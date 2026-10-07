# ============================================================
# BRAVO.ServiceRecovery — облік відновлення впалих служб (#314, хвилі 3–5).
#
# Чиста логіка без звернень до SCM/WMI: політика пауз, state-файл спроб
# (FR-5), рішення «чи можна запускати зараз», облік CRITICAL «циклічно
# падає», тексти сповіщень (FR-6) і план ланцюжка профілю -RecoverServices
# (FR-3, Get-BRAVOServiceRecoveryChainPlan). Лише ЧИТАЮТЬ стан системи дві
# функції профілю: класифікація керованих служб
# (Get-BRAVOServiceRecoveryConditions) і події SCM із журналу System
# (Get-BRAVOServiceRecoveryScmEvents). Запускає служби лише Maintenance —
# цей модуль нічого не запускає і нічого не надсилає. Хвиля 5: тригери
# задачі BRAVO_SERVICE_RECOVERY (Add-BRAVOServiceRecoveryTaskTriggers,
# BRAVO_TASKS_INSTALL) і чиста перевірка її визначення
# (Test-BRAVOServiceRecoveryTaskDefinition, BRAVO_TASKS_DIAGNOSE).
#
# State: %ProgramData%\BRAVO\State\BRAVO_SERVICE_RECOVERY_STATE.json
# (поряд із BRAVO_SERVICE_QUIESCENCE.json), UTF-8 без BOM, атомарний запис
# через Write-BRAVOStateFileAtomic (BRAVO.System). Схема v1:
#   { "schemaVersion": 1, "hostname": "HOST-01", "updatedAt": "<o>",
#     "services": { "<Name>": { "attempts": ["<o>", ...],
#                               "lastCriticalAt": "<o>"|null,
#                               "stableSince": "<o>"|null } } }
# Дати — ToString('o') локального часу з offset.
#
# Стан передається явно (-State) і повертається НОВИМ об'єктом: функції
# не змінюють вхідний об'єкт і не тримають $global:/$script:-стану, тож
# детерміновано тестуються з -Now на будь-якій ОС.
#
# Пошкоджений або чужий state-файл НІКОЛИ не блокує спробу запуску:
# Read-BRAVOServiceRecoveryState переносить його в карантин
# (.corrupt-<yyyyMMdd_HHmmss>) і повертає порожній стан із Warning.
#
# Сумісність: PowerShell 3.0+ (Windows PowerShell 5.1), Set-StrictMode 2.0.
# ============================================================

$script:BRAVOServiceRecoverySystemManifest = Join-Path `
    -Path (Split-Path -Path $PSScriptRoot -Parent) `
    -ChildPath 'BRAVO.System\BRAVO.System.psd1'
Import-Module -Name $script:BRAVOServiceRecoverySystemManifest -ErrorAction Stop

function Get-BRAVOServiceRecoveryPolicy {
    # Єдине джерело констант відновлення служб (до cutover #216 — без
    # ключів конфігурації; після нього значення переїдуть у
    # Services.Recovery окремою задачею).
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        PauseMinutesByAttempt  = @(0, 5, 15)
        PauseMinutesCeiling    = 60
        WindowHours            = 24
        CyclicThreshold        = 3
        StableResetMinutes     = 30
        EventTriggerDelay      = 'PT1M'
        BootTriggerDelay       = 'PT10M'
        RepeatInterval         = 'PT15M'
        TaskExecutionTimeLimit = 'PT1H'
        TaskName               = 'BRAVO_SERVICE_RECOVERY'
        MarkerOwner            = 'BRAVO_MAINTENANCE_RECOVER'
        ScmEventIds            = @(7000, 7009, 7011, 7022, 7023, 7024, 7031, 7034)
        MaxScmEvents           = 50
    }
}

function Test-BRAVOServiceRecoveryFailed {
    # «Впала служба» для Maintenance і профілю відновлення (#314, план §0.3):
    # класифікатор Get-BRAVOManagedServiceCondition дає Failed і для Paused,
    # але призупинену службу BRAVO не зупиняє і не запускає (#360). Тому
    # «впала» = Condition 'Failed' І Status 'Stopped'.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Condition
    )

    if ($null -eq $Condition) { return $false }
    $conditionProperty = $Condition.PSObject.Properties['Condition']
    $statusProperty = $Condition.PSObject.Properties['Status']
    if ($null -eq $conditionProperty -or $null -eq $statusProperty) { return $false }
    return ([string]$conditionProperty.Value -eq 'Failed' -and [string]$statusProperty.Value -eq 'Stopped')
}

function Get-BRAVOServiceRecoveryStatePath {
    # Тестовий шов: self-test затінює цю функцію шляхом у TEMP, щоб ніколи
    # не торкатися справжнього %ProgramData%\BRAVO\State.
    [CmdletBinding()]
    param()

    $programDataRoot = [Environment]::GetFolderPath('CommonApplicationData')
    if ([string]::IsNullOrWhiteSpace($programDataRoot)) {
        throw 'CommonApplicationData недоступний для service-recovery state'
    }
    return Join-Path $programDataRoot 'BRAVO\State\BRAVO_SERVICE_RECOVERY_STATE.json'
}

function ConvertTo-BRAVOServiceRecoveryDateTime {
    # Приватний: рядок ToString('o') або [datetime] -> [datetime]; $null
    # для порожнього значення. PowerShell 7 ConvertFrom-Json сам перетворює
    # ISO-рядки на [datetime], Windows PowerShell 5.1 — ні; приймаються обидва.
    # Нерозбірне значення -> виняток (читач трактує файл як пошкоджений).
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return [datetime]$Value }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).LocalDateTime }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return [datetime]::Parse(
        $text,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
}

