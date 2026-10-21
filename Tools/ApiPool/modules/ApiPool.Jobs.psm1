Set-StrictMode -Version Latest

# ApiPool.Jobs: file-backed job engine, health, capabilities and the orchestrate adapter.
# Depends on ApiPool.Core, ApiPool.Pricing, ApiPool.Budget, ApiPool.Adapter and
# ApiPool.Agents, which the entrypoint/test runner imports into the global scope (fixed
# order) before this module.
#
# Contract summary
#  - Everything is synchronous in the caller. No daemon, no Scheduled Task, no background
#    job, no runspace, no detached process.
#  - <StateRoot>/jobs/<jobId>.json  job document (atomic replace)
#    <StateRoot>/jobs/<jobId>.lock  held by the process that runs the job
#    <StateRoot>/jobs/<jobId>.cancel  cancel marker observed by the adapter
#  - A job in state 'running' whose lock can be taken belongs to a dead process: it is
#    marked 'interrupted' and must be resumed explicitly with a reason.
#  - Terminal states (succeeded, failed, cancelled) are never overwritten.

$script:ApiPoolJobTerminalStates = @('succeeded', 'failed', 'cancelled')
$script:ApiPoolJobAllStates = @('queued', 'running', 'interrupted', 'succeeded', 'failed', 'cancelled')
$script:ApiPoolRetryableCodes = @('RATE_LIMITED', 'RETRY_EXHAUSTED', 'API_OVERLOADED', 'API_SERVER_ERROR', 'TRANSPORT_TIMEOUT', 'TRANSPORT_ERROR', 'SLOT_TIMEOUT')
$script:ApiPoolJobLockTimeoutMs = 250
$script:ApiPoolJobMaxAttempts = 3
$script:ApiPoolJobKeyMaxChars = 200

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

function Get-ApiPoolJobNow {
    param([AllowNull()][scriptblock]$Clock)

    $now = [System.DateTime]::UtcNow
    if ($null -ne $Clock) { $now = [System.DateTime](& $Clock) }
    if ($now.Kind -eq [System.DateTimeKind]::Unspecified) { $now = [System.DateTime]::SpecifyKind($now, [System.DateTimeKind]::Utc) }
    return $now.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-ApiPoolJobPath {
    param([string]$StateRoot, [string]$JobId)

    if ($JobId -cnotmatch '^job-[0-9a-f]{24}$') {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'JobId has an invalid format.'
    }
    $root = Assert-ApiPoolStateRoot -StateRoot $StateRoot
    $dir = Join-Path $root 'jobs'
    return [pscustomobject]@{
        Root   = $root
        Dir    = $dir
        File   = Join-Path $dir ($JobId + '.json')
        Lock   = Join-Path $dir ($JobId + '.lock')
        Cancel = Join-Path $dir ($JobId + '.cancel')
    }
}

function Get-ApiPoolDefaultCatalogPath {
    return (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'config') 'agents.json')
}

function Get-ApiPoolDefaultRegistryPath {
    return (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'config') 'models.json')
}

function ConvertTo-ApiPoolJobMap {
    param($Node)

    if ($null -eq $Node -or $Node -is [string] -or $Node -is [bool] -or $Node.GetType().IsPrimitive) { return $Node }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $map = [ordered]@{}
        foreach ($p in $Node.PSObject.Properties) { $map[[string]$p.Name] = ConvertTo-ApiPoolJobMap -Node $p.Value }
        return $map
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $Node) { [void]$list.Add((ConvertTo-ApiPoolJobMap -Node $item)) }
        return , $list
    }
    return $Node
}

