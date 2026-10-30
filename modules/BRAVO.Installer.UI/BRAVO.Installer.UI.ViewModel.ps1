# BRAVO.Installer.UI.ViewModel — чисті view-model функції (без WinForms, без
# I/O). GUI — лише frontend: тут немає політики розгортання, defaults,
# hash/provenance чи exit-кодів; лише відображення даних engine (InstallationState,
# PreflightResult) у текст + маркер + дозволені дії (docs\installer\CONTRACTS.md).

$script:BRAVOInstallerRepeatBlockedReason = 'Повторну операцію заблоковано: після критичного результату потрібна ручна перевірка.'

function Get-BRAVOInstallerProperty {
    # StrictMode 2.0: доступ до відсутньої властивості PSCustomObject кидає
    # виняток, а JSON від engine може бути частковим/старшим — читаємо безпечно.
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function New-BRAVOInstallerAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [string]$Reason = ''
    )
    [pscustomobject]@{ Key = $Key; Label = $Label; Enabled = $Enabled; Reason = $Reason }
}

function New-BRAVOInstallerMutationAction {
    # Mutation-дії лише ВІДКРИВАЮТЬ майстер або запускають engine через UAC:
    # самі вони нічого не змінюють. -BlockedReason (напр. після Critical)
    # вимикає дію з видимою причиною (fail closed).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$BlockedReason = ''
    )
    if ($BlockedReason) {
        return (New-BRAVOInstallerAction -Key $Key -Label $Label -Enabled $false -Reason $BlockedReason)
    }
    New-BRAVOInstallerAction -Key $Key -Label $Label -Enabled $true
}

function Get-BRAVOInstallerSecondaryAction {
    [CmdletBinding()]
    param([bool]$HasRoot, [bool]$RecoveryPending)
    $settings = if (-not $HasRoot) {
        New-BRAVOInstallerAction -Key 'Settings' -Label 'Налаштування' -Enabled $false -Reason 'Спершу встановіть BRAVO Toolkit'
    } elseif ($RecoveryPending) {
        New-BRAVOInstallerAction -Key 'Settings' -Label 'Налаштування' -Enabled $false -Reason 'Спершу завершіть відновлення'
    } else {
        New-BRAVOInstallerAction -Key 'Settings' -Label 'Налаштування' -Enabled $true
    }
    @(
        $settings,
        (New-BRAVOInstallerAction -Key 'Diagnostics' -Label 'Діагностика' -Enabled $true),
        (New-BRAVOInstallerAction -Key 'Logs' -Label 'Журнали' -Enabled $true)
    )
}

