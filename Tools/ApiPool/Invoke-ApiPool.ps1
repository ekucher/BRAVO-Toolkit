<#
    Thin command-line entrypoint of the OFFLINE ApiPool build (Windows PowerShell 5.1).
    Parses parameters, imports the modules in the fixed order and dispatches one command.
    Output: one line of compressed JSON on stdout {ok, code, data}.
    Exit codes: 0 = ok, 1 = error, 2 = usage (missing required parameters).
    This build has no provider transport: run -> MODE_OFFLINE, orchestrate -> fallback POOL_DISABLED.
#>
[CmdletBinding()]
param(
    [ValidateSet('submit', 'run', 'status', 'result', 'cancel', 'resume', 'health', 'capabilities', 'orchestrate',
        'budget-status', 'budget-init', 'budget-stop', 'budget-clear', 'budget-reconcile', 'budget-repair', 'credential-rotate')]
    [string]$Command,
    [string]$StateRoot,
    [string]$ConfigPath,
    [string]$RequestPath,
    [string]$JobId,
    [string]$ReservationId,
    [decimal]$ActualUsd,
    [string]$Reason,
    [string]$SecretPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ExitCode = 1
$script:ModulesReady = $false
$script:BoundParams = $PSBoundParameters

function Write-ApiPoolCliResult {
    param([bool]$Ok, [string]$Code, $Data, [int]$Exit)

    $json = ConvertTo-Json -InputObject ([ordered]@{ ok = $Ok; code = $Code; data = $Data }) -Compress -Depth 10
    if ($script:ModulesReady) { $json = Protect-ApiPoolText -Text $json }
    Write-Output $json
    $script:ExitCode = $Exit
}

function Get-ApiPoolCliMissing {
    # Returns the names of required parameters that were not supplied for the command.
    param([string]$Name, [System.Collections.IDictionary]$Bound)

    $need = @{
        'status' = @('JobId'); 'result' = @('JobId'); 'cancel' = @('JobId'); 'resume' = @('JobId', 'Reason')
        'submit' = @('RequestPath'); 'orchestrate' = @('RequestPath'); 'budget-clear' = @('Reason')
        'budget-repair' = @('Reason'); 'budget-reconcile' = @('ReservationId', 'ActualUsd', 'Reason'); 'credential-rotate' = @('SecretPath')
    }
    if (-not $need.ContainsKey($Name)) { return @() }
    return @($need[$Name] | Where-Object { -not $Bound.ContainsKey($_) -or ($Bound[$_] -is [string] -and [string]::IsNullOrWhiteSpace($Bound[$_])) })
}

function Read-ApiPoolCliRequest {
    param([string]$Path)

    if (-not [System.IO.File]::Exists($Path)) { Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'The request file was not found.' }
    if ((New-Object System.IO.FileInfo($Path)).Length -gt 1048576) { Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'The request file exceeds 1 MiB.' }
    try { $doc = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path)) } catch {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'The request file is not valid JSON.'
    }
    if ($doc -isnot [System.Management.Automation.PSCustomObject]) { Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'The request root must be a JSON object.' }
    $req = @{ role = ''; brief = ''; contextData = ''; idempotencyKey = '' }
    foreach ($p in $doc.PSObject.Properties) {
        if (-not $req.ContainsKey([string]$p.Name) -or $p.Value -isnot [string]) {
            Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("Request field '{0}' is not allowed or not a string." -f $p.Name)
        }
        $req[[string]$p.Name] = [string]$p.Value
    }
    return $req
}

function ConvertTo-ApiPoolCliJob {
    # Summary only: the brief and the context data are never echoed.
    param($Job)

    $summary = [ordered]@{ jobId = $Job.jobId; role = $Job.role; state = $Job.state; attempts = $Job.attempts; maxAttempts = $Job.maxAttempts; updatedUtc = $Job.updatedUtc }
    if ($null -ne $Job.PSObject.Properties['Duplicate']) { $summary['duplicate'] = $Job.Duplicate }
    if ($null -ne $Job.PSObject.Properties['error'] -and $null -ne $Job.error) { $summary['error'] = $Job.error }
    return $summary
}

