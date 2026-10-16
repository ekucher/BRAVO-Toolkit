# ============================================================
# #364: BRAVO.LogSync — синхронізація дозволених runtime-журналів на SFTP.
# ============================================================
# Реальний, вже імпортований production-модуль (чисті функції + явно
# ін'єктовані I/O-scriptblock-и для транспорту) — жодних stub/fixture не
# потрібно для самого модуля.

Import-Module -Name (Join-Path $root 'modules\BRAVO.LogSync\BRAVO.LogSync.psd1') -Force -ErrorAction Stop

# --- LogSync/AllowlistExactSet ---
# Явний, нерекурсивний allowlist (owner-approved рішення #1) — НІЧОГО,
# крім 4 шаблонів, не йде на SFTP: НЕ HELPERS, НЕ file_sizes_*.csv, НЕ
# маркери/lock-файли/self-test fixtures.
$logSyncAllowlistCases = @(
    @{ N = 'BRAVO_MAINTENANCE_20261016_013000_PID1.log'; Expect = $true },
    @{ N = 'BRAVO_ARCHIV_20261016_013000_PID1.log'; Expect = $true },
    @{ N = 'BRAVO_DATA_RESTORE_20261016_013000.log'; Expect = $true },
    @{ N = 'script_log_setup.txt'; Expect = $true },
    @{ N = 'file_sizes_before_20261016.csv'; Expect = $false },
    @{ N = 'restore_done_20261016.marker'; Expect = $false },
    @{ N = 'BRAVO_OPERATION.lock'; Expect = $false },
    @{ N = 'range_id_log.json'; Expect = $false },
    @{ N = 'BRAVO_HELPERS_transcript.log'; Expect = $false }
)
$logSyncAllowlistMismatches = New-Object System.Collections.Generic.List[string]
foreach ($case in $logSyncAllowlistCases) {
    $actual = Test-BRAVOLogSyncAllowlistMatch -FileName $case.N
    if ($actual -ne $case.Expect) {
        $logSyncAllowlistMismatches.Add("$($case.N): actual=$actual expected=$($case.Expect)")
    }
}
Test-BRAVOCondition -Condition ($logSyncAllowlistMismatches.Count -eq 0) `
    -Name 'LogSync/AllowlistExactSet' `
    -Failure "#364: allowlist має пропускати ЛИШЕ BRAVO_MAINTENANCE_*.log/BRAVO_ARCHIV_*.log/BRAVO_DATA_RESTORE_*.log/script_log_*.txt, нерекурсивно, нічого іншого (HELPERS/CSV/markers/lock/json); розбіжності: $($logSyncAllowlistMismatches -join ' | ')"

$logSyncTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_LOGSYNC_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
try {
    $logSyncLogsDir = Join-Path $logSyncTestRoot 'logs'
    $logSyncStateRoot = Join-Path $logSyncTestRoot 'state'
    [void](New-Item -ItemType Directory -Path $logSyncLogsDir -Force)

    # --- LogSync/LedgerSameLengthOverwriteReuploads (RED->GREEN, closes
    # the closed-without-merge PR #332 defect: "пропуск за однаковим
    # розміром" мовчки ховав перезаписаний файл тієї самої довжини). ---
    $logSyncFile1 = Join-Path $logSyncLogsDir 'BRAVO_MAINTENANCE_run1.log'
    [IO.File]::WriteAllText($logSyncFile1, 'aaa', (New-Object Text.UTF8Encoding($false)))
    $logSyncUploadedPaths1 = New-Object System.Collections.Generic.List[string]
    $logSyncRun1 = Invoke-BRAVOLogSyncRun -LogsDirectory $logSyncLogsDir -StateRoot $logSyncStateRoot `
        -RemoteDirectory 'logs/runtime/SELFTEST-HOST' `
        -MaskFile { param($p) $p } -RemoveMaskedCopy { param($p) } `
        -UploadFile { param($local, $remoteDir, $remoteName) $logSyncUploadedPaths1.Add($remoteName); [pscustomobject]@{ Success = $true; Error = $null } }

    Start-Sleep -Milliseconds 30
    # Той самий розмір (3 байти), НОВИЙ вміст і mtime — стара (закрита без
    # merge) реалізація мовчки пропускала б це як "уже вивантажено".
    [IO.File]::WriteAllText($logSyncFile1, 'bbb', (New-Object Text.UTF8Encoding($false)))
    $logSyncUploadedPaths2 = New-Object System.Collections.Generic.List[string]
    $logSyncRun2 = Invoke-BRAVOLogSyncRun -LogsDirectory $logSyncLogsDir -StateRoot $logSyncStateRoot `
        -RemoteDirectory 'logs/runtime/SELFTEST-HOST' `
        -MaskFile { param($p) $p } -RemoveMaskedCopy { param($p) } `
        -UploadFile { param($local, $remoteDir, $remoteName) $logSyncUploadedPaths2.Add($remoteName); [pscustomobject]@{ Success = $true; Error = $null } }

    Test-BRAVOCondition -Condition (
        $logSyncRun1.Uploaded -eq 1 -and
        $logSyncRun2.Attempted -eq 1 -and $logSyncRun2.Uploaded -eq 1
    ) -Name 'LogSync/LedgerSameLengthOverwriteReuploads' `
        -Failure "#364: перезапис тієї самої довжини з НОВИМ mtime мусить re-upload-итись (закриває дефект пропуску за розміром закритого без merge PR #332); run1.Uploaded=$($logSyncRun1.Uploaded), run2.Attempted=$($logSyncRun2.Attempted), run2.Uploaded=$($logSyncRun2.Uploaded)"

    # --- LogSync/UnchangedFileIsTrustedSkip ---
    $logSyncUploadedPaths3 = New-Object System.Collections.Generic.List[string]
    $logSyncRun3 = Invoke-BRAVOLogSyncRun -LogsDirectory $logSyncLogsDir -StateRoot $logSyncStateRoot `
        -RemoteDirectory 'logs/runtime/SELFTEST-HOST' `
        -MaskFile { param($p) $p } -RemoveMaskedCopy { param($p) } `
        -UploadFile { param($local, $remoteDir, $remoteName) $logSyncUploadedPaths3.Add($remoteName); [pscustomobject]@{ Success = $true; Error = $null } }
    Test-BRAVOCondition -Condition ($logSyncRun3.Attempted -eq 0) `
        -Name 'LogSync/UnchangedFileIsTrustedSkip' `
        -Failure "#364: незмінений (ledger Size+LastWriteTimeUtc збігається) файл не повинен повторно вивантажуватись; факт Attempted=$($logSyncRun3.Attempted)"

    # --- LogSync/SingleFileFailureIsolated (ізоляція збою одного файлу) ---
    [IO.File]::WriteAllText((Join-Path $logSyncLogsDir 'BRAVO_ARCHIV_run1.log'), 'ccc', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $logSyncLogsDir 'script_log_setup.txt'), 'ddd', (New-Object Text.UTF8Encoding($false)))
    $logSyncRun4Attempts = New-Object System.Collections.Generic.List[string]
    $logSyncRun4 = Invoke-BRAVOLogSyncRun -LogsDirectory $logSyncLogsDir -StateRoot $logSyncStateRoot `
        -RemoteDirectory 'logs/runtime/SELFTEST-HOST' `
        -MaskFile { param($p) $p } -RemoveMaskedCopy { param($p) } `
        -UploadFile {
            param($local, $remoteDir, $remoteName)
            $logSyncRun4Attempts.Add($remoteName)
            if ($remoteName -eq 'BRAVO_ARCHIV_run1.log') {
                [pscustomobject]@{ Success = $false; Error = 'simulated SFTP timeout' }
            } else {
                [pscustomobject]@{ Success = $true; Error = $null }
            }
        }
    Test-BRAVOCondition -Condition (
        $logSyncRun4.Attempted -eq 2 -and $logSyncRun4.Uploaded -eq 1 -and $logSyncRun4.Failed -eq 1 -and
        ($logSyncRun4.Errors -join ';') -match 'BRAVO_ARCHIV_run1\.log.*simulated SFTP timeout' -and
        $logSyncRun4Attempts.Contains('script_log_setup.txt')
    ) -Name 'LogSync/SingleFileFailureIsolated' `
        -Failure "#364: збій ОДНОГО файлу не сміє перервати решту allowlist; факт Attempted=$($logSyncRun4.Attempted) Uploaded=$($logSyncRun4.Uploaded) Failed=$($logSyncRun4.Failed) Errors=$($logSyncRun4.Errors -join '|')"

    # --- LogSync/BudgetStopsAfterMaxFiles (бюджет: кількість) ---
    for ($i = 1; $i -le 5; $i++) {
        [IO.File]::WriteAllText((Join-Path $logSyncLogsDir "BRAVO_MAINTENANCE_budget$i.log"), "payload$i", (New-Object Text.UTF8Encoding($false)))
    }
    $logSyncRun5 = Invoke-BRAVOLogSyncRun -LogsDirectory $logSyncLogsDir -StateRoot $logSyncStateRoot `
        -RemoteDirectory 'logs/runtime/SELFTEST-HOST' -MaxFiles 2 `
        -MaskFile { param($p) $p } -RemoveMaskedCopy { param($p) } `
        -UploadFile { param($local, $remoteDir, $remoteName) [pscustomobject]@{ Success = $true; Error = $null } }
    Test-BRAVOCondition -Condition (
        $logSyncRun5.Attempted -eq 2 -and $logSyncRun5.BudgetExhausted
    ) -Name 'LogSync/BudgetStopsAfterMaxFiles' `
        -Failure "#364: -MaxFiles 2 має зупинити цикл рівно після 2 спроб і позначити BudgetExhausted; факт Attempted=$($logSyncRun5.Attempted) BudgetExhausted=$($logSyncRun5.BudgetExhausted)"

    # --- LogSync/OversizedFileSkippedNotStarvingRest (review P1) ---
    # Файл, що сам перевищує MaxTotalBytes, раніше ламав ВЕСЬ цикл (break):
    # оскільки план сортується за іменем, цей самий файл назавжди лишався б
    # першим і назавжди блокував би алфавітно пізніші файли від
    # вивантаження в БУДЬ-якому майбутньому прогоні. 'BRAVO_ARCHIV_...'
    # сортується раніше за 'script_log_...' -- саме порядок, що відтворює
    # дефект.
    $logSyncOversizedDir = Join-Path ([IO.Path]::GetTempPath()) ("logsync_oversized_{0}" -f [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($logSyncOversizedDir)
    $logSyncOversizedState = Join-Path ([IO.Path]::GetTempPath()) ("logsync_oversized_state_{0}" -f [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText((Join-Path $logSyncOversizedDir 'BRAVO_ARCHIV_huge.log'), ('x' * 200), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $logSyncOversizedDir 'script_log_small.txt'), 'small', (New-Object Text.UTF8Encoding($false)))
    $logSyncRun7Attempts = New-Object System.Collections.Generic.List[string]
    $logSyncRun7 = Invoke-BRAVOLogSyncRun -LogsDirectory $logSyncOversizedDir -StateRoot $logSyncOversizedState `
        -RemoteDirectory 'logs/runtime/SELFTEST-HOST' -MaxTotalBytes 100 `
        -MaskFile { param($p) $p } -RemoveMaskedCopy { param($p) } `
        -UploadFile {
            param($local, $remoteDir, $remoteName)
            $logSyncRun7Attempts.Add($remoteName)
            [pscustomobject]@{ Success = $true; Error = $null }
        }
    Test-BRAVOCondition -Condition (
        $logSyncRun7.OversizedSkipped.Contains('BRAVO_ARCHIV_huge.log') -and
        -not $logSyncRun7Attempts.Contains('BRAVO_ARCHIV_huge.log') -and
        $logSyncRun7Attempts.Contains('script_log_small.txt') -and
        $logSyncRun7.Uploaded -eq 1 -and
        -not $logSyncRun7.BudgetExhausted
    ) -Name 'LogSync/OversizedFileSkippedNotStarvingRest' `
        -Failure "файл, що сам перевищує MaxTotalBytes, мусить бути пропущений (OversizedSkipped), а НЕ ламати цикл для алфавітно пізніших файлів; факт OversizedSkipped=$($logSyncRun7.OversizedSkipped -join ',') Attempts=$($logSyncRun7Attempts -join ',') Uploaded=$($logSyncRun7.Uploaded) BudgetExhausted=$($logSyncRun7.BudgetExhausted)"

    # --- LogSync/SessionBreakStopsCycleWithoutRetryStorm (розрив сесії) ---
    $logSyncRun6HealthChecks = 0
    $logSyncRun6 = Invoke-BRAVOLogSyncRun -LogsDirectory $logSyncLogsDir -StateRoot $logSyncStateRoot `
        -RemoteDirectory 'logs/runtime/SELFTEST-HOST' `
        -MaskFile { param($p) $p } -RemoveMaskedCopy { param($p) } `
        -UploadFile { param($local, $remoteDir, $remoteName) [pscustomobject]@{ Success = $true; Error = $null } } `
        -IsSessionHealthy { $script:logSyncRun6HealthChecks++; $false }
    Test-BRAVOCondition -Condition (
        $logSyncRun6.Attempted -eq 0 -and $logSyncRun6.SessionBroke
    ) -Name 'LogSync/SessionBreakStopsCycleWithoutRetryStorm' `
        -Failure "#364: розрив сесії МІЖ файлами має зупинити цикл одразу (SessionBroke=true), не спробувати жодного файлу; факт Attempted=$($logSyncRun6.Attempted) SessionBroke=$($logSyncRun6.SessionBroke)"

    # --- LogSync/LocalFilesNeverModified (локальні файли не змінюються) ---
    $logSyncLocalContentBefore = [IO.File]::ReadAllText($logSyncFile1)
    [void](Invoke-BRAVOLogSyncRun -LogsDirectory $logSyncLogsDir -StateRoot $logSyncStateRoot `
        -RemoteDirectory 'logs/runtime/SELFTEST-HOST' `
        -MaskFile { param($p) $p } -RemoveMaskedCopy { param($p) } `
        -UploadFile { param($local, $remoteDir, $remoteName) [pscustomobject]@{ Success = $true; Error = $null } })
    $logSyncLocalContentAfter = [IO.File]::ReadAllText($logSyncFile1)
    Test-BRAVOCondition -Condition ($logSyncLocalContentBefore -ceq $logSyncLocalContentAfter) `
        -Name 'LogSync/LocalFilesNeverModified' `
        -Failure "#364: синхронізація не сміє змінювати локальний файл; before='$logSyncLocalContentBefore' after='$logSyncLocalContentAfter'"
} finally {
    if (Test-Path -LiteralPath $logSyncTestRoot) {
        Remove-Item -LiteralPath $logSyncTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Remove-Module -Name 'BRAVO.LogSync' -Force -ErrorAction SilentlyContinue
