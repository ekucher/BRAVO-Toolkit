# Jobs suite. Dot-sourced by Invoke-ApiPoolTests.ps1. Offline; fake transport and sandbox state roots only.

$jbSandbox = New-ApiPoolTestSandbox
try {
    $jbCatalog = Join-Path $script:ConfigRoot 'agents.json'
    $jbRegistry = Import-ApiPoolModelRegistry -Path (Join-Path $script:ConfigRoot 'models.json')
    $jbFakeKeyTail = 'JBFAKE1234567890'
    $jbFakeKey = 'sk-' + 'ant-' + 'api03-' + $jbFakeKeyTail

    function New-JbHandoffText {
        return "Analysis done.`n`nHANDOFF`nresult: done`nrole: api-scout`nreview_source: codex-security`nchanged: a.ps1`nmerge_gate: clear`nfindings: none`nnext: owner"
    }

    function New-JbOkResp {
        param([string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { $Text = New-JbHandoffText }
        $doc = [ordered]@{
            id = 'msg_jb1'; type = 'message'; role = 'assistant'; model = 'claude-sonnet-5-5'
            content = @(@{ type = 'text'; text = $Text }); stop_reason = 'end_turn'
            usage = [ordered]@{ input_tokens = 100; output_tokens = 50; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }
        }
        return @{ StatusCode = 200; Headers = @{ 'request-id' = 'req_jb' }; Body = (ConvertTo-Json -InputObject $doc -Compress -Depth 8) }
    }

    function New-JbErrResp {
        param([int]$Status, [string]$Type = 'invalid_request_error')
        return @{ StatusCode = $Status; Headers = @{}; Body = (ConvertTo-Json -InputObject ([ordered]@{ type = 'error'; error = [ordered]@{ type = $Type; message = 'nope' } }) -Compress -Depth 5) }
    }

    function New-JbEnv {
        param([object[]]$Responses, [long]$Limit = 60000000, [scriptblock]$OnSleep, [scriptblock]$Configure, [switch]$NoLedger)
        $root = Join-Path $jbSandbox ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $cfg = Read-ApiPoolConfig -Path (Join-Path $script:ConfigRoot 'apipool.defaults.json')
        $cfg.minRequestIntervalMs = 0
        if ($null -ne $Configure) { & $Configure $cfg }
        if (-not $NoLedger) { [void](Initialize-ApiPoolLedger -StateRoot $root -GlobalLimitMicroUsd $Limit) }
        $state = @{ Now = (New-Object System.DateTime(2030, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)) }
        $clock = { $state.Now }.GetNewClosure()
        $sleep = {
            param($Milliseconds)
            $state.Now = $state.Now.AddMilliseconds($Milliseconds)
            if ($null -ne $OnSleep) { & $OnSleep $Milliseconds }
        }.GetNewClosure()
        $transport = New-ApiPoolFakeTransport -Responses $Responses
        $ctx = New-ApiPoolContext -StateRoot $root -Config $cfg -Registry $jbRegistry -Transport $transport -CredentialProvider $null -Clock $clock -Sleep $sleep
        return [pscustomobject]@{ Root = $root; Context = $ctx; Transport = $transport; Config = $cfg }
    }

    function Submit-JbJob {
        param($Env, [string]$Key, [string]$Brief = 'Map the module.', [string]$ContextData = 'file contents', [string]$Role = 'api-scout')
        $a = @{ Context = $Env.Context; Role = $Role; Brief = $Brief; ContextData = $ContextData; CatalogPath = $jbCatalog }
        if (-not [string]::IsNullOrEmpty($Key)) { $a['IdempotencyKey'] = $Key }
        return (Submit-ApiPoolJob @a)
    }

    function Get-JbCalls { param($Env) return @(Get-ApiPoolFakeTransportCall -Transport $Env.Transport).Count }

    function Get-JbReserveCount {
        param($Env)
        $p = Join-Path (Join-Path $Env.Root 'budget') 'ledger.jsonl'
        if (-not [System.IO.File]::Exists($p)) { return 0 }
        return @([System.IO.File]::ReadAllText($p).Split([char]10) | Where-Object { $_ -match '"type":"RESERVE"' }).Count
    }

    function Set-JbJobState {
        param($Env, [string]$JobId, [string]$State)
        $p = Join-Path (Join-Path $Env.Root 'jobs') ($JobId + '.json')
        $doc = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($p))
        $doc.state = $State
        [System.IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $doc -Compress -Depth 12))
    }

    function Get-JbCode {
        param([scriptblock]$Block)
        try { $null = & $Block; return $null } catch { return (Get-ApiPoolErrorCode -ErrorRecord $_) }
    }

    # ---------------------------------------------------------------- happy path
    $e1 = New-JbEnv -Responses @((New-JbOkResp))
    $j1 = Submit-JbJob -Env $e1 -Key 'happy'
    Assert-ApiPoolTrue -Condition ($j1.jobId -cmatch '^job-[0-9a-f]{24}$') -Name 'Submit/JobIdFormat'
    Assert-ApiPoolEqual -Expected ('job-' + (Get-ApiPoolSha256Hex -Text "api-scout`nhappy").Substring(0, 24)) -Actual $j1.jobId -Name 'Submit/JobIdFromRoleAndKey'
    Assert-ApiPoolEqual -Expected 'queued' -Actual $j1.state -Name 'Submit/StateQueued'
    Assert-ApiPoolEqual -Expected 0 -Actual $j1.attempts -Name 'Submit/AttemptsZero'
    Assert-ApiPoolEqual -Expected 3 -Actual $j1.maxAttempts -Name 'Submit/MaxAttemptsThree'
    Assert-ApiPoolEqual -Expected $false -Actual $j1.Duplicate -Name 'Submit/NotDuplicate'
    Assert-ApiPoolEqual -Expected 64 -Actual ([string]$j1.payloadHash).Length -Name 'Submit/PayloadHashSha256'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-JbCalls -Env $e1) -Name 'Submit/NoTransportCall'
    Assert-ApiPoolEqual -Expected 'queued' -Actual (Get-ApiPoolJob -StateRoot $e1.Root -JobId $j1.jobId).state -Name 'Status/Queued'
    Assert-ApiPoolEqual -Expected 'queued' -Actual (Get-ApiPoolJobResult -StateRoot $e1.Root -JobId $j1.jobId).State -Name 'Result/QueuedHasState'
    Assert-ApiPoolEqual -Expected $null -Actual (Get-ApiPoolJobResult -StateRoot $e1.Root -JobId $j1.jobId).Result -Name 'Result/QueuedHasNoResult'

    $r1 = Invoke-ApiPoolJob -Context $e1.Context -JobId $j1.jobId -CatalogPath $jbCatalog
    Assert-ApiPoolEqual -Expected 'succeeded' -Actual $r1.state -Name 'Run/Succeeded'
    Assert-ApiPoolEqual -Expected 1 -Actual $r1.attempts -Name 'Run/AttemptsOne'
    Assert-ApiPoolEqual -Expected 700 -Actual $r1.result.costMicroUsd -Name 'Run/CostPersisted'
    Assert-ApiPoolEqual -Expected 'req_jb' -Actual $r1.result.requestId -Name 'Run/RequestIdPersisted'
    Assert-ApiPoolEqual -Expected 'msg_jb1' -Actual $r1.result.messageId -Name 'Run/MessageIdPersisted'
    Assert-ApiPoolEqual -Expected 'none' -Actual $r1.result.handoff.review_source -Name 'Run/ReviewSourceForced'
    Assert-ApiPoolEqual -Expected 'n/a' -Actual $r1.result.handoff.merge_gate -Name 'Run/MergeGateForced'
    Assert-ApiPoolEqual -Expected 'none' -Actual $r1.result.handoff.changed -Name 'Run/ChangedForced'
    Assert-ApiPoolEqual -Expected $true -Actual $r1.result.handoff.advisoryOnly -Name 'Run/AdvisoryOnly'
    Assert-ApiPoolEqual -Expected 'queued,running,succeeded' -Actual ((@($r1.history) | ForEach-Object { $_.state }) -join ',') -Name 'Run/HistoryStates'
    Assert-ApiPoolEqual -Expected 1 -Actual (Get-JbCalls -Env $e1) -Name 'Run/OneTransportCall'
    Assert-ApiPoolEqual -Expected 700 -Actual (Get-ApiPoolBudgetStatus -StateRoot $e1.Root).CommittedMicroUsd -Name 'Run/BudgetCommitted'
    $res1 = Get-ApiPoolJobResult -StateRoot $e1.Root -JobId $j1.jobId
    Assert-ApiPoolEqual -Expected 'succeeded' -Actual $res1.State -Name 'Result/State'
    Assert-ApiPoolTrue -Condition ($res1.Result.text.Contains('Analysis done.')) -Name 'Result/Text'
    Assert-ApiPoolEqual -Expected $null -Actual $res1.Error -Name 'Result/NoError'
    Assert-ApiPoolThrows { Invoke-ApiPoolJob -Context $e1.Context -JobId $j1.jobId -CatalogPath $jbCatalog } 'Run/TerminalRefused' -ExpectedCode 'JOB_TERMINAL'
    Assert-ApiPoolEqual -Expected 1 -Actual (Get-JbCalls -Env $e1) -Name 'Run/TerminalMadeNoCall'
    Assert-ApiPoolThrows { Stop-ApiPoolJob -StateRoot $e1.Root -JobId $j1.jobId } 'Stop/TerminalRefused' -ExpectedCode 'JOB_TERMINAL'
    Assert-ApiPoolThrows { Resume-ApiPoolJob -Context $e1.Context -JobId $j1.jobId -Reason 'again' } 'Resume/SucceededNotAllowed' -ExpectedCode 'RESUME_NOT_ALLOWED'
    Assert-ApiPoolTrue -Condition (-not [System.IO.File]::Exists((Join-Path (Join-Path $e1.Root 'jobs') ($j1.jobId + '.json.tmp')))) -Name 'Run/NoTempFilesLeft'

    # ---------------------------------------------------------------- idempotency
    $e2 = New-JbEnv -Responses @((New-JbOkResp))
    $a = Submit-JbJob -Env $e2 -Key 'same'
    $b = Submit-JbJob -Env $e2 -Key 'same'
    Assert-ApiPoolEqual -Expected $a.jobId -Actual $b.jobId -Name 'Idempotent/SameJobId'
    Assert-ApiPoolEqual -Expected $true -Actual $b.Duplicate -Name 'Idempotent/DuplicateFlag'
    [void](Invoke-ApiPoolJob -Context $e2.Context -JobId $a.jobId -CatalogPath $jbCatalog)
    $c = Submit-JbJob -Env $e2 -Key 'same'
    Assert-ApiPoolEqual -Expected 'succeeded' -Actual $c.state -Name 'Idempotent/DuplicateAfterRunIsSucceeded'
    Assert-ApiPoolEqual -Expected 1 -Actual (Get-JbReserveCount -Env $e2) -Name 'Idempotent/OneReservationOnly'
    Assert-ApiPoolEqual -Expected 1 -Actual (Get-JbCalls -Env $e2) -Name 'Idempotent/OneTransportCall'
    Assert-ApiPoolThrows { Submit-JbJob -Env $e2 -Key 'same' -Brief 'a different brief' } 'Idempotent/ConflictOnDifferentPayload' -ExpectedCode 'IDEMPOTENCY_CONFLICT'
    Assert-ApiPoolThrows { Submit-JbJob -Env $e2 -Key 'same' -ContextData 'other data' } 'Idempotent/ConflictOnDifferentContext' -ExpectedCode 'IDEMPOTENCY_CONFLICT'
    $other = Submit-JbJob -Env $e2 -Key 'same' -Role 'api-doc-reviewer'
    Assert-ApiPoolTrue -Condition ($other.jobId -cne $a.jobId) -Name 'Idempotent/RoleIsPartOfJobId'
    $n1 = Submit-JbJob -Env $e2
    $n2 = Submit-JbJob -Env $e2
    Assert-ApiPoolTrue -Condition ($n1.jobId -cne $n2.jobId -and -not $n2.Duplicate) -Name 'Idempotent/NoKeyMeansDistinctJobs'
    Assert-ApiPoolTrue -Condition ($n1.jobId -cmatch '^job-[0-9a-f]{24}$') -Name 'Idempotent/NoKeyJobIdFormat'

    # ---------------------------------------------------------------- validation
    Assert-ApiPoolThrows { Submit-JbJob -Env $e2 -Role 'api-nope' } 'Validate/UnknownRole' -ExpectedCode 'REQUEST_INVALID'
    Assert-ApiPoolThrows { Submit-JbJob -Env $e2 -Brief ('b' * 8001) } 'Validate/BriefTooLong' -ExpectedCode 'REQUEST_INVALID'
    Assert-ApiPoolThrows { Get-ApiPoolJob -StateRoot $e2.Root -JobId 'job-000000000000000000000000' } 'Validate/NotFound' -ExpectedCode 'JOB_NOT_FOUND'
    Assert-ApiPoolThrows { Get-ApiPoolJobResult -StateRoot $e2.Root -JobId 'job-000000000000000000000000' } 'Validate/ResultNotFound' -ExpectedCode 'JOB_NOT_FOUND'
    Assert-ApiPoolThrows { Get-ApiPoolJob -StateRoot $e2.Root -JobId '..\..\evil' } 'Validate/BadJobIdFormat' -ExpectedCode 'REQUEST_INVALID'
    Assert-ApiPoolThrows { Invoke-ApiPoolJob -Context $e2.Context -JobId 'job-000000000000000000000000' -CatalogPath $jbCatalog } 'Validate/RunNotFound' -ExpectedCode 'JOB_NOT_FOUND'
    $eNoTransport = New-JbEnv -Responses @()
    $eNoTransport.Context.Transport = $null
    $jn = Submit-JbJob -Env $eNoTransport
    Assert-ApiPoolThrows { Invoke-ApiPoolJob -Context $eNoTransport.Context -JobId $jn.jobId -CatalogPath $jbCatalog } 'Validate/RunWithoutTransportIsModeOffline' -ExpectedCode 'MODE_OFFLINE'
    Assert-ApiPoolEqual -Expected 'queued' -Actual (Get-ApiPoolJob -StateRoot $eNoTransport.Root -JobId $jn.jobId).state -Name 'Validate/ModeOfflineLeavesJobQueued'
    $corruptPath = Join-Path (Join-Path $e2.Root 'jobs') ('job-' + ('a' * 24) + '.json')
    [System.IO.File]::WriteAllText($corruptPath, '{not json')
    Assert-ApiPoolThrows { Get-ApiPoolJob -StateRoot $e2.Root -JobId ('job-' + ('a' * 24)) } 'Validate/CorruptJobFile' -ExpectedCode 'JOB_CORRUPT'

    # ---------------------------------------------------------------- JOB_BUSY
    $e3 = New-JbEnv -Responses @((New-JbOkResp))
    $j3 = Submit-JbJob -Env $e3
    $held = Enter-ApiPoolFileLock -Path (Join-Path (Join-Path $e3.Root 'jobs') ($j3.jobId + '.lock')) -TimeoutMs 1000
    try {
        Assert-ApiPoolThrows { Invoke-ApiPoolJob -Context $e3.Context -JobId $j3.jobId -CatalogPath $jbCatalog } 'Busy/LockHeldRefused' -ExpectedCode 'JOB_BUSY'
        Assert-ApiPoolEqual -Expected 0 -Actual (Get-JbCalls -Env $e3) -Name 'Busy/NoTransportCall'
        Assert-ApiPoolEqual -Expected 'queued' -Actual (Get-ApiPoolJob -StateRoot $e3.Root -JobId $j3.jobId).state -Name 'Busy/StateUnchanged'
        # Stop while a runner holds the lock: the cancel marker is written instead.
        $stopBusy = Stop-ApiPoolJob -StateRoot $e3.Root -JobId $j3.jobId -Reason 'busy'
        Assert-ApiPoolTrue -Condition ([System.IO.File]::Exists((Join-Path (Join-Path $e3.Root 'jobs') ($j3.jobId + '.cancel')))) -Name 'Busy/StopWritesCancelMarker'
        Assert-ApiPoolEqual -Expected 'queued' -Actual $stopBusy.state -Name 'Busy/StopDoesNotChangeState'
    }
    finally {
        Exit-ApiPoolFileLock -Handle $held
    }
    $r3 = Invoke-ApiPoolJob -Context $e3.Context -JobId $j3.jobId -CatalogPath $jbCatalog
    Assert-ApiPoolEqual -Expected 'cancelled' -Actual $r3.state -Name 'Busy/MarkerHonoredAtNextRun'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-JbCalls -Env $e3) -Name 'Busy/CancelledBeforeAnyCall'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-JbReserveCount -Env $e3) -Name 'Busy/CancelledBeforeAnyReservation'

    # ---------------------------------------------------------------- crash simulation + resume
    $e4 = New-JbEnv -Responses @((New-JbOkResp))
    $j4 = Submit-JbJob -Env $e4
    Set-JbJobState -Env $e4 -JobId $j4.jobId -State 'running'
    Assert-ApiPoolThrows { Invoke-ApiPoolJob -Context $e4.Context -JobId $j4.jobId -CatalogPath $jbCatalog } 'Crash/RunningWithoutLockRefused' -ExpectedCode 'JOB_INTERRUPTED'
    Assert-ApiPoolEqual -Expected 'interrupted' -Actual (Get-ApiPoolJob -StateRoot $e4.Root -JobId $j4.jobId).state -Name 'Crash/MarkedInterrupted'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-JbCalls -Env $e4) -Name 'Crash/NoTransportCall'
    Assert-ApiPoolThrows { Invoke-ApiPoolJob -Context $e4.Context -JobId $j4.jobId -CatalogPath $jbCatalog } 'Crash/InterruptedStillRefused' -ExpectedCode 'JOB_INTERRUPTED'
    Assert-ApiPoolThrows { Resume-ApiPoolJob -Context $e4.Context -JobId $j4.jobId -Reason '   ' } 'Resume/ReasonRequired' -ExpectedCode 'REQUEST_INVALID'
    $rs4 = Resume-ApiPoolJob -Context $e4.Context -JobId $j4.jobId -Reason 'operator checked the host'
    Assert-ApiPoolEqual -Expected 'queued' -Actual $rs4.state -Name 'Resume/BackToQueued'
    Assert-ApiPoolTrue -Condition (@($rs4.history)[-1].reason -like '*operator checked the host*') -Name 'Resume/ReasonInHistory'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-JbCalls -Env $e4) -Name 'Resume/DoesNotRun'
    $r4 = Invoke-ApiPoolJob -Context $e4.Context -JobId $j4.jobId -CatalogPath $jbCatalog
    Assert-ApiPoolEqual -Expected 'succeeded' -Actual $r4.state -Name 'Resume/ThenRunSucceeds'
    Assert-ApiPoolEqual -Expected 1 -Actual (Get-JbReserveCount -Env $e4) -Name 'Resume/NewReservationForNewRun'

    # RESUME_LIMIT and retryable resume (timeout x1 per run).
    $e5 = New-JbEnv -Responses @(@{ Kind = 'timeout' }, @{ Kind = 'timeout' }, @{ Kind = 'timeout' }) -Configure { param($c) $c.retry.maxAttempts = 1 }
    $j5 = Submit-JbJob -Env $e5
    $f5 = Invoke-ApiPoolJob -Context $e5.Context -JobId $j5.jobId -CatalogPath $jbCatalog
    Assert-ApiPoolEqual -Expected 'failed' -Actual $f5.state -Name 'Limit/FirstRunFailed'
    Assert-ApiPoolEqual -Expected 'RETRY_EXHAUSTED' -Actual $f5.error.code -Name 'Limit/ErrorCode'
    Assert-ApiPoolEqual -Expected $true -Actual $f5.error.retryable -Name 'Limit/TimeoutIsRetryable'
    [void](Resume-ApiPoolJob -Context $e5.Context -JobId $j5.jobId -Reason 'retry 1')
    $f5b = Invoke-ApiPoolJob -Context $e5.Context -JobId $j5.jobId -CatalogPath $jbCatalog
    Assert-ApiPoolEqual -Expected 2 -Actual $f5b.attempts -Name 'Limit/SecondAttemptCounted'
    [void](Resume-ApiPoolJob -Context $e5.Context -JobId $j5.jobId -Reason 'retry 2')
    $f5c = Invoke-ApiPoolJob -Context $e5.Context -JobId $j5.jobId -CatalogPath $jbCatalog
    Assert-ApiPoolEqual -Expected 3 -Actual $f5c.attempts -Name 'Limit/ThirdAttemptCounted'
    Assert-ApiPoolThrows { Resume-ApiPoolJob -Context $e5.Context -JobId $j5.jobId -Reason 'retry 3' } 'Limit/ResumeLimit' -ExpectedCode 'RESUME_LIMIT'
    Assert-ApiPoolEqual -Expected 'failed' -Actual (Get-ApiPoolJob -StateRoot $e5.Root -JobId $j5.jobId).state -Name 'Limit/StaysFailed'
    Assert-ApiPoolEqual -Expected 3 -Actual (Get-JbCalls -Env $e5) -Name 'Limit/ThreeFakeCalls'

    # ---------------------------------------------------------------- cancel
    $e6 = New-JbEnv -Responses @((New-JbOkResp))
    $j6 = Submit-JbJob -Env $e6
    $s6 = Stop-ApiPoolJob -StateRoot $e6.Root -JobId $j6.jobId -Reason 'not needed'
    Assert-ApiPoolEqual -Expected 'cancelled' -Actual $s6.state -Name 'Cancel/QueuedBecomesCancelled'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-JbCalls -Env $e6) -Name 'Cancel/NoTransportCall'
    Assert-ApiPoolThrows { Invoke-ApiPoolJob -Context $e6.Context -JobId $j6.jobId -CatalogPath $jbCatalog } 'Cancel/RunAfterCancelRefused' -ExpectedCode 'JOB_TERMINAL'
    Assert-ApiPoolThrows { Resume-ApiPoolJob -Context $e6.Context -JobId $j6.jobId -Reason 'x' } 'Cancel/ResumeCancelledRefused' -ExpectedCode 'RESUME_NOT_ALLOWED'
    Assert-ApiPoolThrows { Stop-ApiPoolJob -StateRoot $e6.Root -JobId $j6.jobId } 'Cancel/SecondCancelRefused' -ExpectedCode 'JOB_TERMINAL'

    # Cancel during a run: 429 first, the cancel marker appears while the adapter backs off.
    $holder = @{ Path = $null }
    $onSleep = { param($ms) if ($null -ne $holder.Path) { [System.IO.File]::WriteAllText($holder.Path, 'cancel') } }.GetNewClosure()
    $e7 = New-JbEnv -Responses @((New-JbErrResp -Status 429 -Type 'rate_limit_error'), (New-JbOkResp)) -OnSleep $onSleep
    $j7 = Submit-JbJob -Env $e7
    $holder.Path = Join-Path (Join-Path $e7.Root 'jobs') ($j7.jobId + '.cancel')
    $r7 = Invoke-ApiPoolJob -Context $e7.Context -JobId $j7.jobId -CatalogPath $jbCatalog
    Assert-ApiPoolEqual -Expected 'cancelled' -Actual $r7.state -Name 'CancelRunning/BecomesCancelled'
    Assert-ApiPoolEqual -Expected 1 -Actual (Get-JbCalls -Env $e7) -Name 'CancelRunning/StoppedAfterFirstCall'
    Assert-ApiPoolEqual -Expected $null -Actual $r7.result -Name 'CancelRunning/NoResult'

    # ---------------------------------------------------------------- failure mapping
    $e8 = New-JbEnv -Responses @((New-JbErrResp -Status 401 -Type 'authentication_error'))
    $f8 = Invoke-ApiPoolJob -Context $e8.Context -JobId (Submit-JbJob -Env $e8).jobId -CatalogPath $jbCatalog
    Assert-ApiPoolEqual -Expected 'failed' -Actual $f8.state -Name 'Failure/AuthFailed'
    Assert-ApiPoolEqual -Expected 'API_AUTH_FAILED' -Actual $f8.error.code -Name 'Failure/AuthCode'
    Assert-ApiPoolEqual -Expected $false -Actual $f8.error.retryable -Name 'Failure/AuthNotRetryable'
    Assert-ApiPoolThrows { Resume-ApiPoolJob -Context $e8.Context -JobId $f8.jobId -Reason 'x' } 'Failure/NonRetryableResumeRefused' -ExpectedCode 'RESUME_NOT_ALLOWED'
    $e9 = New-JbEnv -Responses @((New-JbErrResp -Status 400))
    $f9 = Invoke-ApiPoolJob -Context $e9.Context -JobId (Submit-JbJob -Env $e9).jobId -CatalogPath $jbCatalog
    Assert-ApiPoolEqual -Expected 'API_CLIENT_ERROR' -Actual $f9.error.code -Name 'Failure/ClientErrorCode'
    Assert-ApiPoolEqual -Expected $false -Actual $f9.error.retryable -Name 'Failure/ClientErrorNotRetryable'
    $e10 = New-JbEnv -Responses @(@{ Kind = 'timeout' }, @{ Kind = 'timeout' }, @{ Kind = 'timeout' }, @{ Kind = 'timeout' })
    $f10 = Invoke-ApiPoolJob -Context $e10.Context -JobId (Submit-JbJob -Env $e10).jobId -CatalogPath $jbCatalog
    Assert-ApiPoolEqual -Expected 'failed' -Actual $f10.state -Name 'Failure/TimeoutsFail'
    Assert-ApiPoolEqual -Expected 'RETRY_EXHAUSTED' -Actual $f10.error.code -Name 'Failure/TimeoutsExhausted'
    Assert-ApiPoolEqual -Expected $true -Actual $f10.error.retryable -Name 'Failure/TimeoutsRetryable'
    Assert-ApiPoolEqual -Expected 4 -Actual (Get-JbCalls -Env $e10) -Name 'Failure/FourAttemptsMade'
    $e11 = New-JbEnv -Responses @((New-JbOkResp)) -Limit 1000
    $f11 = Invoke-ApiPoolJob -Context $e11.Context -JobId (Submit-JbJob -Env $e11).jobId -CatalogPath $jbCatalog
    Assert-ApiPoolEqual -Expected 'BUDGET_EXHAUSTED_GLOBAL' -Actual $f11.error.code -Name 'Failure/BudgetExhausted'
    Assert-ApiPoolEqual -Expected $false -Actual $f11.error.retryable -Name 'Failure/BudgetExhaustedNotRetryable'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-JbCalls -Env $e11) -Name 'Failure/NoCallWithoutBudget'
    $e12 = New-JbEnv -Responses @((New-JbOkResp ('x ' + $jbFakeKey + "`nHANDOFF`nresult: done")))
    $f12 = Invoke-ApiPoolJob -Context $e12.Context -JobId (Submit-JbJob -Env $e12).jobId -CatalogPath $jbCatalog
    Assert-ApiPoolTrue -Condition (-not [System.IO.File]::ReadAllText((Join-Path (Join-Path $e12.Root 'jobs') ($f12.jobId + '.json'))).Contains($jbFakeKeyTail)) -Name 'Failure/SecretNotPersistedInJobFile'
    $e13 = New-JbEnv -Responses @((New-JbOkResp 'no handoff at all'))
    $f13 = Invoke-ApiPoolJob -Context $e13.Context -JobId (Submit-JbJob -Env $e13).jobId -CatalogPath $jbCatalog
    Assert-ApiPoolEqual -Expected 'succeeded' -Actual $f13.state -Name 'Failure/MalformedHandoffStillSucceeds'
    Assert-ApiPoolEqual -Expected 'HANDOFF_MALFORMED' -Actual $f13.result.handoff.next -Name 'Failure/MalformedHandoffFlagged'
    Assert-ApiPoolTrue -Condition (@($f13.result.warnings | Where-Object { $_ -like 'HANDOFF_MALFORMED*' }).Count -eq 1) -Name 'Failure/MalformedHandoffWarningPersisted'

    # ---------------------------------------------------------------- health
    $h1 = Get-ApiPoolHealth -Context $e1.Context
    Assert-ApiPoolEqual -Expected $true -Actual $h1.ok -Name 'Health/OkWhenInitialized'
    Assert-ApiPoolEqual -Expected 'offline' -Actual $h1.mode -Name 'Health/ModeOffline'
    Assert-ApiPoolEqual -Expected $false -Actual $h1.liveAvailable -Name 'Health/LiveNotAvailable'
    Assert-ApiPoolEqual -Expected 'Fake' -Actual $h1.transportKind -Name 'Health/TransportKind'
    Assert-ApiPoolEqual -Expected 'OK' -Actual $h1.budget.state -Name 'Health/BudgetOk'
    Assert-ApiPoolEqual -Expected $true -Actual $h1.stateRootWritable -Name 'Health/Writable'
    Assert-ApiPoolEqual -Expected 1 -Actual $h1.counts['succeeded'] -Name 'Health/CountsSucceeded'
    $hq = Get-ApiPoolHealth -Context $e4.Context
    Assert-ApiPoolEqual -Expected 1 -Actual $hq.counts['succeeded'] -Name 'Health/CountsOtherRoot'
    [void](Set-ApiPoolEmergencyStop -StateRoot $e1.Root -Reason 'health test')
    $h2 = Get-ApiPoolHealth -Context $e1.Context
    Assert-ApiPoolEqual -Expected $false -Actual $h2.ok -Name 'Health/NotOkWhenStopped'
    Assert-ApiPoolEqual -Expected 'STOPPED' -Actual $h2.budget.state -Name 'Health/BudgetStopped'
    Assert-ApiPoolTrue -Condition (@($h2.issues).Count -ge 1) -Name 'Health/StoppedHasIssue'
    $eCorrupt = New-JbEnv -Responses @()
    [System.IO.File]::AppendAllText((Join-Path (Join-Path $eCorrupt.Root 'budget') 'ledger.jsonl'), "{garbage`n")
    $h3 = Get-ApiPoolHealth -Context $eCorrupt.Context
    Assert-ApiPoolEqual -Expected $false -Actual $h3.ok -Name 'Health/NotOkWhenCorrupt'
    Assert-ApiPoolEqual -Expected 'CORRUPT' -Actual $h3.budget.state -Name 'Health/BudgetCorrupt'
    $eUninit = New-JbEnv -Responses @() -NoLedger
    $h4 = Get-ApiPoolHealth -Context $eUninit.Context
    Assert-ApiPoolEqual -Expected $false -Actual $h4.ok -Name 'Health/NotOkWhenUninitialized'
    Assert-ApiPoolEqual -Expected 'UNINITIALIZED' -Actual $h4.budget.state -Name 'Health/BudgetUninitialized'
    $eLive = New-JbEnv -Responses @()
    $eLive.Context.Config.mode = 'live'
    Assert-ApiPoolEqual -Expected $false -Actual (Get-ApiPoolHealth -Context $eLive.Context).ok -Name 'Health/NotOkWhenModeNotOffline'

    # ---------------------------------------------------------------- capabilities
    $cap = Get-ApiPoolCapability -CatalogPath $jbCatalog -RegistryPath (Join-Path $script:ConfigRoot 'models.json')
    Assert-ApiPoolEqual -Expected 'apipool.capabilities/1' -Actual $cap.schema -Name 'Capability/Schema'
    Assert-ApiPoolEqual -Expected 'offline' -Actual $cap.build -Name 'Capability/Build'
    Assert-ApiPoolEqual -Expected 'disabled-in-build' -Actual $cap.liveTransport -Name 'Capability/LiveTransport'
    Assert-ApiPoolEqual -Expected 6 -Actual @($cap.roles).Count -Name 'Capability/Roles'
    Assert-ApiPoolEqual -Expected 'name,model,maxTokens,description' -Actual (@($cap.roles[0].Keys) -join ',') -Name 'Capability/RoleShape'
    Assert-ApiPoolTrue -Condition (@($cap.models) -contains 'claude-sonnet-5-5' -and @($cap.models) -notcontains 'claude-haiku-5-5') -Name 'Capability/EnabledModelsOnly'
    Assert-ApiPoolEqual -Expected 'text-only' -Actual (@($cap.requestFeatures) -join ',') -Name 'Capability/TextOnly'
    Assert-ApiPoolEqual -Expected 'none (caller-driven)' -Actual $cap.scheduler -Name 'Capability/NoScheduler'
    $capJson = ConvertTo-Json -InputObject $cap -Compress -Depth 8
    Assert-ApiPoolTrue -Condition ($capJson -notmatch '"(tools?|tool_choice|mcp\w*)"\s*:') -Name 'Capability/NoToolsKey'
    Assert-ApiPoolTrue -Condition (@($cap.forbidden) -contains 'tools' -and @($cap.forbidden) -contains 'mcp_servers') -Name 'Capability/ForbiddenListed'

    # ---------------------------------------------------------------- process restart
    $e14 = New-JbEnv -Responses @((New-JbOkResp))
    $j14 = Submit-JbJob -Env $e14 -Key 'restart'
    [void](Invoke-ApiPoolJob -Context $e14.Context -JobId $j14.jobId -CatalogPath $jbCatalog)
    $helper = Join-Path (Join-Path $script:TestsRoot 'helpers') 'Invoke-ApiPoolJobWorker.ps1'
    $outPath = Join-Path $jbSandbox 'worker-out.json'
    $argText = '-NoProfile -File "{0}" -ModulesDir "{1}" -StateRoot "{2}" -JobId "{3}" -OutPath "{4}"' -f $helper, $script:ModulesRoot, $e14.Root, $j14.jobId, $outPath
    Assert-ApiPoolTrue -Condition (Test-ApiPoolTestPathInSandbox -Path $e14.Root) -Name 'Restart/StateRootInSandbox'
    $proc = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argText -PassThru -WindowStyle Hidden
    $exited = $proc.WaitForExit(60000)
    if (-not $exited) { try { $proc.Kill() } catch { $null = $_ } }
    Assert-ApiPoolTrue -Condition $exited -Name 'Restart/ChildExited'
    if ($exited) {
        Assert-ApiPoolEqual -Expected 0 -Actual $proc.ExitCode -Name 'Restart/ChildExitCodeZero'
        $wo = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($outPath))
        Assert-ApiPoolEqual -Expected 'succeeded' -Actual $wo.state -Name 'Restart/StatePersisted'
        Assert-ApiPoolEqual -Expected $j14.jobId -Actual $wo.jobId -Name 'Restart/JobIdReadable'
        Assert-ApiPoolEqual -Expected 700 -Actual $wo.costMicroUsd -Name 'Restart/ResultPersisted'
        Assert-ApiPoolEqual -Expected 'none' -Actual $wo.reviewSource -Name 'Restart/ForcedFieldPersisted'
    }

    # ---------------------------------------------------------------- F5 ARCH-002: job schemaVersion
    $e30 = New-JbEnv -Responses @((New-JbOkResp))
    $j30 = Submit-JbJob -Env $e30 -Key 'schema-v2'
    $j30Path = Join-Path (Join-Path $e30.Root 'jobs') ($j30.jobId + '.json')
    foreach ($badVersion in @('2', '0', '"1"', '1.5', 'null', 'true')) {
        $orig = [System.IO.File]::ReadAllText($j30Path)
        $mutated = [regex]::Replace($orig, '"schemaVersion":1', ('"schemaVersion":' + $badVersion))
        Assert-ApiPoolTrue -Condition ($mutated -cne $orig) -Name ('Schema/Fixture/' + $badVersion)
        [System.IO.File]::WriteAllText($j30Path, $mutated)
        $beforeBytes = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($j30Path))
        $callsBefore = Get-JbCalls -Env $e30
        Assert-ApiPoolThrows { Get-ApiPoolJob -StateRoot $e30.Root -JobId $j30.jobId } ('Schema/StatusRefused/' + $badVersion) -ExpectedCode 'JOB_SCHEMA_UNSUPPORTED'
        Assert-ApiPoolThrows { Get-ApiPoolJobResult -StateRoot $e30.Root -JobId $j30.jobId } ('Schema/ResultRefused/' + $badVersion) -ExpectedCode 'JOB_SCHEMA_UNSUPPORTED'
        Assert-ApiPoolThrows { Invoke-ApiPoolJob -Context $e30.Context -JobId $j30.jobId -CatalogPath $jbCatalog } ('Schema/RunRefused/' + $badVersion) -ExpectedCode 'JOB_SCHEMA_UNSUPPORTED'
        Assert-ApiPoolThrows { Stop-ApiPoolJob -StateRoot $e30.Root -JobId $j30.jobId } ('Schema/CancelRefused/' + $badVersion) -ExpectedCode 'JOB_SCHEMA_UNSUPPORTED'
        Assert-ApiPoolThrows { Resume-ApiPoolJob -Context $e30.Context -JobId $j30.jobId -Reason 'try' } ('Schema/ResumeRefused/' + $badVersion) -ExpectedCode 'JOB_SCHEMA_UNSUPPORTED'
        Assert-ApiPoolThrows { Submit-JbJob -Env $e30 -Key 'schema-v2' } ('Schema/ResubmitRefused/' + $badVersion) -ExpectedCode 'JOB_SCHEMA_UNSUPPORTED'
        Assert-ApiPoolEqual -Expected $beforeBytes -Actual ([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($j30Path))) -Name ('Schema/FileUntouched/' + $badVersion)
        Assert-ApiPoolEqual -Expected $callsBefore -Actual (Get-JbCalls -Env $e30) -Name ('Schema/NoTransportCall/' + $badVersion)
        Assert-ApiPoolEqual -Expected 0 -Actual (Get-JbReserveCount -Env $e30) -Name ('Schema/NoReservation/' + $badVersion)
        [System.IO.File]::WriteAllText($j30Path, $orig)
    }
    $schemaCaught = $null
    [System.IO.File]::WriteAllText($j30Path, ([System.IO.File]::ReadAllText($j30Path) -replace '"schemaVersion":1', '"schemaVersion":2'))
    try { $null = Get-ApiPoolJob -StateRoot $e30.Root -JobId $j30.jobId } catch { $schemaCaught = $_ }
    Assert-ApiPoolTrue -Condition ($null -ne $schemaCaught -and $schemaCaught.TargetObject.Retryable -eq $false) -Name 'Schema/NotRetryable'
    [System.IO.File]::WriteAllText($j30Path, ([System.IO.File]::ReadAllText($j30Path) -replace '"schemaVersion":2', '"schemaVersion":1'))
    Assert-ApiPoolEqual -Expected 'queued' -Actual (Get-ApiPoolJob -StateRoot $e30.Root -JobId $j30.jobId).state -Name 'Schema/Version1StillReadable'
    # A missing schemaVersion stays JOB_CORRUPT (not "unsupported").
    [System.IO.File]::WriteAllText($j30Path, ([System.IO.File]::ReadAllText($j30Path) -replace '"schemaVersion":1,', ''))
    Assert-ApiPoolThrows { Get-ApiPoolJob -StateRoot $e30.Root -JobId $j30.jobId } 'Schema/MissingStaysCorrupt' -ExpectedCode 'JOB_CORRUPT'

    # ---------------------------------------------------------------- F5 SEC-001: job id and jobs directory
    foreach ($badId in @('..\..\evil', 'job-../../../x', 'job-AAAAAAAAAAAAAAAAAAAAAAAA', 'job-0123456789abcdef0123456', 'job-0123456789abcdef012345678', 'job-0123456789abcdef01234567.json')) {
        Assert-ApiPoolThrows { Get-ApiPoolJob -StateRoot $e30.Root -JobId $badId } ('JobId/StatusRefused/' + $badId) -ExpectedCode 'REQUEST_INVALID'
        Assert-ApiPoolThrows { Stop-ApiPoolJob -StateRoot $e30.Root -JobId $badId } ('JobId/CancelRefused/' + $badId) -ExpectedCode 'REQUEST_INVALID'
        Assert-ApiPoolThrows { Invoke-ApiPoolJob -Context $e30.Context -JobId $badId -CatalogPath $jbCatalog } ('JobId/RunRefused/' + $badId) -ExpectedCode 'REQUEST_INVALID'
        Assert-ApiPoolThrows { Resume-ApiPoolJob -Context $e30.Context -JobId $badId -Reason 'x' } ('JobId/ResumeRefused/' + $badId) -ExpectedCode 'REQUEST_INVALID'
    }
    $e31 = New-JbEnv -Responses @((New-JbOkResp))
    $jobsTarget = Join-Path $jbSandbox 'jobs-target'
    [void][System.IO.Directory]::CreateDirectory($jobsTarget)
    $jobsLink = Join-Path $e31.Root 'jobs'
    $null = & cmd.exe /c ('mklink /J "{0}" "{1}"' -f $jobsLink, $jobsTarget)
    Assert-ApiPoolTrue -Condition ([System.IO.Directory]::Exists($jobsLink)) -Name 'JobsJunction/FixtureCreated'
    try {
        Invoke-ApiPoolSandboxRefusal -Path $e31.Root -Name 'JobsJunction/SubmitRefused' -ScriptBlock { Submit-JbJob -Env $e31 -Key 'junction' }
        Invoke-ApiPoolSandboxRefusal -Path $e31.Root -Name 'JobsJunction/StatusRefused' -ScriptBlock { Get-ApiPoolJob -StateRoot $e31.Root -JobId ('job-' + ('a' * 24)) }
        Invoke-ApiPoolSandboxRefusal -Path $e31.Root -Name 'JobsJunction/CancelRefused' -ScriptBlock { Stop-ApiPoolJob -StateRoot $e31.Root -JobId ('job-' + ('a' * 24)) }
        Invoke-ApiPoolSandboxRefusal -Path $e31.Root -Name 'JobsJunction/RunRefused' -ScriptBlock { Invoke-ApiPoolJob -Context $e31.Context -JobId ('job-' + ('a' * 24)) -CatalogPath $jbCatalog }
        $healthJ = Get-ApiPoolHealth -Context $e31.Context
        Assert-ApiPoolTrue -Condition (@($healthJ.issues | Where-Object { $_ -like '*jobs*' }).Count -ge 1) -Name 'JobsJunction/HealthReportsUnsafeJobsDir'
        Assert-ApiPoolEqual -Expected 0 -Actual @(Get-ChildItem -LiteralPath $jobsTarget -Force).Count -Name 'JobsJunction/TargetStaysEmpty'
    }
    finally {
        if ([System.IO.Directory]::Exists($jobsLink)) { [System.IO.Directory]::Delete($jobsLink, $false) }
    }
}
finally {
    Remove-ApiPoolTestSandbox -Path $jbSandbox
}
