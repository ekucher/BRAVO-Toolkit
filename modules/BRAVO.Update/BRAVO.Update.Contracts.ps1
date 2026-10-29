# BRAVO.Update.Contracts — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Контракти даних Installer v1 (docs\installer\CONTRACTS.md): конструктори
# New-BRAVOUpdate<Name>, валідатори Test-BRAVOUpdate<Name> (повертають
# { IsValid, Problems[] } і нічого не кидають), серіалізація, JSONL-потік
# прогресу, відображення на коди BRAVO.ExitCodes.
#
# ЧОМУ валідатори, а не [ValidateSet] на об'єктах: контракти приходять з
# диска/GUI (ConvertFrom-Json), де типів немає. Валідатор — єдина межа
# довіри; пошкоджене/підмінене значення = IsValid $false (fail closed).

$script:BRAVOUpdateSecretPropertyPattern = '(?i)password|secret|token|apikey|api_key|privatekey|passphrase|webhook'
$script:BRAVOUpdateCredentialPresenceValues = @('Found', 'Missing', 'Unknown', 'NotRequired')
$script:BRAVOUpdateFindingSeverities = @('Ok', 'Warning', 'Blocker', 'NotApplicable')
$script:BRAVOUpdateProgressPhases = @('Preflight', 'Acquire', 'Verify', 'Stage', 'Backup', 'Deploy', 'Configure', 'Validate', 'Activate', 'Commit', 'Rollback', 'Recovery')
$script:BRAVOUpdateProgressStatuses = @('Started', 'Progress', 'Heartbeat', 'Completed', 'Failed', 'Skipped')
$script:BRAVOUpdateInstallationStates = @('NotInstalled', 'Installed', 'UpdateAvailable', 'PrereleaseInstalled', 'Degraded', 'RepairRequired', 'InterruptedUpdate', 'RollbackRequired', 'Unsupported', 'Ambiguous')
$script:BRAVOUpdateOperations = @('Install', 'Update', 'Repair', 'Diagnose')
$script:BRAVOUpdatePlanActions = @('Install', 'Update', 'Repair')
$script:BRAVOUpdateResultStatuses = @('Success', 'SuccessWithWarnings', 'Failed', 'RolledBack', 'Critical')
$script:BRAVOUpdateResultReasonCodes = @('Blocked', 'Cancelled', 'PlanStale', 'VerificationFailed', 'Error')
$script:BRAVOUpdateFailedExitCodeHints = @(20, 30, 31, 33, 35, 36, 37, 42)
$script:BRAVOUpdateContractKinds = @('InstallationState', 'PreflightResult', 'DeploymentPlan', 'ProgressEvent', 'DeploymentResult', 'UpdateJournal')

# ---------------------------------------------------------------------------
# Дрібні helper-и (приватні)
# ---------------------------------------------------------------------------

function Get-BRAVOUpdateUtcNowText {
    [CmdletBinding()]
    param()
    return [datetime]::UtcNow.ToString('o')
}

function Test-BRAVOUpdateHasProperty {
    # Працює однаково для PSCustomObject (з JSON) і hashtable (з коду).
    # StrictMode 2.0 кидає виняток на відсутню властивість, тому доступ лише через цей helper.
    [CmdletBinding()]
    param([AllowNull()]$InputObject, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [System.Collections.IDictionary]) { return [bool]$InputObject.Contains($Name) }
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function Get-BRAVOUpdatePropertyValue {
    [CmdletBinding()]
    param([AllowNull()]$InputObject, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)

    $value = $Default
    $found = Test-BRAVOUpdateHasProperty -InputObject $InputObject -Name $Name
    if ($found) { if ($InputObject -is [System.Collections.IDictionary]) { $value = $InputObject[$Name] } else { $value = $InputObject.PSObject.Properties[$Name].Value } }
    return $value
}

function ConvertTo-BRAVOUpdateUtcText {
    # PS 5.1 ConvertFrom-Json перетворює ISO-рядки на DateTime (Local); повертаємо канонічний UTC 'o'.
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    return [string]$Value
}

function Test-BRAVOUpdateTimestampValue {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($Value -is [datetime]) { return $true }
    if (($Value -isnot [string]) -or [string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = [datetime]::MinValue
    return [datetime]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)
}

function Test-BRAVOUpdateGuidText {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    return (($Value -is [string]) -and ($Value -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
}

function Test-BRAVOUpdateWholeNumber {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    return (($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [int16]) -or ($Value -is [byte]))
}

function New-BRAVOUpdateValidationResult {
    [CmdletBinding()]
    param([AllowNull()][System.Collections.Generic.List[string]]$Problems)

    $list = @()
    if ($null -ne $Problems) { $list = @($Problems.ToArray()) }
    return [pscustomobject]@{ IsValid = ($list.Count -eq 0); Problems = $list }
}

function Test-BRAVOUpdateContractBase {
    # Спільна частина: об'єкт, не масив, schemaVersion = 1, жодних секретних властивостей.
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Problems,
        [string[]]$RequiredField = @()
    )

    if ($null -eq $InputObject) { $Problems.Add('Контракт порожній ($null).'); return $false }
    if (($InputObject -is [string]) -or (($InputObject -is [System.Collections.IEnumerable]) -and ($InputObject -isnot [System.Collections.IDictionary]))) {
        $Problems.Add('Контракт має бути об''єктом, а не рядком чи масивом.')
        return $false
    }
    foreach ($name in $RequiredField) {
        if (-not (Test-BRAVOUpdateHasProperty -InputObject $InputObject -Name $name)) { $Problems.Add("Відсутнє обов'язкове поле '$name'.") }
    }
    if (Test-BRAVOUpdateHasProperty -InputObject $InputObject -Name 'schemaVersion') {
        $version = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'schemaVersion'
        if ((-not (Test-BRAVOUpdateWholeNumber -Value $version)) -or ([int]$version -ne 1)) { $Problems.Add("Непідтримуваний schemaVersion: '$version' (очікується 1).") }
    }
    $secretCheck = Test-BRAVOUpdateNoSecretProperty -InputObject $InputObject
    foreach ($problem in $secretCheck.Problems) { $Problems.Add($problem) }
    return $true
}

function Test-BRAVOUpdateEnumValue {
    [CmdletBinding()]
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$FieldName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Problems,
        [switch]$AllowNull
    )

    if ($null -eq $Value) {
        if (-not $AllowNull) { $Problems.Add("Поле '$FieldName' не може бути порожнім.") }
        return
    }
    if (($Value -isnot [string]) -or ($Allowed -cnotcontains $Value)) {
        $Problems.Add("Поле '$FieldName' має недопустиме значення '$Value' (дозволено: $($Allowed -join ', ')).")
    }
}

function Test-BRAVOUpdateFindingList {
    [CmdletBinding()]
    param(
        [AllowNull()]$Findings,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Problems,
        [string]$FieldName = 'findings'
    )

    # Порожній масив через helper стає $null: відсутність поля вже фіксує перелік обов'язкових полів.
    if ($null -eq $Findings) { return }
    $index = 0
    foreach ($finding in @($Findings)) {
        $check = Test-BRAVOUpdateFinding -InputObject $finding
        foreach ($problem in $check.Problems) { $Problems.Add("${FieldName}[$index]: $problem") }
        $index++
    }
}

# ---------------------------------------------------------------------------
# Finding
# ---------------------------------------------------------------------------

function New-BRAVOUpdateFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('Ok', 'Warning', 'Blocker', 'NotApplicable')][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Meaning = '',
        [string]$Action = '',
        [string]$Details = '',
        [AllowNull()][object]$ExitCodeHint = $null
    )

    if ([string]::IsNullOrWhiteSpace($Id)) { throw 'BRAVO.Update: Finding.id не може бути порожнім.' }
    if ($Severity -eq 'Blocker' -and [string]::IsNullOrWhiteSpace($Action)) {
        throw "BRAVO.Update: Blocker '$Id' мусить мати Action (що зробити оператору)."
    }
    if ($null -ne $ExitCodeHint) {
        if (-not (Test-BRAVOUpdateWholeNumber -Value $ExitCodeHint)) { throw "BRAVO.Update: ExitCodeHint для '$Id' має бути цілим числом." }
        $ExitCodeHint = [int]$ExitCodeHint
    }
    return [pscustomobject][ordered]@{
        id           = $Id
        severity     = $Severity
        title        = $Title
        meaning      = $Meaning
        action       = $Action
        details      = $Details
        exitCodeHint = $ExitCodeHint
    }
}

