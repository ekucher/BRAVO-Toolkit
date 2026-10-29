# BRAVO.Update.Journal — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Журнал операції (CONTRACTS §8): <StateRoot>\Journal\<operationId>.json.
# Принцип write-ahead: intent фази пишеться на диск ДО side effect, completion —
# після; recovery трактує фазу з intent без completion як можливо виконану.
# Усі мутатори журналу персистять ПЕРЕД поверненням (збій запису = виняток, тож
# engine не виконає side effect без підтвердженого intent).

$script:BRAVOUpdateJournalStates = @('Open', 'Committed', 'RolledBack', 'Critical', 'Abandoned')
$script:BRAVOUpdateJournalActions = @('Install', 'Update', 'Repair')

function Write-BRAVOUpdateFileAtomic {
    <#
    .SYNOPSIS
        Атомарний запис тексту (UTF-8 без BOM): тимчасовий файл у тому ж
        каталозі -> File.Replace (існуючий) або File.Move (новий).
    .DESCRIPTION
        BRAVO.System\Write-BRAVOStateFileAtomic має ту саму схему tmp+Replace, але
        пише тимчасовий файл через WriteAllText БЕЗ FileOptions.WriteThrough:
        після раптової втрати живлення Replace міг би підмінити журнал файлом,
        вміст якого ще лише в кеші ОС. Для write-ahead журналу це неприпустимо,
        тому тут власна реалізація з WriteThrough + Flush($true). Порожнього
        або часткового файлу на місці цілі не буває: Replace/Move атомарні в
        межах тому, а при збої цільовий файл лишається попереднім.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $directory = [IO.Path]::GetDirectoryName($Path)
    if ([string]::IsNullOrWhiteSpace($directory)) { throw "BRAVO.Update: шлях має містити каталог: $Path" }
    if (-not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }

    $leaf = [IO.Path]::GetFileName($Path)
    $suffix = [guid]::NewGuid().ToString('N')
    $temporaryPath = [IO.Path]::Combine($directory, ('.{0}_{1}.tmp' -f $leaf, $suffix))
    $backupPath = [IO.Path]::Combine($directory, ('.{0}_{1}.bak' -f $leaf, $suffix))
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    $replaced = $false
    try {
        $stream = New-Object System.IO.FileStream($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        if ([IO.File]::Exists($Path)) {
            # .NET Framework: явний backup-шлях надійніший за $null.
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

function Get-BRAVOUpdateJournalDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    return (Join-Path $StateRoot 'Journal')
}

function Get-BRAVOUpdateJournalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    # operationId входить в ім'я файлу: лише GUID, інакше обхід каталогу через '..'.
    if (-not (Test-BRAVOUpdateGuidText -Value $OperationId)) { throw "BRAVO.Update: некоректний operationId '$OperationId'." }
    return (Join-Path (Get-BRAVOUpdateJournalDirectory -StateRoot $StateRoot) ($OperationId + '.json'))
}

function Test-BRAVOUpdateJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$InputObject)

    $problems = New-Object 'System.Collections.Generic.List[string]'
    $required = @('schemaVersion', 'operationId', 'planId', 'action', 'state', 'runtimeRoot', 'stagingRoot', 'backupRoot', 'artifactSha256', 'sourceVersion', 'targetVersion', 'mutationStarted', 'phases', 'lastCompletedPhase', 'backup', 'schedulerSnapshot', 'createdOwnership', 'createdUtc', 'updatedUtc')
    if (Test-BRAVOUpdateContractBase -InputObject $InputObject -Problems $problems -RequiredField $required) {
        if (-not (Test-BRAVOUpdateGuidText -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'operationId'))) { $problems.Add('operationId має бути GUID у нижньому регістрі.') }
        if (-not (Test-BRAVOUpdateGuidText -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'planId'))) { $problems.Add('planId має бути GUID у нижньому регістрі.') }
        Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'action') -Allowed $script:BRAVOUpdateJournalActions -FieldName 'action' -Problems $problems
        Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'state') -Allowed $script:BRAVOUpdateJournalStates -FieldName 'state' -Problems $problems
        if ((Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'mutationStarted') -isnot [bool]) { $problems.Add('mutationStarted має бути bool.') }
        $sha = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'artifactSha256'
        if (($null -ne $sha) -and (($sha -isnot [string]) -or ($sha -cnotmatch '^[0-9A-Fa-f]{64}$'))) { $problems.Add('artifactSha256 має бути null або SHA-256 hex.') }
        foreach ($timeName in @('createdUtc', 'updatedUtc')) {
            if (-not (Test-BRAVOUpdateTimestampValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name $timeName))) { $problems.Add("$timeName не є датою ISO 8601.") }
        }
        $phases = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'phases'
        if ($true) {
            $index = 0
            foreach ($phase in @($phases)) {
                foreach ($name in @('phase', 'intentUtc', 'completedUtc', 'outcome')) {
                    if (-not (Test-BRAVOUpdateHasProperty -InputObject $phase -Name $name)) { $problems.Add("phases[$index]: відсутнє поле '$name'.") }
                }
                $phaseName = Get-BRAVOUpdatePropertyValue -InputObject $phase -Name 'phase'
                if (($phaseName -isnot [string]) -or [string]::IsNullOrWhiteSpace($phaseName)) { $problems.Add("phases[$index]: порожня назва фази.") }
                if (-not (Test-BRAVOUpdateTimestampValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $phase -Name 'intentUtc'))) { $problems.Add("phases[$index]: intentUtc не є датою.") }
                $completed = Get-BRAVOUpdatePropertyValue -InputObject $phase -Name 'completedUtc'
                if (($null -ne $completed) -and (-not (Test-BRAVOUpdateTimestampValue -Value $completed))) { $problems.Add("phases[$index]: completedUtc не є датою.") }
                $index++
            }
        }
    }
    return (New-BRAVOUpdateValidationResult -Problems $problems)
}