function Read-ApiPoolJobDocument {
    # Returns the parsed job (PSCustomObject). JOB_NOT_FOUND / JOB_CORRUPT otherwise.
    param($Paths)

    if (-not [System.IO.File]::Exists($Paths.File)) {
        Invoke-ApiPoolThrow -Code 'JOB_NOT_FOUND' -Message 'The job does not exist.'
    }
    $raw = $null
    for ($try = 1; $try -le 5; $try++) {
        try { $raw = [System.IO.File]::ReadAllText($Paths.File); break } catch [System.IO.IOException] {
            if ($try -eq 5) { Invoke-ApiPoolThrow -Code 'JOB_CORRUPT' -Message 'The job file could not be read.' }
            [System.Threading.Thread]::Sleep(20)
        }
    }
    try { $doc = ConvertFrom-Json -InputObject $raw } catch {
        Invoke-ApiPoolThrow -Code 'JOB_CORRUPT' -Message 'The job file is not valid JSON.'
    }
    if ($doc -isnot [System.Management.Automation.PSCustomObject]) {
        Invoke-ApiPoolThrow -Code 'JOB_CORRUPT' -Message 'The job file root must be a JSON object.'
    }
    foreach ($k in @('schemaVersion', 'jobId', 'role', 'state', 'payloadHash', 'attempts', 'maxAttempts', 'history')) {
        if ($null -eq $doc.PSObject.Properties[$k]) {
            Invoke-ApiPoolThrow -Code 'JOB_CORRUPT' -Message ("The job file is missing '{0}'." -f $k)
        }
    }
    if (-not ($script:ApiPoolJobAllStates -ccontains [string]$doc.state)) {
        Invoke-ApiPoolThrow -Code 'JOB_CORRUPT' -Message 'The job file has an unknown state.'
    }
    return $doc
}

function Read-ApiPoolJobMap {
    param($Paths)

    return (ConvertTo-ApiPoolJobMap -Node (Read-ApiPoolJobDocument -Paths $Paths))
}

function Save-ApiPoolJobMap {
    param($Paths, $Map, [AllowNull()][scriptblock]$Clock)

    $Map['updatedUtc'] = Get-ApiPoolJobNow -Clock $Clock
    $json = ConvertTo-ApiPoolCanonicalJson -InputObject $Map
    for ($try = 1; $try -le 5; $try++) {
        try { Write-ApiPoolFileAtomic -Path $Paths.File -Content $json; return } catch [System.IO.IOException] {
            if ($try -eq 5) { throw }
            [System.Threading.Thread]::Sleep(20)
        }
    }
}

function Set-ApiPoolJobMapState {
    # Moves the map to a new state, appends history and saves. Terminal states are never left.
    param($Paths, $Map, [string]$State, [string]$Reason, [AllowNull()][scriptblock]$Clock)

    if ($script:ApiPoolJobTerminalStates -ccontains [string]$Map['state']) {
        Invoke-ApiPoolThrow -Code 'JOB_TERMINAL' -Message ("The job is already {0}." -f $Map['state'])
    }
    $Map['state'] = $State
    $safeReason = ''
    if (-not [string]::IsNullOrEmpty($Reason)) { $safeReason = Protect-ApiPoolText -Text $Reason }
    [void]$Map['history'].Add([ordered]@{ state = $State; utc = (Get-ApiPoolJobNow -Clock $Clock); reason = $safeReason })
    Save-ApiPoolJobMap -Paths $Paths -Map $Map -Clock $Clock
}

function Enter-ApiPoolJobLock {
    param($Paths, [AllowNull()][scriptblock]$Sleep, [int]$TimeoutMs)

    if ($null -ne $Sleep) {
        return (Enter-ApiPoolFileLock -Path $Paths.Lock -TimeoutMs $TimeoutMs -Sleep $Sleep -TimeoutCode 'JOB_BUSY')
    }
    return (Enter-ApiPoolFileLock -Path $Paths.Lock -TimeoutMs $TimeoutMs -TimeoutCode 'JOB_BUSY')
}

function Get-ApiPoolSafeText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $safe = Protect-ApiPoolText -Text $Text
    $safe = [regex]::Replace($safe, '[\x00-\x1F\x7F]', ' ')
    if ($safe.Length -gt 500) { $safe = $safe.Substring(0, 500) }
    return $safe
}

