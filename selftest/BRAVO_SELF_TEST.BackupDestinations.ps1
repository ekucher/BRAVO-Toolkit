# ============================================================
# BackupDestinations: куди копіювати резервні копії (#282, хвиля 2)
# ============================================================
# Рішення власника (дизайн «Резервне копіювання лише того, що є, і лише
# туди, куди дозволено», розділи 4-6):
#   * чотири профілі напрямків відповідають топологіям наявних пресетів
#     Configurator і пишуть лише наявні прапорці
#     (Get-BRAVOConfiguratorBackupDestinationProfile); дефолти нової
#     інсталяції дорівнюють дефолтам конфігурації, крім вимикачів напрямків
#     (BAZA_*_SFTP профіль не чіпає: BAZA_WWW_SFTP вмикається свідомо);
#   * профіль застосовує лише інсталятор і лише до НОВОГО BRAVO.local.config;
#   * свідомо вимкнений напрямок у Health — один INFO-рядок, без WARNING;
#   * «Лише локально» охоплює дані й журнали: жоден автоматичний прогін не
#     відкриває SFTP/SMB-канал повз canonical storageEffective
#     (сторож вихідних каналів нижче). Сповіщення, Operations і запит
#     публічної IP навмисно поза цим обсягом.

$bdConfiguratorRoot = Join-Path $root 'modules\BRAVO.Configurator'
Import-Module -Name (Join-Path $root 'modules\BRAVO.Discovery\BRAVO.Discovery.psd1') -ErrorAction Stop
Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Derivation.psd1') -ErrorAction Stop
Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Schema.psd1') -ErrorAction Stop
foreach ($bdModuleName in @('BRAVO.Configurator.Effective', 'BRAVO.Configurator.Model', 'BRAVO.Configurator.Persistence', 'BRAVO.Configurator.Presets')) {
    Import-Module -Name (Join-Path $bdConfiguratorRoot ($bdModuleName + '.psm1')) -Force -ErrorAction Stop
}

function ConvertTo-BRAVOSelfTestDestinationText {
    # Детермінований текст набору override-значень для порівняння й діагностики.
    param([System.Collections.IDictionary]$Overrides)
    return (@($Overrides.Keys | Sort-Object | ForEach-Object { "$_=$([string]$Overrides[$_])" }) -join '; ')
}

# ------------------------------------------------------------
# (1) Профіль -> точний набір прапорців.
# ------------------------------------------------------------
$bdExpectedProfiles = [ordered]@{
    Cloud = @{
        PresetName = 'LocalPlusSFTP'
        Overrides = @{
            'componentSettings.SFTP.Enabled' = $true
            'componentSettings.SMB.Enabled' = $false
        }
    }
    CloudAndSamba = @{
        PresetName = 'LocalPlusSFTPAndSMB'
        Overrides = @{
            'componentSettings.SFTP.Enabled' = $true
            'componentSettings.SMB.Enabled' = $true
            'componentSettings.SMB.ArchiveCopy' = $true
        }
    }
    SambaOnly = @{
        PresetName = 'LocalPlusSMB'
        Overrides = @{
            'componentSettings.SFTP.Enabled' = $false
            'componentSettings.SMB.Enabled' = $true
            'componentSettings.SMB.ArchiveCopy' = $true
            'componentSettings.Synchronization.BAZA_APP_LOCAL' = $true
            'componentSettings.Synchronization.BAZA_WWW_LOCAL' = $true
        }
    }
    LocalOnly = @{
        PresetName = 'LocalOnly'
        Overrides = @{
            'componentSettings.SFTP.Enabled' = $false
            'componentSettings.SMB.Enabled' = $false
            'componentSettings.Synchronization.BAZA_APP_LOCAL' = $true
            'componentSettings.Synchronization.BAZA_WWW_LOCAL' = $true
        }
    }
}
$bdProfiles = @{}
foreach ($bdDestination in @($bdExpectedProfiles.Keys)) {
    $bdProfile = Get-BRAVOConfiguratorBackupDestinationProfile -Destination $bdDestination
    $bdProfiles[$bdDestination] = $bdProfile
    $bdExpected = $bdExpectedProfiles[$bdDestination]
    $bdActualText = ConvertTo-BRAVOSelfTestDestinationText -Overrides $bdProfile.Overrides
    $bdExpectedText = ConvertTo-BRAVOSelfTestDestinationText -Overrides $bdExpected.Overrides
    Test-BRAVOCondition -Condition (
        [string]$bdProfile.PresetName -eq [string]$bdExpected.PresetName -and
        $bdActualText -ceq $bdExpectedText -and
        @($bdProfile.Overrides.Values | Where-Object { $_ -isnot [bool] }).Count -eq 0
    ) -Name "BackupDestinations/Profile${bdDestination}WritesExactFlags" `
        -Failure "профіль $bdDestination має відповідати preset $($bdExpected.PresetName) і писати рівно: $bdExpectedText; фактично preset=$($bdProfile.PresetName): $bdActualText"
}

# Профіль має ту саму топологію, що й відповідний preset Configurator
# (master-вимикачі SFTP/SMB збігаються), але свідомо не пише BAZA_*_SFTP:
# ці прапорці лишаються на конфігураційних дефолтах (рішення власника).
$bdPresetSubsetMismatches = @()
foreach ($bdDestination in @($bdExpectedProfiles.Keys)) {
    $bdPresetSet = Get-BRAVOConfiguratorPresetOverrideSet -PresetName ([string]$bdProfiles[$bdDestination].PresetName)
    foreach ($bdPath in @('componentSettings.SFTP.Enabled', 'componentSettings.SMB.Enabled')) {
        if (-not $bdProfiles[$bdDestination].Overrides.Contains($bdPath) -or
            $bdProfiles[$bdDestination].Overrides[$bdPath] -ne $bdPresetSet[$bdPath]) {
            $bdPresetSubsetMismatches += "$bdDestination/$bdPath"
        }
    }
    foreach ($bdPath in @($bdProfiles[$bdDestination].Overrides.Keys)) {
        if ($bdPath -match '\.BAZA_(APP|WWW)_SFTP$') {
            $bdPresetSubsetMismatches += "$bdDestination/$bdPath (BAZA SFTP не входить у профіль)"
        }
    }
}
$bdPresetChildFlags = @()
foreach ($bdPresetName in @('LocalOnly', 'LocalPlusSMB', 'LocalPlusSFTP', 'LocalPlusSFTPAndSMB', 'Current', 'Manual')) {
    $bdPresetChildFlags += @(@((Get-BRAVOConfiguratorPresetOverrideSet -PresetName $bdPresetName).Keys) |
        Where-Object { $_ -match '\.(ArchiveUpload|ArchiveCopy)$' } | ForEach-Object { "$bdPresetName/$_" })
}
Test-BRAVOCondition -Condition (
    $bdPresetSubsetMismatches.Count -eq 0 -and
    $bdPresetChildFlags.Count -eq 0 -and
    (Get-BRAVOConfiguratorPresetOverrideSet -PresetName 'Current').Count -eq 0 -and
    (Get-BRAVOConfiguratorPresetOverrideSet -PresetName 'Manual').Count -eq 0
) -Name 'BackupDestinations/ProfilesMatchPresetTopology' `
    -Failure "профіль має збігатися з preset-ом за master-вимикачами SFTP/SMB і не писати BAZA_*_SFTP, а preset Configurator не торкається ArchiveUpload/ArchiveCopy; розбіжності: $($bdPresetSubsetMismatches -join ', '); дочірні прапорці в preset: $($bdPresetChildFlags -join ', ')"

# Invoke-BRAVOConfiguratorPreset застосовує саме канонічний набір (той
# самий контракт після винесення таблиці в Get-BRAVOConfiguratorPresetOverrideSet).
$bdModelPaths = @(
    'componentSettings.SFTP.Enabled', 'componentSettings.SFTP.ArchiveUpload',
    'componentSettings.SMB.Enabled', 'componentSettings.SMB.ArchiveCopy',
    'componentSettings.Synchronization.BAZA_APP_LOCAL', 'componentSettings.Synchronization.BAZA_APP_SFTP',
    'componentSettings.Synchronization.BAZA_WWW_LOCAL', 'componentSettings.Synchronization.BAZA_WWW_SFTP',
    'consoleSettings.ConsoleLevel'
)
$bdBaseModel = @($bdModelPaths | ForEach-Object {
    [pscustomobject]@{
        Path = $_; Metadata = $null; DefaultValue = $null
        OverridePresent = $false; OverrideValue = $null
        EffectiveValue = $null; EffectiveSource = $null; DisabledReason = $null
        ValidationState = $null; DependencyState = $null; Dirty = $false
    }
})
$bdBaseModel = Set-BRAVOConfiguratorOverride -Model $bdBaseModel -Path 'componentSettings.SMB.ArchiveCopy' -Value $false
$bdBaseModel = Set-BRAVOConfiguratorOverride -Model $bdBaseModel -Path 'consoleSettings.ConsoleLevel' -Value 'ERROR'
$bdPresetModelMismatches = @()
foreach ($bdPresetName in @('LocalOnly', 'LocalPlusSMB', 'LocalPlusSFTP', 'LocalPlusSFTPAndSMB', 'Current', 'Manual')) {
    $bdPresetSet = Get-BRAVOConfiguratorPresetOverrideSet -PresetName $bdPresetName
    $bdPresetModel = @(Invoke-BRAVOConfiguratorPreset -Model $bdBaseModel -PresetName $bdPresetName)
    foreach ($bdSetting in $bdPresetModel) {
        $bdBaseSetting = @($bdBaseModel | Where-Object { $_.Path -eq $bdSetting.Path })[0]
        if ($bdPresetSet.Contains($bdSetting.Path)) {
            if (-not $bdSetting.OverridePresent -or $bdSetting.OverrideValue -ne $bdPresetSet[$bdSetting.Path]) {
                $bdPresetModelMismatches += "$bdPresetName/$($bdSetting.Path)"
            }
        } elseif ($bdSetting.OverridePresent -ne $bdBaseSetting.OverridePresent -or
            [string]$bdSetting.OverrideValue -ne [string]$bdBaseSetting.OverrideValue) {
            $bdPresetModelMismatches += "$bdPresetName/$($bdSetting.Path) (зайва зміна)"
        }
    }
}
Test-BRAVOCondition -Condition ($bdPresetModelMismatches.Count -eq 0) `
    -Name 'BackupDestinations/PresetAppliesCanonicalOverrideSet' `
    -Failure "Invoke-BRAVOConfiguratorPreset має виставляти рівно набір Get-BRAVOConfiguratorPresetOverrideSet і не чіпати решту (зокрема SMB.ArchiveCopy і consoleSettings); розбіжності: $($bdPresetModelMismatches -join ', ')"

# Кожен ключ профілю — канонічний лист, який дозволено перевизначати в
# BRAVO.local.config (ALLOW_SITE), інакше loader відхилив би новий файл.
$bdAuthorizationClass = Get-BRAVOConfigurationSchemaAuthorizationClass
$bdNotAllowedKeys = @()
foreach ($bdDestination in @($bdProfiles.Keys)) {
    foreach ($bdPath in @($bdProfiles[$bdDestination].Overrides.Keys)) {
        $bdEntry = $bdAuthorizationClass[$bdPath]
        if ($null -eq $bdEntry -or [string]$bdEntry.Class -ne 'ALLOW_SITE') {
            $bdNotAllowedKeys += "$bdDestination/$bdPath"
        }
    }
}
Test-BRAVOCondition -Condition ($bdNotAllowedKeys.Count -eq 0) `
    -Name 'BackupDestinations/ProfileKeysAreSiteOverridable' `
    -Failure "ключі профілю мають бути ALLOW_SITE у реєстрі авторизації: $($bdNotAllowedKeys -join ', ')"

# ------------------------------------------------------------
# (2) Ефективна поведінка профілів через канонічні функції. Доказ, чому
# профілі з Samba пишуть SMB.ArchiveCopy: SMB.Enabled сам по собі (дефолт
# ArchiveCopy = $false) не копіює нічого.
# ------------------------------------------------------------
$bdSmbEnabledOnly = Get-BRAVOEffectiveStorageConfiguration -ComponentSettings @{
    SFTP = @{ Enabled = $true; ArchiveUpload = $true }
    SMB = @{ Enabled = $true; ArchiveCopy = $false }
}
Test-BRAVOCondition -Condition (
    [bool]$bdSmbEnabledOnly.SMB.Enabled -and -not [bool]$bdSmbEnabledOnly.SMB.ArchiveCopy
) -Name 'BackupDestinations/SmbEnabledWithoutArchiveCopyCopiesNothing' `
    -Failure 'контроль: SMB.Enabled=$true при ArchiveCopy=$false не має давати копіювання на NAS (саме тому профілі Samba пишуть ArchiveCopy=$true)'

$bdEffectiveMismatches = @()
foreach ($bdDestination in @($bdProfiles.Keys)) {
    $bdOverrides = $bdProfiles[$bdDestination].Overrides
    # Дефолти комплекту (BRAVO.Configuration): ArchiveUpload=$true, ArchiveCopy=$false,
    # BAZA_APP_SFTP=$true, решта BAZA=$false. Профіль накладається поверх.
    $bdSettings = @{
        SFTP = @{ Enabled = $true; ArchiveUpload = $true }
        SMB = @{ Enabled = $true; ArchiveCopy = $false }
    }
    $bdSync = @{ BAZA_APP_LOCAL = $false; BAZA_APP_SFTP = $true; BAZA_WWW_LOCAL = $false; BAZA_WWW_SFTP = $false }
    foreach ($bdPath in @($bdOverrides.Keys)) {
        $bdSegments = $bdPath.Split('.')
        if ($bdSegments[1] -eq 'Synchronization') { $bdSync[$bdSegments[2]] = $bdOverrides[$bdPath] }
        else { $bdSettings[$bdSegments[1]][$bdSegments[2]] = $bdOverrides[$bdPath] }
    }
    $bdStorage = Get-BRAVOEffectiveStorageConfiguration -ComponentSettings $bdSettings
    $bdBaza = Get-BRAVOEffectiveSynchronizationConfiguration -Synchronization $bdSync `
        -GlobalSftpEnabled ([bool]$bdStorage.SFTP.Enabled)
    $bdExpectSftp = @('Cloud', 'CloudAndSamba') -contains $bdDestination
    $bdExpectSmb = @('CloudAndSamba', 'SambaOnly') -contains $bdDestination
    # Профілі з SFTP лишають BAZA на дефолтах комплекту: BAZA_WWW без
    # каналу — дефолт (BAZA_WWW_SFTP вмикається свідомо). Профілі без SFTP
    # мають тримати кожен BAZA-компонент хоча б локально.
    $bdAllowedWithoutChannel = @()
    if ($bdExpectSftp) { $bdAllowedWithoutChannel = @('BAZA_WWW') }
    $bdBazaWithoutChannel = @($bdBaza.Components | Where-Object { -not [bool]$_.AnyEnabled } | ForEach-Object { $_.Name } |
        Where-Object { $bdAllowedWithoutChannel -notcontains $_ })
    if ([bool]$bdStorage.SFTP.Enabled -ne $bdExpectSftp -or [bool]$bdStorage.SFTP.ArchiveUpload -ne $bdExpectSftp -or
        [bool]$bdStorage.SMB.Enabled -ne $bdExpectSmb -or [bool]$bdStorage.SMB.ArchiveCopy -ne $bdExpectSmb -or
        [bool]$bdBaza.ScheduledSftpSyncRequired -ne $bdExpectSftp -or $bdBazaWithoutChannel.Count -gt 0) {
        $bdEffectiveMismatches += ("$bdDestination (SFTP=$($bdStorage.SFTP.Enabled)/$($bdStorage.SFTP.ArchiveUpload) " +
            "SMB=$($bdStorage.SMB.Enabled)/$($bdStorage.SMB.ArchiveCopy) BAZA SFTP=$($bdBaza.ScheduledSftpSyncRequired) " +
            "BAZA без каналу: $($bdBazaWithoutChannel -join ','))")
    }
}
Test-BRAVOCondition -Condition ($bdEffectiveMismatches.Count -eq 0) `
    -Name 'BackupDestinations/ProfilesYieldExpectedEffectiveDestinations' `
    -Failure "ефективні напрямки профілів (Хмара: лише SFTP; Хмара + Samba: SFTP і копія NAS; Лише Samba: лише копія NAS; Лише локально: нічого) і жодного BAZA-компонента без каналу (крім дефолтного BAZA_WWW у профілях з SFTP): $($bdEffectiveMismatches -join ' | ')"

# ------------------------------------------------------------
# (2a) Відповідність профілю за ЕФЕКТИВНИМИ значеннями (#434):
# Test-BRAVOConfiguratorBackupDestinationEffective порівнює головні вимикачі
# канонічного Get-BRAVOEffectiveStorageConfiguration з профілем. Результат
# профілю сам із собою — Compliant; дефолти (SFTP і SMB увімкнені) для
# LocalOnly — ні, з обома каналами; відсутні ефективні значення — ні.
# ------------------------------------------------------------
Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.psd1') -ErrorAction Stop
$bdEffectiveCheckFailures = @()
$bdDestinationNames = @($bdExpectedProfiles.Keys)
foreach ($bdDestination in $bdDestinationNames) {
    $bdOwnMerged = Resolve-BRAVORawConfiguration -DefaultConfiguration (Get-BRAVODefaultConfiguration) `
        -PrimaryOverrides $null -LocalOverrides $bdProfiles[$bdDestination].Overrides
    $bdOwnStorage = Get-BRAVOEffectiveStorageConfiguration -ComponentSettings $bdOwnMerged['componentSettings']
    foreach ($bdCandidate in $bdDestinationNames) {
        $bdCheck = Test-BRAVOConfiguratorBackupDestinationEffective -Destination $bdCandidate -EffectiveStorage $bdOwnStorage
        $bdCandidateOverrides = $bdProfiles[$bdCandidate].Overrides
        $bdOwnOverrides = $bdProfiles[$bdDestination].Overrides
        $bdShouldMatch = ([bool]$bdCandidateOverrides['componentSettings.SFTP.Enabled'] -eq [bool]$bdOwnOverrides['componentSettings.SFTP.Enabled']) -and
            ([bool]$bdCandidateOverrides['componentSettings.SMB.Enabled'] -eq [bool]$bdOwnOverrides['componentSettings.SMB.Enabled'])
        if ([bool]$bdCheck.Compliant -ne $bdShouldMatch -or ($bdShouldMatch -and @($bdCheck.ConflictingChannels).Count -ne 0)) {
            $bdEffectiveCheckFailures += "$bdCandidate проти ефективних значень $bdDestination : Compliant=$($bdCheck.Compliant) конфлікти=$(@($bdCheck.ConflictingChannels) -join ',')"
        }
    }
}
$bdDefaultStorage = Get-BRAVOEffectiveStorageConfiguration -ComponentSettings (Get-BRAVODefaultConfiguration)['componentSettings']
$bdDefaultCheck = Test-BRAVOConfiguratorBackupDestinationEffective -Destination 'LocalOnly' -EffectiveStorage $bdDefaultStorage
if ([bool]$bdDefaultCheck.Compliant -or (@($bdDefaultCheck.ConflictingChannels) -join ',') -ne 'SFTP,SMB' -or
    (@($bdDefaultCheck.Reasons) -join ' ') -notmatch '[\u0400-\u04FF]') {
    $bdEffectiveCheckFailures += "LocalOnly проти дефолтів: Compliant=$($bdDefaultCheck.Compliant) конфлікти=$(@($bdDefaultCheck.ConflictingChannels) -join ',') причини=$(@($bdDefaultCheck.Reasons) -join ' ')"
}
$bdNullCheck = Test-BRAVOConfiguratorBackupDestinationEffective -Destination 'LocalOnly' -EffectiveStorage $null
if ([bool]$bdNullCheck.Compliant) { $bdEffectiveCheckFailures += 'LocalOnly без ефективних значень визнано Compliant' }
Test-BRAVOCondition -Condition ($bdEffectiveCheckFailures.Count -eq 0) `
    -Name 'BackupDestinations/EffectiveDestinationCheckMatchesProfiles' `
    -Failure "Test-BRAVOConfiguratorBackupDestinationEffective має визнавати відповідність профілю лише за ефективними SFTP.Enabled/SMB.Enabled і fail-closed без ефективних значень: $($bdEffectiveCheckFailures -join ' | ')"

# (2b) Codex P1: SFTP.Enabled = $true сам по собі не вивантажує архів.
# Профіль із хмарою (Cloud/CloudAndSamba) «в силі» лише тоді, коли ефективний
# SFTP.ArchiveUpload той самий, що дав би свіжий seed профілю (seed його не
# пише -> дефолт BRAVO.Configuration). Для профілів без SFTP (SambaOnly,
# LocalOnly) ArchiveUpload нічого не змінює — жодних хибних відмов.
$bdUploadFailures = @()
foreach ($bdDestination in $bdDestinationNames) {
    $bdUploadOverrides = @{}
    foreach ($bdOverrideKey in @($bdProfiles[$bdDestination].Overrides.Keys)) { $bdUploadOverrides[$bdOverrideKey] = $bdProfiles[$bdDestination].Overrides[$bdOverrideKey] }
    $bdUploadOverrides['componentSettings.SFTP.ArchiveUpload'] = $false
    $bdUploadMerged = Resolve-BRAVORawConfiguration -DefaultConfiguration (Get-BRAVODefaultConfiguration) `
        -PrimaryOverrides $null -LocalOverrides $bdUploadOverrides
    $bdUploadStorage = Get-BRAVOEffectiveStorageConfiguration -ComponentSettings $bdUploadMerged['componentSettings']
    $bdUploadCheck = Test-BRAVOConfiguratorBackupDestinationEffective -Destination $bdDestination -EffectiveStorage $bdUploadStorage
    $bdUploadExpectSftp = [bool]$bdProfiles[$bdDestination].Overrides['componentSettings.SFTP.Enabled']
    if ($bdUploadExpectSftp) {
        if (-not [bool]$bdUploadStorage.SFTP.Enabled -or [bool]$bdUploadStorage.SFTP.ArchiveUpload) {
            $bdUploadFailures += "$bdDestination фікстура: SFTP.Enabled=$($bdUploadStorage.SFTP.Enabled) ArchiveUpload=$($bdUploadStorage.SFTP.ArchiveUpload)"
        }
        if ([bool]$bdUploadCheck.Compliant -or (@($bdUploadCheck.ConflictingChannels) -join ',') -ne 'SFTP' -or
            (@($bdUploadCheck.Reasons) -join ' ') -notmatch 'ArchiveUpload' -or (@($bdUploadCheck.Reasons) -join ' ') -notmatch '[Ѐ-ӿ]') {
            $bdUploadFailures += "$bdDestination з ArchiveUpload=`$false: Compliant=$($bdUploadCheck.Compliant) конфлікти=$(@($bdUploadCheck.ConflictingChannels) -join ',') причини=$(@($bdUploadCheck.Reasons) -join ' ')"
        }
    } elseif (-not [bool]$bdUploadCheck.Compliant -or @($bdUploadCheck.ConflictingChannels).Count -ne 0) {
        $bdUploadFailures += "$bdDestination (SFTP вимкнено) з ArchiveUpload=`$false хибно відхилено: конфлікти=$(@($bdUploadCheck.ConflictingChannels) -join ',') причини=$(@($bdUploadCheck.Reasons) -join ' ')"
    }
}
Test-BRAVOCondition -Condition ($bdUploadFailures.Count -eq 0) `
    -Name 'BackupDestinations/EffectiveDestinationCheckComparesArchiveUpload' `
    -Failure "Test-BRAVOConfiguratorBackupDestinationEffective: Cloud/CloudAndSamba при SFTP.Enabled=`$true, але ефективному SFTP.ArchiveUpload=`$false не «в силі» (канал SFTP, причина з ArchiveUpload); SambaOnly/LocalOnly від ArchiveUpload не залежать: $($bdUploadFailures -join ' | ')"

