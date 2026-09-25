Set-StrictMode -Version 2.0

# BRAVO.Operations — агентська частина fleet-моніторингу BSYSTEM Operations
# (замінює ручний аналіз Discord-потоку централізованим dashboard, design
# зафіксований грилінг-сесією 2026-09-23; контракт enroll/events оновлено
# під фінальний D1-D7 hardening bsystem-operations, 2026-09-24).
#
# Область цього модуля:
#   - постійна ідентичність сервера (GUID Server ID, persisted state);
#   - self-enrollment (bootstrap-секрет -> pending -> approve -> API-ключ,
#     ретрійований claim-based poll);
#   - відправка структурованих подій/heartbeat в Operations API з durable
#     локальним outbox (retry/backoff) на випадок недоступності API.
#
# Канонічно НЕ входить сюди (навмисно): формування Discord/Slack-тексту
# (BRAVO.Notifications), низькорівневий webhook-транспорт для Discord/Slack
# (BRAVO.Compatibility Send-BRAVOWebhookNotification) — Operations має
# власний JSON-контракт, а не текстове повідомлення, тож ділити транспорт
# з тими функціями означало б підганяти чужий контракт під цей.
#
# Усі публічні функції тут NEVER-THROW назовні при мережевих/HTTP-збоях
# (і при пошкодженому локальному стані): Operations-звітність — вторинний
# ефект (як і Slack/Discord), її збій не повинен переривати чи спотворювати
# первинну операцію Archive/Maintenance/Health (операційний інваріант
# проекту).

# ---------------------------------------------------------------------
# STATE: каталоги/шляхи
# ---------------------------------------------------------------------

function Get-BRAVOOperationsStateDirectory {
    # Тестова ізоляція (той самий принцип, що BRAVO_SELFTEST_ROOT/
    # BRAVO_SELFTEST_VERSION_STATE_PATH у BRAVO_SELF_TEST.ps1): якщо
    # BRAVO_OPERATIONS_TEST_STATE_DIR встановлено, використовується він
    # ЗАМІСТЬ реального ProgramData\BRAVO\State — без цього self-test для
    # server-id/outbox або читав би, або (гірше) МУТУВАВ би справжній
    # production-стан цього хоста. Продакшн-код без цієї змінної
    # середовища поведінки не змінює.
    [CmdletBinding()]
    param()

    $testOverrideDirectory = [Environment]::GetEnvironmentVariable('BRAVO_OPERATIONS_TEST_STATE_DIR')
    if (-not [string]::IsNullOrWhiteSpace($testOverrideDirectory)) {
        return $testOverrideDirectory
    }

    $programDataRoot = [Environment]::GetFolderPath('CommonApplicationData')
    if ([string]::IsNullOrWhiteSpace($programDataRoot)) {
        throw 'CommonApplicationData недоступний для Operations server-id state'
    }
    return (Join-Path $programDataRoot 'BRAVO\State')
}

function Get-BRAVOOperationsServerIdStatePath {
    [CmdletBinding()]
    param()

    return (Join-Path (Get-BRAVOOperationsStateDirectory) 'BRAVO_OPERATIONS_SERVER_ID.json')
}

function Get-BRAVOOperationsEnrollmentStatePath {
    # A1/A2 (bsystem-operations Wave 2 hardening): зберігає АГЕНТ-
    # ЗГЕНЕРОВАНИЙ enrollment claim (не сервером виданий/ротований —
    # дивись Get-BRAVOOperationsEnrollmentClaim) + throttle-мітки
    # логування. Claim генерується ОДИН раз на серверну ідентичність і
    # живе ПОРУЧ з BRAVO_OPERATIONS_SERVER_ID.json увесь час її життя
    # (той самий каталог, той самий atomic-write патерн) — той самий
    # локальний файл, що раніше тримав сервер-видани claimToken під
    # старим протоколом, тепер перевикористаний під агент-згенерований
    # claim нового протоколу.
    #
    # Свідомий вибір F4: НЕ Credential Manager. Це не fleet-wide секрет
    # (як bootstrap-секрет) і не видана авторизація (як API-ключ) —
    # компрометація ЦЬОГО claim шкодить ЛИШЕ pending/lifecycle
    # enrollment-у ЦЬОГО одного серверId (сервер прив'язує claim-hash до
    # конкретного ServerRow, D1/A3), не fleet-wide доступу. Додавання
    # третьої Credential Manager-цілі заради значення з таким вузьким
    # blast radius — зайва складність без відповідного захисту, який
    # виправдав би її; звичайний JSON поруч зі server-id state — простіше
    # і достатньо.
    [CmdletBinding()]
    param()

    return (Join-Path (Get-BRAVOOperationsStateDirectory) 'BRAVO_OPERATIONS_ENROLLMENT.json')
}

function Get-BRAVOOperationsOutboxDirectory {
    [CmdletBinding()]
    param()

    return (Join-Path (Get-BRAVOOperationsStateDirectory) 'Outbox')
}

function Get-BRAVOOperationsOutboxDeadLetterDirectory {
    [CmdletBinding()]
    param()

    return (Join-Path (Get-BRAVOOperationsOutboxDirectory) 'DeadLetter')
}

function Write-BRAVOOperationsAtomicJsonFile {
    # Спільний write-to-temp-then-Replace/Move патерн — той самий, що
    # Get-BRAVOOperationsServerId нижче використовував локально; винесено
    # в один call site, бо тепер його потребують і enrollment-state, і
    # кожен outbox-запис.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object
    )

    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }

    $temporaryPath = Join-Path $directory ('.{0}_{1}.tmp' -f (Split-Path -Path $Path -Leaf), [guid]::NewGuid().ToString('N'))
    $backupPath = Join-Path $directory ('.{0}_{1}.bak' -f (Split-Path -Path $Path -Leaf), [guid]::NewGuid().ToString('N'))
    $wasReplaced = $false
    try {
        $json = $Object | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($temporaryPath, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporaryPath, $Path, $backupPath)
            $wasReplaced = $true
        } else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
        if ($wasReplaced -and [IO.File]::Exists($backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-BRAVOOperationsServerId {
    # Постійний GUID, що ідентифікує цей сервер в Operations — генерується
    # ОДИН раз (перший запуск, файл стану ще не існує) і переживає
    # перевстановлення/оновлення BRAVO-Toolkit.
    #
    # E9 (fail-closed на пошкоджений state-файл): раніше нечитаний/
    # непарсований файл трактувався як "відсутній" і мовчки перезаписувався
    # НОВИМ GUID — якщо цей сервер уже був approved під старим ідентифіка-
    # тором, це створювало "ghost"-ідентичність (нове enrollment з нуля),
    # а стара approved-сутність лишалась осиротілою в dashboard назавжди.
    # Тепер: файл ІСНУЄ, але непарсований -> ERROR-лог і $null (звітність
    # Operations пропускається цей прогін), БЕЗ генерації заміни. Лише
    # СПРАВЖНЯ відсутність файлу (перший запуск) генерує новий GUID.
    [CmdletBinding()]
    param()

    $statePath = Get-BRAVOOperationsServerIdStatePath
    if ([IO.File]::Exists($statePath)) {
        try {
            $existing = ([IO.File]::ReadAllText($statePath, (New-Object Text.UTF8Encoding($false))) | ConvertFrom-Json -ErrorAction Stop)
            $existingId = [string]$existing.ServerId
            $parsedGuid = [guid]::Empty
            if ([guid]::TryParse($existingId, [ref]$parsedGuid)) {
                return $parsedGuid.ToString()
            }
            Write-BRAVOLog -Component 'Operations' -Level 'ERROR' `
                -Message "Файл ідентичності Operations ($statePath) прочитано, але ServerId у ньому не є валідним GUID — звітність Operations пропущено цей прогін. Це НЕ автоматично виправляється (щоб не створити ghost-ідентичність поверх уже approved сервера); відновіть файл з резервної копії, або свідомо видаліть його, якщо потрібне нове enrollment."
            return $null
        } catch {
            Write-BRAVOLog -Component 'Operations' -Level 'ERROR' `
                -Message "Файл ідентичності Operations ($statePath) пошкоджений/не парситься ($($_.Exception.Message)) — звітність Operations пропущено цей прогін. Це НЕ автоматично виправляється (щоб не створити ghost-ідентичність поверх уже approved сервера); відновіть файл з резервної копії, або свідомо видаліть його, якщо потрібне нове enrollment."
            return $null
        }
    }

    $newServerId = [guid]::NewGuid().ToString()
    Write-BRAVOOperationsAtomicJsonFile -Path $statePath -Object ([pscustomobject]@{
        ServerId = $newServerId
        CreatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    })
    return $newServerId
}

# ---------------------------------------------------------------------
# ENROLLMENT LOCAL STATE (claim token + log-throttle timestamps)
# ---------------------------------------------------------------------

function Get-BRAVOOperationsEnrollmentState {
    # Пошкоджений/відсутній файл тут НЕ є identity-критичним у сенсі E9
    # (на відміну від server-id): відсутній Claim тут просто означає
    # "згенеруємо новий" (Get-BRAVOOperationsEnrollmentClaim нижче) — тож
    # непарсований файл трактується як "відсутній", не fail-closed. Варто
    # памʼятати: якщо сервер уже 'pending' на API зі СТАРИМ claim-hash, а
    # локальний файл щойно згенерував НОВИЙ claim через втрату/
    # пошкодження цього файлу — наступний POST /enroll отримає 409
    # claim_mismatch (термінально для тієї спроби, див. F6/Invoke-
    # BRAVOOperationsEnrollment) — це прийнятний, задокументований
    # залишковий ризик втрати ЦЬОГО файлу, а не помилка цієї функції.
    [CmdletBinding()]
    param()

    $path = Get-BRAVOOperationsEnrollmentStatePath
    if (-not [IO.File]::Exists($path)) {
        return [pscustomobject]@{
            Claim = $null
            LastNotReadyLoggedAtUtc = $null
            LastTtlExpiredLoggedAtUtc = $null
            LastFinalizedLoggedAtUtc = $null
            LastNotConfiguredLoggedAtUtc = $null
            LastApiBaseUrlMissingLoggedAtUtc = $null
        }
    }
    try {
        $raw = ([IO.File]::ReadAllText($path, (New-Object Text.UTF8Encoding($false))) | ConvertFrom-Json -ErrorAction Stop)
        return [pscustomobject]@{
            Claim = if ($null -ne $raw.Claim) { [string]$raw.Claim } else { $null }
            LastNotReadyLoggedAtUtc = if ($null -ne $raw.LastNotReadyLoggedAtUtc) { [string]$raw.LastNotReadyLoggedAtUtc } else { $null }
            LastTtlExpiredLoggedAtUtc = if ($null -ne $raw.LastTtlExpiredLoggedAtUtc) { [string]$raw.LastTtlExpiredLoggedAtUtc } else { $null }
            LastFinalizedLoggedAtUtc = if ($null -ne $raw.LastFinalizedLoggedAtUtc) { [string]$raw.LastFinalizedLoggedAtUtc } else { $null }
            LastNotConfiguredLoggedAtUtc = if ($null -ne $raw.LastNotConfiguredLoggedAtUtc) { [string]$raw.LastNotConfiguredLoggedAtUtc } else { $null }
            LastApiBaseUrlMissingLoggedAtUtc = if ($null -ne $raw.LastApiBaseUrlMissingLoggedAtUtc) { [string]$raw.LastApiBaseUrlMissingLoggedAtUtc } else { $null }
        }
    } catch {
        return [pscustomobject]@{
            Claim = $null
            LastNotReadyLoggedAtUtc = $null
            LastTtlExpiredLoggedAtUtc = $null
            LastFinalizedLoggedAtUtc = $null
            LastNotConfiguredLoggedAtUtc = $null
            LastApiBaseUrlMissingLoggedAtUtc = $null
        }
    }
}

function Enter-BRAVOOperationsEnrollmentClaimLock {
    # Cross-process серіалізація першостворення claim (review P1): Get-
    # BRAVOOperationsEnrollmentClaim нижче — read-then-write (прочитати
    # стан, якщо Claim відсутній — згенерувати й записати). Write-
    # BRAVOOperationsAtomicJsonFile сам по собі атомарний (temp+rename),
    # але це захищає лише ЦІЛІСНІСТЬ ОДНОГО запису, не CAS між двома
    # одночасними першими прогонами (Maintenance/Health/Archive/heartbeat
    # можуть стартувати одночасно за розкладом): обидва можуть прочитати
    # ВІДСУТНІЙ claim, згенерувати РІЗНІ GUID і атомарно перезаписати той
    # самий файл — переможець запису лишає claim, якого процес-програвець
    # ніколи не побачив (він уже тримає СВІЙ GUID у пам'яті й надішле
    # ЙОГО в POST /enroll). Сервер зв'яже serverId із claim переможця
    # запису файлу; кожен наступний прогін програвця (з тим самим,
    # застарілим claim, доки файл знову не прочитають) отримає постійний
    # 409 claim_mismatch.
    #
    # Named Mutex (той самий канонічний підхід, що
    # Enter-BRAVOPilotInstallRootLock у deploy/BRAVOConfigV2Pilot.Runtime.ps1):
    # crash-safe за конструкцією ОС — впалий власник без Release не лишає
    # постійного замка (AbandonedMutexException -> лок і так наш).
    # Global\-простір імен: BRAVO-процеси (Scheduled Task під SYSTEM чи
    # сервісним акаунтом чи heartbeat-сесія оператора) можуть виконуватись
    # у різних сесіях; без Global\ інша сесія не побачила б цей mutex.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutSeconds = 10
    )

    $normalizedPath = ([IO.Path]::GetFullPath($Path)).TrimEnd('\', '/').ToLowerInvariant()
    $hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($normalizedPath))
    $hashHex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    $mutexName = "Global\BRAVOOperationsEnrollmentClaim-$hashHex"

    $mutex = New-Object Threading.Mutex($false, $mutexName)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
    } catch [Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        $mutex.Dispose()
        return $null
    }
    return $mutex
}