function New-ApiPoolJobError {
    param([string]$Code, [string]$Message)

    return [ordered]@{
        code      = $Code
        message   = (Get-ApiPoolSafeText -Text $Message)
        retryable = [bool]($script:ApiPoolRetryableCodes -ccontains $Code)
    }
}

# ---------------------------------------------------------------------------
# Submit / read
# ---------------------------------------------------------------------------

function Submit-ApiPoolJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context,

        [Parameter(Mandatory = $true)]
        [string]$Role,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Brief,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ContextData,

        [string]$IdempotencyKey,

        [string]$CatalogPath
    )

    if ([string]::IsNullOrEmpty($CatalogPath)) { $CatalogPath = Get-ApiPoolDefaultCatalogPath }
    $roleObject = Get-ApiPoolAgentRole -CatalogPath $CatalogPath -Role $Role
    # Validates the size limits at submit time; the request itself is rebuilt at run time.
    [void](New-ApiPoolAgentRequest -RoleObject $roleObject -Brief $Brief -ContextData $ContextData)

    $payloadHash = Get-ApiPoolSha256Hex -Text (ConvertTo-ApiPoolCanonicalJson -InputObject ([ordered]@{ role = $Role; brief = $Brief; contextData = $ContextData }))
    if ([string]::IsNullOrEmpty($IdempotencyKey)) {
        $jobId = 'job-' + [guid]::NewGuid().ToString('N').Substring(0, 24)
    }
    else {
        if ($IdempotencyKey.Length -gt $script:ApiPoolJobKeyMaxChars -or [string]::IsNullOrWhiteSpace($IdempotencyKey)) {
            Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("The idempotency key must be 1..{0} characters." -f $script:ApiPoolJobKeyMaxChars)
        }
        $jobId = 'job-' + (Get-ApiPoolSha256Hex -Text ($Role + "`n" + $IdempotencyKey)).Substring(0, 24)
    }
    $paths = Get-ApiPoolJobPath -StateRoot $Context.StateRoot -JobId $jobId

    $existing = $null
    if ([System.IO.File]::Exists($paths.File)) { $existing = Read-ApiPoolJobDocument -Paths $paths }
    else {
        $lock = Enter-ApiPoolJobLock -Paths $paths -Sleep $Context.Sleep -TimeoutMs 5000
        try {
            if ([System.IO.File]::Exists($paths.File)) { $existing = Read-ApiPoolJobDocument -Paths $paths }
            else {
                $now = Get-ApiPoolJobNow -Clock $Context.Clock
                $map = [ordered]@{
                    schemaVersion = 1
                    jobId         = $jobId
                    role          = $Role
                    state         = 'queued'
                    payloadHash   = $payloadHash
                    brief         = $Brief
                    contextData   = $ContextData
                    attempts      = 0
                    maxAttempts   = $script:ApiPoolJobMaxAttempts
                    createdUtc    = $now
                    updatedUtc    = $now
                    history       = (New-Object System.Collections.ArrayList)
                    result        = $null
                    error         = $null
                }
                [void]$map['history'].Add([ordered]@{ state = 'queued'; utc = $now; reason = 'submitted' })
                Save-ApiPoolJobMap -Paths $paths -Map $map -Clock $Context.Clock
            }
        }
        finally {
            Exit-ApiPoolFileLock -Handle $lock
        }
    }

    if ($null -ne $existing) {
        if ([string]$existing.payloadHash -cne $payloadHash) {
            Invoke-ApiPoolThrow -Code 'IDEMPOTENCY_CONFLICT' -Message 'A job with this idempotency key already exists with a different payload.'
        }
        return (Add-Member -InputObject $existing -NotePropertyName 'Duplicate' -NotePropertyValue $true -PassThru)
    }
    return (Add-Member -InputObject (Read-ApiPoolJobDocument -Paths $paths) -NotePropertyName 'Duplicate' -NotePropertyValue $false -PassThru)
}

