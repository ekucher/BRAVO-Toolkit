# Домен-фрагмент self-test: BRAVO_ARCHIV disk-space integration
# (fix/5.2.3-operation-aware-disk-space, BRAVO_5_2_2_DISK_SPACE_TASK_FINAL.md
# §63 test A1-A25). Тестує РЕАЛЬНИЙ виклик-сайт Archive —
# Resolve-BRAVOArchiveSpaceDecision, витягнуту з BRAVO.Archive.Runtime.ps1
# через New-BRAVOSelfTestRuntimeModule, — на відміну від
# BRAVO_SELF_TEST.DiskSpace.ps1 (S1-S20), який тестує сам shared classifier
# в ізоляції.
#
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, $archiveScriptText, Test-BRAVOCondition,
# New-BRAVOSelfTestRuntimeModule, $script:failures.
#
# Свідомо відсутні тут ID з §63 (перевірено 2026-08-31, не оверсайт):
#   A3  — below-floor relaxation при достатній оцінці. Сценарій прибраний
#         разом із PeakSafeEstimate=false для Archive (§24.1); замінений на
#         A24 (BLOCK BelowFloorEstimateNotPeakSafe) і A25 (той самий вхід під
#         ArchivePeakSafe-політикою, яка в 5.2.3 не використовується
#         production-виклик-сайтом — лише доводить наявність коду).
#   A12 — SyncBAZA-потік. Invoke-ManualBAZASFTPSynchronization НЕ підключений
#         до Invoke-BRAVODiskSpaceClassifier у цьому релізі (CHANGELOG,
#         "Відомі обмеження") — тестувати нема що, поведінка незмінна
#         відносно 5.2.2.
#   A13 — peak-estimator characterization. Результат Phase 0 зафіксований як
#         рішення коду (PeakSafeEstimate=false, коментар на початку
#         BRAVO.DiskSpace.psm1), а не як окремий регресійний тест.
#   A18, A21, A22 — remote/SFTP capacity-unknown і access-unavailable
#         сценарії. StorageKind SFTP проходить ті самі гілки класифікатора,
#         що й UNC/AccessUnavailable — реальне branch-покриття вже дають
#         DiskSpace/S10 (UNC accessible + capacity unknown → Warning
#         CapacityUnknownRemote), DiskSpace/S11 (RequiresAccess=true +
#         override) та Archive/A7, Archive/A20 (RequiresAccess=true +
#         AccessStatus=Unavailable → BLOCK AccessUnavailable — код
#         storage-kind-агностичний, крок 6). SFTP-мітка на дублі цих же
#         гілок не додає покриття, лише назву.

Import-Module -Name (Join-Path $root "modules\BRAVO.DiskSpace\BRAVO.DiskSpace.psd1") -Force -ErrorAction Stop

$archiveSpaceDecisionModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText $archiveScriptText `
    -FunctionNames @('Resolve-BRAVOArchiveSpaceDecision')

function New-ArchiveDiskSpaceDrive {
    param([string]$Drive, [double]$AvailableGB, [double]$TotalGB = 200)
    [pscustomobject]@{ Drive = $Drive; IsReady = $true; AvailableFreeSpace = [int64]($AvailableGB * 1GB); TotalSize = [int64]($TotalGB * 1GB); DriveType = 'Fixed' }
}

function New-ArchiveDiskSpaceEstimate {
    # $ComponentSizes: hashtable Type -> EstimatedGB ($null = без історії/bootstrap)
    param([hashtable]$ComponentSizes)
    $estimates = @()
    foreach ($type in $ComponentSizes.Keys) {
        $gb = $ComponentSizes[$type]
        $estimates += [pscustomobject]@{
            Type = $type
            HasHistory = ($null -ne $gb)
            EstimatedBytes = if ($null -ne $gb) { [int64]($gb * 1GB) } else { $null }
        }
    }
    [pscustomobject]@{ Success = $true; ComponentEstimates = $estimates; VolumeStatus = @(); Problems = @() }
}

function Invoke-ArchiveSpaceDecision {
    param([object[]]$EnabledArchives, [object]$EstimatedResult, [double]$MinimumFreeSpaceGB, [string[]]$ExcludedDrives = @(), [object[]]$Drives)
    & $archiveSpaceDecisionModule {
        param($EnabledArchives, $EstimatedResult, $MinimumFreeSpaceGB, $ExcludedDrives, $Drives)
        Resolve-BRAVOArchiveSpaceDecision -EnabledArchives $EnabledArchives -EstimatedResult $EstimatedResult `
            -MinimumFreeSpaceGB $MinimumFreeSpaceGB -ExcludedDrives $ExcludedDrives -Drives $Drives
    } $EnabledArchives $EstimatedResult $MinimumFreeSpaceGB $ExcludedDrives $Drives
}

