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
function Write-BRAVOServiceQuiescenceState {
    param([string]$Owner, [object[]]$Services, [string]$LogFile, [switch]$RestartSuppressed, [object[]]$StartTypeSnapshot, [switch]$PreserveForeignStartTypeSnapshot)
    if ($script:ProbeMarkerWriteFails) { Add-ProbeEvent 'MARKER-WRITE-FAIL'; throw 'self-test: імітований збій запису ownership-маркера' }
    Add-ProbeEvent ('MARKER-WRITE {0} {1}' -f $Owner, ((@($Services) | ForEach-Object { '{0}={1}' -f $_.Name, [bool]$_.RestartIntent }) -join ','))
}
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
function Invoke-BRAVOExchangeApiLogRotation { param($SourceDirectory, $DestinationDirectory, $Patterns, $RetryCount, $RetryDelaySeconds, $Logger) Add-ProbeEvent 'EXCHANGE-ROTATION'; return [pscustomobject]@{ Found = 1; Moved = 1; Errors = 0 } }
function Invoke-BRAVOApacheLogRotation { param($SourceDirectory, $DestinationDirectory, $Filter, $RetryCount, $RetryDelaySeconds, $Logger) Add-ProbeEvent 'APACHE-ROTATION'; return [pscustomobject]@{ Moved = 1; Errors = 0 } }
function Invoke-BRAVOWebApplicationLogRotation { param($SourceDirectory, $DestinationDirectory, $Filter, $RetryCount, $RetryDelaySeconds, $Logger) Add-ProbeEvent 'WEBAPP-ROTATION'; return [pscustomobject]@{ Moved = 1; Errors = 0 } }
function Get-BRAVOTraceConfiguration { param($DiscoveryResult, $TraceRootDirectory, $DateFolderName) return [pscustomobject]@{ IsValid = $true; TracePath = 'self-test-trace.log'; Reason = $null } }
function Get-BRAVOInstallationTraceOutSources { param($InstallationRoot, $LimsRoot, $SrvTracePath, $ExplicitBisPath) return [pscustomobject]@{ Sources = @(); ScanRoot = 'self-test'; ScanRootReason = 'self-test' } }
function Resolve-BRAVOExchangeApiRuntimeDirectory { param($ServiceName, $FallbackDirectory) return [pscustomobject]@{ Directory = 'self-test'; Reason = 'self-test' } }
function Get-BRAVOWmiInstance { param($ClassName, $Filter) return [pscustomobject]@{ LastBootUpTime = (Get-Date).AddHours(-3) } }
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
            $script:ProbeStrayProcesses = @('Bis')
            $script:ProbeLockBusy = $false
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

        # ТЗ §6 п. 5: lock зайнятий — код 20, без змін і сповіщень, без журналу.
        & $recoverCheck 'RSLockBusy' 20 @('LOCK-BUSY') '' $recoverOk `
            'ServiceRecovery/RecoverServicesLockBusy' `
            '#314 FR-3 крок 3 (ТЗ §6 п. 5): lock зайнятий — код 20, жодної зупинки чи запуску, без сповіщення і без файлу журналу'

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