function Get-ApiPoolJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateRoot,

        [Parameter(Mandatory = $true)]
        [string]$JobId
    )

    return (Read-ApiPoolJobDocument -Paths (Get-ApiPoolJobPath -StateRoot $StateRoot -JobId $JobId))
}

function Get-ApiPoolJobResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateRoot,

        [Parameter(Mandatory = $true)]
        [string]$JobId
    )

    $job = Get-ApiPoolJob -StateRoot $StateRoot -JobId $JobId
    $result = $null
    $err = $null
    if ($null -ne $job.PSObject.Properties['result']) { $result = $job.result }
    if ($null -ne $job.PSObject.Properties['error']) { $err = $job.error }
    return [pscustomobject]@{
        JobId  = [string]$job.jobId
        State  = [string]$job.state
        Result = $result
        Error  = $err
    }
}

# ---------------------------------------------------------------------------
# Run / stop / resume
# ---------------------------------------------------------------------------

function Invoke-ApiPoolJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context,

        [Parameter(Mandatory = $true)]
        [string]$JobId,

        [string]$CatalogPath
    )

    if ($null -eq $Context.Transport) {
        Invoke-ApiPoolThrow -Code 'MODE_OFFLINE' -Message 'offline build: no provider transport; use tests/fake transport'
    }
    if ([string]::IsNullOrEmpty($CatalogPath)) { $CatalogPath = Get-ApiPoolDefaultCatalogPath }
    $paths = Get-ApiPoolJobPath -StateRoot $Context.StateRoot -JobId $JobId
    [void](Read-ApiPoolJobDocument -Paths $paths)

    $lock = Enter-ApiPoolJobLock -Paths $paths -Sleep $Context.Sleep -TimeoutMs $script:ApiPoolJobLockTimeoutMs
    try {
        $map = Read-ApiPoolJobMap -Paths $paths
        $state = [string]$map['state']
        if ($script:ApiPoolJobTerminalStates -ccontains $state) {
            Invoke-ApiPoolThrow -Code 'JOB_TERMINAL' -Message ("The job is already {0}." -f $state)
        }
        if ($state -ceq 'running') {
            # The lock was obtainable, so the process that owned 'running' is gone.
            Set-ApiPoolJobMapState -Paths $paths -Map $map -State 'interrupted' -Reason 'the previous run did not finish (no lock holder)' -Clock $Context.Clock
            $state = 'interrupted'
        }
        if ($state -ceq 'interrupted') {
            Invoke-ApiPoolThrow -Code 'JOB_INTERRUPTED' -Message 'The job was interrupted; resume it explicitly with a reason before running it again.'
        }

        # Build the request BEFORE leaving 'queued' so a refusal does not burn an attempt.
        $roleObject = Get-ApiPoolAgentRole -CatalogPath $CatalogPath -Role ([string]$map['role'])
        $request = New-ApiPoolAgentRequest -RoleObject $roleObject -Brief ([string]$map['brief']) -ContextData ([string]$map['contextData'])

        $map['attempts'] = [int]$map['attempts'] + 1
        Set-ApiPoolJobMapState -Paths $paths -Map $map -State 'running' -Reason ('attempt {0}' -f $map['attempts']) -Clock $Context.Clock

        $msg = $null
        $thrown = $null
        try {
            $msg = Invoke-ApiPoolMessage -Context $Context -JobId $JobId -Request $request -CancelPath $paths.Cancel
        }
        catch {
            $thrown = $_
        }

        $finalState = 'failed'
        $reason = ''
        $resultMap = $null
        $errorMap = $null
        if ($null -ne $thrown) {
            $code = Get-ApiPoolErrorCode -ErrorRecord $thrown
            if ($null -eq $code) { $code = 'INTERNAL_ERROR' }
            $errorMap = New-ApiPoolJobError -Code $code -Message $thrown.Exception.Message
            $reason = $code
        }
        elseif ($msg.Ok) {
            try {
                $parsed = ConvertFrom-ApiPoolAgentOutput -RoleObject $roleObject -Text $msg.Text
                $warningList = New-Object System.Collections.ArrayList
                foreach ($w in $parsed.Warnings) { [void]$warningList.Add([string]$w) }
                $finalState = 'succeeded'
                $reason = 'completed'
                $resultMap = [ordered]@{
                    text         = $parsed.Text
                    handoff      = $parsed.Handoff
                    warnings     = $warningList
                    costMicroUsd = [long]$msg.CostMicroUsd
                    requestId    = $msg.RequestId
                    messageId    = $msg.MessageId
                }
            }
            catch {
                $errorMap = New-ApiPoolJobError -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
                $reason = 'INTERNAL_ERROR'
            }
        }
        elseif ($msg.Code -ceq 'CANCELLED') {
            $finalState = 'cancelled'
            $reason = 'cancelled by marker'
        }
        else {
            $errorMap = New-ApiPoolJobError -Code ([string]$msg.Code) -Message ([string]$msg.Message)
            $reason = [string]$msg.Code
        }

        $map['result'] = $resultMap
        $map['error'] = $errorMap
        Set-ApiPoolJobMapState -Paths $paths -Map $map -State $finalState -Reason $reason -Clock $Context.Clock
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lock
    }
    return (Read-ApiPoolJobDocument -Paths $paths)
}

