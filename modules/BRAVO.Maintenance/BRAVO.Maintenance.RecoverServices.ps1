# ============================================================
# Профіль BRAVO_MAINTENANCE.ps1 -RecoverServices (#314, хвиля 4, FR-3):
# автоматичне відновлення впалих керованих служб BRAVO.
#
# Файл НЕ є самостійним скриптом і не імпортується як модуль: його
# dot-source-ить Invoke-BRAVOMaintenance (BRAVO.Maintenance.Runtime.ps1),
# як і BRAVO.Maintenance.ServiceCycle.ps1. Функції профілю, як і цикл
# служб, бачать змінні тіла runtime через динамічний scope (імена й
# керованість служб, таймаути, каталоги журналів, режим і маршрути
# сповіщень, Write-Log) і пишуть стан прогону через $script:.
# Get-BRAVOServiceRecoveryPlan і Get-BRAVOServiceRecoveryScmEvent змінних
# прогону не читають (усе — параметрами).
#
# Профіль лише піднімає впалі служби: зупинка залежних служб, обробка
# журналів і запуск — тими самими функціями циклу служб, що й нічний
# Maintenance (ServiceCycle.ps1), облік спроб, паузи й сповіщення — функціями
# ServiceRecovery.ps1. Реставрації, перевірки розмірів, очистки, міграції
# журналів, trace-архіву/SFTP, запуску BRAVO_ARCHIV і автовимкнення немає.
#
# Кроки (ТЗ #314 FR-3):
#   1. класифікація без lock-а; жодної впалої служби -> 0, без файлу журналу
#      і без сповіщень (стабільність лічильника спроб — лише під lock-ом);
#   2. для всіх впалих пауза (FR-5) ще не минула -> 0, рядок INFO у добовий
#      файл BRAVO_MAINTENANCE_<дата>_RECOVER_PAUSE.log;
#   3. operation-lock без очікування; зайнятий -> 20 без сповіщення і змін
#      (крім підтвердженого володіння BRAVO_ARCHIV — тоді без lock-а);
#   4-11. під lock-ом: повторна класифікація, ланцюжок, докази, маркер
#      власника BRAVO_MAINTENANCE_RECOVER, журнали, запуск, облік спроби,
#      сповіщення; код 0 / 10 / 60.
# ============================================================

function Get-BRAVOServiceRecoveryPlan {
    # Ланцюжок відновлення (#314 FR-3 крок 5) зі стану керованих служб.
    #   Failed BRAVO       -> зупинити працюючі BRAVO Web і exchangAPI (саме в
    #                         такому порядку), далі запуск BRAVO -> exchangAPI
    #                         -> BRAVO Web;
    #   Failed exchangAPI  -> лише exchangAPI;
    #   Failed BRAVO Web   -> лише BRAVO Web;
    #   кілька впалих      -> об'єднання, запуск у канонічному порядку.
    # Впалою вважається лише служба Failed у стані Stopped. Призупинена
    # (Paused, теж Failed за FR-1) не зупиняється й не запускається
    # (PausedKeys). exchangAPI і BRAVO Web при BRAVO з типом запуску Disabled
    # не піднімаються (DependentSkippedKeys, рішення власника #321). Служба,
    # пауза якої ще не минула (-DeferredKeys), у цей раз не відновлюється.
    # Лише обчислює. Повертає ключі служб (Bravo/ExchangeApi/BravoWeb):
    # { FailedKeys; StopKeys; StartKeys; PausedKeys; DependentSkippedKeys; DeferredKeys }.
    param(
        [Parameter(Mandatory = $true)][object]$ServiceSet,
        [Parameter(Mandatory = $true)][hashtable]$Conditions,
        [AllowEmptyCollection()][string[]]$DeferredKeys = @()
    )

    $failedKeys = @()
    $pausedKeys = @()
    $dependentSkippedKeys = @()
    $deferred = @()
    foreach ($serviceKey in @('Bravo', 'ExchangeApi', 'BravoWeb')) {
        if (-not $Conditions.ContainsKey($serviceKey)) { continue }
        $condition = $Conditions[$serviceKey]
        if ([string]$condition.Condition -ne 'Failed') { continue }
        if ([string]$condition.Status -ne 'Stopped') { $pausedKeys += $serviceKey; continue }
        if ($serviceKey -ne 'Bravo' -and [bool]$ServiceSet.Bravo.Disabled) { $dependentSkippedKeys += $serviceKey; continue }
        if (@($DeferredKeys) -contains $serviceKey) { $deferred += $serviceKey; continue }
        $failedKeys += $serviceKey
    }

    $stopKeys = @()
    if ($failedKeys -contains 'Bravo') {
        foreach ($dependentKey in @('BravoWeb', 'ExchangeApi')) {
            if ($Conditions.ContainsKey($dependentKey) -and [string]$Conditions[$dependentKey].Condition -eq 'Running') {
                $stopKeys += $dependentKey
            }
        }
    }
    $startKeys = @()
    foreach ($serviceKey in @('Bravo', 'ExchangeApi', 'BravoWeb')) {
        if ($failedKeys -contains $serviceKey -or $stopKeys -contains $serviceKey) { $startKeys += $serviceKey }
    }
    return [pscustomobject]@{
        FailedKeys = @($failedKeys)
        StopKeys = @($stopKeys)
        StartKeys = @($startKeys)
        PausedKeys = @($pausedKeys)
        DependentSkippedKeys = @($dependentSkippedKeys)
        DeferredKeys = @($deferred)
    }
}

function Get-BRAVOServiceRecoveryScmEvent {
    # Докази інциденту (#314 FR-3 крок 7): події System log від Service
    # Control Manager (7000, 7009, 7011, 7022, 7023, 7024, 7031, 7034) з
    # моменту -Since, лише ті, параметри яких називають службу з -ServiceNames
    # (ім'я або відображуване ім'я), не більше -MaxEvents найновіших — у
    # хронологічному порядку. Відбір за параметрами події, а не за
    # локалізованим текстом. Не кидає винятку: збій читання повертається в
    # Error (викликач пише WARNING і продовжує). Повертає { Events; Error },
    # подія — { TimeCreated; Id; ServiceName; Message }.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ServiceNames,
        [AllowNull()][object]$Since,
        [int]$MaxEvents = 50
    )

    $result = [pscustomobject]@{ Events = @(); Error = $null }
    $names = @($ServiceNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($names.Count -eq 0) { return $result }
    $filter = @{
        LogName = 'System'
        ProviderName = 'Service Control Manager'
        Id = @(7000, 7009, 7011, 7022, 7023, 7024, 7031, 7034)
    }
    if ($null -ne $Since) { $filter['StartTime'] = [datetime]$Since }
    $rawEvents = @()
    try {
        $rawEvents = @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop)
    } catch {
        # Порожній результат Get-WinEvent повідомляє винятком — це не збій.
        if ([string]$_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
            $result.Error = $_.Exception.Message
        }
        return $result
    }
    $selected = @()
    foreach ($rawEvent in $rawEvents) {
        $values = @()
        if ($null -ne $rawEvent.PSObject.Properties['Properties']) {
            $values = @(@($rawEvent.Properties) | ForEach-Object { [string]$_.Value })
        }
        $matchedName = @($names | Where-Object { $values -contains [string]$_ }) | Select-Object -First 1
        if ($null -eq $matchedName) { continue }
        $messageText = ([string]$rawEvent.Message) -replace '\s+', ' '
        $selected += [pscustomobject]@{
            TimeCreated = $rawEvent.TimeCreated
            Id = [int]$rawEvent.Id
            ServiceName = [string]$matchedName
            Message = $messageText.Trim()
        }
        if ($selected.Count -ge $MaxEvents) { break }
    }
    $result.Events = @($selected | Sort-Object -Property TimeCreated)
    return $result
}