function Exit-BRAVOOperationsEnrollmentClaimLock {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Threading.Mutex]$Mutex)
    try {
        $Mutex.ReleaseMutex()
    } catch {
        # best effort: Dispose() нижче виконується безумовно й звільняє
        # kernel-об'єкт навіть якщо ReleaseMutex кинув (напр. виклик з
        # потоку, що не тримав mutex, чого тут статично не буває, але
        # немає сенсу переривати finally-подібний cleanup через це).
    }
    $Mutex.Dispose()
}

function Get-BRAVOOperationsEnrollmentClaim {
    # A1/A2 (bsystem-operations Wave 2 hardening — fixes PR #2 review
    # finding P1, repository.ts:148 at the time): цей claim ТЕПЕР
    # генерується АГЕНТОМ, один раз на серверну ідентичність, і живе
    # ЛОКАЛЬНО (Get-BRAVOOperationsEnrollmentStatePath) увесь час життя
    # цієї ідентичності — POST /enroll і GET /enroll/:id завжди несуть
    # ОДИН і той самий claim, доки серверId не буде замінений повністю
    # новим enrollment (нова ідентичність = новий server-id state-файл,
    # окрема дія, яку цей модуль сам не ініціює). Стара модель (сервер
    # РОТУВАВ/повертав claim у 202-відповіді POST) дозволяла перехопити
    # чужий pending-enrollment, знаючи лише fleet-wide bootstrap-секрет +
    # вгадуваний serverId — тепер claim ніколи не подорожує сервер->агент.
    #
    # Never-throw: якщо диск недоступний для запису, claim ЛИШЕ ДЛЯ
    # ЦЬОГО прогону все одно повертається (щоб спроба enrollment не
    # зривалась взагалі) — з WARNING, бо нестабільний claim між прогонами
    # означає 409 claim_mismatch на наступному POST для вже-pending
    # серверId.
    [CmdletBinding()]
    param()

    $state = Get-BRAVOOperationsEnrollmentState
    if (-not [string]::IsNullOrWhiteSpace($state.Claim)) {
        return $state.Claim
    }

    # Claim відсутній — критична секція генерації+запису серіалізується
    # cross-process mutex-ом (Enter-BRAVOOperationsEnrollmentClaimLock
    # вище), щоб два одночасні "першостворення" не породили два різні
    # GUID для того самого serverId.
    $lockMutex = Enter-BRAVOOperationsEnrollmentClaimLock -Path (Get-BRAVOOperationsEnrollmentStatePath)
    if ($null -eq $lockMutex) {
        # Лок не отримано за таймаут — той самий never-throw fallback, що
        # й раніше для збою диска: claim генерується лише для ПАМ'ЯТІ
        # цього прогону, без запису (щоб точно не перезаписати те, що
        # власник локу саме зараз пише).
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message 'Не вдалося отримати cross-process лок для першостворення enrollment-claim (інший процес BRAVO, ймовірно, робить це паралельно) — цей прогін використає claim лише в памʼяті, без запису на диск'
        return [guid]::NewGuid().ToString()
    }
    try {
        # Double-checked locking: поки чекали на mutex, інший процес міг
        # уже прочитати відсутній claim, згенерувати й записати СВІЙ —
        # перечитуємо стан ПІСЛЯ отримання локу, щоб не створити другий,
        # зайвий GUID і не перезаписати вже узгоджений з сервером claim.
        $state = Get-BRAVOOperationsEnrollmentState
        if (-not [string]::IsNullOrWhiteSpace($state.Claim)) {
            return $state.Claim
        }
        $newClaim = [guid]::NewGuid().ToString()
        $state.Claim = $newClaim
        try {
            Write-BRAVOOperationsAtomicJsonFile -Path (Get-BRAVOOperationsEnrollmentStatePath) -Object $state
        } catch {
            Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
                -Message "Не вдалося зберегти новостворений enrollment-claim на диск: $($_.Exception.Message) — цей прогін використає його лише в памʼяті; якщо диск лишиться недоступним, наступний прогін згенерує ІНШИЙ claim, що дасть 409 claim_mismatch, якщо серверId уже pending на API"
        }
        return $newClaim
    } finally {
        Exit-BRAVOOperationsEnrollmentClaimLock -Mutex $lockMutex
    }
}

function Set-BRAVOOperationsEnrollmentState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)

    try {
        Write-BRAVOOperationsAtomicJsonFile -Path (Get-BRAVOOperationsEnrollmentStatePath) -Object $State
    } catch {
        # Локальний throttle/claim-стан — best effort. Втрата запису лише
        # означає повторний POST /enroll наступного разу (rotates claim,
        # нешкідливо) або одне зайве попередження в лозі — не привід
        # переривати виклик.
    }
}

