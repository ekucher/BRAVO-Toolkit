# Домен-фрагмент self-test: ConfigIntent — AUTO/EXPLICIT намір -ConfigPath
# на СПРАВЖНІЙ межі виклику оператора (root entrypoints) та його пропагація
# в runtime і дочірні процеси. Регресія класу дефектів acceptance CF-17 /
# AUTO-intent: root entrypoint авто-резолвив $ConfigPath і безумовно клав
# його у splat, runtime "відновлював" намір через $PSBoundParameters — і
# кожен AUTO-виклик ставав EXPLICIT (AUTO no-config -> exit 30 замість
# built-in шляху). Попередній self-test кликав Import-BravoConfiguration
# напряму, тому цього не бачив. Dot-sourced з BRAVO_SELF_TEST.ps1 —
# успадковує $root, Test-BRAVOCondition, New-BRAVOSelfTestRuntimeModule.

# ===== E2E: реальні root-entrypoints + stub-runtime =====
# Кожен сценарій запускає СПРАВЖНІЙ root <EP>.ps1 у fixture-каталозі зі
# СПРАВЖНІМ BRAVO_RUNTIME_GUARD.ps1; runtime-модуль підмінений стабом, що
# записує отримані Parameters у JSON і повертає 0 — жодних реальних
# операцій, elevation-гілки runtime не виконуються. BRAVO_RUNTIME_INTEGRITY_
# MODE=Warn (штатний аварійний режим guard-а) виставляється ЛИШЕ в env
# дочірнього процесу; VERSION.json у fixture навмисно відсутній, тому
# version-state цієї машини не читається і не пишеться. Сценарій
# EXPLICIT+missing на ЦІЙ межі перевіряє лише збереження наміру і точного
# шляху: fail-closed відповідь на явний відсутній файл — контракт
# Import-BravoConfiguration, покритий доменом ConfigLoader.

$configIntentSpecs = @(
    @{ Entry = 'BRAVO_ARCHIV.ps1'; Module = 'BRAVO.Archive'; EntryFunction = 'Invoke-BRAVOArchiveEntrypoint'; RequiresAdmin = $false }
    @{ Entry = 'BRAVO_MAINTENANCE.ps1'; Module = 'BRAVO.Maintenance'; EntryFunction = 'Invoke-BRAVOMaintenanceEntrypoint'; RequiresAdmin = $false }
    @{ Entry = 'BRAVO_DATA_RESTORE.ps1'; Module = 'BRAVO.DataRestore'; EntryFunction = 'Invoke-BRAVODataRestoreEntrypoint'; RequiresAdmin = $false }
    # BRAVO_HEALTH.ps1 виконує elevation-перевірку в root ДО імпорту модуля:
    # non-interactive non-admin завершується кодом 36 ще до splat-у, тому
    # цей сценарій вимагає адміністративної сесії (CI runner і штатний
    # запуск self-test — елевовані).
    @{ Entry = 'BRAVO_HEALTH.ps1'; Module = 'BRAVO.Health'; EntryFunction = 'Invoke-BRAVOHealthEntrypoint'; RequiresAdmin = $true }
)

