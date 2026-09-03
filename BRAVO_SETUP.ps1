[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', 'CredentialComponent',
    Justification = 'Хибне спрацювання: $CredentialComponent — це ValidateSet-перемикач (яку групу credentials налаштовувати), не секрет.')]
[CmdletBinding()]
param(
    [string]$ConfigPath,

    [ValidateSet("Full", "Credentials", "Scheduler", "Test")]
    [string]$Action = "Full",

    [ValidateSet(
        "Required",
        "All",
        "SFTP",
        "SMB",
        "Slack",
        "Discord",
        "Archive",
        "Institution"
    )]
    [string]$CredentialComponent = "Required",

    [ValidateSet("Both", "ScheduledTaskAccount", "CurrentUser")]
    [string]$StoreFor = "Both",

    [switch]$ValidateOnly,
    [switch]$ConfirmDiscoveryBaseline,
    [switch]$SkipAccessTest,
    [switch]$SkipTestNotification,
    [switch]$NoElevation,
    [switch]$NoPause
)

$helperLoggingPath = Join-Path $PSScriptRoot "modules\BRAVO.HelperLogging\BRAVO.HelperLogging.psd1"
Import-Module -Name $helperLoggingPath -ErrorAction Stop
$null = Start-BRAVOHelperLog -ScriptPath $PSCommandPath -ConfigPath $ConfigPath

# Імпортується тут, а не після завантаження BRAVO.config: заголовок і
# РЕЗУЛЬТАТ мають намалюватись навіть тоді, коли Setup провалюється ще ДО
# конфігурації (catch-блок нижче).
$setupConsoleModulePath = Join-Path $PSScriptRoot "modules\BRAVO.Console\BRAVO.Console.psd1"
Import-Module -Name $setupConsoleModulePath -ErrorAction Stop

# Єдина точка налаштування BRAVO:
# 1. fail-closed preflight без production-операцій;
# 2. додавання/оновлення параметрів установи та секретів у Credential Manager;
# 3. перевірка читання записів для поточного користувача і task account;
# 4. перевірка/встановлення Планувальника;
# 5. read-only тестовий прогін і opt-in тестове сповіщення.

$ErrorActionPreference = "Stop"



function Wait-BRAVOSetupCompletion {
    if ($NoPause -or -not [Environment]::UserInteractive) {
        return
    }

    try {
        if ([Console]::IsInputRedirected) {
            return
        }
        [void](Read-Host "Натисніть Enter для завершення")
    } catch {
        # Фонові, перенаправлені або non-interactive запуски не повинні
        # завершуватися помилкою лише через відсутність консолі.
    }
}



function Invoke-ChildPowerShell {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments,
        [string]$StepName,
        [int]$Current,
        [int]$Total
    )

    # Дочірній процес стрімить власний повний вивід (заголовок/кроки/
    # РЕЗУЛЬТАТ, після міграції кожного з них — той самий каркас
    # BRAVO.Console) прямо в консоль без перехоплення — тому тут лише
    # заголовок кроку [N/M], а не Write-BRAVOStepResult з одним фінальним
    # OK/ERROR: це вимагало б ковтати діагностику дочірнього скрипта
    # (Credential Manager FOUND/MISSING, Dry Run PASS/WARN/FAIL/PLAN тощо),
    # яку оператор зараз бачить наживо.
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}" -f $Current, $Total, $StepName) -ForegroundColor Cyan
    $powerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
        throw "Windows PowerShell не знайдено: $powerShellPath"
    }
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Скрипт не знайдено: $ScriptPath"
    }

    $childArguments = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $ScriptPath
    ) + @($Arguments)
    & $powerShellPath @childArguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$StepName завершився з кодом $exitCode"
    }
}

