[CmdletBinding()]
param(
    [string]$RuntimeRoot = 'C:\Program Files\BRAVO-Toolkit',
    [string]$ConfigRoot,
    [string]$ConfigPath,
    [string]$OutputPath,
    [switch]$IncludeMissingInCandidate
)

# Інструмент дельти site-конфігурації (#154, задача B0).
#
# ЩО ВІН ВІДПОВІДАЄ: "що саме на ЦЬОМУ сервері перевизначено в BRAVO.config
# відносно канонічних дефолтів комплекту". Сьогодні цієї відповіді немає ні
# в кого: BRAVO.config епохи 5.2.0 мовчки затінює будь-яке покращення
# дефолтів, і побачити це можна лише побайтовим порівнянням двох файлів на
# 800 рядків.
#
# ЩО ВІН НІКОЛИ НЕ РОБИТЬ:
#   * не змінює жодного файлу на сервері — вивід іде в консоль, і лише за
#     явним -OutputPath записується у ВКАЗАНИЙ файл (наявний файл за цим
#     шляхом не перезаписується: скрипт відмовляє);
#   * не чіпає BRAVO.config, BRAVO.local.config і LOGS\;
#   * не виконує міграцію (це задача B5) — він готує її вхідні дані.
#
# ПОБІЧНИЙ ЕФЕКТ: щоб зчитати raw-значення, BRAVO.config доводиться
# ВИКОНАТИ (це досі PowerShell-скрипт) — тим самим canonical читачем, яким
# його виконує звичайне завантаження (Read-BRAVOLegacyPrimaryRawOverrides).
# Тому інструмент запускають окремим процесом і він нічого не повертає у
# виклик іншого скрипта.

$ErrorActionPreference = 'Stop'

