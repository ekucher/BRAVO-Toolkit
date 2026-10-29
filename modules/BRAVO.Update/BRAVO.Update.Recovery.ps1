# BRAVO.Update.Recovery — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Recovery незавершеної операції (ENGINE_DESIGN §8.1, CONTRACTS §8): ЄДИНИЙ
# дозволений вихід із відкритого журналу. Recovery v1 — лише повернення до
# known-good (resume-from-middle не підтримується): до mutationStarted
# прибираємо staging/backup операції, після — Invoke-BRAVORollback (E5).
# Після recovery придатний лише новий preflight і новий план.
#
# Залежності від інших частин (викликаються за іменем):
#   Invoke-BRAVORollback (Rollback), Remove-BRAVOUpdateOperationDirectory (Deploy,
#   приватна), Disable-BRAVOAllManagedTasks (Reconcile, best-effort).
# Assumption: Invoke-BRAVORollback НЕ бере lifecycle-lock сам, коли викликана з
# Recovery, бо lock тримається тут до кінця; operation-lock вона бере сама.

function Invoke-BRAVORecoveryFaultPoint {
    <#
    .SYNOPSIS
        Точка failure injection для Recovery: ключі 'Recovery.<Point>', значення
        Throw | Crash. Crash кидає BRAVOUpdate.SimulatedCrash, який Recovery не
        перехоплює (журнал лишається Open, у finally звільняється лише lock).
    .DESCRIPTION
        Окремо від Invoke-BRAVOUpdateFaultPoint частини Deploy: у Recovery немає
        контексту операції, а простір ключів інший. FaultInjection ніколи не
        читається з request чи аргументів CLI — лише з тестового виклику.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$FaultInjection,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $FaultInjection) { return }
    if ($FaultInjection -isnot [System.Collections.IDictionary]) { return }
    if (-not $FaultInjection.Contains($Name)) { return }
    $mode = [string]$FaultInjection[$Name]
    if ($mode -ceq 'Crash') { throw "BRAVOUpdate.SimulatedCrash: $Name" }
    if ($mode -ceq 'Throw') { throw "BRAVOUpdate.SimulatedFault: $Name" }
}

function Test-BRAVORecoveryIsSimulatedCrash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    return ([string]$ErrorRecord.Exception.Message).StartsWith('BRAVOUpdate.SimulatedCrash', [StringComparison]::Ordinal)
}

function Send-BRAVORecoveryProgress {
    <#
    .SYNOPSIS
        Best-effort подія фази Recovery у progress.jsonl вже існуючого каталогу операції.
    .DESCRIPTION
        Каталог Operations\<id> створює оригінальна операція (з потрібним ACL); recovery
        його НЕ створює. Немає каталогу або збій запису — мовчки пропускаємо: прогрес
        не може завалити відновлення.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][ValidateSet('Started', 'Completed', 'Failed')][string]$Status,
        [Parameter(Mandatory = $true)][string]$MessageKey,
        [Parameter(Mandatory = $true)][string]$Message
    )

    try {
        $directory = Join-Path (Join-Path $StateRoot 'Operations') $OperationId
        if (-not [IO.Directory]::Exists($directory)) { return }
        $writer = New-BRAVOUpdateProgressWriter -Path (Join-Path $directory 'progress.jsonl') -OperationId $OperationId
        [void]$writer.Emit('Recovery', $Status, $null, $MessageKey, @(), $Message)
    } catch {
        $null = $_
    }
}

