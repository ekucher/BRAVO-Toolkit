# Домен-фрагмент self-test: BRAVO.Configurator.UI — ЛИШЕ чисті,
# headless-тестовані функції (Get-BRAVOConfiguratorUIReachablePaths/
# -UIFilteredSettings/-UISearchMatches/-UICategoryTree/-UIBooleanTriState/
# ConvertTo-BRAVOConfiguratorUI*). Жоден System.Windows.Forms-об'єкт тут
# НЕ конструюється — Show-BRAVOConfiguratorMainForm (ShowDialog, реальна
# desktop-сесія) навмисно поза межами цього фрагмента: інтерактивний
# GUI-smoke-тест був би флакі в headless CI-раннері.
#
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition, $script:failures.
#
# Ізоляція: жодна перевірка не читає й не пише реальний
# $root\BRAVO.local.config — фікстурні Model/SchemaCatalog масиви
# будуються вручну в пам'яті; єдиний реальний backend-виклик —
# Get-BRAVOConfiguratorSchemaCatalog (читає лише .psd1-каталог дескрипторів,
# не production-конфіг) для перевірки 100%-покриття UI_REACHABLE.

$configuratorUIModuleRoot = Join-Path $root 'modules\BRAVO.Configurator'
Import-Module (Join-Path $configuratorUIModuleRoot 'BRAVO.Configurator.Schema.psm1') -Force
Import-Module (Join-Path $configuratorUIModuleRoot 'BRAVO.Configurator.UI.psm1') -Force

# ===== 1: UI_REACHABLE == SCHEMA_DESCRIPTORS (кількість і множина Path) =====
$configuratorUISchemaCatalog = Get-BRAVOConfiguratorSchemaCatalog
$configuratorUIReachablePaths = @(Get-BRAVOConfiguratorUIReachablePaths -SchemaCatalog $configuratorUISchemaCatalog)
$configuratorUISchemaPaths = @($configuratorUISchemaCatalog | ForEach-Object { [string]$_.Path })

$configuratorUIMissingFromReachable = @($configuratorUISchemaPaths | Where-Object { $configuratorUIReachablePaths -notcontains $_ })
$configuratorUIExtraInReachable = @($configuratorUIReachablePaths | Where-Object { $configuratorUISchemaPaths -notcontains $_ })

Test-BRAVOCondition (
    $configuratorUIReachablePaths.Count -eq $configuratorUISchemaCatalog.Count -and
    $configuratorUIMissingFromReachable.Count -eq 0 -and
    $configuratorUIExtraInReachable.Count -eq 0
) `
    'ConfiguratorUI: Get-BRAVOConfiguratorUIReachablePaths покриває 100% schema-каталогу (кількість і множина Path)' `
    ("UI_REACHABLE=$($configuratorUIReachablePaths.Count) SCHEMA_DESCRIPTORS=$($configuratorUISchemaCatalog.Count) " +
     "Missing=$($configuratorUIMissingFromReachable -join ',') Extra=$($configuratorUIExtraInReachable -join ',')")

# ===== Фікстурна Model для решти перевірок (не залежить від реального
# Effective/Credential Manager — суто in-memory pscustomobject-масив у
# формі, яку повертає Get-BRAVOConfiguratorModel/Update-BRAVOConfiguratorEffective). =====
function New-ConfiguratorUIFixtureSetting {
    param(
        [string]$Path,
        [string]$Group = 'General',
        [string]$Section = 'Institution',
        [string]$Label = $Path,
        [string]$Description = 'fixture',
        [string]$Type = 'String',
        [bool]$Advanced = $false,
        [bool]$ReadOnly = $false,
        $DefaultValue = $null,
        [bool]$OverridePresent = $false,
        $OverrideValue = $null,
        $EffectiveValue = $null,
        [string]$EffectiveSource = 'Default',
        [string]$DisabledReason = $null,
        [bool]$Dirty = $false
    )
    return [pscustomobject]@{
        Path            = $Path
        Metadata        = [pscustomobject]@{
            Path = $Path; Group = $Group; Section = $Section; Label = $Label; Description = $Description
            Type = $Type; Advanced = $Advanced; ReadOnly = $ReadOnly; Secret = $false; Order = 10
        }
        DefaultValue    = $DefaultValue
        OverridePresent = $OverridePresent
        OverrideValue   = $OverrideValue
        EffectiveValue  = $EffectiveValue
        EffectiveSource = $EffectiveSource
        DisabledReason  = $DisabledReason
        ValidationState = $null
        DependencyState = $null
        Dirty           = $Dirty
    }
}

