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
#
# P2-B (UX/DPI/keyboard/context-help hardening, docs/design/
# BRAVO_CONFIGURATOR_DESIGN.md §12) НЕ змінює жодну з семантик вище —
# лише responsive-layout/DPI/keyboard/accessibility шар навколо того
# самого backend-контракту. Schema/Effective/Persistence/Presets/
# Credentials/Dirty/session-outcome/fail-closed поведінка не зачіпаються.

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

        P2-B: внутрішні ID фільтрів (і backend-семантика вище) НЕ
        змінюються — Get-BRAVOConfiguratorUIFilterOptions лише додає
        українську підпис-проєкцію для ComboBox, filtering тут лишається
        єдиним джерелом істини.
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

# ---------------------------------------------------------------------
# P2-B pure helpers (§26 задачі: deterministic headless layout tests) —
# усі рішення про breakpoint/розмір/затискання splitter обчислюються
# ТУТ, а не всередині WinForms-функцій нижче, саме щоб їх можна було
# протестувати без побудови реальної форми.
# ---------------------------------------------------------------------

$script:BRAVOConfiguratorUICompactWidthThreshold = 1000

function Get-BRAVOConfiguratorUILayoutMode {
    <#
    .SYNOPSIS
        Визначає режим компонування середньої частини форми (§13 задачі
        P2-B): 'Wide' — Categories | Settings | Details одним рядом;
        'Compact' — права SplitContainer-пара (Settings/Details) стає
        горизонтальною (Details знизу), а не вертикальною (Details
        праворуч). Один канонічний breakpoint-поріг — не дублюється по
        файлу.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ClientWidth
    )
    if ($ClientWidth -lt $script:BRAVOConfiguratorUICompactWidthThreshold) {
        return 'Compact'
    }
    return 'Wide'
}

function Get-BRAVOConfiguratorUIFilterOptions {
    <#
    .SYNOPSIS
        Канонічна відповідність внутрішнього (backend, ValidateSet
        Get-BRAVOConfiguratorUIFilteredSettings) ідентифікатора фільтра
        і українського відображуваного підпису (§21 задачі P2-B). Порядок
        масиву = порядок пунктів у ComboBox (DisplayMember='Label',
        ValueMember='Id'). Backend-семантика фільтрації НЕ змінюється —
        це лише проєкція для відображення, filtering й далі виконує
        Get-BRAVOConfiguratorUIFilteredSettings за Id.
    #>
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{ Id = 'All';      Label = 'Усі' }
        [pscustomobject]@{ Id = 'Changed';  Label = 'Змінені' }
        [pscustomobject]@{ Id = 'Active';   Label = 'Активні' }
        [pscustomobject]@{ Id = 'Problems'; Label = 'Проблеми' }
        [pscustomobject]@{ Id = 'Advanced'; Label = 'Розширені' }
    )
}

function Get-BRAVOConfiguratorUISettingHelpText {
    <#
    .SYNOPSIS
        Форматує Details-панель/F1 context-help текст для одного
        Model-запису (§14 задачі P2-B): спершу операторський зміст
        (Назва/Опис/Поточний стан/Default/Local override/Effective/
        Effective source/Disabled reason), потім технічні дані
        (Path/Group/Section/Type/Advanced). Використовує ЛИШЕ schema/
        model metadata, яка вже проходить через Validation/Effective —
        жодних secrets/паролів/credential-значень тут ніколи немає (той
        самий Model[], що й решта UI-шару; Credential Manager-значення
        взагалі не потрапляють у Model).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Setting
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $label = [string]$Setting.Metadata.Label
    if ([string]::IsNullOrWhiteSpace($label)) { $label = [string]$Setting.Path }

    $currentStateText = if ([bool]$Setting.OverridePresent) { 'Локальний override активний' } else { 'Використовується значення за замовчуванням' }

    $lines.Add("Назва: $label")
    $lines.Add("Опис: $([string]$Setting.Metadata.Description)")
    $lines.Add("Поточний стан: $currentStateText")
    $lines.Add('')
    $lines.Add("Default: $($Setting.DefaultValue)")
    $lines.Add("Local override: $(if ($Setting.OverridePresent) { $Setting.OverrideValue } else { '<немає>' })")
    $lines.Add("Effective: $($Setting.EffectiveValue)")
    $lines.Add("Effective source: $($Setting.EffectiveSource)")
    if (-not [string]::IsNullOrWhiteSpace([string]$Setting.DisabledReason)) {
        $lines.Add("Disabled reason: $($Setting.DisabledReason)")
    }
    $lines.Add('')
    $lines.Add("Path: $($Setting.Path)")
    $lines.Add("Group / Section: $($Setting.Metadata.Group) / $($Setting.Metadata.Section)")
    $lines.Add("Type: $($Setting.Metadata.Type)")
    $lines.Add("Advanced: $($Setting.Metadata.Advanced)")

    return [string]::Join([Environment]::NewLine, $lines.ToArray())
}

function Get-BRAVOConfiguratorUIGeneralHelpText {
    <#
    .SYNOPSIS
        Загальний F1-текст, коли жодне налаштування не обрано (§15
        задачі P2-B). Статичний рядок — не документаційний браузер і не
        зовнішня веб-сторінка.
    #>
    [CmdletBinding()]
    param()
    return (@(
        'BRAVO Configurator — контекстна довідка'
        ''
        'Оберіть налаштування ліворуч, щоб побачити його опис, поточний стан і Effective-значення.'
        ''
        'Клавіатурні скорочення:'
        '  Ctrl+F — фокус на полі пошуку'
        '  F1     — контекстна довідка для обраного налаштування'
        '  F5     — Перезавантажити (з підтвердженням, якщо є незбережені зміни)'
        '  Esc    — Скасувати (з підтвердженням, якщо є незбережені зміни)'
        '  Tab / Shift+Tab — навігація між елементами керування'
    ) -join [Environment]::NewLine)
}