function Test-BRAVOUpdateFinding {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$InputObject)

    $problems = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $InputObject) { $problems.Add('Finding порожній.'); return (New-BRAVOUpdateValidationResult -Problems $problems) }
    foreach ($name in @('id', 'severity', 'title', 'meaning', 'action', 'details', 'exitCodeHint')) {
        if (-not (Test-BRAVOUpdateHasProperty -InputObject $InputObject -Name $name)) { $problems.Add("Відсутнє поле '$name'.") }
    }
    $id = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'id'
    if (($id -isnot [string]) -or [string]::IsNullOrWhiteSpace($id)) { $problems.Add('Finding.id порожній.') }
    $severity = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'severity'
    Test-BRAVOUpdateEnumValue -Value $severity -Allowed $script:BRAVOUpdateFindingSeverities -FieldName 'severity' -Problems $problems
    if ($severity -ceq 'Blocker') {
        $action = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'action'
        if (($action -isnot [string]) -or [string]::IsNullOrWhiteSpace($action)) { $problems.Add('Blocker без action.') }
    }
    $hint = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'exitCodeHint'
    if (($null -ne $hint) -and (-not (Test-BRAVOUpdateWholeNumber -Value $hint))) { $problems.Add('exitCodeHint має бути цілим або null.') }
    $secretCheck = Test-BRAVOUpdateNoSecretProperty -InputObject $InputObject
    foreach ($problem in $secretCheck.Problems) { $problems.Add($problem) }
    return (New-BRAVOUpdateValidationResult -Problems $problems)
}

function Get-BRAVOUpdateFindingSummary {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Findings)

    $blockers = 0
    $warnings = 0
    foreach ($finding in @($Findings)) {
        if ($null -eq $finding) { continue }
        $severity = Get-BRAVOUpdatePropertyValue -InputObject $finding -Name 'severity'
        if ($severity -ceq 'Blocker') { $blockers++ } elseif ($severity -ceq 'Warning') { $warnings++ }
    }
    return [pscustomobject]@{ BlockerCount = $blockers; WarningCount = $warnings; CanProceed = ($blockers -eq 0) }
}

function Format-BRAVOUpdateFindingMarker {
    # Маркер завжди разом із текстом (не лише колір) — UX.md.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Ok', 'Warning', 'Blocker', 'NotApplicable')][string]$Severity)

    switch ($Severity) {
        'Ok' { return '✓' }
        'Warning' { return '!' }
        'Blocker' { return '×' }
        default { return '—' }
    }
}

# ---------------------------------------------------------------------------
# Секрети, канонічний JSON, SHA-256
# ---------------------------------------------------------------------------

function Test-BRAVOUpdateNoSecretProperty {
    <#
    .SYNOPSIS
        Єдина канонічна перевірка «секретів у контрактах немає» (CONTRACTS §1).
    .DESCRIPTION
        Рекурсивно обходить PSCustomObject/hashtable/масиви й відхиляє будь-яке
        ім'я властивості за шаблоном секретів. Виняток: credentialPresence,
        значення якого лише Found|Missing|Unknown|NotRequired. Значення-рядки
        не скануються (лише імена), але глибина обмежена, щоб цикл не завис.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][AllowNull()]$InputObject)

    $problems = New-Object 'System.Collections.Generic.List[string]'
    Test-BRAVOUpdateNoSecretNode -Node $InputObject -Path '$' -Depth 0 -Problems $problems
    return [pscustomobject]@{ IsValid = ($problems.Count -eq 0); Problems = @($problems.ToArray()) }
}

function Test-BRAVOUpdateNoSecretNode {
    [CmdletBinding()]
    param(
        [AllowNull()]$Node,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Depth,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Problems
    )

    if ($null -eq $Node) { return }
    if (($Node -is [string]) -or ($Node -is [ValueType])) { return }
    if ($Depth -gt 24) { $Problems.Add("Занадто глибока структура на '$Path'."); return }

    $pairs = @()
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in @($Node.Keys)) { $pairs += , @([string]$key, $Node[$key]) }
    } elseif ($Node -is [System.Collections.IEnumerable]) {
        $position = 0
        foreach ($item in $Node) {
            Test-BRAVOUpdateNoSecretNode -Node $item -Path "$Path[$position]" -Depth ($Depth + 1) -Problems $Problems
            $position++
        }
        return
    } else {
        foreach ($property in $Node.PSObject.Properties) {
            if ($property.MemberType -in @('NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty')) { $pairs += , @([string]$property.Name, $property.Value) }
        }
    }
    foreach ($pair in $pairs) {
        $name = $pair[0]
        $value = $pair[1]
        $childPath = "$Path.$name"
        if ($name -ieq 'credentialPresence') {
            if (($value -isnot [string]) -or ($script:BRAVOUpdateCredentialPresenceValues -cnotcontains $value)) {
                $Problems.Add("credentialPresence на '$childPath' має значення поза Found|Missing|Unknown|NotRequired.")
            }
            continue
        }
        if ($name -match $script:BRAVOUpdateSecretPropertyPattern) {
            $Problems.Add("Заборонена секретна властивість '$childPath'.")
            continue
        }
        Test-BRAVOUpdateNoSecretNode -Node $value -Path $childPath -Depth ($Depth + 1) -Problems $Problems
    }
}

