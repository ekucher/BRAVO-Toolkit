# Домен-фрагмент self-test: BRAVO.Configurator backend
# (Schema/Model/Effective/Validation/Persistence) — GUI (Agent 4-7 з
# docs/design/BRAVO_CONFIGURATOR_DESIGN.md) поки не реалізовано, тут
# перевіряється лише backend-контракт.
#
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition, $script:failures.
#
# Ізоляція: жодна перевірка не читає й не пише реальний
# $root\BRAVO.local.config — лише тимчасові каталоги в %TEMP%, видалені у
# finally.
#
# Герметичність RuntimeRoot (CI-регресія, той самий клас, що
# selftest\BRAVO_SELF_TEST.ConfigLoader.ps1 вже документує для
# BackupRoot=""): Configurator.Effective копіює $RuntimeRoot\BRAVO.config
# У isolated ConfigRoot ВЕРБАТИМ, без жодного патчингу. Канонічний
# комплектний default LIMSRoot=""/BackupRoot="" (AUTO) на реальному
# production-сервері резолвиться через встановлену службу BRAVO; на
# GitHub runner (і будь-якій dev-машині без LIMS) AUTO-виявлення падає з
# "Не вдалося визначити BackupRoot" — жоден Configurator-виклик з
# порожнім/без-override candidate (у т.ч. ВСЕРЕДИНІ production
# Test-BRAVOConfiguratorCandidateOverrides, яка завжди рахує ВЛАСНИЙ
# DefaultConfig з -CandidateOverrides @{}) не може обійти цю залежність
# лише через overrides, передані САМИМ self-test-ом. Тому весь фрагмент
# передає RuntimeRoot = ІЗОЛЬОВАНА копія реального комплекту з ЄДИНОЮ
# зміною — явний LIMSRoot/BackupRoot замість AUTO (той самий text-replace
# прийом, що ConfigLoader.ps1), а не реальний $root.

$configuratorModuleRoot = Join-Path $root 'modules\BRAVO.Configurator'
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Schema.psm1') -Force
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Effective.psm1') -Force
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Model.psm1') -Force
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Validation.psm1') -Force
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Persistence.psm1') -Force
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Credentials.psm1') -Force
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Presets.psm1') -Force
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Preview.psm1') -Force

$configuratorFixtureRuntimeRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIGURATOR_SELFTEST_RUNTIME_{0}" -f [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($configuratorFixtureRuntimeRoot)
$configuratorFixtureLimsRoot = Join-Path $configuratorFixtureRuntimeRoot 'FIXTURE_LIMS'
$configuratorFixtureBackupRoot = Join-Path $configuratorFixtureRuntimeRoot 'FIXTURE_BACKUP'
[void][IO.Directory]::CreateDirectory($configuratorFixtureLimsRoot)
[void][IO.Directory]::CreateDirectory($configuratorFixtureBackupRoot)
Copy-Item -LiteralPath (Join-Path $root 'BRAVO_CONFIG_LOADER.ps1') -Destination (Join-Path $configuratorFixtureRuntimeRoot 'BRAVO_CONFIG_LOADER.ps1') -Force
Copy-Item -LiteralPath (Join-Path $root 'VERSION.json') -Destination (Join-Path $configuratorFixtureRuntimeRoot 'VERSION.json') -Force
# Junction, не copy: modules\ — великий, реальні збірки викликів
# (Discovery/Compatibility) мають лишатися canonical-кодом репозиторію,
# не копією, що могла б непомітно розійтись.
$null = cmd.exe /c mklink /J "$configuratorFixtureRuntimeRoot\modules" "$root\modules" 2>&1
$configuratorKitConfigText = (Get-BRAVOSelfTestLegacyConfigText)
$configuratorLimsRootLiteralLine = '    LIMSRoot      = ""'
$configuratorBackupRootLiteralLine = '    BackupRoot    = ""'
if (-not $configuratorKitConfigText.Contains($configuratorLimsRootLiteralLine) -or
    -not $configuratorKitConfigText.Contains($configuratorBackupRootLiteralLine)) {
    throw "BRAVO_SELF_TEST.Configurator: у BRAVO.config не знайдено очікувані рядки LIMSRoot/BackupRoot — оновіть fixture під нову форму конфігурації"
}
$configuratorPatchedConfigText = $configuratorKitConfigText.
    Replace($configuratorLimsRootLiteralLine, "    LIMSRoot      = '$($configuratorFixtureLimsRoot.Replace("'", "''"))'").
    Replace($configuratorBackupRootLiteralLine, "    BackupRoot    = '$($configuratorFixtureBackupRoot.Replace("'", "''"))'")
[IO.File]::WriteAllText((Join-Path $configuratorFixtureRuntimeRoot 'BRAVO.config'), $configuratorPatchedConfigText, (New-Object System.Text.UTF8Encoding($false)))

# ===== Schema completeness (§3.4 задачі Configurator-а) =====
$configuratorSchemaResult = Test-BRAVOConfiguratorSchemaCompleteness -ExamplePath (Join-Path $root 'BRAVO.local.config.example')
Test-BRAVOCondition ($configuratorSchemaResult.IsComplete) `
    'Configurator: schema 1:1 з BRAVO.local.config.example' `
    ("ConfigurableTotal=$($configuratorSchemaResult.ConfigurableTotal) SchemaDescriptors=$($configuratorSchemaResult.SchemaDescriptors) " +
     "Missing=$($configuratorSchemaResult.MissingPaths -join ',') Orphan=$($configuratorSchemaResult.OrphanPaths -join ',') " +
     "Duplicate=$($configuratorSchemaResult.DuplicatePaths -join ',')")
Test-BRAVOCondition ($configuratorSchemaResult.ConfigurableTotal -gt 100) `
    'Configurator: schema каталог не порожній/тривіальний' `
    "ConfigurableTotal=$($configuratorSchemaResult.ConfigurableTotal) (очікувалось > 100)"

# R3-5 (PR #136, третє коло review): 5 нових log-lifecycle ключів мусять
# мати дескриптор правильного типу — без цього фіча лишається керованою
# лише прямим редагуванням BRAVO.config, недоступною з Configurator UI.
$configuratorLogLifecycleDescriptors = @(Get-BRAVOConfiguratorSchemaCatalog)
$configuratorExpectedLogLifecyclePaths = @{
    'maintenanceSettings.Retention.RawSourceGraceDays'  = 'Integer'
    'componentSettings.SFTP.MaintenanceLogUploadEnabled' = 'Boolean'
    'componentSettings.SFTP.ArchiveLogUploadEnabled'     = 'Boolean'
    'sftpDirectories.MaintenanceLog'                     = 'String'
    'sftpDirectories.ArchivLog'                          = 'String'
}
$configuratorLogLifecycleMismatches = New-Object System.Collections.Generic.List[string]
foreach ($expectedPath in $configuratorExpectedLogLifecyclePaths.Keys) {
    $matchingDescriptor = @($configuratorLogLifecycleDescriptors | Where-Object { $_.Path -eq $expectedPath })
    if ($matchingDescriptor.Count -ne 1) {
        $configuratorLogLifecycleMismatches.Add("$expectedPath : відсутній дескриптор (знайдено $($matchingDescriptor.Count))")
    } elseif ([string]$matchingDescriptor[0].Type -ne $configuratorExpectedLogLifecyclePaths[$expectedPath]) {
        $configuratorLogLifecycleMismatches.Add("$expectedPath : Type='$($matchingDescriptor[0].Type)', очікувалось '$($configuratorExpectedLogLifecyclePaths[$expectedPath])'")
    }
}
Test-BRAVOCondition ($configuratorLogLifecycleMismatches.Count -eq 0) `
    'Configurator/LogLifecycleSettingsHaveDescriptors' `
    "5 нових log-lifecycle ключів мають мати дескриптор коректного типу; розбіжності: $($configuratorLogLifecycleMismatches -join ' | ')"

# ===== Model: Default/Override/Effective/Dirty (§22.4-6 задачі) =====
$configuratorSchemaCatalog = Get-BRAVOConfiguratorSchemaCatalog
$configuratorDefaultConfig = Invoke-BRAVOConfiguratorEffectiveComputation -RuntimeRoot $configuratorFixtureRuntimeRoot -CandidateOverrides @{}

# 4: no override -> Effective=Default
$modelNoOverride = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{}
$modelNoOverride = Update-BRAVOConfiguratorEffective -Model $modelNoOverride -RuntimeRoot $configuratorFixtureRuntimeRoot
$backupRootSettingNoOverride = @($modelNoOverride | Where-Object { $_.Path -eq 'pathSettings.BackupRoot' })
Test-BRAVOCondition ($backupRootSettingNoOverride.Count -eq 1 -and $backupRootSettingNoOverride[0].EffectiveValue -eq $backupRootSettingNoOverride[0].DefaultValue) `
    'Configurator Model: без override Effective=Default' `
    "Effective=$($backupRootSettingNoOverride[0].EffectiveValue) Default=$($backupRootSettingNoOverride[0].DefaultValue)"

# 5: explicit override -> Effective=Override
$modelWithOverride = Set-BRAVOConfiguratorOverride -Model $modelNoOverride -Path 'pathSettings.BackupRoot' -Value 'E:\SELFTEST_BACKUP_ROOT'
$modelWithOverride = Update-BRAVOConfiguratorEffective -Model $modelWithOverride -RuntimeRoot $configuratorFixtureRuntimeRoot
$backupRootSettingOverride = @($modelWithOverride | Where-Object { $_.Path -eq 'pathSettings.BackupRoot' })
Test-BRAVOCondition ($backupRootSettingOverride.Count -eq 1 -and $backupRootSettingOverride[0].EffectiveValue -eq 'E:\SELFTEST_BACKUP_ROOT' -and $backupRootSettingOverride[0].EffectiveSource -eq 'Override') `
    'Configurator Model: explicit override -> Effective=Override' `
    "Effective=$($backupRootSettingOverride[0].EffectiveValue) Source=$($backupRootSettingOverride[0].EffectiveSource)"

# 6: Default action removes override
$modelCleared = Clear-BRAVOConfiguratorOverride -Model $modelWithOverride -Path 'pathSettings.BackupRoot'
$backupRootSettingCleared = @($modelCleared | Where-Object { $_.Path -eq 'pathSettings.BackupRoot' })
Test-BRAVOCondition ($backupRootSettingCleared.Count -eq 1 -and -not $backupRootSettingCleared[0].OverridePresent) `
    'Configurator Model: "Використовувати default" видаляє override' `
    "OverridePresent=$($backupRootSettingCleared[0].OverridePresent)"

# ===== SFTP/SMB 5.2.2 master-switch semantics (P0.13 Scenario A-J; реальний
# canonical loader через Get-BRAVOEffectiveStorageConfiguration/
# Get-BRAVOEffectiveSynchronizationConfiguration, не reimplemented) =====

# Scenario A: SFTP.Enabled=true, ArchiveUpload raw=true -> Effective=true
$modelScenarioA = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SFTP.Enabled' = $true
    'componentSettings.SFTP.ArchiveUpload' = $true
}
$modelScenarioA = Update-BRAVOConfiguratorEffective -Model $modelScenarioA -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioA = @($modelScenarioA | Where-Object { $_.Path -eq 'componentSettings.SFTP.ArchiveUpload' })
Test-BRAVOCondition ($settingScenarioA.Count -eq 1 -and [bool]$settingScenarioA[0].EffectiveValue -eq $true) `
    'Configurator 5.2.2 Scenario A: SFTP.Enabled=true + ArchiveUpload raw=true -> Effective=true' `
    "Effective=$($settingScenarioA[0].EffectiveValue)"

# Scenario B: SFTP.Enabled=false, ArchiveUpload raw=true -> Effective=false;
# Raw лишається true; DisabledReason присутній і посилається саме на
# componentSettings.SFTP.Enabled (canonical текст, не Configurator-вигадка).
$modelScenarioB = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SFTP.Enabled' = $false
    'componentSettings.SFTP.ArchiveUpload' = $true
}
$modelScenarioB = Update-BRAVOConfiguratorEffective -Model $modelScenarioB -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioB = @($modelScenarioB | Where-Object { $_.Path -eq 'componentSettings.SFTP.ArchiveUpload' })
Test-BRAVOCondition (
    $settingScenarioB.Count -eq 1 -and
    [bool]$settingScenarioB[0].OverrideValue -eq $true -and
    [bool]$settingScenarioB[0].EffectiveValue -eq $false -and
    -not [string]::IsNullOrWhiteSpace([string]$settingScenarioB[0].DisabledReason) -and
    [string]$settingScenarioB[0].DisabledReason -match 'componentSettings\.SFTP\.Enabled'
) `
    'Configurator 5.2.2 Scenario B: SFTP.Enabled=false -> ArchiveUpload Effective=false, Raw=true, DisabledReason коректний' `
    "Raw=$($settingScenarioB[0].OverrideValue) Effective=$($settingScenarioB[0].EffectiveValue) DisabledReason=$($settingScenarioB[0].DisabledReason)"

# Scenario C: SFTP.Enabled=false, BAZA_APP_SFTP raw=true -> Effective=false
$modelScenarioC = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SFTP.Enabled' = $false
    'componentSettings.Synchronization.BAZA_APP_SFTP' = $true
}
$modelScenarioC = Update-BRAVOConfiguratorEffective -Model $modelScenarioC -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioC = @($modelScenarioC | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_SFTP' })
Test-BRAVOCondition ($settingScenarioC.Count -eq 1 -and [bool]$settingScenarioC[0].OverrideValue -eq $true -and [bool]$settingScenarioC[0].EffectiveValue -eq $false) `
    'Configurator 5.2.2 Scenario C: SFTP.Enabled=false -> BAZA_APP_SFTP Effective=false (Raw=true збережено)' `
    "Raw=$($settingScenarioC[0].OverrideValue) Effective=$($settingScenarioC[0].EffectiveValue)"

# Scenario D: SFTP.Enabled=false, BAZA_WWW_SFTP raw=true -> Effective=false
$modelScenarioD = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SFTP.Enabled' = $false
    'componentSettings.Synchronization.BAZA_WWW_SFTP' = $true
}
$modelScenarioD = Update-BRAVOConfiguratorEffective -Model $modelScenarioD -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioD = @($modelScenarioD | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_SFTP' })
Test-BRAVOCondition ($settingScenarioD.Count -eq 1 -and [bool]$settingScenarioD[0].OverrideValue -eq $true -and [bool]$settingScenarioD[0].EffectiveValue -eq $false) `
    'Configurator 5.2.2 Scenario D: SFTP.Enabled=false -> BAZA_WWW_SFTP Effective=false (Raw=true збережено)' `
    "Raw=$($settingScenarioD[0].OverrideValue) Effective=$($settingScenarioD[0].EffectiveValue)"

# Scenario E: master re-enabled -> raw child value restored as effective
# БЕЗ повторного налаштування дочірнього прапорця (сам override
# ArchiveUpload=true лишається незмінним і всю сесію — лише master
# перемикається false->true).
$modelScenarioE = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SFTP.Enabled' = $true
    'componentSettings.SFTP.ArchiveUpload' = $true
}
$modelScenarioE = Update-BRAVOConfiguratorEffective -Model $modelScenarioE -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioE = @($modelScenarioE | Where-Object { $_.Path -eq 'componentSettings.SFTP.ArchiveUpload' })
Test-BRAVOCondition ($settingScenarioE.Count -eq 1 -and [bool]$settingScenarioE[0].OverrideValue -eq $true -and [bool]$settingScenarioE[0].EffectiveValue -eq $true -and [string]::IsNullOrWhiteSpace([string]$settingScenarioE[0].DisabledReason)) `
    'Configurator 5.2.2 Scenario E: master повторно увімкнено -> Effective відновлено з Raw, без DisabledReason' `
    "Raw=$($settingScenarioE[0].OverrideValue) Effective=$($settingScenarioE[0].EffectiveValue) DisabledReason=$($settingScenarioE[0].DisabledReason)"

# Scenario F: SMB.Enabled=false, ArchiveCopy raw=true -> Effective=false
$modelScenarioF = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SMB.Enabled' = $false
    'componentSettings.SMB.ArchiveCopy' = $true
}
$modelScenarioF = Update-BRAVOConfiguratorEffective -Model $modelScenarioF -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioF = @($modelScenarioF | Where-Object { $_.Path -eq 'componentSettings.SMB.ArchiveCopy' })
Test-BRAVOCondition (
    $settingScenarioF.Count -eq 1 -and [bool]$settingScenarioF[0].OverrideValue -eq $true -and [bool]$settingScenarioF[0].EffectiveValue -eq $false -and
    [string]$settingScenarioF[0].DisabledReason -match 'componentSettings\.SMB\.Enabled'
) `
    'Configurator 5.2.2 Scenario F: SMB.Enabled=false -> ArchiveCopy Effective=false, DisabledReason коректний' `
    "Raw=$($settingScenarioF[0].OverrideValue) Effective=$($settingScenarioF[0].EffectiveValue) DisabledReason=$($settingScenarioF[0].DisabledReason)"

# Scenario G: SFTP disabled НЕ вимикає SMB (незалежні master-и)
$modelScenarioG = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SFTP.Enabled' = $false
    'componentSettings.SMB.ArchiveCopy' = $true
}
$modelScenarioG = Update-BRAVOConfiguratorEffective -Model $modelScenarioG -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioG = @($modelScenarioG | Where-Object { $_.Path -eq 'componentSettings.SMB.ArchiveCopy' })
Test-BRAVOCondition ($settingScenarioG.Count -eq 1 -and [bool]$settingScenarioG[0].EffectiveValue -eq $true) `
    'Configurator 5.2.2 Scenario G: SFTP.Enabled=false НЕ вимикає SMB.ArchiveCopy' `
    "Effective=$($settingScenarioG[0].EffectiveValue)"

# Scenario H: SMB disabled НЕ вимикає SFTP (незалежні master-и)
$modelScenarioH = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SMB.Enabled' = $false
    'componentSettings.SFTP.ArchiveUpload' = $true
}
$modelScenarioH = Update-BRAVOConfiguratorEffective -Model $modelScenarioH -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioH = @($modelScenarioH | Where-Object { $_.Path -eq 'componentSettings.SFTP.ArchiveUpload' })
Test-BRAVOCondition ($settingScenarioH.Count -eq 1 -and [bool]$settingScenarioH[0].EffectiveValue -eq $true) `
    'Configurator 5.2.2 Scenario H: SMB.Enabled=false НЕ вимикає SFTP.ArchiveUpload' `
    "Effective=$($settingScenarioH[0].EffectiveValue)"

# Scenario I (Health isolation, §P0.6): backupMonitoring.SFTP.Enabled=false
# з операційним SFTP.Enabled=true НЕ повинно вимикати operational
# ArchiveUpload — Health-вимикач лишається у власному semantic domain.
$modelScenarioI = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'backupMonitoring.SFTP.Enabled' = $false
    'componentSettings.SFTP.Enabled' = $true
    'componentSettings.SFTP.ArchiveUpload' = $true
}
$modelScenarioI = Update-BRAVOConfiguratorEffective -Model $modelScenarioI -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioI = @($modelScenarioI | Where-Object { $_.Path -eq 'componentSettings.SFTP.ArchiveUpload' })
Test-BRAVOCondition ($settingScenarioI.Count -eq 1 -and [bool]$settingScenarioI[0].EffectiveValue -eq $true -and [string]::IsNullOrWhiteSpace([string]$settingScenarioI[0].DisabledReason)) `
    'Configurator 5.2.2 Scenario I: backupMonitoring.SFTP.Enabled=false НЕ вимикає operational ArchiveUpload (Health isolation)' `
    "Effective=$($settingScenarioI[0].EffectiveValue) DisabledReason=$($settingScenarioI[0].DisabledReason)"

# Scenario J (Health isolation, §P0.6): backupMonitoring.SMB.Enabled=false
# з операційним SMB.Enabled=true НЕ повинно вимикати operational ArchiveCopy.
$modelScenarioJ = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'backupMonitoring.SMB.Enabled' = $false
    'componentSettings.SMB.Enabled' = $true
    'componentSettings.SMB.ArchiveCopy' = $true
}
$modelScenarioJ = Update-BRAVOConfiguratorEffective -Model $modelScenarioJ -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioJ = @($modelScenarioJ | Where-Object { $_.Path -eq 'componentSettings.SMB.ArchiveCopy' })
Test-BRAVOCondition ($settingScenarioJ.Count -eq 1 -and [bool]$settingScenarioJ[0].EffectiveValue -eq $true -and [string]::IsNullOrWhiteSpace([string]$settingScenarioJ[0].DisabledReason)) `
    'Configurator 5.2.2 Scenario J: backupMonitoring.SMB.Enabled=false НЕ вимикає operational ArchiveCopy (Health isolation)' `
    "Effective=$($settingScenarioJ[0].EffectiveValue) DisabledReason=$($settingScenarioJ[0].DisabledReason)"

# Scenario K: schema completeness (== canonical documented override paths,
# missing=0, stale=0) уже перевірено вище ($configuratorSchemaResult,
# IsComplete/MissingPaths/OrphanPaths) — не дублюємо ту саму перевірку.
Test-BRAVOCondition ($configuratorSchemaResult.IsComplete -and $configuratorSchemaResult.SchemaDescriptors -eq $configuratorSchemaResult.ConfigurableTotal) `
    'Configurator 5.2.2 Scenario K: descriptors == canonical documented paths (152), missing=0, stale=0' `
    "SchemaDescriptors=$($configuratorSchemaResult.SchemaDescriptors) ConfigurableTotal=$($configuratorSchemaResult.ConfigurableTotal)"

# ===== SMB.ArchiveCopy default (raw) лишається без override — Validation
# blocking-сценарій нижче (SMB.ArchiveCopy=true + порожній RootPath)
# перевіряє саме Raw override, не залежить від нового SMB.Enabled master —
# лишено без змін (P0.9: жодної нової залежності в дійсному runtime немає
# для smbSettings.RootPath).

# ===== Validation: SMB blocking ERROR + clean model zero-findings (§22.11-13 задачі) =====
$modelSmbInvalid = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SMB.ArchiveCopy' = $true
    'smbSettings.RootPath' = ''
}
$modelSmbInvalid = Update-BRAVOConfiguratorEffective -Model $modelSmbInvalid -RuntimeRoot $configuratorFixtureRuntimeRoot
$validationSmbInvalid = Invoke-BRAVOConfiguratorValidation -Model $modelSmbInvalid
Test-BRAVOCondition ($validationSmbInvalid.HasErrors -and $validationSmbInvalid.ErrorCount -eq 1) `
    'Configurator Validation: SMB.ArchiveCopy=true + порожній RootPath -> blocking ERROR' `
    "HasErrors=$($validationSmbInvalid.HasErrors) ErrorCount=$($validationSmbInvalid.ErrorCount)"

$validationClean = Invoke-BRAVOConfiguratorValidation -Model $modelNoOverride
Test-BRAVOCondition (-not $validationClean.HasErrors -and $validationClean.Findings.Count -eq 0) `
    'Configurator Validation: чиста модель без overrides -> 0 findings' `
    "HasErrors=$($validationClean.HasErrors) Findings=$($validationClean.Findings.Count)"

