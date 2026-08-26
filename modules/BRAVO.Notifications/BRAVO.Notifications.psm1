# Shared BRAVO notification helpers with explicit Compatibility/Credentials dependencies.

$compatibilityManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.Compatibility\BRAVO.Compatibility.psd1'
Import-Module -Name $compatibilityManifest -ErrorAction Stop

$credentialsManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.Credentials\BRAVO.Credentials.psd1'
Import-Module -Name $credentialsManifest -ErrorAction Stop

# Безпечна дефолтна routing-таблиця severity -> канал. Використовується,
# коли викликач не передав -RoutingTable (стара конфігурація без
# NotificationRouting) або передав щось не-hashtable.
$script:BRAVODefaultNotificationRouting = @{
    SUCCESS  = "general"
    WARNING  = "alerts"
    ERROR    = "alerts"
    CRITICAL = "alerts"
}

function Get-HostInformation {
    if ($null -ne $script:CachedHostInformation) {
        return $script:CachedHostInformation
    }

    $machineName = [Environment]::MachineName
    $localAddresses = @()

    try {
        $adapterAddresses = Get-BRAVOWmiInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = TRUE" |
            ForEach-Object { @($_.IPAddress) }

        foreach ($address in $adapterAddresses) {
            $parsedAddress = $null
            if ([System.Net.IPAddress]::TryParse([string]$address, [ref]$parsedAddress) -and
                $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                -not [System.Net.IPAddress]::IsLoopback($parsedAddress) -and
                -not ([string]$address).StartsWith("169.254.")) {
                $localAddresses += [string]$address
            }
        }
    } catch {
        try {
            $localAddresses = @(
                [System.Net.Dns]::GetHostAddresses($machineName) |
                    Where-Object {
                        $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                        -not [System.Net.IPAddress]::IsLoopback($_) -and
                        -not $_.ToString().StartsWith("169.254.")
                    } |
                    ForEach-Object { $_.ToString() }
            )
        } catch {
            $localAddresses = @()
        }
    }

    $localAddressText = if ($localAddresses.Count -gt 0) {
        (@($localAddresses | Sort-Object -Unique) -join ", ")
    } else {
        "недоступна"
    }

    # Аудит P1.10: за замовчуванням вимкнено, якщо конфігурація взагалі не
    # визначає hostInformationSettings/PublicIPLookupEnabled — той самий
    # fail-safe default, що тепер і в BRAVO.config.
    $lookupEnabled = $false
    $lookupUrls = @("https://api.ipify.org")
    $lookupTimeoutSeconds = 5

    # $hostInformationSettings навмисно читається без $global: — так само
    # резолвиться через ланцюжок scope. Але якщо змінна взагалі не існує
    # (модуль імпортовано до того, як BRAVO.config її встановив), це і
    # раніше, і зараз мовчки трактується як "вимкнено" (fail-safe за
    # замовчуванням) — явно попереджаємо про це в лог, щоб оператор
    # бачив, що налаштування з конфігу фактично проігноровані, а не
    # думав, що lookup свідомо вимкнено адміністратором.
    $hostInformationSettingsVar = Get-Variable -Name hostInformationSettings -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $hostInformationSettingsVar -and (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
        Write-Log -Message "hostInformationSettings не ініціалізовано (BRAVO.config не завантажено?) — public IP lookup вимкнено за замовчуванням" -Level WARNING
    }

    if ($hostInformationSettings -is [System.Collections.IDictionary]) {
        if ($hostInformationSettings.Contains("PublicIPLookupEnabled")) {
            $lookupEnabled = [System.Convert]::ToBoolean($hostInformationSettings.PublicIPLookupEnabled)
        }
        if ($hostInformationSettings.Contains("PublicIPLookupUrls")) {
            $configuredUrls = @($hostInformationSettings.PublicIPLookupUrls | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_)
            })
            if ($configuredUrls.Count -gt 0) {
                $lookupUrls = $configuredUrls
            }
        }
        if ($hostInformationSettings.Contains("PublicIPLookupTimeoutSeconds")) {
            $lookupTimeoutSeconds = [math]::Max(
                1,
                [int]$hostInformationSettings.PublicIPLookupTimeoutSeconds
            )
        }
    }

    $publicAddressText = if ($lookupEnabled) { "недоступна" } else { "вимкнено" }
    if ($lookupEnabled) {
        foreach ($lookupUrl in $lookupUrls) {
            $response = $null
            $reader = $null
            try {
                $request = [System.Net.WebRequest]::Create([string]$lookupUrl)
                $request.Method = "GET"
                $request.Timeout = $lookupTimeoutSeconds * 1000
                $request.ReadWriteTimeout = $lookupTimeoutSeconds * 1000
                $response = $request.GetResponse()
                $reader = New-Object System.IO.StreamReader(
                    $response.GetResponseStream(),
                    [System.Text.Encoding]::UTF8
                )
                $candidateAddress = $reader.ReadToEnd().Trim()
                $parsedPublicAddress = $null
                if ([System.Net.IPAddress]::TryParse($candidateAddress, [ref]$parsedPublicAddress)) {
                    $publicAddressText = $candidateAddress
                    break
                }
            } catch {
                # Недоступність зовнішнього сервісу не впливає на health-check.
            } finally {
                if ($reader) { $reader.Dispose() }
                if ($response) { $response.Dispose() }
            }
        }
    }

    $script:CachedHostInformation = [pscustomobject]@{
        MachineName = $machineName
        LocalIP = $localAddressText
        PublicIP = $publicAddressText
    }
    return $script:CachedHostInformation
}

