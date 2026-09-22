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

# =========================================================================
# Wave 2 (#216): авторизація local-override шляхів BRAVO.local.config.
# =========================================================================
#
# ЩО ЦЕ. Test-BRAVOConfigurationOverrideSchema (вище) перевіряє лише ТИП
# значення. Wave 2 додає ОРТОГОНАЛЬНИЙ шар: чи МАЄ BRAVO.local.config
# ПРАВО перевизначати конкретний лист узагалі, незалежно від того,
# наскільки правильне запропоноване значення. Контракт (owner-approved,
# WAVE2-CONTRACT.md, 2026-09-21) класифікує кожен із 271 канонічних
# листів в один із семи класів:
#
#   ALLOW_SITE             — звичайне site-значення, без обмежень.
#   ALLOW_WITH_VALIDATOR   — дозволено, але семантично обмежене (Enum,
#                            діапазон, формат) — Validator називає
#                            конкретний іменований валідатор нижче.
#   DENY_DERIVED            — значення обчислюється похідною логікою;
#                            local-override сюди ніколи не гарантовано
#                            узгоджено застосується.
#   DENY_CREDENTIAL_BACKED  — ніс би сам секрет (сьогодні 0 листів; клас
#                            зарезервований на майбутнє).
#   DENY_SECURITY_CONTROL   — security-critical перемикач.
#   DENY_EXECUTION_CONTROL  — керує тим, ЩО/ЯК/ПІД КИМ виконується
#                            (шлях виконуваного файлу, аргументи
#                            командного рядка, ідентичність служби/задачі).
#   DENY_INTERNAL_METADATA  — внутрішній контракт формату (glob/ordinal/
#                            timestamp), на який покладаються кілька
#                            підсистем незалежно від оператора.
#
# ЧОМУ ОКРЕМИЙ ШАР, А НЕ РОЗШИРЕННЯ ТИПОВОЇ ПЕРЕВІРКИ. Правильний ТИП
# значення (String/Number/...) нічого не каже про те, чи ЦЕЙ шлях
# узагалі дозволено перевизначати з site-шару — 05-architecture.md
# вимагає одного канонічного власника на відповідальність, тому
# авторизація живе тут (поруч зі схемою форми), а не дублюється в
# BRAVO_CONFIG_LOADER.ps1 чи Configurator-і.
#
# ДЖЕРЕЛО КЛАСИФІКАЦІЇ. "WAVE2-CONTRACT.md", згаданий у коментарях
# нижче й посилання на нього нижче за текстом — це ЗОВНІШНІЙ,
# попередньо узгоджений з власником планувальний документ (Issue #216,
# Wave 2), який навмисно НЕ закомічений у це дерево коду (аналогічно
# іншим planning/acceptance-артефактам, що не належать до runtime).
# Він є джерелом 271-позиційного переліку й per-класового обґрунтування
# нижче; сам реєстр і self-test-покриття (селф-тест-файли
# Configuration/ConfigLoader/Configurator) — це відтворювана,
# перевірювана В РЕПОЗИТОРІЇ форма цього рішення.
#
# МЕЖА З D3 (unknown-leaf accept+warn, рішення власника 2026-09-14).
# Авторизаційний реєстр нижче — це той самий периметр, що вже перевіряє
# Test-BRAVOConfigurationOverrideSchema: КОЖЕН шлях спершу проходить
# через $Schema.Contains($path) (див. Test-BRAVOConfigurationOverrideAuthorization
# нижче) — шлях, якого немає в канонічній схемі, НЕ класифікується тут
# узагалі й проходить повз цей шар так само, як повз type-перевірку.
# Це свідоме узгодження з D3, не недогляд (WAVE2-CONTRACT.md, розділ 5/11.3).
#
# ФОРМАТ РЕЄСТРУ. Явний запис на КОЖЕН із 271 канонічних листів (а не
# лише на DENY/VALIDATOR-підмножину) — навмисно: WAVE2-CONTRACT.md
# (розділ 8/11.3) вимагає, щоб кожен НОВИЙ канонічний лист отримував
# явне класифікаційне рішення (навіть якщо це явний ALLOW_SITE), а не
# мовчазний allow-by-omission. Повнота реєстру перевіряється в
# selftest\BRAVO_SELF_TEST.Configuration.ps1 (перевірка "271/271
# coverage" — фейлить, якщо реєстр і канонічна схема розійшлися в
# обидва боки: зайвий запис АБО відсутній запис); у цьому модулі немає
# окремої функції з такою назвою.
#
# WEAKENINGOVERRIDE (owner remediation, Issue #216 Wave 2 — усунення
# дублювання політики). ДО цього поля BRAVO_CONFIG_LOADER.ps1 містив
# власний, жорстко закодований перелік dot-шляхів (BAZA.Mode/
# MutationPolicy), які виключені з BRAVO_ALLOW_WEAKENED_SECURITY-обходу
# — друга, окрема копія авторизаційної політики поза канонічним
# реєстром (ризик розбіжності). WeakeningOverride переносить ЦЕ рішення
# в canonical реєстр — loader питає РЕЗУЛЬТАТ (Violation.WeakeningOverride),
# а не порівнює dot-шлях.
#
#   None                        — DENY_*-порушення на цьому листі НІКОЛИ
#                                  не може використати наявний
#                                  BRAVO_ALLOW_WEAKENED_SECURITY-механізм
#                                  (fail closed за замовчуванням — див.
#                                  нижче).
#   ExistingSecurityEscapeHatch — DENY_SECURITY_CONTROL-порушення на
#                                  цьому листі МОЖЕ пройти через наявний
#                                  BRAVO_ALLOW_WEAKENED_SECURITY=1
#                                  оператора-контракт (той самий
#                                  механізм, що вже застосовує
#                                  Test-BRAVOEffectiveSecurityInvariants
#                                  до backupConsistency.Mode/
#                                  toolIntegritySettings.Mode) — НЕ новий
#                                  bypass, лише перенесення РІШЕННЯ "хто
#                                  може використати наявний механізм" у
#                                  канонічний реєстр.
#
# FAIL-CLOSED ЗА ЗАМОВЧУВАННЯМ: явна відсутність ключа WeakeningOverride
# у записі реєстру трактується як 'None' (Get-BRAVOConfigurationSchemaAuthorizationClass
# і Test-BRAVOConfigurationOverrideAuthorization нижче обидва
# застосовують цей дефолт explicit) — тому кожен МАЙБУТНІЙ DENY_*-лист,
# доданий у реєстр без явного WeakeningOverride, автоматично НЕ може
# використати обхід, а не мовчки успадковує його.
#
# Сьогодні рівно ОДИН лист має ExistingSecurityEscapeHatch:
# requireAdministrator (Wave 1 — наявна, свідомо збережена поведінка).
# backupMonitoring.SFTP.BAZA.Mode/.MutationPolicy НЕ отримують цього
# ключа — DENY_SECURITY_CONTROL + відсутній WeakeningOverride = 'None' =
# безумовна відмова незалежно від BRAVO_ALLOW_WEAKENED_SECURITY.
$script:BRAVOConfigurationSchemaWeakeningOverrideNone = 'None'
$script:BRAVOConfigurationSchemaWeakeningOverrideExistingEscapeHatch = 'ExistingSecurityEscapeHatch'
$script:BRAVOConfigurationSchemaValidWeakeningOverrides = @(
    $script:BRAVOConfigurationSchemaWeakeningOverrideNone,
    $script:BRAVOConfigurationSchemaWeakeningOverrideExistingEscapeHatch
)

