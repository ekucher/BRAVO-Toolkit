# BRAVO.Installer.UI.Screens — WinForms-оболонка: головна форма, навігація,
# екрани. Тільки презентація: дані беруться з view-model функцій і з engine
# через дочірній процес (BRAVO.Installer.UI.Engine.ps1).
#
# Важливо (PS 5.1): обробники подій — прості scriptblock-и БЕЗ GetNewClosure
# (замикання ламає резолв приватних функцій модуля). Стан передається через
# $form.Tag (Context), який обробник бере з $sender.FindForm() / $sender.Tag.

# Екрани лівої навігації й екрани майстра (3–10): майстер відкривається діями
# Головної/Maintenance Center і не має власних пунктів навігації.
$script:BRAVOInstallerNavScreenNames = @('Home', 'Preflight', 'Settings', 'Diagnostics', 'Logs')
$script:BRAVOInstallerWizardScreenNames = @('Source', 'Directories', 'Backup', 'Credentials', 'Schedule', 'Plan', 'Progress', 'Result')
$script:BRAVOInstallerScreenNames = @($script:BRAVOInstallerNavScreenNames) + @($script:BRAVOInstallerWizardScreenNames)

function Initialize-BRAVOInstallerWinForms {
    [CmdletBinding()]
    param()
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
}

function Register-BRAVOInstallerControl {
    [CmdletBinding()]
    param([hashtable]$Context, [string]$Name, [object]$Control)
    $Control.Name = $Name
    $Context.Controls[$Name] = $Control
    $Control
}

function New-BRAVOInstallerLabel {
    # Довгі українські підписи переносяться: AutoSize + MaximumSize (ширину
    # оновлює Set-BRAVOInstallerWrapWidth), без фіксованих пікселів під текст.
    [CmdletBinding()]
    param(
        [hashtable]$Context, [string]$Name, [string]$Text,
        [switch]$Bold, [double]$FontScale = 1.0, [int]$WrapWidth = 600
    )
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $true
    $label.Text = $Text
    $label.MaximumSize = New-Object System.Drawing.Size($WrapWidth, 0)
    $label.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    $label.Tag = 'wrap'
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $label.Font = New-Object System.Drawing.Font($label.Font.FontFamily, ([single]($label.Font.Size * $FontScale)), $style)
    [void](Register-BRAVOInstallerControl -Context $Context -Name $Name -Control $label)
    $label
}

function New-BRAVOInstallerButton {
    [CmdletBinding()]
    param(
        [hashtable]$Context, [string]$Name, [string]$Text, [string]$AccessibleName,
        [string]$Key, [AllowNull()][string]$Reason = ''
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.AutoSize = $true
    $button.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $button.UseMnemonic = $true
    $button.Tag = $Key
    $button.AccessibleName = $AccessibleName
    $button.AccessibleRole = [System.Windows.Forms.AccessibleRole]::PushButton
    $button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 6)
    $button.Padding = New-Object System.Windows.Forms.Padding(8, 3, 8, 3)
    if ($Reason) {
        $button.AccessibleDescription = $Reason
        $Context.ToolTip.SetToolTip($button, $Reason)
    }
    $button.add_Click({
        param($sender, $e)
        $form = $sender.FindForm()
        Invoke-BRAVOInstallerAction -Context $form.Tag -Key ([string]$sender.Tag)
    })
    [void](Register-BRAVOInstallerControl -Context $Context -Name $Name -Control $button)
    $button
}

function New-BRAVOInstallerFlow {
    [CmdletBinding()]
    param([ValidateSet('TopDown', 'LeftToRight')][string]$Direction = 'TopDown')
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.FlowDirection = [System.Windows.Forms.FlowDirection]::$Direction
    $flow.WrapContents = ($Direction -eq 'LeftToRight')
    $flow.AutoSize = $true
    $flow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $flow.Dock = [System.Windows.Forms.DockStyle]::Top
    $flow.Margin = New-Object System.Windows.Forms.Padding(0)
    $flow
}

