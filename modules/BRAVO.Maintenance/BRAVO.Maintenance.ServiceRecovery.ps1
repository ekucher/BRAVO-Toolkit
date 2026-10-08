# ============================================================
# Облік спроб відновлення впалих служб BRAVO і сповіщення про них
# (#314, хвиля 3: FR-5 паузи між спробами, FR-6 сповіщення).
#
# Файл НЕ є самостійним скриптом і не імпортується як модуль: його
# dot-source-ить Invoke-BRAVOMaintenance (BRAVO.Maintenance.Runtime.ps1),
# як і BRAVO.Maintenance.ServiceCycle.ps1. На відміну від циклу служб,
# функції тут НЕ читають змінних прогону: усе, що їм потрібно (шлях
# state-файлу, hostname, поточний час, режим і маршрути сповіщень),
# передається параметрами. Тому їх однаково викликають нічний Maintenance
# і профіль -RecoverServices (хвиля 4), а self-test перевіряє їх напряму.
#
# State-файл %ProgramData%\BRAVO\State\BRAVO_SERVICE_RECOVERY_STATE.json
# лежить поряд з ownership-маркером (той самий каталог машинного стану,
# захищений Protect-BRAVOMachineStateRoot). UTF-8 без BOM, читання з
# -Encoding UTF8, запис атомарний (Write-BRAVOStateFileAtomic: temp + move).
# Формат:
#   { "schemaVersion": 1, "hostname": "HOST-01",
#     "services": { "exchangAPI": { "attempts": ["2026-09-27T10:01:12.0000000+03:00"],
#                                   "lastCriticalAt": null, "stableSince": null } } }
# Облік ведеться на службу, яка впала (залежні, перезапущені разом з BRAVO,
# не рахуються). Пошкоджений або чужий (інший hostname) файл не блокує
# спробу запуску: він перейменовується в .corrupt-<ts>, облік починається
# заново, викликач отримує текст для WARNING.
# ============================================================

function Get-BRAVOServiceRecoveryPolicy {
    # Параметри відновлення служб (ТЗ #314 §8). До cutover Config V2 (#216) —
    # константи в коді, без ключів конфігурації.
    #   PauseMinutes           - мінімальна пауза перед 1/2/3-ю спробою за
    #                            вікно; далі (4-та й наступні) — останнє
    #                            значення, без обмеження кількості спроб;
    #   WindowHours            - ковзне вікно обліку спроб;
    #   CyclicAttemptThreshold - спроба з цим номером у вікні дає CRITICAL
    #                            «циклічно падає»;
    #   CyclicReminderHours    - CRITICAL «циклічно падає» не частіше;
    #   StableMinutes          - стільки служба має працювати після останньої
    #                            спроби, щоб облік обнулився;
    #   BootGraceMinutes       - перші хвилини після старту ОС профіль служб
    #                            не змінює: ними розпоряджається boot-тригер
    #                            (-RunMissedRestoreOnly, HoldServices); менше
    #                            за затримку Boot-тригера задачі (10 хв).
    return [pscustomobject]@{
        PauseMinutes = @(0, 5, 15, 60)
        WindowHours = 24
        CyclicAttemptThreshold = 3
        CyclicReminderHours = 24
        StableMinutes = 30
        BootGraceMinutes = 9
    }
}

function Get-BRAVOServiceRecoveryStatePath {
    # Поряд з ownership-маркером (BRAVO.System): той самий каталог машинного стану.
    return Join-Path (Split-Path -Path (Get-BRAVOServiceQuiescenceStatePath) -Parent) 'BRAVO_SERVICE_RECOVERY_STATE.json'
}

function New-BRAVOServiceRecoveryState {
    param([Parameter(Mandatory = $true)][string]$HostName)
    return @{ schemaVersion = 1; hostname = $HostName; services = @{} }
}

