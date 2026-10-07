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

# ============================================================
# Батч-раннер проб loader-а: ОДИН дочірній powershell.exe на фрагмент
# замість окремого процесу на кожну пробу (старт процесу ≈1,8–2 с).
# Ізоляцію дає свіжий runspace на кожну пробу
# ([runspacefactory]::CreateRunspace() + [powershell]::Create()):
# власні глобальні змінні, функції, модулі й StrictMode, як у нового
# процесу. Спільне на процес — змінні середовища й поточний каталог .NET;
# раннер знімає їх перед першою пробою й відновлює після КОЖНОЇ проби
# (проби ставлять BRAVO_ALLOW_WEAKENED_SECURITY).
#
# Протокол: батько записує текст проби в probe-<N>.ps1 і передає N рядком
# у stdin раннера; раннер виконує пробу, пише result-<N>.txt (вивід,
# включно з помилками й попередженнями, як колись 2>&1 | Out-String) і
# result-<N>.meta (PID і канарки ізоляції), а тоді відповідає "DONE <N>".
# Кожна проба лишається синхронним викликом на тому самому місці, тож
# порядок файлових фікстур між пробами не змінився.
#
# Fail-closed: якщо раннер не стартував, упав або проба не записала
# результат, Invoke-BRAVOConfigLoaderProbe повертає текст із маркером
# BRAVO-CONFIGLOADER-PROBE-NO-RESULT. Жодна позитивна умова перевірок його
# не задовольняє, а перевірки з лише заперечними умовами додатково
# звіряються з Test-BRAVOConfigLoaderProbeCompleted. Окрема перевірка
# ConfigLoader/ProbesShareOneChildProcess (секція ConfigLoader/Authorization)
# звіряє кількість проб і результатів, один PID і канарки ізоляції.
#
# Окремим процесом лишаються лише запуски, де важить код виходу або
# entrypoint: BRAVO_DRY_RUN.ps1, Invoke-BRAVOSelfTestEffectiveSnapshotCapture
# (exit 1 + ExitCode) і deploy\Get-BRAVOConfigSiteDelta.ps1.
# ============================================================
$script:BRAVOConfigLoaderProbeWorker = @{
    Root     = $null
    Process  = $null
    Issued   = 0
    Failure  = ''
    Results  = (New-Object System.Collections.ArrayList)
    NoResult = 'BRAVO-CONFIGLOADER-PROBE-NO-RESULT'
}

function Start-BRAVOConfigLoaderProbeWorker {
    $probeWorker = $script:BRAVOConfigLoaderProbeWorker
    $probeWorker.Root = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_CONFIGLOADER_PROBES_{0}" -f [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($probeWorker.Root)
    $probeRunnerText = @'
param($BRAVOConfigLoaderProbeState)
# Виконується у СВІЖОМУ runspace раннера, у глобальній області (як
# powershell.exe -Command). Канарки: жодна не має бути видна з попередньої
# проби — глобальну змінну прибирає новий runspace, змінну середовища
# відновлює раннер.
if ($null -ne (Get-Variable -Name 'BRAVOConfigLoaderProbeCanary' -Scope Global -ErrorAction SilentlyContinue)) {
    [void]$BRAVOConfigLoaderProbeState.Leaks.Add('global:BRAVOConfigLoaderProbeCanary')
}
if ($null -ne [Environment]::GetEnvironmentVariable('BRAVO_CONFIGLOADER_PROBE_CANARY')) {
    [void]$BRAVOConfigLoaderProbeState.Leaks.Add('env:BRAVO_CONFIGLOADER_PROBE_CANARY')
}
try {
    do {
        . ([scriptblock]::Create([string]$BRAVOConfigLoaderProbeState.Command)) 2>&1 3>&1 |
            Out-String -Stream |
            ForEach-Object { [void]$BRAVOConfigLoaderProbeState.Lines.Add([string]$_) }
    } while ($false)
} catch {
    [void]$BRAVOConfigLoaderProbeState.Lines.Add([string]($_ | Out-String))
}
$global:BRAVOConfigLoaderProbeCanary = $BRAVOConfigLoaderProbeState.Index
[Environment]::SetEnvironmentVariable('BRAVO_CONFIGLOADER_PROBE_CANARY', [string]$BRAVOConfigLoaderProbeState.Index)
$BRAVOConfigLoaderProbeState.Completed = $true
'@
    $probeWorkerText = @'
# Раннер проб BRAVO_SELF_TEST.ConfigLoader.ps1 (див. коментар у фрагменті).
$ErrorActionPreference = 'Stop'
$probeUtf8 = New-Object System.Text.UTF8Encoding($false)
$probeRunnerText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'runner.ps1'), [Text.Encoding]::UTF8)
$probeEnvironmentBaseline = @{}
foreach ($probeEnvironmentEntry in @(Get-ChildItem -Path 'Env:')) {
    $probeEnvironmentBaseline[$probeEnvironmentEntry.Name] = [string]$probeEnvironmentEntry.Value
}
$probeCurrentDirectory = [Environment]::CurrentDirectory
while ($true) {
    $probeRequest = [Console]::In.ReadLine()
    if ($null -eq $probeRequest) { break }
    if ($probeRequest -notmatch '(\d+)') { continue }
    $probeIndex = [int]$Matches[1]
    try {
        $probeState = @{
            Index     = $probeIndex
            Command   = [IO.File]::ReadAllText((Join-Path $PSScriptRoot ('probe-{0}.ps1' -f $probeIndex)), [Text.Encoding]::UTF8)
            Lines     = (New-Object System.Collections.ArrayList)
            Leaks     = (New-Object System.Collections.ArrayList)
            Completed = $false
        }
        $probeRunspace = $null
        $probeShell = $null
        try {
            $probeRunspace = [runspacefactory]::CreateRunspace()
            $probeRunspace.Open()
            $probeShell = [powershell]::Create()
            $probeShell.Runspace = $probeRunspace
            [void]$probeShell.AddScript($probeRunnerText).AddArgument($probeState)
            [void]$probeShell.Invoke()
        } finally {
            if ($null -ne $probeShell) { $probeShell.Dispose() }
            if ($null -ne $probeRunspace) { $probeRunspace.Dispose() }
            foreach ($probeEnvironmentEntry in @(Get-ChildItem -Path 'Env:')) {
                if (-not $probeEnvironmentBaseline.ContainsKey($probeEnvironmentEntry.Name)) {
                    # Remove-Item, а не SetEnvironmentVariable(name, $null): PowerShell
                    # передає $null у string-параметр як '', а порожнє значення
                    # видаляє змінну лише в .NET Framework.
                    Remove-Item -LiteralPath ('Env:' + $probeEnvironmentEntry.Name) -ErrorAction SilentlyContinue
                }
            }
            foreach ($probeEnvironmentName in @($probeEnvironmentBaseline.Keys)) {
                if ([Environment]::GetEnvironmentVariable($probeEnvironmentName) -cne $probeEnvironmentBaseline[$probeEnvironmentName]) {
                    [Environment]::SetEnvironmentVariable($probeEnvironmentName, $probeEnvironmentBaseline[$probeEnvironmentName])
                }
            }
            [Environment]::CurrentDirectory = $probeCurrentDirectory
        }
        if (-not $probeState.Completed) { throw 'runspace проби не дійшов до кінця' }
        [IO.File]::WriteAllText((Join-Path $PSScriptRoot ('result-{0}.txt' -f $probeIndex)),
            (([string]::Join("`r`n", @($probeState.Lines | ForEach-Object { [string]$_ }))) + "`r`n"), $probeUtf8)
        [IO.File]::WriteAllText((Join-Path $PSScriptRoot ('result-{0}.meta' -f $probeIndex)),
            ('{0}{1}{2}' -f $PID, "`t", ([string]::Join(',', @($probeState.Leaks | ForEach-Object { [string]$_ })))), $probeUtf8)
    } catch {
        [IO.File]::WriteAllText((Join-Path $PSScriptRoot ('result-{0}.error' -f $probeIndex)), [string]$_.Exception.Message, $probeUtf8)
    }
    [Console]::Out.WriteLine(('DONE {0}' -f $probeIndex))
    [Console]::Out.Flush()
}
'@
    $probeBomUtf8 = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText((Join-Path $probeWorker.Root 'runner.ps1'), $probeRunnerText, $probeBomUtf8)
    [IO.File]::WriteAllText((Join-Path $probeWorker.Root 'worker.ps1'), $probeWorkerText, $probeBomUtf8)
    $probeStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $probeStartInfo.FileName = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $probeStartInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
        (Join-Path $probeWorker.Root 'worker.ps1') + '"'
    $probeStartInfo.UseShellExecute = $false
    $probeStartInfo.RedirectStandardInput = $true
    $probeStartInfo.RedirectStandardOutput = $true
    $probeWorker.Process = [System.Diagnostics.Process]::Start($probeStartInfo)
}

function Invoke-BRAVOConfigLoaderProbe {
    # Виконує текст проби (те, що раніше йшло в powershell.exe -Command)
    # у свіжому runspace спільного дочірнього раннера й повертає вивід
    # рядком; -AsLines — масивом рядків, як нативний вивід без Out-String.
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$AsLines
    )
    $probeWorker = $script:BRAVOConfigLoaderProbeWorker
    if ($null -eq $probeWorker.Process -and [string]::IsNullOrEmpty($probeWorker.Failure)) {
        try {
            Start-BRAVOConfigLoaderProbeWorker
        } catch {
            $probeWorker.Failure = "раннер проб не стартував: $($_.Exception.Message)"
        }
    }
    $probeWorker.Issued = [int]$probeWorker.Issued + 1
    $probeIndex = [int]$probeWorker.Issued
    $probeText = $null
    $probeReason = ''
    if ([string]::IsNullOrEmpty($probeWorker.Failure)) {
        try {
            [IO.File]::WriteAllText((Join-Path $probeWorker.Root "probe-$probeIndex.ps1"), $Command, (New-Object System.Text.UTF8Encoding($true)))
            $probeWorker.Process.StandardInput.WriteLine([string]$probeIndex)
            $probeAck = $null
            do {
                $probeAck = $probeWorker.Process.StandardOutput.ReadLine()
            } while ($null -ne $probeAck -and $probeAck -notmatch ('(^|\W)DONE ' + $probeIndex + '$'))
            if ($null -eq $probeAck) {
                $probeExitText = if ($probeWorker.Process.WaitForExit(5000)) { [string]$probeWorker.Process.ExitCode } else { 'н/д' }
                $probeWorker.Failure = "раннер проб завершився (код виходу $probeExitText)"
            }
        } catch {
            $probeWorker.Failure = "зв'язок із раннером проб втрачено: $($_.Exception.Message)"
        }
        $probeResultPath = Join-Path $probeWorker.Root "result-$probeIndex.txt"
        $probeMetaPath = Join-Path $probeWorker.Root "result-$probeIndex.meta"
        $probeErrorPath = Join-Path $probeWorker.Root "result-$probeIndex.error"
        if ((Test-Path -LiteralPath $probeResultPath -PathType Leaf) -and (Test-Path -LiteralPath $probeMetaPath -PathType Leaf)) {
            $probeText = [IO.File]::ReadAllText($probeResultPath, [Text.Encoding]::UTF8)
            $probeMeta = [IO.File]::ReadAllText($probeMetaPath, [Text.Encoding]::UTF8).Split("`t")
            [void]$probeWorker.Results.Add([pscustomobject]@{
                    Index     = $probeIndex
                    ProcessId = [string]$probeMeta[0]
                    Leaks     = $(if ($probeMeta.Count -gt 1) { [string]$probeMeta[1] } else { '' })
                })
        } elseif (Test-Path -LiteralPath $probeErrorPath -PathType Leaf) {
            $probeReason = "збій раннера: $([IO.File]::ReadAllText($probeErrorPath, [Text.Encoding]::UTF8))"
        }
    }
    if ($null -eq $probeText) {
        if ([string]::IsNullOrEmpty($probeReason)) {
            $probeReason = $(if ([string]::IsNullOrEmpty($probeWorker.Failure)) { 'файл результату відсутній' } else { $probeWorker.Failure })
        }
        $probeText = "$($probeWorker.NoResult): проба #$probeIndex не записала результат ($probeReason)`r`n"
    }
    if ($AsLines) {
        return @($probeText.TrimEnd() -split "`r?`n")
    }
    return $probeText
}

function Test-BRAVOConfigLoaderProbeCompleted {
    # $false, якщо замість виводу проби повернуто маркер відсутнього
    # результату (fail-closed для перевірок лише із заперечними умовами).
    param([AllowNull()][AllowEmptyString()][string]$Output)
    return -not ([string]$Output).Contains($script:BRAVOConfigLoaderProbeWorker.NoResult)
}

