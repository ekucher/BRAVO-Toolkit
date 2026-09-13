[CmdletBinding()]
param(
    [string]$RuntimeRoot = 'C:\Program Files\BRAVO-Toolkit',
    [string]$Tag = 'v5.2.4',
    [string]$ZipPath,
    [string]$StagingRoot = 'C:\Temp\BRAVO_INSTALL',
    [switch]$SeedLocalConfig,
    [switch]$SkipSelfTest,
    [switch]$Force
)

# Проміжний помічник ЧИСТОЇ інсталяції stable-релізу BRAVO-Toolkit на ОДИН
# сервер: завантажити артефакт релізу, звірити SHA-256, розгорнути в порожній
# каталог і довести цілісність комплекту.
#
# Це НЕ P3.2a (ROADMAP.md) і не оновлення. Для переходу 5.2.3 -> 5.2.4
# використовуйте Update-BRAVOServer.ps1; для переходу з лінії 4.2 —
# docs\BRAVO_42_TO_524_MIGRATION_20260913.md (цей скрипт виконує її розділ 6).
#
# ЩО ВІН НАВМИСНО НЕ РОБИТЬ:
#   * не створює і не читає credentials — це інтерактивний BRAVO_SETUP.ps1;
#   * не реєструє завдання Планувальника;
#   * не редагує BRAVO.config — site-відмінності належать BRAVO.local.config;
#   * не видаляє нічого поза власним staging-каталогом;
#   * не видаляє розгорнуті файли після провалу гейта: провалена перевірка
#     цілісності — це доказ, а не сміття.

$ErrorActionPreference = 'Stop'

# Операторський інструмент: помилка має читатися одним рядком, а не
# стек-дампом PowerShell. Код завершення 1 = скрипт зупинився сам.
trap {
    Write-Host ''
    Write-Host ('ЗУПИНЕНО: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
Set-StrictMode -Version 2.0

function Write-Step { param([string]$T) Write-Host ''; Write-Host ('=== ' + $T) -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host ('  [OK]    ' + $T) -ForegroundColor Green }
function Write-Bad  { param([string]$T) Write-Host ('  [FAIL]  ' + $T) -ForegroundColor Red }
function Write-Note { param([string]$T) Write-Host ('  [..]    ' + $T) }
function Write-Warn2{ param([string]$T) Write-Host ('  [УВАГА] ' + $T) -ForegroundColor Yellow }

$targetVersion = $Tag.TrimStart('v')

# --- 0. Передумови ----------------------------------------------------------

Write-Step '0. Передумови'

$isElevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) {
    throw 'Потрібні права адміністратора: запустіть PowerShell від імені адміністратора.'
}
Write-Ok 'запущено з піднятими правами'

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw ('Потрібен Windows PowerShell 5.1 (знайдено ' + $PSVersionTable.PSVersion.ToString() + ').')
}
Write-Ok ('PowerShell ' + $PSVersionTable.PSVersion.ToString())

# Порожній цільовий каталог — умова чистої інсталяції. Наявний комплект
# оновлюється іншим інструментом, і мовчки копіювати поверх нього не можна:
# у чистої інсталяції інший контракт (нові LOGS, новий стан, новий config).
$targetExists = Test-Path -LiteralPath $RuntimeRoot
if ($targetExists) {
    if (Test-Path -LiteralPath (Join-Path $RuntimeRoot 'VERSION.json') -PathType Leaf) {
        $existing = (Get-Content -LiteralPath (Join-Path $RuntimeRoot 'VERSION.json') -Raw -Encoding UTF8 |
            ConvertFrom-Json)
        throw ('У ' + $RuntimeRoot + ' уже встановлено BRAVO ' + $existing.packageVersion +
            '. Для оновлення використовуйте Update-BRAVOServer.ps1, для переходу з 4.2 — ' +
            'процедуру міграції (інсталяція в ІНШИЙ каталог).')
    }
    $content = @(Get-ChildItem -LiteralPath $RuntimeRoot -Force -ErrorAction SilentlyContinue)
    if ($content.Count -gt 0 -and -not $Force) {
        throw ('Каталог не порожній: ' + $RuntimeRoot + ' (' + $content.Count +
            ' об''єктів). Оберіть інший каталог або вкажіть -Force, якщо вміст справді сторонній.')
    }
    Write-Ok ('цільовий каталог існує і придатний: ' + $RuntimeRoot)
} else {
    Write-Note ('цільовий каталог буде створено: ' + $RuntimeRoot)
}

