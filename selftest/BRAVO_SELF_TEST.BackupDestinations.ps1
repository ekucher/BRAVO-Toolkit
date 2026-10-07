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
# жодна інша команда не пише в $localConfig (копія прикладу, Set-Content тощо).
$bdInstallWrites = @($bdInstallAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    @('Copy-Item', 'Move-Item', 'Set-Content', 'Add-Content', 'Out-File', 'New-Item') -contains [string]$node.GetCommandName() -and
    $node.Extent.Text -match '(?i)\$localConfig\b|BRAVO\.local\.config'''
}, $true))
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
    foreach ($bdModuleDirectory in @('BRAVO.Configurator', 'BRAVO.Configuration', 'BRAVO.System')) {
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
        'function Write-Bad { param([string]$T) Write-StepOutput (''[FAIL] '' + $T) }',
        'try {',
        $bdStepText,
        'exit 0',
        '} catch { Write-StepOutput (''THROW: '' + $_.Exception.Message); exit 1 }'
    ) -join "`r`n"
    [IO.File]::WriteAllText($bdChildPath, $bdChildText, (New-Object Text.UTF8Encoding($true)))
    $bdHostPath = (Get-Process -Id $PID).Path
    $bdLocalConfigPath = Join-Path $bdInstallRoot 'BRAVO.local.config'

    $bdOutputLogPath = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_SELFTEST_DEST_INSTALL_' + [guid]::NewGuid().ToString('N') + '.log')
    function Invoke-BRAVOSelfTestInstallStep4 {
        param([string[]]$Arguments)
        Remove-Item -LiteralPath $bdOutputLogPath -Force -ErrorAction SilentlyContinue
        $streamOutput = @(& $bdHostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bdChildPath `
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

    # Наявний файл не змінюється, і вивід називає незастосований профіль.
    $bdExistingText = "@{`r`n    'pathSettings.BackupRoot' = 'D:\ExampleArchive'`r`n}`r`n"
    [IO.File]::WriteAllText($bdLocalConfigPath, $bdExistingText, (New-Object Text.UTF8Encoding($false)))
    $bdExistingBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($bdLocalConfigPath))
    $bdRunExisting = Invoke-BRAVOSelfTestInstallStep4 -Arguments @('-SeedLocalConfig', '-BackupDestination', 'LocalOnly')
    $bdExistingAfter = [Convert]::ToBase64String([IO.File]::ReadAllBytes($bdLocalConfigPath))
    Remove-Item -LiteralPath $bdLocalConfigPath -Force -ErrorAction SilentlyContinue
    # Без -SeedLocalConfig файл не створюється, а явний профіль названо незастосованим.
    $bdRunNoSeed = Invoke-BRAVOSelfTestInstallStep4 -Arguments @('-BackupDestination', 'LocalOnly')
    Test-BRAVOCondition -Condition (
        $bdRunExisting.ExitCode -eq 0 -and
        $bdExistingBefore -ceq $bdExistingAfter -and
        $bdRunExisting.Output.Contains('BRAVO.local.config уже існує') -and
        $bdRunExisting.Output.Contains('профіль напрямків LocalOnly НЕ застосовано') -and
        $bdRunNoSeed.ExitCode -eq 0 -and
        -not (Test-Path -LiteralPath $bdLocalConfigPath) -and
        $bdRunNoSeed.Output.Contains('профіль напрямків LocalOnly НЕ застосовано') -and
        @(Get-ChildItem -LiteralPath $bdInstallRoot -Force -Filter 'BRAVO.local.config*').Count -eq 0
    ) -Name 'BackupDestinations/InstallerExistingConfigUntouched' `
        -Failure "наявний BRAVO.local.config інсталятор не змінює й повідомляє, який профіль не застосовано; без -SeedLocalConfig файл не створюється; наявний: exit=$($bdRunExisting.ExitCode) байти_збіглись=$($bdExistingBefore -ceq $bdExistingAfter) $($bdRunExisting.Output) ||| без seed: exit=$($bdRunNoSeed.ExitCode) $($bdRunNoSeed.Output)"
} finally {
    if (Test-Path -LiteralPath $bdInstallRoot) {
        Remove-Item -LiteralPath $bdInstallRoot -Recurse -Force -ErrorAction SilentlyContinue
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
#   * if/elseif, у ланцюгу умов якого (до гілки з місцем включно) є вимикач;
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

function Test-BRAVOSelfTestOutboundGated {
    param($Node, [string]$Kind, [hashtable]$Context, [int]$Depth, [hashtable]$Visited)

    $regex = Get-BRAVOSelfTestOutboundGateRegex -Node $Node -Kind $Kind -Context $Context
    $child = $Node
    $parent = $Node.Parent
    while ($null -ne $parent) {
        if ($parent -is [Management.Automation.Language.IfStatementAst]) {
            foreach ($clause in $parent.Clauses) {
                if ($clause.Item1.Extent.Text -match $regex) {
                    return [pscustomobject]@{ Gated = $true; Evidence = "if L$($clause.Item1.Extent.StartLineNumber)" }
                }
                $inBody = $clause.Item2.Extent.StartOffset -le $child.Extent.StartOffset -and $clause.Item2.Extent.EndOffset -ge $child.Extent.EndOffset
                $inCondition = $clause.Item1.Extent.StartOffset -le $child.Extent.StartOffset -and $clause.Item1.Extent.EndOffset -ge $child.Extent.EndOffset
                if ($inBody -or $inCondition) { break }
            }
        }
        if ($parent -is [Management.Automation.Language.BinaryExpressionAst] -and
            $parent.Operator -eq [Management.Automation.Language.TokenKind]::And -and
            [object]::ReferenceEquals($parent.Right, $child) -and $parent.Left.Extent.Text -match $regex) {
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
