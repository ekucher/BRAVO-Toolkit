[CmdletBinding()]
param(
    [string]$Root
)

# Заборонені патерни: те, чого PSScriptAnalyzer не ловить взагалі або
# ловить лише як AST (пропускаючи входження всередині рядків). Кожен
# пункт — те, чого в цьому репозиторії немає й не повинно з'явитись.
#
# Чому окремий файл, а не крок `run:` у ci.yml: GitHub Actions записує
# вміст `run:` у тимчасовий .ps1 БЕЗ BOM, і Windows PowerShell 5.1
# читає його в системній ANSI-кодовій сторінці. Кирилична літера, чий
# другий байт UTF-8 потрапляє в діапазон 0x80-0x9F (наприклад "я" =
# D1 8F), декодується в control-символ і руйнує рядковий літерал —
# крок падає з ParserError ще до виконання. Файл у репозиторії має BOM,
# тому читається коректно, і його можна запустити локально.

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}

# Явна перевірка, а не тихий аналіз чужого каталогу: помилка на один
# рівень вгору вже траплялась при перенесенні цього скрипта і призвела
# до сканування всього Documents замість репозиторію.
if (-not (Test-Path -LiteralPath (Join-Path $Root 'BRAVO_SELF_TEST.ps1') -PathType Leaf)) {
    Write-Host "::error::Не схоже на корінь репозиторію BRAVO (немає BRAVO_SELF_TEST.ps1): $Root"
    exit 1
}

# ExecutionPolicy Bypass легітимний лише там, де скрипт перезапускає сам
# себе через UAC або описує завдання Планувальника (SECURITY.md розділ
# 4). Мета правила — заблокувати НОВІ файли з Bypass, а не переписати
# наявний механізм elevation.
#
# BRAVO_TASKS_DIAGNOSE.ps1 належить до тієї самої категорії "описує завдання
# Планувальника": він не запускає нічого з Bypass, а ПЕРЕВІРЯЄ, що вже
# зареєстровані завдання містять очікувані аргументи. Без цього рядка
# діагностика не могла б назвати те, чого шукає.
# BRAVO_SETUP.ps1 є installer-ом і генерує три ручні launcher-и. Self-test
# окремо вимагає, щоб Bypass існував лише всередині
# New-BRAVOManualLauncherContent і рівно в одному місці файла.
$bypassAllowlist = @(
    'BRAVO_SETUP.ps1',
    'BRAVO_TASKS_INSTALL.ps1',
    'BRAVO_TASKS_UNINSTALL.ps1',
    'BRAVO_TASKS_DIAGNOSE.ps1',
    'BRAVO_CREDENTIALS_SETUP.ps1',
    'BRAVO_SELF_TEST.ps1',
    # Домен-фрагменти self-test (dot-sourced з BRAVO_SELF_TEST.ps1, Фаза 2
    # модуляризації): несуть ТІ САМІ перевірки, що раніше жили в allowlisted
    # моноліті — Governance проганяє release-policy гейт дочірнім
    # powershell.exe, ManualLaunchers ПЕРЕВІРЯЄ, що Bypass у BRAVO_SETUP.ps1
    # обмежений рівно New-BRAVOManualLauncherContent, і містить очікуваний
    # рядок launcher-а. Нових ВИКОНУВАНИХ Bypass-місць не додано.
    'BRAVO_SELF_TEST.Governance.ps1',
    'BRAVO_SELF_TEST.ManualLaunchers.ps1',
    # ConfigLoader: Import-BravoConfiguration встановлює $global:ScriptVersion/
    # $global:BravoConfigurationMetadata та інший глобальний стан, небезпечний
    # для змішування з рештою self-test-прогону в тому самому процесі — той
    # самий ізольований дочірній powershell.exe патерн, що ManualLaunchers/
    # Governance вище. Нових ВИКОНУВАНИХ Bypass-місць не додано.
    'BRAVO_SELF_TEST.ConfigLoader.ps1',
    'BRAVO.Archive.Runtime.ps1',
    'BRAVO.Maintenance.Runtime.ps1',
    # Self-elevation (-Verb RunAs) і дочірній запуск BRAVO_HEALTH — той
    # самий патерн, що в Archive/Maintenance runtime.
    'BRAVO.DataRestore.Runtime.ps1',
    # Ручний E2E-матричний тест DataRestore: кожна комбінація — окремий
    # дочірній powershell.exe того самого довіреного комплекту (Runtime.ps1
    # робить рядковий exit, тому in-process виклик неможливий), той самий
    # елевований self-relaunch патерн, що BRAVO_SELF_TEST.ps1 і
    # BRAVO.DataRestore.Runtime.ps1 вище.
    'BRAVO.DataRestore.MatrixTest.psm1',
    # BRAVO.config описує завдання Планувальника (ArgumentsTemplate для
    # schtasks) — та сама категорія "описує завдання", що TASKS_INSTALL.
    # Config увійшов у скан заради правила legacy-webhook нижче.
    'BRAVO.config'
)