# ===== Persistence: 14-19 (§22 задачі) — ізольована production-директорія =====
$configuratorPersistScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIGURATOR_PERSIST_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($configuratorPersistScenarioRoot)
try {
    # 14: candidate valid -> atomic apply (на порожній production-директорії)
    $persistBaselineEmpty = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot
    $persistModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $persistBaselineEmpty.Overrides
    $persistModel = Set-BRAVOConfiguratorOverride -Model $persistModel -Path 'consoleSettings.ConsoleLevel' -Value 'ERROR'
    $persistModel = Update-BRAVOConfiguratorEffective -Model $persistModel -RuntimeRoot $configuratorFixtureRuntimeRoot
    $persistApplyValid = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot -Model $persistModel -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $persistBaselineEmpty
    Test-BRAVOCondition ($persistApplyValid.Applied -and $persistApplyValid.Stage -eq 'Complete') `
        'Configurator Persistence: валідний candidate -> atomic apply' `
        "Applied=$($persistApplyValid.Applied) Stage=$($persistApplyValid.Stage) Reasons=$($persistApplyValid.Reasons -join '; ')"

    $persistContentAfterValid = Get-Content -LiteralPath (Join-Path $configuratorPersistScenarioRoot 'BRAVO.local.config') -Raw -Encoding UTF8

    # 15: candidate invalid -> production untouched
    $persistBaselineForInvalid = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot
    $persistInvalidModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $persistBaselineForInvalid.Overrides
    $persistInvalidModel = Set-BRAVOConfiguratorOverride -Model $persistInvalidModel -Path 'componentSettings.SMB.ArchiveCopy' -Value $true
    $persistInvalidModel = Set-BRAVOConfiguratorOverride -Model $persistInvalidModel -Path 'smbSettings.RootPath' -Value ''
    $persistInvalidModel = Update-BRAVOConfiguratorEffective -Model $persistInvalidModel -RuntimeRoot $configuratorFixtureRuntimeRoot
    $persistApplyInvalid = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot -Model $persistInvalidModel -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $persistBaselineForInvalid
    $persistContentAfterInvalidAttempt = Get-Content -LiteralPath (Join-Path $configuratorPersistScenarioRoot 'BRAVO.local.config') -Raw -Encoding UTF8
    Test-BRAVOCondition ((-not $persistApplyInvalid.Applied) -and $persistApplyInvalid.Stage -eq 'Validation' -and $persistContentAfterInvalidAttempt -eq $persistContentAfterValid) `
        'Configurator Persistence: невалідний candidate -> production файл незмінний' `
        "Applied=$($persistApplyInvalid.Applied) Stage=$($persistApplyInvalid.Stage) FileUnchanged=$($persistContentAfterInvalidAttempt -eq $persistContentAfterValid)"

    # 16: baseline змінився паралельно -> STOP (race detection), без merge
    $staleBaselineForRace = $persistBaselineEmpty   # свідомо застарілий знімок (до кроку 14)
    $persistApplyRace = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot -Model $persistModel -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $staleBaselineForRace
    Test-BRAVOCondition ((-not $persistApplyRace.Applied) -and $persistApplyRace.Stage -eq 'RaceDetection') `
        'Configurator Persistence: застарілий baseline -> STOP без merge/overwrite' `
        "Applied=$($persistApplyRace.Applied) Stage=$($persistApplyRace.Stage)"

    # 17: backup створюється перед replace
    Test-BRAVOCondition ($null -ne $persistApplyValid.BackupPath -or -not $persistBaselineEmpty.Present) `
        'Configurator Persistence: backup створюється, якщо існував попередній файл (тут — перший запис, backup не очікується)' `
        "BackupPath=$($persistApplyValid.BackupPath) ProductionWasPresent=$($persistBaselineEmpty.Present)"

    # 18: unknown/newer ключ (не в схемі) переживає roundtrip
    $persistBaselineForUnknown = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot
    $mergedWithUnknown = @{}
    foreach ($existingKey in $persistBaselineForUnknown.Overrides.Keys) { $mergedWithUnknown[$existingKey] = $persistBaselineForUnknown.Overrides[$existingKey] }
    $mergedWithUnknown['maintenanceSettings.FutureFieldNotYetInSchema'] = 'preserve-me'
    [IO.File]::WriteAllText(
        (Join-Path $configuratorPersistScenarioRoot 'BRAVO.local.config'),
        (ConvertTo-BRAVOConfiguratorLocalConfigText -MergedOverrides $mergedWithUnknown),
        (New-Object System.Text.UTF8Encoding($false))
    )
    $persistBaselineWithUnknown = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot
    $persistModelWithUnknown = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $persistBaselineWithUnknown.Overrides
    $persistModelWithUnknown = Set-BRAVOConfiguratorOverride -Model $persistModelWithUnknown -Path 'progressSettings.Enabled' -Value $false
    $persistModelWithUnknown = Update-BRAVOConfiguratorEffective -Model $persistModelWithUnknown -RuntimeRoot $configuratorFixtureRuntimeRoot
    $persistApplyWithUnknown = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot -Model $persistModelWithUnknown -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $persistBaselineWithUnknown
    $persistContentWithUnknown = Get-Content -LiteralPath (Join-Path $configuratorPersistScenarioRoot 'BRAVO.local.config') -Raw -Encoding UTF8
    Test-BRAVOCondition ($persistApplyWithUnknown.Applied -and $persistContentWithUnknown -match 'FutureFieldNotYetInSchema') `
        'Configurator Persistence: невідомий/newer ключ переживає roundtrip' `
        "Applied=$($persistApplyWithUnknown.Applied) UnknownKeyPresent=$($persistContentWithUnknown -match 'FutureFieldNotYetInSchema')"

    # 19: повторний Apply без реальних змін — ідемпотентний (той самий контент/хеш)
    $persistBaselineIdem = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot
    $persistModelIdem = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $persistBaselineIdem.Overrides
    $persistModelIdem = Update-BRAVOConfiguratorEffective -Model $persistModelIdem -RuntimeRoot $configuratorFixtureRuntimeRoot
    $persistApplyIdem = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot -Model $persistModelIdem -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $persistBaselineIdem
    Test-BRAVOCondition ($persistApplyIdem.Applied -and $persistApplyIdem.NewHash -eq $persistBaselineIdem.BaselineHash) `
        'Configurator Persistence: повторний Apply без змін — ідемпотентний' `
        "Applied=$($persistApplyIdem.Applied) NewHash=$($persistApplyIdem.NewHash) BaselineHash=$($persistBaselineIdem.BaselineHash)"
    # 20 (P1-регресія за незалежним review): зламаний preserved/legacy
    # ключ (неіснуючий кореневий $global:) МУСИТЬ бути відхилений на
    # Validation-стадії, а не пройти Apply мовчки. До фіксу
    # Test-BRAVOConfiguratorCandidateOverrides прогоняв Effective лише
    # для schema-відомих Path (ConvertTo-BRAVOConfiguratorOverrideHashtable
    # мовчки відкидала цей ключ) — тепер Update-BRAVOConfiguratorEffective
    # викликається з -CandidateOverridesOverride $mergedOverrides (повний
    # набір), тому canonical loader реально бачить і відхиляє зламаний ключ.
    $persistBaselineForBrokenKey = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot
    $mergedWithBrokenKey = @{}
    foreach ($existingKey in $persistBaselineForBrokenKey.Overrides.Keys) { $mergedWithBrokenKey[$existingKey] = $persistBaselineForBrokenKey.Overrides[$existingKey] }
    $mergedWithBrokenKey['thisRootDoesNotExist.BrokenLegacyField'] = 'x'
    [IO.File]::WriteAllText(
        (Join-Path $configuratorPersistScenarioRoot 'BRAVO.local.config'),
        (ConvertTo-BRAVOConfiguratorLocalConfigText -MergedOverrides $mergedWithBrokenKey),
        (New-Object System.Text.UTF8Encoding($false))
    )
    $persistBaselineWithBrokenKey = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot
    $persistContentBeforeBrokenAttempt = Get-Content -LiteralPath (Join-Path $configuratorPersistScenarioRoot 'BRAVO.local.config') -Raw -Encoding UTF8
    $persistModelForBrokenKey = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $persistBaselineWithBrokenKey.Overrides
    $persistModelForBrokenKey = Set-BRAVOConfiguratorOverride -Model $persistModelForBrokenKey -Path 'progressSettings.Enabled' -Value $true
    $persistModelForBrokenKey = Update-BRAVOConfiguratorEffective -Model $persistModelForBrokenKey -RuntimeRoot $configuratorFixtureRuntimeRoot
    $persistApplyBrokenKey = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot -Model $persistModelForBrokenKey -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $persistBaselineWithBrokenKey
    $persistContentAfterBrokenAttempt = Get-Content -LiteralPath (Join-Path $configuratorPersistScenarioRoot 'BRAVO.local.config') -Raw -Encoding UTF8
    Test-BRAVOCondition ((-not $persistApplyBrokenKey.Applied) -and $persistApplyBrokenKey.Stage -eq 'Validation' -and $persistContentAfterBrokenAttempt -eq $persistContentBeforeBrokenAttempt) `
        'Configurator Persistence: зламаний preserved-ключ (неіснуючий root) -> Apply відхилено на Validation, не записано' `
        "Applied=$($persistApplyBrokenKey.Applied) Stage=$($persistApplyBrokenKey.Stage) Reasons=$($persistApplyBrokenKey.Reasons -join '; ')"
} finally {
    Remove-Item -LiteralPath $configuratorPersistScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ===== P2-A.7: hermetic Backup forced-failure (§Stage='Backup') =====
# Крок 11 (Copy-Item production -> .bak) провалюється, якщо WRITE у
# директорію заборонено ACL deny-rule для поточного користувача — на
# відміну від file-lock (AtomicReplace-тест нижче), READ джерела (і крок
# 10 race-check, і сам Copy-Item source-read) лишається доступним, тому
# збій ізольовано САМЕ на кроці 11, а не раніше. Реальна знахідка: до
# P2-A.7 backup Copy-Item НЕ мав власного try/catch взагалі — необроблений
# виняток пробив би Invoke-BRAVOConfiguratorApply наскрізь, порушуючи
# задокументований контракт "завжди повертає структурований результат".
$configuratorBackupFailureRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIGURATOR_BACKUPFAIL_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($configuratorBackupFailureRoot)
$backupFailureDenyRule = $null
$backupFailureAclApplied = $false
try {
    $backupFailureConfigPath = Join-Path $configuratorBackupFailureRoot 'BRAVO.local.config'
    [IO.File]::WriteAllText(
        $backupFailureConfigPath,
        (ConvertTo-BRAVOConfiguratorLocalConfigText -MergedOverrides @{ 'consoleSettings.ConsoleLevel' = 'ERROR' }),
        (New-Object System.Text.UTF8Encoding($false)))
    $backupFailureBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorBackupFailureRoot
    $backupFailureContentBefore = Get-Content -LiteralPath $backupFailureConfigPath -Raw -Encoding UTF8
    $backupFailureModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $backupFailureBaseline.Overrides
    # Issue #216, Wave 2: 'WARN' НЕ є валідним ConsoleLevel-значенням
    # (канонічний enum — TRACE/DEBUG/INFO/SUCCESS/WARNING/ERROR/FATAL,
    # BRAVO.Configuration.Schema.psm1); до Wave 2 це проходило
    # непоміченим (лише String type-check), тепер canonical loader
    # коректно відхиляє його РАНІШЕ. Тест перевіряє backup-on-apply/
    # atomic-replace, а не enum-семантику, тому досить БУДЬ-ЯКОГО
    # валідного значення, відмінного від baseline 'ERROR'.
    $backupFailureModel = Set-BRAVOConfiguratorOverride -Model $backupFailureModel -Path 'consoleSettings.ConsoleLevel' -Value 'WARNING'
    $backupFailureModel = Update-BRAVOConfiguratorEffective -Model $backupFailureModel -RuntimeRoot $configuratorFixtureRuntimeRoot

    $backupFailureAcl = Get-Acl -Path $configuratorBackupFailureRoot
    $backupFailureIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $backupFailureDenyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $backupFailureIdentity, 'CreateFiles,Write', 'ContainerInherit,ObjectInherit', 'None', 'Deny')
    $backupFailureAcl.AddAccessRule($backupFailureDenyRule)
    Set-Acl -Path $configuratorBackupFailureRoot -AclObject $backupFailureAcl
    $backupFailureAclApplied = $true

    $persistApplyBackupFailure = Invoke-BRAVOConfiguratorApply `
        -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorBackupFailureRoot `
        -Model $backupFailureModel -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $backupFailureBaseline

    # ACL знімається ПЕРЕД читанням результату/cleanup, інакше Get-Content/
    # Remove-Item нижче так само впадуть на deny-write directory.
    if ($backupFailureAclApplied) {
        $backupFailureAclRestore = Get-Acl -Path $configuratorBackupFailureRoot
        $backupFailureAclRestore.RemoveAccessRule($backupFailureDenyRule) | Out-Null
        Set-Acl -Path $configuratorBackupFailureRoot -AclObject $backupFailureAclRestore
        $backupFailureAclApplied = $false
    }

    $backupFailureContentAfter = Get-Content -LiteralPath $backupFailureConfigPath -Raw -Encoding UTF8
    $backupFailureTempLeftovers = @(Get-ChildItem -LiteralPath $configuratorBackupFailureRoot -Filter 'BRAVO.local.config.tmp-*' -ErrorAction SilentlyContinue)
    $backupFailureBakFiles = @(Get-ChildItem -LiteralPath $configuratorBackupFailureRoot -Filter 'BRAVO.local.config.bak-*' -ErrorAction SilentlyContinue)
    Test-BRAVOCondition (
        (-not $persistApplyBackupFailure.Applied) -and
        $persistApplyBackupFailure.Stage -eq 'Backup' -and
        $backupFailureContentAfter -eq $backupFailureContentBefore -and
        $backupFailureTempLeftovers.Count -eq 0 -and
        $backupFailureBakFiles.Count -eq 0 -and
        $persistApplyBackupFailure.Reasons.Count -gt 0
    ) `
        'Configurator Persistence: forced Backup failure (ACL deny-write directory) -> Applied=false Stage=Backup, оригінал незмінний, AtomicReplace/PostApplyVerification НЕ виконувались' `
        ("Applied=$($persistApplyBackupFailure.Applied) Stage=$($persistApplyBackupFailure.Stage) " +
         "ContentUnchanged=$($backupFailureContentAfter -eq $backupFailureContentBefore) TempLeftovers=$($backupFailureTempLeftovers.Count) " +
         "BakFiles=$($backupFailureBakFiles.Count) Reasons=$($persistApplyBackupFailure.Reasons -join '; ')")
} finally {
    if ($backupFailureAclApplied -and $null -ne $backupFailureDenyRule) {
        try {
            $backupFailureAclCleanup = Get-Acl -Path $configuratorBackupFailureRoot
            $backupFailureAclCleanup.RemoveAccessRule($backupFailureDenyRule) | Out-Null
            Set-Acl -Path $configuratorBackupFailureRoot -AclObject $backupFailureAclCleanup
        } catch { }
    }
    Remove-Item -LiteralPath $configuratorBackupFailureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ===== P2-A.1: hermetic AtomicReplace forced-failure (§Stage='AtomicReplace') =====
# Crок 12 (Move-Item temp -> production) провалюється, якщо production-файл
# відкритий БЕЗ FileShare.Delete — реальний, детермінований, без потреби у
# test-only seam чи змінах Persistence-коду (перевірено окремим прототипом:
# Move-Item -Force дійсно кидає "Cannot create a file when that file already
# exists" на такому handle).
$configuratorAtomicReplaceRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIGURATOR_ATOMICREPLACE_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($configuratorAtomicReplaceRoot)
try {
    $atomicReplaceConfigPath = Join-Path $configuratorAtomicReplaceRoot 'BRAVO.local.config'
    [IO.File]::WriteAllText(
        $atomicReplaceConfigPath,
        (ConvertTo-BRAVOConfiguratorLocalConfigText -MergedOverrides @{ 'consoleSettings.ConsoleLevel' = 'ERROR' }),
        (New-Object System.Text.UTF8Encoding($false)))
    $atomicReplaceBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorAtomicReplaceRoot
    $atomicReplaceContentBefore = Get-Content -LiteralPath $atomicReplaceConfigPath -Raw -Encoding UTF8
    $atomicReplaceModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $atomicReplaceBaseline.Overrides
    # Issue #216, Wave 2: див. коментар у аналогічному backup-failure
    # тесті вище — 'WARN' не є валідним ConsoleLevel-значенням.
    $atomicReplaceModel = Set-BRAVOConfiguratorOverride -Model $atomicReplaceModel -Path 'consoleSettings.ConsoleLevel' -Value 'WARNING'
    $atomicReplaceModel = Update-BRAVOConfiguratorEffective -Model $atomicReplaceModel -RuntimeRoot $configuratorFixtureRuntimeRoot

    $atomicReplaceLockStream = [System.IO.File]::Open(
        $atomicReplaceConfigPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $persistApplyAtomicReplaceFailure = Invoke-BRAVOConfiguratorApply `
            -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorAtomicReplaceRoot `
            -Model $atomicReplaceModel -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $atomicReplaceBaseline
    } finally {
        $atomicReplaceLockStream.Close()
    }
    $atomicReplaceContentAfter = Get-Content -LiteralPath $atomicReplaceConfigPath -Raw -Encoding UTF8
    $atomicReplaceTempLeftovers = @(Get-ChildItem -LiteralPath $configuratorAtomicReplaceRoot -Filter 'BRAVO.local.config.tmp-*' -ErrorAction SilentlyContinue)
    Test-BRAVOCondition (
        (-not $persistApplyAtomicReplaceFailure.Applied) -and
        $persistApplyAtomicReplaceFailure.Stage -eq 'AtomicReplace' -and
        $atomicReplaceContentAfter -eq $atomicReplaceContentBefore -and
        $atomicReplaceTempLeftovers.Count -eq 0
    ) `
        'Configurator Persistence: forced AtomicReplace failure (locked production file) -> Applied=false, оригінал незмінний, temp прибрано' `
        ("Applied=$($persistApplyAtomicReplaceFailure.Applied) Stage=$($persistApplyAtomicReplaceFailure.Stage) " +
         "ContentUnchanged=$($atomicReplaceContentAfter -eq $atomicReplaceContentBefore) TempLeftovers=$($atomicReplaceTempLeftovers.Count) " +
         "Reasons=$($persistApplyAtomicReplaceFailure.Reasons -join '; ')")
} finally {
    Remove-Item -LiteralPath $configuratorAtomicReplaceRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ===== P2-A.2: PostApplyVerification forced-mismatch (§Stage='PostApplyVerification') =====
# Test-BRAVOConfiguratorPostApplyVerification винесено з Invoke-BRAVOConfiguratorApply
# (крок 13-14) саме для цього — hermetic виклик напряму з деліберативно
# зіпсованим "щойно записаним" файлом (canonical Read-BRAVOLocalConfigurationOverrides
# відхиляє $env:-звернення невиконуючим AST-парсером), без залежності
# від таймінгу/race файлової системи.
$configuratorPostVerifyRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIGURATOR_POSTAPPLYVERIFY_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($configuratorPostVerifyRoot)
try {
    $postVerifyConfigPath = Join-Path $configuratorPostVerifyRoot 'BRAVO.local.config'
    $postVerifyBackupPath = "$postVerifyConfigPath.bak-selftest"
    $postVerifyOriginalContent = ConvertTo-BRAVOConfiguratorLocalConfigText -MergedOverrides @{ 'consoleSettings.ConsoleLevel' = 'ERROR' }
    [IO.File]::WriteAllText($postVerifyBackupPath, $postVerifyOriginalContent, (New-Object System.Text.UTF8Encoding($false)))
    # "Щойно записаний" файл — неприпустимий для data-only контракту
    # (парсер відхилить $env:-звернення) -> reload на кроці 13 гарантовано впаде.
    [IO.File]::WriteAllText($postVerifyConfigPath, "@{ 'x' = `$env:PATH }", (New-Object System.Text.UTF8Encoding($false)))

    $postVerifyResultWithBackup = Test-BRAVOConfiguratorPostApplyVerification `
        -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPostVerifyRoot `
        -ProductionConfigPath $postVerifyConfigPath -BackupPath $postVerifyBackupPath
    $postVerifyContentAfterRollback = Get-Content -LiteralPath $postVerifyConfigPath -Raw -Encoding UTF8
    Test-BRAVOCondition (
        ($null -ne $postVerifyResultWithBackup) -and
        (-not $postVerifyResultWithBackup.Applied) -and
        $postVerifyResultWithBackup.Stage -eq 'PostApplyVerification' -and
        $postVerifyContentAfterRollback -eq $postVerifyOriginalContent
    ) `
        'Configurator Persistence: forced PostApplyVerification mismatch (backup наявний) -> Applied=false, rollback з backup, фінальний стан = оригінал' `
        ("Applied=$($postVerifyResultWithBackup.Applied) Stage=$($postVerifyResultWithBackup.Stage) " +
         "RolledBackToOriginal=$($postVerifyContentAfterRollback -eq $postVerifyOriginalContent) " +
         "Reasons=$($postVerifyResultWithBackup.Reasons -join '; ')")

    # Без backup (симулює перший-у-житті запис, що самé виявився зіпсованим) ->
    # rollback видаляє файл, а не лишає невалідований production-стан.
    [IO.File]::WriteAllText($postVerifyConfigPath, "@{ 'x' = `$env:PATH }", (New-Object System.Text.UTF8Encoding($false)))
    $postVerifyResultNoBackup = Test-BRAVOConfiguratorPostApplyVerification `
        -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPostVerifyRoot `
        -ProductionConfigPath $postVerifyConfigPath
    $postVerifyFileRemainsAfterNoBackupRollback = Test-Path -LiteralPath $postVerifyConfigPath -PathType Leaf
    Test-BRAVOCondition (
        ($null -ne $postVerifyResultNoBackup) -and
        (-not $postVerifyResultNoBackup.Applied) -and
        $postVerifyResultNoBackup.Stage -eq 'PostApplyVerification' -and
        (-not $postVerifyFileRemainsAfterNoBackupRollback)
    ) `
        'Configurator Persistence: forced PostApplyVerification mismatch (без backup) -> Applied=false, rollback видаляє файл' `
        ("Applied=$($postVerifyResultNoBackup.Applied) Stage=$($postVerifyResultNoBackup.Stage) " +
         "FileRemains=$postVerifyFileRemainsAfterNoBackupRollback Reasons=$($postVerifyResultNoBackup.Reasons -join '; ')")

    # Успішна верифікація (валідний "щойно записаний" файл) -> $null,
    # Apply продовжує до Complete (те саме, що вже покривають тести 14/19 вище).
    [IO.File]::WriteAllText($postVerifyConfigPath, $postVerifyOriginalContent, (New-Object System.Text.UTF8Encoding($false)))
    $postVerifyResultSuccess = Test-BRAVOConfiguratorPostApplyVerification `
        -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPostVerifyRoot `
        -ProductionConfigPath $postVerifyConfigPath -BackupPath $postVerifyBackupPath
    Test-BRAVOCondition ($null -eq $postVerifyResultSuccess) `
        'Configurator Persistence: PostApplyVerification успішна -> $null (Apply продовжує до Complete)' `
        "Result=$postVerifyResultSuccess"
} finally {
    Remove-Item -LiteralPath $configuratorPostVerifyRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ===== 21 (P2-регресія за незалежним review): EffectiveSource для масивів =====
# Test-BRAVOConfiguratorValueEquality замінив '-eq' (element-wise для
# масивів зліва — завжди хибний 'Derived' навіть для дійсно рівних
# масивів) на справжнє глибоке порівняння.
# BravoDisplayName має 2 елементи в BRAVO.config default (@("BRAVO Service",
# "BRAVO Server")) — з ОДНИМ елементом '-eq' на масивах випадково давав
# truthy результат (element-wise match повертає непорожній масив), тому
# саме 2+-елементний масив реально демонструє баг/фікс.
$configuratorArrayPathForEquality = 'maintenanceSettings.Services.BravoDisplayName'
$modelArrayNoOverride = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{}
$modelArrayNoOverride = Update-BRAVOConfiguratorEffective -Model $modelArrayNoOverride -RuntimeRoot $configuratorFixtureRuntimeRoot
$arraySettingNoOverride = @($modelArrayNoOverride | Where-Object { $_.Path -eq $configuratorArrayPathForEquality })
Test-BRAVOCondition ($arraySettingNoOverride.Count -eq 1 -and $arraySettingNoOverride[0].EffectiveSource -eq 'Default') `
    'Configurator Model: EffectiveSource для StringArray без override -> Default (не хибний Derived)' `
    "Path=$configuratorArrayPathForEquality EffectiveSource=$($arraySettingNoOverride[0].EffectiveSource) Effective=$($arraySettingNoOverride[0].EffectiveValue -join ',') Default=$($arraySettingNoOverride[0].DefaultValue -join ',')"

# ===== P1.1 незалежний review (2 P2-регресії) =====

# L: hashtable-значення у candidate -> ConvertTo-BRAVOConfiguratorPowerShellLiteral
# явно відхиляє (fail-closed), а не рекурсує до call-depth overflow.
$configuratorHashtableLiteralThrew = $false
$configuratorHashtableLiteralMessage = $null
try {
    [void](ConvertTo-BRAVOConfiguratorPowerShellLiteral -Value @{ Nested = 'value' })
} catch {
    $configuratorHashtableLiteralThrew = $true
    $configuratorHashtableLiteralMessage = $_.Exception.Message
}
Test-BRAVOCondition ($configuratorHashtableLiteralThrew -and $configuratorHashtableLiteralMessage -notmatch 'call depth overflow') `
    'Configurator Effective: hashtable-значення відхиляється явним винятком, не рекурсією до call depth overflow' `
    "Threw=$configuratorHashtableLiteralThrew Message=$configuratorHashtableLiteralMessage"

# M: BAZA_APP_SFTP raw=false + SFTP.Enabled=false -> DisabledReason НЕ
# приписується master-у (Effective=false спричинений власним raw-вибором
# оператора, а не глобальним вимикачем).
$modelScenarioM = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SFTP.Enabled' = $false
    'componentSettings.Synchronization.BAZA_APP_SFTP' = $false
}
$modelScenarioM = Update-BRAVOConfiguratorEffective -Model $modelScenarioM -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioM = @($modelScenarioM | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_SFTP' })
Test-BRAVOCondition ($settingScenarioM.Count -eq 1 -and [bool]$settingScenarioM[0].EffectiveValue -eq $false -and [string]::IsNullOrWhiteSpace([string]$settingScenarioM[0].DisabledReason)) `
    'Configurator 5.2.2 Scenario M: BAZA_APP_SFTP raw=false + SFTP.Enabled=false -> DisabledReason НЕ приписується master-у (власний вибір оператора)' `
    "Effective=$($settingScenarioM[0].EffectiveValue) DisabledReason=$($settingScenarioM[0].DisabledReason)"

# ===== P1.7 Credentials: requirement-формула (детерміновано, без
# звернення до Credential Manager — CI-гермет) =====

# N: SFTP master OFF -> Required=false, незалежно від child-прапорців.
$credentialEffectiveSftpOff = [pscustomobject]@{
    storageEffective  = [pscustomobject]@{
        SFTP = [pscustomobject]@{ Enabled = $false; ArchiveUpload = $false; DisabledReason = 'SFTP глобально вимкнено (componentSettings.SFTP.Enabled = $false)' }
        SMB  = [pscustomobject]@{ Enabled = $true; ArchiveCopy = $false; DisabledReason = $null }
    }
    bazaSyncEffective = [pscustomobject]@{ ScheduledSftpSyncRequired = $false }
    backupMonitoring  = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $true }; SMB = [pscustomobject]@{ Enabled = $true } }
}
$credentialRequirementSftpOff = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $credentialEffectiveSftpOff
Test-BRAVOCondition (-not $credentialRequirementSftpOff.SFTP.Required) `
    'Configurator Credentials: SFTP master OFF -> SFTP credentials НЕ обов''язкові' `
    "Required=$($credentialRequirementSftpOff.SFTP.Required)"

# O: SFTP master ON + ArchiveUpload=true -> Required=true.
$credentialEffectiveSftpOn = [pscustomobject]@{
    storageEffective  = [pscustomobject]@{
        SFTP = [pscustomobject]@{ Enabled = $true; ArchiveUpload = $true; DisabledReason = $null }
        SMB  = [pscustomobject]@{ Enabled = $true; ArchiveCopy = $false; DisabledReason = $null }
    }
    bazaSyncEffective = [pscustomobject]@{ ScheduledSftpSyncRequired = $false }
    backupMonitoring  = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $false }; SMB = [pscustomobject]@{ Enabled = $false } }
}
$credentialRequirementSftpOn = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $credentialEffectiveSftpOn
Test-BRAVOCondition ($credentialRequirementSftpOn.SFTP.Required) `
    'Configurator Credentials: SFTP operational (master ON + ArchiveUpload) -> credentials обов''язкові' `
    "Required=$($credentialRequirementSftpOn.SFTP.Required)"

