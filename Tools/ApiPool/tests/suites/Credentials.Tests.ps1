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
Assert-ApiPoolTestPathInSandbox -Path $dpapiPath
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
    # Real-system forbidden paths are passed ONLY to the pure validator (never to a writer). Writer refusal is
    # covered below with sandbox-structural paths only.
    $credRepoRoot = Split-Path -Parent (Split-Path -Parent $script:ApiRoot)
    $realBadPaths = @('\\localhost\C$\x\s.dpapi', '//localhost/C$/x/s.dpapi', '\\127.0.0.1\c$\x\s.dpapi', '\\?\C:\x\s.dpapi', '\\.\C:\x\s.dpapi', 'C:\ProgramData\BRAVO\s.dpapi', (Join-Path $credRepoRoot 'x\s.dpapi'), 'creds\relative.dpapi', '.\relative.dpapi', 'relative.dpapi')
    foreach ($bad in $realBadPaths) {
        Assert-ApiPoolForbiddenPathRejected -Path $bad -Name ('SecretPath/ValidatorRejects/' + $bad)
    }
    # Fake repo root inside the sandbox: the validator rejects a path under it (pure check).
    $credFakeRepo = Join-Path $credSandbox 'fake-repo'
    Assert-ApiPoolForbiddenPathRejected -Path (Join-Path $credFakeRepo 'sub\s.dpapi') -RepoRoot $credFakeRepo -Name 'SecretPath/ValidatorRejects/InsideFakeRepoRoot'
    # Writers refuse a junction ancestor that lives INSIDE the sandbox (a regressed guard would write into the sandbox only).
    $credJTarget = Join-Path $credSandbox 'j-target'
    $credJLink = Join-Path $credSandbox 'j-link'
    [void][System.IO.Directory]::CreateDirectory($credJTarget)
    $null = & cmd.exe /c ('mklink /J "{0}" "{1}"' -f $credJLink, $credJTarget)
    Assert-ApiPoolTrue ([System.IO.Directory]::Exists($credJLink)) 'SecretPath/JunctionFixtureCreated'
    try {
        $jSecret = Join-Path $credJLink 'sub\s.dpapi'
        $jSecure = New-CredTestSecure $credFake
        Invoke-ApiPoolSandboxRefusal -Path $jSecret -Name 'SecretPath/Provider/JunctionAncestor' -ScriptBlock { New-ApiPoolCredentialProvider -Kind Dpapi -SecretPath $jSecret }
        Invoke-ApiPoolSandboxRefusal -Path $jSecret -Name 'SecretPath/Set/JunctionAncestor' -ScriptBlock { Set-ApiPoolCredential -SecretPath $jSecret -Secret $jSecure }
        Invoke-ApiPoolSandboxRefusal -Path $jSecret -Name 'SecretPath/Restore/JunctionAncestor' -ScriptBlock { Restore-ApiPoolPreviousCredential -SecretPath $jSecret }
        Assert-ApiPoolEqual 0 @(Get-ChildItem -LiteralPath $credJTarget -Force).Count 'SecretPath/JunctionTargetUntouched'
    }
    finally {
        if ([System.IO.Directory]::Exists($credJLink)) { [System.IO.Directory]::Delete($credJLink, $false) }
    }

    # ---------------- F6-P2-A: derived paths (.previous, .meta.json) must not be reparse points ----------------
    # Links live ONLY inside the sandbox. A file symlink is tried first (may need a privilege); if mklink fails, a directory
    # junction with the same name is used instead (kind recorded in the test names).
    $lnkDir = Join-Path $credSandbox 'lnk'
    [void][System.IO.Directory]::CreateDirectory($lnkDir)
    $lnkCounter = 0
    function New-CredTestLink {
        param([string]$Link, [string]$TargetFile, [string]$TargetDir)
        # stderr is silenced inside cmd (a PowerShell 2>&1 would raise under $ErrorActionPreference = 'Stop').
        $null = & cmd.exe /c ('mklink "{0}" "{1}" 2>nul' -f $Link, $TargetFile)
        if ([System.IO.File]::Exists($Link)) { return 'filesymlink' }
        $null = & cmd.exe /c ('mklink /J "{0}" "{1}" 2>nul' -f $Link, $TargetDir)
        if ([System.IO.Directory]::Exists($Link)) { return 'junction' }
        return 'none'
    }
    function Remove-CredTestLink {
        param([string]$Link, [string]$Kind)
        if ($Kind -eq 'filesymlink') { [System.IO.File]::Delete($Link) }
        elseif ($Kind -eq 'junction') { [System.IO.Directory]::Delete($Link, $false) }
    }
    $lnkKnown = [System.Text.Encoding]::UTF8.GetBytes('KNOWN-TARGET-CONTENT-DO-NOT-OVERWRITE')
    foreach ($slot in @('previous', 'meta')) {
        foreach ($op in @('Set', 'Restore')) {
            $lnkCounter++
            $lnkSecret = Join-Path $lnkDir ('s{0}.dpapi' -f $lnkCounter)
            $lnkTargetDir = Join-Path $lnkDir ('t{0}' -f $lnkCounter)
            [void][System.IO.Directory]::CreateDirectory($lnkTargetDir)
            $lnkTarget = Join-Path $lnkTargetDir 'target.bin'
            [System.IO.File]::WriteAllBytes($lnkTarget, $lnkKnown)
            Set-ApiPoolCredential -SecretPath $lnkSecret -Secret (New-CredTestSecure $credFake)
            Set-ApiPoolCredential -SecretPath $lnkSecret -Secret (New-CredTestSecure $credFakeB)
            $lnkLeaf = if ($slot -eq 'previous') { $lnkSecret + '.previous' } else { $lnkSecret + '.meta.json' }
            $lnkBefore = [System.IO.File]::ReadAllBytes($lnkSecret)
            [System.IO.File]::Delete($lnkLeaf)
            $lnkKind = New-CredTestLink -Link $lnkLeaf -TargetFile $lnkTarget -TargetDir $lnkTargetDir
            $lnkName = 'Reparse/{0}/{1}/{2}' -f $op, $slot, $lnkKind
            Assert-ApiPoolTrue ($lnkKind -ne 'none') ($lnkName + '/FixtureCreated')
            if ($lnkKind -ne 'none') {
                try {
                    $lnkSecure = New-CredTestSecure $credFake
                    $lnkSecretCapture = $lnkSecret
                    if ($op -eq 'Set') {
                        Invoke-ApiPoolSandboxRefusal -Path $lnkLeaf -Name ($lnkName + '/Refused') -ScriptBlock { Set-ApiPoolCredential -SecretPath $lnkSecretCapture -Secret $lnkSecure }
                    }
                    else {
                        Invoke-ApiPoolSandboxRefusal -Path $lnkLeaf -Name ($lnkName + '/Refused') -ScriptBlock { Restore-ApiPoolPreviousCredential -SecretPath $lnkSecretCapture }
                    }
                    if ($lnkKind -eq 'filesymlink') {
                        Assert-ApiPoolEqual ([System.Convert]::ToBase64String($lnkKnown)) ([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($lnkTarget))) ($lnkName + '/TargetContentUnchanged')
                    }
                    else {
                        Assert-ApiPoolEqual 1 @(Get-ChildItem -LiteralPath $lnkTargetDir -Force).Count ($lnkName + '/TargetDirUnchanged')
                    }
                    Assert-ApiPoolEqual ([System.Convert]::ToBase64String($lnkBefore)) ([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($lnkSecret))) ($lnkName + '/CurrentSecretUntouched')
                }
                finally { Remove-CredTestLink -Link $lnkLeaf -Kind $lnkKind }
            }
        }
    }

    # ---------------- Static self-check: suites never hand real system paths to a writer ----------------
    $writerNames = @(('Set-ApiPool' + 'Credential'), ('Restore-ApiPool' + 'PreviousCredential'), ('Initialize-ApiPool' + 'Ledger'), ('New-ApiPool' + 'Reservation'), ('Write-ApiPool' + 'FileAtomic'), ('Write-ApiPool' + 'BytesAtomic'), ('Add-ApiPool' + 'LineDurable'), ('Enter-ApiPool' + 'FileLock'), ('Set-ApiPool' + 'EmergencyStop'))
    $realPathRegex = 'ProgramData|\\\\localhost|\\\\127\.|\\\\\?\\|\\\\\.\\|//localhost|C:\\x\b'
    $scanLine = {
        param([string]$Line)
        foreach ($w in $writerNames) { if ($Line.Contains($w) -and $Line -match $realPathRegex) { return $true } }
        return $false
    }
    $probeLine = ('    ' + $writerNames[0] + ' -SecretPath ' + "'C:\" + "ProgramData\BRAVO\s.dpapi'")
    Assert-ApiPoolTrue (& $scanLine $probeLine) 'Static/ScannerDetectsWriterWithRealPath'
    foreach ($suiteFile in @(Get-ChildItem -LiteralPath (Join-Path $script:TestsRoot 'suites') -Filter '*.Tests.ps1')) {
        $offending = @([System.IO.File]::ReadAllLines($suiteFile.FullName) | Where-Object { & $scanLine $_ })
        Assert-ApiPoolEqual 0 $offending.Count ('Static/NoWriterWithRealSystemPath/' + $suiteFile.Name)
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