# ============================================================
# A1 — production reproduction (§1): C: low, не write-heavy; D/E достатньо
# ============================================================
$a1Drives = @(
    New-ArchiveDiskSpaceDrive -Drive 'C:' -AvailableGB 18.62
    New-ArchiveDiskSpaceDrive -Drive 'D:' -AvailableGB 38.01
    New-ArchiveDiskSpaceDrive -Drive 'E:' -AvailableGB 101.93
)
$a1Archives = @(
    @{ Type = 'MODEL'; Source = 'D:\Source\MODEL'; Destination = 'D:\ARCHIV\MODEL' }
)
$a1Estimate = New-ArchiveDiskSpaceEstimate -ComponentSizes @{ MODEL = 5 }
$a1 = Invoke-ArchiveSpaceDecision -EnabledArchives $a1Archives -EstimatedResult $a1Estimate -MinimumFreeSpaceGB 20 -Drives $a1Drives
Test-BRAVOCondition `
    -Condition ($a1.Success -and -not [bool]($a1.Results | Where-Object { $_.Blocks })) `
    -Name 'Archive/A1-ProductionReproductionCNotBlocking' `
    -Failure "виробничий сценарій (C: 18.62GB не write-heavy, D:/E: достатньо) не повинен блокувати архівацію"

# ============================================================
# A2 — unrelated critically low (C: 1GB), write-required лише на D
# ============================================================
$a2Drives = @(New-ArchiveDiskSpaceDrive -Drive 'C:' -AvailableGB 1; New-ArchiveDiskSpaceDrive -Drive 'D:' -AvailableGB 100)
$a2Archives = @(@{ Type = 'MODEL'; Source = 'D:\Source\MODEL'; Destination = 'D:\ARCHIV\MODEL' })
$a2Estimate = New-ArchiveDiskSpaceEstimate -ComponentSizes @{ MODEL = 5 }
$a2 = Invoke-ArchiveSpaceDecision -EnabledArchives $a2Archives -EstimatedResult $a2Estimate -MinimumFreeSpaceGB 20 -Drives $a2Drives
Test-BRAVOCondition `
    -Condition ($a2.Success) `
    -Name 'Archive/A2-UnrelatedCriticallyLowPasses' `
    -Failure "критично мало на непов'язаному диску (C: 1GB) не повинно блокувати, коли write-required D: достатньо"