function Stop-ApiPoolJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateRoot,

        [Parameter(Mandatory = $true)]
        [string]$JobId,

        [string]$Reason,

        [scriptblock]$Clock
    )

    $paths = Get-ApiPoolJobPath -StateRoot $StateRoot -JobId $JobId
    $doc = Read-ApiPoolJobDocument -Paths $paths
    if ($script:ApiPoolJobTerminalStates -ccontains [string]$doc.state) {
        Invoke-ApiPoolThrow -Code 'JOB_TERMINAL' -Message ("The job is already {0}." -f $doc.state)
    }
    $why = 'cancelled by operator'
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { $why = 'cancelled: ' + $Reason }

    $lock = $null
    try {
        $lock = Enter-ApiPoolJobLock -Paths $paths -Sleep $null -TimeoutMs $script:ApiPoolJobLockTimeoutMs
    }
    catch {
        if ((Get-ApiPoolErrorCode -ErrorRecord $_) -cne 'JOB_BUSY') { throw }
    }
    if ($null -eq $lock) {
        # A runner holds the job: ask it to stop through the marker.
        Write-ApiPoolFileAtomic -Path $paths.Cancel -Content (Get-ApiPoolSafeText -Text $why)
        return (Read-ApiPoolJobDocument -Paths $paths)
    }
    try {
        $map = Read-ApiPoolJobMap -Paths $paths
        $state = [string]$map['state']
        if ($script:ApiPoolJobTerminalStates -ccontains $state) {
            Invoke-ApiPoolThrow -Code 'JOB_TERMINAL' -Message ("The job is already {0}." -f $state)
        }
        if ($state -ceq 'running') {
            Write-ApiPoolFileAtomic -Path $paths.Cancel -Content (Get-ApiPoolSafeText -Text $why)
        }
        else {
            Set-ApiPoolJobMapState -Paths $paths -Map $map -State 'cancelled' -Reason $why -Clock $Clock
        }
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lock
    }
    return (Read-ApiPoolJobDocument -Paths $paths)
}

