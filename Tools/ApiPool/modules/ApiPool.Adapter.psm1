Set-StrictMode -Version Latest

# ApiPool.Adapter: Anthropic Messages adapter. Depends on ApiPool.Core, ApiPool.Pricing,
# ApiPool.Budget and ApiPool.Transport, which the entrypoint/test runner imports into the
# global scope (fixed order) before this module.
#
# Contract summary
#  - Only a text-only request allowlist is accepted; everything else is refused BEFORE any
#    reservation or transport call (programmer/config errors are thrown, not returned).
#  - One budget reservation per attempt. Undo ONLY after a response that is clearly not
#    charged. Anything ambiguous stays counted (UNRECONCILED).
#  - Retry backoff is deterministic (no random jitter in v1) so behavior is reproducible
#    and testable. All waiting goes through Context.Sleep in chunks of at most 250 ms and
#    checks the cancel marker between chunks.
#  - Concurrency slots are <StateRoot>/slots/slot-<n>.lock file locks; the per-model rate
#    limit state is <StateRoot>/ratelimit/<model>.json under <model>.lock.
#  - The logical endpoint below is NOT a network address: this build has no live transport.

$script:ApiPoolMessageEndpoint = 'apipool:messages/v1'
$script:ApiPoolAllowedTopKeys = @('model', 'max_tokens', 'system', 'messages')
$script:ApiPoolSleepChunkMs = 250
$script:ApiPoolSlotPollMs = 100

# ---------------------------------------------------------------------------
# Small private helpers
# ---------------------------------------------------------------------------

function Get-ApiPoolJsonField {
    # Strict-mode safe member read for parsed JSON (PSCustomObject) or dictionaries.
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    # The leading comma keeps a one-element array from being unrolled into its element.
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return , $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return , $p.Value
}

function Get-ApiPoolHeaderValue {
    param($Headers, [string]$Name)

    if ($null -eq $Headers -or $Headers -isnot [System.Collections.IDictionary]) { return $null }
    foreach ($k in $Headers.Keys) {
        if ([string]::Equals([string]$k, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($null -eq $Headers[$k]) { return $null }
            return [string]$Headers[$k]
        }
    }
    return $null
}

function Get-ApiPoolNow {
    param($Context)

    $now = [System.DateTime](& $Context.Clock)
    if ($now.Kind -eq [System.DateTimeKind]::Unspecified) { return [System.DateTime]::SpecifyKind($now, [System.DateTimeKind]::Utc) }
    return $now.ToUniversalTime()
}

function ConvertTo-ApiPoolUtcDate {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.DateTime]) { return $Value.ToUniversalTime() }
    $parsed = [System.DateTime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([System.DateTime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $parsed }
    return $null
}

function Format-ApiPoolUtcDate {
    param([System.DateTime]$Value)

    return $Value.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Test-ApiPoolCancelled {
    param([string]$CancelPath)

    if ([string]::IsNullOrEmpty($CancelPath)) { return $false }
    return [System.IO.File]::Exists($CancelPath)
}

function Wait-ApiPoolInterruptible {
    # Sleeps via Context.Sleep in chunks <= 250 ms; returns $true when the cancel marker appeared.
    param($Context, [long]$Milliseconds, [string]$CancelPath)

    $remaining = $Milliseconds
    while ($remaining -gt 0) {
        if (Test-ApiPoolCancelled -CancelPath $CancelPath) { return $true }
        $chunk = [int][Math]::Min([long]$script:ApiPoolSleepChunkMs, $remaining)
        & $Context.Sleep $chunk
        $remaining -= $chunk
    }
    return (Test-ApiPoolCancelled -CancelPath $CancelPath)
}

function Get-ApiPoolRetryDelay {
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Attempt,

        [AllowNull()]
        [Nullable[double]]$RetryAfterSec,

        [Parameter(Mandatory = $true)]
        $Config
    )

    $maxRetryAfter = [decimal]$Config.retry.maxRetryAfterSec
    if ($null -ne $RetryAfterSec -and -not [double]::IsNaN([double]$RetryAfterSec) -and -not [double]::IsInfinity([double]$RetryAfterSec) -and [double]$RetryAfterSec -ge 0) {
        $capped = [Math]::Min([decimal][Math]::Min([double]$RetryAfterSec, 1000000.0), $maxRetryAfter)
        return [long][Math]::Ceiling($capped * 1000)
    }
    $exponent = [Math]::Max(0, [Math]::Min($Attempt - 1, 30))
    $delay = [decimal]$Config.retry.baseDelayMs * [decimal][Math]::Pow(2, $exponent)
    return [long][Math]::Ceiling([Math]::Min($delay, [decimal]$Config.retry.maxDelayMs))
}

# ---------------------------------------------------------------------------
# Request validation and body construction
# ---------------------------------------------------------------------------

function Test-ApiPoolIntegralNumber {
    param($Value)

    if ($null -eq $Value -or $Value -is [bool]) { return $false }
    if ($Value -is [int] -or $Value -is [long]) { return $true }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        $d = [double]$Value
        return (-not [double]::IsNaN($d) -and -not [double]::IsInfinity($d) -and $d -eq [Math]::Floor($d))
    }
    return $false
}

