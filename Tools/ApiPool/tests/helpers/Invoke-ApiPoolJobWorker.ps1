# Test helper: reads a persisted ApiPool job from a fresh process (restart check). Read-only.
param(
    [Parameter(Mandatory = $true)][string]$ModulesDir,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$JobId,
    [Parameter(Mandatory = $true)][string]$OutPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $ModulesDir 'ApiPool.Core.psm1') -Force -Global -DisableNameChecking
Import-Module -Name (Join-Path $ModulesDir 'ApiPool.Jobs.psm1') -Force -Global -DisableNameChecking

$job = Get-ApiPoolJob -StateRoot $StateRoot -JobId $JobId
$summary = [ordered]@{
    jobId        = [string]$job.jobId
    state        = [string]$job.state
    attempts     = [int]$job.attempts
    costMicroUsd = [long]$job.result.costMicroUsd
    reviewSource = [string]$job.result.handoff.review_source
}
[System.IO.File]::WriteAllText($OutPath, (ConvertTo-Json -InputObject $summary -Compress))
exit 0