function Stop-BRAVOConfigLoaderProbeWorker {
    # Закритий stdin завершує цикл раннера; наступна проба (якщо буде)
    # запустить новий раннер із чистим обліком.
    $probeWorker = $script:BRAVOConfigLoaderProbeWorker
    if ($null -ne $probeWorker.Process) {
        try {
            $probeWorker.Process.StandardInput.Close()
            if (-not $probeWorker.Process.WaitForExit(30000)) { $probeWorker.Process.Kill() }
        } catch {
            $null = $_
        }
        $probeWorker.Process.Dispose()
    }
    if (-not [string]::IsNullOrEmpty($probeWorker.Root)) {
        Remove-Item -LiteralPath $probeWorker.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
    $probeWorker.Root = $null
    $probeWorker.Process = $null
    $probeWorker.Issued = 0
    $probeWorker.Failure = ''
    $probeWorker.Results.Clear()
}

if (Enter-BRAVOSelfTestSection -Name 'ConfigLoader/OriginalExceptionMessageNotLost') { try {
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

    # Окремий runspace у дочірньому раннері проб: Import-BravoConfiguration
    # встановлює $global:ScriptVersion/$global:BravoConfigurationMetadata та
    # інший глобальний стан, який небезпечно змішувати з рештою
    # self-test-прогону в тому самому процесі.
    $childOutput = Invoke-BRAVOConfigLoaderProbe -Command @"
`$ErrorActionPreference = 'Stop'
try {
    . '$configLoaderPath'
    Import-BravoConfiguration -ConfigRoot '$configLoaderScenarioRoot' -ConfigPath '$syntheticConfigPath' -RuntimeRoot '$root'
    Write-Output 'NO_ERROR_THROWN'
} catch {
    Write-Output `$_.Exception.Message
}
"@

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
            (Test-BRAVOConfigLoaderProbeCompleted -Output $configLoaderErrorMessage) -and
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
# оновлення комплекту. Кожен сценарій — ізольований runspace у дочірньому
# раннері проб (Import-BravoConfiguration змінює глобальний стан).
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
    $localCfgProbe = Invoke-BRAVOConfigLoaderProbe -AsLines -Command (
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
        )
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
    $localCfgNestedProbe = Invoke-BRAVOConfigLoaderProbe -AsLines -Command (
            "Set-StrictMode -Version 2.0; " +
            "try { " +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "[void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); " +
            "'{0}|{1}' -f [string]`$global:bravoSettings.NotificationRouting.SUCCESS, " +
            "[string]`$global:bravoSettings.NotificationRouting.WARNING " +
            "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
        )
    $localCfgNestedProbeLast = ([string](@($localCfgNestedProbe)[-1])).Trim()
    Test-BRAVOCondition `
        -Condition ($localCfgNestedProbeLast -eq 'general|alerts') `
        -Name "ConfigLoader/NestedNodeOverrideReachesMergeAndAppliesPerLeaf" `
        -Failure "вкладений (hashtable-значення) Node-override bravoSettings.NotificationRouting мусить пройти авторизацію по кожному дочірньому листу окремо й дійти до merge/global стану; отримано: '$localCfgNestedProbeLast'"

    # --- Loader/DefaultLogLevelWhitespaceCompatibility (PR #224 review,
    # четвертий раунд, P2 "Preserve trimming for defaultLogLevel"):
    # defaultLogLevel=' ERROR ' (пробіли навколо) мусить пройти весь
    # loader-конвеєр БЕЗ throw — доведена pre-Wave-2 tolerance, бо
    # Write-Log сам робить .Trim().ToUpperInvariant() перед використанням
    # значення. Регресія перевіряється через реальний Import-BravoConfiguration
    # (не лише ізольований виклик валідатора вище).
    [IO.File]::WriteAllText($localCfgOverridePath, (
        "@{`r`n" +
        "    'defaultLogLevel' = ' ERROR '`r`n" +
        "}`r`n"
    ), (New-Object System.Text.UTF8Encoding $false))
    $localCfgDefaultLogLevelProbe = Invoke-BRAVOConfigLoaderProbe -AsLines -Command (
            "Set-StrictMode -Version 2.0; " +
            "try { " +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "[void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); " +
            "'NOTHREW:' + [string]`$global:defaultLogLevel " +
            "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
        )
    $localCfgDefaultLogLevelProbeLast = ([string](@($localCfgDefaultLogLevelProbe)[-1])).Trim()
    Test-BRAVOCondition `
        -Condition ($localCfgDefaultLogLevelProbeLast -eq 'NOTHREW: ERROR') `
        -Name "Loader/DefaultLogLevelWhitespaceCompatibility" `
        -Failure "defaultLogLevel=' ERROR ' (з пробілами) мусить проходити реальний Import-BravoConfiguration без throw і без мутації сирого значення; отримано: '$localCfgDefaultLogLevelProbeLast'"

    # --- Loader/OutputEncodingCodePageZeroCompatibility (PR #224 review,
    # п'яте коло, P2 "Permit the valid Windows code page zero"):
    # consoleSettings.OutputEncodingCodePage=0 мусить проходити весь
    # loader-конвеєр БЕЗ throw — [System.Text.Encoding]::GetEncoding(0),
    # реальний production-споживач (BRAVO.Archive.Runtime.ps1), сам
    # приймає 0 (системна ANSI code page). Регресія перевіряється через
    # реальний Import-BravoConfiguration (не лише ізольований виклик
    # валідатора вище).
    [IO.File]::WriteAllText($localCfgOverridePath, (
        "@{`r`n" +
        "    'consoleSettings.OutputEncodingCodePage' = 0`r`n" +
        "}`r`n"
    ), (New-Object System.Text.UTF8Encoding $false))
    $localCfgCodePageProbe = Invoke-BRAVOConfigLoaderProbe -AsLines -Command (
            "Set-StrictMode -Version 2.0; " +
            "try { " +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "[void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); " +
            "'NOTHREW:' + [string]`$global:consoleSettings.OutputEncodingCodePage " +
            "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
        )
    $localCfgCodePageProbeLast = ([string](@($localCfgCodePageProbe)[-1])).Trim()
    Test-BRAVOCondition `
        -Condition ($localCfgCodePageProbeLast -eq 'NOTHREW:0') `
        -Name "Loader/OutputEncodingCodePageZeroCompatibility" `
        -Failure "consoleSettings.OutputEncodingCodePage=0 мусить проходити реальний Import-BravoConfiguration без throw; отримано: '$localCfgCodePageProbeLast'"

    # --- Loader/SftpPortOversizedValueFailsClosedWithoutOverflowException
    # (PR #224 review, шосте коло, P2 "IntegerRange overflow hardening"):
    # sftpPort=[uint64]::MaxValue МУСИТЬ і надалі fail-closed зупиняти
    # завантаження (ValidatorRejected — canonical авторизаційний контракт
    # незмінний), АЛЕ керованим throw ("неавторизоване перевизначення" з
    # loader-а), НЕ неконтрольованим .NET OverflowException від звуження
    # [int64] усередині Test-BRAVOConfigurationAuthorizationIntegerRange.
    [IO.File]::WriteAllText($localCfgOverridePath, (
        "@{`r`n" +
        "    'sftpPort' = 18446744073709551615`r`n" +
        "}`r`n"
    ), (New-Object System.Text.UTF8Encoding $false))
    $localCfgSftpPortProbe = Invoke-BRAVOConfigLoaderProbe -AsLines -Command (
            "Set-StrictMode -Version 2.0; " +
            "try { " +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "[void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); " +
            "'UNEXPECTED-NOTHREW' " +
            "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
        )
    $localCfgSftpPortProbeLast = ([string](@($localCfgSftpPortProbe)[-1])).Trim()
    Test-BRAVOCondition `
        -Condition (
            $localCfgSftpPortProbeLast.StartsWith('CHILD-ERROR:') -and
            $localCfgSftpPortProbeLast.Contains('BRAVO.local.config: неавторизоване перевизначення') -and
            $localCfgSftpPortProbeLast.Contains('sftpPort') -and
            (-not $localCfgSftpPortProbeLast.Contains('OverflowException')) -and
            (-not $localCfgSftpPortProbeLast.Contains('overflow'))
        ) `
        -Name "Loader/SftpPortOversizedValueFailsClosedWithoutOverflowException" `
        -Failure "sftpPort=[uint64]::MaxValue мусить fail-closed зупинити завантаження КЕРОВАНИМ throw ('неавторизоване перевизначення'), БЕЗ OverflowException; отримано: '$localCfgSftpPortProbeLast'"

    # --- Loader/MaintenanceLoggingSuccessLoadsSuccessfully (PR #224 review,
    # шосте коло, P2 "Restrict maintenance log levels to runtime-supported
    # values"): SUCCESS — runtime-підтримуваний рівень (Maintenance
    # startup-gate), мусить проходити реальний Import-BravoConfiguration
    # без throw.
    [IO.File]::WriteAllText($localCfgOverridePath, (
        "@{`r`n" +
        "    'maintenanceSettings.Logging.Level' = 'SUCCESS'`r`n" +
        "}`r`n"
    ), (New-Object System.Text.UTF8Encoding $false))
    $localCfgMlSuccessProbe = Invoke-BRAVOConfigLoaderProbe -AsLines -Command (
            "Set-StrictMode -Version 2.0; " +
            "try { " +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "[void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); " +
            "'NOTHREW:' + [string]`$global:maintenanceSettings.Logging.Level " +
            "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
        )
    $localCfgMlSuccessProbeLast = ([string](@($localCfgMlSuccessProbe)[-1])).Trim()
    Test-BRAVOCondition `
        -Condition ($localCfgMlSuccessProbeLast -eq 'NOTHREW:SUCCESS') `
        -Name "Loader/MaintenanceLoggingSuccessLoadsSuccessfully" `
        -Failure "maintenanceSettings.Logging.Level='SUCCESS' мусить проходити реальний Import-BravoConfiguration без throw; отримано: '$localCfgMlSuccessProbeLast'"

    # --- Loader/MaintenanceLoggingTraceRejectedByCanonicalAuthorization /
    # Loader/MaintenanceLoggingFatalRejectedByCanonicalAuthorization ---
    # TRACE/FATAL мусять бути відхилені canonical авторизацією НА ЕТАПІ
    # завантаження конфігурації — керованим throw ('неавторизоване
    # перевизначення'), а НЕ пропущені далі до того, як Maintenance
    # startup-gate сам впаде з непрозорим exit 30.
    foreach ($mlUnsupported in @('TRACE', 'FATAL')) {
        [IO.File]::WriteAllText($localCfgOverridePath, (
            "@{`r`n" +
            "    'maintenanceSettings.Logging.Level' = '$mlUnsupported'`r`n" +
            "}`r`n"
        ), (New-Object System.Text.UTF8Encoding $false))
        $localCfgMlUnsupportedProbe = Invoke-BRAVOConfigLoaderProbe -AsLines -Command (
                "Set-StrictMode -Version 2.0; " +
                "try { " +
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "[void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); " +
                "'UNEXPECTED-NOTHREW' " +
                "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
            )
        $localCfgMlUnsupportedProbeLast = ([string](@($localCfgMlUnsupportedProbe)[-1])).Trim()
        Test-BRAVOCondition `
            -Condition (
                $localCfgMlUnsupportedProbeLast.StartsWith('CHILD-ERROR:') -and
                $localCfgMlUnsupportedProbeLast.Contains('BRAVO.local.config: неавторизоване перевизначення') -and
                $localCfgMlUnsupportedProbeLast.Contains('maintenanceSettings.Logging.Level')
            ) `
            -Name "Loader/MaintenanceLogging$($mlUnsupported.Substring(0,1) + $mlUnsupported.Substring(1).ToLowerInvariant())RejectedByCanonicalAuthorization" `
            -Failure "maintenanceSettings.Logging.Level='$mlUnsupported' мусить бути відхилений canonical авторизацією ПІД ЧАС завантаження конфігурації (не пропущений до Maintenance startup-gate); отримано: '$localCfgMlUnsupportedProbeLast'"
    }

    # --- Опечатка в dot-шляху -> помилка конфігурації (не мовчазне ігнорування).
    [IO.File]::WriteAllText($localCfgOverridePath,
        "@{ 'pathSettings.NoSuchKeyRoot.Sub' = 'x' }",
        (New-Object System.Text.UTF8Encoding $false))
    $localCfgTypoProbe = [string](
        Invoke-BRAVOConfigLoaderProbe -Command (
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "try { [void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); 'NO-THROW' } catch { 'THREW' }"
            )
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
        Invoke-BRAVOConfigLoaderProbe -Command (
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "try { [void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); 'NO-THROW' } catch { 'THREW:' + `$_.Exception.Message }"
            )
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
        Invoke-BRAVOConfigLoaderProbe -Command (
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "try { [void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
                "'RESULT:' + [string]`$global:BravoConfigurationMetadata.LocalConfigDeclaredSchemaVersion + " +
                "';' + [string]`$global:pathSettings.BackupRoot } catch { 'THREW:' + `$_.Exception.Message }"
            )
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
        Invoke-BRAVOConfigLoaderProbe -Command (
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "try { [void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); 'NO-THROW' } catch { 'THREW:' + `$_.Exception.Message }"
            )
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
        Invoke-BRAVOConfigLoaderProbe -Command (
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "try { [void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); 'NO-THROW' } catch { 'THREW' }"
            )
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
        Invoke-BRAVOConfigLoaderProbe -Command (
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "try { [void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); 'NO-THROW' } catch { 'THREW' }"
            )
    )
    Test-BRAVOCondition `
        -Condition ($localCfgExpressionProbe.Contains('THREW') -and -not $localCfgExpressionProbe.Contains('NO-THROW')) `
        -Name "ConfigLoader/LocalOverrideRejectsEvaluatedExpression" `
        -Failure "вираз у значенні BRAVO.local.config мусить відхилятись, а не обчислюватись (файл є ДАНИМИ); отримано: $localCfgExpressionProbe"

    # --- Без файла -> штатне завантаження, metadata порожній.
    Remove-Item -LiteralPath $localCfgOverridePath -Force
    $localCfgAbsentProbe = [string](
        Invoke-BRAVOConfigLoaderProbe -Command (
                "try { " +
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "[void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); " +
                "'OK ' + (@(`$global:BravoConfigurationMetadata.LocalConfigOverrides).Count) " +
                "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
            )
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
# Кожен сценарій — ізольований runspace у дочірньому раннері проб
# (Import-BravoConfiguration змінює глобальний стан); конфіг герметизовано явним BackupRoot (та сама
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
            Invoke-BRAVOConfigLoaderProbe -Command $busyWaitProbeCommand
        )
        Test-BRAVOCondition `
            -Condition ($busyWaitProbe.Contains([string]$busyWaitCase.Expected)) `
            -Name ([string]$busyWaitCase.Name) `
            -Failure "$($busyWaitCase.Failure); отримано: $busyWaitProbe"
    }
} finally {
    Remove-Item -LiteralPath $busyWaitScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}
} catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'ConfigLoader/OriginalExceptionMessageNotLost' } }
if (Enter-BRAVOSelfTestSection -Name 'ConfigLoader/NoConfigAutoDerivedPathSucceedsAsSynthetic') { try {

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
            Invoke-BRAVOConfigLoaderProbe -Command $successDedupProbeCommand
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
# Кожен сценарій — ізольований runspace у дочірньому раннері проб.
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
            Invoke-BRAVOConfigLoaderProbe -Command $storageSwitchProbeCommand
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
# Кожен сценарій — ізольований runspace у дочірньому раннері проб; BackupRoot
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
    # Кирилиця у виводі (InstitutionName/ObjectName) доходить без утрат:
    # раннер проб пише результат у файл UTF-8, а не через консольну кодову
    # сторінку (раніше тут доводилось перемикати [Console]::OutputEncoding).
    $noConfigProbe = [string](
        Invoke-BRAVOConfigLoaderProbe -Command $noConfigProbeCommand
    )
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
        Invoke-BRAVOConfigLoaderProbe -Command $noConfigExplicitProbeCommand
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
                Invoke-BRAVOConfigLoaderProbe -Command $intentMatrixProbeCommand
            )
            $intentMatrixThrew = $intentMatrixProbe.Contains('THREW') -and -not $intentMatrixProbe.Contains('NO-THROW')
            Test-BRAVOCondition `
                -Condition ((Test-BRAVOConfigLoaderProbeCompleted -Output $intentMatrixProbe) -and ($intentMatrixThrew -eq [bool]$intentMatrixCase.ExpectThrow)) `
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
        Invoke-BRAVOConfigLoaderProbe -Command $noConfigTypoProbeCommand
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
            Invoke-BRAVOConfigLoaderProbe -Command $probeCommand
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
            Invoke-BRAVOConfigLoaderProbe -Command $probeCommand
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
        Invoke-BRAVOConfigLoaderProbe -Command $reqAdminInvariantNonBoolProbeCommand
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
} catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'ConfigLoader/NoConfigAutoDerivedPathSucceedsAsSynthetic' } }
if (Enter-BRAVOSelfTestSection -Name 'ConfigLoader/RequireAdministratorMissingBlocks' -DependsOn 'ConfigLoader/OriginalExceptionMessageNotLost', 'ConfigLoader/NoConfigAutoDerivedPathSucceedsAsSynthetic') { try {

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
    Invoke-BRAVOConfigLoaderProbe -Command $reqAdminMissingProbeCommand
).Trim()
Test-BRAVOCondition `
    -Condition (
        $reqAdminMissingResult.StartsWith('THREW') -and
        $reqAdminMissingResult.Contains('ПОСЛАБЛЮЄ ЗАХИСТ') -and
        $reqAdminMissingResult.Contains('requireAdministrator відсутній')
    ) `
    -Name "ConfigLoader/RequireAdministratorMissingBlocks" `
    -Failure "відсутній `$global:requireAdministrator (не просто `$false) МАЄ БЛОКУВАТИ з окремим діагностичним повідомленням 'requireAdministrator відсутній'; отримано: $reqAdminMissingResult"

# --- ConfigLoader/ToolIntegrityModeWeakenedBlocks (Issue #216, §9 п.6):
# toolIntegritySettings.Mode НЕ raw-configurable (канонічна константа) —
# у звичайних probe-ах вище він СВІДОМО завжди встановлюється безпечним
# значенням ('Enforce'), щоб не заважати ізоляції ІНШИХ змінних. Тому
# власна DENY-гілка Test-BRAVOEffectiveSecurityInvariants для цього
# canary (BRAVO_CONFIG_LOADER.ps1: "toolIntegritySettings.Mode = '...'
# замість 'Enforce'") досі не мала жодного прямого тесту — лише pre-trust
# AST-дзеркало (BRAVO_RUNTIME_GUARD.ps1) нижче. Той самий прямий-виклик
# паттерн, що RequireAdministratorMissingBlocks вище.
$toolIntegrityWeakenedProbeCommand = (
    "try { . '$root\BRAVO_CONFIG_LOADER.ps1'; " +
    "`$global:backupConsistency = @{ Mode = 'VSS' }; " +
    "`$global:toolIntegritySettings = @{ Mode = 'Warn' }; " +
    "`$global:requireAdministrator = `$true; " +
    "Test-BRAVOEffectiveSecurityInvariants } catch { 'THREW: ' + `$_.Exception.Message }"
)
$toolIntegrityWeakenedResult = [string](
    Invoke-BRAVOConfigLoaderProbe -Command $toolIntegrityWeakenedProbeCommand
).Trim()
Test-BRAVOCondition `
    -Condition (
        $toolIntegrityWeakenedResult.StartsWith('THREW') -and
        $toolIntegrityWeakenedResult.Contains('ПОСЛАБЛЮЄ ЗАХИСТ') -and
        $toolIntegrityWeakenedResult.Contains("toolIntegritySettings.Mode = 'Warn'")
    ) `
    -Name "ConfigLoader/ToolIntegrityModeWeakenedBlocks" `
    -Failure "ефективний `$global:toolIntegritySettings.Mode = 'Warn' (замість 'Enforce') МАЄ БЛОКУВАТИ через Test-BRAVOEffectiveSecurityInvariants навіть якщо ця canary-гілка сьогодні недосяжна звичайним raw-override-шляхом; отримано: $toolIntegrityWeakenedResult"

