# BRAVO.Update.Repair — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Same-version repair (ENGINE_DESIGN §8.2): ядро Invoke-BRAVODeployment з
# action=Repair; ця частина додає лише те, що специфічне для repair:
#   - ідентичність пакета: packageVersion, sourceCommit, buildId == встановлений
#     VERSION.json (інакше Repair.VersionMismatch / Repair.IdentityUnproven) —
#     repair НІКОЛИ не є прихованим upgrade/downgrade;
#   - збереження site-конфігурації за хешем (baseline до, перевірка після);
#   - Scope All|Runtime|Scheduler, що передається ядру;
#   - повідомлення «runtime лишився пошкодженим» після rollback.
#
# Залежності від інших частин (викликаються за іменем, assumptions для HANDOFF):
#   Invoke-BRAVODeployment (Deploy, E2): приймає -Plan -Adapter -RuntimeRoot
#     -StateRoot -LockRoot -StagingRoot -BackupRoot -OperationLockPath
#     -VersionStatePath [-SourcePath] [-FaultInjection] і ОПЦІЙНИЙ -Scope
#     (All|Runtime|Scheduler); для action=Repair ядро на кроці U6 викликає
#     Test-BRAVORepairIdentity з цього файлу для staged runtime й трактує
#     IsMatch=$false як blocker до mutation.
#   Get-BRAVOSiteConfigurationBaseline / Test-BRAVOSiteConfigurationPreserved
#     (Reconcile, E3).

$script:BRAVORepairScopes = @('All', 'Runtime', 'Scheduler')
$script:BRAVORepairIdentityFields = @('packageVersion', 'sourceCommit', 'buildId')

function Get-BRAVORepairIdentity {
    <#
    .SYNOPSIS
        Читає { packageVersion, sourceCommit, buildId } з VERSION.json у корені як ДАНІ.
    .DESCRIPTION
        Повертає { Proven, Values, Problem }. Proven=$false, якщо файл відсутній,
        пошкоджений або будь-яке з трьох полів порожнє: ідентичність без доказів
        не вважається збіжною (fail closed, R3).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    $values = [ordered]@{ packageVersion = ''; sourceCommit = ''; buildId = '' }
    $read = Read-BRAVOUpdateDiscoveryJson -Path (Join-Path $Root 'VERSION.json')
    if (-not $read.Present) { return [pscustomobject]@{ Proven = $false; Values = $values; Problem = 'VERSION.json відсутній' } }
    if (-not $read.Valid) { return [pscustomobject]@{ Proven = $false; Values = $values; Problem = ('VERSION.json нечитаний: ' + [string]$read.Error) } }
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($field in $script:BRAVORepairIdentityFields) {
        $text = ''
        $property = $read.Data.PSObject.Properties[$field]
        if ($null -ne $property -and $null -ne $property.Value) { $text = ([string]$property.Value).Trim() }
        if ($text -eq '') { $missing.Add($field) }
        $values[$field] = $text
    }
    if ($missing.Count -gt 0) {
        return [pscustomobject]@{ Proven = $false; Values = $values; Problem = ('у VERSION.json немає полів: ' + ($missing.ToArray() -join ', ')) }
    }
    return [pscustomobject]@{ Proven = $true; Values = $values; Problem = '' }
}

