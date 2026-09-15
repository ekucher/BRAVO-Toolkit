Set-StrictMode -Version 2.0

# BRAVO.Configuration.Schema — формальна схема Configuration v2 (#154, B2).
#
# ЩО ЦЕ. Машинно перевірювана декларація ФОРМИ канонічної конфігурації:
# для кожного dot-шляху — його рід (Node/Boolean/String/Number/Array),
# рід елементів масиву й допустимість $null. На її основі
# Test-BRAVOConfigurationOverrideSchema перевіряє ТИПИ значень, які
# site-шар (BRAVO.local.config) намагається перевизначити, і відхиляє
# невідповідність fail-closed, називаючи точний шлях.
#
# ЧОМУ СХЕМА ВИВОДИТЬСЯ, А НЕ ПЕРЕПИСУЄТЬСЯ РУКАМИ. Друга рукописна
# копія 271 листа канонічних дефолтів розійшлася б із
# Get-BRAVODefaultConfiguration при першій же зміні, і розійшлася б
# МОВЧКИ. Тому форма береться з самого канонічного графа, а руками
# задано рівно те, чого з дефолту вивести НЕМОЖЛИВО:
#
#   - лист, чий дефолт $null      -> рід з таблиці нижче + Nullable;
#   - лист, чий дефолт @()        -> рід елементів з таблиці нижче.
#
# Будь-який інший невизначений лист — ПОМИЛКА побудови схеми, а не
# мовчазний пропуск: новий $null-дефолт без запису в таблиці одразу
# валить Schema/*-перевірки, замість того щоб тихо лишитись без типу.
# Це і є "обов'язковість" у термінах B2: схема мусить покривати кожен
# канонічний лист.
#
# ЧОГО ЦЕЙ МОДУЛЬ НАВМИСНО НЕ ВОЛОДІЄ (щоб не з'явилась друга копія
# політики):
#
#   - невідомий top-level ключ і невідомий БАТЬКІВСЬКИЙ вузол —
#     ConvertTo-BRAVONestedOverride (BRAVO.Configuration.psm1) вже
#     відхиляє їх fail-closed; тут такі шляхи просто не перевіряються
#     на тип, бо перевіряти немає проти чого;
#   - невідомий КІНЦЕВИЙ сегмент (leaf) — рішення власника D3
#     (2026-09-14): приймається + попередження + метадані. Цей модуль
#     його НЕ відхиляє й НЕ дублює облік (сток веде
#     ConvertTo-BRAVONestedOverride, #154 A2);
#   - діапазони, переліки допустимих значень і семантика шляхів
#     (BootRestoreMode, WeeklyOn, BusyWaitMinutes, BISSourcePath,
#     backupConsistency.Mode тощо) — у них уже є канонічні власники
#     (Assert-BravoLoadedConfiguration, Test-BRAVOEffectiveSecurityInvariants,
#     каталог BRAVO.Configurator.Schema.psd1). Копія тих правил тут була б
#     дубльованою політикою, а переведення їхнього нинішнього
#     "попередження + безпечний дефолт" у fail-closed — зміною поведінки
#     поза обсягом B2. Замість копії є механічний guard self-test-у, що
#     звіряє РОДИ задокументованого каталогу Configurator-а зі схемою.

# ПРО [AllowEmptyCollection()] НА ОБОВ'ЯЗКОВИХ ПАРАМЕТРАХ НИЖЧЕ.
# Windows PowerShell відхиляє ПОРОЖНЮ колекцію, передану в обов'язковий
# параметр, тим самим неявним контролем, що й $null та порожній рядок:
# "Cannot bind argument to parameter 'X' because it is an empty
# collection" (інцидент CI 2026-09-15). Для цього модуля порожня колекція
# — штатне значення, а не помилка: порожній перелік порушень на валідній
# конфігурації, дефолт-масив @() (Limits.ExcludedDrives) і щойно створена
# схема @{} на початку побудови. Тому кожен обов'язковий параметр, який
# може отримати колекцію, явно її дозволяє. Це НЕ послаблення перевірки:
# самі значення далі перевіряються кодом функцій, а не прив'язкою.

