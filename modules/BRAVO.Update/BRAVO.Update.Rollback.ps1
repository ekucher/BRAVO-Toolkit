# BRAVO.Update.Rollback — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Відкат операції (ENGINE_DESIGN §7, §9.3): знімок і відновлення version-state,
# Invoke-BRAVORollback (кроки 1–9 §7.3) та відкат clean install
# (Invoke-BRAVOInstallRollback). Кожен крок durable (intent -> side effect ->
# completion у журналі) і безпечно повторюваний: після crash у будь-якій фазі
# повторний виклик приводить до того самого фінального стану.
#
# Функції інших частин (Restore-BRAVOManagedTaskState,
# Invoke-BRAVOSchedulerReconcile, Test-BRAVODeploymentValidation,
# Disable-BRAVOAllManagedTasks) викликаються за іменем.

# Маркер «файлу version-state не існувало» у знімку. Справжній state — JSON, тому
# з цим текстом збігтися не може.
$script:BRAVOVersionStateAbsentMarker = 'BRAVO-VERSION-STATE-ABSENT'
# Скільки спроб відкату дозволено, перш ніж одразу оголошувати Critical (§7.3).
$script:BRAVORollbackMaxAttempts = 3

# ---------------------------------------------------------------------------
# Приватні helper-и
# ---------------------------------------------------------------------------

function Get-BRAVORollbackOperationDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    # operationId входить у шлях: лише GUID, інакше обхід каталогу через '..'.
    if (-not (Test-BRAVOUpdateGuidText -Value $OperationId)) { throw "BRAVO.Update: некоректний operationId '$OperationId'." }
    return (Join-Path (Join-Path $StateRoot 'Operations') $OperationId)
}

function Write-BRAVORollbackBytesAtomic {
    # Атомарний запис ТОЧНИХ байтів (tmp у тому ж каталозі з WriteThrough ->
    # File.Replace або File.Move). Write-BRAVOUpdateFileAtomic приймає текст і
    # перекодує в UTF-8 без BOM, тож для побайтного відновлення state непридатна:
    # знімок мусить повернутися бітово (sha256 == знімку).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )

    $directory = [IO.Path]::GetDirectoryName($Path)
    if ([string]::IsNullOrWhiteSpace($directory)) { throw "BRAVO.Update: шлях має містити каталог: $Path" }
    if (-not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }
    $leaf = [IO.Path]::GetFileName($Path)
    $suffix = [guid]::NewGuid().ToString('N')
    $temporaryPath = [IO.Path]::Combine($directory, ('.{0}_{1}.tmp' -f $leaf, $suffix))
    $backupPath = [IO.Path]::Combine($directory, ('.{0}_{1}.bak' -f $leaf, $suffix))
    $replaced = $false
    try {
        $stream = New-Object System.IO.FileStream($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporaryPath, $Path, $backupPath)
            $replaced = $true
        } else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
        if ($replaced -and [IO.File]::Exists($backupPath)) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-BRAVORollbackBytesSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToUpperInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-BRAVOVersionStateRecordedText {
    # Версія, яку guard вважав би записаною (highestVersionFull, інакше
    # highestVersion). $null, якщо вміст не JSON або без версії: guard теж трактує
    # такий state як «запису немає», а для відкату це означає «пошкоджений».
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    try {
        $text = (New-Object System.Text.UTF8Encoding($false)).GetString($Bytes).TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $parsed = $text | ConvertFrom-Json -ErrorAction Stop
        foreach ($name in @('highestVersionFull', 'highestVersion')) {
            $value = Get-BRAVOUpdatePropertyValue -InputObject $parsed -Name $name
            if (($value -is [string]) -and -not [string]::IsNullOrWhiteSpace($value)) { return [string]$value }
        }
    } catch {
        return $null
    }
    return $null
}

function Set-BRAVOUpdateJournalField {
    <#
    .SYNOPSIS
        Адитивні поля журналу, яких немає в CONTRACTS §8, але потрібні відкату:
        rollbackAttempts, versionState, deployKeys, baseline, createdTasks.
    .DESCRIPTION
        Читає/пише через Write-BRAVOUpdateJournal (валідація + атомарний запис);
        поле, якого ще немає, додається як NoteProperty. Дозволено лише
        перелічені імена: довільні поля журналу не створюються.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][ValidateSet('rollbackAttempts', 'versionState', 'deployKeys', 'baseline', 'createdTasks')][string]$Name,
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )

    if ($null -ne $Journal.PSObject.Properties[$Name]) {
        $Journal.$Name = $Value
    } else {
        Add-Member -InputObject $Journal -MemberType NoteProperty -Name $Name -Value $Value
    }
    [void](Write-BRAVOUpdateJournal -Journal $Journal -StateRoot $StateRoot)
    return $Journal
}

function Invoke-BRAVORollbackFaultPoint {
    # Failure injection відкату (ENGINE_DESIGN §2.3): ключ '<Phase>.<Point>',
    # значення Throw|Crash. Cancel під час відкату ігнорується (rollback не
    # скасовується). Crash кидає виняток з префіксом BRAVOUpdate.SimulatedCrash,
    # який Invoke-BRAVORollback НЕ перехоплює: журнал лишається як є.
    [CmdletBinding()]
    param(
        [AllowNull()]$FaultInjection,
        [Parameter(Mandatory = $true)][string]$Point
    )

    if (($null -eq $FaultInjection) -or ($FaultInjection -isnot [System.Collections.IDictionary])) { return }
    if (-not $FaultInjection.Contains($Point)) { return }
    $mode = [string]$FaultInjection[$Point]
    if ($mode -eq 'Crash') { throw ('BRAVOUpdate.SimulatedCrash: ' + $Point) }
    if ($mode -eq 'Throw') { throw ('BRAVOUpdate.InjectedFault: ' + $Point) }
}

function Test-BRAVORollbackSimulatedCrash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    return ([string]$ErrorRecord.Exception.Message).StartsWith('BRAVOUpdate.SimulatedCrash', [StringComparison]::Ordinal)
}

function Send-BRAVORollbackProgress {
    # Прогрес — best effort: збій запису прогресу не має валити відкат.
    [CmdletBinding()]
    param(
        [AllowNull()]$Context,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$MessageKey,
        [string]$Message = ''
    )

    try {
        $writer = Get-BRAVOUpdatePropertyValue -InputObject $Context -Name 'ProgressWriter'
        if ($null -ne $writer) { [void]$writer.Emit('Rollback', $Status, $null, $MessageKey, @(), $Message) }
    } catch {
        return
    }
}

