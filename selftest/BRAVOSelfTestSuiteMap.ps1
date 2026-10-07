# ============================================================
# Мапа "змінений шлях -> suite" і консервативний класифікатор Affected (VAL-05, PR1).
#
# КАНОНІЧНИЙ ВЛАСНИК каталогу -Suite, підказки "шлях -> suite" і плану Affected.
# Файл dot-source-ить BRAVO_SELF_TEST.ps1 (після перевірки цілісності
# RUNTIME_MANIFEST і до розбору -Suite); тому він:
#   * не є фрагментом (ім'я не збігається з BRAVO_SELF_TEST.<Ім'я>.ps1);
#   * не тримає стану, окрім каталогу $script:BRAVOSelfTestSuiteCatalog;
#   * безпечний під Set-StrictMode -Version 2.0 і сумісний з Windows PowerShell 5.1;
#   * чистий: жодного читання git, диска чи середовища.
#
# ІНВАРІАНТИ ПЛАНУ (рішення ревізій 2 і 2.1 дизайну Affected):
#   * клас лише V1, V2 або V3 - V0 не видається НІКОЛИ (рішення P1-B);
#   * клас - МІНІМАЛЬНИЙ ЗА КАРТОЮ ШЛЯХІВ, а не класифікація PR; Affected
#     ніколи не є acceptance (IsAcceptanceEvidence = $false);
#   * будь-який шлях без відповідності, зокрема змішаний набір відомих і
#     невідомих, дає V3 і Suite = @() - вибірковий прогін лише відомих suite
#     небезпечний, тому не пропонується;
#   * Governance входить до union завжди, коли клас нижчий за V3;
#   * union упорядковано за каталогом (детермінований результат).
# ============================================================

$script:BRAVOSelfTestSuiteCatalog = @(
    'Archive', 'ArchiveDiskSpace', 'BackupDestinations', 'BackupScope', 'BazaSync', 'ConfigIntent', 'ConfigLoader',
    'Configuration', 'Configurator', 'ConfiguratorUI', 'ConsoleUX', 'DataRestore',
    'DiskSpace', 'Governance', 'LogRotation', 'MaintenanceDiskSpace',
    'MaintenanceOwnLog', 'MaintenanceRepair', 'ManifestStorage', 'Operations', 'Paths',
    'RestoreSynthetic', 'RestoreVerify', 'ServiceQuiescence',
    'SftpCredentialsRequired', 'Status', 'TraceArchive'
)

