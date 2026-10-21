Set-StrictMode -Version Latest

# ApiPool.Budget: append-only, hash-chained budget ledger with reservations, emergency stop
# and torn-tail repair. Depends only on ApiPool.Core (and the Pricing money convention:
# whole micro-USD as [long]); the entrypoint imports the modules in a fixed order.
# Every operation: take ledger.lock -> full replay + verification -> decide -> append -> release.
# The hash chain detects accidental corruption, not tampering by the same OS user.

$script:ApiPoolLedgerZeroHash = ('0' * 64)

$script:ApiPoolLedgerTypeSpec = @{
    INIT         = @{ globalLimitMicroUsd = 'long' }
    RESERVE      = @{ id = 'string'; jobId = 'string'; attemptId = 'string'; amount = 'long'; perJobLimit = 'long' }
    COMMIT       = @{ id = 'string'; actual = 'long'; evidence = 'any' }
    UNDO         = @{ id = 'string'; reason = 'string' }
    UNRECONCILED = @{ id = 'string'; reason = 'string' }
    RESOLVE      = @{ id = 'string'; actual = 'long'; evidence = 'any'; reason = 'string' }
    STOP         = @{ reason = 'string' }
    CLEAR        = @{ reason = 'string' }
    OVERRUN      = @{ id = 'string'; reserved = 'long'; actual = 'long' }
    REPAIR       = @{ reason = 'string'; quarantinePath = 'string' }
}

$script:ApiPoolOverrunReason = 'automatic: cost bound violated'

# ---------------------------------------------------------------------------
# Paths, clock, validation helpers (private)
# ---------------------------------------------------------------------------

function Get-ApiPoolLedgerPaths {
    param([string]$StateRoot)

    # Every derived path goes through the canonical resolver (reparse points below the root are refused).
    $root = Assert-ApiPoolStateRoot -StateRoot $StateRoot
    $dir = Resolve-ApiPoolStatePath -StateRoot $root -RelativePath 'budget'
    return [pscustomobject]@{
        Root       = $root
        Dir        = $dir
        Ledger     = Resolve-ApiPoolStatePath -StateRoot $root -RelativePath 'budget\ledger.jsonl'
        Lock       = Resolve-ApiPoolStatePath -StateRoot $root -RelativePath 'budget\ledger.lock'
        Marker     = Resolve-ApiPoolStatePath -StateRoot $root -RelativePath 'budget\EMERGENCY_STOP'
        Quarantine = Join-Path $dir 'quarantine'
    }
}

function Get-ApiPoolLedgerTimestamp {
    param([scriptblock]$Clock)

    if ($null -eq $Clock) { $now = [System.DateTime]::UtcNow } else { $now = [System.DateTime](& $Clock) }
    return $now.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Assert-ApiPoolNonEmptyText {
    param([string]$Value, [string]$Name, [int]$MaxLength = 500)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("{0} must be a non-empty string." -f $Name)
    }
    if ($Value.Length -gt $MaxLength) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("{0} is longer than {1} characters." -f $Name, $MaxLength)
    }
}

function ConvertTo-ApiPoolLedgerEvidence {
    param($Evidence)

    $map = [ordered]@{ requestId = $null; messageId = $null; usage = $null }
    if ($null -ne $Evidence) {
        foreach ($key in @('requestId', 'messageId', 'usage')) {
            $value = $null
            if ($Evidence -is [System.Collections.IDictionary]) {
                if ($Evidence.Contains($key)) { $value = $Evidence[$key] }
            }
            elseif ($null -ne $Evidence.PSObject.Properties[$key]) {
                $value = $Evidence.PSObject.Properties[$key].Value
            }
            if ($value -is [string]) { $value = Protect-ApiPoolText -Text $value }
            $map[$key] = $value
        }
    }
    return $map
}

# ---------------------------------------------------------------------------
# Ledger replay (private)
# ---------------------------------------------------------------------------

function Test-ApiPoolLedgerFieldKind {
    param($Value, [string]$Kind)

    switch ($Kind) {
        'long' { return (($Value -is [int] -or $Value -is [long]) -and ([long]$Value -ge 0)) }
        'string' { return ($Value -is [string]) }
        default { return $true }
    }
}