$script:BRAVOConfigurationSchemaAuthorizationClass = @{
    'archiveFileFilter' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'archiveParams' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'archiveRetentionDays' = @{ Class = 'ALLOW_SITE' }
    'archiveTimestampFormat' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'backupConsistency.Mode' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'Enum:VSS,Direct' }
    'backupConsistency.SnapshotContext' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'Enum:ClientAccessible' }
    'backupMonitoring.CandidateLimit' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.CheckManagedServices' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.Enabled' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.LogFileNameTemplate' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.MaxBackupAgeHours' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.NotifyOnSuccessAfterBackup' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.RepeatAlertAfterHours' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.RunAfterBackup' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.BAZA.AutoArchiveMutationThreshold' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.BAZA.FastHealthEnabled' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.BAZA.FullAuditEnabled' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.BAZA.FullAuditEveryDays' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.BAZA.Mode' = @{ Class = 'DENY_SECURITY_CONTROL' }
    'backupMonitoring.SFTP.BAZA.MutationPolicy' = @{ Class = 'DENY_SECURITY_CONTROL' }
    'backupMonitoring.SFTP.BAZA.SynchronizeBeforeHealth' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.BAZAPendingAlertAfterHours' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.BAZAPreviewOptions' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'backupMonitoring.SFTP.CheckArchiveUploads' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.CheckBAZASynchronization' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.DifferenceDetailLimit' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.Enabled' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.OperationTimeoutSeconds' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.RemoteBackupMaxAgeHours' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.RequireServerSideArchiveHash' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.SynchronizationTimeoutSeconds' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SFTP.VerifyRemoteArchiveHash' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SizeSanity.Enabled' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SizeSanity.HistoryCount' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SizeSanity.MaxSizeDropPercent' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SizeSanity.MinimumBytes' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SMB.CheckArchiveCopies' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SMB.Enabled' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SMB.RemoteBackupMaxAgeHours' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SMB.VerifyRemoteArchiveHash' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.SuccessDedupMinutes' = @{ Class = 'ALLOW_SITE' }
    'backupMonitoring.VerifyFileHash' = @{ Class = 'ALLOW_SITE' }
    'bravoSettings.ArchivePrefix' = @{ Class = 'ALLOW_SITE' }
    'bravoSettings.InstitutionCode' = @{ Class = 'ALLOW_SITE' }
    'bravoSettings.InstitutionName' = @{ Class = 'ALLOW_SITE' }
    # PR #224 review, F3 + R3-5 + P2 (defaultLogLevel): EnumTrimmed (не
    # Enum) — 5 з 18 enum-валідованих ALLOW_WITH_VALIDATOR-листів, для
    # яких знайдено ДОКАЗ pre-Wave-2 tolerance до пробілів у РЕАЛЬНОМУ
    # runtime-споживачі:
    #   - NotificationMode/NotificationProvider (F3): усі runtime-
    #     споживачі (BRAVO_DRY_RUN.ps1 x4, BRAVO_NOTIFICATION_TEST.ps1,
    #     BRAVO_RESTORE_TEST.ps1) уже викликають
    #     .Trim().ToLowerInvariant() на цих двох значеннях ДО їх
    #     реального використання;
    #   - consoleSettings.ConsoleLevel/consoleSettings.FileLevel (R3-5,
    #     PR #224 third review): canonical runtime-споживач
    #     Get-BRAVOLogSeverityValue (modules/BRAVO.Logging/BRAVO.Logging.psm1)
    #     уже викликає `.Trim().ToUpperInvariant()` на значенні ПЕРЕД
    #     порівнянням із таблицею рівнів — обидва листи проєктуються в
    #     нього незмінними через Initialize-BRAVOLog
    #     ($script:BRAVOLogConsoleLevel/$script:BRAVOLogFileLevel,
    #     consumed by Write-BRAVOLog), а не звичайну прямо порівнювану
    #     Enum-семантику. Wave 2 не мав ставати першим випадком, коли
    #     ' ERROR '/' INFO ' (історично прийнятні цими двома листами)
    #     перетворюються на startup-помилку;
    #   - defaultLogLevel (PR #224 review, четвертий раунд): Write-Log
    #     (modules/BRAVO.Archive/BRAVO.Archive.Runtime.ps1) використовує
    #     $defaultLogLevel як default для параметра $Level і сам
    #     нормалізує через `$Level.Trim().ToUpperInvariant()` перед
    #     порівнянням з тим самим переліком рівнів — та сама доведена
    #     tolerance-семантика, що й вище.
    # Решта 13 enum-листів (LogLevel/BootRestoreMode/robocopyWindowStyle/
    # MultipleInstances/WeeklyOn/backupConsistency.*/NotificationRouting.*/
    # maintenanceSettings.Logging.Level/schedulerSettings.WindowStyle) НЕ
    # мають такого доказу в жодній точці споживання — лишаються на
    # звичайному 'Enum:' (без trim), щоб не послаблювати авторизацію без
    # підстави для листів, чия семантика не перевірена.
    'bravoSettings.NotificationMode' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'EnumTrimmed:none,errors_only,all' }
    'bravoSettings.NotificationProvider' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'EnumTrimmed:discord,slack' }
    'bravoSettings.NotificationRequestTimeoutSeconds' = @{ Class = 'ALLOW_SITE' }
    'bravoSettings.NotificationRouting.CRITICAL' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'Enum:general,alerts' }
    'bravoSettings.NotificationRouting.ERROR' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'Enum:general,alerts' }
    'bravoSettings.NotificationRouting.SUCCESS' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'Enum:general,alerts' }
    'bravoSettings.NotificationRouting.WARNING' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'Enum:general,alerts' }
    'componentSettings.Archive.BLOG' = @{ Class = 'ALLOW_SITE' }
    'componentSettings.Archive.BRAVOEXCH' = @{ Class = 'ALLOW_SITE' }
    'componentSettings.Archive.MODEL' = @{ Class = 'ALLOW_SITE' }
    'componentSettings.SFTP.ArchiveLogUploadEnabled' = @{ Class = 'ALLOW_SITE' }
    'componentSettings.SFTP.ArchiveUpload' = @{ Class = 'ALLOW_SITE' }
    'componentSettings.SFTP.Enabled' = @{ Class = 'ALLOW_SITE' }
    'componentSettings.SFTP.MaintenanceLogUploadEnabled' = @{ Class = 'ALLOW_SITE' }
    'componentSettings.SMB.ArchiveCopy' = @{ Class = 'ALLOW_SITE' }
    'componentSettings.SMB.Enabled' = @{ Class = 'ALLOW_SITE' }
    'componentSettings.Synchronization.BAZA_APP_LOCAL' = @{ Class = 'ALLOW_SITE' }
    'componentSettings.Synchronization.BAZA_APP_SFTP' = @{ Class = 'ALLOW_SITE' }
    'componentSettings.Synchronization.BAZA_WWW_LOCAL' = @{ Class = 'ALLOW_SITE' }
    'componentSettings.Synchronization.BAZA_WWW_SFTP' = @{ Class = 'ALLOW_SITE' }
    'consoleSettings.BackgroundColor' = @{ Class = 'ALLOW_SITE' }
    'consoleSettings.ClearOnStart' = @{ Class = 'ALLOW_SITE' }
    'consoleSettings.ConsoleLevel' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'EnumTrimmed:TRACE,DEBUG,INFO,SUCCESS,WARNING,ERROR,FATAL' }
    'consoleSettings.FileLevel' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'EnumTrimmed:TRACE,DEBUG,INFO,SUCCESS,WARNING,ERROR,FATAL' }
    'consoleSettings.ForegroundColor' = @{ Class = 'ALLOW_SITE' }
    'consoleSettings.OutputEncodingCodePage' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'WindowsCodePage' }
    'consoleSettings.PauseOnExit' = @{ Class = 'ALLOW_SITE' }
    'consoleSettings.PausePrompt' = @{ Class = 'ALLOW_SITE' }
    'consoleSettings.ShowTimestampsInConsole' = @{ Class = 'ALLOW_SITE' }
    'consoleSettings.StepWidth' = @{ Class = 'ALLOW_SITE' }
    'consoleSettings.WindowTitleTemplate' = @{ Class = 'ALLOW_SITE' }
    'credentialSettings.Targets.ArchivePassword' = @{ Class = 'ALLOW_SITE' }
    'credentialSettings.Targets.ArchivePrefix' = @{ Class = 'ALLOW_SITE' }
    'credentialSettings.Targets.DiscordWebhookAlerts' = @{ Class = 'ALLOW_SITE' }
    'credentialSettings.Targets.DiscordWebhookGeneral' = @{ Class = 'ALLOW_SITE' }
    'credentialSettings.Targets.InstitutionCode' = @{ Class = 'ALLOW_SITE' }
    'credentialSettings.Targets.InstitutionName' = @{ Class = 'ALLOW_SITE' }
    'credentialSettings.Targets.SFTPLogin' = @{ Class = 'ALLOW_SITE' }
    'credentialSettings.Targets.SFTPPassword' = @{ Class = 'ALLOW_SITE' }
    'credentialSettings.Targets.SlackWebhookAlerts' = @{ Class = 'ALLOW_SITE' }
    'credentialSettings.Targets.SlackWebhookGeneral' = @{ Class = 'ALLOW_SITE' }
    'credentialSettings.Targets.SMBLogin' = @{ Class = 'ALLOW_SITE' }
    'credentialSettings.Targets.SMBPassword' = @{ Class = 'ALLOW_SITE' }
    # PR #224 review (P2, "Preserve trimming for defaultLogLevel"):
    # EnumTrimmed (не Enum) — той самий доведений pre-Wave-2 tolerance, що
    # ConsoleLevel/FileLevel вище: Write-Log (BRAVO.Archive.Runtime.ps1)
    # використовує defaultLogLevel як default для $Level і сам нормалізує
    # через $Level.Trim().ToUpperInvariant() перед enum-порівнянням —
    # значення з пробілами навколо (' ERROR ') раніше приймались і
    # коректно оброблялись рантаймом, exact-match Enum: тут хибно
    # відхиляв би всю конфігурацію.
    'defaultLogLevel' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'EnumTrimmed:TRACE,DEBUG,INFO,SUCCESS,WARNING,ERROR,FATAL' }
    'discoverySettings.BravoIniPath' = @{ Class = 'ALLOW_SITE' }
    'discoverySettings.BravoRoot' = @{ Class = 'ALLOW_SITE' }
    'discoverySettings.Sources.BACKUP_ROOT' = @{ Class = 'ALLOW_SITE' }
    'discoverySettings.Sources.BAZA_APP' = @{ Class = 'ALLOW_SITE' }
    'discoverySettings.Sources.BAZA_WWW' = @{ Class = 'ALLOW_SITE' }
    'discoverySettings.Sources.BLOG' = @{ Class = 'ALLOW_SITE' }
    'discoverySettings.Sources.BRAVOEXCH' = @{ Class = 'ALLOW_SITE' }
    'discoverySettings.Sources.MODEL' = @{ Class = 'ALLOW_SITE' }
    'discoverySettings.WebRoot' = @{ Class = 'ALLOW_SITE' }
    'durationFormat' = @{ Class = 'ALLOW_SITE' }
    'elevationSettings.ArgumentsTemplate' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'elevationSettings.PowerShellExecutable' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'elevationSettings.Verb' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'elevationSettings.WindowStyle' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'enableArchiveDeletion' = @{ Class = 'ALLOW_SITE' }
    'enableFailedArchiveDeletion' = @{ Class = 'ALLOW_SITE' }
    'enableLunchArchiveCleanup' = @{ Class = 'ALLOW_SITE' }
    'enableOrphanTempCleanup' = @{ Class = 'ALLOW_SITE' }
    'failedArchiveRetentionDays' = @{ Class = 'ALLOW_SITE' }
    'hashFileEncoding' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'hashFileExtension' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'hashFileFilter' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'hostInformationSettings.PublicIPLookupEnabled' = @{ Class = 'ALLOW_SITE' }
    'hostInformationSettings.PublicIPLookupTimeoutSeconds' = @{ Class = 'ALLOW_SITE' }
    'hostInformationSettings.PublicIPLookupUrls' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'UrlArray:http,https' }
    'logColors.DEBUG' = @{ Class = 'ALLOW_SITE' }
    'logColors.Default' = @{ Class = 'ALLOW_SITE' }
    'logColors.ERROR' = @{ Class = 'ALLOW_SITE' }
    'logColors.Header' = @{ Class = 'ALLOW_SITE' }
    'logColors.Progress' = @{ Class = 'ALLOW_SITE' }
    'logColors.SUCCESS' = @{ Class = 'ALLOW_SITE' }
    'logColors.WARNING' = @{ Class = 'ALLOW_SITE' }
    'logFileDateFormat' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'logFileEncoding' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'logFileFilter' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'logFileNameTemplate' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'LogLevel' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'Enum:TRACE,DEBUG,INFO,SUCCESS,WARNING,ERROR,FATAL' }
    'logLevels.DEBUG' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'logLevels.ERROR' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'logLevels.INFO' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'logLevels.SUCCESS' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'logLevels.WARNING' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'logRetentionDays' = @{ Class = 'ALLOW_SITE' }
    'logSeparatorLength' = @{ Class = 'ALLOW_SITE' }
    'logTimestampFormat' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'lunchArchiveCleanupDirectories' = @{ Class = 'ALLOW_SITE' }
    'lunchArchiveCleanupPath' = @{ Class = 'ALLOW_SITE' }
    'lunchArchiveRetentionMonths' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Archiver.CommandTimeoutSeconds' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Archiver.IntegrityTestTimeoutSeconds' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Archiver.Parameters' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'maintenanceSettings.Automation.ArchiveAfterMaintenance' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Automation.AutoShutdown' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Automation.ShutdownTimeoutSeconds' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.FileOperations.MoveRetryCount' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.FileOperations.MoveRetryDelaySeconds' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.General.BravoWebDirectory' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Limits.EstimatedSpaceMarginPercent' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Limits.ExcludedDrives' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Limits.MaximumMdFileSizeGB' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Limits.MdFileSizeExclusions' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Limits.MinimumFreeSpaceGB' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Logging.Level' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'Enum:TRACE,DEBUG,INFO,SUCCESS,WARNING,ERROR,FATAL' }
    'maintenanceSettings.RangeIdMonitoring.CheckDelaySeconds' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.RangeIdMonitoring.Enabled' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.RangeIdMonitoring.ThresholdPercent' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Restore.ArchivesKeepCount' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Restore.BootRestoreMode' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'Enum:None,HoldServices' }
    'maintenanceSettings.Restore.Day' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Restore.StartupDelayMinutes' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Restore.Time' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Restore.WindowEnd' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Restore.WindowStart' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Retention.ArchiveDays' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Retention.CompressedLogDays' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Retention.CompressedLogDeletionEnabled' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Retention.FailedArchiveDays' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Retention.LogDays' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Retention.RawSourceGraceDays' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Services.BravoDisplayName' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Services.BravoName' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'maintenanceSettings.Services.BravoWebCandidates' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Services.BravoWebEnabled' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Services.ExchangeApiName' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Services.PollIntervalSeconds' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Services.StartTimeoutSeconds' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Services.StopTimeoutSeconds' = @{ Class = 'ALLOW_SITE' }
    'maintenanceSettings.Trace.BISSourcePath' = @{ Class = 'ALLOW_SITE' }
    'minimumRetainedVerifiedBackups' = @{ Class = 'ALLOW_SITE' }
    'orphanTempRetentionHours' = @{ Class = 'ALLOW_SITE' }
    'pathSettings.BackupRoot' = @{ Class = 'ALLOW_SITE' }
    'pathSettings.LIMSRoot' = @{ Class = 'ALLOW_SITE' }
    'pathSettings.SystemLogRoot' = @{ Class = 'ALLOW_SITE' }
    'progressSettings.Activity' = @{ Class = 'ALLOW_SITE' }
    'progressSettings.Enabled' = @{ Class = 'ALLOW_SITE' }
    'progressSettings.RobocopyProgressOptions' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'progressSettings.SevenZipProgressSwitch' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'progressSettings.SevenZipTestTimeoutSeconds' = @{ Class = 'ALLOW_SITE' }
    'progressSettings.SevenZipTimeoutSeconds' = @{ Class = 'ALLOW_SITE' }
    'progressSettings.ShowOverallProgress' = @{ Class = 'ALLOW_SITE' }
    'progressSettings.ShowRobocopyOutput' = @{ Class = 'ALLOW_SITE' }
    'progressSettings.ShowSevenZipOutput' = @{ Class = 'ALLOW_SITE' }
    'progressSettings.ShowWinSCPOutput' = @{ Class = 'ALLOW_SITE' }
    'requireAdministrator' = @{ Class = 'DENY_SECURITY_CONTROL'; WeakeningOverride = 'ExistingSecurityEscapeHatch' }
    'restoreVerifySettings.MaxVerificationAgeHours' = @{ Class = 'ALLOW_SITE' }
    'restoreVerifySettings.MinimumFileCount' = @{ Class = 'ALLOW_SITE' }
    'robocopyMaxSuccessExitCode' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'IntegerRange:0,7' }
    'robocopyOptions' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'robocopyPath' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'robocopyWindowStyle' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'Enum:Normal,Minimized,Maximized,Hidden' }
    'schedulerSettings.AllowStartIfOnBatteries' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Backup.DailyAt' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Backup.Description' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Backup.Enabled' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Backup.ExecutionTimeLimitHours' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Backup.TaskName' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'schedulerSettings.BAZASync.Description' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.BAZASync.ExecutionTimeLimitHours' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.BAZASync.RepeatEveryHours' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.BAZASync.StartAt' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.BAZASync.TaskName' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'schedulerSettings.DontStopIfGoingOnBatteries' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Health.BusyWaitMinutes' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Health.Description' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Health.Enabled' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Health.ExecutionTimeLimitHours' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Health.RepeatEveryMinutes' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Health.SkipIfBackupTaskRunning' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Health.StartAt' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Health.TaskName' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'schedulerSettings.Hidden' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.LegacyTaskNames' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'schedulerSettings.LegacyTaskPath' = @{ Class = 'DENY_INTERNAL_METADATA' }
    'schedulerSettings.LogonType' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'schedulerSettings.Maintenance.DailyAt' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Maintenance.Description' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Maintenance.Enabled' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Maintenance.ExecutionTimeLimitHours' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Maintenance.TaskName' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'schedulerSettings.MultipleInstances' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'Enum:Parallel,Queue,IgnoreNew,StopExisting' }
    'schedulerSettings.OperationLockWaitMinutes' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Recovery.Description' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Recovery.ExecutionTimeLimitHours' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.Recovery.TaskName' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'schedulerSettings.RequireProtectedRuntime' = @{ Class = 'DENY_SECURITY_CONTROL' }
    'schedulerSettings.RestartCount' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.RestartIntervalMinutes' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.RestoreVerify.At' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.RestoreVerify.Description' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.RestoreVerify.Enabled' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.RestoreVerify.ExecutionTimeLimitHours' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.RestoreVerify.TaskName' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'schedulerSettings.RestoreVerify.WeeklyOn' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'Enum:Monday,Tuesday,Wednesday,Thursday,Friday,Saturday,Sunday' }
    'schedulerSettings.RunAsUser' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'schedulerSettings.StartWhenAvailable' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.TaskPath' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'TaskSchedulerPath' }
    'schedulerSettings.WakeToRun' = @{ Class = 'ALLOW_SITE' }
    'schedulerSettings.WindowStyle' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'Enum:Normal,Minimized,Maximized,Hidden' }
    'sftpConnectionTimeoutSeconds' = @{ Class = 'ALLOW_SITE' }
    'sftpDirectories.ArchivLog' = @{ Class = 'ALLOW_SITE' }
    # PR #224 review, N3: пере-класифіковано з DENY_DERIVED на ALLOW_SITE
    # (2026-09-22, review remediation) — доведено фактичною трасою
    # BRAVO.Configuration.Derivation.psm1:285-288 ("sftpDirectories — уже
    # повністю raw-параметр (без похідних полів)", `$global:sftpDirectories
    # = $sftpDirectories` — пряма проєкція без обчислення) і
    # Get-BRAVOEffectiveSynchronizationConfiguration
    # (BRAVO.Discovery.psm1:2112/2122), де `$SftpDirectories['BAZA']`/
    # `['BAZAWWW']` передається в SftpRemoteDirectory АС IS, без деривації.
    # Канонічний дефолт (BRAVO.Configuration.psm1:360-361, "baza_app"/
    # "baza_www") — такий самий сирий рядок-каталог, що й усі сусідні
    # sftpDirectories.* (MODEL/Blog/BravoExch/Manifest/...), усі вже
    # ALLOW_SITE. Це НЕ шлях discovery BAZA_APP/BAZA_WWW SOURCE
    # (BRAVO.Discovery.psm1 Resolve-BRAVODiscoveryPathComponentPresence) —
    # той домен справді похідний/евристичний, але не має власного запису
    # в цьому реєстрі; тут ідеться про ім'я SFTP remote-каталогу, суто
    # site-конфігурований оператором рядок, без жодної деривації.
    # Жоден security-інваріант не залежить від фіксованого імені цього
    # каталогу — append-only mutation-детекція (BAZA.Mode/MutationPolicy,
    # лишаються DENY_SECURITY_CONTROL) працює незалежно від того, як
    # називається remote-каталог.
    'sftpDirectories.BAZA' = @{ Class = 'ALLOW_SITE' }
    'sftpDirectories.BAZAWWW' = @{ Class = 'ALLOW_SITE' }
    'sftpDirectories.Blog' = @{ Class = 'ALLOW_SITE' }
    'sftpDirectories.BravoExch' = @{ Class = 'ALLOW_SITE' }
    'sftpDirectories.ExchangeApiLogs' = @{ Class = 'ALLOW_SITE' }
    'sftpDirectories.MaintenanceLog' = @{ Class = 'ALLOW_SITE' }
    'sftpDirectories.Manifest' = @{ Class = 'ALLOW_SITE' }
    'sftpDirectories.MODEL' = @{ Class = 'ALLOW_SITE' }
    'sftpDirectories.Trace' = @{ Class = 'ALLOW_SITE' }
    'sftpDirectories.TraceLogs' = @{ Class = 'ALLOW_SITE' }
    'sftpHostKey' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'NonEmptyString' }
    'sftpHostTemplate' = @{ Class = 'ALLOW_SITE' }
    'sftpPort' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'IntegerRange:1,65535' }
    'sftpSynchronizationOptions' = @{ Class = 'DENY_EXECUTION_CONTROL' }
    'smbSettings.CopyBufferSizeMB' = @{ Class = 'ALLOW_SITE' }
    'smbSettings.Directories.BLOG' = @{ Class = 'ALLOW_SITE' }
    'smbSettings.Directories.BRAVOEXCH' = @{ Class = 'ALLOW_SITE' }
    'smbSettings.Directories.MODEL' = @{ Class = 'ALLOW_SITE' }
    'smbSettings.RootPath' = @{ Class = 'ALLOW_SITE' }
    'synchronizationSafety.RequireNonEmptyBAZASource' = @{ Class = 'DENY_SECURITY_CONTROL' }
    'winSCPIniPath' = @{ Class = 'DENY_SECURITY_CONTROL' }
    'winSCPScriptEncoding' = @{ Class = 'ALLOW_WITH_VALIDATOR'; Validator = 'DotNetEncodingName' }
}