function Test-BRAVORepairIdentity {
    <#
    .SYNOPSIS
        Порівнює ідентичність staged runtime зі встановленим (INS-070/071).
    .DESCRIPTION
        Повертає { IsMatch, Findings[] }. Нечитаний/неповний VERSION.json з будь-якого
        боку -> Repair.IdentityUnproven; розбіжність будь-якого з packageVersion,
        sourceCommit, buildId -> Repair.VersionMismatch (з переліком полів без
        секретів). Порівняння ординальне й регістро-чутливе: «схожий» build не збіг.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstalledRuntimeRoot,
        [Parameter(Mandatory = $true)][string]$StagedRoot
    )

    $findings = New-Object 'System.Collections.Generic.List[object]'
    $installed = Get-BRAVORepairIdentity -Root $InstalledRuntimeRoot
    $staged = Get-BRAVORepairIdentity -Root $StagedRoot
    if (-not $installed.Proven) {
        $findings.Add((New-BRAVOUpdateFinding -Id 'Repair.IdentityUnproven' -Severity Blocker `
            -Title 'Не вдалося довести ідентичність встановленої версії' `
            -Meaning 'Repair можливий лише для тієї самої збірки; без VERSION.json це неможливо перевірити, а оновлення тут не виконується.' `
            -Action 'Відновіть VERSION.json зі збірки тієї самої версії вручну або виконайте окреме оновлення (Update).' `
            -Details ('встановлений runtime: ' + $installed.Problem)))
    }
    if (-not $staged.Proven) {
        $findings.Add((New-BRAVOUpdateFinding -Id 'Repair.IdentityUnproven' -Severity Blocker `
            -Title 'Не вдалося довести ідентичність пакета для repair' `
            -Meaning 'Пакет не містить повного VERSION.json, тож невідомо, чи це та сама збірка.' `
            -Action 'Використайте пакет тієї самої збірки (packageVersion, sourceCommit, buildId) з перевіреним manifest.' `
            -Details ('staged runtime: ' + $staged.Problem)))
    }
    if ($installed.Proven -and $staged.Proven) {
        $different = New-Object 'System.Collections.Generic.List[string]'
        foreach ($field in $script:BRAVORepairIdentityFields) {
            if (-not ([string]$installed.Values[$field]).Equals([string]$staged.Values[$field], [StringComparison]::Ordinal)) {
                $different.Add(('{0}: встановлено={1}; пакет={2}' -f $field, $installed.Values[$field], $staged.Values[$field]))
            }
        }
        if ($different.Count -gt 0) {
            $findings.Add((New-BRAVOUpdateFinding -Id 'Repair.VersionMismatch' -Severity Blocker `
                -Title 'Пакет не збігається зі встановленою збіркою' `
                -Meaning 'Repair не виконує оновлення чи відкат версії: файли беруться лише з тієї самої збірки.' `
                -Action 'Для іншої версії скористайтеся Update, для repair візьміть пакет встановленої збірки.' `
                -Details ($different.ToArray() -join '; ')))
        }
    }
    return [pscustomobject]@{ IsMatch = ($findings.Count -eq 0); Findings = $findings.ToArray() }
}

