# BRAVO.Update.Deploy — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Спільне ядро mutation-операцій Installer v1 (docs\installer\ENGINE_DESIGN.md,
# розділи 2 і 4): контекст операції, виконавець фаз із write-ahead журналом,
# failure injection, cancel, файловий набір розгортання, перевірене копіювання,
# і orchestrator Update/Repair (кроки U0-U19).
#
# ТОЧКИ ПОВТОРНОГО ВИКОРИСТАННЯ (для Recovery/Repair/Install):
#   * New-BRAVOUpdateOperationContext + Invoke-BRAVOUpdatePhase — фазовий двигун;
#     будь-яка нова операція виконує кроки лише через Invoke-BRAVOUpdatePhase,
#     щоб cancel, fault-точки, intent/completion і ProgressEvent були єдині.
#   * Open-BRAVOUpdateOperation (U0-U4: актуальність плану, lifecycle lock, Open-журнал,
#     replay-реєстр, каталог операції, журнал, контекст) — для Install теж.
#   * Invoke-BRAVOUpdateAcquireStage (U5-U6: Acquire/Verify/Stage/staged-валідація +
#     файловий набір) — для Install: Get-BRAVODeploymentFileSet на порожньому runtime
#     дає лише Add.
#   * Invoke-BRAVOUpdatePlanRecheck (U7), Invoke-BRAVOUpdateEnterOperationLock (U9),
#     Invoke-BRAVOUpdateCaptureBaseline (U10), Start-BRAVOUpdateMutation (U11) —
#     «дрібні» кроки між backup і межею mutation.
#   * Resolve-BRAVOUpdateOperationFailure — єдине місце вибору «до межі: Abandoned +
#     прибирання» чи «після межі: Invoke-BRAVORollback»; Crash не перехоплюється.
#   * Close-BRAVOUpdateOperationHandles — звільнення lock-ів у finally.
#   * Get-BRAVODeploymentFileSet / Save-BRAVODeploymentKeySet /
#     Invoke-BRAVORuntimeDeploy / Copy-BRAVOUpdateVerifiedFile — файлова частина.
#   * Remove-BRAVOUpdateOperationDirectory — ЄДИНИЙ дозволений рекурсивний delete
#     (Recovery викликає його на <journal.stagingRoot|backupRoot>\<opId>).
#   * Set-BRAVOUpdateJournalField (частина Rollback, E5) — додаткові поля журналу
#     (baseline, deployKeys, versionState, createdTasks, rollbackAttempts).
#
# LOCK-и і Rollback: orchestrator тримає lifecycle lock і operation lock і
# викликає Invoke-BRAVORollback з -Context (Context.Handles.LifecycleLock /
# OperationLock заповнені). Rollback НЕ бере lifecycle lock повторно, якщо він є в
# Context.Handles; operation lock бере лише коли Handles.OperationLock порожній.
#
# Нові поля журналу (поза CONTRACTS §8, валідатор їх пропускає): deployKeys
# { path, sha256 } — шлях і SHA-256 deploy-keys.json; baseline { siteConfig,
# guardExitCode }; versionState { present, sha256, recordedVersion, snapshotPath };
# createdTasks.
#
# Фазові виклики лишають проміжні значення у Context.Data (hashtable):
#   StagingDirectory, StagedRoot, Payload, Verification, FileSet, KeySet, Backup,
#   SiteBaseline, SchedulerSnapshot, VersionStateSnapshot, GuardBaselineExitCode,
#   SchedulerReconcile, TaskActivation, Deployed, Scope.
#
# У цьому файлі немає виводу в консоль, exit і $global:. Функції інших частин
# (Backup/Reconcile/Validation/Rollback/Repair) викликаються за іменами з ENGINE_DESIGN.

# Розширення скриптів, які вважаються виконуваним кодом (сторонні — blocker).
$script:BRAVOUpdateScriptExtensions = @('.ps1', '.psm1', '.psd1')

# ---------------------------------------------------------------------------
# Типізовані винятки, fault injection, cancel
# ---------------------------------------------------------------------------

function New-BRAVOUpdateTypedException {
    <#
    .SYNOPSIS
        Створює виняток із типом збою у Data. Тип визначає, як orchestrator
        перетворить збій на DeploymentResult.
    .DESCRIPTION
        У Exception.Data можна класти лише серіалізовані значення (.NET Framework
        відхиляє PSCustomObject), тому finding тут не передається — лише його id,
        підказка коду й текст дії; об'єкт finding будує orchestrator.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][ValidateSet('Crash', 'Cancel', 'CancelAfterMutation', 'Blocked', 'Verification', 'PlanStale', 'Error')][string]$Kind,
        [string]$FindingId = '',
        [AllowNull()][object]$ExitCodeHint = $null,
        [string]$Action = ''
    )

    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['BRAVOUpdateKind'] = $Kind
    $exception.Data['BRAVOUpdateFindingId'] = $FindingId
    $exception.Data['BRAVOUpdateAction'] = $Action
    if ($null -ne $ExitCodeHint) { $exception.Data['BRAVOUpdateHint'] = [int]$ExitCodeHint }
    return $exception
}

function Get-BRAVOUpdateExceptionKind {
    <#
    .SYNOPSIS
        Тип збою з ErrorRecord: { Kind, FindingId, ExitCodeHint, Action, Message }.
        Виняток без позначки = 'Error'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $info = [pscustomobject]@{ Kind = 'Error'; FindingId = ''; ExitCodeHint = $null; Action = ''; Message = '' }
    $exception = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $exception = $ErrorRecord.Exception } elseif ($ErrorRecord -is [System.Exception]) { $exception = $ErrorRecord }
    if ($null -eq $exception) { return $info }
    $info.Message = [string]$exception.Message
    # Конвенція E5/E6: імітація смерті процесу = повідомлення з цим префіксом.
    if ($info.Message.StartsWith('BRAVOUpdate.SimulatedCrash', [StringComparison]::Ordinal)) { $info.Kind = 'Crash'; return $info }
    $depth = 0
    while (($null -ne $exception) -and ($depth -lt 8)) {
        if ($exception.Data.Contains('BRAVOUpdateKind')) {
            $info.Kind = [string]$exception.Data['BRAVOUpdateKind']
            $info.FindingId = [string]$exception.Data['BRAVOUpdateFindingId']
            $info.Action = [string]$exception.Data['BRAVOUpdateAction']
            if ($exception.Data.Contains('BRAVOUpdateHint')) { $info.ExitCodeHint = [int]$exception.Data['BRAVOUpdateHint'] }
            $info.Message = [string]$exception.Message
            return $info
        }
        $exception = $exception.InnerException
        $depth++
    }
    return $info
}

function Get-BRAVOUpdateCancelPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    return (Join-Path (Join-Path $Context.OperationDirectory 'control') 'cancel')
}

function Test-BRAVOUpdateCancelRequested {
    <#
    .SYNOPSIS
        $true, якщо є файл <OperationDirectory>\control\cancel. Вміст файлу НЕ
        читається: каталог control доступний на створення неелевованому запускачу,
        тому файл — лише сигнал, а не носій даних.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    if ([IO.File]::Exists((Get-BRAVOUpdateCancelPath -Context $Context))) { $Context.CancelRequested = $true }
    return [bool]$Context.CancelRequested
}

function Invoke-BRAVOUpdateFaultPoint {
    <#
    .SYNOPSIS
        Failure injection (ENGINE_DESIGN 2.3): значення Throw | Crash | Cancel для
        ключа '<Phase>.<Point>'. Лише тести передають FaultInjection у функцію
        engine; Worker і CLI його ніколи не читають із request чи аргументів.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Point
    )

    $injection = $Context.FaultInjection
    if (($null -eq $injection) -or (-not $injection.ContainsKey($Point))) { return }
    $mode = [string]$injection[$Point]
    switch -CaseSensitive ($mode) {
        'Throw' { throw (New-BRAVOUpdateTypedException -Message ('BRAVOUpdate.InjectedFault: ' + $Point) -Kind Error) }
        'Crash' { throw (New-BRAVOUpdateTypedException -Message ('BRAVOUpdate.SimulatedCrash: ' + $Point) -Kind Crash) }
        'Cancel' {
            $cancelPath = Get-BRAVOUpdateCancelPath -Context $Context
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($cancelPath))
            [IO.File]::WriteAllText($cancelPath, '', (New-Object System.Text.UTF8Encoding($false)))
        }
        default { throw (New-BRAVOUpdateTypedException -Message ("BRAVOUpdate.InjectedFault: невідомий режим '$mode' для $Point") -Kind Error) }
    }
}

# ---------------------------------------------------------------------------
# Контекст операції і виконавець фаз
# ---------------------------------------------------------------------------

function New-BRAVOUpdateOperationContext {
    <#
    .SYNOPSIS
        Контекст операції (ENGINE_DESIGN 2.1). Стану $script: немає: усе, що
        потрібно фазам, лежить у цьому об'єкті.
    .DESCRIPTION
        Paths — об'єкт/hashtable з усіма сімома коренями. Findings/Validation —
        List[object], Handles — місце для lock-ів, Data — hashtable для проміжних
        результатів кроків (див. шапку файлу).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$OperationDirectory,
        [Parameter(Mandatory = $true)]$Journal,
        [hashtable]$FaultInjection = $null
    )

    $normalizedPaths = [ordered]@{}
    foreach ($name in @('RuntimeRoot', 'StateRoot', 'LockRoot', 'StagingRoot', 'BackupRoot', 'OperationLockPath', 'VersionStatePath')) {
        $value = Get-BRAVOUpdatePropertyValue -InputObject $Paths -Name $name
        if ([string]::IsNullOrWhiteSpace([string]$value)) { throw "BRAVO.Update: у Paths відсутній корінь '$name'." }
        $normalizedPaths[$name] = [string]$value
    }
    $operationId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'operationId' -Default '')
    if ([string]::IsNullOrWhiteSpace($operationId)) { $operationId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'operationId' -Default '') }
    if (-not (Test-BRAVOUpdateGuidText -Value $operationId)) { throw 'BRAVO.Update: контекст потребує operationId (GUID у нижньому регістрі).' }
    if ($null -eq $FaultInjection) { $FaultInjection = @{} }
    $writer = New-BRAVOUpdateProgressWriter -Path (Join-Path $OperationDirectory 'progress.jsonl') -OperationId $operationId
    $mutationStarted = ((Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'mutationStarted' -Default $false) -eq $true)
    return [pscustomobject]@{
        OperationId        = $operationId
        Action             = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'action' -Default '')
        Plan               = $Plan
        Adapter            = $Adapter
        Paths              = [pscustomobject]$normalizedPaths
        OperationDirectory = $OperationDirectory
        Journal            = $Journal
        ProgressWriter     = $writer
        CancelRequested    = $false
        MutationStarted    = $mutationStarted
        LastPhase          = $null
        Findings           = (New-Object 'System.Collections.Generic.List[object]')
        Validation         = (New-Object 'System.Collections.Generic.List[object]')
        Handles            = [pscustomobject]@{ LifecycleLock = $null; OperationLock = $null }
        Data               = @{}
        FaultInjection     = $FaultInjection
    }
}