function ConvertTo-BRAVOServiceRecoveryDateText {
    # Приватний: [datetime] -> рядок ToString('o') локального часу з offset.
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $dateTime = ConvertTo-BRAVOServiceRecoveryDateTime -Value $Value
    if ($null -eq $dateTime) { return $null }
    if ($dateTime.Kind -eq [DateTimeKind]::Utc) { $dateTime = $dateTime.ToLocalTime() }
    if ($dateTime.Kind -eq [DateTimeKind]::Unspecified) {
        $dateTime = [datetime]::SpecifyKind($dateTime, [DateTimeKind]::Local)
    }
    return $dateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-BRAVOServiceRecoveryElapsedMinutes {
    # Приватний: хвилини від From до To (порівняння в UTC — однаково для
    # дат із різним Kind).
    param(
        [Parameter(Mandatory = $true)][datetime]$From,
        [Parameter(Mandatory = $true)][datetime]$To
    )

    return ($To.ToUniversalTime() - $From.ToUniversalTime()).TotalMinutes
}

function New-BRAVOServiceRecoveryServiceEntry {
    # Приватний: запис однієї служби в канонічній формі.
    param(
        [string[]]$Attempts = @(),
        [AllowNull()][string]$LastCriticalAt,
        [AllowNull()][string]$StableSince
    )

    # Параметри типізовані [string]: присвоєння їм $null дає '' (змінна з
    # обмеженням типу), тому порожнє значення -> $null через окремі
    # нетипізовані змінні. Інакше '' потрапляв у стан як «дата» і ламав
    # обчислення вікна/пауз.
    $lastCriticalValue = $null
    if (-not [string]::IsNullOrWhiteSpace($LastCriticalAt)) { $lastCriticalValue = $LastCriticalAt }
    $stableSinceValue = $null
    if (-not [string]::IsNullOrWhiteSpace($StableSince)) { $stableSinceValue = $StableSince }
    return [pscustomobject]@{
        attempts       = [object[]]@($Attempts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        lastCriticalAt = $lastCriticalValue
        stableSince    = $stableSinceValue
    }
}

function New-BRAVOServiceRecoveryEmptyState {
    # Приватний: порожній стан цього хоста.
    param()

    return [pscustomobject]@{
        schemaVersion = 1
        hostname      = [Environment]::MachineName
        updatedAt     = $null
        services      = @{}
    }
}

function ConvertTo-BRAVOServiceRecoveryState {
    # Приватний: будь-яке представлення стану (результат ConvertFrom-Json або
    # об'єкт цього модуля) -> НОВИЙ канонічний об'єкт; services — hashtable
    # (ім'я служби без урахування регістру) записів у канонічній формі.
    # Вхідний об'єкт не змінюється. Некоректні дати -> виняток.
    param([AllowNull()][object]$State)

    $normalized = New-BRAVOServiceRecoveryEmptyState
    if ($null -eq $State) { return $normalized }

    $hostnameProperty = $State.PSObject.Properties['hostname']
    if ($null -ne $hostnameProperty -and -not [string]::IsNullOrWhiteSpace([string]$hostnameProperty.Value)) {
        $normalized.hostname = [string]$hostnameProperty.Value
    }
    $updatedAtProperty = $State.PSObject.Properties['updatedAt']
    if ($null -ne $updatedAtProperty) {
        $normalized.updatedAt = ConvertTo-BRAVOServiceRecoveryDateText -Value $updatedAtProperty.Value
    }

    $servicesProperty = $State.PSObject.Properties['services']
    if ($null -eq $servicesProperty -or $null -eq $servicesProperty.Value) { return $normalized }
    $sourceServices = $servicesProperty.Value
    $sourcePairs = @()
    if ($sourceServices -is [Collections.IDictionary]) {
        foreach ($serviceKey in @($sourceServices.Keys)) {
            $sourcePairs += , @([string]$serviceKey, $sourceServices[$serviceKey])
        }
    } else {
        foreach ($serviceProperty in @($sourceServices.PSObject.Properties)) {
            $sourcePairs += , @([string]$serviceProperty.Name, $serviceProperty.Value)
        }
    }

    foreach ($sourcePair in $sourcePairs) {
        $serviceName = [string]$sourcePair[0]
        $sourceEntry = $sourcePair[1]
        if ([string]::IsNullOrWhiteSpace($serviceName) -or $null -eq $sourceEntry) { continue }
        $attemptTexts = @()
        $lastCriticalText = $null
        $stableSinceText = $null
        $attemptsProperty = $sourceEntry.PSObject.Properties['attempts']
        if ($null -ne $attemptsProperty -and $null -ne $attemptsProperty.Value) {
            foreach ($attemptValue in @($attemptsProperty.Value)) {
                $attemptText = ConvertTo-BRAVOServiceRecoveryDateText -Value $attemptValue
                if ($null -ne $attemptText) { $attemptTexts += $attemptText }
            }
        }
        $lastCriticalProperty = $sourceEntry.PSObject.Properties['lastCriticalAt']
        if ($null -ne $lastCriticalProperty) {
            $lastCriticalText = ConvertTo-BRAVOServiceRecoveryDateText -Value $lastCriticalProperty.Value
        }
        $stableSinceProperty = $sourceEntry.PSObject.Properties['stableSince']
        if ($null -ne $stableSinceProperty) {
            $stableSinceText = ConvertTo-BRAVOServiceRecoveryDateText -Value $stableSinceProperty.Value
        }
        $normalized.services[$serviceName] = New-BRAVOServiceRecoveryServiceEntry `
            -Attempts $attemptTexts -LastCriticalAt $lastCriticalText -StableSince $stableSinceText
    }
    return $normalized
}

function Get-BRAVOServiceRecoveryWindowAttempt {
    # Приватний: мітки спроб служби, молодші за вікно (WindowHours),
    # відсортовані за часом ([datetime] у конвеєр; викликач обгортає @()).
    param(
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][datetime]$Now
    )

    $windowMinutes = [double]((Get-BRAVOServiceRecoveryPolicy).WindowHours * 60)
    $recent = @()
    foreach ($attemptText in @($Entry.attempts)) {
        $attemptTime = ConvertTo-BRAVOServiceRecoveryDateTime -Value $attemptText
        if ($null -eq $attemptTime) { continue }
        if ((Get-BRAVOServiceRecoveryElapsedMinutes -From $attemptTime -To $Now) -lt $windowMinutes) {
            $recent += $attemptTime
        }
    }
    return @($recent | Sort-Object -Property { $_.ToUniversalTime() })
}

function Get-BRAVOServiceRecoveryEntry {
    # Приватний: запис служби з канонічного стану або порожній запис.
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$ServiceName
    )

    if ($State.services.ContainsKey($ServiceName)) { return $State.services[$ServiceName] }
    return New-BRAVOServiceRecoveryServiceEntry
}

function Remove-BRAVOServiceRecoveryExpiredAttempts {
    # Прибирає мітки спроб, старші за вікно (24 год), і lastCriticalAt,
    # старший за вікно. Служба без жодних даних зникає зі стану.
    # Повертає НОВИЙ стан.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$State,
        [Parameter(Mandatory = $true)][datetime]$Now
    )

    $normalized = ConvertTo-BRAVOServiceRecoveryState -State $State
    $windowMinutes = [double]((Get-BRAVOServiceRecoveryPolicy).WindowHours * 60)
    foreach ($serviceName in @($normalized.services.Keys)) {
        $entry = $normalized.services[$serviceName]
        $recentTexts = @(@(Get-BRAVOServiceRecoveryWindowAttempt -Entry $entry -Now $Now) |
                ForEach-Object { ConvertTo-BRAVOServiceRecoveryDateText -Value $_ })
        $lastCriticalText = $entry.lastCriticalAt
        if ($null -ne $lastCriticalText) {
            $lastCriticalTime = ConvertTo-BRAVOServiceRecoveryDateTime -Value $lastCriticalText
            if ((Get-BRAVOServiceRecoveryElapsedMinutes -From $lastCriticalTime -To $Now) -ge $windowMinutes) {
                $lastCriticalText = $null
            }
        }
        $stableSinceText = $entry.stableSince
        if ($recentTexts.Count -eq 0) { $stableSinceText = $null }
        if ($recentTexts.Count -eq 0 -and $null -eq $lastCriticalText) {
            $normalized.services.Remove($serviceName)
            continue
        }
        $normalized.services[$serviceName] = New-BRAVOServiceRecoveryServiceEntry `
            -Attempts $recentTexts -LastCriticalAt $lastCriticalText -StableSince $stableSinceText
    }
    return $normalized
}

function Read-BRAVOServiceRecoveryState {
    # Читає state-файл. Результат:
    #   State           - канонічний стан (порожній, якщо файлу немає чи він
    #                     непридатний);
    #   Status          - 'Missing' | 'Ok' | 'Corrupt' | 'ForeignHost';
    #   Warning         - текст для WARNING-рядка викликача або $null;
    #   QuarantinedPath - куди перенесено непридатний файл або $null.
    # Непридатний файл (нерозбірний JSON, schemaVersion <> 1, немає services,
    # некоректні дати, чужий hostname) переноситься в
    # <ім'я>.corrupt-<yyyyMMdd_HHmmss>; збій перенесення — лише Warning.
    # Функція не кидає винятків через вміст файлу: спроба запуску служби не
    # блокується ніколи.
    [CmdletBinding()]
    param()

    $statePath = Get-BRAVOServiceRecoveryStatePath
    $result = [pscustomobject]@{
        State           = (New-BRAVOServiceRecoveryEmptyState)
        Status          = 'Missing'
        Warning         = $null
        QuarantinedPath = $null
    }
    if (-not [IO.File]::Exists($statePath)) { return $result }

    $problem = $null
    $status = 'Corrupt'
    $normalized = $null
    try {
        # ReadAllText сам знімає BOM, якщо файл записано не BRAVO.
        $text = [IO.File]::ReadAllText($statePath)
        $parsed = $null
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $parsed = $text | ConvertFrom-Json -ErrorAction Stop
        }
        if ($null -eq $parsed) {
            $problem = 'файл порожній'
        } else {
            $schemaProperty = $parsed.PSObject.Properties['schemaVersion']
            $servicesProperty = $parsed.PSObject.Properties['services']
            $hostnameProperty = $parsed.PSObject.Properties['hostname']
            if ($null -eq $schemaProperty -or [string]$schemaProperty.Value -ne '1') {
                $problem = 'невідома schemaVersion'
            } elseif ($null -eq $servicesProperty -or $null -eq $servicesProperty.Value) {
                $problem = "немає поля services"
            } elseif ($null -eq $hostnameProperty -or
                [string]$hostnameProperty.Value -ine [Environment]::MachineName) {
                $status = 'ForeignHost'
                $problem = "файл належить іншому хосту ('{0}')" -f [string]$(if ($null -ne $hostnameProperty) { $hostnameProperty.Value } else { '' })
            } else {
                $normalized = ConvertTo-BRAVOServiceRecoveryState -State $parsed
            }
        }
    } catch {
        $status = 'Corrupt'
        $problem = 'файл не розбирається: ' + $_.Exception.Message
        $normalized = $null
    }

    if ($null -eq $problem -and $null -ne $normalized) {
        $result.State = $normalized
        $result.Status = 'Ok'
        return $result
    }

    $result.Status = $status
    $quarantinePath = '{0}.corrupt-{1}' -f $statePath, (Get-Date).ToString('yyyyMMdd_HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    try {
        Move-Item -LiteralPath $statePath -Destination $quarantinePath -Force -ErrorAction Stop
        $result.QuarantinedPath = $quarantinePath
        $result.Warning = "State відновлення служб непридатний ($problem) — перенесено в $quarantinePath; облік спроб почато заново"
    } catch {
        $result.Warning = "State відновлення служб непридатний ($problem) і не перенесений у карантин ($($_.Exception.Message)); облік спроб почато заново"
    }
    return $result
}

function Write-BRAVOServiceRecoveryState {
    # Записує стан атомарно (UTF-8 без BOM; tmp + Replace/Move через
    # Write-BRAVOStateFileAtomic). Перед записом прибирає прострочені мітки
    # і проставляє hostname цього хоста та updatedAt.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$State,
        [datetime]$Now = (Get-Date)
    )

    $pruned = Remove-BRAVOServiceRecoveryExpiredAttempts -State $State -Now $Now
    $orderedServices = [ordered]@{}
    foreach ($serviceName in @($pruned.services.Keys | Sort-Object)) {
        $entry = $pruned.services[$serviceName]
        $orderedServices[$serviceName] = [ordered]@{
            # Новий [string[]] без PSObject-обгортки: інакше Windows
            # PowerShell 5.1 серіалізує масив як {"value":[...],"Count":n}.
            attempts       = [string[]]@($entry.attempts | ForEach-Object { [string]$_ })
            lastCriticalAt = $entry.lastCriticalAt
            stableSince    = $entry.stableSince
        }
    }
    $document = [ordered]@{
        schemaVersion = 1
        hostname      = [Environment]::MachineName
        updatedAt     = (ConvertTo-BRAVOServiceRecoveryDateText -Value $Now)
        services      = $orderedServices
    }
    $json = ConvertTo-Json -InputObject $document -Depth 5
    Write-BRAVOStateFileAtomic -Path (Get-BRAVOServiceRecoveryStatePath) -Text $json
}

