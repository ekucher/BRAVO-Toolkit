# Домен-фрагмент self-test: цикл служб нічного Maintenance (#314, хвиля 2) —
# «зупинка служб -> обробка журналів (trace BRAVO / exchangAPI / Apache і
# BRAVO Web) -> запуск у канонічному порядку BRAVO -> exchangAPI -> BRAVO Web» —
# і автоматичне відновлення впалих служб (#314, хвиля 3: FR-2 нічний
# Maintenance піднімає впалі служби, FR-5 облік спроб і паузи, FR-6
# сповіщення; тести ТЗ §6 п. 3, 4, 7, 10).
#
# Характеризаційні тести: фіксують ПОТОЧНУ поведінку циклу (які служби
# зупиняються й запускаються, порядок, що відбувається з журналами,
# ownership-маркер, restartSuppressed, гейт цілісності моделі,
# -RunMissedRestoreOnly, -ForceRestore, завершення Bis перед зупинкою BRAVO)
# через СПРАВЖНЮ оркестрацію Maintenance. Вони однаково проходять до і
# після винесення циклу з BRAVO.Maintenance.Runtime.ps1 у функції
# BRAVO.Maintenance.ServiceCycle.ps1: зміна будь-якого рядка журналу,
# порядку чи складу подій циклу — свідома зміна поведінки, яку мусить
# супроводжувати зміна очікувань тут (хвилі 3–4 #314). Хвиля 3 (FR-2)
# так свідомо змінила сценарії зі службами, зупиненими до прогону: такі
# служби (не Disabled, не під маркером) тепер входять у маркер і
# запускаються, а рядок «BRAVO Trace після запуску служби» пишеться лише
# тоді, коли службу BRAVO справді запускали.
#
# Проба та сама, що в Maintenance/Orchestration* кореневого файлу (стаби,
# seed, збирач runtime з AST) — тексти беруться з BRAVO_SELF_TEST.ps1 за
# AST, без копії. Поверх них фрагмент додає стаби, що записують у журнал
# проби КОЖЕН рядок Write-Log, завершення Bis і ротацію кожного журналу,
# а scenario-seed.ps1 кожного сценарію задає стан поза наборами за іменем.
#
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition,
# Get-BRAVOSelfTestParsedFile. Усе — у дочірньому scope (& { }): змінні
# фрагмента не потрапляють у script-scope самотесту (#163).

& {
    $serviceRecoveryRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_SERVICE_RECOVERY_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($serviceRecoveryRoot)

        # Тексти проби оркестрації — з кореневого файлу за AST (одне джерело).
        $serviceRecoveryRootAst = (Get-BRAVOSelfTestParsedFile -Path (Join-Path $root 'BRAVO_SELF_TEST.ps1')).Ast
        $serviceRecoveryProbeTexts = @{}
        foreach ($serviceRecoveryAssignment in @($serviceRecoveryRootAst.FindAll({
                        param($node)
                        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                        @('maintenanceOrchestrationStubs', 'maintenanceOrchestrationSeed', 'maintenanceOrchestrationProbeScript') -contains $node.Left.VariablePath.UserPath
                    }, $true))) {
            $serviceRecoveryValue = $serviceRecoveryAssignment.Right
            if ($serviceRecoveryValue -is [Management.Automation.Language.CommandExpressionAst] -and
                $serviceRecoveryValue.Expression -is [Management.Automation.Language.StringConstantExpressionAst]) {
                $serviceRecoveryProbeTexts[$serviceRecoveryAssignment.Left.VariablePath.UserPath] = [string]$serviceRecoveryValue.Expression.Value
            }
        }

        # Додаткові стаби (визначені ПІСЛЯ стабів проби — перекривають їх):
        # повний журнал Write-Log (з тими самими побічними ефектами, що й у
        # стабі проби: лічильник WARNING і пауза перед зупинкою), Bis як
        # сторонній процес, що тримає модель, і ротація кожного журналу.
        $serviceRecoveryExtraStubs = @'
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO', [int]$SeparatorLength = 100, [switch]$NoTimestamp, [switch]$NoConsole, [switch]$Environmental)
    if ($Level -eq 'WARNING' -and -not $Environmental) { $script:BRAVOWarningCount++ }
    Add-ProbeEvent ("LOG-{0} {1}" -f $Level, $Message)
    if ($null -ne $script:ProbePauseBeforeStop) {
        foreach ($probePauseName in @($script:ProbePauseBeforeStop.Keys)) {
            if ($Message -like "Зупинка служби $probePauseName...") {
                Invoke-ProbeLateStart -Changes $script:ProbePauseBeforeStop
                break
            }
        }
    }
}
function Get-Process {
    param($Name, $ErrorAction)
    if (@($script:ProbeStrayProcesses) -contains [string]$Name) {
        Add-ProbeEvent ("GET-PROCESS " + [string]$Name)
        return [pscustomobject]@{ Name = [string]$Name }
    }
}
function Stop-Process {
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force)
    process { Add-ProbeEvent ("STOP-PROCESS {0} Force={1}" -f [string]$InputObject.Name, [bool]$Force) }
}
function Invoke-BRAVOTraceRotation {
    param($Sources, $DestinationDirectory, $RetryCount, $RetryDelaySeconds, $Logger)
    Add-ProbeEvent 'TRACE-ROTATION'
    return [pscustomobject]@{ Moved = 2; Errors = 0 }
}
function Invoke-BRAVOExchangeApiLogRotation {
    param($SourceDirectory, $DestinationDirectory, $Patterns, $RetryCount, $RetryDelaySeconds, $Logger)
    Add-ProbeEvent 'EXCHANGE-ROTATION'
    return [pscustomobject]@{ Found = 3; Moved = 3; Errors = 0 }
}
function Invoke-BRAVOApacheLogRotation {
    param($SourceDirectory, $DestinationDirectory, $Filter, $RetryCount, $RetryDelaySeconds, $Logger)
    Add-ProbeEvent 'APACHE-ROTATION'
    return [pscustomobject]@{ Moved = 1; Errors = 0 }
}
function Invoke-BRAVOWebApplicationLogRotation {
    param($SourceDirectory, $DestinationDirectory, $Filter, $RetryCount, $RetryDelaySeconds, $Logger)
    Add-ProbeEvent 'WEBAPP-ROTATION'
    return [pscustomobject]@{ Moved = 1; Errors = 0 }
}
# #314 FR-2: служба, яка не стартує (стан лишається Stopped, справжній
# Invoke-ServiceStateChange дочекається таймауту).
function Start-Service {
    param([string]$Name, $WarningAction, $ErrorAction, $ErrorVariable)
    if (@($script:ProbeStartFailures) -contains $Name) { Add-ProbeEvent "START-FAIL $Name"; return }
    Add-ProbeEvent "START $Name"
    $script:ProbeServices[$Name] = 'Running'
}
# #314 FR-5: state-файл обліку спроб — у каталозі сценарію (BRAVO.System у
# пробі не імпортовано: шлях, захист каталогу й атомарний запис — стаби).
function Get-BRAVOServiceRecoveryStatePath { return $script:ProbeRecoveryStatePath }
function Protect-BRAVOMachineStateRoot { param([switch]$CheckOnly, [string]$Path) return [pscustomobject]@{ Path = $Path; Compliant = $true; Applied = $false; Issues = @() } }
function Write-BRAVOStateFileAtomic {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
    Add-ProbeEvent 'RECOVERY-STATE-WRITE'
}
# #314 FR-6: маршрут і доставка сповіщень (BRAVO.Notifications у пробі не
# імпортовано): режими none / errors_only / all — як у Resolve-BRAVONotificationRoute.
function Resolve-BRAVONotificationRoute {
    param($Severity, $NotificationMode, $RoutingTable)
    if ($NotificationMode -eq 'none' -or ($NotificationMode -eq 'errors_only' -and $Severity -eq 'SUCCESS')) { return 'none' }
    if ($Severity -eq 'SUCCESS') { return 'general' }
    return 'alerts'
}
function New-MaintenanceNotificationMessage {
    param($Title, $TitleEmoji, $Duration, $DurationLabel, $StatusLines, $Details, $LogPath, $Severity)
    return ('{0}|{1}' -f $Severity, $Title)
}
function Invoke-NotificationWebhook {
    param([string]$Message, [string]$WebhookUrl)
    Add-ProbeEvent ('NOTIFY {0} -> {1}' -f $Message, $WebhookUrl)
}
'@
        # Спільний seed: компонент BRAVO Web з Apache увімкнено (журнали
        # Apache і застосунку BRAVO Web теж обробляються), Bis не запущено.
        $serviceRecoveryExtraSeed = @'
