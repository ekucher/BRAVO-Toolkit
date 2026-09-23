Set-StrictMode -Version 2.0

# BRAVO.Operations — агентська частина fleet-моніторингу BSYSTEM Operations
# (замінює ручний аналіз Discord-потоку централізованим dashboard, design
# зафіксований грилінг-сесією 2026-09-23).
#
# Область цього модуля:
#   - постійна ідентичність сервера (GUID Server ID, persisted state);
#   - self-enrollment (bootstrap-секрет -> pending -> approve -> API-ключ,
#     reveal-once);
#   - відправка структурованих подій/heartbeat в Operations API.
#
# Канонічно НЕ входить сюди (навмисно): формування Discord/Slack-тексту
# (BRAVO.Notifications), низькорівневий webhook-транспорт для Discord/Slack
# (BRAVO.Compatibility Send-BRAVOWebhookNotification) — Operations має
# власний JSON-контракт, а не текстове повідомлення, тож ділити транспорт
# з тими функціями означало б підганяти чужий контракт під цей.
#
# Усі публічні функції тут NEVER-THROW назовні при мережевих/HTTP-збоях:
# Operations-звітність — вторинний ефект (як і Slack/Discord), її збій не
# повинен переривати чи спотворювати первинну операцію Archive/Maintenance/
# Health (операційний інваріант проекту).