function Get-BRAVOServiceRecoveryAttemptDecision {
    # Чи можна запускати службу зараз. Паузи за кількістю спроб у вікні:
    # 0 -> 0 хв, 1 -> 5, 2 -> 15, 3 і більше -> 60. -IgnorePause (нічний
    # Maintenance) дозволяє запуск без паузи, але номер спроби той самий.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$State,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][datetime]$Now,
        [switch]$IgnorePause
    )

    $policy = Get-BRAVOServiceRecoveryPolicy
    $normalized = ConvertTo-BRAVOServiceRecoveryState -State $State
    $entry = Get-BRAVOServiceRecoveryEntry -State $normalized -ServiceName $ServiceName
    $recent = @(Get-BRAVOServiceRecoveryWindowAttempt -Entry $entry -Now $Now)
    $recentCount = $recent.Count
    $ladder = @($policy.PauseMinutesByAttempt)
    $pauseMinutes = [int]$policy.PauseMinutesCeiling
    if ($recentCount -lt $ladder.Count) { $pauseMinutes = [int]$ladder[$recentCount] }

    $lastAttemptAt = $null
    $nextAllowedAt = $Now
    if ($recentCount -gt 0) {
        $lastAttemptAt = $recent[$recentCount - 1]
        $nextAllowedAt = $lastAttemptAt.AddMinutes($pauseMinutes)
    }
    $pauseElapsed = ($Now.ToUniversalTime() -ge $nextAllowedAt.ToUniversalTime())
    $reason = 'FirstAttempt'
    if ($recentCount -gt 0) {
        if ($pauseElapsed) {
            $reason = 'PauseElapsed'
        } elseif ($IgnorePause) {
            $reason = 'PauseIgnored'
        } else {
            $reason = 'PauseActive'
        }
    }

    return [pscustomobject]@{
        ServiceName    = $ServiceName
        AttemptNumber  = $recentCount + 1
        RecentAttempts = $recentCount
        LastAttemptAt  = $lastAttemptAt
        PauseMinutes   = $pauseMinutes
        NextAllowedAt  = $nextAllowedAt
        Allowed        = ([bool]$IgnorePause -or $pauseElapsed)
        Reason         = $reason
    }
}

