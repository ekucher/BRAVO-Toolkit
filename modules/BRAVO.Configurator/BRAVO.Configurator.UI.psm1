# BRAVO.Configurator.UI — schema-driven WinForms UI над уже готовим
# backend-ом (Schema/Effective/Model/Validation/Persistence/Credentials/
# Presets/Preview). Цей модуль НЕ реалізує жодної dependency/master-child
# семантики й НЕ пише BRAVO.local.config напряму — лише орендує пусту
# in-memory модель через Set/Clear-BRAVOConfiguratorOverride і передає
# фінальний Model у Invoke-BRAVOConfiguratorApply.
#
# Структура файлу:
#   1. Чисті (headless-тестовані) функції — БЕЗ жодного типу
#      System.Windows.Forms у сигнатурі чи тілі. Саме їх прогонить
#      selftest\BRAVO_SELF_TEST.ConfiguratorUI.ps1 напряму, без
#      інтерактивної desktop-сесії.
#   2. Приватні WinForms-функції побудови контролів/панелей — importable,
#      але НЕ exported (внутрішня деталь реалізації форми).
#   3. Show-BRAVOConfiguratorMainForm — єдина публічна точка входу, що
#      реально створює й показує форму (ShowDialog, блокуюча).
#
# Debounce-політика для Update-BRAVOConfiguratorEffective (реальний
# child-process виклик canonical loader-а, секунди, НЕ на кожен keystroke):
# редагування поля (checkbox override / текстове поле / ComboBox) лише
# оновлює IN-MEMORY Model через Set/Clear-BRAVOConfiguratorOverride і
# позначає стан "потребує перерахунку" (EffectiveStale) — САМ Effective
# перераховується ЛИШЕ (а) на явну кнопку "Перерахувати", (б) автоматично
# перед побудовою Preview у потоці Apply (пункт "batch it before showing
# Preview" з умови задачі), (в) одноразово при старті форми, (г) після
# успішного Apply/Reload. Жодного автоматичного виклику на TextChanged/
# SelectedIndexChanged немає.

Set-StrictMode -Version 2.0

# =====================================================================
# 1. Чисті функції (без System.Windows.Forms у сигнатурі/тілі)
# =====================================================================

function Get-BRAVOConfiguratorUIReachablePaths {
    <#
    .SYNOPSIS
        Повертає всі Path, для яких UI побудує контроль — механічний
        доказ 100% покриття schema-каталогу (жоден Path не пропускається
        через хардкод конкретних полів: центральна панель будується
        динамічно з $SchemaCatalog/Model, не зі списку "відомих" шляхів).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$SchemaCatalog
    )

    return @($SchemaCatalog | ForEach-Object { [string]$_.Path })
}

function Get-BRAVOConfiguratorUIFilteredSettings {
    <#
    .SYNOPSIS
        Фільтрує Model за одним з 5 UI-фільтрів. Визначення (задокументовано
        тут, бо задача явно віддає це "на розсуд" з вимогою документувати):
          - 'All'      — усі settings без змін.
          - 'Changed'  — Dirty=$true АБО OverridePresent=$true (тобто:
                          або щойно відредаговано в цій сесії, або вже
                          має явний override, незалежно від того, коли
                          його виставлено).
          - 'Active'   — для Boolean-дескрипторів: EffectiveValue truthy
                          (реально "увімкнено" зараз); для всіх інших
                          типів: OverridePresent=$true (немає єдиного
                          "truthy" сенсу для String/Enum/Path/масивів,
                          тому "Active" для них означає "оператор явно
                          щось налаштував").
          - 'Problems' — Path присутній у $ValidationFindings із
                          Severity WARNING/ERROR, АБО DisabledReason
                          непорожній (розбіжність Raw/Effective через
                          master-switch також вважається "проблемою" для
                          операторської уваги, навіть якщо це лише INFO
                          у Validation-модулі).
          - 'Advanced' — Metadata.Advanced=$true.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$Model,
        [Parameter(Mandatory = $true)][ValidateSet('All', 'Changed', 'Active', 'Problems', 'Advanced')][string]$Filter,
        [array]$ValidationFindings = @()
    )

    switch ($Filter) {
        'All' {
            return @($Model)
        }
        'Changed' {
            return @($Model | Where-Object { [bool]$_.Dirty -or [bool]$_.OverridePresent })
        }
        'Active' {
            return @($Model | Where-Object {
                if ([string]$_.Metadata.Type -eq 'Boolean') {
                    [bool]$_.EffectiveValue
                } else {
                    [bool]$_.OverridePresent
                }
            })
        }
        'Problems' {
            $problemPaths = @($ValidationFindings |
                Where-Object { [string]$_.Severity -eq 'WARNING' -or [string]$_.Severity -eq 'ERROR' } |
                ForEach-Object { [string]$_.Path })
            return @($Model | Where-Object {
                ($problemPaths -contains [string]$_.Path) -or
                (-not [string]::IsNullOrWhiteSpace([string]$_.DisabledReason))
            })
        }
        'Advanced' {
            return @($Model | Where-Object { [bool]$_.Metadata.Advanced })
        }
    }
}

function Get-BRAVOConfiguratorUISearchMatches {
    <#
    .SYNOPSIS
        Повертає підмножину Model, чий Path/Label/Description/Group
        містить $SearchText (case-insensitive substring). Порожній/
        whitespace-only SearchText повертає Model без змін.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$Model,
        [AllowEmptyString()][string]$SearchText = ''
    )

    if ([string]::IsNullOrWhiteSpace($SearchText)) {
        return @($Model)
    }

    $needlePattern = [regex]::Escape($SearchText.Trim())
    return @($Model | Where-Object {
        ([string]$_.Path -match $needlePattern) -or
        ([string]$_.Metadata.Label -match $needlePattern) -or
        ([string]$_.Metadata.Description -match $needlePattern) -or
        ([string]$_.Metadata.Group -match $needlePattern)
    })
}

function Get-BRAVOConfiguratorUICategoryTree {
    <#
    .SYNOPSIS
        Будує структуру Group -> Section[] (з DescriptorCount на кожному
        рівні) ВИКЛЮЧНО зі схемних Group/Section-полів — без жодного
        хардкодженого переліку категорій. Повертає plain data
        (pscustomobject/array), не TreeNode — саме це годує TreeView у
        приватному UI-шарі, але сама функція headless-тестована.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$SchemaCatalog
    )

    $projected = @($SchemaCatalog | ForEach-Object {
        [pscustomobject]@{ Group = [string]$_.Group; Section = [string]$_.Section }
    })

    $tree = New-Object System.Collections.Generic.List[object]
    $groupBuckets = @($projected | Group-Object -Property Group | Sort-Object -Property Name)
    foreach ($groupBucket in $groupBuckets) {
        $sectionBuckets = @($groupBucket.Group | Group-Object -Property Section | Sort-Object -Property Name)
        $sections = New-Object System.Collections.Generic.List[object]
        foreach ($sectionBucket in $sectionBuckets) {
            $sections.Add([pscustomobject]@{
                Section         = $sectionBucket.Name
                DescriptorCount = $sectionBucket.Count
            })
        }
        $tree.Add([pscustomobject]@{
            Group           = $groupBucket.Name
            DescriptorCount = $groupBucket.Count
            Sections        = $sections.ToArray()
        })
    }

    return $tree.ToArray()
}

