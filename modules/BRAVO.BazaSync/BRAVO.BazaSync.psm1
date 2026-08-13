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
    # Fail-fast (без очікування/Start-Sleep): якщо lock зайнятий іншим
    # процесом, чекати нема сенсу — викликач трактує це як "пропущено цим
    # циклом" (Classification=Busy -> SKIPPED_CONCURRENT -> INFO).
    #
    # P1-3 (deep review): Classification РОЗРІЗНЯЄ genuine contention від
    # інфраструктурної помилки. Раніше БУДЬ-ЯКИЙ виняток (ACL denied,
    # каталог стану недоступний, зіпсований шлях, диск відсутній) ставав
    # Success=$false без різниці — виклик-точка тоді ЗАВЖДИ перетворювала
    # це на SKIPPED_CONCURRENT, а Fast Health трактує SKIPPED_CONCURRENT як
    # healthy/INFO. Це маскувало реальні інфраструктурні збої під "просто
    # інший процес зараз синхронізує". Емпірично підтверджено (.NET,
    # Windows): genuine sharing violation (другий File.Open на вже
    # відкритий з FileShare.None файл) дає РІВНО System.IO.IOException з
    # HResult -2147024864 (Win32 ERROR_SHARING_VIOLATION=32, він же
    # 0x80070020) — і ЛИШЕ це вважається Busy. Будь-яка інша IOException
    # (DirectoryNotFoundException — підтверджено емпірично, коли батько
    # шляху насправді файл, не каталог; PathTooLongException; диск
    # від'єднаний), UnauthorizedAccessException (ACL, read-only файл,
    # спроба відкрити каталог як файл — підтверджено емпірично) чи
    # будь-що інше (ArgumentException на некоректних символах шляху) —
    # завжди Error, ніколи Busy.
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
        return [pscustomobject]@{ Success = $true; Stream = $lockStream; Path = $lockPath; Classification = 'Acquired'; Error = $null }
    } catch [System.IO.IOException] {
        $isSharingViolation = ($_.Exception.HResult -eq -2147024864)
        return [pscustomobject]@{
            Success = $false; Stream = $null; Path = $lockPath
            Classification = if ($isSharingViolation) { 'Busy' } else { 'Error' }
            Error = $_.Exception.Message
        }
    } catch {
        # UnauthorizedAccessException і все інше (ArgumentException тощо) —
        # ніколи не "інший процес синхронізує", завжди інфраструктурна
        # помилка.
        return [pscustomobject]@{ Success = $false; Stream = $null; Path = $lockPath; Classification = 'Error'; Error = $_.Exception.Message }
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
    #                         (попередній pending/failed).
    #   MutationViolation   — state.Verified=true, а size АБО LastWriteTimeUtc
    #                         локально ЗМІНИВСЯ (P2, hardening round 2: раніше
    #                         порівнювався лише size, всупереч цьому ж
    #                         контракту — append-only файл, переписаний тим
    #                         самим розміром, але з новим mtime, мовчки
    #                         отримував trusted skip). MutationPolicy=Fail
    #                         (типово) -> файл НЕ включається до ToUpload (без
    #                         мовчазного перезапису remote), лише репортується.
    #
    # Це НЕ timestamp-only discovery (ТЗ п.7 лишається в силі): рішення
    # "новий чи ні" ухвалюється ВИКЛЮЧНО за присутністю шляху в state —
    # новий файл (відсутній у state) підхоплюється ЗАВЖДИ, хоч би який
    # старий LastWriteTime він мав. Timestamp бере участь лише в
    # mutation-детекції ВЖЕ Verified шляху, як другий сигнал зміни поряд
    # із розміром.
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

        $sizeChanged = ($stateSize -ne $localEntry.Size)
        $mtimeChanged = $false
        $stateMtimeRaw = [string]$stateEntry.LastWriteTimeUtc
        $localMtimeRaw = [string]$localEntry.LastWriteTimeUtc
        if ($stateMtimeRaw -cne $localMtimeRaw) {
            # Швидкий шлях вище: обидва значення пишуться одним і тим самим
            # ToString('o'), тож для незмінного файлу рядки збігаються без
            # парсингу (важливо на 100k+ Verified записів). Парсимо лише
            # при розбіжності рядків, щоб відрізнити реальну зміну mtime
            # від суто форматної відмінності історичного запису.
            $stateMtimeParsed = [datetime]::MinValue
            $localMtimeParsed = [datetime]::MinValue
            $bothParsed = (
                [datetime]::TryParse($stateMtimeRaw, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$stateMtimeParsed) -and
                [datetime]::TryParse($localMtimeRaw, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$localMtimeParsed)
            )
            # Непарсований запис = не можемо ДОВЕСТИ незмінність -> fail
            # visible (mutation), не мовчазний trusted skip.
            $mtimeChanged = -not (
                $bothParsed -and
                $stateMtimeParsed.ToUniversalTime().Ticks -eq $localMtimeParsed.ToUniversalTime().Ticks
            )
        }

        if ($sizeChanged -or $mtimeChanged) {
            $mutation = [pscustomobject]@{
                RelativePath = $relativePath
                PreviousSize = $stateSize
                CurrentSize = $localEntry.Size
                PreviousLastWriteTimeUtc = $stateMtimeRaw
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

        # Verified=true, size і LastWriteTimeUtc незмінні -> trusted skip.
        $trustedSkip.Add($localEntry)
    }

    return [pscustomobject]@{
        ToUpload = $toUpload.ToArray()
        TrustedSkip = $trustedSkip.ToArray()
        MutationViolations = $mutations.ToArray()
    }
}

function Test-BRAVOBazaRemoteNameCompatibility {
    # Локальна ЛИШЕ перевірка (жодного SFTP I/O, жодного remote listing) —
    # порт того самого правила, що вже роками застосовує legacy
    # Get-BAZARemoteNameCompatibilityIssues (BRAVO.Archive.Runtime.ps1):
    # кожен СЕГМЕНТ відносного шляху (і кожен проміжний каталог, і сам
    # файл) не повинен перевищувати типову межу довжини імені на SFTP-
    # серверах (255 байт у UTF-8). ТЗ P2 ("Preserve SFTP filename
    # compatibility safety"): incremental-шлях раніше повністю пропускав
    # цю перевірку.
    #
    # Викликається ЛИШЕ для кандидатів у ToUpload (Invoke-BRAVOBazaSynchronization),
    # НЕ для всього локального дерева на кожному циклі — інакше сотні тисяч
    # уже Verified файлів отримували б зайву перевірку щоцикл, та сама
    # O(усі файли) вартість, якої incremental engine навмисно уникає.
    #
    # Ліміт ФАЙЛА = 246, а не 255 (P1, hardening round 2): цільовий upload
    # явно вмикає ResumeSupport (див. Invoke-BRAVOBazaFileUpload), а WinSCP
    # при resume додає ".filepart" — 9 UTF-8 байт — до тимчасового імені.
    # Це ТА САМА пара значень, що її роками використовує legacy-шлях
    # (BRAVO.Archive.Runtime.ps1: 246 при -resumesupport=on, інакше 255):
    # ім'я на 247..255 байт пройшло б валідацію і впало б уже ПІД ЧАС
    # передачі, коли сервер відхилить "<ім'я>.filepart". Каталогів resume
    # не стосується — для них лишається 255.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [int]$MaximumFileUtf8Bytes = 246,
        [int]$MaximumDirectoryUtf8Bytes = 255
    )

    $segments = @(
        $RelativePath.Replace('\', '/').Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    for ($segmentIndex = 0; $segmentIndex -lt $segments.Count; $segmentIndex++) {
        $segment = $segments[$segmentIndex]
        $isLeaf = ($segmentIndex -eq ($segments.Count - 1))
        $maximumUtf8Bytes = if ($isLeaf) { $MaximumFileUtf8Bytes } else { $MaximumDirectoryUtf8Bytes }
        $utf8ByteCount = [System.Text.Encoding]::UTF8.GetByteCount($segment)
        if ($utf8ByteCount -gt $maximumUtf8Bytes) {
            return [pscustomobject]@{
                Compatible = $false
                Segment = $segment
                IsDirectory = -not $isLeaf
                Utf8ByteCount = $utf8ByteCount
                MaximumUtf8Bytes = $maximumUtf8Bytes
                Reason = "ім'я '$segment' довше за допустимі $maximumUtf8Bytes байт у UTF-8 (фактично $utf8ByteCount)"
            }
        }
    }
    return [pscustomobject]@{
        Compatible = $true; Segment = $null; IsDirectory = $false; Utf8ByteCount = 0; MaximumUtf8Bytes = 0; Reason = $null
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

function Get-BRAVOBazaExistingRemoteUploadOutcome {
    # Приватний хелпер (свідомо НЕ експортується): класифікація випадку
    # "remote-шлях кандидата вже зайнятий". Викликається ДВІЧІ на
    # кандидата — рання дешева перевірка і повторна безпосередньо перед
    # PutFiles (мінімізація TOCTOU-вікна). Повертає $null, якщо remote
    # відсутній (звичайний upload дозволено).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][string]$RemoteFullPath,
        [switch]$DisallowRecovery
    )

    if (-not [bool]$Session.FileExists($RemoteFullPath)) {
        return $null
    }
    $existingRemoteInfo = $Session.GetFileInfo($RemoteFullPath)
    $existingRemoteSize = if ($null -ne $existingRemoteInfo) { [int64]$existingRemoteInfo.Length } else { [int64](-1) }
    if ($DisallowRecovery) {
        return [pscustomobject]@{
            RelativePath = $Entry.RelativePath; Success = $false; Outcome = 'AuditDrift'
            Error = "remote-файл існує, але ПОТОЧНИЙ Full Audit явно позначив кандидата як pending — generic same-size recovery заборонено, перезапис заборонено (local $($Entry.Size) байт, remote $existingRemoteSize байт)"
            Bytes = 0; RemoteSize = $existingRemoteSize
        }
    }
    if ($existingRemoteSize -eq [int64]$Entry.Size) {
        return [pscustomobject]@{
            RelativePath = $Entry.RelativePath; Success = $true; Outcome = 'AlreadyRemote'
            Error = $null; Bytes = 0; RemoteSize = $existingRemoteSize
        }
    }
    return [pscustomobject]@{
        RelativePath = $Entry.RelativePath; Success = $false; Outcome = 'RemoteConflict'
        Error = "remote-файл уже існує з іншим розміром (local $($Entry.Size) байт, remote $existingRemoteSize байт) — перезапис заборонено append-only контрактом"
        Bytes = 0; RemoteSize = $existingRemoteSize
    }
}

function Invoke-BRAVOBazaFileUpload {
    # Один цільовий upload + легка remote-верифікація (розмір) — O(1) per
    # candidate, не O(усі файли). $Session — injectable (WinSCP.Session або
    # тестовий duck-typed об'єкт з тими самими методами: PutFiles/FileExists/
    # GetFileInfo/CreateDirectory).
    #
    # P1 (hardening round 3): перед PutFiles — цільова перевірка існування
    # САМОГО remote-файлу. WinSCP TransferOptions.OverwriteMode типово =
    # Overwrite, тобто без цієї перевірки кандидат, чий remote-шлях ВЖЕ
    # зайнятий, мовчки ПЕРЕЗАПИСАВ би наявний immutable BAZA-файл. Типовий
    # реальний випадок — crash-вікно: PutFiles попереднього циклу встиг,
    # Save-BRAVOBazaState — ні; наступний цикл знову бачить кандидата.
    # Append-only контракт:
    #   remote відсутній        -> звичайний targeted upload (Outcome=Uploaded)
    #   remote є, розмір збігся -> визнаємо файл уже присутнім/відновленим,
    #                              НУЛЬ PutFiles (Outcome=AlreadyRemote)
    #   remote є, розмір інший  -> Outcome=RemoteConflict, НУЛЬ PutFiles,
    #                              fail visible — ЖОДНОГО overwrite за
    #                              замовчуванням. Якщо колись знадобиться
    #                              overwrite — це мусить бути ОКРЕМА, явно
    #                              названа операторська політика, не тихий
    #                              OverwriteMode=Overwrite.
    # Перевірка цільова (один FileExists, і лише за потреби один GetFileInfo,
    # на КАНДИДАТА): TrustedSkip-записи в цю функцію взагалі не потрапляють,
    # тож O(Verified) remote-викликів не з'являється.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][string]$LocalDirectory,
        [Parameter(Mandatory = $true)][string]$RemoteRootPath,
        # P1 (round 4): кандидат, якого ПОТОЧНИЙ Full Audit явно позначив
        # pending (UploadNew/UploadUpdate), не має права на generic
        # AlreadyRemote same-size recovery: audit уже порівняв за
        # -criteria=time,size і виніс вердикт "не збігається" — збіг ЛИШЕ
        # розміру не сміє його мовчки скасувати. remote відсутній ->
        # звичайний upload; remote існує -> Outcome=AuditDrift (нуль
        # PutFiles, без перезапису).
        [switch]$DisallowExistingRemoteRecovery
    )

    $remoteRelative = $Entry.RelativePath.Replace('\', '/')
    $remoteFullPath = ($RemoteRootPath.TrimEnd('/') + '/' + $remoteRelative)
    $remoteDirectory = Split-Path -Path $remoteFullPath -Parent
    $remoteDirectory = if ([string]::IsNullOrWhiteSpace($remoteDirectory)) { $RemoteRootPath } else { $remoteDirectory.Replace('\', '/') }

    try {
        $existingOutcome = Get-BRAVOBazaExistingRemoteUploadOutcome -Session $Session -Entry $Entry -RemoteFullPath $remoteFullPath -DisallowRecovery:$DisallowExistingRemoteRecovery
        if ($null -ne $existingOutcome) { return $existingOutcome }
        New-BRAVOBazaRemoteDirectoryRecursive -Session $Session -RemoteDirectoryPath $remoteDirectory
        # P2 (round 4): повторна перевірка існування якнайближче до
        # PutFiles (після підготовки remote-каталогів) — звужує TOCTOU-
        # вікно FileExists...PutFiles. Це НЕ розподілена атомарна
        # гарантія: локальний lock — machine-wide, не SFTP-wide;
        # IncrementalAppendOnly вимагає РІВНО ОДНОГО writer-а на кожен
        # керований BAZA remote root (див. OPERATIONS).
        $existingOutcome = Get-BRAVOBazaExistingRemoteUploadOutcome -Session $Session -Entry $Entry -RemoteFullPath $remoteFullPath -DisallowRecovery:$DisallowExistingRemoteRecovery
        if ($null -ne $existingOutcome) { return $existingOutcome }
        $transferOptions = New-Object WinSCP.TransferOptions
        $transferOptions.TransferMode = [WinSCP.TransferMode]::Binary
        # P1 (hardening round 2): resume вмикається ЯВНО, а не через
        # built-in default WinSCP (той сам вирішує за порогом розміру,
        # використовувати чи ні тимчасове ".filepart"-ім'я). Явний On
        # робить контракт детермінованим і узгодженим із валідатором імен
        # (Test-BRAVOBazaRemoteNameCompatibility, ліміт файла 246 байт =
        # 255 - 9 байт ".filepart") — legacy-шлях так само працює в парі
        # resumesupport=on + ліміт 246. Свідомо НЕ вимикаємо resume заради
        # "довших імен": обрив передачі великого BAZA-файлу без resume
        # коштує дорожче, ніж 9 байт запасу в імені.
        $transferOptions.ResumeSupport.State = [WinSCP.TransferResumeSupportState]::On
        $transferResult = $Session.PutFiles($Entry.FullPath, $remoteFullPath, $false, $transferOptions)
        if (-not $transferResult.IsSuccess) {
            $failureMessages = @(
                $transferResult.Transfers | Where-Object { $null -ne $_.Error } |
                    ForEach-Object { [string]$_.Error.Message }
            )
            $detail = if ($failureMessages.Count -gt 0) { $failureMessages -join '; ' } else { 'невідома помилка передачі' }
            return [pscustomobject]@{ RelativePath = $Entry.RelativePath; Success = $false; Outcome = 'Failed'; Error = $detail; Bytes = 0; RemoteSize = $null }
        }

        # Легка remote-верифікація: розмір, не checksum (checksum на
        # сотнях тисяч файлів повернув би ту саму O(all) вартість, якої ця
        # зміна навмисно уникає) — targeted, один файл.
        $remoteInfo = $Session.GetFileInfo($remoteFullPath)
        if ($null -eq $remoteInfo -or [int64]$remoteInfo.Length -ne [int64]$Entry.Size) {
            return [pscustomobject]@{
                RelativePath = $Entry.RelativePath; Success = $false; Outcome = 'Failed'
                Error = "remote розмір не збігається після передачі (очікувалось $($Entry.Size))"; Bytes = 0; RemoteSize = $null
            }
        }
        return [pscustomobject]@{ RelativePath = $Entry.RelativePath; Success = $true; Outcome = 'Uploaded'; Error = $null; Bytes = [int64]$Entry.Size; RemoteSize = [int64]$Entry.Size }
    } catch {
        return [pscustomobject]@{ RelativePath = $Entry.RelativePath; Success = $false; Outcome = 'Failed'; Error = $_.Exception.Message; Bytes = 0; RemoteSize = $null }
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
        # P2 (deep review): IncompatibleFiles — кандидати, чиє ім'я/каталог
        # порушує SFTP-обмеження довжини (Test-BRAVOBazaRemoteNameCompatibility)
        # — НЕ upload-яться і НЕ рахуються як Failed/PendingWithinCutoff
        # (це не транзієнтна помилка передачі, перезапуск сам по собі
        # нічого не виправить, доки оператор не скоротить ім'я).
        IncompatibleFiles = @()
        # P1 (hardening round 3): захист від перезапису наявних remote-файлів.
        # RecoveredRemote — кандидати, чий remote-шлях уже існував із ТИМ
        # САМИМ розміром (типово: crash-вікно "PutFiles встиг, Save-State ні")
        # — визнані Verified без повторної передачі. RemoteConflicts —
        # кандидати, чий remote-шлях зайнятий файлом ІНШОГО розміру:
        # перезапис заборонено, кожен запис несе RelativePath/LocalSize/
        # RemoteSize.
        RecoveredRemote = 0
        RemoteConflicts = @()
        # P1 (round 4): кандидати, яких ПОТОЧНИЙ Full Audit позначив
        # pending, але їхній remote-шлях зайнятий — generic same-size
        # recovery для них заборонено (Action/Reason з audit + розміри).
        AuditDriftFiles = @()
        # P2 (round 4): відносні шляхи, ПРИСУТНІ у знімку цього циклу
        # (cutoff-membership) — health-time NewAfterCutoff рахує лише
        # файли, яких НЕ БУЛО в знімку, а не "відсутні в persisted state"
        # (несумісні/конфліктні кандидати свідомо не потрапляють у state,
        # але вони існували ДО cutoff і новими не є).
        # P2 (round 5): $null — СЕНТИНЕЛ "знімок недоступний" (цикл не
        # дійшов до знімка або результат синтетичний) -> fallback на
        # persisted state; @() — ВАЛІДНИЙ знімок порожнього каталогу,
        # membership авторитетний (порожній != недоступний).
        CutoffSnapshotRelativePaths = $null
        Status = 'ERROR'
        Error = $null
        Bootstrap = $false
        # P1-3/SKIPPED_CONCURRENT hardening: останній ПІДТВЕРДЖЕНИЙ успішний
        # цикл за даними persisted state (не обов'язково ЦЬОГО результату —
        # для SKIPPED_CONCURRENT це єдиний доступний сигнал "чи є взагалі
        # чому довіряти").
        LastSuccessfulSyncUtc = $null
        # P2 (deep review): видимість періодичного Full Audit — раніше
        # провал НЕ-bootstrap Full Audit залишав LastFullAuditUtc
        # застарілим, але СЛІД цього в SyncResult зникав повністю.
        FullAuditAttempted = $false
        FullAuditSucceeded = $false
        FullAuditError = $null
        LastFullAuditUtc = $null
        # P2 (deep review): видимість публікації remote checkpoint — раніше
        # Write-BRAVOBazaRemoteCheckpoint викликався як [void](...), і
        # Health не мав жодного способу дізнатися, чи публікація вдалась.
        CheckpointAttempted = $false
        CheckpointPublished = $false
        CheckpointError = $null
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
            PendingItems = @()
        }
    }

    # Обидві сторони порівняння нормалізуються ЧЕРЕЗ ТУ САМУ функцію
    # (GetFullPath), а не лише корінь: production PendingFiles[].Path
    # (Get-BAZASFTPComparison) будується через Join-Path $LocalPath
    # $childPath — без канонізації. Якщо нормалізувати лише $normalizedRoot,
    # а pendingFile.Path лишити як є, префіксне порівняння могло мовчки не
    # спрацювати на будь-якому non-canonical вхідному $LocalDirectory
    # (кінцевий "\", змішані роздільники) — файл тоді помилково потрапляв
    # би в "already matching" замість "pending", і drift не виявлявся б.
    $normalizedRoot = ([IO.Path]::GetFullPath($LocalDirectory)).TrimEnd('\', '/')
    $pendingRelativePaths = New-Object System.Collections.Generic.HashSet[string]
    # P1 (round 4): pending-вердикт БІЛЬШЕ НЕ втрачається редукцією до
    # "already matching": PendingItems зберігає RelativePath + Action
    # (UploadNew/UploadUpdate з WinSCP ComparisonDifference) + Reason, щоб
    # цикл, який щойно отримав audit-вердикт, міг заборонити generic
    # AlreadyRemote same-size recovery для явно pending кандидатів.
    $pendingItems = New-Object System.Collections.Generic.List[object]
    foreach ($pendingFile in $PendingFiles) {
        if ([bool]$pendingFile.IsDirectory) { continue }
        $rawPath = [string]$pendingFile.Path
        if ([string]::IsNullOrWhiteSpace($rawPath)) { continue }
        $absolutePath = try { [IO.Path]::GetFullPath($rawPath) } catch { $rawPath }
        if (-not $absolutePath.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $relative = $absolutePath.Substring($normalizedRoot.Length).TrimStart('\', '/')
        [void]$pendingRelativePaths.Add($relative)
        $pendingAction = if ($null -ne $pendingFile.PSObject.Properties['Action']) { [string]$pendingFile.Action } else { $null }
        $pendingReason = if ($null -ne $pendingFile.PSObject.Properties['Reason']) { [string]$pendingFile.Reason } else { $null }
        [void]$pendingItems.Add([pscustomobject]@{
            RelativePath = $relative
            Action = $pendingAction
            Reason = $pendingReason
        })
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
        PendingItems = $pendingItems.ToArray()
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

    # Спільні прапорці, що заповнюються ОБОМА гілками нижче (пошкоджений
    # стан -> реконсиляція, або звичайний шлях -> можливий bootstrap/
    # periodic audit), і читаються уніфіковано після if/else.
    $isFirstRun = $false
    $state = $null
    $snapshot = $null
    $bootstrapPerformed = $false
    $fullAuditAttemptedThisCycle = $false
    $fullAuditSucceededThisCycle = $false
    $fullAuditErrorThisCycle = $null
    # P1 (round 4): вердикт Full Audit ЦЬОГО циклу — RelativePath ->
    # PendingItem (Action/Reason). Кандидат, якого ПОТОЧНИЙ audit явно
    # позначив pending (напр. UploadUpdate: той самий розмір, інший mtime),
    # НЕ має права на generic AlreadyRemote same-size recovery — інакше
    # цикл мовчки скасовував би щойно отриманий audit-вердикт. Мапа
    # СВІДОМО scope-иться на поточний цикл (вердикти не персистяться в
    # state) — між аудитами діє звичайна round-3 семантика.
    $currentAuditPendingByPath = @{}

    if ($stateRead.Corrupt) {
        # P1-4 (deep review): пошкоджений/несумісний стан раніше ЗАВЖДИ
        # повертав STATE_INVALID негайно, ще ДО того, як -ForceFullAudit/
        # -BootstrapIfNeeded/FullAuditProvider взагалі мали шанс щось
        # виправити — OPERATIONS хибно стверджував, що "наступний Full
        # Audit відновить стан", хоча виконання НІКОЛИ туди не доходило.
        if (-not $BootstrapIfNeeded -or $null -eq $FullAuditProvider) {
            # Health / no recovery authorization: без ОБОХ прапорців немає
            # звідки взяти нове довірене джерело істини — контрольована
            # відмова, старі файли НІКОЛИ не вважаються automatically
            # verified.
            $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $startedUtc
            $result.Status = 'STATE_INVALID'
            $result.Error = "стан BAZA пошкоджено або несумісний ($statePath): $($stateRead.Reason). Потрібна повна реконсиляція (Full Audit) — старі файли НЕ вважаються автоматично verified."
            $result.CompletedUtc = (Get-Date).ToUniversalTime()
            return $result
        }

        # Archive / explicit reconciliation path: ОБИДВА -BootstrapIfNeeded
        # і FullAuditProvider присутні — контрольоване відновлення.
        $recoverySnapshot = Get-BRAVOBazaLocalSnapshot -LocalDirectory $LocalDirectory
        if (-not $recoverySnapshot.Success) {
            $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $startedUtc
            $result.Status = 'STATE_INVALID'
            $result.Error = "стан пошкоджено ($($stateRead.Reason)); реконсиляцію не вдалося навіть розпочати — не вдалося прочитати локальний каталог: $($recoverySnapshot.Error)"
            $result.CompletedUtc = (Get-Date).ToUniversalTime()
            return $result
        }
        $fullAuditAttemptedThisCycle = $true
        $recoveryAudit = & $FullAuditProvider $recoverySnapshot
        if (-not $recoveryAudit.Success) {
            # Стара пошкоджена evidence лишається НЕТОРКНУТОЮ на
            # канонічному шляху (ми ще НЕ карантинили її — карантин лише
            # на успішному шляху нижче). Наступне читання знову побачить
            # Corrupt=true, доки причину провалу Full Audit не усунуто.
            $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $recoverySnapshot.SnapshotUtc
            $result.Status = 'STATE_INVALID'
            $result.Error = "стан пошкоджено ($($stateRead.Reason)); реконсиляція через Full Audit також не вдалася: $($recoveryAudit.Error). Стара evidence збережена без змін ($statePath) — жоден файл не вважається verified."
            $result.FullAuditAttempted = $true
            $result.FullAuditSucceeded = $false
            $result.FullAuditError = [string]$recoveryAudit.Error
            $result.CompletedUtc = (Get-Date).ToUniversalTime()
            return $result
        }

        # Full Audit успішний — карантинимо СТАРИЙ пошкоджений файл
        # (forensic evidence; best-effort — провал карантину НЕ зупиняє
        # реконсиляцію, бо Save-BRAVOBazaState нижче однаково атомарно
        # перезапише канонічний шлях новим, довіреним станом) і будуємо
        # СВІЖИЙ стан ВИКЛЮЧНО з audit result — жоден запис зі старого
        # (пошкодженого, отже недовіреного) файлу не переноситься.
        $quarantinePath = Join-Path (Split-Path -Path $statePath -Parent) (
            '{0}.state.corrupt.{1}.json' -f $Component, $startedUtc.ToString('yyyyMMdd_HHmmss')
        )
        try {
            if ([IO.File]::Exists($statePath)) {
                [IO.File]::Move($statePath, $quarantinePath)
            }
        } catch {
            # Best-effort forensic copy — див. коментар вище.
        }

        $state = New-BRAVOBazaEmptyState -Component $Component
        foreach ($matchedRelativePath in $recoveryAudit.AlreadyMatchingRelativePaths) {
            $state.Files[$matchedRelativePath] = [pscustomobject]@{
                Size = $recoveryAudit.LocalSizes[$matchedRelativePath]
                LastWriteTimeUtc = $recoveryAudit.LastWriteTimesUtc[$matchedRelativePath]
                UploadedUtc = $startedUtc.ToString('o')
                Verified = $true
            }
        }
        $state.LastFullAuditUtc = $startedUtc.ToString('o')
        $isFirstRun = $false
        $bootstrapPerformed = $true
        $fullAuditSucceededThisCycle = $true
        if ($null -ne $recoveryAudit.PSObject.Properties['PendingItems']) {
            foreach ($auditPendingItem in @($recoveryAudit.PendingItems)) {
                if ($null -eq $auditPendingItem) { continue }
                $currentAuditPendingByPath[[string]$auditPendingItem.RelativePath] = $auditPendingItem
            }
        }
        $snapshot = $recoverySnapshot
    } else {
        $isFirstRun = -not $stateRead.Exists

        # P1-1 (deep review): без -BootstrapIfNeeded (типовий standalone
        # Health fallback, де bootstrap лишається виключною
        # відповідальністю Archive) перший запуск раніше мовчки провалювався
        # у порожній $state -> Get-BRAVOBazaSyncPlan, де КОЖЕН локальний
        # файл виглядав би як "новий" -> ToUpload — для 50+ ГБ дерева це
        # означало б спробу standalone Health перезавантажити ВСЕ заново.
        # Контрольована відмова ДО планувальника/upload — жодного
        # PutFiles-виклику, UploadInvocationCount=0.
        if ($isFirstRun -and -not $BootstrapIfNeeded) {
            $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $startedUtc
            $result.Status = 'STATE_NOT_INITIALIZED'
            $result.Error = "$Component — incremental стан не ініціалізовано ($statePath). Спершу виконайте bootstrap через BRAVO_ARCHIV/BAZA."
            $result.CompletedUtc = (Get-Date).ToUniversalTime()
            return $result
        }

        $state = if ($stateRead.Exists) { $stateRead.State } else { New-BRAVOBazaEmptyState -Component $Component }

        # Знімок ОДИН для всього циклу (і для bootstrap seed, і для плану,
        # і як сам Cutoff) — узгодженість: bootstrap ніколи не бачить
        # ІНШИЙ перелік каталогу, ніж той, що потім планується до upload.
        $snapshot = Get-BRAVOBazaLocalSnapshot -LocalDirectory $LocalDirectory
        if (-not $snapshot.Success) {
            $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $startedUtc
            $result.Status = 'ERROR'
            $result.Error = "не вдалося прочитати локальний каталог: $($snapshot.Error)"
            $result.CompletedUtc = (Get-Date).ToUniversalTime()
            return $result
        }

        # Full Audit тригериться або на першому запуску (bootstrap, ТЗ
        # п.15), або періодично, коли попередній Full Audit застарів (ТЗ
        # п.12/13: "Full Audit НЕ запускати після кожного Archive/Health" —
        # тому це виключно ВІК останнього LastFullAuditUtc, а не кожен
        # цикл). FullAuditEveryDays <= 0 вимикає періодичний шлях;
        # лишається лише bootstrap першого запуску.
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
            # "прострочено" — консервативно, а не мовчки пропускається
            # назавжди.
            if ($null -eq $lastFullAuditUtc) {
                $fullAuditOverdue = $true
            } else {
                $fullAuditOverdue = ($startedUtc - $lastFullAuditUtc).TotalDays -ge $FullAuditEveryDays
            }
        }

        if (($isFirstRun -or $fullAuditOverdue) -and $BootstrapIfNeeded) {
            # Bootstrap/періодичний Full Audit: одна дорога Full Audit
            # (повне порівняння), щоб НЕ завантажувати повторно файли, які
            # вже фактично є на SFTP (ТЗ п.15), і щоб виявити дрейф (напр.
            # хтось вручну видалив файл на SFTP) — seed/refresh VERIFIED-
            # записів для того, що вже збігається, без жодного upload для
            # них.
            if ($null -eq $FullAuditProvider) {
                if ($isFirstRun) {
                    $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $snapshot.SnapshotUtc
                    $result.Status = 'ERROR'
                    $result.Error = 'перший запуск без persisted state вимагає bootstrap Full Audit, але FullAuditProvider не передано'
                    $result.CompletedUtc = (Get-Date).ToUniversalTime()
                    return $result
                }
                # Періодичний Full Audit прострочено, але провайдера немає
                # (напр. виклик з Health, де bootstrap/Full Audit свідомо
                # не передається — Archive's exclusive responsibility). Це
                # НЕ помилка цього циклу: incremental sync продовжується
                # без audit, а прострочення лишається до наступного разу,
                # коли виклик матиме провайдера.
            } else {
                $fullAuditAttemptedThisCycle = $true
                $auditResult = & $FullAuditProvider $snapshot
                if (-not $auditResult.Success) {
                    $fullAuditErrorThisCycle = [string]$auditResult.Error
                    if ($isFirstRun) {
                        $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $snapshot.SnapshotUtc
                        $result.Status = 'ERROR'
                        $result.Error = "bootstrap Full Audit не вдався: $($auditResult.Error)"
                        $result.FullAuditAttempted = $true
                        $result.FullAuditSucceeded = $false
                        $result.FullAuditError = $fullAuditErrorThisCycle
                        $result.CompletedUtc = (Get-Date).ToUniversalTime()
                        return $result
                    }
                    # Періодичний (не-bootstrap) Full Audit, що провалився,
                    # не має блокувати вже-працюючий incremental sync —
                    # стан і далі вважається валідним, LastFullAuditUtc НЕ
                    # оновлюється (наступний цикл спробує знову), але це
                    # ПОВИННО бути видимим у SyncResult (P2 review) — не
                    # зникати мовчки.
                } else {
                    $fullAuditSucceededThisCycle = $true
                    if ($null -ne $auditResult.PSObject.Properties['PendingItems']) {
                        foreach ($auditPendingItem in @($auditResult.PendingItems)) {
                            if ($null -eq $auditPendingItem) { continue }
                            $currentAuditPendingByPath[[string]$auditPendingItem.RelativePath] = $auditPendingItem
                        }
                    }
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
                    # Дрейф-реконсиляція: файл, який РАНІШЕ був Verified=true
                    # в state, але повний audit (напр. хтось вручну видалив
                    # його на SFTP) НЕ підтвердив його серед
                    # AlreadyMatchingRelativePaths — це саме "старий
                    # remote-об'єкт зник" (ТЗ п.13). Скидаємо Verified, щоб
                    # звичайний incremental-план цього ж циклу підхопив
                    # його як ToUpload — без цього периодичний Full Audit
                    # був би лише "seed", а не справжньою реконсиляцією.
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
    }

    $cutoffUtc = $snapshot.SnapshotUtc
    $plan = Get-BRAVOBazaSyncPlan -Snapshot $snapshot -State $state -MutationPolicy $MutationPolicy

    $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $cutoffUtc
    $result.Bootstrap = $bootstrapPerformed
    $result.DiscoveredWithinCutoff = $snapshot.Entries.Count
    $result.CutoffSnapshotRelativePaths = @($snapshot.Entries.Keys)
    $result.AlreadyVerified = $plan.TrustedSkip.Count
    $result.MutationViolations = $plan.MutationViolations
    $result.FullAuditAttempted = $fullAuditAttemptedThisCycle
    $result.FullAuditSucceeded = $fullAuditSucceededThisCycle
    $result.FullAuditError = $fullAuditErrorThisCycle
    $result.LastFullAuditUtc = $state.LastFullAuditUtc

    $uploadedCount = 0
    $uploadedBytes = [int64]0
    $recoveredRemoteCount = 0
    $failedFiles = New-Object System.Collections.Generic.List[object]
    $incompatibleFiles = New-Object System.Collections.Generic.List[object]
    $remoteConflicts = New-Object System.Collections.Generic.List[object]
    $auditDriftFiles = New-Object System.Collections.Generic.List[object]

    foreach ($candidate in $plan.ToUpload) {
        # P2 (deep review): SFTP filename-compatibility — локальна ЛИШЕ
        # перевірка (жоден remote listing, жоден зайвий stat), рахується
        # лише для candidates у ToUpload, НЕ для сотень тисяч уже Verified
        # файлів.
        $nameCompatibility = Test-BRAVOBazaRemoteNameCompatibility -RelativePath $candidate.RelativePath
        if (-not $nameCompatibility.Compatible) {
            $incompatibleFiles.Add([pscustomobject]@{ RelativePath = $candidate.RelativePath; Reason = $nameCompatibility.Reason })
            # НЕ upload, НЕ Verified=false-pending-retry-forever: ім'я не
            # стане сумісним само по собі, повторна спроба передачі
            # безглузда, доки оператор не скоротить ім'я локально. Стан
            # для нього НЕ записується — наступний цикл побачить того
            # самого кандидата знову (видимий щоразу, точне ім'я в
            # повідомленні), без хибних "upload failed" повідомлень про
            # мережеву/SFTP помилку, якої насправді не було.
            continue
        }
        $candidateAuditPending = $currentAuditPendingByPath[$candidate.RelativePath]
        # P1 (round 5): audit-вердикт СТІЙКИЙ між циклами. Раніше заборона
        # generic recovery жила лише в пам'яті циклу, в якому audit
        # виконався: НАСТУПНИЙ звичайний цикл (без власного аудиту) бачив
        # Verified=false, remote same-size — і мовчки "відновлював" файл,
        # скасовуючи авторитетний вердикт попереднього Full Audit
        # (false-green вікно до наступного планового аудиту). Тепер
        # AUDIT_DRIFT персистує мінімальний блокер у state-записі шляху —
        # звичайні unverified/pending записи (без BlockReason) лишаються
        # придатними до звичайного crash-recovery.
        $candidateStateEntry = $state.Files[$candidate.RelativePath]
        $persistedAuditBlock = (
            $null -ne $candidateStateEntry -and
            $null -ne $candidateStateEntry.PSObject.Properties['BlockReason'] -and
            [string]$candidateStateEntry.BlockReason -eq 'AuditDrift'
        )
        $recoveryDisallowed = ($null -ne $candidateAuditPending) -or $persistedAuditBlock
        $uploadOutcome = Invoke-BRAVOBazaFileUpload -Session $Session -Entry $candidate -LocalDirectory $LocalDirectory -RemoteRootPath $RemoteRootPath -DisallowExistingRemoteRecovery:$recoveryDisallowed
        if ($uploadOutcome.Outcome -eq 'AuditDrift') {
            $blockAction = if ($null -ne $candidateAuditPending) {
                $candidateAuditPending.Action
            } elseif ($persistedAuditBlock -and $null -ne $candidateStateEntry.PSObject.Properties['AuditAction']) {
                [string]$candidateStateEntry.AuditAction
            } else { $null }
            $blockReasonText = if ($null -ne $candidateAuditPending) {
                $candidateAuditPending.Reason
            } elseif ($persistedAuditBlock -and $null -ne $candidateStateEntry.PSObject.Properties['AuditReason']) {
                [string]$candidateStateEntry.AuditReason
            } else { $null }
            $blockDetectedUtc = if ($persistedAuditBlock -and $null -ne $candidateStateEntry.PSObject.Properties['AuditDetectedUtc'] -and
                -not [string]::IsNullOrWhiteSpace([string]$candidateStateEntry.AuditDetectedUtc)) {
                # Первинна дата виявлення дрейфу зберігається — доказ віку
                # проблеми, а не дата останнього повторного спрацювання.
                [string]$candidateStateEntry.AuditDetectedUtc
            } else {
                $startedUtc.ToString('o')
            }
            $auditDriftFiles.Add([pscustomobject]@{
                RelativePath = $candidate.RelativePath
                Action = $blockAction
                Reason = $blockReasonText
                LocalSize = [int64]$candidate.Size
                RemoteSize = $uploadOutcome.RemoteSize
                Error = $uploadOutcome.Error
            })
            # Персистуємо блокер (Verified=false + мінімальний audit-доказ).
            # Очищення — ЛИШЕ позитивною розв'язкою: (A) пізніший Full
            # Audit підтвердив збіг — seed перезапише запис начисто; або
            # (B) remote зник — успішний targeted upload + верифікація
            # перезапишуть запис як Verified=true. Збіг розміру НІКОЛИ не
            # очищає блокер — саме цей доказ попередній audit уже визнав
            # недостатнім.
            $state.Files[$candidate.RelativePath] = [pscustomobject]@{
                Size = $candidate.Size
                LastWriteTimeUtc = $candidate.LastWriteTimeUtc
                UploadedUtc = $null
                Verified = $false
                BlockReason = 'AuditDrift'
                AuditAction = $blockAction
                AuditReason = $blockReasonText
                AuditDetectedUtc = $blockDetectedUtc
            }
        } elseif ($uploadOutcome.Outcome -eq 'AlreadyRemote') {
            # P1 (round 3): remote-файл уже існує з тим самим розміром —
            # crash-recovery випадок (upload попереднього циклу пройшов, а
            # state тоді не зберігся). Визнаємо Verified БЕЗ повторної
            # передачі — нуль PutFiles, наявний файл не перезаписується.
            $recoveredRemoteCount++
            $state.Files[$candidate.RelativePath] = [pscustomobject]@{
                Size = $candidate.Size
                LastWriteTimeUtc = $candidate.LastWriteTimeUtc
                UploadedUtc = (Get-Date).ToUniversalTime().ToString('o')
                Verified = $true
            }
        } elseif ($uploadOutcome.Outcome -eq 'RemoteConflict') {
            # P1 (round 3): remote-шлях зайнятий файлом ІНШОГО розміру —
            # перезапис заборонено. Стан для кандидата НЕ пишеться (як і
            # для несумісних імен): наступний цикл знову побачить конфлікт
            # тією самою цільовою перевіркою, доки оператор не вирішить.
            $remoteConflicts.Add([pscustomobject]@{
                RelativePath = $candidate.RelativePath
                LocalSize = [int64]$candidate.Size
                RemoteSize = $uploadOutcome.RemoteSize
                Error = $uploadOutcome.Error
            })
        } elseif ($uploadOutcome.Success) {
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
    $result.RecoveredRemote = $recoveredRemoteCount
    $result.Failed = $failedFiles.Count
    $result.FailedFiles = $failedFiles.ToArray()
    $result.PendingWithinCutoff = $failedFiles.Count
    $result.IncompatibleFiles = $incompatibleFiles.ToArray()
    $result.RemoteConflicts = $remoteConflicts.ToArray()
    $result.AuditDriftFiles = $auditDriftFiles.ToArray()

    $completedUtc = (Get-Date).ToUniversalTime()
    $result.CompletedUtc = $completedUtc

    if ($failedFiles.Count -gt 0) {
        $result.Status = 'INCOMPLETE'
    } elseif ($plan.MutationViolations.Count -gt 0 -and $MutationPolicy -eq 'Fail') {
        $result.Status = 'MUTATION_VIOLATION'
    } elseif ($auditDriftFiles.Count -gt 0) {
        # P1 (round 4): audit-вердикт не скасовано, але й не виконано —
        # явний не-COMPLETE статус: provenance не просувається, checkpoint
        # не публікується, Health -> CRITICAL. LastFullAuditUtc при цьому
        # МІГ просунутись вище (audit УСПІШНО завершився і виявив drift) —
        # це свіжість аудиту, НЕ успішність синхронізації.
        $result.Status = 'AUDIT_DRIFT'
        $auditDriftPreview = @(
            $auditDriftFiles | Select-Object -First 3 | ForEach-Object {
                "$($_.RelativePath) [$($_.Action)] (local $($_.LocalSize) байт, remote $($_.RemoteSize) байт)"
            }
        ) -join '; '
        $result.Error = (
            "$($auditDriftFiles.Count) кандидат(ів) позначені поточним Full Audit як pending, але їхні remote-шляхи вже зайняті: " +
            "$auditDriftPreview — перезапис заборонено, generic same-size recovery не застосовується, цикл не вважається успішним"
        )
    } elseif ($remoteConflicts.Count -gt 0) {
        # P1 (round 3): конфлікт із наявним remote-файлом іншого розміру —
        # явний не-COMPLETE статус: provenance успішного циклу не
        # просувається, checkpoint не публікується, Health -> CRITICAL.
        $result.Status = 'REMOTE_CONFLICT'
        $conflictPreview = @(
            $remoteConflicts | Select-Object -First 3 | ForEach-Object {
                "$($_.RelativePath) (local $($_.LocalSize) байт, remote $($_.RemoteSize) байт)"
            }
        ) -join '; '
        $result.Error = (
            "$($remoteConflicts.Count) кандидат(ів) конфліктують з уже наявними remote-файлами іншого розміру: " +
            "$conflictPreview — перезапис заборонено append-only контрактом, цикл не вважається успішним"
        )
    } elseif ($incompatibleFiles.Count -gt 0) {
        # P1 (hardening round 2): несумісні імена НЕ дають успішного циклу.
        # Раніше Failed=0 при пропущених несумісних кандидатах давав
        # COMPLETE: LastSuccessfulSyncUtc просувався і публікувався
        # "успішний" checkpoint, хоча частину даних свідомо НЕ передано.
        # Явний статус (а не INCOMPLETE) — щоб оператор одразу бачив
        # причину: це не мережевий збій, а імена, які треба скоротити.
        # Provenance успішного циклу (LastCycleId/LastSuccessfulSyncUtc)
        # НЕ просувається; checkpoint не публікується (gate на COMPLETE у
        # Invoke-BRAVOBazaComponentSyncSession); сумісні файли цього ж
        # циклу передано і закомічено в state вище — повторно вони не
        # передаватимуться.
        $result.Status = 'INCOMPATIBLE_NAME'
        $incompatibleNamesPreview = @(
            $incompatibleFiles | Select-Object -First 3 | ForEach-Object { $_.RelativePath }
        ) -join ', '
        $result.Error = (
            "$($incompatibleFiles.Count) кандидат(ів) не передано через несумісні з SFTP імена " +
            "(напр.: $incompatibleNamesPreview) — цикл не вважається успішним"
        )
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

    # P1-3/SKIPPED_CONCURRENT hardening: LastSuccessfulSyncUtc З ЦЬОГО
    # стану (після можливого оновлення вище) — доступний навіть коли
    # ЦЕЙ цикл сам не COMPLETE, як довідка "коли востаннє точно вдалось".
    $result.LastSuccessfulSyncUtc = $state.LastSuccessfulSyncUtc

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
    #
    # P2 (deep review): результат більше НЕ [bool] — виклик-точка раніше
    # обгортала виклик у [void](...) і повністю викидала результат: Health
    # не мав способу дізнатись, чи публікація насправді вдалась
    # ("write-only" checkpoint). Тепер повертається структурований
    # Attempted/Published/Error, який Invoke-BRAVOBazaComponentSyncSession
    # переносить у SyncResult.
    #
    # Публікація через ТИМЧАСОВЕ remote-ім'я + явна заміна (P2, hardening
    # round 2): вміст завжди спершу ПОВНІСТЮ лягає під тимчасовим іменем —
    # канонічний шлях ніколи не містить частково записаного JSON (crash/
    # розрив мережі посеред PutFiles напряму в .bravo-sync.json лишив би
    # там обрізаний файл). Далі, якщо канонічний checkpoint від
    # попереднього циклу ВЖЕ існує, він явно видаляється перед
    # MoveFile(temp -> canonical): SFTP-rename переносимо НЕ гарантує
    # перезапису наявної цілі (перший цикл проходив, а кожен наступний
    # падав би на rename). Свідомо НЕ заявляємо атомарності заміни:
    # generic SFTP її не дає, а checkpoint — write-only телеметрія для
    # зовнішнього спостерігача, НЕ джерело correctness для Health. Вікно
    # неатомарності вузьке і чесне: між RemoveFiles та MoveFile читач може
    # побачити checkpoint ВІДСУТНІМ — але ніколи частковим.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$RemoteRootPath,
        [Parameter(Mandatory = $true)][object]$SyncResult
    )
    if ($SyncResult.Status -ne 'COMPLETE') {
        return [pscustomobject]@{ Attempted = $false; Published = $false; Error = $null }
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
        $canonicalRemoteCheckpointPath = ($RemoteRootPath.TrimEnd('/') + '/' + (Get-BRAVOBazaRemoteCheckpointName))
        $temporaryRemoteCheckpointPath = ($RemoteRootPath.TrimEnd('/') + '/.bravo-sync.json.tmp-' + [guid]::NewGuid().ToString('N'))
        $transferOptions = New-Object WinSCP.TransferOptions
        $transferOptions.TransferMode = [WinSCP.TransferMode]::Binary
        $transferResult = $Session.PutFiles($tempLocalPath, $temporaryRemoteCheckpointPath, $false, $transferOptions)
        if (-not $transferResult.IsSuccess) {
            return [pscustomobject]@{ Attempted = $true; Published = $false; Error = 'не вдалося завантажити тимчасовий checkpoint' }
        }
        try {
            # Явна заміна попереднього checkpoint: RemoveFiles лише для
            # ВЛАСНОГО телеметрійного файлу двигуна — жодні дані бекапів
            # цим шляхом не видаляються ніколи. P2 (round 3): результат
            # RemoveFiles НЕ відкидається — WinSCP репортує per-file збої в
            # RemovalOperationResult без винятку; ігнорування означало б
            # "заміна вдалася", хоча стара ціль лишилась і MoveFile нижче
            # впаде або, гірше, репортнеться неправда.
            if ([bool]$Session.FileExists($canonicalRemoteCheckpointPath)) {
                $canonicalRemovalResult = $Session.RemoveFiles($canonicalRemoteCheckpointPath)
                if ($null -eq $canonicalRemovalResult -or -not [bool]$canonicalRemovalResult.IsSuccess) {
                    try { [void]$Session.RemoveFiles($temporaryRemoteCheckpointPath) } catch {
                        # Best-effort cleanup tmp-файлу: першопричина (збій
                        # видалення попереднього checkpoint) важливіша.
                    }
                    return [pscustomobject]@{
                        Attempted = $true; Published = $false
                        Error = 'не вдалося прибрати попередній checkpoint перед заміною — заміну НЕ виконано, канонічний шлях лишився зі старим checkpoint'
                    }
                }
            }
            $Session.MoveFile($temporaryRemoteCheckpointPath, $canonicalRemoteCheckpointPath)
        } catch {
            # Заміна не вдалася — прибираємо тимчасовий файл (best-effort),
            # щоб не лишати сміття на SFTP; checkpoint вважається
            # неопублікованим.
            try { [void]$Session.RemoveFiles($temporaryRemoteCheckpointPath) } catch {
                # Best-effort cleanup: збій прибирання tmp-файлу не
                # важливіший за ПЕРШУ помилку (збій заміни), яку повертаємо
                # нижче. Осиротілий .tmp-* на SFTP нешкідливий.
            }
            return [pscustomobject]@{ Attempted = $true; Published = $false; Error = "не вдалося замінити checkpoint на канонічному імені: $($_.Exception.Message)" }
        }
        return [pscustomobject]@{ Attempted = $true; Published = $true; Error = $null }
    } catch {
        return [pscustomobject]@{ Attempted = $true; Published = $false; Error = $_.Exception.Message }
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

    if ($SyncResult.Status -notin @('COMPLETE', 'INCOMPLETE', 'MUTATION_VIOLATION', 'INCOMPATIBLE_NAME', 'REMOTE_CONFLICT', 'AUDIT_DRIFT')) {
        # ERROR/STATE_INVALID: стан ненадійний або синхронізація взагалі не
        # відбулась — NewAfterCutoff тут не має сенсу, лишаємо 0.
        # INCOMPATIBLE_NAME/REMOTE_CONFLICT/AUDIT_DRIFT дозволені: цикл
        # реально відбувся і state збережено — локальна діагностика "скільки
        # файлів з'явилось після cutoff" для них так само валідна.
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

    # P2 (round 4): cutoff-membership — ЧЛЕНСТВО У ЗНІМКУ ЦЬОГО ЦИКЛУ, а
    # не "відсутність у persisted state". Несумісні/конфліктні/audit-drift
    # кандидати свідомо НЕ записуються в state, але вони існували ДО
    # cutoff — "новими після cutoff" вони не є. І навпаки: файл, доданий
    # ПІСЛЯ знімка з навмисно старим LastWriteTime (backdated), у знімку
    # відсутній — отже, рахується (timestamp ніколи не є критерієм
    # членства).
    # P2 (round 5): "порожній знімок" != "знімка немає". $null у
    # CutoffSnapshotRelativePaths — сентинел "недоступно" (лише тоді
    # fallback на persisted state); @() — валідний знімок ПОРОЖНЬОГО
    # каталогу, membership авторитетний: файл, що з'явився після такого
    # cutoff, рахується новим навіть якщо старий persisted state ще
    # пам'ятає його з давніших циклів.
    $cutoffSnapshotCaptured = ($null -ne $SyncResult.CutoffSnapshotRelativePaths)
    $cutoffMembership = New-Object System.Collections.Generic.HashSet[string]
    if ($cutoffSnapshotCaptured) {
        foreach ($cutoffSeenPath in @($SyncResult.CutoffSnapshotRelativePaths)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$cutoffSeenPath)) {
                [void]$cutoffMembership.Add([string]$cutoffSeenPath)
            }
        }
    }

    $newCount = 0
    foreach ($relativePath in $freshSnapshot.Entries.Keys) {
        if ($cutoffSnapshotCaptured) {
            if (-not $cutoffMembership.Contains($relativePath)) {
                $newCount++
            }
        } elseif (-not $stateRead.State.Files.ContainsKey($relativePath)) {
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
    #   B. SYNC FAILED (Status != COMPLETE зі своєю причиною) -> ALERT,
    #      "синхронізація не завершена", не "N файлів відсутні";
    #   C. CURRENT CYCLE INCOMPLETE (Failed>0
    #      або PendingWithinCutoff>0)          -> ALERT з деталями what/why.
    #
    # P1-2 (deep review): SUCCESS WHITELIST, не blacklist. Раніше нове/
    # незнайоме значення Status (напр. INCOMPLETE з Failed=0 і
    # PendingWithinCutoff=0 — саме такий стан лишає провал
    # Save-BRAVOBazaState ПІСЛЯ вже успішних uploads) не перехоплювалось
    # ЖОДНИМ if і мовчки провалювалось у фінальну "OK"-гілку. Тепер ЛИШЕ
    # Status=COMPLETE (і без IncompatibleFiles) проходить до звичайної
    # Healthy-оцінки; SKIPPED_CONCURRENT має власну (freshness-aware)
    # гілку; УСЕ інше, включно з будь-яким незнайомим значенням, —
    # Healthy=false. Unknown status fails visible, не fail open.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$SyncResult,
        # SKIPPED_CONCURRENT hardening: "інший процес синхронізує зараз"
        # НЕ є доказом, що хмарна копія актуальна, якщо останній
        # ПІДТВЕРДЖЕНИЙ успішний цикл був давно (або взагалі не було
        # жодного). Той самий порядок величини, що вже усталений в цьому
        # комплекті для "наскільки стара копія — ще нормально"
        # (backupMonitoring.SFTP.RemoteBackupMaxAgeHours = 24 типово).
        [double]$ConcurrentStalenessThresholdHours = 24
    )

    if ($SyncResult.Status -eq 'STATE_INVALID') {
        return [pscustomobject]@{
            Level = 'CRITICAL'; Healthy = $false
            Message = "$($SyncResult.Component): стан синхронізації пошкоджено — потрібна повна реконсиляція. $($SyncResult.Error)"
            Info = @()
        }
    }
    if ($SyncResult.Status -eq 'STATE_NOT_INITIALIZED') {
        return [pscustomobject]@{
            Level = 'CRITICAL'; Healthy = $false
            Message = "$($SyncResult.Component) — incremental стан не ініціалізовано. Спершу виконайте bootstrap через BRAVO_ARCHIV/BAZA. $($SyncResult.Error)"
            Info = @()
        }
    }
    if ($SyncResult.Status -eq 'ERROR') {
        return [pscustomobject]@{
            Level = 'CRITICAL'; Healthy = $false
            Message = "$($SyncResult.Component) — синхронізація не завершена: $($SyncResult.Error)"
            Info = @()
        }
    }
    if ($SyncResult.Status -eq 'SKIPPED_CONCURRENT') {
        # Інший процес (напр. Archive) якраз синхронізує той самий
        # компонент (Enter-BRAVOBazaSyncLock, Classification=Busy, ТЗ
        # п.17) — саме по собі НЕ проблема. Але "хтось зараз працює" і
        # "хмара актуальна" — РІЗНІ твердження: якщо останній підтверджений
        # успішний цикл або відсутній, або застарів, "пропущено цим
        # циклом" не повинно тихо читатися як "усе гаразд".
        $lastSuccessfulSyncUtcRaw = [string]$SyncResult.LastSuccessfulSyncUtc
        $isFresh = $false
        if (-not [string]::IsNullOrWhiteSpace($lastSuccessfulSyncUtcRaw)) {
            try {
                $lastSuccessfulSyncUtc = [DateTime]::Parse(
                    $lastSuccessfulSyncUtcRaw,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind)
                $ageHours = ((Get-Date).ToUniversalTime() - $lastSuccessfulSyncUtc).TotalHours
                $isFresh = ($ageHours -ge 0 -and $ageHours -le $ConcurrentStalenessThresholdHours)
            } catch {
                $isFresh = $false
            }
        }
        if ($isFresh) {
            return [pscustomobject]@{
                Level = 'INFO'; Healthy = $true
                Message = "$($SyncResult.Component) — синхронізацію виконує інший процес одночасно; пропущено цим циклом, останній підтверджений успішний цикл: $lastSuccessfulSyncUtcRaw ($($SyncResult.Error))"
                Info = @()
            }
        }
        # Навмисно НЕ використовується фраза "хмарна копія актуальна" (навіть
        # у запереченні) — рядкове сканування логів/дашбордів за цією
        # фразою не повинно випадково зачепити застережний WARNING як
        # "усе гаразд" (ТЗ: "Do not produce the normal 'хмарна копія
        # актуальна' message for SKIPPED_CONCURRENT").
        return [pscustomobject]@{
            Level = 'WARNING'; Healthy = $false
            Message = (
                "$($SyncResult.Component) — синхронізацію виконує інший процес одночасно, і " +
                $(if ([string]::IsNullOrWhiteSpace($lastSuccessfulSyncUtcRaw)) {
                    "жодного підтвердженого успішного циклу ще не було"
                } else {
                    "останній підтверджений успішний цикл застарів ($lastSuccessfulSyncUtcRaw)"
                }) +
                " — стан хмарної копії цим циклом НЕ підтверджено ($($SyncResult.Error))"
            )
            Info = @()
        }
    }
    # P2 (round 3): якщо в одному циклі співіснують кілька категорій
    # (мутації, remote-конфлікти, несумісні імена) — одна лишається
    # основним Status/Message, але решта НЕ мають зникати до наступного
    # прогону: кожна гілка нижче додає ІНШІ непорожні категорії в Info.
    $mutationSummary = if (@($SyncResult.MutationViolations).Count -gt 0) {
        $names = ($SyncResult.MutationViolations | Select-Object -First 5 | ForEach-Object { $_.RelativePath }) -join ', '
        "append-only мутації: $(@($SyncResult.MutationViolations).Count) файл(ів) ($names)"
    } else { $null }
    $conflictSummary = if (@($SyncResult.RemoteConflicts).Count -gt 0) {
        $names = ($SyncResult.RemoteConflicts | Select-Object -First 5 | ForEach-Object { "$($_.RelativePath) (local $($_.LocalSize) байт, remote $($_.RemoteSize) байт)" }) -join '; '
        "remote-конфлікти розміру: $(@($SyncResult.RemoteConflicts).Count) файл(ів) — $names"
    } else { $null }
    $incompatibleSummary = if (@($SyncResult.IncompatibleFiles).Count -gt 0) {
        $names = ($SyncResult.IncompatibleFiles | Select-Object -First 5 | ForEach-Object { "$($_.RelativePath) ($($_.Reason))" }) -join '; '
        "несумісні з SFTP імена: $(@($SyncResult.IncompatibleFiles).Count) файл(ів) — $names"
    } else { $null }
    $auditDriftSummary = if (@($SyncResult.AuditDriftFiles).Count -gt 0) {
        $names = ($SyncResult.AuditDriftFiles | Select-Object -First 5 | ForEach-Object { "$($_.RelativePath) [$($_.Action)] (local $($_.LocalSize) байт, remote $($_.RemoteSize) байт)" }) -join '; '
        "audit-pending кандидати із зайнятим remote-шляхом: $(@($SyncResult.AuditDriftFiles).Count) файл(ів) — $names"
    } else { $null }

    if ($SyncResult.Status -eq 'MUTATION_VIOLATION') {
        $names = ($SyncResult.MutationViolations | Select-Object -First 5 | ForEach-Object { $_.RelativePath }) -join ', '
        return [pscustomobject]@{
            Level = 'CRITICAL'; Healthy = $false
            Message = "$($SyncResult.Component) — виявлено append-only invariant violation ($($SyncResult.MutationViolations.Count) файл(ів), напр.: $names) — передачу заблоковано, потрібне ручне рішення"
            Info = @(@($auditDriftSummary, $conflictSummary, $incompatibleSummary) | Where-Object { $null -ne $_ })
        }
    }
    if (@($SyncResult.AuditDriftFiles).Count -gt 0) {
        # P1 (round 4): поточний Full Audit позначив кандидата pending, а
        # його remote-шлях зайнятий — вердикт audit не можна мовчки
        # скасувати збігом розміру; точний шлях, audit Action і обидва
        # розміри у повідомленні.
        return [pscustomobject]@{
            Level = 'CRITICAL'; Healthy = $false
            Message = (
                "$($SyncResult.Component) — $(@($SyncResult.AuditDriftFiles).Count) кандидат(ів) позначені поточним Full Audit як pending, але їхні remote-шляхи вже зайняті: " +
                (($SyncResult.AuditDriftFiles | Select-Object -First 5 | ForEach-Object { "$($_.RelativePath) [$($_.Action)] (local $($_.LocalSize) байт, remote $($_.RemoteSize) байт)" }) -join '; ') +
                " — перезапис заборонено, потрібне ручне рішення оператора"
            )
            Info = @(@($mutationSummary, $conflictSummary, $incompatibleSummary) | Where-Object { $null -ne $_ })
        }
    }
    if (@($SyncResult.RemoteConflicts).Count -gt 0) {
        # P1 (round 3): remote-шлях кандидата зайнятий файлом іншого
        # розміру — перезапис заборонено; точний шлях і обидва розміри в
        # повідомленні, щоб оператор бачив, ЩО саме конфліктує.
        return [pscustomobject]@{
            Level = 'CRITICAL'; Healthy = $false
            Message = (
                "$($SyncResult.Component) — $(@($SyncResult.RemoteConflicts).Count) кандидат(ів) конфліктують з уже наявними remote-файлами: " +
                (($SyncResult.RemoteConflicts | Select-Object -First 5 | ForEach-Object { "$($_.RelativePath) (local $($_.LocalSize) байт, remote $($_.RemoteSize) байт)" }) -join '; ') +
                " — перезапис заборонено append-only контрактом, потрібне ручне рішення оператора"
            )
            Info = @(@($mutationSummary, $auditDriftSummary, $incompatibleSummary) | Where-Object { $null -ne $_ })
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
            Info = @(@($mutationSummary, $auditDriftSummary, $conflictSummary, $incompatibleSummary) | Where-Object { $null -ne $_ })
        }
    }
    if (@($SyncResult.IncompatibleFiles).Count -gt 0) {
        $incompatibleNames = ($SyncResult.IncompatibleFiles | Select-Object -First 5 | ForEach-Object { "$($_.RelativePath) ($($_.Reason))" }) -join '; '
        return [pscustomobject]@{
            Level = 'CRITICAL'; Healthy = $false
            Message = (
                "$($SyncResult.Component) — $(@($SyncResult.IncompatibleFiles).Count) файл(ів) не передано через несумісність імені з SFTP " +
                "(потребує ручного скорочення локального імені): $incompatibleNames"
            )
            Info = @(@($mutationSummary, $auditDriftSummary, $conflictSummary) | Where-Object { $null -ne $_ })
        }
    }

    if ($SyncResult.Status -ne 'COMPLETE') {
        # Дійшли сюди з Failed=0, PendingWithinCutoff=0, IncompatibleFiles
        # порожній, АЛЕ Status все одно НЕ COMPLETE — типовий приклад: усі
        # upload УСПІШНІ, але сам Save-BRAVOBazaState провалився
        # (Invoke-BRAVOBazaSynchronization понижує такий цикл до
        # INCOMPLETE саме для цього випадку). "Failed=0" тут НЕ означає
        # "усе гаразд": стан не підтверджено збереженим. Будь-який інший/
        # незнайомий Status так само НЕ проходить мовчки — Healthy=true
        # можливий ЛИШЕ для явного COMPLETE.
        $statusDetail = if ([string]::IsNullOrWhiteSpace([string]$SyncResult.Error)) {
            "Status=$($SyncResult.Status)"
        } else {
            "Status=$($SyncResult.Status): $($SyncResult.Error)"
        }
        return [pscustomobject]@{
            Level = 'CRITICAL'; Healthy = $false
            Message = "$($SyncResult.Component) — синхронізація не в стані COMPLETE, хмарна копія НЕ підтверджена актуальною. $statusDetail"
            Info = @()
        }
    }

    $infoParts = New-Object System.Collections.Generic.List[string]
    if ($SyncResult.NewAfterCutoff -gt 0) {
        [void]$infoParts.Add("нові після cutoff: $($SyncResult.NewAfterCutoff) файл(ів) — будуть передані наступним циклом")
    }
    # P2 (deep review): успішний sync-цикл (Status=COMPLETE) не повинен
    # мовчки звітувати "усе повністю перевірено", коли periodic Full Audit
    # чи checkpoint-публікація цього ж циклу насправді провалились —
    # дані УСЕ ОДНО в хмарі (сам upload успішний), тому це WARNING
    # (Healthy лишається true), а НЕ CRITICAL, але воно МАЄ бути видимим.
    $level = 'OK'
    if ($SyncResult.FullAuditAttempted -and -not $SyncResult.FullAuditSucceeded) {
        $level = 'WARNING'
        [void]$infoParts.Add("періодичний Full Audit цього циклу не вдався: $($SyncResult.FullAuditError)")
    }
    if ($SyncResult.CheckpointAttempted -and -not $SyncResult.CheckpointPublished) {
        $level = 'WARNING'
        [void]$infoParts.Add("публікація remote checkpoint цього циклу не вдалася: $($SyncResult.CheckpointError)")
    }
    return [pscustomobject]@{
        Level = $level; Healthy = $true
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
    #
    # P1-3 (deep review): лише Classification=Busy (genuine sharing
    # violation — інший процес ЗАРАЗ тримає lock) стає SKIPPED_CONCURRENT.
    # Classification=Error (ACL, недоступний каталог стану, зіпсований
    # шлях) — це ERROR: інфраструктурна помилка НІКОЛИ не маскується під
    # "просто інший процес синхронізує".
    $syncLock = Enter-BRAVOBazaSyncLock -StateRoot $StateRoot -Component $Component
    if (-not $syncLock.Success) {
        $result = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $startedUtc
        if ($syncLock.Classification -eq 'Busy') {
            $result.Status = 'SKIPPED_CONCURRENT'
            $result.Error = "інший процес зараз синхронізує $Component ($($syncLock.Path)): $($syncLock.Error)"
            # SKIPPED_CONCURRENT hardening: сам факт "зайнято" не є доказом,
            # що хмарна копія актуальна — читаємо LastSuccessfulSyncUtc
            # (read-only, без lock — читання persisted state не потребує
            # ексклюзивного доступу) для health-time freshness-рішення
            # (Get-BRAVOBazaFastHealthResult).
            try {
                $concurrentStateRead = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $StateRoot -Component $Component)
                if ($concurrentStateRead.Exists -and -not $concurrentStateRead.Corrupt) {
                    $result.LastSuccessfulSyncUtc = $concurrentStateRead.State.LastSuccessfulSyncUtc
                }
            } catch {
                # Читання стану під час SKIPPED_CONCURRENT — best-effort
                # діагностика; провал не повинен перетворювати "зайнято" на
                # щось інше.
            }
        } else {
            $result.Status = 'ERROR'
            $result.Error = "не вдалося отримати lock синхронізації для ${Component}: $($syncLock.Error)"
        }
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
            # P2 (deep review): результат публікації більше НЕ відкидається
            # — Health бачить, чи checkpoint дійсно опублікувався.
            $checkpointOutcome = Write-BRAVOBazaRemoteCheckpoint -Session $session -RemoteRootPath $RemoteRootPath -SyncResult $syncResult
            $syncResult.CheckpointAttempted = $checkpointOutcome.Attempted
            $syncResult.CheckpointPublished = $checkpointOutcome.Published
            $syncResult.CheckpointError = $checkpointOutcome.Error
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
    'Test-BRAVOBazaRemoteNameCompatibility',
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
