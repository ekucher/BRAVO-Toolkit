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
