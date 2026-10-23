# Transport suite. Dot-sourced by Invoke-ApiPoolTests.ps1. Offline; fake transport only.

$trnSandbox = New-ApiPoolTestSandbox
try {
    function Get-TrnErrorRecord {
        param([scriptblock]$Block)
        try { $null = & $Block; return $null } catch { return $_ }
    }

    function Get-TrnSentFlag {
        param($ErrorRecord)
        return $ErrorRecord.TargetObject.Details['sent']
    }

    function New-TrnRequest {
        param([string]$Body = '{"a":1}')
        return @{ Method = 'POST'; Uri = 'apipool:messages/v1'; Body = $Body; TimeoutSec = 30 }
    }

    $trnFakeKey = 'sk-' + 'ant-' + 'api03-' + 'TRNFAKEKEY0123456789'

    # --- Live transport is not shipped ---
    Assert-ApiPoolThrows { New-ApiPoolHttpTransport } 'Http/NoArgsThrows' -ExpectedCode 'LIVE_DISABLED_IN_BUILD'
    Assert-ApiPoolThrows { New-ApiPoolHttpTransport -Uri 'x' -TimeoutSec 5 -Anything 'y' } 'Http/NamedArgsThrow' -ExpectedCode 'LIVE_DISABLED_IN_BUILD'
    Assert-ApiPoolThrows { New-ApiPoolHttpTransport 'a' 'b' 3 } 'Http/PositionalArgsThrow' -ExpectedCode 'LIVE_DISABLED_IN_BUILD'
    Assert-ApiPoolThrows { New-ApiPoolHttpTransport -CredentialProvider $null -Verbose } 'Http/CommonParameterStillThrows' -ExpectedCode 'LIVE_DISABLED_IN_BUILD'

    $liveConfig = [pscustomobject]@{ mode = 'live' }
    Assert-ApiPoolThrows { New-ApiPoolContext -StateRoot (Join-Path $trnSandbox 'live') -Config $liveConfig -Registry $null -Transport $null -CredentialProvider $null } 'Context/LiveModeRefused' -ExpectedCode 'LIVE_DISABLED_IN_BUILD'
    $trnCfg = Read-ApiPoolConfig -Path (Join-Path $script:ConfigRoot 'apipool.defaults.json')
    Assert-ApiPoolEqual -Expected 'offline' -Actual $trnCfg.mode -Name 'Context/DefaultModeOffline'

    # --- Fake transport records calls, never header values ---
    $fake = New-ApiPoolFakeTransport -Responses @(
        @{ StatusCode = 200; Headers = @{ 'request-id' = 'req_1' }; Body = '{"ok":true}' },
        @{ StatusCode = 429; Headers = @{ 'retry-after' = '7' }; Body = 'slow down' }
    )
    Assert-ApiPoolEqual -Expected 'Fake' -Actual $fake.Kind -Name 'Fake/Kind'
    $unicodeBody = '{"text":"' + [string][char]0x041F + [string][char]0x0440 + [string][char]0x0438 + '"}'
    $r1 = Send-ApiPoolTransportRequest -Transport $fake -Request (New-TrnRequest -Body $unicodeBody) -CredentialProvider $null
    Assert-ApiPoolEqual -Expected 200 -Actual $r1.StatusCode -Name 'Fake/FirstStatus'
    Assert-ApiPoolEqual -Expected 'req_1' -Actual $r1.Headers['request-id'] -Name 'Fake/FirstHeaders'
    Assert-ApiPoolEqual -Expected '{"ok":true}' -Actual $r1.Body -Name 'Fake/FirstBody'
    $r2 = Send-ApiPoolTransportRequest -Transport $fake -Request (New-TrnRequest) -CredentialProvider $null
    Assert-ApiPoolEqual -Expected 429 -Actual $r2.StatusCode -Name 'Fake/SecondStatus'
    Assert-ApiPoolEqual -Expected '7' -Actual $r2.Headers['Retry-After'] -Name 'Fake/HeaderLookupCaseInsensitive'

    $calls = @(Get-ApiPoolFakeTransportCall -Transport $fake)
    Assert-ApiPoolEqual -Expected 2 -Actual $calls.Count -Name 'Fake/CallsRecorded'
    Assert-ApiPoolEqual -Expected 'POST' -Actual $calls[0].Method -Name 'Fake/CallMethod'
    Assert-ApiPoolEqual -Expected 'apipool:messages/v1' -Actual $calls[0].Uri -Name 'Fake/CallUri'
    Assert-ApiPoolEqual -Expected 30 -Actual $calls[0].TimeoutSec -Name 'Fake/CallTimeout'
    Assert-ApiPoolEqual -Expected ((New-Object System.Text.UTF8Encoding($false)).GetByteCount($unicodeBody)) -Actual $calls[0].BodyBytes -Name 'Fake/BodyBytesAreUtf8Bytes'
    Assert-ApiPoolTrue -Condition ($calls[0].BodyBytes -gt $unicodeBody.Length) -Name 'Fake/NonAsciiBytesExceedChars'
    Assert-ApiPoolEqual -Expected (Get-ApiPoolSha256Hex -Text $unicodeBody) -Actual $calls[0].BodySha256 -Name 'Fake/BodySha256'
    Assert-ApiPoolEqual -Expected 'anthropic-version,content-type,x-api-key' -Actual ((@($calls[0].HeaderNames) | Sort-Object) -join ',') -Name 'Fake/HeaderNamesOnly'
    $serialized = ConvertTo-ApiPoolCanonicalJson -InputObject $calls
    Assert-ApiPoolTrue -Condition (-not $serialized.Contains('2023-06-01')) -Name 'Fake/NoHeaderValuesRecorded'
    Assert-ApiPoolTrue -Condition (-not $serialized.Contains('application/json')) -Name 'Fake/NoContentTypeValueRecorded'

    # --- Exhausted queue ---
    $err = Get-TrnErrorRecord { Send-ApiPoolTransportRequest -Transport $fake -Request (New-TrnRequest) -CredentialProvider $null }
    Assert-ApiPoolEqual -Expected 'TRANSPORT_ERROR' -Actual (Get-ApiPoolErrorCode -ErrorRecord $err) -Name 'Fake/ExhaustedCode'
    Assert-ApiPoolTrue -Condition ($err.Exception.Message.Contains('fake transport exhausted')) -Name 'Fake/ExhaustedMessage'
    Assert-ApiPoolEqual -Expected $false -Actual (Get-TrnSentFlag -ErrorRecord $err) -Name 'Fake/ExhaustedNotSent'

    # --- Scripted failures ---
    $failing = New-ApiPoolFakeTransport -Responses @(@{ Kind = 'timeout' }, @{ Kind = 'timeoutAfterSend' }, @{ Kind = 'transportError' })
    $e1 = Get-TrnErrorRecord { Send-ApiPoolTransportRequest -Transport $failing -Request (New-TrnRequest) -CredentialProvider $null }
    Assert-ApiPoolEqual -Expected 'TRANSPORT_TIMEOUT' -Actual (Get-ApiPoolErrorCode -ErrorRecord $e1) -Name 'Fake/TimeoutCode'
    Assert-ApiPoolEqual -Expected $false -Actual (Get-TrnSentFlag -ErrorRecord $e1) -Name 'Fake/TimeoutNotSent'
    $e2 = Get-TrnErrorRecord { Send-ApiPoolTransportRequest -Transport $failing -Request (New-TrnRequest) -CredentialProvider $null }
    Assert-ApiPoolEqual -Expected 'TRANSPORT_TIMEOUT' -Actual (Get-ApiPoolErrorCode -ErrorRecord $e2) -Name 'Fake/TimeoutAfterSendCode'
    Assert-ApiPoolEqual -Expected $true -Actual (Get-TrnSentFlag -ErrorRecord $e2) -Name 'Fake/TimeoutAfterSendWasSent'
    $e3 = Get-TrnErrorRecord { Send-ApiPoolTransportRequest -Transport $failing -Request (New-TrnRequest) -CredentialProvider $null }
    Assert-ApiPoolEqual -Expected 'TRANSPORT_ERROR' -Actual (Get-ApiPoolErrorCode -ErrorRecord $e3) -Name 'Fake/TransportErrorCode'
    Assert-ApiPoolEqual -Expected $false -Actual (Get-TrnSentFlag -ErrorRecord $e3) -Name 'Fake/TransportErrorNotSent'
    Assert-ApiPoolEqual -Expected 3 -Actual @(Get-ApiPoolFakeTransportCall -Transport $failing).Count -Name 'Fake/FailuresStillRecordCalls'

    # --- Credential is never resolved (offline build) ---
    $missingProvider = New-ApiPoolCredentialProvider -Kind Dpapi -SecretPath (Join-Path $trnSandbox 'does-not-exist.bin')
    Assert-ApiPoolThrows { Get-ApiPoolCredential -Provider $missingProvider } 'Credential/ProviderWouldThrowIfResolved' -ExpectedCode 'CREDENTIAL_NOT_FOUND'
    $noCred = New-ApiPoolFakeTransport -Responses @(@{ StatusCode = 200; Body = '{}' })
    $sentOk = $null
    $sendFailure = $null
    try { $sentOk = Send-ApiPoolTransportRequest -Transport $noCred -Request (New-TrnRequest) -CredentialProvider $missingProvider } catch { $sendFailure = $_ }
    Assert-ApiPoolTrue -Condition ($null -eq $sendFailure -and $null -ne $sentOk -and $sentOk.StatusCode -eq 200) -Name 'Credential/SendSucceedsWithUnresolvableProvider' -Detail ([string]$sendFailure)

    # A mock provider is instrumented through the redaction registry: resolving it would register the secret.
    $mockPlain = 'trn-mock-secret-' + [guid]::NewGuid().ToString('N')
    $mockSecure = New-Object System.Security.SecureString
    foreach ($ch in $mockPlain.ToCharArray()) { $mockSecure.AppendChar($ch) }
    $mockProvider = New-ApiPoolCredentialProvider -Kind Mock -MockSecret $mockSecure
    $mockTransport = New-ApiPoolFakeTransport -Responses @(@{ StatusCode = 200; Body = '{}' })
    [void](Send-ApiPoolTransportRequest -Transport $mockTransport -Request (New-TrnRequest) -CredentialProvider $mockProvider)
    Assert-ApiPoolEqual -Expected ('x ' + $mockPlain) -Actual (Protect-ApiPoolText -Text ('x ' + $mockPlain)) -Name 'Credential/MockSecretNeverRegistered'

    # --- Validation and unknown kinds ---
    $httpish = [pscustomobject]@{ Kind = 'Http' }
    Assert-ApiPoolThrows { Send-ApiPoolTransportRequest -Transport $httpish -Request (New-TrnRequest) -CredentialProvider $null } 'Send/UnknownKindInternalError' -ExpectedCode 'INTERNAL_ERROR'
    Assert-ApiPoolThrows { Send-ApiPoolTransportRequest -Transport ([pscustomobject]@{ Other = 1 }) -Request (New-TrnRequest) -CredentialProvider $null } 'Send/NoKindInternalError' -ExpectedCode 'INTERNAL_ERROR'
    $v = New-ApiPoolFakeTransport -Responses @()
    Assert-ApiPoolThrows { Send-ApiPoolTransportRequest -Transport $v -Request @{ Method = 'POST'; Body = 'x'; TimeoutSec = 5 } -CredentialProvider $null } 'Send/MissingUriInvalid' -ExpectedCode 'REQUEST_INVALID'
    Assert-ApiPoolThrows { Send-ApiPoolTransportRequest -Transport $v -Request 'not a hashtable' -CredentialProvider $null } 'Send/RequestNotHashtable' -ExpectedCode 'REQUEST_INVALID'
    Assert-ApiPoolThrows { New-ApiPoolFakeTransport -Responses @(@{ Kind = 'explode' }) } 'Fake/UnknownScriptedKind' -ExpectedCode 'INTERNAL_ERROR'
    Assert-ApiPoolThrows { New-ApiPoolFakeTransport -Responses @(@{ Body = 'x' }) } 'Fake/ScriptedItemNeedsStatus' -ExpectedCode 'INTERNAL_ERROR'
    Assert-ApiPoolThrows { New-ApiPoolFakeTransport -Responses @('text') } 'Fake/ScriptedItemMustBeHashtable' -ExpectedCode 'INTERNAL_ERROR'
    Assert-ApiPoolEqual -Expected 0 -Actual @(Get-ApiPoolFakeTransportCall -Transport $v).Count -Name 'Fake/InvalidRequestRecordsNothing'

    # --- Error messages never carry the request body or secrets ---
    $secretBody = New-ApiPoolFakeTransport -Responses @(@{ Kind = 'transportError' })
    $e4 = Get-TrnErrorRecord { Send-ApiPoolTransportRequest -Transport $secretBody -Request (New-TrnRequest -Body ('{"k":"' + $trnFakeKey + '"}')) -CredentialProvider $null }
    Assert-ApiPoolTrue -Condition (-not $e4.Exception.Message.Contains('TRNFAKEKEY')) -Name 'Fake/ErrorDoesNotEchoBody'
}
finally {
    Remove-ApiPoolTestSandbox -Path $trnSandbox
}
