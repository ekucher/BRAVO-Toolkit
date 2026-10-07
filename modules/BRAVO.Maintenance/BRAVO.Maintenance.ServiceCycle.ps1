# ============================================================
# Цикл служб BRAVO (#314, хвиля 2): «зупинка служб -> обробка журналів
# (trace BRAVO / exchangAPI / Apache і BRAVO Web) -> запуск у канонічному
# порядку BRAVO -> exchangAPI -> BRAVO Web».
#
# Файл НЕ є самостійним скриптом і не імпортується як модуль: його
# dot-source-ить Invoke-BRAVOMaintenance (BRAVO.Maintenance.Runtime.ps1) у
# власний scope, тож функції нижче — такі самі функції runtime, як і
# решта: бачать змінні тіла через динамічний scope (Write-Log,
# Send-SlackAlert, Invoke-ServiceStateChange, $script:criticalErrorOccurred,
# конфігурацію журналів прогону) і пишуть стан прогону через $script:.
# Цикл винесено сюди, щоб його без копіювання викликали і нічний
# Maintenance, і профіль -RecoverServices (хвилі 3–4 #314).
#
# Явно, параметрами, передається те, що відрізняє профілі: які служби
# керуються (New-BRAVOMaintenanceServiceSet), lifecycle-контракт
# ownership-маркера (#360) — колбеками, намір перезапуску й результати.
# Тіла функцій перенесено з runtime БЕЗ ЗМІН ПОВЕДІНКИ: локальні змінні
# мають ті самі імена, що й у runtime, тож тексти журналу, порядок дій і
# прапорці помилок збігаються дослівно. Поведінку фіксують характеризаційні
# тести suite ServiceRecovery (selftest\BRAVO_SELF_TEST.ServiceRecovery.ps1).
# ============================================================

function Stop-BRAVOMaintenanceStrayProcess {
    # ТОЧКА РОЗШИРЕННЯ #316 (коректне закриття BIS перед реставрацією).
    # Завершення додаткових процесів, що можуть тримати файли моделі (Bis):
    # безумовний Stop-Process -Force.
    # Викликається з Invoke-BRAVOMaintenanceServiceStopSequence безпосередньо
    # перед зупинкою працюючої служби BRAVO, а при -ForceRestore і Disabled
    # BRAVO (#321) — у Disabled-гілці зупинки. Саме ТУТ #316 замінить
    # безумовне завершення на ворота закриття BIS (попередження активних
    # сесій, очікування, потім примусове закриття з записом у журнал); інших
    # місць, де Maintenance завершує Bis, немає.
    $processNames = @("Bis")
    foreach ($procName in $processNames) {
        $process = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($process) {
            Write-Log -Message "Завершення процесу $procName..." -Level "INFO"
            $process | Stop-Process -Force
            Start-Sleep -Seconds 1
        }
    }
}

function New-BRAVOMaintenanceServiceSet {
    # Опис трьох керованих служб для циклу: ключ, ім'я, чи керує ними
    # Maintenance (Managed: встановлена й не Disabled оператором) і чи має
    # служба тип запуску Disabled. Значення передаються як є, без
    # перетворення типів: тіла циклу порівнюють їх так само, як змінні runtime.
    param(
        $BravoName,
        $BravoManaged,
        $BravoDisabled,
        $ExchangeApiName,
        $ExchangeApiManaged,
        $ExchangeApiDisabled,
        $BravoWebName,
        $BravoWebManaged
    )
    return [pscustomobject]@{
        Bravo = [pscustomobject]@{ Key = 'Bravo'; Name = $BravoName; Managed = $BravoManaged; Disabled = $BravoDisabled }
        ExchangeApi = [pscustomobject]@{ Key = 'ExchangeApi'; Name = $ExchangeApiName; Managed = $ExchangeApiManaged; Disabled = $ExchangeApiDisabled }
        BravoWeb = [pscustomobject]@{ Key = 'BravoWeb'; Name = $BravoWebName; Managed = $BravoWebManaged; Disabled = $false }
    }
}

