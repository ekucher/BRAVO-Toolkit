# BRAVO.Status — machine-readable status contract v2 (ROADMAP P2.1; читає v1 і v2).
#
# Канонічний власник схеми статусу останнього прогону операції для
# зовнішніх machine-споживачів (моніторинг читає JSON з диска замість
# парсингу консолі). Один файл на операцію:
#     %ProgramData%\BRAVO\State\STATUS\BRAVO_STATUS_<Operation>.json
#
# ІНВАРІАНТИ КОНТРАКТУ (ROADMAP «Telemetry/monitoring не повинні
# змінювати exit code або результат операції»):
# - Write-BRAVOOperationStatus сам може кинути виняток (диск/ACL) —
#   КОЖЕН call-site зобов'язаний обгорнути виклик try/catch і на
#   помилку лише логувати WARNING, ніколи не змінюючи exit code чи
#   результат операції (fail-soft; перевіряється self-test-контрактом).
# - Exit codes лишаються канонічним класифікатором збою: поле status
#   (OK|WARNINGS|ERROR) — лише зручна проєкція exitCode для споживача.
#   Модуль НЕ імпортує BRAVO.ExitCodes і власного відображення код→status
#   не має (#479): call-site обчислює status канонічною
#   Get-BRAVOExitCodeStatus (BRAVO.ExitCodes) і передає його обов'язковим
#   параметром -Status; writer валідує його за схемою і ЗВІРЯЄ з канонічною
#   Get-BRAVOExitCodeStatus (late-bound, без залежності в маніфесті):
#   суперечлива пара -ExitCode/-Status відхиляється, а недоступність
#   канонічного відображення — fail-closed (статус не пишеться).
# - Версії схеми: v1 (коди ≠ 0/10 → ERROR, зокрема 20) і v2 (код 20 →
#   WARNINGS, рішення D-A #479). Writer пише v2; reader приймає 1 і 2,
#   файли v1 лишаються валідними (status читається як записано).
# - Серіалізація: preservation-рішення «ERROR не затирається слабшим» і
#   атомарна заміна файла виконуються під ексклюзивним lock-файлом
#   <status>.lock (FileStream, FileShare.None; прив'язка до фізичного файла,
#   без глобального простору імен) з обмеженим очікуванням; усі writer'и
#   беруть те саме блокування (check-then-write race, PR #493).
# - Жодних secret-bearing значень у details: call-site передає лише
#   агрегати (лічильники, ідентифікатори generation, булеві прапорці).
#
# Це фундамент P2.1; транспорт/outbox/Zabbix-інтеграція (P2.2/FEAT-003)
# свідомо НЕ входить — контракт лишається локальним файлом.

Set-StrictMode -Version 2.0

$script:OperationStatusSchemaVersion = 2
$script:SupportedOperationStatusSchemaVersions = @(1, 2)
$script:OperationStatusDefaultLockTimeoutMilliseconds = 10000
# Тестові seam'и блокування (див. Enter-BRAVOOperationStatusLock); у production $null.
$script:OperationStatusLockContendedHook = $null
$script:OperationStatusLockAcquiredHook = $null

function Get-BRAVOOperationStatusPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Archive', 'Health', 'Maintenance', 'RestoreVerify')]
        [string]$Operation
    )

    return Join-Path (Join-Path $StateRoot 'STATUS') "BRAVO_STATUS_$Operation.json"
}

function Get-BRAVOOperationStatus {
    # Контракт результату той самий, що Read-BRAVOBazaState /
    # Get-BRAVORestoreVerifyState: {Exists; Corrupt; State; Reason}.
    # Невідома schemaVersion → Corrupt (fail-closed для споживача,
    # ніколи не мовчазна міграція).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not [IO.File]::Exists($Path)) {
        return [pscustomobject]@{ Exists = $false; Corrupt = $false; State = $null; Reason = $null }
    }
    try {
        $parsed = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($null -eq $parsed.PSObject.Properties['schemaVersion'] -or
            $script:SupportedOperationStatusSchemaVersions -notcontains [int]$parsed.schemaVersion) {
            return [pscustomobject]@{
                Exists = $true
                Corrupt = $true
                State = $null
                Reason = "непідтримувана schemaVersion status-файла (підтримуються: $($script:SupportedOperationStatusSchemaVersions -join ', '))"
            }
        }
        return [pscustomobject]@{ Exists = $true; Corrupt = $false; State = $parsed; Reason = $null }
    } catch {
        return [pscustomobject]@{ Exists = $true; Corrupt = $true; State = $null; Reason = $_.Exception.Message }
    }
}

