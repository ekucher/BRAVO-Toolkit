# Домен-фрагмент self-test: RestoreVerify (P1.1 — планова перевірка
# відновлюваності): state-API BRAVO.RestoreVerify (атомарний запис,
# політика LastVerifiedAt, fail-closed на пошкодженому state),
# health-оцінка віку верифікації, канонічний DaysOfWeek-mask (BRAVO.System),
# статичні контракти BRAVO_RESTORE_TEST/TASKS_INSTALL/TASKS_UNINSTALL і
# loader-нормалізація legacy-конфігів без RestoreVerify-вузлів.
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 -- НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition, $script:failures,
# New-BRAVOSelfTestSchedulerFixtureConfig (fixture legacy-конфігів).

    Import-Module -Name (Join-Path $root 'modules\BRAVO.RestoreVerify\BRAVO.RestoreVerify.psd1') -Force
    Import-Module -Name (Join-Path $root 'modules\BRAVO.System\BRAVO.System.psd1')

    # --- State-API: атомарний roundtrip і політика LastVerifiedAt ---
    $restoreVerifyTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_RESTORE_VERIFY_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void](New-Item -ItemType Directory -Path $restoreVerifyTestRoot -Force)
        $restoreVerifyStatePath = Get-BRAVORestoreVerifyStatePath -StateRoot $restoreVerifyTestRoot

        Save-BRAVORestoreVerifyState -Path $restoreVerifyStatePath `
            -RunAt (Get-Date).AddHours(-2) -Status PASS -ExitCode 0 `
            -GenerationId 'GEN_SELFTEST_1' -VerificationSucceeded $true
        $restoreVerifyPassState = Get-BRAVORestoreVerifyState -Path $restoreVerifyStatePath
        $restoreVerifyStateBytes = [IO.File]::ReadAllBytes($restoreVerifyStatePath)
        Test-BRAVOCondition `
            -Condition (
                [bool]$restoreVerifyPassState.Exists -and
                -not [bool]$restoreVerifyPassState.Corrupt -and
                [string]$restoreVerifyPassState.State.LastStatus -eq 'PASS' -and
                [string]$restoreVerifyPassState.State.GenerationId -eq 'GEN_SELFTEST_1' -and
                -not [string]::IsNullOrWhiteSpace([string]$restoreVerifyPassState.State.LastVerifiedAt) -and
                -not ($restoreVerifyStateBytes.Length -ge 3 -and $restoreVerifyStateBytes[0] -eq 0xEF) -and
                @(Get-ChildItem -LiteralPath $restoreVerifyTestRoot -Force -File |
                    Where-Object { $_.Name -like '.BRAVO_RESTORE_VERIFY_STATE_*' }).Count -eq 0
            ) `
            -Name 'RestoreVerify/StateAtomicWriteRoundTrip' `
            -Failure 'Save/Get-BRAVORestoreVerifyState: чистий PASS має записати LastVerifiedAt (UTF-8 без BOM, без .tmp/.bak-залишків) і прочитатися назад без Corrupt'

        # WARN означає «частину компонентів не перевірено» — вік останньої
        # ДОВЕДЕНОЇ верифікації не скидається слабшим результатом.
        $restoreVerifyPreviousVerifiedAt = [string]$restoreVerifyPassState.State.LastVerifiedAt
        Save-BRAVORestoreVerifyState -Path $restoreVerifyStatePath `
            -RunAt (Get-Date) -Status WARN -ExitCode 10 `
            -GenerationId 'GEN_SELFTEST_2' -VerificationSucceeded $false
        $restoreVerifyWarnState = Get-BRAVORestoreVerifyState -Path $restoreVerifyStatePath
        Test-BRAVOCondition `
            -Condition (
                [string]$restoreVerifyWarnState.State.LastStatus -eq 'WARN' -and
                [string]$restoreVerifyWarnState.State.LastVerifiedAt -eq $restoreVerifyPreviousVerifiedAt
            ) `
            -Name 'RestoreVerify/WarnRunPreservesLastVerifiedAt' `
            -Failure 'WARN-прогін не повинен оновлювати LastVerifiedAt — вік останньої доведеної верифікації зберігається з попереднього чистого PASS'

        $restoreVerifyFreshEvaluation = Get-BRAVORestoreVerifyHealthIssue `
            -StateResult $restoreVerifyWarnState -MaxVerificationAgeHours 216
        Save-BRAVORestoreVerifyState -Path $restoreVerifyStatePath `
            -RunAt (Get-Date) -Status FAIL -ExitCode 41 `
            -GenerationId 'GEN_SELFTEST_3' -VerificationSucceeded $false
        $restoreVerifyFailEvaluation = Get-BRAVORestoreVerifyHealthIssue `
            -StateResult (Get-BRAVORestoreVerifyState -Path $restoreVerifyStatePath) `
            -MaxVerificationAgeHours 216
        Save-BRAVORestoreVerifyState -Path $restoreVerifyStatePath `
            -RunAt (Get-Date).AddDays(-30) -Status PASS -ExitCode 0 `
            -GenerationId 'GEN_SELFTEST_4' -VerificationSucceeded $true
        $restoreVerifyStaleEvaluation = Get-BRAVORestoreVerifyHealthIssue `
            -StateResult (Get-BRAVORestoreVerifyState -Path $restoreVerifyStatePath) `
            -MaxVerificationAgeHours 216
        $restoreVerifyMissingEvaluation = Get-BRAVORestoreVerifyHealthIssue `
            -StateResult (Get-BRAVORestoreVerifyState -Path (Join-Path $restoreVerifyTestRoot 'absent.json')) `
            -MaxVerificationAgeHours 216
        [IO.File]::WriteAllText($restoreVerifyStatePath, 'garbage{{{', (New-Object Text.UTF8Encoding($false)))
        $restoreVerifyCorruptState = Get-BRAVORestoreVerifyState -Path $restoreVerifyStatePath
        $restoreVerifyCorruptEvaluation = Get-BRAVORestoreVerifyHealthIssue `
            -StateResult $restoreVerifyCorruptState -MaxVerificationAgeHours 216
        Test-BRAVOCondition `
            -Condition (
                $null -eq $restoreVerifyFreshEvaluation.Issue -and
                -not [string]::IsNullOrWhiteSpace([string]$restoreVerifyFreshEvaluation.Detail) -and
                -not [string]::IsNullOrWhiteSpace([string]$restoreVerifyFailEvaluation.Issue) -and
                -not [string]::IsNullOrWhiteSpace([string]$restoreVerifyStaleEvaluation.Issue) -and
                $null -eq $restoreVerifyMissingEvaluation.Issue -and
                -not [string]::IsNullOrWhiteSpace([string]$restoreVerifyMissingEvaluation.Warning) -and
                [bool]$restoreVerifyCorruptState.Corrupt -and
                -not [string]::IsNullOrWhiteSpace([string]$restoreVerifyCorruptEvaluation.Issue)
            ) `
            -Name 'RestoreVerify/HealthIssueAgeLogic' `
            -Failure "Get-BRAVORestoreVerifyHealthIssue: свіжий (WARN зі свіжим LastVerifiedAt) -> без issue; FAIL/прострочений/пошкоджений -> issue (fail-closed); відсутній state -> лише Warning (сервер чекає першого прогону). Fresh=$($restoreVerifyFreshEvaluation.Issue); Fail=$($restoreVerifyFailEvaluation.Issue); Stale=$($restoreVerifyStaleEvaluation.Issue); Missing=$($restoreVerifyMissingEvaluation.Issue)/$($restoreVerifyMissingEvaluation.Warning); Corrupt=$($restoreVerifyCorruptEvaluation.Issue)"
    } finally {
        Remove-Item -LiteralPath $restoreVerifyTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- Канонічний DaysOfWeek-mask (спільний Installer/Diagnose) ---
    $restoreVerifyDayMaskExpectations = @(
        @{ Day = 'Sunday'; Mask = 1 }, @{ Day = 'Monday'; Mask = 2 },
        @{ Day = 'Tuesday'; Mask = 4 }, @{ Day = 'Wednesday'; Mask = 8 },
        @{ Day = 'Thursday'; Mask = 16 }, @{ Day = 'Friday'; Mask = 32 },
        @{ Day = 'Saturday'; Mask = 64 }
    )
    $restoreVerifyDayMaskMismatches = @(
        $restoreVerifyDayMaskExpectations | Where-Object {
            (ConvertTo-BRAVODaysOfWeekMask -DayOfWeek $_.Day) -ne [int]$_.Mask
        }
    )
    $restoreVerifyInvalidDayThrew = $false
    try {
        [void](ConvertTo-BRAVODaysOfWeekMask -DayOfWeek 'Субота')
    } catch {
        $restoreVerifyInvalidDayThrew = $true
    }
    Test-BRAVOCondition `
        -Condition ($restoreVerifyDayMaskMismatches.Count -eq 0 -and $restoreVerifyInvalidDayThrew) `
        -Name 'Scheduler/DaysOfWeekMaskCanonical' `
        -Failure "ConvertTo-BRAVODaysOfWeekMask: Sunday=1..Saturday=64 (Task Scheduler bitmask), невідома назва дня -> throw (fail-closed); розбіжності: $(@($restoreVerifyDayMaskMismatches | ForEach-Object { $_.Day }) -join ', ')"

    # --- Статичні контракти drill/scheduler-файлів ---
    $restoreTestTextForVerify = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_RESTORE_TEST.ps1'), [Text.Encoding]::UTF8)
    Test-BRAVOCondition `
        -Condition (
            $restoreTestTextForVerify.Contains('[switch]$NoPause') -and
            $restoreTestTextForVerify.Contains('[switch]$NotifyOnSuccess') -and
            $restoreTestTextForVerify.Contains("BRAVO_RUNTIME_GUARD.ps1") -and
            $restoreTestTextForVerify.Contains('Test-BRAVORuntimeManifestIntegrity') -and
            $restoreTestTextForVerify.Contains('Save-BRAVORestoreVerifyState') -and
            $restoreTestTextForVerify.Contains('-VerificationSucceeded ($drillFailCount -eq 0 -and $drillWarnCount -eq 0)')
        ) `
        -Name 'RestoreTest/ScheduledModeContract' `
        -Failure 'BRAVO_RESTORE_TEST.ps1 має приймати -NoPause/-NotifyOnSuccess, проходити runtime guard і писати стан верифікації, де LastVerifiedAt оновлюється лише повністю чистим прогоном (0 FAIL і 0 WARN)'

    Test-BRAVOCondition `
        -Condition ($restoreTestTextForVerify.Contains('AddDays(-7)') -and
            [regex]::IsMatch($restoreTestTextForVerify, 'Select-Object\s+-First\s+10')) `
        -Name 'RestoreTest/OrphanDrillDirectoryCleanupIsBounded' `
        -Failure 'BRAVO_RESTORE_TEST.ps1 має прибирати покинуті drill-каталоги старші 7 діб, обмежено (не більше 10 за прогін)'

    $taskInstallerTextForVerify = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_TASKS_INSTALL.ps1'), [Text.Encoding]::UTF8)
    $taskUninstallerTextForVerify = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_TASKS_UNINSTALL.ps1'), [Text.Encoding]::UTF8)
    Test-BRAVOCondition `
        -Condition (
            $taskInstallerTextForVerify.Contains('"BAZASync", "RestoreVerify")') -and
            $taskInstallerTextForVerify.Contains('$definition.Triggers.Create(3) # TASK_TRIGGER_WEEKLY') -and
            $taskInstallerTextForVerify.Contains('ConvertTo-BRAVODaysOfWeekMask -DayOfWeek ([string]$TaskSettings.WeeklyOn)') -and
            $taskInstallerTextForVerify.Contains('Type = "RestoreVerify"; Settings = $schedulerSettings.RestoreVerify') -and
            $taskUninstallerTextForVerify.Contains('$schedulerSettings.RestoreVerify.TaskName')
        ) `
        -Name 'Scheduler/RestoreVerifyTaskTypeRegistered' `
        -Failure 'RestoreVerify має бути повноцінним типом завдання: ValidateSet + weekly-тригер через канонічний DaysOfWeek-mask у TASKS_INSTALL, елемент taskPlans і видалення у TASKS_UNINSTALL'

    # --- Loader: legacy-конфіг без RestoreVerify-вузлів отримує дефолти ---
    # Та сама фікстурна механіка, що ConfigurationLoader/MissingBootRestoreModeDefaultsToNone:
    # реальний site-config старого покоління просто не має нових вузлів.
    $legacyRestoreVerifyFixture = New-BRAVOSelfTestSchedulerFixtureConfig `
        -BreakLimsRootViaFakeService $false -MaintenanceEnabled $true -RecoveryEnabled $false
    $legacyRestoreVerifyConfigText = [IO.File]::ReadAllText($legacyRestoreVerifyFixture.ConfigPath, [Text.Encoding]::UTF8)
    $legacyRestoreVerifyConfigText = [regex]::Replace(
        $legacyRestoreVerifyConfigText, '(?s)    RestoreVerify = @\{.*?\r?\n    \}\r?\n', '', 1)
    $legacyRestoreVerifyConfigText = [regex]::Replace(
        $legacyRestoreVerifyConfigText, '(?s)\$global:restoreVerifySettings = @\{.*?\r?\n\}\r?\n', '', 1)
    [IO.File]::WriteAllText($legacyRestoreVerifyFixture.ConfigPath, $legacyRestoreVerifyConfigText, (New-Object Text.UTF8Encoding($false)))
    $legacyRestoreVerifyProbeOutput = & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (
            "Set-StrictMode -Version 2.0; " +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "[void](Import-BravoConfiguration -ConfigRoot '$($legacyRestoreVerifyFixture.Root)' -RuntimeRoot '$root'); " +
            "'{0}|{1}|{2}|{3}' -f [string]`$global:schedulerSettings.RestoreVerify.WeeklyOn, " +
            "[string]`$global:schedulerSettings.RestoreVerify.At, " +
            "[string]`$global:restoreVerifySettings.MaxVerificationAgeHours, " +
            "[IO.Path]::GetFileName([string]`$global:schedulerSettings.RestoreVerify.ScriptPath)"
        ) 2>&1
    $legacyRestoreVerifyProbeLast = ([string](@($legacyRestoreVerifyProbeOutput)[-1])).Trim()
    Test-BRAVOCondition `
        -Condition (
            -not $legacyRestoreVerifyConfigText.Contains('RestoreVerify = @{') -and
            $legacyRestoreVerifyProbeLast -eq 'Saturday|04:00|216|BRAVO_RESTORE_TEST.ps1' -and
            (($legacyRestoreVerifyProbeOutput | Out-String) -notmatch 'cannot be found')
        ) `
        -Name 'ConfigurationLoader/LegacyConfigSynthesizesRestoreVerifyDefaults' `
        -Failure "loader має синтезувати RestoreVerify-вузли для legacy-конфігів (Saturday/04:00/216/BRAVO_RESTORE_TEST.ps1 зі StrictMode без падінь); отримано: '$legacyRestoreVerifyProbeLast'"