function Invoke-BRAVOMaintenanceServiceStopSequence {
    # Зупинка керованих служб у порядку BRAVO Web -> exchangAPI -> BRAVO.
    # Службу зупиняють лише тоді, коли lifecycle-контракт ($ConfirmStopContract,
    # параметри -Key -Name -Status) підтвердив, що чинний ownership-маркер
    # містить її з наміром перезапуску; підсумок кожної зупинки отримує
    # $CompleteStop (-Key -Name -Result). Перед зупинкою BRAVO завершується Bis
    # (Stop-BRAVOMaintenanceStrayProcess, точка розширення #316); при Disabled
    # BRAVO — лише коли -CloseModelClientsWhenBravoDisabled (-ForceRestore, #321).
    # Збій зупинки — ERROR, критичне сповіщення і $script:criticalErrorOccurred.
    param(
        [Parameter(Mandatory = $true)][object]$ServiceSet,
        [Parameter(Mandatory = $true)][scriptblock]$ConfirmStopContract,
        [Parameter(Mandatory = $true)][scriptblock]$CompleteStop,
        [bool]$CloseModelClientsWhenBravoDisabled = $false,
        [Parameter(Mandatory = $true)][int]$StopTimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$PollIntervalSeconds
    )

    $BravoServiceName = $ServiceSet.Bravo.Name
    $BravoMaintenanceEnabled = $ServiceSet.Bravo.Managed
    $BravoServiceDisabledBySystem = $ServiceSet.Bravo.Disabled
    $ExchangAPIServiceName = $ServiceSet.ExchangeApi.Name
    $exchangAPIServiceEnabled = $ServiceSet.ExchangeApi.Managed
    $exchangAPIServiceDisabled = $ServiceSet.ExchangeApi.Disabled
    $BravoWebServiceName = $ServiceSet.BravoWeb.Name
    $BravoWebMaintenanceEnabled = $ServiceSet.BravoWeb.Managed
    $restoreOnDisabledBravo = $CloseModelClientsWhenBravoDisabled
    $ServiceStopTimeoutSeconds = $StopTimeoutSeconds
    $ServicePollIntervalSeconds = $PollIntervalSeconds

    # 1. Зупинка BRAVO Web
    if ($BravoWebMaintenanceEnabled) {
        try {
            $ApacheService = Get-Service -Name $BravoWebServiceName -ErrorAction Stop
            if (& $ConfirmStopContract -Key 'BravoWeb' -Name $BravoWebServiceName -Status ([string]$ApacheService.Status)) {
                Write-Log -Message "Зупинка служби BRAVO Web ($BravoWebServiceName)..." -Level "INFO"
                $serviceResult = Invoke-ServiceStateChange `
                    -Name $BravoWebServiceName `
                    -DesiredStatus Stopped `
                    -TimeoutSeconds $ServiceStopTimeoutSeconds `
                    -PollIntervalSeconds $ServicePollIntervalSeconds `
                    -Force
                & $CompleteStop -Key 'BravoWeb' -Name $BravoWebServiceName -Result $serviceResult
                if ($serviceResult.Success) {
                    Write-Log -Message "Службу BRAVO Web успішно зупинено" -Level "SUCCESS"
                } else {
                    throw $serviceResult.Error
                }
            } elseif ([string]$ApacheService.Status -eq 'Stopped') {
                Write-Log -Message "Служба BRAVO Web вже зупинена - операція не потрібна" -Level "INFO"
            }
        } catch {
            $errorMsg = "Помилка при зупинці служби BRAVO Web ($BravoWebServiceName): $($_.Exception.Message)"
            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
        }
    }

    # 2. Зупинка exchangAPI. Керування дозволене лише через встановлену
    # Windows-службу, тип запуску якої не Disabled.
    if ($exchangAPIServiceEnabled) {
        # #360: свіжий стан — $exchangAPIService знято на старті прогону, і його
        # закешований Status не бачить служби, запущеної після знімка.
        try {
            # Нечитабельний стан — невідомий, а не «зупинена»: збій читання = критична
            # помилка, служба не вважається зупиненою (як для BRAVO і BRAVO Web).
            $serviceStatus = [string](Get-Service -Name $ExchangAPIServiceName -ErrorAction Stop).Status
            if (& $ConfirmStopContract -Key 'ExchangeApi' -Name $ExchangAPIServiceName -Status $serviceStatus) {
                Write-Log -Message "Зупинка служби $ExchangAPIServiceName..." -Level "INFO"
                $serviceResult = Invoke-ServiceStateChange `
                    -Name $ExchangAPIServiceName `
                    -DesiredStatus Stopped `
                    -TimeoutSeconds $ServiceStopTimeoutSeconds `
                    -PollIntervalSeconds $ServicePollIntervalSeconds `
                    -Force
                & $CompleteStop -Key 'ExchangeApi' -Name $ExchangAPIServiceName -Result $serviceResult
                if ($serviceResult.Success) {
                    Write-Log -Message "Служба $ExchangAPIServiceName успішно зупинена" -Level "SUCCESS"
                } else {
                    $errorMsg = "Не вдалося зупинити службу ${ExchangAPIServiceName}: $($serviceResult.Error)"
                    Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                    Send-SlackAlert -Message $errorMsg -IsCritical
                    $script:criticalErrorOccurred = $true
                }
            } elseif ($serviceStatus -eq 'Stopped') {
                Write-Log -Message "Служба $ExchangAPIServiceName вже зупинена" -Level "INFO"
            }
        } catch {
            $errorMsg = "Помилка при зупинці служби ${ExchangAPIServiceName}: $($_.Exception.Message)"
            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
        }
    } elseif ($exchangAPIServiceDisabled) {
        Write-Log -Message "Служба $ExchangAPIServiceName має тип запуску Disabled - керування пропущено" -Level "INFO"
    }

    # 3. Зупинка служби BRAVO
    if ($BravoMaintenanceEnabled) {
        try {
            $serviceStatus = [string](Get-Service -Name $BravoServiceName).Status

            # #287/#360: зупиняється будь-яка активна служба (зокрема StartPending),
            # а не лише Running — і лише під lifecycle-контрактом маркера.
            if (& $ConfirmStopContract -Key 'Bravo' -Name $BravoServiceName -Status $serviceStatus) {
                Write-Log -Message "Зупинка служби $BravoServiceName..." -Level "INFO"

                # Точка розширення #316: див. Stop-BRAVOMaintenanceStrayProcess.
                Stop-BRAVOMaintenanceStrayProcess

                $serviceResult = Invoke-ServiceStateChange `
                    -Name $BravoServiceName `
                    -DesiredStatus Stopped `
                    -TimeoutSeconds $ServiceStopTimeoutSeconds `
                    -PollIntervalSeconds $ServicePollIntervalSeconds `
                    -Force
                & $CompleteStop -Key 'Bravo' -Name $BravoServiceName -Result $serviceResult
                if ($serviceResult.Success) {
                    Write-Log -Message "Служба $BravoServiceName успішно зупинена" -Level "SUCCESS"
                } else {
                    $errorMsg = "$BravoServiceName не зупинився автоматично: $($serviceResult.Error)"
                    Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                    Send-SlackAlert -Message $errorMsg -IsCritical
                    $script:criticalErrorOccurred = $true
                }
            }
            elseif ($serviceStatus -eq 'Stopped') {
                Write-Log -Message "Служба $BravoServiceName вже зупинена" -Level "INFO"
            }
        } catch {
            $errorMsg = "Помилка при зупинці ${BravoServiceName}: $($_.Exception.Message)"
            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
        }
    } elseif ($BravoServiceDisabledBySystem) {
        Write-Log -Message "Служба $BravoServiceName має тип запуску Disabled - компонент BRAVO пропущено" -Level "INFO"
        if ($restoreOnDisabledBravo) {
            # #321: службу не чіпаємо (уже зупинена, Disabled), але сторонній Bis
            # може тримати файли моделі під час bravocmd — та сама логіка завершення.
            Stop-BRAVOMaintenanceStrayProcess
        }
    } else {
        Write-Log -Message "Службу $BravoServiceName не встановлено - компонент BRAVO пропущено" -Level "INFO"
    }
}

function Invoke-BRAVOMaintenanceServiceLogProcessing {
    # Обробка журналів служб після їх зупинки: trace BRAVO (лише коли
    # -TraceAllowed: служба BRAVO фактично зупинена), журнали exchangAPI і
    # журнали Apache та застосунку BRAVO Web (-WebLogsEnabled) — кожен лише
    # над фактично зупиненою службою, інакше WARNING і журнал не чіпається.
    # Кількості оброблених файлів пишуться в -Counters (ключі
    # TraceOutputProcessed, TraceOutputProcessedCount, ExchangeApiLogsFoundCount,
    # ExchangeApiLogsProcessedCount, WebApacheLogsProcessedCount,
    # WebWwwLogsProcessedCount) у міру обробки. Джерела, каталоги призначення,
    # фільтри, повтори переміщення і $bravoLogRotationLogger — конфігурація
    # прогону з області Invoke-BRAVOMaintenance.
    param(
        [Parameter(Mandatory = $true)][object]$ServiceSet,
        [bool]$TraceAllowed = $false,
        [bool]$WebLogsEnabled = $false,
        [Parameter(Mandatory = $true)][hashtable]$Counters
    )

    $BravoServiceName = $ServiceSet.Bravo.Name
    $BravoMaintenanceEnabled = $ServiceSet.Bravo.Managed
    $ExchangAPIServiceName = $ServiceSet.ExchangeApi.Name
    $exchangAPIServiceEnabled = $ServiceSet.ExchangeApi.Managed
    $BravoWebServiceName = $ServiceSet.BravoWeb.Name
    $BravoWebMaintenanceEnabled = $ServiceSet.BravoWeb.Managed
    $bravoFilePhaseAllowed = $TraceAllowed
    $ApacheEnabled = $WebLogsEnabled

    if ($bravoFilePhaseAllowed) {
        try {
            if ($BravoMaintenanceEnabled) {
                Write-Log -Message "==="
                Write-Log -Message "=== ОБРОБКА TRACE-ФАЙЛІВ ===" -Level "INFO"
                # SRV з невалідною конфігурацією вже прапорцьований критичною
                # помилкою у блоці джерел — тут він просто пропускається
                # (порожній Path), НЕ блокуючи ротацію BIS.
                # Джерела вже перелічені один раз у блоці "ДЖЕРЕЛА ЖУРНАЛІВ"
                # (скан усіх *.out кореня інсталяції + SRV/BIS поза коренем).
                # Порожній перелік — легальний стан (скан неможливий/файлів
                # немає): ротація сама віддасть підсумок "файлів немає".
                # #360/#287: стан BRAVO перечитується безпосередньо перед ротацією —
                # знімок воріт вище знято до реставрації, а службу після нього міг
                # підняти SCM recovery (коли утримання від автостарту не діє).
                $traceRotationBravoStatus = [string](Get-Service -Name $BravoServiceName -ErrorAction SilentlyContinue).Status
                if ($traceRotationBravoStatus -notin @('Stopped', 'Paused')) {
                    throw "службу $BravoServiceName запущено після її зупинки (стан: $traceRotationBravoStatus) — trace-файли не переміщено (#360)"
                }
                $traceRotationSummary = Invoke-BRAVOTraceRotation `
                    -Sources @($traceOutSources) `
                    -DestinationDirectory $TRACE_DIR `
                    -RetryCount $MoveRetryCount `
                    -RetryDelaySeconds $MoveRetryDelaySeconds `
                    -Logger $bravoLogRotationLogger
                $Counters.TraceOutputProcessedCount = [int]$traceRotationSummary.Moved
                $Counters.TraceOutputProcessed = ($Counters.TraceOutputProcessedCount -gt 0)
                if ([int]$traceRotationSummary.Errors -gt 0) {
                    $script:criticalErrorOccurred = $true
                }
            }
        }
        catch {
            $errorMsg = "Помилка при обробці Trace-файлів: $($_.Exception.Message)"
            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
        }
    }

    # Компонент exchangAPI обробляється незалежно, але лише за наявності
    # встановленої та не відключеної служби — і лише коли вона фактично
    # зупинена: переміщувати журнал з-під працюючого застосунку означає або
    # отримати відмову доступу, або відрізати частину записів.
    if ($exchangAPIServiceEnabled) {
        $exchangAPIStatus = try {
            [string](Get-Service -Name $ExchangAPIServiceName -ErrorAction Stop).Status
        } catch {
            'Unknown'
        }
        if ($exchangAPIStatus -eq 'Stopped') {
            try {
                Write-Log "==="
                Write-Log -Message "=== ОБРОБКА ЛОГІВ EXCHANGAPI ===" -Level "INFO"
                # Плоске призначення (без каталогу-дати): нова модель зберігає
                # оригінальні імена і пакує їх у добовий exchangAPI_YYYYMMDD.mdz
                # тим самим движком, що Trace; legacy каталоги-дати не чіпаються.
                $exchangeRotationSummary = Invoke-BRAVOExchangeApiLogRotation `
                    -SourceDirectory ([string]$exchangeApiRuntime.Directory) `
                    -DestinationDirectory $EXCHANGE_LOG_DIR `
                    -Patterns $EXCHANGAPI_LOG_FILTERS `
                    -RetryCount $MoveRetryCount `
                    -RetryDelaySeconds $MoveRetryDelaySeconds `
                    -Logger $bravoLogRotationLogger
                $Counters.ExchangeApiLogsFoundCount = [int]$exchangeRotationSummary.Found
                $Counters.ExchangeApiLogsProcessedCount = [int]$exchangeRotationSummary.Moved
                if ([int]$exchangeRotationSummary.Errors -gt 0) {
                    $script:criticalErrorOccurred = $true
                }
            } catch {
                $errorMsg = "Помилка при обробці логів exchangAPI: $($_.Exception.Message)"
                Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                Send-SlackAlert -Message $errorMsg -IsCritical
                $script:criticalErrorOccurred = $true
            }
        } else {
            Write-Log -Message "Ротацію логів exchangAPI пропущено: службу $ExchangAPIServiceName не зупинено (стан: $exchangAPIStatus)" -Level "WARNING"
        }
    }

    # Компонент BRAVO Web обробляється лише за наявності активної служби,
    # необхідних каталогів і фактично зупиненого Apache: httpd тримає
    # access.log/error.log відкритими, доки працює.
    if ($BravoWebMaintenanceEnabled -and $ApacheEnabled) {
        $bravoWebStatus = try {
            [string](Get-Service -Name $BravoWebServiceName -ErrorAction Stop).Status
        } catch {
            'Unknown'
        }
        if ($bravoWebStatus -eq 'Stopped') {
            try {
                Write-Log "==="
                Write-Log -Message "=== ОБРОБКА ЛОГІВ APACHE ===" -Level "INFO"
                $apacheRotationSummary = Invoke-BRAVOApacheLogRotation `
                    -SourceDirectory $APACHE_LOGS_DIR `
                    -DestinationDirectory $APACHE_DAILY_LOG_DIR `
                    -Filter $APACHE_LOG_FILTER `
                    -RetryCount $MoveRetryCount `
                    -RetryDelaySeconds $MoveRetryDelaySeconds `
                    -Logger $bravoLogRotationLogger
                $Counters.WebApacheLogsProcessedCount = [int]$apacheRotationSummary.Moved

                Write-Log -Message "==="
                Write-Log -Message "=== ОБРОБКА ЛОГІВ BRAVO WEB APPLICATION ===" -Level "INFO"
                $webApplicationRotationSummary = Invoke-BRAVOWebApplicationLogRotation `
                    -SourceDirectory $WWW_LOGS_DIR `
                    -DestinationDirectory $BRAVOWEB_APP_DAILY_LOG_DIR `
                    -Filter $BRAVOWEB_APP_LOG_FILTER `
                    -RetryCount $MoveRetryCount `
                    -RetryDelaySeconds $MoveRetryDelaySeconds `
                    -Logger $bravoLogRotationLogger
                $Counters.WebWwwLogsProcessedCount = [int]$webApplicationRotationSummary.Moved

                if ([int]$apacheRotationSummary.Errors -gt 0 -or
                    [int]$webApplicationRotationSummary.Errors -gt 0) {
                    $script:criticalErrorOccurred = $true
                }
            } catch {
                $errorMsg = "Помилка при обробці логів BRAVO Web: $($_.Exception.Message)"
                Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                Send-SlackAlert -Message $errorMsg -IsCritical
                $script:criticalErrorOccurred = $true
            }
        } else {
            Write-Log -Message "Ротацію логів BRAVO Web пропущено: службу $BravoWebServiceName не зупинено (стан: $bravoWebStatus)" -Level "WARNING"
        }
    }
}

