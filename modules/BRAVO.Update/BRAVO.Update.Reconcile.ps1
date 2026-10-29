# BRAVO.Update.Reconcile — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Узгодження конфігурації та планувальника завдань (ENGINE_DESIGN.md, розділ 5):
# baseline site-конфігурації, знімок/призупинення/відновлення керованих задач,
# реконсиляція scheduler з негайним повторним вимкненням (факт F1) і політика
# активації задач (D6). Усі зовнішні side effects (Task Scheduler, BRAVO_SETUP)
# — лише через adapter; цей файл не звертається до Task Scheduler напряму.

# Файли, якими володіє сайт: engine ніколи їх не змінює, лише звіряє хеші.
function Get-BRAVOUpdateSiteConfigurationFileName {
    [CmdletBinding()]
    param()
    return @('BRAVO.local.config', 'BRAVO.config', 'TOOLS_INTEGRITY.json', 'WinSCP.ini')
}

# ----------------------------------------------------------------------
# Baseline site-конфігурації
# ----------------------------------------------------------------------

function Get-BRAVOSiteConfigurationBaseline {
    <#
    .SYNOPSIS
        SHA-256 (UPPER) або 'absent' для файлів site-конфігурації в RuntimeRoot.
    .DESCRIPTION
        Нечитабельний файл (заблокований, каталог замість файлу) — виняток:
        baseline, у якому «невідомо», не може довести збереження конфігурації,
        тому mutation без нього не починається (fail closed).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)

    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { throw 'BRAVO.Update: RuntimeRoot порожній.' }
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($name in (Get-BRAVOUpdateSiteConfigurationFileName)) {
        $path = Join-Path $RuntimeRoot $name
        $hash = 'absent'
        if ([IO.Directory]::Exists($path)) {
            throw "BRAVO.Update: '$name' є каталогом, а не файлом конфігурації."
        }
        if ([IO.File]::Exists($path)) {
            try {
                $hash = Get-BRAVODeployFileSha256 -Path $path
            } catch {
                throw "BRAVO.Update: не вдалося прочитати '$name' для baseline: $($_.Exception.Message)"
            }
        }
        $files.Add([pscustomobject][ordered]@{ name = $name; sha256 = $hash })
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        capturedUtc   = (Get-BRAVOUpdateUtcNowText)
        runtimeRoot   = $RuntimeRoot
        files         = @($files.ToArray())
    }
}

function Test-BRAVOSiteConfigurationPreserved {
    <#
    .SYNOPSIS
        Порівнює поточні хеші site-конфігурації з baseline; повертає validation
        entry { name = 'SiteConfigPreserved', status Pass|Fail, message }.
    .DESCRIPTION
        Не кидає: будь-яка неоднозначність (порожній baseline, нечитабельний
        файл) — Fail. У message лише імена файлів, без вмісту.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [AllowNull()]$Baseline
    )

    $fail = {
        param([string]$Message)
        return [pscustomobject][ordered]@{ name = 'SiteConfigPreserved'; status = 'Fail'; message = $Message }
    }
    $baselineFiles = @(Get-BRAVOUpdatePropertyValue -InputObject $Baseline -Name 'files' -Default @())
    if ($null -eq $Baseline -or $baselineFiles.Count -eq 0) {
        return (& $fail 'Baseline site-конфігурації відсутній або порожній: збереження не доведено.')
    }
    $changed = New-Object System.Collections.Generic.List[string]
    $expectedNames = @{}
    foreach ($entry in $baselineFiles) {
        $name = [string](Get-BRAVOUpdatePropertyValue -InputObject $entry -Name 'name' -Default '')
        $expected = [string](Get-BRAVOUpdatePropertyValue -InputObject $entry -Name 'sha256' -Default '')
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($expected)) {
            return (& $fail 'Baseline site-конфігурації пошкоджений (порожнє ім''я або хеш).')
        }
        $expectedNames[$name.ToUpperInvariant()] = $true
        $path = Join-Path $RuntimeRoot $name
        $actual = 'absent'
        try {
            if ([IO.Directory]::Exists($path)) {
                $actual = 'unreadable'
            } elseif ([IO.File]::Exists($path)) {
                $actual = Get-BRAVODeployFileSha256 -Path $path
            }
        } catch {
            $actual = 'unreadable'
        }
        if (-not [string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)) { $changed.Add($name) }
    }
    # Baseline мусить покривати всі файли сайту: усічений список = помилка фіксації.
    foreach ($required in (Get-BRAVOUpdateSiteConfigurationFileName)) {
        if (-not $expectedNames.ContainsKey($required.ToUpperInvariant())) { $changed.Add($required + ' (немає в baseline)') }
    }
    if ($changed.Count -gt 0) {
        return (& $fail ('Site-конфігурація змінилась: ' + ($changed.ToArray() -join ', ')))
    }
    return [pscustomobject][ordered]@{ name = 'SiteConfigPreserved'; status = 'Pass'; message = 'Файли site-конфігурації збережено без змін.' }
}

# ----------------------------------------------------------------------
# Допоміжні функції scheduler
# ----------------------------------------------------------------------

function Get-BRAVOReconcileAdapterAction {
    # Повертає scriptblock adapter-а за ключем; відсутній ключ — виняток до будь-якої дії.
    [CmdletBinding()]
    param([AllowNull()]$Adapter, [Parameter(Mandatory = $true)][string]$Name)

    if (($null -eq $Adapter) -or ($Adapter -isnot [System.Collections.IDictionary]) -or (-not $Adapter.Contains($Name)) -or ($null -eq $Adapter[$Name])) {
        throw "BRAVO.Update: adapter не має дії '$Name'."
    }
    return $Adapter[$Name]
}

