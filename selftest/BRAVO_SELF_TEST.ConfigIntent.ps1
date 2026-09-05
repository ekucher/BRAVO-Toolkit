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

# ===== Публічний positional-контракт Invoke-BRAVOHealthCheck =====
# Регресія review-знахідки PR #134: ConfigPathWasExplicit було вставлено
# ДРУГИМ параметром exported public function — за увімкненого positional
# binding це зсувало позиції всіх наступних параметрів, і legacy
# positional-виклик міг мовчки зв'язати друге значення з [bool]-прапорцем.
# Контракт: усі параметри, що існували ДО PR #134, зберігають свій
# declaration/positional order 1:1; нові параметри — лише ПІСЛЯ них.

# --- H1: declaration order (AST) ---
$configIntentHealthAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'modules\BRAVO.Health\BRAVO.Health.psm1'), [ref]$null, [ref]$null
)
$configIntentHealthCheckAst = $configIntentHealthAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Invoke-BRAVOHealthCheck'
}, $true)
$configIntentHealthParamNames = @(
    $configIntentHealthCheckAst.Body.ParamBlock.Parameters |
        ForEach-Object { $_.Name.VariablePath.UserPath }
)
# Порядок exported-контракту ДО PR #134 (origin/developer) — не змінювати.
$configIntentHealthBaselineOrder = @(
    'ConfigPath', 'ForceNotification', 'NotifyOnSuccess', 'NoSlack',
    'SkipIfBackupTaskRunning', 'RuntimeRoot', 'EntryScriptPath', 'BazaSyncResults'
)
$configIntentHealthPrefixIntact = (
    $configIntentHealthParamNames.Count -gt $configIntentHealthBaselineOrder.Count
)
if ($configIntentHealthPrefixIntact) {
    for ($configIntentHealthIndex = 0;
         $configIntentHealthIndex -lt $configIntentHealthBaselineOrder.Count;
         $configIntentHealthIndex++) {
        if ($configIntentHealthParamNames[$configIntentHealthIndex] -cne
            $configIntentHealthBaselineOrder[$configIntentHealthIndex]) {
            $configIntentHealthPrefixIntact = $false
            break
        }
    }
}
Test-BRAVOCondition `
    -Condition (
        $configIntentHealthPrefixIntact -and
        ([Collections.Generic.List[string]]$configIntentHealthParamNames).IndexOf('ConfigPathWasExplicit') -ge
            $configIntentHealthBaselineOrder.Count
    ) `
    -Name 'ConfigIntent/HealthPublicApiParameterOrderPreserved' `
    -Failure (
        'exported Invoke-BRAVOHealthCheck мусить зберігати порядок параметрів ' +
        'до-PR#134 контракту (' + ($configIntentHealthBaselineOrder -join ', ') +
        '), а ConfigPathWasExplicit — лише ПІСЛЯ них; фактично: ' +
        ($configIntentHealthParamNames -join ', ')
    )

# --- H2..H5: behavior-level binding у дочірньому процесі ---
# Fixture-копія СПРАВЖНЬОГО BRAVO.Health.psm1 зі stub-Runtime, що фіксує,
# ЩО реально дійшло до runtime-splat. Дочірній процес виключає колізію з
# уже імпортованим у цій сесії модулем BRAVO.Health.
$configIntentHealthApiFixture = Join-Path $configIntentTempBase (
    'BRAVO_HEALTH_API_{0}' -f [guid]::NewGuid().ToString('N')
)
try {
    [void][IO.Directory]::CreateDirectory($configIntentHealthApiFixture)
    Copy-Item -LiteralPath (Join-Path $root 'modules\BRAVO.Health\BRAVO.Health.psm1') `
        -Destination (Join-Path $configIntentHealthApiFixture 'BRAVO.Health.psm1')
    $configIntentHealthStubRuntime = @'
