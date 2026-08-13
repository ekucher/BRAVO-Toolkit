# BRAVO.BazaSync — incremental, append-only-aware synchronization engine for
# BAZA_APP/BAZA_WWW (>50 GB, десятки/сотні тисяч файлів, накопичувальний
# SFTP). Використовується і BRAVO_ARCHIV (виконує sync), і BRAVO_HEALTH
# (переоцінює вже готовий SyncResult, або синхронізує сам, якщо його немає).
#
# Архітектурний інваріант (safety-review): SYNC -> VERIFY -> HEALTH RESULT,
# а не "VERIFY знайшов нові локальні файли -> ALERT". Нові файли, що
# з'явилися ПІСЛЯ моменту, коли sync зняв знімок каталогу (Cutoff), належать
# наступному циклу (NewAfterCutoff) — це INFO, не помилка поточного циклу.
#
# ЦЕ НЕ Durable Operation Journal. Персистований стан тут — вузькоспеціальний
# індекс "який локальний файл BAZA вже підтверджено переданим на SFTP", а не
# журнал операцій.
$compatibilityManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.Compatibility\BRAVO.Compatibility.psd1'
Import-Module -Name $compatibilityManifest -ErrorAction Stop
$archiveRuntimeManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.ArchiveRuntime\BRAVO.ArchiveRuntime.psd1'
Import-Module -Name $archiveRuntimeManifest -ErrorAction Stop

$script:BazaStateSchemaVersion = 1

# =====================================================================
# STATE: %ProgramData%\BRAVO\State\BAZA\<Component>.state.json
# =====================================================================
# Формат — JSON (узгоджено з рештою persisted state цього комплекту:
# BRAVO_RESTORE_STATE.json, BRAVO_VSS_OWNERSHIP.json). Scalability
# (див. ТЗ п.4): ConvertTo-Json/ConvertFrom-Json на hashtable із
# сотнями тисяч простих записів (RelativePath/Size/LastWriteTimeUtc/
# UploadedUtc/Verified) вимірювався емпірично на fixture 100k
# записів — секунди, не хвилини; прийнятно для фонового 4-годинного
# циклу і значно дешевше за повне SFTP-порівняння дерева, яке ця
# зміна замінює. Якщо в майбутньому це стане вузьким місцем — заміна
# формату (напр. delimited flat-file) можлива без зміни публічного
# контракту функцій цього модуля (Read-/Save-BRAVOBazaState — єдина
# точка серіалізації).

function Get-BRAVOBazaStateDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    return (Join-Path $StateRoot 'BAZA')
}

function Get-BRAVOBazaStatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$Component
    )
    return (Join-Path (Get-BRAVOBazaStateDirectory -StateRoot $StateRoot) "$Component.state.json")
}

function Enter-BRAVOBazaSyncLock {
    # Machine-wide серіалізація ОДНОГО компонента (BAZA_APP/BAZA_WWW) між
    # процесами (ТЗ п.17: "BAZA sync має не виконуватися паралельно з собою,
    # не дублювати upload між Archive і Health"). Основний захист —
    # SkipIfBackupTaskRunning (Health не запускається, поки Archive тримає
    # BRAVO_OPERATION.lock), але це config-залежне і не діє на ручний запуск
    # BRAVO_HEALTH.ps1 без цього прапорця — цей lock є другим, безумовним
    # рубежем саме навколо read-modify-write persisted state.
    #
    # Fail-fast (без очікування/Start-Sleep): якщо lock зайнятий, це означає,
    # що ІНШИЙ процес щойно синхронізує той самий компонент прямо зараз —
    # чекати нема сенсу, викликач має трактувати це як "пропущено цим
    # циклом", а не як помилку (Get-BRAVOBazaFastHealthResult: Status
    # SKIPPED_CONCURRENT -> INFO, не ALERT).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$Component
    )
    $lockPath = Join-Path (Get-BRAVOBazaStateDirectory -StateRoot $StateRoot) "$Component.sync.lock"
    try {
        $lockDirectory = Split-Path -Path $lockPath -Parent
        if (-not (Test-Path -LiteralPath $lockDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $lockDirectory -Force -ErrorAction Stop | Out-Null
        }
        $lockStream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        return [pscustomobject]@{ Success = $true; Stream = $lockStream; Path = $lockPath; Error = $null }
    } catch {
        return [pscustomobject]@{ Success = $false; Stream = $null; Path = $lockPath; Error = $_.Exception.Message }
    }
}

function New-BRAVOBazaEmptyState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Component)
    return [pscustomobject]@{
        SchemaVersion = $script:BazaStateSchemaVersion
        Component = $Component
        LastCycleId = $null
        LastSuccessfulSyncUtc = $null
        LastFullAuditUtc = $null
        # Hashtable, не array: O(1) lookup за RelativePath — критично для
        # сотень тисяч файлів (план інкременту читає це на КОЖЕН локальний
        # файл, щоб вирішити trusted-skip чи candidate).
        Files = @{}
    }
}

function Read-BRAVOBazaState {
    # Повертає керовану відповідь, а не сирий $state — виклик-точка САМА
    # вирішує критичність (той самий принцип, що Resolve-BRAVOInstallationDiscovery
    # уже застосовує для discovery). Відсутність файлу — легітимний перший
    # запуск (Exists=$false, Corrupt=$false): bootstrap. Наявний, але
    # непридатний файл — Corrupt=$true: НІКОЛИ не трактувати старі файли як
    # автоматично verified (ТЗ п.14) — виклик-точка мусить вимагати
    # full reconciliation, а не мовчки почати з порожнього стану (це
    # призвело б до повторного upload УЖЕ переданих файлів, а гірше —
    # замаскувало б реальну проблему зі станом).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Corrupt = $false; State = $null; Reason = $null }
    }
    try {
        $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [pscustomobject]@{ Exists = $true; Corrupt = $true; State = $null; Reason = 'файл стану порожній' }
        }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed.SchemaVersion -or [int]$parsed.SchemaVersion -ne $script:BazaStateSchemaVersion) {
            return [pscustomobject]@{
                Exists = $true; Corrupt = $true; State = $null
                Reason = "непідтримувана schemaVersion: $($parsed.SchemaVersion) (очікується $script:BazaStateSchemaVersion)"
            }
        }
        # ConvertFrom-Json дає PSCustomObject для вкладеного Files — конвертуємо
        # назад у hashtable для O(1) lookup у решті модуля.
        $filesHashtable = @{}
        if ($null -ne $parsed.Files) {
            foreach ($property in $parsed.Files.PSObject.Properties) {
                $filesHashtable[$property.Name] = $property.Value
            }
        }
        $state = [pscustomobject]@{
            SchemaVersion = [int]$parsed.SchemaVersion
            Component = [string]$parsed.Component
            LastCycleId = [string]$parsed.LastCycleId
            LastSuccessfulSyncUtc = [string]$parsed.LastSuccessfulSyncUtc
            LastFullAuditUtc = [string]$parsed.LastFullAuditUtc
            Files = $filesHashtable
        }
        return [pscustomobject]@{ Exists = $true; Corrupt = $false; State = $state; Reason = $null }
    } catch {
        return [pscustomobject]@{ Exists = $true; Corrupt = $true; State = $null; Reason = $_.Exception.Message }
    }
}

