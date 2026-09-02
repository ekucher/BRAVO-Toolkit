# Домен-фрагмент self-test: BRAVO_MAINTENANCE disk-space integration
# (fix/5.2.3-operation-aware-disk-space, BRAVO_5_2_2_DISK_SPACE_TASK_FINAL.md
# §64 test M1-M11). Тестує РЕАЛЬНИЙ виклик-сайт Maintenance —
# Invoke-BRAVOMaintenanceDiskSpaceCheck, витягнуту з
# BRAVO.Maintenance.Runtime.ps1 через New-BRAVOSelfTestRuntimeModule.
#
# Спрощена модель Maintenance (Phase 0 §5.3): на відміну від Archive, жодна
# поточна Maintenance-операція не має exact/verified розрахунку вимоги —
# увесь запис відбувається під деревом ROOT_LIMS. Тому Maintenance у 5.2.3
# моделює РІВНО ОДНУ write-required роль (MaintenanceWorkingVolume =
# ROOT_LIMS) + health-only sweep решти Fixed-дисків, а не повний набір
# ролей (RestoreTarget/RecoveryTarget/SynchronizationTarget окремо), який
# специфікація описує як цільову модель. Це свідоме звуження обсягу
# (§70 scope control): усуває саме production-баг (§1) мінімальною зміною,
# без multi-role redesign, який жоден наявний Maintenance-код сьогодні не
# підтримує розрахунком. M9 (окреме read-only джерело) та M6 (health-only
# run — у Maintenance немає такого режиму, на відміну від Archive
# -HealthCheckOnly) НЕ застосовні до цієї моделі — задокументовано, не
# приховано.
#
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition,
# New-BRAVOSelfTestRuntimeModule, $script:failures.

Import-Module -Name (Join-Path $root "modules\BRAVO.DiskSpace\BRAVO.DiskSpace.psd1") -Force -ErrorAction Stop

$maintenanceScriptTextForDiskSpace = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
    [Text.Encoding]::UTF8
)
$maintenanceDiskSpaceModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText $maintenanceScriptTextForDiskSpace `
    -FunctionNames @('Invoke-BRAVOMaintenanceDiskSpaceCheck', 'Get-BRAVOMaintenanceDiskSpaceEntities', 'Write-Log', 'Write-BRAVOMaintenanceLogFile')

# Write-Log викликає Write-BRAVOMaintenanceLogFile, яка читає $LOG_DIR/
# $LOG_FILE зі своєї module-scope (той самий підхід ізоляції, що й у
# ManifestStorage-фрагменті нижче по BRAVO_SELF_TEST.ps1). Без екстракції
# цієї функції і встановлення обох змінних $LOG_DIR лишається невстановленим
# і Test-Path отримує $null — ізольований тимчасовий файл нижче усуває це,
# жоден production-каталог не зачіпається.
$maintenanceDiskSpaceLogTempFile = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_MAINT_DISKSPACE_SELF_TEST_{0}.log" -f [guid]::NewGuid().ToString("N"))

function New-MaintenanceDiskSpaceDrive {
    param([string]$Drive, [double]$AvailableGB, [double]$TotalGB = 200, [bool]$IsReady = $true)
    [pscustomobject]@{ Drive = $Drive; IsReady = $IsReady; AvailableFreeSpace = [int64]($AvailableGB * 1GB); TotalSize = [int64]($TotalGB * 1GB); DriveType = 'Fixed' }
}

function Invoke-MaintenanceSpaceCheck {
    param([string]$RootLims, [double]$MinFreeSpace, [string[]]$ExcludedDrives = @(), [object[]]$Drives)
    & $maintenanceDiskSpaceModule {
        param($RootLims, $MinFreeSpace, $ExcludedDrives, $Drives, $LogFilePath)
        $LOG_DIR = [IO.Path]::GetDirectoryName($LogFilePath)
        $LOG_FILE = $LogFilePath
        $script:SlackMode = 'none'
        $script:criticalErrorOccurred = $false
        $script:BRAVOWarningCount = 0
        $MIN_FREE_SPACE = $MinFreeSpace
        $result = Invoke-BRAVOMaintenanceDiskSpaceCheck -ROOT_LIMS $RootLims -ExcludedDrives $ExcludedDrives -Drives $Drives
        [pscustomobject]@{
            Result = $result
            CriticalErrorOccurred = $script:criticalErrorOccurred
            WarningCount = $script:BRAVOWarningCount
            FreeSpaceSummary = $script:freeSpaceSummary
        }
    } $RootLims $MinFreeSpace $ExcludedDrives $Drives $maintenanceDiskSpaceLogTempFile
}

# ============================================================
# M1 — runtime disk below floor (C:), required Maintenance volume (D:) healthy
# ============================================================
$m1Drives = @(New-MaintenanceDiskSpaceDrive -Drive 'C:' -AvailableGB 18; New-MaintenanceDiskSpaceDrive -Drive 'D:' -AvailableGB 100)
$m1 = Invoke-MaintenanceSpaceCheck -RootLims 'D:\LIMS' -MinFreeSpace 20 -Drives $m1Drives
Test-BRAVOCondition `
    -Condition ($m1.Result -eq $true -and -not $m1.CriticalErrorOccurred -and $m1.WarningCount -ge 1) `
    -Name 'Maintenance/M1-RuntimeDiskBelowFloorContinues' `
    -Failure "C: below floor (18<20) не пов'язаний з ROOT_LIMS (D:) не повинен блокувати Maintenance — має продовжити з warning"

