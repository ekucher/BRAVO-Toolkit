# Канонічний, спільний для BRAVO_ARCHIV та BRAVO_MAINTENANCE, operation-aware
# класифікатор перевірки вільного місця/доступу до storage.
#
# Контекст (BRAVO-Toolkit 5.2.3, fix/5.2.3-operation-aware-disk-space):
# до цього релізу MinimumFreeSpaceGB діяв як глобальний execution gate по
# всіх локальних Fixed-дисках — операція блокувалась навіть якщо мало
# місця лише на диску, який ця операція фактично не використовує (напр.
# C: з runtime/логами, коли Archive пише на D/E). Цей модуль реалізує
# розділення трьох незалежних семантик:
#
#     Participates       — том/шлях бере участь в операції (діагностика)
#     RequiresAccess      — операція неможлива без доступу до тому/шляху
#     RequiresFreeSpace   — операція реально потребує вільного місця тут
#
# і canonical decision algorithm (24-крокова специфікація для Archive,
# §45.0 — той самий спільний алгоритм для Maintenance) з інваріантом
# RequiresFreeSpace=true => RequiresAccess=true.
#
# Модуль НЕ є entrypoint-скриптом (на відміну від BRAVO.Archive.Runtime.ps1/
# BRAVO.Maintenance.Runtime.ps1) — це чиста бібліотека функцій, яку
# викликають Archive/Maintenance runtime через Invoke-BRAVODiskSpaceClassifier.
# Свідоме архітектурне відхилення від "thin entrypoint over runtime script":
# тут немає власного Invoke-BRAVO*Entrypoint, бо немає окремого процесу для
# запуску — модуль підключається через Import-Module так само, як
# BRAVO.ExitCodes/BRAVO.Logging.
#
# Минуле рішення (5.2.1): Archive мав власний Merge-BRAVOArchiveSpaceCheckResults,
# який послаблював фіксований поріг per-drive, коли Get-BRAVOArchiveEstimatedSpaceRequirement
# показував достатність. Ця функція видалена в 5.2.3 разом з переходом на
# спільний класифікатор: PeakSafeEstimate=false для Archive (estimator НЕ
# доведений peak-safe — не враховує retained generations і .work тимчасові
# файли), тому below-floor relaxation свідомо вимкнено — див. політику
# 'ArchiveNotPeakSafe' нижче. Це навмисне посилення проти 5.2.1, задокументоване
# окремо (CHANGELOG/upgrade notes), а не регресія.

Set-StrictMode -Version Latest

# ------------------------------------------------------------------
# Канонічний result object (§16 специфікації)
# ------------------------------------------------------------------

function New-BRAVODiskSpaceResult {
    [CmdletBinding()]
    param(
        [string]$StorageKind = 'LocalVolume',
        [string]$DisplayPath,
        [string]$CapacityKey,
        [string]$VolumeKey,
        [string]$VolumeId,
        [string]$Drive,
        [string]$DriveType,
        [string[]]$Roles = @(),
        [string[]]$Components = @(),
        [bool]$Participates = $true,
        [bool]$RequiresAccess = $false,
        [bool]$RequiresFreeSpace = $false,
        [string]$AccessStatus = 'Unknown',
        [string]$CapacityState = 'Unknown',
        [System.Nullable[double]]$AvailableGB,
        [System.Nullable[double]]$TotalGB,
        [System.Nullable[double]]$MinimumGB,
        [string]$RequirementGranularity,
        [string]$GroupRequirementState,
        [System.Nullable[double]]$RequiredGB,
        [System.Nullable[double]]$KnownRequiredLowerBoundGB,
        [System.Nullable[double]]$AggregatedRequiredGB,
        [System.Nullable[double]]$ResidualAvailableGB,
        [System.Nullable[double]]$ProjectedFreeGB,
        [string]$Status = 'Success',
        [bool]$Blocks = $false,
        [string]$Reason,
        [string[]]$Flags = @()
    )

    return [pscustomobject]@{
        StorageKind               = $StorageKind
        DisplayPath               = $DisplayPath
        CapacityKey               = $CapacityKey
        VolumeKey                 = $VolumeKey
        VolumeId                  = $VolumeId
        Drive                     = $Drive
        DriveType                 = $DriveType
        Roles                     = @($Roles)
        Components                = @($Components)
        Participates              = $Participates
        RequiresAccess            = $RequiresAccess
        RequiresFreeSpace         = $RequiresFreeSpace
        AccessStatus              = $AccessStatus
        CapacityState             = $CapacityState
        AvailableGB               = $AvailableGB
        TotalGB                   = $TotalGB
        MinimumGB                 = $MinimumGB
        RequirementGranularity    = $RequirementGranularity
        GroupRequirementState     = $GroupRequirementState
        RequiredGB                = $RequiredGB
        KnownRequiredLowerBoundGB = $KnownRequiredLowerBoundGB
        AggregatedRequiredGB      = $AggregatedRequiredGB
        ResidualAvailableGB       = $ResidualAvailableGB
        ProjectedFreeGB           = $ProjectedFreeGB
        Status                    = $Status
        Blocks                    = $Blocks
        Reason                    = $Reason
        Flags                     = @($Flags)
    }
}

# ------------------------------------------------------------------
# §24 крок 4 / §35 / §35.1 / §35.2 — resolution storage identity
# ------------------------------------------------------------------