function Register-BRAVOServiceRecoveryAttempt {
    # Облік спроби запуску: додає мітку Now, обрізає вікно, скидає
    # stableSince. CyclicAlertDue — пора надіслати CRITICAL «циклічно
    # падає»: спроб у вікні >= CyclicThreshold і попередній CRITICAL не
    # надсилався або був >= 24 год тому.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$State,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][datetime]$Now
    )

    $policy = Get-BRAVOServiceRecoveryPolicy
    $normalized = ConvertTo-BRAVOServiceRecoveryState -State $State
    $entry = Get-BRAVOServiceRecoveryEntry -State $normalized -ServiceName $ServiceName
    $recent = @(Get-BRAVOServiceRecoveryWindowAttempt -Entry $entry -Now $Now)
    $attemptTexts = @($recent | ForEach-Object { ConvertTo-BRAVOServiceRecoveryDateText -Value $_ })
    $attemptTexts += (ConvertTo-BRAVOServiceRecoveryDateText -Value $Now)
    $normalized.services[$ServiceName] = New-BRAVOServiceRecoveryServiceEntry `
        -Attempts $attemptTexts -LastCriticalAt $entry.lastCriticalAt -StableSince $null

    $attemptNumber = $attemptTexts.Count
    $criticalQuiet = $true
    if ($null -ne $entry.lastCriticalAt) {
        $lastCriticalTime = ConvertTo-BRAVOServiceRecoveryDateTime -Value $entry.lastCriticalAt
        $criticalQuiet = ((Get-BRAVOServiceRecoveryElapsedMinutes -From $lastCriticalTime -To $Now) -ge
            [double]($policy.WindowHours * 60))
    }
    $firstAttemptAt = $Now
    if ($recent.Count -gt 0) { $firstAttemptAt = $recent[0] }

    return [pscustomobject]@{
        State          = $normalized
        AttemptNumber  = $attemptNumber
        CyclicAlertDue = ($attemptNumber -ge [int]$policy.CyclicThreshold -and $criticalQuiet)
        FirstAttemptAt = $firstAttemptAt
    }
}

function Register-BRAVOServiceRecoveryCriticalSent {
    # Фіксує момент надсилання CRITICAL «циклічно падає» (lastCriticalAt).
    # Повертає НОВИЙ стан.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$State,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][datetime]$Now
    )

    $normalized = ConvertTo-BRAVOServiceRecoveryState -State $State
    $entry = Get-BRAVOServiceRecoveryEntry -State $normalized -ServiceName $ServiceName
    $normalized.services[$ServiceName] = New-BRAVOServiceRecoveryServiceEntry `
        -Attempts @($entry.attempts) `
        -LastCriticalAt (ConvertTo-BRAVOServiceRecoveryDateText -Value $Now) `
        -StableSince $entry.stableSince
    return $normalized
}

function Register-BRAVOServiceRecoveryStableObservation {
    # Служба спостерігається Running. Якщо по ній є облік спроб: перше
    # спостереження ставить stableSince = Now; якщо служба працює вже
    # >= StableResetMinutes (30 хв) — облік скидається (спроби, lastCriticalAt,
    # stableSince). Результат: State (НОВИЙ), Changed, Reset.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$State,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][datetime]$Now
    )

    $policy = Get-BRAVOServiceRecoveryPolicy
    $normalized = ConvertTo-BRAVOServiceRecoveryState -State $State
    $changed = $false
    $reset = $false
    if ($normalized.services.ContainsKey($ServiceName)) {
        $entry = $normalized.services[$ServiceName]
        if ($null -eq $entry.stableSince) {
            $normalized.services[$ServiceName] = New-BRAVOServiceRecoveryServiceEntry `
                -Attempts @($entry.attempts) -LastCriticalAt $entry.lastCriticalAt `
                -StableSince (ConvertTo-BRAVOServiceRecoveryDateText -Value $Now)
            $changed = $true
        } else {
            $stableSinceTime = ConvertTo-BRAVOServiceRecoveryDateTime -Value $entry.stableSince
            if ((Get-BRAVOServiceRecoveryElapsedMinutes -From $stableSinceTime -To $Now) -ge
                [double]$policy.StableResetMinutes) {
                $normalized.services.Remove($ServiceName)
                $changed = $true
                $reset = $true
            }
        }
    }

    return [pscustomobject]@{
        State   = $normalized
        Changed = $changed
        Reset   = $reset
    }
}