function ConvertTo-BRAVOServiceRecoveryInstant {
    # Мітка часу state-файлу -> [DateTimeOffset]. Рядок ISO 8601 з
    # часовим поясом (так пише Write-BRAVOServiceRecoveryState); [datetime]
    # теж приймається — ConvertFrom-Json у PowerShell 7 сам перетворює такі
    # рядки на дати. Нерозпізнане значення — виняток (файл пошкоджений).
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [datetime]) { return (New-Object DateTimeOffset($Value)) }
    if ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)) {
        return [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    throw "нерозпізнана мітка часу: '$Value'"
}

function Read-BRAVOServiceRecoveryState {
    # Читає state-файл. Повертає { State; Warning; CorruptPath }: State —
    # hashtable { schemaVersion; hostname; services = @{ <служба> = @{
    # attempts = [DateTimeOffset[]]; lastCriticalAt; stableSince } } }.
    # Відсутній файл — порожній облік без попередження. Пошкоджений або
    # записаний іншим хостом файл перейменовується в <файл>.corrupt-<ts>,
    # облік починається заново, а Warning містить текст для WARNING.
    # -ReadOnly (профіль -RecoverServices до взяття lock-а): файл не
    # перейменовується — лише порожній облік і Warning.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Now,
        [switch]$ReadOnly
    )

    $result = [pscustomobject]@{ State = (New-BRAVOServiceRecoveryState -HostName $HostName); Warning = $null; CorruptPath = $null }
    if (-not [IO.File]::Exists($Path)) { return $result }

    $problem = $null
    try {
        $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$text)) { throw 'файл порожній' }
        $parsed = ConvertFrom-Json -InputObject ([string]$text) -ErrorAction Stop
        if ($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['schemaVersion'] -or ($parsed.schemaVersion -as [int]) -ne 1) {
            throw 'невідома schemaVersion'
        }
        $hostProperty = $parsed.PSObject.Properties['hostname']
        if ($null -eq $hostProperty -or [string]::IsNullOrWhiteSpace([string]$hostProperty.Value)) { throw 'немає hostname' }
        if ([string]$hostProperty.Value -ine $HostName) {
            $problem = "файл записано на іншому хості ($([string]$hostProperty.Value))"
        } else {
            $servicesProperty = $parsed.PSObject.Properties['services']
            if ($null -eq $servicesProperty -or $null -eq $servicesProperty.Value) { throw 'немає services' }
            $services = @{}
            foreach ($serviceProperty in @($servicesProperty.Value.PSObject.Properties)) {
                $entryValue = $serviceProperty.Value
                if ($null -eq $entryValue -or $null -eq $entryValue.PSObject.Properties['attempts']) {
                    throw "запис служби $($serviceProperty.Name) без attempts"
                }
                $attempts = @()
                foreach ($attemptValue in @($entryValue.attempts)) {
                    $attempts += ConvertTo-BRAVOServiceRecoveryInstant -Value $attemptValue
                }
                $lastCriticalAt = $null
                if ($null -ne $entryValue.PSObject.Properties['lastCriticalAt']) {
                    $lastCriticalAt = ConvertTo-BRAVOServiceRecoveryInstant -Value $entryValue.lastCriticalAt
                }
                $stableSince = $null
                if ($null -ne $entryValue.PSObject.Properties['stableSince']) {
                    $stableSince = ConvertTo-BRAVOServiceRecoveryInstant -Value $entryValue.stableSince
                }
                $services[[string]$serviceProperty.Name] = @{ attempts = @($attempts); lastCriticalAt = $lastCriticalAt; stableSince = $stableSince }
            }
            $result.State.services = $services
            return $result
        }
    } catch {
        $problem = "файл пошкоджений: $($_.Exception.Message)"
    }
    if ($ReadOnly) {
        $result.Warning = "State-файл відновлення служб $Path не прочитано ($problem)"
        return $result
    }

    $corruptPath = '{0}.corrupt-{1}' -f $Path, $Now.ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture)
    if ([IO.File]::Exists($corruptPath)) {
        $corruptPath = '{0}-{1}' -f $corruptPath, [guid]::NewGuid().ToString('N').Substring(0, 8)
    }
    $renameText = ''
    try {
        [IO.File]::Move($Path, $corruptPath)
        $result.CorruptPath = $corruptPath
        $renameText = "збережено як $corruptPath"
    } catch {
        $renameText = "перейменувати не вдалося: $($_.Exception.Message)"
    }
    $result.Warning = "Облік спроб відновлення служб ($Path) не прочитано — $problem; $renameText. Облік починається заново, запуск служб не блокується (#314)"
    return $result
}

function Get-BRAVOServiceRecoveryWindowAttempts {
    # Спроби служби в ковзному вікні обліку, від найстаршої. Стан не змінює.
    param(
        [AllowNull()][hashtable]$Entry,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Now
    )
    if ($null -eq $Entry) { return @() }
    $windowStart = $Now.AddHours(-1 * (Get-BRAVOServiceRecoveryPolicy).WindowHours)
    return @(@($Entry.attempts) | Where-Object { $null -ne $_ -and $_ -gt $windowStart } | Sort-Object)
}