function New-BRAVOManualLauncherContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EntryScriptPath,
        # P0 Configuration Foundation (PR C, Секція 7): AUTO ($ConfigPath
        # порожній/не передано) -> launcher НЕ вбудовує -ConfigPath, кожен
        # запуск сам виконує ту саму AUTO-резолюцію проти RuntimeRoot
        # (той самий контракт, що BRAVO_TASKS_INSTALL.ps1, Секція 6).
        # EXPLICIT -> точний шлях у .cmd.
        [string]$ConfigPath,
        [ValidateSet('-ForceRestore')][string[]]$Arguments = @(),
        [switch]$RequiresConfirmation
    )

    $pathsToValidate = @($EntryScriptPath)
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $pathsToValidate += $ConfigPath }
    foreach ($path in $pathsToValidate) {
        if (-not [IO.Path]::IsPathRooted($path) -or $path.Contains('"')) {
            throw "Некоректний шлях для manual launcher: $path"
        }
        if ($path -cmatch '[^\x00-\x7F]') {
            throw "Manual launcher не підтримує не-ASCII шлях: $path"
        }
    }

    $commandArguments = if ($Arguments.Count -gt 0) { ' ' + ($Arguments -join ' ') } else { '' }
    $lines = @(
        '@echo off',
        'setlocal'
    )
    if ($RequiresConfirmation) {
        $lines += @(
            'echo.',
            'echo WARNING: BRAVO Maintenance will run with FORCED RESTORE.',
            'echo This operation will perform restore regardless of the normal schedule.',
            'echo.',
            'choice /C YN /N /M "Continue? [Y/N]: "',
            'if errorlevel 2 exit /b 0',
            ''
        )
    }
    $configPathArgumentText = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        ''
    } else {
        ' -ConfigPath "{0}"' -f $ConfigPath
    }
    $lines += @(
        'set "BRAVO_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"',
        ('"%BRAVO_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"{1}{2}' -f $EntryScriptPath, $configPathArgumentText, $commandArguments),
        'exit /b %ERRORLEVEL%',
        ''
    )
    return ($lines -join "`r`n")
}

function Write-BRAVOManualLaunchers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        # P0 Configuration Foundation (PR C, Секція 7): AUTO -> $ConfigPath
        # порожній ($ConfigPathWasExplicit=$false); EXPLICIT -> точний шлях.
        [string]$ConfigPath,
        [bool]$ConfigPathWasExplicit
    )

    $pathsToValidate = @($BackupRoot, $RuntimeRoot)
    if ($ConfigPathWasExplicit) { $pathsToValidate += $ConfigPath }
    foreach ($path in $pathsToValidate) {
        if (-not [IO.Path]::IsPathRooted($path)) {
            throw "Очікувався абсолютний шлях для manual launcher: $path"
        }
    }

    $resolvedRuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
    $resolvedBackupRoot = [IO.Path]::GetFullPath($BackupRoot)
    # AUTO-режим не вимагає фізичного BRAVO.config для генерації launcher-ів
    # (built-in-only/no-primary — легітимний сценарій); launcher у цьому
    # режимі й не посилається на цей шлях. EXPLICIT — файл мав існувати ще
    # на кроці Get-SetupConfiguration (інакше Setup уже впав раніше).
    $launcherConfigPath = if ($ConfigPathWasExplicit) { [IO.Path]::GetFullPath($ConfigPath) } else { $null }

    $launchers = @(
        [pscustomobject]@{ Name = 'BRAVO_ARCHIV.cmd'; Script = 'BRAVO_ARCHIV.ps1'; Arguments = @(); RequiresConfirmation = $false },
        [pscustomobject]@{ Name = 'BRAVO_MAINTENANCE.cmd'; Script = 'BRAVO_MAINTENANCE.ps1'; Arguments = @(); RequiresConfirmation = $false },
        [pscustomobject]@{ Name = 'BRAVO_MAINTENANCE_FORCE_RESTORE.cmd'; Script = 'BRAVO_MAINTENANCE.ps1'; Arguments = @('-ForceRestore'); RequiresConfirmation = $true }
    )
    $launcherContents = @()
    foreach ($launcher in $launchers) {
        $entryScriptPath = Join-Path $resolvedRuntimeRoot $launcher.Script
        if (-not (Test-Path -LiteralPath $entryScriptPath -PathType Leaf)) {
            throw "Скрипт для manual launcher не знайдено: $entryScriptPath"
        }
        $launcherContents += [pscustomobject]@{
            Path = Join-Path $resolvedBackupRoot $launcher.Name
            Content = New-BRAVOManualLauncherContent `
                -EntryScriptPath $entryScriptPath `
                -ConfigPath $launcherConfigPath `
                -Arguments $launcher.Arguments `
                -RequiresConfirmation:$launcher.RequiresConfirmation
        }
    }

    [void][IO.Directory]::CreateDirectory($resolvedBackupRoot)
    $ascii = New-Object Text.ASCIIEncoding
    foreach ($launcher in $launcherContents) {
        [IO.File]::WriteAllText(
            $launcher.Path,
            $launcher.Content,
            $ascii
        )
    }
}