function ConvertTo-BRAVOUpdateJsonString {
    # Власне екранування (а не ConvertTo-Json): PS 5.1 екранує <,>,&,' як \uXXXX непослідовно між версіями,
    # а канонічна форма для SHA-256 мусить бути стабільною.
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($character in $Text.ToCharArray()) {
        $code = [int]$character
        switch ($code) {
            34 { [void]$builder.Append('\"') }
            92 { [void]$builder.Append('\\') }
            8 { [void]$builder.Append('\b') }
            12 { [void]$builder.Append('\f') }
            10 { [void]$builder.Append('\n') }
            13 { [void]$builder.Append('\r') }
            9 { [void]$builder.Append('\t') }
            default {
                if ($code -lt 32) { [void]$builder.Append(('\u{0:x4}' -f $code)) } else { [void]$builder.Append($character) }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-BRAVOUpdateCanonicalNode {
    [CmdletBinding()]
    param([AllowNull()]$Node, [Parameter(Mandatory = $true)][int]$Depth)

    if ($Depth -gt 32) { throw 'BRAVO.Update: структура для канонічного JSON занадто глибока.' }
    if ($null -eq $Node) { return 'null' }
    if ($Node -is [string]) { return (ConvertTo-BRAVOUpdateJsonString -Text $Node) }
    if ($Node -is [char]) { return (ConvertTo-BRAVOUpdateJsonString -Text ([string]$Node)) }
    if ($Node -is [bool]) { if ($Node) { return 'true' } else { return 'false' } }
    if ($Node -is [datetime]) { return (ConvertTo-BRAVOUpdateJsonString -Text ($Node.ToUniversalTime().ToString('o'))) }
    if (($Node -is [guid]) -or ($Node -is [Enum])) { return (ConvertTo-BRAVOUpdateJsonString -Text ([string]$Node)) }
    if ($Node -is [double]) { return $Node.ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
    if ($Node -is [ValueType]) { return ([string][Convert]::ToString($Node, [Globalization.CultureInfo]::InvariantCulture)) }

    $keys = @()
    $lookup = @{}
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in @($Node.Keys)) { $keys += [string]$key; $lookup[[string]$key] = $Node[$key] }
    } elseif ($Node -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Node) { $items.Add((ConvertTo-BRAVOUpdateCanonicalNode -Node $item -Depth ($Depth + 1))) }
        return '[' + ([string]::Join(',', $items.ToArray())) + ']'
    } else {
        foreach ($property in $Node.PSObject.Properties) {
            if ($property.MemberType -in @('NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty')) { $keys += [string]$property.Name; $lookup[[string]$property.Name] = $property.Value }
        }
    }
    $sortedKeys = [string[]]$keys
    [Array]::Sort($sortedKeys, [StringComparer]::Ordinal)
    $members = New-Object System.Collections.Generic.List[string]
    foreach ($key in $sortedKeys) {
        $members.Add((ConvertTo-BRAVOUpdateJsonString -Text $key) + ':' + (ConvertTo-BRAVOUpdateCanonicalNode -Node $lookup[$key] -Depth ($Depth + 1)))
    }
    return '{' + ([string]::Join(',', $members.ToArray())) + '}'
}

function Get-BRAVOUpdateCanonicalJson {
    <#
    .SYNOPSIS
        Компактний JSON зі стабільним порядком ключів (ordinal-сортування) —
        вхід для SHA-256 fingerprint-ів. Порядок елементів масивів зберігається.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$InputObject)

    return (ConvertTo-BRAVOUpdateCanonicalNode -Node $InputObject -Depth 0)
}

function Get-BRAVOUpdateSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash((New-Object System.Text.UTF8Encoding($false)).GetBytes($Text))
    } finally {
        $sha.Dispose()
    }
    return (([BitConverter]::ToString($hash)) -replace '-', '').ToUpperInvariant()
}

function ConvertTo-BRAVOUpdateJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$InputObject, [switch]$Compress)

    if ($Compress) { return ($InputObject | ConvertTo-Json -Depth 10 -Compress) }
    return ($InputObject | ConvertTo-Json -Depth 10)
}

function ConvertTo-BRAVOUpdateNormalizedObject {
    # Після ConvertFrom-Json (PS 5.1) DateTime -> канонічний UTC-рядок, щоб контракт
    # мав однакову форму і до, і після round-trip.
    [CmdletBinding()]
    param([AllowNull()]$Node)

    if ($null -eq $Node) { return $null }
    if ($Node -is [datetime]) { return $Node.ToUniversalTime().ToString('o') }
    if (($Node -is [string]) -or ($Node -is [ValueType])) { return $Node }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in @($Node.Keys)) { $Node[$key] = ConvertTo-BRAVOUpdateNormalizedObject -Node $Node[$key] }
        return $Node
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Node) { $list.Add((ConvertTo-BRAVOUpdateNormalizedObject -Node $item)) }
        return , $list.ToArray()
    }
    foreach ($property in @($Node.PSObject.Properties)) {
        if ($property.MemberType -eq 'NoteProperty') { $property.Value = ConvertTo-BRAVOUpdateNormalizedObject -Node $property.Value }
    }
    return $Node
}

# ---------------------------------------------------------------------------
# Коди завершення
# ---------------------------------------------------------------------------

function Initialize-BRAVOUpdateExitCodeModule {
    [CmdletBinding()]
    param()

    if ($null -ne (Get-Command -Name 'Get-BRAVOExitCodeName' -ErrorAction SilentlyContinue)) { return }
    $manifest = Join-Path $script:BRAVOUpdateToolkitRoot 'modules\BRAVO.ExitCodes\BRAVO.ExitCodes.psd1'
    Import-Module -Name $manifest -ErrorAction Stop
}

