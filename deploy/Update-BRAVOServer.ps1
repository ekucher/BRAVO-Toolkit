[CmdletBinding()]
param(
    [string]$RuntimeRoot = 'C:\Program Files\BRAVO-Toolkit',
    [string]$Tag = 'v5.2.4',
    [string]$ZipPath,
    [string]$StagingRoot = 'C:\Temp\BRAVO_UPDATE',
    [string]$BackupRoot,
    [switch]$PreflightOnly,
    [switch]$AllowPrereleaseChannel,
    [switch]$Force,
    [switch]$NoElevation,
    [switch]$NoPause
)

# Проміжний помічник розкатки stable-релізу на ОДИН сервер.
#
# Це НЕ P3.2a (ROADMAP.md): немає versioned-каталогів, atomic activation,
# auto-download за розкладом і будь-якого silent-режиму. Запускає оператор
# вручну, з піднятими правами, і спостерігає результат. Коли BRAVO_UPDATE.ps1
# і modules\BRAVO.Update\ буде реалізовано — цей скрипт слід видалити.
#
# ЩО ВІН НІКОЛИ НЕ РОБИТЬ:
#   * не видаляє з runtime жодного файлу (перевірено: між 5.2.3 і 5.2.4
#     не видалено жодного файлу, додано лише один документ — тож копіювання
#     поверх достатнє; для переходу, де файли зникають, потрібен P3.2a);
#   * не чіпає BRAVO.config, BRAVO.local.config, Tools\TOOLS_INTEGRITY.json,
#     LOGS\ і каталоги призначення бекапів;
#   * не перейменовує каталог runtime (ACL-захист BRAVO_TASKS_INSTALL це
#     забороняє навіть адміністратору — ROADMAP P3.2a крок 6).

$ErrorActionPreference = 'Stop'

# Операторський інструмент: помилка має читатися одним рядком, а не
# стек-дампом PowerShell. Код завершення 1 = скрипт зупинився сам.
#
# Це catch, а не trap: тіло скрипта обгорнуте try/finally заради паузи й
# відновлення кодування, а trap спрацював би ПІСЛЯ finally — оператор
# побачив би запит "Натисніть Enter" раніше за причину зупинки.
$script:Failed = $false

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

$script:Blockers = New-Object System.Collections.Generic.List[string]
function Add-Blocker { param([string]$T) Write-Bad $T; [void]$script:Blockers.Add($T) }

