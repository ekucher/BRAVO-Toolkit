[CmdletBinding()]
param(
    [string]$ConfigPath,

    # Провайдер за замовчуванням береться з bravoSettings.NotificationProvider.
    [ValidateSet("Discord", "Slack")]
    [string]$Provider,

    # Канали за замовчуванням залежать від NotificationMode:
    # all -> General+Alerts; errors_only -> Alerts; none -> потрібен явний
    # -Channels (реальна доставка лише за явним наміром оператора).
    [ValidateSet("General", "Alerts")]
    [string[]]$Channels,

    [switch]$NoPause
)

$helperLoggingPath = Join-Path $PSScriptRoot "modules\BRAVO.HelperLogging\BRAVO.HelperLogging.psd1"
Import-Module -Name $helperLoggingPath -ErrorAction Stop
$null = Start-BRAVOHelperLog -ScriptPath $PSCommandPath -ConfigPath $ConfigPath

# Інтеграційний тест РЕАЛЬНОЇ доставки сповіщень (opt-in, поза self-test):
# проходить рівно той самий канонічний конвеєр, що й production runtime —
#   Severity -> Resolve-BRAVONotificationRoute -> Resolve-BRAVONotificationEndpoint
#   -> New-BRAVOOperatorNotificationMessage -> ConvertTo-BRAVONotificationPayloadText
#   -> Send-BRAVONotificationChunks
# — без власного вибору credential і без прямого HTTP-виклику. GENERAL
# перевіряється повідомленням із Severity=SUCCESS, ALERTS — Severity=WARNING;
# тексти явно марковані як ТЕСТОВІ. Webhook-значення ніколи не виводяться —
# лише назви Credential Manager target-ів, маршрут і статус.
#
# Коди завершення (канонічний BRAVO.ExitCodes): 0 = усі перевірені канали
# доставлені; 30 = некоректна конфігурація виклику; 31 = не вдалося
# отримати webhook-credential; 90 = credential знайдено, але доставка
# не вдалася.

$ErrorActionPreference = "Stop"

function Wait-NotificationTestExit {
    param([int]$ExitCode)
    if (-not $NoPause) {
        Write-Host ""
        Write-Host "Натисніть Enter для виходу..." -ForegroundColor DarkGray
        try {
            [void](Read-Host)
        } catch {
            # Неінтерактивний host (перенаправлений stdin) — пауза
            # неможлива і не потрібна, виходимо одразу.
        }
    }
    exit $ExitCode
}