function Get-BRAVOConfigurationSchemaAuthorizationClass {
    <#
    .SYNOPSIS
        Захисна копія авторизаційного реєстру Wave 2 (#216).
    .DESCRIPTION
        Повертає НОВУ hashtable (не посилання на $script:-стан) — викликач
        не може мутувати канонічний реєстр через повернене значення.
        Використовується loader-ом непрямо (через Test-BRAVOConfigurationOverrideAuthorization)
        і self-test-ами повноти схеми напряму (перевірка, що кожен
        канонічний лист має рівно один запис і жоден запис не осиротів).
    .OUTPUTS
        [hashtable]
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $copy = @{}
    foreach ($path in @($script:BRAVOConfigurationSchemaAuthorizationClass.Keys)) {
        $entry = $script:BRAVOConfigurationSchemaAuthorizationClass[$path]
        $copy[$path] = @{
            Class             = [string]$entry.Class
            Validator         = $(if ($entry.Contains('Validator')) { [string]$entry.Validator } else { $null })
            # WeakeningOverride: FAIL-CLOSED за замовчуванням. Відсутність
            # явного запису в канонічному реєстрі НІКОЛИ не мовчки
            # інтерпретується як "escapable" — лише явний
            # 'ExistingSecurityEscapeHatch' у реєстрі надає доступ до
            # наявного BRAVO_ALLOW_WEAKENED_SECURITY-механізму (owner
            # remediation, Issue #216 Wave 2: канонічний реєстр — ЄДИНИЙ
            # власник цієї політики, loader більше не знає жодної
            # dot-path-назви).
            WeakeningOverride = $(if ($entry.Contains('WeakeningOverride')) { [string]$entry.WeakeningOverride } else { $script:BRAVOConfigurationSchemaWeakeningOverrideNone })
        }
    }
    return $copy
}

function Test-BRAVOConfigurationWeakeningEscapeHatchAllowed {
    <#
    .SYNOPSIS
        Єдина canonical перевірка: чи МОЖЕ конкретний DENY_*-лист пройти
        через наявний BRAVO_ALLOW_WEAKENED_SECURITY=1 механізм ЗАРАЗ
        (PR #224 review, R3-1).
    .DESCRIPTION
        Комбінує дві незалежні умови в ОДНЕ рішення, щоб жоден викликач
        (loader, Configurator preview) не повторював цю комбінацію
        самостійно:
          1. WeakeningOverride запису реєстру для цього Path —
             'ExistingSecurityEscapeHatch' (canonical дозвіл на ЦЕЙ лист;
             fail-closed 'None' за замовчуванням — див.
             Get-BRAVOConfigurationSchemaAuthorizationClass);
          2. фактичний стан env-змінної BRAVO_ALLOW_WEAKENED_SECURITY у
             ПОТОЧНОМУ процесі (оператор дійсно підтвердив послаблення
             зараз, а не лише "цей лист теоретично escapable").
        Обидві умови МУСЯТЬ бути істинними, інакше DENY_*-порушення на
        цьому Path лишається безумовною відмовою — той самий висновок,
        що вже виводить BRAVO_CONFIG_LOADER.ps1 (Test-BRAVOConfigurationOverrideAuthorization
        + власний WeakeningOverride/env-читання), тепер доступний як
        одна canonical функція для будь-якого викликача, якому потрібне
        те саме рішення без повторної реалізації порівняння.
        Не приймає Value/Class — навмисно: рішення "чи ЦЕЙ Path escapable
        ЗАРАЗ" не залежить від запропонованого значення (DENY_* — про
        володіння листом, не про безпечність конкретного значення).
    .PARAMETER Path
        Канонічний dot-шлях, що перевіряється.
    .PARAMETER AuthorizationClass
        Опційно — вже отриманий результат Get-BRAVOConfigurationSchemaAuthorizationClass
        (уникає повторного виклику, коли викликач уже його має). За
        замовчуванням функція отримує свіжу копію сама.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$AuthorizationClass
    )

    $registry = $AuthorizationClass
    if ($null -eq $registry) {
        $registry = Get-BRAVOConfigurationSchemaAuthorizationClass
    }

    if (-not $registry.Contains($Path)) { return $false }

    $weakeningOverride = [string]$registry[$Path].WeakeningOverride
    if ($weakeningOverride -ne $script:BRAVOConfigurationSchemaWeakeningOverrideExistingEscapeHatch) {
        return $false
    }

    return ([System.Environment]::GetEnvironmentVariable('BRAVO_ALLOW_WEAKENED_SECURITY') -eq '1')
}

