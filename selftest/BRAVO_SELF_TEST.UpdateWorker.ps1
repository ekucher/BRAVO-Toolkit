# ============================================================
# UpdateWorker: worker-протокол і диспетчер CLI Installer v1 (INS-041)
# ============================================================
# Перевіряється реальний модуль BRAVO.Update (частина Worker) у sandbox-каталогах
# із пробілами й кирилицею. Оркестратори (Install/Update/Repair/Recover) —
# stub-и через seam -Operations, адаптер — stub; елевація, Task Scheduler,
# credentials і реальні mutation не виконуються. Тест не запускає
# BRAVO_UPDATE.ps1.

& {
    $wkModule = $null
    $wkRoot = $null
    $wkPrefix = Join-Path ([IO.Path]::GetTempPath()) 'BRAVO_UPD_e8 тест '
    $wkJunction = $null
    $wkValidatorOriginal = $null
    try {
        Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking
        $wkModule = Get-Module BRAVO.Update

        # --- TEST SHIM: Plan.ps1 (чужа частина) викликає валідатор як -Plan, а він
        # приймає -InputObject (Codex P1 #1). Доки Plan.ps1 не виправлено,
        # на час тесту валідатор отримує alias Plan; після виправлення shim
        # не вмикається. Production-файли тут не змінюються.
        $wkValidatorOriginal = $null
        $planSource = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.Plan.ps1'))
        if ($planSource.Contains('& $validator -Plan $plan')) {
            $wkValidatorOriginal = & $wkModule { (Get-Item Function:\Test-BRAVOUpdateDeploymentPlan).ScriptBlock }
            & $wkModule {
                param($Original)
                Set-Item -Path Function:\Test-BRAVOUpdateDeploymentPlan -Value ({ param([Parameter(Position = 0)][Alias('Plan')]$InputObject) & $Original -InputObject $InputObject }.GetNewClosure())
            } $wkValidatorOriginal
        }

        $wkRoot = $wkPrefix + [guid]::NewGuid().ToString('N')
        $runtime = Join-Path $wkRoot 'Сервер\runtime'
        $staged = Join-Path $wkRoot 'staged'
        $paths = [pscustomobject]@{
            StateRoot = (Join-Path $wkRoot 'state'); LockRoot = (Join-Path $wkRoot 'locks'); StagingRoot = (Join-Path $wkRoot 'staging')
            BackupRoot = (Join-Path $wkRoot 'backup'); RuntimeRoot = $runtime
            OperationLockPath = (Join-Path $wkRoot 'locks\BRAVO_OPERATION.lock'); VersionStatePath = (Join-Path $wkRoot 'state\version.json')
        }
        # LockRoot не створюється звичайним New-Item: спільний каталог лише ВАЛІДУЄТЬСЯ (Container), відсутній — створює Initialize.
        foreach ($dir in @($runtime, $staged, $paths.StagingRoot, $paths.BackupRoot)) { [void](New-Item -ItemType Directory -Path $dir -Force) }

        $writeTree = {
            param([string]$Path, [hashtable]$Files)
            $entries = [ordered]@{}
            foreach ($relative in @($Files.Keys)) {
                $full = Join-Path $Path ($relative -replace '/', '\')
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force)
                [IO.File]::WriteAllText($full, [string]$Files[$relative], (New-Object Text.UTF8Encoding $false))
                $entries[$relative] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToUpperInvariant()
            }
            [IO.File]::WriteAllText((Join-Path $Path 'RUNTIME_MANIFEST.json'), ([pscustomobject]@{ files = [pscustomobject]$entries } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
        }
        & $writeTree $runtime @{ 'a.txt' = 'однаковий'; 'b.txt' = 'старий'; 'VERSION.json' = '{"packageVersion": "5.2.6", "releaseChannel": "stable"}' }
        & $writeTree $staged @{ 'a.txt' = 'однаковий'; 'b.txt' = 'новий'; 'd.txt' = 'додано'; 'VERSION.json' = '{"packageVersion": "5.3.0", "releaseChannel": "stable"}' }

        $envOk = { [pscustomobject]@{ OsTier = 'Supported'; OsDescription = 'Example OS'; PowerShellVersion = [version]'5.1.20348.0'; PowerShellEdition = 'Desktop'; DotNetRelease = 528372; Is64BitOS = $true; IsAdministrator = $true } }
        $adapter = @{ GetPreflightEnvironment = $envOk; GetManagedTasks = { @() } }
        $source = [pscustomobject]@{
            kind = 'Offline'; tag = 'v5.3.0'; artifactName = 'BRAVO-Toolkit-5.3.0.zip'; artifactSha256 = ('A' * 64); manifestSha256 = ('B' * 64)
            packageVersion = '5.3.0'; releaseChannel = 'stable'; prereleaseAuthorized = $false
        }
        $call = { param([string]$Name, [hashtable]$Params) & $wkModule { param($n, $p) & $n @p } $Name $Params }
        $newPlan = {
            $preflight = [pscustomobject]@{ findings = @(); canProceed = $true; blockerCount = 0; warningCount = 0 }
            & $call 'New-BRAVODeploymentPlan' @{
                Action = 'Update'; RuntimeRoot = $runtime; StagingRoot = $paths.StagingRoot; BackupRoot = $paths.BackupRoot; StateRoot = $paths.StateRoot
                Source = $source; StagedRoot = $staged; Preflight = $preflight; Adapter = $adapter
            }
        }
        $init = & $call 'Initialize-BRAVOUpdateStateDirectories' @{ StateRoot = $paths.StateRoot }
        Test-BRAVOCondition -Condition ($init.Success -and (Test-Path -LiteralPath (Join-Path $paths.StateRoot 'Requests')) -and (Test-Path -LiteralPath (Join-Path $paths.StateRoot 'ConsumedPlans'))) `
            -Name 'UpdateWorker/InitializeStateDirectories' -Failure ('каталоги протоколу не створено: ' + ($init.Problems -join '; '))

        # Лічильник викликів stub-оркестраторів і самі stub-и (прив'язані до області модуля).
        $calls = @{ Update = 0; Install = 0; Repair = 0; Recover = 0; Last = $null }
        $makeOperation = & $wkModule {
            {
                param($Calls, [string]$Name, [string]$Mode)
                {
                param($Plan, $Adapter, $RuntimeRoot, $StateRoot, $LockRoot, $StagingRoot, $BackupRoot, $OperationLockPath, $VersionStatePath, $BackupDestination, $Scope, $SourcePath)
                $Calls[$Name]++
                $Calls.Last = @{ RuntimeRoot = $RuntimeRoot; StagingRoot = $StagingRoot; BackupDestination = $BackupDestination; Scope = $Scope; SourcePath = $SourcePath }
                if ($Mode -eq 'Throw') { throw 'імітований збій оркестратора' }
                New-BRAVOUpdateDeploymentResult -OperationId $Plan.operationId -PlanId $Plan.planId -Action $Plan.action -Status Success -SourceVersion '5.2.6' -TargetVersion '5.3.0' -InstalledVersion '5.3.0'
                }.GetNewClosure()
            }
        }
        $ops = @{ Update = (& $makeOperation $calls 'Update' 'Ok'); Install = (& $makeOperation $calls 'Install' 'Ok'); Repair = (& $makeOperation $calls 'Repair' 'Ok') }
        $opsThrow = @{ Update = (& $makeOperation $calls 'Update' 'Throw') }
        $recoverOp = & $wkModule {
            param($Calls)
            {
                param($StateRoot, $LockRoot, $OperationLockPath, $Adapter, $VersionStatePath)
                $Calls.Recover++
                New-BRAVOUpdateDeploymentResult -OperationId ([guid]::NewGuid().ToString()) -Action Recovery -Status Success
            }.GetNewClosure()
        } $calls

        $treeSnapshot = {
            param([string]$Dir)
            $lines = foreach ($item in (Get-ChildItem -LiteralPath $Dir -Recurse -Force | Sort-Object FullName)) {
                $hash = ''
                if (-not $item.PSIsContainer) { $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }
                $item.FullName + '|' + $hash
            }
            return (@($lines) -join "`n")
        }
        $writeRequest = {
            param($Plan, [scriptblock]$Mutate, [string]$Dir = '', [string]$Name = '')
            $request = & $call 'New-BRAVOUpdateRequest' @{ Plan = $Plan; ConfirmedPlanShortId = $Plan.planId.Substring(0, 8); Option = @{ backupDestination = 'LocalOnly'; scope = 'All' } }
            $copy = ($request | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
            if ($null -ne $Mutate) { & $Mutate $copy }
            if ([string]::IsNullOrEmpty($Dir)) { $Dir = Join-Path $paths.StateRoot 'Requests' }
            if ([string]::IsNullOrEmpty($Name)) { $Name = [guid]::NewGuid().ToString() + '.json' }
            $path = Join-Path $Dir $Name
            [IO.File]::WriteAllText($path, ($copy | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding $false))
            return $path
        }
        $runWorker = {
            param([string]$RequestPath, $UsePaths = $paths, $Admin = $true, $Operations = $ops, $Now = $null)
            $arguments = @{ RequestPath = $RequestPath; Adapter = $adapter; Paths = $UsePaths; CandidateRoots = @($runtime); Operations = $Operations; IsAdministrator = $Admin }
            if ($null -ne $Now) { $arguments['Now'] = $Now }
            & $call 'Invoke-BRAVOUpdateWorker' $arguments
        }
        $findingIds = { param($Result) @(@($Result.Result.findings) | ForEach-Object { $_.id }) }

        # --- New-BRAVOUpdateRequest ---
        & {
            $plan = & $newPlan
            $request = & $call 'New-BRAVOUpdateRequest' @{ Plan = $plan; ConfirmedPlanShortId = $plan.planId.Substring(0, 8).ToUpperInvariant() }
            Test-BRAVOCondition -Condition ($request.confirmedPlanShortId -ceq $plan.planId.Substring(0, 8) -and $request.schemaVersion -eq 1 -and $request.planId -ceq $plan.planId) `
                -Name 'UpdateWorker/RequestShape' -Failure 'форма запиту (короткий id = перші 8 hex planId)'
            $wrong = $null
            try { [void](& $call 'New-BRAVOUpdateRequest' @{ Plan = $plan; ConfirmedPlanShortId = '00000000' }) } catch { $wrong = $_.Exception.Message }
            Test-BRAVOCondition -Condition ($null -ne $wrong) -Name 'UpdateWorker/RequestRejectsWrongShortId' -Failure 'хибний короткий id мав кинути'
            $secret = $null
            try { [void](& $call 'New-BRAVOUpdateRequest' @{ Plan = $plan; ConfirmedPlanShortId = $plan.planId.Substring(0, 8); Option = @{ apiToken = 'x' } }) } catch { $secret = $_.Exception.Message }
            Test-BRAVOCondition -Condition ($null -ne $secret) -Name 'UpdateWorker/RequestRejectsSecretOption' -Failure 'секретне поле в options мало відхилитись'
        }

        # --- Права: без них нічого не пишемо ---
        & {
            $plan = & $newPlan
            $path = & $writeRequest $plan $null
            $before = & $treeSnapshot $paths.StateRoot
            $runtimeBefore = & $treeSnapshot $runtime
            $result = & $runWorker $path $paths $false
            Test-BRAVOCondition -Condition ($result.ExitCode -eq 36 -and (& $findingIds $result) -contains 'Worker.PrivilegeRequired') -Name 'UpdateWorker/NonAdminExit36' -Failure ('очікувався 36, отримано ' + $result.ExitCode)
            Test-BRAVOCondition -Condition ($before -ceq (& $treeSnapshot $paths.StateRoot) -and $runtimeBefore -ceq (& $treeSnapshot $runtime) -and $null -eq $result.ResultPath) `
                -Name 'UpdateWorker/NonAdminNoWrites' -Failure 'відмова без прав не повинна нічого писати'
            $cli = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'Execute'; RequestPath = $path; Paths = $paths; Adapter = $adapter; IsAdministrator = $false; Operations = $ops; CandidateRoots = @($runtime) }
            Test-BRAVOCondition -Condition ($cli.ExitCode -eq 36 -and $before -ceq (& $treeSnapshot $paths.StateRoot)) -Name 'UpdateWorker/CliExecuteNonAdmin36' -Failure 'CLI Execute без прав має дати 36 без записів'
        }

        # --- Тамперинг запиту: жодного виклику оркестратора, runtime незмінний ---
        & {
            $runtimeBefore = & $treeSnapshot $runtime
            $callsBefore = $calls.Update
            $check = {
                param([string]$Name, [string]$ExpectedId, $Result, [int]$ExpectedExit = 80)
                Test-BRAVOCondition -Condition ($Result.ExitCode -eq $ExpectedExit -and ((& $findingIds $Result) -contains $ExpectedId)) -Name ('UpdateWorker/' + $Name) `
                    -Failure ('очікувався ' + $ExpectedId + ' / ' + $ExpectedExit + ', отримано ' + $Result.ExitCode + ' [' + ((& $findingIds $Result) -join ',') + ']')
            }

            $plan = & $newPlan
            $foreign = Join-Path $wkRoot 'чужий runtime'
            [void](New-Item -ItemType Directory -Path $foreign -Force)
            $path = & $writeRequest $plan { param($r) $r.plan.runtimeRoot = $foreign }
            & $check 'TamperForeignRuntimeRoot' 'Worker.ForeignRoot' (& $runWorker $path)

            $plan = & $newPlan
            $path = & $writeRequest $plan { param($r) $r.plan.stagingRoot = (Join-Path $wkRoot 'інший staging') }
            & $check 'TamperStagingRoot' 'Worker.ForeignRoot' (& $runWorker $path)

            $plan = & $newPlan
            $path = & $writeRequest $plan { param($r) $r.plan.runtimeRoot = $paths.StagingRoot }
            & $check 'TamperRuntimeIsStagingRoot' 'Worker.ForeignRoot' (& $runWorker $path)

            $plan = & $newPlan
            $path = & $writeRequest $plan { param($r) $r.plan.backupRoot = $runtime }
            & $check 'TamperBackupRoot' 'Worker.ForeignRoot' (& $runWorker $path)

            $plan = & $newPlan
            $path = & $writeRequest $plan { param($r) $r.options | Add-Member -NotePropertyName apiKey -NotePropertyValue 'x' }
            & $check 'TamperSecretOption' 'Worker.RequestSchema' (& $runWorker $path)

            $plan = & $newPlan
            $path = & $writeRequest $plan { param($r) $r.plan.source | Add-Member -NotePropertyName password -NotePropertyValue 'x' }
            & $check 'TamperSecretInPlan' 'Worker.RequestSchema' (& $runWorker $path)

            $plan = & $newPlan
            $path = & $writeRequest $plan { param($r) $r.confirmedPlanShortId = 'deadbeef' }
            & $check 'TamperWrongShortId' 'Worker.RequestSchema' (& $runWorker $path)

            $plan = & $newPlan
            $path = & $writeRequest $plan { param($r) $r.planId = [guid]::NewGuid().ToString() }
            & $check 'TamperPlanIdMismatch' 'Worker.RequestSchema' (& $runWorker $path)

            $plan = & $newPlan
            $path = & $writeRequest $plan { param($r) $r.options.backupDestination = 'Anywhere' }
            & $check 'TamperBadBackupDestination' 'Worker.RequestSchema' (& $runWorker $path)

            $plan = & $newPlan
            $path = & $writeRequest $plan $null
            [IO.File]::WriteAllText($path, ('{"x": "' + ('я' * 600000) + '"}'), (New-Object Text.UTF8Encoding $false))
            & $check 'TamperOversizedRequest' 'Worker.RequestSize' (& $runWorker $path)

            $path = Join-Path (Join-Path $paths.StateRoot 'Requests') ([guid]::NewGuid().ToString() + '.json')
            [IO.File]::WriteAllText($path, '{ не json', (New-Object Text.UTF8Encoding $false))
            & $check 'TamperCorruptJson' 'Worker.RequestJson' (& $runWorker $path)

            $plan = & $newPlan
            $otherDir = Join-Path $wkRoot 'не Requests'
            [void](New-Item -ItemType Directory -Path $otherDir -Force)
            $path = & $writeRequest $plan $null $otherDir
            & $check 'TamperRequestOutsideRequests' 'Worker.RequestPath' (& $runWorker $path)

            $path = & $writeRequest $plan $null '' 'request.json'
            & $check 'TamperRequestBadLeaf' 'Worker.RequestPath' (& $runWorker $path)

            & $check 'RequestMissing' 'Worker.RequestMissing' (& $runWorker (Join-Path (Join-Path $paths.StateRoot 'Requests') ([guid]::NewGuid().ToString() + '.json')))

            # Reparse: Requests другого StateRoot — junction на справжній Requests.
            $plan = & $newPlan
            $path = & $writeRequest $plan $null
            $state2 = Join-Path $wkRoot 'state2'
            [void](New-Item -ItemType Directory -Path $state2 -Force)
            $wkJunction = Join-Path $state2 'Requests'
            $null = & cmd.exe /c ('mklink /J "' + $wkJunction + '" "' + (Join-Path $paths.StateRoot 'Requests') + '"')
            if (Test-Path -LiteralPath $wkJunction) {
                $paths2 = $paths.PSObject.Copy()
                $paths2.StateRoot = $state2
                $viaJunction = Join-Path $wkJunction ([IO.Path]::GetFileName($path))
                # H1: junction на місці Requests тепер відсікається ще раніше — перевіркою коренів engine (до читання запиту).
                & $check 'TamperReparseRequestPath' 'State.RootUnsafe' (& $runWorker $viaJunction $paths2)
            } else {
                Test-BRAVOCondition -Condition $true -EnvironmentLimitation -Name 'UpdateWorker/TamperReparseRequestPath' -Failure 'junction не створено'
            }

            $plan = & $newPlan
            $path = & $writeRequest $plan $null
            & $check 'ExpiredPlan' 'Worker.PlanStale' (& $runWorker $path $paths $true $ops ([datetime]::UtcNow.AddHours(3)))

            $plan = & $newPlan
            $path = & $writeRequest $plan $null
            [void](New-Item -ItemType File -Path (Join-Path (Join-Path $paths.StateRoot 'ConsumedPlans') $plan.planId) -Force)
            & $check 'ReplayConsumedPlan' 'Worker.PlanReplay' (& $runWorker $path)

            $plan = & $newPlan
            $path = & $writeRequest $plan $null
            $previous = [Environment]::GetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE')
            [Environment]::SetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE', '1')
            try { $downgrade = & $runWorker $path } finally { [Environment]::SetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE', $previous) }
            & $check 'DowngradeOverrideRefused' 'Worker.DowngradeOverride' $downgrade 35

            Test-BRAVOCondition -Condition ($calls.Update -eq $callsBefore) -Name 'UpdateWorker/TamperNeverReachesOrchestrator' -Failure 'оркестратор не мав викликатись при жодному тамперингу'
            Test-BRAVOCondition -Condition ($runtimeBefore -ceq (& $treeSnapshot $runtime)) -Name 'UpdateWorker/TamperRuntimeUnchanged' -Failure 'runtime змінився'
        }

        # --- Успішний шлях, ACL, replay, збій оркестратора ---
        & {
            $plan = & $newPlan
            $path = & $writeRequest $plan $null
            $result = & $runWorker $path
            $opDir = Join-Path (Join-Path $paths.StateRoot 'Operations') $plan.operationId
            Test-BRAVOCondition -Condition ($result.ExitCode -eq 0 -and $calls.Update -ge 1 -and $result.Result.status -eq 'Success') -Name 'UpdateWorker/HappyPathDispatchesUpdate' `
                -Failure ('код ' + $result.ExitCode + ' [' + ((& $findingIds $result) -join ',') + ']')
            Test-BRAVOCondition -Condition ($calls.Last.RuntimeRoot -ceq $runtime -and $calls.Last.StagingRoot -ceq $paths.StagingRoot) -Name 'UpdateWorker/DispatchUsesTrustedRoots' -Failure 'корені для оркестратора'
            Test-BRAVOCondition -Condition ((Test-Path -LiteralPath (Join-Path $opDir 'result.json')) -and (Test-Path -LiteralPath (Join-Path $opDir 'request.json')) -and (Test-Path -LiteralPath (Join-Path $opDir 'control'))) `
                -Name 'UpdateWorker/OperationDirectoryArtifacts' -Failure 'result.json/request.json/control мають існувати'
            $stored = & $call 'Read-BRAVOUpdateContractFile' @{ Path = (Join-Path $opDir 'result.json'); Kind = 'DeploymentResult' }
            Test-BRAVOCondition -Condition ($stored.IsValid) -Name 'UpdateWorker/ResultJsonValid' -Failure ($stored.Problems -join '; ')

            $users = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
            $rules = @((Get-Acl -LiteralPath $opDir).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
            $usersRule = @($rules | Where-Object { $_.IdentityReference.Value -eq $users.Value })
            $writeBits = [System.Security.AccessControl.FileSystemRights]::WriteData -bor [System.Security.AccessControl.FileSystemRights]::AppendData
            Test-BRAVOCondition -Condition ($usersRule.Count -eq 1 -and (($usersRule[0].FileSystemRights -band $writeBits) -eq 0) -and (($usersRule[0].FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::ReadData) -ne 0)) `
                -Name 'UpdateWorker/OperationAclUsersReadOnly' -Failure 'Users мають лише читання каталогу операції'
            $controlRules = @((Get-Acl -LiteralPath (Join-Path $opDir 'control')).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
            $launcherSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $launcherRule = @($controlRules | Where-Object { $_.IdentityReference.Value -eq $launcherSid -and (($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::CreateFiles) -ne 0) })
            Test-BRAVOCondition -Condition ($launcherRule.Count -ge 1) -Name 'UpdateWorker/ControlAclLauncherCreateFiles' -Failure 'SID запускача мусить мати CreateFiles на control\'

            $replay = & $runWorker $path
            Test-BRAVOCondition -Condition ($replay.ExitCode -eq 80 -and $replay.Result.reasonCode -eq 'PlanStale' -and (& $findingIds $replay) -contains 'Worker.PlanReplay' -and $calls.Update -eq 1) `
                -Name 'UpdateWorker/ReplayRefused' -Failure 'повторний запуск того самого плану мав бути відхилений'

            $plan = & $newPlan
            $path = & $writeRequest $plan $null
            $thrown = & $runWorker $path $paths $true $opsThrow
            Test-BRAVOCondition -Condition ($thrown.ExitCode -eq 80 -and $thrown.Result.reasonCode -eq 'Error' -and (& $findingIds $thrown) -contains 'Worker.DispatchFailed' -and
                (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $paths.StateRoot 'Operations') $plan.operationId) 'result.json'))) `
                -Name 'UpdateWorker/DispatchFailureReported' -Failure 'збій оркестратора мав стати Failed/Error з result.json'
        }

        # --- CLI диспетчер: read-only дії ---
        & {
            $before = & $treeSnapshot $paths.StateRoot
            $base = @{ Paths = $paths; Adapter = $adapter; IsAdministrator = $false; CandidateRoots = @($runtime); Operations = $ops }
            $stateRun = @(& $call 'Invoke-BRAVOUpdateCliAction' ($base + @{ Action = 'State' }))
            Test-BRAVOCondition -Condition ($stateRun.Count -eq 1 -and $stateRun[0].ExitCode -eq 0 -and $stateRun[0].Result.schemaVersion -eq 1 -and -not [string]::IsNullOrEmpty([string]$stateRun[0].Result.state)) `
                -Name 'UpdateWorker/CliState' -Failure 'State: один результат, код 0, InstallationState'
            $json = & $call 'ConvertTo-BRAVOUpdateJson' @{ InputObject = $stateRun[0].Result }
            $roundTrip = $null
            try { $roundTrip = $json | ConvertFrom-Json } catch { $roundTrip = $null }
            Test-BRAVOCondition -Condition ($null -ne $roundTrip -and $json.TrimStart().StartsWith('{') -and $roundTrip.schemaVersion -eq 1) -Name 'UpdateWorker/AsJsonPurity' -Failure 'JSON має бути єдиним контрактним об''єктом'

            $pre = @(& $call 'Invoke-BRAVOUpdateCliAction' ($base + @{ Action = 'Preflight'; Operation = 'Update' }))
            Test-BRAVOCondition -Condition ($pre.Count -eq 1 -and $null -ne $pre[0].Result.findings -and (@(0, 10, 20, 30, 31, 33, 35, 36, 37, 42, 80) -contains $pre[0].ExitCode)) `
                -Name 'UpdateWorker/CliPreflight' -Failure ('Preflight код ' + $pre[0].ExitCode)
            $diag = @(& $call 'Invoke-BRAVOUpdateCliAction' ($base + @{ Action = 'Diagnose' }))
            Test-BRAVOCondition -Condition ($diag.Count -eq 1 -and $diag[0].ExitCode -eq 0 -and $null -ne $diag[0].Result) -Name 'UpdateWorker/CliDiagnose' -Failure 'Diagnose має дати 0'

            $stagedCopy = $staged; $sourceCopy = $source; $acquire = @{ Stage = { param($Tag, $SourcePath, $AllowPrerelease, $WorkDirectory) [pscustomobject]@{ Success = $true; Findings = @(); Source = $sourceCopy; StagedRoot = $stagedCopy } }.GetNewClosure() }
            $planRun = @(& $call 'Invoke-BRAVOUpdateCliAction' ($base + @{ Action = 'Plan'; Operation = 'Update'; Acquire = $acquire; WorkRoot = $wkRoot; RuntimeRoot = $runtime }))
            Test-BRAVOCondition -Condition ($planRun.Count -eq 1 -and $null -ne $planRun[0].Result -and $planRun[0].Result.action -eq 'Update' -and (@($planRun[0].Lines) -join "`n") -match [regex]::Escape($planRun[0].Result.planId.Substring(0, 8))) `
                -Name 'UpdateWorker/CliPlan' -Failure 'Plan має повернути DeploymentPlan і короткий id'
            Test-BRAVOCondition -Condition (@(Get-ChildItem -LiteralPath $wkRoot -Directory -Filter 'BRAVO_UPDATE_PLAN_*').Count -eq 0) -Name 'UpdateWorker/PlanWorkDirectoryRemoved' -Failure 'робочий каталог плану лишився'
            $noOp = @(& $call 'Invoke-BRAVOUpdateCliAction' ($base + @{ Action = 'Plan' }))
            Test-BRAVOCondition -Condition ($noOp[0].ExitCode -eq 80) -Name 'UpdateWorker/CliPlanNeedsOperation' -Failure 'Plan без -Operation = 80'
            $badZip = @(& $call 'Invoke-BRAVOUpdateCliAction' ($base + @{ Action = 'Plan'; Operation = 'Update'; SourcePath = (Join-Path $wkRoot 'немає.zip'); WorkRoot = $wkRoot; RuntimeRoot = $runtime }))
            Test-BRAVOCondition -Condition ($badZip[0].ExitCode -eq 42 -and $badZip[0].Result.canProceed -eq $false) -Name 'UpdateWorker/CliPlanMissingArtifactFailsClosed' -Failure ('код ' + $badZip[0].ExitCode)
            Test-BRAVOCondition -Condition ($before -ceq (& $treeSnapshot $paths.StateRoot)) -Name 'UpdateWorker/ReadOnlyActionsWriteNothing' -Failure 'read-only дії змінили StateRoot'
        }

        # --- CLI диспетчер: підтвердження, елевація, Recover ---
        & {
            $stagedCopy = $staged; $sourceCopy = $source; $acquire = @{ Stage = { param($Tag, $SourcePath, $AllowPrerelease, $WorkDirectory) [pscustomobject]@{ Success = $true; Findings = @(); Source = $sourceCopy; StagedRoot = $stagedCopy } }.GetNewClosure() }
            $base = @{ Paths = $paths; Adapter = $adapter; CandidateRoots = @($runtime); Operations = $ops; Acquire = $acquire; WorkRoot = $wkRoot; RuntimeRoot = $runtime; Action = 'Update'; SourcePath = (Join-Path $wkRoot 'offline.zip') }

            $r = & $call 'Invoke-BRAVOUpdateCliAction' ($base + @{ IsAdministrator = $true; NonInteractive = $true })
            Test-BRAVOCondition -Condition ($r.ExitCode -eq 80) -Name 'UpdateWorker/NonInteractiveNeedsPlanPathAndId' -Failure 'неінтерактивно без -PlanPath/-ConfirmPlanId = 80'

            $callsBefore = $calls.Update
            $r = & $call 'Invoke-BRAVOUpdateCliAction' ($base + @{ IsAdministrator = $true; Prompt = { param($m) 'не той id' } })
            Test-BRAVOCondition -Condition ($r.ExitCode -eq 80 -and $calls.Update -eq $callsBefore) -Name 'UpdateWorker/WrongTypedIdCancels' -Failure 'хибний id має скасувати без mutation'
            $r = & $call 'Invoke-BRAVOUpdateCliAction' ($base + @{ IsAdministrator = $true })
            Test-BRAVOCondition -Condition ($r.ExitCode -eq 80 -and $calls.Update -eq $callsBefore) -Name 'UpdateWorker/NoPromptNoConfirmation' -Failure 'без Prompt підтвердження неможливе'

            $typedIds = New-Object System.Collections.Generic.List[string]
            $prompt = { param($m) $typedIds.Add($m); if ($m -match '\(([0-9a-f]{8})\)') { $Matches[1] } else { '' } }.GetNewClosure()
            $r = & $call 'Invoke-BRAVOUpdateCliAction' ($base + @{ IsAdministrator = $true; Prompt = $prompt })
            Test-BRAVOCondition -Condition ($r.ExitCode -eq 0 -and $calls.Update -eq ($callsBefore + 1) -and $r.Result.status -eq 'Success') -Name 'UpdateWorker/CliUpdateInProcessFlow' -Failure ('код ' + $r.ExitCode + ' [' + (($r.Result.findings | ForEach-Object { $_.id }) -join ',') + ']')

            # Неелевований: UAC скасовано -> 36; процес без результату -> 80; аргументи запуску.
            $callsBefore = $calls.Update
            $captured = New-Object System.Collections.Generic.List[object]
            $cancel = { param([string[]]$ArgumentList) $captured.Add($ArgumentList); [pscustomobject]@{ Launched = $false; ExitCode = 36; Error = 'UAC скасовано' } }.GetNewClosure()
            $r = & $call 'Invoke-BRAVOUpdateCliAction' ($base + @{ IsAdministrator = $false; Prompt = $prompt; ElevatedLauncher = $cancel; ScriptPath = 'C:\Тест папка\BRAVO_UPDATE.ps1' })
            $argumentText = @($captured | ForEach-Object { $_ }) -join ' '
            Test-BRAVOCondition -Condition ($r.ExitCode -eq 36 -and $calls.Update -eq $callsBefore -and $argumentText -match '-Action "Execute"' -and $argumentText -match '"C:\\Тест папка\\BRAVO_UPDATE\.ps1"' -and $argumentText -match '-RequestPath' -and $argumentText -match '-NoPause') `
                -Name 'UpdateWorker/CliElevationCancelled36' -Failure ('код ' + $r.ExitCode + '; ' + $argumentText)
            $silent = { param([string[]]$ArgumentList) [pscustomobject]@{ Launched = $true; ExitCode = 0; Error = '' } }
            $r = & $call 'Invoke-BRAVOUpdateCliAction' ($base + @{ IsAdministrator = $false; Prompt = $prompt; ElevatedLauncher = $silent; ScriptPath = 'C:\x\BRAVO_UPDATE.ps1' })
            Test-BRAVOCondition -Condition ($r.ExitCode -eq 80 -and $calls.Update -eq $callsBefore) -Name 'UpdateWorker/CliElevatedWithoutResult80' -Failure ('код ' + $r.ExitCode)

            $recover = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'Recover'; Paths = $paths; Adapter = $adapter; IsAdministrator = $true; Operations = @{ Recover = $recoverOp } }
            Test-BRAVOCondition -Condition ($recover.ExitCode -eq 0 -and $calls.Recover -eq 1) -Name 'UpdateWorker/CliRecoverAdmin' -Failure ('код ' + $recover.ExitCode)
            $recoverCancel = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'Recover'; Paths = $paths; Adapter = $adapter; IsAdministrator = $false; Operations = @{ Recover = $recoverOp }; ElevatedLauncher = $cancel; ScriptPath = 'C:\x\BRAVO_UPDATE.ps1'; WorkRoot = $wkRoot }
            Test-BRAVOCondition -Condition ($recoverCancel.ExitCode -eq 36 -and $calls.Recover -eq 1) -Name 'UpdateWorker/CliRecoverNonAdminElevates' -Failure ('код ' + $recoverCancel.ExitCode)
            # H1/5: елевований Recover пише результат у Operations/<recoveryId>/result.json під StateRoot, а не в шлях викликача.
            $recoverIdSeen = @{ Value = ''; Args = '' }
            # GetNewClosure захоплює лише локальні змінні поточної області: копіюємо потрібне явно.
            $closureCall = $call; $closurePaths = $paths; $closureAdapter = $adapter; $closureRecoverOp = $recoverOp
            $recoverLauncher = {
                param($ArgumentList)
                $joined = [string]::Join(' ', $ArgumentList)
                $recoverIdSeen.Args = $joined
                if ($joined -match '-RecoveryId "([0-9a-f-]{36})"') {
                    $recoverIdSeen.Value = $Matches[1]
                    # Імітація елевованого процесу: той самий диспетчер із RecoveryId.
                    try { $null = & $closureCall 'Invoke-BRAVOUpdateCliAction' @{ Action = 'Recover'; Paths = $closurePaths; Adapter = $closureAdapter; IsAdministrator = $true; Operations = @{ Recover = $closureRecoverOp }; RecoveryId = $Matches[1] } } catch { $recoverIdSeen.Args = 'ERR ' + $_.Exception.Message }
                }
                [pscustomobject]@{ Launched = $true; ExitCode = 0; Error = '' }
            }.GetNewClosure()
            $viaElevation = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'Recover'; Paths = $paths; Adapter = $adapter; IsAdministrator = $false; Operations = @{ Recover = $recoverOp }; ElevatedLauncher = $recoverLauncher; ScriptPath = 'C:\Тест папка\BRAVO_UPDATE.ps1' }
            $recoverResultFile = Join-Path (Join-Path (Join-Path $paths.StateRoot 'Operations') $recoverIdSeen.Value) 'result.json'
            Test-BRAVOCondition -Condition (($viaElevation.ExitCode -eq 0) -and ($recoverIdSeen.Value -ne '') -and (Test-Path -LiteralPath $recoverResultFile) -and ($recoverIdSeen.Args -notmatch '-ResultPath')) -Name 'UpdateWorker/H1/ElevatedRecoverResultUnderStateRoot' -Failure ('код ' + $viaElevation.ExitCode + '; args=' + $recoverIdSeen.Args)
            $badRecovery = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'Recover'; Paths = $paths; Adapter = $adapter; IsAdministrator = $true; Operations = @{ Recover = $recoverOp }; RecoveryId = '..\..\evil' }
            Test-BRAVOCondition -Condition ($badRecovery.ExitCode -eq 80) -Name 'UpdateWorker/H1/RecoveryIdMustBeGuid' -Failure ('код ' + $badRecovery.ExitCode)
            $initAdmin = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'Initialize'; Paths = $paths; Adapter = $adapter; IsAdministrator = $true }
            $initUser = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'Initialize'; Paths = $paths; Adapter = $adapter; IsAdministrator = $false }
            Test-BRAVOCondition -Condition (($initAdmin.ExitCode -eq 0) -and ($initUser.ExitCode -eq 36)) -Name 'UpdateWorker/H1/InitializeActionNeedsAdmin' -Failure ('admin=' + $initAdmin.ExitCode + ' user=' + $initUser.ExitCode)

            # Recover: корені для Invoke-BRAVORecovery (контракт E5) визначає виявлення, а не запит; staging/backup — типові корені engine.
            $recorded = @{ Args = $null }
            $recorderOp = {
                param([string]$StateRoot, [string]$LockRoot, [string]$OperationLockPath, $Adapter, [string]$VersionStatePath, [string]$RuntimeRoot, [string]$StagingRoot, [string]$BackupRoot)
                $recorded.Args = @{ RuntimeRoot = $RuntimeRoot; StagingRoot = $StagingRoot; BackupRoot = $BackupRoot }
                New-BRAVOUpdateDeploymentResult -OperationId ([guid]::NewGuid().ToString()) -Action Recovery -Status Success
            }.GetNewClosure()
            $discovered = & $call 'Get-BRAVOUpdateCliState' @{ CandidateRoots = @($runtime); Paths = $paths; Adapter = $adapter }
            $discoveredRoot = [string]$discovered.runtimeRoot
            $recWithRoot = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'Recover'; Paths = $paths; Adapter = $adapter; IsAdministrator = $true; CandidateRoots = @($runtime); Operations = @{ Recover = $recorderOp } }
            Test-BRAVOCondition -Condition (($recWithRoot.ExitCode -eq 0) -and ($null -ne $recorded.Args) -and ($recorded.Args.StagingRoot -ceq [string]$paths.StagingRoot) -and ($recorded.Args.BackupRoot -ceq [string]$paths.BackupRoot) -and ($recorded.Args.RuntimeRoot -ceq $discoveredRoot) -and ($discoveredRoot -ne '')) -Name 'UpdateWorker/H1/RecoverPassesDiscoveredRootAndEngineRoots' -Failure ('код ' + $recWithRoot.ExitCode + ' root=' + $discoveredRoot)
            # N1: елевований CLI перевіряє корені (read-only дії — лише валідація) ДО будь-якої дії; небезпечний корінь = 80.
            $unsafeStaging = Join-Path $wkRoot 'unsafe-staging'
            [void](New-Item -ItemType Directory -Path $unsafeStaging -Force)
            $unsafeInfo = New-Object System.IO.DirectoryInfo($unsafeStaging)
            $unsafeAcl = $unsafeInfo.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
            $unsafeAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')), [System.Security.AccessControl.FileSystemRights]::Modify,
                    ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit), [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)))
            $unsafeInfo.SetAccessControl($unsafeAcl)
            $unsafePaths = $paths.PSObject.Copy()
            $unsafePaths.StagingRoot = $unsafeStaging
            $stateUnsafe = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'State'; Paths = $unsafePaths; Adapter = $adapter; IsAdministrator = $true; CandidateRoots = @($runtime) }
            $stateUnsafeIds = @(@($stateUnsafe.Result.findings) | ForEach-Object { [string]$_.id })
            $stateSafe = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'State'; Paths = $paths; Adapter = $adapter; IsAdministrator = $true; CandidateRoots = @($runtime) }
            $stateUnelevated = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'State'; Paths = $unsafePaths; Adapter = $adapter; IsAdministrator = $false; CandidateRoots = @($runtime) }
            Test-BRAVOCondition -Condition (($stateUnsafe.ExitCode -eq 80) -and ($stateUnsafeIds -contains 'State.RootUnsafe') -and ($stateSafe.ExitCode -eq 0) -and ($stateUnelevated.ExitCode -eq 0)) -Name 'UpdateWorker/H1/ElevatedReadOnlyActionChecksRootsFirst' -Failure ('unsafe=' + $stateUnsafe.ExitCode + ' safe=' + $stateSafe.ExitCode + ' unelevated=' + $stateUnelevated.ExitCode)
            $recorded.Args = $null
            $recForeign = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'Recover'; Paths = $paths; Adapter = $adapter; IsAdministrator = $true; CandidateRoots = @($runtime); RuntimeRoot = (Join-Path $wkRoot 'not-discovered'); Operations = @{ Recover = $recorderOp } }
            Test-BRAVOCondition -Condition (($recForeign.ExitCode -eq 80) -and ($null -eq $recorded.Args)) -Name 'UpdateWorker/H1/RecoverRejectsUndiscoveredRuntimeRoot' -Failure ('код ' + $recForeign.ExitCode)
        }

        # --- Контекст discovery при запуску з каталогу toolkit != runtime (Codex P1) ---
        & {
            $callsBefore = $calls.Update
            $plan = & $newPlan
            $path = & $writeRequest $plan $null
            $viaDefault = & $call 'Invoke-BRAVOUpdateWorker' @{ RequestPath = $path; Adapter = $adapter; Paths = $paths; Operations = $ops; IsAdministrator = $true }
            Test-BRAVOCondition -Condition ($viaDefault.ExitCode -eq 0 -and $calls.Update -eq ($callsBefore + 1)) -Name 'UpdateWorker/ToolkitDirNotRuntimeStillDiscovered' `
                -Failure ('код ' + $viaDefault.ExitCode + ' [' + ((& $findingIds $viaDefault) -join ',') + ']')
            $otherPaths = $paths.PSObject.Copy()
            $otherPaths.RuntimeRoot = (Join-Path $wkRoot 'інший runtime')
            $plan = & $newPlan
            $path = & $writeRequest $plan $null
            $notFound = & $call 'Invoke-BRAVOUpdateWorker' @{ RequestPath = $path; Adapter = $adapter; Paths = $otherPaths; Operations = $ops; IsAdministrator = $true }
            Test-BRAVOCondition -Condition ($notFound.ExitCode -eq 80 -and ((& $findingIds $notFound) -contains 'Worker.ForeignRoot') -and $calls.Update -eq ($callsBefore + 1)) -Name 'UpdateWorker/UndiscoveredRuntimeStillRejected' `
                -Failure 'root поза знайденими кандидатами мусить відхилятись'
        }

        # --- Self-test як частина підтвердженого плану (Codex P2) ---
        & {
            $planWith = {
                param([string]$Action, [string]$SelfTest)
                $preflight = [pscustomobject]@{ findings = @(); canProceed = $true; blockerCount = 0; warningCount = 0 }
                & $call 'New-BRAVODeploymentPlan' @{ Action = $Action; RuntimeRoot = $runtime; StagingRoot = $paths.StagingRoot; BackupRoot = $paths.BackupRoot; StateRoot = $paths.StateRoot
                    Source = $source; StagedRoot = $staged; Preflight = $preflight; Adapter = $adapter; SelfTest = $SelfTest }
            }
            $hasPlanned = { param($Plan) @(@($Plan.tests.planned) | Where-Object { $_.id -eq 'SelfTest' }).Count -eq 1 }
            $skippedItem = { param($Plan) @(@($Plan.tests.skipped) | Where-Object { $_.id -eq 'SelfTest' }) }
            $updateDefault = & $planWith 'Update' 'Default'
            $updateSkip = & $planWith 'Update' 'Skip'
            $repairDefault = & $planWith 'Repair' 'Default'
            $repairInclude = & $planWith 'Repair' 'Include'
            Test-BRAVOCondition -Condition ((& $hasPlanned $updateDefault) -and -not (& $hasPlanned $updateSkip) -and -not (& $hasPlanned $repairDefault) -and (& $hasPlanned $repairInclude)) `
                -Name 'UpdateWorker/PlanSelfTestSelection' -Failure 'Default/Include/Skip мають визначати plan.tests.planned'
            Test-BRAVOCondition -Condition (((& $skippedItem $updateSkip)[0].reason) -ceq 'вимкнено оператором' -and (@(& $skippedItem $repairInclude)).Count -eq 0) -Name 'UpdateWorker/PlanSelfTestSkippedReason' -Failure 'причина пропуску'

            $callsBefore = $calls.Update
            $plan = & $newPlan
            $path = & $writeRequest $plan { param($r) $r.options.runSelfTest = $false }
            $mismatch = & $runWorker $path
            Test-BRAVOCondition -Condition ($mismatch.ExitCode -eq 80 -and ((& $findingIds $mismatch) -contains 'Request.OptionMismatch') -and $calls.Update -eq $callsBefore) -Name 'UpdateWorker/RunSelfTestMismatchRejected' `
                -Failure ('код ' + $mismatch.ExitCode + ' [' + ((& $findingIds $mismatch) -join ',') + ']')
            $skipPlan = & $planWith 'Update' 'Skip'
            $skipRequest = & $call 'New-BRAVOUpdateRequest' @{ Plan = $skipPlan; ConfirmedPlanShortId = $skipPlan.planId.Substring(0, 8) }
            Test-BRAVOCondition -Condition ($skipRequest.options.runSelfTest -eq $false) -Name 'UpdateWorker/RequestDefaultsRunSelfTestFromPlan' -Failure 'runSelfTest за замовчуванням береться з плану'

            $stagedCopy = $staged; $sourceCopy = $source
            $acquire = @{ Stage = { param($Tag, $SourcePath, $AllowPrerelease, $WorkDirectory) [pscustomobject]@{ Success = $true; Findings = @(); Source = $sourceCopy; StagedRoot = $stagedCopy } }.GetNewClosure() }
            $cliPlan = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'Plan'; Operation = 'Update'; SelfTest = 'Skip'; Paths = $paths; Adapter = $adapter; CandidateRoots = @($runtime); Acquire = $acquire; WorkRoot = $wkRoot; RuntimeRoot = $runtime }
            Test-BRAVOCondition -Condition ($null -ne $cliPlan.Result -and -not (& $hasPlanned $cliPlan.Result) -and (@(& $skippedItem $cliPlan.Result)).Count -eq 1) -Name 'UpdateWorker/CliPlanSelfTestSkip' -Failure 'CLI -SelfTest Skip мусить потрапити в план'
        }

        # --- Codex R2 #3: Recover через елевацію передає явний -RuntimeRoot ---
        & {
            $captured = New-Object System.Collections.Generic.List[object]
            $launcher = { param([string[]]$ArgumentList) $captured.Add($ArgumentList); [pscustomobject]@{ Launched = $false; ExitCode = 36; Error = 'UAC скасовано' } }.GetNewClosure()
            $null = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'Recover'; Paths = $paths; Adapter = $adapter; IsAdministrator = $false; RuntimeRoot = $runtime; ElevatedLauncher = $launcher; ScriptPath = 'C:\x\BRAVO_UPDATE.ps1' }
            $argumentText = @($captured | ForEach-Object { $_ }) -join ' '
            Test-BRAVOCondition -Condition ($argumentText -match '-RuntimeRoot' -and $argumentText.Contains($runtime) -and $argumentText -match '-RecoveryId') -Name 'UpdateWorker/RecoverElevationForwardsRuntimeRoot' -Failure $argumentText
            $captured.Clear()
            $null = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'Recover'; Paths = $paths; Adapter = $adapter; IsAdministrator = $false; ElevatedLauncher = $launcher; ScriptPath = 'C:\x\BRAVO_UPDATE.ps1' }
            Test-BRAVOCondition -Condition ((@($captured | ForEach-Object { $_ }) -join ' ') -notmatch '-RuntimeRoot') -Name 'UpdateWorker/RecoverElevationWithoutRootOmitsIt' -Failure 'без явного root аргумент не додається'
        }

        # --- Codex R2 #4: збережений офлайн-план без -SourcePath не переходить на онлайн ---
        & {
            $plan = & $newPlan
            $planFile = Join-Path $wkRoot 'offline-plan.json'
            [IO.File]::WriteAllText($planFile, (& $call 'ConvertTo-BRAVOUpdateJson' @{ InputObject = $plan }), (New-Object Text.UTF8Encoding $false))
            $callsBefore = $calls.Update
            $base = @{ Action = 'Update'; PlanPath = $planFile; ConfirmPlanId = $plan.planId.Substring(0, 8); NonInteractive = $true; Paths = $paths; Adapter = $adapter; CandidateRoots = @($runtime); Operations = $ops; IsAdministrator = $true }
            $refused = & $call 'Invoke-BRAVOUpdateCliAction' $base
            Test-BRAVOCondition -Condition ($refused.ExitCode -eq 80 -and (@(@($refused.Result.findings) | ForEach-Object { $_.id }) -contains 'Cli.OfflineSourceRequired') -and $calls.Update -eq $callsBefore) `
                -Name 'UpdateWorker/OfflinePlanRequiresSourcePath' -Failure ('код ' + $refused.ExitCode)
            $allowed = & $call 'Invoke-BRAVOUpdateCliAction' ($base + @{ SourcePath = (Join-Path $wkRoot 'offline.zip') })
            Test-BRAVOCondition -Condition ($allowed.ExitCode -eq 0 -and $calls.Update -eq ($callsBefore + 1) -and $calls.Last.SourcePath -ceq (Join-Path $wkRoot 'offline.zip')) -Name 'UpdateWorker/OfflinePlanWithSourcePathDispatches' -Failure ('код ' + $allowed.ExitCode)
        }

        # --- Codex R4 #3: Install, перерваний до копіювання метаданих, відновлюється за журналом ---
        & {
            $partial = Join-Path $wkRoot 'частковий install'
            [void](New-Item -ItemType Directory -Path $partial -Force)
            [IO.File]::WriteAllText((Join-Path $partial 'a.txt'), 'x', (New-Object Text.UTF8Encoding $false))
            $recordedIj = @{ Args = $null }
            $recorder = {
                param([string]$StateRoot, [string]$LockRoot, [string]$OperationLockPath, $Adapter, [string]$VersionStatePath, [string]$RuntimeRoot, [string]$StagingRoot, [string]$BackupRoot)
                $recordedIj.Args = @{ RuntimeRoot = $RuntimeRoot }
                New-BRAVOUpdateDeploymentResult -OperationId ([guid]::NewGuid().ToString()) -Action Recovery -Status Success
            }.GetNewClosure()
            $makeState = {
                param([string]$Name, [string]$JournalAction)
                $p = $paths.PSObject.Copy()
                $p.StateRoot = Join-Path $wkRoot $Name
                $p.StagingRoot = Join-Path $wkRoot ($Name + '-staging')
                $p.BackupRoot = Join-Path $wkRoot ($Name + '-backup')
                $p.OperationLockPath = Join-Path $p.LockRoot 'BRAVO_OPERATION.lock'
                $p.VersionStatePath = Join-Path $p.StateRoot 'version.json'
                [void](& $call 'Initialize-BRAVOUpdateStateDirectories' @{ StateRoot = $p.StateRoot })
                [void](& $call 'New-BRAVOUpdateJournal' @{ StateRoot = $p.StateRoot; OperationId = [guid]::NewGuid().ToString(); PlanId = [guid]::NewGuid().ToString(); Action = $JournalAction
                        RuntimeRoot = $partial; StagingRoot = $p.StagingRoot; BackupRoot = $p.BackupRoot })
                return $p
            }
            $installPaths = & $makeState 'state-install-journal' 'Install'
            $callRecover = {
                param($UsePaths, [string]$Root)
                $recordedIj.Args = $null
                $arguments = @{ Action = 'Recover'; Paths = $UsePaths; Adapter = $adapter; IsAdministrator = $true; CandidateRoots = @((Join-Path $wkRoot 'нема встановлень')); Operations = @{ Recover = $recorder } }
                if (-not [string]::IsNullOrEmpty($Root)) { $arguments['RuntimeRoot'] = $Root }
                & $call 'Invoke-BRAVOUpdateCliAction' $arguments
            }
            $noRoot = & $callRecover $installPaths ''
            Test-BRAVOCondition -Condition ($noRoot.ExitCode -eq 0 -and $null -ne $recordedIj.Args -and $recordedIj.Args.RuntimeRoot -ceq $partial) -Name 'UpdateWorker/RecoverInstallJournalWithoutRoot' -Failure ('код ' + $noRoot.ExitCode + ' ' + (@($noRoot.Result.findings | ForEach-Object { $_.id + ':' + $_.details }) -join '|'))
            $explicit = & $callRecover $installPaths $partial
            Test-BRAVOCondition -Condition ($explicit.ExitCode -eq 0 -and $recordedIj.Args.RuntimeRoot -ceq $partial) -Name 'UpdateWorker/RecoverInstallJournalExplicitRoot' -Failure ('код ' + $explicit.ExitCode)
            $wrong = & $callRecover $installPaths (Join-Path $wkRoot 'інший каталог')
            Test-BRAVOCondition -Condition ($wrong.ExitCode -eq 80 -and $null -eq $recordedIj.Args) -Name 'UpdateWorker/RecoverInstallJournalRejectsOtherRoot' -Failure ('код ' + $wrong.ExitCode)
            $updatePaths = & $makeState 'state-update-journal' 'Update'
            $updExplicit = & $callRecover $updatePaths $partial
            Test-BRAVOCondition -Condition ($null -eq $recordedIj.Args -and $updExplicit.ExitCode -eq 80) -Name 'UpdateWorker/RecoverUpdateJournalStillRequiresDiscovery' -Failure ('код ' + $updExplicit.ExitCode)
        }

        # --- Codex R3 #3: розпакований комплект не є встановленням без ознак встановлення ---
        & {
            $originalToolkit = & $wkModule { $script:BRAVOUpdateToolkitRoot }
            $bundle = Join-Path $wkRoot 'комплект bundle'
            & $writeTree $bundle @{ 'VERSION.json' = '{"packageVersion": "5.3.0", "releaseChannel": "stable"}'; 'a.txt' = 'x' }
            $emptyRuntime = Join-Path $wkRoot 'ще немає runtime'
            $freshPaths = $paths.PSObject.Copy()
            $freshPaths.RuntimeRoot = $emptyRuntime
            try {
                & $wkModule { param($r) $script:BRAVOUpdateToolkitRoot = $r } $bundle
                $candidates = @(& $call 'Get-BRAVOUpdateWorkerDefaultCandidate' @{ Paths = $freshPaths })
                $freshState = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'State'; Paths = $freshPaths; Adapter = $adapter; IsAdministrator = $false }
                Test-BRAVOCondition -Condition ($candidates.Count -eq 1 -and $candidates[0] -ceq $emptyRuntime -and $freshState.Result.state -eq 'NotInstalled' -and @($freshState.Result.candidateRoots).Count -eq 0) `
                    -Name 'UpdateWorker/ReleaseBundleIsNotAnInstallation' -Failure ('candidates=' + ($candidates -join ',') + ' state=' + $freshState.Result.state)
                [IO.File]::WriteAllText((Join-Path $bundle 'BRAVO.local.config'), '@{}', (New-Object Text.UTF8Encoding $false))
                $withConfig = @(& $call 'Get-BRAVOUpdateWorkerDefaultCandidate' @{ Paths = $freshPaths })
                $realState = & $call 'Invoke-BRAVOUpdateCliAction' @{ Action = 'State'; Paths = $freshPaths; Adapter = $adapter; IsAdministrator = $false }
                Test-BRAVOCondition -Condition ($withConfig.Count -eq 2 -and $withConfig[1] -ceq $bundle -and $realState.Result.state -ne 'NotInstalled' -and @($realState.Result.candidateRoots) -contains $bundle) `
                    -Name 'UpdateWorker/BundleWithLocalConfigIsInstallation' -Failure ('state=' + $realState.Result.state)
            } finally {
                & $wkModule { param($r) $script:BRAVOUpdateToolkitRoot = $r } $originalToolkit
            }
        }
    } finally {
        if ($null -ne $wkValidatorOriginal) {
            & $wkModule { param($Original) Set-Item -Path Function:\Test-BRAVOUpdateDeploymentPlan -Value $Original } $wkValidatorOriginal
        }
        if ($null -ne $wkJunction -and (Test-Path -LiteralPath $wkJunction)) {
            # Лише власне посилання (не ціль): Directory.Delete на junction видаляє тільки його.
            try { [IO.Directory]::Delete($wkJunction) } catch { $null = $_ }
        }
        if ($null -ne $wkRoot -and $wkRoot.StartsWith($wkPrefix, [StringComparison]::Ordinal) -and (Test-Path -LiteralPath $wkRoot)) {
            Remove-Item -LiteralPath $wkRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