function Resolve-BRAVODiskSpaceStorageIdentity {
    # Визначає StorageKind/CapacityKey/Drive для одного DisplayPath.
    #
    # LocalVolume: CapacityKey = буква диска (нормалізована), Drive/DriveType
    # заповнюються з [System.IO.DriveInfo] (або injected -Drives для тестів).
    # Bootstrap (§35.1): якщо DisplayPath ще не існує, резолвиться
    # найближчий існуючий предок; якщо не існує навіть корінь — Failed=$true.
    #
    # UNC: CapacityKey = нормалізований \\server\share (перші два сегменти
    # шляху), без спроби Windows physical-volume resolution (§34.1).
    #
    # SFTP/OtherRemote: фізичний resolver із самої природи неможливий (§34.1)
    # — виклик має передати -CapacityKey напряму (canonical transport/endpoint
    # identity); ця функція лише валідує, що CapacityKey заданий.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DisplayPath,
        [ValidateSet('LocalVolume', 'UNC', 'SFTP', 'OtherRemote')]
        [string]$StorageKind,
        [string]$CapacityKey,
        [object[]]$Drives
    )

    $resolvedKind = $StorageKind
    if ([string]::IsNullOrWhiteSpace($resolvedKind)) {
        $resolvedKind = if ($DisplayPath -match '^\\\\[^\\]+\\[^\\]+') { 'UNC' } else { 'LocalVolume' }
    }

    if ($resolvedKind -eq 'SFTP' -or $resolvedKind -eq 'OtherRemote') {
        if ([string]::IsNullOrWhiteSpace($CapacityKey)) {
            return [pscustomobject]@{
                Failed = $true
                StorageKind = $resolvedKind
                CapacityKey = $null
                Drive = $null
                DriveType = $null
                VolumeKey = $null
                VolumeId = $null
            }
        }
        return [pscustomobject]@{
            Failed = $false
            StorageKind = $resolvedKind
            CapacityKey = $CapacityKey
            Drive = $null
            DriveType = $null
            VolumeKey = $CapacityKey
            VolumeId = $null
        }
    }

    if ($resolvedKind -eq 'UNC') {
        if ($DisplayPath -notmatch '^(\\\\[^\\]+\\[^\\]+)') {
            return [pscustomobject]@{
                Failed = $true
                StorageKind = 'UNC'
                CapacityKey = $null
                Drive = $null
                DriveType = $null
                VolumeKey = $null
                VolumeId = $null
            }
        }
        $shareRoot = $Matches[1].ToLowerInvariant()
        return [pscustomobject]@{
            Failed = $false
            StorageKind = 'UNC'
            CapacityKey = $shareRoot
            Drive = $null
            DriveType = $null
            VolumeKey = $shareRoot
            VolumeId = $null
        }
    }

    # LocalVolume: §35.1 bootstrap — walk up до найближчого існуючого предка.
    $probePath = $DisplayPath
    $foundExisting = $false
    for ($depth = 0; $depth -lt 64; $depth++) {
        if ([string]::IsNullOrWhiteSpace($probePath)) { break }
        if (Test-Path -LiteralPath $probePath) { $foundExisting = $true; break }
        $parent = Split-Path -Path $probePath -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probePath) { break }
        $probePath = $parent
    }

    $driveLetter = $null
    try {
        $driveLetter = ([IO.Path]::GetPathRoot($DisplayPath)).TrimEnd('\').ToUpperInvariant()
    } catch {
        $driveLetter = $null
    }

    if ([string]::IsNullOrWhiteSpace($driveLetter)) {
        return [pscustomobject]@{
            Failed = $true
            StorageKind = 'LocalVolume'
            CapacityKey = $null
            Drive = $null
            DriveType = $null
            VolumeKey = $null
            VolumeId = $null
        }
    }

    # Корінь тому (driveLetter) сам по собі має існувати, навіть якщо
    # DisplayPath — ще не створений підкаталог (§35.1 п.3).
    $driveType = $null
    $driveResolved = $false
    try {
        if ($PSBoundParameters.ContainsKey('Drives')) {
            $injected = @($Drives | Where-Object {
                ([string]$_.Drive).TrimEnd('\').ToUpperInvariant() -eq $driveLetter
            } | Select-Object -First 1)
            if ($injected.Count -gt 0) {
                $driveResolved = $true
                $driveType = if ($injected[0].PSObject.Properties.Match('DriveType').Count -gt 0) { [string]$injected[0].DriveType } else { 'Fixed' }
            }
        } else {
            $driveInfo = New-Object System.IO.DriveInfo($driveLetter)
            $driveResolved = $true
            $driveType = [string]$driveInfo.DriveType
        }
    } catch {
        $driveResolved = $false
    }

    if (-not $foundExisting -or -not $driveResolved) {
        return [pscustomobject]@{
            Failed = $true
            StorageKind = 'LocalVolume'
            CapacityKey = $driveLetter
            Drive = $driveLetter
            DriveType = $driveType
            VolumeKey = $driveLetter
            VolumeId = $null
        }
    }

    return [pscustomobject]@{
        Failed = $false
        StorageKind = 'LocalVolume'
        CapacityKey = $driveLetter
        Drive = $driveLetter
        DriveType = $driveType
        VolumeKey = $driveLetter
        VolumeId = $null
    }
}

# ------------------------------------------------------------------
# §24 крок 5/6 — AccessStatus truth table
# ------------------------------------------------------------------

function Get-BRAVODiskSpaceAccessState {
    # Визначає AccessStatus. Якщо -AccessStatusOverride заданий (наприклад,
    # SFTP-сесія вже перевірена викликачем), він має пріоритет — ця функція
    # не виконує власних SFTP/UNC probe (поза scope §36 — не додавати нові
    # storage-типи). Для LocalVolume/UNC без override виконується best-effort
    # локальна перевірка.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StorageKind,
        [string]$DisplayPath,
        [string]$Drive,
        [string]$AccessStatusOverride,
        [object[]]$Drives
    )

    if (-not [string]::IsNullOrWhiteSpace($AccessStatusOverride)) {
        return $AccessStatusOverride
    }

    if ($StorageKind -eq 'LocalVolume') {
        if ([string]::IsNullOrWhiteSpace($Drive)) { return 'Unknown' }
        try {
            if ($PSBoundParameters.ContainsKey('Drives')) {
                $injected = @($Drives | Where-Object {
                    ([string]$_.Drive).TrimEnd('\').ToUpperInvariant() -eq $Drive
                } | Select-Object -First 1)
                if ($injected.Count -eq 0) { return 'Unknown' }
                return $(if ([bool]$injected[0].IsReady) { 'Available' } else { 'Unavailable' })
            }
            $driveInfo = New-Object System.IO.DriveInfo($Drive)
            return $(if ($driveInfo.IsReady) { 'Available' } else { 'Unavailable' })
        } catch {
            return 'Unknown'
        }
    }

    if ($StorageKind -eq 'UNC') {
        try {
            return $(if (Test-Path -LiteralPath $DisplayPath) { 'Available' } else { 'Unavailable' })
        } catch {
            return 'Unknown'
        }
    }

    # SFTP/OtherRemote без override: викликач зобов'язаний передати
    # AccessStatusOverride (доступ до транспорту класифікатор не перевіряє
    # сам). Fail-closed за замовчуванням.
    return 'Unknown'
}

# ------------------------------------------------------------------
# §24 крок 9 — нормалізація capacity на рівні CapacityKey
# ------------------------------------------------------------------

function Get-BRAVODiskSpaceCapacityObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StorageKind,
        [Parameter(Mandatory = $true)][string]$CapacityKey,
        [string]$Drive,
        # Кожен елемент: @{ CapacityState = 'Known'|'Unknown'|'NotApplicable'; AvailableGB = <double|$null>; TotalGB = <double|$null> }
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Observations,
        [object[]]$Drives
    )

    $conflict = $false

    if ($StorageKind -eq 'LocalVolume') {
        $availableGB = $null
        $totalGB = $null
        $resolved = $false
        try {
            if ($PSBoundParameters.ContainsKey('Drives')) {
                $injected = @($Drives | Where-Object {
                    ([string]$_.Drive).TrimEnd('\').ToUpperInvariant() -eq $Drive
                } | Select-Object -First 1)
                if ($injected.Count -gt 0 -and [bool]$injected[0].IsReady) {
                    $availableGB = [math]::Round(([double]$injected[0].AvailableFreeSpace / 1GB), 2)
                    if ($injected[0].PSObject.Properties.Match('TotalSize').Count -gt 0) {
                        $totalGB = [math]::Round(([double]$injected[0].TotalSize / 1GB), 2)
                    }
                    $resolved = $true
                }
            } else {
                $driveInfo = New-Object System.IO.DriveInfo($Drive)
                if ($driveInfo.IsReady) {
                    $availableGB = [math]::Round(([double]$driveInfo.AvailableFreeSpace / 1GB), 2)
                    $totalGB = [math]::Round(([double]$driveInfo.TotalSize / 1GB), 2)
                    $resolved = $true
                }
            }
        } catch {
            $resolved = $false
        }

        if (-not $resolved) {
            return [pscustomobject]@{ CapacityState = 'Unknown'; AvailableGB = $null; TotalGB = $null; Conflict = $false }
        }
        return [pscustomobject]@{ CapacityState = 'Known'; AvailableGB = $availableGB; TotalGB = $totalGB; Conflict = $false }
    }

    # UNC / SFTP / OtherRemote: немає нового физичного resolver-а (§36) —
    # довіряємо спостереженням, наданим викликачем (напр. BAZA SFTP-сесія
    # вже перевірила доступність, capacity API зазвичай відсутній).
    $knownObservations = @($Observations | Where-Object { $_.CapacityState -eq 'Known' })
    $unknownObservations = @($Observations | Where-Object { $_.CapacityState -ne 'Known' })

    if ($knownObservations.Count -gt 0 -and $unknownObservations.Count -gt 0) {
        $conflict = $true
    }
    if ($knownObservations.Count -gt 1) {
        $distinctValues = @($knownObservations | Select-Object -ExpandProperty AvailableGB -Unique)
        if ($distinctValues.Count -gt 1) { $conflict = $true }
    }

    if ($conflict) {
        return [pscustomobject]@{ CapacityState = 'Unknown'; AvailableGB = $null; TotalGB = $null; Conflict = $true }
    }
    if ($knownObservations.Count -gt 0) {
        $first = $knownObservations[0]
        return [pscustomobject]@{ CapacityState = 'Known'; AvailableGB = $first.AvailableGB; TotalGB = $first.TotalGB; Conflict = $false }
    }
    return [pscustomobject]@{ CapacityState = 'Unknown'; AvailableGB = $null; TotalGB = $null; Conflict = $false }
}