function Write-BRAVOServiceRecoveryState {
    # Атомарний запис state-файлу (UTF-8 без BOM, temp + move). Перед
    # записом прибирає мітки спроб, старші за вікно обліку, і записи служб,
    # у яких не лишилось нічого чинного.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Now
    )

    $policy = Get-BRAVOServiceRecoveryPolicy
    $reminderStart = $Now.AddHours(-1 * $policy.CyclicReminderHours)
    $servicesOut = [ordered]@{}
    foreach ($serviceName in @($State.services.Keys | Sort-Object)) {
        $entry = $State.services[$serviceName]
        $attempts = @(Get-BRAVOServiceRecoveryWindowAttempts -Entry $entry -Now $Now)
        $criticalRecent = $null -ne $entry.lastCriticalAt -and $entry.lastCriticalAt -gt $reminderStart
        if ($attempts.Count -eq 0 -and $null -eq $entry.stableSince -and -not $criticalRecent) { continue }
        $servicesOut[[string]$serviceName] = [ordered]@{
            attempts = @($attempts | ForEach-Object { $_.ToString('o', [Globalization.CultureInfo]::InvariantCulture) })
            lastCriticalAt = $(if ($null -ne $entry.lastCriticalAt) { $entry.lastCriticalAt.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } else { $null })
            stableSince = $(if ($null -ne $entry.stableSince) { $entry.stableSince.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } else { $null })
        }
    }
    $document = [ordered]@{
        schemaVersion = 1
        hostname = [string]$State.hostname
        services = $servicesOut
    }
    Write-BRAVOStateFileAtomic -Path $Path -Text ($document | ConvertTo-Json -Depth 6)
}

function Test-BRAVOServiceRecoveryPauseElapsed {
    # FR-5: чи минула мінімальна пауза від попередньої спроби запуску служби
    # (0 / 5 / 15 хв перед 1/2/3-ю спробою за вікно, далі 60 хв). Лише
    # читає стан. Нічний Maintenance паузу не перевіряє (завжди робить
    # спробу); перевіряє профіль -RecoverServices (хвиля 4).
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Now
    )

    $policy = Get-BRAVOServiceRecoveryPolicy
    $entry = $null
    if ($State.services.ContainsKey($ServiceName)) { $entry = $State.services[$ServiceName] }
    $attempts = @(Get-BRAVOServiceRecoveryWindowAttempts -Entry $entry -Now $Now)
    $pauseIndex = [Math]::Min($attempts.Count, $policy.PauseMinutes.Count - 1)
    $pauseMinutes = [int]$policy.PauseMinutes[$pauseIndex]
    $lastAttemptAt = $null
    $nextAttemptAt = $Now
    if ($attempts.Count -gt 0) {
        $lastAttemptAt = $attempts[$attempts.Count - 1]
        $nextAttemptAt = $lastAttemptAt.AddMinutes($pauseMinutes)
    }
    return [pscustomobject]@{
        ServiceName = $ServiceName
        Elapsed = ($Now -ge $nextAttemptAt)
        AttemptsInWindow = $attempts.Count
        PauseMinutes = $pauseMinutes
        LastAttemptAt = $lastAttemptAt
        NextAttemptAt = $nextAttemptAt
    }
}

function Add-BRAVOServiceRecoveryAttempt {
    # FR-5: реєструє спробу запуску впалої служби (незалежно від її
    # результату): прибирає мітки поза вікном, додає поточну, скидає
    # stableSince. FR-6: спроба з номером CyclicAttemptThreshold і далі
    # дає CyclicCriticalDue — не частіше ніж раз на CyclicReminderHours
    # (lastCriticalAt оновлюється тут же, щоб збій доставки не спричинив
    # повтору на кожній наступній спробі).
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Now
    )

    $policy = Get-BRAVOServiceRecoveryPolicy
    if (-not $State.services.ContainsKey($ServiceName)) {
        $State.services[$ServiceName] = @{ attempts = @(); lastCriticalAt = $null; stableSince = $null }
    }
    $entry = $State.services[$ServiceName]
    $attempts = @(@(Get-BRAVOServiceRecoveryWindowAttempts -Entry $entry -Now $Now) + @($Now))
    $entry.attempts = $attempts
    $entry.stableSince = $null
    $cyclicDue = $attempts.Count -ge $policy.CyclicAttemptThreshold -and
        ($null -eq $entry.lastCriticalAt -or ($Now - $entry.lastCriticalAt).TotalHours -ge $policy.CyclicReminderHours)
    if ($cyclicDue) { $entry.lastCriticalAt = $Now }
    return [pscustomobject]@{
        ServiceName = $ServiceName
        AttemptNumber = $attempts.Count
        FirstAttemptAt = $attempts[0]
        CyclicCriticalDue = [bool]$cyclicDue
    }
}