function Get-ApiPoolValidatedContent {
    # Returns a string or an ArrayList of @{type;text} maps, or throws.
    param($Content, [string]$Where)

    if ($Content -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Content)) {
            Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("{0}: content text must not be empty." -f $Where)
        }
        return $Content
    }
    if ($null -eq $Content -or $Content -is [System.Collections.IDictionary] -or $Content -isnot [System.Collections.IEnumerable]) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("{0}: content must be a string or an array of text blocks." -f $Where)
    }
    $blocks = New-Object System.Collections.ArrayList
    foreach ($block in $Content) {
        if ($block -isnot [System.Collections.IDictionary]) {
            Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("{0}: a content block must be an object." -f $Where)
        }
        foreach ($k in $block.Keys) {
            if ([string]$k -cne 'type' -and [string]$k -cne 'text') {
                Invoke-ApiPoolThrow -Code 'REQUEST_FORBIDDEN_FIELD' -Message ("{0}: content block field '{1}' is not allowed." -f $Where, [string]$k) -Details @{ field = [string]$k }
            }
        }
        if (-not $block.Contains('type') -or $block['type'] -isnot [string]) {
            Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("{0}: a content block needs a string 'type'." -f $Where)
        }
        if ($block['type'] -cne 'text') {
            Invoke-ApiPoolThrow -Code 'REQUEST_FORBIDDEN_FIELD' -Message ("{0}: content block type '{1}' is not allowed (text only)." -f $Where, [string]$block['type']) -Details @{ field = 'type' }
        }
        if (-not $block.Contains('text') -or $block['text'] -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$block['text'])) {
            Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("{0}: a text block needs a non-empty 'text'." -f $Where)
        }
        [void]$blocks.Add([ordered]@{ type = 'text'; text = [string]$block['text'] })
    }
    if ($blocks.Count -eq 0) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("{0}: content must not be an empty array." -f $Where)
    }
    return , $blocks
}

function ConvertTo-ApiPoolPreparedRequest {
    param($Context, $Request)

    if ($Request -isnot [System.Collections.IDictionary]) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'The request must be a hashtable.'
    }
    foreach ($k in $Request.Keys) {
        if (-not ($script:ApiPoolAllowedTopKeys -ccontains [string]$k)) {
            Invoke-ApiPoolThrow -Code 'REQUEST_FORBIDDEN_FIELD' -Message ("Request field '{0}' is not allowed." -f [string]$k) -Details @{ field = [string]$k }
        }
    }
    foreach ($required in @('model', 'max_tokens', 'messages')) {
        if (-not $Request.Contains($required)) {
            Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("Request field '{0}' is required." -f $required)
        }
    }
    if ($Request['model'] -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Request['model'])) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message "Request field 'model' must be a non-empty string."
    }
    if (-not (Test-ApiPoolIntegralNumber -Value $Request['max_tokens']) -or [decimal]$Request['max_tokens'] -lt 1) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message "Request field 'max_tokens' must be an integer >= 1."
    }
    if ($Request.Contains('system')) {
        if ($Request['system'] -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Request['system'])) {
            Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message "Request field 'system' must be a non-empty string."
        }
    }
    $messages = $Request['messages']
    if ($null -eq $messages -or $messages -is [string] -or $messages -is [System.Collections.IDictionary] -or $messages -isnot [System.Collections.IEnumerable]) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message "Request field 'messages' must be an array."
    }
    $preparedMessages = New-Object System.Collections.ArrayList
    $index = 0
    foreach ($m in $messages) {
        $where = 'messages[{0}]' -f $index
        if ($m -isnot [System.Collections.IDictionary]) {
            Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("{0} must be an object." -f $where)
        }
        foreach ($k in $m.Keys) {
            if ([string]$k -cne 'role' -and [string]$k -cne 'content') {
                Invoke-ApiPoolThrow -Code 'REQUEST_FORBIDDEN_FIELD' -Message ("{0}: field '{1}' is not allowed." -f $where, [string]$k) -Details @{ field = [string]$k }
            }
        }
        if (-not $m.Contains('role') -or ($m['role'] -isnot [string]) -or -not (([string]$m['role'] -ceq 'user') -or ([string]$m['role'] -ceq 'assistant'))) {
            Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("{0}: role must be 'user' or 'assistant'." -f $where)
        }
        if (-not $m.Contains('content')) {
            Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("{0}: content is required." -f $where)
        }
        $content = Get-ApiPoolValidatedContent -Content $m['content'] -Where $where
        [void]$preparedMessages.Add([ordered]@{ role = [string]$m['role']; content = $content })
        $index++
    }
    if ($preparedMessages.Count -eq 0) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message "Request field 'messages' must not be empty."
    }
    if ($preparedMessages[0]['role'] -cne 'user') {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'The first message must have role user.'
    }

    if ($null -eq $Context.Registry) {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message 'The context has no model registry.'
    }
    $model = Get-ApiPoolModel -Registry $Context.Registry -Model ([string]$Request['model'])
    if ($model.Id -notmatch '^[A-Za-z0-9._-]+$') {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'The model id contains characters that are not allowed.'
    }
    if ([decimal]$Request['max_tokens'] -gt [decimal]$model.MaxOutputTokens) {
        Invoke-ApiPoolThrow -Code 'MAX_TOKENS_EXCEEDS_MODEL' -Message ("max_tokens {0} exceeds the limit {1} of model '{2}'." -f $Request['max_tokens'], $model.MaxOutputTokens, $model.Id)
    }
    $maxTokens = [int]$Request['max_tokens']

    $body = [ordered]@{ model = $model.Id; max_tokens = $maxTokens }
    if ($Request.Contains('system')) { $body['system'] = [string]$Request['system'] }
    $body['messages'] = $preparedMessages
    $json = ConvertTo-ApiPoolCanonicalJson -InputObject $body
    $bodyBytes = (New-Object System.Text.UTF8Encoding($false)).GetByteCount($json)
    $reservation = Get-ApiPoolReservationCost -Model $model -BodyBytes $bodyBytes -MessageCount $preparedMessages.Count -MaxTokens $maxTokens

    return [pscustomobject]@{
        Model               = $model
        MaxTokens           = $maxTokens
        BodyJson            = $json
        BodyBytes           = [int64]$bodyBytes
        MessageCount        = [int]$preparedMessages.Count
        ReservationMicroUsd = [long]$reservation
    }
}