function Invoke-BRAVOMaintenanceServiceStartSequence {
    # Запуск служб у канонічному порядку BRAVO -> exchangAPI -> BRAVO Web.
    # Запускається лише служба з наміром перезапуску (-RestartIntent: ключі
    # Bravo/ExchangeApi/BravoWeb) і лише коли цілісність моделі встановлено
    # ($script:modelIntegrityEstablished); призупинену оператором службу не
    # запускають (#360). Після спроби запуску BRAVO в журнал іде діагностичний
    # рядок про BRAVO Trace (-TraceConfiguration). Будь-який збій запуску —
    # ERROR, критичне сповіщення, $script:criticalErrorOccurred і
    # $Outcome.RestartFailed = $true (ownership-маркер тоді лишається).
    param(
        [Parameter(Mandatory = $true)][object]$ServiceSet,
        [Parameter(Mandatory = $true)][hashtable]$RestartIntent,
        [AllowNull()][object]$TraceConfiguration,
        [Parameter(Mandatory = $true)][int]$StartTimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$PollIntervalSeconds,
        [Parameter(Mandatory = $true)][hashtable]$Outcome
    )

    $BravoServiceName = $ServiceSet.Bravo.Name
    $BravoMaintenanceEnabled = $ServiceSet.Bravo.Managed
    $ExchangAPIServiceName = $ServiceSet.ExchangeApi.Name
    $BravoWebServiceName = $ServiceSet.BravoWeb.Name
    $serviceWasRunning = $RestartIntent
    $traceConfiguration = $TraceConfiguration
    $ServiceStartTimeoutSeconds = $StartTimeoutSeconds
    $ServicePollIntervalSeconds = $PollIntervalSeconds

    # 1. Запуск служби BRAVO
    try {
        # Призупинену оператором службу (Paused, а також PausePending /
        # ContinuePending — той самий набір, що й у фазі зупинки) не запускаємо:
        # Maintenance її не зупиняв, пауза зберігається (#360).
        if ($script:modelIntegrityEstablished -and $serviceWasRunning.Bravo -and [string](Get-Service -Name $BravoServiceName).Status -notin @('Running', 'Paused', 'PausePending', 'ContinuePending')) {
            Write-Log -Message "Запуск служби $BravoServiceName..." -Level "INFO"
            $serviceResult = Invoke-ServiceStateChange `
                -Name $BravoServiceName `
                -DesiredStatus Running `
                -TimeoutSeconds $ServiceStartTimeoutSeconds `
                -PollIntervalSeconds $ServicePollIntervalSeconds
            if ($serviceResult.Success) {
                Write-Log -Message "Служба $BravoServiceName успішно запущена" -Level "SUCCESS"
                $script:bravoServiceStartedThisRun = $true
            } else {
                $errorMsg = "$BravoServiceName не запустився автоматично: $($serviceResult.Error)"
                Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                Send-SlackAlert -Message $errorMsg -IsCritical
                $script:criticalErrorOccurred = $true
                $Outcome.RestartFailed = $true
            }
        }
    } catch {
        $errorMsg = "Помилка при запуску ${BravoServiceName}: $($_.Exception.Message)"
        Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
        Send-SlackAlert -Message $errorMsg -IsCritical
        $script:criticalErrorOccurred = $true
        $Outcome.RestartFailed = $true
    }

    # Діагностика, не перевірка: BRAVO створює trace лише під час першої
    # debug-події, тому його відсутність одразу після старту нормальна. Рядок
    # у журналі потрібен лише для того, щоб при розборі інциденту було видно
    # фактичний стан, а не доводилося здогадуватись. На exit code не впливає.
    if ($BravoMaintenanceEnabled -and $null -ne $traceConfiguration -and $traceConfiguration.IsValid) {
        $traceRecreated = Test-Path -LiteralPath $traceConfiguration.TracePath -PathType Leaf
        Write-Log -Message (
            "BRAVO Trace після запуску служби: $(if ($traceRecreated) { 'створено заново' } else { 'ще не створено (очікувано до першої debug-події)' }) — $($traceConfiguration.TracePath)"
        ) -Level "INFO"
    }

    # 2. Запуск exchangAPI лише через встановлену та не відключену Windows-службу
    # (не піднімаємо, якщо цілісність моделі не встановлено — той самий гейт).
    if ($script:modelIntegrityEstablished -and $serviceWasRunning.ExchangeApi) {
        try {
            $serviceStatus = [string](Get-Service -Name $ExchangAPIServiceName -ErrorAction Stop).Status
            # Призупинену оператором службу (Paused/PausePending/ContinuePending) не запускаємо (#360).
            if ($serviceStatus -notin @('Running', 'Paused', 'PausePending', 'ContinuePending')) {
                Write-Log -Message "Запуск служби $ExchangAPIServiceName..." -Level "INFO"
                $serviceResult = Invoke-ServiceStateChange `
                    -Name $ExchangAPIServiceName `
                    -DesiredStatus Running `
                    -TimeoutSeconds $ServiceStartTimeoutSeconds `
                    -PollIntervalSeconds $ServicePollIntervalSeconds
                if ($serviceResult.Success) {
                    Write-Log -Message "Служба $ExchangAPIServiceName успішно запущена" -Level "SUCCESS"
                } else {
                    throw $serviceResult.Error
                }
            } else {
                Write-Log -Message "Служба $ExchangAPIServiceName вже запущена" -Level "INFO"
            }
        } catch {
            $errorMsg = "Помилка при запуску служби ${ExchangAPIServiceName}: $($_.Exception.Message)"
            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
            $Outcome.RestartFailed = $true
        }
    }

    # 3. Запуск BRAVO Web (виконується останнім; той самий гейт цілісності)
    if ($script:modelIntegrityEstablished -and $serviceWasRunning.BravoWeb) {
        try {
            $ApacheService = Get-Service -Name $BravoWebServiceName -ErrorAction Stop
            # Призупинену оператором службу (Paused/PausePending/ContinuePending) не запускаємо (#360).
            if ([string]$ApacheService.Status -notin @('Running', 'Paused', 'PausePending', 'ContinuePending')) {
                Write-Log -Message "Запуск служби BRAVO Web ($BravoWebServiceName)..." -Level "INFO"
                $serviceResult = Invoke-ServiceStateChange `
                    -Name $BravoWebServiceName `
                    -DesiredStatus Running `
                    -TimeoutSeconds $ServiceStartTimeoutSeconds `
                    -PollIntervalSeconds $ServicePollIntervalSeconds
                if ($serviceResult.Success) {
                    Write-Log -Message "Службу BRAVO Web успішно запущено" -Level "SUCCESS"
                } else {
                    throw $serviceResult.Error
                }
            } else {
                Write-Log -Message "Служба BRAVO Web вже запущена - операція не потрібна" -Level "INFO"
            }
        } catch {
            $errorMsg = "Помилка при запуску служби BRAVO Web ($BravoWebServiceName): $($_.Exception.Message)"
            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
            $Outcome.RestartFailed = $true
        }
    }
}
