# Suite UpdateRollback: version-state, Invoke-BRAVORollback, відкат clean install і
# additive -OwnedKeyList у deploy\BRAVO.Deploy.Rollback.ps1 (INS-050...052).
# Фрагмент dot-source-иться з BRAVO_SELF_TEST.ps1 ($root заданий). Усе — у sandbox
# під %TEMP%; scheduler, credentials і справжній runtime не чіпаються.

Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking

$updRbModule = Get-Module BRAVO.Update
$updRbTemp = Join-Path ([System.IO.Path]::GetTempPath()) ('bravo-updrb-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $updRbTemp -Force)
$updRbSavedDowngrade = [Environment]::GetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE')
$updRbUtf8 = New-Object System.Text.UTF8Encoding($false)

# Виклик приватних функцій модуля (splat із hashtable).
function Invoke-UpdRbCall {
    param([string]$Name, [hashtable]$Arguments = @{})
    & $updRbModule { param($n, $a) & $n @a } $Name $Arguments
}

function Write-UpdRbFile {
    param([string]$Path, [string]$Text)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::WriteAllText($Path, $Text, $updRbUtf8)
}

function Get-UpdRbSha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

# Знімок дерева (файли з хешами + каталоги): рівність рядків = ідентичне дерево.
function Get-UpdRbTreeHash {
    param([string]$Root)
    $prefix = $Root.TrimEnd('\').Length
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object -Property FullName)) {
        $rel = $item.FullName.Substring($prefix)
        if ($item.PSIsContainer) { $lines.Add('D ' + $rel) } else { $lines.Add('F ' + $rel + ' ' + (Get-UpdRbSha -Path $item.FullName)) }
    }
    return [string]::Join("`n", $lines.ToArray())
}

# Stub-и функцій інших частин (Reconcile/Validation) у області МОДУЛЯ: ті самі
# імена, що викликає Rollback; поведінка керується $script:UpdRbMode. Після
# suite модуль перезавантажується (-Force), тож stub-и не просочуються далі.
& $updRbModule {
    $script:UpdRbLog = New-Object System.Collections.Generic.List[string]
    $script:UpdRbMode = @{ ValidationStatus = 'Pass'; RestoreComplete = $true; ReconcileVerdict = 'PASS'; LiveEnabled = $false }
    $script:UpdRbProbe = $null
    function script:Disable-BRAVOAllManagedTasks {
        [CmdletBinding()] param($Adapter, $RuntimeRoot = '', $Snapshot = $null)
        # Probe фіксує стан runtime у МОМЕНТ вимкнення (порядок quiesce -> restore).
        $suffix = ''
        if ($null -ne $script:UpdRbProbe) { $suffix = '@' + [string](& $script:UpdRbProbe) }
        $script:UpdRbLog.Add('Disable' + $suffix)
        [pscustomobject]@{ Disabled = @(); Failed = @(); IsComplete = $true }
    }
    function script:Get-BRAVOSchedulerSnapshot {
        [CmdletBinding()] param($Adapter, $RuntimeRoot = '', $TaskPath = '', $ManagedTaskName = @())
        $script:UpdRbLog.Add('LiveRead')
        [pscustomobject]@{ tasks = @([pscustomobject]@{ name = 'T1'; exists = $true; enabled = [bool]$script:UpdRbMode.LiveEnabled }) }
    }
    function script:Restore-BRAVOManagedTaskState {
        [CmdletBinding()] param($Snapshot, $Adapter)
        $script:UpdRbLog.Add('RestoreTasks')
        [pscustomobject]@{ Restored = @(); Failed = @(); IsComplete = [bool]$script:UpdRbMode.RestoreComplete }
    }
    function script:Invoke-BRAVOSchedulerReconcile {
        [CmdletBinding()] param($Context, $Snapshot)
        $script:UpdRbLog.Add('Reconcile')
        [pscustomobject]@{ Verdict = [string]$script:UpdRbMode.ReconcileVerdict; ExitCode = 0; CreatedTasks = @(); RequiescedTasks = @(); Problems = @() }
    }
    function script:Test-BRAVODeploymentValidation {
        [CmdletBinding()] param($Context, $Mode, $ExpectedVersion, $ExpectedManifestPath, $SiteBaseline, $GuardBaselineExitCode, $SetupValidateBaselineExitCode)
        $script:UpdRbLastValidate = @{ Guard = $GuardBaselineExitCode; Setup = $SetupValidateBaselineExitCode }
        $script:UpdRbLog.Add('Validate:' + $Mode)
        [pscustomobject]@{ Status = [string]$script:UpdRbMode.ValidationStatus; Items = @([pscustomobject]@{ Name = 'RuntimeManifest'; Status = 'Pass'; Message = 'ok' }) }
    }
}
function Reset-UpdRbStubs {
    param([string]$ValidationStatus = 'Pass', [bool]$RestoreComplete = $true, [string]$ReconcileVerdict = 'PASS', [bool]$LiveEnabled = $false, $Probe = $null)
    & $updRbModule { param($v, $r, $c, $l, $p) $script:UpdRbLog.Clear(); $script:UpdRbProbe = $p; $script:UpdRbMode = @{ ValidationStatus = $v; RestoreComplete = $r; ReconcileVerdict = $c; LiveEnabled = $l } } $ValidationStatus $RestoreComplete $ReconcileVerdict $LiveEnabled $Probe
}
function Get-UpdRbLog { $items = @(& $updRbModule { $script:UpdRbLog.ToArray() }); return $items }

$updRbOldState = '{"highestVersion":"5.2.5","highestVersionFull":"5.2.5","sourceCommit":"abc","recordedAt":"2026-01-01T00:00:00Z"}'
function Get-UpdRbStateText { param([string]$Version) return ('{"highestVersion":"' + $Version + '","highestVersionFull":"' + $Version + '","sourceCommit":"zzz","recordedAt":"2026-02-02T00:00:00Z"}') }