function Test-ApiPoolLedgerLine {
    # Returns @{ Ok; Kind (parse|shape|chain|semantic); Reason; Record }.
    param([string]$Line, [long]$ExpectedSeq, [string]$PrevHash)

    $bad = {
        param($kind, $reason)
        return @{ Ok = $false; Kind = $kind; Reason = $reason; Record = $null }
    }

    try { $rec = ConvertFrom-Json -InputObject $Line -ErrorAction Stop } catch {
        return (& $bad 'parse' 'line is not valid JSON')
    }
    if ($rec -isnot [System.Management.Automation.PSCustomObject]) {
        return (& $bad 'shape' 'record is not a JSON object')
    }
    $expectedNames = @('seq', 'ts', 'type', 'data', 'prevHash', 'hash')
    $names = @($rec.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names.Count -ne $expectedNames.Count) { return (& $bad 'shape' 'record has unexpected fields') }
    foreach ($n in $expectedNames) {
        if ($names -cnotcontains $n) { return (& $bad 'shape' ("record is missing field '{0}'" -f $n)) }
    }
    if (-not (Test-ApiPoolLedgerFieldKind -Value $rec.seq -Kind 'long')) { return (& $bad 'shape' 'seq is not an integer') }
    if ([long]$rec.seq -ne $ExpectedSeq) {
        return (& $bad 'chain' ("sequence gap or repeat: expected seq {0} but found {1}" -f $ExpectedSeq, $rec.seq))
    }
    foreach ($n in @('ts', 'type', 'prevHash', 'hash')) {
        if ($rec.$n -isnot [string]) { return (& $bad 'shape' ("field '{0}' is not a string" -f $n)) }
    }
    if ($rec.prevHash -cne $PrevHash) { return (& $bad 'chain' ("hash chain broken at seq {0}: prevHash mismatch" -f $ExpectedSeq)) }

    $unsigned = [ordered]@{ seq = $rec.seq; ts = $rec.ts; type = $rec.type; data = $rec.data; prevHash = $rec.prevHash }
    $expectedHash = Get-ApiPoolSha256Hex -Text ($rec.prevHash + (ConvertTo-ApiPoolCanonicalJson -InputObject $unsigned))
    if ($rec.hash -cne $expectedHash) { return (& $bad 'chain' ("hash chain broken at seq {0}: record hash mismatch" -f $ExpectedSeq)) }

    if (-not $script:ApiPoolLedgerTypeSpec.ContainsKey($rec.type)) {
        return (& $bad 'semantic' ("unknown record type '{0}' at seq {1}" -f $rec.type, $ExpectedSeq))
    }
    if ($rec.data -isnot [System.Management.Automation.PSCustomObject]) { return (& $bad 'shape' 'data is not an object') }
    $spec = $script:ApiPoolLedgerTypeSpec[[string]$rec.type]
    $dataNames = @($rec.data.PSObject.Properties | ForEach-Object { $_.Name })
    $specCount = $spec.Count
    if ($rec.type -ceq 'INIT' -and $dataNames -ccontains 'schemaVersion') {
        # INIT may carry schemaVersion (new ledgers write 1; a missing field means v1). Anything else is a newer/unknown format.
        $sv = $rec.data.schemaVersion
        if (-not (($sv -is [int] -or $sv -is [long]) -and [long]$sv -eq 1)) {
            return (& $bad 'semantic' 'unsupported ledger schema (INIT schemaVersion must be 1)')
        }
        $specCount++
    }
    if ($dataNames.Count -ne $specCount) { return (& $bad 'semantic' ("data of {0} at seq {1} has unexpected fields" -f $rec.type, $ExpectedSeq)) }
    foreach ($field in $spec.Keys) {
        if ($dataNames -cnotcontains $field) { return (& $bad 'semantic' ("data of {0} at seq {1} lacks '{2}'" -f $rec.type, $ExpectedSeq, $field)) }
        if (-not (Test-ApiPoolLedgerFieldKind -Value $rec.data.$field -Kind $spec[$field])) {
            return (& $bad 'semantic' ("field '{0}' of {1} at seq {2} has an invalid value" -f $field, $rec.type, $ExpectedSeq))
        }
    }
    return @{ Ok = $true; Kind = ''; Reason = ''; Record = $rec }
}

function Add-ApiPoolLedgerModelRecord {
    # Applies one verified record to the model. Returns $null or a corruption reason.
    param($Ledger, $Rec, [bool]$IsFirst)

    $type = [string]$Rec.type
    $data = $Rec.data
    $seq = [long]$Rec.seq
    if ($IsFirst -and $type -cne 'INIT') { return 'first record is not INIT' }
    if (-not $IsFirst -and $type -ceq 'INIT') { return ("INIT repeated at seq {0}" -f $seq) }

    $res = $Ledger.Reservations
    switch -CaseSensitive ($type) {
        'INIT' {
            if ([long]$data.globalLimitMicroUsd -le 0) { return 'INIT limit is not positive' }
            $Ledger.Limit = [long]$data.globalLimitMicroUsd
        }
        'RESERVE' {
            if ($res.ContainsKey([string]$data.id)) { return ("duplicate reservation id {0} at seq {1}" -f $data.id, $seq) }
            $res[[string]$data.id] = [pscustomobject]@{
                Id = [string]$data.id; JobId = [string]$data.jobId; AttemptId = [string]$data.attemptId
                Amount = [long]$data.amount; PerJobLimit = [long]$data.perJobLimit
                State = 'RESERVED'; Actual = [long]0; Seq = $seq
            }
            # F1-6: the effective per-job limit is the minimum of every limit ever recorded for the job.
            $jl = [long]$data.perJobLimit
            $jk = [string]$data.jobId
            if (-not $Ledger.JobLimitMin.ContainsKey($jk) -or $jl -lt [long]$Ledger.JobLimitMin[$jk]) { $Ledger.JobLimitMin[$jk] = $jl }
        }
        { $_ -ceq 'COMMIT' -or $_ -ceq 'UNDO' -or $_ -ceq 'UNRECONCILED' } {
            $r = $null
            if ($res.ContainsKey([string]$data.id)) { $r = $res[[string]$data.id] }
            if ($null -eq $r) { return ("{0} for unknown reservation {1} at seq {2}" -f $type, $data.id, $seq) }
            if ($r.State -cne 'RESERVED') { return ("illegal {0} on reservation {1} in state {2} at seq {3}" -f $type, $data.id, $r.State, $seq) }
            if ($type -ceq 'COMMIT') {
                $r.State = 'COMMITTED'; $r.Actual = [long]$data.actual
                # F1-1: an overrun commit blocks spend even when the crash happened before OVERRUN/STOP were appended.
                if ($r.Actual -gt $r.Amount) { $Ledger.DerivedStop = $true }
            }
            elseif ($type -ceq 'UNDO') { $r.State = 'UNDONE' }
            else { $r.State = 'UNRECONCILED' }
        }
        'RESOLVE' {
            $r = $null
            if ($res.ContainsKey([string]$data.id)) { $r = $res[[string]$data.id] }
            if ($null -eq $r) { return ("RESOLVE for unknown reservation {0} at seq {1}" -f $data.id, $seq) }
            if ($r.State -cne 'RESERVED' -and $r.State -cne 'UNRECONCILED') {
                return ("illegal RESOLVE on reservation {0} in state {1} at seq {2}" -f $data.id, $r.State, $seq)
            }
            $r.State = 'RESOLVED'
            $r.Actual = [long]$data.actual
            if ($r.Actual -gt $r.Amount) { $Ledger.DerivedStop = $true }
        }
        'OVERRUN' {
            if (-not $res.ContainsKey([string]$data.id)) { return ("OVERRUN for unknown reservation {0} at seq {1}" -f $data.id, $seq) }
        }
        'STOP' {
            $Ledger.StopRecord = $true
            $Ledger.StopReason = [string]$data.reason
        }
        'CLEAR' {
            $Ledger.StopRecord = $false
            $Ledger.StopReason = $null
            $Ledger.DerivedStop = $false
        }
        'REPAIR' { }
    }
    return $null
}