function New-BRAVOServiceRecoveryNotificationText {
    # Тексти сповіщень FR-6 (українською). Лише текст — доставка через
    # наявний Send-SlackAlert у runtime:
    #   Recovered   (WARNING)  - служба впала, журнали збережено, запущена;
    #   StartFailed (CRITICAL) - запустити після падіння не вдалося;
    #   Cyclic      (CRITICAL) - служба циклічно падає.
    # -Condition — результат Get-BRAVOManagedServiceCondition (береться
    # ExitCode; без нього — «ExitCode невідомий»). -LastScmEvent — об'єкт з
    # Id і TimeCreated (необов'язково).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Recovered', 'StartFailed', 'Cyclic')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Condition,
        [Parameter(Mandatory = $true)][int]$AttemptNumber,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$LogPath,
        [AllowNull()][AllowEmptyString()][string]$FailureReason,
        [AllowNull()][object]$LastScmEvent,
        [AllowNull()][object]$FirstAttemptAt,
        [AllowNull()][object]$Now
    )

    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $exitCodeText = 'ExitCode невідомий'
    if ($null -ne $Condition) {
        $exitCodeProperty = $Condition.PSObject.Properties['ExitCode']
        if ($null -ne $exitCodeProperty -and $null -ne $exitCodeProperty.Value -and
            -not [string]::IsNullOrWhiteSpace([string]$exitCodeProperty.Value)) {
            $exitCodeText = 'ExitCode ' + [string]$exitCodeProperty.Value
        }
    }
    $logText = $LogPath
    if ([string]::IsNullOrWhiteSpace($logText)) { $logText = 'не вказано' }

    switch ($Kind) {
        'Recovered' {
            $eventText = ''
            if ($null -ne $LastScmEvent) {
                $eventIdProperty = $LastScmEvent.PSObject.Properties['Id']
                $eventTimeProperty = $LastScmEvent.PSObject.Properties['TimeCreated']
                if ($null -ne $eventIdProperty -and $null -ne $eventIdProperty.Value) {
                    $eventText = ', подія ' + [string]$eventIdProperty.Value
                    if ($null -ne $eventTimeProperty -and $null -ne $eventTimeProperty.Value) {
                        $eventTime = ConvertTo-BRAVOServiceRecoveryDateTime -Value $eventTimeProperty.Value
                        $eventText += ' о ' + $eventTime.ToString('HH:mm', $invariant)
                    }
                }
            }
            return ('Служба {0} впала ({1}{2}), журнали збережено, запущена. Спроба {3} за добу. Журнал: {4}' -f
                $ServiceName, $exitCodeText, $eventText, $AttemptNumber, $logText)
        }
        'StartFailed' {
            $reasonText = $FailureReason
            if ([string]::IsNullOrWhiteSpace($reasonText)) { $reasonText = 'причину не встановлено' }
            return ('Не вдалося запустити службу {0} після падіння ({1}): {2}. Спроба {3} за добу. Журнал: {4}' -f
                $ServiceName, $exitCodeText, $reasonText, $AttemptNumber, $logText)
        }
        default {
            $sinceValue = $FirstAttemptAt
            if ($null -eq $sinceValue) { $sinceValue = $Now }
            if ($null -eq $sinceValue) { $sinceValue = Get-Date }
            $sinceTime = ConvertTo-BRAVOServiceRecoveryDateTime -Value $sinceValue
            return ('Служба {0} циклічно падає: {1} падінь з {2}, потрібне втручання. Журнал: {3}' -f
                $ServiceName, $AttemptNumber, $sinceTime.ToString('dd.MM HH:mm', $invariant), $logText)
        }
    }
}

# ============================================================
# #314 хвиля 4 (FR-3): профіль BRAVO_MAINTENANCE.ps1 -RecoverServices.
# ============================================================

function Get-BRAVOServiceRecoveryItemValue {
    # Приватний: значення поля опису служби (hashtable або об'єкт) — під
    # Set-StrictMode відсутня властивість об'єкта напряму не читається.
    param(
        [AllowNull()][object]$Item,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Item) { return $null }
    if ($Item -is [Collections.IDictionary]) { return $Item[$Name] }
    $property = $Item.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-BRAVOServiceRecoveryConditions {
    # Класифікація керованих служб для профілю -RecoverServices (FR-3, крок 1;
    # повторно — під lock-ом). Лише ЧИТАЄ стан. -Services — опис керованих
    # служб (Key: Bravo | ExchangeApi | BravoWeb, Name, Enabled); некерована
    # служба (компонент вимкнено, службу не встановлено, Disabled від
    # оператора) або служба без імені не класифікується. Ownership-маркер
    # читається ОДИН раз на виклик. Результат — об'єкти
    # Get-BRAVOManagedServiceCondition (BRAVO.System) з доданим Key у
    # канонічному порядку BRAVO -> exchangAPI -> BRAVO Web.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Services
    )

    $quiescenceState = $null
    try { $quiescenceState = Read-BRAVOServiceQuiescenceState } catch { $quiescenceState = $null }
    $conditions = @()
    foreach ($serviceKey in @(Get-BRAVOManagedServiceOrder -Direction Start)) {
        foreach ($service in @($Services)) {
            if ([string](Get-BRAVOServiceRecoveryItemValue -Item $service -Name 'Key') -ne $serviceKey) { continue }
            $serviceName = [string](Get-BRAVOServiceRecoveryItemValue -Item $service -Name 'Name')
            if (-not [bool](Get-BRAVOServiceRecoveryItemValue -Item $service -Name 'Enabled') -or
                [string]::IsNullOrWhiteSpace($serviceName)) { continue }
            $condition = Get-BRAVOManagedServiceCondition -Name $serviceName -QuiescenceState $quiescenceState
            Add-Member -InputObject $condition -NotePropertyName 'Key' -NotePropertyValue $serviceKey -Force
            $conditions += $condition
        }
    }
    return @($conditions)
}

