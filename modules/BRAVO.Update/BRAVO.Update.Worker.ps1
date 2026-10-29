# BRAVO.Update.Worker — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Worker-протокол (CONTRACTS §10, ENGINE_DESIGN §10) і диспетчер тонкого CLI
# BRAVO_UPDATE.ps1. Уся нетривіальна логіка CLI живе тут, щоб entrypoint лише
# зв'язував параметри, викликав Invoke-BRAVOUpdateCliAction і виходив.
#
# Модель довіри: GUI працює без прав і лише ПИШЕ запит у
# <StateRoot>\Requests\<guid>.json; авторизація mutation — це UAC (запускач
# worker-а), сам файл НЕДОВІРЕНИЙ. Тому worker перечитує його один раз, суворо
# перевіряє шлях/розмір/схему/секрети/короткий id і НЕ бере на віру жодного
# кореня з запиту (staging/backup == Get-BRAVOUpdateDefaultPaths, runtime ==
# знайдений кореневий каталог або каталог, що проходить політику Install).
#
# Інваріанти частини: жодного виводу в консоль, жодного exit, жодного
# FaultInjection з запиту/аргументів (збої інжектуються лише тестами через
# оркестратори), жодного стану $script: окрім констант. Операції (Install /
# Update / Repair / Recover) викликаються за ІМЕНЕМ або через seam -Operations.

$script:BRAVOUpdateWorkerMaxRequestBytes = 1048576
$script:BRAVOUpdateWorkerRequestLeafPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$'
$script:BRAVOUpdateWorkerBackupDestinations = @('Cloud', 'CloudAndSamba', 'SambaOnly', 'LocalOnly')
$script:BRAVOUpdateWorkerScopes = @('All', 'Runtime', 'Scheduler')
# Коди, які дозволено переносити з blocker-а на код завершення CLI
# (CONTRACTS §7); будь-який інший hint дає 80.
$script:BRAVOUpdateWorkerHintCodes = @(20, 30, 31, 33, 35, 36, 37, 42)
$script:BRAVOUpdateWorkerPlanWorkPrefix = 'BRAVO_UPDATE_PLAN_'

# ---------------------------------------------------------------------------
# Дрібні helper-и
# ---------------------------------------------------------------------------

function Test-BRAVOUpdateWorkerIsAdministrator {
    # Фактична перевірка прав поточного процесу (elevated Administrators).
    # Помилка визначення = $false (fail closed: mutation без доведених прав
    # не виконується).
    [CmdletBinding()]
    param()
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return [bool]$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function New-BRAVOUpdateWorkerFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Action = 'Побудуйте новий план і повторіть операцію.',
        [string]$Details = '',
        [AllowNull()][object]$Hint = $null,
        [ValidateSet('Ok', 'Warning', 'Blocker', 'NotApplicable')][string]$Severity = 'Blocker',
        [string]$Meaning = ''
    )
    return (New-BRAVOUpdateFinding -Id $Id -Severity $Severity -Title $Title -Meaning $Meaning -Action $Action -Details $Details -ExitCodeHint $Hint)
}

function ConvertTo-BRAVOUpdateWorkerResultAction {
    # Дія контракту DeploymentResult: невідома дія не повинна валити
    # конструктор результату, тому зводиться до 'Update'.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Action)
    if (@('Install', 'Update', 'Repair', 'Rollback', 'Recovery') -ccontains $Action) { return $Action }
    return 'Update'
}

function New-BRAVOUpdateWorkerFailureResult {
    # DeploymentResult для відмови ДО mutation (або збою оркестратора). Код
    # виводить ConvertTo-BRAVOUpdateExitCode з hint першого blocker-а.
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$OperationId,
        [AllowNull()][AllowEmptyString()][string]$PlanId,
        [AllowNull()][AllowEmptyString()][string]$Action = 'Update',
        [ValidateSet('Failed', 'Critical')][string]$Status = 'Failed',
        [ValidateSet('Blocked', 'Cancelled', 'PlanStale', 'VerificationFailed', 'Error')][string]$ReasonCode = 'Blocked',
        [Parameter(Mandatory = $true)][object[]]$Finding,
        [AllowNull()][AllowEmptyString()][string]$StartedUtc = '',
        [bool]$MutationStarted = $false,
        [AllowNull()][AllowEmptyString()][string]$JournalPath = ''
    )
    if ([string]::IsNullOrWhiteSpace($OperationId) -or -not (Test-BRAVOUpdateGuidText -Value $OperationId)) {
        $OperationId = [guid]::NewGuid().ToString()
    }
    if (-not [string]::IsNullOrWhiteSpace($PlanId) -and -not (Test-BRAVOUpdateGuidText -Value $PlanId)) { $PlanId = '' }
    $arguments = @{
        OperationId = $OperationId; PlanId = [string]$PlanId; Action = (ConvertTo-BRAVOUpdateWorkerResultAction -Action $Action)
        Status = $Status; Findings = @($Finding); MutationStarted = $MutationStarted; StartedUtc = [string]$StartedUtc
    }
    if ($Status -eq 'Failed') { $arguments['ReasonCode'] = $ReasonCode }
    if (-not [string]::IsNullOrWhiteSpace($JournalPath)) { $arguments['JournalPath'] = $JournalPath }
    return (New-BRAVOUpdateDeploymentResult @arguments)
}

function Get-BRAVOUpdateWorkerHintExitCode {
    # Код завершення для read-only дій: перший blocker -> його hint (якщо
    # дозволений) або 80; без blocker-ів — 10 за наявності Warning, інакше 0.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Finding)
    $sawWarning = $false
    foreach ($item in @($Finding)) {
        if ($null -eq $item) { continue }
        $severity = [string](Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'severity' -Default '')
        if ($severity -ceq 'Blocker') {
            $hint = Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'exitCodeHint'
            if ((Test-BRAVOUpdateWholeNumber -Value $hint) -and ($script:BRAVOUpdateWorkerHintCodes -contains [int]$hint)) { return [int]$hint }
            return 80
        }
        if ($severity -ceq 'Warning') { $sawWarning = $true }
    }
    if ($sawWarning) { return 10 }
    return 0
}

function Test-BRAVOUpdateWorkerSamePath {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Left, [AllowEmptyString()][string]$Right)
    try {
        return [string]::Equals((Get-BRAVOUpdateFullPath -Path $Left), (Get-BRAVOUpdateFullPath -Path $Right), [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-BRAVOUpdateWorkerAcceptsParameter {
    # Чи прийме операція параметр: scriptblock-seam — за AST param-блока,
    # ім'я функції — за метаданими команди. Невідомо = $false.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Operation, [Parameter(Mandatory = $true)][string]$Name)
    if ($Operation -is [scriptblock]) {
        $paramBlock = $Operation.Ast.ParamBlock
        if ($null -eq $paramBlock) { return $false }
        foreach ($parameter in $paramBlock.Parameters) {
            if ($parameter.Name.VariablePath.UserPath -eq $Name) { return $true }
        }
        return $false
    }
    $command = Get-Command -Name ([string]$Operation) -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $command) { return $false }
    return [bool]$command.Parameters.ContainsKey($Name)
}

# ---------------------------------------------------------------------------
# ACL каталогів протоколу
# ---------------------------------------------------------------------------

function Set-BRAVOUpdateDirectoryAcl {
    <#
    .SYNOPSIS
        Замінює DACL наявного каталогу набором правил (успадкування вимкнено).
    .DESCRIPTION
        Rule — масив { Sid, Rights, Inheritance }. Змінюється лише секція
        Access (без SeSecurityPrivilege, як у New-BRAVOUpdatePrivateDirectory).
        Результат перечитується; повертає { Success, Problems }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object[]]$Rule
    )
    try {
        $directoryInfo = New-Object System.IO.DirectoryInfo($Path)
        $acl = $directoryInfo.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($oldRule in @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
            [void]$acl.RemoveAccessRuleSpecific($oldRule)
        }
        foreach ($item in $Rule) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $item.Sid, $item.Rights, $item.Inheritance,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)))
        }
        $directoryInfo.SetAccessControl($acl)
        $actual = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $problems = New-Object System.Collections.Generic.List[string]
        if (-not $actual.AreAccessRulesProtected) { $problems.Add('успадкування прав не вимкнено') }
        $expected = @($Rule | ForEach-Object { $_.Sid.Value })
        foreach ($actualRule in @($actual.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            if ($expected -notcontains [string]$actualRule.IdentityReference.Value) {
                $problems.Add('зайве правило ' + [string]$actualRule.IdentityReference.Value)
            }
        }
        return [pscustomobject]@{ Success = ($problems.Count -eq 0); Problems = @($problems.ToArray()) }
    } catch {
        return [pscustomobject]@{ Success = $false; Problems = @('ACL ' + $Path + ' не застосовано: ' + $_.Exception.Message) }
    }
}

function Get-BRAVOUpdateWorkerAclRule {
    # Набори правил протоколу. Kind:
    #   Operation  — Administrators/SYSTEM FullControl, Users ReadAndExecute
    #   Control    — як Operation + CreateFiles для SID запускача (лише на
    #                сам каталог: створювати cancel-файл можна, читати/міняти
    #                чужі — ні)
    #   Requests   — Administrators/SYSTEM FullControl, Users лише
    #                створюють файли (drop box)
    #   Private    — лише Administrators/SYSTEM (ConsumedPlans)
    # -IncludeCurrentUser додає FullControl поточному користувачу: потрібно
    # ЛИШЕ неелевованому процесу (тести); у production worker елевований, і
    # такий запис дав би неелевованому токену того ж користувача повний
    # доступ до каталогу операції.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Operation', 'Control', 'Requests', 'Private')][string]$Kind,
        [string]$LauncherSid = '',
        [switch]$IncludeCurrentUser
    )
    $rights = [System.Security.AccessControl.FileSystemRights]
    $flags = [System.Security.AccessControl.InheritanceFlags]
    $inherit = $flags::ContainerInherit -bor $flags::ObjectInherit
    $administrators = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $users = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $list = New-Object System.Collections.Generic.List[object]
    $list.Add([pscustomobject]@{ Sid = $administrators; Rights = $rights::FullControl; Inheritance = $inherit })
    $list.Add([pscustomobject]@{ Sid = $system; Rights = $rights::FullControl; Inheritance = $inherit })
    if ($IncludeCurrentUser) {
        $current = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        if ($current.Value -ne $administrators.Value -and $current.Value -ne $system.Value) {
            $list.Add([pscustomobject]@{ Sid = $current; Rights = $rights::FullControl; Inheritance = $inherit })
        }
    }
    switch ($Kind) {
        'Operation' { $list.Add([pscustomobject]@{ Sid = $users; Rights = $rights::ReadAndExecute; Inheritance = $inherit }) }
        'Control' {
            $list.Add([pscustomobject]@{ Sid = $users; Rights = $rights::ReadAndExecute; Inheritance = $inherit })
            if (-not [string]::IsNullOrWhiteSpace($LauncherSid)) {
                $launcher = New-Object System.Security.Principal.SecurityIdentifier($LauncherSid)
                $list.Add([pscustomobject]@{ Sid = $launcher; Rights = ($rights::CreateFiles -bor $rights::ReadAttributes -bor $rights::Synchronize); Inheritance = $flags::None })
            }
        }
        'Requests' {
            $list.Add([pscustomobject]@{ Sid = $users; Rights = ($rights::CreateFiles -bor $rights::ExecuteFile -bor $rights::ReadAttributes -bor $rights::Synchronize); Inheritance = $flags::None })
        }
        default { }
    }
    return $list.ToArray()
}

