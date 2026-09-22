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
# Ізоляція VersionState (SELFTEST-SAFETY-0 v1.4): дочірній BRAVO_DRY_RUN
# читає (з -NoWrite) machine-global BRAVO_VERSION_STATE.json — сесійний
# scope робить дитину незалежною від стану хоста.
$dryRunIsolationPrevious = Enter-BRAVOSelfTestIsolationScope
try {
    $dryRunSyntheticConfigPath = Join-Path $dryRunScenarioRoot 'BRAVO.config'
    [IO.File]::WriteAllText(
        $dryRunSyntheticConfigPath,
        "param(`$ConfigRoot, `$RuntimeRoot)`nthrow 'BRAVO_SELF_TEST_SYNTHETIC_CONFIG_FAILURE'",
        (New-Object System.Text.UTF8Encoding $false)
    )
    Write-BRAVOSelfTestFixtureBanner -Label 'BRAVO_DRY_RUN.ps1 (synthetic config failure)'
    $dryRunChildOutput = [string](
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $dryRunPath -ConfigPath $dryRunSyntheticConfigPath 2>&1 | Out-String
    )
    $dryRunExitCode = $LASTEXITCODE
    Write-BRAVOSelfTestFixtureBanner -Label 'BRAVO_DRY_RUN.ps1 (synthetic config failure)' -End

    Test-BRAVOCondition `
        -Condition ($dryRunExitCode -eq 1) `
        -Name "ConfigLoader/DryRunFailsClosedOnConfigLoadFailure" `
        -Failure "BRAVO_DRY_RUN.ps1 з непридатним BRAVO.config має завершитись кодом 1 (звичайний FAIL-контракт dry-run), а не впасти неопрацьованим виключенням; отримано exit code $dryRunExitCode, вивід: $dryRunChildOutput"
    Test-BRAVOCondition `
        -Condition (-not $dryRunChildOutput.Contains('VariableIsUndefined')) `
        -Name "ConfigLoader/DryRunDoesNotCrashOnUnsetScriptVersion" `
        -Failure "Write-DryRunOutput не повинен падати з VariableIsUndefined, коли `$global:ScriptVersion ще не створено через провал завантаження конфігурації; отримано: $dryRunChildOutput"
} finally {
    Exit-BRAVOSelfTestIsolationScope -PreviousValues $dryRunIsolationPrevious
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
    $localCfgKitConfigText = (Get-BRAVOSelfTestLegacyConfigText)
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

    # --- PR #224 review, F1: вкладений (nested hashtable) Node-шлях
    # local override реально доходить до merge/global-стану ЦІЛИМ
    # loader-конвеєром (не лише unit-виклик authorization-функції).
    # bravoSettings.NotificationRouting.SUCCESS/WARNING —
    # ALLOW_WITH_VALIDATOR-листи; ДО F1 такий вкладений override
    # помилково провалювався в авторизації з
    # MissingAuthorizationPolicy/UNREGISTERED, бо реєстр — leaf-only.
    [IO.File]::WriteAllText($localCfgOverridePath, (
        "@{`r`n" +
        "    'bravoSettings.NotificationRouting' = @{`r`n" +
        "        'SUCCESS' = 'general'`r`n" +
        "        'WARNING' = 'alerts'`r`n" +
        "    }`r`n" +
        "}`r`n"
    ), (New-Object System.Text.UTF8Encoding $false))
    $localCfgNestedProbe = & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (
            "Set-StrictMode -Version 2.0; " +
            "try { " +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "[void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); " +
            "'{0}|{1}' -f [string]`$global:bravoSettings.NotificationRouting.SUCCESS, " +
            "[string]`$global:bravoSettings.NotificationRouting.WARNING " +
            "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
        ) 2>&1
    $localCfgNestedProbeLast = ([string](@($localCfgNestedProbe)[-1])).Trim()
    Test-BRAVOCondition `
        -Condition ($localCfgNestedProbeLast -eq 'general|alerts') `
        -Name "ConfigLoader/NestedNodeOverrideReachesMergeAndAppliesPerLeaf" `
        -Failure "вкладений (hashtable-значення) Node-override bravoSettings.NotificationRouting мусить пройти авторизацію по кожному дочірньому листу окремо й дійти до merge/global стану; отримано: '$localCfgNestedProbeLast'"

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

    # --- Недійсний ТИП відомого ліста -> fail-closed (#154, B2).
    # Наскрізна регресія, не лише модульна: доводить, що схема v2 реально
    # стоїть у конвеєрі завантаження, а не лише існує як бібліотека.
    # Значення синтаксично бездоганне (рядковий літерал), тому ні
    # AST-парсер B1, ні перевірка невідомих шляхів його не ловлять — це
    # ловить саме перевірка типів.
    [IO.File]::WriteAllText($localCfgOverridePath,
        "@{ 'maintenanceSettings.Limits.MinimumFreeSpaceGB' = 'not-a-number' }",
        (New-Object System.Text.UTF8Encoding $false))
    $localCfgWrongTypeProbe = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "try { [void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); 'NO-THROW' } catch { 'THREW:' + `$_.Exception.Message }"
            ) 2>&1 | Out-String
    )
    Test-BRAVOCondition `
        -Condition (
            $localCfgWrongTypeProbe.Contains('THREW:') -and
            -not $localCfgWrongTypeProbe.Contains('NO-THROW') -and
            $localCfgWrongTypeProbe.Contains('maintenanceSettings.Limits.MinimumFreeSpaceGB')
        ) `
        -Name "ConfigLoader/LocalOverrideWrongTypeFailsClosed" `
        -Failure "рядок на місці числового ліста BRAVO.local.config мусить давати fail-closed з точним dot-шляхом у повідомленні; отримано: $localCfgWrongTypeProbe"

    # --- Маркер версії: наскрізний диспетч (#154, B3).
    # Доводить рівно те, чого модульний тест довести не може: маркер
    # проходить увесь конвеєр завантаження й НЕ відхиляється як
    # невідомий top-level ключ (ним він синтаксично і є).
    [IO.File]::WriteAllText($localCfgOverridePath,
        "@{ configSchemaVersion = 2`r`n'pathSettings.BackupRoot' = '$localCfgBackupLiteral' }",
        (New-Object System.Text.UTF8Encoding $false))
    $localCfgVersionProbe = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "try { [void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
                "'RESULT:' + [string]`$global:BravoConfigurationMetadata.LocalConfigDeclaredSchemaVersion + " +
                "';' + [string]`$global:pathSettings.BackupRoot } catch { 'THREW:' + `$_.Exception.Message }"
            ) 2>&1 | Out-String
    )
    Test-BRAVOCondition `
        -Condition (
            $localCfgVersionProbe.Contains('RESULT:2;') -and
            $localCfgVersionProbe.Contains($localCfgBackupDir) -and
            -not $localCfgVersionProbe.Contains('THREW')
        ) `
        -Name "ConfigLoader/LocalOverrideDeclaredSchemaVersionLoads" `
        -Failure "оголошений configSchemaVersion = 2 мусить прийматись, потрапляти в метадані й не заважати перевизначенням; отримано: $localCfgVersionProbe"

    # --- Непідтримувана версія -> fail closed наскрізно.
    [IO.File]::WriteAllText($localCfgOverridePath,
        "@{ configSchemaVersion = 99`r`n'pathSettings.BackupRoot' = '$localCfgBackupLiteral' }",
        (New-Object System.Text.UTF8Encoding $false))
    $localCfgFutureVersionProbe = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "try { [void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); 'NO-THROW' } catch { 'THREW:' + `$_.Exception.Message }"
            ) 2>&1 | Out-String
    )
    Test-BRAVOCondition `
        -Condition (
            $localCfgFutureVersionProbe.Contains('THREW:') -and
            -not $localCfgFutureVersionProbe.Contains('NO-THROW') -and
            $localCfgFutureVersionProbe.Contains('99')
        ) `
        -Name "ConfigLoader/LocalOverrideUnsupportedSchemaVersionFailsClosed" `
        -Failure "файл новішого формату мусить fail-closed, а не читатись як старіший; отримано: $localCfgFutureVersionProbe"

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
        -Failure "BRAVO.local.config — data-only: файл із виконуваним кодом мусить відхилятись (невиконуюче вилучення літералів з AST); отримано: $localCfgCodeProbe"

    # --- Вираз, який СТАРИЙ механізм приймав і ОБЧИСЛЮВАВ -> відхилення
    # (#154, B1). Регресія саме наскрізна, а не лише модульна: доводить,
    # що canonical читач site-файлу справді перемкнено на невиконуюче
    # вилучення, а не лише що модуль-парсер існує. Обмежена мова даних
    # PowerShell приймала арифметику, і перевірений блок потім
    # викликався — значення 1 + 1 ставало 2.
    [IO.File]::WriteAllText($localCfgOverridePath,
        "@{ 'bravoSettings.NotificationRequestTimeoutSeconds' = 1 + 1 }",
        (New-Object System.Text.UTF8Encoding $false))
    $localCfgExpressionProbe = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "try { [void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); 'NO-THROW' } catch { 'THREW' }"
            ) 2>&1 | Out-String
    )
    Test-BRAVOCondition `
        -Condition ($localCfgExpressionProbe.Contains('THREW') -and -not $localCfgExpressionProbe.Contains('NO-THROW')) `
        -Name "ConfigLoader/LocalOverrideRejectsEvaluatedExpression" `
        -Failure "вираз у значенні BRAVO.local.config мусить відхилятись, а не обчислюватись (файл є ДАНИМИ); отримано: $localCfgExpressionProbe"

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
    $busyWaitKitText = (Get-BRAVOSelfTestLegacyConfigText)
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
    $successDedupKitText = (Get-BRAVOSelfTestLegacyConfigText)
    $successDedupBackupRootLine = '    BackupRoot    = ""'
    $successDedupKeyLine = '    SuccessDedupMinutes = 1380'
    # P0 Configuration Foundation (PR B): SuccessNotificationStatePath і
    # OperationalStatePath більше не raw-літерали в BRAVO.config — це
    # безумовно похідні поля, які тепер завжди обчислює
    # Resolve-BRAVOConfigurationDerivation (modules/BRAVO.Configuration/
    # BRAVO.Configuration.Derivation.psm1), а не сам BRAVO.config. Форма
    # рядків тепер інша ($global:backupMonitoring.X = ..., без 4-
    # пробільного raw-hashtable відступу) — і, оскільки поле обчислюється
    # безумовно (не за raw-ключем), .Replace(...) на цих двох рядках у
    # $successDedupHermeticText нижче — навмисний no-op (більше нема що
    # прибирати з BRAVO.config): деривація й так виробляє шлях незалежно
    # від вмісту raw-конфігу, тому "legacy" і "поточний" сценарії для цих
    # двох конкретних полів тепер еквівалентні.
    $successDedupStatePathLine = '    SuccessNotificationStatePath = Join-Path $stateRoot "BRAVO_HEALTH_SUCCESS_NOTIFICATION_STATE.json"'
    $operationalStatePathLine = '    OperationalStatePath = Join-Path $stateRoot "BRAVO_HEALTH_OPERATIONAL_STATE.json"'
    $successDedupDerivationText = [IO.File]::ReadAllText(
        (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Derivation.psm1'))
    foreach ($successDedupRequiredLine in @($successDedupBackupRootLine, $successDedupKeyLine)) {
        if (-not $successDedupKitText.Contains($successDedupRequiredLine)) {
            throw "BRAVO_SELF_TEST.ConfigLoader: у BRAVO.config не знайдено рядок '$successDedupRequiredLine' — оновіть підготовку SuccessDedup-сценаріїв під нову форму конфігурації"
        }
    }
    foreach ($successDedupDerivedLine in @(
        '$global:backupMonitoring.SuccessNotificationStatePath = Join-Path $stateRoot "BRAVO_HEALTH_SUCCESS_NOTIFICATION_STATE.json"',
        '$global:backupMonitoring.OperationalStatePath = Join-Path $stateRoot "BRAVO_HEALTH_OPERATIONAL_STATE.json"'
    )) {
        if (-not $successDedupDerivationText.Contains($successDedupDerivedLine)) {
            throw "BRAVO_SELF_TEST.ConfigLoader: у BRAVO.Configuration.Derivation.psm1 не знайдено рядок '$successDedupDerivedLine' — оновіть підготовку SuccessDedup-сценаріїв під нову форму деривації"
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
# ============================================================
# componentSettings.SFTP.Enabled / SMB.Enabled (5.2.2): глобальні
# master-вимикачі зовнішніх сховищ. Loader-нормалізація (відсутній ключ =
# $true), strict-bool валідація (не-bool = канонічна помилка), raw vs
# effective розділення і узгодження bazaSyncEffective/BAZASync.
# Кожен сценарій — ізольований дочірній powershell.exe.
# ============================================================
$storageSwitchScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_STORAGESW_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    [void][IO.Directory]::CreateDirectory($storageSwitchScenarioRoot)
    $storageSwitchBackupDir = Join-Path $storageSwitchScenarioRoot 'SITE_DEFAULT'
    [void][IO.Directory]::CreateDirectory($storageSwitchBackupDir)
    $storageSwitchKitText = (Get-BRAVOSelfTestLegacyConfigText)
    $storageSwitchBackupRootLine = '    BackupRoot    = ""'
    # Префікс без закриваючої дужки: блок SFTP у committed BRAVO.config
    # тепер містить додаткові opt-in ключі (MaintenanceLogUploadEnabled/
    # ArchiveLogUploadEnabled, log-lifecycle P1) — заміни нижче
    # модифікують лише рядки Enabled/ArchiveUpload, лишаючи хвіст блоку
    # (коментарі + нові тумблери + дужку) недоторканим.
    $storageSwitchSftpBlock = "    SFTP = @{`r`n        Enabled = `$true`r`n        ArchiveUpload = `$true"
    $storageSwitchSmbBlock = "    SMB = @{`r`n        Enabled = `$true"
    foreach ($storageSwitchRequiredLine in @($storageSwitchBackupRootLine, $storageSwitchSftpBlock, $storageSwitchSmbBlock)) {
        if (-not $storageSwitchKitText.Contains($storageSwitchRequiredLine)) {
            throw "BRAVO_SELF_TEST.ConfigLoader: у BRAVO.config не знайдено фрагмент '$storageSwitchRequiredLine' — оновіть підготовку storage-switch сценаріїв під нову форму конфігурації"
        }
    }
    $storageSwitchHermeticText = $storageSwitchKitText.Replace(
        $storageSwitchBackupRootLine,
        "    BackupRoot    = '$($storageSwitchBackupDir.Replace("'", "''"))'"
    )
    # Probe: effective-значення, raw-збереження і узгодження деривацій в
    # одному рядку — щоб кожен кейс перевірявся атомарно.
    $storageSwitchProbeCommand = (
        "try { " +
        "Set-StrictMode -Version 2.0; " +
        ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
        "[void](Import-BravoConfiguration -ConfigRoot '$storageSwitchScenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
        "'SFTPEN=' + [string]`$global:storageEffective.SFTP.Enabled + " +
        "';SFTPUP=' + [string]`$global:storageEffective.SFTP.ArchiveUpload + " +
        "';SMBEN=' + [string]`$global:storageEffective.SMB.Enabled + " +
        "';SMBCP=' + [string]`$global:storageEffective.SMB.ArchiveCopy + " +
        "';RAWUP=' + [string]`$global:componentSettings.SFTP.ArchiveUpload + " +
        "';SCHED=' + [string]`$global:schedulerSettings.BAZASync.Enabled + " +
        "';REQ=' + [string]`$global:bazaSyncEffective.ScheduledSftpSyncRequired + " +
        "';MLUP=' + [string]`$global:componentSettings.SFTP.MaintenanceLogUploadEnabled + " +
        "';ALUP=' + [string]`$global:componentSettings.SFTP.ArchiveLogUploadEnabled + " +
        "';MLDIR=' + [string]`$global:sftpDirectories.MaintenanceLog + " +
        "';ALDIR=' + [string]`$global:sftpDirectories.ArchivLog + " +
        "';GRACE=' + [string]`$global:maintenanceSettings.Retention.RawSourceGraceDays " +
        "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
    )
    $storageSwitchCases = @(
        @{
            Name = 'ConfigLoader/StorageSwitchLegacyConfigDefaultsToEnabled'
            ConfigText = $storageSwitchHermeticText.Replace("        Enabled = `$true`r`n", '')
            LocalOverride = $null
            Expected = 'SFTPEN=True;SFTPUP=True;SMBEN=True'
            Failure = 'legacy-конфіг без componentSettings.SFTP.Enabled/SMB.Enabled мусить трактуватись як увімкнений (поведінка 5.2.1 зберігається)'
        },
        @{
            Name = 'ConfigLoader/StorageSwitchSftpDisabledKeepsRawChildAndDropsEffective'
            ConfigText = $storageSwitchHermeticText.Replace(
                $storageSwitchSftpBlock,
                "    SFTP = @{`r`n        Enabled = `$false`r`n        ArchiveUpload = `$true"
            )
            LocalOverride = $null
            Expected = 'SFTPEN=False;SFTPUP=False;SMBEN=True;SMBCP=False;RAWUP=True;SCHED=False;REQ=False'
            Failure = 'SFTP.Enabled=$false мусить занулити effective ArchiveUpload/BAZASync (SCHED/REQ=False), зберігши raw ArchiveUpload=$true; SMB незалежний'
        },
        @{
            Name = 'ConfigLoader/StorageSwitchInvalidValueIsCanonicalConfigError'
            ConfigText = $storageSwitchHermeticText.Replace(
                $storageSwitchSftpBlock,
                "    SFTP = @{`r`n        Enabled = 'yes'`r`n        ArchiveUpload = `$true"
            )
            LocalOverride = $null
            Expected = 'CHILD-ERROR:'
            ExpectedAlso = 'componentSettings.SFTP.Enabled'
            Failure = "не-bool значення Enabled мусить давати канонічну помилку конфігурації (fail-closed), а не тихе приведення"
        },
        @{
            Name = 'ConfigLoader/StorageSwitchLocalOverrideDisablesBothPhase1'
            ConfigText = $storageSwitchHermeticText
            LocalOverride = (
                "@{`r`n" +
                "    'componentSettings.SFTP.Enabled' = `$false`r`n" +
                "    'componentSettings.SMB.Enabled' = `$false`r`n" +
                "}`r`n"
            )
            Expected = 'SFTPEN=False;SFTPUP=False;SMBEN=False;SMBCP=False;RAWUP=True;SCHED=False;REQ=False'
            Failure = 'BRAVO.local.config override обох master-вимикачів (фаза 1, до деривацій) мусить давати local-only режим без зміни raw-прапорців'
        },
        @{
            Name = 'ConfigLoader/StorageSwitchReEnableRestoresEffectiveState'
            ConfigText = $storageSwitchHermeticText
            LocalOverride = $null
            Expected = 'SFTPEN=True;SFTPUP=True;SMBEN=True;SMBCP=False;RAWUP=True;SCHED=True;REQ=True'
            Failure = 'повернення Enabled=$true (комплектний дефолт) мусить відновлювати effective-поведінку 5.2.1 без ручної зміни дочірніх прапорців'
        },
        @{
            # Log-lifecycle P1: конфіг, що передує ключам вивантаження
            # власних логів (тумблери + каталоги видалені) — loader мусить
            # нормалізувати тумблери в $false (opt-in, жодних нових
            # мережевих операцій мовчки) і каталоги в канонічні дефолти.
            Name = 'ConfigLoader/OwnLogUploadLegacyConfigDefaultsToDisabled'
            ConfigText = ($storageSwitchHermeticText `
                -replace '(?m)^[ \t]+MaintenanceLogUploadEnabled = .*\r?\n', '' `
                -replace '(?m)^[ \t]+ArchiveLogUploadEnabled = .*\r?\n', '' `
                -replace '(?m)^[ \t]+MaintenanceLog = .*\r?\n', '' `
                -replace '(?m)^[ \t]+ArchivLog = .*\r?\n', '')
            LocalOverride = $null
            Expected = 'MLUP=False;ALUP=False;MLDIR=logs/maintenance;ALDIR=logs/archiv'
            Failure = 'legacy-конфіг без ключів вивантаження власних логів мусить давати вимкнені тумблери (opt-in) і канонічні дефолт-каталоги'
        },
        @{
            # Некоректне значення тумблера деградує до безпечного $false
            # (телеметрію пропускаємо), а НЕ вмикає нову SFTP-поведінку і
            # НЕ валить конфігурацію (на відміну від master-Enabled вище).
            Name = 'ConfigLoader/OwnLogUploadInvalidValueDegradesToDisabled'
            ConfigText = $storageSwitchHermeticText.Replace(
                "        MaintenanceLogUploadEnabled = `$false",
                "        MaintenanceLogUploadEnabled = 'yes'"
            )
            LocalOverride = $null
            Expected = 'MLUP=False;ALUP=False'
            Failure = "не-bool значення MaintenanceLogUploadEnabled мусить деградувати до `$false з попередженням, без помилки конфігурації"
        },
        @{
            # Log-lifecycle P5: некоректне значення grace-періоду сирих
            # джерел деградує до безпечного 0 (негайне видалення після
            # успішної архівації = точна попередня поведінка), а не валить
            # конфігурацію і не лишає сміттєве значення під StrictMode.
            Name = 'ConfigLoader/RawSourceGraceDaysInvalidValueDegradesToZero'
            ConfigText = $storageSwitchHermeticText.Replace(
                "        RawSourceGraceDays = 0",
                "        RawSourceGraceDays = 'abc'"
            )
            LocalOverride = $null
            Expected = 'GRACE=0'
            Failure = "некоректне RawSourceGraceDays мусить деградувати до 0 з попередженням (безпечний дефолт = попередня поведінка)"
        }
    )
    $storageSwitchLocalConfigPath = Join-Path $storageSwitchScenarioRoot 'BRAVO.local.config'
    foreach ($storageSwitchCase in $storageSwitchCases) {
        [IO.File]::WriteAllText(
            (Join-Path $storageSwitchScenarioRoot 'BRAVO.config'),
            [string]$storageSwitchCase.ConfigText,
            (New-Object System.Text.UTF8Encoding $false)
        )
        if ($null -ne $storageSwitchCase.LocalOverride) {
            [IO.File]::WriteAllText($storageSwitchLocalConfigPath, [string]$storageSwitchCase.LocalOverride, (New-Object System.Text.UTF8Encoding $false))
        } elseif (Test-Path -LiteralPath $storageSwitchLocalConfigPath) {
            Remove-Item -LiteralPath $storageSwitchLocalConfigPath -Force
        }
        $storageSwitchProbe = [string](
            & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $storageSwitchProbeCommand 2>&1 | Out-String
        )
        $storageSwitchMatched = $storageSwitchProbe.Contains([string]$storageSwitchCase.Expected)
        if ($storageSwitchMatched -and $storageSwitchCase.Contains('ExpectedAlso')) {
            $storageSwitchMatched = $storageSwitchProbe.Contains([string]$storageSwitchCase.ExpectedAlso)
        }
        Test-BRAVOCondition `
            -Condition $storageSwitchMatched `
            -Name ([string]$storageSwitchCase.Name) `
            -Failure "$($storageSwitchCase.Failure); отримано: $storageSwitchProbe"
    }
} finally {
    Remove-Item -LiteralPath $storageSwitchScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# P0 Configuration Foundation (PR C): BRAVO.config став опційним основним
# override-шаром. Import-BravoSyntheticConfiguration (canonical defaults +
# Resolve-BRAVORawConfiguration + Resolve-BRAVOConfigurationDerivation) —
# той самий derivation-резолвер, що й legacy-шлях, без BRAVO.config-файлу.
# Кожен сценарій — ізольований дочірній powershell.exe; BackupRoot
# передається через BRAVO.local.config (герметичність на машині без LIMS,
# той самий патерн, що й у сценаріях вище).
# ============================================================
$noConfigScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_NOCONFIG_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    [void][IO.Directory]::CreateDirectory($noConfigScenarioRoot)
    $noConfigBackupDir = Join-Path $noConfigScenarioRoot 'SITE_DEFAULT'
    [void][IO.Directory]::CreateDirectory($noConfigBackupDir)
    $noConfigBackupLiteral = $noConfigBackupDir.Replace("'", "''")
    $noConfigLocalOverridePath = Join-Path $noConfigScenarioRoot 'BRAVO.local.config'
    [IO.File]::WriteAllText($noConfigLocalOverridePath, (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$noConfigBackupLiteral'`r`n" +
        "}`r`n"
    ), (New-Object System.Text.UTF8Encoding $false))

    # --- Немає BRAVO.config за auto-derived шляхом -> НЕ помилка: canonical
    # дефолти + BRAVO.local.config, Format=synthetic-no-config. Регресія для
    # двох дірок, знайдених живим тестуванням реального entrypoint-а:
    # credentialSettings.HelperPath/SetupScriptPath і
    # maintenanceSettings.General.ObjectName/ArchivePrefix обчислювались
    # inline в raw-блоці BRAVO.config ДО появи derivation-резолвера й були
    # пропущені під час PR B екстракції.
    $noConfigProbeCommand = (
        "try { " +
        "Set-StrictMode -Version 2.0; " +
        ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
        "[void](Import-BravoConfiguration -ConfigRoot '$noConfigScenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
        "'FORMAT=' + [string]`$global:BravoConfigurationMetadata.Format + " +
        "';INST=' + [string]`$global:bravoSettings.InstitutionName + " +
        "';HELPER=' + [string]`$global:credentialSettings.HelperPath + " +
        "';SETUP=' + [string]`$global:credentialSettings.SetupScriptPath + " +
        "';OBJNAME=' + [string]`$global:maintenanceSettings.General.ObjectName + " +
        "';ARCHPFX=' + [string]`$global:maintenanceSettings.General.ArchivePrefix + " +
        "';LOCKPATH=' + [string]`$global:operationLockSettings.Path " +
        "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
    )
    # Захоплення виводу дочірнього процесу з кирилицею (InstitutionName/
    # ObjectName) потребує явного UTF-8 OutputEncoding — інакше системна
    # кодова сторінка ламає багатобайтові послідовності (той самий
    # відомий пастка, що й у local-only SFTP/SMB сценарії BRAVO_SELF_TEST.ps1).
    $noConfigPreviousOutputEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $noConfigProbe = [string](
            & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $noConfigProbeCommand 2>&1 | Out-String
        )
    } finally {
        [Console]::OutputEncoding = $noConfigPreviousOutputEncoding
    }
    Test-BRAVOCondition `
        -Condition $noConfigProbe.Contains('FORMAT=synthetic-no-config') `
        -Name "ConfigLoader/NoConfigAutoDerivedPathSucceedsAsSynthetic" `
        -Failure "auto-derived шлях (ConfigRoot\BRAVO.config), що не існує, мусить завантажуватись як synthetic-no-config, а не кидати помилку; отримано: $noConfigProbe"
    Test-BRAVOCondition `
        -Condition $noConfigProbe.Contains('INST=УСТАНОВА') `
        -Name "ConfigLoader/NoConfigCanonicalDefaultsApplied" `
        -Failure "synthetic-шлях мусить давати canonical дефолт bravoSettings.InstitutionName з Get-BRAVODefaultConfiguration; отримано: $noConfigProbe"
    Test-BRAVOCondition `
        -Condition (
            $noConfigProbe.Contains('HELPER=') -and -not $noConfigProbe.Contains('HELPER=;') -and
            $noConfigProbe.Contains('BRAVO.Credentials.psd1')
        ) `
        -Name "ConfigLoader/NoConfigCredentialSettingsHelperPathDerived" `
        -Failure "synthetic-шлях мусить обчислювати credentialSettings.HelperPath (раніше — StrictMode-крах у реальному entrypoint-і); отримано: $noConfigProbe"
    Test-BRAVOCondition `
        -Condition (
            $noConfigProbe.Contains('SETUP=') -and
            $noConfigProbe.Contains('BRAVO_CREDENTIALS_SETUP.ps1')
        ) `
        -Name "ConfigLoader/NoConfigCredentialSettingsSetupScriptPathDerived" `
        -Failure "synthetic-шлях мусить обчислювати credentialSettings.SetupScriptPath; отримано: $noConfigProbe"
    Test-BRAVOCondition `
        -Condition $noConfigProbe.Contains('OBJNAME=УСТАНОВА [00000000]') `
        -Name "ConfigLoader/NoConfigMaintenanceGeneralObjectNameDerived" `
        -Failure "synthetic-шлях мусить обчислювати maintenanceSettings.General.ObjectName з canonical bravoSettings; отримано: $noConfigProbe"
    Test-BRAVOCondition `
        -Condition $noConfigProbe.Contains('ARCHPFX=lab_v2412') `
        -Name "ConfigLoader/NoConfigMaintenanceGeneralArchivePrefixDerived" `
        -Failure "synthetic-шлях мусить обчислювати maintenanceSettings.General.ArchivePrefix з canonical bravoSettings; отримано: $noConfigProbe"
    Test-BRAVOCondition `
        -Condition $noConfigProbe.Contains('BRAVO_OPERATION.lock') `
        -Name "ConfigLoader/NoConfigOperationLockSettingsDerived" `
        -Failure "synthetic-шлях мусить обчислювати operationLockSettings.Path так само, як legacy-шлях; отримано: $noConfigProbe"

    # --- Явний -ConfigPath на неіснуючий файл лишається помилкою (свідомий
    # намір != auto-похідна відсутність). -ConfigPathWasExplicit тепер
    # ЄДИНЕ джерело правди (Секція 2 PR C) — caller (тут: сам probe,
    # симулюючи справжній entrypoint) обчислює намір зі свого власного
    # $PSBoundParameters і передає його явно; loader більше НЕ вгадує
    # намір за збігом/відмінністю шляху.
    $noConfigExplicitMissingPath = Join-Path $noConfigScenarioRoot 'BRAVO_EXPLICIT_MISSING.config'
    $noConfigExplicitProbeCommand = (
        "try { " +
        ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
        "[void](Import-BravoConfiguration -ConfigRoot '$noConfigScenarioRoot' -ConfigPath '$noConfigExplicitMissingPath' -RuntimeRoot '$root' -ConfigPathWasExplicit 3>`$null); " +
        "'NO-THROW'" +
        "} catch { 'THREW: ' + `$_.Exception.Message }"
    )
    $noConfigExplicitProbe = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $noConfigExplicitProbeCommand 2>&1 | Out-String
    )
    Test-BRAVOCondition `
        -Condition ($noConfigExplicitProbe.Contains('THREW:') -and -not $noConfigExplicitProbe.Contains('NO-THROW')) `
        -Name "ConfigLoader/NoConfigExplicitMissingConfigPathStillThrows" `
        -Failure "явно вказаний -ConfigPath на неіснуючий файл мусить лишатись помилкою конфігурації навіть після появи no-config шляху; отримано: $noConfigExplicitProbe"

    # ============================================================
    # P0 Configuration Foundation (PR C, Секція 2): повна регресійна
    # матриця explicit-vs-auto intent — включно з Test 5, що ловить
    # дефект СТАРОЇ (незакомiченої) евристики "resolved == auto-derived":
    # оператор, що явно набрав РІВНО той самий шлях, який auto-derivation
    # синтезувала б сама, все одно мав намір "цей файл МУСИТЬ існувати".
    # -ConfigPathWasExplicit — незалежний від значення шляху прапорець.
    # ============================================================
    $intentMatrixExternalRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_INTENTMATRIX_EXTERNAL_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($intentMatrixExternalRoot)
        $intentMatrixExternalConfigPath = Join-Path $intentMatrixExternalRoot 'CUSTOM_SITE1.config'
        # Мінімальний легітимний BRAVO.config: лише BackupRoot (герметичність,
        # той самий CI-пастка коментар, що й у сценаріях вище) — решта з
        # canonical defaults через $global:bravoSettings/... блоки-заглушки
        # реального BRAVO.config тут не потрібні, оскільки цей probe лише
        # перевіряє факт PASS/ERROR завантаження, не effective-значення.
        $intentMatrixKitText = (Get-BRAVOSelfTestLegacyConfigText)
        $intentMatrixBackupDir = Join-Path $intentMatrixExternalRoot 'SITE_BACKUP'
        [void][IO.Directory]::CreateDirectory($intentMatrixBackupDir)
        $intentMatrixBackupRootLine = '    BackupRoot    = ""'
        if (-not $intentMatrixKitText.Contains($intentMatrixBackupRootLine)) {
            throw "BRAVO_SELF_TEST.ConfigLoader: у BRAVO.config не знайдено рядок '$intentMatrixBackupRootLine' — оновіть підготовку intent-matrix сценаріїв під нову форму конфігурації"
        }
        [IO.File]::WriteAllText(
            $intentMatrixExternalConfigPath,
            $intentMatrixKitText.Replace(
                $intentMatrixBackupRootLine,
                "    BackupRoot    = '$($intentMatrixBackupDir.Replace("'", "''"))'"
            ),
            (New-Object System.Text.UTF8Encoding $false)
        )
        $intentMatrixDefaultCandidatePath = Join-Path $noConfigScenarioRoot 'BRAVO.config'

        $intentMatrixCases = @(
            @{
                Name = 'ConfigLoader/IntentMatrix2ExplicitExternalExistingPasses'
                ConfigRoot = $intentMatrixExternalRoot
                ConfigPathArg = $intentMatrixExternalConfigPath
                Explicit = $true
                ExpectThrow = $false
                Failure = 'Test 2: explicit external existing -> PASS'
            },
            @{
                Name = 'ConfigLoader/IntentMatrix3ExplicitExternalMissingErrors'
                ConfigRoot = $intentMatrixExternalRoot
                ConfigPathArg = (Join-Path $intentMatrixExternalRoot 'MISSING_SITE.config')
                Explicit = $true
                ExpectThrow = $true
                Failure = 'Test 3: explicit external missing -> ERROR'
            },
            @{
                Name = 'ConfigLoader/IntentMatrix4ExplicitDefaultCandidateExistingPasses'
                ConfigRoot = $noConfigScenarioRoot
                ConfigPathArg = $intentMatrixDefaultCandidatePath
                Explicit = $true
                ExpectThrow = $false
                # Потребує реального BRAVO.config за default-шляхом у
                # noConfigScenarioRoot — записується лише на час цього case.
                RequiresDefaultCandidateFile = $true
                Failure = 'Test 4: explicit default-candidate existing -> PASS'
            },
            @{
                Name = 'ConfigLoader/IntentMatrix5ExplicitDefaultCandidateMissingErrors'
                ConfigRoot = $noConfigScenarioRoot
                ConfigPathArg = $intentMatrixDefaultCandidatePath
                Explicit = $true
                ExpectThrow = $true
                Failure = 'Test 5 (КРИТИЧНИЙ — ловить дефект path-equality евристики): explicit шлях, що ТЕКСТОВО збігається з auto-похідним default-candidate, але фізично відсутній -> ERROR, не тихий no-config fallback'
            },
            @{
                Name = 'ConfigLoader/IntentMatrix6WhitespaceConfigPathIsNotOperatorIntent'
                ConfigRoot = $noConfigScenarioRoot
                ConfigPathArg = '   '
                Explicit = $true
                ExpectThrow = $false
                Failure = 'Test 6: -ConfigPathWasExplicit разом із null/whitespace -ConfigPath не є свідомим наміром -> AUTO (canonical дефолти), не помилка'
            }
        )
        foreach ($intentMatrixCase in $intentMatrixCases) {
            if ($intentMatrixCase.Contains('RequiresDefaultCandidateFile') -and $intentMatrixCase.RequiresDefaultCandidateFile) {
                [IO.File]::Copy($intentMatrixExternalConfigPath, $intentMatrixDefaultCandidatePath, $true)
            } elseif (Test-Path -LiteralPath $intentMatrixDefaultCandidatePath -PathType Leaf) {
                Remove-Item -LiteralPath $intentMatrixDefaultCandidatePath -Force
            }
            $intentMatrixExplicitArg = if ($intentMatrixCase.Explicit) { '-ConfigPathWasExplicit' } else { '' }
            $intentMatrixProbeCommand = (
                "try { " +
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "[void](Import-BravoConfiguration -ConfigRoot '$($intentMatrixCase.ConfigRoot)' -ConfigPath '$($intentMatrixCase.ConfigPathArg)' -RuntimeRoot '$root' $intentMatrixExplicitArg 3>`$null); " +
                "'NO-THROW'" +
                "} catch { 'THREW' }"
            )
            $intentMatrixProbe = [string](
                & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $intentMatrixProbeCommand 2>&1 | Out-String
            )
            $intentMatrixThrew = $intentMatrixProbe.Contains('THREW') -and -not $intentMatrixProbe.Contains('NO-THROW')
            Test-BRAVOCondition `
                -Condition ($intentMatrixThrew -eq [bool]$intentMatrixCase.ExpectThrow) `
                -Name ([string]$intentMatrixCase.Name) `
                -Failure "$($intentMatrixCase.Failure); очікувалось ExpectThrow=$($intentMatrixCase.ExpectThrow), отримано THREW=$intentMatrixThrew, вивід: $intentMatrixProbe"
        }
        if (Test-Path -LiteralPath $intentMatrixDefaultCandidatePath -PathType Leaf) {
            Remove-Item -LiteralPath $intentMatrixDefaultCandidatePath -Force
        }
    } finally {
        Remove-Item -LiteralPath $intentMatrixExternalRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- Невідомий dot-шлях у BRAVO.local.config у no-config режимі так
    # само fail-closed, як і в legacy-шляху (Resolve-BRAVORawConfiguration
    # через ConvertTo-BRAVONestedOverride кидає на невідомому top-level
    # ключі одним проходом до злиття).
    [IO.File]::WriteAllText($noConfigLocalOverridePath, (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$noConfigBackupLiteral'`r`n" +
        "    'noSuchTopLevelKey.Sub' = 'x'`r`n" +
        "}`r`n"
    ), (New-Object System.Text.UTF8Encoding $false))
    $noConfigTypoProbeCommand = (
        "try { " +
        ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
        "[void](Import-BravoConfiguration -ConfigRoot '$noConfigScenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
        "'NO-THROW'" +
        "} catch { 'THREW'" +
        " }"
    )
    $noConfigTypoProbe = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $noConfigTypoProbeCommand 2>&1 | Out-String
    )
    Test-BRAVOCondition `
        -Condition ($noConfigTypoProbe.Contains('THREW') -and -not $noConfigTypoProbe.Contains('NO-THROW')) `
        -Name "ConfigLoader/NoConfigLocalOverrideUnknownKeyFailsClosed" `
        -Failure "невідомий top-level dot-шлях у BRAVO.local.config за no-config шляху мусить fail-closed так само, як legacy-шлях; отримано: $noConfigTypoProbe"
} finally {
    Remove-Item -LiteralPath $noConfigScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# P0 Configuration Foundation (PR C, Секція 4): МЕХАНІЧНИЙ parity-тест —
# ОДИН і той самий BRAVO.local.config має давати ОДНАКОВИЙ accept/reject
# результат і ОДНАКОВЕ ефективне raw-значення незалежно від того, чи
# присутній BRAVO.config (legacy primary), чи ні (synthetic). До Секції 3
# config-present-шлях ішов через окремий, м'якший
# Invoke-BRAVOLocalConfigurationOverridePhase (дозволяв НОВИЙ leaf у ВЖЕ
# існуючому hashtable-вузлі), а config-absent — одразу через строгіший
# ConvertTo-BRAVONestedOverride (вимагав, щоб і сам leaf уже існував у
# Get-BRAVODefaultConfiguration) — те саме BRAVO.local.config давало
# різний результат залежно від шляху (задокументований дефект, знайдений
# на review). Тепер обидва шляхи йдуть через ОДИН
# Complete-BRAVOConfigurationLoad -> ConvertTo-BRAVONestedOverride виклик
# з ОДНИМ контрактом (батьківські сегменти мають існувати; для
# багатосегментних шляхів сам leaf форвард-сумісно НЕ мусить вже
# існувати) — цей тест доводить збіг результату механічно на РЕАЛЬНОМУ
# loader-виклику для обох шляхів, а не як припущення з архітектури.
# ============================================================
$parityBackupRootDir = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_PARITY_BACKUP_{0}" -f [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($parityBackupRootDir)
$parityBackupRootLiteral = $parityBackupRootDir.Replace("'", "''")

function New-BRAVOConfigLoaderParityProbe {
    param(
        [Parameter(Mandatory = $true)][bool]$WithPrimary,
        [Parameter(Mandatory = $true)][string]$LocalConfigBody
    )
    $scenarioRoot = Join-Path ([IO.Path]::GetTempPath()) (
        "BRAVO_PARITY_{0}_{1}" -f $(if ($WithPrimary) { 'PRIMARY' } else { 'NOCONFIG' }), [guid]::NewGuid().ToString('N')
    )
    [void][IO.Directory]::CreateDirectory($scenarioRoot)
    try {
        if ($WithPrimary) {
            $primaryText = (Get-BRAVOSelfTestLegacyConfigText)
            [IO.File]::WriteAllText((Join-Path $scenarioRoot 'BRAVO.config'), $primaryText, (New-Object System.Text.UTF8Encoding($false)))
        }
        [IO.File]::WriteAllText((Join-Path $scenarioRoot 'BRAVO.local.config'), $LocalConfigBody, (New-Object System.Text.UTF8Encoding($false)))
        $probeCommand = (
            "try { " +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "[void](Import-BravoConfiguration -ConfigRoot '$scenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
            "'RESULT:BackupRoot=' + [string]`$global:pathSettings.BackupRoot + " +
            "';FutureField=' + [string]`$global:maintenanceSettings.FutureFieldNotYetInSchema" +
            "} catch { 'THREW: ' + `$_.Exception.Message }"
        )
        $probeOutput = [string](
            & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $probeCommand 2>&1 | Out-String
        )
        return $probeOutput.Trim()
    } finally {
        Remove-Item -LiteralPath $scenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    # --- Parity 1: відомий override (pathSettings.BackupRoot) +
    # forward-compat новий leaf (maintenanceSettings.FutureFieldNotYetInSchema,
    # відсутній у Get-BRAVODefaultConfiguration, але maintenanceSettings —
    # реальний hashtable-вузол) МАЄ пережити roundtrip і дати ОДНАКОВЕ
    # значення в ОБОХ режимах.
    $parityForwardCompatBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$parityBackupRootLiteral'`r`n" +
        "    'maintenanceSettings.FutureFieldNotYetInSchema' = 'preserve-me'`r`n" +
        "}`r`n"
    )
    $parityNoConfigResult = New-BRAVOConfigLoaderParityProbe -WithPrimary $false -LocalConfigBody $parityForwardCompatBody
    $parityPrimaryResult = New-BRAVOConfigLoaderParityProbe -WithPrimary $true -LocalConfigBody $parityForwardCompatBody
    $parityForwardCompatExpected = "RESULT:BackupRoot=$parityBackupRootDir;FutureField=preserve-me"
    Test-BRAVOCondition `
        -Condition (
            $parityNoConfigResult -eq $parityForwardCompatExpected -and
            $parityPrimaryResult -eq $parityForwardCompatExpected
        ) `
        -Name "ConfigLoader/LocalOverrideParityForwardCompatLeaf" `
        -Failure "той самий BRAVO.local.config (відомий override + forward-compat новий leaf) має дати ОДНАКОВИЙ результат у config-present і config-absent; noConfig='$parityNoConfigResult' primary='$parityPrimaryResult' очікувалось='$parityForwardCompatExpected'"

    # --- Parity 2: генуїнно невідомий TOP-LEVEL ключ МАЄ fail-closed
    # ОДНАКОВО в ОБОХ режимах (typo-захист не повинен розійтися).
    $parityUnknownTopLevelBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$parityBackupRootLiteral'`r`n" +
        "    'noSuchTopLevelKey.Sub' = 'x'`r`n" +
        "}`r`n"
    )
    $parityNoConfigUnknownResult = New-BRAVOConfigLoaderParityProbe -WithPrimary $false -LocalConfigBody $parityUnknownTopLevelBody
    $parityPrimaryUnknownResult = New-BRAVOConfigLoaderParityProbe -WithPrimary $true -LocalConfigBody $parityUnknownTopLevelBody
    Test-BRAVOCondition `
        -Condition (
            $parityNoConfigUnknownResult.StartsWith('THREW') -and
            $parityPrimaryUnknownResult.StartsWith('THREW')
        ) `
        -Name "ConfigLoader/LocalOverrideParityUnknownTopLevelKeyBothFail" `
        -Failure "генуїнно невідомий top-level ключ у BRAVO.local.config має fail-closed ОДНАКОВО в config-present і config-absent; noConfig='$parityNoConfigUnknownResult' primary='$parityPrimaryUnknownResult'"
} finally {
    Remove-Item -LiteralPath $parityBackupRootDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# P0 Configuration Foundation (PR C, Секція 5.4): ФІНАЛЬНА post-merge
# перевірка безпеки (Test-BRAVOEffectiveSecurityInvariants,
# BRAVO_CONFIG_LOADER.ps1) — BRAVO.local.config НЕ повинен мати змогу
# обійти pre-trust guard (BRAVO_RUNTIME_GUARD.ps1 бачить лише текст
# BRAVO.config, не BRAVO.local.config). Обов'язкові тести з ТЗ:
# BRAVO.config відсутній + BRAVO.local.config послаблює захист -> BLOCK;
# те саме в config-present режимі теж має блокувати.
# ============================================================
$secDowngradeBackupRootDir = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_SECDOWNGRADE_BACKUP_{0}" -f [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($secDowngradeBackupRootDir)
$secDowngradeBackupRootLiteral = $secDowngradeBackupRootDir.Replace("'", "''")

function New-BRAVOConfigLoaderSecurityDowngradeProbe {
    param(
        [Parameter(Mandatory = $true)][bool]$WithPrimary,
        [Parameter(Mandatory = $true)][string]$LocalConfigBody,
        [string]$AllowWeakenedEnvValue = '',
        # Wave 1B (Issue #216): дозволяє викликачу перевіряти інший
        # ефективний $global:-вузол (напр. requireAdministrator), ніж
        # backupConsistency.Mode. Порожній рядок (default) зберігає ТОЧНО
        # попередню поведінку для всіх наявних викликачів.
        [string]$ResultExpression = ''
    )
    $scenarioRoot = Join-Path ([IO.Path]::GetTempPath()) (
        "BRAVO_SECDOWNGRADE_{0}_{1}" -f $(if ($WithPrimary) { 'PRIMARY' } else { 'NOCONFIG' }), [guid]::NewGuid().ToString('N')
    )
    [void][IO.Directory]::CreateDirectory($scenarioRoot)
    try {
        if ($WithPrimary) {
            $primaryText = (Get-BRAVOSelfTestLegacyConfigText)
            [IO.File]::WriteAllText((Join-Path $scenarioRoot 'BRAVO.config'), $primaryText, (New-Object System.Text.UTF8Encoding($false)))
        }
        [IO.File]::WriteAllText((Join-Path $scenarioRoot 'BRAVO.local.config'), $LocalConfigBody, (New-Object System.Text.UTF8Encoding($false)))
        $envPrefix = if (-not [string]::IsNullOrWhiteSpace($AllowWeakenedEnvValue)) {
            "`$env:BRAVO_ALLOW_WEAKENED_SECURITY = '$AllowWeakenedEnvValue'; "
        } else {
            ''
        }
        $resultExpr = if (-not [string]::IsNullOrWhiteSpace($ResultExpression)) {
            $ResultExpression
        } else {
            "'RESULT:Mode=' + [string]`$global:backupConsistency.Mode"
        }
        $probeCommand = (
            "try { $envPrefix" +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "[void](Import-BravoConfiguration -ConfigRoot '$scenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
            "$resultExpr" +
            "} catch { 'THREW: ' + `$_.Exception.Message }"
        )
        $probeOutput = [string](
            & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $probeCommand 2>&1 | Out-String
        )
        return $probeOutput.Trim()
    } finally {
        Remove-Item -LiteralPath $scenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    $secDowngradeBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$secDowngradeBackupRootLiteral'`r`n" +
        "    'backupConsistency.Mode' = 'Direct'`r`n" +
        "}`r`n"
    )

    # --- Test 5.4a: BRAVO.config ВІДСУТНІЙ, BRAVO.local.config послаблює
    # backupConsistency.Mode -> МАЄ БЛОКУВАТИ (pre-trust guard нічого не
    # бачить, бо BRAVO.config відсутній — саме тому цей post-merge
    # gate обов'язковий).
    $secDowngradeNoConfigResult = New-BRAVOConfigLoaderSecurityDowngradeProbe -WithPrimary $false -LocalConfigBody $secDowngradeBody
    Test-BRAVOCondition `
        -Condition (
            $secDowngradeNoConfigResult.StartsWith('THREW') -and
            $secDowngradeNoConfigResult.Contains('ПОСЛАБЛЮЄ ЗАХИСТ')
        ) `
        -Name "ConfigLoader/SecurityDowngradeViaLocalConfigBlockedNoConfig" `
        -Failure "BRAVO.config відсутній + BRAVO.local.config встановлює backupConsistency.Mode='Direct' -> МАЄ БЛОКУВАТИ; отримано: $secDowngradeNoConfigResult"

    # --- Test 5.4b: те саме, але BRAVO.config ПРИСУТНІЙ (з коректним
    # VSS) — local override все одно перекриває його на ефективному рівні
    # -> МАЄ БЛОКУВАТИ так само (не лише no-config-режим).
    $secDowngradePrimaryResult = New-BRAVOConfigLoaderSecurityDowngradeProbe -WithPrimary $true -LocalConfigBody $secDowngradeBody
    Test-BRAVOCondition `
        -Condition (
            $secDowngradePrimaryResult.StartsWith('THREW') -and
            $secDowngradePrimaryResult.Contains('ПОСЛАБЛЮЄ ЗАХИСТ')
        ) `
        -Name "ConfigLoader/SecurityDowngradeViaLocalConfigBlockedWithPrimary" `
        -Failure "BRAVO.config присутній (VSS) + BRAVO.local.config встановлює backupConsistency.Mode='Direct' -> МАЄ БЛОКУВАТИ; отримано: $secDowngradePrimaryResult"

    # --- Test 5.4c: свідомий override (BRAVO_ALLOW_WEAKENED_SECURITY=1)
    # дозволяє послаблення й через BRAVO.local.config так само, як через
    # BRAVO.config — без цього оператор мав би обхідний шлях лише для
    # одного з двох джерел.
    $secDowngradeOverrideResult = New-BRAVOConfigLoaderSecurityDowngradeProbe `
        -WithPrimary $false -LocalConfigBody $secDowngradeBody -AllowWeakenedEnvValue '1'
    Test-BRAVOCondition `
        -Condition ($secDowngradeOverrideResult -eq 'RESULT:Mode=Direct') `
        -Name "ConfigLoader/SecurityDowngradeViaLocalConfigAllowedWithExplicitOverride" `
        -Failure "BRAVO_ALLOW_WEAKENED_SECURITY=1 має дозволяти послаблення через BRAVO.local.config (з видимим слідом), а не блокувати; отримано: $secDowngradeOverrideResult"

    # --- Test 5.4d (sanity): local override, що НЕ послаблює захист
    # (явний коректний 'VSS'), не повинен ставати хибним блоком.
    $secDowngradeSafeBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$secDowngradeBackupRootLiteral'`r`n" +
        "    'backupConsistency.Mode' = 'VSS'`r`n" +
        "}`r`n"
    )
    $secDowngradeSafeResult = New-BRAVOConfigLoaderSecurityDowngradeProbe -WithPrimary $false -LocalConfigBody $secDowngradeSafeBody
    Test-BRAVOCondition `
        -Condition ($secDowngradeSafeResult -eq 'RESULT:Mode=VSS') `
        -Name "ConfigLoader/SecurityInvariantDoesNotFalsePositiveOnSafeLocalOverride" `
        -Failure "BRAVO.local.config з коректним backupConsistency.Mode='VSS' не повинен блокуватись; отримано: $secDowngradeSafeResult"
} finally {
    Remove-Item -LiteralPath $secDowngradeBackupRootDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# Wave 1B (Issue #216): requireAdministrator приєднано до ТОГО САМОГО
# post-merge Test-BRAVOEffectiveSecurityInvariants-контролю, що
# backupConsistency.Mode/toolIntegritySettings.Mode вище — той самий
# Enforce/Warn + BRAVO_ALLOW_WEAKENED_SECURITY=1 механізм, ті самі
# BRAVO.local.config-вектори обходу pre-trust guard. Три випадки
# розрізняються явно: відсутній leaf / $false / не-Boolean значення.
# ============================================================
$reqAdminBackupRootDir = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_REQADMIN_BACKUP_{0}" -f [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($reqAdminBackupRootDir)
$reqAdminBackupRootLiteral = $reqAdminBackupRootDir.Replace("'", "''")
$reqAdminResultExpression = (
    "`$reqAdminVar = Get-Variable -Name 'requireAdministrator' -Scope Global -ErrorAction SilentlyContinue; " +
    "if (`$null -eq `$reqAdminVar) { 'RESULT:ReqAdmin=<missing>' } " +
    "else { 'RESULT:ReqAdmin=' + [string]`$reqAdminVar.Value + ';Type=' + `$reqAdminVar.Value.GetType().Name }"
)

try {
    # --- ConfigLoader/RequireAdministratorSecureValuePasses: жодного
    # override requireAdministrator -> canonical default ($true) лишається
    # ефективним, запуск НЕ повинен блокуватись.
    $reqAdminSafeBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$reqAdminBackupRootLiteral'`r`n" +
        "}`r`n"
    )
    $reqAdminSafeResult = New-BRAVOConfigLoaderSecurityDowngradeProbe `
        -WithPrimary $false -LocalConfigBody $reqAdminSafeBody -ResultExpression $reqAdminResultExpression
    Test-BRAVOCondition `
        -Condition ($reqAdminSafeResult -eq 'RESULT:ReqAdmin=True;Type=Boolean') `
        -Name "ConfigLoader/RequireAdministratorSecureValuePasses" `
        -Failure "canonical default requireAdministrator=`$true не повинен блокуватись і має лишитись Boolean `$true; отримано: $reqAdminSafeResult"

    # --- ConfigLoader/RequireAdministratorDowngradeViaLocalConfigBlockedNoConfig:
    # BRAVO.config відсутній, BRAVO.local.config встановлює
    # requireAdministrator=$false -> МАЄ БЛОКУВАТИ (той самий вектор обходу
    # pre-trust guard, що backupConsistency.Mode вище).
    #
    # Issue #216, Wave 2: requireAdministrator тепер класифікований
    # DENY_SECURITY_CONTROL у canonical authorization-реєстрі, тому
    # звичайний BRAVO.local.config-шлях блокується РАНІШЕ —
    # Test-BRAVOConfigurationOverrideAuthorization (pre-merge), а не лише
    # Test-BRAVOEffectiveSecurityInvariants (post-merge, 'ПОСЛАБЛЮЄ
    # ЗАХИСТ'). Обидва повідомлення приймаються тут як доказ блокування:
    # Wave 1 POST-merge інваріант і далі незалежно перевіряється напряму
    # (ConfigLoader/RequireAdministratorInvariantOwnNonBooleanBranch,
    # ConfigLoader/RequireAdministratorMissingBlocks нижче — обидва
    # викликають Test-BRAVOEffectiveSecurityInvariants НАПРЯМУ, в обхід
    # Wave 2, і лишаються незміненими).
    $reqAdminFalseBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$reqAdminBackupRootLiteral'`r`n" +
        "    'requireAdministrator' = `$false`r`n" +
        "}`r`n"
    )
    $reqAdminNoConfigResult = New-BRAVOConfigLoaderSecurityDowngradeProbe `
        -WithPrimary $false -LocalConfigBody $reqAdminFalseBody -ResultExpression $reqAdminResultExpression
    Test-BRAVOCondition `
        -Condition (
            $reqAdminNoConfigResult.StartsWith('THREW') -and
            ($reqAdminNoConfigResult.Contains('ПОСЛАБЛЮЄ ЗАХИСТ') -or $reqAdminNoConfigResult.Contains('неавторизоване перевизначення'))
        ) `
        -Name "ConfigLoader/RequireAdministratorDowngradeViaLocalConfigBlockedNoConfig" `
        -Failure "BRAVO.config відсутній + BRAVO.local.config встановлює requireAdministrator=`$false -> МАЄ БЛОКУВАТИ (Wave 1 post-merge АБО Wave 2 pre-merge); отримано: $reqAdminNoConfigResult"

    # --- ConfigLoader/RequireAdministratorDowngradeViaLocalConfigBlockedWithPrimary:
    # те саме, але BRAVO.config ПРИСУТНІЙ — local override все одно
    # перекриває на ефективному рівні -> МАЄ БЛОКУВАТИ так само.
    $reqAdminWithPrimaryResult = New-BRAVOConfigLoaderSecurityDowngradeProbe `
        -WithPrimary $true -LocalConfigBody $reqAdminFalseBody -ResultExpression $reqAdminResultExpression
    Test-BRAVOCondition `
        -Condition (
            $reqAdminWithPrimaryResult.StartsWith('THREW') -and
            ($reqAdminWithPrimaryResult.Contains('ПОСЛАБЛЮЄ ЗАХИСТ') -or $reqAdminWithPrimaryResult.Contains('неавторизоване перевизначення'))
        ) `
        -Name "ConfigLoader/RequireAdministratorDowngradeViaLocalConfigBlockedWithPrimary" `
        -Failure "BRAVO.config присутній + BRAVO.local.config встановлює requireAdministrator=`$false -> МАЄ БЛОКУВАТИ (Wave 1 post-merge АБО Wave 2 pre-merge); отримано: $reqAdminWithPrimaryResult"

    # --- ConfigLoader/RequireAdministratorDowngradeAllowedWithExplicitOverride:
    # BRAVO_ALLOW_WEAKENED_SECURITY=1 дозволяє свідоме послаблення (з
    # видимим слідом), а не блокує.
    $reqAdminOverrideResult = New-BRAVOConfigLoaderSecurityDowngradeProbe `
        -WithPrimary $false -LocalConfigBody $reqAdminFalseBody -AllowWeakenedEnvValue '1' `
        -ResultExpression $reqAdminResultExpression
    Test-BRAVOCondition `
        -Condition ($reqAdminOverrideResult -eq 'RESULT:ReqAdmin=False;Type=Boolean') `
        -Name "ConfigLoader/RequireAdministratorDowngradeAllowedWithExplicitOverride" `
        -Failure "BRAVO_ALLOW_WEAKENED_SECURITY=1 має дозволяти requireAdministrator=`$false (з видимим слідом), а не блокувати; отримано: $reqAdminOverrideResult"

    # --- ConfigLoader/RequireAdministratorDowngradeDiagnosticIsExplicit:
    # реальний end-to-end шлях (BRAVO.local.config -> Import-BravoConfiguration)
    # ловить не-Boolean requireAdministrator ЩЕ РАНІШЕ, ніж
    # Test-BRAVOEffectiveSecurityInvariants: Test-BRAVOConfigurationOverrideSchema
    # виводить очікуваний тип із canonical default ($true -> Boolean) і
    # відхиляє 'STRING-NOT-BOOL' fail-closed з власним явним повідомленням.
    # Це ВАЛІДНИЙ шар захисту в глибину (той самий підсумок: блокує, з
    # явним типовим діагнозом, не мовчки [bool]-coerce), тому тест
    # перевіряє САМЕ цей фактичний шлях.
    $reqAdminNonBoolBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$reqAdminBackupRootLiteral'`r`n" +
        "    'requireAdministrator' = 'STRING-NOT-BOOL'`r`n" +
        "}`r`n"
    )
    $reqAdminNonBoolResult = New-BRAVOConfigLoaderSecurityDowngradeProbe `
        -WithPrimary $false -LocalConfigBody $reqAdminNonBoolBody -ResultExpression $reqAdminResultExpression
    Test-BRAVOCondition `
        -Condition (
            $reqAdminNonBoolResult.StartsWith('THREW') -and
            $reqAdminNonBoolResult.Contains('очікується логічне значення') -and
            $reqAdminNonBoolResult.Contains('requireAdministrator')
        ) `
        -Name "ConfigLoader/RequireAdministratorDowngradeDiagnosticIsExplicit" `
        -Failure "requireAdministrator='STRING-NOT-BOOL' (не-Boolean) МАЄ БЛОКУВАТИ з окремим, явним типовим діагностичним повідомленням (схема відхиляє нетипізоване значення ще до post-merge перевірки, не мовчки [bool]-coerce до `$true); отримано: $reqAdminNonBoolResult"

    # --- ConfigLoader/RequireAdministratorInvariantOwnNonBooleanBranch:
    # схема-шар вище блокує не-Boolean ЩЕ ДО Test-BRAVOEffectiveSecurityInvariants
    # для звичайного BRAVO.local.config-шляху — цей тест викликає саму
    # інваріант-функцію НАПРЯМУ з $global:requireAdministrator, встановленим
    # у не-Boolean значення в обхід схеми, щоб довести, що ВЛАСНА
    # "не є Boolean"-гілка Test-BRAVOEffectiveSecurityInvariants (не лише
    # схема) теж явно блокує — захист у глибину, а не єдина точка відмови.
    $reqAdminInvariantNonBoolProbeCommand = (
        "try { . '$root\BRAVO_CONFIG_LOADER.ps1'; " +
        "`$global:backupConsistency = @{ Mode = 'VSS' }; " +
        "`$global:toolIntegritySettings = @{ Mode = 'Enforce' }; " +
        "`$global:requireAdministrator = 'STRING-NOT-BOOL'; " +
        "Test-BRAVOEffectiveSecurityInvariants } catch { 'THREW: ' + `$_.Exception.Message }"
    )
    $reqAdminInvariantNonBoolResult = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $reqAdminInvariantNonBoolProbeCommand 2>&1 | Out-String
    ).Trim()
    Test-BRAVOCondition `
        -Condition (
            $reqAdminInvariantNonBoolResult.StartsWith('THREW') -and
            $reqAdminInvariantNonBoolResult.Contains('ПОСЛАБЛЮЄ ЗАХИСТ') -and
            $reqAdminInvariantNonBoolResult.Contains('не є Boolean-значенням')
        ) `
        -Name "ConfigLoader/RequireAdministratorInvariantOwnNonBooleanBranch" `
        -Failure "Test-BRAVOEffectiveSecurityInvariants ВЛАСНА гілка не-Boolean (незалежно від схеми) мусить блокувати з повідомленням 'не є Boolean-значенням'; отримано: $reqAdminInvariantNonBoolResult"
} finally {
    Remove-Item -LiteralPath $reqAdminBackupRootDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- ConfigLoader/RequireAdministratorMissingBlocks: викликає
# Test-BRAVOEffectiveSecurityInvariants НАПРЯМУ у чистому процесі (без
# Import-BravoConfiguration), тому $global:requireAdministrator фактично
# ВІДСУТНІЙ (не просто $false) — окремий case від "$false", який
# неможливо відтворити через звичайний override-шлях (canonical default
# завжди встановлює якесь значення). backupConsistency/toolIntegritySettings
# встановлюються явно безпечними значеннями, щоб StrictMode-звернення до
# них у ЦІЙ самій функції не кинуло раніше, ніж дійде до перевірки
# requireAdministrator (ізоляція однієї змінної під тестом).
$reqAdminMissingProbeCommand = (
    "try { . '$root\BRAVO_CONFIG_LOADER.ps1'; " +
    "`$global:backupConsistency = @{ Mode = 'VSS' }; " +
    "`$global:toolIntegritySettings = @{ Mode = 'Enforce' }; " +
    "Test-BRAVOEffectiveSecurityInvariants } catch { 'THREW: ' + `$_.Exception.Message }"
)
$reqAdminMissingResult = [string](
    & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $reqAdminMissingProbeCommand 2>&1 | Out-String
).Trim()
Test-BRAVOCondition `
    -Condition (
        $reqAdminMissingResult.StartsWith('THREW') -and
        $reqAdminMissingResult.Contains('ПОСЛАБЛЮЄ ЗАХИСТ') -and
        $reqAdminMissingResult.Contains('requireAdministrator відсутній')
    ) `
    -Name "ConfigLoader/RequireAdministratorMissingBlocks" `
    -Failure "відсутній `$global:requireAdministrator (не просто `$false) МАЄ БЛОКУВАТИ з окремим діагностичним повідомленням 'requireAdministrator відсутній'; отримано: $reqAdminMissingResult"

# ============================================================
# Issue #216, Wave 2 review-фікс: backupMonitoring.SFTP.BAZA.Mode/
# .MutationPolicy — owner-decision листи, для яких DENY_SECURITY_CONTROL
# класифікація САМА ПО СОБІ не надає доступу до BRAVO_ALLOW_WEAKENED_SECURITY
# escape hatch (на відміну від requireAdministrator вище). BAZA
# append-only/mutation-detection цілісність — той самий клас гарантії,
# що .claude/rules/07-bravo-runtime-invariants.md вимагає окремого
# свідомого рішення власника для послаблення (як AutoArchiveMutationThreshold),
# а не побічного входження через загальний клас-based escape hatch.
# Незалежний рев'ювер (Wave 2, раунд 1) знайшов, що документація
# твердила про "безумовну" відмову, а код фактично поширював генеричний
# DENY_SECURITY_CONTROL escape hatch і на ЦІ листи — цей блок:
#   (a) доводить, що звичайний шлях блокує (як і всі DENY_SECURITY_CONTROL);
#   (b) доводить, що BRAVO_ALLOW_WEAKENED_SECURITY=1 НЕ відкриває їх
#       (на відміну від requireAdministrator/backupConsistency.Mode) —
#       саме цього e2e-доказу раніше бракувало.
# ============================================================
$bazaModeBackupRootDir = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_BAZAMODE_BACKUP_{0}" -f [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($bazaModeBackupRootDir)
$bazaModeBackupRootLiteral = $bazaModeBackupRootDir.Replace("'", "''")
$bazaModeResultExpression = (
    "'RESULT:BazaMode=' + [string]`$global:backupMonitoring.SFTP.BAZA.Mode"
)
try {
    $bazaModeOverrideBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$bazaModeBackupRootLiteral'`r`n" +
        "    'backupMonitoring.SFTP.BAZA.Mode' = 'Legacy'`r`n" +
        "}`r`n"
    )

    # --- ConfigLoader/BazaModeDowngradeBlockedNoConfig: звичайний шлях
    # МАЄ блокувати (як і будь-який інший DENY_SECURITY_CONTROL-лист).
    $bazaModeNoConfigResult = New-BRAVOConfigLoaderSecurityDowngradeProbe `
        -WithPrimary $false -LocalConfigBody $bazaModeOverrideBody -ResultExpression $bazaModeResultExpression
    Test-BRAVOCondition `
        -Condition (
            $bazaModeNoConfigResult.StartsWith('THREW') -and
            $bazaModeNoConfigResult.Contains('неавторизоване перевизначення')
        ) `
        -Name "ConfigLoader/BazaModeDowngradeBlockedNoConfig" `
        -Failure "BRAVO.local.config встановлює backupMonitoring.SFTP.BAZA.Mode='Legacy' -> МАЄ БЛОКУВАТИ; отримано: $bazaModeNoConfigResult"

    # --- ConfigLoader/BazaModeDowngradeNotEscapableWithWeakenedSecurity:
    # КЛЮЧОВИЙ тест цього блоку — на відміну від requireAdministrator/
    # backupConsistency.Mode, BRAVO_ALLOW_WEAKENED_SECURITY=1 НЕ повинен
    # відкривати BAZA.Mode: очікується ТЕ САМЕ блокування, що й без
    # env-змінної.
    $bazaModeEscapeAttemptResult = New-BRAVOConfigLoaderSecurityDowngradeProbe `
        -WithPrimary $false -LocalConfigBody $bazaModeOverrideBody -AllowWeakenedEnvValue '1' `
        -ResultExpression $bazaModeResultExpression
    Test-BRAVOCondition `
        -Condition (
            $bazaModeEscapeAttemptResult.StartsWith('THREW') -and
            $bazaModeEscapeAttemptResult.Contains('неавторизоване перевизначення')
        ) `
        -Name "ConfigLoader/BazaModeDowngradeNotEscapableWithWeakenedSecurity" `
        -Failure "BRAVO_ALLOW_WEAKENED_SECURITY=1 НЕ повинен відкривати backupMonitoring.SFTP.BAZA.Mode (owner-decision лист, безумовна відмова) — на відміну від requireAdministrator; отримано: $bazaModeEscapeAttemptResult"

    # --- ConfigLoader/BazaMutationPolicyDowngradeNotEscapableWithWeakenedSecurity:
    # той самий доказ для сусіднього MutationPolicy-листа (та сама
    # append-only-гарантія BAZA, той самий клас ризику).
    $bazaMutationPolicyOverrideBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$bazaModeBackupRootLiteral'`r`n" +
        "    'backupMonitoring.SFTP.BAZA.MutationPolicy' = 'AllowOverwrite'`r`n" +
        "}`r`n"
    )
    $bazaMutationPolicyEscapeAttemptResult = New-BRAVOConfigLoaderSecurityDowngradeProbe `
        -WithPrimary $false -LocalConfigBody $bazaMutationPolicyOverrideBody -AllowWeakenedEnvValue '1' `
        -ResultExpression $bazaModeResultExpression
    Test-BRAVOCondition `
        -Condition (
            $bazaMutationPolicyEscapeAttemptResult.StartsWith('THREW') -and
            $bazaMutationPolicyEscapeAttemptResult.Contains('неавторизоване перевизначення')
        ) `
        -Name "ConfigLoader/BazaMutationPolicyDowngradeNotEscapableWithWeakenedSecurity" `
        -Failure "BRAVO_ALLOW_WEAKENED_SECURITY=1 НЕ повинен відкривати backupMonitoring.SFTP.BAZA.MutationPolicy (owner-decision лист, безумовна відмова); отримано: $bazaMutationPolicyEscapeAttemptResult"
} finally {
    Remove-Item -LiteralPath $bazaModeBackupRootDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# PR #224 third review, final cleanup: BRAVO_CONFIG_LOADER.ps1 більше
# не інтерпретує WeakeningOverride/BRAVO_ALLOW_WEAKENED_SECURITY
# самостійно — Complete-BRAVOConfigurationLoad делегує рішення "чи ЦЕЙ
# Path escapable ЗАРАЗ" canonical Test-BRAVOConfigurationWeakeningEscapeHatchAllowed
# (BRAVO.Configuration.Schema.psm1), тій самій функції, яку викликає
# Configurator-preview. Блоки вище (requireAdministrator/BAZA.Mode/
# BAZA.MutationPolicy, кожен окремо) уже e2e-доводять, що рефакторинг
# зберіг поведінку через реальний Import-BravoConfiguration — цей блок
# додає лише те, чого не було: (a) явні тести з іменами, які прямо
# називають canonical-helper-делегування, і (b) ключовий MIXED-кейс —
# ОДИН escapable-лист (requireAdministrator) РАЗОМ з ОДНИМ hard-листом
# (BAZA.Mode) в ОДНОМУ файлі з BRAVO_ALLOW_WEAKENED_SECURITY=1: увесь
# шар мусить fail-closed атомарно, бо хоча б одне порушення лишається
# невирішеним — старий inline-код (2 окремі Where-Object-партиції +
# один спільний env-прапор) і новий canonical-helper-код дають той
# самий результат ТІЛЬКИ якщо helper дійсно застосовується ПЕР-VIOLATION,
# а не глобально.
# ============================================================
$weakeningCleanupBackupRootDir = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_WEAKENCLEANUP_BACKUP_{0}" -f [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($weakeningCleanupBackupRootDir)
$weakeningCleanupBackupRootLiteral = $weakeningCleanupBackupRootDir.Replace("'", "''")

function New-BRAVOConfigLoaderWeakeningMixedProbe {
    param(
        [Parameter(Mandatory = $true)][string]$LocalConfigBody,
        [string]$AllowWeakenedEnvValue = ''
    )
    $scenarioRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_WEAKENCLEANUP_{0}" -f [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($scenarioRoot)
    try {
        [IO.File]::WriteAllText((Join-Path $scenarioRoot 'BRAVO.local.config'), $LocalConfigBody, (New-Object System.Text.UTF8Encoding($false)))
        $envPrefix = if (-not [string]::IsNullOrWhiteSpace($AllowWeakenedEnvValue)) {
            "`$env:BRAVO_ALLOW_WEAKENED_SECURITY = '$AllowWeakenedEnvValue'; "
        } else {
            ''
        }
        # Той самий доказ атомарності, що New-BRAVOConfigLoaderAtomicityProbe
        # вище (archiveRetentionDays лишається <unset> на throw) — тут
        # додатково перевіряємо requireAdministrator, бо саме цей лист
        # проходить через escape-hatch-гілку коду, яку рефакторинг змінив.
        $probeCommand = (
            "try { $envPrefix" +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "[void](Import-BravoConfiguration -ConfigRoot '$scenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
            "'NOTHREW:ArchiveRetentionDays=' + [string]`$global:archiveRetentionDays " +
            "} catch { " +
            "`$archiveVar = Get-Variable -Name 'archiveRetentionDays' -Scope Global -ErrorAction SilentlyContinue; " +
            "`$archiveState = if (`$null -eq `$archiveVar) { '<unset>' } else { [string]`$archiveVar.Value }; " +
            "`$reqAdminVar = Get-Variable -Name 'requireAdministrator' -Scope Global -ErrorAction SilentlyContinue; " +
            "`$reqAdminState = if (`$null -eq `$reqAdminVar) { '<unset>' } else { [string]`$reqAdminVar.Value }; " +
            "'THREW:' + `$_.Exception.Message + ';ArchiveRetentionDaysAfterThrow=' + `$archiveState + ';ReqAdminAfterThrow=' + `$reqAdminState" +
            "}"
        )
        $probeOutput = [string](
            & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $probeCommand 2>&1 | Out-String
        )
        return $probeOutput.Trim()
    } finally {
        Remove-Item -LiteralPath $scenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    # --- Loader/RequireAdministratorWeakeningRejectedWithoutEnv ---
    $weakeningReqAdminOnlyBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$weakeningCleanupBackupRootLiteral'`r`n" +
        "    'requireAdministrator' = `$false`r`n" +
        "}`r`n"
    )
    $weakeningReqAdminNoEnvResult = New-BRAVOConfigLoaderWeakeningMixedProbe -LocalConfigBody $weakeningReqAdminOnlyBody
    Test-BRAVOCondition `
        -Condition (
            $weakeningReqAdminNoEnvResult.StartsWith('THREW:') -and
            $weakeningReqAdminNoEnvResult.Contains('неавторизоване перевизначення') -and
            $weakeningReqAdminNoEnvResult.Contains('ArchiveRetentionDaysAfterThrow=<unset>')
        ) `
        -Name "Loader/RequireAdministratorWeakeningRejectedWithoutEnv" `
        -Failure "requireAdministrator=`$false БЕЗ BRAVO_ALLOW_WEAKENED_SECURITY=1 мусить fail-closed через canonical helper (Test-BRAVOConfigurationWeakeningEscapeHatchAllowed повертає `$false); отримано: $weakeningReqAdminNoEnvResult"

    # --- Loader/RequireAdministratorWeakeningAllowedWithEnv ---
    $weakeningReqAdminOnlyBody999 = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$weakeningCleanupBackupRootLiteral'`r`n" +
        "    'archiveRetentionDays' = 999`r`n" +
        "    'requireAdministrator' = `$false`r`n" +
        "}`r`n"
    )
    $weakeningReqAdminWithEnvResult = New-BRAVOConfigLoaderWeakeningMixedProbe `
        -LocalConfigBody $weakeningReqAdminOnlyBody999 -AllowWeakenedEnvValue '1'
    Test-BRAVOCondition `
        -Condition ($weakeningReqAdminWithEnvResult -eq 'NOTHREW:ArchiveRetentionDays=999') `
        -Name "Loader/RequireAdministratorWeakeningAllowedWithEnv" `
        -Failure "requireAdministrator=`$false З BRAVO_ALLOW_WEAKENED_SECURITY=1 мусить пройти через canonical helper (сусідній archiveRetentionDays=999 мусить застосуватись, шар НЕ відхилений); отримано: $weakeningReqAdminWithEnvResult"

    # --- Loader/BazaModeNotEscapableWithWeakeningEnv ---
    $weakeningBazaModeOnlyBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$weakeningCleanupBackupRootLiteral'`r`n" +
        "    'backupMonitoring.SFTP.BAZA.Mode' = 'Legacy'`r`n" +
        "}`r`n"
    )
    $weakeningBazaModeResult = New-BRAVOConfigLoaderWeakeningMixedProbe `
        -LocalConfigBody $weakeningBazaModeOnlyBody -AllowWeakenedEnvValue '1'
    Test-BRAVOCondition `
        -Condition (
            $weakeningBazaModeResult.StartsWith('THREW:') -and
            $weakeningBazaModeResult.Contains('неавторизоване перевизначення')
        ) `
        -Name "Loader/BazaModeNotEscapableWithWeakeningEnv" `
        -Failure "backupMonitoring.SFTP.BAZA.Mode мусить лишитись fail-closed через canonical helper навіть з BRAVO_ALLOW_WEAKENED_SECURITY=1 (WeakeningOverride='None'); отримано: $weakeningBazaModeResult"

    # --- Loader/BazaMutationPolicyNotEscapableWithWeakeningEnv ---
    $weakeningBazaMutationPolicyOnlyBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$weakeningCleanupBackupRootLiteral'`r`n" +
        "    'backupMonitoring.SFTP.BAZA.MutationPolicy' = 'AllowOverwrite'`r`n" +
        "}`r`n"
    )
    $weakeningBazaMutationPolicyResult = New-BRAVOConfigLoaderWeakeningMixedProbe `
        -LocalConfigBody $weakeningBazaMutationPolicyOnlyBody -AllowWeakenedEnvValue '1'
    Test-BRAVOCondition `
        -Condition (
            $weakeningBazaMutationPolicyResult.StartsWith('THREW:') -and
            $weakeningBazaMutationPolicyResult.Contains('неавторизоване перевизначення')
        ) `
        -Name "Loader/BazaMutationPolicyNotEscapableWithWeakeningEnv" `
        -Failure "backupMonitoring.SFTP.BAZA.MutationPolicy мусить лишитись fail-closed через canonical helper навіть з BRAVO_ALLOW_WEAKENED_SECURITY=1 (WeakeningOverride='None'); отримано: $weakeningBazaMutationPolicyResult"

    # --- Loader/MixedEscapableAndHardViolationRejectsAtomically ---
    # КЛЮЧОВИЙ тест цього блоку: requireAdministrator=$false (escapable)
    # РАЗОМ з backupMonitoring.SFTP.BAZA.Mode='Legacy' (hard) в ОДНОМУ
    # файлі, з BRAVO_ALLOW_WEAKENED_SECURITY=1. Якби рефакторинг помилково
    # застосував helper ДО всього набору порушень одразу (напр. "чи БУДЬ-
    # ЯКЕ порушення escapable"), а не ПЕР-violation, цей тест виявив би
    # це — весь шар мусить відхилитись, і жоден сусідній ALLOW_SITE
    # override (archiveRetentionDays) не повинен потрапити в ефективний
    # стан навіть частково.
    $weakeningMixedBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$weakeningCleanupBackupRootLiteral'`r`n" +
        "    'archiveRetentionDays' = 999`r`n" +
        "    'requireAdministrator' = `$false`r`n" +
        "    'backupMonitoring.SFTP.BAZA.Mode' = 'Legacy'`r`n" +
        "}`r`n"
    )
    $weakeningMixedResult = New-BRAVOConfigLoaderWeakeningMixedProbe `
        -LocalConfigBody $weakeningMixedBody -AllowWeakenedEnvValue '1'
    Test-BRAVOCondition `
        -Condition (
            $weakeningMixedResult.StartsWith('THREW:') -and
            $weakeningMixedResult.Contains('неавторизоване перевизначення') -and
            $weakeningMixedResult.Contains('backupMonitoring.SFTP.BAZA.Mode') -and
            $weakeningMixedResult.Contains('ArchiveRetentionDaysAfterThrow=<unset>') -and
            $weakeningMixedResult.Contains('ReqAdminAfterThrow=<unset>')
        ) `
        -Name "Loader/MixedEscapableAndHardViolationRejectsAtomically" `
        -Failure "requireAdministrator=`$false (escapable) + BAZA.Mode='Legacy' (hard) + BRAVO_ALLOW_WEAKENED_SECURITY=1 мусить відхилити ЦІЛИЙ local-override шар атомарно (жоден лист, у т.ч. escapable requireAdministrator чи сусідній ALLOW_SITE archiveRetentionDays, не повинен потрапити в ефективний стан); отримано: $weakeningMixedResult"
} finally {
    Remove-Item -LiteralPath $weakeningCleanupBackupRootDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# P0 Configuration Foundation (PR C, Секція 5.5): МЕХАНІЧНИЙ доказ, що
# pre-trust AST-правила (BRAVO_RUNTIME_GUARD.ps1, статичний текст
# BRAVO.config) і post-merge effective-правила
# (Test-BRAVOEffectiveSecurityInvariants, BRAVO_CONFIG_LOADER.ps1,
# ефективні $global:-значення) перевіряють ОДНАКОВІ очікувані значення
# для ОДНИХ і тих самих налаштувань — не два незалежні набори правил,
# що можуть розійтися мовчки. Це НЕ той самий код (різні механізми:
# AST-літерал до Import-Module vs. ефективне значення після повного
# мержу) — тому перевіряється текстова присутність тих самих
# Variable/Key/Expected-трійок в обох файлах, а не спільний виклик.
# ============================================================
$guardTextForParity = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_RUNTIME_GUARD.ps1'), [Text.Encoding]::UTF8)
$loaderTextForSecurityParity = [IO.File]::ReadAllText($configLoaderPath, [Text.Encoding]::UTF8)
Test-BRAVOCondition `
    -Condition (
        $guardTextForParity.Contains("Variable = 'toolIntegritySettings'") -and
        $guardTextForParity.Contains("Expected = 'Enforce'") -and
        $guardTextForParity.Contains("Variable = 'backupConsistency'") -and
        $guardTextForParity.Contains("Expected = 'VSS'") -and
        $loaderTextForSecurityParity.Contains('$global:toolIntegritySettings.Mode') -and
        $loaderTextForSecurityParity.Contains("'Enforce', [System.StringComparison]::OrdinalIgnoreCase") -and
        $loaderTextForSecurityParity.Contains('$global:backupConsistency.Mode') -and
        $loaderTextForSecurityParity.Contains("'VSS', [System.StringComparison]::OrdinalIgnoreCase")
    ) `
    -Name "ConfigLoader/SecurityRuleParityGuardVsEffectiveCheck" `
    -Failure "pre-trust guard (BRAVO_RUNTIME_GUARD.ps1) і post-merge effective-перевірка (BRAVO_CONFIG_LOADER.ps1) мають перевіряти ОДНАКОВІ Expected-значення (toolIntegritySettings.Mode='Enforce', backupConsistency.Mode='VSS') — розбіжність тут означає, що два набори правил розійшлися"

# ============================================================
# P0 Configuration Foundation (PR C, owner-checkpoint п.6): МЕХАНІЧНИЙ
# доказ, що committed репозиторний BRAVO.config (legacy primary, що
# сьогодні реально розгортається як shipped-конфіг) НЕ дублює жодного
# canonical product-default ІНШИМ значенням — інакше звичайний
# config-present запуск мовчки повертав би старий/environment-specific
# "default" (напр. maintenanceSettings.Limits.ExcludedDrives=@('F:\'))
# замість справжнього canonical @(), і built-in defaults НЕ були б
# єдиним джерелом істини на практиці (лише в ще не підключеному
# no-config-шляху). Порівнює raw-знімок ПОВНОГО виконання committed
# BRAVO.config (той самий allowlist-механізм, що
# Import-BravoLegacyPrimaryConfiguration) проти Get-BRAVODefaultConfiguration
# по КОЖНОМУ allowlisted top-level ключу рекурсивно. Навмисні винятки —
# лише ті, що явно задокументовані в самому Get-BRAVODefaultConfiguration
# docstring (наразі: ExcludedDrives, lunchArchiveCleanupPath,
# smbSettings.RootPath — синхронізовані з дефолтом 2026-09, коментар
# лишається як історія рішення).
# ============================================================
function Compare-BRAVOConfigurationGraphForParity {
    # Приймає накопичувач ЯВНО (той самий List[string]-об'єкт по всій
    # рекурсії) замість повернення масиву через `return` — рекурсивний
    # `return ,@(...)` на кожному рівні вкладеності виявився ненадійним
    # (порожні "diff"-рядки в self-test-виводі: PowerShell-семантика
    # розгортання масиву на межі pipeline при захопленні результату
    # РЕКУРСИВНОГО виклику через `@(...)` неоднозначна для вкладених
    # comma-обгорнутих масивів). Явний спільний List уникає цього класу
    # проблем повністю.
    param($Actual, $Expected, [string]$Path, [System.Collections.Generic.List[string]]$Diffs)
    if ($Actual -is [hashtable] -and $Expected -is [hashtable]) {
        $allKeys = @(@($Actual.Keys) + @($Expected.Keys) | Select-Object -Unique)
        foreach ($key in $allKeys) {
            if (-not $Actual.Contains($key)) { [void]$Diffs.Add("$Path.$key : відсутнє в BRAVO.config"); continue }
            if (-not $Expected.Contains($key)) { [void]$Diffs.Add("$Path.$key : відсутнє в canonical default"); continue }
            Compare-BRAVOConfigurationGraphForParity -Actual $Actual[$key] -Expected $Expected[$key] -Path "$Path.$key" -Diffs $Diffs
        }
        return
    }

    # Wave 1A (Issue #216): попередня версія цього порівняння стрінгіфікувала
    # обидва боки (-join ',' / [string]) ДО порівняння — '5' проти 5, 'True'
    # проти $true, '' проти @(), @('a,b') проти @('a','a') усі виглядали б
    # ІДЕНТИЧНИМИ й diff не з'являвся. $Actual тут завжди пройшов через
    # ConvertTo-Json/ConvertFrom-Json round-trip (пробний процес серіалізує
    # ефективні $global:-значення в JSON), тому точний CLR-тип (Int32 проти
    # Int64) НЕ зберігається навіть для правильних значень — звідси
    # порівняння за категорією типу (Kind), а не за точним .GetType(),
    # інакше кожен цілочисельний leaf хибно позначався б як "тип
    # відрізняється".
    $actualIsArray = ($Actual -is [array])
    $expectedIsArray = ($Expected -is [array])
    if ($actualIsArray -or $expectedIsArray) {
        if (-not ($actualIsArray -and $expectedIsArray)) {
            [void]$Diffs.Add(
                "$Path : BRAVO.config kind=$(Get-BRAVOParityValueKind $Actual) ('$Actual') " +
                "canonical default kind=$(Get-BRAVOParityValueKind $Expected) ('$Expected') — масив проти не-масиву")
            return
        }
        $actualArray = @($Actual)
        $expectedArray = @($Expected)
        if ($actualArray.Count -ne $expectedArray.Count) {
            [void]$Diffs.Add(
                "$Path : довжина масиву BRAVO.config=$($actualArray.Count) ('$($actualArray -join ',')') " +
                "canonical default=$($expectedArray.Count) ('$($expectedArray -join ',')')")
            return
        }
        for ($elementIndex = 0; $elementIndex -lt $actualArray.Count; $elementIndex++) {
            Compare-BRAVOConfigurationGraphForParity `
                -Actual $actualArray[$elementIndex] -Expected $expectedArray[$elementIndex] `
                -Path "$Path[$elementIndex]" -Diffs $Diffs
        }
        return
    }

    $actualKind = Get-BRAVOParityValueKind -Value $Actual
    $expectedKind = Get-BRAVOParityValueKind -Value $Expected
    if ($actualKind -ne $expectedKind) {
        [void]$Diffs.Add(
            "$Path : тип BRAVO.config=$actualKind ('$Actual') тип canonical default=$expectedKind ('$Expected') — тип відрізняється")
        return
    }
    if ($actualKind -eq 'Null') { return }

    $actualText = [string]$Actual
    $expectedText = [string]$Expected
    if ($actualText -ne $expectedText) {
        [void]$Diffs.Add("$Path : BRAVO.config='$actualText' canonical default='$expectedText'")
    }
}

function Get-BRAVOParityValueKind {
    # Категорія типу, а не точний CLR-тип: значення $Actual пройшло через
    # ConvertTo-Json/ConvertFrom-Json (див. коментар вище) — Int32 і Int64
    # обидва мають потрапити в категорію 'Number', інакше типово коректний
    # leaf хибно позначався б як розбіжність типу. String проти Number/
    # Boolean лишаються РІЗНИМИ категоріями навмисно — саме це ловить
    # '5' проти 5 і 'True' проти $true.
    param($Value)
    if ($null -eq $Value) { return 'Null' }
    if ($Value -is [bool]) { return 'Boolean' }
    if ($Value -is [string]) { return 'String' }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or `
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or `
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return 'Number'
    }
    return [string]$Value.GetType().Name
}

$parityDefaultConfiguration = Get-BRAVODefaultConfiguration
# Шлях до legacy-конфігурації бере канонічний accessor (#154, B4-2), а не
# пряма інтерполяція кореня разом з іменем файлу: інакше ця точка
# лишилась би залежністю від кореневого файлу, невидимою для
# Governance/LegacyConfigPathHasSingleOwner — саме так вона й
# ховалась, доки guard дивився тільки на Join-Path.
$committedConfigLegacyPathLiteral = (Get-BRAVOSelfTestLegacyConfigPath).Replace("'", "''")
$committedConfigProbeCommand = (
    "Import-Module -Name '$root\modules\BRAVO.Configuration\BRAVO.Configuration.psd1' -ErrorAction Stop; " +
    "`$default = Get-BRAVODefaultConfiguration; " +
    "`$sb = [scriptblock]::Create([IO.File]::ReadAllText('$committedConfigLegacyPathLiteral', [Text.Encoding]::UTF8)); " +
    "& `$sb -ConfigRoot '$($root.Replace("'", "''"))' -RuntimeRoot '$($root.Replace("'", "''"))'; " +
    "`$primaryRaw = @{}; " +
    "foreach (`$k in @(`$default.Keys)) { `$v = Get-Variable -Name `$k -Scope Global -ErrorAction SilentlyContinue; if (`$null -ne `$v -and `$null -ne `$v.Value) { `$primaryRaw[`$k] = `$v.Value } }; " +
    "ConvertTo-Json -InputObject `$primaryRaw -Depth 20 -Compress"
)
$committedConfigProbeOutput = [string](
    & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $committedConfigProbeCommand 2>&1 | Out-String
)

