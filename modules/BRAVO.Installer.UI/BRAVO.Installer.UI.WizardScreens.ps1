# BRAVO.Installer.UI.WizardScreens — WinForms-екрани майстра 3–10 і дії
# Maintenance Center. Тільки презентація: дані — з view-model функцій
# (WizardModel), виконання — окремий процес engine (WizardEngine).
# Правила ті ж, що в Screens.ps1: прості scriptblock-обробники БЕЗ
# GetNewClosure (стан — через $form.Tag), текст + маркер, AccessibleName,
# без блокування UI-потоку довгими діями, без політики в GUI.

function New-BRAVOInstallerWizardState {
    # Введення оператора між кроками майстра. Секретів тут немає за
    # конструкцією (жодного поля під пароль/токен).
    [CmdletBinding()]
    param()
    @{
        Operation = 'Install'; Screen = 'Source'; Updating = $false
        SourceKind = 'Online'; Tag = ''; ZipPath = ''
        AdvancedExpanded = $false; AllowPrerelease = $false; PrereleaseAck = $false
        RuntimeRoot = ''; BackupMode = 'Cloud'; RunSelfTest = $false
        Plan = $null; PlanPayload = $null; PlanLines = @(); PlanError = ''; PlanConfirmed = $false
    }
}

# ------------------------------------------------------- Контроли-помічники

function New-BRAVOInstallerTextBox {
    [CmdletBinding()]
    param([hashtable]$Context, [string]$Name, [string]$AccessibleName, [int]$Width = 480)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Width = $Width
    $box.AccessibleName = $AccessibleName
    $box.AccessibleRole = [System.Windows.Forms.AccessibleRole]::Text
    $box.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 6)
    $box.add_TextChanged({
        param($sender, $e)
        $form = $sender.FindForm()
        if ($null -ne $form) { Update-BRAVOInstallerWizardInput -Context $form.Tag }
    })
    [void](Register-BRAVOInstallerControl -Context $Context -Name $Name -Control $box)
    $box
}

function New-BRAVOInstallerCheckBox {
    [CmdletBinding()]
    param([hashtable]$Context, [string]$Name, [string]$Text, [string]$AccessibleName)
    $check = New-Object System.Windows.Forms.CheckBox
    $check.AutoSize = $true
    $check.Text = $Text
    $check.MaximumSize = New-Object System.Drawing.Size(600, 0)
    $check.Tag = 'wrap'
    $check.UseMnemonic = $true
    $check.AccessibleName = $AccessibleName
    $check.AccessibleRole = [System.Windows.Forms.AccessibleRole]::CheckButton
    $check.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    $check.add_CheckedChanged({
        param($sender, $e)
        $form = $sender.FindForm()
        if ($null -ne $form) { Update-BRAVOInstallerWizardInput -Context $form.Tag }
    })
    [void](Register-BRAVOInstallerControl -Context $Context -Name $Name -Control $check)
    $check
}

function New-BRAVOInstallerRadioButton {
    [CmdletBinding()]
    param([hashtable]$Context, [string]$Name, [string]$Text, [string]$AccessibleName)
    $radio = New-Object System.Windows.Forms.RadioButton
    $radio.AutoSize = $true
    $radio.Text = $Text
    $radio.UseMnemonic = $true
    $radio.AccessibleName = $AccessibleName
    $radio.AccessibleRole = [System.Windows.Forms.AccessibleRole]::RadioButton
    $radio.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 6)
    $radio.add_CheckedChanged({
        param($sender, $e)
        $form = $sender.FindForm()
        if ($null -ne $form -and $sender.Checked) { Update-BRAVOInstallerWizardInput -Context $form.Tag }
    })
    [void](Register-BRAVOInstallerControl -Context $Context -Name $Name -Control $radio)
    $radio
}

function Set-BRAVOInstallerTabOrder {
    # Послідовний TabIndex у порядку візуального обходу (WinForms сам його
    # не призначає для контролів, створених кодом).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Container)
    $counter = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push($Container)
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        $children = @($node.Controls)
        foreach ($child in $children) {
            $child.TabIndex = $counter
            $counter++
        }
        for ($i = $children.Count - 1; $i -ge 0; $i--) { if ($children[$i].Controls.Count -gt 0) { $stack.Push($children[$i]) } }
    }
}

function Add-BRAVOInstallerWizardHeader {
    [CmdletBinding()]
    param([hashtable]$Context, [object]$Flow, [string]$Screen, [string]$Title)
    [void]$Flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name "$Screen.Step" -Text '' -FontScale 0.95))
    [void]$Flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name "$Screen.Title" -Text $Title -Bold -FontScale 1.5))
}

function Add-BRAVOInstallerWizardFooter {
    # Назад/Далі в кінці екрана; на екрані плану «Далі» = виконання.
    [CmdletBinding()]
    param([hashtable]$Context, [object]$Flow, [string]$Screen)
    $footer = New-BRAVOInstallerFlow -Direction LeftToRight
    $footer.Name = "$Screen.Footer"
    $nextKey = 'WizardNext'
    if ($Screen -eq 'Plan') { $nextKey = 'Execute' }
    [void]$footer.Controls.Add((New-BRAVOInstallerButton -Context $Context -Name "$Screen.Back" -Text '&Назад' -AccessibleName 'Назад' -Key 'WizardBack'))
    [void]$footer.Controls.Add((New-BRAVOInstallerButton -Context $Context -Name "$Screen.Next" -Text 'Д&алі' -AccessibleName 'Далі' -Key $nextKey))
    [void]$Flow.Controls.Add($footer)
}

function Set-BRAVOInstallerWizardFooter {
    [CmdletBinding()]
    param([hashtable]$Context, [string]$Screen, [bool]$NextEnabled, [string]$NextReason = '', [string]$NextLabel = '')
    $c = $Context.Controls
    $step = ConvertTo-BRAVOInstallerWizardStepViewModel -Operation $Context.Wizard.Operation -Screen $Screen
    $c["$Screen.Step"].Text = $step.Text
    $back = $c["$Screen.Back"]
    $next = $c["$Screen.Next"]
    $back.Text = $(if ($null -eq $step.PreviousKey) { 'До &головної' } else { '&Назад' })
    $back.AccessibleName = $(if ($null -eq $step.PreviousKey) { 'До головної' } else { 'Назад' })
    $back.Enabled = (-not $Context.Busy)
    if ([string]::IsNullOrEmpty($NextLabel)) { $NextLabel = $step.NextLabel }
    $next.Text = $NextLabel
    $next.AccessibleName = $NextLabel
    $next.Enabled = ($NextEnabled -and -not $Context.Busy)
    $next.AccessibleDescription = $NextReason
    $Context.ToolTip.SetToolTip($next, $NextReason)
}

function Get-BRAVOInstallerContextStateRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    if (-not [string]::IsNullOrWhiteSpace([string]$Context.StateRootOverride)) { return [string]$Context.StateRootOverride }
    Get-BRAVOInstallerStateRoot -ToolkitRoot $Context.ToolkitRoot
}

function Get-BRAVOInstallerKnownRuntimeRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $root = [string](Get-BRAVOInstallerProperty -InputObject $Context.State -Name 'runtimeRoot' -Default '')
    if ([string]::IsNullOrEmpty($root)) { $root = [string](Get-BRAVOInstallerProperty -InputObject $Context.Wizard.Plan -Name 'runtimeRoot' -Default '') }
    if ([string]::IsNullOrEmpty($root)) { $root = [string]$Context.RuntimeRoot }
    $root
}

# ------------------------------------------------------------- Екрани