# Ліміт глибини: канонічний граф має щонайбільше 3 рівні; ліміт існує
# лише щоб патологічно вкладений вхід давав зрозумілу відмову, а не
# переповнення стека.
$script:BRAVOConfigurationSchemaMaximumDepth = 16

# Повний перелік числових System.TypeCode. Boolean/Char/DateTime/String
# сюди свідомо не входять: у .NET вони мають власні TypeCode й числами
# у контракті конфігурації не є.
$script:BRAVOConfigurationSchemaNumericTypeCode = @(
    'SByte', 'Byte', 'Int16', 'UInt16', 'Int32', 'UInt32',
    'Int64', 'UInt64', 'Single', 'Double', 'Decimal'
)

# Листи, чий рід НЕМОЖЛИВО вивести з канонічного дефолту.
# Кожен запис мусить відповідати реальному листу канонічного графа —
# зайвий запис ловить Schema/CoversEveryCanonicalLeaf.
$script:BRAVOConfigurationSchemaUndeterminedLeaf = @{
    # discoverySettings.*: дефолт $null = "покластись на auto-discovery"
    # (#158, етап 4). Порожній рядок означає те саме, тому рід String, а
    # $null лишається допустимим значенням, а не помилкою типу.
    'discoverySettings.BravoIniPath'        = @{ Kind = 'String'; Nullable = $true }
    'discoverySettings.BravoRoot'           = @{ Kind = 'String'; Nullable = $true }
    'discoverySettings.WebRoot'             = @{ Kind = 'String'; Nullable = $true }
    'discoverySettings.Sources.MODEL'       = @{ Kind = 'String'; Nullable = $true }
    'discoverySettings.Sources.BLOG'        = @{ Kind = 'String'; Nullable = $true }
    'discoverySettings.Sources.BRAVOEXCH'   = @{ Kind = 'String'; Nullable = $true }
    'discoverySettings.Sources.BAZA_APP'    = @{ Kind = 'String'; Nullable = $true }
    'discoverySettings.Sources.BAZA_WWW'    = @{ Kind = 'String'; Nullable = $true }
    'discoverySettings.Sources.BACKUP_ROOT' = @{ Kind = 'String'; Nullable = $true }

    # Дефолт @() (канонічно порожній перелік виключених дисків) не несе
    # жодного елемента, з якого можна вивести рід.
    'maintenanceSettings.Limits.ExcludedDrives' = @{ Kind = 'Array'; ElementKind = 'String' }
}

function Get-BRAVOConfigurationSchemaValueKind {
    # Рід ЗНАЧЕННЯ (не схеми). Порядок перевірок значущий:
    #   - [string] перевіряється ДО IEnumerable, інакше рядок став би
    #     масивом своїх символів;
    #   - [hashtable]/IDictionary — ДО IEnumerable з тієї самої причини;
    #   - [bool] — ДО числових: у .NET це не число, але явна перевірка
    #     робить намір видимим і не залежить від порядку нижче.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Value)

    if ($null -eq $Value) { return 'Undetermined' }
    if ($Value -is [bool]) { return 'Boolean' }
    if ($Value -is [string]) { return 'String' }
    if ($Value -is [System.Collections.IDictionary]) { return 'Node' }
    # Числові типи — через TypeCode, а НЕ через ланцюг `-is [accelerator]`.
    # Причина емпірична (CI 2026-09-15): `[short]` не є прискорювачем типу
    # у Windows PowerShell 5.1 (з'явився лише в PowerShell 6+), тому
    # обчислення такого операнда кидає "Unable to find type [short]". У
    # ланцюзі `-or` це виглядає безпечно рівно доти, доки якийсь ранній
    # операнд істинний і ланцюг замикається достроково — а на першому ж
    # НЕчисловому значенні обчислюються всі, і схема падає цілком.
    # TypeCode покриває той самий набір типів, не залежить від таблиці
    # прискорювачів конкретної версії й тому не має цього класу відмови.
    $valueTypeCode = [string][System.Type]::GetTypeCode($Value.GetType())
    if ($script:BRAVOConfigurationSchemaNumericTypeCode -contains $valueTypeCode) {
        return 'Number'
    }
    if ($Value -is [System.Collections.IEnumerable]) { return 'Array' }
    return 'Unsupported'
}

