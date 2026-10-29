# Домен-фрагмент self-test: UpdateRecovery (INS-053/054 recovery після перерваного
# оновлення; INS-070…074 same-version repair; ENGINE_DESIGN §8). Усі сценарії
# працюють на sandbox-коренях у тимчасовому каталозі; production-шляхи
# (ProgramData\BRAVO, Program Files\BRAVO-Toolkit) не чіпаються, scheduler,
# credentials і справжні скрипти не запускаються.
#
# Функції інших частин (Rollback, Deploy, Reconcile) пишуться паралельно, тому тут
# вони підставлені TEST-ONLY заглушками в scope модуля (див. блок «Заглушки»):
# Invoke-BRAVORollback, Remove-BRAVOUpdateOperationDirectory,
# Disable-BRAVOAllManagedTasks, Invoke-BRAVODeployment (з/без -Scope),
# Get-BRAVOSiteConfigurationBaseline, Test-BRAVOSiteConfigurationPreserved.
# Після інтеграції реальних частин ці перевизначення діють лише в цьому фрагменті
# (модуль імпортується з -Force на початку).
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 -- НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition.

& {
    Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking -ErrorAction Stop
    $updateModule = Get-Module -Name 'BRAVO.Update'

    $recoveryTempPrefix = Join-Path ([IO.Path]::GetTempPath()) 'BRAVO_UPD_e6_'
    $recoveryBase = $recoveryTempPrefix + [guid]::NewGuid().ToString('N')

    # --- Заглушки (TEST-ONLY, scope модуля) ---------------------------------
    & $updateModule {
        $script:E6RollbackCalls = New-Object System.Collections.ArrayList
        $script:E6RollbackMode = 'RolledBack'
        $script:E6DisableCalls = 0
        $script:E6CoreCalls = New-Object System.Collections.ArrayList
        $script:E6CoreMode = 'Success'

        function script:Invoke-BRAVORollback {
            [CmdletBinding()]
            param($Journal, [hashtable]$Adapter, [string]$StateRoot, [string]$LockRoot, [string]$OperationLockPath, [string]$VersionStatePath, [hashtable]$FaultInjection = $null)
            [void]$script:E6RollbackCalls.Add([pscustomobject]@{ OperationId = [string]$Journal.operationId; VersionStatePath = $VersionStatePath; LockRoot = $LockRoot })
            if ($script:E6RollbackMode -eq 'Throw') { throw 'rollback-stub-throw' }
            if ($script:E6RollbackMode -eq 'Crash') { throw 'BRAVOUpdate.SimulatedCrash: Rollback.Stub' }
            if ($script:E6RollbackMode -eq 'Weird') {
                return (New-BRAVOUpdateDeploymentResult -OperationId ([string]$Journal.operationId) -Action Rollback -Status Success)
            }
            if ($script:E6RollbackMode -eq 'Critical') {
                [void](Set-BRAVOUpdateJournalState -Journal $Journal -State 'Critical' -StateRoot $StateRoot)
                $blocker = New-BRAVOUpdateFinding -Id 'Rollback.StubCritical' -Severity Blocker -Title 'stub' -Action 'manual'
                return (New-BRAVOUpdateDeploymentResult -OperationId ([string]$Journal.operationId) -Action Rollback -Status Critical -Findings @($blocker))
            }
            [void](Set-BRAVOUpdateJournalState -Journal $Journal -State 'RolledBack' -StateRoot $StateRoot)
            return (New-BRAVOUpdateDeploymentResult -OperationId ([string]$Journal.operationId) -Action Rollback -Status RolledBack `
                -Rollback ([pscustomobject][ordered]@{ attempted = $true; status = 'Succeeded'; message = 'stub' }))
        }

        function script:Remove-BRAVOUpdateOperationDirectory {
            [CmdletBinding()]
            param([string]$Path, [string]$ExpectedParent, [string]$OperationId)
            if ([IO.Path]::GetFileName($Path) -ne $OperationId) { throw 'stub: leaf != operationId' }
            if ([IO.Path]::GetDirectoryName($Path) -ne $ExpectedParent.TrimEnd('\')) { throw 'stub: parent != expected' }
            Remove-Item -LiteralPath $Path -Recurse -Force
        }

        function script:Disable-BRAVOAllManagedTasks {
            [CmdletBinding()]
            param([hashtable]$Adapter)
            $script:E6DisableCalls = $script:E6DisableCalls + 1
        }

        function script:Get-BRAVOSiteConfigurationBaseline {
            [CmdletBinding()]
            param([string]$RuntimeRoot)
            $table = [ordered]@{}
            foreach ($name in @('BRAVO.local.config', 'BRAVO.config', 'TOOLS_INTEGRITY.json', 'WinSCP.ini')) {
                $path = Join-Path $RuntimeRoot $name
                if ([IO.File]::Exists($path)) { $table[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $table[$name] = 'absent' }
            }
            return [pscustomobject]$table
        }

        function script:Test-BRAVOSiteConfigurationPreserved {
            [CmdletBinding()]
            param([string]$RuntimeRoot, $Baseline)
            $now = Get-BRAVOSiteConfigurationBaseline -RuntimeRoot $RuntimeRoot
            $bad = @()
            foreach ($property in $Baseline.PSObject.Properties) {
                if ([string]$now.PSObject.Properties[$property.Name].Value -ne [string]$property.Value) { $bad += $property.Name }
            }
            if ($bad.Count -gt 0) { return [pscustomobject]@{ name = 'SiteConfigPreserved'; status = 'Fail'; message = ($bad -join ', ') } }
            return [pscustomobject]@{ name = 'SiteConfigPreserved'; status = 'Pass'; message = '' }
        }

        # Ядро розгортання (спрощене): staged-каталог = SourcePath; перевіряє ідентичність
        # через РЕАЛЬНУ Test-BRAVORepairIdentity і копіює файли поза site-owned.
        function script:Invoke-BRAVODeployment {
            [CmdletBinding()]
            param($Plan, [hashtable]$Adapter, [string]$RuntimeRoot, [string]$StateRoot, [string]$LockRoot, [string]$StagingRoot, [string]$BackupRoot, [string]$OperationLockPath, [string]$VersionStatePath, [string]$SourcePath = '', [hashtable]$FaultInjection = $null, [string]$Scope = 'All')
            [void]$script:E6CoreCalls.Add([pscustomobject]@{ Scope = $Scope; SourcePath = $SourcePath; RuntimeRoot = $RuntimeRoot; HasFault = ($null -ne $FaultInjection) })
            $operationId = [string]$Plan.operationId
            $planId = [string]$Plan.planId
            if ($script:E6CoreMode -eq 'RolledBack') {
                return (New-BRAVOUpdateDeploymentResult -OperationId $operationId -PlanId $planId -Action Repair -Status RolledBack -MutationStarted $true)
            }
            if ($Scope -ne 'Scheduler') {
                $identity = Test-BRAVORepairIdentity -InstalledRuntimeRoot $RuntimeRoot -StagedRoot $SourcePath
                if (-not $identity.IsMatch) {
                    return (New-BRAVOUpdateDeploymentResult -OperationId $operationId -PlanId $planId -Action Repair -Status Failed -ReasonCode Blocked -Findings $identity.Findings)
                }
                foreach ($file in @(Get-ChildItem -LiteralPath $SourcePath -File -Recurse)) {
                    $relative = $file.FullName.Substring($SourcePath.TrimEnd('\').Length + 1)
                    if (@('BRAVO.local.config', 'BRAVO.config') -contains $relative) { continue }
                    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $RuntimeRoot $relative) -Force
                }
            }
            if ($script:E6CoreMode -eq 'TamperConfig') {
                [IO.File]::WriteAllText((Join-Path $RuntimeRoot 'BRAVO.local.config'), 'tampered', (New-Object System.Text.UTF8Encoding $false))
            }
            return (New-BRAVOUpdateDeploymentResult -OperationId $operationId -PlanId $planId -Action Repair -Status Success -MutationStarted $true)
        }
    }

    # Те саме ядро, але без параметра -Scope (для перевірки fail closed).
    $installCoreWithoutScope = {
        function script:Invoke-BRAVODeployment {
            [CmdletBinding()]
            param($Plan, [hashtable]$Adapter, [string]$RuntimeRoot, [string]$StateRoot, [string]$LockRoot, [string]$StagingRoot, [string]$BackupRoot, [string]$OperationLockPath, [string]$VersionStatePath, [string]$SourcePath = '', [hashtable]$FaultInjection = $null)
            [void]$script:E6CoreCalls.Add([pscustomobject]@{ Scope = '(none)'; SourcePath = $SourcePath; RuntimeRoot = $RuntimeRoot; HasFault = $false })
            return (New-BRAVOUpdateDeploymentResult -OperationId ([string]$Plan.operationId) -Action Repair -Status Success)
        }
    }
    $setStub = { param([string]$Name, $Value) Set-Variable -Name $Name -Value $Value -Scope Script }
    $resetCalls = {
        $script:E6RollbackCalls.Clear(); $script:E6CoreCalls.Clear()
        $script:E6RollbackMode = 'RolledBack'; $script:E6CoreMode = 'Success'; $script:E6DisableCalls = 0
    }
    $getCount = { param([string]$Name) (Get-Variable -Name $Name -Scope Script -ValueOnly).Count }

    # --- Допоміжні функції ---------------------------------------------------
    function Get-RecTreeHash {
        param([string]$Path)
        $lines = New-Object System.Collections.ArrayList
        foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object -Property FullName)) {
            $relative = $item.FullName.Substring($Path.Length)
            if ($item.PSIsContainer) { [void]$lines.Add("D|$relative") }
            else { [void]$lines.Add("F|$relative|" + (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash) }
        }
        return ($lines.ToArray() -join "`n")
    }

    # Хеш робочих каталогів сценарію БЕЗ Locks: lifecycle-lock-файл Recovery створює завжди (очікуваний побічний ефект).
    function Get-RecEnvHash {
        param($Environment)
        $parts = foreach ($key in @('Runtime', 'State', 'Staging', 'Backup')) { $key + '::' + (Get-RecTreeHash -Path $Environment[$key]) }
        return ($parts -join "`n")
    }

    function New-RecEnv {
        param([string]$Name)
        $base = Join-Path $recoveryBase $Name
        $environment = @{
            Base = $base
            Runtime = (Join-Path $base 'Сервер BRAVO runtime')
            State = (Join-Path $base 'Стан state')
            Lock = (Join-Path $base 'Locks')
            Staging = (Join-Path $base 'Staging dir')
            Backup = (Join-Path $base 'Резерв Backup')
            OpLock = (Join-Path (Join-Path $base 'Сервер BRAVO runtime') 'BRAVO_OPERATION.lock')
            VersionState = (Join-Path $base 'State\BRAVO_VERSION_STATE.json')
            OpId = [guid]::NewGuid().ToString()
            Adapter = @{}
        }
        foreach ($key in @('Runtime', 'State', 'Lock', 'Staging', 'Backup')) { New-Item -ItemType Directory -Path $environment[$key] -Force | Out-Null }
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText((Join-Path $environment.Runtime 'BRAVO_FIXTURE.ps1'), "# fixture`r`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $environment.Runtime 'BRAVO.local.config'), '{"site":"Example Lab"}', $utf8)
        [IO.File]::WriteAllText((Join-Path $environment.Runtime 'VERSION.json'), (New-RecVersionJson -Version '5.3.0'), $utf8)
        return $environment
    }

    function New-RecVersionJson {
        param([string]$Version, [string]$Commit = 'abc1234abc1234abc1234abc1234abc1234abcd', [string]$BuildId = 'abc1234')
        return ('{"product":"BRAVO-Toolkit","packageVersion":"' + $Version + '","releaseChannel":"stable","buildId":"' + $BuildId + '","sourceCommit":"' + $Commit + '","releaseDate":"2026-10-01"}')
    }

    # Журнал, перерваний у фазі $Last: усі попередні фази завершені, $Last — з intent
    # (і з completion, якщо $Completed). Створює staging\<op> і backup\<op>.
    function New-RecJournal {
        param($Environment, [string]$Last, [bool]$Completed, [bool]$Mutation, [string]$OperationId = '')
        if ($OperationId -eq '') { $OperationId = $Environment.OpId }
        New-Item -ItemType Directory -Path (Join-Path $Environment.Staging $OperationId) -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Environment.Backup $OperationId) -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path (Join-Path $Environment.Staging $OperationId) 'payload.txt'), 'staged', (New-Object System.Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path (Join-Path $Environment.Backup $OperationId) 'backup-manifest.json'), '{}', (New-Object System.Text.UTF8Encoding $false))
        & $updateModule {
            param($E, [string]$Last, [bool]$Completed, [bool]$Mutation, [string]$OpId)
            $phases = @('Acquire', 'Stage', 'Backup', 'QuiesceTasks', 'Deploy', 'ConfigureScheduler', 'Validate', 'Activate')
            $journal = New-BRAVOUpdateJournal -StateRoot $E.State -Action Update -OperationId $OpId -RuntimeRoot $E.Runtime -StagingRoot $E.Staging -BackupRoot $E.Backup -SourceVersion '5.3.0' -TargetVersion '5.3.1'
            foreach ($phase in $phases) {
                [void](Add-BRAVOUpdateJournalPhaseIntent -Journal $journal -Phase $phase -StateRoot $E.State)
                if (($phase -ne $Last) -or $Completed) { [void](Complete-BRAVOUpdateJournalPhase -Journal $journal -Phase $phase -Outcome 'Succeeded' -StateRoot $E.State) }
                if ($phase -eq $Last) { break }
            }
            if ($Mutation) { [void](Set-BRAVOUpdateJournalMutationStarted -Journal $journal -StateRoot $E.State) }
        } $Environment $Last $Completed $Mutation $OperationId
        return $OperationId
    }

    function Read-RecJournal {
        param($Environment, [string]$OperationId)
        return (& $updateModule { param($E, $Id) (Read-BRAVOUpdateJournal -Path (Get-BRAVOUpdateJournalPath -StateRoot $E.State -OperationId $Id)).Journal } $Environment $OperationId)
    }

    function Invoke-RecRecovery {
        param($Environment, [hashtable]$FaultInjection = $null)
        $parameters = @{ StateRoot = $Environment.State; LockRoot = $Environment.Lock; OperationLockPath = $Environment.OpLock; Adapter = $Environment.Adapter; VersionStatePath = $Environment.VersionState }
        if ($null -ne $FaultInjection) { $parameters['FaultInjection'] = $FaultInjection }
        return (& $updateModule { param($P) Invoke-BRAVORecovery @P } $parameters)
    }

    function New-RecPlan {
        param($Environment, [string]$Version = '5.3.0', [string]$Action = 'Repair')
        return [pscustomobject]@{
            action = $Action; operationId = [guid]::NewGuid().ToString(); planId = [guid]::NewGuid().ToString()
            runtimeRoot = $Environment.Runtime; stagingRoot = $Environment.Staging; backupRoot = $Environment.Backup
            source = [pscustomobject]@{ packageVersion = $Version }; currentVersion = $Version; targetVersion = $Version
        }
    }

    function New-RecStaged {
        param($Environment, [string]$Name, [string]$VersionJson = '')
        $path = Join-Path $Environment.Base $Name
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText((Join-Path $path 'BRAVO_FIXTURE.ps1'), "# fixture`r`n", $utf8)
        if ($VersionJson -eq '') { $VersionJson = New-RecVersionJson -Version '5.3.0' }
        if ($VersionJson -ne 'NONE') { [IO.File]::WriteAllText((Join-Path $path 'VERSION.json'), $VersionJson, $utf8) }
        return $path
    }

    function Invoke-RecRepair {
        param($Environment, $Plan, [string]$Staged = '', [string]$Scope = 'All')
        $parameters = @{ Plan = $Plan; Adapter = $Environment.Adapter; RuntimeRoot = $Environment.Runtime; StateRoot = $Environment.State; LockRoot = $Environment.Lock; StagingRoot = $Environment.Staging; BackupRoot = $Environment.Backup; OperationLockPath = $Environment.OpLock; VersionStatePath = $Environment.VersionState; Scope = $Scope }
        if ($Staged -ne '') { $parameters['SourcePath'] = $Staged }
        return (& $updateModule { param($P) Repair-BRAVOInstallation @P } $parameters)
    }

    function Test-RecFindingId {
        param($Result, [string]$Id)
        foreach ($finding in @($Result.findings)) { if ($finding.id -ceq $Id) { return $true } }
        return $false
    }

    try {
        New-Item -ItemType Directory -Path $recoveryBase -Force | Out-Null

        # ===== Recovery: 0 журналів ===========================================
        & {
            $e = New-RecEnv -Name 'none'
            $before = Get-RecTreeHash -Path $e.Runtime
            $r = Invoke-RecRecovery -Environment $e
            Test-BRAVOCondition -Condition ($r.status -ceq 'Success' -and $r.exitCode -eq 0 -and $r.action -ceq 'Recovery') -Name 'UpdateRecovery/NoJournalSuccess' -Failure ($r | ConvertTo-Json -Depth 4)
            Test-BRAVOCondition -Condition ($before -ceq (Get-RecTreeHash -Path $e.Runtime)) -Name 'UpdateRecovery/NoJournalRuntimeUnchanged' -Failure 'runtime змінився'
            $v = & $updateModule { param($R) Test-BRAVOUpdateDeploymentResult -InputObject $R } $r
            Test-BRAVOCondition -Condition $v.IsValid -Name 'UpdateRecovery/ResultContractValid' -Failure ($v.Problems -join '; ')
        }

        # ===== Recovery: кожна фаза x completion x mutationStarted =============
        & {
            $phases = @('Acquire', 'Stage', 'Backup', 'QuiesceTasks', 'Deploy', 'ConfigureScheduler', 'Validate', 'Activate')
            foreach ($phase in $phases) {
                foreach ($completed in @($false, $true)) {
                    foreach ($mutation in @($false, $true)) {
                        $tag = '{0}.{1}.{2}' -f $phase, $(if ($completed) { 'done' } else { 'intent' }), $(if ($mutation) { 'mutated' } else { 'clean' })
                        $e = New-RecEnv -Name ('ph_' + $tag)
                        $opId = New-RecJournal -Environment $e -Last $phase -Completed $completed -Mutation $mutation
                        & $updateModule $resetCalls
                        $before = Get-RecTreeHash -Path $e.Runtime
                        $r = Invoke-RecRecovery -Environment $e
                        $calls = & $updateModule $getCount 'E6RollbackCalls'
                        $journal = Read-RecJournal -Environment $e -OperationId $opId
                        $stagingGone = -not (Test-Path -LiteralPath (Join-Path $e.Staging $opId))
                        $backupGone = -not (Test-Path -LiteralPath (Join-Path $e.Backup $opId))
                        if (-not $mutation) {
                            Test-BRAVOCondition -Condition ($r.status -ceq 'Failed' -and $r.exitCode -eq 80 -and $r.operationId -ceq $opId -and $r.mutationStarted -eq $false) -Name "UpdateRecovery/Abandon/$tag/Result" -Failure ($r | ConvertTo-Json -Depth 4)
                            Test-BRAVOCondition -Condition ($journal.state -ceq 'Abandoned' -and $stagingGone -and $backupGone -and $calls -eq 0) -Name "UpdateRecovery/Abandon/$tag/CleanedNoRollback" -Failure "state=$($journal.state) staging=$stagingGone backup=$backupGone rollback=$calls"
                            Test-BRAVOCondition -Condition ($before -ceq (Get-RecTreeHash -Path $e.Runtime)) -Name "UpdateRecovery/Abandon/$tag/RuntimeUnchanged" -Failure 'runtime змінився'
                        } else {
                            Test-BRAVOCondition -Condition ($r.status -ceq 'RolledBack' -and $r.exitCode -eq 81 -and $r.operationId -ceq $opId -and $r.mutationStarted -eq $true) -Name "UpdateRecovery/Rollback/$tag/Result" -Failure ($r | ConvertTo-Json -Depth 4)
                            Test-BRAVOCondition -Condition ($calls -eq 1 -and $journal.state -ceq 'RolledBack' -and -not $stagingGone -and -not $backupGone) -Name "UpdateRecovery/Rollback/$tag/DelegatedKeepsBackup" -Failure "rollback=$calls state=$($journal.state) staging=$stagingGone backup=$backupGone"
                        }
                    }
                }
            }
        }

        # ===== Recovery: повторюваність, crash у самому recovery ===============
        & {
            # Повторний recovery після Abandoned і після RolledBack -> «не потрібне».
            $e = New-RecEnv -Name 'idem'
            $opId = New-RecJournal -Environment $e -Last 'Backup' -Completed $true -Mutation $false
            [void](Invoke-RecRecovery -Environment $e)
            $before = Get-RecEnvHash -Environment $e
            $again = Invoke-RecRecovery -Environment $e
            Test-BRAVOCondition -Condition ($again.status -ceq 'Success' -and $again.exitCode -eq 0 -and $before -ceq (Get-RecEnvHash -Environment $e)) -Name 'UpdateRecovery/Idempotent/AfterAbandon' -Failure ($again | ConvertTo-Json -Depth 4)

            $e2 = New-RecEnv -Name 'idem2'
            [void](New-RecJournal -Environment $e2 -Last 'Deploy' -Completed $false -Mutation $true)
            & $updateModule $resetCalls
            [void](Invoke-RecRecovery -Environment $e2)
            $again2 = Invoke-RecRecovery -Environment $e2
            $calls2 = & $updateModule $getCount 'E6RollbackCalls'
            Test-BRAVOCondition -Condition ($again2.status -ceq 'Success' -and $calls2 -eq 1) -Name 'UpdateRecovery/Idempotent/AfterRollbackNoSecondRollback' -Failure "status=$($again2.status) rollback=$calls2"

            # Crash у recovery: журнал лишається Open, lock звільнено, другий запуск завершує.
            foreach ($point in @('Recovery.Start', 'Recovery.AfterIntent', 'Recovery.AfterCleanup')) {
                $e3 = New-RecEnv -Name ('crash_' + $point)
                $opId3 = New-RecJournal -Environment $e3 -Last 'Stage' -Completed $true -Mutation $false
                $thrown = $null
                try { [void](Invoke-RecRecovery -Environment $e3 -FaultInjection @{ $point = 'Crash' }) } catch { $thrown = $_.Exception.Message }
                $open = Read-RecJournal -Environment $e3 -OperationId $opId3
                Test-BRAVOCondition -Condition (($null -ne $thrown) -and $thrown -like 'BRAVOUpdate.SimulatedCrash*' -and $open.state -ceq 'Open') -Name "UpdateRecovery/Crash/$point/JournalStaysOpen" -Failure "thrown=$thrown state=$($open.state)"
                $lockProbe = & $updateModule { param($L) $x = Enter-BRAVOUpdateLifecycleLock -LockRoot $L -OperationId ([guid]::NewGuid().ToString()); $ok = $x.Success; Exit-BRAVOUpdateLifecycleLock -Lock $x; $ok } $e3.Lock
                Test-BRAVOCondition -Condition ($lockProbe -eq $true) -Name "UpdateRecovery/Crash/$point/LockReleased" -Failure 'lifecycle lock не звільнено'
                $second = Invoke-RecRecovery -Environment $e3
                $done = Read-RecJournal -Environment $e3 -OperationId $opId3
                $recoveryPhases = @(@($done.phases) | Where-Object { $_.phase -ceq 'Recovery' })
                Test-BRAVOCondition -Condition ($second.status -ceq 'Failed' -and $done.state -ceq 'Abandoned' -and $recoveryPhases.Count -le 1 -and -not (Test-Path -LiteralPath (Join-Path $e3.Staging $opId3))) -Name "UpdateRecovery/Crash/$point/SecondRunCompletes" -Failure "status=$($second.status) state=$($done.state) phases=$($recoveryPhases.Count)"
            }

            # Crash перед rollback: rollback ще не викликано; другий запуск відкочує.
            $e4 = New-RecEnv -Name 'crash_rb'
            $opId4 = New-RecJournal -Environment $e4 -Last 'Activate' -Completed $false -Mutation $true
            & $updateModule $resetCalls
            $thrown4 = $null
            try { [void](Invoke-RecRecovery -Environment $e4 -FaultInjection @{ 'Recovery.BeforeRollback' = 'Crash' }) } catch { $thrown4 = $_.Exception.Message }
            $callsAfterCrash = & $updateModule $getCount 'E6RollbackCalls'
            $r4 = Invoke-RecRecovery -Environment $e4
            Test-BRAVOCondition -Condition (($null -ne $thrown4) -and $callsAfterCrash -eq 0 -and $r4.status -ceq 'RolledBack') -Name 'UpdateRecovery/Crash/BeforeRollbackThenRolledBack' -Failure "thrown=$thrown4 calls=$callsAfterCrash status=$($r4.status)"

            # Crash усередині rollback (stub) не перехоплюється recovery.
            $e5 = New-RecEnv -Name 'crash_in_rb'
            $opId5 = New-RecJournal -Environment $e5 -Last 'Deploy' -Completed $false -Mutation $true
            & $updateModule $resetCalls
            & $updateModule $setStub 'E6RollbackMode' 'Crash'
            $thrown5 = $null
            try { [void](Invoke-RecRecovery -Environment $e5) } catch { $thrown5 = $_.Exception.Message }
            $j5 = Read-RecJournal -Environment $e5 -OperationId $opId5
            Test-BRAVOCondition -Condition (($null -ne $thrown5) -and $thrown5 -like 'BRAVOUpdate.SimulatedCrash*' -and $j5.state -ceq 'Open') -Name 'UpdateRecovery/Crash/InsideRollbackPropagates' -Failure "thrown=$thrown5 state=$($j5.state)"

            # Throw (не crash) під час прибирання: Failed/Error, журнал Open.
            $e6 = New-RecEnv -Name 'throw_cleanup'
            $opId6 = New-RecJournal -Environment $e6 -Last 'Stage' -Completed $true -Mutation $false
            $r6 = Invoke-RecRecovery -Environment $e6 -FaultInjection @{ 'Recovery.AfterIntent' = 'Throw' }
            $j6 = Read-RecJournal -Environment $e6 -OperationId $opId6
            Test-BRAVOCondition -Condition ($r6.status -ceq 'Failed' -and $r6.exitCode -eq 80 -and $j6.state -ceq 'Open') -Name 'UpdateRecovery/ThrowDuringCleanupKeepsOpen' -Failure ($r6 | ConvertTo-Json -Depth 4)
        }

        # ===== Recovery: rollback Critical / виняток / неочікуваний статус =====
        & {
            foreach ($mode in @('Critical', 'Throw', 'Weird')) {
                $e = New-RecEnv -Name ('rbfail_' + $mode)
                $opId = New-RecJournal -Environment $e -Last 'Deploy' -Completed $false -Mutation $true
                & $updateModule $resetCalls
                & $updateModule $setStub 'E6RollbackMode' $mode
                $r = Invoke-RecRecovery -Environment $e
                $disabled = & $updateModule { $script:E6DisableCalls }
                $j = Read-RecJournal -Environment $e -OperationId $opId
                Test-BRAVOCondition -Condition ($r.status -ceq 'Critical' -and $r.exitCode -eq 82 -and $j.state -ceq 'Critical') -Name "UpdateRecovery/RollbackFail/$mode/Critical" -Failure ($r | ConvertTo-Json -Depth 4)
                if ($mode -ne 'Critical') {
                    Test-BRAVOCondition -Condition ($disabled -eq 1 -and (Test-Path -LiteralPath (Join-Path $e.Backup $opId))) -Name "UpdateRecovery/RollbackFail/$mode/TasksDisabledBackupKept" -Failure "disabled=$disabled"
                }
                $v = & $updateModule { param($R) Test-BRAVOUpdateDeploymentResult -InputObject $R } $r
                Test-BRAVOCondition -Condition $v.IsValid -Name "UpdateRecovery/RollbackFail/$mode/ResultContractValid" -Failure ($v.Problems -join '; ')
            }
            & $updateModule $resetCalls
        }

        # ===== Recovery: >1 журналів, пошкоджений, lock, підроблені корені =====
        & {
            # >1 відкритих журналів -> Blocked без змін.
            $e = New-RecEnv -Name 'many'
            $opA = New-RecJournal -Environment $e -Last 'Stage' -Completed $true -Mutation $false
            $opB = New-RecJournal -Environment $e -Last 'Deploy' -Completed $false -Mutation $true -OperationId ([guid]::NewGuid().ToString())
            & $updateModule $resetCalls
            $before = Get-RecEnvHash -Environment $e
            $r = Invoke-RecRecovery -Environment $e
            Test-BRAVOCondition -Condition ($r.status -ceq 'Failed' -and $r.reasonCode -ceq 'Blocked' -and (Test-RecFindingId -Result $r -Id 'Recovery.MultipleOpenJournals') -and $r.exitCode -eq 80) -Name 'UpdateRecovery/MultipleOpenJournalsBlocked' -Failure ($r | ConvertTo-Json -Depth 4)
            Test-BRAVOCondition -Condition ($before -ceq (Get-RecEnvHash -Environment $e) -and (& $updateModule $getCount 'E6RollbackCalls') -eq 0) -Name 'UpdateRecovery/MultipleOpenJournalsNoChanges' -Failure 'recovery щось змінив'

            # Пошкоджений журнал -> Critical без змін (і сміттєвий JSON, і невалідна схема).
            foreach ($garbage in @('{ not json', '{"schemaVersion":1,"operationId":"x"}', '')) {
                $e2 = New-RecEnv -Name ('corrupt_' + $garbage.Length)
                $corruptId = [guid]::NewGuid().ToString()
                $journalDir = Join-Path $e2.State 'Journal'
                New-Item -ItemType Directory -Path $journalDir -Force | Out-Null
                [IO.File]::WriteAllText((Join-Path $journalDir ($corruptId + '.json')), $garbage, (New-Object System.Text.UTF8Encoding $false))
                $before2 = Get-RecEnvHash -Environment $e2
                & $updateModule $resetCalls
                $r2 = Invoke-RecRecovery -Environment $e2
                Test-BRAVOCondition -Condition ($r2.status -ceq 'Critical' -and $r2.exitCode -eq 82 -and (Test-RecFindingId -Result $r2 -Id 'Recovery.JournalCorrupt')) -Name ('UpdateRecovery/CorruptJournalCritical/len' + $garbage.Length) -Failure ($r2 | ConvertTo-Json -Depth 4)
                Test-BRAVOCondition -Condition ($before2 -ceq (Get-RecEnvHash -Environment $e2) -and (& $updateModule $getCount 'E6RollbackCalls') -eq 0) -Name ('UpdateRecovery/CorruptJournalNoChanges/len' + $garbage.Length) -Failure 'recovery щось змінив'
            }

            # Зайнятий lifecycle lock -> Blocked, код 20, нічого не змінено.
            $e3 = New-RecEnv -Name 'busy'
            $opId3 = New-RecJournal -Environment $e3 -Last 'Stage' -Completed $true -Mutation $false
            $held = & $updateModule { param($L) Enter-BRAVOUpdateLifecycleLock -LockRoot $L -OperationId ([guid]::NewGuid().ToString()) } $e3.Lock
            try {
                $r3 = Invoke-RecRecovery -Environment $e3
            } finally {
                & $updateModule { param($H) Exit-BRAVOUpdateLifecycleLock -Lock $H } $held
            }
            $j3 = Read-RecJournal -Environment $e3 -OperationId $opId3
            Test-BRAVOCondition -Condition ($r3.status -ceq 'Failed' -and $r3.reasonCode -ceq 'Blocked' -and $r3.exitCode -eq 20 -and $j3.state -ceq 'Open' -and (Test-Path -LiteralPath (Join-Path $e3.Staging $opId3))) -Name 'UpdateRecovery/LifecycleLockBusyBlocked20' -Failure ($r3 | ConvertTo-Json -Depth 4)

            # Підроблені корені журналу: staging усередині runtime -> відмова, файли цілі.
            $e4 = New-RecEnv -Name 'tampered'
            $opId4 = [guid]::NewGuid().ToString()
            [void](New-RecJournal -Environment $e4 -Last 'Stage' -Completed $true -Mutation $false -OperationId $opId4)
            & $updateModule {
                param($E, $Id)
                $journal = (Read-BRAVOUpdateJournal -Path (Get-BRAVOUpdateJournalPath -StateRoot $E.State -OperationId $Id)).Journal
                $journal.stagingRoot = $E.Runtime
                [void](Write-BRAVOUpdateJournal -Journal $journal -StateRoot $E.State)
            } $e4 $opId4
            New-Item -ItemType Directory -Path (Join-Path $e4.Runtime $opId4) -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path (Join-Path $e4.Runtime $opId4) 'keep.txt'), 'keep', (New-Object System.Text.UTF8Encoding $false))
            $before4 = Get-RecTreeHash -Path $e4.Runtime
            $r4 = Invoke-RecRecovery -Environment $e4
            $j4 = Read-RecJournal -Environment $e4 -OperationId $opId4
            Test-BRAVOCondition -Condition ($r4.status -ceq 'Failed' -and $r4.reasonCode -ceq 'Error' -and $j4.state -ceq 'Open' -and $before4 -ceq (Get-RecTreeHash -Path $e4.Runtime)) -Name 'UpdateRecovery/TamperedJournalRootRefused' -Failure ($r4 | ConvertTo-Json -Depth 4)
        }

        # ===== Recovery: VersionStatePath за замовчуванням і передача параметрів =
        & {
            $e = New-RecEnv -Name 'args'
            [void](New-RecJournal -Environment $e -Last 'Deploy' -Completed $false -Mutation $true)
            & $updateModule $resetCalls
            [void](Invoke-RecRecovery -Environment $e)
            $call = & $updateModule { $script:E6RollbackCalls[0] }
            Test-BRAVOCondition -Condition ($call.VersionStatePath -ceq $e.VersionState -and $call.LockRoot -ceq $e.Lock) -Name 'UpdateRecovery/RollbackReceivesRoots' -Failure ($call | ConvertTo-Json)
        }

        # ===== Repair: ідентичність (юніт) ====================================
        & {
            $e = New-RecEnv -Name 'ident'
            $utf8 = New-Object System.Text.UTF8Encoding $false
            $same = New-RecStaged -Environment $e -Name 'st_same'
            $commit = New-RecStaged -Environment $e -Name 'st_commit' -VersionJson (New-RecVersionJson -Version '5.3.0' -Commit 'ffff234abc1234abc1234abc1234abc1234abcd')
            $build = New-RecStaged -Environment $e -Name 'st_build' -VersionJson (New-RecVersionJson -Version '5.3.0' -BuildId 'zzz9999')
            $ver = New-RecStaged -Environment $e -Name 'st_ver' -VersionJson (New-RecVersionJson -Version '5.4.0')
            $case = New-RecStaged -Environment $e -Name 'st_case' -VersionJson (New-RecVersionJson -Version '5.3.0' -Commit 'ABC1234ABC1234ABC1234ABC1234ABC1234ABCD')
            $none = New-RecStaged -Environment $e -Name 'st_none' -VersionJson 'NONE'
            $bad = New-RecStaged -Environment $e -Name 'st_bad' -VersionJson '{ broken'
            $partial = New-RecStaged -Environment $e -Name 'st_partial' -VersionJson '{"packageVersion":"5.3.0","sourceCommit":"abc1234abc1234abc1234abc1234abc1234abcd"}'
            $check = { param($Installed, $Staged) Test-BRAVORepairIdentity -InstalledRuntimeRoot $Installed -StagedRoot $Staged }
            $ids = { param($R) @($R.Findings | ForEach-Object { $_.id }) -join ',' }
            $rSame = & $updateModule $check $e.Runtime $same
            Test-BRAVOCondition -Condition ($rSame.IsMatch -and @($rSame.Findings).Count -eq 0) -Name 'UpdateRecovery/Identity/SameBuildMatches' -Failure 'збіг не визнано'
            foreach ($case2 in @(@('commit', $commit), @('build', $build), @('version', $ver), @('commitCase', $case))) {
                $rr = & $updateModule $check $e.Runtime $case2[1]
                Test-BRAVOCondition -Condition ((-not $rr.IsMatch) -and ((& $ids $rr) -ceq 'Repair.VersionMismatch')) -Name ('UpdateRecovery/Identity/Mismatch/' + $case2[0]) -Failure (& $ids $rr)
            }
            foreach ($case3 in @(@('missing', $none), @('corrupt', $bad), @('partial', $partial))) {
                $rr = & $updateModule $check $e.Runtime $case3[1]
                Test-BRAVOCondition -Condition ((-not $rr.IsMatch) -and ((& $ids $rr) -ceq 'Repair.IdentityUnproven')) -Name ('UpdateRecovery/Identity/StagedUnproven/' + $case3[0]) -Failure (& $ids $rr)
            }
            # Встановлений VERSION.json нечитаний -> IdentityUnproven.
            [IO.File]::WriteAllText((Join-Path $e.Runtime 'VERSION.json'), '{ broken', $utf8)
            $rr = & $updateModule $check $e.Runtime $same
            Test-BRAVOCondition -Condition ((-not $rr.IsMatch) -and ((& $ids $rr) -ceq 'Repair.IdentityUnproven')) -Name 'UpdateRecovery/Identity/InstalledUnproven' -Failure (& $ids $rr)
        }

        # ===== Repair-BRAVOInstallation =======================================
        & {
            # Пошкоджений файл -> Success; локальний конфіг за хешем не змінено.
            $e = New-RecEnv -Name 'rep_ok'
            $staged = New-RecStaged -Environment $e -Name 'staged_ok'
            [IO.File]::WriteAllText((Join-Path $e.Runtime 'BRAVO_FIXTURE.ps1'), '# DAMAGED', (New-Object System.Text.UTF8Encoding $false))
            $configHash = (Get-FileHash -LiteralPath (Join-Path $e.Runtime 'BRAVO.local.config') -Algorithm SHA256).Hash
            $goodHash = (Get-FileHash -LiteralPath (Join-Path $staged 'BRAVO_FIXTURE.ps1') -Algorithm SHA256).Hash
            & $updateModule $resetCalls
            $plan = New-RecPlan -Environment $e
            $r = Invoke-RecRepair -Environment $e -Plan $plan -Staged $staged
            $fixedHash = (Get-FileHash -LiteralPath (Join-Path $e.Runtime 'BRAVO_FIXTURE.ps1') -Algorithm SHA256).Hash
            $afterConfig = (Get-FileHash -LiteralPath (Join-Path $e.Runtime 'BRAVO.local.config') -Algorithm SHA256).Hash
            Test-BRAVOCondition -Condition ($r.status -ceq 'Success' -and $r.exitCode -eq 0 -and $r.action -ceq 'Repair') -Name 'UpdateRecovery/Repair/DamagedFileSuccess' -Failure ($r | ConvertTo-Json -Depth 4)
            Test-BRAVOCondition -Condition ($fixedHash -ceq $goodHash -and $afterConfig -ceq $configHash) -Name 'UpdateRecovery/Repair/FileFixedLocalConfigHashUnchanged' -Failure "fixed=$fixedHash config=$afterConfig/$configHash"
            $coreCall = & $updateModule { $script:E6CoreCalls[0] }
            Test-BRAVOCondition -Condition ($coreCall.Scope -ceq 'All' -and $coreCall.SourcePath -ceq $staged) -Name 'UpdateRecovery/Repair/CoreCalledWithScopeAll' -Failure ($coreCall | ConvertTo-Json)
            $v = & $updateModule { param($R) Test-BRAVOUpdateDeploymentResult -InputObject $R } $r
            Test-BRAVOCondition -Condition $v.IsValid -Name 'UpdateRecovery/Repair/ResultContractValid' -Failure ($v.Problems -join '; ')

            # Інша версія в плані -> VersionMismatch, ядро не викликано, runtime незмінний.
            $e2 = New-RecEnv -Name 'rep_ver'
            $staged2 = New-RecStaged -Environment $e2 -Name 'staged_ver' -VersionJson (New-RecVersionJson -Version '5.4.0')
            $before2 = Get-RecEnvHash -Environment $e2
            & $updateModule $resetCalls
            $r2 = Invoke-RecRepair -Environment $e2 -Plan (New-RecPlan -Environment $e2 -Version '5.4.0') -Staged $staged2
            Test-BRAVOCondition -Condition ($r2.status -ceq 'Failed' -and $r2.reasonCode -ceq 'Blocked' -and (Test-RecFindingId -Result $r2 -Id 'Repair.VersionMismatch') -and (& $updateModule $getCount 'E6CoreCalls') -eq 0) -Name 'UpdateRecovery/Repair/OtherVersionPlanRejected' -Failure ($r2 | ConvertTo-Json -Depth 4)
            Test-BRAVOCondition -Condition ($before2 -ceq (Get-RecEnvHash -Environment $e2)) -Name 'UpdateRecovery/Repair/OtherVersionNoChanges' -Failure 'щось змінилось'
            # Лише source.packageVersion відрізняється -> теж відхилено (немає прихованого upgrade).
            $plan2b = New-RecPlan -Environment $e2
            $plan2b.source.packageVersion = '5.4.0'
            $r2b = Invoke-RecRepair -Environment $e2 -Plan $plan2b -Staged $staged2
            Test-BRAVOCondition -Condition ($r2b.status -ceq 'Failed' -and (Test-RecFindingId -Result $r2b -Id 'Repair.VersionMismatch')) -Name 'UpdateRecovery/Repair/SourceVersionMismatchRejected' -Failure ($r2b | ConvertTo-Json -Depth 4)

            # Staged з іншим buildId/commit -> ядро (через Test-BRAVORepairIdentity) блокує, runtime незмінний.
            $e3 = New-RecEnv -Name 'rep_build'
            $staged3 = New-RecStaged -Environment $e3 -Name 'staged_build' -VersionJson (New-RecVersionJson -Version '5.3.0' -BuildId 'other99')
            [IO.File]::WriteAllText((Join-Path $e3.Runtime 'BRAVO_FIXTURE.ps1'), '# DAMAGED', (New-Object System.Text.UTF8Encoding $false))
            $before3 = Get-RecTreeHash -Path $e3.Runtime
            $r3 = Invoke-RecRepair -Environment $e3 -Plan (New-RecPlan -Environment $e3) -Staged $staged3
            Test-BRAVOCondition -Condition ($r3.status -ceq 'Failed' -and (Test-RecFindingId -Result $r3 -Id 'Repair.VersionMismatch') -and $before3 -ceq (Get-RecTreeHash -Path $e3.Runtime)) -Name 'UpdateRecovery/Repair/StagedBuildMismatchBlocked' -Failure ($r3 | ConvertTo-Json -Depth 4)

            # Нечитаний/неповний встановлений VERSION.json -> IdentityUnproven, ядро не викликано.
            foreach ($brokenJson in @('{ broken', '{"packageVersion":"5.3.0"}')) {
                $e4 = New-RecEnv -Name ('rep_unproven_' + $brokenJson.Length)
                [IO.File]::WriteAllText((Join-Path $e4.Runtime 'VERSION.json'), $brokenJson, (New-Object System.Text.UTF8Encoding $false))
                $staged4 = New-RecStaged -Environment $e4 -Name 'staged4'
                $before4 = Get-RecEnvHash -Environment $e4
                & $updateModule $resetCalls
                $r4 = Invoke-RecRepair -Environment $e4 -Plan (New-RecPlan -Environment $e4) -Staged $staged4
                Test-BRAVOCondition -Condition ($r4.status -ceq 'Failed' -and (Test-RecFindingId -Result $r4 -Id 'Repair.IdentityUnproven') -and (& $updateModule $getCount 'E6CoreCalls') -eq 0 -and $before4 -ceq (Get-RecEnvHash -Environment $e4)) -Name ('UpdateRecovery/Repair/InstalledIdentityUnproven/len' + $brokenJson.Length) -Failure ($r4 | ConvertTo-Json -Depth 4)
            }

            # Staged без VERSION.json -> IdentityUnproven від ядра.
            $e5 = New-RecEnv -Name 'rep_stagednone'
            $staged5 = New-RecStaged -Environment $e5 -Name 'staged5' -VersionJson 'NONE'
            $r5 = Invoke-RecRepair -Environment $e5 -Plan (New-RecPlan -Environment $e5) -Staged $staged5
            Test-BRAVOCondition -Condition ($r5.status -ceq 'Failed' -and (Test-RecFindingId -Result $r5 -Id 'Repair.IdentityUnproven')) -Name 'UpdateRecovery/Repair/StagedWithoutVersionUnproven' -Failure ($r5 | ConvertTo-Json -Depth 4)

            # Не план Repair -> відмова.
            $e6 = New-RecEnv -Name 'rep_wrongaction'
            & $updateModule $resetCalls
            $r6 = Invoke-RecRepair -Environment $e6 -Plan (New-RecPlan -Environment $e6 -Action 'Update') -Staged (New-RecStaged -Environment $e6 -Name 'staged6')
            Test-BRAVOCondition -Condition ($r6.status -ceq 'Failed' -and (Test-RecFindingId -Result $r6 -Id 'Repair.WrongPlanAction') -and (& $updateModule $getCount 'E6CoreCalls') -eq 0) -Name 'UpdateRecovery/Repair/WrongPlanActionRejected' -Failure ($r6 | ConvertTo-Json -Depth 4)
        }

        # ===== Repair: scope ==================================================
        & {
            $e = New-RecEnv -Name 'rep_scope'
            $staged = New-RecStaged -Environment $e -Name 'staged_scope'
            [IO.File]::WriteAllText((Join-Path $e.Runtime 'BRAVO_FIXTURE.ps1'), '# DAMAGED', (New-Object System.Text.UTF8Encoding $false))
            $before = Get-RecTreeHash -Path $e.Runtime
            & $updateModule $resetCalls
            $r = Invoke-RecRepair -Environment $e -Plan (New-RecPlan -Environment $e) -Staged $staged -Scope 'Scheduler'
            $call = & $updateModule { $script:E6CoreCalls[0] }
            Test-BRAVOCondition -Condition ($r.status -ceq 'Success' -and $call.Scope -ceq 'Scheduler' -and $before -ceq (Get-RecTreeHash -Path $e.Runtime)) -Name 'UpdateRecovery/Repair/ScopeSchedulerPassedRuntimeUntouched' -Failure ($r | ConvertTo-Json -Depth 4)
            & $updateModule $resetCalls
            $r2 = Invoke-RecRepair -Environment $e -Plan (New-RecPlan -Environment $e) -Staged $staged -Scope 'Runtime'
            $call2 = & $updateModule { $script:E6CoreCalls[0] }
            Test-BRAVOCondition -Condition ($r2.status -ceq 'Success' -and $call2.Scope -ceq 'Runtime') -Name 'UpdateRecovery/Repair/ScopeRuntimePassed' -Failure ($r2 | ConvertTo-Json -Depth 4)

            # Ядро без -Scope: All працює, вужчий scope відхиляється (fail closed).
            & $updateModule $installCoreWithoutScope
            & $updateModule $resetCalls
            $r3 = Invoke-RecRepair -Environment $e -Plan (New-RecPlan -Environment $e) -Staged $staged -Scope 'Scheduler'
            Test-BRAVOCondition -Condition ($r3.status -ceq 'Failed' -and (Test-RecFindingId -Result $r3 -Id 'Repair.ScopeUnsupported') -and (& $updateModule $getCount 'E6CoreCalls') -eq 0) -Name 'UpdateRecovery/Repair/ScopeUnsupportedByCoreRefused' -Failure ($r3 | ConvertTo-Json -Depth 4)
            $r4 = Invoke-RecRepair -Environment $e -Plan (New-RecPlan -Environment $e) -Staged $staged -Scope 'All'
            Test-BRAVOCondition -Condition ($r4.status -ceq 'Success' -and (& $updateModule $getCount 'E6CoreCalls') -eq 1) -Name 'UpdateRecovery/Repair/ScopeAllWithoutCoreScopeWorks' -Failure ($r4 | ConvertTo-Json -Depth 4)
        }

        # ===== Repair: захист site-конфігурації і rollback-повідомлення ========
        & {
            # Тут ядро повернуто до версії зі -Scope (перевизначення вище було локальним для scope-блоку,
            # тому відновлюємо ядро-заглушку повторно через її власне визначення нижче).
            & $updateModule {
                function script:Invoke-BRAVODeployment {
                    [CmdletBinding()]
                    param($Plan, [hashtable]$Adapter, [string]$RuntimeRoot, [string]$StateRoot, [string]$LockRoot, [string]$StagingRoot, [string]$BackupRoot, [string]$OperationLockPath, [string]$VersionStatePath, [string]$SourcePath = '', [hashtable]$FaultInjection = $null, [string]$Scope = 'All')
                    [void]$script:E6CoreCalls.Add([pscustomobject]@{ Scope = $Scope; SourcePath = $SourcePath; RuntimeRoot = $RuntimeRoot; HasFault = $false })
                    if ($script:E6CoreMode -eq 'RolledBack') {
                        return (New-BRAVOUpdateDeploymentResult -OperationId ([string]$Plan.operationId) -Action Repair -Status RolledBack -MutationStarted $true)
                    }
                    if ($script:E6CoreMode -eq 'TamperConfig') {
                        [IO.File]::WriteAllText((Join-Path $RuntimeRoot 'BRAVO.local.config'), 'tampered', (New-Object System.Text.UTF8Encoding $false))
                    }
                    return (New-BRAVOUpdateDeploymentResult -OperationId ([string]$Plan.operationId) -Action Repair -Status Success -MutationStarted $true)
                }
            }
            $e = New-RecEnv -Name 'rep_cfg'
            $staged = New-RecStaged -Environment $e -Name 'staged_cfg'
            & $updateModule $resetCalls
            & $updateModule $setStub 'E6CoreMode' 'TamperConfig'
            $r = Invoke-RecRepair -Environment $e -Plan (New-RecPlan -Environment $e) -Staged $staged
            Test-BRAVOCondition -Condition ($r.status -ceq 'Critical' -and $r.exitCode -eq 82 -and (Test-RecFindingId -Result $r -Id 'Repair.SiteConfigChanged')) -Name 'UpdateRecovery/Repair/SiteConfigChangeIsCritical' -Failure ($r | ConvertTo-Json -Depth 4)
            $v = & $updateModule { param($R) Test-BRAVOUpdateDeploymentResult -InputObject $R } $r
            Test-BRAVOCondition -Condition $v.IsValid -Name 'UpdateRecovery/Repair/CriticalResultContractValid' -Failure ($v.Problems -join '; ')

            $e2 = New-RecEnv -Name 'rep_rb'
            $staged2 = New-RecStaged -Environment $e2 -Name 'staged_rb'
            & $updateModule $resetCalls
            & $updateModule $setStub 'E6CoreMode' 'RolledBack'
            $r2 = Invoke-RecRepair -Environment $e2 -Plan (New-RecPlan -Environment $e2) -Staged $staged2
            Test-BRAVOCondition -Condition ($r2.status -ceq 'RolledBack' -and $r2.exitCode -eq 81 -and (Test-RecFindingId -Result $r2 -Id 'Repair.RuntimeStillDamaged')) -Name 'UpdateRecovery/Repair/RollbackSaysRuntimeStillDamaged' -Failure ($r2 | ConvertTo-Json -Depth 4)
            $v2 = & $updateModule { param($R) Test-BRAVOUpdateDeploymentResult -InputObject $R } $r2
            Test-BRAVOCondition -Condition $v2.IsValid -Name 'UpdateRecovery/Repair/RolledBackResultContractValid' -Failure ($v2.Problems -join '; ')
            & $updateModule $resetCalls
        }
    } finally {
        if ($recoveryBase.StartsWith($recoveryTempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $recoveryBase)) {
            Remove-Item -LiteralPath $recoveryBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