# ------------------------------------------------------------
# (3) Запис нового BRAVO.local.config канонічним кодом Configurator.
# ------------------------------------------------------------
function Read-BRAVOSelfTestDestinationOverrides {
    # Канонічний reader site-файлу. Loader dot-source-иться в області цієї
    # функції, щоб його функції не перекривали заглушки інших розділів.
    param([string]$ConfigDirectory)
    . (Join-Path $root 'BRAVO_CONFIG_LOADER.ps1')
    return Read-BRAVOLocalConfigurationOverrides -ConfigDirectory $ConfigDirectory -RuntimeRoot $root
}
$bdSeedRoot = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_SELFTEST_DEST_SEED_' + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $bdSeedRoot -Force)
    $bdSeed = New-BRAVOConfiguratorSeedLocalConfig -RuntimeRoot $root -ConfigDirectory $bdSeedRoot `
        -Overrides $bdProfiles['SambaOnly'].Overrides
    $bdSeedRead = Read-BRAVOSelfTestDestinationOverrides -ConfigDirectory $bdSeedRoot
    $bdSeedReadText = ConvertTo-BRAVOSelfTestDestinationText -Overrides $bdSeedRead.Overrides
    $bdSeedPath = Join-Path $bdSeedRoot 'BRAVO.local.config'
    $bdSeedBytesBefore = [IO.File]::ReadAllBytes($bdSeedPath)
    $bdSeedAgain = New-BRAVOConfiguratorSeedLocalConfig -RuntimeRoot $root -ConfigDirectory $bdSeedRoot `
        -Overrides $bdProfiles['LocalOnly'].Overrides
    $bdSeedBytesAfter = [IO.File]::ReadAllBytes($bdSeedPath)
    Test-BRAVOCondition -Condition (
        [bool]$bdSeed.Created -and [string]$bdSeed.Stage -eq 'Complete' -and
        [bool]$bdSeedRead.Present -and [bool]$bdSeedRead.SchemaVersionWasDeclared -and
        $bdSeedReadText -ceq (ConvertTo-BRAVOSelfTestDestinationText -Overrides $bdProfiles['SambaOnly'].Overrides) -and
        -not [bool]$bdSeedAgain.Created -and [string]$bdSeedAgain.Stage -eq 'Exists' -and
        [Convert]::ToBase64String($bdSeedBytesBefore) -ceq [Convert]::ToBase64String($bdSeedBytesAfter) -and
        @(Get-ChildItem -LiteralPath $bdSeedRoot -Force | Where-Object { $_.Name -ne 'BRAVO.local.config' }).Count -eq 0
    ) -Name 'BackupDestinations/SeedWritesProfileAndNeverOverwrites' `
        -Failure "New-BRAVOConfiguratorSeedLocalConfig має створити версійований файл рівно з профілем (канонічний reader читає його назад), а повторний виклик не змінює наявний файл і не лишає тимчасових файлів; created=$($bdSeed.Created)/$($bdSeed.Stage) read=$bdSeedReadText again=$($bdSeedAgain.Stage)"
} finally {
    if (Test-Path -LiteralPath $bdSeedRoot) {
        Remove-Item -LiteralPath $bdSeedRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Фікстура комплекту (#434, Codex P1): RUNTIME_MANIFEST.json над усіма
# .ps1/.psm1/.psd1 каталогу у форматі, який читає канонічний
# Test-BRAVORuntimeManifestIntegrity (BRAVO_RUNTIME_GUARD.ps1): ключ —
# відносний шлях із роздільником платформи, значення — SHA-256. Інсталятор
# перевіряє цілісність комплекту до першого імпорту його коду, тож фікстура
# має бути цілісною, як справжній комплект.
function Write-BRAVOSelfTestBundleManifest {
    param([string]$BundleRoot)
    $prefixLength = $BundleRoot.TrimEnd('\', '/').Length + 1
    $manifestFiles = [ordered]@{}
    foreach ($manifestFile in @([IO.Directory]::GetFiles($BundleRoot, '*', [IO.SearchOption]::AllDirectories) | Sort-Object)) {
        if (@('.ps1', '.psm1', '.psd1') -notcontains [IO.Path]::GetExtension($manifestFile).ToLowerInvariant()) { continue }
        $manifestFiles[$manifestFile.Substring($prefixLength)] = (Get-FileHash -LiteralPath $manifestFile -Algorithm SHA256).Hash
    }
    [IO.File]::WriteAllText((Join-Path $BundleRoot 'RUNTIME_MANIFEST.json'),
        (@{ files = $manifestFiles } | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false)))
}

# ------------------------------------------------------------
# (4) Install-BRAVOServer.ps1, крок 4: реальний блок інсталятора в окремому
# процесі на тимчасовому RuntimeRoot (крок цілком, без UAC/robocopy/гейтів).
# ------------------------------------------------------------
$bdInstallText = [IO.File]::ReadAllText((Join-Path $root 'deploy\Install-BRAVOServer.ps1'), [Text.Encoding]::UTF8)
$bdStepStart = $bdInstallText.IndexOf('$localConfig = Join-Path $RuntimeRoot ''BRAVO.local.config''')
$bdStepEnd = $bdInstallText.IndexOf('Write-Note ''BRAVO.config з комплекту не редагується')
$bdStepText = $(if ($bdStepStart -ge 0 -and $bdStepEnd -gt $bdStepStart) { $bdInstallText.Substring($bdStepStart, $bdStepEnd - $bdStepStart) } else { '' })
$bdInstallTokens = $null
$bdInstallErrors = $null
$bdInstallAst = [Management.Automation.Language.Parser]::ParseInput($bdInstallText, [ref]$bdInstallTokens, [ref]$bdInstallErrors)
# Єдиний запис site-файлу в інсталяторі — New-BRAVOConfiguratorSeedLocalConfig;
# жодна інша команда не пише в $localConfig (Set-Content тощо). Виняток —
# рівно одна копія прикладу у формі developer: зворотно сумісний неявний
# -SeedLocalConfig для комплекту без BRAVO.Configurator (#434, P1-1; рішення
# власника), поведінково закріплена в (4c).
$bdInstallWriteNodes = @($bdInstallAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    @('Copy-Item', 'Move-Item', 'Set-Content', 'Add-Content', 'Out-File', 'New-Item') -contains [string]$node.GetCommandName() -and
    $node.Extent.Text -match '(?i)\$localConfig\b|BRAVO\.local\.config'''
}, $true))
$bdInstallLegacyExampleCopies = @($bdInstallWriteNodes | Where-Object {
    $_.Extent.Text -ceq 'Copy-Item -LiteralPath $localExample -Destination $localConfig'
})
$bdInstallWrites = @($bdInstallWriteNodes | Where-Object {
    $bdInstallLegacyExampleCopies.Count -gt 1 -or
    $_.Extent.Text -cne 'Copy-Item -LiteralPath $localExample -Destination $localConfig'
})
$bdInstallParam = @($bdInstallAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'BackupDestination' })
$bdInstallValidateSet = @($(if ($bdInstallParam.Count -eq 1) {
    @($bdInstallParam[0].Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' } |
        ForEach-Object { $_.PositionalArguments | ForEach-Object { $_.Value } })
}))
Test-BRAVOCondition -Condition (
    -not [string]::IsNullOrWhiteSpace($bdStepText) -and
    $bdInstallWrites.Count -eq 0 -and
    $bdInstallParam.Count -eq 1 -and
    [string]$bdInstallParam[0].DefaultValue.Extent.Text -eq "'Cloud'" -and
    (@($bdInstallValidateSet | Sort-Object) -join ',') -eq 'Cloud,CloudAndSamba,LocalOnly,SambaOnly' -and
    $bdInstallText.Contains("if (`$PSBoundParameters.ContainsKey('BackupDestination')) {") -and
    $bdStepText.Contains('New-BRAVOConfiguratorSeedLocalConfig') -and
    $bdStepText.Contains('Get-BRAVOConfiguratorBackupDestinationProfile')
) -Name 'BackupDestinations/InstallerUsesCanonicalWriterOnly' `
    -Failure "Install-BRAVOServer.ps1: -BackupDestination (ValidateSet Cloud/CloudAndSamba/SambaOnly/LocalOnly, дефолт Cloud) передається в елевований перезапуск лише явно заданим, а BRAVO.local.config пише лише канонічний New-BRAVOConfiguratorSeedLocalConfig; інші записи: $(@($bdInstallWrites | ForEach-Object { $_.Extent.Text }) -join ' | ')"

$bdInstallRoot = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_SELFTEST_DEST_INSTALL_' + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $bdInstallRoot 'modules') -Force)
    foreach ($bdModuleDirectory in @('BRAVO.Compatibility', 'BRAVO.Configurator', 'BRAVO.Configuration', 'BRAVO.Discovery', 'BRAVO.System')) {
        Copy-Item -LiteralPath (Join-Path $root ('modules\' + $bdModuleDirectory)) `
            -Destination (Join-Path $bdInstallRoot 'modules') -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $root 'BRAVO_CONFIG_LOADER.ps1') -Destination $bdInstallRoot -Force
    $bdChildPath = Join-Path $bdInstallRoot 'Invoke-InstallStep4.ps1'
    $bdChildText = @(
        # Вивід — у UTF-8 файл, а не stdout: кодова сторінка консолі дочірнього
        # Windows PowerShell 5.1 спотворила б кирилицю.
        'param([switch]$SeedLocalConfig, [string]$BackupDestination = ''Cloud'', [string]$RuntimeRoot, [string]$OutputLog)',
        'Set-StrictMode -Version 2.0',
        '$ErrorActionPreference = ''Stop''',
        'function Write-StepOutput { param([string]$T) [IO.File]::AppendAllText($OutputLog, ($T + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false))) }',
        'function Write-Ok { param([string]$T) Write-StepOutput (''[OK] '' + $T) }',
        'function Write-Note { param([string]$T) Write-StepOutput (''[..] '' + $T) }',
        'function Write-Warn2 { param([string]$T) Write-StepOutput (''[УВАГА] '' + $T) }',
        'function Write-Bad { param([string]$T) Write-StepOutput (''[FAIL] '' + $T) }'
    ) + @(
        # Функції інсталятора поза головним try (крім виводу й паузи) — щоб
        # крок 4 міг викликати спільні з кроком 1 перевірки (#434).
        $bdInstallAst.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
            @('Write-Step', 'Write-Ok', 'Write-Bad', 'Write-Note', 'Write-Warn2', 'Wait-BRAVODeployCompletion', 'Restore-BRAVOConsoleEncoding') -notcontains $_.Name
        } | ForEach-Object { $_.Extent.Text }
    ) + @(
        'try {',
        $bdStepText,
        'exit 0',
        '} catch { Write-StepOutput (''THROW: '' + $_.Exception.Message); exit 1 }'
    ) -join "`r`n"
    [IO.File]::WriteAllText($bdChildPath, $bdChildText, (New-Object Text.UTF8Encoding($true)))
    # Розгорнутий каталог має бути цілісним комплектом: крок 4 перевіряє його
    # канонічним guard-ом до імпорту модулів Configurator (#434, Codex P1).
    Copy-Item -LiteralPath (Join-Path $root 'BRAVO_RUNTIME_GUARD.ps1') -Destination $bdInstallRoot -Force
    Write-BRAVOSelfTestBundleManifest -BundleRoot $bdInstallRoot
    $bdHostPath = (Get-Process -Id $PID).Path
    $bdLocalConfigPath = Join-Path $bdInstallRoot 'BRAVO.local.config'

    $bdOutputLogPath = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_SELFTEST_DEST_INSTALL_' + [guid]::NewGuid().ToString('N') + '.log')
    function Invoke-BRAVOSelfTestInstallStep4 {
        param([string[]]$Arguments)
        Remove-Item -LiteralPath $bdOutputLogPath -Force -ErrorAction SilentlyContinue
        # Без -ExecutionPolicy: дочірній процес успадковує політику процесу self-test
        # (PSExecutionPolicyPreference), а Bypass поза allowlist заборонено гейтом CI.
        $streamOutput = @(& $bdHostPath -NoProfile -NonInteractive -File $bdChildPath `
            -RuntimeRoot $bdInstallRoot -OutputLog $bdOutputLogPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
        $logText = $(if (Test-Path -LiteralPath $bdOutputLogPath -PathType Leaf) { [IO.File]::ReadAllText($bdOutputLogPath, [Text.Encoding]::UTF8) } else { '' })
        Remove-Item -LiteralPath $bdOutputLogPath -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ ExitCode = $exitCode; Output = ($logText + ($streamOutput -join "`n")) }
    }
    function Read-BRAVOSelfTestInstalledOverrides {
        if (-not (Test-Path -LiteralPath $bdLocalConfigPath -PathType Leaf)) { return '' }
        return ConvertTo-BRAVOSelfTestDestinationText -Overrides (Read-BRAVOSelfTestDestinationOverrides -ConfigDirectory $bdInstallRoot).Overrides
    }

    # Новий файл, явний профіль.
    $bdRunSamba = Invoke-BRAVOSelfTestInstallStep4 -Arguments @('-SeedLocalConfig', '-BackupDestination', 'SambaOnly')
    $bdRunSambaOverrides = Read-BRAVOSelfTestInstalledOverrides
    Remove-Item -LiteralPath $bdLocalConfigPath -Force -ErrorAction SilentlyContinue
    # Новий файл, профіль за замовчуванням (Хмара: явні SFTP=$true, SMB=$false).
    $bdRunDefault = Invoke-BRAVOSelfTestInstallStep4 -Arguments @('-SeedLocalConfig')
    $bdRunDefaultOverrides = Read-BRAVOSelfTestInstalledOverrides
    Test-BRAVOCondition -Condition (
        $bdRunSamba.ExitCode -eq 0 -and
        $bdRunSambaOverrides -ceq (ConvertTo-BRAVOSelfTestDestinationText -Overrides $bdProfiles['SambaOnly'].Overrides) -and
        $bdRunSamba.Output.Contains('профіль напрямків: SambaOnly') -and
        $bdRunSamba.Output.Contains('smbSettings.RootPath') -and
        $bdRunDefault.ExitCode -eq 0 -and
        $bdRunDefaultOverrides -ceq (ConvertTo-BRAVOSelfTestDestinationText -Overrides $bdProfiles['Cloud'].Overrides) -and
        $bdRunDefaultOverrides.Contains('componentSettings.SFTP.Enabled=True') -and
        $bdRunDefaultOverrides.Contains('componentSettings.SMB.Enabled=False')
    ) -Name 'BackupDestinations/InstallerNewConfigGetsProfile' `
        -Failure "інсталятор з -SeedLocalConfig має створити BRAVO.local.config із профілем (явний SambaOnly і дефолт Cloud); SambaOnly: exit=$($bdRunSamba.ExitCode) $bdRunSambaOverrides; $($bdRunSamba.Output) ||| Cloud: exit=$($bdRunDefault.ExitCode) $bdRunDefaultOverrides; $($bdRunDefault.Output)"

    # Наявний файл не змінюється; без -SeedLocalConfig файл не створюється.
    # #434: тут свідомо НЕЯВНИЙ профіль (без -BackupDestination). Явний
    # профіль, якому файл чи дефолти ЕФЕКТИВНО суперечать, більше не
    # завершується кодом 0 з «НЕ застосовано» (рішення власника, P2-2): ті
    # сценарії — fail-closed у (4a)/(4c), де «файл не змінено / не створено»
    # перевіряється тим самим SHA-256 разом із відмовою.
    $bdExistingText = "@{`r`n    'pathSettings.BackupRoot' = 'D:\ExampleArchive'`r`n}`r`n"
    [IO.File]::WriteAllText($bdLocalConfigPath, $bdExistingText, (New-Object Text.UTF8Encoding($false)))
    $bdExistingBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($bdLocalConfigPath))
    $bdRunExisting = Invoke-BRAVOSelfTestInstallStep4 -Arguments @('-SeedLocalConfig')
    $bdExistingAfter = [Convert]::ToBase64String([IO.File]::ReadAllBytes($bdLocalConfigPath))
    Remove-Item -LiteralPath $bdLocalConfigPath -Force -ErrorAction SilentlyContinue
    # Без -SeedLocalConfig файл не створюється.
    $bdRunNoSeed = Invoke-BRAVOSelfTestInstallStep4 -Arguments @()
    Test-BRAVOCondition -Condition (
        $bdRunExisting.ExitCode -eq 0 -and
        $bdExistingBefore -ceq $bdExistingAfter -and
        $bdRunExisting.Output.Contains('BRAVO.local.config уже існує') -and
        $bdRunNoSeed.ExitCode -eq 0 -and
        -not (Test-Path -LiteralPath $bdLocalConfigPath) -and
        $bdRunNoSeed.Output.Contains('не створено') -and
        @(Get-ChildItem -LiteralPath $bdInstallRoot -Force -Filter 'BRAVO.local.config*').Count -eq 0
    ) -Name 'BackupDestinations/InstallerExistingConfigUntouched' `
        -Failure "наявний BRAVO.local.config інсталятор не змінює (-SeedLocalConfig, профіль за замовчуванням); без -SeedLocalConfig файл не створюється; наявний: exit=$($bdRunExisting.ExitCode) байти_збіглись=$($bdExistingBefore -ceq $bdExistingAfter) $($bdRunExisting.Output) ||| без seed: exit=$($bdRunNoSeed.ExitCode) $($bdRunNoSeed.Output)"

    # ------------------------------------------------------------
    # (4a) Явний -BackupDestination LocalOnly — твердження про ЕФЕКТИВНИЙ стан
    # (#434, P2 fail-open). Оператор, який явно просить «Лише локально», має
    # отримати або ефективно вимкнені SFTP і SMB, або ненульовий код і
    # зрозумілу причину; «УВАГА» з кодом 0 при ефективно ввімкненому
    # SFTP/SMB — мовчазний вихід даних за межі сервера.
    # Ефективні значення рахуються канонічно: reader BRAVO.local.config ->
    # Resolve-BRAVORawConfiguration поверх Get-BRAVODefaultConfiguration ->
    # Get-BRAVOEffectiveStorageConfiguration (не текст файлу).
    # ------------------------------------------------------------
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.psd1') -ErrorAction Stop
    function Get-BRAVOSelfTestInstalledEffectiveStorage {
        $localOverrides = $null
        if (Test-Path -LiteralPath $bdLocalConfigPath -PathType Leaf) {
            $localOverrides = (Read-BRAVOSelfTestDestinationOverrides -ConfigDirectory $bdInstallRoot).Overrides
        }
        $merged = Resolve-BRAVORawConfiguration -DefaultConfiguration (Get-BRAVODefaultConfiguration) `
            -PrimaryOverrides $null -LocalOverrides $localOverrides
        return Get-BRAVOEffectiveStorageConfiguration -ComponentSettings $merged['componentSettings']
    }
    function Get-BRAVOSelfTestInstallThrowText {
        param([string]$Output)
        return (@([regex]::Matches($Output, '(?m)^THROW: (.*)$') | ForEach-Object { $_.Groups[1].Value }) -join ' ')
    }
    function Get-BRAVOSelfTestLocalConfigHash {
        if (-not (Test-Path -LiteralPath $bdLocalConfigPath -PathType Leaf)) { return '' }
        return (Get-FileHash -LiteralPath $bdLocalConfigPath -Algorithm SHA256).Hash
    }
    function Set-BRAVOSelfTestLocalConfigFixture {
        param([string[]]$Lines)
        $fixtureText = "@{`r`n" + ((@($Lines) | ForEach-Object { '    ' + $_ }) -join "`r`n") + "`r`n}`r`n"
        [IO.File]::WriteAllText($bdLocalConfigPath, $fixtureText, (New-Object Text.UTF8Encoding($false)))
    }
    $bdCyrillicPattern = '[\u0400-\u04FF]'
    Remove-Item -LiteralPath $bdLocalConfigPath -Force -ErrorAction SilentlyContinue

    # (1) LocalOnly без -SeedLocalConfig і без наявного файла: ефективна
    # конфігурація = дефолти комплекту (SFTP і SMB увімкнені) -> відмова.
    $bdLoDefaultsEffective = Get-BRAVOSelfTestInstalledEffectiveStorage
    $bdLoNoSeed = Invoke-BRAVOSelfTestInstallStep4 -Arguments @('-BackupDestination', 'LocalOnly')
    $bdLoNoSeedThrow = Get-BRAVOSelfTestInstallThrowText -Output $bdLoNoSeed.Output
    Test-BRAVOCondition -Condition (
        ([bool]$bdLoDefaultsEffective.SFTP.Enabled -or [bool]$bdLoDefaultsEffective.SMB.Enabled) -and
        $bdLoNoSeed.ExitCode -ne 0 -and
        -not [string]::IsNullOrWhiteSpace($bdLoNoSeedThrow) -and
        $bdLoNoSeedThrow -match $bdCyrillicPattern -and
        $bdLoNoSeedThrow.Contains('LocalOnly') -and
        $bdLoNoSeedThrow.Contains('-SeedLocalConfig') -and
        -not (Test-Path -LiteralPath $bdLocalConfigPath) -and
        @(Get-ChildItem -LiteralPath $bdInstallRoot -Force -Filter 'BRAVO.local.config*').Count -eq 0
    ) -Name 'BackupDestinations/InstallerLocalOnlyWithoutSeedFailsClosed' `
        -Failure "явний -BackupDestination LocalOnly без -SeedLocalConfig і без BRAVO.local.config лишає ефективними дефолти (SFTP=$($bdLoDefaultsEffective.SFTP.Enabled), SMB=$($bdLoDefaultsEffective.SMB.Enabled)) — інсталятор має завершитися ненульовим кодом з українською причиною, що називає LocalOnly і -SeedLocalConfig, і не створювати файл; exit=$($bdLoNoSeed.ExitCode) throw='$bdLoNoSeedThrow' вивід: $($bdLoNoSeed.Output)"

    # (2) Наявний BRAVO.local.config, з яким SFTP або SMB ЕФЕКТИВНО увімкнені
    # (зокрема файл, що взагалі не згадує напрямки, — дефолти) -> відмова,
    # файл не змінюється. І з -SeedLocalConfig, і без нього.
    $bdLoRemoteFixtures = [ordered]@{
        DefaultsOnly = @{
            Lines = @("'pathSettings.BackupRoot' = 'D:\ExampleArchive'")
            Channels = @('SFTP', 'SMB')
        }
        SftpEnabled = @{
            Lines = @("'componentSettings.SFTP.Enabled' = `$true", "'componentSettings.SMB.Enabled' = `$false")
            Channels = @('SFTP')
        }
        SmbEnabled = @{
            Lines = @("'componentSettings.SFTP.Enabled' = `$false", "'componentSettings.SMB.Enabled' = `$true",
                "'componentSettings.SMB.ArchiveCopy' = `$true")
            Channels = @('SMB')
        }
    }
    $bdLoRemoteFailures = @()
    foreach ($bdLoFixtureName in @($bdLoRemoteFixtures.Keys)) {
        $bdLoFixture = $bdLoRemoteFixtures[$bdLoFixtureName]
        foreach ($bdLoArguments in @(
            , @('-SeedLocalConfig', '-BackupDestination', 'LocalOnly')
            , @('-BackupDestination', 'LocalOnly')
        )) {
            Set-BRAVOSelfTestLocalConfigFixture -Lines $bdLoFixture.Lines
            $bdLoEffective = Get-BRAVOSelfTestInstalledEffectiveStorage
            $bdLoHashBefore = Get-BRAVOSelfTestLocalConfigHash
            $bdLoRun = Invoke-BRAVOSelfTestInstallStep4 -Arguments $bdLoArguments
            $bdLoHashAfter = Get-BRAVOSelfTestLocalConfigHash
            $bdLoThrow = Get-BRAVOSelfTestInstallThrowText -Output $bdLoRun.Output
            $bdLoLabel = "$bdLoFixtureName [$($bdLoArguments -join ' ')]"
            $bdLoEffectiveChannels = @()
            if ([bool]$bdLoEffective.SFTP.Enabled) { $bdLoEffectiveChannels += 'SFTP' }
            if ([bool]$bdLoEffective.SMB.Enabled) { $bdLoEffectiveChannels += 'SMB' }
            if ((@($bdLoEffectiveChannels) -join ',') -ne (@($bdLoFixture.Channels) -join ',')) {
                $bdLoRemoteFailures += "$bdLoLabel фікстура: ефективно увімкнено '$($bdLoEffectiveChannels -join ',')', очікувалось '$($bdLoFixture.Channels -join ',')'"
            }
            if ($bdLoRun.ExitCode -eq 0) { $bdLoRemoteFailures += "$bdLoLabel exit=0" }
            if ($bdLoHashBefore -cne $bdLoHashAfter) { $bdLoRemoteFailures += "$bdLoLabel файл змінено" }
            if ([string]::IsNullOrWhiteSpace($bdLoThrow) -or $bdLoThrow -notmatch $bdCyrillicPattern -or
                -not $bdLoThrow.Contains('LocalOnly') -or -not $bdLoThrow.Contains('BRAVO.local.config')) {
                $bdLoRemoteFailures += "$bdLoLabel причина без LocalOnly/BRAVO.local.config: '$bdLoThrow'"
            }
            foreach ($bdLoChannel in @($bdLoFixture.Channels)) {
                if (-not $bdLoThrow.Contains($bdLoChannel)) { $bdLoRemoteFailures += "$bdLoLabel причина не називає $bdLoChannel" }
            }
            if (@(Get-ChildItem -LiteralPath $bdInstallRoot -Force -Filter 'BRAVO.local.config*').Count -ne 1) {
                $bdLoRemoteFailures += "$bdLoLabel поруч із BRAVO.local.config з'явилися інші файли"
            }
        }
    }
    Remove-Item -LiteralPath $bdLocalConfigPath -Force -ErrorAction SilentlyContinue
    Test-BRAVOCondition -Condition ($bdLoRemoteFailures.Count -eq 0) `
        -Name 'BackupDestinations/InstallerLocalOnlyRejectsEffectiveRemoteDestination' `
        -Failure "явний LocalOnly при наявному BRAVO.local.config, з яким SFTP/SMB ефективно увімкнені, має завершитися ненульовим кодом з українською причиною (LocalOnly, BRAVO.local.config, назва каналу) і не змінити файл: $($bdLoRemoteFailures -join ' | ')"

    # (3) Наявний файл, з яким SFTP і SMB ефективно вимкнені (профіль уже в
    # силі) -> успіх, файл не змінюється, і вивід не стверджує, що LocalOnly
    # «НЕ застосовано» (ефективно він застосований).
    $bdLoMatchFailures = @()
    foreach ($bdLoArguments in @(
        , @('-SeedLocalConfig', '-BackupDestination', 'LocalOnly')
        , @('-BackupDestination', 'LocalOnly')
    )) {
        Set-BRAVOSelfTestLocalConfigFixture -Lines @(
            "'pathSettings.BackupRoot' = 'D:\ExampleArchive'",
            "'componentSettings.SFTP.Enabled' = `$false",
            "'componentSettings.SMB.Enabled' = `$false"
        )
        $bdLoEffective = Get-BRAVOSelfTestInstalledEffectiveStorage
        $bdLoHashBefore = Get-BRAVOSelfTestLocalConfigHash
        $bdLoRun = Invoke-BRAVOSelfTestInstallStep4 -Arguments $bdLoArguments
        $bdLoHashAfter = Get-BRAVOSelfTestLocalConfigHash
        $bdLoLabel = "[$($bdLoArguments -join ' ')]"
        if ([bool]$bdLoEffective.SFTP.Enabled -or [bool]$bdLoEffective.SMB.Enabled) {
            $bdLoMatchFailures += "$bdLoLabel фікстура не вимикає SFTP/SMB ефективно"
        }
        if ($bdLoRun.ExitCode -ne 0) { $bdLoMatchFailures += "$bdLoLabel exit=$($bdLoRun.ExitCode): $($bdLoRun.Output)" }
        if ($bdLoHashBefore -cne $bdLoHashAfter) { $bdLoMatchFailures += "$bdLoLabel файл змінено" }
        if ($bdLoRun.Output.Contains('профіль напрямків LocalOnly НЕ застосовано')) {
            $bdLoMatchFailures += "$bdLoLabel вивід стверджує «LocalOnly НЕ застосовано», хоча він ефективно в силі"
        }
    }
    Remove-Item -LiteralPath $bdLocalConfigPath -Force -ErrorAction SilentlyContinue
    Test-BRAVOCondition -Condition ($bdLoMatchFailures.Count -eq 0) `
        -Name 'BackupDestinations/InstallerLocalOnlyAcceptsMatchingExistingConfig' `
        -Failure "явний LocalOnly при наявному BRAVO.local.config, з яким SFTP і SMB ефективно вимкнені, має пройти з кодом 0, не змінити файл і не повідомляти «НЕ застосовано»: $($bdLoMatchFailures -join ' | ')"

    # (4) Повторний запуск інсталятора не перезаписує site-конфігурацію:
    # перший прогін створює файл профілем LocalOnly, другий (той самий
    # LocalOnly) проходить без змін, третій з іншим профілем файл не чіпає.
    $bdLoRepeatFailures = @()
    $bdLoFirst = Invoke-BRAVOSelfTestInstallStep4 -Arguments @('-SeedLocalConfig', '-BackupDestination', 'LocalOnly')
    $bdLoFirstHash = Get-BRAVOSelfTestLocalConfigHash
    $bdLoFirstEffective = $(if (-not [string]::IsNullOrEmpty($bdLoFirstHash)) { Get-BRAVOSelfTestInstalledEffectiveStorage } else { $null })
    if ($bdLoFirst.ExitCode -ne 0 -or [string]::IsNullOrEmpty($bdLoFirstHash) -or $null -eq $bdLoFirstEffective -or
        [bool]$bdLoFirstEffective.SFTP.Enabled -or [bool]$bdLoFirstEffective.SMB.Enabled) {
        $bdLoRepeatFailures += "перший прогін: exit=$($bdLoFirst.ExitCode) файл='$bdLoFirstHash' $($bdLoFirst.Output)"
    } else {
        $bdLoSecond = Invoke-BRAVOSelfTestInstallStep4 -Arguments @('-SeedLocalConfig', '-BackupDestination', 'LocalOnly')
        if ($bdLoSecond.ExitCode -ne 0) { $bdLoRepeatFailures += "другий прогін: exit=$($bdLoSecond.ExitCode) $($bdLoSecond.Output)" }
        if ((Get-BRAVOSelfTestLocalConfigHash) -cne $bdLoFirstHash) { $bdLoRepeatFailures += 'другий прогін змінив файл' }
        if ($bdLoSecond.Output.Contains('профіль напрямків LocalOnly НЕ застосовано')) {
            $bdLoRepeatFailures += 'другий прогін стверджує «LocalOnly НЕ застосовано», хоча файл першого прогону вже тримає LocalOnly'
        }
        $bdLoThird = Invoke-BRAVOSelfTestInstallStep4 -Arguments @('-SeedLocalConfig', '-BackupDestination', 'Cloud')
        $bdLoThirdEffective = Get-BRAVOSelfTestInstalledEffectiveStorage
        if ((Get-BRAVOSelfTestLocalConfigHash) -cne $bdLoFirstHash) { $bdLoRepeatFailures += "третій прогін (Cloud) змінив файл: exit=$($bdLoThird.ExitCode)" }
        if ([bool]$bdLoThirdEffective.SFTP.Enabled -or [bool]$bdLoThirdEffective.SMB.Enabled) {
            $bdLoRepeatFailures += 'після третього прогону SFTP/SMB ефективно увімкнені'
        }
    }
    Remove-Item -LiteralPath $bdLocalConfigPath -Force -ErrorAction SilentlyContinue
    Test-BRAVOCondition -Condition ($bdLoRepeatFailures.Count -eq 0) `
        -Name 'BackupDestinations/InstallerRepeatedRunKeepsSiteConfig' `
        -Failure "повторний запуск інсталятора не перезаписує BRAVO.local.config і не повідомляє «НЕ застосовано» про вже ефективний LocalOnly: $($bdLoRepeatFailures -join ' | ')"
} finally {
    if (Test-Path -LiteralPath $bdInstallRoot) {
        Remove-Item -LiteralPath $bdInstallRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------
# (4b) Порядок у Install-BRAVOServer.ps1 (#434): рішення щодо явного
# LocalOnly без -SeedLocalConfig приймається ДО першої зовнішньої операції
# чи запису (staging-каталог, завантаження, розпакування, robocopy, запис
# BRAVO.local.config), а рішення щодо наявного файла в кроці 4 спирається
# на канонічні ефективні значення (Get-BRAVOEffectiveStorageConfiguration),
# а не на текст файла. Функції інсталятора (Write-*) і UAC-перезапуск
# (Start-Process) — не побічні дії над комплектом чи конфігурацією.
# ------------------------------------------------------------
$bdSideEffectCommands = @('New-Item', 'Remove-Item', 'Copy-Item', 'Move-Item', 'Set-Content', 'Add-Content', 'Out-File',
    'Expand-Archive', 'Invoke-WebRequest', 'Invoke-RestMethod', 'robocopy', 'robocopy.exe', 'New-BRAVOConfiguratorSeedLocalConfig')
function Test-BRAVOSelfTestInsideFunction {
    param($Node)
    $parent = $Node.Parent
    while ($null -ne $parent) {
        if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) { return $true }
        $parent = $parent.Parent
    }
    return $false
}
$bdFirstSideEffect = @($bdInstallAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    $bdSideEffectCommands -contains [string]$node.GetCommandName() -and
    -not (Test-BRAVOSelfTestInsideFunction -Node $node)
}, $true) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
$bdFirstSideEffectOffset = $(if ($bdFirstSideEffect.Count -eq 1) { $bdFirstSideEffect[0].Extent.StartOffset } else { -1 })
$bdEarlyLocalOnlyGuards = @($bdInstallAst.FindAll({
    param($node)
    if (-not ($node -is [Management.Automation.Language.IfStatementAst])) { return $false }
    if (Test-BRAVOSelfTestInsideFunction -Node $node) { return $false }
    foreach ($clause in $node.Clauses) {
        $conditionText = $clause.Item1.Extent.Text
        if ($conditionText -match 'LocalOnly|BackupDestination' -and $conditionText -match '(?i)\$SeedLocalConfig\b' -and
            $null -ne $clause.Item2.Find({ param($inner) $inner -is [Management.Automation.Language.ThrowStatementAst] }, $true)) {
            return $true
        }
    }
    return $false
}, $true) | Where-Object { $bdFirstSideEffectOffset -ge 0 -and $_.Extent.EndOffset -lt $bdFirstSideEffectOffset })
$bdEarlyLocalOnlyAsserts = @($bdInstallAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    [string]$node.GetCommandName() -match '^Assert-BRAVO\S*BackupDestination' -and
    -not (Test-BRAVOSelfTestInsideFunction -Node $node)
}, $true) | Where-Object { $bdFirstSideEffectOffset -ge 0 -and $_.Extent.EndOffset -lt $bdFirstSideEffectOffset })
Test-BRAVOCondition -Condition (
    $bdFirstSideEffectOffset -ge 0 -and
    ($bdEarlyLocalOnlyGuards.Count + $bdEarlyLocalOnlyAsserts.Count) -ge 1 -and
    $bdStepText.Contains('Get-BRAVOEffectiveStorageConfiguration')
) -Name 'BackupDestinations/InstallerLocalOnlyDecisionPrecedesSideEffects' `
    -Failure "Install-BRAVOServer.ps1: відмова для явного LocalOnly без -SeedLocalConfig має стояти ДО першої побічної дії ($(if ($bdFirstSideEffect.Count -eq 1) { 'рядок ' + $bdFirstSideEffect[0].Extent.StartLineNumber + ': ' + $bdFirstSideEffect[0].GetCommandName() } else { 'не знайдено' })) — if з умовою на LocalOnly і `$SeedLocalConfig і throw у тілі або виклик Assert-BRAVO*BackupDestination*; знайдено if-guard: $($bdEarlyLocalOnlyGuards.Count), assert: $($bdEarlyLocalOnlyAsserts.Count); крок 4 має вирішувати за Get-BRAVOEffectiveStorageConfiguration: $($bdStepText.Contains('Get-BRAVOEffectiveStorageConfiguration'))"