function Resume-ApiPoolJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context,

        [Parameter(Mandatory = $true)]
        [string]$JobId,

        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'A resume reason is required.'
    }
    $paths = Get-ApiPoolJobPath -StateRoot $Context.StateRoot -JobId $JobId
    [void](Read-ApiPoolJobDocument -Paths $paths)
    $lock = Enter-ApiPoolJobLock -Paths $paths -Sleep $Context.Sleep -TimeoutMs $script:ApiPoolJobLockTimeoutMs
    try {
        $map = Read-ApiPoolJobMap -Paths $paths
        $state = [string]$map['state']
        $previous = $state
        $allowed = $false
        if ($state -ceq 'interrupted') { $allowed = $true }
        elseif ($state -ceq 'failed' -and $null -ne $map['error'] -and $map['error'].Contains('retryable') -and [bool]$map['error']['retryable']) {
            $allowed = $true
            $previous = 'failed ' + [string]$map['error']['code']
        }
        if (-not $allowed) {
            Invoke-ApiPoolThrow -Code 'RESUME_NOT_ALLOWED' -Message ("A job in state '{0}' cannot be resumed." -f $state)
        }
        if ([int]$map['attempts'] -ge [int]$map['maxAttempts']) {
            Invoke-ApiPoolThrow -Code 'RESUME_LIMIT' -Message ("The job already used {0} of {1} attempts." -f $map['attempts'], $map['maxAttempts'])
        }
        # A failed job is terminal for Set-ApiPoolJobMapState; resuming is the one explicit exit.
        $map['state'] = 'interrupted'
        $map['error'] = $null
        Set-ApiPoolJobMapState -Paths $paths -Map $map -State 'queued' -Reason ('resume from {0}: {1}' -f $previous, $Reason) -Clock $Context.Clock
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lock
    }
    return (Read-ApiPoolJobDocument -Paths $paths)
}

# ---------------------------------------------------------------------------
# Health and capabilities
# ---------------------------------------------------------------------------

function Get-ApiPoolHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context
    )

    $issues = New-Object System.Collections.ArrayList
    $mode = [string]$Context.Config.mode
    if ($mode -cne 'offline') { [void]$issues.Add("mode is '$mode', expected 'offline'") }
    $transportKind = 'none'
    if ($null -ne $Context.Transport -and $null -ne $Context.Transport.PSObject.Properties['Kind']) { $transportKind = [string]$Context.Transport.Kind }

    $budget = $null
    try {
        $b = Get-ApiPoolBudgetStatus -StateRoot $Context.StateRoot
        $budget = [ordered]@{
            state                = [string]$b.State
            globalLimitMicroUsd  = $b.GlobalLimitMicroUsd
            committedMicroUsd    = $b.CommittedMicroUsd
            reservedMicroUsd     = $b.ReservedMicroUsd
            unreconciledMicroUsd = $b.UnreconciledMicroUsd
            availableMicroUsd    = $b.AvailableMicroUsd
            emergencyStop        = [bool]$b.EmergencyStop.Active
            openReservations     = @($b.OpenReservations).Count
        }
        if ($b.State -cne 'OK') { [void]$issues.Add(("budget state is {0}" -f $b.State)) }
    }
    catch {
        $budget = [ordered]@{ state = 'ERROR'; code = (Get-ApiPoolErrorCode -ErrorRecord $_) }
        [void]$issues.Add('budget status could not be read')
    }

    $writable = $false
    try {
        [void][System.IO.Directory]::CreateDirectory($Context.StateRoot)
        $probe = Join-Path $Context.StateRoot ('.health-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [System.IO.File]::WriteAllText($probe, 'ok')
        [System.IO.File]::Delete($probe)
        $writable = $true
    }
    catch {
        [void]$issues.Add('state root is not writable')
    }

    $counts = [ordered]@{}
    foreach ($s in $script:ApiPoolJobAllStates) { $counts[$s] = 0 }
    $counts['unreadable'] = 0
    $jobsDir = Join-Path $Context.StateRoot 'jobs'
    if ([System.IO.Directory]::Exists($jobsDir)) {
        foreach ($f in [System.IO.Directory]::GetFiles($jobsDir, 'job-*.json')) {
            try {
                $doc = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($f))
                $st = [string]$doc.state
                if ($counts.Contains($st)) { $counts[$st] = [int]$counts[$st] + 1 } else { $counts['unreadable'] = [int]$counts['unreadable'] + 1 }
            }
            catch {
                $counts['unreadable'] = [int]$counts['unreadable'] + 1
            }
        }
    }
    if ([int]$counts['unreadable'] -gt 0) { [void]$issues.Add('some job files are unreadable') }
    if ([int]$counts['interrupted'] -gt 0) { [void]$issues.Add('interrupted jobs await resume or cancel') }

    $ok = ($mode -ceq 'offline') -and ([string]$budget['state'] -ceq 'OK') -and $writable
    return [pscustomobject]@{
        ok               = [bool]$ok
        mode             = $mode
        liveAvailable    = $false
        transportKind    = $transportKind
        budget           = $budget
        stateRootWritable = $writable
        counts           = $counts
        issues           = @($issues.ToArray())
    }
}