function ConvertFrom-BRAVOParityPSCustomObject {
    param($InputObject)
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $h[$prop.Name] = ConvertFrom-BRAVOParityPSCustomObject -InputObject $prop.Value
        }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return ,@($InputObject | ForEach-Object { ConvertFrom-BRAVOParityPSCustomObject -InputObject $_ })
    }
    return $InputObject
}

$parityDiffs = $null
$parityParseFailed = $false
try {
    $committedRawParsed = $committedConfigProbeOutput.Trim() | ConvertFrom-Json
    $committedRawHashtable = ConvertFrom-BRAVOParityPSCustomObject -InputObject $committedRawParsed
    $parityDiffsList = New-Object System.Collections.Generic.List[string]
    foreach ($topKey in ($committedRawHashtable.Keys | Sort-Object)) {
        if (-not $parityDefaultConfiguration.Contains($topKey)) { continue }
        Compare-BRAVOConfigurationGraphForParity `
            -Actual $committedRawHashtable[$topKey] -Expected $parityDefaultConfiguration[$topKey] `
            -Path $topKey -Diffs $parityDiffsList
    }
    $parityDiffs = @($parityDiffsList.ToArray())
} catch {
    $parityParseFailed = $true
}

Test-BRAVOCondition `
    -Condition (-not $parityParseFailed -and @($parityDiffs).Count -eq 0) `
    -Name "ConfigLoader/CommittedBravoConfigMatchesCanonicalDefaults" `
    -Failure "committed BRAVO.config НЕ повинен мовчки дублювати canonical product-default ІНШИМ значенням (built-in defaults мають бути єдиним джерелом істини навіть у config-present режимі); parseFailed=$parityParseFailed diffs: $(if ($null -ne $parityDiffs) { $parityDiffs -join ' | ' } else { '(none captured)' })"

# ============================================================
# Wave 1A (Issue #216) — регресійний доказ, що
# Compare-BRAVOConfigurationGraphForParity є type-aware, а не стрінгіфікує
# обидва боки перед порівнянням (історичний ґеп: '5' проти 5, 'True'
# проти $true, '' проти @(), @('a,b') проти @('a','b') раніше виглядали
# ІДЕНТИЧНИМИ). Викликає компаратор напряму (не через повний JSON-пробник
# BRAVO.config), щоб перевірка була детермінованою й не залежала від
# фактичного вмісту committed BRAVO.config.
# ============================================================
$parityTypeAwareCases = @(
    @{ Name = 'StringVsIntSameText'; Actual = @{ sftpPort = '22' }; Expected = @{ sftpPort = 22 }; ExpectDiff = $true }
    @{ Name = 'StringVsIntDifferentText'; Actual = @{ sftpPort = 'STRING-NOT-INT' }; Expected = @{ sftpPort = 22 }; ExpectDiff = $true }
    @{ Name = 'StringVsBoolSameText'; Actual = @{ Flag = 'True' }; Expected = @{ Flag = $true }; ExpectDiff = $true }
    @{ Name = 'EmptyStringVsEmptyArray'; Actual = @{ List = '' }; Expected = @{ List = @() }; ExpectDiff = $true }
    @{ Name = 'JoinedArrayVsSeparateElements'; Actual = @{ List = @('a,b') }; Expected = @{ List = @('a', 'b') }; ExpectDiff = $true }
    @{ Name = 'SameIntDifferentCLRWidth'; Actual = @{ sftpPort = [int64]22 }; Expected = @{ sftpPort = [int32]22 }; ExpectDiff = $false }
    @{ Name = 'IdenticalStrings'; Actual = @{ InstitutionCode = 'ABC' }; Expected = @{ InstitutionCode = 'ABC' }; ExpectDiff = $false }
)
$parityTypeAwareFailures = New-Object System.Collections.Generic.List[string]
foreach ($parityCase in $parityTypeAwareCases) {
    $caseDiffs = New-Object System.Collections.Generic.List[string]
    Compare-BRAVOConfigurationGraphForParity -Actual $parityCase.Actual -Expected $parityCase.Expected -Path 'root' -Diffs $caseDiffs
    $caseHasDiff = ($caseDiffs.Count -gt 0)
    if ($caseHasDiff -ne $parityCase.ExpectDiff) {
        [void]$parityTypeAwareFailures.Add(
            "$($parityCase.Name): очікувалось ExpectDiff=$($parityCase.ExpectDiff), отримано diffCount=$($caseDiffs.Count) ($($caseDiffs -join ' | '))")
    }
}
Test-BRAVOCondition `
    -Condition ($parityTypeAwareFailures.Count -eq 0) `
    -Name "ConfigLoader/ParityComparatorIsTypeAware" `
    -Failure "Compare-BRAVOConfigurationGraphForParity мусить порівнювати тип leaf-значення явно (не -join ',' / [string]-стрінгіфікацію) — провалені кейси: $($parityTypeAwareFailures -join ' ;; ')"

