Set-StrictMode -Version Latest

# ApiPool.Core: structured errors, redaction, strict config loading, atomic file
# writes, named-mutex helper, hashing and canonical JSON. No dependency on other
# ApiPool modules. Not part of the BRAVO production runtime.

# In-process registry of exact secret values used ONLY for redaction.
$script:ApiPoolKnownSecrets = New-Object System.Collections.ArrayList

$script:ApiPoolSecretNamePattern = '(?i)(?<pre>["'']?\b(?:x-api-key|anthropic-api-key|api_key|api-key|apikey|authorization)["'']?\s*(?:[:=]|%3[AD])\s*(?:\[\s*)?)(?:(?<q>["''])(?:\\.|(?!\k<q>).)*\k<q>|(?:(?:Bearer|Basic)\s+)?[^\s"'',;&\]]+)'

# ---------------------------------------------------------------------------
# Redaction
# ---------------------------------------------------------------------------

function Register-ApiPoolKnownSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$Secret
    )

    $bstr = [IntPtr]::Zero
    try {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if (-not [string]::IsNullOrEmpty($plain) -and $plain.Length -ge 8) {
            if (-not $script:ApiPoolKnownSecrets.Contains($plain)) {
                [void]$script:ApiPoolKnownSecrets.Add($plain)
            }
        }
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Clear-ApiPoolKnownSecret {
    [CmdletBinding()]
    param()

    $script:ApiPoolKnownSecrets.Clear()
}

function Protect-ApiPoolText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [AllowNull()]
        [string[]]$KnownSecret
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $result = $Text

    $secrets = New-Object System.Collections.ArrayList
    foreach ($s in @($script:ApiPoolKnownSecrets)) { [void]$secrets.Add([string]$s) }
    if ($null -ne $KnownSecret) {
        foreach ($s in $KnownSecret) {
            if (-not [string]::IsNullOrEmpty($s)) { [void]$secrets.Add([string]$s) }
        }
    }
    $ordered = @($secrets | Where-Object { $_.Length -ge 8 } | Sort-Object -Property Length -Descending)
    foreach ($s in $ordered) {
        $result = $result.Replace($s, '***REDACTED***')
    }

    $result = [regex]::Replace($result, 'sk-ant-[A-Za-z0-9_\-]{8,}', 'sk-ant-***REDACTED***')
    # Secret-bearing header/parameter names: `name: value`, `name=value`, `"name":"value"`, `"name":["value"]`,
    # `'name': 'value'`, URL-encoded `name%3Avalue` and quoted values containing spaces (redacted up to the closing quote).
    $result = [regex]::Replace($result, $script:ApiPoolSecretNamePattern, '${pre}${q}***REDACTED***${q}')
    $result = [regex]::Replace($result, '(?i)(\bBearer\s+)([A-Za-z0-9\-._~+/]+=*)', '${1}***REDACTED***')
    $result = [regex]::Replace($result, '(?i)https?://(claude\.ai|chatgpt\.com|chat\.openai\.com)/(share|chat|code/session)[^\s]*', '[chat-link-redacted]')

    return $result
}

# ---------------------------------------------------------------------------
# Structured errors
# ---------------------------------------------------------------------------

function New-ApiPoolError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [switch]$Retryable,

        [int]$HttpStatus = 0,

        [hashtable]$Details
    )

    $safeDetails = @{}
    if ($null -ne $Details) {
        foreach ($key in $Details.Keys) {
            $value = $Details[$key]
            if ($value -is [string]) { $value = Protect-ApiPoolText -Text $value }
            $safeDetails[$key] = $value
        }
    }

    return [pscustomobject]@{
        PSTypeName = 'ApiPool.Error'
        Code       = $Code
        Message    = (Protect-ApiPoolText -Text $Message)
        Retryable  = [bool]$Retryable
        HttpStatus = $HttpStatus
        Details    = $safeDetails
    }
}

function Invoke-ApiPoolThrow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [switch]$Retryable,

        [int]$HttpStatus = 0,

        [hashtable]$Details
    )

    $error1 = New-ApiPoolError -Code $Code -Message $Message -Retryable:$Retryable -HttpStatus $HttpStatus -Details $Details
    $exception = New-Object System.Exception(('[{0}] {1}' -f $error1.Code, $error1.Message))
    $record = New-Object System.Management.Automation.ErrorRecord(
        $exception, ('ApiPool.' + $Code), [System.Management.Automation.ErrorCategory]::InvalidOperation, $error1)
    throw $record
}

