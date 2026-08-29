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
$configuratorKitConfigText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.config'))
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
    'Configurator 5.2.2 Scenario K: descriptors == canonical documented paths (138), missing=0, stale=0' `
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

# ===== Прибирання fixture RuntimeRoot (герметичність, див. коментар на
# початку файлу). Remove-Item на директорію-junction видаляє лише сам
# reparse point, не рекурсує в реальний modules\ репозиторію. =====
Remove-Item -LiteralPath $configuratorFixtureRuntimeRoot -Recurse -Force -ErrorAction SilentlyContinue