$configIntentIsAdmin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Той самий ASCII-guard для %TEMP%, що й у ManualLaunchers (локалізовані
# облікові записи з не-ASCII шляхом профілю).
$configIntentTempBase = [IO.Path]::GetTempPath()
if ($configIntentTempBase -cmatch '[^\x00-\x7F]') {
    $configIntentTempBase = Join-Path $env:SystemRoot 'Temp'
}
$configIntentFixtureRoot = Join-Path $configIntentTempBase (
    'BRAVO_CONFIG_INTENT_{0}' -f [guid]::NewGuid().ToString('N')
)

function Invoke-BRAVOConfigIntentScenario {
    param(
        [Parameter(Mandatory = $true)][string]$EntryScriptPath,
        [Parameter(Mandatory = $true)][string]$FixtureDirectory,
        [string[]]$ExtraArguments = @()
    )
    $intentResultPath = Join-Path $FixtureDirectory (
        'intent_{0}.json' -f [guid]::NewGuid().ToString('N')
    )
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumentParts = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $EntryScriptPath), '-NoPause'
    ) + @($ExtraArguments)
    $startInfo.Arguments = ($argumentParts -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = $FixtureDirectory
    # ЛИШЕ дочірній env: батьківська self-test-сесія і машина не зачіпаються.
    $startInfo.EnvironmentVariables['BRAVO_RUNTIME_INTEGRITY_MODE'] = 'Warn'
    $startInfo.EnvironmentVariables['BRAVO_SELFTEST_INTENT_RESULT'] = $intentResultPath
    $childProcess = [Diagnostics.Process]::Start($startInfo)
    $childStdOut = $childProcess.StandardOutput.ReadToEnd()
    $childStdErr = $childProcess.StandardError.ReadToEnd()
    $childProcess.WaitForExit()
    $capturedIntent = $null
    if ([IO.File]::Exists($intentResultPath)) {
        $capturedIntent = [IO.File]::ReadAllText(
            $intentResultPath, [Text.Encoding]::UTF8
        ) | ConvertFrom-Json
    }
    return [pscustomobject]@{
        ExitCode = $childProcess.ExitCode
        Captured = $capturedIntent
        StdOut = $childStdOut
        StdErr = $childStdErr
    }
}