function Get-ApiPoolErrorCode {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        $ErrorRecord
    )

    $target = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $target = $ErrorRecord.TargetObject
    }
    if ($null -ne $target -and ($target.PSObject.TypeNames -contains 'ApiPool.Error')) {
        return [string]$target.Code
    }

    $message = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $ex = $ErrorRecord.Exception
        while ($null -ne $ex) {
            if ($ex.Message -match '^\[([A-Z][A-Z0-9_]*)\] ') { return $Matches[1] }
            $ex = $ex.InnerException
        }
    }
    elseif ($ErrorRecord -is [System.Exception]) {
        $message = $ErrorRecord.Message
    }
    else {
        $message = [string]$ErrorRecord
    }
    if ($null -ne $message -and $message -match '^\[([A-Z][A-Z0-9_]*)\] ') { return $Matches[1] }
    return $null
}

# ---------------------------------------------------------------------------
# Hashing and canonical JSON
# ---------------------------------------------------------------------------

function Get-ApiPoolSha256Hex {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $hash) {
        [void]$sb.Append($b.ToString('x2', [System.Globalization.CultureInfo]::InvariantCulture))
    }
    return $sb.ToString()
}

function ConvertTo-ApiPoolJsonString {
    param([AllowEmptyString()][string]$Value)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 34) { [void]$sb.Append('\"') }
        elseif ($code -eq 92) { [void]$sb.Append('\\') }
        elseif ($code -eq 8) { [void]$sb.Append('\b') }
        elseif ($code -eq 9) { [void]$sb.Append('\t') }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 12) { [void]$sb.Append('\f') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-ApiPoolCanonicalValue {
    param($Value)

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return (ConvertTo-ApiPoolJsonString -Value $Value) }
    if ($Value -is [char]) { return (ConvertTo-ApiPoolJsonString -Value ([string]$Value)) }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [decimal]) { return $Value.ToString('0.############################', $inv) }
    if ($Value -is [double] -or $Value -is [single]) { return ([double]$Value).ToString('R', $inv) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [byte] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [int16]) {
        return ([System.Convert]::ToString($Value, $inv))
    }
    if ($Value -is [datetime]) {
        return (ConvertTo-ApiPoolJsonString -Value $Value.ToUniversalTime().ToString('o', $inv))
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = New-Object 'System.Collections.Generic.List[string]'
        foreach ($k in $Value.Keys) { $keys.Add([string]$k) }
        $keys.Sort([System.StringComparer]::Ordinal)
        $parts = New-Object System.Collections.ArrayList
        foreach ($k in $keys) {
            $item = ConvertTo-ApiPoolCanonicalValue -Value $Value[$k]
            [void]$parts.Add((ConvertTo-ApiPoolJsonString -Value $k) + ':' + $item)
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$parts.Add((ConvertTo-ApiPoolCanonicalValue -Value $item)) }
        return '[' + ($parts -join ',') + ']'
    }

    $map = @{}
    foreach ($p in $Value.PSObject.Properties) {
        if ($p.MemberType -eq 'NoteProperty' -or $p.MemberType -eq 'Property') { $map[$p.Name] = $p.Value }
    }
    return (ConvertTo-ApiPoolCanonicalValue -Value $map)
}

function ConvertTo-ApiPoolCanonicalJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $InputObject
    )

    return (ConvertTo-ApiPoolCanonicalValue -Value $InputObject)
}

# ---------------------------------------------------------------------------
# Atomic file write
# ---------------------------------------------------------------------------