# --- ConfigLoader/ToolManifestPathRedirectionBlocks та
# ConfigLoader/ToolManifestPathCanonicalAllowed (BRAVO-T001, аудит F001):
# toolIntegritySettings.ManifestPath, як і Mode, виводиться канонічно
# (<toolsPath>\TOOLS_MANIFEST.json) і не є raw-configurable. Canary-гілка
# Test-BRAVOEffectiveSecurityInvariants блокує будь-яке інше значення —
# перенаправлений маніфест тихо легітимізував би підмінений бінарник у
# Enforce. Негативний і позитивний випадки викликають функцію НАПРЯМУ
# (той самий паттерн, що ToolIntegrityModeWeakenedBlocks вище), щоб
# довести саму гілку, а не лише те, що derivation сьогодні її не досягає.
$toolManifestProbeRuntimeRoot = Join-Path ([IO.Path]::GetTempPath()) 'BRAVO_T001_RUNTIME'
$toolManifestProbeRuntimeLiteral = $toolManifestProbeRuntimeRoot.Replace("'", "''")
$toolManifestProbePrefix = (
    "try { . '$root\BRAVO_CONFIG_LOADER.ps1'; " +
    "`$global:backupConsistency = @{ Mode = 'VSS' }; " +
    "`$global:requireAdministrator = `$true; " +
    "`$global:runtimeRoot = '$toolManifestProbeRuntimeLiteral'; " +
    "`$global:toolsPath = (Join-Path `$global:runtimeRoot 'Tools'); "
)
$toolManifestRedirectedProbeCommand = (
    $toolManifestProbePrefix +
    "`$global:toolIntegritySettings = @{ Mode = 'Enforce'; ManifestPath = 'C:\Attacker\TOOLS_MANIFEST.json' }; " +
    "Test-BRAVOEffectiveSecurityInvariants; 'NO-THROW' } catch { 'THREW: ' + `$_.Exception.Message }"
)
$toolManifestRedirectedResult = [string](
    Invoke-BRAVOConfigLoaderProbe -Command $toolManifestRedirectedProbeCommand
).Trim()
Test-BRAVOCondition `
    -Condition (
        $toolManifestRedirectedResult.StartsWith('THREW') -and
        $toolManifestRedirectedResult.Contains('ПОСЛАБЛЮЄ ЗАХИСТ') -and
        $toolManifestRedirectedResult.Contains("toolIntegritySettings.ManifestPath = 'C:\Attacker\TOOLS_MANIFEST.json'")
    ) `
    -Name "ConfigLoader/ToolManifestPathRedirectionBlocks" `
    -Failure "ефективний toolIntegritySettings.ManifestPath поза <RuntimeRoot>\Tools\TOOLS_MANIFEST.json МАЄ БЛОКУВАТИ через Test-BRAVOEffectiveSecurityInvariants; отримано: $toolManifestRedirectedResult"

$toolManifestCanonicalProbeCommand = (
    $toolManifestProbePrefix +
    "`$global:toolIntegritySettings = @{ Mode = 'Enforce'; ManifestPath = (Join-Path `$global:toolsPath 'TOOLS_MANIFEST.json') }; " +
    "Test-BRAVOEffectiveSecurityInvariants; 'NO-THROW' } catch { 'THREW: ' + `$_.Exception.Message }"
)
$toolManifestCanonicalResult = [string](
    Invoke-BRAVOConfigLoaderProbe -Command $toolManifestCanonicalProbeCommand
).Trim()
Test-BRAVOCondition `
    -Condition ($toolManifestCanonicalResult -eq 'NO-THROW') `
    -Name "ConfigLoader/ToolManifestPathCanonicalAllowed" `
    -Failure "канонічний toolIntegritySettings.ManifestPath (<toolsPath>\TOOLS_MANIFEST.json) не повинен блокуватись; отримано: $toolManifestCanonicalResult"

# Крайові випадки T001 в одній пробі (якір довіри —
# <RuntimeRoot>\Tools):
#   empty/malformed — порожній і синтаксично зіпсований ManifestPath;
#   dotCanonical    — '..', що після GetFullPath дає той самий канонічний
#                     файл, допускається навмисно (це той самий шлях);
#   dotEscape       — '..' за межі Tools\;
#   caseVariant     — інший регістр імені файла (на NTFS із per-directory
#                     case sensitivity це інший файл);
#   coRedirected    — toolsPath і ManifestPath перенаправлено в один
#                     сторонній каталог (звірка лише з toolsPath не помітила б);
#   orderedDict     — перенаправлення в OrderedDictionary (споживачі
#                     приймають будь-який IDictionary, не лише hashtable).
$toolManifestEdgeProbeCommand = (
    $toolManifestProbePrefix +
    "`$canonicalTools = `$global:toolsPath; " +
    "`$edgeCases = [ordered]@{ " +
    "'empty' = @(`$canonicalTools, ''); " +
    "'malformed' = @(`$canonicalTools, 'C:\bad:name|<>\TOOLS_MANIFEST.json'); " +
    "'dotCanonical' = @(`$canonicalTools, (Join-Path `$canonicalTools '..\Tools\TOOLS_MANIFEST.json')); " +
    "'dotEscape' = @(`$canonicalTools, (Join-Path `$canonicalTools '..\Other\TOOLS_MANIFEST.json')); " +
    "'caseVariant' = @(`$canonicalTools, (Join-Path `$canonicalTools 'tools_manifest.json')); " +
    "'coRedirected' = @('C:\Attacker\Tools', 'C:\Attacker\Tools\TOOLS_MANIFEST.json'); " +
    "'orderedDict' = @(`$canonicalTools, 'C:\Attacker\TOOLS_MANIFEST.json') }; " +
    "`$edgeOutcomes = foreach (`$edgeName in @(`$edgeCases.Keys)) { " +
    "`$global:toolsPath = `$edgeCases[`$edgeName][0]; " +
    "if (`$edgeName -eq 'orderedDict') { `$settings = New-Object System.Collections.Specialized.OrderedDictionary; `$settings['Mode'] = 'Enforce'; `$settings['ManifestPath'] = `$edgeCases[`$edgeName][1] } " +
    "else { `$settings = @{ Mode = 'Enforce'; ManifestPath = `$edgeCases[`$edgeName][1] } }; " +
    "`$global:toolIntegritySettings = `$settings; " +
    "try { Test-BRAVOEffectiveSecurityInvariants; `$edgeName + '=NO-THROW' } " +
    "catch { `$edgeMessage = [string]`$_.Exception.Message; if (`$edgeMessage -like '*toolIntegritySettings.ManifestPath*' -or `$edgeMessage -like '*toolsPath = *') { `$edgeName + '=BLOCKED' } else { `$edgeName + '=OTHER' } } }; " +
    "`$edgeOutcomes -join ';' } catch { 'THREW: ' + `$_.Exception.Message }"
)
$toolManifestEdgeResult = [string](
    Invoke-BRAVOConfigLoaderProbe -Command $toolManifestEdgeProbeCommand
).Trim()
Test-BRAVOCondition `
    -Condition ($toolManifestEdgeResult -eq 'empty=BLOCKED;malformed=BLOCKED;dotCanonical=NO-THROW;dotEscape=BLOCKED;caseVariant=BLOCKED;coRedirected=BLOCKED;orderedDict=BLOCKED') `
    -Name "ConfigLoader/ToolManifestPathEdgeCasesFailClosed" `
    -Failure "порожній/зіпсований ManifestPath, '..' за межі Tools\, інший регістр імені, спільне перенаправлення toolsPath+ManifestPath і перенаправлення в OrderedDictionary мають блокуватись, а '..', що веде до канонічного файла, — ні; отримано: $toolManifestEdgeResult"

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
            Invoke-BRAVOConfigLoaderProbe -Command $probeCommand
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
#
# Issue #216 (§9, Крок 0): сам bool-вердикт "Enforce"/"VSS" тепер
# централізовано в Test-BRAVOSecurityInvariantValueWeakened
# (modules\BRAVO.Configuration) — Test-BRAVOEffectiveSecurityInvariants
# (BRAVO_CONFIG_LOADER.ps1) лише делегує туди й лишає $global:-
# посилання/операторські повідомлення. Тому Expected-літерали
# перевіряються в каноничному модулі-предикаті, а не в самому loader-і;
# $global:-посилання (доказ, ЩО саме перевіряється) — все ще в loader-і.
# ============================================================
$guardTextForParity = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_RUNTIME_GUARD.ps1'), [Text.Encoding]::UTF8)
$loaderTextForSecurityParity = [IO.File]::ReadAllText($configLoaderPath, [Text.Encoding]::UTF8)
$securityInvariantPredicatePath = Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.psm1'
$securityInvariantPredicateText = [IO.File]::ReadAllText($securityInvariantPredicatePath, [Text.Encoding]::UTF8)
Test-BRAVOCondition `
    -Condition (
        $guardTextForParity.Contains("Variable = 'toolIntegritySettings'") -and
        $guardTextForParity.Contains("Expected = 'Enforce'") -and
        $guardTextForParity.Contains("Variable = 'backupConsistency'") -and
        $guardTextForParity.Contains("Expected = 'VSS'") -and
        $loaderTextForSecurityParity.Contains('$global:toolIntegritySettings.Mode') -and
        $loaderTextForSecurityParity.Contains('$global:backupConsistency.Mode') -and
        $loaderTextForSecurityParity.Contains('Test-BRAVOSecurityInvariantValueWeakened') -and
        $securityInvariantPredicateText.Contains("'Enforce', [System.StringComparison]::OrdinalIgnoreCase") -and
        $securityInvariantPredicateText.Contains("'VSS', [System.StringComparison]::OrdinalIgnoreCase")
    ) `
    -Name "ConfigLoader/SecurityRuleParityGuardVsEffectiveCheck" `
    -Failure "pre-trust guard (BRAVO_RUNTIME_GUARD.ps1) і post-merge effective-перевірка (BRAVO_CONFIG_LOADER.ps1 -> канонічний Test-BRAVOSecurityInvariantValueWeakened) мають перевіряти ОДНАКОВІ Expected-значення (toolIntegritySettings.Mode='Enforce', backupConsistency.Mode='VSS') — розбіжність тут означає, що два набори правил розійшлися"

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
    Invoke-BRAVOConfigLoaderProbe -Command $committedConfigProbeCommand
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
    # АДИТИВНІ КАНОНІЧНІ ЛИСТИ, додані ПІСЛЯ заморожування legacy-фікстури
    # (B4-2, коміт 75b3b39). Фікстура selftest\fixtures\BravoConfigLegacyFrozen.config
    # за своїм контрактом (Get-BRAVOSelfTestLegacyConfigPath у BRAVO_SELF_TEST.ps1)
    # НЕ слідує за майбутніми змінами canonical-дефолтів: вона фіксує
    # pre-B4-2 legacy-текст як синтетичну БАЗУ сценарію. Тому для НОВОГО
    # канонічного листа очікуваний стан фікстури — саме 'відсутній', і
    # дописування такого листа у фікстуру (що й робив PR #225 до цієї
    # правки) знецінило б паритет-harness: він перестав би перевіряти
    # реальну pre-5.3 конфігурацію, бо очікуваний вхід і реалізація
    # оновлювались би разом.
    #
    # Перелічено ПОІМЕННО — той самий принцип, що в
    # ci\Test-BRAVOConfigFoundationParity.ps1 (`$knownIntentionalDiffPrefixes):
    # загальне правило 'відсутнє у фікстурі -> пропускаємо' приховало б
    # справжню регресію (лист, який у фікстурі БУВ і зник). Пропускається
    # рівно один вид розбіжності — 'відсутнє в BRAVO.config'; той самий
    # лист з ІНШИМ значенням і далі fail-closed позначається як diff.
    #
    # Тертя від поіменного переліку — чесний сигнал, що фікстура старіє.
    $parityFrozenFixtureAdditiveLeaves = @(
        # BSYSTEM Operations (5.3.0): імена записів Credential Manager для
        # bootstrap-секрету self-enrollment і виданого API-ключа.
        'credentialSettings.Targets.OperationsApiKey',
        'credentialSettings.Targets.OperationsBootstrapSecret'
    )
    $parityAdditiveAbsenceSuffix = ' : відсутнє в BRAVO.config'
    $parityDiffs = @(@($parityDiffsList.ToArray()) | Where-Object {
        $diffLine = [string]$_
        $isAllowedAbsence = $false
        foreach ($additiveLeaf in $parityFrozenFixtureAdditiveLeaves) {
            if ($diffLine -ceq ($additiveLeaf + $parityAdditiveAbsenceSuffix)) {
                $isAllowedAbsence = $true
                break
            }
        }
        -not $isAllowedAbsence
    })
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
        # Ізольований runspace дочірнього раннера обов'язковий:
        # Import-BravoConfiguration встановлює десятки $global:, змішувати
        # які з рештою прогону не можна.
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
                Invoke-BRAVOConfigLoaderProbe -Command $probeCommand
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
                (Test-BRAVOConfigLoaderProbeCompleted -Output $strictnessUnknownGlobal) -and
                (Test-BRAVOConfigLoaderProbeCompleted -Output $strictnessUnknownNested) -and
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
            Invoke-BRAVOConfigLoaderProbe -Command $strictnessHelperCommand
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
} catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'ConfigLoader/RequireAdministratorMissingBlocks' } }
if (Enter-BRAVOSelfTestSection -Name 'ConfigLoader/Authorization' -DependsOn 'ConfigLoader/NoConfigAutoDerivedPathSucceedsAsSynthetic') { try {

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
            # НІКОЛИ не оголошується в runspace цієї проби. Це прямий
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
                Invoke-BRAVOConfigLoaderProbe -Command $probeCommand
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

# Issue #216 (R2, §9 п.3 HIGH, 2026-09-26): дефект знайдено адверсаріальним
# незалежним рев'ю R2, не дублікат fail-open/H-1 теми. У
# BRAVO_CONFIG_LOADER.ps1 (Complete-BRAVOConfigurationLoad, ~рядок 1447)
# $effectiveUnknownLeafSink будувався через if-вираз:
#     $effectiveUnknownLeafSink = if (...) { $localOverrideState.UnknownLeafPaths } else { $null }
# PowerShell на цьому шляху розгортає ПОРОЖНІЙ IEnumerable (List[string] із
# Count=0), що виходить із гілки if-виразу через звичайний output-стрім, у
# $null (емпірично перевірено мінімальним репро) — а не непорожній список
# розгорнув би не в null, а в останній елемент. UnknownLeafPaths стартує
# порожнім щоразу, тож sink, який фактично передавався нижче в
# Resolve-BRAVORawConfiguration/ConvertTo-BRAVONestedOverride, був ЗАВЖДИ
# $null — D3 unknown-leaf діагностика (#154/A2, і Write-Warning, і
# $global:BravoConfigurationMetadata.LocalConfigUnknownLeafOverrides) мовчки
# ніколи не спрацьовувала, незалежно від того, скільки насправді невідомих
# кінцевих сегментів містив BRAVO.local.config. Функціональний
# observability-регрес, НЕ security bypass (fail-closed на невідомий
# БАТЬКІВСЬКИЙ вузол цим sink-ом не керується;
# Test-BRAVOEffectiveSecurityInvariants перевіряє реальні пост-мердж
# $global: незалежно від цього шляху).
# ============================================================
$r2UnknownLeafBackupRootDir = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_R2_UNKNOWNLEAF_BACKUP_{0}" -f [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($r2UnknownLeafBackupRootDir)
$r2UnknownLeafBackupRootLiteral = $r2UnknownLeafBackupRootDir.Replace("'", "''")
$r2UnknownLeafResultExpression = (
    "'RESULT:Count=' + [string]`$global:BravoConfigurationMetadata.LocalConfigUnknownLeafOverrides.Count + " +
    "';Leaves=' + (`$global:BravoConfigurationMetadata.LocalConfigUnknownLeafOverrides -join ',')"
)

try {
    # --- ConfigLoader/R2UnknownLeafSinkActuallyPopulated: генуїнно невідомий
    # КІНЦЕВИЙ сегмент під реальним hashtable-батьківським вузлом
    # (maintenanceSettings — той самий forward-compat-приклад, що й у
    # LocalOverrideParityForwardCompatLeaf вище) МАЄ з'явитись у
    # LocalConfigUnknownLeafOverrides. До фіксу цей sink був мертвим кодом —
    # Count завжди дорівнював 0 незалежно від вмісту BRAVO.local.config.
    $r2UnknownLeafBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$r2UnknownLeafBackupRootLiteral'`r`n" +
        "    'maintenanceSettings.FutureFieldNotYetInSchema' = 'preserve-me'`r`n" +
        "}`r`n"
    )
    $r2UnknownLeafResult = New-BRAVOConfigLoaderSecurityDowngradeProbe `
        -WithPrimary $false -LocalConfigBody $r2UnknownLeafBody -ResultExpression $r2UnknownLeafResultExpression
    Test-BRAVOCondition `
        -Condition ($r2UnknownLeafResult -eq 'RESULT:Count=1;Leaves=maintenanceSettings.FutureFieldNotYetInSchema') `
        -Name "ConfigLoader/R2UnknownLeafSinkActuallyPopulated" `
        -Failure (
            "genuinely невідомий кінцевий сегмент 'maintenanceSettings.FutureFieldNotYetInSchema' " +
            "мав з'явитись у BravoConfigurationMetadata.LocalConfigUnknownLeafOverrides (sink НЕ мертвий код); " +
            "отримано: $r2UnknownLeafResult"
        )

    # --- ConfigLoader/R2UnknownLeafSinkEmptyWhenNoUnknownLeaf (sanity): без
    # жодного невідомого leaf sink має лишатись порожнім (0), а не
    # false-positive.
    $r2KnownLeafBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$r2UnknownLeafBackupRootLiteral'`r`n" +
        "}`r`n"
    )
    $r2KnownLeafResult = New-BRAVOConfigLoaderSecurityDowngradeProbe `
        -WithPrimary $false -LocalConfigBody $r2KnownLeafBody -ResultExpression $r2UnknownLeafResultExpression
    Test-BRAVOCondition `
        -Condition ($r2KnownLeafResult -eq 'RESULT:Count=0;Leaves=') `
        -Name "ConfigLoader/R2UnknownLeafSinkEmptyWhenNoUnknownLeaf" `
        -Failure "BRAVO.local.config без невідомих leaf-ів має дати Count=0; отримано: $r2KnownLeafResult"
} finally {
    Remove-Item -LiteralPath $r2UnknownLeafBackupRootDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# Спільний захоплювач ПОВНОГО канонічного знімка в дочірньому процесі
# (Proof B нижче + B7-матриця, issue #154). Один дочірній шаблон на
# фрагмент: довільний виклик Import-BravoConfiguration ($InvocationText,
# у scope якого доступні $RuntimeRoot/$ConfigRoot) -> ПОВНИЙ знімок
# Get-BRAVOEffectiveConfigurationSnapshot -> CliXml. Рекурсивне
# сплощення [pscustomobject] і вибір CliXml замість JSON — обґрунтування
# у коментарі Proof B нижче. На помилці дитина пише повідомлення винятку
# і (опційно) значення перелічених $global:-змінних ПІСЛЯ throw —
# для доказу атомарності "жоден сусідній override не потрапив у стан".
# Окремий процес на кожне захоплення: Import-BravoConfiguration
# встановлює десятки $global:, які небезпечно змішувати між прогонами.
# ============================================================
function Invoke-BRAVOSelfTestEffectiveSnapshotCapture {
    param(
        [Parameter(Mandatory = $true)][string]$WorkRoot,
        [Parameter(Mandatory = $true)][string]$ConfigRoot,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$InvocationText,
        [string[]]$ProbeVariableName = @()
    )

    $childScriptPath = Join-Path $WorkRoot 'EffectiveSnapshotCaptureChild.ps1'
    if (-not (Test-Path -LiteralPath $childScriptPath -PathType Leaf)) {
        $childTemplate = @'
param(
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$ConfigRoot,
    [Parameter(Mandatory = $true)][string]$InvocationPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$ErrorPath,
    [string]$ProbeVariableNames = ''
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
try {
    . (Join-Path $RuntimeRoot 'BRAVO_CONFIG_LOADER.ps1')
    . $InvocationPath
    Import-Module -Name (Join-Path $RuntimeRoot 'modules\BRAVO.Configuration\BRAVO.Configuration.Snapshot.psd1') -Force
    function ConvertTo-ProofBComparableValue {
        param($Value)
        if ($null -eq $Value) { return $null }
        if ($Value -is [System.Management.Automation.PSCustomObject]) {
            $result = @{}
            foreach ($property in $Value.PSObject.Properties) {
                $result[$property.Name] = ConvertTo-ProofBComparableValue -Value $property.Value
            }
            return $result
        }
        if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string]) -and -not ($Value -is [System.Collections.IDictionary])) {
            return ,@(@($Value) | ForEach-Object { ConvertTo-ProofBComparableValue -Value $_ })
        }
        return $Value
    }

    $names = @(Get-BRAVOEffectiveConfigurationVariableName)
    $snapshot = Get-BRAVOEffectiveConfigurationSnapshot -VariableName $names
    $captured = @{}
    foreach ($name in $names) {
        $captured[$name] = ConvertTo-ProofBComparableValue -Value $snapshot[$name]
    }
    $captured | Export-Clixml -LiteralPath $OutputPath -Depth 20
    # Той самий канонічний перелік імен, але значення читаються напряму,
    # без `$x = if (...) { $v.Value }` усередині
    # Get-BRAVOEffectiveConfigurationSnapshot: вивід if-оператора йде
    # конвеєром і для ВЕРХНЬОРІВНЕВИХ змінних-масивів розгортає @() у $null,
    # а @('x') — у скаляр 'x' (issue #154, B7: виявлено під час
    # характеризації, винесено окремо — не змінено тут). Для доказів, де
    # важить саме тип масиву, B7 порівнює цей неспотворений знімок.
    $rawCaptured = @{}
    foreach ($name in $names) {
        $rawVariable = Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
        if ($null -eq $rawVariable) {
            $rawCaptured[$name] = '<<ABSENT>>'
        } else {
            $rawCaptured[$name] = ConvertTo-ProofBComparableValue -Value $rawVariable.Value
        }
    }
    $rawCaptured | Export-Clixml -LiteralPath ($OutputPath + '.raw') -Depth 20
} catch {
    $probeValues = @{}
    foreach ($probeName in @($ProbeVariableNames -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $probeVariable = Get-Variable -Name $probeName -Scope Global -ErrorAction SilentlyContinue
        $probeValues[$probeName] = if ($null -eq $probeVariable) { '<unset>' } else { [string]$probeVariable.Value }
    }
    [pscustomobject]@{ Message = $_.Exception.Message; ScriptStackTrace = $_.ScriptStackTrace; ProbeValues = $probeValues } |
        Export-Clixml -LiteralPath $ErrorPath -Depth 5
    exit 1
}
'@
        [IO.File]::WriteAllText($childScriptPath, $childTemplate, (New-Object System.Text.UTF8Encoding($false)))
    }

    $workDir = Join-Path $WorkRoot $Label
    [void][IO.Directory]::CreateDirectory($workDir)
    $invocationPath = Join-Path $workDir 'invocation.ps1'
    [IO.File]::WriteAllText($invocationPath, $InvocationText, (New-Object System.Text.UTF8Encoding($false)))
    $outputPath = Join-Path $workDir 'snapshot.clixml'
    $errorPath = Join-Path $workDir 'error.clixml'
    $stdoutPath = Join-Path $workDir 'stdout.log'
    $stderrPath = Join-Path $workDir 'stderr.log'
    $processArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $childScriptPath,
        '-RuntimeRoot', $root, '-ConfigRoot', $ConfigRoot, '-InvocationPath', $invocationPath,
        '-OutputPath', $outputPath, '-ErrorPath', $errorPath)
    if (@($ProbeVariableName).Count -gt 0) {
        $processArgs += @('-ProbeVariableNames', ([string]::Join(',', @($ProbeVariableName))))
    }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $processArgs -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    $errorRecord = $null
    if (Test-Path -LiteralPath $errorPath -PathType Leaf) {
        $errorRecord = Import-Clixml -LiteralPath $errorPath
    }
    $stderrText = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [string](Get-Content -LiteralPath $stderrPath -Raw) } else { '' }
    $succeeded = ($process.ExitCode -eq 0) -and ($null -eq $errorRecord) -and (Test-Path -LiteralPath $outputPath -PathType Leaf)
    return [pscustomobject]@{
        Succeeded    = $succeeded
        Snapshot     = $(if ($succeeded) { Import-Clixml -LiteralPath $outputPath } else { $null })
        RawSnapshot  = $(if ($succeeded) { Import-Clixml -LiteralPath ($outputPath + '.raw') } else { $null })
        ErrorMessage = $(if ($null -ne $errorRecord) { [string]$errorRecord.Message } else { '' })
        ProbeValues  = $(if ($null -ne $errorRecord) { $errorRecord.ProbeValues } else { @{} })
        ExitCode     = $process.ExitCode
        StdErr       = $stderrText
    }
}

