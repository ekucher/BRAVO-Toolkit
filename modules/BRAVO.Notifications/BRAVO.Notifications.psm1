# Shared BRAVO notification helpers with an explicit Compatibility dependency.

$compatibilityManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.Compatibility\BRAVO.Compatibility.psd1'
Import-Module -Name $compatibilityManifest -ErrorAction Stop

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

    $separator = "━" * 36
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
        ":white_check_mark:" = "✅"
        ":package:" = "📦"
        ":minidisc:" = "💽"
        ":satellite:" = "🛰️"
        ":wrench:" = "🔧"
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