$script:ProbeStrayProcesses = @()
$ApacheEnabled = $true
$BRAVOWEB_LOG_DIR = Join-Path $probeWorkRoot 'system\BravoWeb'
$APACHE_LOG_DIR = Join-Path $probeWorkRoot 'system\BravoWeb\Apache'
$APACHE_DAILY_LOG_DIR = Join-Path $probeWorkRoot 'system\BravoWeb\Apache\daily'
$BRAVOWEB_APP_LOG_DIR = Join-Path $probeWorkRoot 'system\BravoWeb\Application'
$BRAVOWEB_APP_DAILY_LOG_DIR = Join-Path $probeWorkRoot 'system\BravoWeb\Application\daily'
$APACHE_LOGS_DIR = Join-Path $probeWorkRoot 'apache\logs'
$APACHE_LOG_FILTER = '*.log'
$WWW_LOGS_DIR = Join-Path $probeWorkRoot 'www\log'
$BRAVOWEB_APP_LOG_FILTER = '*.log'
# #314 FR-2: справжня класифікація (стаб Get-BRAVOManagedServiceCondition
# проби): керовані служби мають тип Automatic/Manual, тож зупинена служба
# поза маркером — впала (Failed).
$script:ProbeConditionStartModes = @{ 'BRAVO' = 'Automatic'; 'exchangAPI' = 'Automatic'; 'BravoWeb' = 'Manual' }
$script:ProbeExitCodes = @{}
$script:ProbeStartFailures = @()
$script:ProbeRecoveryStatePath = Join-Path (Join-Path $probeWorkRoot 'state') 'BRAVO_SERVICE_RECOVERY_STATE.json'
'@

        # Реставрація з -ForceRestore (як у сценаріях StartMode* кореневої
        # проби): before-архів і bravocmd — стаби, перша ж native-операція
        # повертає 2, тож деструктивна фаза не починається.
        $serviceRecoveryForceRestoreSeed = @(
            '$shouldRestore = $true',
            '$ForceRestore = $true',
            '$restoreReason = ''self-test''',
            '$script:BRAVOMaintenanceRestoreStepEnabled = $true',
            '$ARCH_NAME1 = ''self-test_before.mdz''',
            '$SIZES_FILE = Join-Path $probeWorkRoot ''logs\file_sizes_before.csv''',
            '$arcCommonParams = @()',
            '$MODEL_PROJECT_PATH = $MODEL_PATH',
            '$MODEL_NAME = ''self-test''',
            '$MAIN_MODEL_FILE = ''self-test.md''',
            '$BRAVOCMD_PATH = Join-Path $probeWorkRoot ''lims\bravocmd.exe''',
            '[void][IO.Directory]::CreateDirectory($MODEL_PATH)',
            '[IO.File]::WriteAllText((Join-Path $MODEL_PATH ''self-test.md''), ''self-test'')',
            '[void][IO.Directory]::CreateDirectory($LOG_DIR)',
            '[void][IO.Directory]::CreateDirectory($ARC_DIR)'
        )

        # Сценарії: ім'я -> рядки scenario-seed.ps1 (виконуються після seed проби).
        $serviceRecoveryScenarios = [ordered]@{
            # Усі служби працюють, Bis відкрито: повний цикл.
            'SRCanonicalCycle' = @(
                '$script:ProbeStrayProcesses = @(''Bis'')'
            )
            # BRAVO Web не зупиняється: її журнали не чіпаються, решта циклу триває.
            'SRWebStopFailure' = @(
                '$script:ProbeStopFailures = @(''BravoWeb'')'
            )
            # #314 FR-2: exchangAPI впала до прогону (ExitCode 1067): входить у
            # маркер з наміром перезапуску, її журнали обробляються, запуск — у
            # канонічному порядку; спроба рахується в state-файлі.
            'SRExchangeStoppedBeforeRun' = @(
                '$script:ProbeServices = @{ ''BRAVO'' = ''Running''; ''exchangAPI'' = ''Stopped''; ''BravoWeb'' = ''Running'' }',
                '$script:ProbeExitCodes = @{ ''exchangAPI'' = 1067 }'
            )
            # Цілісність моделі не встановлено: жодна служба не запускається,
            # маркер лишається.
            'SRIntegrityGateClosed' = @(
                '$script:modelIntegrityEstablished = $false',
                '$ARCH_NAME1 = ''self-test_before.mdz'''
            )
            # Маркер аварійно перерваного прогону з наміром перезапуску BRAVO:
            # без restartSuppressed намір успадковується (BRAVO стартує).
            'SRInheritedRestartIntent' = @(
                '$script:ProbeServices = @{ ''BRAVO'' = ''Stopped''; ''exchangAPI'' = ''Stopped''; ''BravoWeb'' = ''Stopped'' }',
                '$script:ProbeForeignRestartIntent = @(''BRAVO'')'
            )
            # Той самий маркер з restartSuppressed: намір НЕ успадковується.
            'SRSuppressedRestartIntent' = @(
                '$script:ProbeServices = @{ ''BRAVO'' = ''Stopped''; ''exchangAPI'' = ''Stopped''; ''BravoWeb'' = ''Stopped'' }',
                '$script:ProbeForeignRestartIntent = @(''BRAVO'')',
                '$script:ProbeForeignRestartSuppressed = $true'
            )
            # -RunMissedRestoreOnly при працюючих службах: Recovery не зупиняє
            # служби (exit 20, жодної зупинки чи запуску).
            'SRRunMissedRestoreOnlyServicesRunning' = @(
                '$RunMissedRestoreOnly = $true',
                '$missedDailyWork = $true',
                '$missedRestoreDue = $false'
            )
            # Рев'ю PR #432 (B-P3-5): -RunMissedRestoreOnly із пропущеною роботою,
            # а всі служби зупинені — служби лишаються зупиненими («без змін»).
            'SRRunMissedRestoreOnlyServicesStopped' = @(
                '$RunMissedRestoreOnly = $true',
                '$missedDailyWork = $true',
                '$missedRestoreDue = $false',
                '$script:ProbeServices = @{ ''BRAVO'' = ''Stopped''; ''exchangAPI'' = ''Stopped''; ''BravoWeb'' = ''Stopped'' }'
            )
            # -ForceRestore при Disabled BRAVO (#321): службу BRAVO не чіпають,
            # але Bis завершується; exchangAPI і BRAVO Web проходять цикл.
            'SRForceRestoreDisabledBravo' = @($serviceRecoveryForceRestoreSeed + @(
                '$script:ProbeStrayProcesses = @(''Bis'')',
                '$BravoMaintenanceEnabled = $false',
                '$BravoServiceDisabledBySystem = $true',
                '$restoreOnDisabledBravo = $true',
                '$script:ProbeServices = @{ ''BRAVO'' = ''Stopped''; ''exchangAPI'' = ''Running''; ''BravoWeb'' = ''Running'' }'
            ))
            # -ForceRestore, exchangAPI зупинена до прогону: #314 FR-2 — після
            # реставрації її теж запускають (раніше лишалась зупиненою).
            'SRForceRestoreExchangeStoppedBeforeRun' = @($serviceRecoveryForceRestoreSeed + @(
                '$script:ProbeServices = @{ ''BRAVO'' = ''Running''; ''exchangAPI'' = ''Stopped''; ''BravoWeb'' = ''Running'' }'
            ))
            # -ForceRestore при Disabled BRAVO (#321, рішення власника) і
            # зупиненій exchangAPI: реставрація йде, службу BRAVO не запускають,
            # exchangAPI (залежить від BRAVO) теж — лише INFO, без WARNING.
            'SRForceRestoreDisabledBravoStoppedExchange' = @($serviceRecoveryForceRestoreSeed + @(
                '$BravoMaintenanceEnabled = $false',
                '$BravoServiceDisabledBySystem = $true',
                '$restoreOnDisabledBravo = $true',
                '$script:ProbeServices = @{ ''BRAVO'' = ''Stopped''; ''exchangAPI'' = ''Stopped''; ''BravoWeb'' = ''Running'' }'
            ))
            # #314 FR-2: впала exchangAPI не стартує — CRITICAL як раніше, але
            # спроба все одно рахується (FR-5).
            'SRFailedServiceStartFails' = @(
                '$script:ProbeServices = @{ ''BRAVO'' = ''Running''; ''exchangAPI'' = ''Stopped''; ''BravoWeb'' = ''Running'' }',
                '$script:ProbeExitCodes = @{ ''exchangAPI'' = 1067 }',
                '$script:ProbeStartFailures = @(''exchangAPI'')'
            )
            # #314 FR-5/FR-6: дві спроби за добу вже є, остання — хвилину тому
            # (пауза 15 хв не минула): нічний прогін паузу ігнорує, запускає
            # службу й рахує 3-тю спробу -> CRITICAL «циклічно падає».
            'SRFailedServiceCyclicIgnoresPause' = @(
                '$script:ProbeServices = @{ ''BRAVO'' = ''Running''; ''exchangAPI'' = ''Stopped''; ''BravoWeb'' = ''Running'' }',
                '$script:ProbeExitCodes = @{ ''exchangAPI'' = 1067 }',
                '$script:SlackMode = ''errors_only''',
                '$script:NotificationWebhookUrls = @{ alerts = ''https://alerts.example.invalid/hook'' }'
            )
            # #314 FR-5: пошкоджений state-файл — WARNING, перейменування в
            # .corrupt-<ts>, облік заново; запуск служби не блокується.
            'SRFailedServiceCorruptState' = @(
                '$script:ProbeServices = @{ ''BRAVO'' = ''Running''; ''exchangAPI'' = ''Stopped''; ''BravoWeb'' = ''Running'' }'
            )
        }
        # Стан обліку до прогону (state-файл у каталозі сценарію). Мітки — від
        # поточного часу, hostname — цього хоста (дочірній процес той самий).
        $serviceRecoveryNow = [DateTimeOffset]::Now
        $serviceRecoveryCyclicFirstAttempt = $serviceRecoveryNow.AddHours(-2)
        $serviceRecoveryStateSeeds = @{
            'SRFailedServiceCyclicIgnoresPause' = (([ordered]@{
                        schemaVersion = 1
                        hostname = [Environment]::MachineName
                        services = [ordered]@{ exchangAPI = [ordered]@{
                                attempts = @($serviceRecoveryCyclicFirstAttempt.ToString('o'), $serviceRecoveryNow.AddMinutes(-1).ToString('o'))
                                lastCriticalAt = $null; stableSince = $null } }
                    }) | ConvertTo-Json -Depth 6)
            'SRFailedServiceCorruptState' = '{ "schemaVersion": 1, "hostname": '
        }

        $serviceRecoveryUtf8 = New-Object Text.UTF8Encoding($false)
        $serviceRecoveryProbeReady = $serviceRecoveryProbeTexts.Count -eq 3
        $serviceRecoveryResults = @{}
        if ($serviceRecoveryProbeReady) {
            [IO.File]::WriteAllText((Join-Path $serviceRecoveryRoot 'stubs.ps1'),
                ($serviceRecoveryProbeTexts['maintenanceOrchestrationStubs'] + "`n" + $serviceRecoveryExtraStubs), $serviceRecoveryUtf8)
            [IO.File]::WriteAllText((Join-Path $serviceRecoveryRoot 'seed.ps1'),
                ($serviceRecoveryProbeTexts['maintenanceOrchestrationSeed'] + "`n" + $serviceRecoveryExtraSeed), $serviceRecoveryUtf8)
            $serviceRecoveryProbePath = Join-Path $serviceRecoveryRoot 'probe.ps1'
            [IO.File]::WriteAllText($serviceRecoveryProbePath, $serviceRecoveryProbeTexts['maintenanceOrchestrationProbeScript'], (New-Object Text.UTF8Encoding($true)))
            foreach ($serviceRecoveryScenario in @($serviceRecoveryScenarios.Keys)) {
                $serviceRecoveryScenarioRoot = Join-Path $serviceRecoveryRoot $serviceRecoveryScenario
                [void][IO.Directory]::CreateDirectory($serviceRecoveryScenarioRoot)
                [IO.File]::WriteAllText((Join-Path $serviceRecoveryScenarioRoot 'scenario-seed.ps1'),
                    (@($serviceRecoveryScenarios[$serviceRecoveryScenario]) -join "`n"), $serviceRecoveryUtf8)
                if ($serviceRecoveryStateSeeds.ContainsKey($serviceRecoveryScenario)) {
                    $serviceRecoveryStateDirectory = Join-Path $serviceRecoveryScenarioRoot 'state'
                    [void][IO.Directory]::CreateDirectory($serviceRecoveryStateDirectory)
                    [IO.File]::WriteAllText((Join-Path $serviceRecoveryStateDirectory 'BRAVO_SERVICE_RECOVERY_STATE.json'),
                        [string]$serviceRecoveryStateSeeds[$serviceRecoveryScenario], $serviceRecoveryUtf8)
                }
            }
            $serviceRecoveryHost = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            # Без -ExecutionPolicy Bypass навмисно (ci\Test-BRAVOForbiddenPattern.ps1
            # не дозволяє нових Bypass-місць): дочірній процес успадковує
            # політику батьківського прогону self-test (той самий підхід, що
            # orchestration-проба Archive).
            $null = & $serviceRecoveryHost -NoLogo -NoProfile -NonInteractive `
                -File $serviceRecoveryProbePath `
                -Scenarios (@($serviceRecoveryScenarios.Keys) -join ',') -RepositoryRoot $root -ProbeParent $serviceRecoveryRoot
            foreach ($serviceRecoveryScenario in @($serviceRecoveryScenarios.Keys)) {
                $serviceRecoveryResultPath = Join-Path (Join-Path $serviceRecoveryRoot $serviceRecoveryScenario) 'result.json'
                $serviceRecoveryResults[$serviceRecoveryScenario] = if (Test-Path -LiteralPath $serviceRecoveryResultPath -PathType Leaf) {
                    [IO.File]::ReadAllText($serviceRecoveryResultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
                } else {
                    [pscustomobject]@{ ProbeError = "проба не записала result.json (код виходу $LASTEXITCODE)" }
                }
            }
        }
        Test-BRAVOCondition `
            -Condition ($serviceRecoveryProbeReady -and $serviceRecoveryResults.Count -eq $serviceRecoveryScenarios.Count) `
            -Name "ServiceRecovery/CharacterizationProbeAvailable" `
            -Failure "тексти проби оркестрації Maintenance (stubs/seed/probe) мають знаходитися в BRAVO_SELF_TEST.ps1 за AST, а кожен сценарій — записати result.json; знайдено текстів: $($serviceRecoveryProbeTexts.Count)"

        # Події циклу служб одного сценарію: усе після кроку [2/8] (знімок
        # стану служб, зупинка, реставрація, обробка журналів, відновлення)
        # до кроку «Відновлення стану служб» включно — або до кінця журналу
        # проби, якщо прогін завершився раніше. Вміст фази реставрації
        # згорнуто до її меж (RESTORE-PHASE ... STEP 4/8): її рядки містять
        # шляхи й не належать до циклу служб. Пропуск міграції журналів
        # (OPERATION) теж не належить до циклу.
        $serviceRecoveryCycleEvents = {
            param([string]$Scenario)
            $result = $serviceRecoveryResults[$Scenario]
            if ($null -eq $result -or $null -ne $result.PSObject.Properties['ProbeError']) { return @() }
            $events = @($result.Events | ForEach-Object { [string]$_ })
            $cycle = New-Object System.Collections.Generic.List[string]
            $inCycle = $false
            $inRestore = $false
            foreach ($event in $events) {
                if (-not $inCycle) {
                    if ($event -like 'STEP 2/8 *') { $inCycle = $true }
                    continue
                }
                if ($event -like 'OPERATION Міграція старих журналів *') { continue }
                if ($event -ceq 'RESTORE-PHASE') { $inRestore = $true; $cycle.Add($event); continue }
                if ($inRestore) {
                    if ($event -notlike 'STEP 4/8 *') { continue }
                    $inRestore = $false
                }
                $cycle.Add($event)
                if ($event -match '^STEP \d+/8 Відновлення стану служб ') { break }
            }
            return @($cycle.ToArray())
        }
        $serviceRecoveryCheck = {
            param([string]$Scenario, [int]$ExpectedExitCode, [string[]]$ExpectedEvents, [string]$Name, [string]$Meaning)
            $result = $serviceRecoveryResults[$Scenario]
            # Шлях каталогу сценарію (і роздільник) у рядках журналу — не
            # поведінка: нормалізуються однаково на Windows і в Linux-harness.
            $scenarioRoot = Join-Path $serviceRecoveryRoot $Scenario
            $actualEvents = @(& $serviceRecoveryCycleEvents $Scenario | ForEach-Object { $_.Replace($scenarioRoot, '<ROOT>').Replace('\', '/') })
            $actualExitCode = $null
            if ($null -ne $result -and $null -ne $result.PSObject.Properties['ExitCode']) { $actualExitCode = [int]$result.ExitCode }
            $firstDifference = -1
            $maxCount = [Math]::Max($actualEvents.Count, $ExpectedEvents.Count)
            for ($index = 0; $index -lt $maxCount; $index++) {
                $actualEvent = if ($index -lt $actualEvents.Count) { $actualEvents[$index] } else { '<немає>' }
                $expectedEvent = if ($index -lt $ExpectedEvents.Count) { $ExpectedEvents[$index] } else { '<немає>' }
                if ($actualEvent -cne $expectedEvent) { $firstDifference = $index; break }
            }
            $differenceText = if ($firstDifference -lt 0) { 'немає' } else {
                "подія #$firstDifference очікувалась '$(if ($firstDifference -lt $ExpectedEvents.Count) { $ExpectedEvents[$firstDifference] } else { '<немає>' })', отримано '$(if ($firstDifference -lt $actualEvents.Count) { $actualEvents[$firstDifference] } else { '<немає>' })'"
            }
            $probeErrorText = if ($null -ne $result -and $null -ne $result.PSObject.Properties['ProbeError']) { [string]$result.ProbeError } else { '' }
            Test-BRAVOCondition `
                -Condition ([string]::IsNullOrEmpty($probeErrorText) -and $actualExitCode -eq $ExpectedExitCode -and $firstDifference -lt 0) `
                -Name $Name `
                -Failure "$Meaning. Код: очікувався $ExpectedExitCode, отримано $actualExitCode; розбіжність: $differenceText; помилка проби: '$probeErrorText'; події циклу: $($actualEvents -join ' || ')"
        }

        # Будівельні блоки очікуваних подій (рядки журналу — дослівно).
        # #314 FR-2: зупинена до прогону служба (не Disabled, не під маркером)
        # — впала: INFO і намір перезапуску замість WARNING і сповіщення
        # «служби не запущені» (Send-InactiveServiceWarning прибрано).
        $srFailedAtStart = {
            param([string]$Name, [string]$ExitCode)
            "LOG-INFO Служба $Name зупинена до обслуговування (ExitCode $ExitCode): її журнали буде оброблено, а службу запущено після обслуговування (#314)"
        }
        $srFailedStarted = {
            param([string]$Name, [string]$ExitCode)
            "LOG-INFO Служба $Name була зупинена до обслуговування (ExitCode $ExitCode), запущена"
        }
        $srBravoOwnedAtStart = @('LOG-WARNING До початку maintenance не запущені служби: BRAVO (Stopped)')
        $srStopHeader = @('LOG-INFO ===', 'LOG-INFO === ЗУПИНКА СЛУЖБ ===')
        $srStopWeb = @('LOG-INFO Зупинка служби BRAVO Web (BravoWeb)...', 'STOP BravoWeb', 'LOG-SUCCESS Службу BRAVO Web успішно зупинено')
        $srStopExchange = @('LOG-INFO Зупинка служби exchangAPI...', 'STOP exchangAPI', 'LOG-SUCCESS Служба exchangAPI успішно зупинена')
        $srBisClosed = @('GET-PROCESS Bis', 'LOG-INFO Завершення процесу Bis...', 'STOP-PROCESS Bis Force=True')
        $srStopBravoHead = @('LOG-INFO Зупинка служби BRAVO...')
        $srStopBravoTail = @('STOP BRAVO', 'LOG-SUCCESS Служба BRAVO успішно зупинена')
        $srAlreadyStopped = @(
            'LOG-INFO Служба BRAVO Web вже зупинена - операція не потрібна',
            'LOG-INFO Служба exchangAPI вже зупинена',
            'LOG-INFO Служба BRAVO вже зупинена')
        $srRestoreSkipped = @('RESTORE-PHASE', 'STEP 4/8 Реставрація моделі SKIPPED', 'SIZE-CHECK', 'STEP 5/8 Перевірка розмірів .md OK')
        $srRestoreFailed = @('RESTORE-PHASE', 'STEP 4/8 Реставрація моделі FAIL', 'SIZE-CHECK', 'STEP 5/8 Перевірка розмірів .md OK')
        $srTraceLogs = @('LOG-INFO ===', 'LOG-INFO === ОБРОБКА TRACE-ФАЙЛІВ ===', 'TRACE-ROTATION')
        $srExchangeLogs = @('LOG-INFO ===', 'LOG-INFO === ОБРОБКА ЛОГІВ EXCHANGAPI ===', 'EXCHANGE-ROTATION')
        $srWebLogs = @(
            'LOG-INFO ===', 'LOG-INFO === ОБРОБКА ЛОГІВ APACHE ===', 'APACHE-ROTATION',
            'LOG-INFO ===', 'LOG-INFO === ОБРОБКА ЛОГІВ BRAVO WEB APPLICATION ===', 'WEBAPP-ROTATION')
        $srStartHeader = @('LOG-INFO ===', 'LOG-INFO === ВІДНОВЛЕННЯ ПОЧАТКОВОГО СТАНУ СЛУЖБ ===')
        $srStartBravo = @('LOG-INFO Запуск служби BRAVO...', 'START BRAVO', 'LOG-SUCCESS Служба BRAVO успішно запущена')
        # #314 FR-2: рядок пишеться лише після спроби запуску служби BRAVO
        # (до хвилі 3 — і тоді, коли службу не запускали).
        $srTraceAfterStart = @('LOG-INFO BRAVO Trace після запуску служби: ще не створено (очікувано до першої debug-події) — self-test-trace.log')
        $srStartExchange = @('LOG-INFO Запуск служби exchangAPI...', 'START exchangAPI', 'LOG-SUCCESS Служба exchangAPI успішно запущена')
        $srStartWeb = @('LOG-INFO Запуск служби BRAVO Web (BravoWeb)...', 'START BravoWeb', 'LOG-SUCCESS Службу BRAVO Web успішно запущено')
        $srStartedClean = @('MARKER-CLEAR', 'STEP 7/8 Відновлення стану служб OK')

        # (1) Канонічний цикл: маркер до першої зупинки; зупинка BRAVO Web ->
        # exchangAPI -> (Bis) -> BRAVO; журнали trace -> exchangAPI -> Apache ->
        # застосунок BRAVO Web лише після зупинки; запуск BRAVO -> exchangAPI ->
        # BRAVO Web; маркер прибрано після всіх стартів.
        & $serviceRecoveryCheck 'SRCanonicalCycle' 0 @(
            $srStopHeader; 'MARKER-WRITE BRAVO,exchangAPI,BravoWeb'
            $srStopWeb; $srStopExchange; $srStopBravoHead; $srBisClosed; $srStopBravoTail
            'STEP 3/8 Зупинка служб OK'
            $srRestoreSkipped
            $srTraceLogs; $srExchangeLogs; $srWebLogs
            'STEP 6/8 Обробка trace і логів OK'
            $srStartHeader; $srStartBravo; $srTraceAfterStart; $srStartExchange; $srStartWeb
            $srStartedClean
        ) 'ServiceRecovery/CycleCanonicalOrderAndLogs' 'усі служби працюють: зупинка BRAVO Web -> exchangAPI -> BRAVO (Bis завершується перед BRAVO), журнали trace/exchangAPI/Apache/BRAVO Web після зупинки, запуск BRAVO -> exchangAPI -> BRAVO Web, маркер прибрано'

        # (2) BRAVO Web не зупинилась: її журнали не чіпаються (WARNING), решта
        # циклу триває, службу повторно не запускають; код 60.
        & $serviceRecoveryCheck 'SRWebStopFailure' 60 @(
            $srStopHeader; 'MARKER-WRITE BRAVO,exchangAPI,BravoWeb'
            'LOG-INFO Зупинка служби BRAVO Web (BravoWeb)...'; 'STOP-FAIL BravoWeb'
            'LOG-ERROR ПОМИЛКА: Помилка при зупинці служби BRAVO Web (BravoWeb): перевищено таймаут 1 сек.'
            $srStopExchange; $srStopBravoHead; $srStopBravoTail
            'STEP 3/8 Зупинка служб FAIL'
            $srRestoreSkipped
            $srTraceLogs; $srExchangeLogs
            'LOG-WARNING Ротацію логів BRAVO Web пропущено: службу BravoWeb не зупинено (стан: Running)'
            'STEP 6/8 Обробка trace і логів WARN'
            $srStartHeader; $srStartBravo; $srTraceAfterStart; $srStartExchange
            'LOG-INFO Служба BRAVO Web вже запущена - операція не потрібна'
            $srStartedClean
        ) 'ServiceRecovery/CycleWebStopFailureSkipsWebLogs' 'BRAVO Web не зупинилась: її журнали пропущено з WARNING, решта зупинена й запущена, код 60'

        # (3) #314 FR-2 (ТЗ §6 п. 7) — СВІДОМА ЗМІНА характеризації хвилі 2
        # (раніше: «зупинена до прогону служба не потрапляє в маркер і не
        # запускається», WARNING і сповіщення «служби не запущені», код 10).
        # Тепер впала exchangAPI входить у маркер з наміром перезапуску, її
        # журнали обробляються, запуск — у канонічному порядку, у підсумку
        # INFO з ExitCode, спроба рахується в state-файлі; WARNING немає, код 0.
        & $serviceRecoveryCheck 'SRExchangeStoppedBeforeRun' 0 @(
            (& $srFailedAtStart 'exchangAPI' '1067')
            $srStopHeader; 'MARKER-WRITE BRAVO,exchangAPI,BravoWeb'
            $srStopWeb; 'LOG-INFO Служба exchangAPI вже зупинена'; $srStopBravoHead; $srStopBravoTail
            'STEP 3/8 Зупинка служб OK'
            $srRestoreSkipped
            $srTraceLogs; $srExchangeLogs; $srWebLogs
            'STEP 6/8 Обробка trace і логів OK'
            $srStartHeader; $srStartBravo; $srTraceAfterStart; $srStartExchange; $srStartWeb
            (& $srFailedStarted 'exchangAPI' '1067'); 'RECOVERY-STATE-WRITE'
            $srStartedClean
        ) 'ServiceRecovery/NightlyFailedServiceEntersMarkerAndStarts' '#314 FR-2: впала до прогону служба входить у маркер з наміром перезапуску, її журнали обробляються, вона запускається в канонічному порядку, у підсумку INFO з ExitCode; без WARNING і сповіщення «служби не запущені»'

        # (4) Гейт цілісності моделі: служби не запускаються, маркер лишається
        # (Health-watchdog), крок відновлення — FAIL, код 60.
        & $serviceRecoveryCheck 'SRIntegrityGateClosed' 60 @(
            $srStopHeader; 'MARKER-WRITE BRAVO,exchangAPI,BravoWeb'
            $srStopWeb; $srStopExchange; $srStopBravoHead; $srStopBravoTail
            'STEP 3/8 Зупинка служб OK'
            $srRestoreSkipped
            $srTraceLogs; $srExchangeLogs; $srWebLogs
            'STEP 6/8 Обробка trace і логів OK'
            $srStartHeader
            'LOG-ERROR ПОМИЛКА: Служби BRAVO НЕ піднято: цілісність моделі не встановлено після перерваної реставрації — потрібне ручне відновлення з before-архіву (<ROOT>/backup/MODEL/self-test_before.mdz).'
            # #314 FR-2: службу не запускали — рядка «BRAVO Trace після запуску» немає.
            'LOG-WARNING Ownership-маркер зупинки служб збережено: не всі служби запустились — Health-watchdog повторить спробу автоматично'
            'STEP 7/8 Відновлення стану служб FAIL'
        ) 'ServiceRecovery/CycleIntegrityGateKeepsServicesStopped' 'без встановленої цілісності моделі жодна служба не запускається, маркер зберігається, код 60'

        # (5) Намір перезапуску від аварійно перерваного прогону (без
        # restartSuppressed) успадковується: BRAVO запускається. #314 FR-2
        # (свідома зміна): BRAVO під маркером (OwnedByBravo) — не впала, її
        # веде успадкування #349; exchangAPI і BRAVO Web поза маркером —
        # впалі, теж входять у маркер і запускаються.
        & $serviceRecoveryCheck 'SRInheritedRestartIntent' 10 @(
            (& $srFailedAtStart 'exchangAPI' '0'); (& $srFailedAtStart 'BravoWeb' '0')
            $srBravoOwnedAtStart
            'LOG-INFO Успадковано намір перезапуску служб від аварійно перерваного прогону BRAVO_MAINTENANCE: BRAVO — їх буде запущено після обслуговування (#349)'
            $srStopHeader; 'MARKER-WRITE BRAVO,exchangAPI,BravoWeb'
            $srAlreadyStopped
            'STEP 3/8 Зупинка служб OK'
            $srRestoreSkipped
            $srTraceLogs; $srExchangeLogs; $srWebLogs
            'STEP 6/8 Обробка trace і логів OK'
            $srStartHeader; $srStartBravo; $srTraceAfterStart; $srStartExchange; $srStartWeb
            (& $srFailedStarted 'exchangAPI' '0'); (& $srFailedStarted 'BravoWeb' '0'); 'RECOVERY-STATE-WRITE'
            $srStartedClean
        ) 'ServiceRecovery/CycleInheritsRestartIntentWithoutSuppression' 'намір перезапуску з маркера мертвого власника без restartSuppressed успадковується: BRAVO у маркері й запускається; впалі exchangAPI і BRAVO Web (FR-2) — теж'

        # (6) Той самий маркер з restartSuppressed: намір не успадковується —
        # жодного маркера, зупинки чи запуску. #314 FR-2: restartSuppressed
        # діє й на впалі служби — exchangAPI і BRAVO Web класифіковано як
        # впалі, але намір знято (WARNING), жодна служба не запускається;
        # рядка «BRAVO Trace після запуску» немає (службу не запускали).
        & $serviceRecoveryCheck 'SRSuppressedRestartIntent' 10 @(
            (& $srFailedAtStart 'exchangAPI' '0'); (& $srFailedAtStart 'BravoWeb' '0')
            $srBravoOwnedAtStart
            'LOG-WARNING Впалі служби не запускаються: попередній прогін BRAVO_MAINTENANCE перервано посеред реставрації (restartSuppressed), цілісність моделі не підтверджено — exchangAPI, BravoWeb (#314)'
            $srAlreadyStopped
            'STEP 3/8 Зупинка служб SKIPPED'
            $srRestoreSkipped
            $srTraceLogs; $srExchangeLogs; $srWebLogs
            'STEP 6/8 Обробка trace і логів OK'
            $srStartHeader
            'STEP 7/8 Відновлення стану служб OK'
        ) 'ServiceRecovery/CycleSuppressedRestartIntentNotInherited' 'намір перезапуску з маркера з restartSuppressed не успадковується, а впалі служби (FR-2) під restartSuppressed не запускаються: жодна служба не запускається'

        # (7) -RunMissedRestoreOnly при працюючих службах: Recovery не зупиняє
        # служби — вихід 20 до фази зупинки.
        & $serviceRecoveryCheck 'SRRunMissedRestoreOnlyServicesRunning' 20 @(
            'LOG-WARNING Пропущені Backup/Maintenance не виконані: уже працюють служби BRAVO, exchangAPI, BravoWeb. Recovery не зупиняє служби. Реставрація слоту вже виконана раніше — її стан не змінюється.'
            'LOCK-EXIT'; 'OWNLOG-UPLOAD'; 'MANUAL-EXIT NoPause=True'
        ) 'ServiceRecovery/CycleRunMissedRestoreOnlyNeverStopsRunningServices' '-RunMissedRestoreOnly при працюючих службах завершується кодом 20 без зупинки й запуску служб'

        # (7a) Рев'ю PR #432 (B-P3-5): -RunMissedRestoreOnly, усі служби
        # зупинені — FR-2 не діє, служби не запускаються.
        & $serviceRecoveryCheck 'SRRunMissedRestoreOnlyServicesStopped' 0 @(
            $srAlreadyStopped
            'STEP 3/8 Зупинка служб SKIPPED'
            $srRestoreSkipped
            $srTraceLogs; $srExchangeLogs; $srWebLogs
            'STEP 6/8 Обробка trace і логів OK'
            $srStartHeader
            'STEP 7/8 Відновлення стану служб OK'
        ) 'ServiceRecovery/CycleRunMissedRestoreOnlyLeavesStoppedServices' "Рев'ю PR #432 (B-P3-5): -RunMissedRestoreOnly не запускає зупинених до прогону служб (ТЗ: «без змін»); впалі піднімає задача BRAVO_SERVICE_RECOVERY"

        # (8) -ForceRestore при Disabled BRAVO (#321): BRAVO не зупиняють і не
        # запускають, Bis завершується, trace не обробляється; exchangAPI і
        # BRAVO Web проходять повний цикл.
        & $serviceRecoveryCheck 'SRForceRestoreDisabledBravo' 40 @(
            $srStopHeader; 'MARKER-WRITE exchangAPI,BravoWeb'
            $srStopWeb; $srStopExchange
            'LOG-INFO Служба BRAVO має тип запуску Disabled - компонент BRAVO пропущено'
            $srBisClosed
            'STEP 3/8 Зупинка служб OK'
            $srRestoreFailed
            $srExchangeLogs; $srWebLogs
            'STEP 6/8 Обробка trace і логів OK'
            $srStartHeader; $srStartExchange; $srStartWeb
            $srStartedClean
        ) 'ServiceRecovery/CycleForceRestoreDisabledBravoClosesBisOnly' '-ForceRestore при Disabled BRAVO: службу BRAVO не чіпають, Bis завершують, exchangAPI і BRAVO Web зупиняють і запускають'

        # (9) #314 FR-2 — СВІДОМА ЗМІНА характеризації хвилі 2 (раніше:
        # «-ForceRestore: зупинена до прогону служба утримується без наміру
        # перезапуску й лишається зупиненою»). Тепер -ForceRestore теж
        # завершується запущеними службами: exchangAPI у маркері з наміром
        # перезапуску й запускається після реставрації.
        & $serviceRecoveryCheck 'SRForceRestoreExchangeStoppedBeforeRun' 40 @(
            (& $srFailedAtStart 'exchangAPI' '0')
            $srStopHeader; 'MARKER-WRITE BRAVO,exchangAPI,BravoWeb'
            $srStopWeb; 'LOG-INFO Служба exchangAPI вже зупинена'; $srStopBravoHead; $srStopBravoTail
            'STEP 3/8 Зупинка служб OK'
            $srRestoreFailed
            $srTraceLogs; $srExchangeLogs; $srWebLogs
            'STEP 6/8 Обробка trace і логів OK'
            $srStartHeader; $srStartBravo; $srTraceAfterStart; $srStartExchange; $srStartWeb
            (& $srFailedStarted 'exchangAPI' '0'); 'RECOVERY-STATE-WRITE'
            $srStartedClean
        ) 'ServiceRecovery/ForceRestoreStartsInitiallyStoppedService' '#314 FR-2: -ForceRestore завершується запущеними службами — зупинена до прогону exchangAPI у маркері з наміром перезапуску й запускається після реставрації'

        # (10) -ForceRestore при Disabled BRAVO (#321, рішення власника):
        # реставрація виконується, службу BRAVO не запускають; зупинена
        # exchangAPI залежить від BRAVO — не запускається, лише INFO, без
        # WARNING і без сповіщення (код визначає лише стаб реставрації).
        & $serviceRecoveryCheck 'SRForceRestoreDisabledBravoStoppedExchange' 40 @(
            'LOG-INFO Служба exchangAPI зупинена й не запускатиметься: вона залежить від служби BRAVO, яка має тип запуску Disabled'
            $srStopHeader; 'MARKER-WRITE exchangAPI,BravoWeb'; 'MARKER-NO-RESTART exchangAPI'
            $srStopWeb; 'LOG-INFO Служба exchangAPI вже зупинена'
            'LOG-INFO Служба BRAVO має тип запуску Disabled - компонент BRAVO пропущено'
            'STEP 3/8 Зупинка служб OK'
            $srRestoreFailed
            $srExchangeLogs; $srWebLogs
            'STEP 6/8 Обробка trace і логів OK'
            $srStartHeader; $srStartWeb
            $srStartedClean
        ) 'ServiceRecovery/ForceRestoreDisabledBravoInfoOnly' '#321: -ForceRestore при Disabled BRAVO не запускає ні BRAVO, ні залежну від неї зупинену exchangAPI — лише INFO, без WARNING'

        # (11) #314 FR-2/FR-5: впала exchangAPI не стартує — ERROR і
        # критичне сповіщення як раніше, маркер лишається (код 60), а спроба
        # все одно рахується в state-файлі.
        & $serviceRecoveryCheck 'SRFailedServiceStartFails' 60 @(
            (& $srFailedAtStart 'exchangAPI' '1067')
            $srStopHeader; 'MARKER-WRITE BRAVO,exchangAPI,BravoWeb'
            $srStopWeb; 'LOG-INFO Служба exchangAPI вже зупинена'; $srStopBravoHead; $srStopBravoTail
            'STEP 3/8 Зупинка служб OK'
            $srRestoreSkipped
            $srTraceLogs; $srExchangeLogs; $srWebLogs
            'STEP 6/8 Обробка trace і логів OK'
            $srStartHeader; $srStartBravo; $srTraceAfterStart
            'LOG-INFO Запуск служби exchangAPI...'; 'START-FAIL exchangAPI'
            'LOG-ERROR ПОМИЛКА: Помилка при запуску служби exchangAPI: перевищено таймаут 1 сек.'
            $srStartWeb
            'RECOVERY-STATE-WRITE'
            'LOG-WARNING Ownership-маркер зупинки служб збережено: не всі служби запустились — Health-watchdog повторить спробу автоматично'
            'STEP 7/8 Відновлення стану служб FAIL'
        ) 'ServiceRecovery/NightlyFailedServiceStartFailureIsCritical' '#314 FR-2: впала служба, що не стартує, — ERROR і критичне сповіщення, маркер лишається, код 60'

        # Стан обліку після прогону (state-файл каталогу сценарію).
        $serviceRecoveryStateAfter = {
            param([string]$Scenario)
            $statePath = Join-Path (Join-Path (Join-Path $serviceRecoveryRoot $Scenario) 'state') 'BRAVO_SERVICE_RECOVERY_STATE.json'
            if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
            return ([IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
        }
        $serviceRecoveryEvents = {
            param([string]$Scenario)
            $result = $serviceRecoveryResults[$Scenario]
            if ($null -eq $result -or $null -ne $result.PSObject.Properties['ProbeError']) { return @() }
            return @($result.Events | ForEach-Object { [string]$_ })
        }
        $serviceRecoveryExitCode = {
            param([string]$Scenario)
            $result = $serviceRecoveryResults[$Scenario]
            if ($null -eq $result -or $null -eq $result.PSObject.Properties['ExitCode']) { return $null }
            return [int]$result.ExitCode
        }

        # (12) ТЗ §6 п. 7, FR-5: спроба нічного прогону рахується в state-файлі
        # незалежно від результату запуску (успіх і збій — по одній мітці).
        $srStateStarted = & $serviceRecoveryStateAfter 'SRExchangeStoppedBeforeRun'
        $srStateFailed = & $serviceRecoveryStateAfter 'SRFailedServiceStartFails'
        $srStateCount = {
            param($State, [string]$Name)
            if ($null -eq $State -or $null -eq $State.services -or $null -eq $State.services.PSObject.Properties[$Name]) { return -1 }
            return @($State.services.$Name.attempts).Count
        }
        Test-BRAVOCondition `
            -Condition (
                (& $srStateCount $srStateStarted 'exchangAPI') -eq 1 -and
                (& $srStateCount $srStateFailed 'exchangAPI') -eq 1 -and
                [string]$srStateStarted.hostname -eq [Environment]::MachineName -and
                $null -eq $srStateStarted.services.PSObject.Properties['BRAVO']
            ) `
            -Name 'ServiceRecovery/NightlyAttemptCountedRegardlessOfResult' `
            -Failure "#314 FR-5: нічний прогін має зареєструвати по одній спробі впалої exchangAPI і при успіху, і при збої запуску (лише для впалої служби); стан після успіху: $($srStateStarted | ConvertTo-Json -Compress -Depth 6); після збою: $($srStateFailed | ConvertTo-Json -Compress -Depth 6)"

        # (13) ТЗ §6 п. 3 і 10: пауза 15 хв перед 3-ю спробою не минула, але
        # нічний прогін її ігнорує — служба запускається, спроба рахується (3
        # за добу), іде WARNING у журнал і CRITICAL «циклічно падає» маршрутом
        # alerts (errors_only); lastCriticalAt записано.
        $srCyclicEvents = @(& $serviceRecoveryEvents 'SRFailedServiceCyclicIgnoresPause')
        $srCyclicState = & $serviceRecoveryStateAfter 'SRFailedServiceCyclicIgnoresPause'
        $srCyclicSince = $serviceRecoveryCyclicFirstAttempt.ToLocalTime().ToString('dd.MM HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        $srCyclicWarning = "LOG-WARNING Служба exchangAPI циклічно падає: 3 падінь з $srCyclicSince, потрібне втручання. (#314)"
        $srCyclicNotify = 'NOTIFY CRITICAL|СЛУЖБА BRAVO ЦИКЛІЧНО ПАДАЄ -> https://alerts.example.invalid/hook'
        Test-BRAVOCondition `
            -Condition (
                (& $serviceRecoveryExitCode 'SRFailedServiceCyclicIgnoresPause') -eq 10 -and
                @($srCyclicEvents | Where-Object { $_ -ceq 'START exchangAPI' }).Count -eq 1 -and
                @($srCyclicEvents | Where-Object { $_ -ceq $srCyclicWarning }).Count -eq 1 -and
                @($srCyclicEvents | Where-Object { $_ -ceq $srCyclicNotify }).Count -eq 1 -and
                @($srCyclicEvents | Where-Object { $_ -like 'NOTIFY *' }).Count -eq 1 -and
                (& $srStateCount $srCyclicState 'exchangAPI') -eq 3 -and
                $null -ne $srCyclicState.services.exchangAPI.lastCriticalAt
            ) `
            -Name 'ServiceRecovery/NightlyIgnoresPauseAndRaisesCyclicCritical' `
            -Failure "#314 FR-5/FR-6: нічний прогін має ігнорувати паузу (запустити exchangAPI), зарахувати 3-тю спробу за добу, записати WARNING '$srCyclicWarning' і рівно одне сповіщення '$srCyclicNotify'; код: $(& $serviceRecoveryExitCode 'SRFailedServiceCyclicIgnoresPause'); події: $($srCyclicEvents -join ' || '); стан: $($srCyclicState | ConvertTo-Json -Compress -Depth 6)"

        # (14) ТЗ §6 п. 4 (у нічному прогоні): пошкоджений state-файл — WARNING,
        # файл перейменовано в .corrupt-<ts>, облік заново (1 спроба), запуск
        # служби не заблоковано.
        $srCorruptEvents = @(& $serviceRecoveryEvents 'SRFailedServiceCorruptState')
        $srCorruptStateDirectory = Join-Path (Join-Path $serviceRecoveryRoot 'SRFailedServiceCorruptState') 'state'
        $srCorruptFiles = @()
        if (Test-Path -LiteralPath $srCorruptStateDirectory -PathType Container) {
            $srCorruptFiles = @([IO.Directory]::GetFiles($srCorruptStateDirectory, 'BRAVO_SERVICE_RECOVERY_STATE.json.corrupt-*'))
        }
        Test-BRAVOCondition `
            -Condition (
                (& $serviceRecoveryExitCode 'SRFailedServiceCorruptState') -eq 10 -and
                @($srCorruptEvents | Where-Object { $_ -ceq 'START exchangAPI' }).Count -eq 1 -and
                @($srCorruptEvents | Where-Object { $_ -like 'LOG-WARNING Облік спроб відновлення служб (*) не прочитано — файл пошкоджений:*збережено як *.corrupt-*' }).Count -eq 1 -and
                $srCorruptFiles.Count -eq 1 -and
                (& $srStateCount (& $serviceRecoveryStateAfter 'SRFailedServiceCorruptState') 'exchangAPI') -eq 1
            ) `
            -Name 'ServiceRecovery/NightlyCorruptStateRenamedAndDoesNotBlockStart' `
            -Failure "#314 FR-5: пошкоджений state-файл має дати WARNING, перейменування в .corrupt-<ts> і облік заново, не блокуючи запуск; файлів .corrupt: $($srCorruptFiles.Count); події: $($srCorruptEvents -join ' || ')"
    } finally {
        if (Test-Path -LiteralPath $serviceRecoveryRoot -PathType Container) {
            Remove-Item -LiteralPath $serviceRecoveryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Облік спроб відновлення і сповіщення (#314 FR-5/FR-6, ТЗ §6 п. 3, 4, 10) —
# напряму над функціями BRAVO.Maintenance.ServiceRecovery.ps1 (вони не
# читають змінних прогону: шлях, hostname, час і маршрути — параметрами).
# Справжні Write-BRAVOStateFileAtomic (BRAVO.System) і
# Resolve-BRAVONotificationRoute (BRAVO.Notifications); формування й доставка
# повідомлення (функції runtime) — стаби, що записують виклики.
& {
    $recoveryUnitRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_SERVICE_RECOVERY_STATE_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($recoveryUnitRoot)
        Import-Module -Name (Join-Path $root 'modules\BRAVO.System\BRAVO.System.psd1') -ErrorAction Stop
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Notifications\BRAVO.Notifications.psd1') -ErrorAction Stop
        . (Join-Path $root 'modules\BRAVO.Maintenance\BRAVO.Maintenance.ServiceRecovery.ps1')

        $recoveryHost = 'HOST-01'
        $recoveryT0 = [DateTimeOffset]::Parse('2026-09-27T10:00:00+03:00', [Globalization.CultureInfo]::InvariantCulture)

        # --- ТЗ §6 п. 3: паузи 0/5/15/60 хв, ковзне вікно 24 год. ---
        $pauseState = New-BRAVOServiceRecoveryState -HostName $recoveryHost
        $pauseChecks = New-Object System.Collections.Generic.List[string]
        $pauseExpect = {
            param([int]$OffsetMinutes, [bool]$Elapsed, [int]$PauseMinutes, [int]$InWindow)
            $check = Test-BRAVOServiceRecoveryPauseElapsed -State $pauseState -ServiceName 'exchangAPI' -Now $recoveryT0.AddMinutes($OffsetMinutes)
            if ($check.Elapsed -ne $Elapsed -or $check.PauseMinutes -ne $PauseMinutes -or $check.AttemptsInWindow -ne $InWindow) {
                $pauseChecks.Add("+$OffsetMinutes хв: Elapsed=$($check.Elapsed) (очікувалось $Elapsed), пауза $($check.PauseMinutes) (очікувалось $PauseMinutes), спроб у вікні $($check.AttemptsInWindow) (очікувалось $InWindow)")
            }
        }
        & $pauseExpect 0 $true 0 0
        [void](Add-BRAVOServiceRecoveryAttempt -State $pauseState -ServiceName 'exchangAPI' -Now $recoveryT0)
        & $pauseExpect 4 $false 5 1
        & $pauseExpect 5 $true 5 1
        [void](Add-BRAVOServiceRecoveryAttempt -State $pauseState -ServiceName 'exchangAPI' -Now $recoveryT0.AddMinutes(5))
        & $pauseExpect 19 $false 15 2
        & $pauseExpect 20 $true 15 2
        [void](Add-BRAVOServiceRecoveryAttempt -State $pauseState -ServiceName 'exchangAPI' -Now $recoveryT0.AddMinutes(20))
        & $pauseExpect 79 $false 60 3
        & $pauseExpect 80 $true 60 3
        [void](Add-BRAVOServiceRecoveryAttempt -State $pauseState -ServiceName 'exchangAPI' -Now $recoveryT0.AddMinutes(80))
        & $pauseExpect 139 $false 60 4
        & $pauseExpect 140 $true 60 4
        # Через 24 год. 1 хв від першої спроби вона випадає з вікна (3 лишаються).
        & $pauseExpect (24 * 60 + 1) $true 60 3
        # Через добу після останньої спроби вікно порожнє — пауза знову 0.
        & $pauseExpect (80 + 24 * 60 + 1) $true 0 0
        # Інша служба має власний облік.
        $pauseOther = Test-BRAVOServiceRecoveryPauseElapsed -State $pauseState -ServiceName 'BRAVO' -Now $recoveryT0.AddMinutes(81)
        if (-not $pauseOther.Elapsed -or $pauseOther.AttemptsInWindow -ne 0) { $pauseChecks.Add('облік іншої служби не має залежати від exchangAPI') }
        Test-BRAVOCondition `
            -Condition ($pauseChecks.Count -eq 0) `
            -Name 'ServiceRecovery/PauseScheduleAndSlidingWindow' `
            -Failure "#314 FR-5: паузи 0/5/15/далі 60 хв перед 1/2/3/4+ спробою, мітки старші за 24 год. не рахуються: $($pauseChecks -join '; ')"

        # --- ТЗ §6 п. 3: скидання обліку після 30 хв стабільної роботи ---
        $stableState = New-BRAVOServiceRecoveryState -HostName $recoveryHost
        [void](Add-BRAVOServiceRecoveryAttempt -State $stableState -ServiceName 'exchangAPI' -Now $recoveryT0)
        [void](Add-BRAVOServiceRecoveryAttempt -State $stableState -ServiceName 'exchangAPI' -Now $recoveryT0.AddMinutes(5))
        $stableFirst = Update-BRAVOServiceRecoveryStability -State $stableState -ServiceName 'exchangAPI' -IsRunning $true -Now $recoveryT0.AddMinutes(6)
        $stableEarly = Update-BRAVOServiceRecoveryStability -State $stableState -ServiceName 'exchangAPI' -IsRunning $true -Now $recoveryT0.AddMinutes(35)
        $stableAttemptsKept = @($stableState.services['exchangAPI'].attempts).Count
        # Перерва в роботі скидає stableSince: відлік 30 хв починається заново.
        $stableDown = Update-BRAVOServiceRecoveryStability -State $stableState -ServiceName 'exchangAPI' -IsRunning $false -Now $recoveryT0.AddMinutes(36)
        $stableAgain = Update-BRAVOServiceRecoveryStability -State $stableState -ServiceName 'exchangAPI' -IsRunning $true -Now $recoveryT0.AddMinutes(37)
        $stableNotYet = Update-BRAVOServiceRecoveryStability -State $stableState -ServiceName 'exchangAPI' -IsRunning $true -Now $recoveryT0.AddMinutes(66)
        $stableReset = Update-BRAVOServiceRecoveryStability -State $stableState -ServiceName 'exchangAPI' -IsRunning $true -Now $recoveryT0.AddMinutes(67)
        $stableAfter = Test-BRAVOServiceRecoveryPauseElapsed -State $stableState -ServiceName 'exchangAPI' -Now $recoveryT0.AddMinutes(67)
        # Нова спроба після stableSince скидає його (відлік — від останньої спроби).
        $stable2 = New-BRAVOServiceRecoveryState -HostName $recoveryHost
        [void](Add-BRAVOServiceRecoveryAttempt -State $stable2 -ServiceName 'BRAVO' -Now $recoveryT0)
        [void](Update-BRAVOServiceRecoveryStability -State $stable2 -ServiceName 'BRAVO' -IsRunning $true -Now $recoveryT0.AddMinutes(1))
        [void](Add-BRAVOServiceRecoveryAttempt -State $stable2 -ServiceName 'BRAVO' -Now $recoveryT0.AddMinutes(20))
        $stable2Late = Update-BRAVOServiceRecoveryStability -State $stable2 -ServiceName 'BRAVO' -IsRunning $true -Now $recoveryT0.AddMinutes(40)
        Test-BRAVOCondition `
            -Condition (
                $stableFirst.Changed -and -not $stableFirst.Reset -and
                -not $stableEarly.Reset -and $stableAttemptsKept -eq 2 -and
                $stableDown.Changed -and -not $stableAgain.Reset -and -not $stableNotYet.Reset -and
                $stableReset.Reset -and -not $stableState.services.ContainsKey('exchangAPI') -and
                $stableAfter.AttemptsInWindow -eq 0 -and $stableAfter.PauseMinutes -eq 0 -and
                -not $stable2Late.Reset -and $stable2.services.ContainsKey('BRAVO')
            ) `
            -Name 'ServiceRecovery/CounterResetAfterThirtyMinutesStable' `
            -Failure "#314 FR-5: облік служби обнуляється лише після 30 хв безперервної роботи після останньої спроби (stableSince); перша фіксація=$($stableFirst.Changed), рано=$($stableEarly.Reset), після перерви=$($stableNotYet.Reset), скинуто=$($stableReset.Reset), нова спроба скидає відлік=$(-not $stable2Late.Reset)"

        # --- ТЗ §6 п. 3: нічний облік ігнорує паузу, але рахує спробу ---
        $nightlyPath = Join-Path $recoveryUnitRoot 'nightly\BRAVO_SERVICE_RECOVERY_STATE.json'
        $nightlyFirst = Invoke-BRAVOServiceRecoveryAttemptAccounting -ServiceNames @('exchangAPI') -Path $nightlyPath -HostName $recoveryHost -Now $recoveryT0
        $nightlyStateBefore = (Read-BRAVOServiceRecoveryState -Path $nightlyPath -HostName $recoveryHost -Now $recoveryT0.AddMinutes(1)).State
        $nightlyPause = Test-BRAVOServiceRecoveryPauseElapsed -State $nightlyStateBefore -ServiceName 'exchangAPI' -Now $recoveryT0.AddMinutes(1)
        $nightlySecond = Invoke-BRAVOServiceRecoveryAttemptAccounting -ServiceNames @('exchangAPI') -Path $nightlyPath -HostName $recoveryHost -Now $recoveryT0.AddMinutes(1)
        Test-BRAVOCondition `
            -Condition (
                @($nightlyFirst.Warnings).Count -eq 0 -and @($nightlySecond.Warnings).Count -eq 0 -and
                -not $nightlyPause.Elapsed -and
                @($nightlySecond.Registrations).Count -eq 1 -and $nightlySecond.Registrations[0].AttemptNumber -eq 2
            ) `
            -Name 'ServiceRecovery/NightlyAccountingIgnoresPauseButCounts' `
            -Failure "#314 FR-5: облік нічного прогону паузу не перевіряє (пауза не минула: $(-not $nightlyPause.Elapsed)), але рахує спробу (номер $(@($nightlySecond.Registrations | ForEach-Object { $_.AttemptNumber }) -join ','), очікувався 2); попередження: $(@($nightlyFirst.Warnings) + @($nightlySecond.Warnings) -join '; ')"

        # --- ТЗ §6 п. 4: state-файл ---
        $stateFileRoot = Join-Path $recoveryUnitRoot 'state'
        [void][IO.Directory]::CreateDirectory($stateFileRoot)
        $stateFilePath = Join-Path $stateFileRoot 'BRAVO_SERVICE_RECOVERY_STATE.json'
        $stateCorruptFiles = { @([IO.Directory]::GetFiles($stateFileRoot, 'BRAVO_SERVICE_RECOVERY_STATE.json.corrupt-*')) }

        # Відсутній файл: порожній облік, без попередження й без запису.
        $missingRead = Read-BRAVOServiceRecoveryState -Path $stateFilePath -HostName $recoveryHost -Now $recoveryT0
        Test-BRAVOCondition `
            -Condition ($null -eq $missingRead.Warning -and $missingRead.State.services.Count -eq 0 -and [string]$missingRead.State.hostname -eq $recoveryHost -and -not [IO.File]::Exists($stateFilePath)) `
            -Name 'ServiceRecovery/StateFileMissingStartsEmpty' `
            -Failure "#314 FR-5: відсутній state-файл — порожній облік без попередження; попередження: '$($missingRead.Warning)'"

        # Атомарний запис: UTF-8 без BOM, через Write-BRAVOStateFileAtomic (temp
        # + move, без залишків .tmp), мітки поза вікном прибрано, round-trip.
        $writeState = New-BRAVOServiceRecoveryState -HostName $recoveryHost
        $writeState.services['exchangAPI'] = @{ attempts = @($recoveryT0.AddHours(-30), $recoveryT0.AddMinutes(-10)); lastCriticalAt = $null; stableSince = $null }
        $writeState.services['BRAVO'] = @{ attempts = @($recoveryT0.AddHours(-25)); lastCriticalAt = $null; stableSince = $null }
        Write-BRAVOServiceRecoveryState -Path $stateFilePath -State $writeState -Now $recoveryT0
        $writtenBytes = [IO.File]::ReadAllBytes($stateFilePath)
        $writtenHasBom = $writtenBytes.Length -ge 3 -and $writtenBytes[0] -eq 0xEF -and $writtenBytes[1] -eq 0xBB -and $writtenBytes[2] -eq 0xBF
        $writtenLeftovers = @([IO.Directory]::GetFiles($stateFileRoot) | Where-Object { [IO.Path]::GetFileName($_) -ne 'BRAVO_SERVICE_RECOVERY_STATE.json' })
        $writtenRead = Read-BRAVOServiceRecoveryState -Path $stateFilePath -HostName $recoveryHost -Now $recoveryT0
        $writeFunction = Get-Command -Name 'Write-BRAVOServiceRecoveryState' -CommandType Function
        $writeUsesAtomic = @($writeFunction.ScriptBlock.Ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-BRAVOStateFileAtomic'
                }, $true)).Count -eq 1
        $readFunctionText = (Get-Command -Name 'Read-BRAVOServiceRecoveryState' -CommandType Function).ScriptBlock.Ast.Extent.Text
        Test-BRAVOCondition `
            -Condition (
                $writeUsesAtomic -and -not $writtenHasBom -and $writtenLeftovers.Count -eq 0 -and
                $readFunctionText.Contains('-Encoding UTF8') -and
                $null -eq $writtenRead.Warning -and
                @($writtenRead.State.services['exchangAPI'].attempts).Count -eq 1 -and
                $writtenRead.State.services['exchangAPI'].attempts[0] -eq $recoveryT0.AddMinutes(-10) -and
                -not $writtenRead.State.services.ContainsKey('BRAVO')
            ) `
            -Name 'ServiceRecovery/StateFileAtomicUtf8WithoutBomAndPruned' `
            -Failure "#314 FR-5: запис state-файлу — атомарний (Write-BRAVOStateFileAtomic: $writeUsesAtomic, залишків: $($writtenLeftovers.Count)), UTF-8 без BOM (BOM: $writtenHasBom), читання з -Encoding UTF8, мітки старші за 24 год. прибрано; прочитано: $($writtenRead.State.services.Keys -join ',')"

        # Файл з BOM (записаний іншим інструментом) читається без втрат.
        [IO.File]::WriteAllText($stateFilePath, [IO.File]::ReadAllText($stateFilePath, [Text.Encoding]::UTF8), (New-Object Text.UTF8Encoding($true)))
        $bomRead = Read-BRAVOServiceRecoveryState -Path $stateFilePath -HostName $recoveryHost -Now $recoveryT0
        Test-BRAVOCondition `
            -Condition ($null -eq $bomRead.Warning -and @($bomRead.State.services['exchangAPI'].attempts).Count -eq 1 -and @(& $stateCorruptFiles).Count -eq 0) `
            -Name 'ServiceRecovery/StateFileWithBomAccepted' `
            -Failure "#314 FR-5: state-файл з BOM має читатися як звичайний; попередження: '$($bomRead.Warning)'"

        # Пошкоджений файл: WARNING, перейменування в .corrupt-<ts>, облік заново.
        [IO.File]::WriteAllText($stateFilePath, '{ "schemaVersion": 1, "hostname": ', (New-Object Text.UTF8Encoding($false)))
        $corruptRead = Read-BRAVOServiceRecoveryState -Path $stateFilePath -HostName $recoveryHost -Now $recoveryT0
        $corruptRenamed = @(& $stateCorruptFiles)
        Test-BRAVOCondition `
            -Condition (
                -not [string]::IsNullOrWhiteSpace([string]$corruptRead.Warning) -and
                ([string]$corruptRead.Warning).Contains('файл пошкоджений') -and
                $corruptRead.State.services.Count -eq 0 -and
                -not [IO.File]::Exists($stateFilePath) -and $corruptRenamed.Count -eq 1 -and
                [string]$corruptRead.CorruptPath -eq $corruptRenamed[0] -and
                $corruptRenamed[0].EndsWith('.corrupt-' + $recoveryT0.ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture))
            ) `
            -Name 'ServiceRecovery/StateFileCorruptRenamedAndRestarted' `
            -Failure "#314 FR-5: пошкоджений state-файл — WARNING, перейменування в .corrupt-<ts>, облік заново; попередження: '$($corruptRead.Warning)'; перейменовано: $($corruptRenamed -join ', ')"

        # Чужий hostname: так само, і спроба через облік не блокується.
        foreach ($corruptFile in @(& $stateCorruptFiles)) { [IO.File]::Delete($corruptFile) }
        $foreignState = New-BRAVOServiceRecoveryState -HostName 'HOST-02'
        $foreignState.services['exchangAPI'] = @{ attempts = @($recoveryT0.AddMinutes(-2), $recoveryT0.AddMinutes(-1)); lastCriticalAt = $null; stableSince = $null }
        Write-BRAVOServiceRecoveryState -Path $stateFilePath -State $foreignState -Now $recoveryT0
        $foreignAccounting = Invoke-BRAVOServiceRecoveryAttemptAccounting -ServiceNames @('exchangAPI') -Path $stateFilePath -HostName $recoveryHost -Now $recoveryT0
        $foreignAfter = Read-BRAVOServiceRecoveryState -Path $stateFilePath -HostName $recoveryHost -Now $recoveryT0
        Test-BRAVOCondition `
            -Condition (
                @($foreignAccounting.Warnings).Count -eq 1 -and
                ([string]@($foreignAccounting.Warnings)[0]).Contains('іншому хості (HOST-02)') -and
                @(& $stateCorruptFiles).Count -eq 1 -and
                @($foreignAccounting.Registrations).Count -eq 1 -and $foreignAccounting.Registrations[0].AttemptNumber -eq 1 -and
                $null -eq $foreignAfter.Warning -and [string]$foreignAfter.State.hostname -eq $recoveryHost
            ) `
            -Name 'ServiceRecovery/StateFileForeignHostRenamedAndRestarted' `
            -Failure "#314 FR-5: state-файл іншого хоста — WARNING, .corrupt-<ts>, облік заново з цього хоста, спроба зареєстрована; попередження: $(@($foreignAccounting.Warnings) -join '; ')"

        # --- ТЗ §6 п. 10: сповіщення ---
        $notifySent = New-Object System.Collections.Generic.List[string]
        function New-MaintenanceNotificationMessage {
            param($Title, $TitleEmoji, $Duration, $DurationLabel, $StatusLines, $Details, $LogPath, $Severity)
            return ('{0}|{1}|{2}' -f $Severity, $Title, (@($Details) -join ' / '))
        }
        function Invoke-NotificationWebhook {
            param([string]$Message, [string]$WebhookUrl)
            $notifySent.Add(('{0} -> {1}' -f $Message, $WebhookUrl))
        }
        $notifyUrls = @{ general = 'https://general.example.invalid/hook'; alerts = 'https://alerts.example.invalid/hook' }
        $notifyLog = 'C:\BRAVO\LOGS\BRAVO_MAINTENANCE_20260927_100000_PID100.log'
        $recovered = New-BRAVOServiceRecoveryNotificationContent -Kind Recovered -ServiceName 'exchangAPI' -ExitCode 1067 -EventText 'подія 7034 о 09:58' -AttemptNumber 2 -LogPath $notifyLog
        $failed = New-BRAVOServiceRecoveryNotificationContent -Kind Failed -ServiceName 'exchangAPI' -ExitCode 1066 -ServiceSpecificExitCode 3 -AttemptNumber 1 -Reason 'перевищено таймаут 60 сек.' -LogPath $notifyLog
        $notifyRoutes = @()
        foreach ($notifyMode in @('none', 'errors_only', 'all')) {
            foreach ($notifyContent in @($recovered, $failed)) {
                $delivery = Send-BRAVOServiceRecoveryNotification -Content $notifyContent -NotificationMode $notifyMode -WebhookUrls $notifyUrls -LogPath $notifyLog
                $notifyRoutes += ('{0}:{1}={2}/{3}' -f $notifyMode, $notifyContent.Severity, $delivery.Route, $delivery.Sent)
            }
        }
        $expectedRoutes = @('none:WARNING=none/False', 'none:CRITICAL=none/False', 'errors_only:WARNING=alerts/True', 'errors_only:CRITICAL=alerts/True', 'all:WARNING=alerts/True', 'all:CRITICAL=alerts/True')
        Test-BRAVOCondition `
            -Condition (
                $recovered.Severity -eq 'WARNING' -and $failed.Severity -eq 'CRITICAL' -and
                ($notifyRoutes -join ',') -ceq ($expectedRoutes -join ',') -and
                $notifySent.Count -eq 4 -and
                $notifySent[0] -ceq "WARNING|СЛУЖБУ BRAVO ВІДНОВЛЕНО|Служба exchangAPI впала (ExitCode 1067, подія 7034 о 09:58), журнали збережено, запущена. / Спроба 2 за добу. / Журнал: $notifyLog -> https://alerts.example.invalid/hook" -and
                $notifySent[1] -ceq "CRITICAL|СЛУЖБУ BRAVO НЕ ВДАЛОСЯ ПІДНЯТИ|Службу exchangAPI не вдалося запустити (ExitCode 1066, ServiceSpecificExitCode 3): перевищено таймаут 60 сек.. / Спроба 1 за добу. / Журнал: $notifyLog -> https://alerts.example.invalid/hook"
            ) `
            -Name 'ServiceRecovery/NotificationRecoveredWarningFailedCritical' `
            -Failure "#314 FR-6: відновлено -> WARNING (ExitCode, подія, номер спроби, журнал), не вдалося -> CRITICAL з причиною; режими none/errors_only/all поважаються; маршрути: $($notifyRoutes -join ','); надіслано: $($notifySent -join ' || ')"

        # CRITICAL «циклічно падає»: з 3-ї спроби за добу, далі не частіше
        # разу на 24 год., поки лічильник не обнулиться.
        $cyclicState = New-BRAVOServiceRecoveryState -HostName $recoveryHost
        $cyclicDue = @()
        foreach ($cyclicOffset in @(0, 5, 20, 80, 140, (24 * 60 + 10), (24 * 60 + 30))) {
            $registration = Add-BRAVOServiceRecoveryAttempt -State $cyclicState -ServiceName 'exchangAPI' -Now $recoveryT0.AddMinutes($cyclicOffset)
            $cyclicDue += ('{0}:{1}' -f $registration.AttemptNumber, $(if ($registration.CyclicCriticalDue) { 'CRITICAL' } else { '-' }))
        }
        $cyclicContent = New-BRAVOServiceRecoveryNotificationContent -Kind Cyclic -ServiceName 'exchangAPI' -AttemptNumber 3 -FirstAttemptAt $recoveryT0 -LogPath $notifyLog
        $cyclicSince = $recoveryT0.ToLocalTime().ToString('dd.MM HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        # Після обнулення (30 хв стабільної роботи) лічильник і lastCriticalAt — заново.
        [void](Update-BRAVOServiceRecoveryStability -State $cyclicState -ServiceName 'exchangAPI' -IsRunning $true -Now $recoveryT0.AddMinutes(24 * 60 + 91))
        [void](Update-BRAVOServiceRecoveryStability -State $cyclicState -ServiceName 'exchangAPI' -IsRunning $true -Now $recoveryT0.AddMinutes(24 * 60 + 121))
        $cyclicAfterReset = @()
        foreach ($cyclicOffset in @((24 * 60 + 130), (24 * 60 + 140), (24 * 60 + 160))) {
            $registration = Add-BRAVOServiceRecoveryAttempt -State $cyclicState -ServiceName 'exchangAPI' -Now $recoveryT0.AddMinutes($cyclicOffset)
            $cyclicAfterReset += ('{0}:{1}' -f $registration.AttemptNumber, $(if ($registration.CyclicCriticalDue) { 'CRITICAL' } else { '-' }))
        }
        Test-BRAVOCondition `
            -Condition (
                ($cyclicDue -join ',') -ceq '1:-,2:-,3:CRITICAL,4:-,5:-,4:-,4:CRITICAL' -and
                ($cyclicAfterReset -join ',') -ceq '1:-,2:-,3:CRITICAL' -and
                $cyclicContent.Severity -eq 'CRITICAL' -and
                @($cyclicContent.Details)[0] -ceq "Служба exchangAPI циклічно падає: 3 падінь з $cyclicSince, потрібне втручання."
            ) `
            -Name 'ServiceRecovery/NotificationCyclicCriticalOncePerDay' `
            -Failure "#314 FR-6: CRITICAL «циклічно падає» — на 3-й спробі за 24 год., далі не частіше разу на 24 год. (lastCriticalAt), після обнулення лічильника — знову з 3-ї; послідовність: $($cyclicDue -join ','); після обнулення: $($cyclicAfterReset -join ','); текст: $(@($cyclicContent.Details)[0])"
    } finally {
        if (Test-Path -LiteralPath $recoveryUnitRoot -PathType Container) {
            Remove-Item -LiteralPath $recoveryUnitRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Профіль BRAVO_MAINTENANCE.ps1 -RecoverServices (#314, хвиля 4, FR-3;
# ТЗ §6 п. 2, 5, 6). Ланцюжок — напряму над Get-BRAVOServiceRecoveryPlan
# (функція лише обчислює). Сам профіль — у дочірньому процесі: справжні
# функції BRAVO.Maintenance.RecoverServices.ps1, циклу служб
# (ServiceCycle.ps1) і обліку відновлення (ServiceRecovery.ps1), справжні
# Get-BRAVOMaintenanceResolvedExitCode / Get-BRAVOMaintenanceFinalStatus
# runtime (за AST) і BRAVO.ExitCodes; служби, класифікація, lock, маркер,
# журнали, події SCM і доставка сповіщень — стаби, що пишуть події.
& {
    $recoverRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_RECOVER_SERVICES_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($recoverRoot)
        $recoverProfilePath = Join-Path $root 'modules\BRAVO.Maintenance\BRAVO.Maintenance.RecoverServices.ps1'
        $recoverProfileText = ''
        if (Test-Path -LiteralPath $recoverProfilePath -PathType Leaf) {
            $recoverProfileText = [IO.File]::ReadAllText($recoverProfilePath, [Text.Encoding]::UTF8)
        }
        $recoverProfileAst = [Management.Automation.Language.Parser]::ParseInput($recoverProfileText, [ref]$null, [ref]$null)
        $recoverFunctionNames = @($recoverProfileAst.EndBlock.Statements | Where-Object {
                $_ -is [Management.Automation.Language.FunctionDefinitionAst]
            } | ForEach-Object { $_.Name })

        # --- ТЗ §6 п. 2: ланцюжки і порядок ---
        $recoverPlanText = @($recoverProfileAst.EndBlock.Statements | Where-Object {
                $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Get-BRAVOServiceRecoveryPlan'
            } | ForEach-Object { $_.Extent.Text }) -join "`n"
        $recoverPlanChecks = New-Object System.Collections.Generic.List[string]
        if ([string]::IsNullOrWhiteSpace($recoverPlanText)) {
            $recoverPlanChecks.Add('немає функції Get-BRAVOServiceRecoveryPlan')
        } else {
            . ([scriptblock]::Create($recoverPlanText))
            $recoverPlanSet = [pscustomobject]@{
                Bravo = [pscustomobject]@{ Key = 'Bravo'; Name = 'BRAVO'; Managed = $true; Disabled = $false }
                ExchangeApi = [pscustomobject]@{ Key = 'ExchangeApi'; Name = 'exchangAPI'; Managed = $true; Disabled = $false }
                BravoWeb = [pscustomobject]@{ Key = 'BravoWeb'; Name = 'BravoWeb'; Managed = $true; Disabled = $false }
            }
            $recoverPlanDisabledBravo = [pscustomobject]@{
                Bravo = [pscustomobject]@{ Key = 'Bravo'; Name = 'BRAVO'; Managed = $false; Disabled = $true }
                ExchangeApi = $recoverPlanSet.ExchangeApi
                BravoWeb = $recoverPlanSet.BravoWeb
            }
            $recoverCondition = {
                param([string]$Condition, [string]$Status)
                [pscustomobject]@{ Condition = $Condition; Status = $Status }
            }
            $recoverPlanCases = @(
                @{ Name = 'BRAVO'; Set = $recoverPlanSet; Conditions = @{ Bravo = (& $recoverCondition 'Failed' 'Stopped'); ExchangeApi = (& $recoverCondition 'Running' 'Running'); BravoWeb = (& $recoverCondition 'Running' 'Running') }; Deferred = @(); Expected = 'F=Bravo;S=BravoWeb,ExchangeApi;R=Bravo,ExchangeApi,BravoWeb;P=;D=' },
                @{ Name = 'exchangAPI'; Set = $recoverPlanSet; Conditions = @{ Bravo = (& $recoverCondition 'Running' 'Running'); ExchangeApi = (& $recoverCondition 'Failed' 'Stopped'); BravoWeb = (& $recoverCondition 'Running' 'Running') }; Deferred = @(); Expected = 'F=ExchangeApi;S=;R=ExchangeApi;P=;D=' },
                @{ Name = 'BRAVO Web'; Set = $recoverPlanSet; Conditions = @{ Bravo = (& $recoverCondition 'Running' 'Running'); ExchangeApi = (& $recoverCondition 'Running' 'Running'); BravoWeb = (& $recoverCondition 'Failed' 'Stopped') }; Deferred = @(); Expected = 'F=BravoWeb;S=;R=BravoWeb;P=;D=' },
                @{ Name = 'BRAVO + exchangAPI'; Set = $recoverPlanSet; Conditions = @{ Bravo = (& $recoverCondition 'Failed' 'Stopped'); ExchangeApi = (& $recoverCondition 'Failed' 'Stopped'); BravoWeb = (& $recoverCondition 'Running' 'Running') }; Deferred = @(); Expected = 'F=Bravo,ExchangeApi;S=BravoWeb;R=Bravo,ExchangeApi,BravoWeb;P=;D=' },
                @{ Name = 'BRAVO + BRAVO Web'; Set = $recoverPlanSet; Conditions = @{ Bravo = (& $recoverCondition 'Failed' 'Stopped'); ExchangeApi = (& $recoverCondition 'Running' 'Running'); BravoWeb = (& $recoverCondition 'Failed' 'Stopped') }; Deferred = @(); Expected = 'F=Bravo,BravoWeb;S=ExchangeApi;R=Bravo,ExchangeApi,BravoWeb;P=;D=' },
                @{ Name = 'exchangAPI + BRAVO Web'; Set = $recoverPlanSet; Conditions = @{ Bravo = (& $recoverCondition 'Running' 'Running'); ExchangeApi = (& $recoverCondition 'Failed' 'Stopped'); BravoWeb = (& $recoverCondition 'Failed' 'Stopped') }; Deferred = @(); Expected = 'F=ExchangeApi,BravoWeb;S=;R=ExchangeApi,BravoWeb;P=;D=' },
                @{ Name = 'усі три'; Set = $recoverPlanSet; Conditions = @{ Bravo = (& $recoverCondition 'Failed' 'Stopped'); ExchangeApi = (& $recoverCondition 'Failed' 'Stopped'); BravoWeb = (& $recoverCondition 'Failed' 'Stopped') }; Deferred = @(); Expected = 'F=Bravo,ExchangeApi,BravoWeb;S=;R=Bravo,ExchangeApi,BravoWeb;P=;D=' },
                @{ Name = 'BRAVO, exchangAPI призупинена'; Set = $recoverPlanSet; Conditions = @{ Bravo = (& $recoverCondition 'Failed' 'Stopped'); ExchangeApi = (& $recoverCondition 'Failed' 'Paused'); BravoWeb = (& $recoverCondition 'Running' 'Running') }; Deferred = @(); Expected = 'F=Bravo;S=BravoWeb;R=Bravo,BravoWeb;P=ExchangeApi;D=' },
                @{ Name = 'BRAVO, BRAVO Web не керується'; Set = $recoverPlanSet; Conditions = @{ Bravo = (& $recoverCondition 'Failed' 'Stopped'); ExchangeApi = (& $recoverCondition 'Running' 'Running') }; Deferred = @(); Expected = 'F=Bravo;S=ExchangeApi;R=Bravo,ExchangeApi;P=;D=' },
                @{ Name = 'BRAVO, exchangAPI під маркером'; Set = $recoverPlanSet; Conditions = @{ Bravo = (& $recoverCondition 'Failed' 'Stopped'); ExchangeApi = (& $recoverCondition 'OwnedByBravo' 'Stopped'); BravoWeb = (& $recoverCondition 'Running' 'Running') }; Deferred = @(); Expected = 'F=Bravo;S=BravoWeb;R=Bravo,BravoWeb;P=;D=' },
                @{ Name = 'BRAVO Disabled, exchangAPI зупинена'; Set = $recoverPlanDisabledBravo; Conditions = @{ ExchangeApi = (& $recoverCondition 'Failed' 'Stopped'); BravoWeb = (& $recoverCondition 'Running' 'Running') }; Deferred = @(); Expected = 'F=;S=;R=;P=;D=' },
                @{ Name = 'пауза exchangAPI не минула'; Set = $recoverPlanSet; Conditions = @{ Bravo = (& $recoverCondition 'Running' 'Running'); ExchangeApi = (& $recoverCondition 'Failed' 'Stopped'); BravoWeb = (& $recoverCondition 'Failed' 'Stopped') }; Deferred = @('ExchangeApi'); Expected = 'F=BravoWeb;S=;R=BravoWeb;P=;D=ExchangeApi' }
            )
            foreach ($recoverPlanCase in $recoverPlanCases) {
                $recoverPlan = Get-BRAVOServiceRecoveryPlan -ServiceSet $recoverPlanCase.Set -Conditions $recoverPlanCase.Conditions -DeferredKeys $recoverPlanCase.Deferred
                $recoverPlanActual = 'F={0};S={1};R={2};P={3};D={4}' -f (@($recoverPlan.FailedKeys) -join ','), (@($recoverPlan.StopKeys) -join ','), (@($recoverPlan.StartKeys) -join ','), (@($recoverPlan.PausedKeys) -join ','), (@($recoverPlan.DeferredKeys) -join ',')
                if ($recoverPlanActual -cne $recoverPlanCase.Expected) {
                    $recoverPlanChecks.Add("$($recoverPlanCase.Name): очікувалось $($recoverPlanCase.Expected), отримано $recoverPlanActual")
                }
            }
            $recoverDependent = Get-BRAVOServiceRecoveryPlan -ServiceSet $recoverPlanDisabledBravo -Conditions @{ ExchangeApi = (& $recoverCondition 'Failed' 'Stopped') }
            if ((@($recoverDependent.DependentSkippedKeys) -join ',') -cne 'ExchangeApi') {
                $recoverPlanChecks.Add("BRAVO Disabled: exchangAPI має потрапити в DependentSkippedKeys, отримано '$(@($recoverDependent.DependentSkippedKeys) -join ',')'")
            }
        }
        Test-BRAVOCondition `
            -Condition ($recoverPlanChecks.Count -eq 0) `
            -Name 'ServiceRecovery/RecoverServicesChainPlan' `
            -Failure "#314 FR-3 крок 5 (ТЗ §6 п. 2): Failed BRAVO -> зупинка працюючих BRAVO Web і exchangAPI, запуск BRAVO -> exchangAPI -> BRAVO Web; Failed exchangAPI / BRAVO Web -> лише вона; кілька -> об'єднання в канонічному порядку; призупинена не чіпається: $($recoverPlanChecks -join '; ')"

        # --- Статичні межі профілю ---
        $recoverCommandNames = @($recoverProfileAst.FindAll({
                    param($node) $node -is [Management.Automation.Language.CommandAst]
                }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Select-Object -Unique)
        $recoverForbidden = @('Restore-FromArchive', 'Invoke-BRAVOModelRestoreRecovery', 'Compare-FileSizes', 'Check-MdFileSizes',
            'Process-OldData', 'Remove-OldLogFiles', 'Remove-OldRestoreArchives', 'Remove-BRAVOExpiredCompressedLogs',
            'Invoke-BRAVOLegacyLogMigration', 'Invoke-BRAVOLegacySweep', 'Invoke-BRAVOTraceArchiveMaintenance', 'Send-BRAVOTraceArchive',
            'Invoke-BRAVOTraceRemoteLogMigration', 'Invoke-BRAVOMaintenanceOwnLogUpload', 'Invoke-AutoShutdown', 'Start-Process',
            'Invoke-CommandWithLog', 'Send-FinalReport', 'Write-BRAVOOperationStatus', 'Write-BRAVOTaskExecutionState',
            'Invoke-ServiceStateChange', 'Start-Service', 'Stop-Service')
        $recoverForbiddenUsed = @($recoverCommandNames | Where-Object { $recoverForbidden -contains $_ })
        $recoverReused = @('Invoke-BRAVOMaintenanceServiceStopSequence', 'Invoke-BRAVOMaintenanceServiceLogProcessing',
            'Invoke-BRAVOMaintenanceServiceStartSequence', 'Get-BRAVOMaintenanceServiceConditionSet', 'Enter-BRAVOMaintenanceOperationLock',
            'Write-BRAVOServiceQuiescenceState', 'Test-BRAVOServiceRecoveryPauseElapsed', 'Invoke-BRAVOServiceRecoveryAttemptAccounting',
            'New-BRAVOServiceRecoveryNotificationContent', 'Send-BRAVOServiceRecoveryNotification')
        $recoverReusedMissing = @($recoverReused | Where-Object { $recoverCommandNames -notcontains $_ })
        Test-BRAVOCondition `
            -Condition ($recoverFunctionNames.Count -gt 0 -and $recoverForbiddenUsed.Count -eq 0 -and $recoverReusedMissing.Count -eq 0) `
            -Name 'ServiceRecovery/RecoverServicesOnlyRecoversServices' `
            -Failure "#314 FR-3: профіль -RecoverServices не виконує реставрацію, перевірку розмірів, очистку, міграцію журналів, trace-архів/SFTP, BRAVO_ARCHIV і автовимкнення, а служби зупиняє/запускає лише функціями циклу служб (без копіювання); заборонені виклики: $($recoverForbiddenUsed -join ', '); не використано: $($recoverReusedMissing -join ', ')"

        $recoverEntryText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_MAINTENANCE.ps1'), [Text.Encoding]::UTF8)
        $recoverEntryLines = @($recoverEntryText -split "`r?`n").Count
        $recoverRuntimeText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'), [Text.Encoding]::UTF8)
        $recoverRuntimeAst = [Management.Automation.Language.Parser]::ParseInput($recoverRuntimeText, [ref]$null, [ref]$null)
        $recoverRuntimeParamCount = @($recoverRuntimeAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.ParameterAst] -and $node.Name.VariablePath.UserPath -eq 'RecoverServices' -and
                    $node.Extent.Text -match '^\[switch\]\$RecoverServices$'
                }, $true)).Count
        $recoverLogFileIndex = $recoverRuntimeText.IndexOf('$script:LOG_FILE = "$LOG_DIR\BRAVO_MAINTENANCE_$maintenanceLogRunId.log"')
        # Гілка профілю — перша після шляхів журналів (рядок елевації теж містить 'if ($RecoverServices) {').
        $recoverBranchIndex = if ($recoverLogFileIndex -ge 0) { $recoverRuntimeText.IndexOf('if ($RecoverServices) {', $recoverLogFileIndex) } else { -1 }
        $recoverStepsIndex = $recoverRuntimeText.IndexOf('Initialize-BRAVOMaintenanceSteps -Total 8')
        $recoverBranchText = if ($recoverBranchIndex -ge 0) { $recoverRuntimeText.Substring($recoverBranchIndex, [Math]::Min(400, $recoverRuntimeText.Length - $recoverBranchIndex)) } else { '' }
        Test-BRAVOCondition `
            -Condition (
                $recoverEntryText.Contains('[switch]$RecoverServices') -and
                $recoverEntryText.Contains('RecoverServices = $RecoverServices') -and
                $recoverEntryLines -le 250 -and
                $recoverRuntimeParamCount -eq 2 -and
                $recoverRuntimeText.Contains('if ($RecoverServices) { $elevatedArguments += "-RecoverServices" }') -and
                $recoverRuntimeText.Contains("'BRAVO.Maintenance.RecoverServices.ps1'") -and
                $recoverLogFileIndex -ge 0 -and $recoverBranchIndex -gt $recoverLogFileIndex -and $recoverBranchIndex -lt $recoverStepsIndex -and
                $recoverBranchText -match 'exit \(Invoke-BRAVOMaintenanceRecoverServicesProfile -ForceRestore:\$ForceRestore -RunMissedRestoreOnly:\$RunMissedRestoreOnly\)'
            ) `
            -Name 'ServiceRecovery/RecoverServicesWiredThroughEntrypointAndRuntime' `
            -Failure "#314 FR-3: -RecoverServices — switch тонкого entrypoint (≤250 рядків, зараз $recoverEntryLines), той самий switch у param() runtime (скрипт і функція: $recoverRuntimeParamCount з 2) і в аргументах елевації, профіль підключено з BRAVO.Maintenance.RecoverServices.ps1 і викликано до кроків нічного прогону (після визначення шляхів журналів), код завершення — його"

        # --- Operation-lock без очікування (FR-3 крок 3) ---
        $recoverLockText = @($recoverRuntimeAst.FindAll({
                    param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Enter-BRAVOMaintenanceOperationLock'
                }, $true) | ForEach-Object { $_.Extent.Text }) -join "`n"
        $recoverLockResult = $null
        $recoverLockError = ''
        $recoverLockSleeps = 0
        $recoverLockLogs = 0
        if (-not [string]::IsNullOrWhiteSpace($recoverLockText)) {
            $recoverLockScenario = & {
                $operationLockSettings = @{ Path = $recoverRoot }
                $schedulerSettings = @{}
                $script:recoverLockSleeps = 0
                $script:recoverLockLogs = 0
                function Get-BRAVOOperationLockWaitBudget { param($SchedulerSettings, $TaskType) [pscustomobject]@{ EffectiveMinutes = 0.02; LimitDescription = '' } }
                function Start-Sleep { param($Seconds, $Milliseconds) $script:recoverLockSleeps++ }
                function Write-Log { param($Message, $Level) $script:recoverLockLogs++ }
                . ([scriptblock]::Create($recoverLockText))
                try {
                    # Каталог замість файлу lock-а: відкриття гарантовано не вдається — як зайнятий lock.
                    $lockResult = Enter-BRAVOMaintenanceOperationLock -TaskType Maintenance -NoWait
                    [pscustomobject]@{ Result = $lockResult; Error = ''; Sleeps = $script:recoverLockSleeps; Logs = $script:recoverLockLogs }
                } catch {
                    [pscustomobject]@{ Result = $null; Error = $_.Exception.Message; Sleeps = $script:recoverLockSleeps; Logs = $script:recoverLockLogs }
                }
            }
            $recoverLockResult = $recoverLockScenario.Result
            $recoverLockError = [string]$recoverLockScenario.Error
            $recoverLockSleeps = [int]$recoverLockScenario.Sleeps
            $recoverLockLogs = [int]$recoverLockScenario.Logs
        }
        Test-BRAVOCondition `
            -Condition ($null -ne $recoverLockResult -and -not $recoverLockResult.Success -and $recoverLockSleeps -eq 0 -and $recoverLockLogs -eq 0) `
            -Name 'ServiceRecovery/RecoverServicesLockWithoutWaiting' `
            -Failure "#314 FR-3 крок 3: Enter-BRAVOMaintenanceOperationLock -NoWait робить рівно одну спробу без очікування й без рядків журналу; помилка: '$recoverLockError'; очікувань: $recoverLockSleeps; рядків журналу: $recoverLockLogs"

        # --- Профіль у дочірньому процесі ---
        $recoverProbeScript = @'
param([string]$RepositoryRoot, [string]$ProbeRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$probeResults = [ordered]@{}
try {
    Import-Module -Name (Join-Path $RepositoryRoot 'modules\BRAVO.ExitCodes\BRAVO.ExitCodes.psd1') -Force -ErrorAction Stop
    foreach ($probeFileName in @('BRAVO.Maintenance.ServiceCycle.ps1', 'BRAVO.Maintenance.ServiceRecovery.ps1', 'BRAVO.Maintenance.RecoverServices.ps1')) {
        $probeFileText = [IO.File]::ReadAllText((Join-Path $RepositoryRoot ('modules\BRAVO.Maintenance\' + $probeFileName)), [Text.Encoding]::UTF8)
        foreach ($probeStatement in @([Management.Automation.Language.Parser]::ParseInput($probeFileText, [ref]$null, [ref]$null).EndBlock.Statements)) {
            if ($probeStatement -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($probeStatement.Extent.Text)) }
        }
    }
    $probeRuntimeText = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'), [Text.Encoding]::UTF8)
    foreach ($probeRuntimeFunction in @([Management.Automation.Language.Parser]::ParseInput($probeRuntimeText, [ref]$null, [ref]$null).FindAll({
                    param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    @('Get-BRAVOMaintenanceResolvedExitCode', 'Get-BRAVOMaintenanceFinalStatus') -contains $node.Name
                }, $true))) {
        . ([scriptblock]::Create($probeRuntimeFunction.Extent.Text))
    }
} catch {
    [IO.File]::WriteAllText((Join-Path $ProbeRoot 'results.json'), (@{ ProbeError = $_.Exception.Message } | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    exit 1
}

# Стаби (визначені після справжніх функцій — перекривають їх).
function Add-ProbeEvent { param([string]$Text) $script:ProbeEvents.Add($Text) }
function Write-Host { param([Parameter(Position = 0)]$Object, $ForegroundColor, [switch]$NoNewline) Add-ProbeEvent ('HOST ' + [string]$Object) }
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO', [int]$SeparatorLength = 100, [switch]$NoTimestamp, [switch]$NoConsole, [switch]$Environmental)
    if ($Level -eq 'WARNING' -and -not $Environmental) { $script:BRAVOWarningCount++ }
    Add-ProbeEvent ('LOG-{0} {1}' -f $Level, $Message)
    if ([string]::IsNullOrWhiteSpace([string]$script:LOG_FILE)) { Add-ProbeEvent 'LOG-WITHOUT-FILE'; return }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([string]$script:LOG_FILE))
    [IO.File]::AppendAllText([string]$script:LOG_FILE, ('[{0}] {1}' -f $Level, $Message) + "`n", (New-Object Text.UTF8Encoding($false)))
}
function Get-Service {
    param([string]$Name, $ErrorAction)
    if (-not $script:ProbeServices.ContainsKey($Name)) {
        if ([string]$ErrorAction -eq 'SilentlyContinue') { return $null }
        throw "self-test: невідома служба $Name"
    }
    $probeService = [pscustomobject]@{ Name = $Name; DisplayName = ('{0} Display' -f $Name); Status = [string]$script:ProbeServices[$Name] }
    $probeService | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
    return $probeService
}
function Get-BRAVOManagedServiceCondition {
    param([string]$Name)
    $probeStatus = [string]$script:ProbeServices[$Name]
    $probeMode = [string]$script:ProbeStartModes[$Name]
    $probeCondition = if ($probeMode -eq 'Disabled') { 'Disabled' } elseif ($probeStatus -eq 'Running') { 'Running' } elseif (@('StartPending', 'StopPending', 'ContinuePending', 'PausePending') -contains $probeStatus) { 'Pending' } elseif (@($script:ProbeMarkerNames) -contains $Name) { 'OwnedByBravo' } else { 'Failed' }
    $probeExitCode = 0
    if ($script:ProbeExitCodes.ContainsKey($Name)) { $probeExitCode = $script:ProbeExitCodes[$Name] }
    return [pscustomobject]@{ Name = $Name; Exists = $true; StartMode = $probeMode; Status = $probeStatus; ExitCode = $probeExitCode; ServiceSpecificExitCode = 0; Condition = $probeCondition }
}
function Invoke-ServiceStateChange {
    param([string]$Name, [string]$DesiredStatus, [int]$TimeoutSeconds, [int]$PollIntervalSeconds, [switch]$Force)
    if ($DesiredStatus -eq 'Stopped') {
        if (@($script:ProbeStopFailures) -contains $Name) {
            Add-ProbeEvent "STOP-FAIL $Name"
            return [pscustomobject]@{ Success = $false; AlreadyInState = $false; StateChangeIssued = $true; FinalStatus = 'Running'; Error = 'self-test: таймаут зупинки' }
        }
        Add-ProbeEvent "STOP $Name"
        $script:ProbeServices[$Name] = 'Stopped'
        return [pscustomobject]@{ Success = $true; AlreadyInState = $false; StateChangeIssued = $true; FinalStatus = 'Stopped'; Error = $null }
    }
    if (@($script:ProbeStartFailures) -contains $Name) {
        Add-ProbeEvent "START-FAIL $Name"
        return [pscustomobject]@{ Success = $false; AlreadyInState = $false; StateChangeIssued = $true; FinalStatus = 'Stopped'; Error = 'self-test: служба не стартувала' }
    }
    Add-ProbeEvent "START $Name"
    $script:ProbeServices[$Name] = 'Running'
    return [pscustomobject]@{ Success = $true; AlreadyInState = $false; StateChangeIssued = $true; FinalStatus = 'Running'; Error = $null }
}
function Get-Process { param($Name, $ErrorAction) if (@($script:ProbeStrayProcesses) -contains [string]$Name) { return [pscustomobject]@{ Name = [string]$Name } } }
function Stop-Process { param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force) process { Add-ProbeEvent ('STOP-PROCESS ' + [string]$InputObject.Name) } }
function Start-Sleep { param($Seconds, $Milliseconds) }
function Send-SlackAlert {
    param([string]$Message, [switch]$IsCritical, [string]$Severity)
    if ($IsCritical) { $script:criticalErrorOccurred = $true; $script:CriticalErrorsList.Add($Message) }
    Add-ProbeEvent 'ALERT-QUEUED'
}
function Enter-BRAVOMaintenanceOperationLock {
    param([string]$TaskType, [switch]$NoWait)
    if ($script:ProbeLockBusy) { Add-ProbeEvent 'LOCK-BUSY'; return [pscustomobject]@{ Success = $false; Stream = $null; Path = 'self-test-lock'; Error = 'self-test: зайнято' } }
    Add-ProbeEvent ('LOCK-ENTER NoWait={0}' -f [bool]$NoWait)
    return [pscustomobject]@{ Success = $true; Stream = $null; Path = 'self-test-lock'; Error = $null }
}
function Exit-BRAVOMaintenanceOperationLock { Add-ProbeEvent 'LOCK-EXIT' }
function Read-BRAVOOperationLockHolder {
    param([string]$Path)
    $script:ProbeLockHolderReads++
    if ($script:ProbeLockHolderReads -ge 2 -and $null -ne $script:ProbeLockHolderRecheck) { return $script:ProbeLockHolderRecheck }
    return $script:ProbeLockHolder
}
function Test-BRAVOProcessAlive { param([int]$ProcessId, [string]$ProcessStartTime) return [bool]$script:ProbeLockHolderAlive }
function Write-BRAVOServiceQuiescenceState {
    param([string]$Owner, [object[]]$Services, [string]$LogFile, [switch]$RestartSuppressed, [object[]]$StartTypeSnapshot, [switch]$PreserveForeignStartTypeSnapshot)
    if ($script:ProbeMarkerWriteFails) { Add-ProbeEvent 'MARKER-WRITE-FAIL'; throw 'self-test: імітований збій запису ownership-маркера' }
    Add-ProbeEvent ('MARKER-WRITE {0} {1}' -f $Owner, ((@($Services) | ForEach-Object { '{0}={1}' -f $_.Name, [bool]$_.RestartIntent }) -join ','))
    $script:ProbeMarkerState = [pscustomobject]@{ owner = $Owner; pid = $PID }
}
function Read-BRAVOServiceQuiescenceState { return $script:ProbeMarkerState }
function Test-BRAVOServiceQuiescenceStateOwnedByCurrentProcess { param($State) return [bool]$script:ProbeMarkerOwned }
function Clear-BRAVOServiceQuiescenceState { param($ExpectedState) Add-ProbeEvent 'MARKER-CLEAR'; return $true }
function Get-BRAVOForeignServiceQuiescenceContext { return $script:ProbeForeignContext }
function Get-BRAVOServiceRecoveryStatePath { return $script:ProbeStatePath }
function Protect-BRAVOMachineStateRoot { param([switch]$CheckOnly, [string]$Path) return [pscustomobject]@{ Path = $Path; Compliant = $true; Applied = $false; Issues = @() } }
function Write-BRAVOStateFileAtomic {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
    Add-ProbeEvent 'RECOVERY-STATE-WRITE'
}
function Resolve-BRAVONotificationRoute {
    param($Severity, $NotificationMode, $RoutingTable)
    if ($NotificationMode -eq 'none' -or ($NotificationMode -eq 'errors_only' -and $Severity -eq 'SUCCESS')) { return 'none' }
    if ($Severity -eq 'SUCCESS') { return 'general' }
    return 'alerts'
}
function New-MaintenanceNotificationMessage { param($Title, $TitleEmoji, $Duration, $DurationLabel, $StatusLines, $Details, $LogPath, $Severity) return ('{0}|{1}' -f $Severity, $Title) }
function Invoke-NotificationWebhook { param([string]$Message, [string]$WebhookUrl) Add-ProbeEvent ('NOTIFY ' + $Message) }
function Invoke-BRAVOTraceRotation { param($Sources, $DestinationDirectory, $RetryCount, $RetryDelaySeconds, $Logger) Add-ProbeEvent 'TRACE-ROTATION'; return [pscustomobject]@{ Moved = 1; Errors = 0 } }
function Invoke-BRAVOExchangeApiLogRotation { param($SourceDirectory, $DestinationDirectory, $Patterns, $RetryCount, $RetryDelaySeconds, $Logger) Add-ProbeEvent 'EXCHANGE-ROTATION'; if ($script:ProbeExternalStartDuringLogs) { $script:ProbeServices['exchangAPI'] = 'Running' }; if ($script:ProbeMarkerTakenOverDuringLogs) { $script:ProbeMarkerOwned = $false }; return [pscustomobject]@{ Found = 1; Moved = 1; Errors = [int]$script:ProbeExchangeRotationErrors } }
function Invoke-BRAVOApacheLogRotation { param($SourceDirectory, $DestinationDirectory, $Filter, $RetryCount, $RetryDelaySeconds, $Logger) Add-ProbeEvent 'APACHE-ROTATION'; return [pscustomobject]@{ Moved = 1; Errors = 0 } }
function Invoke-BRAVOWebApplicationLogRotation { param($SourceDirectory, $DestinationDirectory, $Filter, $RetryCount, $RetryDelaySeconds, $Logger) Add-ProbeEvent 'WEBAPP-ROTATION'; return [pscustomobject]@{ Moved = 1; Errors = 0 } }
function Get-BRAVOTraceConfiguration { param($DiscoveryResult, $TraceRootDirectory, $DateFolderName) return [pscustomobject]@{ IsValid = $true; TracePath = 'self-test-trace.log'; Reason = $null } }
function Get-BRAVOInstallationTraceOutSources { param($InstallationRoot, $LimsRoot, $SrvTracePath, $ExplicitBisPath) return [pscustomobject]@{ Sources = @(); ScanRoot = 'self-test'; ScanRootReason = 'self-test' } }
function Resolve-BRAVOExchangeApiRuntimeDirectory { param($ServiceName, $FallbackDirectory) return [pscustomobject]@{ Directory = 'self-test'; Reason = 'self-test' } }
function Get-BRAVOWmiInstance {
    param($ClassName, $Filter)
    if ($ClassName -eq 'Win32_OperatingSystem' -and $script:ProbeBootTimeUnreadable) { throw 'self-test: WMI недоступний' }
    if ($ClassName -eq 'Win32_Process') {
        if ($script:ProbeProcessQueryFails) { throw 'self-test: Win32_Process недоступний' }
        return @($script:ProbeProcesses)
    }
    return [pscustomobject]@{ LastBootUpTime = (Get-Date).AddMinutes(-[int]$script:ProbeUptimeMinutes) }
}
function Get-WinEvent {
    param($FilterHashtable, $MaxEvents, $ErrorAction)
    Add-ProbeEvent 'SCM-READ'
    if ($script:ProbeScmReadFails) { throw 'self-test: журнал System недоступний' }
    return @($script:ProbeScmEvents)
}