function New-BRAVORepairResult {
    # Failed/Blocked без mutation, коли repair відхилено ДО виклику ядра.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][object[]]$Findings,
        [Parameter(Mandatory = $true)][string]$StartedUtc
    )

    $operationId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'operationId' -Default '')
    if (-not (Test-BRAVOUpdateGuidText -Value $operationId)) { $operationId = [guid]::NewGuid().ToString() }
    $planId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'planId' -Default '')
    if (-not (Test-BRAVOUpdateGuidText -Value $planId)) { $planId = '' }
    return (New-BRAVOUpdateDeploymentResult -OperationId $operationId -PlanId $planId -Action Repair -Status Failed -ReasonCode Blocked `
        -SourceVersion (Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'currentVersion') `
        -TargetVersion (Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'targetVersion') `
        -Findings $Findings -StartedUtc $StartedUtc)
}

function Repair-BRAVOInstallation {
    <#
    .SYNOPSIS
        Same-version repair встановлення (ENGINE_DESIGN §8.2).
    .DESCRIPTION
        До виклику ядра (без жодних змін, без журналу): action плану == Repair,
        VERSION.json встановлення доведений, plan.currentVersion/targetVersion/
        source.packageVersion == встановлений packageVersion (інакше
        Repair.VersionMismatch/Repair.IdentityUnproven). Далі ядро
        Invoke-BRAVODeployment з action=Repair; перевірка sourceCommit/buildId
        staged runtime відбувається в ядрі через Test-BRAVORepairIdentity.
        Scope Runtime|Scheduler без підтримки -Scope у ядрі відхиляється (fail
        closed: ніколи не виконуємо ширшу дію, ніж просили). Після успіху хеші
        site-конфігурації мають збігатись із baseline до repair; інакше Critical.
        Integrity=Invalid не блокує (саме її виправляє repair); unknown scripts лишаються
        blocker-ом ядра.
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
        [ValidateSet('All', 'Runtime', 'Scheduler')][string]$Scope = 'All',
        [hashtable]$FaultInjection = $null
    )

    $startedUtc = Get-BRAVOUpdateUtcNowText

    # Корені: явні параметри > план > Get-BRAVOUpdateDefaultPaths (єдине джерело production-шляхів).
    $defaults = Get-BRAVOUpdateDefaultPaths
    if ($RuntimeRoot -eq '') { $RuntimeRoot = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'runtimeRoot' -Default '') }
    if ($StagingRoot -eq '') { $StagingRoot = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'stagingRoot' -Default '') }
    if ($BackupRoot -eq '') { $BackupRoot = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'backupRoot' -Default '') }
    if ($StagingRoot -eq '') { $StagingRoot = [string]$defaults.StagingRoot }
    if ($BackupRoot -eq '') { $BackupRoot = [string]$defaults.BackupRoot }
    if ($StateRoot -eq '') { $StateRoot = [string]$defaults.StateRoot }
    if ($LockRoot -eq '') { $LockRoot = [string]$defaults.LockRoot }
    if ($OperationLockPath -eq '') { $OperationLockPath = [string]$defaults.OperationLockPath }
    if ($VersionStatePath -eq '') { $VersionStatePath = [string]$defaults.VersionStatePath }

    $rejected = New-Object 'System.Collections.Generic.List[object]'
    if ((Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'action' -Default '') -cne 'Repair') {
        $rejected.Add((New-BRAVOUpdateFinding -Id 'Repair.WrongPlanAction' -Severity Blocker `
            -Title 'План не є планом repair' `
            -Meaning 'Repair-BRAVOInstallation приймає лише план з action=Repair.' `
            -Action 'Побудуйте новий план repair.'))
    }
    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $rejected.Add((New-BRAVOUpdateFinding -Id 'Repair.RuntimeRootMissing' -Severity Blocker `
            -Title 'Не задано каталог встановлення' `
            -Meaning 'Repair працює лише з наявним встановленням.' `
            -Action 'Вкажіть RuntimeRoot встановленого комплекту.'))
    }
    if ($rejected.Count -gt 0) { return (New-BRAVORepairResult -Plan $Plan -Findings $rejected.ToArray() -StartedUtc $startedUtc) }

    # Ідентичність на рівні плану: до staging і будь-яких змін.
    $installed = Get-BRAVORepairIdentity -Root $RuntimeRoot
    if (-not $installed.Proven) {
        $rejected.Add((New-BRAVOUpdateFinding -Id 'Repair.IdentityUnproven' -Severity Blocker `
            -Title 'Не вдалося довести ідентичність встановленої версії' `
            -Meaning 'Repair можливий лише для тієї самої збірки; без VERSION.json це неможливо перевірити, а оновлення тут не виконується.' `
            -Action 'Відновіть VERSION.json зі збірки тієї самої версії вручну або виконайте окреме оновлення (Update).' `
            -Details ('встановлений runtime: ' + $installed.Problem)))
    } else {
        $sourceInfo = Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'source'
        $planVersions = [ordered]@{
            currentVersion = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'currentVersion' -Default '')
            targetVersion  = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'targetVersion' -Default '')
            sourcePackage  = [string](Get-BRAVOUpdatePropertyValue -InputObject $sourceInfo -Name 'packageVersion' -Default '')
        }
        $different = New-Object 'System.Collections.Generic.List[string]'
        foreach ($name in $planVersions.Keys) {
            if (-not ([string]$planVersions[$name]).Equals([string]$installed.Values['packageVersion'], [StringComparison]::Ordinal)) {
                $different.Add(('{0}={1}' -f $name, $planVersions[$name]))
            }
        }
        if ($different.Count -gt 0) {
            $rejected.Add((New-BRAVOUpdateFinding -Id 'Repair.VersionMismatch' -Severity Blocker `
                -Title 'План repair не збігається зі встановленою версією' `
                -Meaning 'Repair не виконує оновлення чи відкат версії.' `
                -Action 'Для іншої версії скористайтеся Update; для repair побудуйте новий план на встановленій збірці.' `
                -Details ('встановлено=' + $installed.Values['packageVersion'] + '; ' + ($different.ToArray() -join '; '))))
        }
    }
    if ($rejected.Count -gt 0) { return (New-BRAVORepairResult -Plan $Plan -Findings $rejected.ToArray() -StartedUtc $startedUtc) }

    # Залежності: fail closed, якщо потрібних функцій інших частин немає.
    $core = Get-Command -Name 'Invoke-BRAVODeployment' -ErrorAction SilentlyContinue
    if ($null -eq $core) {
        $rejected.Add((New-BRAVOUpdateFinding -Id 'Repair.CoreUnavailable' -Severity Blocker `
            -Title 'Ядро розгортання недоступне' -Meaning 'Repair використовує спільне ядро Invoke-BRAVODeployment.' -Action 'Переконайтесь, що модуль BRAVO.Update завантажено повністю.'))
    } elseif ((-not $core.Parameters.ContainsKey('Scope')) -and ($Scope -cne 'All')) {
        $rejected.Add((New-BRAVOUpdateFinding -Id 'Repair.ScopeUnsupported' -Severity Blocker `
            -Title ('Ядро не підтримує область repair ' + $Scope) -Meaning 'Виконання ширшої дії, ніж запитано, заборонене.' -Action 'Використайте -Scope All або оновіть модуль.'))
    }
    foreach ($dependency in @('Get-BRAVOSiteConfigurationBaseline', 'Test-BRAVOSiteConfigurationPreserved')) {
        if ($null -eq (Get-Command -Name $dependency -ErrorAction SilentlyContinue)) {
            $rejected.Add((New-BRAVOUpdateFinding -Id 'Repair.SiteConfigGuardUnavailable' -Severity Blocker `
                -Title 'Перевірка збереження конфігурації недоступна' -Meaning 'Без хешів site-конфігурації repair не запускається.' -Action 'Переконайтесь, що модуль BRAVO.Update завантажено повністю.' -Details $dependency))
        }
    }
    if ($rejected.Count -gt 0) { return (New-BRAVORepairResult -Plan $Plan -Findings $rejected.ToArray() -StartedUtc $startedUtc) }

    $baseline = Get-BRAVOSiteConfigurationBaseline -RuntimeRoot $RuntimeRoot

    $arguments = @{
        Plan              = $Plan
        Adapter           = $Adapter
        RuntimeRoot       = $RuntimeRoot
        StateRoot         = $StateRoot
        LockRoot          = $LockRoot
        StagingRoot       = $StagingRoot
        BackupRoot        = $BackupRoot
        OperationLockPath = $OperationLockPath
        VersionStatePath  = $VersionStatePath
    }
    if ($SourcePath -ne '') { $arguments['SourcePath'] = $SourcePath }
    if ($null -ne $FaultInjection) { $arguments['FaultInjection'] = $FaultInjection }
    if ($core.Parameters.ContainsKey('Scope')) { $arguments['Scope'] = $Scope }
    $result = Invoke-BRAVODeployment @arguments
    if ($null -eq $result) { throw 'BRAVO.Update: Invoke-BRAVODeployment не повернула результат.' }

    $status = [string](Get-BRAVOUpdatePropertyValue -InputObject $result -Name 'status' -Default '')
    $extra = New-Object 'System.Collections.Generic.List[object]'
    if (@('Success', 'SuccessWithWarnings') -ccontains $status) {
        # Друга лінія захисту поверх SiteConfigPreserved ядра: repair не має права змінити локальну конфігурацію.
        $check = Test-BRAVOSiteConfigurationPreserved -RuntimeRoot $RuntimeRoot -Baseline $baseline
        if ([string](Get-BRAVOUpdatePropertyValue -InputObject $check -Name 'status' -Default '') -cne 'Pass') {
            $broken = New-BRAVOUpdateFinding -Id 'Repair.SiteConfigChanged' -Severity Blocker `
                -Title 'Site-конфігурація змінилась під час repair' `
                -Meaning 'Хеш локальної конфігурації не збігається з baseline до repair; стан не підтверджено.' `
                -Action 'Порівняйте BRAVO.local.config із резервною копією операції та відновіть вручну.' `
                -Details ([string](Get-BRAVOUpdatePropertyValue -InputObject $check -Name 'message' -Default ''))
            $existing = @()
            $existingValue = Get-BRAVOUpdatePropertyValue -InputObject $result -Name 'findings'
            if ($null -ne $existingValue) { $existing = @($existingValue) }
            return (New-BRAVOUpdateDeploymentResult -OperationId ([string]$result.operationId) -PlanId ([string](Get-BRAVOUpdatePropertyValue -InputObject $result -Name 'planId' -Default '')) `
                -Action Repair -Status Critical -SourceVersion (Get-BRAVOUpdatePropertyValue -InputObject $result -Name 'sourceVersion') `
                -TargetVersion (Get-BRAVOUpdatePropertyValue -InputObject $result -Name 'targetVersion') -InstalledVersion (Get-BRAVOUpdatePropertyValue -InputObject $result -Name 'installedVersion') `
                -LastPhase ([string](Get-BRAVOUpdatePropertyValue -InputObject $result -Name 'lastPhase' -Default '')) -MutationStarted $true `
                -Findings @($existing + $broken) -JournalPath ([string](Get-BRAVOUpdatePropertyValue -InputObject $result -Name 'journalPath' -Default '')) -StartedUtc ([string]$result.startedUtc))
        }
    }
    if ($status -ceq 'RolledBack') {
        # Rollback repair повертає runtime до стану ДО repair, тобто пошкодженого: оператор має це знати.
        $extra.Add((New-BRAVOUpdateFinding -Id 'Repair.RuntimeStillDamaged' -Severity Warning `
            -Title 'Repair відкочено: runtime лишився пошкодженим, як і до repair' `
            -Meaning 'Файли повернено до стану до спроби; пошкодження, через які запускався repair, не усунуто.' `
            -Action 'Усуньте причину збою зі звіту та повторіть repair із новим планом.'))
        $findingsValue = Get-BRAVOUpdatePropertyValue -InputObject $result -Name 'findings'
        $result.findings = @(@($findingsValue | Where-Object { $null -ne $_ }) + $extra.ToArray())
    }
    return $result
}