function Read-ApiPoolLedger {
    # Full replay and verification of the ledger file. Caller holds ledger.lock.
    param($Paths)

    $ledger = [pscustomobject]@{
        State = 'ABSENT'; Reason = $null; Torn = $false; TornPrefixBytes = [long]0
        ValidRecords = 0; LastSeq = [long]0; LastHash = $script:ApiPoolLedgerZeroHash
        Limit = [long]0; Reservations = @{}; StopRecord = $false; StopReason = $null
        DerivedStop = $false; JobLimitMin = @{}
        Committed = [decimal]0; Reserved = [decimal]0; Unreconciled = [decimal]0; JobCost = @{}
    }
    if (-not [System.IO.File]::Exists($Paths.Ledger)) { return $ledger }

    $corrupt = {
        param($reason, $torn, $prefixBytes)
        $ledger.State = 'CORRUPT'
        $ledger.Reason = $reason
        $ledger.Torn = [bool]$torn
        $ledger.TornPrefixBytes = [long]$prefixBytes
        return $ledger
    }

    $bytes = [System.IO.File]::ReadAllBytes($Paths.Ledger)
    if ($bytes.Length -eq 0) { return (& $corrupt 'ledger file is empty' $false 0) }
    $lastNl = [System.Array]::LastIndexOf($bytes, [byte]10)
    $prefixLen = $lastNl + 1
    $tailLen = $bytes.Length - $prefixLen

    $lines = @()
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    if ($prefixLen -gt 0) {
        try { $text = $utf8.GetString($bytes, 0, $prefixLen) } catch {
            return (& $corrupt 'ledger contains invalid UTF-8' $false 0)
        }
        $lines = @($text.Substring(0, $text.Length - 1).Split([char]10))
    }

    $offset = [long]0
    $count = $lines.Count
    for ($i = 0; $i -lt $count; $i++) {
        $line = [string]$lines[$i]
        $check = Test-ApiPoolLedgerLine -Line $line -ExpectedSeq ($ledger.LastSeq + 1) -PrevHash $ledger.LastHash
        $reason = $null
        if (-not $check.Ok) {
            $reason = ("line {0}: {1}" -f ($i + 1), $check.Reason)
        }
        else {
            $reason = Add-ApiPoolLedgerModelRecord -Ledger $ledger -Rec $check.Record -IsFirst ($i -eq 0)
            if ($null -ne $reason) { $reason = ("line {0}: {1}" -f ($i + 1), $reason) }
        }
        if ($null -ne $reason) {
            $tornLast = ((-not $check.Ok) -and $check.Kind -ceq 'parse' -and ($i -eq $count - 1) -and $tailLen -eq 0 -and $i -ge 1)
            return (& $corrupt $reason $tornLast $offset)
        }
        $ledger.LastSeq = [long]$check.Record.seq
        $ledger.LastHash = [string]$check.Record.hash
        $ledger.ValidRecords++
        $offset += [long]($utf8.GetByteCount($line) + 1)
    }
    if ($tailLen -gt 0) {
        return (& $corrupt 'unterminated last line (torn write)' ($ledger.ValidRecords -ge 1) $prefixLen)
    }

    foreach ($r in $ledger.Reservations.Values) {
        $cost = [decimal]0
        switch ($r.State) {
            'RESERVED' { $ledger.Reserved += [decimal]$r.Amount; $cost = [decimal]$r.Amount }
            'UNRECONCILED' { $ledger.Unreconciled += [decimal]$r.Amount; $cost = [decimal]$r.Amount }
            'COMMITTED' { $ledger.Committed += [decimal]$r.Actual; $cost = [decimal]$r.Actual }
            'RESOLVED' { $ledger.Committed += [decimal]$r.Actual; $cost = [decimal]$r.Actual }
        }
        if (-not $ledger.JobCost.ContainsKey($r.JobId)) { $ledger.JobCost[$r.JobId] = [decimal]0 }
        $ledger.JobCost[$r.JobId] += $cost
    }
    $ledger.State = 'OK'
    return $ledger
}

