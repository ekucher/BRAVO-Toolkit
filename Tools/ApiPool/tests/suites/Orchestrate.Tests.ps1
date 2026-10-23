# Orchestrate suite. Dot-sourced by Invoke-ApiPoolTests.ps1. Offline; fake transport and sandbox state roots only.

$orSandbox = New-ApiPoolTestSandbox
try {
    $orCatalog = Join-Path $script:ConfigRoot 'agents.json'
    $orRegistry = Import-ApiPoolModelRegistry -Path (Join-Path $script:ConfigRoot 'models.json')

    function New-OrOkResp {
        $text = "Result.`n`nHANDOFF`nresult: done`nrole: someone-else`nreview_source: codex-qa`nchanged: x.ps1`nmerge_gate: clear`nchat_links: none`nnext: owner"
        $doc = [ordered]@{
            id = 'msg_or1'; type = 'message'; role = 'assistant'; model = 'claude-sonnet-5-5'
            content = @(@{ type = 'text'; text = $text }); stop_reason = 'end_turn'
            usage = [ordered]@{ input_tokens = 100; output_tokens = 50; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }
        }
        return @{ StatusCode = 200; Headers = @{ 'request-id' = 'req_or' }; Body = (ConvertTo-Json -InputObject $doc -Compress -Depth 8) }
    }

    function New-OrEnv {
        param([object[]]$Responses, [long]$Limit = 60000000, [switch]$NoTransport)
        $root = Join-Path $orSandbox ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $cfg = Read-ApiPoolConfig -Path (Join-Path $script:ConfigRoot 'apipool.defaults.json')
        $cfg.minRequestIntervalMs = 0
        [void](Initialize-ApiPoolLedger -StateRoot $root -GlobalLimitMicroUsd $Limit)
        $transport = $null
        if (-not $NoTransport) { $transport = New-ApiPoolFakeTransport -Responses $Responses }
        $ctx = New-ApiPoolContext -StateRoot $root -Config $cfg -Registry $orRegistry -Transport $transport -CredentialProvider $null -Sleep { param($Milliseconds) }
        return [pscustomobject]@{ Root = $root; Context = $ctx; Transport = $transport }
    }

    function Invoke-OrOrchestrate {
        param($Env, [string]$Key, [string]$Role = 'api-scout', $Context = $null, [switch]$UseContext)
        $ctx = $Env.Context
        if ($UseContext) { $ctx = $Context }
        $a = @{ Context = $ctx; Role = $Role; Brief = 'Map it.'; ContextData = 'data'; CatalogPath = $orCatalog }
        if (-not [string]::IsNullOrEmpty($Key)) { $a['IdempotencyKey'] = $Key }
        return (Invoke-ApiPoolOrchestrateJob @a)
    }

    function Get-OrCalls { param($Env) return @(Get-ApiPoolFakeTransportCall -Transport $Env.Transport).Count }

    # ---------------------------------------------------------------- completed
    $e1 = New-OrEnv -Responses @((New-OrOkResp))
    $o1 = Invoke-OrOrchestrate -Env $e1 -Key 'k1'
    Assert-ApiPoolEqual -Expected 'apipool.orchestrate/1' -Actual $o1.schema -Name 'Completed/Schema'
    Assert-ApiPoolEqual -Expected 'completed' -Actual $o1.status -Name 'Completed/Status'
    Assert-ApiPoolEqual -Expected 'OK' -Actual $o1.reasonCode -Name 'Completed/ReasonCode'
    Assert-ApiPoolEqual -Expected $true -Actual $o1.advisoryOnly -Name 'Completed/AdvisoryOnly'
    Assert-ApiPoolTrue -Condition ($o1.jobId -cmatch '^job-[0-9a-f]{24}$') -Name 'Completed/JobId'
    Assert-ApiPoolEqual -Expected 700 -Actual $o1.costMicroUsd -Name 'Completed/Cost'
    Assert-ApiPoolEqual -Expected 'api-scout' -Actual $o1.handoff.role -Name 'Completed/RoleForced'
    Assert-ApiPoolEqual -Expected 'none' -Actual $o1.handoff.review_source -Name 'Completed/ReviewSourceForced'
    Assert-ApiPoolEqual -Expected 'n/a' -Actual $o1.handoff.merge_gate -Name 'Completed/MergeGateForced'
    Assert-ApiPoolEqual -Expected 'none' -Actual $o1.handoff.changed -Name 'Completed/ChangedForced'
    Assert-ApiPoolEqual -Expected 'succeeded' -Actual (Get-ApiPoolJob -StateRoot $e1.Root -JobId $o1.jobId).state -Name 'Completed/JobPersisted'
    $again = Invoke-OrOrchestrate -Env $e1 -Key 'k1'
    Assert-ApiPoolEqual -Expected 'completed' -Actual $again.status -Name 'Completed/IdempotentRepeat'
    Assert-ApiPoolEqual -Expected 1 -Actual (Get-OrCalls -Env $e1) -Name 'Completed/IdempotentRepeatNoNewCall'

    # ---------------------------------------------------------------- fallbacks
    $oNull = Invoke-ApiPoolOrchestrateJob -Context $null -Role 'api-scout' -Brief 'b' -ContextData 'c' -CatalogPath $orCatalog
    Assert-ApiPoolEqual -Expected 'fallback' -Actual $oNull.status -Name 'Fallback/NullContext'
    Assert-ApiPoolEqual -Expected 'POOL_DISABLED' -Actual $oNull.reasonCode -Name 'Fallback/NullContextCode'
    Assert-ApiPoolEqual -Expected $true -Actual $oNull.advisoryOnly -Name 'Fallback/AdvisoryOnlyAlways'
    $eNoT = New-OrEnv -NoTransport
    $oNoT = Invoke-OrOrchestrate -Env $eNoT
    Assert-ApiPoolEqual -Expected 'POOL_DISABLED' -Actual $oNoT.reasonCode -Name 'Fallback/NullTransportCode'
    Assert-ApiPoolEqual -Expected 'fallback' -Actual $oNoT.status -Name 'Fallback/NullTransportStatus'
    Assert-ApiPoolTrue -Condition (-not [System.IO.Directory]::Exists((Join-Path $eNoT.Root 'jobs'))) -Name 'Fallback/NullTransportCreatesNoJob'

    $eStop = New-OrEnv -Responses @((New-OrOkResp))
    [void](Set-ApiPoolEmergencyStop -StateRoot $eStop.Root -Reason 'orchestrate test')
    $oStop = Invoke-OrOrchestrate -Env $eStop
    Assert-ApiPoolEqual -Expected 'fallback' -Actual $oStop.status -Name 'Fallback/StoppedStatus'
    Assert-ApiPoolEqual -Expected 'BUDGET_STOPPED' -Actual $oStop.reasonCode -Name 'Fallback/StoppedCode'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-OrCalls -Env $eStop) -Name 'Fallback/StoppedNoCall'
    Assert-ApiPoolTrue -Condition (-not [System.IO.Directory]::Exists((Join-Path $eStop.Root 'jobs'))) -Name 'Fallback/StoppedCreatesNoJob'

    $eCor = New-OrEnv -Responses @((New-OrOkResp))
    [System.IO.File]::AppendAllText((Join-Path (Join-Path $eCor.Root 'budget') 'ledger.jsonl'), "{garbage`n")
    $oCor = Invoke-OrOrchestrate -Env $eCor
    Assert-ApiPoolEqual -Expected 'fallback' -Actual $oCor.status -Name 'Fallback/CorruptStatus'
    Assert-ApiPoolEqual -Expected 'LEDGER_CORRUPT' -Actual $oCor.reasonCode -Name 'Fallback/CorruptCode'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-OrCalls -Env $eCor) -Name 'Fallback/CorruptNoCall'

    $eUn = New-OrEnv -Responses @((New-OrOkResp))
    [System.IO.File]::Delete((Join-Path (Join-Path $eUn.Root 'budget') 'ledger.jsonl'))
    $oUn = Invoke-OrOrchestrate -Env $eUn
    Assert-ApiPoolEqual -Expected 'LEDGER_UNINITIALIZED' -Actual $oUn.reasonCode -Name 'Fallback/UninitializedCode'

    $eEx = New-OrEnv -Responses @((New-OrOkResp)) -Limit 1000
    $oEx = Invoke-OrOrchestrate -Env $eEx
    Assert-ApiPoolEqual -Expected 'fallback' -Actual $oEx.status -Name 'Fallback/ExhaustedStatus'
    Assert-ApiPoolEqual -Expected 'BUDGET_EXHAUSTED_GLOBAL' -Actual $oEx.reasonCode -Name 'Fallback/ExhaustedCode'
    Assert-ApiPoolTrue -Condition (-not [string]::IsNullOrEmpty($oEx.jobId)) -Name 'Fallback/ExhaustedKeepsJobId'
    Assert-ApiPoolEqual -Expected 0 -Actual (Get-OrCalls -Env $eEx) -Name 'Fallback/ExhaustedNoCall'

    # ---------------------------------------------------------------- failed
    $eAuth = New-OrEnv -Responses @(@{ StatusCode = 401; Headers = @{}; Body = '{"type":"error","error":{"type":"authentication_error","message":"bad"}}' })
    $oAuth = Invoke-OrOrchestrate -Env $eAuth
    Assert-ApiPoolEqual -Expected 'failed' -Actual $oAuth.status -Name 'Failed/AuthStatus'
    Assert-ApiPoolEqual -Expected 'API_AUTH_FAILED' -Actual $oAuth.reasonCode -Name 'Failed/AuthCode'
    Assert-ApiPoolEqual -Expected $null -Actual $oAuth.handoff -Name 'Failed/NoHandoff'
    $oBadRole = Invoke-OrOrchestrate -Env $eAuth -Role 'api-nope'
    Assert-ApiPoolEqual -Expected 'failed' -Actual $oBadRole.status -Name 'Failed/BadRoleStatus'
    Assert-ApiPoolEqual -Expected 'REQUEST_INVALID' -Actual $oBadRole.reasonCode -Name 'Failed/BadRoleCode'
    $oConflict = Invoke-ApiPoolOrchestrateJob -Context $e1.Context -Role 'api-scout' -Brief 'a different brief' -ContextData 'data' -IdempotencyKey 'k1' -CatalogPath $orCatalog
    Assert-ApiPoolEqual -Expected 'IDEMPOTENCY_CONFLICT' -Actual $oConflict.reasonCode -Name 'Failed/IdempotencyConflictCode'
    Assert-ApiPoolEqual -Expected 'failed' -Actual $oConflict.status -Name 'Failed/IdempotencyConflictStatus'

    # ---------------------------------------------------------------- shared limits
    # Learn the reservation size from one probe run, then allow exactly one reservation of that size.
    $eProbe = New-OrEnv -Responses @((New-OrOkResp))
    [void](Invoke-OrOrchestrate -Env $eProbe)
    $reserve = @([System.IO.File]::ReadAllText((Join-Path (Join-Path $eProbe.Root 'budget') 'ledger.jsonl')).Split([char]10) | Where-Object { $_ -match '"type":"RESERVE"' })
    $reserveAmount = [long](ConvertFrom-Json -InputObject $reserve[0]).data.amount
    Assert-ApiPoolTrue -Condition ($reserveAmount -gt 700) -Name 'Shared/ProbeReservationLearned'
    $eShared = New-OrEnv -Responses @((New-OrOkResp), (New-OrOkResp)) -Limit ($reserveAmount + 500)
    $s1 = Invoke-OrOrchestrate -Env $eShared
    $s2 = Invoke-OrOrchestrate -Env $eShared
    Assert-ApiPoolEqual -Expected 'completed' -Actual $s1.status -Name 'Shared/FirstCompleted'
    Assert-ApiPoolEqual -Expected 'fallback' -Actual $s2.status -Name 'Shared/SecondRefused'
    Assert-ApiPoolEqual -Expected 'BUDGET_EXHAUSTED_GLOBAL' -Actual $s2.reasonCode -Name 'Shared/SecondRefusedByGlobalLimit'
    Assert-ApiPoolEqual -Expected 1 -Actual (Get-OrCalls -Env $eShared) -Name 'Shared/SecondMadeNoCall'
    Assert-ApiPoolTrue -Condition ($s1.jobId -cne $s2.jobId) -Name 'Shared/DistinctJobs'
    Assert-ApiPoolEqual -Expected 700 -Actual (Get-ApiPoolBudgetStatus -StateRoot $eShared.Root).CommittedMicroUsd -Name 'Shared/OneLedger'

    # ---------------------------------------------------------------- no scheduler / background execution
    $forbiddenPatterns = @('Register-ScheduledTask', 'New-ScheduledTask', 'schtasks', 'Start-Job', 'Start-ThreadJob', 'RunspaceFactory', 'Start-Process', 'Register-ObjectEvent', 'Register-WmiEvent')
    $scanFiles = @(
        (Join-Path $script:ModulesRoot 'ApiPool.Jobs.psm1'),
        (Join-Path $script:ModulesRoot 'ApiPool.Agents.psm1'),
        (Join-Path $script:ApiRoot 'Invoke-ApiPool.ps1')
    )
    foreach ($f in $scanFiles) {
        $text = [System.IO.File]::ReadAllText($f)
        $hits = @($forbiddenPatterns | Where-Object { $text -match [regex]::Escape($_) })
        Assert-ApiPoolEqual -Expected 0 -Actual $hits.Count -Name ('NoScheduler/' + (Split-Path -Leaf $f))
        if ($hits.Count -gt 0) { Write-Host ('       found: ' + ($hits -join ', ')) }
    }
    Assert-ApiPoolTrue -Condition ('x Start-Job y' -match [regex]::Escape('Start-Job')) -Name 'NoScheduler/ScannerSelfCheck'
}
finally {
    Remove-ApiPoolTestSandbox -Path $orSandbox
}