function Update-BRAVOServiceRecoveryStability {
    # FR-5: обнулення обліку служби, яка після останньої спроби стабільно
    # працює. Перше спостереження Running після спроби фіксує stableSince;
    # якщо служба й через StableMinutes від нього Running — запис служби
    # (спроби, lastCriticalAt) видаляється. Не Running — stableSince
    # скидається. Викликають профіль -RecoverServices і Health (хвилі 4–5).
    # Повертає { Changed; Reset }.
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][bool]$IsRunning,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Now
    )

    $result = [pscustomobject]@{ Changed = $false; Reset = $false }
    if (-not $State.services.ContainsKey($ServiceName)) { return $result }
    $entry = $State.services[$ServiceName]
    if (-not $IsRunning) {
        if ($null -ne $entry.stableSince) { $entry.stableSince = $null; $result.Changed = $true }
        return $result
    }
    $attempts = @(@($entry.attempts) | Where-Object { $null -ne $_ } | Sort-Object)
    $lastAttemptAt = $null
    if ($attempts.Count -gt 0) { $lastAttemptAt = $attempts[$attempts.Count - 1] }
    if ($null -eq $entry.stableSince -or ($null -ne $lastAttemptAt -and $entry.stableSince -lt $lastAttemptAt)) {
        $entry.stableSince = $Now
        $result.Changed = $true
    } elseif (($Now - $entry.stableSince).TotalMinutes -ge (Get-BRAVOServiceRecoveryPolicy).StableMinutes) {
        [void]$State.services.Remove($ServiceName)
        $result.Changed = $true
        $result.Reset = $true
    }
    return $result
}

function Invoke-BRAVOServiceRecoveryAttemptAccounting {
    # Облік спроб запуску впалих служб у state-файлі: прочитати (пошкоджений
    # чи чужий файл -> .corrupt-<ts> і облік заново), зареєструвати по
    # спробі на кожну службу, атомарно записати. Паузу НЕ перевіряє: нічний
    # Maintenance її ігнорує, а -RecoverServices перевіряє до запуску
    # (Test-BRAVOServiceRecoveryPauseElapsed). Жоден збій обліку не
    # блокує відновлення служб: він повертається текстом у Warnings.
    # Без -Path — шлях за замовчуванням і захист каталогу машинного стану
    # (Protect-BRAVOMachineStateRoot). Повертає { Path; Registrations; Warnings }.
    param(
        [Parameter(Mandatory = $true)][string[]]$ServiceNames,
        [string]$Path,
        [string]$HostName = [Environment]::MachineName,
        [AllowNull()][object]$Now
    )

    $instant = if ($null -ne $Now) { ConvertTo-BRAVOServiceRecoveryInstant -Value $Now } else { [DateTimeOffset]::Now }
    $result = [pscustomobject]@{ Path = $Path; Registrations = @(); Warnings = @() }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        try {
            $Path = Get-BRAVOServiceRecoveryStatePath
            $result.Path = $Path
        } catch {
            $result.Warnings += "Облік спроб відновлення служб недоступний: $($_.Exception.Message) (#314)"
            return $result
        }
        try {
            $protection = Protect-BRAVOMachineStateRoot -Path (Split-Path -Path $Path -Parent)
            if (-not $protection.Compliant -and -not $protection.Applied) {
                $result.Warnings += "Каталог машинного стану не захищено: $(@($protection.Issues) -join '; ') (#314)"
            }
        } catch {
            $result.Warnings += "Каталог машинного стану не захищено: $($_.Exception.Message) (#314)"
        }
    }

    $read = Read-BRAVOServiceRecoveryState -Path $Path -HostName $HostName -Now $instant
    if (-not [string]::IsNullOrWhiteSpace([string]$read.Warning)) { $result.Warnings += [string]$read.Warning }
    $registrations = @()
    foreach ($serviceName in @($ServiceNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        $registrations += Add-BRAVOServiceRecoveryAttempt -State $read.State -ServiceName ([string]$serviceName) -Now $instant
    }
    $result.Registrations = @($registrations)
    try {
        Write-BRAVOServiceRecoveryState -Path $Path -State $read.State -Now $instant
    } catch {
        $result.Warnings += "Облік спроб відновлення служб не записано ($Path): $($_.Exception.Message) (#314)"
    }
    return $result
}