function Clear-BRAVOOperationsEnrollmentState {
    [CmdletBinding()]
    param()

    try {
        $path = Get-BRAVOOperationsEnrollmentStatePath
        if ([IO.File]::Exists($path)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    } catch {
        # best effort
    }
}

function Test-BRAVOOperationsLogThrottleElapsed {
    # Throttle для повторюваних, очікуваних-але-не-помилкових станів
    # (pending/404, TTL-expired, already_finalized) — щоб кожен
    # Send-BRAVOOperationsEvent/Heartbeat виклик (потенційно багато разів
    # за прогін) не спамив однаковим WARNING. $ThresholdMinutes типово 15.
    param(
        [AllowNull()][string]$LastLoggedAtUtc,
        [int]$ThresholdMinutes = 15
    )

    if ([string]::IsNullOrWhiteSpace($LastLoggedAtUtc)) {
        return $true
    }
    try {
        $last = [datetime]::Parse($LastLoggedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        return ((Get-Date).ToUniversalTime() - $last.ToUniversalTime()).TotalMinutes -ge $ThresholdMinutes
    } catch {
        return $true
    }
}

# ---------------------------------------------------------------------
# HTTP TRANSPORT
# ---------------------------------------------------------------------

function Join-BRAVOOperationsApiUrl {
    # E10 (base URL normalization): [Uri]::new($base, $relative) виконує
    # RFC 3986 relative-reference resolution — якщо $BaseUrl БЕЗ кінцевого
    # '/', ОСТАННІЙ сегмент бази відкидається перед приєднанням відносного
    # шляху. Для 'https://host:8443/api' + 'api/v1/enroll' це випадково
    # резолвиться правильно (відкинутий сегмент 'api' == перший сегмент
    # відносного шляху), але для 'https://host:8443/api/' (з кінцевим '/')
    # те саме приєднання дає ЗЛАМАНИЙ 'https://host:8443/api/api/v1/enroll'
    # (подвійний /api). Перевірено емпірично (throwaway [Uri]::new тест)
    # перед фіксом. Фікс: без Uri-резолюції взагалі — явна тримізація
    # кінцевих '/' у базі та початкових '/' у шляху, з'єднання рівно одним
    # '/'. Однаковий коректний результат незалежно від того, чи оператор
    # налаштував ApiBaseUrl з кінцевим слешем чи без нього.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $trimmedBase = $BaseUrl.TrimEnd('/')
    $trimmedPath = $Path.TrimStart('/')
    return "$trimmedBase/$trimmedPath"
}

function Get-BRAVOOperationsJsonPropertyString {
    # Set-StrictMode -Version 2.0 (активний у цьому файлі) кидає
    # PropertyNotFoundException на доступі до властивості, якої немає на
    # PSCustomObject (напр. ConvertFrom-Json результат, де optional-поле
    # API-контракту, як-от apiKey/claimToken/status у деяких відповідях,
    # ВІДСУТНЄ, а не просто $null — JSON.stringify на боці Express
    # відкидає undefined-поля цілком). Прямий `$obj.prop` під strict mode
    # ламається саме на цьому: PROD-виправлення, знайдене під час
    # написання self-test для TTL-expired approved-відповіді (apiKey
    # відсутнє в тілі), а не гіпотетичний edge case.
    [CmdletBinding()]
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -notcontains $Name) { return $null }
    return [string]$Object.$Name
}

function Get-BRAVOOperationsHttpStatusCode {
    # Класифікація HTTP-збою з ErrorRecord, кинутого Invoke-WebRequest
    # (non-2xx -> termінуюча System.Net.WebException з .Response = an
    # HttpWebResponse у PS 5.1). $null означає "не HTTP-статус взагалі"
    # (мережевий збій/timeout/DNS) — саме ці випадки трактуються як
    # transient і йдуть у outbox з retry/backoff.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -ne $response -and ($response.PSObject.Properties.Name -contains 'StatusCode')) {
            return [int]$response.StatusCode
        }
    } catch {
        # не HTTP-відповідь — трактуємо як мережевий/transient збій нижче
    }
    return $null
}

function Get-BRAVOOperationsHttpErrorBody {
    # Парсинг JSON-тіла помилки (напр. {error, status} на 409). Це вже НЕ
    # лише діагностика — POST /enroll's 409-гілка вище branches на
    # $errorCode ('claim_mismatch' vs already_finalized) і на
    # $finalStatus ('approved' vs 'revoked'/інше), тож ця функція мусить
    # надійно повертати реальне тіло, а не мовчки $null.
    #
    # G3 E2E fix: попередня реалізація читала тіло через
    # $response.GetResponseStream().ReadToEnd() -- на РЕАЛЬНОМУ Windows
    # PowerShell 5.1 (перевірено проти живого bsystem-operations API, не
    # мока) Invoke-WebRequest вже сам повністю вичитує response stream
    # non-2xx відповіді, щоб заповнити $ErrorRecord.ErrorDetails.Message
    # -- до моменту виклику цієї функції стрім уже на EOF, і повторний
    # ReadToEnd() мовчки повертає порожній рядок (не викидає -- swallow'
    # ed тим самим try/catch, що мав ловити СПРАВЖНІ помилки парсингу).
    # Наслідок був реальним і 100% відтворюваним, не теоретичним:
    # claim_mismatch/already_finalized НІКОЛИ фактично не розрізнялись
    # (обидва виглядали як "тіло відсутнє"), і -- після виправлення
    # already_finalized-гілки нижче, щоб не бути термінальною для
    # status=approved -- $finalStatus теж завжди виходив порожнім/
    # 'невідомо', тож навіть успішний approve назавжди трактувався як
    # неапрувнутий фінал. $ErrorRecord.ErrorDetails.Message -- це те, що
    # Invoke-WebRequest САМ уже прочитав з того самого стріму, і є
    # надійним джерелом тіла в PS 5.1; ручне читання стріму лишається
    # єдиним fallback-ом для гіпотетичних середовищ/версій, де
    # ErrorDetails порожній, а стрім усе ще не вичерпаний.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    try {
        $detailsText = $null
        if ($null -ne $ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ErrorDetails.Message)) {
            $detailsText = [string]$ErrorRecord.ErrorDetails.Message
        }
        if (-not [string]::IsNullOrWhiteSpace($detailsText)) {
            return ($detailsText | ConvertFrom-Json -ErrorAction Stop)
        }

        $response = $ErrorRecord.Exception.Response
        if ($null -eq $response) { return $null }
        $stream = $response.GetResponseStream()
        if ($null -eq $stream) { return $null }
        $reader = New-Object IO.StreamReader($stream)
        try {
            $text = $reader.ReadToEnd()
        } finally {
            $reader.Close()
        }
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Invoke-BRAVOOperationsApiRequest {
    # Спільний низькорівневий транспорт для enroll/events/heartbeat —
    # той самий HTTPS-only + TLS1.2 + timeout контракт, що
    # Send-BRAVOWebhookNotification (BRAVO.Compatibility), але з JSON
    # тілом і довільними заголовками (X-Api-Key/X-Bootstrap-Secret/
    # X-Enrollment-Claim) замість Discord/Slack payload-формату.
    #
    # НЕ ловить винятки сама (на відміну від публічних Send-*/Invoke-
    # BRAVOOperationsEnrollment) — виклики нижче явно класифікують
    # HTTP-статус (401 vs 404/409/400 vs 5xx/429 vs мережевий збій), тож
    # ковтати помилку тут втратило б цю інформацію.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST')][string]$Method,
        [hashtable]$Headers = @{},
        $Body,
        [int]$TimeoutSeconds = 30
    )

    $baseUri = $null
    if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$baseUri) -or
        $baseUri.Scheme -ne [Uri]::UriSchemeHttps) {
        throw "operationsReportingSettings.ApiBaseUrl не налаштовано або не використовує HTTPS"
    }
    $requestUrl = Join-BRAVOOperationsApiUrl -BaseUrl $BaseUrl -Path $Path

    Enable-BRAVOTls12
    $ProgressPreference = 'SilentlyContinue'

    $requestParameters = @{
        Uri = $requestUrl
        Method = $Method
        Headers = $Headers
        TimeoutSec = [math]::Max(1, $TimeoutSeconds)
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $requestParameters.ContentType = 'application/json; charset=utf-8'
        $requestParameters.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 6 -Compress))
    }

    $response = Invoke-WebRequest @requestParameters
    if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
        return $null
    }
    return ($response.Content | ConvertFrom-Json -ErrorAction Stop)
}

# ---------------------------------------------------------------------
# ENROLLMENT
# ---------------------------------------------------------------------