# Операторський інструмент: помилка має читатися одним рядком, а не
# стек-дампом PowerShell.
try {
    if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
        throw "Не знайдено каталог комплекту: $RuntimeRoot"
    }
    $resolvedRuntimeRoot = [System.IO.Path]::GetFullPath($RuntimeRoot)

    $resolvedConfigRoot = if ([string]::IsNullOrWhiteSpace($ConfigRoot)) {
        $resolvedRuntimeRoot
    } else {
        [System.IO.Path]::GetFullPath($ConfigRoot)
    }

    $resolvedConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        Join-Path $resolvedConfigRoot 'BRAVO.config'
    } else {
        [System.IO.Path]::GetFullPath($ConfigPath)
    }

    if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        # Відсутній BRAVO.config — не помилка комплекту (файл опційний з
        # 5.3.0), але для ЦЬОГО інструменту це порожній вхід: порівнювати
        # нема чого, і мовчазний порожній вивід оператор прочитав би як
        # "відмінностей немає".
        throw "Не знайдено BRAVO.config за шляхом '$resolvedConfigPath' — на цьому сервері site-дельти в primary-шарі немає (діють канонічні дефолти + BRAVO.local.config)."
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
        if (Test-Path -LiteralPath $resolvedOutputPath) {
            throw "Файл '$resolvedOutputPath' уже існує — інструмент нічого не перезаписує. Вкажіть інший -OutputPath."
        }
    } else {
        $resolvedOutputPath = $null
    }

    $loaderPath = Join-Path $resolvedRuntimeRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $loaderPath -PathType Leaf)) {
        throw "Не знайдено BRAVO_CONFIG_LOADER.ps1 у '$resolvedRuntimeRoot' — перевірте -RuntimeRoot."
    }
    . $loaderPath

    Import-Module -Name (Join-Path $resolvedRuntimeRoot 'modules\BRAVO.Configuration\BRAVO.Configuration.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $resolvedRuntimeRoot 'modules\BRAVO.Configuration\BRAVO.Configuration.Delta.psd1') -Force -ErrorAction Stop
    # Рендеринг літералів — canonical реалізація Configurator-а; другої
    # копії правил екранування в комплекті бути не повинно.
    Import-Module -Name (Join-Path $resolvedRuntimeRoot 'modules\BRAVO.Configurator\BRAVO.Configurator.Effective.psd1') -Force -ErrorAction Stop

    # BRAVO.config викликає Resolve-BRAVOInstallationDiscovery — модуль має
    # бути в scope ДО виконання самого config-скрипта (той самий порядок, що
    # й в Import-BravoConfiguration).
    $discoveryModulePath = Join-Path $resolvedRuntimeRoot 'modules\BRAVO.Discovery\BRAVO.Discovery.psd1'
    if (Test-Path -LiteralPath $discoveryModulePath -PathType Leaf) {
        Import-Module -Name $discoveryModulePath -Force -ErrorAction Stop
    }

    $defaultConfiguration = Get-BRAVODefaultConfiguration
    $primaryRawOverrides = Read-BRAVOLegacyPrimaryRawOverrides `
        -ConfigPath $resolvedConfigPath `
        -ConfigRoot $resolvedConfigRoot `
        -RuntimeRoot $resolvedRuntimeRoot

    $differences = @(Compare-BRAVOConfigurationGraph `
        -ReferenceConfiguration $defaultConfiguration `
        -CandidateConfiguration $primaryRawOverrides `
        -IncludeMissingInCandidate:$IncludeMissingInCandidate)

    # Шляхи, які вже перевизначені в BRAVO.local.config, позначаються
    # окремо: переносити їх ще раз не потрібно, а мовчки видати їх у
    # списку "додайте це в site-файл" означало б штовхати оператора до
    # дубльованого запису.
    $localOverrideState = Read-BRAVOLocalConfigurationOverrides -ConfigDirectory $resolvedConfigRoot -RuntimeRoot $resolvedRuntimeRoot
    $localOverridePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($localKey in @($localOverrideState.Overrides.Keys)) {
        [void]$localOverridePaths.Add([string]$localKey)
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("# BRAVO.local.config — site-дельта, згенеровано $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$lines.Add("# Джерело: $resolvedConfigPath")
    [void]$lines.Add("# Комплект: $resolvedRuntimeRoot")
    [void]$lines.Add('#')
    [void]$lines.Add('# Перед перенесенням звірте кожен рядок: наявність значення в BRAVO.config')
    [void]$lines.Add('# не доводить, що воно потрібне саме цій установі — частина відмінностей')
    [void]$lines.Add('# може бути застарілою копією дефолтів попередньої версії комплекту.')
    [void]$lines.Add('#')
    [void]$lines.Add('# Фаза застосування (sftpDirectories, backupMonitoring, schedulerSettings —')
    [void]$lines.Add('# фаза 2) описана в BRAVO.local.config.example; похідні поля туди не')
    [void]$lines.Add('# переносять — перевизначають первинні.')
    [void]$lines.Add('@{')

    $emitted = 0
    $skippedLocal = 0
    $unrepresentable = 0

    foreach ($difference in $differences) {
        # Функція, що повертає порожній масив, у PowerShell не повертає
        # нічого: @(<нічого>) дає @(), але @($null) — масив з ОДНИМ
        # елементом. Явна перевірка тут коштує один рядок, а без неї
        # звернення до .Path під Set-StrictMode впало б винятком.
        if ($null -eq $difference) { continue }

        $path = [string]$difference.Path

        if ($difference.Kind -eq 'OnlyInReference') {
            [void]$lines.Add("    # [немає в BRAVO.config, діє дефолт] '$path'")
            continue
        }

        # Зміна ФОРМИ вузла (блок там, де дефолт має скаляр, або навпаки)
        # не має коректного dot-path-подання: це зміна формату конфігурації,
        # а не site-значення. Мовчки пропустити її не можна.
        if ($difference.CandidateValue -is [System.Collections.IDictionary]) {
            [void]$lines.Add("    # [УВАГА: форма вузла відрізняється від канонічної — перенесіть вручну] '$path'")
            $unrepresentable++
            continue
        }

        # Явний try/catch зі змінною, а не "$literal = try { } catch { }":
        # присвоєння результату try/catch — не гарантована форма у Windows
        # PowerShell 5.1, і операторський інструмент не місце для перевірки
        # межових можливостей парсера.
        $literal = $null
        $literalFailure = $null
        try {
            $literal = ConvertTo-BRAVOConfiguratorPowerShellLiteral -Value $difference.CandidateValue
        } catch {
            $literalFailure = $_.Exception.Message
        }
        if ($null -ne $literalFailure) {
            [void]$lines.Add("    # [УВАГА: значення не серіалізується в data-only літерал] '$path': $literalFailure")
            $unrepresentable++
            continue
        }

        $marker = if ($difference.Kind -eq 'OnlyInCandidate') {
            '  # НЕВІДОМИЙ канонічним дефолтам ключ — звірте назву перед перенесенням'
        } else {
            ''
        }

        if ($localOverridePaths.Contains($path)) {
            [void]$lines.Add("    # [уже є в BRAVO.local.config] '$path' = $literal")
            $skippedLocal++
            continue
        }

        [void]$lines.Add("    '$path' = $literal$marker")
        $emitted++
    }

    [void]$lines.Add('}')

    $text = [string]::Join([Environment]::NewLine, $lines.ToArray())
    Write-Output $text

    Write-Output ''
    Write-Output "[INFO] Відмінностей до перенесення: $emitted"
    Write-Output "[INFO] Уже є в BRAVO.local.config: $skippedLocal"
    if ($unrepresentable -gt 0) {
        Write-Output "[WARN] Потребують ручного перенесення: $unrepresentable"
    }

    if ($null -ne $resolvedOutputPath) {
        Set-Content -LiteralPath $resolvedOutputPath -Value $text -Encoding UTF8 -ErrorAction Stop
        Write-Output "[INFO] Записано: $resolvedOutputPath"
    }
} catch {
    # $ErrorActionPreference скидається ДО Write-Error: при 'Stop' сам
    # Write-Error кинув би виняток і exit 1 нижче ніколи б не виконався —
    # оператор отримав би стек-дамп замість коду завершення.
    $ErrorActionPreference = 'Continue'
    Write-Error $_.Exception.Message
    exit 1
}