function New-BRAVOInstallerScreenSource {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $panel = New-BRAVOInstallerScreenPanel -Context $Context -Name 'Screen.Source' -AccessibleName 'Версія та джерело'
    $flow = New-BRAVOInstallerFlow
    Add-BRAVOInstallerWizardHeader -Context $Context -Flow $flow -Screen 'Source' -Title 'Версія та джерело'
    $kinds = New-BRAVOInstallerFlow -Direction LeftToRight
    [void]$kinds.Controls.Add((New-BRAVOInstallerRadioButton -Context $Context -Name 'Source.KindOnline' -Text 'Завантажити з GitHub &Releases' -AccessibleName 'Джерело: онлайн'))
    [void]$kinds.Controls.Add((New-BRAVOInstallerRadioButton -Context $Context -Name 'Source.KindLocal' -Text '&Локальний ZIP-пакет' -AccessibleName 'Джерело: локальний ZIP'))
    [void]$flow.Controls.Add($kinds)
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Source.TagCaption' -Text 'Тег релізу (vX.Y.Z):'))
    [void]$flow.Controls.Add((New-BRAVOInstallerTextBox -Context $Context -Name 'Source.Tag' -AccessibleName 'Тег релізу'))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Source.TagHint' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Source.ZipCaption' -Text 'ZIP-пакет релізу:'))
    $zipRow = New-BRAVOInstallerFlow -Direction LeftToRight
    [void](Register-BRAVOInstallerControl -Context $Context -Name 'Source.ZipRow' -Control $zipRow)
    [void]$zipRow.Controls.Add((New-BRAVOInstallerTextBox -Context $Context -Name 'Source.Zip' -AccessibleName 'Шлях до ZIP-пакета'))
    [void]$zipRow.Controls.Add((New-BRAVOInstallerButton -Context $Context -Name 'Source.Browse' -Text 'О&гляд…' -AccessibleName 'Обрати ZIP-пакет' -Key 'BrowseZip'))
    [void]$flow.Controls.Add($zipRow)
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Source.ZipHint' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerCheckBox -Context $Context -Name 'Source.Advanced' -Text '&Розширено' -AccessibleName 'Розширені параметри джерела'))
    $advanced = New-BRAVOInstallerFlow
    [void](Register-BRAVOInstallerControl -Context $Context -Name 'Source.AdvancedGroup' -Control $advanced)
    [void]$advanced.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Source.PrereleaseWarning' -Text ''))
    [void]$advanced.Controls.Add((New-BRAVOInstallerCheckBox -Context $Context -Name 'Source.AllowPrerelease' -Text 'Дозволити &попередню (prerelease) версію' -AccessibleName 'Дозволити попередню версію'))
    [void]$advanced.Controls.Add((New-BRAVOInstallerCheckBox -Context $Context -Name 'Source.PrereleaseAck' -Text 'Я розумію ризик використання попередньої версії' -AccessibleName 'Підтверджую ризик попередньої версії'))
    [void]$flow.Controls.Add($advanced)
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Source.Problems' -Text '' -Bold))
    Add-BRAVOInstallerWizardFooter -Context $Context -Flow $flow -Screen 'Source'
    [void]$panel.Controls.Add($flow)
    Set-BRAVOInstallerTabOrder -Container $panel
    $panel
}

function New-BRAVOInstallerScreenDirectories {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $panel = New-BRAVOInstallerScreenPanel -Context $Context -Name 'Screen.Directories' -AccessibleName 'Каталоги та компоненти'
    $flow = New-BRAVOInstallerFlow
    Add-BRAVOInstallerWizardHeader -Context $Context -Flow $flow -Screen 'Directories' -Title 'Каталоги та знайдені компоненти'
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Directories.RootCaption' -Text 'Каталог встановлення (runtime):'))
    [void]$flow.Controls.Add((New-BRAVOInstallerTextBox -Context $Context -Name 'Directories.Root' -AccessibleName 'Каталог встановлення'))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Directories.RootNote' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Directories.Separation' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Directories.ComponentsCaption' -Text 'Знайдені компоненти (лише перегляд):' -Bold))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Directories.Components' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Directories.Problems' -Text '' -Bold))
    Add-BRAVOInstallerWizardFooter -Context $Context -Flow $flow -Screen 'Directories'
    [void]$panel.Controls.Add($flow)
    Set-BRAVOInstallerTabOrder -Container $panel
    $panel
}

function New-BRAVOInstallerScreenBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $panel = New-BRAVOInstallerScreenPanel -Context $Context -Name 'Screen.Backup' -AccessibleName 'Резервні копії'
    $flow = New-BRAVOInstallerFlow
    Add-BRAVOInstallerWizardHeader -Context $Context -Flow $flow -Screen 'Backup' -Title 'Де зберігати резервні копії'
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Backup.ModeCaption' -Text 'Призначення резервних копій:'))
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $combo.Width = 360
    $combo.AccessibleName = 'Призначення резервних копій'
    foreach ($mode in @(Get-BRAVOInstallerBackupModeList)) { [void]$combo.Items.Add($mode.Label) }
    $combo.add_SelectedIndexChanged({
        param($sender, $e)
        $form = $sender.FindForm()
        if ($null -ne $form) { Update-BRAVOInstallerWizardInput -Context $form.Tag }
    })
    [void](Register-BRAVOInstallerControl -Context $Context -Name 'Backup.Mode' -Control $combo)
    [void]$flow.Controls.Add($combo)
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Backup.Canonical' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Backup.Summary' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Backup.Warning' -Text '' -Bold))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Backup.AdvancedHint' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerButton -Context $Context -Name 'Backup.Advanced' -Text 'Розширені на&лаштування' `
        -AccessibleName 'Розширені налаштування (Configurator)' -Key 'OpenConfigurator'))
    Add-BRAVOInstallerWizardFooter -Context $Context -Flow $flow -Screen 'Backup'
    [void]$panel.Controls.Add($flow)
    Set-BRAVOInstallerTabOrder -Container $panel
    $panel
}

function New-BRAVOInstallerScreenCredentials {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $panel = New-BRAVOInstallerScreenPanel -Context $Context -Name 'Screen.Credentials' -AccessibleName 'Облікові дані та сповіщення'
    $flow = New-BRAVOInstallerFlow
    Add-BRAVOInstallerWizardHeader -Context $Context -Flow $flow -Screen 'Credentials' -Title 'Облікові дані та сповіщення'
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Credentials.Status' -Text '' -Bold))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Credentials.Rows' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Credentials.Note' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Credentials.PostInstall' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerButton -Context $Context -Name 'Credentials.Enter' -Text 'Ввести &облікові дані' `
        -AccessibleName 'Ввести облікові дані' -Key 'EnterCredentials'))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Credentials.Reason' -Text ''))
    Add-BRAVOInstallerWizardFooter -Context $Context -Flow $flow -Screen 'Credentials'
    [void]$panel.Controls.Add($flow)
    Set-BRAVOInstallerTabOrder -Container $panel
    $panel
}

function New-BRAVOInstallerScreenSchedule {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $panel = New-BRAVOInstallerScreenPanel -Context $Context -Name 'Screen.Schedule' -AccessibleName 'Розклад'
    $flow = New-BRAVOInstallerFlow
    Add-BRAVOInstallerWizardHeader -Context $Context -Flow $flow -Screen 'Schedule' -Title 'Розклад'
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Schedule.Tasks' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Schedule.PolicyCaption' -Text 'Коли завдання розкладу вмикаються:' -Bold))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Schedule.Policy' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Schedule.Notes' -Text ''))
    Add-BRAVOInstallerWizardFooter -Context $Context -Flow $flow -Screen 'Schedule'
    [void]$panel.Controls.Add($flow)
    Set-BRAVOInstallerTabOrder -Container $panel
    $panel
}

function New-BRAVOInstallerScreenPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $panel = New-BRAVOInstallerScreenPanel -Context $Context -Name 'Screen.Plan' -AccessibleName 'План змін'
    $flow = New-BRAVOInstallerFlow
    Add-BRAVOInstallerWizardHeader -Context $Context -Flow $flow -Screen 'Plan' -Title 'План змін'
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Plan.Status' -Text '' -Bold))
    [void]$flow.Controls.Add((New-BRAVOInstallerReadOnlyBox -Context $Context -Name 'Plan.Text' -AccessibleName 'Текст плану змін' -Lines 16))
    $rows = New-BRAVOInstallerFlow
    $rows.Name = 'Plan.Findings'
    $Context.Controls['Plan.Findings'] = $rows
    [void]$flow.Controls.Add($rows)
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Plan.Uac' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerCheckBox -Context $Context -Name 'Plan.SelfTest' -Text 'Після розгортання виконати повний самотест (довше)' -AccessibleName 'Виконати самотест після розгортання'))
    [void]$flow.Controls.Add((New-BRAVOInstallerCheckBox -Context $Context -Name 'Plan.Confirm' -Text 'Я переглянув план' -AccessibleName 'Я переглянув план'))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Plan.Reason' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerButton -Context $Context -Name 'Plan.Rebuild' -Text '&Сформувати план знову' `
        -AccessibleName 'Сформувати план знову' -Key 'RebuildPlan'))
    Add-BRAVOInstallerWizardFooter -Context $Context -Flow $flow -Screen 'Plan'
    [void]$panel.Controls.Add($flow)
    Set-BRAVOInstallerTabOrder -Container $panel
    $panel
}

function New-BRAVOInstallerScreenProgress {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $panel = New-BRAVOInstallerScreenPanel -Context $Context -Name 'Screen.Progress' -AccessibleName 'Виконання'
    $flow = New-BRAVOInstallerFlow
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Progress.Step' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Progress.Title' -Text 'Виконання' -Bold -FontScale 1.5))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Progress.Phases' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Progress.Current' -Text '' -Bold))
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Width = 480
    $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $bar.AccessibleName = 'Хід виконання операції'
    $bar.AccessibleRole = [System.Windows.Forms.AccessibleRole]::ProgressBar
    $bar.TabStop = $false
    [void](Register-BRAVOInstallerControl -Context $Context -Name 'Progress.Bar' -Control $bar)
    [void]$flow.Controls.Add($bar)
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Progress.Elapsed' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Progress.Heartbeat' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerButton -Context $Context -Name 'Progress.Cancel' -Text 'С&касувати' -AccessibleName 'Скасувати' -Key 'Cancel'))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Progress.CancelNote' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerCheckBox -Context $Context -Name 'Progress.ShowDetails' -Text 'Показати &технічні подробиці' -AccessibleName 'Показати технічні подробиці'))
    [void]$flow.Controls.Add((New-BRAVOInstallerReadOnlyBox -Context $Context -Name 'Progress.Details' -AccessibleName 'Технічні подробиці виконання' -Lines 10))
    $Context.Controls['Progress.Details'].Visible = $false
    [void]$panel.Controls.Add($flow)
    Set-BRAVOInstallerTabOrder -Container $panel
    $panel
}

function New-BRAVOInstallerScreenResult {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $panel = New-BRAVOInstallerScreenPanel -Context $Context -Name 'Screen.Result' -AccessibleName 'Результат'
    $flow = New-BRAVOInstallerFlow
    $banner = New-Object System.Windows.Forms.Panel
    $banner.AutoSize = $true
    $banner.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $banner.Padding = New-Object System.Windows.Forms.Padding(10)
    $banner.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $banner.AccessibleName = 'Підсумок результату'
    $banner.AccessibleRole = [System.Windows.Forms.AccessibleRole]::Pane
    [void](Register-BRAVOInstallerControl -Context $Context -Name 'Result.Banner' -Control $banner)
    [void]$banner.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Result.Title' -Text '' -Bold -FontScale 1.4))
    [void]$flow.Controls.Add($banner)
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Result.Body' -Text ''))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Result.Tasks' -Text '' -Bold))
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Result.Validation' -Text ''))
    $findings = New-BRAVOInstallerFlow
    $findings.Name = 'Result.Findings'
    $Context.Controls['Result.Findings'] = $findings
    [void]$flow.Controls.Add($findings)
    $actions = New-BRAVOInstallerFlow -Direction LeftToRight
    $actions.Name = 'Result.Actions'
    $Context.Controls['Result.Actions'] = $actions
    [void]$flow.Controls.Add($actions)
    [void]$flow.Controls.Add((New-BRAVOInstallerLabel -Context $Context -Name 'Result.DetailsCaption' -Text 'Технічні подробиці (можна скопіювати; секретів немає):'))
    [void]$flow.Controls.Add((New-BRAVOInstallerReadOnlyBox -Context $Context -Name 'Result.Details' -AccessibleName 'Технічні подробиці результату' -Lines 10))
    [void]$panel.Controls.Add($flow)
    Set-BRAVOInstallerTabOrder -Container $panel
    $panel
}

# ------------------------------------------------------------ Оновлення

function Sync-BRAVOInstallerWizardInput {
    # Зчитує значення контролів поточного екрана в стан майстра.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $c = $Context.Controls
    $w = $Context.Wizard
    switch ($w.Screen) {
        'Source' {
            $w.SourceKind = $(if ($c['Source.KindLocal'].Checked) { 'Local' } else { 'Online' })
            $w.Tag = [string]$c['Source.Tag'].Text
            $w.ZipPath = [string]$c['Source.Zip'].Text
            $w.AdvancedExpanded = [bool]$c['Source.Advanced'].Checked
            $w.AllowPrerelease = [bool]$c['Source.AllowPrerelease'].Checked
            $w.PrereleaseAck = [bool]$c['Source.PrereleaseAck'].Checked
        }
        'Directories' { if ($c['Directories.Root'].Enabled) { $w.RuntimeRoot = [string]$c['Directories.Root'].Text } }
        'Backup' {
            $modes = @(Get-BRAVOInstallerBackupModeList)
            $index = $c['Backup.Mode'].SelectedIndex
            if ($index -ge 0 -and $index -lt $modes.Count) { $w.BackupMode = $modes[$index].Key }
        }
        'Plan' {
            $w.PlanConfirmed = [bool]$c['Plan.Confirm'].Checked
            $w.RunSelfTest = [bool]$c['Plan.SelfTest'].Checked
        }
    }
}

function Update-BRAVOInstallerWizardInput {
    # Обробник змін контролів: синхронізація й перемальовування (із захистом
    # від рекурсії, бо перемальовування теж змінює контроли).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    if ($Context.Wizard.Updating) { return }
    Sync-BRAVOInstallerWizardInput -Context $Context
    Update-BRAVOInstallerWizardScreens -Context $Context
}

function Update-BRAVOInstallerSourceScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $c = $Context.Controls
    $w = $Context.Wizard
    $vm = ConvertTo-BRAVOInstallerSourceViewModel -Operation $w.Operation -SourceKind $w.SourceKind -Tag $w.Tag -ZipPath $w.ZipPath `
        -AdvancedExpanded $w.AdvancedExpanded -AllowPrerelease $w.AllowPrerelease -PrereleaseAcknowledged $w.PrereleaseAck
    $c['Source.Title'].Text = $vm.Title
    $c['Source.KindOnline'].Checked = ($vm.SourceKind -eq 'Online')
    $c['Source.KindLocal'].Checked = ($vm.SourceKind -eq 'Local')
    foreach ($pair in @(@('Source.Tag', $w.Tag), @('Source.Zip', $w.ZipPath))) {
        if ($c[$pair[0]].Text -ne [string]$pair[1]) { $c[$pair[0]].Text = [string]$pair[1] }
    }
    foreach ($name in @('Source.TagCaption', 'Source.Tag', 'Source.TagHint')) { $c[$name].Visible = $vm.TagVisible }
    foreach ($name in @('Source.ZipCaption', 'Source.ZipHint')) { $c[$name].Visible = $vm.ZipVisible }
    $c['Source.ZipRow'].Visible = $vm.ZipVisible
    $c['Source.TagHint'].Text = $vm.OnlineHint
    $c['Source.ZipHint'].Text = $vm.OfflineHint
    $c['Source.Advanced'].Checked = $vm.AdvancedExpanded
    $c['Source.AdvancedGroup'].Visible = $vm.PrereleaseControlsVisible
    $c['Source.PrereleaseWarning'].Text = $vm.PrereleaseWarning
    $c['Source.AllowPrerelease'].Checked = $w.AllowPrerelease
    $c['Source.PrereleaseAck'].Checked = $w.PrereleaseAck
    $c['Source.PrereleaseAck'].Enabled = $w.AllowPrerelease
    $c['Source.Problems'].Text = $(if ($vm.Problems.Count -gt 0) { '× ' + (@($vm.Problems) -join [Environment]::NewLine + '× ') } else { '' })
    Set-BRAVOInstallerWizardFooter -Context $Context -Screen 'Source' -NextEnabled $vm.CanContinue -NextReason $(if ($vm.CanContinue) { '' } else { 'Виправте поля вище' })
}

function Update-BRAVOInstallerDirectoriesScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $c = $Context.Controls
    $w = $Context.Wizard
    $default = ''
    try { $default = [string](Invoke-BRAVOInstallerUpdateRead -ToolkitRoot $Context.ToolkitRoot -Name 'Get-BRAVOUpdateDefaultPaths').RuntimeRoot } catch { $default = '' }
    $vm = ConvertTo-BRAVOInstallerDirectoriesViewModel -Operation $w.Operation -State $Context.State -DefaultRuntimeRoot $default -ChosenRuntimeRoot $w.RuntimeRoot
    $box = $c['Directories.Root']
    $box.Enabled = $vm.RuntimeEditable
    if ($box.Text -ne $vm.RuntimeRoot) { $box.Text = $vm.RuntimeRoot }
    if ($vm.RuntimeEditable -and [string]::IsNullOrEmpty($w.RuntimeRoot)) { $w.RuntimeRoot = $vm.RuntimeRoot }
    $c['Directories.RootNote'].Text = $vm.RuntimeNote
    $c['Directories.Separation'].Text = $vm.SeparationNote
    $componentText = (@($vm.Components | ForEach-Object { $_.Text }) -join [Environment]::NewLine)
    if (-not $componentText) { $componentText = $vm.ComponentsNote }
    $c['Directories.Components'].Text = $componentText
    $c['Directories.Problems'].Text = $(if ($vm.Problems.Count -gt 0) { '× ' + (@($vm.Problems) -join [Environment]::NewLine + '× ') } else { '' })
    Set-BRAVOInstallerWizardFooter -Context $Context -Screen 'Directories' -NextEnabled $vm.CanContinue -NextReason $(if ($vm.CanContinue) { '' } else { 'Виправте шлях вище' })
}

function Update-BRAVOInstallerBackupScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $c = $Context.Controls
    $vm = ConvertTo-BRAVOInstallerBackupViewModel -Mode $Context.Wizard.BackupMode
    $index = 0
    $modes = @($vm.Modes)
    for ($i = 0; $i -lt $modes.Count; $i++) { if ($modes[$i].Key -eq $vm.Mode) { $index = $i } }
    if ($c['Backup.Mode'].SelectedIndex -ne $index) { $c['Backup.Mode'].SelectedIndex = $index }
    $c['Backup.Canonical'].Text = 'Канонічний режим: ' + $vm.CanonicalName
    $c['Backup.Summary'].Text = 'Підсумок увімкнень:' + [Environment]::NewLine + (@($vm.EffectiveSummary) -join [Environment]::NewLine)
    $c['Backup.Warning'].Text = $(if ($vm.Warning) { '! ' + $vm.Warning } else { '' })
    $c['Backup.AdvancedHint'].Text = $vm.AdvancedHint
    Set-BRAVOInstallerWizardFooter -Context $Context -Screen 'Backup' -NextEnabled $vm.CanContinue
}

function Update-BRAVOInstallerCredentialsScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $c = $Context.Controls
    $root = [string](Get-BRAVOInstallerProperty -InputObject $Context.State -Name 'runtimeRoot' -Default '')
    $available = ((-not [string]::IsNullOrEmpty($root)) -and (Test-Path -LiteralPath (Join-Path $root 'BRAVO_SETUP.ps1') -PathType Leaf))
    $vm = ConvertTo-BRAVOInstallerCredentialsViewModel -State $Context.State -SetupAvailable $available
    $c['Credentials.Status'].Text = $vm.StatusText
    $c['Credentials.Rows'].Text = (@($vm.Rows | ForEach-Object { $_.Text }) -join [Environment]::NewLine)
    $c['Credentials.Note'].Text = $vm.Note
    $c['Credentials.PostInstall'].Text = $vm.PostInstall
    $c['Credentials.Enter'].Enabled = ($vm.EnterAction.Enabled -and -not $Context.Busy)
    $c['Credentials.Reason'].Text = $vm.EnterAction.Reason
    Set-BRAVOInstallerWizardFooter -Context $Context -Screen 'Credentials' -NextEnabled $true
}

function Update-BRAVOInstallerScheduleScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $c = $Context.Controls
    $vm = ConvertTo-BRAVOInstallerScheduleViewModel -Operation $Context.Wizard.Operation -State $Context.State
    $tasks = (@($vm.Rows | ForEach-Object { $_.Text }) -join [Environment]::NewLine)
    if (-not $tasks) { $tasks = $vm.EmptyNote }
    $c['Schedule.Tasks'].Text = $tasks
    $c['Schedule.Policy'].Text = (@($vm.PolicyLines) -join [Environment]::NewLine)
    $c['Schedule.Notes'].Text = $vm.NoAutoRunNote + [Environment]::NewLine + $vm.RestoreVerifyNote
    Set-BRAVOInstallerWizardFooter -Context $Context -Screen 'Schedule' -NextEnabled $true -NextLabel 'Далі: план змін'
}

function Update-BRAVOInstallerPlanScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $c = $Context.Controls
    $w = $Context.Wizard
    $vm = ConvertTo-BRAVOInstallerPlanViewModel -Plan $w.Plan -PlanLine @($w.PlanLines) -Confirmed $w.PlanConfirmed -ErrorText $w.PlanError -Operation $w.Operation
    $statusText = "$($vm.StatusMarker) $($vm.StatusText)"
    if ($Context.Busy -and $null -ne $Context.Job) { $statusText = '… Формуємо план змін: engine перевіряє джерело й сервер…' }
    $c['Plan.Status'].Text = $statusText
    $c['Plan.Text'].Text = (@($vm.Lines) -join [Environment]::NewLine)
    $rows = @($vm.FindingRows)
    if ($rows.Count -eq 0 -and $null -eq $w.Plan -and $null -ne $w.PlanPayload) {
        $rows = @(ConvertTo-BRAVOInstallerFindingRow -Finding @(Get-BRAVOInstallerProperty -InputObject $w.PlanPayload -Name 'findings' -Default @()))
    }
    Set-BRAVOInstallerFindingRowControl -Flow $c['Plan.Findings'] -Row $rows -WrapWidth ($c['Plan.Status'].MaximumSize.Width)
    $c['Plan.Uac'].Text = $vm.UacNote + [Environment]::NewLine + $vm.PlanChangedNote
    $confirm = $c['Plan.Confirm']
    $confirm.Text = $vm.ConfirmText
    $confirm.Enabled = ($vm.CanConfirm -and -not $Context.Busy)
    if ($confirm.Checked -ne [bool]$w.PlanConfirmed) { $confirm.Checked = [bool]$w.PlanConfirmed }
    $c['Plan.SelfTest'].Enabled = $vm.CanConfirm
    $c['Plan.Reason'].Text = $(if ($vm.ExecuteAction.Reason) { $vm.ExecuteAction.Label + ': ' + $vm.ExecuteAction.Reason } else { '' })
    $c['Plan.Rebuild'].Enabled = (-not $Context.Busy)
    Set-BRAVOInstallerWizardFooter -Context $Context -Screen 'Plan' -NextEnabled $vm.ExecuteAction.Enabled -NextReason $vm.ExecuteAction.Reason -NextLabel $vm.ExecuteAction.Label
}

function Update-BRAVOInstallerProgressScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][object]$ViewModel)
    $c = $Context.Controls
    $c['Progress.Step'].Text = (ConvertTo-BRAVOInstallerWizardStepViewModel -Operation $Context.Wizard.Operation -Screen 'Progress').Text
    $c['Progress.Phases'].Text = (@($ViewModel.Phases | ForEach-Object { $_.Text }) -join [Environment]::NewLine)
    $c['Progress.Current'].Text = $ViewModel.CurrentText
    $bar = $c['Progress.Bar']
    if ($ViewModel.Indeterminate) {
        # Невідомий відсоток = marquee; ніколи не вигадуємо «99%».
        $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    } else {
        $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $bar.Value = [int]$ViewModel.Percent
    }
    $c['Progress.Elapsed'].Text = $ViewModel.ElapsedText
    $c['Progress.Heartbeat'].Text = $ViewModel.HeartbeatText
    $cancel = $c['Progress.Cancel']
    $cancel.Text = $ViewModel.Cancel.Label
    $cancel.AccessibleName = $ViewModel.Cancel.Label
    $cancel.Tag = $ViewModel.Cancel.Key
    $cancel.Enabled = [bool]$ViewModel.Cancel.Enabled
    $cancel.AccessibleDescription = $ViewModel.Cancel.Reason
    $c['Progress.CancelNote'].Text = $ViewModel.CancelNote + $(if ($ViewModel.Cancel.Reason) { [Environment]::NewLine + $ViewModel.Cancel.Reason } else { '' })
    $c['Progress.Details'].Visible = [bool]$c['Progress.ShowDetails'].Checked
    if ($c['Progress.Details'].Visible -and $c['Progress.Details'].Text -ne $ViewModel.TechnicalText) { $c['Progress.Details'].Text = $ViewModel.TechnicalText }
}

function Get-BRAVOInstallerAccentColor {
    # Кольори лише ДОДАЮТЬ до тексту й маркера (UX: статус не лише кольором).
    [CmdletBinding()]
    param([string]$Accent)
    switch ($Accent) {
        'Success'    { @{ Back = [System.Drawing.Color]::FromArgb(198, 239, 206); Fore = [System.Drawing.Color]::FromArgb(0, 80, 0) } }
        'Warning'    { @{ Back = [System.Drawing.Color]::FromArgb(255, 235, 156); Fore = [System.Drawing.Color]::FromArgb(96, 64, 0) } }
        'Error'      { @{ Back = [System.Drawing.Color]::FromArgb(255, 199, 206); Fore = [System.Drawing.Color]::FromArgb(130, 0, 20) } }
        'RolledBack' { @{ Back = [System.Drawing.Color]::FromArgb(255, 217, 179); Fore = [System.Drawing.Color]::FromArgb(110, 45, 0) } }
        default      { @{ Back = [System.Drawing.Color]::FromArgb(156, 0, 6); Fore = [System.Drawing.Color]::White } }
    }
}

function Update-BRAVOInstallerResultScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][object]$ViewModel)
    $c = $Context.Controls
    $colors = Get-BRAVOInstallerAccentColor -Accent $ViewModel.Accent
    $c['Result.Banner'].BackColor = $colors.Back
    $c['Result.Title'].ForeColor = $colors.Fore
    $c['Result.Title'].Text = $ViewModel.Marker + ' ' + $ViewModel.Title
    $c['Result.Body'].Text = (@($ViewModel.Body) -join [Environment]::NewLine)
    $c['Result.Tasks'].Text = $ViewModel.TaskActivationText + [Environment]::NewLine + $ViewModel.NoAutoRunNote
    $c['Result.Validation'].Text = (@($ViewModel.ValidationRows | ForEach-Object { $_.Text }) -join [Environment]::NewLine)
    Set-BRAVOInstallerFindingRowControl -Flow $c['Result.Findings'] -Row $ViewModel.FindingRows -WrapWidth ($c['Result.Body'].MaximumSize.Width)
    $c['Result.Details'].Text = $ViewModel.TechnicalText
    $flow = $c['Result.Actions']
    $flow.SuspendLayout()
    try {
        foreach ($old in @($flow.Controls)) { $flow.Controls.Remove($old); $old.Dispose() }
        foreach ($action in $ViewModel.Actions) {
            $button = New-BRAVOInstallerButton -Context $Context -Name ('Result.Action.' + $action.Key) -Text $action.Label `
                -AccessibleName $action.Label -Key $action.Key -Reason $action.Reason
            $button.Enabled = [bool]$action.Enabled
            [void]$flow.Controls.Add($button)
        }
    } finally {
        $flow.ResumeLayout()
    }
    Set-BRAVOInstallerTabOrder -Container $Context.Controls['Screen.Result']
}

function Update-BRAVOInstallerSettingsScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $c = $Context.Controls
    $vm = ConvertTo-BRAVOInstallerMaintenanceViewModel -State $Context.State -RepeatBlocked:([bool]$Context.RepeatBlocked)
    $c['Settings.Open'].Enabled = ([bool]$vm.ConfigureAction.Enabled -and -not $Context.Busy)
    $c['Settings.Repair'].Enabled = ([bool]$vm.RepairAction.Enabled -and -not $Context.Busy)
    $c['Settings.Credentials'].Enabled = ([bool]$vm.CredentialsAction.Enabled -and -not $Context.Busy)
    $c['Settings.RepairNote'].Text = $vm.RepairNote
    $reasons = @()
    foreach ($action in @($vm.ConfigureAction, $vm.RepairAction, $vm.CredentialsAction)) {
        if ($action.Reason) { $reasons += ($action.Label + ': ' + $action.Reason) }
    }
    $c['Settings.Reasons'].Text = (@($reasons) -join [Environment]::NewLine)
}

function Update-BRAVOInstallerLogsContent {
    # Читання списку й хвостів журналів — короткі обмежені читання (до 3 файлів
    # по 256 КіБ); робиться лише при показі екрана або «Оновити».
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $c = $Context.Controls
    $path = Get-BRAVOInstallerLogsPath -ToolkitRoot $Context.ToolkitRoot -RuntimeRoot ([string]$Context.RuntimeRoot)
    $vm = ConvertTo-BRAVOInstallerLogListViewModel -File @(Get-BRAVOInstallerLogFile -LogsPath $path)
    $list = $c['Logs.List']
    $list.Items.Clear()
    foreach ($row in $vm.Rows) { [void]$list.Items.Add($row.Text) }
    if ($vm.EmptyNote) { [void]$list.Items.Add($vm.EmptyNote) }
    $tail = ''
    try {
        $tail = (@(Invoke-BRAVOInstallerUpdateRead -ToolkitRoot $Context.ToolkitRoot -Name 'Get-BRAVOUpdateLogTail' -Argument @{ LogRoot = $path; MaxLines = 200; MaxFiles = 3 }) -join [Environment]::NewLine)
    } catch {
        $tail = 'Хвіст журналів недоступний: ' + $_.Exception.Message
    }
    $c['Logs.Tail'].Text = $tail
}

function Update-BRAVOInstallerWizardScreens {
    # Перемальовує поточний екран майстра (викликається після зміни введення,
    # завершення job і Busy).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $w = $Context.Wizard
    if ($script:BRAVOInstallerWizardScreenNames -notcontains $Context.CurrentScreen) { return }
    if ($Context.CurrentScreen -ne $w.Screen) { return }
    $w.Updating = $true
    try {
        switch ($w.Screen) {
            'Source'      { Update-BRAVOInstallerSourceScreen -Context $Context }
            'Directories' { Update-BRAVOInstallerDirectoriesScreen -Context $Context }
            'Backup'      { Update-BRAVOInstallerBackupScreen -Context $Context }
            'Credentials' { Update-BRAVOInstallerCredentialsScreen -Context $Context }
            'Schedule'    { Update-BRAVOInstallerScheduleScreen -Context $Context }
            'Plan'        { Update-BRAVOInstallerPlanScreen -Context $Context }
        }
    } finally {
        $w.Updating = $false
    }
}

# --------------------------------------------------------------- Потік

function Show-BRAVOInstallerWizardStep {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Screen)
    $Context.Wizard.Screen = $Screen
    Show-BRAVOInstallerScreen -Context $Context -Name $Screen
    Update-BRAVOInstallerWizardScreens -Context $Context
}