# ============================================================
# Issue #216 (Proof B, Lead-звіт 2026-09-26, §9 п.1 HIGH): permanent
# regression-покриття емпіричного інваріанта Config V2 cutover.
#
# ІНВАРІАНТ, ЩО ДОВОДИТЬСЯ: сторонній BRAVO.config, що лежить поруч із
# ConfigRoot, за -DisallowLegacyPrimaryAutoDetect НЕ впливає на жодне
# значення ефективної конфігурації — лише на provenance-поля
# BravoConfigurationMetadata (LoadedAt/PrimaryConfigPresentOnDisk/
# PrimaryConfigAutoDetectBlocked), які самі описують ФАКТ виявлення
# файлу, а не результат його виконання. Раніше доведено лише ОДНОРАЗОВО
# вручну (R1, 2026-09-26, "8 різнотипних значень, 422 захоплені листи,
# рівно 3 відмінності — усі provenance"); тут — permanent-версія того
# самого прогону, а не новий незалежний доказ.
#
# МЕТОДОЛОГІЯ (та сама, що й у R1, включно з обсягом): один і той самий
# ConfigRoot із ідентичним BRAVO.local.config, знятий у ДВОХ окремих
# дочірніх процесах — раз з отруєним BRAVO.config (8 різнотипних
# перезаписів, включно з найризиковішими полями pathSettings.LIMSRoot і
# pathSettings.BackupRoot), раз без нього — обидва рази з
# -DisallowLegacyPrimaryAutoDetect. Порівнюється ПОВНИЙ канонічний
# знімок (Get-BRAVOEffectiveConfigurationSnapshot), включно з
# BravoConfigurationMetadata/BravoLocalConfigOverrideState — не
# довільна вибірка полів.
#
# ЧОМУ BravoConfigurationMetadata/BravoLocalConfigOverrideState
# ПОТРЕБУЮТЬ ОДНОРІВНЕВОГО СПЛОЩЕННЯ (а не блокового виключення з
# порівняння): обидва — [pscustomobject] з ЛИШЕ листовими полями
# (BRAVO_CONFIG_LOADER.ps1:1718-1776 / :1429-1443 — жодне поле САМЕ не є
# вкладеним PSCustomObject), а Compare-BRAVOConfigurationGraph
# (BRAVO.Configuration.Delta) розкриває рекурсивно лише
# [hashtable]-вузли (Add-BRAVOConfigurationGraphDifference, перевірка
# "-is [hashtable]") — PSCustomObject він порівняв би одним непрозорим
# `-eq` на весь об'єкт (завжди "Changed", різні інстанси в різних
# дочірніх процесах), не заглиблюючись у поля, а виключення цих двох
# імен з переліку взагалі означало би довіряти РІВНОСТІ їхніх ~20 полів
# на слово, а не доводити її — саме та слабина, яку R1 фактично закрив
# повним знімком. Тут — примітивне ОДНОРІВНЕВЕ spread ([pscustomobject]
# -> [hashtable] через PSObject.Properties, без рекурсії), достатнє
# саме тому, що вкладеності немає; НЕ другий загальний глибокий
# конвертер довільного дерева, як у deploy\Compare-BRAVOConfigEffectiveSnapshot.ps1
# (той обслуговує інший споживач — CLI-порівняння двох JSON-знімків з
# довільною глибиною; той інструмент має власний mandatory-param
# CLI-контракт і не призначений для dot-source-повторного використання
# звідси).
#
# Cross-process передача — Export-Clixml/Import-Clixml, а не JSON: усі
# значення канонічного знімка (після однорівневого сплощення двох
# вузлів вище) — реальні .NET hashtable/array/string/bool/number/
# datetime, і CliXml (на відміну від ConvertFrom-Json у Windows
# PowerShell 5.1, який завжди повертає PSCustomObject) відновлює їх
# ТОЧНИМ типом без додаткового конвертера.
& {
    $proofBRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_PROOFB_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($proofBRoot)
    try {
        # ОДИН спільний ConfigRoot для обох знімків (не окремі CLEAN/
        # POISONED-каталоги): якби кожен бік мав власний тимчасовий шлях,
        # ConfigRoot/ConfigPath/LocalConfigPath/PrimaryConfigPath
        # відрізнялись би МІЖ ЗНІМКАМИ через саму лише різницю шляхів
        # фікстури — це затінило б справжній інваріант і фактично довело
        # б "різні директорії дають різні шляхи", а не "сторонній
        # BRAVO.config не впливає на ефективну конфігурацію" (реально
        # відтворено при розробці цього тесту — 4 хибних path-diff
        # зникли одразу після переходу на спільний ConfigRoot).
        $proofBConfigRoot = Join-Path $proofBRoot 'CONFIGROOT'
        [void][IO.Directory]::CreateDirectory($proofBConfigRoot)

        $proofBBackupDir = Join-Path $proofBRoot 'SITE_BACKUP'
        [void][IO.Directory]::CreateDirectory($proofBBackupDir)
        $proofBLocalConfigLiteral = (
            "@{`r`n" +
            "    'pathSettings.BackupRoot' = '$($proofBBackupDir.Replace("'", "''"))'`r`n" +
            "}`r`n"
        )
        [IO.File]::WriteAllText((Join-Path $proofBConfigRoot 'BRAVO.local.config'), $proofBLocalConfigLiteral, (New-Object System.Text.UTF8Encoding($false)))

        function Invoke-BRAVOProofBCapture {
            # Окремий дочірній процес per side (той самий підхід, що й у
            # Invoke-ParityCapture ci\Test-BRAVOConfigFoundationParity.ps1):
            # Import-BravoConfiguration встановлює десятки $global:, які
            # небезпечно змішувати між CLEAN і POISONED прогонами в
            # одному процесі. Сам дочірній шаблон — спільний
            # Invoke-BRAVOSelfTestEffectiveSnapshotCapture (вище).
            param([Parameter(Mandatory = $true)][string]$ConfigRoot, [Parameter(Mandatory = $true)][string]$Label)

            $capture = Invoke-BRAVOSelfTestEffectiveSnapshotCapture `
                -WorkRoot $proofBRoot -ConfigRoot $ConfigRoot -Label $Label `
                -InvocationText 'Import-BravoConfiguration -ConfigRoot $ConfigRoot -RuntimeRoot $RuntimeRoot -DisallowLegacyPrimaryAutoDetect'
            if (-not $capture.Succeeded) {
                throw "Invoke-BRAVOProofBCapture($Label): дочірній процес завершився з помилкою (ExitCode=$($capture.ExitCode)). $($capture.ErrorMessage) $($capture.StdErr)"
            }
            return $capture.Snapshot
        }

        # CLEAN-знімок ЗНІМАЄТЬСЯ ПЕРШИМ, до появи отруєного BRAVO.config —
        # той самий $proofBConfigRoot удруге отримає лише один новий файл,
        # більше нічого в ньому не зміниться.
        $proofBCleanCapture = Invoke-BRAVOProofBCapture -ConfigRoot $proofBConfigRoot -Label 'CLEAN'

        # Отруєний BRAVO.config: заморожений legacy-текст + 8 різнотипних
        # перезаписів у КІНЦІ файлу (виконувались би останніми, якби файл
        # виконувався) — bool/string/number/array/nested-leaf, включно з
        # двома найризиковішими полями — самими коренями даних LIMSRoot і
        # BackupRoot. Файл НІКОЛИ не виконується під
        # -DisallowLegacyPrimaryAutoDetect (перевіряється нижче окремо) —
        # точний вміст після заголовка функціонально неважливий, лише сам
        # факт присутності файлу на диску.
        $proofBPoisonBody = (
            "`$global:LogLevel = 'PROOFB_POISONED'`r`n" +
            "`$global:archiveRetentionDays = 999999`r`n" +
            "`$global:sftpPort = 65535`r`n" +
            "`$global:enableArchiveDeletion = `$true`r`n" +
            "`$global:robocopyOptions = @('/POISONED')`r`n" +
            "`$global:bravoSettings['InstitutionName'] = 'PROOFB_POISONED_INSTITUTION'`r`n" +
            "`$global:pathSettings['LIMSRoot'] = 'C:\PROOFB_NONEXISTENT_LIMS_BOGUS_PATH'`r`n" +
            "`$global:pathSettings['BackupRoot'] = 'C:\PROOFB_NONEXISTENT_BOGUS_PATH'`r`n"
        )
        [IO.File]::WriteAllText(
            (Join-Path $proofBConfigRoot 'BRAVO.config'),
            ((Get-BRAVOSelfTestLegacyConfigText) + "`r`n" + $proofBPoisonBody),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $proofBPoisonedCapture = Invoke-BRAVOProofBCapture -ConfigRoot $proofBConfigRoot -Label 'POISONED'

        # Тест не повинен бути пустим: обидва боки мають підтвердити, що
        # фікстура реально відрізнялась ФАКТОМ на диску (інакше "0
        # відмінностей" довело б лише те, що файл ніде не з'явився).
        Test-BRAVOCondition `
            -Condition (
                $proofBPoisonedCapture['BravoConfigurationMetadata'].PrimaryConfigPresentOnDisk -eq $true -and
                $proofBPoisonedCapture['BravoConfigurationMetadata'].PrimaryConfigAutoDetectBlocked -eq $true
            ) `
            -Name 'ConfigLoader/ProofBPoisonedFixtureActuallyDetectedAndBlocked' `
            -Failure 'фікстура має підтвердити, що отруєний BRAVO.config справді лежав на диску й був заблокований auto-detect (інакше порівняння нижче довело б нуль лише тому, що файл узагалі не існував)'
        Test-BRAVOCondition `
            -Condition (
                $proofBCleanCapture['BravoConfigurationMetadata'].PrimaryConfigPresentOnDisk -eq $false -and
                $proofBCleanCapture['BravoConfigurationMetadata'].PrimaryConfigAutoDetectBlocked -eq $false
            ) `
            -Name 'ConfigLoader/ProofBCleanFixtureHasNoPrimaryConfigOnDisk' `
            -Failure 'чистий бік доказу не повинен мати BRAVO.config на диску взагалі — інакше порівняння нижче не доводить те, що заявляє'

        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Delta.psd1') -Force
        $proofBDifferences = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration $proofBCleanCapture `
            -CandidateConfiguration $proofBPoisonedCapture `
            -IncludeMissingInCandidate)
        # Точковий allowlist — рівно ті самі 3 dot-шляхи, які R1 знайшов
        # уручну (не блокове виключення цілого вузла): вони описують
        # ДЖЕРЕЛО/факт виявлення файлу (LoadedAt — час прогону,
        # PrimaryConfigPresentOnDisk/PrimaryConfigAutoDetectBlocked —
        # прямий наслідок присутності фікстури, уже підтверджений двома
        # умовами вище), а не ефективне значення конфігурації. Усе інше в
        # BravoConfigurationMetadata (Mode/Format/PrimaryConfigPresent/
        # PrimaryConfigIgnoredGlobals/... і 15+ інших полів) і в
        # BravoLocalConfigOverrideState тепер РЕАЛЬНО звіряється — не
        # виключено з розгляду.
        $proofBExpectedDiffPaths = @(
            'BravoConfigurationMetadata.LoadedAt',
            'BravoConfigurationMetadata.PrimaryConfigPresentOnDisk',
            'BravoConfigurationMetadata.PrimaryConfigAutoDetectBlocked'
        )
        $proofBUnexpected = @($proofBDifferences | Where-Object { $proofBExpectedDiffPaths -notcontains $_.Path })

        Test-BRAVOCondition `
            -Condition ($proofBUnexpected.Count -eq 0) `
            -Name 'ConfigLoader/ProofBPoisonedPrimaryConfigHasZeroEffectiveEffect' `
            -Failure (
                "Issue #216 Proof B (Lead-звіт 2026-09-26): сторонній BRAVO.config при -DisallowLegacyPrimaryAutoDetect " +
                "не повинен змінювати ЖОДНОГО значення ефективної конфігурації поза provenance-полями метаданих; " +
                "знайдено $($proofBUnexpected.Count) неочікуваних відмінностей: " +
                (($proofBUnexpected | ForEach-Object { "$($_.Path) [$($_.Kind)]" }) -join '; ')
            )
    } finally {
        Remove-Item -LiteralPath $proofBRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Issue #216 (Wave B/Agent E deploy-cutover audit): post-update-доказ,
# що фізично залишений на диску застарілий BRAVO.config НЕ впливає на
# ефективну конфігурацію production-entrypoint-а після успішного
# Update-BRAVOServer.ps1. Update-BRAVOServer.ps1 НІКОЛИ не видаляє
# BRAVO.config (виключений з robocopy /XF, ретирування — окрема дія
# оператора) — тож сценарій "стара БRAVO.config лишилась поруч після
# оновлення до 5.3" є звичайним, очікуваним станом парку, а не
# гіпотетичним. Захист від нього — саме
# -DisallowLegacyPrimaryAutoDetect (уже проведений у 14 production/
# operator entrypoint-ів, ci/New-BRAVOReleaseArtifact.ps1/
# LEGACY_CONFIG_AUTOEXEC статично звіряє це на staged-комплекті). Той
# гейт лише скенує ТЕКСТ виклику — тут перевіряється фактична
# RUNTIME-поведінка: ефективна конфігурація дійсно ігнорує вміст файлу.
#
# Окремий child scope (& { ... }): усі фрагменти self-test дот-сорсяться в
# ОДИН scope і ділять ліміт $MaximumVariableCount.
& {
    function Invoke-BRAVOPostUpdateStaleConfigProbe {
        # $DisallowAutoDetect симулює production-entrypoint після Wave B
        # (Archive/Health/Maintenance/DataRestore Runtime.ps1, BRAVO_SETUP.ps1
        # та інші 10) — auto-derived BRAVO.config, залишений на диску без
        # явного наміру оператора, мусить трактуватись як відсутній.
        # Без прапорця відтворюється ДОвave-B/migration-tooling поведінка —
        # використовується лише як контрольний (sanity) прогін нижче, щоб
        # довести, що маркер override дійсно спрацьовує, коли ЩОСЬ його
        # читає (інакше PASS вище був би тавтологією "нічого не сталося").
        param([switch]$DisallowAutoDetect)

        $scenarioRoot = Join-Path ([IO.Path]::GetTempPath()) (
            "BRAVO_POSTUPDATE_STALE_CONFIG_{0}" -f [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($scenarioRoot)
        try {
            # Стара конфігурація 5.2-епохи лишилась ФІЗИЧНО поруч (саме так,
            # як Update-BRAVOServer.ps1 її залишає — /XF BRAVO.config, ніколи
            # не видаляється) за auto-derived шляхом ($ConfigRoot\BRAVO.config),
            # БЕЗ жодного явного -ConfigPath — точний контракт "оператор його
            # не запитував".
            # BackupRoot="" (AUTO) вимагає EffectiveLIMSRoot, похідного від
            # реальної служби BRAVO на хості — на self-test/CI-хості такої
            # служби немає. Тест перевіряє лише RETENTION/FORMAT/BLOCKED/
            # PRESENT, не BackupRoot, тож запікаємо явний літерал (той самий
            # паттерн, що й інші сценарії вище в цьому файлі).
            $staleBackupDir = Join-Path $scenarioRoot 'BACKUP'
            [void][IO.Directory]::CreateDirectory($staleBackupDir)
            $staleBackupRootLiteralLine = '    BackupRoot    = ""'
            $staleKitText = (Get-BRAVOSelfTestLegacyConfigText)
            if (-not $staleKitText.Contains($staleBackupRootLiteralLine)) {
                throw "BRAVO_SELF_TEST.ConfigLoader: у BRAVO.config не знайдено рядок '$staleBackupRootLiteralLine' — оновіть підготовку post-update-stale-config сценарію під нову форму конфігурації"
            }
            $staleText = $staleKitText.Replace(
                $staleBackupRootLiteralLine,
                "    BackupRoot    = '$($staleBackupDir.Replace("'", "''"))'"
            ) + "`r`n" + '$global:logRetentionDays = 999' + "`r`n"
            [IO.File]::WriteAllText(
                (Join-Path $scenarioRoot 'BRAVO.config'), $staleText, (New-Object System.Text.UTF8Encoding($false)))

            # Заблокований ($DisallowAutoDetect) прогін ІГНОРУЄ BRAVO.config
            # повністю й переходить на Import-BravoSyntheticConfiguration —
            # той самий "герметичність на машині без LIMS" паттерн, що й
            # ConfigLoader/NoConfigAutoDerivedPathSucceedsAsSynthetic вище:
            # BackupRoot="" (canonical-дефолт) все ще вимагає
            # EffectiveLIMSRoot, тож синтетичний шлях теж потребує
            # BRAVO.local.config з явним BackupRoot.
            [IO.File]::WriteAllText(
                (Join-Path $scenarioRoot 'BRAVO.local.config'),
                (
                    "@{`r`n" +
                    "    'pathSettings.BackupRoot' = '$($staleBackupDir.Replace("'", "''"))'`r`n" +
                    "}`r`n"
                ),
                (New-Object System.Text.UTF8Encoding($false))
            )

            $disallowArg = if ($DisallowAutoDetect) { ' -DisallowLegacyPrimaryAutoDetect' } else { '' }
            $probeCommand = (
                "try { " +
                "Set-StrictMode -Version 2.0; " +
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "[void](Import-BravoConfiguration -ConfigRoot '$scenarioRoot' -RuntimeRoot '$root'$disallowArg 3>`$null); " +
                "'RETENTION=' + [string]`$global:logRetentionDays + " +
                "';FORMAT=' + [string]`$global:BravoConfigurationMetadata.Format + " +
                "';BLOCKED=' + [string]`$global:BravoConfigurationMetadata.PrimaryConfigAutoDetectBlocked + " +
                "';PRESENT=' + [string]`$global:BravoConfigurationMetadata.PrimaryConfigPresentOnDisk" +
                "} catch { 'THREW: ' + `$_.Exception.Message }"
            )
            $probeOutput = [string](
                Invoke-BRAVOConfigLoaderProbe -Command $probeCommand
            )
            return $probeOutput.Trim()
        } finally {
            Remove-Item -LiteralPath $scenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Sanity/контроль: БЕЗ -DisallowLegacyPrimaryAutoDetect застарілий
    # файл дійсно підхоплюється (доводить, що маркер override взагалі щось
    # означає — інакше PASS нижче був би тавтологією). Це той самий шлях,
    # яким і сьогодні йде migration/deploy-інструментарій (Get-
    # BRAVOConfigSiteDelta.ps1, Update-BRAVOServer.ps1 preflight-пробник) —
    # свідомо, не регресія.
    $postUpdateBaseline = Invoke-BRAVOPostUpdateStaleConfigProbe
    Test-BRAVOCondition `
        -Condition (
            $postUpdateBaseline.Contains('RETENTION=999') -and
            $postUpdateBaseline.Contains('PRESENT=True') -and
            -not $postUpdateBaseline.StartsWith('THREW')
        ) `
        -Name "ConfigV2/PostUpdateStaleConfigBaselineAutoDetectPicksItUp" `
        -Failure ("контрольний прогін без -DisallowLegacyPrimaryAutoDetect мусить довести, що маркер override " +
            "(logRetentionDays=999) взагалі читається з auto-derived BRAVO.config — інакше наступна перевірка " +
            "нічого не доводить; отримано '$postUpdateBaseline'")

    # --- Основний доказ (Proof I, Agent E): production-entrypoint після
    # успішного Update-BRAVOServer.ps1, з фізично залишеним на диску
    # застарілим BRAVO.config, ІГНОРУЄ його повністю — ефективна
    # logRetentionDays лишається canonical-дефолтом (31), а не 999.
    $postUpdateProtected = Invoke-BRAVOPostUpdateStaleConfigProbe -DisallowAutoDetect
    Test-BRAVOCondition `
        -Condition (
            $postUpdateProtected.Contains('RETENTION=31') -and
            $postUpdateProtected.Contains('FORMAT=synthetic-no-config') -and
            $postUpdateProtected.Contains('BLOCKED=True') -and
            $postUpdateProtected.Contains('PRESENT=True') -and
            -not $postUpdateProtected.StartsWith('THREW')
        ) `
        -Name "ConfigV2/PostUpdateStaleConfigIgnoredByProductionEntrypoint" `
        -Failure ("фізично залишений на диску застарілий BRAVO.config (issue #216, стан сервера ПІСЛЯ успішного " +
            "Update-BRAVOServer.ps1, який ніколи його не видаляє) мусить давати НУЛЬОВИЙ ефект на ефективну " +
            "конфігурацію production-entrypoint-а, що передає -DisallowLegacyPrimaryAutoDetect: очікувалось " +
            "RETENTION=31 (canonical-дефолт), FORMAT=synthetic-no-config, BLOCKED=True, PRESENT=True; отримано '$postUpdateProtected'")
}