function ConvertTo-BRAVOInstallerHomeViewModel {
    <#
    .SYNOPSIS
        Екран 1 «Головна» (план §5): InstallationState -> текст, маркер,
        primary/secondary дії. Чиста функція. $State = $null означає, що engine
        недоступний або повернув непридатні дані (fail closed, не вгадуємо стан).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$State = $null,
        [string]$EngineError = '',
        [switch]$RepeatBlocked
    )

    # Після Critical (або невідомого результату) повторні Install/Update/Repair
    # заблоковані до ручної перевірки (план §5 екран 10); Recover лишається.
    $blocked = ''
    if ($RepeatBlocked) { $blocked = $script:BRAVOInstallerRepeatBlockedReason }

    $stateKey = [string](Get-BRAVOInstallerProperty -InputObject $State -Name 'state' -Default '')
    $root = Get-BRAVOInstallerProperty -InputObject $State -Name 'runtimeRoot'
    $version = Get-BRAVOInstallerProperty -InputObject $State -Name 'version'
    $packageVersion = [string](Get-BRAVOInstallerProperty -InputObject $version -Name 'packageVersion' -Default '')
    $channel = [string](Get-BRAVOInstallerProperty -InputObject $version -Name 'releaseChannel' -Default '')
    $candidates = @(Get-BRAVOInstallerProperty -InputObject $State -Name 'candidateRoots' -Default @() | Where-Object { $null -ne $_ })
    $findings = @(Get-BRAVOInstallerProperty -InputObject $State -Name 'findings' -Default @() | Where-Object { $null -ne $_ })
    $integrity = [string](Get-BRAVOInstallerProperty -InputObject (Get-BRAVOInstallerProperty -InputObject $State -Name 'integrity') -Name 'status' -Default 'Unknown')
    $targetVersion = [string](Get-BRAVOInstallerProperty -InputObject $State -Name 'targetVersion' -Default '')
    $interrupted = Get-BRAVOInstallerProperty -InputObject $State -Name 'interruptedOperation'

    $versionText = if ($packageVersion) {
        if ($channel) { "Версія: $packageVersion ($channel)" } else { "Версія: $packageVersion" }
    } else { 'Версія: невідома' }
    $rootText = if ($root) { "Каталог встановлення: $root" } else { 'Каталог встановлення: не визначено' }

    $statusText = ''
    $marker = '×'
    $primary = $null
    $recovery = $false
    $secondaryExtra = @()

    if ($null -eq $State -or [string]::IsNullOrWhiteSpace($stateKey)) {
        $stateKey = 'EngineUnavailable'
        $statusText = 'Engine недоступний: стан встановлення не визначено.'
        if ($EngineError) { $statusText = "$statusText $EngineError" }
        $primary = New-BRAVOInstallerAction -Key 'Retry' -Label 'Повторити' -Enabled $true
    } else {
        switch ($stateKey) {
            'NotInstalled' {
                $marker = '—'
                $statusText = 'BRAVO Toolkit не встановлено.'
                $primary = New-BRAVOInstallerMutationAction -Key 'Install' -Label 'Встановити' -BlockedReason $blocked
            }
            'Installed' {
                if ($integrity -eq 'Valid') { $marker = '✓'; $statusText = 'Встановлено. Цілісність підтверджена.' }
                else { $marker = '!'; $statusText = 'Встановлено, але цілісність не підтверджена.' }
                $primary = New-BRAVOInstallerMutationAction -Key 'CheckUpdates' -Label 'Перевірити оновлення' -BlockedReason $blocked
            }
            'PrereleaseInstalled' {
                $marker = '!'
                $statusText = 'Встановлено попередню (не stable) версію.'
                $primary = New-BRAVOInstallerMutationAction -Key 'CheckUpdates' -Label 'Перевірити оновлення' -BlockedReason $blocked
            }
            'UpdateAvailable' {
                $marker = '!'
                if ($targetVersion) {
                    # Назву «Оновити до» показуємо лише коли engine довів ціль (план §5).
                    $statusText = "Доступне оновлення до $targetVersion."
                    $primary = New-BRAVOInstallerMutationAction -Key 'Update' -Label "Оновити до $targetVersion" -BlockedReason $blocked
                } else {
                    $statusText = 'Є ознаки оновлення, але цільову версію не підтверджено.'
                    $primary = New-BRAVOInstallerMutationAction -Key 'CheckUpdates' -Label 'Перевірити оновлення' -BlockedReason $blocked
                }
            }
            'Degraded' {
                $marker = '!'
                $statusText = 'Встановлено з проблемами: потрібна увага оператора.'
                $primary = New-BRAVOInstallerAction -Key 'ViewProblems' -Label 'Переглянути проблеми' -Enabled $true
                $secondaryExtra = @(New-BRAVOInstallerMutationAction -Key 'Repair' -Label 'Відновити компоненти' -BlockedReason $blocked)
            }
            'RepairRequired' {
                $marker = '×'
                $statusText = 'Потрібне відновлення: цілісність комплекту порушена.'
                $primary = New-BRAVOInstallerMutationAction -Key 'Repair' -Label 'Відновити компоненти' -BlockedReason $blocked
                $secondaryExtra = @(New-BRAVOInstallerAction -Key 'ViewProblems' -Label 'Переглянути проблеми' -Enabled $true)
            }
            'InterruptedUpdate' {
                $recovery = $true
                $marker = '×'
                $phase = [string](Get-BRAVOInstallerProperty -InputObject $interrupted -Name 'lastCompletedPhase' -Default '')
                $statusText = 'Знайдено перерване оновлення (зміни ще не починались). Спершу завершіть відновлення.'
                if ($phase) { $statusText = "$statusText Остання фаза: $phase." }
                $primary = New-BRAVOInstallerMutationAction -Key 'Recover' -Label 'Відновити після переривання'
            }
            'RollbackRequired' {
                $recovery = $true
                $marker = '×'
                $statusText = 'Оновлення перервано після початку змін: потрібен відкат. Спершу завершіть відновлення.'
                $primary = New-BRAVOInstallerMutationAction -Key 'Rollback' -Label 'Завершити відкат'
            }
            'Ambiguous' {
                $marker = '!'
                $statusText = 'Знайдено кілька каталогів встановлення. Оберіть потрібний, нічого не вгадуємо.'
                $selectReason = ''
                if ($candidates.Count -eq 0) { $selectReason = 'Engine не повернув жодного каталогу' }
                $primary = New-BRAVOInstallerAction -Key 'SelectRoot' -Label 'Оберіть каталог встановлення' `
                    -Enabled ($candidates.Count -gt 0) -Reason $selectReason
            }
            'Unsupported' {
                $marker = '×'
                $statusText = 'Ця система не підтримується Installer. Див. «Діагностика» для причини.'
                $primary = New-BRAVOInstallerAction -Key 'Diagnostics' -Label 'Показати причину' -Enabled $true
            }
            default {
                # Невідомий стан — fail closed: не показуємо його як здоровий.
                $marker = '×'
                $statusText = "Невідомий стан engine: $stateKey."
                $primary = New-BRAVOInstallerAction -Key 'Retry' -Label 'Повторити' -Enabled $true
            }
        }
    }

    $secondary = @($secondaryExtra) + @(Get-BRAVOInstallerSecondaryAction -HasRoot ([bool]$root) -RecoveryPending $recovery)

    [pscustomobject]@{
        StateKey         = $stateKey
        Title            = 'BRAVO Toolkit'
        VersionText      = $versionText
        RootText         = $rootText
        StatusText       = $statusText
        StatusMarker     = $marker
        PrimaryAction    = $primary
        SecondaryActions = @($secondary)
        Candidates       = @($candidates | ForEach-Object { [string]$_ })
        FindingsCount    = $findings.Count
        RecoveryFirst    = $recovery
    }
}

function ConvertTo-BRAVOInstallerSeverityDisplay {
    # Статус завжди текст + маркер, не лише колір (UX). Невідомий severity —
    # fail closed як блокування.
    [CmdletBinding()]
    param([AllowNull()][string]$Severity)
    switch ($Severity) {
        'Ok'            { [pscustomobject]@{ Marker = '✓'; Text = 'Готово' } }
        'Warning'       { [pscustomobject]@{ Marker = '!'; Text = 'Потрібна дія' } }
        'Blocker'       { [pscustomobject]@{ Marker = '×'; Text = 'Заблоковано' } }
        'NotApplicable' { [pscustomobject]@{ Marker = '—'; Text = 'Не застосовується' } }
        default         { [pscustomobject]@{ Marker = '×'; Text = 'Невідомий статус' } }
    }
}

function ConvertTo-BRAVOInstallerFindingRow {
    # Finding (CONTRACTS §2) -> рядок «проблема -> значення -> що зробити».
    [CmdletBinding()]
    param([AllowNull()][object[]]$Finding)
    $rows = @()
    foreach ($item in @($Finding)) {
        if ($null -eq $item) { continue }
        $severity = [string](Get-BRAVOInstallerProperty -InputObject $item -Name 'severity' -Default '')
        $display = ConvertTo-BRAVOInstallerSeverityDisplay -Severity $severity
        $action = [string](Get-BRAVOInstallerProperty -InputObject $item -Name 'action' -Default '')
        if ([string]::IsNullOrWhiteSpace($action) -and $display.Marker -eq '×') {
            $action = 'Дія не вказана engine. Скопіюйте технічні подробиці й зверніться до оператора.'
        }
        $title = [string](Get-BRAVOInstallerProperty -InputObject $item -Name 'title' -Default '')
        if ([string]::IsNullOrWhiteSpace($title)) { $title = [string](Get-BRAVOInstallerProperty -InputObject $item -Name 'id' -Default 'Без назви') }
        $rows += [pscustomobject]@{
            Id       = [string](Get-BRAVOInstallerProperty -InputObject $item -Name 'id' -Default '')
            Severity = $severity
            Marker   = $display.Marker
            Status   = $display.Text
            Title    = $title
            Meaning  = [string](Get-BRAVOInstallerProperty -InputObject $item -Name 'meaning' -Default '')
            Action   = $action
            Details  = [string](Get-BRAVOInstallerProperty -InputObject $item -Name 'details' -Default '')
        }
    }
    @($rows)
}

function ConvertTo-BRAVOInstallerPreflightViewModel {
    <#
    .SYNOPSIS
        Екран 2 «Перевірка сервера»: PreflightResult -> рядки + підсумок.
        $Preflight = $null — перевірку ще не виконано.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Preflight = $null)

    $rows = @(ConvertTo-BRAVOInstallerFindingRow -Finding @(Get-BRAVOInstallerProperty -InputObject $Preflight -Name 'findings' -Default @()))
    $retry = New-BRAVOInstallerAction -Key 'RetryPreflight' -Label 'Повторити перевірку' -Enabled $true

    if ($null -eq $Preflight) {
        return [pscustomobject]@{
            Rows = @(); SummaryMarker = '—'; SummaryText = 'Перевірку ще не виконано.'
            BlockerCount = 0; WarningCount = 0; CanProceed = $false; RetryAction = $retry
        }
    }

    $blockers = @($rows | Where-Object { $_.Marker -eq '×' }).Count
    $warnings = @($rows | Where-Object { $_.Marker -eq '!' }).Count
    # Лічильник engine, якщо він більший, не перекриваємо меншим значенням.
    $engineBlockers = Get-BRAVOInstallerProperty -InputObject $Preflight -Name 'blockerCount'
    if ($null -ne $engineBlockers -and [int]$engineBlockers -gt $blockers) { $blockers = [int]$engineBlockers }
    $canProceed = ($blockers -eq 0) -and ([bool](Get-BRAVOInstallerProperty -InputObject $Preflight -Name 'canProceed' -Default $false))

    if ($blockers -gt 0) { $marker = '×'; $text = "Заблоковано: блокуючих проблем $blockers, попереджень $warnings." }
    elseif ($warnings -gt 0) { $marker = '!'; $text = "Потрібна дія: попереджень $warnings." }
    elseif ($canProceed) { $marker = '✓'; $text = 'Сервер готовий.' }
    else { $marker = '!'; $text = 'Engine не підтвердив готовність (canProceed не встановлено).' }

    [pscustomobject]@{
        Rows = @($rows); SummaryMarker = $marker; SummaryText = $text
        BlockerCount = $blockers; WarningCount = $warnings; CanProceed = $canProceed; RetryAction = $retry
    }
}

function ConvertTo-BRAVOInstallerProgressViewModel {
    <#
    .SYNOPSIS
        Остання ProgressEvent -> текст. Невідомий percent = indeterminate
        (Percent = $null), ніколи не вигадуємо відсоток (план §9).
    #>
    [CmdletBinding()]
    param([AllowNull()][object[]]$ProgressEvent)
    $last = $null
    foreach ($item in @($ProgressEvent)) { if ($null -ne $item) { $last = $item } }
    if ($null -eq $last) {
        return [pscustomobject]@{ Phase = ''; Message = 'Очікуємо відповідь engine…'; Percent = $null; Indeterminate = $true; Marker = '…' }
    }
    $status = [string](Get-BRAVOInstallerProperty -InputObject $last -Name 'status' -Default '')
    $percentRaw = Get-BRAVOInstallerProperty -InputObject $last -Name 'percent'
    $percent = $null
    if ($null -ne $percentRaw) {
        $parsed = 0
        if ([int]::TryParse([string]$percentRaw, [ref]$parsed)) { $percent = [Math]::Max(0, [Math]::Min(100, $parsed)) }
    }
    $marker = switch ($status) {
        'Completed' { '✓' }
        'Failed'    { '×' }
        'Skipped'   { '—' }
        default     { '…' }
    }
    [pscustomobject]@{
        Phase         = [string](Get-BRAVOInstallerProperty -InputObject $last -Name 'phase' -Default '')
        Message       = [string](Get-BRAVOInstallerProperty -InputObject $last -Name 'message' -Default '')
        Percent       = $percent
        Indeterminate = ($null -eq $percent)
        Marker        = $marker
    }
}

function Get-BRAVOInstallerStartupSize {
    # Безпечний початковий розмір: не більший за робочу область, не менший
    # за практичний мінімум, коли область це дозволяє (1024x768 @100%).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$WorkingAreaWidth,
        [Parameter(Mandatory = $true)][int]$WorkingAreaHeight,
        [int]$PreferredWidth = 1100,
        [int]$PreferredHeight = 720,
        [int]$MinWidth = 900,
        [int]$MinHeight = 600
    )
    $width = [Math]::Min($PreferredWidth, $WorkingAreaWidth)
    $height = [Math]::Min($PreferredHeight, $WorkingAreaHeight)
    $effectiveMinWidth = [Math]::Min($MinWidth, $WorkingAreaWidth)
    $effectiveMinHeight = [Math]::Min($MinHeight, $WorkingAreaHeight)
    [pscustomobject]@{
        Width     = [Math]::Max($width, $effectiveMinWidth)
        Height    = [Math]::Max($height, $effectiveMinHeight)
        MinWidth  = $effectiveMinWidth
        MinHeight = $effectiveMinHeight
    }
}