$probeNow = [DateTimeOffset]::Now
$probeScenarios = [ordered]@{
    'RSAllRunning' = { }
    'RSExchangeFailed' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'
        $script:ProbeExitCodes['exchangAPI'] = 1067
        $script:ProbeScmEvents = @([pscustomobject]@{ TimeCreated = (Get-Date).AddMinutes(-2); Id = 7034; Message = 'self-test: служба завершилась несподівано'; Properties = @([pscustomobject]@{ Value = 'exchangAPI Display' }, [pscustomobject]@{ Value = '1' }) })
    }
    'RSBravoFailed' = { $script:ProbeServices['BRAVO'] = 'Stopped'; $script:ProbeExitCodes['BRAVO'] = 1067 }
    'RSWebFailed' = { $script:ProbeServices['BravoWeb'] = 'Stopped' }
    'RSBravoAndWebFailed' = { $script:ProbeServices['BRAVO'] = 'Stopped'; $script:ProbeServices['BravoWeb'] = 'Stopped' }
    'RSExchangeAndWebFailed' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeServices['BravoWeb'] = 'Stopped' }
    'RSBravoFailedExchangePaused' = { $script:ProbeServices['BRAVO'] = 'Stopped'; $script:ProbeServices['exchangAPI'] = 'Paused' }
    'RSPausedOnly' = { $script:ProbeServices['exchangAPI'] = 'Paused' }
    'RSDisabledBravoDependent' = {
        $script:ProbeServices['BRAVO'] = 'Stopped'; $script:ProbeStartModes['BRAVO'] = 'Disabled'
        $script:ProbeServices['exchangAPI'] = 'Stopped'
        $script:ProbeSeedBravoDisabled = $true
    }
    'RSLockBusy' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeLockBusy = $true }
    'RSLockBusyMaintenance' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeLockBusy = $true
        $script:ProbeLockHolder = [pscustomobject]@{ Operation = 'Maintenance'; Pid = 4242; ProcessStartTime = 'self-test-start'; HostName = [Environment]::MachineName; StartedAt = ''; GenerationId = ''; Description = 'operation=Maintenance; pid=4242' }
    }
    'RSLockBusyArchive' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeLockBusy = $true
        $script:ProbeLockHolder = [pscustomobject]@{ Operation = 'Archive'; Pid = 4242; ProcessStartTime = 'self-test-start'; HostName = [Environment]::MachineName; StartedAt = ''; GenerationId = ''; Description = 'operation=Archive; pid=4242' }
    }
    'RSLockBusyArchiveNightlyMaintenance' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeLockBusy = $true; $script:ProbeLockHolder = $script:ProbeArchiveHolder
        $script:ProbeProcesses = @($script:ProbeProcesses) + @([pscustomobject]@{ ProcessId = 5151; CommandLine = 'powershell.exe -NoProfile -File "C:\BRAVO\BRAVO_MAINTENANCE.ps1" -NoPause' })
    }
    'RSLockBusyArchiveDataRestore' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeLockBusy = $true; $script:ProbeLockHolder = $script:ProbeArchiveHolder
        $script:ProbeProcesses = @($script:ProbeProcesses) + @([pscustomobject]@{ ProcessId = 5252; CommandLine = 'powershell.exe -File C:\BRAVO\BRAVO_DATA_RESTORE.ps1 -NoPause' })
    }
    'RSLockBusyArchiveUnreadableProcess' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeLockBusy = $true; $script:ProbeLockHolder = $script:ProbeArchiveHolder
        $script:ProbeProcesses = @($script:ProbeProcesses) + @([pscustomobject]@{ ProcessId = 5353; CommandLine = $null })
    }
    'RSLockBusyArchiveNotArchiveProcess' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeLockBusy = $true; $script:ProbeLockHolder = $script:ProbeArchiveHolder
        $script:ProbeProcesses = @([pscustomobject]@{ ProcessId = 4242; CommandLine = 'powershell.exe -File C:\Tools\other.ps1' })
    }
    'RSLockBusyArchiveProcessQueryFails' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeLockBusy = $true; $script:ProbeLockHolder = $script:ProbeArchiveHolder; $script:ProbeProcessQueryFails = $true
    }
    'RSLockBusyArchiveHolderChanged' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeLockBusy = $true; $script:ProbeLockHolder = $script:ProbeArchiveHolder
        $script:ProbeLockHolderRecheck = [pscustomobject]@{ Operation = 'Maintenance'; Pid = 5151; ProcessStartTime = 'self-test-start-2'; HostName = [Environment]::MachineName; StartedAt = 'later'; GenerationId = ''; Description = 'operation=Maintenance; pid=5151' }
    }
    'RSLockBusyArchiveSiblingRecover' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeLockBusy = $true; $script:ProbeLockHolder = $script:ProbeArchiveHolder
        $script:ProbeProcesses = @($script:ProbeProcesses) + @([pscustomobject]@{ ProcessId = 6161; CommandLine = 'powershell.exe -File "C:\BRAVO\BRAVO_MAINTENANCE.ps1" -RecoverServices -NoPause' })
    }
    'RSLockBusyArchiveMarkerTakenOver' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeLockBusy = $true; $script:ProbeLockHolder = $script:ProbeArchiveHolder; $script:ProbeMarkerTakenOverDuringLogs = $true
    }
    'RSLockBusyArchiveDead' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeLockBusy = $true; $script:ProbeLockHolderAlive = $false
        $script:ProbeLockHolder = [pscustomobject]@{ Operation = 'Archive'; Pid = 4242; ProcessStartTime = 'self-test-start'; HostName = [Environment]::MachineName; StartedAt = ''; GenerationId = ''; Description = 'operation=Archive; pid=4242' }
    }
    'RSBootGrace' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeUptimeMinutes = 5 }
    'RSBootHoldDelay' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeUptimeMinutes = 25; $script:ProbeBootRestoreMode = 'HoldServices'; $script:ProbeStartupDelay = 30; $script:ProbeRestorePending = $false }
    'RSBootHoldPendingRestore' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeUptimeMinutes = 30; $script:ProbeBootRestoreMode = 'HoldServices'; $script:ProbeStartupDelay = 7; $script:ProbeRestorePending = $true }
    'RSBootHoldBootTimeUnknown' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeBootTimeUnreadable = $true; $script:ProbeBootRestoreMode = 'HoldServices'; $script:ProbeStartupDelay = 7; $script:ProbeRestorePending = $false }
    'RSBootHoldElapsed' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeUptimeMinutes = 180; $script:ProbeBootRestoreMode = 'HoldServices'; $script:ProbeStartupDelay = 7; $script:ProbeRestorePending = $false }
    'RSBootTimeUnknownNoHold' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeBootTimeUnreadable = $true }
    'RSOrphanOwnMarker' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'
        $script:ProbeMarkerNames = @('exchangAPI')
        $script:ProbeForeignContext = [pscustomobject]@{ Present = $true; OwnerAlive = $false; Owner = 'BRAVO_MAINTENANCE_RECOVER'; RestartSuppressed = $false; RestartIntentNames = @('exchangAPI'); HeldSnapshot = @() }
    }
    'RSOrphanForeignMarker' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'
        $script:ProbeMarkerNames = @('exchangAPI')
        $script:ProbeForeignContext = [pscustomobject]@{ Present = $true; OwnerAlive = $false; Owner = 'BRAVO_MAINTENANCE'; RestartSuppressed = $false; RestartIntentNames = @('exchangAPI'); HeldSnapshot = @() }
    }
    'RSPauseNotElapsed' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'
        $script:ProbeStateSeed = ([ordered]@{ schemaVersion = 1; hostname = [Environment]::MachineName; services = [ordered]@{ exchangAPI = [ordered]@{ attempts = @($probeNow.AddMinutes(-1).ToString('o')); lastCriticalAt = $null; stableSince = $null } } } | ConvertTo-Json -Depth 6)
    }
    'RSCyclicThirdAttempt' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'
        $script:ProbeStateSeed = ([ordered]@{ schemaVersion = 1; hostname = [Environment]::MachineName; services = [ordered]@{ exchangAPI = [ordered]@{ attempts = @($probeNow.AddHours(-2).ToString('o'), $probeNow.AddMinutes(-30).ToString('o')); lastCriticalAt = $null; stableSince = $null } } } | ConvertTo-Json -Depth 6)
    }
    'RSStableCounterReset' = {
        $script:ProbeStateSeed = ([ordered]@{ schemaVersion = 1; hostname = [Environment]::MachineName; services = [ordered]@{ exchangAPI = [ordered]@{ attempts = @($probeNow.AddMinutes(-50).ToString('o')); lastCriticalAt = $null; stableSince = $probeNow.AddMinutes(-40).ToString('o') } } } | ConvertTo-Json -Depth 6)
    }
    'RSSuppressedMarker' = {
        $script:ProbeServices['BRAVO'] = 'Stopped'; $script:ProbeServices['exchangAPI'] = 'Stopped'
        $script:ProbeMarkerNames = @('BRAVO')
        $script:ProbeForeignContext = [pscustomobject]@{ Present = $true; OwnerAlive = $false; Owner = 'BRAVO_MAINTENANCE'; RestartSuppressed = $true; RestartIntentNames = @('BRAVO'); HeldSnapshot = @() }
    }
    'RSForeignOwnerAlive' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'
        $script:ProbeForeignContext = [pscustomobject]@{ Present = $true; OwnerAlive = $true; Owner = 'BRAVO_DATA_RESTORE'; RestartSuppressed = $false; RestartIntentNames = @(); HeldSnapshot = @() }
    }
    'RSIntegrityGateClosed' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:modelIntegrityEstablished = $false }
    'RSMarkerWriteFails' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeMarkerWriteFails = $true }
    'RSStartFails' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeStartFailures = @('exchangAPI') }
    'RSRotationErrorCritical' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeExchangeRotationErrors = 1 }
    'RSStopTimeoutStillRunning' = { $script:ProbeServices['BRAVO'] = 'Stopped'; $script:ProbeStopFailures = @('exchangAPI') }
    'RSDependentStartedExternally' = { $script:ProbeServices['BRAVO'] = 'Stopped'; $script:ProbeExternalStartDuringLogs = $true }
    'RSUnexpectedException' = {
        $script:ProbeServices['exchangAPI'] = 'Stopped'
        $script:ProbeScmEvents = @([pscustomobject]@{ TimeCreated = 'self-test: не дата'; Id = 7034; Message = 'self-test'; Properties = @([pscustomobject]@{ Value = 'exchangAPI' }) })
    }
    'RSScmReadFails' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeScmReadFails = $true }
    'RSConflictForceRestore' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeForceRestore = $true }
    'RSConflictRunMissedRestoreOnly' = { $script:ProbeServices['exchangAPI'] = 'Stopped'; $script:ProbeRunMissedRestoreOnly = $true }
}
foreach ($probeScenarioName in @($probeScenarios.Keys)) {
    $probeScenarioRoot = Join-Path $ProbeRoot $probeScenarioName
    [void][IO.Directory]::CreateDirectory($probeScenarioRoot)
    $probeResults[$probeScenarioName] = & {
        param([string]$ScenarioRoot, [scriptblock]$ScenarioSeed)
        try {
            $script:ProbeEvents = New-Object System.Collections.Generic.List[string]
            $script:ScriptStartTime = Get-Date
            $script:BRAVOWarningCount = 0
            $script:criticalErrorOccurred = $false
            $script:CriticalErrors = $false
            $script:CriticalErrorsList = New-Object 'System.Collections.Generic.List[string]'
            $script:NotificationAlertQueue = New-Object 'System.Collections.Generic.List[object]'
            $script:maintenanceDeliveredCriticalAlertCount = 0
            $script:maintenanceDeliveredAlertQueueCount = 0
            $script:restoreArchiveFailed = $false
            $script:restoreIntegrityFailed = $false
            $script:restoreFailed = $false
            $script:modelIntegrityEstablished = $true
            $script:maintenanceOperationLock = $null
            $script:maintenanceOperationLockPath = $null
            $script:maintenanceOwnLogUploadAttempted = $false
            $script:bravoServiceStartedThisRun = $false
            $script:SlackMode = 'errors_only'
            $script:NotificationWebhookUrls = @{ alerts = 'https://alerts.example.invalid/hook' }
            $script:LOG_FILE = $null
            $script:ProbeServices = @{ 'BRAVO' = 'Running'; 'exchangAPI' = 'Running'; 'BravoWeb' = 'Running' }
            $script:ProbeStartModes = @{ 'BRAVO' = 'Automatic'; 'exchangAPI' = 'Automatic'; 'BravoWeb' = 'Manual' }
            $script:ProbeExitCodes = @{}
            $script:ProbeMarkerNames = @()
            $script:ProbeStartFailures = @()
            $script:ProbeStopFailures = @()
            $script:ProbeExchangeRotationErrors = 0
            $script:ProbeExternalStartDuringLogs = $false
            $script:ProbeStrayProcesses = @('Bis')
            $script:ProbeLockBusy = $false
            $script:ProbeLockHolder = $null
            $script:ProbeLockHolderAlive = $true
            $script:ProbeLockHolderReads = 0
            $script:ProbeLockHolderRecheck = $null
            $script:ProbeArchiveHolder = [pscustomobject]@{ Operation = 'Archive'; Pid = 4242; ProcessStartTime = 'self-test-start'; HostName = [Environment]::MachineName; StartedAt = 'self-test-started'; GenerationId = ''; Description = 'operation=Archive; pid=4242' }
            $script:ProbeProcesses = @([pscustomobject]@{ ProcessId = 4242; CommandLine = 'powershell.exe -NoProfile -File "C:\BRAVO\BRAVO_ARCHIV.ps1" -NoPause' })
            $script:ProbeProcessQueryFails = $false
            $script:ProbeMarkerState = $null
            $script:ProbeMarkerOwned = $true
            $script:ProbeMarkerTakenOverDuringLogs = $false
            $script:ProbeUptimeMinutes = 180
            $script:ProbeBootTimeUnreadable = $false
            $script:ProbeBootRestoreMode = $null
            $script:ProbeStartupDelay = $null
            $script:ProbeRestorePending = $null
            $script:ProbeMarkerWriteFails = $false
            $script:ProbeScmReadFails = $false
            $script:ProbeScmEvents = @()
            $script:ProbeStateSeed = $null
            $script:ProbeSeedBravoDisabled = $false
            $script:ProbeForceRestore = $false
            $script:ProbeRunMissedRestoreOnly = $false
            $script:ProbeForeignContext = [pscustomobject]@{ Present = $false; OwnerAlive = $false; Owner = $null; RestartSuppressed = $false; RestartIntentNames = @(); HeldSnapshot = @() }
            $script:ProbeStatePath = Join-Path (Join-Path $ScenarioRoot 'state') 'BRAVO_SERVICE_RECOVERY_STATE.json'
            . $ScenarioSeed
            if ($null -ne $script:ProbeStateSeed) {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:ProbeStatePath))
                [IO.File]::WriteAllText($script:ProbeStatePath, [string]$script:ProbeStateSeed, (New-Object Text.UTF8Encoding($false)))
            }

            # Змінні тіла runtime, які профіль і цикл служб читають через динамічний scope.
            $bravoSettings = [pscustomobject]@{ NotificationRouting = $null }
            $BravoServiceName = 'BRAVO'
            $ExchangAPIServiceName = 'exchangAPI'
            $BravoWebServiceName = 'BravoWeb'
            $BravoMaintenanceEnabled = -not $script:ProbeSeedBravoDisabled
            $BravoServiceDisabledBySystem = [bool]$script:ProbeSeedBravoDisabled
            $exchangAPIServiceEnabled = $true
            $exchangAPIServiceDisabled = $false
            $BravoWebMaintenanceEnabled = $true
            $ApacheEnabled = $true
            $LOG_DIR = Join-Path $ScenarioRoot 'logs'
            $ServiceStartTimeoutSeconds = 1
            $ServiceStopTimeoutSeconds = 1
            $ServicePollIntervalSeconds = 1
            $bravoDiscoveryResult = [pscustomobject]@{ BRAVO_ROOT = ''; MODEL_SOURCE = ''; MODEL_PROJECT_FILE = '' }
            $ROOT_LIMS = Join-Path $ScenarioRoot 'lims'
            $TRACE_DIR = Join-Path $ScenarioRoot 'system\Trace'
            $LOG_DATE_FOLDER = 'self-test'
            $MaintenanceConfig = [pscustomobject]@{ Trace = [pscustomobject]@{ BISSourcePath = '' } }
            $EXCHANGE_LOG_DIR = Join-Path $ScenarioRoot 'system\exchangAPI'
            $EXCHANGAPI_LOG_FILTERS = @('exchangAPI*.log')
            $MoveRetryCount = 0
            $MoveRetryDelaySeconds = 0
            $APACHE_LOGS_DIR = Join-Path $ScenarioRoot 'apache\logs'
            $APACHE_DAILY_LOG_DIR = Join-Path $ScenarioRoot 'system\BravoWeb\Apache\daily'
            $APACHE_LOG_FILTER = '*.log'
            $WWW_LOGS_DIR = Join-Path $ScenarioRoot 'www\log'
            $BRAVOWEB_APP_DAILY_LOG_DIR = Join-Path $ScenarioRoot 'system\BravoWeb\Application\daily'
            $BRAVOWEB_APP_LOG_FILTER = '*.log'

            # Профіль HoldServices: налаштування реставрації і стан пропущеної
            # реставрації ($automaticRestoreDue runtime) — лише в сценаріях, що їх задають.
            if ($null -ne $script:ProbeBootRestoreMode) {
                $maintenanceSettings = @{ Restore = @{ BootRestoreMode = $script:ProbeBootRestoreMode; StartupDelayMinutes = $script:ProbeStartupDelay } }
            }
            if ($null -ne $script:ProbeRestorePending) { $automaticRestoreDue = [bool]$script:ProbeRestorePending }

            $probeExitCode = Invoke-BRAVOMaintenanceRecoverServicesProfile -ForceRestore:$script:ProbeForceRestore -RunMissedRestoreOnly:$script:ProbeRunMissedRestoreOnly
            $probeLogFiles = @()
            if (Test-Path -LiteralPath $LOG_DIR -PathType Container) { $probeLogFiles = @([IO.Directory]::GetFiles($LOG_DIR) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object) }
            $probeLogText = ''
            foreach ($probeLogFile in $probeLogFiles) { $probeLogText += [IO.File]::ReadAllText((Join-Path $LOG_DIR $probeLogFile), [Text.Encoding]::UTF8) }
            $probeStateText = ''
            if ([IO.File]::Exists($script:ProbeStatePath)) { $probeStateText = [IO.File]::ReadAllText($script:ProbeStatePath, [Text.Encoding]::UTF8) }
            [pscustomobject]@{
                ExitCode = $probeExitCode
                Events = @($script:ProbeEvents)
                LogFiles = @($probeLogFiles)
                LogText = $probeLogText
                StateText = $probeStateText
                QueuedCritical = $script:CriticalErrorsList.Count
                DeliveredCritical = [int]$script:maintenanceDeliveredCriticalAlertCount
                OwnLogUploadSuppressed = [bool]$script:maintenanceOwnLogUploadAttempted
            }
        } catch {
            [pscustomobject]@{ ProbeError = ('{0} @ {1}' -f $_.Exception.Message, $_.InvocationInfo.PositionMessage) }
        }
    } $probeScenarioRoot $probeScenarios[$probeScenarioName]
}
[IO.File]::WriteAllText((Join-Path $ProbeRoot 'results.json'), ($probeResults | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
'@
        $recoverResults = $null
        $recoverProbeError = ''
        if ($recoverFunctionNames.Count -gt 0) {
            $recoverProbePath = Join-Path $recoverRoot 'probe.ps1'
            [IO.File]::WriteAllText($recoverProbePath, $recoverProbeScript, (New-Object Text.UTF8Encoding($true)))
            $recoverHost = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $null = & $recoverHost -NoLogo -NoProfile -NonInteractive -File $recoverProbePath -RepositoryRoot $root -ProbeRoot $recoverRoot
            $recoverResultsPath = Join-Path $recoverRoot 'results.json'
            if (Test-Path -LiteralPath $recoverResultsPath -PathType Leaf) {
                $recoverResults = [IO.File]::ReadAllText($recoverResultsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($null -ne $recoverResults.PSObject.Properties['ProbeError']) { $recoverProbeError = [string]$recoverResults.ProbeError; $recoverResults = $null }
            } else {
                $recoverProbeError = "проба не записала results.json (код виходу $LASTEXITCODE)"
            }
        } else {
            $recoverProbeError = 'немає BRAVO.Maintenance.RecoverServices.ps1 з функціями профілю'
        }
        Test-BRAVOCondition `
            -Condition ($null -ne $recoverResults) `
            -Name 'ServiceRecovery/RecoverServicesProbeAvailable' `
            -Failure "проба профілю -RecoverServices: $recoverProbeError"

        # Дії профілю (без рядків журналу й консолі) — у порядку виконання.
        $recoverActions = {
            param([string]$Scenario)
            if ($null -eq $recoverResults -or $null -eq $recoverResults.PSObject.Properties[$Scenario]) { return @('<немає результату>') }
            $result = $recoverResults.$Scenario
            if ($null -ne $result.PSObject.Properties['ProbeError']) { return @("<помилка проби: $($result.ProbeError)>") }
            return @(@($result.Events) | ForEach-Object { [string]$_ } | Where-Object { $_ -notlike 'LOG-*' -and $_ -notlike 'HOST *' -and $_ -ne 'ALERT-QUEUED' })
        }
        $recoverCheck = {
            param([string]$Scenario, [int]$ExpectedExitCode, [string[]]$ExpectedActions, [string]$LogFilePattern, [scriptblock]$Extra, [string]$Name, [string]$Meaning)
            $result = $null
            if ($null -ne $recoverResults -and $null -ne $recoverResults.PSObject.Properties[$Scenario]) { $result = $recoverResults.$Scenario }
            $actualActions = @(& $recoverActions $Scenario)
            $actualExitCode = $null
            $logFiles = @()
            $extraOk = $false
            if ($null -ne $result -and $null -eq $result.PSObject.Properties['ProbeError']) {
                $actualExitCode = [int]$result.ExitCode
                $logFiles = @($result.LogFiles | ForEach-Object { [string]$_ })
                $extraOk = [bool](& $Extra $result)
            }
            $logFilesOk = if ([string]::IsNullOrEmpty($LogFilePattern)) { $logFiles.Count -eq 0 } else { $logFiles.Count -eq 1 -and $logFiles[0] -cmatch $LogFilePattern }
            Test-BRAVOCondition `
                -Condition ($actualExitCode -eq $ExpectedExitCode -and ($actualActions -join ' | ') -ceq ($ExpectedActions -join ' | ') -and $logFilesOk -and $extraOk) `
                -Name $Name `
                -Failure "$Meaning. Код: очікувався $ExpectedExitCode, отримано $actualExitCode; дії: очікувались [$($ExpectedActions -join ' | ')], отримано [$($actualActions -join ' | ')]; файли журналу: [$($logFiles -join ', ')] (очікувались: '$LogFilePattern'); додаткові умови: $extraOk; події: $(if ($null -ne $result -and $null -ne $result.PSObject.Properties['Events']) { @($result.Events) -join ' || ' })"
        }
        $recoverLogName = '^BRAVO_MAINTENANCE_\d{8}_\d{6}_RECOVER_PID\d+\.log$'
        $recoverOk = { param($Result) $true }
        $recoverLock = 'LOCK-ENTER NoWait=True'
        $recoverMarker = { param([string[]]$Names) 'MARKER-WRITE BRAVO_MAINTENANCE_RECOVER ' + (@($Names | ForEach-Object { "$_=True" }) -join ',') }
        $recoverRecovered = 'NOTIFY WARNING|СЛУЖБУ BRAVO ВІДНОВЛЕНО'
        $recoverFailed = 'NOTIFY CRITICAL|СЛУЖБУ BRAVO НЕ ВДАЛОСЯ ПІДНЯТИ'
        $recoverStateCount = {
            param($Result, [string]$ServiceName)
            if ([string]::IsNullOrWhiteSpace([string]$Result.StateText)) { return 0 }
            $stateObject = [string]$Result.StateText | ConvertFrom-Json
            $entry = $stateObject.services.PSObject.Properties[$ServiceName]
            if ($null -eq $entry) { return 0 }
            return @($entry.Value.attempts).Count
        }

        # Крок 1: усі служби працюють — нічого не робиться, файлу журналу немає.
        & $recoverCheck 'RSAllRunning' 0 @() '' { param($Result) @($Result.Events) -contains 'HOST Відновлення служб: впалих керованих служб немає' } `
            'ServiceRecovery/RecoverServicesFastExitWithoutLogFile' `
            '#314 FR-3 крок 1: жодної впалої служби — код 0 без lock-а, без файлу журналу і без сповіщень'
        & $recoverCheck 'RSPausedOnly' 0 @() '' $recoverOk `
            'ServiceRecovery/RecoverServicesPausedServiceNotStarted' `
            '#314 FR-3: призупинена служба (Paused) профілем не запускається і не вважається впалою — швидкий вихід'
        & $recoverCheck 'RSDisabledBravoDependent' 0 @() '' $recoverOk `
            'ServiceRecovery/RecoverServicesDependentOfDisabledBravoIgnored' `
            '#314 FR-3/#321: exchangAPI при BRAVO з типом запуску Disabled не піднімається — швидкий вихід без журналу й сповіщень'

        # ТЗ §6 п. 2: ланцюжки через справжній цикл служб.
        & $recoverCheck 'RSExchangeFailed' 0 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('exchangAPI'))
            'EXCHANGE-ROTATION'; 'START exchangAPI'; 'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered; 'LOCK-EXIT'
        ) $recoverLogName {
            param($Result)
            ([string]$Result.LogText).Contains('Служба exchangAPI: StartMode=Automatic; Status=Stopped; ExitCode=1067; ServiceSpecificExitCode=0') -and
            ([string]$Result.LogText).Contains('Події Service Control Manager з ') -and
            ([string]$Result.LogText) -match '\[INFO\] Подія 7034 [0-9-]{10} [0-9:]{8} \[exchangAPI Display\]: self-test: служба завершилась несподівано' -and
            (& $recoverStateCount $Result 'exchangAPI') -eq 1 -and [bool]$Result.OwnLogUploadSuppressed
        } 'ServiceRecovery/RecoverServicesExchangeApiOnly' `
            '#314 FR-3: впала exchangAPI — lock без очікування, докази (StartMode, Status, ExitCode, подія SCM) у журналі _RECOVER_PID, маркер BRAVO_MAINTENANCE_RECOVER, її журнали, запуск лише exchangAPI, облік спроби, маркер прибрано, WARNING «відновлено»'
        & $recoverCheck 'RSBravoFailed' 0 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('BRAVO', 'exchangAPI', 'BravoWeb'))
            'STOP BravoWeb'; 'STOP exchangAPI'
            'TRACE-ROTATION'; 'EXCHANGE-ROTATION'; 'APACHE-ROTATION'; 'WEBAPP-ROTATION'
            'START BRAVO'; 'START exchangAPI'; 'START BravoWeb'
            'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered; 'LOCK-EXIT'
        ) $recoverLogName {
            param($Result)
            (& $recoverStateCount $Result 'BRAVO') -eq 1 -and (& $recoverStateCount $Result 'exchangAPI') -eq 0 -and (& $recoverStateCount $Result 'BravoWeb') -eq 0
        } 'ServiceRecovery/RecoverServicesBravoChain' `
            '#314 FR-3: впала BRAVO — спершу зупинка працюючих BRAVO Web і exchangAPI (Bis не чіпається: BRAVO вже зупинена), журнали всіх трьох, запуск BRAVO -> exchangAPI -> BRAVO Web; спроба рахується лише для BRAVO'
        & $recoverCheck 'RSWebFailed' 0 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('BravoWeb'))
            'APACHE-ROTATION'; 'WEBAPP-ROTATION'; 'START BravoWeb'; 'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered; 'LOCK-EXIT'
        ) $recoverLogName $recoverOk 'ServiceRecovery/RecoverServicesBravoWebOnly' `
            '#314 FR-3: впала BRAVO Web — лише її журнали й запуск'
        & $recoverCheck 'RSBravoAndWebFailed' 0 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('BRAVO', 'exchangAPI', 'BravoWeb'))
            'STOP exchangAPI'
            'TRACE-ROTATION'; 'EXCHANGE-ROTATION'; 'APACHE-ROTATION'; 'WEBAPP-ROTATION'
            'START BRAVO'; 'START exchangAPI'; 'START BravoWeb'
            'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered; $recoverRecovered; 'LOCK-EXIT'
        ) $recoverLogName {
            param($Result) (& $recoverStateCount $Result 'BRAVO') -eq 1 -and (& $recoverStateCount $Result 'BravoWeb') -eq 1 -and (& $recoverStateCount $Result 'exchangAPI') -eq 0
        } 'ServiceRecovery/RecoverServicesBravoAndWebUnion' `
            '#314 FR-3: впали BRAVO і BRAVO Web — об''єднання ланцюжків: зупинка лише працюючої exchangAPI, запуск у канонічному порядку, дві спроби й два сповіщення'
        & $recoverCheck 'RSExchangeAndWebFailed' 0 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('exchangAPI', 'BravoWeb'))
            'EXCHANGE-ROTATION'; 'APACHE-ROTATION'; 'WEBAPP-ROTATION'
            'START exchangAPI'; 'START BravoWeb'
            'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered; $recoverRecovered; 'LOCK-EXIT'
        ) $recoverLogName $recoverOk 'ServiceRecovery/RecoverServicesExchangeApiAndWebUnion' `
            '#314 FR-3: впали exchangAPI і BRAVO Web — без зупинок, запуск exchangAPI -> BRAVO Web'
        & $recoverCheck 'RSBravoFailedExchangePaused' 0 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('BRAVO', 'BravoWeb'))
            'STOP BravoWeb'
            'TRACE-ROTATION'; 'APACHE-ROTATION'; 'WEBAPP-ROTATION'
            'START BRAVO'; 'START BravoWeb'
            'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered; 'LOCK-EXIT'
        ) $recoverLogName {
            param($Result) ([string]$Result.LogText).Contains('[INFO] Служба exchangAPI у стані Paused — профіль її не запускає, стан збережено')
        } 'ServiceRecovery/RecoverServicesBravoChainKeepsPausedService' `
            '#314 FR-3: призупинена exchangAPI не зупиняється й не запускається при відновленні BRAVO (INFO у журнал)'

        # Крок 2: пауза не минула — код 0, без lock-а, лише рядок INFO у добовий файл.
        & $recoverCheck 'RSPauseNotElapsed' 0 @() '^BRAVO_MAINTENANCE_\d{8}_RECOVER_PAUSE\.log$' {
            param($Result) ([string]$Result.LogText) -match '\[INFO\] Відновлення служб відкладено: пауза між спробами ще не минула — exchangAPI \(спроб за добу: 1, пауза 5 хв'
        } 'ServiceRecovery/RecoverServicesPauseNotElapsed' `
            '#314 FR-3 крок 2 / FR-5: пауза для всіх впалих служб не минула — код 0 без lock-а і без змін, рядок INFO у BRAVO_MAINTENANCE_<дата>_RECOVER_PAUSE.log'

        # ТЗ §6 п. 5: lock зайнятий — код 20, без змін і сповіщень. Рев'ю PR
        # #432 (B-P2-2) свідомо змінило очікування: рядок INFO з власником
        # lock-а тепер пишеться в добовий RECOVER_PAUSE.log (раніше — лише
        # консоль), окремого журналу прогону, як і раніше, немає.
        $recoverPauseLogName = '^BRAVO_MAINTENANCE_\d{8}_RECOVER_PAUSE\.log$'
        & $recoverCheck 'RSLockBusy' 20 @('LOCK-BUSY') $recoverPauseLogName {
            param($Result) ([string]$Result.LogText).Contains('[INFO] Відновлення служб відкладено: операційний lock зайнятий (self-test-lock); тримає: невідомо; служби не змінювались')
        } 'ServiceRecovery/RecoverServicesLockBusy' `
            '#314 FR-3 крок 3 (ТЗ §6 п. 5): lock зайнятий, власник невідомий — код 20, жодної зупинки чи запуску, без сповіщення; рядок INFO у RECOVER_PAUSE.log'
        & $recoverCheck 'RSLockBusyMaintenance' 20 @('LOCK-BUSY') $recoverPauseLogName {
            param($Result) ([string]$Result.LogText).Contains('тримає: operation=Maintenance; pid=4242; служби не змінювались')
        } 'ServiceRecovery/RecoverServicesLockBusyNamesHolder' `
            "Рев'ю PR #432 (B-P2-2): lock тримає нічний Maintenance — код 20, без змін, у рядку INFO названо операцію власника"
        & $recoverCheck 'RSLockBusyArchive' 0 @(
            'LOCK-BUSY'; 'SCM-READ'; (& $recoverMarker @('exchangAPI'))
            'EXCHANGE-ROTATION'; 'START exchangAPI'; 'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered
        ) $recoverLogName {
            param($Result) ([string]$Result.LogText).Contains('[INFO] Операційний lock (self-test-lock) тримає BRAVO_ARCHIV (operation=Archive; pid=4242): він служб не зупиняє — відновлення виконується без lock-а')
        } 'ServiceRecovery/RecoverServicesUnderArchiveLock' `
            "Рев'ю PR #432 (B-P2-2): lock тримає живий BRAVO_ARCHIV цього хоста — служба відновлюється без lock-а (маркер, state, FR-6), чужий lock не звільняється"
        # Рев'ю PR #432 (Codex P1): метадані lock-а можуть бути застарілими —
        # обхід лише за підтвердженого володіння BRAVO_ARCHIV; будь-яка
        # невизначеність — код 20 без змін, причина в рядку INFO.
        $recoverBypassDenied = {
            param([string]$Scenario, [string]$ReasonText, [string]$Name, [string]$Meaning)
            $bypassExpectedText = 'тримає: operation=Archive; pid=4242; відновлення без lock-а не підтверджено: ' + $ReasonText + '; служби не змінювались'
            $bypassExtra = { param($Result) ([string]$Result.LogText).Contains($bypassExpectedText) }.GetNewClosure()
            & $recoverCheck $Scenario 20 @('LOCK-BUSY') $recoverPauseLogName $bypassExtra $Name $Meaning
        }
        & $recoverBypassDenied 'RSLockBusyArchiveNightlyMaintenance' 'виконується BRAVO_MAINTENANCE (pid=5151)' `
            'ServiceRecovery/RecoverServicesArchiveLockNightlyMaintenanceRunningFailClosed' `
            "Рев'ю PR #432 (Codex P1): запис lock-а — живий Archive, але вже працює нічний BRAVO_MAINTENANCE (новий власник lock-а ще не переписав метадані) — код 20 без змін"
        & $recoverBypassDenied 'RSLockBusyArchiveDataRestore' 'виконується BRAVO_DATA_RESTORE (pid=5252)' `
            'ServiceRecovery/RecoverServicesArchiveLockDataRestoreRunningFailClosed' `
            "Рев'ю PR #432 (Codex P1): запис lock-а — живий Archive, але працює BRAVO_DATA_RESTORE — код 20 без змін"
        & $recoverBypassDenied 'RSLockBusyArchiveUnreadableProcess' 'командний рядок процесу PowerShell pid=5353 не прочитано' `
            'ServiceRecovery/RecoverServicesArchiveLockUnreadableCommandLineFailClosed' `
            "Рев'ю PR #432 (Codex P1): командний рядок іншого процесу PowerShell не прочитано — невизначеність, код 20"
        & $recoverBypassDenied 'RSLockBusyArchiveNotArchiveProcess' 'процес pid=4242 не є BRAVO_ARCHIV' `
            'ServiceRecovery/RecoverServicesArchiveLockHolderNotArchiveProcessFailClosed' `
            "Рев'ю PR #432 (Codex P1): живий pid із запису Archive виконує не BRAVO_ARCHIV.ps1 — код 20"
        & $recoverBypassDenied 'RSLockBusyArchiveProcessQueryFails' 'список процесів PowerShell не прочитано' `
            'ServiceRecovery/RecoverServicesArchiveLockProcessQueryFailureFailClosed' `
            "Рев'ю PR #432 (Codex P1): запит Win32_Process не вдався — код 20"
        & $recoverBypassDenied 'RSLockBusyArchiveHolderChanged' 'метадані власника змінилися під час перевірки' `
            'ServiceRecovery/RecoverServicesArchiveLockHolderChangedFailClosed' `
            "Рев'ю PR #432 (Codex P1): повторне читання власника після паузи дає інший запис — код 20"
        & $recoverCheck 'RSLockBusyArchiveSiblingRecover' 0 @(
            'LOCK-BUSY'; 'SCM-READ'; (& $recoverMarker @('exchangAPI'))
            'EXCHANGE-ROTATION'; 'START exchangAPI'; 'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered
        ) $recoverLogName $recoverOk 'ServiceRecovery/RecoverServicesArchiveLockIgnoresOtherRecoverProfile' `
            "Рев'ю PR #432 (Codex P1): інший процес BRAVO_MAINTENANCE.ps1 -RecoverServices не є нічним Maintenance — підтверджений Archive дозволяє відновлення без lock-а"
        & $recoverCheck 'RSLockBusyArchiveMarkerTakenOver' 10 @(
            'LOCK-BUSY'; 'SCM-READ'; (& $recoverMarker @('exchangAPI'))
            'EXCHANGE-ROTATION'; 'MARKER-CLEAR'
        ) $recoverLogName {
            param($Result)
            ([string]$Result.LogText).Contains('[WARNING] Ownership-маркер більше не належить профілю -RecoverServices (його перейняв інший власник) — запуск служб скасовано') -and
            @($Result.Events | Where-Object { ([string]$_) -like 'NOTIFY *' }).Count -eq 0
        } 'ServiceRecovery/RecoverServicesWithoutLockStopsWhenMarkerTakenOver' `
            "Рев'ю PR #432 (Codex P1): без lock-а маркер перейняв інший власник (нічний Maintenance) — служба не запускається, WARNING і код 10"
        & $recoverCheck 'RSLockBusyArchiveDead' 20 @('LOCK-BUSY') $recoverPauseLogName $recoverOk `
            'ServiceRecovery/RecoverServicesArchiveLockDeadHolderFailClosed' `
            "Рев'ю PR #432 (B-P2-2): lock із записом Archive, але процес власника не живий — fail-closed, код 20 без змін"
        # Рев'ю PR #432 (A-P3-4 / B-P3-3): перші 9 хв після старту ОС служби
        # піднімає boot-тригер — профіль нічого не змінює, код 0.
        & $recoverCheck 'RSBootGrace' 0 @() $recoverPauseLogName {
            param($Result) ([string]$Result.LogText).Contains('[INFO] Відновлення служб відкладено: ОС працює менше 9 хв')
        } 'ServiceRecovery/RecoverServicesBootGrace' `
            "Рев'ю PR #432 (A-P3-4): ОС працює 5 хв — профіль без lock-а і без змін виходить з кодом 0, рядок INFO у RECOVER_PAUSE.log"
        # Рев'ю PR #432 (Codex P1): на профілі HoldServices вікно виводиться із
        # затримки boot-тригера Recovery (Restore.StartupDelayMinutes) і стану
        # пропущеної реставрації; час старту ОС не прочитано — fail-closed.
        & $recoverCheck 'RSBootHoldDelay' 0 @() $recoverPauseLogName {
            param($Result) ([string]$Result.LogText).Contains('[INFO] Відновлення служб відкладено: ОС працює менше 40 хв (профіль HoldServices: затримка boot-тригера Recovery 30 хв + запас 10 хв)')
        } 'ServiceRecovery/RecoverServicesBootGraceFollowsHoldServicesDelay' `
            "Рев'ю PR #432 (Codex P1): HoldServices із затримкою boot-тригера 30 хв, ОС працює 25 хв — профіль не випереджає boot-реставрацію: код 0 без змін, вікно 30 + 10 хв"
        & $recoverCheck 'RSBootHoldPendingRestore' 0 @() $recoverPauseLogName {
            param($Result) ([string]$Result.LogText).Contains('[INFO] Відновлення служб відкладено: ОС працює менше 67 хв (профіль HoldServices: затримка boot-тригера Recovery 7 хв + запас 60 хв, пропущена реставрація ще чекає)')
        } 'ServiceRecovery/RecoverServicesBootGraceExtendedWhileRestorePending' `
            "Рев'ю PR #432 (Codex P1): HoldServices і пропущена реставрація ще чекає — вікно довше (затримка + 60 хв), ОС працює 30 хв — код 0 без змін"
        & $recoverCheck 'RSBootHoldBootTimeUnknown' 0 @() $recoverPauseLogName {
            param($Result) ([string]$Result.LogText).Contains('[INFO] Відновлення служб відкладено: час старту ОС не визначено (профіль HoldServices')
        } 'ServiceRecovery/RecoverServicesHoldServicesUnknownBootTimeFailClosed' `
            "Рев'ю PR #432 (Codex P1): HoldServices, час старту ОС не прочитано — fail-closed: тик пропущено (код 0, INFO), служби не змінювались"
        & $recoverCheck 'RSBootHoldElapsed' 0 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('exchangAPI'))
            'EXCHANGE-ROTATION'; 'START exchangAPI'; 'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered; 'LOCK-EXIT'
        ) $recoverLogName $recoverOk 'ServiceRecovery/RecoverServicesHoldServicesAfterGraceRecovers' `
            "Рев'ю PR #432 (Codex P1): HoldServices, вікно після старту ОС минуло — служба відновлюється як звичайно"
        & $recoverCheck 'RSBootTimeUnknownNoHold' 0 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('exchangAPI'))
            'EXCHANGE-ROTATION'; 'START exchangAPI'; 'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered; 'LOCK-EXIT'
        ) $recoverLogName $recoverOk 'ServiceRecovery/RecoverServicesUnknownBootTimeWithoutHoldRecovers' `
            "Рев'ю PR #432 (Codex P1): профіль без HoldServices, час старту ОС не прочитано — як і раніше, відновлення не відкладається"
        # Рев'ю PR #432 (B-P3-1): осиротілий маркер власного профілю переймається.
        & $recoverCheck 'RSOrphanOwnMarker' 0 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('exchangAPI'))
            'EXCHANGE-ROTATION'; 'START exchangAPI'; 'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered; 'LOCK-EXIT'
        ) $recoverLogName {
            param($Result) ([string]$Result.LogText).Contains('[INFO] Перейнято ownership-маркер аварійно перерваного прогону BRAVO_MAINTENANCE_RECOVER: служби exchangAPI')
        } 'ServiceRecovery/RecoverServicesTakesOverOwnOrphanedMarker' `
            "Рев'ю PR #432 (B-P3-1): маркер BRAVO_MAINTENANCE_RECOVER мертвого процесу (без restartSuppressed і знімка) — служба знову впала, профіль її піднімає"
        & $recoverCheck 'RSOrphanForeignMarker' 0 @() '' {
            param($Result) @($Result.Events) -contains 'HOST Відновлення служб: впалих керованих служб немає'
        } 'ServiceRecovery/RecoverServicesLeavesForeignOrphanedMarker' `
            "Рев'ю PR #432 (B-P3-1): маркер мертвого нічного Maintenance не переймається — службою займається Health-watchdog"

        # ТЗ §6 п. 6: restartSuppressed чужого маркера і гейт цілісності моделі.
        & $recoverCheck 'RSSuppressedMarker' 10 @($recoverLock; 'LOCK-EXIT') $recoverLogName {
            param($Result) ([string]$Result.LogText).Contains('[WARNING] Попередній прогін BRAVO_MAINTENANCE перервано посеред реставрації (restartSuppressed)')
        } 'ServiceRecovery/RecoverServicesRestartSuppressedNotStarted' `
            '#314 FR-3 (ТЗ §6 п. 6): маркер з restartSuppressed — служби не запускаються, маркер не перезаписується, WARNING і код 10, без сповіщень'
        & $recoverCheck 'RSIntegrityGateClosed' 10 @($recoverLock; 'LOCK-EXIT') $recoverLogName {
            param($Result) ([string]$Result.LogText).Contains('[WARNING] Цілісність моделі не встановлено — служби не запускаються (#314)')
        } 'ServiceRecovery/RecoverServicesIntegrityGateNotStarted' `
            '#314 FR-3 (ТЗ §6 п. 6): цілісність моделі не встановлено — служби не запускаються'
        & $recoverCheck 'RSForeignOwnerAlive' 0 @($recoverLock; 'LOCK-EXIT') $recoverLogName {
            param($Result) ([string]$Result.LogText).Contains('[INFO] Службами розпоряджається BRAVO_DATA_RESTORE')
        } 'ServiceRecovery/RecoverServicesForeignOwnerNotDisturbed' `
            '#314 FR-3: чинний маркер іншого власника (DataRestore) — профіль не втручається'

        # Збій запису маркера — abort (fail-closed), код 60, CRITICAL.
        & $recoverCheck 'RSMarkerWriteFails' 60 @($recoverLock; 'SCM-READ'; 'MARKER-WRITE-FAIL'; $recoverFailed; 'LOCK-EXIT') $recoverLogName $recoverOk `
            'ServiceRecovery/RecoverServicesMarkerWriteFailureAborts' `
            '#314 FR-3 крок 6: збій запису ownership-маркера — жодної зупинки чи запуску, CRITICAL і код 60'
        & $recoverCheck 'RSStartFails' 60 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('exchangAPI'))
            'EXCHANGE-ROTATION'; 'START-FAIL exchangAPI'; 'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverFailed; 'LOCK-EXIT'
        ) $recoverLogName {
            param($Result) (& $recoverStateCount $Result 'exchangAPI') -eq 1 -and [int]$Result.QueuedCritical -gt 0 -and [int]$Result.DeliveredCritical -eq [int]$Result.QueuedCritical
        } 'ServiceRecovery/RecoverServicesStartFailureCritical' `
            '#314 FR-3/FR-6: служба не стартувала — спроба рахується, CRITICAL «не вдалося підняти» і код 60; загальні критичні алерти циклу не дублюються страховкою runtime'
        # Рев'ю PR #432 (B-P2-1): критична помилка без FR-6 Failed (збій ротації
        # журналу) — окреме CRITICAL прогону, а не лише WARNING «відновлено».
        $recoverRunCritical = 'NOTIFY CRITICAL|ВІДНОВЛЕННЯ СЛУЖБ BRAVO: КРИТИЧНІ ПОМИЛКИ'
        & $recoverCheck 'RSRotationErrorCritical' 60 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('exchangAPI'))
            'EXCHANGE-ROTATION'; 'START exchangAPI'; 'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered; 'LOCK-EXIT'; $recoverRunCritical
        ) $recoverLogName {
            param($Result) [int]$Result.DeliveredCritical -eq [int]$Result.QueuedCritical
        } 'ServiceRecovery/RecoverServicesUncoveredCriticalDelivered' `
            "Рев'ю PR #432 (B-P2-1): збій ротації журналу (код 60) — служба піднята (WARNING «відновлено»), а критична помилка прогону доставлена окремим CRITICAL; лічильник доставлених не завищується"
        # Рев'ю PR #432 (B-P3-6): зупинка exchangAPI завершилась таймаутом, служба
        # лишилась Running — CRITICAL про збій зупинки, без хибного «зупинено,
        # але не запущено»; маркер прибрано.
        & $recoverCheck 'RSStopTimeoutStillRunning' 60 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('BRAVO', 'exchangAPI', 'BravoWeb'))
            'STOP BravoWeb'; 'STOP-FAIL exchangAPI'
            'TRACE-ROTATION'; 'APACHE-ROTATION'; 'WEBAPP-ROTATION'
            'START BRAVO'; 'START BravoWeb'
            'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered; 'LOCK-EXIT'; $recoverRunCritical
        ) $recoverLogName {
            param($Result) @($Result.Events | Where-Object { ([string]$_) -like 'NOTIFY CRITICAL|СЛУЖБУ BRAVO НЕ ВДАЛОСЯ ПІДНЯТИ*' }).Count -eq 0
        } 'ServiceRecovery/RecoverServicesStopTimeoutNoFalseCritical' `
            "Рев'ю PR #432 (B-P3-6): таймаут зупинки залежної служби, яка лишилась Running — CRITICAL про збій зупинки (код 60), без хибного «зупинено, але не запущено»"
        # Рев'ю PR #432 (Codex, P2): зупинену профілем exchangAPI запустив хтось
        # інший під час збору журналів — фінальний стан Running, тож це успіх:
        # без CRITICAL «зупинено, але не запущено», маркер прибрано, код 0.
        & $recoverCheck 'RSDependentStartedExternally' 0 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('BRAVO', 'exchangAPI', 'BravoWeb'))
            'STOP BravoWeb'; 'STOP exchangAPI'
            'TRACE-ROTATION'; 'EXCHANGE-ROTATION'; 'APACHE-ROTATION'; 'WEBAPP-ROTATION'
            'START BRAVO'; 'START BravoWeb'
            'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered; 'LOCK-EXIT'
        ) $recoverLogName {
            param($Result)
            ([string]$Result.LogText).Contains('[INFO] Служба exchangAPI вже працює (її запустили поза профілем після зупинки)') -and
            @($Result.Events | Where-Object { ([string]$_) -like 'NOTIFY CRITICAL*' }).Count -eq 0
        } 'ServiceRecovery/RecoverServicesDependentStartedExternallyIsSuccess' `
            "Рев'ю PR #432 (Codex P2): зупинену профілем службу запустили поза ним під час збору журналів — фінальний стан Running, без хибного CRITICAL, маркер знято, код 0"
        # Рев'ю PR #432 (B-P3-4): непередбачений виняток — код 60 (не 1),
        # FR-6 Failed для впалої служби, lock звільнено.
        & $recoverCheck 'RSUnexpectedException' 60 @(
            $recoverLock; 'SCM-READ'; 'LOCK-EXIT'; $recoverFailed
        ) $recoverLogName {
            param($Result) ([string]$Result.LogText).Contains('[ERROR] ПОМИЛКА: непередбачена помилка профілю -RecoverServices:')
        } 'ServiceRecovery/RecoverServicesUnexpectedExceptionIsCritical' `
            "Рев'ю PR #432 (B-P3-4): непередбачений виняток профілю — ERROR у журнал, FR-6 Failed для впалої служби і код 60"
        & $recoverCheck 'RSCyclicThirdAttempt' 10 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('exchangAPI'))
            'EXCHANGE-ROTATION'; 'START exchangAPI'; 'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered; 'NOTIFY CRITICAL|СЛУЖБА BRAVO ЦИКЛІЧНО ПАДАЄ'; 'LOCK-EXIT'
        ) $recoverLogName {
            param($Result) (& $recoverStateCount $Result 'exchangAPI') -eq 3
        } 'ServiceRecovery/RecoverServicesCyclicThirdAttempt' `
            '#314 FR-5/FR-6: 3-тя спроба за добу (пауза 15 хв минула) — запуск, WARNING «відновлено» і CRITICAL «циклічно падає», код 10'
        & $recoverCheck 'RSScmReadFails' 10 @(
            $recoverLock; 'SCM-READ'; (& $recoverMarker @('exchangAPI'))
            'EXCHANGE-ROTATION'; 'START exchangAPI'; 'RECOVERY-STATE-WRITE'; 'MARKER-CLEAR'; $recoverRecovered; 'LOCK-EXIT'
        ) $recoverLogName {
            param($Result) ([string]$Result.LogText).Contains('[WARNING] Події Service Control Manager не прочитано: self-test: журнал System недоступний')
        } 'ServiceRecovery/RecoverServicesScmEventReadFailureNotBlocking' `
            '#314 FR-3 крок 7: збій читання подій SCM — WARNING, відновлення не блокується (код 10)'
        & $recoverCheck 'RSStableCounterReset' 0 @($recoverLock; 'RECOVERY-STATE-WRITE'; 'LOCK-EXIT') '' {
            param($Result) (& $recoverStateCount $Result 'exchangAPI') -eq 0
        } 'ServiceRecovery/RecoverServicesStableCounterResetUnderLock' `
            '#314 FR-5: служба працює 30 хв після останньої спроби — облік обнуляється під operation-lock, без файлу журналу'

        # Несумісні параметри — помилка параметрів, код 30, нічого не змінюється.
        & $recoverCheck 'RSConflictForceRestore' 30 @() '' $recoverOk `
            'ServiceRecovery/RecoverServicesRejectsForceRestore' `
            '#314 FR-3: -RecoverServices з -ForceRestore — код 30 без будь-яких дій'
        & $recoverCheck 'RSConflictRunMissedRestoreOnly' 30 @() '' $recoverOk `
            'ServiceRecovery/RecoverServicesRejectsRunMissedRestoreOnly' `
            '#314 FR-3: -RecoverServices з -RunMissedRestoreOnly — код 30 без будь-яких дій'
    } finally {
        if (Test-Path -LiteralPath $recoverRoot -PathType Container) {
            Remove-Item -LiteralPath $recoverRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================
# #314 хвиля 5 (FR-4, ТЗ §6 п. 8): задача Планувальника BRAVO_SERVICE_RECOVERY.
# Три тригери (подія Service Control Manager / старт ОС / кожні 15 хв) і
# власні налаштування задачі будує канонічний
# Initialize-BRAVOServiceRecoveryTaskDefinition (BRAVO.System), перевіряє
# Test-BRAVOServiceRecoveryTaskDefinition — той самий модуль, його викликає
# Test-BRAVOScheduledTaskDefinition у BRAVO_TASKS_DIAGNOSE.ps1. Визначення тут —
# підроблений COM ITaskDefinition (однаково на Linux і Windows); справжній COM
# Schedule.Service перевіряє TaskDefinition/ServiceRecoveryComDefinitionHasThreeTriggers
# у кореневому BRAVO_SELF_TEST.ps1 (лише Windows).
& {
    $taskSystemText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.System\BRAVO.System.psm1'), [Text.Encoding]::UTF8)
    $taskModule = $null
    $taskModuleError = ''
    try {
        $taskModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText $taskSystemText `
            -FunctionNames @('ConvertTo-BRAVOEventXPathLiteral', 'Get-BRAVOServiceRecoveryTaskTriggerSpec', 'Initialize-BRAVOServiceRecoveryTaskDefinition', 'Get-BRAVOServiceRecoverySubscriptionStopEventNames', 'Test-BRAVOServiceRecoveryTaskDefinition')
    } catch {
        $taskModuleError = $_.Exception.Message
    }
    # Підроблений ITaskDefinition: Triggers — колекція з методом Create(type),
    # кожен тригер має властивості всіх трьох COM-типів.
    $newFakeDefinition = {
        $fakeTriggers = New-Object System.Collections.ArrayList
        Add-Member -InputObject $fakeTriggers -MemberType ScriptMethod -Name Create -Value {
            param($Type)
            $fakeTrigger = [pscustomobject]@{
                Type = [int]$Type; Enabled = $false; Delay = ''; Subscription = ''; StartBoundary = ''; DaysInterval = 0
                Repetition = [pscustomobject]@{ Interval = ''; Duration = ''; StopAtDurationEnd = $true }
            }
            [void]$this.Add($fakeTrigger)
            return $fakeTrigger
        }
        [pscustomobject]@{
            Settings = [pscustomobject]@{ MultipleInstances = 0; StartWhenAvailable = $true; ExecutionTimeLimit = 'PT72H' }
            Triggers = $fakeTriggers
        }
    }
    $taskProbe = {
        param($Definition, [string]$Mutation)
        Initialize-BRAVOServiceRecoveryTaskDefinition -Definition $Definition -Now ([datetime]'2026-10-07T10:20:30')
        $triggerList = $Definition.Triggers
        switch ($Mutation) {
            'NoEvent' { $triggerList.Remove(@($triggerList | Where-Object { $_.Type -eq 0 })[0]) }
            'NoBoot' { $triggerList.Remove(@($triggerList | Where-Object { $_.Type -eq 8 })[0]) }
            'NoDaily' { $triggerList.Remove(@($triggerList | Where-Object { $_.Type -eq 2 })[0]) }
            'DailyHourly' { @($triggerList | Where-Object { $_.Type -eq 2 })[0].Repetition.Interval = 'PT1H' }
            'BootNoDelay' { @($triggerList | Where-Object { $_.Type -eq 8 })[0].Delay = '' }
            'EventMissingId' { $eventTriggerToEdit = @($triggerList | Where-Object { $_.Type -eq 0 })[0]; $eventTriggerToEdit.Subscription = $eventTriggerToEdit.Subscription.Replace(' or EventID=7034', '') }
            'Parallel' { $Definition.Settings.MultipleInstances = 0 }
            'ForeignLog' { $eventTriggerToEdit = @($triggerList | Where-Object { $_.Type -eq 0 })[0]; $eventTriggerToEdit.Subscription = $eventTriggerToEdit.Subscription.Replace('<Select Path="System">', '<Select Path="Application">') }
            'DuplicateBoot' { $duplicateBoot = $Definition.Triggers.Create(8); $duplicateBoot.Delay = 'PT10M'; $duplicateBoot.Enabled = $true }
            'ExtraTrigger' { [void]$Definition.Triggers.Create(1) }
            'StopAtDurationEnd' { @($triggerList | Where-Object { $_.Type -eq 2 })[0].Repetition.StopAtDurationEnd = $true }
        }
        $spec = Get-BRAVOServiceRecoveryTaskTriggerSpec
        $subscriptionXml = $null
        try { $subscriptionXml = [xml]$spec.EventSubscription } catch { $subscriptionXml = $null }
        [pscustomobject]@{
            Triggers = @($triggerList | ForEach-Object {
                    [pscustomobject]@{
                        Type = $_.Type; Enabled = $_.Enabled; Delay = $_.Delay; Subscription = $_.Subscription
                        StartBoundary = $_.StartBoundary; DaysInterval = $_.DaysInterval
                        Interval = $_.Repetition.Interval; Duration = $_.Repetition.Duration; StopAtDurationEnd = $_.Repetition.StopAtDurationEnd
                    }
                })
            Settings = $Definition.Settings
            Problems = @(Test-BRAVOServiceRecoveryTaskDefinition -Definition $Definition)
            SubscriptionIsXml = ($null -ne $subscriptionXml -and [string]$subscriptionXml.QueryList.Query.Select.Path -eq 'System')
        }
    }
    $runTaskProbe = {
        param([string]$Mutation)
        if ($null -eq $taskModule) { return $null }
        try { return (& $taskModule $taskProbe (& $newFakeDefinition) $Mutation) } catch { return [pscustomobject]@{ Error = $_.Exception.Message } }
    }

    $taskBuilt = & $runTaskProbe ''
    $taskBuiltOk = $false
    $taskBuiltDetail = $taskModuleError
    if ($null -ne $taskBuilt -and $null -ne $taskBuilt.PSObject.Properties['Triggers']) {
        $eventBuilt = @($taskBuilt.Triggers | Where-Object { $_.Type -eq 0 })
        $bootBuilt = @($taskBuilt.Triggers | Where-Object { $_.Type -eq 8 })
        $dailyBuilt = @($taskBuilt.Triggers | Where-Object { $_.Type -eq 2 })
        $eventIdsCovered = $eventBuilt.Count -eq 1 -and @(7000, 7009, 7011, 7022, 7023, 7024, 7031, 7034 | Where-Object { ([string]$eventBuilt[0].Subscription) -notmatch ('EventID={0}\b' -f $_) }).Count -eq 0
        $taskBuiltOk = (
            @($taskBuilt.Triggers).Count -eq 3 -and
            $eventBuilt.Count -eq 1 -and [bool]$eventBuilt[0].Enabled -and $eventBuilt[0].Delay -eq 'PT1M' -and
            ([string]$eventBuilt[0].Subscription).Contains("Provider[@Name='Service Control Manager']") -and
            ([string]$eventBuilt[0].Subscription).Contains('<Select Path="System">') -and $eventIdsCovered -and
            $taskBuilt.SubscriptionIsXml -and
            $bootBuilt.Count -eq 1 -and [bool]$bootBuilt[0].Enabled -and $bootBuilt[0].Delay -eq 'PT10M' -and
            $dailyBuilt.Count -eq 1 -and [bool]$dailyBuilt[0].Enabled -and $dailyBuilt[0].DaysInterval -eq 1 -and
            $dailyBuilt[0].StartBoundary -eq '2026-10-07T00:00:00' -and
            $dailyBuilt[0].Interval -eq 'PT15M' -and $dailyBuilt[0].Duration -eq 'P1D' -and -not [bool]$dailyBuilt[0].StopAtDurationEnd -and
            [int]$taskBuilt.Settings.MultipleInstances -eq 2 -and -not [bool]$taskBuilt.Settings.StartWhenAvailable -and
            [string]$taskBuilt.Settings.ExecutionTimeLimit -eq 'PT1H' -and
            @($taskBuilt.Problems).Count -eq 0
        )
        $taskBuiltDetail = "тригери: $(@($taskBuilt.Triggers | ForEach-Object { '{0}/{1}/{2}/{3}' -f $_.Type, $_.Delay, $_.Interval, $_.Duration }) -join '; '); проблеми: $(@($taskBuilt.Problems) -join ' | ')"
    } elseif ($null -ne $taskBuilt) {
        $taskBuiltDetail = [string]$taskBuilt.Error
    }
    Test-BRAVOCondition `
        -Condition $taskBuiltOk `
        -Name 'ServiceRecovery/TaskDefinitionHasThreeTriggers' `
        -Failure "#314 FR-4: визначення задачі BRAVO_SERVICE_RECOVERY — рівно три тригери: event (System / Service Control Manager, Id 7000, 7009, 7011, 7022, 7023, 7024, 7031, 7034; Delay PT1M), boot (Delay PT10M), daily з Repetition PT15M / P1D; MultipleInstances=IgnoreNew, StartWhenAvailable=false, ExecutionTimeLimit=PT1H; перевірка того самого визначення — без проблем. Отримано: $taskBuiltDetail"

    $taskMutations = [ordered]@{
        NoEvent = 'немає event-тригера'
        NoBoot = 'немає boot-тригера'
        NoDaily = 'немає daily-тригера'
        DailyHourly = 'daily-тригер: Repetition'
        BootNoDelay = 'boot-тригер: Delay'
        EventMissingId = 'бракує 7034'
        Parallel = 'MultipleInstances'
        ForeignLog = 'читає журнал Application'
        DuplicateBoot = 'дубльовані тригери: boot'
        ExtraTrigger = 'зайві тригери (тип 1)'
        StopAtDurationEnd = 'StopAtDurationEnd=True'
    }
    $taskMutationMisses = @()
    foreach ($taskMutation in $taskMutations.Keys) {
        $taskMutated = & $runTaskProbe $taskMutation
        $taskMutationProblems = if ($null -ne $taskMutated -and $null -ne $taskMutated.PSObject.Properties['Problems']) { @($taskMutated.Problems) } else { @() }
        if (@($taskMutationProblems | Where-Object { ([string]$_).Contains([string]$taskMutations[$taskMutation]) }).Count -ne 1) {
            $taskMutationMisses += "${taskMutation}: $($taskMutationProblems -join ' | ')"
        }
    }
    Test-BRAVOCondition `
        -Condition ($null -ne $taskModule -and $taskMutationMisses.Count -eq 0) `
        -Name 'ServiceRecovery/TaskDefinitionCheckCatchesMissingTrigger' `
        -Failure "#314 FR-4: перевірка визначення ловить відсутній тригер і неправильні параметри (event / boot / daily, затримка, повтор, ідентифікатори подій, MultipleInstances), підписку на інший журнал, дубльований і зайвий тригер, StopAtDurationEnd. Пропущено: $($taskMutationMisses -join '; ') $taskModuleError"

    # Diagnose: Test-BRAVOScheduledTaskDefinition для ServiceRecovery додає
    # проблеми тригерів (відсутній boot-тригер — FAIL), для інших типів — ні.
    $diagnoseTextForTask = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_TASKS_DIAGNOSE.ps1'), [Text.Encoding]::UTF8)
    $compatibilityTextForTask = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Compatibility\BRAVO.Compatibility.psm1'), [Text.Encoding]::UTF8)
    $diagnoseTaskModule = $null
    $diagnoseTaskError = ''
    try {
        $diagnoseTaskModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText ($diagnoseTextForTask + "`n" + $compatibilityTextForTask + "`n" + $taskSystemText) `
            -FunctionNames @('Test-BRAVOMappedNetworkDrive', 'ConvertTo-BRAVOAccountSidValue', 'Test-BRAVOAccountIdentityEquivalent',
                'ConvertTo-BRAVOEventXPathLiteral', 'Get-BRAVOServiceRecoveryTaskTriggerSpec', 'Initialize-BRAVOServiceRecoveryTaskDefinition',
                'Get-BRAVOServiceRecoverySubscriptionStopEventNames', 'Test-BRAVOServiceRecoveryTaskDefinition', 'Test-BRAVOScheduledTaskDefinition')
    } catch {
        $diagnoseTaskError = $_.Exception.Message
    }
    $diagnoseTaskProblems = @{}
    if ($null -ne $diagnoseTaskModule) {
        foreach ($diagnoseCase in @('ServiceRecovery|', 'ServiceRecovery|NoBoot', 'Maintenance|NoBoot')) {
            $diagnoseCaseParts = $diagnoseCase.Split('|')
            $diagnoseDefinition = & $newFakeDefinition
            Add-Member -InputObject $diagnoseDefinition -MemberType NoteProperty -Name Principal -Value ([pscustomobject]@{ UserId = 'S-1-5-18'; LogonType = 5; RunLevel = 1 })
            Add-Member -InputObject $diagnoseDefinition -MemberType NoteProperty -Name Actions -Value @()
            try {
                $diagnoseTaskProblems[$diagnoseCase] = @(& $diagnoseTaskModule {
                        param($Definition, $TaskType, $Mutation)
                        Initialize-BRAVOServiceRecoveryTaskDefinition -Definition $Definition
                        if ($Mutation -eq 'NoBoot') { $Definition.Triggers.Remove(@($Definition.Triggers | Where-Object { $_.Type -eq 8 })[0]) }
                        Test-BRAVOScheduledTaskDefinition `
                            -TaskType $TaskType -RegisteredTask ([pscustomobject]@{ Enabled = $true; Definition = $Definition }) -TaskSettings @{} `
                            -ExpectedConfigPath '' -ExpectedExecutable '' -RequiredArgumentTokens @() `
                            -ExpectedAccount 'SYSTEM' -ExpectedLogonType 5 -ExpectedRunLevel 1
                    } $diagnoseDefinition $diagnoseCaseParts[0] $diagnoseCaseParts[1])
            } catch {
                $diagnoseTaskProblems[$diagnoseCase] = @("виняток: $($_.Exception.Message)")
            }
        }
    }
    $diagnoseTriggerProblems = {
        param([string]$Case)
        if (-not $diagnoseTaskProblems.ContainsKey($Case)) { return @('немає результату') }
        return @($diagnoseTaskProblems[$Case] | Where-Object { ([string]$_) -match 'тригер|MultipleInstances|StartWhenAvailable|ExecutionTimeLimit|виняток' })
    }
    Test-BRAVOCondition `
        -Condition (
            $null -ne $diagnoseTaskModule -and
            @(& $diagnoseTriggerProblems 'ServiceRecovery|').Count -eq 0 -and
            @(& $diagnoseTriggerProblems 'ServiceRecovery|NoBoot' | Where-Object { ([string]$_).Contains('немає boot-тригера') }).Count -eq 1 -and
            @(& $diagnoseTriggerProblems 'Maintenance|NoBoot').Count -eq 0
        ) `
        -Name 'ServiceRecovery/DiagnoseChecksServiceRecoveryTriggers' `
        -Failure "#314 FR-4: BRAVO_TASKS_DIAGNOSE (Test-BRAVOScheduledTaskDefinition) перевіряє три тригери задачі ServiceRecovery через Test-BRAVOServiceRecoveryTaskDefinition: правильне визначення — без проблем тригерів, без boot-тригера — FAIL; інших типів задач перевірка не стосується. Отримано: правильне=[$(@(& $diagnoseTriggerProblems 'ServiceRecovery|') -join ' | ')]; без boot=[$(@(& $diagnoseTriggerProblems 'ServiceRecovery|NoBoot') -join ' | ')]; Maintenance=[$(@(& $diagnoseTriggerProblems 'Maintenance|NoBoot') -join ' | ')] $diagnoseTaskError"

    # Рев'ю PR #432 (A-P2): штатний Stop-Service пише в System log лише 7036.
    # Підписка event-тригера має другий Select — 7036 лише для відображуваних
    # імен керованих служб (param1 події); апостроф — у подвійних лапках, обидва
    # види лапок — ім'я пропускається; &, <, > — XML-сутності. Diagnose звіряє
    # зареєстрований фільтр з поточними іменами.
    $stopEventApostropheName = "BRAVO O'Service"
    $stopEventBothQuotesName = 'BRAVO "Q" O''S'
    $stopEventProbe = {
        param($Definition, [string[]]$Names, [string[]]$ExpectedNames, [bool]$BindExpected)
        $spec = Get-BRAVOServiceRecoveryTaskTriggerSpec -StopEventDisplayNames $Names
        $definition = $Definition
        Initialize-BRAVOServiceRecoveryTaskDefinition -Definition $definition -StopEventDisplayNames $Names
        $checkArguments = @{ Definition = $definition }
        if ($BindExpected) { $checkArguments['ExpectedStopEventDisplayNames'] = $ExpectedNames }
        $xml = $null
        try { $xml = [xml]$spec.EventSubscription } catch { $xml = $null }
        [pscustomobject]@{
            Subscription = [string]$spec.EventSubscription
            SpecNames = @($spec.StopEventDisplayNames)
            SelectCount = if ($null -ne $xml) { @($xml.QueryList.Query.Select).Count } else { -1 }
            ParsedNames = @((Get-BRAVOServiceRecoverySubscriptionStopEventNames -Subscription $spec.EventSubscription).Names)
            Problems = @(Test-BRAVOServiceRecoveryTaskDefinition @checkArguments)
        }
    }
    $stopEventRun = {
        param([string[]]$Names, [string[]]$ExpectedNames, [bool]$BindExpected)
        if ($null -eq $taskModule) { return $null }
        try { return (& $taskModule $stopEventProbe (& $newFakeDefinition) $Names $ExpectedNames $BindExpected) } catch { return [pscustomobject]@{ Error = $_.Exception.Message } }
    }
    $stopEventNames = @('BRAVO Display', $stopEventApostropheName, 'BRAVO & Web <x>', $stopEventBothQuotesName)
    $stopEventBuilt = & $stopEventRun $stopEventNames @('BRAVO Display', $stopEventApostropheName, 'BRAVO & Web <x>') $true
    $stopEventNone = & $stopEventRun @() @() $true
    $stopEventStale = & $stopEventRun @('BRAVO Display') @('BRAVO Display (renamed)') $true
    $stopEventUnbound = & $stopEventRun @('BRAVO Display') @() $false
    $stopEventStaleNone = & $stopEventRun @() @('BRAVO Display') $true
    $stopEventOk = (
        $null -ne $stopEventBuilt -and $null -eq $stopEventBuilt.PSObject.Properties['Error'] -and
        $stopEventBuilt.SelectCount -eq 2 -and
        $stopEventBuilt.Subscription.Contains("and EventID=7036] and EventData[Data[@Name='param1']='BRAVO Display' or Data[@Name='param1']=""BRAVO O'Service"" or Data[@Name='param1']='BRAVO &amp; Web &lt;x&gt;']]") -and
        -not $stopEventBuilt.Subscription.Contains('"Q"') -and
        (@($stopEventBuilt.SpecNames) -join '|') -ceq ('BRAVO Display|' + $stopEventApostropheName + '|BRAVO & Web <x>') -and
        (@($stopEventBuilt.ParsedNames) -join '|') -ceq ('BRAVO Display|' + $stopEventApostropheName + '|BRAVO & Web <x>') -and
        @($stopEventBuilt.Problems).Count -eq 0 -and
        $null -ne $stopEventNone -and $stopEventNone.SelectCount -eq 1 -and -not $stopEventNone.Subscription.Contains('7036') -and @($stopEventNone.Problems).Count -eq 0 -and
        $null -ne $stopEventUnbound -and @($stopEventUnbound.Problems).Count -eq 0 -and
        $null -ne $stopEventStale -and @($stopEventStale.Problems | Where-Object { ([string]$_).Contains('фільтр події 7036 не відповідає') -and ([string]$_).Contains('BRAVO Display (renamed)') }).Count -eq 1 -and
        $null -ne $stopEventStaleNone -and @($stopEventStaleNone.Problems | Where-Object { ([string]$_).Contains('зареєстровано: немає') }).Count -eq 1
    )
    Test-BRAVOCondition `
        -Condition $stopEventOk `
        -Name 'ServiceRecovery/TaskStopEventFilteredByDisplayName' `
        -Failure "Рев'ю PR #432 (A-P2): event-тригер підписаний і на 7036 (штатна зупинка), але лише для відображуваних імен керованих служб (EventData/Data[@Name='param1']); апостроф — у подвійних лапках, обидва види лапок — без фільтра, XML-сутності для &, <, >; без імен 7036 не підписується; перевірка визначення ловить розбіжність фільтра з поточними іменами. Отримано: підписка='$(if ($null -ne $stopEventBuilt -and $null -ne $stopEventBuilt.PSObject.Properties['Subscription']) { $stopEventBuilt.Subscription })'; імена=[$(if ($null -ne $stopEventBuilt -and $null -ne $stopEventBuilt.PSObject.Properties['ParsedNames']) { @($stopEventBuilt.ParsedNames) -join ' | ' })]; проблеми розбіжності=[$(if ($null -ne $stopEventStale -and $null -ne $stopEventStale.PSObject.Properties['Problems']) { @($stopEventStale.Problems) -join ' | ' })] $(if ($null -ne $stopEventBuilt -and $null -ne $stopEventBuilt.PSObject.Properties['Error']) { $stopEventBuilt.Error }) $taskModuleError"

    # Відображувані імена читаються з Get-Service (той самий шлях у
    # інсталятора й Diagnose): відсутня служба й ім'я з обома видами лапок —
    # попередження, без фільтра; перелік керованих служб — з налаштувань
    # (BRAVO Web — лише з BravoWebEnabled і discovery).
    $stopEventFilterModule = $null
    $stopEventFilterError = ''
    try {
        $stopEventFilterModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText (@'
function Get-Service {
    param([string]$Name, $ErrorAction)
    if ($Name -eq 'BravoMissing') { return $null }
    $displayNames = @{ 'BRAVO' = 'BRAVO Display'; 'exchangAPI' = 'BRAVO exchangAPI Display'; 'BravoQuoted' = $script:stopEventBothQuotesName; 'BravoNoDisplay' = '' }
    return [pscustomobject]@{ Name = $Name; DisplayName = $displayNames[$Name] }
}
function Get-BRAVOManagedServiceCondition {
    param([string]$Name)
    if ($Name -eq 'BravoMissing') { return [pscustomobject]@{ Name = $Name; Exists = $false; StartMode = $null; Status = $null } }
    return [pscustomobject]@{ Name = $Name; Exists = $true; StartMode = 'Automatic'; Status = 'Running' }
}
'@ + "`n" + $taskSystemText) `
            -FunctionNames @('Get-Service', 'Get-BRAVOManagedServiceCondition', 'ConvertTo-BRAVOEventXPathLiteral', 'Get-BRAVOServiceRecoveryManagedServiceNames', 'Get-BRAVOServiceRecoveryStopEventFilter', 'Get-BRAVOManagedServiceStartModeSummary')
    } catch {
        $stopEventFilterError = $_.Exception.Message
    }
    $stopEventFilterResult = $null
    if ($null -ne $stopEventFilterModule) {
        try {
            $stopEventFilterResult = & $stopEventFilterModule {
                param([string]$BothQuotesName)
                Set-StrictMode -Version 2.0
                $script:stopEventBothQuotesName = $BothQuotesName
                $filter = Get-BRAVOServiceRecoveryStopEventFilter -ServiceNames @('BRAVO', 'exchangAPI', 'BRAVO', 'BravoMissing', 'BravoQuoted', 'BravoNoDisplay', '')
                $discovery = [pscustomobject]@{ WebServiceName = 'BravoWebSvc' }
                [pscustomobject]@{
                    DisplayNames = @($filter.DisplayNames)
                    Warnings = @($filter.Warnings)
                    NamesWithWeb = @(Get-BRAVOServiceRecoveryManagedServiceNames -ServicesSettings @{ BravoName = 'BRAVO'; ExchangeApiName = 'exchangAPI'; BravoWebEnabled = 'true' } -DiscoveryResult $discovery)
                    NamesWebOff = @(Get-BRAVOServiceRecoveryManagedServiceNames -ServicesSettings @{ BravoName = 'BRAVO'; ExchangeApiName = 'exchangAPI'; BravoWebEnabled = $false } -DiscoveryResult $discovery)
                    NamesWebNoFlag = @(Get-BRAVOServiceRecoveryManagedServiceNames -ServicesSettings ([pscustomobject]@{ BravoName = 'BRAVO'; ExchangeApiName = '' }) -DiscoveryResult $discovery)
                    NamesNoSettings = @(Get-BRAVOServiceRecoveryManagedServiceNames -ServicesSettings $null -DiscoveryResult $discovery)
                    Summary = Get-BRAVOManagedServiceStartModeSummary -ServiceNames @('BRAVO', 'BravoMissing', 'BRAVO', '')
                    SummaryEmpty = Get-BRAVOManagedServiceStartModeSummary -ServiceNames @()
                }
            } $stopEventBothQuotesName
        } catch {
            $stopEventFilterError = $_.Exception.Message
        }
    }
    Test-BRAVOCondition `
        -Condition (
            $null -ne $stopEventFilterResult -and
            (@($stopEventFilterResult.DisplayNames) -join '|') -ceq 'BRAVO Display|BRAVO exchangAPI Display' -and
            @($stopEventFilterResult.Warnings).Count -eq 3 -and
            @($stopEventFilterResult.Warnings | Where-Object { ([string]$_).Contains('BravoMissing не знайдено') }).Count -eq 1 -and
            @($stopEventFilterResult.Warnings | Where-Object { ([string]$_).Contains('BravoQuoted містить і апостроф, і подвійні лапки') }).Count -eq 1 -and
            (@($stopEventFilterResult.NamesWithWeb) -join '|') -ceq 'BRAVO|exchangAPI|BravoWebSvc' -and
            (@($stopEventFilterResult.NamesWebOff) -join '|') -ceq 'BRAVO|exchangAPI' -and
            (@($stopEventFilterResult.NamesWebNoFlag) -join '|') -ceq 'BRAVO' -and
            @($stopEventFilterResult.NamesNoSettings).Count -eq 0
        ) `
        -Name 'ServiceRecovery/StopEventDisplayNamesReadFromServices' `
        -Failure "Рев'ю PR #432 (A-P2): відображувані імена для фільтра 7036 — з Get-Service для керованих служб (без дублікатів); відсутня служба, порожнє ім'я і ім'я з обома видами лапок — попередження без фільтра; перелік служб: BRAVO, exchangAPI і BRAVO Web лише з BravoWebEnabled. Отримано: $(if ($null -ne $stopEventFilterResult) { 'імена=' + (@($stopEventFilterResult.DisplayNames) -join ' | ') + '; попередження=' + (@($stopEventFilterResult.Warnings) -join ' | ') + '; служби=' + (@($stopEventFilterResult.NamesWithWeb) -join ',') + '/' + (@($stopEventFilterResult.NamesWebOff) -join ',') + '/' + (@($stopEventFilterResult.NamesWebNoFlag) -join ',') }) $stopEventFilterError"

    # Рев'ю PR #432 (A-P3-5): рядок журналу інсталятора про типи запуску —
    # поведінково, а не лише grep-ом: дублікати й порожні імена пропускаються,
    # відсутня служба — «не встановлена», без служб — окремий текст.
    Test-BRAVOCondition `
        -Condition (
            $null -ne $stopEventFilterResult -and
            [string]$stopEventFilterResult.Summary -ceq 'BRAVO: Automatic, Running; BravoMissing: не встановлена' -and
            [string]$stopEventFilterResult.SummaryEmpty -ceq 'керованих служб не налаштовано'
        ) `
        -Name 'ServiceRecovery/ManagedServiceStartModeSummaryBehaviour' `
        -Failure "Рев'ю PR #432 (A-P3-5): Get-BRAVOManagedServiceStartModeSummary — «ім'я: тип, стан» через '; ', без дублікатів і порожніх імен, відсутня служба — «не встановлена», порожній перелік — «керованих служб не налаштовано». Отримано: '$(if ($null -ne $stopEventFilterResult) { $stopEventFilterResult.Summary })' / '$(if ($null -ne $stopEventFilterResult) { $stopEventFilterResult.SummaryEmpty })' $stopEventFilterError"

    # Diagnose передає поточні імена в перевірку: зареєстрований фільтр 7036
    # зі старими іменами — FAIL.
    $diagnoseStopEventProblems = @()
    if ($null -ne $diagnoseTaskModule) {
        $diagnoseStopEventDefinition = & $newFakeDefinition
        Add-Member -InputObject $diagnoseStopEventDefinition -MemberType NoteProperty -Name Principal -Value ([pscustomobject]@{ UserId = 'S-1-5-18'; LogonType = 5; RunLevel = 1 })
        Add-Member -InputObject $diagnoseStopEventDefinition -MemberType NoteProperty -Name Actions -Value @()
        try {
            $diagnoseStopEventProblems = @(& $diagnoseTaskModule {
                    param($Definition)
                    Initialize-BRAVOServiceRecoveryTaskDefinition -Definition $Definition -StopEventDisplayNames @('BRAVO Display')
                    Test-BRAVOScheduledTaskDefinition `
                        -TaskType 'ServiceRecovery' -RegisteredTask ([pscustomobject]@{ Enabled = $true; Definition = $Definition }) -TaskSettings @{} `
                        -ExpectedConfigPath '' -ExpectedExecutable '' -RequiredArgumentTokens @() `
                        -ExpectedAccount 'SYSTEM' -ExpectedLogonType 5 -ExpectedRunLevel 1 `
                        -ServiceRecoveryStopEventDisplayNames @('BRAVO Display (renamed)')
                } $diagnoseStopEventDefinition)
        } catch {
            $diagnoseStopEventProblems = @("виняток: $($_.Exception.Message)")
        }
    }
    Test-BRAVOCondition `
        -Condition ($null -ne $diagnoseTaskModule -and @($diagnoseStopEventProblems | Where-Object { ([string]$_).Contains('фільтр події 7036 не відповідає') }).Count -eq 1) `
        -Name 'ServiceRecovery/DiagnoseChecksStopEventFilter' `
        -Failure "Рев'ю PR #432 (A-P2): BRAVO_TASKS_DIAGNOSE (Test-BRAVOScheduledTaskDefinition -ServiceRecoveryStopEventDisplayNames) — FAIL, коли фільтр 7036 зареєстровано зі старими відображуваними іменами. Отримано: $($diagnoseStopEventProblems -join ' | ') $diagnoseTaskError"

    # Підключення: тип ServiceRecovery у трьох скриптах задач, похідний вузол
    # конфігурації (Enabled = Maintenance.Enabled), дія -RecoverServices.
    $installTextForTask = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_TASKS_INSTALL.ps1'), [Text.Encoding]::UTF8)
    $uninstallTextForTask = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_TASKS_UNINSTALL.ps1'), [Text.Encoding]::UTF8)
    $derivationTextForTask = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Derivation.psm1'), [Text.Encoding]::UTF8)
    $loaderTextForTask = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_CONFIG_LOADER.ps1'), [Text.Encoding]::UTF8)
    $taskTypeSet = '"Backup", "Maintenance", "Health", "Recovery", "BAZASync", "RestoreVerify", "BackupCatchUp", "ServiceRecovery"'
    $taskWiringChecks = [ordered]@{
        'Install: ValidateSet' = ([regex]::Matches($installTextForTask, [regex]::Escape("[ValidateSet($taskTypeSet)]")).Count -eq 2)
        'Install: план задачі' = $installTextForTask.Contains('[pscustomobject]@{ Type = "ServiceRecovery"; Settings = $serviceRecoverySettings }')
        'Install: Test-TaskName' = $installTextForTask.Contains('Test-TaskName -TaskName $serviceRecoverySettings.TaskName -SettingName "ServiceRecovery.TaskName"')
        'Install: тригери' = $installTextForTask.Contains('Initialize-BRAVOServiceRecoveryTaskDefinition -Definition $definition')
        'Install: дія -RecoverServices' = $installTextForTask.Contains('$actionArguments += " -RecoverServices"')
        'Install: тип запуску трьох служб' = $installTextForTask.Contains('Get-BRAVOManagedServiceStartModeSummary')
        'Diagnose: ValidateSet' = $diagnoseTextForTask.Contains("[ValidateSet($taskTypeSet)]")
        'Diagnose: перелік задач' = $diagnoseTextForTask.Contains("foreach (`$taskType in @($taskTypeSet))")
        'Diagnose: аргументи' = $diagnoseTextForTask.Contains("ServiceRecovery = @('-NoPause', '-RecoverServices')")
        # #314 (рев'ю PR #432, A-P2): виклик перевірки тригерів — через splat,
        # щоб передати поточні імена служб для фільтра події 7036.
        'Diagnose: тригери' = $diagnoseTextForTask.Contains('Test-BRAVOServiceRecoveryTaskDefinition @serviceRecoveryCheckArguments')
        'Diagnose: фільтр 7036' = $diagnoseTextForTask.Contains('-ServiceRecoveryStopEventDisplayNames $serviceRecoveryStopEventDisplayNames') -and $diagnoseTextForTask.Contains('Get-BRAVOServiceRecoveryStopEventFilter -ServiceNames @(Get-BRAVOServiceRecoveryManagedServiceNames')
        'Install: фільтр 7036' = $installTextForTask.Contains('Get-BRAVOServiceRecoveryStopEventFilter -ServiceNames $managedServiceNamesForLog') -and $installTextForTask.Contains('-StopEventDisplayNames $ServiceRecoveryStopEventDisplayNames') -and $installTextForTask.Contains('-ServiceRecoveryStopEventDisplayNames @($serviceRecoveryStopEventFilter.DisplayNames)')
        'Uninstall: ім''я задачі' = $uninstallTextForTask.Contains('$schedulerSettings.ServiceRecovery.TaskName')
        'Derivation: вузол' = ($derivationTextForTask.Contains('$global:schedulerSettings.ServiceRecovery = @{') -and $derivationTextForTask.Contains('TaskName = "BRAVO_SERVICE_RECOVERY"') -and $derivationTextForTask.Contains('ScriptPath = Join-Path $runtimeRoot "BRAVO_MAINTENANCE.ps1"'))
        'Loader: legacy-вузол' = ($loaderTextForTask.Contains('$global:schedulerSettings.ServiceRecovery = @{') -and $loaderTextForTask.Contains("TaskName = 'BRAVO_SERVICE_RECOVERY'"))
    }
    $taskWiringMissing = @($taskWiringChecks.Keys | Where-Object { -not [bool]$taskWiringChecks[$_] })
    Test-BRAVOCondition `
        -Condition ($taskWiringMissing.Count -eq 0) `
        -Name 'ServiceRecovery/TaskWiredThroughInstallDiagnoseUninstall' `
        -Failure "#314 FR-4: тип задачі ServiceRecovery (BRAVO_SERVICE_RECOVERY, дія BRAVO_MAINTENANCE.ps1 -RecoverServices -NoPause) має бути в BRAVO_TASKS_INSTALL / DIAGNOSE / UNINSTALL і в похідній конфігурації; бракує: $($taskWiringMissing -join ', ')"
}

# ============================================================
# #314 хвиля 5 (FR-7, ТЗ §6 п. 9): Health для впалої служби (Failed) НЕ
# запускає службу сам, а просить Планувальник запустити задачу
# BRAVO_SERVICE_RECOVERY (Start-BRAVOScheduledTask, BRAVO.Compatibility).
# Issue лишається, ActionText — «запущено задачу відновлення … результат
# дивіться в журналі» (рев'ю PR #432, B-P3-7: свідомо нейтральний — профіль
# може відкласти відновлення). Задачі
# немає або вона вимкнена — окремий issue «виконайте BRAVO_TASKS_INSTALL».
# Disabled — без issue і без запуску задачі. Стаби: Get-Service, WMI, маркер,
# Start-Service (фіксує заборонений виклик) і Start-BRAVOScheduledTask.
& {
    Add-Type -AssemblyName System.ServiceProcess
    $healthTextForRecovery = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1'), [Text.Encoding]::UTF8)
    $systemTextForRecovery = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.System\BRAVO.System.psm1'), [Text.Encoding]::UTF8)
    $healthRecoveryStubs = @'
function Write-HealthLog { param($Message, $Level) [void]$script:healthRecoveryEvents.Add(('LOG-{0} {1}' -f $Level, $Message)) }
function Get-Service {
    param($Name, $DisplayName, $ErrorAction)
    $status = if (@($script:healthRecoveryRunning) -contains [string]$Name) { [System.ServiceProcess.ServiceControllerStatus]::Running } elseif (@($script:healthRecoveryPaused) -contains [string]$Name) { [System.ServiceProcess.ServiceControllerStatus]::Paused } else { [System.ServiceProcess.ServiceControllerStatus]::Stopped }
    $svc = [pscustomobject]@{ Name = [string]$Name; Status = $status }
    Add-Member -InputObject $svc -MemberType ScriptMethod -Name Refresh -Value { } -Force
    return $svc
}
function Start-Service { param($Name, $ErrorAction) [void]$script:healthRecoveryEvents.Add(('START-SERVICE {0}' -f $Name)) }
function Read-BRAVOServiceQuiescenceState { return $null }
function Get-BRAVOWmiInstance { param($ClassName) return @($script:healthRecoveryWmi) }
function Get-BRAVOServiceRegistryStartMode { param($ServiceName) return $null }
function Start-BRAVOScheduledTask {
    param($TaskPath, $TaskName)
    [void]$script:healthRecoveryEvents.Add(('RUN-TASK {0}{1}' -f $TaskPath, $TaskName))
    if ($null -ne $script:healthRecoveryTaskThrows) { throw $script:healthRecoveryTaskThrows }
    return $script:healthRecoveryTask
}
'@
    $healthRecoveryModule = $null
    $healthRecoveryError = ''
    try {
        $healthRecoveryModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText ($healthRecoveryStubs + "`n" + $healthTextForRecovery + "`n" + $systemTextForRecovery) `
            -FunctionNames @('Write-HealthLog', 'Get-Service', 'Start-Service', 'Read-BRAVOServiceQuiescenceState', 'Get-BRAVOWmiInstance',
                'Get-BRAVOServiceRegistryStartMode', 'Start-BRAVOScheduledTask', 'Test-BRAVOSettingEnabled', 'Get-BRAVOServiceWin32Info', 'Get-BRAVOServiceStartMode',
                'Get-BRAVOManagedServiceCondition', 'Invoke-BRAVOHealthServiceRecoveryTask', 'Get-ManagedServiceHealthIssues')
    } catch {
        $healthRecoveryError = $_.Exception.Message
    }
    $healthRecoveryProbe = {
        param([string[]]$Running, $Wmi, $Task, $TaskThrows = $null, [bool]$RecoveryConfigured = $true, [string[]]$Paused = @())
        Set-StrictMode -Version 2.0
        $script:healthRecoveryEvents = New-Object System.Collections.ArrayList
        $script:healthRecoveryRunning = $Running
        $script:healthRecoveryPaused = $Paused
        $script:healthRecoveryWmi = $Wmi
        $script:healthRecoveryTask = $Task
        $script:healthRecoveryTaskThrows = $TaskThrows
        $script:backupMonitoring = @{ CheckManagedServices = $true }
        $script:maintenanceSettings = [pscustomobject]@{
            Services = [pscustomobject]@{ BravoName = 'BRAVO'; ExchangeApiName = 'exchangAPI'; BravoWebEnabled = $false; BravoWebCandidates = @() }
        }
        # Set-Variable, а не присвоєння: змінна живе лише в scope тестового
        # модуля, а присвоєння $script:schedulerSettings аналізатор
        # Framework/SelectiveSuitesHaveNoCrossSuiteDependency прийняв би за
        # визначення змінної конфігурації, яку читає корінь самотесту.
        Set-Variable -Name 'schedulerSettings' -Scope Script -Value @{
            TaskPath = '\BRAVO\'
            ServiceRecovery = @{ Enabled = $RecoveryConfigured; TaskName = 'BRAVO_SERVICE_RECOVERY' }
        }
        $thrown = $null
        $issues = @()
        try { $issues = @(Get-ManagedServiceHealthIssues) } catch { $thrown = $_.Exception.Message }
        [pscustomobject]@{
            Thrown = $thrown
            Issues = @($issues | ForEach-Object {
                    [pscustomobject]@{
                        Location = [string]$_.Location
                        Reason = [string]$_.Reason
                        ActionText = $(if ($null -ne $_.PSObject.Properties['ActionText']) { [string]$_.ActionText } else { '' })
                    }
                })
            Events = @($script:healthRecoveryEvents)
        }
    }
    $taskReady = [pscustomobject]@{ Exists = $true; Enabled = $true; AlreadyRunning = $false; Started = $true; Error = $null }
    $taskMissing = [pscustomobject]@{ Exists = $false; Enabled = $false; AlreadyRunning = $false; Started = $false; Error = $null }
    $taskDisabled = [pscustomobject]@{ Exists = $true; Enabled = $false; AlreadyRunning = $false; Started = $false; Error = $null }
    $wmiAuto = @(
        [pscustomobject]@{ Name = 'BRAVO'; StartMode = 'Auto'; ExitCode = 0 },
        [pscustomobject]@{ Name = 'exchangAPI'; StartMode = 'Auto'; ExitCode = 1067 }
    )
    $wmiExchangeDisabled = @(
        [pscustomobject]@{ Name = 'BRAVO'; StartMode = 'Auto'; ExitCode = 0 },
        [pscustomobject]@{ Name = 'exchangAPI'; StartMode = 'Disabled'; ExitCode = 0 }
    )
    $runHealthRecovery = {
        param([string[]]$Running, $Wmi, $Task, $TaskThrows = $null, [bool]$RecoveryConfigured = $true, [string[]]$Paused = @())
        if ($null -eq $healthRecoveryModule) { return [pscustomobject]@{ Thrown = $healthRecoveryError; Issues = @(); Events = @() } }
        return (& $healthRecoveryModule $healthRecoveryProbe $Running $Wmi $Task $TaskThrows $RecoveryConfigured $Paused)
    }
    $describeHealthRecovery = {
        param($Result)
        "thrown='$($Result.Thrown)'; issues=[$(@($Result.Issues | ForEach-Object { '{0}: {1} => {2}' -f $_.Location, $_.Reason, $_.ActionText }) -join ' | ')]; events=[$(@($Result.Events | Where-Object { $_ -notlike 'LOG-*' }) -join ', ')]"
    }

    # Впала exchangAPI, задача на місці: задачу запущено рівно раз, службу — ні.
    $healthFailed = & $runHealthRecovery @('BRAVO') $wmiAuto $taskReady
    $healthFailedIssue = @($healthFailed.Issues | Where-Object { $_.Location -eq 'exchangAPI' })
    Test-BRAVOCondition `
        -Condition (
            $null -eq $healthFailed.Thrown -and
            @($healthFailed.Issues).Count -eq 1 -and $healthFailedIssue.Count -eq 1 -and
            $healthFailedIssue[0].ActionText.Contains('служба exchangAPI не працює') -and
            $healthFailedIssue[0].ActionText.Contains('запущено задачу відновлення BRAVO_SERVICE_RECOVERY — результат дивіться в журналі') -and
            $healthFailedIssue[0].ActionText.Contains('_RECOVER_') -and
            @($healthFailed.Events | Where-Object { $_ -eq 'RUN-TASK \BRAVO\BRAVO_SERVICE_RECOVERY' }).Count -eq 1 -and
            @($healthFailed.Events | Where-Object { $_ -like 'START-SERVICE*' }).Count -eq 0
        ) `
        -Name 'ServiceRecovery/HealthFailedServiceStartsRecoveryTaskNotService' `
        -Failure "#314 FR-7: Health для Failed-служби запускає задачу BRAVO_SERVICE_RECOVERY (а не службу), issue лишається з ActionText «служба X не працює; запущено задачу відновлення BRAVO_SERVICE_RECOVERY — результат дивіться в журналі …_RECOVER_….log». Отримано: $(& $describeHealthRecovery $healthFailed)"

    # Дві впалі служби — одна задача на прогін Health.
    $healthTwoFailed = & $runHealthRecovery @() $wmiAuto $taskReady
    Test-BRAVOCondition `
        -Condition (
            $null -eq $healthTwoFailed.Thrown -and @($healthTwoFailed.Issues).Count -eq 2 -and
            @($healthTwoFailed.Issues | Where-Object { $_.ActionText.Contains('запущено задачу відновлення') }).Count -eq 2 -and
            @($healthTwoFailed.Events | Where-Object { $_ -like 'RUN-TASK *' }).Count -eq 1 -and
            @($healthTwoFailed.Events | Where-Object { $_ -like 'START-SERVICE*' }).Count -eq 0
        ) `
        -Name 'ServiceRecovery/HealthRunsRecoveryTaskOncePerCheck' `
        -Failure "#314 FR-7: кілька впалих служб — задача запускається один раз (профіль сам об'єднує ланцюжки), кожен issue має ActionText про відновлення. Отримано: $(& $describeHealthRecovery $healthTwoFailed)"

    # Задачі немає / вимкнена — окремий issue з дією «виконайте BRAVO_TASKS_INSTALL».
    $healthNoTask = & $runHealthRecovery @('BRAVO') $wmiAuto $taskMissing
    $healthDisabledTask = & $runHealthRecovery @('BRAVO') $wmiAuto $taskDisabled
    $healthTaskIssueOk = {
        param($Result)
        $taskIssues = @($Result.Issues | Where-Object { $_.Location -eq 'BRAVO_SERVICE_RECOVERY' })
        $serviceIssues = @($Result.Issues | Where-Object { $_.Location -eq 'exchangAPI' })
        return (
            $null -eq $Result.Thrown -and @($Result.Issues).Count -eq 2 -and
            $taskIssues.Count -eq 1 -and $taskIssues[0].ActionText.Contains('задача відновлення служб відсутня — виконайте BRAVO_TASKS_INSTALL') -and
            [string]$Result.Issues[0].Location -eq 'BRAVO_SERVICE_RECOVERY' -and
            $serviceIssues.Count -eq 1 -and -not $serviceIssues[0].ActionText.Contains('запущено задачу відновлення') -and
            @($Result.Events | Where-Object { $_ -like 'START-SERVICE*' }).Count -eq 0
        )
    }
    Test-BRAVOCondition `
        -Condition ((& $healthTaskIssueOk $healthNoTask) -and (& $healthTaskIssueOk $healthDisabledTask)) `
        -Name 'ServiceRecovery/HealthMissingOrDisabledRecoveryTaskIsSeparateIssue' `
        -Failure "#314 FR-7: задачі BRAVO_SERVICE_RECOVERY немає або вона вимкнена — окремий (перший) issue «задача відновлення служб відсутня — виконайте BRAVO_TASKS_INSTALL», issue служби лишається, службу Health не запускає. Отримано: немає=[$(& $describeHealthRecovery $healthNoTask)]; вимкнена=[$(& $describeHealthRecovery $healthDisabledTask)]"

    # Disabled — як і раніше, INFO без issue і без запуску задачі; усе працює — нічого.
    $healthDisabledService = & $runHealthRecovery @('BRAVO') $wmiExchangeDisabled $taskReady
    $healthAllRunning = & $runHealthRecovery @('BRAVO', 'exchangAPI') $wmiAuto $taskReady
    Test-BRAVOCondition `
        -Condition (
            $null -eq $healthDisabledService.Thrown -and @($healthDisabledService.Issues).Count -eq 0 -and
            @($healthDisabledService.Events | Where-Object { $_ -like 'RUN-TASK *' -or $_ -like 'START-SERVICE*' }).Count -eq 0 -and
            @($healthDisabledService.Events | Where-Object { $_ -like 'LOG-INFO *exchangAPI*Disabled*' }).Count -eq 1 -and
            $null -eq $healthAllRunning.Thrown -and @($healthAllRunning.Issues).Count -eq 0 -and
            @($healthAllRunning.Events | Where-Object { $_ -like 'RUN-TASK *' }).Count -eq 0
        ) `
        -Name 'ServiceRecovery/HealthDisabledServiceNoIssueNoRecoveryTask' `
        -Failure "#314 FR-7: служба Disabled — INFO, без issue і без запуску задачі; усі служби працюють — задача не запускається. Отримано: Disabled=[$(& $describeHealthRecovery $healthDisabledService)]; Running=[$(& $describeHealthRecovery $healthAllRunning)]"

    # Збій запуску задачі не обриває Health і не підміняється запуском служби;
    # задача, що вже виконується, — ActionText про відновлення, що триває;
    # без увімкненого Maintenance (задачу не встановлюють) — колишня поведінка.
    $healthTaskThrows = & $runHealthRecovery @('BRAVO') $wmiAuto $taskReady 'відмовлено в доступі (stub)'
    $healthTaskRunning = & $runHealthRecovery @('BRAVO') $wmiAuto ([pscustomobject]@{ Exists = $true; Enabled = $true; AlreadyRunning = $true; Started = $false; Error = $null })
    $healthNotConfigured = & $runHealthRecovery @('BRAVO') $wmiAuto $taskReady $null $false
    Test-BRAVOCondition `
        -Condition (
            $null -eq $healthTaskThrows.Thrown -and @($healthTaskThrows.Issues).Count -eq 1 -and
            $healthTaskThrows.Issues[0].ActionText.Contains('не вдалося запустити') -and
            @($healthTaskThrows.Events | Where-Object { $_ -like 'START-SERVICE*' }).Count -eq 0 -and
            $null -eq $healthTaskRunning.Thrown -and @($healthTaskRunning.Issues).Count -eq 1 -and
            $healthTaskRunning.Issues[0].ActionText.Contains('вже виконується') -and
            $null -eq $healthNotConfigured.Thrown -and @($healthNotConfigured.Issues).Count -eq 1 -and
            -not $healthNotConfigured.Issues[0].ActionText.Contains('автоматичне відновлення') -and
            @($healthNotConfigured.Events | Where-Object { $_ -like 'RUN-TASK *' -or $_ -like 'START-SERVICE*' }).Count -eq 0
        ) `
        -Name 'ServiceRecovery/HealthRecoveryTaskFailureAndRunningHandled' `
        -Failure "#314 FR-7: збій запуску задачі — issue з ActionText «не вдалося запустити», без винятку і без Start-Service; задача вже виконується — ActionText про відновлення, що триває; Maintenance вимкнено (задачі не передбачено) — issue як раніше, без запуску задачі. Отримано: збій=[$(& $describeHealthRecovery $healthTaskThrows)]; виконується=[$(& $describeHealthRecovery $healthTaskRunning)]; не налаштовано=[$(& $describeHealthRecovery $healthNotConfigured)]"

    # Рев'ю PR #432 (A-P3-1): текст помилки з фігурними дужками не ламає
    # побудову дії алерту (раніше — -f і FormatException на весь Health).
    # A-P3-2: стан задачі не прочитано (помилка COM) — не «задачі немає»:
    # без issue «виконайте BRAVO_TASKS_INSTALL», дія — «не вдалося запустити».
    $healthBracesError = & $runHealthRecovery @('BRAVO') $wmiAuto $taskReady 'відмовлено {0} {доступ}'
    $healthTaskUnreadable = & $runHealthRecovery @('BRAVO') $wmiAuto ([pscustomobject]@{ Exists = $false; Enabled = $false; AlreadyRunning = $false; Started = $false; Error = 'стан задачі не прочитано: self-test COM' })
    Test-BRAVOCondition `
        -Condition (
            $null -eq $healthBracesError.Thrown -and @($healthBracesError.Issues).Count -eq 1 -and
            $healthBracesError.Issues[0].ActionText.Contains('служба exchangAPI не працює; задачу автоматичного відновлення BRAVO_SERVICE_RECOVERY не вдалося запустити (відмовлено {0} {доступ})') -and
            $null -eq $healthTaskUnreadable.Thrown -and @($healthTaskUnreadable.Issues).Count -eq 1 -and
            [string]$healthTaskUnreadable.Issues[0].Location -eq 'exchangAPI' -and
            $healthTaskUnreadable.Issues[0].ActionText.Contains('не вдалося запустити (стан задачі не прочитано: self-test COM)')
        ) `
        -Name 'ServiceRecovery/HealthRecoveryActionTextSafeAndUnreadableTaskNotMissing' `
        -Failure "Рев'ю PR #432 (A-P3-1/A-P3-2): дія алерту будується без -f (фігурні дужки в тексті помилки не кидають FormatException), а нечитабельний стан задачі — збій запуску, не «задачу відсутня». Отримано: дужки=[$(& $describeHealthRecovery $healthBracesError)]; нечитабельна=[$(& $describeHealthRecovery $healthTaskUnreadable)]"

    # Рев'ю PR #432 (B-P3-2): тип запуску зупиненої служби не визначено (немає
    # StartType, рядка WMI і значення реєстру) — issue з поясненням, але задача
    # відновлення не запускається.
    $healthUnknownMode = & $runHealthRecovery @('BRAVO') @([pscustomobject]@{ Name = 'BRAVO'; StartMode = 'Auto'; ExitCode = 0 }) $taskReady
    Test-BRAVOCondition `
        -Condition (
            $null -eq $healthUnknownMode.Thrown -and @($healthUnknownMode.Issues).Count -eq 1 -and
            $healthUnknownMode.Issues[0].Reason.Contains('тип запуску не визначено — автоматичне відновлення її не запускає') -and
            @($healthUnknownMode.Events | Where-Object { $_ -like 'RUN-TASK *' -or $_ -like 'START-SERVICE*' }).Count -eq 0
        ) `
        -Name 'ServiceRecovery/HealthUnknownStartModeNotRecovered' `
        -Failure "Рев'ю PR #432 (B-P3-2): зупинена служба з невідомим типом запуску — issue з причиною, без запуску задачі відновлення. Отримано: $(& $describeHealthRecovery $healthUnknownMode)"

    # Рев'ю PR #432 (Codex, P2): призупинена служба (Paused — Failed за FR-1)
    # профілем -RecoverServices не запускається, тож Health для неї лише
    # додає issue: без запуску задачі й без дії «запущено задачу відновлення».
    $healthPausedOnly = & $runHealthRecovery @('BRAVO') $wmiAuto $taskReady $null $true @('exchangAPI')
    $healthPausedAndStopped = & $runHealthRecovery @() $wmiAuto $taskReady $null $true @('exchangAPI')
    $healthPausedIssue = @($healthPausedOnly.Issues | Where-Object { $_.Location -eq 'exchangAPI' })
    $healthMixedPaused = @($healthPausedAndStopped.Issues | Where-Object { $_.Location -eq 'exchangAPI' })
    $healthMixedStopped = @($healthPausedAndStopped.Issues | Where-Object { $_.Location -eq 'BRAVO' })
    Test-BRAVOCondition `
        -Condition (
            $null -eq $healthPausedOnly.Thrown -and @($healthPausedOnly.Issues).Count -eq 1 -and $healthPausedIssue.Count -eq 1 -and
            $healthPausedIssue[0].Reason.Contains('стан: Paused') -and [string]::IsNullOrEmpty($healthPausedIssue[0].ActionText) -and
            @($healthPausedOnly.Events | Where-Object { $_ -like 'RUN-TASK *' -or $_ -like 'START-SERVICE*' }).Count -eq 0 -and
            @($healthPausedOnly.Events | Where-Object { $_ -like '*задачу автоматичного відновлення*' }).Count -eq 0 -and
            $null -eq $healthPausedAndStopped.Thrown -and @($healthPausedAndStopped.Issues).Count -eq 2 -and
            $healthMixedPaused.Count -eq 1 -and [string]::IsNullOrEmpty($healthMixedPaused[0].ActionText) -and
            $healthMixedStopped.Count -eq 1 -and $healthMixedStopped[0].ActionText.Contains('запущено задачу відновлення') -and
            @($healthPausedAndStopped.Events | Where-Object { $_ -like 'RUN-TASK *' }).Count -eq 1 -and
            @($healthPausedAndStopped.Events | Where-Object { $_ -like 'LOG-INFO Служби не працюють (BRAVO) *' }).Count -eq 1
        ) `
        -Name 'ServiceRecovery/HealthPausedServiceNoRecoveryTask' `
        -Failure "Рев'ю PR #432 (Codex P2): Paused-служба — issue без запуску задачі відновлення і без дії «запущено задачу відновлення»; поряд зі зупиненою — задачу запущено лише заради зупиненої. Отримано: Paused=[$(& $describeHealthRecovery $healthPausedOnly)]; Paused+Stopped=[$(& $describeHealthRecovery $healthPausedAndStopped)]"

    # Start-BRAVOScheduledTask (BRAVO.Compatibility): запуск через ScheduledTasks
    # (Start-ScheduledTask) або COM RegisteredTask.Run($null) — Windows 7 без
    # модуля ScheduledTasks; відсутня / вимкнена / уже запущена задача — без запуску.
    $compatibilityTextForRecovery = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Compatibility\BRAVO.Compatibility.psm1'), [Text.Encoding]::UTF8)
    $startTaskStubs = @'