function Get-BRAVOServiceRecoveryChainPlan {
    # План ланцюжка профілю -RecoverServices (FR-3, крок 5). ЧИСТА функція:
    # рішення лише з переданих станів. -Conditions — класифіковані керовані
    # служби (Key, Name, Condition, Status; hashtable або об'єкт, порядок
    # довільний). -EligibleNames — впалі служби, чия пауза минула
    # (Get-BRAVOServiceRecoveryAttemptDecision); без параметра — усі впалі.
    # Правила (рішення власника #314, порядок BRAVO -> exchangAPI -> BRAVO Web):
    #   - впала BRAVO: працюючі залежні (exchangAPI, BRAVO Web) зупиняються
    #     перед її запуском і запускаються після неї; впала залежна теж
    #     запускається (і обліковується); залежна в Pending -> Deferred;
    #   - впала exchangAPI / BRAVO Web без впалої BRAVO: запускається лише
    #     вона; BRAVO в Pending -> Deferred;
    #   - впала BRAVO у паузі (не в -EligibleNames): залежні від неї
    #     exchangAPI і BRAVO Web у цьому тику не запускаються, не
    #     зупиняються і не обліковуються, навіть якщо їхня власна пауза
    #     минула; впалі з них — у HeldByBravoNames (рядок зведення);
    #   - Disabled, NotInstalled, OwnedByBravo, призупинена (Failed, але не
    #     Stopped — §0.3) — поза планом.
    # Deferred непорожній = план цього тику НЕ виконується (служба саме
    # змінює стан; наступна перевірка через <= 15 хв).
    # Результат: FailedKeys/FailedNames (обліковуються як спроба;
    # AccountedNames — те саме), StopKeys/StopOrder (порядок зупинки BRAVO
    # Web -> exchangAPI), StartKeys/StartOrder (канонічний порядок запуску),
    # Deferred (імена), HeldByBravoNames (впалі залежні, утримані паузою
    # BRAVO).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Conditions,
        [AllowNull()][AllowEmptyCollection()][string[]]$EligibleNames
    )

    $byKey = @{}
    foreach ($item in @($Conditions)) {
        if ($null -eq $item) { continue }
        $itemKey = [string](Get-BRAVOServiceRecoveryItemValue -Item $item -Name 'Key')
        if ([string]::IsNullOrWhiteSpace($itemKey) -or $byKey.ContainsKey($itemKey)) { continue }
        $byKey[$itemKey] = [pscustomobject]@{
            Key       = $itemKey
            Name      = [string](Get-BRAVOServiceRecoveryItemValue -Item $item -Name 'Name')
            Condition = [string](Get-BRAVOServiceRecoveryItemValue -Item $item -Name 'Condition')
            Status    = [string](Get-BRAVOServiceRecoveryItemValue -Item $item -Name 'Status')
        }
    }
    $filterEligible = $PSBoundParameters.ContainsKey('EligibleNames') -and $null -ne $EligibleNames
    $isEligible = {
        param($Entry)
        if (-not (Test-BRAVOServiceRecoveryFailed -Condition $Entry)) { return $false }
        if (-not $filterEligible) { return $true }
        return (@($EligibleNames | Where-Object { [string]$_ -ieq $Entry.Name }).Count -gt 0)
    }

    $failed = @{}
    $stop = @{}
    $start = @{}
    $deferred = @{}
    $held = @{}
    $bravo = $byKey['Bravo']
    $bravoFailed = ($null -ne $bravo -and (& $isEligible $bravo))
    $bravoHeld = (-not $bravoFailed -and $null -ne $bravo -and (Test-BRAVOServiceRecoveryFailed -Condition $bravo))
    if ($bravoFailed) {
        $failed['Bravo'] = $true
        $start['Bravo'] = $true
    }
    foreach ($dependentKey in @('ExchangeApi', 'BravoWeb')) {
        $dependent = $byKey[$dependentKey]
        if ($null -eq $dependent) { continue }
        if ($bravoHeld) {
            if (Test-BRAVOServiceRecoveryFailed -Condition $dependent) { $held[$dependentKey] = $true }
        } elseif ($bravoFailed) {
            if (Test-BRAVOServiceRecoveryFailed -Condition $dependent) {
                $failed[$dependentKey] = $true
                $start[$dependentKey] = $true
            } elseif ($dependent.Condition -eq 'Running') {
                $stop[$dependentKey] = $true
                $start[$dependentKey] = $true
            } elseif ($dependent.Condition -eq 'Pending') {
                $deferred[$dependentKey] = $true
            }
        } elseif (& $isEligible $dependent) {
            $failed[$dependentKey] = $true
            $start[$dependentKey] = $true
            if ($null -ne $bravo -and $bravo.Condition -eq 'Pending') {
                $deferred['Bravo'] = $true
            }
        }
    }

    $startKeyOrder = @(Get-BRAVOManagedServiceOrder -Direction Start)
    $failedKeys = @($startKeyOrder | Where-Object { $failed.ContainsKey($_) })
    $stopKeys = @(Get-BRAVOManagedServiceOrder -Direction Stop | Where-Object { $stop.ContainsKey($_) })
    $startKeys = @($startKeyOrder | Where-Object { $start.ContainsKey($_) })
    $deferredKeys = @($startKeyOrder | Where-Object { $deferred.ContainsKey($_) })
    $heldKeys = @($startKeyOrder | Where-Object { $held.ContainsKey($_) })
    $failedNames = @($failedKeys | ForEach-Object { $byKey[$_].Name })
    return [pscustomobject]@{
        FailedKeys       = $failedKeys
        FailedNames      = $failedNames
        StopKeys         = $stopKeys
        StopOrder        = @($stopKeys | ForEach-Object { $byKey[$_].Name })
        StartKeys        = $startKeys
        StartOrder       = @($startKeys | ForEach-Object { $byKey[$_].Name })
        Deferred         = @($deferredKeys | ForEach-Object { $byKey[$_].Name })
        AccountedNames   = $failedNames
        HeldByBravoNames = @($heldKeys | ForEach-Object { $byKey[$_].Name })
    }
}

function Get-BRAVOServiceRecoveryScmEventOwner {
    # Приватний: якій службі належить подія SCM. Перший параметр події SCM —
    # ім'я служби (7034/7031 — відображуване ім'я, тому -Aliases: псевдонім ->
    # ім'я служби); коли параметрів немає — пошук імені окремим словом у
    # тексті. $null — подія не стосується жодної з -ServiceNames.
    param(
        [Parameter(Mandatory = $true)][object]$ScmEvent,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ServiceNames,
        [hashtable]$Aliases = @{}
    )

    $candidates = @()
    foreach ($serviceName in @($ServiceNames)) {
        if (-not [string]::IsNullOrWhiteSpace($serviceName)) { $candidates += , @([string]$serviceName, [string]$serviceName) }
    }
    foreach ($alias in @($Aliases.Keys)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$alias)) { $candidates += , @([string]$alias, [string]$Aliases[$alias]) }
    }
    $firstValue = $null
    $propertiesProperty = $ScmEvent.PSObject.Properties['Properties']
    if ($null -ne $propertiesProperty -and $null -ne $propertiesProperty.Value) {
        $firstProperty = @($propertiesProperty.Value) | Select-Object -First 1
        if ($null -ne $firstProperty) {
            $valueProperty = $firstProperty.PSObject.Properties['Value']
            $firstValue = if ($null -ne $valueProperty) { [string]$valueProperty.Value } else { [string]$firstProperty }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($firstValue)) {
        foreach ($candidate in $candidates) {
            if ($firstValue.Trim() -ieq $candidate[0]) { return $candidate[1] }
        }
        return $null
    }
    $messageProperty = $ScmEvent.PSObject.Properties['Message']
    $message = if ($null -ne $messageProperty) { [string]$messageProperty.Value } else { '' }
    foreach ($candidate in $candidates) {
        $pattern = '(?<![\w.-])' + [regex]::Escape($candidate[0]) + '(?![\w.-])'
        if ([regex]::IsMatch($message, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) { return $candidate[1] }
    }
    return $null
}

function Select-BRAVOServiceRecoveryScmEvents {
    # ЧИСТИЙ селектор подій SCM для журналу RECOVER (FR-3, крок 7): лише події
    # служб -ServiceNames (див. Get-BRAVOServiceRecoveryScmEventOwner),
    # хронологічно, не більше -MaxEvents найновіших. Результат — об'єкти
    # ServiceName, Id, TimeCreated, Message.
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Events,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ServiceNames,
        [hashtable]$Aliases = @{},
        [int]$MaxEvents = 50
    )

    $selected = @()
    foreach ($scmEvent in @($Events)) {
        if ($null -eq $scmEvent) { continue }
        $owner = Get-BRAVOServiceRecoveryScmEventOwner -ScmEvent $scmEvent -ServiceNames $ServiceNames -Aliases $Aliases
        if ($null -eq $owner) { continue }
        $timeCreated = $null
        $timeProperty = $scmEvent.PSObject.Properties['TimeCreated']
        if ($null -ne $timeProperty) {
            try { $timeCreated = ConvertTo-BRAVOServiceRecoveryDateTime -Value $timeProperty.Value } catch { $timeCreated = $null }
        }
        $idProperty = $scmEvent.PSObject.Properties['Id']
        $messageProperty = $scmEvent.PSObject.Properties['Message']
        $selected += [pscustomobject]@{
            ServiceName = $owner
            Id          = $(if ($null -ne $idProperty) { $idProperty.Value -as [int] } else { $null })
            TimeCreated = $timeCreated
            Message     = $(if ($null -ne $messageProperty) { [string]$messageProperty.Value } else { '' })
        }
    }
    $sorted = @($selected | Sort-Object -Property {
            if ($null -ne $_.TimeCreated) { $_.TimeCreated.ToUniversalTime() } else { [datetime]::MinValue }
        })
    if ($MaxEvents -gt 0 -and $sorted.Count -gt $MaxEvents) {
        $sorted = @($sorted | Select-Object -Last $MaxEvents)
    }
    return @($sorted)
}