function Get-BRAVOOperationStatusPreservation {
    # Recovery-тик не повинен затирати слабшим статусом сильніший (інваріант
    # «never overwrite a stronger state with a weaker one»): ERROR, лишений
    # попередньою невдалою операцією, зберігається, поки його не замінить
    # справжній прогін. Це ЧИСТЕ рішення без запису й без ExitCodes:
    # call-site передає вже обчислений канонічний -NewStatus.
    # Правило: Preserve = (попередній status == 'ERROR') -and (NewStatus != 'ERROR').
    # Відсутній / нечитний / зіпсований файл чи невалідне поле status —
    # НЕ блокують запис (Preserve = $false, fail-soft); причину повертає Note,
    # щоб call-site залогував її. Не кидає винятків через проблеми файлу/вмісту;
    # помилки прив'язки параметрів доходять до викликача.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Archive', 'Health', 'Maintenance', 'RestoreVerify')]
        [string]$Operation,
        [Parameter(Mandatory = $true)]
        [ValidateSet('OK', 'WARNINGS', 'ERROR')]
        [string]$NewStatus
    )

    $result = [pscustomobject]@{ Preserve = $false; PreviousStatus = $null; Note = $null }
    try {
        $existing = Get-BRAVOOperationStatus -Path (Get-BRAVOOperationStatusPath -StateRoot $StateRoot -Operation $Operation)
        if (-not $existing.Exists) { return $result }
        if ($existing.Corrupt) {
            $result.Note = "попередній status-файл пошкоджений ($($existing.Reason)) — записується новий"
            return $result
        }
        $previousProperty = $existing.State.PSObject.Properties['status']
        if ($null -eq $previousProperty -or @('OK', 'WARNINGS', 'ERROR') -cnotcontains [string]$previousProperty.Value) {
            $result.Note = 'попередній status-файл без валідного поля status — записується новий'
            return $result
        }
        $result.PreviousStatus = [string]$previousProperty.Value
        $result.Preserve = ($result.PreviousStatus -ceq 'ERROR' -and $NewStatus -cne 'ERROR')
    } catch {
        $result.Preserve = $false
        $result.Note = "не вдалося прочитати попередній status-файл ($($_.Exception.Message)) — записується новий"
    }
    return $result
}

function Get-BRAVOOperationStatusLockPath {
    # Lock-файл лежить поруч зі status-файлом і прив'язується до ФІЗИЧНОГО файла
    # (FileShare.None): junction/symlink/8.3-аліас/регістр не створюють іншого
    # блокування. Глобального простору імен немає, тож «squatting» неможливий:
    # створювати файли в STATUS\ можуть лише SYSTEM/Administrators (і обліковий
    # запис завдань, Modify) — StateRoot закритий від BUILTIN\Users
    # (Set-BRAVOProtectedDataDirectoryAcl у BRAVO_TASKS_INSTALL.ps1, шлях
    # StateRoot — BRAVO.Configuration.Derivation).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$StatusPath)

    return "$StatusPath.lock"
}