function ConvertTo-BRAVOUpdateTaskPath {
    <#
    .SYNOPSIS
        Нормалізує TaskPath до '\Segment\...\' ('\' для кореня). Сегменти '.'/'..' — виняток.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$TaskPath)

    if ([string]::IsNullOrWhiteSpace($TaskPath)) { throw 'BRAVO.Update: TaskPath порожній.' }
    $inner = $TaskPath.Trim().Trim([char[]]@('\', '/'))
    if ($inner -eq '') { return '\' }
    foreach ($segment in $inner.Split([char[]]@('\', '/'))) {
        if (($segment -eq '') -or ($segment -eq '.') -or ($segment -eq '..')) {
            throw "BRAVO.Update: TaskPath '$TaskPath' містить некоректний сегмент."
        }
    }
    return ('\' + ($inner -replace '/', '\') + '\')
}

function Get-BRAVOUpdateManagedTaskScope {
    <#
    .SYNOPSIS
        { TaskPath, Names[] } керованих задач з ефективної конфігурації
        (schedulerSettings.TaskPath + TaskName вузлів Backup, Maintenance, Health,
        Recovery, BAZASync, RestoreVerify, BackupCatchUp, ServiceRecovery).
    .DESCRIPTION
        Імена не hardcode-яться: їх визначає канонічний loader. Це ж джерело
        обмежує default-adapter (COM) лише керованими задачами.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Configuration)

    $scheduler = Get-BRAVOUpdatePropertyValue -InputObject $Configuration -Name 'schedulerSettings'
    if ($null -eq $scheduler) { throw 'BRAVO.Update: в ефективній конфігурації немає schedulerSettings.' }
    $taskPath = ConvertTo-BRAVOUpdateTaskPath -TaskPath ([string](Get-BRAVOUpdatePropertyValue -InputObject $scheduler -Name 'TaskPath' -Default ''))
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('Backup', 'Maintenance', 'Health', 'Recovery', 'BAZASync', 'RestoreVerify', 'BackupCatchUp', 'ServiceRecovery')) {
        $node = Get-BRAVOUpdatePropertyValue -InputObject $scheduler -Name $key
        if ($null -eq $node) { continue }
        $name = [string](Get-BRAVOUpdatePropertyValue -InputObject $node -Name 'TaskName' -Default '')
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($name -match '[\\/]') { throw "BRAVO.Update: некоректне ім'я керованої задачі '$name'." }
        $exists = $false
        foreach ($known in $names) { if ([string]::Equals($known, $name, [StringComparison]::OrdinalIgnoreCase)) { $exists = $true } }
        if (-not $exists) { $names.Add($name) }
    }
    if ($names.Count -eq 0) { throw 'BRAVO.Update: в ефективній конфігурації немає імен керованих задач.' }
    return [pscustomobject]@{ TaskPath = $taskPath; Names = @($names.ToArray()) }
}

function Resolve-BRAVOReconcileScope {
    # Явні TaskPath+імена мають пріоритет (відкат після відновлення runtime);
    # інакше — з ефективної конфігурації через adapter. Збій = виняток (fail closed).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Adapter,
        [string]$RuntimeRoot = '',
        [string]$TaskPath = '',
        [string[]]$ManagedTaskName = @()
    )

    if ((-not [string]::IsNullOrWhiteSpace($TaskPath)) -and (@($ManagedTaskName).Count -gt 0)) {
        return [pscustomobject]@{ TaskPath = (ConvertTo-BRAVOUpdateTaskPath -TaskPath $TaskPath); Names = @($ManagedTaskName) }
    }
    $getConfiguration = Get-BRAVOReconcileAdapterAction -Adapter $Adapter -Name 'GetEffectiveConfiguration'
    $effective = & $getConfiguration $RuntimeRoot
    if (($null -eq $effective) -or (-not [bool](Get-BRAVOUpdatePropertyValue -InputObject $effective -Name 'Success' -Default $false))) {
        $message = [string](Get-BRAVOUpdatePropertyValue -InputObject $effective -Name 'Message' -Default '')
        throw "BRAVO.Update: ефективну конфігурацію scheduler не прочитано. $message"
    }
    return (Get-BRAVOUpdateManagedTaskScope -Configuration (Get-BRAVOUpdatePropertyValue -InputObject $effective -Name 'Configuration'))
}

function Get-BRAVOReconcileScopeFromSnapshot {
    # Область (TaskPath + імена) із вже зафіксованого знімка; $null, якщо знімок непридатний.
    [CmdletBinding()]
    param([AllowNull()]$Snapshot)

    $taskPath = [string](Get-BRAVOUpdatePropertyValue -InputObject $Snapshot -Name 'taskPath' -Default '')
    $tasks = @(Get-BRAVOUpdatePropertyValue -InputObject $Snapshot -Name 'tasks' -Default @())
    if ([string]::IsNullOrWhiteSpace($taskPath) -or $tasks.Count -eq 0) { return $null }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($task in $tasks) {
        $name = [string](Get-BRAVOUpdatePropertyValue -InputObject $task -Name 'name' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($name)) { $names.Add($name) }
    }
    if ($names.Count -eq 0) { return $null }
    try {
        return [pscustomobject]@{ TaskPath = (ConvertTo-BRAVOUpdateTaskPath -TaskPath $taskPath); Names = @($names.ToArray()) }
    } catch {
        return $null
    }
}

function Test-BRAVOSchedulerSnapshotShape {
    # Структурна перевірка знімка; повертає масив проблем (порожній = придатний).
    [CmdletBinding()]
    param([AllowNull()]$Snapshot)

    $problems = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Snapshot) { $problems.Add('Знімок scheduler порожній.'); return @($problems.ToArray()) }
    if (-not (Test-BRAVOUpdateHasProperty -InputObject $Snapshot -Name 'taskPath') -or [string]::IsNullOrWhiteSpace([string](Get-BRAVOUpdatePropertyValue -InputObject $Snapshot -Name 'taskPath' -Default ''))) {
        $problems.Add('У знімку немає taskPath.')
    }
    if (-not (Test-BRAVOUpdateHasProperty -InputObject $Snapshot -Name 'tasks')) {
        $problems.Add('У знімку немає tasks.')
    } else {
        $index = 0
        foreach ($task in @(Get-BRAVOUpdatePropertyValue -InputObject $Snapshot -Name 'tasks' -Default @())) {
            if ([string]::IsNullOrWhiteSpace([string](Get-BRAVOUpdatePropertyValue -InputObject $task -Name 'name' -Default ''))) { $problems.Add("tasks[$index]: порожнє ім'я.") }
            foreach ($flag in @('exists', 'enabled')) {
                if ((Get-BRAVOUpdatePropertyValue -InputObject $task -Name $flag -Default $null) -isnot [bool]) { $problems.Add("tasks[$index]: поле '$flag' має бути bool.") }
            }
            $index++
        }
    }
    return @($problems.ToArray())
}

function Get-BRAVOSchedulerSnapshot {
    <#
    .SYNOPSIS
        Знімок керованих задач: { schemaVersion, capturedUtc, taskPath, tasks[]{path, name, exists, enabled, state, isRunning} }.
    .DESCRIPTION
        Імена й TaskPath беруться з ефективної конфігурації через adapter (не hardcode),
        якщо їх не передано явно. Результат GetManagedTasks фільтрується до керованих
        імен у цьому TaskPath. Задача, якої adapter не повернув, фіксується як
        exists=$false (відсутність — теж стан). Збій adapter-а не ковтається:
        «невідомо» не можна плутати з «задач немає».
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Adapter,
        [string]$RuntimeRoot = '',
        [string]$TaskPath = '',
        [string[]]$ManagedTaskName = @()
    )

    $scope = Resolve-BRAVOReconcileScope -Adapter $Adapter -RuntimeRoot $RuntimeRoot -TaskPath $TaskPath -ManagedTaskName $ManagedTaskName
    $getTasks = Get-BRAVOReconcileAdapterAction -Adapter $Adapter -Name 'GetManagedTasks'
    $rows = @(& $getTasks $scope.TaskPath $RuntimeRoot | Where-Object { $null -ne $_ })

    $tasks = New-Object System.Collections.Generic.List[object]
    foreach ($name in $scope.Names) {
        $found = $false
        $enabled = $false
        $state = 'Missing'
        foreach ($row in $rows) {
            $rowName = [string](Get-BRAVOUpdatePropertyValue -InputObject $row -Name 'Name' -Default '')
            if (-not [string]::Equals($rowName, $name, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $rowPath = [string](Get-BRAVOUpdatePropertyValue -InputObject $row -Name 'Path' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($rowPath)) {
                $normalizedRowPath = $null
                try { $normalizedRowPath = ConvertTo-BRAVOUpdateTaskPath -TaskPath $rowPath } catch { $normalizedRowPath = $null }
                # Задача з іншого каталогу не є керованою, навіть якщо ім'я збігається.
                if (($null -eq $normalizedRowPath) -or (-not [string]::Equals($normalizedRowPath, $scope.TaskPath, [StringComparison]::OrdinalIgnoreCase))) { continue }
            }
            if (-not [bool](Get-BRAVOUpdatePropertyValue -InputObject $row -Name 'Exists' -Default $true)) { continue }
            # Дублікати: достатньо одного увімкненого рядка, щоб вважати задачу увімкненою.
            if ((-not $found) -or (-not $enabled)) {
                $state = [string](Get-BRAVOUpdatePropertyValue -InputObject $row -Name 'State' -Default 'Unknown')
            }
            $found = $true
            if ([bool](Get-BRAVOUpdatePropertyValue -InputObject $row -Name 'Enabled' -Default $false)) { $enabled = $true }
        }
        $tasks.Add([pscustomobject][ordered]@{
            path      = $scope.TaskPath
            name      = [string]$name
            exists    = $found
            enabled   = ($found -and $enabled)
            state     = $state
            isRunning = ($found -and (@('Running', 'Queued') -contains $state))
        })
    }
    $adapterTable = $null
    if ($Adapter -is [hashtable]) { $adapterTable = $Adapter }
    $capturedUtc = (Get-BRAVOUpdatePlanNow -Adapter $adapterTable).ToString('o')
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        capturedUtc   = $capturedUtc
        taskPath      = $scope.TaskPath
        # Цільовий runtime, за конфігурацією якого визначено область: решта функцій
        # передає його adapter-у, щоб межі керованих задач не залежали від ToolkitRoot.
        runtimeRoot   = $RuntimeRoot
        tasks         = @($tasks.ToArray())
    }
}

function Save-BRAVOSchedulerSnapshot {
    <#
    .SYNOPSIS
        Атомарно пише <OperationDirectory>\scheduler-snapshot.json -> { Path, Sha256 };
        з -Journal і -StateRoot також фіксує шлях у журналі.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Snapshot,
        [Parameter(Mandatory = $true)][string]$OperationDirectory,
        $Journal = $null,
        [string]$StateRoot = ''
    )

    $problems = @(Test-BRAVOSchedulerSnapshotShape -Snapshot $Snapshot)
    if ($problems.Count -gt 0) { throw ('BRAVO.Update: знімок scheduler не придатний до запису: ' + ($problems -join '; ')) }
    if (($null -ne $Journal) -and [string]::IsNullOrWhiteSpace($StateRoot)) { throw 'BRAVO.Update: для запису в журнал потрібен StateRoot.' }
    $path = Join-Path $OperationDirectory 'scheduler-snapshot.json'
    $text = ConvertTo-BRAVOUpdateJson -InputObject $Snapshot
    Write-BRAVOUpdateFileAtomic -Path $path -Text $text
    if ($null -ne $Journal) {
        [void](Set-BRAVOUpdateJournalSchedulerSnapshot -Journal $Journal -Path $path -StateRoot $StateRoot)
    }
    return [pscustomobject]@{ Path = $path; Sha256 = (Get-BRAVOUpdateSha256Text -Text $text) }
}

function Read-BRAVOSchedulerSnapshot {
    <#
    .SYNOPSIS
        Читає знімок з диска fail closed: { IsValid, Problems[], Snapshot, Path }. Не кидає.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $snapshot = $null
    $problems = New-Object System.Collections.Generic.List[string]
    try {
        if (-not [IO.File]::Exists($Path)) { throw 'файл знімка відсутній' }
        $text = [IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'файл знімка порожній' }
        $snapshot = $text | ConvertFrom-Json
        if (Test-BRAVOUpdateHasProperty -InputObject $snapshot -Name 'capturedUtc') {
            $snapshot.capturedUtc = ConvertTo-BRAVOUpdateUtcText -Value $snapshot.capturedUtc
        }
        foreach ($problem in @(Test-BRAVOSchedulerSnapshotShape -Snapshot $snapshot)) { $problems.Add($problem) }
    } catch {
        $snapshot = $null
        $problems.Add("Знімок scheduler нечитабельний: $($_.Exception.Message)")
    }
    return [pscustomobject]@{ IsValid = ($problems.Count -eq 0); Problems = @($problems.ToArray()); Snapshot = $snapshot; Path = $Path }
}

function Add-BRAVOUpdateJournalCreatedTask {
    <#
    .SYNOPSIS
        Додає задачі, створені операцією, у journal.createdTasks ({path,name}); персистить.
    .DESCRIPTION
        Поле не входить у CONTRACTS §8 (валідатор його не вимагає й не відхиляє):
        вводиться пакетом E3 для відкату (R4: створені задачі лишаються вимкненими).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Task,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )

    $existing = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'createdTasks' -Default @())) { $existing.Add($item) }
    $changed = $false
    foreach ($new in $Task) {
        $newPath = [string](Get-BRAVOUpdatePropertyValue -InputObject $new -Name 'path' -Default '')
        $newName = [string](Get-BRAVOUpdatePropertyValue -InputObject $new -Name 'name' -Default '')
        $duplicate = $false
        foreach ($item in $existing) {
            if ([string]::Equals([string](Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'path' -Default ''), $newPath, [StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string](Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'name' -Default ''), $newName, [StringComparison]::OrdinalIgnoreCase)) { $duplicate = $true }
        }
        if (-not $duplicate) {
            $existing.Add([pscustomobject][ordered]@{ path = $newPath; name = $newName })
            $changed = $true
        }
    }
    if ($changed) {
        if (Test-BRAVOUpdateHasProperty -InputObject $Journal -Name 'createdTasks') {
            $Journal.createdTasks = @($existing.ToArray())
        } else {
            Add-Member -InputObject $Journal -MemberType NoteProperty -Name 'createdTasks' -Value @($existing.ToArray())
        }
        [void](Write-BRAVOUpdateJournal -Journal $Journal -StateRoot $StateRoot)
    }
    return $Journal
}

