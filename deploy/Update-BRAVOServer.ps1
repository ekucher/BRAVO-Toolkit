[CmdletBinding()]
param(
    [string]$RuntimeRoot = 'C:\Program Files\BRAVO-Toolkit',
    [string]$Tag = 'v5.2.4',
    [string]$ZipPath,
    [string]$StagingRoot = 'C:\Temp\BRAVO_UPDATE',
    [string]$BackupRoot,
    [switch]$PreflightOnly,
    [switch]$Force
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
trap {
    Write-Host ''
    Write-Host ('ЗУПИНЕНО: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

function Write-Step { param([string]$T) Write-Host ''; Write-Host ('=== ' + $T) -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host ('  [OK]    ' + $T) -ForegroundColor Green }
function Write-Bad  { param([string]$T) Write-Host ('  [FAIL]  ' + $T) -ForegroundColor Red }
function Write-Note { param([string]$T) Write-Host ('  [..]    ' + $T) }
function Write-Warn2{ param([string]$T) Write-Host ('  [УВАГА] ' + $T) -ForegroundColor Yellow }

$script:Blockers = New-Object System.Collections.Generic.List[string]
function Add-Blocker { param([string]$T) Write-Bad $T; [void]$script:Blockers.Add($T) }

# --- 0. Права й цілісність цілі --------------------------------------------

Write-Step '0. Передумови'

$isElevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) { throw 'Потрібні права адміністратора: запустіть PowerShell від імені адміністратора.' }
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
. (Join-Path $RuntimeRoot 'BRAVO_CONFIG_LOADER.ps1')
Import-BravoConfiguration -ConfigRoot $RuntimeRoot -ConfigPath $configPath -RuntimeRoot $RuntimeRoot

$floor = [double]$global:maintenanceSettings.Limits.MinimumFreeSpaceGB
$excluded = @($global:maintenanceSettings.Limits.ExcludedDrives)
$limsRoot = [string]$global:effectiveLimsRoot
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

$taskPath = [string]$global:schedulerSettings.TaskPath
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