function Get-ApiPoolCapability {
    [CmdletBinding()]
    param(
        [string]$CatalogPath,

        [string]$RegistryPath
    )

    if ([string]::IsNullOrEmpty($CatalogPath)) { $CatalogPath = Get-ApiPoolDefaultCatalogPath }
    if ([string]::IsNullOrEmpty($RegistryPath)) { $RegistryPath = Get-ApiPoolDefaultRegistryPath }
    $roles = New-Object System.Collections.ArrayList
    foreach ($r in @(Get-ApiPoolAgentRoleList -CatalogPath $CatalogPath)) {
        [void]$roles.Add([ordered]@{ name = $r.Name; model = $r.Model; maxTokens = $r.MaxTokens; description = $r.Description })
    }
    $registry = Import-ApiPoolModelRegistry -Path $RegistryPath
    $models = New-Object System.Collections.ArrayList
    foreach ($id in @($registry.Models.Keys | Sort-Object)) {
        $m = $registry.Models[$id]
        if ($m.Valid -and $m.Enabled) { [void]$models.Add([string]$id) }
    }
    return [pscustomobject]@{
        schema           = 'apipool.capabilities/1'
        build            = 'offline'
        liveTransport    = 'disabled-in-build'
        roles            = @($roles.ToArray())
        models           = @($models.ToArray())
        requestFeatures  = @('text-only')
        forbidden        = @('tools', 'tool_choice', 'mcp_servers', 'streaming', 'server-tools', 'non-text-content')
        scheduler        = 'none (caller-driven)'
    }
}

# ---------------------------------------------------------------------------
# Orchestrate adapter
# ---------------------------------------------------------------------------

function New-ApiPoolOrchestrateResult {
    param([string]$Status, [string]$ReasonCode, [AllowNull()][string]$JobId, $Handoff, [long]$CostMicroUsd)

    return [pscustomobject]@{
        schema       = 'apipool.orchestrate/1'
        status       = $Status
        reasonCode   = $ReasonCode
        jobId        = $JobId
        handoff      = $Handoff
        costMicroUsd = $CostMicroUsd
        advisoryOnly = $true
    }
}

function Test-ApiPoolFallbackCode {
    param([AllowNull()][string]$Code)

    if ([string]::IsNullOrEmpty($Code)) { return $false }
    return ($Code -ceq 'BUDGET_EXHAUSTED_GLOBAL' -or $Code -ceq 'BUDGET_EXHAUSTED_JOB' -or $Code -ceq 'BUDGET_STOPPED' -or $Code.StartsWith('LEDGER_', [System.StringComparison]::Ordinal))
}