function Send-BRAVOUpdatePhaseProgress {
    # Прогрес — best-effort: збій запису події не повинен відкотити розгортання.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$ProgressPhase,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$PhaseName,
        [AllowNull()][object]$Percent = $null,
        [string]$Message = ''
    )

    try {
        [void](Send-BRAVOUpdateProgress -Writer $Context.ProgressWriter -Phase $ProgressPhase -Status $Status -Percent $Percent `
                -MessageKey ('Update.Phase.' + $PhaseName + '.' + $Status) -MessageArgs @() -Message $Message)
    } catch {
        $null = $_
    }
}

function Add-BRAVOUpdateContextFinding {
    # Додає finding у контекст один раз за id (повторні виклики не множать рядки).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$Finding)

    foreach ($existing in $Context.Findings) {
        if ([string]$existing.id -ceq [string]$Finding.id) { return }
    }
    $Context.Findings.Add($Finding)
}

function Invoke-BRAVOUpdatePhase {
    <#
    .SYNOPSIS
        Виконавець фаз (ENGINE_DESIGN 2.2): cancel-перевірка -> fault Before ->
        (durable) intent -> fault AfterIntent -> Action -> fault AfterSideEffect ->
        (durable) completion -> ProgressEvent Completed -> fault AfterComplete.
    .DESCRIPTION
        Повертає останній об'єкт виводу Action (або $null). Збій Action: durable-фаза
        закривається outcome 'Failed' і подією Failed; тип Crash не закриває нічого
        (імітація смерті процесу — recovery бачить intent без completion).
        IgnoreCancel: cancel не зупиняє фазу, а лише фіксується finding-ом
        (Activate/Commit: після початку активації cancel ігнорується).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][ValidateSet('Preflight', 'Acquire', 'Verify', 'Stage', 'Backup', 'Deploy', 'Configure', 'Validate', 'Activate', 'Commit', 'Rollback', 'Recovery')][string]$ProgressPhase,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [switch]$Durable,
        [switch]$IgnoreCancel,
        [AllowNull()][object]$Percent = $null
    )

    $phStateRoot = [string]$Context.Paths.StateRoot
    if (Test-BRAVOUpdateCancelRequested -Context $Context) {
        if ($IgnoreCancel) {
            Add-BRAVOUpdateContextFinding -Context $Context -Finding (New-BRAVOUpdateFinding -Id 'Operation.CancelIgnored' -Severity Warning `
                    -Title 'Запит на скасування проігноровано' `
                    -Meaning 'Після початку активації завдань скасування небезпечне, тому операцію доведено до кінця.' `
                    -Details ('фаза=' + $Phase))
        } elseif ($Context.MutationStarted) {
            throw (New-BRAVOUpdateTypedException -Message 'Операцію скасовано після початку змін: виконується відкат.' -Kind CancelAfterMutation)
        } else {
            throw (New-BRAVOUpdateTypedException -Message 'Операцію скасовано оператором до початку змін.' -Kind Cancel)
        }
    }
    Invoke-BRAVOUpdateFaultPoint -Context $Context -Point ($Phase + '.Before')
    Send-BRAVOUpdatePhaseProgress -Context $Context -ProgressPhase $ProgressPhase -Status 'Started' -PhaseName $Phase -Percent $Percent -Message ('Фаза ' + $Phase + ': розпочато')
    $phIntentWritten = $false
    $phOutput = @()
    try {
        if ($Durable) {
            [void](Add-BRAVOUpdateJournalPhaseIntent -Journal $Context.Journal -Phase $Phase -StateRoot $phStateRoot)
            $phIntentWritten = $true
        }
        Invoke-BRAVOUpdateFaultPoint -Context $Context -Point ($Phase + '.AfterIntent')
        $phOutput = @(& $Action $Context)
        Invoke-BRAVOUpdateFaultPoint -Context $Context -Point ($Phase + '.AfterSideEffect')
        if ($Durable) { [void](Complete-BRAVOUpdateJournalPhase -Journal $Context.Journal -Phase $Phase -Outcome 'Succeeded' -StateRoot $phStateRoot) }
    } catch {
        $phFailure = $_
        $phKind = (Get-BRAVOUpdateExceptionKind -ErrorRecord $phFailure).Kind
        if ($phKind -cne 'Crash') {
            if ($phIntentWritten) {
                try { [void](Complete-BRAVOUpdateJournalPhase -Journal $Context.Journal -Phase $Phase -Outcome 'Failed' -StateRoot $phStateRoot) } catch { $null = $_ }
            }
            Send-BRAVOUpdatePhaseProgress -Context $Context -ProgressPhase $ProgressPhase -Status 'Failed' -PhaseName $Phase -Message ('Фаза ' + $Phase + ': збій')
        }
        throw $phFailure
    }
    $Context.LastPhase = $Phase
    Send-BRAVOUpdatePhaseProgress -Context $Context -ProgressPhase $ProgressPhase -Status 'Completed' -PhaseName $Phase -Percent $Percent -Message ('Фаза ' + $Phase + ': завершено')
    Invoke-BRAVOUpdateFaultPoint -Context $Context -Point ($Phase + '.AfterComplete')
    if ($phOutput.Count -eq 0) { return $null }
    return $phOutput[$phOutput.Count - 1]
}

function Get-BRAVOUpdateArrayProperty {
    # Властивість-масив без $null-елементів (порожня/відсутня властивість -> порожній масив).
    [CmdletBinding()]
    param([AllowNull()]$InputObject, [Parameter(Mandatory = $true)][string]$Name)

    if (-not (Test-BRAVOUpdateHasProperty -InputObject $InputObject -Name $Name)) { return @() }
    $raw = $null
    if ($InputObject -is [System.Collections.IDictionary]) { $raw = $InputObject[$Name] } else { $raw = $InputObject.PSObject.Properties[$Name].Value }
    if ($null -eq $raw) { return @() }
    $items = New-Object 'System.Collections.Generic.List[object]'
    # foreach напряму, без @(): @(<List[object]>) кидає 'Argument types do not match' у PS 5.1.
    foreach ($item in $raw) { if ($null -ne $item) { $items.Add($item) } }
    return $items.ToArray()
}

# ---------------------------------------------------------------------------
# Єдине дозволене рекурсивне видалення
# ---------------------------------------------------------------------------

function Remove-BRAVOUpdateOperationDirectory {
    <#
    .SYNOPSIS
        Видаляє каталог операції <ExpectedParent>\<OperationId> і лише його.
    .DESCRIPTION
        Захист: OperationId — GUID; leaf шляху == OperationId; батько == очікуваний
        корінь; жоден предок кореня (разом із ним) не reparse point; (H1) корінь
        належить довіреному власнику й не доступний на запис недовіреним
        (Get-BRAVOUpdateProtectedRootProblem -Lenient): інакше підміна всередині
        дерева могла б спрямувати рекурсивне видалення на чужі дані. -AllowedRoot —
        явний перелік коренів engine (production: StagingRoot/BackupRoot/Operations);
        якщо задано, ExpectedParent мусить дорівнювати одному з них. Обхід НЕ заходить
        у reparse point і ПЕРЕД перелічуванням кожного каталогу заново перевіряє його
        атрибут (замінений на junction після додавання в чергу — пропускається з
        записом у Problems); junction/symlink видаляється як посилання, ціль лишається
        недоторканою. Порушення гарду — виняток; збій видалення окремого елемента — у
        Problems без винятку.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedParent,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [string[]]$AllowedRoot = @(),
        [scriptblock]$AdminCheck = $null
    )

    if (-not (Test-BRAVOUpdateGuidText -Value $OperationId)) { throw "BRAVO.Update: некоректний operationId '$OperationId' для видалення каталогу." }
    $fullPath = Get-BRAVOUpdateFullPath -Path $Path
    $fullParent = Get-BRAVOUpdateFullPath -Path $ExpectedParent
    if (-not [string]::Equals([IO.Path]::GetFileName($fullPath), $OperationId, [StringComparison]::OrdinalIgnoreCase)) {
        throw "BRAVO.Update: ім'я каталогу '$fullPath' не збігається з operationId; видалення відхилено."
    }
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($fullPath), $fullParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "BRAVO.Update: каталог '$fullPath' лежить не в очікуваному корені '$fullParent'; видалення відхилено."
    }
    if (@($AllowedRoot).Count -gt 0) {
        $listed = $false
        foreach ($allowed in @($AllowedRoot)) {
            if ((-not [string]::IsNullOrWhiteSpace($allowed)) -and (Test-BRAVOUpdateWorkerSamePath -Left $allowed -Right $fullParent)) { $listed = $true }
        }
        if (-not $listed) { throw "BRAVO.Update: корінь '$fullParent' не входить до дозволених коренів engine; видалення відхилено." }
    }
    $attributesOf = {
        param([string]$Target)
        try { return [IO.File]::GetAttributes($Target) } catch [System.IO.FileNotFoundException] { return $null } catch [System.IO.DirectoryNotFoundException] { return $null }
    }
    # Корінь і ВСІ його предки: reparse на будь-якому рівні перенаправив би видалення.
    if (Test-BRAVOUpdatePathHasReparsePoint -Path $fullParent) {
        throw "BRAVO.Update: очікуваний корінь '$fullParent' (або його предок) є reparse point; видалення відхилено."
    }
    $parentAttributes = & $attributesOf $fullParent
    # Перевірка власника/прав — коли викликач задав -AllowedRoot (production: корені engine, які
    # Initialize-BRAVOUpdateProtectedRoots уже довів до захищеного стану). Без -AllowedRoot
    # лишається лише reparse/leaf/parent-гард (сумісність викликачів поза H1, напр. Recovery).
    if (($null -ne $parentAttributes) -and (@($AllowedRoot).Count -gt 0)) {
        $rootProblem = @(Get-BRAVOUpdateProtectedRootProblem -Path $fullParent -Kind ReadOnly -Lenient -AdminCheck $AdminCheck)
        if ($rootProblem.Count -gt 0) {
            throw ("BRAVO.Update: корінь '$fullParent' не пройшов перевірку власника/прав (" + ($rootProblem -join '; ') + '); видалення відхилено.')
        }
    }
    return (Remove-BRAVOUpdateDirectoryTreeNoFollow -FullPath $fullPath)
}