function Get-BRAVONotificationTestEffectiveChannel {
    # Обчислення ефективних каналів перевірки. PS5.1-пастка, що дала
    # InvokeMethodOnNull у реальному прогоні: пропущений [string[]]-параметр
    # це $null, а @($null).Count = 1 — «порожній» список виглядав
    # непорожнім, default-канали не підставлялись і далі викликався метод
    # на $null-каналі. Тому null/порожні елементи фільтруються явно.
    # Mode-контракт: all -> General+Alerts; errors_only -> Alerts;
    # none/інше -> реальна доставка лише за явним -Channels.
    param(
        [string[]]$Channels,
        [string]$NotificationMode
    )

    $explicitChannels = @(@($Channels) | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    if ($explicitChannels.Count -gt 0) {
        return [pscustomobject]@{
            Channels = $explicitChannels
            RequiresExplicitChannels = $false
        }
    }
    switch (([string]$NotificationMode).Trim().ToLowerInvariant()) {
        "all" {
            return [pscustomobject]@{
                Channels = @("General", "Alerts")
                RequiresExplicitChannels = $false
            }
        }
        "errors_only" {
            return [pscustomobject]@{
                Channels = @("Alerts")
                RequiresExplicitChannels = $false
            }
        }
        default {
            return [pscustomobject]@{
                Channels = @()
                RequiresExplicitChannels = $true
            }
        }
    }
}

# ExitCodes імпортується ДО конфігурації: катастрофа завантаження конфігу
# теж мусить завершитись канонічним кодом, а не CommandNotFoundException.
Import-Module -Name (Join-Path $PSScriptRoot "modules\BRAVO.ExitCodes\BRAVO.ExitCodes.psd1") -ErrorAction Stop

try {
    $configurationLoaderPath = Join-Path $PSScriptRoot "BRAVO_CONFIG_LOADER.ps1"
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Не знайдено BRAVO_CONFIG_LOADER.ps1: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration -ConfigRoot $PSScriptRoot -ConfigPath $ConfigPath -RuntimeRoot $PSScriptRoot

    foreach ($moduleName in @("BRAVO.Compatibility", "BRAVO.Credentials", "BRAVO.Notifications")) {
        $modulePath = Join-Path $PSScriptRoot "modules\$moduleName\$moduleName.psd1"
        Import-Module -Name $modulePath -ErrorAction Stop
    }
} catch {
    Write-Host "ПОМИЛКА конфігурації: $($_.Exception.Message)" -ForegroundColor Red
    Wait-NotificationTestExit -ExitCode (Resolve-BRAVOExitCode -InvalidConfiguration)
}

$notificationMode = ([string]$bravoSettings.NotificationMode).Trim().ToLowerInvariant()
$effectiveProvider = if (-not [string]::IsNullOrWhiteSpace($Provider)) {
    $Provider.ToLowerInvariant()
} else {
    $configuredProvider = ([string]$bravoSettings.NotificationProvider).Trim().ToLowerInvariant()
    if ($configuredProvider -eq "slack") { "slack" } else { "discord" }
}
$providerDisplayName = if ($effectiveProvider -eq "slack") { "Slack" } else { "Discord" }

$channelResolution = Get-BRAVONotificationTestEffectiveChannel `
    -Channels $Channels `
    -NotificationMode $notificationMode
if ($channelResolution.RequiresExplicitChannels) {
    Write-Host "NotificationMode = '$notificationMode': автоматична відправка тестових повідомлень вимкнена." -ForegroundColor Yellow
    Write-Host "Для явної перевірки вкажіть канали: -Channels General,Alerts" -ForegroundColor Yellow
    Wait-NotificationTestExit -ExitCode (Resolve-BRAVOExitCode -InvalidConfiguration)
}
$effectiveChannels = @($channelResolution.Channels)

Write-Host ""
Write-Host "Notification provider: $providerDisplayName (mode: $notificationMode)" -ForegroundColor Cyan

$credentialFailure = $false
$deliveryFailure = $false

foreach ($channel in $effectiveChannels) {
    # Канонічна проєкція каналу: GENERAL несе SUCCESS-семантику, ALERTS —
    # WARNING. Маршрут обчислюється канонічним resolver-ом у режимі "all"
    # (проєкція severity -> канал); гейт site-режиму вже застосовано вище
    # при виборі каналів за замовчуванням, а явний -Channels = явний намір
    # оператора перевірити повну topology.
    $severity = if ($channel -eq "General") { "SUCCESS" } else { "WARNING" }
    $route = Resolve-BRAVONotificationRoute `
        -Severity $severity `
        -NotificationMode "all" `
        -RoutingTable $backupMonitoring.NotificationRouting

    Write-Host ""
    Write-Host ($channel.ToUpperInvariant()) -ForegroundColor White
    Write-Host ("-" * 60)
    Write-Host "Route:       $route"

    $webhookUrl = $null
    try {
        $webhookUrl = Resolve-BRAVONotificationEndpoint `
            -Provider $effectiveProvider `
            -Route $route `
            -CredentialTargets $credentialSettings.Targets
        Write-Host "Credential:  FOUND"
    } catch {
        Write-Host "Credential:  NOT FOUND" -ForegroundColor Red
        Write-Host "Delivery:    NOT ATTEMPTED" -ForegroundColor Yellow
        Write-Host "Деталі:      $($_.Exception.Message)" -ForegroundColor Red
        $credentialFailure = $true
        continue
    }

    try {
        $channelTag = $channel.ToUpperInvariant()
        $resultLines = @(
            "Тестове повідомлення. Реальної події або проблеми немає.",
            "",
            "Channel: $channelTag",
            "Severity: $severity"
        )
        if ($severity -ne "SUCCESS") {
            $resultLines[0] = "ТЕСТОВЕ СПОВІЩЕННЯ. Реальної проблеми немає."
        }
        $message = New-BRAVOOperatorNotificationMessage `
            -Severity $severity `
            -Operation "BRAVO NOTIFICATION TEST — $channelTag" `
            -ActionText $(if ($severity -eq "SUCCESS") { $null } else { "жодних дій не потрібно — це перевірка каналу доставки." }) `
            -InstitutionName ([string]$bravoSettings.InstitutionName) `
            -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
            -HostInformation (Get-HostInformation) `
            -ResultLines $resultLines `
            -Timestamp (Get-Date) `
            -ProductName "BRAVO Notification Test" `
            -Version ([string]$global:ScriptVersion) `
            -BuildId ([string]$global:ScriptBuildId)
        $messageChunks = ConvertTo-BRAVONotificationPayloadText `
            -Provider $effectiveProvider `
            -Message $message
        Send-BRAVONotificationChunks `
            -Provider $effectiveProvider `
            -WebhookUrl $webhookUrl `
            -MessageChunks $messageChunks `
            -TimeoutSeconds ([int]$bravoSettings.NotificationRequestTimeoutSeconds)
        Write-Host "Delivery:    SUCCESS" -ForegroundColor Green
    } catch {
        Write-Host "Delivery:    FAILED" -ForegroundColor Red
        Write-Host "Деталі:      $($_.Exception.Message)" -ForegroundColor Red
        $deliveryFailure = $true
    }
}

Write-Host ""
if ($credentialFailure -or $deliveryFailure) {
    Write-Host "Result: FAIL" -ForegroundColor Red
    if ($credentialFailure) {
        Wait-NotificationTestExit -ExitCode (Resolve-BRAVOExitCode -CredentialsUnavailable)
    }
    Wait-NotificationTestExit -ExitCode (Resolve-BRAVOExitCode -InternalError)
}
Write-Host "Result: PASS" -ForegroundColor Green
Wait-NotificationTestExit -ExitCode 0