try {
# Політика "який артефакт можна розгортати" спільна з Install-BRAVOServer.ps1 і
# живе в одному екземплярі. Відсутність файлу зупиняє розкатку явно: тихо
# продовжити означало б оновлювати БЕЗ гейта.
$script:ReleaseGatePath = Join-Path $PSScriptRoot 'BRAVO.Deploy.ReleaseGate.ps1'
if (-not (Test-Path -LiteralPath $script:ReleaseGatePath -PathType Leaf)) {
    throw ('Поруч зі скриптом немає BRAVO.Deploy.ReleaseGate.ps1 (' + $script:ReleaseGatePath +
        '). Це файл політики гейта релізу — скопіюйте весь каталог deploy\, а не один скрипт.')
}
. $script:ReleaseGatePath

# --- 0. Права й цілісність цілі --------------------------------------------

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
    if (-not [string]::IsNullOrWhiteSpace($BackupRoot)) {
        [void]$argumentParts.Add('-BackupRoot'); [void]$argumentParts.Add('"' + $BackupRoot + '"')
    }
    if ($PreflightOnly) { [void]$argumentParts.Add('-PreflightOnly') }
    if ($AllowPrereleaseChannel) { [void]$argumentParts.Add('-AllowPrereleaseChannel') }
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

foreach ($required in @('VERSION.json', 'BRAVO_RUNTIME_GUARD.ps1', 'BRAVO_SETUP.ps1', 'BRAVO_CONFIG_LOADER.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $RuntimeRoot $required) -PathType Leaf)) {
        throw ("Не схоже на runtime-корінь BRAVO (немає $required): " + $RuntimeRoot)
    }
}
$currentVersion = (Get-Content -LiteralPath (Join-Path $RuntimeRoot 'VERSION.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
Write-Ok ('runtime: ' + $RuntimeRoot)
Write-Ok ('встановлено зараз: ' + $currentVersion.packageVersion + ' / ' + $currentVersion.releaseChannel +
          ' (buildId ' + $currentVersion.buildId + ')')

$targetVersion = $Tag.TrimStart('v')
if ($currentVersion.packageVersion -eq $targetVersion -and -not $Force) {
    Write-Warn2 ('Версія ' + $targetVersion + ' вже встановлена. Для повторного розгортання додайте -Force.')
    if (-not $PreflightOnly) { exit 0 }
}

# --- 1. Preflight: поріг вільного місця -------------------------------------
# Головна пастка 5.2.4: Archive тепер толерує below-floor, а Maintenance —
# НІ (спільний ключ Limits.MinimumFreeSpaceGB). Сервер із завищеним порогом
# проходить архівацію і мовчки валить нічне обслуговування з exit 60.

Write-Step '1. Preflight: поріг вільного місця (пастка асиметрії Archive/Maintenance)'

$configPath = Join-Path $RuntimeRoot 'BRAVO.config'

# Ефективна конфігурація читається в ДОЧІРНЬОМУ powershell.exe, а не тут.
# Import-BravoConfiguration змінює глобальний стан процесу — зокрема
# встановлює $global:ScriptVersion зі СТАРОЇ VERSION.json. Далі гейти
# запускають BRAVO_SETUP у цьому ж процесі, його завантажувач бачить
# успадкований global і друкує хибне попередження "VERSION.json (нова) і
# BRAVO.config (стара) містять різні версії пакета" — при повністю
# коректній конфігурації. Ізоляція дочірнім процесом — та сама конвенція,
# що вже застосована в self-test репозиторію з тієї самої причини.

$probe = @'
param([string]$RuntimeRoot, [string]$ConfigPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $RuntimeRoot 'BRAVO_CONFIG_LOADER.ps1')
Import-BravoConfiguration -ConfigRoot $RuntimeRoot -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot
[pscustomobject]@{
    Floor    = [double]$global:maintenanceSettings.Limits.MinimumFreeSpaceGB
    Excluded = @($global:maintenanceSettings.Limits.ExcludedDrives)
    LimsRoot = [string]$global:effectiveLimsRoot
    TaskPath = [string]$global:schedulerSettings.TaskPath
} | ConvertTo-Json -Compress
'@

$probePath = Join-Path $env:TEMP ('BRAVO_UPDATE_PROBE_' + [guid]::NewGuid().ToString('N') + '.ps1')
try {
    [System.IO.File]::WriteAllText($probePath, $probe, (New-Object System.Text.UTF8Encoding($true)))
    $probeOutput = & powershell.exe -NoProfile -NonInteractive -File $probePath `
        -RuntimeRoot $RuntimeRoot -ConfigPath $configPath
    if ($LASTEXITCODE -ne 0) {
        throw ('Не вдалося прочитати ефективну конфігурацію (' + $LASTEXITCODE + '): ' +
            ($probeOutput -join ' '))
    }
} finally {
    Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
}

$effective = ($probeOutput | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1) | ConvertFrom-Json
$floor = [double]$effective.Floor
$excluded = @($effective.Excluded)
$limsRoot = [string]$effective.LimsRoot
$taskPathFromConfig = [string]$effective.TaskPath
Write-Note ('ефективний поріг MinimumFreeSpaceGB: ' + $floor + ' GB')
Write-Note ('виключення ExcludedDrives: ' + $(if ($excluded.Count) { $excluded -join ', ' } else { '(немає)' }))
Write-Note ('EffectiveLIMSRoot (робочий том Maintenance): ' + $limsRoot)

$limsDrive = ''
try { $limsDrive = ([IO.Path]::GetPathRoot($limsRoot)).TrimEnd('\').ToUpperInvariant() } catch { }

$excludedNorm = @($excluded | ForEach-Object { ([string]$_).TrimEnd('\', ':').ToUpperInvariant() })
$rows = New-Object System.Collections.Generic.List[object]
foreach ($d in ([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq [IO.DriveType]::Fixed -and $_.IsReady })) {
    $letter = ($d.Name).TrimEnd('\').ToUpperInvariant()
    $totalGB = [math]::Round($d.TotalSize / 1GB, 2)
    $freeGB  = [math]::Round($d.AvailableFreeSpace / 1GB, 2)
    $isExcluded = $excludedNorm -contains $letter.TrimEnd(':')
    $isLims = ($letter -eq $limsDrive)

    $verdict = 'OK'
    if ($totalGB -lt $floor) { $verdict = 'ПОРІГ ВИЩЕ ЗА ЄМНІСТЬ' }
    elseif ($freeGB -lt $floor) { $verdict = 'НИЖЧЕ ПОРОГУ' }

    [void]$rows.Add([pscustomobject]@{
        Диск = $letter; ЄмністьGB = $totalGB; ВільноGB = $freeGB
        ПорігGB = $floor; Виключено = $isExcluded; ROOT_LIMS = $isLims; Вердикт = $verdict
    })
}
$rows | Format-Table -AutoSize | Out-String | Write-Host

foreach ($r in $rows) {
    if ($r.Вердикт -eq 'OK') { continue }
    if ($r.ROOT_LIMS) {
        Add-Blocker ("Том $($r.Диск) — робочий том Maintenance (ROOT_LIMS), і він $($r.Вердикт) " +
            "(вільно $($r.ВільноGB) GB, ємність $($r.ЄмністьGB) GB, поріг $($r.ПорігGB) GB). " +
            "BRAVO_MAINTENANCE впаде з BelowFallbackFloorNoEstimate і exit 60 при першому ж нічному прогоні.")
    } elseif (-not $r.Виключено) {
        Write-Warn2 ("Том $($r.Диск) $($r.Вердикт) — health-попередження на кожному прогоні (exit 10, ALERTS). " +
            "Не блокує оновлення.")
    }
}
if ($script:Blockers.Count -eq 0) { Write-Ok 'поріг сумісний і з архівацією, і з обслуговуванням' }

# --- 2. Preflight: жодне завдання BRAVO не виконується ----------------------

Write-Step '2. Preflight: стан завдань Планувальника'

$taskPath = $taskPathFromConfig
if ([string]::IsNullOrWhiteSpace($taskPath)) { $taskPath = '\BRAVO\' }
$running = @()
try {
    $running = @(Get-ScheduledTask -TaskPath $taskPath -ErrorAction Stop |
        Where-Object { $_.State -eq 'Running' })
} catch {
    Write-Warn2 ('не вдалося прочитати завдання ' + $taskPath + ': ' + $_.Exception.Message)
}
if ($running.Count -gt 0) {
    Add-Blocker ('Виконуються завдання BRAVO: ' + (($running | ForEach-Object { $_.TaskName }) -join ', ') +
        '. Оновлення під час прогону пошкодить комплект.')
} else {
    Write-Ok ('жодне завдання в ' + $taskPath + ' не виконується')
}

if ($script:Blockers.Count -gt 0) {
    Write-Step 'ЗУПИНЕНО — блокери preflight'
    foreach ($b in $script:Blockers) { Write-Host ('  - ' + $b) -ForegroundColor Red }
    exit 1
}
if ($PreflightOnly) {
    Write-Step 'Preflight пройдено (-PreflightOnly: нічого не змінено)'
    exit 0
}

# --- 3. Артефакт ------------------------------------------------------------

Write-Step ('3. Артефакт ' + $Tag)

if (-not (Test-Path -LiteralPath $StagingRoot)) { [void](New-Item -ItemType Directory -Path $StagingRoot -Force) }
$downloadDir = Join-Path $StagingRoot 'download'

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    if (Test-Path -LiteralPath $downloadDir) { Remove-Item -LiteralPath $downloadDir -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $downloadDir -Force)
    # TLS 1.2 не є дефолтом на серверах 2016 (ROADMAP P3.2a крок 1).
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $zipName = 'BRAVO-Toolkit-' + $targetVersion + '.zip'
    $base = 'https://github.com/ekucher/BRAVO-Toolkit/releases/download/' + $Tag + '/'
    $ZipPath = Join-Path $downloadDir $zipName
    Write-Note ('завантаження ' + $base + $zipName)
    Invoke-WebRequest -Uri ($base + $zipName) -OutFile $ZipPath -UseBasicParsing
    Invoke-WebRequest -Uri ($base + $zipName + '.sha256') -OutFile ($ZipPath + '.sha256') -UseBasicParsing
    # release-manifest.json — окремий ассет релізу, тобто джерело провенансу,
    # незалежне від самого архіву. Помилка завантаження не зупиняє оновлення:
    # релізи до появи маніфесту його не мають, а без нього лишаються внутрішні
    # інваріанти комплекту (їх перевіряє гейт нижче).
    try {
        Invoke-WebRequest -Uri ($base + 'release-manifest.json') `
            -OutFile (Join-Path $downloadDir 'release-manifest.json') -UseBasicParsing
    } catch {
        Write-Warn2 ('release-manifest.json не завантажено: ' + $_.Exception.Message)
    }
} else {
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw ('Архів не знайдено: ' + $ZipPath) }
}

$shaFile = $ZipPath + '.sha256'
if (-not (Test-Path -LiteralPath $shaFile -PathType Leaf)) {
    throw ('Немає файлу контрольної суми: ' + $shaFile + ' — покладіть його поруч із архівом.')
}
$expected = (((Get-Content -LiteralPath $shaFile -Raw).Trim()) -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expected -ne $actual) { throw ('SHA-256 не збігається. очікувано=' + $expected + ' фактично=' + $actual) }
Write-Ok ('sha256 ' + $actual)

$staged = Join-Path $StagingRoot 'staged'
if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Recurse -Force }
Expand-Archive -LiteralPath $ZipPath -DestinationPath $staged -Force