function New-BRAVOServiceRecoveryNotificationContent {
    # FR-6: зміст сповіщення про відновлення служби (без доставки).
    #   Recovered -> WARNING: служба впала, журнали збережено, запущена;
    #   Failed    -> CRITICAL: службу не вдалося підняти, причина;
    #   Cyclic    -> CRITICAL: служба циклічно падає, потрібне втручання.
    # Повертає { Severity; Title; TitleEmoji; Details }.
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Recovered', 'Failed', 'Cyclic')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [AllowNull()][object]$ExitCode,
        [AllowNull()][object]$ServiceSpecificExitCode,
        [string]$EventText,
        [int]$AttemptNumber = 1,
        [AllowNull()][object]$FirstAttemptAt,
        [string]$Reason,
        [string]$LogPath
    )

    $exitText = Format-BRAVOServiceRecoveryExitCode -ExitCode $ExitCode -ServiceSpecificExitCode $ServiceSpecificExitCode
    $causeText = if ([string]::IsNullOrWhiteSpace($EventText)) { $exitText } else { "$exitText, $EventText" }
    $logText = if ([string]::IsNullOrWhiteSpace($LogPath)) { 'Журнал: не створено' } else { "Журнал: $LogPath" }
    switch ($Kind) {
        'Recovered' {
            return [pscustomobject]@{
                Severity = 'WARNING'
                Title = 'СЛУЖБУ BRAVO ВІДНОВЛЕНО'
                TitleEmoji = ':warning:'
                Details = @("Служба $ServiceName впала ($causeText), журнали збережено, запущена.", "Спроба $AttemptNumber за добу.", $logText)
            }
        }
        'Failed' {
            $reasonText = if ([string]::IsNullOrWhiteSpace($Reason)) { 'причина невідома' } else { $Reason }
            return [pscustomobject]@{
                Severity = 'CRITICAL'
                Title = 'СЛУЖБУ BRAVO НЕ ВДАЛОСЯ ПІДНЯТИ'
                TitleEmoji = ':rotating_light:'
                Details = @("Службу $ServiceName не вдалося запустити ($causeText): $reasonText.", "Спроба $AttemptNumber за добу.", $logText)
            }
        }
        default {
            $sinceText = ''
            if ($null -ne $FirstAttemptAt) {
                $sinceText = ' з ' + (ConvertTo-BRAVOServiceRecoveryInstant -Value $FirstAttemptAt).ToLocalTime().ToString('dd.MM HH:mm', [Globalization.CultureInfo]::InvariantCulture)
            }
            return [pscustomobject]@{
                Severity = 'CRITICAL'
                Title = 'СЛУЖБА BRAVO ЦИКЛІЧНО ПАДАЄ'
                TitleEmoji = ':rotating_light:'
                Details = @("Служба $ServiceName циклічно падає: $AttemptNumber падінь$sinceText, потрібне втручання.", $logText)
            }
        }
    }
}