function Format-BRAVOUkrainianCount {
    param(
        [Parameter(Mandatory = $true)][int]$Count,
        [Parameter(Mandatory = $true)][string]$One,
        [Parameter(Mandatory = $true)][string]$Few,
        [Parameter(Mandatory = $true)][string]$Many
    )

    $absoluteCount = [math]::Abs($Count)
    $lastTwoDigits = $absoluteCount % 100
    $lastDigit = $absoluteCount % 10
    $word = if ($lastTwoDigits -ge 11 -and $lastTwoDigits -le 14) {
        $Many
    } elseif ($lastDigit -eq 1) {
        $One
    } elseif ($lastDigit -ge 2 -and $lastDigit -le 4) {
        $Few
    } else {
        $Many
    }
    return "$Count $word"
}

function Format-BRAVOOperatorDuration {
    param([timespan]$Duration)

    $totalSeconds = [math]::Max(0, [int][math]::Round($Duration.TotalSeconds))
    if ($totalSeconds -lt 60) {
        return (Format-BRAVOUkrainianCount -Count $totalSeconds -One "сек." -Few "сек." -Many "сек.")
    }
    $minutes = [int][math]::Floor($totalSeconds / 60)
    $seconds = $totalSeconds % 60
    if ($minutes -lt 60) {
        $text = Format-BRAVOUkrainianCount -Count $minutes -One "хв." -Few "хв." -Many "хв."
        if ($seconds -gt 0) {
            $text += " " + (Format-BRAVOUkrainianCount -Count $seconds -One "сек." -Few "сек." -Many "сек.")
        }
        return $text
    }
    $hours = [int][math]::Floor($minutes / 60)
    $remainingMinutes = $minutes % 60
    $hourText = Format-BRAVOUkrainianCount -Count $hours -One "год." -Few "год." -Many "год."
    if ($remainingMinutes -gt 0) {
        $hourText += " " + (Format-BRAVOUkrainianCount -Count $remainingMinutes -One "хв." -Few "хв." -Many "хв.")
    }
    return $hourText
}

function Test-BRAVOValidIpAddressText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -in @("вимкнено", "недоступна", "недоступні")) { return $false }
    $parsedAddress = $null
    return [System.Net.IPAddress]::TryParse($Value.Trim(), [ref]$parsedAddress)
}

function Format-BRAVOOperatorHostLine {
    param($HostInformation)

    $machineName = if ($null -ne $HostInformation -and
        -not [string]::IsNullOrWhiteSpace([string]$HostInformation.MachineName)) {
        [string]$HostInformation.MachineName
    } else {
        [Environment]::MachineName
    }

    $localParts = @()
    if ($null -ne $HostInformation) {
        $localParts = @(
            ([string]$HostInformation.LocalIP -split '\s*(?:,|\|)\s*') |
                Where-Object { Test-BRAVOValidIpAddressText -Value ([string]$_) } |
                Select-Object -Unique
        )
    }
    $parts = @($machineName) + $localParts
    return ":desktop_computer: " + ($parts -join " · ")
}