# P: SMB master OFF (storageEffective.SMB.ArchiveCopy вже false за
# конструкцією резолвера) -> Required=false.
$credentialRequirementSmbOff = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $credentialEffectiveSftpOn
Test-BRAVOCondition (-not $credentialRequirementSmbOff.SMB.Required) `
    'Configurator Credentials: SMB.ArchiveCopy effective=false -> SMB credentials НЕ обов''язкові' `
    "Required=$($credentialRequirementSmbOff.SMB.Required)"

# Q: SMB operational (ArchiveCopy effective=true) -> Required=true.
$credentialEffectiveSmbOn = [pscustomobject]@{
    storageEffective  = [pscustomobject]@{
        SFTP = [pscustomobject]@{ Enabled = $false; ArchiveUpload = $false; DisabledReason = $null }
        SMB  = [pscustomobject]@{ Enabled = $true; ArchiveCopy = $true; DisabledReason = $null }
    }
    bazaSyncEffective = [pscustomobject]@{ ScheduledSftpSyncRequired = $false }
    backupMonitoring  = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $false }; SMB = [pscustomobject]@{ Enabled = $false } }
}
$credentialRequirementSmbOn = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $credentialEffectiveSmbOn
Test-BRAVOCondition ($credentialRequirementSmbOn.SMB.Required) `
    'Configurator Credentials: SMB operational (ArchiveCopy effective=true) -> credentials обов''язкові' `
    "Required=$($credentialRequirementSmbOn.SMB.Required)"

# R: Health-only SFTP monitoring (backupMonitoring.SFTP.Enabled=true) з
# master ON, без ArchiveUpload/BAZA sync -> все одно Required=true (Health
# monitoring сам по собі законна причина потребувати креденшели, доки
# master увімкнений) — canonical формула, не Configurator-вигадка.
$credentialEffectiveHealthOnly = [pscustomobject]@{
    storageEffective  = [pscustomobject]@{
        SFTP = [pscustomobject]@{ Enabled = $true; ArchiveUpload = $false; DisabledReason = $null }
        SMB  = [pscustomobject]@{ Enabled = $true; ArchiveCopy = $false; DisabledReason = $null }
    }
    bazaSyncEffective = [pscustomobject]@{ ScheduledSftpSyncRequired = $false }
    backupMonitoring  = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $true }; SMB = [pscustomobject]@{ Enabled = $false } }
}
$credentialRequirementHealthOnly = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $credentialEffectiveHealthOnly
Test-BRAVOCondition ($credentialRequirementHealthOnly.SFTP.Required) `
    'Configurator Credentials: SFTP Health-моніторинг увімкнено (master ON) -> credentials обов''язкові (навіть без ArchiveUpload/BAZA sync)' `
    "Required=$($credentialRequirementHealthOnly.SFTP.Required)"

# S: смоук-тест реального (non-mutating) прогону -Action Test через
# Invoke-BRAVOConfiguratorCredentialCheck — НЕ прив'язується до
# конкретного Found/Missing (CI-runner може не мати credential), лише
# перевіряє, що виклик повертає валідний статус без винятку.
$configuratorCredentialCheckResult = Invoke-BRAVOConfiguratorCredentialCheck -RuntimeRoot $root -Component 'SFTP' -TimeoutSeconds 30
Test-BRAVOCondition ($configuratorCredentialCheckResult.Status -in @('Found', 'Missing', 'Error')) `
    'Configurator Credentials: Invoke-BRAVOConfiguratorCredentialCheck повертає валідний статус без винятку (CI-гермет, не прив''язано до Found/Missing)' `
    "Status=$($configuratorCredentialCheckResult.Status) ExitCode=$($configuratorCredentialCheckResult.ExitCode) Reason=$($configuratorCredentialCheckResult.Reason)"

# ===== P1.6 Presets: чисті model-трансформації (не пишуть файл) =====

$configuratorPresetBaseModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{}
# Навмисний unrelated override ДО preset — має пережити будь-який preset.
$configuratorPresetBaseModel = Set-BRAVOConfiguratorOverride -Model $configuratorPresetBaseModel -Path 'consoleSettings.ConsoleLevel' -Value 'ERROR'

# T: LocalOnly -> SFTP.Enabled=false, SMB.Enabled=false.
$configuratorPresetLocalOnly = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetBaseModel -PresetName 'LocalOnly'
$configuratorPresetLocalOnlySftp = @($configuratorPresetLocalOnly | Where-Object { $_.Path -eq 'componentSettings.SFTP.Enabled' })
$configuratorPresetLocalOnlySmb = @($configuratorPresetLocalOnly | Where-Object { $_.Path -eq 'componentSettings.SMB.Enabled' })
Test-BRAVOCondition ($configuratorPresetLocalOnlySftp.Count -eq 1 -and [bool]$configuratorPresetLocalOnlySftp[0].OverrideValue -eq $false -and [bool]$configuratorPresetLocalOnlySmb[0].OverrideValue -eq $false) `
    'Configurator Presets: LocalOnly -> SFTP.Enabled=false, SMB.Enabled=false' `
    "SFTP=$($configuratorPresetLocalOnlySftp[0].OverrideValue) SMB=$($configuratorPresetLocalOnlySmb[0].OverrideValue)"

# U: unrelated override (consoleSettings.ConsoleLevel) переживає preset.
$configuratorPresetLocalOnlyConsole = @($configuratorPresetLocalOnly | Where-Object { $_.Path -eq 'consoleSettings.ConsoleLevel' })
Test-BRAVOCondition ($configuratorPresetLocalOnlyConsole.Count -eq 1 -and [string]$configuratorPresetLocalOnlyConsole[0].OverrideValue -eq 'ERROR') `
    'Configurator Presets: preset не стирає unrelated override (consoleSettings.ConsoleLevel)' `
    "ConsoleLevel=$($configuratorPresetLocalOnlyConsole[0].OverrideValue)"

# V: LocalPlusSFTPAndSMB -> обидва master=true.
$configuratorPresetBoth = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetBaseModel -PresetName 'LocalPlusSFTPAndSMB'
$configuratorPresetBothSftp = @($configuratorPresetBoth | Where-Object { $_.Path -eq 'componentSettings.SFTP.Enabled' })
$configuratorPresetBothSmb = @($configuratorPresetBoth | Where-Object { $_.Path -eq 'componentSettings.SMB.Enabled' })
Test-BRAVOCondition ([bool]$configuratorPresetBothSftp[0].OverrideValue -eq $true -and [bool]$configuratorPresetBothSmb[0].OverrideValue -eq $true) `
    'Configurator Presets: LocalPlusSFTPAndSMB -> SFTP.Enabled=true, SMB.Enabled=true' `
    "SFTP=$($configuratorPresetBothSftp[0].OverrideValue) SMB=$($configuratorPresetBothSmb[0].OverrideValue)"

# W: idempotent — повторне застосування того самого preset дає той самий результат.
$configuratorPresetLocalOnlyTwice = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetLocalOnly -PresetName 'LocalOnly'
$configuratorPresetLocalOnlyTwiceSftp = @($configuratorPresetLocalOnlyTwice | Where-Object { $_.Path -eq 'componentSettings.SFTP.Enabled' })
Test-BRAVOCondition ([bool]$configuratorPresetLocalOnlyTwiceSftp[0].OverrideValue -eq $false) `
    'Configurator Presets: повторне застосування LocalOnly — ідемпотентне' `
    "SFTP=$($configuratorPresetLocalOnlyTwiceSftp[0].OverrideValue)"

# X: master OFF (preset) не втрачає раніше виставлений child raw override
# — той самий master/child контракт, що ручне редагування.
$configuratorPresetChildBase = Set-BRAVOConfiguratorOverride -Model $configuratorPresetBaseModel -Path 'componentSettings.SFTP.ArchiveUpload' -Value $true
$configuratorPresetChildAfterLocalOnly = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetChildBase -PresetName 'LocalOnly'
$configuratorPresetChildSetting = @($configuratorPresetChildAfterLocalOnly | Where-Object { $_.Path -eq 'componentSettings.SFTP.ArchiveUpload' })
Test-BRAVOCondition ($configuratorPresetChildSetting.Count -eq 1 -and [bool]$configuratorPresetChildSetting[0].OverrideValue -eq $true) `
    'Configurator Presets: LocalOnly НЕ стирає child raw override (ArchiveUpload лишається true, лише Effective зміниться)' `
    "ArchiveUpload Raw=$($configuratorPresetChildSetting[0].OverrideValue)"

# Y: Current/Manual — no-op, жодне override-значення не змінюється
# (порівняння за вмістом, не за object reference — PowerShell типізоване
# [array]-параметр-зв'язування не гарантує той самий фізичний масив).
$configuratorPresetCurrent = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetBaseModel -PresetName 'Current'
$configuratorPresetCurrentConsole = @($configuratorPresetCurrent | Where-Object { $_.Path -eq 'consoleSettings.ConsoleLevel' })
$configuratorPresetCurrentSftp = @($configuratorPresetCurrent | Where-Object { $_.Path -eq 'componentSettings.SFTP.Enabled' })
Test-BRAVOCondition (
    $configuratorPresetCurrent.Count -eq $configuratorPresetBaseModel.Count -and
    [string]$configuratorPresetCurrentConsole[0].OverrideValue -eq 'ERROR' -and
    -not $configuratorPresetCurrentSftp[0].OverridePresent
) `
    'Configurator Presets: Current — no-op (жодне override-значення не змінюється)' `
    "Count=$($configuratorPresetCurrent.Count)/$($configuratorPresetBaseModel.Count) Console=$($configuratorPresetCurrentConsole[0].OverrideValue) SftpOverridePresent=$($configuratorPresetCurrentSftp[0].OverridePresent)"

# ===== feat/bravo-configurator-preset-baza-local: BAZA_*_LOCAL/BAZA_*_SFTP
# preset-контракт (§ user-approved manual acceptance follow-up, item 13) =====

