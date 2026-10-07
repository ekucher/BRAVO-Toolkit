# Домен-фрагмент self-test: цикл служб нічного Maintenance (#314, хвиля 2) —
# «зупинка служб -> обробка журналів (trace BRAVO / exchangAPI / Apache і
# BRAVO Web) -> запуск у канонічному порядку BRAVO -> exchangAPI -> BRAVO Web».
#
# Характеризаційні тести: фіксують ПОТОЧНУ поведінку циклу (які служби
# зупиняються й запускаються, порядок, що відбувається з журналами,
# ownership-маркер, restartSuppressed, гейт цілісності моделі,
# -RunMissedRestoreOnly, -ForceRestore, завершення Bis перед зупинкою BRAVO)
# через СПРАВЖНЮ оркестрацію Maintenance. Вони однаково проходять до і
# після винесення циклу з BRAVO.Maintenance.Runtime.ps1 у функції
# BRAVO.Maintenance.ServiceCycle.ps1: зміна будь-якого рядка журналу,
# порядку чи складу подій циклу — свідома зміна поведінки, яку мусить
# супроводжувати зміна очікувань тут (хвилі 3–4 #314).
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
            # exchangAPI зупинена до прогону: не зупиняється, не запускається,
            # але її журнали обробляються (служба фактично зупинена).
            'SRExchangeStoppedBeforeRun' = @(
                '$script:ProbeServices = @{ ''BRAVO'' = ''Running''; ''exchangAPI'' = ''Stopped''; ''BravoWeb'' = ''Running'' }'
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
            # -ForceRestore, exchangAPI зупинена до прогону: утримується разом з
            # усіма керованими службами (маркер без наміру перезапуску), її
            # журнали обробляються, але після реставрації її НЕ запускають
            # (поточна поведінка; FR-2 хвилі 3 це змінює).
            'SRForceRestoreExchangeStoppedBeforeRun' = @($serviceRecoveryForceRestoreSeed + @(
                '$script:ProbeServices = @{ ''BRAVO'' = ''Running''; ''exchangAPI'' = ''Stopped''; ''BravoWeb'' = ''Running'' }'
            ))
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
        $srAllStoppedAtStart = @(
            'LOG-WARNING До початку maintenance не запущені служби: BRAVO (Stopped), exchangAPI (Stopped), BravoWeb (Stopped)',
            'LOG-INFO Сповіщення про зупинені служби вимкнено режимом none')
        $srExchangeStoppedAtStart = @(
            'LOG-WARNING До початку maintenance не запущені служби: exchangAPI (Stopped)',
            'LOG-INFO Сповіщення про зупинені служби вимкнено режимом none')
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
        # Рядок пишеться й тоді, коли службу BRAVO не запускали (FR-2 хвилі 3 це змінює).
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

        # (3) exchangAPI зупинена до прогону: поза маркером, не зупиняється й не
        # запускається, але її журнали обробляються.
        & $serviceRecoveryCheck 'SRExchangeStoppedBeforeRun' 10 @(
            $srExchangeStoppedAtStart
            $srStopHeader; 'MARKER-WRITE BRAVO,BravoWeb'
            $srStopWeb; 'LOG-INFO Служба exchangAPI вже зупинена'; $srStopBravoHead; $srStopBravoTail
            'STEP 3/8 Зупинка служб OK'
            $srRestoreSkipped
            $srTraceLogs; $srExchangeLogs; $srWebLogs
            'STEP 6/8 Обробка trace і логів OK'
            $srStartHeader; $srStartBravo; $srTraceAfterStart; $srStartWeb
            $srStartedClean
        ) 'ServiceRecovery/CycleServiceStoppedBeforeRunIsNotStarted' 'служба, зупинена до прогону, не потрапляє в маркер і не запускається (поточна поведінка до FR-2), її журнали обробляються'

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
            $srTraceAfterStart
            'LOG-WARNING Ownership-маркер зупинки служб збережено: не всі служби запустились — Health-watchdog повторить спробу автоматично'
            'STEP 7/8 Відновлення стану служб FAIL'
        ) 'ServiceRecovery/CycleIntegrityGateKeepsServicesStopped' 'без встановленої цілісності моделі жодна служба не запускається, маркер зберігається, код 60'

        # (5) Намір перезапуску від аварійно перерваного прогону (без
        # restartSuppressed) успадковується: BRAVO запускається.
        & $serviceRecoveryCheck 'SRInheritedRestartIntent' 10 @(
            $srAllStoppedAtStart
            'LOG-INFO Успадковано намір перезапуску служб від аварійно перерваного прогону BRAVO_MAINTENANCE: BRAVO — їх буде запущено після обслуговування (#349)'
            $srStopHeader; 'MARKER-WRITE BRAVO'
            $srAlreadyStopped
            'STEP 3/8 Зупинка служб OK'
            $srRestoreSkipped
            $srTraceLogs; $srExchangeLogs; $srWebLogs
            'STEP 6/8 Обробка trace і логів OK'
            $srStartHeader; $srStartBravo; $srTraceAfterStart
            $srStartedClean
        ) 'ServiceRecovery/CycleInheritsRestartIntentWithoutSuppression' 'намір перезапуску з маркера мертвого власника без restartSuppressed успадковується: BRAVO у маркері й запускається'

        # (6) Той самий маркер з restartSuppressed: намір не успадковується —
        # жодного маркера, зупинки чи запуску.
        & $serviceRecoveryCheck 'SRSuppressedRestartIntent' 10 @(
            $srAllStoppedAtStart
            $srAlreadyStopped
            'STEP 3/8 Зупинка служб SKIPPED'
            $srRestoreSkipped
            $srTraceLogs; $srExchangeLogs; $srWebLogs
            'STEP 6/8 Обробка trace і логів OK'
            $srStartHeader; $srTraceAfterStart
            'STEP 7/8 Відновлення стану служб OK'
        ) 'ServiceRecovery/CycleSuppressedRestartIntentNotInherited' 'намір перезапуску з маркера з restartSuppressed не успадковується: жодна служба не запускається'

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

        # (9) -ForceRestore, exchangAPI зупинена до прогону: утримується в маркері
        # без наміру перезапуску й після реставрації лишається зупиненою.
        & $serviceRecoveryCheck 'SRForceRestoreExchangeStoppedBeforeRun' 40 @(
            $srExchangeStoppedAtStart
            $srStopHeader; 'MARKER-WRITE BRAVO,exchangAPI,BravoWeb'; 'MARKER-NO-RESTART exchangAPI'
            $srStopWeb; 'LOG-INFO Служба exchangAPI вже зупинена'; $srStopBravoHead; $srStopBravoTail
            'STEP 3/8 Зупинка служб OK'
            $srRestoreFailed
            $srTraceLogs; $srExchangeLogs; $srWebLogs
            'STEP 6/8 Обробка trace і логів OK'
            $srStartHeader; $srStartBravo; $srTraceAfterStart; $srStartWeb
            $srStartedClean
        ) 'ServiceRecovery/CycleForceRestoreKeepsInitiallyStoppedServiceStopped' '-ForceRestore: зупинена до прогону служба утримується без наміру перезапуску й лишається зупиненою (поточна поведінка до FR-2)'
    } finally {
        if (Test-Path -LiteralPath $serviceRecoveryRoot -PathType Container) {
            Remove-Item -LiteralPath $serviceRecoveryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
