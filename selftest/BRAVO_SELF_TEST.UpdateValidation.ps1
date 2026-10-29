# ============================================================
# UpdateValidation: перевірка після розгортання Installer v1 (INS-047)
# ============================================================
# Перевіряється реальний модуль BRAVO.Update (частина Validation) на
# тимчасових fixture-каталогах. Усі зовнішні запуски (guard, BRAVO_SETUP,
# self-test, credentials) підміняються stub-adapter-ом. ЄДИНИЙ реальний
# дочірній процес — крихітний скрипт у temp, що друкує фальшивий секрет
# (перевірка маскування виводу й таймауту Invoke-BRAVOUpdateChildProcess).

Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking

$valTestModule = Get-Module BRAVO.Update

function Invoke-BRAVOValTestCall {
    param([string]$Name, [hashtable]$Params = @{})
    return (& $valTestModule { param($FunctionName, $FunctionParams) & $FunctionName @FunctionParams } $Name $Params)
}

function New-BRAVOValTestRuntime {
    # Runtime-fixture: VERSION.json + файли + RUNTIME_MANIFEST.json (SHA-256 UPPER).
    param([string]$Path, [string]$Version, [switch]$NoVersionJson)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $files = [ordered]@{ 'a.ps1' = 'Write-Output 1'; 'дані/файл.txt' = 'кирилиця' }
    $manifestFiles = [ordered]@{}
    foreach ($relative in @($files.Keys)) {
        $full = Join-Path $Path ($relative -replace '/', '\')
        $dir = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($full, [string]$files[$relative], (New-Object Text.UTF8Encoding $false))
        $manifestFiles[$relative] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToUpperInvariant()
    }
    $manifestPath = Join-Path $Path 'RUNTIME_MANIFEST.json'
    [IO.File]::WriteAllText($manifestPath, ([pscustomobject]@{ files = [pscustomobject]$manifestFiles } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    if (-not $NoVersionJson) {
        [IO.File]::WriteAllText((Join-Path $Path 'VERSION.json'), ('{"packageVersion": "' + $Version + '"}'), (New-Object Text.UTF8Encoding $false))
    }
    return $manifestPath
}

function New-BRAVOValTestAdapter {
    # Stub-adapter: коди виходу задаються параметрами, виклики пишуться в $Calls.
    param(
        [hashtable]$Calls,
        [int]$Guard = 0,
        [int]$Setup = 0,
        [int]$SelfTest = 0,
        [string]$Presence = 'Found',
        [switch]$GuardTimedOut
    )
    $adapter = @{}
    $adapter.InvokeGuard = { param([string]$RuntimeRoot, [string]$LogPath) $Calls['Guard'] = @($RuntimeRoot, $LogPath); [pscustomobject]@{ ExitCode = $Guard; Output = ''; TimedOut = [bool]$GuardTimedOut } }.GetNewClosure()
    $adapter.InvokeSetupValidate = { param([string]$RuntimeRoot) $Calls['Setup'] = $true; [pscustomobject]@{ ExitCode = $Setup; Output = ''; TimedOut = $false } }.GetNewClosure()
    $adapter.InvokeSelfTest = { param([string]$RuntimeRoot) $Calls['SelfTest'] = $true; [pscustomobject]@{ ExitCode = $SelfTest; Output = ''; TimedOut = $false } }.GetNewClosure()
    $adapter.InvokeSetupScheduler = { param([string]$RuntimeRoot) $Calls['Scheduler'] = $true; [pscustomobject]@{ ExitCode = 0; Output = ''; TimedOut = $false } }.GetNewClosure()
    $adapter.TestCredentialPresence = { param([string]$RuntimeRoot, [string]$Component) $Calls['Cred'] = $Component; [pscustomobject]@{ Component = $Component; Presence = $Presence; ExitCode = 0 } }.GetNewClosure()
    return $adapter
}

function New-BRAVOValTestContext {
    param($Adapter, [string]$RuntimeRoot, [string]$OperationDirectory = '', [switch]$SelfTestPlanned)
    $planned = @([pscustomobject]@{ id = 'RuntimeGuard' })
    if ($SelfTestPlanned) { $planned += [pscustomobject]@{ id = 'SelfTest' } }
    return @{
        Adapter            = $Adapter
        Paths              = [pscustomobject]@{ RuntimeRoot = $RuntimeRoot }
        OperationDirectory = $OperationDirectory
        Plan               = [pscustomobject]@{ tests = [pscustomobject]@{ planned = $planned; skipped = @() } }
    }
}

function Invoke-BRAVOValTest {
    param($Context, [string]$ValidationMode, [string]$Version, [string]$Manifest, $GuardBaseline = $null)
    return (Invoke-BRAVOValTestCall -Name 'Test-BRAVODeploymentValidation' -Params @{
            Context = $Context; Mode = $ValidationMode; ExpectedVersion = $Version; ExpectedManifestPath = $Manifest
            SiteBaseline = [pscustomobject]@{ marker = 'baseline' }; GuardBaselineExitCode = $GuardBaseline
        })
}

function Get-BRAVOValTestItemStatus {
    param($Result, [string]$Name)
    foreach ($item in @($Result.Items)) { if ($item.name -eq $Name) { return [string]$item.status } }
    return 'ABSENT'
}

function Set-BRAVOValTestSiteStub {
    # Підміняє Test-BRAVOSiteConfigurationPreserved у scope модуля (E3 пише її
    # паралельно). Попередню версію (якщо була) відновлює Restore-...
    param([scriptblock]$Body)
    & $valTestModule { param($Block) Set-Item -Path 'function:script:Test-BRAVOSiteConfigurationPreserved' -Value $Block } $Body
}

$valSiteOriginal = & $valTestModule { $cmd = Get-Command -Name 'Test-BRAVOSiteConfigurationPreserved' -CommandType Function -ErrorAction SilentlyContinue; if ($null -ne $cmd) { $cmd.ScriptBlock } else { $null } }

function Restore-BRAVOValTestSiteStub {
    if ($null -ne $valSiteOriginal) {
        & $valTestModule { param($Block) Set-Item -Path 'function:script:Test-BRAVOSiteConfigurationPreserved' -Value $Block } $valSiteOriginal
    } else {
        & $valTestModule { if (Test-Path -Path 'function:script:Test-BRAVOSiteConfigurationPreserved') { Remove-Item -Path 'function:script:Test-BRAVOSiteConfigurationPreserved' } }
    }
}

$valSitePass = { param([string]$RuntimeRoot, $Baseline) [pscustomobject]@{ name = 'SiteConfigPreserved'; status = 'Pass'; message = 'ok' } }
$valSiteFail = { param([string]$RuntimeRoot, $Baseline) [pscustomobject]@{ name = 'SiteConfigPreserved'; status = 'Fail'; message = 'BRAVO.local.config змінено' } }

$valTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO вал тест ' + [guid]::NewGuid().ToString('N'))
$valTestPrefix = Join-Path ([IO.Path]::GetTempPath()) 'BRAVO вал тест '
try {
    New-Item -ItemType Directory -Path $valTestRoot -Force | Out-Null
    $runtime = Join-Path $valTestRoot 'Програми Toolkit\runtime'
    $manifest = New-BRAVOValTestRuntime -Path $runtime -Version '5.3.0'
    $opDir = Join-Path $valTestRoot 'op'

    # --- Відсутність SiteConfig-функції = Fail (fail closed), перед будь-яким stub ---
    & {
        if ($null -eq $valSiteOriginal) {
            $calls = @{}
            $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls) -RuntimeRoot $runtime
            $res = Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $manifest
            Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus $res 'SiteConfigPreserved') -eq 'Fail' -and $res.Status -eq 'Fail') `
                -Name 'UpdateValidation/SiteConfigFunctionMissingFailsClosed' -Failure 'без Test-BRAVOSiteConfigurationPreserved результат має бути Fail'
        } else {
            Test-BRAVOCondition -Condition $true -Name 'UpdateValidation/SiteConfigFunctionMissingFailsClosed' -Failure 'n/a (функція E3 уже є)'
        }
    }

    Set-BRAVOValTestSiteStub -Body $valSitePass

    # --- Усе добре: Deploy ---
    & {
        $calls = @{}
        $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls) -RuntimeRoot $runtime -OperationDirectory $opDir -SelfTestPlanned
        $res = Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $manifest
        Test-BRAVOCondition -Condition ($res.Status -eq 'Pass') -Name 'UpdateValidation/DeployAllPass' -Failure ('очікувано Pass: ' + (($res.Items | ForEach-Object { $_.name + '=' + $_.status }) -join ','))
        $names = @($res.Items | ForEach-Object { $_.name })
        Test-BRAVOCondition -Condition (($names -join ',') -eq 'VersionJson,RuntimeManifest,Guard,SetupValidate,SelfTest,SiteConfigPreserved') `
            -Name 'UpdateValidation/DeployItemOrderAndNames' -Failure ('імена елементів: ' + ($names -join ','))
        Test-BRAVOCondition -Condition ($calls.ContainsKey('SelfTest') -and -not $calls.ContainsKey('Cred') -and -not $calls.ContainsKey('Scheduler')) `
            -Name 'UpdateValidation/DeployRunsSelfTestNotCredentialsNotScheduler' -Failure 'Deploy: self-test так, credentials/scheduler ні'
        Test-BRAVOCondition -Condition ($calls['Guard'][0] -eq $runtime -and $calls['Guard'][1] -like (Join-Path $opDir 'logs\*guard*.log')) `
            -Name 'UpdateValidation/GuardGetsRuntimeRootAndLogPath' -Failure ('guard args: ' + ($calls['Guard'] -join '|'))
        $itemShapeOk = $true
        foreach ($item in $res.Items) { if (-not ($item.PSObject.Properties['name'] -and $item.PSObject.Properties['status'] -and $item.PSObject.Properties['message'])) { $itemShapeOk = $false } }
        Test-BRAVOCondition -Condition $itemShapeOk -Name 'UpdateValidation/ItemShape' -Failure 'елемент має {name,status,message}'
    }

    # --- Кожен код guard ---
    foreach ($guardCode in @(0, 1, 33, 34, 35, 36, 37)) {
        & {
            $calls = @{}
            $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls -Guard $guardCode) -RuntimeRoot $runtime
            $res = Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $manifest
            $expected = if ($guardCode -eq 0) { 'Pass' } else { 'Fail' }
            Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus $res 'Guard') -eq $expected) `
                -Name "UpdateValidation/GuardCode$guardCode" -Failure "guard $guardCode -> $expected"
            if ($guardCode -ne 0) {
                Test-BRAVOCondition -Condition ($res.Status -eq 'Fail') -Name "UpdateValidation/GuardCode${guardCode}FailsOverall" -Failure 'загальний статус Fail'
            }
        }
    }

    # --- Guard: таймаут, відсутній ключ, виняток, результат без ExitCode ---
    & {
        $calls = @{}
        $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls -GuardTimedOut) -RuntimeRoot $runtime
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $manifest) 'Guard') -eq 'Fail') `
            -Name 'UpdateValidation/GuardTimedOutFails' -Failure 'TimedOut -> Fail'

        $adapter = New-BRAVOValTestAdapter -Calls $calls
        $adapter.Remove('InvokeGuard')
        $ctx = New-BRAVOValTestContext -Adapter $adapter -RuntimeRoot $runtime
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $manifest) 'Guard') -eq 'Fail') `
            -Name 'UpdateValidation/GuardMissingAdapterKeyFails' -Failure 'немає InvokeGuard -> Fail'

        $adapter = New-BRAVOValTestAdapter -Calls $calls
        $adapter.InvokeGuard = { param([string]$RuntimeRoot) throw 'імітація збою адаптера' }
        $ctx = New-BRAVOValTestContext -Adapter $adapter -RuntimeRoot $runtime
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $manifest) 'Guard') -eq 'Fail') `
            -Name 'UpdateValidation/GuardAdapterThrowsFails' -Failure 'виняток адаптера -> Fail'

        $adapter.InvokeGuard = { param([string]$RuntimeRoot) [pscustomobject]@{ Output = 'x' } }
        $ctx = New-BRAVOValTestContext -Adapter $adapter -RuntimeRoot $runtime
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $manifest) 'Guard') -eq 'Fail') `
            -Name 'UpdateValidation/GuardNoExitCodeFails' -Failure 'результат без ExitCode -> Fail'
    }

    # --- Rollback: baseline guard ---
    & {
        $calls = @{}
        $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls -Guard 35) -RuntimeRoot $runtime
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Rollback -Version '5.3.0' -Manifest $manifest -GuardBaseline 35) 'Guard') -eq 'Pass') `
            -Name 'UpdateValidation/RollbackGuardEqualsBaselinePasses' -Failure 'guard 35 == baseline 35 -> Pass'
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Rollback -Version '5.3.0' -Manifest $manifest -GuardBaseline 0) 'Guard') -eq 'Fail') `
            -Name 'UpdateValidation/RollbackGuardDiffersFromBaselineFails' -Failure 'guard 35 != baseline 0 -> Fail'
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $manifest -GuardBaseline 35) 'Guard') -eq 'Fail') `
            -Name 'UpdateValidation/DeployIgnoresGuardBaseline' -Failure 'baseline діє лише в Rollback'
        $ctx0 = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls -Guard 0) -RuntimeRoot $runtime
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx0 -ValidationMode Rollback -Version '5.3.0' -Manifest $manifest) 'Guard') -eq 'Pass') `
            -Name 'UpdateValidation/RollbackWithoutBaselineExpectsZero' -Failure 'без baseline очікується 0'
    }

    # --- SetupValidate 0/10/1 у кожному режимі ---
    $setupExpect = @{
        Deploy   = @{ 0 = 'Pass'; 10 = 'Warn'; 1 = 'Fail' }
        Rollback = @{ 0 = 'Pass'; 10 = 'Warn'; 1 = 'Fail' }
        Repair   = @{ 0 = 'Pass'; 10 = 'Warn'; 1 = 'Fail' }
        Install  = @{ 0 = 'Pass'; 10 = 'Warn'; 1 = 'Warn' }
    }
    foreach ($valModeName in @('Deploy', 'Rollback', 'Repair', 'Install')) {
        foreach ($setupCode in @(0, 10, 1)) {
            & {
                $calls = @{}
                $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls -Setup $setupCode) -RuntimeRoot $runtime
                $res = Invoke-BRAVOValTest -Context $ctx -ValidationMode $valModeName -Version '5.3.0' -Manifest $manifest
                $expected = $setupExpect[$valModeName][$setupCode]
                Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus $res 'SetupValidate') -eq $expected) `
                    -Name "UpdateValidation/Setup${setupCode}In${valModeName}" -Failure "setup $setupCode у $valModeName -> $expected"
                $overall = switch ($expected) { 'Pass' { 'Pass' } 'Warn' { 'Warn' } default { 'Fail' } }
                # Install: credentials Found -> без додаткових Warn; загальний статус = статус setup.
                Test-BRAVOCondition -Condition ($res.Status -eq $overall) `
                    -Name "UpdateValidation/Setup${setupCode}In${valModeName}Overall" -Failure "загальний статус $overall, фактично $($res.Status)"
            }
        }
    }

    # --- SetupValidate: таймаут Install -> Warn, Deploy -> Fail ---
    & {
        $calls = @{}
        $adapter = New-BRAVOValTestAdapter -Calls $calls
        $adapter.InvokeSetupValidate = { param([string]$RuntimeRoot) [pscustomobject]@{ ExitCode = -1; Output = ''; TimedOut = $true } }
        $ctx = New-BRAVOValTestContext -Adapter $adapter -RuntimeRoot $runtime
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $manifest) 'SetupValidate') -eq 'Fail') `
            -Name 'UpdateValidation/SetupTimeoutDeployFails' -Failure 'таймаут setup у Deploy -> Fail'
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Install -Version '5.3.0' -Manifest $manifest) 'SetupValidate') -eq 'Warn') `
            -Name 'UpdateValidation/SetupTimeoutInstallWarns' -Failure 'таймаут setup в Install -> Warn'
    }

    # --- SelfTest ---
    & {
        $calls = @{}
        $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls) -RuntimeRoot $runtime
        $res = Invoke-BRAVOValTest -Context $ctx -ValidationMode Repair -Version '5.3.0' -Manifest $manifest
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus $res 'SelfTest') -eq 'Skipped' -and -not $calls.ContainsKey('SelfTest')) `
            -Name 'UpdateValidation/SelfTestSkippedWhenNotPlanned' -Failure 'не заплановано -> Skipped, адаптер не викликано'

        $calls = @{}
        $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls -SelfTest 1) -RuntimeRoot $runtime -SelfTestPlanned
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $manifest) 'SelfTest') -eq 'Fail') `
            -Name 'UpdateValidation/SelfTestNonZeroFails' -Failure 'self-test 1 -> Fail'

        $calls = @{}
        $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls) -RuntimeRoot $runtime -SelfTestPlanned
        $res = Invoke-BRAVOValTest -Context $ctx -ValidationMode Rollback -Version '5.3.0' -Manifest $manifest
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus $res 'SelfTest') -eq 'Skipped' -and -not $calls.ContainsKey('SelfTest')) `
            -Name 'UpdateValidation/SelfTestNotRunOnRollback' -Failure 'Rollback не запускає self-test'
    }

    # --- Install: credentials ---
    foreach ($presence in @('Found', 'Missing', 'Unknown')) {
        & {
            $calls = @{}
            $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls -Presence $presence) -RuntimeRoot $runtime
            $res = Invoke-BRAVOValTest -Context $ctx -ValidationMode Install -Version '5.3.0' -Manifest $manifest
            $expected = if ($presence -eq 'Found') { 'Pass' } else { 'Warn' }
            Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus $res 'TestCredentialPresence') -eq $expected) `
                -Name "UpdateValidation/InstallCredentials$presence" -Failure "credentials $presence -> $expected"
            if ($presence -ne 'Found') {
                Test-BRAVOCondition -Condition ($res.Status -eq 'Warn') -Name "UpdateValidation/InstallCredentials${presence}OverallWarn" -Failure 'Missing/Unknown не дає Fail'
            }
        }
    }
    & {
        $calls = @{}
        $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls) -RuntimeRoot $runtime
        $res = Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $manifest
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus $res 'TestCredentialPresence') -eq 'ABSENT') `
            -Name 'UpdateValidation/CredentialsOnlyInInstall' -Failure 'credentials перевіряються лише в Install'
    }

    # --- VERSION.json: відсутній, не той, пошкоджений ---
    & {
        $calls = @{}
        $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls) -RuntimeRoot $runtime
        $res = Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '9.9.9' -Manifest $manifest
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus $res 'VersionJson') -eq 'Fail' -and $res.Status -eq 'Fail') `
            -Name 'UpdateValidation/VersionMismatchFails' -Failure 'версія не збігається -> Fail'

        $noVersionRuntime = Join-Path $valTestRoot 'без версії'
        $noVersionManifest = New-BRAVOValTestRuntime -Path $noVersionRuntime -Version '5.3.0' -NoVersionJson
        $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls) -RuntimeRoot $noVersionRuntime
        $res = Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $noVersionManifest
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus $res 'VersionJson') -eq 'Fail' -and $res.Status -eq 'Fail' -and ($res.Items | Where-Object { $_.name -eq 'Guard' })) `
            -Name 'UpdateValidation/MissingVersionJsonFails' -Failure 'немає VERSION.json -> Fail, решта перевірок усе одно виконана'

        $badVersionRuntime = Join-Path $valTestRoot 'зламана версія'
        $badVersionManifest = New-BRAVOValTestRuntime -Path $badVersionRuntime -Version '5.3.0'
        [IO.File]::WriteAllText((Join-Path $badVersionRuntime 'VERSION.json'), '{ не json', (New-Object Text.UTF8Encoding $false))
        $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls) -RuntimeRoot $badVersionRuntime
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $badVersionManifest) 'VersionJson') -eq 'Fail') `
            -Name 'UpdateValidation/CorruptVersionJsonFails' -Failure 'пошкоджений VERSION.json -> Fail'
    }

    # --- RuntimeManifest: змінений файл, сторонній скрипт, відсутній маніфест ---
    & {
        $calls = @{}
        $driftRuntime = Join-Path $valTestRoot 'дрейф'
        $driftManifest = New-BRAVOValTestRuntime -Path $driftRuntime -Version '5.3.0'
        $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls) -RuntimeRoot $driftRuntime
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $driftManifest) 'RuntimeManifest') -eq 'Pass') `
            -Name 'UpdateValidation/ManifestMatchesPasses' -Failure 'чистий runtime -> Pass'
        [IO.File]::WriteAllText((Join-Path $driftRuntime 'a.ps1'), 'Write-Output 2', (New-Object Text.UTF8Encoding $false))
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $driftManifest) 'RuntimeManifest') -eq 'Fail') `
            -Name 'UpdateValidation/ManifestModifiedFileFails' -Failure 'змінений файл -> Fail'
        [IO.File]::WriteAllText((Join-Path $driftRuntime 'a.ps1'), 'Write-Output 1', (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $driftRuntime 'stranger.ps1'), 'Write-Output 3', (New-Object Text.UTF8Encoding $false))
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $driftManifest) 'RuntimeManifest') -eq 'Fail') `
            -Name 'UpdateValidation/ManifestStrangerScriptFails' -Failure 'сторонній скрипт -> Fail'
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest (Join-Path $driftRuntime 'немає.json')) 'RuntimeManifest') -eq 'Fail') `
            -Name 'UpdateValidation/ManifestMissingFails' -Failure 'немає маніфесту -> Fail'
    }

    # --- SiteConfigPreserved ---
    & {
        $calls = @{}
        Set-BRAVOValTestSiteStub -Body $valSiteFail
        $ctx = New-BRAVOValTestContext -Adapter (New-BRAVOValTestAdapter -Calls $calls) -RuntimeRoot $runtime
        $res = Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $manifest
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus $res 'SiteConfigPreserved') -eq 'Fail' -and $res.Status -eq 'Fail') `
            -Name 'UpdateValidation/SiteConfigDriftFails' -Failure 'розбіжність site config -> Fail'
        Set-BRAVOValTestSiteStub -Body { param([string]$RuntimeRoot, $Baseline) throw 'імітація збою' }
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $manifest) 'SiteConfigPreserved') -eq 'Fail') `
            -Name 'UpdateValidation/SiteConfigThrowsFails' -Failure 'виняток -> Fail'
        Set-BRAVOValTestSiteStub -Body { param([string]$RuntimeRoot, $Baseline) 'сміття' }
        Test-BRAVOCondition -Condition ((Get-BRAVOValTestItemStatus (Invoke-BRAVOValTest -Context $ctx -ValidationMode Deploy -Version '5.3.0' -Manifest $manifest) 'SiteConfigPreserved') -eq 'Fail') `
            -Name 'UpdateValidation/SiteConfigGarbageFails' -Failure 'нерозпізнаний результат -> Fail'
        Set-BRAVOValTestSiteStub -Body $valSitePass
    }

    # --- Реальний дочірній процес: маскування секрету, код виходу, лог, таймаут ---
    & {
        $childDir = Join-Path $valTestRoot 'child dir дитина'
        New-Item -ItemType Directory -Path $childDir -Force | Out-Null
        $childScript = Join-Path $childDir 'e4-child.ps1'
        $childLines = @(
            'param([string]$Mode)',
            'if ($Mode -eq ''Sleep'') { Start-Sleep -Seconds 60; exit 0 }',
            'Write-Output ''CHILD-OUTPUT-START''',
            'Write-Output ''password=HunterFakeSecret42 token=FAKEtokenValue123456''',
            '[Console]::Error.WriteLine(''stderr password=HunterFakeSecret42'')',
            'exit 7'
        )
        [IO.File]::WriteAllText($childScript, ([string]::Join("`r`n", $childLines)), (New-Object Text.UTF8Encoding $true))
        $logPath = Join-Path $childDir 'logs\child.log'

        $run = Invoke-BRAVOValTestCall -Name 'Invoke-BRAVOUpdateChildProcess' -Params @{
            ScriptPath = $childScript; ScriptArgument = @('-Mode', 'Print'); TimeoutSeconds = 60; LogPath = $logPath
        }
        Test-BRAVOCondition -Condition ($run.ExitCode -eq 7 -and -not $run.TimedOut) -Name 'UpdateValidation/ChildExitCodePropagated' -Failure "ExitCode=$($run.ExitCode) TimedOut=$($run.TimedOut)"
        Test-BRAVOCondition -Condition ([string]$run.Output -match 'CHILD-OUTPUT-START') -Name 'UpdateValidation/ChildOutputCaptured' -Failure 'вивід дитини не повернуто'
        Test-BRAVOCondition -Condition ([string]$run.Output -notmatch 'HunterFakeSecret42' -and [string]$run.Output -notmatch 'FAKEtokenValue123456') `
            -Name 'UpdateValidation/ChildOutputSecretMasked' -Failure 'секрет у поверненому виводі'
        $logText = ''
        if (Test-Path -LiteralPath $logPath) { $logText = [IO.File]::ReadAllText($logPath) }
        Test-BRAVOCondition -Condition ($run.LogPath -eq $logPath -and $logText -match 'CHILD-OUTPUT-START' -and $logText -notmatch 'HunterFakeSecret42' -and $logText -notmatch 'FAKEtokenValue123456') `
            -Name 'UpdateValidation/ChildLogWrittenAndMasked' -Failure 'лог відсутній або містить секрет'

        $watch = [Diagnostics.Stopwatch]::StartNew()
        $slow = Invoke-BRAVOValTestCall -Name 'Invoke-BRAVOUpdateChildProcess' -Params @{
            ScriptPath = $childScript; ScriptArgument = @('-Mode', 'Sleep'); TimeoutSeconds = 4; LogPath = (Join-Path $childDir 'logs\timeout.log')
        }
        $watch.Stop()
        Test-BRAVOCondition -Condition ($slow.TimedOut -and $slow.ExitCode -eq -1 -and $watch.Elapsed.TotalSeconds -lt 40) `
            -Name 'UpdateValidation/ChildTimeoutStopsOwnProcess' -Failure "TimedOut=$($slow.TimedOut) Exit=$($slow.ExitCode) elapsed=$($watch.Elapsed.TotalSeconds)"
        Test-BRAVOCondition -Condition (Test-Path -LiteralPath (Join-Path $childDir 'logs\timeout.log')) -Name 'UpdateValidation/ChildTimeoutLogWritten' -Failure 'лог таймауту не записано'
    }

    # --- Статика: прапорці адаптера, RemoteSigned, без Bypass і кілу за ім'ям ---
    & {
        $pathsText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.Paths.ps1'))
        Test-BRAVOCondition -Condition ($pathsText -match "'-ExecutionPolicy', 'RemoteSigned'" -and $pathsText -notmatch '(?i)''bypass''|ExecutionPolicy\s+Bypass') `
            -Name 'UpdateValidation/ChildUsesRemoteSignedNotBypass' -Failure 'child має -ExecutionPolicy RemoteSigned без Bypass'
        $setupValidateOk = $pathsText -match "'-ValidateOnly', '-SkipAccessTest', '-SkipTestNotification', '-NoElevation', '-NoPause'"
        $setupSchedulerOk = $pathsText -match "'-Action', 'Scheduler', '-SkipTestNotification', '-NoElevation', '-NoPause'"
        Test-BRAVOCondition -Condition ($setupValidateOk -and $setupSchedulerOk) `
            -Name 'UpdateValidation/AdapterSetupFlags' -Failure 'прапорці BRAVO_SETUP за ENGINE_DESIGN §6'
        $killMatches = [regex]::Matches($pathsText, '(?i)Stop-Process|taskkill|Get-Process|\.Kill\(')
        Test-BRAVOCondition -Condition ($killMatches.Count -eq 1 -and $killMatches[0].Value -eq '.Kill(') `
            -Name 'UpdateValidation/OnlyOwnProcessObjectIsStopped' -Failure 'допустимо лише завершення власного Process-об''єкта'
        $adapter = & $valTestModule { New-BRAVOUpdateDefaultAdapter }
        Test-BRAVOCondition -Condition ($adapter.ContainsKey('InvokeGuard') -and $adapter.ContainsKey('InvokeSetupValidate') -and $adapter.ContainsKey('InvokeSetupScheduler') -and $adapter.ContainsKey('InvokeSelfTest')) `
            -Name 'UpdateValidation/DefaultAdapterKeys' -Failure 'default adapter має Invoke* ключі'
        $validationText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.Validation.ps1'))
        Test-BRAVOCondition -Condition ($validationText -notmatch '(?m)^\s*Write-Host|\bexit\b\s*\d|\$global:|Invoke-Expression|::new\(|Start-Process') `
            -Name 'UpdateValidation/PartHasNoConsoleExitGlobalOrNew' -Failure 'Validation.ps1: без Write-Host, exit, $global:, Invoke-Expression, ::new(), Start-Process'
    }
} finally {
    Restore-BRAVOValTestSiteStub
    if ($valTestRoot.StartsWith($valTestPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $valTestRoot)) {
        Remove-Item -LiteralPath $valTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
