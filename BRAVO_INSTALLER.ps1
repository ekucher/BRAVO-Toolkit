[CmdletBinding()]
param(
    [string]$RuntimeRoot,
    [switch]$NoPause
)

# Тонкий entrypoint BRAVO Installer (майстер v1, INS-080…092): жодної бізнес-логіки —
# лише guard, імпорт модуля й показ форми. Уся логіка живе в
# modules\BRAVO.Installer.UI\*; дані про стан дає engine (BRAVO_UPDATE.ps1)
# в окремому процесі. GUI не мутує систему й не потребує elevation.

function Wait-BRAVOEarlyManualExit {
    # Ідентично іншим entrypoint-ам (див. коментар у BRAVO_ARCHIV.ps1) —
    # дублюється свідомо, не виносилось у спільний модуль.
    param([switch]$NoPause)
    if ($NoPause) { return }
    try {
        if (-not [Environment]::UserInteractive) { return }
        if ([Console]::IsInputRedirected) { return }
    } catch {
        return
    }
    Write-Host ""
    Write-Host "Натиснiть будь-яку клавiшу для закриття вiкна..." -ForegroundColor Cyan
    try {
        [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        try {
            [void](Read-Host)
        } catch {
            # Немає жодного способу почекати на ввід (нетиповий хост) — це не привід завершити скрипт помилкою.
        }
    }
}

# ===== Runtime/tool integrity guard (той самий 3-перевірковий контракт,
# що BRAVO_HEALTH.ps1/BRAVO_ARCHIV.ps1/BRAVO_CONFIGURATOR.ps1) =====
# Guard має власний param-блок (RuntimeRoot): dot-source перезаписує $RuntimeRoot.
# Зберігаємо значення оператора під іншим ім'ям і відновлюємо після завантаження.
$installerRequestedRuntimeRoot = $RuntimeRoot
$runtimeGuardPath = Join-Path $PSScriptRoot 'BRAVO_RUNTIME_GUARD.ps1'
if (Test-Path -LiteralPath $runtimeGuardPath -PathType Leaf) {
    try {
        . $runtimeGuardPath
    } catch {
        Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити BRAVO_RUNTIME_GUARD.ps1: $($_.Exception.Message)" -ForegroundColor Red
        Wait-BRAVOEarlyManualExit -NoPause:$NoPause
        exit 33
    }
    $RuntimeRoot = $installerRequestedRuntimeRoot
    foreach ($guardFunction in @(
        'Test-BRAVORuntimeManifestIntegrity',
        'Test-BRAVORuntimeSecuritySettings',
        'Test-BRAVOVersionDowngrade'
    )) {
        if (-not (Get-Command -Name $guardFunction -CommandType Function -ErrorAction SilentlyContinue)) {
            Write-Host "КРИТИЧНА ПОМИЛКА: BRAVO_RUNTIME_GUARD.ps1 не оголосив $guardFunction — цілісність комплекту не підтверджена" -ForegroundColor Red
            Wait-BRAVOEarlyManualExit -NoPause:$NoPause
            exit 33
        }
    }
    $runtimeIntegrityMode = if ($env:BRAVO_RUNTIME_INTEGRITY_MODE -eq 'Warn') { 'Warn' } else { 'Enforce' }
    $runtimeIntegrity = Test-BRAVORuntimeManifestIntegrity `
        -RuntimeRoot $PSScriptRoot `
        -ManifestPath (Join-Path $PSScriptRoot 'RUNTIME_MANIFEST.json') `
        -Mode $runtimeIntegrityMode
    if (-not $runtimeIntegrity.IsValid) {
        Write-Host $runtimeIntegrity.Message -ForegroundColor Red
        if ($runtimeIntegrity.ShouldBlock) { Wait-BRAVOEarlyManualExit -NoPause:$NoPause; exit 33 }
    }

    $securitySettings = Test-BRAVORuntimeSecuritySettings `
        -ConfigPath (Join-Path $PSScriptRoot 'BRAVO.config') `
        -Mode $runtimeIntegrityMode
    if (-not $securitySettings.IsValid) {
        $securityColor = if ($securitySettings.ShouldBlock) { 'Red' } else { 'Yellow' }
        Write-Host $securitySettings.Message -ForegroundColor $securityColor
        if ($securitySettings.ShouldBlock) { Wait-BRAVOEarlyManualExit -NoPause:$NoPause; exit 34 }
    }

    $versionState = Test-BRAVOVersionDowngrade `
        -RuntimeRoot $PSScriptRoot `
        -StatePath (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'BRAVO\State\BRAVO_VERSION_STATE.json') `
        -NoWrite `
        -Mode $runtimeIntegrityMode
    if (-not $versionState.IsValid) {
        $versionColor = if ($versionState.ShouldBlock) { 'Red' } else { 'Yellow' }
        Write-Host $versionState.Message -ForegroundColor $versionColor
        if ($versionState.ShouldBlock) { Wait-BRAVOEarlyManualExit -NoPause:$NoPause; exit 35 }
    }
} else {
    Write-Host "КРИТИЧНА ПОМИЛКА: відсутній BRAVO_RUNTIME_GUARD.ps1 — цілісність комплекту не підтверджена" -ForegroundColor Red
    Wait-BRAVOEarlyManualExit -NoPause:$NoPause
    exit 33
}

# ===== Імпорт модуля =====
try {
    Import-Module (Join-Path $PSScriptRoot 'modules\BRAVO.Installer.UI\BRAVO.Installer.UI.psd1') -Force -ErrorAction Stop
} catch {
    Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити модуль Installer UI: $($_.Exception.Message)" -ForegroundColor Red
    Wait-BRAVOEarlyManualExit -NoPause:$NoPause
    exit 1
}

try {
    # Exit-семантика як у Configurator: exit 0 для нормального закриття вікна;
    # GUI-прототип не виконує mutation і не має власних кодів BRAVO.ExitCodes.
    $installerOutcome = Show-BRAVOInstallerMainForm -ToolkitRoot $PSScriptRoot -RuntimeRoot $RuntimeRoot
    Write-Host "Статус: вікно Installer закрито ($installerOutcome)." -ForegroundColor Cyan
    $exitCode = 0
} catch {
    Write-Host "ПОМИЛКА Installer: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}

Wait-BRAVOEarlyManualExit -NoPause:$NoPause
exit $exitCode
