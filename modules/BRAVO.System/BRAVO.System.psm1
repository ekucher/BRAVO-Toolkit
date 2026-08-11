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
        [int]$StartupDelayMinutes = 0
    )

    if ($TaskType -eq 'Recovery') {
        if ($StartupDelayMinutes -gt 0) {
            return "після наступного старту Windows; затримка $StartupDelayMinutes хв."
        }
        return "після наступного старту Windows"
    }

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