# Сценарій Update: старий runtime -> backup -> «розгортання» -> state піднято до target.
function New-UpdRbUpdateScenario {
    param([string]$Name, [switch]$ConfigureScheduler)
    $base = Join-Path $updRbTemp ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $s = @{ Base = $base }
    $s.Runtime = Join-Path $base 'runtime Сервер'
    $s.State = Join-Path $base 'state'; $s.Staging = Join-Path $base 'staging'; $s.Backup = Join-Path $base 'backup'
    $s.Backup = Join-Path $base 'backup'
    $s.Staging = Join-Path $base 'staging'
    $s.OpLock = Join-Path $base 'locks\BRAVO_OPERATION.lock'
    $s.VersionState = Join-Path $base 'state-file\BRAVO_VERSION_STATE.json'
    $s.OperationId = [guid]::NewGuid().ToString()
    $s.OpDir = Join-Path (Join-Path $s.State 'Operations') $s.OperationId
    [void](New-Item -ItemType Directory -Path $s.Runtime, $s.State, $s.Staging -Force)

    $old = [ordered]@{ 'BRAVO_A.ps1' = 'old A'; 'sub dir/B.ps1' = 'old B'; 'REMOVED.ps1' = 'old removed'; 'VERSION.json' = '{"packageVersion":"5.2.5"}' }
    foreach ($key in $old.Keys) { Write-UpdRbFile -Path (Join-Path $s.Runtime ($key -replace '/', '\')) -Text $old[$key] }
    $oldHashes = [ordered]@{}
    foreach ($key in $old.Keys) { $oldHashes[$key] = Get-UpdRbSha -Path (Join-Path $s.Runtime ($key -replace '/', '\')) }
    Write-UpdRbFile -Path (Join-Path $s.Runtime 'RUNTIME_MANIFEST.json') -Text ((@{ schemaVersion = 1; files = $oldHashes } | ConvertTo-Json -Depth 5))
    # Site-файли: поза owned-набором, відкат їх не чіпає.
    Write-UpdRbFile -Path (Join-Path $s.Runtime 'BRAVO.local.config') -Text 'site config'
    Write-UpdRbFile -Path (Join-Path $s.Runtime 'LOGS\run.log') -Text 'log line'

    # Backup (як New-BRAVORuntimeBackup): runtime\ + backup-manifest.json.
    $backupDir = Join-Path $s.Backup $s.OperationId
    $backupKeys = @($old.Keys) + @('RUNTIME_MANIFEST.json')
    $backupHashes = [ordered]@{}
    foreach ($key in $backupKeys) {
        $source = Join-Path $s.Runtime ($key -replace '/', '\')
        $target = Join-Path (Join-Path $backupDir 'runtime') ($key -replace '/', '\')
        $targetDir = [System.IO.Path]::GetDirectoryName($target)
        if (-not [System.IO.Directory]::Exists($targetDir)) { [void][System.IO.Directory]::CreateDirectory($targetDir) }
        [System.IO.File]::Copy($source, $target, $true)
        $backupHashes[$key] = Get-UpdRbSha -Path $source
    }
    Write-UpdRbFile -Path (Join-Path $backupDir 'backup-manifest.json') -Text ((@{ schemaVersion = 1; operationId = $s.OperationId; sourceRuntimeRoot = $s.Runtime; createdUtc = '2026-01-01T00:00:00.0000000Z'; excludeFiles = @(); excludeDirs = @(); files = $backupHashes; fileCount = $backupHashes.Count; totalBytes = 0 } | ConvertTo-Json -Depth 5))
    $s.BackupDir = $backupDir
    $s.OrigTree = Get-UpdRbTreeHash -Root $s.Runtime

    # Снапшоти до mutation.
    Write-UpdRbFile -Path $s.VersionState -Text $updRbOldState
    $s.OrigStateSha = Get-UpdRbSha -Path $s.VersionState
    $snapshot = Invoke-UpdRbCall -Name 'Get-BRAVOVersionStateSnapshot' -Arguments @{ VersionStatePath = $s.VersionState; OperationDirectory = $s.OpDir }
    $s.Snapshot = $snapshot
    $schedulerPath = Join-Path $s.OpDir 'scheduler-snapshot.json'
    Write-UpdRbFile -Path $schedulerPath -Text '{"schemaVersion":1,"tasks":[{"name":"T1","enabled":true}]}'

    # «Розгортання»: змінено, додано, видалено; нові deploy-ключі.
    Write-UpdRbFile -Path (Join-Path $s.Runtime 'BRAVO_A.ps1') -Text 'new A'
    Write-UpdRbFile -Path (Join-Path $s.Runtime 'sub dir\B.ps1') -Text 'new B'
    [System.IO.File]::Delete((Join-Path $s.Runtime 'REMOVED.ps1'))
    Write-UpdRbFile -Path (Join-Path $s.Runtime 'NEW.ps1') -Text 'new file'
    Write-UpdRbFile -Path (Join-Path $s.Runtime 'newdir\N.ps1') -Text 'new nested'
    Write-UpdRbFile -Path (Join-Path $s.Runtime 'VERSION.json') -Text '{"packageVersion":"5.2.6"}'
    $newKeys = @('BRAVO_A.ps1', 'sub dir/B.ps1', 'NEW.ps1', 'newdir/N.ps1', 'VERSION.json')
    $newHashes = [ordered]@{}
    foreach ($key in $newKeys) { $newHashes[$key] = Get-UpdRbSha -Path (Join-Path $s.Runtime ($key -replace '/', '\')) }
    Write-UpdRbFile -Path (Join-Path $s.Runtime 'RUNTIME_MANIFEST.json') -Text ((@{ schemaVersion = 1; files = $newHashes } | ConvertTo-Json -Depth 5))
    $deployHashes = [ordered]@{}
    foreach ($key in ($newKeys + @('RUNTIME_MANIFEST.json'))) { $deployHashes[$key] = Get-UpdRbSha -Path (Join-Path $s.Runtime ($key -replace '/', '\')) }
    $deployKeysPath = Join-Path $s.OpDir 'deploy-keys.json'
    Write-UpdRbFile -Path $deployKeysPath -Text ((@{ schemaVersion = 1; operationId = $s.OperationId; deployKeys = $deployHashes } | ConvertTo-Json -Depth 5))
    $s.DeployKeysPath = $deployKeysPath
    $s.DeployedTree = Get-UpdRbTreeHash -Root $s.Runtime
    # Guard (запуск задачі/оператора) зафіксував target у state.
    Write-UpdRbFile -Path $s.VersionState -Text (Get-UpdRbStateText -Version '5.2.6')

    $journal = Invoke-UpdRbCall -Name 'New-BRAVOUpdateJournal' -Arguments @{
        StateRoot = $s.State; Action = 'Update'; OperationId = $s.OperationId; PlanId = [guid]::NewGuid().ToString()
        RuntimeRoot = $s.Runtime; StagingRoot = $s.Staging; BackupRoot = $s.Backup
        SourceVersion = '5.2.5'; TargetVersion = '5.2.6'
    }
    $manifestSha = Get-UpdRbSha -Path (Join-Path $backupDir 'backup-manifest.json')
    [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalBackup' -Arguments @{ Journal = $journal; Path = $backupDir; ManifestSha256 = $manifestSha; FileCount = $backupKeys.Count; StateRoot = $s.State })
    [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalSchedulerSnapshot' -Arguments @{ Journal = $journal; Path = $schedulerPath; StateRoot = $s.State })
    [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalMutationStarted' -Arguments @{ Journal = $journal; StateRoot = $s.State })
    [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalField' -Arguments @{ Journal = $journal; Name = 'versionState'; Value = $snapshot; StateRoot = $s.State })
    [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalField' -Arguments @{ Journal = $journal; Name = 'deployKeys'; Value = ([pscustomobject]@{ sha256 = (Get-UpdRbSha -Path $deployKeysPath) }); StateRoot = $s.State })
    foreach ($phase in @('QuiesceTasks', 'Deploy')) {
        [void](Invoke-UpdRbCall -Name 'Add-BRAVOUpdateJournalPhaseIntent' -Arguments @{ Journal = $journal; Phase = $phase; StateRoot = $s.State })
        [void](Invoke-UpdRbCall -Name 'Complete-BRAVOUpdateJournalPhase' -Arguments @{ Journal = $journal; Phase = $phase; Outcome = 'Succeeded'; StateRoot = $s.State })
    }
    if ($ConfigureScheduler) {
        [void](Invoke-UpdRbCall -Name 'Add-BRAVOUpdateJournalPhaseIntent' -Arguments @{ Journal = $journal; Phase = 'ConfigureScheduler'; StateRoot = $s.State })
    }
    $s.Journal = $journal
    return $s
}

# Repair -Scope Scheduler: файли не змінювались, backup = $null, Deploy-фази немає;
# після межі mutation відбулися лише QuiesceTasks/ConfigureScheduler і зсув state.
function New-UpdRbSchedulerOnlyScenario {
    param([string]$Name)
    $base = Join-Path $updRbTemp ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $s = @{ Base = $base }
    $s.Runtime = Join-Path $base 'runtime Сервер'
    $s.State = Join-Path $base 'state'; $s.Staging = Join-Path $base 'staging'; $s.Backup = Join-Path $base 'backup'
    $s.OpLock = Join-Path $base 'locks\BRAVO_OPERATION.lock'
    $s.VersionState = Join-Path $base 'state-file\BRAVO_VERSION_STATE.json'
    $s.OperationId = [guid]::NewGuid().ToString()
    $s.OpDir = Join-Path (Join-Path $s.State 'Operations') $s.OperationId
    [void](New-Item -ItemType Directory -Path $s.Runtime, $s.State -Force)
    $files = [ordered]@{ 'BRAVO_A.ps1' = 'A'; 'VERSION.json' = '{"packageVersion":"5.2.5"}' }
    $hashes = [ordered]@{}
    foreach ($key in $files.Keys) {
        Write-UpdRbFile -Path (Join-Path $s.Runtime $key) -Text $files[$key]
        $hashes[$key] = Get-UpdRbSha -Path (Join-Path $s.Runtime $key)
    }
    Write-UpdRbFile -Path (Join-Path $s.Runtime 'RUNTIME_MANIFEST.json') -Text ((@{ schemaVersion = 1; files = $hashes } | ConvertTo-Json -Depth 5))
    $s.OrigTree = Get-UpdRbTreeHash -Root $s.Runtime
    Write-UpdRbFile -Path $s.VersionState -Text $updRbOldState
    $s.OrigStateSha = Get-UpdRbSha -Path $s.VersionState
    $s.Snapshot = Invoke-UpdRbCall -Name 'Get-BRAVOVersionStateSnapshot' -Arguments @{ VersionStatePath = $s.VersionState; OperationDirectory = $s.OpDir }
    $schedulerPath = Join-Path $s.OpDir 'scheduler-snapshot.json'
    Write-UpdRbFile -Path $schedulerPath -Text '{"schemaVersion":1,"tasks":[{"name":"T1","enabled":true}]}'
    Write-UpdRbFile -Path $s.VersionState -Text (Get-UpdRbStateText -Version '5.2.5')
    $s.RaisedStateSha = Get-UpdRbSha -Path $s.VersionState
    $journal = Invoke-UpdRbCall -Name 'New-BRAVOUpdateJournal' -Arguments @{
        StateRoot = $s.State; Action = 'Repair'; OperationId = $s.OperationId; PlanId = [guid]::NewGuid().ToString()
        RuntimeRoot = $s.Runtime; StagingRoot = (Join-Path $base 'staging'); BackupRoot = (Join-Path $base 'backup')
        SourceVersion = '5.2.5'; TargetVersion = '5.2.5'
    }
    [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalSchedulerSnapshot' -Arguments @{ Journal = $journal; Path = $schedulerPath; StateRoot = $s.State })
    [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalMutationStarted' -Arguments @{ Journal = $journal; StateRoot = $s.State })
    [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalField' -Arguments @{ Journal = $journal; Name = 'versionState'; Value = $s.Snapshot; StateRoot = $s.State })
    foreach ($phase in @('QuiesceTasks', 'ConfigureScheduler')) {
        [void](Invoke-UpdRbCall -Name 'Add-BRAVOUpdateJournalPhaseIntent' -Arguments @{ Journal = $journal; Phase = $phase; StateRoot = $s.State })
    }
    $s.Journal = $journal
    return $s
}

function Invoke-UpdRbRollback {
    param($Scenario, $Fault = $null, $Adapter = $null, [string]$JournalPath = '')
    if ($null -eq $Adapter) { $Adapter = @{} }
    # Корені engine передаються явно (journal trust): sandbox-значення, не production-шляхи.
    $arguments = @{
        Journal = $Scenario.Journal; Adapter = $Adapter; StateRoot = $Scenario.State; LockRoot = (Join-Path $Scenario.Base 'locks')
        OperationLockPath = $Scenario.OpLock; VersionStatePath = $Scenario.VersionState
        RuntimeRoot = $Scenario.Runtime; StagingRoot = $Scenario.Staging; BackupRoot = $Scenario.Backup
    }
    if ($JournalPath -ne '') { $arguments.JournalPath = $JournalPath }
    if ($null -ne $Fault) { $arguments.FaultInjection = $Fault }
    return (Invoke-UpdRbCall -Name 'Invoke-BRAVORollback' -Arguments $arguments)
}

# Журнал з диска (а не живий об'єкт): так бачить стан recovery після crash.
function Read-UpdRbJournal {
    param($Scenario)
    $path = Join-Path (Join-Path $Scenario.State 'Journal') ($Scenario.OperationId + '.json')
    return (Invoke-UpdRbCall -Name 'Read-BRAVOUpdateJournal' -Arguments @{ Path = $path }).Journal
}

# Сценарій Install: корінь створено операцією; ownership у журналі.
function New-UpdRbInstallScenario {
    param([string]$Name, [switch]$Foreign, [switch]$Modify, [switch]$Preexisting, [switch]$DeployKeysRecord, [switch]$NoHash)
    $base = Join-Path $updRbTemp ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $s = @{ Base = $base }
    $s.Runtime = Join-Path $base 'install root Кореневий'
    $s.State = Join-Path $base 'state'; $s.Staging = Join-Path $base 'staging'; $s.Backup = Join-Path $base 'backup'
    $s.OpLock = Join-Path $base 'locks\BRAVO_OPERATION.lock'
    $s.VersionState = Join-Path $base 'state-file\BRAVO_VERSION_STATE.json'
    $s.OperationId = [guid]::NewGuid().ToString()
    $s.OpDir = Join-Path (Join-Path $s.State 'Operations') $s.OperationId
    [void](New-Item -ItemType Directory -Path $s.State -Force)
    # Snapshot: state до install відсутній.
    $s.Snapshot = Invoke-UpdRbCall -Name 'Get-BRAVOVersionStateSnapshot' -Arguments @{ VersionStatePath = $s.VersionState; OperationDirectory = $s.OpDir }
    $journal = Invoke-UpdRbCall -Name 'New-BRAVOUpdateJournal' -Arguments @{
        StateRoot = $s.State; Action = 'Install'; OperationId = $s.OperationId; PlanId = [guid]::NewGuid().ToString()
        RuntimeRoot = $s.Runtime; StagingRoot = (Join-Path $base 'staging'); BackupRoot = (Join-Path $base 'backup'); TargetVersion = '5.2.6'
    }
    [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalMutationStarted' -Arguments @{ Journal = $journal; StateRoot = $s.State })
    [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalField' -Arguments @{ Journal = $journal; Name = 'versionState'; Value = $s.Snapshot; StateRoot = $s.State })
    if ($Preexisting) { [void][System.IO.Directory]::CreateDirectory($s.Runtime) }
    $ownership = New-Object System.Collections.Generic.List[string]
    if (-not $Preexisting) { $ownership.Add('dir:' + $s.Runtime) } else { $ownership.Add('marker:preexistingRoot') }
    $ownership.Add('dir:sub dir')
    $files = [ordered]@{ 'BRAVO_A.ps1' = 'installed A'; 'sub dir/B.ps1' = 'installed B'; 'BRAVO.local.config' = 'seeded' }
    $hashes = [ordered]@{}
    foreach ($key in $files.Keys) {
        $path = Join-Path $s.Runtime ($key -replace '/', '\')
        Write-UpdRbFile -Path $path -Text $files[$key]
        $hashes[$key] = Get-UpdRbSha -Path $path
    }
    if ($DeployKeysRecord) {
        $deployPath = Join-Path $s.OpDir 'deploy-keys.json'
        Write-UpdRbFile -Path $deployPath -Text ((@{ schemaVersion = 1; deployKeys = $hashes } | ConvertTo-Json -Depth 5))
        $ownership.Add('deploykeys:' + (Get-UpdRbSha -Path $deployPath))
    } else {
        foreach ($key in $files.Keys) {
            if ($NoHash -and $key -eq 'BRAVO.local.config') { $ownership.Add('file:' + $key) } else { $ownership.Add('file:' + $key + '|' + $hashes[$key]) }
        }
    }
    foreach ($entry in $ownership) { [void](Invoke-UpdRbCall -Name 'Add-BRAVOUpdateJournalCreatedOwnership' -Arguments @{ Journal = $journal; Key = $entry; StateRoot = $s.State }) }
    if ($Foreign) { Write-UpdRbFile -Path (Join-Path $s.Runtime 'operator-note.txt') -Text 'foreign' }
    if ($Modify) { Write-UpdRbFile -Path (Join-Path $s.Runtime 'BRAVO_A.ps1') -Text 'operator edited' }
    Write-UpdRbFile -Path $s.VersionState -Text (Get-UpdRbStateText -Version '5.2.6')
    $s.Journal = $journal
    return $s
}

# __UPDRB_HELPERS_END__ (дочірній процес no-prompt тесту завантажує текст до цього маркера)
try {
    # --- Characterization: legacy-поведінка Invoke-BRAVODeployExactRestore незмінна ---
    & {
        $rt = Join-Path $updRbTemp 'char rt'
        $bk = Join-Path $updRbTemp 'char bk'
        $st = Join-Path $updRbTemp 'char st'
        foreach ($d in @($rt, $bk, $st)) { [void](New-Item -ItemType Directory -Path $d -Force) }
        # backup: A (старий), M (старий manifest-only), runtime: A змінено, X додано, LOGS site
        Write-UpdRbFile -Path (Join-Path $bk 'A.ps1') -Text 'A old'
        Write-UpdRbFile -Path (Join-Path $bk 'sub\M.ps1') -Text 'M old'
        $oldSha = @{ 'A.ps1' = (Get-UpdRbSha -Path (Join-Path $bk 'A.ps1')); 'sub/M.ps1' = (Get-UpdRbSha -Path (Join-Path $bk 'sub\M.ps1')) }
        Write-UpdRbFile -Path (Join-Path $bk 'RUNTIME_MANIFEST.json') -Text ((@{ files = $oldSha } | ConvertTo-Json))
        Write-UpdRbFile -Path (Join-Path $st 'A.ps1') -Text 'A new'
        Write-UpdRbFile -Path (Join-Path $st 'X.ps1') -Text 'X new'
        Write-UpdRbFile -Path (Join-Path $st 'BRAVO.config') -Text 'staged site'
        Write-UpdRbFile -Path (Join-Path $rt 'A.ps1') -Text 'A new'
        Write-UpdRbFile -Path (Join-Path $rt 'X.ps1') -Text 'X new'
        Write-UpdRbFile -Path (Join-Path $rt 'BRAVO.config') -Text 'operator site'
        Write-UpdRbFile -Path (Join-Path $rt 'LOGS\l.log') -Text 'log'
        Write-UpdRbFile -Path (Join-Path $rt 'extra.txt') -Text 'operator file'
        $ownedLegacy = @(Invoke-UpdRbCall -Name 'Get-BRAVODeployOwnedKeys' -Arguments @{ StagedRoot = $st; BackupRoot = $bk; ExcludeFiles = @('BRAVO.config'); ExcludeDirs = @('LOGS') })
        Test-BRAVOCondition -Condition (($ownedLegacy | Sort-Object) -join ',' -eq 'A.ps1,sub/M.ps1,X.ps1') -Name 'UpdateRollback/Legacy/OwnedKeysUnion' -Failure "legacy owned = staged ∪ manifest-и мінус виключення; отримано: $($ownedLegacy -join ',')"
        $rep = Invoke-UpdRbCall -Name 'Invoke-BRAVODeployExactRestore' -Arguments @{ RuntimeRoot = $rt; BackupRoot = $bk; StagedRoot = $st; ExcludeFiles = @('BRAVO.config'); ExcludeDirs = @('LOGS') }
        Test-BRAVOCondition -Condition ($rep.OwnedCount -eq 3 -and (@($rep.Restored) -join ',') -match 'A.ps1' -and (@($rep.Restored) -join ',') -match 'sub/M.ps1' -and (@($rep.Removed) -join ',') -eq 'X.ps1' -and @($rep.Errors).Count -eq 0) -Name 'UpdateRollback/Legacy/ExactRestoreReport' -Failure 'legacy звіт відновлення змінився'
        Test-BRAVOCondition -Condition ([System.IO.File]::ReadAllText((Join-Path $rt 'A.ps1')) -eq 'A old' -and [System.IO.File]::ReadAllText((Join-Path $rt 'sub\M.ps1')) -eq 'M old' -and -not (Test-Path -LiteralPath (Join-Path $rt 'X.ps1')) -and [System.IO.File]::ReadAllText((Join-Path $rt 'BRAVO.config')) -eq 'operator site' -and (Test-Path -LiteralPath (Join-Path $rt 'LOGS\l.log')) -and (Test-Path -LiteralPath (Join-Path $rt 'extra.txt'))) -Name 'UpdateRollback/Legacy/FinalTree' -Failure 'legacy підсумкове дерево змінилося'
    }

    # --- -OwnedKeyList: staged не обходиться, backup-manifest додається, виключення діють ---
    & {
        $rt = Join-Path $updRbTemp 'okl rt'
        $bk = Join-Path $updRbTemp 'okl bk'
        foreach ($d in @($rt, $bk)) { [void](New-Item -ItemType Directory -Path $d -Force) }
        Write-UpdRbFile -Path (Join-Path $bk 'A.ps1') -Text 'A old'
        Write-UpdRbFile -Path (Join-Path $bk 'REM.ps1') -Text 'REM old'
        $oldSha = @{ 'A.ps1' = (Get-UpdRbSha -Path (Join-Path $bk 'A.ps1')); 'REM.ps1' = (Get-UpdRbSha -Path (Join-Path $bk 'REM.ps1')) }
        Write-UpdRbFile -Path (Join-Path $bk 'RUNTIME_MANIFEST.json') -Text ((@{ files = $oldSha } | ConvertTo-Json))
        Write-UpdRbFile -Path (Join-Path $rt 'A.ps1') -Text 'A new'
        Write-UpdRbFile -Path (Join-Path $rt 'N.ps1') -Text 'N new'
        Write-UpdRbFile -Path (Join-Path $rt 'stranger.ps1') -Text 'not owned'
        Write-UpdRbFile -Path (Join-Path $rt 'BRAVO.config') -Text 'site'
        $missingStaged = Join-Path $updRbTemp 'okl staged does not exist'
        $owned = @(Invoke-UpdRbCall -Name 'Get-BRAVODeployOwnedKeys' -Arguments @{ StagedRoot = $missingStaged; BackupRoot = $bk; ExcludeFiles = @('BRAVO.config'); OwnedKeyList = @('A.ps1', 'N.ps1', 'BRAVO.config') })
        Test-BRAVOCondition -Condition (($owned | Sort-Object) -join ',' -eq 'A.ps1,N.ps1,REM.ps1') -Name 'UpdateRollback/OwnedKeyList/Union' -Failure "OwnedKeyList ∪ backup manifest мінус виключення; отримано: $($owned -join ',')"
        $rep = Invoke-UpdRbCall -Name 'Invoke-BRAVODeployExactRestore' -Arguments @{ RuntimeRoot = $rt; BackupRoot = $bk; StagedRoot = $missingStaged; ExcludeFiles = @('BRAVO.config'); OwnedKeyList = @('A.ps1', 'N.ps1') }
        Test-BRAVOCondition -Condition (@($rep.Errors).Count -eq 0 -and [System.IO.File]::ReadAllText((Join-Path $rt 'A.ps1')) -eq 'A old' -and [System.IO.File]::ReadAllText((Join-Path $rt 'REM.ps1')) -eq 'REM old' -and -not (Test-Path -LiteralPath (Join-Path $rt 'N.ps1')) -and (Test-Path -LiteralPath (Join-Path $rt 'stranger.ps1')) -and [System.IO.File]::ReadAllText((Join-Path $rt 'BRAVO.config')) -eq 'site') -Name 'UpdateRollback/OwnedKeyList/RestoreOnlyOwned' -Failure 'з OwnedKeyList мають відновлюватися лише owned; чужі файли й site-файли лишаються'
        $bad = Invoke-UpdRbCall -Name 'Invoke-BRAVODeployExactRestore' -Arguments @{ RuntimeRoot = $rt; BackupRoot = $bk; StagedRoot = $missingStaged; OwnedKeyList = @('..\evil.ps1') }
        Test-BRAVOCondition -Condition (@($bad.Errors).Count -ge 1 -and $bad.OwnedCount -eq 0) -Name 'UpdateRollback/OwnedKeyList/DangerousKeyIsError' -Failure 'небезпечний ключ у OwnedKeyList має бути Errors, а не мовчазним пропуском'
        $empty = Invoke-UpdRbCall -Name 'Get-BRAVODeployOwnedKeys' -Arguments @{ StagedRoot = $missingStaged; BackupRoot = $bk; OwnedKeyList = [string[]]@() }
        Test-BRAVOCondition -Condition (@($empty | Sort-Object) -join ',' -eq 'A.ps1,REM.ps1') -Name 'UpdateRollback/OwnedKeyList/EmptyListIsNewMode' -Failure 'явно порожній OwnedKeyList = новий режим (лише backup manifest), не legacy обхід staged'
    }

    # --- Version-state: знімок ---
    & {
        $dir = Join-Path $updRbTemp 'vs snap Кирилиця'
        $statePath = Join-Path $dir 'BRAVO_VERSION_STATE.json'
        $opDir = Join-Path $dir 'op'
        $bytes = $updRbUtf8.GetBytes($updRbOldState)
        [void](New-Item -ItemType Directory -Path $dir -Force)
        [System.IO.File]::WriteAllBytes($statePath, $bytes)
        $snap = Invoke-UpdRbCall -Name 'Get-BRAVOVersionStateSnapshot' -Arguments @{ VersionStatePath = $statePath; OperationDirectory = $opDir }
        Test-BRAVOCondition -Condition ($snap.present -eq $true -and $snap.sha256 -eq (Get-UpdRbSha -Path $statePath) -and $snap.recordedVersion -eq '5.2.5' -and (Get-UpdRbSha -Path $snap.snapshotPath) -eq $snap.sha256) -Name 'UpdateRollback/Snapshot/PresentExactBytes' -Failure 'знімок має містити точні байти, sha і recordedVersion'
        $second = $null
        try { [void](Invoke-UpdRbCall -Name 'Get-BRAVOVersionStateSnapshot' -Arguments @{ VersionStatePath = $statePath; OperationDirectory = $opDir }) } catch { $second = $_ }
        Test-BRAVOCondition -Condition ($null -ne $second) -Name 'UpdateRollback/Snapshot/SecondSnapshotRefused' -Failure 'повторний знімок для тієї самої операції має відхилятися'
        $dir2 = Join-Path $updRbTemp 'vs snap absent'
        $snapAbsent = Invoke-UpdRbCall -Name 'Get-BRAVOVersionStateSnapshot' -Arguments @{ VersionStatePath = (Join-Path $dir2 'none.json'); OperationDirectory = (Join-Path $dir2 'op') }
        Test-BRAVOCondition -Condition ($snapAbsent.present -eq $false -and $null -eq $snapAbsent.sha256 -and (Test-Path -LiteralPath $snapAbsent.snapshotPath)) -Name 'UpdateRollback/Snapshot/AbsentMarker' -Failure 'для відсутнього state знімок = маркер absent'
    }

    # --- Version-state: таблиця рішень Restore-BRAVOVersionState ---
    & {
        $dir = Join-Path $updRbTemp 'vs table'
        [void](New-Item -ItemType Directory -Path $dir -Force)
        $makeSnap = {
            param([string]$Tag, [object]$InitialText)
            $statePath = Join-Path $dir ($Tag + '\state.json')
            if ($null -ne $InitialText) { Write-UpdRbFile -Path $statePath -Text $InitialText }
            $snap = Invoke-UpdRbCall -Name 'Get-BRAVOVersionStateSnapshot' -Arguments @{ VersionStatePath = $statePath; OperationDirectory = (Join-Path $dir ($Tag + '\op')) }
            return @{ State = $statePath; Snap = $snap }
        }
        $restore = { param($ctx, [string]$Target) Invoke-UpdRbCall -Name 'Restore-BRAVOVersionState' -Arguments @{ Snapshot = $ctx.Snap; VersionStatePath = $ctx.State; SourceVersion = '5.2.5'; TargetVersion = $Target } }

        $a = & $makeSnap 'nochange' $updRbOldState
        $r = & $restore $a '5.2.6'
        Test-BRAVOCondition -Condition ($r.Action -eq 'NoChange') -Name 'UpdateRollback/VersionState/NoChangeWhenEqualsSnapshot' -Failure 'sha == знімок -> NoChange'

        $a = & $makeSnap 'raised' $updRbOldState
        Write-UpdRbFile -Path $a.State -Text (Get-UpdRbStateText -Version '5.2.6')
        $r = & $restore $a '5.2.6'
        Test-BRAVOCondition -Condition ($r.Action -eq 'Restored' -and (Get-UpdRbSha -Path $a.State) -eq $a.Snap.sha256) -Name 'UpdateRollback/VersionState/RaisedToTargetRestored' -Failure 'recorded == target -> побайтове повернення знімка'

        $a = & $makeSnap 'between' $updRbOldState
        Write-UpdRbFile -Path $a.State -Text (Get-UpdRbStateText -Version '5.2.5-hotfix.1')
        $r = & $restore $a '5.2.6'
        Test-BRAVOCondition -Condition ($r.Action -eq 'Restored' -and (Get-UpdRbSha -Path $a.State) -eq $a.Snap.sha256) -Name 'UpdateRollback/VersionState/BetweenSnapshotAndTargetRestored' -Failure 'snapshot < recorded <= target -> Restored'

        $a = & $makeSnap 'higher' $updRbOldState
        Write-UpdRbFile -Path $a.State -Text (Get-UpdRbStateText -Version '5.9.0')
        $r = & $restore $a '5.2.6'
        Test-BRAVOCondition -Condition ($r.Action -eq 'Refused' -and (Get-UpdRbSha -Path $a.State) -ne $a.Snap.sha256) -Name 'UpdateRollback/VersionState/HigherThanTargetRefused' -Failure 'recorded > target -> Refused, файл не чіпається'

        $a = & $makeSnap 'corrupt' $updRbOldState
        Write-UpdRbFile -Path $a.State -Text '{ not json'
        $r = & $restore $a '5.2.6'
        Test-BRAVOCondition -Condition ($r.Action -eq 'Restored' -and (Get-UpdRbSha -Path $a.State) -eq $a.Snap.sha256) -Name 'UpdateRollback/VersionState/CorruptRestored' -Failure 'пошкоджений state -> повернути знімок'

        $a = & $makeSnap 'vanished' $updRbOldState
        [System.IO.File]::Delete($a.State)
        $r = & $restore $a '5.2.6'
        Test-BRAVOCondition -Condition ($r.Action -eq 'Restored' -and (Get-UpdRbSha -Path $a.State) -eq $a.Snap.sha256) -Name 'UpdateRollback/VersionState/VanishedRestored' -Failure 'зниклий state -> повернути знімок'

        $a = & $makeSnap 'absentnew' $null
        Write-UpdRbFile -Path $a.State -Text (Get-UpdRbStateText -Version '5.2.6')
        $r = & $restore $a '5.2.6'
        Test-BRAVOCondition -Condition ($r.Action -eq 'Restored' -and -not (Test-Path -LiteralPath $a.State)) -Name 'UpdateRollback/VersionState/AbsentSnapshotDeletesFile' -Failure 'знімок absent -> файл видаляється'

        $a = & $makeSnap 'absentstill' $null
        $r = & $restore $a '5.2.6'
        Test-BRAVOCondition -Condition ($r.Action -eq 'NoChange') -Name 'UpdateRollback/VersionState/AbsentBothNoChange' -Failure 'absent і досі absent -> NoChange'

        $a = & $makeSnap 'tampered' $updRbOldState
        Write-UpdRbFile -Path $a.Snap.snapshotPath -Text 'tampered snapshot'
        Write-UpdRbFile -Path $a.State -Text (Get-UpdRbStateText -Version '5.2.6')
        $r = & $restore $a '5.2.6'
        Test-BRAVOCondition -Condition ($r.Action -eq 'Refused') -Name 'UpdateRollback/VersionState/TamperedSnapshotRefused' -Failure 'пошкоджений знімок -> Refused'

        $a = & $makeSnap 'badtarget' $updRbOldState
        Write-UpdRbFile -Path $a.State -Text (Get-UpdRbStateText -Version '5.2.6')
        $r = & $restore $a 'not-a-version'
        Test-BRAVOCondition -Condition ($r.Action -eq 'Refused') -Name 'UpdateRollback/VersionState/UnparseableTargetRefused' -Failure 'нерозпізнана target -> Refused (fail closed)'
    }

    # --- Rollback: успіх (Update) ---
    & {
        Reset-UpdRbStubs
        $s = New-UpdRbUpdateScenario -Name 'ok' -ConfigureScheduler
        $result = Invoke-UpdRbRollback -Scenario $s
        $log = @(Get-UpdRbLog)
        $journalAfter = Read-UpdRbJournal -Scenario $s
        Test-BRAVOCondition -Condition ($result.status -eq 'RolledBack' -and $result.exitCode -eq 81 -and $result.action -eq 'Rollback') -Name 'UpdateRollback/Success/Result' -Failure "очікується RolledBack/81; отримано $($result.status)/$($result.exitCode) $($result.rollback.message)"
        Test-BRAVOCondition -Condition ((Get-UpdRbTreeHash -Root $s.Runtime) -eq $s.OrigTree) -Name 'UpdateRollback/Success/RuntimeEqualsBackup' -Failure 'після відкату дерево runtime має збігатися з вихідним (включно з видаленням доданих файлів і порожніх каталогів)'
        Test-BRAVOCondition -Condition ((Get-UpdRbSha -Path $s.VersionState) -eq $s.OrigStateSha) -Name 'UpdateRollback/Success/VersionStateRestored' -Failure 'state, піднятий до target, має бути повернений до знімка'
        Test-BRAVOCondition -Condition ($journalAfter.state -eq 'RolledBack' -and [int]$journalAfter.rollbackAttempts -eq 1) -Name 'UpdateRollback/Success/JournalRolledBackAttempts' -Failure 'журнал: RolledBack, rollbackAttempts=1'
        $expectedOrder = @('Disable', 'LiveRead', 'Reconcile', 'Validate:Rollback', 'RestoreTasks')
        Test-BRAVOCondition -Condition (($log -join ',') -eq ($expectedOrder -join ',')) -Name 'UpdateRollback/Success/StepOrderTasksLast' -Failure "порядок: Scheduler -> Validate -> RestoreTasks (без Disable); отримано: $($log -join ',')"
        $phaseNames = @($journalAfter.phases | ForEach-Object { [string]$_.phase })
        $allDurable = $true
        foreach ($p in @('Rollback.OperationLock', 'Rollback.QuiesceTasks', 'Rollback.RestoreFiles', 'Rollback.RestoreVersionState', 'Rollback.Verify', 'Rollback.Scheduler', 'Rollback.Validate', 'Rollback.RestoreTasks', 'Rollback.Finalize')) {
            $entry = @($journalAfter.phases | Where-Object { [string]$_.phase -eq $p })
            if ($entry.Count -ne 1 -or [string]$entry[0].outcome -ne 'Succeeded') { $allDurable = $false }
        }
        Test-BRAVOCondition -Condition $allDurable -Name 'UpdateRollback/Success/EveryStepDurable' -Failure "кожен крок має intent+completion у журналі; фази: $($phaseNames -join ',')"
        Test-BRAVOCondition -Condition ((-not (Invoke-UpdRbCall -Name 'Test-BRAVOUpdateOperationLockActive' -Arguments @{ OperationLockPath = $s.OpLock }).Active)) -Name 'UpdateRollback/Success/OperationLockReleased' -Failure 'operation lock має бути звільнено після відкату'
        Test-BRAVOCondition -Condition ([System.IO.File]::ReadAllText((Join-Path $s.Runtime 'BRAVO.local.config')) -eq 'site config' -and (Test-Path -LiteralPath (Join-Path $s.Runtime 'LOGS\run.log'))) -Name 'UpdateRollback/Success/SiteFilesUntouched' -Failure 'site-файли й LOGS не змінюються'
        Test-BRAVOCondition -Condition (Test-Path -LiteralPath $s.BackupDir) -Name 'UpdateRollback/Success/BackupKept' -Failure 'backup має зберігатися'
        $again = Invoke-UpdRbRollback -Scenario $s
        Test-BRAVOCondition -Condition ($again.status -eq 'RolledBack') -Name 'UpdateRollback/Success/RepeatIsIdempotent' -Failure 'повторний виклик після RolledBack має повертати RolledBack'

        # Без ConfigureScheduler-intent крок Scheduler не виконується.
        Reset-UpdRbStubs
        $s2 = New-UpdRbUpdateScenario -Name 'noschedulerintent'
        $r2 = Invoke-UpdRbRollback -Scenario $s2
        Test-BRAVOCondition -Condition ($r2.status -eq 'RolledBack' -and (@(Get-UpdRbLog) -notcontains 'Reconcile')) -Name 'UpdateRollback/Success/SchedulerSkippedWithoutIntent' -Failure 'Rollback.Scheduler лише якщо ConfigureScheduler мав intent'
    }

    # --- Crash у кожній фазі Rollback.* -> повторний запуск -> той самий фінальний стан ---
    & {
        foreach ($phase in @('Rollback.OperationLock', 'Rollback.QuiesceTasks', 'Rollback.RestoreFiles', 'Rollback.RestoreVersionState', 'Rollback.Verify', 'Rollback.Scheduler', 'Rollback.Validate', 'Rollback.RestoreTasks', 'Rollback.Finalize')) {
            foreach ($point in @('Before', 'AfterIntent', 'AfterSideEffect', 'AfterComplete')) {
                Reset-UpdRbStubs
                $s = New-UpdRbUpdateScenario -Name 'crash' -ConfigureScheduler
                $crashed = $false
                try { [void](Invoke-UpdRbRollback -Scenario $s -Fault @{ ($phase + '.' + $point) = 'Crash' }) } catch { if ([string]$_.Exception.Message -like '*BRAVOUpdate.SimulatedCrash*') { $crashed = $true } }
                $afterCrash = Read-UpdRbJournal -Scenario $s
                $openAfterCrash = ($afterCrash.state -eq 'Open') -or ($phase -eq 'Rollback.Finalize' -and $point -ne 'Before' -and $point -ne 'AfterIntent')
                # Нове «процесне» середовище: журнал перечитується з диска, як це робить recovery.
                $s.Journal = $afterCrash
                $result = Invoke-UpdRbRollback -Scenario $s
                $final = Read-UpdRbJournal -Scenario $s
                $converged = ($result.status -eq 'RolledBack') -and ((Get-UpdRbTreeHash -Root $s.Runtime) -eq $s.OrigTree) -and ((Get-UpdRbSha -Path $s.VersionState) -eq $s.OrigStateSha) -and ($final.state -eq 'RolledBack')
                $lockFree = -not (Invoke-UpdRbCall -Name 'Test-BRAVOUpdateOperationLockActive' -Arguments @{ OperationLockPath = $s.OpLock }).Active
                Test-BRAVOCondition -Condition ($crashed -and $openAfterCrash -and $converged -and $lockFree) -Name ('UpdateRollback/Crash/' + $phase + '.' + $point + '/Converges') -Failure "crash=$crashed openAfterCrash=$openAfterCrash status=$($result.status) converged=$converged lockFree=$lockFree"
            }
        }
    }

    # --- Throw у кроці -> Critical -> повтор із чистого середовища -> RolledBack ---
    & {
        Reset-UpdRbStubs
        $s = New-UpdRbUpdateScenario -Name 'throw' -ConfigureScheduler
        $result = Invoke-UpdRbRollback -Scenario $s -Fault @{ 'Rollback.RestoreFiles.AfterIntent' = 'Throw' }
        $journalAfter = Read-UpdRbJournal -Scenario $s
        $failedPhase = @($journalAfter.phases | Where-Object { [string]$_.phase -eq 'Rollback.RestoreFiles' })
        Test-BRAVOCondition -Condition ($result.status -eq 'Critical' -and $result.exitCode -eq 82 -and $journalAfter.state -eq 'Critical' -and (@(Get-UpdRbLog) -contains 'Disable') -and $failedPhase.Count -eq 1) -Name 'UpdateRollback/Throw/CriticalDisablesTasks' -Failure "збій кроку -> Critical/82, Disable, intent фази лишився; status=$($result.status)"
        Test-BRAVOCondition -Condition (@(Get-UpdRbLog) -notcontains 'RestoreTasks') -Name 'UpdateRollback/Throw/TasksNotRestored' -Failure 'при збої задачі не відновлюються'
        Reset-UpdRbStubs
        $s.Journal = $journalAfter
        $retry = Invoke-UpdRbRollback -Scenario $s
        $final = Read-UpdRbJournal -Scenario $s
        Test-BRAVOCondition -Condition ($retry.status -eq 'RolledBack' -and $final.state -eq 'RolledBack' -and [int]$final.rollbackAttempts -eq 2 -and (Get-UpdRbTreeHash -Root $s.Runtime) -eq $s.OrigTree) -Name 'UpdateRollback/Throw/RetryFromCriticalSucceeds' -Failure "повторний відкат із Critical має вдатися; status=$($retry.status)"
    }

    # --- recorded > target -> Critical ---
    & {
        Reset-UpdRbStubs
        $s = New-UpdRbUpdateScenario -Name 'higher'
        Write-UpdRbFile -Path $s.VersionState -Text (Get-UpdRbStateText -Version '5.9.0')
        $result = Invoke-UpdRbRollback -Scenario $s
        $journalAfter = Read-UpdRbJournal -Scenario $s
        $log = @(Get-UpdRbLog)
        Test-BRAVOCondition -Condition ($result.status -eq 'Critical' -and $result.exitCode -eq 82 -and $journalAfter.state -eq 'Critical') -Name 'UpdateRollback/Critical/RecordedAboveTarget' -Failure "recorded > target -> Critical; status=$($result.status) $($result.rollback.message)"
        Test-BRAVOCondition -Condition ($log -contains 'Disable' -and $log -notcontains 'RestoreTasks' -and (Get-UpdRbSha -Path $s.VersionState) -ne $s.OrigStateSha) -Name 'UpdateRollback/Critical/RecordedAboveTargetTasksDisabled' -Failure 'Critical: задачі вимкнено, не відновлено; state не змінено'
    }

    # --- Зламаний файл backup -> Critical, задачі лишаються вимкненими ---
    & {
        Reset-UpdRbStubs
        $s = New-UpdRbUpdateScenario -Name 'brokenbackup'
        Write-UpdRbFile -Path (Join-Path $s.BackupDir 'runtime\BRAVO_A.ps1') -Text 'corrupted backup content'
        $result = Invoke-UpdRbRollback -Scenario $s
        $log = @(Get-UpdRbLog)
        Test-BRAVOCondition -Condition ($result.status -eq 'Critical' -and $result.exitCode -eq 82 -and $log -contains 'Disable' -and $log -notcontains 'RestoreTasks' -and (Read-UpdRbJournal -Scenario $s).state -eq 'Critical') -Name 'UpdateRollback/Critical/BrokenBackupFile' -Failure "пошкоджений backup -> Critical, Disable, без RestoreTasks; status=$($result.status) $($result.rollback.message)"
        Test-BRAVOCondition -Condition ((@($result.findings | Where-Object { $_.id -eq 'Rollback.Critical' }).Count -eq 1)) -Name 'UpdateRollback/Critical/FindingPresent' -Failure 'Critical має містити finding Rollback.Critical'
    }

    # --- Збій валідації, неповне відновлення задач, відсутній deploy-keys, змінений deploy-keys, спроби ---
    & {
        Reset-UpdRbStubs -ValidationStatus 'Fail'
        $s = New-UpdRbUpdateScenario -Name 'validfail'
        $r = Invoke-UpdRbRollback -Scenario $s
        Test-BRAVOCondition -Condition ($r.status -eq 'Critical' -and (@(Get-UpdRbLog) -notcontains 'RestoreTasks')) -Name 'UpdateRollback/Critical/ValidationFailNoTaskRestore' -Failure 'Fail валідації -> Critical, задачі не вмикаються (крок 8 лише після 3-7)'
        Reset-UpdRbStubs -RestoreComplete $false
        $s = New-UpdRbUpdateScenario -Name 'taskfail'
        $r = Invoke-UpdRbRollback -Scenario $s
        Test-BRAVOCondition -Condition ($r.status -eq 'Critical' -and (@(Get-UpdRbLog) -contains 'Disable')) -Name 'UpdateRollback/Critical/IncompleteTaskRestore' -Failure 'IsComplete=$false -> Critical + Disable'
        Reset-UpdRbStubs
        $s = New-UpdRbUpdateScenario -Name 'tamperkeys'
        Write-UpdRbFile -Path $s.DeployKeysPath -Text '{"deployKeys":{"BRAVO_A.ps1":"AA"}}'
        $r = Invoke-UpdRbRollback -Scenario $s
        Test-BRAVOCondition -Condition ($r.status -eq 'Critical' -and (Get-UpdRbTreeHash -Root $s.Runtime) -eq $s.DeployedTree) -Name 'UpdateRollback/Critical/DeployKeysShaMismatch' -Failure 'deploy-keys.json з іншим SHA -> Critical, runtime не чіпається'
        Reset-UpdRbStubs
        $s = New-UpdRbUpdateScenario -Name 'attempts'
        [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalField' -Arguments @{ Journal = $s.Journal; Name = 'rollbackAttempts'; Value = 3; StateRoot = $s.State })
        $r = Invoke-UpdRbRollback -Scenario $s
        Test-BRAVOCondition -Condition ($r.status -eq 'Critical' -and (Get-UpdRbTreeHash -Root $s.Runtime) -eq $s.DeployedTree -and @(Get-UpdRbLog) -contains 'Disable') -Name 'UpdateRollback/Critical/AttemptsExhausted' -Failure 'після трьох спроб -> одразу Critical без змін'
        Reset-UpdRbStubs
        $s = New-UpdRbUpdateScenario -Name 'nosnapshot'
        [System.IO.File]::Delete($s.Snapshot.snapshotPath)
        [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalField' -Arguments @{ Journal = $s.Journal; Name = 'versionState'; Value = $null; StateRoot = $s.State })
        $r = Invoke-UpdRbRollback -Scenario $s
        Test-BRAVOCondition -Condition ($r.status -eq 'Critical') -Name 'UpdateRollback/Critical/MissingVersionStateSnapshot' -Failure 'без знімка state -> Critical'
    }

    # --- BRAVO_ALLOW_DOWNGRADE у середовищі -> відмова без змін ---
    & {
        Reset-UpdRbStubs
        $s = New-UpdRbUpdateScenario -Name 'envvar'
        [Environment]::SetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE', '1', 'Process')
        try {
            $r = Invoke-UpdRbRollback -Scenario $s
        } finally {
            [Environment]::SetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE', $updRbSavedDowngrade, 'Process')
        }
        $journalAfter = Read-UpdRbJournal -Scenario $s
        Test-BRAVOCondition -Condition ($r.status -eq 'Failed' -and $r.reasonCode -eq 'Blocked' -and $r.exitCode -eq 35 -and $journalAfter.state -eq 'Open' -and (Get-UpdRbTreeHash -Root $s.Runtime) -eq $s.DeployedTree -and @(Get-UpdRbLog).Count -eq 0) -Name 'UpdateRollback/Env/AllowDowngradeRefused' -Failure "BRAVO_ALLOW_DOWNGRADE -> Failed/Blocked/35 без змін; status=$($r.status)/$($r.exitCode)"
        $s.Journal = $journalAfter
        $ok = Invoke-UpdRbRollback -Scenario $s
        Test-BRAVOCondition -Condition ($ok.status -eq 'RolledBack') -Name 'UpdateRollback/Env/RollbackWorksOnceVariableRemoved' -Failure 'після прибирання змінної відкат має виконатися'
    }

    # --- Відкат clean install (§9.3) ---
    & {
        Reset-UpdRbStubs
        $s = New-UpdRbInstallScenario -Name 'inst-ok'
        $r = Invoke-UpdRbRollback -Scenario $s
        Test-BRAVOCondition -Condition ($r.status -eq 'RolledBack' -and -not (Test-Path -LiteralPath $s.Runtime) -and -not (Test-Path -LiteralPath $s.VersionState) -and (Read-UpdRbJournal -Scenario $s).state -eq 'RolledBack') -Name 'UpdateRollback/Install/RemovesOwnedAndRoot' -Failure "install rollback: файли, каталоги й створений корінь видалено, state повернуто до absent; status=$($r.status) $($r.rollback.message)"
        Test-BRAVOCondition -Condition (@(Get-UpdRbLog).Count -eq 0 -and $r.taskActivation.state -eq 'Inactive') -Name 'UpdateRollback/Install/NoQuiesceWithoutSchedulerIntent' -Failure 'без intent ConfigureScheduler install-відкат не торкається задач (жодних Disable/LiveRead); taskActivation=Inactive'

        Reset-UpdRbStubs
        $s = New-UpdRbInstallScenario -Name 'inst-keys' -DeployKeysRecord
        $r = Invoke-UpdRbRollback -Scenario $s
        Test-BRAVOCondition -Condition ($r.status -eq 'RolledBack' -and -not (Test-Path -LiteralPath $s.Runtime)) -Name 'UpdateRollback/Install/DeployKeysSingleRecord' -Failure "запис deploykeys: має давати той самий результат; status=$($r.status) $($r.rollback.message)"

        Reset-UpdRbStubs
        $s = New-UpdRbInstallScenario -Name 'inst-foreign' -Foreign
        $r = Invoke-UpdRbRollback -Scenario $s
        Test-BRAVOCondition -Condition ($r.status -eq 'RolledBack' -and [System.IO.File]::ReadAllText((Join-Path $s.Runtime 'operator-note.txt')) -eq 'foreign' -and -not (Test-Path -LiteralPath (Join-Path $s.Runtime 'BRAVO_A.ps1')) -and (@($r.findings | Where-Object { $_.severity -eq 'Warning' }).Count -ge 1)) -Name 'UpdateRollback/Install/ForeignFileKeptWarning' -Failure "сторонній файл лишається, відкат RolledBack + Warning; status=$($r.status)"

        Reset-UpdRbStubs
        $s = New-UpdRbInstallScenario -Name 'inst-modified' -Modify
        $r = Invoke-UpdRbRollback -Scenario $s
        Test-BRAVOCondition -Condition ($r.status -eq 'Critical' -and [System.IO.File]::ReadAllText((Join-Path $s.Runtime 'BRAVO_A.ps1')) -eq 'operator edited' -and -not (Test-Path -LiteralPath (Join-Path $s.Runtime 'sub dir\B.ps1'))) -Name 'UpdateRollback/Install/ModifiedOwnedFileCritical' -Failure 'змінений «наш» файл лишається, результат Critical'

        Reset-UpdRbStubs
        $s = New-UpdRbInstallScenario -Name 'inst-nohash' -NoHash
        $r = Invoke-UpdRbRollback -Scenario $s
        Test-BRAVOCondition -Condition ($r.status -eq 'Critical' -and (Test-Path -LiteralPath (Join-Path $s.Runtime 'BRAVO.local.config'))) -Name 'UpdateRollback/Install/UnhashedOwnedFileNotDeleted' -Failure 'файл ownership без хеша не видаляється; Critical'

        Reset-UpdRbStubs
        $s = New-UpdRbInstallScenario -Name 'inst-pre' -Preexisting
        $r = Invoke-UpdRbRollback -Scenario $s
        Test-BRAVOCondition -Condition ($r.status -eq 'RolledBack' -and (Test-Path -LiteralPath $s.Runtime -PathType Container) -and @(Get-ChildItem -LiteralPath $s.Runtime -Force).Count -eq 0) -Name 'UpdateRollback/Install/PreexistingRootKept' -Failure 'корінь із маркером preexistingRoot не видаляється'

        # Reparse point у шляху: файл за junction не видаляється.
        Reset-UpdRbStubs
        $s = New-UpdRbInstallScenario -Name 'inst-junction'
        $outside = Join-Path $s.Base 'outside target'
        Write-UpdRbFile -Path (Join-Path $outside 'victim.ps1') -Text 'must survive'
        $junction = Join-Path $s.Runtime 'linked'
        $mk = & cmd.exe /c ('mklink /J "' + $junction + '" "' + $outside + '"') 2>&1
        try {
            if (Test-Path -LiteralPath $junction) {
                $victimHash = Get-UpdRbSha -Path (Join-Path $outside 'victim.ps1')
                [void](Invoke-UpdRbCall -Name 'Add-BRAVOUpdateJournalCreatedOwnership' -Arguments @{ Journal = $s.Journal; Key = ('file:linked/victim.ps1|' + $victimHash); StateRoot = $s.State })
                $r = Invoke-UpdRbRollback -Scenario $s
                Test-BRAVOCondition -Condition ($r.status -eq 'Critical' -and [System.IO.File]::ReadAllText((Join-Path $outside 'victim.ps1')) -eq 'must survive') -Name 'UpdateRollback/Install/ReparsePointNotFollowed' -Failure 'файл за reparse point не має видалятися'
            } else {
                Test-BRAVOCondition -Condition $true -EnvironmentLimitation -Name 'UpdateRollback/Install/ReparsePointNotFollowed' -Failure ('mklink /J недоступний: ' + $mk)
            }
        } finally {
            # Спершу знімаємо junction (видаляється лише посилання), щоб прибирання не зайшло в outside.
            if (Test-Path -LiteralPath $junction) { [System.IO.Directory]::Delete($junction) }
        }

        # Crash у кожній фазі install-відкату -> повтор -> RolledBack.
        foreach ($phase in @('Rollback.OperationLock', 'Rollback.QuiesceTasks', 'Rollback.InstallCleanup', 'Rollback.RestoreVersionState', 'Rollback.Finalize')) {
            foreach ($point in @('AfterIntent', 'AfterSideEffect')) {
                Reset-UpdRbStubs
                $s = New-UpdRbInstallScenario -Name 'inst-crash'
                $crashed = $false
                try { [void](Invoke-UpdRbRollback -Scenario $s -Fault @{ ($phase + '.' + $point) = 'Crash' }) } catch { if ([string]$_.Exception.Message -like '*BRAVOUpdate.SimulatedCrash*') { $crashed = $true } }
                $s.Journal = Read-UpdRbJournal -Scenario $s
                $r = Invoke-UpdRbRollback -Scenario $s
                Test-BRAVOCondition -Condition ($crashed -and $r.status -eq 'RolledBack' -and -not (Test-Path -LiteralPath $s.Runtime) -and -not (Test-Path -LiteralPath $s.VersionState)) -Name ('UpdateRollback/InstallCrash/' + $phase + '.' + $point + '/Converges') -Failure "crash=$crashed status=$($r.status)"
            }
        }
    }

    # --- Repair -Scope Scheduler: backup = $null, збій після межі -> RolledBack (stub-и) ---
    & {
        Reset-UpdRbStubs
        $s = New-UpdRbSchedulerOnlyScenario -Name 'schedonly'
        $r = Invoke-UpdRbRollback -Scenario $s
        $log = @(Get-UpdRbLog)
        $journalAfter = Read-UpdRbJournal -Scenario $s
        Test-BRAVOCondition -Condition ($r.status -eq 'RolledBack' -and $journalAfter.state -eq 'RolledBack' -and $null -eq $journalAfter.backup) -Name 'UpdateRollback/SchedulerOnly/RolledBack' -Failure "backup=null: має бути RolledBack; status=$($r.status) $($r.rollback.message)"
        Test-BRAVOCondition -Condition ((Get-UpdRbTreeHash -Root $s.Runtime) -eq $s.OrigTree -and (Get-UpdRbSha -Path $s.VersionState) -eq $s.OrigStateSha) -Name 'UpdateRollback/SchedulerOnly/FilesUntouchedStateRestored' -Failure 'файли не змінюються, version-state повертається до знімка'
        Test-BRAVOCondition -Condition (($log -join ',') -eq 'Disable,LiveRead,Reconcile,Validate:Rollback,RestoreTasks') -Name 'UpdateRollback/SchedulerOnly/OnlyTaskStatesRestored' -Failure "scheduler -> validate -> restore tasks; отримано: $($log -join ',')"
    }

    # --- Жодна функція engine не питає в консолі: дочірній powershell.exe БЕЗ -NonInteractive,
    # реальні Test-BRAVODeploymentValidation/Invoke-BRAVORollback, таймаут = «завис на запиті» ---
    & {
        if ($null -eq (Get-Command -Name 'Start-BRAVOProcessWithBomFreeInput' -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $root 'modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1') -DisableNameChecking
        }
        $childDir = Join-Path $updRbTemp 'noprompt child'
        [void](New-Item -ItemType Directory -Path $childDir -Force)
        $childPath = Join-Path $childDir 'noprompt.ps1'
        $resultPath = Join-Path $childDir 'result.json'
        $childText = @'
param([string]$Root, [string]$Fragment, [string]$ResultPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = $Root
$src = [System.IO.File]::ReadAllText($Fragment)
$end = $src.IndexOf('# __UPDRB_HELPERS_END__')
. ([scriptblock]::Create($src.Substring(0, $end)))
# Скидаємо stub-и фрагмента; лишаємо stub лише для функцій, що торкаються Task Scheduler.
Import-Module (Join-Path $Root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking
$updRbModule = Get-Module BRAVO.Update
& $updRbModule {
    function script:Disable-BRAVOAllManagedTasks { [CmdletBinding()] param($Adapter, $RuntimeRoot = '', $Snapshot = $null) [pscustomobject]@{ Disabled = @(); Failed = @(); IsComplete = $true } }
    function script:Restore-BRAVOManagedTaskState { [CmdletBinding()] param($Snapshot, $Adapter) [pscustomobject]@{ Restored = @(); Failed = @(); IsComplete = $true } }
    function script:Get-BRAVOSchedulerSnapshot { [CmdletBinding()] param($Adapter, $RuntimeRoot = '', $TaskPath = '', $ManagedTaskName = @()) [pscustomobject]@{ tasks = @() } }
    function script:Invoke-BRAVOSchedulerReconcile { [CmdletBinding()] param($Context, $Snapshot) [pscustomobject]@{ Verdict = 'PASS'; ExitCode = 0; CreatedTasks = @(); RequiescedTasks = @(); Problems = @() } }
}
$ok = { param($RuntimeRoot, $LogPath) [pscustomobject]@{ ExitCode = 0; Output = ''; TimedOut = $false } }
$adapter = @{
    InvokeGuard = $ok; InvokeSetupValidate = $ok; InvokeSetupScheduler = $ok; InvokeSelfTest = $ok
    TestCredentialPresence = { param($RuntimeRoot, $Component) [pscustomobject]@{ Component = $Component; Presence = 'Found'; ExitCode = 0 } }
    GetManagedTasks = { param($TaskPath) @() }
    SetTaskEnabled = { param($TaskPath, $Name, $Enabled) [pscustomobject]@{ Success = $true; Message = '' } }
    GetEffectiveConfiguration = { param($RuntimeRoot) [pscustomobject]@{ Success = $true; ExitCode = 0; Configuration = $null; Message = '' } }
    Now = { [datetime]::UtcNow }
}
$s = New-UpdRbSchedulerOnlyScenario -Name 'child'
# Baseline site-конфігурації (U10): без нього реальна валідація SiteConfigPreserved = Fail.
$site = Invoke-UpdRbCall -Name 'Get-BRAVOSiteConfigurationBaseline' -Arguments @{ RuntimeRoot = $s.Runtime }
[void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalField' -Arguments @{ Journal = $s.Journal; Name = 'baseline'; Value = ([pscustomobject]@{ siteConfig = $site; guardExitCode = 0 }); StateRoot = $s.State })
$r = Invoke-UpdRbCall -Name 'Invoke-BRAVORollback' -Arguments @{
    Journal = $s.Journal; Adapter = $adapter; StateRoot = $s.State; LockRoot = (Join-Path $s.Base 'locks')
    OperationLockPath = $s.OpLock; VersionStatePath = $s.VersionState
    RuntimeRoot = $s.Runtime; StagingRoot = $s.Staging; BackupRoot = $s.Backup
}
$payload = [pscustomobject]@{ status = [string]$r.status; message = [string]$r.rollback.message; treeSame = ((Get-UpdRbTreeHash -Root $s.Runtime) -eq $s.OrigTree) }
[System.IO.File]::WriteAllText($ResultPath, ($payload | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
$tmp = [System.IO.Path]::GetFullPath($updRbTemp)
if ($tmp.StartsWith([System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()), [System.StringComparison]::OrdinalIgnoreCase) -and ([System.IO.Path]::GetFileName($tmp)).StartsWith('bravo-updrb-')) {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
'@
        [System.IO.File]::WriteAllText($childPath, $childText, (New-Object System.Text.UTF8Encoding($true)))
        $fragmentPath = Join-Path $root 'selftest\BRAVO_SELF_TEST.UpdateRollback.ps1'
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $psExe
        # Навмисно БЕЗ -NonInteractive: запит Mandatory-параметра тоді завис би (таймаут).
        $startInfo.Arguments = '-NoProfile -ExecutionPolicy RemoteSigned -File "' + $childPath + '" -Root "' + $root + '" -Fragment "' + $fragmentPath + '" -ResultPath "' + $resultPath + '"'
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        $timedOut = $false
        $childOutput = ''
        try {
            Start-BRAVOProcessWithBomFreeInput -Process $process
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(240000)) {
                $timedOut = $true
                # Лише власний об'єкт Process (handle зі Start).
                try { $process.Kill() } catch { $null = $_ }
            } else {
                $process.WaitForExit()
                $childOutput = [string]$stdoutTask.Result + [string]$stderrTask.Result
            }
        } finally {
            $process.Dispose()
        }
        $parsed = $null
        if ([System.IO.File]::Exists($resultPath)) { $parsed = [System.IO.File]::ReadAllText($resultPath) | ConvertFrom-Json }
        Test-BRAVOCondition -Condition ((-not $timedOut) -and $null -ne $parsed -and $parsed.status -eq 'RolledBack' -and $parsed.treeSame) -Name 'UpdateRollback/SchedulerOnly/NoPromptInChildWithoutNonInteractive' -Failure "timedOut=$timedOut status=$(if ($null -ne $parsed) { $parsed.status + ' ' + $parsed.message } else { 'немає результату' }) output=$childOutput"
    }

    # --- P1-a: durable quiesce задач ПЕРЕД відновленням файлів (crash після Activate) ---
    & {
        $s = New-UpdRbUpdateScenario -Name 'activate'
        [void](Invoke-UpdRbCall -Name 'Add-BRAVOUpdateJournalPhaseIntent' -Arguments @{ Journal = $s.Journal; Phase = 'Activate'; StateRoot = $s.State })
        $runtimePath = $s.Runtime
        $probe = { if ([System.IO.File]::ReadAllText((Join-Path $runtimePath 'BRAVO_A.ps1')) -eq 'new A') { 'deployed' } else { 'restored' } }.GetNewClosure()
        Reset-UpdRbStubs -Probe $probe
        $r = Invoke-UpdRbRollback -Scenario $s
        $log = @(Get-UpdRbLog)
        Test-BRAVOCondition -Condition ($r.status -eq 'RolledBack' -and $log.Count -ge 2 -and $log[0] -eq 'Disable@deployed' -and $log[1] -eq 'LiveRead') -Name 'UpdateRollback/Quiesce/TasksDisabledBeforeFileRestore' -Failure "Disable має бути першим і до зміни файлів (deployed); log: $($log -join ',')"

        # Crash у Rollback.RestoreTasks -> повторний запуск знову спочатку вимикає задачі.
        $s2 = New-UpdRbUpdateScenario -Name 'activate2'
        Reset-UpdRbStubs
        $crashed = $false
        try { [void](Invoke-UpdRbRollback -Scenario $s2 -Fault @{ 'Rollback.RestoreTasks.AfterSideEffect' = 'Crash' }) } catch { $crashed = $true }
        $s2.Journal = Read-UpdRbJournal -Scenario $s2
        $r2 = Invoke-UpdRbRollback -Scenario $s2
        $disables = @(@(Get-UpdRbLog) | Where-Object { $_ -like 'Disable*' })
        Test-BRAVOCondition -Condition ($crashed -and $r2.status -eq 'RolledBack' -and $disables.Count -eq 2) -Name 'UpdateRollback/Quiesce/RerunQuiescesAgain' -Failure "кожен (пере)запуск починається з quiesce; Disable=$($disables.Count)"

        # Задача лишилась увімкненою після вимкнення -> Critical, файли не чіпаються.
        Reset-UpdRbStubs -LiveEnabled $true
        $s3 = New-UpdRbUpdateScenario -Name 'stillenabled'
        $r3 = Invoke-UpdRbRollback -Scenario $s3
        Test-BRAVOCondition -Condition ($r3.status -eq 'Critical' -and (Get-UpdRbTreeHash -Root $s3.Runtime) -eq $s3.DeployedTree -and @(Get-UpdRbLog) -notcontains 'RestoreTasks') -Name 'UpdateRollback/Quiesce/StillEnabledIsCritical' -Failure "увімкнена задача після quiesce -> Critical без змін; status=$($r3.status)"
    }

    # --- P1-b: junction у runtime -> відкат відмовляє, ціль поза коренем не чіпається ---
    & {
        Reset-UpdRbStubs
        $s = New-UpdRbUpdateScenario -Name 'junction'
        $outside = Join-Path $s.Base 'outside target'
        Write-UpdRbFile -Path (Join-Path $outside 'B.ps1') -Text 'outside victim'
        $sub = Join-Path $s.Runtime 'sub dir'
        Remove-Item -LiteralPath $sub -Recurse -Force
        $mk = & cmd.exe /c ('mklink /J "' + $sub + '" "' + $outside + '"') 2>&1
        try {
            if (Test-Path -LiteralPath $sub) {
                $r = Invoke-UpdRbRollback -Scenario $s
                Test-BRAVOCondition -Condition ($r.status -eq 'Critical' -and [System.IO.File]::ReadAllText((Join-Path $outside 'B.ps1')) -eq 'outside victim' -and [System.IO.File]::ReadAllText((Join-Path $s.Runtime 'BRAVO_A.ps1')) -eq 'new A' -and @($r.findings | Where-Object { $_.id -eq 'Rollback.Critical' }).Count -eq 1) -Name 'UpdateRollback/Reparse/JunctionInRuntimeRefused' -Failure "junction у runtime: Critical, ціль поза коренем і файли не змінено; status=$($r.status) $($r.rollback.message)"
            } else {
                Test-BRAVOCondition -Condition $true -EnvironmentLimitation -Name 'UpdateRollback/Reparse/JunctionInRuntimeRefused' -Failure ('mklink /J недоступний: ' + $mk)
            }
        } finally {
            if (Test-Path -LiteralPath $sub) { [System.IO.File]::GetAttributes($sub) | Out-Null; [System.IO.Directory]::Delete($sub) }
        }
    }

    # --- Підроблений журнал: Critical без жодних побічних ефектів ---
    & {
        $attacker = Join-Path $updRbTemp 'attacker files'
        Write-UpdRbFile -Path (Join-Path $attacker 'BRAVO_A.ps1') -Text 'attacker file'
        Write-UpdRbFile -Path (Join-Path $attacker 'installed.txt') -Text 'attacker'
        Write-UpdRbFile -Path (Join-Path $attacker 'snap.snapshot') -Text 'attacker snapshot'
        $attackerBefore = Get-UpdRbTreeHash -Root $attacker
        $forgeries = @(
            @{ Name = 'ForeignRuntimeRoot'; Apply = { param($s) $s.Journal.runtimeRoot = $attacker } },
            @{ Name = 'BackupPathOutsideBackupRoot'; Apply = { param($s) $s.Journal.backup.path = $attacker } },
            @{ Name = 'SnapshotPathOutsideOperations'; Apply = { param($s) $s.Journal.versionState.snapshotPath = (Join-Path $attacker 'snap.snapshot') } },
            @{ Name = 'SchedulerSnapshotOutsideOperations'; Apply = { param($s) $s.Journal.schedulerSnapshot.path = (Join-Path $attacker 'snap.snapshot') } },
            @{ Name = 'ForeignBackupRoot'; Apply = { param($s) $s.Journal.backupRoot = $attacker } },
            @{ Name = 'ForeignStagingRoot'; Apply = { param($s) $s.Journal.stagingRoot = $attacker } }
        )
        foreach ($forgery in $forgeries) {
            Reset-UpdRbStubs
            $s = New-UpdRbUpdateScenario -Name 'forged'
            $stateBefore = Get-UpdRbSha -Path $s.VersionState
            & $forgery.Apply $s
            $calls = New-Object System.Collections.Generic.List[string]
            $adapter = @{
                GetManagedTasks = { param($p) $calls.Add('GetManagedTasks') }.GetNewClosure()
                SetTaskEnabled = { param($p, $n, $e) $calls.Add('SetTaskEnabled') }.GetNewClosure()
                InvokeSetupScheduler = { param($r) $calls.Add('InvokeSetupScheduler') }.GetNewClosure()
                InvokeGuard = { param($r) $calls.Add('InvokeGuard') }.GetNewClosure()
            }
            $r = Invoke-UpdRbRollback -Scenario $s -Adapter $adapter
            $clean = ($r.status -eq 'Critical') -and ($calls.Count -eq 0) -and (@(Get-UpdRbLog).Count -eq 0) -and ((Get-UpdRbTreeHash -Root $attacker) -eq $attackerBefore) -and ((Get-UpdRbTreeHash -Root $s.Runtime) -eq $s.DeployedTree) -and ((Get-UpdRbSha -Path $s.VersionState) -eq $stateBefore) -and ((Read-UpdRbJournal -Scenario $s).state -eq 'Open') -and (@($r.findings | Where-Object { $_.id -eq 'Rollback.JournalUntrusted' }).Count -eq 1)
            Test-BRAVOCondition -Condition $clean -Name ('UpdateRollback/Forged/' + $forgery.Name) -Failure "status=$($r.status) adapterCalls=$($calls.Count) log=$(@(Get-UpdRbLog) -join ',') $($r.rollback.message)"
        }

        # operationId не збігається з іменем файлу журналу.
        Reset-UpdRbStubs
        $s = New-UpdRbUpdateScenario -Name 'forged-opid'
        $otherName = Join-Path (Join-Path $s.State 'Journal') ([guid]::NewGuid().ToString() + '.json')
        $r = Invoke-UpdRbRollback -Scenario $s -JournalPath $otherName
        Test-BRAVOCondition -Condition ($r.status -eq 'Critical' -and @(Get-UpdRbLog).Count -eq 0 -and (Get-UpdRbTreeHash -Root $s.Runtime) -eq $s.DeployedTree) -Name 'UpdateRollback/Forged/OperationIdFileNameMismatch' -Failure "opId != ім'я файлу -> Critical без дій; status=$($r.status)"
        $s.Journal.operationId = 'NOT-A-GUID'
        $r = Invoke-UpdRbRollback -Scenario $s
        Test-BRAVOCondition -Condition ($r.status -eq 'Critical' -and @(Get-UpdRbLog).Count -eq 0) -Name 'UpdateRollback/Forged/OperationIdNotGuid' -Failure "operationId не GUID -> Critical без дій; status=$($r.status)"

        # Без переданого RuntimeRoot (Update) довіряти runtimeRoot із журналу не можна.
        Reset-UpdRbStubs
        $s = New-UpdRbUpdateScenario -Name 'noruntimeroot'
        $arguments = @{ Journal = $s.Journal; Adapter = @{}; StateRoot = $s.State; OperationLockPath = $s.OpLock; VersionStatePath = $s.VersionState; StagingRoot = $s.Staging; BackupRoot = $s.Backup }
        $r = Invoke-UpdRbCall -Name 'Invoke-BRAVORollback' -Arguments $arguments
        Test-BRAVOCondition -Condition ($r.status -eq 'Critical' -and @(Get-UpdRbLog).Count -eq 0 -and (Get-UpdRbTreeHash -Root $s.Runtime) -eq $s.DeployedTree) -Name 'UpdateRollback/Forged/RuntimeRootNotSuppliedFailsClosed' -Failure "без RuntimeRoot -> Critical без дій; status=$($r.status)"

        # Install: journal.runtimeRoot != корінь викликача -> файли за підміненим коренем не видаляються.
        Reset-UpdRbStubs
        $s = New-UpdRbInstallScenario -Name 'forged-install'
        $fakeRoot = Join-Path $updRbTemp 'attacker install root'
        Write-UpdRbFile -Path (Join-Path $fakeRoot 'BRAVO_A.ps1') -Text 'installed A'
        Write-UpdRbFile -Path (Join-Path $fakeRoot 'sub dir\B.ps1') -Text 'installed B'
        $fakeBefore = Get-UpdRbTreeHash -Root $fakeRoot
        $s.Journal.runtimeRoot = $fakeRoot
        $r = Invoke-UpdRbRollback -Scenario $s
        $s.Journal.runtimeRoot = $s.Runtime
        Test-BRAVOCondition -Condition ($r.status -eq 'Critical' -and (Get-UpdRbTreeHash -Root $fakeRoot) -eq $fakeBefore -and (Test-Path -LiteralPath $s.Runtime) -and @(Get-UpdRbLog).Count -eq 0) -Name 'UpdateRollback/Forged/InstallForeignRuntimeRoot' -Failure "Install: підмінений корінь -> Critical без дій; status=$($r.status) $($r.rollback.message)"
    }

    # --- Install-відкат не виконує конфігурацію з недобудованого runtime (P1 PR bot) ---
    & {
        $mkAdapter = {
            param($Calls)
            @{
                GetEffectiveConfiguration = { param($RuntimeRoot) $Calls.Add('GetEffectiveConfiguration'); throw 'config loader з недобудованого runtime виконувати не можна' }.GetNewClosure()
                GetManagedTasks = { param($TaskPath, $RuntimeRoot) $Calls.Add('GetManagedTasks'); throw 'scope з конфігурації' }.GetNewClosure()
                SetTaskEnabled = { param($TaskPath, $Name, $Enabled, $RuntimeRoot) $Calls.Add('SetTaskEnabled:' + $Name + ':' + $Enabled); [pscustomobject]@{ Success = $true; Message = '' } }.GetNewClosure()
            }
        }
        # Збій на ранній фазі (немає ConfigureScheduler intent): задач немає, adapter не викликається.
        Reset-UpdRbStubs
        $s = New-UpdRbInstallScenario -Name 'inst-early'
        $calls = New-Object System.Collections.Generic.List[string]
        $r = Invoke-UpdRbRollback -Scenario $s -Adapter (& $mkAdapter $calls)
        Test-BRAVOCondition -Condition ($r.status -eq 'RolledBack' -and -not (Test-Path -LiteralPath $s.Runtime) -and $calls.Count -eq 0) -Name 'UpdateRollback/Install/EarlyFailureNoConfigCodeRolledBack' -Failure "ранній збій install: RolledBack, корінь видалено, adapter не викликано; status=$($r.status) calls=$($calls -join ',') $($r.rollback.message)"

        # createdTasks: вимикаються напряму; конфігурація (scope) не завантажується.
        Reset-UpdRbStubs
        $s = New-UpdRbInstallScenario -Name 'inst-created'
        [void](Invoke-UpdRbCall -Name 'Add-BRAVOUpdateJournalPhaseIntent' -Arguments @{ Journal = $s.Journal; Phase = 'ConfigureScheduler'; StateRoot = $s.State })
        [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalField' -Arguments @{ Journal = $s.Journal; Name = 'createdTasks'; Value = @([pscustomobject]@{ path = '\BRAVO\'; name = 'BRAVO_A' }); StateRoot = $s.State })
        $calls = New-Object System.Collections.Generic.List[string]
        $r = Invoke-UpdRbRollback -Scenario $s -Adapter (& $mkAdapter $calls)
        Test-BRAVOCondition -Condition ($r.status -eq 'RolledBack' -and -not (Test-Path -LiteralPath $s.Runtime) -and (@($calls) -contains 'SetTaskEnabled:BRAVO_A:False') -and (@($calls) -notcontains 'GetEffectiveConfiguration') -and (@($calls) -notcontains 'GetManagedTasks')) -Name 'UpdateRollback/Install/CreatedTasksDisabledWithoutConfigLoad' -Failure "createdTasks вимикаються без читання конфігурації; status=$($r.status) calls=$($calls -join ',') $($r.rollback.message)"
    }

    # --- Repair пошкодженого runtime: setup-validate падав і ДО операції (baseline-aware відкат) ---
    & {
        Reset-UpdRbStubs
        $s = New-UpdRbUpdateScenario -Name 'repair-setup-baseline' -ConfigureScheduler
        $s.Journal.action = 'Repair'
        [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalField' -Arguments @{ Journal = $s.Journal; Name = 'baseline'; Value = ([pscustomobject]@{ siteConfig = $null; guardExitCode = 0; setupValidateExitCode = 1 }); StateRoot = $s.State })
        $r = Invoke-UpdRbRollback -Scenario $s
        $log = @(Get-UpdRbLog)
        $seen = & $updRbModule { $script:UpdRbLastValidate }
        Test-BRAVOCondition -Condition ($r.status -eq 'RolledBack' -and $log -notcontains 'Reconcile' -and $log -contains 'RestoreTasks' -and [int]$seen.Setup -eq 1) -Name 'UpdateRollback/RepairSetupBaseline/SchedulerSkippedTasksRestored' -Failure "baseline setup=1: повторну реєстрацію пропущено, стани задач відновлено, baseline передано у валідацію; status=$($r.status) log=$($log -join ',') $($r.rollback.message)"
        Test-BRAVOCondition -Condition (@($r.findings | Where-Object { $_.id -eq 'Rollback.SchedulerReRegistrationSkipped' }).Count -eq 1 -and @($r.findings | Where-Object { $_.id -eq 'Repair.RuntimeStillDamaged' }).Count -eq 1) -Name 'UpdateRollback/RepairSetupBaseline/Findings' -Failure 'очікуються findings Rollback.SchedulerReRegistrationSkipped і Repair.RuntimeStillDamaged'

        # Baseline setup = 0 (здоровий): повторна реєстрація виконується як зазвичай.
        Reset-UpdRbStubs
        $s2 = New-UpdRbUpdateScenario -Name 'repair-setup-ok' -ConfigureScheduler
        $s2.Journal.action = 'Repair'
        [void](Invoke-UpdRbCall -Name 'Set-BRAVOUpdateJournalField' -Arguments @{ Journal = $s2.Journal; Name = 'baseline'; Value = ([pscustomobject]@{ siteConfig = $null; guardExitCode = 0; setupValidateExitCode = 0 }); StateRoot = $s2.State })
        $r2 = Invoke-UpdRbRollback -Scenario $s2
        Test-BRAVOCondition -Condition ($r2.status -eq 'RolledBack' -and @(Get-UpdRbLog) -contains 'Reconcile') -Name 'UpdateRollback/RepairSetupBaseline/HealthyBaselineStillReconciles' -Failure "baseline setup=0 -> Rollback.Scheduler виконується; status=$($r2.status)"
    }

    # --- Прямий виклик Invoke-BRAVOInstallRollback з недовіреним журналом ---
    & {
        Reset-UpdRbStubs
        $s = New-UpdRbInstallScenario -Name 'direct-install'
        $s.Journal.operationId = 'bad id'
        $direct = Invoke-UpdRbCall -Name 'Invoke-BRAVOInstallRollback' -Arguments @{ Journal = $s.Journal; Adapter = @{}; StateRoot = $s.State }
        Test-BRAVOCondition -Condition ((-not $direct.Success) -and @(Get-UpdRbLog).Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $s.Runtime 'BRAVO_A.ps1'))) -Name 'UpdateRollback/Forged/InstallRollbackDirectUntrusted' -Failure 'Invoke-BRAVOInstallRollback сам перевіряє довіру до будь-якої дії'
    }
    # --- Реальна Test-BRAVODeploymentValidation: SetupValidate baseline-aware у Mode Rollback ---
    & {
        # Перезавантаження модуля скидає stub-и: далі працює справжня валідація.
        Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking
        $realModule = Get-Module BRAVO.Update
        $vr = Join-Path $updRbTemp 'real validation rt'
        Write-UpdRbFile -Path (Join-Path $vr 'VERSION.json') -Text '{"packageVersion":"5.2.5"}'
        Write-UpdRbFile -Path (Join-Path $vr 'RUNTIME_MANIFEST.json') -Text '{"schemaVersion":1,"files":{}}'
        $mkContext = {
            param($Code)
            $codeValue = $Code
            [pscustomobject]@{
                Adapter = @{
                    InvokeGuard = { param($RuntimeRoot, $LogPath) [pscustomobject]@{ ExitCode = 0; Output = ''; TimedOut = $false } }
                    InvokeSetupValidate = { param($RuntimeRoot, $LogPath) [pscustomobject]@{ ExitCode = $codeValue; Output = ''; TimedOut = $false } }.GetNewClosure()
                }
                Paths = [pscustomobject]@{ RuntimeRoot = $vr }; OperationDirectory = ''; Plan = $null
            }
        }
        $setupItem = {
            param($Code, $Baseline)
            $arguments = @{ Context = (& $mkContext $Code); Mode = 'Rollback'; ExpectedVersion = '5.2.5'; ExpectedManifestPath = (Join-Path $vr 'RUNTIME_MANIFEST.json'); SiteBaseline = $null }
            if ($null -ne $Baseline) { $arguments.SetupValidateBaselineExitCode = $Baseline }
            $result = & $realModule { param($a) Test-BRAVODeploymentValidation @a } $arguments
            return @($result.Items | Where-Object { $_.Name -eq 'SetupValidate' })[0].Status
        }
        Test-BRAVOCondition -Condition ((& $setupItem 1 1) -eq 'Warn') -Name 'UpdateRollback/Validation/SetupEqualBaselineIsWarn' -Failure 'збій setup, що збігається з baseline, у Rollback -> Warn'
        Test-BRAVOCondition -Condition ((& $setupItem 1 $null) -eq 'Fail') -Name 'UpdateRollback/Validation/SetupFailWithoutBaselineIsFail' -Failure 'без baseline збій setup лишається Fail'
        Test-BRAVOCondition -Condition ((& $setupItem 2 1) -eq 'Fail') -Name 'UpdateRollback/Validation/SetupDifferentFromBaselineIsFail' -Failure 'код, відмінний від baseline, лишається Fail'
        Test-BRAVOCondition -Condition ((& $setupItem 0 1) -eq 'Pass') -Name 'UpdateRollback/Validation/SetupPassStillPass' -Failure 'код 0 лишається Pass'
    }

} finally {
    [Environment]::SetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE', $updRbSavedDowngrade, 'Process')
    # Перезавантаження модуля скидає stub-и, визначені в його області.
    Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking
    $tempFull = [System.IO.Path]::GetFullPath($updRbTemp)
    $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($tempFull.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and ([System.IO.Path]::GetFileName($tempFull)).StartsWith('bravo-updrb-') -and (Test-Path -LiteralPath $tempFull)) {
        Remove-Item -LiteralPath $tempFull -Recurse -Force -ErrorAction SilentlyContinue
    }
}