function Get-BRAVOServiceRecoveryScmEvents {
    # Події SCM служб -ServiceNames із журналу System з моменту завантаження
    # ОС (LastBootUpTime; недоступний — останні WindowHours годин): Id із
    # політики (ScmEventIds), не більше -MaxEvents найновіших. Лише ЧИТАЄ і
    # ніколи не кидає винятку: поза Windows або без доступу до журналу —
    # Available = $false і причина («події SCM недоступні»).
    # Результат: Available, Events (Select-BRAVOServiceRecoveryScmEvents),
    # Since, Reason.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ServiceNames,
        [int]$MaxEvents = 0
    )

    $policy = Get-BRAVOServiceRecoveryPolicy
    if ($MaxEvents -le 0) { $MaxEvents = [int]$policy.MaxScmEvents }
    $result = [pscustomobject]@{ Available = $false; Events = @(); Since = $null; Reason = $null }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        $null -eq (Get-Command -Name 'Get-WinEvent' -ErrorAction SilentlyContinue)) {
        $result.Reason = 'події SCM недоступні: журналу подій Windows (Get-WinEvent) на цьому хості немає'
        return $result
    }

    $since = $null
    try {
        if ($null -ne (Get-Command -Name 'Get-BRAVOWmiInstance' -ErrorAction SilentlyContinue)) {
            $operatingSystem = @(Get-BRAVOWmiInstance -ClassName 'Win32_OperatingSystem') | Select-Object -First 1
            if ($null -ne $operatingSystem) {
                $bootProperty = $operatingSystem.PSObject.Properties['LastBootUpTime']
                if ($null -ne $bootProperty -and $null -ne $bootProperty.Value) {
                    $since = if ($bootProperty.Value -is [datetime]) {
                        [datetime]$bootProperty.Value
                    } else {
                        [Management.ManagementDateTimeConverter]::ToDateTime([string]$bootProperty.Value)
                    }
                }
            }
        }
    } catch {
        $since = $null
    }
    if ($null -eq $since) { $since = (Get-Date).AddHours(-[int]$policy.WindowHours) }
    $result.Since = $since

    # 7034/7031 несуть відображуване ім'я служби: псевдоніми для селектора.
    $aliases = @{}
    foreach ($serviceName in @($ServiceNames)) {
        if ([string]::IsNullOrWhiteSpace($serviceName)) { continue }
        try {
            $service = @(Get-Service -Name $serviceName -ErrorAction Stop) | Select-Object -First 1
            if ($null -ne $service -and -not [string]::IsNullOrWhiteSpace([string]$service.DisplayName) -and
                [string]$service.DisplayName -ine $serviceName) {
                $aliases[[string]$service.DisplayName] = [string]$serviceName
            }
        } catch {
            # Служби немає — шукаємо лише за іменем.
        }
    }

    try {
        $rawEvents = @(Get-WinEvent -FilterHashtable @{
                LogName      = 'System'
                ProviderName = 'Service Control Manager'
                Id           = @($policy.ScmEventIds)
                StartTime    = $since
            } -ErrorAction Stop)
    } catch {
        # «No events were found» — штатна відсутність подій, не збій доступу.
        if ([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
            $result.Available = $true
            return $result
        }
        $result.Reason = "події SCM недоступні: $($_.Exception.Message)"
        return $result
    }
    $result.Available = $true
    $result.Events = @(Select-BRAVOServiceRecoveryScmEvents -Events $rawEvents -ServiceNames $ServiceNames -Aliases $aliases -MaxEvents $MaxEvents)
    return $result
}

