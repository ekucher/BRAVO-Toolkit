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

    # Recovery (5.2.0) має рівно ОДИН boot-trigger (профіль робочого часу,
    # Restore.BootRestoreMode="HoldServices"); daily-trigger о WindowStart
    # прибрано — на 24/7-профілі пропущений слот підхоплює щонічне
    # Maintenance, а саме Recovery-завдання вимкнене.
    # BackupCatchUp — так само лише boot-trigger (підхоплення пропущеної
    # нічної архівації).
    if ($TaskType -eq 'Recovery' -or $TaskType -eq 'BackupCatchUp') {
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

function Get-BRAVOBackupCatchUpDecision {
    # Рішення boot-завдання BackupCatchUp (BRAVO_ARCHIV -CatchUpMissedBackup):
    # чи був пропущений останній щоденний слот Backup.DailyAt. Чиста функція
    # без I/O, щоб self-test перевіряв саме правило.
    #
    # Слот вважається виконаним, якщо остання COMPLETE-копія
    # (BRAVO_TASK_EXECUTION_STATE.json -> Backup) не старша за цей слот.
    # Відсутній запис = копії не було, тож копія робиться. Якщо до
    # наступного планового слоту лишилось не більше NextSlotGuardMinutes,
    # підхоплення не потрібне: копію зробить звичайний запуск.
    #
    # Межові випадки (детерміновані, закріплені self-test):
    #  - LastSuccess == початок слоту вважається виконаним слотом (-ge);
    #  - Now у перші SlotStartGraceMinutes хв. після слоту (включно з
    #    Now == DailyAt): Планувальник саме зараз запускає звичайний
    #    BRAVO_ARCHIV, тож підхоплення поступається йому (інакше, виграв
    #    би підхоплення lock, звичайний прогін після нього зробив би другу
    #    копію); якщо звичайний прогін завершиться без COMPLETE, наступний
    #    boot-запуск або наступний слот це покриє;
    #  - до наступного слоту рівно NextSlotGuardMinutes хв. = пропуск (-le);
    #  - LastSuccess відсутній ($null; стану немає або він пошкоджений) =
    #    копії не було, отже копія робиться: хост без жодної COMPLETE-копії
    #    не повинен лишатися без неї.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][datetime]$Now,
        [Parameter(Mandatory = $true)][string]$DailyAt,
        [AllowNull()]$LastSuccess,
        [int]$NextSlotGuardMinutes = 60,
        [int]$SlotStartGraceMinutes = 2
    )

    $slotTime = [TimeSpan]::Zero
    if (-not [TimeSpan]::TryParse($DailyAt, [ref]$slotTime) -or
        $slotTime -lt [TimeSpan]::Zero -or $slotTime.TotalHours -ge 24) {
        throw "Backup.DailyAt повинен мати формат HH:mm: '$DailyAt'"
    }
    $previousSlot = $Now.Date.Add($slotTime)
    if ($previousSlot -gt $Now) {
        $previousSlot = $previousSlot.AddDays(-1)
    }
    $nextSlot = $previousSlot.AddDays(1)
    $lastSuccessTime = $null
    if ($LastSuccess -is [datetime]) {
        $lastSuccessTime = [datetime]$LastSuccess
    }
    $lastSuccessText = if ($null -ne $lastSuccessTime) {
        $lastSuccessTime.ToString('dd.MM.yyyy HH:mm')
    } else {
        'немає даних'
    }

    $run = $false
    if ($null -ne $lastSuccessTime -and $lastSuccessTime -ge $previousSlot) {
        $reason = "копія за слот $($previousSlot.ToString('dd.MM.yyyy HH:mm')) уже є (остання успішна $lastSuccessText)"
    } elseif (($Now - $previousSlot).TotalMinutes -lt $SlotStartGraceMinutes) {
        $reason = "плановий запуск $($previousSlot.ToString('dd.MM.yyyy HH:mm')) саме стартує, копію зробить він"
    } elseif (($nextSlot - $Now).TotalMinutes -le $NextSlotGuardMinutes) {
        $reason = "до планового запуску $($nextSlot.ToString('dd.MM.yyyy HH:mm')) не більше $NextSlotGuardMinutes хв, копію зробить він"
    } else {
        $run = $true
        $reason = "пропущено слот $($previousSlot.ToString('dd.MM.yyyy HH:mm')) (остання успішна копія: $lastSuccessText)"
    }

    return [pscustomobject]@{
        Run = $run
        PreviousSlot = $previousSlot
        NextSlot = $nextSlot
        LastSuccess = $lastSuccessTime
        Reason = $reason
    }
}

# ---------------------------------------------------------------------------
# Атомарний запис текстового файлу машинного стану (%ProgramData%\BRAVO\State).
#
# Стан завдань (BRAVO_RESTORE_STATE.json, BRAVO_TASK_EXECUTION_STATE.json)
# раніше перезаписувався на місці через [IO.File]::WriteAllText: файл
# обрізався до нуля ДО запису нових байтів, тож kill/втрата живлення/збій
# диска посеред запису лишали порожній або обірваний JSON — а пошкоджений
# стан далі трактується як «стану немає» (тижнева квота реставрації,
# дата останнього запуску). Тут нові байти спершу повністю пишуться в
# тимчасовий файл у ТОМУ Ж каталозі (той самий том — інакше Replace/Move не
# атомарні), і лише потім підміняють цільовий файл ([IO.File]::Replace,
# або ::Move, коли цілі ще немає). Будь-який збій до підміни лишає
# попередній файл недоторканим, а тимчасовий — прибирається.
#
# Кодування — UTF-8 БЕЗ BOM, як у всіх попередніх записувачів стану.
# Семантика читання та поведінка при пошкодженому файлі — справа викликача;
# ця функція їх не змінює.
#
# Той самий патерн уже повторено локально в кількох записувачах
# (Write-BRAVOServiceQuiescenceState нижче, BRAVO.Status, BRAVO.Operations,
# BRAVO.Discovery тощо); їхня міграція на цю функцію — окрема задача.
# ---------------------------------------------------------------------------