function Write-ApiPoolBytesAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if (-not [System.IO.Directory]::Exists($dir)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    $temp = Join-Path $dir ('.' + [System.IO.Path]::GetFileName($full) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')

    try {
        $stream = New-Object System.IO.FileStream($temp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }

        if ([System.IO.File]::Exists($full) -or [System.IO.Directory]::Exists($full)) {
            [System.IO.File]::Replace($temp, $full, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($temp, $full)
        }
    }
    catch {
        if ([System.IO.File]::Exists($temp)) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Write-ApiPoolFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Content)
    Write-ApiPoolBytesAtomic -Path $Path -Bytes $bytes
}

# ---------------------------------------------------------------------------
# File locks (no named mutex / semaphore; the OS releases the handle on process death)
# ---------------------------------------------------------------------------

function Enter-ApiPoolFileLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutMs,

        [scriptblock]$Sleep,

        [string]$TimeoutCode = 'LEDGER_LOCK_TIMEOUT'
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if (-not [System.IO.Directory]::Exists($dir)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }

    $stepMs = 25
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $iteration = 0
    while ($true) {
        try {
            $stream = New-Object System.IO.FileStream($full, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            return [pscustomobject]@{ PSTypeName = 'ApiPool.FileLock'; Path = $full; Stream = $stream }
        }
        catch [System.IO.IOException] {
            # Sharing violation: another holder owns the lock. Retry until timeout.
            $sharingViolation = $true
        }
        $iteration++
        $elapsed = [Math]::Max($stopwatch.ElapsedMilliseconds, [int64]$iteration * $stepMs)
        if ($elapsed -ge $TimeoutMs) {
            Invoke-ApiPoolThrow -Code $TimeoutCode -Message ("Could not acquire lock file '{0}' within {1} ms." -f $full, $TimeoutMs) -Retryable
        }
        if ($null -ne $Sleep) { & $Sleep $stepMs } else { Start-Sleep -Milliseconds $stepMs }
    }
}

function Exit-ApiPoolFileLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Handle
    )

    if ($null -ne $Handle.Stream) {
        $Handle.Stream.Dispose()
    }
}

function Add-ApiPoolLineDurable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    if ($Line.Contains("`n") -or $Line.Contains("`r")) {
        Invoke-ApiPoolThrow -Code 'LINE_INVALID' -Message 'A durable line must not contain line breaks.'
    }
    $full = [System.IO.Path]::GetFullPath($Path)
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if (-not [System.IO.Directory]::Exists($dir)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Line + "`n")
    $stream = New-Object System.IO.FileStream($full, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

# ---------------------------------------------------------------------------
# State root guard and context
# ---------------------------------------------------------------------------

function Get-ApiPoolLongPath {
    # Expands 8.3 short-name components of the existing part of a full path.
    param([string]$FullPath)

    $root = [System.IO.Path]::GetPathRoot($FullPath)
    $rest = $FullPath.Substring($root.Length)
    $current = $root
    $parts = @($rest.Split('\') | Where-Object { $_ -ne '' })
    $resolving = $true
    foreach ($part in $parts) {
        if ($resolving -and [System.IO.Directory]::Exists($current)) {
            $match = @([System.IO.Directory]::GetFileSystemEntries($current, $part))
            if ($match.Count -ge 1) {
                $current = Join-Path $current ([System.IO.Path]::GetFileName($match[0]))
                continue
            }
            $resolving = $false
        }
        $current = Join-Path $current $part
    }
    return $current.TrimEnd('\')
}

function Assert-ApiPoolSafePath {
    # Canonical path guard for every ApiPool path that holds state or secrets. Returns the full path.
    # Rejects: empty, unresolved %VAR%, relative, UNC (\\server\share, \\localhost, \\127.0.0.1), device prefixes
    # (\\?\ and \\.\), the BRAVO production data directory, the repository tree, and any path with an EXISTING
    # ancestor that is a reparse point (junction/symlink).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path,

        [string]$Purpose = 'Path',

        [string]$RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Invoke-ApiPoolThrow -Code 'STATE_PATH_FORBIDDEN' -Message ("{0} must not be empty." -f $Purpose)
    }
    if ($Path.Contains('%')) {
        Invoke-ApiPoolThrow -Code 'STATE_PATH_FORBIDDEN' -Message ("{0} contains an unresolved environment variable." -f $Purpose)
    }
    if ($Path.StartsWith('\\') -or $Path.StartsWith('//')) {
        Invoke-ApiPoolThrow -Code 'STATE_PATH_FORBIDDEN' -Message ("{0} must be a local drive path (UNC and device paths are forbidden)." -f $Purpose)
    }
    if ($Path -notmatch '^[A-Za-z]:[\\/]') {
        Invoke-ApiPoolThrow -Code 'STATE_PATH_FORBIDDEN' -Message ("{0} must be an absolute path." -f $Purpose)
    }
    try { $full = Get-ApiPoolLongPath -FullPath ([System.IO.Path]::GetFullPath($Path)) } catch {
        Invoke-ApiPoolThrow -Code 'STATE_PATH_FORBIDDEN' -Message ("{0} is not a valid path." -f $Purpose)
    }
    if ($full -notmatch '^[A-Za-z]:\\') {
        Invoke-ApiPoolThrow -Code 'STATE_PATH_FORBIDDEN' -Message ("{0} must be a local drive path." -f $Purpose)
    }

    if ([string]::IsNullOrEmpty($RepoRoot)) {
        # modules -> ApiPool -> Tools -> repository root
        $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    }
    $forbidden = New-Object System.Collections.ArrayList
    [void]$forbidden.Add(@('the BRAVO production data directory', 'C:\ProgramData\BRAVO'))
    $common = [System.Environment]::GetFolderPath('CommonApplicationData')
    if (-not [string]::IsNullOrEmpty($common)) {
        [void]$forbidden.Add(@('the BRAVO production data directory', (Join-Path $common 'BRAVO')))
    }
    if (-not [string]::IsNullOrEmpty($RepoRoot)) {
        [void]$forbidden.Add(@('the repository tree', $RepoRoot))
    }
    foreach ($entry in $forbidden) {
        $r = Get-ApiPoolLongPath -FullPath ([System.IO.Path]::GetFullPath($entry[1]))
        if ($full -ieq $r -or $full.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            Invoke-ApiPoolThrow -Code 'STATE_PATH_FORBIDDEN' -Message ("{0} must not be inside {1}." -f $Purpose, $entry[0])
        }
    }

    $probe = $full
    while (-not [string]::IsNullOrEmpty($probe)) {
        if ([System.IO.File]::Exists($probe) -or [System.IO.Directory]::Exists($probe)) {
            $attrs = [System.IO.File]::GetAttributes($probe)
            if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Invoke-ApiPoolThrow -Code 'STATE_PATH_FORBIDDEN' -Message ("{0} must not pass through a reparse point (junction or symbolic link)." -f $Purpose)
            }
        }
        $probe = [System.IO.Path]::GetDirectoryName($probe)
    }
    return $full
}

function Assert-ApiPoolStateRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$StateRoot,

        [string]$RepoRoot
    )

    return (Assert-ApiPoolSafePath -Path $StateRoot -Purpose 'State root' -RepoRoot $RepoRoot)
}

