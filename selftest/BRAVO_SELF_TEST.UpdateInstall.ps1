# ============================================================
# UpdateInstall: clean install Installer v1 (INS-060…065)
# ============================================================
# Перевіряється реальний стек BRAVO.Update (Deploy/Reconcile/Validation/Rollback/Install) на
# sandbox-каталогах у тимчасовому каталозі (з пробілами та кирилицею): справжній zip із
# release-manifest, справжній Open/Acquire/Stage, справжній відкат. Підмінено лише adapter
# (задачі, guard, setup, credentials, сіяння конфігурації): Task Scheduler, Credential Manager,
# ProgramData і Program Files не чіпаються.

Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking

$e7Module = Get-Module BRAVO.Update
$e7Utf8 = New-Object System.Text.UTF8Encoding($false)
$e7TempPrefix = Join-Path ([IO.Path]::GetTempPath()) 'BRAVO_UPD_e7_'
$e7Base = $e7TempPrefix + [guid]::NewGuid().ToString('N')
$e7Counter = 0
$e7Calls = @{ Seed = 0; Credentials = 0 }

function Invoke-BRAVOE7Module {
    param([scriptblock]$Script, [object[]]$Argument = @())
    return (& $e7Module $Script @Argument)
}

function Write-BRAVOE7File {
    param([string]$Path, [string]$Text)
    $dir = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [IO.File]::WriteAllText($Path, $Text, $e7Utf8)
}

function Get-BRAVOE7Sha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-BRAVOE7TreeHash {
    # Відбиток дерева (відносні шляхи + SHA-256) для доказу «нічого не змінилось».
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    $base = $Path.TrimEnd('\')
    $lines = foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName)) {
        if ($item.PSIsContainer) { 'D ' + $item.FullName.Substring($base.Length) } else { 'F ' + $item.FullName.Substring($base.Length) + ' ' + (Get-BRAVOE7Sha -Path $item.FullName) }
    }
    return ($lines -join "`n")
}

