[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('State', 'Preflight', 'Plan', 'Execute', 'Install', 'Update', 'Repair', 'Recover', 'Diagnose')]
    [string]$Action,
    [ValidateSet('', 'Install', 'Update', 'Repair')]
    [string]$Operation = '',
    [string]$RuntimeRoot = '',
    [string]$SourcePath = '',
    [string]$Tag = '',
    [switch]$AllowPrerelease,
    [string]$BackupDestination = '',
    [ValidateSet('All', 'Runtime', 'Scheduler')]
    [string]$Scope = 'All',
    [string]$PlanPath = '',
    [string]$RequestPath = '',
    [string]$ConfirmPlanId = '',
    [switch]$AsJson,
    [string]$ResultPath = '',
    [switch]$NonInteractive,
    [switch]$NoPause
)

# Тонкий CLI Installer v1: лише guard, imports і виклик диспетчера.
# Уся логіка — modules\BRAVO.Update\BRAVO.Update.Worker.ps1
# (Invoke-BRAVOUpdateCliAction). Коди завершення — ENGINE_DESIGN, розділ 10.2.
# -AsJson друкує в stdout ЛИШЕ контрактний JSON; усе людське — без нього.

$interactiveAllowed = -not $AsJson
$pauseAllowed = (-not $NoPause) -and (-not $AsJson)

function Wait-BRAVOEarlyManualExit {
    # Ідентично іншим entrypoint-ам (див. BRAVO_ARCHIV.ps1) — дублюється свідомо.
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

function Invoke-BRAVOUpdateEntryGuard {
    # Guard-блок (патерн BRAVO_CONFIGURATOR.ps1) в ІЗОЛЬОВАНІЙ області функції:
    # dot-source guard-скрипта виконує його param-блок (RuntimeRoot, Mode тощо)
    # і перезаписав би однойменні змінні скрипта. Повертає { Code; Message }.
    # Integrity завжди Enforce (змінна режиму тут не береться).
    param([string]$ToolkitRoot)
    $guardFile = Join-Path $ToolkitRoot 'BRAVO_RUNTIME_GUARD.ps1'
    if (-not (Test-Path -LiteralPath $guardFile -PathType Leaf)) {
        return [pscustomobject]@{ Code = 33; Message = 'КРИТИЧНА ПОМИЛКА: відсутній BRAVO_RUNTIME_GUARD.ps1 — цілісність комплекту не підтверджена' }
    }
    try {
        . $guardFile
    } catch {
        return [pscustomobject]@{ Code = 33; Message = "КРИТИЧНА ПОМИЛКА: не вдалося завантажити BRAVO_RUNTIME_GUARD.ps1: $($_.Exception.Message)" }
    }
    foreach ($guardFunction in @('Test-BRAVORuntimeManifestIntegrity', 'Test-BRAVORuntimeSecuritySettings', 'Test-BRAVOVersionDowngrade')) {
        if (-not (Get-Command -Name $guardFunction -CommandType Function -ErrorAction SilentlyContinue)) {
            return [pscustomobject]@{ Code = 33; Message = "КРИТИЧНА ПОМИЛКА: BRAVO_RUNTIME_GUARD.ps1 не оголосив $guardFunction — цілісність комплекту не підтверджена" }
        }
    }
    $guardMode = 'Enforce'
    $integrity = Test-BRAVORuntimeManifestIntegrity -RuntimeRoot $ToolkitRoot -ManifestPath (Join-Path $ToolkitRoot 'RUNTIME_MANIFEST.json') -Mode $guardMode
    if ((-not $integrity.IsValid) -and $integrity.ShouldBlock) { return [pscustomobject]@{ Code = 33; Message = [string]$integrity.Message } }
    $security = Test-BRAVORuntimeSecuritySettings -ConfigPath (Join-Path $ToolkitRoot 'BRAVO.config') -Mode $guardMode
    if ((-not $security.IsValid) -and $security.ShouldBlock) { return [pscustomobject]@{ Code = 34; Message = [string]$security.Message } }
    # -NoWrite: CLI лише ЧИТАЄ version-state; запис state з read-only
    # entrypoint-а зафіксував би версію до рішення оператора (ENGINE_DESIGN 7.2).
    $versionState = Test-BRAVOVersionDowngrade -RuntimeRoot $ToolkitRoot `
        -StatePath (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'BRAVO\State\BRAVO_VERSION_STATE.json') `
        -Mode $guardMode -NoWrite
    if ((-not $versionState.IsValid) -and $versionState.ShouldBlock) { return [pscustomobject]@{ Code = 35; Message = [string]$versionState.Message } }
    return [pscustomobject]@{ Code = 0; Message = '' }
}

$entryGuard = Invoke-BRAVOUpdateEntryGuard -ToolkitRoot $PSScriptRoot
if ($entryGuard.Code -ne 0) {
    Write-Host $entryGuard.Message -ForegroundColor Red
    Wait-BRAVOEarlyManualExit -NoPause:(-not $pauseAllowed)
    exit $entryGuard.Code
}

# ===== Imports (після guard) =====
try {
    Import-Module (Join-Path $PSScriptRoot 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking -ErrorAction Stop
} catch {
    Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити модуль BRAVO.Update: $($_.Exception.Message)" -ForegroundColor Red
    Wait-BRAVOEarlyManualExit -NoPause:(-not $pauseAllowed)
    exit 1
}

$dispatch = @{
    Action            = $Action
    Operation         = $Operation
    RuntimeRoot       = $RuntimeRoot
    SourcePath        = $SourcePath
    Tag               = $Tag
    BackupDestination = $BackupDestination
    Scope             = $Scope
    PlanPath          = $PlanPath
    RequestPath       = $RequestPath
    ConfirmPlanId     = $ConfirmPlanId
    ScriptPath        = $PSCommandPath
    CandidateRoots    = @($PSScriptRoot)
    # З -AsJson інтерактивне введення неможливе: підтвердження лише -PlanPath + -ConfirmPlanId.
    NonInteractive    = ([bool]$NonInteractive -or [bool]$AsJson)
    AllowPrerelease   = [bool]$AllowPrerelease
}
if ($interactiveAllowed) {
    $dispatch['Prompt'] = { param([string]$Message) Read-Host -Prompt $Message }
    $dispatch['Report'] = { param([string[]]$Line) foreach ($item in $Line) { Write-Host $item } }
}

$outcome = $null
try {
    $outcome = Invoke-BRAVOUpdateCliAction @dispatch
} catch {
    Write-Host "КРИТИЧНА ПОМИЛКА: $($_.Exception.Message)" -ForegroundColor Red
    Wait-BRAVOEarlyManualExit -NoPause:(-not $pauseAllowed)
    exit 80
}

$exitCode = [int]$outcome.ExitCode
$json = ConvertTo-BRAVOUpdateJson -InputObject $outcome.Result
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    try {
        Write-BRAVOUpdateFileAtomic -Path ([IO.Path]::GetFullPath($ResultPath)) -Text $json
    } catch {
        if (-not $AsJson) { Write-Host "Не вдалося записати -ResultPath: $($_.Exception.Message)" -ForegroundColor Yellow }
        if ($exitCode -eq 0) { $exitCode = 80 }
    }
}
if ($AsJson) {
    Write-Output $json
} else {
    foreach ($line in @($outcome.Lines)) { Write-Host $line }
}
Wait-BRAVOEarlyManualExit -NoPause:(-not $pauseAllowed)
exit $exitCode
