# ============================================================
# UpdateReconcile: конфігурація, scheduler і активація задач (INS-045/046)
# ============================================================
# Перевіряється реальний модуль BRAVO.Update (частина Reconcile). Task Scheduler,
# BRAVO_SETUP і Credential Manager не чіпаються: adapter завжди stub, усі корені —
# у тимчасовому каталозі з пробілами та кирилицею. Default-adapter перевіряється
# лише на гілках, що кидають виняток ДО звернення до COM.

Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking

$reconcileTestModule = Get-Module BRAVO.Update

function Invoke-ReconcileTestCall {
    # Виклик приватної/публічної функції модуля за ім'ям із splat-параметрами.
    param([string]$Name, [hashtable]$Params = @{})
    return (& $reconcileTestModule { param($FunctionName, $FunctionParams) & $FunctionName @FunctionParams } $Name $Params)
}

function Test-ReconcileTestThrows {
    param([string]$Name, [hashtable]$Params = @{})
    try { [void](Invoke-ReconcileTestCall -Name $Name -Params $Params); return $false } catch { return $true }
}

function New-ReconcileTestStub {
    # Stub-стан Task Scheduler + adapter; усі виклики пишуться в $stub.Log.
    param([string[]]$Existing = @(), [string[]]$Enabled = @(), [string]$ConfigTaskPath = 'BRAVO Тест', [string]$RowPath = '\BRAVO Тест\')
    $names = @('BRAVO-Backup', 'BRAVO-Maintenance', 'BRAVO-Health', 'BRAVO-Recovery', 'BRAVO-BAZASync', 'BRAVO-RestoreVerify', 'BRAVO-BackupCatchUp', 'BRAVO-ServiceRecovery')
    $stub = @{
        Names = $names; ConfigTaskPath = $ConfigTaskPath; RowPath = $RowPath
        Tasks = @{}; Log = (New-Object System.Collections.Generic.List[string])
        SetupExit = 0; SetupTimedOut = $false; SetupThrow = $false; SetupCreates = @()
        FailSet = @(); ThrowSet = @(); LieSet = @(); GetFail = $false; GetFailAfterSetup = $false; SetupDone = $false
        ConfigFail = $false; Running = @(); Noise = $true
    }
    foreach ($name in $Existing) { $stub.Tasks[$name] = @{ Enabled = ($Enabled -contains $name); State = 'Ready' } }
    $adapter = @{}
    $adapter.GetEffectiveConfiguration = {
        param($RuntimeRoot)
        $stub.Log.Add('CONFIG')
        if ($stub.ConfigFail) { return [pscustomobject]@{ Success = $false; ExitCode = 1; Configuration = $null; Message = 'config stub fail' } }
        $scheduler = [ordered]@{ TaskPath = $stub.ConfigTaskPath }
        $keys = @('Backup', 'Maintenance', 'Health', 'Recovery', 'BAZASync', 'RestoreVerify', 'BackupCatchUp', 'ServiceRecovery')
        for ($i = 0; $i -lt $keys.Count; $i++) { $scheduler[$keys[$i]] = [pscustomobject]@{ TaskName = $stub.Names[$i]; Enabled = $true } }
        return [pscustomobject]@{ Success = $true; ExitCode = 0; Configuration = [pscustomobject]@{ schedulerSettings = [pscustomobject]$scheduler }; Message = '' }
    }.GetNewClosure()
    $adapter.GetManagedTasks = {
        param($TaskPath, $RuntimeRoot)
        $stub.Log.Add('GET')
        if ($stub.GetFail -or ($stub.GetFailAfterSetup -and $stub.SetupDone)) { throw 'get stub fail' }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($name in @($stub.Tasks.Keys)) {
            $state = $stub.Tasks[$name].State
            if ($stub.Running -contains $name) { $state = 'Running' }
            $rows.Add([pscustomobject]@{ Name = $name; Path = $stub.RowPath; Exists = $true; State = $state; Enabled = [bool]$stub.Tasks[$name].Enabled })
        }
        if ($stub.Noise) {
            $rows.Add([pscustomobject]@{ Name = 'Other-Task'; Path = $stub.RowPath; Exists = $true; State = 'Ready'; Enabled = $true })
            $rows.Add([pscustomobject]@{ Name = 'BRAVO-Backup'; Path = '\Other\'; Exists = $true; State = 'Ready'; Enabled = $true })
        }
        return $rows.ToArray()
    }.GetNewClosure()
    $adapter.SetTaskEnabled = {
        param($TaskPath, $Name, $Enabled)
        $stub.Log.Add(('SET|{0}|{1}|{2}' -f $TaskPath, $Name, $Enabled))
        if ($stub.ThrowSet -contains $Name) { throw 'set stub throw' }
        if ($stub.FailSet -contains $Name) { return [pscustomobject]@{ Success = $false; Message = 'set stub fail' } }
        if (-not $stub.Tasks.ContainsKey($Name)) { return [pscustomobject]@{ Success = $false; Message = 'немає задачі' } }
        # LieSet: adapter повідомляє успіх, але стан не змінює (перевірка читанням має це виявити).
        if (-not ($stub.LieSet -contains $Name)) { $stub.Tasks[$Name].Enabled = [bool]$Enabled }
        return [pscustomobject]@{ Success = $true; Message = '' }
    }.GetNewClosure()
    $adapter.InvokeSetupScheduler = {
        param($RuntimeRoot)
        $stub.Log.Add('SETUP')
        if ($stub.SetupThrow) { throw 'setup stub throw' }
        # F1: повторна реєстрація вмикає всі задачі й створює відсутні.
        foreach ($name in @($stub.Tasks.Keys)) { $stub.Tasks[$name].Enabled = $true }
        foreach ($name in @($stub.SetupCreates)) { $stub.Tasks[$name] = @{ Enabled = $true; State = 'Ready' } }
        $stub.SetupDone = $true
        return [pscustomobject]@{ ExitCode = $stub.SetupExit; Output = ''; TimedOut = $stub.SetupTimedOut }
    }.GetNewClosure()
    $adapter.Now = { [datetime]::UtcNow }.GetNewClosure()
    return [pscustomobject]@{ Stub = $stub; Adapter = $adapter }
}

function Get-ReconcileTestSetCalls {
    param($Stub, [string]$Value = '')
    return @($Stub.Log | Where-Object { $_ -like 'SET|*' -and ($Value -eq '' -or $_ -like ('*|' + $Value)) })
}

$reconcileTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO узгодження тест ' + [guid]::NewGuid().ToString('N'))
$reconcileTestPrefix = Join-Path ([IO.Path]::GetTempPath()) 'BRAVO узгодження тест '
try {
    New-Item -ItemType Directory -Path $reconcileTestRoot -Force | Out-Null

    # ------------------------------------------------------------------
    # Baseline site-конфігурації
    # ------------------------------------------------------------------
    & {
        $runtime = Join-Path $reconcileTestRoot 'Програми Toolkit\runtime'
        New-Item -ItemType Directory -Path $runtime -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $runtime 'BRAVO.local.config'), '{"a":1}', (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $runtime 'WinSCP.ini'), '[Sessions]', (New-Object Text.UTF8Encoding $false))

        $baseline = Invoke-ReconcileTestCall -Name 'Get-BRAVOSiteConfigurationBaseline' -Params @{ RuntimeRoot = $runtime }
        $byName = @{}
        foreach ($entry in @($baseline.files)) { $byName[[string]$entry.name] = [string]$entry.sha256 }
        $expectedLocal = (Get-FileHash -LiteralPath (Join-Path $runtime 'BRAVO.local.config') -Algorithm SHA256).Hash.ToUpperInvariant()
        Test-BRAVOCondition -Condition ($byName.Count -eq 4) -Name 'UpdateReconcile/Baseline.FourFiles' -Failure 'baseline має покривати рівно 4 файли site-конфігурації'
        Test-BRAVOCondition -Condition ($byName['BRAVO.local.config'] -ceq $expectedLocal) -Name 'UpdateReconcile/Baseline.LocalConfigSha' -Failure 'хеш local.config має бути SHA-256 UPPER'
        Test-BRAVOCondition -Condition (($byName['BRAVO.config'] -ceq 'absent') -and ($byName['TOOLS_INTEGRITY.json'] -ceq 'absent')) -Name 'UpdateReconcile/Baseline.Absent' -Failure 'відсутні файли мають бути absent'

        $same = Invoke-ReconcileTestCall -Name 'Test-BRAVOSiteConfigurationPreserved' -Params @{ RuntimeRoot = $runtime; Baseline = $baseline }
        Test-BRAVOCondition -Condition (($same.name -ceq 'SiteConfigPreserved') -and ($same.status -ceq 'Pass')) -Name 'UpdateReconcile/Preserved.Unchanged' -Failure 'незмінна конфігурація має дати Pass'

        [IO.File]::WriteAllText((Join-Path $runtime 'BRAVO.local.config'), '{"a":2}', (New-Object Text.UTF8Encoding $false))
        $changed = Invoke-ReconcileTestCall -Name 'Test-BRAVOSiteConfigurationPreserved' -Params @{ RuntimeRoot = $runtime; Baseline = $baseline }
        Test-BRAVOCondition -Condition (($changed.status -ceq 'Fail') -and ($changed.message -like '*BRAVO.local.config*')) -Name 'UpdateReconcile/Preserved.ChangedFileFails' -Failure 'зміна local.config має дати Fail з іменем файлу'
        Test-BRAVOCondition -Condition ($changed.message -notlike '*"a"*') -Name 'UpdateReconcile/Preserved.NoContentInMessage' -Failure 'message не має містити вміст файлу'

        [IO.File]::WriteAllText((Join-Path $runtime 'BRAVO.local.config'), '{"a":1}', (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $runtime 'BRAVO.config'), 'legacy', (New-Object Text.UTF8Encoding $false))
        $appeared = Invoke-ReconcileTestCall -Name 'Test-BRAVOSiteConfigurationPreserved' -Params @{ RuntimeRoot = $runtime; Baseline = $baseline }
        Test-BRAVOCondition -Condition ($appeared.status -ceq 'Fail') -Name 'UpdateReconcile/Preserved.AppearedFileFails' -Failure 'файл, що з''явився (absent -> є), має дати Fail'
        Remove-Item -LiteralPath (Join-Path $runtime 'BRAVO.config') -Force
        Remove-Item -LiteralPath (Join-Path $runtime 'WinSCP.ini') -Force
        $removed = Invoke-ReconcileTestCall -Name 'Test-BRAVOSiteConfigurationPreserved' -Params @{ RuntimeRoot = $runtime; Baseline = $baseline }
        Test-BRAVOCondition -Condition (($removed.status -ceq 'Fail') -and ($removed.message -like '*WinSCP.ini*')) -Name 'UpdateReconcile/Preserved.RemovedFileFails' -Failure 'видалений WinSCP.ini має дати Fail'

        $nullBaseline = Invoke-ReconcileTestCall -Name 'Test-BRAVOSiteConfigurationPreserved' -Params @{ RuntimeRoot = $runtime; Baseline = $null }
        Test-BRAVOCondition -Condition ($nullBaseline.status -ceq 'Fail') -Name 'UpdateReconcile/Preserved.NullBaselineFails' -Failure 'порожній baseline = Fail (fail closed)'
        $truncated = [pscustomobject]@{ files = @([pscustomobject]@{ name = 'BRAVO.local.config'; sha256 = $expectedLocal }) }
        $truncatedResult = Invoke-ReconcileTestCall -Name 'Test-BRAVOSiteConfigurationPreserved' -Params @{ RuntimeRoot = $runtime; Baseline = $truncated }
        Test-BRAVOCondition -Condition ($truncatedResult.status -ceq 'Fail') -Name 'UpdateReconcile/Preserved.TruncatedBaselineFails' -Failure 'усічений baseline має дати Fail'
        $emptyHash = [pscustomobject]@{ files = @([pscustomobject]@{ name = 'BRAVO.local.config'; sha256 = '' }) }
        $emptyHashResult = Invoke-ReconcileTestCall -Name 'Test-BRAVOSiteConfigurationPreserved' -Params @{ RuntimeRoot = $runtime; Baseline = $emptyHash }
        Test-BRAVOCondition -Condition ($emptyHashResult.status -ceq 'Fail') -Name 'UpdateReconcile/Preserved.CorruptBaselineFails' -Failure 'baseline з порожнім хешем має дати Fail'

        # Каталог на місці файлу конфігурації — baseline неможливий.
        $dirRoot = Join-Path $reconcileTestRoot 'dir-as-config'
        New-Item -ItemType Directory -Path (Join-Path $dirRoot 'BRAVO.config') -Force | Out-Null
        Test-BRAVOCondition -Condition (Test-ReconcileTestThrows -Name 'Get-BRAVOSiteConfigurationBaseline' -Params @{ RuntimeRoot = $dirRoot }) -Name 'UpdateReconcile/Baseline.DirectoryThrows' -Failure 'каталог замість файлу має кидати виняток'
        # Порожній runtime (clean install): усе absent, і воно ж зберігається.
        $emptyRuntime = Join-Path $reconcileTestRoot 'empty runtime'
        New-Item -ItemType Directory -Path $emptyRuntime -Force | Out-Null
        $emptyBaseline = Invoke-ReconcileTestCall -Name 'Get-BRAVOSiteConfigurationBaseline' -Params @{ RuntimeRoot = $emptyRuntime }
        $emptyCheck = Invoke-ReconcileTestCall -Name 'Test-BRAVOSiteConfigurationPreserved' -Params @{ RuntimeRoot = $emptyRuntime; Baseline = $emptyBaseline }
        Test-BRAVOCondition -Condition ((@($emptyBaseline.files | Where-Object { $_.sha256 -ceq 'absent' }).Count -eq 4) -and ($emptyCheck.status -ceq 'Pass')) -Name 'UpdateReconcile/Baseline.AllAbsentPasses' -Failure 'порожній runtime: усе absent і Pass'
    }

    # ------------------------------------------------------------------
    # Область керованих задач та TaskPath
    # ------------------------------------------------------------------
    & {
        Test-BRAVOCondition -Condition ((Invoke-ReconcileTestCall -Name 'ConvertTo-BRAVOUpdateTaskPath' -Params @{ TaskPath = 'BRAVO' }) -ceq '\BRAVO\') -Name 'UpdateReconcile/TaskPath.Plain' -Failure 'BRAVO -> \BRAVO\'
        Test-BRAVOCondition -Condition ((Invoke-ReconcileTestCall -Name 'ConvertTo-BRAVOUpdateTaskPath' -Params @{ TaskPath = '\BRAVO Тест\Під\' }) -ceq '\BRAVO Тест\Під\') -Name 'UpdateReconcile/TaskPath.CyrillicNested' -Failure 'вкладений шлях з кирилицею має зберігатись'
        Test-BRAVOCondition -Condition ((Invoke-ReconcileTestCall -Name 'ConvertTo-BRAVOUpdateTaskPath' -Params @{ TaskPath = '\' }) -ceq '\') -Name 'UpdateReconcile/TaskPath.Root' -Failure 'корінь лишається \'
        Test-BRAVOCondition -Condition (Test-ReconcileTestThrows -Name 'ConvertTo-BRAVOUpdateTaskPath' -Params @{ TaskPath = '\BRAVO\..\Microsoft' }) -Name 'UpdateReconcile/TaskPath.DotDotThrows' -Failure '.. у TaskPath має кидати виняток'
        Test-BRAVOCondition -Condition (Test-ReconcileTestThrows -Name 'ConvertTo-BRAVOUpdateTaskPath' -Params @{ TaskPath = '  ' }) -Name 'UpdateReconcile/TaskPath.EmptyThrows' -Failure 'порожній TaskPath має кидати виняток'

        $fixture = New-ReconcileTestStub
        $configuration = (& $fixture.Adapter.GetEffectiveConfiguration 'x').Configuration
        $scope = Invoke-ReconcileTestCall -Name 'Get-BRAVOUpdateManagedTaskScope' -Params @{ Configuration = $configuration }
        Test-BRAVOCondition -Condition (($scope.TaskPath -ceq '\BRAVO Тест\') -and (@($scope.Names).Count -eq 8)) -Name 'UpdateReconcile/Scope.EightNames' -Failure 'область має містити TaskPath і 8 імен'
        $noScheduler = [pscustomobject]@{ pathSettings = [pscustomobject]@{} }
        Test-BRAVOCondition -Condition (Test-ReconcileTestThrows -Name 'Get-BRAVOUpdateManagedTaskScope' -Params @{ Configuration = $noScheduler }) -Name 'UpdateReconcile/Scope.NoSchedulerThrows' -Failure 'без schedulerSettings має бути виняток'
        $badName = [pscustomobject]@{ schedulerSettings = [pscustomobject]@{ TaskPath = 'BRAVO'; Backup = [pscustomobject]@{ TaskName = 'a\b' } } }
        Test-BRAVOCondition -Condition (Test-ReconcileTestThrows -Name 'Get-BRAVOUpdateManagedTaskScope' -Params @{ Configuration = $badName }) -Name 'UpdateReconcile/Scope.SlashInNameThrows' -Failure 'ім''я зі слешем має кидати виняток'
        $dup = [pscustomobject]@{ schedulerSettings = [pscustomobject]@{ TaskPath = 'BRAVO'; Backup = [pscustomobject]@{ TaskName = 'T1' }; Health = [pscustomobject]@{ TaskName = 't1' }; Recovery = [pscustomobject]@{ TaskName = 'T2' } } }
        $dupScope = Invoke-ReconcileTestCall -Name 'Get-BRAVOUpdateManagedTaskScope' -Params @{ Configuration = $dup }
        Test-BRAVOCondition -Condition (@($dupScope.Names).Count -eq 2) -Name 'UpdateReconcile/Scope.DedupeCaseInsensitive' -Failure 'дублікати імен (без регістру) мають зливатись; відсутні вузли пропускаються (legacy)'
    }

    # ------------------------------------------------------------------
    # Знімок scheduler: 0 / 1 / N, шум, збої
    # ------------------------------------------------------------------
    & {
        $zero = New-ReconcileTestStub
        $snapshotZero = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $zero.Adapter; RuntimeRoot = 'C:\fake runtime' }
        Test-BRAVOCondition -Condition ((@($snapshotZero.tasks).Count -eq 8) -and (@($snapshotZero.tasks | Where-Object { $_.exists }).Count -eq 0)) -Name 'UpdateReconcile/Snapshot.ZeroTasks' -Failure '0 існуючих: 8 керованих імен, жодне не exists'
        Test-BRAVOCondition -Condition (($snapshotZero.taskPath -ceq '\BRAVO Тест\') -and ($snapshotZero.schemaVersion -eq 1)) -Name 'UpdateReconcile/Snapshot.TaskPathFromConfig' -Failure 'taskPath береться з ефективної конфігурації'
        Test-BRAVOCondition -Condition (@($snapshotZero.tasks | Where-Object { $_.name -ceq 'Other-Task' }).Count -eq 0) -Name 'UpdateReconcile/Snapshot.ForeignTaskIgnored' -Failure 'сторонні задачі не входять у знімок'

        $one = New-ReconcileTestStub -Existing @('BRAVO-Backup') -Enabled @('BRAVO-Backup')
        $snapshotOne = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $one.Adapter; RuntimeRoot = 'C:\fake runtime' }
        $backupEntry = @($snapshotOne.tasks | Where-Object { $_.name -ceq 'BRAVO-Backup' })[0]
        Test-BRAVOCondition -Condition ($backupEntry.exists -and $backupEntry.enabled -and ($backupEntry.state -ceq 'Ready') -and (-not $backupEntry.isRunning)) -Name 'UpdateReconcile/Snapshot.OneEnabled' -Failure 'увімкнена задача: exists/enabled/state Ready'
        Test-BRAVOCondition -Condition ($backupEntry.path -ceq '\BRAVO Тест\') -Name 'UpdateReconcile/Snapshot.SameNameOtherPathIgnored' -Failure 'однойменна задача з \Other\ не має впливати на знімок'

        $names = @('BRAVO-Backup', 'BRAVO-Maintenance', 'BRAVO-Health', 'BRAVO-Recovery', 'BRAVO-BAZASync', 'BRAVO-RestoreVerify', 'BRAVO-BackupCatchUp', 'BRAVO-ServiceRecovery')
        $many = New-ReconcileTestStub -Existing $names -Enabled @('BRAVO-Backup', 'BRAVO-Health')
        $many.Stub.Running = @('BRAVO-Health')
        $snapshotMany = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $many.Adapter; RuntimeRoot = 'C:\fake runtime' }
        $healthEntry = @($snapshotMany.tasks | Where-Object { $_.name -ceq 'BRAVO-Health' })[0]
        Test-BRAVOCondition -Condition ((@($snapshotMany.tasks | Where-Object { $_.exists }).Count -eq 8) -and (@($snapshotMany.tasks | Where-Object { $_.enabled }).Count -eq 2)) -Name 'UpdateReconcile/Snapshot.ManyTasks' -Failure 'N=8: усі exists, 2 enabled'
        Test-BRAVOCondition -Condition ($healthEntry.isRunning -and ($healthEntry.state -ceq 'Running')) -Name 'UpdateReconcile/Snapshot.RunningDetected' -Failure 'Running має давати isRunning'

        $configFail = New-ReconcileTestStub
        $configFail.Stub.ConfigFail = $true
        Test-BRAVOCondition -Condition (Test-ReconcileTestThrows -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $configFail.Adapter; RuntimeRoot = 'C:\fake runtime' }) -Name 'UpdateReconcile/Snapshot.ConfigFailThrows' -Failure 'збій ефективної конфігурації = виняток (fail closed)'
        $getFail = New-ReconcileTestStub
        $getFail.Stub.GetFail = $true
        Test-BRAVOCondition -Condition (Test-ReconcileTestThrows -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $getFail.Adapter; RuntimeRoot = 'C:\fake runtime' }) -Name 'UpdateReconcile/Snapshot.GetFailThrows' -Failure 'збій GetManagedTasks = виняток, а не «задач немає»'
        $explicit = New-ReconcileTestStub -Existing @('X1') -Enabled @('X1')
        $explicitSnapshot = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $explicit.Adapter; TaskPath = '\BRAVO Тест\'; ManagedTaskName = @('X1') }
        Test-BRAVOCondition -Condition ((@($explicit.Stub.Log | Where-Object { $_ -eq 'CONFIG' }).Count -eq 0) -and $explicitSnapshot.tasks[0].enabled) -Name 'UpdateReconcile/Snapshot.ExplicitScopeSkipsConfig' -Failure 'явна область не має читати конфігурацію'
        Test-BRAVOCondition -Condition (Test-ReconcileTestThrows -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = @{}; RuntimeRoot = 'C:\fake runtime' }) -Name 'UpdateReconcile/Snapshot.AdapterWithoutActionThrows' -Failure 'adapter без дій має кидати виняток'
    }

    # ------------------------------------------------------------------
    # Збереження знімка (Save/Read), журнал
    # ------------------------------------------------------------------
    & {
        $fixture = New-ReconcileTestStub -Existing @('BRAVO-Backup', 'BRAVO-Health') -Enabled @('BRAVO-Backup')
        $snapshot = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $fixture.Adapter; RuntimeRoot = 'C:\fake runtime' }
        $operationDirectory = Join-Path $reconcileTestRoot 'Операції\op знімок'
        $stateRoot = Join-Path $reconcileTestRoot 'state знімок'
        $journal = Invoke-ReconcileTestCall -Name 'New-BRAVOUpdateJournal' -Params @{ StateRoot = $stateRoot; Action = 'Update' }
        $saved = Invoke-ReconcileTestCall -Name 'Save-BRAVOSchedulerSnapshot' -Params @{ Snapshot = $snapshot; OperationDirectory = $operationDirectory; Journal = $journal; StateRoot = $stateRoot }
        $fileSha = (Get-FileHash -LiteralPath $saved.Path -Algorithm SHA256).Hash.ToUpperInvariant()
        Test-BRAVOCondition -Condition (($saved.Path -ceq (Join-Path $operationDirectory 'scheduler-snapshot.json')) -and ($saved.Sha256 -ceq $fileSha)) -Name 'UpdateReconcile/Save.PathAndSha' -Failure 'Save має повернути шлях і SHA-256 файлу'
        $bytes = [IO.File]::ReadAllBytes($saved.Path)
        Test-BRAVOCondition -Condition (-not (($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB))) -Name 'UpdateReconcile/Save.NoBom' -Failure 'JSON знімка має бути UTF-8 без BOM'
        $readJournal = Invoke-ReconcileTestCall -Name 'Read-BRAVOUpdateJournal' -Params @{ Path = (Join-Path $stateRoot ('Journal\' + $journal.operationId + '.json')) }
        Test-BRAVOCondition -Condition ($readJournal.IsValid -and ([string]$readJournal.Journal.schedulerSnapshot.path -ceq $saved.Path)) -Name 'UpdateReconcile/Save.JournalPointer' -Failure 'шлях знімка має бути в журналі'

        $read = Invoke-ReconcileTestCall -Name 'Read-BRAVOSchedulerSnapshot' -Params @{ Path = $saved.Path }
        Test-BRAVOCondition -Condition ($read.IsValid -and (@($read.Snapshot.tasks).Count -eq 8) -and ($read.Snapshot.taskPath -ceq '\BRAVO Тест\')) -Name 'UpdateReconcile/Read.RoundTrip' -Failure 'знімок має читатись з диска без втрат'
        $restoreFromDisk = Invoke-ReconcileTestCall -Name 'Restore-BRAVOManagedTaskState' -Params @{ Snapshot = $read.Snapshot; Adapter = $fixture.Adapter }
        Test-BRAVOCondition -Condition ($restoreFromDisk.IsComplete -and (@($restoreFromDisk.Restored).Count -eq 1)) -Name 'UpdateReconcile/Read.UsableForRestore' -Failure 'прочитаний з диска знімок має бути придатний для Restore'

        $corrupt = Join-Path $operationDirectory 'corrupt.json'
        [IO.File]::WriteAllText($corrupt, '{ not json', (New-Object Text.UTF8Encoding $false))
        $empty = Join-Path $operationDirectory 'empty.json'
        [IO.File]::WriteAllText($empty, '', (New-Object Text.UTF8Encoding $false))
        $partial = Join-Path $operationDirectory 'partial.json'
        [IO.File]::WriteAllText($partial, '{"schemaVersion":1,"taskPath":"\\BRAVO\\"}', (New-Object Text.UTF8Encoding $false))
        $missing = Join-Path $operationDirectory 'missing.json'
        foreach ($case in @(@('corrupt', $corrupt), @('empty', $empty), @('partial', $partial), @('missing', $missing))) {
            $bad = Invoke-ReconcileTestCall -Name 'Read-BRAVOSchedulerSnapshot' -Params @{ Path = $case[1] }
            Test-BRAVOCondition -Condition ((-not $bad.IsValid) -and ($null -eq $bad.Snapshot -or $case[0] -eq 'partial') -and (@($bad.Problems).Count -gt 0)) -Name ('UpdateReconcile/Read.Invalid.' + $case[0]) -Failure ('знімок "' + $case[0] + '" має бути IsValid=$false без винятку')
        }
        Test-BRAVOCondition -Condition (Test-ReconcileTestThrows -Name 'Save-BRAVOSchedulerSnapshot' -Params @{ Snapshot = [pscustomobject]@{ taskPath = '' }; OperationDirectory = $operationDirectory }) -Name 'UpdateReconcile/Save.InvalidSnapshotThrows' -Failure 'непридатний знімок не записується'
        Test-BRAVOCondition -Condition (Test-ReconcileTestThrows -Name 'Save-BRAVOSchedulerSnapshot' -Params @{ Snapshot = $snapshot; OperationDirectory = $operationDirectory; Journal = $journal }) -Name 'UpdateReconcile/Save.JournalNeedsStateRoot' -Failure 'Journal без StateRoot має кидати виняток'

        # createdTasks: додається, дедуплікується, журнал лишається валідним.
        $created = @([pscustomobject]@{ path = '\BRAVO Тест\'; name = 'BRAVO-Health' })
        $null = Invoke-ReconcileTestCall -Name 'Add-BRAVOUpdateJournalCreatedTask' -Params @{ Journal = $journal; Task = $created; StateRoot = $stateRoot }
        $null = Invoke-ReconcileTestCall -Name 'Add-BRAVOUpdateJournalCreatedTask' -Params @{ Journal = $journal; Task = $created; StateRoot = $stateRoot }
        $afterCreated = Invoke-ReconcileTestCall -Name 'Read-BRAVOUpdateJournal' -Params @{ Path = (Join-Path $stateRoot ('Journal\' + $journal.operationId + '.json')) }
        Test-BRAVOCondition -Condition ($afterCreated.IsValid -and (@($afterCreated.Journal.createdTasks).Count -eq 1) -and ($afterCreated.Journal.createdTasks[0].name -ceq 'BRAVO-Health')) -Name 'UpdateReconcile/Journal.CreatedTaskDedupe' -Failure 'createdTasks: один запис без дублікатів, журнал валідний'
    }

    # ------------------------------------------------------------------
    # Suspend / Restore / Disable-All
    # ------------------------------------------------------------------
    & {
        $names = @('BRAVO-Backup', 'BRAVO-Maintenance', 'BRAVO-Health', 'BRAVO-Recovery')
        $fixture = New-ReconcileTestStub -Existing $names -Enabled @('BRAVO-Backup', 'BRAVO-Health')
        $snapshot = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $fixture.Adapter; RuntimeRoot = 'C:\fake runtime' }

        $suspend = Invoke-ReconcileTestCall -Name 'Suspend-BRAVOManagedTasks' -Params @{ Snapshot = $snapshot; Adapter = $fixture.Adapter }
        $setCalls = @(Get-ReconcileTestSetCalls -Stub $fixture.Stub)
        Test-BRAVOCondition -Condition ((@($suspend.Disabled).Count -eq 2) -and (@($suspend.Failed).Count -eq 0) -and ($setCalls.Count -eq 2)) -Name 'UpdateReconcile/Suspend.OnlyEnabled' -Failure 'вимикаються лише enabled=true зі знімка'
        Test-BRAVOCondition -Condition (@($setCalls | Where-Object { $_ -like '*|True' }).Count -eq 0) -Name 'UpdateReconcile/Suspend.NeverEnables' -Failure 'Suspend не має вмикати'
        Test-BRAVOCondition -Condition (@($setCalls | Where-Object { $_ -like 'SET|\BRAVO Тест\|*' }).Count -eq 2) -Name 'UpdateReconcile/Suspend.UsesSnapshotTaskPath' -Failure 'SetTaskEnabled отримує TaskPath зі знімка'

        # Часткова відмова: решта все одно вимикається.
        $fixture2 = New-ReconcileTestStub -Existing $names -Enabled $names
        $snapshot2 = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $fixture2.Adapter; RuntimeRoot = 'C:\fake runtime' }
        $fixture2.Stub.FailSet = @('BRAVO-Maintenance')
        $fixture2.Stub.ThrowSet = @('BRAVO-Health')
        $partialSuspend = Invoke-ReconcileTestCall -Name 'Suspend-BRAVOManagedTasks' -Params @{ Snapshot = $snapshot2; Adapter = $fixture2.Adapter }
        Test-BRAVOCondition -Condition ((@($partialSuspend.Failed).Count -eq 2) -and (@($partialSuspend.Disabled).Count -eq 2)) -Name 'UpdateReconcile/Suspend.PartialFailureContinues' -Failure 'Failed (false + виняток) не зупиняє решту'
        $invalidSuspend = Invoke-ReconcileTestCall -Name 'Suspend-BRAVOManagedTasks' -Params @{ Snapshot = [pscustomobject]@{ foo = 1 }; Adapter = $fixture2.Adapter }
        Test-BRAVOCondition -Condition (@($invalidSuspend.Failed).Count -ge 1) -Name 'UpdateReconcile/Suspend.InvalidSnapshotFails' -Failure 'непридатний знімок = Failed'

        # Restore: лише enabled=true, ідемпотентно.
        $fixture3 = New-ReconcileTestStub -Existing $names -Enabled @('BRAVO-Backup', 'BRAVO-Health')
        $snapshot3 = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $fixture3.Adapter; RuntimeRoot = 'C:\fake runtime' }
        $null = Invoke-ReconcileTestCall -Name 'Suspend-BRAVOManagedTasks' -Params @{ Snapshot = $snapshot3; Adapter = $fixture3.Adapter }
        $restore1 = Invoke-ReconcileTestCall -Name 'Restore-BRAVOManagedTaskState' -Params @{ Snapshot = $snapshot3; Adapter = $fixture3.Adapter }
        $stateAfter1 = (@($names | ForEach-Object { [string][bool]$fixture3.Stub.Tasks[$_].Enabled }) -join ',')
        $restore2 = Invoke-ReconcileTestCall -Name 'Restore-BRAVOManagedTaskState' -Params @{ Snapshot = $snapshot3; Adapter = $fixture3.Adapter }
        $stateAfter2 = (@($names | ForEach-Object { [string][bool]$fixture3.Stub.Tasks[$_].Enabled }) -join ',')
        Test-BRAVOCondition -Condition ($restore1.IsComplete -and (@($restore1.Restored).Count -eq 2) -and ($stateAfter1 -ceq 'True,False,True,False')) -Name 'UpdateReconcile/Restore.OnlyPreviouslyEnabled' -Failure 'вмикаються лише Backup і Health'
        Test-BRAVOCondition -Condition ($restore2.IsComplete -and ($stateAfter2 -ceq $stateAfter1)) -Name 'UpdateReconcile/Restore.Idempotent' -Failure 'повторний Restore дає той самий стан'

        $fixture4 = New-ReconcileTestStub -Existing $names -Enabled @('BRAVO-Backup', 'BRAVO-Health')
        $snapshot4 = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $fixture4.Adapter; RuntimeRoot = 'C:\fake runtime' }
        $fixture4.Stub.FailSet = @('BRAVO-Health')
        $restoreFail = Invoke-ReconcileTestCall -Name 'Restore-BRAVOManagedTaskState' -Params @{ Snapshot = $snapshot4; Adapter = $fixture4.Adapter }
        Test-BRAVOCondition -Condition ((-not $restoreFail.IsComplete) -and (@($restoreFail.Failed).Count -eq 1) -and (@($restoreFail.Restored).Count -eq 1)) -Name 'UpdateReconcile/Restore.IncompleteOnFailure' -Failure 'збій однієї задачі = IsComplete $false'
        $restoreInvalid = Invoke-ReconcileTestCall -Name 'Restore-BRAVOManagedTaskState' -Params @{ Snapshot = $null; Adapter = $fixture4.Adapter }
        Test-BRAVOCondition -Condition (-not $restoreInvalid.IsComplete) -Name 'UpdateReconcile/Restore.InvalidSnapshotNotComplete' -Failure 'порожній знімок не може дати IsComplete'

        # Disable-All: живе читання бачить і створені після знімка; fallback на знімок; без нічого — не кидає.
        $fixture5 = New-ReconcileTestStub -Existing $names -Enabled @('BRAVO-Backup')
        $snapshot5 = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $fixture5.Adapter; RuntimeRoot = 'C:\fake runtime' }
        $fixture5.Stub.Tasks['BRAVO-ServiceRecovery'] = @{ Enabled = $true; State = 'Ready' }
        $disableAll = Invoke-ReconcileTestCall -Name 'Disable-BRAVOAllManagedTasks' -Params @{ Adapter = $fixture5.Adapter; Snapshot = $snapshot5 }
        Test-BRAVOCondition -Condition ($disableAll.IsComplete -and (@($disableAll.Disabled).Count -eq 5) -and (-not [bool]$fixture5.Stub.Tasks['BRAVO-ServiceRecovery'].Enabled)) -Name 'UpdateReconcile/DisableAll.IncludesCreatedAfterSnapshot' -Failure 'Disable-All вимикає всі існуючі, зокрема створені після знімка'
        Test-BRAVOCondition -Condition (@(Get-ReconcileTestSetCalls -Stub $fixture5.Stub | Where-Object { $_ -like '*Other-Task*' }).Count -eq 0) -Name 'UpdateReconcile/DisableAll.IgnoresForeign' -Failure 'сторонні задачі не вимикаються'

        $fixture6 = New-ReconcileTestStub -Existing $names -Enabled $names
        $snapshot6 = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $fixture6.Adapter; RuntimeRoot = 'C:\fake runtime' }
        $fixture6.Stub.GetFail = $true
        $fallback = Invoke-ReconcileTestCall -Name 'Disable-BRAVOAllManagedTasks' -Params @{ Adapter = $fixture6.Adapter; Snapshot = $snapshot6 }
        Test-BRAVOCondition -Condition ($fallback.IsComplete -and (@($fallback.Disabled).Count -eq 4)) -Name 'UpdateReconcile/DisableAll.FallbackToSnapshot' -Failure 'за збою читання вимикаємо все зі знімка'
        $fixture7 = New-ReconcileTestStub -Existing $names -Enabled $names
        $fixture7.Stub.ConfigFail = $true
        $noScope = Invoke-ReconcileTestCall -Name 'Disable-BRAVOAllManagedTasks' -Params @{ Adapter = $fixture7.Adapter; RuntimeRoot = 'C:\fake runtime' }
        Test-BRAVOCondition -Condition ((-not $noScope.IsComplete) -and (@($noScope.Failed).Count -eq 1)) -Name 'UpdateReconcile/DisableAll.NoScopeReportsFailureNoThrow' -Failure 'без області: Failed і IsComplete=$false, без винятку'
        $fixture8 = New-ReconcileTestStub -Existing $names -Enabled $names
        $snapshot8 = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $fixture8.Adapter; RuntimeRoot = 'C:\fake runtime' }
        $fixture8.Stub.ThrowSet = @('BRAVO-Recovery')
        $partialAll = Invoke-ReconcileTestCall -Name 'Disable-BRAVOAllManagedTasks' -Params @{ Adapter = $fixture8.Adapter; Snapshot = $snapshot8 }
        Test-BRAVOCondition -Condition ((-not $partialAll.IsComplete) -and (@($partialAll.Disabled).Count -eq 3) -and (@($partialAll.Failed).Count -eq 1)) -Name 'UpdateReconcile/DisableAll.PartialFailureReported' -Failure 'збій однієї задачі лишається в Failed'
        $brokenAdapter = Invoke-ReconcileTestCall -Name 'Disable-BRAVOAllManagedTasks' -Params @{ Adapter = @{} }
        Test-BRAVOCondition -Condition (-not $brokenAdapter.IsComplete) -Name 'UpdateReconcile/DisableAll.BrokenAdapterNoThrow' -Failure 'адаптер без дій: не кидає, IsComplete=$false'
    }

    # ------------------------------------------------------------------
    # Invoke-BRAVOSchedulerReconcile (F1: негайне повторне вимкнення)
    # ------------------------------------------------------------------
    & {
        $names = @('BRAVO-Backup', 'BRAVO-Maintenance', 'BRAVO-Health')
        $runtime = 'C:\fake runtime'
        $stateRoot = Join-Path $reconcileTestRoot 'state реконсиляція'

        # Успіх: setup вмикає все (F1) і створює 2 нові задачі; після reconcile все вимкнено.
        $fixture = New-ReconcileTestStub -Existing $names -Enabled @('BRAVO-Backup')
        $fixture.Stub.SetupCreates = @('BRAVO-Recovery', 'BRAVO-BAZASync')
        $snapshot = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $fixture.Adapter; RuntimeRoot = $runtime }
        $journal = Invoke-ReconcileTestCall -Name 'New-BRAVOUpdateJournal' -Params @{ StateRoot = $stateRoot; Action = 'Update' }
        $context = [pscustomobject]@{ Adapter = $fixture.Adapter; Paths = [pscustomobject]@{ RuntimeRoot = $runtime; StateRoot = $stateRoot }; Journal = $journal }
        $result = Invoke-ReconcileTestCall -Name 'Invoke-BRAVOSchedulerReconcile' -Params @{ Context = $context; Snapshot = $snapshot }
        $anyEnabled = @($fixture.Stub.Tasks.Keys | Where-Object { [bool]$fixture.Stub.Tasks[$_].Enabled }).Count
        Test-BRAVOCondition -Condition (($result.Verdict -ceq 'PASS') -and ($result.ExitCode -eq 0) -and ($anyEnabled -eq 0)) -Name 'UpdateReconcile/Reconcile.AllRequiescedAfterSetup' -Failure 'після reconcile жодна керована задача не ввімкнена'
        Test-BRAVOCondition -Condition ((@($result.CreatedTasks).Count -eq 2) -and (@($result.CreatedTasks | Where-Object { $_.name -ceq 'BRAVO-Recovery' }).Count -eq 1)) -Name 'UpdateReconcile/Reconcile.CreatedTasksReported' -Failure 'створені задачі мають бути в CreatedTasks'
        Test-BRAVOCondition -Condition (@($result.CreatedTasks | Where-Object { $names -contains $_.name }).Count -eq 0) -Name 'UpdateReconcile/Reconcile.PreexistingNotCreated' -Failure 'попередньо існуючі задачі не є створеними'
        Test-BRAVOCondition -Condition (@($result.RequiescedTasks).Count -eq 5) -Name 'UpdateReconcile/Reconcile.RequiescedAll' -Failure 'мають бути вимкнені всі 5 (3 існуючі, які setup увімкнув, + 2 створені)'
        $log = @($fixture.Stub.Log)
        $setupIndex = [array]::IndexOf($log, 'SETUP')
        $firstSet = -1
        for ($i = 0; $i -lt $log.Count; $i++) { if ($log[$i] -like 'SET|*') { $firstSet = $i; break } }
        Test-BRAVOCondition -Condition (($setupIndex -ge 0) -and ($firstSet -gt $setupIndex) -and (@(Get-ReconcileTestSetCalls -Stub $fixture.Stub | Where-Object { $_ -like '*|True' }).Count -eq 0)) -Name 'UpdateReconcile/Reconcile.RequiesceAfterSetupNeverEnable' -Failure 'вимкнення йде одразу після SETUP; жодного вмикання'
        $journalRead = Invoke-ReconcileTestCall -Name 'Read-BRAVOUpdateJournal' -Params @{ Path = (Join-Path $stateRoot ('Journal\' + $journal.operationId + '.json')) }
        Test-BRAVOCondition -Condition ($journalRead.IsValid -and (@($journalRead.Journal.createdTasks).Count -eq 2)) -Name 'UpdateReconcile/Reconcile.CreatedTasksInJournal' -Failure 'createdTasks мають бути в журналі'

        # PASS_WITH_WARNING (код 10) — задачі все одно вимкнені.
        $warn = New-ReconcileTestStub -Existing $names -Enabled $names
        $warn.Stub.SetupExit = 10
        $warnSnapshot = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $warn.Adapter; RuntimeRoot = $runtime }
        $warnResult = Invoke-ReconcileTestCall -Name 'Invoke-BRAVOSchedulerReconcile' -Params @{ Context = ([pscustomobject]@{ Adapter = $warn.Adapter; Paths = [pscustomobject]@{ RuntimeRoot = $runtime; StateRoot = $stateRoot } }); Snapshot = $warnSnapshot }
        Test-BRAVOCondition -Condition (($warnResult.Verdict -ceq 'PASS_WITH_WARNING') -and (@($warn.Stub.Tasks.Keys | Where-Object { [bool]$warn.Stub.Tasks[$_].Enabled }).Count -eq 0)) -Name 'UpdateReconcile/Reconcile.ExitTenIsWarning' -Failure 'код 10 -> PASS_WITH_WARNING, задачі вимкнені'

        # FAIL (код 1): все одно повторне вимкнення.
        $failFixture = New-ReconcileTestStub -Existing $names -Enabled $names
        $failFixture.Stub.SetupExit = 1
        $failSnapshot = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $failFixture.Adapter; RuntimeRoot = $runtime }
        $failResult = Invoke-ReconcileTestCall -Name 'Invoke-BRAVOSchedulerReconcile' -Params @{ Context = ([pscustomobject]@{ Adapter = $failFixture.Adapter; Paths = [pscustomobject]@{ RuntimeRoot = $runtime; StateRoot = $stateRoot } }); Snapshot = $failSnapshot }
        Test-BRAVOCondition -Condition (($failResult.Verdict -ceq 'FAIL') -and ($failResult.ExitCode -eq 1) -and (@($failFixture.Stub.Tasks.Keys | Where-Object { [bool]$failFixture.Stub.Tasks[$_].Enabled }).Count -eq 0) -and (@($failResult.Problems).Count -ge 1)) -Name 'UpdateReconcile/Reconcile.FailedSetupStillRequiesces' -Failure 'невдалий setup все одно має закінчитись вимкненими задачами'

        # Виняток setup і таймаут.
        $throwFixture = New-ReconcileTestStub -Existing $names -Enabled $names
        $throwFixture.Stub.SetupThrow = $true
        $throwSnapshot = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $throwFixture.Adapter; RuntimeRoot = $runtime }
        $throwResult = Invoke-ReconcileTestCall -Name 'Invoke-BRAVOSchedulerReconcile' -Params @{ Context = ([pscustomobject]@{ Adapter = $throwFixture.Adapter; Paths = [pscustomobject]@{ RuntimeRoot = $runtime; StateRoot = $stateRoot } }); Snapshot = $throwSnapshot }
        Test-BRAVOCondition -Condition (($throwResult.Verdict -ceq 'FAIL') -and ($throwResult.ExitCode -eq -1)) -Name 'UpdateReconcile/Reconcile.SetupThrowIsFail' -Failure 'виняток setup -> FAIL без винятку назовні'
        $timeoutFixture = New-ReconcileTestStub -Existing $names -Enabled $names
        $timeoutFixture.Stub.SetupTimedOut = $true
        $timeoutSnapshot = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $timeoutFixture.Adapter; RuntimeRoot = $runtime }
        $timeoutResult = Invoke-ReconcileTestCall -Name 'Invoke-BRAVOSchedulerReconcile' -Params @{ Context = ([pscustomobject]@{ Adapter = $timeoutFixture.Adapter; Paths = [pscustomobject]@{ RuntimeRoot = $runtime; StateRoot = $stateRoot } }); Snapshot = $timeoutSnapshot }
        Test-BRAVOCondition -Condition (($timeoutResult.Verdict -ceq 'FAIL') -and (@($timeoutFixture.Stub.Tasks.Keys | Where-Object { [bool]$timeoutFixture.Stub.Tasks[$_].Enabled }).Count -eq 0)) -Name 'UpdateReconcile/Reconcile.TimeoutIsFail' -Failure 'таймаут setup -> FAIL, задачі вимкнені'

        # Не вдалося вимкнути одну задачу -> FAIL.
        $stuck = New-ReconcileTestStub -Existing $names -Enabled $names
        $stuckSnapshot = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $stuck.Adapter; RuntimeRoot = $runtime }
        $stuck.Stub.FailSet = @('BRAVO-Health')
        $stuckResult = Invoke-ReconcileTestCall -Name 'Invoke-BRAVOSchedulerReconcile' -Params @{ Context = ([pscustomobject]@{ Adapter = $stuck.Adapter; Paths = [pscustomobject]@{ RuntimeRoot = $runtime; StateRoot = $stateRoot } }); Snapshot = $stuckSnapshot }
        Test-BRAVOCondition -Condition (($stuckResult.Verdict -ceq 'FAIL') -and (@($stuckResult.Problems | Where-Object { $_ -like '*BRAVO-Health*' }).Count -ge 1)) -Name 'UpdateReconcile/Reconcile.CannotDisableIsFail' -Failure 'задача, яку не вдалось вимкнути, -> FAIL з іменем у Problems'

        # Adapter бреше про успіх, стан не змінюється: перевірка читанням має виявити.
        $liar = New-ReconcileTestStub -Existing $names -Enabled $names
        $liarSnapshot = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $liar.Adapter; RuntimeRoot = $runtime }
        $liar.Stub.LieSet = @('BRAVO-Maintenance')
        $liarResult = Invoke-ReconcileTestCall -Name 'Invoke-BRAVOSchedulerReconcile' -Params @{ Context = ([pscustomobject]@{ Adapter = $liar.Adapter; Paths = [pscustomobject]@{ RuntimeRoot = $runtime; StateRoot = $stateRoot } }); Snapshot = $liarSnapshot }
        Test-BRAVOCondition -Condition (($liarResult.Verdict -ceq 'FAIL') -and (@($liarResult.Problems | Where-Object { $_ -like '*увімкненою*' }).Count -ge 1)) -Name 'UpdateReconcile/Reconcile.VerifiesByReading' -Failure 'невдале вимкнення (adapter збрехав) має дати FAIL'

        # Читання задач після setup ламається: аварійне вимкнення за знімком.
        $blind = New-ReconcileTestStub -Existing $names -Enabled $names
        $blindSnapshot = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $blind.Adapter; RuntimeRoot = $runtime }
        $blind.Stub.GetFailAfterSetup = $true
        $blindResult = Invoke-ReconcileTestCall -Name 'Invoke-BRAVOSchedulerReconcile' -Params @{ Context = ([pscustomobject]@{ Adapter = $blind.Adapter; Paths = [pscustomobject]@{ RuntimeRoot = $runtime; StateRoot = $stateRoot } }); Snapshot = $blindSnapshot }
        Test-BRAVOCondition -Condition (($blindResult.Verdict -ceq 'FAIL') -and (@($blind.Stub.Tasks.Keys | Where-Object { [bool]$blind.Stub.Tasks[$_].Enabled }).Count -eq 0)) -Name 'UpdateReconcile/Reconcile.UnreadableStateEmergencyDisable' -Failure 'нечитабельний стан після setup: FAIL і аварійне вимкнення'

        # Непридатний знімок / adapter без дії — виняток ДО setup.
        $guard = New-ReconcileTestStub -Existing $names -Enabled $names
        $guardThrew = Test-ReconcileTestThrows -Name 'Invoke-BRAVOSchedulerReconcile' -Params @{ Context = ([pscustomobject]@{ Adapter = $guard.Adapter; Paths = [pscustomobject]@{ RuntimeRoot = $runtime; StateRoot = $stateRoot } }); Snapshot = [pscustomobject]@{ x = 1 } }
        Test-BRAVOCondition -Condition ($guardThrew -and (@($guard.Stub.Log | Where-Object { $_ -eq 'SETUP' }).Count -eq 0)) -Name 'UpdateReconcile/Reconcile.InvalidSnapshotBeforeSetup' -Failure 'непридатний знімок має кидати виняток до запуску setup'
        $partialAdapter = @{ InvokeSetupScheduler = { param($r) [pscustomobject]@{ ExitCode = 0; Output = ''; TimedOut = $false } } }
        $missingAction = Test-ReconcileTestThrows -Name 'Invoke-BRAVOSchedulerReconcile' -Params @{ Context = ([pscustomobject]@{ Adapter = $partialAdapter; Paths = [pscustomobject]@{ RuntimeRoot = $runtime; StateRoot = $stateRoot } }); Snapshot = $failSnapshot }
        Test-BRAVOCondition -Condition $missingAction -Name 'UpdateReconcile/Reconcile.MissingAdapterActionThrowsBeforeSetup' -Failure 'adapter без SetTaskEnabled/GetManagedTasks відхиляється до setup'
    }

    # ------------------------------------------------------------------
    # Set-BRAVOTaskActivation (D6)
    # ------------------------------------------------------------------
    & {
        $names = @('BRAVO-Backup', 'BRAVO-Maintenance', 'BRAVO-Health')
        $runtime = 'C:\fake runtime'
        $newActivationCase = {
            param([string[]]$EnabledBefore, [string[]]$EnabledNow)
            $case = New-ReconcileTestStub -Existing $names -Enabled $EnabledBefore
            $snap = Invoke-ReconcileTestCall -Name 'Get-BRAVOSchedulerSnapshot' -Params @{ Adapter = $case.Adapter; RuntimeRoot = $runtime }
            # Стан «після операції»: усе вимкнено (як після re-quiesce), якщо не задано інше.
            foreach ($n in $names) { $case.Stub.Tasks[$n].Enabled = ($EnabledNow -contains $n) }
            $case.Stub.Log.Clear()
            return [pscustomobject]@{ Case = $case; Snapshot = $snap }
        }
        $enabledState = { param($c) (@($names | ForEach-Object { [string][bool]$c.Stub.Tasks[$_].Enabled }) -join ',') }

        $a = & $newActivationCase @('BRAVO-Backup', 'BRAVO-Health') @()
        $r = Invoke-ReconcileTestCall -Name 'Set-BRAVOTaskActivation' -Params @{ Policy = 'ActivateOnSuccessOnly'; Snapshot = $a.Snapshot; Adapter = $a.Case.Adapter; OutcomeStatus = 'Success'; Action = 'Update' }
        Test-BRAVOCondition -Condition (($r.TaskActivation.state -ceq 'Active') -and ((& $enabledState $a.Case) -ceq 'True,False,True') -and (@($r.Findings).Count -eq 0)) -Name 'UpdateReconcile/Activation.UpdateSuccessRestores' -Failure 'Update+Success: відновити попередній стан (Active)'

        $b = & $newActivationCase @() @()
        $r = Invoke-ReconcileTestCall -Name 'Set-BRAVOTaskActivation' -Params @{ Policy = 'ActivateOnSuccessOnly'; Snapshot = $b.Snapshot; Adapter = $b.Case.Adapter; OutcomeStatus = 'Success'; Action = 'Repair' }
        Test-BRAVOCondition -Condition (($r.TaskActivation.state -ceq 'Unchanged') -and (@(Get-ReconcileTestSetCalls -Stub $b.Case.Stub).Count -eq 0)) -Name 'UpdateReconcile/Activation.NothingEnabledBeforeIsUnchanged' -Failure 'якщо до операції нічого не було увімкнено: Unchanged без змін'

        $c = & $newActivationCase @('BRAVO-Backup') @()
        $r = Invoke-ReconcileTestCall -Name 'Set-BRAVOTaskActivation' -Params @{ Policy = 'ActivateOnSuccessOnly'; Snapshot = $c.Snapshot; Adapter = $c.Case.Adapter; OutcomeStatus = 'SuccessWithWarnings'; Action = 'Update' }
        Test-BRAVOCondition -Condition (($r.TaskActivation.state -ceq 'Inactive') -and (@($r.Findings | Where-Object { $_.id -ceq 'Activation.HeldByWarnings' -and $_.severity -ceq 'Warning' }).Count -eq 1) -and ((& $enabledState $c.Case) -ceq 'False,False,False')) -Name 'UpdateReconcile/Activation.UpdateWarningsHeld' -Failure 'Update+SuccessWithWarnings: Inactive + finding'
        Test-BRAVOCondition -Condition (@(Get-ReconcileTestSetCalls -Stub $c.Case.Stub | Where-Object { $_ -like '*|True' }).Count -eq 0) -Name 'UpdateReconcile/Activation.UpdateWarningsNeverEnables' -Failure 'утримання не вмикає задачі'

        $d = & $newActivationCase @('BRAVO-Backup') @()
        $r = Invoke-ReconcileTestCall -Name 'Set-BRAVOTaskActivation' -Params @{ Policy = 'ActivateOnWarnings'; Snapshot = $d.Snapshot; Adapter = $d.Case.Adapter; OutcomeStatus = 'SuccessWithWarnings'; Action = 'Update' }
        Test-BRAVOCondition -Condition (($r.TaskActivation.state -ceq 'Active') -and ((& $enabledState $d.Case) -ceq 'True,False,False')) -Name 'UpdateReconcile/Activation.ActivateOnWarningsRestores' -Failure 'ActivateOnWarnings: попередній стан відновлюється й за warnings'

        # Install: завжди Inactive; задачі, що були ввімкнені (поза очікуваннями), вимикаються.
        $e = & $newActivationCase @() @('BRAVO-Health')
        $r = Invoke-ReconcileTestCall -Name 'Set-BRAVOTaskActivation' -Params @{ Policy = 'ActivateOnSuccessOnly'; Snapshot = $e.Snapshot; Adapter = $e.Case.Adapter; OutcomeStatus = 'Success'; Action = 'Install' }
        Test-BRAVOCondition -Condition (($r.TaskActivation.state -ceq 'Inactive') -and ((& $enabledState $e.Case) -ceq 'False,False,False') -and (@($r.Findings | Where-Object { $_.id -ceq 'Activation.InstallInactive' }).Count -eq 1)) -Name 'UpdateReconcile/Activation.InstallInactiveAndDisables' -Failure 'Install+Success: Inactive, залишкові увімкнені задачі вимкнено'
        $f = & $newActivationCase @() @()
        $r = Invoke-ReconcileTestCall -Name 'Set-BRAVOTaskActivation' -Params @{ Policy = ([pscustomobject]@{ action = 'Install'; activationPolicy = 'ActivateOnWarnings' }); Snapshot = $f.Snapshot; Adapter = $f.Case.Adapter; OutcomeStatus = 'SuccessWithWarnings' }
        Test-BRAVOCondition -Condition ($r.TaskActivation.state -ceq 'Inactive') -Name 'UpdateReconcile/Activation.InstallPolicyObjectIgnoresWarningsPolicy' -Failure 'Install ніколи не активується, навіть з ActivateOnWarnings (Policy як об''єкт)'

        # Failed / RolledBack.
        $g = & $newActivationCase @('BRAVO-Backup', 'BRAVO-Health') @()
        $r = Invoke-ReconcileTestCall -Name 'Set-BRAVOTaskActivation' -Params @{ Policy = 'ActivateOnSuccessOnly'; Snapshot = $g.Snapshot; Adapter = $g.Case.Adapter; OutcomeStatus = 'RolledBack'; Action = 'Update' }
        Test-BRAVOCondition -Condition (($r.TaskActivation.state -ceq 'Active') -and ((& $enabledState $g.Case) -ceq 'True,False,True')) -Name 'UpdateReconcile/Activation.RolledBackRestoresPrevious' -Failure 'Update+RolledBack: попередній стан'
        $h = & $newActivationCase @() @()
        $r = Invoke-ReconcileTestCall -Name 'Set-BRAVOTaskActivation' -Params @{ Policy = 'ActivateOnSuccessOnly'; Snapshot = $h.Snapshot; Adapter = $h.Case.Adapter; OutcomeStatus = 'Failed'; Action = 'Install' }
        Test-BRAVOCondition -Condition ($r.TaskActivation.state -ceq 'Inactive') -Name 'UpdateReconcile/Activation.InstallFailedInactive' -Failure 'Install+Failed: Inactive'

        # Critical: ніколи не вмикати, навіть якщо знімок мав увімкнені задачі.
        $i = & $newActivationCase @('BRAVO-Backup', 'BRAVO-Health') @('BRAVO-Backup')
        $r = Invoke-ReconcileTestCall -Name 'Set-BRAVOTaskActivation' -Params @{ Policy = 'ActivateOnWarnings'; Snapshot = $i.Snapshot; Adapter = $i.Case.Adapter; OutcomeStatus = 'Critical'; Action = 'Update' }
        Test-BRAVOCondition -Condition (($r.TaskActivation.state -ceq 'Inactive') -and (@(Get-ReconcileTestSetCalls -Stub $i.Case.Stub | Where-Object { $_ -like '*|True' }).Count -eq 0) -and ((& $enabledState $i.Case) -ceq 'False,False,False')) -Name 'UpdateReconcile/Activation.CriticalNeverEnables' -Failure 'Critical: жодного вмикання, задачі вимкнені'

        # Збої: restore неповний -> Unknown; не вдалось вимкнути -> Unknown; непридатний знімок -> Unknown.
        $j = & $newActivationCase @('BRAVO-Backup', 'BRAVO-Health') @()
        $j.Case.Stub.FailSet = @('BRAVO-Health')
        $r = Invoke-ReconcileTestCall -Name 'Set-BRAVOTaskActivation' -Params @{ Policy = 'ActivateOnSuccessOnly'; Snapshot = $j.Snapshot; Adapter = $j.Case.Adapter; OutcomeStatus = 'Success'; Action = 'Update' }
        Test-BRAVOCondition -Condition (($r.TaskActivation.state -ceq 'Unknown') -and (@($r.Findings | Where-Object { $_.id -ceq 'Activation.RestoreIncomplete' }).Count -eq 1) -and (-not $r.Restore.IsComplete)) -Name 'UpdateReconcile/Activation.RestoreIncompleteIsUnknown' -Failure 'неповне відновлення -> Unknown + finding'
        $k = & $newActivationCase @() @('BRAVO-Health')
        $k.Case.Stub.FailSet = @('BRAVO-Health')
        $r = Invoke-ReconcileTestCall -Name 'Set-BRAVOTaskActivation' -Params @{ Policy = 'ActivateOnSuccessOnly'; Snapshot = $k.Snapshot; Adapter = $k.Case.Adapter; OutcomeStatus = 'Critical'; Action = 'Update' }
        Test-BRAVOCondition -Condition (($r.TaskActivation.state -ceq 'Unknown') -and (@($r.Findings | Where-Object { $_.id -ceq 'Activation.NotDisabled' }).Count -eq 1)) -Name 'UpdateReconcile/Activation.NotDisabledIsUnknown' -Failure 'якщо не вдалось вимкнути: Unknown, а не вигаданий Inactive'
        $l = & $newActivationCase @() @()
        $r = Invoke-ReconcileTestCall -Name 'Set-BRAVOTaskActivation' -Params @{ Policy = 'ActivateOnSuccessOnly'; Snapshot = $null; Adapter = $l.Case.Adapter; OutcomeStatus = 'Success'; Action = 'Update' }
        Test-BRAVOCondition -Condition (($r.TaskActivation.state -ceq 'Unknown') -and (@(Get-ReconcileTestSetCalls -Stub $l.Case.Stub).Count -eq 0)) -Name 'UpdateReconcile/Activation.InvalidSnapshotIsUnknown' -Failure 'порожній знімок -> Unknown без змін'
        $m = & $newActivationCase @() @()
        $m.Case.Stub.GetFail = $true
        $r = Invoke-ReconcileTestCall -Name 'Set-BRAVOTaskActivation' -Params @{ Policy = 'ActivateOnSuccessOnly'; Snapshot = $m.Snapshot; Adapter = $m.Case.Adapter; OutcomeStatus = 'SuccessWithWarnings'; Action = 'Update' }
        Test-BRAVOCondition -Condition ($r.TaskActivation.state -ceq 'Unknown') -Name 'UpdateReconcile/Activation.UnreadableIsUnknown' -Failure 'нечитабельний scheduler -> Unknown'
        $contractCheck = Invoke-ReconcileTestCall -Name 'New-BRAVOUpdateDeploymentResult' -Params @{ OperationId = [guid]::NewGuid().ToString(); Action = 'Update'; Status = 'Success'; TaskActivation = $a.Case.Stub.Names.Count }
        # (не використовується) — результат Set-BRAVOTaskActivation вкладається в DeploymentResult.taskActivation
        $resultWithActivation = Invoke-ReconcileTestCall -Name 'New-BRAVOUpdateDeploymentResult' -Params @{ OperationId = [guid]::NewGuid().ToString(); Action = 'Update'; Status = 'Success'; TaskActivation = $r.TaskActivation }
        Test-BRAVOCondition -Condition ($resultWithActivation.taskActivation.state -ceq 'Unknown') -Name 'UpdateReconcile/Activation.FitsDeploymentResult' -Failure 'TaskActivation має вкладатись у DeploymentResult'
    }

    # ------------------------------------------------------------------
    # Default adapter: обмеження області (гілки до звернення до COM)
    # ------------------------------------------------------------------
    & {
        $defaultAdapter = & $reconcileTestModule { New-BRAVOUpdateDefaultAdapter -ToolkitRoot 'C:\fake toolkit' }
        $fixture = New-ReconcileTestStub
        # Підміна лише GetEffectiveConfiguration: решта (COM) не виконується, бо виняток раніше.
        $defaultAdapter['GetEffectiveConfiguration'] = $fixture.Adapter.GetEffectiveConfiguration
        $setOutside = $false
        try { [void](& $defaultAdapter['SetTaskEnabled'] '\Microsoft\Windows\' 'BRAVO-Backup' $false) } catch { $setOutside = $true }
        Test-BRAVOCondition -Condition $setOutside -Name 'UpdateReconcile/DefaultAdapter.SetOutsideTaskPathThrows' -Failure 'SetTaskEnabled поза TaskPath конфігурації має кидати виняток'
        $setForeign = $false
        try { [void](& $defaultAdapter['SetTaskEnabled'] '\BRAVO Тест\' 'Чужа задача' $false) } catch { $setForeign = $true }
        Test-BRAVOCondition -Condition $setForeign -Name 'UpdateReconcile/DefaultAdapter.SetForeignNameThrows' -Failure 'SetTaskEnabled для некерованого імені має кидати виняток'
        $setTraversal = $false
        try { [void](& $defaultAdapter['SetTaskEnabled'] '\BRAVO Тест\..\' 'BRAVO-Backup' $false) } catch { $setTraversal = $true }
        Test-BRAVOCondition -Condition $setTraversal -Name 'UpdateReconcile/DefaultAdapter.SetTraversalThrows' -Failure '.. у TaskPath має кидати виняток'
        $getOutside = $false
        try { [void](& $defaultAdapter['GetManagedTasks'] '\Microsoft\' 'C:\fake toolkit') } catch { $getOutside = $true }
        Test-BRAVOCondition -Condition $getOutside -Name 'UpdateReconcile/DefaultAdapter.GetOutsideTaskPathThrows' -Failure 'GetManagedTasks для чужого TaskPath має кидати виняток'
        $fixture.Stub.ConfigFail = $true
        $setNoConfig = $false
        try { [void](& $defaultAdapter['SetTaskEnabled'] '\BRAVO Тест\' 'BRAVO-Backup' $false) } catch { $setNoConfig = $true }
        Test-BRAVOCondition -Condition $setNoConfig -Name 'UpdateReconcile/DefaultAdapter.NoConfigThrows' -Failure 'без ефективної конфігурації SetTaskEnabled має кидати виняток (fail closed)'
    }
} finally {
    if ($reconcileTestRoot.StartsWith($reconcileTestPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $reconcileTestRoot)) {
        Remove-Item -LiteralPath $reconcileTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