function ConvertTo-BRAVOUpdateExitCode {
    <#
    .SYNOPSIS
        Відображення DeploymentResult на канонічний код (CONTRACTS §7).
    .DESCRIPTION
        Success=0; SuccessWithWarnings=10; Failed -> exitCodeHint ПЕРШОГО blocker-а,
        якщо він серед 20/30/31/33/35/36/37/42, інакше 80; RolledBack=81;
        Critical=82; невідомий статус -> 80 (fail closed).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Result)

    $status = [string](Get-BRAVOUpdatePropertyValue -InputObject $Result -Name 'status' -Default '')
    switch -CaseSensitive ($status) {
        'Success' { return 0 }
        'SuccessWithWarnings' { return 10 }
        'RolledBack' { return 81 }
        'Critical' { return 82 }
        'Failed' {
            foreach ($finding in @(Get-BRAVOUpdatePropertyValue -InputObject $Result -Name 'findings' -Default @())) {
                if ((Get-BRAVOUpdatePropertyValue -InputObject $finding -Name 'severity') -ceq 'Blocker') {
                    $hint = Get-BRAVOUpdatePropertyValue -InputObject $finding -Name 'exitCodeHint'
                    if ((Test-BRAVOUpdateWholeNumber -Value $hint) -and ($script:BRAVOUpdateFailedExitCodeHints -contains [int]$hint)) { return [int]$hint }
                    break
                }
            }
            return 80
        }
        default { return 80 }
    }
}

# ---------------------------------------------------------------------------
# InstallationState
# ---------------------------------------------------------------------------

function New-BRAVOUpdateInstallationState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Credentials', Justification = 'Параметр Credentials — об''єкт зі статусом присутності облікових даних (credentialPresence), не секрет; ім''я задане контрактом CONTRACTS §3.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('NotInstalled', 'Installed', 'UpdateAvailable', 'PrereleaseInstalled', 'Degraded', 'RepairRequired', 'InterruptedUpdate', 'RollbackRequired', 'Unsupported', 'Ambiguous')][string]$State,
        [AllowNull()][string]$RuntimeRoot = $null,
        [string[]]$CandidateRoots = @(),
        [AllowNull()]$Version = $null,
        $Integrity = $null,
        $VersionState = $null,
        $Configuration = $null,
        $Scheduler = $null,
        $Credentials = $null,
        $InterruptedOperation = $null,
        $LifecycleLock = $null,
        [object[]]$Findings = @(),
        [string]$GeneratedUtc = ''
    )

    if ([string]::IsNullOrEmpty($RuntimeRoot)) { $RuntimeRoot = $null }
    if ($null -eq $Integrity) { $Integrity = [pscustomobject][ordered]@{ status = 'Unknown'; checkedCount = 0; mismatchedCount = 0; missingCount = 0; unknownCount = 0; message = '' } }
    if ($null -eq $VersionState) { $VersionState = [pscustomobject][ordered]@{ recordedVersion = $null; statePathKind = 'Production' } }
    if ($null -eq $Configuration) { $Configuration = [pscustomobject][ordered]@{ localConfigPresent = $false; legacyConfigPresent = $false; localConfigSchemaValid = $true; migrationBlocker = [pscustomobject][ordered]@{ blocked = $false; reasons = @() } } }
    if ($null -eq $Scheduler) { $Scheduler = [pscustomobject][ordered]@{ status = 'Unknown'; tasks = @() } }
    if ($null -eq $Credentials) { $Credentials = [pscustomobject][ordered]@{ status = 'Unknown'; items = @() } }
    if ($null -eq $InterruptedOperation) { $InterruptedOperation = [pscustomobject][ordered]@{ present = $false; operationId = $null; action = $null; lastCompletedPhase = $null; mutationStarted = $false; journalPath = $null } }
    if ($null -eq $LifecycleLock) { $LifecycleLock = [pscustomobject][ordered]@{ held = $false; holderDescription = '' } }
    if ([string]::IsNullOrWhiteSpace($GeneratedUtc)) { $GeneratedUtc = Get-BRAVOUpdateUtcNowText }

    return [pscustomobject][ordered]@{
        schemaVersion        = 1
        generatedUtc         = $GeneratedUtc
        state                = $State
        runtimeRoot          = $RuntimeRoot
        candidateRoots       = @($CandidateRoots)
        version              = $Version
        integrity            = $Integrity
        versionState         = $VersionState
        configuration        = $Configuration
        scheduler            = $Scheduler
        credentials          = $Credentials
        interruptedOperation = $InterruptedOperation
        lifecycleLock        = $LifecycleLock
        findings             = @($Findings)
    }
}

function Test-BRAVOUpdateInstallationState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$InputObject)

    $problems = New-Object 'System.Collections.Generic.List[string]'
    $required = @('schemaVersion', 'generatedUtc', 'state', 'runtimeRoot', 'candidateRoots', 'version', 'integrity', 'versionState', 'configuration', 'scheduler', 'credentials', 'interruptedOperation', 'lifecycleLock', 'findings')
    if (Test-BRAVOUpdateContractBase -InputObject $InputObject -Problems $problems -RequiredField $required) {
        Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'state') -Allowed $script:BRAVOUpdateInstallationStates -FieldName 'state' -Problems $problems
        if (-not (Test-BRAVOUpdateTimestampValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'generatedUtc'))) { $problems.Add('generatedUtc не є датою ISO 8601.') }
        $integrity = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'integrity'
        if ($null -ne $integrity) { Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $integrity -Name 'status') -Allowed @('Valid', 'Invalid', 'Unknown') -FieldName 'integrity.status' -Problems $problems }
        $versionState = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'versionState'
        if ($null -ne $versionState) { Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $versionState -Name 'statePathKind') -Allowed @('Production', 'Sandbox') -FieldName 'versionState.statePathKind' -Problems $problems }
        $scheduler = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'scheduler'
        if ($null -ne $scheduler) { Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $scheduler -Name 'status') -Allowed @('Ok', 'Partial', 'Missing', 'Unknown') -FieldName 'scheduler.status' -Problems $problems }
        $credentials = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'credentials'
        if ($null -ne $credentials) {
            Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $credentials -Name 'status') -Allowed @('Unknown', 'Checked') -FieldName 'credentials.status' -Problems $problems
            foreach ($item in @(Get-BRAVOUpdatePropertyValue -InputObject $credentials -Name 'items' -Default @())) {
                Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'account') -Allowed @('TaskAccount', 'CurrentUser') -FieldName 'credentials.items.account' -Problems $problems
            }
        }
        Test-BRAVOUpdateFindingList -Findings (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'findings') -Problems $problems
    }
    return (New-BRAVOUpdateValidationResult -Problems $problems)
}

# ---------------------------------------------------------------------------
# PreflightResult
# ---------------------------------------------------------------------------

function New-BRAVOUpdatePreflightResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair', 'Diagnose')][string]$Operation,
        [AllowNull()][string]$RuntimeRoot = $null,
        [object[]]$Findings = @(),
        [AllowNull()][string]$Fingerprint = $null,
        [string]$GeneratedUtc = ''
    )

    if ([string]::IsNullOrWhiteSpace($GeneratedUtc)) { $GeneratedUtc = Get-BRAVOUpdateUtcNowText }
    if ([string]::IsNullOrEmpty($RuntimeRoot)) { $RuntimeRoot = $null }
    if ([string]::IsNullOrEmpty($Fingerprint)) { $Fingerprint = $null }
    $summary = Get-BRAVOUpdateFindingSummary -Findings $Findings
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        generatedUtc  = $GeneratedUtc
        operation     = $Operation
        runtimeRoot   = $RuntimeRoot
        findings      = @($Findings)
        canProceed    = [bool]$summary.CanProceed
        blockerCount  = [int]$summary.BlockerCount
        warningCount  = [int]$summary.WarningCount
        fingerprint   = $Fingerprint
    }
}

function Test-BRAVOUpdatePreflightResult {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$InputObject)

    $problems = New-Object 'System.Collections.Generic.List[string]'
    $required = @('schemaVersion', 'generatedUtc', 'operation', 'runtimeRoot', 'findings', 'canProceed', 'blockerCount', 'warningCount', 'fingerprint')
    if (Test-BRAVOUpdateContractBase -InputObject $InputObject -Problems $problems -RequiredField $required) {
        Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'operation') -Allowed $script:BRAVOUpdateOperations -FieldName 'operation' -Problems $problems
        if (-not (Test-BRAVOUpdateTimestampValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'generatedUtc'))) { $problems.Add('generatedUtc не є датою ISO 8601.') }
        $findings = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'findings'
        Test-BRAVOUpdateFindingList -Findings $findings -Problems $problems
        if ($null -ne $findings) {
            # canProceed/лічильники мають збігатися з findings: розбіжність = підміна або баг.
            $summary = Get-BRAVOUpdateFindingSummary -Findings @($findings)
            if ((Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'canProceed') -ne $summary.CanProceed) { $problems.Add('canProceed не відповідає findings.') }
            if ((Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'blockerCount') -ne $summary.BlockerCount) { $problems.Add('blockerCount не відповідає findings.') }
            if ((Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'warningCount') -ne $summary.WarningCount) { $problems.Add('warningCount не відповідає findings.') }
        }
    }
    return (New-BRAVOUpdateValidationResult -Problems $problems)
}

# ---------------------------------------------------------------------------
# DeploymentPlan
# ---------------------------------------------------------------------------

function New-BRAVOUpdateDeploymentPlan {
    <#
    .SYNOPSIS
        Конструктор плану. planId/operationId генеруються, якщо не задані;
        expiresUtc = createdUtc + TtlMinutes (default 30); requiresConfirmation завжди $true.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair')][string]$Action,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$StagingRoot,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        $Source = $null,
        [AllowNull()]$CurrentVersion = $null,
        [AllowNull()]$TargetVersion = $null,
        $Footprint = $null,
        $Changes = $null,
        [string[]]$Preserved = @(),
        $Tests = $null,
        [object[]]$Findings = @(),
        [AllowNull()][string]$PreconditionsFingerprint = $null,
        [string]$PlanId = '',
        [string]$OperationId = '',
        [string]$CreatedUtc = '',
        [int]$TtlMinutes = 30
    )

    if ([string]::IsNullOrEmpty($PreconditionsFingerprint)) { $PreconditionsFingerprint = $null }
    if ([string]::IsNullOrWhiteSpace($PlanId)) { $PlanId = [guid]::NewGuid().ToString() }
    if ([string]::IsNullOrWhiteSpace($OperationId)) { $OperationId = [guid]::NewGuid().ToString() }
    $PlanId = $PlanId.ToLowerInvariant()
    $OperationId = $OperationId.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($CreatedUtc)) { $CreatedUtc = Get-BRAVOUpdateUtcNowText }
    $created = [datetime]::Parse($CreatedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $expires = $created.ToUniversalTime().AddMinutes($TtlMinutes).ToString('o')

    if ($null -eq $Source) { $Source = [pscustomobject][ordered]@{ kind = 'Offline'; tag = $null; artifactName = $null; artifactSha256 = $null; manifestSha256 = $null; packageVersion = $null; releaseChannel = $null; prereleaseAuthorized = $false } }
    if ($null -eq $Footprint) { $Footprint = [pscustomobject][ordered]@{ stagingBytes = 0L; backupBytes = 0L; deployBytes = 0L; reserveBytes = 0L; requiredFreeBytes = 0L; availableFreeBytes = 0L; volume = $null } }
    if ($null -eq $Changes) { $Changes = [pscustomobject][ordered]@{ filesAdded = 0; filesChanged = 0; filesRemoved = 0; configuration = [pscustomobject][ordered]@{ localConfigPreserved = $true; legacyConfigPreserved = $true; delta = @() }; scheduler = [pscustomobject][ordered]@{ tasks = @(); activationPolicy = $null } } }
    if ($null -eq $Tests) { $Tests = [pscustomobject][ordered]@{ planned = @(); skipped = @() } }

    return [pscustomobject][ordered]@{
        schemaVersion            = 1
        planId                   = $PlanId
        operationId              = $OperationId
        action                   = $Action
        createdUtc               = (ConvertTo-BRAVOUpdateUtcText -Value $created)
        expiresUtc               = $expires
        runtimeRoot              = $RuntimeRoot
        stagingRoot              = $StagingRoot
        backupRoot               = $BackupRoot
        source                   = $Source
        currentVersion           = $CurrentVersion
        targetVersion            = $TargetVersion
        footprint                = $Footprint
        changes                  = $Changes
        preserved                = @($Preserved)
        tests                    = $Tests
        findings                 = @($Findings)
        preconditionsFingerprint = $PreconditionsFingerprint
        requiresConfirmation     = $true
    }
}

function Test-BRAVOUpdateDeploymentPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$InputObject)

    $problems = New-Object 'System.Collections.Generic.List[string]'
    $required = @('schemaVersion', 'planId', 'operationId', 'action', 'createdUtc', 'expiresUtc', 'runtimeRoot', 'stagingRoot', 'backupRoot', 'source', 'currentVersion', 'targetVersion', 'footprint', 'changes', 'preserved', 'tests', 'findings', 'preconditionsFingerprint', 'requiresConfirmation')
    if (Test-BRAVOUpdateContractBase -InputObject $InputObject -Problems $problems -RequiredField $required) {
        if (-not (Test-BRAVOUpdateGuidText -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'planId'))) { $problems.Add('planId має бути GUID у нижньому регістрі.') }
        if (-not (Test-BRAVOUpdateGuidText -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'operationId'))) { $problems.Add('operationId має бути GUID у нижньому регістрі.') }
        Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'action') -Allowed $script:BRAVOUpdatePlanActions -FieldName 'action' -Problems $problems
        $createdText = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'createdUtc'
        $expiresText = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'expiresUtc'
        $createdOk = Test-BRAVOUpdateTimestampValue -Value $createdText
        $expiresOk = Test-BRAVOUpdateTimestampValue -Value $expiresText
        if (-not $createdOk) { $problems.Add('createdUtc не є датою ISO 8601.') }
        if (-not $expiresOk) { $problems.Add('expiresUtc не є датою ISO 8601.') }
        if ($createdOk -and $expiresOk) {
            if ([datetime](ConvertTo-BRAVOUpdateUtcText -Value $expiresText) -le [datetime](ConvertTo-BRAVOUpdateUtcText -Value $createdText)) { $problems.Add('expiresUtc має бути пізніше createdUtc.') }
        }
        foreach ($rootName in @('runtimeRoot', 'stagingRoot', 'backupRoot')) {
            $rootValue = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name $rootName
            if (($rootValue -isnot [string]) -or [string]::IsNullOrWhiteSpace($rootValue)) { $problems.Add("$rootName порожній.") }
        }
        $source = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'source'
        if ($null -eq $source) { $problems.Add('source відсутній.') } else {
            Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $source -Name 'kind') -Allowed @('Online', 'Offline') -FieldName 'source.kind' -Problems $problems
        }
        $fingerprint = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'preconditionsFingerprint'
        if (($fingerprint -isnot [string]) -or ($fingerprint -cnotmatch '^[0-9A-F]{64}$')) { $problems.Add('preconditionsFingerprint має бути SHA-256 (64 hex, upper).') }
        if ((Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'requiresConfirmation') -ne $true) { $problems.Add('requiresConfirmation має бути $true.') }
        Test-BRAVOUpdateFindingList -Findings (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'findings') -Problems $problems
    }
    return (New-BRAVOUpdateValidationResult -Problems $problems)
}

# ---------------------------------------------------------------------------
# ProgressEvent
# ---------------------------------------------------------------------------

function New-BRAVOUpdateProgressEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][int]$Sequence,
        [Parameter(Mandatory = $true)][ValidateSet('Preflight', 'Acquire', 'Verify', 'Stage', 'Backup', 'Deploy', 'Configure', 'Validate', 'Activate', 'Commit', 'Rollback', 'Recovery')][string]$Phase,
        [Parameter(Mandatory = $true)][ValidateSet('Started', 'Progress', 'Heartbeat', 'Completed', 'Failed', 'Skipped')][string]$Status,
        [AllowNull()][object]$Percent = $null,
        [string]$MessageKey = '',
        [object[]]$MessageArgs = @(),
        [string]$Message = '',
        [string]$TimestampUtc = ''
    )

    if ([string]::IsNullOrWhiteSpace($TimestampUtc)) { $TimestampUtc = Get-BRAVOUpdateUtcNowText }
    if ($null -ne $Percent) { $Percent = [int]$Percent }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        operationId   = $OperationId.ToLowerInvariant()
        sequence      = $Sequence
        timestampUtc  = $TimestampUtc
        phase         = $Phase
        status        = $Status
        percent       = $Percent
        messageKey    = $MessageKey
        messageArgs   = @($MessageArgs)
        message       = $Message
    }
}

function Test-BRAVOUpdateProgressEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$InputObject)

    $problems = New-Object 'System.Collections.Generic.List[string]'
    $required = @('schemaVersion', 'operationId', 'sequence', 'timestampUtc', 'phase', 'status', 'percent', 'messageKey', 'messageArgs', 'message')
    if (Test-BRAVOUpdateContractBase -InputObject $InputObject -Problems $problems -RequiredField $required) {
        if (-not (Test-BRAVOUpdateGuidText -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'operationId'))) { $problems.Add('operationId має бути GUID у нижньому регістрі.') }
        $sequence = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'sequence'
        if ((-not (Test-BRAVOUpdateWholeNumber -Value $sequence)) -or ([long]$sequence -lt 1)) { $problems.Add('sequence має бути цілим >= 1.') }
        if (-not (Test-BRAVOUpdateTimestampValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'timestampUtc'))) { $problems.Add('timestampUtc не є датою ISO 8601.') }
        Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'phase') -Allowed $script:BRAVOUpdateProgressPhases -FieldName 'phase' -Problems $problems
        Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'status') -Allowed $script:BRAVOUpdateProgressStatuses -FieldName 'status' -Problems $problems
        $percent = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'percent'
        if ($null -ne $percent) {
            if ((-not ($percent -is [ValueType])) -or ($percent -is [bool]) -or ($percent -is [string]) -or ([double]$percent -lt 0) -or ([double]$percent -gt 100)) { $problems.Add('percent має бути null або числом 0-100.') }
        }
    }
    return (New-BRAVOUpdateValidationResult -Problems $problems)
}

function Write-BRAVOUpdateProgressEvent {
    <#
    .SYNOPSIS
        Дописує одну подію JSONL-рядком (UTF-8 без BOM) із flush на диск.
    .DESCRIPTION
        Один Write одним буфером (рядок + LF) мінімізує ризик «рваного» рядка.
        Якщо попередній запис обірвався без LF, перед новою подією додається LF,
        інакше нова подія склеїлась би з уламком і втратилась би.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()]$Event
    )

    $check = Test-BRAVOUpdateProgressEvent -InputObject $Event
    if (-not $check.IsValid) { throw ('BRAVO.Update: некоректна подія прогресу: ' + ($check.Problems -join '; ')) }
    $directory = [IO.Path]::GetDirectoryName($Path)
    if ((-not [string]::IsNullOrWhiteSpace($directory)) -and (-not [IO.Directory]::Exists($directory))) { [void][IO.Directory]::CreateDirectory($directory) }

    $line = ($Event | ConvertTo-Json -Depth 10 -Compress)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($line + "`n")
    $stream = New-Object System.IO.FileStream($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
    try {
        $length = $stream.Length
        $prefix = New-Object 'byte[]' 0
        if ($length -gt 0) {
            [void]$stream.Seek($length - 1, [IO.SeekOrigin]::Begin)
            if ($stream.ReadByte() -ne 10) { $prefix = [byte[]]@(10) }
        }
        [void]$stream.Seek(0, [IO.SeekOrigin]::End)
        $buffer = New-Object 'byte[]' ($prefix.Length + $bytes.Length)
        [Array]::Copy($prefix, 0, $buffer, 0, $prefix.Length)
        [Array]::Copy($bytes, 0, $buffer, $prefix.Length, $bytes.Length)
        $stream.Write($buffer, 0, $buffer.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Read-BRAVOUpdateProgressEvents {
    <#
    .SYNOPSIS
        Читає події з progress.jsonl; нечитабельні (зокрема «рваний» останній)
        рядки пропускає без винятку. Повертає масив (обгортайте в @()).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$AfterSequence = 0
    )

    if (-not [IO.File]::Exists($Path)) { return @() }
    $stream = $null
    $text = ''
    try {
        # ReadWrite-share: GUI читає, поки worker дописує.
        $stream = New-Object System.IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)), $true)
        $text = $reader.ReadToEnd()
    } catch {
        return @()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    $events = New-Object System.Collections.Generic.List[object]
    foreach ($rawLine in ($text -split "`n")) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0) { continue }
        $parsed = $null
        try { $parsed = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (($null -eq $parsed) -or (-not (Test-BRAVOUpdateHasProperty -InputObject $parsed -Name 'sequence'))) { continue }
        $parsed = ConvertTo-BRAVOUpdateNormalizedObject -Node $parsed
        if ((Test-BRAVOUpdateWholeNumber -Value $parsed.sequence) -and ([long]$parsed.sequence -gt $AfterSequence)) { $events.Add($parsed) }
    }
    return $events.ToArray()
}

