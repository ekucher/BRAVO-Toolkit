# Test helper: holds an ApiPool lock file from a child process.
# Mode Release: hold until ReleaseFile appears (max 30 s), release, exit 0.
# Mode Crash:   exit immediately after acquiring WITHOUT releasing (the OS must free the handle).
param(
    [Parameter(Mandatory = $true)][string]$CorePath,
    [Parameter(Mandatory = $true)][string]$LockPath,
    [Parameter(Mandatory = $true)][string]$ReadyFile,
    [string]$ReleaseFile,
    [ValidateSet('Release', 'Crash')][string]$Mode = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name $CorePath -Force -DisableNameChecking

$handle = Enter-ApiPoolFileLock -Path $LockPath -TimeoutMs 20000
[System.IO.File]::WriteAllText($ReadyFile, 'ready')
if ($Mode -eq 'Crash') { exit 0 }

$deadline = [System.DateTime]::UtcNow.AddSeconds(30)
while (-not [System.IO.File]::Exists($ReleaseFile) -and [System.DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 50
}
Exit-ApiPoolFileLock -Handle $handle
exit 0