function Get-BRAVOOperationsStateDirectory {
    [CmdletBinding()]
    param()

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

function Get-BRAVOOperationsServerId {
    # Постійний GUID, що ідентифікує цей сервер в Operations — генерується
    # ОДИН раз і переживає перевстановлення/оновлення BRAVO-Toolkit
    # (persisted state, а не конфігураційний ключ). Атомарний запис —
    # той самий write-to-temp-then-Replace патерн, що
    # Write-BRAVOServiceQuiescenceState (BRAVO.System).
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
        } catch {
            # Пошкоджений/нечитаний state-файл — не намагаємось "полагодити"
            # чуже: генеруємо новий ідентифікатор нижче, як і для
            # відсутнього файлу.
        }
    }

    $newServerId = [guid]::NewGuid().ToString()
    $stateDirectory = Get-BRAVOOperationsStateDirectory
    if (-not (Test-Path -LiteralPath $stateDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
    }

    $temporaryStatePath = Join-Path $stateDirectory ('.BRAVO_OPERATIONS_SERVER_ID_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $backupStatePath = Join-Path $stateDirectory ('.BRAVO_OPERATIONS_SERVER_ID_{0}.bak' -f [guid]::NewGuid().ToString('N'))
    $stateReplaced = $false
    try {
        $json = [pscustomobject]@{
            ServerId = $newServerId
            CreatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Depth 3
        [IO.File]::WriteAllText($temporaryStatePath, $json, [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($statePath)) {
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
    return $newServerId
}

function Invoke-BRAVOOperationsApiRequest {
    # Спільний низькорівневий транспорт для enroll/events/heartbeat —
    # той самий HTTPS-only + TLS1.2 + timeout контракт, що
    # Send-BRAVOWebhookNotification (BRAVO.Compatibility), але з JSON
    # тілом і довільними заголовками (X-Api-Key/X-Bootstrap-Secret)
    # замість Discord/Slack payload-формату.
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
    $requestUri = [Uri]::new($baseUri, $Path.TrimStart('/'))

    Enable-BRAVOTls12
    $ProgressPreference = 'SilentlyContinue'

    $requestParameters = @{
        Uri = $requestUri.AbsoluteUri
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

function Invoke-BRAVOOperationsEnrollment {
    # Ідемпотентна перевірка/спроба self-enrollment. Безпечна викликати
    # перед КОЖНОЮ подією/heartbeat: якщо API-ключ уже отримано —
    # миттєвий no-op (лише читання Credential Manager, без мережі).
    # Повертає API-ключ (string) при успіху, $null інакше (pending/
    # revoked/не сконфігуровано/мережевий збій) — виклик НІКОЛИ не кидає.
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
    $timeoutSeconds = [int]$OperationsReportingSettings.RequestTimeoutSeconds

    try {
        [void](Invoke-BRAVOOperationsApiRequest `
            -BaseUrl $apiBaseUrl -Path '/api/v1/enroll' -Method 'POST' `
            -Body @{
                serverId = $serverId
                institutionCode = $InstitutionCode
                productType = $productType
                hostname = $env:COMPUTERNAME
                bootstrapSecret = $bootstrapSecret
            } `
            -TimeoutSeconds $timeoutSeconds)
    } catch {
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Не вдалося зареєструвати сервер в Operations (enroll): $($_.Exception.Message)"
        return $null
    }

    try {
        $pollResult = Invoke-BRAVOOperationsApiRequest `
            -BaseUrl $apiBaseUrl -Path "/api/v1/enroll/$serverId" -Method 'GET' `
            -Headers @{ 'X-Bootstrap-Secret' = $bootstrapSecret } `
            -TimeoutSeconds $timeoutSeconds
    } catch {
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Не вдалося опитати статус enrollment в Operations: $($_.Exception.Message)"
        return $null
    }

    if ($null -eq $pollResult) {
        return $null
    }
    $status = [string]$pollResult.status
    if ($status -eq 'revoked') {
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Сервер відкликано (revoked) в Operations — звітність призупинена, доки адміністратор не перевидасть доступ"
        return $null
    }
    if ($status -ne 'approved' -or [string]::IsNullOrWhiteSpace([string]$pollResult.apiKey)) {
        # pending — очікуваний стан до ручного підтвердження в Operations
        # UI; не помилка, спроба повториться на наступній події/heartbeat.
        return $null
    }

    $newApiKey = [string]$pollResult.apiKey
    try {
        $secureApiKey = ConvertTo-SecureString -String $newApiKey -AsPlainText -Force
        Set-BRAVOCredential -Target $apiKeyTarget -Secret $secureApiKey
    } finally {
        $secureApiKey = $null
    }
    Write-BRAVOLog -Component 'Operations' -Level 'SUCCESS' -Message 'Сервер підтверджено (approved) в Operations — API-ключ збережено'
    return $newApiKey
}

function Send-BRAVOOperationsEvent {
    # Відправляє ОДНУ подію в Operations. Наслідує Q18 грилінгу: severity
    # тут НЕ фільтрується через NotificationMode/RoutingTable — Operations
    # отримує SUCCESS так само, як WARNING/ERROR/CRITICAL, незалежно від
    # того, як налаштований Discord/Slack-провайдер.
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

    if (-not (Test-BRAVOOperationsSettingEnabled -Value $OperationsReportingSettings.Enabled)) {
        return
    }

    $apiKey = Invoke-BRAVOOperationsEnrollment `
        -OperationsReportingSettings $OperationsReportingSettings `
        -CredentialTargets $CredentialTargets `
        -InstitutionCode $InstitutionCode
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        # Pending/не сконфігуровано/мережевий збій — уже залоговано
        # всередині Invoke-BRAVOOperationsEnrollment, де релевантно.
        return
    }

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

    try {
        [void](Invoke-BRAVOOperationsApiRequest `
            -BaseUrl ([string]$OperationsReportingSettings.ApiBaseUrl) -Path '/api/v1/events' -Method 'POST' `
            -Headers @{ 'X-Api-Key' = $apiKey } `
            -Body @{ category = $Category; severity = $Severity; payload = $payload } `
            -TimeoutSeconds ([int]$OperationsReportingSettings.RequestTimeoutSeconds))
    } catch {
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' `
            -Message "Не вдалося відправити подію ($Category/$Severity) в Operations: $($_.Exception.Message)"
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

    if (-not (Test-BRAVOOperationsSettingEnabled -Value $OperationsReportingSettings.Enabled)) {
        return
    }

    $apiKey = Invoke-BRAVOOperationsEnrollment `
        -OperationsReportingSettings $OperationsReportingSettings `
        -CredentialTargets $CredentialTargets `
        -InstitutionCode $InstitutionCode
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        return
    }

    $body = @{}
    if (-not [string]::IsNullOrWhiteSpace($BravoVersion)) {
        $body.bravoVersion = $BravoVersion
    }

    try {
        [void](Invoke-BRAVOOperationsApiRequest `
            -BaseUrl ([string]$OperationsReportingSettings.ApiBaseUrl) -Path '/api/v1/heartbeat' -Method 'POST' `
            -Headers @{ 'X-Api-Key' = $apiKey } `
            -Body $body `
            -TimeoutSeconds ([int]$OperationsReportingSettings.RequestTimeoutSeconds))
        Write-BRAVOLog -Component 'Operations' -Level 'SUCCESS' -Message 'Heartbeat відправлено в Operations'
    } catch {
        Write-BRAVOLog -Component 'Operations' -Level 'WARNING' -Message "Не вдалося відправити heartbeat в Operations: $($_.Exception.Message)"
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