function Get-BRAVOOperatorPublicIpLine {
    param($HostInformation)

    if ($null -eq $HostInformation) { return $null }
    $publicIp = [string]$HostInformation.PublicIP
    if (Test-BRAVOValidIpAddressText -Value $publicIp) {
        return ":globe_with_meridians: Публічна IP: $publicIp"
    }
    return $null
}

function Format-BRAVOOperatorVersionLine {
    param(
        [Parameter(Mandatory = $true)][string]$ProductName,
        [string]$Version,
        [string]$BuildId
    )

    $versionText = if ([string]::IsNullOrWhiteSpace($Version)) { "невідома" } else { $Version }
    $buildText = if ([string]::IsNullOrWhiteSpace($BuildId)) { "build невідомий" } else { $BuildId }
    return "$ProductName $versionText · $buildText"
}

# Discord/Slack рендерять текст пропорційним шрифтом, тому вирівнювання
# статус-іконки пробілами (PadRight) або фіксованою кількістю пробілів
# ламається щоразу, коли довжина назви компонента (BLOG/MODEL/BRAVOEXCH/
# BAZA_APP) відрізняється. Замість вирівнювання — статус завжди перша
# колонка рядка, без padding.
function Format-BRAVOOperatorStatusLine {
    param(
        [ValidateSet("SUCCESS", "WARNING", "CRITICAL", "ERROR")]
        [string]$Status = "SUCCESS",
        [Parameter(Mandatory = $true)][string]$Icon,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Detail
    )

    $statusIcon = switch ($Status) {
        "SUCCESS" { ":white_check_mark:" }
        "WARNING" { ":warning:" }
        default { ":x:" }
    }

    $line = "$statusIcon $Icon $Name"
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $line += " — $Detail"
    }
    return $line
}

function New-BRAVOOperatorNotificationMessage {
    param(
        [ValidateSet("SUCCESS", "WARNING", "CRITICAL", "ERROR")]
        [string]$Severity = "SUCCESS",
        [Parameter(Mandatory = $true)][string]$Operation,
        [string]$ActionText,
        [string[]]$ReasonLines = @(),
        [string]$InstitutionName,
        [string]$InstitutionCode,
        $HostInformation,
        [string[]]$ResultLines = @(),
        [datetime]$Timestamp = (Get-Date),
        [timespan]$Duration = [timespan]::Zero,
        [string]$TimestampLabel = "Перевірено",
        [string]$ProductName = "BRAVO",
        [string]$Version,
        [string]$BuildId,
        [string]$LogPath,
        [string]$LogLabel = "Журнал"
    )

    # 12, не 36: довга лінія переносилась на вузьких мобільних екранах і
    # з'їдала екран. ДОВЖИНА МУСИТЬ ЗБІГАТИСЯ з $notificationSeparator у
    # Send-BRAVOWebhookNotification (BRAVO.Compatibility) — та функція
    # перевіряє префікс повідомлення й додає власний роздільник, якщо він
    # не збігся (розсинхрон дав би подвійну лінію).
    $separator = "━" * 12
    $severityIcon = switch ($Severity) {
        "SUCCESS" { ":white_check_mark:" }
        "WARNING" { ":warning:" }
        default { ":rotating_light:" }
    }
    $defaultAction = if ($Severity -eq "SUCCESS") {
        "Дій не потрібно"
    } else {
        "Потрібна дія: перевірити журнал BRAVO"
    }
    $actionLine = if ([string]::IsNullOrWhiteSpace($ActionText)) { $defaultAction } else { $ActionText }
    if ($Severity -ne "SUCCESS" -and -not $actionLine.StartsWith("Потрібна дія:")) {
        $actionLine = "Потрібна дія: $actionLine"
    }

    $institutionLine = if (-not [string]::IsNullOrWhiteSpace($InstitutionCode)) {
        ":office: $InstitutionName [$InstitutionCode]"
    } elseif (-not [string]::IsNullOrWhiteSpace($InstitutionName)) {
        ":office: $InstitutionName"
    } else {
        ":office: BRAVO"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($separator)
    $lines.Add("$severityIcon $Operation")
    $lines.Add($actionLine)
    foreach ($reasonLine in @($ReasonLines)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$reasonLine)) {
            $lines.Add([string]$reasonLine)
        }
    }
    $lines.Add("")
    $lines.Add($institutionLine)
    $lines.Add((Format-BRAVOOperatorHostLine -HostInformation $HostInformation))
    $publicIpLine = Get-BRAVOOperatorPublicIpLine -HostInformation $HostInformation
    if (-not [string]::IsNullOrWhiteSpace($publicIpLine)) {
        $lines.Add($publicIpLine)
    }

    $nonEmptyResultLines = @($ResultLines | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    if ($nonEmptyResultLines.Count -gt 0) {
        $lines.Add("")
        foreach ($resultLine in $nonEmptyResultLines) {
            $lines.Add([string]$resultLine)
        }
    }

    $lines.Add("")
    $timeLine = "${TimestampLabel}: $($Timestamp.ToString('dd.MM.yyyy HH:mm:ss'))"
    if ($Duration -gt [timespan]::Zero) {
        $timeLine += " · $(Format-BRAVOOperatorDuration -Duration $Duration)"
    }
    $lines.Add($timeLine)
    $lines.Add((Format-BRAVOOperatorVersionLine -ProductName $ProductName -Version $Version -BuildId $BuildId))
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $lines.Add("")
        $lines.Add(":memo: ${LogLabel}: $LogPath")
    }
    $lines.Add($separator)
    return ($lines.ToArray() -join [Environment]::NewLine)
}