function Add-ApiPoolLedgerRecord {
    # Appends one chained record and advances the in-memory chain head. Caller holds ledger.lock.
    param($Ledger, $Paths, [scriptblock]$Clock, [string]$Type, $Data)

    $unsigned = [ordered]@{
        seq      = ($Ledger.LastSeq + 1)
        ts       = (Get-ApiPoolLedgerTimestamp -Clock $Clock)
        type     = $Type
        data     = $Data
        prevHash = $Ledger.LastHash
    }
    $hash = Get-ApiPoolSha256Hex -Text ($Ledger.LastHash + (ConvertTo-ApiPoolCanonicalJson -InputObject $unsigned))
    $full = [ordered]@{}
    foreach ($k in $unsigned.Keys) { $full[$k] = $unsigned[$k] }
    $full['hash'] = $hash
    Add-ApiPoolLineDurable -Path $Paths.Ledger -Line (ConvertTo-ApiPoolCanonicalJson -InputObject $full)
    $Ledger.LastSeq = [long]$unsigned.seq
    $Ledger.LastHash = $hash
}

function Assert-ApiPoolLedgerUsable {
    param($Ledger)

    if ($Ledger.State -ceq 'CORRUPT') {
        Invoke-ApiPoolThrow -Code 'LEDGER_CORRUPT' -Message ("Budget ledger is corrupt: {0}" -f $Ledger.Reason) -Details @{ reason = [string]$Ledger.Reason }
    }
    if ($Ledger.State -ceq 'ABSENT') {
        Invoke-ApiPoolThrow -Code 'LEDGER_UNINITIALIZED' -Message 'Budget ledger is not initialized.'
    }
}

function Read-ApiPoolStopMarker {
    param($Paths)

    if (-not [System.IO.File]::Exists($Paths.Marker)) { return $null }
    $reason = 'emergency stop marker present'
    try {
        $parsed = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Paths.Marker)) -ErrorAction Stop
        if ($parsed -is [System.Management.Automation.PSCustomObject] -and $null -ne $parsed.PSObject.Properties['reason'] -and $parsed.reason -is [string]) {
            $reason = [string]$parsed.reason
        }
    }
    catch { $reason = 'emergency stop marker present (unreadable content)' }
    return [pscustomobject]@{ Reason = $reason }
}

function Write-ApiPoolStopMarker {
    param($Paths, [string]$Reason, [scriptblock]$Clock)

    $payload = ConvertTo-ApiPoolCanonicalJson -InputObject ([ordered]@{ reason = (Protect-ApiPoolText -Text $Reason); ts = (Get-ApiPoolLedgerTimestamp -Clock $Clock) })
    Write-ApiPoolFileAtomic -Path $Paths.Marker -Content $payload
}

function Get-ApiPoolLedgerReservation {
    param($Ledger, [string]$ReservationId)

    if ($Ledger.Reservations.ContainsKey($ReservationId)) { return $Ledger.Reservations[$ReservationId] }
    Invoke-ApiPoolThrow -Code 'RESERVATION_NOT_FOUND' -Message ("Reservation '{0}' was not found." -f $ReservationId)
}

function Add-ApiPoolOverrunRecords {
    # Called after the COMMIT/RESOLVE record (spend is already counted); then OVERRUN and STOP records.
    param($Ledger, $Paths, [scriptblock]$Clock, [string]$ReservationId, [long]$Reserved, [long]$Actual)

    Add-ApiPoolLedgerRecord -Ledger $Ledger -Paths $Paths -Clock $Clock -Type 'OVERRUN' -Data ([ordered]@{ id = $ReservationId; reserved = $Reserved; actual = $Actual })
    Add-ApiPoolLedgerRecord -Ledger $Ledger -Paths $Paths -Clock $Clock -Type 'STOP' -Data ([ordered]@{ reason = $script:ApiPoolOverrunReason })
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Initialize-ApiPoolLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][long]$GlobalLimitMicroUsd,
        [int]$LockTimeoutMs = 10000,
        [scriptblock]$Clock
    )

    $paths = Get-ApiPoolLedgerPaths -StateRoot $StateRoot
    if ($GlobalLimitMicroUsd -le 0) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'GlobalLimitMicroUsd must be positive.'
    }
    $lock = Enter-ApiPoolFileLock -Path $paths.Lock -TimeoutMs $LockTimeoutMs
    try {
        $ledger = Read-ApiPoolLedger -Paths $paths
        if ($ledger.State -ceq 'CORRUPT') { Assert-ApiPoolLedgerUsable -Ledger $ledger }
        if ($ledger.State -ceq 'OK') {
            if ($ledger.Limit -ne $GlobalLimitMicroUsd) {
                Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message 'ledger initialized with a different global limit' -Details @{ existing = [string]$ledger.Limit; requested = [string]$GlobalLimitMicroUsd }
            }
            return [pscustomobject]@{ Created = $false; GlobalLimitMicroUsd = $ledger.Limit }
        }
        Add-ApiPoolLedgerRecord -Ledger $ledger -Paths $paths -Clock $Clock -Type 'INIT' -Data ([ordered]@{ globalLimitMicroUsd = $GlobalLimitMicroUsd; schemaVersion = 1 })
        return [pscustomobject]@{ Created = $true; GlobalLimitMicroUsd = $GlobalLimitMicroUsd }
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lock
    }
}

