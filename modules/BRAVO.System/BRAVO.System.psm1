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
        processStartTime = (Get-BRAVOCurrentProcessStartTimeText)
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
        $startType = [string]$service.StartType
        $delayed = Get-BRAVOServiceDelayedAutoStart -ServiceName $serviceName
        $action = 'None'
        $targetArgument = $null
        if ($startType -eq 'Automatic') {
            if ($HoldServices -and -not $delayed) {
                $action = 'SetDelayedAuto'; $targetArgument = 'delayed-auto'
            } elseif (-not $HoldServices -and $delayed) {
                $action = 'SetAuto'; $targetArgument = 'auto'
            }
        } elseif ($HoldServices) {
            $action = 'SkippedNotAutomatic'
        }
        $success = $true
        $details = $null
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