function ConvertTo-DiscordNotificationText {
    param([string]$Message)

    $emojiReplacements = [ordered]@{
        ":rotating_light:" = "🚨"
        ":office:" = "🏢"
        ":desktop_computer:" = "🖥️"
        ":globe_with_meridians:" = "🌐"
        ":spiral_calendar_pad:" = "🗓️"
        ":alarm_clock:" = "⏰"
        ":hourglass_flowing_sand:" = "⏳"
        ":pushpin:" = "📌"
        ":cloud:" = "☁️"
        ":warning:" = "⚠️"
        ":file_folder:" = "📁"
        ":page_facing_up:" = "📄"
        ":clock3:" = "🕒"
        ":outbox_tray:" = "📤"
        ":inbox_tray:" = "📥"
        ":arrows_counterclockwise:" = "🔄"
        ":twisted_rightwards_arrows:" = "🔀"
        ":bar_chart:" = "📊"
        ":satellite_antenna:" = "📡"
        ":floppy_disk:" = "💾"
        ":memo:" = "📝"
        ":mag:" = "🔎"
        ":white_check_mark:" = "✅"
        ":package:" = "📦"
        ":minidisc:" = "💽"
        ":satellite:" = "🛰️"
        ":wrench:" = "🔧"
        ":fast_forward:" = "⏭️"
        ":x:" = "❌"
    }

    $discordMessage = $Message
    foreach ($replacement in $emojiReplacements.GetEnumerator()) {
        $discordMessage = $discordMessage.Replace($replacement.Key, $replacement.Value)
    }

    return [regex]::Replace(
        $discordMessage,
        '(?m)(?<!\*)\*([^*\r\n]+)\*(?!\*)',
        '**$1**'
    )
}

function Split-DiscordNotificationText {
    param(
        [string]$Message,
        [int]$MaximumLength = 1900
    )

    $chunks = New-Object 'System.Collections.Generic.List[string]'
    $currentChunk = New-Object System.Text.StringBuilder

    foreach ($line in ($Message -split "\r?\n")) {
        $remainingLine = [string]$line
        do {
            $availableLength = $MaximumLength - $currentChunk.Length
            if ($currentChunk.Length -gt 0) {
                $availableLength -= [Environment]::NewLine.Length
            }

            if ($availableLength -le 0) {
                $chunks.Add($currentChunk.ToString())
                $null = $currentChunk.Clear()
                continue
            }

            $partLength = [math]::Min($availableLength, $remainingLine.Length)
            $linePart = $remainingLine.Substring(0, $partLength)
            if ($currentChunk.Length -gt 0) {
                [void]$currentChunk.AppendLine()
            }
            [void]$currentChunk.Append($linePart)
            $remainingLine = $remainingLine.Substring($partLength)

            if ($remainingLine.Length -gt 0) {
                $chunks.Add($currentChunk.ToString())
                $null = $currentChunk.Clear()
            }
        } while ($remainingLine.Length -gt 0)
    }

    if ($currentChunk.Length -gt 0 -or $chunks.Count -eq 0) {
        $chunks.Add($currentChunk.ToString())
    }
    return $chunks.ToArray()
}

