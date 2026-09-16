[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BeforePath,
    [Parameter(Mandatory = $true)][string]$AfterPath,
    [string]$RuntimeRoot = 'C:\Program Files\BRAVO-Toolkit'
)

# Порівняння двох знімків ефективної конфігурації (#154, підготовка pilot
# migration).
#
# НА ЯКЕ ПИТАННЯ ВІДПОВІДАЄ: "чи справді перенесення site-значень із
# BRAVO.config у BRAVO.local.config НЕ змінило ефективних значень на цьому
# сервері". Це і є критерій приймання міграції, і доти, доки його не було
# чим перевірити над ПОВНИМ графом, приймати міграцію не було на чому.
#
# ЩО ВІН НІКОЛИ НЕ РОБИТЬ: не читає конфігурацію, не чіпає сервер і нічого
# не записує. Вхід — два JSON-файли, зняті
# BRAVO_CONFIG_TEST.ps1 -FullGraph.
#
# ПОЛІТИКА ПОРІВНЯННЯ НЕ ДУБЛЮЄТЬСЯ: сам обхід графа виконує канонічний
# Compare-BRAVOConfigurationGraph (BRAVO.Configuration.Delta). Тут лише
# нормалізація JSON у hashtable і класифікація метаданих.
#
# FAIL-CLOSED: будь-яка неочікувана відмінність -> exit 1. Мовчазний
# успіх при розходженні знецінив би весь крок.

$ErrorActionPreference = 'Stop'

# Поля BravoConfigurationMetadata, які міграція ЗМІНЮЄ ЗА ВИЗНАЧЕННЯМ:
# вони описують ДЖЕРЕЛО конфігурації, а не значення. Перелік поіменний, а
# не префіксний: мовчки заглушити весь вузол метаданих означало б втратити
# і перевірку версії комплекту, яка тут якраз мусить лишитись незмінною.
$expectedSourceFields = @(
    # Час завантаження — різний між будь-якими двома прогонами.
    'BravoConfigurationMetadata.LoadedAt',
    # Режим і формат завантаження: саме їх і змінює міграція.
    'BravoConfigurationMetadata.Mode',
    'BravoConfigurationMetadata.Format',
    'BravoConfigurationMetadata.ConfigPath',
    # Primary-шар (BRAVO.config) — те, від чого йде відмова.
    'BravoConfigurationMetadata.PrimaryConfigPath',
    'BravoConfigurationMetadata.PrimaryConfigPresent',
    'BravoConfigurationMetadata.PrimaryConfigWasExplicit',
    'BravoConfigurationMetadata.PrimaryConfigOverridesCanonicalDefaults',
    'BravoConfigurationMetadata.PrimaryConfigIgnoredGlobals',
    'BravoConfigurationMetadata.PrimaryConfigUnknownNestedKeys',
    # Версія, оголошена самим BRAVO.config: зникає разом із файлом.
    'BravoConfigurationMetadata.LegacyScriptVersion',
    'BravoConfigurationMetadata.LegacyScriptVersionPresent',
    'BravoConfigurationMetadata.PackageVersionMatchesLegacyConfig',
    # Local-шар (BRAVO.local.config) — те, куди значення переїжджають.
    'BravoConfigurationMetadata.LocalConfigPath',
    'BravoConfigurationMetadata.LocalConfigPresent',
    'BravoConfigurationMetadata.LocalConfigOverrides',
    'BravoConfigurationMetadata.AppliedLocalOverrideKeys',
    'BravoConfigurationMetadata.LocalConfigUnknownLeafOverrides',
    'BravoConfigurationMetadata.LocalConfigDeclaredSchemaVersion',
    'BravoConfigurationMetadata.LocalConfigEffectiveSchemaVersion',
    # Стан local-шару як окрема верхньорівнева змінна — той самий клас.
    'BravoLocalConfigOverrideState'
)

