<#
    Standalone offline test runner for the ApiPool toolkit.
    No network, no real credentials, no BRAVO production paths.
#>
[CmdletBinding()]
param(
    [string[]]$Suite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TestsRoot = $PSScriptRoot
$script:ApiRoot = Split-Path -Parent $PSScriptRoot
$script:ModulesRoot = Join-Path $script:ApiRoot 'modules'
$script:ConfigRoot = Join-Path $script:ApiRoot 'config'

. (Join-Path $script:TestsRoot 'ApiPool.TestHarness.ps1')

# --- Network isolation: shadow the web cmdlets and point the default proxy at a dead port. ---
$global:ApiPoolNetworkAttempts = New-Object System.Collections.ArrayList
function global:Invoke-WebRequest { [void]$global:ApiPoolNetworkAttempts.Add('Invoke-WebRequest'); throw 'NETWORK_FORBIDDEN_IN_TESTS' }
function global:Invoke-RestMethod { [void]$global:ApiPoolNetworkAttempts.Add('Invoke-RestMethod'); throw 'NETWORK_FORBIDDEN_IN_TESTS' }

$script:PreviousProxy = [System.Net.WebRequest]::DefaultWebProxy
$script:PreviousApiKeyEnv = [System.Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY', 'Process')
$script:SuiteThrew = $false
$exitCode = 1

try {
    [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy('http://127.0.0.1:9')
    [System.Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', '', 'Process')

    # Fixed import order; modules never import each other.
    foreach ($moduleName in @('Core', 'Credentials', 'Pricing', 'Budget', 'Transport', 'Adapter')) {
        Import-Module -Name (Join-Path $script:ModulesRoot ('ApiPool.{0}.psm1' -f $moduleName)) -Force -Global -DisableNameChecking
    }

    $suiteFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:TestsRoot 'suites') -Filter '*.Tests.ps1' | Sort-Object -Property Name)
    if ($Suite) {
        $known = @($suiteFiles | ForEach-Object { $_.Name -replace '\.Tests\.ps1$', '' })
        foreach ($requested in $Suite) {
            if ($known -notcontains $requested) {
                $script:ApiPoolTestSuite = 'Runner'
                Write-ApiPoolTestResult -Name ('UnknownSuite:' + $requested) -Passed $false -Detail 'suite not found'
                $script:SuiteThrew = $true
            }
        }
        $suiteFiles = @($suiteFiles | Where-Object { $Suite -contains ($_.Name -replace '\.Tests\.ps1$', '') })
    }

    foreach ($suiteFile in $suiteFiles) {
        $script:ApiPoolTestSuite = $suiteFile.Name -replace '\.Tests\.ps1$', ''
        try {
            . $suiteFile.FullName
        }
        catch {
            $script:SuiteThrew = $true
            Write-ApiPoolTestResult -Name 'SuiteThrew' -Passed $false -Detail $_.Exception.Message
        }
    }

    $script:ApiPoolTestSuite = 'Network'
    Assert-ApiPoolEqual -Expected 0 -Actual $global:ApiPoolNetworkAttempts.Count -Name 'NoNetworkAttempts'
    $script:ApiPoolTestSuite = 'Environment'
    Assert-ApiPoolTrue -Condition ([string]::IsNullOrEmpty([System.Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY', 'Process'))) -Name 'AnthropicApiKeyEnvNotConsumed'

    Write-Host ('Total: {0}  Failures: {1}' -f $script:ApiPoolTestTotal, $script:ApiPoolTestFailures)
    if ($script:ApiPoolTestFailures -eq 0 -and -not $script:SuiteThrew) { $exitCode = 0 }
}
finally {
    [System.Net.WebRequest]::DefaultWebProxy = $script:PreviousProxy
    [System.Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $script:PreviousApiKeyEnv, 'Process')
    foreach ($fn in @('Invoke-WebRequest', 'Invoke-RestMethod')) {
        if (Test-Path -LiteralPath ('Function:\' + $fn)) { Remove-Item -LiteralPath ('Function:\' + $fn) -ErrorAction SilentlyContinue }
    }
    Remove-Variable -Name ApiPoolNetworkAttempts -Scope Global -ErrorAction SilentlyContinue
}
exit $exitCode