function Set-BRAVOReconcileTaskEnabled {
    # Один виклик adapter.SetTaskEnabled з перетворенням винятку/Success=$false в єдиний результат.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Adapter,
        [Parameter(Mandatory = $true)][string]$TaskPath,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [string]$RuntimeRoot = ''
    )

    try {
        $setEnabled = Get-BRAVOReconcileAdapterAction -Adapter $Adapter -Name 'SetTaskEnabled'
        $result = & $setEnabled $TaskPath $Name $Enabled $RuntimeRoot
        if (($null -ne $result) -and [bool](Get-BRAVOUpdatePropertyValue -InputObject $result -Name 'Success' -Default $false)) {
            return [pscustomobject]@{ Success = $true; Message = '' }
        }
        $message = [string](Get-BRAVOUpdatePropertyValue -InputObject $result -Name 'Message' -Default 'adapter не підтвердив зміну')
        return [pscustomobject]@{ Success = $false; Message = $message }
    } catch {
        return [pscustomobject]@{ Success = $false; Message = [string]$_.Exception.Message }
    }
}

# ----------------------------------------------------------------------
# Призупинення, відновлення, аварійне вимкнення
# ----------------------------------------------------------------------
function Resolve-BRAVOReconcileRuntimeRoot {
    # Цільовий runtime для adapter-а: явний параметр, інакше runtimeRoot знімка, інакше ''.
    # Саме він визначає область керованих задач (TaskPath/імена) у default-adapter, тому
    # його не можна губити між знімком і SetTaskEnabled/GetManagedTasks.
    [CmdletBinding()]
    param([string]$RuntimeRoot = '', [AllowNull()]$Snapshot = $null)

    if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) { return $RuntimeRoot }
    return [string](Get-BRAVOUpdatePropertyValue -InputObject $Snapshot -Name 'runtimeRoot' -Default '')
}