# ============================================================
# M2 — runtime disk критично низько, але не write-heavy target
# ============================================================
$m2Drives = @(New-MaintenanceDiskSpaceDrive -Drive 'C:' -AvailableGB 1; New-MaintenanceDiskSpaceDrive -Drive 'D:' -AvailableGB 100)
$m2 = Invoke-MaintenanceSpaceCheck -RootLims 'D:\LIMS' -MinFreeSpace 20 -Drives $m2Drives
Test-BRAVOCondition `
    -Condition ($m2.Result -eq $true -and -not $m2.CriticalErrorOccurred) `
    -Name 'Maintenance/M2-RuntimeCriticallyLowButNotTargetContinues' `
    -Failure "C: критично мало (1GB), але не є ROOT_LIMS — Maintenance має продовжити"

# ============================================================
# M3 — Maintenance target (ROOT_LIMS) insufficient => BLOCK
# ============================================================
$m3Drives = @(New-MaintenanceDiskSpaceDrive -Drive 'D:' -AvailableGB 5)
$m3 = Invoke-MaintenanceSpaceCheck -RootLims 'D:\LIMS' -MinFreeSpace 20 -Drives $m3Drives
Test-BRAVOCondition `
    -Condition ($m3.Result -eq $false -and $m3.CriticalErrorOccurred) `
    -Name 'Maintenance/M3-MaintenanceTargetInsufficientBlocks' `
    -Failure "ROOT_LIMS (D:, 5GB < floor 20GB) має BLOCK — критична відмова"

# ============================================================
# M4 — unrelated unavailable volume (не бере участі) => non-blocking
# ============================================================
$m4Drives = @((New-MaintenanceDiskSpaceDrive -Drive 'D:' -AvailableGB 100), (New-MaintenanceDiskSpaceDrive -Drive 'F:' -AvailableGB 50 -IsReady $false))
$m4 = Invoke-MaintenanceSpaceCheck -RootLims 'D:\LIMS' -MinFreeSpace 20 -Drives $m4Drives
Test-BRAVOCondition `
    -Condition ($m4.Result -eq $true -and -not $m4.CriticalErrorOccurred) `
    -Name 'Maintenance/M4-UnrelatedUnavailableVolumeNonBlocking' `
    -Failure "недоступний F: (health-only, не ROOT_LIMS) не повинен блокувати Maintenance"

# ============================================================
# M5 — required target (ROOT_LIMS) unavailable => BLOCK
# ============================================================
$m5Drives = @(New-MaintenanceDiskSpaceDrive -Drive 'D:' -AvailableGB 100 -IsReady $false)
$m5 = Invoke-MaintenanceSpaceCheck -RootLims 'D:\LIMS' -MinFreeSpace 20 -Drives $m5Drives
Test-BRAVOCondition `
    -Condition ($m5.Result -eq $false -and $m5.CriticalErrorOccurred) `
    -Name 'Maintenance/M5-RequiredTargetUnavailableBlocks' `
    -Failure "недоступний ROOT_LIMS (IsReady=false) має BLOCK (AccessUnavailable)"

