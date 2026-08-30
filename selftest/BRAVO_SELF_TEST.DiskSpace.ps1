# Домен-фрагмент self-test: BRAVO.DiskSpace — спільний operation-aware
# класифікатор перевірки вільного місця/доступу до storage
# (fix/5.2.3-operation-aware-disk-space, BRAVO_5_2_2_DISK_SPACE_TASK_FINAL.md
# §63-66 test S1-S20). Тестує ЛИШЕ сам класифікатор (модуль
# BRAVO.DiskSpace) в ізоляції — без інтеграції в Archive/Maintenance,
# яка перевіряється окремими фрагментами (A1-A25/M1-M11/R1-R2).
#
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition, $script:failures.

Import-Module -Name (Join-Path $root "modules\BRAVO.DiskSpace\BRAVO.DiskSpace.psd1") -Force -ErrorAction Stop

function New-DiskSpaceTestDrive {
    param([string]$Drive, [double]$AvailableGB, [double]$TotalGB = 200, [bool]$IsReady = $true, [string]$DriveType = 'Fixed')
    [pscustomobject]@{
        Drive = $Drive
        IsReady = $IsReady
        AvailableFreeSpace = [int64]($AvailableGB * 1GB)
        TotalSize = [int64]($TotalGB * 1GB)
        DriveType = $DriveType
    }
}

# ============================================================
# S1 — identity/normalization для вже підтримуваних 5.2.1 storage-типів
# ============================================================
$s1a = Resolve-BRAVODiskSpaceStorageIdentity -DisplayPath 'C:\BRAVO\Logs' -Drives @(New-DiskSpaceTestDrive -Drive 'C:' -AvailableGB 50)
$s1b = Resolve-BRAVODiskSpaceStorageIdentity -DisplayPath 'c:\bravo\logs' -Drives @(New-DiskSpaceTestDrive -Drive 'C:' -AvailableGB 50)
Test-BRAVOCondition `
    -Condition (-not $s1a.Failed -and -not $s1b.Failed -and $s1a.CapacityKey -eq 'C:' -and $s1a.CapacityKey -eq $s1b.CapacityKey) `
    -Name 'DiskSpace/S1-LocalVolumeIdentityNormalization' `
    -Failure "C:\..., c:\... мають резолвитись у той самий CapacityKey (отримано '$($s1a.CapacityKey)' vs '$($s1b.CapacityKey)')"

# ============================================================
# S2 — exit-code composition (табличний рівень, наскрізна перевірка — A23/M-еквівалент)
# ============================================================
Import-Module -Name (Join-Path $root "modules\BRAVO.ExitCodes\BRAVO.ExitCodes.psd1") -Force -ErrorAction Stop
Test-BRAVOCondition `
    -Condition ((Resolve-BRAVOExitCode) -eq 0) `
    -Name 'DiskSpace/S2-ExitCodeCleanIsZero' `
    -Failure 'без прапорців Resolve-BRAVOExitCode має повертати 0'
Test-BRAVOCondition `
    -Condition ((Resolve-BRAVOExitCode -HasWarnings) -eq 10) `
    -Name 'DiskSpace/S2-ExitCodeWarningsOnlyIsTen' `
    -Failure 'warning-only сценарій має повертати 10 (SuccessWithWarnings)'
Test-BRAVOCondition `
    -Condition ((Resolve-BRAVOExitCode -LocalArchiveFailed -HasWarnings) -eq 40) `
    -Name 'DiskSpace/S2-LaterRealFailureOverridesWarnings' `
    -Failure 'реальна відмова (40) має мати пріоритет над попереднім warning (10)'