function Invoke-BRAVOOperationsEnrollment {
    # Ідемпотентна перевірка/спроба self-enrollment. Безпечна викликати
    # перед КОЖНОЮ подією/heartbeat: якщо API-ключ уже отримано —
    # миттєвий no-op (лише читання Credential Manager, без мережі).
    # Повертає API-ключ (string) при успіху, $null інакше (pending/
    # revoked/already_finalized/claim_mismatch/TTL-expired/не
    # сконфігуровано/мережевий збій) — виклик НІКОЛИ не кидає.
    #
    # A1-A7/D1-D7 (фінальний, ПОТОЧНИЙ контракт bsystem-operations —
    # замінив старий server-rotated-claim протокол, під який був написаний
    # попередній варіант цієї функції):
    #   - bootstrap-секрет ЛИШЕ в заголовку X-Bootstrap-Secret (POST і GET
    #     однаково), НЕ дублюється в тілі.
    #   - X-Enrollment-Claim ТЕПЕР обов'язковий і на POST, і на GET —
    #     АГЕНТ сам генерує цей claim (Get-BRAVOOperationsEnrollmentClaim,
    #     один раз на серверну ідентичність, персистентний), сервер його
    #     НІКОЛИ не видає й не ротує. 202-відповідь POST — це просто
    #     {status}, claimToken у ній більше немає (нема чого повертати —
    #     агент уже тримає свій claim).
    #   - A7 (lost-response recovery СПРОЩЕНО проти старого протоколу): що
    #     втрачена відповідь POST, що звичайний повторний виклик — це
    #     РІВНО той самий serverId+claim+metadata, що природно потрапляє в
    #     ідемпотентну 'updated'-гілку repository.upsertPendingServer, без
    #     жодної спеціальної обробки в цьому коді.
    #   - POST /enroll на вже фіналізований (approved/revoked) серверId
    #     повертає 409 {error:'already_finalized', status} — термінально
    #     для цієї спроби (як і раніше).
    #   - POST /enroll на ІНШИЙ claim, ніж уже збережений для pending
    #     серверId, повертає 409 {error:'claim_mismatch'} — НОВЕ; для
    #     цього коду це має бути практично недосяжно (claim стабільний і
    #     генерується лише цим агентом), тож трактується як термінальний
    #     сигнал можливого пошкодження/втрати локального enrollment-стану,
    #     не loop/retry.
    #   - 503 {error:'enrollment_not_configured'} — НОВЕ; відмінне від 401
    #     (невірний секрет): функціонал enrollment на бекенді взагалі не
    #     ввімкнено. Трактується як "ще не доступно" (та сама постава, що
    #     pending), throttled INFO-лог, без ERROR-спаму, без тісного
    #     retry.
    #   - GET без валідного claim -> 404 (навмисно невідрізнюваний від
    #     "не існує"/revoked/wrong-claim) -> трактується як "ще не
    #     готово", локальний pending-стан зберігається, лог throttled.
    #   - approved-відповідь БЕЗ apiKey означає TTL (5 хв) вичерпано —
    #     потрібне ручне admin reissue, агент сам це не вирішує.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'API-ключ приходить у JSON-тілі approve-відповіді Operations-бекенду (мережа за визначенням передає його як plaintext); SecureString тут — формат негайного зберігання в Credential Manager через Set-BRAVOCredential, а не джерело секрету. Змінна очищається у finally одразу після запису.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$OperationsReportingSettings,
        [Parameter(Mandatory = $true)][hashtable]$CredentialTargets,
        [Parameter(Mandatory = $true)][string]$InstitutionCode
    )

    $apiKeyTarget = [string]$CredentialTargets.OperationsApiKey
    try {
        $existingApiKey = Get-BRAVOCredentialSecret -Target $apiKeyTarget
        if (-not [string]::IsNullOrWhiteSpace($existingApiKey)) {
            return $existingApiKey
        }
    } catch {
        # Credential Manager недоступний узагалі — той самий шлях, що
        # "ще не enrolled", спроба enrollment нижче все одно нічого не
        # погіршить (і сама впаде на Set-BRAVOCredential з чіткою причиною
        # в лозі).
    }

    $apiBaseUrl = [string]$OperationsReportingSettings.ApiBaseUrl
    if ([string]::IsNullOrWhiteSpace($apiBaseUrl)) {
        # Fail-closed ДІАГНОСТИКА (review P2): Enabled=true, але ApiBaseUrl
        # порожній — це помилка конфігурації оператора, а не транзиєнтний
        # pending/мережевий стан. Раніше цей return був повністю мовчазним
        # (без жодного логу) — кожна подія/heartbeat просто зникала, і
        # оператор не мав жодного сигналу, чому dashboard нічого не бачить.
        # Throttled WARNING (той самий шаблон, що LastNotConfiguredLoggedAtUtc
        # нижче) — видимий, але не спамить лог на кожному Archive/Health/
        # Maintenance-прогоні.
        $apiBaseUrlMissingState = Get-BRAVOOperationsEnrollmentState
        if (Test-BRAVOOperationsLogThrottleElapsed -LastLoggedAtUtc $apiBaseUrlMissingState.LastApiBaseUrlMissingLoggedAtUtc) {
            Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
                -Message 'operationsReportingSettings.Enabled=true, але ApiBaseUrl порожній — Operations-звітність не працюватиме, доки оператор не вкаже коректний HTTPS-URL бекенду в конфігурації'
            $apiBaseUrlMissingState.LastApiBaseUrlMissingLoggedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            Set-BRAVOOperationsEnrollmentState -State $apiBaseUrlMissingState
        }
        return $null
    }

    $bootstrapSecretTarget = [string]$CredentialTargets.OperationsBootstrapSecret
    $bootstrapSecret = $null
    try {
        $bootstrapSecret = Get-BRAVOCredentialSecret -Target $bootstrapSecretTarget
    } catch {
        $bootstrapSecret = $null
    }
    if ([string]::IsNullOrWhiteSpace($bootstrapSecret)) {
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "operationsReportingSettings.Enabled=true, але bootstrap-секрет ($bootstrapSecretTarget) не знайдено в Credential Manager — enrollment неможливий"
        return $null
    }

    $productType = [string]$OperationsReportingSettings.ProductType
    if ($productType -notin @('LIMS', 'VETOFFICE')) {
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "operationsReportingSettings.ProductType = '$productType' не розпізнано (очікується LIMS/VETOFFICE) — enrollment пропущено"
        return $null
    }

    $serverId = Get-BRAVOOperationsServerId
    if ([string]::IsNullOrWhiteSpace($serverId)) {
        # E9: Get-BRAVOOperationsServerId уже залогувала ERROR (пошкоджений
        # state-файл) — тут просто пропускаємо enrollment цей прогін.
        return $null
    }
    $timeoutSeconds = [int]$OperationsReportingSettings.RequestTimeoutSeconds

    $claim = Get-BRAVOOperationsEnrollmentClaim
    $enrollmentState = Get-BRAVOOperationsEnrollmentState
    # Гарантія проти застарілого знімка стану: Get-BRAVOOperationsEnrollmentClaim
    # МІГ щойно згенерувати й персистувати НОВИЙ claim (перший запуск для
    # цієї ідентичності) незалежно від $enrollmentState, зчитаного рядком
    # вище -- без цього присвоєння будь-який ПОДАЛЬШИЙ
    # Set-BRAVOOperationsEnrollmentState нижче (throttle-мітки pending/
    # TTL/already_finalized/not_configured) переписав би файл стану СТАРИМ
    # знімком і мовчки СТЕР би щойно збережений Claim із диска.
    $enrollmentState.Claim = $claim

    # POST /enroll: завжди намагаємось (навіть якщо серверId уже мав
    # попередню pending-спробу) — A7: агент несе РІВНО той самий
    # serverId+claim+metadata щоразу, тож повторний POST після втраченої
    # відповіді природно потрапляє в ідемпотентну 'updated'-гілку на
    # сервері; якщо серверId уже фіналізований — 409 already_finalized
    # нижче; якщо (аномально) claim розійшовся з уже збереженим для цього
    # pending серверId — 409 claim_mismatch нижче.
    try {
        $enrollResult = Invoke-BRAVOOperationsApiRequest `
            -BaseUrl $apiBaseUrl -Path '/api/v1/enroll' -Method 'POST' `
            -Headers @{ 'X-Bootstrap-Secret' = $bootstrapSecret; 'X-Enrollment-Claim' = $claim } `
            -Body @{
                serverId = $serverId
                institutionCode = $InstitutionCode
                productType = $productType
                hostname = $env:COMPUTERNAME
            } `
            -TimeoutSeconds $timeoutSeconds
    } catch {
        $statusCode = Get-BRAVOOperationsHttpStatusCode -ErrorRecord $_
        if ($statusCode -eq 503) {
            # A5: enrollment взагалі не сконфігуровано на бекенді (немає
            # bootstrap-секрету) — відмінно від 401 (невірний секрет).
            # Та сама постава, що pending: не помилка, не спамимо ERROR/
            # WARNING, просто зачекаємо наступного природного циклу.
            if (Test-BRAVOOperationsLogThrottleElapsed -LastLoggedAtUtc $enrollmentState.LastNotConfiguredLoggedAtUtc) {
                Write-BRAVOLog -Component 'Operations' -Level 'INFO' `
                    -Message 'Operations enrollment ще не сконфігуровано на боці API (503 enrollment_not_configured) — очікуємо, поки бекенд увімкне цю функцію; це НЕ помилка бажаного секрету (401), а відсутність самої можливості'
                $enrollmentState.LastNotConfiguredLoggedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                Set-BRAVOOperationsEnrollmentState -State $enrollmentState
            }
            return $null
        }
        if ($statusCode -eq 409) {
            $errorBody = Get-BRAVOOperationsHttpErrorBody -ErrorRecord $_
            $errorCode = Get-BRAVOOperationsJsonPropertyString -Object $errorBody -Name 'error'
            if ($errorCode -eq 'claim_mismatch') {
                # A3: наш локально збережений claim розійшовся з тим, що
                # вже збережений на сервері для цього (все ще pending)
                # серверId. За коректної роботи цього агента (стабільний,
                # ніколи не ротований claim) це має бути практично
                # недосяжно — сигнал, що локальний enrollment-стан
                # (Get-BRAVOOperationsEnrollmentStatePath) було втрачено/
                # пошкоджено і згенеровано НОВИЙ claim поверх уже
                # існуючого pending серверId. Термінально для цієї
                # спроби — НЕ ретраїмо тісно (сама лише повторна спроба з
                # тим же новим claim дасть той самий 409 знову).
                Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
                    -Message "POST /enroll відхилено (409 claim_mismatch) — локальний enrollment-claim НЕ збігається з тим, що вже збережений на сервері для серверId=$serverId. Це означає локальний стан ($((Get-BRAVOOperationsEnrollmentStatePath))) було втрачено/пошкоджено після початкового enrollment. Термінально для цієї спроби: САМООБСЛУГОВУВАННЯ НЕ виконується (щоб не мати вигляду takeover-спроби); якщо цей сервер дійсно мав бути новою ідентичністю, свідомо видаліть server-id/enrollment state-файли для повного повторного enrollment."
                return $null
            }
            $finalStatusRaw = Get-BRAVOOperationsJsonPropertyString -Object $errorBody -Name 'status'
            $finalStatus = if (-not [string]::IsNullOrWhiteSpace($finalStatusRaw)) { $finalStatusRaw } else { 'невідомо' }
            if ($finalStatus -eq 'approved') {
                # G3 E2E fix: 409 already_finalized/status=approved is NOT
                # terminal the way revoked is. POST /enroll is attempted
                # unconditionally on every call (see A7 comment above) --
                # so the very first call after an admin approves a
                # still-pending server will ALWAYS hit this branch (the
                # row is already 'approved' by the time this POST runs),
                # before this function has ever had a chance to reach the
                # GET /enroll/{serverId} poll below that actually returns
                # the apiKey. Treating this as terminal here (the previous
                # behavior: `return $null` unconditionally) meant the
                # agent could NEVER retrieve its API key through the
                # normal periodic enrollment call -- every real
                # pending->approved transition would permanently strand
                # the agent, confirmed by a real cross-repo E2E run
                # against a live bsystem-operations API (Wave 2 gate G3).
                # Falling through to the GET poll below (instead of
                # returning) fetches the apiKey normally; the GET path
                # already correctly reports the TTL-expired case
                # (approved-without-apiKey -> needs manual admin reissue)
                # if the 5-minute window has passed.
                if (Test-BRAVOOperationsLogThrottleElapsed -LastLoggedAtUtc $enrollmentState.LastNotReadyLoggedAtUtc) {
                    Write-BRAVOLog -Component 'Operations' -Level 'INFO' `
                        -Message 'POST /enroll відхилено (409 already_finalized, status=approved) — сервер уже підтверджено адміністратором; переходимо одразу до GET /enroll/{serverId} для отримання API-ключа.'
                }
            } else {
                if (Test-BRAVOOperationsLogThrottleElapsed -LastLoggedAtUtc $enrollmentState.LastFinalizedLoggedAtUtc) {
                    Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
                        -Message "Сервер уже фіналізований в Operations (status=$finalStatus) — POST /enroll відхилено (409 already_finalized). Це термінально для цього серверного ідентифікатора: звітність зупинена до нового enrollment адміністратором."
                    $enrollmentState.LastFinalizedLoggedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                    Set-BRAVOOperationsEnrollmentState -State $enrollmentState
                }
                return $null
            }
        } else {
            Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
                -Message "Не вдалося зареєструвати сервер в Operations (enroll): $($_.Exception.Message)"
            return $null
        }
    }
    # A1/A2: 202-відповідь — лише {status}, claimToken більше не
    # повертається (нема чого повертати — claim уже в нас, локально). Тут
    # свідомо НЕ читаємо/не очікуємо жодного claim-поля з $enrollResult.

    try {
        $pollResult = Invoke-BRAVOOperationsApiRequest `
            -BaseUrl $apiBaseUrl -Path "/api/v1/enroll/$serverId" -Method 'GET' `
            -Headers @{ 'X-Bootstrap-Secret' = $bootstrapSecret; 'X-Enrollment-Claim' = $claim } `
            -TimeoutSeconds $timeoutSeconds
    } catch {
        $statusCode = Get-BRAVOOperationsHttpStatusCode -ErrorRecord $_
        if ($statusCode -eq 503) {
            # A5, symmetrically to POST above.
            if (Test-BRAVOOperationsLogThrottleElapsed -LastLoggedAtUtc $enrollmentState.LastNotConfiguredLoggedAtUtc) {
                Write-BRAVOLog -Component 'Operations' -Level 'INFO' `
                    -Message 'Operations enrollment ще не сконфігуровано на боці API (503 enrollment_not_configured) на GET-опитуванні статусу — очікуємо наступного природного циклу'
                $enrollmentState.LastNotConfiguredLoggedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                Set-BRAVOOperationsEnrollmentState -State $enrollmentState
            }
            return $null
        }
        if ($statusCode -eq 404) {
            # D7: 404 тут навмисно невідрізнюваний бекендом від "невідомий
            # id"/"revoked"/"неправильний claim" — трактуємо як "ще не
            # готово", зберігаємо локальний pending-стан (claim лишається),
            # логуємо throttled, НЕ спамимо і НЕ зациклюємось тісно (той
            # самий виклик відбудеться природно на наступній події/
            # heartbeat).
            if (Test-BRAVOOperationsLogThrottleElapsed -LastLoggedAtUtc $enrollmentState.LastNotReadyLoggedAtUtc) {
                Write-BRAVOLog -Component 'Operations' -Level 'INFO' `
                    -Message 'Сервер ще не готовий в Operations (pending/не знайдено з поточним claim) — очікуємо ручного підтвердження в UI'
                $enrollmentState.LastNotReadyLoggedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                Set-BRAVOOperationsEnrollmentState -State $enrollmentState
            }
            return $null
        }
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Не вдалося опитати статус enrollment в Operations: $($_.Exception.Message)"
        return $null
    }

    if ($null -eq $pollResult) {
        return $null
    }
    $status = Get-BRAVOOperationsJsonPropertyString -Object $pollResult -Name 'status'
    if ($status -eq 'revoked') {
        # Захисна гілка: реальний бекенд віддає 404 (не 200/revoked) для
        # revoked-серверів (перехоплено в catch вище). Лишено як-є —
        # нешкідливо, і покриває гіпотетичну майбутню зміну контракту.
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Сервер відкликано (revoked) в Operations — звітність призупинена, доки адміністратор не перевидасть доступ"
        # НЕ Clear-BRAVOOperationsEnrollmentState: claim лишається (той
        # самий D1-інваріант, що й у success-гілці нижче) — якщо
        # адміністратор колись зробить revoked->approved reissue для ЦІЄЇ
        # ж ідентичності, наступний GET має нести ТОЙ САМИЙ claim.
        return $null
    }
    if ($status -ne 'approved') {
        # pending — очікуваний стан до ручного підтвердження в Operations
        # UI; не помилка, спроба повториться на наступній події/heartbeat.
        return $null
    }

    $apiKeyFromPoll = Get-BRAVOOperationsJsonPropertyString -Object $pollResult -Name 'apiKey'
    if ([string]::IsNullOrWhiteSpace($apiKeyFromPoll)) {
        # D3: approved, але apiKey відсутній — 5-хвилинне вікно доступності
        # ключа після approve/reissue вичерпано. Це НЕ transient мережевий
        # збій: повторний тісний retry нічого не змінить, потрібне ручне
        # admin reissue. Логуємо throttled (нормальний poll-cadence, не
        # тісний цикл).
        #
        # Review finding (reveal window vs poll cadence, thread 6): цей GET
        # /enroll-поллінг виконується лише ПОБІЧНО, як частина кожного
        # Send-BRAVOOperationsEvent/Heartbeat (Archive/Health/Maintenance-
        # прогону чи ручного BRAVO_OPERATIONS_HEARTBEAT.ps1) — жодного
        # виділеного heartbeat-розкладу наразі не реєструє
        # BRAVO_TASKS_INSTALL.ps1 (свідоме рішення цієї хвилі, PR #225
        # thread 7: сира конфігурація HeartbeatIntervalMinutes видалена як
        # orphaned, а не вдягнута в необкатаний Scheduled Task). Дефолтний
        # Health-інтервал (schedulerSettings.Health.RepeatEveryMinutes,
        # типово 240 хв) НАБАГАТО перевищує 5-хвилинне вікно видачі ключа
        # — типовий сервер практично ЗАВЖДИ пропустить вікно між approve/
        # reissue й наступним природним поллінгом. 5-хвилинне вікно —
        # рішення бекенду bsystem-operations (інший репозиторій, не в
        # межах цієї зміни); наразі єдина надійна дія оператора: одразу
        # ПІСЛЯ approve/reissue в Operations UI вручну запустити
        # BRAVO_OPERATIONS_HEARTBEAT.ps1 на цьому сервері (чи дочекатись
        # найближчого Archive/Health/Maintenance-прогону, якщо він
        # природно потрапляє в 5-хвилинне вікно).
        if (Test-BRAVOOperationsLogThrottleElapsed -LastLoggedAtUtc $enrollmentState.LastTtlExpiredLoggedAtUtc) {
            Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
                -Message 'Сервер approved в Operations, але API-ключ більше недоступний (5-хвилинне вікно видачі вичерпано) — потрібне ручне admin reissue в Operations UI; ОДРАЗУ ПІСЛЯ reissue вручну запустіть BRAVO_OPERATIONS_HEARTBEAT.ps1 на цьому сервері (наступний природний Archive/Health/Maintenance-прогін може не встигнути в 5-хвилинне вікно — типовий Health-інтервал 240 хв). Агент сам НЕ намагатиметься "самовиправитись" тісним retry.'
            $enrollmentState.LastTtlExpiredLoggedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            Set-BRAVOOperationsEnrollmentState -State $enrollmentState
        }
        return $null
    }

    $newApiKey = $apiKeyFromPoll
    try {
        $secureApiKey = ConvertTo-SecureString -String $newApiKey -AsPlainText -Force
        Set-BRAVOCredential -Target $apiKeyTarget -Secret $secureApiKey
    } finally {
        $secureApiKey = $null
    }
    # A1/A2 (F4): НАВМИСНО НЕ викликаємо Clear-BRAVOOperationsEnrollmentState
    # тут — на відміну від старого server-rotated-claim протоколу (де
    # claimToken був одноразовим і безпечно скидався після approve), Claim
    # тепер ідентифікаційний і має жити ВЕСЬ час життя цієї серверної
    # ідентичності (D1: наступний GET /enroll/:id — напр. після майбутнього
    # TTL-вікна reissue, чи після 401->re-enroll циклу E11 — МУСИТЬ нести
    # ТОЙ САМИЙ claim, бо claimMatches на сервері звіряє його з
    # enrollment_claim_hash, збереженим при першому POST; новий claim тут
    # означав би постійну 404 на всіх майбутніх GET-опитуваннях цього
    # серверId). Throttle-мітки (LastNotReadyLoggedAtUtc тощо) в цьому ж
    # файлі лишаються як є — застарілі, але нешкідливі (природно
    # перезаписуються за потреби).
    # E8: bootstrap-секрет НЕ видаляється автоматично тут (рішення
    # свідоме, задокументоване в модульному коментарі нижче,
    # Remove-BRAVOOperationsBootstrapSecretIfUnneeded) — лише
    # інформативний SUCCESS-лог про те, що видалення тепер безпечне.
    Write-BRAVOLog -Component 'Operations' -Level 'SUCCESS' `
        -Message "Сервер підтверджено (approved) в Operations — API-ключ збережено. Bootstrap-секрет ($bootstrapSecretTarget) більше не потрібен ЦЬОМУ серверу і може бути видалений тим, хто керує provisioning Credential Manager, якщо це бажано (модуль сам його не видаляє — див. коментар E8 у BRAVO.Operations.psm1)."
    return $newApiKey
}

# ---------------------------------------------------------------------
# EVENT ENVELOPE + OUTBOX (E3/E4/E6/E7)
# ---------------------------------------------------------------------
#
# Design decision (E3/E6): один JSON-файл на подію в
# Get-BRAVOOperationsOutboxDirectory, а не єдиний append-only
# journal-файл. Причини:
#   1. Атомарність під частковий збій (raptор/reboot/crash посеред
#      запису) простіша й уже перевірена в цьому файлі — той самий
#      write-to-temp-then-Replace/Move патерн, що Get-BRAVOOperationsServerId
#      використовував локально ще до цієї роботи (тепер винесений у
#      Write-BRAVOOperationsAtomicJsonFile). Append-only лог вимагав би
#      власної compaction-логіки (позначення "спожитих" рядків, періодичне
#      переписування файлу) — ще одна атомарна операція, яку довелось би
#      writе-to-temp-then-Replace ЗАНОВО поверх ВЖЕ growing файлу.
#   2. Часткова відмова легша для розуміння: один невдалий item — один
#      файл, що просто лишається на диску; успішні сусіди видаляються
#      незалежно. Спільний лог вимагав би або transactional rewrite
#      кожного разу (дорого при частих подіях), або risk consumer'а, що
#      читає файл, поки інший процес його дописує.
#   3. Кілька процесів (heartbeat entrypoint + основні
#      Archive/Health/Maintenance запуски) можуть теоретично дренувати
#      outbox одночасно — окремі файли з унікальними іменами (eventId)
#      природно уникають lock-контенції; спільний файл вимагав би
#      явного файлового locking.
# Ціна: багато дрібних файлів при довгій відмові API — прийнятно для
# обсягу подій цього агента (одиниці/десятки за прогін, не тисячі).

function New-BRAVOOperationsEventEnvelope {
    # E4/E7: eventId/occurredAt/schemaVersion генеруються ТУТ, у момент
    # створення події (виклику Send-BRAVOOperationsEvent/Heartbeat) — НЕ
    # в момент фактичної відправки/дренажу outbox. Це навмисно: якщо
    # відправку доведеться повторити (transient збій -> outbox -> drain),
    # повторна спроба має нести ТОЙ САМИЙ eventId (ідемпотентність на
    # UNIQUE(server_id, event_id) стороні API) і ТОЙ САМИЙ occurredAt
    # (коли подія РЕАЛЬНО сталась на агенті, а не коли її врешті вдалось
    # доставити після можливо довгого outage).
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        EventId = [guid]::NewGuid().ToString()
        OccurredAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        SchemaVersion = 1
    }
}