# P0 Configuration Foundation (PR C, Секція 9): BRAVO.local.config —
# site-specific override-шар (LIMSRoot/BackupRoot/розклад/креденшел-таргети
# для конкретного сервера) — не повинен потрапити в git при ручному запуску
# з робочої копії репозиторію (той самий клас ризику, що WinSCP.ini). Текстова
# перевірка .gitignore (не `git check-ignore`): self-test виконується і на
# розгорнутих у клієнта комплектах без .git — git-залежна перевірка там
# просто мовчки не спрацювала б.
$gitignorePath = Join-Path $root '.gitignore'
$gitignoreLines = if (Test-Path -LiteralPath $gitignorePath -PathType Leaf) {
    @(Get-Content -LiteralPath $gitignorePath -Encoding UTF8 | ForEach-Object { $_.Trim() })
} else {
    @()
}
Test-BRAVOCondition `
    -Condition ($gitignoreLines -contains 'BRAVO.local.config') `
    -Name 'ConfigLoader/LocalConfigIsGitignored' `
    -Failure 'BRAVO.local.config (site-specific override-шар) мусить бути в .gitignore окремим рядком — інакше ручний git-запуск із робочої копії міг би закомітити site-дані'

# A1 (#154, знахідка F2 аудиту 2026-09-14): документація мусить описувати
# ФАКТИЧНУ суворість dot-шляху. ConvertTo-BRAVONestedOverride вимагає
# існування лише БАТЬКІВСЬКИХ сегментів; сам leaf існувати не зобов'язаний
# (свідома forward-compat, задокументована в модулі). Документи ж
# стверджували беззастережно "опечатки не мовчать" — і оператор, звіряючись
# із ними, вважав би мовчазно проігнорований ключ застосованим.
#
# Перевіряється текст, а не поведінка: сама поведінка покрита тестами
# ConvertTo-BRAVONestedOverride у Configuration-фрагменті. Тут — саме
# синхронність документації з нею.
$leafDocPaths = @(
    (Join-Path $root 'BRAVO.local.config.example'),
    (Join-Path $root 'BRAVO_SETUP.md')
)
$leafDocProblems = New-Object System.Collections.Generic.List[string]
foreach ($leafDocPath in $leafDocPaths) {
    if (-not (Test-Path -LiteralPath $leafDocPath -PathType Leaf)) {
        [void]$leafDocProblems.Add("$(Split-Path -Leaf $leafDocPath): файл відсутній")
        continue
    }
    $leafDocText = [IO.File]::ReadAllText($leafDocPath, [Text.Encoding]::UTF8)
    $leafDocName = Split-Path -Leaf $leafDocPath
    if ($leafDocText -match 'опечатки\s+не\s+мовчать') {
        [void]$leafDocProblems.Add("${leafDocName}: беззастережна заява 'опечатки не мовчать' суперечить фактичній поведінці leaf")
    }
    if ($leafDocText -notmatch '(?i)forward-compat') {
        [void]$leafDocProblems.Add("${leafDocName}: не описано forward-compat-виняток для останнього сегмента")
    }
    # #154 (A1): після A2 невідомий leaf БІЛЬШЕ НЕ мовчить — є попередження
    # й запис у метадані. Документи описували стан ДО A2 ("буде прийнято
    # мовчки"), тобто відставали від поведінки в протилежний бік. Ім'я поля
    # метаданих — стабільний якір: якщо його немає, документ або не згадує
    # діагностику взагалі, або її прибрали.
    if ($leafDocText -notmatch 'LocalConfigUnknownLeafOverrides') {
        [void]$leafDocProblems.Add("${leafDocName}: не згадано LocalConfigUnknownLeafOverrides — опис відстає від A2, де невідомий leaf став видимим")
    }
}
Test-BRAVOCondition `
    -Condition ($leafDocProblems.Count -eq 0) `
    -Name 'ConfigLoader/LocalConfigLeafSemanticsDocumentedAccurately' `
    -Failure ("документація BRAVO.local.config мусить описувати несиметричну суворість dot-шляху (батьківські сегменти — fail-closed, leaf — forward-compat): " +
        (($leafDocProblems.ToArray()) -join '; '))