function Write-BRAVOUpdateJournal {
    <#
    .SYNOPSIS
        Валідує й атомарно записує журнал; повертає шлях файлу.
    .DESCRIPTION
        Невалідний журнал (зокрема із секретним полем) не записується —
        виняток, а не тихий пропуск: write-ahead гарантія не має «мовчазних» збоїв.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )

    $Journal.updatedUtc = Get-BRAVOUpdateUtcNowText
    $check = Test-BRAVOUpdateJournal -InputObject $Journal
    if (-not $check.IsValid) { throw ('BRAVO.Update: журнал не пройшов валідацію: ' + ($check.Problems -join '; ')) }
    $path = Get-BRAVOUpdateJournalPath -StateRoot $StateRoot -OperationId ([string]$Journal.operationId)
    Write-BRAVOUpdateFileAtomic -Path $path -Text (ConvertTo-BRAVOUpdateJson -InputObject $Journal)
    return $path
}

function New-BRAVOUpdateJournal {
    <#
    .SYNOPSIS
        Створює журнал зі state=Open; за замовчуванням ОДРАЗУ записує на диск
        (відкритий журнал має бути видимий recovery до першої дії), -NoWrite лише для тестів.
    .DESCRIPTION
        З -Plan поля беруться з DeploymentPlan (operationId, planId, action, корені,
        artifactSha256, currentVersion/targetVersion); явні параметри їх перекривають.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        $Plan = $null,
        [string]$OperationId = '',
        [string]$PlanId = '',
        [ValidateSet('', 'Install', 'Update', 'Repair')][string]$Action = '',
        [string]$RuntimeRoot = '',
        [string]$StagingRoot = '',
        [string]$BackupRoot = '',
        [string]$ArtifactSha256 = '',
        [string]$SourceVersion = '',
        [string]$TargetVersion = '',
        [switch]$NoWrite
    )

    if ($null -ne $Plan) {
        if ($OperationId -eq '') { $OperationId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'operationId' -Default '') }
        if ($PlanId -eq '') { $PlanId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'planId' -Default '') }
        if ($Action -eq '') { $Action = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'action' -Default '') }
        if ($RuntimeRoot -eq '') { $RuntimeRoot = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'runtimeRoot' -Default '') }
        if ($StagingRoot -eq '') { $StagingRoot = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'stagingRoot' -Default '') }
        if ($BackupRoot -eq '') { $BackupRoot = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'backupRoot' -Default '') }
        if ($ArtifactSha256 -eq '') { $ArtifactSha256 = [string](Get-BRAVOUpdatePropertyValue -InputObject (Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'source') -Name 'artifactSha256' -Default '') }
        if ($SourceVersion -eq '') { $SourceVersion = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'currentVersion' -Default '') }
        if ($TargetVersion -eq '') { $TargetVersion = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'targetVersion' -Default '') }
    }
    if ($OperationId -eq '') { $OperationId = [guid]::NewGuid().ToString() }
    if ($PlanId -eq '') { $PlanId = [guid]::NewGuid().ToString() }
    if ($Action -eq '') { throw 'BRAVO.Update: для журналу потрібна дія (Install/Update/Repair).' }
    $nowText = Get-BRAVOUpdateUtcNowText
    $nullable = { param([string]$Value) if ([string]::IsNullOrEmpty($Value)) { $null } else { $Value } }

    $journal = [pscustomobject][ordered]@{
        schemaVersion      = 1
        operationId        = $OperationId.ToLowerInvariant()
        planId             = $PlanId.ToLowerInvariant()
        action             = $Action
        state              = 'Open'
        runtimeRoot        = (& $nullable $RuntimeRoot)
        stagingRoot        = (& $nullable $StagingRoot)
        backupRoot         = (& $nullable $BackupRoot)
        artifactSha256     = (& $nullable $ArtifactSha256)
        sourceVersion      = (& $nullable $SourceVersion)
        targetVersion      = (& $nullable $TargetVersion)
        mutationStarted    = $false
        phases             = @()
        lastCompletedPhase = $null
        backup             = $null
        schedulerSnapshot  = $null
        createdOwnership   = @()
        createdUtc         = $nowText
        updatedUtc         = $nowText
    }
    if (-not $NoWrite) { [void](Write-BRAVOUpdateJournal -Journal $journal -StateRoot $StateRoot) }
    return $journal
}

