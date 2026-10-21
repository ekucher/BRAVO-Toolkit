# Cli suite. Dot-sourced by Invoke-ApiPoolTests.ps1. Runs Invoke-ApiPool.ps1 in child powershell.exe processes,
# strictly sequentially (8 children), always with -StateRoot inside the sandbox. Offline; no network.
# Health convention (documented): an unhealthy report is exit 1 with {ok:false, code:'UNHEALTHY'}.

$cliSandbox = New-ApiPoolTestSandbox
try {
    $cliScript = Join-Path $script:ApiRoot 'Invoke-ApiPool.ps1'
    $cliExe = Join-Path $PSHOME 'powershell.exe'
    $cliState = Join-Path $cliSandbox 'state'
    $cliFakeKeyTail = 'CLIFAKE1234567890'
    $cliFakeKey = 'sk-' + 'ant-' + 'api03-' + $cliFakeKeyTail

    function Invoke-CliChild {
        param([string[]]$CliArgs)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $cliExe
        $quoted = @($CliArgs | ForEach-Object { '"' + $_ + '"' })
        $psi.Arguments = '-NoProfile -NonInteractive -File "' + $cliScript + '" ' + ($quoted -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $done = $p.WaitForExit(120000)
        if (-not $done) { try { $p.Kill() } catch { $null = $_ } }
        $stdout = ''
        $stderr = ''
        if ($done) { $stdout = $outTask.Result; $stderr = $errTask.Result }
        $json = $null
        $line = @($stdout.Split([char]10) | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 1)
        if ($line.Count -eq 1) { try { $json = ConvertFrom-Json -InputObject $line[0] } catch { $json = $null } }
        $exit = -1
        if ($done) { $exit = $p.ExitCode }
        $p.Dispose()
        return [pscustomobject]@{ Done = $done; Exit = $exit; Stdout = $stdout; Stderr = $stderr; Json = $json }
    }

    Assert-ApiPoolTrue -Condition (Test-ApiPoolTestPathInSandbox -Path $cliState) -Name 'Guard/StateRootInSandbox'

    # 1. capabilities
    $c1 = Invoke-CliChild -CliArgs @('-Command', 'capabilities', '-StateRoot', $cliState)
    Assert-ApiPoolEqual -Expected 0 -Actual $c1.Exit -Name 'Capabilities/ExitZero'
    Assert-ApiPoolTrue -Condition ($null -ne $c1.Json -and $c1.Json.ok -eq $true -and $c1.Json.code -ceq 'OK') -Name 'Capabilities/OkJson' -Detail $c1.Stdout
    if ($null -ne $c1.Json) {
        Assert-ApiPoolEqual -Expected 'apipool.capabilities/1' -Actual $c1.Json.data.schema -Name 'Capabilities/Schema'
        Assert-ApiPoolEqual -Expected 6 -Actual @($c1.Json.data.roles).Count -Name 'Capabilities/Roles'
        Assert-ApiPoolEqual -Expected 'disabled-in-build' -Actual $c1.Json.data.liveTransport -Name 'Capabilities/LiveDisabled'
    }
    Assert-ApiPoolEqual -Expected 1 -Actual @($c1.Stdout.Split([char]10) | Where-Object { $_.Trim() -ne '' }).Count -Name 'Capabilities/SingleLineOutput'

    # 2. budget-init
    $c2 = Invoke-CliChild -CliArgs @('-Command', 'budget-init', '-StateRoot', $cliState)
    Assert-ApiPoolEqual -Expected 0 -Actual $c2.Exit -Name 'BudgetInit/ExitZero'
    Assert-ApiPoolTrue -Condition ($null -ne $c2.Json -and $c2.Json.ok -eq $true -and $c2.Json.data.GlobalLimitMicroUsd -eq 60000000) -Name 'BudgetInit/Limit60Usd' -Detail $c2.Stdout
    $st = Get-ApiPoolBudgetStatus -StateRoot $cliState
    Assert-ApiPoolEqual -Expected 'OK' -Actual $st.State -Name 'BudgetInit/LedgerInitialized'

    # 3. health (initialized, offline)
    $c3 = Invoke-CliChild -CliArgs @('-Command', 'health', '-StateRoot', $cliState)
    Assert-ApiPoolEqual -Expected 0 -Actual $c3.Exit -Name 'Health/ExitZeroWhenHealthy'
    Assert-ApiPoolTrue -Condition ($null -ne $c3.Json -and $c3.Json.data.budget.state -ceq 'OK' -and $c3.Json.data.transportKind -ceq 'none') -Name 'Health/ReportsBudgetAndTransport' -Detail $c3.Stdout

    # 4. budget-clear without -Reason is a usage error
    $c4 = Invoke-CliChild -CliArgs @('-Command', 'budget-clear', '-StateRoot', $cliState)
    Assert-ApiPoolEqual -Expected 2 -Actual $c4.Exit -Name 'BudgetClear/MissingReasonIsUsage'
    Assert-ApiPoolTrue -Condition ($null -ne $c4.Json -and $c4.Json.ok -eq $false -and $c4.Json.code -ceq 'USAGE') -Name 'BudgetClear/UsageJson' -Detail $c4.Stdout

    # 5. orchestrate with a request file containing a fake secret: fallback POOL_DISABLED, nothing echoed
    $reqPath = Join-Path $cliSandbox 'request.json'
    $reqObj = [ordered]@{ role = 'api-scout'; brief = 'Map the module.'; contextData = ('context with ' + $cliFakeKey); idempotencyKey = 'cli-1' }
    [System.IO.File]::WriteAllText($reqPath, (ConvertTo-Json -InputObject $reqObj -Compress))
    $c5 = Invoke-CliChild -CliArgs @('-Command', 'orchestrate', '-StateRoot', $cliState, '-RequestPath', $reqPath)
    Assert-ApiPoolEqual -Expected 0 -Actual $c5.Exit -Name 'Orchestrate/ExitZero'
    Assert-ApiPoolTrue -Condition ($null -ne $c5.Json -and $c5.Json.data.status -ceq 'fallback' -and $c5.Json.data.reasonCode -ceq 'POOL_DISABLED') -Name 'Orchestrate/FallbackPoolDisabled' -Detail $c5.Stdout
    Assert-ApiPoolEqual -Expected 'apipool.orchestrate/1' -Actual $c5.Json.data.schema -Name 'Orchestrate/Schema'
    Assert-ApiPoolTrue -Condition (-not ($c5.Stdout + $c5.Stderr).Contains($cliFakeKeyTail)) -Name 'Orchestrate/OutputNeverContainsSecret'

    # 6. run -> MODE_OFFLINE (the job id only needs a valid format; the transport check comes first)
    $c6 = Invoke-CliChild -CliArgs @('-Command', 'run', '-StateRoot', $cliState, '-JobId', ('job-' + ('0' * 24)))
    Assert-ApiPoolEqual -Expected 1 -Actual $c6.Exit -Name 'Run/ExitOne'
    Assert-ApiPoolTrue -Condition ($null -ne $c6.Json -and $c6.Json.ok -eq $false -and $c6.Json.code -ceq 'MODE_OFFLINE') -Name 'Run/ModeOffline' -Detail $c6.Stdout

    # 7. a state root inside the repository is refused before any IO
    $forbiddenRoot = Join-Path $script:ApiRoot 'cli-forbidden-state'
    Assert-ApiPoolForbiddenPathRejected -Path $forbiddenRoot -Name 'StateRoot/ValidatorRejectsRepoPath'
    $c7 = Invoke-CliChild -CliArgs @('-Command', 'health', '-StateRoot', $forbiddenRoot)
    Assert-ApiPoolEqual -Expected 1 -Actual $c7.Exit -Name 'StateRoot/RepoPathExitOne'
    Assert-ApiPoolTrue -Condition ($null -ne $c7.Json -and $c7.Json.code -ceq 'STATE_PATH_FORBIDDEN') -Name 'StateRoot/RepoPathForbidden' -Detail $c7.Stdout
    Assert-ApiPoolTrue -Condition (-not [System.IO.Directory]::Exists($forbiddenRoot)) -Name 'StateRoot/RepoPathNotCreated'

    # 8. missing -Command is a usage error
    $c8 = Invoke-CliChild -CliArgs @('-StateRoot', $cliState)
    Assert-ApiPoolEqual -Expected 2 -Actual $c8.Exit -Name 'NoCommand/ExitTwo'
    Assert-ApiPoolTrue -Condition ($null -ne $c8.Json -and $c8.Json.code -ceq 'USAGE') -Name 'NoCommand/UsageJson' -Detail $c8.Stdout

    Assert-ApiPoolTrue -Condition ($c1.Done -and $c2.Done -and $c3.Done -and $c4.Done -and $c5.Done -and $c6.Done -and $c7.Done -and $c8.Done) -Name 'Children/AllExitedInTime'
    Assert-ApiPoolTrue -Condition (-not [System.IO.Directory]::Exists((Join-Path $cliState 'jobs'))) -Name 'Orchestrate/NoJobCreatedWhenPoolDisabled'
}
finally {
    Remove-ApiPoolTestSandbox -Path $cliSandbox
}