# SYSTEM виконуватиме ці файли, тому каталог не повинен бути доступним на
# запис звичайним користувачам (README §14). ACL-hardening виконує
# BRAVO_TASKS_INSTALL за schedulerSettings.RequireProtectedRuntime; тут лише
# попередження про очевидно невдалий вибір місця.
$programFiles = [Environment]::GetFolderPath('ProgramFiles')
if (-not $RuntimeRoot.StartsWith($programFiles, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Warn2 ('каталог поза ' + $programFiles + ': переконайтесь, що звичайні користувачі ' +
        'не мають права запису — комплект виконується від SYSTEM.')
}

# --- 1. Артефакт ------------------------------------------------------------

Write-Step ('1. Артефакт ' + $Tag)

if (-not (Test-Path -LiteralPath $StagingRoot)) {
    [void](New-Item -ItemType Directory -Path $StagingRoot -Force)
}
$downloadDir = Join-Path $StagingRoot 'download'

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    if (Test-Path -LiteralPath $downloadDir) { Remove-Item -LiteralPath $downloadDir -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $downloadDir -Force)
    # TLS 1.2 не є дефолтом на Windows Server 2016.
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $zipName = 'BRAVO-Toolkit-' + $targetVersion + '.zip'
    $base = 'https://github.com/ekucher/BRAVO-Toolkit/releases/download/' + $Tag + '/'
    $ZipPath = Join-Path $downloadDir $zipName
    Write-Note ('завантаження ' + $base + $zipName)
    Invoke-WebRequest -Uri ($base + $zipName) -OutFile $ZipPath -UseBasicParsing
    Invoke-WebRequest -Uri ($base + $zipName + '.sha256') -OutFile ($ZipPath + '.sha256') -UseBasicParsing
} else {
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        throw ('Архів не знайдено: ' + $ZipPath)
    }
    Write-Note ('локальний архів: ' + $ZipPath)
}

$shaFile = $ZipPath + '.sha256'
if (-not (Test-Path -LiteralPath $shaFile -PathType Leaf)) {
    throw ('Немає файлу контрольної суми: ' + $shaFile + ' — покладіть його поруч із архівом. ' +
        'Без нього походження комплекту не підтверджене, і розгортання не виконується.')
}
$expected = (((Get-Content -LiteralPath $shaFile -Raw).Trim()) -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expected -ne $actual) {
    throw ('SHA-256 не збігається. очікувано=' + $expected + ' фактично=' + $actual)
}
Write-Ok ('sha256 ' + $actual)

# Файл, завантажений з Інтернету, несе Zone.Identifier: без Unblock-File
# Expand-Archive і подальший запуск .ps1 можуть блокуватись.
try { Unblock-File -LiteralPath $ZipPath -ErrorAction Stop } catch { }

$staged = Join-Path $StagingRoot 'staged'
if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Recurse -Force }
Expand-Archive -LiteralPath $ZipPath -DestinationPath $staged -Force

$stagedVersionFile = Join-Path $staged 'VERSION.json'
if (-not (Test-Path -LiteralPath $stagedVersionFile -PathType Leaf)) {
    throw ('У розпакованому архіві немає VERSION.json: ' + $staged)
}
$stagedVersion = (Get-Content -LiteralPath $stagedVersionFile -Raw -Encoding UTF8 | ConvertFrom-Json)
if ([string]$stagedVersion.packageVersion -ne $targetVersion) {
    throw ('У комплекті версія ' + $stagedVersion.packageVersion + ', очікувалась ' + $targetVersion)
}
$stagedCommit = if ($null -ne $stagedVersion.PSObject.Properties['sourceCommit']) {
    [string]$stagedVersion.sourceCommit
} else { '(немає у VERSION.json)' }
Write-Ok ('розпаковано: ' + $stagedVersion.packageVersion + ' / ' + $stagedVersion.releaseChannel +
          ' (sourceCommit ' + $stagedCommit + ')')
if ([string]$stagedVersion.releaseChannel -ne 'stable') {
    Write-Warn2 ('канал релізу "' + $stagedVersion.releaseChannel + '", а не "stable".')
}

foreach ($required in @('BRAVO_RUNTIME_GUARD.ps1', 'RUNTIME_MANIFEST.json', 'BRAVO_SETUP.ps1',
                        'BRAVO_CONFIG_LOADER.ps1', 'BRAVO.config', 'Tools\TOOLS_MANIFEST.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $staged $required) -PathType Leaf)) {
        throw ('У комплекті бракує обов''язкового файлу: ' + $required)
    }
}
Write-Ok 'обов''язкові файли комплекту на місці'

# --- 2. Вільне місце --------------------------------------------------------

Write-Step '2. Вільне місце на цільовому томі'