function Get-ApiPoolBudgetStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [int]$LockTimeoutMs = 10000,
        [scriptblock]$Clock
    )

    $paths = Get-ApiPoolLedgerPaths -StateRoot $StateRoot
    $ledger = $null
    $marker = $null
    if ([System.IO.Directory]::Exists($paths.Dir)) {
        $lock = Enter-ApiPoolFileLock -Path $paths.Lock -TimeoutMs $LockTimeoutMs
        try {
            $ledger = Read-ApiPoolLedger -Paths $paths
            $marker = Read-ApiPoolStopMarker -Paths $paths
        }
        finally {
            Exit-ApiPoolFileLock -Handle $lock
        }
    }
    else {
        $ledger = Read-ApiPoolLedger -Paths $paths
        $marker = Read-ApiPoolStopMarker -Paths $paths
    }

    $recordActive = ($ledger.State -ceq 'OK' -and $ledger.StopRecord)
    $derivedActive = ($ledger.State -ceq 'OK' -and $ledger.DerivedStop)
    $markerActive = ($null -ne $marker)
    $source = $null
    $reason = $null
    if ($recordActive -and $markerActive) { $source = 'both'; $reason = $marker.Reason }
    elseif ($markerActive) { $source = 'marker'; $reason = $marker.Reason }
    elseif ($recordActive) { $source = 'record'; $reason = $ledger.StopReason }
    elseif ($derivedActive) { $source = 'derived'; $reason = $script:ApiPoolOverrunReason }
    $stop = [pscustomobject]@{ Active = ($recordActive -or $markerActive -or $derivedActive); Reason = $reason; Source = $source }

    $status = [pscustomobject]@{
        State                = 'UNINITIALIZED'
        GlobalLimitMicroUsd  = $null
        CommittedMicroUsd    = $null
        ReservedMicroUsd     = $null
        UnreconciledMicroUsd = $null
        AvailableMicroUsd    = [long]0
        EmergencyStop        = $stop
        OpenReservations     = @()
        LastSeq              = [long]$ledger.LastSeq
        CorruptReason        = $null
    }
    if ($ledger.State -ceq 'CORRUPT') {
        $status.State = 'CORRUPT'
        $status.CorruptReason = [string]$ledger.Reason
        return $status
    }
    if ($ledger.State -ceq 'ABSENT') { return $status }

    $available = [decimal]$ledger.Limit - $ledger.Committed - $ledger.Reserved - $ledger.Unreconciled
    if ($available -lt 0) { $available = [decimal]0 }
    $open = New-Object System.Collections.ArrayList
    foreach ($r in @($ledger.Reservations.Values | Where-Object { $_.State -ceq 'RESERVED' -or $_.State -ceq 'UNRECONCILED' } | Sort-Object -Property Seq)) {
        [void]$open.Add([pscustomobject]@{
                ReservationId = $r.Id; JobId = $r.JobId; AttemptId = $r.AttemptId
                AmountMicroUsd = [long]$r.Amount; State = $r.State; Seq = [long]$r.Seq
            })
    }
    $status.State = if ($stop.Active) { 'STOPPED' } else { 'OK' }
    $status.GlobalLimitMicroUsd = [long]$ledger.Limit
    $status.CommittedMicroUsd = [long]$ledger.Committed
    $status.ReservedMicroUsd = [long]$ledger.Reserved
    $status.UnreconciledMicroUsd = [long]$ledger.Unreconciled
    $status.AvailableMicroUsd = [long]$available
    $status.OpenReservations = @($open.ToArray())
    return $status
}