# ------------------------------------------------------------------
# §24 крок 10 (A/B/C) — group requirement ownership
# ------------------------------------------------------------------

function Resolve-BRAVODiskSpaceGroupRequirement {
    [CmdletBinding()]
    param(
        # 'Entity' | 'CapacityGroup' | 'Unknown'. Якщо entities у групі мають
        # несумісні значення — викликач має заздалегідь звести до 'Unknown'.
        [Parameter(Mandatory = $true)][string]$RequirementGranularity,
        # Для Entity: масив double? (RequiredGB кожної write-required entity).
        [double[]]$EntityRequiredGB = @(),
        [bool]$AllEntityRequirementsKnown = $true,
        # Для CapacityGroup: одне значення (provider-owned), або $null якщо невідоме.
        [System.Nullable[double]]$CapacityGroupRequiredGB,
        [System.Nullable[double]]$CapacityGroupKnownLowerBoundGB,
        [Parameter(Mandatory = $true)][double]$AvailableGB
    )

    $result = [pscustomobject]@{
        GroupRequirementState     = 'Unknown'
        AggregatedRequiredGB      = $null
        KnownRequiredLowerBoundGB = 0.0
        ResidualAvailableGB       = $AvailableGB
    }

    if ($RequirementGranularity -eq 'Entity') {
        $knownSum = 0.0
        foreach ($value in $EntityRequiredGB) { $knownSum += [double]$value }
        $result.KnownRequiredLowerBoundGB = $knownSum
        if ($AllEntityRequirementsKnown) {
            $result.GroupRequirementState = 'Known'
            $result.AggregatedRequiredGB = $knownSum
        } else {
            $result.GroupRequirementState = 'Unknown'
            $result.AggregatedRequiredGB = $null
        }
    } elseif ($RequirementGranularity -eq 'CapacityGroup') {
        if ($null -ne $CapacityGroupRequiredGB) {
            $result.GroupRequirementState = 'Known'
            $result.AggregatedRequiredGB = [double]$CapacityGroupRequiredGB
            $result.KnownRequiredLowerBoundGB = [double]$CapacityGroupRequiredGB
        } else {
            $result.GroupRequirementState = 'Unknown'
            $result.AggregatedRequiredGB = $null
            $result.KnownRequiredLowerBoundGB = if ($null -ne $CapacityGroupKnownLowerBoundGB) { [double]$CapacityGroupKnownLowerBoundGB } else { 0.0 }
        }
    } else {
        # Unknown/ambiguous granularity — жодної евристичної агрегації.
        $result.GroupRequirementState = 'Unknown'
        $result.AggregatedRequiredGB = $null
        $result.KnownRequiredLowerBoundGB = 0.0
    }

    $result.ResidualAvailableGB = $AvailableGB - $result.KnownRequiredLowerBoundGB
    return $result
}