function Enter-BRAVOInstallerWizard {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair')][string]$Operation)
    $state = New-BRAVOInstallerWizardState
    $state.Operation = $Operation
    if ($Operation -eq 'Repair') {
        # Відновлення не змінює версію: пропонуємо тег поточної версії.
        $current = [string](Get-BRAVOInstallerProperty -InputObject (Get-BRAVOInstallerProperty -InputObject $Context.State -Name 'version') -Name 'packageVersion' -Default '')
        if ($current) { $state.Tag = 'v' + $current }
    }
    $Context.Wizard = $state
    Hide-BRAVOInstallerError -Context $Context
    Show-BRAVOInstallerWizardStep -Context $Context -Screen 'Source'
}

function Start-BRAVOInstallerPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    if ($Context.Busy) { return }
    $w = $Context.Wizard
    Sync-BRAVOInstallerWizardInput -Context $Context
    $source = ConvertTo-BRAVOInstallerSourceViewModel -Operation $w.Operation -SourceKind $w.SourceKind -Tag $w.Tag -ZipPath $w.ZipPath `
        -AdvancedExpanded $w.AdvancedExpanded -AllowPrerelease $w.AllowPrerelease -PrereleaseAcknowledged $w.PrereleaseAck
    $w.Plan = $null; $w.PlanPayload = $null; $w.PlanLines = @(); $w.PlanError = ''; $w.PlanConfirmed = $false
    if (-not $source.CanContinue) {
        $w.PlanError = (@($source.Problems) -join ' ')
        Show-BRAVOInstallerWizardStep -Context $Context -Screen 'Plan'
        return
    }
    $option = @{ Operation = $w.Operation; AllowPrerelease = [bool]$source.PrereleaseEffective }
    if ($source.SourceKind -eq 'Local') { $option['SourcePath'] = $source.ZipPath }
    elseif (-not [string]::IsNullOrEmpty($source.Tag)) { $option['Tag'] = $source.Tag }
    if ($w.Operation -eq 'Install') { $option['BackupDestination'] = [string]$w.BackupMode }
    $runtime = [string]$Context.RuntimeRoot
    if ($w.Operation -eq 'Install') { $runtime = [string]$w.RuntimeRoot }
    elseif (-not [string]::IsNullOrEmpty([string](Get-BRAVOInstallerProperty -InputObject $Context.State -Name 'runtimeRoot' -Default ''))) {
        $runtime = [string]$Context.State.runtimeRoot
    }
    Show-BRAVOInstallerWizardStep -Context $Context -Screen 'Plan'
    try {
        $Context.Job = Start-BRAVOInstallerEngineJob -ToolkitRoot $Context.ToolkitRoot -Action 'Plan' -RuntimeRoot $runtime -PlanOption $option
    } catch {
        $w.PlanError = $_.Exception.Message
        Show-BRAVOInstallerError -Context $Context -Summary 'Не вдалося запустити engine для плану.' -Technical $_.Exception.ToString()
        Update-BRAVOInstallerWizardScreens -Context $Context
        return
    }
    Set-BRAVOInstallerBusy -Context $Context -Busy $true -Text 'Формуємо план змін…'
    $Context.Timer.Enabled = $true   # не .Start(): governance-гард забороняє інстансний .Start()
}

function Complete-BRAVOInstallerPlanJob {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][object]$Status)
    $w = $Context.Wizard
    $data = $Status.Data
    $w.Plan = $null
    $w.PlanLines = @()
    $w.PlanPayload = $data
    $w.PlanConfirmed = $false
    if ($null -ne $data -and $null -ne $data.PSObject.Properties['planId']) {
        $w.Plan = $data
        $w.PlanError = ''
        try {
            $w.PlanLines = @(Invoke-BRAVOInstallerUpdateRead -ToolkitRoot $Context.ToolkitRoot -Name 'Format-BRAVODeploymentPlanText' -Argument @{ Plan = $data })
        } catch {
            $w.PlanLines = @()
            $w.PlanError = 'Текст плану недоступний: ' + $_.Exception.Message
        }
    } else {
        $w.PlanError = $(if ($Status.Error) { $Status.Error } else { 'Engine не сформував план (див. зауваження нижче).' })
    }
}

function Complete-BRAVOInstallerDiagnoseJob {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][object]$Status)
    $Context.DiagnosticData = $Status.Data
    $text = ''
    if ($null -ne $Status.Data) {
        try {
            if ($null -ne $Status.Data.PSObject.Properties['sections']) {
                $text = (@(Invoke-BRAVOInstallerUpdateRead -ToolkitRoot $Context.ToolkitRoot -Name 'Format-BRAVODiagnosticReportText' -Argument @{ Report = $Status.Data }) -join [Environment]::NewLine)
            }
        } catch { $text = '' }
        if ([string]::IsNullOrEmpty($text)) { $text = ($Status.Data | ConvertTo-Json -Depth 8) }
    }
    $Context.DiagnosticText = $text
    $Context.Controls['Diagnostics.Preview'].Text = $text
}

function Start-BRAVOInstallerExecution {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $w = $Context.Wizard
    Sync-BRAVOInstallerWizardInput -Context $Context
    $vm = ConvertTo-BRAVOInstallerPlanViewModel -Plan $w.Plan -PlanLine @($w.PlanLines) -Confirmed $w.PlanConfirmed -Operation $w.Operation
    if (-not $vm.ExecuteAction.Enabled -or $Context.Busy) { return }
    $source = ConvertTo-BRAVOInstallerSourceViewModel -Operation $w.Operation -SourceKind $w.SourceKind -Tag $w.Tag -ZipPath $w.ZipPath `
        -AdvancedExpanded $w.AdvancedExpanded -AllowPrerelease $w.AllowPrerelease -PrereleaseAcknowledged $w.PrereleaseAck
    $requestPath = ''
    try {
        $stateRoot = Get-BRAVOInstallerContextStateRoot -Context $Context
        $operationId = [string](Get-BRAVOInstallerProperty -InputObject $w.Plan -Name 'operationId' -Default '')
        if ($null -eq (Get-BRAVOInstallerOperationDirectory -StateRoot $stateRoot -OperationId $operationId)) { throw 'План не містить коректного operationId: стеження за операцією неможливе.' }
        $backup = $null
        if ($w.Operation -eq 'Install') { $backup = [string]$w.BackupMode }
        $sourcePath = $null
        if ($source.SourceKind -eq 'Local') { $sourcePath = $source.ZipPath }
        $request = New-BRAVOInstallerExecutionRequest -Plan $w.Plan -ConfirmedPlanShortId $vm.ShortId `
            -PrereleaseAuthorized ([bool]$source.PrereleaseEffective) -RunSelfTest ([bool]$w.RunSelfTest) -BackupDestination $backup -SourcePath $sourcePath
        $requestPath = Write-BRAVOInstallerExecutionRequest -Request $request -StateRoot $stateRoot -ToolkitRoot $Context.ToolkitRoot
    } catch {
        Show-BRAVOInstallerError -Context $Context -Summary 'Не вдалося підготувати запит на виконання. Нічого не змінено.' -Technical $_.Exception.ToString()
        return
    }
    $launch = Start-BRAVOInstallerElevatedCommand -Command (New-BRAVOInstallerExecuteCommand -ToolkitRoot $Context.ToolkitRoot -RequestPath $requestPath)
    if (-not $launch.Started) {
        # Запит ніким не прочитаний: видаляємо лише власний файл запиту.
        if ($requestPath -and (Test-Path -LiteralPath $requestPath -PathType Leaf)) { Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue }
        $summary = if ($launch.Declined) { 'Підтвердження UAC скасовано. Нічого не змінено.' } else { 'Не вдалося запустити engine. Нічого не змінено.' }
        Show-BRAVOInstallerError -Context $Context -Summary $summary -Technical $launch.Error
        return
    }
    $Context.Exec = @{
        Process = $launch.Process; OperationId = $operationId; StateRoot = $stateRoot; StartedUtc = [datetime]::UtcNow
        OperationDirectory = (Get-BRAVOInstallerOperationDirectory -StateRoot $stateRoot -OperationId $operationId)
        CancelRequested = $false; ExitedPolls = 0; RequestPath = $requestPath
    }
    $w.Screen = 'Progress'
    Set-BRAVOInstallerNavEnabled -Context $Context -Enabled $false
    Show-BRAVOInstallerScreen -Context $Context -Name 'Progress'
    Update-BRAVOInstallerProgressScreen -Context $Context -ViewModel (ConvertTo-BRAVOInstallerExecutionViewModel -ProgressEvent @() -StartedUtc $Context.Exec.StartedUtc)
    Set-BRAVOInstallerBusy -Context $Context -Busy $true -Text 'Виконується операція BRAVO (engine працює окремо)…'
    $Context.Timer.Enabled = $true   # не .Start(): governance-гард забороняє інстансний .Start()
}

function Set-BRAVOInstallerNavEnabled {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [bool]$Enabled)
    foreach ($screen in $script:BRAVOInstallerNavScreenNames) {
        if ($Context.Controls.ContainsKey("Nav.$screen")) { $Context.Controls["Nav.$screen"].Enabled = $Enabled }
    }
}

function Update-BRAVOInstallerExecutionPoll {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $exec = $Context.Exec
    if ($null -eq $exec) { return }
    $state = Read-BRAVOInstallerExecutionState -StateRoot $exec.StateRoot -OperationId $exec.OperationId -ToolkitRoot $Context.ToolkitRoot
    $vm = ConvertTo-BRAVOInstallerExecutionViewModel -ProgressEvent @($state.Events) -StartedUtc $exec.StartedUtc `
        -MutationStarted $state.MutationStarted -CancelRequested $exec.CancelRequested
    Update-BRAVOInstallerProgressScreen -Context $Context -ViewModel $vm
    if ($state.ResultPresent) {
        $reason = ''
        if (-not $state.ResultValid) { $reason = 'Файл результату некоректний: ' + (@($state.ResultProblems) -join '; ') }
        Complete-BRAVOInstallerExecution -Context $Context -Result $(if ($state.ResultValid) { $state.Result } else { $null }) -Reason $reason
        return
    }
    $exited = $false
    $exitCode = ''
    try { $exited = [bool]$exec.Process.HasExited; if ($exited) { $exitCode = [string]$exec.Process.ExitCode } } catch { $exited = $false }
    if ($exited) {
        $exec.ExitedPolls = [int]$exec.ExitedPolls + 1
        # Кілька опитувань «на дозапис»: result.json міг з'явитись одразу після виходу.
        if ($exec.ExitedPolls -ge 8) {
            Complete-BRAVOInstallerExecution -Context $Context -Result $null -Reason "Engine завершився з кодом $exitCode, не записавши результат операції."
        }
    }
}