# ---------------------------------------------------------------------------
# Concurrency slots and rate limit
# ---------------------------------------------------------------------------

function Enter-ApiPoolSlot {
    param($Context)

    $max = [int]$Context.Config.maxConcurrency
    $waitMs = [Math]::Min([int]$Context.Config.timeouts.requestTimeoutSec * 1000, 30000)
    $waited = 0
    $dir = Join-Path $Context.StateRoot 'slots'
    while ($true) {
        for ($n = 1; $n -le $max; $n++) {
            $path = Join-Path $dir ('slot-{0}.lock' -f $n)
            try {
                return (Enter-ApiPoolFileLock -Path $path -TimeoutMs 1 -TimeoutCode 'SLOT_TIMEOUT')
            }
            catch {
                if ((Get-ApiPoolErrorCode -ErrorRecord $_) -cne 'SLOT_TIMEOUT') { throw }
            }
        }
        if ($waited -ge $waitMs) {
            Invoke-ApiPoolThrow -Code 'SLOT_TIMEOUT' -Message ("No concurrency slot became free within {0} ms." -f $waitMs) -Retryable
        }
        & $Context.Sleep $script:ApiPoolSlotPollMs
        $waited += $script:ApiPoolSlotPollMs
    }
}

function Get-ApiPoolRatePath {
    param($Context, [string]$Model)

    $dir = Join-Path $Context.StateRoot 'ratelimit'
    return [pscustomobject]@{ State = (Join-Path $dir ($Model + '.json')); Lock = (Join-Path $dir ($Model + '.lock')) }
}

function Read-ApiPoolRateState {
    # A missing or unreadable file means "no restriction": it holds throttling hints only, never money.
    param([string]$Path)

    $result = @{ NotBefore = $null; LastAttempt = $null }
    if (-not [System.IO.File]::Exists($Path)) { return $result }
    try {
        $doc = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path)) -ErrorAction Stop
        $result['NotBefore'] = ConvertTo-ApiPoolUtcDate -Value (Get-ApiPoolJsonField -Object $doc -Name 'notBeforeUtc')
        $result['LastAttempt'] = ConvertTo-ApiPoolUtcDate -Value (Get-ApiPoolJsonField -Object $doc -Name 'lastAttemptUtc')
    }
    catch {
        return @{ NotBefore = $null; LastAttempt = $null }
    }
    return $result
}