function ConvertTo-BRAVOSelfTestNormalizedChangedPath {
    <#
        Єдина нормалізація шляху для мапи й плану. Повертає шлях через '\'
        без провідних '.\' або $null, якщо шлях некоректний.

        Шлях НЕ обрізається: якщо Trim() змінив би його (пробіли, переводи
        рядка по краях), шлях некоректний - обрізання приховало б, що вхід
        не є точним шляхом з git. Некоректні: порожній, з керувальними
        символами, абсолютні ('X:', провідний '\' чи '/', UNC), та з
        сегментами '', '.' або '..' (обхід каталогів).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $null }
    if ($Path.Trim() -cne $Path) { return $null }
    # Лише друковний ASCII: керувальні символи й не-ASCII (Kelvin sign U+212A, довге s, кириличні двійники)
    # не мусять потрапляти в правила з (?i), які згортають регістр за Unicode.
    if ($Path -cmatch '[^\x20-\x7E]') { return $null }
    $normalized = $Path.Replace('/', '\')
    if ($normalized.StartsWith('\')) { return $null }
    if ($normalized -match '^[A-Za-z]:') { return $null }
    while ($normalized.StartsWith('.\')) { $normalized = $normalized.Substring(2) }
    if ($normalized.Length -eq 0) { return $null }
    foreach ($segment in $normalized.Split([char[]]@([char]92))) {
        if ($segment.Length -eq 0 -or $segment -ceq '.' -or $segment -ceq '..') { return $null }
    }
    return $normalized
}

function Get-BRAVOSelfTestSuiteForChangedPath {
    <#
        Підказка "змінений файл -> suite" для розробника.

        Порожній результат означає "не знаю", і це НЕ дозвіл звузити прогін:
        викликач має виконати повний. Мапа свідомо мінімальна й перевірювана -
        застаріла мапа гірша за її відсутність, бо тихо радить пропустити те,
        що саме й зламано.

        Правила прив'язані до початку шляху й точні:
          * фрагмент: ^selftest\BRAVO_SELF_TEST.<Ім'я>.ps1$ з каталогу;
          * модуль: ім'я каталогу береться ПОВНИМ сегментом і шукається в
            явній таблиці "каталог модуля -> suite" (BRAVO.Archive.Legacy
            не дорівнює BRAVO.Archive).
        Результат розгортається конвеєром: викликач обгортає його в @(...).
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)

    $changedPath = ConvertTo-BRAVOSelfTestNormalizedChangedPath -Path $Path
    if ($null -eq $changedPath) { return @() }

    # 1. Сам фрагмент -> однойменний suite. Це механічно точно, без здогадок.
    $changedFragment = [regex]::Match($changedPath, '(?i)^selftest\\BRAVO_SELF_TEST\.([A-Za-z]+)\.ps1$')
    if ($changedFragment.Success) {
        $fragmentName = $changedFragment.Groups[1].Value
        if ($fragmentName -cnotmatch '^[A-Za-z][A-Za-z.]*$') { return @() }
        $changedSuite = @($script:BRAVOSelfTestSuiteCatalog |
            Where-Object { [string]::Equals([string]$_, $fragmentName, [StringComparison]::OrdinalIgnoreCase) })
        if (@($changedSuite).Count -gt 0) { return @($changedSuite) }
        return @()
    }

    # 2. Доменний модуль -> suite з явної таблиці (ключ - повне ім'я каталогу).
    $moduleSuiteTable = @{
        'Archive'                = 'Archive'
        'BazaSync'               = 'BazaSync'
        'Configuration'          = 'Configuration'
        'Configurator'           = 'Configurator'
        'DataRestore'            = 'DataRestore'
        'DataRestore.MatrixTest' = 'DataRestore'
        'DiskSpace'              = 'DiskSpace'
        'Operations'             = 'Operations'
        'RestoreVerify'          = 'RestoreVerify'
        'Status'                 = 'Status'
    }
    $moduleLookup = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($moduleKey in @($moduleSuiteTable.Keys)) { $moduleLookup[[string]$moduleKey] = [string]$moduleSuiteTable[$moduleKey] }
    $changedModule = [regex]::Match($changedPath, '(?i)^modules\\BRAVO\.([^\\]+)\\')
    if ($changedModule.Success -and $changedModule.Groups[1].Value -cmatch '^[A-Za-z][A-Za-z.]*$' -and
        $moduleLookup.ContainsKey($changedModule.Groups[1].Value)) {
        $moduleSuiteName = $moduleLookup[$changedModule.Groups[1].Value]
        $changedSuite = @($script:BRAVOSelfTestSuiteCatalog |
            Where-Object { [string]::Equals([string]$_, $moduleSuiteName, [StringComparison]::OrdinalIgnoreCase) })
        if (@($changedSuite).Count -gt 0) { return @($changedSuite) }
    }
    return @()
}

function Get-BRAVOSelfTestLeafModuleTable {
    <#
        Таблиця leaf-модулів V2: "каталог модуля" -> @{ Owner; Dependents }.

        Leaf-модуль - модуль БЕЗ вхідних ребер від будь-якого не-фрагмента
        (іншого модуля, BRAVO_CONFIG_LOADER.ps1, кореневого BRAVO_*.ps1 крім
        BRAVO_SELF_TEST.ps1, deploy\*.ps1, ci\*.ps1). Лише для таких модулів
        зміна дає V2 {Owner + Dependents}; решта модулів - V3.

        На базі гілки (18137d9) усі 10 модулів із suite мають вхідні ребра
        від не-фрагментів, тож таблиця ПОРОЖНЯ: зміна будь-якого реального
        модуля дає V3. Це консервативно. Таблицю обмежує знизу статичний
        guard Framework/AffectedPlan.LeafModulesHaveNoNonFragmentInboundEdge.
    #>
    [CmdletBinding()]
    param()
    return @{}
}

function Get-BRAVOSelfTestConsumedDocumentTable {
    <#
        Таблиця "живих" документів: їх читають suite або CI, тому зміна
        лише такого документа має клас V1 з відповідними споживачами.
        Будь-який інший *.md (зокрема docs\**) - V3.

        Ключ - шлях через '\' від кореня репозиторію. Gate - метадані
        CI-перевірки, яку зміна документа мусить пройти додатково.
    #>
    [CmdletBinding()]
    param()
    return @{
        'README.md'            = @{ Suite = @('Governance'); Gate = @('Release policy') }
        'SECURITY.md'          = @{ Suite = @('Governance'); Gate = @() }
        'RELEASE_CHECKLIST.md' = @{ Suite = @('Governance'); Gate = @() }
        'RELEASE_POLICY.md'    = @{ Suite = @('Governance'); Gate = @() }
        'THREAT_MODEL.md'      = @{ Suite = @('Governance'); Gate = @() }
        'PROJECT.md'           = @{ Suite = @('Governance'); Gate = @() }
        'deploy\README.md'     = @{ Suite = @('Governance'); Gate = @() }
        'OPERATIONS.md'        = @{ Suite = @('Governance', 'DataRestore'); Gate = @() }
        'BRAVO_SETUP.md'       = @{ Suite = @('Governance', 'ConfigLoader'); Gate = @('Release policy') }
        'CHANGELOG.md'         = @{ Suite = @('Governance'); Gate = @('Release policy') }
    }
}

function Test-BRAVOSelfTestRuntimeManifestCompanion {
    <#
        Чи є зміна RUNTIME_MANIFEST.json ПОХІДНИМ супутником змін у ChangedPath.
        Будь-яка зміна .ps1/.psm1/.psd1 вимагає регенерації маніфесту, тож
        маніфест сам по собі не може підвищувати клас до V3.

        Супутник лише якщо водночас:
          (а) обидва тексти розбираються ConvertFrom-Json;
          (б) набір полів верхнього рівня та значення schemaVersion,
              description, updateProcedure ідентичні;
          (в) кожен ключ files, який додано, видалено чи змінено (без регістру,
              '\' -> '/'), є шляхом із ChangedPath.
        Інакше (зокрема коли тексти недоступні) - НЕ супутник.
        Повертає { IsCompanion; Reason; OutsideEntry }.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$BaseText,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$CurrentText,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ChangedPath
    )

    $fail = {
        param([string]$Reason, [string[]]$Outside)
        $outsideList = @()
        if ($null -ne $Outside) { $outsideList = @($Outside) }
        return [pscustomobject]@{ IsCompanion = $false; Reason = $Reason; OutsideEntry = [string[]]$outsideList }
    }
    $parse = {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
        try {
            return (ConvertFrom-Json -InputObject $Text -ErrorAction Stop)
        } catch {
            return $null
        }
    }
    $baseObject = & $parse $BaseText
    $currentObject = & $parse $CurrentText
    if ($null -eq $baseObject -or $null -eq $currentObject) {
        return (& $fail 'текст маніфесту недоступний або не є коректним JSON' @())
    }
    if ($baseObject -isnot [pscustomobject] -or $currentObject -isnot [pscustomobject]) {
        return (& $fail 'корінь маніфесту не є JSON-об''єктом' @())
    }

    $nameSet = {
        param($Object)
        $names = [string[]]@($Object.PSObject.Properties | ForEach-Object { $_.Name })
        [Array]::Sort($names, [StringComparer]::Ordinal)
        return [string]::Join('|', $names)
    }
    if ((& $nameSet $baseObject) -cne (& $nameSet $currentObject)) {
        return (& $fail 'набір полів верхнього рівня змінено' @())
    }
    foreach ($fieldName in @('schemaVersion', 'description', 'updateProcedure', 'files')) {
        if ($null -eq $baseObject.PSObject.Properties[$fieldName]) {
            return (& $fail ("відсутнє поле '" + $fieldName + "'") @())
        }
    }
    foreach ($fieldName in @('schemaVersion', 'description', 'updateProcedure')) {
        # Порівняння з урахуванням типу: 1 і "1" - різні значення.
        $baseField = ConvertTo-Json -InputObject $baseObject.PSObject.Properties[$fieldName].Value -Compress -Depth 5
        $currentField = ConvertTo-Json -InputObject $currentObject.PSObject.Properties[$fieldName].Value -Compress -Depth 5
        if ($baseField -cne $currentField) {
            return (& $fail ("поле '" + $fieldName + "' змінено") @())
        }
    }
    $baseFiles = $baseObject.PSObject.Properties['files'].Value
    $currentFiles = $currentObject.PSObject.Properties['files'].Value
    if ($baseFiles -isnot [pscustomobject] -or $currentFiles -isnot [pscustomobject]) {
        return (& $fail 'поле files не є JSON-об''єктом' @())
    }

    $toMap = {
        param($Object)
        $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in @($Object.PSObject.Properties)) {
            $mapKey = ([string]$property.Name).Replace('\', '/')
            if ($map.ContainsKey($mapKey)) { return $null }
            $map[$mapKey] = [string]$property.Value
        }
        return , $map
    }
    $baseMap = & $toMap $baseFiles
    $currentMap = & $toMap $currentFiles
    if ($null -eq $baseMap -or $null -eq $currentMap) {
        return (& $fail 'files містить ключі, що збігаються після нормалізації' @())
    }

    $changedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($changedItem in @($ChangedPath)) {
        $changedKey = ConvertTo-BRAVOSelfTestNormalizedChangedPath -Path $changedItem
        if ($null -ne $changedKey) { [void]$changedSet.Add($changedKey.Replace('\', '/')) }
    }
    $touchedKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($mapKey in @($baseMap.Keys) + @($currentMap.Keys)) {
        [void]$touchedKeys.Add([string]$mapKey)
    }
    $outside = New-Object System.Collections.Generic.List[string]
    $deltaCount = 0
    foreach ($touchedKey in $touchedKeys) {
        $inBase = $baseMap.ContainsKey($touchedKey)
        $inCurrent = $currentMap.ContainsKey($touchedKey)
        if ($inBase -and $inCurrent -and $baseMap[$touchedKey] -ceq $currentMap[$touchedKey]) { continue }
        $deltaCount++
        if (-not $changedSet.Contains($touchedKey)) { [void]$outside.Add($touchedKey) }
    }
    $outsideSorted = [string[]]@($outside.ToArray())
    [Array]::Sort($outsideSorted, [StringComparer]::Ordinal)
    if ($outsideSorted.Count -gt 0) {
        return (& $fail ('дельта files виходить за ChangedPath: ' + [string]::Join(', ', $outsideSorted)) $outsideSorted)
    }
    return [pscustomobject]@{
        IsCompanion  = $true
        Reason       = ('дельта files (' + $deltaCount + ') повністю в ChangedPath')
        OutsideEntry = [string[]]@()
    }
}

function Get-BRAVOSelfTestAffectedPlan {
    <#
        Мінімальний клас і union suite за картою шляхів. Чиста функція:
        не читає git/диск і не змінює $script:BRAVOSelfTestSelectedSuite.

        Правила по кожному шляху, по порядку:
          1. некоректний шлях (обрізання змінило б його, '..', абсолютний,
             порожній) -> V3;
          2. RUNTIME_MANIFEST.json: похідний супутник -> щонайменше V2 (навіть
             з порожньою розібраною дельтою) + gate "Integrity manifests are
             current"; інакше V3. Tools\TOOLS_MANIFEST.json і VERSION.json - V3;
          3. видалений відомий шлях (фрагмент, leaf-модуль, документ) -> V3;
          4. каталожний фрагмент -> V2 {suite};
          5. leaf-модуль -> V2 {Owner + Dependents};
          6. документ із таблиці -> V1 {споживачі};
          7. усе інше -> V3.
        Клас - максимум по шляхах; V3 -> Suite = @(); інакше union + Governance
        в порядку каталогу. Якщо поза супутником маніфесту не лишилося жодного
        шляху - V3.

        RequiredGate - підказка метаданих CI-перевірок (Integrity, Release policy,
        матричний тест DataRestore). Gate Config parity тут НЕ обчислюється: її
        рішення належить канонічному ci\Test-BRAVOConfigParityRelevantPath.ps1, який
        викликає runner (PR3); копії переліку шляхів у мапі немає.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ChangedPath,
        [Parameter()][AllowEmptyCollection()][AllowEmptyString()][string[]]$DeletedPath = @(),
        [Parameter()][AllowNull()][object]$RuntimeManifestCompanion,
        [Parameter()][AllowNull()][hashtable]$LeafModuleTable,
        [Parameter()][AllowNull()][hashtable]$ConsumedDocumentTable
    )

    $classLabel = 'мінімальний клас за картою шляхів'
    $catalog = @($script:BRAVOSelfTestSuiteCatalog)
    $gateOrder = @('Integrity manifests are current', 'Release policy', 'DataRestore matrix test')
    if ($null -eq $LeafModuleTable) { $LeafModuleTable = Get-BRAVOSelfTestLeafModuleTable }
    if ($null -eq $ConsumedDocumentTable) { $ConsumedDocumentTable = Get-BRAVOSelfTestConsumedDocumentTable }
    # Пошук за ключем - явний OrdinalIgnoreCase, а не залежний від культури хеш-таблиці.
    $leafLookup = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($tableKey in @($LeafModuleTable.Keys)) { $leafLookup[[string]$tableKey] = $LeafModuleTable[$tableKey] }
    $documentLookup = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($tableKey in @($ConsumedDocumentTable.Keys)) { $documentLookup[[string]$tableKey] = $ConsumedDocumentTable[$tableKey] }

    $getMember = {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return , $Object[$Name] }
            return $null
        }
        $member = $Object.PSObject.Properties[$Name]
        if ($null -ne $member) { return , $member.Value }
        return $null
    }
    # Імена suite з таблиць приводяться до написання каталогу; невідоме ім'я -> $null.
    $toCatalogNames = {
        param($Names)
        $resolved = New-Object System.Collections.Generic.List[string]
        foreach ($name in @($Names)) {
            $match = @($catalog | Where-Object { [string]::Equals([string]$_, [string]$name, [StringComparison]::OrdinalIgnoreCase) })
            if ($match.Count -eq 0) { return $null }
            [void]$resolved.Add([string]$match[0])
        }
        return , @($resolved.ToArray())
    }

    $deletedKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($deletedItem in @($DeletedPath)) {
        $deletedKey = ConvertTo-BRAVOSelfTestNormalizedChangedPath -Path $deletedItem
        if ($null -ne $deletedKey) { [void]$deletedKeys.Add($deletedKey) }
    }
    $entries = New-Object System.Collections.Generic.List[object]
    $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $seenInvalid = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($rawPath in (@($ChangedPath) + @($DeletedPath))) {
        $pathKey = ConvertTo-BRAVOSelfTestNormalizedChangedPath -Path $rawPath
        if ($null -eq $pathKey) {
            if ($seenInvalid.Add([string]$rawPath)) {
                [void]$entries.Add([pscustomobject]@{ Raw = [string]$rawPath; Key = $null; Deleted = $false })
            }
            continue
        }
        if ($seenKeys.Add($pathKey)) {
            [void]$entries.Add([pscustomobject]@{ Raw = [string]$rawPath; Key = $pathKey; Deleted = $deletedKeys.Contains($pathKey) })
        }
    }

    if (@($ChangedPath).Count -eq 0) {
        # Порожній вхід - не план. Клас V3 і Suite = @() на випадок, якщо викликач проігнорує Status.
        return [pscustomobject]@{
            Status                    = 'EmptyInput'
            Class                     = 'V3'
            ClassLabel                = $classLabel
            Suite                     = [string[]]@()
            RequiredGate              = [string[]]@()
            RequiresIndependentReview = $true
            UnknownPath               = [string[]]@()
            Decision                  = [object[]]@()
            IsAcceptanceEvidence      = $false
        }
    }

    $companionFlag = $null
    if ($null -ne $RuntimeManifestCompanion) { $companionFlag = & $getMember $RuntimeManifestCompanion 'IsCompanion' }
    $companionOk = ($companionFlag -is [bool] -and $companionFlag)
    $companionReason = 'супутник маніфесту не підтверджено'
    if ($null -ne $RuntimeManifestCompanion) {
        $reasonValue = & $getMember $RuntimeManifestCompanion 'Reason'
        if ($null -ne $reasonValue) { $companionReason = [string]$reasonValue }
    }

    $matrixPrefix = @('modules\bravo.datarestore\', 'modules\bravo.datarestore.matrixtest\')

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        $rowClass = 'V3'
        $rowSuite = New-Object System.Collections.Generic.List[string]
        $rowGate = New-Object System.Collections.Generic.List[string]
        $rowReason = ''
        $rowCompanion = $false

        if ($null -eq $entry.Key) {
            $rowReason = 'некоректний шлях (порожній, обрізання змінює його, абсолютний, з сегментами ''.'' чи ''..'')'
        } else {
            $pathKey = [string]$entry.Key
            $lowerKey = $pathKey.ToLowerInvariant()
            if ($lowerKey -ceq 'bravo_data_restore_matrix_test.ps1') { [void]$rowGate.Add('DataRestore matrix test') }
            foreach ($prefix in $matrixPrefix) {
                if ($lowerKey.StartsWith($prefix, [StringComparison]::Ordinal)) { [void]$rowGate.Add('DataRestore matrix test') }
            }

            $fragmentMatch = [regex]::Match($pathKey, '(?i)^selftest\\BRAVO_SELF_TEST\.([A-Za-z]+)\.ps1$')
            $moduleMatch = [regex]::Match($pathKey, '(?i)^modules\\BRAVO\.([^\\]+)\\')
            if ($lowerKey -ceq 'runtime_manifest.json') {
                [void]$rowGate.Add('Integrity manifests are current')
                if ($entry.Deleted) {
                    $rowReason = 'маніфест видалено'
                } elseif ($companionOk) {
                    $rowClass = 'V2'
                    $rowCompanion = $true
                    $rowReason = 'похідний супутник маніфесту (мінімум V2)'
                } else {
                    $rowReason = 'маніфест не є похідним супутником: ' + $companionReason
                }
            } elseif ($lowerKey -ceq 'tools\tools_manifest.json') {
                [void]$rowGate.Add('Integrity manifests are current')
                $rowReason = 'маніфест інструментів - завжди V3'
            } elseif ($lowerKey -ceq 'version.json') {
                [void]$rowGate.Add('Release policy')
                $rowReason = 'VERSION.json - завжди V3'
            } elseif ($fragmentMatch.Success) {
                $mappedSuite = @(Get-BRAVOSelfTestSuiteForChangedPath -Path $pathKey)
                if ($mappedSuite.Count -eq 0) {
                    $rowReason = 'фрагмент поза каталогом suite'
                } elseif ($entry.Deleted) {
                    $rowReason = 'видалений фрагмент каталогу'
                } else {
                    $rowClass = 'V2'
                    foreach ($mappedName in $mappedSuite) { [void]$rowSuite.Add([string]$mappedName) }
                    $rowReason = 'фрагмент каталогу'
                }
            } elseif ($moduleMatch.Success -and $moduleMatch.Groups[1].Value -cmatch '^[A-Za-z][A-Za-z.]*$' -and
                $leafLookup.ContainsKey($moduleMatch.Groups[1].Value)) {
                $leafEntry = $leafLookup[$moduleMatch.Groups[1].Value]
                $leafOwner = & $getMember $leafEntry 'Owner'
                $leafDependents = & $getMember $leafEntry 'Dependents'
                $leafNames = @()
                if ($null -ne $leafOwner) { $leafNames += @([string]$leafOwner) }
                if ($null -ne $leafDependents) { $leafNames += @($leafDependents) }
                $leafResolved = $null
                if ($null -ne $leafOwner -and $leafNames.Count -gt 0) { $leafResolved = & $toCatalogNames $leafNames }
                if ($null -eq $leafResolved) {
                    $rowReason = 'запис leaf-модуля некоректний (немає Owner або suite поза каталогом)'
                } elseif ($entry.Deleted) {
                    $rowReason = 'видалений файл leaf-модуля'
                } else {
                    $rowClass = 'V2'
                    foreach ($leafName in @($leafResolved)) { [void]$rowSuite.Add([string]$leafName) }
                    $rowReason = 'leaf-модуль: owner + dependents'
                }
            } elseif ($documentLookup.ContainsKey($pathKey)) {
                $documentEntry = $documentLookup[$pathKey]
                $documentSuites = & $getMember $documentEntry 'Suite'
                $documentGates = & $getMember $documentEntry 'Gate'
                $documentResolved = $null
                if ($null -ne $documentSuites) { $documentResolved = & $toCatalogNames $documentSuites }
                if ($null -eq $documentResolved -or @($documentResolved).Count -eq 0) {
                    $rowReason = 'запис документа некоректний (немає споживачів або suite поза каталогом)'
                } elseif ($entry.Deleted) {
                    $rowReason = 'видалений документ із таблиці споживаних'
                } else {
                    $rowClass = 'V1'
                    foreach ($documentName in @($documentResolved)) { [void]$rowSuite.Add([string]$documentName) }
                    foreach ($documentGate in @($documentGates)) {
                        if ($null -ne $documentGate) { [void]$rowGate.Add([string]$documentGate) }
                    }
                    $rowReason = 'документ із таблиці споживаних'
                }
            } else {
                $rowReason = 'шлях без відповідності в карті'
            }
        }
        [void]$rows.Add([pscustomobject]@{
                Path        = [string]$entry.Raw
                Class       = $rowClass
                Suite       = [string[]]@($rowSuite.ToArray())
                Gate        = [string[]]@($rowGate.ToArray())
                Reason      = $rowReason
                IsCompanion = $rowCompanion
            })
    }

    # Лише похідний супутник без жодного змісту - не план.
    if (@($rows | Where-Object { -not $_.IsCompanion }).Count -eq 0) {
        foreach ($row in $rows) {
            if ($row.IsCompanion) {
                $row.Class = 'V3'
                $row.IsCompanion = $false
                $row.Reason = 'маніфест без жодного іншого шляху - зміст змін не визначено'
            }
        }
    }

    $rank = @{ 'V1' = 1; 'V2' = 2; 'V3' = 3 }
    $planClass = 'V1'
    foreach ($row in $rows) {
        if ($rank[$row.Class] -gt $rank[$planClass]) { $planClass = $row.Class }
    }

    $suiteSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $gateSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($row in $rows) {
        foreach ($rowSuiteName in @($row.Suite)) { [void]$suiteSet.Add([string]$rowSuiteName) }
        foreach ($rowGateName in @($row.Gate)) { [void]$gateSet.Add([string]$rowGateName) }
    }
    $planSuite = @()
    if ($planClass -ne 'V3') {
        [void]$suiteSet.Add('Governance')
        $planSuite = @($catalog | Where-Object { $suiteSet.Contains([string]$_) })
    }
    $planGate = @($gateOrder | Where-Object { $gateSet.Contains([string]$_) })
    $unknown = @($rows | Where-Object { $_.Class -eq 'V3' } | ForEach-Object { [string]$_.Path })

    $decision = @($rows | ForEach-Object {
            [pscustomobject]@{
                Path   = $_.Path
                Class  = $_.Class
                Suite  = [string[]]@($_.Suite)
                Reason = $_.Reason
            }
        })
    return [pscustomobject]@{
        Status                    = 'Planned'
        Class                     = $planClass
        ClassLabel                = $classLabel
        Suite                     = [string[]]@($planSuite)
        RequiredGate              = [string[]]@($planGate)
        RequiresIndependentReview = ($planClass -eq 'V3')
        UnknownPath               = [string[]]@($unknown)
        Decision                  = [object[]]@($decision)
        IsAcceptanceEvidence      = $false
    }
}