# ------------------------------------------------------------------
# §24 кроки 1-8 — Фаза 1, per-entity orchestrator
# ------------------------------------------------------------------

function Test-BRAVODiskSpaceEntity {
    # Вхід $EntitySpec (pscustomobject/hashtable), обов'язкові поля:
    #   DisplayPath, RequiresAccess, RequiresFreeSpace
    # опціональні: Roles, Components, Participates, StorageKind, CapacityKey
    #   (для SFTP/OtherRemote — обов'язковий), AccessStatusOverride,
    #   CapacityStateOverride/AvailableGBOverride/TotalGBOverride (для
    #   UNC/SFTP/OtherRemote — власного capacity resolver немає, §36),
    #   RequirementGranularity, RequiredGB, CapacityGroupRequiredGB,
    #   CapacityGroupKnownLowerBoundGB.
    #
    # Повертає @{ Result = <canonical result>; Pending = $true|$false;
    #              EntitySpec = $EntitySpec }
    # Pending=$true означає "чекає Phase-2 group evaluation" (крок 8).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$EntitySpec,
        [object[]]$Drives,
        [string[]]$ExcludedDrives = @()
    )

    $roles = @(if ($EntitySpec.PSObject.Properties.Match('Roles').Count -gt 0) { $EntitySpec.Roles } else { @() })
    $components = @(if ($EntitySpec.PSObject.Properties.Match('Components').Count -gt 0) { $EntitySpec.Components } else { @() })
    $participates = if ($EntitySpec.PSObject.Properties.Match('Participates').Count -gt 0) { [bool]$EntitySpec.Participates } else { $true }
    $requiresAccess = [bool]$EntitySpec.RequiresAccess
    $requiresFreeSpace = [bool]$EntitySpec.RequiresFreeSpace
    $flags = New-Object System.Collections.Generic.List[string]

    # Крок 3: інваріант §3.4.
    if ($requiresFreeSpace -and (-not $requiresAccess)) {
        $requiresAccess = $true
        [void]$flags.Add('InvalidRoleClassification')
    }

    $storageKindHint = if ($EntitySpec.PSObject.Properties.Match('StorageKind').Count -gt 0) { [string]$EntitySpec.StorageKind } else { $null }
    $capacityKeyHint = if ($EntitySpec.PSObject.Properties.Match('CapacityKey').Count -gt 0) { [string]$EntitySpec.CapacityKey } else { $null }

    $identityParams = @{ DisplayPath = [string]$EntitySpec.DisplayPath }
    if (-not [string]::IsNullOrWhiteSpace($storageKindHint)) { $identityParams.StorageKind = $storageKindHint }
    if (-not [string]::IsNullOrWhiteSpace($capacityKeyHint)) { $identityParams.CapacityKey = $capacityKeyHint }
    if ($PSBoundParameters.ContainsKey('Drives')) { $identityParams.Drives = $Drives }

    $identity = Resolve-BRAVODiskSpaceStorageIdentity @identityParams

    # Крок 4: resolution failure.
    if ($identity.Failed) {
        if ($requiresAccess -or $requiresFreeSpace) {
            $result = New-BRAVODiskSpaceResult -StorageKind $identity.StorageKind -DisplayPath ([string]$EntitySpec.DisplayPath) `
                -CapacityKey $identity.CapacityKey -Drive $identity.Drive -DriveType $identity.DriveType `
                -Roles $roles -Components $components -Participates $participates `
                -RequiresAccess $requiresAccess -RequiresFreeSpace $requiresFreeSpace `
                -Status 'Error' -Blocks $true -Reason 'VolumeResolutionFailed' -Flags $flags.ToArray()
            return @{ Result = $result; Pending = $false; EntitySpec = $EntitySpec }
        }
        [void]$flags.Add('VolumeResolutionFallback')
        $healthDrive = $identity.Drive
        $suppressed = ($null -ne $healthDrive -and $ExcludedDrives -contains $healthDrive)
        $result = New-BRAVODiskSpaceResult -StorageKind $identity.StorageKind -DisplayPath ([string]$EntitySpec.DisplayPath) `
            -CapacityKey $identity.CapacityKey -Drive $identity.Drive -DriveType $identity.DriveType `
            -Roles $roles -Components $components -Participates $participates `
            -RequiresAccess $requiresAccess -RequiresFreeSpace $requiresFreeSpace `
            -Status $(if ($suppressed) { 'Success' } else { 'Warning' }) -Blocks $false -Flags $flags.ToArray()
        return @{ Result = $result; Pending = $false; EntitySpec = $EntitySpec }
    }

    # Крок 5: AccessStatus.
    $accessOverride = if ($EntitySpec.PSObject.Properties.Match('AccessStatusOverride').Count -gt 0) { [string]$EntitySpec.AccessStatusOverride } else { $null }
    $accessParams = @{ StorageKind = $identity.StorageKind; DisplayPath = [string]$EntitySpec.DisplayPath; Drive = $identity.Drive }
    if (-not [string]::IsNullOrWhiteSpace($accessOverride)) { $accessParams.AccessStatusOverride = $accessOverride }
    if ($PSBoundParameters.ContainsKey('Drives')) { $accessParams.Drives = $Drives }
    $accessStatus = Get-BRAVODiskSpaceAccessState @accessParams

    # Крок 6: required access перед free-space логікою.
    if ($requiresAccess -and $accessStatus -eq 'Unavailable') {
        $result = New-BRAVODiskSpaceResult -StorageKind $identity.StorageKind -DisplayPath ([string]$EntitySpec.DisplayPath) `
            -CapacityKey $identity.CapacityKey -Drive $identity.Drive -DriveType $identity.DriveType `
            -Roles $roles -Components $components -Participates $participates `
            -RequiresAccess $requiresAccess -RequiresFreeSpace $requiresFreeSpace -AccessStatus $accessStatus `
            -Status 'Error' -Blocks $true -Reason 'AccessUnavailable' -Flags $flags.ToArray()
        return @{ Result = $result; Pending = $false; EntitySpec = $EntitySpec }
    }
    if ($requiresAccess -and $accessStatus -eq 'Unknown') {
        $result = New-BRAVODiskSpaceResult -StorageKind $identity.StorageKind -DisplayPath ([string]$EntitySpec.DisplayPath) `
            -CapacityKey $identity.CapacityKey -Drive $identity.Drive -DriveType $identity.DriveType `
            -Roles $roles -Components $components -Participates $participates `
            -RequiresAccess $requiresAccess -RequiresFreeSpace $requiresFreeSpace -AccessStatus $accessStatus `
            -Status 'Error' -Blocks $true -Reason 'AccessUndetermined' -Flags $flags.ToArray()
        return @{ Result = $result; Pending = $false; EntitySpec = $EntitySpec }
    }
    if ($requiresAccess -and $accessStatus -eq 'NotApplicable') {
        [void]$flags.Add('InvalidRoleClassification')
        $result = New-BRAVODiskSpaceResult -StorageKind $identity.StorageKind -DisplayPath ([string]$EntitySpec.DisplayPath) `
            -CapacityKey $identity.CapacityKey -Drive $identity.Drive -DriveType $identity.DriveType `
            -Roles $roles -Components $components -Participates $participates `
            -RequiresAccess $requiresAccess -RequiresFreeSpace $requiresFreeSpace -AccessStatus $accessStatus `
            -Status 'Error' -Blocks $true -Reason 'AccessUndetermined' -Flags $flags.ToArray()
        return @{ Result = $result; Pending = $false; EntitySpec = $EntitySpec }
    }

    # Крок 7: RequiresFreeSpace = false — лише health-спостереження.
    if (-not $requiresFreeSpace) {
        $capacityOverride = if ($EntitySpec.PSObject.Properties.Match('CapacityStateOverride').Count -gt 0) { [string]$EntitySpec.CapacityStateOverride } else { $null }
        $availableOverride = if ($EntitySpec.PSObject.Properties.Match('AvailableGBOverride').Count -gt 0) { $EntitySpec.AvailableGBOverride } else { $null }

        $healthAvailableGB = $null
        $healthCapacityState = 'Unknown'
        if (-not [string]::IsNullOrWhiteSpace($capacityOverride)) {
            $healthCapacityState = $capacityOverride
            $healthAvailableGB = $availableOverride
        } elseif ($identity.StorageKind -eq 'LocalVolume' -and -not [string]::IsNullOrWhiteSpace($identity.Drive)) {
            $observation = Get-BRAVODiskSpaceCapacityObservation -StorageKind 'LocalVolume' -CapacityKey $identity.CapacityKey `
                -Drive $identity.Drive -Observations @() -Drives $(if ($PSBoundParameters.ContainsKey('Drives')) { $Drives } else { @() })
            $healthCapacityState = $observation.CapacityState
            $healthAvailableGB = $observation.AvailableGB
        }

        $minimumGB = if ($EntitySpec.PSObject.Properties.Match('MinimumFreeSpaceGB').Count -gt 0) { [System.Nullable[double]]$EntitySpec.MinimumFreeSpaceGB } else { $null }

        $healthStatus = 'Success'
        $healthReason = $null
        if ($requiresAccess -and $accessStatus -eq 'Unavailable') {
            # Дійти сюди можна лише якщо requiresAccess=false вище — тобто
            # ця гілка на практиці не спрацьовує для requiresAccess=true
            # (той випадок уже BLOCK на кроці 6). Залишено для повноти таблиці §50.1.
            $healthStatus = 'Warning'
        } elseif ($null -ne $minimumGB -and $healthCapacityState -eq 'Known' -and $null -ne $healthAvailableGB -and [double]$healthAvailableGB -lt [double]$minimumGB) {
            $healthStatus = 'Warning'
            $healthReason = 'BelowHealthFloorNoFreeSpaceRequirement'
        } elseif ($healthCapacityState -ne 'Known') {
            $healthStatus = 'Warning'
        }

        $suppressed = $false
        if ($healthStatus -eq 'Warning' -and $null -ne $identity.Drive -and $ExcludedDrives -contains $identity.Drive) {
            $suppressed = $true
        }
        if ($suppressed) { $healthStatus = 'Success'; $healthReason = $null }

        $result = New-BRAVODiskSpaceResult -StorageKind $identity.StorageKind -DisplayPath ([string]$EntitySpec.DisplayPath) `
            -CapacityKey $identity.CapacityKey -Drive $identity.Drive -DriveType $identity.DriveType `
            -Roles $roles -Components $components -Participates $participates `
            -RequiresAccess $requiresAccess -RequiresFreeSpace $requiresFreeSpace -AccessStatus $accessStatus `
            -CapacityState $healthCapacityState -AvailableGB $healthAvailableGB -MinimumGB $minimumGB `
            -Status $healthStatus -Blocks $false -Reason $healthReason -Flags $flags.ToArray()
        return @{ Result = $result; Pending = $false; EntitySpec = $EntitySpec }
    }

    # Крок 8: RequiresFreeSpace = true — enqueue для Phase 2.
    $capacityOverride = if ($EntitySpec.PSObject.Properties.Match('CapacityStateOverride').Count -gt 0) { [string]$EntitySpec.CapacityStateOverride } else { $null }
    if ($capacityOverride -eq 'NotApplicable') {
        [void]$flags.Add('InvalidRoleClassification')
        $result = New-BRAVODiskSpaceResult -StorageKind $identity.StorageKind -DisplayPath ([string]$EntitySpec.DisplayPath) `
            -CapacityKey $identity.CapacityKey -Drive $identity.Drive -DriveType $identity.DriveType `
            -Roles $roles -Components $components -Participates $participates `
            -RequiresAccess $requiresAccess -RequiresFreeSpace $requiresFreeSpace -AccessStatus $accessStatus `
            -CapacityState 'NotApplicable' -Status 'Error' -Blocks $true -Reason 'CapacityUndetermined' -Flags $flags.ToArray()
        return @{ Result = $result; Pending = $false; EntitySpec = $EntitySpec }
    }

    $pendingResult = New-BRAVODiskSpaceResult -StorageKind $identity.StorageKind -DisplayPath ([string]$EntitySpec.DisplayPath) `
        -CapacityKey $identity.CapacityKey -Drive $identity.Drive -DriveType $identity.DriveType `
        -Roles $roles -Components $components -Participates $participates `
        -RequiresAccess $requiresAccess -RequiresFreeSpace $requiresFreeSpace -AccessStatus $accessStatus `
        -Status 'Pending' -Blocks $false -Flags $flags.ToArray()
    return @{ Result = $pendingResult; Pending = $true; EntitySpec = $EntitySpec }
}

