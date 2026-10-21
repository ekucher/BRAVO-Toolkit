# Core suite. Dot-sourced by Invoke-ApiPoolTests.ps1.

$coreSandbox = New-ApiPoolTestSandbox
try {
    $coreRepoRoot = Split-Path -Parent (Split-Path -Parent $script:ApiRoot)

    function Write-CoreConfig {
        param([string]$Name, $Map)
        $p = Join-Path $coreSandbox ($Name + '.json')
        [System.IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $Map -Depth 6))
        return $p
    }

    # ---------------- Redaction ----------------
    $fakeKey = 'sk-' + 'ant-' + 'api03-' + 'FAKEFAKEFAKE1234'
    $r = Protect-ApiPoolText -Text ('key=' + $fakeKey + ' end')
    Assert-ApiPoolTrue (-not $r.Contains($fakeKey)) 'Redaction/SkAntKey'
    Assert-ApiPoolTrue ($r.Contains('sk-' + 'ant-***REDACTED***')) 'Redaction/SkAntMarker'
    $r = Protect-ApiPoolText -Text 'x-api-key: ZZZZsecretheadervalue99'
    Assert-ApiPoolTrue (-not $r.Contains('ZZZZsecretheadervalue99')) 'Redaction/XApiKeyHeader'
    $r = Protect-ApiPoolText -Text 'Authorization: Bearer abc.DEF-123_tokenvalue'
    Assert-ApiPoolTrue (-not $r.Contains('abc.DEF-123_tokenvalue')) 'Redaction/BearerToken'
    $r = Protect-ApiPoolText -Text 'value is OpaqueSecret-12345 here' -KnownSecret @('OpaqueSecret-12345')
    Assert-ApiPoolTrue (-not $r.Contains('OpaqueSecret-12345')) 'Redaction/KnownSecretParam'
    $r = Protect-ApiPoolText -Text 'short abc here' -KnownSecret @('abc')
    Assert-ApiPoolEqual 'short abc here' $r 'Redaction/KnownSecretTooShortIgnored'
    $reg = New-Object System.Security.SecureString
    foreach ($c in 'RegisteredValue-777'.ToCharArray()) { $reg.AppendChar($c) }
    Register-ApiPoolKnownSecret -Secret $reg
    Assert-ApiPoolTrue (-not (Protect-ApiPoolText -Text 'a RegisteredValue-777 b').Contains('RegisteredValue-777')) 'Redaction/RegisteredSecret'
    Clear-ApiPoolKnownSecret
    Assert-ApiPoolTrue ((Protect-ApiPoolText -Text 'a RegisteredValue-777 b').Contains('RegisteredValue-777')) 'Redaction/ClearedRegistry'
    foreach ($link in @(('https://' + 'claude' + '.ai/' + 'share/abc123'), ('https://' + 'chatgpt' + '.com/' + 'chat/xyz'), ('https://' + 'chat.openai' + '.com/' + 'share/q'), ('https://' + 'claude' + '.ai/' + 'code/session_abc'))) {
        $r = Protect-ApiPoolText -Text ('see ' + $link + ' now')
        Assert-ApiPoolTrue ($r -ceq 'see [chat-link-redacted] now') ('Redaction/ChatLink/' + $link)
    }
    Assert-ApiPoolTrue ([string]::IsNullOrEmpty((Protect-ApiPoolText -Text $null))) 'Redaction/NullYieldsEmpty'

    # ---------------- Structured errors ----------------
    $e = New-ApiPoolError -Code 'X_CODE' -Message ('failed with ' + $fakeKey) -Retryable -HttpStatus 429 -Details @{ k = $fakeKey }
    Assert-ApiPoolEqual 'X_CODE' $e.Code 'Error/Code'
    Assert-ApiPoolTrue ($e.Retryable -and $e.HttpStatus -eq 429) 'Error/RetryableAndStatus'
    Assert-ApiPoolTrue (-not $e.Message.Contains($fakeKey) -and -not $e.Details['k'].Contains($fakeKey)) 'Error/MessageAndDetailsRedacted'
    Assert-ApiPoolTrue ($e.PSObject.TypeNames -contains 'ApiPool.Error') 'Error/TypeName'
    $caught = $null
    try { Invoke-ApiPoolThrow -Code 'SOME_CODE' -Message 'boom' } catch { $caught = $_ }
    Assert-ApiPoolEqual 'SOME_CODE' (Get-ApiPoolErrorCode -ErrorRecord $caught) 'Error/GetCodeFromRecord'
    Assert-ApiPoolEqual 'ApiPool.SOME_CODE' $caught.FullyQualifiedErrorId 'Error/FullyQualifiedErrorId'
    Assert-ApiPoolTrue ($caught.Exception.Message.StartsWith('[SOME_CODE] ')) 'Error/MessagePrefix'
    Assert-ApiPoolEqual $null (Get-ApiPoolErrorCode -ErrorRecord ([System.Management.Automation.ErrorRecord](New-Object System.Management.Automation.ErrorRecord((New-Object System.Exception('plain')), 'x', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)))) 'Error/NoCodeForForeignError'

    # ---------------- Config ----------------
    $shipped = Read-ApiPoolConfig -Path (Join-Path $script:ConfigRoot 'apipool.defaults.json')
    Assert-ApiPoolEqual 'offline' $shipped.mode 'Config/ShippedModeOffline'
    Assert-ApiPoolEqual ([decimal]60) $shipped.budgetUsd 'Config/ShippedBudget'
    Assert-ApiPoolEqual 4 $shipped.retry.maxAttempts 'Config/ShippedRetry'
    Assert-ApiPoolEqual $null $shipped.stateRoot 'Config/ShippedHasNoStateRoot'

    $okPath = Write-CoreConfig 'ok' @{ schemaVersion = 1; mode = 'offline'; budgetUsd = 10.5; perJobUsd = 1; maxConcurrency = 3; stateRoot = (Join-Path $coreSandbox 'state'); leaseSeconds = 60 }
    $ok = Read-ApiPoolConfig -Path $okPath
    Assert-ApiPoolEqual ([decimal]10.5) $ok.budgetUsd 'Config/ValidBudget'
    Assert-ApiPoolEqual 3 $ok.maxConcurrency 'Config/ValidConcurrency'
    Assert-ApiPoolTrue ($ok.stateRoot -like '*\state') 'Config/ValidStateRootResolved'
    Assert-ApiPoolEqual 500 $ok.retry.baseDelayMs 'Config/MissingOptionalDefaulted'

    $legacy = Read-ApiPoolConfig -Path (Write-CoreConfig 'legacy' @{ mode = 'offline'; budgetUsd = 10 })
    Assert-ApiPoolEqual 1 $legacy.schemaVersion 'Config/LegacyMinimalSchemaDefaulted'
    Assert-ApiPoolEqual 120 $legacy.timeouts.requestTimeoutSec 'Config/LegacyMinimalTimeoutsDefaulted'
    Assert-ApiPoolEqual 250 $legacy.minRequestIntervalMs 'Config/LegacyMinimalIntervalDefaulted'
    $empty = Read-ApiPoolConfig -Path (Write-CoreConfig 'empty' @{})
    Assert-ApiPoolEqual ([decimal]2) $empty.perJobUsd 'Config/EmptyObjectAllDefaults'

    $live = Read-ApiPoolConfig -Path (Write-CoreConfig 'live' @{ mode = 'live' })
    Assert-ApiPoolEqual 'live' $live.mode 'Config/LiveModeParses'

    $ovr = Write-CoreConfig 'override' @{ retry = @{ maxAttempts = 2 } }
    $merged = Read-ApiPoolConfig -Path (Join-Path $script:ConfigRoot 'apipool.defaults.json') -OverridePath $ovr
    Assert-ApiPoolEqual 2 $merged.retry.maxAttempts 'Config/OverrideDeepMergeValue'
    Assert-ApiPoolEqual 500 $merged.retry.baseDelayMs 'Config/OverrideDeepMergeKeepsSiblings'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path $okPath -OverridePath (Write-CoreConfig 'ovbad' @{ bogus = 1 }) } 'Config/OverrideUnknownKey' -ExpectedCode 'CONFIG_UNKNOWN_KEY'

    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'u1' @{ bogus = 1 }) } 'Config/UnknownKey' -ExpectedCode 'CONFIG_UNKNOWN_KEY'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'u2' @{ retry = @{ foo = 1 } }) } 'Config/UnknownNestedKey' -ExpectedCode 'CONFIG_UNKNOWN_KEY'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'u3' @{ Mode = 'offline' }) } 'Config/KeyCaseMismatchRejected' -ExpectedCode 'CONFIG_UNKNOWN_KEY'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'm1' @{ mode = 'online' }) } 'Config/InvalidMode' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'm2' @{ mode = 'LIVE' }) } 'Config/ModeIsCaseSensitive' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'b0' @{ budgetUsd = 0 }) } 'Config/BudgetZero' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'b1' @{ budgetUsd = -5 }) } 'Config/BudgetNegative' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'b2' @{ budgetUsd = 1001 }) } 'Config/BudgetAboveMax' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'b3' @{ budgetUsd = '60' }) } 'Config/BudgetString' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'b4' @{ budgetUsd = $true }) } 'Config/BudgetBoolean' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'j1' @{ budgetUsd = 1; perJobUsd = 2 }) } 'Config/PerJobAboveBudget' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'j2' @{ perJobUsd = 0 }) } 'Config/PerJobZero' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'c0' @{ maxConcurrency = 0 }) } 'Config/ConcurrencyZero' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'c1' @{ maxConcurrency = 17 }) } 'Config/ConcurrencyTooHigh' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'c2' @{ maxConcurrency = 1.5 }) } 'Config/ConcurrencyNotInteger' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'l1' @{ leaseSeconds = 29 }) } 'Config/LeaseTooLow' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'r1' @{ retry = @{ baseDelayMs = 1000; maxDelayMs = 10 } }) } 'Config/MaxDelayBelowBase' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'r2' @{ retry = @{ maxAttempts = 0 } }) } 'Config/MaxAttemptsZero' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'r3' @{ retry = @{ maxAttempts = 11 } }) } 'Config/MaxAttemptsTooHigh' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'r4' @{ retry = @{ maxRetryAfterSec = 601 } }) } 'Config/RetryAfterTooHigh' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 'r5' @{ retry = 5 }) } 'Config/RetryNotObject' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 't1' @{ timeouts = @{ requestTimeoutSec = 601 } }) } 'Config/RequestTimeoutTooHigh' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 's1' @{ stateRoot = 'relative\state' }) } 'Config/RelativeStateRoot' -ExpectedCode 'STATE_PATH_FORBIDDEN'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 's2' @{ stateRoot = 'C:\ProgramData\BRAVO\State' }) } 'Config/ProgramDataStateRoot' -ExpectedCode 'STATE_PATH_FORBIDDEN'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 's3' @{ stateRoot = '%ProgramData%\BRAVO\x' }) } 'Config/ProgramDataEnvStateRoot' -ExpectedCode 'STATE_PATH_FORBIDDEN'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 's4' @{ stateRoot = (Join-Path $coreRepoRoot 'state') }) } 'Config/InsideRepoStateRoot' -ExpectedCode 'STATE_PATH_FORBIDDEN'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Write-CoreConfig 's5' @{ stateRoot = '' }) } 'Config/EmptyStateRoot' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path (Join-Path $coreSandbox 'missing.json') } 'Config/MissingFile' -ExpectedCode 'CONFIG_INVALID'
    $badJson = Join-Path $coreSandbox 'bad.json'
    [System.IO.File]::WriteAllText($badJson, '{ not json')
    Assert-ApiPoolThrows { Read-ApiPoolConfig -Path $badJson } 'Config/InvalidJson' -ExpectedCode 'CONFIG_INVALID'

    # ---------------- State root guard and context ----------------
    $stateOk = Assert-ApiPoolStateRoot -StateRoot (Join-Path $coreSandbox 'sr')
    Assert-ApiPoolTrue ($stateOk -like '*\sr') 'StateRoot/AcceptsSandbox'
    Assert-ApiPoolThrows { Assert-ApiPoolStateRoot -StateRoot (Join-Path $coreSandbox 'sr\x') -RepoRoot $coreSandbox } 'StateRoot/InsideExplicitRepoRoot' -ExpectedCode 'STATE_PATH_FORBIDDEN'
    Assert-ApiPoolThrows { Assert-ApiPoolStateRoot -StateRoot $coreSandbox -RepoRoot $coreSandbox } 'StateRoot/EqualsRepoRoot' -ExpectedCode 'STATE_PATH_FORBIDDEN'
    $outside = Assert-ApiPoolStateRoot -StateRoot (Join-Path $coreSandbox 'sr') -RepoRoot (Join-Path $coreSandbox 'other')
    Assert-ApiPoolTrue ($outside -like '*\sr') 'StateRoot/OutsideRepoRootAllowed'
    Assert-ApiPoolThrows { Assert-ApiPoolStateRoot -StateRoot '' } 'StateRoot/Empty' -ExpectedCode 'STATE_PATH_FORBIDDEN'
    Assert-ApiPoolThrows { Assert-ApiPoolStateRoot -StateRoot 'C:\ProgramData\BRAVO' } 'StateRoot/ProgramDataBravoItself' -ExpectedCode 'STATE_PATH_FORBIDDEN'
    Assert-ApiPoolThrows { Assert-ApiPoolStateRoot -StateRoot 'C:\ProgramData\bravo\State' } 'StateRoot/ProgramDataCaseInsensitive' -ExpectedCode 'STATE_PATH_FORBIDDEN'
    Assert-ApiPoolThrows { Assert-ApiPoolStateRoot -StateRoot 'C:\ProgramData\BRAVO\..\BRAVO\x' } 'StateRoot/DotDotNormalized' -ExpectedCode 'STATE_PATH_FORBIDDEN'

    # F1-2: UNC, device prefixes and reparse-point ancestors are forbidden.
    foreach ($bad in @('\\localhost\C$\x', '\\127.0.0.1\c$\x', '\\file-server-01\share\state', '//localhost/C$/x', '\\?\UNC\localhost\C$\x', '\\?\C:\x', '\\.\C:\x')) {
        Assert-ApiPoolThrows { Assert-ApiPoolStateRoot -StateRoot $bad } ('StateRoot/ForbiddenPrefix/' + $bad) -ExpectedCode 'STATE_PATH_FORBIDDEN'
    }
    $jTarget = Join-Path $coreSandbox 'junction-target'
    $jLink = Join-Path $coreSandbox 'junction-link'
    [void][System.IO.Directory]::CreateDirectory($jTarget)
    $null = & cmd.exe /c ('mklink /J "{0}" "{1}"' -f $jLink, $jTarget)
    Assert-ApiPoolTrue ([System.IO.Directory]::Exists($jLink)) 'StateRoot/JunctionFixtureCreated'
    try {
        Assert-ApiPoolThrows { Assert-ApiPoolStateRoot -StateRoot $jLink } 'StateRoot/JunctionItselfRejected' -ExpectedCode 'STATE_PATH_FORBIDDEN'
        Assert-ApiPoolThrows { Assert-ApiPoolStateRoot -StateRoot (Join-Path $jLink 'not\yet\created') } 'StateRoot/JunctionAncestorRejected' -ExpectedCode 'STATE_PATH_FORBIDDEN'
        Assert-ApiPoolThrows { Assert-ApiPoolSafePath -Path (Join-Path $jLink 'secret.bin') -Purpose 'SecretPath' } 'SafePath/JunctionAncestorRejected' -ExpectedCode 'STATE_PATH_FORBIDDEN'
    }
    finally {
        if ([System.IO.Directory]::Exists($jLink)) { [System.IO.Directory]::Delete($jLink, $false) }
    }
    Assert-ApiPoolTrue ([System.IO.Directory]::Exists($jTarget)) 'StateRoot/JunctionTargetSurvivesCleanup'
    Assert-ApiPoolTrue ((Assert-ApiPoolStateRoot -StateRoot (Join-Path $coreSandbox 'plain\deep')) -like '*\plain\deep') 'StateRoot/OrdinaryNestedPathAccepted'
    $safeCaught = $null
    try { Assert-ApiPoolSafePath -Path 'rel\secret.bin' -Purpose 'SecretPath' } catch { $safeCaught = $_ }
    Assert-ApiPoolTrue ($null -ne $safeCaught -and $safeCaught.Exception.Message.Contains('SecretPath')) 'SafePath/PurposeInMessage'

    # F1-4: redaction of secret-bearing header/parameter names in all common forms.
    $rv = 'Qq' + 'Zz-fake-' + 'value-4242'
    $redactForms = @(
        ('x-api-key: ' + $rv), ('X-API-KEY: ' + $rv), ('anthropic-api-key: ' + $rv), ('api_key=' + $rv), ('api-key: ' + $rv),
        ('apikey=' + $rv), ('authorization: ' + $rv), ('Authorization: Bearer ' + $rv), ('Authorization: Basic ' + $rv),
        ('{"x-api-key":"' + $rv + '"}'), ('{"api_key": "' + $rv + '"}'), ('{"x-api-key":["' + $rv + '"]}'),
        ("{'x-api-key': '" + $rv + "'}"), ("'anthropic-api-key'='" + $rv + "'"),
        ('GET /v1?x-api-key%3A' + $rv + '&a=1'), ('GET /v1?api_key%3D' + $rv + '&a=1'), ('GET /v1?api_key=' + $rv + '&a=1'),
        ('{"authorization":"Bearer ' + $rv + '"}')
    )
    foreach ($form in $redactForms) {
        $out = Protect-ApiPoolText -Text $form
        Assert-ApiPoolTrue (-not $out.Contains($rv)) ('Redaction/Form/' + $form.Replace($rv, '<V>')) ('leaked: ' + $out.Replace($rv, '<V>'))
    }
    $spaced = Protect-ApiPoolText -Text ('{"api-key":"two words ' + $rv + ' end","next":"keep"}')
    Assert-ApiPoolEqual '{"api-key":"***REDACTED***","next":"keep"}' $spaced 'Redaction/QuotedValueWithSpacesUpToClosingQuote'
    $spacedSingle = Protect-ApiPoolText -Text ("x-api-key = 'two words " + $rv + "' tail")
    Assert-ApiPoolEqual "x-api-key = '***REDACTED***' tail" $spacedSingle 'Redaction/SingleQuotedValueWithSpaces'
    Assert-ApiPoolEqual 'monkey: banana status=ok' (Protect-ApiPoolText -Text 'monkey: banana status=ok') 'Redaction/UnrelatedTextUntouched'

    $ctx = New-ApiPoolContext -StateRoot (Join-Path $coreSandbox 'ctx') -Config $ok -Registry $null -Transport $null -CredentialProvider $null
    Assert-ApiPoolTrue ($ctx.StateRoot -like '*\ctx' -and $ctx.PSObject.TypeNames -contains 'ApiPool.Context') 'Context/Created'
    Assert-ApiPoolTrue ((& $ctx.Clock) -is [datetime]) 'Context/DefaultClock'
    Assert-ApiPoolThrows { New-ApiPoolContext -StateRoot (Join-Path $coreSandbox 'ctx') -Config $live } 'Context/LiveModeRefused' -ExpectedCode 'LIVE_DISABLED_IN_BUILD'
    Assert-ApiPoolThrows { New-ApiPoolContext -StateRoot 'rel' -Config $ok } 'Context/RelativeStateRootRefused' -ExpectedCode 'STATE_PATH_FORBIDDEN'

    # ---------------- Atomic write ----------------
    $target = Join-Path $coreSandbox 'atomic\file.txt'
    Write-ApiPoolFileAtomic -Path $target -Content 'first'
    Assert-ApiPoolEqual 'first' ([System.IO.File]::ReadAllText($target)) 'Atomic/NewFile'
    $bytes = [System.IO.File]::ReadAllBytes($target)
    Assert-ApiPoolTrue ($bytes.Length -eq 5 -and $bytes[0] -eq 102) 'Atomic/NoBom'
    Write-ApiPoolFileAtomic -Path $target -Content ('second ' + [char]0x0436)
    Assert-ApiPoolEqual ('second ' + [char]0x0436) ([System.IO.File]::ReadAllText($target)) 'Atomic/ReplaceUtf8'
    Assert-ApiPoolEqual 1 @(Get-ChildItem -LiteralPath (Join-Path $coreSandbox 'atomic') -Force).Count 'Atomic/NoTempLeftovers'
    Write-ApiPoolBytesAtomic -Path $target -Bytes ([byte[]](1, 2, 3))
    Assert-ApiPoolEqual '1,2,3' ([System.IO.File]::ReadAllBytes($target) -join ',') 'Atomic/BytesExact'
    $dirTarget = Join-Path $coreSandbox 'atomic\adir'
    [void][System.IO.Directory]::CreateDirectory($dirTarget)
    Assert-ApiPoolThrows { Write-ApiPoolFileAtomic -Path $dirTarget -Content 'x' } 'Atomic/FailureThrows'
    Assert-ApiPoolEqual 2 @(Get-ChildItem -LiteralPath (Join-Path $coreSandbox 'atomic') -Force).Count 'Atomic/TempCleanedOnFailure'

    # ---------------- Durable line append ----------------
    $ledgerLike = Join-Path $coreSandbox 'lines\x.jsonl'
    Add-ApiPoolLineDurable -Path $ledgerLike -Line '{"a":1}'
    Add-ApiPoolLineDurable -Path $ledgerLike -Line ('second ' + [char]0x0436)
    $lineBytes = [System.IO.File]::ReadAllBytes($ledgerLike)
    Assert-ApiPoolTrue ($lineBytes[0] -eq 123) 'Line/NoBom'
    Assert-ApiPoolEqual ("{`"a`":1}`nsecond " + [char]0x0436 + "`n") ([System.Text.Encoding]::UTF8.GetString($lineBytes)) 'Line/AppendedWithLf'
    Assert-ApiPoolThrows { Add-ApiPoolLineDurable -Path $ledgerLike -Line "a`nb" } 'Line/RejectsEmbeddedNewline' -ExpectedCode 'LINE_INVALID'

    # ---------------- File locks ----------------
    $lockPath = Join-Path $coreSandbox 'locks\a.lock'
    $h1 = Enter-ApiPoolFileLock -Path $lockPath -TimeoutMs 500
    Assert-ApiPoolTrue ($null -ne $h1) 'Lock/Acquired'
    $script:CoreSleepCalls = 0
    $countingSleep = { param($ms) $script:CoreSleepCalls++ }
    Assert-ApiPoolThrows { Enter-ApiPoolFileLock -Path $lockPath -TimeoutMs 100 -Sleep $countingSleep } 'Lock/TimeoutWhileHeld' -ExpectedCode 'LEDGER_LOCK_TIMEOUT'
    Assert-ApiPoolTrue ($script:CoreSleepCalls -ge 1) 'Lock/InjectedSleepUsed'
    Assert-ApiPoolThrows { Enter-ApiPoolFileLock -Path $lockPath -TimeoutMs 0 -TimeoutCode 'SLOT_TIMEOUT' } 'Lock/CustomTimeoutCode' -ExpectedCode 'SLOT_TIMEOUT'
    Exit-ApiPoolFileLock -Handle $h1
    $h2 = Enter-ApiPoolFileLock -Path $lockPath -TimeoutMs 500
    Assert-ApiPoolTrue ($null -ne $h2) 'Lock/ReacquiredAfterRelease'
    Exit-ApiPoolFileLock -Handle $h2
    Exit-ApiPoolFileLock -Handle $h2
    Assert-ApiPoolTrue $true 'Lock/DoubleExitIsHarmless'

    # Cross-process: a child powershell.exe holds the lock; we wait for its own exit (never kill).
    $helper = Join-Path (Join-Path $script:TestsRoot 'helpers') 'Hold-ApiPoolLock.ps1'
    $corePath = Join-Path $script:ModulesRoot 'ApiPool.Core.psm1'
    $childLock = Join-Path $coreSandbox 'child.lock'
    $ready = Join-Path $coreSandbox 'ready.flag'
    $release = Join-Path $coreSandbox 'release.flag'
    $argText = '-NoProfile -File "{0}" -CorePath "{1}" -LockPath "{2}" -ReadyFile "{3}" -ReleaseFile "{4}" -Mode Release' -f $helper, $corePath, $childLock, $ready, $release
    $child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argText -PassThru -WindowStyle Hidden
    $waited = 0
    while (-not (Test-Path -LiteralPath $ready) -and $waited -lt 30000 -and -not $child.HasExited) { Start-Sleep -Milliseconds 100; $waited += 100 }
    Assert-ApiPoolTrue (Test-Path -LiteralPath $ready) 'Lock/ChildProcessHoldsLock'
    if (Test-Path -LiteralPath $ready) {
        Assert-ApiPoolThrows { Enter-ApiPoolFileLock -Path $childLock -TimeoutMs 300 } 'Lock/CrossProcessTimeout' -ExpectedCode 'LEDGER_LOCK_TIMEOUT'
    }
    [System.IO.File]::WriteAllText($release, 'go')
    $exited = $child.WaitForExit(30000)
    Assert-ApiPoolTrue $exited 'Lock/ChildExitedOnItsOwn'
    if ($exited) {
        Assert-ApiPoolEqual 0 $child.ExitCode 'Lock/ChildExitCodeZero'
        $h3 = Enter-ApiPoolFileLock -Path $childLock -TimeoutMs 1000
        Assert-ApiPoolTrue ($null -ne $h3) 'Lock/AcquiredAfterChildReleased'
        Exit-ApiPoolFileLock -Handle $h3
    }

    # Process death without release: the OS frees the handle.
    $crashReady = Join-Path $coreSandbox 'ready2.flag'
    $crashLock = Join-Path $coreSandbox 'crash.lock'
    $argText2 = '-NoProfile -File "{0}" -CorePath "{1}" -LockPath "{2}" -ReadyFile "{3}" -Mode Crash' -f $helper, $corePath, $crashLock, $crashReady
    $child2 = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argText2 -PassThru -WindowStyle Hidden
    $exited2 = $child2.WaitForExit(30000)
    Assert-ApiPoolTrue ($exited2 -and (Test-Path -LiteralPath $crashReady)) 'Lock/CrashChildAcquiredAndExited'
    if ($exited2) {
        $h4 = Enter-ApiPoolFileLock -Path $crashLock -TimeoutMs 1000
        Assert-ApiPoolTrue ($null -ne $h4) 'Lock/AcquirableAfterOwnerDied'
        Exit-ApiPoolFileLock -Handle $h4
    }

    # ---------------- Hashing and canonical JSON ----------------
    Assert-ApiPoolEqual 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' (Get-ApiPoolSha256Hex -Text 'abc') 'Hash/Sha256Abc'
    $j1 = ConvertTo-ApiPoolCanonicalJson -InputObject @{ b = 1; a = @{ z = $true; y = 'x"y' }; c = @(1, [decimal]2.50) }
    Assert-ApiPoolEqual '{"a":{"y":"x\"y","z":true},"b":1,"c":[1,2.5]}' $j1 'Canonical/ExactOutput'
    $ordered = New-Object System.Collections.Specialized.OrderedDictionary
    $ordered['c'] = @(1, 2.5); $ordered['a'] = [ordered]@{ y = 'x"y'; z = $true }; $ordered['b'] = 1
    Assert-ApiPoolEqual $j1 (ConvertTo-ApiPoolCanonicalJson -InputObject $ordered) 'Canonical/KeyOrderIndependent'
    $pco = [pscustomobject]@{ b = 1; a = [pscustomobject]@{ z = $true; y = 'x"y' }; c = @(1, 2.5) }
    Assert-ApiPoolEqual $j1 (ConvertTo-ApiPoolCanonicalJson -InputObject $pco) 'Canonical/PsObjectSameAsDictionary'
    Assert-ApiPoolEqual '[2,1]' (ConvertTo-ApiPoolCanonicalJson -InputObject @(2, 1)) 'Canonical/ArrayOrderPreserved'
    Assert-ApiPoolEqual 'null' (ConvertTo-ApiPoolCanonicalJson -InputObject $null) 'Canonical/Null'
    Assert-ApiPoolEqual '0.1' (ConvertTo-ApiPoolCanonicalJson -InputObject 0.1) 'Canonical/DoubleInvariant'

    # ---------------- Static guarantees on shipped files ----------------
    $forbiddenPatterns = @('Invoke-WebRequest', 'Invoke-RestMethod', 'System\.Net', 'HttpClient', 'HttpWebRequest', 'WebClient', 'api\.anthropic\.com', 'ANTHROPIC_API_KEY', 'System\.Threading\.(Mutex|Semaphore)', '::new\(', 'Invoke-Expression')
    foreach ($moduleFile in @(Get-ChildItem -LiteralPath $script:ModulesRoot -Filter '*.psm1')) {
        $text = [System.IO.File]::ReadAllText($moduleFile.FullName)
        $hits = @($forbiddenPatterns | Where-Object { $text -match $_ })
        Assert-ApiPoolEqual 0 $hits.Count ('Static/NoForbiddenReferences/' + $moduleFile.Name)
        Assert-ApiPoolTrue ($text -match 'Set-StrictMode -Version Latest') ('Static/StrictMode/' + $moduleFile.Name)
        Assert-ApiPoolTrue ($text -notmatch 'Import-Module') ('Static/NoCrossImport/' + $moduleFile.Name)
    }
}
finally {
    Remove-ApiPoolTestSandbox -Path $coreSandbox
}