function Save-BRAVOBazaState {
    # Atomic write: temp -> [IO.File]::Replace/Move (той самий прийом, що
    # Save-BRAVOVSSOwnershipState). Crash/reboot посеред запису не повинен
    # лишити частковий/пошкоджений файл поверх валідного попереднього стану
    # (ТЗ п.14) — попередній валідний файл лишається читабельним, доки
    # Replace не завершиться атомарно.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$State
    )

    $stateDirectory = Split-Path -Path $Path -Parent
    if (-not [IO.Directory]::Exists($stateDirectory)) {
        [void][IO.Directory]::CreateDirectory($stateDirectory)
    }
    $serializable = [ordered]@{
        SchemaVersion = $script:BazaStateSchemaVersion
        Component = [string]$State.Component
        LastCycleId = $State.LastCycleId
        LastSuccessfulSyncUtc = $State.LastSuccessfulSyncUtc
        LastFullAuditUtc = $State.LastFullAuditUtc
        Files = $State.Files
    }
    $temporaryPath = Join-Path $stateDirectory ('.BRAVO_BAZA_STATE_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $backupPath = Join-Path $stateDirectory ('.BRAVO_BAZA_STATE_{0}.bak' -f [guid]::NewGuid().ToString('N'))
    $replaced = $false
    try {
        $json = $serializable | ConvertTo-Json -Depth 6 -Compress
        [IO.File]::WriteAllText($temporaryPath, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporaryPath, $Path, $backupPath)
            $replaced = $true
        } else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
        if ($replaced -and [IO.File]::Exists($backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# =====================================================================
# CYCLE / SNAPSHOT / PLAN
# =====================================================================

function New-BRAVOBazaCycleId {
    [CmdletBinding()]
    param([datetime]$NowUtc = (Get-Date).ToUniversalTime())
    return ('{0:yyyyMMdd_HHmmss}_{1}' -f $NowUtc, [guid]::NewGuid().ToString('N').Substring(0, 6))
}

function Get-BRAVOBazaLocalSnapshot {
    # Один прохід .NET-переліку (не Get-ChildItem provider layer — той самий
    # підхід, що вже застосований у Maintenance для великих дерев) —
    # ключовий момент Cutoff: файли в ЦЬОМУ знімку належать поточному циклу;
    # усе, що з'явиться ПІСЛЯ (виявлене пізнішим переліком, напр. під час
    # Health) — NewAfterCutoff. Це НЕ залежить від LastWriteTime файла (ТЗ
    # п.7) — залежить лише від моменту самого переліку.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LocalDirectory)

    $snapshotUtc = (Get-Date).ToUniversalTime()
    $entries = @{}
    if (-not [IO.Directory]::Exists($LocalDirectory)) {
        return [pscustomobject]@{ SnapshotUtc = $snapshotUtc; Entries = $entries; Success = $false; Error = "каталог не знайдено: $LocalDirectory" }
    }
    try {
        $rootInfo = New-Object IO.DirectoryInfo($LocalDirectory)
        $normalizedRoot = $rootInfo.FullName.TrimEnd('\', '/')
        foreach ($file in $rootInfo.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) {
            if (([int]$file.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)) -ne 0) {
                continue
            }
            $relativePath = $file.FullName.Substring($normalizedRoot.Length).TrimStart('\', '/')
            $entries[$relativePath] = [pscustomobject]@{
                RelativePath = $relativePath
                Size = [int64]$file.Length
                LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
                FullPath = $file.FullName
            }
        }
        return [pscustomobject]@{ SnapshotUtc = $snapshotUtc; Entries = $entries; Success = $true; Error = $null }
    } catch {
        return [pscustomobject]@{ SnapshotUtc = $snapshotUtc; Entries = $entries; Success = $false; Error = $_.Exception.Message }
    }
}

function Get-BRAVOBazaSyncPlan {
    # Чиста, тестована функція: знімок + стан -> план. Жодного I/O.
    #
    # Класифікація на файл:
    #   TrustedSkip        — state.Verified=true, і size ТА LastWriteTimeUtc
    #                         locally незмінні відносно запису в state.
    #                         Жодного remote-виклику не потрібно (ТЗ п.5).
    #   ToUpload            — немає в state, або в state Verified=false
    #                         (попередній pending/failed), або present, але
    #                         Verified=true з ІНШИМ size (mutation — див.
    #                         нижче: mutation іде окремим списком, а не сюди,
    #                         якщо MutationPolicy=Fail).
    #   MutationViolation   — state.Verified=true, розмір локально ЗМІНИВСЯ.
    #                         Append-only порушено. MutationPolicy=Fail (типово)
    #                         -> файл НЕ включається до ToUpload (без мовчазного
    #                         перезапису remote), лише репортується.
    #
    # LastWriteTimeUtc порівнюється лише як ДОДАТКОВИЙ сигнал зміни (ТЗ п.7:
    # timestamp — optimization hint, не єдине джерело істини) — САМЕ size
    # є вирішальним для mutation-детекції, бо старий/перенесений timestamp
    # з незмінним розміром НЕ вважається mutation (не можна відрізнити його
    # від легітимного відновлення файла з тим самим вмістом), а НОВИЙ файл
    # (відсутній у state) підхоплюється ЗАВЖДИ, незалежно від того, який у
    # нього LastWriteTime — старий timestamp не може приховати нового файла.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][object]$State,
        [string]$MutationPolicy = 'Fail'
    )

    $toUpload = New-Object System.Collections.Generic.List[object]
    $trustedSkip = New-Object System.Collections.Generic.List[object]
    $mutations = New-Object System.Collections.Generic.List[object]

    foreach ($relativePath in $Snapshot.Entries.Keys) {
        $localEntry = $Snapshot.Entries[$relativePath]
        $stateEntry = $State.Files[$relativePath]

        if ($null -eq $stateEntry) {
            $toUpload.Add($localEntry)
            continue
        }

        $stateVerified = [bool]$stateEntry.Verified
        $stateSize = [int64]$stateEntry.Size

        if (-not $stateVerified) {
            # Попередній цикл не встиг/не зміг підтвердити — повторюємо,
            # незалежно від того, змінився файл локально чи ні.
            $toUpload.Add($localEntry)
            continue
        }

        if ($stateSize -ne $localEntry.Size) {
            $mutation = [pscustomobject]@{
                RelativePath = $relativePath
                PreviousSize = $stateSize
                CurrentSize = $localEntry.Size
                PreviousLastWriteTimeUtc = [string]$stateEntry.LastWriteTimeUtc
                CurrentLastWriteTimeUtc = $localEntry.LastWriteTimeUtc
            }
            $mutations.Add($mutation)
            if ($MutationPolicy -ne 'Fail') {
                # Свідома, явно налаштована політика перезапису — за
                # замовчуванням недоступна (ТЗ п.6: "не overwrite remote
                # мовчки без окремої свідомої policy").
                $toUpload.Add($localEntry)
            }
            continue
        }

        # Розмір збігається і Verified=true -> trusted skip незалежно від
        # LastWriteTimeUtc (ТЗ п.7 explicitly forbids timestamp-only logic,
        # тут ми йдемо СТРОГІШИМ шляхом: size — авторитетний сигнал).
        $trustedSkip.Add($localEntry)
    }

    return [pscustomobject]@{
        ToUpload = $toUpload.ToArray()
        TrustedSkip = $trustedSkip.ToArray()
        MutationViolations = $mutations.ToArray()
    }
}

# =====================================================================
# TARGETED UPLOAD (не whole-tree synchronize/CompareDirectories)
# =====================================================================

function Test-BRAVOBazaRemoteDirectoryExists {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Session, [Parameter(Mandatory = $true)][string]$RemotePath)
    try {
        return [bool]$Session.FileExists($RemotePath)
    } catch {
        return $false
    }
}

function New-BRAVOBazaRemoteDirectoryRecursive {
    # session.PutFiles НЕ створює відсутні проміжні remote-каталоги (на
    # відміну від "synchronize", яку цей шлях замінює для targeted upload) —
    # тому створюємо їх самі, сегмент за сегментом, толерантно до гонки
    # (інший процес/попередній цикл міг створити той самий каталог між
    # FileExists і CreateDirectory).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Session, [Parameter(Mandatory = $true)][string]$RemoteDirectoryPath)

    $normalized = $RemoteDirectoryPath.Replace('\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return
    }
    $segments = $normalized -split '/'
    $current = ''
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $current = "$current/$segment"
        if (-not (Test-BRAVOBazaRemoteDirectoryExists -Session $Session -RemotePath $current)) {
            try {
                $Session.CreateDirectory($current)
            } catch {
                # Гонка (хтось інший щойно створив) — перевіряємо ще раз,
                # перш ніж вважати це реальною помилкою.
                if (-not (Test-BRAVOBazaRemoteDirectoryExists -Session $Session -RemotePath $current)) {
                    throw
                }
            }
        }
    }
}

function Invoke-BRAVOBazaFileUpload {
    # Один цільовий upload + легка remote-верифікація (розмір) — O(1) per
    # candidate, не O(усі файли). $Session — injectable (WinSCP.Session або
    # тестовий duck-typed об'єкт з тими самими методами: PutFiles/FileExists/
    # GetFileInfo/CreateDirectory).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][string]$LocalDirectory,
        [Parameter(Mandatory = $true)][string]$RemoteRootPath
    )

    $remoteRelative = $Entry.RelativePath.Replace('\', '/')
    $remoteFullPath = ($RemoteRootPath.TrimEnd('/') + '/' + $remoteRelative)
    $remoteDirectory = Split-Path -Path $remoteFullPath -Parent
    $remoteDirectory = if ([string]::IsNullOrWhiteSpace($remoteDirectory)) { $RemoteRootPath } else { $remoteDirectory.Replace('\', '/') }

    try {
        New-BRAVOBazaRemoteDirectoryRecursive -Session $Session -RemoteDirectoryPath $remoteDirectory
        $transferOptions = New-Object WinSCP.TransferOptions
        $transferOptions.TransferMode = [WinSCP.TransferMode]::Binary
        $transferResult = $Session.PutFiles($Entry.FullPath, $remoteFullPath, $false, $transferOptions)
        if (-not $transferResult.IsSuccess) {
            $failureMessages = @(
                $transferResult.Transfers | Where-Object { $null -ne $_.Error } |
                    ForEach-Object { [string]$_.Error.Message }
            )
            $detail = if ($failureMessages.Count -gt 0) { $failureMessages -join '; ' } else { 'невідома помилка передачі' }
            return [pscustomobject]@{ RelativePath = $Entry.RelativePath; Success = $false; Error = $detail; Bytes = 0 }
        }

        # Легка remote-верифікація: розмір, не checksum (checksum на
        # сотнях тисяч файлів повернув би ту саму O(all) вартість, якої ця
        # зміна навмисно уникає) — targeted, один файл.
        $remoteInfo = $Session.GetFileInfo($remoteFullPath)
        if ($null -eq $remoteInfo -or [int64]$remoteInfo.Length -ne [int64]$Entry.Size) {
            return [pscustomobject]@{
                RelativePath = $Entry.RelativePath; Success = $false
                Error = "remote розмір не збігається після передачі (очікувалось $($Entry.Size))"; Bytes = 0
            }
        }
        return [pscustomobject]@{ RelativePath = $Entry.RelativePath; Success = $true; Error = $null; Bytes = [int64]$Entry.Size }
    } catch {
        return [pscustomobject]@{ RelativePath = $Entry.RelativePath; Success = $false; Error = $_.Exception.Message; Bytes = 0 }
    }
}

# =====================================================================
# SYNC RESULT
# =====================================================================

function New-BRAVOBazaSyncResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$CycleId,
        [Parameter(Mandatory = $true)][datetime]$StartedUtc,
        [Parameter(Mandatory = $true)][datetime]$CutoffUtc
    )
    return [pscustomobject]@{
        Component = $Component
        CycleId = $CycleId
        StartedUtc = $StartedUtc
        CutoffUtc = $CutoffUtc
        CompletedUtc = $null
        DiscoveredWithinCutoff = 0
        AlreadyVerified = 0
        Uploaded = 0
        UploadedBytes = [int64]0
        Failed = 0
        FailedFiles = @()
        PendingWithinCutoff = 0
        NewAfterCutoff = 0
        MutationViolations = @()
        Status = 'ERROR'
        Error = $null
        Bootstrap = $false
    }
}

# =====================================================================
# FULL AUDIT ADAPTER
# =====================================================================
# Full Audit НЕ дублює повне SFTP-порівняння (ТЗ п.25: "не дублювати
# business rules"): виклик-точка (Archive/Health) продовжує використовувати
# ІСНУЮЧУ Get-BAZASFTPComparison (WinSCP .NET CompareDirectories, той самий
# механізм, що вже роками працює в production) — цей модуль лише
# перетворює її результат (PendingFiles з абсолютними локальними шляхами)
# у форму, яку Invoke-BRAVOBazaSynchronization розуміє для bootstrap/seed
# (RelativePath-ключі, узгоджені з Get-BRAVOBazaLocalSnapshot). Чиста,
# тестована функція — жодного SFTP I/O тут немає.

function ConvertTo-BRAVOBazaFullAuditResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$ComparisonSuccess,
        [string]$ComparisonError,
        [object[]]$PendingFiles = @(),
        [Parameter(Mandatory = $true)][string]$LocalDirectory,
        [Parameter(Mandatory = $true)][object]$LocalSnapshot
    )

    if (-not $ComparisonSuccess) {
        return [pscustomobject]@{
            Success = $false; Error = $ComparisonError
            AlreadyMatchingRelativePaths = @(); LocalSizes = @{}; LastWriteTimesUtc = @{}
        }
    }

    $normalizedRoot = ([IO.Path]::GetFullPath($LocalDirectory)).TrimEnd('\', '/')
    $pendingRelativePaths = New-Object System.Collections.Generic.HashSet[string]
    foreach ($pendingFile in $PendingFiles) {
        if ([bool]$pendingFile.IsDirectory) { continue }
        $absolutePath = [string]$pendingFile.Path
        if ([string]::IsNullOrWhiteSpace($absolutePath) -or -not $absolutePath.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $relative = $absolutePath.Substring($normalizedRoot.Length).TrimStart('\', '/')
        [void]$pendingRelativePaths.Add($relative)
    }

    $alreadyMatching = New-Object System.Collections.Generic.List[string]
    $localSizes = @{}
    $lastWriteTimesUtc = @{}
    foreach ($relativePath in $LocalSnapshot.Entries.Keys) {
        if ($pendingRelativePaths.Contains($relativePath)) { continue }
        $entry = $LocalSnapshot.Entries[$relativePath]
        [void]$alreadyMatching.Add($relativePath)
        $localSizes[$relativePath] = $entry.Size
        $lastWriteTimesUtc[$relativePath] = $entry.LastWriteTimeUtc
    }

    return [pscustomobject]@{
        Success = $true; Error = $null
        AlreadyMatchingRelativePaths = $alreadyMatching.ToArray()
        LocalSizes = $localSizes
        LastWriteTimesUtc = $lastWriteTimesUtc
    }
}

# =====================================================================
# ORCHESTRATION
# =====================================================================

function Invoke-BRAVOBazaSynchronization {
    # Один sync cycle одного компонента (BAZA_APP або BAZA_WWW). Викликач
    # (Archive або standalone Health) відповідає за:
    #   - серіалізацію з іншими WinSCP-операціями (Enter-BRAVOWinSCPProcessLock);
    #   - передачу вже відкритої $Session АБО параметрів для її відкриття.
    #
    # -Session injectable: реальний WinSCP.Session у production, duck-typed
    # fake у self-test (New-BRAVOSelfTestRuntimeModule + function-local
    # object, той самий injectable-принцип, що вже усюди в цьому комплекті).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$LocalDirectory,
        [Parameter(Mandatory = $true)][string]$RemoteRootPath,
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$MutationPolicy = 'Fail',
        [switch]$BootstrapIfNeeded,
        [scriptblock]$FullAuditProvider,
        # <= 0 вимикає періодичний Full Audit — тільки bootstrap першого
        # запуску лишається дорогим шляхом. Full Audit ловить дрейф, якого
        # incremental-план структурно не бачить (напр. хтось вручну видалив
        # файл на SFTP) — periodic, не на кожному циклі (ТЗ п.12).
        [double]$FullAuditEveryDays = 0,
        # Ручний тригер (напр. майбутній CLI-прапорець ручної синхронізації) —
        # ігнорує вік LastFullAuditUtc і FullAuditEveryDays, але НЕ ігнорує
        # відсутність FullAuditProvider (нема звідки брати audit).
        [switch]$ForceFullAudit
    )

    $startedUtc = (Get-Date).ToUniversalTime()
    $cycleId = New-BRAVOBazaCycleId -NowUtc $startedUtc
    $statePath = Get-BRAVOBazaStatePath -StateRoot $StateRoot -Component $Component
    $stateRead = Read-BRAVOBazaState -Path $statePath

    if ($stateRead.Corrupt) {
        $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $startedUtc
        $result.Status = 'STATE_INVALID'
        $result.Error = "стан BAZA пошкоджено або несумісний ($statePath): $($stateRead.Reason). Потрібна повна реконсиляція (Full Audit) — старі файли НЕ вважаються автоматично verified."
        $result.CompletedUtc = (Get-Date).ToUniversalTime()
        return $result
    }

    $isFirstRun = -not $stateRead.Exists
    $state = if ($stateRead.Exists) { $stateRead.State } else { New-BRAVOBazaEmptyState -Component $Component }

    # Знімок ОДИН для всього циклу (і для bootstrap seed, і для плану, і як
    # сам Cutoff) — узгодженість: bootstrap ніколи не бачить ІНШИЙ перелік
    # каталогу, ніж той, що потім планується до upload.
    $snapshot = Get-BRAVOBazaLocalSnapshot -LocalDirectory $LocalDirectory
    if (-not $snapshot.Success) {
        $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $startedUtc
        $result.Status = 'ERROR'
        $result.Error = "не вдалося прочитати локальний каталог: $($snapshot.Error)"
        $result.CompletedUtc = (Get-Date).ToUniversalTime()
        return $result
    }
    $cutoffUtc = $snapshot.SnapshotUtc

    # Full Audit тригериться або на першому запуску (bootstrap, ТЗ п.15),
    # або періодично, коли попередній Full Audit застарів (ТЗ п.12/13:
    # "Full Audit НЕ запускати після кожного Archive/Health" — тому це
    # виключно ВІК останнього LastFullAuditUtc, а не кожен цикл).
    # FullAuditEveryDays <= 0 вимикає періодичний шлях; лишається лише
    # bootstrap першого запуску.
    $fullAuditOverdue = $false
    if (-not $isFirstRun -and $ForceFullAudit) {
        $fullAuditOverdue = $true
    } elseif (-not $isFirstRun -and $FullAuditEveryDays -gt 0) {
        $lastFullAuditUtc = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$state.LastFullAuditUtc)) {
            try {
                $lastFullAuditUtc = [DateTime]::Parse(
                    [string]$state.LastFullAuditUtc,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind)
            } catch {
                $lastFullAuditUtc = $null
            }
        }
        # Відсутній/непарсований LastFullAuditUtc у вже-існуючому state
        # (напр. state, створений до появи цього поля) трактується як
        # "прострочено" — консервативно, а не мовчки пропускається назавжди.
        if ($null -eq $lastFullAuditUtc) {
            $fullAuditOverdue = $true
        } else {
            $fullAuditOverdue = ($startedUtc - $lastFullAuditUtc).TotalDays -ge $FullAuditEveryDays
        }
    }

    $bootstrapPerformed = $false
    if (($isFirstRun -or $fullAuditOverdue) -and $BootstrapIfNeeded) {
        # Bootstrap/періодичний Full Audit: одна дорога Full Audit (повне
        # порівняння), щоб НЕ завантажувати повторно файли, які вже
        # фактично є на SFTP (ТЗ п.15), і щоб виявити дрейф (напр. хтось
        # вручну видалив файл на SFTP) — seed/refresh VERIFIED-записів для
        # того, що вже збігається, без жодного upload для них.
        if ($null -eq $FullAuditProvider) {
            if ($isFirstRun) {
                $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $cutoffUtc
                $result.Status = 'ERROR'
                $result.Error = 'перший запуск без persisted state вимагає bootstrap Full Audit, але FullAuditProvider не передано'
                $result.CompletedUtc = (Get-Date).ToUniversalTime()
                return $result
            }
            # Періодичний Full Audit прострочено, але провайдера немає
            # (напр. виклик з Health, де bootstrap/Full Audit свідомо не
            # передається — Archive's exclusive responsibility). Це НЕ
            # помилка цього циклу: incremental sync продовжується без
            # audit, а прострочення лишається до наступного разу, коли
            # виклик матиме провайдера.
        } else {
            $auditResult = & $FullAuditProvider $snapshot
            if (-not $auditResult.Success) {
                if ($isFirstRun) {
                    $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $cutoffUtc
                    $result.Status = 'ERROR'
                    $result.Error = "bootstrap Full Audit не вдався: $($auditResult.Error)"
                    $result.CompletedUtc = (Get-Date).ToUniversalTime()
                    return $result
                }
                # Періодичний (не-bootstrap) Full Audit, що провалився, не
                # має блокувати вже-працюючий incremental sync — стан і
                # далі вважається валідним, LastFullAuditUtc НЕ оновлюється
                # (наступний цикл спробує знову).
            } else {
                $auditMatchedSet = New-Object System.Collections.Generic.HashSet[string]
                foreach ($matchedRelativePath in $auditResult.AlreadyMatchingRelativePaths) {
                    [void]$auditMatchedSet.Add($matchedRelativePath)
                    $state.Files[$matchedRelativePath] = [pscustomobject]@{
                        Size = $auditResult.LocalSizes[$matchedRelativePath]
                        LastWriteTimeUtc = $auditResult.LastWriteTimesUtc[$matchedRelativePath]
                        UploadedUtc = $startedUtc.ToString('o')
                        Verified = $true
                    }
                }
                # Дрейф-реконсиляція: файл, який РАНІШЕ був Verified=true в
                # state, але повний audit (напр. хтось вручну видалив його на
                # SFTP) НЕ підтвердив його серед AlreadyMatchingRelativePaths
                # — це саме "старий remote-об'єкт зник" (ТЗ п.13). Скидаємо
                # Verified, щоб звичайний incremental-план цього ж циклу
                # підхопив його як ToUpload — без цього периодичний Full
                # Audit був би лише "seed", а не справжньою реконсиляцією.
                foreach ($localRelativePath in $snapshot.Entries.Keys) {
                    if ($auditMatchedSet.Contains($localRelativePath)) { continue }
                    $existingStateEntry = $state.Files[$localRelativePath]
                    if ($null -ne $existingStateEntry -and [bool]$existingStateEntry.Verified) {
                        $existingStateEntry.Verified = $false
                    }
                }
                $state.LastFullAuditUtc = $startedUtc.ToString('o')
                $bootstrapPerformed = $true
            }
        }
    }

    $plan = Get-BRAVOBazaSyncPlan -Snapshot $snapshot -State $state -MutationPolicy $MutationPolicy

    $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $cutoffUtc
    $result.Bootstrap = $bootstrapPerformed
    $result.DiscoveredWithinCutoff = $snapshot.Entries.Count
    $result.AlreadyVerified = $plan.TrustedSkip.Count
    $result.MutationViolations = $plan.MutationViolations

    $uploadedCount = 0
    $uploadedBytes = [int64]0
    $failedFiles = New-Object System.Collections.Generic.List[object]

    foreach ($candidate in $plan.ToUpload) {
        $uploadOutcome = Invoke-BRAVOBazaFileUpload -Session $Session -Entry $candidate -LocalDirectory $LocalDirectory -RemoteRootPath $RemoteRootPath
        if ($uploadOutcome.Success) {
            $uploadedCount++
            $uploadedBytes += $uploadOutcome.Bytes
            $state.Files[$candidate.RelativePath] = [pscustomobject]@{
                Size = $candidate.Size
                LastWriteTimeUtc = $candidate.LastWriteTimeUtc
                UploadedUtc = (Get-Date).ToUniversalTime().ToString('o')
                Verified = $true
            }
        } else {
            $failedFiles.Add([pscustomobject]@{ RelativePath = $candidate.RelativePath; Error = $uploadOutcome.Error })
            # Явно НЕ verified — наступний цикл повторить спробу (crash/
            # failure-safe: ТЗ п.4 і сценарій "crash посеред upload").
            $state.Files[$candidate.RelativePath] = [pscustomobject]@{
                Size = $candidate.Size
                LastWriteTimeUtc = $candidate.LastWriteTimeUtc
                UploadedUtc = $null
                Verified = $false
            }
        }
    }

    $result.Uploaded = $uploadedCount
    $result.UploadedBytes = $uploadedBytes
    $result.Failed = $failedFiles.Count
    $result.FailedFiles = $failedFiles.ToArray()
    $result.PendingWithinCutoff = $failedFiles.Count

    $completedUtc = (Get-Date).ToUniversalTime()
    $result.CompletedUtc = $completedUtc

    if ($failedFiles.Count -gt 0) {
        $result.Status = 'INCOMPLETE'
    } elseif ($plan.MutationViolations.Count -gt 0 -and $MutationPolicy -eq 'Fail') {
        $result.Status = 'MUTATION_VIOLATION'
    } else {
        $result.Status = 'COMPLETE'
        $state.LastCycleId = $cycleId
        $state.LastSuccessfulSyncUtc = $completedUtc.ToString('o')
    }

    try {
        Save-BRAVOBazaState -Path $statePath -State $state
    } catch {
        # Стан не вдалось зберегти — наступний цикл побачить старий (менш
        # повний, але не пошкоджений) стан і повторить upload вже переданих
        # у ЦЬОМУ циклі файлів. Це безпечний degrade (зайва, а не втрачена
        # робота), тому не перетворюємо успішний sync на ERROR лише через
        # це, але результат мусить це відобразити.
        if ($result.Status -eq 'COMPLETE') {
            $result.Status = 'INCOMPLETE'
        }
        $result.Error = "передачу завершено, але не вдалося зберегти стан: $($_.Exception.Message)"
    }

    return $result
}