function Get-BRAVOOperationsOutboxBackoffSeconds {
    # Обмежений експоненційний backoff: 30s, 60s, 120s, ... до стелі 30хв.
    # Без jitter (детермінованість спрощує тестування; єдиний агент на
    # сервер, тож "thundering herd" на один API-інстанс не релевантний
    # так, як для тисяч незалежних клієнтів).
    [CmdletBinding()]
    param([int]$AttemptCount)

    $capped = [math]::Min([math]::Max(1, $AttemptCount), 12)
    $seconds = 30 * [math]::Pow(2, $capped - 1)
    return [int][math]::Min($seconds, 1800)
}

function Get-BRAVOOperationsOutboxItemPath {
    param(
        [Parameter(Mandatory = $true)][string]$EventId,
        [switch]$DeadLetter
    )

    $safeName = ($EventId -replace '[^A-Za-z0-9\-_]', '_')
    $directory = if ($DeadLetter) { Get-BRAVOOperationsOutboxDeadLetterDirectory } else { Get-BRAVOOperationsOutboxDirectory }
    return (Join-Path $directory ("$safeName.json"))
}

function Add-BRAVOOperationsOutboxItem {
    # Кладе подію/heartbeat в durable outbox — викликається, коли негайна
    # спроба відправки впала на transient збої (мережа/timeout/5xx/429).
    # Never-throw: помилка запису в outbox лише логується, подія просто
    # губиться (той самий ризик, що й старий "log WARNING and drop").
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('event', 'heartbeat')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$EventId,
        [Parameter(Mandatory = $true)][string]$OccurredAtUtc,
        [Parameter(Mandatory = $true)][int]$SchemaVersion,
        [Parameter(Mandatory = $true)][string]$ApiPath,
        [Parameter(Mandatory = $true)][hashtable]$RequestBody,
        [int]$AttemptCount = 1,
        [string]$LastError,
        [int]$MaxOutboxItems = 500
    )

    try {
        # Bounded outbox size (thread 5 fix companion): Send-BRAVOOperationsEvent
        # тепер буферизує події сюди й тоді, коли enrollment ще pending (не
        # лише при transient HTTP-збоях) — без цієї межі постійно pending/
        # revoked ідентичність могла б накопичувати items необмежено.
        # Найстаріші items (за FIFO/EnqueuedAtUtc) витісняються в dead-letter
        # (сам dead-letter теж має власну bounded ретенцію, 200 файлів).
        try {
            $existingItems = Get-BRAVOOperationsOutboxItems
            $existingCount = @($existingItems).Count
            if ($existingCount -ge $MaxOutboxItems) {
                $evictCount = ($existingCount - $MaxOutboxItems) + 1
                foreach ($stale in @($existingItems | Select-Object -First $evictCount)) {
                    Move-BRAVOOperationsOutboxItemToDeadLetter -Item $stale -Reason "Outbox переповнено (ліміт $MaxOutboxItems items) — найстаріший item витіснено"
                }
                Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
                    -Message "Outbox Operations переповнено (ліміт $MaxOutboxItems) — витіснено $evictCount найстаріших item(ів) у dead-letter"
            }
        } catch {
            # Never-throw: якщо перевірка розміру outbox сама впала, все одно
            # продовжуємо запис нового item — краще ризикнути тимчасовим
            # переповненням, ніж втратити цю подію взагалі.
        }

        $item = [pscustomobject]@{
            Kind = $Kind
            EventId = $EventId
            OccurredAtUtc = $OccurredAtUtc
            SchemaVersion = $SchemaVersion
            ApiPath = $ApiPath
            RequestBody = $RequestBody
            EnqueuedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            AttemptCount = $AttemptCount
            NextRetryAtUtc = (Get-Date).ToUniversalTime().AddSeconds((Get-BRAVOOperationsOutboxBackoffSeconds -AttemptCount $AttemptCount)).ToString('o')
            LastError = $LastError
        }
        Write-BRAVOOperationsAtomicJsonFile -Path (Get-BRAVOOperationsOutboxItemPath -EventId $EventId) -Object $item
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Подію Operations ($Kind, eventId=$EventId) не вдалося доставити негайно — поставлено в локальний outbox для повторної спроби"
    } catch {
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Не вдалося поставити подію Operations ($Kind, eventId=$EventId) в outbox: $($_.Exception.Message) — подію втрачено"
    }
}