# ============================================================
# S4 — інваріант §3.4 + Reason precedence при кількох одночасних умовах
# ============================================================
$s4Drives = @(New-DiskSpaceTestDrive -Drive 'D:' -AvailableGB 50)
$s4Spec = [pscustomobject]@{
    DisplayPath = 'D:\ARCHIV\MODEL'
    RequiresAccess = $false
    RequiresFreeSpace = $true
    RequirementGranularity = 'Entity'
    RequiredGB = 5
}
$s4Outcome = Test-BRAVODiskSpaceEntity -EntitySpec $s4Spec -Drives $s4Drives -ExcludedDrives @()
Test-BRAVOCondition `
    -Condition ([bool]$s4Outcome.Result.RequiresAccess -eq $true -and $s4Outcome.Result.Flags -contains 'InvalidRoleClassification') `
    -Name 'DiskSpace/S4-RequiresFreeSpaceForcesRequiresAccess' `
    -Failure "§3.4: RequiresFreeSpace=true + RequiresAccess=false має примусово встановити RequiresAccess=true і додати Flags += InvalidRoleClassification"

# ============================================================
# S5 — ExcludedDrives не скасовує операційну необхідність
# ============================================================
$s5Result = Invoke-BRAVODiskSpaceClassifier `
    -EntitySpecs @([pscustomobject]@{ DisplayPath = 'D:\ARCHIV\MODEL'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity'; RequiredGB = 30 }) `
    -MinimumFreeSpaceGB 20 -ExcludedDrives @('D:') -RequirementPolicy 'ArchiveNotPeakSafe' `
    -Drives @(New-DiskSpaceTestDrive -Drive 'D:' -AvailableGB 5)
Test-BRAVOCondition `
    -Condition ([bool]$s5Result.Results[0].Blocks -and $s5Result.Results[0].Reason -eq 'EstimatedRequirementNotMet' -and $s5Result.Results[0].Flags -contains 'ExclusionIgnoredForRequiredVolume') `
    -Name 'DiskSpace/S5-ExcludedDrivesCannotBypassRequiredVolume' `
    -Failure "excluded + operationally required + insufficient має BLOCK з реальним Reason і Flags += ExclusionIgnoredForRequiredVolume"

# ============================================================
# S6 — bootstrap: шлях призначення ще не створений
# ============================================================
$s6NonExistentChild = Join-Path $root ('ARCHIV_BOOTSTRAP_' + [Guid]::NewGuid().ToString('N') + '\MODEL')
$s6Identity = Resolve-BRAVODiskSpaceStorageIdentity -DisplayPath $s6NonExistentChild -Drives @(New-DiskSpaceTestDrive -Drive ([IO.Path]::GetPathRoot($root).TrimEnd('\')) -AvailableGB 50)
Test-BRAVOCondition `
    -Condition (-not $s6Identity.Failed) `
    -Name 'DiskSpace/S6-BootstrapDestinationResolvesToAncestor' `
    -Failure "неіснуючий підкаталог має резолвитись до найближчого існуючого предка (корінь $root існує)"
$s6MissingRoot = Resolve-BRAVODiskSpaceStorageIdentity -DisplayPath 'Z:\NoSuchRoot\Sub' -Drives @()
Test-BRAVOCondition `
    -Condition ($s6MissingRoot.Failed) `
    -Name 'DiskSpace/S6-MissingRootFails' `
    -Failure "якщо не існує навіть корінь шляху (і диск не injected) — резолюція має провалитись"

# ============================================================
# S7 — required vs health-only resolution failure
# ============================================================
$s7Required = Test-BRAVODiskSpaceEntity `
    -EntitySpec ([pscustomobject]@{ DisplayPath = 'Z:\NoSuchRoot\Sub'; RequiresAccess = $true; RequiresFreeSpace = $false }) `
    -Drives @() -ExcludedDrives @()
Test-BRAVOCondition `
    -Condition ([bool]$s7Required.Result.Blocks -and $s7Required.Result.Reason -eq 'VolumeResolutionFailed') `
    -Name 'DiskSpace/S7-RequiredResolutionFailureBlocks' `
    -Failure "required storage з нерезольвованою identity має BLOCK VolumeResolutionFailed"
$s7HealthOnly = Test-BRAVODiskSpaceEntity `
    -EntitySpec ([pscustomobject]@{ DisplayPath = 'Z:\NoSuchRoot\Sub'; RequiresAccess = $false; RequiresFreeSpace = $false }) `
    -Drives @() -ExcludedDrives @()
Test-BRAVOCondition `
    -Condition (-not [bool]$s7HealthOnly.Result.Blocks -and $s7HealthOnly.Result.Flags -contains 'VolumeResolutionFallback') `
    -Name 'DiskSpace/S7-HealthOnlyResolutionFailureWarns' `
    -Failure "health-only storage з нерезольвованою identity має Warning + Flags += VolumeResolutionFallback, не BLOCK"

# ============================================================
# S8 — required access unknown
# ============================================================
$s8 = Test-BRAVODiskSpaceEntity `
    -EntitySpec ([pscustomobject]@{ DisplayPath = 'sftp://host/path'; StorageKind = 'SFTP'; CapacityKey = 'sftp://host'; RequiresAccess = $true; RequiresFreeSpace = $false; AccessStatusOverride = 'Unknown' }) `
    -ExcludedDrives @()
Test-BRAVOCondition `
    -Condition ([bool]$s8.Result.Blocks -and $s8.Result.Reason -eq 'AccessUndetermined') `
    -Name 'DiskSpace/S8-RequiredAccessUnknownBlocks' `
    -Failure "RequiresAccess=true + AccessStatus=Unknown має BLOCK AccessUndetermined"

# ============================================================
# S9 — required local capacity unknown
# ============================================================
# Диск injected із IsReady=true/DriveType (identity/access резолвляться
# успішно), але БЕЗ AvailableFreeSpace — імітує ситуацію, де сам том
# доступний, а запит вільного місця провалюється (capacity-specific
# unknown, відмінне від access/identity failure).
$s9Drive = [pscustomobject]@{ Drive = 'D:'; IsReady = $true; DriveType = 'Fixed' }
$s9 = Invoke-BRAVODiskSpaceClassifier `
    -EntitySpecs @([pscustomobject]@{ DisplayPath = 'D:\ARCHIV\MODEL'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity'; RequiredGB = 5 }) `
    -MinimumFreeSpaceGB 20 -RequirementPolicy 'ArchiveNotPeakSafe' -Drives @($s9Drive)
Test-BRAVOCondition `
    -Condition ([bool]$s9.Results[0].Blocks -and $s9.Results[0].Reason -eq 'CapacityUndetermined') `
    -Name 'DiskSpace/S9-RequiredLocalCapacityUnknownBlocks' `
    -Failure "LocalVolume + RequiresFreeSpace=true + доступний том, але capacity API недоступний, має BLOCK CapacityUndetermined (отримано Blocks=$([bool]$s9.Results[0].Blocks) Reason=$($s9.Results[0].Reason))"

# ============================================================
# S10 — UNC accessible, capacity unknown → Warning, не VolumeResolutionFailed
# ============================================================
$s10Spec = [pscustomobject]@{
    DisplayPath = '\\server\share\ARCHIV'
    StorageKind = 'UNC'
    RequiresAccess = $true
    RequiresFreeSpace = $true
    RequirementGranularity = 'Entity'
    RequiredGB = 5
    AccessStatusOverride = 'Available'
}
$s10 = Invoke-BRAVODiskSpaceClassifier -EntitySpecs @($s10Spec) -MinimumFreeSpaceGB 20 -RequirementPolicy 'ArchiveNotPeakSafe'
Test-BRAVOCondition `
    -Condition (-not [bool]$s10.Results[0].Blocks -and $s10.Results[0].Reason -eq 'CapacityUnknownRemote' -and $s10.Results[0].Status -eq 'Warning') `
    -Name 'DiskSpace/S10-UNCAccessibleUnknownCapacityWarns' `
    -Failure "UNC accessible + capacity unknown має бути non-blocking Warning CapacityUnknownRemote, не VolumeResolutionFailed"

# ============================================================
# S11 — invalid role classification (access)
# ============================================================
$s11 = Test-BRAVODiskSpaceEntity `
    -EntitySpec ([pscustomobject]@{ DisplayPath = 'sftp://host/path'; StorageKind = 'SFTP'; CapacityKey = 'sftp://host'; RequiresAccess = $true; RequiresFreeSpace = $false; AccessStatusOverride = 'NotApplicable' }) `
    -ExcludedDrives @()
Test-BRAVOCondition `
    -Condition ([bool]$s11.Result.Blocks -and $s11.Result.Reason -eq 'AccessUndetermined' -and $s11.Result.Flags -contains 'InvalidRoleClassification') `
    -Name 'DiskSpace/S11-RequiredAccessNotApplicableBlocks' `
    -Failure "RequiresAccess=true + AccessStatus=NotApplicable є invalid classification: BLOCK AccessUndetermined + Flags += InvalidRoleClassification"

# ============================================================
# S12 — invalid capacity classification
# ============================================================
$s12 = Test-BRAVODiskSpaceEntity `
    -EntitySpec ([pscustomobject]@{ DisplayPath = 'D:\ARCHIV\MODEL'; RequiresAccess = $true; RequiresFreeSpace = $true; CapacityStateOverride = 'NotApplicable' }) `
    -Drives @(New-DiskSpaceTestDrive -Drive 'D:' -AvailableGB 50) -ExcludedDrives @()
Test-BRAVOCondition `
    -Condition ([bool]$s12.Result.Blocks -and $s12.Result.Reason -eq 'CapacityUndetermined' -and $s12.Result.Flags -contains 'InvalidRoleClassification') `
    -Name 'DiskSpace/S12-RequiredFreeSpaceCapacityNotApplicableBlocks' `
    -Failure "RequiresFreeSpace=true + CapacityState=NotApplicable є invalid classification: BLOCK CapacityUndetermined + Flags += InvalidRoleClassification"

# ============================================================
# S13 — дві UNC-цілі на одному share: спільна CapacityKey, сумарна вимога
# ============================================================
$s13Specs = @(
    [pscustomobject]@{ DisplayPath = '\\server\share\MODEL'; StorageKind = 'UNC'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity'; RequiredGB = 15; AccessStatusOverride = 'Available'; CapacityStateOverride = 'Known'; AvailableGBOverride = 20 },
    [pscustomobject]@{ DisplayPath = '\\server\share\BLOG'; StorageKind = 'UNC'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity'; RequiredGB = 15; AccessStatusOverride = 'Available'; CapacityStateOverride = 'Known'; AvailableGBOverride = 20 }
)
$s13 = Invoke-BRAVODiskSpaceClassifier -EntitySpecs $s13Specs -MinimumFreeSpaceGB 10 -RequirementPolicy 'ArchiveNotPeakSafe'
Test-BRAVOCondition `
    -Condition (
        $s13.Results.Count -eq 2 -and
        ($s13.Results | ForEach-Object { $_.CapacityKey }) -contains '\\server\share' -and
        [bool]$s13.Results[0].Blocks -and [bool]$s13.Results[1].Blocks -and
        $s13.Results[0].Reason -eq 'EstimatedRequirementNotMet' -and $s13.Results[0].AggregatedRequiredGB -eq 30
    ) `
    -Name 'DiskSpace/S13-SameShareRequirementsAggregate' `
    -Failure "два DisplayPath на одному share мають ділити один CapacityKey і сумарну вимогу (15+15=30 > 20 => BLOCK для обох)"

# ============================================================
# S13b — §51.1: спільний blocking condition одного CapacityKey
# повідомляється ОДИН раз у .Problems, з переліком обох DisplayPath, а
# не як два окремі дубльовані повідомлення.
# ============================================================
Test-BRAVOCondition `
    -Condition (
        @($s13.Problems).Count -eq 1 -and
        $s13.Problems[0] -match [regex]::Escape('\\server\share\MODEL') -and
        $s13.Problems[0] -match [regex]::Escape('\\server\share\BLOG') -and
        $s13.Problems[0] -match 'EstimatedRequirementNotMet'
    ) `
    -Name 'DiskSpace/S13b-SharedBlockingConditionReportedOncePerCapacityKey' `
    -Failure "спільний BLOCK одного CapacityKey має бути ОДНИМ записом у Problems з обома шляхами, не двома дубльованими повідомленнями; отримано $(@($s13.Problems).Count) запис(ів): $($s13.Problems -join ' | ')"

# ============================================================
# S14 — дві UNC-цілі на різних share: незалежна оцінка
# ============================================================
$s14Specs = @(
    [pscustomobject]@{ DisplayPath = '\\server\share1\MODEL'; StorageKind = 'UNC'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity'; RequiredGB = 15; AccessStatusOverride = 'Available'; CapacityStateOverride = 'Known'; AvailableGBOverride = 5 },
    [pscustomobject]@{ DisplayPath = '\\server\share2\BLOG'; StorageKind = 'UNC'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity'; RequiredGB = 15; AccessStatusOverride = 'Available'; CapacityStateOverride = 'Known'; AvailableGBOverride = 50 }
)
$s14 = Invoke-BRAVODiskSpaceClassifier -EntitySpecs $s14Specs -MinimumFreeSpaceGB 10 -RequirementPolicy 'ArchiveNotPeakSafe'
$s14Share1 = $s14.Results | Where-Object { $_.CapacityKey -eq '\\server\share1' }
$s14Share2 = $s14.Results | Where-Object { $_.CapacityKey -eq '\\server\share2' }
Test-BRAVOCondition `
    -Condition ([bool]$s14Share1.Blocks -and -not [bool]$s14Share2.Blocks) `
    -Name 'DiskSpace/S14-DifferentSharesEvaluatedIndependently' `
    -Failure "різні CapacityKey не повинні компенсувати один одного (share1 insufficient має BLOCK незалежно від share2 sufficient)"

# ============================================================
# S15 — mixed known/unknown requirement на одному CapacityKey (A-D)
# ============================================================
function Test-S15Case {
    # $ExpectedReason навмисно без типу [string]: незв'язаний/явний $null
    # параметр має лишатись реальним $null (як Reason у ALLOW-результаті),
    # а не конвертуватись у "" типовим конвертером [string].
    param([double]$AvailableGB, $ExpectedReason, [bool]$ExpectedBlocks, [string]$Name)
    $specs = @(
        [pscustomobject]@{ DisplayPath = 'D:\ARCHIV\MODEL'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity'; RequiredGB = 10 },
        [pscustomobject]@{ DisplayPath = 'D:\ARCHIV\BLOG'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity' }  # RequiredGB unknown
    )
    $r = Invoke-BRAVODiskSpaceClassifier -EntitySpecs $specs -MinimumFreeSpaceGB 20 -RequirementPolicy 'ArchiveNotPeakSafe' -Drives @(New-DiskSpaceTestDrive -Drive 'D:' -AvailableGB $AvailableGB)
    Test-BRAVOCondition `
        -Condition ([bool]$r.Results[0].Blocks -eq $ExpectedBlocks -and $r.Results[0].Reason -eq $ExpectedReason -and $r.Results[0].GroupRequirementState -eq 'Unknown') `
        -Name "DiskSpace/$Name" `
        -Failure "Available=${AvailableGB}: очікувалось Blocks=$ExpectedBlocks Reason=$ExpectedReason, отримано Blocks=$([bool]$r.Results[0].Blocks) Reason=$($r.Results[0].Reason)"
}
Test-S15Case -AvailableGB 15 -ExpectedReason 'BelowFallbackFloorNoEstimate' -ExpectedBlocks $true -Name 'S15A-RawAvailableBelowFloor'
Test-S15Case -AvailableGB 25 -ExpectedReason 'BelowFallbackFloorNoEstimate' -ExpectedBlocks $true -Name 'S15B-ResidualBelowFloorEvenIfRawAboveFloor'
# -ExpectedReason навмисно НЕ передається (лишається $null за замовчуванням):
# явний аргумент $null для параметра типу [string] PowerShell конвертує в
# "" навіть з [AllowNull()], тоді як реальний ALLOW-результат несе Reason=$null.
Test-S15Case -AvailableGB 30 -ExpectedBlocks $false -Name 'S15C-ResidualFloorSatisfiedAllows'
$s15dSpecs = @(
    [pscustomobject]@{ DisplayPath = 'D:\ARCHIV\MODEL'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity'; RequiredGB = 35 },
    [pscustomobject]@{ DisplayPath = 'D:\ARCHIV\BLOG'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity' }
)
$s15d = Invoke-BRAVODiskSpaceClassifier -EntitySpecs $s15dSpecs -MinimumFreeSpaceGB 20 -RequirementPolicy 'ArchiveNotPeakSafe' -Drives @(New-DiskSpaceTestDrive -Drive 'D:' -AvailableGB 30)
Test-BRAVOCondition `
    -Condition ([bool]$s15d.Results[0].Blocks -and $s15d.Results[0].Reason -eq 'EstimatedRequirementNotMet' -and $s15d.Results[0].KnownRequiredLowerBoundGB -eq 35) `
    -Name 'DiskSpace/S15D-KnownLowerBoundAloneExceedsAvailable' `
    -Failure "KnownRequiredLowerBoundGB (35) > AvailableGB (30) має BLOCK EstimatedRequirementNotMet навіть з unknown remainder"

# ============================================================
# S16 — CapacityGroup granularity: не подвоювати агрегацію
# ============================================================
$s16Specs = @(
    [pscustomobject]@{ DisplayPath = 'E:\ARCHIV\MODEL'; Components = @('MODEL'); RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'CapacityGroup'; CapacityGroupRequiredGB = 23 },
    [pscustomobject]@{ DisplayPath = 'E:\ARCHIV\BLOG'; Components = @('BLOG'); RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'CapacityGroup'; CapacityGroupRequiredGB = 23 },
    [pscustomobject]@{ DisplayPath = 'E:\ARCHIV\BRAVOEXCH'; Components = @('BRAVOEXCH'); RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'CapacityGroup'; CapacityGroupRequiredGB = 23 }
)
$s16 = Invoke-BRAVODiskSpaceClassifier -EntitySpecs $s16Specs -MinimumFreeSpaceGB 20 -RequirementPolicy 'ArchiveNotPeakSafe' -Drives @(New-DiskSpaceTestDrive -Drive 'E:' -AvailableGB 30)
Test-BRAVOCondition `
    -Condition (-not [bool]$s16.Results[0].Blocks -and $s16.Results[0].AggregatedRequiredGB -eq 23) `
    -Name 'DiskSpace/S16-CapacityGroupNotDoubleAggregated' `
    -Failure "CapacityGroup-провайдерне значення (23) має використовуватись ОДИН раз, не 23*3=69; отримано AggregatedRequiredGB=$($s16.Results[0].AggregatedRequiredGB)"
$s16bSpecs = @(
    [pscustomobject]@{ DisplayPath = 'E:\ARCHIV\MODEL'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'CapacityGroup' },
    [pscustomobject]@{ DisplayPath = 'E:\ARCHIV\BLOG'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity'; RequiredGB = 5 }
)
$s16b = Invoke-BRAVODiskSpaceClassifier -EntitySpecs $s16bSpecs -MinimumFreeSpaceGB 20 -RequirementPolicy 'ArchiveNotPeakSafe' -Drives @(New-DiskSpaceTestDrive -Drive 'E:' -AvailableGB 30)
Test-BRAVOCondition `
    -Condition ($s16b.Results[0].RequirementGranularity -eq 'Unknown' -and $s16b.Results[0].GroupRequirementState -eq 'Unknown') `
    -Name 'DiskSpace/S16-AmbiguousGranularityFallsBackToUnknown' `
    -Failure "неоднозначна/змішана granularity в одній CapacityKey-групі має звестись до Unknown, без евристичної нормалізації"

# ============================================================
# S17 — монотонність Blocks
# ============================================================
$s17Specs = @(
    [pscustomobject]@{ DisplayPath = 'Z:\NoSuchRoot\Sub'; RequiresAccess = $true; RequiresFreeSpace = $false },
    [pscustomobject]@{ DisplayPath = 'D:\ARCHIV\MODEL'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity'; RequiredGB = 5 }
)
$s17 = Invoke-BRAVODiskSpaceClassifier -EntitySpecs $s17Specs -MinimumFreeSpaceGB 20 -RequirementPolicy 'ArchiveNotPeakSafe' -Drives @(New-DiskSpaceTestDrive -Drive 'D:' -AvailableGB 50)
$s17Terminal = $s17.Results | Where-Object { $_.DisplayPath -eq 'Z:\NoSuchRoot\Sub' }
Test-BRAVOCondition `
    -Condition ([bool]$s17Terminal.Blocks -and [bool]$s17.Blocks -and -not $s17.Success) `
    -Name 'DiskSpace/S17-MonotonicBlocksNotClearedByOtherGroupAllow' `
    -Failure "термінальний BLOCK однієї entity не повинен скасовуватись ALLOW іншої CapacityKey-групи; overall Blocks/Success мають відображати BLOCK"

# ============================================================
# S18 — конфлікт спостережень capacity для одного CapacityKey
# ============================================================
$s18Specs = @(
    [pscustomobject]@{ DisplayPath = '\\server\share\MODEL'; StorageKind = 'UNC'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity'; RequiredGB = 5; AccessStatusOverride = 'Available'; CapacityStateOverride = 'Known'; AvailableGBOverride = 30 },
    [pscustomobject]@{ DisplayPath = '\\server\share\BLOG'; StorageKind = 'UNC'; RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity'; RequiredGB = 5; AccessStatusOverride = 'Available' }  # CapacityState не задано => Unknown
)
$s18 = Invoke-BRAVODiskSpaceClassifier -EntitySpecs $s18Specs -MinimumFreeSpaceGB 10 -RequirementPolicy 'ArchiveNotPeakSafe'
$s18AnyBlocked = @($s18.Results | Where-Object { [bool]$_.Blocks })
Test-BRAVOCondition `
    -Condition (
        $s18.Results.Count -eq 2 -and
        $s18AnyBlocked.Count -eq 0 -and
        (@($s18.Results | ForEach-Object { $_.Flags }) -contains 'CapacityObservationConflict') -and
        (@($s18.Results | ForEach-Object { $_.Reason }) -contains 'CapacityUnknownRemote')
    ) `
    -Name 'DiskSpace/S18-ConflictingRemoteObservationsWarnBothEntities' `
    -Failure "конфлікт спостережень на одному CapacityKey (remote) має дати CapacityUnknownRemote Warning для ОБОХ entities, не виключати жодну (заблоковано: $($s18AnyBlocked.Count))"

# ============================================================
# S19 — required read-only source: resolution failure блокує навіть за RequiresFreeSpace=false
# ============================================================
$s19 = Test-BRAVODiskSpaceEntity `
    -EntitySpec ([pscustomobject]@{ DisplayPath = 'Z:\NoSuchModelSource'; RequiresAccess = $true; RequiresFreeSpace = $false }) `
    -Drives @() -ExcludedDrives @()
Test-BRAVOCondition `
    -Condition ([bool]$s19.Result.Blocks -and $s19.Result.Reason -eq 'VolumeResolutionFailed') `
    -Name 'DiskSpace/S19-RequiredReadOnlySourceResolutionFailureBlocks' `
    -Failure "required read-only source (RequiresFreeSpace=false) з identity-resolution failure має все одно BLOCK VolumeResolutionFailed, не health-only Warning"

# ============================================================
# S20 — remote unknown capacity зупиняє арифметику повністю
# ============================================================
$s20Spec = [pscustomobject]@{
    DisplayPath = 'sftp://host/BAZA'
    StorageKind = 'SFTP'
    CapacityKey = 'sftp://host'
    RequiresAccess = $true
    RequiresFreeSpace = $true
    RequirementGranularity = 'Entity'
    RequiredGB = 5
    AccessStatusOverride = 'Available'
}
$s20 = Invoke-BRAVODiskSpaceClassifier -EntitySpecs @($s20Spec) -MinimumFreeSpaceGB 20 -RequirementPolicy 'ArchiveNotPeakSafe'
Test-BRAVOCondition `
    -Condition (
        -not [bool]$s20.Results[0].Blocks -and $s20.Results[0].Reason -eq 'CapacityUnknownRemote' -and
        $null -eq $s20.Results[0].ProjectedFreeGB -and $null -eq $s20.Results[0].AggregatedRequiredGB
    ) `
    -Name 'DiskSpace/S20-RemoteUnknownCapacityStopsArithmetic' `
    -Failure "remote CapacityState=Unknown має зупинити АРИФМЕТИКУ повністю (жодного ProjectedFreeGB/AggregatedRequiredGB порівняння з `$null)"

# ============================================================
# S3 — notification wording: non-blocking Warning ніколи не формує текст
# "операцію не розпочато"/CRITICAL (§51/§84.10). Warnings будуються лише
# з DisplayPath+Reason — структурно не можуть містити таких фраз, але
# перевіряємо явно як regression-guard на майбутні зміни формату.
# ============================================================
$s3Result = Invoke-BRAVODiskSpaceClassifier `
    -EntitySpecs @([pscustomobject]@{ DisplayPath = 'C:\BRAVO\Logs'; Roles = @('HealthOnly'); RequiresAccess = $false; RequiresFreeSpace = $false; MinimumFreeSpaceGB = 20 }) `
    -MinimumFreeSpaceGB 20 -RequirementPolicy 'ArchiveNotPeakSafe' -Drives @(New-DiskSpaceTestDrive -Drive 'C:' -AvailableGB 5)
$s3ForbiddenPhrases = @('не розпочат', 'CRITICAL', 'критичн', 'повторити запуск')
$s3ContainsForbidden = $false
foreach ($warningText in @($s3Result.Warnings)) {
    foreach ($phrase in $s3ForbiddenPhrases) {
        if ($warningText -match [regex]::Escape($phrase)) { $s3ContainsForbidden = $true }
    }
}
Test-BRAVOCondition `
    -Condition (@($s3Result.Warnings).Count -eq 1 -and -not $s3ContainsForbidden -and -not $s3Result.Blocks) `
    -Name 'DiskSpace/S3-NonBlockingWarningNeverClaimsNotStarted' `
    -Failure "non-blocking Warning не повинен містити фрази на кшталт 'не розпочато'/CRITICAL/'повторити запуск' — операція фактично продовжується"

# ============================================================
# §62 — DiskSpacePolicyMode НЕ вводиться (жодного config-перемикача
# Strict/OperationAware; OperationAware — єдина, canonical поведінка).
# ============================================================
$diskSpaceModuleText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.DiskSpace\BRAVO.DiskSpace.psm1"),
    [Text.Encoding]::UTF8
)
$archiveRuntimeTextForPolicyCheck = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"),
    [Text.Encoding]::UTF8
)
$maintenanceRuntimeTextForPolicyCheck = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
    [Text.Encoding]::UTF8
)
$bravoConfigTextForPolicyCheck = [IO.File]::ReadAllText((Join-Path $root "BRAVO.config"), [Text.Encoding]::UTF8)
Test-BRAVOCondition `
    -Condition (
        -not $diskSpaceModuleText.Contains('DiskSpacePolicyMode') -and
        -not $archiveRuntimeTextForPolicyCheck.Contains('DiskSpacePolicyMode') -and
        -not $maintenanceRuntimeTextForPolicyCheck.Contains('DiskSpacePolicyMode') -and
        -not $bravoConfigTextForPolicyCheck.Contains('DiskSpacePolicyMode')
    ) `
    -Name 'DiskSpace/S62-NoDiskSpacePolicyModeIntroduced' `
    -Failure "§62: DiskSpacePolicyMode (Strict/OperationAware перемикач) не повинен вводитись у 5.2.3 — OperationAware стає єдиною canonical поведінкою"
