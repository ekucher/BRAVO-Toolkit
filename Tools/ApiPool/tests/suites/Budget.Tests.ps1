# Budget suite. Dot-sourced by Invoke-ApiPoolTests.ps1. Offline; sandbox state roots only.

$budgetSandbox = New-ApiPoolTestSandbox
try {
    $budgetHelper = Join-Path (Join-Path $script:TestsRoot 'helpers') 'Invoke-ApiPoolReserveWorker.ps1'
    $budgetUtf8 = New-Object System.Text.UTF8Encoding($false)

    function New-BudgetRoot {
        return (Join-Path $budgetSandbox ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    }

    function New-BudgetFixture {
        param([long]$Limit = 10000)
        $r = New-BudgetRoot
        [void](Initialize-ApiPoolLedger -StateRoot $r -GlobalLimitMicroUsd $Limit)
        return $r
    }

    function Get-BudgetErrCode {
        param([scriptblock]$Block)
        try { $null = & $Block; return $null } catch { return (Get-ApiPoolErrorCode -ErrorRecord $_) }
    }

    function Get-BudgetLedgerPath { param([string]$Root) return (Join-Path (Join-Path $Root 'budget') 'ledger.jsonl') }

    function Get-BudgetLedgerRecords {
        param([string]$Root)
        $text = [System.IO.File]::ReadAllText((Get-BudgetLedgerPath -Root $Root))
        return @($text.Split([char]10) | Where-Object { $_ -ne '' } | ForEach-Object { ConvertFrom-Json -InputObject $_ })
    }

    function Get-BudgetHead {
        param([string]$Root)
        $records = @(Get-BudgetLedgerRecords -Root $Root)
        $last = $records[$records.Count - 1]
        return @{ Seq = [long]$last.seq; Hash = [string]$last.hash }
    }

    function Add-BudgetRawText {
        param([string]$Root, [string]$Text)
        [System.IO.File]::AppendAllText((Get-BudgetLedgerPath -Root $Root), $Text, $budgetUtf8)
    }

    function New-BudgetForgedLine {
        # A record with a CORRECT hash, so only the semantic validation can reject it.
        param([long]$Seq, [string]$Prev, [string]$Type, $Data)
        $unsigned = [ordered]@{ seq = $Seq; ts = '2030-01-01T00:00:00.0000000Z'; type = $Type; data = $Data; prevHash = $Prev }
        $hash = Get-ApiPoolSha256Hex -Text ($Prev + (ConvertTo-ApiPoolCanonicalJson -InputObject $unsigned))
        $full = [ordered]@{}
        foreach ($k in $unsigned.Keys) { $full[$k] = $unsigned[$k] }
        $full['hash'] = $hash
        return (ConvertTo-ApiPoolCanonicalJson -InputObject $full)
    }

    function Edit-BudgetLedgerText {
        param([string]$Root, [string]$Old, [string]$New)
        $path = Get-BudgetLedgerPath -Root $Root
        $text = [System.IO.File]::ReadAllText($path)
        $idx = $text.IndexOf($Old, [System.StringComparison]::Ordinal)
        if ($idx -lt 0) { throw ('test fixture: pattern not found: ' + $Old) }
        $text = $text.Substring(0, $idx) + $New + $text.Substring($idx + $Old.Length)
        [System.IO.File]::WriteAllText($path, $text, $budgetUtf8)
    }

    function New-BudgetBaseLedger {
        # INIT, RESERVE(100, job-a), RESERVE(200, job-b), COMMIT(first, 90)
        $r = New-BudgetFixture -Limit 10000
        $a = New-ApiPoolReservation -StateRoot $r -JobId 'job-a' -AttemptId 'a1' -AmountMicroUsd 100 -PerJobLimitMicroUsd 5000
        $b = New-ApiPoolReservation -StateRoot $r -JobId 'job-b' -AttemptId 'a1' -AmountMicroUsd 200 -PerJobLimitMicroUsd 5000
        [void](Complete-ApiPoolReservation -StateRoot $r -ReservationId $a.ReservationId -ActualMicroUsd 90 -Evidence @{ requestId = 'req_1'; messageId = 'msg_1'; usage = @{ input_tokens = 1; output_tokens = 2 } })
        return @{ Root = $r; A = $a.ReservationId; B = $b.ReservationId }
    }

    function Get-BudgetFileBase64 { param([string]$Path) return [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) }

    # ---------------- Initialization ----------------
    $r = New-BudgetRoot
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolEqual 'UNINITIALIZED' $st.State 'Init/StatusBeforeInit'
    Assert-ApiPoolEqual 'LEDGER_UNINITIALIZED' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 1 }) 'Init/ReserveBeforeInitRefused'
    $init = Initialize-ApiPoolLedger -StateRoot $r -GlobalLimitMicroUsd 5000000
    Assert-ApiPoolTrue ($init.Created -and $init.GlobalLimitMicroUsd -eq 5000000) 'Init/Created'
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolEqual 'OK' $st.State 'Init/StateOk'
    Assert-ApiPoolEqual 5000000 $st.GlobalLimitMicroUsd 'Init/Limit'
    Assert-ApiPoolEqual 5000000 $st.AvailableMicroUsd 'Init/AvailableEqualsLimit'
    Assert-ApiPoolEqual 1 $st.LastSeq 'Init/LastSeqOne'
    Assert-ApiPoolEqual 0 $st.OpenReservations.Count 'Init/NoOpenReservations'
    Assert-ApiPoolTrue (-not $st.EmergencyStop.Active) 'Init/NoEmergencyStop'
    $first = (Get-BudgetLedgerRecords -Root $r)[0]
    Assert-ApiPoolTrue ($first.type -ceq 'INIT' -and $first.seq -eq 1 -and $first.prevHash -ceq ('0' * 64)) 'Init/FirstRecordIsInit'
    $again = Initialize-ApiPoolLedger -StateRoot $r -GlobalLimitMicroUsd 5000000
    Assert-ApiPoolTrue (-not $again.Created) 'Init/IdempotentSameLimit'
    Assert-ApiPoolEqual 1 (Get-ApiPoolBudgetStatus -StateRoot $r).LastSeq 'Init/IdempotentWritesNothing'
    $caught = $null
    try { Initialize-ApiPoolLedger -StateRoot $r -GlobalLimitMicroUsd 5000001 } catch { $caught = $_ }
    Assert-ApiPoolTrue ($null -ne $caught -and (Get-ApiPoolErrorCode -ErrorRecord $caught) -ceq 'CONFIG_INVALID' -and $caught.Exception.Message.Contains('ledger initialized with a different global limit')) 'Init/LimitMismatchRefused'
    Assert-ApiPoolEqual 5000000 (Get-ApiPoolBudgetStatus -StateRoot $r).GlobalLimitMicroUsd 'Init/LimitUnchangedAfterMismatch'
    $badRoot = New-BudgetRoot
    Assert-ApiPoolEqual 'REQUEST_INVALID' (Get-BudgetErrCode { Initialize-ApiPoolLedger -StateRoot $badRoot -GlobalLimitMicroUsd 0 }) 'Init/ZeroLimitRefused'
    # Real-system paths go ONLY to the pure validator; budget writers never receive them.
    foreach ($badRoot2 in @('relative\state', 'C:\ProgramData\BRAVO\x', '\\localhost\C$\x', '\\127.0.0.1\c$\x', '\\?\C:\x', '\\.\C:\x')) {
        Assert-ApiPoolForbiddenPathRejected -Path $badRoot2 -Name ('Init/StateRootValidatorRejects/' + $badRoot2)
    }
    # Writer refusal: junction ancestor inside the sandbox.
    $budJTarget = Join-Path $budgetSandbox 'bj-target'
    $budJLink = Join-Path $budgetSandbox 'bj-link'
    [void][System.IO.Directory]::CreateDirectory($budJTarget)
    $null = & cmd.exe /c ('mklink /J "{0}" "{1}"' -f $budJLink, $budJTarget)
    Assert-ApiPoolTrue ([System.IO.Directory]::Exists($budJLink)) 'Init/JunctionFixtureCreated'
    try {
        $budJRoot = Join-Path $budJLink 'state'
        Invoke-ApiPoolSandboxRefusal -Path $budJRoot -Name 'Init/InitializeLedgerRefusesJunctionRoot' -ScriptBlock { Initialize-ApiPoolLedger -StateRoot $budJRoot -GlobalLimitMicroUsd 1000 }
        Invoke-ApiPoolSandboxRefusal -Path $budJRoot -Name 'Init/ReserveRefusesJunctionRoot' -ScriptBlock { New-ApiPoolReservation -StateRoot $budJRoot -JobId 'j' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 1 }
        Assert-ApiPoolEqual 0 @(Get-ChildItem -LiteralPath $budJTarget -Force).Count 'Init/JunctionTargetUntouched'
    }
    finally {
        if ([System.IO.Directory]::Exists($budJLink)) { [System.IO.Directory]::Delete($budJLink, $false) }
    }

    # ---------------- Accounting ----------------
    $r = New-BudgetFixture -Limit 1000
    $r1 = New-ApiPoolReservation -StateRoot $r -JobId 'job-1' -AttemptId 'a1' -AmountMicroUsd 300 -PerJobLimitMicroUsd 1000
    Assert-ApiPoolTrue ($r1.ReservationId -cmatch '^rsv-[0-9a-f]{24}$') 'Acct/ReservationIdFormat'
    Assert-ApiPoolEqual 700 $r1.AvailableAfterMicroUsd 'Acct/AvailableAfterReturned'
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.ReservedMicroUsd -eq 300 -and $st.AvailableMicroUsd -eq 700 -and $st.CommittedMicroUsd -eq 0 -and $st.OpenReservations.Count -eq 1) 'Acct/ReservedCounted'
    Assert-ApiPoolEqual 'job-1' $st.OpenReservations[0].JobId 'Acct/OpenReservationDetails'
    $r2 = New-ApiPoolReservation -StateRoot $r -JobId 'job-1' -AttemptId 'a2' -AmountMicroUsd 200 -PerJobLimitMicroUsd 1000
    $undo = Undo-ApiPoolReservation -StateRoot $r -ReservationId $r2.ReservationId -Reason 'http 429 without usage'
    Assert-ApiPoolEqual 200 $undo.ReleasedMicroUsd 'Acct/UndoReleasesAmount'
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.ReservedMicroUsd -eq 300 -and $st.AvailableMicroUsd -eq 700) 'Acct/UndoRestoresAvailable'
    $c1 = Complete-ApiPoolReservation -StateRoot $r -ReservationId $r1.ReservationId -ActualMicroUsd 250 -Evidence @{ requestId = 'req_x'; messageId = 'msg_x'; usage = @{ input_tokens = 10; output_tokens = 20 } }
    Assert-ApiPoolTrue ((-not $c1.Overrun) -and $c1.ActualMicroUsd -eq 250 -and $c1.ReservedMicroUsd -eq 300) 'Acct/CommitNoOverrun'
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.CommittedMicroUsd -eq 250 -and $st.ReservedMicroUsd -eq 0 -and $st.AvailableMicroUsd -eq 750 -and $st.State -ceq 'OK') 'Acct/CommitCountedAtActual'
    $r3 = New-ApiPoolReservation -StateRoot $r -JobId 'job-2' -AttemptId 'a1' -AmountMicroUsd 100 -PerJobLimitMicroUsd 1000
    [void](Set-ApiPoolReservationUnreconciled -StateRoot $r -ReservationId $r3.ReservationId -Reason 'transport timeout after send')
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.UnreconciledMicroUsd -eq 100 -and $st.ReservedMicroUsd -eq 0 -and $st.AvailableMicroUsd -eq 650) 'Acct/UnreconciledStaysCounted'
    Assert-ApiPoolTrue ($st.OpenReservations.Count -eq 1 -and $st.OpenReservations[0].State -ceq 'UNRECONCILED') 'Acct/UnreconciledListedAsOpen'
    $res = Resolve-ApiPoolOrphanReservation -StateRoot $r -ReservationId $r3.ReservationId -ActualMicroUsd 80 -Evidence @{ requestId = 'req_y'; messageId = 'msg_y'; usage = @{ input_tokens = 1; output_tokens = 1 } } -Reason 'console usage checked by operator'
    Assert-ApiPoolTrue (-not $res.Overrun) 'Acct/ResolveNoOverrun'
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.CommittedMicroUsd -eq 330 -and $st.UnreconciledMicroUsd -eq 0 -and $st.AvailableMicroUsd -eq 670 -and $st.OpenReservations.Count -eq 0) 'Acct/ResolveCountedAtActual'
    $types = @(Get-BudgetLedgerRecords -Root $r | ForEach-Object { $_.type })
    Assert-ApiPoolEqual 'INIT,RESERVE,RESERVE,UNDO,COMMIT,RESERVE,UNRECONCILED,RESOLVE' ($types -join ',') 'Acct/LedgerRecordSequence'
    $commitRec = @(Get-BudgetLedgerRecords -Root $r | Where-Object { $_.type -ceq 'COMMIT' })[0]
    Assert-ApiPoolTrue ($commitRec.data.evidence.requestId -ceq 'req_x' -and $commitRec.data.evidence.usage.output_tokens -eq 20) 'Acct/EvidencePersisted'

    # ---------------- Exhaustion exactly at the limit ----------------
    $r = New-BudgetFixture -Limit 1000
    $x = New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 1000 -PerJobLimitMicroUsd 5000
    Assert-ApiPoolEqual 0 $x.AvailableAfterMicroUsd 'Limit/ExactlyAtLimitAllowed'
    Assert-ApiPoolEqual 'BUDGET_EXHAUSTED_GLOBAL' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j2' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5000 }) 'Limit/OneMicroOverRefused'
    $r = New-BudgetFixture -Limit 1000
    [void](New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 999 -PerJobLimitMicroUsd 5000)
    Assert-ApiPoolEqual 'BUDGET_EXHAUSTED_GLOBAL' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j2' -AttemptId 'a' -AmountMicroUsd 2 -PerJobLimitMicroUsd 5000 }) 'Limit/PlusTwoOverRefused'
    $lastOne = New-ApiPoolReservation -StateRoot $r -JobId 'j2' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5000
    Assert-ApiPoolEqual 0 $lastOne.AvailableAfterMicroUsd 'Limit/LastMicroAllowed'
    Assert-ApiPoolEqual 'REQUEST_INVALID' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 0 -PerJobLimitMicroUsd 5000 }) 'Limit/ZeroAmountRefused'
    Assert-ApiPoolEqual 'REQUEST_INVALID' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd -5 -PerJobLimitMicroUsd 5000 }) 'Limit/NegativeAmountRefused'
    Assert-ApiPoolEqual 'REQUEST_INVALID' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId '  ' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5000 }) 'Limit/EmptyJobIdRefused'
    $big = [long]::MaxValue
    $r = New-BudgetFixture -Limit $big
    $bigRes = New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd $big -PerJobLimitMicroUsd $big
    Assert-ApiPoolEqual 0 $bigRes.AvailableAfterMicroUsd 'Limit/MaxLongNoOverflow'
    Assert-ApiPoolEqual 'BUDGET_EXHAUSTED_GLOBAL' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j2' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd $big }) 'Limit/MaxLongPlusOneRefused'

    # ---------------- Per-job limit across attempts ----------------
    $r = New-BudgetFixture -Limit 100000
    $j1 = New-ApiPoolReservation -StateRoot $r -JobId 'job-x' -AttemptId 'a1' -AmountMicroUsd 400 -PerJobLimitMicroUsd 1000
    $j2 = New-ApiPoolReservation -StateRoot $r -JobId 'job-x' -AttemptId 'a2' -AmountMicroUsd 400 -PerJobLimitMicroUsd 1000
    Assert-ApiPoolEqual 'BUDGET_EXHAUSTED_JOB' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'job-x' -AttemptId 'a3' -AmountMicroUsd 400 -PerJobLimitMicroUsd 1000 }) 'Job/ThirdAttemptRefused'
    $other = New-ApiPoolReservation -StateRoot $r -JobId 'job-y' -AttemptId 'a1' -AmountMicroUsd 400 -PerJobLimitMicroUsd 1000
    Assert-ApiPoolTrue ($null -ne $other) 'Job/OtherJobUnaffected'
    [void](Undo-ApiPoolReservation -StateRoot $r -ReservationId $j2.ReservationId -Reason 'not charged')
    $j3 = New-ApiPoolReservation -StateRoot $r -JobId 'job-x' -AttemptId 'a3' -AmountMicroUsd 400 -PerJobLimitMicroUsd 1000
    Assert-ApiPoolTrue ($null -ne $j3) 'Job/UndoneAmountNotCounted'
    [void](Complete-ApiPoolReservation -StateRoot $r -ReservationId $j1.ReservationId -ActualMicroUsd 300 -Evidence @{ requestId = 'r'; messageId = 'm'; usage = @{} })
    $j4 = New-ApiPoolReservation -StateRoot $r -JobId 'job-x' -AttemptId 'a4' -AmountMicroUsd 300 -PerJobLimitMicroUsd 1000
    Assert-ApiPoolTrue ($null -ne $j4) 'Job/CommittedCountedAtActual'
    Assert-ApiPoolEqual 'BUDGET_EXHAUSTED_JOB' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'job-x' -AttemptId 'a5' -AmountMicroUsd 1 -PerJobLimitMicroUsd 1000 }) 'Job/ExactlyAtJobLimitThenRefused'
    Assert-ApiPoolEqual 'REQUEST_INVALID' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'job-z' -AttemptId 'a1' -AmountMicroUsd 1 -PerJobLimitMicroUsd 0 }) 'Job/ZeroPerJobLimitRefused'

    # ---------------- Negative balance impossible ----------------
    $r = New-BudgetFixture -Limit 1000
    $o = New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 1000 -PerJobLimitMicroUsd 5000
    $oc = Complete-ApiPoolReservation -StateRoot $r -ReservationId $o.ReservationId -ActualMicroUsd 1500 -Evidence @{ requestId = 'r'; messageId = 'm'; usage = @{} }
    Assert-ApiPoolTrue ($oc.Overrun -eq $true) 'Negative/OverrunReported'
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.CommittedMicroUsd -eq 1500 -and $st.AvailableMicroUsd -eq 0) 'Negative/AvailableNeverBelowZero'
    Assert-ApiPoolEqual 'BUDGET_STOPPED' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'b' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5000 }) 'Negative/ReserveAfterOverrunRefused'
    [void](Clear-ApiPoolEmergencyStop -StateRoot $r -Reason 'operator reviewed overrun')
    Assert-ApiPoolEqual 'BUDGET_EXHAUSTED_GLOBAL' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'c' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5000 }) 'Negative/StillRefusedAfterClearWhenOverLimit'
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.State -ceq 'OK' -and $st.AvailableMicroUsd -eq 0) 'Negative/AvailableStillZero'

    # ---------------- Emergency stop ----------------
    $r = New-BudgetFixture -Limit 1000
    $markerPath = Join-Path (Join-Path $r 'budget') 'EMERGENCY_STOP'
    [System.IO.File]::WriteAllText($markerPath, '{"reason":"manual marker","ts":"2030-01-01T00:00:00.0000000Z"}')
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.State -ceq 'STOPPED' -and $st.EmergencyStop.Active -and $st.EmergencyStop.Source -ceq 'marker' -and $st.EmergencyStop.Reason -ceq 'manual marker') 'Stop/MarkerOnlyStops'
    Assert-ApiPoolEqual 'BUDGET_STOPPED' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5 }) 'Stop/MarkerOnlyRefusesReserve'
    [System.IO.File]::Delete($markerPath)
    Assert-ApiPoolEqual 'OK' (Get-ApiPoolBudgetStatus -StateRoot $r).State 'Stop/MarkerRemovedResumes'
    $set = Set-ApiPoolEmergencyStop -StateRoot $r -Reason 'operator stop'
    Assert-ApiPoolTrue ($set.MarkerWritten -and $set.RecordAppended) 'Stop/SetWritesMarkerAndRecord'
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.EmergencyStop.Source -ceq 'both' -and $st.State -ceq 'STOPPED') 'Stop/SourceBoth'
    $markerJson = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($markerPath))
    Assert-ApiPoolEqual 'operator stop' $markerJson.reason 'Stop/MarkerContainsReason'
    [System.IO.File]::Delete($markerPath)
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.State -ceq 'STOPPED' -and $st.EmergencyStop.Source -ceq 'record' -and $st.EmergencyStop.Reason -ceq 'operator stop') 'Stop/RecordOnlyStillStops'
    Assert-ApiPoolEqual 'BUDGET_STOPPED' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5 }) 'Stop/RecordOnlyRefusesReserve'
    Assert-ApiPoolTrue ((Get-BudgetErrCode { Clear-ApiPoolEmergencyStop -StateRoot $r -Reason '   ' }) -ceq 'REQUEST_INVALID') 'Stop/ClearRequiresReasonWhitespace'
    Assert-ApiPoolThrows { Clear-ApiPoolEmergencyStop -StateRoot $r -Reason '' } 'Stop/ClearRequiresReasonEmpty'
    Assert-ApiPoolEqual 'STOPPED' (Get-ApiPoolBudgetStatus -StateRoot $r).State 'Stop/StillStoppedAfterRefusedClear'
    $clear = Clear-ApiPoolEmergencyStop -StateRoot $r -Reason 'incident closed'
    Assert-ApiPoolTrue (-not $clear.MarkerRemoved -and $clear.RecordAppended) 'Stop/ClearReportsActions'
    Assert-ApiPoolEqual 'OK' (Get-ApiPoolBudgetStatus -StateRoot $r).State 'Stop/ClearResumes'
    $ok1 = New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5
    Assert-ApiPoolTrue ($null -ne $ok1) 'Stop/ReserveWorksAfterClear'
    $set = Set-ApiPoolEmergencyStop -StateRoot $r -Reason 'second stop'
    $set2 = Set-ApiPoolEmergencyStop -StateRoot $r -Reason 'second stop again'
    Assert-ApiPoolTrue ($set2.MarkerWritten -and -not $set2.RecordAppended) 'Stop/RepeatedSetDoesNotDuplicateRecord'
    $clear = Clear-ApiPoolEmergencyStop -StateRoot $r -Reason 'done'
    Assert-ApiPoolTrue ($clear.MarkerRemoved -and (-not [System.IO.File]::Exists($markerPath))) 'Stop/ClearRemovesMarker'
    $stopTypes = @(Get-BudgetLedgerRecords -Root $r | ForEach-Object { $_.type })
    Assert-ApiPoolEqual 'INIT,STOP,CLEAR,RESERVE,STOP,CLEAR' ($stopTypes -join ',') 'Stop/LedgerStopClearRecords'

    # ---------------- Overrun -> automatic stop ----------------
    $r = New-BudgetFixture -Limit 10000
    $ov = New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 100 -PerJobLimitMicroUsd 5000
    $oc = Complete-ApiPoolReservation -StateRoot $r -ReservationId $ov.ReservationId -ActualMicroUsd 150 -Evidence @{ requestId = 'r'; messageId = 'm'; usage = @{} }
    Assert-ApiPoolTrue ($oc.Overrun -and $oc.ActualMicroUsd -eq 150 -and $oc.ReservedMicroUsd -eq 100) 'Overrun/ObjectReturnedNotThrown'
    Assert-ApiPoolTrue ([System.IO.File]::Exists((Join-Path (Join-Path $r 'budget') 'EMERGENCY_STOP'))) 'Overrun/MarkerCreated'
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.State -ceq 'STOPPED' -and $st.CommittedMicroUsd -eq 150 -and $st.EmergencyStop.Source -ceq 'both') 'Overrun/StoppedAndCommittedAtActual'
    Assert-ApiPoolEqual 'automatic: cost bound violated' $st.EmergencyStop.Reason 'Overrun/StopReason'
    Assert-ApiPoolEqual 'INIT,RESERVE,COMMIT,OVERRUN,STOP' (@(Get-BudgetLedgerRecords -Root $r | ForEach-Object { $_.type }) -join ',') 'Overrun/RecordOrder'
    $ovRec = @(Get-BudgetLedgerRecords -Root $r | Where-Object { $_.type -ceq 'OVERRUN' })[0]
    Assert-ApiPoolTrue ($ovRec.data.reserved -eq 100 -and $ovRec.data.actual -eq 150 -and $ovRec.data.id -ceq $ov.ReservationId) 'Overrun/OverrunRecordContent'
    Assert-ApiPoolEqual 'BUDGET_STOPPED' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'b' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5000 }) 'Overrun/ReserveRefusedAfterOverrun'
    $r = New-BudgetFixture -Limit 10000
    $ov2 = New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 100 -PerJobLimitMicroUsd 5000
    $rv = Resolve-ApiPoolOrphanReservation -StateRoot $r -ReservationId $ov2.ReservationId -ActualMicroUsd 101 -Evidence @{ requestId = 'r'; messageId = 'm'; usage = @{} } -Reason 'operator checked usage'
    Assert-ApiPoolTrue ($rv.Overrun -eq $true -and (Get-ApiPoolBudgetStatus -StateRoot $r).State -ceq 'STOPPED') 'Overrun/ResolveOverrunAlsoStops'
    Assert-ApiPoolEqual 'INIT,RESERVE,RESOLVE,OVERRUN,STOP' (@(Get-BudgetLedgerRecords -Root $r | ForEach-Object { $_.type }) -join ',') 'Overrun/ResolveRecordOrder'
    $r = New-BudgetFixture -Limit 10000
    $eq = New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 100 -PerJobLimitMicroUsd 5000
    $eqc = Complete-ApiPoolReservation -StateRoot $r -ReservationId $eq.ReservationId -ActualMicroUsd 100 -Evidence @{ requestId = 'r'; messageId = 'm'; usage = @{} }
    Assert-ApiPoolTrue ((-not $eqc.Overrun) -and (Get-ApiPoolBudgetStatus -StateRoot $r).State -ceq 'OK') 'Overrun/ActualEqualsReservedIsNotOverrun'

    # ---------------- Reservation state machine ----------------
    $r = New-BudgetFixture -Limit 10000
    Assert-ApiPoolEqual 'RESERVATION_NOT_FOUND' (Get-BudgetErrCode { Complete-ApiPoolReservation -StateRoot $r -ReservationId 'rsv-doesnotexist' -ActualMicroUsd 1 -Evidence @{} }) 'State/CompleteUnknown'
    Assert-ApiPoolEqual 'RESERVATION_NOT_FOUND' (Get-BudgetErrCode { Undo-ApiPoolReservation -StateRoot $r -ReservationId 'rsv-doesnotexist' -Reason 'x' }) 'State/UndoUnknown'
    Assert-ApiPoolEqual 'RESERVATION_NOT_FOUND' (Get-BudgetErrCode { Set-ApiPoolReservationUnreconciled -StateRoot $r -ReservationId 'rsv-doesnotexist' -Reason 'x' }) 'State/UnreconciledUnknown'
    Assert-ApiPoolEqual 'RESERVATION_NOT_FOUND' (Get-BudgetErrCode { Resolve-ApiPoolOrphanReservation -StateRoot $r -ReservationId 'rsv-doesnotexist' -ActualMicroUsd 1 -Evidence @{} -Reason 'x' }) 'State/ResolveUnknown'
    $s1 = New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 100 -PerJobLimitMicroUsd 5000
    Assert-ApiPoolEqual 'REQUEST_INVALID' (Get-BudgetErrCode { Complete-ApiPoolReservation -StateRoot $r -ReservationId $s1.ReservationId -ActualMicroUsd -1 -Evidence @{} }) 'State/NegativeActualRefused'
    Assert-ApiPoolEqual 'REQUEST_INVALID' (Get-BudgetErrCode { Undo-ApiPoolReservation -StateRoot $r -ReservationId $s1.ReservationId -Reason ' ' }) 'State/UndoBlankReasonRefused'
    Assert-ApiPoolEqual 'REQUEST_INVALID' (Get-BudgetErrCode { Resolve-ApiPoolOrphanReservation -StateRoot $r -ReservationId $s1.ReservationId -ActualMicroUsd 1 -Evidence @{} -Reason ' ' }) 'State/ResolveBlankReasonRefused'
    Assert-ApiPoolThrows { Resolve-ApiPoolOrphanReservation -StateRoot $r -ReservationId $s1.ReservationId -ActualMicroUsd 1 -Evidence @{} -Reason '' } 'State/ResolveEmptyReasonRefused'
    Assert-ApiPoolEqual 100 (Get-ApiPoolBudgetStatus -StateRoot $r).ReservedMicroUsd 'State/RefusalsLeaveReservationOpen'
    [void](Complete-ApiPoolReservation -StateRoot $r -ReservationId $s1.ReservationId -ActualMicroUsd 50 -Evidence @{ requestId = 'r'; messageId = 'm'; usage = @{} })
    Assert-ApiPoolEqual 'RESERVATION_STATE_INVALID' (Get-BudgetErrCode { Complete-ApiPoolReservation -StateRoot $r -ReservationId $s1.ReservationId -ActualMicroUsd 50 -Evidence @{} }) 'State/DoubleCommitRefused'
    Assert-ApiPoolEqual 'RESERVATION_STATE_INVALID' (Get-BudgetErrCode { Undo-ApiPoolReservation -StateRoot $r -ReservationId $s1.ReservationId -Reason 'x' }) 'State/UndoAfterCommitRefused'
    Assert-ApiPoolEqual 'RESERVATION_STATE_INVALID' (Get-BudgetErrCode { Resolve-ApiPoolOrphanReservation -StateRoot $r -ReservationId $s1.ReservationId -ActualMicroUsd 1 -Evidence @{} -Reason 'x' }) 'State/ResolveAfterCommitRefused'
    Assert-ApiPoolEqual 'RESERVATION_STATE_INVALID' (Get-BudgetErrCode { Set-ApiPoolReservationUnreconciled -StateRoot $r -ReservationId $s1.ReservationId -Reason 'x' }) 'State/UnreconciledAfterCommitRefused'
    Assert-ApiPoolEqual 50 (Get-ApiPoolBudgetStatus -StateRoot $r).CommittedMicroUsd 'State/DoubleCommitNotCounted'
    $s2 = New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'b' -AmountMicroUsd 100 -PerJobLimitMicroUsd 5000
    [void](Undo-ApiPoolReservation -StateRoot $r -ReservationId $s2.ReservationId -Reason 'not charged')
    Assert-ApiPoolEqual 'RESERVATION_STATE_INVALID' (Get-BudgetErrCode { Complete-ApiPoolReservation -StateRoot $r -ReservationId $s2.ReservationId -ActualMicroUsd 1 -Evidence @{} }) 'State/CommitAfterUndoRefused'
    Assert-ApiPoolEqual 'RESERVATION_STATE_INVALID' (Get-BudgetErrCode { Undo-ApiPoolReservation -StateRoot $r -ReservationId $s2.ReservationId -Reason 'again' }) 'State/DoubleUndoRefused'
    Assert-ApiPoolEqual 'RESERVATION_STATE_INVALID' (Get-BudgetErrCode { Resolve-ApiPoolOrphanReservation -StateRoot $r -ReservationId $s2.ReservationId -ActualMicroUsd 1 -Evidence @{} -Reason 'x' }) 'State/ResolveAfterUndoRefused'
    $s3 = New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'c' -AmountMicroUsd 100 -PerJobLimitMicroUsd 5000
    [void](Set-ApiPoolReservationUnreconciled -StateRoot $r -ReservationId $s3.ReservationId -Reason 'timeout')
    Assert-ApiPoolEqual 'RESERVATION_STATE_INVALID' (Get-BudgetErrCode { Complete-ApiPoolReservation -StateRoot $r -ReservationId $s3.ReservationId -ActualMicroUsd 1 -Evidence @{} }) 'State/CommitOnUnreconciledRefused'
    Assert-ApiPoolEqual 'RESERVATION_STATE_INVALID' (Get-BudgetErrCode { Undo-ApiPoolReservation -StateRoot $r -ReservationId $s3.ReservationId -Reason 'x' }) 'State/UndoOnUnreconciledRefused'
    Assert-ApiPoolEqual 'RESERVATION_STATE_INVALID' (Get-BudgetErrCode { Set-ApiPoolReservationUnreconciled -StateRoot $r -ReservationId $s3.ReservationId -Reason 'x' }) 'State/DoubleUnreconciledRefused'

    # ---------------- Crash between reserve and commit ----------------
    $r = New-BudgetFixture -Limit 1000
    $orphan = New-ApiPoolReservation -StateRoot $r -JobId 'job-crash' -AttemptId 'a1' -AmountMicroUsd 400 -PerJobLimitMicroUsd 1000
    # "Restart": nothing in memory survives; everything is re-read from the ledger.
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.ReservedMicroUsd -eq 400 -and $st.OpenReservations.Count -eq 1 -and $st.OpenReservations[0].ReservationId -ceq $orphan.ReservationId) 'Orphan/OpenReserveStillCounted'
    Assert-ApiPoolEqual 'BUDGET_EXHAUSTED_GLOBAL' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j2' -AttemptId 'a' -AmountMicroUsd 700 -PerJobLimitMicroUsd 1000 }) 'Orphan/CountedAgainstLimit'
    $fit = New-ApiPoolReservation -StateRoot $r -JobId 'j2' -AttemptId 'a' -AmountMicroUsd 600 -PerJobLimitMicroUsd 1000
    Assert-ApiPoolEqual 0 $fit.AvailableAfterMicroUsd 'Orphan/RemainderUsable'
    $resolved = Resolve-ApiPoolOrphanReservation -StateRoot $r -ReservationId $orphan.ReservationId -ActualMicroUsd 350 -Evidence @{ requestId = 'req_o'; messageId = 'msg_o'; usage = @{ input_tokens = 5; output_tokens = 6 } } -Reason 'owner crashed; console shows 350'
    Assert-ApiPoolTrue (-not $resolved.Overrun) 'Orphan/ResolveWithinReserved'
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.CommittedMicroUsd -eq 350 -and $st.ReservedMicroUsd -eq 600 -and $st.AvailableMicroUsd -eq 50) 'Orphan/ResolvedCountedAtActual'
    $resolveRec = @(Get-BudgetLedgerRecords -Root $r | Where-Object { $_.type -ceq 'RESOLVE' })[0]
    Assert-ApiPoolTrue ($resolveRec.data.reason -ceq 'owner crashed; console shows 350' -and $resolveRec.data.evidence.messageId -ceq 'msg_o') 'Orphan/ResolveReasonAndEvidenceRecorded'
    Assert-ApiPoolEqual 'RESERVATION_STATE_INVALID' (Get-BudgetErrCode { Resolve-ApiPoolOrphanReservation -StateRoot $r -ReservationId $orphan.ReservationId -ActualMicroUsd 1 -Evidence @{} -Reason 'again' }) 'Orphan/DoubleResolveRefused'

    # ---------------- Process restart persistence (fresh powershell.exe) ----------------
    $base = New-BudgetBaseLedger
    $r = $base.Root
    [void](Set-ApiPoolReservationUnreconciled -StateRoot $r -ReservationId $base.B -Reason 'timeout')
    $statusFile = Join-Path $budgetSandbox 'child-status.json'
    $argText = '-NoProfile -File "{0}" -ModulesDir "{1}" -StateRoot "{2}" -ResultPath "{3}" -StatusOnly' -f $budgetHelper, $script:ModulesRoot, $r, $statusFile
    $child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argText -PassThru -WindowStyle Hidden
    $childExited = $child.WaitForExit(60000)
    Assert-ApiPoolTrue $childExited 'Restart/ChildExitedOnItsOwn'
    if ($childExited) {
        Assert-ApiPoolEqual 0 $child.ExitCode 'Restart/ChildExitCodeZero'
        $mine = Get-ApiPoolBudgetStatus -StateRoot $r
        $theirs = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($statusFile))
        Assert-ApiPoolTrue ($theirs.State -ceq $mine.State -and $theirs.GlobalLimitMicroUsd -eq $mine.GlobalLimitMicroUsd -and $theirs.LastSeq -eq $mine.LastSeq) 'Restart/StateLimitAndSeqIdentical'
        Assert-ApiPoolTrue ($theirs.CommittedMicroUsd -eq $mine.CommittedMicroUsd -and $theirs.ReservedMicroUsd -eq $mine.ReservedMicroUsd -and $theirs.UnreconciledMicroUsd -eq $mine.UnreconciledMicroUsd -and $theirs.AvailableMicroUsd -eq $mine.AvailableMicroUsd) 'Restart/AmountsIdentical'
        Assert-ApiPoolTrue (@($theirs.OpenReservations).Count -eq 1 -and @($theirs.OpenReservations)[0].ReservationId -ceq $base.B -and @($theirs.OpenReservations)[0].State -ceq 'UNRECONCILED') 'Restart/OpenReservationsIdentical'
        Assert-ApiPoolEqual 90 $theirs.CommittedMicroUsd 'Restart/CommittedValue'
    }

    # ---------------- Corrupted journal ----------------
    $base = New-BudgetBaseLedger
    $r = $base.Root
    Assert-ApiPoolEqual 'OK' (Get-ApiPoolBudgetStatus -StateRoot $r).State 'Corrupt/BaseLedgerIsOk'
    Edit-BudgetLedgerText -Root $r -Old '"amount":100,' -New '"amount":101,'
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.State -ceq 'CORRUPT' -and $st.CorruptReason -match 'hash chain broken') 'Corrupt/FlippedByteChainBreak'
    $before = Get-BudgetFileBase64 -Path (Get-BudgetLedgerPath -Root $r)
    Assert-ApiPoolEqual 'LEDGER_CORRUPT' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5 }) 'Corrupt/ReserveRefusedOnChainBreak'
    Assert-ApiPoolEqual 'LEDGER_CORRUPT' (Get-BudgetErrCode { Complete-ApiPoolReservation -StateRoot $r -ReservationId $base.B -ActualMicroUsd 1 -Evidence @{} }) 'Corrupt/CompleteRefusedOnChainBreak'
    Assert-ApiPoolEqual 'LEDGER_CORRUPT' (Get-BudgetErrCode { Clear-ApiPoolEmergencyStop -StateRoot $r -Reason 'x' }) 'Corrupt/ClearRefusedOnCorruption'
    Assert-ApiPoolEqual 'LEDGER_CORRUPT' (Get-BudgetErrCode { Initialize-ApiPoolLedger -StateRoot $r -GlobalLimitMicroUsd 10000 }) 'Corrupt/InitRefusedOnCorruption'
    Assert-ApiPoolEqual $before (Get-BudgetFileBase64 -Path (Get-BudgetLedgerPath -Root $r)) 'Corrupt/RefusalsNeverAppend'
    Assert-ApiPoolEqual 'LEDGER_CORRUPT' (Get-BudgetErrCode { Repair-ApiPoolLedger -StateRoot $r -Reason 'try' }) 'Corrupt/RepairRefusesMidFileCorruption'
    Assert-ApiPoolEqual $before (Get-BudgetFileBase64 -Path (Get-BudgetLedgerPath -Root $r)) 'Corrupt/RepairRefusalLeavesFileUnchanged'
    Assert-ApiPoolTrue (-not [System.IO.Directory]::Exists((Join-Path (Join-Path $r 'budget') 'quarantine'))) 'Corrupt/RepairRefusalCreatesNoQuarantine'
    $stopOnCorrupt = Set-ApiPoolEmergencyStop -StateRoot $r -Reason 'stop despite corruption'
    Assert-ApiPoolTrue ($stopOnCorrupt.MarkerWritten -and -not $stopOnCorrupt.RecordAppended) 'Corrupt/EmergencyStopStillWritesMarkerOnly'
    Assert-ApiPoolEqual $before (Get-BudgetFileBase64 -Path (Get-BudgetLedgerPath -Root $r)) 'Corrupt/EmergencyStopDoesNotAppend'

    # Chain-valid but semantically broken ledgers (forged with correct hashes).
    $base = New-BudgetBaseLedger
    $head = Get-BudgetHead -Root $base.Root
    Add-BudgetRawText -Root $base.Root -Text ((New-BudgetForgedLine -Seq ($head.Seq + 2) -Prev $head.Hash -Type 'STOP' -Data ([ordered]@{ reason = 'x' })) + "`n")
    $st = Get-ApiPoolBudgetStatus -StateRoot $base.Root
    Assert-ApiPoolTrue ($st.State -ceq 'CORRUPT' -and $st.CorruptReason -match 'sequence gap') 'Corrupt/SeqGapWithValidHash'
    Assert-ApiPoolEqual 'LEDGER_CORRUPT' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $base.Root -JobId 'j' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5 }) 'Corrupt/ReserveRefusedOnSeqGap'

    $base = New-BudgetBaseLedger
    $head = Get-BudgetHead -Root $base.Root
    Add-BudgetRawText -Root $base.Root -Text ((New-BudgetForgedLine -Seq ($head.Seq + 1) -Prev $head.Hash -Type 'BOGUS' -Data ([ordered]@{ reason = 'x' })) + "`n")
    $st = Get-ApiPoolBudgetStatus -StateRoot $base.Root
    Assert-ApiPoolTrue ($st.State -ceq 'CORRUPT' -and $st.CorruptReason -match 'unknown record type') 'Corrupt/UnknownType'
    Assert-ApiPoolEqual 'LEDGER_CORRUPT' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $base.Root -JobId 'j' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5 }) 'Corrupt/ReserveRefusedOnUnknownType'
    Assert-ApiPoolEqual 'LEDGER_CORRUPT' (Get-BudgetErrCode { Repair-ApiPoolLedger -StateRoot $base.Root -Reason 'try' }) 'Corrupt/RepairRefusesUnknownType'

    $nonInit = New-BudgetRoot
    [void][System.IO.Directory]::CreateDirectory((Join-Path $nonInit 'budget'))
    $line = New-BudgetForgedLine -Seq 1 -Prev ('0' * 64) -Type 'RESERVE' -Data ([ordered]@{ id = 'rsv-aaaaaaaaaaaaaaaaaaaaaaaa'; jobId = 'j'; attemptId = 'a'; amount = 1; perJobLimit = 1 })
    [System.IO.File]::WriteAllText((Get-BudgetLedgerPath -Root $nonInit), ($line + "`n"), $budgetUtf8)
    $st = Get-ApiPoolBudgetStatus -StateRoot $nonInit
    Assert-ApiPoolTrue ($st.State -ceq 'CORRUPT' -and $st.CorruptReason -match 'first record is not INIT') 'Corrupt/NonInitFirstRecord'
    Assert-ApiPoolEqual 'LEDGER_CORRUPT' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $nonInit -JobId 'j' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5 }) 'Corrupt/ReserveRefusedOnNonInit'

    $emptyRoot = New-BudgetRoot
    [void][System.IO.Directory]::CreateDirectory((Join-Path $emptyRoot 'budget'))
    [System.IO.File]::WriteAllBytes((Get-BudgetLedgerPath -Root $emptyRoot), [byte[]]@())
    Assert-ApiPoolEqual 'CORRUPT' (Get-ApiPoolBudgetStatus -StateRoot $emptyRoot).State 'Corrupt/EmptyLedgerFile'
    Assert-ApiPoolEqual 'LEDGER_CORRUPT' (Get-BudgetErrCode { Repair-ApiPoolLedger -StateRoot $emptyRoot -Reason 'try' }) 'Corrupt/RepairRefusesEmptyLedger'

    $dup = New-BudgetBaseLedger
    $head = Get-BudgetHead -Root $dup.Root
    Add-BudgetRawText -Root $dup.Root -Text ((New-BudgetForgedLine -Seq ($head.Seq + 1) -Prev $head.Hash -Type 'RESERVE' -Data ([ordered]@{ id = $dup.A; jobId = 'j'; attemptId = 'a'; amount = 1; perJobLimit = 5 })) + "`n")
    Assert-ApiPoolTrue ((Get-ApiPoolBudgetStatus -StateRoot $dup.Root).CorruptReason -match 'duplicate reservation id') 'Corrupt/DuplicateReserveId'

    $dc = New-BudgetBaseLedger
    $head = Get-BudgetHead -Root $dc.Root
    Add-BudgetRawText -Root $dc.Root -Text ((New-BudgetForgedLine -Seq ($head.Seq + 1) -Prev $head.Hash -Type 'COMMIT' -Data ([ordered]@{ id = $dc.A; actual = 1; evidence = $null })) + "`n")
    Assert-ApiPoolTrue ((Get-ApiPoolBudgetStatus -StateRoot $dc.Root).CorruptReason -match 'illegal COMMIT') 'Corrupt/DoubleCommitInJournal'

    $unk = New-BudgetBaseLedger
    $head = Get-BudgetHead -Root $unk.Root
    Add-BudgetRawText -Root $unk.Root -Text ((New-BudgetForgedLine -Seq ($head.Seq + 1) -Prev $head.Hash -Type 'UNDO' -Data ([ordered]@{ id = 'rsv-unknown'; reason = 'x' })) + "`n")
    Assert-ApiPoolTrue ((Get-ApiPoolBudgetStatus -StateRoot $unk.Root).CorruptReason -match 'unknown reservation') 'Corrupt/UndoUnknownInJournal'

    $rz = New-BudgetBaseLedger
    $head = Get-BudgetHead -Root $rz.Root
    Add-BudgetRawText -Root $rz.Root -Text ((New-BudgetForgedLine -Seq ($head.Seq + 1) -Prev $head.Hash -Type 'RESOLVE' -Data ([ordered]@{ id = $rz.A; actual = 1; evidence = $null; reason = 'x' })) + "`n")
    Assert-ApiPoolTrue ((Get-ApiPoolBudgetStatus -StateRoot $rz.Root).CorruptReason -match 'illegal RESOLVE') 'Corrupt/ResolveAfterCommitInJournal'

    $ri = New-BudgetBaseLedger
    $head = Get-BudgetHead -Root $ri.Root
    Add-BudgetRawText -Root $ri.Root -Text ((New-BudgetForgedLine -Seq ($head.Seq + 1) -Prev $head.Hash -Type 'INIT' -Data ([ordered]@{ globalLimitMicroUsd = 5 })) + "`n")
    Assert-ApiPoolTrue ((Get-ApiPoolBudgetStatus -StateRoot $ri.Root).CorruptReason -match 'INIT repeated') 'Corrupt/RepeatedInit'

    $bf = New-BudgetBaseLedger
    $head = Get-BudgetHead -Root $bf.Root
    Add-BudgetRawText -Root $bf.Root -Text ((New-BudgetForgedLine -Seq ($head.Seq + 1) -Prev $head.Hash -Type 'RESERVE' -Data ([ordered]@{ id = 'rsv-bbbbbbbbbbbbbbbbbbbbbbbb'; jobId = 'j'; attemptId = 'a'; amount = -5; perJobLimit = 5 })) + "`n")
    Assert-ApiPoolEqual 'CORRUPT' (Get-ApiPoolBudgetStatus -StateRoot $bf.Root).State 'Corrupt/NegativeAmountInJournal'

    # Torn tail: unterminated partial line.
    $base = New-BudgetBaseLedger
    $r = $base.Root
    $ledgerPath = Get-BudgetLedgerPath -Root $r
    $cleanBase64 = Get-BudgetFileBase64 -Path $ledgerPath
    Add-BudgetRawText -Root $r -Text '{"data":{"actual":5,"id":"rsv-'
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.State -ceq 'CORRUPT' -and $st.CorruptReason -match 'torn') 'Torn/PartialLineWithoutNewlineIsCorrupt'
    Assert-ApiPoolEqual 'LEDGER_CORRUPT' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5 }) 'Torn/ReserveRefused'
    $tornBytes = [System.IO.File]::ReadAllBytes($ledgerPath)
    Assert-ApiPoolThrows { Repair-ApiPoolLedger -StateRoot $r -Reason '' } 'Torn/RepairRequiresReason'
    $rep = Repair-ApiPoolLedger -StateRoot $r -Reason 'torn write after power loss'
    Assert-ApiPoolTrue ($rep.Repaired -and $rep.TruncatedBytes -eq ($tornBytes.Length - ([System.Convert]::FromBase64String($cleanBase64)).Length)) 'Torn/RepairTruncatedExactlyTheTail'
    Assert-ApiPoolTrue ([System.IO.File]::Exists($rep.QuarantinePath)) 'Torn/QuarantineCopyExists'
    Assert-ApiPoolEqual ([System.Convert]::ToBase64String($tornBytes)) (Get-BudgetFileBase64 -Path $rep.QuarantinePath) 'Torn/QuarantineHoldsPreRepairBytes'
    Assert-ApiPoolTrue ($rep.QuarantinePath -like (Join-Path (Join-Path $r 'budget') 'quarantine') + '\ledger-*.jsonl') 'Torn/QuarantinePathUnderBudgetQuarantine'
    $records = @(Get-BudgetLedgerRecords -Root $r)
    $lastRec = $records[$records.Count - 1]
    Assert-ApiPoolTrue ($lastRec.type -ceq 'REPAIR' -and $lastRec.data.reason -ceq 'torn write after power loss' -and $lastRec.data.quarantinePath -ceq $rep.QuarantinePath -and $lastRec.seq -eq 5) 'Torn/RepairRecordAppended'
    $st = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolTrue ($st.State -ceq 'OK' -and $st.CommittedMicroUsd -eq 90 -and $st.ReservedMicroUsd -eq 200) 'Torn/AccountingPreservedAfterRepair'
    $after = New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 10 -PerJobLimitMicroUsd 50
    Assert-ApiPoolTrue ($null -ne $after) 'Torn/ReserveWorksAfterRepair'
    $noop = Repair-ApiPoolLedger -StateRoot $r -Reason 'nothing to do'
    Assert-ApiPoolTrue (-not $noop.Repaired) 'Torn/RepairOnHealthyLedgerIsNoop'
    Assert-ApiPoolEqual 6 (Get-ApiPoolBudgetStatus -StateRoot $r).LastSeq 'Torn/NoopWritesNothing'

    # Torn tail: complete-looking but unparseable last line terminated by newline, and a cut multibyte character.
    $base = New-BudgetBaseLedger
    $r = $base.Root
    Add-BudgetRawText -Root $r -Text ('{"seq":5,"ts":"20' + "`n")
    Assert-ApiPoolEqual 'CORRUPT' (Get-ApiPoolBudgetStatus -StateRoot $r).State 'Torn/InvalidJsonLastLineIsCorrupt'
    $rep2 = Repair-ApiPoolLedger -StateRoot $r -Reason 'garbled last line'
    Assert-ApiPoolTrue ($rep2.Repaired -and (Get-ApiPoolBudgetStatus -StateRoot $r).State -ceq 'OK') 'Torn/InvalidJsonLastLineRepaired'
    $base = New-BudgetBaseLedger
    $r = $base.Root
    $fs = New-Object System.IO.FileStream((Get-BudgetLedgerPath -Root $r), [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try { $fs.WriteByte(0xD0); $fs.Flush($true) } finally { $fs.Dispose() }
    Assert-ApiPoolEqual 'CORRUPT' (Get-ApiPoolBudgetStatus -StateRoot $r).State 'Torn/CutMultibyteTailIsCorrupt'
    $rep3 = Repair-ApiPoolLedger -StateRoot $r -Reason 'cut character'
    Assert-ApiPoolTrue ($rep3.Repaired -and $rep3.TruncatedBytes -eq 1 -and (Get-ApiPoolBudgetStatus -StateRoot $r).State -ceq 'OK') 'Torn/CutMultibyteTailRepaired'

    # Torn tail on top of mid-file corruption is NOT repairable.
    $base = New-BudgetBaseLedger
    $r = $base.Root
    Edit-BudgetLedgerText -Root $r -Old '"amount":100,' -New '"amount":101,'
    Add-BudgetRawText -Root $r -Text '{"partial'
    $both = Get-BudgetFileBase64 -Path (Get-BudgetLedgerPath -Root $r)
    Assert-ApiPoolEqual 'LEDGER_CORRUPT' (Get-BudgetErrCode { Repair-ApiPoolLedger -StateRoot $r -Reason 'try' }) 'Torn/RepairRefusesTornTailPlusMidFileCorruption'
    Assert-ApiPoolEqual $both (Get-BudgetFileBase64 -Path (Get-BudgetLedgerPath -Root $r)) 'Torn/RefusedRepairLeavesFileUnchanged'

    # Hash of a well-formed last line with a flipped byte is chain corruption, not a torn tail.
    $base = New-BudgetBaseLedger
    $r = $base.Root
    Edit-BudgetLedgerText -Root $r -Old '"actual":90,' -New '"actual":91,'
    Assert-ApiPoolEqual 'LEDGER_CORRUPT' (Get-BudgetErrCode { Repair-ApiPoolLedger -StateRoot $r -Reason 'try' }) 'Torn/LastLineHashMismatchIsNotRepairable'

    # ---------------- Clock, redaction, lock timeout ----------------
    $r = New-BudgetFixture -Limit 1000
    $fixed = { [System.DateTime]::SpecifyKind([System.DateTime]'2030-01-02T03:04:05', [System.DateTimeKind]::Utc) }
    [void](New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5 -Clock $fixed)
    $recs = @(Get-BudgetLedgerRecords -Root $r)
    Assert-ApiPoolEqual '2030-01-02T03:04:05.0000000Z' $recs[$recs.Count - 1].ts 'Clock/InjectedClockUsedForTimestamp'

    $fakeKey = 'sk-' + 'ant-' + 'api03-' + 'LEDGERFAKEKEY1234'
    $rk = New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'b' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5
    [void](Undo-ApiPoolReservation -StateRoot $r -ReservationId $rk.ReservationId -Reason ('failed with ' + $fakeKey))
    [void](Set-ApiPoolEmergencyStop -StateRoot $r -Reason ('stop ' + $fakeKey))
    $ledgerText = [System.IO.File]::ReadAllText((Get-BudgetLedgerPath -Root $r))
    $markerText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $r 'budget') 'EMERGENCY_STOP'))
    Assert-ApiPoolTrue ((-not $ledgerText.Contains($fakeKey)) -and (-not $markerText.Contains($fakeKey))) 'Redaction/SecretsNeverPersisted'
    Assert-ApiPoolTrue ((Get-ApiPoolBudgetStatus -StateRoot $r).State -cne 'CORRUPT') 'Redaction/LedgerStillValidAfterRedactedWrites'
    [void](Clear-ApiPoolEmergencyStop -StateRoot $r -Reason 'ok')

    $r = New-BudgetFixture -Limit 1000
    $lockHandle = Enter-ApiPoolFileLock -Path (Join-Path (Join-Path $r 'budget') 'ledger.lock') -TimeoutMs 1000
    $sizeBefore = ([System.IO.FileInfo](Get-BudgetLedgerPath -Root $r)).Length
    try {
        Assert-ApiPoolEqual 'LEDGER_LOCK_TIMEOUT' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'j' -AttemptId 'a' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5 -LockTimeoutMs 150 }) 'Lock/ReserveTimesOutWhileHeld'
        Assert-ApiPoolEqual 'LEDGER_LOCK_TIMEOUT' (Get-BudgetErrCode { Get-ApiPoolBudgetStatus -StateRoot $r -LockTimeoutMs 150 }) 'Lock/StatusTakesTheLock'
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lockHandle
    }
    Assert-ApiPoolEqual $sizeBefore ([System.IO.FileInfo](Get-BudgetLedgerPath -Root $r)).Length 'Lock/TimedOutCallWroteNothing'
    Assert-ApiPoolEqual 'OK' (Get-ApiPoolBudgetStatus -StateRoot $r).State 'Lock/UsableAfterRelease'

    # ---------------- F1-1: overrun is recorded even when the stop marker cannot be written ----------------
    $r = New-BudgetFixture -Limit 10000
    $rsv = New-ApiPoolReservation -StateRoot $r -JobId 'mk' -AttemptId 'a1' -AmountMicroUsd 1000 -PerJobLimitMicroUsd 5000
    # A DIRECTORY at the marker path makes the atomic marker write throw.
    [void][System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $r 'budget') 'EMERGENCY_STOP'))
    $mkRes = $null
    try { $mkRes = Complete-ApiPoolReservation -StateRoot $r -ReservationId $rsv.ReservationId -ActualMicroUsd 1500 } catch { $mkRes = $null }
    $mkStatus = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolEqual 1500 $mkStatus.CommittedMicroUsd 'MarkerFailure/CompleteCountsActualSpend'
    Assert-ApiPoolEqual 'STOPPED' $mkStatus.State 'MarkerFailure/CompleteStatusStopped'
    Assert-ApiPoolTrue ($null -ne $mkRes -and $mkRes.Overrun -eq $true -and $mkRes.EmergencyStop -eq $true) 'MarkerFailure/CompleteReturnsOverrun'
    Assert-ApiPoolTrue ($null -ne $mkRes -and -not [string]::IsNullOrEmpty([string]$mkRes.MarkerError)) 'MarkerFailure/CompleteSurfacesMarkerError'
    Assert-ApiPoolEqual 'BUDGET_STOPPED' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'mk' -AttemptId 'a2' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5000 }) 'MarkerFailure/NextReserveRefused'
    $mkTypes = @(Get-BudgetLedgerRecords -Root $r | ForEach-Object { [string]$_.type })
    Assert-ApiPoolEqual 'INIT,RESERVE,COMMIT,OVERRUN,STOP' ($mkTypes -join ',') 'MarkerFailure/RecordOrderCommitOverrunStop'

    $r = New-BudgetFixture -Limit 10000
    $rsv = New-ApiPoolReservation -StateRoot $r -JobId 'mk' -AttemptId 'a1' -AmountMicroUsd 1000 -PerJobLimitMicroUsd 5000
    [void](Set-ApiPoolReservationUnreconciled -StateRoot $r -ReservationId $rsv.ReservationId -Reason 'test')
    [void][System.IO.Directory]::CreateDirectory((Join-Path (Join-Path $r 'budget') 'EMERGENCY_STOP'))
    $mkRes = $null
    try { $mkRes = Resolve-ApiPoolOrphanReservation -StateRoot $r -ReservationId $rsv.ReservationId -ActualMicroUsd 1500 -Reason 'test' } catch { $mkRes = $null }
    $mkStatus = Get-ApiPoolBudgetStatus -StateRoot $r
    Assert-ApiPoolEqual 1500 $mkStatus.CommittedMicroUsd 'MarkerFailure/ResolveCountsActualSpend'
    Assert-ApiPoolEqual 'STOPPED' $mkStatus.State 'MarkerFailure/ResolveStatusStopped'
    Assert-ApiPoolTrue ($null -ne $mkRes -and $mkRes.Overrun -eq $true -and -not [string]::IsNullOrEmpty([string]$mkRes.MarkerError)) 'MarkerFailure/ResolveReturnsOverrunAndMarkerError'
    Assert-ApiPoolEqual 'BUDGET_STOPPED' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'mk' -AttemptId 'a2' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5000 }) 'MarkerFailure/ResolveNextReserveRefused'

    # ---------------- F1-1: a crash right after an overrun COMMIT/RESOLVE still blocks spend (derived stop) ----------------
    foreach ($kind in @('Complete', 'Resolve')) {
        $r = New-BudgetFixture -Limit 10000
        $rsv = New-ApiPoolReservation -StateRoot $r -JobId 'dr' -AttemptId 'a1' -AmountMicroUsd 1000 -PerJobLimitMicroUsd 5000
        if ($kind -ceq 'Complete') {
            [void](Complete-ApiPoolReservation -StateRoot $r -ReservationId $rsv.ReservationId -ActualMicroUsd 1500)
            $keep = 3
        }
        else {
            [void](Resolve-ApiPoolOrphanReservation -StateRoot $r -ReservationId $rsv.ReservationId -ActualMicroUsd 1500 -Reason 'test')
            $keep = 3
        }
        $lines = @([System.IO.File]::ReadAllText((Get-BudgetLedgerPath -Root $r)).Split([char]10) | Where-Object { $_ -ne '' })
        Assert-ApiPoolEqual 5 $lines.Count ('Derived/' + $kind + '/FullRunHasFiveRecords')
        [System.IO.File]::WriteAllText((Get-BudgetLedgerPath -Root $r), ((@($lines[0..($keep - 1)]) -join "`n") + "`n"), $budgetUtf8)
        $marker = Join-Path (Join-Path $r 'budget') 'EMERGENCY_STOP'
        if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
        $ds = Get-ApiPoolBudgetStatus -StateRoot $r
        Assert-ApiPoolEqual 'STOPPED' $ds.State ('Derived/' + $kind + '/TruncatedLedgerIsStopped')
        Assert-ApiPoolEqual 'derived' $ds.EmergencyStop.Source ('Derived/' + $kind + '/SourceDerived')
        Assert-ApiPoolEqual 1500 $ds.CommittedMicroUsd ('Derived/' + $kind + '/SpendCounted')
        Assert-ApiPoolEqual 'BUDGET_STOPPED' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'dr' -AttemptId 'a2' -AmountMicroUsd 1 -PerJobLimitMicroUsd 5000 }) ('Derived/' + $kind + '/ReserveRefused')
        [void](Clear-ApiPoolEmergencyStop -StateRoot $r -Reason 'operator reviewed')
        Assert-ApiPoolEqual 'OK' (Get-ApiPoolBudgetStatus -StateRoot $r).State ('Derived/' + $kind + '/ClearLiftsDerivedStop')
    }
    # A non-overrun commit never derives a stop.
    $r = New-BudgetFixture -Limit 10000
    $rsv = New-ApiPoolReservation -StateRoot $r -JobId 'nd' -AttemptId 'a1' -AmountMicroUsd 1000 -PerJobLimitMicroUsd 5000
    [void](Complete-ApiPoolReservation -StateRoot $r -ReservationId $rsv.ReservationId -ActualMicroUsd 1000)
    Assert-ApiPoolEqual 'OK' (Get-ApiPoolBudgetStatus -StateRoot $r).State 'Derived/ExactCommitDoesNotStop'

    # ---------------- F1-6: per-job limit is the minimum of every limit ever recorded for the job ----------------
    $r = New-BudgetFixture -Limit 5000000
    [void](New-ApiPoolReservation -StateRoot $r -JobId 'jl' -AttemptId 'a1' -AmountMicroUsd 600 -PerJobLimitMicroUsd 1000)
    Assert-ApiPoolEqual 'BUDGET_EXHAUSTED_JOB' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'jl' -AttemptId 'a2' -AmountMicroUsd 600 -PerJobLimitMicroUsd 1000000 }) 'JobLimitMin/LaterLargerLimitCannotRaiseCap'
    $second = New-ApiPoolReservation -StateRoot $r -JobId 'jl' -AttemptId 'a3' -AmountMicroUsd 400 -PerJobLimitMicroUsd 1000000
    Assert-ApiPoolTrue ($null -ne $second) 'JobLimitMin/FillsUpToRecordedCap'
    Assert-ApiPoolEqual 'BUDGET_EXHAUSTED_JOB' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'jl' -AttemptId 'a4' -AmountMicroUsd 1 -PerJobLimitMicroUsd 1000000 }) 'JobLimitMin/CapHoldsAtExactLimit'
    [void](New-ApiPoolReservation -StateRoot $r -JobId 'jm' -AttemptId 'a1' -AmountMicroUsd 600 -PerJobLimitMicroUsd 1000000)
    Assert-ApiPoolEqual 'BUDGET_EXHAUSTED_JOB' (Get-BudgetErrCode { New-ApiPoolReservation -StateRoot $r -JobId 'jm' -AttemptId 'a2' -AmountMicroUsd 600 -PerJobLimitMicroUsd 1000 }) 'JobLimitMin/CurrentSmallerLimitStillApplies'
    $other = New-ApiPoolReservation -StateRoot $r -JobId 'jo' -AttemptId 'a1' -AmountMicroUsd 900 -PerJobLimitMicroUsd 1000000
    Assert-ApiPoolTrue ($null -ne $other) 'JobLimitMin/OtherJobUnaffected'
}
finally {
    Remove-ApiPoolTestSandbox -Path $budgetSandbox
}