function Suspend-BRAVOManagedTasks {
    <#
    .SYNOPSIS
        Вимикає керовані задачі, що в знімку exists+enabled -> { Disabled[], Failed[] }.
    .DESCRIPTION
        Не зупиняється на першій помилці: треба вимкнути якомога більше задач.
        Будь-який Failed = збій фази для викликача.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$Snapshot, [Parameter(Mandatory = $true)]$Adapter, [string]$RuntimeRoot = '')

    $disabled = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]
    $shape = @(Test-BRAVOSchedulerSnapshotShape -Snapshot $Snapshot)
    if ($shape.Count -gt 0) {
        $failed.Add([pscustomobject][ordered]@{ path = ''; name = ''; message = ($shape -join '; ') })
        return [pscustomobject]@{ Disabled = @(); Failed = @($failed.ToArray()) }
    }
    $taskPath = [string](Get-BRAVOUpdatePropertyValue -InputObject $Snapshot -Name 'taskPath')
    $effectiveRoot = Resolve-BRAVOReconcileRuntimeRoot -RuntimeRoot $RuntimeRoot -Snapshot $Snapshot
    foreach ($task in @(Get-BRAVOUpdatePropertyValue -InputObject $Snapshot -Name 'tasks' -Default @())) {
        if (-not ([bool]$task.exists -and [bool]$task.enabled)) { continue }
        $name = [string]$task.name
        $set = Set-BRAVOReconcileTaskEnabled -Adapter $Adapter -TaskPath $taskPath -Name $name -Enabled $false -RuntimeRoot $effectiveRoot
        if ($set.Success) {
            $disabled.Add([pscustomobject][ordered]@{ path = $taskPath; name = $name })
        } else {
            $failed.Add([pscustomobject][ordered]@{ path = $taskPath; name = $name; message = $set.Message })
        }
    }
    return [pscustomobject]@{ Disabled = @($disabled.ToArray()); Failed = @($failed.ToArray()) }
}

