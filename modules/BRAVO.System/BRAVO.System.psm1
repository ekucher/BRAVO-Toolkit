# Shared system and Task Scheduler helpers.

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function ConvertTo-BRAVOProcessArgument {
    param([string]$Value)

    return '"' + $Value.Replace('"', '\"') + '"'
}

function ConvertTo-BRAVOTaskPath {
    param([string]$TaskPath)

    if ([string]::IsNullOrWhiteSpace($TaskPath)) {
        throw "schedulerSettings.TaskPath не налаштовано"
    }

    $trimmed = $TaskPath.Trim().Trim("\")
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return "\"
    }
    if ($trimmed -match '[/:*?"<>|]' -or $trimmed -match '(^|\\)\.\.?($|\\)') {
        throw "Некоректний TaskPath: $TaskPath"
    }
    return "\$trimmed\"
}

function ConvertTo-BRAVOSchedulerLogonType {
    # Єдине відображення schedulerSettings.LogonType -> числове значення
    # Task Scheduler. Раніше жило локально в BRAVO_TASKS_INSTALL.ps1, через що
    # Diagnose не мав спільного правила й порівнював LogonType із жорстко
    # прописаною 5.
    param([string]$Value)

    switch ($Value) {
        "Interactive" { return 3 }    # TASK_LOGON_INTERACTIVE_TOKEN
        "ServiceAccount" { return 5 } # TASK_LOGON_SERVICE_ACCOUNT
        default { throw "Непідтримуваний LogonType: $Value" }
    }
}

function Format-BRAVOSchedulerNextRun {
    # Людиночитний "наступний запуск". Recovery використовує boot-тригер, для
    # якого Task Scheduler COM повертає sentinel-значення 30.12.1899 —
    # форматувати його як звичайну дату не можна. Для boot-завдань показуємо,
    # що запуск станеться після старту Windows (із затримкою, якщо задана).
    # Спільний для Installer і Diagnose, щоб обидва показували однаково.
    param(
        [string]$TaskType,
        $NextRunTime,
        [int]$StartupDelayMinutes = 0,
        # Recovery може мати ДВА trigger на одному завданні: boot (сентинел
        # NextRunTime, тому й лишається окремим текстом нижче) і daily о
        # Restore.WindowStart. Без DailyWindowStart текст описував би лише
        # половину реального розкладу.
        [string]$DailyWindowStart,
        # Boot-trigger сам New-BRAVOTaskDefinition створює лише коли
        # Restore.RunMissedOnStartup=true (BRAVO.config). За замовчуванням
        # $true — зберігає попередню поведінку викликів без цього параметра
        # (усі наявні виклики й тести передбачали boot-trigger присутнім).
        [bool]$HasBootTrigger = $true
    )

    if ($TaskType -eq 'Recovery' -and $HasBootTrigger) {
        $bootText = if ($StartupDelayMinutes -gt 0) {
            "після наступного старту Windows; затримка $StartupDelayMinutes хв."
        } else {
            "після наступного старту Windows"
        }
        if (-not [string]::IsNullOrWhiteSpace($DailyWindowStart)) {
            return "$bootText та щодня о $DailyWindowStart"
        }
        return $bootText
    }
    # Recovery БЕЗ boot-trigger (RunMissedOnStartup=false) має лише daily
    # trigger — NextRunTime для нього РЕАЛЬНА дата (не сентинел 1899), тому
    # форматується так само, як звичайне щоденне завдання нижче.

    try {
        # .Year -gt 1900 відкидає sentinel 30.12.1899 (він БІЛЬШИЙ за
        # DateTime.MinValue, тому стара перевірка -gt MinValue його пропускала).
        if ($NextRunTime -is [datetime] -and $NextRunTime.Year -gt 1900) {
            return $NextRunTime.ToString('dd.MM.yyyy HH:mm')
        }
    } catch {
        # Доступ до COM-властивості NextRunTime може кинути виняток; це не
        # помилка діагностики — трактуємо як 'невідомо' (значення нижче).
    }
    return 'невідомо'
}

# ---------------------------------------------------------------------------
# Ownership-маркер зупинки служб (BRAVO_SERVICE_QUIESCENCE.json).
#
# Проблема: якщо Maintenance/DataRestore зупинив служби і процес загинув
# ЖОРСТКО (kill, втрата живлення — finally не виконався), in-memory знімки
# станів втрачаються і служби лишаються зупиненими назавжди. Водночас
# техпідтримка легітимно зупиняє служби вручну для регламентних робіт —
# автоматичний старт у такий момент неприпустимий.
#
# Рішення: власник (Maintenance/DataRestore) ПЕРЕД зупинкою пише
# персистентний маркер зі своїм pid+processStartTime і ТОЧНИМИ resolved
# іменами служб; при штатному відновленні служб у finally — прибирає.
# Watchdog (Health, кожні 4 год) стартує служби ЛИШЕ якщо маркер існує,
# власник МЕРТВИЙ і restartSuppressed=false. Без маркера (ручна зупинка
# техпідтримкою) BRAVO не чіпає служби ніколи.
#
# Атомарність запису — той самий патерн, що BRAVO_VSS_OWNERSHIP.json
# (GUID-tmp + [IO.File]::Replace/Move).
# ---------------------------------------------------------------------------