function Get-BRAVOConfiguratorUIStartupSize {
    <#
    .SYNOPSIS
        Обчислює безпечний початковий розмір вікна (§5/§24 задачі P2-B):
        ніколи не більший за Screen.WorkingArea, але й не менший за
        практичний мінімум (за замовчуванням — придатний для 1024x768
        @ 100%). Чиста функція — не читає жодного реального
        System.Windows.Forms.Screen; приймає вже виміряні числа
        (headless-тестована), тому придатна і для головної форми, і для
        Preview-діалогу з різними Preferred/Min значеннями.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$WorkingAreaWidth,
        [Parameter(Mandatory = $true)][int]$WorkingAreaHeight,
        [int]$PreferredWidth = 1150,
        [int]$PreferredHeight = 780,
        [int]$MinWidth = 1000,
        [int]$MinHeight = 650
    )

    # Ніколи не більше усього робочого простору екрана.
    $width = [Math]::Min($PreferredWidth, $WorkingAreaWidth)
    $height = [Math]::Min($PreferredHeight, $WorkingAreaHeight)

    # Не менше практичного мінімуму, ЯКЩО робоча область це дозволяє —
    # інакше пріоритет за WorkingArea (не відкривати вікно, що фізично
    # не влазить на екран, лише щоб дотриматись Min*).
    if ($WorkingAreaWidth -ge $MinWidth) { $width = [Math]::Max($width, $MinWidth) }
    if ($WorkingAreaHeight -ge $MinHeight) { $height = [Math]::Max($height, $MinHeight) }

    return [pscustomobject]@{ Width = $width; Height = $height }
}

function Get-BRAVOConfiguratorUIClampedSplitterDistance {
    <#
    .SYNOPSIS
        Затискає бажану SplitterDistance у легальний діапазон
        [Panel1MinSize, AvailableSize-Panel2MinSize] (§12/§13 задачі
        P2-B) — SplitContainer.SplitterDistance кидає
        ArgumentOutOfRangeException на значенні поза цим діапазоном,
        зокрема одразу після DPI-масштабування, зміни орієнтації чи
        запуску з малим стартовим розміром вікна. Якщо AvailableSize
        замалий для обох мінімумів одночасно — повертає Panel1MinSize
        (найменше безпечне значення), НЕ кидає виняток.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$AvailableSize,
        [Parameter(Mandatory = $true)][int]$Panel1MinSize,
        [Parameter(Mandatory = $true)][int]$Panel2MinSize,
        [Parameter(Mandatory = $true)][int]$DesiredDistance
    )

    $maxDistance = $AvailableSize - $Panel2MinSize
    if ($maxDistance -lt $Panel1MinSize) {
        return $Panel1MinSize
    }
    if ($DesiredDistance -lt $Panel1MinSize) { return $Panel1MinSize }
    if ($DesiredDistance -gt $maxDistance) { return $maxDistance }
    return $DesiredDistance
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

function Set-BRAVOConfiguratorUISplitterDistanceSafe {
    <#
    .SYNOPSIS
        Затискає й безпечно призначає SplitterDistance (§12/§13 задачі
        P2-B) — обгортка над чистою Get-BRAVOConfiguratorUIClampedSplitterDistance
        з захисним try/catch на межовий WinForms-race (заокруглення
        border/DPI вже ПІСЛЯ обчислення затиснутого значення) — НЕ
        приховує бізнес-помилку, лише конкретний відомий WinForms-квірк
        навколо SplitContainer.SplitterDistance.
    #>
    param(
        [Parameter(Mandatory = $true)]$SplitContainer,
        [Parameter(Mandatory = $true)][int]$DesiredDistance
    )
    $available = if ($SplitContainer.Orientation -eq [System.Windows.Forms.Orientation]::Horizontal) {
        $SplitContainer.ClientSize.Height
    } else {
        $SplitContainer.ClientSize.Width
    }
    $clamped = Get-BRAVOConfiguratorUIClampedSplitterDistance -AvailableSize $available `
        -Panel1MinSize $SplitContainer.Panel1MinSize -Panel2MinSize $SplitContainer.Panel2MinSize `
        -DesiredDistance $DesiredDistance
    try {
        $SplitContainer.SplitterDistance = $clamped
    } catch [System.ArgumentException] {
        # Захисний fallback — див. .SYNOPSIS. Навмисно порожньо: значення
        # лишається попереднім легальним SplitterDistance.
    }
}

