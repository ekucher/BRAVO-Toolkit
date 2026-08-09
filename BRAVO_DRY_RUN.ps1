[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$TestAccess,
    [switch]$SendTestNotification,
    [switch]$SkipCredentials,
    [switch]$RequireScheduledTasks,
    [switch]$AsJson,
    [string]$ResultPath
)

$helperLoggingPath = Join-Path $PSScriptRoot "modules\BRAVO.HelperLogging\BRAVO.HelperLogging.psd1"
Import-Module -Name $helperLoggingPath -ErrorAction Stop
$null = Start-BRAVOHelperLog `
    -ScriptPath $PSCommandPath `
    -ConfigPath $ConfigPath `
    -QuietConsole:$AsJson

# Імпортується тут, а не після завантаження BRAVO.config: Write-DryRunOutput
# має вміти намалювати заголовок і РЕЗУЛЬТАТ навіть тоді, коли dry-run
# провалився ще ДО завантаження конфігурації (єдиний try/catch нижче ловить
# і цей випадок як звичайний [FAIL] запис).
$dryRunConsoleModulePath = Join-Path $PSScriptRoot "modules\BRAVO.Console\BRAVO.Console.psd1"
Import-Module -Name $dryRunConsoleModulePath -ErrorAction Stop
$notificationHelpersPath = Join-Path $PSScriptRoot "modules\BRAVO.Notifications\BRAVO.Notifications.psd1"
Import-Module -Name $notificationHelpersPath -ErrorAction Stop

# Безпечна симуляція BRAVO/VETOFFICE:
# - не створює архіви та каталоги;
# - не копіює, не синхронізує і не видаляє файли;
# - не змінює служби або Планувальник завдань;
# - надсилає тестове Slack/Discord повідомлення лише з -SendTestNotification.
# -TestAccess виконує лише read-only мережеві перевірки.

$ErrorActionPreference = "Stop"
$script:dryRunResults = New-Object System.Collections.ArrayList

function Add-DryRunResult {
    param(
        [ValidateSet("PASS", "WARN", "FAIL", "PLAN")]
        [string]$Status,
        [string]$Category,
        [string]$Name,
        [string]$Detail
    )

    [void]$script:dryRunResults.Add([pscustomobject]@{
        Status = $Status
        Category = $Category
        Name = $Name
        Detail = $Detail
    })
}

function Test-BRAVOMappedNetworkDrivePath {
    # Заплановане завдання від NT AUTHORITY\SYSTEM не бачить дискових
    # підключень користувача. Шлях на букві мережевого диска працює під час
    # ручного запуску й мовчки зникає вночі.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^([A-Za-z]):[\\/]') {
        return $false
    }
    try {
        $driveInfo = New-Object System.IO.DriveInfo($Matches[1] + ":\")
        return ($driveInfo.DriveType -eq [System.IO.DriveType]::Network)
    } catch {
        return $false
    }
}

function Test-BRAVOFileSystemReadAccess {
    # Перелічення каталогу й читання метаданих — рівно те, що робить
    # production-код. Test-Path сюди не годиться: він відповідає "шлях
    # існує", а не "цей обліковий запис може його прочитати", і саме ця
    # різниця й з'ясовується вночі під SYSTEM.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Success = $false; Detail = "шлях не задано" }
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                [void]$stream.ReadByte()
            } finally {
                $stream.Dispose()
            }
            return [pscustomobject]@{ Success = $true; Detail = "читання підтверджено: $Path" }
        } catch {
            return [pscustomobject]@{ Success = $false; Detail = "не вдалося прочитати ${Path}: $($_.Exception.Message)" }
        }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{ Success = $false; Detail = "не існує: $Path" }
    }
    try {
        [void]@([IO.Directory]::EnumerateFileSystemEntries($Path) | Select-Object -First 1)
        return [pscustomobject]@{ Success = $true; Detail = "перелічення підтверджено: $Path" }
    } catch {
        return [pscustomobject]@{ Success = $false; Detail = "не вдалося перелічити ${Path}: $($_.Exception.Message)" }
    }
}

function Test-BRAVOFileSystemWriteAccess {
    # Справжній probe: створити -> записати -> прочитати назад -> видалити.
    # Наявність каталогу нічого не гарантує: ACL може дозволяти перелічення
    # й забороняти запис саме для SYSTEM, і тоді ротація журналів падає вже
    # на production, а не тут.
    #
    # Каталог створюється, якщо його немає: під час першого розгортання
    # SystemLogRoot чи каталог призначення ще не існують, і "не існує" не
    # має видаватися за "немає прав".
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Success = $false; Detail = "шлях не задано" }
    }
    if (Test-BRAVOMappedNetworkDrivePath -Path $Path) {
        return [pscustomobject]@{
            Success = $false
            Detail = "$Path — підключений мережевий диск; під SYSTEM він недоступний, використайте UNC \\server\share\..."
        }
    }
    $createdDirectory = $false
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        try {
            [void](New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop)
            $createdDirectory = $true
        } catch {
            return [pscustomobject]@{ Success = $false; Detail = "не вдалося створити ${Path}: $($_.Exception.Message)" }
        }
    }

    $probePath = Join-Path $Path ("BRAVO_WRITE_PROBE_{0}.tmp" -f [guid]::NewGuid().ToString("N"))
    $probeBytes = [byte[]](0x42, 0x52, 0x41, 0x56, 0x4F)
    try {
        [IO.File]::WriteAllBytes($probePath, $probeBytes)
        $readBack = [IO.File]::ReadAllBytes($probePath)
        if ($readBack.Length -ne $probeBytes.Length) {
            throw "прочитано $($readBack.Length) байт замість $($probeBytes.Length)"
        }
        for ($i = 0; $i -lt $probeBytes.Length; $i++) {
            if ($readBack[$i] -ne $probeBytes[$i]) {
                throw "вміст probe-файла не збігається"
            }
        }
        return [pscustomobject]@{
            Success = $true
            Detail = "запис/читання/видалення підтверджено: $Path$(if ($createdDirectory) { ' (каталог створено)' })"
        }
    } catch {
        return [pscustomobject]@{ Success = $false; Detail = "запис у $Path неможливий: $($_.Exception.Message)" }
    } finally {
        if (Test-Path -LiteralPath $probePath -PathType Leaf) {
            Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-SettingEnabled {
    param([object]$Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }
    if ($null -eq $Value) {
        return $false
    }
    return ([string]$Value).Trim().ToLowerInvariant() -in @(
        "1", "true", "yes", "on", "enabled"
    )
}

function Get-BRAVODryRunConfiguredServiceState {
    # Discovery returns eligible services, but a Disabled installed service is
    # deliberately absent from that result. Probe only known names so Dry Run
    # can preserve the distinction without importing Maintenance runtime.
    param(
        [string]$DiscoveredServiceName,
        [string[]]$ServiceCandidates
    )

    $service = $null
    foreach ($name in @($DiscoveredServiceName) + @($ServiceCandidates)) {
        if ([string]::IsNullOrWhiteSpace([string]$name) -or $null -ne $service) {
            continue
        }
        $service = Get-Service -Name ([string]$name) -ErrorAction SilentlyContinue
    }
    if ($null -eq $service -and @($ServiceCandidates).Count -gt 0) {
        $candidateServices = @(Get-Service -ErrorAction SilentlyContinue)
        $service = $candidateServices | Where-Object {
            $ServiceCandidates -contains [string]$_.Name -or
                $ServiceCandidates -contains [string]$_.DisplayName
        } | Select-Object -First 1
    }

    $startType = if ($null -ne $service) { [string]$service.StartType } else { '' }
    if ($null -ne $service -and [string]::IsNullOrWhiteSpace($startType)) {
        try {
            $escapedName = ([string]$service.Name).Replace("'", "''")
            $serviceInfo = Get-WmiObject -Class Win32_Service `
                -Filter "Name = '$escapedName'" `
                -ErrorAction Stop | Select-Object -First 1
            $startType = [string]$serviceInfo.StartMode
        } catch {
            # A denied WMI query must not turn an optional component into a
            # Dry Run failure; Get-Service still establishes its existence.
        }
    }

    return [pscustomobject]@{
        Exists = ($null -ne $service)
        Disabled = ($startType -ieq 'Disabled')
        Name = if ($null -ne $service) { [string]$service.Name } else { $null }
    }
}

function Get-BRAVODryRunOptionalComponentPlan {
    param(
        [bool]$BravoWebEnabled,
        [bool]$BravoWebServiceExists,
        [bool]$BravoWebServiceDisabled,
        [bool]$ExchangeApiServiceExists,
        [bool]$ExchangeApiServiceDisabled,
        [string]$SystemLogRoot,
        [string]$ExchangeApiServiceName
    )

    $bravoWebEligible = $BravoWebEnabled -and $BravoWebServiceExists -and -not $BravoWebServiceDisabled
    $exchangeApiEligible = $ExchangeApiServiceExists -and -not $ExchangeApiServiceDisabled
    $writeAccessTargets = [ordered]@{}
    if ($exchangeApiEligible) {
        $writeAccessTargets['SystemLog\exchangAPI'] = [IO.Path]::Combine($SystemLogRoot, 'exchangAPI')
    }
    if ($bravoWebEligible) {
        $writeAccessTargets['SystemLog\BravoWeb\Apache'] = [IO.Path]::Combine($SystemLogRoot, 'BravoWeb\Apache')
        $writeAccessTargets['SystemLog\BravoWeb\Application'] = [IO.Path]::Combine($SystemLogRoot, 'BravoWeb\Application')
    }

    $serviceNames = @()
    if ($bravoWebEligible) { $serviceNames += 'BRAVO Web/Apache (автовизначення)' }
    if ($exchangeApiEligible -and -not [string]::IsNullOrWhiteSpace($ExchangeApiServiceName)) {
        $serviceNames += $ExchangeApiServiceName
    }

    return [pscustomobject]@{
        BravoWebEligible = $bravoWebEligible
        BravoWebLegacyDataEligible = $BravoWebEnabled -and $BravoWebServiceExists
        ExchangeApiEligible = $exchangeApiEligible
        ExchangeApiLegacyDataEligible = $ExchangeApiServiceExists
        WriteAccessTargets = $writeAccessTargets
        ServiceNames = @($serviceNames)
    }
}

function Get-BRAVODryRunRangeIdPlan {
    param(
        [Parameter(Mandatory = $true)]$RangeIdMonitoring,
        [string]$SystemRoot,
        [Nullable[bool]]$Is64BitOperatingSystem,
        [scriptblock]$TestPath = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf }
    )

    if (-not (Test-SettingEnabled $RangeIdMonitoring.Enabled)) {
        return $null
    }

    $rangeIdLogPath = Get-BRAVOSystemRangeIdLogPath `
        -SystemRoot $SystemRoot `
        -Is64BitOperatingSystem $Is64BitOperatingSystem
    $thresholdPercent = [string]$RangeIdMonitoring.ThresholdPercent
    if (& $TestPath $rangeIdLogPath) {
        return [pscustomobject]@{
            Status = 'PLAN'
            Path = $rangeIdLogPath
            Detail = "read-only перевірка canonical '$rangeIdLogPath' при $thresholdPercent%"
        }
    }
    return [pscustomobject]@{
        Status = 'WARN'
        Path = $rangeIdLogPath
        Detail = "canonical range_id_log.json не знайдено: '$rangeIdLogPath'; перевірка буде пропущена при $thresholdPercent%"
    }
}

function Get-ConfiguredTarget {
    param(
        [string]$PropertyName,
        [string]$DefaultValue
    )

    $configuredValue = $null
    if ($null -ne $credentialSettings -and
        $null -ne $credentialSettings.Targets) {
        $configuredValue = [string]$credentialSettings.Targets[$PropertyName]
    }
    if ([string]::IsNullOrWhiteSpace($configuredValue)) {
        return $DefaultValue
    }
    return $configuredValue
}

function Get-RequiredCredentialDescriptors {
    $descriptors = New-Object System.Collections.ArrayList

    if ($null -ne $bravoSettings.InstitutionName -and
        $null -ne $bravoSettings.InstitutionCode -and
        $null -ne $bravoSettings.ArchivePrefix) {
        [void]$descriptors.Add([pscustomobject]@{
            Name = "Назва установи"
            Target = Get-ConfiguredTarget "InstitutionName" "BRAVO_INSTITUTION_NAME"
            Kind = "InstitutionName"
        })
        [void]$descriptors.Add([pscustomobject]@{
            Name = "Код установи"
            Target = Get-ConfiguredTarget "InstitutionCode" "BRAVO_INSTITUTION_CODE"
            Kind = "InstitutionCode"
        })
        [void]$descriptors.Add([pscustomobject]@{
            Name = "Префікс архівів"
            Target = Get-ConfiguredTarget "ArchivePrefix" "BRAVO_ARCHIVE_PREFIX"
            Kind = "ArchivePrefix"
        })
    }

    $archiveEnabled = $true
    if ($null -ne $componentSettings -and $null -ne $componentSettings.Archive) {
        $archiveEnabled = Test-SettingEnabled $componentSettings.Archive.MODEL
        $archiveEnabled = $archiveEnabled -or
            (Test-SettingEnabled $componentSettings.Archive.BLOG)
        $archiveEnabled = $archiveEnabled -or
            (Test-SettingEnabled $componentSettings.Archive.BRAVOEXCH)
    }
    if ($archiveEnabled) {
        [void]$descriptors.Add([pscustomobject]@{
            Name = "Пароль архівів"
            Target = Get-ConfiguredTarget "ArchivePassword" "BRAVO_7Z_PASSWORD"
            Kind = "Archive"
        })
    }

    $sftpEnabled = (Test-SettingEnabled $componentSettings.SFTP.ArchiveUpload) -or
        $bazaSyncEffective.ScheduledSftpSyncRequired -or
        (Test-SettingEnabled $backupMonitoring.SFTP.Enabled)
    if ($sftpEnabled) {
        [void]$descriptors.Add([pscustomobject]@{
            Name = "SFTP логін"
            Target = Get-ConfiguredTarget "SFTPLogin" "BRAVO_SFTP_LOGIN"
            Kind = "SFTPLogin"
        })
        [void]$descriptors.Add([pscustomobject]@{
            Name = "SFTP пароль"
            Target = Get-ConfiguredTarget "SFTPPassword" "BRAVO_SFTP_PASSWORD"
            Kind = "SFTPPassword"
        })
    }

    $smbEnabled = Test-SettingEnabled $componentSettings.SMB.ArchiveCopy
    if ($smbEnabled) {
        [void]$descriptors.Add([pscustomobject]@{
            Name = "SMB логін"
            Target = Get-ConfiguredTarget "SMBLogin" "BRAVO_SMB_LOGIN"
            Kind = "SMBLogin"
        })
        [void]$descriptors.Add([pscustomobject]@{
            Name = "SMB пароль"
            Target = Get-ConfiguredTarget "SMBPassword" "BRAVO_SMB_PASSWORD"
            Kind = "SMBPassword"
        })
    }

    $notificationMode = ([string]$bravoSettings.NotificationMode).Trim().ToLowerInvariant()
    if ($notificationMode -ne "none") {
        $provider = ([string]$bravoSettings.NotificationProvider).Trim().ToLowerInvariant()
        if ($provider -eq "slack") {
            [void]$descriptors.Add([pscustomobject]@{
                Name = "Slack webhook"
                Target = Get-ConfiguredTarget "SlackWebhook" "BRAVO_SLACK_URL"
                Kind = "Webhook"
            })
        } else {
            [void]$descriptors.Add([pscustomobject]@{
                Name = "Discord webhook"
                Target = Get-ConfiguredTarget "DiscordWebhook" "BRAVO_DISCORD_URL"
                Kind = "Webhook"
            })
        }
    }

    return $descriptors.ToArray()
}

function Get-SourceDirectory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded.EndsWith("\*") -or $expanded.EndsWith("/*")) {
        return $expanded.Substring(0, $expanded.Length - 2)
    }
    return $expanded
}

function Get-BRAVODryRunVolumeRoot {
    param([string]$Path)

    $sourceDirectory = Get-SourceDirectory -Path $Path
    if ([string]::IsNullOrWhiteSpace($sourceDirectory)) { return $null }
    try {
        return [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($sourceDirectory)).TrimEnd('\')
    } catch {
        return $null
    }
}

function Test-TcpPort {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMilliseconds = 5000
    )

    $client = New-Object Net.Sockets.TcpClient
    try {
        $asyncResult = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            throw "тайм-аут $TimeoutMilliseconds мс"
        }
        $client.EndConnect($asyncResult)
        return $true
    } finally {
        $client.Close()
    }
}

function Send-TestWebhookNotification {
    param(
        [string]$Provider,
        [string]$WebhookUrl,
        [string]$ConfigFileName
    )

    $normalizedProvider = $Provider.Trim().ToLowerInvariant()
    if ($normalizedProvider -notin @("slack", "discord")) {
        throw "невідомий notification provider: $Provider"
    }
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
        throw "webhook відсутній у Credential Manager"
    }

    $uri = New-Object Uri($WebhookUrl)
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne "https") {
        throw "webhook повинен бути абсолютним HTTPS URL"
    }

    $institution = ([string]$bravoSettings.InstitutionName).Trim()
    $institutionCode = ([string]$bravoSettings.InstitutionCode).Trim()
    $objectText = if (-not [string]::IsNullOrWhiteSpace($institutionCode)) {
        "$institution [$institutionCode]".Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($institution)) {
        $institution
    } else {
        "BRAVO"
    }
    $message = New-BRAVOOperatorNotificationMessage `
        -Severity "SUCCESS" `
        -Operation "BRAVO DRY RUN — ТЕСТОВЕ СПОВІЩЕННЯ" `
        -InstitutionName $institution `
        -InstitutionCode $institutionCode `
        -HostInformation (Get-HostInformation) `
        -ResultLines @(
            "Credential Manager і надсилання webhook працюють.",
            "Config: $ConfigFileName",
            "Production-операції архівації, копіювання та видалення не запускалися."
        ) `
        -Timestamp (Get-Date) `
        -ProductName "BRAVO Dry Run" `
        -Version $ScriptVersion `
        -BuildId $ScriptBuildId

    $payload = if ($normalizedProvider -eq "discord") {
        @{
            content = $message
            allowed_mentions = @{parse = @()}
        }
    } else {
        @{text = $message}
    }
    $body = [Text.Encoding]::UTF8.GetBytes(
        ($payload | ConvertTo-Json -Compress -Depth 5)
    )
    $timeoutSeconds = if (
        [int]$bravoSettings.NotificationRequestTimeoutSeconds -gt 0
    ) {
        [int]$bravoSettings.NotificationRequestTimeoutSeconds
    } else {
        30
    }

    # Windows 7 / Server 2008 R2 потребують явного ввімкнення TLS 1.2.
    [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject(
        [Net.SecurityProtocolType],
        3072
    )
    [Net.ServicePointManager]::Expect100Continue = $false

    $request = [Net.WebRequest]::Create($uri)
    $request.Method = "POST"
    $request.ContentType = "application/json; charset=utf-8"
    $request.ContentLength = $body.Length
    $request.Timeout = $timeoutSeconds * 1000
    $request.ReadWriteTimeout = $timeoutSeconds * 1000
    $request.ProtocolVersion = [Net.HttpVersion]::Version11
    $request.KeepAlive = $false
    $request.ServicePoint.Expect100Continue = $false

    $requestStream = $null
    $response = $null
    $reader = $null
    try {
        $requestStream = $request.GetRequestStream()
        $requestStream.Write($body, 0, $body.Length)
        $requestStream.Dispose()
        $requestStream = $null

        $response = $request.GetResponse()
        $statusCode = [int]$response.StatusCode
        $reader = New-Object IO.StreamReader(
            $response.GetResponseStream(),
            [Text.Encoding]::UTF8
        )
        $responseText = $reader.ReadToEnd().Trim()

        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            throw "$normalizedProvider повернув HTTP $statusCode"
        }
        if ($normalizedProvider -eq "slack" -and
            -not [string]::IsNullOrWhiteSpace($responseText) -and
            $responseText -ne "ok") {
            throw "Slack повернув неочікувану відповідь: $responseText"
        }
        return "$normalizedProvider прийняв тестове повідомлення; HTTP $statusCode"
    } catch [Net.WebException] {
        $webException = $_.Exception
        $statusText = "невідомий HTTP-статус"
        $responseText = ""
        $errorResponse = $webException.Response
        if ($null -ne $errorResponse) {
            try {
                if ($errorResponse.StatusCode) {
                    $statusText = "$([int]$errorResponse.StatusCode) $($errorResponse.StatusDescription)"
                }
                $errorReader = New-Object IO.StreamReader(
                    $errorResponse.GetResponseStream(),
                    [Text.Encoding]::UTF8
                )
                try {
                    $responseText = $errorReader.ReadToEnd().Trim()
                } finally {
                    $errorReader.Dispose()
                }
            } catch {
                $responseText = ""
            }
        }
        if ([string]::IsNullOrWhiteSpace($responseText)) {
            throw "Webhook HTTP ${statusText}: $($webException.Message)"
        }
        throw "Webhook HTTP ${statusText}: $responseText"
    } finally {
        if ($requestStream) { $requestStream.Dispose() }
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Resolve-SftpHost {
    param([string]$Login)

    if (-not [string]::IsNullOrWhiteSpace([string]$sftpHostTemplate)) {
        return ([string]$sftpHostTemplate) -f $Login
    }
    foreach ($legacyVariableName in @('sftpHostName', 'sftpHost')) {
        $legacyVariable = Get-Variable -Name $legacyVariableName -Scope Global -ErrorAction SilentlyContinue
        if ($null -ne $legacyVariable -and -not [string]::IsNullOrWhiteSpace([string]$legacyVariable.Value)) {
            return [string]$legacyVariable.Value
        }
    }
    throw "SFTP host не налаштовано"
}

function Get-WinSCPComponents {
    $assemblyCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$winSCPAssemblyPath)) {
        $assemblyCandidates += [string]$winSCPAssemblyPath
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$winSCPPath)) {
        $assemblyCandidates += Join-Path (Split-Path $winSCPPath -Parent) "WinSCPnet.dll"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$toolsPath)) {
        $assemblyCandidates += Join-Path $toolsPath "WinSCPnet.dll"
    }
    if (${env:ProgramFiles(x86)}) {
        $assemblyCandidates += Join-Path ${env:ProgramFiles(x86)} "WinSCP\WinSCPnet.dll"
    }
    if ($env:ProgramFiles) {
        $assemblyCandidates += Join-Path $env:ProgramFiles "WinSCP\WinSCPnet.dll"
    }

    foreach ($assemblyPath in @($assemblyCandidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
            continue
        }
        $executableCandidates = @(
            (Join-Path (Split-Path $assemblyPath -Parent) "WinSCP.exe")
        )
        if (-not [string]::IsNullOrWhiteSpace([string]$winSCPPath)) {
            $configuredDirectory = Split-Path $winSCPPath -Parent
            $executableCandidates += Join-Path $configuredDirectory "WinSCP.exe"
        }
        $executable = @(
            $executableCandidates |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
        )
        if ($executable.Count -gt 0) {
            return [pscustomobject]@{
                Assembly = $assemblyPath
                Executable = [string]$executable[0]
            }
        }
    }
    return $null
}

function Test-SftpReadOnlyAccess {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Секрет із Credential Manager; WinSCP.SessionOptions.Password приймає саме рядок.')]
    param(
        [string]$Login,
        [string]$Password,
        # Віддалені каталоги призначення для увімкнених SFTP-компонентів
        # (наприклад "baza_app", "baza_www"). Перевіряються read-only через
        # FileExists; каталоги НЕ створюються.
        [string[]]$RequiredDirectories = @()
    )

    $hostName = Resolve-SftpHost -Login $Login
    $port = if ([int]$sftpPort -gt 0) { [int]$sftpPort } else { 22 }
    [void](Test-TcpPort -HostName $hostName -Port $port)

    $components = Get-WinSCPComponents
    if ($null -eq $components) {
        throw "для authenticated test не знайдено пару WinSCPnet.dll + WinSCP.exe"
    }

    Add-Type -Path $components.Assembly
    $session = New-Object WinSCP.Session
    try {
        $session.ExecutablePath = $components.Executable
        $options = New-Object WinSCP.SessionOptions
        $options.Protocol = [WinSCP.Protocol]::Sftp
        $options.HostName = $hostName
        $options.PortNumber = $port
        $options.UserName = $Login
        $options.Password = $Password
        $options.SshHostKeyFingerprint = ([string]$sftpHostKey).Trim().Trim('"')
        $session.Open($options)
        [void]$session.ListDirectory(".")

        $present = New-Object System.Collections.Generic.List[string]
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($directory in @($RequiredDirectories)) {
            if ([string]::IsNullOrWhiteSpace($directory)) { continue }
            $remotePath = '/' + ($directory.Trim().Trim('/'))
            # FileExists — read-only stat; Dry Run НІКОЛИ не створює каталоги.
            if ($session.FileExists($remotePath)) {
                $present.Add($remotePath)
            } else {
                $missing.Add($remotePath)
            }
        }
        return [pscustomobject]@{
            Detail = "$hostName`:$port — автентифікація і читання каталогу успішні"
            Present = $present.ToArray()
            Missing = $missing.ToArray()
        }
    } finally {
        $session.Dispose()
    }
}