function Get-BRAVOConfiguratorUIBooleanTriState {
    <#
    .SYNOPSIS
        Обчислює один із 3 генуїнно різних станів Boolean-налаштування:
        'Default' (немає override), 'True' (override=true), 'False'
        (override=false) — так UI (незалежно від того, чи це 3-item
        ComboBox чи checkbox+use-default toggle) може відрізнити
        "override=false" від "override відсутній", а не звужувати їх до
        одного 2-state прапорця.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$OverridePresent,
        $OverrideValue
    )

    if (-not $OverridePresent) { return 'Default' }
    if ([bool]$OverrideValue) { return 'True' }
    return 'False'
}

function ConvertTo-BRAVOConfiguratorUIDisplayText {
    <#
    .SYNOPSIS
        Форматує значення (скаляр або масив) у текст для TextBox-редактора
        — StringArray/NumberArray через кому, решта — просте [string]-приведення.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        $Value
    )

    if ($null -eq $Value) { return '' }
    if ($Type -eq 'StringArray' -or $Type -eq 'NumberArray') {
        return [string]::Join(', ', @($Value))
    }
    return [string]$Value
}

function ConvertTo-BRAVOConfiguratorUITypedValue {
    <#
    .SYNOPSIS
        Парсить текст редактора у .NET-тип, який Effective/Persistence
        очікує для даного схемного Type (ConvertTo-BRAVOConfiguratorPowerShellLiteral
        у BRAVO.Configurator.Effective розрізняє int/double/bool/string/array
        — редактор повинен віддати сумісний .NET-тип, не голий текст).
    .DESCRIPTION
        Кидає виняток на невалідному вводі (некоректне число тощо) —
        викликач (UI-шар) відповідає за показ повідомлення оператору й
        НЕ застосовує override на цій помилці (fail-closed для одного
        поля, не для всієї форми).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [AllowEmptyString()][string]$RawText = ''
    )

    switch ($Type) {
        'Integer' {
            return [int]::Parse($RawText.Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
        }
        'Number' {
            return [double]::Parse($RawText.Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
        }
        'StringArray' {
            if ([string]::IsNullOrWhiteSpace($RawText)) { return @() }
            return @($RawText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        }
        'NumberArray' {
            if ([string]::IsNullOrWhiteSpace($RawText)) { return @() }
            return @($RawText -split ',' | ForEach-Object { [double]::Parse($_.Trim(), [System.Globalization.CultureInfo]::InvariantCulture) })
        }
        default {
            return $RawText
        }
    }
}

# =====================================================================
# 2. Приватні WinForms-функції (не exported) — конструюють реальні
#    System.Windows.Forms-контролі поверх чистих функцій вище.
# =====================================================================

function Initialize-BRAVOConfiguratorUIAssemblies {
    # Лениве завантаження WinForms-складань — лише всередині
    # Show-BRAVOConfiguratorMainForm, НІКОЛИ на рівні модуля, щоб
    # Import-Module цього модуля (напр. у self-test) не вимагав жодного
    # WinForms-залежного середовища.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}

function Get-BRAVOConfiguratorUIDirtyState {
    # P2-A.3: справжній diff-based Dirty проти $State.ProductionBaseline.Overrides
    # (canonical Test-BRAVOConfiguratorModelDirty, Model.psm1) — НЕ подієвий
    # Model[].Dirty прапорець, який лишався $true назавжди після
    # edit -> revert до оригіналу (P3-знахідка P1-стабілізації, "phantom
    # Dirty"). $State.ProductionBaseline оновлюється при Load/Reload/
    # успішному Apply — той самий знімок, що вже існував для race
    # detection у Persistence.
    param([Parameter(Mandatory = $true)][hashtable]$State)
    return Test-BRAVOConfiguratorModelDirty -Model $State.Model -BaselineOverrides $State.ProductionBaseline.Overrides
}

function Show-BRAVOConfiguratorUIMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Caption = 'BRAVO Configurator',
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Caption, [System.Windows.Forms.MessageBoxButtons]::OK, $Icon)
}

function New-BRAVOConfiguratorUISettingRow {
    <#
    .SYNOPSIS
        Будує один рядок панелі налаштувань: checkbox "override" + типовий
        редактор значення + статус-мітка (EffectiveSource/DisabledReason).
        Жодна подія тут НЕ пише на диск і НЕ викликає
        Update-BRAVOConfiguratorEffective — лише Set/Clear-BRAVOConfiguratorOverride
        через $OnChanged callback (мутує $State.Model на місці).
    #>
    param(
        [Parameter(Mandatory = $true)]$Setting,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][scriptblock]$OnChanged,
        [Parameter(Mandatory = $true)][scriptblock]$OnSelected
    )

    $descriptorType = [string]$Setting.Metadata.Type
    $currentPath = [string]$Setting.Path

    # P1-фікс (stabilization): .GetNewClosure() у Windows PowerShell 5.1 не
    # зберігає прив'язку до module-private command table — прямий виклик
    # приватної функції модуля (не exported) з тіла GetNewClosure()-блоку
    # падає з "term ... is not recognized" у реальному WinForms-запуску
    # (self-test цього не ловив, бо ніколи не будує реальну форму). Тут
    # $currentPath/$overrideCheckBox/$valueControl дійсно потребують
    # GetNewClosure (New-BRAVOConfiguratorUISettingRow повертається одразу
    # після побудови рядка, до першого кліку) — тому замість видалення
    # GetNewClosure передаємо приватну функцію як captured-змінну
    # (той самий підхід, що вже працює для $OnChanged/$OnSelected-параметрів).
    $showMessageRef = ${function:Show-BRAVOConfiguratorUIMessage}

    $rowPanel = New-Object System.Windows.Forms.Panel
    $rowPanel.Width = 700
    $rowPanel.Height = 28
    $rowPanel.Margin = New-Object System.Windows.Forms.Padding(2)

    $overrideCheckBox = New-Object System.Windows.Forms.CheckBox
    $labelText = [string]$Setting.Metadata.Label
    if ([string]::IsNullOrWhiteSpace($labelText)) { $labelText = $currentPath }
    $overrideCheckBox.Text = $labelText
    $overrideCheckBox.Location = New-Object System.Drawing.Point(0, 5)
    $overrideCheckBox.Width = 270
    $overrideCheckBox.Checked = [bool]$Setting.OverridePresent
    $overrideCheckBox.Enabled = -not [bool]$Setting.Metadata.ReadOnly
    $rowPanel.Controls.Add($overrideCheckBox)

    $valueControl = $null
    if ($descriptorType -eq 'Boolean') {
        $valueControl = New-Object System.Windows.Forms.ComboBox
        $valueControl.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
        [void]$valueControl.Items.Add('Так')
        [void]$valueControl.Items.Add('Ні')
        $currentBoolValue = if ($Setting.OverridePresent) { [bool]$Setting.OverrideValue } else { [bool]$Setting.DefaultValue }
        $valueControl.SelectedIndex = if ($currentBoolValue) { 0 } else { 1 }
    } elseif ($descriptorType -eq 'Enum') {
        $valueControl = New-Object System.Windows.Forms.ComboBox
        $valueControl.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
        foreach ($allowedValue in @($Setting.Metadata.AllowedValues)) {
            [void]$valueControl.Items.Add([string]$allowedValue)
        }
        $currentEnumValue = if ($Setting.OverridePresent) { [string]$Setting.OverrideValue } else { [string]$Setting.DefaultValue }
        $existingIndex = $valueControl.Items.IndexOf($currentEnumValue)
        if ($existingIndex -ge 0) { $valueControl.SelectedIndex = $existingIndex }
    } else {
        $valueControl = New-Object System.Windows.Forms.TextBox
        $currentTypedValue = if ($Setting.OverridePresent) { $Setting.OverrideValue } else { $Setting.DefaultValue }
        $valueControl.Text = ConvertTo-BRAVOConfiguratorUIDisplayText -Type $descriptorType -Value $currentTypedValue
    }
    $valueControl.Location = New-Object System.Drawing.Point(275, 2)
    $valueControl.Width = 260
    $valueControl.Enabled = ([bool]$Setting.OverridePresent) -and (-not [bool]$Setting.Metadata.ReadOnly)
    $rowPanel.Controls.Add($valueControl)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Location = New-Object System.Drawing.Point(545, 5)
    $statusLabel.Width = 150
    $statusText = [string]$Setting.EffectiveSource
    if (-not [string]::IsNullOrWhiteSpace([string]$Setting.DisabledReason)) {
        $statusText = "$statusText *"
        $toolTip = New-Object System.Windows.Forms.ToolTip
        $toolTip.SetToolTip($statusLabel, [string]$Setting.DisabledReason)
    }
    $statusLabel.Text = $statusText
    $rowPanel.Controls.Add($statusLabel)

    # Захоплення поточного значення редактора в типізований override —
    # спільна логіка для checkbox-toggle і value-change нижче.
    $getConvertedValue = {
        if ($descriptorType -eq 'Boolean') {
            return ($valueControl.SelectedIndex -eq 0)
        } elseif ($descriptorType -eq 'Enum') {
            return [string]$valueControl.Text
        } else {
            return ConvertTo-BRAVOConfiguratorUITypedValue -Type $descriptorType -RawText $valueControl.Text
        }
    }.GetNewClosure()

    $overrideCheckBox.Add_CheckedChanged({
        $valueControl.Enabled = $overrideCheckBox.Checked -and (-not [bool]$Setting.Metadata.ReadOnly)
        if ($overrideCheckBox.Checked) {
            try {
                $convertedValue = & $getConvertedValue
                & $OnChanged $currentPath $true $convertedValue
            } catch {
                & $showMessageRef -Text "Некоректне значення для '$currentPath': $($_.Exception.Message)" -Icon Warning
            }
        } else {
            & $OnChanged $currentPath $false $null
        }
        & $OnSelected $currentPath
    }.GetNewClosure())

    if ($valueControl -is [System.Windows.Forms.ComboBox]) {
        $valueControl.Add_SelectedIndexChanged({
            if ($overrideCheckBox.Checked) {
                try {
                    $convertedValue = & $getConvertedValue
                    & $OnChanged $currentPath $true $convertedValue
                } catch {
                    & $showMessageRef -Text "Некоректне значення для '$currentPath': $($_.Exception.Message)" -Icon Warning
                }
            }
            & $OnSelected $currentPath
        }.GetNewClosure())
    } else {
        $valueControl.Add_Leave({
            if ($overrideCheckBox.Checked) {
                try {
                    $convertedValue = & $getConvertedValue
                    & $OnChanged $currentPath $true $convertedValue
                } catch {
                    & $showMessageRef -Text "Некоректне значення для '$currentPath': $($_.Exception.Message)" -Icon Warning
                }
            }
        }.GetNewClosure())
    }

    $overrideCheckBox.Add_Enter({ & $OnSelected $currentPath }.GetNewClosure())
    $valueControl.Add_Enter({ & $OnSelected $currentPath }.GetNewClosure())

    return $rowPanel
}

