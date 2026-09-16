[CmdletBinding()]
param(
    [string]$RuntimeRoot = 'C:\Program Files\BRAVO-Toolkit',
    [string]$Tag = 'v5.2.4',
    [string]$ZipPath,
    [string]$StagingRoot = 'C:\Temp\BRAVO_INSTALL',
    [switch]$SeedLocalConfig,
    [switch]$AllowPrereleaseChannel,
    [switch]$SkipSelfTest,
    [switch]$Force,
    [switch]$NoElevation,
    [switch]$NoPause
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
#
# Це catch, а не trap: тіло скрипта обгорнуте try/finally заради паузи й
# відновлення кодування, а trap спрацював би ПІСЛЯ finally — оператор
# побачив би запит "Натисніть Enter" раніше за причину зупинки.
$script:Failed = $false
Set-StrictMode -Version 2.0

# --- Кирилиця в консолі ------------------------------------------------------
# Windows PowerShell 5.1 на серверах з російською локаллю тримає консоль у
# OEM-866, тому UTF-8-вивід дочірніх процесів BRAVO (BRAVO_DRY_RUN,
# BRAVO_TASKS_INSTALL, BRAVO_CREDENTIALS_SETUP) читається як
# "‹®Ј ¤®Ї®¬?¦­®Ј®". Перемикаємо консоль на UTF-8 на час роботи скрипта;
# дочірні процеси успадковують кодову сторінку. Початковий стан
# повертається у finally наприкінці файлу.

$script:PreviousConsoleEncoding = $null
$script:PreviousOutputEncoding = $null
try {
    $script:PreviousConsoleEncoding = [Console]::OutputEncoding
    $script:PreviousOutputEncoding = $OutputEncoding
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8NoBom
    $global:OutputEncoding = $utf8NoBom
} catch {
    # Вивід перенаправлено або консолі немає — не критично, працюємо далі.
    Write-Host ('Не вдалося перемкнути консоль на UTF-8: ' + $_.Exception.Message) -ForegroundColor Yellow
}

function Wait-BRAVODeployCompletion {
    # Той самий контракт, що Wait-BRAVOSetupCompletion у BRAVO_SETUP.ps1.
    # Пауза безумовна на КОЖНОМУ шляху завершення — успіх, зупинка, провал
    # гейта, UAC-перезапуск: вікно, відкрите подвійним кліком або UAC-ом,
    # інакше закривається миттєво разом із результатом. Вимикається лише
    # явним -NoPause або відсутністю інтерактивної консолі.
    if ($NoPause -or -not [Environment]::UserInteractive) {
        return
    }
    try {
        if ([Console]::IsInputRedirected) { return }
        [void](Read-Host 'Натисніть Enter для завершення')
    } catch {
        # Фоновий або перенаправлений запуск не має падати через брак консолі.
    }
}

function Restore-BRAVOConsoleEncoding {
    try {
        if ($null -ne $script:PreviousConsoleEncoding) {
            [Console]::OutputEncoding = $script:PreviousConsoleEncoding
        }
        if ($null -ne $script:PreviousOutputEncoding) {
            $global:OutputEncoding = $script:PreviousOutputEncoding
        }
    } catch {
        # Відновлення кодування ніколи не має маскувати результат роботи.
    }
}

function Write-Step { param([string]$T) Write-Host ''; Write-Host ('=== ' + $T) -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host ('  [OK]    ' + $T) -ForegroundColor Green }
function Write-Bad  { param([string]$T) Write-Host ('  [FAIL]  ' + $T) -ForegroundColor Red }
function Write-Note { param([string]$T) Write-Host ('  [..]    ' + $T) }
function Write-Warn2{ param([string]$T) Write-Host ('  [УВАГА] ' + $T) -ForegroundColor Yellow }

try {
$targetVersion = $Tag.TrimStart('v')

# Політика "який артефакт можна розгортати" спільна з Update-BRAVOServer.ps1 і
# живе в одному екземплярі. Відсутність файлу зупиняє розкатку явно: тихо
# продовжити означало б розгортати БЕЗ гейта.
$script:ReleaseGatePath = Join-Path $PSScriptRoot 'BRAVO.Deploy.ReleaseGate.ps1'
if (-not (Test-Path -LiteralPath $script:ReleaseGatePath -PathType Leaf)) {
    throw ('Поруч зі скриптом немає BRAVO.Deploy.ReleaseGate.ps1 (' + $script:ReleaseGatePath +
        '). Це файл політики гейта релізу — скопіюйте весь каталог deploy\, а не один скрипт.')
}
. $script:ReleaseGatePath

# --- 0. Передумови ----------------------------------------------------------

Write-Step '0. Передумови'

$isElevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# Права адміністратора обов'язкові: скрипт пише у %ProgramFiles%, читає
# Планувальник і запускає BRAVO_SETUP. Замість відмови пропонуємо UAC —
# той самий контракт, що BRAVO_SETUP.ps1 (-NoElevation вимикає підняття й
# передається у перезапущений процес, щоб не було циклу).
#
# ExecutionPolicy тут НЕ послаблюється: перезапуск іде як
# "-NoLogo -NoProfile -File", без -ExecutionPolicy Bypass.

if (-not $isElevated) {
    if ($NoElevation -or -not [Environment]::UserInteractive) {
        throw ('Потрібні права адміністратора. Запустіть PowerShell від імені ' +
            'адміністратора або приберіть -NoElevation, щоб скрипт сам запросив UAC.')
    }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Не вдалося визначити власний шлях для перезапуску з правами адміністратора.'
    }

    Write-Note 'права не підняті — запит UAC і перезапуск в елевованій консолі'

    $argumentParts = New-Object System.Collections.Generic.List[string]
    foreach ($fixed in @('-NoLogo', '-NoProfile', '-File', ('"' + $PSCommandPath + '"'))) {
        [void]$argumentParts.Add($fixed)
    }
    if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        [void]$argumentParts.Add('-RuntimeRoot'); [void]$argumentParts.Add('"' + $RuntimeRoot + '"')
    }
    if (-not [string]::IsNullOrWhiteSpace($Tag)) {
        [void]$argumentParts.Add('-Tag'); [void]$argumentParts.Add('"' + $Tag + '"')
    }
    if (-not [string]::IsNullOrWhiteSpace($ZipPath)) {
        [void]$argumentParts.Add('-ZipPath'); [void]$argumentParts.Add('"' + $ZipPath + '"')
    }
    if (-not [string]::IsNullOrWhiteSpace($StagingRoot)) {
        [void]$argumentParts.Add('-StagingRoot'); [void]$argumentParts.Add('"' + $StagingRoot + '"')
    }
    if ($SeedLocalConfig) { [void]$argumentParts.Add('-SeedLocalConfig') }
    if ($AllowPrereleaseChannel) { [void]$argumentParts.Add('-AllowPrereleaseChannel') }
    if ($SkipSelfTest) { [void]$argumentParts.Add('-SkipSelfTest') }
    if ($Force) { [void]$argumentParts.Add('-Force') }
    if ($NoPause) { [void]$argumentParts.Add('-NoPause') }
    [void]$argumentParts.Add('-NoElevation')

    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $elevated = Start-Process -FilePath $powerShellPath `
        -ArgumentList ($argumentParts -join ' ') `
        -Verb RunAs -Wait -PassThru -WindowStyle Normal

    # Елевований прогін іде в ОКРЕМОМУ вікні, тому батьківський процес мусить
    # сказати, чим він скінчився. Без цього оператор бачив лише "запит UAC" і
    # одразу "Натисніть Enter" — без жодної ознаки, спрацювало щось чи ні.
    if ($null -eq $elevated) {
        throw 'UAC-перезапуск не повернув об''єкт процесу — підняття прав не відбулося.'
    }
    $elevatedCode = [int]$elevated.ExitCode
    Write-Host ''
    if ($elevatedCode -eq 0) {
        Write-Ok 'елевований прогін завершився успішно (код 0)'
    } else {
        Write-Bad ('елевований прогін завершився кодом ' + $elevatedCode)
        Write-Host '  Вивід ішов в ОКРЕМЕ вікно. Якщо воно закрилося раніше, ніж ви встигли' -ForegroundColor Yellow
        Write-Host '  прочитати, запустіть скрипт з консолі, відкритої через "Запуск від імені' -ForegroundColor Yellow
        Write-Host '  адміністратора" — тоді весь вивід лишиться в одному вікні.' -ForegroundColor Yellow
    }
    exit $elevatedCode
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
    # release-manifest.json — окремий ассет релізу, тобто джерело провенансу,
    # незалежне від самого архіву. Помилка завантаження не зупиняє розкатку:
    # релізи до появи маніфесту його не мають, а без нього лишаються внутрішні
    # інваріанти комплекту (їх перевіряє гейт нижче).
    try {
        Invoke-WebRequest -Uri ($base + 'release-manifest.json') `
            -OutFile (Join-Path $downloadDir 'release-manifest.json') -UseBasicParsing
    } catch {
        Write-Warn2 ('release-manifest.json не завантажено: ' + $_.Exception.Message)
    }
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

# --- Гейт релізу ------------------------------------------------------------
# Доти тут було лише Write-Warn2: prerelease-комплект розгортався в установі
# без жодного свідомого рішення. Саме так LIMS-TOP опинився в production на
# 5.2.0-rc.2 — версії, тега якої не існує.

# Конвенція одна: release-manifest.json лежить поруч з архівом — і коли його
# завантажив цей скрипт, і коли оператор приніс zip разом з ассетами релізу.
$releaseManifestPath = Join-Path (Split-Path -Parent $ZipPath) 'release-manifest.json'
$releaseManifest = $null
if (Test-Path -LiteralPath $releaseManifestPath -PathType Leaf) {
    try {
        $releaseManifest = (Get-Content -LiteralPath $releaseManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        throw ('release-manifest.json пошкоджений (' + $releaseManifestPath + '): ' + $_.Exception.Message +
            ' — провенанс не підтверджується, розгортання зупинено.')
    }
}

$provenance = Get-BRAVODeployProvenanceVerdict -VersionMetadata $stagedVersion `
    -ReleaseManifest $releaseManifest -ArtifactSha256 $actual -ExpectedTag $Tag
if (-not $provenance.IsValid) {
    throw $provenance.Message
}
if ($provenance.Severity -eq 'Warning') { Write-Warn2 $provenance.Message } else { Write-Ok $provenance.Message }

$channelDecision = Get-BRAVODeployReleaseChannelDecision -VersionMetadata $stagedVersion `
    -AllowPrereleaseChannel:$AllowPrereleaseChannel
if (-not $channelDecision.Allowed) {
    throw $channelDecision.Message
}
if ($channelDecision.OverrideUsed) { Write-Warn2 $channelDecision.Message } else { Write-Ok $channelDecision.Message }

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
        # -NoPause обов'язковий: без нього self-test чекає клавішу
        # (Wait-BRAVOManualExit) і зупиняє весь автоматичний прогін
        # посеред кроку 6 — спіймано на реальній інсталяції.
        & (Join-Path $RuntimeRoot 'BRAVO_SELF_TEST.ps1') -NoPause
        $selfTestCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($selfTestCode -eq 0) {
        Write-Ok 'BRAVO_SELF_TEST.ps1 -> exit 0'
    } else {
        Write-Bad ('BRAVO_SELF_TEST.ps1 -> exit ' + $selfTestCode)
        Write-Host ''
        Write-Host '  Комплект розгорнуто, але не провалідовано. Розберіть рядки [FAIL] вище' -ForegroundColor Yellow
        Write-Host '  і журнал у LOGS\HELPERS перед налаштуванням. Частина перевірок залежить' -ForegroundColor Yellow
        Write-Host '  від середовища хоста (політики PowerShell, доступність мережевих шляхів),' -ForegroundColor Yellow
        Write-Host '  тому провал self-test не завжди означає дефект комплекту. Свідомо' -ForegroundColor Yellow
        Write-Host '  пропустити перевірку можна параметром -SkipSelfTest.' -ForegroundColor Yellow
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
} catch {
    Write-Host ''
    Write-Host ('ЗУПИНЕНО: ' + $_.Exception.Message) -ForegroundColor Red
    $script:Failed = $true
} finally {
    Wait-BRAVODeployCompletion
    Restore-BRAVOConsoleEncoding
}

if ($script:Failed) { exit 1 }