function New-BRAVOInstallerReadOnlyBox {
    # Копійований технічний текст (помилки, JSON): ReadOnly TextBox, не Label.
    [CmdletBinding()]
    param([hashtable]$Context, [string]$Name, [string]$AccessibleName, [int]$Lines = 6)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $box.WordWrap = $false
    $box.Height = [int]($box.Font.Height * $Lines) + 8
    $box.AccessibleName = $AccessibleName
    $box.AccessibleRole = [System.Windows.Forms.AccessibleRole]::Text
    $box.Tag = 'fill'
    $box.Width = 560
    [void](Register-BRAVOInstallerControl -Context $Context -Name $Name -Control $box)
    $box
}

function Set-BRAVOInstallerWrapWidth {
    # Оновлює MaximumSize підписів і ширину 'fill'-контролів під ширину екрана.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Container)
    $scroll = [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth
    $width = [Math]::Max(240, $Container.ClientSize.Width - $scroll - 32)
    $stack = New-Object System.Collections.Stack
    $stack.Push($Container)
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        foreach ($child in $node.Controls) {
            if ($child.Tag -is [string] -and $child.Tag -eq 'wrap') {
                $child.MaximumSize = New-Object System.Drawing.Size($width, 0)
            } elseif ($child.Tag -is [string] -and $child.Tag -eq 'fill') {
                $child.Width = $width
            }
            if ($child.Controls.Count -gt 0) { $stack.Push($child) }
        }
    }
}

function New-BRAVOInstallerScreenPanel {
    [CmdletBinding()]
    param([hashtable]$Context, [string]$Name, [string]$AccessibleName)
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $panel.AutoScroll = $true
    $panel.Padding = New-Object System.Windows.Forms.Padding(16)
    $panel.Visible = $false
    $panel.AccessibleName = $AccessibleName
    $panel.AccessibleRole = [System.Windows.Forms.AccessibleRole]::Pane
    $panel.add_Resize({ param($sender, $e) Set-BRAVOInstallerWrapWidth -Container $sender })
    [void](Register-BRAVOInstallerControl -Context $Context -Name $Name -Control $panel)
    $panel
}

function New-BRAVOInstallerScreenHome {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $panel = New-BRAVOInstallerScreenPanel -Context $Context -Name 'Screen.Home' -AccessibleName 'Головна'
    $flow = New-BRAVOInstallerFlow
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Home.Title' -Text 'BRAVO Toolkit' -Bold -FontScale 1.8))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Home.Version' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Home.Root' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Home.Status' -Text '' -Bold -FontScale 1.2))

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $combo.AccessibleName = 'Каталог встановлення'
    $combo.Visible = $false
    $combo.Width = 480
    [void](Register-BRAVOInstallerControl -Context $Context -Name 'Home.RootChoice' -Control $combo)
    [void]$flow.Controls.Add($combo)

    $actions = New-BRAVOInstallerFlow -Direction LeftToRight
    $primary = New-BRAVOInstallerButton -Context $Context -Name 'Home.Primary' -Text 'Повторити' -AccessibleName 'Основна дія' -Key 'Retry'
    $primary.Font = New-Object System.Drawing.Font($primary.Font, [System.Drawing.FontStyle]::Bold)
    [void]$actions.Controls.Add($primary)
    [void]$flow.Controls.Add($actions)
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Home.Reasons' -Text ''))

    $secondary = New-BRAVOInstallerFlow -Direction LeftToRight
    $secondary.Name = 'Home.Secondary'
    $Context.Controls['Home.Secondary'] = $secondary
    [void]$flow.Controls.Add($secondary)
    [void]$panel.Controls.Add($flow)
    $panel
}

function New-BRAVOInstallerScreenPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $panel = New-BRAVOInstallerScreenPanel -Context $Context -Name 'Screen.Preflight' -AccessibleName 'Перевірка сервера'
    $flow = New-BRAVOInstallerFlow
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Preflight.Title' -Text 'Перевірка сервера' -Bold -FontScale 1.5))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Preflight.Summary' -Text '' -Bold))
    $rows = New-BRAVOInstallerFlow
    $rows.Name = 'Preflight.Rows'
    $Context.Controls['Preflight.Rows'] = $rows
    [void]$flow.Controls.Add($rows)
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Preflight.DetailsCaption' -Text 'Технічні подробиці (можна скопіювати):'))
    [void]$flow.Controls.Add((New-BRAVOInstallerReadOnlyBox -Context $Context -Name 'Preflight.Details' -AccessibleName 'Технічні подробиці перевірки'))
    [void]$flow.Controls.Add((New-BRAVOInstallerButton -Context $Context -Name 'Preflight.Retry' -Text 'По&вторити перевірку' `
        -AccessibleName 'Повторити перевірку' -Key 'RetryPreflight'))
    [void]$panel.Controls.Add($flow)
    $panel
}

function New-BRAVOInstallerScreenSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $panel = New-BRAVOInstallerScreenPanel -Context $Context -Name 'Screen.Settings' -AccessibleName 'Налаштування'
    $flow = New-BRAVOInstallerFlow
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Settings.Title' -Text 'Налаштування' -Bold -FontScale 1.5))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Settings.Info' -Text `
        'Налаштування виконує канонічний BRAVO Configurator. Він відкривається в окремому вікні; Installer не змінює конфігурацію сам.'))
    [void]$flow.Controls.Add((New-BRAVOInstallerButton -Context $Context -Name 'Settings.Open' -Text 'Відкрити &Configurator' `
        -AccessibleName 'Відкрити Configurator' -Key 'OpenConfigurator'))
    [void]$panel.Controls.Add($flow)
    $panel
}

function New-BRAVOInstallerScreenDiagnostics {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $panel = New-BRAVOInstallerScreenPanel -Context $Context -Name 'Screen.Diagnostics' -AccessibleName 'Діагностика'
    $flow = New-BRAVOInstallerFlow
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Diagnostics.Title' -Text 'Діагностика' -Bold -FontScale 1.5))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Diagnostics.Summary' -Text '' -Bold))
    $rows = New-BRAVOInstallerFlow
    $Context.Controls['Diagnostics.Rows'] = $rows
    [void]$flow.Controls.Add($rows)
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Diagnostics.RawCaption' -Text 'Відповідь engine (можна скопіювати):'))
    [void]$flow.Controls.Add((New-BRAVOInstallerReadOnlyBox -Context $Context -Name 'Diagnostics.Raw' -AccessibleName 'Відповідь engine' -Lines 12))
    [void]$flow.Controls.Add((New-BRAVOInstallerButton -Context $Context -Name 'Diagnostics.Refresh' -Text 'Оновити &діагностику' `
        -AccessibleName 'Оновити діагностику' -Key 'Retry'))
    [void]$panel.Controls.Add($flow)
    $panel
}