function New-ApiPoolContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateRoot,

        [Parameter(Mandatory = $true)]
        $Config,

        [AllowNull()]
        $Registry,

        [AllowNull()]
        $Transport,

        [AllowNull()]
        [psobject]$CredentialProvider,

        [scriptblock]$Clock,

        [scriptblock]$Sleep
    )

    if ($Config.PSObject.Properties['mode'] -and [string]$Config.mode -eq 'live') {
        Invoke-ApiPoolThrow -Code 'LIVE_DISABLED_IN_BUILD' -Message "Configuration mode 'live' is disabled in this build."
    }
    $root = Assert-ApiPoolStateRoot -StateRoot $StateRoot
    if ($null -eq $Clock) { $Clock = { [System.DateTime]::UtcNow } }
    if ($null -eq $Sleep) { $Sleep = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds } }

    return [pscustomobject]@{
        PSTypeName         = 'ApiPool.Context'
        StateRoot          = $root
        Config             = $Config
        Registry           = $Registry
        Transport          = $Transport
        CredentialProvider = $CredentialProvider
        Clock              = $Clock
        Sleep              = $Sleep
    }
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$script:ApiPoolConfigKeys = @{
    ''         = @('schemaVersion', 'mode', 'budgetUsd', 'perJobUsd', 'maxConcurrency', 'stateRoot', 'leaseSeconds', 'retry', 'timeouts', 'minRequestIntervalMs')
    'retry'    = @('maxAttempts', 'baseDelayMs', 'maxDelayMs', 'maxRetryAfterSec')
    'timeouts' = @('requestTimeoutSec')
}

function Get-ApiPoolConfigDefaultMap {
    # Canonical built-in defaults: the single normalization point for missing keys.
    return [ordered]@{
        schemaVersion        = 1
        mode                 = 'offline'
        budgetUsd            = 60
        perJobUsd            = 2
        maxConcurrency       = 2
        leaseSeconds         = 900
        retry                = [ordered]@{ maxAttempts = 4; baseDelayMs = 500; maxDelayMs = 20000; maxRetryAfterSec = 60 }
        timeouts             = [ordered]@{ requestTimeoutSec = 120 }
        minRequestIntervalMs = 250
    }
}