try {
    foreach ($configIntentSpec in $configIntentSpecs) {
        $intentEntryName = [string]$configIntentSpec.Entry
        $intentModuleName = [string]$configIntentSpec.Module
        $intentTestPrefix = 'ConfigIntent/{0}' -f ($intentEntryName -replace '\.ps1$', '')

        if ($configIntentSpec.RequiresAdmin -and -not $configIntentIsAdmin) {
            Test-BRAVOCondition `
                -Condition $true `
                -Name ($intentTestPrefix + '/SkippedRequiresAdministrator') `
                -Failure 'E2E-сценарій вимагає адміністративної сесії'
            continue
        }

        $intentFixture = Join-Path $configIntentFixtureRoot $intentModuleName
        $intentModuleDirectory = Join-Path $intentFixture ('modules\{0}' -f $intentModuleName)
        [void][IO.Directory]::CreateDirectory($intentModuleDirectory)
        Copy-Item -LiteralPath (Join-Path $root $intentEntryName) `
            -Destination (Join-Path $intentFixture $intentEntryName)
        Copy-Item -LiteralPath (Join-Path $root 'BRAVO_RUNTIME_GUARD.ps1') `
            -Destination (Join-Path $intentFixture 'BRAVO_RUNTIME_GUARD.ps1')

        $intentStubBody = @'
function __ENTRY_FUNCTION__ {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Parameters)
    $capturedIntent = [pscustomobject]@{
        ConfigPath = [string]$Parameters['ConfigPath']
        ConfigPathBound = [bool]$Parameters.ContainsKey('ConfigPath')
        ConfigPathWasExplicitBound = [bool]$Parameters.ContainsKey('ConfigPathWasExplicit')
        ConfigPathWasExplicit = $(
            if ($Parameters.ContainsKey('ConfigPathWasExplicit')) {
                [bool]$Parameters['ConfigPathWasExplicit']
            } else {
                $null
            }
        )
    }
    [IO.File]::WriteAllText(
        $env:BRAVO_SELFTEST_INTENT_RESULT,
        ($capturedIntent | ConvertTo-Json),
        [Text.Encoding]::UTF8
    )
    return 0
}
Export-ModuleMember -Function '__ENTRY_FUNCTION__'
'@
        $intentStubBody = $intentStubBody.Replace(
            '__ENTRY_FUNCTION__', [string]$configIntentSpec.EntryFunction
        )
        [IO.File]::WriteAllText(
            (Join-Path $intentModuleDirectory ($intentModuleName + '.psm1')),
            $intentStubBody,
            [Text.Encoding]::UTF8
        )
        [IO.File]::WriteAllText(
            (Join-Path $intentModuleDirectory ($intentModuleName + '.psd1')),
            ("@{{ RootModule = '{0}.psm1'; ModuleVersion = '1.0.0'; FunctionsToExport = @('{1}') }}" -f `
                $intentModuleName, [string]$configIntentSpec.EntryFunction),
            [Text.Encoding]::UTF8
        )

        $intentEntryPath = Join-Path $intentFixture $intentEntryName
        $intentAutoConfigPath = Join-Path $intentFixture 'BRAVO.config'
        # Guard статично AST-сканує текст конфігурації, тому вміст має бути
        # синтаксично коректним PowerShell без послаблень безпеки.
        $intentBenignConfigText = '$global:pathSettings = @{ BackupRoot = "C:\x" }'

        # --- AUTO + config ВІДСУТНІЙ: намір НЕ explicit ---
        $intentAutoAbsent = Invoke-BRAVOConfigIntentScenario `
            -EntryScriptPath $intentEntryPath -FixtureDirectory $intentFixture
        Test-BRAVOCondition `
            -Condition (
                $intentAutoAbsent.ExitCode -eq 0 -and
                $null -ne $intentAutoAbsent.Captured -and
                $intentAutoAbsent.Captured.ConfigPathBound -and
                $intentAutoAbsent.Captured.ConfigPathWasExplicitBound -and
                $intentAutoAbsent.Captured.ConfigPathWasExplicit -eq $false -and
                [string]$intentAutoAbsent.Captured.ConfigPath -eq $intentAutoConfigPath
            ) `
            -Name ($intentTestPrefix + '/AutoNoConfigIntentIsNotExplicit') `
            -Failure (
                'AUTO-виклик без BRAVO.config має дійти до runtime з ' +
                'ConfigPathWasExplicit=false і auto-derived шляхом; фактично: ' +
                ('exit={0}; captured={1}; stderr={2}' -f `
                    $intentAutoAbsent.ExitCode,
                    ($intentAutoAbsent.Captured | ConvertTo-Json -Compress),
                    $intentAutoAbsent.StdErr)
            )

        # --- AUTO + config ПРИСУТНІЙ: намір так само НЕ explicit ---
        [IO.File]::WriteAllText($intentAutoConfigPath, $intentBenignConfigText, [Text.Encoding]::UTF8)
        $intentAutoPresent = Invoke-BRAVOConfigIntentScenario `
            -EntryScriptPath $intentEntryPath -FixtureDirectory $intentFixture
        [IO.File]::Delete($intentAutoConfigPath)
        Test-BRAVOCondition `
            -Condition (
                $intentAutoPresent.ExitCode -eq 0 -and
                $null -ne $intentAutoPresent.Captured -and
                $intentAutoPresent.Captured.ConfigPathWasExplicit -eq $false -and
                [string]$intentAutoPresent.Captured.ConfigPath -eq $intentAutoConfigPath
            ) `
            -Name ($intentTestPrefix + '/AutoWithConfigIntentIsNotExplicit') `
            -Failure (
                'AUTO-виклик з наявним BRAVO.config не повинен ставати explicit; фактично: ' +
                ('exit={0}; captured={1}' -f $intentAutoPresent.ExitCode,
                    ($intentAutoPresent.Captured | ConvertTo-Json -Compress))
            )

        # --- EXPLICIT + config ПРИСУТНІЙ: намір explicit, точний шлях ---
        $intentExplicitDirectory = Join-Path $intentFixture 'ExplicitConfig'
        [void][IO.Directory]::CreateDirectory($intentExplicitDirectory)
        $intentExplicitConfigPath = Join-Path $intentExplicitDirectory 'BRAVO.config'
        [IO.File]::WriteAllText($intentExplicitConfigPath, $intentBenignConfigText, [Text.Encoding]::UTF8)
        $intentExplicitPresent = Invoke-BRAVOConfigIntentScenario `
            -EntryScriptPath $intentEntryPath -FixtureDirectory $intentFixture `
            -ExtraArguments @('-ConfigPath', ('"{0}"' -f $intentExplicitConfigPath))
        Test-BRAVOCondition `
            -Condition (
                $intentExplicitPresent.ExitCode -eq 0 -and
                $null -ne $intentExplicitPresent.Captured -and
                $intentExplicitPresent.Captured.ConfigPathWasExplicit -eq $true -and
                [string]$intentExplicitPresent.Captured.ConfigPath -eq $intentExplicitConfigPath
            ) `
            -Name ($intentTestPrefix + '/ExplicitIntentAndExactPathRetained') `
            -Failure (
                'EXPLICIT-виклик має дійти до runtime з ConfigPathWasExplicit=true ' +
                'і точним нормалізованим шляхом; фактично: ' +
                ('exit={0}; captured={1}' -f $intentExplicitPresent.ExitCode,
                    ($intentExplicitPresent.Captured | ConvertTo-Json -Compress))
            )

        # --- EXPLICIT + config ВІДСУТНІЙ: намір і шлях зберігаються ---
        $intentExplicitMissingPath = Join-Path $intentFixture 'missing\BRAVO.config'
        $intentExplicitMissing = Invoke-BRAVOConfigIntentScenario `
            -EntryScriptPath $intentEntryPath -FixtureDirectory $intentFixture `
            -ExtraArguments @('-ConfigPath', ('"{0}"' -f $intentExplicitMissingPath))
        Test-BRAVOCondition `
            -Condition (
                $null -ne $intentExplicitMissing.Captured -and
                $intentExplicitMissing.Captured.ConfigPathWasExplicit -eq $true -and
                [string]$intentExplicitMissing.Captured.ConfigPath -eq $intentExplicitMissingPath
            ) `
            -Name ($intentTestPrefix + '/ExplicitMissingIntentRetained') `
            -Failure (
                'EXPLICIT-виклик з відсутнім файлом не має деградувати в AUTO: ' +
                'намір і точний шлях мусять дійти до runtime (fail-closed ' +
                'вирішує Import-BravoConfiguration); фактично: ' +
                ('captured={0}' -f ($intentExplicitMissing.Captured | ConvertTo-Json -Compress))
            )
    }
} finally {
    if ([IO.Directory]::Exists($configIntentFixtureRoot)) {
        try {
            Remove-Item -LiteralPath $configIntentFixtureRoot -Recurse -Force -ErrorAction Stop
        } catch {
            # best-effort: тимчасова fixture-тека не впливає на результат.
        }
    }
}

# ===== Child-propagation: Health UAC relaunch argument builder =====
$configIntentHealthRootText = [IO.File]::ReadAllText(
    (Join-Path $root 'BRAVO_HEALTH.ps1'), [Text.Encoding]::UTF8
)
$configIntentHealthRelaunchModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText $configIntentHealthRootText `
    -FunctionNames @('New-BRAVOHealthRelaunchArgumentList')

$configIntentHealthAutoArgv = & $configIntentHealthRelaunchModule {
    New-BRAVOHealthRelaunchArgumentList `
        -ScriptPath 'C:\kit\BRAVO_HEALTH.ps1' `
        -BoundParameters @{ NoPause = $true } `
        -ResolvedConfigPath $null
}
$configIntentHealthExplicitArgv = & $configIntentHealthRelaunchModule {
    New-BRAVOHealthRelaunchArgumentList `
        -ScriptPath 'C:\kit\BRAVO_HEALTH.ps1' `
        -BoundParameters @{ ConfigPath = 'C:\cfg\BRAVO.config'; NoPause = $true } `
        -ResolvedConfigPath 'C:\cfg\BRAVO.config'
}
Test-BRAVOCondition `
    -Condition (
        @($configIntentHealthAutoArgv) -notcontains '-ConfigPath' -and
        @($configIntentHealthExplicitArgv) -contains '-ConfigPath' -and
        @($configIntentHealthExplicitArgv) -contains '"C:\cfg\BRAVO.config"'
    ) `
    -Name 'ConfigIntent/HealthRelaunchArgvHonoursIntent' `
    -Failure 'UAC-relaunch argv Health: AUTO не повинен містити -ConfigPath, EXPLICIT — мусить містити точний квотований шлях'

# Root Health передає в builder ResolvedConfigPath ЛИШЕ за explicit-наміру.
Test-BRAVOCondition `
    -Condition ($configIntentHealthRootText.Contains(
        '$relaunchResolvedConfigPath = if ($configPathWasExplicit) { $effectiveConfigPath } else { $null }'
    )) `
    -Name 'ConfigIntent/HealthRootGatesRelaunchConfigByIntent' `
    -Failure 'BRAVO_HEALTH.ps1 має передавати ResolvedConfigPath у relaunch-builder лише коли -ConfigPath був явним'

# ===== Характеризація: межа оператора і заборона повторного вгадування =====
$configIntentRootEntrypoints = @(
    'BRAVO_ARCHIV.ps1', 'BRAVO_MAINTENANCE.ps1', 'BRAVO_HEALTH.ps1',
    'BRAVO_DATA_RESTORE.ps1', 'BRAVO_BAZA_RECONCILE.ps1', 'BRAVO_RESTORE_TEST.ps1'
)
$configIntentCaptureMarker = "$" + "configPathWasExplicit = $" + "PSBoundParameters.ContainsKey('ConfigPath')"
$configIntentReassignMarker = "$" + "ConfigPath = $" + "effectiveConfigPath"
$configIntentBrokenOrder = @()
foreach ($configIntentEntrypointName in $configIntentRootEntrypoints) {
    $configIntentEntrypointText = [IO.File]::ReadAllText(
        (Join-Path $root $configIntentEntrypointName), [Text.Encoding]::UTF8
    )
    $configIntentCaptureIndex = $configIntentEntrypointText.IndexOf($configIntentCaptureMarker)
    $configIntentReassignIndex = $configIntentEntrypointText.IndexOf($configIntentReassignMarker)
    if ($configIntentCaptureIndex -lt 0 -or
        $configIntentReassignIndex -lt 0 -or
        $configIntentCaptureIndex -gt $configIntentReassignIndex) {
        $configIntentBrokenOrder += $configIntentEntrypointName
    }
}
Test-BRAVOCondition `
    -Condition ($configIntentBrokenOrder.Count -eq 0) `
    -Name 'ConfigIntent/AllRootEntrypointsCaptureIntentBeforeDerivation' `
    -Failure (
        'root entrypoint мусить фіксувати намір оператора ДО реасайну ' +
        '$ConfigPath на effective-шлях; порушено: ' +
        ($configIntentBrokenOrder -join ', ')
    )

$configIntentForwardingSplats = @(
    'BRAVO_ARCHIV.ps1', 'BRAVO_MAINTENANCE.ps1', 'BRAVO_HEALTH.ps1', 'BRAVO_DATA_RESTORE.ps1'
)
$configIntentMissingForward = @()
foreach ($configIntentEntrypointName in $configIntentForwardingSplats) {
    $configIntentEntrypointText = [IO.File]::ReadAllText(
        (Join-Path $root $configIntentEntrypointName), [Text.Encoding]::UTF8
    )
    if (-not $configIntentEntrypointText.Contains('ConfigPathWasExplicit = $configPathWasExplicit')) {
        $configIntentMissingForward += $configIntentEntrypointName
    }
}
Test-BRAVOCondition `
    -Condition ($configIntentMissingForward.Count -eq 0) `
    -Name 'ConfigIntent/ForwardingEntrypointsSplatIntent' `
    -Failure (
        'entrypoint, що делегує в runtime, мусить класти ConfigPathWasExplicit у splat; ' +
        'відсутнє в: ' + ($configIntentMissingForward -join ', ')
    )

$configIntentRuntimeFiles = @(
    'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1',
    'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1',
    'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1',
    'modules\BRAVO.DataRestore\BRAVO.DataRestore.Runtime.ps1'
)
$configIntentRuntimeViolations = @()
foreach ($configIntentRuntimeName in $configIntentRuntimeFiles) {
    $configIntentRuntimeText = [IO.File]::ReadAllText(
        (Join-Path $root $configIntentRuntimeName), [Text.Encoding]::UTF8
    )
    $configIntentRuntimeHasParameter = $configIntentRuntimeText.Contains('[bool]$ConfigPathWasExplicit')
    # Runtime отримує ConfigPath завжди bound від entrypoint-splat, тому
    # будь-яке повторне "вгадування" наміру через $PSBoundParameters у
    # runtime — регресія цього ж класу дефектів.
    $configIntentRuntimeGuessesAgain = $configIntentRuntimeText.Contains(
        "$" + "PSBoundParameters.ContainsKey('ConfigPath')"
    )
    if (-not $configIntentRuntimeHasParameter -or $configIntentRuntimeGuessesAgain) {
        $configIntentRuntimeViolations += $configIntentRuntimeName
    }
}
Test-BRAVOCondition `
    -Condition ($configIntentRuntimeViolations.Count -eq 0) `
    -Name 'ConfigIntent/RuntimesAcceptIntentParameterAndDoNotGuess' `
    -Failure (
        'runtime мусить приймати [bool]$ConfigPathWasExplicit і не відновлювати ' +
        'намір через $PSBoundParameters; порушено: ' +
        ($configIntentRuntimeViolations -join ', ')
    )

# ===== Характеризація: relaunch/child-канали зберігають AUTO-контракт =====
$configIntentCredentialsText = [IO.File]::ReadAllText(
    (Join-Path $root 'BRAVO_CREDENTIALS_SETUP.ps1'), [Text.Encoding]::UTF8
)
Test-BRAVOCondition `
    -Condition (
        $configIntentCredentialsText.Contains('$workerConfigArgumentText = if ($ConfigPathWasExplicit)') -and
        $configIntentCredentialsText.Contains('$elevationConfigArgumentText = if ($configPathWasExplicit)') -and
        @([regex]::Matches(
            $configIntentCredentialsText,
            'Invoke-AsSystem(?s:.){0,200}?-ConfigPathWasExplicit \$configPathWasExplicit'
        )).Count -eq 3
    ) `
    -Name 'ConfigIntent/CredentialsRelaunchesHonourIntent' `
    -Failure 'SYSTEM-worker та UAC-relaunch BRAVO_CREDENTIALS_SETUP мусять вбудовувати -ConfigPath лише за explicit-наміру, а всі 3 виклики Invoke-AsSystem — передавати намір (acceptance CF-17)'

$configIntentMaintenanceRuntimeText = [IO.File]::ReadAllText(
    (Join-Path $root 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'),
    [Text.Encoding]::UTF8
)
Test-BRAVOCondition `
    -Condition ($configIntentMaintenanceRuntimeText -match (
        '(?s)if \(\$configPathWasExplicit\) \{\s*' +
        [regex]::Escape('$elevatedArguments += @("-ConfigPath"')
    )) `
    -Name 'ConfigIntent/MaintenanceElevationGatesConfigByIntent' `
    -Failure 'UAC-relaunch Maintenance мусить вбудовувати -ConfigPath лише за explicit-наміру'

$configIntentArchiveRuntimeText = [IO.File]::ReadAllText(
    (Join-Path $root 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1'),
    [Text.Encoding]::UTF8
)
$configIntentHealthModuleText = [IO.File]::ReadAllText(
    (Join-Path $root 'modules\BRAVO.Health\BRAVO.Health.psm1'),
    [Text.Encoding]::UTF8
)
Test-BRAVOCondition `
    -Condition (
        $configIntentArchiveRuntimeText.Contains('ConfigPathWasExplicit = $configPathWasExplicit') -and
        $configIntentArchiveRuntimeText.Contains('$healthForwardConfigArguments = @{}') -and
        $configIntentHealthModuleText.Contains('ConfigPathWasExplicit = $ConfigPathWasExplicit')
    ) `
    -Name 'ConfigIntent/ArchiveToHealthChannelsPropagateIntent' `
    -Failure 'обидва канали Archive->Health (in-process Invoke-BRAVOHealthCheck та -HealthCheckOnly child) мусять пропагувати намір, а не вигаданий explicit'
