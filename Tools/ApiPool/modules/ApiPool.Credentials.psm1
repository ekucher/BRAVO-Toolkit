Set-StrictMode -Version Latest

# ApiPool.Credentials: credential providers (DPAPI file or in-memory mock) with
# rotation. Depends on ApiPool.Core, which the entrypoint/test runner imports
# into the global scope BEFORE this module (modules never import each other).
#
# DPAPI file format assumption: the file holds the raw output of
# ProtectedData.Protect(<UTF-8 secret bytes>, <entropy or null>, CurrentUser).
# No entropy is used unless the caller passes one explicitly.
# The secret is handled as SecureString; plaintext only exists transiently in
# char[]/byte[] buffers that are zeroed in finally blocks.
# By design Core's known-secret registry (Register-ApiPoolKnownSecret) keeps the plaintext
# of every credential read in-process for redaction; that copy is not zeroed.
# SecretPath is validated by Core's Assert-ApiPoolSafePath (absolute local drive path, no
# UNC/device prefix, not under the BRAVO data directory or the repository, no reparse ancestors).
# Written credential files (secret, .previous, .meta.json) get an owner-only ACL: inheritance
# disabled, FullControl for the current user and SYSTEM only.
# Restore-ApiPoolPreviousCredential is a two-step swap (secret first, then .previous), NOT atomic.

Add-Type -AssemblyName System.Security

# Mock secrets are kept out of the provider object so it never exposes them.
$script:ApiPoolMockSecrets = @{}

