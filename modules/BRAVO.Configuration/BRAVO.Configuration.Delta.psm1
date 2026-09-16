Set-StrictMode -Version 2.0

# BRAVO.Configuration.Delta — canonical порівняння двох конфігураційних
# графів (#154, задача B0).
#
# Навіщо окремий файл, а не функція в BRAVO.Configuration.psm1: там живе
# canonical pipeline завантаження (defaults -> merge -> nested override),
# і він виконується на КОЖНОМУ запуску продукту. Порівняння графів —
# інша відповідальність, потрібна діагностиці й міграції, а не
# завантаженню. Той самий поділ, що вже застосовано для
# BRAVO.Configuration.Derivation.psm1.
#
# Модуль НЕ має залежностей: він приймає два готові графи й повертає
# структуровані відмінності. Рендеринг у літерали BRAVO.local.config —
# відповідальність викликача (ConvertTo-BRAVOConfiguratorPowerShellLiteral
# з BRAVO.Configurator.Effective), інакше доменний модуль конфігурації
# почав би залежати від модуля Configurator-а, тобто від вищого шару.

function Test-BRAVOConfigurationDictionaryEquality {
    # Приватний helper: СТРУКТУРНЕ порівняння двох словників.
    #
    # Викликається лише з гілки колекцій Test-BRAVOConfigurationValue
    # Equality. Окремою функцією, а не інлайном: словник усередині
    # словника має порівнюватись тим самим правилом, і рекурсія тут
    # чесніша за копію умови в двох місцях.
    #
    # Ключі звіряються РЕГІСТРОНЕЗАЛЕЖНО: hashtable у PowerShell саме
    # такий, тож @{ Type = 'MODEL' } і @{ type = 'MODEL' } — один і той
    # самий словник, і оголосити їх різними означало б вигадати
    # відмінність, якої в конфігурації немає.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Left,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Right
    )

    $leftKeys = @(@($Left.Keys) | ForEach-Object { [string]$_ } | Sort-Object)
    $rightKeys = @(@($Right.Keys) | ForEach-Object { [string]$_ } | Sort-Object)
    if ($leftKeys.Count -ne $rightKeys.Count) { return $false }
    for ($k = 0; $k -lt $leftKeys.Count; $k++) {
        if ($leftKeys[$k] -ne $rightKeys[$k]) { return $false }
    }

    foreach ($key in $leftKeys) {
        $leftValue = $Left[$key]
        $rightValue = $Right[$key]
        $leftValueIsDictionary = $leftValue -is [System.Collections.IDictionary]
        $rightValueIsDictionary = $rightValue -is [System.Collections.IDictionary]
        if ($leftValueIsDictionary -or $rightValueIsDictionary) {
            if (-not ($leftValueIsDictionary -and $rightValueIsDictionary)) { return $false }
            if (-not (Test-BRAVOConfigurationDictionaryEquality -Left $leftValue -Right $rightValue)) {
                return $false
            }
            continue
        }
        if (-not (Test-BRAVOConfigurationValueEquality -Left $leftValue -Right $rightValue)) {
            return $false
        }
    }
    return $true
}

function Test-BRAVOConfigurationValueEquality {
    # Приватний helper: порівняння ЛИСТОВИХ значень.
    #
    # Масиви порівнюються поелементно, а не через -eq: у Windows
    # PowerShell 5.1 оператор -eq над масивом ліворуч виконує ФІЛЬТРАЦІЮ і
    # повертає підмножину, а не булеве значення — класична пастка, через
    # яку "порівняння" мовчки давало б хибний результат.
    [CmdletBinding()]
    [OutputType([bool])]
    param($Left, $Right)

    if ($null -eq $Left -and $null -eq $Right) { return $true }
    if ($null -eq $Left -or $null -eq $Right) { return $false }

    # Словник, що НЕ є [hashtable] (наприклад [ordered]), сюди дійти не
    # мав би: вузли-hashtable розкриває сам Compare-BRAVOConfigurationGraph.
    # Якщо дійшов — порівнювати його як колекцію не можна: перелічення
    # словника дає DictionaryEntry, і -eq порівняв би ПОСИЛАННЯ, мовчки
    # оголосивши різні словники рівними/нерівними навмання. Звітуємо про
    # відмінність: інструмент дельти покаже такий шлях оператору, замість
    # тихо його загубити.
    if (($Left -is [System.Collections.IDictionary]) -or ($Right -is [System.Collections.IDictionary])) {
        return $false
    }

    $leftIsCollection = ($Left -is [System.Collections.IEnumerable]) -and ($Left -isnot [string])
    $rightIsCollection = ($Right -is [System.Collections.IEnumerable]) -and ($Right -isnot [string])
    if ($leftIsCollection -ne $rightIsCollection) { return $false }

    if ($leftIsCollection) {
        $leftItems = @($Left)
        $rightItems = @($Right)
        if ($leftItems.Count -ne $rightItems.Count) { return $false }
        for ($i = 0; $i -lt $leftItems.Count; $i++) {
            $leftItem = $leftItems[$i]
            $rightItem = $rightItems[$i]
            # Словник УСЕРЕДИНІ колекції — окремий випадок від словника,
            # що прийшов сюди верхнім рівнем (блок вище). Верхній рівень
            # сюди дійти не мав би, і відмова там свідома. А от масив
            # словників — цілком штатна форма ефективної конфігурації
            # ($global:archiveDefinitions — масив із трьох hashtable), і
            # для неї "будь-який словник => різні" означало б, що два
            # ІДЕНТИЧНІ знімки завжди звітують відмінність. Порівнюємо
            # структурно; приховати справжню відмінність це не може —
            # звіряються і набір ключів, і кожне значення.
            $leftItemIsDictionary = $leftItem -is [System.Collections.IDictionary]
            $rightItemIsDictionary = $rightItem -is [System.Collections.IDictionary]
            if ($leftItemIsDictionary -or $rightItemIsDictionary) {
                if (-not ($leftItemIsDictionary -and $rightItemIsDictionary)) { return $false }
                if (-not (Test-BRAVOConfigurationDictionaryEquality -Left $leftItem -Right $rightItem)) {
                    return $false
                }
                continue
            }
            if (-not (Test-BRAVOConfigurationValueEquality -Left $leftItem -Right $rightItem)) {
                return $false
            }
        }
        return $true
    }

    # Рядки порівнюються з урахуванням регістру: шлях 'E:\ARCHIV' і
    # 'e:\archiv' — це та сама тека, але РІЗНИЙ site-запис, і оператор має
    # бачити, що значення на сервері записане інакше, ніж у дефолтах.
    if ($Left -is [string] -or $Right -is [string]) {
        return ([string]$Left -ceq [string]$Right)
    }

    return ($Left -eq $Right)
}