function Remove-BRAVOUpdateDirectoryTreeNoFollow {
    # Ядро guarded-видалення (без перевірки кореня: гарди — у викликача). Не заходить у
    # reparse point, атрибут кожного каталогу перевіряється ПЕРЕД перелічуванням.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$FullPath)

    $fullPath = $FullPath
    $attributesOf = {
        param([string]$Target)
        try { return [IO.File]::GetAttributes($Target) } catch [System.IO.FileNotFoundException] { return $null } catch [System.IO.DirectoryNotFoundException] { return $null }
    }
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $rootAttributes = & $attributesOf $fullPath
    $result = [pscustomobject]@{ Path = $fullPath; Existed = ($null -ne $rootAttributes); Removed = $false; Problems = @() }
    if ($null -eq $rootAttributes) { return $result }
    $isDirectory = (($rootAttributes -band [IO.FileAttributes]::Directory) -ne 0)
    $isReparse = (($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    if ((-not $isDirectory) -or $isReparse) {
        # Файл або посилання на місці каталогу операції: видаляємо лише саме посилання.
        try {
            if ($isDirectory) { [IO.Directory]::Delete($fullPath, $false) } else { [IO.File]::Delete($fullPath) }
        } catch {
            $problems.Add(('не вдалося видалити ' + $fullPath + ': ' + $_.Exception.Message))
        }
        $result.Removed = ($null -eq (& $attributesOf $fullPath))
        $result.Problems = $problems.ToArray()
        return $result
    }

    $visited = New-Object 'System.Collections.Generic.List[string]'
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($fullPath)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        # Атрибут перевіряється ПЕРЕД перелічуванням: між додаванням у чергу й заходом
        # каталог могли замінити junction-ом (TOCTOU) — тоді не заходимо, лише фіксуємо.
        $currentAttributes = & $attributesOf $current
        if ($null -eq $currentAttributes) { continue }
        if (($currentAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $problems.Add(('каталог ' + $current + ' став reparse point під час видалення; пропущено'))
            continue
        }
        $visited.Add($current)
        $children = @()
        try { $children = [IO.Directory]::GetFileSystemEntries($current) } catch { $problems.Add(('не вдалося прочитати ' + $current + ': ' + $_.Exception.Message)); continue }
        foreach ($child in $children) {
            $childAttributes = & $attributesOf $child
            if ($null -eq $childAttributes) { continue }
            $childIsDirectory = (($childAttributes -band [IO.FileAttributes]::Directory) -ne 0)
            $childIsReparse = (($childAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            try {
                if ($childIsReparse) {
                    if ($childIsDirectory) { [IO.Directory]::Delete($child, $false) } else { [IO.File]::Delete($child) }
                } elseif ($childIsDirectory) {
                    $pending.Push($child)
                } else {
                    if (($childAttributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { [IO.File]::SetAttributes($child, [IO.FileAttributes]::Normal) }
                    [IO.File]::Delete($child)
                }
            } catch {
                $problems.Add(('не вдалося видалити ' + $child + ': ' + $_.Exception.Message))
            }
        }
    }
    for ($index = $visited.Count - 1; $index -ge 0; $index--) {
        try { [IO.Directory]::Delete($visited[$index], $false) } catch { $problems.Add(('не вдалося видалити каталог ' + $visited[$index] + ': ' + $_.Exception.Message)) }
    }
    $result.Removed = ($null -eq (& $attributesOf $fullPath))
    $result.Problems = $problems.ToArray()
    return $result
}

# ---------------------------------------------------------------------------
# Файловий набір розгортання
# ---------------------------------------------------------------------------

function Get-BRAVOUpdateDeployTreeScan {
    <#
    .SYNOPSIS
        Обхід дерева без заходу в reparse point і в виключені каталоги:
        { Keys[] (відносні ключі з '/'), ReparsePoints[] }.
    .DESCRIPTION
        Get-BRAVODeployTreeKeys заходить у junction (GetDirectories їх повертає),
        а для Deploy це небезпечно: набір ключів тоді описував би чужий том.
        Виключення — та сама семантика robocopy /XF /XD (Test-BRAVODeployPathExcluded).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs = @()
    )

    $keys = New-Object 'System.Collections.Generic.List[string]'
    $reparse = New-Object 'System.Collections.Generic.List[string]'
    if ([IO.Directory]::Exists($Root)) {
        $rootFull = $Root.TrimEnd('\', '/')
        $prefixLength = $rootFull.Length + 1
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($rootFull)
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            foreach ($subdirectory in [IO.Directory]::GetDirectories($directory)) {
                $name = [IO.Path]::GetFileName($subdirectory)
                $skip = $false
                foreach ($excluded in @($ExcludeDirs)) { if ([string]::Equals($name, $excluded, [StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break } }
                if ($skip) { continue }
                if (([IO.File]::GetAttributes($subdirectory) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $reparse.Add(($subdirectory.Substring($prefixLength) -replace '\\', '/'))
                    continue
                }
                $pending.Push($subdirectory)
            }
            foreach ($file in [IO.Directory]::GetFiles($directory)) {
                $key = ($file.Substring($prefixLength) -replace '\\', '/')
                if (Test-BRAVODeployPathExcluded -RelativeKey $key -ExcludeFiles $ExcludeFiles -ExcludeDirs $ExcludeDirs) { continue }
                if (([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $reparse.Add($key)
                    continue
                }
                $keys.Add($key)
            }
        }
    }
    return [pscustomobject]@{ Keys = $keys.ToArray(); ReparsePoints = $reparse.ToArray() }
}

function Get-BRAVODeploymentFileSet {
    <#
    .SYNOPSIS
        Файловий набір розгортання (ENGINE_DESIGN 4.1); лише читання.
    .DESCRIPTION
        DeployKeys — усі файли staged-дерева поза site-owned (з SHA-256 в UPPER), а не
        лише ключі manifest: артефакт містить і файли поза integrity-manifest.
        Add/Change/Unchanged — за ФАКТИЧНИМ хешем файлу в runtime (а не за manifest:
        runtime може бути змінений вручну). Remove — ключі СТАРОГО manifest без
        відповідника в staged (доведено manifest-owned). UnknownScripts —
        .ps1/.psm1/.psd1 у runtime поза обома наборами (blocker до mutation: сторонній
        скрипт у комплекті може виконатися від SYSTEM); UnknownOther — інші чужі файли
        (лишаються, Warning). NamespaceViolations — staged-ключ у site-owned просторі.
        ReparsePoints — reparse у staged/runtime. Site-owned — лише
        Get-BRAVOUpdateSiteOwnedPaths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StagedRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [string]$OldManifestPath = ''
    )

    if (-not [IO.Directory]::Exists($StagedRoot)) { throw "BRAVO.Update: staged-каталог не існує: $StagedRoot" }
    $owned = Get-BRAVOUpdateSiteOwnedPaths
    $problems = New-Object 'System.Collections.Generic.List[string]'

    $stagedScan = Get-BRAVOUpdateDeployTreeScan -Root $StagedRoot
    $deployKeys = [ordered]@{}
    $namespaceViolations = New-Object 'System.Collections.Generic.List[string]'
    $stagedKeySet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in @($stagedScan.Keys | Sort-Object)) {
        [void]$stagedKeySet.Add($key)
        if (Test-BRAVODeployPathExcluded -RelativeKey $key -ExcludeFiles $owned.Files -ExcludeDirs $owned.Dirs) { $namespaceViolations.Add($key); continue }
        $deployKeys[$key] = Get-BRAVODeployFileSha256 -Path (Resolve-BRAVODeployTargetPath -Root $StagedRoot -Key $key)
    }

    $oldKeys = @{}
    $oldManifestPresent = $false
    if ((-not [string]::IsNullOrWhiteSpace($OldManifestPath)) -and [IO.File]::Exists($OldManifestPath)) {
        $oldKeys = Get-BRAVODeployManifestHashes -ManifestPath $OldManifestPath
        $oldManifestPresent = $true
    }

    $runtimeScan = Get-BRAVOUpdateDeployTreeScan -Root $RuntimeRoot -ExcludeFiles $owned.Files -ExcludeDirs $owned.Dirs
    $runtimeKeySet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $runtimeScan.Keys) { [void]$runtimeKeySet.Add($key) }

    $add = New-Object 'System.Collections.Generic.List[string]'
    $change = New-Object 'System.Collections.Generic.List[string]'
    $unchanged = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @($deployKeys.Keys)) {
        if (-not $runtimeKeySet.Contains($key)) { $add.Add($key); continue }
        $runtimeHash = $null
        try { $runtimeHash = Get-BRAVODeployFileSha256 -Path (Resolve-BRAVODeployTargetPath -Root $RuntimeRoot -Key $key) } catch { $problems.Add(('не вдалося прочитати runtime-файл ' + $key + ': ' + $_.Exception.Message)) }
        if (($null -ne $runtimeHash) -and ($runtimeHash -ceq [string]$deployKeys[$key])) { $unchanged.Add($key) } else { $change.Add($key) }
    }

    $remove = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @($oldKeys.Keys | Sort-Object)) {
        if (Test-BRAVODeployPathExcluded -RelativeKey $key -ExcludeFiles $owned.Files -ExcludeDirs $owned.Dirs) { continue }
        if ($stagedKeySet.Contains($key)) { continue }
        $remove.Add($key)
    }

    $unknownScripts = New-Object 'System.Collections.Generic.List[string]'
    $unknownOther = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @($runtimeScan.Keys | Sort-Object)) {
        if ($oldKeys.ContainsKey($key) -or $stagedKeySet.Contains($key)) { continue }
        $extension = [IO.Path]::GetExtension($key).ToLowerInvariant()
        if ($script:BRAVOUpdateScriptExtensions -contains $extension) { $unknownScripts.Add($key) } else { $unknownOther.Add($key) }
    }

    $reparsePoints = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in $stagedScan.ReparsePoints) { $reparsePoints.Add('staged:' + $item) }
    foreach ($item in $runtimeScan.ReparsePoints) { $reparsePoints.Add('runtime:' + $item) }
    if ([IO.Directory]::Exists($RuntimeRoot) -and (([IO.File]::GetAttributes($RuntimeRoot.TrimEnd('\', '/')) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { $reparsePoints.Add('runtime:.') }

    return [pscustomobject][ordered]@{
        DeployKeys          = $deployKeys
        Add                 = $add.ToArray()
        Change              = $change.ToArray()
        Unchanged           = $unchanged.ToArray()
        Remove              = $remove.ToArray()
        UnknownScripts      = $unknownScripts.ToArray()
        UnknownOther        = $unknownOther.ToArray()
        NamespaceViolations = $namespaceViolations.ToArray()
        ReparsePoints       = $reparsePoints.ToArray()
        OldManifestPresent  = $oldManifestPresent
        Problems            = $problems.ToArray()
    }
}

function Save-BRAVODeploymentKeySet {
    <#
    .SYNOPSIS
        Зберігає deploy-keys.json у каталозі операції атомарно: { Path, Sha256 }.
    .DESCRIPTION
        Формат: { schemaVersion, deployKeys { ключ: SHA-256 }, remove [ключі] }. Rollback
        (-OwnedKeyList) читає цей файл; SHA-256 файлу фіксується в журналі, щоб
        підміна набору між deploy і rollback була помітною.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$FileSet,
        [Parameter(Mandatory = $true)][string]$OperationDirectory
    )

    $document = [pscustomobject][ordered]@{
        schemaVersion = 1
        deployKeys    = $FileSet.DeployKeys
        remove        = @($FileSet.Remove)
    }
    $path = Join-Path $OperationDirectory 'deploy-keys.json'
    Write-BRAVOUpdateFileAtomic -Path $path -Text (ConvertTo-BRAVOUpdateJson -InputObject $document)
    return [pscustomobject]@{ Path = $path; Sha256 = (Get-BRAVODeployFileSha256 -Path $path) }
}

function Copy-BRAVOUpdateVerifiedFile {
    <#
    .SYNOPSIS
        Копіює файл потоком із SHA-256 «на льоту»; розбіжність із очікуваним хешем —
        виняток (Verification), а файл призначення не змінюється.
    .DESCRIPTION
        Пишемо в тимчасовий файл поруч (WriteThrough), перевіряємо хеш ПОТОКУ,
        що фактично записано, і лише тоді атомарно підміняємо ціль (Replace/Move).
        Так між перевіркою й записом немає вікна TOCTOU: хешується той самий потік,
        і ціль ніколи не містить часткових даних.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    $directory = [IO.Path]::GetDirectoryName($Destination)
    if (-not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }
    $suffix = [guid]::NewGuid().ToString('N')
    $temporaryPath = [IO.Path]::Combine($directory, ('.{0}_{1}.bravo-tmp' -f [IO.Path]::GetFileName($Destination), $suffix))
    $backupPath = [IO.Path]::Combine($directory, ('.{0}_{1}.bravo-old' -f [IO.Path]::GetFileName($Destination), $suffix))
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $sourceStream = $null
    $output = $null
    $bytes = [long]0
    $actual = ''
    $replaced = $false
    try {
        $sourceStream = New-Object System.IO.FileStream($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 81920)
        $output = New-Object System.IO.FileStream($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 81920, [IO.FileOptions]::WriteThrough)
        $buffer = New-Object 'byte[]' 81920
        while (($read = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$hasher.TransformBlock($buffer, 0, $read, $null, 0)
            $output.Write($buffer, 0, $read)
            $bytes += $read
        }
        [void]$hasher.TransformFinalBlock((New-Object 'byte[]' 0), 0, 0)
        $output.Flush($true)
        $actual = ([BitConverter]::ToString($hasher.Hash) -replace '-', '').ToUpperInvariant()
        $output.Dispose()
        $output = $null
        if ($actual -cne $ExpectedSha256.ToUpperInvariant()) {
            throw (New-BRAVOUpdateTypedException -Message ("SHA-256 файлу '$Source' не збігається з очікуваним (очікувано $ExpectedSha256, прочитано $actual).") -Kind Verification -FindingId 'Deploy.HashMismatch' -ExitCodeHint 33 -Action 'Файл комплекту змінено після перевірки; операцію відкочено, отримайте артефакт знову.')
        }
        if ([IO.File]::Exists($Destination)) {
            [IO.File]::Replace($temporaryPath, $Destination, $backupPath)
            $replaced = $true
        } else {
            [IO.File]::Move($temporaryPath, $Destination)
        }
    } finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
        $hasher.Dispose()
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
        if ($replaced -and [IO.File]::Exists($backupPath)) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ Path = $Destination; Sha256 = $actual; Bytes = $bytes }
}

function Invoke-BRAVORuntimeDeploy {
    <#
    .SYNOPSIS
        Розгортає staged-набір у runtime: { Copied[], Removed[], Errors[] }.
    .DESCRIPTION
        Порядок: Add+Change (VERSION.json і RUNTIME_MANIFEST.json ОСТАННІМИ, щоб
        перерваний deploy не лишив «новий manifest при старих файлах»), далі
        Remove[], далі порожні каталоги знизу вгору (корінь і site-owned — ніколи).
        Перед кожним записом перевіряється відсутність reparse point у ланцюгу
        каталогів призначення. Перший збій зупиняє розгортання (Errors не порожній);
        fault Deploy.AfterFileCount = N кидає виняток після N скопійованих файлів.
        ACL не змінюється: повторне hardening робить крок Scheduler (ENGINE_DESIGN F3).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$StagedRoot,
        [Parameter(Mandatory = $true)]$FileSet
    )

    $runtimeRoot = [string]$Context.Paths.RuntimeRoot
    $copied = New-Object 'System.Collections.Generic.List[string]'
    $removed = New-Object 'System.Collections.Generic.List[string]'
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $faultAfter = $null
    if (($null -ne $Context.FaultInjection) -and $Context.FaultInjection.ContainsKey('Deploy.AfterFileCount')) { $faultAfter = [int]$Context.FaultInjection['Deploy.AfterFileCount'] }

    if (-not [IO.Directory]::Exists($runtimeRoot)) { [void][IO.Directory]::CreateDirectory($runtimeRoot) }
    $ordered = New-Object 'System.Collections.Generic.List[string]'
    $last = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @(@($FileSet.Add) + @($FileSet.Change))) {
        if (@('VERSION.json', 'RUNTIME_MANIFEST.json') -contains $key) { $last.Add($key) } else { $ordered.Add($key) }
    }
    foreach ($key in @($last.ToArray() | Sort-Object)) { $ordered.Add($key) }

    foreach ($key in $ordered) {
        try {
            $source = Resolve-BRAVODeployTargetPath -Root $StagedRoot -Key $key
            $destination = Resolve-BRAVODeployTargetPath -Root $runtimeRoot -Key $key
            if (Test-BRAVOUpdatePathHasReparsePoint -Path ([IO.Path]::GetDirectoryName($destination)) -StopAt $runtimeRoot) {
                throw "каталог призначення для '$key' містить reparse point."
            }
            if ([IO.File]::Exists($destination) -and (([IO.File]::GetAttributes($destination) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw "файл призначення '$key' є reparse point."
            }
            [void](Copy-BRAVOUpdateVerifiedFile -Source $source -Destination $destination -ExpectedSha256 ([string]$FileSet.DeployKeys[$key]))
            $copied.Add($key)
        } catch {
            if ((Get-BRAVOUpdateExceptionKind -ErrorRecord $_).Kind -ceq 'Crash') { throw }
            $errors.Add(('копіювання ' + $key + ': ' + $_.Exception.Message))
            break
        }
        if (($null -ne $faultAfter) -and ($copied.Count -ge $faultAfter)) {
            throw (New-BRAVOUpdateTypedException -Message ('BRAVOUpdate.InjectedFault: Deploy.AfterFileCount=' + $faultAfter) -Kind Error)
        }
    }

    if ($errors.Count -eq 0) {
        $directories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($key in @($FileSet.Remove)) {
            try {
                $target = Resolve-BRAVODeployTargetPath -Root $runtimeRoot -Key $key
                if (Test-BRAVOUpdatePathHasReparsePoint -Path ([IO.Path]::GetDirectoryName($target)) -StopAt $runtimeRoot) { throw "каталог '$key' містить reparse point." }
                if ([IO.File]::Exists($target)) {
                    if (([IO.File]::GetAttributes($target) -band [IO.FileAttributes]::ReadOnly) -ne 0) { [IO.File]::SetAttributes($target, [IO.FileAttributes]::Normal) }
                    [IO.File]::Delete($target)
                    $removed.Add($key)
                }
                [void]$directories.Add([IO.Path]::GetDirectoryName($target))
            } catch {
                $errors.Add(('видалення ' + $key + ': ' + $_.Exception.Message))
                break
            }
        }
        if ($errors.Count -eq 0) {
            $rootFull = $runtimeRoot.TrimEnd('\', '/')
            $candidates = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($directory in $directories) {
                $walker = $directory
                while ((-not [string]::IsNullOrEmpty($walker)) -and ($walker.Length -gt $rootFull.Length) -and $walker.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    [void]$candidates.Add($walker)
                    $walker = [IO.Path]::GetDirectoryName($walker)
                }
            }
            foreach ($candidate in @($candidates | Sort-Object -Property Length -Descending)) {
                try {
                    if ([IO.Directory]::Exists($candidate) -and ([IO.Directory]::GetFileSystemEntries($candidate).Length -eq 0)) { [IO.Directory]::Delete($candidate, $false) }
                } catch {
                    $errors.Add(('видалення порожнього каталогу ' + $candidate + ': ' + $_.Exception.Message))
                    break
                }
            }
        }
    }
    return [pscustomobject]@{ Copied = $copied.ToArray(); Removed = $removed.ToArray(); Errors = $errors.ToArray() }
}

# ---------------------------------------------------------------------------
# Кроки orchestrator-а (повторно використовуються Install/Repair)
# ---------------------------------------------------------------------------

function Test-BRAVOUpdatePlanStillCurrent {
    <#
    .SYNOPSIS
        Повторна перевірка актуальності плану (U7) ПІСЛЯ створення власного Open-журналу.
    .DESCRIPTION
        Fingerprint плану включає перелік відкритих журналів; після U4 у ньому є
        журнал самої операції, тож Test-BRAVODeploymentPlanCurrent дав би хибне
        «прострочено». Тут передумови рахуються тими самими функціями Plan, але
        власний operationId виключається з переліку відкритих журналів. Чужі Open/
        пошкоджені журнали лишаються і ламають fingerprint, як і має бути.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    $problems = New-Object 'System.Collections.Generic.List[string]'
    $plan = $Context.Plan
    try {
        $source = Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'source'
        $nowUtc = Get-BRAVOUpdatePlanNow -Adapter $Context.Adapter
        $expires = [datetime]::Parse([string](Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'expiresUtc'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if ($nowUtc -gt $expires) { $problems.Add('Термін дії плану минув під час виконання.') }
        $artifact = [string](Get-BRAVOUpdatePropertyValue -InputObject $source -Name 'artifactSha256' -Default '')
        $manifest = [string](Get-BRAVOUpdatePropertyValue -InputObject $source -Name 'manifestSha256' -Default '')
        $preconditions = Get-BRAVODeploymentPreconditions -RuntimeRoot $Context.Paths.RuntimeRoot -StateRoot $Context.Paths.StateRoot `
            -ArtifactSha256 $artifact -ManifestSha256 $manifest -Adapter $Context.Adapter
        $own = [string]$Context.OperationId
        $preconditions.openJournalIds = @(@($preconditions.openJournalIds) | Where-Object { [string]$_ -cne $own })
        $current = Get-BRAVOUpdatePreconditionsFingerprint -Preconditions $preconditions
        if ($current -cne ([string](Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'preconditionsFingerprint' -Default '')).ToUpperInvariant()) {
            $problems.Add('Передумови змінилися після підтвердження плану (конфігурація, задачі, версія, артефакт або журнал).')
        }
    } catch {
        $problems.Add('Не вдалося перевірити актуальність плану: ' + $_.Exception.Message)
    }
    return [pscustomobject]@{ IsCurrent = ($problems.Count -eq 0); Problems = $problems.ToArray() }
}

function Close-BRAVOUpdateOperationHandles {
    # Звільняє lock-и в порядку operation -> lifecycle; безпечно повторювати.
    [CmdletBinding()]
    param([AllowNull()]$Context)

    if ($null -eq $Context) { return }
    $operationLock = $Context.Handles.OperationLock
    $lifecycleLock = $Context.Handles.LifecycleLock
    $Context.Handles.OperationLock = $null
    $Context.Handles.LifecycleLock = $null
    if ($null -ne $operationLock) { Exit-BRAVOUpdateOperationLock -Lock $operationLock }
    if ($null -ne $lifecycleLock) { Exit-BRAVOUpdateLifecycleLock -Lock $lifecycleLock }
}

function New-BRAVOUpdateOperationResult {
    <#
    .SYNOPSIS
        DeploymentResult для операції через контрактний конструктор; план може бути
        пошкодженим (ранні відмови), тому поля плану читаються безпечно.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Plan = $null,
        [AllowNull()]$Context = $null,
        [Parameter(Mandatory = $true)][ValidateSet('Success', 'SuccessWithWarnings', 'Failed', 'RolledBack', 'Critical')][string]$Status,
        [ValidateSet('', 'Blocked', 'Cancelled', 'PlanStale', 'VerificationFailed', 'Error')][string]$ReasonCode = '',
        [object[]]$Findings = @(),
        [object[]]$Validation = @(),
        $Rollback = $null,
        $TaskActivation = $null,
        [AllowNull()]$InstalledVersion = $null,
        [AllowNull()][string]$LastPhase = $null,
        [bool]$MutationStarted = $false,
        [AllowNull()][string]$JournalPath = $null,
        [string]$StartedUtc = ''
    )

    $operationId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'operationId' -Default '')
    if ($null -ne $Context) { $operationId = [string]$Context.OperationId }
    if (-not (Test-BRAVOUpdateGuidText -Value $operationId)) { $operationId = [guid]::NewGuid().ToString() }
    $planId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'planId' -Default '')
    if (-not (Test-BRAVOUpdateGuidText -Value $planId)) { $planId = '' }
    $action = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'action' -Default '')
    if (@('Install', 'Update', 'Repair') -cnotcontains $action) { $action = 'Update' }
    $logPath = $null
    if ($null -ne $Context) { $logPath = Join-Path $Context.OperationDirectory 'logs' }
    $parameters = @{
        OperationId      = $operationId
        PlanId           = $planId
        Action           = $action
        Status           = $Status
        ReasonCode       = $ReasonCode
        SourceVersion    = (Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'currentVersion')
        TargetVersion    = (Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'targetVersion')
        InstalledVersion = $InstalledVersion
        LastPhase        = $LastPhase
        MutationStarted  = $MutationStarted
        Validation       = @($Validation)
        Findings         = @($Findings)
        LogPath          = $logPath
        JournalPath      = $JournalPath
    }
    if ($null -ne $Rollback) { $parameters['Rollback'] = $Rollback }
    if ($null -ne $TaskActivation) { $parameters['TaskActivation'] = $TaskActivation }
    if (-not [string]::IsNullOrWhiteSpace($StartedUtc)) { $parameters['StartedUtc'] = $StartedUtc }
    return (New-BRAVOUpdateDeploymentResult @parameters)
}

function Open-BRAVOUpdateOperation {
    <#
    .SYNOPSIS
        Кроки U0-U4: структура/актуальність плану, lifecycle lock, відсутність Open-
        журналів, одноразовість плану, каталог операції і Open-журнал, контекст.
    .DESCRIPTION
        Повертає { Context, EarlyResult }: при ранній відмові EarlyResult — готовий
        DeploymentResult (lock уже звільнено, нічого не змінено, крім реєстру
        споживання плану у випадку відмови після U3). Інакше Context тримає lifecycle
        lock у Handles — викликач зобов'язаний звільнити його у finally
        (Close-BRAVOUpdateOperationHandles). Підходить і для Install.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        [Parameter(Mandatory = $true)]$Paths,
        [hashtable]$FaultInjection = $null
    )

    $startedUtc = Get-BRAVOUpdateUtcNowText
    $fail = {
        param([string]$Reason, $Finding)
        return [pscustomobject]@{ Context = $null; EarlyResult = (New-BRAVOUpdateOperationResult -Plan $Plan -Status Failed -ReasonCode $Reason -Findings @($Finding) -StartedUtc $startedUtc) }
    }

    # --- U0: структура плану, змінна середовища, актуальність ---
    $planCheck = Test-BRAVOUpdateDeploymentPlan -InputObject $Plan
    if (-not $planCheck.IsValid) {
        return (& $fail 'Blocked' (New-BRAVOUpdateFinding -Id 'Plan.Invalid' -Severity Blocker -Title 'План розгортання не відповідає контракту' `
                    -Meaning 'Виконувати можна лише валідний план.' -Action 'Побудуйте новий план і підтвердіть його.' -Details ($planCheck.Problems -join '; ')))
    }
    foreach ($pair in @(@('stagingRoot', 'StagingRoot'), @('backupRoot', 'BackupRoot'))) {
        $planValue = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name $pair[0])
        $actualValue = [string](Get-BRAVOUpdatePropertyValue -InputObject $Paths -Name $pair[1])
        if (-not [string]::Equals((Get-BRAVOUpdateFullPath -Path $planValue), (Get-BRAVOUpdateFullPath -Path $actualValue), [StringComparison]::OrdinalIgnoreCase)) {
            return (& $fail 'Blocked' (New-BRAVOUpdateFinding -Id 'Plan.RootMismatch' -Severity Blocker -Title 'Корені плану не збігаються з коренями виконання' `
                        -Meaning 'План підтверджено для інших каталогів; виконання відхилено.' -Action 'Побудуйте новий план для поточних каталогів.' -Details ($pair[0] + ': план ' + $planValue + ', виконання ' + $actualValue)))
        }
    }
    $current = Test-BRAVODeploymentPlanCurrent -Plan $Plan -RuntimeRoot $Paths.RuntimeRoot -StateRoot $Paths.StateRoot -Adapter $Adapter
    if (-not $current.IsCurrent) {
        return (& $fail 'PlanStale' (New-BRAVOUpdateFinding -Id 'Plan.Stale' -Severity Blocker -Title 'План застарів' `
                    -Meaning 'Стан сервера змінився після підтвердження плану, або термін дії плану минув.' -Action 'Виконайте preflight і побудуйте новий план.' -Details ($current.Problems -join '; ')))
    }

    # --- U1: lifecycle lock ---
    $operationId = [string]$Plan.operationId
    $lifecycle = Enter-BRAVOUpdateLifecycleLock -LockRoot $Paths.LockRoot -OperationId $operationId
    if (-not $lifecycle.Success) {
        return (& $fail 'Blocked' (New-BRAVOUpdateFinding -Id 'Lock.LifecycleBusy' -Severity Blocker -Title 'Інша операція оновлення вже виконується' `
                    -Meaning 'Одночасно може працювати лише одна операція життєвого циклу.' -Action 'Дочекайтеся завершення іншої операції; процеси не завершуйте примусово.' -Details ([string]$lifecycle.Error) -ExitCodeHint 20))
    }
    try {
        # --- U2: відкриті журнали ---
        $openJournals = @(Get-BRAVOUpdateOpenJournal -StateRoot $Paths.StateRoot)
        if ($openJournals.Count -gt 0) {
            Exit-BRAVOUpdateLifecycleLock -Lock $lifecycle
            $details = (@($openJournals | ForEach-Object { [string]$_.OperationId })) -join ', '
            return (& $fail 'Blocked' (New-BRAVOUpdateFinding -Id 'Journal.RecoveryRequired' -Severity Blocker -Title 'Є незавершена операція: потрібне відновлення' `
                        -Meaning 'Нові операції заблоковано, доки попередню не відновлено.' -Action 'Запустіть відновлення (Recover) і лише потім нову операцію.' -Details $details))
        }

        # --- U3: одноразовість плану ---
        $planId = [string]$Plan.planId
        $consumedDirectory = Join-Path $Paths.StateRoot 'ConsumedPlans'
        [void][IO.Directory]::CreateDirectory($consumedDirectory)
        $consumedPath = Join-Path $consumedDirectory $planId
        $consumed = $false
        $stream = $null
        try {
            $stream = New-Object System.IO.FileStream($consumedPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
            $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-BRAVOUpdateJson -InputObject ([pscustomobject]@{ planId = $planId; operationId = $operationId; consumedUtc = (Get-BRAVOUpdateUtcNowText) })))
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            $consumed = $true
        } catch [System.IO.IOException] {
            if (-not [IO.File]::Exists($consumedPath)) { throw }
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
        if (-not $consumed) {
            Exit-BRAVOUpdateLifecycleLock -Lock $lifecycle
            return (& $fail 'PlanStale' (New-BRAVOUpdateFinding -Id 'Plan.AlreadyConsumed' -Severity Blocker -Title 'План уже використано' `
                        -Meaning 'Кожен підтверджений план виконується не більше одного разу (захист від повторного запуску запиту).' -Action 'Побудуйте новий план і підтвердіть його.' -Details ('planId=' + $planId)))
        }

        # --- U4: каталог операції, журнал, контекст ---
        $operationDirectory = Join-Path (Join-Path $Paths.StateRoot 'Operations') $operationId
        if ([IO.Directory]::Exists($operationDirectory)) {
            # Worker міг заздалегідь створити каталог лише з request.json і control\; будь-що інше = Blocked.
            $foreign = @([IO.Directory]::GetFileSystemEntries($operationDirectory) | Where-Object { @('request.json', 'control') -cnotcontains [IO.Path]::GetFileName($_) })
            if ($foreign.Count -gt 0) {
                Exit-BRAVOUpdateLifecycleLock -Lock $lifecycle
                return (& $fail 'Blocked' (New-BRAVOUpdateFinding -Id 'Operation.DirectoryNotClean' -Severity Blocker -Title 'Каталог операції вже містить сторонні файли' `
                            -Meaning 'Очікувалися лише request.json і control; стан каталогу не довірений.' -Action 'Побудуйте новий план (новий operationId).' -Details (($foreign | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ', ')))
            }
        }
        [void][IO.Directory]::CreateDirectory($operationDirectory)
        if (([IO.File]::GetAttributes($operationDirectory) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "BRAVO.Update: каталог операції є reparse point: $operationDirectory" }
        [void][IO.Directory]::CreateDirectory((Join-Path $operationDirectory 'control'))
        [void][IO.Directory]::CreateDirectory((Join-Path $operationDirectory 'logs'))
        $journal = New-BRAVOUpdateJournal -StateRoot $Paths.StateRoot -Plan $Plan -RuntimeRoot $Paths.RuntimeRoot -StagingRoot $Paths.StagingRoot -BackupRoot $Paths.BackupRoot
        $context = New-BRAVOUpdateOperationContext -Plan $Plan -Adapter $Adapter -Paths $Paths -OperationDirectory $operationDirectory -Journal $journal -FaultInjection $FaultInjection
        $context.Handles.LifecycleLock = $lifecycle
        return [pscustomobject]@{ Context = $context; EarlyResult = $null }
    } catch {
        Exit-BRAVOUpdateLifecycleLock -Lock $lifecycle
        throw
    }
}

function Invoke-BRAVOUpdateAcquireStage {
    <#
    .SYNOPSIS
        Кроки U5-U6: Acquire -> Verify -> Stage проти plan.source.*Sha256, staged-
        валідація, файловий набір і deploy-keys.json. Повертає { StagedRoot, FileSet, KeySet }.
    .DESCRIPTION
        Усе до межі mutation: збій = Failed без змін runtime. Verify виконує
        Test-BRAVOReleaseArtifact (з StatePath версій) і звіряє SHA-256 архіва та
        release-manifest із планом. Для Repair ідентичність staged і встановленої
        збірки перевіряє Test-BRAVORepairIdentity (частина Repair); IsMatch=$false —
        Failed/Blocked до mutation. Unknown scripts, namespace violations і reparse
        points — blocker-и (Blocked).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string]$SourcePath = '',
        [string]$ChecksumPath = '',
        [string]$ManifestPath = '',
        [scriptblock]$Downloader = $null,
        [string]$RepositoryBaseUri = ''
    )

    $stagingDir = Join-Path $Context.Paths.StagingRoot $Context.OperationId
    $payloadDir = Join-Path $stagingDir 'payload'
    $stagedDir = Join-Path $stagingDir 'runtime'
    $Context.Data['StagingDirectory'] = $stagingDir

    [void](Invoke-BRAVOUpdatePhase -Context $Context -Phase 'Acquire' -ProgressPhase Acquire -Percent 5 -Action {
            param($Context)
            $created = New-BRAVOUpdatePrivateDirectory -Path $stagingDir
            if (-not $created.Success) { throw (New-BRAVOUpdateTypedException -Message ('Не вдалося створити приватний каталог staging: ' + ($created.Problems -join '; ')) -Kind Error -FindingId 'Stage.DirectoryFailed' -Action 'Перевірте каталог staging і права доступу.') }
            $payloadCreated = New-BRAVOUpdatePrivateDirectory -Path $payloadDir
            if (-not $payloadCreated.Success) { throw (New-BRAVOUpdateTypedException -Message ('Не вдалося створити каталог payload: ' + ($payloadCreated.Problems -join '; ')) -Kind Error -FindingId 'Stage.DirectoryFailed' -Action 'Перевірте каталог staging і права доступу.') }
            $acquired = $null
            if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
                $acquired = Get-BRAVOOfflineReleaseSource -ZipPath $SourcePath -ChecksumPath $ChecksumPath -ManifestPath $ManifestPath -DestinationRoot $payloadDir
            } else {
                $tag = [string](Get-BRAVOUpdatePropertyValue -InputObject (Get-BRAVOUpdatePropertyValue -InputObject $Context.Plan -Name 'source') -Name 'tag' -Default '')
                $candidateArgs = @{ Tag = $tag }
                if (-not [string]::IsNullOrWhiteSpace($RepositoryBaseUri)) { $candidateArgs['RepositoryBaseUri'] = $RepositoryBaseUri }
                $candidate = Get-BRAVOReleaseCandidate @candidateArgs
                $saveArgs = @{ Candidate = $candidate; DestinationRoot = $payloadDir }
                if ($null -ne $Downloader) { $saveArgs['Downloader'] = $Downloader }
                $acquired = Save-BRAVOReleaseArtifact @saveArgs
            }
            if ((-not $acquired.Success) -and (@(@($acquired.Problems) | Where-Object { ([string]$_) -match '^Не знайдено release-manifest\.json' }).Count -gt 0)) {
                # Відсутній release-manifest — це збій перевірки артефакта (як у конвеєрі плану: 42), а не транспортний збій.
                throw (New-BRAVOUpdateTypedException -Message ('Відсутній release-manifest.json: ' + (@($acquired.Problems) -join '; ')) -Kind Verification -FindingId 'Release.ManifestMissing' -ExitCodeHint 42 -Action 'Отримайте повний артефакт (архів, .sha256, release-manifest.json) з довіреного джерела.')
            }
            if (-not $acquired.Success) { throw (New-BRAVOUpdateTypedException -Message ('Не вдалося отримати артефакт: ' + (@($acquired.Problems) -join '; ')) -Kind Error -FindingId 'Acquire.Failed' -Action 'Перевірте джерело артефакта і повторіть.') }
            $Context.Data['Payload'] = $acquired
        })

    [void](Invoke-BRAVOUpdatePhase -Context $Context -Phase 'Verify' -ProgressPhase Verify -Percent 15 -Action {
            param($Context)
            $source = Get-BRAVOUpdatePropertyValue -InputObject $Context.Plan -Name 'source'
            $payload = $Context.Data['Payload']
            $verifyArgs = @{
                ZipPath      = [string]$payload.ZipPath
                ChecksumPath = [string]$payload.ChecksumPath
                ManifestPath = [string]$payload.ManifestPath
                ExpectedTag  = [string](Get-BRAVOUpdatePropertyValue -InputObject $source -Name 'tag' -Default '')
                StatePath    = [string]$Context.Paths.VersionStatePath
            }
            if ((Get-BRAVOUpdatePropertyValue -InputObject $source -Name 'prereleaseAuthorized' -Default $false) -eq $true) { $verifyArgs['AllowPrerelease'] = $true }
            $verification = Test-BRAVOReleaseArtifact @verifyArgs
            $firstBlocker = $null
            foreach ($finding in (Get-BRAVOUpdateArrayProperty -InputObject $verification -Name 'Findings')) {
                if ($finding.severity -ceq 'Blocker') { if ($null -eq $firstBlocker) { $firstBlocker = $finding }; $Context.Findings.Add($finding) }
                elseif ($finding.severity -ceq 'Warning') { $Context.Findings.Add($finding) }
            }
            if ((-not $verification.IsValid) -or ($null -ne $firstBlocker)) {
                $hint = $null; if ($null -ne $firstBlocker) { $hint = $firstBlocker.exitCodeHint }
                $text = 'Артефакт не пройшов перевірку.'; if ($null -ne $firstBlocker) { $text = [string]$firstBlocker.title }
                throw (New-BRAVOUpdateTypedException -Message $text -Kind Verification -FindingId 'Release.VerifyFailed' -ExitCodeHint $hint -Action 'Отримайте артефакт знову з довіреного джерела.')
            }
            foreach ($pair in @(@('artifactSha256', [string]$verification.ArtifactSha256), @('manifestSha256', [string]$verification.ManifestSha256))) {
                $planned = [string](Get-BRAVOUpdatePropertyValue -InputObject $source -Name $pair[0] -Default '')
                if (([string]::IsNullOrWhiteSpace($planned)) -or (-not [string]::Equals($planned, $pair[1], [StringComparison]::OrdinalIgnoreCase))) {
                    throw (New-BRAVOUpdateTypedException -Message ('Хеш ' + $pair[0] + ' артефакта не збігається з планом.') -Kind Verification -FindingId 'Release.PlanHashMismatch' -ExitCodeHint 42 -Action 'Артефакт відрізняється від підтвердженого; побудуйте новий план.')
                }
            }
            $Context.Data['Verification'] = $verification
        })

    [void](Invoke-BRAVOUpdatePhase -Context $Context -Phase 'Stage' -ProgressPhase Stage -Percent 25 -Action {
            param($Context)
            $stagedCreated = New-BRAVOUpdatePrivateDirectory -Path $stagedDir
            if (-not $stagedCreated.Success) { throw (New-BRAVOUpdateTypedException -Message ('Не вдалося створити каталог розпакування: ' + ($stagedCreated.Problems -join '; ')) -Kind Error -FindingId 'Stage.DirectoryFailed' -Action 'Перевірте каталог staging і права доступу.') }
            $source = Get-BRAVOUpdatePropertyValue -InputObject $Context.Plan -Name 'source'
            $expanded = Expand-BRAVOUpdateArchiveSafe -ZipPath ([string]$Context.Data['Payload'].ZipPath) -DestinationRoot $stagedDir -ExpectedSha256 ([string](Get-BRAVOUpdatePropertyValue -InputObject $source -Name 'artifactSha256' -Default ''))
            if (-not $expanded.Success) { throw (New-BRAVOUpdateTypedException -Message ('Розпакування артефакта не вдалося: ' + (@($expanded.Problems) -join '; ')) -Kind Verification -FindingId 'Stage.ExtractFailed' -ExitCodeHint 42 -Action 'Отримайте артефакт знову.') }
            $Context.Data['StagedRoot'] = $stagedDir
        })

    [void](Invoke-BRAVOUpdatePhase -Context $Context -Phase 'StageValidation' -ProgressPhase Stage -Percent 35 -Action {
            param($Context)
            $targetVersion = [string](Get-BRAVOUpdatePropertyValue -InputObject $Context.Plan -Name 'targetVersion' -Default '')
            $stagedCheck = Test-BRAVOStagedRuntime -StagedRoot $stagedDir -ExpectedVersion $targetVersion
            $firstBlocker = $null
            foreach ($finding in (Get-BRAVOUpdateArrayProperty -InputObject $stagedCheck -Name 'Findings')) {
                if ($finding.severity -ceq 'Blocker') { if ($null -eq $firstBlocker) { $firstBlocker = $finding }; $Context.Findings.Add($finding) }
            }
            if ((-not $stagedCheck.IsValid) -or ($null -ne $firstBlocker)) {
                $hint = $null; if ($null -ne $firstBlocker) { $hint = $firstBlocker.exitCodeHint }
                $text = 'Staged-комплект не пройшов перевірку.'; if ($null -ne $firstBlocker) { $text = [string]$firstBlocker.title }
                throw (New-BRAVOUpdateTypedException -Message $text -Kind Verification -FindingId 'Staged.Invalid' -ExitCodeHint $hint -Action 'Отримайте й розпакуйте артефакт знову.')
            }
            if ($Context.Action -ceq 'Repair') {
                $identity = Test-BRAVORepairIdentity -InstalledRuntimeRoot $Context.Paths.RuntimeRoot -StagedRoot $stagedDir
                if (-not $identity.IsMatch) {
                    foreach ($identityFinding in @(Get-BRAVOUpdateArrayProperty -InputObject $identity -Name 'Findings')) { $Context.Findings.Add($identityFinding) }
                    throw (New-BRAVOUpdateTypedException -Message 'Збірка пакета не збігається зі встановленою (repair).' -Kind Blocked -FindingId 'Repair.VersionMismatch')
                }
            }
            $fileSet = Get-BRAVODeploymentFileSet -StagedRoot $stagedDir -RuntimeRoot $Context.Paths.RuntimeRoot -OldManifestPath (Join-Path $Context.Paths.RuntimeRoot 'RUNTIME_MANIFEST.json')
            $blocked = $false
            if (@($fileSet.UnknownScripts).Count -gt 0) {
                $blocked = $true
                $Context.Findings.Add((New-BRAVOUpdateFinding -Id 'Deploy.UnknownScript' -Severity Blocker -Title 'У каталозі встановлення є сторонні скрипти' `
                            -Meaning 'Скрипти поза manifest можуть виконатися від SYSTEM; оновлення не продовжується.' -Action 'Перевірте й приберіть або перенесіть ці файли, потім повторіть.' `
                            -Details ((@($fileSet.UnknownScripts) | Select-Object -First 20) -join '; ')))
            }
            if (@($fileSet.NamespaceViolations).Count -gt 0) {
                $blocked = $true
                $Context.Findings.Add((New-BRAVOUpdateFinding -Id 'Deploy.NamespaceViolation' -Severity Blocker -Title 'Пакет містить файли простору сервера' `
                            -Meaning 'Артефакт не має права постачати конфігурацію чи дані сервера.' -Action 'Отримайте артефакт із довіреного джерела.' `
                            -Details ((@($fileSet.NamespaceViolations) | Select-Object -First 20) -join '; ')))
            }
            if (@($fileSet.ReparsePoints).Count -gt 0) {
                $blocked = $true
                $Context.Findings.Add((New-BRAVOUpdateFinding -Id 'Deploy.ReparsePoint' -Severity Blocker -Title 'У дереві є символічні посилання або junction' `
                            -Meaning 'Через посилання запис міг би вийти за межі каталогу встановлення.' -Action 'Приберіть посилання з каталогу встановлення або пакета.' `
                            -Details ((@($fileSet.ReparsePoints) | Select-Object -First 20) -join '; ')))
            }
            if ($blocked) { throw (New-BRAVOUpdateTypedException -Message 'Файловий набір розгортання містить blocker-и.' -Kind Blocked -FindingId 'Deploy.FileSetBlocked') }
            if (@($fileSet.UnknownOther).Count -gt 0) {
                $Context.Findings.Add((New-BRAVOUpdateFinding -Id 'Deploy.UnknownFiles' -Severity Warning -Title 'У каталозі встановлення є сторонні файли' `
                            -Meaning 'Файли не належать комплекту й лишаються без змін.' -Details ((@($fileSet.UnknownOther) | Select-Object -First 20) -join '; ')))
            }
            $keySet = Save-BRAVODeploymentKeySet -FileSet $fileSet -OperationDirectory $Context.OperationDirectory
            [void](Set-BRAVOUpdateJournalField -Journal $Context.Journal -StateRoot $Context.Paths.StateRoot -Name 'deployKeys' -Value ([pscustomobject][ordered]@{ path = $keySet.Path; sha256 = $keySet.Sha256 }))
            $Context.Data['FileSet'] = $fileSet
            $Context.Data['KeySet'] = $keySet
        })

    return [pscustomobject]@{ StagedRoot = $stagedDir; FileSet = $Context.Data['FileSet']; KeySet = $Context.Data['KeySet'] }
}

function Invoke-BRAVOUpdatePlanRecheck {
    # U7: повторна перевірка плану після staging; PlanStale до межі mutation.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    [void](Invoke-BRAVOUpdatePhase -Context $Context -Phase 'PlanRecheck' -ProgressPhase Verify -Percent 40 -Action {
            param($Context)
            $check = Test-BRAVOUpdatePlanStillCurrent -Context $Context
            if (-not $check.IsCurrent) {
                $Context.Findings.Add((New-BRAVOUpdateFinding -Id 'Plan.Stale' -Severity Blocker -Title 'План застарів під час підготовки' `
                            -Meaning 'Стан сервера змінився після підтвердження плану.' -Action 'Виконайте preflight і побудуйте новий план.' -Details ($check.Problems -join '; ')))
                throw (New-BRAVOUpdateTypedException -Message 'План застарів під час підготовки.' -Kind PlanStale -FindingId 'Plan.Stale')
            }
        })
}

function Invoke-BRAVOUpdateEnterOperationLock {
    <#
    .SYNOPSIS
        U9: канонічний BRAVO_OPERATION.lock і повторна перевірка, що керовані задачі
        не виконуються. ДО межі mutation навмисно: інакше зайнятий lock давав би
        фіктивний RolledBack.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    [void](Invoke-BRAVOUpdatePhase -Context $Context -Phase 'OperationLock' -ProgressPhase Backup -Percent 55 -Action {
            param($Context)
            $packageVersion = [string](Get-BRAVOUpdatePropertyValue -InputObject $Context.Plan -Name 'targetVersion' -Default '')
            $lock = Enter-BRAVOUpdateOperationLock -OperationLockPath $Context.Paths.OperationLockPath -OperationId $Context.OperationId -PackageVersion $packageVersion
            if (-not $lock.Success) {
                throw (New-BRAVOUpdateTypedException -Message ('Операційний lock зайнятий: ' + [string]$lock.Error) -Kind Blocked -FindingId 'Lock.OperationBusy' -ExitCodeHint 20 -Action 'Дочекайтеся завершення Archive/Maintenance; процеси не завершуйте примусово.')
            }
            $Context.Handles.OperationLock = $lock
            if (-not $Context.Adapter.ContainsKey('GetManagedTasks') -or $null -eq $Context.Adapter['GetManagedTasks']) {
                throw (New-BRAVOUpdateTypedException -Message 'Стан керованих задач недоступний (adapter без GetManagedTasks).' -Kind Blocked -FindingId 'Scheduler.TasksUnknown' -Action 'Перевірте доступ до Task Scheduler.')
            }
            $tasks = @(& $Context.Adapter['GetManagedTasks'] '' ([string]$Context.Paths.RuntimeRoot))
            foreach ($task in $tasks) {
                if ($null -eq $task) { continue }
                $state = [string](Get-BRAVOUpdatePropertyValue -InputObject $task -Name 'State' -Default '')
                if ($state -match '^(Running|4)$') {
                    throw (New-BRAVOUpdateTypedException -Message ('Керована задача виконується: ' + [string](Get-BRAVOUpdatePropertyValue -InputObject $task -Name 'Name' -Default '')) -Kind Blocked -FindingId 'Scheduler.TaskRunning' -ExitCodeHint 20 -Action 'Дочекайтеся завершення задачі й повторіть.')
                }
            }
        })
}

function Invoke-BRAVOUpdateCaptureBaseline {
    <#
    .SYNOPSIS
        U10: знімки стану ДО змін — конфігурація сайту, scheduler, version-state,
        код guard. Знімки пишуть у каталог операції та в журнал (baseline).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    [void](Invoke-BRAVOUpdatePhase -Context $Context -Phase 'Baseline' -ProgressPhase Backup -Percent 60 -Action {
            param($Context)
            $siteBaseline = Get-BRAVOSiteConfigurationBaseline -RuntimeRoot $Context.Paths.RuntimeRoot
            $schedulerSnapshot = Get-BRAVOSchedulerSnapshot -Adapter $Context.Adapter -RuntimeRoot $Context.Paths.RuntimeRoot
            [void](Save-BRAVOSchedulerSnapshot -Snapshot $schedulerSnapshot -OperationDirectory $Context.OperationDirectory -Journal $Context.Journal -StateRoot $Context.Paths.StateRoot)
            $versionSnapshot = Get-BRAVOVersionStateSnapshot -VersionStatePath $Context.Paths.VersionStatePath -OperationDirectory $Context.OperationDirectory
            $guardExitCode = $null
            if ($Context.Adapter.ContainsKey('InvokeGuard') -and $null -ne $Context.Adapter['InvokeGuard']) {
                try {
                    $guard = & $Context.Adapter['InvokeGuard'] $Context.Paths.RuntimeRoot
                    $guardExitCode = Get-BRAVOUpdatePropertyValue -InputObject $guard -Name 'ExitCode'
                } catch {
                    if ((Get-BRAVOUpdateExceptionKind -ErrorRecord $_).Kind -ceq 'Crash') { throw }
                    $guardExitCode = $null
                }
            }
            $Context.Data['SiteBaseline'] = $siteBaseline
            $Context.Data['SchedulerSnapshot'] = $schedulerSnapshot
            $Context.Data['VersionStateSnapshot'] = $versionSnapshot
            $Context.Data['GuardBaselineExitCode'] = $guardExitCode
            [void](Set-BRAVOUpdateJournalField -Journal $Context.Journal -StateRoot $Context.Paths.StateRoot -Name 'versionState' -Value ([pscustomobject][ordered]@{
                        present         = (Get-BRAVOUpdatePropertyValue -InputObject $versionSnapshot -Name 'present')
                        sha256          = (Get-BRAVOUpdatePropertyValue -InputObject $versionSnapshot -Name 'sha256')
                        recordedVersion = (Get-BRAVOUpdatePropertyValue -InputObject $versionSnapshot -Name 'recordedVersion')
                        snapshotPath    = (Get-BRAVOUpdatePropertyValue -InputObject $versionSnapshot -Name 'snapshotPath')
                    }))
            $baseline = [pscustomobject][ordered]@{ siteConfig = $siteBaseline; guardExitCode = $guardExitCode }
            [void](Set-BRAVOUpdateJournalField -Journal $Context.Journal -StateRoot $Context.Paths.StateRoot -Name 'baseline' -Value $baseline)
        })
}

function Start-BRAVOUpdateMutation {
    <#
    .SYNOPSIS
        U11: MUTATION BOUNDARY. mutationStarted пишеться в журнал ДО першої зміни
        runtime; прапорець у контексті ставиться ще раніше (консервативно: збій
        запису журналу після цього веде до відкату непорушеного runtime — безпечно).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    [void](Invoke-BRAVOUpdatePhase -Context $Context -Phase 'MutationBoundary' -ProgressPhase Deploy -Percent 62 -Action {
            param($Context)
            $Context.MutationStarted = $true
            [void](Set-BRAVOUpdateJournalMutationStarted -Journal $Context.Journal -StateRoot $Context.Paths.StateRoot)
        })
}

function Invoke-BRAVOUpdatePreMutationCleanup {
    # Збій до межі: журнал Abandoned, staging і backup цієї операції видаляються.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    try {
        [void](Set-BRAVOUpdateJournalState -Journal $Context.Journal -State Abandoned -StateRoot $Context.Paths.StateRoot)
    } catch {
        $Context.Findings.Add((New-BRAVOUpdateFinding -Id 'Cleanup.JournalNotClosed' -Severity Warning -Title 'Не вдалося закрити журнал операції' `
                    -Meaning 'Журнал лишився відкритим; наступна операція вимагатиме відновлення (воно безпечне: змін не було).' -Details ([string]$_.Exception.Message)))
    }
    foreach ($pair in @(@($Context.Paths.StagingRoot, 'staging'), @($Context.Paths.BackupRoot, 'backup'))) {
        try {
            $removal = Remove-BRAVOUpdateOperationDirectory -Path (Join-Path $pair[0] $Context.OperationId) -ExpectedParent $pair[0] -OperationId $Context.OperationId -AllowedRoot @([string]$Context.Paths.StagingRoot, [string]$Context.Paths.BackupRoot)
            if (@($removal.Problems).Count -gt 0) {
                $Context.Findings.Add((New-BRAVOUpdateFinding -Id ('Cleanup.' + $pair[1] + 'Incomplete') -Severity Warning -Title ('Каталог ' + $pair[1] + ' операції видалено не повністю') `
                            -Meaning 'Залишки можна видалити вручну після перевірки.' -Details ((@($removal.Problems) | Select-Object -First 5) -join '; ')))
            }
        } catch {
            $Context.Findings.Add((New-BRAVOUpdateFinding -Id ('Cleanup.' + $pair[1] + 'Failed') -Severity Warning -Title ('Не вдалося прибрати каталог ' + $pair[1] + ' операції') `
                        -Meaning 'Залишки можна видалити вручну після перевірки.' -Details ([string]$_.Exception.Message)))
        }
    }
}

function Resolve-BRAVOUpdateOperationFailure {
    <#
    .SYNOPSIS
        Перетворює збій фази на DeploymentResult. Crash не перехоплюється (повторно
        кидається). До межі mutation — Abandoned + прибирання; після — Invoke-BRAVORollback.
    .DESCRIPTION
        Збій самого rollback (виняток) -> best-effort Disable-BRAVOAllManagedTasks,
        журнал Critical, результат Critical. Причина додається у findings, якщо серед
        них ще немає blocker-а.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$ErrorRecord,
        [string]$StartedUtc = ''
    )

    $info = Get-BRAVOUpdateExceptionKind -ErrorRecord $ErrorRecord
    if ($info.Kind -ceq 'Crash') { throw $ErrorRecord }

    $reason = 'Error'
    $defaultId = 'Operation.Error'
    switch -CaseSensitive ($info.Kind) {
        'Cancel' { $reason = 'Cancelled'; $defaultId = 'Operation.Cancelled' }
        'Blocked' { $reason = 'Blocked'; $defaultId = 'Operation.Blocked' }
        'Verification' { $reason = 'VerificationFailed'; $defaultId = 'Operation.VerificationFailed' }
        'PlanStale' { $reason = 'PlanStale'; $defaultId = 'Plan.Stale' }
        default { $reason = 'Error'; $defaultId = 'Operation.Error' }
    }
    $findingId = $defaultId; if (-not [string]::IsNullOrWhiteSpace($info.FindingId)) { $findingId = $info.FindingId }
    $actionText = $info.Action; if ([string]::IsNullOrWhiteSpace($actionText)) { $actionText = 'Перегляньте журнал операції (каталог операції) і за потреби повторіть після усунення причини.' }
    $hasBlocker = $false
    foreach ($existing in $Context.Findings) { if ([string]$existing.severity -ceq 'Blocker') { $hasBlocker = $true } }
    if ($info.Kind -ceq 'CancelAfterMutation') {
        Add-BRAVOUpdateContextFinding -Context $Context -Finding (New-BRAVOUpdateFinding -Id 'Operation.CancelledAfterMutation' -Severity Warning -Title 'Операцію скасовано після початку змін' `
                -Meaning 'Поточну фазу завершено, виконано відкат до стану до операції.' -Details ('остання фаза=' + [string]$Context.LastPhase))
    } elseif (-not $hasBlocker) {
        Add-BRAVOUpdateContextFinding -Context $Context -Finding (New-BRAVOUpdateFinding -Id $findingId -Severity Blocker -Title ('Операцію зупинено: ' + $info.Message) `
                -Meaning 'Зміни не завершено; стан сервера описано в результаті.' -Action $actionText -Details ([string]$info.Message) -ExitCodeHint $info.ExitCodeHint)
    }

    $journalPath = $null
    try { $journalPath = Get-BRAVOUpdateJournalPath -StateRoot $Context.Paths.StateRoot -OperationId $Context.OperationId } catch { $journalPath = $null }

    if (-not $Context.MutationStarted) {
        Invoke-BRAVOUpdatePreMutationCleanup -Context $Context
        return (New-BRAVOUpdateOperationResult -Plan $Context.Plan -Context $Context -Status Failed -ReasonCode $reason `
                -Findings @($Context.Findings.ToArray()) -Validation @($Context.Validation.ToArray()) `
                -InstalledVersion (Get-BRAVOUpdatePropertyValue -InputObject $Context.Plan -Name 'currentVersion') `
                -LastPhase $Context.LastPhase -MutationStarted $false -JournalPath $journalPath -StartedUtc $StartedUtc)
    }

    $rollbackResult = $null
    $rollbackFailure = $null
    try {
        $rollbackResult = Invoke-BRAVORollback -Journal $Context.Journal -Context $Context -Adapter $Context.Adapter -StateRoot $Context.Paths.StateRoot `
            -LockRoot $Context.Paths.LockRoot -OperationLockPath $Context.Paths.OperationLockPath -VersionStatePath $Context.Paths.VersionStatePath -FaultInjection $Context.FaultInjection
    } catch {
        if ((Get-BRAVOUpdateExceptionKind -ErrorRecord $_).Kind -ceq 'Crash') { throw }
        $rollbackFailure = [string]$_.Exception.Message
    }
    if (($null -eq $rollbackResult) -and ($null -eq $rollbackFailure)) { $rollbackFailure = 'Invoke-BRAVORollback не повернув результат.' }
    if ($null -ne $rollbackFailure) {
        if ($null -ne (Get-Command -Name 'Disable-BRAVOAllManagedTasks' -ErrorAction SilentlyContinue)) {
            try { [void](Disable-BRAVOAllManagedTasks -Adapter $Context.Adapter) } catch { $null = $_ }
        }
        try { [void](Set-BRAVOUpdateJournalState -Journal $Context.Journal -State Critical -StateRoot $Context.Paths.StateRoot) } catch { $null = $_ }
        Add-BRAVOUpdateContextFinding -Context $Context -Finding (New-BRAVOUpdateFinding -Id 'Rollback.Failed' -Severity Blocker -Title 'Відкат не вдався' `
                -Meaning 'Стан сервера невизначений; керовані задачі вимкнено в міру можливості.' -Action 'Не запускайте задачі вручну; зверніться до відновлення з резервної копії операції.' -Details $rollbackFailure)
        return (New-BRAVOUpdateOperationResult -Plan $Context.Plan -Context $Context -Status Critical `
                -Findings @($Context.Findings.ToArray()) -Validation @($Context.Validation.ToArray()) `
                -Rollback ([pscustomobject][ordered]@{ attempted = $true; status = 'Failed'; message = $rollbackFailure }) `
                -LastPhase $Context.LastPhase -MutationStarted $true -JournalPath $journalPath -StartedUtc $StartedUtc)
    }

    $status = [string](Get-BRAVOUpdatePropertyValue -InputObject $rollbackResult -Name 'status' -Default 'Critical')
    if (@('RolledBack', 'Critical') -cnotcontains $status) { $status = 'Critical' }
    $rollbackInfo = Get-BRAVOUpdatePropertyValue -InputObject $rollbackResult -Name 'rollback'
    if ($null -eq $rollbackInfo) {
        $outcome = 'Failed'; if ($status -ceq 'RolledBack') { $outcome = 'Succeeded' }
        $rollbackInfo = [pscustomobject][ordered]@{ attempted = $true; status = $outcome; message = '' }
    }
    $combinedFindings = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $Context.Findings) { $combinedFindings.Add($item) }
    foreach ($item in @(Get-BRAVOUpdateArrayProperty -InputObject $rollbackResult -Name 'findings')) { $combinedFindings.Add($item) }
    $combinedValidation = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $Context.Validation) { $combinedValidation.Add($item) }
    foreach ($item in @(Get-BRAVOUpdateArrayProperty -InputObject $rollbackResult -Name 'validation')) { $combinedValidation.Add($item) }
    $installed = $null; if ($status -ceq 'RolledBack') { $installed = Get-BRAVOUpdatePropertyValue -InputObject $Context.Plan -Name 'currentVersion' }
    return (New-BRAVOUpdateOperationResult -Plan $Context.Plan -Context $Context -Status $status `
            -Findings @($combinedFindings.ToArray()) -Validation @($combinedValidation.ToArray()) -Rollback $rollbackInfo `
            -TaskActivation (Get-BRAVOUpdatePropertyValue -InputObject $rollbackResult -Name 'taskActivation') `
            -InstalledVersion $installed -LastPhase $Context.LastPhase -MutationStarted $true -JournalPath $journalPath -StartedUtc $StartedUtc)
}

# ---------------------------------------------------------------------------
# Orchestrator Update/Repair
# ---------------------------------------------------------------------------

function Invoke-BRAVODeployment {
    <#
    .SYNOPSIS
        Orchestrator кроків U0-U19 (ENGINE_DESIGN 4.2) для дій Update і Repair
        (дія береться з plan.action). Повертає DeploymentResult.
    .DESCRIPTION
        Корені, не задані явно: staging/backup/runtime — з плану; State/Lock/Operation-
        lock/VersionState — з Get-BRAVOUpdateDefaultPaths (тести завжди задають їх явно).
        SourcePath (+ChecksumPath/ManifestPath) — офлайн-джерело; без нього береться
        plan.source.tag через Save-BRAVOReleaseArtifact (-Downloader/-RepositoryBaseUri
        підміняють мережу в тестах). Scope Scheduler (лише Repair) пропускає U5-U8 і
        U13; All і Runtime у цьому пакеті поводяться однаково.
        Змінна середовища BRAVO_ALLOW_DOWNGRADE у процесі = відмова на вході
        (Failed/Blocked) до будь-яких змін. FaultInjection — лише для тестів.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        [string]$RuntimeRoot = '',
        [string]$StateRoot = '',
        [string]$LockRoot = '',
        [string]$StagingRoot = '',
        [string]$BackupRoot = '',
        [string]$OperationLockPath = '',
        [string]$VersionStatePath = '',
        [string]$SourcePath = '',
        [string]$ChecksumPath = '',
        [string]$ManifestPath = '',
        [scriptblock]$Downloader = $null,
        [string]$RepositoryBaseUri = '',
        [ValidateSet('All', 'Runtime', 'Scheduler')][string]$Scope = 'All',
        [hashtable]$FaultInjection = $null
    )

    $startedUtc = Get-BRAVOUpdateUtcNowText
    if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE'))) {
        return (New-BRAVOUpdateOperationResult -Plan $Plan -Status Failed -ReasonCode Blocked -StartedUtc $startedUtc -Findings @(
                New-BRAVOUpdateFinding -Id 'Operation.AllowDowngradeSet' -Severity Blocker -Title 'У середовищі задано BRAVO_ALLOW_DOWNGRADE' `
                    -Meaning 'Installer не працює при вимкненому захисті від відкату версії.' -Action 'Приберіть змінну BRAVO_ALLOW_DOWNGRADE і повторіть.' -ExitCodeHint 35))
    }
    $planAction = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'action' -Default '')
    if (@('Update', 'Repair') -cnotcontains $planAction) {
        return (New-BRAVOUpdateOperationResult -Plan $Plan -Status Failed -ReasonCode Blocked -StartedUtc $startedUtc -Findings @(
                New-BRAVOUpdateFinding -Id 'Plan.WrongAction' -Severity Blocker -Title 'Orchestrator виконує лише Update і Repair' `
                    -Meaning 'Чиста інсталяція має власну транзакцію.' -Action 'Використайте Install-BRAVOToolkit для чистої інсталяції.'))
    }
    if (($Scope -cne 'All') -and ($planAction -cne 'Repair')) {
        return (New-BRAVOUpdateOperationResult -Plan $Plan -Status Failed -ReasonCode Blocked -StartedUtc $startedUtc -Findings @(
                New-BRAVOUpdateFinding -Id 'Plan.ScopeNotAllowed' -Severity Blocker -Title 'Обмежений Scope доступний лише для Repair' `
                    -Meaning 'Оновлення версії завжди виконується повністю.' -Action 'Приберіть параметр Scope.'))
    }

    $defaults = $null
    if (($StateRoot -eq '') -or ($LockRoot -eq '') -or ($OperationLockPath -eq '') -or ($VersionStatePath -eq '')) { $defaults = Get-BRAVOUpdateDefaultPaths }
    $pick = {
        param([string]$Explicit, [string]$Fallback)
        if ($Explicit -ne '') { return $Explicit }
        return $Fallback
    }
    $defaultState = ''; $defaultLock = ''; $defaultOperationLock = ''; $defaultVersionState = ''
    if ($null -ne $defaults) { $defaultState = $defaults.StateRoot; $defaultLock = $defaults.LockRoot; $defaultOperationLock = $defaults.OperationLockPath; $defaultVersionState = $defaults.VersionStatePath }
    $paths = [pscustomobject][ordered]@{
        RuntimeRoot       = (& $pick $RuntimeRoot ([string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'runtimeRoot' -Default '')))
        StateRoot         = (& $pick $StateRoot $defaultState)
        LockRoot          = (& $pick $LockRoot $defaultLock)
        StagingRoot       = (& $pick $StagingRoot ([string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'stagingRoot' -Default '')))
        BackupRoot        = (& $pick $BackupRoot ([string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'backupRoot' -Default '')))
        OperationLockPath = (& $pick $OperationLockPath $defaultOperationLock)
        VersionStatePath  = (& $pick $VersionStatePath $defaultVersionState)
    }

    $context = $null
    try {
        $opened = $null
        try {
            $opened = Open-BRAVOUpdateOperation -Plan $Plan -Adapter $Adapter -Paths $paths -FaultInjection $FaultInjection
        } catch {
            if ((Get-BRAVOUpdateExceptionKind -ErrorRecord $_).Kind -ceq 'Crash') { throw }
            return (New-BRAVOUpdateOperationResult -Plan $Plan -Status Failed -ReasonCode Error -StartedUtc $startedUtc -Findings @(
                    New-BRAVOUpdateFinding -Id 'Operation.StartFailed' -Severity Blocker -Title 'Не вдалося розпочати операцію' `
                        -Meaning 'Підготовку (lock, журнал, реєстр планів) не завершено; змін runtime немає.' -Action 'Перевірте каталог State та права доступу і повторіть.' -Details ([string]$_.Exception.Message)))
        }
        if ($null -ne $opened.EarlyResult) { return $opened.EarlyResult }
        $context = $opened.Context
        $context.Data['Scope'] = $Scope

        try {
            $schedulerOnly = ($Scope -ceq 'Scheduler')
            if (-not $schedulerOnly) {
                [void](Invoke-BRAVOUpdateAcquireStage -Context $context -SourcePath $SourcePath -ChecksumPath $ChecksumPath -ManifestPath $ManifestPath -Downloader $Downloader -RepositoryBaseUri $RepositoryBaseUri)
            } else {
                foreach ($skipped in @('Acquire', 'Verify', 'Stage')) {
                    Send-BRAVOUpdatePhaseProgress -Context $context -ProgressPhase $skipped -Status 'Skipped' -PhaseName $skipped -Message ('Фаза ' + $skipped + ': пропущено (Scope Scheduler)')
                }
            }
            Invoke-BRAVOUpdatePlanRecheck -Context $context
            if (-not $schedulerOnly) {
                [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'Backup' -ProgressPhase Backup -Durable -Percent 50 -Action {
                        param($Context)
                        $backup = New-BRAVORuntimeBackup -RuntimeRoot $Context.Paths.RuntimeRoot -BackupRoot $Context.Paths.BackupRoot -OperationId $Context.OperationId -FaultInjection $Context.FaultInjection
                        $backupProblems = @(Get-BRAVOUpdateArrayProperty -InputObject $backup -Name 'Problems')
                        if ($backupProblems.Count -gt 0) {
                            throw (New-BRAVOUpdateTypedException -Message ('Резервну копію не створено: ' + (($backupProblems | Select-Object -First 5) -join '; ')) -Kind Error -FindingId 'Backup.Failed' -Action 'Перевірте місце на диску та права на каталог резервних копій.')
                        }
                        [void](Set-BRAVOUpdateJournalBackup -Journal $Context.Journal -Path ([string]$backup.Path) -ManifestSha256 ([string]$backup.ManifestSha256) -FileCount ([int]$backup.FileCount) -StateRoot $Context.Paths.StateRoot)
                        $Context.Data['Backup'] = $backup
                    })
            }
            Invoke-BRAVOUpdateEnterOperationLock -Context $context
            Invoke-BRAVOUpdateCaptureBaseline -Context $context
            Start-BRAVOUpdateMutation -Context $context

            [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'QuiesceTasks' -ProgressPhase Deploy -Durable -Percent 65 -Action {
                    param($Context)
                    $suspended = Suspend-BRAVOManagedTasks -Snapshot $Context.Data['SchedulerSnapshot'] -Adapter $Context.Adapter
                    $suspendFailed = @(Get-BRAVOUpdateArrayProperty -InputObject $suspended -Name 'Failed')
                    if ($suspendFailed.Count -gt 0) {
                        throw (New-BRAVOUpdateTypedException -Message ('Не вдалося вимкнути керовані задачі: ' + (($suspendFailed | ForEach-Object { [string]$_ }) -join '; ')) -Kind Error -FindingId 'Scheduler.SuspendFailed')
                    }
                })
            if (-not $schedulerOnly) {
                [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'Deploy' -ProgressPhase Deploy -Durable -Percent 70 -Action {
                        param($Context)
                        $deployed = Invoke-BRAVORuntimeDeploy -Context $Context -StagedRoot ([string]$Context.Data['StagedRoot']) -FileSet $Context.Data['FileSet']
                        if (@($deployed.Errors).Count -gt 0) {
                            throw (New-BRAVOUpdateTypedException -Message ('Розгортання файлів не вдалося: ' + (@($deployed.Errors) -join '; ')) -Kind Error -FindingId 'Deploy.Failed')
                        }
                        $Context.Data['Deployed'] = $deployed
                    })
            } else {
                Send-BRAVOUpdatePhaseProgress -Context $context -ProgressPhase 'Deploy' -Status 'Skipped' -PhaseName 'Deploy' -Message 'Фаза Deploy: пропущено (Scope Scheduler)'
            }
            [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'ConfigureScheduler' -ProgressPhase Configure -Durable -Percent 78 -Action {
                    param($Context)
                    $reconcile = Invoke-BRAVOSchedulerReconcile -Context $Context -Snapshot $Context.Data['SchedulerSnapshot']
                    $Context.Data['SchedulerReconcile'] = $reconcile
                    $created = @(Get-BRAVOUpdateArrayProperty -InputObject $reconcile -Name 'CreatedTasks')
                    if ($created.Count -gt 0) { [void](Set-BRAVOUpdateJournalField -Journal $Context.Journal -StateRoot $Context.Paths.StateRoot -Name 'createdTasks' -Value @($created)) }
                    $verdict = [string](Get-BRAVOUpdatePropertyValue -InputObject $reconcile -Name 'Verdict' -Default 'FAIL')
                    if ($verdict -ceq 'FAIL') {
                        throw (New-BRAVOUpdateTypedException -Message ('Налаштування планувальника завершилось збоєм: ' + ((@(Get-BRAVOUpdateArrayProperty -InputObject $reconcile -Name 'Problems') | Select-Object -First 5) -join '; ')) -Kind Error -FindingId 'Scheduler.ReconcileFailed')
                    }
                })
            $mode = 'Deploy'; if ($planAction -ceq 'Repair') { $mode = 'Repair' }
            [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'Validate' -ProgressPhase Validate -Percent 88 -Action {
                    param($Context)
                    $validationArgs = @{
                        Context              = $Context
                        Mode                 = $mode
                        ExpectedVersion      = [string](Get-BRAVOUpdatePropertyValue -InputObject $Context.Plan -Name 'targetVersion' -Default '')
                        ExpectedManifestPath = (Join-Path $Context.Paths.RuntimeRoot 'RUNTIME_MANIFEST.json')
                        SiteBaseline         = $Context.Data['SiteBaseline']
                    }
                    if ($null -ne $Context.Data['GuardBaselineExitCode']) { $validationArgs['GuardBaselineExitCode'] = [int]$Context.Data['GuardBaselineExitCode'] }
                    $validation = Test-BRAVODeploymentValidation @validationArgs
                    foreach ($item in @(Get-BRAVOUpdateArrayProperty -InputObject $validation -Name 'Items')) { $Context.Validation.Add($item) }
                    $validationStatus = [string](Get-BRAVOUpdatePropertyValue -InputObject $validation -Name 'Status' -Default 'Fail')
                    if ($validationStatus -ceq 'Warn') {
                        Add-BRAVOUpdateContextFinding -Context $Context -Finding (New-BRAVOUpdateFinding -Id 'Validate.Warnings' -Severity Warning -Title 'Валідація завершилась із попередженнями' -Meaning 'Деякі перевірки дали попередження; див. validation.')
                    } elseif ($validationStatus -cne 'Pass') {
                        $failedNames = @($Context.Validation.ToArray() | Where-Object { [string](Get-BRAVOUpdatePropertyValue -InputObject $_ -Name 'status') -ceq 'Fail' } | ForEach-Object { [string](Get-BRAVOUpdatePropertyValue -InputObject $_ -Name 'name') })
                        throw (New-BRAVOUpdateTypedException -Message ('Валідація після розгортання не пройшла: ' + ($failedNames -join ', ')) -Kind Verification -FindingId 'Validate.Failed' -Action 'Виконано відкат; перегляньте validation у результаті.')
                    }
                })

            # U16: остання нагода скасувати; далі — Activate, де cancel ігнорується.
            if (Test-BRAVOUpdateCancelRequested -Context $context) {
                throw (New-BRAVOUpdateTypedException -Message 'Операцію скасовано перед активацією: виконується відкат.' -Kind CancelAfterMutation)
            }

            $outcomeStatus = 'Success'
            foreach ($item in $context.Findings) { if ([string]$item.severity -ceq 'Warning') { $outcomeStatus = 'SuccessWithWarnings' } }
            $activationPolicy = [string](Get-BRAVOUpdatePropertyValue -InputObject (Get-BRAVOUpdatePropertyValue -InputObject (Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'changes') -Name 'scheduler') -Name 'activationPolicy' -Default 'ActivateOnSuccessOnly')
            $taskActivation = $null
            try {
                $activation = Invoke-BRAVOUpdatePhase -Context $context -Phase 'Activate' -ProgressPhase Activate -Durable -IgnoreCancel -Percent 94 -Action {
                    param($Context)
                    Set-BRAVOTaskActivation -Policy $activationPolicy -Snapshot $Context.Data['SchedulerSnapshot'] -Adapter $Context.Adapter -OutcomeStatus $outcomeStatus -Action $planAction
                }
                $taskActivation = Get-BRAVOUpdatePropertyValue -InputObject $activation -Name 'TaskActivation'
                foreach ($activationFinding in @(Get-BRAVOUpdateArrayProperty -InputObject $activation -Name 'Findings')) { Add-BRAVOUpdateContextFinding -Context $context -Finding $activationFinding }
            } catch {
                # Після успішної Validate збій Activate не відкочує розгортання: файли вже
                # перевірені, тож задачі лишаються вимкненими, а оператор бачить Unknown.
                if ((Get-BRAVOUpdateExceptionKind -ErrorRecord $_).Kind -ceq 'Crash') { throw }
                $taskActivation = $null
                Add-BRAVOUpdateContextFinding -Context $context -Finding (New-BRAVOUpdateFinding -Id 'Activate.Failed' -Severity Warning -Title 'Не вдалося підтвердити стан задач після розгортання' `
                        -Meaning 'Розгортання перевірено й збережено, але стан активації задач невідомий.' -Action 'Перевірте стан задач у планувальнику й увімкніть їх вручну за потреби.' -Details ([string]$_.Exception.Message))
            }
            if ($null -eq $taskActivation) { $taskActivation = [pscustomobject][ordered]@{ state = 'Unknown'; tasks = @() } }
            if ([string](Get-BRAVOUpdatePropertyValue -InputObject $taskActivation -Name 'state' -Default '') -ceq 'Inactive') {
                Add-BRAVOUpdateContextFinding -Context $context -Finding (New-BRAVOUpdateFinding -Id 'Activate.Inactive' -Severity Warning -Title 'Керовані задачі лишились вимкненими' `
                        -Meaning 'За політикою активації задачі не вмикаються автоматично.' -Action 'Увімкніть задачі після перевірки результату оновлення.')
            }
            $context.Data['TaskActivation'] = $taskActivation

            # U18: Commit. Журнал Committed ставиться ПІСЛЯ фази: будь-який збій до цього
            # ще веде до відкату, а після — вже ні.
            [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'Commit' -ProgressPhase Commit -Durable -IgnoreCancel -Percent 99 -Action {
                    param($Context)
                    $null = $Context.Journal
                })
            [void](Set-BRAVOUpdateJournalState -Journal $context.Journal -State Committed -StateRoot $paths.StateRoot)
            Close-BRAVOUpdateOperationHandles -Context $context
            try {
                $removal = Remove-BRAVOUpdateOperationDirectory -Path (Join-Path $paths.StagingRoot $context.OperationId) -ExpectedParent $paths.StagingRoot -OperationId $context.OperationId -AllowedRoot @([string]$paths.StagingRoot, [string]$paths.BackupRoot)
                if (@($removal.Problems).Count -gt 0) {
                    Add-BRAVOUpdateContextFinding -Context $context -Finding (New-BRAVOUpdateFinding -Id 'Commit.StagingNotRemoved' -Severity Warning -Title 'Staging операції видалено не повністю' `
                            -Meaning 'Залишки не впливають на роботу; їх можна видалити вручну.' -Details ((@($removal.Problems) | Select-Object -First 5) -join '; '))
                }
            } catch {
                Add-BRAVOUpdateContextFinding -Context $context -Finding (New-BRAVOUpdateFinding -Id 'Commit.StagingNotRemoved' -Severity Warning -Title 'Staging операції не видалено' `
                        -Meaning 'Залишки не впливають на роботу; їх можна видалити вручну.' -Details ([string]$_.Exception.Message))
            }

            $finalStatus = 'Success'
            foreach ($item in $context.Findings) { if ([string]$item.severity -ceq 'Warning') { $finalStatus = 'SuccessWithWarnings' } }
            foreach ($item in $context.Validation) { if ([string](Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'status') -ceq 'Warn') { $finalStatus = 'SuccessWithWarnings' } }
            if ([string](Get-BRAVOUpdatePropertyValue -InputObject $taskActivation -Name 'state' -Default '') -ceq 'Unknown') { $finalStatus = 'SuccessWithWarnings' }
            return (New-BRAVOUpdateOperationResult -Plan $Plan -Context $context -Status $finalStatus `
                    -Findings @($context.Findings.ToArray()) -Validation @($context.Validation.ToArray()) -TaskActivation $taskActivation `
                    -InstalledVersion (Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'targetVersion') -LastPhase $context.LastPhase -MutationStarted $true `
                    -JournalPath (Get-BRAVOUpdateJournalPath -StateRoot $paths.StateRoot -OperationId $context.OperationId) -StartedUtc $startedUtc)
        } catch {
            return (Resolve-BRAVOUpdateOperationFailure -Context $context -ErrorRecord $_ -StartedUtc $startedUtc)
        }
    } finally {
        Close-BRAVOUpdateOperationHandles -Context $context
    }
}
