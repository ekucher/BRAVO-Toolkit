# NetworkIsolation suite: OFFLINE MODE MUST NEVER CALL THE REAL API.
# Dot-sourced by Invoke-ApiPoolTests.ps1.
#
# IMPORTANT LIMITATION: these checks prove that the shipped ApiPool code contains no
# network-capable constructs and that the exercised code paths never reach the shadowed web
# cmdlets. They do NOT prove OS-level egress isolation (a firewall or an air gap is the only
# proof of that). Do not read a green result here as a statement about the host network.

$netSandbox = New-ApiPoolTestSandbox
try {
    $netApiRoot = Split-Path -Parent $script:TestsRoot

    # Case-insensitive; whole-word where a bare word could appear inside a longer identifier.
    $netPatterns = [ordered]@{
        'Invoke-WebRequest'  = '(?i)Invoke-WebRequest'
        'Invoke-RestMethod'  = '(?i)Invoke-RestMethod'
        'System.Net'         = '(?i)System\.Net'
        'HttpClient'         = '(?i)HttpClient'
        'HttpWebRequest'     = '(?i)HttpWebRequest'
        'WebClient'          = '(?i)WebClient'
        'Net.Sockets'        = '(?i)Net\.Sockets'
        'TcpClient'          = '(?i)TcpClient'
        'api host name'      = '(?i)api\.anthropic\.com'
        'Start-BitsTransfer' = '(?i)Start-BitsTransfer'
        'curl'               = '(?i)\bcurl\b'
        'wget'               = '(?i)\bwget\b'
    }

    function Find-NetIsolationPattern {
        param([string]$Text)
        $hits = New-Object System.Collections.ArrayList
        foreach ($name in $netPatterns.Keys) {
            if ([regex]::IsMatch($Text, $netPatterns[$name])) { [void]$hits.Add($name) }
        }
        return @($hits.ToArray())
    }

    # --- (1) static scan of everything shipped as product code ---
    # The scanner is verified first, so a green scan cannot be an artifact of a broken pattern.
    $probe = 'Invoke-WebRequest INVOKE-RESTMETHOD [System.Net.Http.HttpClient] new-object HttpWebRequest WebClient ' +
    'Net.Sockets TcpClient api.anthropic.com Start-BitsTransfer curl wget'
    $probeHits = @(Find-NetIsolationPattern -Text $probe)
    Assert-ApiPoolEqual -Expected $netPatterns.Count -Actual $probeHits.Count -Name 'Scan/PatternsDetectEveryForbiddenConstruct'
    Assert-ApiPoolEqual -Expected 0 -Actual @(Find-NetIsolationPattern -Text 'curlew wget2 Send-ApiPoolTransportRequest').Count -Name 'Scan/WholeWordForBareWords'

    $scanTargets = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath $script:ModulesRoot -Recurse -File)) { [void]$scanTargets.Add($f.FullName) }
    $entrypoint = Join-Path $netApiRoot 'Invoke-ApiPool.ps1'
    if ([System.IO.File]::Exists($entrypoint)) { [void]$scanTargets.Add($entrypoint) }
    Assert-ApiPoolTrue -Condition ($scanTargets.Count -ge 6) -Name 'Scan/CoversAllModules' -Detail ('scanned only {0} files' -f $scanTargets.Count)
    foreach ($required in @('Core', 'Credentials', 'Pricing', 'Budget', 'Transport', 'Adapter')) {
        $expected = Join-Path $script:ModulesRoot ('ApiPool.{0}.psm1' -f $required)
        Assert-ApiPoolTrue -Condition ($scanTargets -contains $expected) -Name ('Scan/Includes{0}' -f $required)
    }
    foreach ($path in $scanTargets) {
        $text = [System.IO.File]::ReadAllText($path)
        $hits = @(Find-NetIsolationPattern -Text $text)
        Assert-ApiPoolEqual -Expected 0 -Actual $hits.Count -Name ('Scan/NoNetworkConstructs/{0}' -f (Split-Path -Leaf $path))
        if ($hits.Count -gt 0) { Write-Host ('       forbidden in {0}: {1}' -f (Split-Path -Leaf $path), ($hits -join ', ')) }
    }

    # --- (2) end to end in offline mode: the shadowed web cmdlets must see nothing ---
    $haveRecorder = ($null -ne (Get-Variable -Name ApiPoolNetworkAttempts -Scope Global -ErrorAction SilentlyContinue))
    Assert-ApiPoolTrue -Condition $haveRecorder -Name 'Guard/RecorderPresent' -Detail 'run through Invoke-ApiPoolTests.ps1 so the web cmdlets are shadowed'
    $shadowed = ($null -ne (Get-Command -Name Invoke-WebRequest -CommandType Function -ErrorAction SilentlyContinue)) -and ($null -ne (Get-Command -Name Invoke-RestMethod -CommandType Function -ErrorAction SilentlyContinue))
    Assert-ApiPoolTrue -Condition $shadowed -Name 'Guard/WebCmdletsShadowed'

    if ($haveRecorder) {
        $before = $global:ApiPoolNetworkAttempts.Count
        $netRoot = Join-Path $netSandbox 'e2e'
        $netCfg = Read-ApiPoolConfig -Path (Join-Path $script:ConfigRoot 'apipool.defaults.json')
        $netCfg.minRequestIntervalMs = 0
        $netReg = Import-ApiPoolModelRegistry -Path (Join-Path $script:ConfigRoot 'models.json')
        [void](Initialize-ApiPoolLedger -StateRoot $netRoot -GlobalLimitMicroUsd 60000000)
        $okBody = ConvertTo-Json -Compress -Depth 6 -InputObject ([ordered]@{
                id = 'msg_net'; type = 'message'; role = 'assistant'; content = @(@{ type = 'text'; text = 'ok' }); stop_reason = 'end_turn'
                usage = [ordered]@{ input_tokens = 5; output_tokens = 5; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }
            })
        $netTransport = New-ApiPoolFakeTransport -Responses @(@{ StatusCode = 500; Body = '{}' }, @{ StatusCode = 200; Headers = @{ 'request-id' = 'req_net' }; Body = $okBody })
        $netCtx = New-ApiPoolContext -StateRoot $netRoot -Config $netCfg -Registry $netReg -Transport $netTransport -CredentialProvider $null -Sleep { param($Milliseconds) }
        $netReq = @{ model = 'claude-sonnet-5-5'; max_tokens = 64; messages = @(@{ role = 'user'; content = 'ping' }) }
        $netRes = Invoke-ApiPoolMessage -Context $netCtx -JobId 'job-net' -Request $netReq
        Assert-ApiPoolTrue -Condition $netRes.Ok -Name 'EndToEnd/OfflineCallSucceedsViaFake' -Detail ([string]$netRes.Code)
        Assert-ApiPoolEqual -Expected 2 -Actual @(Get-ApiPoolFakeTransportCall -Transport $netTransport).Count -Name 'EndToEnd/OnlyFakeTransportUsed'
        Assert-ApiPoolEqual -Expected $before -Actual $global:ApiPoolNetworkAttempts.Count -Name 'EndToEnd/ZeroWebCmdletAttempts'
        Assert-ApiPoolEqual -Expected 'offline' -Actual $netCfg.mode -Name 'EndToEnd/ConfigModeOffline'
    }

    # --- (3) negative control: the guard really fires, and is recorded ---
    # The recorder is shared with the run-level NoNetworkAttempts assertion, so ONLY the entries
    # added here are removed afterwards (earlier real attempts, if any, must stay visible).
    if ($haveRecorder -and $shadowed) {
        $mark = $global:ApiPoolNetworkAttempts.Count
        $thrownWr = $null
        try { Invoke-WebRequest -Uri 'http://127.0.0.1:9/' } catch { $thrownWr = $_ }
        Assert-ApiPoolTrue -Condition ($null -ne $thrownWr -and $thrownWr.Exception.Message -eq 'NETWORK_FORBIDDEN_IN_TESTS') -Name 'GuardControl/InvokeWebRequestThrows'
        Assert-ApiPoolEqual -Expected ($mark + 1) -Actual $global:ApiPoolNetworkAttempts.Count -Name 'GuardControl/InvokeWebRequestRecorded'
        $thrownRm = $null
        try { Invoke-RestMethod -Uri 'http://127.0.0.1:9/' } catch { $thrownRm = $_ }
        Assert-ApiPoolTrue -Condition ($null -ne $thrownRm -and $thrownRm.Exception.Message -eq 'NETWORK_FORBIDDEN_IN_TESTS') -Name 'GuardControl/InvokeRestMethodThrows'
        Assert-ApiPoolEqual -Expected ($mark + 2) -Actual $global:ApiPoolNetworkAttempts.Count -Name 'GuardControl/InvokeRestMethodRecorded'
        while ($global:ApiPoolNetworkAttempts.Count -gt $mark) {
            $global:ApiPoolNetworkAttempts.RemoveAt($global:ApiPoolNetworkAttempts.Count - 1)
        }
        Assert-ApiPoolEqual -Expected $mark -Actual $global:ApiPoolNetworkAttempts.Count -Name 'GuardControl/RecorderRestoredForRunLevelAssertion'
    }

    # --- (4) the live transport cannot be constructed, whatever it is called with ---
    Assert-ApiPoolThrows { New-ApiPoolHttpTransport } 'LiveTransport/NoArguments' -ExpectedCode 'LIVE_DISABLED_IN_BUILD'
    Assert-ApiPoolThrows { New-ApiPoolHttpTransport -BaseUri 'https://example.invalid/' -ApiKey 'x' -TimeoutSec 1 -Proxy 'p' } 'LiveTransport/ArbitraryNamedArguments' -ExpectedCode 'LIVE_DISABLED_IN_BUILD'
    Assert-ApiPoolThrows { New-ApiPoolHttpTransport @{ Uri = 'x' } $null 42 } 'LiveTransport/ArbitraryPositionalArguments' -ExpectedCode 'LIVE_DISABLED_IN_BUILD'
    Assert-ApiPoolThrows { New-ApiPoolHttpTransport -Allow $true -EnableLive } 'LiveTransport/AttemptToEnable' -ExpectedCode 'LIVE_DISABLED_IN_BUILD'
    Assert-ApiPoolThrows { New-ApiPoolContext -StateRoot (Join-Path $netSandbox 'live') -Config ([pscustomobject]@{ mode = 'live' }) -Registry $null -Transport $null -CredentialProvider $null } 'LiveTransport/LiveModeConfigRefused' -ExpectedCode 'LIVE_DISABLED_IN_BUILD'
    $liveMsg = ''
    try { New-ApiPoolHttpTransport } catch { $liveMsg = $_.Exception.Message }
    Assert-ApiPoolTrue -Condition ($liveMsg.Contains('live transport is not shipped in this build')) -Name 'LiveTransport/MessageIsExplicit' -Detail $liveMsg
}
finally {
    Remove-ApiPoolTestSandbox -Path $netSandbox
}
