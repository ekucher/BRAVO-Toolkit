# BRAVO.DataRestore.MatrixTest — фікстури й драйвер для ручного, повністю
# себестоятного end-to-end матричного тесту BRAVO_DATA_RESTORE (-Source
# Local): будує ізольований TEMP-sandbox (fixture BRAVO.config, синтетичні
# "live"-джерела компонентів, реальні генерації через справжній
# BRAVO_ARCHIV.ps1), запускає кожну комбінацію матриці як окремий дочірній
# powershell.exe-процес (Runtime.ps1 робить рядковий `exit N`, що в межах
# одного процесу завершило б увесь довгоживучий host — див.
# BRAVO_DATA_RESTORE_MATRIX_TEST.ps1) і перевіряє файловий/стан-результат.
#
# Використовується ЛИШЕ для ручного запуску (не підключено до CI) з
# елевованої сесії. Жодна реальна Windows-служба, production LIMS-дані чи
# SFTP не зачіпаються — див. коментарі нижче про Managed=false та
# discoverySettings.Sources override.

$compatibilityManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.Compatibility\BRAVO.Compatibility.psd1'
Import-Module -Name $compatibilityManifest -ErrorAction Stop
$archiveHelpersManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1'
Import-Module -Name $archiveHelpersManifest -ErrorAction Stop
$exitCodesManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.ExitCodes\BRAVO.ExitCodes.psd1'
Import-Module -Name $exitCodesManifest -ErrorAction Stop

# Неіснуючі назви служб (безпечна fixture-константа, розділ "Служби для
# InPlace" плану): Get-BRAVODataRestoreServiceSnapshot позначає запис
# Managed=true лише коли реальний Get-Service знаходить службу з таким
# іменем. З цими назвами жодна InPlace-комбінація матриці ніколи не
# запитує/не зупиняє/не запускає жодну реальну Windows-службу. НЕ
# змінювати на реальні імена служб.
$script:FixtureBravoServiceName = 'BRAVO_MATRIXTEST_NONEXISTENT_SVC'
$script:FixtureBravoDisplayName = 'BRAVO_MATRIXTEST_NONEXISTENT_DISPLAY'
$script:FixtureExchangeApiServiceName = 'BRAVO_MATRIXTEST_NONEXISTENT_EXCH'

function New-BRAVODataRestoreMatrixFixtureConfig {
    # Будує fixture BRAVO.config як трансформовану копію РЕАЛЬНОГО
    # BRAVO.config комплекту (не hand-rolled з нуля): усі похідні
    # обчислення (Resolve-BRAVOEffectiveLimsRoot,
    # Resolve-BRAVOInstallationDiscovery, Resolve-BRAVOEffectiveBackupRoot,
    # Get-BRAVOEffectiveSynchronizationConfiguration) лишаються реальним
    # кодом комплекту — підмінюються лише вхідні блоки значень
    # (pathSettings/discoverySettings/componentSettings/operationLockSettings
    # + кілька скалярних рядків), через анкеровані на `^$global:<ім'я> = @{`
    # regex-блоки, а не хардкод номерів рядків — стійкіше до майбутніх
    # правок реального BRAVO.config, ніж копіювання тексту вручну.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$FixtureRoot,
        [string]$ConfigFileName = 'BRAVO.config',
        [int]$MinimumFreeSpaceGB = 1
    )

    $configRootDir = Join-Path $FixtureRoot 'CONFIG'
    $limsRootDir = Join-Path $FixtureRoot 'LIMS'
    $systemLogRootDir = Join-Path $FixtureRoot 'SYSTEMLOGS'
    $backupRootDir = Join-Path $FixtureRoot 'ARCHIV'
    $sourcesRootDir = Join-Path $FixtureRoot 'SOURCES'
    $sourceDirectories = @{
        MODEL = Join-Path $sourcesRootDir 'MODEL'
        BLOG = Join-Path $sourcesRootDir 'BLOG'
        BRAVOEXCH = Join-Path $sourcesRootDir 'BRAVOEXCH'
    }
    $lockPath = Join-Path $FixtureRoot 'LOCK\BRAVO_OPERATION.lock'

    foreach ($directory in @($configRootDir, $limsRootDir, $systemLogRootDir, $backupRootDir) + @($sourceDirectories.Values) + @(Split-Path $lockPath -Parent)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop)
        }
    }

    $realConfigPath = Join-Path $RepoRoot 'BRAVO.config'
    $configText = Get-Content -LiteralPath $realConfigPath -Raw -Encoding UTF8

    $fixturePathSettingsBlock = @"
