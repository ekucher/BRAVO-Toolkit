# ============================================================
# UpdatePlan: побудова плану розгортання Installer v1 (INS-023)
# ============================================================
# Перевіряється реальний модуль BRAVO.Update (частина Plan) на тимчасових
# fixture-каталогах із згенерованими integrity-манифестами. Диск/задачі/
# Credential Manager не чіпаються: adapter підміняється stub-ом, усі корені —
# у тимчасовому каталозі з пробілами та кирилицею.

Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking

$planTestModule = Get-Module BRAVO.Update

function Invoke-BRAVOPlanTestCall {
    # Виклик приватної/публічної функції модуля за ім'ям із splat-параметрами.
    param([string]$Name, [hashtable]$Params = @{})
    return (& $planTestModule { param($FunctionName, $FunctionParams) & $FunctionName @FunctionParams } $Name $Params)
}

function New-BRAVOPlanTestTree {
    # Створює дерево файлів + RUNTIME_MANIFEST.json (SHA-256, UPPER).
    # Files: hashtable відносний-шлях -> вміст. Манифест рахується з реальних файлів.
    param([string]$Path, [hashtable]$Files, [switch]$NoManifest)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $manifestFiles = [ordered]@{}
    foreach ($relative in @($Files.Keys)) {
        $full = Join-Path $Path ($relative -replace '/', '\')
        $dir = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($full, [string]$Files[$relative], (New-Object Text.UTF8Encoding $false))
        $manifestFiles[$relative] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToUpperInvariant()
    }
    if (-not $NoManifest) {
        $manifestText = ([pscustomobject]@{ files = [pscustomobject]$manifestFiles } | ConvertTo-Json -Depth 5)
        [IO.File]::WriteAllText((Join-Path $Path 'RUNTIME_MANIFEST.json'), $manifestText, (New-Object Text.UTF8Encoding $false))
    }
}

function New-BRAVOPlanTestVersionJson {
    param([string]$Version)
    return ('{"packageVersion": "' + $Version + '", "releaseChannel": "stable"}')
}

$planTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO план тест ' + [guid]::NewGuid().ToString('N'))
$planTestPrefix = Join-Path ([IO.Path]::GetTempPath()) 'BRAVO план тест '
try {
    New-Item -ItemType Directory -Path $planTestRoot -Force | Out-Null

    # Спільні fixture: runtime 5.2.6 і staged 5.3.0.
    $runtime = Join-Path $planTestRoot 'Програми Toolkit\runtime'
    $staged = Join-Path $planTestRoot 'staging\staged'
    $stagingRoot = Join-Path $planTestRoot 'staging'
    $backupRoot = Join-Path $planTestRoot 'backup'
    $stateRoot = Join-Path $planTestRoot 'state'
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

    New-BRAVOPlanTestTree -Path $runtime -Files @{
        'a.txt'                 = 'однаковий'
        'b.txt'                 = 'старий b'
        'c.txt'                 = 'буде видалено'
        'дані/файл.txt'         = 'кирилиця'
        'VERSION.json'          = (New-BRAVOPlanTestVersionJson '5.2.6')
        'BRAVO.config'          = 'site config'
        'BRAVO.local.config'    = '{"local":1}'
        'LOGS/old.log'          = 'лог'
        'sub/WinSCP.ini'        = 'site ini'
    }
    New-BRAVOPlanTestTree -Path $staged -Files @{
        'a.txt'                 = 'однаковий'
        'b.txt'                 = 'новий b'
        'd.txt'                 = 'додано'
        'дані/новий.txt'        = 'нове'
        'VERSION.json'          = (New-BRAVOPlanTestVersionJson '5.3.0')
        'BRAVO.config'          = 'артефактний config'
        'LOGS/x.log'            = 'не повинно рахуватись'
        'TOOLS_INTEGRITY.json'  = '{}'
    }
    # VERSION.json: runtime-файл змінює хеш, тому той самий файл рахується у delta як changed (це очікувано).

    $source = [pscustomobject]@{
        kind = 'Offline'; tag = 'v5.3.0'; artifactName = 'BRAVO-Toolkit-5.3.0.zip'
        artifactSha256 = ('A' * 64); manifestSha256 = ('B' * 64)
        packageVersion = '5.3.0'; releaseChannel = 'stable'; prereleaseAuthorized = $false
    }
    $preflightOk = [pscustomobject]@{ findings = @(); canProceed = $true; blockerCount = 0; warningCount = 0 }
    $adapterState = @{ Enabled = $true }
    $adapter = @{
        GetManagedTasks = { @([pscustomobject]@{ Name = 'BRAVO-Б'; Enabled = $adapterState.Enabled }, [pscustomobject]@{ Name = 'BRAVO-А'; Enabled = $true }) }
    }
    $fixedNow = [datetime]::SpecifyKind([datetime]'2026-10-29T10:00:00', [DateTimeKind]::Utc)

    function Get-BRAVOPlanTestPlan {
        param([string]$Action = 'Update', $PlanSource = $source, $State = $null, $Preflight = $preflightOk,
              [string]$RuntimePath = $runtime, [string]$StagedPath = $staged, [hashtable]$PlanAdapter = $adapter)
        $params = @{
            Action = $Action; RuntimeRoot = $RuntimePath; StagingRoot = $stagingRoot; BackupRoot = $backupRoot
            StateRoot = $stateRoot; Source = $PlanSource; StagedRoot = $StagedPath; Preflight = $Preflight
            Adapter = $PlanAdapter; Now = $fixedNow
        }
        if ($null -ne $State) { $params['InstallationState'] = $State }
        return (Invoke-BRAVOPlanTestCall -Name 'New-BRAVODeploymentPlan' -Params $params)
    }
    function Get-BRAVOPlanTestFindingIds {
        param($Plan, [string]$Severity = 'Blocker')
        return @(@($Plan.findings) | Where-Object { $_.severity -eq $Severity } | ForEach-Object { $_.id })
    }
    function New-BRAVOPlanTestState {
        param([string]$State, [string]$Version)
        $versionObject = $null
        if (-not [string]::IsNullOrEmpty($Version)) { $versionObject = [pscustomobject]@{ packageVersion = $Version } }
        return [pscustomobject]@{ state = $State; version = $versionObject }
    }

    # --- Site-owned: єдиний набір ---
    & {
        $owned = Invoke-BRAVOPlanTestCall -Name 'Get-BRAVOUpdateSiteOwnedPaths'
        Test-BRAVOCondition -Condition (@($owned.Files).Count -eq 5 -and @($owned.Files) -contains 'BRAVO.local.config' -and @($owned.Files) -contains 'BRAVO_OPERATION.lock' -and @($owned.Files) -contains 'WinSCP.ini' -and @($owned.Files) -contains 'TOOLS_INTEGRITY.json' -and @($owned.Files) -contains 'BRAVO.config') `
            -Name 'UpdatePlan/SiteOwnedFiles' -Failure 'набір site-owned файлів мусить збігатися з robocopy /XF розгортання'
        Test-BRAVOCondition -Condition (@($owned.Dirs).Count -eq 11 -and @($owned.Dirs) -contains '.claude' -and @($owned.Dirs) -contains 'artifacts' -and @($owned.Dirs) -contains 'LOGS' -and @($owned.Dirs) -contains 'BAZA_WWW' -and @($owned.Dirs) -contains 'local-backups' -and @($owned.Dirs) -contains '.git' -and @($owned.Dirs) -contains '.vscode') `
            -Name 'UpdatePlan/SiteOwnedDirs' -Failure 'набір site-owned каталогів мусить збігатися з robocopy /XD розгортання'
        $owned.Files[0] = 'змінено'
        $again = Invoke-BRAVOPlanTestCall -Name 'Get-BRAVOUpdateSiteOwnedPaths'
        Test-BRAVOCondition -Condition (@($again.Files) -contains 'BRAVO.config') `
            -Name 'UpdatePlan/SiteOwnedAccessorReturnsCopy' -Failure 'зміна результату accessor-а не має псувати константу'
    }

    # --- Дельта файлів ---
    & {
        $delta = Invoke-BRAVOPlanTestCall -Name 'Get-BRAVODeploymentFileDelta' -Params @{ RuntimeRoot = $runtime; StagedRoot = $staged }
        # Added: d.txt, дані/новий.txt; Changed: b.txt, VERSION.json; Removed: c.txt, дані/файл.txt.
        # BRAVO.config / LOGS / TOOLS_INTEGRITY / WinSCP.ini / BRAVO.local.config — site-owned, не рахуються.
        Test-BRAVOCondition -Condition ($delta.FilesAdded -eq 2 -and @($delta.Added) -contains 'd.txt' -and @($delta.Added) -contains 'дані/новий.txt') `
            -Name 'UpdatePlan/DeltaAdded' -Failure ('очікувалось 2 додані, отримано ' + $delta.FilesAdded + ': ' + (@($delta.Added) -join ','))
        Test-BRAVOCondition -Condition ($delta.FilesChanged -eq 2 -and @($delta.Changed) -contains 'b.txt' -and @($delta.Changed) -contains 'VERSION.json') `
            -Name 'UpdatePlan/DeltaChanged' -Failure ('очікувалось 2 змінені, отримано ' + $delta.FilesChanged + ': ' + (@($delta.Changed) -join ','))
        Test-BRAVOCondition -Condition ($delta.FilesRemoved -eq 2 -and @($delta.Removed) -contains 'c.txt' -and @($delta.Removed) -contains 'дані/файл.txt') `
            -Name 'UpdatePlan/DeltaRemoved' -Failure ('очікувалось 2 видалені, отримано ' + $delta.FilesRemoved + ': ' + (@($delta.Removed) -join ','))
        $all = @($delta.Added) + @($delta.Changed) + @($delta.Removed)
        $leaked = @($all | Where-Object { $_ -match 'BRAVO\.config|BRAVO\.local\.config|LOGS|TOOLS_INTEGRITY|WinSCP\.ini' })
        Test-BRAVOCondition -Condition ($leaked.Count -eq 0) `
            -Name 'UpdatePlan/DeltaExcludesSiteOwned' -Failure ('site-owned потрапили в дельту: ' + ($leaked -join ','))
        Test-BRAVOCondition -Condition ($delta.RuntimeManifestPresent -eq $true) `
            -Name 'UpdatePlan/DeltaRuntimeManifestPresent' -Failure 'RuntimeManifestPresent мусить бути true'

        # 0 змін: staged = runtime (крім site-owned)
        $same = Join-Path $planTestRoot 'same'
        New-BRAVOPlanTestTree -Path $same -Files @{ 'x.txt' = '1' }
        $sameStaged = Join-Path $planTestRoot 'same-staged'
        New-BRAVOPlanTestTree -Path $sameStaged -Files @{ 'x.txt' = '1' }
        $zero = Invoke-BRAVOPlanTestCall -Name 'Get-BRAVODeploymentFileDelta' -Params @{ RuntimeRoot = $same; StagedRoot = $sameStaged }
        Test-BRAVOCondition -Condition ($zero.FilesAdded -eq 0 -and $zero.FilesChanged -eq 0 -and $zero.FilesRemoved -eq 0 -and @($zero.Added).Count -eq 0) `
            -Name 'UpdatePlan/DeltaZero' -Failure 'однакові дерева мають давати нульову дельту'

        # Install: runtime без манифесту -> все Added
        $emptyRuntime = Join-Path $planTestRoot 'порожній runtime'
        New-Item -ItemType Directory -Path $emptyRuntime -Force | Out-Null
        $install = Invoke-BRAVOPlanTestCall -Name 'Get-BRAVODeploymentFileDelta' -Params @{ RuntimeRoot = $emptyRuntime; StagedRoot = $staged }
        Test-BRAVOCondition -Condition ($install.RuntimeManifestPresent -eq $false -and $install.FilesAdded -eq 5 -and $install.FilesRemoved -eq 0) `
            -Name 'UpdatePlan/DeltaInstallAllAdded' -Failure ('Install без манифесту runtime: усе Added (5 без site-owned), отримано ' + $install.FilesAdded)

        # Пошкоджений/відсутній манифест staged -> виняток (fail closed)
        $noManifest = Join-Path $planTestRoot 'staged-no-manifest'
        New-BRAVOPlanTestTree -Path $noManifest -Files @{ 'x.txt' = '1' } -NoManifest
        $threw = $false
        try { $null = Invoke-BRAVOPlanTestCall -Name 'Get-BRAVODeploymentFileDelta' -Params @{ RuntimeRoot = $runtime; StagedRoot = $noManifest } } catch { $threw = $true }
        Test-BRAVOCondition -Condition $threw `
            -Name 'UpdatePlan/DeltaMissingStagedManifestThrows' -Failure 'без манифесту staged дельту рахувати не можна'
    }

    # --- Footprint ---
    & {
        $fp = Invoke-BRAVOPlanTestCall -Name 'Get-BRAVODeploymentFootprint' -Params @{ StagedRoot = $staged; RuntimeRoot = $runtime; StagingRoot = $stagingRoot; BackupRoot = $backupRoot }
        Test-BRAVOCondition -Condition ($fp.reserveBytes -eq 512MB -and $fp.stagingBytes -gt 0 -and $fp.deployBytes -eq $fp.stagingBytes) `
            -Name 'UpdatePlan/FootprintStagedAndReserve' -Failure 'staging = deploy = розмір staged, резерв 512 MB'
        # Backup = runtime без site-owned: a,b,c,дані/файл,VERSION.json + RUNTIME_MANIFEST.json (BRAVO.config/local/LOGS/WinSCP.ini виключені)
        $expectedBackup = 0
        foreach ($rel in @('a.txt', 'b.txt', 'c.txt', 'дані\файл.txt', 'VERSION.json', 'RUNTIME_MANIFEST.json')) {
            $expectedBackup += (Get-Item -LiteralPath (Join-Path $runtime $rel)).Length
        }
        Test-BRAVOCondition -Condition ($fp.backupBytes -eq $expectedBackup) `
            -Name 'UpdatePlan/FootprintBackupExcludesSiteOwned' -Failure ('backup=' + $fp.backupBytes + ', очікувалось ' + $expectedBackup)
        # Усі корені на одному томі: потреба = сума + резерв один раз.
        Test-BRAVOCondition -Condition (@($fp.volumes).Count -eq 1 -and $fp.requiredFreeBytes -eq ($fp.stagingBytes + $fp.backupBytes + $fp.deployBytes + 512MB)) `
            -Name 'UpdatePlan/FootprintAggregatesPerVolume' -Failure ('required=' + $fp.requiredFreeBytes)
        Test-BRAVOCondition -Condition ($null -ne $fp.availableFreeBytes -and $fp.availableFreeBytes -gt 0 -and -not [string]::IsNullOrEmpty($fp.volume)) `
            -Name 'UpdatePlan/FootprintAvailable' -Failure 'DriveInfo мав повернути вільне місце локального тому'
        # Відсутній runtime = backup 0
        $fp0 = Invoke-BRAVOPlanTestCall -Name 'Get-BRAVODeploymentFootprint' -Params @{ StagedRoot = $staged; RuntimeRoot = (Join-Path $planTestRoot 'нема'); StagingRoot = $stagingRoot; BackupRoot = $backupRoot }
        Test-BRAVOCondition -Condition ($fp0.backupBytes -eq 0) `
            -Name 'UpdatePlan/FootprintNoRuntimeZeroBackup' -Failure 'без runtime backup = 0'
        # UNC: том невідомий -> availableFreeBytes = $null, без винятку
        $fpUnc = Invoke-BRAVOPlanTestCall -Name 'Get-BRAVODeploymentFootprint' -Params @{ StagedRoot = $staged; RuntimeRoot = $runtime; StagingRoot = '\\host-a\share\staging'; BackupRoot = $backupRoot }
        Test-BRAVOCondition -Condition (@($fpUnc.volumes).Count -eq 2 -and $null -eq $fpUnc.availableFreeBytes) `
            -Name 'UpdatePlan/FootprintUnknownVolumeIsNull' -Failure 'невідомий том має давати availableFreeBytes = $null (найгірший)'
    }

    # --- Версії: Update ---
    & {
        $up = Get-BRAVOPlanTestPlan -Action 'Update' -State (New-BRAVOPlanTestState 'Installed' '5.2.6')
        Test-BRAVOCondition -Condition (@(Get-BRAVOPlanTestFindingIds $up).Count -eq 0 -and $up.currentVersion -eq '5.2.6' -and $up.targetVersion -eq '5.3.0') `
            -Name 'UpdatePlan/UpdateGreaterOk' -Failure ('блокери: ' + ((Get-BRAVOPlanTestFindingIds $up) -join ','))

        $equalSource = $source.PSObject.Copy(); $equalSource.packageVersion = '5.2.6'
        $equalStaged = Join-Path $planTestRoot 'equal-staged'
        New-BRAVOPlanTestTree -Path $equalStaged -Files @{ 'a.txt' = 'однаковий' }
        $eq = Get-BRAVOPlanTestPlan -Action 'Update' -PlanSource $equalSource -State (New-BRAVOPlanTestState 'Installed' '5.2.6') -StagedPath $equalStaged
        $eqFinding = @($eq.findings | Where-Object { $_.id -eq 'Plan.UpdateSameVersion' })
        Test-BRAVOCondition -Condition ($eqFinding.Count -eq 1 -and $eqFinding[0].action -match 'Відновити') `
            -Name 'UpdatePlan/UpdateEqualSuggestsRepair' -Failure 'рівна версія: blocker із підказкою «Відновити»'

        $lowSource = $source.PSObject.Copy(); $lowSource.packageVersion = '5.1.0'
        $lowStaged = Join-Path $planTestRoot 'low-staged'
        New-BRAVOPlanTestTree -Path $lowStaged -Files @{ 'a.txt' = 'однаковий' }
        $low = Get-BRAVOPlanTestPlan -Action 'Update' -PlanSource $lowSource -State (New-BRAVOPlanTestState 'Installed' '5.2.6') -StagedPath $lowStaged
        $lowFinding = @($low.findings | Where-Object { $_.id -eq 'Plan.UpdateDowngrade' })
        Test-BRAVOCondition -Condition ($lowFinding.Count -eq 1 -and $lowFinding[0].severity -eq 'Blocker' -and $lowFinding[0].exitCodeHint -eq 35) `
            -Name 'UpdatePlan/UpdateLowerBlockedExit35' -Failure 'нижча версія: Blocker з exitCodeHint 35'

        # Prerelease: 5.3.0-rc.1 -> 5.3.0 stable дозволено; 5.3.0 -> 5.3.0-rc.1 = відкат
        $preStaged = Join-Path $planTestRoot 'pre-staged'
        New-BRAVOPlanTestTree -Path $preStaged -Files @{ 'a.txt' = 'однаковий' }
        $stableTarget = $source.PSObject.Copy()
        $upFromRc = Get-BRAVOPlanTestPlan -Action 'Update' -PlanSource $stableTarget -State (New-BRAVOPlanTestState 'PrereleaseInstalled' '5.3.0-rc.1') -StagedPath $preStaged
        Test-BRAVOCondition -Condition (@(Get-BRAVOPlanTestFindingIds $upFromRc).Count -eq 0) `
            -Name 'UpdatePlan/PrereleaseToStableAllowed' -Failure ('5.3.0 > 5.3.0-rc.1: ' + ((Get-BRAVOPlanTestFindingIds $upFromRc) -join ','))
        $rcSource = $source.PSObject.Copy(); $rcSource.packageVersion = '5.3.0-rc.1'; $rcSource.releaseChannel = 'rc'; $rcSource.prereleaseAuthorized = $true
        $downToRc = Get-BRAVOPlanTestPlan -Action 'Update' -PlanSource $rcSource -State (New-BRAVOPlanTestState 'Installed' '5.3.0') -StagedPath $preStaged
        Test-BRAVOCondition -Condition (@(Get-BRAVOPlanTestFindingIds $downToRc) -contains 'Plan.UpdateDowngrade') `
            -Name 'UpdatePlan/StableToPrereleaseIsDowngrade' -Failure '5.3.0 -> 5.3.0-rc.1 має бути відкатом'
        $rcLater = $source.PSObject.Copy(); $rcLater.packageVersion = '5.3.0-rc.2'; $rcLater.releaseChannel = 'rc'; $rcLater.prereleaseAuthorized = $true
        $rcUp = Get-BRAVOPlanTestPlan -Action 'Update' -PlanSource $rcLater -State (New-BRAVOPlanTestState 'PrereleaseInstalled' '5.3.0-rc.1') -StagedPath $preStaged
        Test-BRAVOCondition -Condition (@(Get-BRAVOPlanTestFindingIds $rcUp).Count -eq 0) `
            -Name 'UpdatePlan/PrereleaseOrderingRcToRc' -Failure 'rc.2 > rc.1 має бути оновленням'
        $rcNoAuth = $rcLater.PSObject.Copy(); $rcNoAuth.prereleaseAuthorized = $false
        $rcBlocked = Get-BRAVOPlanTestPlan -Action 'Update' -PlanSource $rcNoAuth -State (New-BRAVOPlanTestState 'PrereleaseInstalled' '5.3.0-rc.1') -StagedPath $preStaged
        Test-BRAVOCondition -Condition (@(Get-BRAVOPlanTestFindingIds $rcBlocked) -contains 'Plan.PrereleaseNotAuthorized') `
            -Name 'UpdatePlan/PrereleaseWithoutAuthorizationBlocked' -Failure 'prerelease без дозволу має блокуватись'

        # Некоректна поточна версія -> fail closed
        $bad = Get-BRAVOPlanTestPlan -Action 'Update' -State (New-BRAVOPlanTestState 'Installed' 'не-версія')
        Test-BRAVOCondition -Condition (@(Get-BRAVOPlanTestFindingIds $bad) -contains 'Plan.VersionCompareFailed') `
            -Name 'UpdatePlan/MalformedCurrentVersionFailsClosed' -Failure 'некоректна версія мусить блокувати'

        # Без InstallationState: версія береться з VERSION.json runtime
        $noState = Get-BRAVOPlanTestPlan -Action 'Update'
        Test-BRAVOCondition -Condition ($noState.currentVersion -eq '5.2.6') `
            -Name 'UpdatePlan/CurrentVersionFromVersionJson' -Failure 'без state версія береться з VERSION.json'

        # Невідома поточна версія (немає VERSION.json і state)
        $unknown = Get-BRAVOPlanTestPlan -Action 'Update' -RuntimePath (Join-Path $planTestRoot 'нема-runtime')
        Test-BRAVOCondition -Condition (@(Get-BRAVOPlanTestFindingIds $unknown) -contains 'Plan.CurrentVersionUnknown') `
            -Name 'UpdatePlan/UpdateUnknownCurrentBlocked' -Failure 'Update без поточної версії мусить блокуватись'
    }

    # --- Версії: Repair та Install ---
    & {
        $sameSource = $source.PSObject.Copy(); $sameSource.packageVersion = '5.2.6'
        $sameStaged = Join-Path $planTestRoot 'repair-staged'
        New-BRAVOPlanTestTree -Path $sameStaged -Files @{ 'a.txt' = 'однаковий'; 'VERSION.json' = (New-BRAVOPlanTestVersionJson '5.2.6') }
        $repair = Get-BRAVOPlanTestPlan -Action 'Repair' -PlanSource $sameSource -State (New-BRAVOPlanTestState 'RepairRequired' '5.2.6') -StagedPath $sameStaged
        Test-BRAVOCondition -Condition (@(Get-BRAVOPlanTestFindingIds $repair).Count -eq 0) `
            -Name 'UpdatePlan/RepairSameVersionOk' -Failure ('блокери: ' + ((Get-BRAVOPlanTestFindingIds $repair) -join ','))
        Test-BRAVOCondition -Condition (@($repair.tests.skipped).Count -eq 1 -and $repair.tests.skipped[0].id -eq 'SelfTest' -and -not [string]::IsNullOrEmpty($repair.tests.skipped[0].reason) -and (@($repair.tests.planned | Where-Object { $_.id -eq 'SelfTest' }).Count -eq 0)) `
            -Name 'UpdatePlan/RepairSkipsSelfTestWithReason' -Failure 'Repair: self-test пропущено з причиною'

        $repairNewer = Get-BRAVOPlanTestPlan -Action 'Repair' -State (New-BRAVOPlanTestState 'Installed' '5.2.6')
        $mismatch = @($repairNewer.findings | Where-Object { $_.id -eq 'Plan.RepairVersionMismatch' })
        Test-BRAVOCondition -Condition ($mismatch.Count -eq 1 -and $mismatch[0].title -eq 'відновлення не виконує оновлення версії') `
            -Name 'UpdatePlan/RepairDifferentVersionBlocked' -Failure 'Repair із іншою версією — Blocker із заданим текстом'

        $emptyRuntime = Join-Path $planTestRoot 'install-runtime'
        $install = Get-BRAVOPlanTestPlan -Action 'Install' -RuntimePath $emptyRuntime -State (New-BRAVOPlanTestState 'NotInstalled' $null)
        Test-BRAVOCondition -Condition (@(Get-BRAVOPlanTestFindingIds $install).Count -eq 0 -and $null -eq $install.currentVersion -and (@($install.tests.planned | Where-Object { $_.id -eq 'SelfTest' }).Count -eq 1)) `
            -Name 'UpdatePlan/InstallOnNotInstalledOk' -Failure ('блокери: ' + ((Get-BRAVOPlanTestFindingIds $install) -join ','))
        $installOn = Get-BRAVOPlanTestPlan -Action 'Install' -State (New-BRAVOPlanTestState 'Installed' '5.2.6')
        Test-BRAVOCondition -Condition (@(Get-BRAVOPlanTestFindingIds $installOn) -contains 'Plan.InstallOnExisting') `
            -Name 'UpdatePlan/InstallOnInstalledBlocked' -Failure 'Install на встановленому — Blocker'
        $installNoState = Get-BRAVOPlanTestPlan -Action 'Install'
        Test-BRAVOCondition -Condition (@(Get-BRAVOPlanTestFindingIds $installNoState) -contains 'Plan.InstallOnExisting') `
            -Name 'UpdatePlan/InstallDetectsVersionJsonWithoutState' -Failure 'без state наявний VERSION.json означає, що встановлено'
    }

    # --- Структура плану ---
    & {
        $warnFinding = [pscustomobject]@{ id = 'Preflight.Disk'; severity = 'Warning'; title = 'попередження'; meaning = ''; action = ''; details = ''; exitCodeHint = $null }
        $blockFinding = [pscustomobject]@{ id = 'Preflight.Lock'; severity = 'Blocker'; title = 'блокер'; meaning = ''; action = 'зробіть'; details = ''; exitCodeHint = 20 }
        $okFinding = [pscustomobject]@{ id = 'Preflight.Fine'; severity = 'Ok'; title = 'добре'; meaning = ''; action = ''; details = ''; exitCodeHint = $null }
        $preflight = [pscustomobject]@{ findings = @($warnFinding, $blockFinding, $okFinding); canProceed = $false }
        $plan = Get-BRAVOPlanTestPlan -Action 'Update' -State (New-BRAVOPlanTestState 'Installed' '5.2.6') -Preflight $preflight
        Test-BRAVOCondition -Condition ((Get-BRAVOPlanTestFindingIds $plan) -contains 'Preflight.Lock' -and (Get-BRAVOPlanTestFindingIds $plan 'Warning') -contains 'Preflight.Disk' -and @($plan.findings | Where-Object { $_.id -eq 'Preflight.Fine' }).Count -eq 0) `
            -Name 'UpdatePlan/PreflightFindingsCopied' -Failure 'мають копіюватись Blocker і Warning, але не Ok'

        $missing = Get-BRAVOPlanTestPlan -Action 'Update' -State (New-BRAVOPlanTestState 'Installed' '5.2.6') -Preflight ([pscustomobject]@{})
        Test-BRAVOCondition -Condition ((Get-BRAVOPlanTestFindingIds $missing) -contains 'Plan.PreflightMissing') `
            -Name 'UpdatePlan/PreflightWithoutFindingsBlocked' -Failure 'preflight без findings — fail closed'

        $good = Get-BRAVOPlanTestPlan -Action 'Update' -State (New-BRAVOPlanTestState 'Installed' '5.2.6')
        Test-BRAVOCondition -Condition ($good.schemaVersion -eq 1 -and $good.requiresConfirmation -eq $true -and $good.action -eq 'Update' -and $good.planId -match '^[0-9a-f]{8}-' -and $good.operationId -match '^[0-9a-f]{8}-' -and $good.planId -ne $good.operationId) `
            -Name 'UpdatePlan/PlanBasics' -Failure 'schemaVersion, GUID у нижньому регістрі, requiresConfirmation = true'
        Test-BRAVOCondition -Condition ($good.createdUtc -eq $fixedNow.ToString('o') -and $good.expiresUtc -eq $fixedNow.AddMinutes(30).ToString('o')) `
            -Name 'UpdatePlan/DefaultTtl30Minutes' -Failure ('created=' + $good.createdUtc + ' expires=' + $good.expiresUtc)
        Test-BRAVOCondition -Condition ($good.changes.scheduler.activationPolicy -eq 'ActivateOnSuccessOnly' -and @($good.changes.scheduler.tasks).Count -eq 2 -and $good.changes.scheduler.tasks[0].name -eq 'BRAVO-А') `
            -Name 'UpdatePlan/SchedulerPolicyAndSortedTasks' -Failure 'політика ActivateOnSuccessOnly, задачі відсортовані'
        Test-BRAVOCondition -Condition (@($good.changes.configuration.delta).Count -eq 0 -and $good.changes.configuration.note -eq 'BRAVO.local.config зберігається побайтово' -and $good.changes.configuration.localConfigPreserved -eq $true -and $good.changes.configuration.legacyConfigPreserved -eq $true) `
            -Name 'UpdatePlan/ConfigurationPreserved' -Failure 'конфігурація: delta порожня, нотатка про побайтове збереження'
        Test-BRAVOCondition -Condition (@($good.preserved).Count -ge 5 -and (@($good.preserved | Where-Object { $_ -notmatch '[А-Яа-яІіЇїЄє]' }).Count -eq 0)) `
            -Name 'UpdatePlan/PreservedUkrainianItems' -Failure 'preserved[] має бути явним українським переліком'
        Test-BRAVOCondition -Condition (@($good.tests.planned | ForEach-Object { $_.id }) -join ',' -eq 'RuntimeGuard,SetupValidate,SchedulerReconcile,SelfTest') `
            -Name 'UpdatePlan/UpdateTestsPlanned' -Failure 'Update: guard, setup validate, scheduler reconcile, self-test'
        Test-BRAVOCondition -Condition ($good.changes.filesAdded -eq 2 -and $good.changes.filesChanged -eq 2 -and $good.changes.filesRemoved -eq 2 -and $null -ne $good.footprint) `
            -Name 'UpdatePlan/PlanCarriesDeltaAndFootprint' -Failure 'план містить кількості дельти й footprint'
        Test-BRAVOCondition -Condition ($good.preconditionsFingerprint -match '^[0-9A-F]{64}$' -and $good.source.artifactSha256 -eq ('A' * 64)) `
            -Name 'UpdatePlan/FingerprintFormat' -Failure 'fingerprint = SHA-256 hex UPPER'

        # Пошкоджений манифест staged не валить побудову: Blocker
        $brokenStaged = Join-Path $planTestRoot 'broken-staged'
        New-BRAVOPlanTestTree -Path $brokenStaged -Files @{ 'a.txt' = '1' } -NoManifest
        [IO.File]::WriteAllText((Join-Path $brokenStaged 'RUNTIME_MANIFEST.json'), '{ не json', (New-Object Text.UTF8Encoding $false))
        $broken = Get-BRAVOPlanTestPlan -Action 'Update' -State (New-BRAVOPlanTestState 'Installed' '5.2.6') -StagedPath $brokenStaged
        Test-BRAVOCondition -Condition ((Get-BRAVOPlanTestFindingIds $broken) -contains 'Plan.DeltaFailed') `
            -Name 'UpdatePlan/CorruptStagedManifestBlocker' -Failure 'пошкоджений манифест staged — Blocker Plan.DeltaFailed'

        # Невідповідність staged VERSION.json джерелу
        $mismatchSource = $source.PSObject.Copy(); $mismatchSource.packageVersion = '5.4.0'
        $mm = Get-BRAVOPlanTestPlan -Action 'Update' -PlanSource $mismatchSource -State (New-BRAVOPlanTestState 'Installed' '5.2.6')
        Test-BRAVOCondition -Condition ((Get-BRAVOPlanTestFindingIds $mm) -contains 'Plan.StagedVersionMismatch') `
            -Name 'UpdatePlan/StagedVersionMismatchBlocked' -Failure 'staged 5.3.0 проти джерела 5.4.0 — Blocker'
    }

    # --- Fingerprint, актуальність, TTL ---
    & {
        $state = New-BRAVOPlanTestState 'Installed' '5.2.6'
        $plan = Get-BRAVOPlanTestPlan -Action 'Update' -State $state
        $fresh = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = $plan; RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapter; Now = $fixedNow.AddMinutes(5) }
        Test-BRAVOCondition -Condition ($fresh.IsCurrent -eq $true -and $fresh.Expired -eq $false -and $fresh.FingerprintMatches -eq $true -and @($fresh.Problems).Count -eq 0) `
            -Name 'UpdatePlan/CurrentPlanIsCurrent' -Failure ('проблеми: ' + (@($fresh.Problems) -join '; '))

        $atEdge = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = $plan; RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapter; Now = $fixedNow.AddMinutes(30) }
        Test-BRAVOCondition -Condition ($atEdge.IsCurrent -eq $true) `
            -Name 'UpdatePlan/ExpiryBoundaryInclusive' -Failure 'рівно на expiresUtc план ще чинний'

        $expired = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = $plan; RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapter; Now = $fixedNow.AddMinutes(31) }
        Test-BRAVOCondition -Condition ($expired.IsCurrent -eq $false -and $expired.Expired -eq $true -and $expired.FingerprintMatches -eq $true -and @($expired.Problems).Count -ge 1) `
            -Name 'UpdatePlan/ExpiredPlanNotCurrent' -Failure 'після TTL план не чинний, fingerprint при цьому збігається'

        # Now з adapter-а
        $adapterNow = @{ GetManagedTasks = $adapter.GetManagedTasks; Now = { [datetime]::SpecifyKind([datetime]'2026-10-29T12:00:00', [DateTimeKind]::Utc) } }
        $viaAdapter = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = $plan; RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapterNow }
        Test-BRAVOCondition -Condition ($viaAdapter.Expired -eq $true) `
            -Name 'UpdatePlan/AdapterNowUsedForExpiry' -Failure 'adapter.Now має використовуватись, коли -Now не передано'

        # Зміна локального конфігу
        $localConfig = Join-Path $runtime 'BRAVO.local.config'
        $originalLocal = [IO.File]::ReadAllText($localConfig)
        [IO.File]::WriteAllText($localConfig, '{"local":2}', (New-Object Text.UTF8Encoding $false))
        $afterLocal = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = $plan; RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapter; Now = $fixedNow }
        Test-BRAVOCondition -Condition ($afterLocal.IsCurrent -eq $false -and $afterLocal.FingerprintMatches -eq $false) `
            -Name 'UpdatePlan/FingerprintChangesOnLocalConfig' -Failure 'зміна BRAVO.local.config має інвалідувати план'
        [IO.File]::WriteAllText($localConfig, $originalLocal, (New-Object Text.UTF8Encoding $false))
        $restored = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = $plan; RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapter; Now = $fixedNow }
        Test-BRAVOCondition -Condition ($restored.IsCurrent -eq $true) `
            -Name 'UpdatePlan/FingerprintStableAfterRestore' -Failure 'відновлений конфіг має давати той самий fingerprint'

        # Видалення локального конфігу ('absent')
        Move-Item -LiteralPath $localConfig -Destination ($localConfig + '.bak')
        $absent = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = $plan; RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapter; Now = $fixedNow }
        Move-Item -LiteralPath ($localConfig + '.bak') -Destination $localConfig
        Test-BRAVOCondition -Condition ($absent.FingerprintMatches -eq $false) `
            -Name 'UpdatePlan/FingerprintChangesWhenLocalConfigAbsent' -Failure 'зникнення local config має змінювати fingerprint'

        # Зміна enabled задачі
        $adapterState.Enabled = $false
        $afterTask = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = $plan; RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapter; Now = $fixedNow }
        $adapterState.Enabled = $true
        Test-BRAVOCondition -Condition ($afterTask.FingerprintMatches -eq $false) `
            -Name 'UpdatePlan/FingerprintChangesOnTaskEnabled' -Failure 'вимкнення задачі має інвалідувати план'

        # Adapter відсутній -> 'Unknown' -> fingerprint інший
        $noAdapter = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = $plan; RuntimeRoot = $runtime; StateRoot = $stateRoot; Now = $fixedNow }
        Test-BRAVOCondition -Condition ($noAdapter.FingerprintMatches -eq $false) `
            -Name 'UpdatePlan/FingerprintUnknownTasksDiffer' -Failure 'невідомий стан задач не може збігатись із відомим'
        $preUnknown = Invoke-BRAVOPlanTestCall -Name 'Get-BRAVODeploymentPreconditions' -Params @{ RuntimeRoot = $runtime; StateRoot = $stateRoot }
        Test-BRAVOCondition -Condition ($preUnknown.managedTasks -eq 'Unknown') `
            -Name 'UpdatePlan/PreconditionsUnknownWithoutAdapter' -Failure 'без adapter managedTasks = Unknown'

        # Падіння adapter-а = Unknown, не виняток
        $throwing = @{ GetManagedTasks = { throw 'збій планувальника' } }
        $preThrow = Invoke-BRAVOPlanTestCall -Name 'Get-BRAVODeploymentPreconditions' -Params @{ RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $throwing }
        Test-BRAVOCondition -Condition ($preThrow.managedTasks -eq 'Unknown') `
            -Name 'UpdatePlan/AdapterFailureIsUnknown' -Failure 'збій adapter-а = Unknown'

        # Зміна artifact sha: інший plan.source.artifactSha256 -> інший fingerprint
        $otherSource = $source.PSObject.Copy(); $otherSource.artifactSha256 = ('C' * 64)
        $otherPlan = Get-BRAVOPlanTestPlan -Action 'Update' -PlanSource $otherSource -State $state
        Test-BRAVOCondition -Condition ($otherPlan.preconditionsFingerprint -ne $plan.preconditionsFingerprint) `
            -Name 'UpdatePlan/FingerprintChangesOnArtifactSha' -Failure 'інший sha артефакта має давати інший fingerprint'
        $tampered = $plan.PSObject.Copy()
        $tampered.source = $otherSource
        $tamperCheck = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = $tampered; RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapter; Now = $fixedNow }
        Test-BRAVOCondition -Condition ($tamperCheck.IsCurrent -eq $false) `
            -Name 'UpdatePlan/TamperedArtifactShaDetected' -Failure 'підміна sha артефакта в плані має виявлятись'

        # Відкритий журнал змінює fingerprint
        $journalDir = Join-Path $stateRoot 'Journal'
        New-Item -ItemType Directory -Path $journalDir -Force | Out-Null
        # Журнали створюються канонічними конструкторами Journal (валідна форма контракту).
        $closedJournal = Invoke-BRAVOPlanTestCall -Name 'New-BRAVOUpdateJournal' -Params @{ StateRoot = $stateRoot; Action = 'Update'; RuntimeRoot = $runtime }
        [void](Invoke-BRAVOPlanTestCall -Name 'Set-BRAVOUpdateJournalState' -Params @{ Journal = $closedJournal; State = 'Committed'; StateRoot = $stateRoot })
        $closedOnly = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = $plan; RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapter; Now = $fixedNow }
        Test-BRAVOCondition -Condition ($closedOnly.IsCurrent -eq $true) `
            -Name 'UpdatePlan/ClosedJournalDoesNotInvalidate' -Failure 'закритий журнал не впливає на fingerprint'
        $openJournal = Invoke-BRAVOPlanTestCall -Name 'New-BRAVOUpdateJournal' -Params @{ StateRoot = $stateRoot; Action = 'Update'; RuntimeRoot = $runtime }
        $openJournalFile = Join-Path $journalDir ($openJournal.operationId + '.json')
        $withOpen = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = $plan; RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapter; Now = $fixedNow }
        Test-BRAVOCondition -Condition ($withOpen.FingerprintMatches -eq $false) `
            -Name 'UpdatePlan/OpenJournalInvalidatesPlan' -Failure 'відкритий журнал має інвалідувати план'
        $preOpen = Invoke-BRAVOPlanTestCall -Name 'Get-BRAVODeploymentPreconditions' -Params @{ RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapter }
        Test-BRAVOCondition -Condition (@($preOpen.openJournalIds) -contains $openJournal.operationId -and @($preOpen.openJournalIds).Count -eq 1) `
            -Name 'UpdatePlan/OpenJournalIdFromCanonicalReader' -Failure 'відкритий журнал має входити в openJournalIds рівно один раз (закритий — ні)'
        Remove-Item -LiteralPath $openJournalFile -Force
        [IO.File]::WriteAllText((Join-Path $journalDir 'bad.json'), '{ пошкоджено', (New-Object Text.UTF8Encoding $false))
        $pre = Invoke-BRAVOPlanTestCall -Name 'Get-BRAVODeploymentPreconditions' -Params @{ RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapter }
        Test-BRAVOCondition -Condition (@($pre.openJournalIds) -contains 'corrupt:bad') `
            -Name 'UpdatePlan/CorruptJournalCountsAsOpen' -Failure 'пошкоджений журнал = відкритий (fail closed)'
        Remove-Item -LiteralPath (Join-Path $journalDir 'bad.json') -Force

        # Інший RuntimeRoot
        $otherRoot = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = $plan; RuntimeRoot = $planTestRoot; StateRoot = $stateRoot; Adapter = $adapter; Now = $fixedNow }
        Test-BRAVOCondition -Condition ($otherRoot.IsCurrent -eq $false) `
            -Name 'UpdatePlan/DifferentRuntimeRootNotCurrent' -Failure 'інший каталог встановлення — план не чинний'

        # Порядок передумов і вміст
        $names = @($pre.PSObject.Properties | ForEach-Object { $_.Name }) -join ','
        Test-BRAVOCondition -Condition ($names -eq 'runtimeManifestSha256,versionJsonSha256,localConfigSha256,configPresent,artifactSha256,manifestSha256,managedTasks,openJournalIds' -and $pre.runtimeManifestSha256 -match '^[0-9A-F]{64}$' -and $pre.configPresent -eq $true -and @($pre.managedTasks) -join ',' -eq 'BRAVO-А=enabled,BRAVO-Б=enabled') `
            -Name 'UpdatePlan/PreconditionsOrderedAndSorted' -Failure ('поля: ' + $names)

        # Fail closed: сміття замість плану
        $garbage = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = ([pscustomobject]@{ x = 1 }); RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapter; Now = $fixedNow }
        Test-BRAVOCondition -Condition ($garbage.IsCurrent -eq $false -and @($garbage.Problems).Count -ge 1) `
            -Name 'UpdatePlan/MalformedPlanFailsClosed' -Failure 'план без обов''язкових полів не може бути чинним'
        $badDate = $plan.PSObject.Copy(); $badDate.expiresUtc = 'не дата'
        $badDateCheck = Invoke-BRAVOPlanTestCall -Name 'Test-BRAVODeploymentPlanCurrent' -Params @{ Plan = $badDate; RuntimeRoot = $runtime; StateRoot = $stateRoot; Adapter = $adapter; Now = $fixedNow }
        Test-BRAVOCondition -Condition ($badDateCheck.IsCurrent -eq $false) `
            -Name 'UpdatePlan/BadExpiryFailsClosed' -Failure 'нерозбірливий expiresUtc — план не чинний'
    }

    # --- Текстове подання ---
    & {
        $blockPreflight = [pscustomobject]@{ findings = @([pscustomobject]@{ id = 'P.1'; severity = 'Blocker'; title = 'Є активний процес'; meaning = ''; action = 'Дочекайтеся завершення'; details = ''; exitCodeHint = $null }); canProceed = $false }
        $plan = Get-BRAVOPlanTestPlan -Action 'Update' -State (New-BRAVOPlanTestState 'Installed' '5.2.6') -Preflight $blockPreflight
        $lines = @(Invoke-BRAVOPlanTestCall -Name 'Format-BRAVODeploymentPlanText' -Params @{ Plan = $plan })
        $text = $lines -join "`n"
        Test-BRAVOCondition -Condition ($lines.Count -gt 10 -and (@($lines | Where-Object { $_ -isnot [string] }).Count -eq 0)) `
            -Name 'UpdatePlan/FormatReturnsStrings' -Failure 'форматувальник має повертати string[]'
        Test-BRAVOCondition -Condition ($text -match 'Оновлення' -and $text -match '5\.2\.6 -> 5\.3\.0' -and $text -match 'ActivateOnSuccessOnly' -and $text -match 'побайтово' -and $text -match 'Є активний процес') `
            -Name 'UpdatePlan/FormatContainsKeyFacts' -Failure 'у тексті мають бути дія, версії, політика, конфіг і blocker'
        $blockerSymbol = [string][char]0x00D7
        Test-BRAVOCondition -Condition ($text.Contains($blockerSymbol + ' Є активний процес')) `
            -Name 'UpdatePlan/FormatBlockerSymbolWithText' -Failure 'blocker позначається символом разом із текстом'
        $installPlan = Get-BRAVOPlanTestPlan -Action 'Install' -RuntimePath (Join-Path $planTestRoot 'install-text') -State (New-BRAVOPlanTestState 'NotInstalled' $null)
        $installLines = @(Invoke-BRAVOPlanTestCall -Name 'Format-BRAVODeploymentPlanText' -Params @{ Plan = $installPlan })
        Test-BRAVOCondition -Condition (($installLines -join "`n") -match 'не встановлено -> 5\.3\.0') `
            -Name 'UpdatePlan/FormatInstallNoCurrentVersion' -Failure 'Install: поточна версія «не встановлено»'
    }

    # --- Шляхи з пробілами та кирилицею: усе вище вже працює у такому корені ---
    & {
        Test-BRAVOCondition -Condition ($runtime -match ' ' -and $runtime -match '[А-Яа-я]') `
            -Name 'UpdatePlan/FixtureRootHasSpacesAndCyrillic' -Failure 'fixture-шляхи мають містити пробіли й кирилицю'
    }

    # --- Статика: частина не пише в консоль і не має заборонених конструкцій ---
    & {
        $planSourceText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.Plan.ps1'))
        Test-BRAVOCondition -Condition ($planSourceText -notmatch '(?m)^\s*Write-Host|\bexit\b\s*\d|\$global:|Invoke-Expression|::new\(') `
            -Name 'UpdatePlan/PartHasNoConsoleExitGlobalOrNew' -Failure 'Plan.ps1: без Write-Host, exit, $global:, Invoke-Expression, ::new()'
    }
} finally {
    if ($planTestRoot.StartsWith($planTestPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $planTestRoot)) {
        Remove-Item -LiteralPath $planTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