function Test-SmbReadOnlyAccess {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Секрет із Credential Manager; конвертується в PSCredential одразу нижче.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'Секрет із Credential Manager; SecureString потрібен лише для конструктора PSCredential.')]
    param(
        [string]$RootPath,
        [string]$Login,
        [string]$Password
    )

    if ([string]::IsNullOrWhiteSpace($RootPath) -or -not $RootPath.StartsWith("\\")) {
        throw "SMB RootPath повинен бути UNC-шляхом"
    }
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = New-Object Management.Automation.PSCredential($Login, $securePassword)
    $driveName = "BRV" + ([guid]::NewGuid().ToString("N").Substring(0, 5))
    try {
        [void](New-PSDrive -Name $driveName -PSProvider FileSystem -Root $RootPath -Credential $credential -Scope Script)
        [void](Get-ChildItem -LiteralPath "${driveName}:\" -Force -ErrorAction Stop | Select-Object -First 1)
        return "$RootPath — автентифікація і читання каталогу успішні"
    } finally {
        Remove-PSDrive -Name $driveName -Scope Script -Force -ErrorAction SilentlyContinue
        $securePassword.Dispose()
    }
}

function Write-DryRunOutput {
    if ($AsJson -or -not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $json = $script:dryRunResults.ToArray() | ConvertTo-Json -Depth 5
        if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
            $resolvedResultDirectory = Split-Path -Path $ResultPath -Parent
            if (-not [string]::IsNullOrWhiteSpace($resolvedResultDirectory) -and
                -not (Test-Path -LiteralPath $resolvedResultDirectory -PathType Container)) {
                throw "Каталог ResultPath не існує: $resolvedResultDirectory"
            }
            [IO.File]::WriteAllText(
                $ResultPath,
                [string]$json,
                (New-Object Text.UTF8Encoding($false))
            )
        }
        if ($AsJson) {
            $json
        }
        return
    }

    Initialize-BRAVOConsole
    # Dry-run не малює Write-Progress — без цього Write-BRAVOHeader резервує
    # 6 порожніх рядків під прогрес-бар, якого тут немає.
    Initialize-BRAVOProgress -Enabled $false

    # $bravoSettings/$global:ScriptVersion можуть не існувати, якщо dry-run
    # провалився ще ДО завантаження BRAVO.config (спільний catch вище ловить
    # це як звичайний [FAIL] запис "Dry-run/Фатальна помилка") — заголовок
    # має намалюватись і тоді, просто без назви установи.
    $bravoSettingsVariable = Get-Variable -Name bravoSettings -ErrorAction SilentlyContinue
    $dryRunInstitutionName = $null
    $dryRunInstitutionCode = $null
    if ($null -ne $bravoSettingsVariable -and $null -ne $bravoSettingsVariable.Value) {
        $dryRunInstitutionName = [string]$bravoSettingsVariable.Value.InstitutionName
        $dryRunInstitutionCode = [string]$bravoSettingsVariable.Value.InstitutionCode
    }
    $dryRunVersionText = if ($global:ScriptVersion) { [string]$global:ScriptVersion } else { 'невідома' }
    Write-BRAVOHeader `
        -Title ("BRAVO Dry Run {0}" -f $dryRunVersionText) `
        -Institution $dryRunInstitutionName `
        -InstitutionCode $dryRunInstitutionCode `
        -Mode 'READ-ONLY'

    # Dry Run зберігає власну семантику PASS/WARN/FAIL/PLAN
    # (docs/OPERATOR_CONSOLE_UX.md §6) — не переводиться силоміць у
    # Archive-style [N/M] OK/ERROR. Записи групуються за (Статус, Категорія)
    # у порядку появи: одна перевірка на кшталт "Архівація" з трьома
    # компонентами (MODEL/BLOG/BRAVOEXCH) — один заголовок [PLAN] Архівація
    # і три деталі під ним, а не три однакові рядки поспіль.
    $dryRunGroupOrder = New-Object System.Collections.Generic.List[object]
    $dryRunGroupIndex = @{}
    foreach ($result in $script:dryRunResults) {
        $groupKey = "$($result.Status)|$($result.Category)"
        if (-not $dryRunGroupIndex.ContainsKey($groupKey)) {
            $group = [pscustomobject]@{
                Status = $result.Status
                Category = $result.Category
                Entries = New-Object System.Collections.Generic.List[object]
            }
            $dryRunGroupIndex[$groupKey] = $group
            $dryRunGroupOrder.Add($group)
        }
        $dryRunGroupIndex[$groupKey].Entries.Add($result)
    }
    $dryRunStatusColors = @{
        PASS = [ConsoleColor]::Green
        WARN = [ConsoleColor]::Yellow
        FAIL = [ConsoleColor]::Red
        PLAN = [ConsoleColor]::Cyan
    }
    Write-Host ''
    foreach ($group in $dryRunGroupOrder) {
        Write-Host ("[{0}] {1}" -f $group.Status, $group.Category) -ForegroundColor $dryRunStatusColors[$group.Status]
        foreach ($entry in $group.Entries) {
            $entryLine = if (-not [string]::IsNullOrWhiteSpace($entry.Name) -and $entry.Name -ne $group.Category) {
                if ([string]::IsNullOrWhiteSpace($entry.Detail)) {
                    $entry.Name
                } else {
                    "$($entry.Name): $($entry.Detail)"
                }
            } else {
                $entry.Detail
            }
            Write-Host ("       {0}" -f $entryLine)
        }
        Write-Host ''
    }

    $passCount = @($script:dryRunResults | Where-Object { $_.Status -eq 'PASS' }).Count
    $warnCount = @($script:dryRunResults | Where-Object { $_.Status -eq 'WARN' }).Count
    $failCount = @($script:dryRunResults | Where-Object { $_.Status -eq 'FAIL' }).Count
    $planCount = @($script:dryRunResults | Where-Object { $_.Status -eq 'PLAN' }).Count
    # Контракт незмінний: FAIL > 0 -> "НЕ ГОТОВО" і process exit code
    # лишається ненульовим (обчислюється нижче, поза цією функцією, так
    # само, як і раніше).
    $dryRunReadiness = if ($failCount -gt 0) { 'НЕ ГОТОВО' } else { 'ГОТОВО ДО ЗАПУСКУ' }
    $dryRunReadinessColor = if ($failCount -gt 0) { [ConsoleColor]::Red } else { [ConsoleColor]::Green }

    Write-BRAVOSeparator
    Write-Host ' РЕЗУЛЬТАТ'
    Write-BRAVOSeparator
    Write-BRAVOResultField -Label 'Готовність' -Value $dryRunReadiness -Color $dryRunReadinessColor
    Write-BRAVOResultBlankLine
    Write-BRAVOResultField -Label 'PASS' -Value ([string]$passCount)
    Write-BRAVOResultField -Label 'WARN' -Value ([string]$warnCount)
    Write-BRAVOResultField -Label 'FAIL' -Value ([string]$failCount)
    Write-BRAVOResultField -Label 'PLAN' -Value ([string]$planCount)
    Write-BRAVOResultBlankLine
    Write-BRAVOResultNote -Text 'Production-операції не виконувались.'
    Write-BRAVOSeparator
}