function Get-BRAVOServiceRecoveryBootTime {
    # Час завантаження ОС (Win32_OperatingSystem.LastBootUpTime): [datetime]
    # з CIM або рядок DMTF з WMI. $null, якщо прочитати не вдалося.
    try {
        $operatingSystem = @(Get-BRAVOWmiInstance -ClassName Win32_OperatingSystem) | Select-Object -First 1
        if ($null -eq $operatingSystem) { return $null }
        $bootValue = $operatingSystem.LastBootUpTime
        if ($bootValue -is [datetime]) { return $bootValue }
        if (-not [string]::IsNullOrWhiteSpace([string]$bootValue)) {
            return [Management.ManagementDateTimeConverter]::ToDateTime([string]$bootValue)
        }
    } catch {
        return $null
    }
    return $null
}

function Get-BRAVOServiceRecoveryPowerShellProcess {
    # Процеси PowerShell цього хоста (powershell.exe, pwsh.exe) з командними
    # рядками — Win32_Process через канонічний Get-BRAVOWmiInstance
    # (BRAVO.Compatibility). Кожен — { ProcessId; CommandLine } (порожній
    # CommandLine — рядок не прочитано). Збій запиту — виняток: викликач
    # трактує його як невизначеність (fail-closed).
    return @(@(Get-BRAVOWmiInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'") | ForEach-Object {
            [pscustomobject]@{ ProcessId = ($_.ProcessId -as [int]); CommandLine = [string]$_.CommandLine }
        })
}

function Test-BRAVOServiceRecoveryLockHolderAllowsRecovery {
    # Рев'ю PR #432 (B-P2-2, Codex P1): чи дозволяє власник зайнятого
    # operation-lock відновлення служб без lock-а. Метадані у файлі lock-а
    # можуть бути застарілими: новий власник (Maintenance, DataRestore) уже
    # тримає lock, але ще не переписав JSON попереднього (Archive), — тож
    # непідтверджене володіння = зайнято. Дозволено лише коли ВСЕ підтверджено:
    #   - запис operation 'Archive' (BRAVO_ARCHIV: Archive, BackupCatchUp,
    #     BAZASync — служб не зупиняє й не запускає) цього хоста, з pid і
    #     processStartTime, процес живий (Test-BRAVOProcessAlive);
    #   - командний рядок цього pid (-Processes, Win32_Process) справді
    #     запускає BRAVO_ARCHIV.ps1;
    #   - серед процесів PowerShell (крім -CurrentProcessId) немає
    #     BRAVO_DATA_RESTORE.ps1 і BRAVO_MAINTENANCE.ps1 без -RecoverServices
    #     (нічний Maintenance, -RunMissedRestoreOnly), а командний рядок
    #     кожного прочитано;
    #   - повторне читання власника після паузи (-HolderRecheck) дає той
    #     самий запис (pid, processStartTime, startedAt, operation).
    # Будь-яка невизначеність — Allowed $false з причиною (код 20). Лише
    # обчислює (процес-живий — Test-BRAVOProcessAlive). Повертає { Allowed; Reason }.
    param(
        [AllowNull()][object]$Holder,
        [Parameter(Mandatory = $true)][string]$HostName,
        [AllowNull()][object[]]$Processes,
        [int]$CurrentProcessId = $PID,
        [AllowNull()][object]$HolderRecheck
    )

    $deny = { param([string]$Reason) [pscustomobject]@{ Allowed = $false; Reason = $Reason } }
    if ($null -eq $Holder) { return (& $deny 'метадані власника не прочитано') }
    if ([string]$Holder.Operation -ne 'Archive') { return (& $deny ('власник — ' + [string]$Holder.Operation + ', не BRAVO_ARCHIV')) }
    if ([string]$Holder.HostName -ne $HostName) { return (& $deny 'lock записано іншим хостом') }
    if ($null -eq $Holder.Pid -or [int]$Holder.Pid -le 0) { return (& $deny 'у записі власника немає pid') }
    if ([string]::IsNullOrWhiteSpace([string]$Holder.ProcessStartTime)) { return (& $deny 'у записі власника немає processStartTime') }
    $holderPid = [int]$Holder.Pid
    if (-not [bool](Test-BRAVOProcessAlive -ProcessId $holderPid -ProcessStartTime ([string]$Holder.ProcessStartTime))) {
        return (& $deny ('процес власника pid=' + $holderPid + ' не живий'))
    }
    if ($null -eq $Processes) { return (& $deny 'список процесів PowerShell не прочитано') }
    $holderProcess = @(@($Processes) | Where-Object { $null -ne $_ -and ($_.ProcessId -as [int]) -eq $holderPid }) | Select-Object -First 1
    if ($null -eq $holderProcess -or [string]::IsNullOrWhiteSpace([string]$holderProcess.CommandLine)) {
        return (& $deny ('командний рядок процесу власника pid=' + $holderPid + ' не прочитано'))
    }
    if ([string]$holderProcess.CommandLine -notmatch '(?i)(^|[\\/"''\s])BRAVO_ARCHIV\.ps1\b') {
        return (& $deny ('процес pid=' + $holderPid + ' не є BRAVO_ARCHIV'))
    }
    foreach ($process in @($Processes)) {
        if ($null -eq $process) { continue }
        $processId = $process.ProcessId -as [int]
        if ($processId -eq $CurrentProcessId -or $processId -eq $holderPid) { continue }
        $commandLine = [string]$process.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            return (& $deny ('командний рядок процесу PowerShell pid=' + $processId + ' не прочитано'))
        }
        if ($commandLine -match '(?i)(^|[\\/"''\s])BRAVO_DATA_RESTORE\.ps1\b') {
            return (& $deny ('виконується BRAVO_DATA_RESTORE (pid=' + $processId + ')'))
        }
        if ($commandLine -match '(?i)(^|[\\/"''\s])BRAVO_MAINTENANCE\.ps1\b' -and $commandLine -notmatch '(?i)(^|\s)[-/]RecoverServices\b') {
            return (& $deny ('виконується BRAVO_MAINTENANCE (pid=' + $processId + ')'))
        }
    }
    if ($null -eq $HolderRecheck) { return (& $deny 'повторно метадані власника не прочитано') }
    foreach ($fieldName in @('Operation', 'Pid', 'ProcessStartTime', 'StartedAt', 'HostName')) {
        if ([string]$HolderRecheck.$fieldName -ne [string]$Holder.$fieldName) {
            return (& $deny 'метадані власника змінилися під час перевірки')
        }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = $null }
}