$stagedVersion = (Get-Content -LiteralPath (Join-Path $staged 'VERSION.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
if ([string]$stagedVersion.packageVersion -ne $targetVersion) {
    throw ('У комплекті версія ' + $stagedVersion.packageVersion + ', очікувалась ' + $targetVersion)
}
Write-Ok ('розпаковано: ' + $stagedVersion.packageVersion + ' / ' + $stagedVersion.releaseChannel +
          ' (sourceCommit ' + $stagedVersion.sourceCommit + ')')

# --- Гейт релізу ------------------------------------------------------------
# Доти оновлення НЕ перевіряло канал релізу взагалі — лише друкувало його.
# Тобто prerelease-комплект приїжджав на сервер установи без жодного рішення.
# Політика й тексти — спільні з Install-BRAVOServer.ps1 (BRAVO.Deploy.ReleaseGate.ps1).

# Конвенція одна: release-manifest.json лежить поруч з архівом — і коли його
# завантажив цей скрипт, і коли оператор приніс zip разом з ассетами релізу.
$releaseManifestPath = Join-Path (Split-Path -Parent $ZipPath) 'release-manifest.json'
$releaseManifest = $null
if (Test-Path -LiteralPath $releaseManifestPath -PathType Leaf) {
    try {
        $releaseManifest = (Get-Content -LiteralPath $releaseManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        throw ('release-manifest.json пошкоджений (' + $releaseManifestPath + '): ' + $_.Exception.Message +
            ' — провенанс не підтверджується, оновлення зупинено.')
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

# Копіювання поверх НЕ видаляє файлів. Скрипт .ps1/.psm1/.psd1, якого немає
# в новому RUNTIME_MANIFEST.json, після оновлення лишиться в комплекті — і
# BRAVO_RUNTIME_GUARD заблокує запуск кодом 33 ("сторонні скрипти в
# комплекті"). Тому шукаємо такі файли ДО заміни, а не після провалу гейта.
#
# Це загальна перевірка замість припущення "між версією X і цільовою нічого
# не видалено": вона однаково працює для будь-якої встановленої версії.
# Файли не видаляються автоматично — видалення в production-каталозі
# лишається рішенням оператора.

$stagedManifest = Get-Content -LiteralPath (Join-Path $staged 'RUNTIME_MANIFEST.json') `
    -Raw -Encoding UTF8 | ConvertFrom-Json
$expectedRelative = New-Object 'System.Collections.Generic.HashSet[string]' `
    ([StringComparer]::OrdinalIgnoreCase)
foreach ($property in $stagedManifest.files.PSObject.Properties) {
    [void]$expectedRelative.Add($property.Name)
}

# Той самий набір виключень, що в BRAVO_RUNTIME_GUARD.ps1.
$guardExclusion = '^(LOGS|\.git|\.vscode|\.claude|local-backups)[\\/]'
$runtimePrefixLength = $RuntimeRoot.TrimEnd('\', '/').Length + 1
$orphans = New-Object System.Collections.Generic.List[string]
foreach ($file in (Get-ChildItem -LiteralPath $RuntimeRoot -Recurse -File -ErrorAction SilentlyContinue)) {
    if (@('.ps1', '.psm1', '.psd1') -notcontains $file.Extension.ToLowerInvariant()) { continue }
    $relative = $file.FullName.Substring($runtimePrefixLength)
    if ($relative -match $guardExclusion) { continue }
    if (-not $expectedRelative.Contains($relative)) { [void]$orphans.Add($relative) }
}

if ($orphans.Count -gt 0) {
    Write-Bad ('у комплекті ' + $orphans.Count + ' скрипт(ів), яких немає в новому маніфесті:')
    foreach ($o in $orphans) { Write-Host ('      ' + $o) -ForegroundColor Red }
    Write-Host ''
    Write-Host '  Копіювання поверх їх не видалить, і після оновлення BRAVO_RUNTIME_GUARD' -ForegroundColor Yellow
    Write-Host '  заблокує запуск кодом 33. Приберіть їх (зберігши власну копію) і' -ForegroundColor Yellow
    Write-Host '  повторіть. Типові кандидати після давніх оновлень поверх — застарілі' -ForegroundColor Yellow
    Write-Host '  кореневі бібліотеки BRAVO_COMPATIBILITY.ps1, BRAVO_CREDENTIALS.ps1,' -ForegroundColor Yellow
    Write-Host '  BRAVO_HELPER_LOGGING.ps1, BRAVO_NOTIFICATION.ps1, BRAVO_ARCHIVE_HELPERS.ps1,' -ForegroundColor Yellow
    Write-Host '  BRAVO_ARCHIV_RUNTIME.ps1, BRAVO_SYSTEM_HELPERS.ps1 (README §10, пункт 4).' -ForegroundColor Yellow
    exit 1
}
Write-Ok 'сторонніх скриптів у комплекті немає'

# --- 4. Backup копіюванням --------------------------------------------------

Write-Step '4. Backup поточного комплекту'

if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = $RuntimeRoot.TrimEnd('\') + '.old_' + $currentVersion.packageVersion +
        '_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
}
if (Test-Path -LiteralPath $BackupRoot) { throw ('Каталог backup вже існує: ' + $BackupRoot) }
Write-Note ('копіювання (НЕ перейменування) у ' + $BackupRoot)
$rcBackup = robocopy $RuntimeRoot $BackupRoot /E /R:2 /W:2 /NFL /NDL /NJH /NJS /XD LOGS
if ($LASTEXITCODE -ge 8) { throw ('robocopy backup завершився з кодом ' + $LASTEXITCODE) }
Write-Ok ('backup створено (LOGS виключено), robocopy код ' + $LASTEXITCODE)

# --- 5. Розгортання поверх --------------------------------------------------

Write-Step '5. Розгортання комплекту'

# БЕЗ /MIR: нічого не видаляємо. /XF і /XD нижче — site-specific стан, який
# є в runtime і якого немає в артефакті (.gitignore), плюс BRAVO.config,
# що в артефакті Є, але на сервері налаштований під цей сервер.
$excludeFiles = @('BRAVO.config', 'BRAVO.local.config', 'TOOLS_INTEGRITY.json',
                  'WinSCP.ini', 'BRAVO_OPERATION.lock')
$excludeDirs  = @('LOGS', 'MODEL', 'BLOG', 'BRAVOEXCH', 'BAZA', 'BAZA_WWW', 'artifacts')

$rcArgs = @($staged, $RuntimeRoot, '/E', '/R:2', '/W:2', '/NFL', '/NDL', '/NJH', '/NJS',
            '/XF') + $excludeFiles + @('/XD') + $excludeDirs
$rcDeploy = robocopy @rcArgs
if ($LASTEXITCODE -ge 8) { throw ('robocopy розгортання завершилось з кодом ' + $LASTEXITCODE) }
Write-Ok ('файли скопійовано, robocopy код ' + $LASTEXITCODE)
Write-Note ('збережено без змін: ' + ($excludeFiles -join ', '))

# --- 6. Гейти після заміни --------------------------------------------------

Write-Step '6. Гейти після заміни'

$gateFailures = New-Object System.Collections.Generic.List[string]

$newVersion = (Get-Content -LiteralPath (Join-Path $RuntimeRoot 'VERSION.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
if ([string]$newVersion.packageVersion -eq $targetVersion) {
    Write-Ok ('VERSION.json: ' + $newVersion.packageVersion + ' / ' + $newVersion.releaseChannel)
} else {
    [void]$gateFailures.Add('VERSION.json у runtime = ' + $newVersion.packageVersion + ', очікувалось ' + $targetVersion)
}

Push-Location $RuntimeRoot
try {
    & .\BRAVO_RUNTIME_GUARD.ps1
    $guard = $LASTEXITCODE
    if ($guard -eq 0) { Write-Ok 'BRAVO_RUNTIME_GUARD.ps1: exit 0' }
    else { [void]$gateFailures.Add('BRAVO_RUNTIME_GUARD.ps1 exit ' + $guard) }

    if ($gateFailures.Count -eq 0) {
        & .\BRAVO_SETUP.ps1 -Action Scheduler -NoPause
        $sched = $LASTEXITCODE
        if ($sched -eq 0) { Write-Ok 'BRAVO_SETUP -Action Scheduler: exit 0' }
        else { [void]$gateFailures.Add('BRAVO_SETUP -Action Scheduler exit ' + $sched) }

        & .\BRAVO_SETUP.ps1 -ValidateOnly -NoPause
        $val = $LASTEXITCODE
        if ($val -eq 0) { Write-Ok 'BRAVO_SETUP -ValidateOnly: exit 0' }
        else { [void]$gateFailures.Add('BRAVO_SETUP -ValidateOnly exit ' + $val) }
    }
} finally {
    Pop-Location
}

# --- 7. Відкат при провалі гейта -------------------------------------------

if ($gateFailures.Count -gt 0) {
    Write-Step 'ПРОВАЛ ГЕЙТА — автоматичний відкат'
    foreach ($f in $gateFailures) { Write-Bad $f }
    Write-Note ('відновлення з ' + $BackupRoot)
    $rcBack = robocopy $BackupRoot $RuntimeRoot /E /R:2 /W:2 /NFL /NDL /NJH /NJS /XD LOGS
    if ($LASTEXITCODE -ge 8) {
        Write-Bad ('ВІДКАТ НЕ ВДАВСЯ (robocopy код ' + $LASTEXITCODE + '). Комплект у невизначеному стані.')
        Write-Bad ('Backup лишається тут: ' + $BackupRoot)
        exit 2
    }
    Push-Location $RuntimeRoot
    try { & .\BRAVO_RUNTIME_GUARD.ps1; $g2 = $LASTEXITCODE } finally { Pop-Location }
    if ($g2 -eq 0) { Write-Ok 'відкат виконано, guard на відновленому комплекті: exit 0' }
    else { Write-Bad ('після відкату guard дає exit ' + $g2 + ' — потрібне ручне втручання') }
    exit 1
}

# --- 8. Підсумок ------------------------------------------------------------

Write-Step 'ГОТОВО'
Write-Host ('  було:   ' + $currentVersion.packageVersion + ' (' + $currentVersion.buildId + ')')
Write-Host ('  стало:  ' + $newVersion.packageVersion + ' (' + $newVersion.buildId + ')')
Write-Host ('  backup: ' + $BackupRoot)
Write-Host ''
Write-Warn2 'Перевірте перший нічний прогін: і архівацію, і обслуговування.'
Write-Warn2 ('Backup не видаляється автоматично — приберіть ' + $BackupRoot + ' після успішної доби.')
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