# ---------------------------------------------------------------------------
# Централізована severity-based маршрутизація сповіщень (GENERAL/ALERTS).
#
# Pipeline: Severity -> (Resolve-BRAVONotificationRoute) -> Route ->
#           (Resolve-BRAVONotificationEndpoint) -> WebhookUrl ->
#           (ConvertTo-BRAVONotificationPayloadText) -> chunks ->
#           (Send-BRAVONotificationChunks) -> delivery.
# Send-BRAVONotification композує всі стадії для типового виклику з runtime.
# ---------------------------------------------------------------------------

function Resolve-BRAVONotificationRoute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("SUCCESS", "WARNING", "ERROR", "CRITICAL")]
        [string]$Severity,

        [ValidateSet("none", "errors_only", "all")]
        [string]$NotificationMode = "all",

        [hashtable]$RoutingTable
    )

    if ($NotificationMode -eq "none") {
        return "none"
    }

    $effectiveTable = if ($RoutingTable -is [hashtable] -and $RoutingTable.Count -gt 0) {
        $RoutingTable
    } else {
        $script:BRAVODefaultNotificationRouting
    }

    # Semantics самого NotificationMode пріоритетніші за (можливо
    # нестандартну/користувацьку) RoutingTable — custom-таблиця не повинна
    # мати змоги обійти контракт errors_only:
    #   SUCCESS                  -> none (незалежно від таблиці)
    #   WARNING/ERROR/CRITICAL   -> alerts (незалежно від таблиці)
    # Це узгоджено з Health/Maintenance preflight, який під errors_only
    # резолвить лише ALERTS endpoint — custom-маршрут у "general" для
    # non-SUCCESS severity там просто не мав би webhook для доставки.
    if ($NotificationMode -eq "errors_only") {
        if ($Severity -eq "SUCCESS") {
            return "none"
        }
        return "alerts"
    }

    $route = if ($effectiveTable.Contains($Severity) -and
        -not [string]::IsNullOrWhiteSpace([string]$effectiveTable[$Severity])) {
        ([string]$effectiveTable[$Severity]).ToLowerInvariant()
    } else {
        $script:BRAVODefaultNotificationRouting[$Severity]
    }

    if ($route -notin @("general", "alerts")) {
        $route = $script:BRAVODefaultNotificationRouting[$Severity]
    }

    return $route
}

function Resolve-BRAVONotificationEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("slack", "discord")]
        [string]$Provider,

        [Parameter(Mandatory = $true)]
        [ValidateSet("general", "alerts")]
        [string]$Route,

        [Parameter(Mandatory = $true)]
        [hashtable]$CredentialTargets
    )

    $normalizedProvider = $Provider.ToLowerInvariant()
    $routeKey = if ($Route -eq "general") { "General" } else { "Alerts" }

    # Route-специфічний target -> legacy provider-wide target -> жорсткий
    # літерал. Це і є backward-compatibility fallback: сервер, де
    # налаштовано лише BRAVO_DISCORD_URL/BRAVO_SLACK_URL, продовжує
    # отримувати сповіщення в обидва канали через один legacy webhook.
    $candidateTargetNames = New-Object System.Collections.Generic.List[string]

    if ($normalizedProvider -eq "discord") {
        $routeSpecificKey = "DiscordWebhook$routeKey"
        $legacyKey = "DiscordWebhook"
        $legacyLiteral = "BRAVO_DISCORD_URL"
    } else {
        $routeSpecificKey = "SlackWebhook$routeKey"
        $legacyKey = "SlackWebhook"
        $legacyLiteral = "BRAVO_SLACK_URL"
    }

    if ($CredentialTargets.Contains($routeSpecificKey) -and
        -not [string]::IsNullOrWhiteSpace([string]$CredentialTargets[$routeSpecificKey])) {
        $candidateTargetNames.Add([string]$CredentialTargets[$routeSpecificKey])
    }
    if ($CredentialTargets.Contains($legacyKey) -and
        -not [string]::IsNullOrWhiteSpace([string]$CredentialTargets[$legacyKey])) {
        $candidateTargetNames.Add([string]$CredentialTargets[$legacyKey])
    }
    $candidateTargetNames.Add($legacyLiteral)

    $lastError = $null
    foreach ($targetName in ($candidateTargetNames | Select-Object -Unique)) {
        try {
            $secret = Get-BRAVOCredentialSecret -Target $targetName
        } catch {
            $lastError = $_
            $secret = $null
        }
        if (-not [string]::IsNullOrWhiteSpace($secret)) {
            return $secret
        }
    }

    if ($lastError) {
        throw "Не вдалося отримати webhook для $Provider/$Route з Credential Manager: $($lastError.Exception.Message)"
    }
    throw "Webhook для $Provider/$Route не налаштовано в Credential Manager (перевірені targets: $($candidateTargetNames -join ', '))"
}