function Test-BRAVOConfigurationAuthorizationEnumValue {
    # Регістронезалежне порівняння (як і решта схеми — та сама
    # case-insensitive-семантика, що hashtable PowerShell); значення
    # МУСИТЬ бути рядком — не-рядок (Number/Boolean/Array/$null) завжди
    # відхиляється, навіть якщо його текстове представлення випадково
    # збігається з дозволеним значенням.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Value,
        [Parameter(Mandatory = $true)][string[]]$AllowedValues,
        [Parameter(Mandatory = $true)][string]$Path,
        # PR #224 review, F3: лише для 'EnumTrimmed:'-диспетчеризованих
        # листів (див. Test-BRAVOConfigurationAuthorizationValidatorValue) —
        # порівняння відбувається з ОБРІЗАНИМ (Trim) значенням, але саме
        # значення НЕ мутується й НЕ повертається звідси: авторизація
        # лише каже "прийнятно/неприйнятно", збережене/повернене
        # значення лишається таким, яким його ввів оператор (той самий
        # незмінний runtime-consumer, що вже сам робить
        # .Trim().ToLowerInvariant() перед використанням).
        [switch]$TrimBeforeComparison
    )

    if ($null -eq $Value -or $Value -isnot [string]) {
        $actualCaption = if ($null -eq $Value) { '$null' } else { $Value.GetType().Name }
        return [pscustomobject]@{
            IsValid = $false
            Message = "${Path}: очікується рядок із переліку ($($AllowedValues -join ', ')), отримано $actualCaption."
        }
    }
    $comparisonValue = if ($TrimBeforeComparison) { ([string]$Value).Trim() } else { [string]$Value }
    foreach ($allowed in $AllowedValues) {
        if ([string]::Equals($comparisonValue, $allowed, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ IsValid = $true; Message = $null }
        }
    }
    return [pscustomobject]@{
        IsValid = $false
        Message = "${Path}: значення '$Value' недопустиме. Дозволено: $($AllowedValues -join ', ')."
    }
}

