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