function New-BRAVOConfiguratorUISettingRow {
    <#
    .SYNOPSIS
        Будує один рядок панелі налаштувань: checkbox "override" + типовий
        редактор значення + статус-мітка (EffectiveSource/DisabledReason).
        Жодна подія тут НЕ пише на диск і НЕ викликає
        Update-BRAVOConfiguratorEffective — лише Set/Clear-BRAVOConfiguratorOverride
        через $OnChanged callback (мутує $State.Model на місці).
    .DESCRIPTION
        P2-B: TableLayoutPanel (3 responsive-колонки: override+label |
        editor | status) замінює попередній fixed-Width=700/Point(x,y)
        рядок — ширина рядка тепер визначається батьківським контейнером,
        не магічним числом. $ToolTip — один спільний
        System.Windows.Forms.ToolTip, власник форми (§16 задачі P2-B),
        не окремий об'єкт на кожен рядок.
    #>
    param(
        [Parameter(Mandatory = $true)]$Setting,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][scriptblock]$OnChanged,
        [Parameter(Mandatory = $true)][scriptblock]$OnSelected,
        [Parameter(Mandatory = $true)]$ToolTip
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

    $rowPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $rowPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rowPanel.Margin = New-Object System.Windows.Forms.Padding(2, 1, 2, 1)
    $rowPanel.ColumnCount = 3
    $rowPanel.RowCount = 1
    [void]$rowPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 38)))
    [void]$rowPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 37)))
    [void]$rowPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 25)))
    [void]$rowPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $labelText = [string]$Setting.Metadata.Label
    if ([string]::IsNullOrWhiteSpace($labelText)) { $labelText = $currentPath }

    $overrideCheckBox = New-Object System.Windows.Forms.CheckBox
    $overrideCheckBox.Text = $labelText
    $overrideCheckBox.AutoEllipsis = $true
    $overrideCheckBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $overrideCheckBox.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $overrideCheckBox.Checked = [bool]$Setting.OverridePresent
    $overrideCheckBox.Enabled = -not [bool]$Setting.Metadata.ReadOnly
    $overrideCheckBox.AccessibleName = "Override: $labelText"
    $overrideCheckBox.AccessibleDescription = 'Позначено = явний локальний override; знято = використовується значення за замовчуванням.'
    $ToolTip.SetToolTip($overrideCheckBox, 'Позначено = явний локальний override (записується у BRAVO.local.config). Знято = використовується Default.')
    $rowPanel.Controls.Add($overrideCheckBox, 0, 0)

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
    $valueControl.Dock = [System.Windows.Forms.DockStyle]::Fill
    $valueControl.Margin = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
    $valueControl.Enabled = ([bool]$Setting.OverridePresent) -and (-not [bool]$Setting.Metadata.ReadOnly)
    $valueControl.AccessibleName = "Значення: $labelText"
    $rowPanel.Controls.Add($valueControl, 1, 0)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusLabel.AutoEllipsis = $true
    $statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $statusText = [string]$Setting.EffectiveSource
    $hasDisabledReason = -not [string]::IsNullOrWhiteSpace([string]$Setting.DisabledReason)
    if ($hasDisabledReason) {
        $statusText = "$statusText *"
        $ToolTip.SetToolTip($statusLabel, [string]$Setting.DisabledReason)
    } else {
        $ToolTip.SetToolTip($statusLabel, "Effective source: $statusText")
    }
    $statusLabel.Text = $statusText
    $statusLabel.AccessibleName = "Статус: $labelText"
    $statusLabel.AccessibleDescription = if ($hasDisabledReason) { [string]$Setting.DisabledReason } else { "Effective source: $statusText" }
    $rowPanel.Controls.Add($statusLabel, 2, 0)

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
    # P2-B.8: форматування винесено в чисту Get-BRAVOConfiguratorUISettingHelpText
    # (§14 задачі) — той самий текст обслуговує і Details-панель, і F1.
    $DetailsTextBox.Text = Get-BRAVOConfiguratorUISettingHelpText -Setting $setting[0]
}