function New-BRAVOUpdateRecoveryResult {
    <#
    .SYNOPSIS
        DeploymentResult (action=Recovery) із полями журналу, якщо він відомий.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][ValidateSet('Success', 'SuccessWithWarnings', 'Failed', 'RolledBack', 'Critical')][string]$Status,
        [ValidateSet('', 'Blocked', 'Cancelled', 'PlanStale', 'VerificationFailed', 'Error')][string]$ReasonCode = '',
        [object[]]$Findings = @(),
        $Journal = $null,
        [AllowNull()][string]$JournalPath = $null,
        [object[]]$Validation = @(),
        $Rollback = $null,
        $TaskActivation = $null,
        [AllowNull()]$InstalledVersion = $null,
        [AllowNull()][string]$LogPath = $null,
        [AllowNull()][string]$ReportPath = $null,
        [Parameter(Mandatory = $true)][string]$StartedUtc
    )

    $planId = $null
    $sourceVersion = $null
    $targetVersion = $null
    $lastPhase = $null
    $mutation = $false
    if ($null -ne $Journal) {
        $planId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'planId' -Default '')
        $sourceVersion = Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'sourceVersion'
        $targetVersion = Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'targetVersion'
        $lastPhase = Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'lastCompletedPhase'
        $mutation = ((Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'mutationStarted' -Default $false) -eq $true)
    }
    $arguments = @{
        OperationId      = $OperationId
        PlanId           = $planId
        Action           = 'Recovery'
        Status           = $Status
        ReasonCode       = $ReasonCode
        SourceVersion    = $sourceVersion
        TargetVersion    = $targetVersion
        InstalledVersion = $InstalledVersion
        LastPhase        = $lastPhase
        MutationStarted  = $mutation
        Validation       = @($Validation)
        Findings         = @($Findings)
        LogPath          = $LogPath
        ReportPath       = $ReportPath
        JournalPath      = $JournalPath
        StartedUtc       = $StartedUtc
    }
    if ($null -ne $Rollback) { $arguments['Rollback'] = $Rollback }
    if ($null -ne $TaskActivation) { $arguments['TaskActivation'] = $TaskActivation }
    return (New-BRAVOUpdateDeploymentResult @arguments)
}

function Remove-BRAVORecoveryOperationArtifact {
    <#
    .SYNOPSIS
        Прибирає staging\<opId> і backup\<opId> операції, що не дійшла до mutation.
    .DESCRIPTION
        Корені беруться з журналу, тож ПЕРЕД видаленням перевіряємо їх: абсолютний
        шлях, не збігається і не вкладений у runtimeRoot (підроблений журнал не має
        спрямувати видалення в робочу копію). Саме видалення — лише приватна
        Remove-BRAVOUpdateOperationDirectory (leaf=opId, parent=очікуваний корінь,
        reparse point видаляється як link). Відсутній каталог — не помилка
        (повторний recovery ідемпотентний). Будь-яка підозра = виняток, журнал
        лишається Open для ручного аналізу.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Journal)

    $operationId = [string]$Journal.operationId
    $runtimeRoot = [string](Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name 'runtimeRoot' -Default '')
    $removed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rootName in @('stagingRoot', 'backupRoot')) {
        $root = [string](Get-BRAVOUpdatePropertyValue -InputObject $Journal -Name $rootName -Default '')
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (-not [IO.Path]::IsPathRooted($root)) { throw "BRAVO.Update: $rootName журналу не є абсолютним шляхом: '$root'." }
        if (-not [string]::IsNullOrWhiteSpace($runtimeRoot)) {
            if ((Test-BRAVOUpdatePathIsUnder -Path $root -Root $runtimeRoot -AllowEqual) -or (Test-BRAVOUpdatePathIsUnder -Path $runtimeRoot -Root $root -AllowEqual)) {
                throw "BRAVO.Update: $rootName журналу перетинається з runtimeRoot; видалення відхилено."
            }
        }
        $directory = Join-Path $root $operationId
        if (-not [IO.Directory]::Exists($directory)) { continue }
        Remove-BRAVOUpdateOperationDirectory -Path $directory -ExpectedParent $root -OperationId $operationId
        $removed.Add($directory)
    }
    return $removed.ToArray()
}