function Get-BRAVOConfigurationSchemaKindCaption {
    # Операторський підпис роду для повідомлення про помилку.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Kind)

    switch ($Kind) {
        'Boolean' { return 'логічне значення ($true/$false)' }
        'String'  { return 'рядок' }
        'Number'  { return 'числове значення' }
        'Array'   { return 'масив' }
        'Node'    { return 'вкладена hashtable' }
        default   { return $Kind }
    }
}

function Get-BRAVOConfigurationSchemaValueCaption {
    # Фактичне значення у повідомленні: тип .NET + обрізаний текст.
    # Без тексту оператор не бачить, ЩО саме він написав; без обрізання
    # довгий масив зробив би повідомлення нечитабельним.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Value)

    if ($null -eq $Value) { return '$null' }
    $text = ''
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Value) {
            if ($null -eq $item) { [void]$items.Add('$null') } else { [void]$items.Add([string]$item) }
        }
        $text = $items -join ', '
    } else {
        $text = [string]$Value
    }
    if ($text.Length -gt 80) { $text = $text.Substring(0, 77) + '...' }
    return "$($Value.GetType().Name) ('$text')"
}

function Add-BRAVOConfigurationSchemaLeaf {
    # Рекурсивний будівник схеми. Мутує передану hashtable $Schema —
    # повертати граф через pipeline не можна: PowerShell 5.1 розгорнув би
    # проміжні колекції (.claude/rules/powershell.md).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Node,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$Schema,
        [Parameter(Mandatory = $true)][int]$Depth
    )

    if ($Depth -gt $script:BRAVOConfigurationSchemaMaximumDepth) {
        throw "Схема конфігурації: перевищено дозволену глибину вкладеності ($script:BRAVOConfigurationSchemaMaximumDepth) на шляху '$Path'."
    }

    $kind = Get-BRAVOConfigurationSchemaValueKind -Value $Node

    if ($kind -eq 'Node') {
        if ($Path -ne '') {
            $Schema[$Path] = [pscustomobject]@{
                Path        = $Path
                Kind        = 'Node'
                ElementKind = ''
                Nullable    = $false
            }
        }
        foreach ($childKey in @($Node.Keys)) {
            $childPath = if ($Path -eq '') { [string]$childKey } else { "$Path.$childKey" }
            Add-BRAVOConfigurationSchemaLeaf -Node $Node[$childKey] -Path $childPath -Schema $Schema -Depth ($Depth + 1)
        }
        return
    }

    if ($Path -eq '') {
        throw "Схема конфігурації: корінь канонічної конфігурації мусить бути hashtable (отримано рід '$kind')."
    }

    $undetermined = $null
    if ($script:BRAVOConfigurationSchemaUndeterminedLeaf.Contains($Path)) {
        $undetermined = $script:BRAVOConfigurationSchemaUndeterminedLeaf[$Path]
    }

    if ($kind -eq 'Undetermined') {
        # Дефолт $null: рід мусить бути заданий явно, інакше лист лишився
        # б без типу — мовчазна діра в схемі.
        if ($null -eq $undetermined) {
            throw "Схема конфігурації: лист '$Path' має дефолт `$null, тому його рід неможливо вивести — додайте запис у `$script:BRAVOConfigurationSchemaUndeterminedLeaf."
        }
        $undeterminedElementKind = ''
        if ($undetermined.Contains('ElementKind')) { $undeterminedElementKind = [string]$undetermined['ElementKind'] }
        $Schema[$Path] = [pscustomobject]@{
            Path        = $Path
            Kind        = [string]$undetermined['Kind']
            ElementKind = $undeterminedElementKind
            Nullable    = $true
        }
        return
    }

    if ($kind -eq 'Array') {
        $elementKinds = New-Object System.Collections.Generic.List[string]
        foreach ($element in $Node) {
            $elementKind = Get-BRAVOConfigurationSchemaValueKind -Value $element
            if (-not $elementKinds.Contains($elementKind)) { [void]$elementKinds.Add($elementKind) }
        }
        $resolvedElementKind = ''
        if ($elementKinds.Count -eq 1) {
            $resolvedElementKind = $elementKinds[0]
        } elseif ($elementKinds.Count -gt 1) {
            # Змішаного масиву в канонічних дефолтах сьогодні немає;
            # 'Any' означає "елементи не перевіряються" і ловиться
            # механічною перевіркою повноти схеми в self-test.
            $resolvedElementKind = 'Any'
        }
        if ([string]::IsNullOrEmpty($resolvedElementKind) -or $resolvedElementKind -eq 'Undetermined') {
            if ($null -eq $undetermined -or -not $undetermined.Contains('ElementKind')) {
                throw "Схема конфігурації: лист '$Path' має дефолт-масив без елементів, з яких можна вивести рід — додайте ElementKind у `$script:BRAVOConfigurationSchemaUndeterminedLeaf."
            }
            $resolvedElementKind = [string]$undetermined['ElementKind']
        }
        $Schema[$Path] = [pscustomobject]@{
            Path        = $Path
            Kind        = 'Array'
            ElementKind = $resolvedElementKind
            Nullable    = $false
        }
        return
    }

    if ($kind -eq 'Unsupported') {
        throw "Схема конфігурації: лист '$Path' має значення непідтримуваного роду ($($Node.GetType().FullName))."
    }

    $Schema[$Path] = [pscustomobject]@{
        Path        = $Path
        Kind        = $kind
        ElementKind = ''
        Nullable    = ($null -ne $undetermined -and $undetermined.Contains('Nullable') -and [bool]$undetermined['Nullable'])
    }
}