# ============================================================
# M7 — required volume (ROOT_LIMS) в ExcludedDrives — не рятує від BLOCK
# ============================================================
$m7Drives = @(New-MaintenanceDiskSpaceDrive -Drive 'D:' -AvailableGB 5)
$m7 = Invoke-MaintenanceSpaceCheck -RootLims 'D:\LIMS' -MinFreeSpace 20 -ExcludedDrives @('D:') -Drives $m7Drives
Test-BRAVOCondition `
    -Condition ($m7.Result -eq $false -and $m7.CriticalErrorOccurred) `
    -Name 'Maintenance/M7-RequiredVolumeInExcludedDrivesStillBlocks' `
    -Failure "ExcludedDrives не може приховати недостатність required ROOT_LIMS — має BLOCK попри виключення"

# ============================================================
# M8 — unrelated excluded volume (health-only) => suppressed, PASS
# ============================================================
$m8Drives = @((New-MaintenanceDiskSpaceDrive -Drive 'D:' -AvailableGB 100), (New-MaintenanceDiskSpaceDrive -Drive 'C:' -AvailableGB 5))
$m8 = Invoke-MaintenanceSpaceCheck -RootLims 'D:\LIMS' -MinFreeSpace 20 -ExcludedDrives @('C:') -Drives $m8Drives
Test-BRAVOCondition `
    -Condition ($m8.Result -eq $true -and -not $m8.CriticalErrorOccurred -and $m8.WarningCount -eq 0) `
    -Name 'Maintenance/M8-UnrelatedExcludedHealthVolumeSuppressed' `
    -Failure "виключений health-only C: (5GB < floor) має придушити warning повністю (ExcludedDrives застосовується до health-suppression)"

# ============================================================
# M10 — write-heavy операція, цільовий том невизначений => BLOCK
# MaintenanceTargetUndetermined (не мовчазний ALLOW, не вгаданий диск)
# ============================================================
$m10 = Invoke-MaintenanceSpaceCheck -RootLims '' -MinFreeSpace 20 -Drives @(New-MaintenanceDiskSpaceDrive -Drive 'C:' -AvailableGB 100)
Test-BRAVOCondition `
    -Condition ($m10.Result -eq $false -and $m10.CriticalErrorOccurred) `
    -Name 'Maintenance/M10-TargetUndeterminedBlocks' `
    -Failure "порожній ROOT_LIMS (target undeterminable) має BLOCK, не мовчазний ALLOW і не вгаданий диск"

# ============================================================
# M11 — exact Maintenance requirement fits below floor (forward-looking:
# доводить існування коду §45.0 для 'MaintenanceExactOnly', хоча жодна
# поточна Maintenance-операція сьогодні не постачає exact вимогу)
# ============================================================
$m11Drives = @(New-MaintenanceDiskSpaceDrive -Drive 'D:' -AvailableGB 18)
$m11 = Invoke-BRAVODiskSpaceClassifier `
    -EntitySpecs @([pscustomobject]@{ DisplayPath = 'D:\LIMS'; Roles = @('MaintenanceWorkingVolume'); RequiresAccess = $true; RequiresFreeSpace = $true; RequirementGranularity = 'Entity'; RequiredGB = 7 }) `
    -MinimumFreeSpaceGB 20 -RequirementPolicy 'MaintenanceExactOnly' -Drives $m11Drives
Test-BRAVOCondition `
    -Condition ($m11.Success -and $m11.Results[0].Reason -eq 'BelowHealthFloorButRequirementSatisfied') `
    -Name 'Maintenance/M11-ExactRequirementBelowFloorAllows' `
    -Failure "'MaintenanceExactOnly' policy з Known/exact вимогою (7<=18, 18<floor 20) має ALLOW+WARNING BelowHealthFloorButRequirementSatisfied — доводить, що below-floor ALLOW для Maintenance існує лише для exact вимог, не для unverified estimate (на відміну від Archive, де це вимкнено взагалі рішенням reviewer #2)"

