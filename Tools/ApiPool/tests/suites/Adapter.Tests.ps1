# Adapter suite. Dot-sourced by Invoke-ApiPoolTests.ps1. Offline; fake transport and sandbox state roots only.

$adpSandbox = New-ApiPoolTestSandbox
try {
    $adpConfigPath = Join-Path $script:ConfigRoot 'apipool.defaults.json'
    $adpRegistry = Import-ApiPoolModelRegistry -Path (Join-Path $script:ConfigRoot 'models.json')
    $adpSonnet = Get-ApiPoolModel -Registry $adpRegistry -Model 'claude-sonnet-5-5'
    $adpUtf8 = New-Object System.Text.UTF8Encoding($false)
    $adpProvider = New-ApiPoolCredentialProvider -Kind Dpapi -SecretPath (Join-Path $adpSandbox 'never-created.bin')
    $adpFakeKeyTail = 'ADPFAKE1234567890'
    $adpFakeKey = 'sk-' + 'ant-' + 'api03-' + $adpFakeKeyTail

    # Canonical body of the default request (keys sorted, no whitespace).
    $adpDefaultBody = '{"max_tokens":256,"messages":[{"content":"Hello","role":"user"}],"model":"claude-sonnet-5-5"}'

    function New-AdpRequest {
        return @{ model = 'claude-sonnet-5-5'; max_tokens = 256; messages = @(@{ role = 'user'; content = 'Hello' }) }
    }

    function New-AdpEnv {
        param(
            [object[]]$Responses,
            [scriptblock]$Configure,
            [long]$LimitMicroUsd = 60000000,
            [string]$Root,
            $State,
            [scriptblock]$OnSleep
        )

        $fresh = [string]::IsNullOrEmpty($Root)
        if ($fresh) { $Root = Join-Path $adpSandbox ([guid]::NewGuid().ToString('N').Substring(0, 8)) }
        $cfg = Read-ApiPoolConfig -Path $adpConfigPath
        $cfg.minRequestIntervalMs = 0
        if ($null -ne $Configure) { & $Configure $cfg }
        if ($fresh) { [void](Initialize-ApiPoolLedger -StateRoot $Root -GlobalLimitMicroUsd $LimitMicroUsd) }
        if ($null -eq $State) { $State = @{ Now = (New-Object System.DateTime(2030, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)) } }
        $sleeps = New-Object System.Collections.ArrayList
        $clock = { $State.Now }.GetNewClosure()
        $sleep = {
            param($Milliseconds)
            [void]$sleeps.Add([int]$Milliseconds)
            $State.Now = $State.Now.AddMilliseconds($Milliseconds)
            if ($null -ne $OnSleep) { & $OnSleep $Milliseconds }
        }.GetNewClosure()
        $transport = New-ApiPoolFakeTransport -Responses $Responses
        $ctx = New-ApiPoolContext -StateRoot $Root -Config $cfg -Registry $adpRegistry -Transport $transport -CredentialProvider $adpProvider -Clock $clock -Sleep $sleep
        return [pscustomobject]@{ Root = $Root; Context = $ctx; Transport = $transport; Sleeps = $sleeps; State = $State; Config = $cfg }
    }

    function New-AdpOkBody {
        param([hashtable]$Usage, [string]$Text = 'hello', [string]$Id = 'msg_test1')
        if ($null -eq $Usage) {
            $Usage = [ordered]@{ input_tokens = 100; output_tokens = 50; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }
        }
        $doc = [ordered]@{
            id = $Id; type = 'message'; role = 'assistant'; model = 'claude-sonnet-5-5'
            content = @(@{ type = 'text'; text = $Text }); stop_reason = 'end_turn'; usage = $Usage
        }
        return (ConvertTo-Json -InputObject $doc -Compress -Depth 8)
    }

    function New-AdpResp {
        param([int]$Status, [string]$Body = '', [hashtable]$Headers = @{})
        return @{ StatusCode = $Status; Headers = $Headers; Body = $Body }
    }

    function New-AdpErrorBody {
        param([string]$Message, [string]$Type = 'invalid_request_error')
        return (ConvertTo-Json -InputObject ([ordered]@{ type = 'error'; error = [ordered]@{ type = $Type; message = $Message } }) -Compress -Depth 5)
    }

    function Get-AdpOk { return (New-AdpResp -Status 200 -Body (New-AdpOkBody) -Headers @{ 'request-id' = 'req_abc' }) }

    function Get-AdpSleepTotal {
        param($Env)
        $total = 0
        foreach ($s in $Env.Sleeps) { $total += $s }
        return $total
    }

    function Get-AdpLedgerRecords {
        param([string]$Root)
        $text = [System.IO.File]::ReadAllText((Join-Path (Join-Path $Root 'budget') 'ledger.jsonl'))
        return @($text.Split([char]10) | Where-Object { $_ -ne '' } | ForEach-Object { ConvertFrom-Json -InputObject $_ })
    }

    function Get-AdpTypeCount {
        param([string]$Root, [string]$Type)
        return @(Get-AdpLedgerRecords -Root $Root | Where-Object { $_.type -ceq $Type }).Count
    }

    function Get-AdpReservationAmount {
        $bytes = $adpUtf8.GetByteCount($adpDefaultBody)
        return (Get-ApiPoolReservationCost -Model $adpSonnet -BodyBytes $bytes -MessageCount 1 -MaxTokens 256)
    }

    function Invoke-AdpMessage {
        param($Env, $Request, [string]$CancelPath, $PerJob)
        if ($null -eq $Request) { $Request = New-AdpRequest }
        if ($null -ne $PerJob) {
            return (Invoke-ApiPoolMessage -Context $Env.Context -JobId 'job-test' -Request $Request -CancelPath $CancelPath -PerJobLimitMicroUsd ([long]$PerJob))
        }
        return (Invoke-ApiPoolMessage -Context $Env.Context -JobId 'job-test' -Request $Request -CancelPath $CancelPath)
    }

    function Get-AdpErrorCode {
        param([scriptblock]$Block)
        try { $null = & $Block; return $null } catch { return (Get-ApiPoolErrorCode -ErrorRecord $_) }
    }

    function Test-AdpSlotsFree {
        param($Env)
        $free = $true
        for ($n = 1; $n -le [int]$Env.Config.maxConcurrency; $n++) {
            try {
                $h = Enter-ApiPoolFileLock -Path (Join-Path (Join-Path $Env.Root 'slots') ('slot-{0}.lock' -f $n)) -TimeoutMs 1 -TimeoutCode 'SLOT_TIMEOUT'
                Exit-ApiPoolFileLock -Handle $h
            }
            catch { $free = $false }
        }
        return $free
    }

    # ---------------------------------------------------------------- Get-ApiPoolRetryDelay
    $dCfg = Read-ApiPoolConfig -Path $adpConfigPath
    Assert-ApiPoolEqual -Expected 500 -Actual (Get-ApiPoolRetryDelay -Attempt 1 -RetryAfterSec $null -Config $dCfg) -Name 'Delay/Attempt1'
    Assert-ApiPoolEqual -Expected 1000 -Actual (Get-ApiPoolRetryDelay -Attempt 2 -RetryAfterSec $null -Config $dCfg) -Name 'Delay/Attempt2'
    Assert-ApiPoolEqual -Expected 4000 -Actual (Get-ApiPoolRetryDelay -Attempt 4 -RetryAfterSec $null -Config $dCfg) -Name 'Delay/Attempt4'
    Assert-ApiPoolEqual -Expected 16000 -Actual (Get-ApiPoolRetryDelay -Attempt 6 -RetryAfterSec $null -Config $dCfg) -Name 'Delay/Attempt6'
    Assert-ApiPoolEqual -Expected 20000 -Actual (Get-ApiPoolRetryDelay -Attempt 7 -RetryAfterSec $null -Config $dCfg) -Name 'Delay/CappedAtMaxDelay'
    Assert-ApiPoolEqual -Expected 20000 -Actual (Get-ApiPoolRetryDelay -Attempt 1000 -RetryAfterSec $null -Config $dCfg) -Name 'Delay/HugeAttemptDoesNotOverflow'
    Assert-ApiPoolEqual -Expected 2000 -Actual (Get-ApiPoolRetryDelay -Attempt 1 -RetryAfterSec 2 -Config $dCfg) -Name 'Delay/RetryAfterHonored'
    Assert-ApiPoolEqual -Expected 500 -Actual (Get-ApiPoolRetryDelay -Attempt 3 -RetryAfterSec 0.5 -Config $dCfg) -Name 'Delay/RetryAfterFraction'
    Assert-ApiPoolEqual -Expected 60000 -Actual (Get-ApiPoolRetryDelay -Attempt 1 -RetryAfterSec 3600 -Config $dCfg) -Name 'Delay/RetryAfterCappedByMaxRetryAfter'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-ApiPoolRetryDelay -Attempt 1 -RetryAfterSec 0 -Config $dCfg) -Name 'Delay/RetryAfterZero'
    Assert-ApiPoolEqual -Expected 500 -Actual (Get-ApiPoolRetryDelay -Attempt 1 -RetryAfterSec -5 -Config $dCfg) -Name 'Delay/NegativeRetryAfterIgnored'
    Assert-ApiPoolEqual -Expected 500 -Actual (Get-ApiPoolRetryDelay -Attempt 1 -RetryAfterSec ([double]::NaN) -Config $dCfg) -Name 'Delay/NaNRetryAfterIgnored'

    # ---------------------------------------------------------------- success path
    $env1 = New-AdpEnv -Responses @((Get-AdpOk))
    $res = Invoke-AdpMessage -Env $env1
    $expectedCost = Get-ApiPoolActualCost -Model $adpSonnet -Usage ([pscustomobject]@{ input_tokens = 100; output_tokens = 50; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 })
    Assert-ApiPoolTrue -Condition $res.Ok -Name 'Success/Ok' -Detail ([string]$res.Code + ' ' + [string]$res.Message)
    Assert-ApiPoolEqual -Expected 700 -Actual $expectedCost -Name 'Success/ExpectedCostSanity'
    Assert-ApiPoolEqual -Expected $expectedCost -Actual $res.CostMicroUsd -Name 'Success/CostEqualsActualCost'
    Assert-ApiPoolEqual -Expected 'hello' -Actual $res.Text -Name 'Success/Text'
    Assert-ApiPoolEqual -Expected 'end_turn' -Actual $res.StopReason -Name 'Success/StopReason'
    Assert-ApiPoolEqual -Expected 1 -Actual $res.Attempts -Name 'Success/Attempts'
    Assert-ApiPoolEqual -Expected 'req_abc' -Actual $res.RequestId -Name 'Success/RequestId'
    Assert-ApiPoolEqual -Expected 'msg_test1' -Actual $res.MessageId -Name 'Success/MessageId'
    Assert-ApiPoolEqual -Expected 1 -Actual @($res.ReservationIds).Count -Name 'Success/ReservationIds'
    Assert-ApiPoolEqual -Expected 100 -Actual $res.Usage['input_tokens'] -Name 'Success/UsageReturned'
    $st = Get-ApiPoolBudgetStatus -StateRoot $env1.Root
    Assert-ApiPoolEqual -Expected $expectedCost -Actual $st.CommittedMicroUsd -Name 'Success/BudgetCommitted'
    Assert-ApiPoolEqual -Expected 0 -Actual $st.ReservedMicroUsd -Name 'Success/BudgetReservedZero'
    Assert-ApiPoolEqual -Expected 0 -Actual $st.UnreconciledMicroUsd -Name 'Success/BudgetUnreconciledZero'
    Assert-ApiPoolEqual -Expected (60000000 - $expectedCost) -Actual $st.AvailableMicroUsd -Name 'Success/BudgetAvailable'
    $commit = @(Get-AdpLedgerRecords -Root $env1.Root | Where-Object { $_.type -ceq 'COMMIT' })
    Assert-ApiPoolEqual -Expected 1 -Actual $commit.Count -Name 'Success/OneCommitRecord'
    Assert-ApiPoolEqual -Expected 'req_abc' -Actual $commit[0].data.evidence.requestId -Name 'Success/EvidenceRequestId'
    Assert-ApiPoolEqual -Expected 'msg_test1' -Actual $commit[0].data.evidence.messageId -Name 'Success/EvidenceMessageId'
    Assert-ApiPoolEqual -Expected 50 -Actual $commit[0].data.evidence.usage.output_tokens -Name 'Success/EvidenceUsage'
    $calls = @(Get-ApiPoolFakeTransportCall -Transport $env1.Transport)
    Assert-ApiPoolEqual -Expected 1 -Actual $calls.Count -Name 'Success/OneTransportCall'
    Assert-ApiPoolEqual -Expected (Get-ApiPoolSha256Hex -Text $adpDefaultBody) -Actual $calls[0].BodySha256 -Name 'Success/CanonicalBodySent'
    Assert-ApiPoolEqual -Expected $adpUtf8.GetByteCount($adpDefaultBody) -Actual $calls[0].BodyBytes -Name 'Success/BodyBytes'
    Assert-ApiPoolEqual -Expected 120 -Actual $calls[0].TimeoutSec -Name 'Success/TimeoutFromConfig'
    Assert-ApiPoolTrue -Condition (Test-AdpSlotsFree -Env $env1) -Name 'Success/SlotReleased'
    Assert-ApiPoolEqual -Expected 0 -Actual $env1.Sleeps.Count -Name 'Success/NoSleep'

    # Default per-job limit comes from Config.perJobUsd (2 USD).
    $resv = @(Get-AdpLedgerRecords -Root $env1.Root | Where-Object { $_.type -ceq 'RESERVE' })
    Assert-ApiPoolEqual -Expected 2000000 -Actual $resv[0].data.perJobLimit -Name 'Success/PerJobLimitFromConfig'
    Assert-ApiPoolEqual -Expected (Get-AdpReservationAmount) -Actual $resv[0].data.amount -Name 'Success/ReservationFromBodyBytes'
    Assert-ApiPoolEqual -Expected '1' -Actual $resv[0].data.attemptId -Name 'Success/AttemptIdIsNumber'

    # system prompt, array content, multi-turn
    $envMulti = New-AdpEnv -Responses @((Get-AdpOk))
    $multiReq = @{
        model = 'claude-sonnet-5-5'; max_tokens = 100; system = 'Be brief.'
        messages = @(
            @{ role = 'user'; content = @(@{ type = 'text'; text = 'one' }, @{ type = 'text'; text = 'two' }) },
            @{ role = 'assistant'; content = 'ok' },
            @{ role = 'user'; content = 'three' }
        )
    }
    $resMulti = Invoke-AdpMessage -Env $envMulti -Request $multiReq
    Assert-ApiPoolTrue -Condition $resMulti.Ok -Name 'Multi/Ok' -Detail ([string]$resMulti.Code)
    $multiCalls = @(Get-ApiPoolFakeTransportCall -Transport $envMulti.Transport)
    $multiExpected = '{"max_tokens":100,"messages":[{"content":[{"text":"one","type":"text"},{"text":"two","type":"text"}],"role":"user"},{"content":"ok","role":"assistant"},{"content":"three","role":"user"}],"model":"claude-sonnet-5-5","system":"Be brief."}'
    Assert-ApiPoolEqual -Expected (Get-ApiPoolSha256Hex -Text $multiExpected) -Actual $multiCalls[0].BodySha256 -Name 'Multi/CanonicalBody'

    # ---------------------------------------------------------------- cache accounting
    $cacheUsage = [ordered]@{
        input_tokens = 1000; output_tokens = 200; cache_creation_input_tokens = 3000; cache_read_input_tokens = 5000
        cache_creation = [ordered]@{ ephemeral_5m_input_tokens = 1000; ephemeral_1h_input_tokens = 2000 }
    }
    $envCache = New-AdpEnv -Responses @((New-AdpResp -Status 200 -Body (New-AdpOkBody -Usage $cacheUsage) -Headers @{ 'request-id' = 'req_cache' }))
    # A larger max_tokens keeps the reservation bound above the cache-heavy actual cost.
    $cacheReq = New-AdpRequest
    $cacheReq['max_tokens'] = 4000
    $resCache = Invoke-AdpMessage -Env $envCache -Request $cacheReq
    # 1000*2 + 200*10 + 1000*2.5 + 2000*4 + 5000*0.2 = 15500
    Assert-ApiPoolTrue -Condition $resCache.Ok -Name 'Cache/Ok' -Detail ([string]$resCache.Code + ' ' + [string]$resCache.Message)
    Assert-ApiPoolEqual -Expected 15500 -Actual $resCache.CostMicroUsd -Name 'Cache/CostWithBreakdown'
    Assert-ApiPoolEqual -Expected 15500 -Actual (Get-ApiPoolBudgetStatus -StateRoot $envCache.Root).CommittedMicroUsd -Name 'Cache/Committed'
    $cacheCommit = @(Get-AdpLedgerRecords -Root $envCache.Root | Where-Object { $_.type -ceq 'COMMIT' })
    Assert-ApiPoolEqual -Expected 2000 -Actual $cacheCommit[0].data.evidence.usage.cache_creation.ephemeral_1h_input_tokens -Name 'Cache/EvidenceBreakdown'
    $envCache2 = New-AdpEnv -Responses @((New-AdpResp -Status 200 -Body (New-AdpOkBody -Usage ([ordered]@{ input_tokens = 0; output_tokens = 0; cache_creation_input_tokens = 1000; cache_read_input_tokens = 0 }))))
    $resCache2 = Invoke-AdpMessage -Env $envCache2 -Request $cacheReq
    Assert-ApiPoolEqual -Expected 4000 -Actual $resCache2.CostMicroUsd -Name 'Cache/NoBreakdownPricedAt1hRate'

    # ---------------------------------------------------------------- 429 / retry-after
    $env429 = New-AdpEnv -Responses @(
        (New-AdpResp -Status 429 -Body (New-AdpErrorBody -Message 'rate' -Type 'rate_limit_error') -Headers @{ 'retry-after' = '2' }),
        (Get-AdpOk))
    $res429 = Invoke-AdpMessage -Env $env429
    Assert-ApiPoolTrue -Condition $res429.Ok -Name 'RateLimit429/Ok' -Detail ([string]$res429.Code)
    Assert-ApiPoolEqual -Expected 2 -Actual $res429.Attempts -Name 'RateLimit429/TwoAttempts'
    Assert-ApiPoolEqual -Expected 2 -Actual @($res429.ReservationIds).Count -Name 'RateLimit429/TwoReservations'
    Assert-ApiPoolEqual -Expected 2000 -Actual (Get-AdpSleepTotal -Env $env429) -Name 'RateLimit429/DelayHonored'
    Assert-ApiPoolTrue -Condition (@($env429.Sleeps | Where-Object { $_ -gt 250 }).Count -eq 0) -Name 'RateLimit429/SleepChunksAtMost250'
    Assert-ApiPoolEqual -Expected 'INIT,RESERVE,UNDO,RESERVE,COMMIT' -Actual ((Get-AdpLedgerRecords -Root $env429.Root | ForEach-Object { $_.type }) -join ',') -Name 'RateLimit429/FirstReservationUndone'
    $st = Get-ApiPoolBudgetStatus -StateRoot $env429.Root
    Assert-ApiPoolEqual -Expected 0 -Actual $st.ReservedMicroUsd -Name 'RateLimit429/ReservedZero'
    Assert-ApiPoolEqual -Expected 700 -Actual $st.CommittedMicroUsd -Name 'RateLimit429/OnlySecondCharged'
    $rateFile = Join-Path (Join-Path $env429.Root 'ratelimit') 'claude-sonnet-5-5.json'
    Assert-ApiPoolTrue -Condition ([System.IO.File]::Exists($rateFile)) -Name 'RateLimit429/StateFileWritten'
    $rateDoc = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($rateFile))
    Assert-ApiPoolEqual -Expected '2030-01-01T00:00:02.0000000Z' -Actual ([string]$rateDoc.notBeforeUtc) -Name 'RateLimit429/NotBeforeFromRetryAfter'

    $envCap = New-AdpEnv -Responses @((New-AdpResp -Status 429 -Headers @{ 'Retry-After' = '3600' }), (Get-AdpOk))
    $resCap = Invoke-AdpMessage -Env $envCap
    Assert-ApiPoolTrue -Condition $resCap.Ok -Name 'RateLimit429Cap/Ok' -Detail ([string]$resCap.Code)
    Assert-ApiPoolEqual -Expected 60000 -Actual (Get-AdpSleepTotal -Env $envCap) -Name 'RateLimit429Cap/CappedByMaxRetryAfterSec'
    $capDoc = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Join-Path (Join-Path $envCap.Root 'ratelimit') 'claude-sonnet-5-5.json')))
    Assert-ApiPoolEqual -Expected '2030-01-01T00:01:00.0000000Z' -Actual ([string]$capDoc.notBeforeUtc) -Name 'RateLimit429Cap/NotBeforeCapped'

    $envNoRa = New-AdpEnv -Responses @((New-AdpResp -Status 429), (Get-AdpOk))
    $resNoRa = Invoke-AdpMessage -Env $envNoRa
    Assert-ApiPoolTrue -Condition $resNoRa.Ok -Name 'RateLimit429NoHeader/Ok' -Detail ([string]$resNoRa.Code)
    Assert-ApiPoolEqual -Expected 500 -Actual (Get-AdpSleepTotal -Env $envNoRa) -Name 'RateLimit429NoHeader/ExponentialBackoff'
    $noRaDoc = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Join-Path (Join-Path $envNoRa.Root 'ratelimit') 'claude-sonnet-5-5.json')))
    Assert-ApiPoolTrue -Condition ($null -eq $noRaDoc.notBeforeUtc) -Name 'RateLimit429NoHeader/NoNotBeforeWithoutHeader'

    # ---------------------------------------------------------------- 500 / 503 / 529 then success
    $env5xx = New-AdpEnv -Responses @(
        (New-AdpResp -Status 500 -Body (New-AdpErrorBody -Message 'oops' -Type 'api_error')),
        (New-AdpResp -Status 503 -Body (New-AdpErrorBody -Message 'unavailable' -Type 'api_error')),
        (New-AdpResp -Status 529 -Body (New-AdpErrorBody -Message 'busy' -Type 'overloaded_error')),
        (Get-AdpOk))
    $res5xx = Invoke-AdpMessage -Env $env5xx
    Assert-ApiPoolTrue -Condition $res5xx.Ok -Name 'Retry5xx/Ok' -Detail ([string]$res5xx.Code + ' ' + [string]$res5xx.Message)
    Assert-ApiPoolEqual -Expected 4 -Actual $res5xx.Attempts -Name 'Retry5xx/FourAttempts'
    Assert-ApiPoolEqual -Expected 3500 -Actual (Get-AdpSleepTotal -Env $env5xx) -Name 'Retry5xx/ExponentialBackoffSum'
    Assert-ApiPoolEqual -Expected 3 -Actual (Get-AdpTypeCount -Root $env5xx.Root -Type 'UNDO') -Name 'Retry5xx/ThreeUndone'
    $st = Get-ApiPoolBudgetStatus -StateRoot $env5xx.Root
    Assert-ApiPoolEqual -Expected 0 -Actual $st.ReservedMicroUsd -Name 'Retry5xx/ReservedZero'
    Assert-ApiPoolEqual -Expected 0 -Actual $st.UnreconciledMicroUsd -Name 'Retry5xx/UnreconciledZero'

    # ---------------------------------------------------------------- retries exhausted
    $envEx = New-AdpEnv -Responses @(1..4 | ForEach-Object { New-AdpResp -Status 500 -Body (New-AdpErrorBody -Message 'down' -Type 'api_error') })
    $resEx = Invoke-AdpMessage -Env $envEx
    Assert-ApiPoolEqual -Expected $false -Actual $resEx.Ok -Name 'Exhausted/NotOk'
    Assert-ApiPoolEqual -Expected 'RETRY_EXHAUSTED' -Actual $resEx.Code -Name 'Exhausted/Code'
    Assert-ApiPoolEqual -Expected 'API_SERVER_ERROR' -Actual $resEx.Details['lastCode'] -Name 'Exhausted/LastCode'
    Assert-ApiPoolEqual -Expected 4 -Actual $resEx.Attempts -Name 'Exhausted/Attempts'
    Assert-ApiPoolEqual -Expected 4 -Actual @($resEx.ReservationIds).Count -Name 'Exhausted/ReservationIds'
    Assert-ApiPoolEqual -Expected 4 -Actual (Get-AdpTypeCount -Root $envEx.Root -Type 'UNDO') -Name 'Exhausted/AllUndone'
    $st = Get-ApiPoolBudgetStatus -StateRoot $envEx.Root
    Assert-ApiPoolEqual -Expected 0 -Actual $st.ReservedMicroUsd -Name 'Exhausted/ReservedZero'
    Assert-ApiPoolEqual -Expected 0 -Actual $st.CommittedMicroUsd -Name 'Exhausted/NothingCommitted'
    Assert-ApiPoolEqual -Expected 3500 -Actual (Get-AdpSleepTotal -Env $envEx) -Name 'Exhausted/NoSleepAfterLastAttempt'
    Assert-ApiPoolTrue -Condition (Test-AdpSlotsFree -Env $envEx) -Name 'Exhausted/SlotReleased'

    $envEx429 = New-AdpEnv -Responses @(1..4 | ForEach-Object { New-AdpResp -Status 429 }) -Configure { param($c) $c.retry.maxAttempts = 3 }
    $resEx429 = Invoke-AdpMessage -Env $envEx429
    Assert-ApiPoolEqual -Expected 'RETRY_EXHAUSTED' -Actual $resEx429.Code -Name 'Exhausted429/Code'
    Assert-ApiPoolEqual -Expected 'RATE_LIMITED' -Actual $resEx429.Details['lastCode'] -Name 'Exhausted429/LastCode'
    Assert-ApiPoolEqual -Expected 3 -Actual $resEx429.Attempts -Name 'Exhausted429/HonorsMaxAttempts'
    Assert-ApiPoolEqual -Expected 3 -Actual @(Get-ApiPoolFakeTransportCall -Transport $envEx429.Transport).Count -Name 'Exhausted429/ThreeCalls'

    # overloaded exhaustion reports API_OVERLOADED
    $envOv = New-AdpEnv -Responses @(1..2 | ForEach-Object { New-AdpResp -Status 529 }) -Configure { param($c) $c.retry.maxAttempts = 2 }
    $resOv = Invoke-AdpMessage -Env $envOv
    Assert-ApiPoolEqual -Expected 'API_OVERLOADED' -Actual $resOv.Details['lastCode'] -Name 'Exhausted529/LastCode'

    # ---------------------------------------------------------------- non-retryable client errors
    $env400 = New-AdpEnv -Responses @((New-AdpResp -Status 400 -Body (New-AdpErrorBody -Message 'messages: bad shape')), (Get-AdpOk))
    $res400 = Invoke-AdpMessage -Env $env400
    Assert-ApiPoolEqual -Expected $false -Actual $res400.Ok -Name 'Client400/NotOk'
    Assert-ApiPoolEqual -Expected 'API_CLIENT_ERROR' -Actual $res400.Code -Name 'Client400/Code'
    Assert-ApiPoolEqual -Expected 1 -Actual $res400.Attempts -Name 'Client400/NoRetry'
    Assert-ApiPoolEqual -Expected 1 -Actual @(Get-ApiPoolFakeTransportCall -Transport $env400.Transport).Count -Name 'Client400/OneCall'
    Assert-ApiPoolTrue -Condition ($res400.Message.Contains('messages: bad shape')) -Name 'Client400/ErrorMessagePassedThrough'
    Assert-ApiPoolEqual -Expected 400 -Actual $res400.Details['status'] -Name 'Client400/StatusInDetails'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-ApiPoolBudgetStatus -StateRoot $env400.Root).ReservedMicroUsd -Name 'Client400/ReservationUndone'
    Assert-ApiPoolEqual -Expected 1 -Actual (Get-AdpTypeCount -Root $env400.Root -Type 'UNDO') -Name 'Client400/UndoRecorded'
    Assert-ApiPoolEqual -Expected 0 -Actual $env400.Sleeps.Count -Name 'Client400/NoBackoff'

    $env401 = New-AdpEnv -Responses @((New-AdpResp -Status 401 -Body (New-AdpErrorBody -Message 'invalid x-api-key' -Type 'authentication_error')), (Get-AdpOk))
    $res401 = Invoke-AdpMessage -Env $env401
    Assert-ApiPoolEqual -Expected 'API_AUTH_FAILED' -Actual $res401.Code -Name 'Auth401/Code'
    Assert-ApiPoolEqual -Expected 1 -Actual $res401.Attempts -Name 'Auth401/NoRetry'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-ApiPoolBudgetStatus -StateRoot $env401.Root).ReservedMicroUsd -Name 'Auth401/Undone'

    foreach ($case in @(@(403, 'API_AUTH_FAILED'), @(402, 'API_CLIENT_ERROR'), @(404, 'API_CLIENT_ERROR'), @(413, 'API_CLIENT_ERROR'), @(422, 'API_CLIENT_ERROR'))) {
        $envC = New-AdpEnv -Responses @((New-AdpResp -Status $case[0]), (Get-AdpOk))
        $resC = Invoke-AdpMessage -Env $envC
        Assert-ApiPoolEqual -Expected $case[1] -Actual $resC.Code -Name ('ClientStatus{0}/Code' -f $case[0])
        Assert-ApiPoolEqual -Expected 1 -Actual $resC.Attempts -Name ('ClientStatus{0}/NoRetry' -f $case[0])
        Assert-ApiPoolEqual -Expected 1 -Actual (Get-AdpTypeCount -Root $envC.Root -Type 'UNDO') -Name ('ClientStatus{0}/Undone' -f $case[0])
    }

    # unknown status: cannot prove not charged -> stays counted, no retry
    $env502 = New-AdpEnv -Responses @((New-AdpResp -Status 502 -Body 'bad gateway'), (Get-AdpOk))
    $res502 = Invoke-AdpMessage -Env $env502
    Assert-ApiPoolEqual -Expected 'RESPONSE_MALFORMED' -Actual $res502.Code -Name 'UnknownStatus/Code'
    Assert-ApiPoolEqual -Expected 502 -Actual $res502.Details['status'] -Name 'UnknownStatus/StatusDetail'
    Assert-ApiPoolEqual -Expected 1 -Actual $res502.Attempts -Name 'UnknownStatus/NoRetry'
    $st = Get-ApiPoolBudgetStatus -StateRoot $env502.Root
    Assert-ApiPoolEqual -Expected (Get-AdpReservationAmount) -Actual $st.UnreconciledMicroUsd -Name 'UnknownStatus/UnreconciledCounted'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-AdpTypeCount -Root $env502.Root -Type 'UNDO') -Name 'UnknownStatus/NotUndone'

    # ---------------------------------------------------------------- malformed 200 responses
    $okDoc = { param($mutate)
        $d = [ordered]@{ id = 'msg_x'; type = 'message'; role = 'assistant'; content = @(@{ type = 'text'; text = 'hi' }); stop_reason = 'end_turn'
            usage = [ordered]@{ input_tokens = 10; output_tokens = 5; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 } }
        & $mutate $d
        return (ConvertTo-Json -InputObject $d -Compress -Depth 8)
    }
    $malformed = [ordered]@{
        'NotJson'            = 'this is not json'
        'EmptyBody'          = ''
        'JsonArray'          = '[1,2,3]'
        'WrongType'          = (& $okDoc { param($d) $d['type'] = 'error' })
        'ContentNotArray'    = (& $okDoc { param($d) $d['content'] = 'plain string' })
        'ContentBlockNotText' = (& $okDoc { param($d) $d['content'] = @(@{ type = 'tool_use'; id = 'x' }) })
        'MissingStopReason'  = (& $okDoc { param($d) $d.Remove('stop_reason') })
        'MissingUsage'       = (& $okDoc { param($d) $d.Remove('usage') })
        'UsageMissingField'  = (& $okDoc { param($d) $d['usage'] = [ordered]@{ input_tokens = 10; output_tokens = 5 } })
        'NegativeUsage'      = (& $okDoc { param($d) $d['usage']['input_tokens'] = -1 })
        'NonIntegerUsage'    = (& $okDoc { param($d) $d['usage']['output_tokens'] = 1.5 })
        'StringUsage'        = (& $okDoc { param($d) $d['usage']['output_tokens'] = 'many' })
    }
    $amount = Get-AdpReservationAmount
    foreach ($name in $malformed.Keys) {
        $envM = New-AdpEnv -Responses @((New-AdpResp -Status 200 -Body $malformed[$name]), (Get-AdpOk))
        $resM = Invoke-AdpMessage -Env $envM
        Assert-ApiPoolEqual -Expected 'RESPONSE_MALFORMED' -Actual $resM.Code -Name ('Malformed/{0}/Code' -f $name)
        Assert-ApiPoolEqual -Expected $false -Actual $resM.Ok -Name ('Malformed/{0}/NotOk' -f $name)
        Assert-ApiPoolEqual -Expected 1 -Actual $resM.Attempts -Name ('Malformed/{0}/NoRetry' -f $name)
        $stM = Get-ApiPoolBudgetStatus -StateRoot $envM.Root
        Assert-ApiPoolEqual -Expected $amount -Actual $stM.UnreconciledMicroUsd -Name ('Malformed/{0}/UnreconciledCounted' -f $name)
        Assert-ApiPoolEqual -Expected 0 -Actual $stM.CommittedMicroUsd -Name ('Malformed/{0}/NothingCommitted' -f $name)
        Assert-ApiPoolEqual -Expected 0 -Actual $stM.ReservedMicroUsd -Name ('Malformed/{0}/ReservedZero' -f $name)
        Assert-ApiPoolEqual -Expected 1 -Actual (Get-AdpTypeCount -Root $envM.Root -Type 'UNRECONCILED') -Name ('Malformed/{0}/UnreconciledRecord' -f $name)
        Assert-ApiPoolEqual -Expected 0 -Actual (Get-AdpTypeCount -Root $envM.Root -Type 'UNDO') -Name ('Malformed/{0}/NotUndone' -f $name)
    }

    # ---------------------------------------------------------------- timeouts
    $envTo = New-AdpEnv -Responses @(@{ Kind = 'timeout' }, (Get-AdpOk))
    $resTo = Invoke-AdpMessage -Env $envTo
    Assert-ApiPoolTrue -Condition $resTo.Ok -Name 'Timeout/Ok' -Detail ([string]$resTo.Code)
    Assert-ApiPoolEqual -Expected 2 -Actual $resTo.Attempts -Name 'Timeout/Retried'
    Assert-ApiPoolEqual -Expected 'INIT,RESERVE,UNDO,RESERVE,COMMIT' -Actual ((Get-AdpLedgerRecords -Root $envTo.Root | ForEach-Object { $_.type }) -join ',') -Name 'Timeout/NotSentIsUndone'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-ApiPoolBudgetStatus -StateRoot $envTo.Root).UnreconciledMicroUsd -Name 'Timeout/NothingUnreconciled'
    Assert-ApiPoolEqual -Expected 500 -Actual (Get-AdpSleepTotal -Env $envTo) -Name 'Timeout/Backoff'

    $envTe = New-AdpEnv -Responses @(@{ Kind = 'transportError' }, (Get-AdpOk))
    $resTe = Invoke-AdpMessage -Env $envTe
    Assert-ApiPoolTrue -Condition $resTe.Ok -Name 'TransportError/Ok' -Detail ([string]$resTe.Code)
    Assert-ApiPoolEqual -Expected 1 -Actual (Get-AdpTypeCount -Root $envTe.Root -Type 'UNDO') -Name 'TransportError/Undone'

    $envTs = New-AdpEnv -Responses @(@{ Kind = 'timeoutAfterSend' }, (Get-AdpOk))
    $resTs = Invoke-AdpMessage -Env $envTs
    Assert-ApiPoolTrue -Condition $resTs.Ok -Name 'TimeoutAfterSend/Ok' -Detail ([string]$resTs.Code)
    Assert-ApiPoolEqual -Expected 2 -Actual $resTs.Attempts -Name 'TimeoutAfterSend/Retried'
    $st = Get-ApiPoolBudgetStatus -StateRoot $envTs.Root
    Assert-ApiPoolEqual -Expected (Get-AdpReservationAmount) -Actual $st.UnreconciledMicroUsd -Name 'TimeoutAfterSend/StaysCounted'
    Assert-ApiPoolEqual -Expected 700 -Actual $st.CommittedMicroUsd -Name 'TimeoutAfterSend/RetryCommitted'
    Assert-ApiPoolEqual -Expected 0 -Actual $st.ReservedMicroUsd -Name 'TimeoutAfterSend/ReservedZero'
    Assert-ApiPoolEqual -Expected 'INIT,RESERVE,UNRECONCILED,RESERVE,COMMIT' -Actual ((Get-AdpLedgerRecords -Root $envTs.Root | ForEach-Object { $_.type }) -join ',') -Name 'TimeoutAfterSend/LedgerSequence'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-AdpTypeCount -Root $envTs.Root -Type 'UNDO') -Name 'TimeoutAfterSend/NeverUndone'

    $envExh = New-AdpEnv -Responses @()
    $resExh = Invoke-AdpMessage -Env $envExh
    Assert-ApiPoolEqual -Expected 'RETRY_EXHAUSTED' -Actual $resExh.Code -Name 'ExhaustedQueue/Code'
    Assert-ApiPoolEqual -Expected 'TRANSPORT_ERROR' -Actual $resExh.Details['lastCode'] -Name 'ExhaustedQueue/LastCode'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-ApiPoolBudgetStatus -StateRoot $envExh.Root).ReservedMicroUsd -Name 'ExhaustedQueue/AllUndone'

    # ---------------------------------------------------------------- cancellation
    $cancelFile = Join-Path $adpSandbox 'cancel-before.flag'
    [System.IO.File]::WriteAllText($cancelFile, 'x')
    $envCb = New-AdpEnv -Responses @((Get-AdpOk))
    $resCb = Invoke-AdpMessage -Env $envCb -CancelPath $cancelFile
    Assert-ApiPoolEqual -Expected $false -Actual $resCb.Ok -Name 'CancelBefore/NotOk'
    Assert-ApiPoolEqual -Expected 'CANCELLED' -Actual $resCb.Code -Name 'CancelBefore/Code'
    Assert-ApiPoolEqual -Expected 0 -Actual @(Get-ApiPoolFakeTransportCall -Transport $envCb.Transport).Count -Name 'CancelBefore/NoTransportCall'
    Assert-ApiPoolEqual -Expected 0 -Actual @($resCb.ReservationIds).Count -Name 'CancelBefore/NoReservation'
    Assert-ApiPoolEqual -Expected 'INIT' -Actual ((Get-AdpLedgerRecords -Root $envCb.Root | ForEach-Object { $_.type }) -join ',') -Name 'CancelBefore/LedgerUntouched'
    Assert-ApiPoolEqual -Expected 0 -Actual $resCb.Attempts -Name 'CancelBefore/ZeroAttempts'

    $cancelDuring = Join-Path $adpSandbox 'cancel-during.flag'
    $envCd = New-AdpEnv -Responses @((New-AdpResp -Status 429), (Get-AdpOk)) -OnSleep { param($ms) [System.IO.File]::WriteAllText($cancelDuring, 'x') }
    $resCd = Invoke-AdpMessage -Env $envCd -CancelPath $cancelDuring
    Assert-ApiPoolEqual -Expected 'CANCELLED' -Actual $resCd.Code -Name 'CancelDuringBackoff/Code'
    Assert-ApiPoolEqual -Expected 1 -Actual @(Get-ApiPoolFakeTransportCall -Transport $envCd.Transport).Count -Name 'CancelDuringBackoff/NoSecondCall'
    Assert-ApiPoolEqual -Expected 1 -Actual $envCd.Sleeps.Count -Name 'CancelDuringBackoff/StoppedAfterFirstChunk'
    Assert-ApiPoolEqual -Expected 1 -Actual $resCd.Attempts -Name 'CancelDuringBackoff/OneAttempt'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-ApiPoolBudgetStatus -StateRoot $envCd.Root).ReservedMicroUsd -Name 'CancelDuringBackoff/NothingLeftReserved'
    Assert-ApiPoolEqual -Expected 'INIT,RESERVE,UNDO' -Actual ((Get-AdpLedgerRecords -Root $envCd.Root | ForEach-Object { $_.type }) -join ',') -Name 'CancelDuringBackoff/NoNewReservation'

    # ---------------------------------------------------------------- request refusal (before any reservation)
    $envRf = New-AdpEnv -Responses @((Get-AdpOk))
    $forbidden = [ordered]@{
        tools          = @(@{ name = 'x'; input_schema = @{ type = 'object' } })
        tool_choice    = @{ type = 'auto' }
        mcp_servers    = @(@{ name = 'srv' })
        stream         = $true
        thinking       = @{ type = 'enabled'; budget_tokens = 1024 }
        temperature    = 0.5
        top_p          = 0.9
        top_k          = 5
        metadata       = @{ user_id = 'u' }
        container      = 'c'
        output_config  = @{ format = 'json' }
        betas          = @('x')
        stop_sequences = @('x')
    }
    foreach ($key in $forbidden.Keys) {
        $req = New-AdpRequest
        $req[$key] = $forbidden[$key]
        $caught = $null
        try { $null = Invoke-AdpMessage -Env $envRf -Request $req } catch { $caught = $_ }
        Assert-ApiPoolEqual -Expected 'REQUEST_FORBIDDEN_FIELD' -Actual $(if ($null -ne $caught) { Get-ApiPoolErrorCode -ErrorRecord $caught } else { $null }) -Name ('Forbidden/{0}/Code' -f $key)
        Assert-ApiPoolTrue -Condition ($null -ne $caught -and $caught.Exception.Message.Contains("'$key'")) -Name ('Forbidden/{0}/NamesTheKey' -f $key)
    }
    $imageReq = New-AdpRequest
    $imageReq['messages'] = @(@{ role = 'user'; content = @(@{ type = 'image'; source = @{ type = 'base64' } }) })
    Assert-ApiPoolThrows { Invoke-AdpMessage -Env $envRf -Request $imageReq } 'Forbidden/NonTextBlock' -ExpectedCode 'REQUEST_FORBIDDEN_FIELD'
    $cacheCtlReq = New-AdpRequest
    $cacheCtlReq['messages'] = @(@{ role = 'user'; content = @(@{ type = 'text'; text = 'x'; cache_control = @{ type = 'ephemeral' } }) })
    Assert-ApiPoolThrows { Invoke-AdpMessage -Env $envRf -Request $cacheCtlReq } 'Forbidden/ExtraBlockKey' -ExpectedCode 'REQUEST_FORBIDDEN_FIELD'
    $msgKeyReq = New-AdpRequest
    $msgKeyReq['messages'] = @(@{ role = 'user'; content = 'x'; name = 'bob' })
    Assert-ApiPoolThrows { Invoke-AdpMessage -Env $envRf -Request $msgKeyReq } 'Forbidden/ExtraMessageKey' -ExpectedCode 'REQUEST_FORBIDDEN_FIELD'

    $invalidCases = [ordered]@{
        'EmptyContentString'  = { $r = New-AdpRequest; $r['messages'] = @(@{ role = 'user'; content = '' }); $r }
        'EmptyTextBlock'      = { $r = New-AdpRequest; $r['messages'] = @(@{ role = 'user'; content = @(@{ type = 'text'; text = '' }) }); $r }
        'EmptyMessages'       = { $r = New-AdpRequest; $r['messages'] = @(); $r }
        'FirstMessageAssistant' = { $r = New-AdpRequest; $r['messages'] = @(@{ role = 'assistant'; content = 'x' }); $r }
        'BadRole'             = { $r = New-AdpRequest; $r['messages'] = @(@{ role = 'system'; content = 'x' }); $r }
        'MaxTokensZero'       = { $r = New-AdpRequest; $r['max_tokens'] = 0; $r }
        'MaxTokensString'     = { $r = New-AdpRequest; $r['max_tokens'] = '256'; $r }
        'MaxTokensFraction'   = { $r = New-AdpRequest; $r['max_tokens'] = 10.5; $r }
        'MissingModel'        = { $r = New-AdpRequest; $r.Remove('model'); $r }
        'MissingMaxTokens'    = { $r = New-AdpRequest; $r.Remove('max_tokens'); $r }
        'MissingMessages'     = { $r = New-AdpRequest; $r.Remove('messages'); $r }
        'SystemNotString'     = { $r = New-AdpRequest; $r['system'] = @('x'); $r }
        'SystemEmpty'         = { $r = New-AdpRequest; $r['system'] = ''; $r }
        'MessagesNotArray'    = { $r = New-AdpRequest; $r['messages'] = 'hello'; $r }
        'RequestNotHashtable' = { 'just a string' }
    }
    foreach ($name in $invalidCases.Keys) {
        $badReq = & $invalidCases[$name]
        Assert-ApiPoolEqual -Expected 'REQUEST_INVALID' -Actual (Get-AdpErrorCode { Invoke-AdpMessage -Env $envRf -Request $badReq }) -Name ('Invalid/{0}' -f $name)
    }
    $tooBig = New-AdpRequest
    $tooBig['max_tokens'] = 128001
    Assert-ApiPoolThrows { Invoke-AdpMessage -Env $envRf -Request $tooBig } 'Invalid/MaxTokensExceedsModel' -ExpectedCode 'MAX_TOKENS_EXCEEDS_MODEL'
    $unknownModel = New-AdpRequest
    $unknownModel['model'] = 'claude-nonexistent-9'
    Assert-ApiPoolThrows { Invoke-AdpMessage -Env $envRf -Request $unknownModel } 'Pricing/UnknownModel' -ExpectedCode 'PRICING_UNKNOWN'
    $haiku = New-AdpRequest
    $haiku['model'] = 'claude-haiku-5-5'
    Assert-ApiPoolThrows { Invoke-AdpMessage -Env $envRf -Request $haiku } 'Pricing/DisabledHaiku' -ExpectedCode 'PRICING_UNKNOWN'
    Assert-ApiPoolThrows { Invoke-ApiPoolMessage -Context $envRf.Context -JobId '' -Request (New-AdpRequest) } 'Invalid/EmptyJobId'
    Assert-ApiPoolEqual -Expected 0 -Actual @(Get-ApiPoolFakeTransportCall -Transport $envRf.Transport).Count -Name 'Refusal/NoTransportCall'
    Assert-ApiPoolEqual -Expected 'INIT' -Actual ((Get-AdpLedgerRecords -Root $envRf.Root | ForEach-Object { $_.type }) -join ',') -Name 'Refusal/NoReservation'
    Assert-ApiPoolEqual -Expected 0 -Actual $envRf.Sleeps.Count -Name 'Refusal/NoSleep'

    $envBadT = New-AdpEnv -Responses @()
    $badCtx = New-ApiPoolContext -StateRoot $envBadT.Root -Config $envBadT.Config -Registry $adpRegistry -Transport ([pscustomobject]@{ Kind = 'Http' }) -CredentialProvider $null
    Assert-ApiPoolThrows { Invoke-ApiPoolMessage -Context $badCtx -JobId 'j' -Request (New-AdpRequest) } 'Refusal/UnsupportedTransportKind' -ExpectedCode 'INTERNAL_ERROR'
    Assert-ApiPoolEqual -Expected 'INIT' -Actual ((Get-AdpLedgerRecords -Root $envBadT.Root | ForEach-Object { $_.type }) -join ',') -Name 'Refusal/UnsupportedTransportNoReservation'

    # ---------------------------------------------------------------- budget refusals (returned, never thrown)
    $envBx = New-AdpEnv -Responses @((Get-AdpOk)) -LimitMicroUsd 100
    $resBx = Invoke-AdpMessage -Env $envBx
    Assert-ApiPoolEqual -Expected $false -Actual $resBx.Ok -Name 'BudgetExhausted/NotOk'
    Assert-ApiPoolEqual -Expected 'BUDGET_EXHAUSTED_GLOBAL' -Actual $resBx.Code -Name 'BudgetExhausted/Code'
    Assert-ApiPoolEqual -Expected 0 -Actual @(Get-ApiPoolFakeTransportCall -Transport $envBx.Transport).Count -Name 'BudgetExhausted/NoTransportCall'
    Assert-ApiPoolEqual -Expected 0 -Actual $resBx.Attempts -Name 'BudgetExhausted/ZeroAttempts'
    Assert-ApiPoolTrue -Condition (Test-AdpSlotsFree -Env $envBx) -Name 'BudgetExhausted/SlotReleased'

    $envSt = New-AdpEnv -Responses @((Get-AdpOk))
    [void](Set-ApiPoolEmergencyStop -StateRoot $envSt.Root -Reason 'test stop')
    $resSt = Invoke-AdpMessage -Env $envSt
    Assert-ApiPoolEqual -Expected 'BUDGET_STOPPED' -Actual $resSt.Code -Name 'EmergencyStop/Code'
    Assert-ApiPoolEqual -Expected $false -Actual $resSt.Ok -Name 'EmergencyStop/NotOk'
    Assert-ApiPoolEqual -Expected 0 -Actual @(Get-ApiPoolFakeTransportCall -Transport $envSt.Transport).Count -Name 'EmergencyStop/NoTransportCall'

    $envPj = New-AdpEnv -Responses @((Get-AdpOk))
    $resPj = Invoke-AdpMessage -Env $envPj -PerJob 100
    Assert-ApiPoolEqual -Expected 'BUDGET_EXHAUSTED_JOB' -Actual $resPj.Code -Name 'PerJob/ExplicitLimitCode'
    Assert-ApiPoolEqual -Expected 0 -Actual @(Get-ApiPoolFakeTransportCall -Transport $envPj.Transport).Count -Name 'PerJob/NoTransportCall'
    $envPj2 = New-AdpEnv -Responses @((Get-AdpOk)) -Configure { param($c) $c.perJobUsd = [decimal]0.0001 }
    $resPj2 = Invoke-AdpMessage -Env $envPj2
    Assert-ApiPoolEqual -Expected 'BUDGET_EXHAUSTED_JOB' -Actual $resPj2.Code -Name 'PerJob/ConfigDefaultCode'
    Assert-ApiPoolThrows { Invoke-AdpMessage -Env $envPj -Request (New-AdpRequest) -PerJob 0 } 'PerJob/NonPositiveRejected' -ExpectedCode 'REQUEST_INVALID'

    # per-job limit counts the unreconciled first attempt
    $oneAndHalf = [long]((Get-AdpReservationAmount) * 1.5)
    $envPj3 = New-AdpEnv -Responses @(@{ Kind = 'timeoutAfterSend' }, (Get-AdpOk))
    $resPj3 = Invoke-AdpMessage -Env $envPj3 -PerJob $oneAndHalf
    Assert-ApiPoolEqual -Expected 'BUDGET_EXHAUSTED_JOB' -Actual $resPj3.Code -Name 'PerJob/UnreconciledAttemptCounts'
    Assert-ApiPoolEqual -Expected 1 -Actual $resPj3.Attempts -Name 'PerJob/SecondAttemptNotSent'
    Assert-ApiPoolEqual -Expected 1 -Actual @(Get-ApiPoolFakeTransportCall -Transport $envPj3.Transport).Count -Name 'PerJob/OnlyOneCall'

    # ledger problems are refused, not thrown
    $envLc = New-AdpEnv -Responses @((Get-AdpOk))
    [System.IO.File]::Delete((Join-Path (Join-Path $envLc.Root 'budget') 'ledger.jsonl'))
    $resLc = Invoke-AdpMessage -Env $envLc
    Assert-ApiPoolEqual -Expected 'LEDGER_UNINITIALIZED' -Actual $resLc.Code -Name 'Ledger/UninitializedRefused'
    Assert-ApiPoolEqual -Expected 0 -Actual @(Get-ApiPoolFakeTransportCall -Transport $envLc.Transport).Count -Name 'Ledger/NoTransportCall'

    # ---------------------------------------------------------------- overrun
    $bigUsage = [ordered]@{ input_tokens = 100; output_tokens = 1000000; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }
    $envOr = New-AdpEnv -Responses @((New-AdpResp -Status 200 -Body (New-AdpOkBody -Usage $bigUsage)), (Get-AdpOk))
    $resOr = Invoke-AdpMessage -Env $envOr
    Assert-ApiPoolEqual -Expected $false -Actual $resOr.Ok -Name 'Overrun/NotOk'
    Assert-ApiPoolEqual -Expected 'BUDGET_OVERRUN' -Actual $resOr.Code -Name 'Overrun/Code'
    Assert-ApiPoolEqual -Expected 1 -Actual $resOr.Attempts -Name 'Overrun/NoRetry'
    Assert-ApiPoolEqual -Expected 10000200 -Actual $resOr.CostMicroUsd -Name 'Overrun/ActualCostReported'
    $st = Get-ApiPoolBudgetStatus -StateRoot $envOr.Root
    Assert-ApiPoolEqual -Expected 'STOPPED' -Actual $st.State -Name 'Overrun/BudgetStopped'
    Assert-ApiPoolEqual -Expected 10000200 -Actual $st.CommittedMicroUsd -Name 'Overrun/ActualCommitted'
    Assert-ApiPoolEqual -Expected 1 -Actual (Get-AdpTypeCount -Root $envOr.Root -Type 'OVERRUN') -Name 'Overrun/OverrunRecorded'
    $resAfter = Invoke-AdpMessage -Env $envOr
    Assert-ApiPoolEqual -Expected 'BUDGET_STOPPED' -Actual $resAfter.Code -Name 'Overrun/NextCallStopped'
    Assert-ApiPoolEqual -Expected 1 -Actual @(Get-ApiPoolFakeTransportCall -Transport $envOr.Transport).Count -Name 'Overrun/NoFurtherTransportCall'

    # ---------------------------------------------------------------- secret redaction
    $envSr = New-AdpEnv -Responses @((New-AdpResp -Status 400 -Body (New-AdpErrorBody -Message ('bad credential ' + $adpFakeKey + ' supplied') -Type ('t-' + $adpFakeKey))))
    $resSr = Invoke-AdpMessage -Env $envSr
    Assert-ApiPoolEqual -Expected 'API_CLIENT_ERROR' -Actual $resSr.Code -Name 'Redaction/Code'
    $dump = (ConvertTo-ApiPoolCanonicalJson -InputObject @{ Message = $resSr.Message; Details = $resSr.Details; Code = $resSr.Code })
    Assert-ApiPoolTrue -Condition (-not $dump.Contains($adpFakeKeyTail)) -Name 'Redaction/KeyAbsentFromResult' -Detail $dump
    Assert-ApiPoolTrue -Condition ($resSr.Message.Contains('REDACTED')) -Name 'Redaction/MarkerPresent'
    $ledgerText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $envSr.Root 'budget') 'ledger.jsonl'))
    Assert-ApiPoolTrue -Condition (-not $ledgerText.Contains($adpFakeKeyTail)) -Name 'Redaction/KeyAbsentFromLedger'
    $longMessage = ('A' * 900)
    $envLong = New-AdpEnv -Responses @((New-AdpResp -Status 400 -Body (New-AdpErrorBody -Message $longMessage)))
    $resLong = Invoke-AdpMessage -Env $envLong
    Assert-ApiPoolTrue -Condition ($resLong.Message.Length -le 520) -Name 'Redaction/MessageLengthCapped'
    $envCtl = New-AdpEnv -Responses @((New-AdpResp -Status 400 -Body (New-AdpErrorBody -Message ("line1`nline2`tx"))))
    $resCtl = Invoke-AdpMessage -Env $envCtl
    Assert-ApiPoolTrue -Condition (-not $resCtl.Message.Contains("`n") -and -not $resCtl.Message.Contains("`t")) -Name 'Redaction/ControlCharsFlattened'

    # ---------------------------------------------------------------- concurrency slots
    $envSl = New-AdpEnv -Responses @((Get-AdpOk)) -Configure { param($c) $c.maxConcurrency = 1; $c.timeouts.requestTimeoutSec = 1 }
    $held = Enter-ApiPoolFileLock -Path (Join-Path (Join-Path $envSl.Root 'slots') 'slot-1.lock') -TimeoutMs 1000
    try {
        $resSl = Invoke-AdpMessage -Env $envSl
    }
    finally {
        Exit-ApiPoolFileLock -Handle $held
    }
    Assert-ApiPoolEqual -Expected $false -Actual $resSl.Ok -Name 'Slots/NotOk'
    Assert-ApiPoolEqual -Expected 'SLOT_TIMEOUT' -Actual $resSl.Code -Name 'Slots/SlotTimeoutCode'
    Assert-ApiPoolEqual -Expected 0 -Actual @(Get-ApiPoolFakeTransportCall -Transport $envSl.Transport).Count -Name 'Slots/NoTransportCall'
    Assert-ApiPoolEqual -Expected 'INIT' -Actual ((Get-AdpLedgerRecords -Root $envSl.Root | ForEach-Object { $_.type }) -join ',') -Name 'Slots/NoReservation'
    Assert-ApiPoolTrue -Condition ($envSl.Sleeps.Count -gt 0 -and (Get-AdpSleepTotal -Env $envSl) -le 1100) -Name 'Slots/PollsWithInjectedSleepOnly'
    $resSl2 = Invoke-AdpMessage -Env $envSl
    Assert-ApiPoolTrue -Condition $resSl2.Ok -Name 'Slots/FreeAfterRelease' -Detail ([string]$resSl2.Code)

    # With two slots and one held, the call uses the second slot immediately.
    $envSl2 = New-AdpEnv -Responses @((Get-AdpOk)) -Configure { param($c) $c.maxConcurrency = 2 }
    $held2 = Enter-ApiPoolFileLock -Path (Join-Path (Join-Path $envSl2.Root 'slots') 'slot-1.lock') -TimeoutMs 1000
    try {
        $resSl3 = Invoke-AdpMessage -Env $envSl2
    }
    finally {
        Exit-ApiPoolFileLock -Handle $held2
    }
    Assert-ApiPoolTrue -Condition $resSl3.Ok -Name 'Slots/SecondSlotUsed' -Detail ([string]$resSl3.Code)
    Assert-ApiPoolEqual -Expected 0 -Actual $envSl2.Sleeps.Count -Name 'Slots/NoWaitWhenSlotFree'

    # ---------------------------------------------------------------- QA-001 cancellation while waiting / before reserve / before send
    $cancelSlot = Join-Path $adpSandbox 'cancel-slot.flag'
    $slotHold = @{ Handle = $null; Polls = 0 }
    $envCs = New-AdpEnv -Responses @((Get-AdpOk)) -Configure { param($c) $c.maxConcurrency = 1; $c.timeouts.requestTimeoutSec = 30 } -OnSleep {
        param($ms)
        $slotHold.Polls++
        if ($slotHold.Polls -eq 1) { [System.IO.File]::WriteAllText($cancelSlot, 'x') }
        elseif ($slotHold.Polls -eq 2 -and $null -ne $slotHold.Handle) { Exit-ApiPoolFileLock -Handle $slotHold.Handle; $slotHold.Handle = $null }
    }
    $slotHold.Handle = Enter-ApiPoolFileLock -Path (Join-Path (Join-Path $envCs.Root 'slots') 'slot-1.lock') -TimeoutMs 1000
    try {
        $resCs = Invoke-AdpMessage -Env $envCs -CancelPath $cancelSlot
    }
    finally {
        if ($null -ne $slotHold.Handle) { Exit-ApiPoolFileLock -Handle $slotHold.Handle; $slotHold.Handle = $null }
    }
    Assert-ApiPoolEqual -Expected 'CANCELLED' -Actual $resCs.Code -Name 'CancelWhileWaitingForSlot/Code'
    Assert-ApiPoolEqual -Expected 0 -Actual @(Get-ApiPoolFakeTransportCall -Transport $envCs.Transport).Count -Name 'CancelWhileWaitingForSlot/NoTransportCall'
    Assert-ApiPoolEqual -Expected 'INIT' -Actual ((Get-AdpLedgerRecords -Root $envCs.Root | ForEach-Object { $_.type }) -join ',') -Name 'CancelWhileWaitingForSlot/NoReservation'
    Assert-ApiPoolEqual -Expected 0 -Actual @($resCs.ReservationIds).Count -Name 'CancelWhileWaitingForSlot/NoReservationIds'

    # Cancel marker appears during the rate-limit wait of a second call that shares the state root.
    $cancelRate = Join-Path $adpSandbox 'cancel-rate.flag'
    $envCr1 = New-AdpEnv -Responses @((New-AdpResp -Status 429 -Headers @{ 'retry-after' = '5' }), (Get-AdpOk))
    $resCr1 = Invoke-AdpMessage -Env $envCr1
    Assert-ApiPoolTrue -Condition $resCr1.Ok -Name 'CancelDuringRateWait/Setup' -Detail ([string]$resCr1.Code)
    $envCr1.State.Now = New-Object System.DateTime(2030, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    $envCr2 = New-AdpEnv -Responses @((Get-AdpOk)) -Root $envCr1.Root -State $envCr1.State -OnSleep { param($ms) [System.IO.File]::WriteAllText($cancelRate, 'x') }
    $resCr2 = Invoke-AdpMessage -Env $envCr2 -CancelPath $cancelRate
    Assert-ApiPoolEqual -Expected 'CANCELLED' -Actual $resCr2.Code -Name 'CancelDuringRateWait/Code'
    Assert-ApiPoolEqual -Expected 0 -Actual @(Get-ApiPoolFakeTransportCall -Transport $envCr2.Transport).Count -Name 'CancelDuringRateWait/NoTransportCall'
    Assert-ApiPoolEqual -Expected 0 -Actual @($resCr2.ReservationIds).Count -Name 'CancelDuringRateWait/NoReservation'

    # Cancel marker appears while the reservation is being made (injected clock): no budget left reserved, no transport call.
    $cancelRsv = Join-Path $adpSandbox 'cancel-reserve.flag'
    $envCv = New-AdpEnv -Responses @((Get-AdpOk))
    $cvState = $envCv.State
    $envCv.Context.Clock = { [System.IO.File]::WriteAllText($cancelRsv, 'x'); $cvState.Now }.GetNewClosure()
    $resCv = Invoke-AdpMessage -Env $envCv -CancelPath $cancelRsv
    Assert-ApiPoolEqual -Expected 'CANCELLED' -Actual $resCv.Code -Name 'CancelBeforeSend/Code'
    Assert-ApiPoolEqual -Expected 0 -Actual @(Get-ApiPoolFakeTransportCall -Transport $envCv.Transport).Count -Name 'CancelBeforeSend/NoTransportCall'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-ApiPoolBudgetStatus -StateRoot $envCv.Root).ReservedMicroUsd -Name 'CancelBeforeSend/NothingLeftReserved'

    # ---------------------------------------------------------------- rate limit shared through the state file
    $envRl1 = New-AdpEnv -Responses @((New-AdpResp -Status 429 -Headers @{ 'retry-after' = '5' }), (Get-AdpOk))
    $resRl1 = Invoke-AdpMessage -Env $envRl1
    Assert-ApiPoolTrue -Condition $resRl1.Ok -Name 'RateShared/FirstCallOk' -Detail ([string]$resRl1.Code)
    $envRl1.State.Now = New-Object System.DateTime(2030, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    $envRl2 = New-AdpEnv -Responses @((Get-AdpOk)) -Root $envRl1.Root -State $envRl1.State
    $resRl2 = Invoke-AdpMessage -Env $envRl2
    Assert-ApiPoolTrue -Condition $resRl2.Ok -Name 'RateShared/SecondCallOk' -Detail ([string]$resRl2.Code)
    Assert-ApiPoolEqual -Expected 5000 -Actual (Get-AdpSleepTotal -Env $envRl2) -Name 'RateShared/SecondCallWaitsForNotBefore'
    Assert-ApiPoolTrue -Condition (@($envRl2.Sleeps | Where-Object { $_ -gt 250 }).Count -eq 0) -Name 'RateShared/WaitInChunks'

    # a hand-written state file in the documented format is honored, and a corrupt one is ignored
    $envRl3 = New-AdpEnv -Responses @((Get-AdpOk))
    $rlDir = Join-Path $envRl3.Root 'ratelimit'
    [void][System.IO.Directory]::CreateDirectory($rlDir)
    [System.IO.File]::WriteAllText((Join-Path $rlDir 'claude-sonnet-5-5.json'), '{"notBeforeUtc":"2030-01-01T00:00:03.0000000Z"}')
    $resRl3 = Invoke-AdpMessage -Env $envRl3
    Assert-ApiPoolTrue -Condition $resRl3.Ok -Name 'RateFile/HandWrittenOk' -Detail ([string]$resRl3.Code)
    Assert-ApiPoolEqual -Expected 3000 -Actual (Get-AdpSleepTotal -Env $envRl3) -Name 'RateFile/HandWrittenHonored'
    $envRl4 = New-AdpEnv -Responses @((Get-AdpOk))
    $rlDir4 = Join-Path $envRl4.Root 'ratelimit'
    [void][System.IO.Directory]::CreateDirectory($rlDir4)
    [System.IO.File]::WriteAllText((Join-Path $rlDir4 'claude-sonnet-5-5.json'), '{ this is not json')
    $resRl4 = Invoke-AdpMessage -Env $envRl4
    Assert-ApiPoolTrue -Condition $resRl4.Ok -Name 'RateFile/CorruptIgnored' -Detail ([string]$resRl4.Code)
    Assert-ApiPoolEqual -Expected 0 -Actual $envRl4.Sleeps.Count -Name 'RateFile/CorruptNoWait'

    # minimum interval between attempts of one model
    $envMi1 = New-AdpEnv -Responses @((Get-AdpOk)) -Configure { param($c) $c.minRequestIntervalMs = 400 }
    $resMi1 = Invoke-AdpMessage -Env $envMi1
    Assert-ApiPoolEqual -Expected 0 -Actual $envMi1.Sleeps.Count -Name 'MinInterval/FirstCallNoWait'
    $envMi2 = New-AdpEnv -Responses @((Get-AdpOk)) -Configure { param($c) $c.minRequestIntervalMs = 400 } -Root $envMi1.Root -State $envMi1.State
    $resMi2 = Invoke-AdpMessage -Env $envMi2
    Assert-ApiPoolTrue -Condition ($resMi1.Ok -and $resMi2.Ok) -Name 'MinInterval/BothOk'
    Assert-ApiPoolEqual -Expected 400 -Actual (Get-AdpSleepTotal -Env $envMi2) -Name 'MinInterval/SecondCallWaits'
    Assert-ApiPoolTrue -Condition (@($envMi2.Sleeps | Where-Object { $_ -gt 250 }).Count -eq 0) -Name 'MinInterval/WaitInChunks'

    # live mode can never reach the adapter
    $envLive = New-AdpEnv -Responses @((Get-AdpOk))
    $liveCfg = Read-ApiPoolConfig -Path $adpConfigPath
    $liveCfg.mode = 'live'
    $liveCtx = [pscustomobject]@{ StateRoot = $envLive.Root; Config = $liveCfg; Registry = $adpRegistry; Transport = $envLive.Transport; CredentialProvider = $null; Clock = $envLive.Context.Clock; Sleep = $envLive.Context.Sleep }
    Assert-ApiPoolThrows { Invoke-ApiPoolMessage -Context $liveCtx -JobId 'j' -Request (New-AdpRequest) } 'Live/AdapterRefusesLiveMode' -ExpectedCode 'LIVE_DISABLED_IN_BUILD'
}
finally {
    Remove-ApiPoolTestSandbox -Path $adpSandbox
}