$configuratorUIFixtureModel = @(
    New-ConfiguratorUIFixtureSetting -Path 'fixture.General.Advanced' -Group 'General' -Section 'A' -Label 'Advanced Setting' -Advanced $true -Type 'Boolean' -DefaultValue $false -EffectiveValue $false
    New-ConfiguratorUIFixtureSetting -Path 'fixture.General.NotAdvanced' -Group 'General' -Section 'A' -Label 'Regular Setting' -Advanced $false -Type 'Boolean' -DefaultValue $false -EffectiveValue $false
    New-ConfiguratorUIFixtureSetting -Path 'fixture.Storage.WithProblem' -Group 'Storage' -Section 'B' -Label 'Problem Setting' -Type 'String' -DefaultValue '' -EffectiveValue '' -DisabledReason 'master-switch вимкнув це поле'
    New-ConfiguratorUIFixtureSetting -Path 'fixture.Storage.NoProblem' -Group 'Storage' -Section 'B' -Label 'Clean Setting' -Type 'String' -DefaultValue 'x' -EffectiveValue 'x'
    New-ConfiguratorUIFixtureSetting -Path 'fixture.Storage.Dirty' -Group 'Storage' -Section 'C' -Label 'Dirty Setting' -Type 'Integer' -DefaultValue 1 -EffectiveValue 1 -Dirty $true
    New-ConfiguratorUIFixtureSetting -Path 'fixture.Storage.Overridden' -Group 'Storage' -Section 'C' -Label 'BackupRoot Override' -Type 'Path' -DefaultValue 'C:\Default' -OverridePresent $true -OverrideValue 'D:\Override' -EffectiveValue 'D:\Override' -EffectiveSource 'Override'
)

# ===== 2: Filter 'Advanced' повертає рівно ті settings, де Metadata.Advanced=$true =====
$configuratorUIAdvancedFiltered = @(Get-BRAVOConfiguratorUIFilteredSettings -Model $configuratorUIFixtureModel -Filter 'Advanced')
Test-BRAVOCondition (
    $configuratorUIAdvancedFiltered.Count -eq 1 -and $configuratorUIAdvancedFiltered[0].Path -eq 'fixture.General.Advanced'
) `
    "ConfiguratorUI Filter 'Advanced': повертає рівно settings з Metadata.Advanced=true" `
    "Count=$($configuratorUIAdvancedFiltered.Count) Paths=$(($configuratorUIAdvancedFiltered | ForEach-Object { $_.Path }) -join ',')"

# ===== 3: Filter 'Problems' включає DisabledReason-непорожній і виключає порожній =====
$configuratorUIProblemsFiltered = @(Get-BRAVOConfiguratorUIFilteredSettings -Model $configuratorUIFixtureModel -Filter 'Problems')
$configuratorUIProblemsPaths = @($configuratorUIProblemsFiltered | ForEach-Object { $_.Path })
Test-BRAVOCondition (
    ($configuratorUIProblemsPaths -contains 'fixture.Storage.WithProblem') -and
    ($configuratorUIProblemsPaths -notcontains 'fixture.Storage.NoProblem')
) `
    "ConfiguratorUI Filter 'Problems': включає непорожній DisabledReason, виключає порожній" `
    "Paths=$($configuratorUIProblemsPaths -join ',')"

# ===== 4: Filter 'Changed' — Dirty OR OverridePresent =====
$configuratorUIChangedFiltered = @(Get-BRAVOConfiguratorUIFilteredSettings -Model $configuratorUIFixtureModel -Filter 'Changed')
$configuratorUIChangedPaths = @($configuratorUIChangedFiltered | ForEach-Object { $_.Path })
Test-BRAVOCondition (
    ($configuratorUIChangedPaths -contains 'fixture.Storage.Dirty') -and
    ($configuratorUIChangedPaths -contains 'fixture.Storage.Overridden') -and
    ($configuratorUIChangedPaths -notcontains 'fixture.Storage.NoProblem')
) `
    "ConfiguratorUI Filter 'Changed': Dirty=true АБО OverridePresent=true, не інші" `
    "Paths=$($configuratorUIChangedPaths -join ',')"

# ===== 5: Search за точним canonical Path повертає рівно одне налаштування =====
$configuratorUISearchByPath = @(Get-BRAVOConfiguratorUISearchMatches -Model $configuratorUIFixtureModel -SearchText 'fixture.Storage.Overridden')
Test-BRAVOCondition (
    $configuratorUISearchByPath.Count -eq 1 -and $configuratorUISearchByPath[0].Path -eq 'fixture.Storage.Overridden'
) `
    'ConfiguratorUI Search: точний canonical Path повертає рівно 1 налаштування' `
    "Count=$($configuratorUISearchByPath.Count)"