function New-BRAVOInstallerScreenLogs {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $panel = New-BRAVOInstallerScreenPanel -Context $Context -Name 'Screen.Logs' -AccessibleName 'Журнали'
    $flow = New-BRAVOInstallerFlow
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Logs.Title' -Text 'Журнали' -Bold -FontScale 1.5))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Logs.Path' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerButton -Context $Context -Name 'Logs.Open' -Text 'Відкрити &папку журналів' `
        -AccessibleName 'Відкрити папку журналів' -Key 'OpenLogsFolder'))
    [void]$panel.Controls.Add($flow)
    $panel
}

function Set-BRAVOInstallerFindingRowControl {
    # Перебудовує список рядків «маркер статус — проблема / значення / що зробити».
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Flow, [object[]]$Row, [int]$WrapWidth)
    $Flow.SuspendLayout()
    try {
        foreach ($old in @($Flow.Controls)) { $Flow.Controls.Remove($old); $old.Dispose() }
        foreach ($item in @($Row)) {
            $text = "$($item.Marker) $($item.Status) — $($item.Title)"
            if ($item.Meaning) { $text += [Environment]::NewLine + $item.Meaning }
            if ($item.Action) { $text += [Environment]::NewLine + 'Що зробити: ' + $item.Action }
            $label = New-Object System.Windows.Forms.Label
            $label.AutoSize = $true
            $label.Text = $text
            $label.Tag = 'wrap'
            $label.MaximumSize = New-Object System.Drawing.Size($WrapWidth, 0)
            $label.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
            [void]$Flow.Controls.Add($label)
        }
    } finally {
        $Flow.ResumeLayout()
    }
}

function Get-BRAVOInstallerFindingDetailsText {
    [CmdletBinding()]
    param([object[]]$Row)
    $lines = foreach ($item in @($Row)) {
        if ($item.Details) { "[$($item.Id)] $($item.Details)" }
    }
    (@($lines) -join [Environment]::NewLine)
}

function Update-BRAVOInstallerHomeScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $c = $Context.Controls
    $viewModel = ConvertTo-BRAVOInstallerHomeViewModel -State $Context.State -EngineError $Context.EngineError
    $Context.HomeViewModel = $viewModel
    $c['Home.Title'].Text = $viewModel.Title
    $c['Home.Version'].Text = $viewModel.VersionText
    $c['Home.Root'].Text = $viewModel.RootText
    $c['Home.Status'].Text = "$($viewModel.StatusMarker) $($viewModel.StatusText)"
    if ($Context.Loading) { $c['Home.Status'].Text = '… Визначаємо стан встановлення…' }

    $primary = $c['Home.Primary']
    $primary.Text = $viewModel.PrimaryAction.Label
    $primary.AccessibleName = $viewModel.PrimaryAction.Label
    $primary.Tag = $viewModel.PrimaryAction.Key
    $primary.Enabled = [bool]$viewModel.PrimaryAction.Enabled -and (-not $Context.Busy)
    $primary.AccessibleDescription = $viewModel.PrimaryAction.Reason
    $Context.ToolTip.SetToolTip($primary, $viewModel.PrimaryAction.Reason)

    $combo = $c['Home.RootChoice']
    $combo.Items.Clear()
    $combo.Visible = ($viewModel.StateKey -eq 'Ambiguous')
    foreach ($candidate in $viewModel.Candidates) { [void]$combo.Items.Add($candidate) }
    if ($combo.Items.Count -gt 0) { $combo.SelectedIndex = 0 }

    # ToolTip не показується на вимкнених контролах, тому причину
    # недоступності дублюємо видимим текстом (не лише tooltip).
    $reasons = @()
    if ($viewModel.PrimaryAction.Reason) { $reasons += "$($viewModel.PrimaryAction.Label): $($viewModel.PrimaryAction.Reason)" }

    $flow = $c['Home.Secondary']
    $flow.SuspendLayout()
    try {
        foreach ($old in @($flow.Controls)) { $flow.Controls.Remove($old); $old.Dispose() }
        $index = 0
        foreach ($action in $viewModel.SecondaryActions) {
            $index++
            $button = New-BRAVOInstallerButton -Context $Context -Name ("Home.Secondary.$($action.Key)") -Text $action.Label `
                -AccessibleName $action.Label -Key $action.Key -Reason $action.Reason
            $button.Enabled = [bool]$action.Enabled
            $button.TabIndex = $index
            [void]$flow.Controls.Add($button)
            if ($action.Reason) { $reasons += "$($action.Label): $($action.Reason)" }
        }
    } finally {
        $flow.ResumeLayout()
    }
    $c['Home.Reasons'].Text = (@($reasons) -join [Environment]::NewLine)
}

function Update-BRAVOInstallerPreflightScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $c = $Context.Controls
    $viewModel = ConvertTo-BRAVOInstallerPreflightViewModel -Preflight $Context.Preflight
    $c['Preflight.Summary'].Text = "$($viewModel.SummaryMarker) $($viewModel.SummaryText)"
    Set-BRAVOInstallerFindingRowControl -Flow $c['Preflight.Rows'] -Row $viewModel.Rows -WrapWidth ($c['Preflight.Summary'].MaximumSize.Width)
    $c['Preflight.Details'].Text = Get-BRAVOInstallerFindingDetailsText -Row $viewModel.Rows
    $c['Preflight.Retry'].Enabled = (-not $Context.Busy)
}

function Update-BRAVOInstallerDiagnosticsScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $c = $Context.Controls
    $findings = @(Get-BRAVOInstallerProperty -InputObject $Context.State -Name 'findings' -Default @())
    $rows = @(ConvertTo-BRAVOInstallerFindingRow -Finding $findings)
    if ($null -eq $Context.State) {
        $c['Diagnostics.Summary'].Text = "× Стан engine недоступний. $($Context.EngineError)"
    } elseif ($rows.Count -eq 0) {
        $c['Diagnostics.Summary'].Text = '✓ Engine не повідомив про проблеми.'
    } else {
        $c['Diagnostics.Summary'].Text = "! Знахідок: $($rows.Count)."
    }
    Set-BRAVOInstallerFindingRowControl -Flow $c['Diagnostics.Rows'] -Row $rows -WrapWidth ($c['Diagnostics.Summary'].MaximumSize.Width)
    $raw = ''
    if ($null -ne $Context.State) { $raw = ($Context.State | ConvertTo-Json -Depth 8) }
    $c['Diagnostics.Raw'].Text = $raw
    $c['Diagnostics.Refresh'].Enabled = (-not $Context.Busy)
}

function Update-BRAVOInstallerLogsScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $path = Get-BRAVOInstallerLogsPath -ToolkitRoot $Context.ToolkitRoot -RuntimeRoot ([string]$Context.RuntimeRoot)
    $Context.Controls['Logs.Path'].Text = "Папка журналів: $path"
}

function Update-BRAVOInstallerAllScreens {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    Update-BRAVOInstallerHomeScreen -Context $Context
    Update-BRAVOInstallerPreflightScreen -Context $Context
    Update-BRAVOInstallerDiagnosticsScreen -Context $Context
    Update-BRAVOInstallerLogsScreen -Context $Context
}

function Show-BRAVOInstallerScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Name)
    if ($script:BRAVOInstallerScreenNames -notcontains $Name) { return }
    foreach ($screen in $script:BRAVOInstallerScreenNames) {
        $isActive = ($screen -eq $Name)
        $Context.Controls["Screen.$screen"].Visible = $isActive
        $nav = $Context.Controls["Nav.$screen"]
        # Поточний екран позначаємо жирним шрифтом і AccessibleDescription (не лише кольором).
        $style = if ($isActive) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
        $nav.Font = New-Object System.Drawing.Font($nav.Font, $style)
        $nav.AccessibleDescription = $(if ($isActive) { 'Поточний екран' } else { '' })
    }
    $Context.CurrentScreen = $Name
    Set-BRAVOInstallerWrapWidth -Container $Context.Controls["Screen.$Name"]
}

function Hide-BRAVOInstallerError {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $Context.Controls['Error.Group'].Visible = $false
    $Context.Controls['Error.Box'].Text = ''
}

function Show-BRAVOInstallerError {
    # Технічні подробиці — у копійованому ReadOnly TextBox; фокус переходить
    # на нього (екранний диктор і клавіатура одразу потрапляють на помилку).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Summary,
        [string]$Technical = ''
    )
    $Context.Controls['Error.Summary'].Text = "× $Summary"
    $Context.Controls['Error.Box'].Text = $Technical
    $Context.Controls['Error.Group'].Visible = $true
    [void]$Context.Controls['Error.Box'].Focus()
}

function Set-BRAVOInstallerBusy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [bool]$Busy, [string]$Text = '')
    $Context.Busy = $Busy
    $bar = $Context.Controls['Status.Progress']
    $bar.Visible = $Busy
    $Context.Controls['Status.Text'].Text = $Text
    Update-BRAVOInstallerAllScreens -Context $Context
}

function Start-BRAVOInstallerRefresh {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][ValidateSet('State', 'Preflight')][string]$Action)
    if ($Context.Busy) { return }
    Hide-BRAVOInstallerError -Context $Context
    if (-not (Test-BRAVOInstallerEngineAvailable -ToolkitRoot $Context.ToolkitRoot)) {
        $Context.State = $null
        $Context.Loading = $false
        $Context.EngineError = 'BRAVO_UPDATE.ps1 не знайдено в каталозі комплекту.'
        Update-BRAVOInstallerAllScreens -Context $Context
        return
    }
    try {
        $Context.Job = Start-BRAVOInstallerEngineJob -ToolkitRoot $Context.ToolkitRoot -Action $Action -RuntimeRoot ([string]$Context.RuntimeRoot)
    } catch {
        $Context.Loading = $false
        $Context.EngineError = $_.Exception.Message
        Show-BRAVOInstallerError -Context $Context -Summary 'Не вдалося запустити engine.' -Technical $_.Exception.ToString()
        Update-BRAVOInstallerAllScreens -Context $Context
        return
    }
    $caption = if ($Action -eq 'State') { 'Визначаємо стан встановлення…' } else { 'Виконується перевірка сервера…' }
    Set-BRAVOInstallerBusy -Context $Context -Busy $true -Text $caption
    $Context.Timer.Start()
}

