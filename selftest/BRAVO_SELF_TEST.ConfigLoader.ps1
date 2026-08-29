# Домен-фрагмент self-test: BRAVO_CONFIG_LOADER.ps1 — Import-BravoConfiguration,
# зокрема діагностичне збагачення повідомлення про помилку виконання
# BRAVO.config (fix 2026-08-24: реальний DEV-майданчик на Windows NT
# 6.2.9200 / PowerShell 3.0 — Get-BRAVOOSSupportTier класифікує PowerShell
# <4.0 як "Unsupported" — отримав голу .NET NullReferenceException без
# жодного натяку на причину замість зрозумілого повідомлення).
#
# Реальна PowerShell 3.0-система тут не відтворюється (крихко/нереалістично
# підміняти $PSVersionTable під час прогону) — перевіряється сам механізм
# збагачення на реальному оточенні прогону (Supported на CI/dev-машинах):
# оригінальна причина помилки не губиться, і hint не з'являється там, де
# оточення й так Supported.
#
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition, $script:failures.

$configLoaderPath = Join-Path $root 'BRAVO_CONFIG_LOADER.ps1'
$configLoaderScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIG_LOADER_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($configLoaderScenarioRoot)
try {
    $syntheticConfigPath = Join-Path $configLoaderScenarioRoot 'BRAVO.config'
    # Мінімальний легітимний param(ConfigRoot)-контракт (Import-BravoConfiguration
    # компілює вміст як scriptblock і викликає з -ConfigRoot/-RuntimeRoot),
    # який одразу кидає синтетичну помилку — імітує будь-який реальний збій
    # усередині виконання BRAVO.config (незалежно від конкретної причини).
    [IO.File]::WriteAllText(
        $syntheticConfigPath,
        "param(`$ConfigRoot, `$RuntimeRoot)`nthrow 'BRAVO_SELF_TEST_SYNTHETIC_CONFIG_FAILURE'",
        (New-Object System.Text.UTF8Encoding $false)
    )

    # Окремий дочірній процес: Import-BravoConfiguration встановлює
    # $global:ScriptVersion/$global:BravoConfigurationMetadata та інший
    # глобальний стан, який небезпечно змішувати з рештою self-test-прогону
    # в тому самому процесі.
    $childOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command @"
`$ErrorActionPreference = 'Stop'
try {
    . '$configLoaderPath'
    Import-BravoConfiguration -ConfigRoot '$configLoaderScenarioRoot' -ConfigPath '$syntheticConfigPath' -RuntimeRoot '$root'
    Write-Output 'NO_ERROR_THROWN'
} catch {
    Write-Output `$_.Exception.Message
}
"@ 2>&1 | Out-String

    $configLoaderErrorMessage = [string]$childOutput

    Test-BRAVOCondition `
        -Condition $configLoaderErrorMessage.Contains('BRAVO_SELF_TEST_SYNTHETIC_CONFIG_FAILURE') `
        -Name "ConfigLoader/OriginalExceptionMessageNotLost" `
        -Failure "діагностичне збагачення повідомлення про помилку BRAVO.config не повинне губити оригінальну причину; отримано: $configLoaderErrorMessage"
    Test-BRAVOCondition `
        -Condition $configLoaderErrorMessage.Contains("Не вдалося завантажити BRAVO.config") `
        -Name "ConfigLoader/ErrorMessageContractPreserved" `
        -Failure "префікс повідомлення 'Не вдалося завантажити BRAVO.config' має зберігатися незалежно від збагачення"
    # На середовищі, де реально виконується self-test (CI/dev, Supported-tier),
    # hint про Unsupported/LegacyBestEffort зʼявлятися не повинен — це і є
    # мовчазна поведінка для Supported-оточення, яку описує коментар у коді.
    Test-BRAVOCondition `
        -Condition (
            -not $configLoaderErrorMessage.Contains('Unsupported') -and
            -not $configLoaderErrorMessage.Contains('LegacyBestEffort')
        ) `
        -Name "ConfigLoader/NoHintOnSupportedEnvironment" `
        -Failure "на Supported-оточенні (де реально виконується self-test) hint про непідтримуване середовище не повинен зʼявлятися; отримано: $configLoaderErrorMessage"
} finally {
    Remove-Item -LiteralPath $configLoaderScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- BRAVO_DRY_RUN.ps1: коли Import-BravoConfiguration провалюється (той
# самий синтетичний BRAVO.config, що й вище), Write-DryRunOutput усе одно
# має намалювати заголовок і звичайний [FAIL] запис "Dry-run/Фатальна
# помилка" — а не впасти вдруге з окремою, ще заплутанішою помилкою.
# Реальний DEV-майданчик (2026-08-24): "if ($global:ScriptVersion)" під
# Set-StrictMode 2.0 (успадкованим від dot-sourced BRAVO_CONFIG_LOADER.ps1)
# кидав VariableIsUndefined, коли конфігурація не завантажилась ДО того, як
# змінна взагалі створювалась — ховаючи первинну причину.
$dryRunPath = Join-Path $root 'BRAVO_DRY_RUN.ps1'
$dryRunScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_DRY_RUN_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($dryRunScenarioRoot)
try {
    $dryRunSyntheticConfigPath = Join-Path $dryRunScenarioRoot 'BRAVO.config'
    [IO.File]::WriteAllText(
        $dryRunSyntheticConfigPath,
        "param(`$ConfigRoot, `$RuntimeRoot)`nthrow 'BRAVO_SELF_TEST_SYNTHETIC_CONFIG_FAILURE'",
        (New-Object System.Text.UTF8Encoding $false)
    )
    $dryRunChildOutput = [string](
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $dryRunPath -ConfigPath $dryRunSyntheticConfigPath 2>&1 | Out-String
    )
    $dryRunExitCode = $LASTEXITCODE

    Test-BRAVOCondition `
        -Condition ($dryRunExitCode -eq 1) `
        -Name "ConfigLoader/DryRunFailsClosedOnConfigLoadFailure" `
        -Failure "BRAVO_DRY_RUN.ps1 з непридатним BRAVO.config має завершитись кодом 1 (звичайний FAIL-контракт dry-run), а не впасти неопрацьованим виключенням; отримано exit code $dryRunExitCode, вивід: $dryRunChildOutput"
    Test-BRAVOCondition `
        -Condition (-not $dryRunChildOutput.Contains('VariableIsUndefined')) `
        -Name "ConfigLoader/DryRunDoesNotCrashOnUnsetScriptVersion" `
        -Failure "Write-DryRunOutput не повинен падати з VariableIsUndefined, коли `$global:ScriptVersion ще не створено через провал завантаження конфігурації; отримано: $dryRunChildOutput"
} finally {
    Remove-Item -LiteralPath $dryRunScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# BRAVO.local.config (5.2.1): локальні site-overrides, що переживають
# оновлення комплекту. Кожен сценарій — ізольований дочірній
# powershell.exe (Import-BravoConfiguration змінює глобальний стан).
# ============================================================
$localCfgScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_LOCALCFG_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    [void][IO.Directory]::CreateDirectory($localCfgScenarioRoot)
    $localCfgBackupDir = Join-Path $localCfgScenarioRoot 'SITE_BACKUP'
    [void][IO.Directory]::CreateDirectory($localCfgBackupDir)
    # Герметичність (CI-провал v5.2.1-rc.7): комплектний дефолт
    # BackupRoot="" означає AUTO -> <EffectiveLIMSRoot>\ARCHIV, і на
    # машині БЕЗ інсталяції LIMS (GitHub runner) BRAVO.config кидає
    # «Не вдалося визначити BackupRoot» — сценарій без overrides
    # (FileAbsentIsNoop) залежав від середовища прогону. Запікаємо в
    # копію конфігурації явний BackupRoot (ОКРЕМИЙ від SITE_BACKUP
    # каталог: фаза-1 сценарій саме доводить, що override з
    # BRAVO.local.config перемагає явне значення з BRAVO.config).
    $localCfgDefaultBackupDir = Join-Path $localCfgScenarioRoot 'SITE_DEFAULT'
    [void][IO.Directory]::CreateDirectory($localCfgDefaultBackupDir)
    $localCfgKitConfigText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.config'))
    $localCfgBackupRootLiteralLine = '    BackupRoot    = ""'
    if (-not $localCfgKitConfigText.Contains($localCfgBackupRootLiteralLine)) {
        throw "BRAVO_SELF_TEST.ConfigLoader: у BRAVO.config не знайдено рядок '$localCfgBackupRootLiteralLine' — оновіть підготовку local-config сценаріїв під нову форму конфігурації"
    }
    [IO.File]::WriteAllText(
        (Join-Path $localCfgScenarioRoot 'BRAVO.config'),
        $localCfgKitConfigText.Replace(
            $localCfgBackupRootLiteralLine,
            "    BackupRoot    = '$($localCfgDefaultBackupDir.Replace("'", "''"))'"
        ),
        (New-Object System.Text.UTF8Encoding $false)
    )
    $localCfgOverridePath = Join-Path $localCfgScenarioRoot 'BRAVO.local.config'
    $localCfgBackupLiteral = $localCfgBackupDir.Replace("'", "''")

    # --- Фаза 1 + фаза 2 + деривації: BackupRoot протягується в archiveDirs,
    # BootRestoreMode -> Recovery.Enabled, пізній поріг BAZA, скаляр.
    [IO.File]::WriteAllText($localCfgOverridePath, (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$localCfgBackupLiteral'`r`n" +
        "    'maintenanceSettings.Restore.BootRestoreMode' = 'HoldServices'`r`n" +
        "    'backupMonitoring.SFTP.BAZA.AutoArchiveMutationThreshold' = 77`r`n" +
        "    'sftpHostTemplate' = '{0}.selftest-example.test'`r`n" +
        "}`r`n"
    ), (New-Object System.Text.UTF8Encoding $false))
    $localCfgProbe = & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (
            "Set-StrictMode -Version 2.0; " +
            "try { " +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "[void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); " +
            "'{0}|{1}|{2}|{3}|{4}' -f [string]`$global:archiveDirs.Model, " +
            "[string]`$global:maintenanceSettings.Restore.BootRestoreMode, " +
            "[string]`$global:schedulerSettings.Recovery.Enabled, " +
            "[string]`$global:backupMonitoring.SFTP.BAZA.AutoArchiveMutationThreshold, " +
            "(@(`$global:BravoConfigurationMetadata.LocalConfigOverrides).Count) " +
            "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
        ) 2>&1
    $localCfgProbeLast = ([string](@($localCfgProbe)[-1])).Trim()
    Test-BRAVOCondition `
        -Condition ($localCfgProbeLast -eq "$localCfgBackupDir\MODEL|HoldServices|True|77|4") `
        -Name "ConfigLoader/LocalOverridesApplyAcrossBothPhasesWithDerivations" `
        -Failure "BRAVO.local.config має перевизначати первинні поля ДО деривацій (BackupRoot -> archiveDirs.Model; BootRestoreMode -> Recovery.Enabled=True) і пізні leaf-поля (поріг BAZA=77), з обліком у metadata (4 ключі); отримано: '$localCfgProbeLast'"

    # --- Опечатка в dot-шляху -> помилка конфігурації (не мовчазне ігнорування).
    [IO.File]::WriteAllText($localCfgOverridePath,
        "@{ 'pathSettings.NoSuchKeyRoot.Sub' = 'x' }",
        (New-Object System.Text.UTF8Encoding $false))
    $localCfgTypoProbe = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "try { [void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); 'NO-THROW' } catch { 'THREW' }"
            ) 2>&1 | Out-String
    )
    Test-BRAVOCondition `
        -Condition ($localCfgTypoProbe.Contains('THREW') -and -not $localCfgTypoProbe.Contains('NO-THROW')) `
        -Name "ConfigLoader/LocalOverrideUnknownKeyFailsClosed" `
        -Failure "невідомий dot-шлях у BRAVO.local.config мусить давати помилку конфігурації (конфіг, що бреше, гірший за помилку); отримано: $localCfgTypoProbe"

    # --- Виконуваний код у файлі -> відхилення (data-only контракт).
    [IO.File]::WriteAllText($localCfgOverridePath,
        "@{ 'pathSettings.BackupRoot' = (Get-Date).ToString() }",
        (New-Object System.Text.UTF8Encoding $false))
    $localCfgCodeProbe = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "try { [void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); 'NO-THROW' } catch { 'THREW' }"
            ) 2>&1 | Out-String
    )
    Test-BRAVOCondition `
        -Condition ($localCfgCodeProbe.Contains('THREW') -and -not $localCfgCodeProbe.Contains('NO-THROW')) `
        -Name "ConfigLoader/LocalOverrideRejectsExecutableCode" `
        -Failure "BRAVO.local.config — data-only: файл із виконуваним кодом мусить відхилятись (CheckRestrictedLanguage); отримано: $localCfgCodeProbe"

    # --- Без файла -> штатне завантаження, metadata порожній.
    Remove-Item -LiteralPath $localCfgOverridePath -Force
    $localCfgAbsentProbe = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (
                "try { " +
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "[void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); " +
                "'OK ' + (@(`$global:BravoConfigurationMetadata.LocalConfigOverrides).Count) " +
                "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
            ) 2>&1 | Out-String
    )
    Test-BRAVOCondition `
        -Condition ($localCfgAbsentProbe.Contains('OK 0')) `
        -Name "ConfigLoader/LocalOverrideFileAbsentIsNoop" `
        -Failure "відсутній BRAVO.local.config = штатне завантаження без overrides; отримано: $localCfgAbsentProbe"
} finally {
    Remove-Item -LiteralPath $localCfgScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# schedulerSettings.Health.BusyWaitMinutes (5.2.1): loader-нормалізація
# ліміту очікування зайнятої архівації перед відкладенням health-прогону.
# Кожен сценарій — ізольований дочірній powershell.exe (Import-BravoConfiguration
# змінює глобальний стан); конфіг герметизовано явним BackupRoot (та сама
# CI-пастка, що й у local-config сценаріях вище).
# ============================================================
$busyWaitScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_BUSYWAIT_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    [void][IO.Directory]::CreateDirectory($busyWaitScenarioRoot)
    $busyWaitBackupDir = Join-Path $busyWaitScenarioRoot 'SITE_DEFAULT'
    [void][IO.Directory]::CreateDirectory($busyWaitBackupDir)
    $busyWaitKitText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.config'))
    $busyWaitBackupRootLine = '    BackupRoot    = ""'
    $busyWaitKeyLine = '        BusyWaitMinutes = 60'
    foreach ($busyWaitRequiredLine in @($busyWaitBackupRootLine, $busyWaitKeyLine)) {
        if (-not $busyWaitKitText.Contains($busyWaitRequiredLine)) {
            throw "BRAVO_SELF_TEST.ConfigLoader: у BRAVO.config не знайдено рядок '$busyWaitRequiredLine' — оновіть підготовку BusyWaitMinutes-сценаріїв під нову форму конфігурації"
        }
    }
    $busyWaitHermeticText = $busyWaitKitText.Replace(
        $busyWaitBackupRootLine,
        "    BackupRoot    = '$($busyWaitBackupDir.Replace("'", "''"))'"
    )
    $busyWaitProbeCommand = (
        "try { " +
        "Set-StrictMode -Version 2.0; " +
        ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
        "[void](Import-BravoConfiguration -ConfigRoot '$busyWaitScenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
        "'VALUE=' + [string]`$global:schedulerSettings.Health.BusyWaitMinutes " +
        "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
    )
    $busyWaitCases = @(
        @{
            Name = 'ConfigLoader/HealthBusyWaitLegacyConfigGetsCanonicalDefault'
            ConfigText = $busyWaitHermeticText.Replace("$busyWaitKeyLine`r`n", '')
            Expected = 'VALUE=60'
            Failure = 'legacy-конфіг без schedulerSettings.Health.BusyWaitMinutes мусить отримувати канонічний loader-дефолт 60 (компат-нормалізація, без Warning)'
        },
        @{
            Name = 'ConfigLoader/HealthBusyWaitExplicitZeroIsPreserved'
            ConfigText = $busyWaitHermeticText.Replace($busyWaitKeyLine, '        BusyWaitMinutes = 0')
            Expected = 'VALUE=0'
            Failure = 'явний BusyWaitMinutes = 0 (стара поведінка: негайне відкладення) мусить зберігатись, а не затиратись дефолтом'
        },
        @{
            Name = 'ConfigLoader/HealthBusyWaitInvalidValueFallsBackToDefault'
            ConfigText = $busyWaitHermeticText.Replace($busyWaitKeyLine, "        BusyWaitMinutes = 'abc'")
            Expected = 'VALUE=60'
            Failure = "нечислове/поза-діапазонне BusyWaitMinutes мусить нормалізуватись до канонічних 60 хв (з Warning), а не протікати в runtime як рядок"
        }
    )
    foreach ($busyWaitCase in $busyWaitCases) {
        [IO.File]::WriteAllText(
            (Join-Path $busyWaitScenarioRoot 'BRAVO.config'),
            [string]$busyWaitCase.ConfigText,
            (New-Object System.Text.UTF8Encoding $false)
        )
        $busyWaitProbe = [string](
            & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $busyWaitProbeCommand 2>&1 | Out-String
        )
        Test-BRAVOCondition `
            -Condition ($busyWaitProbe.Contains([string]$busyWaitCase.Expected)) `
            -Name ([string]$busyWaitCase.Name) `
            -Failure "$($busyWaitCase.Failure); отримано: $busyWaitProbe"
    }
} finally {
    Remove-Item -LiteralPath $busyWaitScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# backupMonitoring.SuccessDedupMinutes (5.2.1): loader-нормалізація вікна
# дедуплікації зелених success-звітів + деривація SuccessNotificationStatePath
# для legacy-конфігів. Той самий герметичний патерн, що й BusyWaitMinutes вище.
# ============================================================
$successDedupScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_SUCCESSDEDUP_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    [void][IO.Directory]::CreateDirectory($successDedupScenarioRoot)
    $successDedupBackupDir = Join-Path $successDedupScenarioRoot 'SITE_DEFAULT'
    [void][IO.Directory]::CreateDirectory($successDedupBackupDir)
    $successDedupKitText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.config'))
    $successDedupBackupRootLine = '    BackupRoot    = ""'
    $successDedupKeyLine = '    SuccessDedupMinutes = 1380'
    $successDedupStatePathLine = '    SuccessNotificationStatePath = Join-Path $stateRoot "BRAVO_HEALTH_SUCCESS_NOTIFICATION_STATE.json"'
    $operationalStatePathLine = '    OperationalStatePath = Join-Path $stateRoot "BRAVO_HEALTH_OPERATIONAL_STATE.json"'
    foreach ($successDedupRequiredLine in @($successDedupBackupRootLine, $successDedupKeyLine, $successDedupStatePathLine, $operationalStatePathLine)) {
        if (-not $successDedupKitText.Contains($successDedupRequiredLine)) {
            throw "BRAVO_SELF_TEST.ConfigLoader: у BRAVO.config не знайдено рядок '$successDedupRequiredLine' — оновіть підготовку SuccessDedup-сценаріїв під нову форму конфігурації"
        }
    }
    $successDedupHermeticText = $successDedupKitText.Replace(
        $successDedupBackupRootLine,
        "    BackupRoot    = '$($successDedupBackupDir.Replace("'", "''"))'"
    )
    $successDedupProbeCommand = (
        "try { " +
        "Set-StrictMode -Version 2.0; " +
        ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
        "[void](Import-BravoConfiguration -ConfigRoot '$successDedupScenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
        "'VALUE=' + [string]`$global:backupMonitoring.SuccessDedupMinutes + ';PATH=' + [string]`$global:backupMonitoring.SuccessNotificationStatePath + ';OPPATH=' + [string]`$global:backupMonitoring.OperationalStatePath " +
        "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
    )
    $successDedupCases = @(
        @{
            Name = 'ConfigLoader/HealthSuccessDedupLegacyConfigGetsCanonicalDefault'
            ConfigText = $successDedupHermeticText.Replace("$successDedupKeyLine`r`n", '').Replace("$successDedupStatePathLine`r`n", '')
            Expected = 'VALUE=1380;PATH='
            Failure = 'legacy-конфіг без backupMonitoring.SuccessDedupMinutes мусить отримувати канонічний loader-дефолт 1380 (компат-нормалізація, без Warning)'
        },
        @{
            Name = 'ConfigLoader/HealthSuccessDedupLegacyStatePathDerivedFromAlertState'
            ConfigText = $successDedupHermeticText.Replace("$successDedupKeyLine`r`n", '').Replace("$successDedupStatePathLine`r`n", '')
            Expected = 'BRAVO_HEALTH_SUCCESS_NOTIFICATION_STATE.json'
            Failure = 'legacy-конфіг без SuccessNotificationStatePath мусить отримувати шлях, деривований від каталогу AlertStatePath'
        },
        @{
            Name = 'ConfigLoader/HealthOperationalStatePathDerivedForLegacyConfig'
            ConfigText = $successDedupHermeticText.Replace("$operationalStatePathLine`r`n", '')
            Expected = 'BRAVO_HEALTH_OPERATIONAL_STATE.json'
            Failure = 'legacy-конфіг без OperationalStatePath мусить отримувати шлях операційного recovery-стану, деривований від каталогу AlertStatePath'
        },
        @{
            Name = 'ConfigLoader/HealthSuccessDedupExplicitZeroIsPreserved'
            ConfigText = $successDedupHermeticText.Replace($successDedupKeyLine, '    SuccessDedupMinutes = 0')
            Expected = 'VALUE=0;'
            Failure = 'явний SuccessDedupMinutes = 0 (дедуп вимкнено, стара поведінка) мусить зберігатись, а не затиратись дефолтом'
        },
        @{
            Name = 'ConfigLoader/HealthSuccessDedupInvalidValueFallsBackToDefault'
            ConfigText = $successDedupHermeticText.Replace($successDedupKeyLine, "    SuccessDedupMinutes = 'abc'")
            Expected = 'VALUE=1380;'
            Failure = "нечислове/поза-діапазонне SuccessDedupMinutes мусить нормалізуватись до канонічних 1380 хв (з Warning), а не протікати в runtime як рядок"
        }
    )
    foreach ($successDedupCase in $successDedupCases) {
        [IO.File]::WriteAllText(
            (Join-Path $successDedupScenarioRoot 'BRAVO.config'),
            [string]$successDedupCase.ConfigText,
            (New-Object System.Text.UTF8Encoding $false)
        )
        $successDedupProbe = [string](
            & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $successDedupProbeCommand 2>&1 | Out-String
        )
        Test-BRAVOCondition `
            -Condition ($successDedupProbe.Contains([string]$successDedupCase.Expected)) `
            -Name ([string]$successDedupCase.Name) `
            -Failure "$($successDedupCase.Failure); отримано: $successDedupProbe"
    }
} finally {
    Remove-Item -LiteralPath $successDedupScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}