function Write-ApiPoolRateState {
    param([string]$Path, $NotBefore, $LastAttempt)

    $nb = $null
    $la = $null
    if ($null -ne $NotBefore) { $nb = Format-ApiPoolUtcDate -Value $NotBefore }
    if ($null -ne $LastAttempt) { $la = Format-ApiPoolUtcDate -Value $LastAttempt }
    Write-ApiPoolFileAtomic -Path $Path -Content (ConvertTo-ApiPoolCanonicalJson -InputObject ([ordered]@{ notBeforeUtc = $nb; lastAttemptUtc = $la }))
}

function Request-ApiPoolRateClaim {
    # Atomically claims the right to send now. Returns 0 when claimed (lastAttemptUtc is
    # recorded), otherwise the number of milliseconds to wait before asking again.
    param($Context, [string]$Model)

    $paths = Get-ApiPoolRatePath -Context $Context -Model $Model
    $lock = Enter-ApiPoolFileLock -Path $paths.Lock -TimeoutMs 5000 -Sleep $Context.Sleep -TimeoutCode 'RATELIMIT_LOCK_TIMEOUT'
    try {
        $now = Get-ApiPoolNow -Context $Context
        $state = Read-ApiPoolRateState -Path $paths.State
        $next = $now
        if ($null -ne $state['NotBefore'] -and $state['NotBefore'] -gt $next) { $next = $state['NotBefore'] }
        if ($null -ne $state['LastAttempt']) {
            $candidate = $state['LastAttempt'].AddMilliseconds([double]$Context.Config.minRequestIntervalMs)
            if ($candidate -gt $next) { $next = $candidate }
        }
        if ($next -gt $now) {
            return [long][Math]::Max(1.0, [Math]::Ceiling(($next - $now).TotalMilliseconds))
        }
        Write-ApiPoolRateState -Path $paths.State -NotBefore $state['NotBefore'] -LastAttempt $now
        return [long]0
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lock
    }
}

function Set-ApiPoolRateNotBefore {
    param($Context, [string]$Model, [double]$Seconds)

    $paths = Get-ApiPoolRatePath -Context $Context -Model $Model
    $lock = Enter-ApiPoolFileLock -Path $paths.Lock -TimeoutMs 5000 -Sleep $Context.Sleep -TimeoutCode 'RATELIMIT_LOCK_TIMEOUT'
    try {
        $now = Get-ApiPoolNow -Context $Context
        $state = Read-ApiPoolRateState -Path $paths.State
        $notBefore = $now.AddSeconds($Seconds)
        if ($null -ne $state['NotBefore'] -and $state['NotBefore'] -gt $notBefore) { $notBefore = $state['NotBefore'] }
        Write-ApiPoolRateState -Path $paths.State -NotBefore $notBefore -LastAttempt $state['LastAttempt']
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lock
    }
}

# ---------------------------------------------------------------------------
# Response handling
# ---------------------------------------------------------------------------

function Get-ApiPoolSafeMessage {
    # Redact first, then flatten control characters and cap the length (never cut a secret in half).
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $safe = Protect-ApiPoolText -Text $Text
    $safe = [regex]::Replace($safe, '[\x00-\x1F\x7F]', ' ')
    if ($safe.Length -gt 500) { $safe = $safe.Substring(0, 500) }
    return $safe
}

function Get-ApiPoolErrorBodyInfo {
    param([string]$Body)

    $info = @{ ErrorType = $null; Message = $null }
    if ([string]::IsNullOrWhiteSpace($Body)) { return $info }
    try {
        $doc = ConvertFrom-Json -InputObject $Body -ErrorAction Stop
        if ((Get-ApiPoolJsonField -Object $doc -Name 'type') -ceq 'error') {
            $err = Get-ApiPoolJsonField -Object $doc -Name 'error'
            $t = Get-ApiPoolJsonField -Object $err -Name 'type'
            $m = Get-ApiPoolJsonField -Object $err -Name 'message'
            if ($t -is [string]) { $info['ErrorType'] = Get-ApiPoolSafeMessage -Text $t }
            if ($m -is [string]) { $info['Message'] = Get-ApiPoolSafeMessage -Text $m }
        }
    }
    catch {
        return @{ ErrorType = $null; Message = $null }
    }
    return $info
}