param(
    [string]$ConfigPath,
    [bool]$ConfigPathWasExplicit = $false,
    [switch]$ForceNotification,
    [switch]$NotifyOnSuccess,
    [switch]$NoSlack,
    [switch]$SkipIfBackupTaskRunning,
    [switch]$NoPause,
    [string]$RuntimeRoot,
    [string]$EntryScriptPath
)
$script:Login = $null
$script:resolvedSftpHost = $null
$script:sftpUrl = $null
$script:smbCredential = $null
$script:stubRuntimeConfigPath = $ConfigPath
$script:stubRuntimeConfigPathWasExplicit = $ConfigPathWasExplicit
$script:stubRuntimeRuntimeRoot = $RuntimeRoot
$script:stubRuntimeEntryScriptPath = $EntryScriptPath
function Invoke-BRAVOHealth {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [switch]$ForceNotification,
        [switch]$NotifyOnSuccess,
        [switch]$NoSlack,
        [hashtable]$BazaSyncResults,
        [switch]$SkipIfBackupTaskRunning,
        [switch]$SuppressHeader
    )
    $bazaKeys = ''
    if ($null -ne $BazaSyncResults) {
        $bazaKeys = (@($BazaSyncResults.Keys) | Sort-Object) -join ','
    }
    return [pscustomobject]@{
        Status = 'StubCaptured'
        Notification = 'none'
        RuntimeConfigPath = $script:stubRuntimeConfigPath
        RuntimeConfigPathWasExplicit = $script:stubRuntimeConfigPathWasExplicit
        RuntimeRoot = $script:stubRuntimeRuntimeRoot
        RuntimeEntryScriptPath = $script:stubRuntimeEntryScriptPath
        BazaSyncKeys = $bazaKeys
    }
}
'@
    [IO.File]::WriteAllText(
        (Join-Path $configIntentHealthApiFixture 'BRAVO.Health.Runtime.ps1'),
        $configIntentHealthStubRuntime, [Text.Encoding]::UTF8
    )
    $configIntentHealthApiProbe = @'