function New-ApiPoolReservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$AttemptId,
        [Parameter(Mandatory = $true)][long]$AmountMicroUsd,
        [Parameter(Mandatory = $true)][long]$PerJobLimitMicroUsd,
        [int]$LockTimeoutMs = 10000,
        [scriptblock]$Clock
    )

    $paths = Get-ApiPoolLedgerPaths -StateRoot $StateRoot
    Assert-ApiPoolNonEmptyText -Value $JobId -Name 'JobId' -MaxLength 200
    Assert-ApiPoolNonEmptyText -Value $AttemptId -Name 'AttemptId' -MaxLength 200
    if ($AmountMicroUsd -le 0) { Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'Reservation amount must be positive.' }
    if ($PerJobLimitMicroUsd -le 0) { Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'Per-job limit must be positive.' }

    $lock = Enter-ApiPoolFileLock -Path $paths.Lock -TimeoutMs $LockTimeoutMs
    try {
        $ledger = Read-ApiPoolLedger -Paths $paths
        Assert-ApiPoolLedgerUsable -Ledger $ledger

        $marker = Read-ApiPoolStopMarker -Paths $paths
        if ($null -ne $marker -or $ledger.StopRecord -or $ledger.DerivedStop) {
            Invoke-ApiPoolThrow -Code 'BUDGET_STOPPED' -Message 'Budget is stopped (emergency stop is active).'
        }
        $outstanding = $ledger.Committed + $ledger.Reserved + $ledger.Unreconciled
        if (($outstanding + [decimal]$AmountMicroUsd) -gt [decimal]$ledger.Limit) {
            Invoke-ApiPoolThrow -Code 'BUDGET_EXHAUSTED_GLOBAL' -Message 'Reservation would exceed the global budget limit.' -Details @{ amount = [string]$AmountMicroUsd; available = [string]([Math]::Max([decimal]0, [decimal]$ledger.Limit - $outstanding)) }
        }
        $jobCost = [decimal]0
        if ($ledger.JobCost.ContainsKey($JobId)) { $jobCost = $ledger.JobCost[$JobId] }
        $effectiveJobLimit = [long]$PerJobLimitMicroUsd
        if ($ledger.JobLimitMin.ContainsKey($JobId) -and [long]$ledger.JobLimitMin[$JobId] -lt $effectiveJobLimit) { $effectiveJobLimit = [long]$ledger.JobLimitMin[$JobId] }
        if (($jobCost + [decimal]$AmountMicroUsd) -gt [decimal]$effectiveJobLimit) {
            Invoke-ApiPoolThrow -Code 'BUDGET_EXHAUSTED_JOB' -Message 'Reservation would exceed the per-job limit.' -Details @{ jobId = $JobId }
        }

        $id = 'rsv-' + [guid]::NewGuid().ToString('N').Substring(0, 24)
        while ($ledger.Reservations.ContainsKey($id)) { $id = 'rsv-' + [guid]::NewGuid().ToString('N').Substring(0, 24) }
        Add-ApiPoolLedgerRecord -Ledger $ledger -Paths $paths -Clock $Clock -Type 'RESERVE' -Data ([ordered]@{
                id = $id; jobId = $JobId; attemptId = $AttemptId; amount = $AmountMicroUsd; perJobLimit = $PerJobLimitMicroUsd
            })
        return [pscustomobject]@{
            ReservationId           = $id
            AmountMicroUsd          = $AmountMicroUsd
            AvailableAfterMicroUsd  = [long]([decimal]$ledger.Limit - $outstanding - [decimal]$AmountMicroUsd)
        }
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lock
    }
}

function Complete-ApiPoolReservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ReservationId,
        [Parameter(Mandatory = $true)][long]$ActualMicroUsd,
        [hashtable]$Evidence,
        [int]$LockTimeoutMs = 10000,
        [scriptblock]$Clock
    )

    $paths = Get-ApiPoolLedgerPaths -StateRoot $StateRoot
    if ($ActualMicroUsd -lt 0) { Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'Actual cost must not be negative.' }
    $lock = Enter-ApiPoolFileLock -Path $paths.Lock -TimeoutMs $LockTimeoutMs
    try {
        $ledger = Read-ApiPoolLedger -Paths $paths
        Assert-ApiPoolLedgerUsable -Ledger $ledger
        $r = Get-ApiPoolLedgerReservation -Ledger $ledger -ReservationId $ReservationId
        if ($r.State -cne 'RESERVED') {
            Invoke-ApiPoolThrow -Code 'RESERVATION_STATE_INVALID' -Message ("Reservation '{0}' is in state {1}; only an open reservation can be completed." -f $ReservationId, $r.State)
        }
        $overrun = ($ActualMicroUsd -gt $r.Amount)
        $markerError = $null
        Add-ApiPoolLedgerRecord -Ledger $ledger -Paths $paths -Clock $Clock -Type 'COMMIT' -Data ([ordered]@{
                id = $ReservationId; actual = $ActualMicroUsd; evidence = (ConvertTo-ApiPoolLedgerEvidence -Evidence $Evidence)
            })
        if ($overrun) {
            Add-ApiPoolOverrunRecords -Ledger $ledger -Paths $paths -Clock $Clock -ReservationId $ReservationId -Reserved $r.Amount -Actual $ActualMicroUsd
            # The marker is a secondary stop signal: its failure never undoes or skips ledger records.
            try { Write-ApiPoolStopMarker -Paths $paths -Reason $script:ApiPoolOverrunReason -Clock $Clock }
            catch { $markerError = [string]$_.Exception.Message }
        }
        return [pscustomobject]@{
            ReservationId     = $ReservationId
            ReservedMicroUsd  = [long]$r.Amount
            ActualMicroUsd    = $ActualMicroUsd
            Overrun           = $overrun
            EmergencyStop     = $overrun
            MarkerError       = $markerError
        }
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lock
    }
}

function Undo-ApiPoolReservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ReservationId,
        [Parameter(Mandatory = $true)][string]$Reason,
        [int]$LockTimeoutMs = 10000,
        [scriptblock]$Clock
    )

    $paths = Get-ApiPoolLedgerPaths -StateRoot $StateRoot
    Assert-ApiPoolNonEmptyText -Value $Reason -Name 'Reason'
    $lock = Enter-ApiPoolFileLock -Path $paths.Lock -TimeoutMs $LockTimeoutMs
    try {
        $ledger = Read-ApiPoolLedger -Paths $paths
        Assert-ApiPoolLedgerUsable -Ledger $ledger
        $r = Get-ApiPoolLedgerReservation -Ledger $ledger -ReservationId $ReservationId
        if ($r.State -cne 'RESERVED') {
            Invoke-ApiPoolThrow -Code 'RESERVATION_STATE_INVALID' -Message ("Reservation '{0}' is in state {1}; only an open reservation can be undone." -f $ReservationId, $r.State)
        }
        Add-ApiPoolLedgerRecord -Ledger $ledger -Paths $paths -Clock $Clock -Type 'UNDO' -Data ([ordered]@{ id = $ReservationId; reason = (Protect-ApiPoolText -Text $Reason) })
        return [pscustomobject]@{ ReservationId = $ReservationId; ReleasedMicroUsd = [long]$r.Amount }
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lock
    }
}