function Restore-BRAVOManagedTaskState {
    <#
    .SYNOPSIS
        Вмикає лише задачі, що в знімку мали enabled=$true -> { Restored[], Failed[], IsComplete }.
    .DESCRIPTION
        Ідемпотентна: повторний виклик знову встановлює той самий стан; задачі зі
        знімка з enabled=$false ніколи не вмикаються. Непридатний знімок = Failed
        (fail closed), а не «нічого відновлювати».
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$Snapshot, [Parameter(Mandatory = $true)]$Adapter, [string]$RuntimeRoot = '')

    $restored = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]
    $shape = @(Test-BRAVOSchedulerSnapshotShape -Snapshot $Snapshot)
    if ($shape.Count -gt 0) {
        $failed.Add([pscustomobject][ordered]@{ path = ''; name = ''; message = ($shape -join '; ') })
    } else {
        $taskPath = [string](Get-BRAVOUpdatePropertyValue -InputObject $Snapshot -Name 'taskPath')
        $effectiveRoot = Resolve-BRAVOReconcileRuntimeRoot -RuntimeRoot $RuntimeRoot -Snapshot $Snapshot
        foreach ($task in @(Get-BRAVOUpdatePropertyValue -InputObject $Snapshot -Name 'tasks' -Default @())) {
            if (-not ([bool]$task.exists -and [bool]$task.enabled)) { continue }
            $name = [string]$task.name
            $set = Set-BRAVOReconcileTaskEnabled -Adapter $Adapter -TaskPath $taskPath -Name $name -Enabled $true -RuntimeRoot $effectiveRoot
            if ($set.Success) {
                $restored.Add([pscustomobject][ordered]@{ path = $taskPath; name = $name })
            } else {
                $failed.Add([pscustomobject][ordered]@{ path = $taskPath; name = $name; message = $set.Message })
            }
        }
    }
    return [pscustomobject]@{ Restored = @($restored.ToArray()); Failed = @($failed.ToArray()); IsComplete = ($failed.Count -eq 0) }
}

function Disable-BRAVOAllManagedTasks {
    <#
    .SYNOPSIS
        Шлях Critical: best-effort вимкнення всіх керованих задач -> { Disabled[], Failed[], IsComplete }. Не кидає.
    .DESCRIPTION
        Область беремо зі знімка (якщо є), інакше з ефективної конфігурації RuntimeRoot.
        Якщо живе читання вдалось — вимикаємо всі існуючі керовані задачі (зокрема
        створені після знімка). Якщо ні — вимикаємо наосліп усе, що існувало у знімку, а збій по
        задачі лишається в Failed: мовчки вважати її вимкненою не можна.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Adapter,
        [string]$RuntimeRoot = '',
        $Snapshot = $null,
        [string]$TaskPath = '',
        [string[]]$ManagedTaskName = @()
    )

    $disabled = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]
    $targets = New-Object System.Collections.Generic.List[object]
    try {
        $snapshotScope = $null
        if ($null -ne $Snapshot) { $snapshotScope = Get-BRAVOReconcileScopeFromSnapshot -Snapshot $Snapshot }
        $effectiveRoot = Resolve-BRAVOReconcileRuntimeRoot -RuntimeRoot $RuntimeRoot -Snapshot $Snapshot
        $live = $null
        $liveError = ''
        try {
            if ($null -ne $snapshotScope) {
                $live = Get-BRAVOSchedulerSnapshot -Adapter $Adapter -RuntimeRoot $effectiveRoot -TaskPath $snapshotScope.TaskPath -ManagedTaskName $snapshotScope.Names
            } else {
                $live = Get-BRAVOSchedulerSnapshot -Adapter $Adapter -RuntimeRoot $effectiveRoot -TaskPath $TaskPath -ManagedTaskName $ManagedTaskName
            }
        } catch {
            $live = $null
            $liveError = [string]$_.Exception.Message
        }
        if ($null -ne $live) {
            foreach ($task in @($live.tasks)) {
                if ([bool]$task.exists) { $targets.Add([pscustomobject]@{ path = [string]$task.path; name = [string]$task.name }) }
            }
        } elseif ($null -ne $snapshotScope) {
            foreach ($task in @($Snapshot.tasks)) { if ([bool]$task.exists) { $targets.Add([pscustomobject]@{ path = $snapshotScope.TaskPath; name = [string]$task.name }) } }
        } else {
            $failed.Add([pscustomobject][ordered]@{ path = ''; name = ''; message = "Не вдалося визначити керовані задачі: $liveError" })
        }
        foreach ($target in $targets.ToArray()) {
            $set = Set-BRAVOReconcileTaskEnabled -Adapter $Adapter -TaskPath $target.path -Name $target.name -Enabled $false -RuntimeRoot $effectiveRoot
            if ($set.Success) {
                $disabled.Add([pscustomobject][ordered]@{ path = $target.path; name = $target.name })
            } else {
                $failed.Add([pscustomobject][ordered]@{ path = $target.path; name = $target.name; message = $set.Message })
            }
        }
    } catch {
        $failed.Add([pscustomobject][ordered]@{ path = ''; name = ''; message = [string]$_.Exception.Message })
    }
    return [pscustomobject]@{ Disabled = @($disabled.ToArray()); Failed = @($failed.ToArray()); IsComplete = ($failed.Count -eq 0) }
}

# ----------------------------------------------------------------------
# Реконсиляція scheduler
# ----------------------------------------------------------------------