function New-BRAVOServiceRecoveryRunAlertContent {
    # FR-6 (рев'ю PR #432, B-P2-1): зміст сповіщення про помилки прогону
    # відновлення, які не покриває сповіщення про конкретну службу (збій
    # зупинки залежної служби, ротації журналів, непередбачений виняток).
    # -CriticalMessages — записи CriticalErrorsList, -QueuedAlerts — записи
    # NotificationAlertQueue ({ Severity; Message }), -CriticalWithoutDetails —
    # критичний збій, про який прогін не лишив тексту. Повертає
    # { Severity; Title; TitleEmoji; Details }.
    param(
        [AllowEmptyCollection()][string[]]$CriticalMessages = @(),
        [AllowEmptyCollection()][object[]]$QueuedAlerts = @(),
        [switch]$CriticalWithoutDetails,
        [string]$LogPath
    )

    $queuedSeverities = @(@($QueuedAlerts) | ForEach-Object { [string]$_.Severity })
    $severity = 'WARNING'
    if (@($CriticalMessages).Count -gt 0 -or $CriticalWithoutDetails -or $queuedSeverities -contains 'CRITICAL') {
        $severity = 'CRITICAL'
    } elseif ($queuedSeverities -contains 'ERROR') {
        $severity = 'ERROR'
    }
    $details = @(@($CriticalMessages) | ForEach-Object { [string]$_ }) + @(@($QueuedAlerts) | ForEach-Object { [string]$_.Message })
    if ($CriticalWithoutDetails -and @($CriticalMessages).Count -eq 0) {
        $details += 'Прогін відновлення служб завершився з критичною помилкою — подробиці в журналі.'
    }
    $details += $(if ([string]::IsNullOrWhiteSpace($LogPath)) { 'Журнал: не створено' } else { "Журнал: $LogPath" })
    $title = 'ВІДНОВЛЕННЯ СЛУЖБ BRAVO: ПОПЕРЕДЖЕННЯ'
    $titleEmoji = ':warning:'
    if ($severity -eq 'CRITICAL') {
        $title = 'ВІДНОВЛЕННЯ СЛУЖБ BRAVO: КРИТИЧНІ ПОМИЛКИ'
        $titleEmoji = ':rotating_light:'
    } elseif ($severity -eq 'ERROR') {
        $title = 'ВІДНОВЛЕННЯ СЛУЖБ BRAVO: ПОМИЛКИ'
        $titleEmoji = ':x:'
    }
    return [pscustomobject]@{ Severity = $severity; Title = $title; TitleEmoji = $titleEmoji; Details = @($details) }
}

function Format-BRAVOServiceRecoveryExitCode {
    # «ExitCode N» (+ ServiceSpecificExitCode, коли служба повідомила власний код).
    param([AllowNull()][object]$ExitCode, [AllowNull()][object]$ServiceSpecificExitCode)
    if ($null -eq $ExitCode) { return 'ExitCode невідомий' }
    $text = "ExitCode $ExitCode"
    if ($null -ne $ServiceSpecificExitCode -and [long]$ServiceSpecificExitCode -ne 0) {
        $text += ", ServiceSpecificExitCode $ServiceSpecificExitCode"
    }
    return $text
}

function Send-BRAVOServiceRecoveryNotification {
    # FR-6: доставка змісту (New-BRAVOServiceRecoveryNotificationContent)
    # наявним маршрутом сповіщень: Resolve-BRAVONotificationRoute поважає
    # режими none / errors_only / all, New-MaintenanceNotificationMessage
    # формує повідомлення, Invoke-NotificationWebhook доставляє. Збій
    # доставки не кидає винятку — повертається в Error. Прапорців прогону
    # (criticalErrorOccurred, лічильник WARNING) функція не ставить: це
    # рішення викликача. Повертає { Route; Sent; Error }.
    param(
        [Parameter(Mandatory = $true)][object]$Content,
        [string]$NotificationMode = 'none',
        [hashtable]$RoutingTable,
        [AllowNull()][object]$WebhookUrls,
        [string]$LogPath,
        [timespan]$Duration = [timespan]::Zero
    )

    $result = [pscustomobject]@{ Route = 'none'; Sent = $false; Error = $null }
    try {
        $result.Route = [string](Resolve-BRAVONotificationRoute -Severity ([string]$Content.Severity) -NotificationMode $NotificationMode -RoutingTable $RoutingTable)
        if ($result.Route -eq 'none') { return $result }
        $message = New-MaintenanceNotificationMessage `
            -Title ([string]$Content.Title) `
            -TitleEmoji ([string]$Content.TitleEmoji) `
            -Severity ([string]$Content.Severity) `
            -Duration $Duration `
            -Details @($Content.Details) `
            -LogPath $LogPath
        $webhookUrl = $null
        if ($null -ne $WebhookUrls) { $webhookUrl = $WebhookUrls[$result.Route] }
        if ([string]::IsNullOrWhiteSpace([string]$webhookUrl)) { throw "немає адреси для маршруту $($result.Route)" }
        Invoke-NotificationWebhook -Message $message -WebhookUrl ([string]$webhookUrl)
        $result.Sent = $true
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}
