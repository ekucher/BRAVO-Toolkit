# Credentials suite. Dot-sourced by Invoke-ApiPoolTests.ps1.

$credSandbox = New-ApiPoolTestSandbox
try {
    # Fixture secrets are assembled at runtime; none of them is a real key.
    $credFake = 'sk-' + 'ant-' + 'test-FAKE-' + '0000000000'
    $credFakeB = 'sk-' + 'ant-' + 'test-FAKE-' + '1111111111'
    $credOpaque = 'PlainTokenValue-987654'

    function New-CredTestSecure {
        param([string]$Text)
        $s = New-Object System.Security.SecureString
        foreach ($c in $Text.ToCharArray()) { $s.AppendChar($c) }
        $s.MakeReadOnly()
        return $s
    }

    function ConvertFrom-CredTestSecure {
        param([System.Security.SecureString]$Secure)
        $b = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    }

    function Get-CredTestPlain {
        param($Provider)
        $s = Get-ApiPoolCredential -Provider $Provider
        return (ConvertFrom-CredTestSecure -Secure $s)
    }

    $dpapiPath = Join-Path $credSandbox 'creds\anthropic-test.dpapi'
    $provider = New-ApiPoolCredentialProvider -Kind Dpapi -SecretPath $dpapiPath

    # ---------------- Missing / empty / corrupted ----------------
    Assert-ApiPoolThrows { Get-ApiPoolCredential -Provider $provider } 'Dpapi/MissingFile' -ExpectedCode 'CREDENTIAL_NOT_FOUND'
    $t = Test-ApiPoolCredential -Provider $provider
    Assert-ApiPoolTrue ((-not $t.Ok) -and $t.Code -ceq 'CREDENTIAL_NOT_FOUND') 'Dpapi/TestReportsMissing'
    $caughtMissing = $null
    try { Get-ApiPoolCredential -Provider $provider } catch { $caughtMissing = $_ }
    Assert-ApiPoolTrue ($caughtMissing.Exception.Message.Contains($dpapiPath)) 'Dpapi/MissingMessageNamesPath'

    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $dpapiPath))
    [System.IO.File]::WriteAllBytes($dpapiPath, [byte[]]@())
    Assert-ApiPoolThrows { Get-ApiPoolCredential -Provider $provider } 'Dpapi/EmptyFile' -ExpectedCode 'CREDENTIAL_NOT_FOUND'
    $junk = New-Object 'byte[]' 80
    for ($i = 0; $i -lt $junk.Length; $i++) { $junk[$i] = [byte](($i * 37 + 11) % 256) }
    [System.IO.File]::WriteAllBytes($dpapiPath, $junk)
    Assert-ApiPoolThrows { Get-ApiPoolCredential -Provider $provider } 'Dpapi/CorruptedFile' -ExpectedCode 'CREDENTIAL_UNREADABLE'
    $t = Test-ApiPoolCredential -Provider $provider
    Assert-ApiPoolTrue ((-not $t.Ok) -and $t.Code -ceq 'CREDENTIAL_UNREADABLE') 'Dpapi/TestReportsUnreadable'
    Remove-Item -LiteralPath $dpapiPath -Force

    # ---------------- Round trip ----------------
    Set-ApiPoolCredential -SecretPath $dpapiPath -Secret (New-CredTestSecure $credFake)
    Assert-ApiPoolTrue (Test-Path -LiteralPath $dpapiPath) 'Dpapi/FileCreated'
    $raw = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($dpapiPath))
    Assert-ApiPoolTrue (-not $raw.Contains('FAKE')) 'Dpapi/FileIsNotPlaintext'
    Assert-ApiPoolEqual $credFake (Get-CredTestPlain $provider) 'Dpapi/RoundTrip'
    $t = Test-ApiPoolCredential -Provider $provider
    Assert-ApiPoolTrue ($t.Ok -and $t.Code -ceq 'OK') 'Dpapi/TestOk'
    Assert-ApiPoolTrue ($null -eq $t.PSObject.Properties['Secret'] -and @($t.PSObject.Properties).Count -eq 2) 'Dpapi/TestDoesNotReturnSecret'
    Assert-ApiPoolEqual 0 @(Get-ChildItem -LiteralPath (Split-Path -Parent $dpapiPath) -Force | Where-Object { $_.Name -like '*.tmp' }).Count 'Dpapi/NoTempLeftovers'

    $meta = Get-Content -LiteralPath ($dpapiPath + '.meta.json') -Raw | ConvertFrom-Json
    $expectedFingerprint = (Get-ApiPoolSha256Hex -Text $credFake).Substring(0, 8)
    Assert-ApiPoolEqual $expectedFingerprint $meta.fingerprint 'Meta/Fingerprint'
    Assert-ApiPoolTrue ($meta.rotatedAtUtc -match '^\d{4}-\d{2}-\d{2}T') 'Meta/RotatedAtUtc'
    Assert-ApiPoolEqual 2 @($meta.PSObject.Properties).Count 'Meta/OnlyTwoFields'
    Assert-ApiPoolTrue (-not (Get-Content -LiteralPath ($dpapiPath + '.meta.json') -Raw).Contains($credFake)) 'Meta/NoSecret'

    # ---------------- Entropy ----------------
    $entropy = [System.Text.Encoding]::UTF8.GetBytes('test-entropy')
    $entPath = Join-Path $credSandbox 'creds\entropy.dpapi'
    Set-ApiPoolCredential -SecretPath $entPath -Secret (New-CredTestSecure $credFake) -Entropy $entropy
    $withEntropy = New-ApiPoolCredentialProvider -Kind Dpapi -SecretPath $entPath -Entropy $entropy
    Assert-ApiPoolEqual $credFake (Get-CredTestPlain $withEntropy) 'Dpapi/EntropyRoundTrip'
    $noEntropy = New-ApiPoolCredentialProvider -Kind Dpapi -SecretPath $entPath
    Assert-ApiPoolThrows { Get-ApiPoolCredential -Provider $noEntropy } 'Dpapi/WrongEntropyUnreadable' -ExpectedCode 'CREDENTIAL_UNREADABLE'

    # ---------------- Format validation ----------------
    Assert-ApiPoolThrows { Set-ApiPoolCredential -SecretPath (Join-Path $credSandbox 'creds\short.dpapi') -Secret (New-CredTestSecure 'short') } 'Dpapi/SetRejectsShortSecret' -ExpectedCode 'CREDENTIAL_INVALID_FORMAT'
    Assert-ApiPoolThrows { Set-ApiPoolCredential -SecretPath (Join-Path $credSandbox 'creds\ws.dpapi') -Secret (New-CredTestSecure 'has space inside secret') } 'Dpapi/SetRejectsWhitespace' -ExpectedCode 'CREDENTIAL_INVALID_FORMAT'
    Assert-ApiPoolTrue (-not (Test-Path -LiteralPath (Join-Path $credSandbox 'creds\short.dpapi'))) 'Dpapi/RejectedSecretNotWritten'
    $badFmt = Join-Path $credSandbox 'creds\badformat.dpapi'
    $badBytes = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes('contains white space here'), $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes($badFmt, $badBytes)
    Assert-ApiPoolThrows { Get-ApiPoolCredential -Provider (New-ApiPoolCredentialProvider -Kind Dpapi -SecretPath $badFmt) } 'Dpapi/DecryptedBadFormat' -ExpectedCode 'CREDENTIAL_INVALID_FORMAT'
    $nlPath = Join-Path $credSandbox 'creds\newline.dpapi'
    $nlBytes = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes($credFake + "`r`n"), $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes($nlPath, $nlBytes)
    Assert-ApiPoolEqual $credFake (Get-CredTestPlain (New-ApiPoolCredentialProvider -Kind Dpapi -SecretPath $nlPath)) 'Dpapi/TrailingNewlineTrimmed'

    # ---------------- Rotation ----------------
    Set-ApiPoolCredential -SecretPath $dpapiPath -Secret (New-CredTestSecure $credFakeB)
    Assert-ApiPoolTrue (Test-Path -LiteralPath ($dpapiPath + '.previous')) 'Rotation/PreviousKept'
    Assert-ApiPoolEqual $credFakeB (Get-CredTestPlain $provider) 'Rotation/NewActive'
    $prevProvider = New-ApiPoolCredentialProvider -Kind Dpapi -SecretPath ($dpapiPath + '.previous')
    Assert-ApiPoolEqual $credFake (Get-CredTestPlain $prevProvider) 'Rotation/PreviousHoldsOldSecret'
    $meta2 = Get-Content -LiteralPath ($dpapiPath + '.meta.json') -Raw | ConvertFrom-Json
    Assert-ApiPoolEqual (Get-ApiPoolSha256Hex -Text $credFakeB).Substring(0, 8) $meta2.fingerprint 'Rotation/MetaUpdated'
    Restore-ApiPoolPreviousCredential -SecretPath $dpapiPath
    Assert-ApiPoolEqual $credFake (Get-CredTestPlain $provider) 'Rotation/RestoreSwapsBack'
    Assert-ApiPoolEqual $credFakeB (Get-CredTestPlain $prevProvider) 'Rotation/RestoreKeepsReplacedAsPrevious'
    $meta3 = Get-Content -LiteralPath ($dpapiPath + '.meta.json') -Raw | ConvertFrom-Json
    Assert-ApiPoolEqual $expectedFingerprint $meta3.fingerprint 'Rotation/RestoreMetaUpdated'

    Assert-ApiPoolThrows { Restore-ApiPoolPreviousCredential -SecretPath (Join-Path $credSandbox 'creds\none.dpapi') } 'Rotation/RestoreWithoutPrevious' -ExpectedCode 'CREDENTIAL_NOT_FOUND'
    # Corrupt previous must not replace a good current secret.
    [System.IO.File]::WriteAllBytes(($dpapiPath + '.previous'), $junk)
    Assert-ApiPoolThrows { Restore-ApiPoolPreviousCredential -SecretPath $dpapiPath } 'Rotation/RestoreCorruptPreviousRefused' -ExpectedCode 'CREDENTIAL_UNREADABLE'
    Assert-ApiPoolEqual $credFake (Get-CredTestPlain $provider) 'Rotation/CurrentUntouchedAfterFailedRestore'
    # Rotation failure (previous slot blocked by a directory) keeps the current secret.
    Remove-Item -LiteralPath ($dpapiPath + '.previous') -Force
    [void][System.IO.Directory]::CreateDirectory($dpapiPath + '.previous')
    Assert-ApiPoolThrows { Set-ApiPoolCredential -SecretPath $dpapiPath -Secret (New-CredTestSecure $credFakeB) } 'Rotation/FailureReported' -ExpectedCode 'CREDENTIAL_ROTATION_FAILED' -MessageMustNotContain @($credFakeB)
    Assert-ApiPoolEqual $credFake (Get-CredTestPlain $provider) 'Rotation/CurrentUntouchedAfterFailedRotation'

    # ---------------- F1-3: fingerprint value is stable (byte-based computation) ----------------
    Assert-ApiPoolEqual '14e16c60' $meta3.fingerprint 'Meta/FingerprintMatchesPrecomputedSha256Prefix'

    # ---------------- F1-5: owner-only ACL on written files ----------------
    $aclPath = Join-Path $credSandbox 'creds\acl-test.dpapi'
    Set-ApiPoolCredential -SecretPath $aclPath -Secret (New-CredTestSecure $credFake)
    Set-ApiPoolCredential -SecretPath $aclPath -Secret (New-CredTestSecure $credFakeB)
    Restore-ApiPoolPreviousCredential -SecretPath $aclPath
    $meSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $systemSid = 'S-1-5-18'
    foreach ($aclFile in @($aclPath, ($aclPath + '.previous'), ($aclPath + '.meta.json'))) {
        $acl = [System.IO.File]::GetAccessControl($aclFile)
        $leaf = Split-Path -Leaf $aclFile
        Assert-ApiPoolTrue $acl.AreAccessRulesProtected ('Acl/InheritanceDisabled/' + $leaf)
        $sids = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
        Assert-ApiPoolTrue ($sids -contains $meSid) ('Acl/CurrentUserPresent/' + $leaf)
        Assert-ApiPoolEqual 0 @($sids | Where-Object { $_ -ne $meSid -and $_ -ne $systemSid }).Count ('Acl/OnlyOwnerAndSystem/' + $leaf)
        $inherited = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | Where-Object { $_.IsInherited })
        Assert-ApiPoolEqual 0 $inherited.Count ('Acl/NoInheritedRules/' + $leaf)
    }

    # ---------------- F1-5: SecretPath guard ----------------
    $credRepoRoot = Split-Path -Parent (Split-Path -Parent $script:ApiRoot)
    $badSecretPaths = @('creds\relative.dpapi', '\\localhost\C$\x\s.dpapi', '//localhost/C$/x/s.dpapi', '\\?\C:\x\s.dpapi', '\\.\C:\x\s.dpapi', 'C:\ProgramData\BRAVO\s.dpapi', (Join-Path $credRepoRoot 'x\s.dpapi'))
    foreach ($bad in $badSecretPaths) {
        $badSecure = New-CredTestSecure $credFake
        Assert-ApiPoolThrows { New-ApiPoolCredentialProvider -Kind Dpapi -SecretPath $bad } ('SecretPath/Provider/' + $bad) -ExpectedCode 'STATE_PATH_FORBIDDEN'
        Assert-ApiPoolThrows { Set-ApiPoolCredential -SecretPath $bad -Secret $badSecure } ('SecretPath/Set/' + $bad) -ExpectedCode 'STATE_PATH_FORBIDDEN'
        Assert-ApiPoolThrows { Restore-ApiPoolPreviousCredential -SecretPath $bad } ('SecretPath/Restore/' + $bad) -ExpectedCode 'STATE_PATH_FORBIDDEN'
    }

    # ---------------- Mock provider ----------------
    $mock = New-ApiPoolCredentialProvider -Kind Mock -MockSecret (New-CredTestSecure $credFake)
    Assert-ApiPoolEqual 'Mock' $mock.Kind 'Mock/Kind'
    Assert-ApiPoolEqual $credFake (Get-CredTestPlain $mock) 'Mock/ReturnsSecret'
    $t = Test-ApiPoolCredential -Provider $mock
    Assert-ApiPoolTrue $t.Ok 'Mock/TestOk'
    $mockBad = New-ApiPoolCredentialProvider -Kind Mock -MockSecret (New-Object System.Security.SecureString)
    Assert-ApiPoolThrows { Get-ApiPoolCredential -Provider $mockBad } 'Mock/EmptySecretInvalid' -ExpectedCode 'CREDENTIAL_INVALID_FORMAT'
    Assert-ApiPoolThrows { New-ApiPoolCredentialProvider -Kind Dpapi } 'Provider/DpapiRequiresPath' -ExpectedCode 'CREDENTIAL_NOT_FOUND'
    Assert-ApiPoolThrows { New-ApiPoolCredentialProvider -Kind Mock } 'Provider/MockRequiresSecret' -ExpectedCode 'CREDENTIAL_NOT_FOUND'

    # ---------------- No plaintext exposure ----------------
    $exposures = @(
        [string]$mock, "$mock", $mock.Describe(), ($mock | Out-String), ($mock | Format-List * | Out-String), ($mock | ConvertTo-Json -Depth 4),
        [string]$provider, $provider.Describe(), ($provider | Out-String), ($provider | ConvertTo-Json -Depth 4)
    )
    $leaks = @($exposures | Where-Object { $_.Contains($credFake) -or $_.Contains('FAKE-0000') })
    Assert-ApiPoolEqual 0 $leaks.Count 'Exposure/ProviderNeverShowsSecret'
    Assert-ApiPoolEqual 'Kind=Mock' $mock.Describe() 'Exposure/MockDescribe'
    Assert-ApiPoolTrue ($provider.Describe() -like 'Kind=Dpapi SecretPath=*') 'Exposure/DpapiDescribe'
    $errTexts = New-Object System.Collections.ArrayList
    foreach ($sb in @({ Get-ApiPoolCredential -Provider $prevProvider; Get-ApiPoolCredential -Provider (New-ApiPoolCredentialProvider -Kind Dpapi -SecretPath (Join-Path $credSandbox 'creds\nothing.dpapi')) }, { Get-ApiPoolCredential -Provider $noEntropy }, { Get-ApiPoolCredential -Provider (New-ApiPoolCredentialProvider -Kind Dpapi -SecretPath $badFmt) })) {
        try { & $sb } catch { [void]$errTexts.Add($_.Exception.Message) }
    }
    Assert-ApiPoolTrue ($errTexts.Count -ge 3) 'Exposure/ErrorsWereProduced'
    Assert-ApiPoolEqual 0 @($errTexts | Where-Object { $_.Contains($credFake) -or $_.Contains($credFakeB) -or $_.Contains('white space') }).Count 'Exposure/ErrorMessagesHaveNoSecret'

    # ---------------- Redaction of registered secrets ----------------
    Clear-ApiPoolKnownSecret
    Assert-ApiPoolTrue ((Protect-ApiPoolText -Text ('x ' + $credOpaque + ' y')).Contains($credOpaque)) 'Redaction/OpaqueVisibleBeforeRegistration'
    $opaqueProvider = New-ApiPoolCredentialProvider -Kind Mock -MockSecret (New-CredTestSecure $credOpaque)
    $got = Get-ApiPoolCredential -Provider $opaqueProvider
    $got.Dispose()
    Assert-ApiPoolTrue (-not (Protect-ApiPoolText -Text ('x ' + $credOpaque + ' y')).Contains($credOpaque)) 'Redaction/RegisteredOnGet'
    Clear-ApiPoolKnownSecret
    Assert-ApiPoolTrue (-not (Protect-ApiPoolText -Text ('k ' + $credFake)).Contains($credFake)) 'Redaction/PatternStillCatchesKeyAfterClear'
    $viaDpapi = Get-CredTestPlain $provider
    Assert-ApiPoolTrue (-not (Protect-ApiPoolText -Text ('k ' + $viaDpapi)).Contains($viaDpapi)) 'Redaction/DpapiSecretRedacted'
    Clear-ApiPoolKnownSecret
}
finally {
    Clear-ApiPoolKnownSecret
    Remove-ApiPoolTestSandbox -Path $credSandbox
}