function Get-BRAVOReconcileEnabledTask {
    # Задачі знімка, які існують і ввімкнені.
    [CmdletBinding()]
    param([AllowNull()]$Snapshot)
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($task in @(Get-BRAVOUpdatePropertyValue -InputObject $Snapshot -Name 'tasks' -Default @())) {
        if ([bool](Get-BRAVOUpdatePropertyValue -InputObject $task -Name 'exists' -Default $false) -and [bool](Get-BRAVOUpdatePropertyValue -InputObject $task -Name 'enabled' -Default $false)) { $result.Add($task) }
    }
    return @($result.ToArray())
}

function Invoke-BRAVOSchedulerReconcile {
    <#
    .SYNOPSIS
        Реєструє задачі через BRAVO_SETUP -Action Scheduler і ОДРАЗУ вимикає всі
        увімкнені керовані задачі -> { Verdict, ExitCode, CreatedTasks[], RequiescedTasks[], Problems[] }.
    .DESCRIPTION
        Факт F1: повторна реєстрація завжди вмикає задачу, тому повторне вимкнення
        виконується безумовно — і після невдалого BRAVO_SETUP (часткова реєстрація
        могла ввімкнути частину задач). Після вимкнення стан перечитується й
        перевіряється; якщо щось лишилось увімкненим — Verdict FAIL.
        Verdict: PASS | PASS_WITH_WARNING | FAIL (через Get-BRAVODeploySetupExitVerdict).
        Context: { Adapter, Paths{RuntimeRoot, StateRoot}, Journal }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$Snapshot)

    $adapter = Get-BRAVOUpdatePropertyValue -InputObject $Context -Name 'Adapter'
    $paths = Get-BRAVOUpdatePropertyValue -InputObject $Context -Name 'Paths'
    $runtimeRoot = [string](Get-BRAVOUpdatePropertyValue -InputObject $paths -Name 'RuntimeRoot' -Default '')
    $stateRoot = [string](Get-BRAVOUpdatePropertyValue -InputObject $paths -Name 'StateRoot' -Default '')
    $journal = Get-BRAVOUpdatePropertyValue -InputObject $Context -Name 'Journal'
    $shape = @(Test-BRAVOSchedulerSnapshotShape -Snapshot $Snapshot)
    if ($shape.Count -gt 0) { throw ('BRAVO.Update: знімок scheduler непридатний: ' + ($shape -join '; ')) }
    # Відсутні дії adapter-а виявляємо ДО будь-якої зміни.
    $setupScheduler = Get-BRAVOReconcileAdapterAction -Adapter $adapter -Name 'InvokeSetupScheduler'
    [void](Get-BRAVOReconcileAdapterAction -Adapter $adapter -Name 'SetTaskEnabled')
    [void](Get-BRAVOReconcileAdapterAction -Adapter $adapter -Name 'GetManagedTasks')

    $problems = New-Object System.Collections.Generic.List[string]
    $requiesced = New-Object System.Collections.Generic.List[object]
    $created = New-Object System.Collections.Generic.List[object]
    $hardFail = $false
    $exitCode = -1
    $setupVerdict = 'FAIL'

    try {
        $run = & $setupScheduler $runtimeRoot
        $rawExit = Get-BRAVOUpdatePropertyValue -InputObject $run -Name 'ExitCode' -Default $null
        $timedOut = [bool](Get-BRAVOUpdatePropertyValue -InputObject $run -Name 'TimedOut' -Default $false)
        if (($null -eq $run) -or (-not (Test-BRAVOUpdateWholeNumber -Value $rawExit))) {
            $problems.Add('BRAVO_SETUP -Action Scheduler не повернув код завершення.')
        } else {
            $exitCode = [int]$rawExit
            if ($timedOut) {
                $problems.Add('BRAVO_SETUP -Action Scheduler перевищив таймаут.')
            } else {
                $setupVerdict = Get-BRAVODeploySetupExitVerdict -ExitCode $exitCode
                if ($setupVerdict -eq 'FAIL') { $problems.Add("BRAVO_SETUP -Action Scheduler завершився з кодом $exitCode.") }
            }
        }
    } catch {
        $problems.Add("BRAVO_SETUP -Action Scheduler: виняток: $($_.Exception.Message)")
    }

    # --- Негайне повторне вимкнення (F1): виконується за будь-якого результату setup ---
    $current = $null
    try {
        $current = Get-BRAVOSchedulerSnapshot -Adapter $adapter -RuntimeRoot $runtimeRoot
    } catch {
        $problems.Add("Не вдалося прочитати задачі за новою конфігурацією: $($_.Exception.Message)")
        # Нова конфігурація недоступна — працюємо в області знімка до операції.
        $scope = Get-BRAVOReconcileScopeFromSnapshot -Snapshot $Snapshot
        if ($null -ne $scope) {
            try { $current = Get-BRAVOSchedulerSnapshot -Adapter $adapter -RuntimeRoot $runtimeRoot -TaskPath $scope.TaskPath -ManagedTaskName $scope.Names } catch { $current = $null }
        }
    }
    if ($null -eq $current) {
        $hardFail = $true
        $problems.Add('Стан задач після реєстрації невідомий: виконано аварійне вимкнення.')
        $emergency = Disable-BRAVOAllManagedTasks -Adapter $adapter -RuntimeRoot $runtimeRoot -Snapshot $Snapshot
        foreach ($item in @($emergency.Disabled)) { $requiesced.Add($item) }
        foreach ($item in @($emergency.Failed)) { $problems.Add("Не вимкнено '$($item.name)': $($item.message)") }
    } else {
        # Створені = існують зараз, але не існували у знімку до операції.
        foreach ($task in @($current.tasks)) {
            if (-not [bool]$task.exists) { continue }
            $before = $false
            foreach ($old in @(Get-BRAVOUpdatePropertyValue -InputObject $Snapshot -Name 'tasks' -Default @())) {
                if ([bool]$old.exists -and [string]::Equals([string]$old.name, [string]$task.name, [StringComparison]::OrdinalIgnoreCase) -and
                    [string]::Equals([string]$Snapshot.taskPath, [string]$task.path, [StringComparison]::OrdinalIgnoreCase)) { $before = $true }
            }
            if (-not $before) { $created.Add([pscustomobject][ordered]@{ path = [string]$task.path; name = [string]$task.name }) }
        }
        # Створені задачі фіксуємо в журналі ДО вимкнення: збій посеред вимкнення не має їх загубити.
        if (($null -ne $journal) -and ($created.Count -gt 0)) {
            try {
                [void](Add-BRAVOUpdateJournalCreatedTask -Journal $journal -Task @($created.ToArray()) -StateRoot $stateRoot)
            } catch {
                $hardFail = $true
                $problems.Add("Не вдалося записати створені задачі в журнал: $($_.Exception.Message)")
            }
        }
        $verified = $false
        $currentTaskPath = [string]$current.taskPath
        $currentNames = @($current.tasks | ForEach-Object { [string]$_.name })
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            if ($attempt -gt 1) {
                try {
                    $current = Get-BRAVOSchedulerSnapshot -Adapter $adapter -RuntimeRoot $runtimeRoot -TaskPath $currentTaskPath -ManagedTaskName $currentNames
                } catch {
                    $problems.Add("Повторне читання задач не вдалося: $($_.Exception.Message)")
                    break
                }
            }
            $enabledNow = @(Get-BRAVOReconcileEnabledTask -Snapshot $current)
            if ($enabledNow.Count -eq 0) { $verified = $true; break }
            $suspend = Suspend-BRAVOManagedTasks -Snapshot $current -Adapter $adapter -RuntimeRoot $runtimeRoot
            foreach ($item in @($suspend.Disabled)) { $requiesced.Add($item) }
            foreach ($item in @($suspend.Failed)) { $problems.Add("Не вимкнено '$($item.name)': $($item.message)") }
        }
        if (-not $verified) {
            $hardFail = $true
            $problems.Add('Після реєстрації частина керованих задач лишається увімкненою.')
        }
    }

    $verdict = $setupVerdict
    if ($hardFail) { $verdict = 'FAIL' }
    # Унікальні вимкнені задачі (повторні спроби не дублюють записи).
    $uniqueRequiesced = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($item in $requiesced.ToArray()) {
        $key = (([string]$item.path) + '|' + ([string]$item.name)).ToUpperInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $uniqueRequiesced.Add($item) }
    }
    return [pscustomobject][ordered]@{
        Verdict         = $verdict
        ExitCode        = $exitCode
        CreatedTasks    = @($created.ToArray())
        RequiescedTasks = @($uniqueRequiesced.ToArray())
        Problems        = @($problems.ToArray())
    }
}