function Test-BRAVOConfigurationAuthorizationIntegerRange {
    # Ціле число БЕЗ рядкової коерсії: '7' (рядок), $true/$false, масив і
    # дробове значення (7.5) відхиляються так само, як значення поза
    # діапазоном — TypeCode-перевірка (та сама причина, що
    # Get-BRAVOConfigurationSchemaValueKind: короткі типи-прискорювачі
    # не всюди доступні в Windows PowerShell 5.1), а не `-is [int]`-ланцюг.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Value,
        [Parameter(Mandatory = $true)][int]$Minimum,
        [Parameter(Mandatory = $true)][int]$Maximum,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($null -eq $Value) {
        return [pscustomobject]@{
            IsValid = $false
            Message = "${Path}: очікується ціле число в діапазоні $Minimum..$Maximum, отримано `$null."
        }
    }
    $typeCode = [string][System.Type]::GetTypeCode($Value.GetType())
    if ($script:BRAVOConfigurationSchemaNumericTypeCode -notcontains $typeCode) {
        return [pscustomobject]@{
            IsValid = $false
            Message = "${Path}: очікується ціле число без лапок (діапазон $Minimum..$Maximum), отримано $($Value.GetType().Name)."
        }
    }
    $doubleValue = [double]$Value
    if ($doubleValue -ne [System.Math]::Truncate($doubleValue)) {
        return [pscustomobject]@{
            IsValid = $false
            Message = "${Path}: значення '$Value' має дробову частину — очікується ціле число (діапазон $Minimum..$Maximum)."
        }
    }
    $intValue = [int64]$doubleValue
    if ($intValue -lt $Minimum -or $intValue -gt $Maximum) {
        return [pscustomobject]@{
            IsValid = $false
            Message = "${Path}: значення '$Value' поза допустимим діапазоном $Minimum..$Maximum."
        }
    }
    return [pscustomobject]@{ IsValid = $true; Message = $null }
}