$forbiddenRules = @(
    @{
        Name = 'Invoke-Expression / iex'
        Pattern = '(?i)\b(Invoke-Expression|iex)\s'
        Allowlist = @()
    },
    @{
        Name = 'Мережеве завантаження коду'
        Pattern = '(?i)(DownloadString|DownloadFile|Net\.WebClient)'
        Allowlist = @()
    },
    @{
        Name = 'Секрет в аргументах процесу'
        Pattern = '(?i)-ArgumentList[^\r\n]*\$(password|secret|apiKey|token)\b'
        Allowlist = @()
    },
    @{
        Name = 'ExecutionPolicy Bypass поза installer/task definitions'
        Pattern = '(?i)ExecutionPolicy\s+Bypass'
        Allowlist = $bypassAllowlist
    },
    @{
        # 5.2.1: legacy provider-wide webhook-и виведені з активного
        # контракту — Discord/Slack працюють лише через канальні
        # GENERAL/ALERTS targets. Правило блокує ПОВЕРНЕННЯ legacy-літералів
        # в активний runtime/config/setup код (коментарі пропускаються
        # загальним фільтром вище; історичні CHANGELOG/evidence-docs не
        # входять у analyzable-набір).
        # Allowlist: BRAVO_DRY_RUN.ps1 — міграційна діагностика legacy-only
        # інсталяції (читає запис лише щоб пояснити FAIL, runtime resolver
        # його не використовує); BRAVO_SELF_TEST.ps1 — негативні регресії
        # (доводять, що навіть наявний legacy-запис ігнорується).
        Name = 'Legacy provider-wide webhook target (BRAVO_DISCORD_URL/BRAVO_SLACK_URL)'
        Pattern = 'BRAVO_(DISCORD|SLACK)_URL'
        Allowlist = @(
            'BRAVO_DRY_RUN.ps1',
            'BRAVO_SELF_TEST.ps1'
        )
    }
)

. (Join-Path $PSScriptRoot 'BRAVOAnalyzableFiles.ps1')
$files = @(Get-BRAVOAnalyzableFile -Root $Root)

# Активні конфігураційні файли — не .ps1/.psm1/.psd1, тому поза
# Get-BRAVOAnalyzableFile, але legacy webhook-літерали (та інші заборонені
# патерни) не мають права з'являтись і в них.
foreach ($configFileName in @('BRAVO.config', 'BRAVO.local.config.example')) {
    $configFilePath = Join-Path $Root $configFileName
    if (Test-Path -LiteralPath $configFilePath -PathType Leaf) {
        $files += @(Get-Item -LiteralPath $configFilePath)
    }
}

$violationCount = 0
foreach ($file in $files) {
    # Сам цей скрипт містить заборонені патерни у визначеннях правил
    # (регулярні вирази), тому інакше спрацював би сам на себе.
    if ($file.FullName -eq $PSCommandPath) {
        continue
    }

    $lines = [IO.File]::ReadAllLines($file.FullName)
    for ($index = 0; $index -lt $lines.Length; $index++) {
        $line = $lines[$index]

        # Рядки-коментарі не є виконуваним кодом: у репозиторії є
        # приклади команд запуску в коментарях, і сам цей файл описує
        # заборонені патерни в тексті правил.
        if ($line.TrimStart().StartsWith('#')) {
            continue
        }

        foreach ($rule in $forbiddenRules) {
            if ($line -notmatch $rule.Pattern) {
                continue
            }
            if ($rule.Allowlist -contains $file.Name) {
                continue
            }
            Write-Host "::error file=$($file.FullName),line=$($index + 1)::Заборонений патерн ($($rule.Name)): $($line.Trim())"
            $violationCount++
        }
    }
}