# ============================================================
# A4 — destination above floor, estimate insufficient => BLOCK, exit 40
# ============================================================
$a4Drives = @(New-ArchiveDiskSpaceDrive -Drive 'E:' -AvailableGB 30)
$a4Archives = @(@{ Type = 'MODEL'; Source = 'E:\Source\MODEL'; Destination = 'E:\ARCHIV\MODEL' })
$a4Estimate = New-ArchiveDiskSpaceEstimate -ComponentSizes @{ MODEL = 35 }
$a4 = Invoke-ArchiveSpaceDecision -EnabledArchives $a4Archives -EstimatedResult $a4Estimate -MinimumFreeSpaceGB 20 -Drives $a4Drives
Test-BRAVOCondition `
    -Condition (-not $a4.Success -and (@($a4.Results | Where-Object { $_.Blocks })[0]).Reason -eq 'EstimatedRequirementNotMet') `
    -Name 'Archive/A4-DestinationAboveFloorEstimateInsufficientBlocks' `
    -Failure "Available=30 > floor=20, але AggregatedRequiredGB=35 > Available має BLOCK EstimatedRequirementNotMet (веде до exit 40)"

# ============================================================
# A5 — bootstrap destination: немає estimate, below floor => BLOCK
# ============================================================
$a5Drives = @(New-ArchiveDiskSpaceDrive -Drive 'E:' -AvailableGB 15)
$a5Archives = @(@{ Type = 'MODEL'; Source = 'E:\Source\MODEL'; Destination = 'E:\ARCHIV\MODEL' })
$a5Estimate = New-ArchiveDiskSpaceEstimate -ComponentSizes @{ MODEL = $null }
$a5 = Invoke-ArchiveSpaceDecision -EnabledArchives $a5Archives -EstimatedResult $a5Estimate -MinimumFreeSpaceGB 20 -Drives $a5Drives
Test-BRAVOCondition `
    -Condition (-not $a5.Success -and (@($a5.Results | Where-Object { $_.Blocks })[0]).Reason -eq 'BelowFallbackFloorNoEstimate') `
    -Name 'Archive/A5-BootstrapDestinationBelowFloorBlocks' `
    -Failure "bootstrap (немає валідної історії) + below floor має BLOCK BelowFallbackFloorNoEstimate — fail-safe для першої generation"

# ============================================================
# A8 — unrelated unavailable health volume (не бере участі в backup)
# ============================================================
$a8Drives = @((New-ArchiveDiskSpaceDrive -Drive 'C:' -AvailableGB 50), (New-ArchiveDiskSpaceDrive -Drive 'F:' -AvailableGB 50 | ForEach-Object { $_.IsReady = $false; $_ }))
$a8 = Invoke-ArchiveSpaceDecision -EnabledArchives @() -EstimatedResult (New-ArchiveDiskSpaceEstimate -ComponentSizes @{}) -MinimumFreeSpaceGB 20 -Drives $a8Drives
Test-BRAVOCondition `
    -Condition ($a8.Success) `
    -Name 'Archive/A8-UnrelatedUnavailableHealthVolumeNonBlocking' `
    -Failure "недоступний диск (F:), який не бере участі в жодному enabled component, не повинен блокувати health-only sweep"

# ============================================================
# A14 — ProjectedFreeGB: ALLOW, але залишок після вирахування вимоги
# нижче floor => PASS + WARNING ProjectedBelowHealthFloor
# ============================================================
$a14Drives = @(New-ArchiveDiskSpaceDrive -Drive 'E:' -AvailableGB 30)
$a14Archives = @(@{ Type = 'MODEL'; Source = 'E:\Source\MODEL'; Destination = 'E:\ARCHIV\MODEL' })
$a14Estimate = New-ArchiveDiskSpaceEstimate -ComponentSizes @{ MODEL = 28 }
$a14 = Invoke-ArchiveSpaceDecision -EnabledArchives $a14Archives -EstimatedResult $a14Estimate -MinimumFreeSpaceGB 20 -Drives $a14Drives
$a14Destination = $a14.Results | Where-Object { $_.Roles -contains 'MODEL_ARCHIVE_DESTINATION' }
Test-BRAVOCondition `
    -Condition ($a14.Success -and $a14Destination.ProjectedFreeGB -eq 2 -and $a14Destination.Reason -eq 'ProjectedBelowHealthFloor') `
    -Name 'Archive/A14-ProjectedFreeGBBelowFloorWarns' `
    -Failure "Available=30, AggregatedRequiredGB=28 => ALLOW, але ProjectedFreeGB=2 < floor=20 має дати PASS+WARNING ProjectedBelowHealthFloor, отримано ProjectedFreeGB=$($a14Destination.ProjectedFreeGB) Reason=$($a14Destination.Reason)"