function Test-BRAVOConfigurationAuthorizationWindowsCodePage {
    # Число ДОДАТКОВО мусить бути розпізнаваним .NET Encoding code page —
    # ціле в правдоподібному діапазоні, яке .NET все одно не знає, все
    # одно відхиляється (напр. 99999).
    #
    # PR #224 review (P2, "Permit the valid Windows code page zero"):
    # мінімум навмисно 0 (не 1) — [System.Text.Encoding]::GetEncoding(0)
    # ВАЛІДНИЙ .NET-виклик (системна ANSI code page за замовчуванням),
    # той самий API, що й production-споживач консолі/WinSCP-кодування
    # використовує напряму. Діапазон нижче лише відсіює структурно
    # неможливі значення (від'ємні/дробові/нецілі/понад 65535) ДО
    # звернення до .NET; чи КОНКРЕТНЕ невід'ємне число (0 включно) —
    # розпізнаваний code page, і далі вирішує вже сам
    # Encoding.GetEncoding нижче — жодного окремого спецвипадку для 0
    # тут не додано.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rangeResult = Test-BRAVOConfigurationAuthorizationIntegerRange -Value $Value -Minimum 0 -Maximum 65535 -Path $Path
    if (-not $rangeResult.IsValid) { return $rangeResult }
    try {
        [void][System.Text.Encoding]::GetEncoding([int]$Value)
        return [pscustomobject]@{ IsValid = $true; Message = $null }
    } catch {
        return [pscustomobject]@{ IsValid = $false; Message = "${Path}: код сторінки '$Value' не розпізнається .NET Encoding." }
    }
}

function Test-BRAVOConfigurationAuthorizationEncodingName {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($null -eq $Value -or $Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [pscustomobject]@{ IsValid = $false; Message = "${Path}: очікується непорожнє ім'я .NET-кодування (напр. UTF8, ASCII)." }
    }
    try {
        [void][System.Text.Encoding]::GetEncoding([string]$Value)
        return [pscustomobject]@{ IsValid = $true; Message = $null }
    } catch {
        return [pscustomobject]@{ IsValid = $false; Message = "${Path}: кодування '$Value' не розпізнається .NET Encoding." }
    }
}

function Test-BRAVOConfigurationAuthorizationUrlArray {
    # Кожен елемент — абсолютний URL з дозволеною схемою (http/https).
    # Масив як ціле не перевіряється по-елементно за схожими родами —
    # елемент, що не є рядком, чи невалідний URL відхиляє весь масив
    # (перше порушення — точний індекс у повідомленні).
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Value,
        [Parameter(Mandatory = $true)][string[]]$AllowedSchemes,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($null -eq $Value -or $Value -isnot [System.Collections.IEnumerable] -or $Value -is [string]) {
        return [pscustomobject]@{ IsValid = $false; Message = "${Path}: очікується масив URL-рядків." }
    }
    $index = 0
    foreach ($item in $Value) {
        $elementPath = '{0}[{1}]' -f $Path, $index
        if ($null -eq $item -or $item -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item)) {
            return [pscustomobject]@{ IsValid = $false; Message = "${elementPath}: очікується непорожній рядок URL." }
        }
        $parsedUri = $null
        if (-not [System.Uri]::TryCreate([string]$item, [System.UriKind]::Absolute, [ref]$parsedUri)) {
            return [pscustomobject]@{ IsValid = $false; Message = "${elementPath}: '$item' не є коректним абсолютним URL." }
        }
        $scheme = $parsedUri.Scheme.ToLowerInvariant()
        if ($AllowedSchemes -notcontains $scheme) {
            return [pscustomobject]@{ IsValid = $false; Message = "${elementPath}: схема '$scheme' недопустима — дозволено: $($AllowedSchemes -join ', ')." }
        }
        $index++
    }
    return [pscustomobject]@{ IsValid = $true; Message = $null }
}

