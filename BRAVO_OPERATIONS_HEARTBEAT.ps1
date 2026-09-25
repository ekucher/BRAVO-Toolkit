[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$NoPause
)

# Тонкий entrypoint для періодичного heartbeat BSYSTEM Operations
# (BRAVO.Operations, Task #3/Etap 2). Guard/config-завантаження — той
# самий шаблон, що BRAVO_MAINTENANCE.ps1; уся heartbeat-логіка канонічно
# живе в модулі BRAVO.Operations, тут лише оркестрація.
function Wait-BRAVOEarlyManualExit {
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

$configPathWasExplicit = $PSBoundParameters.ContainsKey('ConfigPath') -and
    -not [string]::IsNullOrWhiteSpace($ConfigPath)

$effectiveConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    Join-Path $PSScriptRoot 'BRAVO.config'
} else {
    [Environment]::ExpandEnvironmentVariables($ConfigPath)
}
try {
    $effectiveConfigPath = [System.IO.Path]::GetFullPath($effectiveConfigPath)
} catch {
    $effectiveConfigPath = [string]$effectiveConfigPath
}
$ConfigPath = $effectiveConfigPath

$runtimeGuardPath = Join-Path $PSScriptRoot 'BRAVO_RUNTIME_GUARD.ps1'
if (Test-Path -LiteralPath $runtimeGuardPath -PathType Leaf) {
    try {
        . $runtimeGuardPath
    } catch {
        Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити BRAVO_RUNTIME_GUARD.ps1: $($_.Exception.Message)" -ForegroundColor Red
        Wait-BRAVOEarlyManualExit -NoPause:$NoPause
        exit 33
    }
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
        -ConfigPath $effectiveConfigPath `
        -Mode $runtimeIntegrityMode
    if (-not $securitySettings.IsValid) {
        $securityColor = if ($securitySettings.ShouldBlock) { 'Red' } else { 'Yellow' }
        Write-Host $securitySettings.Message -ForegroundColor $securityColor
        if ($securitySettings.ShouldBlock) { Wait-BRAVOEarlyManualExit -NoPause:$NoPause; exit 34 }
    }

    $versionState = Test-BRAVOVersionDowngrade `
        -RuntimeRoot $PSScriptRoot `
        -StatePath (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'BRAVO\State\BRAVO_VERSION_STATE.json') `
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

foreach ($moduleName in @('BRAVO.Compatibility', 'BRAVO.Credentials', 'BRAVO.Logging', 'BRAVO.Operations')) {
    $moduleManifestPath = Join-Path $PSScriptRoot "modules\$moduleName\$moduleName.psd1"
    try {
        Import-Module -Name $moduleManifestPath -ErrorAction Stop
    } catch {
        Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити модуль $moduleManifestPath : $($_.Exception.Message)" -ForegroundColor Red
        Wait-BRAVOEarlyManualExit -NoPause:$NoPause
        exit 90
    }
}

try {
    $configRoot = Split-Path -Path $ConfigPath -Parent
    $configurationLoaderPath = Join-Path $PSScriptRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration `
        -ConfigRoot $configRoot `
        -ConfigPath $ConfigPath `
        -RuntimeRoot $PSScriptRoot `
        -ConfigPathWasExplicit:$configPathWasExplicit

    if ($null -eq $global:credentialSettings -or
        $null -eq (Get-Command -Name Initialize-BRAVOCredentialManager -ErrorAction SilentlyContinue)) {
        throw "вбудований Credential Manager недоступний"
    }
    [void](Import-BRAVOInstitutionSettings `
        -CredentialSettings $global:credentialSettings `
        -BravoSettings $global:bravoSettings)
} catch {
    Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити конфігурацію: $($_.Exception.Message)" -ForegroundColor Red
    Wait-BRAVOEarlyManualExit -NoPause:$NoPause
    exit 30
}

if (-not (Test-Path -LiteralPath 'Variable:global:operationsReportingSettings')) {
    Write-Host "operationsReportingSettings відсутній у конфігурації — heartbeat пропущено" -ForegroundColor Yellow
    Wait-BRAVOEarlyManualExit -NoPause:$NoPause
    exit 0
}

$bravoVersion = [string]$global:ScriptVersion

Send-BRAVOOperationsHeartbeat `
    -OperationsReportingSettings $global:operationsReportingSettings `
    -CredentialTargets $global:credentialSettings.Targets `
    -InstitutionCode ([string]$global:bravoSettings.InstitutionCode) `
    -BravoVersion $bravoVersion

Wait-BRAVOEarlyManualExit -NoPause:$NoPause
exit 0