function Get-BRAVOScheduledTaskState { param($TaskPath, $TaskName) return $script:startTaskState }
function Start-ScheduledTask { param($InputObject, $ErrorAction) [void]$script:startTaskEvents.Add('START-SCHEDULEDTASK') }
'@
    $startTaskModule = $null
    $startTaskError = ''
    try {
        $startTaskModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText ($startTaskStubs + "`n" + $compatibilityTextForRecovery) `
            -FunctionNames @('Get-BRAVOScheduledTaskState', 'Start-ScheduledTask', 'Start-BRAVOScheduledTask')
    } catch {
        $startTaskError = $_.Exception.Message
    }
    $startTaskProbe = {
        param([string]$Provider, [string]$State, [bool]$Exists)
        $script:startTaskEvents = New-Object System.Collections.ArrayList
        $comTask = [pscustomobject]@{ Name = 'BRAVO_SERVICE_RECOVERY' }
        Add-Member -InputObject $comTask -MemberType ScriptMethod -Name Run -Value { param($Parameters) [void]$script:startTaskEvents.Add('COM-RUN') }
        $script:startTaskState = [pscustomobject]@{ Exists = $Exists; State = $State; IsRunning = ($State -eq 'Running'); Provider = $Provider; Task = $(if ($Exists) { $comTask } else { $null }) }
        $outcome = Start-BRAVOScheduledTask -TaskPath '\BRAVO\' -TaskName 'BRAVO_SERVICE_RECOVERY'
        [pscustomobject]@{ Outcome = $outcome; Events = @($script:startTaskEvents) }
    }
    $startTaskCases = @{}
    if ($null -ne $startTaskModule) {
        foreach ($startTaskCase in @('COM|Ready|1', 'ScheduledTasks|Ready|1', 'COM|Disabled|1', 'COM|Running|1', 'COM|NotFound|0')) {
            $startTaskParts = $startTaskCase.Split('|')
            try {
                $startTaskCases[$startTaskCase] = & $startTaskModule $startTaskProbe $startTaskParts[0] $startTaskParts[1] ($startTaskParts[2] -eq '1')
            } catch {
                $startTaskCases[$startTaskCase] = [pscustomobject]@{ Outcome = $null; Events = @("виняток: $($_.Exception.Message)") }
            }
        }
    }
    $startTaskOk = {
        param([string]$Case, [bool]$Started, [string]$Event, [string]$Flag)
        if (-not $startTaskCases.ContainsKey($Case) -or $null -eq $startTaskCases[$Case].Outcome) { return $false }
        $caseResult = $startTaskCases[$Case]
        $eventsOk = if ([string]::IsNullOrEmpty($Event)) { @($caseResult.Events).Count -eq 0 } else { (@($caseResult.Events) -join ',') -eq $Event }
        $flagOk = switch ($Flag) {
            'Missing' { -not [bool]$caseResult.Outcome.Exists }
            'Disabled' { [bool]$caseResult.Outcome.Exists -and -not [bool]$caseResult.Outcome.Enabled }
            'Running' { [bool]$caseResult.Outcome.AlreadyRunning }
            default { $true }
        }
        return ([bool]$caseResult.Outcome.Started -eq $Started -and $eventsOk -and $flagOk)
    }
    Test-BRAVOCondition `
        -Condition (
            $null -ne $startTaskModule -and
            (& $startTaskOk 'COM|Ready|1' $true 'COM-RUN' '') -and
            (& $startTaskOk 'ScheduledTasks|Ready|1' $true 'START-SCHEDULEDTASK' '') -and
            (& $startTaskOk 'COM|Disabled|1' $false '' 'Disabled') -and
            (& $startTaskOk 'COM|Running|1' $false '' 'Running') -and
            (& $startTaskOk 'COM|NotFound|0' $false '' 'Missing')
        ) `
        -Name 'ServiceRecovery/StartScheduledTaskViaComOrScheduledTasks' `
        -Failure "#314 FR-7: Start-BRAVOScheduledTask запускає задачу через COM RegisteredTask.Run (Windows 7) або Start-ScheduledTask, а відсутню, вимкнену чи вже запущену задачу не запускає. Отримано: $(@($startTaskCases.Keys | Sort-Object | ForEach-Object { '{0} => started={1}; events={2}' -f $_, $(if ($null -ne $startTaskCases[$_].Outcome) { $startTaskCases[$_].Outcome.Started } else { '?' }), (@($startTaskCases[$_].Events) -join ',') }) -join ' | ') $startTaskError"

    # Рев'ю PR #432 (A-P3-2): Get-BRAVOScheduledTaskState через COM — «задачі
    # немає» лише для HRESULT 0x80070002/0x80070003; інша помилка COM —
    # State 'Unavailable' з Error, а Start-BRAVOScheduledTask передає її в Error.
    $taskStateStubs = @'
function Test-BRAVOCommandAvailable { param($Name) return $false }
function New-Object {
    param([Parameter(Position = 0)][string]$TypeName, [Parameter(Position = 1)][object[]]$ArgumentList, [string]$ComObject, [System.Collections.IDictionary]$Property)
    if (-not $ComObject) { return (Microsoft.PowerShell.Utility\New-Object @PSBoundParameters) }
    $fakeService = [pscustomobject]@{ HResult = $script:taskStateHResult }
    Add-Member -InputObject $fakeService -MemberType ScriptMethod -Name Connect -Value { }
    Add-Member -InputObject $fakeService -MemberType ScriptMethod -Name GetFolder -Value {
        param($Path)
        throw (Microsoft.PowerShell.Utility\New-Object System.Runtime.InteropServices.COMException('self-test COM', [int]$this.HResult))
    }
    return $fakeService
}
'@
    $taskStateModule = $null
    $taskStateError = ''
    $taskStateCases = @{}
    try {
        $taskStateModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText ($taskStateStubs + "`n" + $compatibilityTextForRecovery) `
            -FunctionNames @('Test-BRAVOCommandAvailable', 'New-Object', 'Get-BRAVOScheduledTaskState', 'Start-BRAVOScheduledTask')
        foreach ($taskStateCase in @(@('NotFound', -2147024894), @('NoFolder', -2147024893), @('AccessDenied', -2147024891))) {
            $taskStateCases[$taskStateCase[0]] = & $taskStateModule {
                param([int]$HResult)
                Set-StrictMode -Version 2.0
                $script:taskStateHResult = $HResult
                [pscustomobject]@{
                    State = Get-BRAVOScheduledTaskState -TaskPath '\BRAVO\' -TaskName 'BRAVO_SERVICE_RECOVERY'
                    Start = Start-BRAVOScheduledTask -TaskPath '\BRAVO\' -TaskName 'BRAVO_SERVICE_RECOVERY'
                }
            } $taskStateCase[1]
        }
    } catch {
        $taskStateError = $_.Exception.Message
    }
    # Error читається через PSObject.Properties: до виправлення його не було.
    $taskStateErrorText = { param($Object) if ($null -ne $Object -and $null -ne $Object.PSObject.Properties['Error']) { [string]$Object.Error } else { '' } }
    $taskStateMissingOk = {
        param($Case)
        $null -ne $Case -and -not [bool]$Case.State.Exists -and [string]$Case.State.State -eq 'NotFound' -and
            [string]::IsNullOrEmpty((& $taskStateErrorText $Case.State)) -and -not [bool]$Case.Start.Exists -and [string]::IsNullOrEmpty([string]$Case.Start.Error)
    }
    $taskStateDenied = $taskStateCases['AccessDenied']
    Test-BRAVOCondition `
        -Condition (
            [string]::IsNullOrEmpty($taskStateError) -and
            (& $taskStateMissingOk $taskStateCases['NotFound']) -and (& $taskStateMissingOk $taskStateCases['NoFolder']) -and
            $null -ne $taskStateDenied -and -not [bool]$taskStateDenied.State.Exists -and [string]$taskStateDenied.State.State -eq 'Unavailable' -and
            (& $taskStateErrorText $taskStateDenied.State).Contains('self-test COM') -and
            ([string]$taskStateDenied.Start.Error).StartsWith('стан задачі не прочитано: ') -and -not [bool]$taskStateDenied.Start.Started
        ) `
        -Name 'ServiceRecovery/ScheduledTaskComErrorIsNotMissingTask' `
        -Failure "Рев'ю PR #432 (A-P3-2): COM 0x80070002/0x80070003 — задачі немає (NotFound, без Error); інша помилка COM (0x80070005) — State 'Unavailable' з Error, і Start-BRAVOScheduledTask повертає її в Error. Помилка: '$taskStateError'; результат: $(@($taskStateCases.Keys | Sort-Object | ForEach-Object { '{0} => state={1}; error={2}; startError={3}' -f $_, $taskStateCases[$_].State.State, (& $taskStateErrorText $taskStateCases[$_].State), (& $taskStateErrorText $taskStateCases[$_].Start) }) -join ' | ')"

    # Статично: Health не викликає Start-Service поза watchdog-ом осиротілого
    # маркера; запуск задачі — лише з Get-ManagedServiceHealthIssues.
    $healthServiceFunctionText = ''
    $healthServiceFunctionStart = $healthTextForRecovery.IndexOf('function Get-ManagedServiceHealthIssues')
    $healthServiceFunctionEnd = $healthTextForRecovery.IndexOf('function Get-BRAVOManagedServiceStatusSnapshot')
    if ($healthServiceFunctionStart -ge 0 -and $healthServiceFunctionEnd -gt $healthServiceFunctionStart) {
        $healthServiceFunctionText = $healthTextForRecovery.Substring($healthServiceFunctionStart, $healthServiceFunctionEnd - $healthServiceFunctionStart)
    }
    Test-BRAVOCondition `
        -Condition (
            $healthServiceFunctionText.Contains('Invoke-BRAVOHealthServiceRecoveryTask') -and
            -not $healthServiceFunctionText.Contains('Start-Service') -and
            ([regex]::Matches($healthTextForRecovery, 'Start-BRAVOScheduledTask\b')).Count -eq 1
        ) `
        -Name 'ServiceRecovery/HealthNeverStartsFailedServiceDirectly' `
        -Failure '#314 FR-7: Get-ManagedServiceHealthIssues не запускає служби (Start-Service лише у watchdog осиротілого маркера), а для впалої служби викликає Invoke-BRAVOHealthServiceRecoveryTask — єдине місце запуску задачі (Start-BRAVOScheduledTask)'
}

# ============================================================
# Рев'ю PR #432 (B-P2-2): власника operation-lock читає канонічний
# Read-BRAVOOperationLockHolder (BRAVO.System) — і гілка очікування
# Enter-BRAVOMaintenanceOperationLock, і профіль -RecoverServices.
& {
    $holderSystemText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.System\BRAVO.System.psm1'), [Text.Encoding]::UTF8)
    $holderRoot = Join-Path ([IO.Path]::GetTempPath()) ('bravo-selftest-lockholder-' + [guid]::NewGuid().ToString('N'))
    $holderResult = $null
    $holderError = ''
    try {
        [void][IO.Directory]::CreateDirectory($holderRoot)
        $holderLockPath = Join-Path $holderRoot 'operation.lock'
        $holderPartialPath = Join-Path $holderRoot 'partial.lock'
        $holderEmptyPath = Join-Path $holderRoot 'empty.lock'
        [IO.File]::WriteAllText($holderLockPath, '{"pid":4242,"processStartTime":"self-test-start","hostname":"host-a","operation":"Archive","startedAt":"self-test-at","generationId":"self-test-gen"}', (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($holderPartialPath, '{"operation":"Maintenance"}', (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($holderEmptyPath, '', (New-Object Text.UTF8Encoding($false)))
        $holderModule = New-BRAVOSelfTestRuntimeModule -SourceText $holderSystemText -FunctionNames @('Read-BRAVOOperationLockHolder')
        $holderResult = & $holderModule {
            param([string]$Full, [string]$Partial, [string]$Empty, [string]$Missing)
            Set-StrictMode -Version 2.0
            [pscustomobject]@{
                Full = Read-BRAVOOperationLockHolder -Path $Full
                Partial = Read-BRAVOOperationLockHolder -Path $Partial
                Empty = Read-BRAVOOperationLockHolder -Path $Empty
                Missing = Read-BRAVOOperationLockHolder -Path $Missing
            }
        } $holderLockPath $holderPartialPath $holderEmptyPath (Join-Path $holderRoot 'missing.lock')
    } catch {
        $holderError = $_.Exception.Message
    } finally {
        if (Test-Path -LiteralPath $holderRoot -PathType Container) { Remove-Item -LiteralPath $holderRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Test-BRAVOCondition `
        -Condition (
            $null -ne $holderResult -and $null -ne $holderResult.Full -and
            [string]$holderResult.Full.Operation -ceq 'Archive' -and [int]$holderResult.Full.Pid -eq 4242 -and
            [string]$holderResult.Full.ProcessStartTime -ceq 'self-test-start' -and [string]$holderResult.Full.HostName -ceq 'host-a' -and
            [string]$holderResult.Full.Description -ceq 'operation=Archive; pid=4242; hostname=host-a; startedAt=self-test-at; generationId=self-test-gen' -and
            $null -ne $holderResult.Partial -and [string]$holderResult.Partial.Description -ceq 'operation=Maintenance; pid=?; hostname=?; startedAt=?; generationId=?' -and
            $null -eq $holderResult.Partial.Pid -and
            $null -eq $holderResult.Empty -and $null -eq $holderResult.Missing
        ) `
        -Name 'ServiceRecovery/OperationLockHolderReadable' `
        -Failure "Рев'ю PR #432 (B-P2-2): Read-BRAVOOperationLockHolder повертає поля власника lock-а й опис для журналу ('?' для відсутніх), а порожній чи відсутній файл — `$null. Помилка: '$holderError'; результат: $(if ($null -ne $holderResult) { $holderResult | ConvertTo-Json -Compress -Depth 3 })"

    # Статично: peek власника не дублюється — гілка очікування Maintenance і
    # профіль -RecoverServices викликають канонічну функцію.
    $holderRuntimeText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'), [Text.Encoding]::UTF8)
    $holderRecoverText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Maintenance\BRAVO.Maintenance.RecoverServices.ps1'), [Text.Encoding]::UTF8)
    $holderLockStart = $holderRuntimeText.IndexOf('function Enter-BRAVOMaintenanceOperationLock')
    $holderLockEnd = if ($holderLockStart -ge 0) { $holderRuntimeText.IndexOf("`nfunction ", $holderLockStart + 10) } else { -1 }
    $holderLockText = if ($holderLockStart -ge 0 -and $holderLockEnd -gt $holderLockStart) { $holderRuntimeText.Substring($holderLockStart, $holderLockEnd - $holderLockStart) } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $holderLockText.Contains('Read-BRAVOOperationLockHolder -Path $lockPath') -and
            -not $holderLockText.Contains('$peekStream') -and
            $holderRecoverText.Contains('Read-BRAVOOperationLockHolder -Path')
        ) `
        -Name 'ServiceRecovery/OperationLockHolderSingleImplementation' `
        -Failure "Рев'ю PR #432 (B-P2-2): власника lock-а читає лише Read-BRAVOOperationLockHolder — його викликають Enter-BRAVOMaintenanceOperationLock (гілка очікування) і профіль -RecoverServices; власного peek у runtime немає"
}