function Enter-BRAVOOperationStatusLock {
    # Ексклюзивне блокування lock-файла: FileStream OpenOrCreate/ReadWrite/
    # FileShare.None у обмеженому циклі (опитування кожні 50 мс до
    # TimeoutMilliseconds). «Зайнято» = ЛИШЕ sharing violation
    # (IOException, HResult 0x80070020). Повертає утримуваний FileStream або
    # $null при таймауті; будь-яка інша помилка кидається (caller діє так само,
    # як при таймауті: preserve-запис пропускається, звичайний кидає). Handle
    # звільняє ОС при завершенні процесу — покинутого блокування не буває.
    # Lock-файл не видаляється (це дало б гонку між створенням і видаленням).
    # Тестові seam'и (за замовчуванням $null, у production не встановлюються):
    # ContendedHook — при першому спостереженні зайнятого блокування, AcquiredHook —
    # одразу після отримання. Помилки hook'ів ігноруються.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StatusPath,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
    )

    $lockPath = Get-BRAVOOperationStatusLockPath -StatusPath $StatusPath
    $sharingViolationHResult = -2147024864 # 0x80070020
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $contendedSignalled = $false
    $stream = $null
    while ($null -eq $stream) {
        try {
            $stream = New-Object System.IO.FileStream($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) -ErrorAction Stop
        } catch {
            # New-Object загортає виняток конструктора в MethodInvocationException.
            $openError = $_.Exception
            if ($openError -is [System.Management.Automation.MethodInvocationException] -and $null -ne $openError.InnerException) {
                $openError = $openError.InnerException
            }
            if ($openError -isnot [System.IO.IOException] -or [int]$openError.HResult -ne $sharingViolationHResult) { throw $openError }
            if (-not $contendedSignalled) {
                $contendedSignalled = $true
                if ($null -ne $script:OperationStatusLockContendedHook) {
                    try { $null = & $script:OperationStatusLockContendedHook } catch { $null = $_ }
                }
            }
            if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMilliseconds) { return $null }
            Start-Sleep -Milliseconds 50
        }
    }
    if ($null -ne $script:OperationStatusLockAcquiredHook) {
        try { $null = & $script:OperationStatusLockAcquiredHook } catch { $null = $_ }
    }
    return $stream
}

function Exit-BRAVOOperationStatusLock {
    [CmdletBinding()]
    param([AllowNull()]$Stream)

    if ($null -eq $Stream) { return }
    $Stream.Dispose()
}

function Assert-BRAVOOperationStatusMatchesExitCode {
    # Пара -ExitCode/-Status повинна збігатися з канонічною проєкцією
    # BRAVO.ExitCodes (Get-BRAVOExitCodeStatus). Модуль не імпортує ExitCodes
    # (маніфест без залежностей): функцію шукаємо в сесії. Відсутня — fail-closed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Status
    )

    $canonicalResolver = Get-Command -Name Get-BRAVOExitCodeStatus -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $canonicalResolver) {
        throw 'Канонічне відображення exit-код -> status (Get-BRAVOExitCodeStatus, BRAVO.ExitCodes) недоступне: status-файл не записано, щоб не зберегти непідтверджену пару.'
    }
    $canonicalStatus = [string](& $canonicalResolver -Code $ExitCode)
    if ($canonicalStatus -cne $Status) {
        throw "Суперечлива пара exitCode=$ExitCode / status=${Status}: канонічний status для цього коду - ${canonicalStatus}. Status-файл не записано."
    }
}