function ConvertTo-ApiPoolConfigMap {
    param($Object)

    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $map = [ordered]@{}
        foreach ($p in $Object.PSObject.Properties) {
            $map[$p.Name] = ConvertTo-ApiPoolConfigMap -Object $p.Value
        }
        return $map
    }
    return $Object
}

function Assert-ApiPoolConfigKeys {
    param(
        [System.Collections.IDictionary]$Map,
        [string]$Section,
        [string]$Source
    )

    $allowed = $script:ApiPoolConfigKeys[$Section]
    foreach ($key in $Map.Keys) {
        $display = $key
        if ($Section -ne '') { $display = $Section + '.' + $key }
        if (-not ($allowed -ccontains [string]$key)) {
            Invoke-ApiPoolThrow -Code 'CONFIG_UNKNOWN_KEY' -Message ("Unknown configuration key '{0}' in {1}." -f $display, $Source)
        }
        if ($Section -eq '' -and ($script:ApiPoolConfigKeys.ContainsKey([string]$key)) -and ($Map[$key] -is [System.Collections.IDictionary])) {
            Assert-ApiPoolConfigKeys -Map $Map[$key] -Section ([string]$key) -Source $Source
        }
    }
}

function Merge-ApiPoolConfigMap {
    param(
        [System.Collections.IDictionary]$Base,
        [System.Collections.IDictionary]$Override
    )

    foreach ($key in @($Override.Keys)) {
        if ($Base.Contains($key) -and ($Base[$key] -is [System.Collections.IDictionary]) -and ($Override[$key] -is [System.Collections.IDictionary])) {
            Merge-ApiPoolConfigMap -Base $Base[$key] -Override $Override[$key]
        }
        else {
            $Base[$key] = $Override[$key]
        }
    }
}

function Read-ApiPoolConfigFile {
    param([string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message ("Configuration file not found: {0}" -f $Path)
    }
    try {
        $raw = [System.IO.File]::ReadAllText($Path)
        $parsed = ConvertFrom-Json -InputObject $raw
    }
    catch {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message ("Configuration file is not valid JSON: {0}" -f $Path)
    }
    if ($parsed -isnot [System.Management.Automation.PSCustomObject]) {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message ("Configuration root must be a JSON object: {0}" -f $Path)
    }
    $map = ConvertTo-ApiPoolConfigMap -Object $parsed
    Assert-ApiPoolConfigKeys -Map $map -Section '' -Source $Path
    return $map
}

function Get-ApiPoolConfigNumber {
    param(
        $Value,
        [string]$KeyPath,
        [switch]$Integer,
        [decimal]$Min,
        [decimal]$Max,
        [switch]$MinExclusive
    )

    $isNumber = ($null -ne $Value) -and ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single])
    if (-not $isNumber) {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message ("Configuration key '{0}' must be a number." -f $KeyPath)
    }
    try { $d = [decimal]$Value } catch {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message ("Configuration key '{0}' is out of range." -f $KeyPath)
    }
    if ($Integer -and ($d -ne [Math]::Floor($d))) {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message ("Configuration key '{0}' must be an integer." -f $KeyPath)
    }
    $belowMin = if ($MinExclusive) { $d -le $Min } else { $d -lt $Min }
    if ($belowMin -or $d -gt $Max) {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message ("Configuration key '{0}' is out of range ({1}..{2})." -f $KeyPath, $Min, $Max)
    }
    if ($Integer) { return [int]$d }
    return $d
}


