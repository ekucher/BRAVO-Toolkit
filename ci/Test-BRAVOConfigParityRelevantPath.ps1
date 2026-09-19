function Get-BRAVOConfigParityRelevantPathPattern {
    <#
        Канонічний перелік шляхів конфігураційного пайплайна, зміна яких
        вимагає прогону ci\Test-BRAVOConfigFoundationParity.ps1.

        ЧОМУ ЦЕ ОКРЕМИЙ ФАЙЛ, А НЕ СПИСОК `paths:` У WORKFLOW. Фільтр
        `paths:` у GitHub Actions задається на рівні workflow, і його
        наслідок — workflow ВЗАГАЛІ НЕ ЗАПУСКАЄТЬСЯ для PR, що не зачіпає
        перелічені шляхи. Для звичайної задачі це економія; для
        REQUIRED status check це дефект: branch protection чекає на
        статус, який ніхто не створить, і PR лишається заблокованим
        назавжди. Тому рішення "релевантно / не релевантно" перенесено
        ВСЕРЕДИНУ задачі, а перелік шляхів став кодом, який можна
        перевірити self-test-ом на синтетичних наборах.

        Формат елемента:
          * "шлях/до/файлу"     — точний збіг;
          * "каталог/**"        — будь-який файл усередині каталогу.

        Шляхи записані так, як їх друкує `git diff --name-only`:
        відносно кореня репозиторію, через "/".
    #>
    [CmdletBinding()]
    param()

    # Порядок елементів не має значення для рішення; він обраний так,
    # щоб перелік читався від продакшн-коду до самого інструмента.
    return @(
        # Канонічний завантажувач — головний предмет паритету.
        'BRAVO_CONFIG_LOADER.ps1'

        # Legacy primary-шар. Він ще є фікстурою самого harness-а, тож
        # його зміна змінює результат паритету. Рядок лишається, доки
        # файл існує (#154, B4 частина 2 прибирає його з пакета).
        'BRAVO.config'

        # Каталог дозволених override-шляхів site-шару — канонічне
        # джерело істини для того, що harness взагалі має порівнювати.
        'BRAVO.local.config.example'

        # Доменні модулі конфігурації та Configurator-а.
        'modules/BRAVO.Configuration/**'
        'modules/BRAVO.Configurator/**'

        # Сам harness і сама логіка рішення: зміна будь-якого з них
        # мусить перевірятися тим самим прогоном, інакше перевірку можна
        # мовчки знешкодити правкою її власного коду.
        'ci/Test-BRAVOConfigFoundationParity.ps1'
        'ci/Test-BRAVOConfigParityRelevantPath.ps1'
        '.github/workflows/config-parity.yml'
    )
}

function Test-BRAVOConfigParityRelevantPath {
    <#
        Вирішує, чи зачіпає набір змінених файлів конфігураційний
        пайплайн.

        Повертає об'єкт, а не лише [bool], щоб задача CI могла надрукувати
        ПРИЧИНУ рішення: "не релевантно" без переліку розглянутих шляхів
        неможливо відрізнити від "перелік порожній через помилку".

        Порожній набір змінених файлів — це НЕ релевантно. Викликач, який
        не зміг визначити набір, не повинен передавати порожній масив:
        нездатність визначити зміни означає "запускати", і це рішення
        належить викликачу, а не цій функції.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ChangedPath,

        # Дозволяє self-test-у перевірити саму логіку зіставлення на
        # синтетичному переліку, не прив'язуючись до канонічного.
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Pattern
    )

    $effectivePattern = @($Pattern)
    if ($effectivePattern.Count -eq 0) {
        $effectivePattern = @(Get-BRAVOConfigParityRelevantPathPattern)
    }

    # Нормалізація обох боків до однієї форми: git друкує "/", Windows і
    # копіпаста з провідника дають "\", а "./" трапляється у виводі
    # деяких інструментів. Порівняння регістронезалежне — файлова
    # система цільової платформи теж.
    $normalize = {
        param([string]$Value)
        if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
        $normalized = $Value.Trim().Replace('\', '/')
        while ($normalized.StartsWith('./')) {
            $normalized = $normalized.Substring(2)
        }
        $normalized = $normalized.TrimStart('/')
        if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }
        return $normalized
    }

    $normalizedChanged = @(
        @($ChangedPath) |
            ForEach-Object { & $normalize $_ } |
            Where-Object { $null -ne $_ }
    )

    $matchedPath = New-Object System.Collections.Generic.List[string]

    foreach ($candidate in $normalizedChanged) {
        foreach ($rawPattern in $effectivePattern) {
            $normalizedPattern = & $normalize $rawPattern
            if ($null -eq $normalizedPattern) { continue }

            $isMatch = $false
            if ($normalizedPattern.EndsWith('/**')) {
                # Префікс каталогу. Обов'язково З роздільником: інакше
                # "modules/BRAVO.Configuration/**" зіставлявся б і з
                # "modules/BRAVO.ConfigurationBackup/x.psm1".
                $directoryPrefix = $normalizedPattern.Substring(0, $normalizedPattern.Length - 2)
                $isMatch = $candidate.StartsWith($directoryPrefix, [StringComparison]::OrdinalIgnoreCase)
            } else {
                $isMatch = [string]::Equals($candidate, $normalizedPattern, [StringComparison]::OrdinalIgnoreCase)
            }

            if ($isMatch) {
                if (-not $matchedPath.Contains($candidate)) {
                    [void]$matchedPath.Add($candidate)
                }
                break
            }
        }
    }

    # @() навколо кожної колекції свідоме: споживач звертається до
    # .Count, а 0-елементний результат, що розгорнувся у $null, валить
    # .Count із PropertyNotFoundException (той самий клас дефекту, що
    # #212). Унарної коми тут НЕ треба й не можна: у літералі хештаблиці
    # розгортання не відбувається, тож ,@() додала б зайвий рівень
    # вкладеності, і .Count порожньої колекції дорівнював би 1.
    return [pscustomobject]@{
        IsRelevant     = ($matchedPath.Count -gt 0)
        MatchedPath    = @($matchedPath.ToArray())
        ConsideredPath = @($normalizedChanged)
        Pattern        = @($effectivePattern)
    }
}