# ===== 6: Search за підрядком Label (case-insensitive) =====
$configuratorUISearchByLabel = @(Get-BRAVOConfiguratorUISearchMatches -Model $configuratorUIFixtureModel -SearchText 'backuproot override')
$configuratorUISearchByLabelPaths = @($configuratorUISearchByLabel | ForEach-Object { $_.Path })
Test-BRAVOCondition (
    $configuratorUISearchByLabelPaths -contains 'fixture.Storage.Overridden'
) `
    'ConfiguratorUI Search: case-insensitive підрядок Label знаходить очікуване налаштування' `
    "Paths=$($configuratorUISearchByLabelPaths -join ',')"

# ===== 6b: порожній SearchText повертає Model без змін =====
$configuratorUISearchEmpty = @(Get-BRAVOConfiguratorUISearchMatches -Model $configuratorUIFixtureModel -SearchText '   ')
Test-BRAVOCondition ($configuratorUISearchEmpty.Count -eq $configuratorUIFixtureModel.Count) `
    'ConfiguratorUI Search: порожній/whitespace SearchText повертає Model без змін' `
    "Count=$($configuratorUISearchEmpty.Count)/$($configuratorUIFixtureModel.Count)"

# ===== 7: Get-BRAVOConfiguratorUICategoryTree групує коректно (2 групи фікстура) =====
$configuratorUICategoryFixtureSchema = @(
    @{ Path = 'catA.one'; Group = 'GroupA'; Section = 'Sec1'; Type = 'String' }
    @{ Path = 'catA.two'; Group = 'GroupA'; Section = 'Sec1'; Type = 'String' }
    @{ Path = 'catA.three'; Group = 'GroupA'; Section = 'Sec2'; Type = 'String' }
    @{ Path = 'catB.one'; Group = 'GroupB'; Section = 'Sec3'; Type = 'String' }
)
$configuratorUICategoryTree = @(Get-BRAVOConfiguratorUICategoryTree -SchemaCatalog $configuratorUICategoryFixtureSchema)
$configuratorUIGroupA = @($configuratorUICategoryTree | Where-Object { $_.Group -eq 'GroupA' })
$configuratorUIGroupB = @($configuratorUICategoryTree | Where-Object { $_.Group -eq 'GroupB' })
Test-BRAVOCondition (
    $configuratorUICategoryTree.Count -eq 2 -and
    $configuratorUIGroupA.Count -eq 1 -and $configuratorUIGroupA[0].DescriptorCount -eq 3 -and $configuratorUIGroupA[0].Sections.Count -eq 2 -and
    $configuratorUIGroupB.Count -eq 1 -and $configuratorUIGroupB[0].DescriptorCount -eq 1 -and $configuratorUIGroupB[0].Sections.Count -eq 1
) `
    'ConfiguratorUI CategoryTree: 2 групи фікстури групуються коректно (Group -> Section[] з правильними DescriptorCount)' `
    ("Groups=$($configuratorUICategoryTree.Count) GroupA.DescriptorCount=$($configuratorUIGroupA[0].DescriptorCount) " +
     "GroupA.Sections=$($configuratorUIGroupA[0].Sections.Count) GroupB.DescriptorCount=$($configuratorUIGroupB[0].DescriptorCount)")

$configuratorUISec1 = @($configuratorUIGroupA[0].Sections | Where-Object { $_.Section -eq 'Sec1' })
Test-BRAVOCondition ($configuratorUISec1.Count -eq 1 -and $configuratorUISec1[0].DescriptorCount -eq 2) `
    'ConfiguratorUI CategoryTree: Section-рівень DescriptorCount коректний (Sec1 = 2 дескриптори)' `
    "Sec1.DescriptorCount=$($configuratorUISec1[0].DescriptorCount)"