function ConvertFrom-ApiPoolMessageResponse {
    # Never throws: returns @{Valid; Reason; ...}. Valid requires a well-formed message AND
    # a usage block from which an exact cost can be computed.
    param([string]$Body, $Model)

    $bad = { param($reason) return @{ Valid = $false; Reason = $reason } }
    try {
        $doc = ConvertFrom-Json -InputObject $Body -ErrorAction Stop
    }
    catch {
        return (& $bad 'the body is not valid JSON')
    }
    if ($doc -isnot [System.Management.Automation.PSCustomObject]) { return (& $bad 'the body is not a JSON object') }
    if ((Get-ApiPoolJsonField -Object $doc -Name 'type') -cne 'message') { return (& $bad "the body type is not 'message'") }
    $content = Get-ApiPoolJsonField -Object $doc -Name 'content'
    if ($null -eq $content -or $content -is [string] -or $content -isnot [System.Collections.IEnumerable] -or $content -is [System.Collections.IDictionary]) {
        return (& $bad 'content is not an array')
    }
    $text = New-Object System.Text.StringBuilder
    foreach ($block in $content) {
        if ($block -isnot [System.Management.Automation.PSCustomObject]) { return (& $bad 'a content block is not an object') }
        if ((Get-ApiPoolJsonField -Object $block -Name 'type') -cne 'text') { return (& $bad 'a content block is not a text block') }
        $t = Get-ApiPoolJsonField -Object $block -Name 'text'
        if ($t -isnot [string]) { return (& $bad 'a text block has no text') }
        [void]$text.Append($t)
    }
    $stop = Get-ApiPoolJsonField -Object $doc -Name 'stop_reason'
    if ($stop -isnot [string] -or [string]::IsNullOrEmpty($stop)) { return (& $bad 'stop_reason is missing') }
    $usage = Get-ApiPoolJsonField -Object $doc -Name 'usage'
    if ($null -eq $usage -or $usage -isnot [System.Management.Automation.PSCustomObject]) { return (& $bad 'usage is missing') }

    try {
        $cost = Get-ApiPoolActualCost -Model $Model -Usage $usage
        $usageMap = [ordered]@{
            input_tokens                = [long](Get-ApiPoolJsonField -Object $usage -Name 'input_tokens')
            output_tokens               = [long](Get-ApiPoolJsonField -Object $usage -Name 'output_tokens')
            cache_creation_input_tokens = [long](Get-ApiPoolJsonField -Object $usage -Name 'cache_creation_input_tokens')
            cache_read_input_tokens     = [long](Get-ApiPoolJsonField -Object $usage -Name 'cache_read_input_tokens')
        }
        $breakdown = Get-ApiPoolJsonField -Object $usage -Name 'cache_creation'
        if ($null -ne $breakdown) {
            $usageMap['cache_creation'] = [ordered]@{
                ephemeral_5m_input_tokens = [long](Get-ApiPoolJsonField -Object $breakdown -Name 'ephemeral_5m_input_tokens')
                ephemeral_1h_input_tokens = [long](Get-ApiPoolJsonField -Object $breakdown -Name 'ephemeral_1h_input_tokens')
            }
        }
    }
    catch {
        return (& $bad 'usage is invalid or cannot be priced')
    }
    $id = Get-ApiPoolJsonField -Object $doc -Name 'id'
    $messageId = $null
    if ($id -is [string]) { $messageId = Get-ApiPoolSafeMessage -Text $id }
    return @{ Valid = $true; Reason = $null; Text = $text.ToString(); StopReason = $stop; Usage = $usageMap; CostMicroUsd = [long]$cost; MessageId = $messageId }
}

# ---------------------------------------------------------------------------
# Attempt and public entrypoint
# ---------------------------------------------------------------------------

function New-ApiPoolOutcome {
    # Kind 'Done' ends the call; Kind 'Retry' means the attempt failed in a retryable way.
    # Sent = the transport was invoked for this attempt (counts toward Attempts).
    param(
        [string]$Kind,
        [AllowNull()][string]$Code,
        [AllowNull()][string]$Message,
        [bool]$Sent = $false,
        [bool]$Ok = $false,
        [hashtable]$Extra
    )

    $o = [ordered]@{
        Kind = $Kind; Code = $Code; Message = $Message; Sent = $Sent; Ok = $Ok
        Text = $null; StopReason = $null; Usage = $null; CostMicroUsd = [long]0
        RequestId = $null; MessageId = $null; RetryAfterSec = $null; Details = @{}
    }
    if ($null -ne $Extra) { foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] } }
    return [pscustomobject]$o
}

function Get-ApiPoolSendFailureSent {
    # $true/$false when the transport states it, $null when ambiguous.
    param($ErrorRecord)

    $target = $ErrorRecord.TargetObject
    if ($null -ne $target -and ($target.PSObject.TypeNames -contains 'ApiPool.Error') -and $target.Details -is [hashtable] -and $target.Details.ContainsKey('sent')) {
        return [bool]$target.Details['sent']
    }
    return $null
}

