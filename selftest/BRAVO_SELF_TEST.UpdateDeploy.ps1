# Suite UpdateDeploy: фазовий двигун, файловий набір, перевірене копіювання і
# orchestrator Update/Repair (INS-042/044, ENGINE_DESIGN розділи 2 і 4).
# Усе в sandbox у тимчасовому каталозі з унікальним GUID (пробіли й кирилиця в
# шляхах); adapter завжди stub; Task Scheduler, credentials і C:\ProgramData\BRAVO
# не чіпаються. Функції ще не написаних частин (Reconcile/Rollback) підставляються
# заглушками В МОДУЛЬ лише якщо Get-Command їх не знаходить — РОЗДІЛ "STUBS" нижче.

Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking

$deployTestModule = Get-Module BRAVO.Update
$deployTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_UPD_E2_' + [guid]::NewGuid().ToString('N'))
$deployTestPrefix = Join-Path ([IO.Path]::GetTempPath()) 'BRAVO_UPD_E2_'
[void](New-Item -ItemType Directory -Path $deployTestRoot -Force)

try {
    & {
        $utf8 = New-Object System.Text.UTF8Encoding($false)

        # ------------------------------------------------------------------
        # STUBS: лише для відсутніх функцій інших пакетів (E3 Reconcile, E5 Rollback).
        # Реальні функції, коли з'являються, мають пріоритет (Get-Command).
        # ------------------------------------------------------------------
        $stubBodies = [ordered]@{}
        $stubBodies['Get-BRAVOSiteConfigurationBaseline'] = @'
function script:Get-BRAVOSiteConfigurationBaseline {
    [CmdletBinding()] param([Parameter(Mandatory = $true)][string]$RuntimeRoot)
    $r = [ordered]@{}
    foreach ($n in @('BRAVO.local.config', 'BRAVO.config', 'TOOLS_INTEGRITY.json', 'WinSCP.ini')) {
        $p = Join-Path $RuntimeRoot $n
        if ([IO.File]::Exists($p)) { $r[$n] = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } else { $r[$n] = 'absent' }
    }
    return [pscustomobject]$r
}
'@
        $stubBodies['Test-BRAVOSiteConfigurationPreserved'] = @'
function script:Test-BRAVOSiteConfigurationPreserved {
    [CmdletBinding()] param([Parameter(Mandatory = $true)][string]$RuntimeRoot, [Parameter(Mandatory = $true)]$Baseline)
    $now = Get-BRAVOSiteConfigurationBaseline -RuntimeRoot $RuntimeRoot
    foreach ($prop in $Baseline.PSObject.Properties) {
        if ([string]$now.PSObject.Properties[$prop.Name].Value -ne [string]$prop.Value) { return [pscustomobject]@{ name = 'SiteConfigPreserved'; status = 'Fail'; message = ('змінено ' + $prop.Name) } }
    }
    return [pscustomobject]@{ name = 'SiteConfigPreserved'; status = 'Pass'; message = '' }
}
'@
        $stubBodies['Get-BRAVOSchedulerSnapshot'] = @'
function script:Get-BRAVOSchedulerSnapshot {
    [CmdletBinding()] param([Parameter(Mandatory = $true)][hashtable]$Adapter, [string]$RuntimeRoot)
    $tasks = @()
    foreach ($t in @(& $Adapter['GetManagedTasks'])) {
        $tasks += [pscustomobject]@{ path = [string]$t.Path; name = [string]$t.Name; exists = $true; enabled = [bool]$t.Enabled; state = [string]$t.State; isRunning = ([string]$t.State -eq 'Running') }
    }
    return [pscustomobject]@{ schemaVersion = 1; capturedUtc = [datetime]::UtcNow.ToString('o'); taskPath = '\BRAVO\'; tasks = $tasks }
}
'@
        $stubBodies['Suspend-BRAVOManagedTasks'] = @'
function script:Suspend-BRAVOManagedTasks {
    [CmdletBinding()] param([Parameter(Mandatory = $true)]$Snapshot, [Parameter(Mandatory = $true)][hashtable]$Adapter)
    $script:E2Calls.Add('Suspend')
    $disabled = @(); $failed = @()
    foreach ($t in @($Snapshot.tasks)) {
        if (-not $t.enabled) { continue }
        if ($script:E2Config['FailSuspend']) { $failed += $t.name; continue }
        [void](& $Adapter['SetTaskEnabled'] $t.path $t.name $false); $disabled += $t.name
    }
    return [pscustomobject]@{ Disabled = $disabled; Failed = $failed }
}
'@
        $stubBodies['Invoke-BRAVOSchedulerReconcile'] = @'
function script:Invoke-BRAVOSchedulerReconcile {
    [CmdletBinding()] param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$Snapshot)
    $script:E2Calls.Add('Reconcile')
    $run = & $Context.Adapter['InvokeSetupScheduler'] $Context.Paths.RuntimeRoot
    $code = [int]$run.ExitCode
    if ($script:E2Config['FailReconcile']) { $code = 1 }
    return [pscustomobject]@{ Verdict = (Get-BRAVODeploySetupExitVerdict -ExitCode $code); ExitCode = $code; CreatedTasks = @(); RequiescedTasks = @(); Problems = @() }
}
'@
        $stubBodies['Set-BRAVOTaskActivation'] = @'
function script:Set-BRAVOTaskActivation {
    [CmdletBinding()] param($Policy, $Snapshot, [hashtable]$Adapter, [string]$OutcomeStatus)
    $script:E2Calls.Add('Activation:' + $OutcomeStatus)
    $state = 'Active'; if ($OutcomeStatus -ne 'Success') { $state = 'Inactive' }
    return [pscustomobject][ordered]@{ state = $state; tasks = @() }
}
'@
        $stubBodies['Get-BRAVOVersionStateSnapshot'] = @'
function script:Get-BRAVOVersionStateSnapshot {
    [CmdletBinding()] param([Parameter(Mandatory = $true)][string]$VersionStatePath, [Parameter(Mandatory = $true)][string]$OperationDirectory)
    if (-not [IO.File]::Exists($VersionStatePath)) { return [pscustomobject]@{ present = $false; sha256 = $null; recordedVersion = $null; snapshotPath = $null } }
    $snap = Join-Path $OperationDirectory 'version-state.snapshot'
    [IO.File]::Copy($VersionStatePath, $snap, $true)
    return [pscustomobject]@{ present = $true; sha256 = (Get-FileHash -LiteralPath $VersionStatePath -Algorithm SHA256).Hash; recordedVersion = '5.2.6'; snapshotPath = $snap }
}
'@
        $stubBodies['Invoke-BRAVORollback'] = @'
function script:Invoke-BRAVORollback {
    [CmdletBinding()] param($Journal, $Context, $Adapter, $StateRoot, $LockRoot, $OperationLockPath, $VersionStatePath, $FaultInjection)
    $held = ($null -ne $Context.Handles.LifecycleLock)
    $script:E2Calls.Add('Rollback:lifecycleHeld=' + $held)
    if ($script:E2Config['FailRollback']) { throw 'stub rollback failure' }
    $runtime = [string]$Journal.runtimeRoot
    $backupRuntime = Join-Path ([string]$Journal.backup.path) 'runtime'
    $keysDoc = Get-Content -LiteralPath (Join-Path $Context.OperationDirectory 'deploy-keys.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $keysDoc.deployKeys.PSObject.Properties) {
        $inBackup = Join-Path $backupRuntime ($p.Name -replace '/', '\')
        $target = Join-Path $runtime ($p.Name -replace '/', '\')
        if (-not [IO.File]::Exists($inBackup) -and [IO.File]::Exists($target)) { [IO.File]::Delete($target) }
    }
    foreach ($file in Get-ChildItem -LiteralPath $backupRuntime -Recurse -File -Force) {
        $rel = $file.FullName.Substring($backupRuntime.Length + 1)
        $target = Join-Path $runtime $rel
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy($file.FullName, $target, $true)
    }
    [void](Set-BRAVOUpdateJournalState -Journal $Journal -State RolledBack -StateRoot $StateRoot)
    return (New-BRAVOUpdateDeploymentResult -OperationId $Journal.operationId -PlanId $Journal.planId -Action Update -Status RolledBack -MutationStarted $true `
        -Rollback ([pscustomobject][ordered]@{ attempted = $true; status = 'Succeeded'; message = 'stub' }))
}
'@
        $stubText = "`$script:E2Calls = New-Object 'System.Collections.Generic.List[object]'`r`n`$script:E2Config = @{}`r`n"
        $stubbed = New-Object System.Collections.Generic.List[string]
        foreach ($stubName in $stubBodies.Keys) {
            if ($null -eq (Get-Command -Name $stubName -ErrorAction SilentlyContinue)) {
                $stubText += $stubBodies[$stubName] + "`r`n"
                $stubbed.Add($stubName)
            }
        }
        & $deployTestModule ([scriptblock]::Create($stubText))
        $setConfig = { param([string]$Key, $Value) $script:E2Config[$Key] = $Value }
        $clearState = { $script:E2Calls.Clear(); $script:E2Config.Clear() }
        $getCalls = { , @($script:E2Calls.ToArray()) }

        # ------------------------------------------------------------------
        # Допоміжні функції sandbox
        # ------------------------------------------------------------------
        function Write-E2File {
            param([string]$Path, [string]$Text)
            $dir = [IO.Path]::GetDirectoryName($Path)
            if (-not [IO.Directory]::Exists($dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            [IO.File]::WriteAllText($Path, $Text, $utf8)
        }
        function Get-E2Sha { param([string]$Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }
        function Get-E2TreeHash {
            param([string]$Root)
            $lines = New-Object System.Collections.Generic.List[string]
            if (Test-Path -LiteralPath $Root) {
                foreach ($file in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object -Property FullName)) {
                    $lines.Add($file.FullName.Substring($Root.Length) + ':' + (Get-E2Sha -Path $file.FullName))
                }
            }
            return ($lines.ToArray() -join '|')
        }
        function Write-E2Manifest {
            param([string]$Root, [string[]]$Relative)
            $files = [ordered]@{}
            foreach ($rel in $Relative) { $files[$rel] = Get-E2Sha -Path (Join-Path $Root $rel) }
            Write-E2File (Join-Path $Root 'RUNTIME_MANIFEST.json') ((@{ schemaVersion = 1; description = 'fixture'; files = $files } | ConvertTo-Json -Depth 4))
        }

        function New-E2Release {
            # fake-реліз: stage-дерево + integrity-манифест + zip + .sha256 + release-manifest.json
            param([string]$Base, [string]$Tag, [string]$Commit, [string]$GuardText = '# guard stub')
            $version = $Tag.Substring(1)
            $stage = Join-Path $Base 'stage'
            $out = Join-Path $Base 'out'
            [void](New-Item -ItemType Directory -Path $stage -Force)
            [void](New-Item -ItemType Directory -Path $out -Force)
            $versionJson = (@{ product = 'BRAVO-Toolkit'; packageVersion = $version; configSchemaVersion = 1; stateSchemaVersion = 1; updaterVersion = '1.0.0'
                    releaseDate = '2026-09-13'; releaseChannel = 'stable'; buildId = $Commit.Substring(0, 7); sourceCommit = $Commit } | ConvertTo-Json)
            Write-E2File (Join-Path $stage 'VERSION.json') $versionJson
            Write-E2File (Join-Path $stage 'BRAVO_RUNTIME_GUARD.ps1') $GuardText
            Write-E2File (Join-Path $stage 'BRAVO_SETUP.ps1') '# setup stub'
            Write-E2File (Join-Path $stage 'BRAVO_CONFIG_LOADER.ps1') '# loader stub'
            Write-E2File (Join-Path $stage 'Tools\TOOLS_MANIFEST.json') '{}'
            Write-E2File (Join-Path $stage 'modules\X\X.psm1') '# module stub'
            Write-E2File (Join-Path $stage 'docs\README.txt') 'readme'
            Write-E2Manifest -Root $stage -Relative @('BRAVO_RUNTIME_GUARD.ps1', 'BRAVO_SETUP.ps1', 'BRAVO_CONFIG_LOADER.ps1', 'modules\X\X.psm1', 'VERSION.json', 'Tools\TOOLS_MANIFEST.json')
            $entries = New-Object System.Collections.Generic.List[object]
            foreach ($file in (Get-ChildItem -LiteralPath $stage -Recurse -File)) {
                $rel = $file.FullName.Substring($stage.Length + 1).Replace('\', '/')
                $entries.Add([pscustomobject]@{ path = $rel; sizeBytes = [long]$file.Length; sha256 = (Get-E2Sha -Path $file.FullName).ToLowerInvariant() })
            }
            $zipName = 'BRAVO-Toolkit-{0}.zip' -f $version
            $zipPath = Join-Path $out $zipName
            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($file in (Get-ChildItem -LiteralPath $stage -Recurse -File)) {
                    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $file.FullName.Substring($stage.Length + 1).Replace('\', '/'))
                }
            } finally { $zip.Dispose() }
            $zipHash = (Get-E2Sha -Path $zipPath).ToLowerInvariant()
            Write-E2File ($zipPath + '.sha256') ("{0} *{1}`n" -f $zipHash, $zipName)
            $manifestPath = Join-Path $out 'release-manifest.json'
            $manifest = [pscustomobject]@{
                schemaVersion = 1; product = 'BRAVO-Toolkit'; packageVersion = $version; releaseChannel = 'stable'; releaseDate = '2026-09-13'
                sourceCommit = $Commit; buildId = $Commit.Substring(0, 7); archiveRef = $Tag; archiveCommit = $Commit; tag = $Tag; generatedUtc = '2026-09-13T00:00:00Z'
                artifact = [pscustomobject]@{ name = $zipName; sizeBytes = (Get-Item -LiteralPath $zipPath).Length; sha256 = $zipHash }; files = $entries.ToArray()
            }
            Write-E2File $manifestPath ($manifest | ConvertTo-Json -Depth 5)
            return [pscustomobject]@{ Stage = $stage; Zip = $zipPath; Tag = $Tag; Version = $version; ZipName = $zipName; ZipSha = $zipHash.ToUpperInvariant(); ManifestSha = (Get-E2Sha -Path $manifestPath) }
        }

        function Add-E2SiteFiles {
            param([string]$Runtime)
            Write-E2File (Join-Path $Runtime 'BRAVO.config') 'site config'
            Write-E2File (Join-Path $Runtime 'BRAVO.local.config') '{"local":1}'
            Write-E2File (Join-Path $Runtime 'TOOLS_INTEGRITY.json') '{}'
            Write-E2File (Join-Path $Runtime 'WinSCP.ini') 'ini'
            Write-E2File (Join-Path $Runtime 'LOGS\a.log') 'лог'
            Write-E2File (Join-Path $Runtime 'BAZA\db.dat') 'дані'
        }

        function New-E2UpdateRuntime {
            # runtime 5.2.6: Unchanged (BRAVO_SETUP), Change (guard/loader/VERSION/manifest), Remove (old_only, старий модуль)
            param([string]$Runtime, [switch]$WithUnknownOther, [switch]$WithRogueScript)
            $versionJson = (@{ product = 'BRAVO-Toolkit'; packageVersion = '5.2.6'; releaseChannel = 'stable'; buildId = 'aaaaaaa'; sourceCommit = ('a' * 40) } | ConvertTo-Json)
            Write-E2File (Join-Path $Runtime 'VERSION.json') $versionJson
            Write-E2File (Join-Path $Runtime 'BRAVO_RUNTIME_GUARD.ps1') '# guard old'
            Write-E2File (Join-Path $Runtime 'BRAVO_SETUP.ps1') '# setup stub'
            Write-E2File (Join-Path $Runtime 'BRAVO_CONFIG_LOADER.ps1') '# loader OLD'
            Write-E2File (Join-Path $Runtime 'Tools\TOOLS_MANIFEST.json') '{}'
            Write-E2File (Join-Path $Runtime 'old_only.ps1') '# old only'
            Write-E2File (Join-Path $Runtime 'modules\Старий модуль\old.psm1') '# old module'
            Write-E2Manifest -Root $Runtime -Relative @('VERSION.json', 'BRAVO_RUNTIME_GUARD.ps1', 'BRAVO_SETUP.ps1', 'BRAVO_CONFIG_LOADER.ps1', 'Tools\TOOLS_MANIFEST.json', 'old_only.ps1', 'modules\Старий модуль\old.psm1')
            Add-E2SiteFiles -Runtime $Runtime
            if ($WithUnknownOther) { Write-E2File (Join-Path $Runtime 'notes.txt') 'нотатки оператора' }
            if ($WithRogueScript) { Write-E2File (Join-Path $Runtime 'rogue.ps1') '# not in any manifest' }
        }

        function New-E2Sandbox {
            param([string]$Name, $Release, [ValidateSet('Update', 'Repair')][string]$Action = 'Update', [string]$InstalledVersion = '5.2.6', [switch]$WithUnknownOther, [switch]$WithRogueScript, [string]$RepairReleaseStage = '', [switch]$NoCorrupt)
            $base = Join-Path $deployTestRoot ($Name + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $runtime = Join-Path $base 'Програми Toolkit\runtime'
            if ($Action -eq 'Update') {
                New-E2UpdateRuntime -Runtime $runtime -WithUnknownOther:$WithUnknownOther -WithRogueScript:$WithRogueScript
            } else {
                # Repair: runtime = встановлена збірка з пошкодженим guard
                [void](New-Item -ItemType Directory -Path $runtime -Force)
                Copy-Item -Path (Join-Path $RepairReleaseStage '*') -Destination $runtime -Recurse -Force
                Add-E2SiteFiles -Runtime $runtime
                if (-not $NoCorrupt) { Write-E2File (Join-Path $runtime 'BRAVO_RUNTIME_GUARD.ps1') '# CORRUPTED guard' }
            }
            $sb = [ordered]@{
                Base = $base; Runtime = $runtime
                State = (Join-Path $base 'state'); Lock = (Join-Path $base 'locks'); Staging = (Join-Path $base 'staging'); Backup = (Join-Path $base 'backup')
                OpLock = (Join-Path $base 'locks\BRAVO_OPERATION.lock'); VersionState = (Join-Path $base 'state\BRAVO_VERSION_STATE.json')
            }
            [void](New-Item -ItemType Directory -Path $sb.State -Force)
            [void](New-Item -ItemType Directory -Path $sb.Lock -Force)
            Write-E2File $sb.VersionState '{"highestVersion":"5.2.6","highestVersionFull":"5.2.6"}'
            $state = @{ Hook = $null; Offset = 0; Running = $false; Tasks = @{ BRAVO_A = $true; BRAVO_B = $false } }
            $sb['AdapterState'] = $state
            $sb['Adapter'] = @{
                GetManagedTasks       = { param($TaskPath, $RuntimeRoot) if ($null -ne $state.Hook) { & $state.Hook }; $st = 'Ready'; if ($state.Running) { $st = 'Running' }; @(foreach ($n in @('BRAVO_A', 'BRAVO_B')) { [pscustomobject]@{ Name = $n; Path = '\BRAVO\'; Exists = $true; State = $st; Enabled = [bool]$state.Tasks[$n] } }) }.GetNewClosure()
                SetTaskEnabled        = { param($TaskPath, $Name, $Enabled) $state.Tasks[$Name] = [bool]$Enabled; [pscustomobject]@{ Success = $true; Message = '' } }.GetNewClosure()
                InvokeGuard           = { param($RuntimeRoot, $LogPath) [pscustomobject]@{ ExitCode = 0; Output = ''; TimedOut = $false } }
                InvokeSetupScheduler  = { param($RuntimeRoot, $LogPath) [pscustomobject]@{ ExitCode = 0; Output = ''; TimedOut = $false } }
                InvokeSetupValidate   = { param($RuntimeRoot, $LogPath) [pscustomobject]@{ ExitCode = 0; Output = ''; TimedOut = $false } }
                InvokeSelfTest        = { param($RuntimeRoot, $LogPath) [pscustomobject]@{ ExitCode = 0; Output = ''; TimedOut = $false } }
                TestCredentialPresence = { param($RuntimeRoot, $Component) [pscustomobject]@{ Component = $Component; Presence = 'Found'; ExitCode = 0 } }
                GetEffectiveConfiguration = { param($RuntimeRoot) [pscustomobject]@{ Success = $true; ExitCode = 0; Message = ''; Configuration = [pscustomobject]@{ schedulerSettings = [pscustomobject]@{ TaskPath = '\BRAVO\'; Backup = [pscustomobject]@{ TaskName = 'BRAVO_A'; Enabled = $true }; Maintenance = [pscustomobject]@{ TaskName = 'BRAVO_B'; Enabled = $false } } } } }
                Now                   = { [datetime]::UtcNow.AddMinutes($state.Offset) }.GetNewClosure()
            }
            $source = [pscustomobject][ordered]@{ kind = 'Offline'; tag = $Release.Tag; artifactName = $Release.ZipName; artifactSha256 = $Release.ZipSha; manifestSha256 = $Release.ManifestSha
                packageVersion = $Release.Version; releaseChannel = 'stable'; prereleaseAuthorized = $false }
            $pre = Get-BRAVODeploymentPreconditions -RuntimeRoot $sb.Runtime -StateRoot $sb.State -ArtifactSha256 $Release.ZipSha -ManifestSha256 $Release.ManifestSha -Adapter $sb.Adapter
            $fingerprint = Get-BRAVOUpdatePreconditionsFingerprint -Preconditions $pre
            $changes = [pscustomobject][ordered]@{ filesAdded = 0; filesChanged = 0; filesRemoved = 0
                configuration = [pscustomobject][ordered]@{ localConfigPreserved = $true; legacyConfigPreserved = $true; delta = @() }
                scheduler = [pscustomobject][ordered]@{ tasks = @(); activationPolicy = 'ActivateOnSuccessOnly' } }
            $tests = [pscustomobject][ordered]@{ planned = @([pscustomobject][ordered]@{ id = 'SelfTest'; title = 'Self-test' }); skipped = @() }
            $sb['Plan'] = New-BRAVOUpdateDeploymentPlan -Action $Action -RuntimeRoot $sb.Runtime -StagingRoot $sb.Staging -BackupRoot $sb.Backup -Source $source `
                -CurrentVersion $InstalledVersion -TargetVersion $Release.Version -Changes $changes -Tests $tests -PreconditionsFingerprint $fingerprint
            $sb['Zip'] = $Release.Zip
            return [pscustomobject]$sb
        }

        function Invoke-E2Deploy {
            param($Sandbox, [hashtable]$Fault = $null, [string]$Scope = 'All', [switch]$NoSource)
            $arguments = @{
                Plan = $Sandbox.Plan; Adapter = $Sandbox.Adapter; RuntimeRoot = $Sandbox.Runtime; StateRoot = $Sandbox.State; LockRoot = $Sandbox.Lock
                StagingRoot = $Sandbox.Staging; BackupRoot = $Sandbox.Backup; OperationLockPath = $Sandbox.OpLock; VersionStatePath = $Sandbox.VersionState
            }
            if (-not $NoSource) { $arguments['SourcePath'] = $Sandbox.Zip }
            if ($null -ne $Fault) { $arguments['FaultInjection'] = $Fault }
            if ($Scope -ne 'All') { $arguments['Scope'] = $Scope }
            return (Invoke-BRAVODeployment @arguments)
        }
        function Read-E2Journal {
            param($Sandbox)
            return (Read-BRAVOUpdateJournal -Path (Get-BRAVOUpdateJournalPath -StateRoot $Sandbox.State -OperationId ([string]$Sandbox.Plan.operationId))).Journal
        }
        function Get-E2CallList { return @(& $deployTestModule $getCalls) }
        function Get-E2RollbackCount {
            # Заглушка пише виклики в E2Calls; реальний Rollback лишає слід у журналі (стан/rollbackAttempts).
            param($Sandbox)
            $stubCalls = @(Get-E2CallList | Where-Object { $_ -like 'Rollback*' }).Count
            if ($stubCalls -gt 0) { return $stubCalls }
            $journalPath = Get-BRAVOUpdateJournalPath -StateRoot $Sandbox.State -OperationId ([string]$Sandbox.Plan.operationId)
            if (-not [IO.File]::Exists($journalPath)) { return 0 }
            $journal = (Read-BRAVOUpdateJournal -Path $journalPath).Journal
            if ($null -eq $journal) { return 0 }
            if (@('RolledBack', 'Critical') -contains [string]$journal.state) { return 1 }
            return 0
        }        function Test-E2LocksFree {
            param($Sandbox)
            $life = Enter-BRAVOUpdateLifecycleLock -LockRoot $Sandbox.Lock -OperationId ([guid]::NewGuid().ToString())
            $op = Enter-BRAVOUpdateOperationLock -OperationLockPath $Sandbox.OpLock -OperationId ([guid]::NewGuid().ToString()) -PackageVersion '0'
            $free = ($life.Success -and $op.Success)
            if ($life.Success) { Exit-BRAVOUpdateLifecycleLock -Lock $life }
            if ($op.Success) { Exit-BRAVOUpdateOperationLock -Lock $op }
            return $free
        }
        function Get-E2FindingIds { param($Result) return @(@($Result.findings) | ForEach-Object { [string]$_.id }) }
        function Remove-E2Junction { param([string]$Path) if (Test-Path -LiteralPath $Path) { [IO.Directory]::Delete($Path, $false) } }

        $release = New-E2Release -Base (Join-Path $deployTestRoot 'release-530') -Tag 'v5.3.0' -Commit ('d77f3b4d021c3d3d53565a604a2497d1d962dcb4')
        $repairCommit = ('a' * 40)
        $releaseRepair = New-E2Release -Base (Join-Path $deployTestRoot 'release-526') -Tag 'v5.2.6' -Commit $repairCommit

        # ================================================================
        # 1. Remove-BRAVOUpdateOperationDirectory
        # ================================================================
        & {
            $parent = Join-Path $deployTestRoot 'rm тест'
            $opId = [guid]::NewGuid().ToString()
            $dir = Join-Path $parent $opId
            Write-E2File (Join-Path $dir 'a\b\file.txt') 'x'
            Write-E2File (Join-Path $dir 'ro.txt') 'x'
            [IO.File]::SetAttributes((Join-Path $dir 'ro.txt'), [IO.FileAttributes]::ReadOnly)
            $canaryDir = Join-Path $deployTestRoot 'canary'
            Write-E2File (Join-Path $canaryDir 'keep.txt') 'keep'
            [void](New-Item -ItemType Junction -Path (Join-Path $dir 'link') -Target $canaryDir)
            $r = Remove-BRAVOUpdateOperationDirectory -Path $dir -ExpectedParent $parent -OperationId $opId
            Test-BRAVOCondition -Condition ($r.Existed -and $r.Removed -and (-not (Test-Path -LiteralPath $dir))) -Name 'UpdateDeploy/Remove-Dir-Removed' -Failure 'Каталог операції (з read-only файлом) має бути видалено.'
            Test-BRAVOCondition -Condition ([IO.File]::Exists((Join-Path $canaryDir 'keep.txt'))) -Name 'UpdateDeploy/Remove-Dir-JunctionTargetKept' -Failure 'Ціль junction не повинна видалятись.'
            $none = Remove-BRAVOUpdateOperationDirectory -Path $dir -ExpectedParent $parent -OperationId $opId
            Test-BRAVOCondition -Condition ((-not $none.Existed) -and (-not $none.Removed)) -Name 'UpdateDeploy/Remove-Dir-Absent' -Failure 'Відсутній каталог не помилка.'
            $threw = 0
            foreach ($case in @(@($dir, $parent, 'not-a-guid'), @((Join-Path $parent ([guid]::NewGuid().ToString())), $parent, $opId), @((Join-Path $parent $opId), (Join-Path $parent 'other'), $opId))) {
                try { [void](Remove-BRAVOUpdateOperationDirectory -Path $case[0] -ExpectedParent $case[1] -OperationId $case[2]) } catch { $threw++ }
            }
            Test-BRAVOCondition -Condition ($threw -eq 3) -Name 'UpdateDeploy/Remove-Dir-GuardsThrow' -Failure 'Некоректний id, інше ім''я та інший корінь мають відхилятись винятком.'
        }

        # ================================================================
        # 2. Copy-BRAVOUpdateVerifiedFile
        # ================================================================
        & {
            $src = Join-Path $deployTestRoot 'copy src\файл.txt'
            Write-E2File $src 'вміст'
            $dst = Join-Path $deployTestRoot 'copy dst\підкаталог\файл.txt'
            $r = Copy-BRAVOUpdateVerifiedFile -Source $src -Destination $dst -ExpectedSha256 (Get-E2Sha -Path $src)
            Test-BRAVOCondition -Condition ((Get-E2Sha -Path $dst) -eq (Get-E2Sha -Path $src) -and $r.Bytes -gt 0) -Name 'UpdateDeploy/Copy-Ok' -Failure 'Файл має бути скопійовано з правильним хешем (шлях із кирилицею).'
            Write-E2File $dst 'старе'
            $before = Get-E2Sha -Path $dst
            $threw = $false
            try { [void](Copy-BRAVOUpdateVerifiedFile -Source $src -Destination $dst -ExpectedSha256 ('0' * 64)) } catch { $threw = $true }
            $left = @(Get-ChildItem -LiteralPath (Split-Path -Parent $dst) -Force | Where-Object { $_.Name -like '.*' })
            Test-BRAVOCondition -Condition ($threw -and ((Get-E2Sha -Path $dst) -eq $before) -and $left.Count -eq 0) -Name 'UpdateDeploy/Copy-MismatchKeepsDestination' -Failure 'Розбіжність хешу: виняток, ціль без змін, тимчасових файлів немає.'
            [void](Copy-BRAVOUpdateVerifiedFile -Source $src -Destination $dst -ExpectedSha256 (Get-E2Sha -Path $src))
            Test-BRAVOCondition -Condition ((Get-E2Sha -Path $dst) -eq (Get-E2Sha -Path $src)) -Name 'UpdateDeploy/Copy-ReplacesExisting' -Failure 'Наявний файл має бути атомарно замінено.'
        }

        # ================================================================
        # 3. Get-BRAVODeploymentFileSet, Save-BRAVODeploymentKeySet
        # ================================================================
        & {
            $sb = New-E2Sandbox -Name 'fileset' -Release $release -WithUnknownOther
            $set = Get-BRAVODeploymentFileSet -StagedRoot $release.Stage -RuntimeRoot $sb.Runtime -OldManifestPath (Join-Path $sb.Runtime 'RUNTIME_MANIFEST.json')
            Test-BRAVOCondition -Condition ((@($set.Unchanged) -contains 'BRAVO_SETUP.ps1') -and (@($set.Unchanged).Count -eq 2)) -Name 'UpdateDeploy/FileSet-Unchanged' -Failure 'Unchanged = BRAVO_SETUP.ps1 і Tools/TOOLS_MANIFEST.json.'
            Test-BRAVOCondition -Condition ((@($set.Add) -contains 'modules/X/X.psm1') -and (@($set.Add) -contains 'docs/README.txt')) -Name 'UpdateDeploy/FileSet-Add' -Failure 'Нові файли (включно з не-manifest) мають бути в Add.'
            Test-BRAVOCondition -Condition ((@($set.Change) -contains 'BRAVO_RUNTIME_GUARD.ps1') -and (@($set.Change) -contains 'BRAVO_CONFIG_LOADER.ps1') -and (@($set.Change) -contains 'VERSION.json') -and (@($set.Change) -contains 'RUNTIME_MANIFEST.json')) -Name 'UpdateDeploy/FileSet-Change' -Failure 'Змінені файли мають бути в Change.'
            Test-BRAVOCondition -Condition ((@($set.Remove) -contains 'old_only.ps1') -and (@($set.Remove) -contains 'modules/Старий модуль/old.psm1') -and (@($set.Remove).Count -eq 2)) -Name 'UpdateDeploy/FileSet-Remove' -Failure 'Remove = ключі старого manifest без відповідника в staged.'
            Test-BRAVOCondition -Condition ((@($set.UnknownScripts).Count -eq 0) -and (@($set.UnknownOther) -contains 'notes.txt') -and (@($set.NamespaceViolations).Count -eq 0) -and (@($set.ReparsePoints).Count -eq 0)) -Name 'UpdateDeploy/FileSet-UnknownOtherOnly' -Failure 'notes.txt = UnknownOther; site-owned файли (BRAVO.config, LOGS, BAZA) не фігурують.'
            Test-BRAVOCondition -Condition ((-not $set.DeployKeys.Contains('BRAVO.config')) -and ($set.DeployKeys.Contains('docs/README.txt'))) -Name 'UpdateDeploy/FileSet-DeployKeysIncludeNonManifest' -Failure 'DeployKeys = усі staged-файли поза site-owned.'

            $rogue = New-E2Sandbox -Name 'fileset-rogue' -Release $release -WithRogueScript
            $rogueSet = Get-BRAVODeploymentFileSet -StagedRoot $release.Stage -RuntimeRoot $rogue.Runtime -OldManifestPath (Join-Path $rogue.Runtime 'RUNTIME_MANIFEST.json')
            Test-BRAVOCondition -Condition ((@($rogueSet.UnknownScripts) -contains 'rogue.ps1') -and (@($rogueSet.UnknownScripts).Count -eq 1)) -Name 'UpdateDeploy/FileSet-UnknownScript' -Failure 'rogue.ps1 поза обома manifest = UnknownScripts.'

            $noManifest = Get-BRAVODeploymentFileSet -StagedRoot $release.Stage -RuntimeRoot $rogue.Runtime -OldManifestPath (Join-Path $rogue.Runtime 'no-such.json')
            Test-BRAVOCondition -Condition ((-not $noManifest.OldManifestPresent) -and (@($noManifest.UnknownScripts).Count -gt 1) -and (@($noManifest.Remove).Count -eq 0)) -Name 'UpdateDeploy/FileSet-NoOldManifest' -Failure 'Без старого manifest усі невідомі runtime-скрипти — UnknownScripts, Remove порожній.'

            # 0 файлів
            $emptyStage = Join-Path $deployTestRoot 'empty-stage'
            [void](New-Item -ItemType Directory -Path $emptyStage -Force)
            $emptyRuntime = Join-Path $deployTestRoot 'empty-runtime'
            $emptySet = Get-BRAVODeploymentFileSet -StagedRoot $emptyStage -RuntimeRoot $emptyRuntime
            Test-BRAVOCondition -Condition ((@($emptySet.Add).Count -eq 0) -and (@($emptySet.Change).Count -eq 0) -and ($emptySet.DeployKeys.Count -eq 0)) -Name 'UpdateDeploy/FileSet-Zero' -Failure 'Порожній staged і відсутній runtime: усе порожнє.'
            # 1 файл
            $oneStage = Join-Path $deployTestRoot 'one-stage'
            Write-E2File (Join-Path $oneStage 'one.ps1') '# one'
            $oneSet = Get-BRAVODeploymentFileSet -StagedRoot $oneStage -RuntimeRoot $emptyRuntime
            Test-BRAVOCondition -Condition ((@($oneSet.Add).Count -eq 1) -and ($oneSet.Add[0] -eq 'one.ps1')) -Name 'UpdateDeploy/FileSet-One' -Failure 'Один staged-файл на порожньому runtime = один Add.'

            # namespace violation + reparse
            $nsStage = Join-Path $deployTestRoot 'ns-stage'
            Write-E2File (Join-Path $nsStage 'BRAVO.config') 'evil'
            Write-E2File (Join-Path $nsStage 'LOGS\x.log') 'evil'
            Write-E2File (Join-Path $nsStage 'ok.txt') 'ok'
            $nsSet = Get-BRAVODeploymentFileSet -StagedRoot $nsStage -RuntimeRoot $emptyRuntime
            Test-BRAVOCondition -Condition ((@($nsSet.NamespaceViolations).Count -eq 2) -and (@($nsSet.Add) -contains 'ok.txt') -and (@($nsSet.Add).Count -eq 1)) -Name 'UpdateDeploy/FileSet-NamespaceViolation' -Failure 'Staged BRAVO.config і LOGS\x.log — NamespaceViolations.'
            $jTarget = Join-Path $deployTestRoot 'junction-target'
            Write-E2File (Join-Path $jTarget 'secret.ps1') '# should not be scanned'
            $jRuntime = Join-Path $deployTestRoot 'junction-runtime'
            Write-E2File (Join-Path $jRuntime 'a.txt') 'a'
            [void](New-Item -ItemType Junction -Path (Join-Path $jRuntime 'jl') -Target $jTarget)
            try {
                $jSet = Get-BRAVODeploymentFileSet -StagedRoot $oneStage -RuntimeRoot $jRuntime
                Test-BRAVOCondition -Condition ((@($jSet.ReparsePoints) -contains 'runtime:jl') -and (@($jSet.UnknownScripts).Count -eq 0)) -Name 'UpdateDeploy/FileSet-ReparsePoint' -Failure 'Junction у runtime — ReparsePoints; у нього не заходимо.'
            } finally { Remove-E2Junction -Path (Join-Path $jRuntime 'jl') }

            $opDir = Join-Path $deployTestRoot 'opdir keys'
            $keys = Save-BRAVODeploymentKeySet -FileSet $set -OperationDirectory $opDir
            $parsed = Get-Content -LiteralPath $keys.Path -Raw -Encoding UTF8 | ConvertFrom-Json
            Test-BRAVOCondition -Condition (($keys.Sha256 -eq (Get-E2Sha -Path $keys.Path)) -and ($parsed.schemaVersion -eq 1) -and (@($parsed.remove).Count -eq 2) -and ($null -ne $parsed.deployKeys.PSObject.Properties['VERSION.json'])) -Name 'UpdateDeploy/KeySet-Saved' -Failure 'deploy-keys.json: схема, ключі, remove, SHA-256 файлу.'
        }

        # ================================================================
        # 4. Контекст і виконавець фаз
        # ================================================================
        function New-E2PhaseContext {
            param([hashtable]$Fault = $null)
            $sb = New-E2Sandbox -Name 'phase' -Release $release
            $opDir = Join-Path $sb.State ('Operations\' + $sb.Plan.operationId)
            [void](New-Item -ItemType Directory -Path $opDir -Force)
            $journal = New-BRAVOUpdateJournal -StateRoot $sb.State -Plan $sb.Plan
            $paths = [pscustomobject]@{ RuntimeRoot = $sb.Runtime; StateRoot = $sb.State; LockRoot = $sb.Lock; StagingRoot = $sb.Staging; BackupRoot = $sb.Backup; OperationLockPath = $sb.OpLock; VersionStatePath = $sb.VersionState }
            $arguments = @{ Plan = $sb.Plan; Adapter = $sb.Adapter; Paths = $paths; OperationDirectory = $opDir; Journal = $journal }
            if ($null -ne $Fault) { $arguments['FaultInjection'] = $Fault }
            return [pscustomobject]@{ Sandbox = $sb; Context = (New-BRAVOUpdateOperationContext @arguments); OperationDirectory = $opDir }
        }
        & {
            $pc = New-E2PhaseContext
            $c = $pc.Context
            Test-BRAVOCondition -Condition (($c.OperationId -eq [string]$pc.Sandbox.Plan.operationId) -and ($c.Findings.Count -eq 0) -and (-not $c.MutationStarted) -and (-not $c.CancelRequested) -and ($null -eq $c.Handles.LifecycleLock)) -Name 'UpdateDeploy/Context-Shape' -Failure 'Контекст: operationId, порожні Findings, без mutation/cancel/lock.'
            $threwPaths = $false
            try { [void](New-BRAVOUpdateOperationContext -Plan $pc.Sandbox.Plan -Adapter $pc.Sandbox.Adapter -Paths ([pscustomobject]@{ RuntimeRoot = 'x' }) -OperationDirectory $pc.OperationDirectory -Journal $c.Journal) } catch { $threwPaths = $true }
            Test-BRAVOCondition -Condition $threwPaths -Name 'UpdateDeploy/Context-RejectsIncompletePaths' -Failure 'Неповні Paths мають відхилятись.'

            $order = New-Object System.Collections.Generic.List[string]
            $result = Invoke-BRAVOUpdatePhase -Context $c -Phase 'Backup' -ProgressPhase Backup -Durable -Action { param($Context) $order.Add('action'); 'value-1'; 'value-2' }
            $journal = Read-BRAVOUpdateJournal -Path (Get-BRAVOUpdateJournalPath -StateRoot $pc.Sandbox.State -OperationId $c.OperationId)
            $phase = @($journal.Journal.phases)[0]
            Test-BRAVOCondition -Condition (($result -eq 'value-2') -and ([string]$phase.phase -eq 'Backup') -and ($null -ne $phase.completedUtc) -and ([string]$phase.outcome -eq 'Succeeded') -and ($c.LastPhase -eq 'Backup')) -Name 'UpdateDeploy/Phase-DurableIntentCompletion' -Failure 'Durable-фаза: intent+completion у журналі, повертається останній вивід Action.'
            $events = @(Read-BRAVOUpdateProgressEvents -Path (Join-Path $pc.OperationDirectory 'progress.jsonl'))
            Test-BRAVOCondition -Condition (($events.Count -eq 2) -and ($events[0].status -eq 'Started') -and ($events[1].status -eq 'Completed') -and ($events[1].sequence -gt $events[0].sequence)) -Name 'UpdateDeploy/Phase-ProgressEvents' -Failure 'Started і Completed із зростаючим sequence.'

            # Throw у кожній точці фази
            foreach ($point in @('Before', 'AfterIntent', 'AfterSideEffect', 'AfterComplete')) {
                $fc = New-E2PhaseContext -Fault @{ ('P.' + $point) = 'Throw' }
                $acted = $false
                $threw = $false
                try { [void](Invoke-BRAVOUpdatePhase -Context $fc.Context -Phase 'P' -ProgressPhase Backup -Durable -Action { param($Context) $script:e2acted = $true }) } catch { $threw = $true }
                $fj = Read-BRAVOUpdateJournal -Path (Get-BRAVOUpdateJournalPath -StateRoot $fc.Sandbox.State -OperationId $fc.Context.OperationId)
                $ph = @($fj.Journal.phases)
                $expectIntent = ($point -ne 'Before')
                $intentOk = ($ph.Count -eq $(if ($expectIntent) { 1 } else { 0 }))
                $outcomeOk = $true
                if ($point -eq 'AfterIntent' -or $point -eq 'AfterSideEffect') { $outcomeOk = ([string]$ph[0].outcome -eq 'Failed') }
                if ($point -eq 'AfterComplete') { $outcomeOk = ([string]$ph[0].outcome -eq 'Succeeded') }
                Test-BRAVOCondition -Condition ($threw -and $intentOk -and $outcomeOk) -Name ('UpdateDeploy/Phase-Throw-' + $point) -Failure ('Throw у ' + $point + ': виняток, журнал узгоджений (intent/Failed/Succeeded).')
            }
            # Crash лишає intent без completion
            $cc = New-E2PhaseContext -Fault @{ 'P.AfterSideEffect' = 'Crash' }
            $kind = ''
            try { [void](Invoke-BRAVOUpdatePhase -Context $cc.Context -Phase 'P' -ProgressPhase Backup -Durable -Action { param($Context) $null }) } catch { $kind = (Get-BRAVOUpdateExceptionKind -ErrorRecord $_).Kind }
            $cj = Read-BRAVOUpdateJournal -Path (Get-BRAVOUpdateJournalPath -StateRoot $cc.Sandbox.State -OperationId $cc.Context.OperationId)
            Test-BRAVOCondition -Condition (($kind -eq 'Crash') -and ($null -eq @($cj.Journal.phases)[0].completedUtc)) -Name 'UpdateDeploy/Phase-CrashLeavesIntentOpen' -Failure 'Crash: тип Crash і intent без completion.'
            # Cancel fault -> наступна фаза зупиняється
            $kc = New-E2PhaseContext -Fault @{ 'A.AfterComplete' = 'Cancel' }
            [void](Invoke-BRAVOUpdatePhase -Context $kc.Context -Phase 'A' -ProgressPhase Backup -Action { param($Context) $null })
            $cancelKind = ''
            try { [void](Invoke-BRAVOUpdatePhase -Context $kc.Context -Phase 'B' -ProgressPhase Backup -Action { param($Context) $null }) } catch { $cancelKind = (Get-BRAVOUpdateExceptionKind -ErrorRecord $_).Kind }
            Test-BRAVOCondition -Condition (($cancelKind -eq 'Cancel') -and [IO.File]::Exists((Join-Path $kc.OperationDirectory 'control\cancel'))) -Name 'UpdateDeploy/Phase-CancelBeforeMutation' -Failure 'cancel-файл до mutation = Cancel на старті наступної фази.'
            $kc.Context.MutationStarted = $true
            $cancelKind = ''
            try { [void](Invoke-BRAVOUpdatePhase -Context $kc.Context -Phase 'C' -ProgressPhase Backup -Action { param($Context) $null }) } catch { $cancelKind = (Get-BRAVOUpdateExceptionKind -ErrorRecord $_).Kind }
            Test-BRAVOCondition -Condition ($cancelKind -eq 'CancelAfterMutation') -Name 'UpdateDeploy/Phase-CancelAfterMutation' -Failure 'cancel після mutation = CancelAfterMutation.'
            [void](Invoke-BRAVOUpdatePhase -Context $kc.Context -Phase 'D' -ProgressPhase Backup -IgnoreCancel -Action { param($Context) $null })
            Test-BRAVOCondition -Condition (@($kc.Context.Findings | Where-Object { $_.id -eq 'Operation.CancelIgnored' }).Count -eq 1) -Name 'UpdateDeploy/Phase-IgnoreCancelFinding' -Failure 'IgnoreCancel: фаза виконується, finding Operation.CancelIgnored.'
        }

        # ================================================================
        # 5. Invoke-BRAVORuntimeDeploy
        # ================================================================
        & {
            $pc = New-E2PhaseContext
            $sb = $pc.Sandbox
            $set = Get-BRAVODeploymentFileSet -StagedRoot $release.Stage -RuntimeRoot $sb.Runtime -OldManifestPath (Join-Path $sb.Runtime 'RUNTIME_MANIFEST.json')
            $siteBefore = (Get-E2Sha -Path (Join-Path $sb.Runtime 'BRAVO.local.config')) + (Get-E2Sha -Path (Join-Path $sb.Runtime 'LOGS\a.log'))
            $deployed = Invoke-BRAVORuntimeDeploy -Context $pc.Context -StagedRoot $release.Stage -FileSet $set
            $match = Test-BRAVODeployRuntimeMatchesManifest -RuntimeRoot $sb.Runtime -ManifestPath (Join-Path $release.Stage 'RUNTIME_MANIFEST.json') -ExcludeDirs @((Get-BRAVOUpdateSiteOwnedPaths).Dirs)
            Test-BRAVOCondition -Condition ((@($deployed.Errors).Count -eq 0) -and $match.IsMatch) -Name 'UpdateDeploy/Deploy-RuntimeMatchesStagedManifest' -Failure 'Після Deploy runtime збігається зі staged manifest.'
            Test-BRAVOCondition -Condition ((-not [IO.File]::Exists((Join-Path $sb.Runtime 'old_only.ps1'))) -and (-not [IO.Directory]::Exists((Join-Path $sb.Runtime 'modules\Старий модуль'))) -and [IO.File]::Exists((Join-Path $sb.Runtime 'docs\README.txt'))) -Name 'UpdateDeploy/Deploy-RemovesOldKeepsNew' -Failure 'Старі manifest-файли й порожній каталог видалені, нові додані.'
            Test-BRAVOCondition -Condition ($siteBefore -eq ((Get-E2Sha -Path (Join-Path $sb.Runtime 'BRAVO.local.config')) + (Get-E2Sha -Path (Join-Path $sb.Runtime 'LOGS\a.log')))) -Name 'UpdateDeploy/Deploy-SiteOwnedUntouched' -Failure 'Site-owned файли не змінюються.'

            $own = New-E2Sandbox -Name 'deploy-notes' -Release $release -WithUnknownOther
            $oc = New-E2PhaseContext
            $oc.Context.Paths.RuntimeRoot = $own.Runtime
            $ownSet = Get-BRAVODeploymentFileSet -StagedRoot $release.Stage -RuntimeRoot $own.Runtime -OldManifestPath (Join-Path $own.Runtime 'RUNTIME_MANIFEST.json')
            [void](Invoke-BRAVORuntimeDeploy -Context $oc.Context -StagedRoot $release.Stage -FileSet $ownSet)
            Test-BRAVOCondition -Condition ([IO.File]::Exists((Join-Path $own.Runtime 'notes.txt'))) -Name 'UpdateDeploy/Deploy-KeepsUnknownNonScript' -Failure 'Невідомий не-скрипт лишається при видаленні файлів старого manifest.'

            $fi = New-E2Sandbox -Name 'deploy-fault' -Release $release
            $fc = New-E2PhaseContext -Fault @{ 'Deploy.AfterFileCount' = 2 }
            $fc.Context.Paths.RuntimeRoot = $fi.Runtime
            $fiSet = Get-BRAVODeploymentFileSet -StagedRoot $release.Stage -RuntimeRoot $fi.Runtime -OldManifestPath (Join-Path $fi.Runtime 'RUNTIME_MANIFEST.json')
            $threw = $false
            try { [void](Invoke-BRAVORuntimeDeploy -Context $fc.Context -StagedRoot $release.Stage -FileSet $fiSet) } catch { $threw = $true }
            Test-BRAVOCondition -Condition $threw -Name 'UpdateDeploy/Deploy-AfterFileCountFault' -Failure 'Deploy.AfterFileCount=2 кидає виняток після 2 файлів.'
        }

        # ================================================================
        # 6. Orchestrator: успіх
        # ================================================================
        & {
            & $deployTestModule $clearState
            $sb = New-E2Sandbox -Name 'ok' -Release $release
            $siteSha = Get-E2TreeHash -Root (Join-Path $sb.Runtime 'LOGS')
            $result = Invoke-E2Deploy -Sandbox $sb
            $validity = Test-BRAVOUpdateDeploymentResult -InputObject $result
            Test-BRAVOCondition -Condition (($result.status -eq 'Success') -and ($result.exitCode -eq 0) -and $validity.IsValid) -Name 'UpdateDeploy/Orchestrator-Success' -Failure ('Повний успіх очікується; status=' + $result.status + ' findings=' + ((@($result.findings) | ForEach-Object { $_.id + '[' + $_.details + ']' }) -join ',') + ' problems=' + ($validity.Problems -join ';'))
            $match = Test-BRAVODeployRuntimeMatchesManifest -RuntimeRoot $sb.Runtime -ManifestPath (Join-Path $release.Stage 'RUNTIME_MANIFEST.json') -ExcludeDirs @((Get-BRAVOUpdateSiteOwnedPaths).Dirs)
            Test-BRAVOCondition -Condition ($match.IsMatch -and ($siteSha -eq (Get-E2TreeHash -Root (Join-Path $sb.Runtime 'LOGS')))) -Name 'UpdateDeploy/Orchestrator-RuntimeAndSiteState' -Failure 'Runtime == staged, LOGS без змін.'
            $journal = Read-E2Journal -Sandbox $sb
            $phases = @($journal.phases | ForEach-Object { [string]$_.phase })
            Test-BRAVOCondition -Condition (([string]$journal.state -eq 'Committed') -and $journal.mutationStarted -and (($phases -join ',') -eq 'Backup,QuiesceTasks,Deploy,ConfigureScheduler,Activate,Commit') -and ($null -ne $journal.deployKeys) -and ($null -ne $journal.baseline)) -Name 'UpdateDeploy/Orchestrator-JournalCommitted' -Failure ('Журнал Committed, durable-фази у порядку; phases=' + ($phases -join ','))
            Test-BRAVOCondition -Condition ((-not [IO.Directory]::Exists((Join-Path $sb.Staging ([string]$sb.Plan.operationId)))) -and [IO.Directory]::Exists((Join-Path $sb.Backup ([string]$sb.Plan.operationId))) -and [IO.File]::Exists((Join-Path $sb.State ('ConsumedPlans\' + $sb.Plan.planId)))) -Name 'UpdateDeploy/Orchestrator-StagingRemovedBackupKept' -Failure 'Staging видалено, backup лишається, план споживено.'
            Test-BRAVOCondition -Condition (Test-E2LocksFree -Sandbox $sb) -Name 'UpdateDeploy/Orchestrator-LocksReleased' -Failure 'Після успіху обидва lock-и звільнено.'
            $opDir = Join-Path $sb.State ('Operations\' + $sb.Plan.operationId)
            $events = @(Read-BRAVOUpdateProgressEvents -Path (Join-Path $opDir 'progress.jsonl'))
            $monotonic = $true; for ($i = 1; $i -lt $events.Count; $i++) { if ([long]$events[$i].sequence -le [long]$events[$i - 1].sequence) { $monotonic = $false } }
            Test-BRAVOCondition -Condition (($events.Count -gt 10) -and $monotonic -and ($events[$events.Count - 1].phase -eq 'Commit') -and ($events[$events.Count - 1].status -eq 'Completed')) -Name 'UpdateDeploy/Orchestrator-ProgressMonotonic' -Failure 'Прогрес: sequence зростає, останнє — Commit/Completed.'
            Test-BRAVOCondition -Condition ([IO.File]::Exists((Join-Path $opDir 'deploy-keys.json')) -and [IO.File]::Exists((Join-Path $opDir 'scheduler-snapshot.json'))) -Name 'UpdateDeploy/Orchestrator-OperationDirArtifacts' -Failure 'deploy-keys.json і scheduler-snapshot.json у каталозі операції.'
            Test-BRAVOCondition -Condition ((Get-E2RollbackCount -Sandbox $sb) -eq 0 -or $stubbed -notcontains 'Invoke-BRAVORollback') -Name 'UpdateDeploy/Orchestrator-NoRollbackOnSuccess' -Failure 'Rollback не викликається при успіху.'

            # Replay того самого плану
            $again = Invoke-E2Deploy -Sandbox $sb
            Test-BRAVOCondition -Condition (($again.status -eq 'Failed') -and ($again.reasonCode -eq 'PlanStale')) -Name 'UpdateDeploy/Replay-AfterSuccess' -Failure 'Повторний запуск використаного плану = Failed/PlanStale.'
        }

        # SuccessWithWarnings: сторонній не-скрипт
        & {
            $sb = New-E2Sandbox -Name 'warn' -Release $release -WithUnknownOther
            $result = Invoke-E2Deploy -Sandbox $sb
            Test-BRAVOCondition -Condition (($result.status -eq 'SuccessWithWarnings') -and ($result.exitCode -eq 10) -and ((Get-E2FindingIds -Result $result) -contains 'Deploy.UnknownFiles') -and [IO.File]::Exists((Join-Path $sb.Runtime 'notes.txt'))) -Name 'UpdateDeploy/Orchestrator-SuccessWithWarnings' -Failure ('Сторонній файл = SuccessWithWarnings, файл лишається; status=' + $result.status)
        }

        # ================================================================
        # 7. Orchestrator: відмови до межі (runtime незмінний за хешем)
        # ================================================================
        function Assert-E2PreMutationFailure {
            param([string]$Name, $Sandbox, $Result, [string]$Reason, [string]$Before)
            $opId = [string]$Sandbox.Plan.operationId
            $after = Get-E2TreeHash -Root $Sandbox.Runtime
            Test-BRAVOCondition -Condition (($Result.status -eq 'Failed') -and ($Result.reasonCode -eq $Reason) -and (-not $Result.mutationStarted)) -Name ('UpdateDeploy/' + $Name + '-StatusReason') -Failure ('Очікується Failed/' + $Reason + ', отримано ' + $Result.status + '/' + $Result.reasonCode + ' findings=' + ((Get-E2FindingIds -Result $Result) -join ','))
            Test-BRAVOCondition -Condition ($after -eq $Before) -Name ('UpdateDeploy/' + $Name + '-RuntimeUnchanged') -Failure 'Runtime має бути незмінним за хешем.'
            Test-BRAVOCondition -Condition (Test-E2LocksFree -Sandbox $Sandbox) -Name ('UpdateDeploy/' + $Name + '-LocksReleased') -Failure 'Lock-и звільнено.'
        }
        function Assert-E2Abandoned {
            param([string]$Name, $Sandbox)
            $opId = [string]$Sandbox.Plan.operationId
            $journal = Read-E2Journal -Sandbox $Sandbox
            Test-BRAVOCondition -Condition (([string]$journal.state -eq 'Abandoned') -and (-not [IO.Directory]::Exists((Join-Path $Sandbox.Staging $opId))) -and (-not [IO.Directory]::Exists((Join-Path $Sandbox.Backup $opId)))) -Name ('UpdateDeploy/' + $Name + '-AbandonedCleaned') -Failure 'Журнал Abandoned, staging і backup операції прибрано.'
        }

        & {
            # unknown script
            $sb = New-E2Sandbox -Name 'rogue' -Release $release -WithRogueScript
            $before = Get-E2TreeHash -Root $sb.Runtime
            $r = Invoke-E2Deploy -Sandbox $sb
            Assert-E2PreMutationFailure -Name 'UnknownScript' -Sandbox $sb -Result $r -Reason 'Blocked' -Before $before
            Test-BRAVOCondition -Condition ((Get-E2FindingIds -Result $r) -contains 'Deploy.UnknownScript') -Name 'UpdateDeploy/UnknownScript-Finding' -Failure 'Blocker Deploy.UnknownScript.'
            Assert-E2Abandoned -Name 'UnknownScript' -Sandbox $sb

            # tamper zip після плану
            $tam = New-E2Sandbox -Name 'tamper-zip' -Release $release
            $tamZip = Join-Path $tam.Base 'tampered\BRAVO-Toolkit-5.3.0.zip'
            Write-E2File $tamZip 'not a zip'
            Copy-Item -LiteralPath ($release.Zip + '.sha256') -Destination ($tamZip + '.sha256')
            Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $release.Zip) 'release-manifest.json') -Destination (Join-Path (Split-Path -Parent $tamZip) 'release-manifest.json')
            $tam.Zip = $tamZip
            $tamBefore = Get-E2TreeHash -Root $tam.Runtime
            $tr = Invoke-E2Deploy -Sandbox $tam
            Assert-E2PreMutationFailure -Name 'TamperZip' -Sandbox $tam -Result $tr -Reason 'VerificationFailed' -Before $tamBefore
            Test-BRAVOCondition -Condition ($tr.exitCode -eq 42) -Name 'UpdateDeploy/TamperZip-ExitCode42' -Failure 'Підміна артефакта — код 42.'
            Assert-E2Abandoned -Name 'TamperZip' -Sandbox $tam

            # replay (план уже споживано)
            $rp = New-E2Sandbox -Name 'replay' -Release $release
            Write-E2File (Join-Path $rp.State ('ConsumedPlans\' + $rp.Plan.planId)) '{}'
            $rpBefore = Get-E2TreeHash -Root $rp.Runtime
            $rr = Invoke-E2Deploy -Sandbox $rp
            Assert-E2PreMutationFailure -Name 'ReplayConsumed' -Sandbox $rp -Result $rr -Reason 'PlanStale' -Before $rpBefore
            Test-BRAVOCondition -Condition ((Get-E2FindingIds -Result $rr) -contains 'Plan.AlreadyConsumed') -Name 'UpdateDeploy/Replay-Finding' -Failure 'Finding Plan.AlreadyConsumed.'

            # lifecycle lock зайнято
            $lk = New-E2Sandbox -Name 'lockbusy' -Release $release
            $held = Enter-BRAVOUpdateLifecycleLock -LockRoot $lk.Lock -OperationId ([guid]::NewGuid().ToString())
            $lkBefore = Get-E2TreeHash -Root $lk.Runtime
            try { $lr = Invoke-E2Deploy -Sandbox $lk } finally { Exit-BRAVOUpdateLifecycleLock -Lock $held }
            Test-BRAVOCondition -Condition (($lr.status -eq 'Failed') -and ($lr.reasonCode -eq 'Blocked') -and ($lr.exitCode -eq 20) -and ($lkBefore -eq (Get-E2TreeHash -Root $lk.Runtime))) -Name 'UpdateDeploy/LockBusy-Lifecycle' -Failure 'Зайнятий lifecycle lock = Failed/Blocked, код 20, runtime незмінний.'
            Test-BRAVOCondition -Condition (-not [IO.File]::Exists((Join-Path $lk.State ('ConsumedPlans\' + $lk.Plan.planId)))) -Name 'UpdateDeploy/LockBusy-PlanNotConsumed' -Failure 'План не споживається при зайнятому lock.'

            # operation lock зайнято (U9)
            $ol = New-E2Sandbox -Name 'oplockbusy' -Release $release
            $heldOp = Enter-BRAVOUpdateOperationLock -OperationLockPath $ol.OpLock -OperationId ([guid]::NewGuid().ToString()) -PackageVersion '1'
            $olBefore = Get-E2TreeHash -Root $ol.Runtime
            try { $or = Invoke-E2Deploy -Sandbox $ol } finally { Exit-BRAVOUpdateOperationLock -Lock $heldOp }
            Assert-E2PreMutationFailure -Name 'OperationLockBusy' -Sandbox $ol -Result $or -Reason 'Blocked' -Before $olBefore
            Test-BRAVOCondition -Condition ($or.exitCode -eq 20) -Name 'UpdateDeploy/OperationLockBusy-Exit20' -Failure 'Зайнятий BRAVO_OPERATION.lock — код 20.'
            Assert-E2Abandoned -Name 'OperationLockBusy' -Sandbox $ol

            # керована задача виконується
            $rt = New-E2Sandbox -Name 'taskrunning' -Release $release
            $rt.AdapterState['Running'] = $true
            $rtBefore = Get-E2TreeHash -Root $rt.Runtime
            $rtr = Invoke-E2Deploy -Sandbox $rt
            Assert-E2PreMutationFailure -Name 'TaskRunning' -Sandbox $rt -Result $rtr -Reason 'Blocked' -Before $rtBefore
            Assert-E2Abandoned -Name 'TaskRunning' -Sandbox $rt

            # прострочений план і змінена конфігурація
            $ex = New-E2Sandbox -Name 'expired' -Release $release
            $ex.AdapterState['Offset'] = 120
            $exBefore = Get-E2TreeHash -Root $ex.Runtime
            $exr = Invoke-E2Deploy -Sandbox $ex
            Assert-E2PreMutationFailure -Name 'ExpiredPlan' -Sandbox $ex -Result $exr -Reason 'PlanStale' -Before $exBefore
            $cf = New-E2Sandbox -Name 'configchanged' -Release $release
            Write-E2File (Join-Path $cf.Runtime 'BRAVO.local.config') '{"local":2}'
            $cfBefore = Get-E2TreeHash -Root $cf.Runtime
            $cfr = Invoke-E2Deploy -Sandbox $cf
            Assert-E2PreMutationFailure -Name 'ConfigChanged' -Sandbox $cf -Result $cfr -Reason 'PlanStale' -Before $cfBefore

            # BRAVO_ALLOW_DOWNGRADE
            $ad = New-E2Sandbox -Name 'allowdowngrade' -Release $release
            $adBefore = Get-E2TreeHash -Root $ad.Runtime
            $env:BRAVO_ALLOW_DOWNGRADE = '1'
            try { $adr = Invoke-E2Deploy -Sandbox $ad } finally { Remove-Item -Path 'Env:\BRAVO_ALLOW_DOWNGRADE' -ErrorAction SilentlyContinue }
            Test-BRAVOCondition -Condition (($adr.status -eq 'Failed') -and ($adr.reasonCode -eq 'Blocked') -and ($adr.exitCode -eq 35) -and ($adBefore -eq (Get-E2TreeHash -Root $ad.Runtime)) -and (-not [IO.File]::Exists((Join-Path $ad.State ('ConsumedPlans\' + $ad.Plan.planId))))) -Name 'UpdateDeploy/AllowDowngradeRefused' -Failure 'BRAVO_ALLOW_DOWNGRADE у середовищі: Failed/Blocked 35 без жодних змін.'

            # Install-план у Update-orchestrator
            $wa = New-E2Sandbox -Name 'wrongaction' -Release $release
            $wa.Plan.action = 'Install'
            $war = Invoke-E2Deploy -Sandbox $wa
            Test-BRAVOCondition -Condition (($war.status -eq 'Failed') -and ((Get-E2FindingIds -Result $war) -contains 'Plan.WrongAction')) -Name 'UpdateDeploy/WrongAction' -Failure 'Orchestrator відхиляє Install-план.'
        }

        # ================================================================
        # 8. Throw у кожній фазі
        # ================================================================
        & {
            $preBoundary = @('Acquire', 'Verify', 'Stage', 'StageValidation', 'PlanRecheck', 'Backup', 'OperationLock', 'Baseline', 'MutationBoundary')
            foreach ($phaseName in $preBoundary) {
                & $deployTestModule $clearState
                $sb = New-E2Sandbox -Name ('throw-' + $phaseName) -Release $release
                $before = Get-E2TreeHash -Root $sb.Runtime
                $r = Invoke-E2Deploy -Sandbox $sb -Fault @{ ($phaseName + '.Before') = 'Throw' }
                $rollbackCalls = @(for ($ri = 0; $ri -lt (Get-E2RollbackCount -Sandbox $sb); $ri++) { $ri })
                Test-BRAVOCondition -Condition (($r.status -eq 'Failed') -and ($r.reasonCode -eq 'Error') -and (-not $r.mutationStarted) -and ($before -eq (Get-E2TreeHash -Root $sb.Runtime)) -and ($rollbackCalls.Count -eq 0)) -Name ('UpdateDeploy/Throw-' + $phaseName + '-Before-PreMutation') -Failure ('Throw у ' + $phaseName + ' до межі: Failed/Error, runtime незмінний, rollback не викликано; status=' + $r.status + '/' + $r.reasonCode)
                $journal = Read-E2Journal -Sandbox $sb
                Test-BRAVOCondition -Condition (([string]$journal.state -eq 'Abandoned') -and (Test-E2LocksFree -Sandbox $sb)) -Name ('UpdateDeploy/Throw-' + $phaseName + '-AbandonedLocksFree') -Failure 'Журнал Abandoned, lock-и вільні.'
            }
            # Backup після side effect: каталог backup операції прибрано
            $bs = New-E2Sandbox -Name 'throw-backup-after' -Release $release
            $bBefore = Get-E2TreeHash -Root $bs.Runtime
            $br = Invoke-E2Deploy -Sandbox $bs -Fault @{ 'Backup.AfterSideEffect' = 'Throw' }
            Assert-E2PreMutationFailure -Name 'Throw-Backup-AfterSideEffect' -Sandbox $bs -Result $br -Reason 'Error' -Before $bBefore
            Assert-E2Abandoned -Name 'Throw-Backup-AfterSideEffect' -Sandbox $bs

            $postBoundary = @('QuiesceTasks', 'Deploy', 'ConfigureScheduler', 'Validate', 'Commit')
            foreach ($phaseName in $postBoundary) {
                & $deployTestModule $clearState
                $sb = New-E2Sandbox -Name ('throw-' + $phaseName) -Release $release
                $before = Get-E2TreeHash -Root $sb.Runtime
                $r = Invoke-E2Deploy -Sandbox $sb -Fault @{ ($phaseName + '.Before') = 'Throw' }
                $rollbackCalls = @(for ($ri = 0; $ri -lt (Get-E2RollbackCount -Sandbox $sb); $ri++) { $ri })
                Test-BRAVOCondition -Condition (($r.status -eq 'RolledBack') -and ($r.exitCode -eq 81) -and $r.mutationStarted -and ($rollbackCalls.Count -eq 1)) -Name ('UpdateDeploy/Throw-' + $phaseName + '-RollbackInvoked') -Failure ('Throw у ' + $phaseName + ' після межі: RolledBack, Invoke-BRAVORollback викликано один раз; status=' + $r.status + ' calls=' + $rollbackCalls.Count)
                if ($stubbed -contains 'Invoke-BRAVORollback') {
                    Test-BRAVOCondition -Condition ($before -eq (Get-E2TreeHash -Root $sb.Runtime)) -Name ('UpdateDeploy/Throw-' + $phaseName + '-RuntimeRestored') -Failure 'Після відкату runtime == початковий (за хешем).'
                }
                $journal = Read-E2Journal -Sandbox $sb
                Test-BRAVOCondition -Condition (([string]$journal.state -eq 'RolledBack') -and (Test-E2LocksFree -Sandbox $sb)) -Name ('UpdateDeploy/Throw-' + $phaseName + '-JournalRolledBack') -Failure 'Журнал RolledBack, lock-и вільні.'
            }
            foreach ($point in @('MutationBoundary.AfterSideEffect', 'Deploy.AfterSideEffect', 'Deploy.AfterIntent', 'Backup.AfterComplete')) {
                & $deployTestModule $clearState
                $sb = New-E2Sandbox -Name 'throw-point' -Release $release
                $before = Get-E2TreeHash -Root $sb.Runtime
                $r = Invoke-E2Deploy -Sandbox $sb -Fault @{ $point = 'Throw' }
                $expected = 'RolledBack'; if ($point -eq 'Backup.AfterComplete') { $expected = 'Failed' }
                Test-BRAVOCondition -Condition ($r.status -eq $expected) -Name ('UpdateDeploy/Throw-Point-' + $point) -Failure ('Throw у ' + $point + ': очікується ' + $expected + ', отримано ' + $r.status)
                if ($expected -eq 'Failed') { Test-BRAVOCondition -Condition ($before -eq (Get-E2TreeHash -Root $sb.Runtime)) -Name ('UpdateDeploy/Throw-Point-' + $point + '-Unchanged') -Failure 'Runtime незмінний.' }
            }
            # часткове копіювання
            & $deployTestModule $clearState
            $pf = New-E2Sandbox -Name 'partial' -Release $release
            $pfBefore = Get-E2TreeHash -Root $pf.Runtime
            $pr = Invoke-E2Deploy -Sandbox $pf -Fault @{ 'Deploy.AfterFileCount' = 2 }
            Test-BRAVOCondition -Condition (($pr.status -eq 'RolledBack') -and ((Get-E2RollbackCount -Sandbox $pf) -eq 1)) -Name 'UpdateDeploy/Throw-PartialDeploy-RolledBack' -Failure 'Збій посеред копіювання: RolledBack.'
            if ($stubbed -contains 'Invoke-BRAVORollback') { Test-BRAVOCondition -Condition ($pfBefore -eq (Get-E2TreeHash -Root $pf.Runtime)) -Name 'UpdateDeploy/Throw-PartialDeploy-Restored' -Failure 'Після часткового розгортання й відкату runtime повернувся.' }

            # Activate: збій після успішної Validate не відкочує
            & $deployTestModule $clearState
            $av = New-E2Sandbox -Name 'throw-activate' -Release $release
            $avr = Invoke-E2Deploy -Sandbox $av -Fault @{ 'Activate.Before' = 'Throw' }
            $avJournal = Read-E2Journal -Sandbox $av
            $avMatch = Test-BRAVODeployRuntimeMatchesManifest -RuntimeRoot $av.Runtime -ManifestPath (Join-Path $release.Stage 'RUNTIME_MANIFEST.json') -ExcludeDirs @((Get-BRAVOUpdateSiteOwnedPaths).Dirs)
            Test-BRAVOCondition -Condition (($avr.status -eq 'SuccessWithWarnings') -and ($avr.taskActivation.state -eq 'Unknown') -and ([string]$avJournal.state -eq 'Committed') -and $avMatch.IsMatch -and ((Get-E2RollbackCount -Sandbox $av) -eq 0)) -Name 'UpdateDeploy/Throw-Activate-NoRollback' -Failure ('Збій Activate: SuccessWithWarnings, Unknown, Committed, без rollback; status=' + $avr.status)
        }

        # ================================================================
        # 9. Tamper staged посеред операції, збої кроків, Crash, Cancel
        # ================================================================
        & {
            & $deployTestModule $clearState
            $sb = New-E2Sandbox -Name 'tamper-staged' -Release $release
            $before = Get-E2TreeHash -Root $sb.Runtime
            $tamperState = @{ Count = 0 }
            $stagedTarget = Join-Path $sb.Staging ($sb.Plan.operationId + '\runtime\BRAVO_CONFIG_LOADER.ps1')
            $sb.AdapterState['Hook'] = { if ([IO.File]::Exists($stagedTarget)) { [IO.File]::WriteAllText($stagedTarget, '# TAMPERED', (New-Object System.Text.UTF8Encoding($false))) } }.GetNewClosure()
            $r = Invoke-E2Deploy -Sandbox $sb
            Test-BRAVOCondition -Condition (($r.status -eq 'RolledBack') -and ((Get-E2RollbackCount -Sandbox $sb) -eq 1)) -Name 'UpdateDeploy/Tamper-StagedAfterVerify-RolledBack' -Failure ('Підміна staged між перевіркою й копіюванням: RolledBack; status=' + $r.status)
            if ($stubbed -contains 'Invoke-BRAVORollback') { Test-BRAVOCondition -Condition ($before -eq (Get-E2TreeHash -Root $sb.Runtime)) -Name 'UpdateDeploy/Tamper-StagedAfterVerify-Restored' -Failure 'Runtime відновлено.' }

            # Suspend / Reconcile / Validation збої -> rollback
            foreach ($config in @('FailSuspend', 'FailReconcile')) {
                if (($stubbed -notcontains 'Suspend-BRAVOManagedTasks') -and $config -eq 'FailSuspend') { continue }
                if (($stubbed -notcontains 'Invoke-BRAVOSchedulerReconcile') -and $config -eq 'FailReconcile') { continue }
                & $deployTestModule $clearState
                & $deployTestModule $setConfig $config $true
                $fs = New-E2Sandbox -Name ('cfg-' + $config) -Release $release
                $fr = Invoke-E2Deploy -Sandbox $fs
                Test-BRAVOCondition -Condition (($fr.status -eq 'RolledBack') -and ($fr.mutationStarted)) -Name ('UpdateDeploy/' + $config + '-RolledBack') -Failure ($config + ' після межі веде до відкату; status=' + $fr.status)
                & $deployTestModule $clearState
            }
            # Guard після Deploy != 0 -> Validate Fail -> rollback
            & $deployTestModule $clearState
            $gv = New-E2Sandbox -Name 'guardfail' -Release $release
            $gvState = @{ Calls = 0 }
            $gv.Adapter['InvokeGuard'] = { param($RuntimeRoot, $LogPath) $gvState['Calls'] = [int]$gvState['Calls'] + 1; $code = 0; if ([int]$gvState['Calls'] -eq 2) { $code = 33 }; [pscustomobject]@{ ExitCode = $code; Output = ''; TimedOut = $false } }.GetNewClosure()
            $gvr = Invoke-E2Deploy -Sandbox $gv
            Test-BRAVOCondition -Condition (($gvr.status -eq 'RolledBack') -and (@($gvr.validation | Where-Object { $_.name -eq 'Guard' -and $_.status -eq 'Fail' }).Count -ge 1)) -Name 'UpdateDeploy/ValidationFail-RolledBackWithItems' -Failure ('Guard!=0 після Deploy: RolledBack, validation містить Guard/Fail; status=' + $gvr.status)

            # Rollback кидає -> Critical
            if ($stubbed -contains 'Invoke-BRAVORollback') {
                & $deployTestModule $clearState
                & $deployTestModule $setConfig 'FailRollback' $true
                $cr = New-E2Sandbox -Name 'critical' -Release $release
                $crr = Invoke-E2Deploy -Sandbox $cr -Fault @{ 'Deploy.Before' = 'Throw' }
                $crj = Read-E2Journal -Sandbox $cr
                Test-BRAVOCondition -Condition (($crr.status -eq 'Critical') -and ($crr.exitCode -eq 82) -and ([string]$crj.state -eq 'Critical') -and ($crr.rollback.status -eq 'Failed')) -Name 'UpdateDeploy/RollbackFailure-Critical' -Failure ('Збій rollback = Critical/82, журнал Critical; status=' + $crr.status)
                & $deployTestModule $clearState
            }

            # Crash: виняток назовні, журнал Open, handle-и звільнені
            & $deployTestModule $clearState
            $cs = New-E2Sandbox -Name 'crash' -Release $release
            $crashed = $false
            try { [void](Invoke-E2Deploy -Sandbox $cs -Fault @{ 'Deploy.AfterSideEffect' = 'Crash' }) } catch { if ((Get-BRAVOUpdateExceptionKind -ErrorRecord $_).Kind -eq 'Crash') { $crashed = $true } }
            $csj = Read-E2Journal -Sandbox $cs
            Test-BRAVOCondition -Condition ($crashed -and ([string]$csj.state -eq 'Open') -and $csj.mutationStarted -and (Test-E2LocksFree -Sandbox $cs) -and ((Get-E2RollbackCount -Sandbox $cs) -eq 0)) -Name 'UpdateDeploy/Crash-NoRollbackJournalOpen' -Failure 'Crash: виняток, журнал Open з mutationStarted, rollback не викликано, lock-и звільнені.'
            if ($null -ne (Get-Command -Name 'Invoke-BRAVORecovery' -ErrorAction SilentlyContinue)) {
                $rec = Invoke-BRAVORecovery -StateRoot $cs.State -LockRoot $cs.Lock -OperationLockPath $cs.OpLock -Adapter $cs.Adapter -VersionStatePath $cs.VersionState
                $csj2 = Read-E2Journal -Sandbox $cs
                Test-BRAVOCondition -Condition ([string]$csj2.state -ne 'Open') -Name 'UpdateDeploy/Crash-RecoveryClosesJournal' -Failure ('Recovery закриває журнал після Crash; status=' + $rec.status)
            }
            # Crash до mutation
            $cb = New-E2Sandbox -Name 'crash-pre' -Release $release
            $crashed = $false
            try { [void](Invoke-E2Deploy -Sandbox $cb -Fault @{ 'Backup.AfterSideEffect' = 'Crash' }) } catch { if ((Get-BRAVOUpdateExceptionKind -ErrorRecord $_).Kind -eq 'Crash') { $crashed = $true } }
            $cbj = Read-E2Journal -Sandbox $cb
            Test-BRAVOCondition -Condition ($crashed -and ([string]$cbj.state -eq 'Open') -and (-not $cbj.mutationStarted)) -Name 'UpdateDeploy/Crash-BeforeMutation' -Failure 'Crash до межі: журнал Open без mutationStarted (InterruptedUpdate).'

            # Cancel до межі
            & $deployTestModule $clearState
            $c1 = New-E2Sandbox -Name 'cancel-before' -Release $release
            $c1Before = Get-E2TreeHash -Root $c1.Runtime
            $c1r = Invoke-E2Deploy -Sandbox $c1 -Fault @{ 'Backup.AfterComplete' = 'Cancel' }
            Assert-E2PreMutationFailure -Name 'CancelBefore' -Sandbox $c1 -Result $c1r -Reason 'Cancelled' -Before $c1Before
            Assert-E2Abandoned -Name 'CancelBefore' -Sandbox $c1
            Test-BRAVOCondition -Condition ((Get-E2RollbackCount -Sandbox $c1) -eq 0) -Name 'UpdateDeploy/CancelBefore-NoRollback' -Failure 'Cancel до межі не викликає rollback.'
            # Cancel після межі
            & $deployTestModule $clearState
            $c2 = New-E2Sandbox -Name 'cancel-after' -Release $release
            $c2Before = Get-E2TreeHash -Root $c2.Runtime
            $c2r = Invoke-E2Deploy -Sandbox $c2 -Fault @{ 'Deploy.AfterComplete' = 'Cancel' }
            Test-BRAVOCondition -Condition (($c2r.status -eq 'RolledBack') -and ((Get-E2FindingIds -Result $c2r) -contains 'Operation.CancelledAfterMutation') -and ((Get-E2RollbackCount -Sandbox $c2) -eq 1)) -Name 'UpdateDeploy/CancelAfter-RolledBack' -Failure ('Cancel після межі: RolledBack + Operation.CancelledAfterMutation; status=' + $c2r.status)
            if ($stubbed -contains 'Invoke-BRAVORollback') { Test-BRAVOCondition -Condition ($c2Before -eq (Get-E2TreeHash -Root $c2.Runtime)) -Name 'UpdateDeploy/CancelAfter-Restored' -Failure 'Runtime відновлено.' }
            # Cancel перед Activate (U16)
            & $deployTestModule $clearState
            $c3 = New-E2Sandbox -Name 'cancel-u16' -Release $release
            $c3r = Invoke-E2Deploy -Sandbox $c3 -Fault @{ 'Validate.AfterComplete' = 'Cancel' }
            Test-BRAVOCondition -Condition ($c3r.status -eq 'RolledBack') -Name 'UpdateDeploy/CancelBeforeActivate-RolledBack' -Failure 'Cancel до Activate (U16) = rollback.'
            # Cancel під час Activate ігнорується
            & $deployTestModule $clearState
            $c4 = New-E2Sandbox -Name 'cancel-activate' -Release $release
            $c4r = Invoke-E2Deploy -Sandbox $c4 -Fault @{ 'Activate.AfterIntent' = 'Cancel' }
            Test-BRAVOCondition -Condition (($c4r.status -eq 'SuccessWithWarnings') -and ((Get-E2FindingIds -Result $c4r) -contains 'Operation.CancelIgnored') -and ((Get-E2RollbackCount -Sandbox $c4) -eq 0)) -Name 'UpdateDeploy/CancelDuringActivate-Ignored' -Failure ('Cancel під час Activate ігнорується з finding; status=' + $c4r.status)
        }

        # ================================================================
        # 10. Repair (спільне ядро)
        # ================================================================
        & {
            & $deployTestModule $clearState
            $rep = New-E2Sandbox -Name 'repair' -Release $releaseRepair -Action Repair -InstalledVersion '5.2.6' -RepairReleaseStage $releaseRepair.Stage
            $r = Invoke-E2Deploy -Sandbox $rep
            $match = Test-BRAVODeployRuntimeMatchesManifest -RuntimeRoot $rep.Runtime -ManifestPath (Join-Path $releaseRepair.Stage 'RUNTIME_MANIFEST.json') -ExcludeDirs @((Get-BRAVOUpdateSiteOwnedPaths).Dirs)
            Test-BRAVOCondition -Condition (($r.status -eq 'Success') -and $match.IsMatch) -Name 'UpdateDeploy/Repair-Success' -Failure ('Repair тієї самої збірки відновлює пошкоджений guard; status=' + $r.status + ' findings=' + ((Get-E2FindingIds -Result $r) -join ','))

            $mm = New-E2Sandbox -Name 'repair-mismatch' -Release $releaseRepair -Action Repair -InstalledVersion '5.2.6' -RepairReleaseStage $releaseRepair.Stage
            Write-E2File (Join-Path $mm.Runtime 'VERSION.json') ((@{ packageVersion = '5.2.6'; buildId = 'bbbbbbb'; sourceCommit = ('b' * 40) } | ConvertTo-Json))
            # VERSION.json змінився -> fingerprint плану стане іншим, тому перебудовуємо план
            $pre = Get-BRAVODeploymentPreconditions -RuntimeRoot $mm.Runtime -StateRoot $mm.State -ArtifactSha256 $releaseRepair.ZipSha -ManifestSha256 $releaseRepair.ManifestSha -Adapter $mm.Adapter
            $mm.Plan.preconditionsFingerprint = Get-BRAVOUpdatePreconditionsFingerprint -Preconditions $pre
            $mmBefore = Get-E2TreeHash -Root $mm.Runtime
            $mr = Invoke-E2Deploy -Sandbox $mm
            Assert-E2PreMutationFailure -Name 'RepairMismatch' -Sandbox $mm -Result $mr -Reason 'Blocked' -Before $mmBefore
            Test-BRAVOCondition -Condition ((Get-E2FindingIds -Result $mr) -contains 'Repair.VersionMismatch') -Name 'UpdateDeploy/RepairMismatch-Finding' -Failure 'Finding Repair.VersionMismatch.'

            # Scope Scheduler: без staging/backup/deploy
            & $deployTestModule $clearState
            $ss = New-E2Sandbox -Name 'repair-sched' -Release $releaseRepair -Action Repair -InstalledVersion '5.2.6' -RepairReleaseStage $releaseRepair.Stage -NoCorrupt
            $ssBefore = Get-E2TreeHash -Root $ss.Runtime
            $ssr = Invoke-E2Deploy -Sandbox $ss -Scope Scheduler -NoSource
            $ssj = Read-E2Journal -Sandbox $ss
            $ssPhases = @($ssj.phases | ForEach-Object { [string]$_.phase })
            Test-BRAVOCondition -Condition (($ssPhases -notcontains 'Backup') -and ($ssPhases -notcontains 'Deploy') -and ($ssPhases -contains 'ConfigureScheduler') -and ($ssBefore -eq (Get-E2TreeHash -Root $ss.Runtime)) -and (-not [IO.Directory]::Exists((Join-Path $ss.Staging ([string]$ss.Plan.operationId))))) -Name 'UpdateDeploy/Repair-SchedulerScope-SkipsDeploy' -Failure ('Scope Scheduler пропускає Acquire..Backup і Deploy; фази=' + ($ssPhases -join ',') + ' status=' + $ssr.status)
            $upd = New-E2Sandbox -Name 'update-scope' -Release $release
            $ur = Invoke-E2Deploy -Sandbox $upd -Scope Scheduler
            Test-BRAVOCondition -Condition (($ur.status -eq 'Failed') -and ((Get-E2FindingIds -Result $ur) -contains 'Plan.ScopeNotAllowed')) -Name 'UpdateDeploy/Update-RejectsScope' -Failure 'Update із Scope Scheduler відхиляється.'
        }
    }
} finally {
    if (($null -ne $deployTestRoot) -and $deployTestRoot.StartsWith($deployTestPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $deployTestRoot)) {
        Remove-Item -LiteralPath $deployTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