function ConvertFrom-ApiPoolOrchestrateJob {
    param($Job)

    $jobId = [string]$Job.jobId
    $state = [string]$Job.state
    if ($state -ceq 'succeeded') {
        return (New-ApiPoolOrchestrateResult -Status 'completed' -ReasonCode 'OK' -JobId $jobId -Handoff $Job.result.handoff -CostMicroUsd ([long]$Job.result.costMicroUsd))
    }
    $code = 'JOB_' + $state.ToUpperInvariant()
    if ($null -ne $Job.PSObject.Properties['error'] -and $null -ne $Job.error) { $code = [string]$Job.error.code }
    if ($state -ceq 'failed' -and (Test-ApiPoolFallbackCode -Code $code)) {
        return (New-ApiPoolOrchestrateResult -Status 'fallback' -ReasonCode $code -JobId $jobId -Handoff $null -CostMicroUsd 0)
    }
    return (New-ApiPoolOrchestrateResult -Status 'failed' -ReasonCode $code -JobId $jobId -Handoff $null -CostMicroUsd 0)
}

function Invoke-ApiPoolOrchestrateJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Context,

        [Parameter(Mandatory = $true)]
        [string]$Role,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Brief,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ContextData,

        [string]$IdempotencyKey,

        [string]$CatalogPath
    )

    if ($null -eq $Context -or $null -eq $Context.Transport) {
        return (New-ApiPoolOrchestrateResult -Status 'fallback' -ReasonCode 'POOL_DISABLED' -JobId $null -Handoff $null -CostMicroUsd 0)
    }

    $jobId = $null
    try {
        $budget = Get-ApiPoolBudgetStatus -StateRoot $Context.StateRoot
        if ($budget.State -ceq 'STOPPED') { return (New-ApiPoolOrchestrateResult -Status 'fallback' -ReasonCode 'BUDGET_STOPPED' -JobId $null -Handoff $null -CostMicroUsd 0) }
        if ($budget.State -ceq 'CORRUPT') { return (New-ApiPoolOrchestrateResult -Status 'fallback' -ReasonCode 'LEDGER_CORRUPT' -JobId $null -Handoff $null -CostMicroUsd 0) }
        if ($budget.State -ceq 'UNINITIALIZED') { return (New-ApiPoolOrchestrateResult -Status 'fallback' -ReasonCode 'LEDGER_UNINITIALIZED' -JobId $null -Handoff $null -CostMicroUsd 0) }

        $submitArgs = @{ Context = $Context; Role = $Role; Brief = $Brief; ContextData = $ContextData }
        if (-not [string]::IsNullOrEmpty($IdempotencyKey)) { $submitArgs['IdempotencyKey'] = $IdempotencyKey }
        if (-not [string]::IsNullOrEmpty($CatalogPath)) { $submitArgs['CatalogPath'] = $CatalogPath }
        $job = Submit-ApiPoolJob @submitArgs
        $jobId = [string]$job.jobId

        $state = [string]$job.state
        if ($state -ceq 'queued') {
            $runArgs = @{ Context = $Context; JobId = $jobId }
            if (-not [string]::IsNullOrEmpty($CatalogPath)) { $runArgs['CatalogPath'] = $CatalogPath }
            $job = Invoke-ApiPoolJob @runArgs
        }
        return (ConvertFrom-ApiPoolOrchestrateJob -Job $job)
    }
    catch {
        $code = Get-ApiPoolErrorCode -ErrorRecord $_
        if ($null -eq $code) { $code = 'INTERNAL_ERROR' }
        if (Test-ApiPoolFallbackCode -Code $code) {
            return (New-ApiPoolOrchestrateResult -Status 'fallback' -ReasonCode $code -JobId $jobId -Handoff $null -CostMicroUsd 0)
        }
        return (New-ApiPoolOrchestrateResult -Status 'failed' -ReasonCode $code -JobId $jobId -Handoff $null -CostMicroUsd 0)
    }
}

Export-ModuleMember -Function @(
    'Submit-ApiPoolJob',
    'Invoke-ApiPoolJob',
    'Get-ApiPoolJob',
    'Get-ApiPoolJobResult',
    'Stop-ApiPoolJob',
    'Resume-ApiPoolJob',
    'Get-ApiPoolHealth',
    'Get-ApiPoolCapability',
    'Invoke-ApiPoolOrchestrateJob'
)
