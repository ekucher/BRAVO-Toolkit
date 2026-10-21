# Minimal assertion harness. Dot-sourced by Invoke-ApiPoolTests.ps1 (same scope as the suites).
Set-StrictMode -Version Latest

$script:ApiPoolTestTotal = 0
$script:ApiPoolTestFailures = 0
$script:ApiPoolTestSuite = ''

function Write-ApiPoolTestResult {
    param([string]$Name, [bool]$Passed, [string]$Detail)

    $script:ApiPoolTestTotal++
    $label = '{0}/{1}' -f $script:ApiPoolTestSuite, $Name
    if ($Passed) {
        Write-Host ('[PASS] {0}' -f $label)
    }
    else {
        $script:ApiPoolTestFailures++
        Write-Host ('[FAIL] {0} :: {1}' -f $label, $Detail)
    }
}

function Format-ApiPoolTestValue {
    param($Value)

    if ($null -eq $Value) { return '<null>' }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return ('[' + ((@($Value) | ForEach-Object { [string]$_ }) -join ',') + ']')
    }
    return ('{0} ({1})' -f [string]$Value, $Value.GetType().Name)
}

function Assert-ApiPoolTrue {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Condition,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Detail = 'condition was false'
    )

    $ok = ($null -ne $Condition) -and [bool]$Condition
    Write-ApiPoolTestResult -Name $Name -Passed $ok -Detail $Detail
}

function Assert-ApiPoolEqual {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Expected,
        [Parameter(Mandatory = $true)][AllowNull()]$Actual,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $ok = $false
    if ($null -eq $Expected -and $null -eq $Actual) { $ok = $true }
    elseif ($null -eq $Expected -or $null -eq $Actual) { $ok = $false }
    elseif ($Expected -is [string] -and $Actual -is [string]) { $ok = ($Expected -ceq $Actual) }
    else { try { $ok = [bool]($Expected -eq $Actual) } catch { $ok = $false } }
    Write-ApiPoolTestResult -Name $Name -Passed $ok -Detail ('expected {0} but got {1}' -f (Format-ApiPoolTestValue $Expected), (Format-ApiPoolTestValue $Actual))
}

function Assert-ApiPoolThrows {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ExpectedCode,
        [string[]]$MessageMustNotContain
    )

    $caught = $null
    try { $null = & $ScriptBlock } catch { $caught = $_ }
    if ($null -eq $caught) {
        Write-ApiPoolTestResult -Name $Name -Passed $false -Detail 'no exception was thrown'
        return
    }
    $ok = $true
    $detail = ''
    if (-not [string]::IsNullOrEmpty($ExpectedCode)) {
        $code = Get-ApiPoolErrorCode -ErrorRecord $caught
        if ($code -cne $ExpectedCode) { $ok = $false; $detail = ('expected code {0} but got {1} ({2})' -f $ExpectedCode, $code, $caught.Exception.Message) }
    }
    foreach ($forbidden in @($MessageMustNotContain)) {
        if (-not [string]::IsNullOrEmpty($forbidden) -and $caught.Exception.Message.Contains($forbidden)) {
            $ok = $false; $detail = 'error message leaked a forbidden value'
        }
    }
    Write-ApiPoolTestResult -Name $Name -Passed $ok -Detail $detail
}

function New-ApiPoolTestSandbox {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('ApiPoolTests-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($path)
    return $path
}

function Remove-ApiPoolTestSandbox {
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return }
    if ((Split-Path -Leaf $Path) -notlike 'ApiPoolTests-*') { return }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}
