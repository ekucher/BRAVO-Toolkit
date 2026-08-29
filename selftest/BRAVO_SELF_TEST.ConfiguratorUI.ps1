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
