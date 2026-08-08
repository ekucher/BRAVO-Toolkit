#requires -Version 3.0

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    Split-Path -Path $MyInvocation.MyCommand.Path -Parent
} else {
    [Environment]::CurrentDirectory
}

$loaderPath = Join-Path $scriptRoot 'BRAVO_CONFIG_LOADER.ps1'
if (-not (Test-Path -LiteralPath $loaderPath -PathType Leaf)) {
    throw "Configuration loader not found: $loaderPath"
}

. $loaderPath

$result = Import-BravoConfiguration `
    -ConfigRoot $scriptRoot `
    -ConfigPath $ConfigPath `
    -PassThru

# Ефективні корені (з урахуванням AUTO) обчислює BRAVO.config і публікує
# як $global-змінні. Config Test показує саме final effective values, а не
# лише raw config strings (ТЗ RuntimeRoot/LIMSRoot §53, §88).
$limsRootResult = $global:limsRootResult
$systemLogRootResult = $global:systemLogRootResult
$backupRootResult = $global:backupRootResult
$validation = [pscustomobject]@{
    Status = 'OK'
    Product = $result.Version.Product
    PackageVersion = $result.Version.PackageVersion
    LegacyScriptVersion = $result.Configuration.LegacyScriptVersion
    PackageVersionMatchesLegacyConfig = $result.Configuration.PackageVersionMatchesLegacyConfig
    ConfigSchemaVersion = $result.Configuration.ConfigSchemaVersion
    ConfigFormat = $result.Configuration.Format
    ConfigPath = $result.Configuration.ConfigPath
    RuntimeRoot = [string]$global:runtimeRoot
    RuntimeLogRoot = [string]$global:runtimeLogRoot
    ConfiguredLIMSRoot = [string]$limsRootResult.ConfiguredPath
    EffectiveLIMSRoot = [string]$global:effectiveLimsRoot
    LIMSRootSource = [string]$limsRootResult.Source
    ConfiguredSystemLogRoot = [string]$systemLogRootResult.ConfiguredPath
    EffectiveSystemLogRoot = [string]$global:systemLogRoot
    SystemLogRootSource = [string]$systemLogRootResult.Source
    ConfiguredBackupRoot = [string]$backupRootResult.ConfiguredPath
    EffectiveBackupRoot = [string]$global:backupRootPath
    BackupRootSource = [string]$backupRootResult.Source
    StateRoot = [string]$global:stateRoot
    OperationLockPath = [string]$global:operationLockSettings.Path
    LoadedAt = $result.Configuration.LoadedAt
}

if ($AsJson) {
    $validation | ConvertTo-Json -Depth 5
    exit 0
}

Write-Host ('[INFO] Configuration loaded: {0}' -f $validation.ConfigPath)
Write-Host ('[INFO] Package version: {0}' -f $validation.PackageVersion)
Write-Host ('[INFO] Legacy config version: {0}' -f $validation.LegacyScriptVersion)
Write-Host ('[INFO] Configuration schema: {0}' -f $validation.ConfigSchemaVersion)
Write-Host ('[INFO] RuntimeRoot: {0}' -f $validation.RuntimeRoot)
Write-Host ('[INFO] RuntimeLogRoot (script logs): {0}' -f $validation.RuntimeLogRoot)
Write-Host ('[INFO] LIMSRoot: configured="{0}" effective="{1}" source={2}' -f $validation.ConfiguredLIMSRoot, $validation.EffectiveLIMSRoot, $validation.LIMSRootSource)
Write-Host ('[INFO] SystemLogRoot: configured="{0}" effective="{1}" source={2}' -f $validation.ConfiguredSystemLogRoot, $validation.EffectiveSystemLogRoot, $validation.SystemLogRootSource)
Write-Host ('[INFO] BackupRoot: configured="{0}" effective="{1}" source={2}' -f $validation.ConfiguredBackupRoot, $validation.EffectiveBackupRoot, $validation.BackupRootSource)
Write-Host ('[INFO] StateRoot: {0}' -f $validation.StateRoot)
Write-Host ('[INFO] Operation lock: {0}' -f $validation.OperationLockPath)

if (-not [string]::IsNullOrWhiteSpace([string]$validation.LegacyScriptVersion) -and
    -not $validation.PackageVersionMatchesLegacyConfig) {
    Write-Warning (
        'Transitional state: VERSION.json and BRAVO.config have different versions. ' +
        'This is allowed only until loader integration into production scripts is complete.'
    )
}

Write-Host '[SUCCESS] Configuration validation completed successfully.'
exit 0