function Test-BRAVOConfigurationAuthorizationTaskSchedulerPath {
    <#
    .DESCRIPTION
        PR #224 review, N2: попередня версія вимагала, щоб СИРЕ значення
        вже було у нормалізованій формі `\...\` (regex `^\\.*\\$`) — це
        суворіше за фактичний runtime-контракт. Канонічний нормалізатор
        schedulerSettings.TaskPath — ConvertTo-BRAVOTaskPath
        (modules/BRAVO.System/BRAVO.System.psm1) — робить
        `.Trim().Trim('\')`, потім відхиляє неприпустимі символи
        (`[/:*?"<>|]`) і dot-сегменти (`.`/`..`), і повертає
        нормалізовану `\<value>\`. Форми на кшталт 'BRAVO', '\BRAVO',
        'BRAVO\' — валідні pre-Wave-2 вхідні дані, що нормалізатор уже
        приймав; ця авторизація мала їх помилково відхиляти.
        Замість дублювання regex-граматики нормалізатора (друга,
        незалежна копія тієї самої політики — заборонено архітектурною
        політикою), авторизація ВИКЛИКАЄ сам канонічний
        ConvertTo-BRAVOTaskPath і трактує виняток як IsValid=$false.
        Напрямок залежності Configuration -> System безпечний: System —
        листовий модуль (не має власних Import-Module, не залежить від
        Configuration), тож циклу немає.
        Валідація лише перевіряє прийнятність — САМЕ значення, що йде
        далі в merge, НЕ підмінюється нормалізованою формою; runtime-
        консюмер (BRAVO_TASKS_INSTALL.ps1 та інші) і далі сам викликає
        ConvertTo-BRAVOTaskPath над сирим значенням у момент використання.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($null -eq $Value -or $Value -isnot [string]) {
        return [pscustomobject]@{ IsValid = $false; Message = "${Path}: значення мусить бути рядком (шлях Task Scheduler)." }
    }

    if (-not (Get-Module -Name 'BRAVO.System')) {
        Import-Module -Name (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'BRAVO.System\BRAVO.System.psd1') -ErrorAction Stop
    }

    try {
        # Лише валідація — повернене нормалізоване значення свідомо
        # відкидається ([void]), сире $Value НЕ мутується й НЕ
        # повертається звідси.
        [void](ConvertTo-BRAVOTaskPath -TaskPath ([string]$Value))
    } catch {
        return [pscustomobject]@{ IsValid = $false; Message = "${Path}: $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ IsValid = $true; Message = $null }
}

function Test-BRAVOConfigurationAuthorizationNonEmptyString {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($null -eq $Value -or $Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [pscustomobject]@{ IsValid = $false; Message = "${Path}: значення не може бути порожнім." }
    }
    return [pscustomobject]@{ IsValid = $true; Message = $null }
}

function Test-BRAVOConfigurationAuthorizationValidatorValue {
    <#
    .SYNOPSIS
        Диспетчер іменованих валідаторів для ALLOW_WITH_VALIDATOR (#216, Wave 2).
    .DESCRIPTION
        Валідатори — іменовані PowerShell-функції, диспетчеровані за
        стабільним рядковим ідентифікатором ('Enum:...', 'IntegerRange:...',
        'WindowsCodePage', ...), а НЕ scriptblock-и, вбудовані в
        дескриптор: scriptblock у data-реєстрі ускладнює
        integrity-верифікацію (RUNTIME_MANIFEST), тестування й PS
        5.1-серіалізацію (WAVE2-CONTRACT.md, розділ 11.5).

        Невідомий ідентифікатор валідатора — FAIL CLOSED (throw), а не
        мовчазний accept: якщо реєстр посилається на валідатор, якого
        немає, це дефект реєстру схеми, не легітимне "порожнє" значення
        оператора.
    .OUTPUTS
        [pscustomobject] { IsValid; Message }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$ValidatorId,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($ValidatorId.StartsWith('Enum:', [System.StringComparison]::Ordinal)) {
        $allowedValues = @($ValidatorId.Substring(5) -split ',')
        return Test-BRAVOConfigurationAuthorizationEnumValue -Value $Value -AllowedValues $allowedValues -Path $Path
    }
    if ($ValidatorId.StartsWith('EnumTrimmed:', [System.StringComparison]::Ordinal)) {
        # PR #224 review, F3: окремий (не гілка загального 'Enum:')
        # named-валідатор — лише для листів, де ДОВЕДЕНО pre-Wave-2
        # tolerance до пробілів на всіх реальних runtime-точках
        # споживання (див. коментар біля реєстрації
        # bravoSettings.NotificationMode/NotificationProvider). НЕ
        # застосовується узагальнено до всіх enum-листів без доказу.
        $allowedValues = @($ValidatorId.Substring(12) -split ',')
        return Test-BRAVOConfigurationAuthorizationEnumValue -Value $Value -AllowedValues $allowedValues -Path $Path -TrimBeforeComparison
    }
    if ($ValidatorId.StartsWith('IntegerRange:', [System.StringComparison]::Ordinal)) {
        $bounds = @($ValidatorId.Substring(13) -split ',')
        return Test-BRAVOConfigurationAuthorizationIntegerRange -Value $Value -Minimum ([int]$bounds[0]) -Maximum ([int]$bounds[1]) -Path $Path
    }
    if ($ValidatorId.StartsWith('UrlArray:', [System.StringComparison]::Ordinal)) {
        $allowedSchemes = @($ValidatorId.Substring(9) -split ',')
        return Test-BRAVOConfigurationAuthorizationUrlArray -Value $Value -AllowedSchemes $allowedSchemes -Path $Path
    }
    switch ($ValidatorId) {
        'WindowsCodePage'    { return Test-BRAVOConfigurationAuthorizationWindowsCodePage -Value $Value -Path $Path }
        'DotNetEncodingName' { return Test-BRAVOConfigurationAuthorizationEncodingName -Value $Value -Path $Path }
        'TaskSchedulerPath'  { return Test-BRAVOConfigurationAuthorizationTaskSchedulerPath -Value $Value -Path $Path }
        'NonEmptyString'     { return Test-BRAVOConfigurationAuthorizationNonEmptyString -Value $Value -Path $Path }
        default {
            throw "Схема авторизації конфігурації: невідомий ідентифікатор валідатора '$ValidatorId' для '$Path' — це дефект реєстру схеми, не значення оператора."
        }
    }
}

function Test-BRAVOConfigurationAuthorizationLeaf {
    # Приватний helper (не експортується): оцінює АВТОРИЗАЦІЮ РІВНО
    # ОДНОГО канонічного leaf-шляху й додає порушення (якщо є) у спільну
    # колекцію викликача. Винесено з Test-BRAVOConfigurationOverrideAuthorization
    # (PR #224 review, F1) — та сама логіка тепер викликається як з
    # top-level циклу, так і рекурсивно для листів, супроводжуваних
    # вкладеним (Node) local-override значенням; одна реалізація на
    # "чи авторизований цей КОНКРЕТНИЙ leaf-шлях", без дублювання.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Value,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Violations
    )

    if (-not $script:BRAVOConfigurationSchemaAuthorizationClass.Contains($Path)) {
        # Схема знає цей лист, але авторизаційний реєстр — ні. Це
        # дефект РЕЄСТРУ (порушення умови self-test-повноти), не
        # легітимний "невідомий шлях" (той випадок уже відсіяний
        # викликачем через Schema.Contains). Fail closed: мовчазний
        # allow-by-omission для КАНОНІЧНОГО листа заборонений
        # архітектурним рішенням Wave 2 (WAVE2-CONTRACT.md, розділ 11.3).
        [void]$Violations.Add([pscustomobject]@{
            Path              = $Path
            Class             = 'UNREGISTERED'
            Validator         = $null
            WeakeningOverride = $script:BRAVOConfigurationSchemaWeakeningOverrideNone
            Reason            = 'MissingAuthorizationPolicy'
            Message           = "${Path}: канонічний лист не має запису в авторизаційному реєстрі Wave 2 — це дефект реєстру схеми, не дозвіл."
        })
        return
    }

    $entry = $script:BRAVOConfigurationSchemaAuthorizationClass[$Path]
    $class = [string]$entry.Class
    # Fail-closed за замовчуванням: відсутність WeakeningOverride у
    # записі реєстру ЗАВЖДИ означає 'None', НІКОЛИ мовчазний
    # escapable-дозвіл (той самий дефолт, що Get-BRAVOConfigurationSchemaAuthorizationClass
    # застосовує для зовнішніх читачів реєстру).
    $weakeningOverride = $(if ($entry.Contains('WeakeningOverride')) { [string]$entry.WeakeningOverride } else { $script:BRAVOConfigurationSchemaWeakeningOverrideNone })

    if ($class -eq 'ALLOW_SITE') { return }

    if ($class -eq 'ALLOW_WITH_VALIDATOR') {
        $validatorId = [string]$entry.Validator
        $validationResult = Test-BRAVOConfigurationAuthorizationValidatorValue -ValidatorId $validatorId -Value $Value -Path $Path
        if (-not $validationResult.IsValid) {
            [void]$Violations.Add([pscustomobject]@{
                Path              = $Path
                Class             = $class
                Validator         = $validatorId
                WeakeningOverride = $weakeningOverride
                Reason            = 'ValidatorRejected'
                Message           = $validationResult.Message
            })
        }
        return
    }

    # Усі DENY_*-класи: безумовна відмова, незалежно від значення.
    # Escapability (чи МОЖЕ викликач запропонувати наявний
    # BRAVO_ALLOW_WEAKENED_SECURITY-механізм для цього конкретного
    # порушення) — це ВЛАСТИВІСТЬ порушення (WeakeningOverride вище),
    # яку викликач (loader) читає з результату; ЦЯ функція нічого не
    # вирішує про env-змінну і не знає жодної dot-path-назви окрім
    # тієї, що обробляє в поточному виклику.
    [void]$Violations.Add([pscustomobject]@{
        Path              = $Path
        Class             = $class
        Validator         = $null
        WeakeningOverride = $weakeningOverride
        Reason            = 'DeniedClass'
        Message           = "${Path}: локальне перевизначення заборонено (клас '$class') — BRAVO.local.config не має повноважень на цей лист незалежно від запропонованого значення."
    })
}

function Test-BRAVOConfigurationAuthorizationNodeDescendants {
    # Приватний helper (не експортується): рекурсивно авторизує КОЖЕН
    # leaf усередині вкладеного (Node) local-override значення — та сама
    # структурна рекурсія (batch/child-path побудова, D3 unknown-child
    # skip, глибина обмежена $script:BRAVOConfigurationSchemaMaximumDepth),
    # що Add-BRAVOConfigurationSchemaViolation вже застосовує для
    # ТИПОВОЇ перевірки Node-значень (PR #224 review, F1): раніше
    # авторизація не мала еквівалентної рекурсії й тому помилково
    # трактувала кожен Node-шлях, супроводжуваний вкладеним hashtable, як
    # "канонічний лист без запису в реєстрі" (UNREGISTERED) — реєстр НЕ
    # містить записів на Node-шляхи, лише на leaf-шляхи, тому вимога була
    # структурно нездійсненною.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Node,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$Schema,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Violations,
        [Parameter(Mandatory = $true)][int]$Depth
    )

    if ($Depth -gt $script:BRAVOConfigurationSchemaMaximumDepth) { return }

    foreach ($childKey in @($Node.Keys)) {
        $childPath = "$Path.$childKey"
        # Невідомий ключ усередині вузла-override — той самий "невідомий
        # кінцевий сегмент під відомим вузлом", що D3 (рішення власника
        # 2026-09-14) вже лишає прийнятним для типової перевірки — тут
        # лише пропуск, без ВЛАСНОЇ, ширшої, unknown-path-політики.
        if (-not $Schema.Contains($childPath)) { continue }

        $childDescriptor = $Schema[$childPath]
        $childValue = $Node[$childKey]

        if ([string]$childDescriptor.Kind -eq 'Node') {
            # Вкладеність глибша за один рівень — рекурсуємо далі. Якщо
            # значення НЕ hashtable (форма невірна), це вже відповідальність
            # Test-BRAVOConfigurationOverrideSchema (типова перевірка, що
            # ЗАВЖДИ запускається раніше в конвеєрі loader-а) — авторизація
            # тут лишається мовчазною для НЕПРАВИЛЬНОЇ форми, а не намагається
            # самостійно повторно діагностувати тип.
            if ($childValue -is [hashtable]) {
                Test-BRAVOConfigurationAuthorizationNodeDescendants -Node $childValue -Path $childPath `
                    -Schema $Schema -Violations $Violations -Depth ($Depth + 1)
            }
            continue
        }

        Test-BRAVOConfigurationAuthorizationLeaf -Path $childPath -Value $childValue -Violations $Violations
    }
}