# ===== 8: Boolean tri-state — 3 генуїнно різні стани =====
$configuratorUITriStateDefault = Get-BRAVOConfiguratorUIBooleanTriState -OverridePresent $false -OverrideValue $null
$configuratorUITriStateTrue = Get-BRAVOConfiguratorUIBooleanTriState -OverridePresent $true -OverrideValue $true
$configuratorUITriStateFalse = Get-BRAVOConfiguratorUIBooleanTriState -OverridePresent $true -OverrideValue $false
Test-BRAVOCondition (
    $configuratorUITriStateDefault -eq 'Default' -and $configuratorUITriStateTrue -eq 'True' -and $configuratorUITriStateFalse -eq 'False' -and
    ($configuratorUITriStateDefault -ne $configuratorUITriStateTrue) -and
    ($configuratorUITriStateTrue -ne $configuratorUITriStateFalse) -and
    ($configuratorUITriStateDefault -ne $configuratorUITriStateFalse)
) `
    'ConfiguratorUI Boolean tri-state: Default/True/False — 3 генуїнно різні стани (не порожній override-false звужено до 2-state)' `
    "Default=$configuratorUITriStateDefault True=$configuratorUITriStateTrue False=$configuratorUITriStateFalse"

# ===== 9: ConvertTo-BRAVOConfiguratorUITypedValue / ConvertTo-BRAVOConfiguratorUIDisplayText round-trip для масивів =====
$configuratorUITypedArray = ConvertTo-BRAVOConfiguratorUITypedValue -Type 'StringArray' -RawText 'D:, E:, F:'
Test-BRAVOCondition (
    @(Compare-Object $configuratorUITypedArray @('D:', 'E:', 'F:')).Count -eq 0
) `
    'ConfiguratorUI ConvertTo-...TypedValue: StringArray-текст парситься коректно (trim, без порожніх елементів)' `
    "Parsed=$($configuratorUITypedArray -join '|')"

$configuratorUIDisplayArrayText = ConvertTo-BRAVOConfiguratorUIDisplayText -Type 'StringArray' -Value @('D:', 'E:', 'F:')
Test-BRAVOCondition ($configuratorUIDisplayArrayText -eq 'D:, E:, F:') `
    'ConfiguratorUI ConvertTo-...DisplayText: StringArray форматується через кому' `
    "DisplayText=$configuratorUIDisplayArrayText"

# ===== 10: Static-analysis регресія (P1-stabilization): жоден
# .GetNewClosure()-scriptblock у BRAVO.Configurator.UI.psm1 не викликає
# приватну (не-exported) функцію ЦЬОГО модуля по імені напряму.
#
# Root cause реального дефекту (реальний запуск BRAVO_CONFIGURATOR.ps1
# падав на "term 'Update-BRAVOConfiguratorUICenterPanel' is not
# recognized" одразу при відкритті форми): у Windows PowerShell 5.1
# .GetNewClosure() створює клон scriptblock-а, що НЕ зберігає прив'язку
# до command-table приватних (не-exported) функцій свого модуля — прямий
# виклик такої функції по імені зсередини GetNewClosure()-блоку падає з
# CommandNotFoundException, навіть коли функція реально визначена в тому
# самому модулі. Жоден headless self-test цього не ловив, бо жоден з них
# не будує реальну WinForms-форму (Show-BRAVOConfiguratorMainForm
# навмисно поза межами цього фрагмента — див. коментар на початку файлу).
# Цей тест — суто статичний AST-аналіз (не будує жодного System.Windows.
# Forms-об'єкта), що ловить САМЕ цей патерн дефекту напряму в коді.
$configuratorUIModulePath = Join-Path $configuratorUIModuleRoot 'BRAVO.Configurator.UI.psm1'
$configuratorUIParseErrors = $null
$configuratorUITokens = $null
$configuratorUIAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $configuratorUIModulePath, [ref]$configuratorUITokens, [ref]$configuratorUIParseErrors)

$configuratorUIAllFunctionNames = @(
    $configuratorUIAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name }
)
$configuratorUIExportedFunctionNames = @((Get-Module BRAVO.Configurator.UI).ExportedFunctions.Keys)
$configuratorUIPrivateFunctionNames = @($configuratorUIAllFunctionNames | Where-Object { $configuratorUIExportedFunctionNames -notcontains $_ })

$configuratorUIClosureScriptBlocks = @(
    $configuratorUIAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        [string]$node.Member.Value -eq 'GetNewClosure' -and
        $node.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
    }, $true) | ForEach-Object { $_.Expression.ScriptBlock }
)