function Update-BRAVOInstallerJobPoll {
    # Викликається таймером (UI-потік); нічого не блокує довше за миттєвий опит.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $job = $Context.Job
    if ($null -eq $job) { $Context.Timer.Stop(); return }
    $status = Get-BRAVOInstallerEngineJobStatus -Handle $job
    if (-not $status.Completed) {
        $progress = ConvertTo-BRAVOInstallerProgressViewModel -ProgressEvent @(Read-BRAVOInstallerProgress -Path $job.ProgressPath)
        $text = "$($progress.Marker) $($progress.Message)"
        if ($status.TimedOut) { $text += ' Engine відповідає довше за очікуване.' }
        $Context.Controls['Status.Text'].Text = $text.Trim()
        $bar = $Context.Controls['Status.Progress']
        if ($progress.Indeterminate) {
            $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        } else {
            $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
            $bar.Value = [int]$progress.Percent
        }
        return
    }
    $Context.Timer.Stop()
    $Context.Job = $null
    Remove-BRAVOInstallerPrivateDirectory -Path $job.PrivateDir
    $errorSummary = ''
    if ($null -ne $status.Data) {
        if ($job.Action -eq 'State') { $Context.State = $status.Data; $Context.EngineError = '' }
        else { $Context.Preflight = $status.Data }
    } else {
        $errorSummary = if ($status.Error) { $status.Error } else { 'Engine не повернув даних.' }
        if ($job.Action -eq 'State') { $Context.State = $null; $Context.EngineError = $errorSummary }
    }
    $Context.Loading = $false
    Set-BRAVOInstallerBusy -Context $Context -Busy $false -Text ''
    if ($errorSummary) {
        $technical = "Код завершення engine: $($status.ExitCode)" + [Environment]::NewLine + "stderr:" + [Environment]::NewLine + $status.StdErr + [Environment]::NewLine + "stdout:" + [Environment]::NewLine + $status.StdOut
        Show-BRAVOInstallerError -Context $Context -Summary $errorSummary -Technical $technical
    }
}

function Invoke-BRAVOInstallerAction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Key)
    switch ($Key) {
        'Retry'          { Start-BRAVOInstallerRefresh -Context $Context -Action 'State' }
        'RetryPreflight' { Start-BRAVOInstallerRefresh -Context $Context -Action 'Preflight' }
        'ViewProblems'   {
            Show-BRAVOInstallerScreen -Context $Context -Name 'Preflight'
            Start-BRAVOInstallerRefresh -Context $Context -Action 'Preflight'
        }
        'Diagnostics'    { Show-BRAVOInstallerScreen -Context $Context -Name 'Diagnostics' }
        'Settings'       { Show-BRAVOInstallerScreen -Context $Context -Name 'Settings' }
        'Logs'           { Show-BRAVOInstallerScreen -Context $Context -Name 'Logs' }
        'SelectRoot'     {
            $choice = $Context.Controls['Home.RootChoice'].SelectedItem
            if ($null -ne $choice) {
                $Context.RuntimeRoot = [string]$choice
                Start-BRAVOInstallerRefresh -Context $Context -Action 'State'
            }
        }
        'OpenConfigurator' {
            try {
                [void](Invoke-BRAVOInstallerCommand -Command (New-BRAVOInstallerConfiguratorCommand -ToolkitRoot $Context.ToolkitRoot))
            } catch {
                Show-BRAVOInstallerError -Context $Context -Summary 'Не вдалося відкрити Configurator.' -Technical $_.Exception.ToString()
            }
        }
        'OpenLogsFolder' {
            $logs = Get-BRAVOInstallerLogsPath -ToolkitRoot $Context.ToolkitRoot -RuntimeRoot ([string]$Context.RuntimeRoot)
            if (-not (Test-Path -LiteralPath $logs -PathType Container)) {
                Show-BRAVOInstallerError -Context $Context -Summary 'Папку журналів не знайдено.' -Technical $logs
            } else {
                try { [void](Invoke-BRAVOInstallerCommand -Command (New-BRAVOInstallerLogsCommand -LogsPath $logs)) }
                catch { Show-BRAVOInstallerError -Context $Context -Summary 'Не вдалося відкрити папку журналів.' -Technical $_.Exception.ToString() }
            }
        }
        default {
            # Mutation-дії в прототипі вимкнені; сюди потрапити не повинні.
            Show-BRAVOInstallerError -Context $Context -Summary $script:BRAVOInstallerPrototypeReason -Technical "Дія: $Key"
        }
    }
}