try {
    $scriptDirectory = if ($PSCommandPath) {
        Split-Path $PSCommandPath -Parent
    } else {
        [Environment]::CurrentDirectory
    }
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $scriptDirectory "BRAVO.config"
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "файл конфігурації не знайдено: $ConfigPath"
    }

    $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $runtimeRoot = (Resolve-Path -LiteralPath $scriptDirectory).Path
    $configRoot = Split-Path $resolvedConfigPath -Parent
    $configurationLoaderPath = Join-Path $runtimeRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration `
        -ConfigRoot $configRoot `
        -ConfigPath $resolvedConfigPath `
        -RuntimeRoot $runtimeRoot
    Add-DryRunResult PASS "Конфігурація" "Завантаження" $resolvedConfigPath

    $requiredScriptNames = @(
        "BRAVO_ARCHIV.ps1",
        "BRAVO_MAINTENANCE.ps1",
        "BRAVO_HEALTH.ps1"
    )
    foreach ($scriptName in $requiredScriptNames) {
        $scriptFile = Join-Path $runtimeRoot $scriptName
        if (Test-Path -LiteralPath $scriptFile -PathType Leaf) {
            Add-DryRunResult PASS "Скрипти" $scriptName $scriptFile
        } else {
            Add-DryRunResult FAIL "Скрипти" $scriptName "файл відсутній: $scriptFile"
        }
    }

    # Ті самі три перевірки, які виконує кожен production-entrypoint ДО
    # Import-Module. Без них dry-run звітував «0 помилок» на комплекті, який
    # гарантовано впав би з кодом 33 при першому ж запуску за розкладом —
    # рівно це й сталося на тестовому сервері, де в Tools\ лежали залишки
    # старого розкладання. Перевірка готовності, яка не перевіряє те, що
    # перевіряє сам запуск, дає хибну впевненість.
    $dryRunGuardPath = Join-Path $runtimeRoot 'BRAVO_RUNTIME_GUARD.ps1'
    if (-not (Test-Path -LiteralPath $dryRunGuardPath -PathType Leaf)) {
        Add-DryRunResult FAIL "Цілісність" "Guard" "відсутній: $dryRunGuardPath"
    } else {
        $dryRunGuardLoaded = $false
        try {
            # BRAVO_RUNTIME_GUARD.ps1 has a script-level RuntimeRoot
            # parameter. Dot-sourcing it without this argument would bind an
            # empty value into this script's case-insensitive $runtimeRoot.
            . $dryRunGuardPath -RuntimeRoot $runtimeRoot
            $dryRunGuardLoaded = $null -ne (
                Get-Command -Name 'Test-BRAVORuntimeManifestIntegrity' `
                    -CommandType Function -ErrorAction SilentlyContinue
            )
        } catch {
            $dryRunGuardLoaded = $false
        }

        if (-not $dryRunGuardLoaded) {
            Add-DryRunResult FAIL "Цілісність" "Guard" (
                "не завантажується — перевірка цілісності не виконається й " +
                "при запуску: $dryRunGuardPath"
            )
        } else {
            $runtimeIntegrityResult = Test-BRAVORuntimeManifestIntegrity `
                -RuntimeRoot $runtimeRoot `
                -ManifestPath (Join-Path $runtimeRoot 'RUNTIME_MANIFEST.json') `
                -Mode 'Enforce'
            if ($runtimeIntegrityResult.IsValid) {
                Add-DryRunResult PASS "Цілісність" "Комплект" "RUNTIME_MANIFEST.json відповідає комплекту"
            } else {
                Add-DryRunResult FAIL "Цілісність" "Комплект" ([string]$runtimeIntegrityResult.Message)
            }

            $securitySettingsResult = Test-BRAVORuntimeSecuritySettings `
                -ConfigPath $resolvedConfigPath `
                -Mode 'Enforce'
            if ($securitySettingsResult.IsValid) {
                Add-DryRunResult PASS "Цілісність" "Перемикачі безпеки" "Enforce + VSS підтверджено в BRAVO.config"
            } else {
                Add-DryRunResult FAIL "Цілісність" "Перемикачі безпеки" ([string]$securitySettingsResult.Message)
            }

            # -NoWrite обов'язковий: dry-run не має права записувати стан
            # версії, інакше він сам фіксує розгортання, яке ще не відбулося.
            $versionStateResult = Test-BRAVOVersionDowngrade `
                -RuntimeRoot $runtimeRoot `
                -StatePath (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'BRAVO\State\BRAVO_VERSION_STATE.json') `
                -Mode 'Enforce' `
                -NoWrite
            if ($versionStateResult.IsValid) {
                Add-DryRunResult PASS "Цілісність" "Версія" "відкат на старішу версію не виявлено"
            } else {
                Add-DryRunResult FAIL "Цілісність" "Версія" ([string]$versionStateResult.Message)
            }
        }
    }

    # ===== ФАКТИЧНИЙ ДОСТУП ДО ФАЙЛОВОЇ СИСТЕМИ =====
    # Виконується під тим самим обліковим записом, що й production-запуск
    # (через тимчасове завдання Планувальника — BRAVO_TASKS_DIAGNOSE.ps1),
    # тому це єдине місце, де "SYSTEM має права" перестає бути припущенням.
    $dryRunRuntimeRoot = $runtimeRoot
    # Ефективні корені обчислює BRAVO.config і публікує як $global-змінні.
    # Явний lookup, щоб helper-scope не перетворив валідні корені на порожні.
    $dryRunRuntimeLogRoot = [string]$global:runtimeLogRoot
    $dryRunLimsRoot = [string]$global:effectiveLimsRoot
    $dryRunSystemLogRoot = [string]$global:systemLogRoot
    $dryRunBackupRoot = [string]$global:backupRootPath
    $dryRunStateRoot = [string]$global:stateRoot
    $bravoWebEnabled = Test-SettingEnabled $maintenanceSettings.Services.BravoWebEnabled
    $bravoWebServiceState = if ($bravoWebEnabled) {
        Get-BRAVODryRunConfiguredServiceState `
            -DiscoveredServiceName ([string]$bravoDiscoveryResult.WebServiceName) `
            -ServiceCandidates @($maintenanceSettings.Services.BravoWebCandidates)
    } else {
        [pscustomobject]@{ Exists = $false; Disabled = $false; Name = $null }
    }
    $exchangeApiServiceName = [string]$maintenanceSettings.Services.ExchangeApiName
    $exchangeApiServiceState = Get-BRAVODryRunConfiguredServiceState `
        -ServiceCandidates @($exchangeApiServiceName)
    $optionalComponentPlan = Get-BRAVODryRunOptionalComponentPlan `
        -BravoWebEnabled $bravoWebEnabled `
        -BravoWebServiceExists $bravoWebServiceState.Exists `
        -BravoWebServiceDisabled $bravoWebServiceState.Disabled `
        -ExchangeApiServiceExists $exchangeApiServiceState.Exists `
        -ExchangeApiServiceDisabled $exchangeApiServiceState.Disabled `
        -SystemLogRoot $dryRunSystemLogRoot `
        -ExchangeApiServiceName $exchangeApiServiceName

    Add-DryRunResult PASS "Корені" "RuntimeRoot" $dryRunRuntimeRoot
    Add-DryRunResult PASS "Корені" "RuntimeLogRoot (script logs)" $dryRunRuntimeLogRoot
    Add-DryRunResult PASS "Корені" ("LIMSRoot [{0}]" -f $global:limsRootResult.Source) $dryRunLimsRoot
    Add-DryRunResult PASS "Корені" ("SystemLogRoot [{0}]" -f $global:systemLogRootResult.Source) $dryRunSystemLogRoot
    Add-DryRunResult PASS "Корені" ("BackupRoot [{0}]" -f $global:backupRootResult.Source) $dryRunBackupRoot
    foreach ($rootPair in @(
        @{ Name = 'LIMSRoot'; Path = $dryRunLimsRoot },
        @{ Name = 'SystemLogRoot'; Path = $dryRunSystemLogRoot },
        @{ Name = 'BackupRoot'; Path = $dryRunBackupRoot }
    )) {
        if (Test-BRAVOMappedNetworkDrivePath -Path ([string]$rootPair.Path)) {
            Add-DryRunResult FAIL "Корені" ([string]$rootPair.Name) (
                "$($rootPair.Path) — підключений мережевий диск; SYSTEM його не бачить. " +
                "Використайте UNC \\server\share\..."
            )
        }
    }

    $readAccessTargets = [ordered]@{
        'RuntimeRoot' = $dryRunRuntimeRoot
        'ConfigPath'  = $resolvedConfigPath
        'modules'     = (Join-Path $dryRunRuntimeRoot 'modules')
        'Tools'       = [string]$toolsPath
        'LIMSRoot'    = $dryRunLimsRoot
        'bravo.ini'   = [string]$bravoDiscoveryResult.BravoIniPath
    }
    foreach ($readTarget in $readAccessTargets.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace([string]$readTarget.Value)) {
            Add-DryRunResult WARN "Доступ (читання)" ([string]$readTarget.Key) "шлях не визначено в конфігурації"
            continue
        }
        $readResult = Test-BRAVOFileSystemReadAccess -Path ([string]$readTarget.Value)
        if ($readResult.Success) {
            Add-DryRunResult PASS "Доступ (читання)" ([string]$readTarget.Key) ([string]$readResult.Detail)
        } else {
            Add-DryRunResult FAIL "Доступ (читання)" ([string]$readTarget.Key) ([string]$readResult.Detail)
        }
    }

    $writeAccessTargets = [ordered]@{
        'RuntimeRoot\LOGS (script logs)' = $dryRunRuntimeLogRoot
        'BackupRoot'                     = $dryRunBackupRoot
        'SystemLogRoot'                  = $dryRunSystemLogRoot
        'SystemLog\Trace'               = ([System.IO.Path]::Combine($dryRunSystemLogRoot, 'Trace'))
        'Тимчасовий каталог'   = ([IO.Path]::GetTempPath())
        'Operation lock'       = (Split-Path -Path ([string]$operationLockSettings.Path) -Parent)
        'Machine state'        = $dryRunStateRoot
    }
    foreach ($optionalTarget in $optionalComponentPlan.WriteAccessTargets.GetEnumerator()) {
        $writeAccessTargets[[string]$optionalTarget.Key] = [string]$optionalTarget.Value
    }
    foreach ($definition in @($archiveDefinitions | Where-Object { Test-SettingEnabled $_.Enabled })) {
        $writeAccessTargets["$($definition.Type) destination"] = [string]$definition.Destination
        # [IO.Path]::Combine: диск призначення може ще не існувати — список
        # шляхів для probe будується без DriveNotFoundException, а недоступність
        # рапортує сам probe.
        $writeAccessTargets["$($definition.Type) work"] = [System.IO.Path]::Combine([string]$definition.Destination, '.work')
    }
    if (Test-SettingEnabled $componentSettings.Synchronization.BAZA_APP_LOCAL) {
        $writeAccessTargets['BAZA_APP destination'] = [string]$bazaAppPaths.Destination
    }
    if (Test-SettingEnabled $componentSettings.Synchronization.BAZA_WWW_LOCAL) {
        $writeAccessTargets['BAZA_WWW destination'] = [string]$bazaWWWPaths.Destination
    }
    foreach ($writeTarget in $writeAccessTargets.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace([string]$writeTarget.Value)) {
            Add-DryRunResult WARN "Доступ (запис)" ([string]$writeTarget.Key) "шлях не визначено в конфігурації"
            continue
        }
        $writeResult = Test-BRAVOFileSystemWriteAccess -Path ([string]$writeTarget.Value)
        if ($writeResult.Success) {
            Add-DryRunResult PASS "Доступ (запис)" ([string]$writeTarget.Key) ([string]$writeResult.Detail)
        } else {
            Add-DryRunResult FAIL "Доступ (запис)" ([string]$writeTarget.Key) ([string]$writeResult.Detail)
        }
    }

    $archiverPath = if (-not [string]::IsNullOrWhiteSpace([string]$arcPath)) {
        [string]$arcPath
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$toolsPath)) {
        Join-Path $toolsPath "7za.exe"
    } else {
        $null
    }
    if ($archiverPath -and (Test-Path -LiteralPath $archiverPath -PathType Leaf)) {
        Add-DryRunResult PASS "Інструменти" "7-Zip" $archiverPath
    } else {
        Add-DryRunResult FAIL "Інструменти" "7-Zip" "не знайдено: $archiverPath"
    }

    $compatibilityModulePath = Join-Path $dryRunRuntimeRoot 'modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1'
    if (Test-Path -LiteralPath $compatibilityModulePath -PathType Leaf) {
        Import-Module -Name $compatibilityModulePath -ErrorAction Stop
        $toolManifestResult = Test-BRAVOToolManifestIntegrity `
            -ToolsDirectory ([string]$toolsPath) `
            -ManifestPath ([string]$toolIntegritySettings.ManifestPath) `
            -Mode 'Enforce'
        if ($toolManifestResult.IsValid) {
            Add-DryRunResult PASS 'Цілісність' 'TOOLS_MANIFEST.json' 'runtime tools відповідають version-controlled manifest'
        } else {
            Add-DryRunResult FAIL 'Цілісність' 'TOOLS_MANIFEST.json' ([string]$toolManifestResult.Message)
        }
    } else {
        Add-DryRunResult FAIL 'Цілісність' 'Compatibility module' "не знайдено: $compatibilityModulePath"
    }

    $sftpConfigured = (Test-SettingEnabled $componentSettings.SFTP.ArchiveUpload) -or
        $bazaSyncEffective.ScheduledSftpSyncRequired -or
        (Test-SettingEnabled $backupMonitoring.SFTP.Enabled)
    if ($sftpConfigured) {
        $configuredWinSCPPath = if (-not [string]::IsNullOrWhiteSpace([string]$winSCPPath)) {
            [string]$winSCPPath
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$toolsPath)) {
            Join-Path $toolsPath "WinSCP.com"
        } else {
            $null
        }
        if ($configuredWinSCPPath -and
            (Test-Path -LiteralPath $configuredWinSCPPath -PathType Leaf)) {
            Add-DryRunResult PASS "Інструменти" "WinSCP CLI" $configuredWinSCPPath
        } else {
            Add-DryRunResult FAIL "Інструменти" "WinSCP CLI" (
                "не знайдено: $configuredWinSCPPath"
            )
        }
    }

    if ((Test-SettingEnabled $componentSettings.Synchronization.BAZA_APP_LOCAL) -or
        (Test-SettingEnabled $componentSettings.Synchronization.BAZA_WWW_LOCAL)) {
        $robocopyExecutable = if (
            [string]::IsNullOrWhiteSpace([string]$robocopyPath)
        ) {
            "robocopy.exe"
        } else {
            [string]$robocopyPath
        }
        $robocopyCommand = Get-Command $robocopyExecutable -ErrorAction SilentlyContinue
        if ($null -ne $robocopyCommand) {
            Add-DryRunResult PASS "Інструменти" "Robocopy" ([string]$robocopyCommand.Path)
        } else {
            Add-DryRunResult FAIL "Інструменти" "Robocopy" (
                "команду '$robocopyExecutable' не знайдено"
            )
        }
    }

    $enabledArchiveCount = 0
    foreach ($definition in @($archiveDefinitions)) {
        if (-not (Test-SettingEnabled $definition.Enabled)) {
            continue
        }
        $enabledArchiveCount++
        $sourceDirectory = Get-SourceDirectory ([string]$definition.Source)
        $sourceReadResult = Test-BRAVOFileSystemReadAccess -Path $sourceDirectory
        if ($sourceReadResult.Success) {
            $sourceVolume = Get-BRAVODryRunVolumeRoot -Path $sourceDirectory
            Add-DryRunResult PASS "Джерело" ([string]$definition.Type) "$($sourceReadResult.Detail); volume=$sourceVolume"
        } else {
            Add-DryRunResult FAIL "Джерело" ([string]$definition.Type) ([string]$sourceReadResult.Detail)
        }
        Add-DryRunResult PLAN "Архівація" ([string]$definition.Type) (
            "створення архіву в '$($definition.Destination)' і SHA sidecar"
        )
    }

    if ($enabledArchiveCount -gt 0) {
        $sourceVolumes = @(
            $archiveDefinitions |
                Where-Object { Test-SettingEnabled $_.Enabled } |
                ForEach-Object { Get-BRAVODryRunVolumeRoot -Path ([string]$_.Source) } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )
        $vssService = Get-Service -Name VSS -ErrorAction SilentlyContinue
        $shadowCopyClass = $null
        $shadowCopyClassError = $null
        try {
            $shadowCopyClass = Get-WmiObject -List -Class Win32_ShadowCopy -ErrorAction Stop
        } catch {
            # Restricted sessions can deny WMI even when the VSS class exists.
            # This is a failed capability check, not a reason to abort the rest
            # of dry-run diagnostics (SFTP, scheduler, credentials, etc.).
            $shadowCopyClassError = [string]$_.Exception.Message
        }
        $diskshadowCommand = Get-Command 'diskshadow.exe' -ErrorAction SilentlyContinue
        if ($null -eq $vssService -or $null -eq $shadowCopyClass -or
            ($sourceVolumes.Count -gt 1 -and $null -eq $diskshadowCommand)) {
            $vssDetail = "volumes=$($sourceVolumes -join ', '); VSS service/class/diskshadow capability incomplete"
            if (-not [string]::IsNullOrWhiteSpace($shadowCopyClassError)) {
                $vssDetail += "; Win32_ShadowCopy: $shadowCopyClassError"
            }
            Add-DryRunResult FAIL 'VSS' 'Capability' $vssDetail
        } else {
            Add-DryRunResult PASS 'VSS' 'Capability' "one Snapshot Set planned for volumes: $($sourceVolumes -join ', '); no snapshot created"
        }
    }
    if ($enabledArchiveCount -eq 0 -and $null -ne $sourcePaths) {
        foreach ($entry in $sourcePaths.GetEnumerator()) {
            $sourceDirectory = Get-SourceDirectory ([string]$entry.Value)
            if (Test-Path -LiteralPath $sourceDirectory -PathType Container) {
                Add-DryRunResult PASS "Джерело" ([string]$entry.Key) $sourceDirectory
            } else {
                Add-DryRunResult FAIL "Джерело" ([string]$entry.Key) "каталог відсутній: $sourceDirectory"
            }
            Add-DryRunResult PLAN "Архівація" ([string]$entry.Key) "створення архіву (симуляція)"
        }
    }

    # Джерело кожного УВІМКНЕНОГО BAZA-компонента (LOCAL АБО SFTP) обов'язкове й
    # має існувати — незалежно від типу призначення. Раніше SFTP-гілка лише
    # планувала синхронізацію без перевірки джерела, тому порожнє/відсутнє
    # джерело давало false PASS, хоча production-синхронізація виконатися не
    # могла. Перелік компонентів і правило enablement беруться з канонічного
    # $bazaSyncEffective (Config Loader), а не обчислюються тут повторно.
    foreach ($syncComponent in $bazaSyncEffective.Components) {
        if (-not $syncComponent.AnyEnabled) { continue }

        $componentSource = [string]$syncComponent.Source
        if ([string]::IsNullOrWhiteSpace($componentSource)) {
            $reasonText = if (-not [string]::IsNullOrWhiteSpace([string]$syncComponent.SourceReason)) {
                [string]$syncComponent.SourceReason
            } else {
                'шлях не визначено'
            }
            Add-DryRunResult FAIL "Джерело" $syncComponent.DisplayName (
                "джерело не визначено: $reasonText"
            )
        } else {
            $resolvedComponentSource = Get-SourceDirectory $componentSource
            if (Test-Path -LiteralPath $resolvedComponentSource -PathType Container) {
                Add-DryRunResult PASS "Джерело" $syncComponent.DisplayName $resolvedComponentSource
            } else {
                Add-DryRunResult FAIL "Джерело" $syncComponent.DisplayName "каталог відсутній: $resolvedComponentSource"
            }
        }

        if ($syncComponent.LocalEnabled) {
            $localDestination = if ($syncComponent.Name -eq 'BAZA_APP') {
                [string]$bazaAppPaths.Destination
            } else {
                [string]$bazaWWWPaths.Destination
            }
            Add-DryRunResult PLAN "Синхронізація" ("{0} local" -f $syncComponent.DisplayName) (
                "'$componentSource' -> '$localDestination'"
            )
        }
        if ($syncComponent.SftpEnabled) {
            Add-DryRunResult PLAN "Синхронізація" ("{0} SFTP" -f $syncComponent.DisplayName) (
                "'$componentSource' -> '/$($syncComponent.SftpRemoteDirectory)' без -delete"
            )
        }
    }

    if ($null -ne $maintenanceSettings) {
        $serviceNames = @([string]$maintenanceSettings.Services.BravoName)
        $serviceNames += @($optionalComponentPlan.ServiceNames)
        Add-DryRunResult PLAN "Maintenance" "Служби" (
            "контрольована зупинка/запуск: $($serviceNames -join ', '); у dry-run стан не змінювався"
        )
        Add-DryRunResult PLAN "Backup" "Узгодженість джерел" (
            "режим=$($backupConsistency.Mode); " +
            "контекст=$($backupConsistency.SnapshotContext); " +
            "один VSS Snapshot Set для всіх enabled archive components; " +
            "спільний BRAVO_OPERATION.lock; очікування до " +
            "$($schedulerSettings.OperationLockWaitMinutes) хв.; служби не змінювалися"
        )
        Add-DryRunResult PLAN "Maintenance" "Відновлення MODEL" (
            "день=$($maintenanceSettings.Restore.Day); час=$($maintenanceSettings.Restore.Time); " +
            "контрольні архіви до/після; відновлення не запускалося"
        )
        Add-DryRunResult PLAN "Maintenance" "Retention" (
            "архіви старші $($maintenanceSettings.Retention.ArchiveDays) дн.; " +
            "логи старші $($maintenanceSettings.Retention.LogDays) дн.; " +
            "failed-архіви старші $($maintenanceSettings.Retention.FailedArchiveDays) дн.; " +
            "нічого не видалено"
        )
        if (Test-SettingEnabled $maintenanceSettings.RangeIdMonitoring.Enabled) {
            $rangeIdPlan = Get-BRAVODryRunRangeIdPlan `
                -RangeIdMonitoring $maintenanceSettings.RangeIdMonitoring
            Add-DryRunResult $rangeIdPlan.Status "Maintenance" "Range ID" $rangeIdPlan.Detail
        }
        Add-DryRunResult PLAN "Maintenance" "Shutdown" (
            "AutoShutdown=$($maintenanceSettings.Automation.AutoShutdown); вимкнення ПК не запускалося"
        )
        Add-DryRunResult PLAN "Maintenance" "Архів після maintenance" (
            "ArchiveAfterMaintenance=$($maintenanceSettings.Automation.ArchiveAfterMaintenance); " +
            "BRAVO_ARCHIV.ps1 не запускався"
        )
    } else {
        Add-DryRunResult PLAN "Retention" "Архіви" (
            "enableArchiveDeletion=$enableArchiveDeletion; retentionDays=$archiveRetentionDays; " +
            "failedRetentionDays=$failedArchiveRetentionDays; нічого не видалено"
        )
        Add-DryRunResult PLAN "Retention" "Логи" (
            "logRetentionDays=$logRetentionDays; нічого не видалено"
        )
    }

    if ($null -ne $backupMonitoring -and
        (Test-SettingEnabled $backupMonitoring.Enabled)) {
        Add-DryRunResult PLAN "Health" "Перевірка резервних копій" (
            "локальна/SFTP/SMB перевірка описана config; вбудований HealthCheckOnly не запускався"
        )
    }

    $notificationMode = ([string]$bravoSettings.NotificationMode).Trim().ToLowerInvariant()
    if ($notificationMode -ne "none") {
        $notificationPlan = if ($SendTestNotification) {
            "буде надіслано одне явно позначене тестове повідомлення"
        } else {
            "повідомлення не надсилатиметься без -SendTestNotification"
        }
        Add-DryRunResult PLAN "Сповіщення" ([string]$bravoSettings.NotificationProvider) (
            "режим=$notificationMode; $notificationPlan"
        )
    }

    $requiredCredentials = @()
    # Keep a stable shape under StrictMode. -SkipCredentials deliberately
    # leaves values empty, but subsequent SFTP/SMB/notification planning must
    # still complete instead of reading properties that do not exist.
    $credentialValues = @{
        SFTPLogin = ''
        SFTPPassword = ''
        SMBLogin = ''
        SMBPassword = ''
        Webhook = ''
    }
    if (-not $SkipCredentials) {
        if ($null -eq $credentialSettings -or
            [string]::IsNullOrWhiteSpace([string]$credentialSettings.HelperPath) -or
            -not (Test-Path -LiteralPath $credentialSettings.HelperPath -PathType Leaf)) {
            Add-DryRunResult FAIL "Credential Manager" "Модуль" "BRAVO.Credentials не знайдено"
        } else {
            Import-Module -Name $credentialSettings.HelperPath -ErrorAction Stop
            try {
                $institutionImportResults = @(Import-BRAVOInstitutionSettings `
                    -CredentialSettings $credentialSettings `
                    -BravoSettings $bravoSettings)
                foreach ($institutionResult in $institutionImportResults) {
                    $sourceStatus = if (
                        $institutionResult.Source -eq "CredentialManager"
                    ) {
                        "PASS"
                    } else {
                        "WARN"
                    }
                    Add-DryRunResult $sourceStatus "Параметри установи" (
                        [string]$institutionResult.Name
                    ) (
                        "джерело=$($institutionResult.Source); target='$($institutionResult.Target)'"
                    )
                }
                Add-DryRunResult PASS "Параметри установи" "Ефективні значення" (
                    "$($bravoSettings.InstitutionName) [$($bravoSettings.InstitutionCode)]; " +
                    "ArchivePrefix=$($bravoSettings.ArchivePrefix)"
                )
            } catch {
                Add-DryRunResult FAIL "Параметри установи" "Застосування" $_.Exception.Message
            }
            $requiredCredentials = @(Get-RequiredCredentialDescriptors)
            foreach ($descriptor in $requiredCredentials) {
                try {
                    $secret = Get-BRAVOCredentialSecret -Target $descriptor.Target
                    if ([string]::IsNullOrWhiteSpace($secret)) {
                        Add-DryRunResult FAIL "Credential Manager" $descriptor.Name (
                            "запис '$($descriptor.Target)' відсутній або порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
                        )
                    } else {
                        $credentialValues[$descriptor.Kind] = $secret
                        Add-DryRunResult PASS "Credential Manager" $descriptor.Name (
                            "запис '$($descriptor.Target)' доступний для поточного облікового запису"
                        )
                    }
                } catch {
                    Add-DryRunResult FAIL "Credential Manager" $descriptor.Name $_.Exception.Message
                }
            }
        }
    } else {
        Add-DryRunResult WARN "Credential Manager" "Перевірка" "пропущено параметром -SkipCredentials"
    }

    $sftpRequired = $sftpConfigured
    if ($sftpRequired) {
        Add-DryRunResult PLAN "SFTP" "Передача" "upload/synchronize не запускалися"
        if ($credentialValues.SFTPLogin) {
            try {
                $actualSftpHost = Resolve-SftpHost -Login ([string]$credentialValues.SFTPLogin)
                [void](Test-TcpPort -HostName $actualSftpHost -Port ([int]$sftpPort))
                Add-DryRunResult PASS 'SFTP' 'Actual endpoint' "${actualSftpHost}:$sftpPort доступний"
            } catch {
                Add-DryRunResult FAIL 'SFTP' 'Actual endpoint' $_.Exception.Message
            }
        }
        if ($TestAccess -and $credentialValues.SFTPLogin -and $credentialValues.SFTPPassword) {
            try {
                # Кожен УВІМКНЕНИЙ SFTP-компонент вимагає, щоб його віддалений
                # каталог призначення вже існував (production sync його не
                # створює). Перелік — з канонічного $bazaSyncEffective.
                $requiredSftpDirectories = @($bazaSyncEffective.RequiredSftpDestinations)
                $sftpResult = Test-SftpReadOnlyAccess `
                    -Login ([string]$credentialValues.SFTPLogin) `
                    -Password ([string]$credentialValues.SFTPPassword) `
                    -RequiredDirectories $requiredSftpDirectories
                Add-DryRunResult PASS "SFTP" "Read-only доступ" $sftpResult.Detail
                foreach ($presentDir in @($sftpResult.Present)) {
                    Add-DryRunResult PASS "SFTP" "Каталог призначення" "$presentDir існує"
                }
                foreach ($missingDir in @($sftpResult.Missing)) {
                    Add-DryRunResult FAIL "SFTP" "Каталог призначення" (
                        "SFTP destination '$missingDir' не існує або недоступний. " +
                        "Dry Run не створює каталоги."
                    )
                }
            } catch {
                Add-DryRunResult FAIL "SFTP" "Read-only доступ" $_.Exception.Message
            }
        } elseif (-not $TestAccess) {
            Add-DryRunResult WARN "SFTP" "Read-only доступ" "не перевірявся; використайте -TestAccess"
        }
    }

    if (Test-SettingEnabled $componentSettings.SMB.ArchiveCopy) {
        $smbRoot = if (-not [string]::IsNullOrWhiteSpace([string]$smbSettings.RootPath)) {
            [string]$smbSettings.RootPath
        } else {
            # Сумісність зі старими конфігами, де шлях лежав у networkCopyConfig.
            # Змінної може не бути взагалі, тому читаємо її безпечно.
            $legacyNetworkCopy = Get-Variable -Name 'networkCopyConfig' -Scope Global -ErrorAction SilentlyContinue
            if ($null -ne $legacyNetworkCopy -and $null -ne $legacyNetworkCopy.Value) {
                [string]$legacyNetworkCopy.Value.NetworkPath
            } else {
                ""
            }
        }
        Add-DryRunResult PLAN "SMB" "Копіювання" "копіювання до '$smbRoot' не запускалося"
        if ($TestAccess -and $credentialValues.SMBLogin -and $credentialValues.SMBPassword) {
            try {
                $detail = Test-SmbReadOnlyAccess `
                    -RootPath $smbRoot `
                    -Login ([string]$credentialValues.SMBLogin) `
                    -Password ([string]$credentialValues.SMBPassword)
                Add-DryRunResult PASS "SMB" "Read-only доступ" $detail
            } catch {
                Add-DryRunResult FAIL "SMB" "Read-only доступ" $_.Exception.Message
            }
        } elseif (-not $TestAccess) {
            Add-DryRunResult WARN "SMB" "Read-only доступ" "не перевірявся; використайте -TestAccess"
        }
    }

    if ($null -ne $schedulerSettings -and $null -ne $schedulerSettings.Backup) {
        $taskFolder = $null
        $taskServiceError = $null
        try {
            $taskService = New-Object -ComObject "Schedule.Service"
            $taskService.Connect()
            $taskPath = ([string]$schedulerSettings.TaskPath).TrimEnd("\")
            if ([string]::IsNullOrWhiteSpace($taskPath)) {
                $taskPath = "\"
            }
            $taskFolder = $taskService.GetFolder($taskPath)
        } catch {
            $taskServiceError = $_.Exception.Message
        }

        foreach ($taskName in @("Backup", "Maintenance", "Health")) {
            $task = $schedulerSettings[$taskName]
            if ($null -eq $task) {
                continue
            }
            $enabledText = if (Test-SettingEnabled $task.Enabled) { "увімкнено" } else { "вимкнено" }
            $timeText = if ($taskName -eq "Health") {
                "$($task.StartAt), кожні $($task.RepeatEveryMinutes) хв."
            } else {
                [string]$task.DailyAt
            }
            Add-DryRunResult PLAN "Планувальник" $taskName (
                "$enabledText; $($schedulerSettings.TaskPath)$($task.TaskName); $timeText; запуск від $($schedulerSettings.RunAsUser)"
            )

            if (Test-SettingEnabled $task.Enabled) {
                $registeredTask = $null
                if ($null -ne $taskFolder) {
                    try {
                        $registeredTask = $taskFolder.GetTask([string]$task.TaskName)
                    } catch {
                        $registeredTask = $null
                    }
                }
                if ($null -ne $registeredTask) {
                    $registeredState = switch ([int]$registeredTask.State) {
                        1 { "Disabled" }
                        2 { "Queued" }
                        3 { "Ready" }
                        4 { "Running" }
                        default { "Unknown" }
                    }
                    Add-DryRunResult PASS "Планувальник" "$taskName registration" (
                        "завдання зареєстровано; state=$registeredState; enabled=$($registeredTask.Enabled)"
                    )
                } else {
                    $missingStatus = if ($RequireScheduledTasks) { "FAIL" } else { "WARN" }
                    $missingDetail = if ($taskServiceError) {
                        "стан не вдалося прочитати: $taskServiceError"
                    } else {
                        "увімкнене в config завдання ще не зареєстровано"
                    }
                    Add-DryRunResult $missingStatus "Планувальник" "$taskName registration" $missingDetail
                }
            }
        }
    } else {
        Add-DryRunResult WARN "Планувальник" "Конфігурація" (
            "у цьому config немає повної schedulerSettings; інсталяція BRAVO_TASKS_INSTALL.ps1 недоступна"
        )
    }

    if ($TestAccess) {
        foreach ($webhook in @($requiredCredentials | Where-Object { $_.Kind -eq "Webhook" })) {
            $webhookValue = [string]$credentialValues.Webhook
            try {
                $uri = New-Object Uri($webhookValue)
                if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne "https") {
                    throw "webhook повинен бути абсолютним HTTPS URL"
                }
                [void](Test-TcpPort -HostName $uri.DnsSafeHost -Port 443)
                Add-DryRunResult PASS "Сповіщення" $webhook.Name (
                    "$($uri.DnsSafeHost):443 доступний; повідомлення не надсилалося"
                )
            } catch {
                Add-DryRunResult FAIL "Сповіщення" $webhook.Name $_.Exception.Message
            }
        }
    }

    if ($SendTestNotification) {
        $notificationMode = ([string]$bravoSettings.NotificationMode).Trim().ToLowerInvariant()
        $notificationProvider = ([string]$bravoSettings.NotificationProvider).Trim().ToLowerInvariant()
        if ($notificationMode -eq "none") {
            Add-DryRunResult FAIL "Сповіщення" "Тестове повідомлення" (
                "NotificationMode=none; webhook не налаштований як активний компонент"
            )
        } elseif ([string]::IsNullOrWhiteSpace([string]$credentialValues.Webhook)) {
            Add-DryRunResult FAIL "Сповіщення" "Тестове повідомлення" (
                "webhook не вдалося прочитати з Credential Manager"
            )
        } else {
            try {
                $sendResult = Send-TestWebhookNotification `
                    -Provider $notificationProvider `
                    -WebhookUrl ([string]$credentialValues.Webhook) `
                    -ConfigFileName (Split-Path $resolvedConfigPath -Leaf)
                Add-DryRunResult PASS "Сповіщення" "Тестове повідомлення" $sendResult
            } catch {
                Add-DryRunResult FAIL "Сповіщення" "Тестове повідомлення" $_.Exception.Message
            }
        }
    }
} catch {
    $fatalDetail = [string]$_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace([string]$_.InvocationInfo.PositionMessage)) {
        $fatalDetail += "`n$($_.InvocationInfo.PositionMessage.Trim())"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$_.ScriptStackTrace)) {
        $fatalDetail += "`nStack: $($_.ScriptStackTrace)"
    }
    Add-DryRunResult FAIL "Dry-run" "Фатальна помилка" $fatalDetail
}

Write-DryRunOutput
$failureCount = @($script:dryRunResults | Where-Object { $_.Status -eq "FAIL" }).Count
if ($failureCount -gt 0) {
    Complete-BRAVOHelperLog -ExitCode 1
}
Complete-BRAVOHelperLog -ExitCode 0