function Get-BRAVOServiceQuiescenceStatePath {
    $programDataRoot = [Environment]::GetFolderPath('CommonApplicationData')
    if ([string]::IsNullOrWhiteSpace($programDataRoot)) {
        throw 'CommonApplicationData недоступний для service-quiescence state'
    }
    return Join-Path $programDataRoot 'BRAVO\State\BRAVO_SERVICE_QUIESCENCE.json'
}

function Write-BRAVOServiceQuiescenceState {
    # Пишеться ПЕРЕД першою зупинкою служби. Збій запису має абортувати
    # зупинку у викликача (fail-closed): без маркера аварія знову стала б
    # «мовчазною». Services — масив @{ Name = ...; RestartIntent = $true/$false }
    # з ФАКТИЧНИМИ resolved іменами (BravoWeb резолвиться в кожному рантаймі
    # по-своєму — watchdog не повинен резолвити сам).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('BRAVO_MAINTENANCE', 'BRAVO_DATA_RESTORE')][string]$Owner,
        [Parameter(Mandatory = $true)][object[]]$Services,
        [string]$LogFile,
        [switch]$RestartSuppressed
    )

    $statePath = Get-BRAVOServiceQuiescenceStatePath
    $stateDirectory = Split-Path -Path $statePath -Parent
    if (-not [IO.Directory]::Exists($stateDirectory)) {
        [void][IO.Directory]::CreateDirectory($stateDirectory)
    }
    $state = [ordered]@{
        schemaVersion = 1
        owner = $Owner
        hostname = [Environment]::MachineName
        pid = $PID
        # Module-qualified: захист від затінення Get-Process функцією-стабом
        # у сесії викликача (реальний випадок у self-test).
        processStartTime = $(try { (Microsoft.PowerShell.Management\Get-Process -Id $PID -ErrorAction Stop).StartTime.ToString('o') } catch { $null })
        createdAt = (Get-Date).ToString('o')
        logFile = [string]$LogFile
        restartSuppressed = [bool]$RestartSuppressed
        services = @($Services | ForEach-Object {
            [ordered]@{ Name = [string]$_.Name; RestartIntent = [bool]$_.RestartIntent }
        })
    }
    $temporaryStatePath = Join-Path $stateDirectory ('.BRAVO_SERVICE_QUIESCENCE_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $backupStatePath = Join-Path $stateDirectory ('.BRAVO_SERVICE_QUIESCENCE_{0}.bak' -f [guid]::NewGuid().ToString('N'))
    $stateReplaced = $false
    try {
        $json = $state | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($temporaryStatePath, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($statePath)) {
            # .NET Framework відхиляє null-backup у Replace — тому явний шлях.
            [IO.File]::Replace($temporaryStatePath, $statePath, $backupStatePath)
            $stateReplaced = $true
        } else {
            [IO.File]::Move($temporaryStatePath, $statePath)
        }
    } finally {
        if ([IO.File]::Exists($temporaryStatePath)) {
            [IO.File]::Delete($temporaryStatePath)
        }
        if ($stateReplaced -and [IO.File]::Exists($backupStatePath)) {
            Remove-Item -LiteralPath $backupStatePath -Force -ErrorAction SilentlyContinue
        }
    }
    return $state
}

function Read-BRAVOServiceQuiescenceState {
    # $null = маркера немає АБО він невалідний/чужий (інший hostname,
    # незнайома schemaVersion, зіпсований JSON) — у всіх цих випадках
    # watchdog НЕ діє (лише алертить про невалідний файл сам викликач,
    # якщо вважає за потрібне). Валідний чужий маркер не «лікуємо» — це
    # свідома fail-safe поведінка, як у VSS-ownership.
    [CmdletBinding()]
    param()

    $statePath = Get-BRAVOServiceQuiescenceStatePath
    if (-not [IO.File]::Exists($statePath)) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($statePath, (New-Object Text.UTF8Encoding($false)))
        $state = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
    if ($null -eq $state.PSObject.Properties['schemaVersion'] -or [int]$state.schemaVersion -ne 1) { return $null }
    if ([string]$state.owner -notin @('BRAVO_MAINTENANCE', 'BRAVO_DATA_RESTORE')) { return $null }
    if ([string]$state.hostname -ne [Environment]::MachineName) { return $null }
    return $state
}