# ------------------------------------------------------------
# (4c) Install-BRAVOServer.ps1 від кроку 0 до кроку 4 на ФЕЙКОВОМУ комплекті
# (#434: P1-1, P2-1, P2-2). Реальний код інсталятора (усі оператори головного
# try до «Write-Step '5.» і функції поза ним) виконується в окремому процесі
# з локальним zip і .sha256 — без мережі, без UAC, без кроків 5-7. Підмінено
# лише: перевірку прав ($isElevated = $true), robocopy.exe (копіювання тим
# самим Copy-Item з маркером виклику), Invoke-WebRequest і Start-Process
# (заборонені). Справжні: розпакування, SHA-256, провенанс, канал релізу,
# перевірка обов'язкових файлів, крок 4.
#
# Контракт власника:
#   * P1-1: явний -BackupDestination з комплектом без BRAVO.Configurator
#     (форма v5.2.4) зупиняється ДО копіювання в каталог інсталяції;
#     неявний -SeedLocalConfig з таким комплектом лишає поведінку developer
#     (копія прикладу) і завершується кодом 0;
#   * P2-1/P2-2: для КОЖНОГО явного профілю наявний BRAVO.local.config
#     перевіряється за ефективними значеннями ДО копіювання; суперечність =
#     ефективні SFTP.Enabled, SFTP.ArchiveUpload, SMB.Enabled чи SMB.ArchiveCopy відрізняються від
#     тих, що дав би свіжий -SeedLocalConfig -BackupDestination <профіль>;
#     без -SeedLocalConfig і без файла явний профіль відхиляється в кроці 0;
#   * наявний файл ніколи не змінюється (SHA-256), модулі з комплекту не
#     імпортуються до гейтів SHA-256/провенансу/каналу.
# ------------------------------------------------------------
# Блок виконується в дочірній області (& { ... }, конвенція #163): його
# змінні не накопичуються в області self-test.
& {
    $bdE2eRoot = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_SELFTEST_DEST_E2E_' + [guid]::NewGuid().ToString('N'))
    $bdE2eVersion = '9.8.7'
    $bdE2eHostPath = (Get-Process -Id $PID).Path
    try {
        [void](New-Item -ItemType Directory -Path $bdE2eRoot -Force)
        Copy-Item -LiteralPath (Join-Path $root 'deploy\BRAVO.Deploy.ReleaseGate.ps1') -Destination $bdE2eRoot -Force

        # --- Дочірній скрипт: реальні оператори інсталятора до кроку 5 ---
        $bdE2eMainTry = @($bdInstallAst.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.TryStatementAst] -and $_.Body.Extent.Text.Contains("Write-Step '0.")
        })
        $bdE2eStatements = @()
        $bdE2eStopFound = $false
        if ($bdE2eMainTry.Count -eq 1) {
            foreach ($bdE2eStatement in @($bdE2eMainTry[0].Body.Statements)) {
                $bdE2eStatementText = $bdE2eStatement.Extent.Text
                if ($bdE2eStatementText -match "^Write-Step\s+'5\.") { $bdE2eStopFound = $true; break }
                if ($bdE2eStatementText -match '^\$isElevated\s*=') { $bdE2eStatements += '$isElevated = $true'; continue }
                $bdE2eStatements += $bdE2eStatementText
            }
        }
        $bdE2eHelperNames = @('Write-Step', 'Write-Ok', 'Write-Bad', 'Write-Note', 'Write-Warn2',
            'Wait-BRAVODeployCompletion', 'Restore-BRAVOConsoleEncoding')
        $bdE2eHelpers = @($bdInstallAst.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $bdE2eHelperNames -notcontains $_.Name
        } | ForEach-Object { $_.Extent.Text })
        # (Codex P1, раунд 3) Приватний каталог кроку 1 інсталятор створює з
        # DACL лише для BUILTIN\Administrators і SYSTEM — це можливо лише в
        # елевованому процесі Windows. Харнес і так підставляє $isElevated =
        # $true, тож поза елевованим Windows (Linux, неелевована консоль)
        # New-BRAVOInstallPrivateDirectory замінено звичайним створенням
        # каталогу, а основа $env:SystemRoot\Temp — [IO.Path]::GetTempPath();
        # справжні функції перевіряє InstallerPrivateVerifyDirectoryProtectedBeforeFirstWrite.
        $bdE2eIsWindows = ($env:OS -eq 'Windows_NT')
        $bdE2eIsElevated = $false
        if ($bdE2eIsWindows) {
            $bdE2eIsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        $bdE2ePrivateDirectoryStub = @($(if (-not ($bdE2eIsWindows -and $bdE2eIsElevated)) {
            'function Get-BRAVOInstallPrivateDirectoryBase { return [IO.Path]::GetTempPath() }',
            'function New-BRAVOInstallPrivateDirectory { param([string]$Path) Write-StepOutput ''STUB: private-acl''; [void](New-Item -ItemType Directory -Path $Path) }'
        }))
        $bdE2eParamText = [regex]::Replace([string]$bdInstallAst.ParamBlock.Extent.Text, '^(?i)param\s*\(', 'param([string]$OutputLog, [string]$SelfTestSiteMutationSource, ')
        $bdE2eChildPath = Join-Path $bdE2eRoot 'Invoke-InstallSteps0to4.ps1'
        $bdE2eChildText = (@(
            '[CmdletBinding()]',
            $bdE2eParamText,
            'Set-StrictMode -Version 2.0',
            '$ErrorActionPreference = ''Stop''',
            'function Write-StepOutput { param([string]$T) [IO.File]::AppendAllText($OutputLog, ($T + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false))) }',
            'function Write-Step {',
            '    param([string]$T)',
            '    Write-StepOutput (''=== '' + $T)',
            '    # Гачок харнеса: зміна BRAVO.local.config МІЖ перевіркою кроку 1 і копіюванням.',
            '    if ($T -like ''2.*'' -and -not [string]::IsNullOrEmpty($SelfTestSiteMutationSource)) {',
            '        [void](New-Item -ItemType Directory -Path $RuntimeRoot -Force)',
            '        Copy-Item -LiteralPath $SelfTestSiteMutationSource -Destination (Join-Path $RuntimeRoot ''BRAVO.local.config'') -Force',
            '    }',
            '}',
            'function Write-Ok { param([string]$T) Write-StepOutput (''[OK] '' + $T) }',
            'function Write-Note { param([string]$T) Write-StepOutput (''[..] '' + $T) }',
            'function Write-Warn2 { param([string]$T) Write-StepOutput (''[УВАГА] '' + $T) }',
            'function Write-Bad { param([string]$T) Write-StepOutput (''[FAIL] '' + $T) }',
            'function robocopy.exe {',
            '    Write-StepOutput ''STUB: robocopy''',
            '    Get-ChildItem -LiteralPath $args[0] -Force | Copy-Item -Destination $args[1] -Recurse -Force',
            '    $global:LASTEXITCODE = 1',
            '}',
            'function Invoke-WebRequest { throw ''self-test: мережа заборонена'' }',
            'function Start-Process { throw ''self-test: Start-Process заборонено'' }'
        ) + $bdE2eHelpers + $bdE2ePrivateDirectoryStub + @('try {') + $bdE2eStatements + @(
            'exit 0',
            '} catch { Write-StepOutput (''THROW: '' + $_.Exception.Message); exit 1 }'
        )) -join "`r`n"
        [IO.File]::WriteAllText($bdE2eChildPath, $bdE2eChildText, (New-Object Text.UTF8Encoding($true)))

        # --- Фейковий комплект: zip + .sha256 поруч, без release-manifest.json ---
        function New-BRAVOSelfTestInstallBundle {
            param([string]$Name, [string[]]$ModuleDirectories, [string]$SourceCommit = ('a1b2c3d4' * 5),
                [switch]$MarkImports, [switch]$CorruptChecksum, [string[]]$StripFunctions = @(), [switch]$TamperAfterManifest,
                [string[]]$UnexportFunctions = @(), [string]$PersistenceImportHook = '')
            $bundleDir = Join-Path $bdE2eRoot ('bundle_' + $Name)
            [void](New-Item -ItemType Directory -Path (Join-Path $bundleDir 'modules') -Force)
            [void](New-Item -ItemType Directory -Path (Join-Path $bundleDir 'Tools') -Force)
            $buildId = $(if ($SourceCommit.Length -ge 7) { $SourceCommit.Substring(0, 7) } else { $SourceCommit })
            $versionJson = '{ "product": "BRAVO-Toolkit", "packageVersion": "' + $bdE2eVersion + '", "releaseChannel": "stable", ' +
                '"buildId": "' + $buildId + '", "sourceCommit": "' + $SourceCommit + '" }'
            $utf8 = New-Object Text.UTF8Encoding($false)
            # Переписаний модуль зберігає BOM джерела: без нього Windows PowerShell 5.1
            # читає .psm1/.psd1 як ANSI, байти 0x91-0x94 кирилиці в UTF-8 стають
            # «розумними» лапками, і ParseFile дає помилки («не розібрано»).
            $utf8Bom = New-Object Text.UTF8Encoding($true)
            [IO.File]::WriteAllText((Join-Path $bundleDir 'VERSION.json'), $versionJson, $utf8)
            [IO.File]::WriteAllText((Join-Path $bundleDir 'RUNTIME_MANIFEST.json'), '{}', $utf8)
            [IO.File]::WriteAllText((Join-Path $bundleDir 'Tools\TOOLS_MANIFEST.json'), '{}', $utf8)
            [IO.File]::WriteAllText((Join-Path $bundleDir 'BRAVO_SETUP.ps1'), ("# self-test fixture`r`nexit 0`r`n"), $utf8)
            # Справжній guard: інсталятор звіряє комплект з RUNTIME_MANIFEST.json
            # його канонічною перевіркою до першого імпорту коду комплекту.
            Copy-Item -LiteralPath (Join-Path $root 'BRAVO_RUNTIME_GUARD.ps1') -Destination $bundleDir -Force
            Copy-Item -LiteralPath (Join-Path $root 'BRAVO_CONFIG_LOADER.ps1') -Destination $bundleDir -Force
            Copy-Item -LiteralPath (Join-Path $root 'BRAVO.local.config.example') -Destination $bundleDir -Force
            foreach ($moduleDirectory in @($ModuleDirectories)) {
                Copy-Item -LiteralPath (Join-Path $root ('modules\' + $moduleDirectory)) -Destination (Join-Path $bundleDir 'modules') -Recurse -Force
            }
            if (@($StripFunctions).Count -gt 0) {
                # Форма знімка developer: файли BRAVO.Configurator є, а функцій
                # профілю напрямків у них немає (визначення вирізано за AST).
                foreach ($moduleFile in @(Get-ChildItem -LiteralPath (Join-Path $bundleDir 'modules') -Recurse -Filter '*.psm1')) {
                    $moduleText = [IO.File]::ReadAllText($moduleFile.FullName, [Text.Encoding]::UTF8)
                    $moduleTokens = $null; $moduleErrors = $null
                    $moduleAst = [Management.Automation.Language.Parser]::ParseInput($moduleText, [ref]$moduleTokens, [ref]$moduleErrors)
                    $stripNodes = @($moduleAst.FindAll({ param($node)
                        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and @($StripFunctions) -contains $node.Name }, $false) |
                        Sort-Object { $_.Extent.StartOffset } -Descending)
                    foreach ($stripNode in $stripNodes) {
                        $moduleText = $moduleText.Remove($stripNode.Extent.StartOffset, $stripNode.Extent.EndOffset - $stripNode.Extent.StartOffset)
                    }
                    if ($stripNodes.Count -gt 0) { [IO.File]::WriteAllText($moduleFile.FullName, $moduleText, $utf8Bom) }
                }
            }
            if (@($UnexportFunctions).Count -gt 0) {
                # Визначення функції лишається, але модуль її не експортує:
                # ім'я вирізано зі списків Export-ModuleMember (.psm1) і
                # FunctionsToExport (.psd1) за AST.
                foreach ($moduleFile in @(Get-ChildItem -LiteralPath (Join-Path $bundleDir 'modules') -Recurse -File |
                    Where-Object { @('.psm1', '.psd1') -contains $_.Extension.ToLowerInvariant() })) {
                    $moduleText = [IO.File]::ReadAllText($moduleFile.FullName, [Text.Encoding]::UTF8)
                    $moduleTokens = $null; $moduleErrors = $null
                    $moduleAst = [Management.Automation.Language.Parser]::ParseInput($moduleText, [ref]$moduleTokens, [ref]$moduleErrors)
                    $isManifest = ($moduleFile.Extension.ToLowerInvariant() -eq '.psd1')
                    $exportNodes = @($moduleAst.FindAll({ param($node)
                        if (-not ($node -is [Management.Automation.Language.StringConstantExpressionAst]) -or @($UnexportFunctions) -notcontains $node.Value) { return $false }
                        if ($isManifest) { return $true }
                        $ancestor = $node.Parent
                        while ($null -ne $ancestor) {
                            if ($ancestor -is [Management.Automation.Language.CommandAst] -and [string]$ancestor.GetCommandName() -eq 'Export-ModuleMember') { return $true }
                            $ancestor = $ancestor.Parent
                        }
                        return $false
                    }, $true) | Sort-Object { $_.Extent.StartOffset } -Descending)
                    foreach ($exportNode in $exportNodes) {
                        $removeStart = $exportNode.Extent.StartOffset
                        $removeEnd = $exportNode.Extent.EndOffset
                        $trailingComma = [regex]::Match($moduleText.Substring($removeEnd), '^\s*,')
                        if ($trailingComma.Success) { $removeEnd += $trailingComma.Length } else {
                            $leadingComma = [regex]::Match($moduleText.Substring(0, $removeStart), ',\s*$')
                            if ($leadingComma.Success) { $removeStart -= $leadingComma.Length }
                        }
                        $moduleText = $moduleText.Remove($removeStart, $removeEnd - $removeStart)
                    }
                    if ($exportNodes.Count -gt 0) { [IO.File]::WriteAllText($moduleFile.FullName, $moduleText, $utf8Bom) }
                }
            }
            if (-not [string]::IsNullOrEmpty($PersistenceImportHook)) {
                # Код, що виконується при КОЖНОМУ імпорті Persistence.psm1 (до
                # маніфесту — комплект цілісний).
                [IO.File]::AppendAllText((Join-Path $bundleDir 'modules\BRAVO.Configurator\BRAVO.Configurator.Persistence.psm1'),
                    ("`r`n" + $PersistenceImportHook + "`r`n"), $utf8)
            }
            $markerPath = Join-Path $bdE2eRoot ('imported_' + $Name + '.marker')
            $markModules = {
                # Будь-який імпорт модуля з комплекту лишає маркер — рядок із
                # каталогом, з якого модуль імпортовано ($PSScriptRoot).
                foreach ($moduleFile in @(Get-ChildItem -LiteralPath (Join-Path $bundleDir 'modules') -Recurse -Filter '*.psm1')) {
                    [IO.File]::AppendAllText($moduleFile.FullName,
                        ("`r`n[IO.File]::AppendAllText('" + $markerPath.Replace("'", "''") + "', (`$PSScriptRoot + [Environment]::NewLine))`r`n"), $utf8)
                }
            }
            if ($MarkImports -and -not $TamperAfterManifest) { & $markModules }
            Write-BRAVOSelfTestBundleManifest -BundleRoot $bundleDir
            # Підміна ПІСЛЯ маніфесту: архів і .sha256 узгоджені, а модулі не
            # збігаються з RUNTIME_MANIFEST.json (локальний архів зі «своїм»
            # .sha256 поруч або підміна staged-файлів).
            if ($TamperAfterManifest) { & $markModules }
            $zipDir = Join-Path $bdE2eRoot ('zip_' + $Name)
            [void](New-Item -ItemType Directory -Path $zipDir -Force)
            $zipPath = Join-Path $zipDir ('BRAVO-Toolkit-' + $bdE2eVersion + '.zip')
            Compress-Archive -Path (Join-Path $bundleDir '*') -DestinationPath $zipPath -Force
            $sha = $(if ($CorruptChecksum) { '0' * 64 } else { (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() })
            [IO.File]::WriteAllText($zipPath + '.sha256', ($sha + '  ' + (Split-Path -Leaf $zipPath)), $utf8)
            return [pscustomobject]@{
                ZipPath = $zipPath
                MarkerPath = $markerPath
                ExampleBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $bundleDir 'BRAVO.local.config.example')))
            }
        }
        $bdE2eCurrentModules = @('BRAVO.Compatibility', 'BRAVO.Configurator', 'BRAVO.Configuration', 'BRAVO.Discovery', 'BRAVO.System')
        # Форма v5.2.4: немає modules\BRAVO.Configurator і modules\BRAVO.Configuration.
        $bdE2eLegacyModules = @('BRAVO.Compatibility', 'BRAVO.Discovery', 'BRAVO.System')
        $bdE2eCurrentBundle = New-BRAVOSelfTestInstallBundle -Name 'current' -ModuleDirectories $bdE2eCurrentModules
        $bdE2eLegacyBundle = New-BRAVOSelfTestInstallBundle -Name 'legacy' -ModuleDirectories $bdE2eLegacyModules
        # Форма знімка developer: усі файли модулів на місці, але без функцій
        # профілю напрямків (#434, P3-1).
        $bdE2eCapabilityFunctions = @('Get-BRAVOConfiguratorBackupDestinationProfile',
            'Test-BRAVOConfiguratorBackupDestinationEffective', 'New-BRAVOConfiguratorSeedLocalConfig')
        $bdE2eNoCapabilityBundle = New-BRAVOSelfTestInstallBundle -Name 'nocapability' -ModuleDirectories $bdE2eCurrentModules `
            -StripFunctions $bdE2eCapabilityFunctions

        function Invoke-BRAVOSelfTestInstallE2E {
            param([string]$RuntimeRoot, [string]$ZipPath, [string[]]$Arguments, [string]$SiteMutationSource)
            $runId = [guid]::NewGuid().ToString('N')
            $stagingRoot = Join-Path $bdE2eRoot ('staging_' + $runId)
            $outputLog = Join-Path $bdE2eRoot ('out_' + $runId + '.log')
            $hookArguments = @($(if (-not [string]::IsNullOrEmpty($SiteMutationSource)) { '-SelfTestSiteMutationSource'; $SiteMutationSource }))
            # Без -ExecutionPolicy: політика успадковується від процесу self-test.
            $streamOutput = @(& $bdE2eHostPath -NoProfile -NonInteractive -File $bdE2eChildPath -OutputLog $outputLog `
                -RuntimeRoot $RuntimeRoot -Tag ('v' + $bdE2eVersion) -ZipPath $ZipPath -StagingRoot $stagingRoot `
                -NoElevation -NoPause @hookArguments @Arguments 2>&1 | ForEach-Object { [string]$_ })
            $exitCode = $LASTEXITCODE
            $logText = $(if (Test-Path -LiteralPath $outputLog -PathType Leaf) { [IO.File]::ReadAllText($outputLog, [Text.Encoding]::UTF8) } else { '' })
            $throwText = (@([regex]::Matches($logText, '(?m)^THROW: (.*)$') | ForEach-Object { $_.Groups[1].Value }) -join ' ')
            return [pscustomobject]@{
                ExitCode = $exitCode
                Output = ($logText + ($streamOutput -join "`n"))
                Throw = $throwText
                RobocopyCalled = $logText.Contains('STUB: robocopy')
                StagingCreated = (Test-Path -LiteralPath $stagingRoot)
                StagingLeaf = ('staging_' + $runId)
                Label = ('[' + (@($Arguments) -join ' ') + ']')
            }
        }
        function New-BRAVOSelfTestE2ERuntimeRoot {
            param([string[]]$SiteConfigLines, [string]$SiteConfigText)
            $runtimeRoot = Join-Path $bdE2eRoot ('runtime_' + [guid]::NewGuid().ToString('N'))
            if ($PSBoundParameters.ContainsKey('SiteConfigLines') -or $PSBoundParameters.ContainsKey('SiteConfigText')) {
                [void](New-Item -ItemType Directory -Path $runtimeRoot -Force)
                $text = $(if ($PSBoundParameters.ContainsKey('SiteConfigText')) { $SiteConfigText } else {
                    "@{`r`n" + ((@($SiteConfigLines) | ForEach-Object { '    ' + $_ }) -join "`r`n") + "`r`n}`r`n" })
                [IO.File]::WriteAllText((Join-Path $runtimeRoot 'BRAVO.local.config'), $text, (New-Object Text.UTF8Encoding($false)))
            }
            return $runtimeRoot
        }
        function Get-BRAVOSelfTestE2ESiteHash {
            param([string]$RuntimeRoot)
            $path = Join-Path $RuntimeRoot 'BRAVO.local.config'
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
            return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
        function Get-BRAVOSelfTestE2EEntries {
            param([string]$RuntimeRoot)
            if (-not (Test-Path -LiteralPath $RuntimeRoot)) { return @() }
            return @(Get-ChildItem -LiteralPath $RuntimeRoot -Force | ForEach-Object { $_.Name } | Sort-Object)
        }
        # Ефективні напрямки — канонічно: дефолти < LocalOverrides ->
        # Get-BRAVOEffectiveStorageConfiguration. NAS = ефективний SMB.ArchiveCopy,
        # Upload = ефективний SFTP.ArchiveUpload.
        function Get-BRAVOSelfTestEffectiveDestinations {
            param($LocalOverrides)
            $merged = Resolve-BRAVORawConfiguration -DefaultConfiguration (Get-BRAVODefaultConfiguration) `
                -PrimaryOverrides $null -LocalOverrides $LocalOverrides
            $storage = Get-BRAVOEffectiveStorageConfiguration -ComponentSettings $merged['componentSettings']
            return [pscustomobject]@{
                SFTP = [bool]$storage.SFTP.Enabled
                Upload = [bool]$storage.SFTP.ArchiveUpload
                SMB = [bool]$storage.SMB.Enabled
                NAS = [bool]$storage.SMB.ArchiveCopy
            }
        }
        function Get-BRAVOSelfTestDestinationConflicts {
            # Канали, чий ефективний стан суперечить профілю; NAS-копія звітується
            # як SMB, вивантаження архіву (SFTP.ArchiveUpload) — як SFTP.
            param($Actual, $Expected)
            $channels = @()
            if ($Actual.SFTP -ne $Expected.SFTP -or $Actual.Upload -ne $Expected.Upload) { $channels += 'SFTP' }
            if ($Actual.SMB -ne $Expected.SMB -or $Actual.NAS -ne $Expected.NAS) { $channels += 'SMB' }
            return @($channels)
        }
        function ConvertTo-BRAVOSelfTestSiteConfigLines {
            param([System.Collections.IDictionary]$Overrides)
            return @(@($Overrides.Keys | Sort-Object) | ForEach-Object { "'$_' = `$" + ([string][bool]$Overrides[$_]).ToLowerInvariant() })
        }
        # «Що дав би свіжий -SeedLocalConfig -BackupDestination <профіль>».
        $bdE2eProfileDestinations = @{}
        foreach ($bdE2eDestination in @($bdExpectedProfiles.Keys)) {
            $bdE2eProfileDestinations[$bdE2eDestination] = Get-BRAVOSelfTestEffectiveDestinations -LocalOverrides $bdProfiles[$bdE2eDestination].Overrides
        }
        $bdE2eDefaultDestinations = Get-BRAVOSelfTestEffectiveDestinations -LocalOverrides $null
        function Get-BRAVOSelfTestPreDeployRefusalProblems {
            # Відмова ДО розгортання: код != 0, українська причина з потрібними
            # словами, robocopy не викликано, у каталозі інсталяції немає нічого,
            # крім дозволеного (наявного BRAVO.local.config), і VERSION.json.
            param($Run, [string]$RuntimeRoot, [string[]]$AllowedEntries, [string[]]$RequiredTexts)
            $problems = @()
            if ($Run.ExitCode -eq 0) { $problems += "$($Run.Label) exit=0" }
            if ([string]::IsNullOrWhiteSpace($Run.Throw) -or $Run.Throw -notmatch '[\u0400-\u04FF]') {
                $problems += "$($Run.Label) немає української причини зупинки"
            }
            foreach ($requiredText in @($RequiredTexts)) {
                if (-not $Run.Throw.Contains($requiredText)) { $problems += "$($Run.Label) причина не містить '$requiredText'" }
            }
            if ($Run.RobocopyCalled) { $problems += "$($Run.Label) копіювання в каталог інсталяції вже виконано" }
            if (Test-Path -LiteralPath (Join-Path $RuntimeRoot 'VERSION.json')) { $problems += "$($Run.Label) у каталозі інсталяції є VERSION.json" }
            $unexpected = @(Get-BRAVOSelfTestE2EEntries -RuntimeRoot $RuntimeRoot | Where-Object { @($AllowedEntries) -notcontains $_ })
            if ($unexpected.Count -gt 0) { $problems += "$($Run.Label) у каталозі інсталяції з'явилось: $($unexpected -join ',')" }
            if ($problems.Count -gt 0) { $problems += "$($Run.Label) throw='$($Run.Throw)'" }
            return @($problems)
        }

        # Контроль харнеса: дочірній скрипт зібрано, комплект поточної форми
        # розгортається, -SeedLocalConfig пише профіль (явний SambaOnly і дефолт Cloud).
        $bdE2eControlFailures = @()
        if ($bdE2eMainTry.Count -ne 1 -or -not $bdE2eStopFound) {
            $bdE2eControlFailures += "харнес: головний try інсталятора або «Write-Step '5.» не знайдено (try=$($bdE2eMainTry.Count))"
        }
        foreach ($bdE2eControlCase in @(
            @{ Arguments = @('-SeedLocalConfig', '-BackupDestination', 'SambaOnly'); Destination = 'SambaOnly' },
            @{ Arguments = @('-SeedLocalConfig'); Destination = 'Cloud' }
        )) {
            $bdE2eRuntime = New-BRAVOSelfTestE2ERuntimeRoot
            $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eCurrentBundle.ZipPath -Arguments $bdE2eControlCase.Arguments
            $bdE2eInstalled = $(if (Test-Path -LiteralPath (Join-Path $bdE2eRuntime 'BRAVO.local.config')) {
                ConvertTo-BRAVOSelfTestDestinationText -Overrides (Read-BRAVOSelfTestDestinationOverrides -ConfigDirectory $bdE2eRuntime).Overrides } else { '' })
            if ($bdE2eRun.ExitCode -ne 0 -or -not $bdE2eRun.RobocopyCalled -or
                -not (Test-Path -LiteralPath (Join-Path $bdE2eRuntime 'VERSION.json')) -or
                $bdE2eInstalled -cne (ConvertTo-BRAVOSelfTestDestinationText -Overrides $bdProfiles[$bdE2eControlCase.Destination].Overrides)) {
                $bdE2eControlFailures += "$($bdE2eRun.Label): exit=$($bdE2eRun.ExitCode) robocopy=$($bdE2eRun.RobocopyCalled) файл='$bdE2eInstalled' $($bdE2eRun.Output)"
            }
        }
        Test-BRAVOCondition -Condition ($bdE2eControlFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerE2EHarnessDeploysCurrentBundle' `
            -Failure "контроль харнеса: кроки 0-4 інсталятора на фейковому комплекті поточної форми мають розгорнути його й створити BRAVO.local.config профілем: $($bdE2eControlFailures -join ' | ')"

        # (P1-1) Явний -BackupDestination з комплектом без BRAVO.Configurator:
        # зупинка ДО копіювання, причина називає модуль, параметр і вихід (-Tag/-ZipPath).
        $bdE2eLegacyExplicitFailures = @()
        $bdE2eLocalOnlyLines = @("'pathSettings.BackupRoot' = 'D:\ExampleArchive'") + @(ConvertTo-BRAVOSelfTestSiteConfigLines -Overrides $bdProfiles['LocalOnly'].Overrides)
        foreach ($bdE2eCase in @(
            @{ Arguments = @('-SeedLocalConfig', '-BackupDestination', 'LocalOnly'); Existing = $false },
            @{ Arguments = @('-SeedLocalConfig', '-BackupDestination', 'SambaOnly'); Existing = $false },
            @{ Arguments = @('-SeedLocalConfig', '-BackupDestination', 'Cloud'); Existing = $false },
            @{ Arguments = @('-BackupDestination', 'LocalOnly', '-Force'); Existing = $true }
        )) {
            $bdE2eRuntime = $(if ($bdE2eCase.Existing) { New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigLines $bdE2eLocalOnlyLines } else { New-BRAVOSelfTestE2ERuntimeRoot })
            $bdE2eHashBefore = Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime
            $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eLegacyBundle.ZipPath -Arguments $bdE2eCase.Arguments
            $bdE2eAllowed = $(if ($bdE2eCase.Existing) { @('BRAVO.local.config') } else { @() })
            $bdE2eLegacyExplicitFailures += @(Get-BRAVOSelfTestPreDeployRefusalProblems -Run $bdE2eRun -RuntimeRoot $bdE2eRuntime `
                -AllowedEntries $bdE2eAllowed -RequiredTexts @('BRAVO.Configurator', '-BackupDestination'))
            if (-not ($bdE2eRun.Throw.Contains('-Tag') -or $bdE2eRun.Throw.Contains('-ZipPath'))) {
                $bdE2eLegacyExplicitFailures += "$($bdE2eRun.Label) причина не підказує інший комплект (-Tag/-ZipPath)"
            }
            if ((Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime) -cne $bdE2eHashBefore) {
                $bdE2eLegacyExplicitFailures += "$($bdE2eRun.Label) BRAVO.local.config змінено або створено"
            }
        }
        Test-BRAVOCondition -Condition ($bdE2eLegacyExplicitFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerExplicitDestinationRejectsBundleWithoutConfigurator' `
            -Failure "явний -BackupDestination з комплектом без modules\BRAVO.Configurator (форма v5.2.4) має зупинитися ДО копіювання в каталог інсталяції (без VERSION.json і часткового runtime) з українською причиною (BRAVO.Configurator, -BackupDestination, -Tag/-ZipPath), не чіпаючи BRAVO.local.config: $($bdE2eLegacyExplicitFailures -join ' | ')"

        # (P1-1) Неявний шлях з комплектом без BRAVO.Configurator — поведінка
        # developer: -SeedLocalConfig копіює приклад; без нього файл не створюється;
        # наявний файл не змінюється; код 0 і розгорнутий VERSION.json.
        $bdE2eLegacyImplicitFailures = @()
        $bdE2eRuntime = New-BRAVOSelfTestE2ERuntimeRoot
        $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eLegacyBundle.ZipPath -Arguments @('-SeedLocalConfig')
        $bdE2eSitePath = Join-Path $bdE2eRuntime 'BRAVO.local.config'
        $bdE2eSiteBytes = $(if (Test-Path -LiteralPath $bdE2eSitePath -PathType Leaf) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($bdE2eSitePath)) } else { '' })
        if ($bdE2eRun.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $bdE2eRuntime 'VERSION.json')) -or
            $bdE2eSiteBytes -cne $bdE2eLegacyBundle.ExampleBytes -or -not $bdE2eRun.Output.Contains('з прикладу')) {
            $bdE2eLegacyImplicitFailures += "$($bdE2eRun.Label): exit=$($bdE2eRun.ExitCode) файл=приклад:$($bdE2eSiteBytes -ceq $bdE2eLegacyBundle.ExampleBytes) throw='$($bdE2eRun.Throw)'"
        }
        $bdE2eRuntime = New-BRAVOSelfTestE2ERuntimeRoot
        $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eLegacyBundle.ZipPath -Arguments @()
        if ($bdE2eRun.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $bdE2eRuntime 'VERSION.json')) -or
            (Test-Path -LiteralPath (Join-Path $bdE2eRuntime 'BRAVO.local.config'))) {
            $bdE2eLegacyImplicitFailures += "без параметрів: exit=$($bdE2eRun.ExitCode) throw='$($bdE2eRun.Throw)'"
        }
        $bdE2eRuntime = New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigLines @("'pathSettings.BackupRoot' = 'D:\ExampleArchive'")
        $bdE2eHashBefore = Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime
        $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eLegacyBundle.ZipPath -Arguments @('-SeedLocalConfig', '-Force')
        if ($bdE2eRun.ExitCode -ne 0 -or (Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime) -cne $bdE2eHashBefore) {
            $bdE2eLegacyImplicitFailures += "$($bdE2eRun.Label) з наявним файлом: exit=$($bdE2eRun.ExitCode) throw='$($bdE2eRun.Throw)'"
        }
        Test-BRAVOCondition -Condition ($bdE2eLegacyImplicitFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerImplicitSeedWithLegacyBundleKeepsDeveloperBehaviour' `
            -Failure "без -BackupDestination комплект без BRAVO.Configurator встановлюється, як на developer: -SeedLocalConfig копіює BRAVO.local.config.example («з прикладу»), без нього файл не створюється, наявний не змінюється, код 0: $($bdE2eLegacyImplicitFailures -join ' | ')"

        # (P3-1) Комплект з файлами BRAVO.Configurator, але без функцій профілю
        # напрямків (знімок developer): явний профіль відхиляється ДО копіювання
        # (перевірка за визначеннями функцій, а не лише за наявністю файлів);
        # неявний -SeedLocalConfig копіює приклад, як на developer.
        $bdE2eNoCapabilityFailures = @()
        $bdE2eNoCapabilityStripped = [IO.File]::ReadAllText((Join-Path $bdE2eRoot 'bundle_nocapability\modules\BRAVO.Configurator\BRAVO.Configurator.Presets.psm1'), [Text.Encoding]::UTF8)
        if ($bdE2eNoCapabilityStripped.Contains('function Get-BRAVOConfiguratorBackupDestinationProfile')) {
            $bdE2eNoCapabilityFailures += 'фікстура: функції профілю не вирізано з Presets.psm1'
        }
        foreach ($bdE2eCase in @(
            @{ Arguments = @('-SeedLocalConfig', '-BackupDestination', 'LocalOnly'); Existing = $false },
            @{ Arguments = @('-BackupDestination', 'LocalOnly', '-Force'); Existing = $true }
        )) {
            $bdE2eRuntime = $(if ($bdE2eCase.Existing) { New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigLines $bdE2eLocalOnlyLines } else { New-BRAVOSelfTestE2ERuntimeRoot })
            $bdE2eHashBefore = Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime
            $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eNoCapabilityBundle.ZipPath -Arguments $bdE2eCase.Arguments
            $bdE2eAllowed = $(if ($bdE2eCase.Existing) { @('BRAVO.local.config') } else { @() })
            $bdE2eNoCapabilityFailures += @(Get-BRAVOSelfTestPreDeployRefusalProblems -Run $bdE2eRun -RuntimeRoot $bdE2eRuntime `
                -AllowedEntries $bdE2eAllowed -RequiredTexts @('BRAVO.Configurator', '-BackupDestination'))
            if ((Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime) -cne $bdE2eHashBefore) {
                $bdE2eNoCapabilityFailures += "$($bdE2eRun.Label) BRAVO.local.config змінено або створено"
            }
        }
        $bdE2eRuntime = New-BRAVOSelfTestE2ERuntimeRoot
        $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eNoCapabilityBundle.ZipPath -Arguments @('-SeedLocalConfig')
        $bdE2eSitePath = Join-Path $bdE2eRuntime 'BRAVO.local.config'
        $bdE2eSiteBytes = $(if (Test-Path -LiteralPath $bdE2eSitePath -PathType Leaf) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($bdE2eSitePath)) } else { '' })
        if ($bdE2eRun.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $bdE2eRuntime 'VERSION.json')) -or
            $bdE2eSiteBytes -cne $bdE2eNoCapabilityBundle.ExampleBytes -or -not $bdE2eRun.Output.Contains('з прикладу') -or
            -not $bdE2eRun.Output.Contains('усі ключі в ньому закоментовані')) {
            $bdE2eNoCapabilityFailures += "$($bdE2eRun.Label): exit=$($bdE2eRun.ExitCode) файл=приклад:$($bdE2eSiteBytes -ceq $bdE2eNoCapabilityBundle.ExampleBytes) throw='$($bdE2eRun.Throw)'"
        }
        Test-BRAVOCondition -Condition ($bdE2eNoCapabilityFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerBundleWithoutDestinationFunctionsKeepsDeveloperBehaviour' `
            -Failure "комплект з файлами BRAVO.Configurator, але без функцій профілю напрямків ($($bdE2eCapabilityFunctions -join ', ')): явний -BackupDestination має зупинитися ДО копіювання (без VERSION.json), а неявний -SeedLocalConfig — скопіювати приклад з попередженням, як на developer: $($bdE2eNoCapabilityFailures -join ' | ')"

        # (P2-1/P2-2) Наявний BRAVO.local.config суперечить явному профілю ->
        # відмова ДО копіювання; файл не змінено. Для кожного профілю.
        $bdE2eConflictCases = @(
            @{ Destination = 'LocalOnly'; Arguments = @('-BackupDestination', 'LocalOnly', '-Force')
               Lines = @("'pathSettings.BackupRoot' = 'D:\ExampleArchive'"); Channels = @('SFTP', 'SMB') },
            @{ Destination = 'SambaOnly'; Arguments = @('-SeedLocalConfig', '-BackupDestination', 'SambaOnly', '-Force')
               Lines = @("'componentSettings.SFTP.Enabled' = `$true", "'componentSettings.SMB.Enabled' = `$true", "'componentSettings.SMB.ArchiveCopy' = `$true")
               Channels = @('SFTP') },
            @{ Destination = 'Cloud'; Arguments = @('-BackupDestination', 'Cloud', '-Force')
               Lines = @("'componentSettings.SFTP.Enabled' = `$true", "'componentSettings.SMB.Enabled' = `$true", "'componentSettings.SMB.ArchiveCopy' = `$true")
               Channels = @('SMB') },
            @{ Destination = 'CloudAndSamba'; Arguments = @('-SeedLocalConfig', '-BackupDestination', 'CloudAndSamba', '-Force')
               Lines = @("'componentSettings.SFTP.Enabled' = `$false", "'componentSettings.SMB.Enabled' = `$true", "'componentSettings.SMB.ArchiveCopy' = `$true")
               Channels = @('SFTP') },
            # Головні вимикачі збігаються, але копії на NAS ефективно немає
            # (SMB.ArchiveCopy = $false) — «Хмара + Samba» не в силі.
            @{ Destination = 'CloudAndSamba'; Arguments = @('-BackupDestination', 'CloudAndSamba', '-Force')
               Lines = @("'componentSettings.SFTP.Enabled' = `$true", "'componentSettings.SMB.Enabled' = `$true", "'componentSettings.SMB.ArchiveCopy' = `$false")
               Channels = @('SMB') },
            # Codex P1: SFTP увімкнено, але архів у хмару ефективно не
            # вивантажується (SFTP.ArchiveUpload = $false) — «Хмара» не в силі.
            @{ Destination = 'Cloud'; Arguments = @('-BackupDestination', 'Cloud', '-Force')
               Lines = @("'componentSettings.SFTP.Enabled' = `$true", "'componentSettings.SFTP.ArchiveUpload' = `$false", "'componentSettings.SMB.Enabled' = `$false")
               Channels = @('SFTP') },
            @{ Destination = 'CloudAndSamba'; Arguments = @('-SeedLocalConfig', '-BackupDestination', 'CloudAndSamba', '-Force')
               Lines = @("'componentSettings.SFTP.Enabled' = `$true", "'componentSettings.SFTP.ArchiveUpload' = `$false", "'componentSettings.SMB.Enabled' = `$true", "'componentSettings.SMB.ArchiveCopy' = `$true")
               Channels = @('SFTP') }
        )
        $bdE2eConflictFailures = @()
        foreach ($bdE2eCase in $bdE2eConflictCases) {
            $bdE2eRuntime = New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigLines $bdE2eCase.Lines
            $bdE2eActual = Get-BRAVOSelfTestEffectiveDestinations -LocalOverrides (Read-BRAVOSelfTestDestinationOverrides -ConfigDirectory $bdE2eRuntime).Overrides
            $bdE2eConflicts = @(Get-BRAVOSelfTestDestinationConflicts -Actual $bdE2eActual -Expected $bdE2eProfileDestinations[$bdE2eCase.Destination])
            if ((@($bdE2eConflicts) -join ',') -ne (@($bdE2eCase.Channels) -join ',')) {
                $bdE2eConflictFailures += "$($bdE2eCase.Destination) фікстура: суперечність '$($bdE2eConflicts -join ',')', очікувалась '$($bdE2eCase.Channels -join ',')'"
            }
            $bdE2eHashBefore = Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime
            $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eCurrentBundle.ZipPath -Arguments $bdE2eCase.Arguments
            $bdE2eConflictFailures += @(Get-BRAVOSelfTestPreDeployRefusalProblems -Run $bdE2eRun -RuntimeRoot $bdE2eRuntime `
                -AllowedEntries @('BRAVO.local.config') -RequiredTexts (@($bdE2eCase.Destination, 'BRAVO.local.config') + @($bdE2eCase.Channels)))
            if ((Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime) -cne $bdE2eHashBefore) {
                $bdE2eConflictFailures += "$($bdE2eRun.Label) BRAVO.local.config змінено"
            }
        }
        Test-BRAVOCondition -Condition ($bdE2eConflictFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerExplicitDestinationConflictRefusedBeforeDeploy' `
            -Failure "явний профіль (Cloud/CloudAndSamba/SambaOnly/LocalOnly), якому ЕФЕКТИВНО суперечить наявний BRAVO.local.config (SFTP.Enabled, SFTP.ArchiveUpload, SMB.Enabled чи SMB.ArchiveCopy не ті, що дав би -SeedLocalConfig цього профілю), має зупинити інсталяцію ДО копіювання в каталог інсталяції з українською причиною (профіль, BRAVO.local.config, канал) і не змінити файл: $($bdE2eConflictFailures -join ' | ')"

        # (P2-1) Нерозбірний BRAVO.local.config при явному профілі -> відмова ДО
        # копіювання з причиною, що називає профіль і файл; файл не змінено.
        $bdE2eBrokenText = "@{`r`n    'componentSettings.SFTP.Enabled' = `r`n"
        $bdE2eBrokenPremise = $false
        $bdE2eBrokenProbe = New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigText $bdE2eBrokenText
        try { [void](Read-BRAVOSelfTestDestinationOverrides -ConfigDirectory $bdE2eBrokenProbe) } catch { $bdE2eBrokenPremise = $true }
        $bdE2eBrokenFailures = @()
        if (-not $bdE2eBrokenPremise) { $bdE2eBrokenFailures += 'фікстура: канонічний reader прочитав нерозбірний файл без помилки' }
        foreach ($bdE2eArguments in @(
            , @('-BackupDestination', 'LocalOnly', '-Force')
            , @('-SeedLocalConfig', '-BackupDestination', 'SambaOnly', '-Force')
        )) {
            $bdE2eRuntime = New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigText $bdE2eBrokenText
            $bdE2eHashBefore = Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime
            $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eCurrentBundle.ZipPath -Arguments $bdE2eArguments
            $bdE2eBrokenFailures += @(Get-BRAVOSelfTestPreDeployRefusalProblems -Run $bdE2eRun -RuntimeRoot $bdE2eRuntime `
                -AllowedEntries @('BRAVO.local.config') -RequiredTexts @($bdE2eArguments[$bdE2eArguments.Count - 2], 'BRAVO.local.config'))
            if ((Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime) -cne $bdE2eHashBefore) {
                $bdE2eBrokenFailures += "$($bdE2eRun.Label) BRAVO.local.config змінено"
            }
        }
        Test-BRAVOCondition -Condition ($bdE2eBrokenFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerUnusableSiteConfigRefusedBeforeDeploy' `
            -Failure "нерозбірний BRAVO.local.config при явному -BackupDestination має зупинити інсталяцію ДО копіювання з українською причиною (профіль, BRAVO.local.config), файл не змінено: $($bdE2eBrokenFailures -join ' | ')"

        # (P2-1/P2-2) Наявний файл, ефективно сумісний з явним профілем -> код 0,
        # розгорнуто, файл не змінено, вивід підтверджує «профіль напрямків <X> у
        # силі» і не каже «НЕ застосовано» (як для LocalOnly у (4a)).
        $bdE2eCompatibleFailures = @()
        $bdE2eSeedToggle = $false
        foreach ($bdE2eDestination in @($bdExpectedProfiles.Keys)) {
            $bdE2eSeedToggle = -not $bdE2eSeedToggle
            $bdE2eLines = @("'pathSettings.BackupRoot' = 'D:\ExampleArchive'") + @(ConvertTo-BRAVOSelfTestSiteConfigLines -Overrides $bdProfiles[$bdE2eDestination].Overrides)
            $bdE2eRuntime = New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigLines $bdE2eLines
            $bdE2eActual = Get-BRAVOSelfTestEffectiveDestinations -LocalOverrides (Read-BRAVOSelfTestDestinationOverrides -ConfigDirectory $bdE2eRuntime).Overrides
            if (@(Get-BRAVOSelfTestDestinationConflicts -Actual $bdE2eActual -Expected $bdE2eProfileDestinations[$bdE2eDestination]).Count -ne 0) {
                $bdE2eCompatibleFailures += "$bdE2eDestination фікстура не відповідає профілю ефективно"
            }
            $bdE2eArguments = @('-BackupDestination', $bdE2eDestination, '-Force')
            if ($bdE2eSeedToggle) { $bdE2eArguments = @('-SeedLocalConfig') + $bdE2eArguments }
            $bdE2eHashBefore = Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime
            $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eCurrentBundle.ZipPath -Arguments $bdE2eArguments
            if ($bdE2eRun.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $bdE2eRuntime 'VERSION.json'))) {
                $bdE2eCompatibleFailures += "$($bdE2eRun.Label) exit=$($bdE2eRun.ExitCode) throw='$($bdE2eRun.Throw)'"
            }
            if ((Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime) -cne $bdE2eHashBefore) { $bdE2eCompatibleFailures += "$($bdE2eRun.Label) файл змінено" }
            if ($bdE2eRun.Output.Contains("профіль напрямків $bdE2eDestination НЕ застосовано")) {
                $bdE2eCompatibleFailures += "$($bdE2eRun.Label) вивід стверджує «$bdE2eDestination НЕ застосовано», хоча профіль ефективно в силі"
            }
            if (-not $bdE2eRun.Output.Contains("профіль напрямків $bdE2eDestination у силі")) {
                $bdE2eCompatibleFailures += "$($bdE2eRun.Label) вивід не підтверджує «профіль напрямків $bdE2eDestination у силі»"
            }
        }
        Test-BRAVOCondition -Condition ($bdE2eCompatibleFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerExplicitDestinationAcceptsCompatibleSiteConfig' `
            -Failure "явний профіль при наявному BRAVO.local.config, ефективно сумісному з ним, має пройти з кодом 0, не змінити файл і підтвердити «профіль напрямків <X> у силі» без «НЕ застосовано»: $($bdE2eCompatibleFailures -join ' | ')"

        # (P2-1) Повтор після відмови: оператор виправляє файл і повторює той
        # самий запуск — інсталяція проходить (відмова нічого не розгорнула);
        # ще один повтор на вже встановленому каталозі файл не змінює.
        $bdE2eRepeatFailures = @()
        $bdE2eRuntime = New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigLines @("'pathSettings.BackupRoot' = 'D:\ExampleArchive'")
        $bdE2eRepeatArguments = @('-BackupDestination', 'LocalOnly', '-Force')
        $bdE2eRunFirst = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eCurrentBundle.ZipPath -Arguments $bdE2eRepeatArguments
        if ($bdE2eRunFirst.ExitCode -eq 0 -or (Test-Path -LiteralPath (Join-Path $bdE2eRuntime 'VERSION.json'))) {
            $bdE2eRepeatFailures += "перший прогін (суперечливий файл): exit=$($bdE2eRunFirst.ExitCode) VERSION.json=$(Test-Path -LiteralPath (Join-Path $bdE2eRuntime 'VERSION.json'))"
        }
        [IO.File]::WriteAllText((Join-Path $bdE2eRuntime 'BRAVO.local.config'),
            ("@{`r`n" + ((@($bdE2eLocalOnlyLines) | ForEach-Object { '    ' + $_ }) -join "`r`n") + "`r`n}`r`n"), (New-Object Text.UTF8Encoding($false)))
        $bdE2eFixedHash = Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime
        $bdE2eRunSecond = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eCurrentBundle.ZipPath -Arguments $bdE2eRepeatArguments
        if ($bdE2eRunSecond.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $bdE2eRuntime 'VERSION.json')) -or
            (Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime) -cne $bdE2eFixedHash) {
            $bdE2eRepeatFailures += "другий прогін (виправлений файл): exit=$($bdE2eRunSecond.ExitCode) throw='$($bdE2eRunSecond.Throw)'"
        }
        $bdE2eRunThird = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eCurrentBundle.ZipPath -Arguments @('-SeedLocalConfig', '-BackupDestination', 'Cloud', '-Force')
        if ((Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime) -cne $bdE2eFixedHash) {
            $bdE2eRepeatFailures += "третій прогін змінив BRAVO.local.config: exit=$($bdE2eRunThird.ExitCode)"
        }
        Test-BRAVOCondition -Condition ($bdE2eRepeatFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerRetryAfterRefusalSucceeds' `
            -Failure "відмова через суперечливий BRAVO.local.config не має нічого розгортати, тож після виправлення файла той самий запуск проходить; повторні запуски файл не змінюють: $($bdE2eRepeatFailures -join ' | ')"

        # (P2-2) Явний профіль без -SeedLocalConfig і без BRAVO.local.config ->
        # діють дефолти, що суперечать кожному профілю -> відмова в кроці 0: ні
        # staging-каталогу, ні каталогу інсталяції.
        $bdE2eStepZeroFailures = @()
        foreach ($bdE2eDestination in @($bdExpectedProfiles.Keys)) {
            if (@(Get-BRAVOSelfTestDestinationConflicts -Actual $bdE2eDefaultDestinations -Expected $bdE2eProfileDestinations[$bdE2eDestination]).Count -eq 0) {
                $bdE2eStepZeroFailures += "$bdE2eDestination передумова: дефолти не суперечать профілю"
            }
            $bdE2eRuntime = New-BRAVOSelfTestE2ERuntimeRoot
            $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eCurrentBundle.ZipPath -Arguments @('-BackupDestination', $bdE2eDestination)
            $bdE2eStepZeroFailures += @(Get-BRAVOSelfTestPreDeployRefusalProblems -Run $bdE2eRun -RuntimeRoot $bdE2eRuntime `
                -AllowedEntries @() -RequiredTexts @($bdE2eDestination, '-SeedLocalConfig'))
            if ($bdE2eRun.StagingCreated -or (Test-Path -LiteralPath $bdE2eRuntime)) {
                $bdE2eStepZeroFailures += "$($bdE2eRun.Label) відмова не в кроці 0: staging=$($bdE2eRun.StagingCreated) каталог=$(Test-Path -LiteralPath $bdE2eRuntime)"
            }
        }
        Test-BRAVOCondition -Condition ($bdE2eStepZeroFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerExplicitDestinationWithoutSiteConfigFailsAtStep0' `
            -Failure "явний -BackupDestination (будь-який) без -SeedLocalConfig і без BRAVO.local.config лишає дефолти, що суперечать профілю, — відмова в кроці 0 (до staging/завантаження) з українською причиною (профіль, -SeedLocalConfig): $($bdE2eStepZeroFailures -join ' | ')"

        # (Codex P1) Комплект, чий архів і .sha256 узгоджені, але модулі не
        # збігаються з його RUNTIME_MANIFEST.json (локальний архів зі «своїм»
        # .sha256 або підміна staged-файлів): код комплекту не імпортується до
        # канонічної перевірки цілісності. Явний профіль — відмова ДО копіювання
        # (без VERSION.json); неявний -SeedLocalConfig — відмова до імпорту
        # Configurator у кроці 4, файл не створено. Маркер у кожному .psm1.
        $bdE2eTamperFailures = @()
        $bdE2eTamperedBundle = New-BRAVOSelfTestInstallBundle -Name 'tampered' -ModuleDirectories $bdE2eCurrentModules -TamperAfterManifest
        foreach ($bdE2eCase in @(
            @{ Arguments = @('-BackupDestination', 'LocalOnly', '-Force'); Existing = $true },
            @{ Arguments = @('-SeedLocalConfig', '-BackupDestination', 'SambaOnly'); Existing = $false }
        )) {
            if (Test-Path -LiteralPath $bdE2eTamperedBundle.MarkerPath) { Remove-Item -LiteralPath $bdE2eTamperedBundle.MarkerPath -Force }
            $bdE2eRuntime = $(if ($bdE2eCase.Existing) { New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigLines $bdE2eLocalOnlyLines } else { New-BRAVOSelfTestE2ERuntimeRoot })
            $bdE2eHashBefore = Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime
            $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eTamperedBundle.ZipPath -Arguments $bdE2eCase.Arguments
            $bdE2eAllowed = $(if ($bdE2eCase.Existing) { @('BRAVO.local.config') } else { @() })
            $bdE2eTamperFailures += @(Get-BRAVOSelfTestPreDeployRefusalProblems -Run $bdE2eRun -RuntimeRoot $bdE2eRuntime `
                -AllowedEntries $bdE2eAllowed -RequiredTexts @('RUNTIME_MANIFEST.json', 'BRAVO.Configurator.Presets.psm1'))
            if (Test-Path -LiteralPath $bdE2eTamperedBundle.MarkerPath) { $bdE2eTamperFailures += "$($bdE2eRun.Label) модуль підміненого комплекту імпортовано" }
            if ((Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime) -cne $bdE2eHashBefore) {
                $bdE2eTamperFailures += "$($bdE2eRun.Label) BRAVO.local.config змінено або створено"
            }
        }
        if (Test-Path -LiteralPath $bdE2eTamperedBundle.MarkerPath) { Remove-Item -LiteralPath $bdE2eTamperedBundle.MarkerPath -Force }
        $bdE2eRuntime = New-BRAVOSelfTestE2ERuntimeRoot
        $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eTamperedBundle.ZipPath -Arguments @('-SeedLocalConfig')
        if ($bdE2eRun.ExitCode -eq 0 -or -not $bdE2eRun.Throw.Contains('RUNTIME_MANIFEST.json') -or $bdE2eRun.Throw -notmatch '[Ѐ-ӿ]' -or
            (Test-Path -LiteralPath $bdE2eTamperedBundle.MarkerPath) -or (Test-Path -LiteralPath (Join-Path $bdE2eRuntime 'BRAVO.local.config'))) {
            $bdE2eTamperFailures += "$($bdE2eRun.Label): exit=$($bdE2eRun.ExitCode) імпортовано=$(Test-Path -LiteralPath $bdE2eTamperedBundle.MarkerPath) файл=$(Test-Path -LiteralPath (Join-Path $bdE2eRuntime 'BRAVO.local.config')) throw='$($bdE2eRun.Throw)'"
        }
        Test-BRAVOCondition -Condition ($bdE2eTamperFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerRefusesTamperedBundleBeforeImport' `
            -Failure "комплект, модулі якого не збігаються з RUNTIME_MANIFEST.json (архів і .sha256 узгоджені), не можна імпортувати: явний -BackupDestination — відмова ДО копіювання з українською причиною (RUNTIME_MANIFEST.json, підмінений файл), неявний -SeedLocalConfig — зупинка до імпорту Configurator без створення BRAVO.local.config: $($bdE2eTamperFailures -join ' | ')"

        # (Codex P1, раунд 2) TOCTOU: $StagingRoot може бути доступний на запис
        # звичайному користувачеві, тож код комплекту для перевірки кроку 1 не
        # імпортується звідти. Маркер у кожному .psm1 записує каталог імпорту:
        # жодного імпорту з $StagingRoot, імпорт кроку 1 — з окремого
        # каталогу, якого після прогону вже немає.
        $bdE2ePrivateFailures = @()
        $bdE2eMarkedBundle = New-BRAVOSelfTestInstallBundle -Name 'marked' -ModuleDirectories $bdE2eCurrentModules -MarkImports
        $bdE2eRuntime = New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigLines $bdE2eLocalOnlyLines
        $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eMarkedBundle.ZipPath -Arguments @('-BackupDestination', 'LocalOnly', '-Force')
        $bdE2eImportDirs = @($(if (Test-Path -LiteralPath $bdE2eMarkedBundle.MarkerPath) {
            [IO.File]::ReadAllLines($bdE2eMarkedBundle.MarkerPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique }))
        $bdE2eRuntimeLeaf = Split-Path -Leaf $bdE2eRuntime
        $bdE2eStagingImports = @($bdE2eImportDirs | Where-Object { $_.Contains($bdE2eRun.StagingLeaf) })
        $bdE2ePrivateImports = @($bdE2eImportDirs | Where-Object { -not $_.Contains($bdE2eRun.StagingLeaf) -and -not $_.Contains($bdE2eRuntimeLeaf) })
        if ($bdE2eRun.ExitCode -ne 0) { $bdE2ePrivateFailures += "$($bdE2eRun.Label) exit=$($bdE2eRun.ExitCode) throw='$($bdE2eRun.Throw)'" }
        foreach ($bdE2eImportDir in $bdE2eStagingImports) { $bdE2ePrivateFailures += "імпорт із `$StagingRoot: $bdE2eImportDir" }
        if ($bdE2ePrivateImports.Count -eq 0) { $bdE2ePrivateFailures += "імпорту кроку 1 з окремого каталогу не було (імпорти: $($bdE2eImportDirs -join ', '))" }
        foreach ($bdE2eImportDir in $bdE2ePrivateImports) {
            if (Test-Path -LiteralPath $bdE2eImportDir) { $bdE2ePrivateFailures += "каталог перевірки не видалено: $bdE2eImportDir" }
        }
        Test-BRAVOCondition -Condition ($bdE2ePrivateFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerStep1ImportsFromPrivateVerifiedCopy' `
            -Failure "явний -BackupDestination: код комплекту для перевірки кроку 1 не імпортується з `$StagingRoot (доступний на запис іншим — підміна між перевіркою цілісності й Import-Module), а з приватної перевіреної копії, яку видалено після перевірки: $($bdE2ePrivateFailures -join ' | ')"

        # (Codex P2, раунд 2) BRAVO.local.config, змінений МІЖ перевіркою кроку 1
        # і копіюванням (гачок харнеса в Write-Step '2.'), — відмова ДО першого
        # запису в каталог інсталяції: без VERSION.json і без копіювання; файл
        # лишається таким, яким його залишили.
        $bdE2eMutationFailures = @()
        $bdE2eMutationSource = Join-Path $bdE2eRoot 'site_mutation.config'
        [IO.File]::WriteAllText($bdE2eMutationSource, "@{`r`n    'pathSettings.BackupRoot' = 'D:\ExampleArchive'`r`n}`r`n", (New-Object Text.UTF8Encoding($false)))
        $bdE2eMutationHash = (Get-FileHash -LiteralPath $bdE2eMutationSource -Algorithm SHA256).Hash
        foreach ($bdE2eCase in @(
            @{ Arguments = @('-BackupDestination', 'LocalOnly', '-Force'); Existing = $true },
            @{ Arguments = @('-SeedLocalConfig', '-BackupDestination', 'LocalOnly'); Existing = $false }
        )) {
            $bdE2eRuntime = $(if ($bdE2eCase.Existing) { New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigLines $bdE2eLocalOnlyLines } else { New-BRAVOSelfTestE2ERuntimeRoot })
            $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eCurrentBundle.ZipPath -Arguments $bdE2eCase.Arguments `
                -SiteMutationSource $bdE2eMutationSource
            $bdE2eMutationFailures += @(Get-BRAVOSelfTestPreDeployRefusalProblems -Run $bdE2eRun -RuntimeRoot $bdE2eRuntime `
                -AllowedEntries @('BRAVO.local.config') -RequiredTexts @('BRAVO.local.config', 'змінився', 'Нічого не розгорнуто'))
            if ((Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime) -cne $bdE2eMutationHash) {
                $bdE2eMutationFailures += "$($bdE2eRun.Label) BRAVO.local.config після відмови не той, що залишив оператор"
            }
        }
        Test-BRAVOCondition -Condition ($bdE2eMutationFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerSiteConfigChangedAfterCheckRefusedBeforeCopy' `
            -Failure "BRAVO.local.config, змінений чи створений після перевірки -BackupDestination у кроці 1, має зупинити інсталяцію ДО першого запису в каталог інсталяції (без VERSION.json і копіювання) з українською причиною, файл не змінено: $($bdE2eMutationFailures -join ' | ')"

        # (Codex P2, раунд 2) Можливості BRAVO.Configuration/BRAVO.Discovery
        # звіряються за визначеннями функцій, а не лише за наявністю .psd1:
        # комплект без Get-BRAVOEffectiveStorageConfiguration — явний профіль
        # відхиляється ДО копіювання з назвою відсутньої функції.
        $bdE2eNoStorageFailures = @()
        $bdE2eNoStorageBundle = New-BRAVOSelfTestInstallBundle -Name 'nostorage' -ModuleDirectories $bdE2eCurrentModules `
            -StripFunctions @('Get-BRAVOEffectiveStorageConfiguration')
        if ([IO.File]::ReadAllText((Join-Path $bdE2eRoot 'bundle_nostorage\modules\BRAVO.Discovery\BRAVO.Discovery.psm1'), [Text.Encoding]::UTF8).Contains('function Get-BRAVOEffectiveStorageConfiguration')) {
            $bdE2eNoStorageFailures += 'фікстура: Get-BRAVOEffectiveStorageConfiguration не вирізано з BRAVO.Discovery.psm1'
        }
        $bdE2eNoStorageHead = [IO.File]::ReadAllBytes((Join-Path $bdE2eRoot 'bundle_nostorage\modules\BRAVO.Discovery\BRAVO.Discovery.psm1'))
        if ($bdE2eNoStorageHead.Length -lt 3 -or $bdE2eNoStorageHead[0] -ne 0xEF -or $bdE2eNoStorageHead[1] -ne 0xBB -or $bdE2eNoStorageHead[2] -ne 0xBF) {
            $bdE2eNoStorageFailures += 'фікстура: переписаний BRAVO.Discovery.psm1 без UTF-8 BOM (Windows PowerShell 5.1 розбере його як ANSI)'
        }
        foreach ($bdE2eCase in @(
            @{ Arguments = @('-SeedLocalConfig', '-BackupDestination', 'LocalOnly'); Existing = $false },
            @{ Arguments = @('-BackupDestination', 'LocalOnly', '-Force'); Existing = $true }
        )) {
            $bdE2eRuntime = $(if ($bdE2eCase.Existing) { New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigLines $bdE2eLocalOnlyLines } else { New-BRAVOSelfTestE2ERuntimeRoot })
            $bdE2eHashBefore = Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime
            $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eNoStorageBundle.ZipPath -Arguments $bdE2eCase.Arguments
            $bdE2eAllowed = $(if ($bdE2eCase.Existing) { @('BRAVO.local.config') } else { @() })
            $bdE2eNoStorageFailures += @(Get-BRAVOSelfTestPreDeployRefusalProblems -Run $bdE2eRun -RuntimeRoot $bdE2eRuntime `
                -AllowedEntries $bdE2eAllowed -RequiredTexts @('-BackupDestination', 'Get-BRAVOEffectiveStorageConfiguration'))
            if ((Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime) -cne $bdE2eHashBefore) {
                $bdE2eNoStorageFailures += "$($bdE2eRun.Label) BRAVO.local.config змінено або створено"
            }
        }
        Test-BRAVOCondition -Condition ($bdE2eNoStorageFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerExplicitDestinationRequiresConfigurationFunctions' `
            -Failure "комплект без функції BRAVO.Discovery/BRAVO.Configuration, яку викликає перевірка профілю (Get-BRAVOEffectiveStorageConfiguration), має відхиляти явний -BackupDestination ДО копіювання з назвою функції в причині: $($bdE2eNoStorageFailures -join ' | ')"

        # (Codex P2, раунд 3) Можливість — це ЕКСПОРТОВАНА функція: визначення,
        # якого модуль не експортує (Export-ModuleMember/FunctionsToExport),
        # викликати не можна. Явний профіль: після імпорту приватної копії
        # Get-Command мусить знайти кожну потрібну функцію з її модуля; інакше
        # відмова ДО копіювання з назвою функції. Фікстура: визначення
        # Get-BRAVOConfiguratorBackupDestinationProfile є, експорту немає.
        $bdE2eNoExportFailures = @()
        $bdE2eNoExportBundle = New-BRAVOSelfTestInstallBundle -Name 'noexport' -ModuleDirectories $bdE2eCurrentModules `
            -UnexportFunctions @('Get-BRAVOConfiguratorBackupDestinationProfile')
        $bdE2eNoExportPresets = [IO.File]::ReadAllText((Join-Path $bdE2eRoot 'bundle_noexport\modules\BRAVO.Configurator\BRAVO.Configurator.Presets.psm1'), [Text.Encoding]::UTF8)
        if (-not $bdE2eNoExportPresets.Contains('function Get-BRAVOConfiguratorBackupDestinationProfile') -or
            $bdE2eNoExportPresets.Contains("'Get-BRAVOConfiguratorBackupDestinationProfile'")) {
            $bdE2eNoExportFailures += 'фікстура: визначення має лишитися, а ім''я — зникнути з Export-ModuleMember у Presets.psm1'
        }
        foreach ($bdE2eCase in @(
            @{ Arguments = @('-SeedLocalConfig', '-BackupDestination', 'LocalOnly'); Existing = $false },
            @{ Arguments = @('-BackupDestination', 'LocalOnly', '-Force'); Existing = $true }
        )) {
            $bdE2eRuntime = $(if ($bdE2eCase.Existing) { New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigLines $bdE2eLocalOnlyLines } else { New-BRAVOSelfTestE2ERuntimeRoot })
            $bdE2eHashBefore = Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime
            $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eNoExportBundle.ZipPath -Arguments $bdE2eCase.Arguments
            $bdE2eAllowed = $(if ($bdE2eCase.Existing) { @('BRAVO.local.config') } else { @() })
            $bdE2eNoExportFailures += @(Get-BRAVOSelfTestPreDeployRefusalProblems -Run $bdE2eRun -RuntimeRoot $bdE2eRuntime `
                -AllowedEntries $bdE2eAllowed -RequiredTexts @('-BackupDestination', 'Get-BRAVOConfiguratorBackupDestinationProfile', 'Нічого не розгорнуто'))
            if ((Get-BRAVOSelfTestE2ESiteHash -RuntimeRoot $bdE2eRuntime) -cne $bdE2eHashBefore) {
                $bdE2eNoExportFailures += "$($bdE2eRun.Label) BRAVO.local.config змінено або створено"
            }
        }
        Test-BRAVOCondition -Condition ($bdE2eNoExportFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerExplicitDestinationRequiresExportedFunctions' `
            -Failure "комплект, модуль якого визначає, але не експортує потрібну функцію (Get-BRAVOConfiguratorBackupDestinationProfile), має відхиляти явний -BackupDestination ДО копіювання (без VERSION.json) з назвою функції в причині: $($bdE2eNoExportFailures -join ' | ')"

        # (Codex P2, раунд 4) Звірка експорту спирається на екземпляр модуля,
        # який щойно повернув Import-Module -PassThru з $ModuleRoot, а не на
        # Get-Command за ModuleName: однойменний модуль з іншого шляху, уже
        # завантажений у сесію, не повинен «закрити» функцію, якої свіжий
        # екземпляр не експортує. Справжні функції інсталятора виконуються в
        # дочірньому процесі над мінімальними фейковими модулями: застарілий
        # корінь (усе експортує) імпортовано заздалегідь, свіжий корінь не
        # експортує Get-BRAVOConfiguratorBackupDestinationProfile → відмова з
        # назвою функції; повний свіжий корінь при тому самому застарілому → без відмови.
        $bdE2eStaleFailures = @()
        $bdE2eStaleDefinitions = @($bdInstallAst.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
            @('Get-BRAVOInstallBackupDestinationRequiredFunctions', 'Import-BRAVOInstallBackupDestinationModules') -contains $_.Name
        } | ForEach-Object { $_.Extent.Text })
        if ($bdE2eStaleDefinitions.Count -ne 2) { $bdE2eStaleFailures += "функції інсталятора не знайдено ($($bdE2eStaleDefinitions.Count) з 2)" }
        $bdE2eStaleModules = [ordered]@{
            'BRAVO.Configurator\BRAVO.Configurator.Persistence' = @('Get-BRAVOConfiguratorProductionOverrideState', 'New-BRAVOConfiguratorSeedLocalConfig')
            'BRAVO.Configurator\BRAVO.Configurator.Presets'     = @('Get-BRAVOConfiguratorBackupDestinationProfile', 'Test-BRAVOConfiguratorBackupDestinationEffective')
            'BRAVO.Configuration\BRAVO.Configuration'           = @('Get-BRAVODefaultConfiguration', 'Resolve-BRAVORawConfiguration')
            'BRAVO.Discovery\BRAVO.Discovery'                   = @('Get-BRAVOEffectiveStorageConfiguration')
        }
        $bdE2eStaleRoots = @{}
        foreach ($bdE2eStaleRootName in @('stale', 'fresh_noexport', 'fresh_full')) {
            $bdE2eStaleRoot = Join-Path $bdE2eRoot ('modroot_' + $bdE2eStaleRootName)
            $bdE2eStaleRoots[$bdE2eStaleRootName] = $bdE2eStaleRoot
            foreach ($bdE2eStaleModule in @($bdE2eStaleModules.Keys)) {
                $bdE2eStaleBase = Join-Path (Join-Path $bdE2eStaleRoot 'modules') $bdE2eStaleModule
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $bdE2eStaleBase) -Force)
                $bdE2eStaleNames = @($bdE2eStaleModules[$bdE2eStaleModule])
                $bdE2eStaleExports = @($bdE2eStaleNames | Where-Object {
                    -not ($bdE2eStaleRootName -eq 'fresh_noexport' -and $_ -eq 'Get-BRAVOConfiguratorBackupDestinationProfile') })
                $bdE2eStaleText = ((@($bdE2eStaleNames | ForEach-Object { 'function ' + $_ + " { return '" + $bdE2eStaleRootName + "' }" }) +
                    @('Export-ModuleMember -Function @(' + ((@($bdE2eStaleExports | ForEach-Object { "'" + $_ + "'" })) -join ', ') + ')')) -join "`r`n") + "`r`n"
                [IO.File]::WriteAllText($bdE2eStaleBase + '.psm1', $bdE2eStaleText, (New-Object Text.UTF8Encoding($true)))
                if ($bdE2eStaleModule -notlike 'BRAVO.Configurator\*') {
                    $bdE2eStaleLeaf = Split-Path -Leaf $bdE2eStaleBase
                    [IO.File]::WriteAllText($bdE2eStaleBase + '.psd1', ("@{`r`n    RootModule = '" + $bdE2eStaleLeaf + ".psm1'`r`n    ModuleVersion = '1.0.0'`r`n    FunctionsToExport = '*'`r`n}`r`n"),
                        (New-Object Text.UTF8Encoding($true)))
                }
            }
        }
        $bdE2eStaleChild = Join-Path $bdE2eRoot 'Invoke-StaleModuleExportCheck.ps1'
        [IO.File]::WriteAllText($bdE2eStaleChild, ((@(
            'param([string]$StaleRoot, [string]$FreshRoot)',
            'Set-StrictMode -Version 2.0',
            '$ErrorActionPreference = ''Stop'''
        ) + $bdE2eStaleDefinitions + @(
            'foreach ($stalePath in @(''modules\BRAVO.Configurator\BRAVO.Configurator.Persistence.psm1'', ''modules\BRAVO.Configurator\BRAVO.Configurator.Presets.psm1'', ''modules\BRAVO.Configuration\BRAVO.Configuration.psd1'', ''modules\BRAVO.Discovery\BRAVO.Discovery.psd1'')) {',
            '    Import-Module -Name (Join-Path $StaleRoot $stalePath) -ErrorAction Stop',
            '}',
            'try { Import-BRAVOInstallBackupDestinationModules -ModuleRoot $FreshRoot -Destination LocalOnly -BeforeDeploy; ''RESULT: accepted'' } catch { ''RESULT: refused '' + $_.Exception.Message }'
        )) -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($true)))
        foreach ($bdE2eStaleCase in @(
            @{ Fresh = 'fresh_noexport'; Refused = $true },
            @{ Fresh = 'fresh_full'; Refused = $false }
        )) {
            $bdE2eStaleOutput = (@(& $bdE2eHostPath -NoProfile -NonInteractive -File $bdE2eStaleChild -StaleRoot $bdE2eStaleRoots['stale'] `
                -FreshRoot $bdE2eStaleRoots[$bdE2eStaleCase.Fresh] 2>&1 | ForEach-Object { [string]$_ }) -join ' ')
            if ($bdE2eStaleCase.Refused) {
                if (-not $bdE2eStaleOutput.Contains('RESULT: refused') -or -not $bdE2eStaleOutput.Contains('Get-BRAVOConfiguratorBackupDestinationProfile') -or
                    -not $bdE2eStaleOutput.Contains('Нічого не розгорнуто')) {
                    $bdE2eStaleFailures += "$($bdE2eStaleCase.Fresh): очікувано відмову з назвою функції, отримано: $bdE2eStaleOutput"
                }
            } elseif (-not $bdE2eStaleOutput.Contains('RESULT: accepted')) {
                $bdE2eStaleFailures += "$($bdE2eStaleCase.Fresh): очікувано без відмови, отримано: $bdE2eStaleOutput"
            }
        }
        Test-BRAVOCondition -Condition ($bdE2eStaleFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerExportCheckIgnoresStaleSameNameModule' `
            -Failure "звірка експорту має спиратися на щойно імпортований з `$ModuleRoot екземпляр модуля, а не на однойменний модуль з іншого шляху, уже завантажений у сесію: $($bdE2eStaleFailures -join ' | ')"

        # (Codex P2, раунд 3) Відбиток BRAVO.local.config і те, що прочитав
        # канонічний reader у кроці 1, — ті самі байти. Фікстура: імпорт
        # Persistence.psm1 (між зняттям знімка й читанням) підміняє живий файл
        # (сумісний LocalOnly) на суперечливий. Рішення кроку 1 має спиратися на
        # знімок (сумісний), а підміну має зупинити звірка перед першим записом
        # у каталог інсталяції («змінився»), а не читання живого файла після
        # відбитка («не в силі»).
        $bdE2eSnapshotFailures = @()
        $bdE2eRuntime = New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigLines $bdE2eLocalOnlyLines
        $bdE2eSwappedText = "@{`r`n    'pathSettings.BackupRoot' = 'D:\ExampleArchive'`r`n}`r`n"
        $bdE2eSnapshotHook = "[IO.File]::WriteAllText('" + (Join-Path $bdE2eRuntime 'BRAVO.local.config').Replace("'", "''") + "', '" +
            $bdE2eSwappedText.Replace("'", "''") + "', (New-Object Text.UTF8Encoding(`$false)))"
        $bdE2eSnapshotBundle = New-BRAVOSelfTestInstallBundle -Name 'swapsite' -ModuleDirectories $bdE2eCurrentModules -PersistenceImportHook $bdE2eSnapshotHook
        $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eSnapshotBundle.ZipPath -Arguments @('-BackupDestination', 'LocalOnly', '-Force')
        $bdE2eSnapshotFailures += @(Get-BRAVOSelfTestPreDeployRefusalProblems -Run $bdE2eRun -RuntimeRoot $bdE2eRuntime `
            -AllowedEntries @('BRAVO.local.config') -RequiredTexts @('BRAVO.local.config', 'змінився', 'Нічого не розгорнуто'))
        if ($bdE2eRun.Throw.Contains('не в силі')) {
            $bdE2eSnapshotFailures += "$($bdE2eRun.Label) крок 1 прочитав живий файл після відбитка (відмова «не в силі»), а не знімок"
        }
        Test-BRAVOCondition -Condition ($bdE2eSnapshotFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerStep1ReadsFingerprintedSiteConfigSnapshot' `
            -Failure "крок 1 має читати знімок BRAVO.local.config, з байтів якого знято відбиток, а зміну живого файла після знімка — зупиняти перед першим записом у каталог інсталяції («змінився»): $($bdE2eSnapshotFailures -join ' | ')"

        # (Codex P1, раунд 3) Приватний каталог перевірки кроку 1 лежить у
        # $env:SystemRoot\Temp (не %TEMP% користувача, де той має FILE_DELETE_CHILD
        # і міг би перейменувати каталог) і без явного DACL успадкував би права:
        # процес того самого користувача без елевації підмінив би .psm1 між
        # перевіркою цілісності й Import-Module. Статично: каталог створює лише
        # New-BRAVOInstallPrivateDirectory (DACL з SetAccessRuleProtection, лише
        # S-1-5-32-544 і S-1-5-18, власник S-1-5-32-544, повторна перевірка
        # Get-Acl), і цей виклик стоїть до ПЕРШОГО запису в каталог, до
        # перевірки цілісності й до імпорту. На Windows — ще й фактичний DACL.
        $bdE2eAclFailures = @()
        $bdE2eAclTry = @($bdE2eMainTry)
        $bdE2eAclCreates = @($(if ($bdE2eAclTry.Count -eq 1) { $bdE2eAclTry[0].Body.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and [string]$node.GetCommandName() -eq 'New-BRAVOInstallPrivateDirectory' }, $true) }))
        $bdE2eAclPrivateVariables = @('verifiedBundleRoot')
        foreach ($bdE2eAclAssignment in @($(if ($bdE2eAclTry.Count -eq 1) { $bdE2eAclTry[0].Body.FindAll({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] }, $true) }))) {
            if ($bdE2eAclAssignment.Right.Extent.Text -match '(?i)\$verifiedBundleRoot\b' -and $bdE2eAclPrivateVariables -notcontains $bdE2eAclAssignment.Left.VariablePath.UserPath) {
                $bdE2eAclPrivateVariables += $bdE2eAclAssignment.Left.VariablePath.UserPath
            }
        }
        $bdE2eAclPrivatePattern = '(?i)\$(' + ((@($bdE2eAclPrivateVariables) | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\b'
        $bdE2eAclWriteCommands = @('New-Item', 'Copy-Item', 'Move-Item', 'Expand-Archive', 'Set-Content', 'Add-Content', 'Out-File',
            'Assert-BRAVOInstallBundleIntegrity', 'Import-Module', 'Import-BRAVOInstallBackupDestinationModules',
            'Get-BRAVOInstallSiteComponentSettings', 'Get-BRAVOInstallBackupDestinationMissingCapabilities')
        $bdE2eAclUses = @($(if ($bdE2eAclTry.Count -eq 1) { $bdE2eAclTry[0].Body.FindAll({ param($node)
            (($node -is [Management.Automation.Language.CommandAst] -and $bdE2eAclWriteCommands -contains [string]$node.GetCommandName()) -or
             ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Extent.Text -match '^(?i)(Write\w*|Create\w*|Copy|Move|ExtractToDirectory)$')) -and
            $node.Extent.Text -match $bdE2eAclPrivatePattern }, $true) }))
        if ($bdE2eAclCreates.Count -ne 1) {
            $bdE2eAclFailures += "New-BRAVOInstallPrivateDirectory у головному try: $($bdE2eAclCreates.Count) викликів (очікувався рівно один)"
        } else {
            $bdE2eAclCreate = $bdE2eAclCreates[0]
            if ($bdE2eAclCreate.Extent.Text -notmatch '(?i)-Path\s+\$verifiedBundleRoot\b') {
                $bdE2eAclFailures += "New-BRAVOInstallPrivateDirectory не над `$verifiedBundleRoot: $($bdE2eAclCreate.Extent.Text)"
            }
            if (@($bdE2eAclUses | Where-Object { $_ -is [Management.Automation.Language.CommandAst] -and [string]$_.GetCommandName() -eq 'Assert-BRAVOInstallBundleIntegrity' }).Count -eq 0) {
                $bdE2eAclFailures += 'харнес: перевірки цілісності приватної копії не знайдено'
            }
            foreach ($bdE2eAclUse in $bdE2eAclUses) {
                if ($bdE2eAclUse.Extent.StartOffset -lt $bdE2eAclCreate.Extent.EndOffset) {
                    $bdE2eAclFailures += "рядок $($bdE2eAclUse.Extent.StartLineNumber): запис/перевірка/імпорт у приватному каталозі до New-BRAVOInstallPrivateDirectory: $($bdE2eAclUse.Extent.Text)"
                }
                if ($bdE2eAclUse -is [Management.Automation.Language.CommandAst] -and [string]$bdE2eAclUse.GetCommandName() -eq 'New-Item' -and
                    $bdE2eAclUse.Extent.Text -match '(?i)-Path\s+\$verifiedBundleRoot\b') {
                    $bdE2eAclFailures += "рядок $($bdE2eAclUse.Extent.StartLineNumber): корінь приватного каталогу створено без захищеного DACL: $($bdE2eAclUse.Extent.Text)"
                }
            }
        }
        # Основа — $env:SystemRoot\Temp через Get-BRAVOInstallPrivateDirectoryBase,
        # не GetTempPath(); відсутність основи — відмова.
        $bdE2eAclRootAssignments = @($(if ($bdE2eAclTry.Count -eq 1) { $bdE2eAclTry[0].Body.FindAll({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq 'verifiedBundleRoot' }, $true) }))
        if ($bdE2eAclRootAssignments.Count -ne 1 -or $bdE2eAclRootAssignments[0].Right.Extent.Text -notmatch '^Join-Path \(Get-BRAVOInstallPrivateDirectoryBase\) ' -or
            $bdE2eAclRootAssignments[0].Right.Extent.Text -match 'GetTempPath') {
            $bdE2eAclFailures += "`$verifiedBundleRoot має будуватися як Join-Path (Get-BRAVOInstallPrivateDirectoryBase) ...: $(@($bdE2eAclRootAssignments | ForEach-Object { $_.Extent.Text }) -join ' | ')"
        }
        $bdE2eAclBaseFunction = @($bdInstallAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-BRAVOInstallPrivateDirectoryBase' }, $true))
        if ($bdE2eAclBaseFunction.Count -ne 1) {
            $bdE2eAclFailures += 'Get-BRAVOInstallPrivateDirectoryBase не визначено в інсталяторі'
        } else {
            $bdE2eAclBaseBody = $bdE2eAclBaseFunction[0].Body.Extent.Text
            if (-not $bdE2eAclBaseBody.Contains('$env:SystemRoot') -or -not $bdE2eAclBaseBody.Contains("Join-Path `$systemRoot 'Temp'") -or
                $bdE2eAclBaseBody.Contains('GetTempPath') -or $bdE2eAclBaseBody.Contains('$env:TEMP') -or -not $bdE2eAclBaseBody.Contains('throw')) {
                $bdE2eAclFailures += 'Get-BRAVOInstallPrivateDirectoryBase: основа — Join-Path $env:SystemRoot ''Temp'' з відмовою за відсутності, без GetTempPath/$env:TEMP'
            }
            # Поведінка: без $env:SystemRoot чи з неіснуючим — відмова з українською причиною.
            $bdE2eAclBaseCases = & {
                param([string]$FunctionText, [string]$MissingRoot)
                . ([scriptblock]::Create($FunctionText))
                $savedSystemRoot = $env:SystemRoot
                $outcomes = @()
                try {
                    foreach ($caseRoot in @('', $MissingRoot)) {
                        $env:SystemRoot = $caseRoot
                        try { [void](Get-BRAVOInstallPrivateDirectoryBase); $outcomes += "'$caseRoot': без відмови" } catch {
                            if ($_.Exception.Message -notmatch '[\u0400-\u04FF]') { $outcomes += "'$caseRoot': причина не українська" }
                        }
                    }
                } finally { $env:SystemRoot = $savedSystemRoot }
                return @($outcomes)
            } $bdE2eAclBaseFunction[0].Extent.Text (Join-Path $bdE2eRoot ('no_systemroot_' + [guid]::NewGuid().ToString('N')))
            foreach ($bdE2eAclBaseCase in @($bdE2eAclBaseCases)) { $bdE2eAclFailures += "Get-BRAVOInstallPrivateDirectoryBase $bdE2eAclBaseCase" }
        }
        $bdE2eAclFunction = @($bdInstallAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-BRAVOInstallPrivateDirectory' }, $true))
        if ($bdE2eAclFunction.Count -ne 1) {
            $bdE2eAclFailures += 'New-BRAVOInstallPrivateDirectory не визначено в інсталяторі'
        } else {
            $bdE2eAclBody = $bdE2eAclFunction[0].Body.Extent.Text
            foreach ($bdE2eAclRequired in @('SetAccessRuleProtection($true, $false)', "'S-1-5-32-544'", "'S-1-5-18'", 'SetOwner(', 'CreateDirectory', 'Get-Acl', 'AreAccessRulesProtected', 'IsInherited', 'throw')) {
                if (-not $bdE2eAclBody.Contains($bdE2eAclRequired)) { $bdE2eAclFailures += "New-BRAVOInstallPrivateDirectory: немає '$bdE2eAclRequired'" }
            }
            # Каталог створюється одразу з DACL (без вікна з успадкованими
            # правами %TEMP%), а не New-Item + Set-Acl.
            if (@($bdE2eAclFunction[0].Body.FindAll({ param($node)
                $node -is [Management.Automation.Language.CommandAst] -and @('New-Item', 'Set-Acl', 'mkdir', 'md') -contains [string]$node.GetCommandName() }, $true)).Count -ne 0) {
                $bdE2eAclFailures += 'New-BRAVOInstallPrivateDirectory: каталог має створюватися одразу з DACL (CreateDirectory з DirectorySecurity), без New-Item/Set-Acl'
            }
            if ($bdE2eIsWindows) {
                # Фактичний DACL — справжньою функцією інсталятора у дочірній області.
                $bdE2eAclProbe = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_SELFTEST_DEST_ACL_' + [guid]::NewGuid().ToString('N'))
                $bdE2eAclResult = & {
                    param([string]$FunctionText, [string]$ProbePath)
                    . ([scriptblock]::Create($FunctionText))
                    try {
                        New-BRAVOInstallPrivateDirectory -Path $ProbePath
                        return [pscustomobject]@{ Threw = $false; Message = ''; Acl = (Get-Acl -LiteralPath $ProbePath) }
                    } catch {
                        return [pscustomobject]@{ Threw = $true; Message = $_.Exception.Message; Acl = $null }
                    }
                } $bdE2eAclFunction[0].Extent.Text $bdE2eAclProbe
                try {
                    if ($bdE2eIsElevated) {
                        if ($bdE2eAclResult.Threw -or $null -eq $bdE2eAclResult.Acl) {
                            $bdE2eAclFailures += "елевований Windows: каталог не створено: $($bdE2eAclResult.Message)"
                        } else {
                            $bdE2eAclRules = @($bdE2eAclResult.Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
                            $bdE2eAclSids = @($bdE2eAclRules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
                            if (-not $bdE2eAclResult.Acl.AreAccessRulesProtected) { $bdE2eAclFailures += 'успадкування DACL не вимкнено' }
                            if (@($bdE2eAclRules | Where-Object { $_.IsInherited }).Count -ne 0) { $bdE2eAclFailures += 'є успадковані правила' }
                            if (($bdE2eAclSids -join ',') -ne 'S-1-5-18,S-1-5-32-544') { $bdE2eAclFailures += "SID у DACL: $($bdE2eAclSids -join ',')" }
                            if (@($bdE2eAclRules | Where-Object { [string]$_.AccessControlType -ne 'Allow' -or
                                ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl }).Count -ne 0) {
                                $bdE2eAclFailures += 'правила DACL не FullControl/Allow'
                            }
                            $bdE2eAclOwner = $bdE2eAclResult.Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
                            if ($bdE2eAclOwner -ne 'S-1-5-32-544') { $bdE2eAclFailures += "власник: $bdE2eAclOwner" }
                        }
                    } elseif (-not $bdE2eAclResult.Threw -or $bdE2eAclResult.Message -notmatch '[\u0400-\u04FF]') {
                        # Без елевації DACL «лише Administrators/SYSTEM» з
                        # власником Administrators не встановити — fail closed.
                        $bdE2eAclFailures += "неелевований Windows: очікувалась відмова з українською причиною, отримано Threw=$($bdE2eAclResult.Threw) '$($bdE2eAclResult.Message)'"
                    }
                } finally {
                    if (Test-Path -LiteralPath $bdE2eAclProbe) { Remove-Item -LiteralPath $bdE2eAclProbe -Recurse -Force -ErrorAction SilentlyContinue }
                }
            }
        }
        Test-BRAVOCondition -Condition ($bdE2eAclFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerPrivateVerifyDirectoryProtectedBeforeFirstWrite' `
            -Failure "приватний каталог перевірки кроку 1 має створюватися одразу із захищеним DACL (без успадкування; лише BUILTIN\Administrators і NT AUTHORITY\SYSTEM, власник Administrators) до першого запису, перевірки цілісності й імпорту; невдача — відмова: $($bdE2eAclFailures -join ' | ')"

        # Регресійний запобіжник (не RED): модулі комплекту не імпортуються до
        # гейтів SHA-256 і провенансу — маркер у кожному .psm1 комплекту лишається
        # нествореним; статично: жоден Import-Module з $staged* не стоїть до
        # рішення про канал релізу.
        $bdE2eTrustFailures = @()
        $bdE2eBadShaBundle = New-BRAVOSelfTestInstallBundle -Name 'badsha' -ModuleDirectories $bdE2eCurrentModules -MarkImports -CorruptChecksum
        $bdE2eBadProvenanceBundle = New-BRAVOSelfTestInstallBundle -Name 'badprovenance' -ModuleDirectories $bdE2eCurrentModules -MarkImports -SourceCommit 'not-a-commit'
        foreach ($bdE2eCase in @(
            @{ Bundle = $bdE2eBadShaBundle; Expect = 'SHA-256' },
            @{ Bundle = $bdE2eBadProvenanceBundle; Expect = 'провенанс' }
        )) {
            $bdE2eRuntime = New-BRAVOSelfTestE2ERuntimeRoot -SiteConfigLines $bdE2eLocalOnlyLines
            $bdE2eRun = Invoke-BRAVOSelfTestInstallE2E -RuntimeRoot $bdE2eRuntime -ZipPath $bdE2eCase.Bundle.ZipPath -Arguments @('-BackupDestination', 'LocalOnly', '-Force')
            $bdE2eTrustFailures += @(Get-BRAVOSelfTestPreDeployRefusalProblems -Run $bdE2eRun -RuntimeRoot $bdE2eRuntime `
                -AllowedEntries @('BRAVO.local.config') -RequiredTexts @($bdE2eCase.Expect))
            if (Test-Path -LiteralPath $bdE2eCase.Bundle.MarkerPath) { $bdE2eTrustFailures += "$($bdE2eCase.Expect): модуль комплекту імпортовано до гейта" }
        }
        $bdE2eChannelGate = @($bdInstallAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and [string]$node.GetCommandName() -eq 'Get-BRAVODeployReleaseChannelDecision'
        }, $true) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
        $bdE2eEarlyStagedImports = @($bdInstallAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            ([string]$node.GetCommandName() -eq 'Import-Module' -or $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot) -and
            $node.Extent.Text -match '(?i)\$staged'
        }, $true) | Where-Object { $bdE2eChannelGate.Count -ne 1 -or $_.Extent.StartOffset -lt $bdE2eChannelGate[0].Extent.StartOffset })
        if ($bdE2eChannelGate.Count -ne 1) { $bdE2eTrustFailures += 'Get-BRAVODeployReleaseChannelDecision не знайдено' }
        foreach ($bdE2eImport in $bdE2eEarlyStagedImports) { $bdE2eTrustFailures += "рядок $($bdE2eImport.Extent.StartLineNumber): $($bdE2eImport.Extent.Text)" }
        # (Codex P1) Кожен імпорт коду комплекту в головному try (Import-Module,
        # dot-source, Get-BRAVOInstallSiteComponentSettings,
        # Import-BRAVOInstallBackupDestinationModules) має бути домінований
        # викликом Assert-BRAVOInstallBundleIntegrity над тим самим коренем:
        # виклик — окремий оператор раніше в тому самому чи зовнішньому блоці.
        # Сама перевірка — канонічна Test-BRAVORuntimeManifestIntegrity з
        # BRAVO_RUNTIME_GUARD.ps1, без власного переліку хешів в інсталяторі.
        $bdE2eIntegrityCalls = @($bdInstallAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and [string]$node.GetCommandName() -eq 'Assert-BRAVOInstallBundleIntegrity' -and
            -not (Test-BRAVOSelfTestInsideFunction -Node $node)
        }, $true))
        $bdE2eBundleImports = @($bdInstallAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and -not (Test-BRAVOSelfTestInsideFunction -Node $node) -and
            (@('Import-Module', 'Get-BRAVOInstallSiteComponentSettings', 'Import-BRAVOInstallBackupDestinationModules') -contains [string]$node.GetCommandName() -or
                $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot) -and
            $node.Extent.Text -match '(?i)\$(staged|StagingRoot|RuntimeRoot|configuratorModuleRoot|verifiedBundle)\b'
        }, $true))
        # (Codex P1, раунд 2) Корінь імпорту — змінна аргументу -ModuleRoot чи
        # -Name (перша змінна); $configuratorModuleRoot = $RuntimeRoot. Корінь
        # не може походити з $StagingRoot/$staged (транзитивно за присвоєннями):
        # той каталог може бути доступний на запис іншим. Імпорт кроку 1 — з
        # приватного каталогу Get-BRAVOInstallPrivateDirectoryBase ($env:SystemRoot\Temp), і цілісність
        # перевіряється над ТИМ самим коренем (домінування нижче).
        function Get-BRAVOSelfTestInstallVariableOrigin {
            param([string]$VariableName, [int]$Depth = 0)
            $originText = @()
            if ($Depth -gt 6) { return @() }
            foreach ($assignment in @($bdInstallAst.FindAll({ param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -eq $VariableName }, $true))) {
                $originText += $assignment.Right.Extent.Text
                foreach ($reference in @($assignment.Right.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] }, $true))) {
                    if ($reference.VariablePath.UserPath -ne $VariableName) {
                        $originText += @(Get-BRAVOSelfTestInstallVariableOrigin -VariableName $reference.VariablePath.UserPath -Depth ($Depth + 1))
                    }
                }
            }
            return @($originText)
        }
        $bdE2ePrivateRootImports = 0
        foreach ($bdE2eImport in $bdE2eBundleImports) {
            $bdE2eRootElement = @($(if (@('Get-BRAVOInstallSiteComponentSettings', 'Import-BRAVOInstallBackupDestinationModules') -contains [string]$bdE2eImport.GetCommandName()) {
                $bdE2eModuleRootIndex = -1
                for ($bdE2eIndex = 0; $bdE2eIndex -lt $bdE2eImport.CommandElements.Count - 1; $bdE2eIndex++) {
                    if ($bdE2eImport.CommandElements[$bdE2eIndex].Extent.Text -eq '-ModuleRoot') { $bdE2eModuleRootIndex = $bdE2eIndex + 1 }
                }
                if ($bdE2eModuleRootIndex -ge 0) { $bdE2eImport.CommandElements[$bdE2eModuleRootIndex] }
            } else { $bdE2eImport }))
            $bdE2eRootVariables = @($(if ($bdE2eRootElement.Count -eq 1) {
                @($bdE2eRootElement[0].FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] }, $true)) |
                    Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1 }))
            $bdE2eImportRoot = $(if ($bdE2eRootVariables.Count -eq 1) { '$' + $bdE2eRootVariables[0].VariablePath.UserPath } else { '' })
            if ($bdE2eImportRoot -eq '$configuratorModuleRoot') { $bdE2eImportRoot = '$RuntimeRoot' }
            $bdE2eImportOrigin = @($(if ($bdE2eImportRoot -ne '') { Get-BRAVOSelfTestInstallVariableOrigin -VariableName $bdE2eImportRoot.Substring(1) }))
            if ($bdE2eImportRoot -eq '' -or $bdE2eImportRoot -match '(?i)^\$(staged|StagingRoot)$' -or
                @($bdE2eImportOrigin | Where-Object { $_ -match '(?i)\$(staged|StagingRoot)\b' }).Count -gt 0) {
                $bdE2eTrustFailures += "рядок $($bdE2eImport.Extent.StartLineNumber): імпорт коду комплекту з `$StagingRoot (або корінь не визначено: '$bdE2eImportRoot'): $($bdE2eImport.Extent.Text)"
                continue
            }
            if ($bdE2eImportRoot -ne '$RuntimeRoot' -and @($bdE2eImportOrigin | Where-Object { $_ -match 'Get-BRAVOInstallPrivateDirectoryBase' }).Count -gt 0) {
                $bdE2ePrivateRootImports++
            }
            $bdE2eDominated = $false
            foreach ($bdE2eIntegrityCall in $bdE2eIntegrityCalls) {
                $bdE2eRootArgument = @($bdE2eIntegrityCall.CommandElements | Where-Object {
                    $_ -is [Management.Automation.Language.VariableExpressionAst] })
                if ($bdE2eRootArgument.Count -ne 1 -or $bdE2eRootArgument[0].Extent.Text -ne $bdE2eImportRoot) { continue }
                $bdE2eCallStatement = $bdE2eIntegrityCall.Parent
                while ($null -ne $bdE2eCallStatement -and -not ($bdE2eCallStatement.Parent -is [Management.Automation.Language.StatementBlockAst] -or
                    $bdE2eCallStatement.Parent -is [Management.Automation.Language.NamedBlockAst])) { $bdE2eCallStatement = $bdE2eCallStatement.Parent }
                if ($null -eq $bdE2eCallStatement -or -not ($bdE2eCallStatement -is [Management.Automation.Language.PipelineAst])) { continue }
                $bdE2eBlock = $bdE2eCallStatement.Parent
                if ($bdE2eCallStatement.Extent.EndOffset -le $bdE2eImport.Extent.StartOffset -and
                    $bdE2eBlock.Extent.StartOffset -le $bdE2eImport.Extent.StartOffset -and $bdE2eBlock.Extent.EndOffset -ge $bdE2eImport.Extent.EndOffset) {
                    $bdE2eDominated = $true
                    break
                }
            }
            if (-not $bdE2eDominated) {
                $bdE2eTrustFailures += "рядок $($bdE2eImport.Extent.StartLineNumber): імпорт коду комплекту ($bdE2eImportRoot) без попередньої Assert-BRAVOInstallBundleIntegrity над тим самим коренем: $($bdE2eImport.Extent.Text)"
            }
        }
        if ($bdE2eBundleImports.Count -eq 0) { $bdE2eTrustFailures += 'харнес: імпортів коду комплекту в головному try не знайдено' }
        if ($bdE2ePrivateRootImports -eq 0) { $bdE2eTrustFailures += 'імпорт кроку 1 не з приватного каталогу Get-BRAVOInstallPrivateDirectoryBase ($env:SystemRoot\Temp)' }
        $bdE2eIntegrityFunction = @($bdInstallAst.FindAll({
            param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-BRAVOInstallBundleIntegrity'
        }, $true))
        if ($bdE2eIntegrityFunction.Count -ne 1 -or
            @($bdE2eIntegrityFunction[0].Body.FindAll({ param($node)
                $node -is [Management.Automation.Language.CommandAst] -and [string]$node.GetCommandName() -eq 'Test-BRAVORuntimeManifestIntegrity' }, $true)).Count -ne 1 -or
            -not $bdE2eIntegrityFunction[0].Body.Extent.Text.Contains('BRAVO_RUNTIME_GUARD.ps1') -or
            @($bdInstallAst.FindAll({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-BRAVORuntimeManifestIntegrity' }, $true)).Count -ne 0) {
            $bdE2eTrustFailures += 'Assert-BRAVOInstallBundleIntegrity має викликати канонічну Test-BRAVORuntimeManifestIntegrity з BRAVO_RUNTIME_GUARD.ps1 комплекту (без власної копії перевірки)'
        }
        Test-BRAVOCondition -Condition ($bdE2eTrustFailures.Count -eq 0) `
            -Name 'BackupDestinations/InstallerNeverImportsBundleBeforeTrustGates' `
            -Failure "модулі розпакованого чи розгорнутого комплекту не можна імпортувати до перевірки SHA-256, провенансу, каналу релізу й цілісності за RUNTIME_MANIFEST.json: $($bdE2eTrustFailures -join ' | ')"
    } finally {
        if (Test-Path -LiteralPath $bdE2eRoot) {
            Remove-Item -LiteralPath $bdE2eRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ------------------------------------------------------------
# (5) Health: свідомо вимкнений напрямок — один INFO-рядок.
# ------------------------------------------------------------
$bdHealthText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1'), [Text.Encoding]::UTF8)
$bdHealthLinesModule = New-BRAVOSelfTestRuntimeModule -SourceText $bdHealthText `
    -FunctionNames @('Get-BRAVOHealthDisabledDestinationLines')
$bdHealthLineCases = & $bdHealthLinesModule {
    Set-StrictMode -Version Latest
    $both = [pscustomobject]@{
        SFTP = [pscustomobject]@{ Enabled = $false; ArchiveUpload = $false }
        SMB = [pscustomobject]@{ Enabled = $false; ArchiveCopy = $false }
    }
    $none = [pscustomobject]@{
        SFTP = [pscustomobject]@{ Enabled = $true; ArchiveUpload = $true }
        SMB = [pscustomobject]@{ Enabled = $true; ArchiveCopy = $false }
    }
    [pscustomobject]@{
        Both = @(Get-BRAVOHealthDisabledDestinationLines -StorageEffective $both)
        None = @(Get-BRAVOHealthDisabledDestinationLines -StorageEffective $none)
        Null = @(Get-BRAVOHealthDisabledDestinationLines -StorageEffective $null)
    }
}
Test-BRAVOCondition -Condition (
    @($bdHealthLineCases.Both).Count -eq 2 -and
    [string]@($bdHealthLineCases.Both)[0].Text -eq 'Хмара (SFTP): вимкнено конфігурацією' -and
    [string]@($bdHealthLineCases.Both)[1].Text -eq 'NAS/SMB: вимкнено конфігурацією' -and
    @($bdHealthLineCases.None).Count -eq 0 -and
    @($bdHealthLineCases.Null).Count -eq 0
) -Name 'BackupDestinations/HealthDisabledDestinationLinePerMasterSwitch' `
    -Failure "рядок «вимкнено конфігурацією» — рівно один на напрямок, вимкнений головним вимикачем (SMB.Enabled=`$true з ArchiveCopy=`$false рядка не дає), і жодного до завантаження конфігурації"

# Звіт «ВСЕ СПРАВНО»: «Лише локально» — INFO-рядки замість SFTP/SMB, без WARNING.
$bdSuccessModule = New-BRAVOSelfTestRuntimeModule -SourceText $bdHealthText `
    -FunctionNames @('New-SlackSuccessMessage', 'Get-BRAVOHealthDisabledDestinationLines')
$bdSuccessMessage = [string](& $bdSuccessModule {
    Set-StrictMode -Version Latest
    $script:NotificationProvider = 'slack'
    $script:healthNotInstalledComponents = @()
    $script:healthEmptySourceComponents = @()
    $script:healthEmptySourceWarningComponents = @()
    $script:healthLatestArchives = @{}
    $global:ScriptVersion = 'self-test'; $global:ScriptBuildId = 'self-test'
    $backupMonitoring = [pscustomobject]@{
        MaxBackupAgeHours = 24; InstitutionName = 'Example Lab'; InstitutionCode = 'LAB1'
        SFTP = [pscustomobject]@{ Enabled = $true; CheckBAZASynchronization = $true; CheckArchiveUploads = $true }
        SMB = [pscustomobject]@{ Enabled = $true; CheckArchiveCopies = $true }
    }
    $storageEffective = [pscustomobject]@{
        SFTP = [pscustomobject]@{ Enabled = $false; ArchiveUpload = $false }
        SMB = [pscustomobject]@{ Enabled = $false; ArchiveCopy = $false }
    }
    $bazaAppLocalHealthEnabled = $true; $bazaWWWLocalHealthEnabled = $false
    $bazaAppSFTPHealthEnabled = $false; $bazaWWWSFTPHealthEnabled = $false
    $healthCheckStarted = Get-Date; $healthCheckStartedUtc = $healthCheckStarted.ToUniversalTime(); $healthLogFile = 'self-test.log'
    function Get-HostInformation { return $null }
    function Get-EnabledBackupComponentNames { return @('MODEL') }
    function Get-BRAVOHealthLatestBackupSummary { return [pscustomobject]@{ Found = $false; TimestampText = ''; AgeText = ''; ComponentLines = @() } }
    function Format-BRAVOOperatorStatusLine { param($Status, $Icon, $Name, $Detail) return "[$Status] $Name — $Detail" }
    function New-BRAVOOperatorNotificationMessage { param($Severity, $Operation, $ResultLines) return ("$Severity`n" + (@($ResultLines) -join "`n")) }
    New-SlackSuccessMessage -Duration ([timespan]::FromSeconds(1))
})
$bdSuccessLines = @($bdSuccessMessage -split "`n")
Test-BRAVOCondition -Condition (
    $bdSuccessLines[0] -eq 'SUCCESS' -and
    @($bdSuccessLines | Where-Object { $_ -eq ':information_source: Хмара (SFTP): вимкнено конфігурацією' }).Count -eq 1 -and
    @($bdSuccessLines | Where-Object { $_ -eq ':information_source: NAS/SMB: вимкнено конфігурацією' }).Count -eq 1 -and
    @($bdSuccessLines | Where-Object { $_ -match '\[(SUCCESS|WARNING)\] (SFTP|SMB|BAZA_APP|BAZA_WWW) —' }).Count -eq 0 -and
    @($bdSuccessLines | Where-Object { $_ -match '(?i)прострочен|WARNING' }).Count -eq 0 -and
    $bdSuccessMessage.Contains('[SUCCESS] Local')
) -Name 'BackupDestinations/HealthSuccessMessageShowsDisabledDestinationsAsInfo' `
    -Failure "звіт «ВСЕ СПРАВНО» для «Лише локально» має містити по одному INFO-рядку на вимкнений напрямок і жодного рядка SFTP/SMB/BAZA SFTP чи WARNING: $bdSuccessMessage"

# Підсумок консолі (Complete-BRAVOHealthResult): той самий рядок, без
# попереджень і без зміни коду завершення.
$bdSummaryModule = New-BRAVOSelfTestRuntimeModule -SourceText $bdHealthText `
    -FunctionNames @('Complete-BRAVOHealthResult', 'Get-BRAVOHealthDisabledDestinationLines', 'Get-BRAVOHealthSummaryResult')
$bdSummaryCases = @{}
foreach ($bdSummaryCase in @('LocalOnly', 'Cloud')) {
    $bdSummaryCases[$bdSummaryCase] = & $bdSummaryModule {
        param([string]$Case)
        Set-StrictMode -Version 2.0
        $script:BRAVOHealthConsoleReady = $true
        $script:BRAVOHealthNotificationStepEnabled = $false
        $script:BRAVOHealthSftpStepEnabled = ($Case -eq 'Cloud')
        $script:BRAVOHealthSmbStepEnabled = $false
        $script:BRAVOHealthStepCurrent = 3; $script:BRAVOHealthStepTotal = 4
        $script:BRAVOHealthStepOkCount = 3; $script:BRAVOHealthStepWarningCount = 0; $script:BRAVOHealthStepErrorCount = 0
        $script:BRAVOWarningCount = 0
        $script:BRAVOToolManifest = $null
        $script:healthLatestArchives = @{}
        $script:healthNotInstalledComponents = @()
        $script:summaryFields = New-Object System.Collections.Generic.List[string]
        $SuppressHeader = $false
        $healthCheckStarted = Get-Date
        $stateRoot = 'C:\ExampleState'; $backupRootPath = 'C:\ExampleArchive'
        $storageEffective = [pscustomobject]@{
            SFTP = [pscustomobject]@{ Enabled = ($Case -eq 'Cloud'); ArchiveUpload = ($Case -eq 'Cloud') }
            SMB = [pscustomobject]@{ Enabled = $false; ArchiveCopy = $false }
        }
        function Resolve-BRAVOExitCode { return 0 }
        function Get-BRAVOExitCodeName { param($Code) return 'Success' }
        function Write-BRAVOOperationStatus { }
        function Complete-BRAVOProgress { }
        function Format-BRAVODuration { param($Duration) return '1 с' }
        function Write-BRAVOResultHeader { param($Status) $script:summaryFields.Add("HEADER=$Status") }
        function Write-BRAVOResultField { param($Label, $Value) $script:summaryFields.Add("$Label=$Value") }
        function Write-BRAVOResultBlankLine { }
        function Write-BRAVOResultSection { param($Title) $script:summaryFields.Add("SECTION=$Title") }
        function Write-BRAVOConsoleDetail { param($Message) $script:summaryFields.Add("DETAIL=$Message") }
        function Write-BRAVOResultFooter { }
        $completed = Complete-BRAVOHealthResult -Result ([pscustomobject]@{
            Status = 'Healthy'; IssueCount = 0; LocalVerified = $true
            SftpVerified = ($Case -eq 'Cloud'); SmbVerified = $false; LogPath = ''
        })
        [pscustomobject]@{ Fields = @($script:summaryFields); ExitCode = $script:healthRuntimeExitCode; Status = [string]$completed.Status }
    } $bdSummaryCase
}
$bdLocalOnlyFields = @($bdSummaryCases['LocalOnly'].Fields)
$bdCloudFields = @($bdSummaryCases['Cloud'].Fields)
Test-BRAVOCondition -Condition (
    @($bdLocalOnlyFields | Where-Object { $_ -eq 'Хмара (SFTP)=вимкнено конфігурацією' }).Count -eq 1 -and
    @($bdLocalOnlyFields | Where-Object { $_ -eq 'NAS/SMB=вимкнено конфігурацією' }).Count -eq 1 -and
    @($bdLocalOnlyFields | Where-Object { $_ -eq 'HEADER=УСПІШНО' }).Count -eq 1 -and
    @($bdLocalOnlyFields | Where-Object { $_ -eq 'Попереджень=0' }).Count -eq 1 -and
    @($bdLocalOnlyFields | Where-Object { $_ -match '^(SFTP|NAS/SMB)=(True|False)$' }).Count -eq 0 -and
    [int]$bdSummaryCases['LocalOnly'].ExitCode -eq 0 -and
    @($bdCloudFields | Where-Object { $_ -eq 'NAS/SMB=вимкнено конфігурацією' }).Count -eq 1 -and
    @($bdCloudFields | Where-Object { $_ -like 'Хмара (SFTP)=*' }).Count -eq 0 -and
    @($bdCloudFields | Where-Object { $_ -eq 'SFTP=True' }).Count -eq 1
) -Name 'BackupDestinations/HealthConsoleSummaryShowsDisabledDestinations' `
    -Failure "підсумок Health має показати «вимкнено конфігурацією» для кожного вимкненого напрямку (і лише для нього), без попереджень і з кодом 0; Лише локально: $($bdLocalOnlyFields -join ' | ') ||| Хмара: $($bdCloudFields -join ' | ')"

# ------------------------------------------------------------
# (6) Сторож вихідних каналів: кожне місце, що відкриває SFTP-сесію
# (WinSCP .NET Session або процес WinSCP.com) чи підключає NAS/SMB
# (New-PSDrive), у runtime-коді досяжне лише під canonical-вимикачем
# storageEffective.SFTP/SMB.
# ------------------------------------------------------------
# Метод (статичний, AST): від місця каналу вгору по дереву шукається
#   * if/elseif, умова САМЕ тієї гілки, у тілі якої стоїть місце, містить
#     вимикач; else і пізніші elseif умовою попередньої гілки захищені лише
#     тоді, коли та умова — рівно заперечення вимикача (-not/! вимикач):
#     туди потік доходить, лише коли вимикач істинний;
#   * попередній у тому самому блоці if з вимикачем, що завершує потік
#     (return/exit/continue/break/throw) — ранній вихід;
#   * ліва частина -and, коли місце праворуч.
# Дійшовши до визначення функції, перевірка повторюється для КОЖНОГО
# виклику цієї функції в runtime-коді (усі файли); функція без викликів —
# не захищена. Вимикач — canonical вирази $storageEffective.SFTP.Enabled /
# .ArchiveUpload, $storageEffective.SMB.Enabled / .ArchiveCopy,
# $bazaSyncEffective (його SftpEnabled уже містить SFTP.Enabled, див.
# перевірку нижче), а також змінні файлу, кожне присвоєння яких читає
# такий вираз (похідні прапорці на кшталт $sftpTransferEnabled).
# Межі методу: це перевірка структури, а не семантики (умову з вимикачем,
# що не блокує канал, вона не відрізнить), і SMB-канал розпізнається за
# New-PSDrive — єдиним способом, яким runtime підключає NAS з креденшлами.
# Тому поряд стоять поведінкові перевірки canonical-предикатів.

$script:BRAVOSelfTestOutboundExceptions = @(
    [pscustomobject]@{
        File = 'BRAVO_BAZA_RECONCILE.ps1'; Function = '<script>'
        Reason = 'ручна звірка BAZA з SFTP: запускає оператор, не автоматичний прогін'
    },
    [pscustomobject]@{
        File = 'modules\BRAVO.DataRestore\BRAVO.DataRestore.Runtime.ps1'; Function = 'Invoke-BRAVODataRestoreWinSCPScript'
        Reason = 'ручне відновлення з SFTP (BRAVO_DATA_RESTORE.ps1 -Source SFTP): запускає оператор'
    }
)

function Get-BRAVOSelfTestOutboundSourceSet {
    # Runtime-код: усі .ps1/.psm1 комплекту, крім self-test, CI та Tools.
    param([string]$Root)
    $sources = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { @('.ps1', '.psm1') -contains $_.Extension.ToLowerInvariant() })) {
        $relative = $file.FullName.Substring($Root.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('/', '\')
        if ($relative -match '^(selftest|ci|Tools|\.git|\.claude)\\' -or $relative -eq 'BRAVO_SELF_TEST.ps1') {
            continue
        }
        $sources += [pscustomobject]@{ File = $relative; Text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) }
    }
    return $sources
}

function Get-BRAVOSelfTestOutboundSites {
    param([object[]]$Sources)

    $canonical = @{
        SFTP = '(?i)\$storageEffective\.SFTP\.(Enabled|ArchiveUpload)\b|\$bazaSyncEffective\b'
        SMB  = '(?i)\$storageEffective\.SMB\.(Enabled|ArchiveCopy)\b'
    }
    $parsed = @()
    foreach ($source in $Sources) {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput([string]$source.Text, [ref]$tokens, [ref]$errors)
        $parsed += [pscustomobject]@{ File = [string]$source.File; Ast = $ast }
    }

    # Індекс викликів функцій за іменем (усі файли) і кеш вимикачів файлу.
    $context = @{ Calls = @{}; Regex = @{}; Canonical = $canonical }
    foreach ($entry in $parsed) {
        foreach ($command in @($entry.Ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))) {
            $name = $command.GetCommandName()
            if ([string]::IsNullOrEmpty($name)) { continue }
            $key = $name.ToLowerInvariant()
            if (-not $context.Calls.ContainsKey($key)) { $context.Calls[$key] = New-Object System.Collections.Generic.List[object] }
            $context.Calls[$key].Add($command)
        }
    }

    $sites = @()
    foreach ($entry in $parsed) {
        $found = @($entry.Ast.FindAll({
            param($node)
            ($node -is [Management.Automation.Language.CommandAst] -and (
                ([string]$node.GetCommandName() -eq 'New-Object' -and $node.Extent.Text -match '(?i)WinSCP\.Session\b(?!Options)') -or
                ([string]$node.GetCommandName() -eq 'New-PSDrive') -or
                ([string]$node.GetCommandName() -eq 'Start-Process' -and $node.Extent.Text -match '(?i)winscp') -or
                ($node.InvocationOperator -ne [Management.Automation.Language.TokenKind]::Unknown -and
                    $node.CommandElements[0].Extent.Text -match '(?i)winscp'))) -or
            ($node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -match '(?i)\.FileName$' -and $node.Right.Extent.Text -match '(?i)winscp') -or
            ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Static -and
                $node.Expression.Extent.Text -match '(?i)WinSCP\.Session\]' -and $node.Member.Extent.Text -eq 'new')
        }, $true))
        foreach ($site in $found) {
            $kind = $(if ($site -is [Management.Automation.Language.CommandAst] -and [string]$site.GetCommandName() -eq 'New-PSDrive') { 'SMB' } else { 'SFTP' })
            $function = Get-BRAVOSelfTestOutboundEnclosingFunction -Node $site
            $gate = Test-BRAVOSelfTestOutboundGated -Node $site -Kind $kind -Context $context -Depth 0 -Visited @{}
            $sites += [pscustomobject]@{
                Kind = $kind
                File = $entry.File
                Line = $site.Extent.StartLineNumber
                Function = $(if ($null -ne $function) { $function.Name } else { '<script>' })
                Gated = [bool]$gate.Gated
                Evidence = [string]$gate.Evidence
            }
        }
    }
    return $sites
}

function Get-BRAVOSelfTestOutboundEnclosingFunction {
    param($Node)
    $parent = $Node.Parent
    while ($null -ne $parent) {
        if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) { return $parent }
        $parent = $parent.Parent
    }
    return $null
}

function Get-BRAVOSelfTestOutboundGateRegex {
    # Canonical вимикачі + похідні змінні файлу (кожне присвоєння читає вимикач).
    param($Node, [string]$Kind, [hashtable]$Context)
    $rootAst = $Node
    while ($null -ne $rootAst.Parent) { $rootAst = $rootAst.Parent }
    $cacheKey = [string]$Kind + '|' + [string]$rootAst.Extent.File + '|' + [string]$rootAst.GetHashCode()
    if ($Context.Regex.ContainsKey($cacheKey)) { return $Context.Regex[$cacheKey] }

    $regex = [string]$Context.Canonical[$Kind]
    $assignmentsByVariable = @{}
    foreach ($assignment in @($rootAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst]
    }, $true))) {
        $variableName = $assignment.Left.VariablePath.UserPath
        if (-not $assignmentsByVariable.ContainsKey($variableName)) { $assignmentsByVariable[$variableName] = @() }
        $assignmentsByVariable[$variableName] += $assignment
    }
    $derived = @{}
    for ($pass = 0; $pass -lt 4; $pass++) {
        $changed = $false
        foreach ($variableName in @($assignmentsByVariable.Keys)) {
            if ($derived.ContainsKey($variableName)) { continue }
            $allGated = $true
            foreach ($assignment in $assignmentsByVariable[$variableName]) {
                if ($assignment.Right.Extent.Text -notmatch $regex) { $allGated = $false; break }
            }
            if ($allGated) {
                $derived[$variableName] = $true
                $changed = $true
                $regex = $regex + '|(?i)\$' + [regex]::Escape($variableName) + '\b'
            }
        }
        if (-not $changed) { break }
    }
    $Context.Regex[$cacheKey] = $regex
    return $regex
}

function Test-BRAVOSelfTestOutboundStopsFlow {
    param($Ast)
    return @($Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.ReturnStatementAst] -or
        $node -is [Management.Automation.Language.ExitStatementAst] -or
        $node -is [Management.Automation.Language.ContinueStatementAst] -or
        $node -is [Management.Automation.Language.BreakStatementAst] -or
        $node -is [Management.Automation.Language.ThrowStatementAst]
    }, $true)).Count -gt 0
}

function Test-BRAVOSelfTestOutboundPositiveGate {
    # Умова вимагає вимикач ПОЗИТИВНО (Codex P2, раунд 2): термін, що збігається
    # з вимикачем, стоїть не під -not/!, а з іншими термінами поєднаний лише
    # через -and — тож хибний вимикач робить умову хибною. «-not вимикач»,
    # «вимикач -or інше», порівняння й виклики команд не зараховуються.
    param($Condition, [string]$Regex)
    $node = $Condition
    if ($node -is [Management.Automation.Language.PipelineAst]) {
        if (@($node.PipelineElements).Count -ne 1) { return $false }
        $node = $node.PipelineElements[0]
    }
    if ($node -is [Management.Automation.Language.CommandExpressionAst]) { $node = $node.Expression }
    # Test-SettingEnabled <значення> (BRAVO_DRY_RUN.ps1) — перетворювач
    # істинності без зміни полярності: зараховується за своїм єдиним аргументом.
    if ($node -is [Management.Automation.Language.CommandAst] -and [string]$node.GetCommandName() -eq 'Test-SettingEnabled' -and
        @($node.CommandElements).Count -eq 2) {
        return (Test-BRAVOSelfTestOutboundPositiveGate -Condition $node.CommandElements[1] -Regex $Regex)
    }
    if ($node -is [Management.Automation.Language.ParenExpressionAst]) {
        return (Test-BRAVOSelfTestOutboundPositiveGate -Condition $node.Pipeline -Regex $Regex)
    }
    if ($node -is [Management.Automation.Language.ConvertExpressionAst]) {
        return (Test-BRAVOSelfTestOutboundPositiveGate -Condition $node.Child -Regex $Regex)
    }
    if ($node -is [Management.Automation.Language.BinaryExpressionAst]) {
        if ($node.Operator -ne [Management.Automation.Language.TokenKind]::And) { return $false }
        return ((Test-BRAVOSelfTestOutboundPositiveGate -Condition $node.Left -Regex $Regex) -or
            (Test-BRAVOSelfTestOutboundPositiveGate -Condition $node.Right -Regex $Regex))
    }
    if ($node -is [Management.Automation.Language.UnaryExpressionAst] -or
        $node -is [Management.Automation.Language.CommandBaseAst] -or
        $node -is [Management.Automation.Language.PipelineBaseAst]) { return $false }
    return ($node.Extent.Text -match $Regex)
}

function Test-BRAVOSelfTestOutboundNegatedGate {
    # Умова — рівно заперечення вимикача: -not <вимикач> чи !<вимикач>, без
    # -and/-or навколо (інакше хибність умови не означає істинність вимикача);
    # під запереченням — позитивна вимога вимикача.
    param($Condition, [string]$Regex)
    if (-not ($Condition -is [Management.Automation.Language.PipelineAst]) -or @($Condition.PipelineElements).Count -ne 1) { return $false }
    $element = $Condition.PipelineElements[0]
    if (-not ($element -is [Management.Automation.Language.CommandExpressionAst])) { return $false }
    $expression = $element.Expression
    if (-not ($expression -is [Management.Automation.Language.UnaryExpressionAst])) { return $false }
    if (@([Management.Automation.Language.TokenKind]::Not, [Management.Automation.Language.TokenKind]::Exclaim) -notcontains $expression.TokenKind) { return $false }
    return (Test-BRAVOSelfTestOutboundPositiveGate -Condition $expression.Child -Regex $Regex)
}

function Test-BRAVOSelfTestOutboundGated {
    param($Node, [string]$Kind, [hashtable]$Context, [int]$Depth, [hashtable]$Visited)

    $regex = Get-BRAVOSelfTestOutboundGateRegex -Node $Node -Kind $Kind -Context $Context
    $child = $Node
    $parent = $Node.Parent
    while ($null -ne $parent) {
        if ($parent -is [Management.Automation.Language.IfStatementAst]) {
            # Зараховується умова гілки, у ТІЛІ якої стоїть місце. else-гілка
            # ($parent.ElseClause) і пізніші elseif виконуються саме тоді, коли
            # попередні умови ХИБНІ, тож вимикач у такій умові їх не захищає —
            # крім умови, що є рівно запереченням вимикача.
            $negatedBefore = $null
            $located = $false
            foreach ($clause in $parent.Clauses) {
                $inBody = $clause.Item2.Extent.StartOffset -le $child.Extent.StartOffset -and $clause.Item2.Extent.EndOffset -ge $child.Extent.EndOffset
                if ($inBody -and (Test-BRAVOSelfTestOutboundPositiveGate -Condition $clause.Item1 -Regex $regex)) {
                    return [pscustomobject]@{ Gated = $true; Evidence = "if L$($clause.Item1.Extent.StartLineNumber)" }
                }
                $inCondition = $clause.Item1.Extent.StartOffset -le $child.Extent.StartOffset -and $clause.Item1.Extent.EndOffset -ge $child.Extent.EndOffset
                if ($inBody -or $inCondition) { $located = $true; break }
                if ($null -eq $negatedBefore -and (Test-BRAVOSelfTestOutboundNegatedGate -Condition $clause.Item1 -Regex $regex)) {
                    $negatedBefore = $clause
                }
            }
            if (-not $located -and $null -ne $parent.ElseClause) {
                $located = $parent.ElseClause.Extent.StartOffset -le $child.Extent.StartOffset -and $parent.ElseClause.Extent.EndOffset -ge $child.Extent.EndOffset
            }
            if ($located -and $null -ne $negatedBefore) {
                return [pscustomobject]@{ Gated = $true; Evidence = "else після -not L$($negatedBefore.Item1.Extent.StartLineNumber)" }
            }
        }
        if ($parent -is [Management.Automation.Language.BinaryExpressionAst] -and
            $parent.Operator -eq [Management.Automation.Language.TokenKind]::And -and
            [object]::ReferenceEquals($parent.Right, $child) -and (Test-BRAVOSelfTestOutboundPositiveGate -Condition $parent.Left -Regex $regex)) {
            return [pscustomobject]@{ Gated = $true; Evidence = "-and L$($parent.Extent.StartLineNumber)" }
        }
        if ($parent -is [Management.Automation.Language.StatementBlockAst] -or $parent -is [Management.Automation.Language.NamedBlockAst]) {
            foreach ($statement in $parent.Statements) {
                if ($statement.Extent.EndOffset -gt $child.Extent.StartOffset) { break }
                if ($statement -is [Management.Automation.Language.IfStatementAst]) {
                    foreach ($clause in $statement.Clauses) {
                        if ($clause.Item1.Extent.Text -match $regex -and (Test-BRAVOSelfTestOutboundStopsFlow -Ast $clause.Item2)) {
                            return [pscustomobject]@{ Gated = $true; Evidence = "ранній вихід L$($clause.Item1.Extent.StartLineNumber)" }
                        }
                    }
                }
            }
        }
        if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) {
            $name = $parent.Name
            $key = $name.ToLowerInvariant()
            if ($Visited.ContainsKey($key) -or $Depth -ge 10) {
                return [pscustomobject]@{ Gated = $false; Evidence = "цикл або глибина: $name" }
            }
            $Visited[$key] = $true
            $calls = @($(if ($Context.Calls.ContainsKey($key)) { $Context.Calls[$key] }))
            if ($calls.Count -eq 0) {
                return [pscustomobject]@{ Gated = $false; Evidence = "функцію $name ніхто не викликає під вимикачем (викликів немає)" }
            }
            $evidence = @()
            foreach ($call in $calls) {
                $callGate = Test-BRAVOSelfTestOutboundGated -Node $call -Kind $Kind -Context $Context -Depth ($Depth + 1) -Visited $Visited.Clone()
                if (-not $callGate.Gated) {
                    return [pscustomobject]@{ Gated = $false; Evidence = "$name <- L$($call.Extent.StartLineNumber): $($callGate.Evidence)" }
                }
                $evidence += "$name <- L$($call.Extent.StartLineNumber) [$($callGate.Evidence)]"
            }
            return [pscustomobject]@{ Gated = $true; Evidence = ($evidence -join '; ') }
        }
        $child = $parent
        $parent = $parent.Parent
    }
    return [pscustomobject]@{ Gated = $false; Evidence = 'верхній рівень скрипта без вимикача' }
}

function Test-BRAVOSelfTestOutboundException {
    param($Site)
    return @($script:BRAVOSelfTestOutboundExceptions | Where-Object {
        $_.File -eq $Site.File -and $_.Function -eq $Site.Function
    }).Count -gt 0
}

# Негативний контроль самого сторожа: синтетичний runtime-файл із
# захищеним і незахищеним каналом.
$bdGuardFixture = @(
    [pscustomobject]@{ File = 'modules\Example\Example.Runtime.ps1'; Text = @'
function Send-ExampleGated { $session = New-Object WinSCP.Session; $session.Open($null) }
function Send-ExampleUngated { $session = New-Object WinSCP.Session; $session.Open($null) }
function Connect-ExampleNas { New-PSDrive -Name EX -PSProvider FileSystem -Root '\\file-server-01\share' }
$exampleUploadEnabled = [bool]$storageEffective.SFTP.ArchiveUpload
if ($exampleUploadEnabled) { Send-ExampleGated }
if (-not [bool]$storageEffective.SMB.Enabled) { return }
Connect-ExampleNas
Send-ExampleUngated
'@ }
)
$bdGuardFixtureSites = @(Get-BRAVOSelfTestOutboundSites -Sources $bdGuardFixture)
$bdGuardFixtureByFunction = @{}
foreach ($bdFixtureSite in $bdGuardFixtureSites) { $bdGuardFixtureByFunction[$bdFixtureSite.Function] = $bdFixtureSite }
Test-BRAVOCondition -Condition (
    $bdGuardFixtureSites.Count -eq 3 -and
    [bool]$bdGuardFixtureByFunction['Send-ExampleGated'].Gated -and
    [bool]$bdGuardFixtureByFunction['Connect-ExampleNas'].Gated -and
    [string]$bdGuardFixtureByFunction['Connect-ExampleNas'].Kind -eq 'SMB' -and
    -not [bool]$bdGuardFixtureByFunction['Send-ExampleUngated'].Gated
) -Name 'BackupDestinations/OutboundGuardDetectsUngatedChannel' `
    -Failure "сторож має розпізнати захищений (похідний прапорець, ранній вихід) і незахищений канали на синтетичному файлі: $(@($bdGuardFixtureSites | ForEach-Object { "$($_.Function): gated=$($_.Gated) $($_.Evidence)" }) -join ' | ')"

# Codex P2: умова захищає лише ТЕЛО своєї гілки. Канал у else чи в пізнішій
# elseif-гілці не захищений вимикачем з умови попередньої гілки; канал у тілі
# elseif із власною умовою-вимикачем — захищений; else після умови «-not
# вимикач» (форма BRAVO.Maintenance.Runtime.ps1) — захищений.
$bdBranchFixture = @(
    [pscustomobject]@{ File = 'modules\Example\Example.Branches.ps1'; Text = @'
function Send-ExampleIfBody { $session = New-Object WinSCP.Session; $session.Open($null) }
function Send-ExampleElseBody { $session = New-Object WinSCP.Session; $session.Open($null) }
function Send-ExampleLaterElseIf { $session = New-Object WinSCP.Session; $session.Open($null) }
function Send-ExampleOwnElseIf { $session = New-Object WinSCP.Session; $session.Open($null) }
function Send-ExampleNegatedElse { $session = New-Object WinSCP.Session; $session.Open($null) }
function Send-ExampleNegatedOrElse { $session = New-Object WinSCP.Session; $session.Open($null) }
if ([bool]$storageEffective.SFTP.Enabled) { Send-ExampleIfBody } else { Send-ExampleElseBody }
if (-not [bool]$storageEffective.SFTP.Enabled) { Write-Output 'off' } else { Send-ExampleNegatedElse }
if (-not [bool]$storageEffective.SFTP.Enabled -or $exampleOtherFlag) { Write-Output 'off' } else { Send-ExampleNegatedOrElse }
if ([bool]$storageEffective.SFTP.Enabled) { Write-Output 'sftp' } elseif ($exampleOtherFlag) { Send-ExampleLaterElseIf }
if ($exampleOtherFlag) { Write-Output 'other' } elseif ([bool]$storageEffective.SFTP.ArchiveUpload) { Send-ExampleOwnElseIf }
'@ }
)
$bdBranchSites = @{}
foreach ($bdBranchSite in @(Get-BRAVOSelfTestOutboundSites -Sources $bdBranchFixture)) { $bdBranchSites[$bdBranchSite.Function] = $bdBranchSite }
Test-BRAVOCondition -Condition (
    $bdBranchSites.Count -eq 6 -and
    [bool]$bdBranchSites['Send-ExampleIfBody'].Gated -and
    -not [bool]$bdBranchSites['Send-ExampleElseBody'].Gated -and
    -not [bool]$bdBranchSites['Send-ExampleLaterElseIf'].Gated -and
    [bool]$bdBranchSites['Send-ExampleOwnElseIf'].Gated -and
    [bool]$bdBranchSites['Send-ExampleNegatedElse'].Gated -and
    -not [bool]$bdBranchSites['Send-ExampleNegatedOrElse'].Gated
) -Name 'BackupDestinations/OutboundGuardCountsOnlyOwnBranchCondition' `
    -Failure "сторож має зараховувати вимикач лише з умови гілки, у тілі якої стоїть канал: else і пізніша elseif — незахищені (крім else після рівно «-not вимикач»), if і elseif із власною умовою — захищені: $(@($bdBranchSites.Values | ForEach-Object { "$($_.Function): gated=$($_.Gated) $($_.Evidence)" }) -join ' | ')"

# Codex P2 (раунд 2): полярність. Вимикач зараховується лише як позитивна
# вимога на власній гілці каналу: «-not вимикач» у тілі й «вимикач -or інше»
# каналу не захищають; «вимикач -and інше» — захищає; else після рівно
# «-not вимикач» лишається захищеним.
$bdPolarityFixture = @(
    [pscustomobject]@{ File = 'modules\Example\Example.Polarity.ps1'; Text = @'
function Send-ExampleNegatedBody { $session = New-Object WinSCP.Session; $session.Open($null) }
function Send-ExampleOrBody { $session = New-Object WinSCP.Session; $session.Open($null) }
function Send-ExampleNegatedAndRight { $session = New-Object WinSCP.Session; $session.Open($null) }
function Send-ExampleAndBody { $session = New-Object WinSCP.Session; $session.Open($null) }
function Send-ExampleNegatedElseKept { $session = New-Object WinSCP.Session; $session.Open($null) }
if (-not $storageEffective.SFTP.Enabled) { Send-ExampleNegatedBody }
if ($storageEffective.SFTP.Enabled -or $exampleOtherFlag) { Send-ExampleOrBody }
(-not $storageEffective.SFTP.Enabled) -and (Send-ExampleNegatedAndRight)
if ($storageEffective.SFTP.Enabled -and $exampleOtherFlag) { Send-ExampleAndBody }
if (!$storageEffective.SFTP.Enabled) { Write-Output 'off' } else { Send-ExampleNegatedElseKept }
'@ }
)
$bdPolaritySites = @{}
foreach ($bdPolaritySite in @(Get-BRAVOSelfTestOutboundSites -Sources $bdPolarityFixture)) { $bdPolaritySites[$bdPolaritySite.Function] = $bdPolaritySite }
Test-BRAVOCondition -Condition (
    $bdPolaritySites.Count -eq 5 -and
    -not [bool]$bdPolaritySites['Send-ExampleNegatedBody'].Gated -and
    -not [bool]$bdPolaritySites['Send-ExampleOrBody'].Gated -and
    -not [bool]$bdPolaritySites['Send-ExampleNegatedAndRight'].Gated -and
    [bool]$bdPolaritySites['Send-ExampleAndBody'].Gated -and
    [bool]$bdPolaritySites['Send-ExampleNegatedElseKept'].Gated
) -Name 'BackupDestinations/OutboundGuardRequiresPositiveSwitch' `
    -Failure "сторож має зараховувати вимикач лише як позитивну вимогу гілки каналу (не під -not/!, поєднану лише через -and): «if (-not вимикач) { канал }», «if (вимикач -or інше) { канал }» і «(-not вимикач) -and (канал)» — незахищені; «вимикач -and інше» і else після «!вимикач» — захищені: $(@($bdPolaritySites.Values | ForEach-Object { "$($_.Function): gated=$($_.Gated) $($_.Evidence)" }) -join ' | ')"

$bdOutboundSites = @(Get-BRAVOSelfTestOutboundSites -Sources (Get-BRAVOSelfTestOutboundSourceSet -Root $root))
$bdUngatedSites = @($bdOutboundSites | Where-Object { -not $_.Gated -and -not (Test-BRAVOSelfTestOutboundException -Site $_) })
$bdStaleExceptions = @($script:BRAVOSelfTestOutboundExceptions | Where-Object {
    $exception = $_
    @($bdOutboundSites | Where-Object { $_.File -eq $exception.File -and $_.Function -eq $exception.Function }).Count -eq 0
})
# Інвентар-якір: сторож мусить бачити відомі канали кожного домену, інакше
# зламаний пошук файлів дав би «0 незахищених» без жодної перевірки.
$bdExpectedAnchors = @(
    'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1|Send-FileViaWinSCP',
    'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1|New-BRAVOSMBDrive',
    'modules\BRAVO.BazaSync\BRAVO.BazaSync.psm1|Invoke-BRAVOBazaComponentSyncSession',
    'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1|Invoke-WinSCPBAZAComparison',
    'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1|New-BRAVOSMBHealthDrive',
    'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1|Connect-BRAVOOwnLogSftpSession',
    'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1|Invoke-BRAVOMaintenance',
    'BRAVO_DRY_RUN.ps1|Test-SftpDestinationAccess',
    'BRAVO_DRY_RUN.ps1|Test-SmbReadOnlyAccess'
)
$bdSiteKeys = @($bdOutboundSites | ForEach-Object { "$($_.File)|$($_.Function)" })
$bdMissingAnchors = @($bdExpectedAnchors | Where-Object { $bdSiteKeys -notcontains $_ })
Test-BRAVOCondition -Condition (
    $bdUngatedSites.Count -eq 0 -and
    $bdStaleExceptions.Count -eq 0 -and
    $bdMissingAnchors.Count -eq 0
) -Name 'BackupDestinations/EveryOutboundChannelGatedByStorageEffective' `
    -Failure ("кожен SFTP/SMB-канал runtime-коду має бути під storageEffective.SFTP/SMB (або в явному переліку ручних інструментів з причиною). " +
        "Незахищені: $(@($bdUngatedSites | ForEach-Object { "$($_.Kind) $($_.File):$($_.Line) [$($_.Function)] — $($_.Evidence)" }) -join ' | '); " +
        "застарілі винятки: $(@($bdStaleExceptions | ForEach-Object { "$($_.File) [$($_.Function)]" }) -join ', '); " +
        "не знайдено відомих каналів: $($bdMissingAnchors -join ', ')")

# Вимикачі, на які спирається сторож, справді вимикають канали.
$bdStorageOff = Get-BRAVOEffectiveStorageConfiguration -ComponentSettings @{
    SFTP = @{ Enabled = $false; ArchiveUpload = $true }
    SMB = @{ Enabled = $false; ArchiveCopy = $true }
}
$bdBazaOff = Get-BRAVOEffectiveSynchronizationConfiguration `
    -Synchronization @{ BAZA_APP_LOCAL = $false; BAZA_APP_SFTP = $true; BAZA_WWW_LOCAL = $false; BAZA_WWW_SFTP = $true } `
    -GlobalSftpEnabled $false
$bdDerivationText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Derivation.psm1'), [Text.Encoding]::UTF8)
$bdBazaAssignments = @([regex]::Matches(
    (@((Get-BRAVOSelfTestOutboundSourceSet -Root $root) | ForEach-Object { $_.Text }) -join "`n"),
    '(?i)\$(global:)?bazaSyncEffective\s*=(?!=)'))
Test-BRAVOCondition -Condition (
    -not [bool]$bdStorageOff.SFTP.ArchiveUpload -and
    -not [bool]$bdStorageOff.SMB.ArchiveCopy -and
    -not [bool]$bdBazaOff.ScheduledSftpSyncRequired -and
    @($bdBazaOff.Components | Where-Object { [bool]$_.SftpEnabled }).Count -eq 0 -and
    -not (Test-BRAVOSftpCredentialsRequired -SftpEnabled $false -ArchiveUploadEnabled $true -MaintenanceLogUploadEnabled $true `
        -ArchiveLogUploadEnabled $true -ScheduledSftpSyncRequired $true -BackupMonitoringSftpEnabled $true) -and
    $bdBazaAssignments.Count -eq 1 -and
    $bdDerivationText -match '(?s)\$global:bazaSyncEffective = Get-BRAVOEffectiveSynchronizationConfiguration[^\r\n]*\r?\n(?:[^\r\n]*\r?\n){0,6}?[^\r\n]*-GlobalSftpEnabled \(\[bool\]\$global:storageEffective\.SFTP\.Enabled\)'
) -Name 'BackupDestinations/StorageMasterSwitchesDisableEveryChild' `
    -Failure "головні вимикачі мають гасити всі дочірні канали (ArchiveUpload, ArchiveCopy, BAZA SFTP, потребу SFTP-креденшлів), а єдине присвоєння bazaSyncEffective — брати GlobalSftpEnabled зі storageEffective.SFTP.Enabled; присвоєнь: $($bdBazaAssignments.Count)"