function Test-BRAVOConfigurationOverrideAuthorization {
    <#
    .SYNOPSIS
        Перевіряє АВТОРИЗАЦІЮ (не тип) кожного local-override шляху проти
        канонічного класифікаційного реєстру Wave 2 (#216).
    .DESCRIPTION
        ОКРЕМИЙ виклик від Test-BRAVOConfigurationOverrideSchema (яка
        перевіряє лише ФОРМУ/тип значення) — авторизація визначає, чи
        БУДЬ-ЯКЕ значення на цьому шляху дозволено перевизначати з
        BRAVO.local.config, незалежно від того, наскільки воно
        правильного типу.

        Перевіряються ЛИШЕ шляхи, відомі схемі ($Schema.Contains($path)) —
        та сама межа, що й у Test-BRAVOConfigurationOverrideSchema.
        Невідомий кінцевий сегмент (D3, рішення власника 2026-09-14)
        НАВМИСНО не класифікується тут.

        Node-шляхи (PR #224 review, F1): реєстр Wave 2 навмисно містить
        ЛИШЕ leaf-записи, НЕ Node-записи. Local-override значення на
        Node-шляху (вкладений hashtable, наприклад
        bravoSettings.NotificationRouting = @{ SUCCESS='general';
        WARNING='alerts' }) авторизується рекурсивно ЧЕРЕЗ його
        supplied-leaves (bravoSettings.NotificationRouting.SUCCESS,
        ...WARNING) — Test-BRAVOConfigurationAuthorizationNodeDescendants
        нижче, та сама D3-межа й глибина, що вже застосовує типова
        перевірка. Реєстр і далі НІКОЛИ не отримує запису на сам Node-шлях.

        ALLOW_SITE      -> приймається без додаткової перевірки.
        ALLOW_WITH_VALIDATOR -> додатково проганяється через іменований
                                 валідатор (Test-BRAVOConfigurationAuthorizationValidatorValue).
        DENY_*          -> відхиляється БЕЗУМОВНО, незалежно від
                            запропонованого значення (у т.ч. коли воно
                            збігається з канонічним дефолтом) —
                            авторизація тут про володіння ЛИСТОМ, а не
                            про безпечність конкретного значення. Це
                            діє ІДЕНТИЧНО для top-level DENY-листа й для
                            DENY-листа, досягнутого через вкладену
                            Node-форму — атомарність (одне порушення
                            будь-де в шарі відхиляє ВЕСЬ шар) не залежить
                            від того, якою формою супроводжувався
                            конкретний leaf.
    .PARAMETER DotPathOverrides
        Плаский шар "dot-шлях -> значення" (формат BRAVO.local.config) —
        той самий вхід, що й Test-BRAVOConfigurationOverrideSchema.
    .PARAMETER Schema
        Результат Get-BRAVOConfigurationSchema.
    .OUTPUTS
        [pscustomobject] { IsValid; Violations }
        Кожне порушення: [pscustomobject]{ Path; Class; Validator; WeakeningOverride; Reason; Message }.
        WeakeningOverride ('None'|'ExistingSecurityEscapeHatch') — чи МОЖЕ
        викликач (loader) запропонувати наявний
        BRAVO_ALLOW_WEAKENED_SECURITY-механізм для САМЕ ЦЬОГО порушення;
        похідне з канонічного реєстру, fail-closed 'None' за
        замовчуванням, коли реєстр не містить явного значення.
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
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not $Schema.Contains($path)) { continue }

        $descriptor = $Schema[$path]
        $value = $DotPathOverrides[$dotPath]

        if ([string]$descriptor.Kind -eq 'Node') {
            # Node-шлях: реєстр НІКОЛИ не містить запису на нього самого
            # (F1) — авторизуємо кожен supplied descendant-leaf окремо.
            # Неправильна форма (значення не hashtable) — відповідальність
            # типової перевірки, яка вже проходить раніше в конвеєрі
            # loader-а; тут просто нічого немає для рекурсії.
            if ($value -is [hashtable]) {
                Test-BRAVOConfigurationAuthorizationNodeDescendants -Node $value -Path $path `
                    -Schema $Schema -Violations $violations -Depth 1
            }
            continue
        }

        Test-BRAVOConfigurationAuthorizationLeaf -Path $path -Value $value -Violations $violations
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
    ,'Test-BRAVOConfigurationOverrideAuthorization'
    ,'Get-BRAVOConfigurationSchemaAuthorizationClass'
    ,'Test-BRAVOConfigurationAuthorizationValidatorValue'
    ,'Test-BRAVOConfigurationWeakeningEscapeHatchAllowed'
)