# ============================================================
# Structural: виклик-сайт Main викликає Invoke-BRAVOMaintenanceDiskSpaceCheck
# замість колишньої Check-FreeSpace.
# ============================================================
Test-BRAVOCondition `
    -Condition (
        $maintenanceScriptTextForDiskSpace.Contains('function Invoke-BRAVOMaintenanceDiskSpaceCheck') -and
        $maintenanceScriptTextForDiskSpace.Contains('$spaceCheckResult = Invoke-BRAVOMaintenanceDiskSpaceCheck') -and
        -not $maintenanceScriptTextForDiskSpace.Contains('function Check-FreeSpace')
    ) `
    -Name 'Maintenance/SpaceCheckWiredIntoMain' `
    -Failure 'Invoke-BRAVOMaintenanceDiskSpaceCheck має викликатися на виклик-сайті замість Check-FreeSpace; стара функція має бути видалена, не залишена паралельно'

# ============================================================
# Regression: Write-Log у M1-M11 має реально писати в ізольований
# $LOG_DIR/$LOG_FILE fixture, а не мовчки провалюватись у catch
# Write-BRAVOMaintenanceLogFile через невстановлений $LOG_DIR=$null
# (реальний production acceptance-інцидент на LIMS-TOP, 5.2.3-rc.1 —
# self-test PASS ховав 36 рядків "Помилка запису у файл логу:
# Cannot bind argument to parameter 'Path' because it is null.").
# Перевіряємо конкретний logging-fixture (файл на диску), не текст усієї
# консолі self-test — не крихкий тест, не забороняє інші негативні
# сценарії з очікуваними ПОМИЛКА-рядками деінде.
# ============================================================
$maintenanceDiskSpaceLogContent = if (Test-Path -LiteralPath $maintenanceDiskSpaceLogTempFile) {
    [IO.File]::ReadAllText($maintenanceDiskSpaceLogTempFile, [Text.Encoding]::UTF8)
} else { $null }
Test-BRAVOCondition `
    -Condition (
        $null -ne $maintenanceDiskSpaceLogContent -and
        $maintenanceDiskSpaceLogContent.Length -gt 0 -and
        -not $maintenanceDiskSpaceLogContent.Contains('Помилка запису у файл логу') -and
        -not $maintenanceDiskSpaceLogContent.Contains("Cannot bind argument to parameter 'Path'")
    ) `
    -Name 'Maintenance/DiskSpaceFixtureLogWritesWithoutPathError' `
    -Failure "M1-M11 мають писати в ізольований fixture-лог ($maintenanceDiskSpaceLogTempFile) без 'Помилка запису у файл логу'/null-Path — Write-BRAVOMaintenanceLogFile мусить бути екстрагована разом із Write-Log, а `$LOG_DIR/`$LOG_FILE встановлені перед викликом"
Remove-Item -LiteralPath $maintenanceDiskSpaceLogTempFile -Force -ErrorAction SilentlyContinue

# ============================================================
# Відомі обмеження цієї стадії (задокументовано, не приховано):
#   M6  — Maintenance не має health-only режиму (на відміну від Archive
#         -HealthCheckOnly), тому сценарій "no write-heavy operation active"
#         не застосовний до реальних режимів Maintenance.
#   M9  — спрощена модель (лише ROOT_LIMS як write-required ціль) не виділяє
#         окрему read-only source-роль; недоступність джерела для конкретної
#         Maintenance-операції (напр. читання MODEL для pre-restore архіву)
#         сьогодні не моделюється окремо від ROOT_LIMS.
#   R1  — RuntimeWriteUnavailable (реальна write-capability проба) не
#         додано в цій стадії: §47 вимагає повторно використати ІСНУЮЧІ
#         механізми виявлення відмови запису, а не нову probe-підсистему;
#         яка саме existing-детекція придатна для цього — окреме
#         дослідження, віднесене до Stage 4/наступного циклу.
# ============================================================
