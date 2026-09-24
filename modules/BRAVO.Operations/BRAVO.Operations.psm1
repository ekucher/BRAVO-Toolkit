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
    # Локальний claim-токен (D1) + throttle-мітки логування, отримані від
    # останнього POST /enroll. НЕ секрет фонду (bootstrap secret) і не
    # API-ключ — компрометація сама по собі не дає доступу до чужих
    # серверів (claimMatches прив'язаний до ServerId), тож зберігається як
    # звичайний JSON, а не Credential Manager secret.
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
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
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
            $existing = ([IO.File]::ReadAllText($statePath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -ErrorAction Stop)
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
    # Пошкоджений/відсутній файл тут НЕ є identity-критичним (на відміну
    # від server-id): claimToken можна отримати заново звичайним повторним
    # POST /enroll, тож тут достатньо трактувати непарсований файл як
    # "відсутній" — це не fail-closed кейс E9.
    [CmdletBinding()]
    param()

    $path = Get-BRAVOOperationsEnrollmentStatePath
    if (-not [IO.File]::Exists($path)) {
        return [pscustomobject]@{
            ClaimToken = $null
            LastNotReadyLoggedAtUtc = $null
            LastTtlExpiredLoggedAtUtc = $null
            LastFinalizedLoggedAtUtc = $null
        }
    }
    try {
        $raw = ([IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -ErrorAction Stop)
        return [pscustomobject]@{
            ClaimToken = if ($null -ne $raw.ClaimToken) { [string]$raw.ClaimToken } else { $null }
            LastNotReadyLoggedAtUtc = if ($null -ne $raw.LastNotReadyLoggedAtUtc) { [string]$raw.LastNotReadyLoggedAtUtc } else { $null }
            LastTtlExpiredLoggedAtUtc = if ($null -ne $raw.LastTtlExpiredLoggedAtUtc) { [string]$raw.LastTtlExpiredLoggedAtUtc } else { $null }
            LastFinalizedLoggedAtUtc = if ($null -ne $raw.LastFinalizedLoggedAtUtc) { [string]$raw.LastFinalizedLoggedAtUtc } else { $null }
        }
    } catch {
        return [pscustomobject]@{
            ClaimToken = $null
            LastNotReadyLoggedAtUtc = $null
            LastTtlExpiredLoggedAtUtc = $null
            LastFinalizedLoggedAtUtc = $null
        }
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
    # Best-effort парсинг JSON-тіла помилки (напр. {error, status} на 409)
    # — лише для діагностичного логування, ніколи не для гілкування логіки
    # (щоб не залежати від точного формату помилки бекенду).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    try {
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
    # revoked/already_finalized/TTL-expired/не сконфігуровано/мережевий
    # збій) — виклик НІКОЛИ не кидає.
    #
    # D1/D2/D3 (фінальний контракт bsystem-operations):
    #   - bootstrap-секрет ЛИШЕ в заголовку X-Bootstrap-Secret (POST і GET
    #     однаково) — раніше POST його ще й дублював у тілі.
    #   - POST /enroll повертає claimToken (202) — зберігається локально,
    #     обов'язковий для GET через X-Enrollment-Claim.
    #   - POST /enroll на вже фіналізований (approved/revoked) серверID
    #     повертає 409 already_finalized — термінально для цієї спроби.
    #   - GET без валідного claim -> 404 (навмисно невідрізнюваний від
    #     "не існує"/revoked) -> трактується як "ще не готово", локальний
    #     pending-стан зберігається, лог throttled.
    #   - approved-відповідь БЕЗ apiKey означає TTL (5 хв) вичерпано —
    #     потрібне ручне admin reissue, агент сам це не вирішує.
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

    $enrollmentState = Get-BRAVOOperationsEnrollmentState

    # POST /enroll: завжди намагаємось (навіть якщо claim уже є локально)
    # — сервер безпечно ротує/повертає usable claim, доки серверId ще
    # pending (design bsystem-operations: "lost response recovered by
    # re-POSTing"); якщо серверId уже фіналізований — 409 нижче.
    try {
        $enrollResult = Invoke-BRAVOOperationsApiRequest `
            -BaseUrl $apiBaseUrl -Path '/api/v1/enroll' -Method 'POST' `
            -Headers @{ 'X-Bootstrap-Secret' = $bootstrapSecret } `
            -Body @{
                serverId = $serverId
                institutionCode = $InstitutionCode
                productType = $productType
                hostname = $env:COMPUTERNAME
            } `
            -TimeoutSeconds $timeoutSeconds
    } catch {
        $statusCode = Get-BRAVOOperationsHttpStatusCode -ErrorRecord $_
        if ($statusCode -eq 409) {
            $errorBody = Get-BRAVOOperationsHttpErrorBody -ErrorRecord $_
            $finalStatusRaw = Get-BRAVOOperationsJsonPropertyString -Object $errorBody -Name 'status'
            $finalStatus = if (-not [string]::IsNullOrWhiteSpace($finalStatusRaw)) { $finalStatusRaw } else { 'невідомо' }
            if (Test-BRAVOOperationsLogThrottleElapsed -LastLoggedAtUtc $enrollmentState.LastFinalizedLoggedAtUtc) {
                Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
                    -Message "Сервер уже фіналізований в Operations (status=$finalStatus) — POST /enroll відхилено (409 already_finalized). Це термінально для цього серверного ідентифікатора: якщо status=revoked, звітність зупинена до нового enrollment адміністратором; якщо status=approved, а локальний API-ключ втрачено, потрібне ручне admin reissue (агент не може самообслуговуватись у цьому випадку)."
                $enrollmentState.LastFinalizedLoggedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                Set-BRAVOOperationsEnrollmentState -State $enrollmentState
            }
            return $null
        }
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Не вдалося зареєструвати сервер в Operations (enroll): $($_.Exception.Message)"
        return $null
    }

    $claimTokenFromEnroll = Get-BRAVOOperationsJsonPropertyString -Object $enrollResult -Name 'claimToken'
    if ([string]::IsNullOrWhiteSpace($claimTokenFromEnroll)) {
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message 'Відповідь POST /enroll не містила claimToken — enrollment відкладено до наступної спроби'
        return $null
    }
    $claimToken = $claimTokenFromEnroll
    $enrollmentState.ClaimToken = $claimToken
    Set-BRAVOOperationsEnrollmentState -State $enrollmentState

    try {
        $pollResult = Invoke-BRAVOOperationsApiRequest `
            -BaseUrl $apiBaseUrl -Path "/api/v1/enroll/$serverId" -Method 'GET' `
            -Headers @{ 'X-Bootstrap-Secret' = $bootstrapSecret; 'X-Enrollment-Claim' = $claimToken } `
            -TimeoutSeconds $timeoutSeconds
    } catch {
        $statusCode = Get-BRAVOOperationsHttpStatusCode -ErrorRecord $_
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
        Clear-BRAVOOperationsEnrollmentState
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
        if (Test-BRAVOOperationsLogThrottleElapsed -LastLoggedAtUtc $enrollmentState.LastTtlExpiredLoggedAtUtc) {
            Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
                -Message 'Сервер approved в Operations, але API-ключ більше недоступний (5-хвилинне вікно видачі вичерпано) — потрібне ручне admin reissue; агент продовжить періодично перевіряти, але не намагатиметься "самовиправитись"'
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
    Clear-BRAVOOperationsEnrollmentState
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
        [string]$LastError
    )

    try {
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
            $parsed = ([IO.File]::ReadAllText($file.FullName, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -ErrorAction Stop)
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
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    try {
        $items = Get-BRAVOOperationsOutboxItems
        $now = (Get-Date).ToUniversalTime()
        foreach ($item in $items) {
            $nextRetry = $now
            try {
                $nextRetry = [datetime]::Parse([string]$item.NextRetryAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            } catch {
                $nextRetry = $now
            }
            if ($nextRetry -gt $now) {
                continue
            }

            $requestBodyHashtable = @{}
            foreach ($property in $item.RequestBody.PSObject.Properties) {
                $requestBodyHashtable[$property.Name] = $property.Value
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
            # Pending/не сконфігуровано/мережевий збій/401-invalidated —
            # уже залоговано всередині Invoke-BRAVOOperationsEnrollment
            # (чи Clear-BRAVOOperationsInvalidCredential на попередньому
            # виклику). Подія цього разу НЕ ставиться в outbox — немає
            # валідного ключа, яким її можна було б колись відправити;
            # наступний цикл, коли ключ з'явиться, понесе свої нові події.
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