function Set-ApiPoolReservationUnreconciled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ReservationId,
        [Parameter(Mandatory = $true)][string]$Reason,
        [int]$LockTimeoutMs = 10000,
        [scriptblock]$Clock
    )

    $paths = Get-ApiPoolLedgerPaths -StateRoot $StateRoot
    Assert-ApiPoolNonEmptyText -Value $Reason -Name 'Reason'
    $lock = Enter-ApiPoolFileLock -Path $paths.Lock -TimeoutMs $LockTimeoutMs
    try {
        $ledger = Read-ApiPoolLedger -Paths $paths
        Assert-ApiPoolLedgerUsable -Ledger $ledger
        $r = Get-ApiPoolLedgerReservation -Ledger $ledger -ReservationId $ReservationId
        if ($r.State -cne 'RESERVED') {
            Invoke-ApiPoolThrow -Code 'RESERVATION_STATE_INVALID' -Message ("Reservation '{0}' is in state {1}; only an open reservation can become unreconciled." -f $ReservationId, $r.State)
        }
        Add-ApiPoolLedgerRecord -Ledger $ledger -Paths $paths -Clock $Clock -Type 'UNRECONCILED' -Data ([ordered]@{ id = $ReservationId; reason = (Protect-ApiPoolText -Text $Reason) })
        return [pscustomobject]@{ ReservationId = $ReservationId; CountedMicroUsd = [long]$r.Amount }
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lock
    }
}

function Resolve-ApiPoolOrphanReservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ReservationId,
        [Parameter(Mandatory = $true)][long]$ActualMicroUsd,
        [hashtable]$Evidence,
        [Parameter(Mandatory = $true)][string]$Reason,
        [int]$LockTimeoutMs = 10000,
        [scriptblock]$Clock
    )

    $paths = Get-ApiPoolLedgerPaths -StateRoot $StateRoot
    Assert-ApiPoolNonEmptyText -Value $Reason -Name 'Reason'
    if ($ActualMicroUsd -lt 0) { Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'Actual cost must not be negative.' }
    $lock = Enter-ApiPoolFileLock -Path $paths.Lock -TimeoutMs $LockTimeoutMs
    try {
        $ledger = Read-ApiPoolLedger -Paths $paths
        Assert-ApiPoolLedgerUsable -Ledger $ledger
        $r = Get-ApiPoolLedgerReservation -Ledger $ledger -ReservationId $ReservationId
        if ($r.State -cne 'RESERVED' -and $r.State -cne 'UNRECONCILED') {
            Invoke-ApiPoolThrow -Code 'RESERVATION_STATE_INVALID' -Message ("Reservation '{0}' is in state {1}; only an open or unreconciled reservation can be resolved." -f $ReservationId, $r.State)
        }
        $overrun = ($ActualMicroUsd -gt $r.Amount)
        $markerError = $null
        Add-ApiPoolLedgerRecord -Ledger $ledger -Paths $paths -Clock $Clock -Type 'RESOLVE' -Data ([ordered]@{
                id = $ReservationId; actual = $ActualMicroUsd; evidence = (ConvertTo-ApiPoolLedgerEvidence -Evidence $Evidence); reason = (Protect-ApiPoolText -Text $Reason)
            })
        if ($overrun) {
            Add-ApiPoolOverrunRecords -Ledger $ledger -Paths $paths -Clock $Clock -ReservationId $ReservationId -Reserved $r.Amount -Actual $ActualMicroUsd
            # The marker is a secondary stop signal: its failure never undoes or skips ledger records.
            try { Write-ApiPoolStopMarker -Paths $paths -Reason $script:ApiPoolOverrunReason -Clock $Clock }
            catch { $markerError = [string]$_.Exception.Message }
        }
        return [pscustomobject]@{
            ReservationId     = $ReservationId
            ReservedMicroUsd  = [long]$r.Amount
            ActualMicroUsd    = $ActualMicroUsd
            Overrun           = $overrun
            EmergencyStop     = $overrun
            MarkerError       = $markerError
        }
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lock
    }
}

function Set-ApiPoolEmergencyStop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$Reason,
        [int]$LockTimeoutMs = 10000,
        [scriptblock]$Clock
    )

    $paths = Get-ApiPoolLedgerPaths -StateRoot $StateRoot
    Assert-ApiPoolNonEmptyText -Value $Reason -Name 'Reason'
    $lock = Enter-ApiPoolFileLock -Path $paths.Lock -TimeoutMs $LockTimeoutMs
    try {
        # The marker is written first and regardless of ledger health: a stop must always be possible.
        Write-ApiPoolStopMarker -Paths $paths -Reason $Reason -Clock $Clock
        $ledger = Read-ApiPoolLedger -Paths $paths
        $recorded = $false
        if ($ledger.State -ceq 'OK' -and -not $ledger.StopRecord) {
            Add-ApiPoolLedgerRecord -Ledger $ledger -Paths $paths -Clock $Clock -Type 'STOP' -Data ([ordered]@{ reason = (Protect-ApiPoolText -Text $Reason) })
            $recorded = $true
        }
        return [pscustomobject]@{ MarkerWritten = $true; RecordAppended = $recorded; LedgerState = [string]$ledger.State }
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lock
    }
}

