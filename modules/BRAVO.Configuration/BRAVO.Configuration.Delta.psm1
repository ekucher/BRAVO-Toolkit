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
            if (-not (Test-BRAVOConfigurationValueEquality -Left $leftItems[$i] -Right $rightItems[$i])) {
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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$ReferenceConfiguration,
        [Parameter(Mandatory = $true)][hashtable]$CandidateConfiguration,
        [string]$PathPrefix = '',
        [switch]$IncludeMissingInCandidate
    )

    $differences = New-Object System.Collections.Generic.List[object]

    foreach ($key in @($CandidateConfiguration.Keys)) {
        $path = if ([string]::IsNullOrEmpty($PathPrefix)) { [string]$key } else { "$PathPrefix.$key" }
        $candidateValue = $CandidateConfiguration[$key]
        $referenceHasKey = $ReferenceConfiguration.Contains($key)
        $referenceValue = if ($referenceHasKey) { $ReferenceConfiguration[$key] } else { $null }

        $candidateIsNode = ($candidateValue -is [hashtable])
        $referenceIsNode = ($referenceValue -is [hashtable])

        if ($candidateIsNode -and $referenceIsNode) {
            $nested = Compare-BRAVOConfigurationGraph `
                -ReferenceConfiguration $referenceValue `
                -CandidateConfiguration $candidateValue `
                -PathPrefix $path `
                -IncludeMissingInCandidate:$IncludeMissingInCandidate
            foreach ($item in @($nested)) { [void]$differences.Add($item) }
            continue
        }

        if (-not $referenceHasKey) {
            # Вузол-hashtable, якого немає в еталоні, розкривається до
            # листів: оператору потрібен конкретний dot-path, а не
            # "десь у цьому блоці щось є".
            if ($candidateIsNode) {
                $nested = Compare-BRAVOConfigurationGraph `
                    -ReferenceConfiguration @{} `
                    -CandidateConfiguration $candidateValue `
                    -PathPrefix $path `
                    -IncludeMissingInCandidate:$IncludeMissingInCandidate
                foreach ($item in @($nested)) { [void]$differences.Add($item) }
                continue
            }
            [void]$differences.Add([pscustomobject]@{
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
            [void]$differences.Add([pscustomobject]@{
                Path           = $path
                Kind           = 'Changed'
                ReferenceValue = $referenceValue
                CandidateValue = $candidateValue
            })
            continue
        }

        if (-not (Test-BRAVOConfigurationValueEquality -Left $referenceValue -Right $candidateValue)) {
            [void]$differences.Add([pscustomobject]@{
                Path           = $path
                Kind           = 'Changed'
                ReferenceValue = $referenceValue
                CandidateValue = $candidateValue
            })
        }
    }

    if ($IncludeMissingInCandidate) {
        foreach ($key in @($ReferenceConfiguration.Keys)) {
            if ($CandidateConfiguration.Contains($key)) { continue }
            $path = if ([string]::IsNullOrEmpty($PathPrefix)) { [string]$key } else { "$PathPrefix.$key" }
            $referenceValue = $ReferenceConfiguration[$key]
            if ($referenceValue -is [hashtable]) {
                $nested = Compare-BRAVOConfigurationGraph `
                    -ReferenceConfiguration $referenceValue `
                    -CandidateConfiguration @{} `
                    -PathPrefix $path `
                    -IncludeMissingInCandidate
                foreach ($item in @($nested)) { [void]$differences.Add($item) }
                continue
            }
            [void]$differences.Add([pscustomobject]@{
                Path           = $path
                Kind           = 'OnlyInReference'
                ReferenceValue = $referenceValue
                CandidateValue = $null
            })
        }
    }

    # Сортування за шляхом: вивід інструменту має бути детермінованим,
    # інакше два прогони на тому самому сервері дають різний порядок і
    # порівняти їх між собою неможливо.
    return @($differences.ToArray() | Sort-Object -Property Path)
}

Export-ModuleMember -Function @(
    'Compare-BRAVOConfigurationGraph'
)