function Get-BRAVOOperationsOutboxItems {
    # Повертає pscustomobject-и, зчитані з outbox (без DeadLetter),
    # відсортовані за EnqueuedAtUtc (FIFO) — стабільний порядок дренажу.
    # Пошкоджений item-файл видаляється (не заважає решті) — сам факт
    # непарсованості означає, що подія вже втрачена, тримати сміттєвий
    # файл сенсу немає.
    [CmdletBinding()]
    param()

    $directory = Get-BRAVOOperationsOutboxDirectory
    $items = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return $items.ToArray()
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $parsed = ([IO.File]::ReadAllText($file.FullName, (New-Object Text.UTF8Encoding($false))) | ConvertFrom-Json -ErrorAction Stop)
            $parsed | Add-Member -MemberType NoteProperty -Name '__Path' -Value $file.FullName -Force
            [void]$items.Add($parsed)
        } catch {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return @($items | Sort-Object -Property EnqueuedAtUtc)
}

function Move-BRAVOOperationsOutboxItemToDeadLetter {
    # Немає сенсу ретраяти справжню 4xx-помилку валідації (напр. 400
    # malformed payload) — вона не стане "успішною" з часом. Переносимо
    # у DeadLetter/ (не видаляємо одразу) для можливого ручного розбору,
    # з обмеженою ретенцією (найновіші 200 файлів), щоб не рости
    # необмежено на сервері, де ця помилка повторюється систематично.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [string]$Reason
    )

    try {
        $deadLetterDirectory = Get-BRAVOOperationsOutboxDeadLetterDirectory
        if (-not (Test-Path -LiteralPath $deadLetterDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $deadLetterDirectory -Force)
        }
        $Item | Add-Member -MemberType NoteProperty -Name 'DeadLetteredAtUtc' -Value ((Get-Date).ToUniversalTime().ToString('o')) -Force
        $Item | Add-Member -MemberType NoteProperty -Name 'DeadLetterReason' -Value $Reason -Force
        $targetPath = Get-BRAVOOperationsOutboxItemPath -EventId ([string]$Item.EventId) -DeadLetter
        Write-BRAVOOperationsAtomicJsonFile -Path $targetPath -Object $Item
        if ($Item.PSObject.Properties.Name -contains '__Path' -and [IO.File]::Exists([string]$Item.__Path)) {
            Remove-Item -LiteralPath ([string]$Item.__Path) -Force -ErrorAction SilentlyContinue
        }

        $deadLetterFiles = @(Get-ChildItem -LiteralPath $deadLetterDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
        if ($deadLetterFiles.Count -gt 200) {
            foreach ($stale in @($deadLetterFiles | Select-Object -Skip 200)) {
                Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Не вдалося перемістити подію Operations (eventId=$([string]$Item.EventId)) у dead-letter: $($_.Exception.Message)"
    }
}

function Remove-BRAVOOperationsOutboxItem {
    param([Parameter(Mandatory = $true)]$Item)

    try {
        if ($Item.PSObject.Properties.Name -contains '__Path' -and [IO.File]::Exists([string]$Item.__Path)) {
            Remove-Item -LiteralPath ([string]$Item.__Path) -Force -ErrorAction SilentlyContinue
        }
    } catch {
        # best effort
    }
}

function Update-BRAVOOperationsOutboxItemAfterFailure {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [string]$LastError
    )

    try {
        $nextAttempt = [int]$Item.AttemptCount + 1
        $Item.AttemptCount = $nextAttempt
        $Item.NextRetryAtUtc = (Get-Date).ToUniversalTime().AddSeconds((Get-BRAVOOperationsOutboxBackoffSeconds -AttemptCount $nextAttempt)).ToString('o')
        $Item.LastError = $LastError
        $path = if ($Item.PSObject.Properties.Name -contains '__Path') { [string]$Item.__Path } else { Get-BRAVOOperationsOutboxItemPath -EventId ([string]$Item.EventId) }
        $toWrite = $Item | Select-Object * -ExcludeProperty __Path
        Write-BRAVOOperationsAtomicJsonFile -Path $path -Object $toWrite
    } catch {
        # best effort — item лишиться зі старим NextRetryAtUtc, дренаж
        # спробує його знову раніше, ніж "заслужив"; нешкідливо.
    }
}

function Clear-BRAVOOperationsInvalidCredential {
    # E11: 401 на X-Api-Key запиті означає credential більше не валідний
    # (revoked адміністратором, або інша інвалідизація на стороні API) —
    # НЕ transient мережевий збій. Очищення локального ключа гарантує, що
    # наступний виклик Invoke-BRAVOOperationsEnrollment природно піде по
    # звичайному enroll+poll шляху (де вже коректно зупиняється на
    # revoked/already_finalized, а не намагається "самополагодитись").
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$CredentialTargets)

    try {
        $apiKeyTarget = [string]$CredentialTargets.OperationsApiKey
        [void](Remove-BRAVOCredential -Target $apiKeyTarget)
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Operations API-ключ ($apiKeyTarget) відхилено сервером (401) — трактуємо як відкликаний/недійсний, локальний ключ видалено. Наступний цикл спробує звичайний enrollment заново (природно зупиниться, якщо сервер дійсно revoked)."
    } catch {
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Operations API-ключ відхилено сервером (401), але не вдалося видалити локальний збережений ключ: $($_.Exception.Message)"
    }
}