function Get-ApiPoolSecureChars {
    param([System.Security.SecureString]$Secret)

    $bstr = [IntPtr]::Zero
    try {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
        $chars = New-Object 'char[]' $Secret.Length
        for ($i = 0; $i -lt $chars.Length; $i++) {
            $unit = [int][System.Runtime.InteropServices.Marshal]::ReadInt16($bstr, $i * 2) -band 0xFFFF
            $chars[$i] = [char]$unit
        }
        return , $chars
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Clear-ApiPoolBuffer {
    param($Buffer)

    if ($Buffer -is [byte[]]) { [Array]::Clear($Buffer, 0, $Buffer.Length) }
    elseif ($Buffer -is [char[]]) { [Array]::Clear($Buffer, 0, $Buffer.Length) }
}

function Test-ApiPoolSecretChars {
    # A plausible API key: at least 8 characters, no whitespace or control characters.
    param([char[]]$Chars)

    if ($Chars.Length -lt 8) { return $false }
    foreach ($c in $Chars) {
        if ([char]::IsWhiteSpace($c) -or [char]::IsControl($c)) { return $false }
    }
    return $true
}

function Invoke-ApiPoolUnprotect {
    # Returns plaintext bytes. Throws CREDENTIAL_UNREADABLE on any decrypt failure.
    param([byte[]]$Protected, [byte[]]$Entropy)

    try {
        return , [System.Security.Cryptography.ProtectedData]::Unprotect($Protected, $Entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    }
    catch {
        Invoke-ApiPoolThrow -Code 'CREDENTIAL_UNREADABLE' -Message ('Credential file could not be decrypted for the current user ({0}).' -f $_.Exception.GetType().Name)
    }
}

function ConvertTo-ApiPoolSecureString {
    # Builds a SecureString from plaintext bytes (UTF-8) without leaving a string copy.
    param([byte[]]$PlainBytes)

    $chars = [System.Text.Encoding]::UTF8.GetChars($PlainBytes)
    try {
        $end = $chars.Length
        while ($end -gt 0 -and [char]::IsWhiteSpace($chars[$end - 1])) { $end-- }
        $trimmed = New-Object 'char[]' $end
        [Array]::Copy($chars, $trimmed, $end)
        try {
            if (-not (Test-ApiPoolSecretChars -Chars $trimmed)) {
                Invoke-ApiPoolThrow -Code 'CREDENTIAL_INVALID_FORMAT' -Message 'Decrypted credential is empty or has an unexpected format.'
            }
            $secure = New-Object System.Security.SecureString
            foreach ($c in $trimmed) { $secure.AppendChar($c) }
            $secure.MakeReadOnly()
            return $secure
        }
        finally {
            Clear-ApiPoolBuffer -Buffer $trimmed
        }
    }
    finally {
        Clear-ApiPoolBuffer -Buffer $chars
    }
}

function New-ApiPoolCredentialProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Dpapi', 'Mock')]
        [string]$Kind,

        [string]$SecretPath,

        [byte[]]$Entropy,

        [System.Security.SecureString]$MockSecret
    )

    $id = [guid]::NewGuid().ToString('N')
    if ($Kind -eq 'Dpapi') {
        if ([string]::IsNullOrWhiteSpace($SecretPath)) {
            Invoke-ApiPoolThrow -Code 'CREDENTIAL_NOT_FOUND' -Message 'SecretPath is required for the Dpapi provider.'
        }
        $provider = [pscustomobject]@{
            PSTypeName = 'ApiPool.CredentialProvider'
            Kind       = 'Dpapi'
            Id         = $id
            SecretPath = (Assert-ApiPoolSafePath -Path $SecretPath -Purpose 'SecretPath')
            Entropy    = $Entropy
        }
    }
    else {
        if ($null -eq $MockSecret) {
            Invoke-ApiPoolThrow -Code 'CREDENTIAL_NOT_FOUND' -Message 'MockSecret is required for the Mock provider.'
        }
        $script:ApiPoolMockSecrets[$id] = $MockSecret.Copy()
        $provider = [pscustomobject]@{
            PSTypeName = 'ApiPool.CredentialProvider'
            Kind       = 'Mock'
            Id         = $id
            SecretPath = $null
            Entropy    = $null
        }
    }
    Add-Member -InputObject $provider -MemberType ScriptMethod -Name Describe -Value {
        if ($this.Kind -eq 'Dpapi') { return ('Kind=Dpapi SecretPath={0}' -f $this.SecretPath) }
        return 'Kind=Mock'
    }
    Add-Member -InputObject $provider -MemberType ScriptMethod -Name ToString -Force -Value { return $this.Describe() }
    return $provider
}

function Get-ApiPoolCredential {
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param(
        [Parameter(Mandatory = $true)]
        $Provider
    )

    if ($Provider.Kind -eq 'Mock') {
        if (-not $script:ApiPoolMockSecrets.ContainsKey($Provider.Id)) {
            Invoke-ApiPoolThrow -Code 'CREDENTIAL_NOT_FOUND' -Message 'Mock credential is not available.'
        }
        $copy = $script:ApiPoolMockSecrets[$Provider.Id].Copy()
        $chars = Get-ApiPoolSecureChars -Secret $copy
        try {
            if (-not (Test-ApiPoolSecretChars -Chars $chars)) {
                Invoke-ApiPoolThrow -Code 'CREDENTIAL_INVALID_FORMAT' -Message 'Mock credential is empty or has an unexpected format.'
            }
        }
        finally { Clear-ApiPoolBuffer -Buffer $chars }
        Register-ApiPoolKnownSecret -Secret $copy
        return $copy
    }

    $path = $Provider.SecretPath
    if (-not [System.IO.File]::Exists($path)) {
        Invoke-ApiPoolThrow -Code 'CREDENTIAL_NOT_FOUND' -Message ("Credential file not found: {0}" -f $path)
    }
    $protectedBytes = $null
    $plainBytes = $null
    try {
        try { $protectedBytes = [System.IO.File]::ReadAllBytes($path) } catch {
            Invoke-ApiPoolThrow -Code 'CREDENTIAL_UNREADABLE' -Message ("Credential file could not be read: {0}" -f $path)
        }
        if ($protectedBytes.Length -eq 0) {
            Invoke-ApiPoolThrow -Code 'CREDENTIAL_NOT_FOUND' -Message ("Credential file is empty: {0}" -f $path)
        }
        $plainBytes = Invoke-ApiPoolUnprotect -Protected $protectedBytes -Entropy $Provider.Entropy
        $secure = ConvertTo-ApiPoolSecureString -PlainBytes $plainBytes
    }
    finally {
        Clear-ApiPoolBuffer -Buffer $protectedBytes
        Clear-ApiPoolBuffer -Buffer $plainBytes
    }
    Register-ApiPoolKnownSecret -Secret $secure
    return $secure
}

function Set-ApiPoolOwnerOnlyAcl {
    # Protected (non-inherited) DACL: current user and SYSTEM, FullControl.
    param([string]$Path)

    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
    $security = New-Object System.Security.AccessControl.FileSecurity
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($me, $system)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    [System.IO.File]::SetAccessControl($Path, $security)
}

function Write-ApiPoolCredentialMeta {
    param([string]$SecretPath, [byte[]]$PlainBytes)

    # Fingerprint over the UTF-8 bytes (trailing ASCII whitespace trimmed); no managed plaintext string.
    $end = $PlainBytes.Length
    while ($end -gt 0 -and ($PlainBytes[$end - 1] -eq 32 -or ($PlainBytes[$end - 1] -ge 9 -and $PlainBytes[$end - 1] -le 13))) { $end-- }
    $trimmed = New-Object 'byte[]' $end
    [Array]::Copy($PlainBytes, $trimmed, $end)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($trimmed)
    }
    finally {
        $sha.Dispose()
        Clear-ApiPoolBuffer -Buffer $trimmed
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $hash) { [void]$sb.Append($b.ToString('x2', [System.Globalization.CultureInfo]::InvariantCulture)) }
    $fingerprint = $sb.ToString().Substring(0, 8)
    $meta = [ordered]@{
        rotatedAtUtc = [System.DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        fingerprint  = $fingerprint
    }
    Write-ApiPoolFileAtomic -Path ($SecretPath + '.meta.json') -Content (ConvertTo-ApiPoolCanonicalJson -InputObject $meta)
}

function Set-ApiPoolCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecretPath,

        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$Secret,

        [byte[]]$Entropy
    )

    $full = Assert-ApiPoolSafePath -Path $SecretPath -Purpose 'SecretPath'
    $chars = Get-ApiPoolSecureChars -Secret $Secret
    $plainBytes = $null
    try {
        if (-not (Test-ApiPoolSecretChars -Chars $chars)) {
            Invoke-ApiPoolThrow -Code 'CREDENTIAL_INVALID_FORMAT' -Message 'Credential is empty or has an unexpected format.'
        }
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($chars)
        $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect($plainBytes, $Entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)

        try {
            if ([System.IO.File]::Exists($full)) {
                [System.IO.File]::Copy($full, ($full + '.previous'), $true)
            }
            Write-ApiPoolBytesAtomic -Path $full -Bytes $protectedBytes
            Write-ApiPoolCredentialMeta -SecretPath $full -PlainBytes $plainBytes
            foreach ($f in @($full, ($full + '.previous'), ($full + '.meta.json'))) {
                if ([System.IO.File]::Exists($f)) { Set-ApiPoolOwnerOnlyAcl -Path $f }
            }
        }
        catch {
            Invoke-ApiPoolThrow -Code 'CREDENTIAL_ROTATION_FAILED' -Message ("Credential rotation failed for {0} ({1})." -f $full, $_.Exception.GetType().Name)
        }
    }
    finally {
        Clear-ApiPoolBuffer -Buffer $chars
        Clear-ApiPoolBuffer -Buffer $plainBytes
    }
}