$stagedSum = (Get-ChildItem -LiteralPath $staged -Recurse -Force -File |
    Measure-Object -Property Length -Sum).Sum
if ($null -eq $stagedSum) { $stagedSum = 0 }
$stagedBytes = [long]$stagedSum
$needBytes = [long]($stagedBytes * 1.2)
$targetQualifier = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($RuntimeRoot))
$freeBytes = $null
if ($targetQualifier -match '^[A-Za-z]:') {
    try {
        $drive = Get-PSDrive -Name ($targetQualifier.Substring(0, 1)) -ErrorAction Stop
        $freeBytes = [long]$drive.Free
    } catch {
        Write-Warn2 ('не вдалося визначити вільне місце на ' + $targetQualifier + ': ' + $_.Exception.Message)
    }
} else {
    Write-Warn2 ('цільовий шлях не на локальному томі з літерою (' + $targetQualifier +
        '): перевірку вільного місця пропущено.')
}
Write-Note ('комплект: ' + [math]::Round($stagedBytes / 1MB, 1) + ' MB')
if ($null -ne $freeBytes) {
    Write-Note ('вільно на ' + $targetQualifier + ': ' + [math]::Round($freeBytes / 1GB, 2) + ' GB')
    if ($freeBytes -lt $needBytes) {
        throw ('Недостатньо місця на ' + $targetQualifier + ': потрібно щонайменше ' +
            [math]::Round($needBytes / 1MB, 1) + ' MB.')
    }
    Write-Ok 'місця достатньо'
}

# Це перевірка місця САМЕ ПІД КОМПЛЕКТ. Вона нічого не каже про місце під
# архіви й обслуговування — його перевіряє BRAVO за
# maintenanceSettings.Limits.MinimumFreeSpaceGB (розділ 8 процедури міграції).

# --- 3. Розгортання ---------------------------------------------------------

Write-Step '3. Розгортання'

if (-not $targetExists) {
    [void](New-Item -ItemType Directory -Path $RuntimeRoot -Force)
    Write-Ok ('створено ' + $RuntimeRoot)
}