function Send-BRAVOOperationsEnvelope {
    # Спільна логіка "спробувати негайно; на transient збій -> outbox; на
    # 401 -> інвалідизація credential; на іншу 4xx -> dead-letter" для
    # event і heartbeat. Never-throw.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ApiBaseUrl,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [Parameter(Mandatory = $true)][hashtable]$CredentialTargets,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][ValidateSet('event', 'heartbeat')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$ApiPath,
        [Parameter(Mandatory = $true)][hashtable]$RequestBody,
        [Parameter(Mandatory = $true)][string]$EventId,
        [Parameter(Mandatory = $true)][string]$OccurredAtUtc,
        [Parameter(Mandatory = $true)][int]$SchemaVersion
    )

    try {
        [void](Invoke-BRAVOOperationsApiRequest `
            -BaseUrl $ApiBaseUrl -Path $ApiPath -Method 'POST' `
            -Headers @{ 'X-Api-Key' = $ApiKey } `
            -Body $RequestBody `
            -TimeoutSeconds $TimeoutSeconds)
        return $true
    } catch {
        $statusCode = Get-BRAVOOperationsHttpStatusCode -ErrorRecord $_
        if ($statusCode -eq 401) {
            Clear-BRAVOOperationsInvalidCredential -CredentialTargets $CredentialTargets
            # Не enqueue: цей самий ключ ніколи не стане валідним — outbox
            # ретраяв би вічно марно. Подія для ЦІЄЇ спроби втрачається
            # (той самий залишковий ризик, що й попередня поведінка "log
            # and drop"); наступний успішний enrollment почне з чистого
            # потоку нових подій.
            return $false
        }
        if ($null -ne $statusCode -and $statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429) {
            # Справжня помилка валідації (напр. 400) — не транзиєнтна,
            # ретрай нічого не змінить. Dead-letter, не тісний retry-цикл.
            $item = [pscustomobject]@{
                Kind = $Kind
                EventId = $EventId
                OccurredAtUtc = $OccurredAtUtc
                SchemaVersion = $SchemaVersion
                ApiPath = $ApiPath
                RequestBody = $RequestBody
                EnqueuedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                AttemptCount = 1
            }
            Move-BRAVOOperationsOutboxItemToDeadLetter -Item $item -Reason "HTTP $statusCode при першій спробі: $($_.Exception.Message)"
            Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
                -Message "Подію Operations ($Kind, eventId=$EventId) відхилено як невалідну (HTTP $statusCode) — переміщено в dead-letter, повтор не матиме сенсу"
            return $false
        }
        # Мережевий збій / timeout / 5xx / 429 — transient, у durable outbox.
        Add-BRAVOOperationsOutboxItem -Kind $Kind -EventId $EventId -OccurredAtUtc $OccurredAtUtc `
            -SchemaVersion $SchemaVersion -ApiPath $ApiPath -RequestBody $RequestBody `
            -AttemptCount 1 -LastError $_.Exception.Message
        return $false
    }
}