function Get-BRAVOConfigurationSchema {
    <#
    .SYNOPSIS
        Формальна схема Configuration v2, виведена з канонічної
        конфігурації (#154, B2).
    .DESCRIPTION
        Повертає hashtable "dot-шлях -> дескриптор". Дескриптор:
            Path        — той самий dot-шлях;
            Kind        — Node | Boolean | String | Number | Array;
            ElementKind — рід елементів (лише для Kind = 'Array');
            Nullable    — чи допустиме значення $null.
        Ключі регістронезалежні — як і в будь-якій hashtable PowerShell,
        тобто так само, як ключі самої конфігурації.
    .PARAMETER ReferenceConfiguration
        Канонічний граф (типово Get-BRAVODefaultConfiguration).
        Передається ПАРАМЕТРОМ, а не читається всередині модуля: цей
        модуль не мусить залежати від BRAVO.Configuration, а self-test
        має змогу побудувати схему з підставленого графа.
    .OUTPUTS
        [hashtable]
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$ReferenceConfiguration
    )

    $schema = @{}
    Add-BRAVOConfigurationSchemaLeaf -Node $ReferenceConfiguration -Path '' -Schema $schema -Depth 0
    return $schema
}

function Add-BRAVOConfigurationSchemaViolation {
    # Перевіряє ОДНЕ значення проти дескриптора; знайдені порушення
    # додає у передану колекцію (та сама причина, що й у будівника
    # схеми: повернення колекції через pipeline розгорталось би).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Descriptor,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$Schema,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Violations,
        [Parameter(Mandatory = $true)][int]$Depth
    )

    $expectedKind = [string]$Descriptor.Kind
    $expectedCaption = Get-BRAVOConfigurationSchemaKindCaption -Kind $expectedKind

    if ($null -eq $Value) {
        if ([bool]$Descriptor.Nullable) { return }
        [void]$Violations.Add([pscustomobject]@{
            Path     = $Path
            Expected = $expectedKind
            Actual   = 'Null'
            Message  = "${Path}: очікується $expectedCaption, отримано `$null."
        })
        return
    }

    $actualKind = Get-BRAVOConfigurationSchemaValueKind -Value $Value

    if ($expectedKind -eq 'Node') {
        if ($actualKind -ne 'Node') {
            [void]$Violations.Add([pscustomobject]@{
                Path     = $Path
                Expected = $expectedKind
                Actual   = $actualKind
                Message  = "${Path}: очікується $expectedCaption, отримано $(Get-BRAVOConfigurationSchemaValueCaption -Value $Value)."
            })
            return
        }
        if ($Depth -ge $script:BRAVOConfigurationSchemaMaximumDepth) { return }
        foreach ($childKey in @($Value.Keys)) {
            $childPath = "$Path.$childKey"
            # Невідомий ключ усередині вузла-override — це той самий
            # невідомий leaf: рішення D3 лишає його прийнятним, тож тут
            # лише пропуск, без власної політики.
            if (-not $Schema.Contains($childPath)) { continue }
            Add-BRAVOConfigurationSchemaViolation -Descriptor $Schema[$childPath] -Value $Value[$childKey] `
                -Path $childPath -Schema $Schema -Violations $Violations -Depth ($Depth + 1)
        }
        return
    }

    if ($expectedKind -eq 'Array') {
        if ($actualKind -ne 'Array') {
            [void]$Violations.Add([pscustomobject]@{
                Path     = $Path
                Expected = $expectedKind
                Actual   = $actualKind
                Message  = "${Path}: очікується $expectedCaption, отримано $(Get-BRAVOConfigurationSchemaValueCaption -Value $Value)."
            })
            return
        }
        $expectedElementKind = [string]$Descriptor.ElementKind
        if ([string]::IsNullOrEmpty($expectedElementKind) -or $expectedElementKind -eq 'Any') { return }
        $expectedElementCaption = Get-BRAVOConfigurationSchemaKindCaption -Kind $expectedElementKind
        $elementIndex = 0
        foreach ($element in $Value) {
            $elementKind = Get-BRAVOConfigurationSchemaValueKind -Value $element
            if ($elementKind -ne $expectedElementKind) {
                # '{0}[{1}]' через -f, а не інтерполяція: "$Path[$i]" у
                # рядку читається неоднозначно, а -f лишає намір явним.
                $elementPath = '{0}[{1}]' -f $Path, $elementIndex
                [void]$Violations.Add([pscustomobject]@{
                    Path     = $elementPath
                    Expected = $expectedElementKind
                    Actual   = $elementKind
                    Message  = "${elementPath}: очікується $expectedElementCaption, отримано $(Get-BRAVOConfigurationSchemaValueCaption -Value $element)."
                })
            }
            $elementIndex++
        }
        return
    }

    if ($actualKind -ne $expectedKind) {
        [void]$Violations.Add([pscustomobject]@{
            Path     = $Path
            Expected = $expectedKind
            Actual   = $actualKind
            Message  = "${Path}: очікується $expectedCaption, отримано $(Get-BRAVOConfigurationSchemaValueCaption -Value $Value)."
        })
    }
}

function Test-BRAVOConfigurationOverrideSchema {
    <#
    .SYNOPSIS
        Перевіряє ТИПИ значень плаского dot-path шару перевизначень
        проти схеми v2 (#154, B2).
    .DESCRIPTION
        Перевіряються ЛИШЕ шляхи, відомі схемі. Шлях, якого в схемі
        немає, тут мовчки пропускається — і це не послаблення:
        невідомий top-level/батьківський вузол уже відхиляє
        ConvertTo-BRAVONestedOverride fail-closed, а невідомий кінцевий
        сегмент навмисно приймається (рішення власника D3) і
        обліковується власним стоком. Друга реалізація тих самих правил
        тут створила б дубльовану політику.
    .PARAMETER DotPathOverrides
        Плаский шар "dot-шлях -> значення" (формат BRAVO.local.config).
    .PARAMETER Schema
        Результат Get-BRAVOConfigurationSchema.
    .OUTPUTS
        [pscustomobject] { IsValid; Violations }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$DotPathOverrides,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$Schema
    )

    $violations = New-Object System.Collections.Generic.List[object]

    foreach ($dotPath in @($DotPathOverrides.Keys)) {
        $path = [string]$dotPath
        # Порожній ключ — контракт читача site-файлу
        # (Read-BRAVOLocalConfigurationOverrides), не схеми.
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not $Schema.Contains($path)) { continue }
        Add-BRAVOConfigurationSchemaViolation -Descriptor $Schema[$path] -Value $DotPathOverrides[$dotPath] `
            -Path $path -Schema $Schema -Violations $violations -Depth 0
    }

    return [pscustomobject]@{
        IsValid    = ($violations.Count -eq 0)
        Violations = $violations.ToArray()
    }
}