$configuratorUIBrokenClosureCalls = New-Object System.Collections.Generic.List[string]
foreach ($closureBlock in $configuratorUIClosureScriptBlocks) {
    $commandsInClosure = @($closureBlock.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    foreach ($commandAst in $commandsInClosure) {
        $calledName = [string]$commandAst.GetCommandName()
        if ($configuratorUIPrivateFunctionNames -contains $calledName) {
            $configuratorUIBrokenClosureCalls.Add("$calledName (рядок $($commandAst.Extent.StartLineNumber))")
        }
    }
}

Test-BRAVOCondition (
    $configuratorUIParseErrors.Count -eq 0 -and
    $configuratorUIPrivateFunctionNames.Count -gt 0 -and
    $configuratorUIClosureScriptBlocks.Count -gt 0 -and
    $configuratorUIBrokenClosureCalls.Count -eq 0
) `
    'ConfiguratorUI static: жоден .GetNewClosure()-блок не викликає приватну функцію модуля напряму по імені (regression для P1-launch-crash)' `
    ("ParseErrors=$($configuratorUIParseErrors.Count) PrivateFns=$($configuratorUIPrivateFunctionNames.Count) " +
     "ClosureBlocks=$($configuratorUIClosureScriptBlocks.Count) Broken=$($configuratorUIBrokenClosureCalls -join '; ')")

# =====================================================================
# P2-B (docs/design/BRAVO_CONFIGURATOR_DESIGN.md §12): деtermіновані
# headless-тести для чистих UX-helpers (breakpoint/filter labels/context
# help/startup-size/splitter clamp) + статична регресія проти
# повторного внесення fixed-layout боргу (§27 задачі). Жоден з цих
# тестів не будує System.Windows.Forms.Form — та сама ізоляція, що й
# решта фрагмента.
# =====================================================================

# ===== 11: Get-BRAVOConfiguratorUILayoutMode — детермінований breakpoint =====
$configuratorUILayoutCompact = Get-BRAVOConfiguratorUILayoutMode -ClientWidth 800
$configuratorUILayoutWide = Get-BRAVOConfiguratorUILayoutMode -ClientWidth 1200
$configuratorUILayoutBoundaryBelow = Get-BRAVOConfiguratorUILayoutMode -ClientWidth 999
$configuratorUILayoutBoundaryAt = Get-BRAVOConfiguratorUILayoutMode -ClientWidth 1000
Test-BRAVOCondition (
    $configuratorUILayoutCompact -eq 'Compact' -and $configuratorUILayoutWide -eq 'Wide' -and
    $configuratorUILayoutBoundaryBelow -eq 'Compact' -and $configuratorUILayoutBoundaryAt -eq 'Wide'
) `
    'ConfiguratorUI P2-B LayoutMode: детермінований Wide/Compact breakpoint (800->Compact, 1200->Wide, межа 999/1000)' `
    "800=$configuratorUILayoutCompact 1200=$configuratorUILayoutWide 999=$configuratorUILayoutBoundaryBelow 1000=$configuratorUILayoutBoundaryAt"

# ===== 12: Get-BRAVOConfiguratorUIFilterOptions — канонічна українська відповідність (§21) =====
$configuratorUIFilterOptions = @(Get-BRAVOConfiguratorUIFilterOptions)
$configuratorUIExpectedFilterMap = [ordered]@{
    All      = 'Усі'
    Changed  = 'Змінені'
    Active   = 'Активні'
    Problems = 'Проблеми'
    Advanced = 'Розширені'
}
$configuratorUIFilterMapMismatch = @($configuratorUIExpectedFilterMap.Keys | Where-Object {
    $expectedId = $_
    $actual = @($configuratorUIFilterOptions | Where-Object { $_.Id -eq $expectedId })
    ($actual.Count -ne 1) -or ($actual[0].Label -ne $configuratorUIExpectedFilterMap[$expectedId])
})
Test-BRAVOCondition (
    $configuratorUIFilterOptions.Count -eq $configuratorUIExpectedFilterMap.Count -and
    $configuratorUIFilterMapMismatch.Count -eq 0
) `
    'ConfiguratorUI P2-B FilterOptions: усі 5 backend Id мають канонічний український Label, без розбіжностей' `
    "Count=$($configuratorUIFilterOptions.Count) Mismatch=$($configuratorUIFilterMapMismatch -join ',')"

# ===== 13: Get-BRAVOConfiguratorUISettingHelpText — операторський зміст перед технічним (§14) =====
$configuratorUIHelpFixture = New-ConfiguratorUIFixtureSetting -Path 'fixture.Storage.Overridden' -Group 'Storage' -Section 'C' `
    -Label 'BackupRoot Override' -Type 'Path' -DefaultValue 'C:\Default' -OverridePresent $true -OverrideValue 'D:\Override' `
    -EffectiveValue 'D:\Override' -EffectiveSource 'Override'
$configuratorUIHelpText = Get-BRAVOConfiguratorUISettingHelpText -Setting $configuratorUIHelpFixture
$configuratorUINameIndex = $configuratorUIHelpText.IndexOf('Назва:')
$configuratorUIStateIndex = $configuratorUIHelpText.IndexOf('Поточний стан:')
$configuratorUIEffectiveIndex = $configuratorUIHelpText.IndexOf('Effective:')
$configuratorUIPathIndex = $configuratorUIHelpText.IndexOf('Path:')
Test-BRAVOCondition (
    $configuratorUINameIndex -ge 0 -and $configuratorUIStateIndex -gt $configuratorUINameIndex -and
    $configuratorUIEffectiveIndex -gt $configuratorUIStateIndex -and $configuratorUIPathIndex -gt $configuratorUIEffectiveIndex -and
    $configuratorUIHelpText -match 'Локальний override активний' -and
    $configuratorUIHelpText -notmatch 'password' -and $configuratorUIHelpText -notmatch 'secret'
) `
    'ConfiguratorUI P2-B SettingHelpText: операторський зміст (Назва/Поточний стан/Effective) передує технічним даним (Path), override-стан коректний, без secret-слів' `
    "NameIdx=$configuratorUINameIndex StateIdx=$configuratorUIStateIndex EffectiveIdx=$configuratorUIEffectiveIndex PathIdx=$configuratorUIPathIndex"

$configuratorUIHelpFixtureDefault = New-ConfiguratorUIFixtureSetting -Path 'fixture.Storage.Default' -Type 'String' -DefaultValue 'x' -EffectiveValue 'x'
$configuratorUIHelpTextDefault = Get-BRAVOConfiguratorUISettingHelpText -Setting $configuratorUIHelpFixtureDefault
Test-BRAVOCondition ($configuratorUIHelpTextDefault -match 'Використовується значення за замовчуванням') `
    'ConfiguratorUI P2-B SettingHelpText: без override "Поточний стан" явно каже "за замовчуванням" (Default != False з тексту так само, як з семантики)' `
    "Text=$configuratorUIHelpTextDefault"

# ===== 14: Get-BRAVOConfiguratorUIGeneralHelpText — статичний, без веб/зовнішніх посилань (§15) =====
$configuratorUIGeneralHelp = Get-BRAVOConfiguratorUIGeneralHelpText
Test-BRAVOCondition (
    (-not [string]::IsNullOrWhiteSpace($configuratorUIGeneralHelp)) -and
    $configuratorUIGeneralHelp -match 'Ctrl\+F' -and $configuratorUIGeneralHelp -match 'F1' -and
    $configuratorUIGeneralHelp -notmatch 'http://' -and $configuratorUIGeneralHelp -notmatch 'https://'
) `
    'ConfiguratorUI P2-B GeneralHelpText: непорожній, документує Ctrl+F/F1, без зовнішніх URL (немає web-браузера довідки)' `
    "Length=$($configuratorUIGeneralHelp.Length)"

# ===== 15: Get-BRAVOConfiguratorUIStartupSize — ніколи не більше WorkingArea, Min лише коли є місце (§5/§24) =====
$configuratorUIStartupSmallScreen = Get-BRAVOConfiguratorUIStartupSize -WorkingAreaWidth 1024 -WorkingAreaHeight 768
$configuratorUIStartupHugeScreen = Get-BRAVOConfiguratorUIStartupSize -WorkingAreaWidth 3840 -WorkingAreaHeight 2160
$configuratorUIStartupTinyScreen = Get-BRAVOConfiguratorUIStartupSize -WorkingAreaWidth 800 -WorkingAreaHeight 600
Test-BRAVOCondition (
    $configuratorUIStartupSmallScreen.Width -eq 1024 -and $configuratorUIStartupSmallScreen.Height -eq 768 -and
    $configuratorUIStartupHugeScreen.Width -eq 1150 -and $configuratorUIStartupHugeScreen.Height -eq 780 -and
    $configuratorUIStartupTinyScreen.Width -le 800 -and $configuratorUIStartupTinyScreen.Height -le 600
) `
    'ConfiguratorUI P2-B StartupSize: 1024x768 лишається повністю usable, великий екран не розтягує понад Preferred, замалий екран НІКОЛИ не перевищується (Min поступається WorkingArea)' `
    ("Small=$($configuratorUIStartupSmallScreen.Width)x$($configuratorUIStartupSmallScreen.Height) " +
     "Huge=$($configuratorUIStartupHugeScreen.Width)x$($configuratorUIStartupHugeScreen.Height) " +
     "Tiny=$($configuratorUIStartupTinyScreen.Width)x$($configuratorUIStartupTinyScreen.Height)")

# ===== 16: Get-BRAVOConfiguratorUIClampedSplitterDistance — легальний діапазон, без винятків (§12/§13) =====
$configuratorUISplitterNormal = Get-BRAVOConfiguratorUIClampedSplitterDistance -AvailableSize 1000 -Panel1MinSize 150 -Panel2MinSize 400 -DesiredDistance 220
$configuratorUISplitterTooSmallContainer = Get-BRAVOConfiguratorUIClampedSplitterDistance -AvailableSize 300 -Panel1MinSize 150 -Panel2MinSize 400 -DesiredDistance 220
$configuratorUISplitterDesiredTooBig = Get-BRAVOConfiguratorUIClampedSplitterDistance -AvailableSize 1000 -Panel1MinSize 150 -Panel2MinSize 400 -DesiredDistance 950
$configuratorUISplitterDesiredTooSmall = Get-BRAVOConfiguratorUIClampedSplitterDistance -AvailableSize 1000 -Panel1MinSize 150 -Panel2MinSize 400 -DesiredDistance 10
Test-BRAVOCondition (
    $configuratorUISplitterNormal -eq 220 -and
    $configuratorUISplitterTooSmallContainer -eq 150 -and
    $configuratorUISplitterDesiredTooBig -eq 600 -and
    $configuratorUISplitterDesiredTooSmall -eq 150
) `
    'ConfiguratorUI P2-B ClampedSplitterDistance: у межах діапазону лишається без змін, поза межами затискається, замалий контейнер повертає Panel1MinSize (не кидає ArgumentOutOfRangeException)' `
    "Normal=$configuratorUISplitterNormal TooSmallContainer=$configuratorUISplitterTooSmallContainer TooBig=$configuratorUISplitterDesiredTooBig TooSmall=$configuratorUISplitterDesiredTooSmall"

# ===== 17: Статична регресія (§27 задачі P2-B) — попередній fixed-layout
# борг (rowPanel.Width=700, form.Width=1150, form.Height=780 як
# ЄДИНО МОЖЛИВІ значення) не повертається. Навмисно ТОЧКОВО (не блокує
# кожне присвоєння .Width/.Height у файлі — лише конкретні знову-внесені
# магічні константи з попереднього fixed-layout контракту), як вимагає
# задача ("Do not build a brittle blanket ban against every .Width
# assignment"). 1150x780 і далі використовуються як Preferred* значення
# всередині Get-BRAVOConfiguratorUIStartupSize (де вони — верхня стеля,
# не хардкод присвоєння формі) — регресія перевіряє саме РЯДКОВИЙ
# патерн прямого присвоєння контролу, який P2-B прибрав.
$configuratorUIRawSource = Get-Content -LiteralPath $configuratorUIModulePath -Raw
$configuratorUIFixedLayoutDebtPatterns = @(
    '\$rowPanel\.Width\s*=\s*700\b'
    '\$form\.Width\s*=\s*1150\b'
    '\$form\.Height\s*=\s*780\b'
)
$configuratorUIReintroducedDebt = @($configuratorUIFixedLayoutDebtPatterns | Where-Object { $configuratorUIRawSource -match $_ })
Test-BRAVOCondition ($configuratorUIReintroducedDebt.Count -eq 0) `
    'ConfiguratorUI P2-B static regression: попередній fixed-layout борг (rowPanel.Width=700, form.Width=1150, form.Height=780 як пряме присвоєння) не реінтродукований' `
    "Reintroduced=$($configuratorUIReintroducedDebt -join '; ')"

# ===== 18: P2-B manual acceptance FAIL #5 регресія — Filter 'Problems'
# з $ValidationFindings=$null (не @()) НЕ падає з "The property 'Severity'
# cannot be found on this object". Реальний production-шлях:
# Update-BRAVOConfiguratorUICenterPanel обчислює
#   $validationFindings = if ($cond) { $State.ValidationResult.Findings } else { @() }
# — коли Findings є ПОРОЖНІМ масивом (типовий стан одразу після запуску,
# до будь-яких warnings/errors), PowerShell "згортає" тіло if-виразу з
# нуля елементів у $null (НЕ @()), що обходить `-ValidationFindings = @()`
# default нижче. `$null | Where-Object {...}` (на відміну від `@() |
# Where-Object {...}`) пропускає РІВНО один $null-елемент пайплайном,
# тому `[string]$_.Severity` падав під Set-StrictMode -Version 2.0.
# Викликається напряму з $ValidationFindings=$null — тестує контракт
# Get-BRAVOConfiguratorUIFilteredSettings, не UI-конструювання (фрагмент
# лишається headless, жодного System.Windows.Forms-об'єкта).
foreach ($configuratorUINullFindingsFilter in @('All', 'Changed', 'Active', 'Problems', 'Advanced')) {
    $configuratorUINullFindingsThrew = $false
    $configuratorUINullFindingsCount = -1
    try {
        $configuratorUINullFindingsResult = @(Get-BRAVOConfiguratorUIFilteredSettings -Model $configuratorUIFixtureModel -Filter $configuratorUINullFindingsFilter -ValidationFindings $null)
        $configuratorUINullFindingsCount = $configuratorUINullFindingsResult.Count
    } catch {
        $configuratorUINullFindingsThrew = $true
    }
    Test-BRAVOCondition (-not $configuratorUINullFindingsThrew) `
        "ConfiguratorUI P2-B regression (FAIL #5): Filter '$configuratorUINullFindingsFilter' з -ValidationFindings `$null не кидає виняток" `
        "Filter=$configuratorUINullFindingsFilter Threw=$configuratorUINullFindingsThrew Count=$configuratorUINullFindingsCount"
}
$configuratorUINullFindingsProblemsResult = @(Get-BRAVOConfiguratorUIFilteredSettings -Model $configuratorUIFixtureModel -Filter 'Problems' -ValidationFindings $null)
$configuratorUINullFindingsProblemsPaths = @($configuratorUINullFindingsProblemsResult | ForEach-Object { $_.Path })
Test-BRAVOCondition (
    ($configuratorUINullFindingsProblemsPaths -contains 'fixture.Storage.WithProblem') -and
    ($configuratorUINullFindingsProblemsPaths -notcontains 'fixture.Storage.NoProblem')
) `
    "ConfiguratorUI P2-B regression (FAIL #5): Filter 'Problems' з `$null ValidationFindings усе одно коректно фільтрує за DisabledReason" `
    "Paths=$($configuratorUINullFindingsProblemsPaths -join ',')"

# ===== 19: P2-B manual acceptance FAIL #11 follow-up регресія —
# ConvertTo-BRAVOConfiguratorUITypedValue для 'Path'/'UNCPath' тепер
# fail-closed на синтаксично некоректному шляху (раніше падало в
# default { return $RawText } без жодної перевірки — некоректний текст
# міг потрапити у $State.Model як override і зривав реальний
# Update-BRAVOConfiguratorEffective лише пізніше, під час Recalculate/
# Apply, з незрозумілою помилкою). Порожній рядок лишається легальним
# (валідність відсутності шляху — семантика Validation-модуля).
foreach ($configuratorUIPathType in @('Path', 'UNCPath')) {
    $configuratorUIValidPathResult = ConvertTo-BRAVOConfiguratorUITypedValue -Type $configuratorUIPathType -RawText '  \\host\share\BRAVO  '
    Test-BRAVOCondition ($configuratorUIValidPathResult -eq '\\host\share\BRAVO') `
        "ConfiguratorUI P2-B regression (FAIL #11 follow-up): Type '$configuratorUIPathType' пропускає валідний UNC-шлях (з trim)" `
        "Result='$configuratorUIValidPathResult'"

    $configuratorUIEmptyPathResult = ConvertTo-BRAVOConfiguratorUITypedValue -Type $configuratorUIPathType -RawText ''
    Test-BRAVOCondition ($configuratorUIEmptyPathResult -eq '') `
        "ConfiguratorUI P2-B regression (FAIL #11 follow-up): Type '$configuratorUIPathType' пропускає порожній рядок (валідна відсутність шляху)" `
        "Result='$configuratorUIEmptyPathResult'"

    $configuratorUIInvalidPathThrew = $false
    try {
        [void](ConvertTo-BRAVOConfiguratorUITypedValue -Type $configuratorUIPathType -RawText 'C:\Bad|Path')
    } catch {
        $configuratorUIInvalidPathThrew = $true
    }
    Test-BRAVOCondition $configuratorUIInvalidPathThrew `
        "ConfiguratorUI P2-B regression (FAIL #11 follow-up): Type '$configuratorUIPathType' fail-closed на синтаксично некоректному шляху (не комітиться як default { return `$RawText })" `
        "Threw=$configuratorUIInvalidPathThrew"
}