function Resolve-BRAVOServiceRecoveryLockBypass {
    # Збирає докази для Test-BRAVOServiceRecoveryLockHolderAllowsRecovery:
    # власник lock-а (Read-BRAVOOperationLockHolder, BRAVO.System), а для
    # запису Archive — процеси PowerShell і повторне читання власника після
    # паузи -RecheckDelaySeconds. Повертає { Allowed; Reason; Holder }.
    param(
        [AllowNull()][string]$LockPath,
        [int]$RecheckDelaySeconds = 2
    )

    $holder = $null
    if (-not [string]::IsNullOrWhiteSpace($LockPath)) { $holder = Read-BRAVOOperationLockHolder -Path $LockPath }
    $processes = $null
    $holderRecheck = $null
    if ($null -ne $holder -and [string]$holder.Operation -eq 'Archive') {
        try { $processes = @(Get-BRAVOServiceRecoveryPowerShellProcess) } catch { $processes = $null }
        Start-Sleep -Seconds $RecheckDelaySeconds
        $holderRecheck = Read-BRAVOOperationLockHolder -Path $LockPath
    }
    $decision = Test-BRAVOServiceRecoveryLockHolderAllowsRecovery -Holder $holder -HostName ([Environment]::MachineName) `
        -Processes $processes -CurrentProcessId $PID -HolderRecheck $holderRecheck
    return [pscustomobject]@{ Allowed = [bool]$decision.Allowed; Reason = [string]$decision.Reason; Holder = $holder }
}

function Test-BRAVOServiceRecoveryOwnMarkerHeld {
    # Чинний ownership-маркер записав саме цей процес. Відсутній,
    # невалідний, чужий чи нечитабельний маркер — $false: службами вже
    # розпоряджається інший власник (рев'ю PR #432, Codex P1).
    try {
        $markerState = Read-BRAVOServiceQuiescenceState
        if ($null -eq $markerState) { return $false }
        return [bool](Test-BRAVOServiceQuiescenceStateOwnedByCurrentProcess -State $markerState)
    } catch {
        return $false
    }
}

function Convert-BRAVOServiceRecoveryOrphanedOwnConditions {
    # Рев'ю PR #432 (B-P3-1): ownership-маркер власного профілю
    # (BRAVO_MAINTENANCE_RECOVER), чий процес аварійно завершився, не чекає
    # Health-watchdog: служби, які той прогін зупинив із наміром запуску,
    # знову вважаються впалими (OwnedByBravo -> Failed). Лише для маркера без
    # restartSuppressed і без знімка типів запуску (служба не тримається в
    # Disabled; такий маркер перезаписується). Змінює -Conditions на місці;
    # повертає ключі перейнятих служб.
    param(
        [Parameter(Mandatory = $true)][hashtable]$Conditions,
        [AllowNull()][object]$Foreign
    )

    $takenKeys = @()
    if ($null -eq $Foreign -or -not [bool]$Foreign.Present -or [bool]$Foreign.OwnerAlive) { return $takenKeys }
    if ([string]$Foreign.Owner -ne 'BRAVO_MAINTENANCE_RECOVER' -or [bool]$Foreign.RestartSuppressed) { return $takenKeys }
    if (@($Foreign.HeldSnapshot).Count -gt 0) { return $takenKeys }
    foreach ($conditionKey in @($Conditions.Keys)) {
        $condition = $Conditions[$conditionKey]
        if ([string]$condition.Condition -ne 'OwnedByBravo' -or [string]$condition.Status -ne 'Stopped') { continue }
        $heldProperty = $condition.PSObject.Properties['HeldByBravo']
        if ($null -ne $heldProperty -and [bool]$heldProperty.Value) { continue }
        if (@($Foreign.RestartIntentNames) -notcontains [string]$condition.Name) { continue }
        $condition.Condition = 'Failed'
        $takenKeys += $conditionKey
    }
    return $takenKeys
}

function Write-BRAVOMaintenanceServiceRecoveryDayLine {
    # Рядок INFO профілю, що завершився без змін (пауза FR-5, вікно після
    # старту ОС, зайнятий lock): у консоль і в добовий
    # BRAVO_MAINTENANCE_<дата>_RECOVER_PAUSE.log — без окремого журналу
    # прогону на кожен тик тригера.
    param([Parameter(Mandatory = $true)][string]$Message)

    $dayLine = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] [INFO] ' + $Message
    Write-Host $dayLine
    try {
        if (-not (Test-Path -LiteralPath $LOG_DIR -PathType Container)) { [void](New-Item -ItemType Directory -Path $LOG_DIR -Force -ErrorAction Stop) }
        $dayLine | Out-File -FilePath (Join-Path $LOG_DIR ('BRAVO_MAINTENANCE_{0}_RECOVER_PAUSE.log' -f (Get-Date -Format 'yyyyMMdd'))) -Append -Encoding UTF8
    } catch {
        Write-Host "УВАГА: рядок у добовий журнал профілю не записано: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Send-BRAVOMaintenanceServiceRecoveryNotification {
    # Доставка сповіщення #314 FR-6 (зміст — New-BRAVOServiceRecoveryNotificationContent)
    # з режимом і маршрутами сповіщень прогону ($script:SlackMode,
    # $bravoSettings.NotificationRouting, $script:NotificationWebhookUrls) і
    # журналом прогону ($LOG_FILE). Збій доставки — ERROR у журнал (не
    # WARNING: на код завершення не впливає, як і в нічному прогоні).
    param([Parameter(Mandatory = $true)][object]$Content)

    $routingTable = $null
    if ($null -ne $bravoSettings -and $null -ne $bravoSettings.PSObject.Properties['NotificationRouting']) { $routingTable = $bravoSettings.NotificationRouting }
    $delivery = Send-BRAVOServiceRecoveryNotification -Content $Content `
        -NotificationMode ([string]$script:SlackMode) `
        -RoutingTable $routingTable `
        -WebhookUrls $script:NotificationWebhookUrls `
        -LogPath $LOG_FILE `
        -Duration ((Get-Date) - $script:ScriptStartTime)
    if (-not [string]::IsNullOrWhiteSpace([string]$delivery.Error)) {
        Write-Log -Message "Сповіщення «$($Content.Title)» не доставлено: $($delivery.Error)" -Level "ERROR"
    }
}

function Update-BRAVOMaintenanceServiceRecoveryStability {
    # #314 FR-5: обнулення обліку спроб служб, що стабільно працюють
    # (Update-BRAVOServiceRecoveryStability). Викликається лише під
    # operation-lock: state-файл пишуть тільки його власники. -Conditions —
    # класифікація керованих служб (ключ -> стан). Повертає тексти WARNING.
    param(
        [Parameter(Mandatory = $true)][object]$ServiceSet,
        [Parameter(Mandatory = $true)][hashtable]$Conditions,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Now,
        [AllowEmptyCollection()][string[]]$ExcludeKeys = @()
    )

    $warnings = @()
    $read = Read-BRAVOServiceRecoveryState -Path $StatePath -HostName ([Environment]::MachineName) -Now $Now
    if (-not [string]::IsNullOrWhiteSpace([string]$read.Warning)) { $warnings += [string]$read.Warning }
    $changed = $false
    foreach ($serviceKey in @('Bravo', 'ExchangeApi', 'BravoWeb')) {
        if (@($ExcludeKeys) -contains $serviceKey -or -not $Conditions.ContainsKey($serviceKey)) { continue }
        $serviceName = [string]$ServiceSet.$serviceKey.Name
        if (-not $read.State.services.ContainsKey($serviceName)) { continue }
        $stability = Update-BRAVOServiceRecoveryStability -State $read.State -ServiceName $serviceName `
            -IsRunning ([string]$Conditions[$serviceKey].Condition -eq 'Running') -Now $Now
        if ($stability.Changed) { $changed = $true }
    }
    if ($changed) {
        try {
            Write-BRAVOServiceRecoveryState -Path $StatePath -State $read.State -Now $Now
        } catch {
            $warnings += "Облік спроб відновлення служб не записано ($StatePath): $($_.Exception.Message) (#314)"
        }
    }
    return @($warnings)
}

function Test-BRAVOMaintenanceServiceRecoveryStabilityPending {
    # Чи має сенс брати lock для обнулення обліку (крок 1 без впалих служб):
    # те саме Update-BRAVOServiceRecoveryStability над копією стану в пам'яті.
    # Лише читає (пошкоджений файл не перейменовує).
    param(
        [Parameter(Mandatory = $true)][object]$ServiceSet,
        [Parameter(Mandatory = $true)][hashtable]$Conditions,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Now
    )
    foreach ($serviceKey in @('Bravo', 'ExchangeApi', 'BravoWeb')) {
        if (-not $Conditions.ContainsKey($serviceKey)) { continue }
        $serviceName = [string]$ServiceSet.$serviceKey.Name
        if (-not $State.services.ContainsKey($serviceName)) { continue }
        $stability = Update-BRAVOServiceRecoveryStability -State $State -ServiceName $serviceName `
            -IsRunning ([string]$Conditions[$serviceKey].Condition -eq 'Running') -Now $Now
        if ($stability.Changed) { return $true }
    }
    return $false
}