function New-BRAVOE7Release {
    # fake-реліз: stage-дерево + integrity-манифест + zip + .sha256 + release-manifest.json
    param([string]$Base, [string]$Tag = 'v9.9.9', [string]$Commit = 'd77f3b4d021c3d3d53565a604a2497d1d962dcb4', [string]$ExtraFile = '')
    $version = $Tag.Substring(1)
    $stage = Join-Path $Base 'stage'
    $out = Join-Path $Base 'out'
    [void](New-Item -ItemType Directory -Path $stage -Force)
    [void](New-Item -ItemType Directory -Path $out -Force)
    $versionJson = (@{ product = 'BRAVO-Toolkit'; packageVersion = $version; configSchemaVersion = 1; stateSchemaVersion = 1; updaterVersion = '1.0.0'
            releaseDate = '2026-09-13'; releaseChannel = 'stable'; buildId = $Commit.Substring(0, 7); sourceCommit = $Commit } | ConvertTo-Json)
    Write-BRAVOE7File (Join-Path $stage 'VERSION.json') $versionJson
    Write-BRAVOE7File (Join-Path $stage 'BRAVO_RUNTIME_GUARD.ps1') '# guard stub'
    Write-BRAVOE7File (Join-Path $stage 'BRAVO_SETUP.ps1') '# setup stub'
    Write-BRAVOE7File (Join-Path $stage 'BRAVO_CONFIG_LOADER.ps1') '# loader stub'
    Write-BRAVOE7File (Join-Path $stage 'Tools\TOOLS_MANIFEST.json') '{}'
    Write-BRAVOE7File (Join-Path $stage 'modules\X\X.psm1') '# module stub'
    Write-BRAVOE7File (Join-Path $stage 'дані\файл.txt') 'кирилиця'
    $manifestFiles = [ordered]@{}
    foreach ($rel in @('BRAVO_RUNTIME_GUARD.ps1', 'BRAVO_SETUP.ps1', 'BRAVO_CONFIG_LOADER.ps1', 'modules\X\X.psm1', 'VERSION.json', 'Tools\TOOLS_MANIFEST.json')) { $manifestFiles[$rel] = Get-BRAVOE7Sha -Path (Join-Path $stage $rel) }
    Write-BRAVOE7File (Join-Path $stage 'RUNTIME_MANIFEST.json') ((@{ schemaVersion = 1; description = 'fixture'; files = $manifestFiles } | ConvertTo-Json -Depth 4))
    if ($ExtraFile -ne '') { Write-BRAVOE7File (Join-Path $stage $ExtraFile) 'site' }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($file in (Get-ChildItem -LiteralPath $stage -Recurse -File)) {
        $rel = $file.FullName.Substring($stage.Length + 1).Replace('\', '/')
        $entries.Add([pscustomobject]@{ path = $rel; sizeBytes = [long]$file.Length; sha256 = (Get-BRAVOE7Sha -Path $file.FullName).ToLowerInvariant() })
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
    $zipHash = (Get-BRAVOE7Sha -Path $zipPath).ToLowerInvariant()
    Write-BRAVOE7File ($zipPath + '.sha256') ("{0} *{1}`n" -f $zipHash, $zipName)
    $manifestPath = Join-Path $out 'release-manifest.json'
    $manifest = [pscustomobject]@{
        schemaVersion = 1; product = 'BRAVO-Toolkit'; packageVersion = $version; releaseChannel = 'stable'; releaseDate = '2026-09-13'
        sourceCommit = $Commit; buildId = $Commit.Substring(0, 7); archiveRef = $Tag; archiveCommit = $Commit; tag = $Tag; generatedUtc = '2026-09-13T00:00:00Z'
        artifact = [pscustomobject]@{ name = $zipName; sizeBytes = (Get-Item -LiteralPath $zipPath).Length; sha256 = $zipHash }; files = $entries.ToArray()
    }
    Write-BRAVOE7File $manifestPath ($manifest | ConvertTo-Json -Depth 5)
    return [pscustomobject]@{ Stage = $stage; Zip = $zipPath; Tag = $Tag; Version = $version; ZipName = $zipName; ZipSha = $zipHash.ToUpperInvariant(); ManifestSha = (Get-BRAVOE7Sha -Path $manifestPath) }
}

function New-BRAVOE7Adapter {
    # Stub-adapter: задачі в пам'яті (спочатку їх немає; BRAVO_SETUP «реєструє» й вмикає, як F1),
    # guard/setup/credentials керуються параметрами. Seed — stub (дефолт потребує справжніх модулів).
    param([string]$Presence = 'Found', [bool]$SeedCreates = $true, [int]$GuardExit = 0, [int]$SetupValidateExit = 0, [int]$SchedulerExit = 0, [int]$OffsetMinutes = 0)
    $calls = $e7Calls
    $state = @{ Tasks = [ordered]@{}; Offset = $OffsetMinutes }
    $adapter = @{}
    $adapter['State'] = $state
    $adapter.GetManagedTasks = { param($TaskPath, $RuntimeRoot)
        @(foreach ($name in @($state.Tasks.Keys)) { [pscustomobject]@{ Name = $name; Path = '\BRAVO\'; Exists = $true; State = $(if ($state.Tasks[$name]) { 'Ready' } else { 'Disabled' }); Enabled = [bool]$state.Tasks[$name] } })
    }.GetNewClosure()
    $adapter.SetTaskEnabled = { param($TaskPath, $Name, $Enabled) $state.Tasks[$Name] = [bool]$Enabled; [pscustomobject]@{ Success = $true; Message = '' } }.GetNewClosure()
    $adapter.InvokeGuard = { param($RuntimeRoot, $LogPath) [pscustomobject]@{ ExitCode = $GuardExit; Output = ''; TimedOut = $false } }.GetNewClosure()
    $adapter.InvokeSetupScheduler = { param($RuntimeRoot, $LogPath)
        if ($SchedulerExit -eq 0 -or $SchedulerExit -eq 10) { $state.Tasks['BRAVO_A'] = $true; $state.Tasks['BRAVO_B'] = $true }
        [pscustomobject]@{ ExitCode = $SchedulerExit; Output = ''; TimedOut = $false }
    }.GetNewClosure()
    $adapter.InvokeSetupValidate = { param($RuntimeRoot, $LogPath) [pscustomobject]@{ ExitCode = $SetupValidateExit; Output = ''; TimedOut = $false } }.GetNewClosure()
    $adapter.InvokeSelfTest = { param($RuntimeRoot, $LogPath) [pscustomobject]@{ ExitCode = 0; Output = ''; TimedOut = $false } }
    $adapter.TestCredentialPresence = { param($RuntimeRoot, $Component) $calls.Credentials++; [pscustomobject]@{ Component = $Component; Presence = $Presence; ExitCode = 0 } }.GetNewClosure()
    $adapter.GetEffectiveConfiguration = { param($RuntimeRoot)
        [pscustomobject]@{ Success = $true; ExitCode = 0; Message = ''; Configuration = [pscustomobject]@{ schedulerSettings = [pscustomobject]@{ TaskPath = '\BRAVO\'; Backup = [pscustomobject]@{ TaskName = 'BRAVO_A'; Enabled = $true }; Maintenance = [pscustomobject]@{ TaskName = 'BRAVO_B'; Enabled = $false } } } }
    }
    $adapter.Now = { [datetime]::UtcNow.AddMinutes($state.Offset) }.GetNewClosure()
    $adapter.GetUserProfileRoots = { @('C:\Users\Example-Nobody') }
    $adapter.SeedLocalConfig = { param($RuntimeRoot, $BackupDestination)
        $calls.Seed++
        $path = Join-Path $RuntimeRoot 'BRAVO.local.config'
        if (-not $SeedCreates) { return [pscustomobject]@{ Created = $false; Stage = 'Exists'; Path = $path; Reasons = @('вже існує') } }
        [IO.File]::WriteAllText($path, ('# seed ' + $BackupDestination), (New-Object Text.UTF8Encoding $false))
        [pscustomobject]@{ Created = $true; Stage = 'Complete'; Path = $path; Reasons = @() }
    }.GetNewClosure()
    return $adapter
}

function New-BRAVOE7Scenario {
    # Окремі sandbox-корені на сценарій; батьківський каталог кореня встановлення існує (політика).
    param($Release, [string]$Action = 'Install', [int]$OffsetMinutes = 0, [hashtable]$AdapterOptions = @{}, [string]$TargetVersion = '', [string]$SourceArtifactSha = '')
    $script:e7Counter++
    $scenarioRoot = Join-Path $e7Base ('сценарій ' + $script:e7Counter)
    $parent = Join-Path $scenarioRoot 'Програми BRAVO'
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $sc = [ordered]@{
        Scenario = $scenarioRoot; Runtime = (Join-Path $parent 'BRAVO Toolkit'); State = (Join-Path $scenarioRoot 'state'); Lock = (Join-Path $scenarioRoot 'locks')
        Staging = (Join-Path $scenarioRoot 'staging'); Backup = (Join-Path $scenarioRoot 'backup')
        OperationLock = (Join-Path $scenarioRoot 'locks\BRAVO_OPERATION.lock'); VersionState = (Join-Path $scenarioRoot 'state\BRAVO_VERSION_STATE.json')
    }
    [void](New-Item -ItemType Directory -Path $sc.State -Force)
    [void](New-Item -ItemType Directory -Path $sc.Lock -Force)
    $options = @{ OffsetMinutes = $OffsetMinutes }
    foreach ($key in @($AdapterOptions.Keys)) { $options[$key] = $AdapterOptions[$key] }
    $adapter = New-BRAVOE7Adapter @options
    if ($TargetVersion -eq '') { $TargetVersion = $Release.Version }
    $artifactSha = $Release.ZipSha
    if ($SourceArtifactSha -ne '') { $artifactSha = $SourceArtifactSha }
    $source = [pscustomobject][ordered]@{ kind = 'Offline'; tag = $Release.Tag; artifactName = $Release.ZipName; artifactSha256 = $artifactSha; manifestSha256 = $Release.ManifestSha
        packageVersion = $Release.Version; releaseChannel = 'stable'; prereleaseAuthorized = $false }
    $plainAdapter = @{}
    foreach ($key in @($adapter.Keys)) { if ($key -ne 'State') { $plainAdapter[$key] = $adapter[$key] } }
    $pre = Invoke-BRAVOE7Module { param($Rt, $St, $A, $M, $Ad) Get-BRAVODeploymentPreconditions -RuntimeRoot $Rt -StateRoot $St -ArtifactSha256 $A -ManifestSha256 $M -Adapter $Ad } @($sc.Runtime, $sc.State, $artifactSha, $Release.ManifestSha, $plainAdapter)
    $fingerprint = Invoke-BRAVOE7Module { param($P) Get-BRAVOUpdatePreconditionsFingerprint -Preconditions $P } @($pre)
    $changes = [pscustomobject][ordered]@{ filesAdded = 0; filesChanged = 0; filesRemoved = 0
        configuration = [pscustomobject][ordered]@{ localConfigPreserved = $true; legacyConfigPreserved = $true; delta = @() }
        scheduler = [pscustomobject][ordered]@{ tasks = @(); activationPolicy = 'ActivateOnSuccessOnly' } }
    $tests = [pscustomobject][ordered]@{ planned = @(); skipped = @() }
    $plan = New-BRAVOUpdateDeploymentPlan -Action $Action -RuntimeRoot $sc.Runtime -StagingRoot $sc.Staging -BackupRoot $sc.Backup -Source $source `
        -CurrentVersion $null -TargetVersion $TargetVersion -Changes $changes -Tests $tests -PreconditionsFingerprint $fingerprint
    $sc['Plan'] = $plan
    $sc['Adapter'] = $plainAdapter
    $sc['AdapterState'] = $adapter['State']
    $sc['Zip'] = $Release.Zip
    return [pscustomobject]$sc
}

function Invoke-BRAVOE7Install {
    param($Scenario, [hashtable]$Fault = $null, [string]$Destination = 'Cloud')
    $arguments = @{
        Plan = $Scenario.Plan; Adapter = $Scenario.Adapter; BackupDestination = $Destination; SourcePath = $Scenario.Zip
        RuntimeRoot = $Scenario.Runtime; StateRoot = $Scenario.State; LockRoot = $Scenario.Lock; StagingRoot = $Scenario.Staging
        BackupRoot = $Scenario.Backup; OperationLockPath = $Scenario.OperationLock; VersionStatePath = $Scenario.VersionState
    }
    if ($null -ne $Fault) { $arguments['FaultInjection'] = $Fault }
    return (Install-BRAVOToolkit @arguments)
}

function Read-BRAVOE7Journal {
    param($Scenario)
    $path = Join-Path (Join-Path $Scenario.State 'Journal') ([string]$Scenario.Plan.operationId + '.json')
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return ([IO.File]::ReadAllText($path) | ConvertFrom-Json)
}

function Get-BRAVOE7Failure {
    param($Result)
    return ("status=$($Result.status) reason=$($Result.reasonCode) exit=$($Result.exitCode) rollback=$($Result.rollback.message) findings=" + (@($Result.findings | ForEach-Object { $_.id + ':' + $_.details }) -join '|'))
}

function Test-BRAVOE7LocksFree {
    param($Scenario)
    return [bool](Invoke-BRAVOE7Module {
            param($L, $O)
            $a = Enter-BRAVOUpdateLifecycleLock -LockRoot $L -OperationId ([guid]::NewGuid().ToString())
            $b = Enter-BRAVOUpdateOperationLock -OperationLockPath $O -OperationId ([guid]::NewGuid().ToString()) -PackageVersion '0'
            $ok = ($a.Success -and $b.Success)
            if ($a.Success) { Exit-BRAVOUpdateLifecycleLock -Lock $a }
            if ($b.Success) { Exit-BRAVOUpdateOperationLock -Lock $b }
            $ok
        } @($Scenario.Lock, $Scenario.OperationLock))
}

try {
    New-Item -ItemType Directory -Path $e7Base -Force | Out-Null
    $e7Release = New-BRAVOE7Release -Base (Join-Path $e7Base 'release-999')

    # ---------------- 1. Успіх із credentials Found ----------------
    & {
        $e7Calls.Seed = 0
        $sc = New-BRAVOE7Scenario -Release $e7Release
        $result = Invoke-BRAVOE7Install -Scenario $sc -Destination 'LocalOnly'
        $valid = Invoke-BRAVOE7Module { param($R) Test-BRAVOUpdateDeploymentResult -InputObject $R } @($result)
        $journal = Read-BRAVOE7Journal -Scenario $sc
        Test-BRAVOCondition -Condition ($result.status -eq 'Success' -and $result.exitCode -eq 0) -Name 'UpdateInstall/Success/Status' -Failure (Get-BRAVOE7Failure $result)
        Test-BRAVOCondition -Condition ($valid.IsValid) -Name 'UpdateInstall/Success/ResultContractValid' -Failure ($valid.Problems -join '; ')
        Test-BRAVOCondition -Condition ((Test-Path -LiteralPath (Join-Path $sc.Runtime 'дані\файл.txt')) -and (Test-Path -LiteralPath (Join-Path $sc.Runtime 'BRAVO.local.config')) -and (Test-Path -LiteralPath (Join-Path $sc.Runtime 'VERSION.json'))) -Name 'UpdateInstall/Success/FilesAndSeedPresent' -Failure 'файли або BRAVO.local.config відсутні'
        Test-BRAVOCondition -Condition ($result.taskActivation.state -eq 'Inactive') -Name 'UpdateInstall/Success/TasksInactive' -Failure ($result.taskActivation | ConvertTo-Json -Compress)
        Test-BRAVOCondition -Condition (@($sc.AdapterState.Tasks.Keys).Count -eq 2 -and (-not $sc.AdapterState.Tasks['BRAVO_A']) -and (-not $sc.AdapterState.Tasks['BRAVO_B'])) -Name 'UpdateInstall/Success/CreatedTasksDisabled' -Failure ($sc.AdapterState.Tasks | ConvertTo-Json -Compress)
        Test-BRAVOCondition -Condition ($e7Calls.Seed -eq 1) -Name 'UpdateInstall/Success/SeedOnce' -Failure "seed=$($e7Calls.Seed)"
        Test-BRAVOCondition -Condition ($null -ne $journal -and $journal.state -eq 'Committed' -and $journal.mutationStarted -eq $true) -Name 'UpdateInstall/Success/JournalCommitted' -Failure 'журнал не Committed'
        $ownership = @($journal.createdOwnership)
        $seedHash = Get-BRAVOE7Sha -Path (Join-Path $sc.Runtime 'BRAVO.local.config')
        $deployKeysHash = Get-BRAVOE7Sha -Path (Join-Path (Join-Path (Join-Path $sc.State 'Operations') ([string]$sc.Plan.operationId)) 'deploy-keys.json')
        Test-BRAVOCondition -Condition ($ownership -contains ('dir:' + $sc.Runtime) -and $ownership -contains 'dir:modules/X' -and $ownership -contains 'dir:дані') -Name 'UpdateInstall/Success/OwnershipDirs' -Failure ($ownership -join '|')
        Test-BRAVOCondition -Condition ($ownership -contains ('file:BRAVO.local.config|' + $seedHash) -and ($ownership -notcontains 'file:BRAVO.local.config') -and (@($ownership | Where-Object { $_ -like 'deploykeys:*' }).Count -eq 1) -and ($ownership -contains ('deploykeys:' + $deployKeysHash))) -Name 'UpdateInstall/Success/OwnershipDeployKeysAndSeedHash' -Failure ($ownership -join '|')
        Test-BRAVOCondition -Condition (-not (Test-Path -LiteralPath (Join-Path $sc.Staging ([string]$sc.Plan.operationId)))) -Name 'UpdateInstall/Success/StagingRemoved' -Failure 'staging операції лишився'
        Test-BRAVOCondition -Condition (Test-Path -LiteralPath (Join-Path $sc.State ('ConsumedPlans\' + [string]$sc.Plan.planId))) -Name 'UpdateInstall/Success/PlanConsumed' -Failure 'план не позначено використаним'
        Test-BRAVOCondition -Condition (Test-BRAVOE7LocksFree -Scenario $sc) -Name 'UpdateInstall/Success/LocksReleased' -Failure 'lock-и не звільнено'
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
            $sc = New-BRAVOE7Scenario -Release $e7Release -AdapterOptions @{ Presence = $presence }
            $result = Invoke-BRAVOE7Install -Scenario $sc
            $deferred = @($result.findings | Where-Object { $_.id -eq 'Install.SchedulerDeferred' })
            Test-BRAVOCondition -Condition ($result.status -eq 'SuccessWithWarnings' -and $result.exitCode -eq 10) -Name "UpdateInstall/Credentials$presence/SuccessWithWarnings" -Failure (Get-BRAVOE7Failure $result)
            Test-BRAVOCondition -Condition ($deferred.Count -eq 1 -and $deferred[0].severity -eq 'Warning') -Name "UpdateInstall/Credentials$presence/SchedulerDeferredFinding" -Failure 'немає finding Install.SchedulerDeferred'
            Test-BRAVOCondition -Condition (@($sc.AdapterState.Tasks.Keys).Count -eq 0) -Name "UpdateInstall/Credentials$presence/SchedulerNotRegistered" -Failure 'задачі зареєстровано без credentials'
            Test-BRAVOCondition -Condition ($result.taskActivation.state -eq 'Inactive') -Name "UpdateInstall/Credentials$presence/TasksInactive" -Failure $result.taskActivation.state
            $journal = Read-BRAVOE7Journal -Scenario $sc
            Test-BRAVOCondition -Condition ($journal.state -eq 'Committed') -Name "UpdateInstall/Credentials$presence/JournalCommitted" -Failure $journal.state
        }
    }

    # ---------------- 4. Validation Warn -> SuccessWithWarnings; Fail/Scheduler FAIL -> rollback ----------------
    & {
        $sc = New-BRAVOE7Scenario -Release $e7Release -AdapterOptions @{ SetupValidateExit = 1 }
        $result = Invoke-BRAVOE7Install -Scenario $sc
        Test-BRAVOCondition -Condition ($result.status -eq 'SuccessWithWarnings' -and @($result.validation | Where-Object { $_.status -eq 'Warn' }).Count -ge 1) -Name 'UpdateInstall/ValidationWarn/SuccessWithWarnings' -Failure (Get-BRAVOE7Failure $result)

        $sc = New-BRAVOE7Scenario -Release $e7Release -AdapterOptions @{ GuardExit = 1 }
        $result = Invoke-BRAVOE7Install -Scenario $sc
        $journal = Read-BRAVOE7Journal -Scenario $sc
        Test-BRAVOCondition -Condition ($result.status -eq 'RolledBack' -and $result.exitCode -eq 81 -and -not (Test-Path -LiteralPath $sc.Runtime) -and $journal.state -eq 'RolledBack') -Name 'UpdateInstall/ValidationFail/RolledBackToAbsentRoot' -Failure (Get-BRAVOE7Failure $result)

        $sc = New-BRAVOE7Scenario -Release $e7Release -AdapterOptions @{ SchedulerExit = 1 }
        $result = Invoke-BRAVOE7Install -Scenario $sc
        Test-BRAVOCondition -Condition ($result.status -eq 'RolledBack' -and -not (Test-Path -LiteralPath $sc.Runtime)) -Name 'UpdateInstall/SchedulerFail/RolledBack' -Failure (Get-BRAVOE7Failure $result)

        $sc = New-BRAVOE7Scenario -Release $e7Release -AdapterOptions @{ SchedulerExit = 10 }
        $result = Invoke-BRAVOE7Install -Scenario $sc
        Test-BRAVOCondition -Condition ($result.status -eq 'SuccessWithWarnings' -and @($result.findings | Where-Object { $_.id -eq 'Install.SchedulerWarning' }).Count -eq 1) -Name 'UpdateInstall/SchedulerWarning/SuccessWithWarnings' -Failure (Get-BRAVOE7Failure $result)
    }

    # ---------------- 5. Політика кореня ----------------
    & {
        $sc = New-BRAVOE7Scenario -Release $e7Release
        $check = {
            param([string]$Root, [string[]]$Profiles = @('C:\Users\Example-Nobody'), [string]$State = '')
            Invoke-BRAVOE7Module { param($R, $P, $S) Test-BRAVOInstallRuntimeRootPolicy -RuntimeRoot $R -StateRoot $S -ProfileRoot $P } @($Root, $Profiles, $State)
        }

        $okResult = & $check $sc.Runtime
        Test-BRAVOCondition -Condition ($okResult.IsValid -and -not $okResult.PreexistingEmpty) -Name 'UpdateInstall/RootPolicy/AcceptsSpacesAndCyrillic' -Failure ($okResult.Problems -join '; ')

        $nonEmpty = Join-Path $sc.Scenario 'непорожній каталог'
        New-Item -ItemType Directory -Path $nonEmpty -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $nonEmpty 'x.txt'), 'x')
        Test-BRAVOCondition -Condition (-not (& $check $nonEmpty).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsNonEmpty' -Failure 'непорожній корінь прийнято'

        $empty = Join-Path $sc.Scenario 'порожній каталог'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $emptyResult = & $check $empty
        Test-BRAVOCondition -Condition ($emptyResult.IsValid -and $emptyResult.PreexistingEmpty) -Name 'UpdateInstall/RootPolicy/AcceptsPreexistingEmpty' -Failure ($emptyResult.Problems -join '; ')

        Test-BRAVOCondition -Condition (-not (& $check '\\host-a\share\BRAVO').IsValid) -Name 'UpdateInstall/RootPolicy/RejectsUnc' -Failure 'UNC прийнято'
        Test-BRAVOCondition -Condition (-not (& $check 'відносний\шлях').IsValid) -Name 'UpdateInstall/RootPolicy/RejectsRelative' -Failure 'відносний шлях прийнято'
        Test-BRAVOCondition -Condition (-not (& $check ($sc.Scenario + '\Програми BRAVO\..\BRAVO')).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsDotDot' -Failure "'..' прийнято"
        Test-BRAVOCondition -Condition (-not (& $check ([IO.Path]::GetPathRoot($sc.Runtime))).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsDriveRoot' -Failure 'корінь диска прийнято'
        Test-BRAVOCondition -Condition (-not (& $check (Join-Path $env:SystemRoot 'BRAVO-Example')).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsUnderSystemRoot' -Failure 'каталог під SystemRoot прийнято'
        Test-BRAVOCondition -Condition (-not (& $check $sc.Runtime @($sc.Scenario)).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsUnderProfile' -Failure 'каталог у профілі прийнято'
        Test-BRAVOCondition -Condition (-not (& $check $sc.Scenario @($sc.Scenario)).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsProfileItself' -Failure 'сам профіль прийнято'
        Test-BRAVOCondition -Condition (-not (& $check (Join-Path $sc.Scenario 'нема\батька\BRAVO')).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsMissingParent' -Failure 'відсутній батько прийнято'
        $fileRoot = Join-Path $sc.Scenario 'файл-а-не-каталог'
        [IO.File]::WriteAllText($fileRoot, 'x')
        Test-BRAVOCondition -Condition (-not (& $check $fileRoot).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsFile' -Failure 'файл прийнято'
        Test-BRAVOCondition -Condition (-not (& $check (Join-Path $sc.State 'всередині') @('C:\Users\Example-Nobody') $sc.State).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsInsideState' -Failure 'корінь у State прийнято'
        Test-BRAVOCondition -Condition (-not (& $check $sc.Scenario @('C:\Users\Example-Nobody') $sc.Runtime).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsContainingState' -Failure 'корінь, що містить State, прийнято'

        # Junction: сам корінь і корінь під junction-ом.
        $junctionTarget = Join-Path $sc.Scenario 'ціль junction'
        $junction = Join-Path $sc.Scenario 'junction'
        New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
        [void](New-Item -ItemType Junction -Path $junction -Target $junctionTarget)
        try {
            Test-BRAVOCondition -Condition (-not (& $check $junction).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsJunctionRoot' -Failure 'junction як корінь прийнято'
            Test-BRAVOCondition -Condition (-not (& $check (Join-Path $junction 'BRAVO')).IsValid) -Name 'UpdateInstall/RootPolicy/RejectsUnderJunction' -Failure 'корінь під junction прийнято'
        } finally {
            [IO.Directory]::Delete($junction, $false)
        }

        # Наскрізно: непорожній корінь -> Failed/Blocked, нічого не змінено, журналу немає.
        $e2e = New-BRAVOE7Scenario -Release $e7Release
        New-Item -ItemType Directory -Path $e2e.Runtime -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $e2e.Runtime 'чужий.txt'), 'дані сайту')
        $before = Get-BRAVOE7TreeHash -Path $e2e.Runtime
        $result = Invoke-BRAVOE7Install -Scenario $e2e
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.reasonCode -eq 'Blocked' -and -not $result.mutationStarted) -Name 'UpdateInstall/RootPolicy/NonEmptyBlockedEndToEnd' -Failure (Get-BRAVOE7Failure $result)
        Test-BRAVOCondition -Condition ((Get-BRAVOE7TreeHash -Path $e2e.Runtime) -eq $before -and -not (Test-Path -LiteralPath (Join-Path $e2e.State 'Journal'))) -Name 'UpdateInstall/RootPolicy/NonEmptyUntouchedNoJournal' -Failure 'каталог змінено або створено журнал'
    }

    # ---------------- 6. Наперед існуючий порожній корінь ----------------
    & {
        $sc = New-BRAVOE7Scenario -Release $e7Release
        New-Item -ItemType Directory -Path $sc.Runtime -Force | Out-Null
        $result = Invoke-BRAVOE7Install -Scenario $sc
        $journal = Read-BRAVOE7Journal -Scenario $sc
        $ownership = @($journal.createdOwnership)
        Test-BRAVOCondition -Condition ($result.status -eq 'Success' -and ($ownership -contains 'marker:preexistingRoot') -and ($ownership -notcontains ('dir:' + $sc.Runtime))) -Name 'UpdateInstall/PreexistingRoot/MarkerNotDirOwnership' -Failure ((Get-BRAVOE7Failure $result) + ' ' + ($ownership -join '|'))

        $sc2 = New-BRAVOE7Scenario -Release $e7Release
        New-Item -ItemType Directory -Path $sc2.Runtime -Force | Out-Null
        $result2 = Invoke-BRAVOE7Install -Scenario $sc2 -Fault @{ 'Deploy.AfterSideEffect' = 'Throw' }
        Test-BRAVOCondition -Condition ($result2.status -eq 'RolledBack' -and (Test-Path -LiteralPath $sc2.Runtime) -and @(Get-ChildItem -LiteralPath $sc2.Runtime -Force).Count -eq 0) -Name 'UpdateInstall/PreexistingRoot/KeptEmptyAfterRollback' -Failure (Get-BRAVOE7Failure $result2)
    }

    # ---------------- 7. Збій у кожній фазі -> rollback до відсутнього кореня ----------------
    $e7PhaseFaults = @(
        @{ Name = 'MutationBoundary.AfterSideEffect'; Fault = @{ 'MutationBoundary.AfterSideEffect' = 'Throw' } },
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
            $sc = New-BRAVOE7Scenario -Release $e7Release
            $result = Invoke-BRAVOE7Install -Scenario $sc -Fault $case.Fault
            $journal = Read-BRAVOE7Journal -Scenario $sc
            $name = $case.Name
            Test-BRAVOCondition -Condition ($result.status -eq 'RolledBack' -and $result.exitCode -eq 81 -and $result.mutationStarted) -Name ('UpdateInstall/PhaseFailure/' + $name + '/RolledBack') -Failure (Get-BRAVOE7Failure $result)
            Test-BRAVOCondition -Condition (-not (Test-Path -LiteralPath $sc.Runtime)) -Name ('UpdateInstall/PhaseFailure/' + $name + '/RootAbsent') -Failure ('корінь лишився: ' + (Get-BRAVOE7TreeHash -Path $sc.Runtime))
            Test-BRAVOCondition -Condition ($null -ne $journal -and $journal.state -eq 'RolledBack') -Name ('UpdateInstall/PhaseFailure/' + $name + '/JournalRolledBack') -Failure ([string]$journal.state)
            Test-BRAVOCondition -Condition (@($result.findings | Where-Object { $_.severity -eq 'Blocker' }).Count -ge 1) -Name ('UpdateInstall/PhaseFailure/' + $name + '/FailureReported') -Failure 'немає blocker-finding про причину'
        }
    }

    # Збій Activate після успішної Validate не відкочує встановлення (як у Update): Unknown + Warning.
    & {
        $sc = New-BRAVOE7Scenario -Release $e7Release
        $result = Invoke-BRAVOE7Install -Scenario $sc -Fault @{ 'Activate.AfterIntent' = 'Throw' }
        Test-BRAVOCondition -Condition ($result.status -eq 'SuccessWithWarnings' -and $result.taskActivation.state -eq 'Unknown' -and (Test-Path -LiteralPath $sc.Runtime)) -Name 'UpdateInstall/PhaseFailure/Activate/NoRollbackUnknownActivation' -Failure (Get-BRAVOE7Failure $result)
    }

    # ---------------- 8. Збій ДО межі mutation: Abandoned, runtime не чіпаємо ----------------
    & {
        $sc = New-BRAVOE7Scenario -Release $e7Release
        $result = Invoke-BRAVOE7Install -Scenario $sc -Fault @{ 'Stage.AfterSideEffect' = 'Throw' }
        $journal = Read-BRAVOE7Journal -Scenario $sc
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and -not $result.mutationStarted -and $result.reasonCode -eq 'Error') -Name 'UpdateInstall/PreMutation/FailedNotRolledBack' -Failure (Get-BRAVOE7Failure $result)
        Test-BRAVOCondition -Condition ($journal.state -eq 'Abandoned' -and -not (Test-Path -LiteralPath $sc.Runtime) -and -not (Test-Path -LiteralPath (Join-Path $sc.Staging ([string]$sc.Plan.operationId)))) -Name 'UpdateInstall/PreMutation/AbandonedAndCleaned' -Failure "journal=$($journal.state)"
        $replay = Invoke-BRAVOE7Install -Scenario $sc
        Test-BRAVOCondition -Condition ($replay.status -eq 'Failed' -and $replay.reasonCode -eq 'PlanStale') -Name 'UpdateInstall/PreMutation/ReplayRejected' -Failure (Get-BRAVOE7Failure $replay)

        # Файл сайту в пакеті -> blocker до mutation.
        $siteRelease = New-BRAVOE7Release -Base (Join-Path $e7Base 'release-site') -ExtraFile 'BRAVO.config'
        $sc = New-BRAVOE7Scenario -Release $siteRelease
        $result = Invoke-BRAVOE7Install -Scenario $sc
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.reasonCode -eq 'VerificationFailed' -and -not (Test-Path -LiteralPath $sc.Runtime)) -Name 'UpdateInstall/PreMutation/SiteFileInPayloadBlocked' -Failure (Get-BRAVOE7Failure $result)

        # Хеш артефакта не збігається з планом.
        $sc = New-BRAVOE7Scenario -Release $e7Release -SourceArtifactSha ('C' * 64)
        $result = Invoke-BRAVOE7Install -Scenario $sc
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.reasonCode -eq 'VerificationFailed' -and -not (Test-Path -LiteralPath $sc.Runtime)) -Name 'UpdateInstall/PreMutation/PlanHashMismatch' -Failure (Get-BRAVOE7Failure $result)

        # Версія staged не збігається з планом.
        $sc = New-BRAVOE7Scenario -Release $e7Release -TargetVersion '9.9.8'
        $result = Invoke-BRAVOE7Install -Scenario $sc
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.reasonCode -eq 'VerificationFailed' -and -not (Test-Path -LiteralPath $sc.Runtime)) -Name 'UpdateInstall/PreMutation/StagedVersionMismatch' -Failure (Get-BRAVOE7Failure $result)
    }

    # ---------------- 9. Plan stale, wrong action, ALLOW_DOWNGRADE, locks ----------------
    & {
        # План прострочено (годинник adapter-а +60 хв після побудови плану).
        $sc = New-BRAVOE7Scenario -Release $e7Release
        $sc.AdapterState.Offset = 60
        $result = Invoke-BRAVOE7Install -Scenario $sc
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.reasonCode -eq 'PlanStale' -and -not (Test-Path -LiteralPath $sc.Runtime) -and -not (Test-Path -LiteralPath (Join-Path $sc.State 'Journal'))) -Name 'UpdateInstall/PlanStale/NoMutationNoJournal' -Failure (Get-BRAVOE7Failure $result)

        $sc = New-BRAVOE7Scenario -Release $e7Release -Action 'Update'
        $result = Invoke-BRAVOE7Install -Scenario $sc
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.reasonCode -eq 'Blocked' -and -not (Test-Path -LiteralPath $sc.Runtime)) -Name 'UpdateInstall/WrongAction/Blocked' -Failure (Get-BRAVOE7Failure $result)

        $sc = New-BRAVOE7Scenario -Release $e7Release
        $previous = [Environment]::GetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE')
        try {
            [Environment]::SetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE', '1')
            $result = Invoke-BRAVOE7Install -Scenario $sc
        } finally {
            [Environment]::SetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE', $previous)
        }
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.reasonCode -eq 'Blocked' -and -not (Test-Path -LiteralPath $sc.Runtime)) -Name 'UpdateInstall/AllowDowngrade/Blocked' -Failure (Get-BRAVOE7Failure $result)

        # Lifecycle lock зайнятий -> Blocked 20.
        $sc = New-BRAVOE7Scenario -Release $e7Release
        $held = Invoke-BRAVOE7Module { param($L) Enter-BRAVOUpdateLifecycleLock -LockRoot $L -OperationId ([guid]::NewGuid().ToString()) } @($sc.Lock)
        try {
            $result = Invoke-BRAVOE7Install -Scenario $sc
        } finally {
            Invoke-BRAVOE7Module { param($H) Exit-BRAVOUpdateLifecycleLock -Lock $H } @($held)
        }
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.exitCode -eq 20 -and -not (Test-Path -LiteralPath $sc.Runtime)) -Name 'UpdateInstall/LifecycleLockBusy/Exit20' -Failure (Get-BRAVOE7Failure $result)

        # Operation lock зайнятий -> Blocked 20 до межі: runtime не створено, журнал Abandoned, а не фіктивний RolledBack.
        $sc = New-BRAVOE7Scenario -Release $e7Release
        $heldOperation = Invoke-BRAVOE7Module { param($P) Enter-BRAVOUpdateOperationLock -OperationLockPath $P -OperationId ([guid]::NewGuid().ToString()) -PackageVersion '1.0.0' } @($sc.OperationLock)
        try {
            $result = Invoke-BRAVOE7Install -Scenario $sc
        } finally {
            Invoke-BRAVOE7Module { param($H) Exit-BRAVOUpdateOperationLock -Lock $H } @($heldOperation)
        }
        $journal = Read-BRAVOE7Journal -Scenario $sc
        Test-BRAVOCondition -Condition ($result.status -eq 'Failed' -and $result.exitCode -eq 20 -and $journal.state -eq 'Abandoned' -and -not $result.mutationStarted -and -not (Test-Path -LiteralPath $sc.Runtime)) -Name 'UpdateInstall/OperationLockBusy/AbandonedBeforeBoundary' -Failure (Get-BRAVOE7Failure $result)
    }

    # ---------------- 10. Crash: без rollback, журнал Open, handle-и звільнені ----------------
    & {
        $sc = New-BRAVOE7Scenario -Release $e7Release
        $thrown = $null
        try {
            [void](Invoke-BRAVOE7Install -Scenario $sc -Fault @{ 'Deploy.AfterSideEffect' = 'Crash' })
        } catch {
            $thrown = $_.Exception.Message
        }
        $journal = Read-BRAVOE7Journal -Scenario $sc
        Test-BRAVOCondition -Condition ($null -ne $thrown -and $thrown -like '*SimulatedCrash*') -Name 'UpdateInstall/Crash/Propagates' -Failure ([string]$thrown)
        Test-BRAVOCondition -Condition ($journal.state -eq 'Open' -and $journal.mutationStarted -eq $true -and (Test-Path -LiteralPath $sc.Runtime)) -Name 'UpdateInstall/Crash/JournalOpenRuntimeLeftForRecovery' -Failure "journal=$($journal.state)"
        Test-BRAVOCondition -Condition (Test-BRAVOE7LocksFree -Scenario $sc) -Name 'UpdateInstall/Crash/HandlesReleased' -Failure 'lock-и лишилися утриманими'
    }

    # ---------------- 11. Сіяння не перезаписує ----------------
    & {
        $sc = New-BRAVOE7Scenario -Release $e7Release -AdapterOptions @{ SeedCreates = $false }
        $result = Invoke-BRAVOE7Install -Scenario $sc
        $journal = Read-BRAVOE7Journal -Scenario $sc
        Test-BRAVOCondition -Condition ($result.status -eq 'RolledBack' -and -not (Test-Path -LiteralPath $sc.Runtime)) -Name 'UpdateInstall/Seed/CreatedFalseIsFailure' -Failure (Get-BRAVOE7Failure $result)
        Test-BRAVOCondition -Condition (@($journal.createdOwnership | Where-Object { $_ -like 'file:BRAVO.local.config*' }).Count -eq 0) -Name 'UpdateInstall/Seed/NoOwnershipForForeignFile' -Failure (@($journal.createdOwnership) -join '|')
    }

    # ---------------- 12. Rollback, що не вдався -> Critical ----------------
    & {
        $sc = New-BRAVOE7Scenario -Release $e7Release
        $result = Invoke-BRAVOE7Install -Scenario $sc -Fault @{ 'Deploy.AfterSideEffect' = 'Throw'; 'Rollback.InstallCleanup.AfterSideEffect' = 'Throw' }
        $journal = Read-BRAVOE7Journal -Scenario $sc
        Test-BRAVOCondition -Condition ($result.status -eq 'Critical' -and $result.exitCode -eq 82 -and $journal.state -eq 'Critical' -and $result.rollback.status -eq 'Failed') -Name 'UpdateInstall/RollbackFailure/Critical' -Failure (Get-BRAVOE7Failure $result)
    }

    # ---------------- 13. Ownership-ключі й adapter за замовчуванням ----------------
    & {
        $entries = @(Invoke-BRAVOE7Module { param($K) Get-BRAVOInstallOwnershipEntry -DeployKeys $K } @(, @{ 'a/b/c.txt' = 'aa'; 'root.txt' = 'bb'; 'a/d.txt' = 'cc' }))
        Test-BRAVOCondition -Condition ($entries.Count -eq 2 -and $entries[0] -eq 'dir:a' -and $entries[1] -eq 'dir:a/b') -Name 'UpdateInstall/Ownership/DirsParentsFirstOnly' -Failure ($entries -join '|')
        $threw = $false
        try { [void](Invoke-BRAVOE7Module { param($K) Get-BRAVOInstallOwnershipEntry -DeployKeys $K } @(, @{ '../evil.txt' = 'aa' })) } catch { $threw = $true }
        Test-BRAVOCondition -Condition $threw -Name 'UpdateInstall/Ownership/RejectsDotDotKey' -Failure 'ключ з .. прийнято'
        $full = Invoke-BRAVOE7Module { Get-BRAVOInstallAdapter -Adapter @{ Now = { [datetime]::UtcNow } } }
        Test-BRAVOCondition -Condition ($full.ContainsKey('SeedLocalConfig') -and $full.ContainsKey('GetUserProfileRoots') -and $full.ContainsKey('Now')) -Name 'UpdateInstall/Adapter/DefaultsAdded' -Failure (@($full.Keys) -join ',')
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
}