function Send-BRAVOUpdateProgress {
    # Присвоює наступний sequence з writer-а, пише подію й повертає її.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Writer,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][object]$Percent = $null,
        [string]$MessageKey = '',
        [object[]]$MessageArgs = @(),
        [string]$Message = ''
    )

    $next = [long]$Writer.State.Sequence + 1
    if ([string]::IsNullOrWhiteSpace($Message)) { $Message = $MessageKey }
    $progressEvent = New-BRAVOUpdateProgressEvent -OperationId $Writer.OperationId -Sequence ([int]$next) -Phase $Phase -Status $Status -Percent $Percent -MessageKey $MessageKey -MessageArgs $MessageArgs -Message $Message
    Write-BRAVOUpdateProgressEvent -Path $Writer.Path -Event $progressEvent
    # Лічильник зсуваємо ЛИШЕ після успішного запису: збій не створює «дірку» в sequence.
    $Writer.State.Sequence = $next
    return $progressEvent
}

function New-BRAVOUpdateProgressWriter {
    <#
    .SYNOPSIS
        Writer прогресу: об'єкт із Path, OperationId, State.Sequence і методом
        Emit(Phase, Status, Percent, MessageKey, MessageArgs, Message) (синонім Write).
    .DESCRIPTION
        Якщо файл уже містить події цієї операції (перезапуск worker-а),
        нумерація продовжується з максимального sequence — монотонність
        зберігається між процесами.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    $last = 0L
    foreach ($existing in @(Read-BRAVOUpdateProgressEvents -Path $Path)) {
        if ([long]$existing.sequence -gt $last) { $last = [long]$existing.sequence }
    }
    $writer = [pscustomobject]@{ Path = $Path; OperationId = $OperationId.ToLowerInvariant(); State = @{ Sequence = $last } }
    $emit = {
        param([string]$Phase, [string]$Status, [object]$Percent = $null, [string]$MessageKey = '', [object[]]$MessageArgs = @(), [string]$Message = '')
        Send-BRAVOUpdateProgress -Writer $this -Phase $Phase -Status $Status -Percent $Percent -MessageKey $MessageKey -MessageArgs $MessageArgs -Message $Message
    }
    Add-Member -InputObject $writer -MemberType ScriptMethod -Name 'Emit' -Value $emit
    Add-Member -InputObject $writer -MemberType ScriptMethod -Name 'Write' -Value $emit
    return $writer
}

# ---------------------------------------------------------------------------
# DeploymentResult
# ---------------------------------------------------------------------------

function New-BRAVOUpdateDeploymentResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OperationId,
        [AllowNull()][string]$PlanId = $null,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair', 'Rollback', 'Recovery')][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('Success', 'SuccessWithWarnings', 'Failed', 'RolledBack', 'Critical')][string]$Status,
        [ValidateSet('', 'Blocked', 'Cancelled', 'PlanStale', 'VerificationFailed', 'Error')][string]$ReasonCode = '',
        [AllowNull()][object]$ExitCode = $null,
        [AllowNull()]$SourceVersion = $null,
        [AllowNull()]$TargetVersion = $null,
        [AllowNull()]$InstalledVersion = $null,
        [AllowNull()][string]$LastPhase = $null,
        [bool]$MutationStarted = $false,
        [object[]]$Validation = @(),
        $Rollback = $null,
        $TaskActivation = $null,
        [object[]]$Findings = @(),
        [AllowNull()][string]$LogPath = $null,
        [AllowNull()][string]$ReportPath = $null,
        [AllowNull()][string]$JournalPath = $null,
        [string]$StartedUtc = '',
        [string]$FinishedUtc = ''
    )

    # [string]-параметри з $null стають '' — у контракті порожнє значення має бути $null.
    # Присвоєння $null типізованій змінній знову дало б '', тому окремі змінні.
    $reasonValue = $null; if (-not [string]::IsNullOrEmpty($ReasonCode)) { $reasonValue = $ReasonCode }
    $planValue = $null; if (-not [string]::IsNullOrEmpty($PlanId)) { $planValue = $PlanId }
    $phaseValue = $null; if (-not [string]::IsNullOrEmpty($LastPhase)) { $phaseValue = $LastPhase }
    $logValue = $null; if (-not [string]::IsNullOrEmpty($LogPath)) { $logValue = $LogPath }
    $reportValue = $null; if (-not [string]::IsNullOrEmpty($ReportPath)) { $reportValue = $ReportPath }
    $journalValue = $null; if (-not [string]::IsNullOrEmpty($JournalPath)) { $journalValue = $JournalPath }
    if ($null -eq $Rollback) { $Rollback = [pscustomobject][ordered]@{ attempted = $false; status = 'NotNeeded'; message = '' } }
    if ($null -eq $TaskActivation) { $TaskActivation = [pscustomobject][ordered]@{ state = 'Unchanged'; tasks = @() } }
    $now = Get-BRAVOUpdateUtcNowText
    if ([string]::IsNullOrWhiteSpace($StartedUtc)) { $StartedUtc = $now }
    if ([string]::IsNullOrWhiteSpace($FinishedUtc)) { $FinishedUtc = $now }

    $result = [pscustomobject][ordered]@{
        schemaVersion    = 1
        operationId      = $OperationId.ToLowerInvariant()
        planId           = $planValue
        action           = $Action
        status           = $Status
        reasonCode       = $reasonValue
        exitCode         = $null
        exitCodeName     = $null
        sourceVersion    = $SourceVersion
        targetVersion    = $TargetVersion
        installedVersion = $InstalledVersion
        lastPhase        = $phaseValue
        mutationStarted  = $MutationStarted
        validation       = @($Validation)
        rollback         = $Rollback
        taskActivation   = $TaskActivation
        findings         = @($Findings)
        logPath          = $logValue
        reportPath       = $reportValue
        journalPath      = $journalValue
        startedUtc       = $StartedUtc
        finishedUtc      = $FinishedUtc
    }
    # Код — лише через відображення §7 і BRAVO.ExitCodes (явний -ExitCode має бути узгодженим, інакше валідатор відхилить).
    Initialize-BRAVOUpdateExitCodeModule
    if ($null -eq $ExitCode) { $ExitCode = ConvertTo-BRAVOUpdateExitCode -Result $result }
    $result.exitCode = [int]$ExitCode
    $result.exitCodeName = Get-BRAVOExitCodeName -Code ([int]$ExitCode)
    return $result
}