function Invoke-BRAVORollbackStep {
    # Durable-крок: fault .Before -> intent -> fault .AfterIntent -> дія ->
    # fault .AfterSideEffect -> completion -> fault .AfterComplete. Збій дії
    # (не crash) закриває фазу з outcome Failed і перекидає виняток.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$StepJournal,
        [Parameter(Mandatory = $true)][string]$StepStateRoot,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [AllowNull()]$FaultInjection = $null,
        [AllowNull()]$StepContext = $null
    )

    Invoke-BRAVORollbackFaultPoint -FaultInjection $FaultInjection -Point ($Phase + '.Before')
    [void](Add-BRAVOUpdateJournalPhaseIntent -Journal $StepJournal -Phase $Phase -StateRoot $StepStateRoot)
    Send-BRAVORollbackProgress -Context $StepContext -Status 'Started' -MessageKey $Phase
    Invoke-BRAVORollbackFaultPoint -FaultInjection $FaultInjection -Point ($Phase + '.AfterIntent')
    $output = $null
    try {
        $output = & $Action
    } catch {
        if (Test-BRAVORollbackSimulatedCrash -ErrorRecord $_) { throw }
        $failure = $_
        try { [void](Complete-BRAVOUpdateJournalPhase -Journal $StepJournal -Phase $Phase -Outcome 'Failed' -StateRoot $StepStateRoot) } catch { $null = $_ }
        Send-BRAVORollbackProgress -Context $StepContext -Status 'Failed' -MessageKey $Phase -Message ([string]$failure.Exception.Message)
        throw $failure
    }
    Invoke-BRAVORollbackFaultPoint -FaultInjection $FaultInjection -Point ($Phase + '.AfterSideEffect')
    [void](Complete-BRAVOUpdateJournalPhase -Journal $StepJournal -Phase $Phase -Outcome 'Succeeded' -StateRoot $StepStateRoot)
    Send-BRAVORollbackProgress -Context $StepContext -Status 'Completed' -MessageKey $Phase
    Invoke-BRAVORollbackFaultPoint -FaultInjection $FaultInjection -Point ($Phase + '.AfterComplete')
    return $output
}

function Read-BRAVORollbackJsonFile {
    # Fail closed: $null для відсутнього/порожнього/пошкодженого файлу.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [IO.File]::Exists($Path)) { return $null }
    try {
        $text = [IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Get-BRAVORollbackKeyMap {
    # deploy-keys.json -> hashtable ключ -> SHA-256 (може бути порожнім значенням).
    # Формат файлу належить частині Deploy; приймаємо {deployKeys|files|keys:{k:sha}},
    # плоский {k:sha} або масив рядків/об'єктів {key|path[,sha256]}.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Parsed)

    $map = @{}
    $source = $Parsed
    foreach ($container in @('deployKeys', 'files', 'keys')) {
        $candidate = Get-BRAVOUpdatePropertyValue -InputObject $Parsed -Name $container
        if ($null -ne $candidate) { $source = $candidate; break }
    }
    if ($source -is [string]) { $map[$source] = ''; return $map }
    if (($source -is [System.Collections.IEnumerable]) -and ($source -isnot [System.Collections.IDictionary])) {
        foreach ($item in $source) {
            if ($item -is [string]) { $map[[string]$item] = ''; continue }
            $itemKey = Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'key' -Default (Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'path')
            if ($null -eq $itemKey) { throw 'deploy-keys: елемент без ключа.' }
            $map[[string]$itemKey] = [string](Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'sha256' -Default '')
        }
        return $map
    }
    $pairs = New-Object System.Collections.Generic.List[object]
    if ($source -is [System.Collections.IDictionary]) {
        foreach ($name in @($source.Keys)) { $pairs.Add([pscustomobject]@{ Name = [string]$name; Value = $source[$name] }) }
    } else {
        foreach ($property in $source.PSObject.Properties) { $pairs.Add([pscustomobject]@{ Name = [string]$property.Name; Value = $property.Value }) }
    }
    foreach ($pair in $pairs) {
        if (@('schemaVersion', 'operationId', 'generatedUtc', 'createdUtc') -contains $pair.Name) { continue }
        $value = $pair.Value
        if (($null -ne $value) -and ($value -isnot [string]) -and (Test-BRAVOUpdateHasProperty -InputObject $value -Name 'sha256')) { $value = Get-BRAVOUpdatePropertyValue -InputObject $value -Name 'sha256' }
        $map[$pair.Name] = [string]$value
    }
    return $map
}

function Get-BRAVORollbackDeployKeySet {
    # Читає deploy-keys.json операції й звіряє його SHA-256 з журналом (§7.3 п.3).
    # Немає запису в журналі, файлу чи розбіжність sha = виняток: без доведеної
    # власності відкат нічого не видаляє.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$OperationDirectory
    )

    $recorded = Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'deployKeys'
    $recordedSha = [string](Get-BRAVOUpdatePropertyValue -InputObject $recorded -Name 'sha256' -Default '')
    if ([string]::IsNullOrWhiteSpace($recordedSha)) { throw 'У журналі немає SHA-256 deploy-keys.json: власність файлів не доведена.' }
    $path = Join-Path $OperationDirectory 'deploy-keys.json'
    if (-not [IO.File]::Exists($path)) { throw "deploy-keys.json не знайдено: $path" }
    $actual = Get-BRAVODeployFileSha256 -Path $path
    if ($actual -ne $recordedSha.ToUpperInvariant()) { throw 'deploy-keys.json змінено після запису в журнал (SHA-256 не збігається).' }
    $parsed = Read-BRAVORollbackJsonFile -Path $path
    if ($null -eq $parsed) { throw 'deploy-keys.json пошкоджений.' }
    return (Get-BRAVORollbackKeyMap -Parsed $parsed)
}

function Resolve-BRAVORollbackBackupLayout {
    # journal.backup.path = каталог операції в BackupRoot (runtime\ +
    # backup-manifest.json); толерантно приймаємо й шлях до самого runtime\.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Journal)

    $backup = Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'backup'
    $path = [string](Get-BRAVOUpdatePropertyValue -InputObject $backup -Name 'path' -Default '')
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    $base = $path.TrimEnd('\', '/')
    if ((-not [IO.Directory]::Exists((Join-Path $base 'runtime'))) -and ([IO.Path]::GetFileName($base) -eq 'runtime')) {
        $runtimeDir = $base
        $base = [IO.Path]::GetDirectoryName($base)
    } else {
        $runtimeDir = Join-Path $base 'runtime'
    }
    return [pscustomobject]@{
        Directory      = $base
        RuntimeDir     = $runtimeDir
        ManifestPath   = (Join-Path $base 'backup-manifest.json')
        ManifestSha256 = [string](Get-BRAVOUpdatePropertyValue -InputObject $backup -Name 'manifestSha256' -Default '')
    }
}

function Get-BRAVORollbackJournalVersionStateSnapshot {
    # Знімок version-state: з журналу (versionState), інакше відновлюється з файлу
    # знімка в каталозі операції. $null, якщо знімка немає взагалі.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$OperationDirectory
    )

    $recorded = Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'versionState'
    $snapshotPath = [string](Get-BRAVOUpdatePropertyValue -InputObject $recorded -Name 'snapshotPath' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($snapshotPath)) {
        $sha = Get-BRAVOUpdatePropertyValue -InputObject $recorded -Name 'sha256'
        return [pscustomobject]@{
            present         = [bool](Get-BRAVOUpdatePropertyValue -InputObject $recorded -Name 'present' -Default $false)
            sha256          = $(if ([string]::IsNullOrEmpty([string]$sha)) { $null } else { [string]$sha })
            recordedVersion = (Get-BRAVOUpdatePropertyValue -InputObject $recorded -Name 'recordedVersion')
            snapshotPath    = $snapshotPath
        }
    }
    $fallbackPath = Join-Path $OperationDirectory 'version-state.snapshot'
    if (-not [IO.File]::Exists($fallbackPath)) { return $null }
    $bytes = [IO.File]::ReadAllBytes($fallbackPath)
    $isMarker = ((New-Object System.Text.UTF8Encoding($false)).GetString($bytes) -ceq $script:BRAVOVersionStateAbsentMarker)
    if ($isMarker) {
        return [pscustomobject]@{ present = $false; sha256 = $null; recordedVersion = $null; snapshotPath = $fallbackPath }
    }
    return [pscustomobject]@{ present = $true; sha256 = (Get-BRAVORollbackBytesSha256 -Bytes $bytes); recordedVersion = (Get-BRAVOVersionStateRecordedText -Bytes $bytes); snapshotPath = $fallbackPath }
}

# ---------------------------------------------------------------------------
# Version-state (ENGINE_DESIGN §7.2)
# ---------------------------------------------------------------------------

function Get-BRAVOVersionStateSnapshot {
    <#
    .SYNOPSIS
        Знімок BRAVO_VERSION_STATE.json перед mutation: { present, sha256,
        recordedVersion, snapshotPath }.
    .DESCRIPTION
        Точні байти файлу копіюються у <OperationDirectory>\version-state.snapshot;
        якщо state не існує — у знімок пишеться маркер absent. Повторний знімок
        для тієї самої операції ЗАБОРОНЕНО (виняток): після початку mutation він
        зафіксував би вже змінений state як «початковий».
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VersionStatePath,
        [Parameter(Mandatory = $true)][string]$OperationDirectory
    )

    if (-not [IO.Directory]::Exists($OperationDirectory)) { [void][IO.Directory]::CreateDirectory($OperationDirectory) }
    $snapshotPath = Join-Path $OperationDirectory 'version-state.snapshot'
    if ([IO.File]::Exists($snapshotPath)) { throw "BRAVO.Update: знімок version-state уже існує: $snapshotPath" }
    if ([IO.File]::Exists($VersionStatePath)) {
        # Збій читання існуючого state = виняток (fail closed): без знімка відкат
        # не зможе повернути state.
        $bytes = [IO.File]::ReadAllBytes($VersionStatePath)
        Write-BRAVORollbackBytesAtomic -Path $snapshotPath -Bytes $bytes
        return [pscustomobject]@{
            present         = $true
            sha256          = (Get-BRAVORollbackBytesSha256 -Bytes $bytes)
            recordedVersion = (Get-BRAVOVersionStateRecordedText -Bytes $bytes)
            snapshotPath    = $snapshotPath
        }
    }
    Write-BRAVORollbackBytesAtomic -Path $snapshotPath -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes($script:BRAVOVersionStateAbsentMarker))
    return [pscustomobject]@{ present = $false; sha256 = $null; recordedVersion = $null; snapshotPath = $snapshotPath }
}