# Реальні ідентифікатори майданчиків (5.2.6): назви установ, імена
# хостів, код ЄДРПОУ й IP-адреси, які раніше потрапляли в пакет, а в
# документах і коментарях мають бути лише заглушки (HOST-NN, SITE-X,
# 00000000, адреси на кшталт 10.0.0.10 і 203.0.113.10 з RFC 5737).
#
# На відміну від правил вище, тут перевіряються ВСІ текстові файли
# комплекту, включно з коментарями, Markdown і CHANGELOG: саме там ці
# значення й жили. Порівняння — за SHA-256 токена у верхньому регістрі,
# щоб сам guard не відтворював ідентифікатори відкритим текстом. Це не
# криптографічний захист (короткі значення на кшталт IP перебираються),
# а лише спосіб не публікувати їх повторно.
$identifierHashes = @(
    '1ab1eaf0c00ddfc07b23747c0598fd55d11da39ae76c67934f7023c4136e299f',
    '9dc17d569688fb0ae048296578242ffec8ae113bd0d50fcded431eb9acbfa5ba',
    'b8532627fcff3d7500ce7ac50f9cfdf5fa18c7f6ef9d09dfd90cb90bc7a2b57a',
    '39ff14436524387c48287e261d8b56cefa0ec72ca3eafba6a0940b86694cb81d',
    'bd7ba0a674d050e6eb0614fc255c33f9728e0f0dfe89aab7aa64c9d3d4f16294',
    '12bc4e3b2251a23e86f98bae3185a4fde571bb48a5f460bd04a7bbc048ee3311',
    '18b6173117f96473dff5fe8ce2d1cc21d9100fddf26c8e20ebc2e2d26c5f4cb4',
    '4ca59d9350b25fb41d0eefc173ad1d25beebf3c0ba08edd7bc43d9572704e35b',
    '46180348b5bfa63d8b853a1bf24ec868c3c9b25c65546cf5d0a3e400bbd69074',
    'cd2f9047b9c468b3a9abf82b512882badf2f6361757d35cdc5e94be3c8dc864d',
    '9bf002250682ac24019f79f83d132465b6472f3651ea2c2b4cc837beb497048c',
    '2bbf8651ec56454157be46008b13dc34187cae5e0741877fbc2a78260ca87cef',
    'fb8c7aa657190b3acbb7d45ecb4415a9183942cd4809d7301d74f953ca65d5ec',
    'e66bd04919639ce897072f33b028e15806911363aee1ba5b7b0b9766b3e9e72e',
    '52287c6b27dc35b557c49a2abf6cc8f9e98acede38026b6fa2ecd29917a58ca4',
    '2b803d29504dfed63db9de3de9d5b64f7601263b73e77c7bf542078425275f17',
    '1ba666fe38422f7a0e306fdf157943f4aec05b614a06732356da1cf046800f1c',
    '61f0a4f429fa728eb7136ce534c3db098d1d47644a5f1123161a50537b39262a',
    '7f5d56ba132159ce1acbe8187db26b750039f41c4e6ec20aca0eda9583b77b68'
)
$identifierHashSet = @{}
foreach ($identifierHash in $identifierHashes) {
    $identifierHashSet[$identifierHash] = $true
}

# Токен — літери, цифри, '_' і '-', з'єднані крапками (IP, ім'я хоста з
# доменом). Перевіряється і весь токен, і кожна його частина між
# крапками.
$identifierTokenPattern = '[\p{L}\p{Nd}_\-]+(?:\.[\p{L}\p{Nd}_\-]+)*'
$identifierSha256 = [Security.Cryptography.SHA256]::Create()
$identifierTokenCache = @{}
$identifierFileCount = 0
$identifierRoot = (Resolve-Path -LiteralPath $Root).Path
$identifierFiles = @(Get-ChildItem -LiteralPath $identifierRoot -Recurse -Force -File | Where-Object {
        $relativeParts = $_.FullName.Substring($identifierRoot.Length).TrimStart('\', '/') -split '[\\/]'
        -not ($relativeParts -contains '.git') -and -not ($relativeParts -contains 'LOGS') -and $_.Length -le 16MB
    })
foreach ($file in $identifierFiles) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    # Бінарні файли (Tools\*.exe тощо) не є текстом комплекту.
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) {
        continue
    }
    $identifierFileCount++
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $lines = $text -split "`r?`n"
    for ($index = 0; $index -lt $lines.Length; $index++) {
        foreach ($tokenMatch in [regex]::Matches($lines[$index], $identifierTokenPattern)) {
            $candidates = @($tokenMatch.Value) + @($tokenMatch.Value.Split('.'))
            foreach ($candidate in $candidates) {
                $normalized = $candidate.ToUpperInvariant()
                if (-not $identifierTokenCache.ContainsKey($normalized)) {
                    $hashBytes = $identifierSha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))
                    $identifierTokenCache[$normalized] = (-join ($hashBytes | ForEach-Object { $_.ToString('x2') }))
                }
                if ($identifierHashSet.ContainsKey($identifierTokenCache[$normalized])) {
                    # Значення не виводиться: лише файл, рядок і позиція.
                    Write-Host "::error file=$($file.FullName),line=$($index + 1)::Реальний ідентифікатор майданчика (позиція $($tokenMatch.Index + 1)): замініть заглушкою (HOST-NN, SITE-X, 00000000, RFC 5737)."
                    $violationCount++
                    break
                }
            }
        }
    }
}
$identifierSha256.Dispose()
Write-Host "Реальні ідентифікатори майданчиків: перевірено текстових файлів: $identifierFileCount."

if ($violationCount -gt 0) {
    Write-Host "::error::Знайдено заборонених патернів: $violationCount. Ці конструкції не мають легітимного застосування в цьому репозиторії."
    exit 1
}

Write-Host "Заборонені патерни: не знайдено (перевірено файлів: $($files.Count))."
exit 0