function ConvertTo-SnapshotHashtable {
    # JSON -> hashtable. Compare-BRAVOConfigurationGraph приймає саме
    # hashtable, а ConvertFrom-Json у Windows PowerShell 5.1 повертає
    # PSCustomObject (ConvertFrom-Json -AsHashtable з'явився лише в
    # PowerShell 6), тож конвертація тут обов'язкова, а не стилістична.
    param($Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-SnapshotHashtable -Value $property.Value
        }
        return $result
    }

    # @() навколо результату: у 5.1 pipeline розгортає одноелементний
    # масив у скаляр, і масив з одного значення перестав би бути масивом —
    # тобто два однакові знімки могли б дати хибну відмінність за ТИПОМ.
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return @(@($Value) | ForEach-Object { ConvertTo-SnapshotHashtable -Value $_ })
    }

    return $Value
}

function Read-SnapshotGraph {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Label)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Не знайдено знімок $Label : $Path"
    }
    $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $document.PSObject.Properties['EffectiveGraph']) {
        throw "Знімок $Label не містить EffectiveGraph — знімайте через BRAVO_CONFIG_TEST.ps1 -FullGraph, а не -AsJson."
    }
    return (ConvertTo-SnapshotHashtable -Value $document.EffectiveGraph)
}

try {
    $resolvedRuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
    $deltaModulePath = Join-Path $resolvedRuntimeRoot 'modules\BRAVO.Configuration\BRAVO.Configuration.Delta.psd1'
    if (-not (Test-Path -LiteralPath $deltaModulePath -PathType Leaf)) {
        throw "Не знайдено $deltaModulePath — перевірте -RuntimeRoot."
    }
    Import-Module -Name $deltaModulePath -Force -ErrorAction Stop

    $beforeGraph = Read-SnapshotGraph -Path $BeforePath -Label 'BEFORE'
    $afterGraph = Read-SnapshotGraph -Path $AfterPath -Label 'AFTER'

    # -IncludeMissingInCandidate обов'язковий: зникле поле — це теж зміна
    # ефективної конфігурації, і за замовчуванням comparer його не
    # повертає (для задачі "що перевизначено" відсутність означає дефолт,
    # для задачі "чи щось змінилось" — ні).
    $differences = @(Compare-BRAVOConfigurationGraph `
        -ReferenceConfiguration $beforeGraph `
        -CandidateConfiguration $afterGraph `
        -IncludeMissingInCandidate)

    $expected = New-Object System.Collections.Generic.List[object]
    $unexpected = New-Object System.Collections.Generic.List[object]
    foreach ($difference in $differences) {
        if ($null -eq $difference) { continue }
        $path = [string]$difference.Path
        $isExpected = $false
        foreach ($field in $expectedSourceFields) {
            if ($path -eq $field -or $path.StartsWith("$field.", [StringComparison]::OrdinalIgnoreCase)) {
                $isExpected = $true
                break
            }
        }
        if ($isExpected) { [void]$expected.Add($difference) } else { [void]$unexpected.Add($difference) }
    }

    Write-Output "BEFORE: $BeforePath"
    Write-Output "AFTER:  $AfterPath"
    Write-Output ''
    Write-Output "[INFO] Очікуваних відмінностей (джерело конфігурації): $($expected.Count)"
    foreach ($difference in $expected) {
        Write-Output ("    {0} [{1}]" -f $difference.Path, $difference.Kind)
    }
    Write-Output ''

    if ($unexpected.Count -eq 0) {
        Write-Output '[SUCCESS] Ефективні значення не змінились — міграцію можна приймати.'
        exit 0
    }

    Write-Output "[ERROR] Неочікуваних відмінностей: $($unexpected.Count) — це РЕГРЕСІЯ ефективної конфігурації."
    foreach ($difference in $unexpected) {
        Write-Output ("    {0} [{1}]" -f $difference.Path, $difference.Kind)
        Write-Output ("        BEFORE: {0}" -f (ConvertTo-Json -InputObject $difference.ReferenceValue -Depth 5 -Compress))
        Write-Output ("        AFTER:  {0}" -f (ConvertTo-Json -InputObject $difference.CandidateValue -Depth 5 -Compress))
    }
    exit 1
} catch {
    $ErrorActionPreference = 'Continue'
    Write-Error $_.Exception.Message
    exit 1
}