function Restore-ApiPoolPreviousCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecretPath,

        [byte[]]$Entropy
    )

    $full = Assert-ApiPoolSafePath -Path $SecretPath -Purpose 'SecretPath'
    $previousPath = $full + '.previous'
    if (-not [System.IO.File]::Exists($previousPath)) {
        Invoke-ApiPoolThrow -Code 'CREDENTIAL_NOT_FOUND' -Message ("No previous credential exists for {0}." -f $full)
    }
    $previousBytes = [System.IO.File]::ReadAllBytes($previousPath)
    $plainBytes = $null
    try {
        # Validate before swapping: an unreadable previous file must not replace a good one.
        $plainBytes = Invoke-ApiPoolUnprotect -Protected $previousBytes -Entropy $Entropy
        $check = ConvertTo-ApiPoolSecureString -PlainBytes $plainBytes
        $check.Dispose()

        $currentBytes = $null
        if ([System.IO.File]::Exists($full)) { $currentBytes = [System.IO.File]::ReadAllBytes($full) }
        try {
            # Two-step swap (secret, then .previous): a crash between the steps leaves both files valid but not exchanged.
            Write-ApiPoolBytesAtomic -Path $full -Bytes $previousBytes
            if ($null -ne $currentBytes) {
                Write-ApiPoolBytesAtomic -Path $previousPath -Bytes $currentBytes
            }
            Write-ApiPoolCredentialMeta -SecretPath $full -PlainBytes $plainBytes
            foreach ($f in @($full, $previousPath, ($full + '.meta.json'))) {
                if ([System.IO.File]::Exists($f)) { Set-ApiPoolOwnerOnlyAcl -Path $f }
            }
        }
        catch {
            Invoke-ApiPoolThrow -Code 'CREDENTIAL_ROTATION_FAILED' -Message ("Credential restore failed for {0} ({1})." -f $full, $_.Exception.GetType().Name)
        }
    }
    finally {
        Clear-ApiPoolBuffer -Buffer $plainBytes
    }
}

function Test-ApiPoolCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Provider
    )

    try {
        $secret = Get-ApiPoolCredential -Provider $Provider
        $secret.Dispose()
        return [pscustomobject]@{ Ok = $true; Code = 'OK' }
    }
    catch {
        $code = Get-ApiPoolErrorCode -ErrorRecord $_
        if ([string]::IsNullOrEmpty($code)) { $code = 'CREDENTIAL_UNREADABLE' }
        return [pscustomobject]@{ Ok = $false; Code = $code }
    }
}

Export-ModuleMember -Function @(
    'New-ApiPoolCredentialProvider',
    'Get-ApiPoolCredential',
    'Set-ApiPoolCredential',
    'Restore-ApiPoolPreviousCredential',
    'Test-ApiPoolCredential'
)