# Без /MIR і без /PURGE: цільовий каталог порожній, а знищувальні режими
# robocopy на кореневому каталозі — саме те, чого тут не має бути.
$robocopyLog = Join-Path $StagingRoot ('robocopy_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
$null = & robocopy.exe $staged $RuntimeRoot /E /R:2 /W:2 /NFL /NDL /NP ('/LOG:' + $robocopyLog)
$robocopyCode = $LASTEXITCODE
if ($robocopyCode -ge 8) {
    throw ('robocopy завершився кодом ' + $robocopyCode + '; журнал: ' + $robocopyLog)
}
Write-Ok ('файли скопійовано (robocopy ' + $robocopyCode + ')')

$deployedVersion = (Get-Content -LiteralPath (Join-Path $RuntimeRoot 'VERSION.json') -Raw -Encoding UTF8 |
    ConvertFrom-Json)
if ([string]$deployedVersion.packageVersion -ne $targetVersion) {
    throw ('Після копіювання VERSION.json показує ' + $deployedVersion.packageVersion)
}
Write-Ok ('VERSION.json: ' + $deployedVersion.packageVersion + ' / ' + $deployedVersion.releaseChannel)

# --- 4. BRAVO.local.config --------------------------------------------------

Write-Step '4. Шар site-відмінностей'

$localConfig = Join-Path $RuntimeRoot 'BRAVO.local.config'
$localExample = Join-Path $RuntimeRoot 'BRAVO.local.config.example'
if (Test-Path -LiteralPath $localConfig -PathType Leaf) {
    Write-Ok 'BRAVO.local.config уже існує — не чіпаємо'
} elseif ($SeedLocalConfig) {
    if (-not (Test-Path -LiteralPath $localExample -PathType Leaf)) {
        throw ('Немає прикладу ' + $localExample)
    }
    Copy-Item -LiteralPath $localExample -Destination $localConfig
    Write-Ok ('створено з прикладу: ' + $localConfig)
    Write-Warn2 'усі ключі в ньому закоментовані — внесіть site-відмінності ДО BRAVO_SETUP.'
} else {
    Write-Note ('не створено (додайте -SeedLocalConfig або скопіюйте вручну з ' +
        'BRAVO.local.config.example)')
}
Write-Note 'BRAVO.config з комплекту не редагується — site-значення належать BRAVO.local.config.'

# --- 5. Гейт цілісності -----------------------------------------------------

Write-Step '5. Гейт: цілісність комплекту'

Push-Location $RuntimeRoot
try {
    & (Join-Path $RuntimeRoot 'BRAVO_RUNTIME_GUARD.ps1')
    $guardCode = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($guardCode -ne 0) {
    Write-Bad ('BRAVO_RUNTIME_GUARD.ps1 -> exit ' + $guardCode)
    switch ($guardCode) {
        33 { Write-Host '  33 = цілісність комплекту порушена: файл не збігається з RUNTIME_MANIFEST.json, відсутній, або в комплекті є сторонній .ps1/.psm1.' -ForegroundColor Red }
        34 { Write-Host '  34 = BRAVO.config послаблює захист (Tools Mode=Warn або backupConsistency.Mode != VSS).' -ForegroundColor Red }
        35 { Write-Host '  35 = на цьому сервері вже запускали новішу версію (BRAVO_VERSION_STATE.json).' -ForegroundColor Red }
        default { }
    }
    Write-Host ''
    Write-Host '  Розгорнуті файли НЕ видалено — це доказ. Не "лагодьте" цю помилку' -ForegroundColor Yellow
    Write-Host '  видаленням маніфеста: так вимикається перевірка, а не усувається причина.' -ForegroundColor Yellow
    Write-Host '  Порядок дій за кодом — матриця діагностики в README §12.' -ForegroundColor Yellow
    exit $guardCode
}
Write-Ok 'BRAVO_RUNTIME_GUARD.ps1 -> exit 0'

# --- 6. Self-test -----------------------------------------------------------

Write-Step '6. Self-test'

if ($SkipSelfTest) {
    Write-Note 'пропущено (-SkipSelfTest)'
} else {
    Write-Note 'виконується, це кілька хвилин...'
    Push-Location $RuntimeRoot
    try {
        & (Join-Path $RuntimeRoot 'BRAVO_SELF_TEST.ps1')
        $selfTestCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($selfTestCode -eq 0) {
        Write-Ok 'BRAVO_SELF_TEST.ps1 -> exit 0'
    } else {
        Write-Bad ('BRAVO_SELF_TEST.ps1 -> exit ' + $selfTestCode + ' — розберіть вивід вище перед налаштуванням.')
        exit $selfTestCode
    }
}

# --- 7. Діагностична валідація (не блокує) ----------------------------------

Write-Step '7. Валідація конфігурації (діагностична)'

Push-Location $RuntimeRoot
try {
    & (Join-Path $RuntimeRoot 'BRAVO_SETUP.ps1') -ValidateOnly -NoPause
    $validateCode = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($validateCode -eq 0) {
    Write-Ok 'BRAVO_SETUP.ps1 -ValidateOnly -> exit 0'
} else {
    Write-Warn2 ('BRAVO_SETUP.ps1 -ValidateOnly -> exit ' + $validateCode)
    Write-Host '  На ЧИСТОМУ сервері це очікувано: 30 — не задані site-шляхи,' -ForegroundColor Yellow
    Write-Host '  31 — ще немає записів Credential Manager. Обидва усуваються на кроках нижче.' -ForegroundColor Yellow
}

# --- Підсумок ---------------------------------------------------------------

Write-Step 'Готово: комплект розгорнуто'

Write-Host ('  каталог:     ' + $RuntimeRoot)
Write-Host ('  версія:      ' + $deployedVersion.packageVersion + ' / ' + $deployedVersion.releaseChannel)
Write-Host ('  sourceCommit: ' + $stagedCommit)
Write-Host ('  staging:     ' + $StagingRoot + ' (можна видалити)')
Write-Host ''
Write-Host '  Сервер ЩЕ НЕ налаштований: credentials не створені, завдання' -ForegroundColor Yellow
Write-Host '  Планувальника не зареєстровані, архівація не виконується.' -ForegroundColor Yellow
Write-Host ''
Write-Host '  Далі, вручну й по порядку:' -ForegroundColor Cyan
Write-Host ('    1. ' + $localConfig + '  — внести site-відмінності')
Write-Host '    2. .\BRAVO_SETUP.ps1 -Action Test -ValidateOnly        — звірити DISCOVERY ДЖЕРЕЛ'
Write-Host '    3. .\BRAVO_SETUP.ps1 -Action Test -ValidateOnly -ConfirmDiscoveryBaseline'
Write-Host '    4. .\BRAVO_SETUP.ps1                                   — credentials + Планувальник'
Write-Host '    5. .\BRAVO_TASKS_DIAGNOSE.ps1 -InspectOnly'
Write-Host '    6. .\BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess'
Write-Host '    7. .\BRAVO_DRY_RUN.ps1                                 — прогін без production-дій'
Write-Host ''
exit 0