function Complete-BRAVOInstallerExecution {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [AllowNull()][object]$Result, [string]$Reason = '')
    $Context.Exec = $null
    $vm = ConvertTo-BRAVOInstallerResultViewModel -Result $Result -Operation $Context.Wizard.Operation -NoResultReason $Reason
    $Context.LastResultViewModel = $vm
    if ($vm.RepeatBlocked) { $Context.RepeatBlocked = $true }
    Set-BRAVOInstallerNavEnabled -Context $Context -Enabled $true
    Set-BRAVOInstallerBusy -Context $Context -Busy $false -Text ''
    $Context.Wizard.Screen = 'Result'
    Update-BRAVOInstallerResultScreen -Context $Context -ViewModel $vm
    Show-BRAVOInstallerScreen -Context $Context -Name 'Result'
    # Головна має показати новий стан після операції.
    Start-BRAVOInstallerRefresh -Context $Context -Action 'State'
}

function Update-BRAVOInstallerConsolePoll {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $console = $Context.Console
    if ($null -eq $console) { return }
    $exited = $true
    try { $exited = [bool]$console.Process.HasExited } catch { $exited = $true }
    if (-not $exited) { return }
    $Context.Console = $null
    # Після закриття вікна: свіжий State, а для облікових даних — ще й Preflight.
    $Context.PendingPreflight = ($console.Kind -eq 'Credentials')
    Start-BRAVOInstallerRefresh -Context $Context -Action 'State'
}

# --------------------------------------------------------------- Дії

function Show-BRAVOInstallerSaveDialog {
    # Повертає вибраний шлях або $null. Діалог модальний, але нічого не пише.
    [CmdletBinding()]
    param([string]$FileName, [string]$Filter = 'Текстовий файл (*.txt)|*.txt')
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    try {
        $dialog.FileName = $FileName
        $dialog.Filter = $Filter
        $dialog.OverwritePrompt = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
    } finally {
        $dialog.Dispose()
    }
    $null
}

function Test-BRAVOInstallerSavePathAllowed {
    # Звіт не можна класти всередину runtime (він керований manifest-ом).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Path)
    $root = Get-BRAVOInstallerKnownRuntimeRoot -Context $Context
    if ([string]::IsNullOrEmpty($root)) { return $true }
    try {
        return (-not [bool](Invoke-BRAVOInstallerUpdateRead -ToolkitRoot $Context.ToolkitRoot -Name 'Test-BRAVOUpdatePathIsUnder' -Argument @{ Path = $Path; Root = $root; AllowEqual = $true }))
    } catch { return $false }
}

function Invoke-BRAVOInstallerRecover {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $answer = [System.Windows.Forms.MessageBox]::Show($Context.Controls['Screen.Home'].FindForm(),
        ('Відновлення після переривання виконує engine з правами адміністратора: з''явиться одне підтвердження UAC і окреме вікно з перебігом.' +
            [Environment]::NewLine + 'Після завершення натисніть «Повторити» на головному екрані, якщо стан не оновиться сам.'),
        'BRAVO Installer', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Information)
    if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $launch = Start-BRAVOInstallerElevatedCommand -Command (New-BRAVOInstallerRecoverCommand -ToolkitRoot $Context.ToolkitRoot -RuntimeRoot ([string]$Context.RuntimeRoot))
    if (-not $launch.Started) {
        $summary = if ($launch.Declined) { 'Підтвердження UAC скасовано. Нічого не змінено.' } else { 'Не вдалося запустити відновлення.' }
        Show-BRAVOInstallerError -Context $Context -Summary $summary -Technical $launch.Error
        return
    }
    $Context.Console = @{ Process = $launch.Process; Kind = 'Recover' }
    $Context.Timer.Enabled = $true   # не .Start(): governance-гард забороняє інстансний .Start()
}

function Invoke-BRAVOInstallerCredentialsSetup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $root = Get-BRAVOInstallerKnownRuntimeRoot -Context $Context
    if ([string]::IsNullOrEmpty($root) -or -not (Test-Path -LiteralPath (Join-Path $root 'BRAVO_SETUP.ps1') -PathType Leaf)) {
        Show-BRAVOInstallerError -Context $Context -Summary 'Канонічне налаштування облікових даних не знайдено в каталозі встановлення.' -Technical $root
        return
    }
    try {
        $process = Start-BRAVOInstallerVisibleConsole -Command (New-BRAVOInstallerCredentialsCommand -RuntimeRoot $root)
    } catch {
        Show-BRAVOInstallerError -Context $Context -Summary 'Не вдалося відкрити налаштування облікових даних.' -Technical $_.Exception.ToString()
        return
    }
    $Context.Console = @{ Process = $process; Kind = 'Credentials' }
    $Context.Timer.Enabled = $true   # не .Start(): governance-гард забороняє інстансний .Start()
}