function Add-BRAVOServiceRecoverySummaryLine {
    # Зведений журнал профілю -RecoverServices (LOGS\
    # BRAVO_SERVICE_RECOVERY_SUMMARY.log, UTF-8 без BOM) — рядок про впалу
    # службу в паузі, коли профіль нічого не робить. Перевірка йде кожні
    # 15 хв, тому рядок дописується, лише якщо він не збігається з останнім.
    # Повертає $true, якщо рядок дописано.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $line = $Text.Trim()
    if ([IO.File]::Exists($Path)) {
        $lastLine = @([IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Last 1
        if ([string]$lastLine -ceq $line) { return $false }
    } else {
        $directory = Split-Path -Path $Path -Parent
        if (-not [string]::IsNullOrWhiteSpace($directory) -and -not [IO.Directory]::Exists($directory)) {
            [void][IO.Directory]::CreateDirectory($directory)
        }
    }
    [IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    return $true
}

function Get-BRAVOServiceRecoveryTaskEventSubscription {
    # XPath-фільтр подієвого тригера задачі BRAVO_SERVICE_RECOVERY: журнал
    # System, джерело Service Control Manager, EventID з політики. Фільтра за
    # іменем служби немає свідомо (7034 несе display name, а профіль
    # -RecoverServices без впалих керованих служб виходить за секунди).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [int[]]$EventIds = @((Get-BRAVOServiceRecoveryPolicy).ScmEventIds)
    )

    $eventFilter = (@($EventIds) | ForEach-Object { 'EventID={0}' -f [int]$_ }) -join ' or '
    return ('<QueryList><Query Id="0" Path="System"><Select Path="System">' +
        "*[System[Provider[@Name='Service Control Manager'] and ($eventFilter)]]" +
        '</Select></Query></QueryList>')
}

function Add-BRAVOServiceRecoveryTaskTriggers {
    # Тригери і налаштування задачі BRAVO_SERVICE_RECOVERY (FR-4) у
    # визначенні Task Scheduler 2.0 (COM ITaskDefinition або об'єкт тієї ж
    # форми: Triggers.Create(type), Settings). Нічого не реєструє.
    #   - подія SCM (TASK_TRIGGER_EVENT = 0) із затримкою EventTriggerDelay;
    #   - старт ОС (TASK_TRIGGER_BOOT = 8) із затримкою BootTriggerDelay;
    #   - щодня з 00:00 (TASK_TRIGGER_DAILY = 2) з повтором RepeatInterval
    #     протягом доби — страховка, якщо подію пропущено.
    # MultipleInstances = IgnoreNew (2) незалежно від глобального
    # schedulerSettings.MultipleInstances: шторм подій SCM не множить
    # екземпляри; ExecutionTimeLimit обмежує завислий запуск;
    # StartWhenAvailable вимкнено — пропущений періодичний тик не потрібен.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Definition,
        [object]$Policy = (Get-BRAVOServiceRecoveryPolicy),
        [datetime]$Today = (Get-Date).Date
    )

    $Definition.Settings.MultipleInstances = 2
    $Definition.Settings.StartWhenAvailable = $false
    $Definition.Settings.ExecutionTimeLimit = [string]$Policy.TaskExecutionTimeLimit

    $eventTrigger = $Definition.Triggers.Create(0) # TASK_TRIGGER_EVENT
    $eventTrigger.Subscription = Get-BRAVOServiceRecoveryTaskEventSubscription -EventIds @($Policy.ScmEventIds)
    $eventTrigger.Delay = [string]$Policy.EventTriggerDelay
    $eventTrigger.Enabled = $true

    $bootTrigger = $Definition.Triggers.Create(8) # TASK_TRIGGER_BOOT
    $bootTrigger.Delay = [string]$Policy.BootTriggerDelay
    $bootTrigger.Enabled = $true

    $dailyTrigger = $Definition.Triggers.Create(2) # TASK_TRIGGER_DAILY
    $dailyTrigger.StartBoundary = $Today.Date.ToString("yyyy-MM-dd'T'HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture)
    $dailyTrigger.DaysInterval = 1
    $dailyTrigger.Repetition.Interval = [string]$Policy.RepeatInterval
    $dailyTrigger.Repetition.Duration = 'P1D'
    $dailyTrigger.Repetition.StopAtDurationEnd = $false
    $dailyTrigger.Enabled = $true
}

function Test-BRAVOServiceRecoveryTaskDefinition {
    # Перевірка ФАКТИЧНОГО визначення задачі BRAVO_SERVICE_RECOVERY для
    # BRAVO_TASKS_DIAGNOSE (ті самі правила, що Add-BRAVOServiceRecoveryTaskTriggers).
    # ЧИСТА: приймає COM ITaskDefinition або об'єкт тієї ж форми. Повертає
    # перелік проблем (порожній — визначення правильне).
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][object]$Definition,
        [object]$Policy = (Get-BRAVOServiceRecoveryPolicy)
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $triggers = @(@($Definition.Triggers) | Where-Object { $null -ne $_ })
    $firstOfType = {
        param([int]$Type)
        @($triggers | Where-Object { [int]$_.Type -eq $Type }) | Select-Object -First 1
    }

    $eventTrigger = & $firstOfType 0
    if ($null -eq $eventTrigger) {
        $problems.Add('немає тригера за подією SCM (EventTrigger)')
    } else {
        $subscription = [string]$eventTrigger.Subscription
        if ($subscription -notmatch 'Service Control Manager') {
            $problems.Add('тригер за подією SCM: фільтр не на джерело Service Control Manager')
        }
        foreach ($eventId in @($Policy.ScmEventIds)) {
            if ($subscription -notmatch ('EventID={0}(?!\d)' -f [int]$eventId)) {
                $problems.Add("тригер за подією SCM: у фільтрі немає EventID $eventId")
            }
        }
        if ([string]$eventTrigger.Delay -ne [string]$Policy.EventTriggerDelay) {
            $problems.Add("тригер за подією SCM: Delay='$($eventTrigger.Delay)', очікується $($Policy.EventTriggerDelay)")
        }
        if (-not [bool]$eventTrigger.Enabled) { $problems.Add('тригер за подією SCM вимкнено') }
    }

    $bootTrigger = & $firstOfType 8
    if ($null -eq $bootTrigger) {
        $problems.Add('немає тригера після старту Windows (BootTrigger)')
    } else {
        if ([string]$bootTrigger.Delay -ne [string]$Policy.BootTriggerDelay) {
            $problems.Add("тригер після старту Windows: Delay='$($bootTrigger.Delay)', очікується $($Policy.BootTriggerDelay)")
        }
        if (-not [bool]$bootTrigger.Enabled) { $problems.Add('тригер після старту Windows вимкнено') }
    }

    $dailyTrigger = & $firstOfType 2
    if ($null -eq $dailyTrigger) {
        $problems.Add('немає щоденного тригера з повтором (CalendarTrigger)')
    } else {
        if ([string]$dailyTrigger.Repetition.Interval -ne [string]$Policy.RepeatInterval) {
            $problems.Add("щоденний тригер: повтор '$($dailyTrigger.Repetition.Interval)', очікується $($Policy.RepeatInterval)")
        }
        if (-not [bool]$dailyTrigger.Enabled) { $problems.Add('щоденний тригер вимкнено') }
    }

    if ([int]$Definition.Settings.MultipleInstances -ne 2) {
        $problems.Add("MultipleInstances=$($Definition.Settings.MultipleInstances), очікується 2 (IgnoreNew)")
    }
    if ([string]$Definition.Settings.ExecutionTimeLimit -ne [string]$Policy.TaskExecutionTimeLimit) {
        $problems.Add("ExecutionTimeLimit='$($Definition.Settings.ExecutionTimeLimit)', очікується $($Policy.TaskExecutionTimeLimit)")
    }
    return $problems.ToArray()
}