function Write-BRAVOOperationStatus {
    # Atomic write: temp -> [IO.File]::Replace/Move (канонічний прийом
    # Save-BRAVOBazaState / Save-BRAVORestoreVerifyState) — crash посеред
    # запису не лишає частковий файл поверх валідного попереднього.
    #
    # Серіалізація (PR #493, P1): заміна файла виконується під lock-файлом
    # <status>.lock. З -PreserveStrongerError рішення «не затирати ERROR
    # слабшим» (Get-BRAVOOperationStatusPreservation) приймається в ТІЙ ЖЕ
    # критичній секції, що й заміна, тому конкурентний writer не може
    # опублікувати ERROR між читанням і записом. Таймаут очікування: з
    # -PreserveStrongerError запис ПРОПУСКАЄТЬСЯ (можливий сильніший стан не
    # затирається; TimedOut=$true у -PassThru), без нього — виняток (call-site
    # fail-soft логує WARNING). -PassThru повертає {Written; Preserved;
    # PreviousStatus; TimedOut; Note}.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Archive', 'Health', 'Maintenance', 'RestoreVerify')]
        [string]$Operation,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [datetime]$FinishedAt = (Get-Date),
        # Операційно-специфічні агрегати (лічильники/ідентифікатори/булеві).
        # Call-site НЕ передає сюди секрети, повні шляхи з credentials чи
        # сирі повідомлення винятків — self-test перевіряє серіалізацію.
        [hashtable]$Details = @{},
        # Ім'я exit-коду з канонічного BRAVO.ExitCodes; параметр, а не
        # виклик звідси — модуль статусу не тягне залежність на ExitCodes
        # (call-site уже має Get-BRAVOExitCodeName у scope).
        [AllowNull()][AllowEmptyString()][string]$ExitCodeName,
        # Проєкція exit-коду на схему статусу (OK|WARNINGS|ERROR): результат
        # Get-BRAVOExitCodeStatus, обчислений call-site'ом (#479). Обов'язковий:
        # запасного відображення тут немає; пара з -ExitCode звіряється з
        # каноном (Assert-BRAVOOperationStatusMatchesExitCode).
        [Parameter(Mandatory = $true)]
        [ValidateSet('OK', 'WARNINGS', 'ERROR')]
        [string]$Status,
        [switch]$PreserveStrongerError,
        [ValidateRange(0, 600000)]
        [int]$LockTimeoutMilliseconds = 10000,
        [switch]$PassThru
    )

    Assert-BRAVOOperationStatusMatchesExitCode -ExitCode $ExitCode -Status $Status

    $outcome = [pscustomobject]@{ Written = $false; Preserved = $false; PreviousStatus = $null; TimedOut = $false; Note = $null }

    $packageVersion = ''
    $packageVersionVariable = Get-Variable -Name 'ScriptVersion' -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $packageVersionVariable) {
        $packageVersion = [string]$packageVersionVariable.Value
    }

    $serializable = [ordered]@{
        schemaVersion = $script:OperationStatusSchemaVersion
        host = [string]$env:COMPUTERNAME
        packageVersion = $packageVersion
        operation = $Operation
        status = $Status
        exitCode = $ExitCode
        exitCodeName = [string]$ExitCodeName
        startedAt = $StartedAt.ToString('o')
        finishedAt = $FinishedAt.ToString('o')
        durationSeconds = [math]::Round(($FinishedAt - $StartedAt).TotalSeconds, 1)
        details = $Details
    }

    $statusPath = Get-BRAVOOperationStatusPath -StateRoot $StateRoot -Operation $Operation
    $statusDirectory = Split-Path -Path $statusPath -Parent
    if (-not [IO.Directory]::Exists($statusDirectory)) {
        [void][IO.Directory]::CreateDirectory($statusDirectory)
    }
    $temporaryPath = Join-Path $statusDirectory ('.BRAVO_STATUS_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $backupPath = Join-Path $statusDirectory ('.BRAVO_STATUS_{0}.bak' -f [guid]::NewGuid().ToString('N'))
    $replaced = $false
    $lock = $null
    try {
        $json = $serializable | ConvertTo-Json -Depth 4 -Compress
        [IO.File]::WriteAllText($temporaryPath, $json, (New-Object Text.UTF8Encoding($false)))

        try {
            $lock = Enter-BRAVOOperationStatusLock -StatusPath $statusPath -TimeoutMilliseconds $LockTimeoutMilliseconds
        } catch {
            if (-not $PreserveStrongerError) { throw }
            $outcome.Note = "блокування status-файла недоступне ($($_.Exception.Message)) — запис пропущено, щоб не затерти можливий сильніший статус"
            if ($PassThru) { return $outcome }
            return
        }
        if ($null -eq $lock) {
            $outcome.TimedOut = $true
            $outcome.Note = "не вдалося отримати блокування status-файла за $LockTimeoutMilliseconds мс"
            if (-not $PreserveStrongerError) {
                throw "Status-файл $Operation заблокований іншим процесом (очікування $LockTimeoutMilliseconds мс): запис не виконано."
            }
            $outcome.Note += ' — запис пропущено, щоб не затерти можливий сильніший статус'
            if ($PassThru) { return $outcome }
            return
        }

        if ($PreserveStrongerError) {
            $preservation = Get-BRAVOOperationStatusPreservation -StateRoot $StateRoot -Operation $Operation -NewStatus $Status
            $outcome.PreviousStatus = $preservation.PreviousStatus
            $outcome.Note = $preservation.Note
            if ($preservation.Preserve) {
                $outcome.Preserved = $true
                if ($PassThru) { return $outcome }
                return
            }
        }

        if ([IO.File]::Exists($statusPath)) {
            [IO.File]::Replace($temporaryPath, $statusPath, $backupPath)
            $replaced = $true
        } else {
            [IO.File]::Move($temporaryPath, $statusPath)
        }
        $outcome.Written = $true
    } finally {
        Exit-BRAVOOperationStatusLock -Stream $lock
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
        if ($replaced -and [IO.File]::Exists($backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($PassThru) { return $outcome }
}