function Invoke-BRAVOInstallerWizardAction {
    <#
    .SYNOPSIS
        Дії майстра й Maintenance Center. Повертає $true, якщо ключ оброблено.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Key)
    $w = $Context.Wizard
    switch ($Key) {
        'Install'      { Enter-BRAVOInstallerWizard -Context $Context -Operation 'Install'; return $true }
        'CheckUpdates' { Enter-BRAVOInstallerWizard -Context $Context -Operation 'Update'; return $true }
        'Update'       { Enter-BRAVOInstallerWizard -Context $Context -Operation 'Update'; return $true }
        'Repair'       { Enter-BRAVOInstallerWizard -Context $Context -Operation 'Repair'; return $true }
        'Recover'      { Invoke-BRAVOInstallerRecover -Context $Context; return $true }
        'Rollback'     { Invoke-BRAVOInstallerRecover -Context $Context; return $true }
        'EnterCredentials' { Invoke-BRAVOInstallerCredentialsSetup -Context $Context; return $true }
        'BrowseZip' {
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            try {
                $dialog.Filter = 'ZIP-пакет релізу (*.zip)|*.zip'
                if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $Context.Controls['Source.Zip'].Text = $dialog.FileName
                }
            } finally { $dialog.Dispose() }
            return $true
        }
        'WizardBack' {
            if ($Context.Busy) { return $true }
            Sync-BRAVOInstallerWizardInput -Context $Context
            $step = ConvertTo-BRAVOInstallerWizardStepViewModel -Operation $w.Operation -Screen $w.Screen
            if ($null -eq $step.PreviousKey) { Show-BRAVOInstallerScreen -Context $Context -Name 'Home' }
            else { Show-BRAVOInstallerWizardStep -Context $Context -Screen $step.PreviousKey }
            return $true
        }
        'WizardNext' {
            if ($Context.Busy) { return $true }
            Sync-BRAVOInstallerWizardInput -Context $Context
            $step = ConvertTo-BRAVOInstallerWizardStepViewModel -Operation $w.Operation -Screen $w.Screen
            if ($null -eq $step.NextKey) { return $true }
            if ($step.NextKey -eq 'Plan') { Start-BRAVOInstallerPlan -Context $Context }
            else { Show-BRAVOInstallerWizardStep -Context $Context -Screen $step.NextKey }
            return $true
        }
        'RebuildPlan'  { Start-BRAVOInstallerPlan -Context $Context; return $true }
        'Execute'      { Start-BRAVOInstallerExecution -Context $Context; return $true }
        'RestartWizard' { $w.Plan = $null; $w.PlanLines = @(); $w.PlanConfirmed = $false; Show-BRAVOInstallerWizardStep -Context $Context -Screen 'Source'; return $true }
        'Finish' {
            $Context.Wizard = New-BRAVOInstallerWizardState
            Show-BRAVOInstallerScreen -Context $Context -Name 'Home'
            return $true
        }
        { $_ -eq 'Cancel' -or $_ -eq 'SafeStop' } {
            if ($null -eq $Context.Exec) { return $true }
            if ($Key -eq 'SafeStop') {
                $answer = [System.Windows.Forms.MessageBox]::Show($Context.Controls['Screen.Progress'].FindForm(),
                    'Зміни вже почались. Engine дійде до безпечної точки й відкотить зміни. Продовжити?',
                    'BRAVO Installer', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return $true }
            }
            $cancel = New-BRAVOInstallerCancelRequest -OperationDirectory $Context.Exec.OperationDirectory
            if ($cancel.Success) { $Context.Exec.CancelRequested = $true }
            else { Show-BRAVOInstallerError -Context $Context -Summary $cancel.Message -Technical ([string]$cancel.Path) }
            return $true
        }
        'RunDiagnose' { Start-BRAVOInstallerRefresh -Context $Context -Action 'Diagnose'; return $true }
        'RefreshLogs' { Update-BRAVOInstallerLogsContent -Context $Context; return $true }
        'SaveDiagnostics' {
            $path = Show-BRAVOInstallerSaveDialog -FileName ('BRAVO-diagnostics-' + [datetime]::Now.ToString('yyyyMMdd-HHmmss') + '.txt')
            if ($null -eq $path) { return $true }
            if (-not (Test-BRAVOInstallerSavePathAllowed -Context $Context -Path $path)) {
                Show-BRAVOInstallerError -Context $Context -Summary 'Звіт не можна зберігати всередину каталогу встановлення. Оберіть інше місце.' -Technical $path
                return $true
            }
            try {
                $report = $Context.DiagnosticData
                if ($null -eq $report -or $null -eq $report.PSObject.Properties['sections']) {
                    # Engine не дав готового звіту: збираємо його read-only з відомого State/Preflight.
                    $preflight = $Context.Preflight
                    if ($null -eq $preflight) { $preflight = [pscustomobject]@{ findings = @(); canProceed = $false; blockerCount = 0; warningCount = 0 } }
                    $report = Invoke-BRAVOInstallerUpdateRead -ToolkitRoot $Context.ToolkitRoot -Name 'New-BRAVODiagnosticReport' -Argument @{ InstallationState = $Context.State; Preflight = $preflight }
                }
                $runtimeRoots = @(Get-BRAVOInstallerKnownRuntimeRoot -Context $Context)
                [void](Invoke-BRAVOInstallerUpdateRead -ToolkitRoot $Context.ToolkitRoot -Name 'Save-BRAVODiagnosticReport' -Argument @{ Report = $report; Path = $path; RuntimeRoot = $runtimeRoots })
                $Context.Controls['Status.Text'].Text = "✓ Звіт збережено: $path"
            } catch {
                Show-BRAVOInstallerError -Context $Context -Summary 'Не вдалося зберегти діагностичний звіт.' -Technical $_.Exception.ToString()
            }
            return $true
        }
        'OpenLog' {
            $log = ''
            if ($null -ne $Context.LastResultViewModel) { $log = [string]$Context.LastResultViewModel.LogPath }
            try {
                if ($log -and (Test-Path -LiteralPath $log -PathType Leaf)) { [void](Invoke-BRAVOInstallerCommand -Command (New-BRAVOInstallerOpenLogCommand -LogPath $log)) }
                elseif ($log -and (Test-Path -LiteralPath $log -PathType Container)) { [void](Invoke-BRAVOInstallerCommand -Command (New-BRAVOInstallerLogsCommand -LogsPath $log)) }
                else {
                    $fallback = Get-BRAVOInstallerLogsPath -ToolkitRoot $Context.ToolkitRoot -RuntimeRoot (Get-BRAVOInstallerKnownRuntimeRoot -Context $Context)
                    if (Test-Path -LiteralPath $fallback -PathType Container) { [void](Invoke-BRAVOInstallerCommand -Command (New-BRAVOInstallerLogsCommand -LogsPath $fallback)) }
                    else { Show-BRAVOInstallerError -Context $Context -Summary 'Журнал не знайдено: шлях не вказано або каталог відсутній.' -Technical $log }
                }
            } catch {
                Show-BRAVOInstallerError -Context $Context -Summary 'Не вдалося відкрити журнал.' -Technical $_.Exception.ToString()
            }
            return $true
        }
        'SaveReport' {
            $vm = $Context.LastResultViewModel
            if ($null -eq $vm) { return $true }
            $path = Show-BRAVOInstallerSaveDialog -FileName ('BRAVO-result-' + [datetime]::Now.ToString('yyyyMMdd-HHmmss') + '.txt')
            if ($null -eq $path) { return $true }
            if (-not (Test-BRAVOInstallerSavePathAllowed -Context $Context -Path $path)) {
                Show-BRAVOInstallerError -Context $Context -Summary 'Звіт не можна зберігати всередину каталогу встановлення. Оберіть інше місце.' -Technical $path
                return $true
            }
            try {
                $text = $vm.Marker + ' ' + $vm.Title + [Environment]::NewLine + (@($vm.Body) -join [Environment]::NewLine) + [Environment]::NewLine +
                    $vm.TaskActivationText + [Environment]::NewLine + [Environment]::NewLine + $vm.TechnicalText
                [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($true)))
                $Context.Controls['Status.Text'].Text = "✓ Звіт збережено: $path"
            } catch {
                Show-BRAVOInstallerError -Context $Context -Summary 'Не вдалося зберегти звіт.' -Technical $_.Exception.ToString()
            }
            return $true
        }
        'Configure' { Invoke-BRAVOInstallerAction -Context $Context -Key 'OpenConfigurator'; return $true }
    }
    $false
}