`$global:pathSettings = @{
    LIMSRoot      = "$limsRootDir"
    SystemLogRoot = "$systemLogRootDir"
    BackupRoot    = "$backupRootDir"
}
"@
    $fixtureDiscoverySettingsBlock = @"
`$global:discoverySettings = @{
    BravoIniPath = `$null
    BravoRoot = `$null
    WebRoot = `$null
    Sources = @{
        MODEL = "$($sourceDirectories.MODEL)"
        BLOG = "$($sourceDirectories.BLOG)"
        BRAVOEXCH = "$($sourceDirectories.BRAVOEXCH)"
        BAZA_APP = `$null
        BAZA_WWW = `$null
        BACKUP_ROOT = `$null
    }
}
"@
    # Archive: усі три компоненти увімкнені (потрібні реальні генерації для
    # матриці). Synchronization/SFTP/SMB: усі вимкнені — fixture-прогін
    # BRAVO_ARCHIV не повинен намагатися жодного мережевого шляху.
    $fixtureComponentSettingsBlock = @"
`$global:componentSettings = @{
    Archive = @{
        MODEL = `$true
        BLOG = `$true
        BRAVOEXCH = `$true
    }
    Synchronization = @{
        BAZA_APP_LOCAL = `$false
        BAZA_APP_SFTP = `$false
        BAZA_WWW_SFTP = `$false
        BAZA_WWW_LOCAL = `$false
    }
    SFTP = @{
        ArchiveUpload = `$false
    }
    SMB = @{
        ArchiveCopy = `$false
    }
}
"@
    $fixtureOperationLockSettingsBlock = @"