function Invoke-BRAVOOperationsOutboxDrain {
    # E3/E6: опортуністичний дренаж durable outbox — викликається на
    # початку кожного Send-BRAVOOperationsEvent/Send-BRAVOOperationsHeartbeat
    # (після успішного enrollment, тобто коли валідний API-ключ уже є).
    # Обробляє items у FIFO-порядку, лише ті, чий NextRetryAtUtc уже
    # настав (bounded backoff per item, щоб не "молотити" ще недоступний
    # API). Never-throw: помилка дренажу одного item лишає його в outbox
    # для наступної спроби, не зупиняє обробку решти (крім 401, який
    # зупиняє дренаж повністю — тим самим ключем усі решта items так само
    # впадуть).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ApiBaseUrl,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [Parameter(Mandatory = $true)][hashtable]$CredentialTargets,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [int]$MaxItemsPerDrain = 200,
        [int]$MaxDrainDurationSeconds = 60
    )

    try {
        $items = Get-BRAVOOperationsOutboxItems
        $now = (Get-Date).ToUniversalTime()
        $drainStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $processedCount = 0
        foreach ($item in $items) {
            if ($processedCount -ge $MaxItemsPerDrain -or
                $drainStopwatch.Elapsed.TotalSeconds -ge $MaxDrainDurationSeconds) {
                $remainingCount = @($items).Count - $processedCount
                Write-BRAVOLog -Component 'Operations' -Level 'WARNING' -Message "Дренаж Operations outbox зупинено достроково (ліміт items=$MaxItemsPerDrain, ліміт часу=${MaxDrainDurationSeconds}с) - залишилось items у черзі для наступного дренажу: $remainingCount"
                break
            }

            $nextRetry = $now
            try {
                $nextRetry = [datetime]::Parse([string]$item.NextRetryAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            } catch {
                $nextRetry = $now
            }
            if ($nextRetry -gt $now) {
                continue
            }
            $processedCount++

            # Isolate-per-item (review P2): якщо item — валідний JSON, але
            # RequestBody відсутнє/не об'єкт (схемна зміна, ручне
            # відновлення, локальна пошкодженість) — PSObject.Properties
            # на $null/не-об'єкті кидає виняток. Раніше він летів у
            # ЗОВНІШНІЙ try функції (нижче), зупиняючи дренаж ЦІЛКОМ:
            # жодного remove/dead-letter для цього item, тож він лишався б
            # першим у FIFO-черзі і "отруював" би обробку ВСІХ наступних
            # items на КОЖНОМУ наступному прогоні. Тепер такий item сам
            # dead-letter-иться і drain продовжує решту.
            $requestBodyHashtable = $null
            try {
                $requestBodyHashtable = @{}
                if ($null -eq $item.RequestBody -or $item.RequestBody -isnot [PSCustomObject]) {
                    throw "RequestBody відсутнє або має неочікуваний тип: $(if ($null -eq $item.RequestBody) { '<null>' } else { $item.RequestBody.GetType().FullName })"
                }
                foreach ($property in $item.RequestBody.PSObject.Properties) {
                    $requestBodyHashtable[$property.Name] = $property.Value
                }
            } catch {
                Move-BRAVOOperationsOutboxItemToDeadLetter -Item $item -Reason "Пошкоджений outbox item (невалідне RequestBody) при дренажі: $($_.Exception.Message)"
                Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
                    -Message "Пошкоджений outbox item (eventId=$([string]$item.EventId)) переміщено в dead-letter при дренажі — решта черги обробляється далі"
                continue
            }

            try {
                [void](Invoke-BRAVOOperationsApiRequest `
                    -BaseUrl $ApiBaseUrl -Path ([string]$item.ApiPath) -Method 'POST' `
                    -Headers @{ 'X-Api-Key' = $ApiKey } `
                    -Body $requestBodyHashtable `
                    -TimeoutSeconds $TimeoutSeconds)
                Remove-BRAVOOperationsOutboxItem -Item $item
                Write-BRAVOLog -Component 'Operations' -Level 'SUCCESS' `
                    -Message "Подію Operations з outbox доставлено (eventId=$([string]$item.EventId))"
            } catch {
                $statusCode = Get-BRAVOOperationsHttpStatusCode -ErrorRecord $_
                if ($statusCode -eq 401) {
                    Clear-BRAVOOperationsInvalidCredential -CredentialTargets $CredentialTargets
                    # Цей і решта items у цій пачці не будуть доставлені
                    # тим самим ключем — зупиняємо дренаж, лишаючи їх в
                    # outbox для дренажу вже НОВИМ ключем після наступного
                    # успішного enrollment.
                    return
                }
                if ($null -ne $statusCode -and $statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429) {
                    Move-BRAVOOperationsOutboxItemToDeadLetter -Item $item -Reason "HTTP $statusCode при дренажі: $($_.Exception.Message)"
                    continue
                }
                Update-BRAVOOperationsOutboxItemAfterFailure -Item $item -LastError $_.Exception.Message
            }
        }
    } catch {
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Дренаж Operations outbox завершився з помилкою: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------
# PUBLIC SEND API
# ---------------------------------------------------------------------

function Send-BRAVOOperationsEvent {
    # Відправляє ОДНУ подію в Operations. Наслідує Q18 грилінгу: severity
    # тут НЕ фільтрується через NotificationMode/RoutingTable — Operations
    # отримує SUCCESS так само, як WARNING/ERROR/CRITICAL, незалежно від
    # того, як налаштований Discord/Slack-провайдер.
    #
    # E4/E7: envelope (eventId/occurredAt/schemaVersion) фіксується ТУТ,
    # на вході — перед будь-якою мережевою спробою чи постановкою в outbox
    # — щоб повторна спроча (з outbox) несла той самий eventId/occurredAt.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$OperationsReportingSettings,
        [Parameter(Mandatory = $true)][hashtable]$CredentialTargets,
        [Parameter(Mandatory = $true)][string]$InstitutionCode,

        [Parameter(Mandatory = $true)][ValidateSet('backup', 'maintenance', 'health')][string]$Category,
        [Parameter(Mandatory = $true)][ValidateSet('SUCCESS', 'WARNING', 'ERROR', 'CRITICAL')][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Component,
        [object[]]$Services,
        [hashtable]$Details
    )

    try {
        if (-not (Test-BRAVOOperationsSettingEnabled -Value $OperationsReportingSettings.Enabled)) {
            return
        }

        $envelope = New-BRAVOOperationsEventEnvelope

        $apiKey = Invoke-BRAVOOperationsEnrollment `
            -OperationsReportingSettings $OperationsReportingSettings `
            -CredentialTargets $CredentialTargets `
            -InstitutionCode $InstitutionCode
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            # Review finding (event loss during pending enrollment): раніше
            # подія тут губилась назавжди — валідного apiKey ще немає
            # (pending/не сконфігуровано/мережевий збій/401-invalidated,
            # уже залоговано всередині Invoke-BRAVOOperationsEnrollment /
            # Clear-BRAVOOperationsInvalidCredential). Тепер вона
            # ставиться в ТОЙ САМИЙ durable outbox, що вже обслуговує
            # transient HTTP-збої — коли enrollment завершиться, наступний
            # природний Send-BRAVOOperationsEvent/Heartbeat задренує чергу
            # (FIFO). AttemptCount=0 -> без штучного стартового backoff.
            $pendingPayload = @{ message = $Message }
            if (-not [string]::IsNullOrWhiteSpace($Component)) {
                $pendingPayload.component = $Component
            }
            if ($null -ne $Services -and @($Services).Count -gt 0) {
                $pendingPayload.services = @($Services)
            }
            if ($null -ne $Details -and $Details.Count -gt 0) {
                $pendingPayload.details = $Details
            }
            $pendingRequestBody = @{
                category = $Category
                severity = $Severity
                payload = $pendingPayload
                eventId = $envelope.EventId
                occurredAt = $envelope.OccurredAtUtc
                schemaVersion = $envelope.SchemaVersion
            }
            Add-BRAVOOperationsOutboxItem -Kind 'event' -EventId $envelope.EventId `
                -OccurredAtUtc $envelope.OccurredAtUtc -SchemaVersion $envelope.SchemaVersion `
                -ApiPath '/api/v1/events' -RequestBody $pendingRequestBody -AttemptCount 0
            return
        }

        $apiBaseUrl = [string]$OperationsReportingSettings.ApiBaseUrl
        $timeoutSeconds = [int]$OperationsReportingSettings.RequestTimeoutSeconds

        Invoke-BRAVOOperationsOutboxDrain -ApiBaseUrl $apiBaseUrl -ApiKey $apiKey `
            -CredentialTargets $CredentialTargets -TimeoutSeconds $timeoutSeconds

        $payload = @{ message = $Message }
        if (-not [string]::IsNullOrWhiteSpace($Component)) {
            $payload.component = $Component
        }
        if ($null -ne $Services -and @($Services).Count -gt 0) {
            $payload.services = @($Services)
        }
        if ($null -ne $Details -and $Details.Count -gt 0) {
            $payload.details = $Details
        }

        $requestBody = @{
            category = $Category
            severity = $Severity
            payload = $payload
            eventId = $envelope.EventId
            occurredAt = $envelope.OccurredAtUtc
            schemaVersion = $envelope.SchemaVersion
        }

        [void](Send-BRAVOOperationsEnvelope `
            -ApiBaseUrl $apiBaseUrl -ApiKey $apiKey -CredentialTargets $CredentialTargets -TimeoutSeconds $timeoutSeconds `
            -Kind 'event' -ApiPath '/api/v1/events' -RequestBody $requestBody `
            -EventId $envelope.EventId -OccurredAtUtc $envelope.OccurredAtUtc -SchemaVersion $envelope.SchemaVersion)
    } catch {
        # Never-throw invariant: жодна несподівана помилка тут не сміє
        # переривати виклик Archive/Maintenance/Health.
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Неочікувана помилка Send-BRAVOOperationsEvent: $($_.Exception.Message)"
    }
}

function Send-BRAVOOperationsHeartbeat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$OperationsReportingSettings,
        [Parameter(Mandatory = $true)][hashtable]$CredentialTargets,
        [Parameter(Mandatory = $true)][string]$InstitutionCode,
        [string]$BravoVersion
    )

    try {
        if (-not (Test-BRAVOOperationsSettingEnabled -Value $OperationsReportingSettings.Enabled)) {
            return
        }

        $envelope = New-BRAVOOperationsEventEnvelope

        $apiKey = Invoke-BRAVOOperationsEnrollment `
            -OperationsReportingSettings $OperationsReportingSettings `
            -CredentialTargets $CredentialTargets `
            -InstitutionCode $InstitutionCode
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            return
        }

        $apiBaseUrl = [string]$OperationsReportingSettings.ApiBaseUrl
        $timeoutSeconds = [int]$OperationsReportingSettings.RequestTimeoutSeconds

        Invoke-BRAVOOperationsOutboxDrain -ApiBaseUrl $apiBaseUrl -ApiKey $apiKey `
            -CredentialTargets $CredentialTargets -TimeoutSeconds $timeoutSeconds

        $requestBody = @{
            eventId = $envelope.EventId
            occurredAt = $envelope.OccurredAtUtc
            schemaVersion = $envelope.SchemaVersion
        }
        if (-not [string]::IsNullOrWhiteSpace($BravoVersion)) {
            $requestBody.bravoVersion = $BravoVersion
        }

        $sent = Send-BRAVOOperationsEnvelope `
            -ApiBaseUrl $apiBaseUrl -ApiKey $apiKey -CredentialTargets $CredentialTargets -TimeoutSeconds $timeoutSeconds `
            -Kind 'heartbeat' -ApiPath '/api/v1/heartbeat' -RequestBody $requestBody `
            -EventId $envelope.EventId -OccurredAtUtc $envelope.OccurredAtUtc -SchemaVersion $envelope.SchemaVersion
        if ($sent) {
            Write-BRAVOLog -Component 'Operations' -Level 'SUCCESS' -Message 'Heartbeat відправлено в Operations'
        }
    } catch {
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Неочікувана помилка Send-BRAVOOperationsHeartbeat: $($_.Exception.Message)"
    }
}

function Test-BRAVOOperationsSettingEnabled {
    # Той самий permissive-boolean парсинг, що Test-BRAVOSettingEnabled
    # (BRAVO.Health) — окрема копія, а не cross-module залежність від
    # Health, щоб BRAVO.Operations лишався незалежним від домену, який
    # його не мусить знати.
    param([object]$Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }
    if ($null -eq $Value) {
        return $false
    }
    return ([string]$Value).Trim() -match '^(?i:true|1|yes|on)$'
}
