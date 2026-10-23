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

$script:ApiPoolTestSandboxRoots = New-Object System.Collections.ArrayList

function New-ApiPoolTestSandbox {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('ApiPoolTests-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($path)
    [void]$script:ApiPoolTestSandboxRoots.Add($path)
    return $path
}

function Test-ApiPoolTestPathInSandbox {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.StartsWith('\\') -or $Path.StartsWith('//')) { return $false }
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    $roots = New-Object System.Collections.ArrayList
    [void]$roots.Add([System.IO.Path]::GetTempPath())
    foreach ($r in $script:ApiPoolTestSandboxRoots) { [void]$roots.Add($r) }
    foreach ($root in $roots) {
        $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
        if ($full.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Assert-ApiPoolTestPathInSandbox {
    # Throws unless the path is absolute, local and under a test sandbox root (or the temp directory).
    # Pure string check; performs no IO.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)

    if (-not (Test-ApiPoolTestPathInSandbox -Path $Path)) {
        throw ('TEST SAFETY: path is outside the test sandbox: ' + $Path)
    }
}

function Assert-ApiPoolForbiddenPathRejected {
    # VALIDATOR-ONLY check for forbidden REAL-SYSTEM paths (ProgramData, UNC, device, repo, drive roots, relative).
    # The path is handed to Assert-ApiPoolSafePath and to nothing else: no writer is ever called with it.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ExpectedCode = 'STATE_PATH_FORBIDDEN',
        [string]$RepoRoot
    )

    $code = $null
    try {
        if ([string]::IsNullOrEmpty($RepoRoot)) { $null = Assert-ApiPoolSafePath -Path $Path -Purpose 'TestProbe' }
        else { $null = Assert-ApiPoolSafePath -Path $Path -Purpose 'TestProbe' -RepoRoot $RepoRoot }
    }
    catch { $code = Get-ApiPoolErrorCode -ErrorRecord $_ }
    Write-ApiPoolTestResult -Name $Name -Passed ($code -ceq $ExpectedCode) -Detail ('validator returned code=' + [string]$code)
}

function Invoke-ApiPoolSandboxRefusal {
    # For forbidden paths that live INSIDE the sandbox (e.g. junction ancestor): the sandbox is asserted
    # before the write function is invoked.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ExpectedCode = 'STATE_PATH_FORBIDDEN'
    )

    if (-not (Test-ApiPoolTestPathInSandbox -Path $Path)) {
        Write-ApiPoolTestResult -Name ($Name + '/InSandbox') -Passed $false -Detail 'path is outside the test sandbox; write function NOT invoked'
        return
    }
    Assert-ApiPoolThrows $ScriptBlock $Name -ExpectedCode $ExpectedCode
}

# --- Run-level tripwire: production state and drive-root probes must be untouched by the whole run. ---
function Get-ApiPoolSafetySnapshot {
    param([string]$Path)

    if (-not [System.IO.Directory]::Exists($Path)) { return 'ABSENT' }
    $children = @([System.IO.Directory]::GetFileSystemEntries($Path) | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Sort-Object)
    return ('PRESENT|{0}|{1}' -f [System.IO.Directory]::GetLastWriteTimeUtc($Path).Ticks, ($children -join ','))
}

function Start-ApiPoolSafetyTripwire {
    $script:ApiPoolTripwireBravo = 'C:\ProgramData\BRAVO'
    $script:ApiPoolTripwireProbes = @('C:\x', 'C:\state', 'C:\ApiPool', 'C:\s.dpapi')
    $script:ApiPoolTripwireBefore = @{}
    foreach ($p in (@($script:ApiPoolTripwireBravo) + $script:ApiPoolTripwireProbes)) {
        $script:ApiPoolTripwireBefore[$p] = Get-ApiPoolSafetySnapshot -Path $p
    }
}

function Complete-ApiPoolSafetyTripwire {
    $previousSuite = $script:ApiPoolTestSuite
    $script:ApiPoolTestSuite = 'Safety'
    $after = Get-ApiPoolSafetySnapshot -Path $script:ApiPoolTripwireBravo
    Assert-ApiPoolTrue ($after -ceq $script:ApiPoolTripwireBefore[$script:ApiPoolTripwireBravo]) 'ProductionStateUntouched' ('C:\ProgramData\BRAVO changed during the run: before=' + $script:ApiPoolTripwireBefore[$script:ApiPoolTripwireBravo] + ' after=' + $after)
    $changed = @($script:ApiPoolTripwireProbes | Where-Object { (Get-ApiPoolSafetySnapshot -Path $_) -cne $script:ApiPoolTripwireBefore[$_] })
    Assert-ApiPoolTrue ($changed.Count -eq 0) 'NoDriveRootArtifacts' ('drive-root probe changed: ' + ($changed -join ', '))
    $script:ApiPoolTestSuite = $previousSuite
}

function Remove-ApiPoolTestSandbox {
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return }
    if ((Split-Path -Leaf $Path) -notlike 'ApiPoolTests-*') { return }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}
