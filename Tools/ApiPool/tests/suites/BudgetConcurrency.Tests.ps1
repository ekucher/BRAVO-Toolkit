# Budget concurrency suite. Dot-sourced by Invoke-ApiPoolTests.ps1.
# Separate powershell.exe processes race on ONE sandbox ledger; the ledger lock must serialize them.
# Children are only waited for; only Process objects started here may be killed, and only on timeout.

$concSandbox = New-ApiPoolTestSandbox
try {
    $concHelper = Join-Path (Join-Path $script:TestsRoot 'helpers') 'Invoke-ApiPoolReserveWorker.ps1'
    $concAmount = [long]1000000
    $concSuccessSlots = 24
    $concLimit = $concAmount * $concSuccessSlots
    $concDeadlineMs = 60000

    foreach ($workerCount in @(2, 4, 8)) {
        $tag = 'N' + $workerCount
        $root = Join-Path $concSandbox $tag
        [void](Initialize-ApiPoolLedger -StateRoot $root -GlobalLimitMicroUsd $concLimit)
        $perWorker = [int][Math]::Ceiling(($concSuccessSlots * 1.5) / $workerCount)
        $attempts = $perWorker * $workerCount

        $procs = New-Object System.Collections.ArrayList
        $resultFiles = New-Object System.Collections.ArrayList
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        for ($w = 1; $w -le $workerCount; $w++) {
            $resultPath = Join-Path $concSandbox ('{0}-w{1}.json' -f $tag, $w)
            $argText = '-NoProfile -File "{0}" -ModulesDir "{1}" -StateRoot "{2}" -JobPrefix "{3}" -Count {4} -AmountMicroUsd {5} -PerJobLimitMicroUsd {6} -ResultPath "{7}"' -f $concHelper, $script:ModulesRoot, $root, ('{0}w{1}' -f $tag, $w), $perWorker, $concAmount, ($concLimit * 10), $resultPath
            $p = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argText -PassThru -WindowStyle Hidden
            [void]$procs.Add($p)
            [void]$resultFiles.Add($resultPath)
        }

        $allExited = $true
        foreach ($p in $procs) {
            $left = [int][Math]::Max(1, $concDeadlineMs - $clock.ElapsedMilliseconds)
            if (-not $p.WaitForExit($left)) {
                $allExited = $false
                try { $p.Kill() } catch { $null = $_ }
            }
        }
        Assert-ApiPoolTrue $allExited ($tag + '/AllChildrenExitedWithinTimeout')
        Write-Host ('[INFO] {0}: {1} workers, {2} attempts, {3} ms' -f $tag, $workerCount, $attempts, $clock.ElapsedMilliseconds)
        if (-not $allExited) { continue }

        $exitCodes = @($procs | ForEach-Object { $_.ExitCode })
        Assert-ApiPoolEqual 0 @($exitCodes | Where-Object { $_ -ne 0 }).Count ($tag + '/AllChildrenExitCodeZero')

        $successes = 0
        $refusals = @{}
        $ids = New-Object System.Collections.ArrayList
        $resultsPresent = 0
        foreach ($file in $resultFiles) {
            if (-not [System.IO.File]::Exists($file)) { continue }
            $resultsPresent++
            $res = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($file))
            $successes += [int]$res.successes
            foreach ($id in @($res.reservationIds)) { [void]$ids.Add([string]$id) }
            foreach ($prop in $res.refusals.PSObject.Properties) {
                if ($refusals.ContainsKey($prop.Name)) { $refusals[$prop.Name] += [int]$prop.Value } else { $refusals[$prop.Name] = [int]$prop.Value }
            }
        }
        Assert-ApiPoolEqual $workerCount $resultsPresent ($tag + '/AllResultFilesWritten')
        Assert-ApiPoolEqual $concSuccessSlots $successes ($tag + '/ExactlyLimitDividedByAmountSucceeded')
        Assert-ApiPoolTrue (($successes * $concAmount) -le $concLimit) ($tag + '/SumOfReservationsWithinLimit')
        $refusedTotal = 0
        foreach ($v in $refusals.Values) { $refusedTotal += $v }
        Assert-ApiPoolEqual ($attempts - $concSuccessSlots) $refusedTotal ($tag + '/EveryOtherAttemptRefused')
        Assert-ApiPoolEqual ($attempts - $concSuccessSlots) $(if ($refusals.ContainsKey('BUDGET_EXHAUSTED_GLOBAL')) { $refusals['BUDGET_EXHAUSTED_GLOBAL'] } else { 0 }) ($tag + '/RefusalsAreGlobalExhaustionOnly')
        Assert-ApiPoolEqual $concSuccessSlots @($ids | Sort-Object -Unique).Count ($tag + '/ReservationIdsUnique')

        $st = Get-ApiPoolBudgetStatus -StateRoot $root
        Assert-ApiPoolEqual 'OK' $st.State ($tag + '/LedgerChainValid')
        Assert-ApiPoolTrue ($null -eq $st.CorruptReason) ($tag + '/NoCorruptReason')
        Assert-ApiPoolEqual $concLimit $st.ReservedMicroUsd ($tag + '/ReservedEqualsLimit')
        Assert-ApiPoolEqual 0 $st.AvailableMicroUsd ($tag + '/NothingLeft')
        Assert-ApiPoolEqual $concSuccessSlots $st.OpenReservations.Count ($tag + '/OpenReservationCount')

        $lines = @(([System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'budget') 'ledger.jsonl'))).Split([char]10) | Where-Object { $_ -ne '' })
        $seqs = @($lines | ForEach-Object { [long](ConvertFrom-Json -InputObject $_).seq })
        Assert-ApiPoolEqual ($concSuccessSlots + 1) $seqs.Count ($tag + '/LedgerLineCount')
        Assert-ApiPoolEqual $seqs.Count @($seqs | Sort-Object -Unique).Count ($tag + '/NoDuplicateSeq')
        $consecutive = $true
        for ($i = 0; $i -lt $seqs.Count; $i++) { if ($seqs[$i] -ne ($i + 1)) { $consecutive = $false } }
        Assert-ApiPoolTrue $consecutive ($tag + '/SeqStrictlyConsecutive')
    }
}
finally {
    Remove-ApiPoolTestSandbox -Path $concSandbox
}