function Update-BRAVOConfiguratorUIDetailsPanel {
    param(
        [Parameter(Mandatory = $true)]$DetailsTextBox,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $DetailsTextBox.Text = ''
        return
    }
    $setting = @($State.Model | Where-Object { [string]$_.Path -eq $Path })
    if ($setting.Count -ne 1) {
        $DetailsTextBox.Text = ''
        return
    }
    $item = $setting[0]
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Path: $($item.Path)")
    $lines.Add("Label: $($item.Metadata.Label)")
    $lines.Add("Group / Section: $($item.Metadata.Group) / $($item.Metadata.Section)")
    $lines.Add("Type: $($item.Metadata.Type)")
    $lines.Add("Advanced: $($item.Metadata.Advanced)")
    $lines.Add('')
    $lines.Add("Description: $($item.Metadata.Description)")
    $lines.Add('')
    $lines.Add("Default: $($item.DefaultValue)")
    $lines.Add("Raw (override): $(if ($item.OverridePresent) { $item.OverrideValue } else { '<немає>' })")
    $lines.Add("Effective: $($item.EffectiveValue)")
    $lines.Add("EffectiveSource: $($item.EffectiveSource)")
    if (-not [string]::IsNullOrWhiteSpace([string]$item.DisabledReason)) {
        $lines.Add("DisabledReason: $($item.DisabledReason)")
    }
    $DetailsTextBox.Text = [string]::Join([Environment]::NewLine, $lines.ToArray())
}

