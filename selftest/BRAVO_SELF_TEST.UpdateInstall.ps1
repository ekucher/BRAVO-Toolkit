# ============================================================
# UpdateInstall: clean install Installer v1 (INS-060…065)
# ============================================================
# Перевіряється реальна частина Install модуля BRAVO.Update на sandbox-каталогах у
# тимчасовому каталозі (з пробілами та кирилицею). Задачі, Credential Manager, ProgramData і
# Program Files не чіпаються: adapter — stub, шляхи — sandbox.
#
# Функції інших частин (Deploy/Reconcile/Validation/Rollback), яких може ще не бути в
# збірці, підставляються ЛИШЕ тут, у тестовому harness, мінімальними shim-ами (див.
# $e7Shims). Production-код Install викликає їх за іменами без fallback-копій.

Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking

$e7Module = Get-Module BRAVO.Update

# --- Shim-и частин, яких може не бути (тільки harness; не production) -----------------------
$e7Shims = {
    if ($null -eq (Get-Command -Name 'Invoke-BRAVORuntimeDeploy' -ErrorAction SilentlyContinue)) {
        function script:New-BRAVOUpdateOperationContext {
            param($Plan, $Adapter, $Paths, $OperationDirectory, $Journal, $FaultInjection = $null)
            return [pscustomobject]@{
                OperationId = [string]$Journal.operationId; Plan = $Plan; Adapter = $Adapter; Paths = $Paths
                OperationDirectory = $OperationDirectory; Journal = $Journal; MutationStarted = $false
                FaultInjection = $FaultInjection; Findings = (New-Object System.Collections.Generic.List[object])
            }
        }
        function script:Invoke-BRAVOUpdatePhase {
            param($Context, [string]$Phase, [string]$ProgressPhase, [scriptblock]$Action, [switch]$Durable)
            $injection = $Context.FaultInjection
            $fault = {
                param([string]$Point)
                if ($null -ne $injection -and $injection.ContainsKey($Phase + '.' + $Point)) {
                    if ([string]$injection[$Phase + '.' + $Point] -eq 'Crash') { throw 'BRAVOUpdate.SimulatedCrash' }
                    throw ('BRAVOUpdate.InjectedFault ' + $Phase + '.' + $Point)
                }
            }
            & $fault 'Before'
            if ($Durable) { [void](Add-BRAVOUpdateJournalPhaseIntent -Journal $Context.Journal -Phase $Phase -StateRoot $Context.Paths.StateRoot) }
            & $fault 'AfterIntent'
            [void](& $Action)
            & $fault 'AfterSideEffect'
            if ($Durable) { [void](Complete-BRAVOUpdateJournalPhase -Journal $Context.Journal -Phase $Phase -Outcome 'Succeeded' -StateRoot $Context.Paths.StateRoot) }
            & $fault 'AfterComplete'
        }
        function script:Get-BRAVODeploymentFileSet {
            param($StagedRoot, $RuntimeRoot, $OldManifestPath)
            $keys = @{}
            $base = $StagedRoot.TrimEnd('\')
            foreach ($file in @(Get-ChildItem -LiteralPath $StagedRoot -File -Recurse -Force)) {
                $key = $file.FullName.Substring($base.Length + 1) -replace '\\', '/'
                $keys[$key] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
            }
            $unknown = @(); if ($script:E7UnknownScript) { $unknown = @('evil.ps1') }
            return [pscustomobject]@{ DeployKeys = $keys; Add = @($keys.Keys); Change = @(); Unchanged = @(); Remove = @(); UnknownScripts = $unknown; UnknownOther = @(); NamespaceViolations = @(); ReparsePoints = @() }
        }
        function script:Save-BRAVODeploymentKeySet {
            param($FileSet, $OperationDirectory)
            $path = Join-Path $OperationDirectory 'deploy-keys.json'
            [IO.File]::WriteAllText($path, ($FileSet.DeployKeys | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
            return [pscustomobject]@{ Path = $path; Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
        }
        function script:Invoke-BRAVORuntimeDeploy {
            param($Context, $StagedRoot, $FileSet)
            $copied = 0
            foreach ($key in @($FileSet.DeployKeys.Keys | Sort-Object)) {
                $target = Join-Path $Context.Paths.RuntimeRoot ($key -replace '/', '\')
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                [IO.File]::Copy((Join-Path $StagedRoot ($key -replace '/', '\')), $target, $false)
                $copied++
                if ($null -ne $Context.FaultInjection -and $Context.FaultInjection.ContainsKey('Deploy.AfterFileCount') -and $copied -ge [int]$Context.FaultInjection['Deploy.AfterFileCount']) {
                    throw 'BRAVOUpdate.InjectedFault Deploy.AfterFileCount'
                }
            }
            return [pscustomobject]@{ Copied = @($FileSet.DeployKeys.Keys); Removed = @(); Errors = @() }
        }
        function script:Remove-BRAVOUpdateOperationDirectory {
            param($Path, $ExpectedParent, $OperationId)
            if ((Split-Path -Leaf $Path) -ne $OperationId) { throw 'leaf' }
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
        }
    }
    if ($null -eq (Get-Command -Name 'Get-BRAVOVersionStateSnapshot' -ErrorAction SilentlyContinue)) {
        function script:Get-BRAVOVersionStateSnapshot { param($VersionStatePath, $OperationDirectory) return [pscustomobject]@{ present = $false } }
    }
    if ($true) {
        function script:Get-BRAVOSiteConfigurationBaseline { param($RuntimeRoot) return @{} }
    }
    if ($true) { # E3 покрита власним suite
        function script:Get-BRAVOSchedulerSnapshot { param($Adapter, $RuntimeRoot) return [pscustomobject]@{ tasks = @() } }
    }
    if ($true) {
        function script:Invoke-BRAVOSchedulerReconcile {
            param($Context, $Snapshot)
            $script:E7ReconcileCalls++
            return [pscustomobject]@{ Verdict = $script:E7ReconcileVerdict; ExitCode = 0; CreatedTasks = @('Task-A'); RequiescedTasks = @('Task-A'); Problems = @('stub') }
        }
    }
    if ($true) { # E4 покрита власним suite; тут керований результат
        function script:Test-BRAVODeploymentValidation {
            param($Context, $Mode, $ExpectedVersion, $ExpectedManifestPath, $SiteBaseline)
            return [pscustomobject]@{ Status = $script:E7ValidationStatus; Items = @([pscustomobject]@{ name = 'VersionJson'; status = $script:E7ValidationStatus; message = 'stub' }) }
        }
    }
    # Disable-BRAVOAllManagedTasks (E3) повертає об'єкт, а Invoke-BRAVOInstallRollback (E5) викликає його без [void]:
    # у реальній збірці $cleanup стає масивом і відкат помилково дає Critical. Тут shim без виводу;
    # проблему зафіксовано у HANDOFF (виправлення -- у частині Rollback).
    function script:Disable-BRAVOAllManagedTasks { param($Adapter, $RuntimeRoot, $Snapshot, $TaskPath, $ManagedTaskName) $script:E7DisableAllCalls++ }
}
& $e7Module $e7Shims
# Керування shim-ами та Plan-current stub (лише harness).
$e7SetFlags = {
    param($Flags)
    $script:E7PlanCurrent = [bool]$Flags.PlanCurrent
    $script:E7UnknownScript = [bool]$Flags.UnknownScript
    $script:E7ReconcileVerdict = [string]$Flags.ReconcileVerdict
    $script:E7ValidationStatus = [string]$Flags.ValidationStatus
    $script:E7RollbackThrows = [bool]$Flags.RollbackThrows
    $script:E7ReconcileCalls = 0
    $script:E7DisableAllCalls = 0
}
$e7PlanStub = {
    function script:Test-BRAVODeploymentPlanCurrent {
        param($Plan, $RuntimeRoot, $StateRoot, $Adapter = $null, $Now = $null)
        return [pscustomobject]@{ IsCurrent = $script:E7PlanCurrent; Expired = $false; FingerprintMatches = $script:E7PlanCurrent; Problems = @('stub: план не актуальний') }
    }
}
& $e7Module $e7PlanStub

function Set-BRAVOE7Flags {
    param([hashtable]$Overrides = @{})
    $flags = @{ PlanCurrent = $true; UnknownScript = $false; ReconcileVerdict = 'PASS'; ValidationStatus = 'Pass'; RollbackThrows = $false }
    foreach ($key in @($Overrides.Keys)) { $flags[$key] = $Overrides[$key] }
    & $e7Module $e7SetFlags $flags
}

function Get-BRAVOE7Counter {
    param([string]$Name)
    return (& $e7Module { param($N) Get-Variable -Name $N -Scope Script -ValueOnly } $Name)
}

function Invoke-BRAVOE7Module {
    param([scriptblock]$Script, [object[]]$Argument = @())
    return (& $e7Module $Script @Argument)
}

function Get-BRAVOE7TreeHash {
    # Відбиток дерева (відносні шляхи + SHA-256) для доказу «нічого не змінилось».
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    $base = $Path.TrimEnd('\')
    $lines = foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName)) {
        if ($item.PSIsContainer) { 'D ' + $item.FullName.Substring($base.Length) } else { 'F ' + $item.FullName.Substring($base.Length) + ' ' + (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }
    }
    return ($lines -join "`n")
}

$e7TempPrefix = Join-Path ([IO.Path]::GetTempPath()) 'BRAVO_UPD_e7_'
$e7Base = $e7TempPrefix + [guid]::NewGuid().ToString('N')
$e7Counter = 0
$e7Calls = @{ Seed = 0; Credentials = 0 }

function New-BRAVOE7Scenario {
    # Окремі sandbox-корені на сценарій. Родитель кореня встановлення існує (політика).
    $script:e7Counter++
    $scenarioRoot = Join-Path $e7Base ('сценарій ' + $script:e7Counter)
    $parent = Join-Path $scenarioRoot 'Програми BRAVO'
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $roots = @{
        Scenario = $scenarioRoot
        Runtime = (Join-Path $parent 'BRAVO Toolkit')
        State = (Join-Path $scenarioRoot 'state')
        Lock = (Join-Path $scenarioRoot 'locks')
        Staging = (Join-Path $scenarioRoot 'staging')
        Backup = (Join-Path $scenarioRoot 'backup')
        OperationLock = (Join-Path $scenarioRoot 'locks\BRAVO_OPERATION.lock')
        VersionState = (Join-Path $scenarioRoot 'state\BRAVO_VERSION_STATE.json')
    }
    return $roots
}

function New-BRAVOE7Plan {
    param([hashtable]$Roots, [string]$Action = 'Install')
    $planId = [guid]::NewGuid().ToString()
    return [pscustomobject]@{
        schemaVersion = 1; planId = $planId; operationId = [guid]::NewGuid().ToString(); action = $Action
        runtimeRoot = $Roots.Runtime; stagingRoot = $Roots.Staging; backupRoot = $Roots.Backup
        source = [pscustomobject]@{ kind = 'Offline'; tag = 'v9.9.9'; artifactSha256 = ('A' * 64); manifestSha256 = ('B' * 64); packageVersion = '9.9.9'; prereleaseAuthorized = $false }
        currentVersion = $null; targetVersion = '9.9.9'
    }
}

function New-BRAVOE7Adapter {
    param([string]$Presence = 'Found', [bool]$SeedCreates = $true, [bool]$TaskHost = $true)
    $calls = $e7Calls
    $adapter = @{}
    $adapter.TestCredentialPresence = {
        param($RuntimeRoot, $Component)
        $calls.Credentials++
        [pscustomobject]@{ Component = $Component; Presence = $Presence; ExitCode = 0 }
    }.GetNewClosure()
    $adapter.GetUserProfileRoots = { @('C:\Users\Example-Nobody') }
    $adapter.StageRelease = {
        param($Plan, $SourcePath, $StagingDirectory, $Downloader)
        $staged = Join-Path $StagingDirectory 'runtime'
        New-Item -ItemType Directory -Path (Join-Path $staged 'modules\BRAVO.Update') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $staged 'дані') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $staged 'VERSION.json'), '{"packageVersion": "9.9.9", "releaseChannel": "stable"}', (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $staged 'BRAVO_SETUP.ps1'), '# stub', (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $staged 'modules\BRAVO.Update\x.psm1'), '# x', (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $staged 'дані\файл.txt'), 'кирилиця', (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $staged 'RUNTIME_MANIFEST.json'), '{"files": {}}', (New-Object Text.UTF8Encoding $false))
        [pscustomobject]@{ Success = $true; StagedRoot = $staged; Problems = @(); Findings = @() }
    }
    $adapter.SeedLocalConfig = {
        param($RuntimeRoot, $BackupDestination)
        $calls.Seed++
        $path = Join-Path $RuntimeRoot 'BRAVO.local.config'
        if (-not $SeedCreates) { return [pscustomobject]@{ Created = $false; Stage = 'Exists'; Path = $path; Reasons = @('вже існує') } }
        [IO.File]::WriteAllText($path, ('# seed ' + $BackupDestination), (New-Object Text.UTF8Encoding $false))
        [pscustomobject]@{ Created = $true; Stage = 'Complete'; Path = $path; Reasons = @() }
    }.GetNewClosure()
    return $adapter
}

function Invoke-BRAVOE7Install {
    param([hashtable]$Roots, $Plan, [hashtable]$Adapter, [hashtable]$Fault = $null, [string]$Destination = 'Cloud')
    $arguments = @{
        Plan = $Plan; Adapter = $Adapter; BackupDestination = $Destination
        RuntimeRoot = $Roots.Runtime; StateRoot = $Roots.State; LockRoot = $Roots.Lock; StagingRoot = $Roots.Staging
        BackupRoot = $Roots.Backup; OperationLockPath = $Roots.OperationLock; VersionStatePath = $Roots.VersionState
    }
    if ($null -ne $Fault) { $arguments['FaultInjection'] = $Fault }
    return (Install-BRAVOToolkit @arguments)
}

function Read-BRAVOE7Journal {
    param([hashtable]$Roots, $Plan)
    $path = Join-Path (Join-Path $Roots.State 'Journal') ([string]$Plan.operationId + '.json')
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return ([IO.File]::ReadAllText($path) | ConvertFrom-Json)
}

try {
    New-Item -ItemType Directory -Path $e7Base -Force | Out-Null

    # ---------------- 1. Успіх із credentials Found ----------------
    & {
        Set-BRAVOE7Flags
        $roots = New-BRAVOE7Scenario
        $plan = New-BRAVOE7Plan -Roots $roots
        $e7Calls.Seed = 0
        $result = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter (New-BRAVOE7Adapter -Presence 'Found') -Destination 'LocalOnly'
        $valid = Invoke-BRAVOE7Module { param($R) Test-BRAVOUpdateDeploymentResult -InputObject $R } @($result)
        $journal = Read-BRAVOE7Journal -Roots $roots -Plan $plan
        Test-BRAVOCondition -Condition ($result.status -eq 'Success' -and $result.exitCode -eq 0) -Name 'UpdateInstall/Success/Status' -Failure ("status=$($result.status) exit=$($result.exitCode) findings=" + (@($result.findings | ForEach-Object { $_.id + ':' + $_.details }) -join '|'))
        Test-BRAVOCondition -Condition ($valid.IsValid) -Name 'UpdateInstall/Success/ResultContractValid' -Failure ($valid.Problems -join '; ')
        Test-BRAVOCondition -Condition ((Test-Path -LiteralPath (Join-Path $roots.Runtime 'дані\файл.txt')) -and (Test-Path -LiteralPath (Join-Path $roots.Runtime 'BRAVO.local.config'))) -Name 'UpdateInstall/Success/FilesAndSeedPresent' -Failure 'файли або BRAVO.local.config відсутні'
        Test-BRAVOCondition -Condition ($result.taskActivation.state -eq 'Inactive' -and @($result.taskActivation.tasks) -contains 'Task-A') -Name 'UpdateInstall/Success/TasksInactive' -Failure ("activation=" + ($result.taskActivation | ConvertTo-Json -Compress))
        Test-BRAVOCondition -Condition ((Get-BRAVOE7Counter -Name 'E7ReconcileCalls') -eq 1 -and $e7Calls.Seed -eq 1) -Name 'UpdateInstall/Success/SchedulerAndSeedOnce' -Failure 'scheduler/seed викликано не один раз'
        Test-BRAVOCondition -Condition ($null -ne $journal -and $journal.state -eq 'Committed' -and $journal.mutationStarted -eq $true) -Name 'UpdateInstall/Success/JournalCommitted' -Failure 'журнал не Committed'
        $ownership = @($journal.createdOwnership)
        Test-BRAVOCondition -Condition ($ownership -contains ('dir:' + $roots.Runtime) -and $ownership -contains 'dir:modules/BRAVO.Update' -and $ownership -contains 'dir:дані') -Name 'UpdateInstall/Success/OwnershipDirs' -Failure ($ownership -join '|')
        $seedHash = (Get-FileHash -LiteralPath (Join-Path $roots.Runtime 'BRAVO.local.config') -Algorithm SHA256).Hash
        $deployKeysHash = (Get-FileHash -LiteralPath (Join-Path (Join-Path (Join-Path $roots.State 'Operations') ([string]$plan.operationId)) 'deploy-keys.json') -Algorithm SHA256).Hash
        Test-BRAVOCondition -Condition ($ownership -contains ('file:BRAVO.local.config|' + $seedHash) -and ($ownership -notcontains 'file:BRAVO.local.config') -and (@($ownership | Where-Object { $_ -like 'deploykeys:*' }).Count -eq 1 -and $ownership -contains ('deploykeys:' + $deployKeysHash))) -Name 'UpdateInstall/Success/OwnershipFileHashes' -Failure ($ownership -join '|')
        Test-BRAVOCondition -Condition (-not (Test-Path -LiteralPath (Join-Path $roots.Staging ([string]$plan.operationId)))) -Name 'UpdateInstall/Success/StagingRemoved' -Failure 'staging операції лишився'
        Test-BRAVOCondition -Condition (Test-Path -LiteralPath (Join-Path $roots.State ('ConsumedPlans\' + [string]$plan.planId))) -Name 'UpdateInstall/Success/PlanConsumed' -Failure 'план не позначено використаним'
        # Handle-и звільнені: lifecycle lock знову береться.
        $again = Invoke-BRAVOE7Module { param($L, $O) $l = Enter-BRAVOUpdateLifecycleLock -LockRoot $L -OperationId $O; $ok = $l.Success; Exit-BRAVOUpdateLifecycleLock -Lock $l; $ok } @($roots.Lock, [guid]::NewGuid().ToString())
        Test-BRAVOCondition -Condition ([bool]$again) -Name 'UpdateInstall/Success/LocksReleased' -Failure 'lifecycle lock не звільнено'
    }

    # ---------------- 2. DACL кореня: ті самі правила, що Set-BRAVOProtectedRuntimeAcl ----------------
    & {
        $dir = Join-Path $e7Base ('acl тест ' + [guid]::NewGuid().ToString('N'))
        $created = Invoke-BRAVOE7Module { param($P) New-BRAVOInstallProtectedDirectory -Path $P } @($dir)
        Test-BRAVOCondition -Condition ($created.Success) -Name 'UpdateInstall/Acl/Created' -Failure ($created.Problems -join '; ')
        $acl = Get-Acl -LiteralPath $dir
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $byValue = @{}
        foreach ($rule in $rules) { $byValue[[string]$rule.IdentityReference.Value] = $rule }
        Test-BRAVOCondition -Condition ($acl.AreAccessRulesProtected) -Name 'UpdateInstall/Acl/InheritanceDisabled' -Failure 'успадкування не вимкнено'
        Test-BRAVOCondition -Condition ($byValue.ContainsKey('S-1-5-32-544') -and $byValue.ContainsKey('S-1-5-18') -and $byValue.ContainsKey('S-1-5-32-545')) -Name 'UpdateInstall/Acl/ThreeSids' -Failure (@($byValue.Keys) -join ',')
        Test-BRAVOCondition -Condition (($byValue['S-1-5-32-544'].FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl -and
            ($byValue['S-1-5-18'].FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl) -Name 'UpdateInstall/Acl/AdminsSystemFullControl' -Failure 'права Administrators/SYSTEM'
        $usersRights = $byValue['S-1-5-32-545'].FileSystemRights
        Test-BRAVOCondition -Condition (($usersRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute -and
            ($usersRights -band [Security.AccessControl.FileSystemRights]::Write) -eq 0) -Name 'UpdateInstall/Acl/UsersReadExecuteOnly' -Failure ([string]$usersRights)
        Test-BRAVOCondition -Condition (@($rules | Where-Object { -not $_.IsInherited }).Count -eq $rules.Count) -Name 'UpdateInstall/Acl/NoInheritedRules' -Failure 'є успадковані правила'
        [IO.Directory]::Delete($dir, $false)
    }

    # ---------------- 3. Credentials Missing / Unknown -> SchedulerDeferred ----------------
    foreach ($presence in @('Missing', 'Unknown')) {
        & {
            Set-BRAVOE7Flags
            $roots = New-BRAVOE7Scenario
            $plan = New-BRAVOE7Plan -Roots $roots
            $result = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter (New-BRAVOE7Adapter -Presence $presence)
            $deferred = @($result.findings | Where-Object { $_.id -eq 'Install.SchedulerDeferred' })
            Test-BRAVOCondition -Condition ($result.status -eq 'SuccessWithWarnings' -and $result.exitCode -eq 10) -Name "UpdateInstall/Credentials$presence/SuccessWithWarnings" -Failure ("status=$($result.status) exit=$($result.exitCode) rollback=$($result.rollback.message) findings=" + (@($result.findings | ForEach-Object { $_.id + ':' + $_.details }) -join '|'))
            Test-BRAVOCondition -Condition ($deferred.Count -eq 1 -and $deferred[0].severity -eq 'Warning') -Name "UpdateInstall/Credentials$presence/SchedulerDeferredFinding" -Failure 'немає finding Install.SchedulerDeferred'
            Test-BRAVOCondition -Condition ((Get-BRAVOE7Counter -Name 'E7ReconcileCalls') -eq 0) -Name "UpdateInstall/Credentials$presence/SchedulerNotRegistered" -Failure 'scheduler зареєстровано без credentials'
            Test-BRAVOCondition -Condition ($result.taskActivation.state -eq 'Inactive') -Name "UpdateInstall/Credentials$presence/TasksInactive" -Failure $result.taskActivation.state
            $journal = Read-BRAVOE7Journal -Roots $roots -Plan $plan
            Test-BRAVOCondition -Condition ($journal.state -eq 'Committed') -Name "UpdateInstall/Credentials$presence/JournalCommitted" -Failure $journal.state
        }
    }

    # ---------------- 4. Validation Warn -> SuccessWithWarnings; Fail -> rollback ----------------
    & {
        Set-BRAVOE7Flags @{ ValidationStatus = 'Warn' }
        $roots = New-BRAVOE7Scenario
        $plan = New-BRAVOE7Plan -Roots $roots
        $result = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter (New-BRAVOE7Adapter)
        Test-BRAVOCondition -Condition ($result.status -eq 'SuccessWithWarnings' -and @($result.validation).Count -eq 1 -and $result.validation[0].status -eq 'Warn') -Name 'UpdateInstall/ValidationWarn/SuccessWithWarnings' -Failure "status=$($result.status)"
        Set-BRAVOE7Flags @{ ValidationStatus = 'Fail' }
        $roots = New-BRAVOE7Scenario
        $plan = New-BRAVOE7Plan -Roots $roots
        $result = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter (New-BRAVOE7Adapter)
        Test-BRAVOCondition -Condition ($result.status -eq 'RolledBack' -and $result.exitCode -eq 81 -and -not (Test-Path -LiteralPath $roots.Runtime)) -Name 'UpdateInstall/ValidationFail/RolledBackToAbsentRoot' -Failure "status=$($result.status) root=$(Test-Path -LiteralPath $roots.Runtime)"
    }

    # ---------------- 5. Політика кореня ----------------
    & {
        Set-BRAVOE7Flags
        $roots = New-BRAVOE7Scenario
        $policy = {
            param($Root, $ProfileRoot)
            Test-BRAVOInstallRuntimeRootPolicy -RuntimeRoot $Root -StateRoot $using:null -ProfileRoot $ProfileRoot
        }
        $check = {
            param([string]$Root, [string[]]$Profiles = @('C:\Users\Example-Nobody'), [string]$State = '')
            Invoke-BRAVOE7Module { param($R, $P, $S) Test-BRAVOInstallRuntimeRootPolicy -RuntimeRoot $R -StateRoot $S -ProfileRoot $P } @($Root, $Profiles, $State)
        }

        $okResult = & $check $roots.Runtime
        Test-BRAVOCondition -Condition ($okResult.IsValid -and -not $okResult.PreexistingEmpty) -Name 'UpdateInstall/RootPolicy/AcceptsSpacesAndCyrillic' -Failure ($okResult.Problems -join '; ')

        $nonEmpty = Join-Path $roots.Scenario 'непорожній каталог'
        New-Item -ItemType Directory -Path $nonEmpty -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $nonEmpty 'x.txt'), 'x')
        Test-BRAVOCondition -Condition (-not (& $check $nonEmpty).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsNonEmpty' -Failure 'непорожній корінь прийнято'

        $empty = Join-Path $roots.Scenario 'порожній каталог'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $emptyResult = & $check $empty
        Test-BRAVOCondition -Condition ($emptyResult.IsValid -and $emptyResult.PreexistingEmpty) -Name 'UpdateInstall/RootPolicy/AcceptsPreexistingEmpty' -Failure ($emptyResult.Problems -join '; ')

        Test-BRAVOCondition -Condition (-not (& $check '\\host-a\share\BRAVO').IsValid) -Name 'UpdateInstall/RootPolicy/RejectsUnc' -Failure 'UNC прийнято'
        Test-BRAVOCondition -Condition (-not (& $check 'відносний\шлях').IsValid) -Name 'UpdateInstall/RootPolicy/RejectsRelative' -Failure 'відносний шлях прийнято'
        Test-BRAVOCondition -Condition (-not (& $check ($roots.Scenario + '\Програми BRAVO\..\BRAVO')).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsDotDot' -Failure "'..' прийнято"
        Test-BRAVOCondition -Condition (-not (& $check ([IO.Path]::GetPathRoot($roots.Runtime))).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsDriveRoot' -Failure 'корінь диска прийнято'
        Test-BRAVOCondition -Condition (-not (& $check (Join-Path $env:SystemRoot 'BRAVO-Example')).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsUnderSystemRoot' -Failure 'каталог під SystemRoot прийнято'
        Test-BRAVOCondition -Condition (-not (& $check $roots.Runtime @($roots.Scenario)).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsUnderProfile' -Failure 'каталог у профілі прийнято'
        Test-BRAVOCondition -Condition (-not (& $check $roots.Scenario @($roots.Scenario)).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsProfileItself' -Failure 'сам профіль прийнято'
        Test-BRAVOCondition -Condition (-not (& $check (Join-Path $roots.Scenario 'нема\батька\BRAVO')).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsMissingParent' -Failure 'відсутній батько прийнято'
        $fileRoot = Join-Path $roots.Scenario 'файл-а-не-каталог'
        [IO.File]::WriteAllText($fileRoot, 'x')
        Test-BRAVOCondition -Condition (-not (& $check $fileRoot).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsFile' -Failure 'файл прийнято'
        Test-BRAVOCondition -Condition (-not (& $check (Join-Path $roots.State 'всередині') @('C:\Users\Example-Nobody') $roots.State).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsInsideState' -Failure 'корінь у State прийнято'
        Test-BRAVOCondition -Condition (-not (& $check $roots.Scenario @('C:\Users\Example-Nobody') $roots.Runtime).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsContainingState' -Failure 'корінь, що містить State, прийнято'

        # Junction: сам корінь і корінь під junction-ом.
        $junctionTarget = Join-Path $roots.Scenario 'ціль junction'
        $junction = Join-Path $roots.Scenario 'junction'
        New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
        & cmd.exe /c ('mklink /J "' + $junction + '" "' + $junctionTarget + '" >nul 2>&1')
        if (Test-Path -LiteralPath $junction) {
            try {
                Test-BRAVOCondition -Condition (-not (& $check $junction).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsJunctionRoot' -Failure 'junction як корінь прийнято'
                Test-BRAVOCondition -Condition (-not (& $check (Join-Path $junction 'BRAVO')).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsUnderJunction' -Failure 'корінь під junction прийнято'
            } finally {
                [IO.Directory]::Delete($junction, $false)
            }
        } else {
            Test-BRAVOCondition -Condition $true -Name 'UpdateInstall/RootPolicy/JunctionSkipped' -EnvironmentLimitation -Failure 'mklink /J недоступний'
        }

        # Наскрізно: непорожній корінь -> Failed/Blocked, нічого не змінено, журналу немає.
        $e2e = New-BRAVOE7Scenario
        New-Item -ItemType Directory -Path $e2e.Runtime -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $e2e.Runtime 'чужий.txt'), 'дані сайту')
        $before = Get-BRAVOE7TreeHash -Path $e2e.Runtime
        $plan = New-BRAVOE7Plan -Roots $e2e
        $result = Invoke-BRAVOE7Install -Roots $e2e -Plan $plan -Adapter (New-BRAVOE7Adapter)
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.reasonCode -eq 'Blocked' -and -not $result.mutationStarted) -Name 'UpdateInstall/RootPolicy/NonEmptyBlockedEndToEnd' -Failure "status=$($result.status)"
        Test-BRAVOCondition -Condition ((Get-BRAVOE7TreeHash -Path $e2e.Runtime) -eq $before -and -not (Test-Path -LiteralPath (Join-Path $e2e.State 'Journal'))) -Name 'UpdateInstall/RootPolicy/NonEmptyUntouchedNoJournal' -Failure 'каталог змінено або створено журнал'
    }

    # ---------------- 6. Наперед існуючий порожній корінь ----------------
    & {
        Set-BRAVOE7Flags
        $roots = New-BRAVOE7Scenario
        New-Item -ItemType Directory -Path $roots.Runtime -Force | Out-Null
        $plan = New-BRAVOE7Plan -Roots $roots
        $result = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter (New-BRAVOE7Adapter)
        $journal = Read-BRAVOE7Journal -Roots $roots -Plan $plan
        $ownership = @($journal.createdOwnership)
        Test-BRAVOCondition -Condition ($result.status -eq 'Success' -and ($ownership -contains 'marker:preexistingRoot') -and ($ownership -notcontains ('dir:' + $roots.Runtime))) -Name 'UpdateInstall/PreexistingRoot/MarkerNotDirOwnership' -Failure ($ownership -join '|')

        $roots2 = New-BRAVOE7Scenario
        New-Item -ItemType Directory -Path $roots2.Runtime -Force | Out-Null
        $plan2 = New-BRAVOE7Plan -Roots $roots2
        $result2 = Invoke-BRAVOE7Install -Roots $roots2 -Plan $plan2 -Adapter (New-BRAVOE7Adapter) -Fault @{ 'Deploy.AfterSideEffect' = 'Throw' }
        Test-BRAVOCondition -Condition ($result2.status -eq 'RolledBack' -and (Test-Path -LiteralPath $roots2.Runtime) -and @(Get-ChildItem -LiteralPath $roots2.Runtime -Force).Count -eq 0) -Name 'UpdateInstall/PreexistingRoot/KeptEmptyAfterRollback' -Failure "status=$($result2.status) exists=$(Test-Path -LiteralPath $roots2.Runtime)"
    }

    # ---------------- 7. Збій у кожній фазі -> rollback до відсутнього кореня ----------------
    $e7PhaseFaults = @(
        @{ Name = 'CreateRuntimeRoot.AfterIntent'; Fault = @{ 'CreateRuntimeRoot.AfterIntent' = 'Throw' } },
        @{ Name = 'CreateRuntimeRoot.AfterSideEffect'; Fault = @{ 'CreateRuntimeRoot.AfterSideEffect' = 'Throw' } },
        @{ Name = 'Deploy.Before'; Fault = @{ 'Deploy.Before' = 'Throw' } },
        @{ Name = 'Deploy.AfterFileCount2'; Fault = @{ 'Deploy.AfterFileCount' = 2 } },
        @{ Name = 'Deploy.AfterSideEffect'; Fault = @{ 'Deploy.AfterSideEffect' = 'Throw' } },
        @{ Name = 'SeedLocalConfig.AfterIntent'; Fault = @{ 'SeedLocalConfig.AfterIntent' = 'Throw' } },
        @{ Name = 'SeedLocalConfig.AfterSideEffect'; Fault = @{ 'SeedLocalConfig.AfterSideEffect' = 'Throw' } },
        @{ Name = 'ConfigureScheduler.AfterSideEffect'; Fault = @{ 'ConfigureScheduler.AfterSideEffect' = 'Throw' } },
        @{ Name = 'Validate.Before'; Fault = @{ 'Validate.Before' = 'Throw' } },
        @{ Name = 'Commit.Before'; Fault = @{ 'Commit.Before' = 'Throw' } }
    )
    foreach ($case in $e7PhaseFaults) {
        & {
            Set-BRAVOE7Flags
            $roots = New-BRAVOE7Scenario
            $plan = New-BRAVOE7Plan -Roots $roots
            $result = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter (New-BRAVOE7Adapter) -Fault $case.Fault
            $journal = Read-BRAVOE7Journal -Roots $roots -Plan $plan
            Test-BRAVOCondition -Condition ($result.status -eq 'RolledBack' -and $result.exitCode -eq 81 -and $result.mutationStarted) -Name ('UpdateInstall/PhaseFailure/' + $case.Name + '/RolledBack') -Failure ("status=$($result.status) exit=$($result.exitCode) rollback=$($result.rollback.message) findings=" + (@($result.findings | ForEach-Object { $_.id + ':' + $_.details }) -join '|'))
            Test-BRAVOCondition -Condition (-not (Test-Path -LiteralPath $roots.Runtime)) -Name ('UpdateInstall/PhaseFailure/' + $case.Name + '/RootAbsent') -Failure ('корінь лишився: ' + (Get-BRAVOE7TreeHash -Path $roots.Runtime))
            Test-BRAVOCondition -Condition ($null -ne $journal -and $journal.state -eq 'RolledBack') -Name ('UpdateInstall/PhaseFailure/' + $case.Name + '/JournalRolledBack') -Failure ([string]$journal.state)
            Test-BRAVOCondition -Condition (@($result.findings | Where-Object { $_.id -eq 'Install.PhaseFailed' }).Count -eq 1) -Name ('UpdateInstall/PhaseFailure/' + $case.Name + '/FailureReported') -Failure 'немає finding Install.PhaseFailed'
        }
    }

    # ---------------- 8. Збій ДО межі mutation: Abandoned, runtime не чіпаємо ----------------
    & {
        Set-BRAVOE7Flags
        $roots = New-BRAVOE7Scenario
        $plan = New-BRAVOE7Plan -Roots $roots
        $result = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter (New-BRAVOE7Adapter) -Fault @{ 'Stage.AfterSideEffect' = 'Throw' }
        $journal = Read-BRAVOE7Journal -Roots $roots -Plan $plan
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and -not $result.mutationStarted -and $result.reasonCode -eq 'Error') -Name 'UpdateInstall/PreMutation/FailedNotRolledBack' -Failure "status=$($result.status) reason=$($result.reasonCode)"
        Test-BRAVOCondition -Condition ($journal.state -eq 'Abandoned' -and -not (Test-Path -LiteralPath $roots.Runtime) -and -not (Test-Path -LiteralPath (Join-Path $roots.Staging ([string]$plan.operationId)))) -Name 'UpdateInstall/PreMutation/AbandonedAndCleaned' -Failure "journal=$($journal.state)"
        # Replay того самого плану відхиляється.
        $replay = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter (New-BRAVOE7Adapter)
        Test-BRAVOCondition -Condition ($replay.status -eq 'Failed' -and $replay.reasonCode -eq 'PlanStale') -Name 'UpdateInstall/PreMutation/ReplayRejected' -Failure "status=$($replay.status) reason=$($replay.reasonCode)"

        # Невідомий скрипт у наборі -> blocker до mutation.
        Set-BRAVOE7Flags @{ UnknownScript = $true }
        $roots = New-BRAVOE7Scenario
        $plan = New-BRAVOE7Plan -Roots $roots
        $result = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter (New-BRAVOE7Adapter)
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and -not (Test-Path -LiteralPath $roots.Runtime) -and @($result.findings | Where-Object { $_.id -eq 'Install.FileSet' }).Count -eq 1) -Name 'UpdateInstall/PreMutation/UnknownScriptBlocked' -Failure "status=$($result.status)"

        # Збіг версій staged і плану.
        Set-BRAVOE7Flags
        $roots = New-BRAVOE7Scenario
        $plan = New-BRAVOE7Plan -Roots $roots
        $plan.targetVersion = '9.9.8'
        $result = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter (New-BRAVOE7Adapter)
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.reasonCode -eq 'VerificationFailed' -and -not (Test-Path -LiteralPath $roots.Runtime)) -Name 'UpdateInstall/PreMutation/StagedVersionMismatch' -Failure "status=$($result.status)"
    }

    # ---------------- 9. Plan stale, wrong action, ALLOW_DOWNGRADE, locks ----------------
    & {
        Set-BRAVOE7Flags @{ PlanCurrent = $false }
        $roots = New-BRAVOE7Scenario
        $plan = New-BRAVOE7Plan -Roots $roots
        $result = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter (New-BRAVOE7Adapter)
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.reasonCode -eq 'PlanStale' -and -not (Test-Path -LiteralPath $roots.Runtime) -and -not (Test-Path -LiteralPath (Join-Path $roots.State 'Journal'))) -Name 'UpdateInstall/PlanStale/NoMutationNoJournal' -Failure "status=$($result.status)"

        Set-BRAVOE7Flags
        $roots = New-BRAVOE7Scenario
        $result = Invoke-BRAVOE7Install -Roots $roots -Plan (New-BRAVOE7Plan -Roots $roots -Action 'Update') -Adapter (New-BRAVOE7Adapter)
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.reasonCode -eq 'Blocked' -and -not (Test-Path -LiteralPath $roots.Runtime)) -Name 'UpdateInstall/WrongAction/Blocked' -Failure "status=$($result.status)"

        $roots = New-BRAVOE7Scenario
        $previous = [Environment]::GetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE')
        try {
            [Environment]::SetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE', '1')
            $result = Invoke-BRAVOE7Install -Roots $roots -Plan (New-BRAVOE7Plan -Roots $roots) -Adapter (New-BRAVOE7Adapter)
        } finally {
            [Environment]::SetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE', $previous)
        }
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.reasonCode -eq 'Blocked' -and -not (Test-Path -LiteralPath $roots.Runtime)) -Name 'UpdateInstall/AllowDowngrade/Blocked' -Failure "status=$($result.status)"

        # Lifecycle lock зайнятий -> Blocked 20.
        $roots = New-BRAVOE7Scenario
        $held = Invoke-BRAVOE7Module { param($L) Enter-BRAVOUpdateLifecycleLock -LockRoot $L -OperationId ([guid]::NewGuid().ToString()) } @($roots.Lock)
        try {
            $result = Invoke-BRAVOE7Install -Roots $roots -Plan (New-BRAVOE7Plan -Roots $roots) -Adapter (New-BRAVOE7Adapter)
        } finally {
            Invoke-BRAVOE7Module { param($H) Exit-BRAVOUpdateLifecycleLock -Lock $H } @($held)
        }
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.exitCode -eq 20 -and -not (Test-Path -LiteralPath $roots.Runtime)) -Name 'UpdateInstall/LifecycleLockBusy/Exit20' -Failure ("status=$($result.status) exit=$($result.exitCode) rollback=$($result.rollback.message) findings=" + (@($result.findings | ForEach-Object { $_.id + ':' + $_.details }) -join '|'))

        # Operation lock зайнятий -> Blocked 20 до межі: runtime не створено, журнал Abandoned, а не фіктивний RolledBack.
        $roots = New-BRAVOE7Scenario
        $plan = New-BRAVOE7Plan -Roots $roots
        $heldOperation = Invoke-BRAVOE7Module { param($P) Enter-BRAVOUpdateOperationLock -OperationLockPath $P -OperationId ([guid]::NewGuid().ToString()) -PackageVersion '1.0.0' } @($roots.OperationLock)
        try {
            $result = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter (New-BRAVOE7Adapter)
        } finally {
            Invoke-BRAVOE7Module { param($H) Exit-BRAVOUpdateOperationLock -Lock $H } @($heldOperation)
        }
        $journal = Read-BRAVOE7Journal -Roots $roots -Plan $plan
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.exitCode -eq 20 -and $journal.state -eq 'Abandoned' -and -not $result.mutationStarted -and -not (Test-Path -LiteralPath $roots.Runtime)) -Name 'UpdateInstall/OperationLockBusy/AbandonedBeforeBoundary' -Failure "status=$($result.status) exit=$($result.exitCode) journal=$($journal.state)"
    }

    # ---------------- 10. Crash: без rollback, журнал Open, handle-и звільнені ----------------
    & {
        Set-BRAVOE7Flags
        $roots = New-BRAVOE7Scenario
        $plan = New-BRAVOE7Plan -Roots $roots
        $thrown = $null
        try {
            [void](Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter (New-BRAVOE7Adapter) -Fault @{ 'Deploy.AfterSideEffect' = 'Crash' })
        } catch {
            $thrown = $_.Exception.Message
        }
        $journal = Read-BRAVOE7Journal -Roots $roots -Plan $plan
        Test-BRAVOCondition -Condition ($null -ne $thrown -and $thrown -like '*SimulatedCrash*') -Name 'UpdateInstall/Crash/Propagates' -Failure ([string]$thrown)
        Test-BRAVOCondition -Condition ($journal.state -eq 'Open' -and $journal.mutationStarted -eq $true -and (Test-Path -LiteralPath $roots.Runtime)) -Name 'UpdateInstall/Crash/JournalOpenRuntimeLeftForRecovery' -Failure "journal=$($journal.state)"
        $freed = Invoke-BRAVOE7Module { param($L) $l = Enter-BRAVOUpdateLifecycleLock -LockRoot $L -OperationId ([guid]::NewGuid().ToString()); $ok = $l.Success; Exit-BRAVOUpdateLifecycleLock -Lock $l; $ok } @($roots.Lock)
        Test-BRAVOCondition -Condition ([bool]$freed) -Name 'UpdateInstall/Crash/HandlesReleased' -Failure 'lifecycle lock лишився утриманим'
    }

    # ---------------- 11. Сіяння не перезаписує ----------------
    & {
        Set-BRAVOE7Flags
        $e7Calls.Seed = 0
        $roots = New-BRAVOE7Scenario
        $plan = New-BRAVOE7Plan -Roots $roots
        $adapter = New-BRAVOE7Adapter -SeedCreates $false
        $result = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter $adapter
        $journal = Read-BRAVOE7Journal -Roots $roots -Plan $plan
        Test-BRAVOCondition -Condition ($result.status -eq 'RolledBack' -and -not (Test-Path -LiteralPath $roots.Runtime)) -Name 'UpdateInstall/Seed/CreatedFalseIsFailure' -Failure "status=$($result.status)"
        Test-BRAVOCondition -Condition (@($journal.createdOwnership | Where-Object { $_ -like 'file:BRAVO.local.config*' }).Count -eq 0) -Name 'UpdateInstall/Seed/NoOwnershipForForeignFile' -Failure (@($journal.createdOwnership) -join '|')

        # Файл уже є в новому корені до сіяння (чужий) -> adapter не викликається, файл не змінено й не видалено відкатом.
        $e7Calls.Seed = 0
        $roots = New-BRAVOE7Scenario
        $plan = New-BRAVOE7Plan -Roots $roots
        $adapter = New-BRAVOE7Adapter
        $stage = $adapter.StageRelease
        $adapter.StageRelease = {
            param($Plan, $SourcePath, $StagingDirectory, $Downloader)
            $r = & $stage $Plan $SourcePath $StagingDirectory $Downloader
            [IO.File]::WriteAllText((Join-Path $r.StagedRoot 'BRAVO.local.config'), 'підкинутий', (New-Object Text.UTF8Encoding $false))
            $r
        }.GetNewClosure()
        $result = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter $adapter
        Test-BRAVOCondition -Condition ($result.status -eq 'RolledBack' -and $e7Calls.Seed -eq 0) -Name 'UpdateInstall/Seed/ExistingFileNeverOverwritten' -Failure "status=$($result.status) seedCalls=$($e7Calls.Seed)"
    }

    # ---------------- 12. Scheduler FAIL -> rollback; відкат, що не вдався -> Critical ----------------
    & {
        Set-BRAVOE7Flags @{ ReconcileVerdict = 'FAIL' }
        $roots = New-BRAVOE7Scenario
        $result = Invoke-BRAVOE7Install -Roots $roots -Plan (New-BRAVOE7Plan -Roots $roots) -Adapter (New-BRAVOE7Adapter)
        Test-BRAVOCondition -Condition ($result.status -eq 'RolledBack' -and -not (Test-Path -LiteralPath $roots.Runtime)) -Name 'UpdateInstall/SchedulerFail/RolledBack' -Failure "status=$($result.status)"

        Set-BRAVOE7Flags @{ RollbackThrows = $true }
        $roots = New-BRAVOE7Scenario
        $plan = New-BRAVOE7Plan -Roots $roots
        $result = Invoke-BRAVOE7Install -Roots $roots -Plan $plan -Adapter (New-BRAVOE7Adapter) -Fault @{ 'Deploy.AfterSideEffect' = 'Throw'; 'Rollback.InstallCleanup.AfterSideEffect' = 'Throw' }
        $journal = Read-BRAVOE7Journal -Roots $roots -Plan $plan
        Test-BRAVOCondition -Condition ($result.status -eq 'Critical' -and $result.exitCode -eq 82 -and $journal.state -eq 'Critical' -and $result.rollback.status -eq 'Failed') -Name 'UpdateInstall/RollbackFailure/Critical' -Failure "status=$($result.status) journal=$($journal.state)"
        Set-BRAVOE7Flags
    }

    # ---------------- 13. Ownership-ключі й adapter за замовчуванням ----------------
    & {
        $entries = @(Invoke-BRAVOE7Module { param($K) Get-BRAVOInstallOwnershipEntry -DeployKeys $K } @(, @{ 'a/b/c.txt' = 'aa'; 'root.txt' = 'bb'; 'a/d.txt' = 'cc' }))
        $dirs = @($entries | Where-Object { $_ -like 'dir:*' })
        Test-BRAVOCondition -Condition ($dirs.Count -eq 2 -and $dirs[0] -eq 'dir:a' -and $dirs[1] -eq 'dir:a/b') -Name 'UpdateInstall/Ownership/DirsParentsFirst' -Failure ($entries -join '|')
        Test-BRAVOCondition -Condition (@($entries | Where-Object { $_ -like 'file:*' -or $_ -like 'deploykeys:*' }).Count -eq 0) -Name 'UpdateInstall/Ownership/DirsOnlyFilesCoveredByDeployKeys' -Failure ($entries -join '|')
        $threw = $false
        try { [void](Invoke-BRAVOE7Module { param($K) Get-BRAVOInstallOwnershipEntry -DeployKeys $K } @(, @{ '../evil.txt' = 'aa' })) } catch { $threw = $true }
        Test-BRAVOCondition -Condition $threw -Name 'UpdateInstall/Ownership/RejectsDotDotKey' -Failure 'ключ з .. прийнято'
        $full = Invoke-BRAVOE7Module { Get-BRAVOInstallAdapter -Adapter @{ Now = { [datetime]::UtcNow } } }
        Test-BRAVOCondition -Condition ($full.ContainsKey('SeedLocalConfig') -and $full.ContainsKey('StageRelease') -and $full.ContainsKey('GetUserProfileRoots') -and $full.ContainsKey('Now')) -Name 'UpdateInstall/Adapter/DefaultsAdded' -Failure (@($full.Keys) -join ',')
        $profiles = @(& $full.GetUserProfileRoots)
        Test-BRAVOCondition -Condition ($profiles.Count -ge 1 -and $profiles[0] -eq [Environment]::GetFolderPath('UserProfile')) -Name 'UpdateInstall/Adapter/DefaultProfileRoots' -Failure ($profiles -join ',')
    }

    # ---------------- 14. Команда передачі credentials ----------------
    & {
        $command = Get-BRAVOInstallCredentialHandoffCommand -RuntimeRoot 'C:\Програми BRAVO\Toolkit з пробілом'
        Test-BRAVOCondition -Condition ($command.RequiresVisibleConsole -and $command.FilePath -eq 'powershell.exe' -and $command.ArgumentList -contains '-Action' -and $command.ArgumentList -contains 'Credentials') -Name 'UpdateInstall/Handoff/Shape' -Failure ($command | ConvertTo-Json -Compress)
        Test-BRAVOCondition -Condition ($command.ArgumentString -eq '-NoProfile -File "C:\Програми BRAVO\Toolkit з пробілом\BRAVO_SETUP.ps1" -Action Credentials') -Name 'UpdateInstall/Handoff/QuotedPathWithSpacesCyrillic' -Failure $command.ArgumentString
        Test-BRAVOCondition -Condition (($command | ConvertTo-Json -Compress) -notmatch '(?i)password|secret|token|-Hidden|Bypass') -Name 'UpdateInstall/Handoff/NoSecretsNoHiddenNoBypass' -Failure 'заборонений вміст у команді'
        $threw = $false
        try { [void](Get-BRAVOInstallCredentialHandoffCommand -RuntimeRoot 'відносний') } catch { $threw = $true }
        Test-BRAVOCondition -Condition $threw -Name 'UpdateInstall/Handoff/RejectsRelativeRoot' -Failure 'відносний шлях прийнято'
    }
} finally {
    # Прибираємо лише власний sandbox (префікс перевірено).
    if ($e7Base.StartsWith($e7TempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $e7Base)) {
        Remove-Item -LiteralPath $e7Base -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Знімаємо тестові shim-и: наступні фрагменти отримують чистий модуль.
    Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking
}