function Clear-BRAVOServiceQuiescenceState {
    # Ідемпотентне видалення (штатне завершення відновлення служб).
    [CmdletBinding()]
    param()

    $statePath = Get-BRAVOServiceQuiescenceStatePath
    if ([IO.File]::Exists($statePath)) {
        Remove-Item -LiteralPath $statePath -Force -ErrorAction Stop
    }
}

function Set-BRAVOServiceQuiescenceRestartSuppressed {
    # Для fail-closed гілки DataRestore (rollback неповний): служби НАВМИСНО
    # лишаються зупиненими, маркер зберігається як евіденс, але watchdog не
    # має права стартувати — лише алертити про потребу ручного втручання.
    [CmdletBinding()]
    param()

    $state = Read-BRAVOServiceQuiescenceState
    if ($null -eq $state) { return $null }
    $services = @($state.services | ForEach-Object {
        @{ Name = [string]$_.Name; RestartIntent = [bool]$_.RestartIntent }
    })
    return Write-BRAVOServiceQuiescenceState `
        -Owner ([string]$state.owner) `
        -Services $services `
        -LogFile ([string]$state.logFile) `
        -RestartSuppressed
}

function Test-BRAVOProcessAlive {
    # Предикат «процес із цим PID і саме цим startTime ще живий».
    # Мертвий PID або перевикористаний (інший startTime) -> $false.
    # Помилка ДОСТУПУ до живого процесу -> консервативно $true (fail-safe:
    # краще не стартувати служби під живим власником, ніж навпаки).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string]$ProcessStartTime
    )

    $process = Microsoft.PowerShell.Management\Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    if ([string]::IsNullOrWhiteSpace($ProcessStartTime)) {
        # Маркер без startTime (не мав би траплятися) — вважаємо живим,
        # поки PID існує (консервативно).
        return $true
    }
    try {
        return ($process.StartTime.ToString('o') -eq $ProcessStartTime)
    } catch {
        return $true
    }
}