param(
    [Parameter(Mandatory = $true)][string]$ModulePath,
    [Parameter(Mandatory = $true)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module $ModulePath -Force
$probeConfigPath = 'C:\__bravo_probe__\BRAVO.config'
$probeRuntimeRoot = 'C:\__bravo_probe__\runtime'
$probeEntryScript = 'C:\__bravo_probe__\BRAVO_HEALTH.ps1'
$probeBaza = @{ BAZA_APP = 'probe' }
$probeResults = @{}
# H2: legacy positional call за до-PR#134 схемою:
# ConfigPath(0), RuntimeRoot(1), EntryScriptPath(2), BazaSyncResults(3).
try {
    $probePositional = Invoke-BRAVOHealthCheck `
        $probeConfigPath $probeRuntimeRoot $probeEntryScript $probeBaza
    $probeResults['Positional'] = @{
        Ok = $true
        ConfigPath = [string]$probePositional.RuntimeConfigPath
        WasExplicit = [bool]$probePositional.RuntimeConfigPathWasExplicit
        RuntimeRoot = [string]$probePositional.RuntimeRoot
        EntryScriptPath = [string]$probePositional.RuntimeEntryScriptPath
        BazaSyncKeys = [string]$probePositional.BazaSyncKeys
    }
} catch {
    $probeResults['Positional'] = @{ Ok = $false; Error = $_.Exception.Message }
}
# H3: named explicit ConfigPath без прапорця -> inference = explicit.
try {
    $probeNamed = Invoke-BRAVOHealthCheck `
        -ConfigPath $probeConfigPath -RuntimeRoot $probeRuntimeRoot
    $probeResults['NamedExplicit'] = @{
        Ok = $true; WasExplicit = [bool]$probeNamed.RuntimeConfigPathWasExplicit
    }
} catch {
    $probeResults['NamedExplicit'] = @{ Ok = $false; Error = $_.Exception.Message }
}
# H4: явний $false має пріоритет над inference (AUTO-derived непорожній шлях).
try {
    $probeAutoFalse = Invoke-BRAVOHealthCheck `
        -ConfigPath $probeConfigPath -ConfigPathWasExplicit $false `
        -RuntimeRoot $probeRuntimeRoot
    $probeResults['ExplicitFalse'] = @{
        Ok = $true; WasExplicit = [bool]$probeAutoFalse.RuntimeConfigPathWasExplicit
    }
} catch {
    $probeResults['ExplicitFalse'] = @{ Ok = $false; Error = $_.Exception.Message }
}
# H5: явний $true проходить без повторного inference (ConfigPath не bound,
# inference дав би $false).
try {
    $probeTrue = Invoke-BRAVOHealthCheck `
        -ConfigPathWasExplicit $true -RuntimeRoot $probeRuntimeRoot
    $probeResults['ExplicitTrue'] = @{
        Ok = $true; WasExplicit = [bool]$probeTrue.RuntimeConfigPathWasExplicit
    }
} catch {
    $probeResults['ExplicitTrue'] = @{ Ok = $false; Error = $_.Exception.Message }
}
[IO.File]::WriteAllText(
    $ResultPath, ($probeResults | ConvertTo-Json -Depth 5), [Text.Encoding]::UTF8
)
'@
    $configIntentHealthApiProbePath = Join-Path $configIntentHealthApiFixture 'probe.ps1'
    [IO.File]::WriteAllText(
        $configIntentHealthApiProbePath, $configIntentHealthApiProbe, [Text.Encoding]::UTF8
    )
    $configIntentHealthApiResultPath = Join-Path $configIntentHealthApiFixture 'result.json'
    $configIntentHealthApiPwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $configIntentHealthApiPwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $configIntentHealthApiProbePath `
        -ModulePath (Join-Path $configIntentHealthApiFixture 'BRAVO.Health.psm1') `
        -ResultPath $configIntentHealthApiResultPath | Out-Null
    $configIntentHealthApiResult = $null
    if ([IO.File]::Exists($configIntentHealthApiResultPath)) {
        $configIntentHealthApiResult = [IO.File]::ReadAllText(
            $configIntentHealthApiResultPath, [Text.Encoding]::UTF8
        ) | ConvertFrom-Json
    }
    Test-BRAVOCondition `
        -Condition (
            $null -ne $configIntentHealthApiResult -and
            $configIntentHealthApiResult.Positional.Ok -and
            [string]$configIntentHealthApiResult.Positional.ConfigPath -eq 'C:\__bravo_probe__\BRAVO.config' -and
            $configIntentHealthApiResult.Positional.WasExplicit -eq $true -and
            [string]$configIntentHealthApiResult.Positional.RuntimeRoot -eq 'C:\__bravo_probe__\runtime' -and
            [string]$configIntentHealthApiResult.Positional.EntryScriptPath -eq 'C:\__bravo_probe__\BRAVO_HEALTH.ps1' -and
            [string]$configIntentHealthApiResult.Positional.BazaSyncKeys -eq 'BAZA_APP'
        ) `
        -Name 'ConfigIntent/HealthPublicApiLegacyPositionalBinding' `
        -Failure (
            'legacy positional-виклик Invoke-BRAVOHealthCheck мусить зв''язати ' +
            'ConfigPath/RuntimeRoot/EntryScriptPath/BazaSyncResults як ДО PR #134; ' +
            'фактично: ' + ($configIntentHealthApiResult | ConvertTo-Json -Compress -Depth 5)
        )
    Test-BRAVOCondition `
        -Condition (
            $null -ne $configIntentHealthApiResult -and
            $configIntentHealthApiResult.NamedExplicit.Ok -and
            $configIntentHealthApiResult.NamedExplicit.WasExplicit -eq $true -and
            $configIntentHealthApiResult.ExplicitFalse.Ok -and
            $configIntentHealthApiResult.ExplicitFalse.WasExplicit -eq $false -and
            $configIntentHealthApiResult.ExplicitTrue.Ok -and
            $configIntentHealthApiResult.ExplicitTrue.WasExplicit -eq $true
        ) `
        -Name 'ConfigIntent/HealthPublicApiIntentInferenceAndOverrides' `
        -Failure (
            'семантика наміру Invoke-BRAVOHealthCheck: named explicit ConfigPath -> ' +
            'explicit; явний $false/$true має пріоритет над inference; фактично: ' +
            ($configIntentHealthApiResult | ConvertTo-Json -Compress -Depth 5)
        )
} finally {
    if ([IO.Directory]::Exists($configIntentHealthApiFixture)) {
        try {
            Remove-Item -LiteralPath $configIntentHealthApiFixture -Recurse -Force -ErrorAction Stop
        } catch {
            # best-effort: тимчасова fixture-тека не впливає на результат.
        }
    }
}