function Add-BRAVOConfigurationGraphDifference {
    # Приватний рекурсивний обхід. Приймає накопичувач ЯВНО (той самий
    # List[object] по всій рекурсії) замість повернення масиву через
    # `return` на кожному рівні.
    #
    # Це НЕ стильова вподобаність. Функція, що повертає ПОРОЖНІЙ масив,
    # у PowerShell не повертає нічого: `$nested = Compare-... ` дає
    # $null, а `@($nested)` перетворює його на масив з ОДНИМ елементом
    # $null — і кожна рекурсія у вузол БЕЗ відмінностей додавала
    # порожній запис у результат. Емпірично: порівняння canonical
    # defaults із самими собою давало 3 "відмінності" замість 0
    # (self-test Delta/IdenticalGraphsProduceNoDifference, CI 2026-09-14).
    # Той самий клас проблеми вже задокументований у цьому репозиторії —
    # Compare-BRAVOConfigurationGraphForParity у
    # selftest\BRAVO_SELF_TEST.ConfigLoader.ps1 ("порожні diff-рядки") —
    # і там застосовано те саме рішення.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$ReferenceConfiguration,
        [Parameter(Mandatory = $true)][hashtable]$CandidateConfiguration,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PathPrefix,
        [switch]$IncludeMissingInCandidate,
        # AllowEmptyCollection обов'язковий: Mandatory-параметр у PowerShell
        # неявно відхиляє ПОРОЖНЮ колекцію ("Cannot bind argument to
        # parameter 'Differences' because it is an empty collection"), а
        # накопичувач на першому виклику завжди порожній. Так само
        # AllowEmptyString вище для $PathPrefix: кореневий виклик передає ''.
        # (Порожня hashtable під це правило НЕ підпадає — canonical
        # -LocalOverrides @{} працює так з самого початку.)
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Differences
    )

    foreach ($key in @($CandidateConfiguration.Keys)) {
        $path = if ([string]::IsNullOrEmpty($PathPrefix)) { [string]$key } else { "$PathPrefix.$key" }
        $candidateValue = $CandidateConfiguration[$key]
        $referenceHasKey = $ReferenceConfiguration.Contains($key)

        # ПРЯМЕ присвоєння, а не $referenceValue = if (...) { ... } else { $null }:
        # присвоєння РЕЗУЛЬТАТУ statement-а проганяє значення через
        # output-pipeline, який РОЗГОРТАЄ колекції — порожній масив
        # перетворюється на $null, а одноелементний на сам елемент. Кандидат
        # при цьому читається прямим індексуванням і колекцією лишається,
        # тож порівнювались різні ТИПИ. Емпірично: порівняння canonical
        # defaults із самими собою давало рівно 3 хибні "відмінності" —
        # maintenanceSettings.Limits.ExcludedDrives (@()),
        # maintenanceSettings.Limits.MdFileSizeExclusions (@('...')) і
        # progressSettings.RobocopyProgressOptions (@('/ETA')), тобто ВСІ
        # порожні й одноелементні масиви дефолтів і жодного іншого
        # (CI 2026-09-14).
        $referenceValue = $null
        if ($referenceHasKey) { $referenceValue = $ReferenceConfiguration[$key] }

        $candidateIsNode = ($candidateValue -is [hashtable])
        $referenceIsNode = ($referenceValue -is [hashtable])

        if ($candidateIsNode -and $referenceIsNode) {
            Add-BRAVOConfigurationGraphDifference `
                -ReferenceConfiguration $referenceValue `
                -CandidateConfiguration $candidateValue `
                -PathPrefix $path `
                -IncludeMissingInCandidate:$IncludeMissingInCandidate `
                -Differences $Differences
            continue
        }

        if (-not $referenceHasKey) {
            # Вузол-hashtable, якого немає в еталоні, розкривається до
            # листів: оператору потрібен конкретний dot-path, а не
            # "десь у цьому блоці щось є".
            if ($candidateIsNode) {
                Add-BRAVOConfigurationGraphDifference `
                    -ReferenceConfiguration @{} `
                    -CandidateConfiguration $candidateValue `
                    -PathPrefix $path `
                    -IncludeMissingInCandidate:$IncludeMissingInCandidate `
                    -Differences $Differences
                continue
            }
            [void]$Differences.Add([pscustomobject]@{
                Path           = $path
                Kind           = 'OnlyInCandidate'
                ReferenceValue = $null
                CandidateValue = $candidateValue
            })
            continue
        }

        if ($candidateIsNode -ne $referenceIsNode) {
            # Форма вузла змінилась (скаляр там, де еталон має блок, або
            # навпаки) — це відмінність сама по собі, не привід рекурсувати.
            [void]$Differences.Add([pscustomobject]@{
                Path           = $path
                Kind           = 'Changed'
                ReferenceValue = $referenceValue
                CandidateValue = $candidateValue
            })
            continue
        }

        if (-not (Test-BRAVOConfigurationValueEquality -Left $referenceValue -Right $candidateValue)) {
            [void]$Differences.Add([pscustomobject]@{
                Path           = $path
                Kind           = 'Changed'
                ReferenceValue = $referenceValue
                CandidateValue = $candidateValue
            })
        }
    }

    if (-not $IncludeMissingInCandidate) { return }

    foreach ($key in @($ReferenceConfiguration.Keys)) {
        if ($CandidateConfiguration.Contains($key)) { continue }
        $path = if ([string]::IsNullOrEmpty($PathPrefix)) { [string]$key } else { "$PathPrefix.$key" }
        $referenceValue = $ReferenceConfiguration[$key]
        if ($referenceValue -is [hashtable]) {
            Add-BRAVOConfigurationGraphDifference `
                -ReferenceConfiguration $referenceValue `
                -CandidateConfiguration @{} `
                -PathPrefix $path `
                -IncludeMissingInCandidate `
                -Differences $Differences
            continue
        }
        [void]$Differences.Add([pscustomobject]@{
            Path           = $path
            Kind           = 'OnlyInReference'
            ReferenceValue = $referenceValue
            CandidateValue = $null
        })
    }
}

function Compare-BRAVOConfigurationGraph {
    <#
    .SYNOPSIS
        Порівнює граф-кандидат із еталонним графом і повертає ЛИСТОВІ
        відмінності у форматі dot-path.
    .DESCRIPTION
        Рекурсивно обходить обидва графи. Вузол-hashtable розкривається
        далі; усе інше вважається листом і порівнюється значенням.

        Kind:
          Changed          — лист є в обох графах, значення різні;
          OnlyInCandidate  — шляху немає в еталоні (для site-конфігу це
                             або невідомий ключ, або ключ новішої версії);
          OnlyInReference  — шлях є в еталоні, але відсутній у кандидаті.

        OnlyInReference за замовчуванням НЕ повертається: для задачі
        "що саме перевизначено на цьому сервері" відсутність ключа в
        site-конфігу означає "діє дефолт", а не відмінність. Вмикається
        прапорцем -IncludeMissingInCandidate, коли потрібна повна картина.

        Сам обхід виконує приватний Add-BRAVOConfigurationGraphDifference
        з явним накопичувачем; ця функція лише створює накопичувач і
        повертає детермінований результат.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$ReferenceConfiguration,
        [Parameter(Mandatory = $true)][hashtable]$CandidateConfiguration,
        [string]$PathPrefix = '',
        [switch]$IncludeMissingInCandidate
    )

    $differences = New-Object System.Collections.Generic.List[object]
    Add-BRAVOConfigurationGraphDifference `
        -ReferenceConfiguration $ReferenceConfiguration `
        -CandidateConfiguration $CandidateConfiguration `
        -PathPrefix $PathPrefix `
        -IncludeMissingInCandidate:$IncludeMissingInCandidate `
        -Differences $differences

    # Сортування за шляхом: вивід інструменту має бути детермінованим,
    # інакше два прогони на тому самому сервері дають різний порядок і
    # порівняти їх між собою неможливо.
    return @($differences.ToArray() | Sort-Object -Property Path)
}

Export-ModuleMember -Function @(
    'Compare-BRAVOConfigurationGraph'
)