function Read-ApiPoolConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$OverridePath
    )

    $merged = Get-ApiPoolConfigDefaultMap
    Merge-ApiPoolConfigMap -Base $merged -Override (Read-ApiPoolConfigFile -Path $Path)
    if (-not [string]::IsNullOrEmpty($OverridePath)) {
        Merge-ApiPoolConfigMap -Base $merged -Override (Read-ApiPoolConfigFile -Path $OverridePath)
    }

    foreach ($section in @('retry', 'timeouts')) {
        if ($merged[$section] -isnot [System.Collections.IDictionary]) {
            Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message ("Configuration key '{0}' must be an object." -f $section)
        }
    }

    $schemaVersion = Get-ApiPoolConfigNumber -Value $merged['schemaVersion'] -KeyPath 'schemaVersion' -Integer -Min 1 -Max 1

    $mode = $merged['mode']
    if ($mode -isnot [string] -or -not ($mode -ceq 'offline' -or $mode -ceq 'live')) {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message "Configuration key 'mode' must be 'offline' or 'live'."
    }

    $budget = Get-ApiPoolConfigNumber -Value $merged['budgetUsd'] -KeyPath 'budgetUsd' -Min 0 -Max 1000 -MinExclusive
    $perJob = Get-ApiPoolConfigNumber -Value $merged['perJobUsd'] -KeyPath 'perJobUsd' -Min 0 -Max 1000 -MinExclusive
    if ($perJob -gt $budget) {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message "Configuration key 'perJobUsd' must not exceed 'budgetUsd'."
    }
    $concurrency = Get-ApiPoolConfigNumber -Value $merged['maxConcurrency'] -KeyPath 'maxConcurrency' -Integer -Min 1 -Max 16
    # stateRoot is OPTIONAL: modules never pick a default path (only the entrypoint does).
    $stateRoot = $null
    if ($merged.Contains('stateRoot')) {
        $rawRoot = $merged['stateRoot']
        if ($rawRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($rawRoot)) {
            Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message "Configuration key 'stateRoot' must be a non-empty string."
        }
        $stateRoot = Assert-ApiPoolStateRoot -StateRoot ([System.Environment]::ExpandEnvironmentVariables($rawRoot.Trim()))
    }
    $lease = Get-ApiPoolConfigNumber -Value $merged['leaseSeconds'] -KeyPath 'leaseSeconds' -Integer -Min 30 -Max 86400
    $interval = Get-ApiPoolConfigNumber -Value $merged['minRequestIntervalMs'] -KeyPath 'minRequestIntervalMs' -Integer -Min 0 -Max 60000

    $retry = $merged['retry']
    $maxAttempts = Get-ApiPoolConfigNumber -Value $retry['maxAttempts'] -KeyPath 'retry.maxAttempts' -Integer -Min 1 -Max 10
    $baseDelay = Get-ApiPoolConfigNumber -Value $retry['baseDelayMs'] -KeyPath 'retry.baseDelayMs' -Integer -Min 0 -Max 60000
    $maxDelay = Get-ApiPoolConfigNumber -Value $retry['maxDelayMs'] -KeyPath 'retry.maxDelayMs' -Integer -Min 0 -Max 3600000
    if ($maxDelay -lt $baseDelay) {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message "Configuration key 'retry.maxDelayMs' must be >= 'retry.baseDelayMs'."
    }
    $maxRetryAfter = Get-ApiPoolConfigNumber -Value $retry['maxRetryAfterSec'] -KeyPath 'retry.maxRetryAfterSec' -Integer -Min 0 -Max 600

    $requestTimeout = Get-ApiPoolConfigNumber -Value $merged['timeouts']['requestTimeoutSec'] -KeyPath 'timeouts.requestTimeoutSec' -Integer -Min 1 -Max 600

    return [pscustomobject]@{
        schemaVersion        = $schemaVersion
        mode                 = [string]$mode
        budgetUsd            = $budget
        perJobUsd            = $perJob
        maxConcurrency       = $concurrency
        stateRoot            = $stateRoot
        leaseSeconds         = $lease
        retry                = [pscustomobject]@{
            maxAttempts      = $maxAttempts
            baseDelayMs      = $baseDelay
            maxDelayMs       = $maxDelay
            maxRetryAfterSec = $maxRetryAfter
        }
        timeouts             = [pscustomobject]@{ requestTimeoutSec = $requestTimeout }
        minRequestIntervalMs = $interval
    }
}

Export-ModuleMember -Function @(
    'Register-ApiPoolKnownSecret',
    'Clear-ApiPoolKnownSecret',
    'Protect-ApiPoolText',
    'New-ApiPoolError',
    'Invoke-ApiPoolThrow',
    'Get-ApiPoolErrorCode',
    'Get-ApiPoolSha256Hex',
    'ConvertTo-ApiPoolCanonicalJson',
    'Write-ApiPoolBytesAtomic',
    'Write-ApiPoolFileAtomic',
    'Enter-ApiPoolFileLock',
    'Exit-ApiPoolFileLock',
    'Add-ApiPoolLineDurable',
    'Assert-ApiPoolSafePath',
    'Assert-ApiPoolStateRoot',
    'New-ApiPoolContext',
    'Read-ApiPoolConfig'
)