function Clear-ApiPoolEmergencyStop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$Reason,
        [int]$LockTimeoutMs = 10000,
        [scriptblock]$Clock
    )

    $paths = Get-ApiPoolLedgerPaths -StateRoot $StateRoot
    Assert-ApiPoolNonEmptyText -Value $Reason -Name 'Reason'
    $lock = Enter-ApiPoolFileLock -Path $paths.Lock -TimeoutMs $LockTimeoutMs
    try {
        $ledger = Read-ApiPoolLedger -Paths $paths
        Assert-ApiPoolLedgerUsable -Ledger $ledger
        # Marker removed first: a crash in between leaves the STOP record active (safe side).
        $markerRemoved = [System.IO.File]::Exists($paths.Marker)
        if ($markerRemoved) { [System.IO.File]::Delete($paths.Marker) }
        Add-ApiPoolLedgerRecord -Ledger $ledger -Paths $paths -Clock $Clock -Type 'CLEAR' -Data ([ordered]@{ reason = (Protect-ApiPoolText -Text $Reason) })
        return [pscustomobject]@{ MarkerRemoved = $markerRemoved; RecordAppended = $true }
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lock
    }
}

function Repair-ApiPoolLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$Reason,
        [int]$LockTimeoutMs = 10000,
        [scriptblock]$Clock
    )

    $paths = Get-ApiPoolLedgerPaths -StateRoot $StateRoot
    Assert-ApiPoolNonEmptyText -Value $Reason -Name 'Reason'
    # The quarantine directory is validated before the lock is taken and before anything is copied.
    $quarantineDir = Resolve-ApiPoolStatePath -StateRoot $paths.Root -RelativePath 'budget\quarantine'
    $lock = Enter-ApiPoolFileLock -Path $paths.Lock -TimeoutMs $LockTimeoutMs
    try {
        $ledger = Read-ApiPoolLedger -Paths $paths
        if ($ledger.State -ceq 'ABSENT') { Assert-ApiPoolLedgerUsable -Ledger $ledger }
        if ($ledger.State -ceq 'OK') {
            return [pscustomobject]@{ Repaired = $false; QuarantinePath = $null; TruncatedBytes = [long]0 }
        }
        if (-not $ledger.Torn) { Assert-ApiPoolLedgerUsable -Ledger $ledger }

        $all = [System.IO.File]::ReadAllBytes($paths.Ledger)
        $prefixLen = [int]$ledger.TornPrefixBytes
        $stamp = (Get-ApiPoolLedgerTimestamp -Clock $Clock).Replace(':', '').Replace('-', '').Replace('.', '')
        $quarantine = Resolve-ApiPoolStatePath -StateRoot $paths.Root -RelativePath ('budget\quarantine\ledger-{0}.jsonl' -f $stamp)
        if ([System.IO.File]::Exists($quarantine)) {
            $quarantine = Resolve-ApiPoolStatePath -StateRoot $paths.Root -RelativePath ('budget\quarantine\ledger-{0}-{1}.jsonl' -f $stamp, [guid]::NewGuid().ToString('N').Substring(0, 8))
        }
        if (-not [System.IO.Directory]::Exists($quarantineDir)) { [void][System.IO.Directory]::CreateDirectory($quarantineDir) }
        [System.IO.File]::Copy($paths.Ledger, $quarantine, $false)

        $kept = New-Object byte[] $prefixLen
        [System.Array]::Copy($all, 0, $kept, 0, $prefixLen)
        Write-ApiPoolBytesAtomic -Path $paths.Ledger -Bytes $kept

        $after = Read-ApiPoolLedger -Paths $paths
        if ($after.State -cne 'OK') {
            Invoke-ApiPoolThrow -Code 'LEDGER_CORRUPT' -Message ("Budget ledger is still corrupt after truncating the torn tail: {0}" -f $after.Reason) -Details @{ quarantine = $quarantine }
        }
        Add-ApiPoolLedgerRecord -Ledger $after -Paths $paths -Clock $Clock -Type 'REPAIR' -Data ([ordered]@{ reason = (Protect-ApiPoolText -Text $Reason); quarantinePath = $quarantine })
        return [pscustomobject]@{ Repaired = $true; QuarantinePath = $quarantine; TruncatedBytes = [long]($all.Length - $prefixLen) }
    }
    finally {
        Exit-ApiPoolFileLock -Handle $lock
    }
}

Export-ModuleMember -Function @(
    'Initialize-ApiPoolLedger',
    'Get-ApiPoolBudgetStatus',
    'New-ApiPoolReservation',
    'Complete-ApiPoolReservation',
    'Undo-ApiPoolReservation',
    'Set-ApiPoolReservationUnreconciled',
    'Resolve-ApiPoolOrphanReservation',
    'Set-ApiPoolEmergencyStop',
    'Clear-ApiPoolEmergencyStop',
    'Repair-ApiPoolLedger'
)