function New-BRAVOInstallerMainForm {
    <#
    .SYNOPSIS
        Створює головну форму БЕЗ показу (ShowDialog викликає
        Show-BRAVOInstallerMainForm) — придатно для headless-тесту структури.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ToolkitRoot,
        [string]$RuntimeRoot
    )
    Initialize-BRAVOInstallerWinForms
    $context = @{
        ToolkitRoot = $ToolkitRoot; RuntimeRoot = $RuntimeRoot; Controls = @{}
        State = $null; Preflight = $null; EngineError = ''; Job = $null; Busy = $false
        Loading = $true; CurrentScreen = 'Home'; HomeViewModel = $null
        ToolTip = (New-Object System.Windows.Forms.ToolTip); Timer = $null
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'BRAVO Installer'
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $size = Get-BRAVOInstallerStartupSize -WorkingAreaWidth $area.Width -WorkingAreaHeight $area.Height
    $form.MinimumSize = New-Object System.Drawing.Size($size.MinWidth, $size.MinHeight)
    $form.ClientSize = New-Object System.Drawing.Size($size.Width, $size.Height)
    $form.Tag = $context
    $form.AccessibleName = 'BRAVO Installer'

    $outer = New-Object System.Windows.Forms.TableLayoutPanel
    $outer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $outer.ColumnCount = 1
    $outer.RowCount = 3
    [void]$outer.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$outer.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$outer.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $inner = New-Object System.Windows.Forms.TableLayoutPanel
    $inner.Dock = [System.Windows.Forms.DockStyle]::Fill
    $inner.ColumnCount = 2
    $inner.RowCount = 1
    [void]$inner.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$inner.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    # Ліва навігація.
    $nav = New-Object System.Windows.Forms.FlowLayoutPanel
    $nav.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $nav.WrapContents = $false
    $nav.AutoSize = $true
    $nav.Dock = [System.Windows.Forms.DockStyle]::Fill
    $nav.Padding = New-Object System.Windows.Forms.Padding(12)
    $navItems = @(
        @{ Screen = 'Home'; Text = '&Головна'; Accessible = 'Головна' },
        @{ Screen = 'Preflight'; Text = 'Пере&вірка сервера'; Accessible = 'Перевірка сервера' },
        @{ Screen = 'Settings'; Text = '&Налаштування'; Accessible = 'Налаштування' },
        @{ Screen = 'Diagnostics'; Text = '&Діагностика'; Accessible = 'Діагностика' },
        @{ Screen = 'Logs'; Text = '&Журнали'; Accessible = 'Журнали' }
    )
    $tab = 0
    foreach ($item in $navItems) {
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $item.Text
        $button.AutoSize = $true
        $button.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $button.UseMnemonic = $true
        $button.Tag = $item.Screen
        $button.AccessibleName = $item.Accessible
        $button.AccessibleRole = [System.Windows.Forms.AccessibleRole]::PushButton
        $button.TabIndex = $tab
        $button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
        $button.MinimumSize = New-Object System.Drawing.Size(170, 0)
        $button.add_Click({
            param($sender, $e)
            $ctx = $sender.FindForm().Tag
            Show-BRAVOInstallerScreen -Context $ctx -Name ([string]$sender.Tag)
            if ($sender.Tag -eq 'Preflight' -and $null -eq $ctx.Preflight) {
                Start-BRAVOInstallerRefresh -Context $ctx -Action 'Preflight'
            }
        })
        [void](Register-BRAVOInstallerControl -Context $context -Name ("Nav." + $item.Screen) -Control $button)
        [void]$nav.Controls.Add($button)
        $tab++
    }

    # Контент: усі екрани в одному хості, видимий лише активний.
    $host_ = New-Object System.Windows.Forms.Panel
    $host_.Dock = [System.Windows.Forms.DockStyle]::Fill
    $host_.TabIndex = $tab
    foreach ($screen in @(
        (New-BRAVOInstallerScreenHome -Context $context),
        (New-BRAVOInstallerScreenPreflight -Context $context),
        (New-BRAVOInstallerScreenSettings -Context $context),
        (New-BRAVOInstallerScreenDiagnostics -Context $context),
        (New-BRAVOInstallerScreenLogs -Context $context))) {
        [void]$host_.Controls.Add($screen)
    }
    [void]$inner.Controls.Add($nav, 0, 0)
    [void]$inner.Controls.Add($host_, 1, 0)

    # Панель помилки: копійований ReadOnly TextBox (прихована, поки помилки немає).
    $errorGroup = New-Object System.Windows.Forms.GroupBox
    $errorGroup.Text = 'Помилка'
    $errorGroup.AutoSize = $true
    $errorGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $errorGroup.Visible = $false
    $errorGroup.TabIndex = $tab + 1
    $errorFlow = New-BRAVOInstallerFlow
    [void]$errorFlow.Controls.Add((New-BRAVOInstallerLabel -Context $context -Name 'Error.Summary' -Text '' -Bold -WrapWidth 800))
    $errorBox = New-Object System.Windows.Forms.TextBox
    $errorBox.Multiline = $true
    $errorBox.ReadOnly = $true
    $errorBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $errorBox.WordWrap = $false
    $errorBox.Height = $errorBox.Font.Height * 5 + 8
    $errorBox.Width = 800
    $errorBox.AccessibleName = 'Технічні подробиці помилки'
    $errorBox.AccessibleRole = [System.Windows.Forms.AccessibleRole]::Text
    [void](Register-BRAVOInstallerControl -Context $context -Name 'Error.Box' -Control $errorBox)
    [void]$errorFlow.Controls.Add($errorBox)
    [void]$errorGroup.Controls.Add($errorFlow)
    $context.Controls['Error.Group'] = $errorGroup

    # Рядок стану: текст + прогрес (marquee, якщо відсоток невідомий).
    $statusFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $statusFlow.AutoSize = $true
    $statusFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusFlow.Padding = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $bar.Visible = $false
    $bar.AccessibleName = 'Хід виконання'
    $bar.TabStop = $false
    [void](Register-BRAVOInstallerControl -Context $context -Name 'Status.Progress' -Control $bar)
    [void]$statusFlow.Controls.Add($bar)
    [void]$statusFlow.Controls.Add((New-BRAVOInstallerLabel -Context $context -Name 'Status.Text' -Text '' -WrapWidth 800))

    [void]$outer.Controls.Add($inner, 0, 0)
    [void]$outer.Controls.Add($errorGroup, 0, 1)
    [void]$outer.Controls.Add($statusFlow, 0, 2)
    [void]$form.Controls.Add($outer)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Tag = $context
    $timer.add_Tick({ param($sender, $e) Update-BRAVOInstallerJobPoll -Context $sender.Tag })
    $context.Timer = $timer

    $form.add_Shown({
        param($sender, $e)
        Start-BRAVOInstallerRefresh -Context $sender.Tag -Action 'State'
    })
    $form.add_FormClosed({
        param($sender, $e)
        $ctx = $sender.Tag
        $ctx.Timer.Stop()
        $ctx.Timer.Dispose()
        if ($null -ne $ctx.Job) { Remove-BRAVOInstallerPrivateDirectory -Path $ctx.Job.PrivateDir }
    })

    # Початковий вміст до першої відповіді engine.
    Update-BRAVOInstallerAllScreens -Context $context
    Show-BRAVOInstallerScreen -Context $context -Name 'Home'
    $form
}

function Show-BRAVOInstallerMainForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ToolkitRoot,
        [string]$RuntimeRoot
    )
    Initialize-BRAVOInstallerWinForms
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $form = New-BRAVOInstallerMainForm -ToolkitRoot $ToolkitRoot -RuntimeRoot $RuntimeRoot
    try {
        [void]$form.ShowDialog()
    } finally {
        $form.Dispose()
    }
    'Closed'
}