function Initialize-BRAVOUpdateStateDirectories {
    <#
    .SYNOPSIS
        Обгортка сумісності над Initialize-BRAVOUpdateProtectedRoots (Paths, H1)
        лише для піддерева StateRoot: Journal, Operations (Users читають), Requests
        (Users лише створюють), ConsumedPlans (Administrators/SYSTEM).
    .DESCRIPTION
        Єдина реалізація створення/перевірки власника й ACL — у Paths. Наявний
        каталог із довіреним власником отримує DACL заново; з чужим власником —
        відмова (Problems). Повертає { Success, Created[], Problems[] } і не кидає.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $pathsLike = [pscustomobject]@{ StateRoot = $StateRoot; LockRoot = $StateRoot; StagingRoot = $StateRoot; BackupRoot = $StateRoot }
    $outcome = Initialize-BRAVOUpdateProtectedRoots -Paths $pathsLike -Only @('StateRoot', 'Journal', 'Operations', 'ConsumedPlans', 'Requests')
    return [pscustomobject]@{ Success = [bool]$outcome.Success; Created = @($outcome.Created); Problems = @($outcome.Problems) }
}

function New-BRAVOUpdateOperationDirectory {
    <#
    .SYNOPSIS
        Створює <StateRoot>\Operations\<operationId> (+ control\) з ACL
        протоколу. Існуючий непорожній каталог = відмова (replay).
    .DESCRIPTION
        Повертає { Success, Path, ControlPath, Problems[] }. Створення — через
        New-BRAVOUpdatePrivateDirectory (захищений DACL з першого моменту),
        далі Users отримують лише читання, а SID запускача — CreateFiles на
        control\ (cancel-файл).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [string]$LauncherSid = ''
    )
    $failure = {
        param([string]$Message, [string]$Path)
        [pscustomobject]@{ Success = $false; Path = $Path; ControlPath = $null; Problems = @($Message) }
    }
    if (-not (Test-BRAVOUpdateGuidText -Value $OperationId)) { return (& $failure 'operationId має бути GUID.' $null) }
    $operationsRoot = Join-Path $StateRoot 'Operations'
    $operationPath = Join-Path $operationsRoot $OperationId
    try {
        if (Test-BRAVOUpdatePathHasReparsePoint -Path $operationPath) { return (& $failure 'Шлях операції є reparse point або має його серед предків.' $operationPath) }
        [void][System.IO.Directory]::CreateDirectory($operationsRoot)
        $private = New-BRAVOUpdatePrivateDirectory -Path $operationPath
        if (-not $private.Success) { return (& $failure ('Каталог операції не створено: ' + ($private.Problems -join '; ')) $operationPath) }
        $includeCurrent = -not (Test-BRAVOUpdateWorkerIsAdministrator)
        $applied = Set-BRAVOUpdateDirectoryAcl -Path $operationPath -Rule (Get-BRAVOUpdateWorkerAclRule -Kind Operation -IncludeCurrentUser:$includeCurrent)
        if (-not $applied.Success) { return (& $failure ('ACL каталогу операції: ' + ($applied.Problems -join '; ')) $operationPath) }
        $controlPath = Join-Path $operationPath 'control'
        [void][System.IO.Directory]::CreateDirectory($controlPath)
        $controlApplied = Set-BRAVOUpdateDirectoryAcl -Path $controlPath -Rule (Get-BRAVOUpdateWorkerAclRule -Kind Control -LauncherSid $LauncherSid -IncludeCurrentUser:$includeCurrent)
        if (-not $controlApplied.Success) { return (& $failure ('ACL control: ' + ($controlApplied.Problems -join '; ')) $operationPath) }
        return [pscustomobject]@{ Success = $true; Path = $operationPath; ControlPath = $controlPath; Problems = @() }
    } catch {
        return (& $failure ('Каталог операції не створено: ' + $_.Exception.Message) $operationPath)
    }
}

# ---------------------------------------------------------------------------
# Запит (GUI/CLI -> worker)
# ---------------------------------------------------------------------------

function New-BRAVOUpdateRequest {
    <#
    .SYNOPSIS
        Будує запит на виконання плану (CONTRACTS §10); використовують CLI і
        (за документацією) GUI.
    .DESCRIPTION
        Форма: { schemaVersion, requestId, planId, plan, confirmedPlanShortId,
        requestedUtc, options{ prereleaseAuthorized, activationPolicy,
        runSelfTest, backupDestination, sourcePath, scope } }.
        confirmedPlanShortId — те, що ТЕКСТОМ ввів/підтвердив оператор; він
        мусить дорівнювати перших 8 hex planId, інакше виняток (підтвердження
        не підміняється обчисленим значенням). Секретів у запиті немає:
        Test-BRAVOUpdateNoSecretProperty відхиляє будь-яке ім'я за шаблоном.
        Не пише на диск (див. Write-BRAVOUpdateRequestFile).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$ConfirmedPlanShortId,
        [System.Collections.IDictionary]$Option = @{},
        [string]$RequestId = '',
        [string]$RequestedUtc = ''
    )
    $planId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'planId' -Default '')
    if (-not (Test-BRAVOUpdateGuidText -Value $planId)) { throw 'BRAVO.Update: у плані немає коректного planId.' }
    if ($ConfirmedPlanShortId.Trim().ToLowerInvariant() -cne $planId.Substring(0, 8)) {
        throw 'BRAVO.Update: короткий id плану не збігається з підтвердженням оператора.'
    }
    if ([string]::IsNullOrWhiteSpace($RequestId)) { $RequestId = [guid]::NewGuid().ToString() }
    if ([string]::IsNullOrWhiteSpace($RequestedUtc)) { $RequestedUtc = Get-BRAVOUpdateUtcNowText }
    $options = [ordered]@{
        prereleaseAuthorized = $false
        activationPolicy     = ''
        runSelfTest          = $false
        backupDestination    = ''
        sourcePath           = ''
        scope                = 'All'
    }
    foreach ($key in @($Option.Keys)) { $options[[string]$key] = $Option[$key] }
    $request = [pscustomobject][ordered]@{
        schemaVersion        = 1
        requestId            = $RequestId.ToLowerInvariant()
        planId               = $planId
        plan                 = $Plan
        confirmedPlanShortId = $planId.Substring(0, 8)
        requestedUtc         = $RequestedUtc
        options              = [pscustomobject]$options
    }
    $check = Test-BRAVOUpdateRequest -Request $request
    if (-not $check.IsValid) { throw ('BRAVO.Update: запит не пройшов перевірку: ' + ($check.Problems -join '; ')) }
    return $request
}

function Write-BRAVOUpdateRequestFile {
    <#
    .SYNOPSIS
        Записує запит у <StateRoot>\Requests\<requestId>.json (CreateNew —
        наявний файл не перезаписується). Повертає шлях.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )
    $requestId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Request -Name 'requestId' -Default '')
    if (-not (Test-BRAVOUpdateGuidText -Value $requestId)) { throw 'BRAVO.Update: requestId має бути GUID.' }
    $directory = Join-Path $StateRoot 'Requests'
    if (-not [System.IO.Directory]::Exists($directory)) { throw ('BRAVO.Update: каталог запитів не існує: ' + $directory) }
    $path = Join-Path $directory ($requestId + '.json')
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-BRAVOUpdateJson -InputObject $Request))
    $stream = New-Object System.IO.FileStream($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    return $path
}

function Test-BRAVOUpdateRequest {
    # Схема запиту (CONTRACTS §10). Не кидає: { IsValid, Problems[] }.
    [CmdletBinding()]
    param([AllowNull()]$Request)
    $problems = New-Object 'System.Collections.Generic.List[string]'
    if (($null -eq $Request) -or ($Request -is [string]) -or ($Request -is [ValueType]) -or (($Request -is [System.Collections.IEnumerable]) -and ($Request -isnot [System.Collections.IDictionary]))) {
        $problems.Add('запит має бути JSON-об''єктом.')
        return (New-BRAVOUpdateValidationResult -Problems $problems)
    }
    foreach ($name in @('schemaVersion', 'requestId', 'planId', 'plan', 'confirmedPlanShortId', 'requestedUtc', 'options')) {
        if (-not (Test-BRAVOUpdateHasProperty -InputObject $Request -Name $name)) { $problems.Add("відсутнє поле $name.") }
    }
    if ($problems.Count -gt 0) { return (New-BRAVOUpdateValidationResult -Problems $problems) }

    $secret = Test-BRAVOUpdateNoSecretProperty -InputObject $Request
    if (-not $secret.IsValid) { foreach ($problem in $secret.Problems) { $problems.Add('секрет у запиті: ' + $problem) } }
    $version = Get-BRAVOUpdatePropertyValue -InputObject $Request -Name 'schemaVersion'
    if (-not ((Test-BRAVOUpdateWholeNumber -Value $version) -and ([int]$version -eq 1))) { $problems.Add('schemaVersion має бути 1.') }
    if (-not (Test-BRAVOUpdateGuidText -Value (Get-BRAVOUpdatePropertyValue -InputObject $Request -Name 'requestId'))) { $problems.Add('requestId має бути GUID у нижньому регістрі.') }
    $planId = Get-BRAVOUpdatePropertyValue -InputObject $Request -Name 'planId'
    if (-not (Test-BRAVOUpdateGuidText -Value $planId)) { $problems.Add('planId має бути GUID у нижньому регістрі.') }
    if (-not (Test-BRAVOUpdateTimestampValue -Value (Get-BRAVOUpdatePropertyValue -InputObject $Request -Name 'requestedUtc'))) { $problems.Add('requestedUtc не є датою ISO 8601.') }

    $plan = Get-BRAVOUpdatePropertyValue -InputObject $Request -Name 'plan'
    $planCheck = Test-BRAVOUpdateDeploymentPlan -InputObject $plan
    if (-not $planCheck.IsValid) {
        foreach ($problem in $planCheck.Problems) { $problems.Add('plan: ' + $problem) }
    } elseif ([string](Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'planId') -cne [string]$planId) {
        $problems.Add('planId запиту не збігається з planId плану.')
    }

    $shortId = Get-BRAVOUpdatePropertyValue -InputObject $Request -Name 'confirmedPlanShortId'
    if (($shortId -isnot [string]) -or ($shortId -cnotmatch '^[0-9a-f]{8}$')) {
        $problems.Add('confirmedPlanShortId має бути 8 hex у нижньому регістрі.')
    } elseif (($planId -is [string]) -and ($planId.Length -ge 8) -and ($shortId -cne $planId.Substring(0, 8))) {
        $problems.Add('confirmedPlanShortId не збігається з перших 8 hex planId.')
    }

    $options = Get-BRAVOUpdatePropertyValue -InputObject $Request -Name 'options'
    if (($null -eq $options) -or ($options -is [string]) -or ($options -is [ValueType])) {
        $problems.Add('options має бути об''єктом.')
    } else {
        foreach ($flag in @('prereleaseAuthorized', 'runSelfTest')) {
            $value = Get-BRAVOUpdatePropertyValue -InputObject $options -Name $flag -Default $false
            if ($value -isnot [bool]) { $problems.Add("options.$flag має бути логічним значенням.") }
        }
        foreach ($text in @('activationPolicy', 'sourcePath')) {
            $value = Get-BRAVOUpdatePropertyValue -InputObject $options -Name $text -Default ''
            if (($null -ne $value) -and ($value -isnot [string])) { $problems.Add("options.$text має бути рядком.") }
        }
        $destination = Get-BRAVOUpdatePropertyValue -InputObject $options -Name 'backupDestination' -Default ''
        if (-not (($null -eq $destination) -or (($destination -is [string]) -and (($destination -eq '') -or ($script:BRAVOUpdateWorkerBackupDestinations -ccontains $destination))))) {
            $problems.Add('options.backupDestination має бути Cloud|CloudAndSamba|SambaOnly|LocalOnly.')
        }
        $scope = Get-BRAVOUpdatePropertyValue -InputObject $options -Name 'scope' -Default 'All'
        if (-not (($scope -is [string]) -and ($script:BRAVOUpdateWorkerScopes -ccontains $scope))) { $problems.Add('options.scope має бути All|Runtime|Scheduler.') }
    }
    return (New-BRAVOUpdateValidationResult -Problems $problems)
}