# ----------------------------------------------------------------------
# Активація задач (D6)
# ----------------------------------------------------------------------

function Set-BRAVOTaskActivation {
    <#
    .SYNOPSIS
        Визначає й застосовує політику активації -> { TaskActivation{state, tasks[]}, Findings[], Restore }.
    .DESCRIPTION
        -Policy: рядок activationPolicy плану (ActivateOnSuccessOnly | ActivateOnWarnings)
        або об'єкт із полями activationPolicy і action. -Action (Install|Update|Repair)
        перекриває Policy.action; без жодного — Update.
        Правила (ENGINE_DESIGN.md, розділ 5):
          Update/Repair + Success            -> відновити попередній стан;
          Update/Repair + SuccessWithWarnings -> відновити попередній стан + Warning finding (D6);
          Update/Repair + Failed/RolledBack  -> відновити попередній стан (D6);
          Install (будь-який результат)       -> Inactive;
          Critical                            -> ніколи не вмикати (лише вимкнути).
        Стан Inactive перевіряється читанням; якщо перевірити/вимкнути не вдалось —
        Unknown і Warning, а не вигаданий «Inactive».
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Policy,
        [Parameter(Mandatory = $true)][AllowNull()]$Snapshot,
        [Parameter(Mandatory = $true)]$Adapter,
        [Parameter(Mandatory = $true)][ValidateSet('Success', 'SuccessWithWarnings', 'Failed', 'RolledBack', 'Critical')][string]$OutcomeStatus,
        [ValidateSet('', 'Install', 'Update', 'Repair')][string]$Action = '',
        [string[]]$WarningText = @(),
        [string]$RuntimeRoot = ''
    )

    $effectiveRoot = Resolve-BRAVOReconcileRuntimeRoot -RuntimeRoot $RuntimeRoot -Snapshot $Snapshot
    $activationPolicy = 'ActivateOnSuccessOnly'
    $policyAction = ''
    if ($Policy -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($Policy)) { $activationPolicy = $Policy }
    } elseif ($null -ne $Policy) {
        $activationPolicy = [string](Get-BRAVOUpdatePropertyValue -InputObject $Policy -Name 'activationPolicy' -Default 'ActivateOnSuccessOnly')
        $policyAction = [string](Get-BRAVOUpdatePropertyValue -InputObject $Policy -Name 'action' -Default '')
    }
    $effectiveAction = $Action
    if ($effectiveAction -eq '') { $effectiveAction = $policyAction }
    if (@('Install', 'Update', 'Repair') -notcontains $effectiveAction) { $effectiveAction = 'Update' }

    $findings = New-Object System.Collections.Generic.List[object]
    $restore = $null

    $unknown = {
        param([string]$Id, [string]$Title, [string]$Meaning, [string]$Details)
        $findings.Add((New-BRAVOUpdateFinding -Id $Id -Severity Warning -Title $Title -Meaning $Meaning `
            -Action 'Перевірте стан задач BRAVO у Планувальнику завдань і за потреби вимкніть їх вручну.' -Details $Details))
        return [pscustomobject][ordered]@{ state = 'Unknown'; tasks = @() }
    }

    $shape = @(Test-BRAVOSchedulerSnapshotShape -Snapshot $Snapshot)
    if ($shape.Count -gt 0) {
        $activation = & $unknown 'Activation.SnapshotInvalid' 'Стан активації задач невідомий' 'Знімок scheduler відсутній або пошкоджений; задачі не змінювались.' ($shape -join '; ')
        return [pscustomobject]@{ TaskActivation = $activation; Findings = @($findings.ToArray()); Restore = $null }
    }
    $scope = Get-BRAVOReconcileScopeFromSnapshot -Snapshot $Snapshot

    # Яку гілку виконуємо: відновлення попереднього стану чи утримання вимкненими.
    $restorePrevious = $false
    switch ($OutcomeStatus) {
        'Critical' { $restorePrevious = $false }
        'Success' {
            if ($effectiveAction -eq 'Install') {
                $restorePrevious = $false
                $findings.Add((New-BRAVOUpdateFinding -Id 'Activation.InstallInactive' -Severity Ok -Title 'Задачі лишаються неактивними після встановлення' `
                    -Meaning 'Після чистого встановлення задачі вмикаються лише після введення облікових даних і явного підтвердження.' `
                    -Action 'Введіть облікові дані, виконайте Відновлення планувальника й активуйте задачі.'))
            } else { $restorePrevious = $true }
        }
        'SuccessWithWarnings' {
            if ($effectiveAction -eq 'Install') {
                $restorePrevious = $false
            } else {
                # D6: попередній enabled-стан зберігається; попередження лише повідомляємо.
                $restorePrevious = $true
                $warningDetails = (@($WarningText | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join '; ')
                $findings.Add((New-BRAVOUpdateFinding -Id 'Activation.RestoredWithWarnings' -Severity Warning -Title 'Задачі відновлено в попередньому стані, операція мала попередження' `
                    -Meaning 'Операція завершилась із попередженнями; задачі повернено до стану до операції, нові задачі не активовано.' `
                    -Action 'Перегляньте попередження операції й за потреби перевірте задачі в Планувальнику завдань.' -Details $warningDetails))
            }
        }
        default {
            # Failed / RolledBack: Install не мав попередніх задач, Update/Repair повертаються до знімка.
            $restorePrevious = ($effectiveAction -ne 'Install')
        }
    }

    $expectedEnabled = @(Get-BRAVOReconcileEnabledTask -Snapshot $Snapshot)
    if ($restorePrevious) {
        $restore = Restore-BRAVOManagedTaskState -Snapshot $Snapshot -Adapter $Adapter -RuntimeRoot $effectiveRoot
        if (-not $restore.IsComplete) {
            $details = (@($restore.Failed | ForEach-Object { [string]$_.name + ': ' + [string]$_.message }) -join '; ')
            $activation = & $unknown 'Activation.RestoreIncomplete' 'Не всі задачі відновлено в попередньому стані' 'Частина задач, що були активні до операції, не ввімкнена.' $details
            return [pscustomobject]@{ TaskActivation = $activation; Findings = @($findings.ToArray()); Restore = $restore }
        }
        $state = 'Unchanged'
        if ($expectedEnabled.Count -gt 0) { $state = 'Active' }
        $listed = New-Object System.Collections.Generic.List[object]
        foreach ($task in @($Snapshot.tasks)) {
            if ([bool]$task.exists) { $listed.Add([pscustomobject][ordered]@{ name = [string]$task.name; path = [string]$task.path; enabled = [bool]$task.enabled }) }
        }
        $activation = [pscustomobject][ordered]@{ state = $state; tasks = @($listed.ToArray()) }
        return [pscustomobject]@{ TaskActivation = $activation; Findings = @($findings.ToArray()); Restore = $restore }
    }

    # Утримання вимкненими: читаємо поточний стан, за потреби вимикаємо, перевіряємо.
    if ($null -eq $scope) {
        $activation = & $unknown 'Activation.ScopeUnknown' 'Стан активації задач невідомий' 'Не визначено керовані задачі зі знімка.' ''
        return [pscustomobject]@{ TaskActivation = $activation; Findings = @($findings.ToArray()); Restore = $null }
    }
    $final = $null
    $details = ''
    try {
        $final = Get-BRAVOSchedulerSnapshot -Adapter $Adapter -RuntimeRoot $effectiveRoot -TaskPath $scope.TaskPath -ManagedTaskName $scope.Names
        $stillEnabled = @(Get-BRAVOReconcileEnabledTask -Snapshot $final)
        if ($stillEnabled.Count -gt 0) {
            $suspend = Suspend-BRAVOManagedTasks -Snapshot $final -Adapter $Adapter -RuntimeRoot $effectiveRoot
            $details = (@($suspend.Failed | ForEach-Object { [string]$_.name + ': ' + [string]$_.message }) -join '; ')
            $final = Get-BRAVOSchedulerSnapshot -Adapter $Adapter -RuntimeRoot $effectiveRoot -TaskPath $scope.TaskPath -ManagedTaskName $scope.Names
        }
    } catch {
        $final = $null
        $details = [string]$_.Exception.Message
    }
    if (($null -eq $final) -or (@(Get-BRAVOReconcileEnabledTask -Snapshot $final).Count -gt 0)) {
        $activation = & $unknown 'Activation.NotDisabled' 'Не вдалося підтвердити, що задачі неактивні' 'Деякі керовані задачі можуть бути увімкнені, хоча активацію заборонено політикою.' $details
        return [pscustomobject]@{ TaskActivation = $activation; Findings = @($findings.ToArray()); Restore = $null }
    }
    $listed = New-Object System.Collections.Generic.List[object]
    foreach ($task in @($final.tasks)) {
        if ([bool]$task.exists) { $listed.Add([pscustomobject][ordered]@{ name = [string]$task.name; path = [string]$task.path; enabled = $false }) }
    }
    $activation = [pscustomobject][ordered]@{ state = 'Inactive'; tasks = @($listed.ToArray()) }
    return [pscustomobject]@{ TaskActivation = $activation; Findings = @($findings.ToArray()); Restore = $null }
}