function Restore-BRAVOVersionState {
    <#
    .SYNOPSIS
        Повертає version-state до знімка за таблицею §7.2:
        { Action NoChange|Restored|Refused, Message }.
    .DESCRIPTION
        sha == знімок (або обидва absent) -> NoChange; recorded > target ->
        Refused (хтось після target справді запустив новішу версію: відкат
        нижче небезпечний, rollback завершується Critical); recorded <= target
        (зокрема == target), відсутній або пошкоджений state -> побайтове
        повернення знімка (або видалення файлу, якщо знімок absent), атомарно.
        Будь-яка невизначеність (знімок пошкоджений, target не розпізнано,
        state нечитабельний) -> Refused, а не вгадування.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$VersionStatePath,
        [AllowEmptyString()][string]$SourceVersion = '',
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TargetVersion
    )

    $refuse = { param([string]$Why) [pscustomobject]@{ Action = 'Refused'; Message = $Why } }
    $snapPresent = [bool](Get-BRAVOUpdatePropertyValue -InputObject $Snapshot -Name 'present' -Default $false)
    $snapSha = [string](Get-BRAVOUpdatePropertyValue -InputObject $Snapshot -Name 'sha256' -Default '')
    $snapPath = [string](Get-BRAVOUpdatePropertyValue -InputObject $Snapshot -Name 'snapshotPath' -Default '')

    $snapBytes = $null
    if ($snapPresent) {
        if ([string]::IsNullOrWhiteSpace($snapPath) -or -not [IO.File]::Exists($snapPath)) { return (& $refuse 'Файл знімка version-state відсутній.') }
        try { $snapBytes = [IO.File]::ReadAllBytes($snapPath) } catch { return (& $refuse ('Файл знімка version-state нечитабельний: ' + $_.Exception.Message)) }
        if ((Get-BRAVORollbackBytesSha256 -Bytes $snapBytes) -ne $snapSha.ToUpperInvariant()) { return (& $refuse 'Файл знімка version-state пошкоджений (SHA-256 не збігається).') }
    }

    $currentExists = [IO.File]::Exists($VersionStatePath)
    $currentBytes = $null
    if ($currentExists) {
        try { $currentBytes = [IO.File]::ReadAllBytes($VersionStatePath) } catch { return (& $refuse ('Поточний version-state нечитабельний: ' + $_.Exception.Message)) }
        if ($snapPresent -and ((Get-BRAVORollbackBytesSha256 -Bytes $currentBytes) -eq $snapSha.ToUpperInvariant())) {
            return [pscustomobject]@{ Action = 'NoChange'; Message = 'Version-state збігається зі знімком.' }
        }
    } elseif (-not $snapPresent) {
        return [pscustomobject]@{ Action = 'NoChange'; Message = 'Version-state відсутній, як і до операції.' }
    }

    $reason = ''
    if ($currentExists) {
        $recordedText = Get-BRAVOVersionStateRecordedText -Bytes $currentBytes
        $comparison = $null
        if ($null -ne $recordedText) {
            if ([string]::IsNullOrWhiteSpace($TargetVersion)) { return (& $refuse 'Цільову версію не вказано: порівняти записану версію неможливо.') }
            $comparison = Compare-BRAVOReleaseVersionText -LeftText $recordedText -RightText $TargetVersion
            if ($null -eq $comparison) {
                if ($null -eq (ConvertTo-BRAVOComparableVersion -Text $recordedText)) { $recordedText = $null }
                else { return (& $refuse "Цільову версію '$TargetVersion' не розпізнано: порівняння неможливе.") }
            }
        }
        if ($null -eq $recordedText) {
            $reason = 'Version-state пошкоджений: повернуто знімок.'
        } elseif ([int]$comparison -gt 0) {
            return (& $refuse "Записана версія ${recordedText} новіша за цільову ${TargetVersion}: після операції запускали новіший комплект, відкат state небезпечний.")
        } else {
            $reason = "Записана версія ${recordedText} не вища за цільову ${TargetVersion}: повернуто знімок."
        }
    } else {
        $reason = 'Version-state зник: повернуто знімок.'
    }

    if ($snapPresent) {
        Write-BRAVORollbackBytesAtomic -Path $VersionStatePath -Bytes $snapBytes
        $after = [IO.File]::ReadAllBytes($VersionStatePath)
        if ((Get-BRAVORollbackBytesSha256 -Bytes $after) -ne $snapSha.ToUpperInvariant()) { return (& $refuse 'Після відновлення version-state не збігається зі знімком.') }
    } else {
        [IO.File]::Delete($VersionStatePath)
        if ([IO.File]::Exists($VersionStatePath)) { return (& $refuse 'Не вдалося видалити version-state, якого не було до операції.') }
        $reason = $reason + ' (файлу до операції не було, видалено)'
    }
    return [pscustomobject]@{ Action = 'Restored'; Message = $reason }
}