function Invoke-ApiPoolCliCommand {
    $apiRoot = $PSScriptRoot
    $missing = @(Get-ApiPoolCliMissing -Name $Command -Bound $script:BoundParams)
    if ($missing.Count -gt 0) {
        Write-ApiPoolCliResult -Ok $false -Code 'USAGE' -Data @{ message = ('Missing required parameter(s): ' + ($missing -join ', ')) } -Exit 2
        return
    }

    # D15: the default state root is chosen here and nowhere else.
    if ([string]::IsNullOrEmpty($StateRoot)) {
        if ([string]::IsNullOrEmpty($env:LOCALAPPDATA)) { Invoke-ApiPoolThrow -Code 'STATE_PATH_FORBIDDEN' -Message 'LOCALAPPDATA is not set; pass -StateRoot.' }
        $StateRoot = Join-Path $env:LOCALAPPDATA 'BRAVO\ApiPool\state'
    }
    if ([string]::IsNullOrEmpty($ConfigPath)) { $ConfigPath = Join-Path (Join-Path $apiRoot 'config') 'apipool.defaults.json' }
    $repoRoot = Split-Path -Parent (Split-Path -Parent $apiRoot)
    $root = Assert-ApiPoolStateRoot -StateRoot $StateRoot -RepoRoot $repoRoot
    $config = Read-ApiPoolConfig -Path $ConfigPath
    $registry = Import-ApiPoolModelRegistry -Path (Join-Path (Join-Path $apiRoot 'config') 'models.json')
    # The offline build has no way to construct a live transport: Transport stays $null.
    $ctx = New-ApiPoolContext -StateRoot $root -Config $config -Registry $registry -Transport $null -CredentialProvider $null
    $catalog = Join-Path (Join-Path $apiRoot 'config') 'agents.json'

    switch ($Command) {
        'submit' {
            $r = Read-ApiPoolCliRequest -Path $RequestPath
            $job = Submit-ApiPoolJob -Context $ctx -Role $r.role -Brief $r.brief -ContextData $r.contextData -IdempotencyKey $r.idempotencyKey -CatalogPath $catalog
            Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data (ConvertTo-ApiPoolCliJob -Job $job) -Exit 0
        }
        'run' {
            Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data (ConvertTo-ApiPoolCliJob -Job (Invoke-ApiPoolJob -Context $ctx -JobId $JobId -CatalogPath $catalog)) -Exit 0
        }
        'status' {
            Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data (ConvertTo-ApiPoolCliJob -Job (Get-ApiPoolJob -StateRoot $root -JobId $JobId)) -Exit 0
        }
        'result' {
            Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data (Get-ApiPoolJobResult -StateRoot $root -JobId $JobId) -Exit 0
        }
        'cancel' {
            Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data (ConvertTo-ApiPoolCliJob -Job (Stop-ApiPoolJob -StateRoot $root -JobId $JobId -Reason $Reason)) -Exit 0
        }
        'resume' {
            Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data (ConvertTo-ApiPoolCliJob -Job (Resume-ApiPoolJob -Context $ctx -JobId $JobId -Reason $Reason)) -Exit 0
        }
        'health' {
            $health = Get-ApiPoolHealth -Context $ctx
            if ($health.ok) { Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data $health -Exit 0 }
            else { Write-ApiPoolCliResult -Ok $false -Code 'UNHEALTHY' -Data $health -Exit 1 }
        }
        'capabilities' {
            Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data (Get-ApiPoolCapability -CatalogPath $catalog -RegistryPath (Join-Path (Join-Path $apiRoot 'config') 'models.json')) -Exit 0
        }
        'orchestrate' {
            $r = Read-ApiPoolCliRequest -Path $RequestPath
            $out = Invoke-ApiPoolOrchestrateJob -Context $ctx -Role $r.role -Brief $r.brief -ContextData $r.contextData -IdempotencyKey $r.idempotencyKey -CatalogPath $catalog
            if ($out.status -ceq 'failed') { Write-ApiPoolCliResult -Ok $false -Code $out.reasonCode -Data $out -Exit 1 }
            else { Write-ApiPoolCliResult -Ok $true -Code $out.reasonCode -Data $out -Exit 0 }
        }
        'budget-status' {
            Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data (Get-ApiPoolBudgetStatus -StateRoot $root) -Exit 0
        }
        'budget-init' {
            $limit = [long][Math]::Floor([decimal]$config.budgetUsd * 1000000)
            Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data (Initialize-ApiPoolLedger -StateRoot $root -GlobalLimitMicroUsd $limit) -Exit 0
        }
        'budget-stop' {
            if ([string]::IsNullOrWhiteSpace($Reason)) { $Reason = 'operator stop via CLI' }
            Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data (Set-ApiPoolEmergencyStop -StateRoot $root -Reason $Reason) -Exit 0
        }
        'budget-clear' {
            Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data (Clear-ApiPoolEmergencyStop -StateRoot $root -Reason $Reason) -Exit 0
        }
        'budget-reconcile' {
            $micro = [long][Math]::Ceiling($ActualUsd * 1000000)
            Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data (Resolve-ApiPoolOrphanReservation -StateRoot $root -ReservationId $ReservationId -ActualMicroUsd $micro -Reason $Reason) -Exit 0
        }
        'budget-repair' {
            Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data (Repair-ApiPoolLedger -StateRoot $root -Reason $Reason) -Exit 0
        }
        'credential-rotate' {
            $secret = Read-Host -Prompt 'New API key (input hidden)' -AsSecureString
            Set-ApiPoolCredential -SecretPath $SecretPath -Secret $secret
            Write-ApiPoolCliResult -Ok $true -Code 'OK' -Data @{ rotated = $true } -Exit 0
        }
    }
}

try {
    foreach ($moduleName in @('Core', 'Credentials', 'Pricing', 'Budget', 'Transport', 'Adapter', 'Agents', 'Jobs')) {
        Import-Module -Name (Join-Path (Join-Path $PSScriptRoot 'modules') ('ApiPool.{0}.psm1' -f $moduleName)) -Force -Global -DisableNameChecking
    }
    $script:ModulesReady = $true
    if ([string]::IsNullOrEmpty($Command)) {
        Write-ApiPoolCliResult -Ok $false -Code 'USAGE' -Data @{ message = 'Parameter -Command is required.' } -Exit 2
    }
    else { Invoke-ApiPoolCliCommand }
}
catch {
    $code = 'INTERNAL_ERROR'
    $message = [string]$_.Exception.Message
    if ($script:ModulesReady) {
        $found = Get-ApiPoolErrorCode -ErrorRecord $_
        if ($null -ne $found) { $code = $found }
        $message = Protect-ApiPoolText -Text $message
    }
    else { $message = 'The ApiPool modules could not be loaded.' }
    Write-ApiPoolCliResult -Ok $false -Code $code -Data @{ message = $message } -Exit 1
}
exit $script:ExitCode