# ============================================================
# A6 — health-only C: без estimate, below floor => WARNING, PASS
# ============================================================
$a6Drives = @(New-ArchiveDiskSpaceDrive -Drive 'C:' -AvailableGB 15)
$a6 = Invoke-ArchiveSpaceDecision -EnabledArchives @() -EstimatedResult (New-ArchiveDiskSpaceEstimate -ComponentSizes @{}) -MinimumFreeSpaceGB 20 -Drives $a6Drives
Test-BRAVOCondition `
    -Condition ($a6.Success -and @($a6.Warnings).Count -eq 1) `
    -Name 'Archive/A6-HealthOnlyVolumeWithoutEstimateWarns' `
    -Failure "health-only диск без жодного enabled component має WARNING, не BLOCK"

# ============================================================
# A7 — required destination unavailable => BLOCK AccessUnavailable
# ============================================================
$a7Drives = @(New-ArchiveDiskSpaceDrive -Drive 'D:' -AvailableGB 50 -TotalGB 50 | ForEach-Object { $_.IsReady = $false; $_ })
$a7Archives = @(@{ Type = 'MODEL'; Source = 'D:\Source\MODEL'; Destination = 'D:\ARCHIV\MODEL' })
$a7 = Invoke-ArchiveSpaceDecision -EnabledArchives $a7Archives -EstimatedResult (New-ArchiveDiskSpaceEstimate -ComponentSizes @{ MODEL = 5 }) -MinimumFreeSpaceGB 20 -Drives $a7Drives
Test-BRAVOCondition `
    -Condition (-not $a7.Success -and (@($a7.Results | Where-Object { $_.Blocks })[0]).Reason -eq 'AccessUnavailable') `
    -Name 'Archive/A7-RequiredDestinationUnavailableBlocks' `
    -Failure "недоступний required destination має BLOCK AccessUnavailable"

# ============================================================
# A9 — multiple components same volume: сумарна вимога
# ============================================================
$a9Drives = @(New-ArchiveDiskSpaceDrive -Drive 'E:' -AvailableGB 30)
$a9Archives = @(
    @{ Type = 'MODEL'; Source = 'E:\Source\MODEL'; Destination = 'E:\ARCHIV\MODEL' },
    @{ Type = 'BLOG'; Source = 'E:\Source\BLOG'; Destination = 'E:\ARCHIV\BLOG' },
    @{ Type = 'BRAVOEXCH'; Source = 'E:\Source\BRAVOEXCH'; Destination = 'E:\ARCHIV\BRAVOEXCH' }
)
$a9Estimate = New-ArchiveDiskSpaceEstimate -ComponentSizes @{ MODEL = 10; BLOG = 5; BRAVOEXCH = 8 }
$a9 = Invoke-ArchiveSpaceDecision -EnabledArchives $a9Archives -EstimatedResult $a9Estimate -MinimumFreeSpaceGB 20 -Drives $a9Drives
$a9Destination = $a9.Results | Where-Object { $_.Roles -contains 'MODEL_ARCHIVE_DESTINATION' }
Test-BRAVOCondition `
    -Condition ($a9.Success -and $a9Destination.AggregatedRequiredGB -eq 23) `
    -Name 'Archive/A9-MultipleComponentsSameVolumeAggregate' `
    -Failure "MODEL(10)+BLOG(5)+BRAVOEXCH(8)=23 <= Available(30) має PASS з AggregatedRequiredGB=23, отримано $($a9Destination.AggregatedRequiredGB)"

# ============================================================
# A10 — same volume insufficient
# ============================================================
$a10Drives = @(New-ArchiveDiskSpaceDrive -Drive 'E:' -AvailableGB 20)
$a10 = Invoke-ArchiveSpaceDecision -EnabledArchives $a9Archives -EstimatedResult $a9Estimate -MinimumFreeSpaceGB 20 -Drives $a10Drives
Test-BRAVOCondition `
    -Condition (-not $a10.Success -and (@($a10.Results | Where-Object { $_.Blocks })[0]).Reason -eq 'EstimatedRequirementNotMet') `
    -Name 'Archive/A10-SameVolumeInsufficientBlocks' `
    -Failure "сумарна вимога 23 > Available 20 має BLOCK EstimatedRequirementNotMet"