function Invoke-BRAVOManualLauncherSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$SetupConfiguration,
        [ValidateSet('Full', 'Credentials', 'Scheduler', 'Test')][string]$Action,
        [switch]$ValidateOnly
    )

    if ($ValidateOnly -or $Action -ne 'Full') {
        return
    }
    Write-BRAVOManualLaunchers `
        -BackupRoot $SetupConfiguration.BackupRoot `
        -RuntimeRoot $SetupConfiguration.Root `
        -ConfigPath $SetupConfiguration.ConfigPath `
        -ConfigPathWasExplicit $SetupConfiguration.ConfigPathWasExplicit
}

function Get-SetupConfiguration {
    param(
        [string]$Path,
        # P0 Configuration Foundation (PR C, Секція 7): зберігає operator
        # intent (той самий контракт, що решта entrypoint-ів) — AUTO
        # (оператор НЕ передав -ConfigPath) допускає відсутній файл
        # (built-in-only/legacy-primary+local synthetic-шлях);
        # EXPLICIT-відсутність лишається помилкою конфігурації.
        [bool]$ConfigPathWasExplicit
    )

    if ($ConfigPathWasExplicit -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Файл конфігурації не знайдено: $Path"
    }
    # GetFullPath (не Resolve-Path) — нормалізує шлях без вимоги існування
    # (AUTO-шлях може легітимно вказувати на файл, якого ще немає).
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $configRoot = Split-Path $resolvedPath -Parent
    $runtimeRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
    $configurationLoaderPath = Join-Path $runtimeRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration `
        -ConfigRoot $configRoot -ConfigPath $resolvedPath -RuntimeRoot $runtimeRoot `
        -ConfigPathWasExplicit:$ConfigPathWasExplicit

    $credentialScript = if ($null -ne $credentialSettings -and
        -not [string]::IsNullOrWhiteSpace([string]$credentialSettings.SetupScriptPath)) {
        [string]$credentialSettings.SetupScriptPath
    } else {
        Join-Path $runtimeRoot "BRAVO_CREDENTIALS_SETUP.ps1"
    }

    return [pscustomobject]@{
        ConfigPath = $resolvedPath
        ConfigRoot = $configRoot
        ConfigPathWasExplicit = $ConfigPathWasExplicit
        # Порожній масив у AUTO-режимі: жодна дочірня інвокація (child
        # PowerShell/UAC relaunch/manual launcher) НЕ повинна вбудовувати
        # -ConfigPath — кожен дочірній процес сам виконує ту саму
        # AUTO-резолюцію проти власного RuntimeRoot (той самий контракт,
        # що BRAVO_TASKS_INSTALL.ps1, Секція 6).
        ConfigPathArgument = if ($ConfigPathWasExplicit) { @('-ConfigPath', $resolvedPath) } else { @() }
        PrimaryConfigPresent = [bool]$global:BravoConfigurationMetadata.PrimaryConfigPresent
        Root = $runtimeRoot
        BackupRoot = [string]$global:backupRootPath
        CredentialScript = $credentialScript
        DryRunScript = Join-Path $runtimeRoot "BRAVO_DRY_RUN.ps1"
        # Task Installer/Diagnose — runtime-ресурси комплекту, тому беруться з
        # RuntimeRoot, а не з каталогу конфігурації (ConfigRoot може бути іншим
        # каталогом за -ConfigPath).
        TaskInstallScript = Join-Path $runtimeRoot "BRAVO_TASKS_INSTALL.ps1"
        TaskDiagnoseScript = Join-Path $runtimeRoot "BRAVO_TASKS_DIAGNOSE.ps1"
        NotificationsEnabled = (
            ([string]$bravoSettings.NotificationMode).Trim().ToLowerInvariant() -ne "none"
        )
        HasFullSchedulerConfiguration = (
            $null -ne $schedulerSettings -and
            $null -ne $schedulerSettings.Backup -and
            $null -ne $schedulerSettings.Maintenance -and
            $null -ne $schedulerSettings.Health
        )
    }
}