function Read-BRAVOUpdateJournal {
    <#
    .SYNOPSIS
        Читає журнал fail closed: { IsValid, Problems[], Contract, Journal, Path }.
        Відсутній/пошкоджений файл = IsValid $false, без винятку.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $read = Read-BRAVOUpdateContractFile -Path $Path -Kind UpdateJournal
    return [pscustomobject]@{ IsValid = $read.IsValid; Problems = @($read.Problems); Contract = $read.Contract; Journal = $read.Contract; Path = $Path }
}

function Get-BRAVOUpdateOpenJournal {
    <#
    .SYNOPSIS
        Усі журнали, що блокують нові операції: state=Open АБО пошкоджені/нечитабельні.
    .DESCRIPTION
        Fail closed: пошкоджений журнал НІКОЛИ не ігнорується — він повертається як
        запис зі State='Unknown', IsCorrupt=$true і blocker-finding-ом (оператор не
        знає, чи починалась mutation). Файли, що не *.json (тимчасові .tmp), пропускаються.
        Повертає масив записів { OperationId, Path, State, IsCorrupt, Journal, Problems, Finding }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $directory = Get-BRAVOUpdateJournalDirectory -StateRoot $StateRoot
    $entries = New-Object System.Collections.Generic.List[object]
    if (-not [IO.Directory]::Exists($directory)) { return @() }
    $files = @()
    try {
        $files = @(Get-ChildItem -LiteralPath $directory -File -Filter '*.json' -ErrorAction Stop | Sort-Object -Property Name)
    } catch {
        $finding = New-BRAVOUpdateFinding -Id 'Journal.Unreadable' -Severity Blocker -Title 'Каталог журналів операцій недоступний' `
            -Meaning 'Неможливо визначити, чи є незавершена операція.' -Action 'Перевірте доступ до каталогу журналів і запустіть відновлення.' -Details ([string]$_.Exception.Message)
        $entries.Add([pscustomobject]@{ OperationId = $null; Path = $directory; State = 'Unknown'; IsCorrupt = $true; Journal = $null; Problems = @([string]$_.Exception.Message); Finding = $finding })
        return $entries.ToArray()
    }
    foreach ($file in $files) {
        $read = Read-BRAVOUpdateJournal -Path $file.FullName
        $baseName = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        $problems = @($read.Problems)
        if ($read.IsValid -and ([string]$read.Journal.operationId -cne $baseName)) {
            $problems += "operationId журналу не збігається з іменем файлу '$($file.Name)'."
        }
        if ($read.IsValid -and $problems.Count -eq 0) {
            if ([string]$read.Journal.state -ceq 'Open') {
                $finding = New-BRAVOUpdateFinding -Id 'Journal.Open' -Severity Blocker -Title 'Знайдено незавершену операцію оновлення' `
                    -Meaning 'Нові операції заблоковано, доки попередню не відновлено.' -Action 'Запустіть відновлення (Recovery) для цієї операції.' -Details ("operationId=$baseName")
                $entries.Add([pscustomobject]@{ OperationId = $baseName; Path = $file.FullName; State = 'Open'; IsCorrupt = $false; Journal = $read.Journal; Problems = @(); Finding = $finding })
            }
            continue
        }
        $finding = New-BRAVOUpdateFinding -Id 'Journal.Corrupt' -Severity Blocker -Title 'Журнал операції пошкоджений або нечитабельний' `
            -Meaning 'Невідомо, чи була змінена робоча копія; журнал не ігнорується.' -Action 'Запустіть відновлення (Recovery) і не видаляйте журнал вручну.' -Details ("файл=$($file.Name); " + ($problems -join '; '))
        $entries.Add([pscustomobject]@{ OperationId = $baseName; Path = $file.FullName; State = 'Unknown'; IsCorrupt = $true; Journal = $read.Journal; Problems = $problems; Finding = $finding })
    }
    return $entries.ToArray()
}

function Add-BRAVOUpdateJournalPhaseIntent {
    <#
    .SYNOPSIS
        Записує intent фази (completedUtc/outcome = $null) і персистить ДО повернення.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )

    if ([string]::IsNullOrWhiteSpace($Phase)) { throw 'BRAVO.Update: назва фази порожня.' }
    $entry = [pscustomobject][ordered]@{ phase = $Phase; intentUtc = (Get-BRAVOUpdateUtcNowText); completedUtc = $null; outcome = $null }
    $Journal.phases = @(@($Journal.phases) + $entry)
    [void](Write-BRAVOUpdateJournal -Journal $Journal -StateRoot $StateRoot)
    return $Journal
}

function Complete-BRAVOUpdateJournalPhase {
    <#
    .SYNOPSIS
        Закриває останній незавершений intent цієї фази (Outcome: напр. Succeeded|Failed|Skipped)
        і персистить. lastCompletedPhase зсувається, якщо Outcome не 'Failed'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Outcome,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )

    if ([string]::IsNullOrWhiteSpace($Outcome)) { throw 'BRAVO.Update: Outcome порожній.' }
    $phases = @($Journal.phases)
    $target = $null
    for ($index = $phases.Count - 1; $index -ge 0; $index--) {
        if (([string]$phases[$index].phase -ceq $Phase) -and ($null -eq $phases[$index].completedUtc)) { $target = $phases[$index]; break }
    }
    if ($null -eq $target) { throw "BRAVO.Update: немає незавершеного intent для фази '$Phase' (спочатку Add-BRAVOUpdateJournalPhaseIntent)." }
    $target.completedUtc = Get-BRAVOUpdateUtcNowText
    $target.outcome = $Outcome
    if ($Outcome -cne 'Failed') { $Journal.lastCompletedPhase = $Phase }
    [void](Write-BRAVOUpdateJournal -Journal $Journal -StateRoot $StateRoot)
    return $Journal
}

function Set-BRAVOUpdateJournalMutationStarted {
    # Викликати ПЕРЕД першою зміною runtime (CONTRACTS §8).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Journal, [Parameter(Mandatory = $true)][string]$StateRoot)

    $Journal.mutationStarted = $true
    [void](Write-BRAVOUpdateJournal -Journal $Journal -StateRoot $StateRoot)
    return $Journal
}

function Set-BRAVOUpdateJournalState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][ValidateSet('Committed', 'RolledBack', 'Critical', 'Abandoned')][string]$State,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )

    $Journal.state = $State
    [void](Write-BRAVOUpdateJournal -Journal $Journal -StateRoot $StateRoot)
    return $Journal
}

function Add-BRAVOUpdateJournalCreatedOwnership {
    # Ключ файлу/каталогу, створеного цією операцією (для відкату clean install); дублікати ігноруються.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )

    if ([string]::IsNullOrWhiteSpace($Key)) { throw 'BRAVO.Update: ключ ownership порожній.' }
    $existing = @($Journal.createdOwnership)
    if ($existing -cnotcontains $Key) {
        $Journal.createdOwnership = @($existing + $Key)
        [void](Write-BRAVOUpdateJournal -Journal $Journal -StateRoot $StateRoot)
    }
    return $Journal
}

function Set-BRAVOUpdateJournalBackup {
    # Реквізити резервної копії { path, manifestSha256, fileCount }; персистить.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][string]$ManifestSha256 = $null,
        [int]$FileCount = 0,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )

    if ([string]::IsNullOrEmpty($ManifestSha256)) { $ManifestSha256 = $null }
    $Journal.backup = [pscustomobject][ordered]@{ path = $Path; manifestSha256 = $ManifestSha256; fileCount = $FileCount }
    [void](Write-BRAVOUpdateJournal -Journal $Journal -StateRoot $StateRoot)
    return $Journal
}

function Set-BRAVOUpdateJournalSchedulerSnapshot {
    # Шлях до JSON зі станом enabled керованих задач до операції; персистить.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )

    $Journal.schedulerSnapshot = [pscustomobject][ordered]@{ path = $Path }
    [void](Write-BRAVOUpdateJournal -Journal $Journal -StateRoot $StateRoot)
    return $Journal
}