# Канонічний максимум прикладів для великих переліків у операторських
# notification (ЄДИНЕ місце константи — не розносити 5 по коду; повна
# діагностика завжди лишається в локальному журналі).
$script:BRAVONotificationMaximumListExamples = 5

# Транспорт-агностичний safe payload limit операторського notification.
# СВІДОМО менший за фізичні ліміти конкретних API (Discord message 2000,
# chunk-ліміт Split-DiscordNotificationText 1900; Slack text ~4000) — щоб
# лишався запас на заголовки/markdown/escaping/wrapper-и і щоб «одна
# подія → одне повідомлення» виконувалось на ОБОХ транспортах: після
# guard Discord-split структурно не може дати більше одного chunk-а.
$script:BRAVONotificationSafePayloadLimit = 1800

# Канонічний рендер великого переліку в операторському notification:
#   Приклади:
#   • <рядок 1>
#   ...
#   …і ще N файл(ів).
# «…і ще 0» структурно неможливе (хвіст додається лише коли TotalCount
# перевищує кількість показаних прикладів). Повертає масив рядків —
# викликач вирішує, як їх вплести у своє повідомлення.
function Format-BRAVONotificationListSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ExampleLines,
        [Parameter(Mandatory = $true)][int]$TotalCount,
        [int]$MaximumExamples = $script:BRAVONotificationMaximumListExamples,
        [string]$RemainderNounOne = 'файл',
        [string]$RemainderNounFew = 'файли',
        [string]$RemainderNounMany = 'файлів'
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $shown = @($ExampleLines | Select-Object -First ([math]::Max(1, $MaximumExamples)))
    if (@($shown).Count -eq 0) {
        return @()
    }
    [void]$lines.Add('Приклади:')
    foreach ($exampleLine in $shown) {
        [void]$lines.Add(('• {0}' -f [string]$exampleLine))
    }
    $remainder = $TotalCount - @($shown).Count
    if ($remainder -gt 0) {
        [void]$lines.Add(('…і ще {0}.' -f (Format-BRAVOUkrainianCount -Count $remainder -One $RemainderNounOne -Few $RemainderNounFew -Many $RemainderNounMany)))
    }
    return @($lines.ToArray())
}

# Defensive guard транспортного шару: один аномально великий payload не
# повинен породжувати серію операторських повідомлень і не повинен
# використовувати транспорт як переглядач журналу. Обрізає ПО МЕЖІ РЯДКА,
# додає явний suffix; рядок журналу (":memo:"/"📝") з повного тексту
# зберігається ПІСЛЯ suffix, щоб оператор не втратив шлях до повної
# діагностики. Секрети/webhook у warning не потрапляють.
function Limit-BRAVONotificationPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$MaximumLength = $script:BRAVONotificationSafePayloadLimit,
        [string]$TransportLabel = 'unknown'
    )

    if ($Message.Length -le $MaximumLength) {
        return $Message
    }

    $truncationSuffix = '⚠️ Повідомлення скорочено — повні деталі в журналі BRAVO-Toolkit.'
    $allLines = $Message -split "`r?`n"
    $logPathLine = @($allLines | Where-Object {
        $trimmedLine = ([string]$_).TrimStart()
        $trimmedLine.StartsWith(':memo:') -or $trimmedLine.StartsWith('📝')
    } | Select-Object -First 1)
    $tailLines = New-Object System.Collections.Generic.List[string]
    [void]$tailLines.Add($truncationSuffix)
    if (@($logPathLine).Count -gt 0) {
        [void]$tailLines.Add([string]$logPathLine[0])
    }
    $tailText = ($tailLines.ToArray() -join "`n")

    $budget = $MaximumLength - $tailText.Length - 1
    $keptLines = New-Object System.Collections.Generic.List[string]
    $usedLength = 0
    foreach ($line in $allLines) {
        $lineText = [string]$line
        $lineCost = $lineText.Length + $(if ($keptLines.Count -gt 0) { 1 } else { 0 })
        if (($usedLength + $lineCost) -gt $budget) { break }
        [void]$keptLines.Add($lineText)
        $usedLength += $lineCost
    }
    if ($keptLines.Count -eq 0 -and $budget -gt 0) {
        # Дегенеративний випадок: перший рядок сам довший за бюджет —
        # обрізаємо його посимвольно, щоб suffix гарантовано вмістився.
        [void]$keptLines.Add(([string]$allLines[0]).Substring(0, [math]::Max(0, $budget)))
    }

    $limitedMessage = (($keptLines.ToArray() -join "`n").TrimEnd()) + "`n" + $tailText
    Write-Warning (
        "Notification payload exceeded safe limit and was truncated. " +
        "Transport=$TransportLabel OriginalLength=$($Message.Length) FinalLength=$($limitedMessage.Length) Limit=$MaximumLength"
    )
    return $limitedMessage
}