# ============================================================
# #154 (A3/F1): симетрія ДІАГНОСТИКИ primary-шару.
# ============================================================
# Site-шар fail-closed на невідомий батьківський вузол і (з A2) звітує про
# невідомий leaf. Primary-шар доти мовчав в обох випадках: невідомий
# top-level $global: не потрапляв в allowlist-збірку й зникав безслідно,
# невідомий вкладений ключ мовчки зливався. Поведінка прийому НЕ змінена —
# перевіряється саме ВИДИМІСТЬ.
#
# Окремий child scope (& { ... }): усі фрагменти self-test дот-сорсяться в
# ОДИН scope і ділять ліміт $MaximumVariableCount.
& {
    $strictnessBackupRootDir = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_PRIMARY_STRICTNESS_BACKUP_{0}" -f [guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($strictnessBackupRootDir)

    function New-BRAVOConfigLoaderPrimaryStrictnessProbe {
        # Сценарій-корінь із КОПІЄЮ реального BRAVO.config (плюс, за потреби,
        # додані рядки) — той самий підхід, що й у parity-проб вище.
        # Дочірній процес обов'язковий: Import-BravoConfiguration встановлює
        # десятки $global:, змішувати які з рештою прогону не можна.
        param([string]$ExtraConfigBody = '')

        $scenarioRoot = Join-Path ([IO.Path]::GetTempPath()) (
            "BRAVO_PRIMARY_STRICTNESS_{0}" -f [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($scenarioRoot)
        try {
            $primaryText = (Get-BRAVOSelfTestLegacyConfigText)
            if (-not [string]::IsNullOrEmpty($ExtraConfigBody)) {
                $primaryText = $primaryText + "`r`n" + $ExtraConfigBody + "`r`n"
            }
            [IO.File]::WriteAllText((Join-Path $scenarioRoot 'BRAVO.config'), $primaryText, (New-Object System.Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText(
                (Join-Path $scenarioRoot 'BRAVO.local.config'),
                # Конкатенація, а не -f: рядок містить літеральні @{ і },
                # які оператор форматування витлумачив би як плейсхолдери.
                ("@{`r`n    'pathSettings.BackupRoot' = '" + $strictnessBackupRootDir.Replace("'", "''") + "'`r`n}`r`n"),
                (New-Object System.Text.UTF8Encoding($false)))

            $probeCommand = (
                "try { " +
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "[void](Import-BravoConfiguration -ConfigRoot '$scenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
                "'RESULT:IGNORED=' + ((@(`$global:BravoConfigurationMetadata.PrimaryConfigIgnoredGlobals)) -join '|') + " +
                "';UNKNOWN=' + ((@(`$global:BravoConfigurationMetadata.PrimaryConfigUnknownNestedKeys)) -join '|') + " +
                "';OVERRIDES=' + ((@(`$global:BravoConfigurationMetadata.PrimaryConfigOverridesCanonicalDefaults)) -join '|')" +
                "} catch { 'THREW: ' + `$_.Exception.Message }"
            )
            $probeOutput = [string](
                & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $probeCommand 2>&1 | Out-String
            )
            return $probeOutput.Trim()
        } finally {
            Remove-Item -LiteralPath $scenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    try {
        # --- PrimaryStrictness/PristineConfigProducesNoDiagnostics ---
        # НАЙВАЖЛИВІШЕ: комплектний BRAVO.config не сміє давати жодного
        # попередження. Інакше кожен сервер отримав би шум на кожному
        # запуску кожного entrypoint-а, і діагностика знецінилась би.
        $strictnessPristine = New-BRAVOConfigLoaderPrimaryStrictnessProbe
        Test-BRAVOCondition `
            -Condition ($strictnessPristine -eq 'RESULT:IGNORED=;UNKNOWN=;OVERRIDES=') `
            -Name "PrimaryStrictness/PristineConfigProducesNoDiagnostics" `
            -Failure "комплектний BRAVO.config має давати ПОРОЖНІ PrimaryConfigIgnoredGlobals, PrimaryConfigUnknownNestedKeys і PrimaryConfigOverridesCanonicalDefaults; отримано '$strictnessPristine'"

        # --- ConfigV2/StaleLegacyConfigCannotSilentlyOverrideDefaults ---
        # Ядро B4. Застарілий BRAVO.config (значення епохи попередньої
        # версії) і далі ПРАЦЮЄ — забрати його зараз означало б забрати в
        # серверів їхні налаштування, бо міграція парку (B5) ще не
        # виконана. Але він більше не МОВЧИТЬ: конкретний dot-шлях, який
        # він затінює, потрапляє в метадані завантаження.
        $strictnessStaleOverride = New-BRAVOConfigLoaderPrimaryStrictnessProbe `
            -ExtraConfigBody '$global:logRetentionDays = 999'
        Test-BRAVOCondition `
            -Condition (
                $strictnessStaleOverride.Contains('OVERRIDES=logRetentionDays') -and
                -not $strictnessStaleOverride.StartsWith('THREW')
            ) `
            -Name "ConfigV2/StaleLegacyConfigCannotSilentlyOverrideDefaults" `
            -Failure "BRAVO.config, що відхиляється від канонічного дефолту, мусить називати конкретний шлях у PrimaryConfigOverridesCanonicalDefaults і при цьому НЕ ламати завантаження; отримано '$strictnessStaleOverride'"

        # --- PrimaryStrictness/UnknownTopLevelGlobalReported ---
        # Сьогодні така змінна зникає безслідно: allowlist-збірка бере лише
        # ключі Get-BRAVODefaultConfiguration, решта не потрапляє нікуди.
        $strictnessUnknownGlobal = New-BRAVOConfigLoaderPrimaryStrictnessProbe `
            -ExtraConfigBody '$global:selfTestObsoleteKnob = 42'
        Test-BRAVOCondition `
            -Condition (
                $strictnessUnknownGlobal.Contains('IGNORED=selfTestObsoleteKnob') -and
                $strictnessUnknownGlobal.Contains('UNKNOWN=')
            ) `
            -Name "PrimaryStrictness/UnknownTopLevelGlobalReported" `
            -Failure "невідомий top-level `$global: у BRAVO.config має потрапити в PrimaryConfigIgnoredGlobals; отримано '$strictnessUnknownGlobal'"

        # --- PrimaryStrictness/UnknownNestedKeyReported ---
        # Індексне присвоєння, а не $global:x = — навмисно: так перевіряється
        # саме ВКЛАДЕНИЙ шлях, і воно не має рахуватись оголошенням
        # top-level змінної (інакше тест проходив би з хибної причини).
        $strictnessUnknownNested = New-BRAVOConfigLoaderPrimaryStrictnessProbe `
            -ExtraConfigBody "`$global:pathSettings['SelfTestUnknownNestedKey'] = 'x'"
        Test-BRAVOCondition `
            -Condition (
                $strictnessUnknownNested.Contains('UNKNOWN=pathSettings.SelfTestUnknownNestedKey') -and
                $strictnessUnknownNested.Contains('IGNORED=;')
            ) `
            -Name "PrimaryStrictness/UnknownNestedKeyReported" `
            -Failure "невідомий вкладений ключ BRAVO.config має потрапити в PrimaryConfigUnknownNestedKeys і НЕ потрапити в IgnoredGlobals; отримано '$strictnessUnknownNested'"

        # --- PrimaryStrictness/DiagnosticsNeverRejectConfiguration ---
        # A3 — діагностика, а не новий fail-closed: обидва сценарії вище
        # мусять ЗАВАНТАЖИТИСЬ. Рішення про сувору відмову — окреме (D3).
        Test-BRAVOCondition `
            -Condition (
                -not $strictnessUnknownGlobal.StartsWith('THREW') -and
                -not $strictnessUnknownNested.StartsWith('THREW')
            ) `
            -Name "PrimaryStrictness/DiagnosticsNeverRejectConfiguration" `
            -Failure "невідомий ключ primary-шару має лишатись ПРИЙНЯТИМ (діагностика, не gate); global='$strictnessUnknownGlobal' nested='$strictnessUnknownNested'"

        # --- PrimaryStrictness/DeclaredGlobalNameHelperReturnsNames ---
        # Пряма перевірка самого helper-а, а не лише його наслідків: перша
        # реалізація читала VariablePath.UnqualifiedPath, якої в
        # System.Management.Automation.VariablePath Windows PowerShell 5.1
        # ПУБЛІЧНО немає — завантаження конфігурації падало цілком
        # ("The property 'UnqualifiedPath' cannot be found on this object",
        # CI 2026-09-14). Текстовий guard нижче такого не ловить.
        $strictnessHelperCommand = (
            "try { " +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "`$sb = [scriptblock]::Create('`$global:alpha = 1; `$global:beta = @{}; `$local:gamma = 3; `$delta = 4'); " +
            "'RESULT:' + ((@(Get-BRAVODeclaredGlobalVariableName -ScriptBlock `$sb) | Sort-Object) -join '|')" +
            "} catch { 'THREW: ' + `$_.Exception.Message }"
        )
        # Два кроки, а не [string](...).Trim(): у PowerShell приведення типу
        # зв'язується СЛАБШЕ за виклик методу, тож однорядковий варіант
        # означав би [string]($output.Trim()) — не те, що записано.
        $strictnessHelperRaw = [string](
            & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $strictnessHelperCommand 2>&1 | Out-String
        )
        $strictnessHelperOutput = $strictnessHelperRaw.Trim()
        Test-BRAVOCondition `
            -Condition ($strictnessHelperOutput -eq 'RESULT:alpha|beta') `
            -Name "PrimaryStrictness/DeclaredGlobalNameHelperReturnsNames" `
            -Failure "Get-BRAVODeclaredGlobalVariableName має повертати ІМЕНА без префікса scope і лише для `$global: (очікувалось 'RESULT:alpha|beta'); отримано '$strictnessHelperOutput'"

        # --- PrimaryStrictness/DeclaredGlobalNamesFromAstNotSnapshot ---
        # Guard від регресії в бік знімка глобальної області: знімок ДО/ПІСЛЯ
        # дав би шум рантайму й пропустив би присвоєння наявній змінній.
        $strictnessLoaderText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_CONFIG_LOADER.ps1'), [Text.Encoding]::UTF8)
        Test-BRAVOCondition `
            -Condition (
                $strictnessLoaderText.Contains('AssignmentStatementAst') -and
                $strictnessLoaderText.Contains('VariablePath.IsGlobal')
            ) `
            -Name "PrimaryStrictness/DeclaredGlobalNamesFromAstNotSnapshot" `
            -Failure "перелік оголошених BRAVO.config top-level `$global: мусить будуватись з AST (AssignmentStatementAst + VariablePath.IsGlobal), а не зі знімка глобальної області"
    } finally {
        Remove-Item -LiteralPath $strictnessBackupRootDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# Wave 2 (#216): атомарність авторизаційного шару BRAVO.local.config
# =====================================================================
# Наскрізний тест реального production-конвеєра loader-а (не лише
# ізольованої Test-BRAVOConfigurationOverrideAuthorization) — доводить,
# що ОДИН denied-лист у файлі з кількома override-ами зупиняє мердж ДО
# того, як хоч ОДИН, у т.ч. валідний, override застосувався (WAVE2-CONTRACT.md,
# розділ 11.2/11.6, тест-кейс 12).
& {
    $atomicityBackupRootDir = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_AUTHATOMIC_BACKUP_{0}" -f [guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($atomicityBackupRootDir)
    $atomicityBackupRootLiteral = $atomicityBackupRootDir.Replace("'", "''")

    function New-BRAVOConfigLoaderAtomicityProbe {
        param(
            [Parameter(Mandatory = $true)][string]$LocalConfigBody
        )
        $scenarioRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_AUTHATOMIC_{0}" -f [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($scenarioRoot)
        try {
            [IO.File]::WriteAllText((Join-Path $scenarioRoot 'BRAVO.local.config'), $LocalConfigBody, (New-Object System.Text.UTF8Encoding($false)))
            # Перевірка стану ВСЕРЕДИНІ catch — якщо Import-BravoConfiguration
            # кидає виняток ДО Set-Variable-проєкції top-level ключів
            # (Complete-BRAVOConfigurationLoad), $global:archiveRetentionDays
            # НІКОЛИ не оголошується в цьому дочірньому процесі. Це прямий
            # доказ атомарності (не лише "виняток кинуто", а "жоден валідний
            # override з того самого файлу не потрапив у ефективний стан").
            $probeCommand = (
                "try { " +
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "[void](Import-BravoConfiguration -ConfigRoot '$scenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
                "'NOTHREW:ArchiveRetentionDays=' + [string]`$global:archiveRetentionDays " +
                "} catch { " +
                "`$archiveVar = Get-Variable -Name 'archiveRetentionDays' -Scope Global -ErrorAction SilentlyContinue; " +
                "`$archiveState = if (`$null -eq `$archiveVar) { '<unset>' } else { [string]`$archiveVar.Value }; " +
                "'THREW:' + `$_.Exception.Message + ';ArchiveRetentionDaysAfterThrow=' + `$archiveState" +
                "}"
            )
            $probeOutput = [string](
                & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $probeCommand 2>&1 | Out-String
            )
            return $probeOutput.Trim()
        } finally {
            Remove-Item -LiteralPath $scenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    try {
        # --- Authorization/LoaderAtomicMergeRejectsWholeLocalLayer ---
        # Один валідний ALLOW_SITE override (archiveRetentionDays) РАЗОМ з
        # одним DENY_EXECUTION_CONTROL override (BravoName) в ОДНОМУ файлі.
        $atomicityMixedBody = (
            "@{`r`n" +
            "    'pathSettings.BackupRoot' = '$atomicityBackupRootLiteral'`r`n" +
            "    'archiveRetentionDays' = 999`r`n" +
            "    'maintenanceSettings.Services.BravoName' = 'EvilService'`r`n" +
            "}`r`n"
        )
        $atomicityMixedResult = New-BRAVOConfigLoaderAtomicityProbe -LocalConfigBody $atomicityMixedBody
        Test-BRAVOCondition `
            -Condition (
                $atomicityMixedResult.StartsWith('THREW:') -and
                $atomicityMixedResult.Contains('неавторизоване перевизначення') -and
                $atomicityMixedResult.Contains('ArchiveRetentionDaysAfterThrow=<unset>')
            ) `
            -Name "Authorization/LoaderAtomicMergeRejectsWholeLocalLayer" `
            -Failure "мішаний local-config (1 валідний ALLOW_SITE + 1 DENY_EXECUTION_CONTROL) мусить fail closed ЦІЛИМ шаром, і archiveRetentionDays НЕ повинен потрапити в ефективний `$global:-стан навіть частково; отримано: $atomicityMixedResult"

        # --- Authorization/LoaderAtomicMergeSanityAllValidStillApplies ---
        # Контрольний sanity-кейс: без denied-листа той самий валідний
        # override застосовується нормально (доводить, що попередній тест
        # не є хибним провалом самого archiveRetentionDays-шляху).
        $atomicitySafeBody = (
            "@{`r`n" +
            "    'pathSettings.BackupRoot' = '$atomicityBackupRootLiteral'`r`n" +
            "    'archiveRetentionDays' = 999`r`n" +
            "}`r`n"
        )
        $atomicitySafeResult = New-BRAVOConfigLoaderAtomicityProbe -LocalConfigBody $atomicitySafeBody
        Test-BRAVOCondition `
            -Condition ($atomicitySafeResult -eq 'NOTHREW:ArchiveRetentionDays=999') `
            -Name "Authorization/LoaderAtomicMergeSanityAllValidStillApplies" `
            -Failure "той самий archiveRetentionDays=999 БЕЗ denied-листа мусить застосуватись нормально (sanity-контроль для атомарного тесту вище); отримано: $atomicitySafeResult"

        # --- Authorization/LoaderRejectsDeniedLeafAloneWithSameMessage ---
        $atomicityDenyOnlyBody = (
            "@{`r`n" +
            "    'pathSettings.BackupRoot' = '$atomicityBackupRootLiteral'`r`n" +
            "    'maintenanceSettings.Services.BravoName' = 'EvilService'`r`n" +
            "}`r`n"
        )
        $atomicityDenyOnlyResult = New-BRAVOConfigLoaderAtomicityProbe -LocalConfigBody $atomicityDenyOnlyBody
        Test-BRAVOCondition `
            -Condition (
                $atomicityDenyOnlyResult.StartsWith('THREW:') -and
                $atomicityDenyOnlyResult.Contains('неавторизоване перевизначення') -and
                $atomicityDenyOnlyResult.Contains('maintenanceSettings.Services.BravoName')
            ) `
            -Name "Authorization/LoaderRejectsDeniedLeafAloneWithSameMessage" `
            -Failure "лише denied-лист (без сусіднього валідного override) мусить так само fail closed з тим самим повідомленням, що називає точний шлях; отримано: $atomicityDenyOnlyResult"

        # --- Authorization/LoaderAtomicMergeRejectsWholeLocalLayerNestedForm ---
        # PR #224 review, F1 (section 4): дзеркало
        # LoaderAtomicMergeRejectsWholeLocalLayer вище, але DENY-лист
        # супроводжується ВКЛАДЕНОЮ (hashtable-значення) Node-формою
        # (maintenanceSettings.Services = @{ BravoName = 'EvilService' }),
        # не пласким dot-шляхом. Той самий ізольований (без BRAVO.config)
        # probe, тому archiveRetentionDays справді <unset> до спроби —
        # доводить, що вкладена форма fail-closed ЦІЛИМ loader-конвеєром
        # ДО merge так само атомарно, як пласка.
        $atomicityNestedBody = (
            "@{`r`n" +
            "    'pathSettings.BackupRoot' = '$atomicityBackupRootLiteral'`r`n" +
            "    'archiveRetentionDays' = 999`r`n" +
            "    'maintenanceSettings.Services' = @{`r`n" +
            "        'BravoName' = 'EvilService'`r`n" +
            "    }`r`n" +
            "}`r`n"
        )
        $atomicityNestedResult = New-BRAVOConfigLoaderAtomicityProbe -LocalConfigBody $atomicityNestedBody
        Test-BRAVOCondition `
            -Condition (
                $atomicityNestedResult.StartsWith('THREW:') -and
                $atomicityNestedResult.Contains('неавторизоване перевизначення') -and
                $atomicityNestedResult.Contains('maintenanceSettings.Services.BravoName') -and
                $atomicityNestedResult.Contains('ArchiveRetentionDaysAfterThrow=<unset>')
            ) `
            -Name "Authorization/LoaderAtomicMergeRejectsWholeLocalLayerNestedForm" `
            -Failure "вкладений (hashtable-значення) Node-override, чий єдиний дочірній лист DENY_EXECUTION_CONTROL, мусить fail closed ЦІЛИМ loader-конвеєром ДО merge (сусідній ALLOW_SITE archiveRetentionDays=999 НЕ повинен потрапити в `$global:-стан); отримано: $atomicityNestedResult"
    } finally {
        Remove-Item -LiteralPath $atomicityBackupRootDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