# ============================================================
# A11 — split destinations: D достатньо, E недостатньо => overall BLOCK
# ============================================================
$a11Drives = @(New-ArchiveDiskSpaceDrive -Drive 'D:' -AvailableGB 50; New-ArchiveDiskSpaceDrive -Drive 'E:' -AvailableGB 10)
$a11Archives = @(
    @{ Type = 'MODEL'; Source = 'D:\Source\MODEL'; Destination = 'D:\ARCHIV\MODEL' },
    @{ Type = 'BLOG'; Source = 'E:\Source\BLOG'; Destination = 'E:\ARCHIV\BLOG' },
    @{ Type = 'BRAVOEXCH'; Source = 'E:\Source\BRAVOEXCH'; Destination = 'E:\ARCHIV\BRAVOEXCH' }
)
$a11Estimate = New-ArchiveDiskSpaceEstimate -ComponentSizes @{ MODEL = 10; BLOG = 5; BRAVOEXCH = 8 }
$a11 = Invoke-ArchiveSpaceDecision -EnabledArchives $a11Archives -EstimatedResult $a11Estimate -MinimumFreeSpaceGB 5 -Drives $a11Drives
$a11D = $a11.Results | Where-Object { $_.Roles -contains 'MODEL_ARCHIVE_DESTINATION' }
$a11E = $a11.Results | Where-Object { $_.Roles -contains 'BLOG_ARCHIVE_DESTINATION' }
Test-BRAVOCondition `
    -Condition (-not [bool]$a11D.Blocks -and [bool]$a11E.Blocks -and -not $a11.Success) `
    -Name 'Archive/A11-SplitDestinationsIndependentEvaluation' `
    -Failure "D (сумарно 10, доступно 50) має OK, E (сумарно 13, доступно 10) має BLOCK; overall Success=false"

# ============================================================
# A15 — усі компоненти вимкнено => PASS, без BLOCK
# ============================================================
$a15 = Invoke-ArchiveSpaceDecision -EnabledArchives @() -EstimatedResult (New-ArchiveDiskSpaceEstimate -ComponentSizes @{}) -MinimumFreeSpaceGB 20 -Drives @(New-ArchiveDiskSpaceDrive -Drive 'C:' -AvailableGB 100)
Test-BRAVOCondition `
    -Condition ($a15.Success -and @($a15.Results | Where-Object { $_.Blocks }).Count -eq 0) `
    -Name 'Archive/A15-AllComponentsDisabledPasses' `
    -Failure "усі архівні компоненти вимкнено має PASS без жодного BLOCK"