# ---------------------------------------------------------------------
# Контракт версії схеми site-файлу (#154, B3)
# ---------------------------------------------------------------------
# УВАГА: це НЕ те саме, що VERSION.json.configSchemaVersion. Там —
# версія схеми САМОГО КОМПЛЕКТУ (метадані релізу, споживач —
# BRAVO_CONFIG_TEST.ps1). Тут — версія формату, яку ОГОЛОШУЄ конкретний
# BRAVO.local.config. Значення збігаються за назвою ключа навмисно
# (один семантичний ідентифікатор формату), але це два різні носії, і
# B3 не змінює VERSION.json: зміна метаданих релізу разом зі зміною
# runtime-поведінки заборонена політикою релізу.
#
# Маркер — ЗАРЕЗЕРВОВАНИЙ ключ, а не перевизначення. Site-файл є плоским
# словником 'dot.path' = значення, тож 'configSchemaVersion' був би
# односегментним, тобто TOP-LEVEL шляхом — і ConvertTo-BRAVONestedOverride
# відхилив би його як невідомий ключ (fail-closed). Тому канонічний читач
# знімає маркер ДО валідації шляхів, і жоден споживач .Overrides його не
# бачить.
$script:BRAVOConfigurationSchemaVersionKey = 'configSchemaVersion'