function Invoke-ApiPoolAttempt {
    param($Context, [string]$JobId, $Prepared, [int]$Attempt, [long]$PerJobLimitMicroUsd, [string]$CancelPath, $ReservationIds)

    $root = $Context.StateRoot
    $slot = $null
    try {
        $claims = 0
        while ($true) {
            if (Test-ApiPoolCancelled -CancelPath $CancelPath) {
                return (New-ApiPoolOutcome -Kind 'Done' -Code 'CANCELLED' -Message 'The job was cancelled.')
            }
            try { $slot = Enter-ApiPoolSlot -Context $Context }
            catch {
                if ((Get-ApiPoolErrorCode -ErrorRecord $_) -ceq 'SLOT_TIMEOUT') {
                    return (New-ApiPoolOutcome -Kind 'Done' -Code 'SLOT_TIMEOUT' -Message 'No concurrency slot became free in time.')
                }
                throw
            }
            $wait = Request-ApiPoolRateClaim -Context $Context -Model $Prepared.Model.Id
            if ($wait -le 0) { break }
            # Never sleep while holding a slot.
            Exit-ApiPoolFileLock -Handle $slot
            $slot = $null
            $claims++
            if ($claims -gt 100) {
                Invoke-ApiPoolThrow -Code 'INTERNAL_ERROR' -Message 'The rate limit wait did not converge.'
            }
            if (Wait-ApiPoolInterruptible -Context $Context -Milliseconds $wait -CancelPath $CancelPath) {
                return (New-ApiPoolOutcome -Kind 'Done' -Code 'CANCELLED' -Message 'The job was cancelled.')
            }
        }

        try {
            $rsv = New-ApiPoolReservation -StateRoot $root -JobId $JobId -AttemptId ([string]$Attempt) -AmountMicroUsd $Prepared.ReservationMicroUsd -PerJobLimitMicroUsd $PerJobLimitMicroUsd -Clock $Context.Clock
        }
        catch {
            $code = Get-ApiPoolErrorCode -ErrorRecord $_
            if ($null -ne $code -and ($code.StartsWith('BUDGET_', [System.StringComparison]::Ordinal) -or $code.StartsWith('LEDGER_', [System.StringComparison]::Ordinal))) {
                return (New-ApiPoolOutcome -Kind 'Done' -Code $code -Message (Get-ApiPoolSafeMessage -Text $_.Exception.Message))
            }
            throw
        }
        [void]$ReservationIds.Add($rsv.ReservationId)
        $rid = $rsv.ReservationId

        $request = @{ Method = 'POST'; Uri = $script:ApiPoolMessageEndpoint; Body = $Prepared.BodyJson; TimeoutSec = [int]$Context.Config.timeouts.requestTimeoutSec }
        $response = $null
        $sendError = $null
        try {
            $response = Send-ApiPoolTransportRequest -Transport $Context.Transport -Request $request -CredentialProvider $Context.CredentialProvider
        }
        catch {
            $sendError = $_
        }

        if ($null -ne $sendError) {
            $code = Get-ApiPoolErrorCode -ErrorRecord $sendError
            $sent = Get-ApiPoolSendFailureSent -ErrorRecord $sendError
            $isTransport = ($code -ceq 'TRANSPORT_TIMEOUT' -or $code -ceq 'TRANSPORT_ERROR')
            $message = Get-ApiPoolSafeMessage -Text $sendError.Exception.Message
            if ($isTransport -and $sent -eq $false) {
                [void](Undo-ApiPoolReservation -StateRoot $root -ReservationId $rid -Reason ('{0}: request not sent' -f $code) -Clock $Context.Clock)
                return (New-ApiPoolOutcome -Kind 'Retry' -Code $code -Message $message -Sent $true)
            }
            $reasonCode = 'transport failure'
            if ($null -ne $code) { $reasonCode = $code }
            [void](Set-ApiPoolReservationUnreconciled -StateRoot $root -ReservationId $rid -Reason ('{0}: outcome unknown' -f $reasonCode) -Clock $Context.Clock)
            if ($isTransport) {
                return (New-ApiPoolOutcome -Kind 'Retry' -Code $code -Message $message -Sent $true)
            }
            $finalCode = 'INTERNAL_ERROR'
            if ($null -ne $code) { $finalCode = $code }
            return (New-ApiPoolOutcome -Kind 'Done' -Code $finalCode -Message $message -Sent $true)
        }

        $status = [int]$response.StatusCode
        $requestId = Get-ApiPoolHeaderValue -Headers $response.Headers -Name 'request-id'
        if ($null -ne $requestId) { $requestId = Get-ApiPoolSafeMessage -Text $requestId }
        $retryAfter = $null
        $raw = Get-ApiPoolHeaderValue -Headers $response.Headers -Name 'retry-after'
        if ($null -ne $raw) {
            $parsed = [double]0
            if ([double]::TryParse($raw.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and -not [double]::IsNaN($parsed) -and -not [double]::IsInfinity($parsed) -and $parsed -ge 0) {
                $retryAfter = $parsed
            }
        }

        if ($status -eq 200) {
            $parsedBody = ConvertFrom-ApiPoolMessageResponse -Body $response.Body -Model $Prepared.Model
            if (-not $parsedBody['Valid']) {
                [void](Set-ApiPoolReservationUnreconciled -StateRoot $root -ReservationId $rid -Reason ('malformed 200 response: {0}' -f $parsedBody['Reason']) -Clock $Context.Clock)
                return (New-ApiPoolOutcome -Kind 'Done' -Code 'RESPONSE_MALFORMED' -Message ('The response is malformed: {0}.' -f $parsedBody['Reason']) -Sent $true -Extra @{ RequestId = $requestId; Details = @{ status = 200 } })
            }
            $evidence = @{ requestId = $requestId; messageId = $parsedBody['MessageId']; usage = $parsedBody['Usage'] }
            $done = Complete-ApiPoolReservation -StateRoot $root -ReservationId $rid -ActualMicroUsd $parsedBody['CostMicroUsd'] -Evidence $evidence -Clock $Context.Clock
            $common = @{
                Text = $parsedBody['Text']; StopReason = $parsedBody['StopReason']; Usage = $parsedBody['Usage']
                CostMicroUsd = [long]$parsedBody['CostMicroUsd']; RequestId = $requestId; MessageId = $parsedBody['MessageId']
            }
            if ($done.Overrun) {
                return (New-ApiPoolOutcome -Kind 'Done' -Code 'BUDGET_OVERRUN' -Message 'The actual cost exceeded the reservation; the budget is now stopped.' -Sent $true -Extra $common)
            }
            return (New-ApiPoolOutcome -Kind 'Done' -Ok $true -Sent $true -Extra $common)
        }

        $info = Get-ApiPoolErrorBodyInfo -Body $response.Body
        $details = @{ status = $status }
        if ($null -ne $info['ErrorType']) { $details['errorType'] = $info['ErrorType'] }
        $errorText = 'HTTP {0}' -f $status
        if ($null -ne $info['Message']) { $errorText = 'HTTP {0}: {1}' -f $status, $info['Message'] }

        $retryCode = $null
        $finalCode = $null
        switch ($status) {
            429 { $retryCode = 'RATE_LIMITED' }
            500 { $retryCode = 'API_SERVER_ERROR' }
            503 { $retryCode = 'API_SERVER_ERROR' }
            529 { $retryCode = 'API_OVERLOADED' }
            400 { $finalCode = 'API_CLIENT_ERROR' }
            402 { $finalCode = 'API_CLIENT_ERROR' }
            404 { $finalCode = 'API_CLIENT_ERROR' }
            413 { $finalCode = 'API_CLIENT_ERROR' }
            422 { $finalCode = 'API_CLIENT_ERROR' }
            401 { $finalCode = 'API_AUTH_FAILED' }
            403 { $finalCode = 'API_AUTH_FAILED' }
        }
        if ($null -eq $retryCode -and $null -eq $finalCode) {
            # An unknown status cannot be proven uncharged: keep the reservation counted.
            [void](Set-ApiPoolReservationUnreconciled -StateRoot $root -ReservationId $rid -Reason ('unexpected HTTP status {0}' -f $status) -Clock $Context.Clock)
            return (New-ApiPoolOutcome -Kind 'Done' -Code 'RESPONSE_MALFORMED' -Message ('Unexpected HTTP status {0}.' -f $status) -Sent $true -Extra @{ RequestId = $requestId; Details = $details })
        }

        [void](Undo-ApiPoolReservation -StateRoot $root -ReservationId $rid -Reason ('HTTP {0}: error response, not charged' -f $status) -Clock $Context.Clock)
        if ($null -ne $retryCode) {
            if ($status -eq 429 -and $null -ne $retryAfter) {
                $capped = [Math]::Min($retryAfter, [double]$Context.Config.retry.maxRetryAfterSec)
                Set-ApiPoolRateNotBefore -Context $Context -Model $Prepared.Model.Id -Seconds $capped
            }
            return (New-ApiPoolOutcome -Kind 'Retry' -Code $retryCode -Message $errorText -Sent $true -Extra @{ RetryAfterSec = $retryAfter; RequestId = $requestId; Details = $details })
        }
        return (New-ApiPoolOutcome -Kind 'Done' -Code $finalCode -Message $errorText -Sent $true -Extra @{ RequestId = $requestId; Details = $details })
    }
    finally {
        if ($null -ne $slot) { Exit-ApiPoolFileLock -Handle $slot }
    }
}

function New-ApiPoolMessageResult {
    param($Outcome, [int]$Attempts, $ReservationIds, [hashtable]$Details)

    $d = @{}
    if ($null -ne $Outcome.Details) { foreach ($k in $Outcome.Details.Keys) { $d[$k] = $Outcome.Details[$k] } }
    if ($null -ne $Details) { foreach ($k in $Details.Keys) { $d[$k] = $Details[$k] } }
    $code = $Outcome.Code
    if ($Outcome.Ok) { $code = 'OK' }
    return [pscustomobject]@{
        PSTypeName     = 'ApiPool.MessageResult'
        Ok             = [bool]$Outcome.Ok
        Code           = $code
        Message        = $Outcome.Message
        Text           = $Outcome.Text
        StopReason     = $Outcome.StopReason
        Usage          = $Outcome.Usage
        CostMicroUsd   = [long]$Outcome.CostMicroUsd
        Attempts       = $Attempts
        RequestId      = $Outcome.RequestId
        MessageId      = $Outcome.MessageId
        ReservationIds = @($ReservationIds.ToArray())
        Details        = $d
    }
}

function Invoke-ApiPoolMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context,

        [Parameter(Mandatory = $true)]
        [string]$JobId,

        [Parameter(Mandatory = $true)]
        $Request,

        [string]$CancelPath,

        [long]$PerJobLimitMicroUsd
    )

    # --- Programmer / configuration errors: thrown BEFORE any reservation. ---
    if ([string]::IsNullOrWhiteSpace($JobId)) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'JobId must be a non-empty string.'
    }
    if ($Context.Config.PSObject.Properties['mode'] -and [string]$Context.Config.mode -ceq 'live') {
        Invoke-ApiPoolThrow -Code 'LIVE_DISABLED_IN_BUILD' -Message "Configuration mode 'live' is disabled in this build."
    }
    if ($null -eq $Context.Transport -or $null -eq $Context.Transport.PSObject.Properties['Kind'] -or $Context.Transport.Kind -cne 'Fake') {
        Invoke-ApiPoolThrow -Code 'INTERNAL_ERROR' -Message 'The context has no supported transport (only Fake exists in this build).'
    }
    $prepared = ConvertTo-ApiPoolPreparedRequest -Context $Context -Request $Request
    $perJob = $PerJobLimitMicroUsd
    if (-not $PSBoundParameters.ContainsKey('PerJobLimitMicroUsd')) {
        $perJob = [long][Math]::Floor([decimal]$Context.Config.perJobUsd * 1000000)
    }
    if ($perJob -le 0) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'The per-job limit must be positive.'
    }

    $maxAttempts = [int]$Context.Config.retry.maxAttempts
    $reservationIds = New-Object System.Collections.ArrayList
    $sentCount = 0
    $last = $null

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $outcome = Invoke-ApiPoolAttempt -Context $Context -JobId $JobId -Prepared $prepared -Attempt $attempt -PerJobLimitMicroUsd $perJob -CancelPath $CancelPath -ReservationIds $reservationIds
        }
        catch {
            # An unexpected failure after a reservation leaves it counted (fail closed).
            $code = Get-ApiPoolErrorCode -ErrorRecord $_
            if ($null -eq $code) { $code = 'INTERNAL_ERROR' }
            $outcome = New-ApiPoolOutcome -Kind 'Done' -Code $code -Message (Get-ApiPoolSafeMessage -Text $_.Exception.Message)
        }
        if ($outcome.Sent) { $sentCount++ }
        $last = $outcome
        if ($outcome.Kind -ceq 'Done') {
            return (New-ApiPoolMessageResult -Outcome $outcome -Attempts $sentCount -ReservationIds $reservationIds)
        }
        if ($attempt -lt $maxAttempts) {
            $delay = Get-ApiPoolRetryDelay -Attempt $attempt -RetryAfterSec $outcome.RetryAfterSec -Config $Context.Config
            if (Wait-ApiPoolInterruptible -Context $Context -Milliseconds $delay -CancelPath $CancelPath) {
                $cancelled = New-ApiPoolOutcome -Kind 'Done' -Code 'CANCELLED' -Message 'The job was cancelled.'
                return (New-ApiPoolMessageResult -Outcome $cancelled -Attempts $sentCount -ReservationIds $reservationIds)
            }
        }
    }

    $exhausted = New-ApiPoolOutcome -Kind 'Done' -Code 'RETRY_EXHAUSTED' -Message ('Retries exhausted after {0} attempt(s); last error: {1}.' -f $maxAttempts, $last.Code)
    return (New-ApiPoolMessageResult -Outcome $exhausted -Attempts $sentCount -ReservationIds $reservationIds -Details @{ lastCode = $last.Code })
}

Export-ModuleMember -Function @(
    'Invoke-ApiPoolMessage',
    'Get-ApiPoolRetryDelay'
)