function Test-BRAVOUpdateDeploymentResult {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$InputObject)

    $problems = New-Object 'System.Collections.Generic.List[string]'
    $required = @('schemaVersion', 'operationId', 'planId', 'action', 'status', 'reasonCode', 'exitCode', 'exitCodeName', 'sourceVersion', 'targetVersion', 'installedVersion', 'lastPhase', 'mutationStarted', 'validation', 'rollback', 'taskActivation', 'findings', 'logPath', 'reportPath', 'journalPath', 'startedUtc', 'finishedUtc')
    if (Test-BRAVOUpdateContractBase -InputObject $InputObject -Problems $problems -RequiredField $required) {
        if (-not (Test-BRAVOUpdateGuidText -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'operationId'))) { $problems.Add('operationId має бути GUID у нижньому регістрі.') }
        $planId = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'planId'
        if (($null -ne $planId) -and (-not (Test-BRAVOUpdateGuidText -Value $planId))) { $problems.Add('planId має бути GUID або null.') }
        Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'action') -Allowed @('Install', 'Update', 'Repair', 'Rollback', 'Recovery') -FieldName 'action' -Problems $problems
        $status = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'status'
        Test-BRAVOUpdateEnumValue -Value $status -Allowed $script:BRAVOUpdateResultStatuses -FieldName 'status' -Problems $problems
        $reason = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'reasonCode'
        if ($status -ceq 'Failed') {
            Test-BRAVOUpdateEnumValue -Value $reason -Allowed $script:BRAVOUpdateResultReasonCodes -FieldName 'reasonCode' -Problems $problems
        } else {
            Test-BRAVOUpdateEnumValue -Value $reason -Allowed $script:BRAVOUpdateResultReasonCodes -FieldName 'reasonCode' -Problems $problems -AllowNull
        }
        $exitCode = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'exitCode'
        if (-not (Test-BRAVOUpdateWholeNumber -Value $exitCode)) {
            $problems.Add('exitCode має бути цілим.')
        } elseif ($script:BRAVOUpdateResultStatuses -ccontains $status) {
            $expected = ConvertTo-BRAVOUpdateExitCode -Result $InputObject
            if ([int]$exitCode -ne $expected) { $problems.Add("exitCode $exitCode не відповідає статусу '$status' (очікується $expected).") }
        }
        $exitName = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'exitCodeName'
        if (($exitName -isnot [string]) -or [string]::IsNullOrWhiteSpace($exitName)) { $problems.Add('exitCodeName порожній.') }
        foreach ($item in @(Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'validation' -Default @())) {
            Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'status') -Allowed @('Pass', 'Warn', 'Fail', 'Skipped') -FieldName 'validation.status' -Problems $problems
        }
        $rollback = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'rollback'
        if ($null -ne $rollback) { Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $rollback -Name 'status') -Allowed @('NotNeeded', 'Succeeded', 'Failed') -FieldName 'rollback.status' -Problems $problems }
        $activation = Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'taskActivation'
        if ($null -ne $activation) { Test-BRAVOUpdateEnumValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $activation -Name 'state') -Allowed @('Active', 'Inactive', 'Unchanged', 'Unknown') -FieldName 'taskActivation.state' -Problems $problems }
        foreach ($timeName in @('startedUtc', 'finishedUtc')) {
            if (-not (Test-BRAVOUpdateTimestampValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name $timeName))) { $problems.Add("$timeName не є датою ISO 8601.") }
        }
        Test-BRAVOUpdateFindingList -Findings (Get-BRAVOUpdatePropertyValue -InputObject $InputObject -Name 'findings') -Problems $problems
    }
    return (New-BRAVOUpdateValidationResult -Problems $problems)
}

# ---------------------------------------------------------------------------
# Читання контрактів з диска (fail closed)
# ---------------------------------------------------------------------------

function Read-BRAVOUpdateContractFile {
    <#
    .SYNOPSIS
        Читає й валідує контракт; ніколи не кидає. Повертає
        { IsValid, Problems[], Contract, Path, Kind }.
    .DESCRIPTION
        Відсутній, порожній чи пошкоджений файл, непарсабельний JSON або
        невалідна схема = IsValid $false (Contract може бути $null).
        Kind UpdateJournal використовує Test-BRAVOUpdateJournal із частини Journal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('InstallationState', 'PreflightResult', 'DeploymentPlan', 'ProgressEvent', 'DeploymentResult', 'UpdateJournal')][string]$Kind
    )

    $fail = {
        param([string]$Reason, $Contract)
        [pscustomobject]@{ IsValid = $false; Problems = @($Reason); Contract = $Contract; Path = $Path; Kind = $Kind }
    }
    if (-not [IO.File]::Exists($Path)) { return (& $fail "Файл не знайдено: $Path" $null) }
    $text = $null
    try { $text = [IO.File]::ReadAllText($Path) } catch { return (& $fail "Не вдалося прочитати файл: $($_.Exception.Message)" $null) }
    if ([string]::IsNullOrWhiteSpace($text)) { return (& $fail 'Файл порожній.' $null) }
    $parsed = $null
    try { $parsed = $text | ConvertFrom-Json -ErrorAction Stop } catch { return (& $fail "Пошкоджений JSON: $($_.Exception.Message)" $null) }
    if ($null -eq $parsed) { return (& $fail 'JSON не містить об''єкта.' $null) }
    $parsed = ConvertTo-BRAVOUpdateNormalizedObject -Node $parsed

    $validatorName = 'Test-BRAVOUpdate' + $(if ($Kind -eq 'UpdateJournal') { 'Journal' } else { $Kind })
    if ($null -eq (Get-Command -Name $validatorName -ErrorAction SilentlyContinue)) { return (& $fail "Валідатор '$validatorName' недоступний." $parsed) }
    $check = & $validatorName -InputObject $parsed
    return [pscustomobject]@{ IsValid = [bool]$check.IsValid; Problems = @($check.Problems); Contract = $parsed; Path = $Path; Kind = $Kind }
}