function Read-BRAVOUpdateRequestFile {
    <#
    .SYNOPSIS
        Одноразово читає запит із <StateRoot>\Requests (шлях, reparse, розмір,
        UTF-8, JSON). Повертає { IsValid, Finding, Text, Request }; не кидає.
    .DESCRIPTION
        Файл читається ОДИН раз у пам'ять (потік FileShare.Read); усе
        подальше — над цією копією, тож підміна файлу після перевірки
        нічого не дає (TOCTOU). Розмір обмежений 1 MiB і перевіряється двічі:
        за FileInfo та за фактично прочитаними байтами.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RequestPath,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )
    $reject = {
        param([string]$Id, [string]$Title, [string]$Details)
        [pscustomobject]@{
            IsValid = $false; Text = $null; Request = $null
            Finding = (New-BRAVOUpdateWorkerFinding -Id $Id -Title $Title -Details $Details -Action 'Сформуйте запит заново через Installer або BRAVO_UPDATE.ps1.')
        }
    }
    try {
        $fullPath = Get-BRAVOUpdateFullPath -Path $RequestPath
        $requestsRoot = Get-BRAVOUpdateFullPath -Path (Join-Path $StateRoot 'Requests')
        $parent = [System.IO.Path]::GetDirectoryName($fullPath)
        if (-not [string]::Equals($parent, $requestsRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return (& $reject 'Worker.RequestPath' 'Запит поза каталогом Requests' ('очікується файл безпосередньо в ' + $requestsRoot))
        }
        if ([System.IO.Path]::GetFileName($fullPath) -cnotmatch $script:BRAVOUpdateWorkerRequestLeafPattern) {
            return (& $reject 'Worker.RequestPath' 'Ім''я файлу запиту має бути <guid>.json' ([System.IO.Path]::GetFileName($fullPath)))
        }
        if (Test-BRAVOUpdatePathHasReparsePoint -Path $fullPath) {
            return (& $reject 'Worker.RequestReparse' 'Шлях запиту є reparse point або проходить через нього' $fullPath)
        }
        if (-not [System.IO.File]::Exists($fullPath)) {
            return (& $reject 'Worker.RequestMissing' 'Файл запиту не знайдено' $fullPath)
        }
        $info = New-Object System.IO.FileInfo($fullPath)
        if ($info.Length -gt $script:BRAVOUpdateWorkerMaxRequestBytes) {
            return (& $reject 'Worker.RequestSize' 'Файл запиту завеликий' ('розмір ' + $info.Length + ' > ' + $script:BRAVOUpdateWorkerMaxRequestBytes))
        }
        $stream = New-Object System.IO.FileStream($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $bytes = $null
        try {
            $limit = $script:BRAVOUpdateWorkerMaxRequestBytes + 1
            $buffer = New-Object byte[] $limit
            $total = 0
            while ($total -lt $limit) {
                $read = $stream.Read($buffer, $total, $limit - $total)
                if ($read -le 0) { break }
                $total += $read
            }
            if ($total -gt $script:BRAVOUpdateWorkerMaxRequestBytes) {
                return (& $reject 'Worker.RequestSize' 'Файл запиту завеликий' 'фактичний розмір перевищує ліміт')
            }
            $bytes = New-Object byte[] $total
            [System.Array]::Copy($buffer, $bytes, $total)
        } finally {
            $stream.Dispose()
        }
        $text = $null
        try {
            $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes).TrimStart([char]0xFEFF)
        } catch {
            return (& $reject 'Worker.RequestEncoding' 'Запит не є коректним UTF-8' '')
        }
        if ([string]::IsNullOrWhiteSpace($text)) { return (& $reject 'Worker.RequestEmpty' 'Файл запиту порожній' '') }
        $parsed = $null
        try { $parsed = $text | ConvertFrom-Json -ErrorAction Stop } catch { return (& $reject 'Worker.RequestJson' 'Запит не є коректним JSON' '') }
        $parsed = ConvertTo-BRAVOUpdateNormalizedObject -Node $parsed
        return [pscustomobject]@{ IsValid = $true; Text = $text; Request = $parsed; Finding = $null }
    } catch {
        return (& $reject 'Worker.RequestRead' 'Запит не вдалося прочитати' $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------

function Write-BRAVOUpdateWorkerResultFile {
    # result.json атомарно; збій запису не маскує результат (повертає $false).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$OperationDirectory, [Parameter(Mandatory = $true)]$Result)
    try {
        Write-BRAVOUpdateFileAtomic -Path (Join-Path $OperationDirectory 'result.json') -Text (ConvertTo-BRAVOUpdateJson -InputObject $Result)
        return $true
    } catch {
        return $false
    }
}

function Invoke-BRAVOUpdateWorker {
    <#
    .SYNOPSIS
        Виконує запит на розгортання (ENGINE_DESIGN §10.1). Повертає
        { ExitCode, Result, OperationId, ResultPath }; не кидає й не виходить.
    .DESCRIPTION
        Порядок: права -> читання/перевірка запиту -> корені -> replay ->
        каталог операції (request.json, control\) -> актуальність плану ->
        повторний preflight -> dispatch. Усі відмови до dispatch — БЕЗ
        mutation. Відмови до створення каталогу операції не пишуть нічого на
        диск (результат лише в пам'яті); пізніші — також у result.json.
    .PARAMETER Operations
        Seam тестів: { Install, Update, Repair } -> ім'я функції або
        scriptblock. Типово — Install-BRAVOToolkit, Invoke-BRAVODeployment,
        Repair-BRAVOInstallation. FaultInjection сюди НЕ передається ніколи.
    .PARAMETER IsAdministrator
        Seam тестів (production: $null = реальна перевірка).
    .PARAMETER LauncherSid
        SID, якому дозволено створювати cancel-файл у control\; типово —
        користувач поточного процесу (запускач через UAC того ж облікового запису).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RequestPath,
        [hashtable]$Adapter = $null,
        $Paths = $null,
        [string[]]$CandidateRoots = @(),
        [hashtable]$Operations = $null,
        [AllowNull()][object]$IsAdministrator = $null,
        [string]$LauncherSid = '',
        [object]$Now = $null
    )
    $startedUtc = Get-BRAVOUpdateUtcNowText
    $useDefaultAdapter = ($null -eq $Adapter)
    if ($null -eq $Paths) { $Paths = Get-BRAVOUpdateDefaultPaths }
    if ($null -eq $Adapter) { $Adapter = New-BRAVOUpdateDefaultAdapter -StagingRoot ([string]$Paths.StagingRoot) }
    $stateRoot = [string]$Paths.StateRoot
    $attestation = ''

    $finish = {
        param($Result, [string]$OperationDirectory)
        $resultPath = $null
        if (-not [string]::IsNullOrWhiteSpace($OperationDirectory)) {
            if (Write-BRAVOUpdateWorkerResultFile -OperationDirectory $OperationDirectory -Result $Result) {
                $resultPath = Join-Path $OperationDirectory 'result.json'
            }
        }
        [pscustomobject]@{ ExitCode = [int]$Result.exitCode; Result = $Result; OperationId = [string]$Result.operationId; ResultPath = $resultPath; Attestation = $attestation }
    }
    $fail = {
        param([object[]]$Findings, [string]$Reason, $Plan, [string]$OperationDirectory, [string]$ResultAction)
        $failOperationId = ''
        $failPlanId = ''
        if ($null -ne $Plan) {
            $failOperationId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'operationId' -Default '')
            $failPlanId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'planId' -Default '')
            if ([string]::IsNullOrEmpty($ResultAction)) { $ResultAction = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'action' -Default 'Update') }
        }
        $failure = New-BRAVOUpdateWorkerFailureResult -OperationId $failOperationId -PlanId $failPlanId -Action $ResultAction -ReasonCode $Reason -Finding $Findings -StartedUtc $startedUtc
        & $finish $failure $OperationDirectory
    }

    # 1. Права: без них нічого не пишемо.
    $isAdmin = $IsAdministrator
    if ($null -eq $isAdmin) { $isAdmin = Test-BRAVOUpdateWorkerIsAdministrator }
    if (-not [bool]$isAdmin) {
        return (& $fail @(New-BRAVOUpdateWorkerFinding -Id 'Worker.PrivilegeRequired' -Title 'Для виконання операції потрібні права адміністратора' `
                    -Action 'Запустіть операцію від імені адміністратора (підтвердіть UAC).' -Hint 36) 'Blocked' $null '' 'Update')
    }
    # Engine ніколи не встановлює BRAVO_ALLOW_DOWNGRADE і відмовляє, якщо він присутній (ENGINE_DESIGN 7.2).
    if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE'))) {
        return (& $fail @(New-BRAVOUpdateWorkerFinding -Id 'Worker.DowngradeOverride' -Title 'У середовищі задано BRAVO_ALLOW_DOWNGRADE' `
                    -Meaning 'Дозвіл відкату версії несумісний з операціями Installer.' -Action 'Приберіть змінну BRAVO_ALLOW_DOWNGRADE зі середовища й повторіть.' -Hint 35) 'Blocked' $null '' 'Update')
    }

    # H1: корені engine створюються/перевіряються (власник, ACL, reparse) ДО читання будь-якого
    # запиту чи журналу: ProgramData дозволяє будь-кому підкласти каталог, а запит і журнал —
    # вхід для привілейованих дій. Недовірений корінь = Blocked без жодних записів.
    $protectedRoots = Initialize-BRAVOUpdateProtectedRoots -Paths $Paths
    if (-not $protectedRoots.Success) {
        return (& $fail @($protectedRoots.Findings) 'Blocked' $null '' 'Update')
    }

    # 2-3. Запит: шлях, розмір, схема, секрети, короткий id.
    $read = Read-BRAVOUpdateRequestFile -RequestPath $RequestPath -StateRoot $stateRoot
    if (-not $read.IsValid) { return (& $fail @($read.Finding) 'Blocked' $null '' 'Update') }
    $request = $read.Request
    $check = Test-BRAVOUpdateRequest -Request $request
    if (-not $check.IsValid) {
        return (& $fail @(New-BRAVOUpdateWorkerFinding -Id 'Worker.RequestSchema' -Title 'Запит не пройшов перевірку' -Details ($check.Problems -join '; ') `
                    -Action 'Сформуйте запит заново через Installer або BRAVO_UPDATE.ps1.') 'Blocked' $null '' 'Update')
    }
    $plan = Get-BRAVOUpdatePropertyValue -InputObject $request -Name 'plan'
    $options = Get-BRAVOUpdatePropertyValue -InputObject $request -Name 'options'
    $action = [string](Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'action')
    $operationId = [string](Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'operationId')
    $planId = [string](Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'planId')
    $planRuntime = [string](Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'runtimeRoot')
    # Прийняті залишкові ризики v1 (DECISIONS-стиль, H1/6): (1) офлайн-реліз самоатестований
    # (немає ключа підпису: SHA-256 архіва ловить пошкодження, не підміну разом із manifest);
    # (2) запит, який неелевований код того ж облікового запису може переписати після згоди
    # UAC (UAC-згода стосується запуску, не вмісту файлу). Пом'якшення v1, не жорстке
    # виправлення: елевований консольний лог і результат показують короткий id плану,
    # цільову версію й sha256 джерела, щоб оператор побачив розбіжність із підтвердженим.
    $planSourceInfo = Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'source'
    $attestationSha = [string](Get-BRAVOUpdatePropertyValue -InputObject $planSourceInfo -Name 'artifactSha256' -Default '')
    if ($attestationSha.Length -gt 16) { $attestationSha = $attestationSha.Substring(0, 16) }
    $attestation = ('Елевований engine виконує план ' + $planId.Substring(0, [Math]::Min(8, $planId.Length)) + ' (' + $action + '), цільова версія ' +
        [string](Get-BRAVOUpdatePropertyValue -InputObject $planSourceInfo -Name 'packageVersion' -Default '?') + ', sha256 джерела ' + $attestationSha + '...')

    # 4. Корені не беруться на віру з запиту.
    $rootProblems = New-Object System.Collections.Generic.List[string]
    if (-not (Test-BRAVOUpdateWorkerSamePath -Left ([string](Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'stagingRoot')) -Right ([string]$Paths.StagingRoot))) {
        $rootProblems.Add('stagingRoot плану не збігається з каталогом staging engine')
    }
    if (-not (Test-BRAVOUpdateWorkerSamePath -Left ([string](Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'backupRoot')) -Right ([string]$Paths.BackupRoot))) {
        $rootProblems.Add('backupRoot плану не збігається з каталогом резервних копій engine')
    }
    foreach ($own in @($Paths.StateRoot, $Paths.LockRoot, $Paths.StagingRoot, $Paths.BackupRoot)) {
        if ((Test-BRAVOUpdateWorkerSamePath -Left $planRuntime -Right ([string]$own)) -or
            (Test-BRAVOUpdatePathIsUnder -Path $planRuntime -Root ([string]$own)) -or
            (Test-BRAVOUpdatePathIsUnder -Path ([string]$own) -Root $planRuntime)) {
            $rootProblems.Add('runtimeRoot плану збігається або перетинається зі службовим каталогом engine: ' + [string]$own)
        }
    }
    $installationState = $null
    if ($rootProblems.Count -eq 0 -and $action -ne 'Install') {
        $candidates = @($CandidateRoots)
        if ($candidates.Count -eq 0) { $candidates = @([string]$Paths.RuntimeRoot, [string]$script:BRAVOUpdateToolkitRoot) }
        try {
            $installationState = Get-BRAVOInstallationState -CandidateRoots $candidates -StateRoot $stateRoot -VersionStatePath ([string]$Paths.VersionStatePath) `
                -OperationLockPath ([string]$Paths.OperationLockPath) -LockRoot ([string]$Paths.LockRoot) -Adapter $Adapter -IncludeScheduler:$useDefaultAdapter
            $found = @(@($installationState.candidateRoots) | Where-Object { Test-BRAVOUpdateWorkerSamePath -Left ([string]$_) -Right $planRuntime })
            if ($found.Count -eq 0) { $rootProblems.Add('runtimeRoot плану не є знайденим встановленням BRAVO') }
        } catch {
            $rootProblems.Add('не вдалося визначити встановлення: ' + $_.Exception.Message)
        }
    }
    if ($rootProblems.Count -gt 0) {
        return (& $fail @(New-BRAVOUpdateWorkerFinding -Id 'Worker.ForeignRoot' -Title 'Запит містить каталоги, яким engine не довіряє' -Details ($rootProblems -join '; ') `
                    -Action 'Побудуйте новий план для встановлення, знайденого engine.') 'Blocked' $plan '' $action)
    }

    # Replay: зареєстрований план або вже використаний каталог операції — без записів.
    $consumedMarker = Join-Path (Join-Path $stateRoot 'ConsumedPlans') $planId
    $operationPath = Join-Path (Join-Path $stateRoot 'Operations') $operationId
    $operationInUse = $false
    if ([System.IO.Directory]::Exists($operationPath)) { $operationInUse = (@(Get-ChildItem -LiteralPath $operationPath -Force -ErrorAction SilentlyContinue).Count -gt 0) }
    if ([System.IO.File]::Exists($consumedMarker) -or [System.IO.Directory]::Exists($consumedMarker) -or $operationInUse) {
        return (& $fail @(New-BRAVOUpdateWorkerFinding -Id 'Worker.PlanReplay' -Title 'План уже використано' -Meaning 'Один план виконується не більше одного разу.' `
                    -Action 'Побудуйте новий план і підтвердіть його.' -Details ('planId=' + $planId)) 'PlanStale' $plan '' $action)
    }

    # 5. Каталог операції й копія запиту.
    if ([string]::IsNullOrWhiteSpace($LauncherSid)) { $LauncherSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    $operation = New-BRAVOUpdateOperationDirectory -StateRoot $stateRoot -OperationId $operationId -LauncherSid $LauncherSid
    if (-not $operation.Success) {
        return (& $fail @(New-BRAVOUpdateWorkerFinding -Id 'Worker.OperationDirectory' -Title 'Не вдалося підготувати каталог операції' -Details ($operation.Problems -join '; ') `
                    -Action 'Перевірте права на каталог стану й повторіть.') 'Error' $plan '' $action)
    }
    $operationDirectory = [string]$operation.Path
    try {
        Write-BRAVOUpdateFileAtomic -Path (Join-Path $operationDirectory 'request.json') -Text ([string]$read.Text)
    } catch {
        return (& $fail @(New-BRAVOUpdateWorkerFinding -Id 'Worker.RequestCopy' -Title 'Не вдалося зберегти копію запиту' -Details $_.Exception.Message `
                    -Action 'Перевірте права й вільне місце та повторіть.') 'Error' $plan $operationDirectory $action)
    }

    # Plan current + blockers плану.
    $currentArguments = @{ Plan = $plan; RuntimeRoot = $planRuntime; StateRoot = $stateRoot; Adapter = $Adapter }
    if ($null -ne $Now) { $currentArguments['Now'] = $Now }
    $current = Test-BRAVODeploymentPlanCurrent @currentArguments
    if (-not $current.IsCurrent) {
        return (& $fail @(New-BRAVOUpdateWorkerFinding -Id 'Worker.PlanStale' -Title 'План уже не актуальний' -Details ($current.Problems -join '; ') `
                    -Action 'Виконайте новий preflight, побудуйте новий план і підтвердіть його.') 'PlanStale' $plan $operationDirectory $action)
    }
    $planBlockers = @(@(Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'findings' -Default @()) | Where-Object { [string](Get-BRAVOUpdatePropertyValue -InputObject $_ -Name 'severity') -ceq 'Blocker' })
    if ($planBlockers.Count -gt 0) {
        return (& $fail $planBlockers 'Blocked' $plan $operationDirectory $action)
    }

    # Повторний preflight (передумови могли змінитись після побудови плану).
    $required = [long]0
    $footprint = Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'footprint'
    foreach ($name in @('stagingBytes', 'backupBytes', 'deployBytes')) {
        $value = Get-BRAVOUpdatePropertyValue -InputObject $footprint -Name $name -Default 0
        if (Test-BRAVOUpdateWholeNumber -Value $value) { $required += [long]$value }
    }
    $preflightArguments = @{
        Operation = $action; RuntimeRoot = $planRuntime; StateRoot = $stateRoot; LockRoot = [string]$Paths.LockRoot
        OperationLockPath = [string]$Paths.OperationLockPath; StagingRoot = [string]$Paths.StagingRoot; BackupRoot = [string]$Paths.BackupRoot
        RequiredBytes = $required; Adapter = $Adapter
    }
    if ($null -ne $installationState) { $preflightArguments['InstallationState'] = $installationState }
    $preflight = $null
    try { $preflight = Test-BRAVODeploymentPreflight @preflightArguments } catch {
        return (& $fail @(New-BRAVOUpdateWorkerFinding -Id 'Worker.Preflight' -Title 'Повторний preflight не виконано' -Details $_.Exception.Message `
                    -Action 'Усуньте причину й побудуйте новий план.') 'Error' $plan $operationDirectory $action)
    }
    if (-not [bool]$preflight.canProceed) {
        $blockers = @(@($preflight.findings) | Where-Object { [string]$_.severity -ceq 'Blocker' })
        return (& $fail $blockers 'Blocked' $plan $operationDirectory $action)
    }

    # 6. Dispatch: лише за іменем/seam; жодного FaultInjection.
    $table = @{ Install = 'Install-BRAVOToolkit'; Update = 'Invoke-BRAVODeployment'; Repair = 'Repair-BRAVOInstallation' }
    if ($null -ne $Operations) { foreach ($key in @($Operations.Keys)) { $table[[string]$key] = $Operations[$key] } }
    $operationTarget = $table[$action]
    $splat = @{
        Plan = $plan; Adapter = $Adapter; RuntimeRoot = $planRuntime; StateRoot = $stateRoot; LockRoot = [string]$Paths.LockRoot
        StagingRoot = [string]$Paths.StagingRoot; BackupRoot = [string]$Paths.BackupRoot
        OperationLockPath = [string]$Paths.OperationLockPath; VersionStatePath = [string]$Paths.VersionStatePath
    }
    $destination = [string](Get-BRAVOUpdatePropertyValue -InputObject $options -Name 'backupDestination' -Default '')
    if ($action -eq 'Install') {
        if ([string]::IsNullOrEmpty($destination)) {
            return (& $fail @(New-BRAVOUpdateWorkerFinding -Id 'Worker.BackupDestination' -Title 'Для встановлення не вказано призначення резервних копій' `
                        -Action 'Вкажіть призначення (Cloud, CloudAndSamba, SambaOnly або LocalOnly) і побудуйте запит заново.') 'Blocked' $plan $operationDirectory $action)
        }
        $splat['BackupDestination'] = $destination
    }
    if ($action -eq 'Repair') { $splat['Scope'] = [string](Get-BRAVOUpdatePropertyValue -InputObject $options -Name 'scope' -Default 'All') }
    $sourcePath = [string](Get-BRAVOUpdatePropertyValue -InputObject $options -Name 'sourcePath' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($sourcePath) -and (Test-BRAVOUpdateWorkerAcceptsParameter -Operation $operationTarget -Name 'SourcePath')) {
        $splat['SourcePath'] = $sourcePath
    }
    $outcome = $null
    $thrown = $null
    try {
        $outcome = @(& $operationTarget @splat) | Where-Object { ($null -ne $_) -and ($null -ne $_.PSObject.Properties['operationId']) -and ($null -ne $_.PSObject.Properties['status']) } | Select-Object -Last 1
    } catch {
        $thrown = $_.Exception.Message
    }
    if (($null -ne $thrown) -or ($null -eq $outcome)) {
        $details = 'Оркестратор не повернув результат.'
        if ($null -ne $thrown) { $details = 'Збій оркестратора: ' + $thrown }
        return (& $fail @(New-BRAVOUpdateWorkerFinding -Id 'Worker.DispatchFailed' -Title 'Операцію перервано невизначеним збоєм' -Details $details `
                    -Meaning 'Стан встановлення невідомий: журнал операції може лишатись відкритим.' `
                    -Action 'Виконайте BRAVO_UPDATE.ps1 -Action Recover перед будь-якою новою операцією.') 'Error' $plan $operationDirectory $action)
    }
    $resultCheck = Test-BRAVOUpdateDeploymentResult -InputObject $outcome
    if ((-not $resultCheck.IsValid) -or ([string]$outcome.operationId -cne $operationId)) {
        return (& $fail @(New-BRAVOUpdateWorkerFinding -Id 'Worker.ResultInvalid' -Title 'Оркестратор повернув некоректний результат' -Details ($resultCheck.Problems -join '; ') `
                    -Action 'Виконайте BRAVO_UPDATE.ps1 -Action Recover і перевірте журнал.') 'Error' $plan $operationDirectory $action)
    }
    return (& $finish $outcome $operationDirectory)
}

# ---------------------------------------------------------------------------
# CLI: acquire + stage + plan
# ---------------------------------------------------------------------------

function Remove-BRAVOUpdateWorkerPlanWorkDirectory {
    # Єдиний рекурсивний delete цієї частини: лише каталог, який створив
    # той самий виклик (префікс + GUID, прямий нащадок WorkRoot, не reparse).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$WorkRoot)
    try {
        $fullPath = Get-BRAVOUpdateFullPath -Path $Path
        $leaf = [System.IO.Path]::GetFileName($fullPath)
        $parent = [System.IO.Path]::GetDirectoryName($fullPath)
        if (-not $leaf.StartsWith($script:BRAVOUpdateWorkerPlanWorkPrefix, [StringComparison]::Ordinal)) { return }
        if (-not (Test-BRAVOUpdateWorkerSamePath -Left $parent -Right $WorkRoot)) { return }
        if (-not [System.IO.Directory]::Exists($fullPath)) { return }
        if (Test-BRAVOUpdatePathHasReparsePoint -Path $fullPath -StopAt $WorkRoot) { return }
        # H1: без Remove-Item -Recurse (слідує за junction у дереві, яке може змінювати неелевований код):
        # обхід no-follow, атрибут кожного каталогу перевіряється перед перелічуванням.
        [void](Remove-BRAVOUpdateDirectoryTreeNoFollow -FullPath $fullPath)
    } catch {
        $null = $_
    }
}

function Invoke-BRAVOUpdateAcquireAndStage {
    <#
    .SYNOPSIS
        Отримує (онлайн за тегом або офлайн із zip), верифікує й розпаковує
        реліз у приватний робочий каталог плану. Нічого не розгортає.
    .DESCRIPTION
        Повертає { Success, Findings[], Source, StagedRoot }. Будь-яка помилка
        — blocker-finding (hint 42), не виняток. Верифікація — єдиний
        конвеєр Test-BRAVOReleaseArtifact незалежно від джерела.
    #>
    [CmdletBinding()]
    param(
        [string]$Tag = '',
        [string]$SourcePath = '',
        [switch]$AllowPrerelease,
        [Parameter(Mandatory = $true)][string]$WorkDirectory,
        [string]$VersionStatePath = '',
        [scriptblock]$Downloader
    )
    $findings = New-Object System.Collections.Generic.List[object]
    $out = {
        param([bool]$Success, $Source, [string]$Staged)
        [pscustomobject]@{ Success = $Success; Findings = @($findings.ToArray()); Source = $Source; StagedRoot = $Staged }
    }
    $block = {
        param([string]$Id, [string]$Title, [string]$Details)
        $findings.Add((New-BRAVOUpdateWorkerFinding -Id $Id -Title $Title -Details $Details -Hint 42 `
                    -Action 'Отримайте артефакт із довіреного джерела й повторіть; розгортання не продовжується.'))
    }
    try {
        $kind = 'Online'
        $acquired = $null
        $downloadRoot = Join-Path $WorkDirectory 'download'
        $private = New-BRAVOUpdatePrivateDirectory -Path $downloadRoot
        if (-not $private.Success) { & $block 'Release.WorkDirectory' 'Не вдалося створити робочий каталог' ($private.Problems -join '; '); return (& $out $false $null '') }
        if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
            $kind = 'Offline'
            if ([string]::IsNullOrWhiteSpace($Tag)) {
                $leafName = [System.IO.Path]::GetFileName($SourcePath)
                $match = [regex]::Match($leafName, '^BRAVO-Toolkit-(.+)\.zip$')
                if ($match.Success) { $Tag = 'v' + $match.Groups[1].Value }
            }
            if ([string]::IsNullOrWhiteSpace($Tag)) { & $block 'Release.Tag' 'Не вдалося визначити тег релізу з імені архіва' 'Вкажіть -Tag разом із -SourcePath.'; return (& $out $false $null '') }
            $acquired = Get-BRAVOOfflineReleaseSource -ZipPath $SourcePath -DestinationRoot $downloadRoot
        } else {
            if ([string]::IsNullOrWhiteSpace($Tag)) { & $block 'Release.Tag' 'Не вказано джерело' 'Вкажіть -SourcePath (офлайн) або -Tag (онлайн).'; return (& $out $false $null '') }
            $candidate = Get-BRAVOReleaseCandidate -Tag $Tag
            $downloadArguments = @{ Candidate = $candidate; DestinationRoot = $downloadRoot }
            if ($null -ne $Downloader) { $downloadArguments['Downloader'] = $Downloader }
            $acquired = Save-BRAVOReleaseArtifact @downloadArguments
        }
        if (-not $acquired.Success) {
            foreach ($problem in @($acquired.Problems)) { & $block 'Release.Acquire' 'Артефакт не отримано' ([string]$problem) }
            return (& $out $false $null '')
        }
        $verifyArguments = @{ ZipPath = $acquired.ZipPath; ChecksumPath = $acquired.ChecksumPath; ManifestPath = $acquired.ManifestPath; ExpectedTag = $Tag }
        if ($AllowPrerelease) { $verifyArguments['AllowPrerelease'] = $true }
        if (-not [string]::IsNullOrWhiteSpace($VersionStatePath)) { $verifyArguments['StatePath'] = $VersionStatePath }
        $verified = Test-BRAVOReleaseArtifact @verifyArguments
        foreach ($item in @($verified.Findings)) { $findings.Add($item) }
        if (-not $verified.IsValid) { return (& $out $false $null '') }

        $stagedRoot = Join-Path $WorkDirectory 'staged'
        $stagedPrivate = New-BRAVOUpdatePrivateDirectory -Path $stagedRoot
        if (-not $stagedPrivate.Success) { & $block 'Release.WorkDirectory' 'Не вдалося створити каталог staged' ($stagedPrivate.Problems -join '; '); return (& $out $false $null '') }
        $expanded = Expand-BRAVOUpdateArchiveSafe -ZipPath $acquired.ZipPath -DestinationRoot $stagedRoot -ExpectedSha256 ([string]$verified.ArtifactSha256)
        if (-not $expanded.Success) {
            foreach ($problem in @($expanded.Problems)) { & $block 'Release.Stage' 'Артефакт не розпаковано' ([string]$problem) }
            return (& $out $false $null '')
        }
        $staged = Test-BRAVOStagedRuntime -StagedRoot $stagedRoot -ExpectedVersion ([string]$verified.PackageVersion)
        foreach ($item in @($staged.Findings)) { $findings.Add($item) }
        if (-not $staged.IsValid) { return (& $out $false $null '') }

        $source = [pscustomobject][ordered]@{
            kind = $kind; tag = $Tag; artifactName = [System.IO.Path]::GetFileName([string]$acquired.ZipPath)
            artifactSha256 = [string]$verified.ArtifactSha256; manifestSha256 = [string]$verified.ManifestSha256
            packageVersion = [string]$verified.PackageVersion; releaseChannel = [string]$verified.ReleaseChannel
            prereleaseAuthorized = [bool]$AllowPrerelease
        }
        return (& $out $true $source $stagedRoot)
    } catch {
        & $block 'Release.Unexpected' 'Отримання або верифікація артефакта завершились збоєм' $_.Exception.Message
        return (& $out $false $null '')
    }
}

function Get-BRAVOUpdateCliState {
    [CmdletBinding()]
    param(
        [string]$RuntimeRoot = '',
        [string[]]$CandidateRoots = @(),
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        [switch]$IncludeScheduler
    )
    $arguments = @{
        StateRoot = [string]$Paths.StateRoot; VersionStatePath = [string]$Paths.VersionStatePath
        OperationLockPath = [string]$Paths.OperationLockPath; LockRoot = [string]$Paths.LockRoot; Adapter = $Adapter
    }
    if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) { $arguments['RuntimeRoot'] = $RuntimeRoot }
    if (@($CandidateRoots).Count -gt 0) { $arguments['CandidateRoots'] = @($CandidateRoots) }
    if ($IncludeScheduler) { $arguments['IncludeScheduler'] = $true }
    return (Get-BRAVOInstallationState @arguments)
}

function New-BRAVOUpdateCliPlan {
    <#
    .SYNOPSIS
        Складає DeploymentPlan для CLI/GUI: acquire -> stage -> preflight ->
        New-BRAVODeploymentPlan; робочий каталог видаляється. Повертає
        { Plan, Findings[] }: Plan = $null, якщо артефакт не пройшов
        верифікацію (тоді Findings містять причини).
    .PARAMETER Acquire
        Seam тестів: @{ Stage = param($Tag,$SourcePath,$AllowPrerelease,$WorkDirectory)
        -> { Success, Findings, Source, StagedRoot } } замість реальної
        верифікації zip (її покриває suite UpdateRelease).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair')][string]$Operation,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        $InstallationState = $null,
        [string]$Tag = '',
        [string]$SourcePath = '',
        [switch]$AllowPrerelease,
        [string]$WorkRoot = '',
        [hashtable]$Acquire = $null,
        [scriptblock]$Downloader,
        [object]$Now = $null
    )
    # N2: елевований процес без явного WorkRoot будує план у захищеному <StagingRoot>\<guid>\work (після перевірки
    # контейнерів ProgramData), а не у %TEMP% з особистим SID оператора.
    $planWork = Resolve-BRAVOUpdatePlanWorkRoot -WorkRoot $WorkRoot -StagingRoot ([string]$Paths.StagingRoot) -IsAdministrator ([bool](Test-BRAVOUpdateWorkerIsAdministrator))
    $childWork = $null
    if ($planWork.UseChildWorkDirectory) {
        $childWork = New-BRAVOUpdateChildWorkDirectory -Root $planWork.Root
        $workDirectory = [string]$childWork.WorkDirectory
        $private = [pscustomobject]@{ Success = [bool]$childWork.Success; Problems = @($childWork.Problems) }
    } else {
        $WorkRoot = $planWork.Root
        $workDirectory = Join-Path $WorkRoot ($script:BRAVOUpdateWorkerPlanWorkPrefix + [guid]::NewGuid().ToString('N'))
        $private = New-BRAVOUpdatePrivateDirectory -Path $workDirectory
    }
    if (-not $private.Success) {
        return [pscustomobject]@{ Plan = $null; Findings = @(New-BRAVOUpdateWorkerFinding -Id 'Plan.WorkDirectory' -Title 'Не вдалося створити робочий каталог плану' -Details ($private.Problems -join '; ') `
                    -Action 'Перевірте доступ до тимчасового каталогу.') }
    }
    try {
        $acquired = $null
        if (($null -ne $Acquire) -and $Acquire.ContainsKey('Stage')) {
            $acquired = & $Acquire['Stage'] $Tag $SourcePath ([bool]$AllowPrerelease) $workDirectory
        } else {
            $stageArguments = @{ Tag = $Tag; SourcePath = $SourcePath; WorkDirectory = $workDirectory; VersionStatePath = [string]$Paths.VersionStatePath; AllowPrerelease = $AllowPrerelease }
            if ($null -ne $Downloader) { $stageArguments['Downloader'] = $Downloader }
            $acquired = Invoke-BRAVOUpdateAcquireAndStage @stageArguments
        }
        if (-not $acquired.Success) { return [pscustomobject]@{ Plan = $null; Findings = @($acquired.Findings) } }

        $stagedBytes = [long](Get-BRAVOUpdateDirectorySize -Path ([string]$acquired.StagedRoot))
        $preflightArguments = @{
            Operation = $Operation; RuntimeRoot = $RuntimeRoot; StateRoot = [string]$Paths.StateRoot; LockRoot = [string]$Paths.LockRoot
            OperationLockPath = [string]$Paths.OperationLockPath; StagingRoot = [string]$Paths.StagingRoot; BackupRoot = [string]$Paths.BackupRoot
            RequiredBytes = ($stagedBytes * 2); Adapter = $Adapter
        }
        if ($null -ne $InstallationState) { $preflightArguments['InstallationState'] = $InstallationState }
        $preflight = Test-BRAVODeploymentPreflight @preflightArguments
        $planArguments = @{
            Action = $Operation; RuntimeRoot = $RuntimeRoot; StagingRoot = [string]$Paths.StagingRoot; BackupRoot = [string]$Paths.BackupRoot
            StateRoot = [string]$Paths.StateRoot; Source = $acquired.Source; StagedRoot = [string]$acquired.StagedRoot
            Preflight = $preflight; Adapter = $Adapter
        }
        if ($null -ne $InstallationState) { $planArguments['InstallationState'] = $InstallationState }
        if ($null -ne $Now) { $planArguments['Now'] = $Now }
        $plan = New-BRAVODeploymentPlan @planArguments
        return [pscustomobject]@{ Plan = $plan; Findings = @($acquired.Findings) }
    } catch {
        return [pscustomobject]@{ Plan = $null; Findings = @(New-BRAVOUpdateWorkerFinding -Id 'Plan.Unexpected' -Title 'План не вдалося побудувати' -Details $_.Exception.Message `
                    -Action 'Усуньте причину й повторіть побудову плану.') }
    } finally {
        if ($null -ne $childWork) { Remove-BRAVOUpdateChildWorkDirectory -WorkInfo $childWork } else { Remove-BRAVOUpdateWorkerPlanWorkDirectory -Path $workDirectory -WorkRoot $WorkRoot }
    }
}

function Invoke-BRAVOUpdateCliPlanStep {
    # Спільний крок Plan/Install/Update/Repair: стан -> корінь -> план.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][hashtable]$StateArguments,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        [string]$Tag = '',
        [string]$SourcePath = '',
        [switch]$AllowPrerelease,
        [string]$WorkRoot = '',
        [hashtable]$Acquire = $null,
        [scriptblock]$Downloader,
        [object]$Now = $null
    )
    $state = Get-BRAVOUpdateCliState @StateArguments
    $root = [string]$StateArguments['RuntimeRoot']
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [string](Get-BRAVOUpdatePropertyValue -InputObject $state -Name 'runtimeRoot' -Default '') }
    if ([string]::IsNullOrWhiteSpace($root)) {
        if ($Operation -eq 'Install') {
            $root = [string]$Paths.RuntimeRoot
        } else {
            return [pscustomobject]@{ Plan = $null; Findings = @(New-BRAVOUpdateWorkerFinding -Id 'Plan.RuntimeRoot' -Title 'Встановлення не знайдено або їх кілька' `
                        -Action 'Вкажіть -RuntimeRoot явно.' -Details ('state=' + [string](Get-BRAVOUpdatePropertyValue -InputObject $state -Name 'state' -Default ''))) }
        }
    }
    return (New-BRAVOUpdateCliPlan -Operation $Operation -RuntimeRoot $root -Paths $Paths -Adapter $Adapter -InstallationState $state -Tag $Tag -SourcePath $SourcePath `
            -AllowPrerelease:$AllowPrerelease -WorkRoot $WorkRoot -Acquire $Acquire -Downloader $Downloader -Now $Now)
}

# ---------------------------------------------------------------------------
# CLI: елевація, підсумок, диспетчер
# ---------------------------------------------------------------------------

function Invoke-BRAVOUpdateElevatedProcess {
    # Запускає елевований BRAVO_UPDATE.ps1 і чекає (Start-Process -Verb RunAs
    # -Wait). Скасований UAC = Win32Exception -> Launched=$false, код 36.
    # Лише шляхи в аргументах, жодних секретів.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string[]]$ScriptArgument,
        [scriptblock]$ElevatedLauncher
    )
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($fixed in @('-NoProfile', '-File')) { $parts.Add($fixed) }
    $parts.Add((ConvertTo-BRAVOUpdateQuotedArgument -Value $ScriptPath))
    foreach ($argument in $ScriptArgument) {
        if ($argument -match '^-[A-Za-z]+$') { $parts.Add($argument) } else { $parts.Add((ConvertTo-BRAVOUpdateQuotedArgument -Value $argument)) }
    }
    $argumentList = $parts.ToArray()
    if ($null -ne $ElevatedLauncher) { return (& $ElevatedLauncher $argumentList) }
    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList ([string]::Join(' ', $argumentList)) -Verb RunAs -Wait -PassThru -ErrorAction Stop
        return [pscustomobject]@{ Launched = $true; ExitCode = [int]$process.ExitCode; Error = '' }
    } catch {
        return [pscustomobject]@{ Launched = $false; ExitCode = 36; Error = [string]$_.Exception.Message }
    }
}

function Format-BRAVOUpdateCliSummary {
    # Людський підсумок для консолі (-AsJson його не друкує). Лише рядки.
    [CmdletBinding()]
    param([AllowNull()]$Result)
    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Result) { return @() }
    $findings = @(Get-BRAVOUpdatePropertyValue -InputObject $Result -Name 'findings' -Default @())
    if (Test-BRAVOUpdateHasProperty -InputObject $Result -Name 'status') {
        $lines.Add('Результат: ' + [string]$Result.status + ' (код ' + [string]$Result.exitCode + ' ' + [string]$Result.exitCodeName + ')')
    } elseif (Test-BRAVOUpdateHasProperty -InputObject $Result -Name 'state') {
        $lines.Add('Стан встановлення: ' + [string]$Result.state)
        $versionObject = Get-BRAVOUpdatePropertyValue -InputObject $Result -Name 'version'
        if ($null -ne $versionObject) { $lines.Add('Версія: ' + [string](Get-BRAVOUpdatePropertyValue -InputObject $versionObject -Name 'packageVersion' -Default '')) }
    } elseif (Test-BRAVOUpdateHasProperty -InputObject $Result -Name 'canProceed') {
        $lines.Add('Можна продовжувати: ' + [string]$Result.canProceed + '; блокерів ' + [string]$Result.blockerCount + ', попереджень ' + [string]$Result.warningCount)
    }
    foreach ($finding in $findings) {
        if ($null -eq $finding) { continue }
        $severity = [string](Get-BRAVOUpdatePropertyValue -InputObject $finding -Name 'severity' -Default '')
        if (@('Warning', 'Blocker') -cnotcontains $severity) { continue }
        $line = (Format-BRAVOUpdateFindingMarker -Severity $severity) + ' ' + [string](Get-BRAVOUpdatePropertyValue -InputObject $finding -Name 'title' -Default '')
        $hintText = [string](Get-BRAVOUpdatePropertyValue -InputObject $finding -Name 'action' -Default '')
        if ($hintText -ne '') { $line = $line + ' — ' + $hintText }
        $lines.Add($line)
    }
    return @($lines.ToArray())
}

function New-BRAVOUpdateCliUsageResult {
    # Результат помилки використання/відмови для read-only дій: PreflightResult
    # (контрактна форма) з blocker-ом; для дій mutation — DeploymentResult.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][object[]]$Finding,
        [string]$Reason = 'Blocked',
        $Plan = $null
    )
    if (@('Execute', 'Install', 'Update', 'Repair', 'Recover') -contains $Action) {
        $resultAction = $Action
        if ($Action -eq 'Recover') { $resultAction = 'Recovery' }
        if ($Action -eq 'Execute') { $resultAction = 'Update' }
        $operationId = ''
        $planId = ''
        if ($null -ne $Plan) {
            $operationId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'operationId' -Default '')
            $planId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'planId' -Default '')
            $resultAction = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'action' -Default $resultAction)
        }
        return (New-BRAVOUpdateWorkerFailureResult -OperationId $operationId -PlanId $planId -Action $resultAction -ReasonCode $Reason -Finding $Finding)
    }
    $operation = 'Diagnose'
    if (@('Install', 'Update', 'Repair') -contains $Action) { $operation = $Action }
    return (New-BRAVOUpdatePreflightResult -Operation $operation -Findings $Finding)
}

function Invoke-BRAVOUpdateElevatedRecover {
    <#
    .SYNOPSIS
        Recover без прав: перезапуск елевованого BRAVO_UPDATE.ps1 -Action Recover
        -RecoveryId <guid>; результат читається з <StateRoot>\Operations\<id>\result.json.
    .DESCRIPTION
        H1: елевований процес НЕ пише у шлях, який задав неелевований викликач
        (раніше -ResultPath у користувацькому temp: підміна каталогу junction-ом
        спрямувала б привілейований запис на чужий шлях). Каталог результату створює
        елевований engine у захищеному дереві стану (Users лише читають).
        -WorkRoot залишено лише для сумісності підпису: більше не використовується.
    #>
    [CmdletBinding()]
    param([string]$ScriptPath = '', [string]$StateRoot = '', [string]$WorkRoot = '', [scriptblock]$ElevatedLauncher)
    $problem = {
        param([string]$Id, [string]$Title, [string]$Details, [int]$Code)
        $hint = $null
        if ($script:BRAVOUpdateWorkerHintCodes -contains $Code) { $hint = $Code }
        $finding = New-BRAVOUpdateWorkerFinding -Id $Id -Title $Title -Details $Details -Hint $hint -Action 'Запустіть відновлення від імені адміністратора.'
        [pscustomobject]@{ ExitCode = $Code; Result = (New-BRAVOUpdateWorkerFailureResult -OperationId '' -PlanId '' -Action 'Recovery' -Finding @($finding)) }
    }
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return (& $problem 'Cli.NoScript' 'Не вказано шлях BRAVO_UPDATE.ps1 для підвищення прав' '' 36) }
    if ([string]::IsNullOrWhiteSpace($StateRoot)) { $StateRoot = [string](Get-BRAVOUpdateDefaultPaths).StateRoot }
    $recoveryId = [guid]::NewGuid().ToString()
    $launched = Invoke-BRAVOUpdateElevatedProcess -ScriptPath $ScriptPath -ElevatedLauncher $ElevatedLauncher `
        -ScriptArgument @('-Action', 'Recover', '-RecoveryId', $recoveryId, '-NoPause')
    if (-not $launched.Launched) { return (& $problem 'Worker.PrivilegeRequired' 'Підвищення прав не підтверджено' ([string]$launched.Error) 36) }
    $resultFile = Join-Path (Join-Path (Join-Path $StateRoot 'Operations') $recoveryId) 'result.json'
    $read = Read-BRAVOUpdateContractFile -Path $resultFile -Kind DeploymentResult
    if (-not $read.IsValid) {
        $code = [int]$launched.ExitCode
        if ($code -le 0) { $code = 80 }
        return (& $problem 'Cli.NoResult' 'Елевований процес не залишив результату' (($read.Problems) -join '; ') $code)
    }
    return [pscustomobject]@{ ExitCode = [int]$read.Contract.exitCode; Result = $read.Contract }
}

function Invoke-BRAVOUpdateCliMutation {
    # Install/Update/Repair: план -> показ -> підтвердження -> запит ->
    # worker (in-process за наявності прав, інакше UAC) -> результат.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][hashtable]$StateArguments,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        [hashtable]$Operations = $null,
        [hashtable]$Acquire = $null,
        [string]$Tag = '',
        [string]$SourcePath = '',
        [switch]$AllowPrerelease,
        [string]$BackupDestination = '',
        [string]$Scope = 'All',
        [string]$PlanPath = '',
        [string]$ConfirmPlanId = '',
        [switch]$NonInteractive,
        [bool]$IsAdministrator = $false,
        [scriptblock]$Prompt = $null,
        [scriptblock]$Report = $null,
        [scriptblock]$ElevatedLauncher = $null,
        [string]$ScriptPath = '',
        [string]$WorkRoot = '',
        [scriptblock]$Downloader = $null,
        [object]$Now = $null,
        [string[]]$CandidateRoots = @()
    )
    $done = {
        param([int]$Code, $Result)
        [pscustomobject]@{ ExitCode = $Code; Result = $Result; Lines = @(Format-BRAVOUpdateCliSummary -Result $Result) }
    }
    $refuse = {
        param([string]$Id, [string]$Title, [string]$Details, $Plan, [object]$Hint, [string]$Reason)
        $finding = New-BRAVOUpdateWorkerFinding -Id $Id -Title $Title -Details $Details -Hint $Hint -Action 'Перевірте параметри й повторіть; mutation не виконувалась.'
        $code = 80
        if ($null -ne $Hint) { $code = [int]$Hint }
        & $done $code (New-BRAVOUpdateCliUsageResult -Action $Action -Finding @($finding) -Plan $Plan -Reason $Reason)
    }
    if (($Action -eq 'Install') -and [string]::IsNullOrEmpty($BackupDestination)) {
        return (& $refuse 'Cli.Usage' 'Для Install потрібен -BackupDestination Cloud|CloudAndSamba|SambaOnly|LocalOnly' '' $null $null 'Blocked')
    }
    if ($NonInteractive -and ([string]::IsNullOrEmpty($PlanPath) -or [string]::IsNullOrEmpty($ConfirmPlanId))) {
        return (& $refuse 'Cli.Usage' 'Неінтерактивний режим дозволено лише з -PlanPath і -ConfirmPlanId' '' $null $null 'Blocked')
    }

    # 1. План: із файлу або побудований зараз.
    $plan = $null
    if (-not [string]::IsNullOrEmpty($PlanPath)) {
        $loaded = Read-BRAVOUpdateContractFile -Path $PlanPath -Kind DeploymentPlan
        if (-not $loaded.IsValid) { return (& $refuse 'Cli.PlanInvalid' 'Файл плану некоректний' (($loaded.Problems) -join '; ') $null $null 'Blocked') }
        $plan = $loaded.Contract
        if ([string]$plan.action -cne $Action) { return (& $refuse 'Cli.PlanAction' 'Дія плану не збігається з -Action' ('план: ' + [string]$plan.action) $plan $null 'Blocked') }
    } else {
        $built = Invoke-BRAVOUpdateCliPlanStep -Operation $Action -StateArguments $StateArguments -Paths $Paths -Adapter $Adapter -Tag $Tag -SourcePath $SourcePath `
            -AllowPrerelease:$AllowPrerelease -WorkRoot $WorkRoot -Acquire $Acquire -Downloader $Downloader -Now $Now
        if ($null -eq $built.Plan) {
            $code = Get-BRAVOUpdateWorkerHintExitCode -Finding @($built.Findings)
            if ($code -le 10) { $code = 80 }
            return (& $done $code (New-BRAVOUpdateCliUsageResult -Action $Action -Finding @($built.Findings)))
        }
        $plan = $built.Plan
    }
    $planBlockers = @(@(Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'findings' -Default @()) | Where-Object { [string](Get-BRAVOUpdatePropertyValue -InputObject $_ -Name 'severity') -ceq 'Blocker' })
    $shortId = ([string]$plan.planId).Substring(0, 8)
    if ($null -ne $Report) { & $Report (@(Format-BRAVODeploymentPlanText -Plan $plan) + @('Короткий id плану: ' + $shortId)) }
    if ($planBlockers.Count -gt 0) {
        $failed = New-BRAVOUpdateWorkerFailureResult -OperationId ([string]$plan.operationId) -PlanId ([string]$plan.planId) -Action $Action -Finding $planBlockers
        return (& $done ([int]$failed.exitCode) $failed)
    }

    # 2. Підтвердження: інтерактивно — введений короткий id; неінтерактивно — лише -ConfirmPlanId.
    $typed = ''
    if ($NonInteractive) {
        $typed = $ConfirmPlanId
    } elseif ($null -ne $Prompt) {
        $typed = [string](& $Prompt ('Щоб підтвердити виконання плану, введіть його короткий id (' + $shortId + '): '))
    } else {
        return (& $refuse 'Cli.NoConfirmation' 'Підтвердження неможливе: немає інтерактивного введення' 'Використайте -PlanPath разом із -ConfirmPlanId.' $plan $null 'Cancelled')
    }
    if ($typed.Trim().ToLowerInvariant() -cne $shortId) {
        return (& $refuse 'Cli.ConfirmMismatch' 'Короткий id плану не збігається; операцію скасовано' '' $plan $null 'Cancelled')
    }

    # 3. Запит. Каталоги протоколу створює лише процес з правами.
    $stateRoot = [string]$Paths.StateRoot
    if ($IsAdministrator) {
        $initialized = Initialize-BRAVOUpdateProtectedRoots -Paths $Paths
        if (-not $initialized.Success) {
            return (& $refuse 'State.RootUnsafe' 'Каталоги стану engine не пройшли перевірку власника/прав' (@($initialized.Problems) -join '; ') $plan $null 'Blocked')
        }
    }
    $changes = Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'changes'
    $scheduler = Get-BRAVOUpdatePropertyValue -InputObject $changes -Name 'scheduler'
    $activation = [string](Get-BRAVOUpdatePropertyValue -InputObject $scheduler -Name 'activationPolicy' -Default '')
    $options = @{
        prereleaseAuthorized = [bool]$AllowPrerelease; activationPolicy = $activation; runSelfTest = $false
        backupDestination = $BackupDestination; sourcePath = $SourcePath; scope = $Scope
    }
    $requestPath = $null
    try {
        $request = New-BRAVOUpdateRequest -Plan $plan -ConfirmedPlanShortId $typed -Option $options
        $requestPath = Write-BRAVOUpdateRequestFile -Request $request -StateRoot $stateRoot
    } catch {
        return (& $refuse 'Worker.PrivilegeRequired' 'Запит не вдалося створити (каталог запитів недоступний)' $_.Exception.Message $plan 36 'Blocked')
    }

    # 4. Виконання: у процесі з правами, інакше UAC.
    if ($IsAdministrator) {
        $workerArguments = @{ RequestPath = $requestPath; Adapter = $Adapter; Paths = $Paths; CandidateRoots = $CandidateRoots; IsAdministrator = $true }
        if ($null -ne $Operations) { $workerArguments['Operations'] = $Operations }
        if ($null -ne $Now) { $workerArguments['Now'] = $Now }
        $worker = Invoke-BRAVOUpdateWorker @workerArguments
        return (& $done ([int]$worker.ExitCode) $worker.Result)
    }
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        return (& $refuse 'Cli.NoScript' 'Не вказано шлях BRAVO_UPDATE.ps1 для підвищення прав' '' $plan 36 'Blocked')
    }
    $launched = Invoke-BRAVOUpdateElevatedProcess -ScriptPath $ScriptPath -ElevatedLauncher $ElevatedLauncher `
        -ScriptArgument @('-Action', 'Execute', '-RequestPath', $requestPath, '-NoPause')
    if (-not $launched.Launched) {
        return (& $refuse 'Worker.PrivilegeRequired' 'Підвищення прав не підтверджено (UAC скасовано)' ([string]$launched.Error) $plan 36 'Blocked')
    }
    $resultFile = Join-Path (Join-Path (Join-Path $stateRoot 'Operations') ([string]$plan.operationId)) 'result.json'
    $read = Read-BRAVOUpdateContractFile -Path $resultFile -Kind DeploymentResult
    if ($read.IsValid) { return (& $done ([int]$read.Contract.exitCode) $read.Contract) }
    $code = [int]$launched.ExitCode
    if ($code -le 0) { $code = 80 }
    $hint = $null
    if ($script:BRAVOUpdateWorkerHintCodes -contains $code) { $hint = $code }
    $finding = New-BRAVOUpdateWorkerFinding -Id 'Cli.NoResult' -Title 'Елевований процес не залишив результату' -Details (($read.Problems) -join '; ') -Hint $hint `
        -Action 'Перевірте журнал операції; за потреби виконайте -Action Recover.'
    $failed = New-BRAVOUpdateWorkerFailureResult -OperationId ([string]$plan.operationId) -PlanId ([string]$plan.planId) -Action $Action -ReasonCode Error -Finding @($finding)
    return (& $done ([int]$failed.exitCode) $failed)
}

function Invoke-BRAVOUpdateCliAction {
    <#
    .SYNOPSIS
        Диспетчер тонкого CLI BRAVO_UPDATE.ps1 (ENGINE_DESIGN §10.2).
        Повертає { ExitCode, Result, Lines }; не виходить і не пише в консоль.
    .DESCRIPTION
        Result — контрактний об'єкт (InstallationState, PreflightResult,
        DeploymentPlan, DeploymentResult або DiagnosticReport) для -AsJson /
        -ResultPath. Lines — людський підсумок.
        Seam-и (-Prompt, -Report, -ElevatedLauncher, -Operations, -Acquire,
        -IsAdministrator, -Paths, -Adapter) призначені для тестів і для
        entrypoint-а; FaultInjection не приймається нізвідки.
    .PARAMETER Prompt
        scriptblock param([string]$Message) -> введений рядок (інтерактивне
        підтвердження коротким id). Без нього інтерактивне підтвердження
        неможливе (80).
    .PARAMETER Report
        scriptblock param([string[]]$Line): показ плану перед підтвердженням.
    .PARAMETER ElevatedLauncher
        scriptblock param([string[]]$ArgumentList) -> { Launched, ExitCode, Error }
        (production: Start-Process -Verb RunAs -Wait). ScriptPath — шлях
        BRAVO_UPDATE.ps1 для перезапуску з elevation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('State', 'Preflight', 'Plan', 'Execute', 'Install', 'Update', 'Repair', 'Recover', 'Diagnose', 'Initialize')][string]$Action,
        [ValidateSet('', 'Install', 'Update', 'Repair')][string]$Operation = '',
        [string]$RuntimeRoot = '',
        [string]$SourcePath = '',
        [string]$Tag = '',
        [switch]$AllowPrerelease,
        [string]$BackupDestination = '',
        [ValidateSet('All', 'Runtime', 'Scheduler')][string]$Scope = 'All',
        [string]$PlanPath = '',
        [string]$RequestPath = '',
        [string]$ConfirmPlanId = '',
        [string]$RecoveryId = '',
        [switch]$NonInteractive,
        [string[]]$CandidateRoots = @(),
        $Paths = $null,
        [hashtable]$Adapter = $null,
        [hashtable]$Operations = $null,
        [hashtable]$Acquire = $null,
        [AllowNull()][object]$IsAdministrator = $null,
        [scriptblock]$Prompt = $null,
        [scriptblock]$Report = $null,
        [scriptblock]$ElevatedLauncher = $null,
        [string]$ScriptPath = '',
        [string]$WorkRoot = '',
        [scriptblock]$Downloader = $null,
        [object]$Now = $null
    )
    $useDefaultAdapter = ($null -eq $Adapter)
    if ($null -eq $Paths) { $Paths = Get-BRAVOUpdateDefaultPaths }
    if ($null -eq $Adapter) { $Adapter = New-BRAVOUpdateDefaultAdapter -StagingRoot ([string]$Paths.StagingRoot) }
    $isAdmin = $IsAdministrator
    if ($null -eq $isAdmin) { $isAdmin = Test-BRAVOUpdateWorkerIsAdministrator }
    $isAdmin = [bool]$isAdmin
    if (@($CandidateRoots).Count -eq 0) { $CandidateRoots = @([string]$Paths.RuntimeRoot, [string]$script:BRAVOUpdateToolkitRoot) }

    $done = {
        param([int]$Code, $Result)
        [pscustomobject]@{ ExitCode = $Code; Result = $Result; Lines = @(Format-BRAVOUpdateCliSummary -Result $Result) }
    }
    $usage = {
        param([string]$Title, [string]$Details)
        $finding = New-BRAVOUpdateWorkerFinding -Id 'Cli.Usage' -Title $Title -Details $Details -Action 'Перевірте параметри (див. docs\installer\ENGINE_DESIGN.md, розділ 10.2).'
        & $done 80 (New-BRAVOUpdateCliUsageResult -Action $Action -Finding @($finding))
    }
    # N1: елевований процес ПЕРШИМ кроком перевіряє корені engine разом із контейнерами ProgramData для КОЖНОЇ дії (навіть
    # read-only: GetEffectiveConfiguration виконує згенерований скрипт). Mutation-дії ще й створюють/виправляють корені;
    # read-only лише перевіряють. Неелевований процес нічого не створює й не перевіряє тут (user work dir).
    if ($isAdmin -and (@('Initialize') -cnotcontains $Action)) {
        $topMutating = (@('Execute', 'Install', 'Update', 'Repair', 'Recover') -contains $Action)
        $topRoots = Initialize-BRAVOUpdateProtectedRoots -Paths $Paths -Validate:(-not $topMutating)
        if (-not $topRoots.Success) {
            return (& $done 80 (New-BRAVOUpdateCliUsageResult -Action $Action -Finding @($topRoots.Findings)))
        }
    }
    $stateArguments = @{ RuntimeRoot = $RuntimeRoot; CandidateRoots = $CandidateRoots; Paths = $Paths; Adapter = $Adapter; IncludeScheduler = $useDefaultAdapter }
    $preflightFor = {
        param([string]$PreflightOperation, $State, [string]$Root)
        Test-BRAVODeploymentPreflight -Operation $PreflightOperation -RuntimeRoot $Root -StateRoot ([string]$Paths.StateRoot) -LockRoot ([string]$Paths.LockRoot) `
            -OperationLockPath ([string]$Paths.OperationLockPath) -StagingRoot ([string]$Paths.StagingRoot) -BackupRoot ([string]$Paths.BackupRoot) -InstallationState $State -Adapter $Adapter
    }

    switch ($Action) {
        'State' {
            $state = Get-BRAVOUpdateCliState @stateArguments
            return (& $done 0 $state)
        }
        'Diagnose' {
            $state = Get-BRAVOUpdateCliState @stateArguments
            $root = $RuntimeRoot
            if ([string]::IsNullOrWhiteSpace($root)) { $root = [string](Get-BRAVOUpdatePropertyValue -InputObject $state -Name 'runtimeRoot' -Default '') }
            if ([string]::IsNullOrWhiteSpace($root)) { $root = [string]$Paths.RuntimeRoot }
            $preflight = & $preflightFor 'Diagnose' $state $root
            $recent = New-Object System.Collections.Generic.List[object]
            $operationsRoot = Join-Path ([string]$Paths.StateRoot) 'Operations'
            if ([System.IO.Directory]::Exists($operationsRoot)) {
                foreach ($directory in @(Get-ChildItem -LiteralPath $operationsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 3)) {
                    $readResult = Read-BRAVOUpdateContractFile -Path (Join-Path $directory.FullName 'result.json') -Kind DeploymentResult
                    if ($readResult.IsValid) { $recent.Add($readResult.Contract) }
                }
            }
            $diagnosticReport = New-BRAVODiagnosticReport -InstallationState $state -Preflight $preflight -RecentResults $recent.ToArray() -LogTail @() -SiteIdentifiers @()
            return (& $done 0 $diagnosticReport)
        }
        'Preflight' {
            $state = Get-BRAVOUpdateCliState @stateArguments
            $stateName = [string](Get-BRAVOUpdatePropertyValue -InputObject $state -Name 'state' -Default '')
            $op = $Operation
            if ([string]::IsNullOrEmpty($op)) { if ($stateName -eq 'NotInstalled') { $op = 'Install' } else { $op = 'Update' } }
            $root = $RuntimeRoot
            if ([string]::IsNullOrWhiteSpace($root)) { $root = [string](Get-BRAVOUpdatePropertyValue -InputObject $state -Name 'runtimeRoot' -Default '') }
            if ([string]::IsNullOrWhiteSpace($root)) { $root = [string]$Paths.RuntimeRoot }
            $preflight = & $preflightFor $op $state $root
            return (& $done (Get-BRAVOUpdateWorkerHintExitCode -Finding @($preflight.findings)) $preflight)
        }
        'Plan' {
            if ([string]::IsNullOrEmpty($Operation)) { return (& $usage 'Для -Action Plan потрібен -Operation Install|Update|Repair' '') }
            $built = Invoke-BRAVOUpdateCliPlanStep -Operation $Operation -StateArguments $stateArguments -Paths $Paths -Adapter $Adapter -Tag $Tag -SourcePath $SourcePath `
                -AllowPrerelease:$AllowPrerelease -WorkRoot $WorkRoot -Acquire $Acquire -Downloader $Downloader -Now $Now
            if ($null -eq $built.Plan) {
                $failedPreflight = New-BRAVOUpdatePreflightResult -Operation $Operation -Findings @($built.Findings)
                return (& $done (Get-BRAVOUpdateWorkerHintExitCode -Finding @($built.Findings)) $failedPreflight)
            }
            $allFindings = @(@($built.Plan.findings) + @($built.Findings))
            $summary = & $done (Get-BRAVOUpdateWorkerHintExitCode -Finding $allFindings) $built.Plan
            $summary.Lines = @(Format-BRAVODeploymentPlanText -Plan $built.Plan) + @('Короткий id плану: ' + ([string]$built.Plan.planId).Substring(0, 8))
            return $summary
        }
        'Execute' {
            if ([string]::IsNullOrWhiteSpace($RequestPath)) { return (& $usage 'Для -Action Execute потрібен -RequestPath' '') }
            $workerArguments = @{ RequestPath = $RequestPath; Adapter = $Adapter; Paths = $Paths; CandidateRoots = $CandidateRoots; IsAdministrator = $isAdmin }
            if ($null -ne $Operations) { $workerArguments['Operations'] = $Operations }
            if ($null -ne $Now) { $workerArguments['Now'] = $Now }
            $worker = Invoke-BRAVOUpdateWorker @workerArguments
            $executed = & $done ([int]$worker.ExitCode) $worker.Result
            # H1/6: короткий id плану, версія й sha джерела — на початок елевованого консольного підсумку.
            if (-not [string]::IsNullOrEmpty([string]$worker.Attestation)) { $executed.Lines = @([string]$worker.Attestation) + @($executed.Lines) }
            return $executed
        }
        'Initialize' {
            # Первинне налаштування каталогів стану: лише з правами адміністратора (GUI їх не створює).
            if (-not $isAdmin) {
                $finding = New-BRAVOUpdateWorkerFinding -Id 'Worker.PrivilegeRequired' -Title 'Для первинного налаштування потрібні права адміністратора' -Action 'Запустіть від імені адміністратора (підтвердіть UAC).' -Hint 36
                return (& $done 36 (New-BRAVOUpdatePreflightResult -Operation 'Diagnose' -Findings @($finding)))
            }
            $initialized = Initialize-BRAVOUpdateProtectedRoots -Paths $Paths
            if (-not $initialized.Success) { return (& $done 80 (New-BRAVOUpdatePreflightResult -Operation 'Diagnose' -Findings @($initialized.Findings))) }
            $okFinding = New-BRAVOUpdateFinding -Id 'State.RootsReady' -Severity Ok -Title 'Каталоги стану engine готові' -Details ('створено: ' + @($initialized.Created).Count + '; оновлено права: ' + @($initialized.Reapplied).Count)
            return (& $done 0 (New-BRAVOUpdatePreflightResult -Operation 'Diagnose' -Findings @($okFinding)))
        }
        'Recover' {
            $target = 'Invoke-BRAVORecovery'
            if (($null -ne $Operations) -and $Operations.ContainsKey('Recover')) { $target = $Operations['Recover'] }
            if ($isAdmin) {
                # H1: корені engine перевіряються ДО читання журналів відновлення.
                $recoverRoots = Initialize-BRAVOUpdateProtectedRoots -Paths $Paths
                if (-not $recoverRoots.Success) {
                    return (& $done 80 (New-BRAVOUpdateWorkerFailureResult -OperationId '' -PlanId '' -Action 'Recovery' -Finding @($recoverRoots.Findings)))
                }
                $recoveryArguments = @{ StateRoot = [string]$Paths.StateRoot; LockRoot = [string]$Paths.LockRoot; OperationLockPath = [string]$Paths.OperationLockPath; Adapter = $Adapter; VersionStatePath = [string]$Paths.VersionStatePath }
                # Контракт E5: Recovery для Update/Repair вимагає знайдений корінь установки й корені staging/backup engine
                # (journal.stagingRoot має дорівнювати StagingRoot engine); викликається ПІСЛЯ перевірки захищених коренів.
                # Корінь установки визначається НЕЗАЛЕЖНИМ виявленням (Get-BRAVOInstallationState); явний -RuntimeRoot
                # приймається лише якщо його знайшло виявлення. Валідатор Recovery не послаблюється.
                $recoverRuntime = ''
                $recoverCandidates = @()
                try {
                    # Без явного RuntimeRoot: виявлення незалежне від того, що вказав викликач.
                    $independentArguments = @{}
                    foreach ($argumentKey in $stateArguments.Keys) { $independentArguments[$argumentKey] = $stateArguments[$argumentKey] }
                    $independentArguments['RuntimeRoot'] = ''
                    $recoverState = Get-BRAVOUpdateCliState @independentArguments
                    $recoverRuntime = [string](Get-BRAVOUpdatePropertyValue -InputObject $recoverState -Name 'runtimeRoot' -Default '')
                    $recoverCandidates = @(@(Get-BRAVOUpdatePropertyValue -InputObject $recoverState -Name 'candidateRoots' -Default @()) | ForEach-Object { [string]$_ })
                } catch { $recoverRuntime = ''; $recoverCandidates = @() }
                if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) {
                    $explicitFound = @($recoverCandidates | Where-Object { Test-BRAVOUpdateWorkerSamePath -Left $_ -Right $RuntimeRoot })
                    if (($explicitFound.Count -eq 0) -and -not (Test-BRAVOUpdateWorkerSamePath -Left $recoverRuntime -Right $RuntimeRoot)) {
                        $foreignRecover = New-BRAVOUpdateWorkerFinding -Id 'Cli.RecoverRuntimeRoot' -Title 'Вказаний -RuntimeRoot не є знайденим встановленням BRAVO' -Details $RuntimeRoot -Action 'Не вказуйте -RuntimeRoot або вкажіть каталог, який знайшов engine.'
                        return (& $done 80 (New-BRAVOUpdateWorkerFailureResult -OperationId '' -PlanId '' -Action 'Recovery' -Finding @($foreignRecover)))
                    }
                    $recoverRuntime = $RuntimeRoot
                }
                $recoveryArguments['StagingRoot'] = [string]$Paths.StagingRoot
                $recoveryArguments['BackupRoot'] = [string]$Paths.BackupRoot
                if (-not [string]::IsNullOrWhiteSpace($recoverRuntime)) { $recoveryArguments['RuntimeRoot'] = $recoverRuntime }
                foreach ($optionalName in @('RuntimeRoot', 'StagingRoot', 'BackupRoot')) {
                    if ($recoveryArguments.ContainsKey($optionalName) -and -not (Test-BRAVOUpdateWorkerAcceptsParameter -Operation $target -Name $optionalName)) { $recoveryArguments.Remove($optionalName) }
                }
                $outcome = $null
                try {
                    $outcome = @(& $target @recoveryArguments) | Where-Object { ($null -ne $_) -and ($null -ne $_.PSObject.Properties['status']) -and ($null -ne $_.PSObject.Properties['operationId']) } | Select-Object -Last 1
                } catch {
                    $recoverFinding = New-BRAVOUpdateWorkerFinding -Id 'Cli.RecoverFailed' -Title 'Відновлення завершилось невизначеним збоєм' -Details $_.Exception.Message -Action 'Не запускайте нових операцій; зверніться до підтримки з журналом.'
                    return (& $done 82 (New-BRAVOUpdateWorkerFailureResult -OperationId '' -PlanId '' -Action 'Recovery' -Status Critical -Finding @($recoverFinding)))
                }
                if ($null -eq $outcome) { return (& $usage 'Відновлення не повернуло результат' '') }
                # H1/5: результат елевованого Recover — лише у Operations/<recoveryId>/result.json під StateRoot
                # (захищене дерево; неелевований викликач читає його звідти), а не у шлях, заданий викликачем.
                if (-not [string]::IsNullOrWhiteSpace($RecoveryId)) {
                    if (-not (Test-BRAVOUpdateGuidText -Value $RecoveryId)) { return (& $usage 'RecoveryId має бути GUID' '') }
                    $recoveryOperation = New-BRAVOUpdateOperationDirectory -StateRoot ([string]$Paths.StateRoot) -OperationId $RecoveryId -LauncherSid ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
                    if ($recoveryOperation.Success) { [void](Write-BRAVOUpdateWorkerResultFile -OperationDirectory ([string]$recoveryOperation.Path) -Result $outcome) }
                }
                return (& $done ([int]$outcome.exitCode) $outcome)
            }
            # Без прав: перезапуск процесом з правами; результат — через тимчасовий файл.
            $elevated = Invoke-BRAVOUpdateElevatedRecover -ScriptPath $ScriptPath -StateRoot ([string]$Paths.StateRoot) -ElevatedLauncher $ElevatedLauncher
            return (& $done ([int]$elevated.ExitCode) $elevated.Result)
        }
        default {
            return (Invoke-BRAVOUpdateCliMutation -Action $Action -StateArguments $stateArguments -Paths $Paths -Adapter $Adapter -Operations $Operations -Acquire $Acquire `
                    -Tag $Tag -SourcePath $SourcePath -AllowPrerelease:$AllowPrerelease -BackupDestination $BackupDestination -Scope $Scope -PlanPath $PlanPath `
                    -ConfirmPlanId $ConfirmPlanId -NonInteractive:$NonInteractive -IsAdministrator $isAdmin -Prompt $Prompt -Report $Report `
                    -ElevatedLauncher $ElevatedLauncher -ScriptPath $ScriptPath -WorkRoot $WorkRoot -Downloader $Downloader -Now $Now -CandidateRoots $CandidateRoots)
        }
    }
}