function Get-BRAVOMaintenanceServiceRecoveryDeferredKey {
    # Ключі впалих служб, для яких пауза FR-5 ще не минула, і рядки пояснень.
    param(
        [Parameter(Mandatory = $true)][object]$ServiceSet,
        [AllowEmptyCollection()][string[]]$FailedKeys = @(),
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Now
    )
    $deferredKeys = @()
    $notes = @()
    foreach ($serviceKey in @($FailedKeys)) {
        $serviceName = [string]$ServiceSet.$serviceKey.Name
        $pause = Test-BRAVOServiceRecoveryPauseElapsed -State $State -ServiceName $serviceName -Now $Now
        if ($pause.Elapsed) { continue }
        $deferredKeys += $serviceKey
        $notes += "$serviceName (спроб за добу: $($pause.AttemptsInWindow), пауза $($pause.PauseMinutes) хв, наступна спроба після $($pause.NextAttemptAt.ToLocalTime().ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)))"
    }
    return [pscustomobject]@{ Keys = @($deferredKeys); Notes = @($notes) }
}

function Invoke-BRAVOMaintenanceRecoverServicesProfile {
    # Профіль -RecoverServices (#314 FR-3). Повертає код завершення з
    # BRAVO.ExitCodes: 0 (усе піднято або нічого робити), 10 (піднято з
    # попередженнями або запуск свідомо заблоковано), 20 (operation-lock
    # зайнятий), 30 (несумісні параметри), 60 (не вдалося підняти або
    # непередбачена помилка профілю).
    param(
        [switch]$ForceRestore,
        [switch]$RunMissedRestoreOnly
    )

    if ($ForceRestore -or $RunMissedRestoreOnly) {
        Write-Host "ПОМИЛКА ПАРАМЕТРІВ: -RecoverServices несумісний з -ForceRestore і -RunMissedRestoreOnly" -ForegroundColor Red
        return (Resolve-BRAVOExitCode -InvalidConfiguration)
    }
    # Профіль не вивантажує власний журнал на SFTP (спільний finally runtime).
    $script:maintenanceOwnLogUploadAttempted = $true

    # Стан прогону для сповіщень (рев'ю PR #432): які служби впали, скільки
    # сповіщень FR-6 Failed надіслано і які записи CriticalErrorsList вони
    # покривають (збої запуску служб).
    $outcome = @{
        ServiceSet = $null; FailedKeys = @(); NotifiedKeys = @(); FailedNotifications = 0
        CoveredCriticalFrom = -1; CoveredCriticalTo = -1; CriticalAtStart = [bool]$script:criticalErrorOccurred
    }
    try {
        return (Invoke-BRAVOMaintenanceRecoverServicesSteps -Outcome $outcome)
    } catch {
        # Рев'ю PR #432 (B-P3-4): непередбачений виняток — критична помилка
        # прогону (код 60) і FR-6 Failed для впалих служб, а не код 1.
        $profileError = "непередбачена помилка профілю -RecoverServices: $($_.Exception.Message)"
        $script:criticalErrorOccurred = $true
        try { Write-Log -Message "ПОМИЛКА: $profileError" -Level "ERROR" } catch { Write-Host "ПОМИЛКА: $profileError" -ForegroundColor Red }
        $unnotifiedKeys = @(@($outcome.FailedKeys) | Where-Object { @($outcome.NotifiedKeys) -notcontains $_ })
        if ($null -ne $outcome.ServiceSet -and $unnotifiedKeys.Count -gt 0) {
            foreach ($failedKey in $unnotifiedKeys) {
                Send-BRAVOMaintenanceServiceRecoveryNotification -Content (New-BRAVOServiceRecoveryNotificationContent -Kind Failed `
                    -ServiceName ([string]$outcome.ServiceSet.$failedKey.Name) -ExitCode $null -Reason $profileError -LogPath $LOG_FILE)
                $outcome.FailedNotifications++
            }
        } else {
            $script:CriticalErrorsList.Add($profileError)
        }
        return (Get-BRAVOMaintenanceResolvedExitCode)
    } finally {
        Send-BRAVOMaintenanceServiceRecoveryRunAlerts -Outcome $outcome
    }
}

function Send-BRAVOMaintenanceServiceRecoveryRunAlerts {
    # Рев'ю PR #432 (B-P2-1): доставка критичних помилок і попереджень
    # прогону, які не покриває FR-6 про конкретну службу. Записи
    # CriticalErrorsList про збій запуску служб ([CoveredCriticalFrom,
    # CoveredCriticalTo)) пропускаються, лише коли на них уже надіслано
    # стільки ж FR-6 Failed; решта (збій зупинки, ротації журналів, виняток)
    # — одним сповіщенням. Лічильники доставлених зсуваються до кінця черг:
    # страховка спільного finally runtime (Send-BRAVOMaintenanceEarlyExitAlerts)
    # нічого не дублює. Критичний збій без тексту (лише прапорець) теж
    # доставляється, якщо жодного FR-6 Failed не було.
    param([Parameter(Mandatory = $true)][hashtable]$Outcome)

    $criticalList = $script:CriticalErrorsList
    $alertQueue = $script:NotificationAlertQueue
    $coveredFrom = [int]$Outcome.CoveredCriticalFrom
    $coveredTo = [int]$Outcome.CoveredCriticalTo
    $skipCovered = ($coveredTo -gt $coveredFrom) -and ([int]$Outcome.FailedNotifications -ge ($coveredTo - $coveredFrom))
    $pendingCritical = @()
    for ($criticalIndex = [int]$script:maintenanceDeliveredCriticalAlertCount; $criticalIndex -lt $criticalList.Count; $criticalIndex++) {
        if ($skipCovered -and $criticalIndex -ge $coveredFrom -and $criticalIndex -lt $coveredTo) { continue }
        $pendingCritical += [string]$criticalList[$criticalIndex]
    }
    $pendingQueue = @()
    for ($queueIndex = [int]$script:maintenanceDeliveredAlertQueueCount; $queueIndex -lt $alertQueue.Count; $queueIndex++) {
        $pendingQueue += $alertQueue[$queueIndex]
    }
    $script:maintenanceDeliveredCriticalAlertCount = $criticalList.Count
    $script:maintenanceDeliveredAlertQueueCount = $alertQueue.Count
    $criticalWithoutDetails = [bool]$script:criticalErrorOccurred -and -not [bool]$Outcome.CriticalAtStart -and
        $pendingCritical.Count -eq 0 -and [int]$Outcome.FailedNotifications -eq 0
    if ($pendingCritical.Count -eq 0 -and $pendingQueue.Count -eq 0 -and -not $criticalWithoutDetails) { return }
    Send-BRAVOMaintenanceServiceRecoveryNotification -Content (New-BRAVOServiceRecoveryRunAlertContent `
        -CriticalMessages $pendingCritical -QueuedAlerts $pendingQueue -CriticalWithoutDetails:$criticalWithoutDetails -LogPath $LOG_FILE)
}

function Invoke-BRAVOMaintenanceRecoverServicesSteps {
    # Кроки 1-11 профілю -RecoverServices; -Outcome — стан для сповіщень
    # (див. Invoke-BRAVOMaintenanceRecoverServicesProfile).
    param([Parameter(Mandatory = $true)][hashtable]$Outcome)

    $serviceSet = New-BRAVOMaintenanceServiceSet `
        -BravoName $BravoServiceName -BravoManaged $BravoMaintenanceEnabled -BravoDisabled $BravoServiceDisabledBySystem `
        -ExchangeApiName $ExchangAPIServiceName -ExchangeApiManaged $exchangAPIServiceEnabled -ExchangeApiDisabled $exchangAPIServiceDisabled `
        -BravoWebName $BravoWebServiceName -BravoWebManaged $BravoWebMaintenanceEnabled
    $now = [DateTimeOffset]::Now
    $statePath = $null
    try { $statePath = Get-BRAVOServiceRecoveryStatePath } catch { $statePath = $null }

    # Крок 1: класифікація без lock-а. Нічого не пишемо на диск.
    $Outcome.ServiceSet = $serviceSet
    $conditions = Get-BRAVOMaintenanceServiceConditionSet -ServiceSet $serviceSet
    [void](Convert-BRAVOServiceRecoveryOrphanedOwnConditions -Conditions $conditions -Foreign (Get-BRAVOForeignServiceQuiescenceContext))
    $plan = Get-BRAVOServiceRecoveryPlan -ServiceSet $serviceSet -Conditions $conditions
    $Outcome.FailedKeys = @($plan.FailedKeys)
    $quietState = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$statePath)) {
        $quietState = (Read-BRAVOServiceRecoveryState -Path $statePath -HostName ([Environment]::MachineName) -Now $now -ReadOnly).State
    }
    if ($plan.FailedKeys.Count -eq 0) {
        # Облік спроб обнуляється лише під lock-ом і лише тоді, коли є що змінювати.
        if ($null -ne $quietState -and (Test-BRAVOMaintenanceServiceRecoveryStabilityPending -ServiceSet $serviceSet -Conditions $conditions -State $quietState -Now $now)) {
            $stabilityLock = Enter-BRAVOMaintenanceOperationLock -TaskType Maintenance -NoWait
            if ($stabilityLock.Success) {
                $script:maintenanceOperationLock = $stabilityLock.Stream
                $script:maintenanceOperationLockPath = $stabilityLock.Path
                try {
                    foreach ($stabilityWarning in @(Update-BRAVOMaintenanceServiceRecoveryStability -ServiceSet $serviceSet -Conditions $conditions -StatePath $statePath -Now $now)) {
                        Write-Host "УВАГА: $stabilityWarning" -ForegroundColor Yellow
                    }
                } finally {
                    Exit-BRAVOMaintenanceOperationLock
                }
            }
        }
        Write-Host "Відновлення служб: впалих керованих служб немає"
        return 0
    }

    # Рев'ю PR #432 (A-P3-4 / B-P3-3, Codex P1): перші хвилини після старту
    # ОС служби піднімає boot-тригер (-RunMissedRestoreOnly, з урахуванням
    # HoldServices); event- чи daily-тригер профілю не випереджає його. Для
    # HoldServices вікно виводиться із затримки boot-тригера Recovery
    # (Restore.StartupDelayMinutes), а поки пропущена реставрація чекає
    # ($automaticRestoreDue runtime: персистентний BRAVO_RESTORE_STATE.json),
    # гейт закритий без обмеження часу (Codex, раунд 2).
    $restoreSettings = $null
    $maintenanceSettingsValue = Get-Variable -Name maintenanceSettings -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $maintenanceSettingsValue -and $maintenanceSettingsValue -is [System.Collections.IDictionary] -and $maintenanceSettingsValue.Contains('Restore')) { $restoreSettings = $maintenanceSettingsValue.Restore }
    $bootRestoreMode = $null
    $startupDelayMinutes = $null
    if ($restoreSettings -is [System.Collections.IDictionary]) {
        if ($restoreSettings.Contains('BootRestoreMode')) { $bootRestoreMode = [string]$restoreSettings.BootRestoreMode }
        if ($restoreSettings.Contains('StartupDelayMinutes')) { $startupDelayMinutes = $restoreSettings.StartupDelayMinutes }
    }
    # Невідомий стан реставрації — як «ще чекає» (гейт закритий, fail-closed).
    $restorePendingVariable = Get-Variable -Name automaticRestoreDue -ErrorAction SilentlyContinue
    $restorePending = ($null -eq $restorePendingVariable) -or [bool]$restorePendingVariable.Value
    $bootGate = Get-BRAVOServiceRecoveryBootGate -BootTime (Get-BRAVOServiceRecoveryBootTime) -Now (Get-Date) `
        -BootRestoreMode $bootRestoreMode -StartupDelayMinutes $startupDelayMinutes -RestorePending $restorePending
    if ($bootGate.Defer) {
        Write-BRAVOMaintenanceServiceRecoveryDayLine -Message ('Відновлення служб відкладено: ' + [string]$bootGate.Reason + ' — службами після старту розпоряджається boot-тригер; служби не змінювались')
        return 0
    }

    # Крок 2: паузи між спробами (FR-5).
    if ($null -ne $quietState) {
        $deferred = Get-BRAVOMaintenanceServiceRecoveryDeferredKey -ServiceSet $serviceSet -FailedKeys $plan.FailedKeys -State $quietState -Now $now
        if ($deferred.Keys.Count -eq $plan.FailedKeys.Count) {
            Write-BRAVOMaintenanceServiceRecoveryDayLine -Message ('Відновлення служб відкладено: пауза між спробами ще не минула — ' + (@($deferred.Notes) -join '; '))
            return 0
        }
    }

    # Крок 3: operation-lock без очікування. Зайнятий нічним Maintenance чи
    # DataRestore — власник сам підніме служби (код 20). Зайнятий BRAVO_ARCHIV
    # (Archive / BackupCatchUp / BAZASync, operation=Archive) — він служб не
    # зупиняє й не запускає, тож відновлення йде без lock-а (рев'ю PR #432,
    # B-P2-2), але лише коли володіння Archive ПІДТВЕРДЖЕНО (Codex P1: метадані
    # lock-а бувають застарілими) — Resolve-BRAVOServiceRecoveryLockBypass; будь-яка
    # невизначеність — код 20. Без lock-а: маркер fail-closed, перед кожним
    # запуском служби — перевірка, що маркер досі наш, state-файл атомарний, а
    # реставрацію від запущених служб захищає Confirm-BRAVOServicesQuiesced.
    $lockResult = Enter-BRAVOMaintenanceOperationLock -TaskType Maintenance -NoWait
    $lockHeld = [bool]$lockResult.Success
    $lockHolder = $null
    if (-not $lockHeld) {
        $lockBypass = Resolve-BRAVOServiceRecoveryLockBypass -LockPath ([string]$lockResult.Path)
        $lockHolder = $lockBypass.Holder
        if (-not $lockBypass.Allowed) {
            $holderText = 'невідомо'
            if ($null -ne $lockHolder) { $holderText = [string]$lockHolder.Description }
            $bypassText = ''
            if ($null -ne $lockHolder -and [string]$lockHolder.Operation -eq 'Archive') { $bypassText = '; відновлення без lock-а не підтверджено: ' + [string]$lockBypass.Reason }
            Write-BRAVOMaintenanceServiceRecoveryDayLine -Message ('Відновлення служб відкладено: операційний lock зайнятий (' + [string]$lockResult.Path + '); тримає: ' + $holderText + $bypassText + '; служби не змінювались')
            return (Resolve-BRAVOExitCode -LockBusy)
        }
    } else {
        $script:maintenanceOperationLock = $lockResult.Stream
        $script:maintenanceOperationLockPath = $lockResult.Path
    }
    try {
        $script:LOG_FILE = Join-Path $LOG_DIR ('BRAVO_MAINTENANCE_{0}_RECOVER_PID{1}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $PID)
        if (-not $lockHeld) {
            Write-Log -Message ('Операційний lock (' + [string]$lockResult.Path + ') тримає BRAVO_ARCHIV (' + [string]$lockHolder.Description + '): він служб не зупиняє — відновлення виконується без lock-а') -Level "INFO"
        }
        Invoke-BRAVOMaintenanceServiceRecoveryUnderLock -ServiceSet $serviceSet -StatePath $statePath -Outcome $Outcome -LockHeld $lockHeld
        $exitCode = Get-BRAVOMaintenanceResolvedExitCode
        $finalStatus = Get-BRAVOMaintenanceFinalStatus -ExitCode $exitCode
        Write-Log -Message "=== СТАТУС: $($finalStatus.Text) ($exitCode — $(Get-BRAVOExitCodeName -Code $exitCode)) ===" -Level "INFO"
        Write-Host "Відновлення служб: $($finalStatus.Text), код $exitCode. Журнал: $LOG_FILE" -ForegroundColor $finalStatus.Color
        return $exitCode
    } finally {
        # Критичні алерти, не покриті FR-6, доставляє
        # Send-BRAVOMaintenanceServiceRecoveryRunAlerts (finally профілю).
        if ($lockHeld) { Exit-BRAVOMaintenanceOperationLock }
    }
}

function Invoke-BRAVOMaintenanceServiceRecoveryUnderLock {
    # Кроки 4-11 FR-3 під operation-lock. Результат — у прапорцях прогону
    # ($script:criticalErrorOccurred, лічильник WARNING), з них викликач
    # обчислює код завершення. -LockHeld $false — lock тримає підтверджений
    # BRAVO_ARCHIV (Resolve-BRAVOServiceRecoveryLockBypass): перед кожним
    # запуском служби перевіряється, що ownership-маркер досі наш.
    param(
        [Parameter(Mandatory = $true)][object]$ServiceSet,
        [AllowNull()][string]$StatePath,
        [hashtable]$Outcome = @{ NotifiedKeys = @(); FailedNotifications = 0; CoveredCriticalFrom = -1; CoveredCriticalTo = -1 },
        [bool]$LockHeld = $true
    )

    $now = [DateTimeOffset]::Now
    Write-Log -Message "=== ВІДНОВЛЕННЯ СЛУЖБ (-RecoverServices, #314) ===" -Level "INFO"

    # Крок 4: повторна класифікація під lock-ом (стан міг змінитися).
    $conditions = Get-BRAVOMaintenanceServiceConditionSet -ServiceSet $ServiceSet
    $state = $null
    if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
        $stateRead = Read-BRAVOServiceRecoveryState -Path $StatePath -HostName ([Environment]::MachineName) -Now $now
        if (-not [string]::IsNullOrWhiteSpace([string]$stateRead.Warning)) { Write-Log -Message ([string]$stateRead.Warning) -Level "WARNING" }
        $state = $stateRead.State
    }

    # Чинний маркер іншого власника або гейт цілісності моделі: не втручаємось.
    # Осиротілий маркер власного профілю переймається (B-P3-1): його служби
    # знову впалі, а маркер перезапише крок 6.
    $foreign = Get-BRAVOForeignServiceQuiescenceContext
    $takenKeys = @(Convert-BRAVOServiceRecoveryOrphanedOwnConditions -Conditions $conditions -Foreign $foreign)
    if ($takenKeys.Count -gt 0) {
        Write-Log -Message "Перейнято ownership-маркер аварійно перерваного прогону $($foreign.Owner): служби $(@($takenKeys | ForEach-Object { $ServiceSet.$_.Name }) -join ', ') знову вважаються впалими" -Level "INFO"
    } elseif ($foreign.Present) {
        if ($foreign.OwnerAlive) {
            Write-Log -Message "Службами розпоряджається $($foreign.Owner) (ownership-маркер живого процесу) — профіль -RecoverServices не втручається" -Level "INFO"
        } elseif ($foreign.RestartSuppressed) {
            Write-Log -Message "Попередній прогін $($foreign.Owner) перервано посеред реставрації (restartSuppressed): цілісність моделі не підтверджено, служби не запускаються — потрібне ручне відновлення (#314)" -Level "WARNING"
        } else {
            Write-Log -Message "Знайдено ownership-маркер аварійно перерваного прогону $($foreign.Owner): службами, які він зупинив, займається Health-watchdog — профіль -RecoverServices не втручається" -Level "INFO"
        }
        return
    }
    if (-not $script:modelIntegrityEstablished) {
        Write-Log -Message "Цілісність моделі не встановлено — служби не запускаються (#314)" -Level "WARNING"
        return
    }

    $initialPlan = Get-BRAVOServiceRecoveryPlan -ServiceSet $ServiceSet -Conditions $conditions
    $deferredKeys = @()
    if ($null -ne $state) {
        $deferred = Get-BRAVOMaintenanceServiceRecoveryDeferredKey -ServiceSet $ServiceSet -FailedKeys $initialPlan.FailedKeys -State $state -Now $now
        $deferredKeys = @($deferred.Keys)
        foreach ($deferredNote in @($deferred.Notes)) {
            Write-Log -Message "Відновлення служби відкладено: пауза між спробами ще не минула — $deferredNote" -Level "INFO"
        }
    }
    $plan = Get-BRAVOServiceRecoveryPlan -ServiceSet $ServiceSet -Conditions $conditions -DeferredKeys $deferredKeys
    foreach ($pausedKey in @($plan.PausedKeys)) {
        Write-Log -Message "Служба $($ServiceSet.$pausedKey.Name) у стані $($conditions[$pausedKey].Status) — профіль її не запускає, стан збережено" -Level "INFO"
    }
    foreach ($dependentKey in @($plan.DependentSkippedKeys)) {
        Write-Log -Message "Служба $($ServiceSet.$dependentKey.Name) зупинена й не запускатиметься: вона залежить від служби $($ServiceSet.Bravo.Name), яка має тип запуску Disabled" -Level "INFO"
    }
    if ($plan.FailedKeys.Count -eq 0) {
        Write-Log -Message "Під операційним lock-ом впалих служб для відновлення немає" -Level "INFO"
        if ($null -ne $state) {
            foreach ($stabilityWarning in @(Update-BRAVOMaintenanceServiceRecoveryStability -ServiceSet $ServiceSet -Conditions $conditions -StatePath $StatePath -Now $now)) {
                Write-Log -Message $stabilityWarning -Level "WARNING"
            }
        }
        return
    }
    $chainKeys = @(@('Bravo', 'ExchangeApi', 'BravoWeb') | Where-Object { $plan.StartKeys -contains $_ -or $plan.StopKeys -contains $_ })
    $chainNames = @($chainKeys | ForEach-Object { [string]$ServiceSet.$_.Name })
    Write-Log -Message "Впалі служби: $(@($plan.FailedKeys | ForEach-Object { $ServiceSet.$_.Name }) -join ', '); зупинка: $(if ($plan.StopKeys.Count -gt 0) { @($plan.StopKeys | ForEach-Object { $ServiceSet.$_.Name }) -join ' -> ' } else { 'не потрібна' }); запуск: $(@($plan.StartKeys | ForEach-Object { $ServiceSet.$_.Name }) -join ' -> ')" -Level "INFO"

    # Крок 7: докази інциденту — до будь-якої зміни стану служб.
    $eventNames = @($chainNames)
    $serviceEventNames = @{}
    foreach ($chainKey in $chainKeys) {
        $serviceEventNames[$chainKey] = @([string]$ServiceSet.$chainKey.Name)
        $condition = $conditions[$chainKey]
        Write-Log -Message "Служба $($ServiceSet.$chainKey.Name): StartMode=$($condition.StartMode); Status=$($condition.Status); ExitCode=$($condition.ExitCode); ServiceSpecificExitCode=$($condition.ServiceSpecificExitCode)" -Level "INFO"
        try {
            $displayName = [string](Get-Service -Name ([string]$ServiceSet.$chainKey.Name) -ErrorAction Stop).DisplayName
            if (-not [string]::IsNullOrWhiteSpace($displayName)) {
                $eventNames += $displayName
                $serviceEventNames[$chainKey] += $displayName
            }
        } catch {
            # Відображуване ім'я — лише для відбору подій; ім'я служби вже є.
        }
    }
    $bootTime = Get-BRAVOServiceRecoveryBootTime
    $eventsSince = $bootTime
    if ($null -eq $eventsSince) {
        $eventsSince = (Get-Date).AddHours(-24)
        Write-Log -Message "Час завантаження ОС не визначено — події Service Control Manager читаються за останні 24 год" -Level "INFO"
    }
    $scmEvents = Get-BRAVOServiceRecoveryScmEvent -ServiceNames $eventNames -Since $eventsSince -MaxEvents 50
    if (-not [string]::IsNullOrWhiteSpace([string]$scmEvents.Error)) {
        Write-Log -Message "Події Service Control Manager не прочитано: $($scmEvents.Error)" -Level "WARNING"
    } else {
        Write-Log -Message "Події Service Control Manager з $(([datetime]$eventsSince).ToString('yyyy-MM-dd HH:mm:ss')): $(@($scmEvents.Events).Count)" -Level "INFO"
        foreach ($scmEvent in @($scmEvents.Events)) {
            Write-Log -Message "Подія $($scmEvent.Id) $(([datetime]$scmEvent.TimeCreated).ToString('yyyy-MM-dd HH:mm:ss')) [$($scmEvent.ServiceName)]: $($scmEvent.Message)" -Level "INFO"
        }
    }

    # Крок 6: ownership-маркер перед першою зупинкою або запуском (fail-closed).
    try {
        [void](Write-BRAVOServiceQuiescenceState `
            -Owner 'BRAVO_MAINTENANCE_RECOVER' `
            -Services @($chainNames | ForEach-Object { @{ Name = $_; RestartIntent = $true } }) `
            -LogFile ([string]$LOG_FILE))
    } catch {
        $markerError = "ownership-маркер не записано, служби не змінювались: $($_.Exception.Message)"
        Write-Log -Message "ПОМИЛКА: відновлення служб скасовано — $markerError" -Level "ERROR"
        $script:criticalErrorOccurred = $true
        foreach ($failedKey in @($plan.FailedKeys)) {
            Send-BRAVOMaintenanceServiceRecoveryNotification -Content (New-BRAVOServiceRecoveryNotificationContent -Kind Failed `
                -ServiceName ([string]$ServiceSet.$failedKey.Name) -ExitCode $conditions[$failedKey].ExitCode `
                -ServiceSpecificExitCode $conditions[$failedKey].ServiceSpecificExitCode -Reason $markerError -LogPath $LOG_FILE)
            $Outcome.FailedNotifications++
            $Outcome.NotifiedKeys += $failedKey
        }
        return
    }

    # Зупинка працюючих залежних служб (лише ті, що в ланцюжку).
    $restartIntent = @{
        Bravo = ($plan.StartKeys -contains 'Bravo')
        ExchangeApi = ($plan.StartKeys -contains 'ExchangeApi')
        BravoWeb = ($plan.StartKeys -contains 'BravoWeb')
    }
    $chainServiceSet = New-BRAVOMaintenanceServiceSet `
        -BravoName $ServiceSet.Bravo.Name -BravoManaged ($chainKeys -contains 'Bravo') -BravoDisabled $ServiceSet.Bravo.Disabled `
        -ExchangeApiName $ServiceSet.ExchangeApi.Name -ExchangeApiManaged ($chainKeys -contains 'ExchangeApi') -ExchangeApiDisabled $false `
        -BravoWebName $ServiceSet.BravoWeb.Name -BravoWebManaged ($chainKeys -contains 'BravoWeb')
    $stopKeys = @($plan.StopKeys)
    # Рев'ю PR #432 (B-P3-6): «зупинено, але не запущено» — лише про службу,
    # яку справді зупинили (таймаут зупинки зі службою в Running — це збій
    # зупинки, про нього вже є CRITICAL циклу служб).
    $stopCompleted = @{}
    if ($stopKeys.Count -gt 0) {
        Write-Log -Message "=== ЗУПИНКА ЗАЛЕЖНИХ СЛУЖБ ===" -Level "INFO"
        Invoke-BRAVOMaintenanceServiceStopSequence `
            -ServiceSet $chainServiceSet `
            -ConfirmStopContract { param($Key, $Name, $Status) ($stopKeys -contains $Key) -and $Status -in @('Running', 'StartPending') } `
            -CompleteStop { param($Key, $Name, $Result)
                $stopCompleted[$Key] = ([bool]$Result.Success -or [string]$Result.FinalStatus -eq 'Stopped')
                if ([string]$Result.FinalStatus -in @('Paused', 'PausePending', 'ContinuePending')) { $restartIntent[$Key] = $false } } `
            -StopTimeoutSeconds $ServiceStopTimeoutSeconds `
            -PollIntervalSeconds $ServicePollIntervalSeconds
    }

    # Крок 8: журнали — тими самими функціями, що й уночі (лише служби ланцюжка).
    $bravoLogRotationLogger = { param($Message, $Level) Write-Log -Message $Message -Level $Level }
    $traceConfiguration = $null
    $traceOutSources = @()
    $exchangeApiRuntime = $null
    try {
        if ($chainKeys -contains 'Bravo') {
            $traceConfiguration = Get-BRAVOTraceConfiguration `
                -DiscoveryResult $bravoDiscoveryResult `
                -TraceRootDirectory $TRACE_DIR `
                -DateFolderName $LOG_DATE_FOLDER
            $traceSrvPath = ''
            if ($null -ne $traceConfiguration -and $traceConfiguration.IsValid) {
                $traceSrvPath = [string]$traceConfiguration.TracePath
            } else {
                Write-Log -Message "Журнал BRAVO Trace не визначено (bravo.ini, [Debug]/FILE): $(if ($null -ne $traceConfiguration) { $traceConfiguration.Reason })" -Level "WARNING"
            }
            $traceOutSources = @((Get-BRAVOInstallationTraceOutSources `
                -InstallationRoot ([string]$bravoDiscoveryResult.BRAVO_ROOT) `
                -LimsRoot $ROOT_LIMS `
                -SrvTracePath $traceSrvPath `
                -ExplicitBisPath ([string]$MaintenanceConfig.Trace.BISSourcePath)).Sources)
        }
        if ($chainKeys -contains 'ExchangeApi') {
            $exchangeApiRuntime = Resolve-BRAVOExchangeApiRuntimeDirectory `
                -ServiceName ([string]$ServiceSet.ExchangeApi.Name) `
                -FallbackDirectory $ROOT_LIMS
        }
    } catch {
        Write-Log -Message "Джерела журналів служб не визначено: $($_.Exception.Message)" -Level "WARNING"
    }
    $serviceLogCounters = @{
        TraceOutputProcessed = $false; TraceOutputProcessedCount = 0
        ExchangeApiLogsFoundCount = 0; ExchangeApiLogsProcessedCount = 0
        WebApacheLogsProcessedCount = 0; WebWwwLogsProcessedCount = 0
    }
    Invoke-BRAVOMaintenanceServiceLogProcessing `
        -ServiceSet $chainServiceSet `
        -TraceAllowed ($plan.FailedKeys -contains 'Bravo') `
        -WebLogsEnabled ([bool]$ApacheEnabled) `
        -Counters $serviceLogCounters

    # Крок 9: запуск у канонічному порядку — по одній службі тим самим циклом
    # служб. Без lock-а (рев'ю PR #432, Codex P1) перед кожним запуском маркер
    # має бути досі наш: інакше lock і службами розпоряджається інший власник (нічний
    # Maintenance перезаписує маркер) — запуск скасовується, WARNING.
    Write-Log -Message "=== ЗАПУСК СЛУЖБ ===" -Level "INFO"
    $startOutcome = @{ RestartFailed = $false; Attempted = @{}; Started = @{} }
    $Outcome.CoveredCriticalFrom = $script:CriticalErrorsList.Count
    foreach ($startKey in @('Bravo', 'ExchangeApi', 'BravoWeb')) {
        if (-not $restartIntent[$startKey]) { continue }
        if (-not $LockHeld -and -not (Test-BRAVOServiceRecoveryOwnMarkerHeld)) {
            Write-Log -Message "Ownership-маркер більше не належить профілю -RecoverServices (його перейняв інший власник) — запуск служб скасовано, службами розпоряджається він" -Level "WARNING"
            break
        }
        $keyOutcome = @{ RestartFailed = $false }
        Invoke-BRAVOMaintenanceServiceStartSequence `
            -ServiceSet $chainServiceSet `
            -RestartIntent @{ Bravo = ($startKey -eq 'Bravo'); ExchangeApi = ($startKey -eq 'ExchangeApi'); BravoWeb = ($startKey -eq 'BravoWeb') } `
            -TraceConfiguration $traceConfiguration `
            -StartTimeoutSeconds $ServiceStartTimeoutSeconds `
            -PollIntervalSeconds $ServicePollIntervalSeconds `
            -Outcome $keyOutcome
        if ($keyOutcome.Attempted[$startKey]) { $startOutcome.Attempted[$startKey] = $true }
        if ($keyOutcome.Started[$startKey]) { $startOutcome.Started[$startKey] = $true }
        if ($keyOutcome.RestartFailed) { $startOutcome.RestartFailed = $true }
    }
    $Outcome.CoveredCriticalTo = $script:CriticalErrorsList.Count

    # Крок 10: облік спроби (лише впалі служби, які справді запускали).
    $attemptedFailedKeys = @($plan.FailedKeys | Where-Object { $startOutcome.Attempted[$_] })
    $registrations = @{}
    if ($attemptedFailedKeys.Count -gt 0) {
        if ($null -ne $state) {
            foreach ($stabilityWarning in @(Update-BRAVOMaintenanceServiceRecoveryStability -ServiceSet $ServiceSet -Conditions $conditions -StatePath $StatePath -Now $now -ExcludeKeys $chainKeys)) {
                Write-Log -Message $stabilityWarning -Level "WARNING"
            }
        }
        $accounting = Invoke-BRAVOServiceRecoveryAttemptAccounting -ServiceNames @($attemptedFailedKeys | ForEach-Object { [string]$ServiceSet.$_.Name })
        foreach ($accountingWarning in @($accounting.Warnings)) {
            Write-Log -Message $accountingWarning -Level "WARNING"
        }
        foreach ($registration in @($accounting.Registrations)) { $registrations[[string]$registration.ServiceName] = $registration }
    }

    # Маркер знімається, коли кожну службу, яку профіль зупинив, знову
    # запущено: впалі до профілю служби профіль не зупиняв, їх наступну
    # спробу веде пауза FR-5 (маркер затулив би їх як OwnedByBravo).
    # Рев'ю PR #432 (Codex, P2): службу міг запустити хтось інший (оператор,
    # SCM) поки збирались журнали — тоді цикл її не запускав, але вона
    # працює. Фінальний стан перечитується: Running — не збій; нечитабельний
    # стан — як і раніше, «зупинено, але не запущено».
    $stoppedNotStarted = @()
    foreach ($stoppedKey in @($stopKeys | Where-Object { $stopCompleted[$_] -and $restartIntent[$_] -and -not $startOutcome.Started[$_] })) {
        $finalStatus = $null
        try { $finalStatus = [string](Get-Service -Name ([string]$ServiceSet.$stoppedKey.Name) -ErrorAction Stop).Status } catch { $finalStatus = $null }
        if ($finalStatus -eq 'Running') {
            Write-Log -Message "Служба $($ServiceSet.$stoppedKey.Name) вже працює (її запустили поза профілем після зупинки) — повторний запуск не потрібен" -Level "INFO"
            continue
        }
        $stoppedNotStarted += $stoppedKey
    }
    if ($stoppedNotStarted.Count -eq 0) {
        try {
            if (-not (Clear-BRAVOServiceQuiescenceState)) {
                Write-Log -Message "Ownership-маркер не прибрано: його перезаписав інший процес" -Level "WARNING"
            }
        } catch {
            Write-Log -Message "Ownership-маркер не прибрано: $($_.Exception.Message)" -Level "WARNING"
        }
    } else {
        Write-Log -Message "Ownership-маркер залишено: зупинені профілем служби не запущено ($(@($stoppedNotStarted | ForEach-Object { $ServiceSet.$_.Name }) -join ', ')) — Health-watchdog повторить спробу" -Level "WARNING"
    }

    # Крок 11: сповіщення FR-6.
    foreach ($failedKey in @($plan.FailedKeys)) {
        if (-not $startOutcome.Attempted[$failedKey]) { continue }
        $serviceName = [string]$ServiceSet.$failedKey.Name
        $registration = $registrations[$serviceName]
        $attemptNumber = 1
        if ($null -ne $registration) { $attemptNumber = [int]$registration.AttemptNumber }
        $lastEvent = @(@($scmEvents.Events) | Where-Object { @($serviceEventNames[$failedKey]) -contains [string]$_.ServiceName }) | Select-Object -Last 1
        $eventText = $null
        if ($null -ne $lastEvent) { $eventText = "подія $($lastEvent.Id) о $(([datetime]$lastEvent.TimeCreated).ToString('HH:mm'))" }
        if ($startOutcome.Started[$failedKey]) {
            $kind = 'Recovered'
            $reason = $null
        } else {
            $kind = 'Failed'
            $statusAfter = 'невідомо'
            try { $statusAfter = [string](Get-Service -Name $serviceName -ErrorAction Stop).Status } catch { $statusAfter = 'невідомо' }
            $reason = "служба не запустилась за $ServiceStartTimeoutSeconds с (стан: $statusAfter)"
        }
        Send-BRAVOMaintenanceServiceRecoveryNotification -Content (New-BRAVOServiceRecoveryNotificationContent -Kind $kind `
            -ServiceName $serviceName -ExitCode $conditions[$failedKey].ExitCode `
            -ServiceSpecificExitCode $conditions[$failedKey].ServiceSpecificExitCode -EventText $eventText `
            -AttemptNumber $attemptNumber -Reason $reason -LogPath $LOG_FILE)
        $Outcome.NotifiedKeys += $failedKey
        if ($kind -eq 'Failed') { $Outcome.FailedNotifications++ }
        if ($null -ne $registration -and $registration.CyclicCriticalDue) {
            $cyclicContent = New-BRAVOServiceRecoveryNotificationContent -Kind Cyclic `
                -ServiceName $serviceName -AttemptNumber $registration.AttemptNumber `
                -FirstAttemptAt $registration.FirstAttemptAt -LogPath $LOG_FILE
            Write-Log -Message "$(@($cyclicContent.Details)[0]) (#314)" -Level "WARNING"
            Send-BRAVOMaintenanceServiceRecoveryNotification -Content $cyclicContent
        }
    }
    foreach ($stoppedKey in $stoppedNotStarted) {
        Send-BRAVOMaintenanceServiceRecoveryNotification -Content (New-BRAVOServiceRecoveryNotificationContent -Kind Failed `
            -ServiceName ([string]$ServiceSet.$stoppedKey.Name) -ExitCode $null `
            -Reason "службу зупинено для перезапуску $($ServiceSet.Bravo.Name), але не запущено" -LogPath $LOG_FILE)
        $Outcome.FailedNotifications++
    }
}