function Get-BRAVOTaskRootReadinessResults {
    # Одна canonical точка інтерпретації readiness LIMSRoot/SystemLogRoot/
    # BackupRoot для планованих завдань. Раніше ця логіка жила лише в
    # BRAVO_DRY_RUN.ps1 (Get-BRAVODryRunRootReadinessResults) — тому
    # BRAVO_TASKS_INSTALL.ps1 міг зареєструвати Maintenance/Recovery,
    # приречені на негайний exit 30 при КОЖНОМУ запуску (BRAVO_MAINTENANCE.ps1
    # має власну guard-перевірку одразу після Import-BravoConfiguration), і
    # завершитися "Статус: УСПІШНО". DryRun і Installer тепер читають РІВНО
    # цю функцію (спільний модуль BRAVO.System, вже імпортований обома) —
    # одне правило, а не дві незалежні його копії.
    #
    # BackupRoot — mandatory для BRAVO_ARCHIV/BRAVO_ARCHIV_HEALTH (обидва
    # реально пишуть/читають туди): невизначений завжди FAIL, незалежно від
    # служб чи увімкнених завдань. (BRAVO.config уже throw-ить на це
    # безумовно під час завантаження конфігурації — рядок тут лише для
    # повноти читання DryRun, який показує стан усіх коренів одразу.)
    #
    # LIMSRoot/SystemLogRoot — НЕ mandatory для BRAVO_ARCHIV/
    # BRAVO_ARCHIV_HEALTH/BAZASync (safety-review "service state != backup
    # policy": жоден з них LIMSRoot не читає як умову результату, SystemLogRoot
    # читає лише BRAVO_MAINTENANCE), тому невизначений корінь сам по собі —
    # НЕ FAIL для них. Але BRAVO_MAINTENANCE/BRAVO_RESTORE_RECOVERY реально
    # керують службою й ротацією системних журналів — якщо ЦІ завдання
    # увімкнені в schedulerSettings, невизначений корінь є справжньою
    # readiness-помилкою САМЕ для них і рапортується як FAIL, а не мовчазний
    # PASS чи непомітний WARN.
    #
    # Жоден зі string-параметрів НЕ Mandatory (той самий урок, що вже
    # закрито для Resolve-BRAVOInstallationDiscovery -LimsRoot): порожній
    # рядок — легітимне, ОЧІКУВАНЕ значення (unresolved root), а
    # PowerShell's Mandatory-string-параметр відхиляє порожній рядок
    # окремою помилкою біндингу, а не просто "не передано".
    param(
        [string]$BackupRootSource,
        [string]$BackupRootValue,
        [string]$BackupRootReason,
        [string]$LimsRootSource,
        [string]$LimsRootValue,
        [string]$LimsRootReason,
        [string]$SystemLogRootSource,
        [string]$SystemLogRootValue,
        [string]$SystemLogRootReason,
        [bool]$MaintenanceTaskEnabled,
        [bool]$RecoveryTaskEnabled
    )

    $results = New-Object System.Collections.Generic.List[object]
    $backupRootUnresolved = ($BackupRootSource -eq 'Error' -or [string]::IsNullOrWhiteSpace($BackupRootValue))
    if ($backupRootUnresolved) {
        $results.Add([pscustomobject]@{
            Status = 'FAIL'; Category = 'Корені'; Label = "BackupRoot [$BackupRootSource]"
            Detail = "не визначено: $BackupRootReason. BackupRoot обов'язковий для BRAVO_ARCHIV/BRAVO_ARCHIV_HEALTH."
        })
    } else {
        $results.Add([pscustomobject]@{
            Status = 'PASS'; Category = 'Корені'; Label = "BackupRoot [$BackupRootSource]"; Detail = $BackupRootValue
        })
    }

    # Точний перелік УВІМКНЕНИХ завдань (а не завжди обидві назви одразу) —
    # повідомлення про помилку має називати САМЕ той task type, що реально
    # постраждає, а не узагальнено обидва, коли лише один з них увімкнено.
    $affectedTaskNames = @()
    if ($MaintenanceTaskEnabled) { $affectedTaskNames += 'BRAVO_MAINTENANCE' }
    if ($RecoveryTaskEnabled) { $affectedTaskNames += 'BRAVO_RESTORE_RECOVERY' }
    $maintenanceOrRecoveryEnabled = $affectedTaskNames.Count -gt 0

    foreach ($rootReport in @(
        @{ Name = 'LIMSRoot'; Source = $LimsRootSource; Value = $LimsRootValue; Reason = $LimsRootReason },
        @{ Name = 'SystemLogRoot'; Source = $SystemLogRootSource; Value = $SystemLogRootValue; Reason = $SystemLogRootReason }
    )) {
        $rootUnresolved = ([string]$rootReport.Source -eq 'Error' -or [string]::IsNullOrWhiteSpace([string]$rootReport.Value))
        if (-not $rootUnresolved) {
            $results.Add([pscustomobject]@{
                Status = 'PASS'; Category = 'Корені'
                Label = "$($rootReport.Name) [$($rootReport.Source)]"; Detail = $rootReport.Value
            })
            continue
        }
        if ($maintenanceOrRecoveryEnabled) {
            $results.Add([pscustomobject]@{
                Status = 'FAIL'; Category = 'Корені'
                Label = "$($rootReport.Name) [$($rootReport.Source)]"
                Detail = (
                    "не визначено: $($rootReport.Reason). " +
                    "$($affectedTaskNames -join ' і ') увімкнено в schedulerSettings, і завдання реально потребує " +
                    "$($rootReport.Name) — задайте pathSettings.$($rootReport.Name) явно або встановіть службу BRAVO."
                )
            })
        } else {
            $results.Add([pscustomobject]@{
                Status = 'WARN'; Category = 'Корені'
                Label = "$($rootReport.Name) [$($rootReport.Source)]"
                Detail = (
                    "не визначено: $($rootReport.Reason). " +
                    "BRAVO_ARCHIV/BRAVO_ARCHIV_HEALTH не потребують $($rootReport.Name) — backup лишається дозволеним; " +
                    "Maintenance/Recovery наразі вимкнені в schedulerSettings."
                )
            })
        }
    }
    return $results.ToArray()
}

function Get-BRAVOExpectedSchedulerPrincipal {
    # Канонічний principal запланованого завдання з effective schedulerSettings.
    # Installer застосовує САМЕ ці значення під час створення завдання, а
    # Diagnose перевіряє фактичне визначення проти НИХ. Один розрахунок означає,
    # що Installer і Diagnose не можуть розійтися в тому, що вважається
    # правильним (інваріант ТЗ: прийняте Installer-ом визначення не має
    # оголошуватися invalid у Diagnose через інший набір правил).
    param([Parameter(Mandatory = $true)][hashtable]$SchedulerSettings)

    return [pscustomobject]@{
        UserId = [string]$SchedulerSettings.RunAsUser
        LogonType = ConvertTo-BRAVOSchedulerLogonType -Value ([string]$SchedulerSettings.LogonType)
        # RunLevel завжди Highest (1): комплект виконує адміністративні операції
        # (VSS, керування службами, ACL). Це контракт Installer, а не окремий
        # конфігурований параметр — але Diagnose отримує його звідси, а не хардкодить.
        RunLevel = 1
    }
}