function Restart-SetupElevated {
    param($SetupConfiguration)

    $argumentParts = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (ConvertTo-BRAVOProcessArgument $PSCommandPath)
    )
    # P0 Configuration Foundation (PR C, Секція 7): зберігаємо AUTO/EXPLICIT
    # намір при UAC relaunch — той самий контракт, що BRAVO_TASKS_INSTALL.ps1.
    if ($SetupConfiguration.ConfigPathWasExplicit) {
        $argumentParts += "-ConfigPath"
        $argumentParts += (ConvertTo-BRAVOProcessArgument $SetupConfiguration.ConfigPath)
    }
    $argumentParts += @(
        "-Action",
        $Action,
        "-StoreFor",
        $StoreFor,
        "-CredentialComponent"
    )
    $argumentParts += $CredentialComponent
    if ($ValidateOnly) {
        $argumentParts += "-ValidateOnly"
    }
    if ($ConfirmDiscoveryBaseline) {
        $argumentParts += "-ConfirmDiscoveryBaseline"
    }
    if ($SkipAccessTest) {
        $argumentParts += "-SkipAccessTest"
    }
    if ($SkipTestNotification) {
        $argumentParts += "-SkipTestNotification"
    }
    if ($NoPause) {
        $argumentParts += "-NoPause"
    }
    $argumentParts += "-NoElevation"

    $powerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $process = Start-Process `
        -FilePath $powerShellPath `
        -ArgumentList ($argumentParts -join " ") `
        -Verb RunAs `
        -Wait `
        -PassThru `
        -WindowStyle Normal
    Complete-BRAVOHelperLog -ExitCode $process.ExitCode
}