`$global:operationLockSettings = @{
    Path = "$lockPath"
}
"@

    $blockReplacements = @(
        @{ Pattern = '(?ms)^\$global:pathSettings = @\{.*?^\}'; Replacement = $fixturePathSettingsBlock }
        @{ Pattern = '(?ms)^\$global:discoverySettings = @\{.*?^\}'; Replacement = $fixtureDiscoverySettingsBlock }
        @{ Pattern = '(?ms)^\$global:componentSettings = @\{.*?^\}'; Replacement = $fixtureComponentSettingsBlock }
        @{ Pattern = '(?ms)^\$global:operationLockSettings = @\{.*?^\}'; Replacement = $fixtureOperationLockSettingsBlock }
    )
    foreach ($block in $blockReplacements) {
        $newConfigText = [regex]::Replace($configText, $block.Pattern, { param($m) $block.Replacement })
        if ($newConfigText -eq $configText) {
            throw "New-BRAVODataRestoreMatrixFixtureConfig: не знайдено очікуваний блок конфігурації за шаблоном '$($block.Pattern)' — реальний BRAVO.config змінив структуру, fixture-генератор потребує оновлення."
        }
        $configText = $newConfigText
    }

    $scalarReplacements = @(
        @{ Pattern = '(?m)^(\s*NotificationMode\s*=\s*)"all"'; Replacement = '${1}"none"' }
        @{ Pattern = '(?m)^(\s*MinimumFreeSpaceGB\s*=\s*)20\b'; Replacement = "`${1}$MinimumFreeSpaceGB" }
        @{ Pattern = '(?m)^(\s*BravoName\s*=\s*)"BRAVO"'; Replacement = "`${1}`"$($script:FixtureBravoServiceName)`"" }
        @{ Pattern = '(?m)^(\s*BravoDisplayName\s*=\s*)"BRAVO Service"'; Replacement = "`${1}`"$($script:FixtureBravoDisplayName)`"" }
        @{ Pattern = '(?m)^(\s*BravoWebEnabled\s*=\s*)\$true'; Replacement = '${1}$false' }
        @{ Pattern = '(?m)^(\s*ExchangeApiName\s*=\s*)"exchangAPI"'; Replacement = "`${1}`"$($script:FixtureExchangeApiServiceName)`"" }
    )
    foreach ($scalar in $scalarReplacements) {
        $newConfigText = [regex]::Replace($configText, $scalar.Pattern, $scalar.Replacement)
        if ($newConfigText -eq $configText) {
            throw "New-BRAVODataRestoreMatrixFixtureConfig: не знайдено очікуваний рядок конфігурації за шаблоном '$($scalar.Pattern)' — реальний BRAVO.config змінив структуру, fixture-генератор потребує оновлення."
        }
        $configText = $newConfigText
    }

    $fixtureConfigPath = Join-Path $configRootDir $ConfigFileName
    Set-Content -LiteralPath $fixtureConfigPath -Value $configText -Encoding UTF8 -NoNewline

    return [pscustomobject]@{
        ConfigPath = $fixtureConfigPath
        ConfigRoot = $configRootDir
        BackupRoot = $backupRootDir
        SourceDirectories = $sourceDirectories
        LockPath = $lockPath
        MinimumFreeSpaceGB = $MinimumFreeSpaceGB
    }
}

function New-BRAVODataRestoreMatrixFixtureGeneration {
    # Пише синтетичний canary-вміст у fixture-джерела (SOURCES\<Component>)
    # і запускає РЕАЛЬНИЙ BRAVO_ARCHIV.ps1 проти fixture-конфігу — тим
    # самим кодом (VSS, 7za.exe, manifest-writer, SHA512), що виробляє
    # production-бекапи, а не hand-rolled fixture (розділ "Fixture-архіви"
    # плану: Get-BRAVOVerifiedGenerationArchive/Get-BRAVORestoreGenerationManifest
    # роблять строгу перевірку, з якою саморобна фікстура ризикує розійтися).
    # Приймає, що це створює реальний VSS shadow copy тому, що містить
    # SOURCES\* (узгоджено з користувачем).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][pscustomobject]$FixtureConfig,
        [Parameter(Mandatory = $true)][string]$CanaryValue,
        [int]$TimeoutSeconds = 600
    )

    foreach ($component in @('MODEL', 'BLOG', 'BRAVOEXCH')) {
        $sourceDirectory = [string]$FixtureConfig.SourceDirectories[$component]
        if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $sourceDirectory -Force -ErrorAction Stop)
        }
        Set-Content -LiteralPath (Join-Path $sourceDirectory 'CANARY.txt') -Value $CanaryValue -Encoding UTF8 -NoNewline
        Set-Content -LiteralPath (Join-Path $sourceDirectory 'FILLER.txt') -Value "BRAVO_DATA_RESTORE_MATRIX_TEST fixture filler ($component)" -Encoding UTF8
    }

    $manifestRoot = Get-BRAVOBackupManifestRoot -BackupRoot ([string]$FixtureConfig.BackupRoot)
    $generationIdsBefore = @(
        if (Test-Path -LiteralPath $manifestRoot -PathType Container) {
            Get-ChildItem -LiteralPath $manifestRoot -Filter 'BRAVO_BACKUP_*.json' -File |
                ForEach-Object { $_.BaseName -replace '^BRAVO_BACKUP_', '' }
        }
    )

    $archiveScriptPath = Join-Path $RepoRoot 'BRAVO_ARCHIV.ps1'
    $argumentString = "-NoProfile -ExecutionPolicy Bypass -File $(ConvertTo-BRAVOWindowsCommandLineArgument -Argument $archiveScriptPath) -ConfigPath $(ConvertTo-BRAVOWindowsCommandLineArgument -Argument ([string]$FixtureConfig.ConfigPath)) -NoPause"
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = $argumentString
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $capture = Start-BRAVOProcessOutputCapture -Process $process
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        try { $process.Kill() } catch {
            # Процес міг завершитись між перевіркою й Kill — не критично.
        }
        throw "New-BRAVODataRestoreMatrixFixtureGeneration: BRAVO_ARCHIV.ps1 не завершився за $TimeoutSeconds с."
    }
    $output = Complete-BRAVOProcessOutputCapture -Capture $capture
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 10) {
        # 0=Success, 10=SuccessWithWarnings (BRAVO.ExitCodes) — обидва прийнятні
        # для fixture-генерації; решта — реальний збій архівації.
        throw "New-BRAVODataRestoreMatrixFixtureGeneration: BRAVO_ARCHIV.ps1 завершився з кодом $($process.ExitCode) ($(Get-BRAVOExitCodeName -Code $process.ExitCode)). StdOut: $($output.StandardOutput) StdErr: $($output.StandardError)"
    }

    $generationIdsAfter = @(
        Get-ChildItem -LiteralPath $manifestRoot -Filter 'BRAVO_BACKUP_*.json' -File |
            ForEach-Object { $_.BaseName -replace '^BRAVO_BACKUP_', '' }
    )
    $newGenerationIds = @($generationIdsAfter | Where-Object { $generationIdsBefore -notcontains $_ })
    if ($newGenerationIds.Count -ne 1) {
        throw "New-BRAVODataRestoreMatrixFixtureGeneration: очікувалась рівно 1 нова generation, знайдено $($newGenerationIds.Count) ($($newGenerationIds -join ', '))."
    }
    return [string]$newGenerationIds[0]
}

function Invoke-BRAVODataRestoreMatrixCombo {
    # Спавнить BRAVO_DATA_RESTORE.ps1 як ОКРЕМИЙ дочірній процес (не
    # in-process виклик Invoke-BRAVODataRestoreEntrypoint — Runtime.ps1
    # робить рядковий `exit N`, що в межах поточного host завершило б увесь
    # довгоживучий процес-драйвер, а не лише дочірню операцію). Failpoint
    # env vars виставляються лише на ProcessStartInfo.EnvironmentVariables
    # цього конкретного процесу — не протікають між комбінаціями матриці.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][hashtable]$Arguments,
        [string]$FailpointComponent,
        [int]$TimeoutSeconds = 180,
        # Стабільний каталог ПОЗА fixture-коренем (який прибирається в
        # finally, якщо не -KeepFixture) — щоб CI міг завантажити stdout/
        # stderr кожної комбінації як артефакт при падінні, а не втратити
        # їх разом із видаленою TEMP-фікстурою. Комбінація ще й іменем
        # файлу описує себе, тому оператору не треба співвідносити з
        # порядком запуску.
        [string]$LogDirectory,
        [string]$ComboName
    )

    $scriptPath = Join-Path $RepoRoot 'BRAVO_DATA_RESTORE.ps1'
    $argumentParts = New-Object System.Collections.Generic.List[string]
    [void]$argumentParts.Add('-NoProfile')
    [void]$argumentParts.Add('-ExecutionPolicy')
    [void]$argumentParts.Add('Bypass')
    [void]$argumentParts.Add('-File')
    [void]$argumentParts.Add((ConvertTo-BRAVOWindowsCommandLineArgument -Argument $scriptPath))
    [void]$argumentParts.Add('-ConfigPath')
    [void]$argumentParts.Add((ConvertTo-BRAVOWindowsCommandLineArgument -Argument $ConfigPath))
    foreach ($key in $Arguments.Keys) {
        $value = $Arguments[$key]
        if ($value -is [switch] -or $value -is [bool]) {
            if ([bool]$value) { [void]$argumentParts.Add("-$key") }
            continue
        }
        if ($null -eq $value -or ([string]$value).Length -eq 0) { continue }
        [void]$argumentParts.Add("-$key")
        [void]$argumentParts.Add((ConvertTo-BRAVOWindowsCommandLineArgument -Argument ([string]$value)))
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = [string]::Join(' ', $argumentParts.ToArray())
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    if (-not [string]::IsNullOrWhiteSpace($FailpointComponent)) {
        $startInfo.EnvironmentVariables['BRAVO_DATARESTORE_TEST_HOOKS'] = 'ACCEPTANCE_ONLY'
        $startInfo.EnvironmentVariables['BRAVO_DATARESTORE_TEST_FAILPOINT'] = "AfterMoveAside:$FailpointComponent"
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $capture = Start-BRAVOProcessOutputCapture -Process $process
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        try { $process.Kill() } catch {
            # Процес міг завершитись між перевіркою й Kill — не критично.
        }
        return [pscustomobject]@{ ExitCode = -1; TimedOut = $true; StandardOutput = $null; StandardError = $null }
    }
    $output = Complete-BRAVOProcessOutputCapture -Capture $capture
    if (-not [string]::IsNullOrWhiteSpace($LogDirectory) -and -not [string]::IsNullOrWhiteSpace($ComboName)) {
        if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $LogDirectory -Force -ErrorAction Stop)
        }
        Set-Content -LiteralPath (Join-Path $LogDirectory "$ComboName.stdout.log") -Value ([string]$output.StandardOutput) -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $LogDirectory "$ComboName.stderr.log") -Value ([string]$output.StandardError) -Encoding UTF8
    }
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        TimedOut = $false
        StandardOutput = [string]$output.StandardOutput
        StandardError = [string]$output.StandardError
    }
}

function Get-BRAVODataRestoreMatrixComboDefinitions {
    # Курована (не повний cartesian) матриця з 16 комбінацій — розділ
    # "Матриця прогонів" плану. Кожен об'єкт: Name, Arguments (для
    # Invoke-BRAVODataRestoreMatrixCombo), FailpointComponent,
    # ExpectedExitCode, AssertionKind (розпізнається Assert-...ComboResult).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$FixtureConfig,
        [Parameter(Mandatory = $true)][pscustomobject]$FreeSpaceFixtureConfig,
        [Parameter(Mandatory = $true)][string]$NewerGenerationId,
        [Parameter(Mandatory = $true)][string]$OlderGenerationId,
        [Parameter(Mandatory = $true)][string]$OutOfPlaceRoot
    )

    $combos = New-Object System.Collections.Generic.List[object]

    foreach ($component in @('MODEL', 'BLOG', 'BRAVOEXCH')) {
        $combos.Add([pscustomobject]@{
            Name = "OutOfPlace-$component-Success"
            ConfigPath = $FixtureConfig.ConfigPath
            Arguments = @{ Component = $component; Mode = 'OutOfPlace'; TargetPath = (Join-Path $OutOfPlaceRoot "OOP_$component"); Source = 'Local'; Force = $true; NoPause = $true }
            FailpointComponent = $null
            ExpectedExitCode = 0
            AssertionKind = 'OutOfPlaceSuccess'
            AssertionComponent = $component
            ExpectedCanary = $NewerGenerationId
        })
    }
    $combos.Add([pscustomobject]@{
        Name = 'OutOfPlace-All-Success'
        ConfigPath = $FixtureConfig.ConfigPath
        Arguments = @{ Component = 'All'; Mode = 'OutOfPlace'; TargetPath = (Join-Path $OutOfPlaceRoot 'OOP_All'); Source = 'Local'; Force = $true; NoPause = $true }
        FailpointComponent = $null
        ExpectedExitCode = 0
        AssertionKind = 'OutOfPlaceSuccessAll'
        AssertionComponent = $null
        ExpectedCanary = $NewerGenerationId
    })
    $combos.Add([pscustomobject]@{
        Name = 'OutOfPlace-MODEL-ExplicitOlderGeneration'
        ConfigPath = $FixtureConfig.ConfigPath
        Arguments = @{ Component = 'MODEL'; Mode = 'OutOfPlace'; TargetPath = (Join-Path $OutOfPlaceRoot 'OOP_Explicit'); Source = 'Local'; GenerationId = $OlderGenerationId; Force = $true; NoPause = $true }
        FailpointComponent = $null
        ExpectedExitCode = 0
        AssertionKind = 'OutOfPlaceSuccess'
        AssertionComponent = 'MODEL'
        ExpectedCanary = $OlderGenerationId
    })
    foreach ($component in @('MODEL', 'BLOG', 'BRAVOEXCH')) {
        $combos.Add([pscustomobject]@{
            Name = "InPlace-$component-Success"
            ConfigPath = $FixtureConfig.ConfigPath
            Arguments = @{ Component = $component; Mode = 'InPlace'; Source = 'Local'; Force = $true; SkipHealthCheck = $true; NoPause = $true }
            FailpointComponent = $null
            ExpectedExitCode = 0
            AssertionKind = 'InPlaceSuccess'
            AssertionComponent = $component
            ExpectedCanary = $NewerGenerationId
        })
    }
    $combos.Add([pscustomobject]@{
        Name = 'InPlace-All-Success'
        ConfigPath = $FixtureConfig.ConfigPath
        Arguments = @{ Component = 'All'; Mode = 'InPlace'; Source = 'Local'; Force = $true; SkipHealthCheck = $true; NoPause = $true }
        FailpointComponent = $null
        ExpectedExitCode = 0
        AssertionKind = 'InPlaceSuccessAll'
        AssertionComponent = $null
        ExpectedCanary = $NewerGenerationId
    })
    $combos.Add([pscustomobject]@{
        Name = 'ListGenerations-Local'
        ConfigPath = $FixtureConfig.ConfigPath
        Arguments = @{ Source = 'Local'; ListGenerations = $true; NoPause = $true }
        FailpointComponent = $null
        ExpectedExitCode = 0
        AssertionKind = 'ListGenerationsNoMutation'
        AssertionComponent = $null
        ExpectedCanary = $null
    })
    $combos.Add([pscustomobject]@{
        Name = 'InPlace-MODEL-CurrentComponentRollback'
        ConfigPath = $FixtureConfig.ConfigPath
        Arguments = @{ Component = 'MODEL'; Mode = 'InPlace'; Source = 'Local'; Force = $true; SkipHealthCheck = $true; NoPause = $true }
        FailpointComponent = 'MODEL'
        ExpectedExitCode = 43
        AssertionKind = 'InPlaceRollback'
        AssertionComponent = 'MODEL'
        ExpectedCanary = $NewerGenerationId
    })
    $combos.Add([pscustomobject]@{
        Name = 'InPlace-All-CrossComponentRollback'
        ConfigPath = $FixtureConfig.ConfigPath
        Arguments = @{ Component = 'All'; Mode = 'InPlace'; Source = 'Local'; Force = $true; SkipHealthCheck = $true; NoPause = $true }
        FailpointComponent = 'BRAVOEXCH'
        ExpectedExitCode = 43
        AssertionKind = 'InPlaceRollbackAll'
        AssertionComponent = $null
        ExpectedCanary = $NewerGenerationId
    })
    $preExistingTarget = Join-Path $OutOfPlaceRoot 'OOP_PreExisting'
    [void](New-Item -ItemType Directory -Path (Join-Path $preExistingTarget 'MODEL') -Force -ErrorAction Stop)
    Set-Content -LiteralPath (Join-Path $preExistingTarget 'MODEL\SENTINEL.txt') -Value 'pre-existing, must remain untouched' -Encoding UTF8
    $combos.Add([pscustomobject]@{
        Name = 'OutOfPlace-MODEL-PreExistingTargetRejected'
        ConfigPath = $FixtureConfig.ConfigPath
        Arguments = @{ Component = 'MODEL'; Mode = 'OutOfPlace'; TargetPath = $preExistingTarget; Source = 'Local'; Force = $true; NoPause = $true }
        FailpointComponent = $null
        ExpectedExitCode = 30
        AssertionKind = 'PreExistingTargetUntouched'
        AssertionComponent = $null
        ExpectedCanary = $null
        SentinelPath = (Join-Path $preExistingTarget 'MODEL\SENTINEL.txt')
    })
    $combos.Add([pscustomobject]@{
        Name = 'InPlace-WithTargetPath-Rejected'
        ConfigPath = $FixtureConfig.ConfigPath
        Arguments = @{ Component = 'MODEL'; Mode = 'InPlace'; TargetPath = (Join-Path $OutOfPlaceRoot 'OOP_Invalid'); Source = 'Local'; Force = $true; SkipHealthCheck = $true; NoPause = $true }
        FailpointComponent = $null
        ExpectedExitCode = 30
        AssertionKind = 'NoAssertion'
        AssertionComponent = $null
        ExpectedCanary = $null
    })
    $combos.Add([pscustomobject]@{
        Name = 'OutOfPlace-WithoutTargetPath-Rejected'
        ConfigPath = $FixtureConfig.ConfigPath
        Arguments = @{ Component = 'MODEL'; Mode = 'OutOfPlace'; Source = 'Local'; Force = $true; NoPause = $true }
        FailpointComponent = $null
        ExpectedExitCode = 30
        AssertionKind = 'NoAssertion'
        AssertionComponent = $null
        ExpectedCanary = $null
    })
    $combos.Add([pscustomobject]@{
        Name = 'OutOfPlace-MODEL-FreeSpacePreflightBlocked'
        ConfigPath = $FreeSpaceFixtureConfig.ConfigPath
        Arguments = @{ Component = 'MODEL'; Mode = 'OutOfPlace'; TargetPath = (Join-Path $OutOfPlaceRoot 'OOP_FreeSpace'); Source = 'Local'; Force = $true; NoPause = $true }
        FailpointComponent = $null
        ExpectedExitCode = 43
        AssertionKind = 'NoExtractionOccurred'
        AssertionComponent = $null
        ExpectedCanary = $null
        SentinelPath = (Join-Path $OutOfPlaceRoot 'OOP_FreeSpace\MODEL\CANARY.txt')
    })

    return $combos.ToArray()
}

function Assert-BRAVODataRestoreMatrixComboResult {
    # Файлові/стан-перевірки для одного результату комбінації. Повертає
    # pscustomobject{Passed, Reasons[]} — Reasons порожній при Passed=true.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Combo,
        [Parameter(Mandatory = $true)][pscustomobject]$Result,
        [Parameter(Mandatory = $true)][pscustomobject]$FixtureConfig,
        [Parameter(Mandatory = $true)][hashtable]$CanaryByGeneration,
        # Live-каталоги переспоживаються послідовними комбінаціями матриці:
        # кожен УСПІШНИЙ InPlace-прогін навмисно лишає власну постійну
        # .prerestore_* копію (задокументований інваріант, не дефект), тому
        # "рівно нуль .prerestore_*" — хибний критерій після кількох
        # прогонів на тому самому компоненті. Коректна перевірка rollback —
        # "жодного НОВОГО .prerestore_* понад ті, що вже існували ДО цієї
        # конкретної комбінації" (знімок від викликача).
        [hashtable]$PrerestoreDirectoriesBefore = @{}
    )

    $reasons = New-Object System.Collections.Generic.List[string]

    if ($Result.TimedOut) {
        $reasons.Add('дочірній процес не завершився за відведений таймаут')
    } elseif ($Result.ExitCode -ne $Combo.ExpectedExitCode) {
        $reasons.Add("exit code $($Result.ExitCode) не збігається з очікуваним $($Combo.ExpectedExitCode)")
    }

    switch ($Combo.AssertionKind) {
        'OutOfPlaceSuccess' {
            $targetCanary = Join-Path ([string]$Combo.Arguments.TargetPath) "$($Combo.AssertionComponent)\CANARY.txt"
            if (-not (Test-Path -LiteralPath $targetCanary -PathType Leaf)) {
                $reasons.Add("ціль не містить CANARY.txt: $targetCanary")
            } else {
                $actual = Get-Content -LiteralPath $targetCanary -Raw
                $expected = [string]$CanaryByGeneration[$Combo.ExpectedCanary]
                if ($actual -ne $expected) {
                    $reasons.Add("вміст CANARY.txt у цілі не відповідає очікуваній генерації ($($Combo.ExpectedCanary))")
                }
            }
        }
        'OutOfPlaceSuccessAll' {
            foreach ($component in @('MODEL', 'BLOG', 'BRAVOEXCH')) {
                $targetCanary = Join-Path ([string]$Combo.Arguments.TargetPath) "$component\CANARY.txt"
                if (-not (Test-Path -LiteralPath $targetCanary -PathType Leaf)) {
                    $reasons.Add("ціль $component не містить CANARY.txt")
                }
            }
        }
        'InPlaceSuccess' {
            $liveDirectory = [string]$FixtureConfig.SourceDirectories[$Combo.AssertionComponent]
            $prerestoreSiblings = @(Get-ChildItem -Path (Split-Path $liveDirectory -Parent) -Filter "$($Combo.AssertionComponent).prerestore_*" -Directory -ErrorAction SilentlyContinue)
            if ($prerestoreSiblings.Count -eq 0) {
                $reasons.Add("не знайдено .prerestore_* каталог для $($Combo.AssertionComponent)")
            }
            $liveCanary = Join-Path $liveDirectory 'CANARY.txt'
            if (-not (Test-Path -LiteralPath $liveCanary -PathType Leaf)) {
                $reasons.Add("live-каталог $($Combo.AssertionComponent) не містить CANARY.txt після відновлення")
            }
        }
        'InPlaceSuccessAll' {
            foreach ($component in @('MODEL', 'BLOG', 'BRAVOEXCH')) {
                $liveDirectory = [string]$FixtureConfig.SourceDirectories[$component]
                $prerestoreSiblings = @(Get-ChildItem -Path (Split-Path $liveDirectory -Parent) -Filter "$component.prerestore_*" -Directory -ErrorAction SilentlyContinue)
                if ($prerestoreSiblings.Count -eq 0) {
                    $reasons.Add("не знайдено .prerestore_* каталог для $component")
                }
            }
        }
        'InPlaceRollback' {
            $liveDirectory = [string]$FixtureConfig.SourceDirectories[$Combo.AssertionComponent]
            $liveCanary = Join-Path $liveDirectory 'CANARY.txt'
            $expected = [string]$CanaryByGeneration[$Combo.ExpectedCanary]
            if (-not (Test-Path -LiteralPath $liveCanary -PathType Leaf)) {
                $reasons.Add("live-каталог $($Combo.AssertionComponent) втратив CANARY.txt після rollback")
            } elseif ((Get-Content -LiteralPath $liveCanary -Raw) -ne $expected) {
                $reasons.Add("вміст live CANARY.txt змінився після rollback (мав лишитися оригінальним)")
            }
            $existingBefore = @($PrerestoreDirectoriesBefore[$Combo.AssertionComponent])
            $orphanPrerestore = @(Get-ChildItem -Path (Split-Path $liveDirectory -Parent) -Filter "$($Combo.AssertionComponent).prerestore_*" -Directory -ErrorAction SilentlyContinue |
                Where-Object { $existingBefore -notcontains $_.Name })
            if ($orphanPrerestore.Count -gt 0) {
                $reasons.Add("з'явився НОВИЙ .prerestore_* каталог після успішного rollback — rollback мав перейменувати назад")
            }
        }
        'InPlaceRollbackAll' {
            foreach ($component in @('MODEL', 'BLOG', 'BRAVOEXCH')) {
                $liveDirectory = [string]$FixtureConfig.SourceDirectories[$component]
                $liveCanary = Join-Path $liveDirectory 'CANARY.txt'
                $expected = [string]$CanaryByGeneration[$Combo.ExpectedCanary]
                if (-not (Test-Path -LiteralPath $liveCanary -PathType Leaf) -or (Get-Content -LiteralPath $liveCanary -Raw) -ne $expected) {
                    $reasons.Add("live-каталог $component не відкочений до оригінального вмісту")
                }
                $existingBefore = @($PrerestoreDirectoriesBefore[$component])
                $orphanPrerestore = @(Get-ChildItem -Path (Split-Path $liveDirectory -Parent) -Filter "$component.prerestore_*" -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $existingBefore -notcontains $_.Name })
                if ($orphanPrerestore.Count -gt 0) {
                    $reasons.Add("залишився .prerestore_* каталог для $component після cross-rollback")
                }
            }
        }
        'ListGenerationsNoMutation' {
            $stagingDirectory = Join-Path ([string]$FixtureConfig.BackupRoot) 'RESTORE_STAGING'
            if (Test-Path -LiteralPath $stagingDirectory -PathType Container) {
                $reasons.Add('-ListGenerations створив RESTORE_STAGING — очікувалась нульова файлова мутація')
            }
        }
        'PreExistingTargetUntouched' {
            if (-not (Test-Path -LiteralPath ([string]$Combo.SentinelPath) -PathType Leaf)) {
                $reasons.Add('sentinel-файл у наявній цілі зник — план мав відхилити запуск до будь-якого запису')
            }
        }
        'NoExtractionOccurred' {
            if (Test-Path -LiteralPath ([string]$Combo.SentinelPath) -PathType Leaf) {
                $reasons.Add('CANARY.txt зʼявився у цілі, хоча free-space preflight мав заблокувати запуск до екстракції')
            }
        }
        'NoAssertion' {
            # Лише exit code (уже перевірено вище) — конфігурація відхиляється
            # до будь-якої файлової мутації.
        }
    }

    # Спільна перевірка для кожної комбінації: lock-файл не утримується
    # одразу після завершення дочірнього процесу (не "відсутній" — файл
    # лишається як діагностика за задумом, розділ "Enter-/Exit-
    # BRAVODataRestoreOperationLock" — а саме "не відкритий ексклюзивно").
    $lockPath = [string]$FixtureConfig.LockPath
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        try {
            $probe = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $probe.Dispose()
        } catch {
            $reasons.Add("operation lock лишився утримуваним після завершення дочірнього процесу: $($_.Exception.Message)")
        }
    }

    return [pscustomobject]@{
        Passed = ($reasons.Count -eq 0)
        Reasons = $reasons.ToArray()
    }
}

function Write-BRAVODataRestoreMatrixSummary {
    # Фінальна PASS/FAIL-таблиця + агрегований exit code (0 — усі
    # комбінації відповідали очікуванню, 1 — інакше).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Results)

    $failedCount = 0
    Write-Host ''
    Write-Host '===== BRAVO_DATA_RESTORE_MATRIX_TEST — підсумок =====' -ForegroundColor Cyan
    foreach ($result in $Results) {
        if ($result.Passed) {
            Write-Host ("[PASS] {0} (exit {1})" -f $result.Name, $result.ExitCode) -ForegroundColor Green
        } else {
            $failedCount++
            Write-Host ("[FAIL] {0} (exit {1})" -f $result.Name, $result.ExitCode) -ForegroundColor Red
            foreach ($reason in $result.Reasons) {
                Write-Host ("       - {0}" -f $reason) -ForegroundColor Red
            }
        }
    }
    Write-Host ("Разом: {0} PASS, {1} FAIL з {2}" -f ($Results.Count - $failedCount), $failedCount, $Results.Count) -ForegroundColor Cyan
    if ($failedCount -gt 0) { return 1 }
    return 0
}

Export-ModuleMember -Function @(
    'New-BRAVODataRestoreMatrixFixtureConfig',
    'New-BRAVODataRestoreMatrixFixtureGeneration',
    'Invoke-BRAVODataRestoreMatrixCombo',
    'Get-BRAVODataRestoreMatrixComboDefinitions',
    'Assert-BRAVODataRestoreMatrixComboResult',
    'Write-BRAVODataRestoreMatrixSummary'
)