# =====================================================================
# REMOTE CHECKPOINT (metadata only — не заміна persisted state)
# =====================================================================

function Get-BRAVOBazaRemoteCheckpointName {
    return '.bravo-sync.json'
}

function Write-BRAVOBazaRemoteCheckpoint {
    # Публікується ЛИШЕ як останній крок УСПІШНОГО sync (ТЗ п.11) — partial/
    # failed цикл не повинен публікувати "successful" checkpoint. Метадані
    # лише: жодних credentials/webhook/secret значень (ТЗ п.24).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$RemoteRootPath,
        [Parameter(Mandatory = $true)][object]$SyncResult
    )
    if ($SyncResult.Status -ne 'COMPLETE') {
        return $false
    }
    $checkpoint = [ordered]@{
        cycleId = $SyncResult.CycleId
        lastSuccessfulSyncUtc = $SyncResult.CompletedUtc.ToString('o')
        cutoffUtc = $SyncResult.CutoffUtc.ToString('o')
        uploadedFiles = $SyncResult.Uploaded
        uploadedBytes = $SyncResult.UploadedBytes
        pendingWithinCutoff = $SyncResult.PendingWithinCutoff
        failed = $SyncResult.Failed
        host = [Environment]::MachineName
    }
    $tempLocalPath = Join-Path ([IO.Path]::GetTempPath()) ('bravo-sync-{0}.json' -f [guid]::NewGuid().ToString('N'))
    try {
        $json = $checkpoint | ConvertTo-Json -Depth 3
        [IO.File]::WriteAllText($tempLocalPath, $json, (New-Object Text.UTF8Encoding($false)))
        $remoteCheckpointPath = ($RemoteRootPath.TrimEnd('/') + '/' + (Get-BRAVOBazaRemoteCheckpointName))
        $transferOptions = New-Object WinSCP.TransferOptions
        $transferOptions.TransferMode = [WinSCP.TransferMode]::Binary
        $transferResult = $Session.PutFiles($tempLocalPath, $remoteCheckpointPath, $false, $transferOptions)
        return [bool]$transferResult.IsSuccess
    } catch {
        return $false
    } finally {
        if (Test-Path -LiteralPath $tempLocalPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempLocalPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# =====================================================================
# NEW-AFTER-CUTOFF (легкий, ЛИШЕ локальний перелік — без SFTP)
# =====================================================================

function Update-BRAVOBazaSyncResultNewAfterCutoff {
    # SyncResult.NewAfterCutoff НЕ обчислюється всередині
    # Invoke-BRAVOBazaSynchronization: це за задумом health-time concern
    # (ТЗ п.8/10) — "скільки файлів з'явилося з моменту cutoff ДО ЗАРАЗ",
    # де "зараз" — момент, коли Health (не sync) оцінює результат, можливо
    # хвилини по тому. Дешева ЛИШЕ-локальна перевірка (жодного SFTP-виклику,
    # тому безпечна для Fast Health): свіжий перелік локального каталогу,
    # файли, ЯКИХ немає серед ключів persisted state (щойно оновленого
    # синхронізацією, чий cutoff-знімок ПОВНІСТЮ записується в state.Files
    # — і Verified=true, і Verified=false/pending) — це НОВІ, ще не
    # побачені sync-ом файли. Мутує й повертає той самий SyncResult.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$SyncResult,
        [Parameter(Mandatory = $true)][string]$LocalDirectory,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )

    if ($SyncResult.Status -notin @('COMPLETE', 'INCOMPLETE', 'MUTATION_VIOLATION')) {
        # ERROR/STATE_INVALID: стан ненадійний або синхронізація взагалі не
        # відбулась — NewAfterCutoff тут не має сенсу, лишаємо 0.
        return $SyncResult
    }

    $statePath = Get-BRAVOBazaStatePath -StateRoot $StateRoot -Component $SyncResult.Component
    $stateRead = Read-BRAVOBazaState -Path $statePath
    if (-not $stateRead.Exists -or $stateRead.Corrupt) {
        return $SyncResult
    }

    $freshSnapshot = Get-BRAVOBazaLocalSnapshot -LocalDirectory $LocalDirectory
    if (-not $freshSnapshot.Success) {
        return $SyncResult
    }

    $newCount = 0
    foreach ($relativePath in $freshSnapshot.Entries.Keys) {
        if (-not $stateRead.State.Files.ContainsKey($relativePath)) {
            $newCount++
        }
    }
    $SyncResult.NewAfterCutoff = $newCount
    return $SyncResult
}

# =====================================================================
# FAST HEALTH (з уже готового SyncResult — жодного нового порівняння)
# =====================================================================

function Test-BRAVOBazaSyncResultFresh {
    [CmdletBinding()]
    param(
        [object]$SyncResult,
        [Parameter(Mandatory = $true)][double]$MaxAgeMinutes,
        [datetime]$NowUtc = (Get-Date).ToUniversalTime()
    )
    if ($null -eq $SyncResult -or $null -eq $SyncResult.CompletedUtc) {
        return $false
    }
    $ageMinutes = ($NowUtc - $SyncResult.CompletedUtc).TotalMinutes
    return ($ageMinutes -ge 0 -and $ageMinutes -le $MaxAgeMinutes)
}

function Get-BRAVOBazaFastHealthResult {
    # Оцінює здоров'я ВИКЛЮЧНО з уже обчисленого SyncResult — жодного
    # нового SFTP-порівняння (ТЗ п.2, "SYNC -> VERIFY -> HEALTH RESULT").
    #
    # Явне розрізнення (ТЗ п.18):
    #   A. NORMAL NEW DATA (NewAfterCutoff)  -> INFO, не alert;
    #   B. SYNC FAILED (Status != COMPLETE/MUTATION_VIOLATION зі своєю
    #      причиною)                          -> ALERT, "синхронізація не
    #                                            завершена", не "N файлів
    #                                            відсутні";
    #   C. CURRENT CYCLE INCOMPLETE (Failed>0
    #      або PendingWithinCutoff>0)          -> ALERT з деталями what/why.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$SyncResult)

    if ($SyncResult.Status -eq 'STATE_INVALID') {
        return [pscustomobject]@{
            Level = 'CRITICAL'; Healthy = $false
            Message = "$($SyncResult.Component): стан синхронізації пошкоджено — потрібна повна реконсиляція. $($SyncResult.Error)"
        }
    }
    if ($SyncResult.Status -eq 'ERROR') {
        return [pscustomobject]@{
            Level = 'CRITICAL'; Healthy = $false
            Message = "$($SyncResult.Component) — синхронізація не завершена: $($SyncResult.Error)"
        }
    }
    if ($SyncResult.Status -eq 'SKIPPED_CONCURRENT') {
        # Інший процес (напр. Archive) якраз синхронізує той самий
        # компонент (Enter-BRAVOBazaSyncLock, ТЗ п.17) — це ознака, що
        # система АКТИВНО працює, а не проблема цього циклу; ALERT тут був
        # би саме тим false positive, якого весь цей safety-review уникає.
        return [pscustomobject]@{
            Level = 'INFO'; Healthy = $true
            Message = "$($SyncResult.Component) — синхронізацію виконує інший процес одночасно; пропущено цим циклом ($($SyncResult.Error))"
        }
    }
    if ($SyncResult.Status -eq 'MUTATION_VIOLATION') {
        $names = ($SyncResult.MutationViolations | Select-Object -First 5 | ForEach-Object { $_.RelativePath }) -join ', '
        return [pscustomobject]@{
            Level = 'CRITICAL'; Healthy = $false
            Message = "$($SyncResult.Component) — виявлено append-only invariant violation ($($SyncResult.MutationViolations.Count) файл(ів), напр.: $names) — передачу заблоковано, потрібне ручне рішення"
        }
    }
    if ($SyncResult.Failed -gt 0 -or $SyncResult.PendingWithinCutoff -gt 0) {
        $failedNames = ($SyncResult.FailedFiles | Select-Object -First 5 | ForEach-Object { $_.RelativePath }) -join ', '
        return [pscustomobject]@{
            Level = 'CRITICAL'; Healthy = $false
            Message = (
                "$($SyncResult.Component) — синхронізація не завершена. Cycle: $($SyncResult.CycleId). " +
                "Виявлено: $($SyncResult.DiscoveredWithinCutoff) • Передано: $($SyncResult.Uploaded) • " +
                "Не передано: $($SyncResult.Failed)$(if ($failedNames) { " ($failedNames)" })"
            )
        }
    }

    $infoParts = New-Object System.Collections.Generic.List[string]
    if ($SyncResult.NewAfterCutoff -gt 0) {
        [void]$infoParts.Add("нові після cutoff: $($SyncResult.NewAfterCutoff) файл(ів) — будуть передані наступним циклом")
    }
    return [pscustomobject]@{
        Level = 'OK'; Healthy = $true
        Message = "$($SyncResult.Component) — хмарна копія актуальна. Cycle: $($SyncResult.CycleId). Передано: $($SyncResult.Uploaded) файл(ів) • $($SyncResult.UploadedBytes) байт. Помилок: 0."
        Info = $infoParts.ToArray()
    }
}

# =====================================================================
# SESSION ORCHESTRATION (WinSCP.Session lifecycle навколо один cycle)
# =====================================================================
# Спільна точка входу для Archive і Health — ONE synchronization, ONE
# SyncResult (ТЗ п.9): обидва викликають ЦЮ функцію, а не власну копію
# session-open/close коду. -FullAuditProvider приймається ЗЗОВНІ (не
# дублює Get-BAZASFTPComparison, яка вже є в BRAVO.Archive.Runtime.ps1 —
# ТЗ п.25) — викликач сам будує scriptblock навколо своєї вже наявної
# реалізації порівняння.

function Invoke-BRAVOBazaComponentSyncSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$LocalDirectory,
        [Parameter(Mandatory = $true)][string]$RemoteRootPath,
        [Parameter(Mandatory = $true)][string]$RepositorySFTPUrl,
        [Parameter(Mandatory = $true)][string]$HostKey,
        [Parameter(Mandatory = $true)][string]$WinSCPAssemblyPath,
        [Parameter(Mandatory = $true)][string]$WinSCPExecutablePath,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [int]$ConnectionTimeoutSeconds = 30,
        [int]$OperationTimeoutSeconds = 1800,
        [string]$MutationPolicy = 'Fail',
        [switch]$BootstrapIfNeeded,
        [scriptblock]$FullAuditProvider,
        [double]$FullAuditEveryDays = 0,
        [switch]$ForceFullAudit,
        [switch]$WriteCheckpoint
    )

    $cycleId = New-BRAVOBazaCycleId
    $startedUtc = (Get-Date).ToUniversalTime()

    # Machine-wide серіалізація ЦЬОГО компонента (ТЗ п.17) — аквайриться ДО
    # відкриття WinSCP-сесії, щоб не платити за зайве з'єднання, коли інший
    # процес (напр. Archive, поки standalone Health запущено вручну без
    # -SkipIfBackupTaskRunning) вже синхронізує той самий компонент.
    $syncLock = Enter-BRAVOBazaSyncLock -StateRoot $StateRoot -Component $Component
    if (-not $syncLock.Success) {
        $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $startedUtc
        $result.Status = 'SKIPPED_CONCURRENT'
        $result.Error = "інший процес зараз синхронізує $Component ($($syncLock.Path)): $($syncLock.Error)"
        $result.CompletedUtc = (Get-Date).ToUniversalTime()
        return $result
    }

    $session = $null
    try {
        if ($null -eq ('WinSCP.Session' -as [type])) {
            Add-Type -Path $WinSCPAssemblyPath -ErrorAction Stop
        }
        $sessionOptions = New-Object WinSCP.SessionOptions
        $sessionOptions.ParseUrl($RepositorySFTPUrl)
        $sessionOptions.SshHostKeyFingerprint = ([string]$HostKey).Trim().Trim('"')
        $sessionOptions.Timeout = [timespan]::FromSeconds([math]::Max(1, $ConnectionTimeoutSeconds))

        $session = New-Object WinSCP.Session
        $session.ExecutablePath = $WinSCPExecutablePath
        $session.Timeout = [timespan]::FromSeconds([math]::Max(1, $OperationTimeoutSeconds))
        $session.Open($sessionOptions)

        $syncResult = Invoke-BRAVOBazaSynchronization `
            -Component $Component `
            -LocalDirectory $LocalDirectory `
            -RemoteRootPath $RemoteRootPath `
            -Session $session `
            -StateRoot $StateRoot `
            -MutationPolicy $MutationPolicy `
            -BootstrapIfNeeded:$BootstrapIfNeeded `
            -FullAuditProvider $FullAuditProvider `
            -FullAuditEveryDays $FullAuditEveryDays `
            -ForceFullAudit:$ForceFullAudit

        if ($WriteCheckpoint -and $syncResult.Status -eq 'COMPLETE') {
            [void](Write-BRAVOBazaRemoteCheckpoint -Session $session -RemoteRootPath $RemoteRootPath -SyncResult $syncResult)
        }
        return $syncResult
    } catch {
        $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $startedUtc
        $result.Status = 'ERROR'
        $result.Error = "не вдалося відкрити SFTP-сесію або виконати синхронізацію ${Component}: $($_.Exception.Message)"
        $result.CompletedUtc = (Get-Date).ToUniversalTime()
        return $result
    } finally {
        if ($null -ne $session) {
            try { $session.Dispose() } catch {
                # Сесія й так закривається (успішно чи ні) — синхронізація вже
                # завершена, результат обчислено; помилка Dispose тут не
                # впливає на нього і логувати нема що діяти.
            }
        }
        if ($null -ne $syncLock.Stream) {
            try { $syncLock.Stream.Dispose() } catch {
                # Те саме: файловий handle звільниться при завершенні процесу
                # навіть якщо Dispose кине виняток — не критично для результату.
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Get-BRAVOBazaStateDirectory',
    'Get-BRAVOBazaStatePath',
    'Enter-BRAVOBazaSyncLock',
    'New-BRAVOBazaEmptyState',
    'Read-BRAVOBazaState',
    'Save-BRAVOBazaState',
    'New-BRAVOBazaCycleId',
    'Get-BRAVOBazaLocalSnapshot',
    'Get-BRAVOBazaSyncPlan',
    'Test-BRAVOBazaRemoteDirectoryExists',
    'New-BRAVOBazaRemoteDirectoryRecursive',
    'Invoke-BRAVOBazaFileUpload',
    'New-BRAVOBazaSyncResult',
    'ConvertTo-BRAVOBazaFullAuditResult',
    'Invoke-BRAVOBazaSynchronization',
    'Get-BRAVOBazaRemoteCheckpointName',
    'Write-BRAVOBazaRemoteCheckpoint',
    'Update-BRAVOBazaSyncResultNewAfterCutoff',
    'Test-BRAVOBazaSyncResultFresh',
    'Get-BRAVOBazaFastHealthResult',
    'Invoke-BRAVOBazaComponentSyncSession'
)