try {
    $scriptDirectory = if ($PSCommandPath) {
        Split-Path $PSCommandPath -Parent
    } else {
        [Environment]::CurrentDirectory
    }
    Import-Module -Name (Join-Path $scriptDirectory 'modules\BRAVO.System\BRAVO.System.psd1') -ErrorAction Stop
    # P0 Configuration Foundation (PR C, Секція 7): intent обчислюється ДО
    # auto-дефолту (той самий контракт, що решта entrypoint-ів) — інакше
    # ця перевірка після мутації $ConfigPath завжди дала б $true.
    $configPathWasExplicit = $PSBoundParameters.ContainsKey('ConfigPath') -and
        -not [string]::IsNullOrWhiteSpace($ConfigPath)
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $scriptDirectory "BRAVO.config"
    }
    $setup = Get-SetupConfiguration -Path $ConfigPath -ConfigPathWasExplicit $configPathWasExplicit

    $credentialWorkRequested = $Action -in @("Full", "Credentials")
    $schedulerWorkRequested = $Action -in @("Full", "Scheduler")
    # ValidateOnly виконує лише read-only перевірки й не повинен відкривати UAC.
    $requiresAdministrator = (-not $ValidateOnly) -and (
        $schedulerWorkRequested -or
        ($credentialWorkRequested -and $StoreFor -in @("Both", "ScheduledTaskAccount"))
    )
    if ($requiresAdministrator -and -not (Test-IsAdministrator)) {
        if ($NoElevation) {
            throw "потрібні права адміністратора, але автоматичне підвищення вимкнено"
        }
        Write-Host "Для Credential Manager task account і Планувальника потрібні права адміністратора. Запит UAC..." `
            -ForegroundColor Yellow
        Restart-SetupElevated -SetupConfiguration $setup
    }

    Initialize-BRAVOConsole
    Initialize-BRAVOProgress -Enabled $false
    Write-BRAVOHeader `
        -Title ("BRAVO Setup {0}" -f $global:ScriptVersion) `
        -Institution ([string]$bravoSettings.InstitutionName) `
        -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
        -Mode "$Action$(if ($ValidateOnly) { ' / VALIDATE-ONLY' } else { '' })"
    Write-BRAVOResultField -Label 'Config' -Value $setup.ConfigPath
    if ($Action -eq 'Full' -and -not $ValidateOnly) {
        Invoke-BRAVOManualLauncherSetup `
            -SetupConfiguration $setup `
            -Action $Action `
            -ValidateOnly:$ValidateOnly
    }

    # Захист State-кореня (%ProgramData%\BRAVO\State): ownership-маркери в
    # ньому — вхід для привілейованих дій SYSTEM-Health (Start-Service за
    # quiescence-маркером), тому запис туди мають лише SYSTEM і
    # Administrators. З адмін-правами невідповідні ACL зміцнюються; у
    # ValidateOnly/неелевованому прогоні — лише перевірка зі звітом.
    $stateRootProtection = if ((Test-IsAdministrator) -and -not $ValidateOnly) {
        Protect-BRAVOMachineStateRoot
    } else {
        Protect-BRAVOMachineStateRoot -CheckOnly
    }
    if ($stateRootProtection.Applied) {
        Write-BRAVOResultField -Label 'State ACL' -Value "зміцнено: $($stateRootProtection.Path)" -Color ([ConsoleColor]::Green)
    } elseif ($stateRootProtection.Compliant) {
        Write-BRAVOResultField -Label 'State ACL' -Value "OK: $($stateRootProtection.Path)"
    } else {
        Write-BRAVOResultField -Label 'State ACL' -Value "НЕВІДПОВІДНІСТЬ: $($stateRootProtection.Path)" -Color ([ConsoleColor]::Yellow)
        foreach ($stateRootIssue in @($stateRootProtection.Issues)) {
            Write-Host "  - $stateRootIssue" -ForegroundColor Yellow
        }
        Write-Host "  Зміцнення виконає повний запуск BRAVO_SETUP з правами адміністратора." -ForegroundColor Yellow
    }

    # Discovery джерел (CLAUDE_CODE_TZ_ARCHIV_LIMS_MONOLITH.md): показуємо
    # завжди, це лише read-only читання вже обчисленого
    # $global:bravoDiscoveryResult з BRAVO.config — жодних нових операцій.
    if ($null -ne $global:bravoDiscoveryResult) {
        Write-BRAVOResultBlankLine
        Write-BRAVOSeparator
        Write-Host ' DISCOVERY'
        Write-BRAVOSeparator
        Write-BRAVOResultField -Label 'BRAVO_ROOT' -Value "$($bravoDiscoveryResult.BRAVO_ROOT) ($($bravoDiscoveryResult.Reasons.BravoRoot))"
        Write-BRAVOResultField -Label 'bravo.ini' -Value "$(if ([string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.BravoIniPath)) { 'не знайдено' } else { [string]$bravoDiscoveryResult.BravoIniPath }) ($($bravoDiscoveryResult.Reasons.BravoIniPath))"
        Write-BRAVOResultField -Label 'MODEL' -Value "$($bravoDiscoveryResult.MODEL_SOURCE) ($($bravoDiscoveryResult.Reasons.MODEL))"
        Write-BRAVOResultField -Label 'BLOG' -Value "$($bravoDiscoveryResult.BLOG_SOURCE) ($($bravoDiscoveryResult.Reasons.BLOG))"
        Write-BRAVOResultField -Label 'BRAVOEXCH' -Value "$($bravoDiscoveryResult.BRAVOEXCH_SOURCE) ($($bravoDiscoveryResult.Reasons.BRAVOEXCH))"
        Write-BRAVOResultField -Label 'BAZA_APP' -Value "$($bravoDiscoveryResult.BAZA_APP) ($($bravoDiscoveryResult.Reasons.BAZA_APP))"
        Write-BRAVOResultField -Label 'WEB_ROOT' -Value "$(if ([string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.WEB_ROOT)) { 'не визначено' } else { [string]$bravoDiscoveryResult.WEB_ROOT }) ($($bravoDiscoveryResult.Reasons.WebRoot))"
        Write-BRAVOResultField -Label 'BAZA_WWW' -Value "$(if ([string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.BAZA_WWW)) { 'не визначено' } else { [string]$bravoDiscoveryResult.BAZA_WWW }) ($($bravoDiscoveryResult.Reasons.BAZA_WWW))"
        if ($bravoDiscoveryResult.Services.Count -gt 0) {
            Write-BRAVOResultField -Label 'Знайдені служби' -Value ($($bravoDiscoveryResult.Services | ForEach-Object { "$($_.Name) [$($_.State)]" }) -join ', ')
        } else {
            Write-BRAVOResultField -Label 'Знайдені служби' -Value 'жодної (доступні лише canonical discovery values або explicit override)'
        }
        if ($bravoDiscoveryResult.Overrides.Count -gt 0) {
            Write-Host "Явні override з discoverySettings: $($bravoDiscoveryResult.Overrides.Keys -join ', ')"
        }
        if ($bravoDiscoveryResult.PSObject.Properties['Ambiguous'] -and
            (([bool]$bravoDiscoveryResult.Ambiguous['BravoRoot']) -or ([bool]$bravoDiscoveryResult.Ambiguous['WebRoot']))) {
            $ambiguousFieldNames = New-Object System.Collections.Generic.List[string]
            if ([bool]$bravoDiscoveryResult.Ambiguous['BravoRoot']) { $ambiguousFieldNames.Add('BRAVO_ROOT') }
            if ([bool]$bravoDiscoveryResult.Ambiguous['WebRoot']) { $ambiguousFieldNames.Add('WEB_ROOT') }
            Write-Host "УВАГА: знайдено кілька служб-кандидатів для $($ambiguousFieldNames -join ' і '); обрано першу знайдену — перевірте вручну." -ForegroundColor Yellow
        }

        # AUD-007 (аудит P1.1/P1.2): порівняння з останнім підтвердженим
        # baseline. Це лише read-only перевірка дрейфу — не блокує сама
        # собою; критичність (Fail vs Warn) лишається за адміністратором,
        # який бачить попередження й вирішує.
        $discoveryBaselinePath = Join-Path $PSScriptRoot "LOGS\DISCOVERY_BASELINE.json"
        $discoveryDrift = @(Compare-BRAVODiscoveryBaseline `
            -DiscoveryResult $bravoDiscoveryResult `
            -BaselinePath $discoveryBaselinePath)
        if ($discoveryDrift.Count -gt 0) {
            Write-Host "УВАГА: виявлено дрейф джерел відносно збереженого baseline:" -ForegroundColor Yellow
            foreach ($driftMessage in $discoveryDrift) {
                Write-Host "  - $driftMessage" -ForegroundColor Yellow
            }
        } elseif (Test-Path -LiteralPath $discoveryBaselinePath -PathType Leaf) {
            Write-Host "Дрейфу джерел відносно збереженого baseline не виявлено."
        } else {
            Write-Host "Baseline discovery ще не збережено (перший запуск або ще не підтверджено)."
        }

        if ($ConfirmDiscoveryBaseline) {
            Save-BRAVODiscoveryBaseline `
                -DiscoveryResult $bravoDiscoveryResult `
                -BaselinePath $discoveryBaselinePath
            Write-Host "Discovery baseline підтверджено й збережено: $discoveryBaselinePath" -ForegroundColor Green
        }

        if ($ValidateOnly) {
            $discoveryValidationErrors = @(Test-BRAVODiscoveryResult `
                -DiscoveryResult $bravoDiscoveryResult `
                -EnabledComponents @{
                    MODEL = [bool]$componentSettings.Archive.MODEL
                    BLOG = [bool]$componentSettings.Archive.BLOG
                    BRAVOEXCH = [bool]$componentSettings.Archive.BRAVOEXCH
                    BAZA_APP = ([bool]$componentSettings.Synchronization.BAZA_APP_LOCAL -or [bool]$componentSettings.Synchronization.BAZA_APP_SFTP)
                    BAZA_WWW = ([bool]$componentSettings.Synchronization.BAZA_WWW_SFTP -or [bool]$componentSettings.Synchronization.BAZA_WWW_LOCAL)
                } `
                -DestinationPaths @{
                    MODEL = $archiveDirs.Model
                    BLOG = $archiveDirs.Blog
                    BRAVOEXCH = $archiveDirs.BravoExch
                    BAZA_APP = $bazaAppPaths.Destination
                    BAZA_WWW = $bazaWWWPaths.Destination
                })
            if ($discoveryValidationErrors.Count -gt 0) {
                Write-Host "Результат перевірки discovery: ПОМИЛКИ" -ForegroundColor Red
                foreach ($validationError in $discoveryValidationErrors) {
                    Write-Host "  - $validationError" -ForegroundColor Red
                }
            } else {
                Write-Host "Результат перевірки discovery: OK" -ForegroundColor Green
            }
        }
        Write-BRAVOSeparator
    }

    # Preflight не читає секрети й ніколи не робить мережеві або production-операції.
    Invoke-ChildPowerShell `
        -ScriptPath $setup.DryRunScript `
        -Arguments (@($setup.ConfigPathArgument) + @("-SkipCredentials")) `
        -StepName "Локальний preflight / симуляція" `
        -Current 1 -Total 5

    if ($credentialWorkRequested) {
        if (-not $ValidateOnly) {
            $credentialArguments = @($setup.ConfigPathArgument) + @(
                "-Action", "Ensure",
                "-StoreFor", $StoreFor,
                "-Component"
            ) + @($CredentialComponent)
            # Крок вводу облікових даних — єдине місце, де на екрані
            # з'являються значення, які оператор набирає. Наш transcript
            # захоплює стрім дитини (у helper-лозі BRAVO_SETUP видно вивід
            # BRAVO_DRY_RUN), тому паузи лише в дочірньому процесі замало:
            # без цієї паузи значення осіли б у батьківському лозі.
            #
            # Дитина показує ввід відкрито ЛИШЕ побачивши цю змінну
            # середовища разом із власною canary-перевіркою — тобто рішення
            # fail-closed з обох боків.
            $parentLogSuspended = Suspend-BRAVOHelperLog
            if ($parentLogSuspended) {
                $env:BRAVO_PARENT_LOG_SUSPENDED = '1'
            }
            try {
                Invoke-ChildPowerShell `
                    -ScriptPath $setup.CredentialScript `
                    -Arguments $credentialArguments `
                    -StepName "Додавання або оновлення Credential Manager" `
                    -Current 2 -Total 5
            } finally {
                # finally обов'язковий: інакше помилка дочірнього процесу
                # лишила б журнал BRAVO_SETUP вимкненим до кінця роботи.
                $env:BRAVO_PARENT_LOG_SUSPENDED = $null
                if ($parentLogSuspended) {
                    [void](Resume-BRAVOHelperLog)
                }
            }
        } else {
            Write-Host ''
            Write-Host '[2/5] Credential Manager' -ForegroundColor Cyan
            Write-Host "[ПЕРЕВІРКА] Записи не створюються і не змінюються." -ForegroundColor Yellow
        }
    }

    # У режимах Full/Credentials перевіряється запитаний scope. У Test/Scheduler
    # перевіряємо стандартний безпечний набір Required для обох облікових записів.
    if ($Action -in @("Full", "Credentials", "Scheduler", "Test")) {
        $testComponents = if ($credentialWorkRequested) {
            @($CredentialComponent)
        } else {
            @("Required")
        }
        $testStore = if ($credentialWorkRequested) { $StoreFor } else { "Both" }
        $credentialTestArguments = @($setup.ConfigPathArgument) + @(
            "-Action", "Test",
            "-StoreFor", $testStore,
            "-Component"
        ) + $testComponents
        Invoke-ChildPowerShell `
            -ScriptPath $setup.CredentialScript `
            -Arguments $credentialTestArguments `
            -StepName "Перевірка читання Credential Manager" `
            -Current 3 -Total 5
    }

    if ($schedulerWorkRequested -or $Action -eq "Test") {
        if (-not $setup.HasFullSchedulerConfiguration) {
            if ($schedulerWorkRequested) {
                throw "цей config не містить повної schedulerSettings для BRAVO_TASKS_INSTALL.ps1"
            }
            Write-Warning "Перевірку Планувальника пропущено: config не містить повної schedulerSettings."
        } else {
            Invoke-ChildPowerShell `
                -ScriptPath $setup.TaskInstallScript `
                -Arguments (@($setup.ConfigPathArgument) + @("-ValidateOnly")) `
                -StepName "Валідація Планувальника завдань" `
                -Current 4 -Total 5

            if ($schedulerWorkRequested -and -not $ValidateOnly) {
                Invoke-ChildPowerShell `
                    -ScriptPath $setup.TaskInstallScript `
                    -Arguments @($setup.ConfigPathArgument) `
                    -StepName "Встановлення/оновлення Планувальника завдань" `
                    -Current 4 -Total 5
            }
        }
    }

    $dryRunArguments = @($setup.ConfigPathArgument)
    if (-not $SkipAccessTest) {
        $dryRunArguments += "-TestAccess"
    }
    if (-not $ValidateOnly -and
        -not $SkipAccessTest -and
        -not $SkipTestNotification -and
        $setup.NotificationsEnabled) {
        $dryRunArguments += "-SendTestNotification"
    }
    if ($schedulerWorkRequested -and
        -not $ValidateOnly -and
        $setup.HasFullSchedulerConfiguration) {
        Invoke-ChildPowerShell `
            -ScriptPath $setup.TaskDiagnoseScript `
            -Arguments $dryRunArguments `
            -StepName "SYSTEM dry-run і діагностика Планувальника" `
            -Current 5 -Total 5
    } else {
        if ($schedulerWorkRequested -and
            -not $ValidateOnly -and
            $setup.HasFullSchedulerConfiguration) {
            $dryRunArguments += "-RequireScheduledTasks"
        }
        Invoke-ChildPowerShell `
            -ScriptPath $setup.DryRunScript `
            -Arguments $dryRunArguments `
            -StepName "Фінальний безпечний тестовий прогін" `
            -Current 5 -Total 5
    }

    Write-BRAVOResultBlankLine
    Write-BRAVOSeparator
    Write-Host ' РЕЗУЛЬТАТ'
    Write-BRAVOSeparator
    Write-BRAVOResultField -Label 'Статус' -Value 'НАЛАШТУВАННЯ ЗАВЕРШЕНО' -Color ([ConsoleColor]::Green)
    Write-BRAVOResultBlankLine
    Write-BRAVOResultNote -Text $(if ($ValidateOnly) {
        'Секрети й завдання не змінювалися; production-операції не запускалися.'
    } else {
        'Production-операції архівації/копіювання/видалення не запускалися.'
    })
    Write-BRAVOSeparator
    Wait-BRAVOSetupCompletion
    Complete-BRAVOHelperLog -ExitCode 0
} catch {
    Write-BRAVOResultBlankLine
    Write-BRAVOSeparator
    Write-Host ' РЕЗУЛЬТАТ'
    Write-BRAVOSeparator
    Write-BRAVOResultField -Label 'Статус' -Value 'ПОМИЛКА' -Color ([ConsoleColor]::Red)
    Write-BRAVOResultField -Label 'Причина' -Value $_.Exception.Message
    Write-BRAVOResultBlankLine
    Write-BRAVOResultNote -Text 'Подальші етапи зупинено (fail-closed).'
    Write-BRAVOSeparator
    Wait-BRAVOSetupCompletion
    Complete-BRAVOHelperLog -ExitCode 1
}
