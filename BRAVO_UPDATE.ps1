[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('State', 'Preflight', 'Plan', 'Execute', 'Install', 'Update', 'Repair', 'Recover', 'Diagnose', 'Initialize')]
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
    # Ідентифікатор каталогу результату елевованого Recover: Operations/<RecoveryId>/result.json під StateRoot (H1).
    [string]$RecoveryId = '',
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

function Test-BRAVOUpdateScriptRootTrusted {
    # H1/P3 #9: елевований процес не повинен виконувати код (guard, модулі BRAVO.Update) із каталогу, який може змінити
    # звичайний користувач. Перевіряємо сам каталог і КОЖНОГО предка: власник Administrators/SYSTEM/TrustedInstaller,
    # немає reparse point, немає Allow-ACE недовірених із правами запису/видалення/зміни прав (InheritOnly не рахується;
    # на предках допустиме лише створення нових елементів — типово для кореня диска). Дублюється свідомо: модуль BRAVO.Update
    # ще не імпортований (імпорт із недовіреного каталогу і є ризиком), тому це єдина функція entrypoint-а без залежностей.
    # -AclReader — seam тестів (param($Path) -> ACL).
    param([Parameter(Mandatory = $true)][string]$Path, [scriptblock]$AclReader = $null)

    $problems = New-Object System.Collections.Generic.List[string]
    $trusted = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', 'S-1-3-4')
    $rights = [System.Security.AccessControl.FileSystemRights]
    $writeMask = [int]($rights::WriteData -bor $rights::AppendData -bor $rights::WriteExtendedAttributes -bor $rights::WriteAttributes -bor $rights::DeleteSubdirectoriesAndFiles -bor $rights::Delete -bor $rights::ChangePermissions -bor $rights::TakeOwnership)
    $createMask = [int]($rights::WriteData -bor $rights::AppendData)
    try {
        $current = [System.IO.Path]::GetFullPath($Path)
        if ($current.Length -gt [System.IO.Path]::GetPathRoot($current).Length) { $current = $current.TrimEnd('\') }
        $isSelf = $true
        while (-not [string]::IsNullOrEmpty($current)) {
            try {
                if (([System.IO.File]::GetAttributes($current) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $problems.Add('reparse point: ' + $current) }
                $acl = $null
                if ($null -ne $AclReader) { $acl = & $AclReader $current } else { $acl = Get-Acl -LiteralPath $current }
                $ownerSid = [string]$acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
                if ($trusted -notcontains $ownerSid) { $problems.Add('власник ' + $ownerSid + ': ' + $current) }
                foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
                    if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
                    if ($trusted -contains [string]$rule.IdentityReference.Value) { continue }
                    if (($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
                    $bits = ([int]$rule.FileSystemRights) -band $writeMask
                    if (-not $isSelf) { $bits = $bits -band (-bnot $createMask) }
                    if ($bits -ne 0) { $problems.Add('запис для ' + [string]$rule.IdentityReference.Value + ' (' + [string]$rule.FileSystemRights + '): ' + $current) }
                }
            } catch {
                $problems.Add('не вдалося перевірити ' + $current + ': ' + $_.Exception.Message)
            }
            $isSelf = $false
            $parent = [System.IO.Path]::GetDirectoryName($current)
            if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) { break }
            $current = $parent
        }
    } catch {
        $problems.Add('шлях не розібрано: ' + $_.Exception.Message)
    }
    return [pscustomobject]@{ IsTrusted = ($problems.Count -eq 0); Problems = $problems.ToArray() }
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

# H1/P3 #9: mutation з правами адміністратора лише з каталогу, який не може змінити звичайний користувач. Перевірка
# ДО guard і імпорту модуля (обидва виконують код із цього каталогу). Read-only дії дозволені.
if (@('Execute', 'Install', 'Update', 'Repair', 'Recover', 'Initialize') -contains $Action) {
    $scriptIsElevated = $false
    try {
        $scriptIsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $scriptIsElevated = $true
    }
    if ($scriptIsElevated) {
        $scriptRootTrust = Test-BRAVOUpdateScriptRootTrusted -Path $PSScriptRoot
        if (-not $scriptRootTrust.IsTrusted) {
            Write-Host 'Запустіть з захищеного каталогу (Program Files або розпакований носій з правами лише адміністраторів): поточний каталог комплекту доступний на запис не лише адміністраторам.' -ForegroundColor Red
            if (-not $AsJson) { foreach ($trustProblem in @($scriptRootTrust.Problems | Select-Object -First 5)) { Write-Host ('  ' + $trustProblem) -ForegroundColor Yellow } }
            Wait-BRAVOEarlyManualExit -NoPause:(-not $pauseAllowed)
            exit 80
        }
    }
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
    RecoveryId        = $RecoveryId
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