function Write-BRAVOStateTemporaryText {
    # Приватний крок запису байтів у тимчасовий файл. Винесено окремо, щоб
    # self-test міг змоделювати збій посеред запису (обірваний тимчасовий
    # файл + виняток) і перевірити, що цільовий файл лишився попереднім.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Write-BRAVOStateFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $directory = [IO.Path]::GetDirectoryName($Path)
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw "Write-BRAVOStateFileAtomic: шлях має містити каталог: $Path"
    }
    if (-not [IO.Directory]::Exists($directory)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }

    $leafName = [IO.Path]::GetFileName($Path)
    $uniqueSuffix = [guid]::NewGuid().ToString('N')
    $temporaryPath = [IO.Path]::Combine($directory, ('.{0}_{1}.tmp' -f $leafName, $uniqueSuffix))
    $backupPath = [IO.Path]::Combine($directory, ('.{0}_{1}.bak' -f $leafName, $uniqueSuffix))
    $replaced = $false
    try {
        Write-BRAVOStateTemporaryText -Path $temporaryPath -Text $Text
        if ([IO.File]::Exists($Path)) {
            # .NET Framework відхиляє null-backup у Replace — тому явний шлях.
            [IO.File]::Replace($temporaryPath, $Path, $backupPath)
            $replaced = $true
        } else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
        if ($replaced -and [IO.File]::Exists($backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
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
# restartSuppressed за власником:
#   - Maintenance пише маркер БЕЗ suppression: його робота між stop/start
#     не змінює live filesystem, автостарт після жорсткого kill безпечний;
#   - DataRestore пише маркер ОДРАЗУ suppressed: жорсткий kill посеред
#     деструктивної фази лишає live filesystem у невизначеному стані, і
#     автостарт служб поверх нього неприпустимий — watchdog лише алертить
#     CRITICAL про потребу ручного відновлення (restart-intent продубльовано
#     в лог-файлі DataRestore).
#
# Clear/Suppress захищені від чужого маркера (перетин власників, напр.
# DataRestore під час планового Maintenance): діють лише на маркер,
# записаний ЦИМ процесом, або (Clear -ExpectedState, watchdog) на рівно
# той маркер, який був прочитаний перед діями.
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

function Protect-BRAVOMachineStateRoot {
    # Захист каталогу машинного стану %ProgramData%\BRAVO\State (review F4).
    #
    # Загроза: quiescence-маркер став ВХОДОМ для привілейованої дії
    # (SYSTEM-Health виконує Start-Service за його вмістом), а стандартні
    # успадковані ACL ProgramData дозволяють звичайним користувачам
    # створювати файли у підкаталогах — локальний непривілейований
    # користувач міг би підкинути маркер. Той самий каталог тримає
    # VSS-ownership і BAZA-стан, тож зміцнення діє на весь State-корінь.
    #
    # Apply-режим (типовий, потребує адмін-прав): створює каталог за
    # потреби, вимикає успадкування і лишає FullControl лише для SYSTEM
    # та BUILTIN\Administrators (SID-и, не локалізовані імена — той самий
    # підхід, що Set-PrivateDirectoryAcl у BRAVO_CREDENTIALS_SETUP).
    # -CheckOnly: лише читає поточні ACL і звітує невідповідності, нічого
    # не змінюючи (для ValidateOnly/неелевованих прогонів SETUP).
    #
    # Compliant оцінює стан ДО застосування: успадкування вимкнено і немає
    # Allow-ACE для широких принципалів (Users/Authenticated Users/
    # Everyone/INTERACTIVE/CREATOR OWNER) — перевіряється саме вектор
    # «непривілейований запис», а не повна еквівалентність еталону.
    [CmdletBinding()]
    param(
        [switch]$CheckOnly,
        # Для self-test: захист довільного каталогу без дотику до
        # реального %ProgramData%. У production не передається.
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Split-Path -Path (Get-BRAVOServiceQuiescenceStatePath) -Parent
    }

    $broadPrincipalSids = @(
        (New-Object Security.Principal.SecurityIdentifier('S-1-1-0')),   # Everyone
        (New-Object Security.Principal.SecurityIdentifier('S-1-5-11')),  # Authenticated Users
        (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')), # BUILTIN\Users
        (New-Object Security.Principal.SecurityIdentifier('S-1-5-4')),   # INTERACTIVE
        (New-Object Security.Principal.SecurityIdentifier('S-1-3-0'))    # CREATOR OWNER
    )

    $issues = @()
    $directoryExists = [IO.Directory]::Exists($Path)
    if (-not $directoryExists) {
        $issues += "каталог ще не існує: $Path (буде створений з успадкованими ACL ProgramData)"
    } else {
        $currentAcl = Get-Acl -LiteralPath $Path
        if (-not $currentAcl.AreAccessRulesProtected) {
            $issues += 'успадкування ACL не вимкнено — діють стандартні права ProgramData'
        }
        foreach ($accessRule in @($currentAcl.Access)) {
            if ($accessRule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            $ruleSid = $null
            try {
                $ruleSid = $accessRule.IdentityReference.Translate([Security.Principal.SecurityIdentifier])
            } catch {
                # Неперекладний принципал (осиротілий SID) — не широкий.
                continue
            }
            foreach ($broadSid in $broadPrincipalSids) {
                if ($ruleSid -eq $broadSid) {
                    $issues += "Allow-ACE для широкого принципала: $($accessRule.IdentityReference) ($($accessRule.FileSystemRights))"
                    break
                }
            }
        }
    }
    $compliantBeforeApply = ($issues.Count -eq 0)

    $applied = $false
    if (-not $CheckOnly -and -not $compliantBeforeApply) {
        if (-not $directoryExists) {
            [void][IO.Directory]::CreateDirectory($Path)
        }
        $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
        $administratorsSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $protectedAcl = New-Object Security.AccessControl.DirectorySecurity
        $protectedAcl.SetAccessRuleProtection($true, $false)
        foreach ($allowedSid in @($systemSid, $administratorsSid)) {
            $protectedAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                $allowedSid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow
            )))
        }
        Set-Acl -LiteralPath $Path -AclObject $protectedAcl
        $applied = $true
    }

    return [pscustomobject]@{
        Path = $Path
        Compliant = $compliantBeforeApply
        Applied = $applied
        Issues = @($issues)
    }
}

function Get-BRAVOCurrentProcessStartTimeText {
    # Module-qualified: захист від затінення Get-Process функцією-стабом
    # у сесії викликача (реальний випадок у self-test).
    [CmdletBinding()]
    param()

    try {
        return (Microsoft.PowerShell.Management\Get-Process -Id $PID -ErrorAction Stop).StartTime.ToString('o')
    } catch {
        return $null
    }
}

function Test-BRAVOServiceQuiescenceStateOwnedByCurrentProcess {
    # Предикат «поточний маркер записаний САМЕ цим процесом»: pid збігається
    # з $PID і processStartTime (якщо обидва відомі) — з моїм. Використовують
    # Clear/Suppress, щоб при перетині власників (другий власник перезаписав
    # маркер першого) finally першого не знищив чужий маркер.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State
    )

    if (($State.pid -as [int]) -ne $PID) { return $false }
    $currentStartTimeText = Get-BRAVOCurrentProcessStartTimeText
    if ([string]::IsNullOrWhiteSpace([string]$State.processStartTime) -or
        [string]::IsNullOrWhiteSpace([string]$currentStartTimeText)) {
        # startTime невідомий з будь-якого боку — залишається збіг PID
        # (консервативно вважаємо власним: у межах життя одного PID на
        # одному хості це і є той самий процес).
        return $true
    }
    return ([string]$State.processStartTime -eq [string]$currentStartTimeText)
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
        [switch]$RestartSuppressed,
        # #297: точні початкові start type служб, які власник тимчасово
        # переводить у Disabled на час restore (@{ Name; StartMode }).
        # Пишеться ДО зміни (write-ahead) — див. Suspend-BRAVOServiceAutostart.
        [object[]]$StartTypeSnapshot = @(),
        # #297: поведінка, коли на диску вже є ЧУЖИЙ маркер з непорожнім
        # startTypeSnapshot (попередній прогін загинув/його служби свідомо
        # утримано Disabled): його знімок — єдиний запис справжніх початкових
        # типів. Без цього прапорця запис ВІДХИЛЯЄТЬСЯ (throw, fail-closed:
        # власник-Maintenance абортує зупинку служб гучною критичною
        # помилкою, а маркер лишається недоторканим — перезапис загубив би
        # типи, і служби лишились би Disabled назавжди, а наступні прогони
        # прийняли б їх за вимкнені оператором). З прапорцем (DataRestore:
        # його робота — саме ручне відновлення й блокувати її не можна)
        # записи чужого знімка переносяться в новий маркер; для тієї самої
        # служби чинний старий запис (він містить справжній оригінал).
        [switch]$PreserveForeignStartTypeSnapshot
    )

    $statePath = Get-BRAVOServiceQuiescenceStatePath
    $existingState = $null
    try { $existingState = Read-BRAVOServiceQuiescenceState } catch { $existingState = $null }
    if ($null -ne $existingState -and
        @($existingState.startTypeSnapshot).Count -gt 0 -and
        -not (Test-BRAVOServiceQuiescenceStateOwnedByCurrentProcess -State $existingState)) {
        if (-not $PreserveForeignStartTypeSnapshot) {
            throw "Існуючий ownership-маркер ($($existingState.owner), PID $($existingState.pid)) містить знімок початкових типів запуску служб (#297) — він не перезаписується, щоб не втратити типи (потрібне відновлення: Health-watchdog або ручне, код 43)"
        }
        $mergedSnapshot = @()
        foreach ($oldEntry in @($existingState.startTypeSnapshot)) {
            $mergedSnapshot += [pscustomobject]@{ Name = [string]$oldEntry.Name; StartMode = [string]$oldEntry.StartMode }
        }
        foreach ($newEntry in @($StartTypeSnapshot)) {
            if (@($mergedSnapshot | Where-Object { $_.Name -ieq [string]$newEntry.Name }).Count -eq 0) {
                $mergedSnapshot += [pscustomobject]@{ Name = [string]$newEntry.Name; StartMode = [string]$newEntry.StartMode }
            }
        }
        $StartTypeSnapshot = @($mergedSnapshot)
    }
    $stateDirectory = Split-Path -Path $statePath -Parent
    if (-not [IO.Directory]::Exists($stateDirectory)) {
        [void][IO.Directory]::CreateDirectory($stateDirectory)
    }
    $state = [ordered]@{
        schemaVersion = 1
        owner = $Owner
        hostname = [Environment]::MachineName
        pid = $PID
        processStartTime = (Get-BRAVOCurrentProcessStartTimeText)
        createdAt = (Get-Date).ToString('o')
        logFile = [string]$LogFile
        restartSuppressed = [bool]$RestartSuppressed
        services = @($Services | ForEach-Object {
            [ordered]@{ Name = [string]$_.Name; RestartIntent = [bool]$_.RestartIntent }
        })
        startTypeSnapshot = @($StartTypeSnapshot | ForEach-Object {
            [ordered]@{ Name = [string]$_.Name; StartMode = [string]$_.StartMode }
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
    # незнайома schemaVersion, зіпсований JSON, відсутні обов'язкові поля) —
    # у всіх цих випадках watchdog НЕ діє (лише алертить про невалідний файл
    # сам викликач, якщо вважає за потрібне). Валідний чужий маркер не
    # «лікуємо» — це свідома fail-safe поведінка, як у VSS-ownership.
    #
    # Повнота полів перевіряється ТУТ (а не у watchdog): контракт функції —
    # «повернене не-null значення безпечно читати під Set-StrictMode».
    # Частково відредагований вручну маркер (валідний JSON + header, але без
    # pid/services) інакше валив би PropertyNotFoundException увесь
    # Health-прогін, тобто втрату моніторингу замість одного watchdog-кроку.
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
    foreach ($requiredPropertyName in @('pid', 'processStartTime', 'createdAt', 'logFile', 'restartSuppressed', 'services')) {
        if ($null -eq $state.PSObject.Properties[$requiredPropertyName]) { return $null }
    }
    if ($null -eq ($state.pid -as [int])) { return $null }
    foreach ($serviceEntry in @($state.services)) {
        if ($null -eq $serviceEntry -or
            $null -eq $serviceEntry.PSObject.Properties['Name'] -or
            $null -eq $serviceEntry.PSObject.Properties['RestartIntent']) {
            return $null
        }
    }
    # #297: startTypeSnapshot — НЕОБОВ'ЯЗКОВЕ поле (маркери старіших версій
    # його не мають). Нормалізуємо: після Read властивість завжди існує й
    # містить лише валідні записи (відомий StartMode). Зіпсований запис
    # знімка відкидається, а не робить увесь маркер невалідним — інакше
    # watchdog утратив би можливість стартувати служби.
    $validSnapshot = @()
    $snapshotProperty = $state.PSObject.Properties['startTypeSnapshot']
    if ($null -ne $snapshotProperty) {
        foreach ($snapshotEntry in @($snapshotProperty.Value)) {
            if ($null -ne $snapshotEntry -and
                $null -ne $snapshotEntry.PSObject.Properties['Name'] -and
                $null -ne $snapshotEntry.PSObject.Properties['StartMode'] -and
                -not [string]::IsNullOrWhiteSpace([string]$snapshotEntry.Name) -and
                [string]$snapshotEntry.StartMode -in @('Automatic', 'AutomaticDelayed', 'Manual')) {
                $validSnapshot += [pscustomobject]@{ Name = [string]$snapshotEntry.Name; StartMode = [string]$snapshotEntry.StartMode }
            }
        }
        $snapshotProperty.Value = @($validSnapshot)
    } else {
        Add-Member -InputObject $state -NotePropertyName 'startTypeSnapshot' -NotePropertyValue @() -Force
    }
    return $state
}

function Clear-BRAVOServiceQuiescenceState {
    # Ідемпотентне ЗАХИЩЕНЕ видалення (штатне завершення відновлення служб).
    # НІКОЛИ не видаляє чужий маркер:
    #   - без -ExpectedState (власник у finally): видаляє лише маркер,
    #     записаний ЦИМ процесом (pid+processStartTime);
    #   - з -ExpectedState (watchdog після старту служб): видаляє лише якщо
    #     поточний маркер — рівно той, що був прочитаний перед діями
    #     (owner+pid+createdAt); новий маркер живого власника не чіпається.
    # Наявний-але-невалідний файл (Read -> $null) теж не видаляється: для
    # watchdog він інертний, а «полагодити видаленням» міг би, наприклад,
    # маркер чужого hostname.
    # Повертає $true, якщо маркера більше немає (видалено або й не було);
    # $false — якщо видалення пропущено, бо маркер не власний/не очікуваний.
    [CmdletBinding()]
    param(
        [object]$ExpectedState
    )

    $statePath = Get-BRAVOServiceQuiescenceStatePath
    if (-not [IO.File]::Exists($statePath)) { return $true }
    $currentState = Read-BRAVOServiceQuiescenceState
    if ($null -eq $currentState) { return $false }
    if ($null -ne $ExpectedState) {
        $isSameMarker = ([string]$currentState.owner -eq [string]$ExpectedState.owner) -and
            (($currentState.pid -as [int]) -eq ($ExpectedState.pid -as [int])) -and
            ([string]$currentState.createdAt -eq [string]$ExpectedState.createdAt)
        if (-not $isSameMarker) { return $false }
    } elseif (-not (Test-BRAVOServiceQuiescenceStateOwnedByCurrentProcess -State $currentState)) {
        return $false
    }
    Remove-Item -LiteralPath $statePath -Force -ErrorAction Stop
    return $true
}

function Set-BRAVOServiceQuiescenceRestartSuppressed {
    # Для fail-closed гілки DataRestore (rollback неповний): служби НАВМИСНО
    # лишаються зупиненими, маркер зберігається як евіденс, але watchdog не
    # має права стартувати — лише алертити про потребу ручного втручання.
    # Діє ЛИШЕ на маркер, записаний цим процесом: перетин власників не
    # повинен дозволяти одному процесу suppress-нути чужий маркер.
    [CmdletBinding()]
    param()

    $state = Read-BRAVOServiceQuiescenceState
    if ($null -eq $state) { return $null }
    if (-not (Test-BRAVOServiceQuiescenceStateOwnedByCurrentProcess -State $state)) { return $null }
    $services = @($state.services | ForEach-Object {
        @{ Name = [string]$_.Name; RestartIntent = [bool]$_.RestartIntent }
    })
    return Write-BRAVOServiceQuiescenceState `
        -Owner ([string]$state.owner) `
        -Services $services `
        -LogFile ([string]$state.logFile) `
        -RestartSuppressed `
        -StartTypeSnapshot @($state.startTypeSnapshot)
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

function Get-BRAVOServiceDelayedAutoStart {
    # Get-Service.StartType показує лише 'Automatic' і не розрізняє
    # звичайний auto та Automatic (Delayed Start) — прапорець delayed
    # живе окремим значенням реєстру DelayedAutostart. $null = службу не
    # знайдено або значення відсутнє (для не-Automatic служб воно
    # нерелевантне).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ServiceName)

    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if (-not (Test-Path -LiteralPath $registryPath)) {
        return $null
    }
    $properties = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
    if ($null -eq $properties -or
        $null -eq ($properties.PSObject.Properties['DelayedAutostart'])) {
        return $false
    }
    return ([int]$properties.DelayedAutostart -eq 1)
}

function Get-BRAVOServiceStartMode {
    # Єдиний канонічний читач типу запуску служби Windows (#319).
    # ServiceController.StartType існує лише з .NET Framework 4.6.1, а
    # Windows PowerShell 5.1 може працювати на .NET 4.5.2+: під
    # Set-StrictMode -Version 2.0 пряме звернення до відсутньої властивості
    # кидає PropertyNotFoundStrict. Порядок джерел:
    #   1) StartType службового об'єкта (через PSObject.Properties) — має
    #      пріоритет, коли присутній і розпізнаний;
    #   2) -FallbackStartMode — значення Win32_Service.StartMode, яке
    #      викликач уже отримав (щоб не робити другий WMI-запит);
    #   3) WMI/CIM Win32_Service через Get-BRAVOWmiInstance (BRAVO.Compatibility),
    #      якщо не вказано -NoWmiQuery.
    # Значення нормалізується до Automatic/Manual/Disabled; WMI 'Auto' ->
    # Automatic. Delayed Start тут НЕ розрізняється (його читає окремо
    # Get-BRAVOServiceDelayedAutoStart з реєстру). Функція не кидає виняток:
    # якщо джерел немає або значення нерозпізнане, StartMode = 'Unknown', а
    # FailureReason пояснює чому.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Service,
        [string]$FallbackStartMode,
        [switch]$NoWmiQuery
    )

    $normalize = {
        param($Value)
        if ($null -eq $Value) { return $null }
        switch (([string]$Value).Trim().ToLowerInvariant()) {
            'automatic' { return 'Automatic' }
            'auto' { return 'Automatic' }
            'manual' { return 'Manual' }
            'disabled' { return 'Disabled' }
            default { return $null }
        }
    }

    $serviceName = ''
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Service) {
        $nameProperty = $Service.PSObject.Properties['Name']
        if ($null -ne $nameProperty -and $null -ne $nameProperty.Value) {
            $serviceName = [string]$nameProperty.Value
        }
    }
    $makeResult = {
        param([string]$Mode, [string]$Source)
        [pscustomobject]@{
            Name = $serviceName
            StartMode = $Mode
            Source = $Source
            FailureReason = if ($Mode -eq 'Unknown') { ($reasons -join '; ') } else { $null }
        }
    }

    if ($null -eq $Service) {
        [void]$reasons.Add('службовий об''єкт не передано')
        return (& $makeResult 'Unknown' 'None')
    }

    $startTypeProperty = $Service.PSObject.Properties['StartType']
    if ($null -eq $startTypeProperty) {
        [void]$reasons.Add('властивість StartType відсутня (.NET Framework < 4.6.1)')
    } else {
        $mode = & $normalize $startTypeProperty.Value
        if ($null -ne $mode) { return (& $makeResult $mode 'StartType') }
        [void]$reasons.Add("StartType порожній або нерозпізнаний: '$([string]$startTypeProperty.Value)'")
    }

    if (-not [string]::IsNullOrWhiteSpace($FallbackStartMode)) {
        $mode = & $normalize $FallbackStartMode
        if ($null -ne $mode) { return (& $makeResult $mode 'FallbackStartMode') }
        [void]$reasons.Add("FallbackStartMode нерозпізнаний: '$FallbackStartMode'")
    }

    if ($NoWmiQuery) {
        [void]$reasons.Add('WMI-запит вимкнено (-NoWmiQuery)')
    } elseif ([string]::IsNullOrWhiteSpace($serviceName)) {
        [void]$reasons.Add('ім''я служби невідоме — WMI-запит неможливий')
    } elseif ($null -eq (Get-Command -Name 'Get-BRAVOWmiInstance' -ErrorAction SilentlyContinue)) {
        [void]$reasons.Add('Get-BRAVOWmiInstance (BRAVO.Compatibility) недоступна')
    } else {
        try {
            $escapedName = $serviceName.Replace("'", "''")
            $serviceInfo = @(Get-BRAVOWmiInstance -ClassName Win32_Service -Filter "Name = '$escapedName'") |
                Select-Object -First 1
            $startModeProperty = if ($null -ne $serviceInfo) { $serviceInfo.PSObject.Properties['StartMode'] } else { $null }
            if ($null -eq $startModeProperty) {
                [void]$reasons.Add('WMI не повернув Win32_Service.StartMode')
            } else {
                $mode = & $normalize $startModeProperty.Value
                if ($null -ne $mode) { return (& $makeResult $mode 'WMI') }
                [void]$reasons.Add("WMI StartMode нерозпізнаний: '$([string]$startModeProperty.Value)'")
            }
        } catch {
            [void]$reasons.Add("WMI-запит завершився помилкою: $($_.Exception.Message)")
        }
    }

    return (& $makeResult 'Unknown' 'None')
}

function Get-BRAVOManagedServiceCondition {
    # Єдина класифікація стану керованої служби BRAVO (#314, FR-1). Лише
    # читає, нічого не змінює. Condition:
    #   NotInstalled - службу не знайдено;
    #   Disabled     - тип запуску Disabled, виставлений НЕ BRAVO (рішення
    #                  оператора: «навмисно вимкнено»); має пріоритет над
    #                  станом служби;
    #   OwnedByBravo - службою зараз розпоряджається BRAVO: вона в чинному
    #                  ownership-маркері (зупинена Maintenance/DataRestore)
    #                  або тимчасово переведена в Disabled зі знімком типу в
    #                  маркері (#297/#329, HeldByBravo = $true). Такий
    #                  Disabled НЕ є рішенням оператора: інакше осиротілий
    #                  знімок після аварії назавжди «вимкнув» би службу;
    #   Running      - працює;
    #   Pending      - StartPending/StopPending/ContinuePending/PausePending;
    #   Failed       - не працює, не Disabled і не під маркером. Automatic чи
    #                  Manual на рішення не впливає (рішення власника #314).
    # Маркер мертвого власника теж дає OwnedByBravo: його відпрацьовує
    # Health-watchdog, а не загальна логіка «впалої» служби.
    #
    # Тестові шви / економія запитів для викликача, що перевіряє кілька служб:
    #   -Service         - уже знайдений службовий об'єкт (BravoWeb
    #                      резолвиться і за DisplayName);
    #   -ServiceInfo     - рядок Win32_Service, уже прочитаний викликачем
    #                      (StartMode як fallback, ExitCode);
    #   -QuiescenceState - уже прочитаний маркер (явний $null = маркера
    #                      немає);
    #   -NoWmiQuery      - не робити власного WMI-запиту.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Service,
        [AllowNull()][object]$ServiceInfo,
        [AllowNull()][object]$QuiescenceState,
        [switch]$NoWmiQuery
    )

    $result = [pscustomobject]@{
        Name = $Name
        Exists = $false
        StartMode = $null
        StartModeSource = $null
        Status = $null
        ExitCode = $null
        ServiceSpecificExitCode = $null
        Condition = 'NotInstalled'
        HeldByBravo = $false
        OriginalStartMode = $null
        MarkerOwner = $null
    }

    if (-not $PSBoundParameters.ContainsKey('Service')) {
        $Service = @(Get-Service -Name $Name -ErrorAction SilentlyContinue) | Select-Object -First 1
    }
    if ($null -eq $Service) { return $result }

    $nameProperty = $Service.PSObject.Properties['Name']
    if ($null -ne $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
        $result.Name = [string]$nameProperty.Value
    }
    if ($null -ne $Service.PSObject.Methods['Refresh']) {
        # Refresh кидає виняток, коли службу вже видалено з SCM.
        try { $Service.Refresh() } catch { return $result }
    }
    $result.Exists = $true
    $result.Status = [string]$Service.Status

    if (-not $PSBoundParameters.ContainsKey('ServiceInfo')) {
        $ServiceInfo = $null
        if (-not $NoWmiQuery -and $null -ne (Get-Command -Name 'Get-BRAVOWmiInstance' -ErrorAction SilentlyContinue)) {
            try {
                $escapedName = $result.Name.Replace("'", "''")
                $ServiceInfo = @(Get-BRAVOWmiInstance -ClassName Win32_Service -Filter "Name = '$escapedName'") |
                    Select-Object -First 1
            } catch {
                $ServiceInfo = $null
            }
        }
    }
    $fallbackStartMode = $null
    if ($null -ne $ServiceInfo) {
        foreach ($infoPropertyName in @('StartMode', 'ExitCode', 'ServiceSpecificExitCode')) {
            $infoProperty = $ServiceInfo.PSObject.Properties[$infoPropertyName]
            if ($null -eq $infoProperty -or $null -eq $infoProperty.Value) { continue }
            switch ($infoPropertyName) {
                'StartMode' { $fallbackStartMode = [string]$infoProperty.Value }
                'ExitCode' { $result.ExitCode = $infoProperty.Value -as [long] }
                'ServiceSpecificExitCode' { $result.ServiceSpecificExitCode = $infoProperty.Value -as [long] }
            }
        }
    }
    # WMI тут уже прочитано (або свідомо пропущено) — другого запиту немає.
    $startModeResult = Get-BRAVOServiceStartMode -Service $Service -FallbackStartMode $fallbackStartMode -NoWmiQuery
    $result.StartMode = [string]$startModeResult.StartMode
    $result.StartModeSource = [string]$startModeResult.Source

    if (-not $PSBoundParameters.ContainsKey('QuiescenceState')) {
        try { $QuiescenceState = Read-BRAVOServiceQuiescenceState } catch { $QuiescenceState = $null }
    }
    $markedForRestart = $false
    $heldSnapshotEntry = $null
    if ($null -ne $QuiescenceState) {
        $markerServicesProperty = $QuiescenceState.PSObject.Properties['services']
        if ($null -ne $markerServicesProperty) {
            $markedForRestart = @(@($markerServicesProperty.Value) | Where-Object {
                    $null -ne $_ -and [string]$_.Name -ieq $result.Name
                }).Count -gt 0
        }
        $markerSnapshotProperty = $QuiescenceState.PSObject.Properties['startTypeSnapshot']
        if ($null -ne $markerSnapshotProperty) {
            $heldSnapshotEntry = @(@($markerSnapshotProperty.Value) | Where-Object {
                    $null -ne $_ -and [string]$_.Name -ieq $result.Name
                }) | Select-Object -First 1
        }
        if ($markedForRestart -or $null -ne $heldSnapshotEntry) {
            $ownerProperty = $QuiescenceState.PSObject.Properties['owner']
            if ($null -ne $ownerProperty) { $result.MarkerOwner = [string]$ownerProperty.Value }
        }
    }

    if ($result.StartMode -eq 'Disabled') {
        if ($null -ne $heldSnapshotEntry) {
            $result.Condition = 'OwnedByBravo'
            $result.HeldByBravo = $true
            $result.OriginalStartMode = [string]$heldSnapshotEntry.StartMode
        } else {
            $result.Condition = 'Disabled'
        }
        return $result
    }
    if ($result.Status -eq 'Running') {
        $result.Condition = 'Running'
    } elseif ($result.Status -in @('StartPending', 'StopPending', 'ContinuePending', 'PausePending')) {
        $result.Condition = 'Pending'
    } elseif ($markedForRestart) {
        $result.Condition = 'OwnedByBravo'
    } else {
        $result.Condition = 'Failed'
    }
    return $result
}

function Set-BRAVOBootRestoreServiceStartType {
    # Канонічне (єдине в комплекті) місце, де BRAVO змінює start type
    # служб Windows. Використовується ЛИШЕ інсталятором Планувальника для
    # профілю Restore.BootRestoreMode:
    #
    #   HoldServices: керовані служби -> Automatic (Delayed Start), щоб
    #     Recovery-boot-завдання (delay 0) стартувало РАНІШЕ за них і
    #     встигло виконати пропущену реставрацію до входу клієнтів.
    #     Manual/Disabled НЕ чіпаються (site-рішення; вони й так не
    #     стартують самі — «hold» виконується природно).
    #
    #   None: повернути звичайний Automatic ЛИШЕ службам, які зараз
    #     Automatic (Delayed Start) — тобто відкотити виключно власну
    #     попередню зміну; Manual/Disabled знову не чіпаються.
    #
    # -ValidateOnly: тільки читання/звіт, жодних змін (режим VALIDATE
    # інсталятора). Збій зміни не throw-ить — повертається в записі
    # результату, рішення про фатальність ухвалює викликач.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$ServiceNames,
        [Parameter(Mandatory = $true)][bool]$HoldServices,
        [switch]$ValidateOnly
    )

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($serviceName in $ServiceNames) {
        if ([string]::IsNullOrWhiteSpace($serviceName)) { continue }
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            [void]$results.Add([pscustomobject]@{
                Name = $serviceName; Found = $false; StartType = $null
                DelayedAutoStart = $null; Action = 'NotFound'
                Success = $true; Details = 'службу не знайдено — пропущено'
            })
            continue
        }
        # StartType (.NET < 4.6.1) може бути відсутній: тип запуску читає
        # канонічний Get-BRAVOServiceStartMode (WMI-fallback). Невідомий тип
        # запуску НЕ змінюємо (жодних припущень про стан служби).
        $startModeResult = Get-BRAVOServiceStartMode -Service $service
        $startType = [string]$startModeResult.StartMode
        $delayed = Get-BRAVOServiceDelayedAutoStart -ServiceName $serviceName
        $action = 'None'
        $targetArgument = $null
        $success = $true
        $details = $null
        if ($startType -eq 'Unknown') {
            # Ні StartType, ні WMI не дали типу запуску: службу не чіпаємо.
            # У HoldServices це ламає гарантію «клієнти не зайдуть до
            # реставрації», тому там — збій (рішення за викликачем); у None
            # власного delayed-стану відкотити нема чого.
            $action = 'SkippedUnknownStartType'
            $details = "тип запуску невідомий: $($startModeResult.FailureReason)"
            if ($HoldServices) { $success = $false }
        } elseif ($startType -eq 'Automatic') {
            if ($HoldServices -and -not $delayed) {
                $action = 'SetDelayedAuto'; $targetArgument = 'delayed-auto'
            } elseif (-not $HoldServices -and $delayed) {
                $action = 'SetAuto'; $targetArgument = 'auto'
            }
        } elseif ($HoldServices) {
            $action = 'SkippedNotAutomatic'
        }
        if ($null -ne $targetArgument -and -not $ValidateOnly) {
            # sc.exe вимагає пробіл ПІСЛЯ 'start=' — це синтаксис утиліти.
            & "$env:SystemRoot\System32\sc.exe" config $serviceName start= $targetArgument | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $success = $false
                $details = "sc config start= $targetArgument завершився з кодом $LASTEXITCODE"
            }
        }
        [void]$results.Add([pscustomobject]@{
            Name = $serviceName; Found = $true; StartType = $startType
            DelayedAutoStart = $delayed; Action = $action
            Success = $success; Details = $details
        })
    }
    return ,$results.ToArray()
}

# ---------------------------------------------------------------------------
# Тимчасове утримання служб від автостарту на час restore (#297).
#
# Проблема: boot-recovery профіль (HoldServices) ставить служби в Automatic
# (Delayed Start); SCM запускає їх ~2 хв після завантаження, тобто посеред
# багатохвилинного before-archive/bravocmd. Так само «restart on failure» чи
# сторонній Start-Service/залежна служба можуть підняти BRAVO/exchangAPI/Web
# усередині вікна реставрації. Зупинка служб сама по собі цього не
# запобігає — вона лише стан у момент знімка (TOCTOU).
#
# Рішення (транзакція зі write-ahead у ТОМУ Ж ownership-маркері, а не
# паралельний механізм):
#   1. знімок ТОЧНОГО початкового start type (Automatic / AutomaticDelayed /
#      Manual) кожної керованої служби, яка НЕ Disabled — Disabled служби
#      у знімок не потрапляють і НІКОЛИ не змінюються/не стартуються;
#   2. знімок записується в маркер (startTypeSnapshot) ДО будь-якої зміни;
#   3. служби переводяться в Disabled (на відміну від Manual, Disabled
#      блокує ВСІ запуски: SCM autostart, recovery actions, Start-Service,
#      автостарт залежностей);
#   4. finally власника повертає типи зі знімка ПЕРЕД стартом служб;
#   5. аварійний вихід (kill/reboot): наступний Maintenance/Recovery
#      (Repair-BRAVOOrphanedServiceStartTypes) та Health-watchdog
#      відновлюють типи з маркера мертвого власника.
# Відновлення торкається ЛИШЕ служби, що зараз Disabled (наша тимчасова
# зміна); якщо оператор уже сам змінив тип — його рішення не перезаписується.
# Виняток: маркер із restartSuppressed (модель у невизначеному стані) —
# служби свідомо ЛИШАЮТЬСЯ Disabled до ручного відновлення (код 43), інакше
# SCM підняв би їх на напіввідновленій моделі при наступному boot.
# ---------------------------------------------------------------------------

function Get-BRAVOServiceRegistryStartMode {
    # Точний SCM start type (вкл. AutomaticDelayed) з реєстру — для знімка
    # утримання #297. Для загальної класифікації start type див.
    # Get-BRAVOServiceStartMode (інший контракт).
    # Канонічне значення start type: Automatic | AutomaticDelayed | Manual |
    # Disabled | Other (boot/system/невідоме) | $null (службу не знайдено).
    # Читається з реєстру (Start + DelayedAutostart), а не з
    # ServiceController.StartType: не залежить від версії .NET і чесно
    # розрізняє Delayed Start. Єдине місце читання (тестовий шов).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ServiceName)

    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if (-not (Test-Path -LiteralPath $registryPath)) { return $null }
    $properties = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
    if ($null -eq $properties -or $null -eq $properties.PSObject.Properties['Start']) { return $null }
    switch ([int]$properties.Start) {
        2 {
            if ((Get-BRAVOServiceDelayedAutoStart -ServiceName $ServiceName) -eq $true) { return 'AutomaticDelayed' }
            return 'Automatic'
        }
        3 { return 'Manual' }
        4 { return 'Disabled' }
        default { return 'Other' }
    }
}

function Set-BRAVOServiceStartMode {
    # Єдиний шов запису start type (sc.exe; тестовий шов). $true = успіх.
    # sc.exe вимагає пробіл ПІСЛЯ 'start=' — це синтаксис утиліти.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][ValidateSet('Automatic', 'AutomaticDelayed', 'Manual', 'Disabled')][string]$StartMode
    )

    $scArgument = switch ($StartMode) {
        'Automatic'        { 'auto' }
        'AutomaticDelayed' { 'delayed-auto' }
        'Manual'           { 'demand' }
        'Disabled'         { 'disabled' }
    }
    & "$env:SystemRoot\System32\sc.exe" config $ServiceName start= $scArgument | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function New-BRAVOServiceStartTypeSnapshot {
    # Знімок точних початкових start type для служб, які МОЖНА тимчасово
    # утримувати: існують і є Automatic/AutomaticDelayed/Manual. Disabled
    # (рішення оператора), Other та відсутні служби — поза знімком, тобто
    # ніколи не змінюються й не відновлюються.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ServiceNames)

    $snapshot = New-Object System.Collections.Generic.List[object]
    foreach ($serviceName in @($ServiceNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        $startMode = Get-BRAVOServiceRegistryStartMode -ServiceName $serviceName
        if ($startMode -in @('Automatic', 'AutomaticDelayed', 'Manual')) {
            [void]$snapshot.Add(@{ Name = [string]$serviceName; StartMode = [string]$startMode })
        }
    }
    return $snapshot.ToArray()
}

function Suspend-BRAVOServiceAutostart {
    # Застосовує Disabled до служб зі знімка (знімок УЖЕ записано в маркер).
    # Не кидає виняток: повертає Applied/Failed — рішення про фатальність
    # (restore fail-closed) ухвалює викликач. Служба, що вже не в
    # початковому стані зі знімка (напр. оператор її вимкнув), не чіпається.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Snapshot)

    $applied = @()
    $failed = @()
    foreach ($entry in @($Snapshot)) {
        $name = [string]$entry.Name
        try {
            $currentMode = Get-BRAVOServiceRegistryStartMode -ServiceName $name
            if ($currentMode -eq 'Disabled') { $applied += $name; continue }
            if ($currentMode -ne [string]$entry.StartMode) {
                $failed += "${name}: тип запуску змінився після знімка ($currentMode замість $($entry.StartMode))"
                continue
            }
            if (Set-BRAVOServiceStartMode -ServiceName $name -StartMode 'Disabled') {
                $applied += $name
            } else {
                $failed += "${name}: sc config start= disabled не вдався"
            }
        } catch {
            $failed += "${name}: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ Applied = @($applied); Failed = @($failed) }
}

function Restore-BRAVOServiceStartTypeSnapshot {
    # Повертає start type зі знімка. Ідемпотентна й безпечна до чужих змін:
    #   - поточний тип Disabled  -> наша тимчасова зміна -> повертаємо;
    #   - поточний == початковий -> нічого (напр. збій між записом знімка й
    #                               застосуванням Disabled);
    #   - будь-який інший        -> оператор змінив сам -> НЕ чіпаємо.
    # -AllowedServiceNames: службу поза канонічним набором (стороннє
    # редагування маркера) не чіпаємо — Failed із поясненням.
    # Не кидає виняток; Failed != порожній => викликач лишає маркер.
    #
    # ОБМЕЖЕННЯ (свідоме, не виправляється тут): функція не відрізняє
    # тимчасовий Disabled від Disabled, який оператор виставив САМ уже ПІСЛЯ
    # аварії — обидва виглядають як «зараз Disabled». Тож якщо оператор
    # вимкнув службу між аварією й самовідновленням, початковий тип буде
    # повернено. Це свідомий компроміс: служба, що лишилась би Disabled через
    # аварію, гірша за повернення її початкового типу; про відновлення
    # гучно повідомляється (WARNING/Slack), оператор бачить, що саме змінено.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Snapshot,
        [string[]]$AllowedServiceNames
    )

    $restored = @()
    $unchanged = @()
    $foreign = @()
    $failed = @()
    foreach ($entry in @($Snapshot)) {
        $name = [string]$entry.Name
        $originalMode = [string]$entry.StartMode
        try {
            if ($PSBoundParameters.ContainsKey('AllowedServiceNames') -and
                @($AllowedServiceNames | Where-Object { $_ -ieq $name }).Count -eq 0) {
                $failed += "${name}: поза керованим набором служб — зміну start type заборонено (можливе стороннє редагування маркера)"
                continue
            }
            $currentMode = Get-BRAVOServiceRegistryStartMode -ServiceName $name
            if ($null -eq $currentMode) { $unchanged += $name; continue }
            if ($currentMode -eq $originalMode) { $unchanged += $name; continue }
            if ($currentMode -ne 'Disabled') {
                $foreign += "${name}: $currentMode (початковий $originalMode)"
                continue
            }
            if (-not (Set-BRAVOServiceStartMode -ServiceName $name -StartMode $originalMode)) {
                $failed += "${name}: не вдалося повернути $originalMode"
                continue
            }
            $verifiedMode = Get-BRAVOServiceRegistryStartMode -ServiceName $name
            if ($verifiedMode -ne $originalMode) {
                $failed += "${name}: після відновлення тип $verifiedMode замість $originalMode"
                continue
            }
            $restored += "${name}=$originalMode"
        } catch {
            $failed += "${name}: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{
        Restored = @($restored); Unchanged = @($unchanged); Foreign = @($foreign); Failed = @($failed)
    }
}

function Repair-BRAVOOrphanedServiceStartTypes {
    # Крок самовідновлення на старті Maintenance/Recovery (до читання
    # start type керованих служб!). Маркер мертвого власника з непорожнім
    # startTypeSnapshot => попередній прогін загинув у вікні утримання:
    #   Status = 'NoMarker'/'NoSnapshot'/'OwnerAlive' — нічого не робимо;
    #   'HeldSuppressed' — маркер restartSuppressed (модель невизначена):
    #       служби свідомо лишаються Disabled, потрібне ручне відновлення;
    #   'Repaired' — типи повернуто, знімок у маркері очищено (маркер, pid,
    #       createdAt збережено: Health-watchdog і далі стартує служби);
    #   'RepairFailed' — частина типів не повернута, маркер лишається.
    # Не кидає виняток (стартовий крок не має валити Maintenance).
    [CmdletBinding()]
    param([string[]]$AllowedServiceNames)

    $result = [pscustomobject]@{
        Status = 'NoMarker'; Owner = $null; Snapshot = @(); Restored = @(); Failed = @(); Foreign = @()
    }
    try {
        $state = Read-BRAVOServiceQuiescenceState
        if ($null -eq $state) { return $result }
        $result.Owner = [string]$state.owner
        $snapshot = @($state.startTypeSnapshot)
        if ($snapshot.Count -eq 0) { $result.Status = 'NoSnapshot'; return $result }
        $result.Snapshot = @($snapshot)
        if (Test-BRAVOProcessAlive -ProcessId ([int]$state.pid) -ProcessStartTime ([string]$state.processStartTime)) {
            $result.Status = 'OwnerAlive'; return $result
        }
        if ([bool]$state.restartSuppressed) { $result.Status = 'HeldSuppressed'; return $result }

        $restoreArguments = @{ Snapshot = $snapshot }
        if ($null -ne $AllowedServiceNames) { $restoreArguments['AllowedServiceNames'] = $AllowedServiceNames }
        $restoreResult = Restore-BRAVOServiceStartTypeSnapshot @restoreArguments
        $result.Restored = @($restoreResult.Restored)
        $result.Foreign = @($restoreResult.Foreign)
        $result.Failed = @($restoreResult.Failed)
        if ($result.Failed.Count -gt 0) { $result.Status = 'RepairFailed'; return $result }

        # Очищаємо знімок, зберігаючи решту маркера дослівно (owner/pid/
        # createdAt — за ними Health-watchdog і TOCTOU-guard).
        $statePath = Get-BRAVOServiceQuiescenceStatePath
        $raw = [IO.File]::ReadAllText($statePath, (New-Object Text.UTF8Encoding($false)))
        # Точкова заміна тексту знімка (а не ConvertFrom/To-Json круговорот):
        # решта маркера лишається байт-у-байт, зокрема формат createdAt.
        $clearedRaw = [regex]::Replace($raw, '(?s)("startTypeSnapshot"\s*:\s*)\[.*?\]', '$1[]', 1)
        if ($clearedRaw -eq $raw) {
            $rawState = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $rawState.PSObject.Properties['startTypeSnapshot']) {
                $rawState.startTypeSnapshot = @()
            }
            $clearedRaw = $rawState | ConvertTo-Json -Depth 5
        }
        Write-BRAVOStateFileAtomic -Path $statePath -Text $clearedRaw
        $result.Status = 'Repaired'
    } catch {
        $result.Status = 'RepairFailed'
        $result.Failed = @($result.Failed) + @("виняток самовідновлення: $($_.Exception.Message)")
    }
    return $result
}

function Get-BRAVOForeignServiceQuiescenceContext {
    # #333: контекст ЧУЖОГО (не цього процесу) ownership-маркера для власника,
    # що зараз починає власне вікно утримання (DataRestore). Єдине місце, де
    # це читається, — щоб споживач не копіював логіку маркера.
    #   Present            - на диску є валідний чужий маркер;
    #   OwnerAlive         - його власник ще живий (тоді решта полів порожня:
    #                        чужу живу роботу не «успадковуємо»);
    #   RestartSuppressed  - маркер мертвого власника suppressed;
    #   RestartIntentNames - служби, які мертвий власник зупинив із наміром
    #                        їх запустити (RestartIntent = $true);
    #   HeldSnapshot       - непорожній startTypeSnapshot мертвого власника
    #                        (служби, що можуть бути тимчасово Disabled).
    # Не кидає виняток; невалідний/відсутній маркер = Present $false.
    [CmdletBinding()]
    param()

    $context = [pscustomobject]@{
        Present = $false; OwnerAlive = $false; Owner = $null; RestartSuppressed = $false
        RestartIntentNames = @(); HeldSnapshot = @()
    }
    try {
        $state = Read-BRAVOServiceQuiescenceState
        if ($null -eq $state) { return $context }
        if (Test-BRAVOServiceQuiescenceStateOwnedByCurrentProcess -State $state) { return $context }
        $context.Present = $true
        $context.Owner = [string]$state.owner
        if (Test-BRAVOProcessAlive -ProcessId ([int]$state.pid) -ProcessStartTime ([string]$state.processStartTime)) {
            $context.OwnerAlive = $true
            return $context
        }
        $context.RestartSuppressed = [bool]$state.restartSuppressed
        $context.RestartIntentNames = @(@($state.services) | Where-Object { [bool]$_.RestartIntent } | ForEach-Object { [string]$_.Name })
        $context.HeldSnapshot = @(@($state.startTypeSnapshot) | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; StartMode = [string]$_.StartMode } })
    } catch {
        $context.Present = $false
    }
    return $context
}

function Confirm-BRAVOServicesQuiesced {
    # Жорстка повторна перевірка безпосередньо ПЕРЕД деструктивним кроком
    # (before-archive, bravocmd): служби з ServiceNames мають бути Stopped.
    # Утримання Disabled закриває вікно, а це — детектор/страховка на
    # випадок, коли утримання не спрацювало (збій sc, зміна типу іншим
    # актором) чи служба піднялась ДО його застосування.
    #   -StopRunning: служба, що біжить, зупиняється знову (ДО архівації
    #       це безпечно). Без прапорця біжуча служба = Offenders (fail-
    #       closed): під час/після before-архіву її запуск означає, що
    #       архів міг бути неконсистентним, тож bravocmd НЕ запускається.
    #   -Snapshot: служби зі знімка мають зараз бути Disabled; при
    #       -StopRunning утримання перезастосовується, інакше розбіжність
    #       = Offenders.
    # Не кидає виняток. Ok = $true лише коли Offenders порожній.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ServiceNames,
        [object[]]$Snapshot = @(),
        [switch]$StopRunning,
        [int]$StopTimeoutSeconds = 60,
        [int]$PollIntervalSeconds = 2
    )

    $offenders = @()
    $stoppedAgain = @()
    foreach ($serviceName in @($ServiceNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            $service.Refresh()
            $status = [string]$service.Status
            if ($status -eq 'Stopped') { continue }
            if (-not $StopRunning) {
                $offenders += "${serviceName}: стан $status (запущена під час вікна реставрації)"
                continue
            }
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            $deadline = (Get-Date).AddSeconds([math]::Max(1, $StopTimeoutSeconds))
            do {
                $service = Get-Service -Name $serviceName -ErrorAction Stop
                $service.Refresh()
                if ([string]$service.Status -eq 'Stopped') { break }
                if ((Get-Date) -ge $deadline) { break }
                Start-Sleep -Seconds ([math]::Max(1, $PollIntervalSeconds))
            } while ($true)
            if ([string]$service.Status -eq 'Stopped') {
                $stoppedAgain += $serviceName
            } else {
                $offenders += "${serviceName}: не вдалося зупинити повторно (стан $($service.Status))"
            }
        } catch {
            $offenders += "${serviceName}: $($_.Exception.Message)"
        }
    }
    foreach ($entry in @($Snapshot)) {
        $name = [string]$entry.Name
        try {
            $currentMode = Get-BRAVOServiceRegistryStartMode -ServiceName $name
            if ($currentMode -eq 'Disabled') { continue }
            if ($StopRunning -and $currentMode -eq [string]$entry.StartMode -and
                (Set-BRAVOServiceStartMode -ServiceName $name -StartMode 'Disabled')) { continue }
            $offenders += "${name}: утримання від автостарту не діє (тип запуску $currentMode замість Disabled)"
        } catch {
            $offenders += "${name}: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{
        Ok = ($offenders.Count -eq 0); Offenders = @($offenders); StoppedAgain = @($stoppedAgain)
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

function ConvertTo-BRAVODaysOfWeekMask {
    # Канонічний bitmask DaysOfWeek для Task Scheduler weekly-тригера
    # (TASK_TRIGGER_WEEKLY): Sunday=1, Monday=2, ... Saturday=64. Один
    # розрахунок для Installer (створює тригер) і Diagnose (перевіряє
    # фактичне визначення) — той самий інваріант, що
    # Get-BRAVOExpectedSchedulerPrincipal нижче. Невідома назва дня —
    # throw (fail-closed: невалідний розклад не має мовчки створити
    # завдання без жодного дня запуску).
    param([Parameter(Mandatory = $true)][string]$DayOfWeek)

    switch ($DayOfWeek.Trim()) {
        'Sunday'    { return 1 }
        'Monday'    { return 2 }
        'Tuesday'   { return 4 }
        'Wednesday' { return 8 }
        'Thursday'  { return 16 }
        'Friday'    { return 32 }
        'Saturday'  { return 64 }
        default {
            throw "невідомий день тижня '$DayOfWeek' — очікується англійська назва (Sunday..Saturday)"
        }
    }
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

function ConvertTo-BRAVOSchedulerExecutionTimeLimit {
    # Канонічна конверсія schedulerSettings.<Task>.ExecutionTimeLimitHours у
    # тривалість. Нею BRAVO_TASKS_INSTALL.ps1 будує Settings.ExecutionTimeLimit
    # задачі Планувальника, і нею ж Get-BRAVOOperationLockWaitBudget читає той
    # самий ліміт — тож бюджет очікування lock і фактичний ліміт задачі не
    # можуть розійтися через різне тлумачення одного значення.
    #
    # Приведення [double] у PowerShell не залежить від CurrentCulture
    # (InvariantCulture і в Windows PowerShell 5.1, і в 7.x): 0.5 -> 30 хв на
    # сервері з uk-UA/de-DE так само, як з en-US. Нечислове значення, NaN чи
    # нескінченність — виняток, як і раніше в інсталяторі.
    [CmdletBinding()]
    [OutputType([timespan])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Hours
    )

    return [timespan]::FromHours([double]$Hours)
}

function Get-BRAVOOperationLockWaitBudget {
    # Канонічний бюджет очікування спільного операційного lock
    # (BRAVO_OPERATION.lock) для прогону, що відповідає задачі Планувальника
    # типу $TaskType.
    #
    # Причина (T025): schedulerSettings.OperationLockWaitMinutes — один
    # глобальний ліміт для всіх задач (типово 360 хв), а ExecutionTimeLimit
    # задач різний (BAZASync = 2 год). BRAVO_ARCHIV -SyncBAZA, що впирався в
    # lock довгої архівації, чекав до 6 год, і Планувальник примусово
    # завершував процес на 2-й годині: без підсумку в журналі, без коду з
    # контракту BRAVO.ExitCodes (лише "задачу зупинено" в історії задачі).
    # Тепер вичерпаний бюджет — штатна відмова викликача (SkippedLockBusy).
    #
    # Ліміт задачі — той самий schedulerSettings.<TaskType>.
    # ExecutionTimeLimitHours і та сама конверсія
    # (ConvertTo-BRAVOSchedulerExecutionTimeLimit), з яких BRAVO_TASKS_INSTALL
    # будує Settings.ExecutionTimeLimit — окремої таблиці лімітів тут немає.
    #
    # Запас 30 хв лишає час на роботу ПІСЛЯ захоплення lock і на штатне
    # завершення з SkippedLockBusy, якщо lock так і не звільнився:
    #   - та сама політика вже діє для задачі того самого 2-годинного класу:
    #     Health.BusyWaitMinutes обмежено 0..90 хв при ліміті 2 год
    #     (BRAVO_CONFIG_LOADER.ps1: "очікування мусить лишати запас");
    #   - сам BAZASync на реальних серверах тримає lock ~16-17 хв (логи,
    #     зафіксовані в BRAVO.Health.Runtime.ps1 біля BusyWaitMinutes) —
    #     це вміщується в запас;
    #   - цикл очікування перевіряє дедлайн з кроком Start-Sleep 30 с, тож
    #     перевищення дедлайну циклом — секунди, а не хвилини.
    #
    # Ліміт задачі не більший за запас: бюджет 0 — рівно одна спроба
    # захоплення без очікування; якщо lock зайнятий, прогін одразу
    # завершується штатною відмовою, а не чекає, доки його вб'є Планувальник.
    #
    # Бюджет не залежить від того, чи прогін запущено Планувальником, чи
    # вручну: надійної ознаки запуску Планувальником немає (-NoPause так само
    # передають і ручні/скриптові запуски), а однаковий командний рядок
    # мусить поводитися однаково. Для ручного запуску це лише коротше
    # очікування з тим самим штатним SkippedLockBusy.
    #
    # Без відомого ліміту задачі (legacy-конфіг без вузла/ключа, або
    # значення, яке не конвертується чи недодатне) бюджет НЕ змінюється —
    # зберігається попередня поведінка: з такою конфігурацією
    # BRAVO_TASKS_INSTALL задачу не встановив би, тож обмежувати немає чим.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][System.Collections.IDictionary]$SchedulerSettings,
        [Parameter(Mandatory = $true)][ValidateSet('Backup', 'Maintenance', 'Recovery', 'BAZASync')][string]$TaskType
    )

    $configuredMinutes = 0
    if ($null -ne $SchedulerSettings -and $SchedulerSettings.Contains('OperationLockWaitMinutes')) {
        $configuredMinutes = [math]::Max(0, [int]$SchedulerSettings.OperationLockWaitMinutes)
    }

    $taskLimitMinutes = $null
    if ($null -ne $SchedulerSettings -and
        $SchedulerSettings.Contains($TaskType) -and
        $SchedulerSettings[$TaskType] -is [System.Collections.IDictionary] -and
        $SchedulerSettings[$TaskType].Contains('ExecutionTimeLimitHours')) {
        try {
            $taskLimit = ConvertTo-BRAVOSchedulerExecutionTimeLimit -Hours $SchedulerSettings[$TaskType].ExecutionTimeLimitHours
            if ($taskLimit.Ticks -gt 0) {
                $taskLimitMinutes = [int][math]::Floor($taskLimit.TotalMinutes)
            }
        } catch {
            $taskLimitMinutes = $null
        }
    }

    $marginMinutes = 30
    $effectiveMinutes = $configuredMinutes
    $capped = $false
    if ($null -ne $taskLimitMinutes) {
        $ceilingMinutes = [math]::Max(0, $taskLimitMinutes - $marginMinutes)
        if ($configuredMinutes -gt $ceilingMinutes) {
            $effectiveMinutes = $ceilingMinutes
            $capped = $true
        }
    }

    # Єдиний операторський текст про обмеження — обидва викликачі
    # (Archive, Maintenance) дописують його до повідомлення про тайм-аут.
    $limitDescription = ''
    if ($capped) {
        $limitDescription = " (OperationLockWaitMinutes=$configuredMinutes обмежено лімітом виконання задачі $TaskType $taskLimitMinutes хв мінус запас $marginMinutes хв)"
    }

    return [pscustomobject]@{
        TaskType = $TaskType
        ConfiguredMinutes = $configuredMinutes
        TaskLimitMinutes = $taskLimitMinutes
        SafetyMarginMinutes = $marginMinutes
        EffectiveMinutes = [int]$effectiveMinutes
        Capped = $capped
        LimitDescription = $limitDescription
    }
}