# ============================================================
# A16 — два блокуючі диски одночасно: обидва в Problems, overall BLOCK
# ============================================================
$a16Drives = @(New-ArchiveDiskSpaceDrive -Drive 'D:' -AvailableGB 5; New-ArchiveDiskSpaceDrive -Drive 'E:' -AvailableGB 5)
$a16Archives = @(
    @{ Type = 'MODEL'; Source = 'D:\Source\MODEL'; Destination = 'D:\ARCHIV\MODEL' },
    @{ Type = 'BLOG'; Source = 'E:\Source\BLOG'; Destination = 'E:\ARCHIV\BLOG' }
)
$a16Estimate = New-ArchiveDiskSpaceEstimate -ComponentSizes @{ MODEL = 10; BLOG = 10 }
$a16 = Invoke-ArchiveSpaceDecision -EnabledArchives $a16Archives -EstimatedResult $a16Estimate -MinimumFreeSpaceGB 20 -Drives $a16Drives
Test-BRAVOCondition `
    -Condition (-not $a16.Success -and @($a16.Problems).Count -eq 2) `
    -Name 'Archive/A16-TwoBlockingVolumesBothReported' `
    -Failure "обидва недостатні диски (D:, E:) мають потрапити в Problems окремо; отримано $(@($a16.Problems).Count)"

# ============================================================
# A17 — source below floor, destination достатньо: Warning, не Block
# ============================================================
$a17Drives = @(New-ArchiveDiskSpaceDrive -Drive 'D:' -AvailableGB 10; New-ArchiveDiskSpaceDrive -Drive 'E:' -AvailableGB 200)
$a17Archives = @(@{ Type = 'MODEL'; Source = 'D:\Source\MODEL'; Destination = 'E:\ARCHIV\MODEL' })
$a17Estimate = New-ArchiveDiskSpaceEstimate -ComponentSizes @{ MODEL = 5 }
$a17 = Invoke-ArchiveSpaceDecision -EnabledArchives $a17Archives -EstimatedResult $a17Estimate -MinimumFreeSpaceGB 20 -Drives $a17Drives
Test-BRAVOCondition `
    -Condition ($a17.Success -and @($a17.Warnings).Count -eq 1) `
    -Name 'Archive/A17-SourceBelowFloorDestinationSufficientWarns' `
    -Failure "MODEL_SOURCE на D: (10GB, below floor) не блокує, коли призначення на E: достатнє — лише WARNING"

# ============================================================
# A19 — source accessible + low free space: WARNING, продовжуємо
# ============================================================
Test-BRAVOCondition `
    -Condition ($a17.Success) `
    -Name 'Archive/A19-SourceAccessibleLowFreeSpaceContinues' `
    -Failure "той самий сценарій A17 доводить: доступне джерело з малим вільним місцем не блокує"

# ============================================================
# A20 — source inaccessible => BLOCK AccessUnavailable
# ============================================================
$a20Drives = @(
    (New-ArchiveDiskSpaceDrive -Drive 'D:' -AvailableGB 10 | ForEach-Object { $_.IsReady = $false; $_ }),
    (New-ArchiveDiskSpaceDrive -Drive 'E:' -AvailableGB 200)
)
$a20Archives = @(@{ Type = 'MODEL'; Source = 'D:\Source\MODEL'; Destination = 'E:\ARCHIV\MODEL' })
$a20 = Invoke-ArchiveSpaceDecision -EnabledArchives $a20Archives -EstimatedResult (New-ArchiveDiskSpaceEstimate -ComponentSizes @{ MODEL = 5 }) -MinimumFreeSpaceGB 20 -Drives $a20Drives
Test-BRAVOCondition `
    -Condition (-not $a20.Success -and (@($a20.Results | Where-Object { $_.Blocks })[0]).Reason -eq 'AccessUnavailable') `
    -Name 'Archive/A20-SourceInaccessibleBlocks' `
    -Failure "недоступне (IsReady=false) джерело MODEL_SOURCE має BLOCK AccessUnavailable"