# Версія, яку пише поточний комплект.
$script:BRAVOConfigurationSchemaCurrentVersion = 2

# Версія, яку означає ВІДСУТНІЙ маркер. Кожен розгорнутий сьогодні
# site-файл не має маркера взагалі, тому "немає маркера" не може
# означати відмову: це зупинило б увесь парк на першому ж оновленні.
$script:BRAVOConfigurationSchemaLegacyVersion = 1

# Підтримувані оголошені версії. Будь-яке інше число — fail closed:
# файл, написаний новішим комплектом, НЕ можна читати як v2 "на удачу".
$script:BRAVOConfigurationSchemaSupportedVersion = @(1, 2)

# Цілочисельні System.TypeCode — маркер версії мусить бути цілим числом,
# а не рядком '2' і не $true (та сама причина, що для решти типів: див.
# коментар про TypeCode вище).
$script:BRAVOConfigurationSchemaIntegerTypeCode = @(
    'SByte', 'Byte', 'Int16', 'UInt16', 'Int32', 'UInt32', 'Int64', 'UInt64'
)

function Get-BRAVOConfigurationSchemaVersionContract {
    <#
    .SYNOPSIS
        Канонічний контракт версії схеми site-файлу (#154, B3).
    .DESCRIPTION
        Один опис для ВСІХ учасників: канонічний читач, який знімає
        маркер, і серіалізатори Configurator-а, які його пишуть. Без
        цього спільного джерела назва ключа й поточна версія існували б
        у трьох місцях і розійшлися б при першій зміні.
    .OUTPUTS
        [pscustomobject] { KeyName; CurrentVersion; LegacyVersion; SupportedVersions }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    return [pscustomobject]@{
        KeyName           = $script:BRAVOConfigurationSchemaVersionKey
        CurrentVersion    = $script:BRAVOConfigurationSchemaCurrentVersion
        LegacyVersion     = $script:BRAVOConfigurationSchemaLegacyVersion
        SupportedVersions = @($script:BRAVOConfigurationSchemaSupportedVersion)
    }
}

function Resolve-BRAVOConfigurationSchemaVersion {
    <#
    .SYNOPSIS
        Знімає й перевіряє маркер версії site-файлу (#154, B3).
    .DESCRIPTION
        Вхід — уже вилучені ДАНІ (результат
        ConvertFrom-BRAVOConfigurationDataFileText), тому версія
        читається з даних і НІКОЛИ не обчислюється виконанням файлу:
        'configSchemaVersion = 1 + 1' не стає двійкою, а відхиляється ще
        парсером як вираз.

        Матриця (обсяг B3):
            маркер відсутній              -> v1 (legacy), приймається
            маркер = 1                    -> v1, приймається
            маркер = 2                    -> v2, приймається
            маркер іншого числа           -> FAIL CLOSED
            маркер нецілого типу/$null    -> FAIL CLOSED

        Рівно ОДИН вихід несе і версію, і очищені перевизначення: якби
        зняття маркера лишилось на викликачеві, кожен із п'яти
        споживачів канонічного читача мусив би повторити це правило.
    .OUTPUTS
        [pscustomobject] { DeclaredVersion; EffectiveVersion; WasDeclared; Overrides }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$DataFileContent,
        [Parameter(Mandatory = $true)][string]$SourceName
    )

    $keyName = $script:BRAVOConfigurationSchemaVersionKey
    $overrides = @{}
    $wasDeclared = $false
    $declaredRaw = $null

    foreach ($contentKey in @($DataFileContent.Keys)) {
        if ([string]::Equals([string]$contentKey, $keyName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $wasDeclared = $true
            $declaredRaw = $DataFileContent[$contentKey]
            continue
        }
        $overrides[$contentKey] = $DataFileContent[$contentKey]
    }

    if (-not $wasDeclared) {
        return [pscustomobject]@{
            DeclaredVersion  = $null
            EffectiveVersion = $script:BRAVOConfigurationSchemaLegacyVersion
            WasDeclared      = $false
            Overrides        = $overrides
        }
    }

    if ($null -eq $declaredRaw) {
        throw "'$SourceName': '$keyName' не може бути `$null — очікується ціле число (підтримуються: $($script:BRAVOConfigurationSchemaSupportedVersion -join ', '))."
    }

    $declaredTypeCode = [string][System.Type]::GetTypeCode($declaredRaw.GetType())
    if (-not ($script:BRAVOConfigurationSchemaIntegerTypeCode -contains $declaredTypeCode)) {
        throw "'$SourceName': '$keyName' мусить бути цілим числом без лапок, отримано $($declaredRaw.GetType().Name) ('$declaredRaw'). Рядок '2' і `$true не є версією схеми."
    }

    $declaredVersion = [int]$declaredRaw
    if (-not ($script:BRAVOConfigurationSchemaSupportedVersion -contains $declaredVersion)) {
        throw "'$SourceName': '$keyName' = $declaredVersion не підтримується цим комплектом (підтримуються: $($script:BRAVOConfigurationSchemaSupportedVersion -join ', ')). Файл новішого формату НЕ читається як старіший — оновіть комплект."
    }

    return [pscustomobject]@{
        DeclaredVersion  = $declaredVersion
        EffectiveVersion = $declaredVersion
        WasDeclared      = $true
        Overrides        = $overrides
    }
}


function Get-BRAVOConfigurationSchemaVersionDeclarationLine {
    <#
    .SYNOPSIS
        Канонічна серіалізована форма маркера версії (#154, B3).
    .DESCRIPTION
        Рівно один запис: `configSchemaVersion = 2` (bareword-ключ і знак
        рівності). Форма з двокрапкою не є валідним PowerShell-DATA
        синтаксисом і тому не емітується ніколи; bareword навмисно
        відрізняє маркер від перевизначень, які завжди беруться в лапки
        як 'dot.path'.

        Функція живе тут, а не в серіалізаторах Configurator-а, бо
        серіалізаторів ДВА (production-запис і кандидат для ізольованого
        обчислення effective), і копія форми в кожному розійшлася б.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$IndentWidth = 4)

    $indent = ''
    if ($IndentWidth -gt 0) { $indent = ' ' * $IndentWidth }
    return "$indent$($script:BRAVOConfigurationSchemaVersionKey) = $($script:BRAVOConfigurationSchemaCurrentVersion)"
}

Export-ModuleMember -Function @(
    'Get-BRAVOConfigurationSchema',
    'Test-BRAVOConfigurationOverrideSchema',
    'Get-BRAVOConfigurationSchemaVersionContract',
    'Resolve-BRAVOConfigurationSchemaVersion',
    'Get-BRAVOConfigurationSchemaVersionDeclarationLine'
)