# AC2: LocalOnly -> BAZA_APP_LOCAL=true, BAZA_WWW_LOCAL=true ("усі
# локальні опції увімкнено", коли SFTP/SMB глобально вимкнені).
$configuratorPresetLocalOnlyBazaAppLocal = @($configuratorPresetLocalOnly | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_LOCAL' })
$configuratorPresetLocalOnlyBazaWwwLocal = @($configuratorPresetLocalOnly | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_LOCAL' })
Test-BRAVOCondition (
    $configuratorPresetLocalOnlyBazaAppLocal.Count -eq 1 -and [bool]$configuratorPresetLocalOnlyBazaAppLocal[0].OverrideValue -eq $true -and
    $configuratorPresetLocalOnlyBazaWwwLocal.Count -eq 1 -and [bool]$configuratorPresetLocalOnlyBazaWwwLocal[0].OverrideValue -eq $true
) `
    'Configurator Presets: LocalOnly -> BAZA_APP_LOCAL=true, BAZA_WWW_LOCAL=true' `
    "BAZA_APP_LOCAL=$($configuratorPresetLocalOnlyBazaAppLocal[0].OverrideValue) BAZA_WWW_LOCAL=$($configuratorPresetLocalOnlyBazaWwwLocal[0].OverrideValue)"

# AC3: LocalOnly НЕ виставляє override для BAZA_*_SFTP (master і так
# вимкнений — child raw цих двох шляхів лишається незмінним/відсутнім).
$configuratorPresetLocalOnlyBazaAppSftp = @($configuratorPresetLocalOnly | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_SFTP' })
$configuratorPresetLocalOnlyBazaWwwSftp = @($configuratorPresetLocalOnly | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_SFTP' })
Test-BRAVOCondition (
    -not $configuratorPresetLocalOnlyBazaAppSftp[0].OverridePresent -and
    -not $configuratorPresetLocalOnlyBazaWwwSftp[0].OverridePresent
) `
    'Configurator Presets: LocalOnly НЕ виставляє override для BAZA_APP_SFTP/BAZA_WWW_SFTP' `
    "AppSftpOverridePresent=$($configuratorPresetLocalOnlyBazaAppSftp[0].OverridePresent) WwwSftpOverridePresent=$($configuratorPresetLocalOnlyBazaWwwSftp[0].OverridePresent)"

# AC4: LocalPlusSMB регресія (критичний негативний тест) — застосування
# LocalPlusSMB до моделі з ПОПЕРЕДНЬО виставленими BAZA-override НЕ
# змінює їх. Немає BAZA-over-SMB transport у кодовій базі — вимкнення
# BAZA_*_LOCAL тут осиротило б BAZA без жодного каналу синхронізації.
$configuratorPresetSmbBazaBase = Set-BRAVOConfiguratorOverride -Model $configuratorPresetBaseModel -Path 'componentSettings.Synchronization.BAZA_APP_LOCAL' -Value $true
$configuratorPresetSmbBazaBase = Set-BRAVOConfiguratorOverride -Model $configuratorPresetSmbBazaBase -Path 'componentSettings.Synchronization.BAZA_WWW_SFTP' -Value $true
$configuratorPresetLocalPlusSmb = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetSmbBazaBase -PresetName 'LocalPlusSMB'
$configuratorPresetLocalPlusSmbBazaAppLocal = @($configuratorPresetLocalPlusSmb | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_LOCAL' })
$configuratorPresetLocalPlusSmbBazaWwwSftp = @($configuratorPresetLocalPlusSmb | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_SFTP' })
Test-BRAVOCondition (
    [bool]$configuratorPresetLocalPlusSmbBazaAppLocal[0].OverrideValue -eq $true -and
    [bool]$configuratorPresetLocalPlusSmbBazaWwwSftp[0].OverrideValue -eq $true
) `
    'Configurator Presets: LocalPlusSMB НЕ змінює раніше виставлені BAZA-overrides (немає BAZA-over-SMB каналу)' `
    "BAZA_APP_LOCAL=$($configuratorPresetLocalPlusSmbBazaAppLocal[0].OverrideValue) BAZA_WWW_SFTP=$($configuratorPresetLocalPlusSmbBazaWwwSftp[0].OverrideValue)"

# AC5: LocalPlusSFTP / LocalPlusSFTPAndSMB -> BAZA_APP_LOCAL=false,
# BAZA_APP_SFTP=true, BAZA_WWW_LOCAL=false, BAZA_WWW_SFTP=true.
# BAZA_WWW_SFTP форсується true РАЗОМ з BAZA_WWW_LOCAL=false навмисно
# (schema default BAZA_WWW_SFTP=$false, "вмикайте свідомо" — без цього
# форсування WWW-компонент лишився б без жодного каналу синхронізації).
foreach ($bazaPresetName in @('LocalPlusSFTP', 'LocalPlusSFTPAndSMB')) {
    $configuratorPresetBazaResult = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetBaseModel -PresetName $bazaPresetName
    $bazaAppLocal = @($configuratorPresetBazaResult | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_LOCAL' })
    $bazaAppSftp  = @($configuratorPresetBazaResult | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_SFTP' })
    $bazaWwwLocal = @($configuratorPresetBazaResult | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_LOCAL' })
    $bazaWwwSftp  = @($configuratorPresetBazaResult | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_SFTP' })
    Test-BRAVOCondition (
        [bool]$bazaAppLocal[0].OverrideValue -eq $false -and [bool]$bazaAppSftp[0].OverrideValue -eq $true -and
        [bool]$bazaWwwLocal[0].OverrideValue -eq $false -and [bool]$bazaWwwSftp[0].OverrideValue -eq $true
    ) `
        "Configurator Presets: $bazaPresetName -> BAZA_APP_LOCAL=false, BAZA_APP_SFTP=true, BAZA_WWW_LOCAL=false, BAZA_WWW_SFTP=true" `
        "AppLocal=$($bazaAppLocal[0].OverrideValue) AppSftp=$($bazaAppSftp[0].OverrideValue) WwwLocal=$($bazaWwwLocal[0].OverrideValue) WwwSftp=$($bazaWwwSftp[0].OverrideValue)"
}

# AC6: ідемпотентність — той самий патерн, що тест W, тепер для BAZA-шляхів.
$configuratorPresetLocalOnlyTwiceBaza = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetLocalOnly -PresetName 'LocalOnly'
$configuratorPresetLocalOnlyTwiceBazaAppLocal = @($configuratorPresetLocalOnlyTwiceBaza | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_LOCAL' })
$configuratorPresetLocalOnlyTwiceBazaWwwLocal = @($configuratorPresetLocalOnlyTwiceBaza | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_LOCAL' })
Test-BRAVOCondition (
    [bool]$configuratorPresetLocalOnlyTwiceBazaAppLocal[0].OverrideValue -eq $true -and
    [bool]$configuratorPresetLocalOnlyTwiceBazaWwwLocal[0].OverrideValue -eq $true
) `
    'Configurator Presets: повторне застосування LocalOnly — ідемпотентне і для BAZA_*_LOCAL' `
    "BAZA_APP_LOCAL=$($configuratorPresetLocalOnlyTwiceBazaAppLocal[0].OverrideValue) BAZA_WWW_LOCAL=$($configuratorPresetLocalOnlyTwiceBazaWwwLocal[0].OverrideValue)"

$configuratorPresetSftpBothTwiceBaza = Invoke-BRAVOConfiguratorPreset -Model (Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetBaseModel -PresetName 'LocalPlusSFTPAndSMB') -PresetName 'LocalPlusSFTPAndSMB'
$configuratorPresetSftpBothTwiceBazaWwwSftp = @($configuratorPresetSftpBothTwiceBaza | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_SFTP' })
Test-BRAVOCondition ([bool]$configuratorPresetSftpBothTwiceBazaWwwSftp[0].OverrideValue -eq $true) `
    'Configurator Presets: повторне застосування LocalPlusSFTPAndSMB — ідемпотентне для BAZA_WWW_SFTP' `
    "BAZA_WWW_SFTP=$($configuratorPresetSftpBothTwiceBazaWwwSftp[0].OverrideValue)"

# ===== P1.8 Preview: семантичний diff =====

$configuratorPreviewBefore = Update-BRAVOConfiguratorEffective -Model $configuratorPresetBaseModel -RuntimeRoot $configuratorFixtureRuntimeRoot
$configuratorPresetForPreview = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetBaseModel -PresetName 'LocalOnly'
$configuratorPreviewAfter = Update-BRAVOConfiguratorEffective -Model $configuratorPresetForPreview -RuntimeRoot $configuratorFixtureRuntimeRoot
$configuratorPreviewResult = Get-BRAVOConfiguratorPreview -ModelBefore $configuratorPreviewBefore -ModelAfter $configuratorPreviewAfter

# Z: Raw diff містить рівно 4 зміни для LocalOnly (2 master-switch +
# BAZA_APP_LOCAL/BAZA_WWW_LOCAL — feat/bravo-configurator-preset-baza-local).
$configuratorPreviewRawPaths = @($configuratorPreviewResult.RawChanges | ForEach-Object { $_.Path } | Sort-Object)
Test-BRAVOCondition (@(Compare-Object $configuratorPreviewRawPaths @(
    'componentSettings.SFTP.Enabled',
    'componentSettings.SMB.Enabled',
    'componentSettings.Synchronization.BAZA_APP_LOCAL',
    'componentSettings.Synchronization.BAZA_WWW_LOCAL'
)).Count -eq 0) `
    'Configurator Preview: Raw diff = рівно 4 зміни для LocalOnly (2 master-switch + 2 BAZA_*_LOCAL)' `
    "RawChanges=$($configuratorPreviewRawPaths -join ',')"

# AA: Effective diff НЕ порожній (SFTP/SMB вимкнення реально змінює
# ефективну поведінку принаймні одного залежного поля).
Test-BRAVOCondition ($configuratorPreviewResult.EffectiveChanges.Count -gt 0) `
    'Configurator Preview: Effective diff непорожній для LocalOnly preset' `
    "EffectiveChanges=$($configuratorPreviewResult.EffectiveChanges.Count)"

# AB: HasBlockingErrors коректно відображає чисту (без ERROR) модель.
Test-BRAVOCondition (-not $configuratorPreviewResult.HasBlockingErrors) `
    'Configurator Preview: HasBlockingErrors=false для валідної LocalOnly-моделі' `
    "HasBlockingErrors=$($configuratorPreviewResult.HasBlockingErrors)"

# AC: Preview без реальних змін (той самий Before/After) -> HasChanges=false.
$configuratorPreviewNoChangeResult = Get-BRAVOConfiguratorPreview -ModelBefore $configuratorPreviewBefore -ModelAfter $configuratorPreviewBefore
Test-BRAVOCondition (-not $configuratorPreviewNoChangeResult.HasChanges) `
    'Configurator Preview: Before==After -> HasChanges=false' `
    "HasChanges=$($configuratorPreviewNoChangeResult.HasChanges)"

# ===== P2-A.3: справжній diff-based Dirty (Test-BRAVOConfiguratorModelDirty) —
# заміна подієвого Model[].Dirty прапорця, який лишався $true назавжди
# після edit -> revert до оригіналу (P3 "phantom Dirty", P1-стабілізація). =====

$dirtyArrayPath = 'maintenanceSettings.Services.BravoDisplayName'
$dirtyStringPath = 'consoleSettings.ConsoleLevel'

# AD: чиста модель без overrides проти порожнього baseline -> Dirty=false
$dirtyModelClean = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{}
Test-BRAVOCondition (-not (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelClean -BaselineOverrides @{})) `
    'Configurator Dirty: чиста модель проти порожнього baseline -> false' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelClean -BaselineOverrides @{})"

# AE: edit -> Dirty=true
$dirtyModelEdited = Set-BRAVOConfiguratorOverride -Model $dirtyModelClean -Path $dirtyStringPath -Value 'ERROR'
Test-BRAVOCondition (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelEdited -BaselineOverrides @{}) `
    'Configurator Dirty: edit -> true' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelEdited -BaselineOverrides @{})"

# AF: edit -> revert (Clear, повертає до "без override", яким і був baseline) -> Dirty=false
$dirtyModelReverted = Clear-BRAVOConfiguratorOverride -Model $dirtyModelEdited -Path $dirtyStringPath
Test-BRAVOCondition (-not (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelReverted -BaselineOverrides @{})) `
    'Configurator Dirty: edit -> revert (Clear) до оригіналу -> false' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelReverted -BaselineOverrides @{})"

# AG: edit значенням, рівним поточному Default, все одно Dirty=true, якщо
# baseline не мав override (OverridePresent сам по собі — частина diff,
# не лише значення) — "false override" != "absent override".
$dirtyDefaultConsoleLevel = ($dirtyModelClean | Where-Object { $_.Path -eq $dirtyStringPath })[0].DefaultValue
$dirtyModelSameAsDefault = Set-BRAVOConfiguratorOverride -Model $dirtyModelClean -Path $dirtyStringPath -Value $dirtyDefaultConsoleLevel
Test-BRAVOCondition (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelSameAsDefault -BaselineOverrides @{}) `
    'Configurator Dirty: явний override == Default value, але baseline не мав override -> true (OverridePresent частина diff)' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelSameAsDefault -BaselineOverrides @{}) OverrideValue=$dirtyDefaultConsoleLevel Default=$dirtyDefaultConsoleLevel"

# AH: baseline МАВ override -> модель побудована з нього -> false; Clear -> true
# ("clear override" != "absent baseline" — реальна зміна, якщо baseline був present)
$dirtyBaselineWithOverride = @{ $dirtyStringPath = 'WARN' }
$dirtyModelFromBaseline = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $dirtyBaselineWithOverride
Test-BRAVOCondition (-not (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelFromBaseline -BaselineOverrides $dirtyBaselineWithOverride)) `
    'Configurator Dirty: модель побудована з baseline -> false (щойно Load/Reload)' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelFromBaseline -BaselineOverrides $dirtyBaselineWithOverride)"
$dirtyModelClearedFromBaseline = Clear-BRAVOConfiguratorOverride -Model $dirtyModelFromBaseline -Path $dirtyStringPath
Test-BRAVOCondition (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelClearedFromBaseline -BaselineOverrides $dirtyBaselineWithOverride) `
    'Configurator Dirty: baseline мав override, Clear прибирає його -> true' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelClearedFromBaseline -BaselineOverrides $dirtyBaselineWithOverride)"

# AI: false override != absent override (Boolean-специфічний випадок)
$dirtyBooleanPath = 'componentSettings.SFTP.ArchiveUpload'
$dirtyModelFalseOverride = Set-BRAVOConfiguratorOverride -Model $dirtyModelClean -Path $dirtyBooleanPath -Value $false
Test-BRAVOCondition (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelFalseOverride -BaselineOverrides @{}) `
    'Configurator Dirty: явний override=false проти відсутнього baseline -> true (false != absent)' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelFalseOverride -BaselineOverrides @{})"

# AJ: масив — той самий порядок елементів, що baseline -> Dirty=false; інший порядок -> true
$dirtyArrayDefault = @(($dirtyModelClean | Where-Object { $_.Path -eq $dirtyArrayPath })[0].DefaultValue)
$dirtyBaselineWithArray = @{ $dirtyArrayPath = $dirtyArrayDefault }
$dirtyModelArraySameOrder = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $dirtyBaselineWithArray
Test-BRAVOCondition (-not (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelArraySameOrder -BaselineOverrides $dirtyBaselineWithArray)) `
    'Configurator Dirty: масив, той самий порядок що baseline -> false' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelArraySameOrder -BaselineOverrides $dirtyBaselineWithArray)"
$dirtyArrayReversedList = $dirtyArrayDefault.Clone()
[array]::Reverse($dirtyArrayReversedList)
$dirtyModelArrayReordered = Set-BRAVOConfiguratorOverride -Model $dirtyModelArraySameOrder -Path $dirtyArrayPath -Value $dirtyArrayReversedList
Test-BRAVOCondition (
    ($dirtyArrayReversedList.Count -lt 2) -or (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelArrayReordered -BaselineOverrides $dirtyBaselineWithArray)
) `
    'Configurator Dirty: масив з іншим порядком елементів проти baseline -> true' `
    "ArrayCount=$($dirtyArrayReversedList.Count) Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelArrayReordered -BaselineOverrides $dirtyBaselineWithArray)"

# ===== PR #224 review (P2, "Resolve nested baselines in dirty checks") —
# Test-BRAVOConfiguratorModelDirty тепер читає baseline через канонічний
# Resolve-BRAVOConfiguratorSuppliedLeafOverride (замість прямого
# $BaselineOverrides.Contains($setting.Path)), тому вкладена (Node)
# baseline-форма розпізнається так само, як і плоска. =====

$nestedDirtyContainerPath = 'bravoSettings.NotificationRouting'
$nestedDirtySuccessPath = 'bravoSettings.NotificationRouting.SUCCESS'
$nestedDirtyWarningPath = 'bravoSettings.NotificationRouting.WARNING'

# A1 / Configurator/NestedBaselineUntouchedIsNotDirty: baseline supplied у
# вкладеній Node-формі, модель побудована з неї й НЕ торкана -> false
# (пряме відтворення review-знахідки: раніше Contains($setting.Path)
# завжди повертав $false для цього baseline і звітував dirty=true).
$nestedDirtyBaseline = @{ $nestedDirtyContainerPath = @{ SUCCESS = 'alerts'; WARNING = 'general' } }
$nestedDirtyModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $nestedDirtyBaseline
Test-BRAVOCondition (-not (Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyModel -BaselineOverrides $nestedDirtyBaseline)) `
    'Configurator/NestedBaselineUntouchedIsNotDirty: вкладена (Node) baseline, модель нею ж побудована й не торкана -> false' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyModel -BaselineOverrides $nestedDirtyBaseline)"

# A2 / Configurator/NestedBaselineChangedIsDirty: змінити один вкладений
# leaf -> true.
$nestedDirtyModelChanged = Set-BRAVOConfiguratorOverride -Model $nestedDirtyModel -Path $nestedDirtySuccessPath -Value 'general'
Test-BRAVOCondition (Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyModelChanged -BaselineOverrides $nestedDirtyBaseline) `
    'Configurator/NestedBaselineChangedIsDirty: зміна одного вкладеного leaf проти вкладеного baseline -> true' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyModelChanged -BaselineOverrides $nestedDirtyBaseline)"

# A3 / Configurator/NestedBaselineRevertedIsNotDirty: змінити, потім
# повернути значення назад до baseline ('alerts') -> false. Свідомо НЕ
# покладається на подієвий Model[].Dirty (лишався б true).
$nestedDirtyModelReverted = Set-BRAVOConfiguratorOverride -Model $nestedDirtyModelChanged -Path $nestedDirtySuccessPath -Value 'alerts'
Test-BRAVOCondition (-not (Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyModelReverted -BaselineOverrides $nestedDirtyBaseline)) `
    'Configurator/NestedBaselineRevertedIsNotDirty: вкладений leaf змінено, потім повернуто до baseline-значення -> false' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyModelReverted -BaselineOverrides $nestedDirtyBaseline)"

# A4 / Configurator/NestedBaselineClearIsDirty: вкладений baseline-leaf
# існував, Clear прибирає його -> true (presence-diff значущий).
$nestedDirtyModelCleared = Clear-BRAVOConfiguratorOverride -Model $nestedDirtyModel -Path $nestedDirtySuccessPath
Test-BRAVOCondition (Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyModelCleared -BaselineOverrides $nestedDirtyBaseline) `
    'Configurator/NestedBaselineClearIsDirty: вкладений baseline-leaf прибрано через Clear -> true' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyModelCleared -BaselineOverrides $nestedDirtyBaseline)"

# A5 / Configurator/NestedBaselineFalseLikeValuePresence: вкладений
# boolean-leaf з "falsy" значенням $false МАЄ трактуватись як present,
# не як absent (та сама "false override != absent override" семантика,
# що AI-тест вище, але тепер через вкладену Node-форму, 2 рівні
# вкладеності: 'componentSettings' -> 'SFTP' -> 'ArchiveUpload').
$nestedDirtyBooleanPath = 'componentSettings.SFTP.ArchiveUpload'
$nestedDirtyBooleanBaseline = @{ componentSettings = @{ SFTP = @{ ArchiveUpload = $false } } }
$nestedDirtyBooleanModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $nestedDirtyBooleanBaseline
Test-BRAVOCondition (-not (Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyBooleanModel -BaselineOverrides $nestedDirtyBooleanBaseline)) `
    'Configurator/NestedBaselineFalseLikeValuePresence: вкладений override=false, модель побудована з нього -> false (присутній, не absent)' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyBooleanModel -BaselineOverrides $nestedDirtyBooleanBaseline)"
$nestedDirtyBooleanCleared = Clear-BRAVOConfiguratorOverride -Model $nestedDirtyBooleanModel -Path $nestedDirtyBooleanPath
Test-BRAVOCondition (Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyBooleanCleared -BaselineOverrides $nestedDirtyBooleanBaseline) `
    'Configurator/NestedBaselineFalseLikeValuePresence: Clear вкладеного false-override -> true (presence, не value, змінився)' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyBooleanCleared -BaselineOverrides $nestedDirtyBooleanBaseline)"

# A6 / Configurator/NestedBaselineFlatPrecedence: baseline містить ОБИДВІ
# представлення одночасно (флат + вкладена, флат МАЄ пріоритет —
# Resolve-BRAVOConfiguratorSuppliedLeafOverride та сама D3/F1-межа, що й
# canonical model-load). Untouched модель, побудована з ТОГО САМОГО
# baseline, повинна лишатись чистою — dirty-check не має розходитись із
# model-load precedence-семантикою.
$nestedDirtyMixedBaseline = @{
    $nestedDirtySuccessPath = 'alerts'
    $nestedDirtyContainerPath = @{ SUCCESS = 'general'; WARNING = 'alerts' }
}
$nestedDirtyMixedModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $nestedDirtyMixedBaseline
$nestedDirtyMixedSuccessRow = @($nestedDirtyMixedModel | Where-Object { $_.Path -eq $nestedDirtySuccessPath })[0]
Test-BRAVOCondition ([string]$nestedDirtyMixedSuccessRow.OverrideValue -eq 'alerts') `
    'Configurator/NestedBaselineFlatPrecedence: model-load сам обирає флат-значення (alerts) при мішаному baseline' `
    "OverrideValue=$($nestedDirtyMixedSuccessRow.OverrideValue)"
Test-BRAVOCondition (-not (Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyMixedModel -BaselineOverrides $nestedDirtyMixedBaseline)) `
    'Configurator/NestedBaselineFlatPrecedence: untouched модель проти мішаного (флат+вкладений) baseline -> false' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyMixedModel -BaselineOverrides $nestedDirtyMixedBaseline)"

# A7: глибша вкладеність (2 сегменти під TopLevelKey замість 1) —
# 'componentSettings' -> 'SFTP' -> 'ArchiveUpload', НЕ 'componentSettings.SFTP' -> 'ArchiveUpload'.
$nestedDirtyDeepBaseline = @{ componentSettings = @{ SFTP = @{ ArchiveUpload = $true } } }
$nestedDirtyDeepModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $nestedDirtyDeepBaseline
Test-BRAVOCondition (-not (Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyDeepModel -BaselineOverrides $nestedDirtyDeepBaseline)) `
    'Configurator/NestedBaselineDeepSegments: 2-сегментна вкладеність (componentSettings.SFTP.ArchiveUpload), untouched -> false' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyDeepModel -BaselineOverrides $nestedDirtyDeepBaseline)"
$nestedDirtyDeepModelChanged = Set-BRAVOConfiguratorOverride -Model $nestedDirtyDeepModel -Path $nestedDirtyBooleanPath -Value $false
Test-BRAVOCondition (Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyDeepModelChanged -BaselineOverrides $nestedDirtyDeepBaseline) `
    'Configurator/NestedBaselineDeepSegments: 2-сегментна вкладеність, значення змінено -> true' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyDeepModelChanged -BaselineOverrides $nestedDirtyDeepBaseline)"

# Non-mutation guard (§4 задачі): Test-BRAVOConfiguratorModelDirty
# лишається read-only — не мутує ні $BaselineOverrides (включно з
# вкладеними hashtable-значеннями), ні $Model.
$nestedDirtyGuardBaselineBefore = ConvertTo-Json -InputObject $nestedDirtyMixedBaseline -Depth 10 -Compress
$nestedDirtyGuardModelBefore = ConvertTo-Json -InputObject $nestedDirtyMixedModel -Depth 10 -Compress
[void](Test-BRAVOConfiguratorModelDirty -Model $nestedDirtyMixedModel -BaselineOverrides $nestedDirtyMixedBaseline)
$nestedDirtyGuardBaselineAfter = ConvertTo-Json -InputObject $nestedDirtyMixedBaseline -Depth 10 -Compress
$nestedDirtyGuardModelAfter = ConvertTo-Json -InputObject $nestedDirtyMixedModel -Depth 10 -Compress
Test-BRAVOCondition (
    ($nestedDirtyGuardBaselineBefore -eq $nestedDirtyGuardBaselineAfter) -and
    ($nestedDirtyGuardModelBefore -eq $nestedDirtyGuardModelAfter)
) `
    'Configurator/NestedBaselineDirtyCheckIsReadOnly: Test-BRAVOConfiguratorModelDirty не мутує ні BaselineOverrides, ні Model' `
    "BaselineUnchanged=$($nestedDirtyGuardBaselineBefore -eq $nestedDirtyGuardBaselineAfter) ModelUnchanged=$($nestedDirtyGuardModelBefore -eq $nestedDirtyGuardModelAfter)"

# AK: Reset-BRAVOConfiguratorSetting — еквівалентний Clear (Boolean повертається
# до Default, а не матеріалізується як False).
$dirtyModelForResetSetting = Set-BRAVOConfiguratorOverride -Model $dirtyModelClean -Path $dirtyBooleanPath -Value $false
$dirtyModelAfterResetSetting = Reset-BRAVOConfiguratorSetting -Model $dirtyModelForResetSetting -Path $dirtyBooleanPath
$dirtyResetSettingRow = @($dirtyModelAfterResetSetting | Where-Object { $_.Path -eq $dirtyBooleanPath })
Test-BRAVOCondition ($dirtyResetSettingRow.Count -eq 1 -and -not [bool]$dirtyResetSettingRow[0].OverridePresent) `
    'Configurator Reset setting: Reset-BRAVOConfiguratorSetting прибирає override (Default, не False)' `
    "OverridePresent=$($dirtyResetSettingRow[0].OverridePresent)"

# AL: Reset-BRAVOConfiguratorSection — скидає лише settings ЦІЄЇ Group/Section,
# інші секції та невідомі ключі не постраждали.
$dirtyResetSectionTarget = @($dirtyModelClean | Where-Object { -not [bool]$_.Metadata.ReadOnly })[0]
$dirtyResetSectionGroup = [string]$dirtyResetSectionTarget.Metadata.Group
$dirtyResetSectionSection = [string]$dirtyResetSectionTarget.Metadata.Section
$dirtyResetSectionOtherCandidate = @($dirtyModelClean | Where-Object {
    ([string]$_.Metadata.Group -ne $dirtyResetSectionGroup -or [string]$_.Metadata.Section -ne $dirtyResetSectionSection) -and -not [bool]$_.Metadata.ReadOnly
})
$dirtyResetSectionOtherPath = if ($dirtyResetSectionOtherCandidate.Count -gt 0) { [string]$dirtyResetSectionOtherCandidate[0].Path } else { $null }
$dirtyModelBeforeSectionReset = Set-BRAVOConfiguratorOverride -Model $dirtyModelClean -Path $dirtyResetSectionTarget.Path -Value $dirtyResetSectionTarget.DefaultValue
if (-not [string]::IsNullOrWhiteSpace($dirtyResetSectionOtherPath)) {
    $otherPathDescriptor = @($dirtyModelClean | Where-Object { $_.Path -eq $dirtyResetSectionOtherPath })[0]
    $dirtyModelBeforeSectionReset = Set-BRAVOConfiguratorOverride -Model $dirtyModelBeforeSectionReset -Path $dirtyResetSectionOtherPath -Value $otherPathDescriptor.DefaultValue
}
$dirtyModelAfterSectionReset = Reset-BRAVOConfiguratorSection -Model $dirtyModelBeforeSectionReset -Group $dirtyResetSectionGroup -Section $dirtyResetSectionSection
$dirtyTargetRowAfterReset = @($dirtyModelAfterSectionReset | Where-Object { $_.Path -eq $dirtyResetSectionTarget.Path })[0]
$dirtyOtherRowAfterReset = if (-not [string]::IsNullOrWhiteSpace($dirtyResetSectionOtherPath)) {
    @($dirtyModelAfterSectionReset | Where-Object { $_.Path -eq $dirtyResetSectionOtherPath })[0]
} else { $null }
Test-BRAVOCondition (
    (-not [bool]$dirtyTargetRowAfterReset.OverridePresent) -and
    ($null -eq $dirtyOtherRowAfterReset -or [bool]$dirtyOtherRowAfterReset.OverridePresent)
) `
    'Configurator Reset section: скидає лише обрану Group/Section, інші секції не постраждали' `
    "TargetOverridePresent=$($dirtyTargetRowAfterReset.OverridePresent) OtherPath=$dirtyResetSectionOtherPath OtherOverridePresent=$($dirtyOtherRowAfterReset.OverridePresent)"

# AM: Get-BRAVOConfiguratorSessionOutcome — P2-A.4 correction. Session
# outcome оцінюється проти ПОТОЧНОГО ProductionBaseline (не первинного
# baseline сесії): Cancelled переважає над Applied, коли на момент
# закриття лишився незбережений diff проти поточного baseline.

# Test 1 — порожня сесія (baseline A, model A, жодного Apply) -> NoChanges
$outcomeBaselineA = @{ $dirtyStringPath = 'WARN' }
$outcomeModelA = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $outcomeBaselineA
Test-BRAVOCondition ((Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelA -ProductionBaseline $outcomeBaselineA -AnyApplySucceeded $false) -eq 'NoChanges') `
    'Configurator SessionOutcome: порожня сесія -> NoChanges' `
    "Outcome=$(Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelA -ProductionBaseline $outcomeBaselineA -AnyApplySucceeded $false)"

# Test 2 — edit, потім revert точно до baseline A, без Apply -> NoChanges
$outcomeModelEdited = Set-BRAVOConfiguratorOverride -Model $outcomeModelA -Path $dirtyBooleanPath -Value $true
$outcomeModelReverted = Reset-BRAVOConfiguratorSetting -Model $outcomeModelEdited -Path $dirtyBooleanPath
Test-BRAVOCondition ((Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelReverted -ProductionBaseline $outcomeBaselineA -AnyApplySucceeded $false) -eq 'NoChanges') `
    'Configurator SessionOutcome: edit -> revert -> NoChanges' `
    "Outcome=$(Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelReverted -ProductionBaseline $outcomeBaselineA -AnyApplySucceeded $false)"

# Test 3 — незбережений edit, без Apply -> Cancelled
Test-BRAVOCondition ((Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelEdited -ProductionBaseline $outcomeBaselineA -AnyApplySucceeded $false) -eq 'Cancelled') `
    'Configurator SessionOutcome: незбережений edit -> Cancelled' `
    "Outcome=$(Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelEdited -ProductionBaseline $outcomeBaselineA -AnyApplySucceeded $false)"

# Test 4 — успішний Apply: ProductionBaseline оновлено до B, Model = B -> Applied
$outcomeBaselineB = @{ $dirtyStringPath = 'WARN'; $dirtyBooleanPath = $true }
$outcomeModelB = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $outcomeBaselineB
Test-BRAVOCondition ((Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelB -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $true) -eq 'Applied') `
    'Configurator SessionOutcome: успішний Apply, без подальших змін -> Applied' `
    "Outcome=$(Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelB -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $true)"

# Test 5 — Apply(B) відбувся, потім НОВИЙ незбережений edit (C != B) -> Cancelled
#   (regression для дефекту: AnyApplySucceeded раніше мав абсолютний
#   пріоритет і хибно приховував ці подальші незбережені зміни)
$outcomeModelC = Set-BRAVOConfiguratorOverride -Model $outcomeModelB -Path $dirtyArrayPath -Value @('changed-after-apply')
Test-BRAVOCondition ((Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelC -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $true) -eq 'Cancelled') `
    'Configurator SessionOutcome: Apply + подальший незбережений edit -> Cancelled (не Applied)' `
    "Outcome=$(Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelC -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $true)"

# Test 6 — Apply(B) відбувся, потім edit, потім revert точно до B -> Applied
$outcomeModelCReverted = Reset-BRAVOConfiguratorSetting -Model $outcomeModelC -Path $dirtyArrayPath
Test-BRAVOCondition ((Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelCReverted -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $true) -eq 'Applied') `
    'Configurator SessionOutcome: Apply + edit -> revert до B -> Applied' `
    "Outcome=$(Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelCReverted -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $true)"

# Test 7 — Launch(A) -> зовнішня модифікація на диску -> B -> Reload
#   (ProductionBaseline і Model обидва оновлені до B) -> Close без edits
#   -> NoChanges. Це головний regression для дефекту InitialBaselineOverrides
#   (B != первинний baseline A хибно давав Cancelled).
Test-BRAVOCondition ((Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelB -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $false) -eq 'NoChanges') `
    'Configurator SessionOutcome: Reload після зовнішньої зміни, без edits -> NoChanges' `
    "Outcome=$(Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelB -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $false)"

# ===== P0 Configuration Foundation (PR C, Секція 8): Configurator без
# фізичного BRAVO.config (built-in-only + BRAVO.local.config-only шлях) —
# та сама герметична модель fixture, що вище, але БЕЗ BRAVO.config
# взагалі: LIMSRoot/BackupRoot надаються через CandidateOverrides (=
# кандидатний BRAVO.local.config, який New-BRAVOConfiguratorIsolatedConfigRoot
# і так уже пише), а не через патчений primary-шар. Доводить: (1)
# Invoke-BRAVOConfiguratorEffectiveComputation більше НЕ вимагає фізичного
# BRAVO.config (раніше — жорсткий throw); (2) DefaultValue для
# hostInformationSettings.PublicIPLookupEnabled узгоджений із дійсним
# canonical дефолтом ($true, рішення власника 2026-08-30) — не застарілим
# P1.10-текстом схеми (drift, знайдений і виправлений у Секції 8). =====
$configuratorNoConfigRuntimeRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIGURATOR_SELFTEST_NOCONFIG_{0}" -f [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($configuratorNoConfigRuntimeRoot)
try {
    $configuratorNoConfigLimsRoot = Join-Path $configuratorNoConfigRuntimeRoot 'FIXTURE_LIMS'
    $configuratorNoConfigBackupRoot = Join-Path $configuratorNoConfigRuntimeRoot 'FIXTURE_BACKUP'
    [void][IO.Directory]::CreateDirectory($configuratorNoConfigLimsRoot)
    [void][IO.Directory]::CreateDirectory($configuratorNoConfigBackupRoot)
    Copy-Item -LiteralPath (Join-Path $root 'BRAVO_CONFIG_LOADER.ps1') -Destination (Join-Path $configuratorNoConfigRuntimeRoot 'BRAVO_CONFIG_LOADER.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $root 'VERSION.json') -Destination (Join-Path $configuratorNoConfigRuntimeRoot 'VERSION.json') -Force
    $null = cmd.exe /c mklink /J "$configuratorNoConfigRuntimeRoot\modules" "$root\modules" 2>&1
    # Свідомо НЕ копіюємо BRAVO.config — це і є предмет перевірки.
    Test-BRAVOCondition (-not (Test-Path -LiteralPath (Join-Path $configuratorNoConfigRuntimeRoot 'BRAVO.config') -PathType Leaf)) `
        'Configurator no-config fixture: BRAVO.config справді відсутній (self-test setup guard)' `
        'fixture RuntimeRoot несподівано містить BRAVO.config'

    $configuratorNoConfigDefault = $null
    $configuratorNoConfigComputationFailed = $false
    $configuratorNoConfigComputationMessage = ''
    try {
        $configuratorNoConfigDefault = Invoke-BRAVOConfiguratorEffectiveComputation `
            -RuntimeRoot $configuratorNoConfigRuntimeRoot `
            -CandidateOverrides @{
                'pathSettings.LIMSRoot' = $configuratorNoConfigLimsRoot
                'pathSettings.BackupRoot' = $configuratorNoConfigBackupRoot
            }
    } catch {
        $configuratorNoConfigComputationFailed = $true
        $configuratorNoConfigComputationMessage = $_.Exception.Message
    }
    Test-BRAVOCondition (-not $configuratorNoConfigComputationFailed) `
        'Configurator Effective: без фізичного BRAVO.config обчислення НЕ падає (built-in-only + local-only шлях)' `
        "Помилка: $configuratorNoConfigComputationMessage"

    if (-not $configuratorNoConfigComputationFailed) {
        Test-BRAVOCondition (
            [bool]$configuratorNoConfigDefault.hostInformationSettings.PublicIPLookupEnabled -eq $true
        ) `
            'Configurator no-config Default: PublicIPLookupEnabled узгоджений із canonical дефолтом ($true, рішення власника 2026-08-30, не застарілий P1.10=false)' `
            "Отримано: $($configuratorNoConfigDefault.hostInformationSettings.PublicIPLookupEnabled)"

        $configuratorNoConfigModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorNoConfigDefault -LocalOverrides @{}
        $configuratorNoConfigPublicIpSetting = @($configuratorNoConfigModel | Where-Object { $_.Path -eq 'hostInformationSettings.PublicIPLookupEnabled' })
        Test-BRAVOCondition (
            $configuratorNoConfigPublicIpSetting.Count -eq 1 -and
            [bool]$configuratorNoConfigPublicIpSetting[0].DefaultValue -eq $true
        ) `
            'Configurator no-config Model: DefaultValue-колонка (не лише сирий Effective-знімок) теж узгоджена з canonical дефолтом' `
            "DefaultValue=$($configuratorNoConfigPublicIpSetting[0].DefaultValue)"
    }
} finally {
    Remove-Item -LiteralPath $configuratorNoConfigRuntimeRoot -Recurse -Force -ErrorAction SilentlyContinue
}


# =====================================================================
# Wave 2 (#216): Configurator споживає canonical authorization Class
# =====================================================================
# Доводить, що Resolve-BRAVOConfiguratorFieldAuthorization ГЕНУЇННО
# читає canonical реєстр (не другу, окремо підтримувану копію) — і що
# drift-приклад із WAVE2-CONTRACT.md (розділ 11.4,
# backupMonitoring.SFTP.BAZA.Mode) фактично усунутий.
& {
    if (-not (Get-Module -Name 'BRAVO.Configuration')) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.psd1') -Force
    }
    if (-not (Get-Module -Name 'BRAVO.Configuration.Schema')) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Schema.psd1') -Force
    }

    $authAdapterRawCatalog = Get-BRAVOConfiguratorSchemaCatalog
    $authAdapterClassRegistry = Get-BRAVOConfigurationSchemaAuthorizationClass
    $authAdapterResolved = Resolve-BRAVOConfiguratorFieldAuthorization -Descriptors $authAdapterRawCatalog -AuthorizationClass $authAdapterClassRegistry

    # --- Configurator/Authorization/AllowSiteFieldRemainsEditable ---
    $authAdapterAllowSite = @($authAdapterResolved | Where-Object { $_.Path -eq 'archiveRetentionDays' })
    Test-BRAVOCondition ($authAdapterAllowSite.Count -eq 1 -and [bool]$authAdapterAllowSite[0].ReadOnly -eq $false) `
        'Configurator/Authorization/AllowSiteFieldRemainsEditable' `
        "archiveRetentionDays (ALLOW_SITE) мусить лишитись ReadOnly=`$false; отримано count=$($authAdapterAllowSite.Count) ReadOnly=$($authAdapterAllowSite[0].ReadOnly)"

    # --- Configurator/Authorization/AllowWithValidatorFieldRemainsEditable ---
    $authAdapterAllowValidator = @($authAdapterResolved | Where-Object { $_.Path -eq 'bravoSettings.NotificationMode' })
    Test-BRAVOCondition ($authAdapterAllowValidator.Count -eq 1 -and [bool]$authAdapterAllowValidator[0].ReadOnly -eq $false) `
        'Configurator/Authorization/AllowWithValidatorFieldRemainsEditable' `
        "bravoSettings.NotificationMode (ALLOW_WITH_VALIDATOR) мусить лишитись ReadOnly=`$false; отримано count=$($authAdapterAllowValidator.Count) ReadOnly=$($authAdapterAllowValidator[0].ReadOnly)"

    # --- Configurator/Authorization/BazaModeNoLongerEmittedAsEditable ---
    # Конкретна drift-позиція з WAVE2-CONTRACT.md (розділ 11.4): статичний
    # каталог документує ReadOnly=$false, AllowedValues=@('IncrementalAppendOnly','Legacy')
    # — canonical DENY_SECURITY_CONTROL мусить примусово зробити її
    # ефективно read-only.
    $authAdapterBazaModeRaw = @($authAdapterRawCatalog | Where-Object { $_.Path -eq 'backupMonitoring.SFTP.BAZA.Mode' })
    $authAdapterBazaModeResolved = @($authAdapterResolved | Where-Object { $_.Path -eq 'backupMonitoring.SFTP.BAZA.Mode' })
    Test-BRAVOCondition (
        $authAdapterBazaModeRaw.Count -eq 1 -and [bool]$authAdapterBazaModeRaw[0].ReadOnly -eq $false -and
        $authAdapterBazaModeResolved.Count -eq 1 -and [bool]$authAdapterBazaModeResolved[0].ReadOnly -eq $true
    ) `
        'Configurator/Authorization/BazaModeNoLongerEmittedAsEditable' `
        ("статичний каталог документує backupMonitoring.SFTP.BAZA.Mode як ReadOnly=`$false (RawReadOnly=$($authAdapterBazaModeRaw[0].ReadOnly)), " +
         "але canonical adapter мусить примусово дати ReadOnly=`$true (ResolvedReadOnly=$($authAdapterBazaModeResolved[0].ReadOnly)) — інакше Configurator генерував би override, який loader після Wave 2 відхилить")

    # --- Configurator/Authorization/DenyExecutionControlFieldNotEditable ---
    # maintenanceSettings.Services.BravoName НЕ задокументований у
    # каталозі Configurator-а сьогодні (DENY_EXECUTION_CONTROL, ніколи не
    # мав редагованого поля) — перевіряємо клас через синтетичний
    # дескриптор, що доводить: adapter форсує ReadOnly для БУДЬ-ЯКОГО
    # DENY_-класу, не лише для вже задокументованого BAZA.Mode-кейса.
    $authAdapterSyntheticDescriptors = @(
        @{ Path = 'maintenanceSettings.Services.BravoName'; Group = 'Maintenance'; Section = 'Services'; Label = 'probe'; Description = ''; Type = 'String'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 1 }
    )
    $authAdapterSyntheticResolved = Resolve-BRAVOConfiguratorFieldAuthorization -Descriptors $authAdapterSyntheticDescriptors -AuthorizationClass $authAdapterClassRegistry
    Test-BRAVOCondition ([bool]$authAdapterSyntheticResolved[0].ReadOnly -eq $true) `
        'Configurator/Authorization/DenyExecutionControlFieldNotEditable' `
        "синтетичний дескриптор на DENY_EXECUTION_CONTROL-шляху (statically ReadOnly=`$false) мусить отримати effective ReadOnly=`$true; отримано $($authAdapterSyntheticResolved[0].ReadOnly)"

    # --- Configurator/Authorization/AdapterGenuinelyConsumesCanonicalClass ---
    # Мутуємо ЛИШЕ canonical Class копії реєстру (не каталог) і доводимо,
    # що вихід adapter-а міняється відповідно — інакше ReadOnly=$true для
    # BAZA.Mode міг би бути жорстко закодований в adapter-і, а не реально
    # похідний від реєстру.
    $authAdapterMutatedRegistry = @{}
    foreach ($mutateKey in @($authAdapterClassRegistry.Keys)) { $authAdapterMutatedRegistry[$mutateKey] = $authAdapterClassRegistry[$mutateKey] }
    $authAdapterMutatedRegistry['backupMonitoring.SFTP.BAZA.Mode'] = @{ Class = 'ALLOW_SITE'; Validator = $null }
    $authAdapterMutatedResolved = Resolve-BRAVOConfiguratorFieldAuthorization -Descriptors $authAdapterRawCatalog -AuthorizationClass $authAdapterMutatedRegistry
    $authAdapterMutatedBazaMode = @($authAdapterMutatedResolved | Where-Object { $_.Path -eq 'backupMonitoring.SFTP.BAZA.Mode' })
    Test-BRAVOCondition ($authAdapterMutatedBazaMode.Count -eq 1 -and [bool]$authAdapterMutatedBazaMode[0].ReadOnly -eq $false) `
        'Configurator/Authorization/AdapterGenuinelyConsumesCanonicalClass' `
        "мутація ЛИШЕ canonical Class (BAZA.Mode -> ALLOW_SITE у копії реєстру) мусить змінити ефективний ReadOnly на `$false — доводить, що adapter реально читає реєстр, а не жорстко кодує рішення для конкретного шляху; отримано $($authAdapterMutatedBazaMode[0].ReadOnly)"

    # --- Configurator/Authorization/RawCatalogUnmutatedByAdapter ---
    $authAdapterRawAfter = @(Get-BRAVOConfiguratorSchemaCatalog | Where-Object { $_.Path -eq 'backupMonitoring.SFTP.BAZA.Mode' })
    Test-BRAVOCondition ($authAdapterRawAfter.Count -eq 1 -and [bool]$authAdapterRawAfter[0].ReadOnly -eq $false) `
        'Configurator/Authorization/RawCatalogUnmutatedByAdapter' `
        "Resolve-BRAVOConfiguratorFieldAuthorization НЕ повинен мутувати вхідні дескриптори/повторні читання сирого каталогу; отримано ReadOnly=$($authAdapterRawAfter[0].ReadOnly)"
}

# =====================================================================
# PR #224 review, F2: legacy denied override deadlockує Configurator при
# старті. Pre-Wave-2 BRAVO.local.config міг уже містити
# backupMonitoring.SFTP.BAZA.Mode='Legacy' (тоді ще editable через
# Configurator, тепер DENY_SECURITY_CONTROL/ReadOnly). Тести нижче
# доводять: (a) сам факт наявності такого override НЕ падає при
# завантаженні/preview-обчисленні (ConvertTo-BRAVOConfiguratorOverrideHashtable
# виключає DENY_* з проєкції ДЛЯ preview), (b) Apply-гейт і далі
# коректно fail-closed, доки override не прибрано (Clear), (c) після
# Clear — валідний candidate, Apply проходить, і результуючий файл
# більше не містить denied override.
# =====================================================================
& {
    if (-not (Get-Module -Name 'BRAVO.Configuration')) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.psd1') -Force
    }
    if (-not (Get-Module -Name 'BRAVO.Configuration.Schema')) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Schema.psd1') -Force
    }

    $legacyDeniedPath = 'backupMonitoring.SFTP.BAZA.Mode'
    $legacyDeniedRawCatalog = Get-BRAVOConfiguratorSchemaCatalog
    $legacyDeniedClassRegistry = Get-BRAVOConfigurationSchemaAuthorizationClass
    $legacyDeniedResolvedCatalog = Resolve-BRAVOConfiguratorFieldAuthorization -Descriptors $legacyDeniedRawCatalog -AuthorizationClass $legacyDeniedClassRegistry

    $legacyDeniedScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_CONFIGURATOR_LEGACYDENIED_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($legacyDeniedScenarioRoot)
    try {
        # Продакшн-файл УЖЕ містить легасі-заборонений override — так,
        # ніби записаний до-Wave-2 версією Configurator-а (не через
        # поточний Set/Apply-конвеєр, який сам ніколи б такий override
        # не створив).
        # Section 6 (PR #224 review remediation): fixture також містить
        # ОДИН сусідній ALLOW_SITE override (archiveRetentionDays), аби
        # довести не лише "denied прибрано", а й "інший, валідний,
        # override переживає весь цикл Clear -> Apply незмінним".
        $legacyDeniedAllowedPath = 'archiveRetentionDays'
        $legacyDeniedAllowedValue = 45
        $legacyDeniedLocalConfigPath = Join-Path $legacyDeniedScenarioRoot 'BRAVO.local.config'
        [IO.File]::WriteAllText(
            $legacyDeniedLocalConfigPath,
            (ConvertTo-BRAVOConfiguratorLocalConfigText -MergedOverrides @{
                $legacyDeniedPath        = 'Legacy'
                $legacyDeniedAllowedPath = $legacyDeniedAllowedValue
            }),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $legacyDeniedBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $legacyDeniedScenarioRoot
        Test-BRAVOCondition ($legacyDeniedBaseline.Overrides.Contains($legacyDeniedPath)) `
            'Configurator/LegacyDeniedOverride/BaselineFixtureContainsIt' `
            "fixture-передумова: baseline мусить містити $legacyDeniedPath='Legacy' перед рештою сценарію; отримано Contains=$($legacyDeniedBaseline.Overrides.Contains($legacyDeniedPath))"

        $legacyDeniedModel = Get-BRAVOConfiguratorModel -SchemaCatalog $legacyDeniedResolvedCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $legacyDeniedBaseline.Overrides
        $legacyDeniedSetting = @($legacyDeniedModel | Where-Object { $_.Path -eq $legacyDeniedPath })

        # --- Configurator/LegacyDeniedOverrideIsReadOnly ---
        Test-BRAVOCondition (
            $legacyDeniedSetting.Count -eq 1 -and [bool]$legacyDeniedSetting[0].OverridePresent -and
            [bool]$legacyDeniedSetting[0].Metadata.ReadOnly -eq $true
        ) `
            'Configurator/LegacyDeniedOverrideIsReadOnly' `
            "легасі-заборонений override мусить бути OverridePresent=`$true, Metadata.ReadOnly=`$true (canonical adapter forcing); отримано OverridePresent=$($legacyDeniedSetting[0].OverridePresent) ReadOnly=$($legacyDeniedSetting[0].Metadata.ReadOnly)"

        # --- Configurator/LegacyDeniedOverrideDoesNotPreventStartup ---
        # ГОЛОВНИЙ баг F2: Update-BRAVOConfiguratorEffective (звичайний
        # UI startup/preview шлях, БЕЗ -CandidateOverridesOverride) НЕ
        # повинен падати лише тому, що Model містить легасі-заборонений
        # override.
        $legacyDeniedStartupThrew = $false
        $legacyDeniedStartupMessage = $null
        $legacyDeniedModelAfterEffective = $null
        try {
            $legacyDeniedModelAfterEffective = Update-BRAVOConfiguratorEffective -Model $legacyDeniedModel -RuntimeRoot $configuratorFixtureRuntimeRoot
        } catch {
            $legacyDeniedStartupThrew = $true
            $legacyDeniedStartupMessage = $_.Exception.Message
        }
        Test-BRAVOCondition (-not $legacyDeniedStartupThrew) `
            'Configurator/LegacyDeniedOverrideDoesNotPreventStartup' `
            "наявність легасі-забороненого override у Model НЕ повинна кидати виняток при звичайному Update-BRAVOConfiguratorEffective (preview/startup шлях); помилка: $legacyDeniedStartupMessage"

        # --- Configurator/LegacyDeniedOverrideCanBeCleared ---
        $legacyDeniedCleared = Clear-BRAVOConfiguratorOverride -Model $legacyDeniedModel -Path $legacyDeniedPath
        $legacyDeniedClearedSetting = @($legacyDeniedCleared | Where-Object { $_.Path -eq $legacyDeniedPath })
        Test-BRAVOCondition (
            $legacyDeniedClearedSetting.Count -eq 1 -and (-not [bool]$legacyDeniedClearedSetting[0].OverridePresent)
        ) `
            'Configurator/LegacyDeniedOverrideCanBeCleared' `
            "оператор мусить мати змогу зняти легасі-заборонений override (Clear-BRAVOConfiguratorOverride) незалежно від ReadOnly; отримано OverridePresent=$($legacyDeniedClearedSetting[0].OverridePresent)"

        # --- Configurator/LegacyDeniedOverrideCannotBeAppliedUnchanged ---
        # Apply-гейт (Test-BRAVOConfiguratorCandidateOverrides, який
        # ЗАВЖДИ обходить проєкцію через -CandidateOverridesOverride)
        # мусить лишитись строгим: доки override НЕ прибрано, Apply
        # мусить провалитись на Validation, а не мовчки пропустити.
        # Section 6, Scenario A: захоплюємо байти файлу ДО спроби Apply, аби
        # довести не лише Stage='Validation', а й що production-файл
        # лишається побайтово незмінним (Validation повертається до кроку
        # backup/atomic-replace у Invoke-BRAVOConfiguratorApply — write
        # ще фізично не відбувся).
        $legacyDeniedPreApplyBytes = [IO.File]::ReadAllBytes($legacyDeniedLocalConfigPath)
        $legacyDeniedModelUnchanged = Update-BRAVOConfiguratorEffective -Model $legacyDeniedModel -RuntimeRoot $configuratorFixtureRuntimeRoot
        $legacyDeniedApplyUnchanged = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $legacyDeniedScenarioRoot -Model $legacyDeniedModelUnchanged -SchemaCatalog $legacyDeniedResolvedCatalog -ProductionBaseline $legacyDeniedBaseline
        $legacyDeniedPostApplyBytes = [IO.File]::ReadAllBytes($legacyDeniedLocalConfigPath)
        Test-BRAVOCondition (
            (-not [bool]$legacyDeniedApplyUnchanged.Applied) -and [string]$legacyDeniedApplyUnchanged.Stage -eq 'Validation'
        ) `
            'Configurator/LegacyDeniedOverrideCannotBeAppliedUnchanged' `
            "Apply з незмінним (все ще присутнім) легасі-забороненим override мусить провалитись на стадії Validation, НЕ бути Applied; отримано Applied=$($legacyDeniedApplyUnchanged.Applied) Stage=$($legacyDeniedApplyUnchanged.Stage)"
        Test-BRAVOCondition (
            [Convert]::ToBase64String($legacyDeniedPreApplyBytes) -eq [Convert]::ToBase64String($legacyDeniedPostApplyBytes)
        ) `
            'Configurator/LegacyDeniedOverrideValidationFailureLeavesProductionFileByteIdentical' `
            "провал Apply на стадії Validation НЕ повинен торкатись production BRAVO.local.config — файл мусить лишитись побайтово ідентичним ($($legacyDeniedPreApplyBytes.Length) байт до, $($legacyDeniedPostApplyBytes.Length) байт після)"

        # --- Configurator/LegacyDeniedOverrideCannotBeChanged ---
        # Навіть спроба ЗМІНИТИ (не лише лишити) заборонений override на
        # ІНШЕ (так само заборонене) значення не повинна коли-небудь
        # реально потрапити в продакшн — canonical loader відхиляє це
        # незалежно від конкретного запропонованого значення (авторизація
        # про володіння листом, не про безпечність значення).
        $legacyDeniedModelChanged = Set-BRAVOConfiguratorOverride -Model $legacyDeniedModel -Path $legacyDeniedPath -Value 'IncrementalAppendOnly'
        $legacyDeniedModelChanged = Update-BRAVOConfiguratorEffective -Model $legacyDeniedModelChanged -RuntimeRoot $configuratorFixtureRuntimeRoot
        $legacyDeniedApplyChanged = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $legacyDeniedScenarioRoot -Model $legacyDeniedModelChanged -SchemaCatalog $legacyDeniedResolvedCatalog -ProductionBaseline $legacyDeniedBaseline
        Test-BRAVOCondition (
            (-not [bool]$legacyDeniedApplyChanged.Applied) -and [string]$legacyDeniedApplyChanged.Stage -eq 'Validation'
        ) `
            'Configurator/LegacyDeniedOverrideCannotBeChanged' `
            "спроба змінити легасі-заборонений override на ІНШЕ значення (замість Clear) мусить так само провалитись на Validation — DENY_* не редагується, лише знімається; отримано Applied=$($legacyDeniedApplyChanged.Applied) Stage=$($legacyDeniedApplyChanged.Stage)"

        # --- Configurator/ClearingLegacyDeniedOverrideProducesValidCandidate ---
        # Ізольована persistence-пайплайн перевірка: існуючий файл із
        # denied override -> Clear -> Apply -> результуючий файл БІЛЬШЕ
        # НЕ містить його (не production-файли, повністю ізольований
        # $legacyDeniedScenarioRoot, прибирається у finally).
        $legacyDeniedFinalModel = Update-BRAVOConfiguratorEffective -Model $legacyDeniedCleared -RuntimeRoot $configuratorFixtureRuntimeRoot
        $legacyDeniedFinalApply = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $legacyDeniedScenarioRoot -Model $legacyDeniedFinalModel -SchemaCatalog $legacyDeniedResolvedCatalog -ProductionBaseline $legacyDeniedBaseline
        $legacyDeniedFinalContent = if (Test-Path -LiteralPath (Join-Path $legacyDeniedScenarioRoot 'BRAVO.local.config')) {
            Get-Content -LiteralPath (Join-Path $legacyDeniedScenarioRoot 'BRAVO.local.config') -Raw -Encoding UTF8
        } else { '' }
        Test-BRAVOCondition (
            [bool]$legacyDeniedFinalApply.Applied -and [string]$legacyDeniedFinalApply.Stage -eq 'Complete' -and
            -not $legacyDeniedFinalContent.Contains($legacyDeniedPath)
        ) `
            'Configurator/ClearingLegacyDeniedOverrideProducesValidCandidate' `
            "після Clear валідний candidate мусить пройти Apply (Applied=`$true, Stage=Complete) і результуючий BRAVO.local.config більше не повинен містити '$legacyDeniedPath'; отримано Applied=$($legacyDeniedFinalApply.Applied) Stage=$($legacyDeniedFinalApply.Stage) StillContains=$($legacyDeniedFinalContent.Contains($legacyDeniedPath))"

        # Section 6, Scenario B: сусідній ALLOW_SITE override
        # (archiveRetentionDays), присутній у тому самому production-файлі
        # від самого початку, мусить пережити весь цикл Clear -> Apply
        # НЕЗМІННИМ — не лише denied прибрано, а й валідний сусід
        # збережений, і результуючий файл завантажується канонічним
        # loader-ом.
        Test-BRAVOCondition (
            $legacyDeniedFinalContent.Contains($legacyDeniedAllowedPath) -and
            $legacyDeniedFinalContent.Contains([string]$legacyDeniedAllowedValue)
        ) `
            'Configurator/ClearingLegacyDeniedOverrideDoesNotDisturbSiblingAllowedOverride' `
            "сусідній ALLOW_SITE override '$legacyDeniedAllowedPath'=$legacyDeniedAllowedValue мусить лишитись у production BRAVO.local.config незмінним після Clear+Apply denied-листа; отримано вміст: $legacyDeniedFinalContent"

        $legacyDeniedFinalLoadedOverrides = (Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $legacyDeniedScenarioRoot).Overrides
        Test-BRAVOCondition (
            $legacyDeniedFinalLoadedOverrides.Contains($legacyDeniedAllowedPath) -and
            [string]$legacyDeniedFinalLoadedOverrides[$legacyDeniedAllowedPath] -eq [string]$legacyDeniedAllowedValue -and
            (-not $legacyDeniedFinalLoadedOverrides.Contains($legacyDeniedPath))
        ) `
            'Configurator/ClearingLegacyDeniedOverrideResultLoadsCleanlyViaCanonicalReader' `
            "результуючий production BRAVO.local.config мусить перезчитуватись канонічним читачем зі збереженим '$legacyDeniedAllowedPath'=$legacyDeniedAllowedValue і без '$legacyDeniedPath'"
    } finally {
        Remove-Item -LiteralPath $legacyDeniedScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# PR #224 review, N1: те саме, що блок LegacyDenied вище, але для
# ВКЛАДЕНОЇ (Node) форми легасі-забороненого override-у — pre-F1 файл
# міг містити 'backupMonitoring.SFTP.BAZA' = @{ Mode = 'Legacy'; ... }
# замість плоского 'backupMonitoring.SFTP.BAZA.Mode' = 'Legacy'.
# ConvertTo-BRAVOConfiguratorLocalConfigText НЕ вміє (і не повинен уміти)
# серіалізувати hashtable-значення (ConvertTo-BRAVOConfiguratorPowerShellLiteral
# fail-closed на IDictionary) — вкладена форма існує ЛИШЕ як легасі
# артефакт, записаний до появи Configurator-а/іншим інструментом, тож
# fixture-файл пишеться напряму (той самий підхід, що F1-тести).
# Сусід AutoArchiveMutationThreshold (ALLOW_SITE, не DENY) — навмисно,
# щоб Scenario B (Apply після Clear лише Mode) справді могла УСПІШНО
# пройти Validation: MutationPolicy теж DENY_SECURITY_CONTROL і зробив
# би сценарій недосяжним, якби був присутній як сусід у тому самому
# контейнері.
# =====================================================================
& {
    if (-not (Get-Module -Name 'BRAVO.Configuration')) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.psd1') -Force
    }
    if (-not (Get-Module -Name 'BRAVO.Configuration.Schema')) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Schema.psd1') -Force
    }

    $nestedDeniedContainerPath = 'backupMonitoring.SFTP.BAZA'
    $nestedDeniedLeafPath = 'backupMonitoring.SFTP.BAZA.Mode'
    $nestedDeniedSiblingLeafPath = 'backupMonitoring.SFTP.BAZA.AutoArchiveMutationThreshold'
    $nestedDeniedSiblingValue = 50
    $nestedDeniedUnknownDescendant = 'UnknownFutureKey'
    $nestedDeniedRawCatalog = Get-BRAVOConfiguratorSchemaCatalog
    $nestedDeniedClassRegistry = Get-BRAVOConfigurationSchemaAuthorizationClass
    $nestedDeniedResolvedCatalog = Resolve-BRAVOConfiguratorFieldAuthorization -Descriptors $nestedDeniedRawCatalog -AuthorizationClass $nestedDeniedClassRegistry

    $nestedDeniedScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_CONFIGURATOR_NESTEDLEGACYDENIED_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($nestedDeniedScenarioRoot)
    try {
        $nestedDeniedLocalConfigPath = Join-Path $nestedDeniedScenarioRoot 'BRAVO.local.config'
        [IO.File]::WriteAllText(
            $nestedDeniedLocalConfigPath, (
                "@{`r`n" +
                "    '$nestedDeniedContainerPath' = @{`r`n" +
                "        'Mode' = 'Legacy'`r`n" +
                "        'AutoArchiveMutationThreshold' = $nestedDeniedSiblingValue`r`n" +
                "        '$nestedDeniedUnknownDescendant' = 'x'`r`n" +
                "    }`r`n" +
                "}`r`n"
            ),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $nestedDeniedBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $nestedDeniedScenarioRoot
        Test-BRAVOCondition ($nestedDeniedBaseline.Overrides.Contains($nestedDeniedContainerPath)) `
            'Configurator/NestedLegacyDeniedOverride/BaselineFixtureContainsIt' `
            "fixture-передумова: baseline мусить містити вкладений контейнер '$nestedDeniedContainerPath'; отримано Contains=$($nestedDeniedBaseline.Overrides.Contains($nestedDeniedContainerPath))"

        $nestedDeniedModel = Get-BRAVOConfiguratorModel -SchemaCatalog $nestedDeniedResolvedCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $nestedDeniedBaseline.Overrides
        $nestedDeniedSetting = @($nestedDeniedModel | Where-Object { $_.Path -eq $nestedDeniedLeafPath })
        $nestedDeniedSiblingSetting = @($nestedDeniedModel | Where-Object { $_.Path -eq $nestedDeniedSiblingLeafPath })

        # --- Configurator/NestedDeniedOverrideDetectedAsCanonicalLeaf ---
        Test-BRAVOCondition (
            $nestedDeniedSetting.Count -eq 1 -and [bool]$nestedDeniedSetting[0].OverridePresent -and
            [string]$nestedDeniedSetting[0].OverrideValue -eq 'Legacy'
        ) `
            'Configurator/NestedDeniedOverrideDetectedAsCanonicalLeaf' `
            "вкладений $nestedDeniedLeafPath мусить бути виявлений Model-побудовою як OverridePresent=`$true, OverrideValue='Legacy' (не лише плоска форма); отримано OverridePresent=$($nestedDeniedSetting[0].OverridePresent) Value=$($nestedDeniedSetting[0].OverrideValue)"

        # --- Configurator/NestedDeniedOverrideIsReadOnlyButClearable ---
        Test-BRAVOCondition (
            [bool]$nestedDeniedSetting[0].Metadata.ReadOnly -eq $true
        ) `
            'Configurator/NestedDeniedOverrideIsReadOnlyButClearable' `
            "вкладений легасі-заборонений override мусить бути ReadOnly (не редагується), незалежно від форми представлення; отримано ReadOnly=$($nestedDeniedSetting[0].Metadata.ReadOnly)"
        $nestedDeniedCleared = Clear-BRAVOConfiguratorOverride -Model $nestedDeniedModel -Path $nestedDeniedLeafPath
        $nestedDeniedClearedSetting = @($nestedDeniedCleared | Where-Object { $_.Path -eq $nestedDeniedLeafPath })
        Test-BRAVOCondition (
            $nestedDeniedClearedSetting.Count -eq 1 -and (-not [bool]$nestedDeniedClearedSetting[0].OverridePresent)
        ) `
            'Configurator/NestedDeniedOverrideClearSucceeds' `
            "той самий Clear-BRAVOConfiguratorOverride механізм мусить прибирати вкладений override так само, як плоский; отримано OverridePresent=$($nestedDeniedClearedSetting[0].OverridePresent)"

        # --- Configurator/NestedDeniedOverrideDoesNotPreventStartup ---
        $nestedDeniedStartupThrew = $false
        $nestedDeniedStartupMessage = $null
        try {
            [void](Update-BRAVOConfiguratorEffective -Model $nestedDeniedModel -RuntimeRoot $configuratorFixtureRuntimeRoot)
        } catch {
            $nestedDeniedStartupThrew = $true
            $nestedDeniedStartupMessage = $_.Exception.Message
        }
        Test-BRAVOCondition (-not $nestedDeniedStartupThrew) `
            'Configurator/NestedDeniedOverrideDoesNotPreventStartup' `
            "наявність вкладеного легасі-забороненого override у Model НЕ повинна кидати виняток при звичайному Update-BRAVOConfiguratorEffective; помилка: $nestedDeniedStartupMessage"

        # --- Configurator/NestedDeniedOverrideExcludedFromPreview ---
        $nestedDeniedPreviewOverrides = ConvertTo-BRAVOConfiguratorOverrideHashtable -Model $nestedDeniedModel
        Test-BRAVOCondition (
            (-not $nestedDeniedPreviewOverrides.Contains($nestedDeniedLeafPath)) -and
            $nestedDeniedPreviewOverrides.Contains($nestedDeniedSiblingLeafPath)
        ) `
            'Configurator/NestedDeniedOverrideExcludedFromPreview' `
            "preview-проєкція мусить виключати вкладений денайд-лист, зберігаючи сусідній ALLOW_SITE лист; отримано Contains(denied)=$($nestedDeniedPreviewOverrides.Contains($nestedDeniedLeafPath)) Contains(sibling)=$($nestedDeniedPreviewOverrides.Contains($nestedDeniedSiblingLeafPath))"

        # --- Configurator/NestedDeniedOverrideApplyWithoutClearFails ---
        $nestedDeniedPreApplyBytes = [IO.File]::ReadAllBytes($nestedDeniedLocalConfigPath)
        $nestedDeniedModelUnchanged = Update-BRAVOConfiguratorEffective -Model $nestedDeniedModel -RuntimeRoot $configuratorFixtureRuntimeRoot
        $nestedDeniedApplyUnchanged = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $nestedDeniedScenarioRoot -Model $nestedDeniedModelUnchanged -SchemaCatalog $nestedDeniedResolvedCatalog -ProductionBaseline $nestedDeniedBaseline
        $nestedDeniedPostApplyBytes = [IO.File]::ReadAllBytes($nestedDeniedLocalConfigPath)
        Test-BRAVOCondition (
            (-not [bool]$nestedDeniedApplyUnchanged.Applied) -and [string]$nestedDeniedApplyUnchanged.Stage -eq 'Validation' -and
            ([Convert]::ToBase64String($nestedDeniedPreApplyBytes) -eq [Convert]::ToBase64String($nestedDeniedPostApplyBytes))
        ) `
            'Configurator/NestedDeniedOverrideApplyWithoutClearFails' `
            "Apply з незмінним вкладеним денайд-листом мусить провалитись на Validation, і production-файл мусить лишитись побайтово незмінним; отримано Applied=$($nestedDeniedApplyUnchanged.Applied) Stage=$($nestedDeniedApplyUnchanged.Stage)"

        # --- Configurator/NestedDeniedOverrideClearPreservesSiblingMembers ---
        # --- Configurator/NestedDeniedOverrideClearRemovesEmptyContainer (перевіряється разом: контейнер НЕ порожній після Clear, бо є 2 сусіди) ---
        $nestedDeniedFinalModel = Update-BRAVOConfiguratorEffective -Model $nestedDeniedCleared -RuntimeRoot $configuratorFixtureRuntimeRoot
        $nestedDeniedFinalApply = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $nestedDeniedScenarioRoot -Model $nestedDeniedFinalModel -SchemaCatalog $nestedDeniedResolvedCatalog -ProductionBaseline $nestedDeniedBaseline
        $nestedDeniedFinalContent = if (Test-Path -LiteralPath $nestedDeniedLocalConfigPath) {
            Get-Content -LiteralPath $nestedDeniedLocalConfigPath -Raw -Encoding UTF8
        } else { '' }
        Test-BRAVOCondition (
            [bool]$nestedDeniedFinalApply.Applied -and [string]$nestedDeniedFinalApply.Stage -eq 'Complete' -and
            (-not $nestedDeniedFinalContent.Contains('Legacy')) -and
            $nestedDeniedFinalContent.Contains($nestedDeniedUnknownDescendant) -and
            $nestedDeniedFinalContent.Contains([string]$nestedDeniedSiblingValue)
        ) `
            'Configurator/NestedDeniedOverrideClearPreservesSiblingMembers' `
            "після Clear лише Mode: Apply мусить успішно пройти (Applied=`$true, Stage=Complete), 'Legacy' мусить зникнути, а ALLOW_SITE-сусід ($nestedDeniedSiblingLeafPath=$nestedDeniedSiblingValue) і невідомий D3-нащадок ($nestedDeniedUnknownDescendant) мусять лишитись; отримано Applied=$($nestedDeniedFinalApply.Applied) Stage=$($nestedDeniedFinalApply.Stage) Content=$nestedDeniedFinalContent"

        # Canonical Configurator-серіалізатор фізично не може записати
        # вкладену форму (fail-closed на IDictionary) — Apply неминуче
        # розгортає контейнер, якого торкається, у плоскі dot-шляхи
        # (Convert-BRAVOConfiguratorNestedContainerToFlatKeys). Тому
        # результат перевіряється як плоскі листи, а не як той самий
        # вкладений контейнер.
        $nestedDeniedFinalLoadedOverrides = (Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $nestedDeniedScenarioRoot).Overrides
        Test-BRAVOCondition (
            $nestedDeniedFinalLoadedOverrides.Contains($nestedDeniedSiblingLeafPath) -and
            [string]$nestedDeniedFinalLoadedOverrides[$nestedDeniedSiblingLeafPath] -eq [string]$nestedDeniedSiblingValue -and
            (-not $nestedDeniedFinalLoadedOverrides.Contains($nestedDeniedLeafPath)) -and
            (-not $nestedDeniedFinalLoadedOverrides.Contains($nestedDeniedContainerPath))
        ) `
            'Configurator/NestedLegacyDeniedOverride/ResultLoadsCleanlyViaCanonicalReader' `
            "результуючий production BRAVO.local.config мусить перезчитуватись канонічним читачем зі збереженим плоским '$nestedDeniedSiblingLeafPath'=$nestedDeniedSiblingValue, без '$nestedDeniedLeafPath' і без вкладеного контейнера '$nestedDeniedContainerPath' (Apply неминуче розгортає торкнутий контейнер у плоску форму — Configurator-серіалізатор не вміє записувати вкладені значення)"

        # --- Configurator/NestedDeniedOverrideClearRemovesEmptyContainer ---
        # Окремий, ІЗОЛЬОВАНИЙ сценарій: контейнер, ЄДИНИЙ член якого —
        # сам denied-лист. Після Clear контейнер мусить спорожніти і
        # ЗНИКНУТИ з persisted output цілком (не лишитись як '= @{}').
        $emptyContainerScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
            ("BRAVO_CONFIGURATOR_NESTEDDENIED_EMPTYCONTAINER_{0}" -f [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($emptyContainerScenarioRoot)
        try {
            $emptyContainerLocalConfigPath = Join-Path $emptyContainerScenarioRoot 'BRAVO.local.config'
            [IO.File]::WriteAllText(
                $emptyContainerLocalConfigPath, (
                    "@{`r`n" +
                    "    '$nestedDeniedContainerPath' = @{`r`n" +
                    "        'Mode' = 'Legacy'`r`n" +
                    "    }`r`n" +
                    "}`r`n"
                ),
                (New-Object System.Text.UTF8Encoding($false))
            )
            $emptyContainerBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $emptyContainerScenarioRoot
            $emptyContainerModel = Get-BRAVOConfiguratorModel -SchemaCatalog $nestedDeniedResolvedCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $emptyContainerBaseline.Overrides
            $emptyContainerCleared = Clear-BRAVOConfiguratorOverride -Model $emptyContainerModel -Path $nestedDeniedLeafPath
            $emptyContainerFinalModel = Update-BRAVOConfiguratorEffective -Model $emptyContainerCleared -RuntimeRoot $configuratorFixtureRuntimeRoot
            $emptyContainerFinalApply = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $emptyContainerScenarioRoot -Model $emptyContainerFinalModel -SchemaCatalog $nestedDeniedResolvedCatalog -ProductionBaseline $emptyContainerBaseline
            $emptyContainerFinalContent = if (Test-Path -LiteralPath $emptyContainerLocalConfigPath) {
                Get-Content -LiteralPath $emptyContainerLocalConfigPath -Raw -Encoding UTF8
            } else { '' }
            Test-BRAVOCondition (
                [bool]$emptyContainerFinalApply.Applied -and [string]$emptyContainerFinalApply.Stage -eq 'Complete' -and
                (-not $emptyContainerFinalContent.Contains($nestedDeniedContainerPath))
            ) `
                'Configurator/NestedDeniedOverrideClearRemovesEmptyContainer' `
                "коли Clear прибирає ЄДИНОГО члена вкладеного контейнера, сам контейнер мусить зникнути з persisted output цілком (не лишитись порожнім '= @{}'); отримано Applied=$($emptyContainerFinalApply.Applied) Stage=$($emptyContainerFinalApply.Stage) Content=$emptyContainerFinalContent"
        } finally {
            Remove-Item -LiteralPath $emptyContainerScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        # --- Configurator/FlatDeniedOverrideRecoveryStillWorks ---
        # N1 регресійний контроль: плоска (флат) форма (F2-фікс) і далі
        # працює ідентично через ЦЕЙ САМИЙ Resolve-BRAVOConfiguratorSuppliedLeafOverride,
        # не лише через окремий, історичний тестовий блок вище.
        $flatRegressionOverrides = @{ $nestedDeniedLeafPath = 'Legacy' }
        $flatRegressionResolved = Resolve-BRAVOConfiguratorSuppliedLeafOverride -LocalOverrides $flatRegressionOverrides -LeafPath $nestedDeniedLeafPath
        Test-BRAVOCondition (
            [bool]$flatRegressionResolved.Found -and [string]$flatRegressionResolved.Value -eq 'Legacy' -and
            @($flatRegressionResolved.NestedPath).Count -eq 0 -and [string]$flatRegressionResolved.TopLevelKey -eq $nestedDeniedLeafPath
        ) `
            'Configurator/FlatDeniedOverrideRecoveryStillWorks' `
            "плоска форма мусить і далі коректно резолвитись (NestedPath=[] порожній, TopLevelKey=точний leaf-шлях); отримано Found=$($flatRegressionResolved.Found) NestedPath.Count=$(@($flatRegressionResolved.NestedPath).Count)"
    } finally {
        Remove-Item -LiteralPath $nestedDeniedScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# PR #224 review, четверте коло (P2): backupMonitoring.SFTP.BAZA.MutationPolicy
# отримав canonical Configurator-дескриптор (recovery-only, дзеркалить
# сусідній Mode-блок вище) — до цього легасі MutationPolicy-override не
# мав жодного Model-рядка, через який оператор міг би його транзакційно
# зняти: loader fail-closed блокував запуск, а Configurator НЕ показував
# жодного шляху відновлення (той самий баг-клас, що F2 закрив для Mode).
# Дескриптор НЕ робить лист звичайним редагованим site-налаштуванням —
# canonical Class лишається DENY_SECURITY_CONTROL,
# WeakeningOverride='None' (BRAVO.Configuration.Schema.psm1); ReadOnly
# похідний (Resolve-BRAVOConfiguratorFieldAuthorization примусово $true
# для будь-якого DENY_*-класу) — жодної MutationPolicy-специфічної гілки
# коду в Model/Persistence не додано, той самий generic-механізм, що вже
# обслуговує Mode.
# =====================================================================
& {
    if (-not (Get-Module -Name 'BRAVO.Configuration')) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.psd1') -Force
    }
    if (-not (Get-Module -Name 'BRAVO.Configuration.Schema')) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Schema.psd1') -Force
    }

    $mutPolPath = 'backupMonitoring.SFTP.BAZA.MutationPolicy'
    $mutPolContainerPath = 'backupMonitoring.SFTP.BAZA'
    $mutPolSiblingPath = 'backupMonitoring.SFTP.BAZA.FullAuditEnabled'
    $mutPolSiblingValue = $true
    $mutPolRawCatalog = Get-BRAVOConfiguratorSchemaCatalog
    $mutPolClassRegistry = Get-BRAVOConfigurationSchemaAuthorizationClass
    $mutPolResolvedCatalog = Resolve-BRAVOConfiguratorFieldAuthorization -Descriptors $mutPolRawCatalog -AuthorizationClass $mutPolClassRegistry

    # --- Configurator/MutationPolicyRecoveryDescriptorExists ---
    $mutPolDescriptor = @($mutPolRawCatalog | Where-Object { $_.Path -eq $mutPolPath })
    Test-BRAVOCondition (
        $mutPolDescriptor.Count -eq 1 -and [string]$mutPolClassRegistry[$mutPolPath].Class -eq 'DENY_SECURITY_CONTROL' -and
        [string]$mutPolClassRegistry[$mutPolPath].WeakeningOverride -ne 'ExistingSecurityEscapeHatch'
    ) `
        'Configurator/MutationPolicyRecoveryDescriptorExists' `
        "рівно ОДИН Configurator-дескриптор мусить існувати для $mutPolPath, а canonical авторизація мусить лишатись DENY_SECURITY_CONTROL/не-escapable; отримано DescriptorCount=$($mutPolDescriptor.Count) Class=$($mutPolClassRegistry[$mutPolPath].Class) WeakeningOverride=$($mutPolClassRegistry[$mutPolPath].WeakeningOverride)"

    # ===== Плоский (flat) легасі-override =====
    $mutPolFlatScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_CONFIGURATOR_MUTATIONPOLICY_FLAT_{0}" -f [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($mutPolFlatScenarioRoot)
    try {
        $mutPolFlatLocalConfigPath = Join-Path $mutPolFlatScenarioRoot 'BRAVO.local.config'
        [IO.File]::WriteAllText(
            $mutPolFlatLocalConfigPath,
            (ConvertTo-BRAVOConfiguratorLocalConfigText -MergedOverrides @{
                $mutPolPath        = 'Fail'
                $mutPolSiblingPath = $mutPolSiblingValue
            }),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $mutPolFlatBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $mutPolFlatScenarioRoot
        $mutPolFlatModel = Get-BRAVOConfiguratorModel -SchemaCatalog $mutPolResolvedCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $mutPolFlatBaseline.Overrides
        $mutPolFlatSetting = @($mutPolFlatModel | Where-Object { $_.Path -eq $mutPolPath })

        # --- Configurator/MutationPolicyLegacyFlatOverrideDetected ---
        Test-BRAVOCondition (
            $mutPolFlatSetting.Count -eq 1 -and [bool]$mutPolFlatSetting[0].OverridePresent -and
            [string]$mutPolFlatSetting[0].OverrideValue -eq 'Fail'
        ) `
            'Configurator/MutationPolicyLegacyFlatOverrideDetected' `
            "плоский легасі $mutPolPath='Fail' мусить бути виявлений Model-побудовою; отримано OverridePresent=$($mutPolFlatSetting[0].OverridePresent) Value=$($mutPolFlatSetting[0].OverrideValue)"

        # --- Configurator/MutationPolicyLegacyOverrideIsReadOnlyButClearable ---
        $mutPolFlatCleared = Clear-BRAVOConfiguratorOverride -Model $mutPolFlatModel -Path $mutPolPath
        $mutPolFlatClearedSetting = @($mutPolFlatCleared | Where-Object { $_.Path -eq $mutPolPath })
        Test-BRAVOCondition (
            [bool]$mutPolFlatSetting[0].Metadata.ReadOnly -eq $true -and
            $mutPolFlatClearedSetting.Count -eq 1 -and (-not [bool]$mutPolFlatClearedSetting[0].OverridePresent)
        ) `
            'Configurator/MutationPolicyLegacyOverrideIsReadOnlyButClearable' `
            "легасі MutationPolicy-override мусить бути ReadOnly=`$true (canonical adapter), але й далі знімний через Clear-BRAVOConfiguratorOverride; отримано ReadOnly=$($mutPolFlatSetting[0].Metadata.ReadOnly) OverridePresentAfterClear=$($mutPolFlatClearedSetting[0].OverridePresent)"

        # --- Configurator/MutationPolicyApplyWithoutClearFails ---
        $mutPolFlatPreApplyBytes = [IO.File]::ReadAllBytes($mutPolFlatLocalConfigPath)
        $mutPolFlatModelUnchanged = Update-BRAVOConfiguratorEffective -Model $mutPolFlatModel -RuntimeRoot $configuratorFixtureRuntimeRoot
        $mutPolFlatApplyUnchanged = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $mutPolFlatScenarioRoot -Model $mutPolFlatModelUnchanged -SchemaCatalog $mutPolResolvedCatalog -ProductionBaseline $mutPolFlatBaseline
        $mutPolFlatPostApplyBytes = [IO.File]::ReadAllBytes($mutPolFlatLocalConfigPath)
        Test-BRAVOCondition (
            (-not [bool]$mutPolFlatApplyUnchanged.Applied) -and [string]$mutPolFlatApplyUnchanged.Stage -eq 'Validation' -and
            ([Convert]::ToBase64String($mutPolFlatPreApplyBytes) -eq [Convert]::ToBase64String($mutPolFlatPostApplyBytes))
        ) `
            'Configurator/MutationPolicyApplyWithoutClearFails' `
            "Apply з незмінним MutationPolicy-override мусить провалитись на Validation, production-файл лишається побайтово незмінним; отримано Applied=$($mutPolFlatApplyUnchanged.Applied) Stage=$($mutPolFlatApplyUnchanged.Stage)"

        # --- Configurator/MutationPolicyClearSucceeds ---
        # --- Configurator/MutationPolicyClearPreservesSibling ---
        $mutPolFlatFinalModel = Update-BRAVOConfiguratorEffective -Model $mutPolFlatCleared -RuntimeRoot $configuratorFixtureRuntimeRoot
        $mutPolFlatFinalApply = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $mutPolFlatScenarioRoot -Model $mutPolFlatFinalModel -SchemaCatalog $mutPolResolvedCatalog -ProductionBaseline $mutPolFlatBaseline
        $mutPolFlatFinalContent = if (Test-Path -LiteralPath $mutPolFlatLocalConfigPath) {
            Get-Content -LiteralPath $mutPolFlatLocalConfigPath -Raw -Encoding UTF8
        } else { '' }
        Test-BRAVOCondition (
            [bool]$mutPolFlatFinalApply.Applied -and [string]$mutPolFlatFinalApply.Stage -eq 'Complete' -and
            (-not $mutPolFlatFinalContent.Contains($mutPolPath))
        ) `
            'Configurator/MutationPolicyClearSucceeds' `
            "після Clear валідний candidate мусить пройти Apply (Applied=`$true, Stage=Complete), результуючий файл більше не повинен містити '$mutPolPath'; отримано Applied=$($mutPolFlatFinalApply.Applied) Stage=$($mutPolFlatFinalApply.Stage)"
        Test-BRAVOCondition (
            $mutPolFlatFinalContent.Contains($mutPolSiblingPath)
        ) `
            'Configurator/MutationPolicyClearPreservesSibling' `
            "сусідній ALLOW_SITE-лист '$mutPolSiblingPath' мусить пережити Clear+Apply MutationPolicy незмінним; вміст: $mutPolFlatFinalContent"

        # --- Configurator/MutationPolicyNotEscapableWithWeakenedSecurity ---
        $mutPolWeakenOriginalEnv = [System.Environment]::GetEnvironmentVariable('BRAVO_ALLOW_WEAKENED_SECURITY')
        try {
            [System.Environment]::SetEnvironmentVariable('BRAVO_ALLOW_WEAKENED_SECURITY', '1')
            $mutPolEscapeHatchResult = Test-BRAVOConfigurationWeakeningEscapeHatchAllowed -Path $mutPolPath
            $mutPolPreviewWithEnv = ConvertTo-BRAVOConfiguratorOverrideHashtable -Model $mutPolFlatModel
            Test-BRAVOCondition (
                (-not $mutPolEscapeHatchResult) -and (-not $mutPolPreviewWithEnv.Contains($mutPolPath))
            ) `
                'Configurator/MutationPolicyNotEscapableWithWeakenedSecurity' `
                "$mutPolPath мусить лишитись non-escapable навіть з BRAVO_ALLOW_WEAKENED_SECURITY=1 (WeakeningOverride='None'), і preview мусить і далі виключати його; отримано EscapeHatchAllowed=$mutPolEscapeHatchResult PreviewContains=$($mutPolPreviewWithEnv.Contains($mutPolPath))"
        } finally {
            [System.Environment]::SetEnvironmentVariable('BRAVO_ALLOW_WEAKENED_SECURITY', $mutPolWeakenOriginalEnv)
        }
    } finally {
        Remove-Item -LiteralPath $mutPolFlatScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ===== Вкладена (nested) легасі-форма =====
    $mutPolNestedScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_CONFIGURATOR_MUTATIONPOLICY_NESTED_{0}" -f [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($mutPolNestedScenarioRoot)
    try {
        $mutPolNestedLocalConfigPath = Join-Path $mutPolNestedScenarioRoot 'BRAVO.local.config'
        [IO.File]::WriteAllText(
            $mutPolNestedLocalConfigPath, (
                "@{`r`n" +
                "    '$mutPolContainerPath' = @{`r`n" +
                "        'MutationPolicy' = 'Fail'`r`n" +
                "        'FullAuditEnabled' = `$true`r`n" +
                "    }`r`n" +
                "}`r`n"
            ),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $mutPolNestedBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $mutPolNestedScenarioRoot
        $mutPolNestedModel = Get-BRAVOConfiguratorModel -SchemaCatalog $mutPolResolvedCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $mutPolNestedBaseline.Overrides
        $mutPolNestedSetting = @($mutPolNestedModel | Where-Object { $_.Path -eq $mutPolPath })

        # --- Configurator/MutationPolicyNestedOverrideDetected ---
        Test-BRAVOCondition (
            $mutPolNestedSetting.Count -eq 1 -and [bool]$mutPolNestedSetting[0].OverridePresent -and
            [string]$mutPolNestedSetting[0].OverrideValue -eq 'Fail' -and [bool]$mutPolNestedSetting[0].Metadata.ReadOnly -eq $true
        ) `
            'Configurator/MutationPolicyNestedOverrideDetected' `
            "вкладений $mutPolPath мусить бути виявлений як canonical leaf (OverridePresent=`$true, Value='Fail', ReadOnly=`$true); отримано OverridePresent=$($mutPolNestedSetting[0].OverridePresent) Value=$($mutPolNestedSetting[0].OverrideValue) ReadOnly=$($mutPolNestedSetting[0].Metadata.ReadOnly)"

        # --- Configurator/MutationPolicyNestedClearPreservesSibling ---
        $mutPolNestedCleared = Clear-BRAVOConfiguratorOverride -Model $mutPolNestedModel -Path $mutPolPath
        $mutPolNestedFinalModel = Update-BRAVOConfiguratorEffective -Model $mutPolNestedCleared -RuntimeRoot $configuratorFixtureRuntimeRoot
        $mutPolNestedFinalApply = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $mutPolNestedScenarioRoot -Model $mutPolNestedFinalModel -SchemaCatalog $mutPolResolvedCatalog -ProductionBaseline $mutPolNestedBaseline
        $mutPolNestedFinalContent = if (Test-Path -LiteralPath $mutPolNestedLocalConfigPath) {
            Get-Content -LiteralPath $mutPolNestedLocalConfigPath -Raw -Encoding UTF8
        } else { '' }
        Test-BRAVOCondition (
            [bool]$mutPolNestedFinalApply.Applied -and [string]$mutPolNestedFinalApply.Stage -eq 'Complete' -and
            (-not $mutPolNestedFinalContent.Contains("'Fail'")) -and
            $mutPolNestedFinalContent.Contains($mutPolSiblingPath)
        ) `
            'Configurator/MutationPolicyNestedClearPreservesSibling' `
            "після Clear вкладеного MutationPolicy: Apply мусить успішно пройти (flatten-on-touch розгортає контейнер), 'Fail' мусить зникнути, а сусід $mutPolSiblingPath мусить лишитись; отримано Applied=$($mutPolNestedFinalApply.Applied) Stage=$($mutPolNestedFinalApply.Stage) Content=$mutPolNestedFinalContent"
    } finally {
        Remove-Item -LiteralPath $mutPolNestedScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ===== Неможливо створити НОВИЙ MutationPolicy-override =====
    $mutPolCleanScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_CONFIGURATOR_MUTATIONPOLICY_CLEAN_{0}" -f [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($mutPolCleanScenarioRoot)
    try {
        # Жодного BRAVO.local.config у цій директорії — справді чистий
        # старт (той самий патерн, що "14: candidate valid -> atomic
        # apply (на порожній production-директорії)" вище у цьому файлі).
        $mutPolCleanBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $mutPolCleanScenarioRoot
        Test-BRAVOCondition (-not $mutPolCleanBaseline.Overrides.Contains($mutPolPath)) `
            'Configurator/MutationPolicyCannotBeNewlyCreated/BaselineStartsClean' `
            "fixture-передумова: чистий baseline НЕ повинен вже містити $mutPolPath; отримано Contains=$($mutPolCleanBaseline.Overrides.Contains($mutPolPath))"

        $mutPolCleanModel = Get-BRAVOConfiguratorModel -SchemaCatalog $mutPolResolvedCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $mutPolCleanBaseline.Overrides
        # Оператор (чи UI, що не звірив ReadOnly) намагається СТВОРИТИ
        # override, якого раніше не було — Set-BRAVOConfiguratorOverride
        # сам по собі не перевіряє ReadOnly (презентаційна відповідальність
        # UI-шару), тому справжній gate — canonical Apply-конвеєр нижче.
        $mutPolCleanAttempt = Set-BRAVOConfiguratorOverride -Model $mutPolCleanModel -Path $mutPolPath -Value 'Fail'
        $mutPolCleanAttempt = Update-BRAVOConfiguratorEffective -Model $mutPolCleanAttempt -RuntimeRoot $configuratorFixtureRuntimeRoot
        $mutPolCleanApply = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $mutPolCleanScenarioRoot -Model $mutPolCleanAttempt -SchemaCatalog $mutPolResolvedCatalog -ProductionBaseline $mutPolCleanBaseline
        $mutPolCleanConfigPath = Join-Path $mutPolCleanScenarioRoot 'BRAVO.local.config'
        Test-BRAVOCondition (
            (-not [bool]$mutPolCleanApply.Applied) -and [string]$mutPolCleanApply.Stage -eq 'Validation' -and
            (-not (Test-Path -LiteralPath $mutPolCleanConfigPath))
        ) `
            'Configurator/MutationPolicyCannotBeNewlyCreated' `
            "спроба ВПЕРШЕ створити $mutPolPath через Configurator-конвеєр мусить провалитись fail-closed на Validation, і жоден production-файл не повинен бути записаний; отримано Applied=$($mutPolCleanApply.Applied) Stage=$($mutPolCleanApply.Stage) FileExists=$(Test-Path -LiteralPath $mutPolCleanConfigPath)"
    } finally {
        Remove-Item -LiteralPath $mutPolCleanScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ===== Змішаний контейнер: Mode + MutationPolicy обидва DENY =====
    # Доводить, що recovery leaf-специфічний і атомарний: часткове Clear
    # (лише одного з двох DENY-сусідів у тому самому контейнері) НЕ
    # повинно дозволяти Apply, доки НЕ прибрано ОБИДВА.
    $mutPolMixedScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_CONFIGURATOR_MUTATIONPOLICY_MIXED_{0}" -f [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($mutPolMixedScenarioRoot)
    try {
        $mutPolMixedLocalConfigPath = Join-Path $mutPolMixedScenarioRoot 'BRAVO.local.config'
        [IO.File]::WriteAllText(
            $mutPolMixedLocalConfigPath, (
                "@{`r`n" +
                "    '$mutPolContainerPath' = @{`r`n" +
                "        'Mode' = 'Legacy'`r`n" +
                "        'MutationPolicy' = 'Fail'`r`n" +
                "        'FullAuditEnabled' = `$true`r`n" +
                "    }`r`n" +
                "}`r`n"
            ),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $mutPolMixedBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $mutPolMixedScenarioRoot
        $mutPolMixedModel = Get-BRAVOConfiguratorModel -SchemaCatalog $mutPolResolvedCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $mutPolMixedBaseline.Overrides
        $mutPolMixedPreBytes = [IO.File]::ReadAllBytes($mutPolMixedLocalConfigPath)

        # --- Configurator/BazaDeniedSiblingRecoveryIsLeafSpecific ---
        # Сценарій A: прибрати ЛИШЕ Mode -> MutationPolicy лишається,
        # Apply і далі відхиляється, файл незмінний.
        $mutPolMixedClearModeOnly = Clear-BRAVOConfiguratorOverride -Model $mutPolMixedModel -Path 'backupMonitoring.SFTP.BAZA.Mode'
        $mutPolMixedClearModeOnly = Update-BRAVOConfiguratorEffective -Model $mutPolMixedClearModeOnly -RuntimeRoot $configuratorFixtureRuntimeRoot
        $mutPolMixedApplyModeOnly = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $mutPolMixedScenarioRoot -Model $mutPolMixedClearModeOnly -SchemaCatalog $mutPolResolvedCatalog -ProductionBaseline $mutPolMixedBaseline
        $mutPolMixedPostBytesA = [IO.File]::ReadAllBytes($mutPolMixedLocalConfigPath)

        # Сценарій B: прибрати ЛИШЕ MutationPolicy -> Mode лишається,
        # Apply і далі відхиляється, файл незмінний. Той самий незмінний
        # $mutPolMixedModel/$mutPolMixedBaseline (Сценарій A нічого не
        # записав — Applied=false зупиняється до atomic replace), тож
        # обидва сценарії genuinely незалежні, не кумулятивні.
        $mutPolMixedClearPolicyOnly = Clear-BRAVOConfiguratorOverride -Model $mutPolMixedModel -Path $mutPolPath
        $mutPolMixedClearPolicyOnly = Update-BRAVOConfiguratorEffective -Model $mutPolMixedClearPolicyOnly -RuntimeRoot $configuratorFixtureRuntimeRoot
        $mutPolMixedApplyPolicyOnly = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $mutPolMixedScenarioRoot -Model $mutPolMixedClearPolicyOnly -SchemaCatalog $mutPolResolvedCatalog -ProductionBaseline $mutPolMixedBaseline
        $mutPolMixedPostBytesB = [IO.File]::ReadAllBytes($mutPolMixedLocalConfigPath)

        Test-BRAVOCondition (
            (-not [bool]$mutPolMixedApplyModeOnly.Applied) -and [string]$mutPolMixedApplyModeOnly.Stage -eq 'Validation' -and
            ([Convert]::ToBase64String($mutPolMixedPreBytes) -eq [Convert]::ToBase64String($mutPolMixedPostBytesA)) -and
            (-not [bool]$mutPolMixedApplyPolicyOnly.Applied) -and [string]$mutPolMixedApplyPolicyOnly.Stage -eq 'Validation' -and
            ([Convert]::ToBase64String($mutPolMixedPreBytes) -eq [Convert]::ToBase64String($mutPolMixedPostBytesB))
        ) `
            'Configurator/BazaDeniedSiblingRecoveryIsLeafSpecific' `
            ("часткове Clear лише ОДНОГО з двох DENY-сусідів (Mode або MutationPolicy) у тому самому контейнері НЕ повинно дозволяти Apply, доки лишається другий; " +
             "отримано ClearModeOnly: Applied=$($mutPolMixedApplyModeOnly.Applied) Stage=$($mutPolMixedApplyModeOnly.Stage) FileChanged=$([Convert]::ToBase64String($mutPolMixedPreBytes) -ne [Convert]::ToBase64String($mutPolMixedPostBytesA)); " +
             "ClearPolicyOnly: Applied=$($mutPolMixedApplyPolicyOnly.Applied) Stage=$($mutPolMixedApplyPolicyOnly.Stage) FileChanged=$([Convert]::ToBase64String($mutPolMixedPreBytes) -ne [Convert]::ToBase64String($mutPolMixedPostBytesB))")

        # --- Configurator/BazaBothDeniedLeavesClearedApplySucceeds ---
        $mutPolMixedClearBoth = Clear-BRAVOConfiguratorOverride -Model $mutPolMixedModel -Path 'backupMonitoring.SFTP.BAZA.Mode'
        $mutPolMixedClearBoth = Clear-BRAVOConfiguratorOverride -Model $mutPolMixedClearBoth -Path $mutPolPath
        $mutPolMixedClearBoth = Update-BRAVOConfiguratorEffective -Model $mutPolMixedClearBoth -RuntimeRoot $configuratorFixtureRuntimeRoot
        $mutPolMixedApplyBoth = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $mutPolMixedScenarioRoot -Model $mutPolMixedClearBoth -SchemaCatalog $mutPolResolvedCatalog -ProductionBaseline $mutPolMixedBaseline
        $mutPolMixedFinalContent = if (Test-Path -LiteralPath $mutPolMixedLocalConfigPath) {
            Get-Content -LiteralPath $mutPolMixedLocalConfigPath -Raw -Encoding UTF8
        } else { '' }
        Test-BRAVOCondition (
            [bool]$mutPolMixedApplyBoth.Applied -and [string]$mutPolMixedApplyBoth.Stage -eq 'Complete' -and
            (-not $mutPolMixedFinalContent.Contains("'Legacy'")) -and
            (-not $mutPolMixedFinalContent.Contains("'Fail'")) -and
            $mutPolMixedFinalContent.Contains($mutPolSiblingPath)
        ) `
            'Configurator/BazaBothDeniedLeavesClearedApplySucceeds' `
            "після Clear ОБОХ (Mode і MutationPolicy) Apply мусить успішно пройти (Applied=`$true, Stage=Complete), жоден із двох DENY-листів не повинен лишитись, а ALLOW_SITE-сусід $mutPolSiblingPath мусить пережити; отримано Applied=$($mutPolMixedApplyBoth.Applied) Stage=$($mutPolMixedApplyBoth.Stage) Content=$mutPolMixedFinalContent"
    } finally {
        Remove-Item -LiteralPath $mutPolMixedScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# PR #224 third review, R3-1: Configurator effective preview повинна
# відображати наявний BRAVO_ALLOW_WEAKENED_SECURITY=1 escape hatch для
# requireAdministrator (canonical WeakeningOverride='ExistingSecurityEscapeHatch'),
# і БЕЗУМОВНО відхиляти backupMonitoring.SFTP.BAZA.Mode/.MutationPolicy
# незалежно від env (WeakeningOverride='None' — fail-closed за
# замовчуванням). Env-змінна процесу зберігається/відновлюється в
# try/finally, щоб не протікати в інші self-test-фрагменти.
# =====================================================================
& {
    if (-not (Get-Module -Name 'BRAVO.Configuration')) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.psd1') -Force
    }
    if (-not (Get-Module -Name 'BRAVO.Configuration.Schema')) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Schema.psd1') -Force
    }

    $r31OriginalEnv = [System.Environment]::GetEnvironmentVariable('BRAVO_ALLOW_WEAKENED_SECURITY')
    try {
        [System.Environment]::SetEnvironmentVariable('BRAVO_ALLOW_WEAKENED_SECURITY', $null)

        # --- Preview/RequireAdministratorWeakeningRejectedWithoutEnv ---
        $r31WithoutEnv = Test-BRAVOConfigurationWeakeningEscapeHatchAllowed -Path 'requireAdministrator'
        Test-BRAVOCondition (-not $r31WithoutEnv) `
            'Preview/RequireAdministratorWeakeningRejectedWithoutEnv' `
            "без BRAVO_ALLOW_WEAKENED_SECURITY=1 requireAdministrator НЕ повинен бути escapable; отримано $r31WithoutEnv"

        $r31BaseModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{}

        # requireAdministrator НЕ має власного Configurator UI-дескриптора
        # (не редагується через Configurator взагалі — підтверджено:
        # немає запису в BRAVO.Configurator.Schema.psd1), тому
        # Get-BRAVOConfiguratorModel/Set-BRAVOConfiguratorOverride НІКОЛИ
        # не можуть створити для нього Setting-рядок. ConvertTo-BRAVOConfiguratorOverrideHashtable
        # приймає БУДЬ-ЯКИЙ масив об'єктів з Path/OverridePresent/OverrideValue
        # (контракт функції не вимагає походження саме від SchemaCatalog) —
        # синтетичний рядок тестує САМЕ ЦЮ функцію напряму, без залежності
        # від того, чи colись з'явиться UI-дескриптор для цього листа.
        # Властивості нижче (EffectiveValue/EffectiveSource/DisabledReason/
        # ValidationState/DependencyState/Dirty) присутні порожніми, бо
        # Update-BRAVOConfiguratorEffective (нижче, блок
        # RequireAdministratorWeakeningAllowed/EffectiveReflectsLoader) під
        # Set-StrictMode -Version 2.0 присвоює $clone.EffectiveValue/
        # .DisabledReason/.EffectiveSource на PSObject.Copy() цього рядка —
        # той самий canonical Setting-shape, що Get-BRAVOConfiguratorModel
        # створює (BRAVO.Configurator.Model.psm1, ~рядок 362), інакше
        # присвоєння неіснуючої властивості PSCustomObject кидає виняток.
        $r31ModelWithOverride = @(
            [pscustomobject]@{
                Path            = 'requireAdministrator'
                Metadata        = $null
                DefaultValue    = $true
                OverridePresent = $true
                OverrideValue   = $false
                EffectiveValue  = $null
                EffectiveSource = $null
                DisabledReason  = $null
                ValidationState = $null
                DependencyState = $null
                Dirty           = $false
            }
        )

        $r31PreviewWithoutEnv = ConvertTo-BRAVOConfiguratorOverrideHashtable -Model $r31ModelWithOverride
        Test-BRAVOCondition (-not $r31PreviewWithoutEnv.Contains('requireAdministrator')) `
            'Preview/RequireAdministratorWeakeningRejectedWithoutEnv/ProjectionExcludesOverride' `
            "без env-підтвердження requireAdministrator=`$false НЕ повинен передаватись canonical loader-у для preview; Contains=$($r31PreviewWithoutEnv.Contains('requireAdministrator'))"

        # --- Preview/RequireAdministratorWeakeningAllowed ---
        [System.Environment]::SetEnvironmentVariable('BRAVO_ALLOW_WEAKENED_SECURITY', '1')

        $r31WithEnv = Test-BRAVOConfigurationWeakeningEscapeHatchAllowed -Path 'requireAdministrator'
        Test-BRAVOCondition ([bool]$r31WithEnv) `
            'Preview/RequireAdministratorWeakeningAllowed' `
            "з BRAVO_ALLOW_WEAKENED_SECURITY=1 requireAdministrator МУСИТЬ бути escapable (canonical WeakeningOverride='ExistingSecurityEscapeHatch'); отримано $r31WithEnv"

        $r31PreviewWithEnv = ConvertTo-BRAVOConfiguratorOverrideHashtable -Model $r31ModelWithOverride
        Test-BRAVOCondition (
            $r31PreviewWithEnv.Contains('requireAdministrator') -and [bool]$r31PreviewWithEnv['requireAdministrator'] -eq $false
        ) `
            'Preview/RequireAdministratorWeakeningAllowed/ProjectionIncludesOverride' `
            "з env-підтвердженням requireAdministrator=`$false МУСИТЬ передаватись canonical loader-у для preview; Contains=$($r31PreviewWithEnv.Contains('requireAdministrator')) Value=$($r31PreviewWithEnv['requireAdministrator'])"

        # Наскрізна перевірка: Effective дійсно стає $false через реальний
        # canonical loader (child-process), не лише проєкція hashtable —
        # Start-Process успадковує env поточного процесу за замовчуванням.
        $r31EffectiveModel = Update-BRAVOConfiguratorEffective -Model $r31ModelWithOverride -RuntimeRoot $configuratorFixtureRuntimeRoot
        $r31RequireAdminSetting = @($r31EffectiveModel | Where-Object { $_.Path -eq 'requireAdministrator' })
        Test-BRAVOCondition (
            $r31RequireAdminSetting.Count -eq 1 -and [bool]$r31RequireAdminSetting[0].EffectiveValue -eq $false
        ) `
            'Preview/RequireAdministratorWeakeningAllowed/EffectiveReflectsLoader' `
            "з env-підтвердженням canonical loader МУСИТЬ прийняти override, тож Effective мусить стати `$false; отримано EffectiveValue=$($r31RequireAdminSetting[0].EffectiveValue)"

        # --- Preview/BazaModeStillRejectedWithWeakeningEnv ---
        # (env і далі '1' з блоку вище — саме цей стан мусить лишатись недостатнім для BAZA.*)
        $r31BazaModeResult = Test-BRAVOConfigurationWeakeningEscapeHatchAllowed -Path 'backupMonitoring.SFTP.BAZA.Mode'
        Test-BRAVOCondition (-not $r31BazaModeResult) `
            'Preview/BazaModeStillRejectedWithWeakeningEnv' `
            "backupMonitoring.SFTP.BAZA.Mode НІКОЛИ не escapable, незалежно від BRAVO_ALLOW_WEAKENED_SECURITY (WeakeningOverride='None'); отримано $r31BazaModeResult"

        $r31BazaModeSetting = @($r31BaseModel | Where-Object { $_.Path -eq 'backupMonitoring.SFTP.BAZA.Mode' })
        Test-BRAVOCondition ($r31BazaModeSetting.Count -eq 1) `
            'Preview/BazaModeStillRejectedWithWeakeningEnv/DescriptorExists' `
            "fixture-передумова: backupMonitoring.SFTP.BAZA.Mode мусить мати Configurator-дескриптор; отримано Count=$($r31BazaModeSetting.Count)"
        $r31BazaModeModel = Set-BRAVOConfiguratorOverride -Model $r31BaseModel -Path 'backupMonitoring.SFTP.BAZA.Mode' -Value 'Legacy'
        $r31BazaModePreview = ConvertTo-BRAVOConfiguratorOverrideHashtable -Model $r31BazaModeModel
        Test-BRAVOCondition (-not $r31BazaModePreview.Contains('backupMonitoring.SFTP.BAZA.Mode')) `
            'Preview/BazaModeStillRejectedWithWeakeningEnv/ProjectionExcludesOverride' `
            "навіть з BRAVO_ALLOW_WEAKENED_SECURITY=1 BAZA.Mode НЕ повинен передаватись canonical loader-у для preview; Contains=$($r31BazaModePreview.Contains('backupMonitoring.SFTP.BAZA.Mode'))"

        # --- Preview/BazaMutationPolicyStillRejectedWithWeakeningEnv ---
        # MutationPolicy не має власного Configurator-дескриптора (UI не
        # рендерить цей лист) — перевірка на рівні canonical рішення, того
        # самого, яке ConvertTo-BRAVOConfiguratorOverrideHashtable викликав
        # би, якби такий дескриптор існував.
        $r31BazaMutationPolicyResult = Test-BRAVOConfigurationWeakeningEscapeHatchAllowed -Path 'backupMonitoring.SFTP.BAZA.MutationPolicy'
        Test-BRAVOCondition (-not $r31BazaMutationPolicyResult) `
            'Preview/BazaMutationPolicyStillRejectedWithWeakeningEnv' `
            "backupMonitoring.SFTP.BAZA.MutationPolicy НІКОЛИ не escapable, незалежно від BRAVO_ALLOW_WEAKENED_SECURITY (WeakeningOverride='None'); отримано $r31BazaMutationPolicyResult"
    } finally {
        [System.Environment]::SetEnvironmentVariable('BRAVO_ALLOW_WEAKENED_SECURITY', $r31OriginalEnv)
    }
}

# =====================================================================
# PR #224 third review, R3-2/R3-3: Convert-BRAVOConfiguratorNestedContainerToFlatKeys
# — explicit flat-key precedence під час flatten-on-touch (R3-2) і
# fail-closed на порожньому вкладеному вузлі (R3-3).
# =====================================================================
& {
    # --- Flatten/ExplicitFlatLeafPrecedenceOverNestedRepresentation ---
    # R3-2 приклад із задачі: SUCCESS заданий і плоским, і вкладеним
    # (різні значення) одночасно; торкання WARNING (сусід у тому самому
    # контейнері) не повинно перезаписати вже явний плоский SUCCESS.
    $r32Overrides = @{
        'bravoSettings.NotificationRouting.SUCCESS' = 'alerts'
        'bravoSettings.NotificationRouting' = @{
            SUCCESS = 'general'
            WARNING = 'alerts'
        }
    }
    Convert-BRAVOConfiguratorNestedContainerToFlatKeys -Overrides $r32Overrides -TopLevelKey 'bravoSettings.NotificationRouting'
    Test-BRAVOCondition (
        $r32Overrides.Contains('bravoSettings.NotificationRouting.SUCCESS') -and
        [string]$r32Overrides['bravoSettings.NotificationRouting.SUCCESS'] -eq 'alerts' -and
        $r32Overrides.Contains('bravoSettings.NotificationRouting.WARNING') -and
        [string]$r32Overrides['bravoSettings.NotificationRouting.WARNING'] -eq 'alerts' -and
        (-not $r32Overrides.Contains('bravoSettings.NotificationRouting'))
    ) `
        'Flatten/ExplicitFlatLeafPrecedenceOverNestedRepresentation' `
        ("явний плоский SUCCESS='alerts' мусить пережити флеттенізацію контейнера (не перезаписаний вкладеним 'general'), " +
         "а WARNING мусить взятись із вкладеного значення; отримано SUCCESS=$($r32Overrides['bravoSettings.NotificationRouting.SUCCESS']) " +
         "WARNING=$($r32Overrides['bravoSettings.NotificationRouting.WARNING']) ContainerStillPresent=$($r32Overrides.Contains('bravoSettings.NotificationRouting'))")

    # --- Flatten/EmptyUnknownNestedContainerFailsClosed ---
    $r33Overrides = @{
        'Some.Container' = @{
            KnownLeaf      = 'value'
            FutureSettings = @{}
        }
    }
    $r33Threw = $false
    $r33Message = $null
    try {
        Convert-BRAVOConfiguratorNestedContainerToFlatKeys -Overrides $r33Overrides -TopLevelKey 'Some.Container'
    } catch {
        $r33Threw = $true
        $r33Message = $_.Exception.Message
    }
    Test-BRAVOCondition (
        $r33Threw -and
        $r33Overrides.Contains('Some.Container') -and
        ($r33Overrides['Some.Container'] -is [hashtable]) -and
        [string]$r33Overrides['Some.Container']['KnownLeaf'] -eq 'value' -and
        $r33Overrides['Some.Container'].Contains('FutureSettings')
    ) `
        'Flatten/EmptyUnknownNestedContainerFailsClosed' `
        ("порожній вкладений вузол ('FutureSettings' = @{}) мусить fail-closed зупинити флеттенізацію ДО будь-якої мутації — контейнер " +
         "мусить лишитись повністю незміненим (не частково розгорнутим); отримано Threw=$r33Threw ContainerPresent=$($r33Overrides.Contains('Some.Container')) Message=$r33Message")

    # --- Apply/EmptyUnknownNestedContainerProductionFileUnchanged ---
    $r33ApplyScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_CONFIGURATOR_EMPTYNESTED_APPLY_{0}" -f [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($r33ApplyScenarioRoot)
    try {
        $r33ApplyConfigPath = Join-Path $r33ApplyScenarioRoot 'BRAVO.local.config'
        [IO.File]::WriteAllText(
            $r33ApplyConfigPath, (
                "@{`r`n" +
                "    'bravoSettings.NotificationRouting' = @{`r`n" +
                "        'CRITICAL' = 'alerts'`r`n" +
                "        'FutureRoutingGroup' = @{}`r`n" +
                "    }`r`n" +
                "}`r`n"
            ),
            (New-Object System.Text.UTF8Encoding($false))
        )
        $r33ApplyBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $r33ApplyScenarioRoot
        $r33ApplyModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $r33ApplyBaseline.Overrides
        # Торкаємо САМЕ той canonical leaf, що вже supplied усередині
        # контейнера (CRITICAL) — це те, що реально резолвиться через
        # Resolve-BRAVOConfiguratorSuppliedLeafOverride як "supplied
        # nested" і форсує флеттенізацію; невідомий (не-schema) leaf
        # типу WARNING-без-попереднього-значення НЕ форсував би її
        # (нема чого резолвити всередині контейнера).
        $r33ApplyModelEdited = Set-BRAVOConfiguratorOverride -Model $r33ApplyModel -Path 'bravoSettings.NotificationRouting.CRITICAL' -Value 'general'
        $r33ApplyPreBytes = [IO.File]::ReadAllBytes($r33ApplyConfigPath)
        $r33ApplyResult = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $r33ApplyScenarioRoot `
            -Model $r33ApplyModelEdited -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $r33ApplyBaseline
        $r33ApplyPostBytes = [IO.File]::ReadAllBytes($r33ApplyConfigPath)
        Test-BRAVOCondition (
            (-not [bool]$r33ApplyResult.Applied) -and [string]$r33ApplyResult.Stage -eq 'Merge' -and
            ([Convert]::ToBase64String($r33ApplyPreBytes) -eq [Convert]::ToBase64String($r33ApplyPostBytes))
        ) `
            'Apply/EmptyUnknownNestedContainerProductionFileUnchanged' `
            ("Apply мусить провалитись fail-closed (Stage='Merge') замість мовчазної втрати порожнього невідомого вкладеного вузла, і " +
             "продакшн-файл мусить лишитись побайтово незмінним; отримано Applied=$($r33ApplyResult.Applied) Stage=$($r33ApplyResult.Stage)")
    } finally {
        Remove-Item -LiteralPath $r33ApplyScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# PR #224 third review, R3-4: BRAVO.local.config.example не повинен
# рекламувати DENY_*-листи як звичайний перелік override-ів, доступних
# для розкоментовування.
# =====================================================================
& {
    if (-not (Get-Module -Name 'BRAVO.Configuration.Schema')) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Schema.psd1') -Force
    }
    $r34DocumentedPaths = Get-BRAVOConfiguratorDocumentedOverridePaths -ExamplePath (Join-Path $root 'BRAVO.local.config.example')
    $r34ClassRegistry = Get-BRAVOConfigurationSchemaAuthorizationClass
    $r34ExampleText = Get-Content -LiteralPath (Join-Path $root 'BRAVO.local.config.example') -Raw -Encoding UTF8

    # --- Contract/DocumentedOverrideTemplateDoesNotExposeDeniedLeaves ---
    # "рекламує як звичайний override" = задокументований шлях є DENY_*
    # БЕЗ явного NON-OVERRIDABLE-маркера поруч із ним у файлі — сам факт
    # присутності в задокументованому переліку (потрібен для 1:1 schema-
    # повноти) не є порушенням, якщо рядок явно позначений як recovery-only.
    $r34UnlabeledDeniedLeaves = New-Object System.Collections.Generic.List[string]
    foreach ($r34Path in $r34DocumentedPaths) {
        if (-not $r34ClassRegistry.Contains($r34Path)) { continue }
        $r34Class = [string]$r34ClassRegistry[$r34Path].Class
        if (-not $r34Class.StartsWith('DENY_', [System.StringComparison]::Ordinal)) { continue }
        if (-not $r34ExampleText.Contains("'$r34Path'") ) { continue }
        # Шукаємо NON-OVERRIDABLE-маркер у безпосередній близькості (той
        # самий рядок) — dot-шлях може з'являтися в файлі кілька разів
        # (напр. попереджувальний коментар-заголовок і сам
        # закоментований entry-рядок нижче), тож перевіряємо УСІ рядки,
        # що містять цей dot-шлях у лапках, а не лише перший знайдений
        # (regex-парсер каталогу читає той самий entry-рядок, що і
        # реальний override-запис, не заголовок).
        # [^\n] (не [^\r\n]) навмисно: файл має CRLF-закінчення рядків, а
        # $ у Multiline-режимі .NET прив'язується безпосередньо ПЕРЕД \n
        # (не перед \r) — виключення \r із класу символів робило б символ
        # \r перед \n непоглинутим, і $ ніколи не міг би збігтись
        # (MatchCount завжди 0 на CRLF-файлах). \r у складі рядка тут
        # нешкідливий — просто ще один звичайний символ вмісту рядка.
        $r34LineMatches = [regex]::Matches($r34ExampleText, "^[^\n]*'$([regex]::Escape($r34Path))'[^\n]*$", [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $r34HasLabeledLine = $false
        foreach ($r34LineMatch in $r34LineMatches) {
            if ($r34LineMatch.Value.Contains('NON-OVERRIDABLE')) { $r34HasLabeledLine = $true; break }
        }
        if ($r34HasLabeledLine) { continue }
        [void]$r34UnlabeledDeniedLeaves.Add($r34Path)
    }
    Test-BRAVOCondition ($r34UnlabeledDeniedLeaves.Count -eq 0) `
        'Contract/DocumentedOverrideTemplateDoesNotExposeDeniedLeaves' `
        "задокументовані DENY_*-листи мусять бути явно позначені NON-OVERRIDABLE, а не представлені як звичайний override; непозначені: $($r34UnlabeledDeniedLeaves -join ', ')"

    # --- Contract/BazaModeExplicitlyLabeledNonOverridable ---
    Test-BRAVOCondition ($r34ExampleText.Contains("'backupMonitoring.SFTP.BAZA.Mode'") -and $r34ExampleText.Contains('NON-OVERRIDABLE')) `
        'Contract/BazaModeExplicitlyLabeledNonOverridable' `
        "backupMonitoring.SFTP.BAZA.Mode мусить лишитись задокументованим (schema-повнота), але з явним NON-OVERRIDABLE-маркером поруч"

    # --- Contract/BazaMutationPolicyExplicitlyLabeledNonOverridable ---
    # PR #224 review (P2, четверте коло): MutationPolicy тепер МАЄ
    # canonical Configurator-дескриптор (recovery-only) — schema-повнота
    # (Test-BRAVOConfiguratorSchemaCompleteness) вимагає документування
    # 1:1, тож "взагалі не з'являється" більше не є правильним контрактом
    # (той тест існував ДО додавання дескриптора). Замість цього — той
    # самий доказ, що вже застосовує Mode: задокументований, але з явним
    # NON-OVERRIDABLE-маркером, тож generic-перевірка вище
    # (Contract/DocumentedOverrideTemplateDoesNotExposeDeniedLeaves) не
    # знаходить його непозначеним.
    Test-BRAVOCondition (
        $r34DocumentedPaths -contains 'backupMonitoring.SFTP.BAZA.MutationPolicy' -and
        $r34ExampleText.Contains("'backupMonitoring.SFTP.BAZA.MutationPolicy'") -and
        $r34ExampleText.Contains('NON-OVERRIDABLE')
    ) `
        'Contract/BazaMutationPolicyExplicitlyLabeledNonOverridable' `
        "backupMonitoring.SFTP.BAZA.MutationPolicy мусить лишитись задокументованим (schema-повнота — тепер має Configurator-дескриптор), але з явним NON-OVERRIDABLE-маркером поруч"
}

# ===== Прибирання fixture RuntimeRoot (герметичність, див. коментар на
# початку файлу). Remove-Item на директорію-junction видаляє лише сам
# reparse point, не рекурсує в реальний modules\ репозиторію. =====
Remove-Item -LiteralPath $configuratorFixtureRuntimeRoot -Recurse -Force -ErrorAction SilentlyContinue
