# ============================================================
# BRAVO.ServiceRecovery — облік відновлення впалих служб (#314, хвиля 3).
#
# Чиста логіка без звернень до SCM/WMI: політика пауз, state-файл спроб
# (FR-5), рішення «чи можна запускати зараз», облік CRITICAL «циклічно
# падає» і тексти сповіщень (FR-6). Запускає служби лише Maintenance —
# цей модуль нічого не запускає і нічого не надсилає.
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

    # Присвоєння $null змінній, типізованій [string] (параметр), у Windows
    # PowerShell 5.1 дає '' — тоді перевірка «$null -ne lastCriticalAt»
    # хибно спрацьовує і порожня дата потрапляє в [datetime]-параметр.
    # Тому значення полів — у нетипізованих локальних змінних.
    $lastCriticalValue = $null
    if (-not [string]::IsNullOrWhiteSpace($LastCriticalAt)) { $lastCriticalValue = [string]$LastCriticalAt }
    $stableSinceValue = $null
    if (-not [string]::IsNullOrWhiteSpace($StableSince)) { $stableSinceValue = [string]$StableSince }
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