# ============================================================
# A24/A25 — PeakSafeEstimate=false рішення reviewer #2: below-floor
# при достатній оцінці БЛОКУЄ (A24); той самий вхід під ArchivePeakSafe
# policy (доводить реальний код-шлях §24.1) — WARNING+ALLOW (A25).
# ============================================================
$a24Drives = @(New-ArchiveDiskSpaceDrive -Drive 'E:' -AvailableGB 18)
$a24Archives = @(@{ Type = 'MODEL'; Source = 'E:\Source\MODEL'; Destination = 'E:\ARCHIV\MODEL' })
$a24Estimate = New-ArchiveDiskSpaceEstimate -ComponentSizes @{ MODEL = 7 }
$a24 = Invoke-ArchiveSpaceDecision -EnabledArchives $a24Archives -EstimatedResult $a24Estimate -MinimumFreeSpaceGB 20 -Drives $a24Drives
Test-BRAVOCondition `
    -Condition (-not $a24.Success -and (@($a24.Results | Where-Object { $_.Blocks })[0]).Reason -eq 'BelowFloorEstimateNotPeakSafe') `
    -Name 'Archive/A24-BelowFloorNotPeakSafeBlocks' `
    -Failure "Resolve-BRAVOArchiveSpaceDecision використовує RequirementPolicy=ArchiveNotPeakSafe: below-floor (18<20) з достатньою оцінкою (7<=18) має БЛОКУВАТИ BelowFloorEstimateNotPeakSafe (рішення reviewer #2), а не послаблювати поріг як у 5.2.1"

Import-Module -Name (Join-Path $root "modules\BRAVO.DiskSpace\BRAVO.DiskSpace.psd1") -Force -ErrorAction Stop
$a25 = Invoke-BRAVODiskSpaceClassifier `
    -EntitySpecs @([pscustomobject]@{ DisplayPath = 'E:\ARCHIV\MODEL'; Roles = @('MODEL_ARCHIVE_DESTINATION'); RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity'; RequiredGB = 7 }) `
    -MinimumFreeSpaceGB 20 -RequirementPolicy 'ArchivePeakSafe' -Drives $a24Drives
Test-BRAVOCondition `
    -Condition ($a25.Success -and $a25.Results[0].Reason -eq 'BelowHealthFloorButRequirementSatisfied') `
    -Name 'Archive/A25-SameInputPeakSafePolicyAllows' `
    -Failure "той самий вхід (18<20, 7<=18) під ArchivePeakSafe policy (не використовується у production-виклику 5.2.3, лише доводить наявність коду §24.1) має ALLOW+WARNING BelowHealthFloorButRequirementSatisfied"

# ============================================================
# Structural: виклик-сайт Main викликає Resolve-BRAVOArchiveSpaceDecision
# у правильному порядку (замінює колишній
# EstimatedSpacePreflightWiredIntoFreeSpaceCheck для Merge-*).
# ============================================================
Test-BRAVOCondition `
    -Condition (
        $archiveScriptText.Contains('function Resolve-BRAVOArchiveSpaceDecision') -and
        $archiveScriptText.Contains('$archiveSpaceDecision = Resolve-BRAVOArchiveSpaceDecision') -and
        $archiveScriptText.IndexOf('$archiveEstimatedSpaceResult = Get-BRAVOArchiveEstimatedSpaceRequirement') -gt
            $archiveScriptText.IndexOf('$archiveFreeSpaceResult = Get-BRAVOArchiveFreeSpaceResult') -and
        $archiveScriptText.IndexOf('$archiveSpaceDecision = Resolve-BRAVOArchiveSpaceDecision') -gt
            $archiveScriptText.IndexOf('$archiveEstimatedSpaceResult = Get-BRAVOArchiveEstimatedSpaceRequirement') -and
        $archiveScriptText.IndexOf('$archiveSpaceDecision = Resolve-BRAVOArchiveSpaceDecision') -lt
            $archiveScriptText.IndexOf('$archiveFreeSpaceReason = if (') -and
        -not $archiveScriptText.Contains('function Merge-BRAVOArchiveSpaceCheckResults')
    ) `
    -Name 'Archive/SpaceDecisionWiredIntoFreeSpaceCheck' `
    -Failure 'Resolve-BRAVOArchiveSpaceDecision має викликатися в тому самому preflight-кроці, ПІСЛЯ фіксованого порогу і розрахункової оцінки, ДО обчислення підсумкового Reason; стара Merge-BRAVOArchiveSpaceCheckResults має бути видалена, не залишена паралельно'