function Update-BRAVOConfiguratorUICenterPanel {
    <#
    .DESCRIPTION
        P2-B: рядки монтуються в одну responsive TableLayoutPanel-хост
        (Dock=Top, AutoSize) замість ручного Point(4,$yPosition)-стекінгу
        — ширина рядків тепер розтягується на всю доступну область
        $CenterPanel (AutoScroll Panel), висота хоста росте автоматично з
        кількістю рядків. §20: якщо обраний Path усе ще присутній серед
        відфільтрованих settings — фокус повертається на його рядок;
        якщо фільтр/пошук/категорія видалили обраний рядок — фокус НЕ
        відновлюється (немає контролю, на який можна було б його
        поставити), а $State.SelectedSettingPath очищається.
    #>
    param(
        [Parameter(Mandatory = $true)]$CenterPanel,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][scriptblock]$OnChanged,
        [Parameter(Mandatory = $true)][scriptblock]$OnSelected,
        [Parameter(Mandatory = $true)]$ToolTip
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

    $rowsHost = New-Object System.Windows.Forms.TableLayoutPanel
    $rowsHost.Dock = [System.Windows.Forms.DockStyle]::Top
    $rowsHost.AutoSize = $true
    $rowsHost.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $rowsHost.GrowStyle = [System.Windows.Forms.TableLayoutPanelGrowStyle]::AddRows
    $rowsHost.ColumnCount = 1
    [void]$rowsHost.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $rowIndexToFocus = -1
    $rowIndex = 0
    foreach ($setting in $orderedSettings) {
        [void]$rowsHost.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30)))
        $row = New-BRAVOConfiguratorUISettingRow -Setting $setting -State $State -OnChanged $OnChanged -OnSelected $OnSelected -ToolTip $ToolTip
        $rowsHost.Controls.Add($row, 0, $rowIndex)
        if ((-not [string]::IsNullOrEmpty($State.SelectedSettingPath)) -and ([string]$setting.Path -eq $State.SelectedSettingPath)) {
            $rowIndexToFocus = $rowIndex
        }
        $rowIndex++
    }
    $CenterPanel.Controls.Add($rowsHost)

    if ($rowIndexToFocus -ge 0) {
        $focusRow = $rowsHost.GetControlFromPosition(0, $rowIndexToFocus)
        if ($null -ne $focusRow -and $focusRow.Controls.Count -gt 0) {
            [void]$focusRow.Controls[0].Focus()
        }
    } elseif (-not [string]::IsNullOrEmpty($State.SelectedSettingPath)) {
        $State.SelectedSettingPath = $null
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

    # P2-B.22: текстовий зміст — джерело істини; колір лише додатковий
    # (не єдиний) сигнал, тому текст не спрощується до самого лише
    # кольору чи символу.
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
    .DESCRIPTION
        P2-B.11: resizable, MinimumSize, стартовий розмір затиснутий до
        WorkingArea власника (той самий Get-BRAVOConfiguratorUIStartupSize,
        що головна форма — інші Preferred/Min для компактнішого діалогу).
        WordWrap=false + ScrollBars=Both для технічного diff-тексту (довгі
        шляхи/значення лишаються інспектованими через горизонтальний
        скрол, а не переносяться й не обрізаються). Жодної зміни семантики
        Preview: blocking error і далі вимикає Apply, Enter/Escape і далі
        мапляться на AcceptButton/CancelButton.
    #>
    param(
        [Parameter(Mandatory = $true)]$Preview,
        $Owner
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'BRAVO Configurator — попередній перегляд змін'
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $dialog.MinimumSize = New-Object System.Drawing.Size(480, 320)

    $ownerWorkingArea = if ($null -ne $Owner) {
        [System.Windows.Forms.Screen]::FromControl($Owner).WorkingArea
    } else {
        [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    }
    $previewSize = Get-BRAVOConfiguratorUIStartupSize -WorkingAreaWidth $ownerWorkingArea.Width -WorkingAreaHeight $ownerWorkingArea.Height `
        -PreferredWidth 900 -PreferredHeight 640 -MinWidth 480 -MinHeight 320
    $dialog.Width = $previewSize.Width
    $dialog.Height = $previewSize.Height

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Multiline = $true
    $textBox.ReadOnly = $true
    $textBox.WordWrap = $false
    $textBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $textBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $textBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $textBox.AccessibleName = 'Попередній перегляд змін'

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

    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $buttonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $buttonPanel.WrapContents = $true
    $buttonPanel.AutoSize = $true
    $buttonPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $buttonPanel.Padding = New-Object System.Windows.Forms.Padding(8)

    $confirmButton = New-Object System.Windows.Forms.Button
    $confirmButton.Text = 'Застосувати'
    $confirmButton.AutoSize = $true
    $confirmButton.Margin = New-Object System.Windows.Forms.Padding(6)
    $confirmButton.Enabled = -not [bool]$Preview.HasBlockingErrors
    $confirmButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $buttonPanel.Controls.Add($confirmButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Скасувати'
    $cancelButton.AutoSize = $true
    $cancelButton.Margin = New-Object System.Windows.Forms.Padding(6)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $buttonPanel.Controls.Add($cancelButton)

    $dialog.Controls.Add($textBox)
    $dialog.Controls.Add($buttonPanel)
    $dialog.AcceptButton = $confirmButton
    $dialog.CancelButton = $cancelButton

    $result = if ($null -ne $Owner) { $dialog.ShowDialog($Owner) } else { $dialog.ShowDialog() }
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
        # P2-B.20: canonical Path обраного налаштування — переживає
        # rebuild центральної панелі (search/filter/category refresh),
        # ЛИШЕ якщо той самий Path усе ще присутній у відфільтрованому
        # наборі (Update-BRAVOConfiguratorUICenterPanel).
        SelectedSettingPath        = $null
        # P2-B.13: 'Wide'/'Compact' — обчислюється Get-BRAVOConfiguratorUILayoutMode
        # з фактичної ширини mainSplit; ініціалізується нижче, до першого
        # виклику $applyLayoutMode.
        LayoutMode                 = $null
        SearchText                 = ''
        Filter                     = 'All'
        EffectiveStale             = $false
        # P2-A.4: exit-semantics — Applied/Cancelled/NoChanges НЕ мапляться
        # на різні OS exit-коди (жоден automation-caller сьогодні їх не
        # розрізняє; Configurator — інтерактивний desktop-інструмент, не
        # scheduled-завдання під BRAVO.ExitCodes). Натомість — structured
        # internal result, який Show-BRAVOConfiguratorMainForm повертає
        # викликачу; BRAVO_CONFIGURATOR.ps1 лишає exit 0 для всіх трьох.
        # Фінальний outcome оцінюється проти ПОТОЧНОГО $state.ProductionBaseline
        # (Get-BRAVOConfiguratorSessionOutcome, Model.psm1) — не проти
        # первинного baseline сесії; окремого InitialBaselineOverrides не
        # зберігаємо (P2-A.4 correction).
        AnyApplySucceeded          = $false
    }
    try {
        $initialSnapshot = Get-BRAVOConfiguratorUIEffectiveConfigSnapshot -State $state
        $state.RequirementBefore = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $initialSnapshot
    } catch {
        # Некритично для старту форми — credential-вимоги просто
        # лишаться невідомі до першого явного "Перевірити"/Apply.
        $state.RequirementBefore = $null
    }

    # ===== Форма =====
    # P2-B.2/3: startup-розмір НЕ хардкодиться сліпо до 1150x780 —
    # затискається до Screen.WorkingArea (Get-BRAVOConfiguratorUIStartupSize),
    # ніколи не відкриває вікно більше за реальний робочий простір екрана.
    # AutoScaleMode=Dpi — framework-рівень DPI-масштабування, сумісний з
    # Windows PowerShell 5.1/.NET Framework (без Application.SetHighDpiMode
    # чи іншого API, недоступного в цьому рантаймі — див. docs/design).
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'BRAVO Configurator'
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.KeyPreview = $true
    $form.MinimumSize = New-Object System.Drawing.Size(1000, 650)
    $formWorkingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $startupSize = Get-BRAVOConfiguratorUIStartupSize -WorkingAreaWidth $formWorkingArea.Width -WorkingAreaHeight $formWorkingArea.Height
    $form.Width = $startupSize.Width
    $form.Height = $startupSize.Height
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.AccessibleName = 'BRAVO Configurator'

    # P2-B.9: один спільний ToolTip, власник форми, замість окремого
    # об'єкта на кожен рядок налаштування.
    $sharedToolTip = New-Object System.Windows.Forms.ToolTip
    $sharedToolTip.AutoPopDelay = 8000
    $sharedToolTip.InitialDelay = 400
    $sharedToolTip.ReshowDelay = 200

    # --- Верхня панель: рядок 1 (пошук/фільтр/пресет), рядок 2 (креденшели) ---
    $topPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $topPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $topPanel.AutoSize = $true
    $topPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $topPanel.ColumnCount = 1
    $topPanel.RowCount = 2
    [void]$topPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$topPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$topPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $searchFilterRow = New-Object System.Windows.Forms.FlowLayoutPanel
    $searchFilterRow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $searchFilterRow.AutoSize = $true
    $searchFilterRow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $searchFilterRow.WrapContents = $true
    $searchFilterRow.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $searchFilterRow.Padding = New-Object System.Windows.Forms.Padding(6, 6, 6, 2)

    $searchLabel = New-Object System.Windows.Forms.Label
    $searchLabel.Text = 'Пошук:'
    $searchLabel.AutoSize = $true
    $searchLabel.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 3)
    $searchFilterRow.Controls.Add($searchLabel)

    $searchTextBox = New-Object System.Windows.Forms.TextBox
    $searchTextBox.Width = 220
    $searchTextBox.Margin = New-Object System.Windows.Forms.Padding(3, 5, 12, 3)
    $searchTextBox.AccessibleName = 'Пошук'
    $searchTextBox.AccessibleDescription = 'Пошук за назвою, шляхом, описом чи групою налаштування.'
    $sharedToolTip.SetToolTip($searchTextBox, 'Пошук за Path/Label/Description/Group (Ctrl+F — фокус сюди)')
    $searchFilterRow.Controls.Add($searchTextBox)

    $filterLabel = New-Object System.Windows.Forms.Label
    $filterLabel.Text = 'Фільтр:'
    $filterLabel.AutoSize = $true
    $filterLabel.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 3)
    $searchFilterRow.Controls.Add($filterLabel)

    # P2-B.21: ComboBox-пункти — pscustomobject{Id;Label} з
    # Get-BRAVOConfiguratorUIFilterOptions (DisplayMember='Label',
    # ValueMember='Id') — оператор бачить український підпис, backend
    # filter (Get-BRAVOConfiguratorUIFilteredSettings) і далі отримує
    # канонічний Id, не залежить від відображуваного тексту.
    $filterComboBox = New-Object System.Windows.Forms.ComboBox
    $filterComboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $filterComboBox.Width = 140
    $filterComboBox.Margin = New-Object System.Windows.Forms.Padding(3, 5, 12, 3)
    $filterComboBox.DisplayMember = 'Label'
    $filterComboBox.ValueMember = 'Id'
    $filterOptions = Get-BRAVOConfiguratorUIFilterOptions
    foreach ($filterOption in $filterOptions) { [void]$filterComboBox.Items.Add($filterOption) }
    $filterComboBox.SelectedIndex = 0
    $filterComboBox.AccessibleName = 'Фільтр'
    $sharedToolTip.SetToolTip($filterComboBox, 'Усі / Змінені / Активні / Проблеми / Розширені.')
    $searchFilterRow.Controls.Add($filterComboBox)

    $presetLabel = New-Object System.Windows.Forms.Label
    $presetLabel.Text = 'Пресет:'
    $presetLabel.AutoSize = $true
    $presetLabel.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 3)
    $searchFilterRow.Controls.Add($presetLabel)

    $presetComboBox = New-Object System.Windows.Forms.ComboBox
    $presetComboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $presetComboBox.Width = 170
    $presetComboBox.Margin = New-Object System.Windows.Forms.Padding(3, 5, 12, 3)
    $presetCatalog = Get-BRAVOConfiguratorPresetCatalog
    foreach ($preset in $presetCatalog) { [void]$presetComboBox.Items.Add([string]$preset.Label) }
    if ($presetComboBox.Items.Count -gt 0) { $presetComboBox.SelectedIndex = 0 }
    $presetComboBox.AccessibleName = 'Пресет'
    $sharedToolTip.SetToolTip($presetComboBox, 'Готовий набір значень для типового сценарію розгортання.')
    $searchFilterRow.Controls.Add($presetComboBox)

    $presetApplyButton = New-Object System.Windows.Forms.Button
    $presetApplyButton.Text = 'Застосувати пресет'
    $presetApplyButton.AutoSize = $true
    $presetApplyButton.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 3)
    $presetApplyButton.AccessibleName = 'Застосувати пресет'
    $sharedToolTip.SetToolTip($presetApplyButton, 'Застосувати обраний пресет до поточної (ще не збереженої) моделі.')
    $searchFilterRow.Controls.Add($presetApplyButton)

    $topPanel.Controls.Add($searchFilterRow, 0, 0)

    $credentialRow = New-Object System.Windows.Forms.FlowLayoutPanel
    $credentialRow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $credentialRow.AutoSize = $true
    $credentialRow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $credentialRow.WrapContents = $true
    $credentialRow.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $credentialRow.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 6)

    $sftpCredLabel = New-Object System.Windows.Forms.Label
    $sftpCredLabel.Text = 'SFTP: —'
    $sftpCredLabel.AutoSize = $true
    $sftpCredLabel.Margin = New-Object System.Windows.Forms.Padding(3, 8, 12, 3)
    $credentialRow.Controls.Add($sftpCredLabel)

    $smbCredLabel = New-Object System.Windows.Forms.Label
    $smbCredLabel.Text = 'SMB: —'
    $smbCredLabel.AutoSize = $true
    $smbCredLabel.Margin = New-Object System.Windows.Forms.Padding(3, 8, 12, 3)
    $credentialRow.Controls.Add($smbCredLabel)

    $credCheckButton = New-Object System.Windows.Forms.Button
    $credCheckButton.Text = 'Перевірити креденшели'
    $credCheckButton.AutoSize = $true
    $credCheckButton.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 3)
    $credCheckButton.AccessibleName = 'Перевірити креденшели'
    $sharedToolTip.SetToolTip($credCheckButton, 'Перевірити стан SFTP/SMB креденшелів для поточної Effective-конфігурації (секрети не показуються).')
    $credentialRow.Controls.Add($credCheckButton)

    $credSetupSftpButton = New-Object System.Windows.Forms.Button
    $credSetupSftpButton.Text = 'Налаштувати SFTP'
    $credSetupSftpButton.AutoSize = $true
    $credSetupSftpButton.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 3)
    $credSetupSftpButton.AccessibleName = 'Налаштувати SFTP креденшели'
    $credentialRow.Controls.Add($credSetupSftpButton)

    $credSetupSmbButton = New-Object System.Windows.Forms.Button
    $credSetupSmbButton.Text = 'Налаштувати SMB'
    $credSetupSmbButton.AutoSize = $true
    $credSetupSmbButton.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 3)
    $credSetupSmbButton.AccessibleName = 'Налаштувати SMB креденшели'
    $credentialRow.Controls.Add($credSetupSmbButton)

    $topPanel.Controls.Add($credentialRow, 0, 1)
    $form.Controls.Add($topPanel)

    # --- Нижня панель: status (ліворуч) | дії (праворуч, wrap) ---
    $bottomPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottomPanel.AutoSize = $true
    $bottomPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $bottomPanel.ColumnCount = 2
    $bottomPanel.RowCount = 1
    [void]$bottomPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 45)))
    [void]$bottomPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 55)))
    [void]$bottomPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $statusPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $statusPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusPanel.AutoSize = $true
    $statusPanel.ColumnCount = 1
    $statusPanel.RowCount = 2
    $statusPanel.Padding = New-Object System.Windows.Forms.Padding(8, 8, 4, 8)

    $dirtyLabel = New-Object System.Windows.Forms.Label
    $dirtyLabel.AutoSize = $true
    $dirtyLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusPanel.Controls.Add($dirtyLabel, 0, 0)

    $validationLabel = New-Object System.Windows.Forms.Label
    $validationLabel.AutoSize = $true
    $validationLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusPanel.Controls.Add($validationLabel, 0, 1)

    $bottomPanel.Controls.Add($statusPanel, 0, 0)

    # P2-A.6: скидання всіх overrides ПОТОЧНОЇ обраної секції до Default —
    # bulk-операція, для якої раніше не було UI-шляху (одиночний setting
    # уже скидається зняттям override-checkbox у рядку — Clear-BRAVOConfiguratorOverride,
    # той самий контракт §1.3 "Використовувати default"). Активна лише
    # коли в дереві обрано КОНКРЕТНУ секцію (не групу цілком і не "Усі категорії").
    #
    # FlowDirection=RightToLeft: перший доданий контроль опиняється
    # крайнім правим — додаємо у зворотному до візуального порядку, щоб
    # зберегти читання зліва направо: Перезавантажити, Перерахувати,
    # Скинути секцію, Застосувати, Скасувати (крайня права — як і в
    # попередньому fixed-layout).
    $actionsRow = New-Object System.Windows.Forms.FlowLayoutPanel
    $actionsRow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $actionsRow.AutoSize = $true
    $actionsRow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $actionsRow.WrapContents = $true
    $actionsRow.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $actionsRow.Padding = New-Object System.Windows.Forms.Padding(4, 8, 8, 8)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Скасувати'
    $cancelButton.AutoSize = $true
    $cancelButton.Margin = New-Object System.Windows.Forms.Padding(4)
    $cancelButton.AccessibleName = 'Скасувати'
    $actionsRow.Controls.Add($cancelButton)

    $applyButton = New-Object System.Windows.Forms.Button
    $applyButton.Text = 'Застосувати...'
    $applyButton.AutoSize = $true
    $applyButton.Margin = New-Object System.Windows.Forms.Padding(4)
    $applyButton.AccessibleName = 'Застосувати'
    $sharedToolTip.SetToolTip($applyButton, 'Перерахувати Effective, показати попередній перегляд і застосувати зміни (з підтвердженням).')
    $actionsRow.Controls.Add($applyButton)

    $resetSectionButton = New-Object System.Windows.Forms.Button
    $resetSectionButton.Text = 'Скинути секцію'
    $resetSectionButton.AutoSize = $true
    $resetSectionButton.Margin = New-Object System.Windows.Forms.Padding(4)
    $resetSectionButton.Enabled = $false
    $resetSectionButton.AccessibleName = 'Скинути секцію до значень за замовчуванням'
    $actionsRow.Controls.Add($resetSectionButton)

    $recalculateButton = New-Object System.Windows.Forms.Button
    $recalculateButton.Text = 'Перерахувати'
    $recalculateButton.AutoSize = $true
    $recalculateButton.Margin = New-Object System.Windows.Forms.Padding(4)
    $recalculateButton.AccessibleName = 'Перерахувати Effective'
    $actionsRow.Controls.Add($recalculateButton)

    $reloadButton = New-Object System.Windows.Forms.Button
    $reloadButton.Text = 'Перезавантажити'
    $reloadButton.AutoSize = $true
    $reloadButton.Margin = New-Object System.Windows.Forms.Padding(4)
    $reloadButton.AccessibleName = 'Перезавантажити конфігурацію з диска'
    $sharedToolTip.SetToolTip($reloadButton, 'Перечитати BRAVO.local.config з диска (F5). Незбережені зміни буде відкинуто після підтвердження.')
    $actionsRow.Controls.Add($reloadButton)

    $bottomPanel.Controls.Add($actionsRow, 1, 0)
    $form.Controls.Add($bottomPanel)

    # --- Середня частина: TreeView | Settings | Details (responsive: §13) ---
    # Panel1MinSize/Panel2MinSize НАВМИСНО не встановлюються одразу після
    # New-Object: SplitContainer у цей момент ще не Dock-размещений і має
    # дефолтний малий Size (не той, що дасть форма) — призначення
    # MinSize/SplitterDistance проти цього тимчасового розміру кидає
    # "SplitterDistance must be between Panel1MinSize and Width -
    # Panel2MinSize" (реальний launch-smoke crash, зловлений
    # ci\acceptance\Test-BRAVOConfiguratorLaunch.ps1). MinSize
    # виставляється нижче, ПІСЛЯ $form.Controls.Add($mainSplit) — коли
    # ClientSize вже відповідає реальному стартовому розміру форми.
    $mainSplit = New-Object System.Windows.Forms.SplitContainer
    $mainSplit.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainSplit.AccessibleName = 'Категорії та налаштування'

    $categoryTree = New-Object System.Windows.Forms.TreeView
    $categoryTree.Dock = [System.Windows.Forms.DockStyle]::Fill
    $categoryTree.AccessibleName = 'Дерево категорій'
    $categoryTree.AccessibleDescription = 'Групи та секції схеми налаштувань.'
    $mainSplit.Panel1.Controls.Add($categoryTree)

    $rightSplit = New-Object System.Windows.Forms.SplitContainer
    $rightSplit.Dock = [System.Windows.Forms.DockStyle]::Fill

    $centerScrollPanel = New-Object System.Windows.Forms.Panel
    $centerScrollPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $centerScrollPanel.AutoScroll = $true
    $centerScrollPanel.AccessibleName = 'Область налаштувань'
    $rightSplit.Panel1.Controls.Add($centerScrollPanel)

    $detailsTextBox = New-Object System.Windows.Forms.TextBox
    $detailsTextBox.Multiline = $true
    $detailsTextBox.ReadOnly = $true
    $detailsTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $detailsTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $detailsTextBox.AccessibleName = 'Деталі налаштування'
    $rightSplit.Panel2.Controls.Add($detailsTextBox)

    $mainSplit.Panel2.Controls.Add($rightSplit)
    $form.Controls.Add($mainSplit)
    $mainSplit.BringToFront()
    $topPanel.SendToBack()

    # ===== §13: початкове розташування splitter-ів і режим (Wide/Compact) =====
    # У цей момент $form уже має фінальний startup-розмір (вище), а
    # $mainSplit/$rightSplit — Dock=Fill дочірні елементи, щойно додані в
    # ієрархію контролів, тому ClientSize вже коректний (WinForms виконує
    # docking-layout синхронно при додаванні Dock-контролю до батька) —
    # саме тому Panel1MinSize/Panel2MinSize встановлюються ТУТ, а не одразу
    # після New-Object (див. коментар вище).
    $mainSplit.Panel1MinSize = 150
    $mainSplit.Panel2MinSize = 400
    $rightSplit.Panel1MinSize = 350
    $rightSplit.Panel2MinSize = 200
    Set-BRAVOConfiguratorUISplitterDistanceSafe -SplitContainer $mainSplit -DesiredDistance 220
    $state.LayoutMode = Get-BRAVOConfiguratorUILayoutMode -ClientWidth $mainSplit.ClientSize.Width
    $rightSplit.Orientation = if ($state.LayoutMode -eq 'Compact') {
        [System.Windows.Forms.Orientation]::Horizontal
    } else {
        [System.Windows.Forms.Orientation]::Vertical
    }
    $rightSplitAvailable = if ($rightSplit.Orientation -eq [System.Windows.Forms.Orientation]::Horizontal) { $rightSplit.ClientSize.Height } else { $rightSplit.ClientSize.Width }
    Set-BRAVOConfiguratorUISplitterDistanceSafe -SplitContainer $rightSplit -DesiredDistance ([Math]::Floor($rightSplitAvailable * 0.65))

    # Resize-driven reclamp (§12/§13): перемикає орієнтацію rightSplit
    # лише на факт зміни Wide<->Compact (не на кожен піксель), інакше
    # затискає ПОТОЧНУ SplitterDistance у новий легальний діапазон —
    # зберігає операторський вибір позиції splitter-а при звичайному
    # resize, замість скидання до фіксованого значення щоразу.
    $applyLayoutMode = {
        $newMode = Get-BRAVOConfiguratorUILayoutMode -ClientWidth $mainSplit.ClientSize.Width
        $orientationChanged = ($newMode -ne $state.LayoutMode)
        $state.LayoutMode = $newMode
        if ($orientationChanged) {
            $rightSplit.Orientation = if ($newMode -eq 'Compact') {
                [System.Windows.Forms.Orientation]::Horizontal
            } else {
                [System.Windows.Forms.Orientation]::Vertical
            }
        }

        Set-BRAVOConfiguratorUISplitterDistanceSafe -SplitContainer $mainSplit -DesiredDistance $mainSplit.SplitterDistance

        $rightAvailableNow = if ($rightSplit.Orientation -eq [System.Windows.Forms.Orientation]::Horizontal) { $rightSplit.ClientSize.Height } else { $rightSplit.ClientSize.Width }
        $rightDesired = if ($orientationChanged) { [Math]::Floor($rightAvailableNow * 0.65) } else { $rightSplit.SplitterDistance }
        Set-BRAVOConfiguratorUISplitterDistanceSafe -SplitContainer $rightSplit -DesiredDistance $rightDesired
    }
    $mainSplit.Add_SizeChanged({ & $applyLayoutMode })
    $rightSplit.Add_SizeChanged({ & $applyLayoutMode })

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
        # P2-B.20: canonical Path обраного налаштування — переживає
        # наступний rebuild центральної панелі, якщо він усе ще
        # присутній у відфільтрованому наборі.
        $state.SelectedSettingPath = $path
        Update-BRAVOConfiguratorUIDetailsPanel -DetailsTextBox $detailsTextBox -State $state -Path $path
    }

    $refreshCenterPanel = {
        Update-BRAVOConfiguratorUICenterPanel -CenterPanel $centerScrollPanel -State $state -OnChanged $onChanged -OnSelected $onSelected -ToolTip $sharedToolTip
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
        $state.Filter = [string]$filterComboBox.SelectedItem.Id
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

        $confirmed = Show-BRAVOConfiguratorUIPreviewDialog -Preview $preview -Owner $form
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

    # P2-B.10/§18/§19: клавіатурні скорочення. Ctrl+F -> фокус пошуку;
    # F1 -> контекстна довідка (фокус Details, якщо є обране налаштування,
    # інакше загальне повідомлення); F5/Escape ПОВНІСТЮ переадресовуються
    # на PerformClick() існуючих кнопок — жоден шлях не обходить
    # dirty-discard confirmation чи Preview/Apply-контракт, бо виконується
    # ТОЙ САМИЙ Add_Click-обробник, не паралельна копія логіки. Головна
    # форма НІКОЛИ не отримує AcceptButton=Apply (Enter у полі редагування
    # не повинен неочікувано писати конфігурацію) — це свідомо не
    # встановлюється тут.
    $form.Add_KeyDown({
        param($keySender, $keyArgs)
        if ($keyArgs.Control -and $keyArgs.KeyCode -eq [System.Windows.Forms.Keys]::F) {
            [void]$searchTextBox.Focus()
            $searchTextBox.SelectAll()
            $keyArgs.Handled = $true
        } elseif ($keyArgs.KeyCode -eq [System.Windows.Forms.Keys]::F1) {
            if (-not [string]::IsNullOrEmpty($state.SelectedSettingPath)) {
                [void]$detailsTextBox.Focus()
            } else {
                Show-BRAVOConfiguratorUIMessage -Text (Get-BRAVOConfiguratorUIGeneralHelpText)
            }
            $keyArgs.Handled = $true
        } elseif ($keyArgs.KeyCode -eq [System.Windows.Forms.Keys]::F5) {
            $reloadButton.PerformClick()
            $keyArgs.Handled = $true
        } elseif ($keyArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $cancelButton.PerformClick()
            $keyArgs.Handled = $true
        }
    })

    $form.Add_FormClosing({
        param($formSender, $formArgs)
        if (-not (Confirm-BRAVOConfiguratorUIDiscardChanges -State $state)) {
            $formArgs.Cancel = $true
        }
    })

    [void]$form.ShowDialog()

    # P2-A.4 (correction): outcome оцінюється проти ПОТОЧНОГО
    # $state.ProductionBaseline (Get-BRAVOConfiguratorSessionOutcome,
    # Model.psm1) — не проти первинного baseline сесії. Незбережений diff
    # на момент закриття (Cancelled) переважає над фактом, що Apply
    # колись у сесії відбувся успішно (Applied) — інакше подальші
    # незбережені зміни після успішного Apply, які оператор відкинув,
    # хибно репортувались би як Applied. Reload оновлює ProductionBaseline,
    # тож "Launch -> зовнішня зміна -> Reload -> Close без edits" коректно
    # дає NoChanges, а не хибний Cancelled проти застарілого первинного
    # baseline.
    return Get-BRAVOConfiguratorSessionOutcome -Model $state.Model `
        -ProductionBaseline $state.ProductionBaseline.Overrides `
        -AnyApplySucceeded $state.AnyApplySucceeded
}

Export-ModuleMember -Function @(
    'Show-BRAVOConfiguratorMainForm',
    'Get-BRAVOConfiguratorUIReachablePaths',
    'Get-BRAVOConfiguratorUIFilteredSettings',
    'Get-BRAVOConfiguratorUISearchMatches',
    'Get-BRAVOConfiguratorUICategoryTree',
    'Get-BRAVOConfiguratorUIBooleanTriState',
    'ConvertTo-BRAVOConfiguratorUIDisplayText',
    'ConvertTo-BRAVOConfiguratorUITypedValue',
    'Get-BRAVOConfiguratorUILayoutMode',
    'Get-BRAVOConfiguratorUIFilterOptions',
    'Get-BRAVOConfiguratorUISettingHelpText',
    'Get-BRAVOConfiguratorUIGeneralHelpText',
    'Get-BRAVOConfiguratorUIStartupSize',
    'Get-BRAVOConfiguratorUIClampedSplitterDistance'
)
