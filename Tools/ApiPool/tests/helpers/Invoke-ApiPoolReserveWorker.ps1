# Test helper: runs in a separate powershell.exe process.
# Default mode: calls New-ApiPoolReservation -Count times against a shared sandbox state root and writes
# {successes, reservationIds, refusals{code:count}, errors} as JSON to ResultPath.
# -StatusOnly: writes the ledger status as JSON to ResultPath (fresh-process persistence check).
param(
    [Parameter(Mandatory = $true)][string]$ModulesDir,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$JobPrefix = 'job',
    [int]$Count = 0,
    [long]$AmountMicroUsd = 1,
    [long]$PerJobLimitMicroUsd = 1,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [switch]$StatusOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($moduleName in @('Core', 'Credentials', 'Pricing', 'Budget')) {
    Import-Module -Name (Join-Path $ModulesDir ('ApiPool.{0}.psm1' -f $moduleName)) -Force -Global -DisableNameChecking
}

if ($StatusOnly) {
    $status = Get-ApiPoolBudgetStatus -StateRoot $StateRoot -LockTimeoutMs 30000
    Write-ApiPoolFileAtomic -Path $ResultPath -Content (ConvertTo-Json -InputObject $status -Depth 8)
    exit 0
}

$successes = 0
$ids = New-Object System.Collections.ArrayList
$refusals = @{}
for ($i = 1; $i -le $Count; $i++) {
    try {
        $r = New-ApiPoolReservation -StateRoot $StateRoot -JobId ('{0}-{1}' -f $JobPrefix, $i) -AttemptId 'a1' -AmountMicroUsd $AmountMicroUsd -PerJobLimitMicroUsd $PerJobLimitMicroUsd -LockTimeoutMs 60000
        $successes++
        [void]$ids.Add([string]$r.ReservationId)
    }
    catch {
        $code = Get-ApiPoolErrorCode -ErrorRecord $_
        if ([string]::IsNullOrEmpty($code)) { $code = 'UNCLASSIFIED' }
        if ($refusals.ContainsKey($code)) { $refusals[$code]++ } else { $refusals[$code] = 1 }
    }
}
$result = [ordered]@{ successes = $successes; reservationIds = @($ids.ToArray()); refusals = $refusals }
Write-ApiPoolFileAtomic -Path $ResultPath -Content (ConvertTo-Json -InputObject $result -Depth 6)
exit 0