# ------------------------------------------------------------------
# §24 кроки 9-16 — Фаза 2, per-CapacityKey group orchestrator
# ------------------------------------------------------------------

function Resolve-BRAVODiskSpaceGroupDecision {
    # $PendingEntities: масив @{ Result = <pending canonical result>; EntitySpec = <original spec> },
    # усі з однаковим CapacityKey.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$PendingEntities,
        [Parameter(Mandatory = $true)][double]$MinimumFreeSpaceGB,
        [string[]]$ExcludedDrives = @(),
        # 'ArchivePeakSafe' | 'ArchiveNotPeakSafe' | 'MaintenanceExactOnly'
        [Parameter(Mandatory = $true)][ValidateSet('ArchivePeakSafe', 'ArchiveNotPeakSafe', 'MaintenanceExactOnly')]
        [string]$RequirementPolicy,
        [object[]]$Drives
    )

    $first = $PendingEntities[0].Result
    $storageKind = $first.StorageKind
    $capacityKey = $first.CapacityKey
    $drive = $first.Drive

    # Крок 9: нормалізація capacity спостереження.
    $observations = @($PendingEntities | ForEach-Object {
        $spec = $_.EntitySpec
        $capOverride = if ($spec.PSObject.Properties.Match('CapacityStateOverride').Count -gt 0) { [string]$spec.CapacityStateOverride } else { $null }
        $availOverride = if ($spec.PSObject.Properties.Match('AvailableGBOverride').Count -gt 0) { $spec.AvailableGBOverride } else { $null }
        $totalOverride = if ($spec.PSObject.Properties.Match('TotalGBOverride').Count -gt 0) { $spec.TotalGBOverride } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($capOverride)) {
            [pscustomobject]@{ CapacityState = $capOverride; AvailableGB = $availOverride; TotalGB = $totalOverride }
        } else {
            [pscustomobject]@{ CapacityState = 'Unknown'; AvailableGB = $null; TotalGB = $null }
        }
    })

    $capacityParams = @{ StorageKind = $storageKind; CapacityKey = $capacityKey; Drive = $drive; Observations = $observations }
    if ($PSBoundParameters.ContainsKey('Drives')) { $capacityParams.Drives = $Drives }
    $capacity = Get-BRAVODiskSpaceCapacityObservation @capacityParams

    $flagsCommon = New-Object System.Collections.Generic.List[string]
    if ($capacity.Conflict) { [void]$flagsCommon.Add('CapacityObservationConflict') }

    if ($capacity.CapacityState -ne 'Known') {
        if ($storageKind -eq 'LocalVolume') {
            return @($PendingEntities | ForEach-Object {
                $r = $_.Result
                $r.CapacityState = 'Unknown'
                $r.Status = 'Error'; $r.Blocks = $true; $r.Reason = 'CapacityUndetermined'
                $r.Flags = @($r.Flags + $flagsCommon.ToArray())
                $r
            })
        }
        return @($PendingEntities | ForEach-Object {
            $r = $_.Result
            $r.CapacityState = 'Unknown'
            $r.Status = 'Warning'; $r.Blocks = $false; $r.Reason = 'CapacityUnknownRemote'
            $r.Flags = @($r.Flags + $flagsCommon.ToArray())
            $r
        })
    }

    # Крок 10: group requirement ownership.
    $granularities = @($PendingEntities | ForEach-Object {
        if ($_.EntitySpec.PSObject.Properties.Match('RequirementGranularity').Count -gt 0) { [string]$_.EntitySpec.RequirementGranularity } else { 'Unknown' }
    } | Select-Object -Unique)
    $effectiveGranularity = if ($granularities.Count -eq 1) { $granularities[0] } else { 'Unknown' }

    $entityRequired = @()
    $allKnown = $true
    if ($effectiveGranularity -eq 'Entity') {
        foreach ($entry in $PendingEntities) {
            $req = if ($entry.EntitySpec.PSObject.Properties.Match('RequiredGB').Count -gt 0) { $entry.EntitySpec.RequiredGB } else { $null }
            if ($null -eq $req) { $allKnown = $false } else { $entityRequired += [double]$req }
        }
    }
    $capacityGroupRequired = $null
    $capacityGroupLowerBound = $null
    if ($effectiveGranularity -eq 'CapacityGroup') {
        $cg = $PendingEntities[0].EntitySpec
        $capacityGroupRequired = if ($cg.PSObject.Properties.Match('CapacityGroupRequiredGB').Count -gt 0) { $cg.CapacityGroupRequiredGB } else { $null }
        $capacityGroupLowerBound = if ($cg.PSObject.Properties.Match('CapacityGroupKnownLowerBoundGB').Count -gt 0) { $cg.CapacityGroupKnownLowerBoundGB } else { $null }
    }

    $requirement = Resolve-BRAVODiskSpaceGroupRequirement -RequirementGranularity $effectiveGranularity `
        -EntityRequiredGB $entityRequired -AllEntityRequirementsKnown $allKnown `
        -CapacityGroupRequiredGB $capacityGroupRequired -CapacityGroupKnownLowerBoundGB $capacityGroupLowerBound `
        -AvailableGB ([double]$capacity.AvailableGB)

    $floor = $MinimumFreeSpaceGB
    $groupStatus = 'Success'
    $groupBlocks = $false
    $groupReason = $null
    $projectedFreeGB = $null

    if ($requirement.GroupRequirementState -eq 'Known') {
        $aggregated = [double]$requirement.AggregatedRequiredGB
        $available = [double]$capacity.AvailableGB
        if ($aggregated -gt $available) {
            $groupStatus = 'Error'; $groupBlocks = $true; $groupReason = 'EstimatedRequirementNotMet'
        } elseif ($available -lt $floor) {
            if ($RequirementPolicy -eq 'ArchiveNotPeakSafe') {
                $groupStatus = 'Error'; $groupBlocks = $true; $groupReason = 'BelowFloorEstimateNotPeakSafe'
            } else {
                # ArchivePeakSafe / MaintenanceExactOnly: Known тут означає
                # доведений peak-safe estimate або exact/conservative-upper-bound
                # requirement — below-floor допускається як WARNING.
                $groupStatus = 'Warning'; $groupBlocks = $false; $groupReason = 'BelowHealthFloorButRequirementSatisfied'
            }
        } else {
            $groupStatus = 'Success'; $groupBlocks = $false
        }
        if (-not $groupBlocks) {
            $projectedFreeGB = $available - $aggregated
            if ($projectedFreeGB -lt $floor -and $groupStatus -ne 'Warning') {
                $groupStatus = 'Warning'; $groupReason = 'ProjectedBelowHealthFloor'
            }
        }
    } else {
        $lowerBound = [double]$requirement.KnownRequiredLowerBoundGB
        $available = [double]$capacity.AvailableGB
        if ($lowerBound -gt $available) {
            $groupStatus = 'Error'; $groupBlocks = $true; $groupReason = 'EstimatedRequirementNotMet'
        } else {
            $residual = $requirement.ResidualAvailableGB
            if ($residual -lt $floor) {
                $groupStatus = 'Error'; $groupBlocks = $true; $groupReason = 'BelowFallbackFloorNoEstimate'
            } else {
                $groupStatus = 'Success'; $groupBlocks = $false
            }
        }
    }

    # Крок 14: ExcludedDrives operational-safety diagnostics — flag-only,
    # ніколи не скидає Blocks=true.
    $exclusionFlag = @()
    if ($groupBlocks -and -not [string]::IsNullOrWhiteSpace($drive) -and $ExcludedDrives -contains $drive) {
        $exclusionFlag = @('ExclusionIgnoredForRequiredVolume')
    }

    return @($PendingEntities | ForEach-Object {
        $r = $_.Result
        $r.CapacityState = 'Known'
        $r.AvailableGB = $capacity.AvailableGB
        $r.TotalGB = $capacity.TotalGB
        $r.MinimumGB = $floor
        $r.RequirementGranularity = $effectiveGranularity
        $r.GroupRequirementState = $requirement.GroupRequirementState
        $r.RequiredGB = if ($effectiveGranularity -eq 'Entity' -and $_.EntitySpec.PSObject.Properties.Match('RequiredGB').Count -gt 0) { $_.EntitySpec.RequiredGB } else { $null }
        $r.KnownRequiredLowerBoundGB = $requirement.KnownRequiredLowerBoundGB
        $r.AggregatedRequiredGB = $requirement.AggregatedRequiredGB
        $r.ResidualAvailableGB = $requirement.ResidualAvailableGB
        $r.ProjectedFreeGB = $projectedFreeGB
        $r.Status = $groupStatus
        $r.Blocks = $groupBlocks
        $r.Reason = $groupReason
        $r.Flags = @($r.Flags + $flagsCommon.ToArray() + $exclusionFlag)
        $r
    })
}

# ------------------------------------------------------------------
# Top-level entry point
# ------------------------------------------------------------------

function Invoke-BRAVODiskSpaceClassifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$EntitySpecs,
        [Parameter(Mandatory = $true)][double]$MinimumFreeSpaceGB,
        [string[]]$ExcludedDrives = @(),
        [Parameter(Mandatory = $true)][ValidateSet('ArchivePeakSafe', 'ArchiveNotPeakSafe', 'MaintenanceExactOnly')]
        [string]$RequirementPolicy,
        [object[]]$Drives
    )

    $entityParams = @{ ExcludedDrives = $ExcludedDrives }
    if ($PSBoundParameters.ContainsKey('Drives')) { $entityParams.Drives = $Drives }

    $terminalResults = New-Object System.Collections.Generic.List[object]
    $pendingByKey = [ordered]@{}

    foreach ($spec in $EntitySpecs) {
        $outcome = Test-BRAVODiskSpaceEntity -EntitySpec $spec @entityParams
        if ($outcome.Pending) {
            $key = [string]$outcome.Result.CapacityKey
            if (-not $pendingByKey.Contains($key)) { $pendingByKey[$key] = New-Object System.Collections.Generic.List[object] }
            [void]$pendingByKey[$key].Add($outcome)
        } else {
            # Крок 14 (застосовується і до термінальних phase-1 BLOCK, коли є
            # стабільна локальна drive identity).
            if ([bool]$outcome.Result.Blocks -and -not [string]::IsNullOrWhiteSpace($outcome.Result.Drive) -and $ExcludedDrives -contains $outcome.Result.Drive) {
                $outcome.Result.Flags = @($outcome.Result.Flags + @('ExclusionIgnoredForRequiredVolume'))
            }
            [void]$terminalResults.Add($outcome.Result)
        }
    }

    $groupParams = @{ MinimumFreeSpaceGB = $MinimumFreeSpaceGB; ExcludedDrives = $ExcludedDrives; RequirementPolicy = $RequirementPolicy }
    if ($PSBoundParameters.ContainsKey('Drives')) { $groupParams.Drives = $Drives }

    $allResults = New-Object System.Collections.Generic.List[object]
    foreach ($r in $terminalResults) { [void]$allResults.Add($r) }
    foreach ($key in $pendingByKey.Keys) {
        # ПРИМІТКА: навмисно $pendingByKey[$key].ToArray(), НЕ @($pendingByKey[$key]) —
        # на цій збірці Windows PowerShell 5.1 (5.1.26100.9168) обгортання @()
        # навколо "голого" System.Collections.Generic.List[object] інколи
        # кидає "Argument types do not match" (відтворено експериментально:
        # @() навколо List[object] з одним pscustomobject/int теж падає,
        # тоді як [object[]]$list або $list.ToArray() працюють коректно).
        # .ToArray() — детермінований, задокументований спосіб конвертації.
        $groupResults = Resolve-BRAVODiskSpaceGroupDecision -PendingEntities $pendingByKey[$key].ToArray() @groupParams
        foreach ($r in $groupResults) { [void]$allResults.Add($r) }
    }

    $resultsArray = $allResults.ToArray()
    $blocking = @($resultsArray | Where-Object { [bool]$_.Blocks })
    $warnings = @($resultsArray | Where-Object { -not [bool]$_.Blocks -and $_.Status -eq 'Warning' })

    return [pscustomobject]@{
        Success  = ($blocking.Count -eq 0)
        Blocks   = ($blocking.Count -gt 0)
        Results  = $resultsArray
        Problems = @(Group-BRAVODiskSpaceMessagesByCapacityKey -Entities $blocking)
        Warnings = @(Group-BRAVODiskSpaceMessagesByCapacityKey -Entities $warnings)
    }
}

function Group-BRAVODiskSpaceMessagesByCapacityKey {
    # §51.1: спільний blocking/warning condition для кількох paths ОДНОГО
    # CapacityKey повідомляється ОДИН раз на capacity resource, з
    # переліком задіяних DisplayPath — не дублюється як окреме
    # повідомлення для кожного path. Entities без CapacityKey (напр.
    # термінальна VolumeResolutionFailed для SFTP без визначеної identity)
    # групуються по DisplayPath — кожен лишається окремим повідомленням.
    param([object[]]$Entities)

    $groups = [ordered]@{}
    foreach ($entity in $Entities) {
        $key = if ([string]::IsNullOrWhiteSpace([string]$entity.CapacityKey)) {
            "path:$($entity.DisplayPath)"
        } else {
            "key:$($entity.CapacityKey)"
        }
        if (-not $groups.Contains($key)) {
            $groups[$key] = [pscustomobject]@{ Reason = $entity.Reason; Paths = New-Object System.Collections.Generic.List[string] }
        }
        [void]$groups[$key].Paths.Add([string]$entity.DisplayPath)
    }

    $messages = New-Object System.Collections.Generic.List[string]
    foreach ($key in $groups.Keys) {
        $group = $groups[$key]
        $pathsText = ($group.Paths.ToArray() | Select-Object -Unique) -join ', '
        [void]$messages.Add("${pathsText}: $($group.Reason)")
    }
    return $messages.ToArray()
}

# ------------------------------------------------------------------
# §58 — структурований лог рішення
# ------------------------------------------------------------------

function Write-BRAVODiskSpaceDecisionLog {
    # -Logger: scriptblock, що приймає один рядок тексту (напр. обгортка
    # навколо Write-BRAVOLog у Archive/Maintenance). За замовчуванням —
    # Write-Verbose, щоб модуль не мав жорсткої залежності від BRAVO.Logging.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Results,
        [scriptblock]$Logger = { param($line) Write-Verbose $line }
    )

    foreach ($r in $Results) {
        $flagsText = if ($r.Flags.Count -gt 0) { ($r.Flags -join ',') } else { '-' }
        $line = "DiskSpace StorageKind=$($r.StorageKind) CapacityKey=$($r.CapacityKey) Drive=$($r.Drive) " +
            "DisplayPath=$($r.DisplayPath) Roles=$($r.Roles -join ',') Participates=$($r.Participates) " +
            "RequiresAccess=$($r.RequiresAccess) RequiresFreeSpace=$($r.RequiresFreeSpace) " +
            "AccessStatus=$($r.AccessStatus) CapacityState=$($r.CapacityState) " +
            "RequirementGranularity=$($r.RequirementGranularity) GroupRequirementState=$($r.GroupRequirementState) " +
            "AvailableGB=$($r.AvailableGB) RequiredGB=$($r.RequiredGB) " +
            "KnownRequiredLowerBoundGB=$($r.KnownRequiredLowerBoundGB) AggregatedRequiredGB=$($r.AggregatedRequiredGB) " +
            "ResidualAvailableGB=$($r.ResidualAvailableGB) ProjectedFreeGB=$($r.ProjectedFreeGB) " +
            "Status=$($r.Status) Blocks=$($r.Blocks) Reason=$($r.Reason) Flags=$flagsText"
        & $Logger $line
    }
}

Export-ModuleMember -Function @(
    'New-BRAVODiskSpaceResult',
    'Resolve-BRAVODiskSpaceStorageIdentity',
    'Get-BRAVODiskSpaceAccessState',
    'Get-BRAVODiskSpaceCapacityObservation',
    'Resolve-BRAVODiskSpaceGroupRequirement',
    'Test-BRAVODiskSpaceEntity',
    'Resolve-BRAVODiskSpaceGroupDecision',
    'Invoke-BRAVODiskSpaceClassifier',
    'Write-BRAVODiskSpaceDecisionLog'
)