# Issue #216 (Phase 11, п.8): "malformed local config fails closed" мав
# fail-closed throw-шляхи в Read-BRAVOLocalConfigurationOverrides
# (BRAVO_CONFIG_LOADER.ps1: "мусить бути data-only hashtable", "мусить
# повертати hashtable", "порожній ключ неприпустимий") від початку
# ConvertFrom-BRAVOConfigurationDataFileText-переходу (#154, B1), але без
# regression-покриття НА РІВНІ повного Import-BravoConfiguration-конвеєра
# (лише DataFile/Rejects*-тести на самому парсері вище в цьому файлі,
# т.з. #154). Тут — наскрізний доказ: реальний зіпсований
# BRAVO.local.config кидає той самий throw через увесь конвеєр, і жоден
# валідний сусідній override з того самого некоректного файлу не потрапляє
# в ефективний `$global:`-стан (той самий атомарний контракт, що
# Authorization/LoaderAtomicMergeRejectsWholeLocalLayer вище, але
# тригер — синтаксична/типова несправність файлу, не DENY-лист).
& {
    function Invoke-BRAVOMalformedLocalConfigProbe {
        param(
            [Parameter(Mandatory = $true)][string]$LocalConfigBody
        )
        $scenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
            ("BRAVO_MALFORMED_LOCAL_{0}" -f [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($scenarioRoot)
        try {
            [IO.File]::WriteAllText(
                (Join-Path $scenarioRoot 'BRAVO.local.config'), $LocalConfigBody, (New-Object System.Text.UTF8Encoding($false)))
            # Немає BRAVO.config: throw у Read-BRAVOLocalConfigurationOverrides
            # трапляється ДО обчислення BackupRoot/derivation, тому синтетичний
            # no-config-шлях сюди не доходить — герметичний BackupRoot-фікстур
            # не потрібен (на відміну від PostUpdateStaleConfig-проб вище).
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
                Invoke-BRAVOConfigLoaderProbe -Command $probeCommand
            )
            return $probeOutput.Trim()
        } finally {
            Remove-Item -LiteralPath $scenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- ConfigLoader/MalformedLocalConfigSyntaxErrorFailsClosed ---
    # Незакрита дужка — синтаксична помилка ловиться самим парсером AST
    # (ConvertFrom-BRAVOConfigurationDataFileText), обгортається
    # "мусить бути data-only hashtable".
    $malformedSyntaxResult = Invoke-BRAVOMalformedLocalConfigProbe -LocalConfigBody "@{`r`n    'archiveRetentionDays' = 999`r`n"
    Test-BRAVOCondition `
        -Condition (
            $malformedSyntaxResult.StartsWith('THREW:') -and
            $malformedSyntaxResult.Contains('мусить бути data-only hashtable') -and
            $malformedSyntaxResult.Contains('ArchiveRetentionDaysAfterThrow=<unset>')
        ) `
        -Name "ConfigLoader/MalformedLocalConfigSyntaxErrorFailsClosed" `
        -Failure "BRAVO.local.config із синтаксичною помилкою (незакрита @{ ) мусить fail closed через увесь Import-BravoConfiguration-конвеєр з повідомленням про data-only hashtable, і archiveRetentionDays НЕ повинен потрапити в ефективний `$global:-стан; отримано: $malformedSyntaxResult"

    # --- ConfigLoader/MalformedLocalConfigNonHashtableTopLevelFailsClosed ---
    # Валідний PowerShell-літерал, але НЕ hashtable на верхньому рівні —
    # масив рядків. ConvertFrom-BRAVOConfigurationDataFileText сам кидає
    # виняток на такій формі (не hashtable-літерал), і Read-
    # BRAVOLocalConfigurationOverrides ловить його тим самим зовнішнім
    # catch, що й синтаксичну помилку вище — обгортає тим самим "мусить
    # бути data-only hashtable" (перевірено емпірично: рядок 348
    # BRAVO_CONFIG_LOADER.ps1, "мусить повертати hashtable", технічно
    # недосяжний через публічний шлях парсера — цей парсер завжди або
    # повертає справжній [hashtable], або кидає виняток раніше).
    $malformedArrayResult = Invoke-BRAVOMalformedLocalConfigProbe -LocalConfigBody "@('archiveRetentionDays', 999)`r`n"
    Test-BRAVOCondition `
        -Condition (
            $malformedArrayResult.StartsWith('THREW:') -and
            $malformedArrayResult.Contains('мусить бути data-only hashtable') -and
            $malformedArrayResult.Contains('ArchiveRetentionDaysAfterThrow=<unset>')
        ) `
        -Name "ConfigLoader/MalformedLocalConfigNonHashtableTopLevelFailsClosed" `
        -Failure "BRAVO.local.config, що повертає масив замість hashtable, мусить fail closed через увесь конвеєр з повідомленням про очікуваний data-only hashtable, і archiveRetentionDays НЕ повинен потрапити в ефективний `$global:-стан; отримано: $malformedArrayResult"

    # --- ConfigLoader/MalformedLocalConfigEmptyKeyFailsClosed ---
    # Синтаксично коректний hashtable, але з порожнім ключем поруч із
    # валідним override — доводить атомарність: сусідній валідний
    # archiveRetentionDays теж НЕ застосовується.
    $malformedEmptyKeyResult = Invoke-BRAVOMalformedLocalConfigProbe -LocalConfigBody (
        "@{`r`n" +
        "    'archiveRetentionDays' = 999`r`n" +
        "    '' = 'orphaned-value'`r`n" +
        "}`r`n"
    )
    Test-BRAVOCondition `
        -Condition (
            $malformedEmptyKeyResult.StartsWith('THREW:') -and
            $malformedEmptyKeyResult.Contains('порожній ключ неприпустимий') -and
            $malformedEmptyKeyResult.Contains('ArchiveRetentionDaysAfterThrow=<unset>')
        ) `
        -Name "ConfigLoader/MalformedLocalConfigEmptyKeyFailsClosed" `
        -Failure "BRAVO.local.config з порожнім ключем поруч із валідним override мусить fail closed ЦІЛИМ шаром (атомарно) — сусідній archiveRetentionDays=999 НЕ повинен потрапити в ефективний `$global:-стан; отримано: $malformedEmptyKeyResult"
}

# --- ConfigLoader/ProbesShareOneChildProcess: усі проби фрагмента досі
# пройшли через ОДИН дочірній раннер (не в батьківському процесі), кожна
# записала результат, і жодна не побачила канарок попередньої: глобальної
# змінної (свіжий runspace) і змінної середовища (раннер відновлює
# середовище після кожної проби). Остання секція з пробами — тож раннер
# одразу зупиняється.
& {
    $probeBatchWorker = $script:BRAVOConfigLoaderProbeWorker
    $probeBatchIssued = [int]$probeBatchWorker.Issued
    $probeBatchResults = @($probeBatchWorker.Results)
    $probeBatchProcessIds = @($probeBatchResults | ForEach-Object { [string]$_.ProcessId } | Sort-Object -Unique)
    $probeBatchLeaks = @($probeBatchResults | Where-Object { -not [string]::IsNullOrEmpty([string]$_.Leaks) } |
        ForEach-Object { "#$($_.Index): $($_.Leaks)" })
    $probeBatchFailure = [string]$probeBatchWorker.Failure
    Stop-BRAVOConfigLoaderProbeWorker
    Test-BRAVOCondition `
        -Condition (
            $probeBatchIssued -ge 2 -and
            $probeBatchResults.Count -eq $probeBatchIssued -and
            $probeBatchProcessIds.Count -eq 1 -and
            $probeBatchProcessIds[0] -ne [string]$PID -and
            $probeBatchLeaks.Count -eq 0 -and
            [string]::IsNullOrEmpty($probeBatchFailure)
        ) `
        -Name "ConfigLoader/ProbesShareOneChildProcess" `
        -Failure "проби loader-а мають виконатися в одному дочірньому раннері, кожна у свіжому runspace і з власним результатом; проб $probeBatchIssued, результатів $($probeBatchResults.Count), PID раннера: $($probeBatchProcessIds -join ', ') (батько $PID), витоки канарок: $($probeBatchLeaks -join '; '), збій раннера: '$probeBatchFailure'"
}
} catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'ConfigLoader/Authorization' } }
if (Enter-BRAVOSelfTestSection -Name 'ConfigLoader/ConfigV2RegressionMatrix' -DependsOn 'ConfigLoader/RequireAdministratorMissingBlocks', 'ConfigLoader/Authorization') { try {

# ============================================================
# Issue #154 (B7): регресійна матриця Config V2 на 5.3-шляху.
#
# Усі сценарії нижче йдуть через ТОЙ САМИЙ канонічний ланцюжок, що й
# production: Import-BravoConfiguration -DisallowLegacyPrimaryAutoDetect
# без BRAVO.config (або з підкладеним, але заблокованим), повний знімок
# за канонічним переліком Get-BRAVOEffectiveConfigurationVariableName
# (спільний захоплювач Invoke-BRAVOSelfTestEffectiveSnapshotCapture вище;
# B7 бере його RawSnapshot — без розгортання верхньорівневих масивів, див.
# коментар у дочірньому шаблоні), порівняння —
# Compare-BRAVOConfigurationGraph (BRAVO.Configuration.Delta), міграція —
# реальний deploy\Get-BRAVOConfigSiteDelta.ps1. Другої моделі
# конфігурації тут немає: жодного власного парсера чи власного переліку
# ключів — лише канонічні Get-BRAVODefaultConfiguration,
# Get-BRAVOConfigurationSchemaAuthorizationClass і
# ConvertTo-BRAVOConfiguratorPowerShellLiteral.
#
# Категорії (нумерація — зі звіту про прогалини B7):
#   (a) виклик Import-BravoConfiguration у кожному з чотирьох runtime-ів
#       (і в heartbeat) дає той самий канонічний знімок, що й еталонний
#       виклик, і не виконує підкладений BRAVO.config;
#   (c) дозволені локальні перевизначення на 5.3-шляху: масив, явний @(),
#       скаляри, вкладений вузол зі збереженням сусідів;
#   (d) security-/execution-чутливі та похідні ключі через
#       BRAVO.local.config відхиляються fail closed, без часткового
#       застосування;
#   (e) зіпсований/невідомий local-config — fail closed із діагностикою,
#       що називає файл (або ConfigRoot) і ключ;
#   (f)(g) міграція 5.2 -> 5.3 реальним інструментом: повний ефективний
#       знімок до == після, дельта детермінована, повторна міграція вже
#       мігрованого сервера нічого не додає.
# Категорії (b) і (h) покриті Proof B / PostUpdateStaleConfig вище та
# ReleaseGate/* у BRAVO_SELF_TEST.Governance.ps1.
#
# Окремий child scope (& { ... }): фрагменти self-test дот-сорсяться в
# ОДИН scope і ділять ліміт $MaximumVariableCount.
# ============================================================
& {
    if (-not (Get-Command -Name 'Get-BRAVODefaultConfiguration' -ErrorAction SilentlyContinue)) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.psd1') -ErrorAction Stop
    }
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Delta.psd1') -Force
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Schema.psd1') -Force
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configurator\BRAVO.Configurator.Effective.psd1') -Force

    $b7Root = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_B7_MATRIX_{0}" -f [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($b7Root)
    $b7Utf8 = New-Object System.Text.UTF8Encoding($false)
    $b7Defaults = Get-BRAVODefaultConfiguration
    $b7CanonicalInvocation = 'Import-BravoConfiguration -ConfigRoot $ConfigRoot -RuntimeRoot $RuntimeRoot -DisallowLegacyPrimaryAutoDetect'
    # Дочірні процеси успадковують середовище: наявний у сесії
    # BRAVO_ALLOW_WEAKENED_SECURITY=1 відкрив би escape hatch для
    # requireAdministrator і зробив би (d) недетермінованим.
    $b7PreviousWeakenedSecurity = $env:BRAVO_ALLOW_WEAKENED_SECURITY
    Remove-Item -Path 'Env:BRAVO_ALLOW_WEAKENED_SECURITY' -ErrorAction SilentlyContinue

    function New-BRAVOB7ConfigRoot {
        # Ізольований ConfigRoot з BRAVO.local.config: явний BackupRoot
        # (герметичність на машині без LIMS — той самий прийом, що й Proof B)
        # плюс рядки override-ів "'шлях' = літерал".
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [string[]]$OverrideLine = @(),
            [switch]$NoLocalConfig
        )
        $configRoot = Join-Path $b7Root $Name
        [void][IO.Directory]::CreateDirectory($configRoot)
        $backupDir = Join-Path $configRoot 'SITE_BACKUP'
        [void][IO.Directory]::CreateDirectory($backupDir)
        if (-not $NoLocalConfig) {
            $body = "@{`r`n    'pathSettings.BackupRoot' = '$($backupDir.Replace("'", "''"))'`r`n"
            foreach ($line in @($OverrideLine)) {
                $body += "    $line`r`n"
            }
            $body += "}`r`n"
            [IO.File]::WriteAllText((Join-Path $configRoot 'BRAVO.local.config'), $body, $b7Utf8)
        }
        return $configRoot
    }

    function Get-BRAVOB7DefaultLeafValue {
        # Значення канонічного дефолту за dot-шляхом реєстру авторизації.
        param([Parameter(Mandatory = $true)][string]$Path)
        $node = $b7Defaults
        foreach ($segment in $Path.Split('.')) {
            if (-not ($node -is [System.Collections.IDictionary]) -or -not $node.Contains($segment)) {
                throw "B7: канонічний дефолт не містить шляху '$Path' (сегмент '$segment')"
            }
            $node = $node[$segment]
        }
        return ,$node
    }

    function Get-BRAVOB7UnexpectedDifference {
        # Відмінності повного знімка поза явним allowlist-ом dot-шляхів
        # (точні шляхи, не префікси вузлів).
        param($Reference, $Candidate, [string[]]$AllowedPath = @())
        return @(Compare-BRAVOConfigurationGraph `
                -ReferenceConfiguration $Reference `
                -CandidateConfiguration $Candidate `
                -IncludeMissingInCandidate |
            Where-Object { $null -ne $_ -and $AllowedPath -notcontains $_.Path })
    }

    function Get-BRAVOB7CallSiteInvocationText {
        # (a) Точний виклик Import-BravoConfiguration з файлу entrypoint-а
        # (AST, Extent.Text — жодного переписування параметрів чи
        # switch-прив'язок, зокрема -DisallowLegacyPrimaryAutoDetect[:x]).
        # Змінні в аргументах зв'язуються за РОЛЛЮ — параметром, якому
        # змінна передана напряму: ConfigRoot/ConfigPath/RuntimeRoot/
        # ConfigPathWasExplicit. Змінна без ролі чи з двома ролями —
        # явна відмова (fail closed), а не здогад.
        param([Parameter(Mandatory = $true)][string]$RelativePath)

        $sourcePath = Join-Path $root $RelativePath
        $parseErrors = $null
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            throw "B7: не вдалося розібрати $RelativePath : $($parseErrors[0].Message)"
        }
        $calls = @($fileAst.FindAll({
                    param($astNode)
                    ($astNode -is [System.Management.Automation.Language.CommandAst]) -and
                    [string]::Equals([string]$astNode.GetCommandName(), 'Import-BravoConfiguration', [StringComparison]::OrdinalIgnoreCase)
                }, $true))
        if ($calls.Count -ne 1) {
            throw "B7: у $RelativePath очікувався рівно один виклик Import-BravoConfiguration, знайдено $($calls.Count)"
        }
        $call = $calls[0]
        $literalVariableNames = @('true', 'false', 'null')
        $switchParameterNames = @('ConfigPathWasExplicit', 'DisallowLegacyPrimaryAutoDetect', 'PassThru')
        $bindableRoles = @('ConfigRoot', 'ConfigPath', 'RuntimeRoot', 'ConfigPathWasExplicit')
        $roleByVariable = @{}
        $elements = @($call.CommandElements)
        for ($elementIndex = 1; $elementIndex -lt $elements.Count; $elementIndex++) {
            $element = $elements[$elementIndex]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $argumentAst = $element.Argument
            if ($null -eq $argumentAst -and
                ($elementIndex + 1) -lt $elements.Count -and
                $elements[$elementIndex + 1] -isnot [System.Management.Automation.Language.CommandParameterAst] -and
                $switchParameterNames -notcontains $element.ParameterName) {
                $argumentAst = $elements[$elementIndex + 1]
            }
            if ($argumentAst -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $argumentVariableName = $argumentAst.VariablePath.UserPath
            if ($literalVariableNames -contains $argumentVariableName) { continue }
            if ($roleByVariable.ContainsKey($argumentVariableName) -and $roleByVariable[$argumentVariableName] -ne $element.ParameterName) {
                throw "B7: у $RelativePath змінна `$$argumentVariableName передана двом параметрам ($($roleByVariable[$argumentVariableName]), $($element.ParameterName)) — роль неоднозначна"
            }
            $roleByVariable[$argumentVariableName] = $element.ParameterName
        }
        $callStartOffset = $call.Extent.StartOffset
        $invocationText = $call.Extent.Text
        $variableAsts = @($call.FindAll({ param($astNode) $astNode -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
            Where-Object { $literalVariableNames -notcontains $_.VariablePath.UserPath } |
            Sort-Object -Property { $_.Extent.StartOffset } -Descending)
        foreach ($variableAst in $variableAsts) {
            $variableName = $variableAst.VariablePath.UserPath
            if (-not $roleByVariable.ContainsKey($variableName) -or $bindableRoles -notcontains $roleByVariable[$variableName]) {
                throw "B7: у $RelativePath змінна `$$variableName не має однозначної ролі серед $($bindableRoles -join '/') — виклик не можна відтворити поведінково"
            }
            $relativeStart = $variableAst.Extent.StartOffset - $callStartOffset
            $invocationText = $invocationText.Substring(0, $relativeStart) + '$b7Bind' + $roleByVariable[$variableName] +
                $invocationText.Substring($relativeStart + $variableAst.Extent.Text.Length)
        }
        # Контекст AUTO-наміру: оператор -ConfigPath не задавав, entrypoint
        # сам вивів <ConfigRoot>\BRAVO.config — рівно той випадок, коли
        # підкладений файл міг би виконатись без наміру оператора.
        return (
            "`$b7BindConfigRoot = `$ConfigRoot`r`n" +
            "`$b7BindConfigPath = Join-Path `$ConfigRoot 'BRAVO.config'`r`n" +
            "`$b7BindRuntimeRoot = `$RuntimeRoot`r`n" +
            "`$b7BindConfigPathWasExplicit = `$false`r`n" +
            $invocationText + "`r`n"
        )
    }

    try {
        # ==========================================================
        # (a) Виклик кожного runtime-а -> канонічний знімок + Proof B.
        # ==========================================================
        $b7CallSiteRoot = New-BRAVOB7ConfigRoot -Name 'CALLSITE'
        $b7CallSiteReference = Invoke-BRAVOSelfTestEffectiveSnapshotCapture -WorkRoot $b7Root -ConfigRoot $b7CallSiteRoot `
            -Label 'CALLSITE_REFERENCE' -InvocationText $b7CanonicalInvocation
        if (-not $b7CallSiteReference.Succeeded) {
            throw "B7(a): еталонний знімок не знято: $($b7CallSiteReference.ErrorMessage) $($b7CallSiteReference.StdErr)"
        }
        $b7PoisonBackupDir = Join-Path $b7CallSiteRoot 'POISON_BACKUP'
        [void][IO.Directory]::CreateDirectory($b7PoisonBackupDir)
        $b7BackupRootLiteralLine = '    BackupRoot    = ""'
        $b7LegacyText = Get-BRAVOSelfTestLegacyConfigText
        if (-not $b7LegacyText.Contains($b7BackupRootLiteralLine)) {
            throw "B7: у legacy-фікстурі не знайдено рядок '$b7BackupRootLiteralLine' — оновіть підготовку B7-сценаріїв"
        }
        [IO.File]::WriteAllText(
            (Join-Path $b7CallSiteRoot 'BRAVO.config'),
            ($b7LegacyText.Replace($b7BackupRootLiteralLine, "    BackupRoot    = '$($b7PoisonBackupDir.Replace("'", "''"))'") +
                "`r`n`$global:logRetentionDays = 999`r`n`$global:bravoSettings['InstitutionName'] = 'B7_POISONED_INSTITUTION'`r`n"),
            $b7Utf8)

        # Контроль (не тавтологія): БЕЗ прапорця той самий файл реально
        # читається й змінює ефективні значення.
        $b7PoisonControl = Invoke-BRAVOSelfTestEffectiveSnapshotCapture -WorkRoot $b7Root -ConfigRoot $b7CallSiteRoot `
            -Label 'CALLSITE_POISON_CONTROL' -InvocationText 'Import-BravoConfiguration -ConfigRoot $ConfigRoot -RuntimeRoot $RuntimeRoot'
        Test-BRAVOCondition `
            -Condition (
                $b7PoisonControl.Succeeded -and
                [string]$b7PoisonControl.RawSnapshot['logRetentionDays'] -eq '999' -and
                [string]$b7PoisonControl.RawSnapshot['bravoSettings']['InstitutionName'] -eq 'B7_POISONED_INSTITUTION'
            ) `
            -Name 'ConfigLoader/B7CallSitePoisonControlIsLiveWithoutFlag' `
            -Failure "контроль (a): без -DisallowLegacyPrimaryAutoDetect підкладений BRAVO.config мусить реально діяти (logRetentionDays=999), інакше перевірки call-site нижче нічого не доводять; Succeeded=$($b7PoisonControl.Succeeded) $($b7PoisonControl.ErrorMessage)"

        $b7CallSiteTargets = [ordered]@{
            'ArchiveRuntime'      = 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1'
            'MaintenanceRuntime'  = 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'
            'HealthRuntime'       = 'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1'
            'DataRestoreRuntime'  = 'modules\BRAVO.DataRestore\BRAVO.DataRestore.Runtime.ps1'
            'OperationsHeartbeat' = 'BRAVO_OPERATIONS_HEARTBEAT.ps1'
        }
        $b7ProofBProvenancePaths = @(
            'BravoConfigurationMetadata.LoadedAt',
            'BravoConfigurationMetadata.PrimaryConfigPresentOnDisk',
            'BravoConfigurationMetadata.PrimaryConfigAutoDetectBlocked'
        )
        foreach ($b7CallSiteName in @($b7CallSiteTargets.Keys)) {
            $b7CallSiteRelativePath = $b7CallSiteTargets[$b7CallSiteName]
            $b7CallSiteError = ''
            $b7CallSiteUnexpected = @()
            $b7CallSiteBlocked = $false
            try {
                $b7CallSiteInvocation = Get-BRAVOB7CallSiteInvocationText -RelativePath $b7CallSiteRelativePath
                $b7CallSiteCapture = Invoke-BRAVOSelfTestEffectiveSnapshotCapture -WorkRoot $b7Root -ConfigRoot $b7CallSiteRoot `
                    -Label "CALLSITE_$b7CallSiteName" -InvocationText $b7CallSiteInvocation
                if ($b7CallSiteCapture.Succeeded) {
                    $b7CallSiteBlocked = ($b7CallSiteCapture.RawSnapshot['BravoConfigurationMetadata']['PrimaryConfigAutoDetectBlocked'] -eq $true)
                    $b7CallSiteUnexpected = @(Get-BRAVOB7UnexpectedDifference `
                            -Reference $b7CallSiteReference.RawSnapshot -Candidate $b7CallSiteCapture.RawSnapshot -AllowedPath $b7ProofBProvenancePaths)
                } else {
                    $b7CallSiteError = "$($b7CallSiteCapture.ErrorMessage) $($b7CallSiteCapture.StdErr)"
                }
            } catch {
                $b7CallSiteError = $_.Exception.Message
            }
            Test-BRAVOCondition `
                -Condition ([string]::IsNullOrEmpty($b7CallSiteError) -and $b7CallSiteBlocked -and $b7CallSiteUnexpected.Count -eq 0) `
                -Name "ConfigLoader/B7CallSiteCanonicalSnapshot$b7CallSiteName" `
                -Failure (
                    "точний виклик Import-BravoConfiguration з $b7CallSiteRelativePath (AUTO-намір, підкладений BRAVO.config поруч) мусить " +
                    "дати ТОЙ САМИЙ повний знімок, що й еталон -DisallowLegacyPrimaryAutoDetect, з заблокованим auto-detect; " +
                    "помилка='$b7CallSiteError' Blocked=$b7CallSiteBlocked, неочікуваних відмінностей $($b7CallSiteUnexpected.Count): " +
                    (($b7CallSiteUnexpected | ForEach-Object { "$($_.Path) [$($_.Kind)]" }) -join '; ')
                )
        }

        # ==========================================================
        # (c) Дозволені перевизначення на 5.3-шляху.
        # ==========================================================
        $b7OverrideRoot = New-BRAVOB7ConfigRoot -Name 'OVERRIDES' -OverrideLine @(
            "'maintenanceSettings.Limits.ExcludedDrives' = @('X:\', 'Y:\')",
            "'maintenanceSettings.Limits.MdFileSizeExclusions' = @('B7ONLY.md')",
            "'lunchArchiveCleanupDirectories' = @()",
            "'archiveRetentionDays' = 200",
            "'enableOrphanTempCleanup' = `$false",
            "'sftpHostTemplate' = '{0}.b7-selftest.test'",
            "'bravoSettings.NotificationRouting' = @{ 'SUCCESS' = 'alerts' }"
        )
        $b7Override = Invoke-BRAVOSelfTestEffectiveSnapshotCapture -WorkRoot $b7Root -ConfigRoot $b7OverrideRoot `
            -Label 'OVERRIDES' -InvocationText $b7CanonicalInvocation
        $b7OverrideSnapshot = if ($b7Override.Succeeded) { $b7Override.RawSnapshot } else { @{} }
        $b7OverrideFailureContext = "Succeeded=$($b7Override.Succeeded) $($b7Override.ErrorMessage)"

        $b7OverrideMetadataOk = $false
        if ($b7Override.Succeeded) {
            $b7OverrideMetadata = $b7OverrideSnapshot['BravoConfigurationMetadata']
            $b7ExpectedOverrideKeys = @(
                'archiveRetentionDays', 'bravoSettings.NotificationRouting', 'enableOrphanTempCleanup',
                'lunchArchiveCleanupDirectories', 'maintenanceSettings.Limits.ExcludedDrives',
                'maintenanceSettings.Limits.MdFileSizeExclusions', 'pathSettings.BackupRoot', 'sftpHostTemplate'
            )
            $b7ActualOverrideKeys = @(@($b7OverrideMetadata['LocalConfigOverrides']) | Sort-Object)
            $b7OverrideMetadataOk = (
                [string]$b7OverrideMetadata['Format'] -eq 'synthetic-no-config' -and
                $b7OverrideMetadata['PrimaryConfigPresent'] -eq $false -and
                $b7OverrideMetadata['PrimaryConfigPresentOnDisk'] -eq $false -and
                (($b7ActualOverrideKeys -join '|') -eq (($b7ExpectedOverrideKeys | Sort-Object) -join '|'))
            )
        }
        Test-BRAVOCondition `
            -Condition $b7OverrideMetadataOk `
            -Name 'ConfigLoader/B7LocalOverridesLoadOnPure53Path' `
            -Failure "BRAVO.local.config без BRAVO.config на диску мусить завантажуватись як synthetic-no-config і обліковувати рівно 8 перевизначених шляхів; $b7OverrideFailureContext"

        $b7OverrideLimits = if ($b7Override.Succeeded) { $b7OverrideSnapshot['maintenanceSettings']['Limits'] } else { @{} }
        $b7DefaultLimits = $b7Defaults['maintenanceSettings']['Limits']
        Test-BRAVOCondition `
            -Condition (
                $b7Override.Succeeded -and
                (@($b7OverrideLimits['ExcludedDrives']) -join '|') -eq 'X:\|Y:\' -and
                (@($b7OverrideLimits['MdFileSizeExclusions']) -join '|') -eq 'B7ONLY.md' -and
                (@($b7DefaultLimits['MdFileSizeExclusions']) -join '|') -ne 'B7ONLY.md'
            ) `
            -Name 'ConfigLoader/B7LocalOverrideArrayReplacesDefaultOn53Path' `
            -Failure "масив із BRAVO.local.config мусить ЗАМІНЮВАТИ дефолт (не доповнювати): ExcludedDrives='$(@($b7OverrideLimits['ExcludedDrives']) -join '|')' MdFileSizeExclusions='$(@($b7OverrideLimits['MdFileSizeExclusions']) -join '|')'; $b7OverrideFailureContext"

        # Пряме присвоєння, а не `$x = if (...) { ... }`: вивід if-оператора
        # іде конвеєром і розгорнув би порожній масив у $null.
        $b7EmptyArrayValue = $null
        if ($b7Override.Succeeded) { $b7EmptyArrayValue = $b7OverrideSnapshot['lunchArchiveCleanupDirectories'] }
        Test-BRAVOCondition `
            -Condition (
                $b7Override.Succeeded -and
                $null -ne $b7EmptyArrayValue -and
                $b7EmptyArrayValue -isnot [string] -and
                @($b7EmptyArrayValue).Count -eq 0 -and
                @($b7Defaults['lunchArchiveCleanupDirectories']).Count -gt 0
            ) `
            -Name 'ConfigLoader/B7LocalOverrideExplicitEmptyArrayOn53Path' `
            -Failure "явний @() у BRAVO.local.config мусить давати порожній масив, а не успадкований дефолт ($(@($b7Defaults['lunchArchiveCleanupDirectories']) -join ',')); отримано '$(@($b7EmptyArrayValue) -join ',')' (null=$($null -eq $b7EmptyArrayValue)); $b7OverrideFailureContext"

        Test-BRAVOCondition `
            -Condition (
                $b7Override.Succeeded -and
                (Get-BRAVOParityValueKind -Value $b7OverrideSnapshot['archiveRetentionDays']) -eq 'Number' -and
                [int]$b7OverrideSnapshot['archiveRetentionDays'] -eq 200 -and
                [int]$b7Defaults['archiveRetentionDays'] -ne 200 -and
                $b7OverrideSnapshot['enableOrphanTempCleanup'] -is [bool] -and
                $b7OverrideSnapshot['enableOrphanTempCleanup'] -eq $false -and
                $b7Defaults['enableOrphanTempCleanup'] -eq $true -and
                $b7OverrideSnapshot['sftpHostTemplate'] -is [string] -and
                $b7OverrideSnapshot['sftpHostTemplate'] -eq '{0}.b7-selftest.test'
            ) `
            -Name 'ConfigLoader/B7LocalOverrideScalarsOn53Path' `
            -Failure "скаляри з BRAVO.local.config (int/bool/string) мусять потрапити в ефективний стан зі збереженням типу; archiveRetentionDays='$($b7OverrideSnapshot['archiveRetentionDays'])' enableOrphanTempCleanup='$($b7OverrideSnapshot['enableOrphanTempCleanup'])' sftpHostTemplate='$($b7OverrideSnapshot['sftpHostTemplate'])'; $b7OverrideFailureContext"

        $b7NestedSiblingDiffs = New-Object System.Collections.Generic.List[string]
        if ($b7Override.Succeeded) {
            $b7OverrideRouting = $b7OverrideSnapshot['bravoSettings']['NotificationRouting']
            $b7DefaultRouting = $b7Defaults['bravoSettings']['NotificationRouting']
            if ([string]$b7OverrideRouting['SUCCESS'] -ne 'alerts' -or [string]$b7DefaultRouting['SUCCESS'] -eq 'alerts') {
                [void]$b7NestedSiblingDiffs.Add("NotificationRouting.SUCCESS='$($b7OverrideRouting['SUCCESS'])' (дефолт '$($b7DefaultRouting['SUCCESS'])')")
            }
            foreach ($b7RoutingKey in @($b7DefaultRouting.Keys)) {
                if ($b7RoutingKey -eq 'SUCCESS') { continue }
                if ([string]$b7OverrideRouting[$b7RoutingKey] -ne [string]$b7DefaultRouting[$b7RoutingKey]) {
                    [void]$b7NestedSiblingDiffs.Add("NotificationRouting.$b7RoutingKey")
                }
            }
            foreach ($b7LimitsKey in @($b7DefaultLimits.Keys)) {
                if (@('ExcludedDrives', 'MdFileSizeExclusions') -contains $b7LimitsKey) { continue }
                if ([string]$b7OverrideLimits[$b7LimitsKey] -ne [string]$b7DefaultLimits[$b7LimitsKey]) {
                    [void]$b7NestedSiblingDiffs.Add("maintenanceSettings.Limits.$b7LimitsKey")
                }
            }
        } else {
            [void]$b7NestedSiblingDiffs.Add('capture failed')
        }
        Test-BRAVOCondition `
            -Condition ($b7NestedSiblingDiffs.Count -eq 0) `
            -Name 'ConfigLoader/B7LocalOverrideNestedNodePreservesSiblingsOn53Path' `
            -Failure "вкладений вузол із BRAVO.local.config мусить змінювати лише перевизначені листи, а сусідні листи того самого вузла — лишати канонічними; розбіжності: $($b7NestedSiblingDiffs -join ', '); $b7OverrideFailureContext"

        # (d), позитивний бік: похідні security-значення на чистому
        # 5.3-графі обчислюються канонічно від RuntimeRoot — їх не можна
        # задати конфігурацією (див. негативні сценарії нижче).
        $b7ToolIntegrity = if ($b7Override.Succeeded) { $b7OverrideSnapshot['toolIntegritySettings'] } else { @{} }
        Test-BRAVOCondition `
            -Condition (
                $b7Override.Succeeded -and
                [string]$b7ToolIntegrity['Mode'] -eq 'Enforce' -and
                [string]$b7ToolIntegrity['ManifestPath'] -eq (Join-Path (Join-Path $root 'Tools') 'TOOLS_MANIFEST.json')
            ) `
            -Name 'ConfigLoader/B7ToolIntegrityDerivedCanonicallyOn53Path' `
            -Failure "toolIntegritySettings на 5.3-шляху мусить бути канонічною деривацією (Mode=Enforce, ManifestPath=<RuntimeRoot>\Tools\TOOLS_MANIFEST.json); отримано Mode='$($b7ToolIntegrity['Mode'])' ManifestPath='$($b7ToolIntegrity['ManifestPath'])'; $b7OverrideFailureContext"

        # ==========================================================
        # (d) Security-/execution-чутливі та похідні ключі.
        # ==========================================================
        # Кожен DENY_*-лист канонічного реєстру авторизації, заданий РІВНО
        # своїм дефолтним значенням (не послабленням): відмова мусить
        # залежати від класу листа, а не від запропонованого значення.
        # Перелік береться з реєстру, тож новий DENY-лист покривається
        # автоматично. Сусідній дозволений override (archiveRetentionDays)
        # доводить атомарність: жоден лист зі шару не застосовано.
        $b7AuthorizationClass = Get-BRAVOConfigurationSchemaAuthorizationClass
        $b7DenyLeaves = @(@($b7AuthorizationClass.Keys) | Where-Object { ([string]$b7AuthorizationClass[$_].Class).StartsWith('DENY_') } | Sort-Object)
        $b7DenyLines = New-Object System.Collections.Generic.List[string]
        foreach ($b7DenyLeaf in $b7DenyLeaves) {
            $b7DenyLiteral = ConvertTo-BRAVOConfiguratorPowerShellLiteral -Value (Get-BRAVOB7DefaultLeafValue -Path $b7DenyLeaf)
            [void]$b7DenyLines.Add("'$b7DenyLeaf' = $b7DenyLiteral")
        }
        [void]$b7DenyLines.Add("'archiveRetentionDays' = 999")
        $b7DenyRoot = New-BRAVOB7ConfigRoot -Name 'DENY_LEAVES' -OverrideLine $b7DenyLines.ToArray()
        $b7Deny = Invoke-BRAVOSelfTestEffectiveSnapshotCapture -WorkRoot $b7Root -ConfigRoot $b7DenyRoot `
            -Label 'DENY_LEAVES' -InvocationText $b7CanonicalInvocation -ProbeVariableName @('archiveRetentionDays')
        $b7DenyUnnamed = @($b7DenyLeaves | Where-Object {
                -not ($b7Deny.ErrorMessage -match ('(^|[\s\u2014.])' + [regex]::Escape($_) + ': '))
            })
        Test-BRAVOCondition `
            -Condition (
                $b7DenyLeaves.Count -gt 0 -and
                @($b7DenyLeaves | Where-Object { $b7AuthorizationClass[$_].Class -eq 'DENY_SECURITY_CONTROL' }).Count -gt 0 -and
                -not $b7Deny.Succeeded -and
                $b7DenyUnnamed.Count -eq 0 -and
                [string]$b7Deny.ProbeValues['archiveRetentionDays'] -ne '999'
            ) `
            -Name 'ConfigLoader/B7LocalConfigDenyClassLeavesRejectedEvenAtDefault' `
            -Failure "кожен із $($b7DenyLeaves.Count) DENY_*-листів реєстру авторизації, заданий через BRAVO.local.config навіть власним дефолтним значенням, мусить відхилятись fail closed і бути названим у діагностиці, без часткового застосування сусіднього archiveRetentionDays; Succeeded=$($b7Deny.Succeeded), не названо: $($b7DenyUnnamed -join ', '), archiveRetentionDays після відмови='$($b7Deny.ProbeValues['archiveRetentionDays'])', повідомлення: $($b7Deny.ErrorMessage)"

        # Похідні ключі, яких немає в канонічній схемі (їх обчислює
        # Resolve-BRAVOConfigurationDerivation від RuntimeRoot/%ProgramData%):
        # цілісність інструментів (T001/PR #272 — ManifestPath сьогодні
        # конфігурацією не перевизначається), шляхи виконуваних файлів,
        # стан і lock. Очікувана канонічна поведінка — unknown key, fail closed.
        $b7DerivedKeys = @(
            'toolIntegritySettings.ManifestPath',
            'toolIntegritySettings.Mode',
            'toolsPath',
            'arcPath',
            'winSCPPath',
            'winSCPAssemblyPath',
            'stateRoot',
            'operationLockSettings.Path',
            'runtimeLogRoot'
        )
        $b7DerivedLines = New-Object System.Collections.Generic.List[string]
        $b7DerivedValue = (Join-Path $b7Root 'B7_REDIRECTED').Replace("'", "''")
        foreach ($b7DerivedKey in $b7DerivedKeys) {
            $b7DerivedLiteral = if ($b7DerivedKey -eq 'toolIntegritySettings.Mode') { "'Warn'" } else { "'$b7DerivedValue'" }
            [void]$b7DerivedLines.Add("'$b7DerivedKey' = $b7DerivedLiteral")
        }
        [void]$b7DerivedLines.Add("'archiveRetentionDays' = 999")
        $b7DerivedRoot = New-BRAVOB7ConfigRoot -Name 'DERIVED_KEYS' -OverrideLine $b7DerivedLines.ToArray()
        $b7Derived = Invoke-BRAVOSelfTestEffectiveSnapshotCapture -WorkRoot $b7Root -ConfigRoot $b7DerivedRoot `
            -Label 'DERIVED_KEYS' -InvocationText $b7CanonicalInvocation -ProbeVariableName @('archiveRetentionDays')
        $b7DerivedUnnamed = @($b7DerivedKeys | Where-Object { -not $b7Derived.ErrorMessage.Contains($_) })
        Test-BRAVOCondition `
            -Condition (
                -not $b7Derived.Succeeded -and
                $b7Derived.ErrorMessage.Contains('Невідомий(і) ключ(і) конфігурації') -and
                $b7DerivedUnnamed.Count -eq 0 -and
                [string]$b7Derived.ProbeValues['archiveRetentionDays'] -ne '999'
            ) `
            -Name 'ConfigLoader/B7LocalConfigDerivedSecurityKeysRejected' `
            -Failure "похідні security-/execution-ключі (toolIntegritySettings.ManifestPath/Mode, toolsPath, шляхи виконуваних файлів, stateRoot, operationLockSettings.Path, runtimeLogRoot) через BRAVO.local.config мусять відхилятись як не-raw-configurable, без часткового застосування; Succeeded=$($b7Derived.Succeeded), не названо: $($b7DerivedUnnamed -join ', '), archiveRetentionDays після відмови='$($b7Derived.ProbeValues['archiveRetentionDays'])', повідомлення: $($b7Derived.ErrorMessage)"

        # Вузлова форма того самого (перезапис цілого похідного вузла).
        $b7NodeRoot = New-BRAVOB7ConfigRoot -Name 'DERIVED_NODE' -OverrideLine @("'toolIntegritySettings' = @{ 'Mode' = 'Warn' }")
        $b7Node = Invoke-BRAVOSelfTestEffectiveSnapshotCapture -WorkRoot $b7Root -ConfigRoot $b7NodeRoot `
            -Label 'DERIVED_NODE' -InvocationText $b7CanonicalInvocation
        Test-BRAVOCondition `
            -Condition (-not $b7Node.Succeeded -and $b7Node.ErrorMessage.Contains('toolIntegritySettings')) `
            -Name 'ConfigLoader/B7LocalConfigToolIntegrityNodeRejected' `
            -Failure "вузол toolIntegritySettings цілком через BRAVO.local.config мусить відхилятись fail closed; Succeeded=$($b7Node.Succeeded), повідомлення: $($b7Node.ErrorMessage)"

        # ==========================================================
        # (e) Зіпсований / невідомий local-config — діагностика.
        # ==========================================================
        $b7MalformedCases = [ordered]@{
            'Syntax'       = @{ Body = "@{`r`n    'archiveRetentionDays' = 999`r`n"; Phrase = 'мусить бути data-only hashtable' }
            'NonHashtable' = @{ Body = "@('archiveRetentionDays', 999)`r`n"; Phrase = 'мусить бути data-only hashtable' }
            'EmptyKey'     = @{ Body = "@{`r`n    'archiveRetentionDays' = 999`r`n    '' = 'orphaned-value'`r`n}`r`n"; Phrase = 'порожній ключ неприпустимий' }
        }
        foreach ($b7MalformedName in @($b7MalformedCases.Keys)) {
            $b7MalformedRoot = New-BRAVOB7ConfigRoot -Name "MALFORMED_$b7MalformedName" -NoLocalConfig
            $b7MalformedPath = Join-Path $b7MalformedRoot 'BRAVO.local.config'
            [IO.File]::WriteAllText($b7MalformedPath, [string]$b7MalformedCases[$b7MalformedName].Body, $b7Utf8)
            $b7Malformed = Invoke-BRAVOSelfTestEffectiveSnapshotCapture -WorkRoot $b7Root -ConfigRoot $b7MalformedRoot `
                -Label "MALFORMED_$b7MalformedName" -InvocationText $b7CanonicalInvocation -ProbeVariableName @('archiveRetentionDays')
            Test-BRAVOCondition `
                -Condition (
                    -not $b7Malformed.Succeeded -and
                    $b7Malformed.ErrorMessage.Contains([string]$b7MalformedCases[$b7MalformedName].Phrase) -and
                    $b7Malformed.ErrorMessage.Contains($b7MalformedPath) -and
                    [string]$b7Malformed.ProbeValues['archiveRetentionDays'] -ne '999'
                ) `
                -Name "ConfigLoader/B7MalformedLocalConfig${b7MalformedName}NamesFileOn53Path" `
                -Failure "зіпсований BRAVO.local.config ($b7MalformedName) на 5.3-шляху мусить fail closed з діагностикою, що називає ПОВНИЙ шлях файлу ('$b7MalformedPath') і причину, без часткового застосування; Succeeded=$($b7Malformed.Succeeded), archiveRetentionDays='$($b7Malformed.ProbeValues['archiveRetentionDays'])', повідомлення: $($b7Malformed.ErrorMessage)"
        }

        # Невідомий ключ: діагностика мусить назвати сам ключ і ConfigRoot
        # (повідомлення схеми не містить імені файлу — див. звіт B7; тут
        # закріплено наявний мінімум, без зміни runtime-тексту).
        $b7UnknownRoot = New-BRAVOB7ConfigRoot -Name 'UNKNOWN_KEY' -OverrideLine @("'archiveRetentionDays' = 999", "'b7NoSuchSetting' = 1")
        $b7Unknown = Invoke-BRAVOSelfTestEffectiveSnapshotCapture -WorkRoot $b7Root -ConfigRoot $b7UnknownRoot `
            -Label 'UNKNOWN_KEY' -InvocationText $b7CanonicalInvocation -ProbeVariableName @('archiveRetentionDays')
        Test-BRAVOCondition `
            -Condition (
                -not $b7Unknown.Succeeded -and
                $b7Unknown.ErrorMessage.Contains('b7NoSuchSetting') -and
                $b7Unknown.ErrorMessage.Contains($b7UnknownRoot) -and
                [string]$b7Unknown.ProbeValues['archiveRetentionDays'] -ne '999'
            ) `
            -Name 'ConfigLoader/B7UnknownLocalKeyNamesKeyAndConfigRootOn53Path' `
            -Failure "невідомий ключ у BRAVO.local.config на 5.3-шляху мусить fail closed з діагностикою, що називає ключ і ConfigRoot ('$b7UnknownRoot'), без часткового застосування; Succeeded=$($b7Unknown.Succeeded), повідомлення: $($b7Unknown.ErrorMessage)"

        # ==========================================================
        # (f)(g) Міграція 5.2 -> 5.3 реальним інструментом.
        # ==========================================================
        # Репрезентативний 5.2-сервер: заморожений legacy-текст + типові
        # site-перевизначення (той самий клас, що на пілотному сервері).
        $b7MigrationRoot = New-BRAVOB7ConfigRoot -Name 'MIGRATION' -NoLocalConfig
        $b7MigrationBackupDir = Join-Path $b7MigrationRoot 'SITE_BACKUP'
        $b7MigrationLunchDir = Join-Path $b7MigrationRoot 'LUNCH'
        [void][IO.Directory]::CreateDirectory($b7MigrationLunchDir)
        $b7MigrationLegacyText = $b7LegacyText.Replace(
            $b7BackupRootLiteralLine,
            "    BackupRoot    = '$($b7MigrationBackupDir.Replace("'", "''"))'"
        ) + "`r`n" +
            "`$global:hostInformationSettings['PublicIPLookupEnabled'] = `$false`r`n" +
            "`$global:lunchArchiveCleanupPath = '$($b7MigrationLunchDir.Replace("'", "''"))'`r`n" +
            "`$global:maintenanceSettings['Limits']['ExcludedDrives'] = @('X:\', 'Y:\')`r`n" +
            "`$global:maintenanceSettings['Restore']['Time'] = '22:30'`r`n" +
            "`$global:smbSettings['RootPath'] = '\\server\bravo-b7'`r`n" +
            "`$global:archiveRetentionDays = 365`r`n" +
            "`$global:lunchArchiveCleanupDirectories = @('MODEL')`r`n"
        $b7MigrationLegacyPath = Join-Path $b7MigrationRoot 'BRAVO.config'
        [IO.File]::WriteAllText($b7MigrationLegacyPath, $b7MigrationLegacyText, $b7Utf8)

        # BEFORE: так, як сервер 5.2 бачить себе сьогодні (legacy-primary,
        # auto-detect — санкціонований шлях migration-інструментів).
        $b7Before = Invoke-BRAVOSelfTestEffectiveSnapshotCapture -WorkRoot $b7Root -ConfigRoot $b7MigrationRoot `
            -Label 'MIGRATION_BEFORE' -InvocationText 'Import-BravoConfiguration -ConfigRoot $ConfigRoot -RuntimeRoot $RuntimeRoot'
        if (-not $b7Before.Succeeded) {
            throw "B7(f): знімок BEFORE не знято: $($b7Before.ErrorMessage) $($b7Before.StdErr)"
        }

        $b7DeltaToolPath = Join-Path $root 'deploy\Get-BRAVOConfigSiteDelta.ps1'
        $b7PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        function Invoke-BRAVOB7SiteDelta {
            param([Parameter(Mandatory = $true)][string]$OutputPath)
            # Локально (scope функції): у Windows PowerShell 5.1 рядок stderr
            # нативного процесу під 2>&1 і 'Stop' став би термінуючим
            # NativeCommandError — справжній gate тут ExitCode нижче.
            $ErrorActionPreference = 'Continue'
            $deltaOutput = [string](& $b7PowerShellExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                    -File $b7DeltaToolPath -RuntimeRoot $root -ConfigRoot $b7MigrationRoot -OutputPath $OutputPath 2>&1 | Out-String)
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $deltaOutput }
        }

        # (g1) Детермінованість: два прогони на тому самому 5.2-вході дають
        # той самий текст (окрім рядка з часом генерації в заголовку).
        $b7Delta1Path = Join-Path $b7Root 'delta1.local.config'
        $b7Delta2Path = Join-Path $b7Root 'delta2.local.config'
        $b7Delta1 = Invoke-BRAVOB7SiteDelta -OutputPath $b7Delta1Path
        $b7Delta2 = Invoke-BRAVOB7SiteDelta -OutputPath $b7Delta2Path
        $b7Delta1Lines = if (Test-Path -LiteralPath $b7Delta1Path -PathType Leaf) { @([IO.File]::ReadAllText($b7Delta1Path, [Text.Encoding]::UTF8) -split "`r?`n") } else { @() }
        $b7Delta2Lines = if (Test-Path -LiteralPath $b7Delta2Path -PathType Leaf) { @([IO.File]::ReadAllText($b7Delta2Path, [Text.Encoding]::UTF8) -split "`r?`n") } else { @() }
        Test-BRAVOCondition `
            -Condition (
                $b7Delta1.ExitCode -eq 0 -and $b7Delta2.ExitCode -eq 0 -and
                $b7Delta1Lines.Count -gt 2 -and
                (@($b7Delta1Lines | Select-Object -Skip 1) -join "`n") -eq (@($b7Delta2Lines | Select-Object -Skip 1) -join "`n")
            ) `
            -Name 'ConfigLoader/B7MigrationDeltaIsDeterministic' `
            -Failure "deploy\Get-BRAVOConfigSiteDelta.ps1 на тому самому 5.2-вході мусить давати ідентичний BRAVO.local.config (окрім часу генерації); ExitCode=$($b7Delta1.ExitCode)/$($b7Delta2.ExitCode); вивід: $($b7Delta1.Output) | $($b7Delta2.Output)"

        # Міграція: згенерований текст стає BRAVO.local.config, BRAVO.config
        # ретирується (прибирається з ConfigRoot).
        $b7RetiredLegacyPath = Join-Path $b7Root 'BRAVO.config.retired'
        if (Test-Path -LiteralPath $b7Delta1Path -PathType Leaf) {
            Copy-Item -LiteralPath $b7Delta1Path -Destination (Join-Path $b7MigrationRoot 'BRAVO.local.config')
        }
        Move-Item -LiteralPath $b7MigrationLegacyPath -Destination $b7RetiredLegacyPath

        # AFTER: чистий 5.3-шлях.
        $b7After = Invoke-BRAVOSelfTestEffectiveSnapshotCapture -WorkRoot $b7Root -ConfigRoot $b7MigrationRoot `
            -Label 'MIGRATION_AFTER' -InvocationText $b7CanonicalInvocation
        # Точковий allowlist — лише поля, що описують СПОСІБ композиції
        # (legacy-primary -> built-in + local) і час прогону; жодного
        # ефективного значення конфігурації. Той самий принцип, що
        # $knownAbsentIntentionalDiffPrefixes у
        # ci\Test-BRAVOConfigFoundationParity.ps1, але для іншого
        # порівняння (legacy-сервер до/після міграції).
        $b7MigrationProvenancePaths = @(
            'BravoConfigurationMetadata.LoadedAt',
            'BravoConfigurationMetadata.Format',
            'BravoConfigurationMetadata.Mode',
            'BravoConfigurationMetadata.PrimaryConfigPresent',
            'BravoConfigurationMetadata.PrimaryConfigPresentOnDisk',
            'BravoConfigurationMetadata.PrimaryConfigOverridesCanonicalDefaults',
            'BravoConfigurationMetadata.LocalConfigPresent',
            'BravoConfigurationMetadata.LocalConfigPath',
            'BravoConfigurationMetadata.LocalConfigOverrides',
            'BravoConfigurationMetadata.AppliedLocalOverrideKeys',
            'BravoConfigurationMetadata.LocalConfigEffectiveSchemaVersion'
        )
        $b7MigrationUnexpected = @()
        if ($b7After.Succeeded) {
            $b7MigrationUnexpected = @(Get-BRAVOB7UnexpectedDifference -Reference $b7Before.RawSnapshot -Candidate $b7After.RawSnapshot -AllowedPath $b7MigrationProvenancePaths)
        }
        # Не тавтологія: site-значення справді відрізняються від дефолтів
        # і справді присутні в обох знімках.
        $b7MigrationNonVacuous = $b7After.Succeeded -and
            [int]$b7Before.RawSnapshot['archiveRetentionDays'] -eq 365 -and
            [int]$b7After.RawSnapshot['archiveRetentionDays'] -eq 365 -and
            [string]$b7After.RawSnapshot['maintenanceSettings']['Restore']['Time'] -eq '22:30' -and
            [string]$b7After.RawSnapshot['smbSettings']['RootPath'] -eq '\\server\bravo-b7' -and
            $b7After.RawSnapshot['hostInformationSettings']['PublicIPLookupEnabled'] -eq $false -and
            (@($b7After.RawSnapshot['maintenanceSettings']['Limits']['ExcludedDrives']) -join '|') -eq 'X:\|Y:\' -and
            $b7After.RawSnapshot['lunchArchiveCleanupDirectories'] -isnot [string] -and
            (@($b7After.RawSnapshot['lunchArchiveCleanupDirectories']) -join '|') -eq 'MODEL'
        Test-BRAVOCondition `
            -Condition ($b7After.Succeeded -and $b7MigrationNonVacuous -and $b7MigrationUnexpected.Count -eq 0) `
            -Name 'ConfigLoader/B7MigrationParityFullEffectiveSnapshot' `
            -Failure (
                "5.2 BRAVO.config -> реальний Get-BRAVOConfigSiteDelta.ps1 -> BRAVO.local.config -> 5.3-шлях мусить дати ТОЙ САМИЙ повний " +
                "ефективний знімок, що й до міграції (відмінності лише в provenance-полях); Succeeded=$($b7After.Succeeded) $($b7After.ErrorMessage), " +
                "NonVacuous=$b7MigrationNonVacuous, неочікуваних відмінностей $($b7MigrationUnexpected.Count): " +
                (($b7MigrationUnexpected | ForEach-Object { "$($_.Path) [$($_.Kind)]" }) -join '; ')
            )

        $b7PrimaryOverrideSet = @(@($b7Before.RawSnapshot['BravoConfigurationMetadata']['PrimaryConfigOverridesCanonicalDefaults']) | Sort-Object)
        $b7AppliedLocalSet = if ($b7After.Succeeded) { @(@($b7After.RawSnapshot['BravoConfigurationMetadata']['AppliedLocalOverrideKeys']) | Sort-Object) } else { @() }
        Test-BRAVOCondition `
            -Condition ($b7PrimaryOverrideSet.Count -gt 0 -and ($b7PrimaryOverrideSet -join '|') -eq ($b7AppliedLocalSet -join '|')) `
            -Name 'ConfigLoader/B7MigrationCarriesEveryPrimaryOverride' `
            -Failure "кожен шлях, який 5.2 BRAVO.config перевизначав відносно канонічних дефолтів, мусить стати застосованим override-ом BRAVO.local.config (і жодного зайвого); до='$($b7PrimaryOverrideSet -join ', ')' після='$($b7AppliedLocalSet -join ', ')'"

        # (g2) Повторна міграція вже мігрованого сервера: legacy-файл знову
        # поруч (Update-BRAVOServer.ps1 його не видаляє), BRAVO.local.config
        # уже згенеровано. Інструмент не пропонує жодного нового
        # перенесення, а ефективна конфігурація 5.3-entrypoint-а не змінюється.
        Copy-Item -LiteralPath $b7RetiredLegacyPath -Destination $b7MigrationLegacyPath
        $b7Delta3Path = Join-Path $b7Root 'delta3.local.config'
        $b7Delta3 = Invoke-BRAVOB7SiteDelta -OutputPath $b7Delta3Path
        $b7Delta3Text = if (Test-Path -LiteralPath $b7Delta3Path -PathType Leaf) { [IO.File]::ReadAllText($b7Delta3Path, [Text.Encoding]::UTF8) } else { '' }
        $b7Delta3Active = @(@($b7Delta3Text -split "`r?`n") | Where-Object { $_ -match "^\s+'[^']+'\s*=" })
        $b7Delta3AlreadyPresent = @(@($b7Delta3Text -split "`r?`n") | Where-Object { $_.Contains('[уже є в BRAVO.local.config]') })
        Test-BRAVOCondition `
            -Condition (
                $b7Delta3.ExitCode -eq 0 -and
                $b7Delta3Active.Count -eq 0 -and
                $b7Delta3AlreadyPresent.Count -eq $b7PrimaryOverrideSet.Count -and
                $b7Delta3.Output.Contains('Відмінностей до перенесення: 0')
            ) `
            -Name 'ConfigLoader/B7MigrationRerunOnMigratedServerIsNoOp' `
            -Failure "повторний прогін міграції на вже мігрованому сервері не повинен пропонувати жодного нового override-а (усі $($b7PrimaryOverrideSet.Count) — '[уже є в BRAVO.local.config]'); активних рядків $($b7Delta3Active.Count), позначених $($b7Delta3AlreadyPresent.Count), ExitCode=$($b7Delta3.ExitCode), вивід: $($b7Delta3.Output)"

        $b7Rerun = Invoke-BRAVOSelfTestEffectiveSnapshotCapture -WorkRoot $b7Root -ConfigRoot $b7MigrationRoot `
            -Label 'MIGRATION_RERUN' -InvocationText $b7CanonicalInvocation
        $b7RerunUnexpected = @()
        if ($b7Rerun.Succeeded -and $b7After.Succeeded) {
            $b7RerunUnexpected = @(Get-BRAVOB7UnexpectedDifference -Reference $b7After.RawSnapshot -Candidate $b7Rerun.RawSnapshot -AllowedPath $b7ProofBProvenancePaths)
        }
        Test-BRAVOCondition `
            -Condition ($b7Rerun.Succeeded -and $b7After.Succeeded -and $b7RerunUnexpected.Count -eq 0) `
            -Name 'ConfigLoader/B7MigratedServerRetainedLegacyConfigHasNoEffect' `
            -Failure "мігрований сервер із залишеним поруч 5.2 BRAVO.config мусить мати той самий ефективний знімок на 5.3-шляху (відмінності лише LoadedAt/PrimaryConfigPresentOnDisk/PrimaryConfigAutoDetectBlocked); Succeeded=$($b7Rerun.Succeeded) $($b7Rerun.ErrorMessage), неочікуваних $($b7RerunUnexpected.Count): $(($b7RerunUnexpected | ForEach-Object { "$($_.Path) [$($_.Kind)]" }) -join '; ')"
    } finally {
        if ($null -ne $b7PreviousWeakenedSecurity) {
            $env:BRAVO_ALLOW_WEAKENED_SECURITY = $b7PreviousWeakenedSecurity
        }
        Remove-Item -LiteralPath $b7Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
} catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'ConfigLoader/ConfigV2RegressionMatrix' } }
# Раннер проб зупиняється в ConfigLoader/Authorization; тут — на випадок,
# коли ту секцію пропущено або вона впала раніше.
Stop-BRAVOConfigLoaderProbeWorker