function Update-BRAVOConfiguratorUICenterPanel {
    param(
        [Parameter(Mandatory = $true)]$CenterPanel,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][scriptblock]$OnChanged,
        [Parameter(Mandatory = $true)][scriptblock]$OnSelected
    )

    $CenterPanel.SuspendLayout()
    $CenterPanel.Controls.Clear()

    $validationFindings = if ($null -ne $State.ValidationResult) { $State.ValidationResult.Findings } else { @() }
    $filtered = Get-BRAVOConfiguratorUIFilteredSettings -Model $State.Model -Filter $State.Filter -ValidationFindings $validationFindings
    $searched = Get-BRAVOConfiguratorUISearchMatches -Model $filtered -SearchText $State.SearchText
    $categoryFiltered = @($searched | Where-Object {
        ($null -eq $State.SelectedGroup) -or (
            [string]$_.Metadata.Group -eq $State.SelectedGroup -and (
                [string]::IsNullOrEmpty($State.SelectedSection) -or [string]$_.Metadata.Section -eq $State.SelectedSection
            )
        )
    })
    $orderedSettings = @($categoryFiltered | Sort-Object -Property `
        @{ Expression = { [string]$_.Metadata.Group } }, `
        @{ Expression = { [string]$_.Metadata.Section } }, `
        @{ Expression = { [int]$_.Metadata.Order } })

    $yPosition = 4
    foreach ($setting in $orderedSettings) {
        $row = New-BRAVOConfiguratorUISettingRow -Setting $setting -State $State -OnChanged $OnChanged -OnSelected $OnSelected
        $row.Location = New-Object System.Drawing.Point(4, $yPosition)
        $CenterPanel.Controls.Add($row)
        $yPosition += ($row.Height + 4)
    }

    $CenterPanel.ResumeLayout()
}

function Update-BRAVOConfiguratorUIStatusLabels {
    param(
        [Parameter(Mandatory = $true)]$DirtyLabel,
        [Parameter(Mandatory = $true)]$ValidationLabel,
        [Parameter(Mandatory = $true)][hashtable]$State
    )

    $isDirty = Get-BRAVOConfiguratorUIDirtyState -State $State
    $dirtyText = if ($isDirty) { 'Є незбережені зміни' } else { 'Змін немає' }
    if ($State.EffectiveStale) { $dirtyText += ' (потрібен перерахунок Effective)' }
    $DirtyLabel.Text = $dirtyText

    if ($null -ne $State.ValidationResult) {
        $ValidationLabel.Text = "Помилки: $($State.ValidationResult.ErrorCount)  Попередження: $($State.ValidationResult.WarningCount)  Інфо: $($State.ValidationResult.InfoCount)"
        $ValidationLabel.ForeColor = if ($State.ValidationResult.HasErrors) { [System.Drawing.Color]::Red } else { [System.Drawing.Color]::Black }
    } else {
        $ValidationLabel.Text = 'Валідація ще не запускалась'
    }
}

function Invoke-BRAVOConfiguratorUIRecalculate {
    <#
    .SYNOPSIS
        Реальний (child-process, секунди) перерахунок Effective + Validation
        для поточної $State.Model. Викликається ЛИШЕ явно (кнопка
        "Перерахувати" або перед побудовою Preview) — див. debounce-політику
        на початку файлу.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $State.Model = Update-BRAVOConfiguratorEffective -Model $State.Model -RuntimeRoot $State.RuntimeRoot
    $State.ValidationResult = Invoke-BRAVOConfiguratorValidation -Model $State.Model
    $State.EffectiveStale = $false
}

function Get-BRAVOConfiguratorUIEffectiveConfigSnapshot {
    <#
    .SYNOPSIS
        Отримує повний "сирий" effective config (storageEffective/
        bazaSyncEffective/backupMonitoring тощо) для поточної Model —
        потрібен Credentials-модулю (Get-BRAVOConfiguratorCredentialState/
        -Requirement приймають EffectiveConfig, не Model[]). Той самий
        canonical виклик, що Update-BRAVOConfiguratorEffective робить
        всередині — жодного дублювання логіки, лише повторний виклик
        того самого exported API з тими самими overrides.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $overrides = ConvertTo-BRAVOConfiguratorOverrideHashtable -Model $State.Model
    return Invoke-BRAVOConfiguratorEffectiveComputation -RuntimeRoot $State.RuntimeRoot -CandidateOverrides $overrides
}

function Update-BRAVOConfiguratorUICredentialLabels {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'CredentialState',
        Justification = 'Хибне спрацювання: параметр названо через слово "Credential" у сенсі Get-BRAVOConfiguratorCredentialState-результату (Required/Status-об''єкт), не пароль/секрет — секрети сюди ніколи не потрапляють (див. header-коментар BRAVO.Configurator.Credentials.psm1).')]
    param(
        [Parameter(Mandatory = $true)]$SftpLabel,
        [Parameter(Mandatory = $true)]$SmbLabel,
        [Parameter(Mandatory = $true)]$CredentialState
    )
    $SftpLabel.Text = "SFTP: Required=$($CredentialState.SFTP.Required) Status=$($CredentialState.SFTP.Status)"
    $SmbLabel.Text = "SMB: Required=$($CredentialState.SMB.Required) Status=$($CredentialState.SMB.Status)"
}

function Show-BRAVOConfiguratorUIPreviewDialog {
    <#
    .SYNOPSIS
        Показує модальний preview-діалог (RawChanges/EffectiveChanges/
        CredentialChanges/Warnings/BlockingErrors) перед реальним Apply.
        Повертає $true лише якщо оператор підтвердив І HasBlockingErrors=false
        (кнопка підтвердження вимкнена, коли є blocking errors).
    #>
    param([Parameter(Mandatory = $true)]$Preview)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'BRAVO Configurator — попередній перегляд змін'
    $dialog.Width = 720
    $dialog.Height = 560
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Multiline = $true
    $textBox.ReadOnly = $true
    $textBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $textBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $textBox.Font = New-Object System.Drawing.Font('Consolas', 9)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("=== Raw-зміни ($($Preview.RawChanges.Count)) ===")
    foreach ($change in $Preview.RawChanges) {
        $lines.Add("  [$($change.ChangeKind)] $($change.Path) ($($change.Label)): '$($change.BeforeValue)' -> '$($change.AfterValue)'")
    }
    $lines.Add('')
    $lines.Add("=== Effective-зміни ($($Preview.EffectiveChanges.Count)) ===")
    foreach ($change in $Preview.EffectiveChanges) {
        $reasonSuffix = if (-not [string]::IsNullOrWhiteSpace([string]$change.DisabledReason)) { " ($($change.DisabledReason))" } else { '' }
        $lines.Add("  $($change.Path) ($($change.Label)): '$($change.BeforeEffective)' -> '$($change.AfterEffective)'$reasonSuffix")
    }
    $lines.Add('')
    $lines.Add("=== Зміни вимог до креденшелів ($($Preview.CredentialChanges.Count)) ===")
    foreach ($change in $Preview.CredentialChanges) {
        $lines.Add("  $($change.Component): Required $($change.BeforeRequired) -> $($change.AfterRequired)")
    }
    $lines.Add('')
    $lines.Add("=== Попередження/Info ($($Preview.Warnings.Count)) ===")
    foreach ($warning in $Preview.Warnings) {
        $lines.Add("  [$($warning.Severity)] $($warning.Path): $($warning.Message)")
    }
    $lines.Add('')
    $lines.Add("=== Блокуючі помилки ($($Preview.BlockingErrors.Count)) ===")
    foreach ($blockingError in $Preview.BlockingErrors) {
        $lines.Add("  [ERROR] $($blockingError.Path): $($blockingError.Message)")
    }
    $textBox.Text = [string]::Join([Environment]::NewLine, $lines.ToArray())

    $buttonPanel = New-Object System.Windows.Forms.Panel
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $buttonPanel.Height = 44

    $confirmButton = New-Object System.Windows.Forms.Button
    $confirmButton.Text = 'Застосувати'
    $confirmButton.Location = New-Object System.Drawing.Point(10, 8)
    $confirmButton.Width = 140
    $confirmButton.Enabled = -not [bool]$Preview.HasBlockingErrors
    $confirmButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $buttonPanel.Controls.Add($confirmButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Скасувати'
    $cancelButton.Location = New-Object System.Drawing.Point(160, 8)
    $cancelButton.Width = 140
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $buttonPanel.Controls.Add($cancelButton)

    $dialog.Controls.Add($textBox)
    $dialog.Controls.Add($buttonPanel)
    $dialog.AcceptButton = $confirmButton
    $dialog.CancelButton = $cancelButton

    $result = $dialog.ShowDialog()
    return ($result -eq [System.Windows.Forms.DialogResult]::OK) -and (-not [bool]$Preview.HasBlockingErrors)
}

function Confirm-BRAVOConfiguratorUIDiscardChanges {
    # Повертає $true, якщо оператор погодився закрити форму (немає змін,
    # або явно підтвердив відкидання незбережених змін).
    param([Parameter(Mandatory = $true)][hashtable]$State)

    if (-not (Get-BRAVOConfiguratorUIDirtyState -State $State)) { return $true }
    $result = [System.Windows.Forms.MessageBox]::Show(
        'Є незбережені зміни. Закрити без застосування?',
        'BRAVO Configurator',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

# =====================================================================
# 3. Публічна точка входу
# =====================================================================

function Show-BRAVOConfiguratorMainForm {
    <#
    .SYNOPSIS
        Блокуючий (ShowDialog) головний entrypoint UI Configurator-а.
        Не кидає виняток на звичайних операторських діях (помилки
        валідації/відхилений Apply показуються в UI, не як exception) —
        лише справді фатальний старт (напр. schema каталог не читається)
        може пробити назовні до BRAVO_CONFIGURATOR.ps1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ProductionConfigDirectory
    )

    Initialize-BRAVOConfiguratorUIAssemblies

    # ===== Початкове (фатальне на помилці) завантаження =====
    $schemaCatalog = Get-BRAVOConfiguratorSchemaCatalog
    $productionBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $RuntimeRoot -ProductionConfigDirectory $ProductionConfigDirectory
    $defaultConfig = Invoke-BRAVOConfiguratorEffectiveComputation -RuntimeRoot $RuntimeRoot -CandidateOverrides @{}
    $initialModel = Get-BRAVOConfiguratorModel -SchemaCatalog $schemaCatalog -DefaultConfig $defaultConfig -LocalOverrides $productionBaseline.Overrides
    $initialModel = Update-BRAVOConfiguratorEffective -Model $initialModel -RuntimeRoot $RuntimeRoot
    $initialValidation = Invoke-BRAVOConfiguratorValidation -Model $initialModel

    $state = @{
        RuntimeRoot               = $RuntimeRoot
        ProductionConfigDirectory = $ProductionConfigDirectory
        SchemaCatalog              = $schemaCatalog
        ProductionBaseline         = $productionBaseline
        OriginalModel              = $initialModel
        Model                      = $initialModel
        ValidationResult           = $initialValidation
        RequirementBefore          = $null
        SelectedGroup              = $null
        SelectedSection            = $null
        SearchText                 = ''
        Filter                     = 'All'
        EffectiveStale             = $false
        # P2-A.4: exit-semantics — Applied/Cancelled/NoChanges НЕ мапляться
        # на різні OS exit-коди (жоден automation-caller сьогодні їх не
        # розрізняє; Configurator — інтерактивний desktop-інструмент, не
        # scheduled-завдання під BRAVO.ExitCodes). Натомість — structured
        # internal result, який Show-BRAVOConfiguratorMainForm повертає
        # викликачу; BRAVO_CONFIGURATOR.ps1 лишає exit 0 для всіх трьох.
        AnyApplySucceeded          = $false
        InitialBaselineOverrides   = $productionBaseline.Overrides
    }
    try {
        $initialSnapshot = Get-BRAVOConfiguratorUIEffectiveConfigSnapshot -State $state
        $state.RequirementBefore = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $initialSnapshot
    } catch {
        # Некритично для старту форми — credential-вимоги просто
        # лишаться невідомі до першого явного "Перевірити"/Apply.
        $state.RequirementBefore = $null
    }

    # ===== Форма і панелі =====
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'BRAVO Configurator'
    $form.Width = 1150
    $form.Height = 780
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen

    # --- Верхня панель: пошук, фільтр, пресети, креденшели ---
    $topPanel = New-Object System.Windows.Forms.Panel
    $topPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $topPanel.Height = 90

    $searchLabel = New-Object System.Windows.Forms.Label
    $searchLabel.Text = 'Пошук:'
    $searchLabel.Location = New-Object System.Drawing.Point(8, 10)
    $searchLabel.Width = 50
    $topPanel.Controls.Add($searchLabel)

    $searchTextBox = New-Object System.Windows.Forms.TextBox
    $searchTextBox.Location = New-Object System.Drawing.Point(60, 8)
    $searchTextBox.Width = 220
    $topPanel.Controls.Add($searchTextBox)

    $filterLabel = New-Object System.Windows.Forms.Label
    $filterLabel.Text = 'Фільтр:'
    $filterLabel.Location = New-Object System.Drawing.Point(290, 10)
    $filterLabel.Width = 45
    $topPanel.Controls.Add($filterLabel)

    $filterComboBox = New-Object System.Windows.Forms.ComboBox
    $filterComboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $filterComboBox.Location = New-Object System.Drawing.Point(340, 8)
    $filterComboBox.Width = 120
    foreach ($filterName in @('All', 'Changed', 'Active', 'Problems', 'Advanced')) { [void]$filterComboBox.Items.Add($filterName) }
    $filterComboBox.SelectedItem = 'All'
    $topPanel.Controls.Add($filterComboBox)

    $presetLabel = New-Object System.Windows.Forms.Label
    $presetLabel.Text = 'Пресет:'
    $presetLabel.Location = New-Object System.Drawing.Point(470, 10)
    $presetLabel.Width = 50
    $topPanel.Controls.Add($presetLabel)

    $presetComboBox = New-Object System.Windows.Forms.ComboBox
    $presetComboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $presetComboBox.Location = New-Object System.Drawing.Point(525, 8)
    $presetComboBox.Width = 170
    $presetCatalog = Get-BRAVOConfiguratorPresetCatalog
    foreach ($preset in $presetCatalog) { [void]$presetComboBox.Items.Add([string]$preset.Label) }
    if ($presetComboBox.Items.Count -gt 0) { $presetComboBox.SelectedIndex = 0 }
    $topPanel.Controls.Add($presetComboBox)

    $presetApplyButton = New-Object System.Windows.Forms.Button
    $presetApplyButton.Text = 'Застосувати пресет'
    $presetApplyButton.Location = New-Object System.Drawing.Point(700, 7)
    $presetApplyButton.Width = 150
    $topPanel.Controls.Add($presetApplyButton)

    $sftpCredLabel = New-Object System.Windows.Forms.Label
    $sftpCredLabel.Text = 'SFTP: —'
    $sftpCredLabel.Location = New-Object System.Drawing.Point(8, 40)
    $sftpCredLabel.Width = 300
    $topPanel.Controls.Add($sftpCredLabel)

    $smbCredLabel = New-Object System.Windows.Forms.Label
    $smbCredLabel.Text = 'SMB: —'
    $smbCredLabel.Location = New-Object System.Drawing.Point(8, 60)
    $smbCredLabel.Width = 300
    $topPanel.Controls.Add($smbCredLabel)

    $credCheckButton = New-Object System.Windows.Forms.Button
    $credCheckButton.Text = 'Перевірити креденшели'
    $credCheckButton.Location = New-Object System.Drawing.Point(320, 40)
    $credCheckButton.Width = 170
    $topPanel.Controls.Add($credCheckButton)

    $credSetupSftpButton = New-Object System.Windows.Forms.Button
    $credSetupSftpButton.Text = 'Налаштувати SFTP'
    $credSetupSftpButton.Location = New-Object System.Drawing.Point(500, 40)
    $credSetupSftpButton.Width = 150
    $topPanel.Controls.Add($credSetupSftpButton)

    $credSetupSmbButton = New-Object System.Windows.Forms.Button
    $credSetupSmbButton.Text = 'Налаштувати SMB'
    $credSetupSmbButton.Location = New-Object System.Drawing.Point(660, 40)
    $credSetupSmbButton.Width = 150
    $topPanel.Controls.Add($credSetupSmbButton)

    $form.Controls.Add($topPanel)

    # --- Нижня панель: dirty/validation, Перерахувати/Apply/Cancel ---
    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottomPanel.Height = 70

    $dirtyLabel = New-Object System.Windows.Forms.Label
    $dirtyLabel.Location = New-Object System.Drawing.Point(8, 8)
    $dirtyLabel.Width = 400
    $bottomPanel.Controls.Add($dirtyLabel)

    $validationLabel = New-Object System.Windows.Forms.Label
    $validationLabel.Location = New-Object System.Drawing.Point(8, 28)
    $validationLabel.Width = 500
    $bottomPanel.Controls.Add($validationLabel)

    # P2-фікс за результатами незалежного review (Agent D): повідомлення
    # RaceDetection буквально каже "Reload configuration before applying
    # your changes", але до цього фіксу форма не мала жодного способу це
    # зробити — лише закрити й перезапустити BRAVO_CONFIGURATOR.ps1.
    $reloadButton = New-Object System.Windows.Forms.Button
    $reloadButton.Text = 'Перезавантажити'
    $reloadButton.Location = New-Object System.Drawing.Point(570, 15)
    $reloadButton.Width = 120
    $bottomPanel.Controls.Add($reloadButton)

    $recalculateButton = New-Object System.Windows.Forms.Button
    $recalculateButton.Text = 'Перерахувати'
    $recalculateButton.Location = New-Object System.Drawing.Point(700, 15)
    $recalculateButton.Width = 120
    $bottomPanel.Controls.Add($recalculateButton)

    $applyButton = New-Object System.Windows.Forms.Button
    $applyButton.Text = 'Застосувати...'
    $applyButton.Location = New-Object System.Drawing.Point(830, 15)
    $applyButton.Width = 120
    $bottomPanel.Controls.Add($applyButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Скасувати'
    $cancelButton.Location = New-Object System.Drawing.Point(960, 15)
    $cancelButton.Width = 120
    $bottomPanel.Controls.Add($cancelButton)

    # P2-A.6: скидання всіх overrides ПОТОЧНОЇ обраної секції до Default —
    # bulk-операція, для якої раніше не було UI-шляху (одиночний setting
    # уже скидається зняттям override-checkbox у рядку — Clear-BRAVOConfiguratorOverride,
    # той самий контракт §1.3 "Використовувати default"). Активна лише
    # коли в дереві обрано КОНКРЕТНУ секцію (не групу цілком і не "Усі категорії").
    $resetSectionButton = New-Object System.Windows.Forms.Button
    $resetSectionButton.Text = 'Скинути секцію'
    $resetSectionButton.Location = New-Object System.Drawing.Point(570, 43)
    $resetSectionButton.Width = 160
    $resetSectionButton.Enabled = $false
    $bottomPanel.Controls.Add($resetSectionButton)

    $form.Controls.Add($bottomPanel)

    # --- Середня частина: TreeView | центр (settings) | деталі ---
    $mainSplit = New-Object System.Windows.Forms.SplitContainer
    $mainSplit.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainSplit.SplitterDistance = 220

    $categoryTree = New-Object System.Windows.Forms.TreeView
    $categoryTree.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainSplit.Panel1.Controls.Add($categoryTree)

    $rightSplit = New-Object System.Windows.Forms.SplitContainer
    $rightSplit.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rightSplit.SplitterDistance = 620

    $centerScrollPanel = New-Object System.Windows.Forms.Panel
    $centerScrollPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $centerScrollPanel.AutoScroll = $true
    $rightSplit.Panel1.Controls.Add($centerScrollPanel)

    $detailsTextBox = New-Object System.Windows.Forms.TextBox
    $detailsTextBox.Multiline = $true
    $detailsTextBox.ReadOnly = $true
    $detailsTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $detailsTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rightSplit.Panel2.Controls.Add($detailsTextBox)

    $mainSplit.Panel2.Controls.Add($rightSplit)
    $form.Controls.Add($mainSplit)
    $mainSplit.BringToFront()
    $topPanel.SendToBack()

    # ===== Заповнення TreeView з чистої Get-BRAVOConfiguratorUICategoryTree =====
    $categoryTreeData = Get-BRAVOConfiguratorUICategoryTree -SchemaCatalog $schemaCatalog
    $rootNode = New-Object System.Windows.Forms.TreeNode('Усі категорії')
    [void]$categoryTree.Nodes.Add($rootNode)
    foreach ($groupEntry in $categoryTreeData) {
        $groupNode = New-Object System.Windows.Forms.TreeNode("$($groupEntry.Group) ($($groupEntry.DescriptorCount))")
        $groupNode.Tag = @{ Group = $groupEntry.Group; Section = $null }
        foreach ($sectionEntry in $groupEntry.Sections) {
            $sectionNode = New-Object System.Windows.Forms.TreeNode("$($sectionEntry.Section) ($($sectionEntry.DescriptorCount))")
            $sectionNode.Tag = @{ Group = $groupEntry.Group; Section = $sectionEntry.Section }
            [void]$groupNode.Nodes.Add($sectionNode)
        }
        [void]$rootNode.Nodes.Add($groupNode)
    }
    $rootNode.Expand()

    # ===== Callbacks, спільні для рядків налаштувань =====
    # P1-фікс (stabilization): без .GetNewClosure() — ці scriptblock-и
    # визначаються один раз (не в циклі) в тілі Show-BRAVOConfiguratorMainForm,
    # а форма блокує виконання через ShowDialog() на весь час своєї роботи,
    # тому лексичний scope цієй функції лишається живим і доступним для
    # прямого виклику приватних функцій модуля (Update-BRAVOConfiguratorUI*)
    # аж до закриття форми. .GetNewClosure() тут не додає жодної потрібної
    # семантики (немає циклу/повторного виклику з різними значеннями), але
    # ламає резолюцію приватних module-функцій у Windows PowerShell 5.1 —
    # див. коментар біля $showMessageRef вище.
    $onChanged = {
        param($path, $overridePresent, $value)
        if ($overridePresent) {
            $state.Model = Set-BRAVOConfiguratorOverride -Model $state.Model -Path $path -Value $value
        } else {
            $state.Model = Clear-BRAVOConfiguratorOverride -Model $state.Model -Path $path
        }
        $state.EffectiveStale = $true
        Update-BRAVOConfiguratorUIStatusLabels -DirtyLabel $dirtyLabel -ValidationLabel $validationLabel -State $state
    }

    $onSelected = {
        param($path)
        Update-BRAVOConfiguratorUIDetailsPanel -DetailsTextBox $detailsTextBox -State $state -Path $path
    }

    $refreshCenterPanel = {
        Update-BRAVOConfiguratorUICenterPanel -CenterPanel $centerScrollPanel -State $state -OnChanged $onChanged -OnSelected $onSelected
    }

    & $refreshCenterPanel
    Update-BRAVOConfiguratorUIStatusLabels -DirtyLabel $dirtyLabel -ValidationLabel $validationLabel -State $state

    # ===== Wiring подій =====
    $categoryTree.Add_AfterSelect({
        $tag = $categoryTree.SelectedNode.Tag
        if ($null -eq $tag) {
            $state.SelectedGroup = $null
            $state.SelectedSection = $null
        } else {
            $state.SelectedGroup = $tag.Group
            $state.SelectedSection = $tag.Section
        }
        $resetSectionButton.Enabled = (-not [string]::IsNullOrEmpty($state.SelectedSection)) -and ($null -ne $state.SelectedGroup)
        & $refreshCenterPanel
    })

    $resetSectionButton.Add_Click({
        if ([string]::IsNullOrEmpty($state.SelectedSection) -or $null -eq $state.SelectedGroup) { return }
        $affectedCount = @($state.Model | Where-Object {
            [string]$_.Metadata.Group -eq $state.SelectedGroup -and [string]$_.Metadata.Section -eq $state.SelectedSection -and [bool]$_.OverridePresent
        }).Count
        if ($affectedCount -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "У секції '$($state.SelectedSection)' немає активних override — нічого скидати.",
                'BRAVO Configurator',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        $confirmResult = [System.Windows.Forms.MessageBox]::Show(
            "Скинути $affectedCount налаштувань секції '$($state.SelectedSection)' до значень за замовчуванням? Інші секції не постраждають.",
            'BRAVO Configurator',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $state.Model = Reset-BRAVOConfiguratorSection -Model $state.Model -Group $state.SelectedGroup -Section $state.SelectedSection
        $state.EffectiveStale = $true
        & $refreshCenterPanel
        Update-BRAVOConfiguratorUIStatusLabels -DirtyLabel $dirtyLabel -ValidationLabel $validationLabel -State $state
    })

    $searchTextBox.Add_TextChanged({
        $state.SearchText = $searchTextBox.Text
        & $refreshCenterPanel
    })

    $filterComboBox.Add_SelectedIndexChanged({
        $state.Filter = [string]$filterComboBox.SelectedItem
        & $refreshCenterPanel
    })

    $presetApplyButton.Add_Click({
        if ($presetComboBox.SelectedIndex -lt 0) { return }
        $selectedPreset = $presetCatalog[$presetComboBox.SelectedIndex]
        $state.Model = Invoke-BRAVOConfiguratorPreset -Model $state.Model -PresetName $selectedPreset.Name
        $state.EffectiveStale = $true
        & $refreshCenterPanel
        Update-BRAVOConfiguratorUIStatusLabels -DirtyLabel $dirtyLabel -ValidationLabel $validationLabel -State $state
    })

    $recalculateButton.Add_Click({
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            Invoke-BRAVOConfiguratorUIRecalculate -State $state
        } catch {
            Show-BRAVOConfiguratorUIMessage -Text "Не вдалося перерахувати Effective: $($_.Exception.Message)" -Icon Error
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
        & $refreshCenterPanel
        Update-BRAVOConfiguratorUIStatusLabels -DirtyLabel $dirtyLabel -ValidationLabel $validationLabel -State $state
    })

    $credCheckButton.Add_Click({
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $snapshot = Get-BRAVOConfiguratorUIEffectiveConfigSnapshot -State $state
            $credState = Get-BRAVOConfiguratorCredentialState -RuntimeRoot $state.RuntimeRoot -EffectiveConfig $snapshot
            Update-BRAVOConfiguratorUICredentialLabels -SftpLabel $sftpCredLabel -SmbLabel $smbCredLabel -CredentialState $credState
        } catch {
            Show-BRAVOConfiguratorUIMessage -Text "Не вдалося перевірити креденшели: $($_.Exception.Message)" -Icon Error
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    $credSetupSftpButton.Add_Click({
        try {
            [void](Invoke-BRAVOConfiguratorCredentialSetup -RuntimeRoot $state.RuntimeRoot -Component 'SFTP')
        } catch {
            Show-BRAVOConfiguratorUIMessage -Text "Налаштування SFTP-креденшелів не вдалося: $($_.Exception.Message)" -Icon Error
        }
    })

    $credSetupSmbButton.Add_Click({
        try {
            [void](Invoke-BRAVOConfiguratorCredentialSetup -RuntimeRoot $state.RuntimeRoot -Component 'SMB')
        } catch {
            Show-BRAVOConfiguratorUIMessage -Text "Налаштування SMB-креденшелів не вдалося: $($_.Exception.Message)" -Icon Error
        }
    })

    $applyButton.Add_Click({
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            Invoke-BRAVOConfiguratorUIRecalculate -State $state
        } catch {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            Show-BRAVOConfiguratorUIMessage -Text "Не вдалося перерахувати Effective перед Apply: $($_.Exception.Message)" -Icon Error
            return
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        & $refreshCenterPanel
        Update-BRAVOConfiguratorUIStatusLabels -DirtyLabel $dirtyLabel -ValidationLabel $validationLabel -State $state

        $requirementAfter = $null
        try {
            $snapshotAfter = Get-BRAVOConfiguratorUIEffectiveConfigSnapshot -State $state
            $requirementAfter = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $snapshotAfter
        } catch {
            $requirementAfter = $null
        }

        $preview = Get-BRAVOConfiguratorPreview -ModelBefore $state.OriginalModel -ModelAfter $state.Model `
            -RequirementStateBefore $state.RequirementBefore -RequirementStateAfter $requirementAfter

        if (-not $preview.HasChanges) {
            Show-BRAVOConfiguratorUIMessage -Text 'Немає змін для застосування.'
            return
        }

        $confirmed = Show-BRAVOConfiguratorUIPreviewDialog -Preview $preview
        if (-not $confirmed) { return }

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $applyResult = $null
        try {
            $applyResult = Invoke-BRAVOConfiguratorApply -RuntimeRoot $state.RuntimeRoot `
                -ProductionConfigDirectory $state.ProductionConfigDirectory `
                -Model $state.Model -SchemaCatalog $state.SchemaCatalog `
                -ProductionBaseline $state.ProductionBaseline
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }

        if ($applyResult.Applied) {
            $state.AnyApplySucceeded = $true
            Show-BRAVOConfiguratorUIMessage -Text "Застосовано успішно. Змінені шляхи: $($applyResult.AppliedPaths -join ', ')"
            # Reload з диску — стан після Apply стає новим baseline/OriginalModel.
            $state.ProductionBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $state.RuntimeRoot -ProductionConfigDirectory $state.ProductionConfigDirectory
            $reloadedModel = Get-BRAVOConfiguratorModel -SchemaCatalog $state.SchemaCatalog -DefaultConfig $defaultConfig -LocalOverrides $state.ProductionBaseline.Overrides
            $reloadedModel = Update-BRAVOConfiguratorEffective -Model $reloadedModel -RuntimeRoot $state.RuntimeRoot
            $state.Model = $reloadedModel
            $state.OriginalModel = $reloadedModel
            $state.ValidationResult = Invoke-BRAVOConfiguratorValidation -Model $reloadedModel
            $state.EffectiveStale = $false
            try {
                $reloadedSnapshot = Get-BRAVOConfiguratorUIEffectiveConfigSnapshot -State $state
                $state.RequirementBefore = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $reloadedSnapshot
            } catch {
                $state.RequirementBefore = $null
            }
            & $refreshCenterPanel
            Update-BRAVOConfiguratorUIStatusLabels -DirtyLabel $dirtyLabel -ValidationLabel $validationLabel -State $state
        } elseif ($applyResult.Stage -eq 'RaceDetection') {
            Show-BRAVOConfiguratorUIMessage `
                -Text "BRAVO.local.config was changed by another process.`n`nYour changes were NOT written.`n`nReload configuration before applying your changes." `
                -Icon Warning
        } else {
            Show-BRAVOConfiguratorUIMessage -Text "Apply відхилено (Stage=$($applyResult.Stage)):`n$($applyResult.Reasons -join [Environment]::NewLine)" -Icon Error
        }
    })

    $cancelButton.Add_Click({
        if (Confirm-BRAVOConfiguratorUIDiscardChanges -State $state) { $form.Close() }
    })

    # P2-фікс за результатами незалежного review (Agent D): раніше
    # єдиний спосіб реально "reload configuration" (як велить
    # RaceDetection-повідомлення нижче) — закрити форму й перезапустити
    # BRAVO_CONFIGURATOR.ps1. Той самий discard-confirm gate, що Cancel/
    # FormClosing — reload відкидає незастосовані правки, тому потребує
    # такого ж явного підтвердження.
    $reloadButton.Add_Click({
        if (-not (Confirm-BRAVOConfiguratorUIDiscardChanges -State $state)) { return }
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $state.ProductionBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $state.RuntimeRoot -ProductionConfigDirectory $state.ProductionConfigDirectory
            $reloadedModel = Get-BRAVOConfiguratorModel -SchemaCatalog $state.SchemaCatalog -DefaultConfig $defaultConfig -LocalOverrides $state.ProductionBaseline.Overrides
            $reloadedModel = Update-BRAVOConfiguratorEffective -Model $reloadedModel -RuntimeRoot $state.RuntimeRoot
            $state.Model = $reloadedModel
            $state.OriginalModel = $reloadedModel
            $state.ValidationResult = Invoke-BRAVOConfiguratorValidation -Model $reloadedModel
            $state.EffectiveStale = $false
            try {
                $reloadedSnapshot = Get-BRAVOConfiguratorUIEffectiveConfigSnapshot -State $state
                $state.RequirementBefore = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $reloadedSnapshot
            } catch {
                $state.RequirementBefore = $null
            }
        } catch {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            Show-BRAVOConfiguratorUIMessage -Text "Не вдалося перезавантажити конфігурацію з диска: $($_.Exception.Message)" -Icon Error
            return
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        & $refreshCenterPanel
        Update-BRAVOConfiguratorUIStatusLabels -DirtyLabel $dirtyLabel -ValidationLabel $validationLabel -State $state
    })

    $form.Add_FormClosing({
        param($formSender, $formArgs)
        if (-not (Confirm-BRAVOConfiguratorUIDiscardChanges -State $state)) {
            $formArgs.Cancel = $true
        }
    })

    [void]$form.ShowDialog()

    # P2-A.4: Applied завжди має пріоритет — навіть якщо оператор після
    # успішного Apply ще щось редагував і зрештою закрив форму без
    # повторного застосування, зміни ВЖЕ persisted у production. Інакше —
    # діагностуємо через справжній diff (Test-BRAVOConfiguratorModelDirty,
    # P2-A.3) проти самого першого baseline цієї сесії: Cancelled, якщо
    # лишились незастосовані відхилення, NoChanges — якщо форму закрито
    # без жодної реальної зміни (порожня сесія або edit->revert).
    if ($state.AnyApplySucceeded) {
        return 'Applied'
    } elseif (Test-BRAVOConfiguratorModelDirty -Model $state.Model -BaselineOverrides $state.InitialBaselineOverrides) {
        return 'Cancelled'
    } else {
        return 'NoChanges'
    }
}

Export-ModuleMember -Function @(
    'Show-BRAVOConfiguratorMainForm',
    'Get-BRAVOConfiguratorUIReachablePaths',
    'Get-BRAVOConfiguratorUIFilteredSettings',
    'Get-BRAVOConfiguratorUISearchMatches',
    'Get-BRAVOConfiguratorUICategoryTree',
    'Get-BRAVOConfiguratorUIBooleanTriState',
    'ConvertTo-BRAVOConfiguratorUIDisplayText',
    'ConvertTo-BRAVOConfiguratorUITypedValue'
)