function Invoke-BRAVORecovery {
    <#
    .SYNOPSIS
        Відновлення після перерваної операції (ENGINE_DESIGN §8.1).
    .DESCRIPTION
        lifecycle lock (зайнято -> Failed/Blocked, 20) -> відкриті журнали:
        0 -> Success; >1 -> Failed/Blocked (ручний аналіз, без змін);
        нечитаний -> Critical без змін; mutationStarted=false -> staging/backup
        операції видаляються, журнал Abandoned, Failed (80); mutationStarted=true
        -> Invoke-BRAVORollback. Crash після Validate чи в Activate теж закінчується
        rollback (R1), бо відомий лише факт mutationStarted.
        Усі кроки повторювані: перерваний recovery можна запустити знову.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$LockRoot,
        [Parameter(Mandatory = $true)][string]$OperationLockPath,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        [string]$VersionStatePath = '',
        [hashtable]$FaultInjection = $null,
        # Корені engine для перевірки довіри до журналу (Test-BRAVORollbackJournalTrust).
        # RuntimeRoot — виявлена установка (worker/CLI); без нього відкат Update/Repair
        # відмовляє (fail closed). Staging/Backup за замовчуванням — Get-BRAVOUpdateDefaultPaths.
        [string]$RuntimeRoot = '',
        [string]$StagingRoot = '',
        [string]$BackupRoot = ''
    )

    $startedUtc = Get-BRAVOUpdateUtcNowText
    $recoveryId = [guid]::NewGuid().ToString()

    $lock = Enter-BRAVOUpdateLifecycleLock -LockRoot $LockRoot -OperationId $recoveryId
    if (-not $lock.Success) {
        $busy = New-BRAVOUpdateFinding -Id 'Recovery.LifecycleLockBusy' -Severity Blocker `
            -Title 'Інша операція оновлення або відновлення вже виконується' `
            -Meaning 'Recovery не запускається поруч з активною операцією: вона може змінювати робочу копію.' `
            -Action 'Дочекайтеся завершення активної операції й повторіть відновлення. Процес не завершуйте примусово.' `
            -Details ([string]$lock.Error) -ExitCodeHint 20
        return (New-BRAVOUpdateRecoveryResult -OperationId $recoveryId -Status Failed -ReasonCode Blocked -Findings @($busy) -StartedUtc $startedUtc)
    }

    try {
        $entries = @(Get-BRAVOUpdateOpenJournal -StateRoot $StateRoot)

        if ($entries.Count -eq 0) {
            $none = New-BRAVOUpdateFinding -Id 'Recovery.NothingToRecover' -Severity Ok -Title 'Відкритих журналів немає' `
                -Meaning 'Незавершених операцій не знайдено, відновлення не потрібне.'
            return (New-BRAVOUpdateRecoveryResult -OperationId $recoveryId -Status Success -Findings @($none) -StartedUtc $startedUtc)
        }

        if ($entries.Count -gt 1) {
            $ids = (@($entries | ForEach-Object { [string]$_.OperationId }) -join ', ')
            $many = New-BRAVOUpdateFinding -Id 'Recovery.MultipleOpenJournals' -Severity Blocker `
                -Title 'Знайдено кілька відкритих журналів' `
                -Meaning 'Автоматичне відновлення неможливе: невідомо, у якому порядку операції змінювали робочу копію.' `
                -Action 'Потрібен ручний аналіз журналів у каталозі Journal; нічого не видаляйте вручну.' `
                -Details ("operationId: $ids")
            return (New-BRAVOUpdateRecoveryResult -OperationId $recoveryId -Status Failed -ReasonCode Blocked -Findings @($many) -StartedUtc $startedUtc)
        }

        $entry = $entries[0]
        $entryOperationId = [string]$entry.OperationId
        if (-not (Test-BRAVOUpdateGuidText -Value $entryOperationId)) { $entryOperationId = $recoveryId }

        if ($entry.IsCorrupt -or ($null -eq $entry.Journal)) {
            # Невідомо, чи починалась mutation: будь-яка дія була б здогадкою, тож без змін.
            $corrupt = New-BRAVOUpdateFinding -Id 'Recovery.JournalCorrupt' -Severity Blocker `
                -Title 'Журнал незавершеної операції пошкоджений' `
                -Meaning 'Не можна визначити, чи змінювалась робоча копія; автоматичне відновлення не виконувалось, жодних змін не внесено.' `
                -Action 'Збережіть журнал і зверніться до адміністратора для ручного аналізу. Журнал не видаляйте.' `
                -Details (@($entry.Problems) -join '; ')
            $found = @($corrupt)
            if ($null -ne $entry.Finding) { $found = @($entry.Finding, $corrupt) }
            return (New-BRAVOUpdateRecoveryResult -OperationId $entryOperationId -Status Critical -Findings $found -JournalPath ([string]$entry.Path) -StartedUtc $startedUtc)
        }

        $journal = $entry.Journal
        $journalPath = [string]$entry.Path
        $operationId = [string]$journal.operationId
        # Довіра до журналу ДО будь-якої дії (прибирання staging/backup, відкат, задачі, state):
        # журнал пише й непривілегований користувач. Недовірений -> Critical без змін.
        if ([string]::IsNullOrWhiteSpace($StagingRoot)) { $StagingRoot = [string](Get-BRAVOUpdateDefaultPaths).StagingRoot }
        if ([string]::IsNullOrWhiteSpace($BackupRoot)) { $BackupRoot = [string](Get-BRAVOUpdateDefaultPaths).BackupRoot }
        $trustArguments = @{ Journal = $journal; StateRoot = $StateRoot; RuntimeRoot = $RuntimeRoot; StagingRoot = $StagingRoot; BackupRoot = $BackupRoot; LockRoot = $LockRoot; JournalPath = $journalPath }
        # До mutation корінь установки не використовується (лише прибирання staging/backup).
        if (($journal.mutationStarted -ne $true) -and [string]::IsNullOrWhiteSpace($RuntimeRoot)) { $trustArguments['AllowUnsuppliedRoots'] = $true; $trustArguments['StagingRoot'] = $StagingRoot; $trustArguments['BackupRoot'] = $BackupRoot }
        $recoveryTrust = Test-BRAVORollbackJournalTrust @trustArguments
        if (-not $recoveryTrust.IsTrusted) {
            $untrusted = New-BRAVOUpdateFinding -Id 'Recovery.JournalUntrusted' -Severity Blocker `
                -Title 'Журнал незавершеної операції не пройшов перевірку довіри' `
                -Meaning 'Шляхи в журналі не відповідають кореням engine (журнал могли підмінити); жодних змін не внесено.' `
                -Action 'Не запускайте відновлення з цього журналу; збережіть його й зверніться до адміністратора.' `
                -Details (@($recoveryTrust.Problems) -join '; ') -ExitCodeHint 82
            return (New-BRAVOUpdateRecoveryResult -OperationId $entryOperationId -Status Critical -Findings @($untrusted) -JournalPath $journalPath -StartedUtc $startedUtc)
        }
        Send-BRAVORecoveryProgress -StateRoot $StateRoot -OperationId $operationId -Status Started -MessageKey 'Recovery.Started' -Message 'Відновлення після перерваної операції.'
        Invoke-BRAVORecoveryFaultPoint -FaultInjection $FaultInjection -Name 'Recovery.Start'

        if ($journal.mutationStarted -ne $true) {
            return (Invoke-BRAVORecoveryAbandon -Journal $journal -JournalPath $journalPath -StateRoot $StateRoot -FaultInjection $FaultInjection -StartedUtc $startedUtc)
        }
        return (Invoke-BRAVORecoveryRollback -Journal $journal -JournalPath $journalPath -StateRoot $StateRoot -LockRoot $LockRoot -OperationLockPath $OperationLockPath -Adapter $Adapter -VersionStatePath $VersionStatePath -FaultInjection $FaultInjection -RuntimeRoot $RuntimeRoot -StagingRoot $StagingRoot -BackupRoot $BackupRoot -StartedUtc $startedUtc)
    } catch {
        if (Test-BRAVORecoveryIsSimulatedCrash -ErrorRecord $_) { throw }
        # Неочікуваний збій ДО mutation-кроків: журнал лишається Open, можна повторити.
        $failure = New-BRAVOUpdateFinding -Id 'Recovery.Error' -Severity Blocker `
            -Title 'Відновлення перервалось помилкою' `
            -Meaning 'Журнал лишився відкритим; повторний запуск відновлення безпечний (кроки ідемпотентні).' `
            -Action 'Усуньте причину зі звіту й повторіть відновлення.' `
            -Details ([string]$_.Exception.Message)
        return (New-BRAVOUpdateRecoveryResult -OperationId $recoveryId -Status Failed -ReasonCode Error -Findings @($failure) -StartedUtc $startedUtc)
    } finally {
        Exit-BRAVOUpdateLifecycleLock -Lock $lock
    }
}

function Invoke-BRAVORecoveryAbandon {
    <#
    .SYNOPSIS
        mutationStarted=false: runtime не змінювався; прибирає staging/backup операції
        і закриває журнал як Abandoned.
    .DESCRIPTION
        Порядок: intent -> прибирання -> completion -> Abandoned. Збій/crash між
        кроками лишає журнал Open, а повторний recovery виконає прибирання знову
        (Remove ідемпотентний; другий intent 'Recovery' не додається).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$JournalPath,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [AllowNull()]$FaultInjection,
        [Parameter(Mandatory = $true)][string]$StartedUtc
    )

    $operationId = [string]$Journal.operationId
    $phases = @($Journal.phases)
    $hasOpenRecovery = $false
    if ($phases.Count -gt 0) {
        $lastPhase = $phases[$phases.Count - 1]
        $hasOpenRecovery = (([string]$lastPhase.phase -ceq 'Recovery') -and ($null -eq $lastPhase.completedUtc))
    }
    if (-not $hasOpenRecovery) { [void](Add-BRAVOUpdateJournalPhaseIntent -Journal $Journal -Phase 'Recovery' -StateRoot $StateRoot) }
    Invoke-BRAVORecoveryFaultPoint -FaultInjection $FaultInjection -Name 'Recovery.AfterIntent'

    $removed = @(Remove-BRAVORecoveryOperationArtifact -Journal $Journal)
    Invoke-BRAVORecoveryFaultPoint -FaultInjection $FaultInjection -Name 'Recovery.AfterCleanup'

    [void](Complete-BRAVOUpdateJournalPhase -Journal $Journal -Phase 'Recovery' -Outcome 'Succeeded' -StateRoot $StateRoot)
    [void](Set-BRAVOUpdateJournalState -Journal $Journal -State 'Abandoned' -StateRoot $StateRoot)
    Send-BRAVORecoveryProgress -StateRoot $StateRoot -OperationId $operationId -Status Failed -MessageKey 'Recovery.Abandoned' -Message 'Операцію перервано до змін робочої копії; тимчасові дані прибрано.'

    $finding = New-BRAVOUpdateFinding -Id 'Recovery.AbandonedBeforeMutation' -Severity Warning `
        -Title 'Операцію перервано до змін робочої копії' `
        -Meaning 'Встановлена версія не змінювалась; тимчасові каталоги staging/backup цієї операції прибрано, журнал закрито як Abandoned.' `
        -Action 'Виконайте новий preflight і побудуйте новий план.' `
        -Details ('removed=' + ($removed -join '; '))
    return (New-BRAVOUpdateRecoveryResult -OperationId $operationId -Status Failed -ReasonCode Error -Findings @($finding) -Journal $Journal -JournalPath $JournalPath -StartedUtc $StartedUtc)
}

function Invoke-BRAVORecoveryRollback {
    <#
    .SYNOPSIS
        mutationStarted=true: делегує Invoke-BRAVORollback (E5) і повертає її підсумок
        як DeploymentResult з action=Recovery.
    .DESCRIPTION
        Fail closed: результат rollback поза {RolledBack, Critical} вважається
        Critical. Виняток із rollback (не Crash) -> best-effort вимкнення всіх
        керованих задач, журнал Critical, результат Critical.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$JournalPath,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$LockRoot,
        [Parameter(Mandatory = $true)][string]$OperationLockPath,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        [string]$VersionStatePath = '',
        [AllowNull()]$FaultInjection,
        [Parameter(Mandatory = $true)][string]$StartedUtc,
        [string]$RuntimeRoot = '',
        [string]$StagingRoot = '',
        [string]$BackupRoot = ''
    )

    $operationId = [string]$Journal.operationId
    if ([string]::IsNullOrWhiteSpace($VersionStatePath)) { $VersionStatePath = [string](Get-BRAVOUpdateDefaultPaths).VersionStatePath }
    Invoke-BRAVORecoveryFaultPoint -FaultInjection $FaultInjection -Name 'Recovery.BeforeRollback'

    $rollbackResult = $null
    $rollbackError = $null
    try {
        if ($null -eq (Get-Command -Name 'Invoke-BRAVORollback' -ErrorAction SilentlyContinue)) {
            throw 'BRAVO.Update: Invoke-BRAVORollback недоступна.'
        }
        $rollbackArguments = @{
            Journal           = $Journal
            Adapter           = $Adapter
            StateRoot         = $StateRoot
            LockRoot          = $LockRoot
            OperationLockPath = $OperationLockPath
            VersionStatePath  = $VersionStatePath
            RuntimeRoot       = $RuntimeRoot
            StagingRoot       = $StagingRoot
            BackupRoot        = $BackupRoot
            JournalPath       = $JournalPath
        }
        if ($null -ne $FaultInjection) { $rollbackArguments['FaultInjection'] = $FaultInjection }
        $rollbackResult = Invoke-BRAVORollback @rollbackArguments
    } catch {
        if (Test-BRAVORecoveryIsSimulatedCrash -ErrorRecord $_) { throw }
        $rollbackError = [string]$_.Exception.Message
    }

    $findings = New-Object 'System.Collections.Generic.List[object]'
    $status = ''
    if ($null -ne $rollbackResult) { $status = [string](Get-BRAVOUpdatePropertyValue -InputObject $rollbackResult -Name 'status' -Default '') }
    if (($null -eq $rollbackError) -and (@('RolledBack', 'Critical') -ccontains $status)) {
        $inherited = Get-BRAVOUpdatePropertyValue -InputObject $rollbackResult -Name 'findings'
        if ($null -ne $inherited) { foreach ($item in @($inherited)) { $findings.Add($item) } }
        if ($status -ceq 'RolledBack') {
            $findings.Add((New-BRAVOUpdateFinding -Id 'Recovery.RolledBack' -Severity Warning `
                -Title 'Перервану операцію відкочено до попереднього стану' `
                -Meaning 'Робоча копія повернена до known-good; оновлення не завершено.' `
                -Action 'Виконайте новий preflight і побудуйте новий план.'))
        }
        $validation = @()
        $validationValue = Get-BRAVOUpdatePropertyValue -InputObject $rollbackResult -Name 'validation'
        if ($null -ne $validationValue) { $validation = @($validationValue) }
        $resultArguments = @{
            OperationId      = $operationId
            Status           = $status
            Findings         = $findings.ToArray()
            Journal          = $Journal
            JournalPath      = $JournalPath
            Validation       = $validation
            InstalledVersion = (Get-BRAVOUpdatePropertyValue -InputObject $rollbackResult -Name 'installedVersion')
            LogPath          = [string](Get-BRAVOUpdatePropertyValue -InputObject $rollbackResult -Name 'logPath' -Default '')
            ReportPath       = [string](Get-BRAVOUpdatePropertyValue -InputObject $rollbackResult -Name 'reportPath' -Default '')
            StartedUtc       = $StartedUtc
        }
        $rollbackInfo = Get-BRAVOUpdatePropertyValue -InputObject $rollbackResult -Name 'rollback'
        if ($null -ne $rollbackInfo) { $resultArguments['Rollback'] = $rollbackInfo }
        $activation = Get-BRAVOUpdatePropertyValue -InputObject $rollbackResult -Name 'taskActivation'
        if ($null -ne $activation) { $resultArguments['TaskActivation'] = $activation }
        $progressStatus = 'Failed'
        if ($status -ceq 'RolledBack') { $progressStatus = 'Completed' }
        Send-BRAVORecoveryProgress -StateRoot $StateRoot -OperationId $operationId -Status $progressStatus -MessageKey 'Recovery.Finished' -Message ('Відновлення завершено зі статусом ' + $status + '.')
        return (New-BRAVOUpdateRecoveryResult @resultArguments)
    }

    # Rollback кинув виняток або повернув неочікуваний підсумок: стан робочої копії
    # невідомий -> Critical, задачі не вмикаємо, а за можливості вимикаємо всі керовані.
    $details = $rollbackError
    if ($null -eq $details) { $details = "rollback повернув статус '$status'." }
    try {
        if ($null -ne (Get-Command -Name 'Disable-BRAVOAllManagedTasks' -ErrorAction SilentlyContinue)) {
            [void](Disable-BRAVOAllManagedTasks -Adapter $Adapter)
        }
    } catch {
        $details = $details + '; вимкнення задач: ' + [string]$_.Exception.Message
    }
    try { [void](Set-BRAVOUpdateJournalState -Journal $Journal -State 'Critical' -StateRoot $StateRoot) } catch { $details = $details + '; журнал: ' + [string]$_.Exception.Message }
    $critical = New-BRAVOUpdateFinding -Id 'Recovery.RollbackFailed' -Severity Blocker `
        -Title 'Відкат перерваної операції не підтверджено' `
        -Meaning 'Стан робочої копії невідомий; керовані задачі лишаються вимкненими. Backup і знімки збережено.' `
        -Action 'Потрібне ручне втручання адміністратора; backup операції не видаляйте.' `
        -Details $details
    return (New-BRAVOUpdateRecoveryResult -OperationId $operationId -Status Critical -Findings @($critical) -Journal $Journal -JournalPath $JournalPath `
        -Rollback ([pscustomobject][ordered]@{ attempted = $true; status = 'Failed'; message = $details }) -StartedUtc $StartedUtc)
}