function ConvertTo-BRAVONotificationPayloadText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("slack", "discord")]
        [string]$Provider,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    # Guard ДО провайдер-специфічної обробки: після нього повідомлення
    # гарантовано ≤ safe limit (< 1900), тож Discord-split структурно дає
    # рівно один chunk, а Slack отримує один payload у межах своїх лімітів.
    # Split-DiscordNotificationText лишається як defense-in-depth.
    $limitedMessage = Limit-BRAVONotificationPayload -Message $Message -TransportLabel $Provider

    if ($Provider.ToLowerInvariant() -eq "discord") {
        $discordText = ConvertTo-DiscordNotificationText -Message $limitedMessage
        return @(Split-DiscordNotificationText -Message $discordText)
    }
    return @($limitedMessage)
}

function Send-BRAVONotificationChunks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("slack", "discord")]
        [string]$Provider,

        [Parameter(Mandatory = $true)]
        [string]$WebhookUrl,

        [Parameter(Mandatory = $true)]
        [string[]]$MessageChunks,

        [int]$TimeoutSeconds = 30
    )

    # Обмежений пейсинг між chunk-запитами (task item 12) — знижує шанс
    # власне спровокувати 429 на великих багатоchunk-повідомленнях. 429/
    # Retry-After усередині Send-BRAVOWebhookNotification має пріоритет:
    # він сам чекає потрібний час перед поверненням у цей цикл.
    $chunkPacingMilliseconds = 400
    $chunkCount = @($MessageChunks).Count
    $chunkIndex = 0
    foreach ($chunk in $MessageChunks) {
        $chunkIndex++
        Send-BRAVOWebhookNotification -Provider $Provider -WebhookUrl $WebhookUrl -Message $chunk -TimeoutSeconds $TimeoutSeconds
        if ($chunkIndex -lt $chunkCount) {
            Start-Sleep -Milliseconds $chunkPacingMilliseconds
        }
    }
}

function Send-BRAVONotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("SUCCESS", "WARNING", "ERROR", "CRITICAL")]
        [string]$Severity,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [ValidateSet("slack", "discord")]
        [string]$Provider,

        [ValidateSet("none", "errors_only", "all")]
        [string]$NotificationMode = "all",

        [hashtable]$RoutingTable,

        [Parameter(Mandatory = $true)]
        [hashtable]$CredentialTargets,

        [int]$TimeoutSeconds = 30,

        [switch]$PassThru
    )

    $route = Resolve-BRAVONotificationRoute -Severity $Severity -NotificationMode $NotificationMode -RoutingTable $RoutingTable

    if ($route -eq "none") {
        if ($PassThru) {
            return [pscustomobject]@{
                Sent = $false
                Route = "none"
                Reason = "NotificationMode/RoutingTable придушили доставку для severity $Severity"
                ChunkCount = 0
            }
        }
        return $null
    }

    $webhookUrl = Resolve-BRAVONotificationEndpoint -Provider $Provider -Route $route -CredentialTargets $CredentialTargets
    $chunks = ConvertTo-BRAVONotificationPayloadText -Provider $Provider -Message $Message
    Send-BRAVONotificationChunks -Provider $Provider -WebhookUrl $webhookUrl -MessageChunks $chunks -TimeoutSeconds $TimeoutSeconds

    if ($PassThru) {
        return [pscustomobject]@{
            Sent = $true
            Route = $route
            Reason = $null
            ChunkCount = $chunks.Count
        }
    }
    return $null
}