# ---------------------------------------------------------------------------
# Відкат clean install (ENGINE_DESIGN §9.3)
# ---------------------------------------------------------------------------

function Invoke-BRAVOInstallRollback {
    <#
    .SYNOPSIS
        Відкат clean install за createdOwnership журналу: { Success, Removed[],
        Left[], OurRemaining[], Findings[], Problems[] }.
    .DESCRIPTION
        1) вимикає створені задачі (Disable-BRAVOAllManagedTasks: до install
        керованих задач не було, тож усі вони створені операцією); 2) видаляє
        файли з createdOwnership від найглибших, ЛИШЕ якщо SHA-256 == записаному
        (змінений чи без хеша файл лишається + finding); 3) видаляє лише ПОРОЖНІ
        створені каталоги; 4) корінь — лише якщо створений операцією
        (не маркер preexistingRoot) і порожній. Рекурсивного видалення немає,
        reparse point у шляху = файл лишається. Success = $false, якщо «наш»
        елемент лишився (викликач завершує Critical); лише чужі файли ->
        Success з Warning finding.
        Синтаксис записів createdOwnership: 'dir:<шлях|ключ>',
        'file:<ключ>|<SHA256>', 'file:<ключ>' (без хеша), 'marker:preexistingRoot',
        'deploykeys:<SHA256 deploy-keys.json>' (усі deploy-ключі з хешами одним записом).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )

    $removed = New-Object System.Collections.Generic.List[string]
    $left = New-Object System.Collections.Generic.List[string]
    $ours = New-Object System.Collections.Generic.List[string]
    $findings = New-Object System.Collections.Generic.List[object]
    $problems = New-Object System.Collections.Generic.List[string]
    $runtimeRoot = [string](Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'runtimeRoot' -Default '')
    if ([string]::IsNullOrWhiteSpace($runtimeRoot)) {
        [void]$problems.Add('У журналі немає runtimeRoot.')
        return [pscustomobject]@{ Success = $false; Removed = @(); Left = @(); OurRemaining = @(); Findings = @(); Problems = @($problems.ToArray()) }
    }
    $runtimeBase = Get-BRAVOUpdateFullPath -Path $runtimeRoot

    # Задачі вимикаємо ПЕРШИМИ: файли, які вони запускають, зникнуть нижче.
    # Результат Disable-BRAVOAllManagedTasks не можна лишати в pipeline:
    # він потрапив би у вихід функції й зламав би форму результату.
    try {
        $installDisable = Disable-BRAVOAllManagedTasks -Adapter $Adapter
        if ($null -ne $installDisable -and $installDisable.PSObject.Properties['IsComplete'] -and -not $installDisable.IsComplete) {
            [void]$problems.Add('Не всі створені задачі вдалося вимкнути.')
        }
    } catch {
        [void]$problems.Add('Не вдалося вимкнути створені задачі: ' + $_.Exception.Message)
    }

    $files = @{}
    $dirs = New-Object System.Collections.Generic.List[string]
    $preexisting = $false
    $operationDirectory = Get-BRAVORollbackOperationDirectory -StateRoot $StateRoot -OperationId ([string]$Journal.operationId)
    foreach ($entry in @($Journal.createdOwnership)) {
        $text = [string]$entry
        if ($text -ceq 'marker:preexistingRoot' -or $text -ceq 'preexistingRoot') { $preexisting = $true; continue }
        if ($text.StartsWith('dir:', [StringComparison]::Ordinal)) { [void]$dirs.Add($text.Substring(4)); continue }
        if ($text.StartsWith('file:', [StringComparison]::Ordinal)) {
            $body = $text.Substring(5)
            $pipe = $body.LastIndexOf('|')
            if ($pipe -gt 0 -and ($body.Substring($pipe + 1) -match '^[0-9A-Fa-f]{64}$')) {
                $files[$body.Substring(0, $pipe)] = $body.Substring($pipe + 1).ToUpperInvariant()
            } elseif (-not $files.ContainsKey($body)) {
                $files[$body] = ''
            }
            continue
        }
        if ($text.StartsWith('deploykeys:', [StringComparison]::Ordinal)) {
            try {
                $deployJournal = [pscustomobject]@{ deployKeys = [pscustomobject]@{ sha256 = $text.Substring(11) } }
                $keyMap = Get-BRAVORollbackDeployKeySet -Journal $deployJournal -OperationDirectory $operationDirectory
                foreach ($key in @($keyMap.Keys)) {
                    if ((-not $files.ContainsKey($key)) -or [string]::IsNullOrEmpty([string]$files[$key])) { $files[$key] = ([string]$keyMap[$key]).ToUpperInvariant() }
                }
            } catch {
                [void]$problems.Add('createdOwnership deploykeys: ' + $_.Exception.Message)
            }
            continue
        }
        [void]$problems.Add("Невідомий запис createdOwnership: '$text'.")
    }

    # Файли: найглибші першими; видаляємо лише з доведеним хешем.
    $ordered = @($files.Keys | Sort-Object -Property @{ Expression = { @($_ -split '[\\/]').Count }; Descending = $true }, @{ Expression = { $_ }; Descending = $false })
    foreach ($key in $ordered) {
        try {
            $safeKey = ConvertTo-BRAVODeployRelativeKey -Path ([string]$key)
            $full = Resolve-BRAVODeployTargetPath -Root $runtimeBase -Key $safeKey
            if (-not [IO.File]::Exists($full)) { continue }
            if (Test-BRAVOUpdatePathHasReparsePoint -Path $full -StopAt $runtimeBase) {
                [void]$ours.Add($safeKey); [void]$left.Add($safeKey)
                [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Rollback.ReparsePoint' -Severity Warning -Title 'Файл створеної установки лишено: шлях містить reparse point' -Meaning 'Видалення могло б вийти за межі каталогу установки.' -Details $safeKey))
                continue
            }
            $expected = [string]$files[$key]
            if ([string]::IsNullOrEmpty($expected)) {
                [void]$ours.Add($safeKey); [void]$left.Add($safeKey)
                [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Rollback.OwnedFileUnverified' -Severity Warning -Title 'Файл створеної установки лишено: хеш не записано' -Meaning 'Без хеша не можна довести, що вміст створила операція.' -Details $safeKey))
                continue
            }
            if ((Get-BRAVODeployFileSha256 -Path $full) -ne $expected) {
                [void]$ours.Add($safeKey); [void]$left.Add($safeKey)
                [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Rollback.OwnedFileModified' -Severity Warning -Title 'Файл створеної установки лишено: вміст змінено' -Meaning 'Файл змінили після створення; його не видалено.' -Details $safeKey))
                continue
            }
            [IO.File]::Delete($full)
            [void]$removed.Add($safeKey)
        } catch {
            [void]$ours.Add([string]$key)
            [void]$problems.Add(([string]$key + ': ' + $_.Exception.Message))
        }
    }

    # Каталоги: лише порожні, найглибші першими, без рекурсії.
    $dirPaths = New-Object System.Collections.Generic.List[string]
    foreach ($dirEntry in $dirs) {
        try {
            if ([IO.Path]::IsPathRooted($dirEntry)) { $dirFull = Get-BRAVOUpdateFullPath -Path $dirEntry }
            else { $dirFull = Resolve-BRAVODeployTargetPath -Root $runtimeBase -Key (ConvertTo-BRAVODeployRelativeKey -Path $dirEntry) }
            if (-not (Test-BRAVOUpdatePathIsUnder -Path $dirFull -Root $runtimeBase -AllowEqual)) {
                [void]$problems.Add("Каталог поза коренем установки: $dirEntry")
                continue
            }
            [void]$dirPaths.Add($dirFull)
        } catch {
            [void]$problems.Add("Некоректний запис каталогу '$dirEntry': " + $_.Exception.Message)
        }
    }
    # Дублікати прибираємо ДО сортування (Sort-Object -Unique з Property
    # порівнював би довжини, а не шляхи).
    $uniqueDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($dirPath in $dirPaths) { [void]$uniqueDirs.Add($dirPath) }
    $orderedDirs = @($uniqueDirs | Sort-Object -Property @{ Expression = { $_.Length }; Descending = $true })
    foreach ($dirFull in $orderedDirs) {
        try {
            if (-not [IO.Directory]::Exists($dirFull)) { continue }
            $isRoot = [string]::Equals($dirFull, $runtimeBase, [StringComparison]::OrdinalIgnoreCase)
            if ($isRoot -and $preexisting) { continue }
            if (Test-BRAVOUpdatePathHasReparsePoint -Path $dirFull -StopAt ([IO.Path]::GetDirectoryName($runtimeBase))) {
                [void]$left.Add($dirFull)
                [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Rollback.ReparsePoint' -Severity Warning -Title 'Каталог створеної установки лишено: reparse point' -Meaning 'Каталог не видалено.' -Details $dirFull))
                continue
            }
            if (@([IO.Directory]::GetFileSystemEntries($dirFull)).Count -eq 0) {
                [IO.Directory]::Delete($dirFull)
                [void]$removed.Add($dirFull)
            } else {
                [void]$left.Add($dirFull)
                [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Rollback.ForeignContent' -Severity Warning -Title 'Каталог не порожній: лишилися сторонні файли' -Meaning 'У каталозі є файли, яких не створювала операція; їх не чіпали.' -Action 'Перегляньте каталог і видаліть його вручну, якщо він не потрібен.' -Details $dirFull))
            }
        } catch {
            [void]$problems.Add("$dirFull : " + $_.Exception.Message)
            [void]$left.Add($dirFull)
        }
    }

    return [pscustomobject]@{
        Success      = (($ours.Count -eq 0) -and ($problems.Count -eq 0))
        Removed      = @($removed.ToArray())
        Left         = @($left.ToArray())
        OurRemaining = @($ours.ToArray())
        Findings     = @($findings.ToArray())
        Problems     = @($problems.ToArray())
    }
}

# ---------------------------------------------------------------------------
# Rollback (ENGINE_DESIGN §7.3)
# ---------------------------------------------------------------------------

function New-BRAVORollbackContext {
    # Мінімальний контекст, якщо викликач (напр. Recovery) його не має: ті самі
    # поля, що в ENGINE_DESIGN §2.1, для reconcile/validation частин.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$LockRoot,
        [Parameter(Mandatory = $true)][string]$OperationLockPath,
        [Parameter(Mandatory = $true)][string]$VersionStatePath,
        [Parameter(Mandatory = $true)][string]$OperationDirectory,
        [AllowNull()]$FaultInjection
    )

    if (-not [IO.Directory]::Exists($OperationDirectory)) { [void][IO.Directory]::CreateDirectory($OperationDirectory) }
    $progress = $null
    try { $progress = New-BRAVOUpdateProgressWriter -Path (Join-Path $OperationDirectory 'progress.jsonl') -OperationId ([string]$Journal.operationId) } catch { $progress = $null }
    return [pscustomobject]@{
        OperationId        = [string]$Journal.operationId
        Plan               = $null
        Adapter            = $Adapter
        Paths              = [pscustomobject]@{
            RuntimeRoot       = [string]$Journal.runtimeRoot
            StateRoot         = $StateRoot
            LockRoot          = $LockRoot
            StagingRoot       = [string]$Journal.stagingRoot
            BackupRoot        = [string]$Journal.backupRoot
            OperationLockPath = $OperationLockPath
            VersionStatePath  = $VersionStatePath
        }
        OperationDirectory = $OperationDirectory
        Journal            = $Journal
        ProgressWriter     = $progress
        CancelRequested    = $false
        MutationStarted    = $true
        Findings           = (New-Object System.Collections.Generic.List[object])
        Validation         = (New-Object System.Collections.Generic.List[object])
        Handles            = [pscustomobject]@{ LifecycleLock = $null; OperationLock = $null }
        FaultInjection     = $FaultInjection
    }
}

function Test-BRAVORollbackBackupFiles {
    # Крок 5 (§7.3): runtime == backup. Повертає список проблем (порожній = ОК).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][hashtable]$DeployKeys,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs = @()
    )

    $problems = New-Object System.Collections.Generic.List[string]
    if (-not [IO.File]::Exists($Layout.ManifestPath)) {
        [void]$problems.Add('backup-manifest.json не знайдено.')
        return @($problems.ToArray())
    }
    if (-not [string]::IsNullOrWhiteSpace($Layout.ManifestSha256)) {
        if ((Get-BRAVODeployFileSha256 -Path $Layout.ManifestPath) -ne $Layout.ManifestSha256.ToUpperInvariant()) {
            [void]$problems.Add('backup-manifest.json змінено (SHA-256 не збігається з журналом).')
            return @($problems.ToArray())
        }
    }
    $manifest = Read-BRAVORollbackJsonFile -Path $Layout.ManifestPath
    $filesNode = Get-BRAVOUpdatePropertyValue -InputObject $manifest -Name 'files'
    if ($null -eq $filesNode) {
        [void]$problems.Add('backup-manifest.json без розділу files.')
        return @($problems.ToArray())
    }
    $expected = @{}
    foreach ($property in $filesNode.PSObject.Properties) { $expected[(ConvertTo-BRAVODeployRelativeKey -Path $property.Name)] = ([string]$property.Value).ToUpperInvariant() }
    foreach ($key in @($expected.Keys)) {
        $full = Resolve-BRAVODeployTargetPath -Root $RuntimeRoot -Key $key
        if (-not [IO.File]::Exists($full)) { [void]$problems.Add('відсутній: ' + $key); continue }
        if ((Get-BRAVODeployFileSha256 -Path $full) -ne $expected[$key]) { [void]$problems.Add('змінено: ' + $key) }
    }
    foreach ($key in @($DeployKeys.Keys)) {
        $safeKey = ConvertTo-BRAVODeployRelativeKey -Path ([string]$key)
        if (Test-BRAVODeployPathExcluded -RelativeKey $safeKey -ExcludeFiles $ExcludeFiles -ExcludeDirs $ExcludeDirs) { continue }
        if ($expected.ContainsKey($safeKey)) { continue }
        if ([IO.File]::Exists((Resolve-BRAVODeployTargetPath -Root $RuntimeRoot -Key $safeKey))) { [void]$problems.Add('зайвий (додано розгортанням): ' + $safeKey) }
    }
    $backupManifest = Join-Path $Layout.RuntimeDir 'RUNTIME_MANIFEST.json'
    if ([IO.File]::Exists($backupManifest)) {
        $match = Test-BRAVODeployRuntimeMatchesManifest -RuntimeRoot $RuntimeRoot -ManifestPath $backupManifest -ExcludeDirs $ExcludeDirs
        foreach ($problem in @($match.Problems)) { [void]$problems.Add([string]$problem) }
    } else {
        [void]$problems.Add('runtime\RUNTIME_MANIFEST.json відсутній у backup.')
    }
    return @($problems.ToArray())
}

function Invoke-BRAVORollback {
    <#
    .SYNOPSIS
        Транзакційний відкат (ENGINE_DESIGN §7.3): DeploymentResult RolledBack
        або Critical (Failed/Blocked, якщо в середовищі є BRAVO_ALLOW_DOWNGRADE).
    .DESCRIPTION
        Кроки: Rollback.OperationLock -> (Install: Rollback.InstallCleanup) |
        Rollback.RestoreFiles -> Rollback.RestoreVersionState -> Rollback.Verify
        -> Rollback.Scheduler (лише якщо ConfigureScheduler мав intent) ->
        Rollback.Validate -> Rollback.RestoreTasks -> Rollback.Finalize. Кожен
        крок durable; усі кроки ідемпотентні, тож повтор після crash дає той
        самий фінальний стан. Збій будь-якого кроку -> Disable-BRAVOAllManagedTasks,
        журнал Critical, результат 82; backup і знімки лишаються.
        rollbackAttempts пишеться в журнал ПЕРЕД спробою; четверта спроба
        одразу Critical. Lifecycle lock тримає викликач; operation lock береться
        тут, якщо його немає в Context.Handles.OperationLock.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [AllowNull()]$Context = $null,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$LockRoot = '',
        [Parameter(Mandatory = $true)][string]$OperationLockPath,
        [Parameter(Mandatory = $true)][string]$VersionStatePath,
        [AllowNull()]$FaultInjection = $null
    )

    $startedUtc = Get-BRAVOUpdateUtcNowText
    $operationId = [string]$Journal.operationId
    $action = [string]$Journal.action
    $journalPath = Get-BRAVOUpdateJournalPath -StateRoot $StateRoot -OperationId $operationId
    $findings = New-Object System.Collections.Generic.List[object]
    $validation = New-Object System.Collections.Generic.List[object]

    $buildResult = {
        param([string]$Status, [string]$Reason, [string]$Message, [string]$ActivationState, [string]$LastPhase)
        $rollbackStatus = 'NotNeeded'
        if ($Status -eq 'RolledBack') { $rollbackStatus = 'Succeeded' } elseif ($Status -eq 'Critical') { $rollbackStatus = 'Failed' }
        $installed = $null
        if ($Status -eq 'RolledBack') { $installed = Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'sourceVersion' }
        New-BRAVOUpdateDeploymentResult -OperationId $operationId -PlanId ([string]$Journal.planId) -Action 'Rollback' -Status $Status -ReasonCode $Reason `
            -SourceVersion (Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'sourceVersion') `
            -TargetVersion (Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'targetVersion') -InstalledVersion $installed `
            -LastPhase $LastPhase -MutationStarted ([bool]$Journal.mutationStarted) -Validation @($validation.ToArray()) `
            -Rollback ([pscustomobject][ordered]@{ attempted = ($Status -ne 'Failed'); status = $rollbackStatus; message = $Message }) `
            -TaskActivation ([pscustomobject][ordered]@{ state = $ActivationState; tasks = @() }) `
            -Findings @($findings.ToArray()) -JournalPath $journalPath -StartedUtc $startedUtc
    }
    $lastPhaseName = {
        $names = @($Journal.phases)
        if ($names.Count -gt 0) { [string]$names[$names.Count - 1].phase } else { $null }
    }

    # Заборона обходу downgrade-захисту: engine ніде не ставить BRAVO_ALLOW_DOWNGRADE
    # і не працює, якщо вона вже є в середовищі процесу (§7.2 п.4). Нічого не
    # змінюємо: журнал лишається Open для повторного відкату в чистому середовищі.
    if ($null -ne [Environment]::GetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE')) {
        [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Rollback.AllowDowngradeSet' -Severity Blocker -Title 'У середовищі встановлено BRAVO_ALLOW_DOWNGRADE' `
            -Meaning 'Engine не виконує відкат із вимкненим захистом від зниження версії; нічого не змінено.' `
            -Action 'Приберіть змінну BRAVO_ALLOW_DOWNGRADE зі середовища процесу й повторіть відновлення.' -ExitCodeHint 35))
        return (& $buildResult 'Failed' 'Blocked' 'Відкат не виконано: встановлено BRAVO_ALLOW_DOWNGRADE.' 'Unchanged' $null)
    }

    $state = [string]$Journal.state
    if ($state -ceq 'RolledBack') {
        return (& $buildResult 'RolledBack' '' 'Відкат уже виконано раніше.' $(if ($action -ceq 'Install') { 'Inactive' } else { 'Unchanged' }) ([string]$Journal.lastCompletedPhase))
    }
    if (($state -cne 'Open') -and ($state -cne 'Critical')) { throw "BRAVO.Update: відкат неможливий для журналу зі станом '$state'." }
    if (-not [bool]$Journal.mutationStarted) { throw 'BRAVO.Update: відкат потрібен лише після початку mutation (mutationStarted=false).' }

    if ($null -eq $FaultInjection) { $FaultInjection = Get-BRAVOUpdatePropertyValue -InputObject $Context -Name 'FaultInjection' }
    $operationDirectory = Get-BRAVORollbackOperationDirectory -StateRoot $StateRoot -OperationId $operationId
    if ($null -eq $Context) {
        $Context = New-BRAVORollbackContext -Journal $Journal -Adapter $Adapter -StateRoot $StateRoot -LockRoot $LockRoot -OperationLockPath $OperationLockPath `
            -VersionStatePath $VersionStatePath -OperationDirectory $operationDirectory -FaultInjection $FaultInjection
    }

    $criticalMessage = $null
    $activation = 'Unchanged'
    # Спільний стан кроків (scriptblock-и читають лише $rb: імена параметрів
    # Invoke-BRAVORollbackStep з ними не перетинаються).
    $rb = @{ Journal = $Journal; StateRoot = $StateRoot; Adapter = $Adapter; Context = $Context; OperationDirectory = $operationDirectory
             VersionStatePath = $VersionStatePath; OperationLockPath = $OperationLockPath; Findings = $findings; Validation = $validation
             Action = $action; Layout = $null; DeployKeys = $null }
    $rb.RuntimeRoot = [string]$Journal.runtimeRoot
    $step = {
        param([string]$Phase, [scriptblock]$Body)
        Invoke-BRAVORollbackStep -StepJournal $Journal -StepStateRoot $StateRoot -Phase $Phase -Action $Body -FaultInjection $FaultInjection -StepContext $Context
    }

    try {
        # Лічильник спроб — ПЕРЕД будь-якою дією, щоб crash не обнуляв його.
        $attempts = [int](Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'rollbackAttempts' -Default 0)
        if ($attempts -ge $script:BRAVORollbackMaxAttempts) {
            throw "Вичерпано кількість спроб відкату ($attempts): потрібне ручне втручання."
        }
        [void](Set-BRAVOUpdateJournalField -Journal $Journal -Name 'rollbackAttempts' -Value ($attempts + 1) -StateRoot $StateRoot)

        # Крок 1: операційний lock (повторно, якщо немає).
        [void](& $step 'Rollback.OperationLock' {
            $handles = Get-BRAVOUpdatePropertyValue -InputObject $rb.Context -Name 'Handles'
            $held = Get-BRAVOUpdatePropertyValue -InputObject $handles -Name 'OperationLock'
            if (($null -ne $held) -and ($null -ne (Get-BRAVOUpdatePropertyValue -InputObject $held -Name 'Stream'))) { return }
            $version = [string](Get-BRAVOUpdatePropertyValue -InputObject $rb.Journal -Name 'targetVersion' -Default '')
            if ([string]::IsNullOrWhiteSpace($version)) { $version = '0.0.0' }
            $lock = Enter-BRAVOUpdateOperationLock -OperationLockPath $rb.OperationLockPath -OperationId ([string]$rb.Journal.operationId) -PackageVersion $version
            if (-not $lock.Success) { throw ('Не вдалося взяти операційний lock для відкату: ' + [string]$lock.Error) }
            $rb.OwnedLock = $lock
        })

        if ($action -ceq 'Install') {
            # Крок 2: відкат install (§9.3).
            [void](& $step 'Rollback.InstallCleanup' {
                $cleanup = Invoke-BRAVOInstallRollback -Journal $rb.Journal -Adapter $rb.Adapter -StateRoot $rb.StateRoot
                foreach ($f in @($cleanup.Findings)) { [void]$rb.Findings.Add($f) }
                if (-not $cleanup.Success) {
                    throw ('Відкат install не завершено, лишилися створені операцією елементи: ' + ((@($cleanup.OurRemaining) + @($cleanup.Problems)) -join '; '))
                }
            })
            $activation = 'Inactive'
        } else {
            $layout = Resolve-BRAVORollbackBackupLayout -Journal $Journal
            $rb.Layout = $layout
            $deployIntent = $false
            foreach ($phaseEntry in @($Journal.phases)) { if ([string]$phaseEntry.phase -ceq 'Deploy') { $deployIntent = $true } }
            $siteOwned = Get-BRAVOUpdateSiteOwnedPaths
            $rb.SiteOwned = $siteOwned

            # Крок 3: точне відновлення файлів із backup за deploy-keys.
            [void](& $step 'Rollback.RestoreFiles' {
                if ($null -eq $rb.Layout) {
                    if ($deployIntent) { throw 'Розгортання починалося, але backup у журналі не записано: файли відновити неможливо.' }
                    return
                }
                if (-not [IO.Directory]::Exists($rb.Layout.RuntimeDir)) { throw ('Каталог backup\runtime не знайдено: ' + $rb.Layout.RuntimeDir) }
                $keys = Get-BRAVORollbackDeployKeySet -Journal $rb.Journal -OperationDirectory $rb.OperationDirectory
                $rb.DeployKeys = $keys
                $stagedRoot = [string](Get-BRAVOUpdatePropertyValue -InputObject $rb.Journal -Name 'stagingRoot' -Default '')
                if ([string]::IsNullOrWhiteSpace($stagedRoot)) { $stagedRoot = $rb.Layout.Directory }
                $report = Invoke-BRAVODeployExactRestore -RuntimeRoot $rb.RuntimeRoot -BackupRoot $rb.Layout.RuntimeDir -StagedRoot $stagedRoot `
                    -ExcludeFiles @($rb.SiteOwned.Files) -ExcludeDirs @($rb.SiteOwned.Dirs) -OwnedKeyList @($keys.Keys)
                if (@($report.Errors).Count -gt 0) { throw ('Точне відновлення файлів завершилося помилками: ' + (@($report.Errors) -join '; ')) }
            })
        }

        # Крок 4: version-state за §7.2.
        [void](& $step 'Rollback.RestoreVersionState' {
            $snapshot = Get-BRAVORollbackJournalVersionStateSnapshot -Journal $rb.Journal -OperationDirectory $rb.OperationDirectory
            if ($null -eq $snapshot) { throw 'Знімок version-state відсутній: відновити state неможливо.' }
            $restore = Restore-BRAVOVersionState -Snapshot $snapshot -VersionStatePath $rb.VersionStatePath `
                -SourceVersion ([string](Get-BRAVOUpdatePropertyValue -InputObject $rb.Journal -Name 'sourceVersion' -Default '')) `
                -TargetVersion ([string](Get-BRAVOUpdatePropertyValue -InputObject $rb.Journal -Name 'targetVersion' -Default ''))
            if ($restore.Action -ceq 'Refused') { throw ('Version-state: ' + $restore.Message) }
            [void]$rb.Findings.Add((New-BRAVOUpdateFinding -Id 'Rollback.VersionState' -Severity Ok -Title 'Version-state перевірено' -Details ([string]$restore.Action + ': ' + [string]$restore.Message)))
        })

        if ($action -cne 'Install') {
            # Крок 5: верифікація дзеркала.
            [void](& $step 'Rollback.Verify' {
                if ($null -eq $rb.Layout) { return }
                $keys = $rb.DeployKeys
                if ($null -eq $keys) { $keys = Get-BRAVORollbackDeployKeySet -Journal $rb.Journal -OperationDirectory $rb.OperationDirectory }
                $problems = @(Test-BRAVORollbackBackupFiles -RuntimeRoot $rb.RuntimeRoot -Layout $rb.Layout -DeployKeys $keys -ExcludeFiles @($rb.SiteOwned.Files) -ExcludeDirs @($rb.SiteOwned.Dirs))
                if ($problems.Count -gt 0) { throw ('Верифікація відкату не пройшла: ' + ($problems -join '; ')) }
            })

            $schedulerSnapshot = $null
            $snapshotRef = Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'schedulerSnapshot'
            $snapshotFile = [string](Get-BRAVOUpdatePropertyValue -InputObject $snapshotRef -Name 'path' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($snapshotFile)) { $schedulerSnapshot = Read-BRAVORollbackJsonFile -Path $snapshotFile }
            $rb.SchedulerSnapshot = $schedulerSnapshot

            # Крок 6: scheduler лише якщо ConfigureScheduler мав intent.
            $configureIntent = $false
            foreach ($phaseEntry in @($Journal.phases)) { if ([string]$phaseEntry.phase -ceq 'ConfigureScheduler') { $configureIntent = $true } }
            if ($configureIntent) {
                [void](& $step 'Rollback.Scheduler' {
                    $reconcile = Invoke-BRAVOSchedulerReconcile -Context $rb.Context -Snapshot $rb.SchedulerSnapshot
                    if (([string]$reconcile.Verdict) -ceq 'FAIL') { throw ('Повторне налаштування scheduler зі старого runtime не вдалося: ' + (@($reconcile.Problems) -join '; ')) }
                })
            }

            # Крок 7: валідація відкату.
            [void](& $step 'Rollback.Validate' {
                $baseline = Get-BRAVOUpdatePropertyValue -InputObject $rb.Journal -Name 'baseline'
                $arguments = @{ Context = $rb.Context; Mode = 'Rollback'; ExpectedVersion = [string](Get-BRAVOUpdatePropertyValue -InputObject $rb.Journal -Name 'sourceVersion' -Default '') }
                if ($null -ne $rb.Layout) { $arguments.ExpectedManifestPath = (Join-Path $rb.Layout.RuntimeDir 'RUNTIME_MANIFEST.json') }
                $site = Get-BRAVOUpdatePropertyValue -InputObject $baseline -Name 'siteConfig'
                if ($null -ne $site) { $arguments.SiteBaseline = $site }
                $guardBaseline = Get-BRAVOUpdatePropertyValue -InputObject $baseline -Name 'guardExitCode'
                if (($rb.Action -ceq 'Repair') -and ($null -ne $guardBaseline)) { $arguments.GuardBaselineExitCode = [int]$guardBaseline }
                $verdict = Test-BRAVODeploymentValidation @arguments
                foreach ($item in @(Get-BRAVOUpdatePropertyValue -InputObject $verdict -Name 'Items' -Default @())) {
                    [void]$rb.Validation.Add([pscustomobject][ordered]@{
                        name    = [string](Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'Name' -Default '')
                        status  = [string](Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'Status' -Default 'Skipped')
                        message = [string](Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'Message' -Default '')
                    })
                }
                if ([string](Get-BRAVOUpdatePropertyValue -InputObject $verdict -Name 'Status' -Default 'Fail') -ceq 'Fail') { throw 'Валідація відкату не пройшла.' }
            })

            # Крок 8: задачі повертаємо ЛИШЕ після успіху кроків 3–7.
            [void](& $step 'Rollback.RestoreTasks' {
                if ($null -eq $rb.SchedulerSnapshot) { throw 'Знімок scheduler відсутній: стан задач відновити неможливо.' }
                $restored = Restore-BRAVOManagedTaskState -Snapshot $rb.SchedulerSnapshot -Adapter $rb.Adapter
                if (-not [bool](Get-BRAVOUpdatePropertyValue -InputObject $restored -Name 'IsComplete' -Default $false)) {
                    throw ('Стан задач відновлено не повністю: ' + (@(Get-BRAVOUpdatePropertyValue -InputObject $restored -Name 'Failed' -Default @()) -join '; '))
                }
            })
        }

        # Крок 9: журнал RolledBack, звільнення lock (у finally).
        [void](& $step 'Rollback.Finalize' {
            [void](Set-BRAVOUpdateJournalState -Journal $rb.Journal -State 'RolledBack' -StateRoot $rb.StateRoot)
        })
    } catch {
        if (Test-BRAVORollbackSimulatedCrash -ErrorRecord $_) { throw }
        $criticalMessage = [string]$_.Exception.Message
    } finally {
        # Перевіряємо $rb, а не локальну змінну: crash одразу після взяття lock-а
        # не має залишити потік відкритим.
        if ($rb.ContainsKey('OwnedLock')) { Exit-BRAVOUpdateOperationLock -Lock $rb.OwnedLock }
    }

    if ($null -eq $criticalMessage) {
        return (& $buildResult 'RolledBack' '' 'Попередній стан відновлено й перевірено.' $activation (& $lastPhaseName))
    }

    # Critical: задачі лишаються вимкненими, журнал Critical, backup і знімки зберігаються.
    $disableNote = ''
    try {
        $criticalDisable = Disable-BRAVOAllManagedTasks -Adapter $Adapter
        if ($null -ne $criticalDisable -and $criticalDisable.PSObject.Properties['IsComplete'] -and -not $criticalDisable.IsComplete) {
            $disableNote = ' Не всі керовані задачі вдалося вимкнути.'
        }
    } catch {
        $disableNote = ' Не вдалося вимкнути задачі: ' + [string]$_.Exception.Message
    }
    try {
        [void](Set-BRAVOUpdateJournalState -Journal $Journal -State 'Critical' -StateRoot $StateRoot)
    } catch {
        $disableNote = $disableNote + ' Не вдалося записати стан Critical у журнал: ' + [string]$_.Exception.Message
    }
    [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Rollback.Critical' -Severity Blocker -Title 'Відкат не вдався: сервер у невизначеному стані' `
        -Meaning 'Керовані задачі вимкнено; backup і знімки збережено для ручного відновлення.' `
        -Action 'Не вмикайте задачі вручну; зверніться до адміністратора й передайте журнал та backup операції.' -Details ($criticalMessage + $disableNote) -ExitCodeHint 82))
    return (& $buildResult 'Critical' '' ($criticalMessage + $disableNote) 'Inactive' (& $lastPhaseName))
}
