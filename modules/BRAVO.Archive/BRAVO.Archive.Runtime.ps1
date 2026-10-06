##########
# BravoSoft
# Author: Evgeniy Kucher
# Скрипт для архівації та резервного копіювання даних BRAVO/LIMS
# Конфігурація винесена в окремий файл
##########

# Ручна синхронізація лише BAZA на SFTP:
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\BRAVO_ARCHIV.ps1" -SyncBAZA -NoPause

param(
    [string]$ConfigPath,
    [bool]$ConfigPathWasExplicit = $false,
    [switch]$SyncBAZA,
    [switch]$HealthCheckOnly,
    [switch]$ForceNotification,
    [switch]$NotifyOnSuccess,
    [switch]$NoSlack,
    [switch]$SkipIfBackupTaskRunning,
    [switch]$CatchUpMissedBackup,
    [switch]$NoPause,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$EntryScriptPath
)

# Тіло runtime — одна функція, за зразком BRAVO.Health.Runtime.ps1
# (Invoke-BRAVOHealth) і BRAVO.DataRestore.Runtime.ps1
# (Invoke-BRAVODataRestore): прямий запуск файлу (& у BRAVO.Archive.psm1)
# виконує тіло через invocation guard наприкінці файлу, а dot-source лише
# визначає функцію й нічого не виконує. param() функції повторює param()
# скрипта один в один. Функції runtime тепер визначаються в scope обгортки
# і, як і раніше, бачать змінні тіла через динамічний scope (усі вони
# викликаються зсередини обгортки); стан, який читають через $script:,
# тіло пише явно через $script:, а exit усередині функції завершує весь
# скрипт тим самим кодом.
function Invoke-BRAVOArchive {
    param(
        [string]$ConfigPath,
        [bool]$ConfigPathWasExplicit = $false,
        [switch]$SyncBAZA,
        [switch]$HealthCheckOnly,
        [switch]$ForceNotification,
        [switch]$NotifyOnSuccess,
        [switch]$NoSlack,
        [switch]$SkipIfBackupTaskRunning,
        [switch]$CatchUpMissedBackup,
        [switch]$NoPause,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$EntryScriptPath
    )

$bravoScriptDirectory = $RuntimeRoot

# Спільні PowerShell-модулі runtime.
foreach ($moduleName in @('BRAVO.Compatibility', 'BRAVO.Credentials', 'BRAVO.ArchiveRuntime', 'BRAVO.BazaSync', 'BRAVO.Logging', 'BRAVO.Console', 'BRAVO.ExitCodes', 'BRAVO.Notifications', 'BRAVO.System', 'BRAVO.Status', 'BRAVO.DiskSpace', 'BRAVO.Operations')) {
    $modulePath = Join-Path $bravoScriptDirectory "modules\$moduleName\$moduleName.psd1"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Не знайдено спільний PowerShell-модуль: $modulePath"
    }
    Import-Module -Name $modulePath -ErrorAction Stop
}
Assert-BRAVOPowerShellCompatibility
[void](Initialize-BRAVOConsoleEncoding -CodePage 65001)
$script:BRAVOCompatibility = Get-BRAVOCompatibilityInfo
$script:BRAVOPowerShellUpdate = Get-BRAVOPowerShellUpdateRecommendation
# Свіжість накопичувальних оновлень Windows Toolkit не перевіряє ніде
# (ні тут, ні в BRAVO_HEALTH): на результат backup вік патчів не впливає,
# а постійне нагадування було лише шумом. Перевірки платформи (ОС, build, PowerShell, .NET,
# архітектура, API) лишаються вище й на місці.
$archiveHelpersPath = Join-Path $bravoScriptDirectory 'modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1'
if (-not (Test-Path -LiteralPath $archiveHelpersPath -PathType Leaf)) {
    throw "Не знайдено PowerShell-модуль archive helpers: $archiveHelpersPath"
}
Import-Module -Name $archiveHelpersPath -ErrorAction Stop



# Compatibility forwarding for callers that still use BRAVO_ARCHIV -HealthCheckOnly.
# New callers and Task Scheduler use BRAVO_HEALTH.ps1 directly.
if ($HealthCheckOnly) {
    $healthScriptPath = Join-Path $bravoScriptDirectory 'BRAVO_HEALTH.ps1'
    if (-not (Test-Path -LiteralPath $healthScriptPath -PathType Leaf)) {
        Write-Error "Не знайдено окремий health-скрипт: $healthScriptPath"
        exit 1
    }
    # AUTO -> дочірній BRAVO_HEALTH.ps1 сам виконує ту саму auto-derivation
    # проти свого $PSScriptRoot (той самий комплект); EXPLICIT -> точний
    # шлях оператора зберігається.
    $healthForwardConfigArguments = @{}
    if ($ConfigPathWasExplicit -and -not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $healthForwardConfigArguments.ConfigPath = $ConfigPath
    }
    & $healthScriptPath @healthForwardConfigArguments `
        -ForceNotification:$ForceNotification `
        -NotifyOnSuccess:$NotifyOnSuccess `
        -NoSlack:$NoSlack `
        -SkipIfBackupTaskRunning:$SkipIfBackupTaskRunning `
        -NoPause:$NoPause
    exit $LASTEXITCODE
}
# P0 Configuration Foundation: справжня межа виклику оператора — root
# entrypoint, і лише ВІН знає, чи -ConfigPath був реально переданий: сюди
# ConfigPath завжди приходить уже резолвленим і непорожнім, тому
# $PSBoundParameters тут відновити намір не може (acceptance-клас дефектів
# CF-17/AUTO-intent). Намір приймається явним -ConfigPathWasExplicit;
# додаткова перевірка порожнього шляху страхує від помилкового виклику з
# прапорцем без шляху (та сама семантика, що в Import-BravoConfiguration).
$configPathWasExplicit = $ConfigPathWasExplicit -and
    -not [string]::IsNullOrWhiteSpace($ConfigPath)
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $bravoScriptDirectory "BRAVO.config"
}

# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass –Force

# =============================================
# ЗАВАНТАЖЕННЯ КОНФІГУРАЦІЇ
# =============================================
# P0 Configuration Foundation: BRAVO.config став опційним основним
# override-шаром — попередня жорстка "файл мусить існувати" перевірка
# тут дублювала (і випереджала) те саме рішення, яке Import-Bravo
# Configuration тепер приймає коректно сама (auto-derived відсутній
# BRAVO.config -> canonical built-in defaults + BRAVO.local.config;
# явно вказаний відсутній -ConfigPath -> як і раніше, помилка). Один
# canonical guard замість двох незалежних копій цього рішення.

# Завантаження конфігурації
try {
    $loaderPath = Join-Path `
        -Path $bravoScriptDirectory `
        -ChildPath "BRAVO_CONFIG_LOADER.ps1"

    if (-not (Test-Path -LiteralPath $loaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $loaderPath"
    }

    . $loaderPath

    # Issue #216 (Wave B): production runtime entrypoint — не виконує
    # BRAVO.config автоматично лише тому, що він опинився поруч на диску;
    # див. коментар біля $DisallowLegacyPrimaryAutoDetect у
    # BRAVO_CONFIG_LOADER.ps1.
    Import-BravoConfiguration `
        -ConfigRoot (Split-Path -Path ([System.IO.Path]::GetFullPath($ConfigPath)) -Parent) `
        -ConfigPath $ConfigPath `
        -RuntimeRoot $bravoScriptDirectory `
        -ConfigPathWasExplicit:$configPathWasExplicit `
        -DisallowLegacyPrimaryAutoDetect

    $configPath = [string]$global:BravoConfigurationMetadata.ConfigPath
    Write-Host "Конфiгурацiю завантажено успiшно: $configPath" -ForegroundColor $logColors.SUCCESS
} catch {
    Write-Host "ПОМИЛКА: Не вдалося завантажити конфiгурацiю: $(Protect-BRAVOLogSecret -Text $_.Exception.Message)" -ForegroundColor Red
    Exit 1
}

# Archive використовує ту саму політику вільного місця, що й Maintenance.
# Нормалізація виключень виконується один раз до запуску операцій, щоб
# помилка конфігурації не могла перетворитися на частково створений backup.
try {
    if ($null -eq $maintenanceSettings -or
        $null -eq $maintenanceSettings.Limits -or
        $null -eq $maintenanceSettings.Limits.MinimumFreeSpaceGB) {
        throw 'У BRAVO.config відсутній Maintenance.Limits.MinimumFreeSpaceGB'
    }

    $archiveMinimumFreeSpaceGB = [double]$maintenanceSettings.Limits.MinimumFreeSpaceGB
    if ($archiveMinimumFreeSpaceGB -lt 0) {
        throw 'Maintenance.Limits.MinimumFreeSpaceGB не може бути відʼємним'
    }

    $archiveFreeSpaceExcludedDrives = @()
    $configuredArchiveExcludedDrives = if (
        $maintenanceSettings.Limits -is [System.Collections.IDictionary] -and
        $maintenanceSettings.Limits.Contains('ExcludedDrives')
    ) {
        @($maintenanceSettings.Limits.ExcludedDrives)
    } else {
        @()
    }
    foreach ($configuredDrive in $configuredArchiveExcludedDrives) {
        $normalizedDrive = ([string]$configuredDrive).Trim().TrimEnd('\').ToUpperInvariant()
        if ($normalizedDrive -match '^[A-Z]$') {
            $normalizedDrive += ':'
        }
        if ($normalizedDrive -notmatch '^[A-Z]:$') {
            throw "Некоректне значення Maintenance.Limits.ExcludedDrives: $configuredDrive"
        }
        if ($archiveFreeSpaceExcludedDrives -notcontains $normalizedDrive) {
            $archiveFreeSpaceExcludedDrives += $normalizedDrive
        }
    }

    # Опційний параметр (compat: старі BRAVO.config його не містять) —
    # запас понад розмір останнього валідного архіву для розрахункової
    # перевірки місця (Get-BRAVOArchiveEstimatedSpaceRequirement нижче).
    # Відсутність ключа НЕ послаблює жодного наявного захисту: фіксований
    # поріг MinimumFreeSpaceGB вище лишається обов'язковим і незалежним.
    $archiveEstimatedSpaceMarginPercent = if (
        $maintenanceSettings.Limits -is [System.Collections.IDictionary] -and
        $maintenanceSettings.Limits.Contains('EstimatedSpaceMarginPercent') -and
        $null -ne $maintenanceSettings.Limits.EstimatedSpaceMarginPercent
    ) {
        [double]$maintenanceSettings.Limits.EstimatedSpaceMarginPercent
    } else {
        25.0
    }
    if ($archiveEstimatedSpaceMarginPercent -lt 0) {
        throw 'Maintenance.Limits.EstimatedSpaceMarginPercent не може бути відʼємним'
    }
} catch {
    Write-Host "ПОМИЛКА: Некоректна конфігурація перевірки вільного місця: $($_.Exception.Message)" -ForegroundColor Red
    Exit 30
}

# Запит на підвищення дозволу виконання скрипта
if ($requireAdministrator) {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    # Планувальник запускає робочі завдання від LocalSystem. У цьому
    # неінтерактивному сеансі UAC/RunAs недоступний, хоча SYSTEM має потрібні
    # системні права, тому не можна намагатися повторно підвищити процес.
    $isLocalSystem = $currentIdentity.User.Value -eq 'S-1-5-18'
    if (!$isLocalSystem -and !$currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Потрiбнi права адмiнiстратора. Запит UAC..." -ForegroundColor $logColors.WARNING

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $elevationSettings.PowerShellExecutable
        $processInfo.Arguments = $elevationSettings.ArgumentsTemplate -f $EntryScriptPath, $configPath
        if ($NoPause) {
            $processInfo.Arguments += " -NoPause"
        }
        if ($SyncBAZA) {
            $processInfo.Arguments += " -SyncBAZA"
        }
        $processInfo.Verb = $elevationSettings.Verb
        $processInfo.WindowStyle = $elevationSettings.WindowStyle

        try {
            $elevatedProcess = [System.Diagnostics.Process]::Start($processInfo)
            $elevatedProcess.WaitForExit()
            Exit $elevatedProcess.ExitCode
        } catch {
            Write-Host "UAC запит вiдхилено або сталася помилка: $($_.Exception.Message)" -ForegroundColor $logColors.ERROR
            Write-Host "Запустiть PowerShell з правами адмiнiстратора вручну" -ForegroundColor $logColors.WARNING
            Exit 1
        }
    }
}

# =============================================
# ЗАВАНТАЖЕННЯ СЕКРЕТІВ З CREDENTIAL MANAGER
# =============================================

$script:Login = $null
$script:resolvedSftpHost = $null
$script:sftpUrl = $null
$script:logFile = $null
$script:archivePassword = $null
$script:smbCredential = $null
$script:credentialInitializationError = $null
$script:archiveCredentialInitializationError = $null
$script:smbCredentialInitializationError = $null
$script:institutionSettingsInitializationError = $null
$script:notificationCredentialInitializationError = $null
$script:notificationProvider = ([string]$bravoSettings.NotificationProvider).ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($script:notificationProvider)) {
    $script:notificationProvider = "discord"
}
$script:notificationMode = [string]$bravoSettings.NotificationMode
if ([string]::IsNullOrWhiteSpace($script:notificationMode)) {
    $script:notificationMode = [string]$bravoSettings.SlackMode
}
if ([string]::IsNullOrWhiteSpace($script:notificationMode)) {
    $script:notificationMode = "none"
}
$script:notificationMode = $script:notificationMode.ToLowerInvariant()
$script:notificationRequestTimeoutSeconds = if ($null -ne $bravoSettings.NotificationRequestTimeoutSeconds) {
    [math]::Max(1, [int]$bravoSettings.NotificationRequestTimeoutSeconds)
} else {
    30
}
# SFTP.Enabled=false (5.2.2) вимикає вимогу креденшелів навіть для
# явного -SyncBAZA — глобально вимкнений destination не має жодних
# автоматичних/ручних network-операцій, доки оператор не поверне
# Enabled=true. ArchiveUpload і ScheduledSftpSyncRequired беруться вже
# effective (Enabled AND child), обгортка потрібна лише для терму
# $SyncBAZA, який не проходить через componentSettings.
$sftpCredentialRequired = [bool]$storageEffective.SFTP.Enabled -and (
    $SyncBAZA -or
    [bool]$storageEffective.SFTP.ArchiveUpload -or
    [bool]$bazaSyncEffective.ScheduledSftpSyncRequired -or
    # Log-lifecycle P1: вивантаження власного логу — самостійна причина
    # мати SFTP-сесію. Без цього терму ArchiveLogUploadEnabled=$true при
    # ArchiveUpload=$false (і без scheduled sync) лишав $script:sftpUrl
    # порожнім, і фінальний upload-блок мовчки пропускався назавжди.
    [bool]$componentSettings.SFTP.ArchiveLogUploadEnabled
)
$smbCredentialRequired = -not $SyncBAZA -and
    [bool]$storageEffective.SMB.ArchiveCopy
$archiveCredentialRequired = -not $SyncBAZA -and (
    [bool]$componentSettings.Archive.MODEL -or
    [bool]$componentSettings.Archive.BLOG -or
    [bool]$componentSettings.Archive.BRAVOEXCH
)
$institutionSettingsRequired = (
    $null -ne $bravoSettings.InstitutionName -and
    $null -ne $bravoSettings.InstitutionCode -and
    $null -ne $bravoSettings.ArchivePrefix
)
$script:notificationProviderDisplayName = if ($script:notificationProvider -eq "discord") {
    "Discord"
} else {
    "Slack"
}
# -SyncBAZA can emit an alert about objects which will never be uploaded.
# Load its webhook too, but treat a missing webhook as a notification error,
# not as a reason to stop the synchronization itself.
$notificationCredentialRequired = $script:notificationMode -ne "none"
$credentialHelperLoaded = $false

if ($institutionSettingsRequired -or
    $sftpCredentialRequired -or
    $smbCredentialRequired -or
    $archiveCredentialRequired -or
    $notificationCredentialRequired) {
    try {
        if ($null -eq (Get-Command -Name Initialize-BRAVOCredentialManager -ErrorAction SilentlyContinue)) {
            throw "вбудований Credential Manager недоступний"
        }
        $credentialHelperLoaded = $true
    } catch {
        # Маскується одразу при захопленні (а не лише при виведенні), щоб
        # жодне подальше читання цих script-scope змінних — консоль, лог,
        # повідомлення — не могло випадково пропустити секрет, який .NET
        # інколи вбудовує прямо в текст виключення Credential Manager.
        $sanitizedCredentialError = Protect-BRAVOLogSecret -Text $_.Exception.Message
        if ($sftpCredentialRequired) {
            $script:credentialInitializationError = $sanitizedCredentialError
        }
        if ($archiveCredentialRequired) {
            $script:archiveCredentialInitializationError = $sanitizedCredentialError
        }
        if ($smbCredentialRequired) {
            $script:smbCredentialInitializationError = $sanitizedCredentialError
        }
        if ($institutionSettingsRequired) {
            $script:institutionSettingsInitializationError = $sanitizedCredentialError
        }
        if ($notificationCredentialRequired) {
            $script:notificationCredentialInitializationError = $sanitizedCredentialError
        }
    }
}

# Ручний запуск (не через Планувальник) з відсутнiми обов'язковими
# обліковими даними — пропонуємо налаштувати їх зараз (лише для
# ПОТОЧНОГО користувача) замiсть того, щоб просто впасти з помилкою й
# змусити шукати окремий скрипт. -StoreFor CurrentUser навмисно: обліковi
# данi облiкового запису запланованого завдання (SYSTEM) налаштовуються
# окремо й свiдомо через BRAVO_SETUP.ps1/BRAVO_CREDENTIALS_SETUP.ps1
# -StoreFor ScheduledTaskAccount — тут ми їх не чіпаємо.
#
# -NoPause і перевірки нижче — той самий "чи це людина за клавіатурою"
# сигнал, що вже охороняє Wait-BRAVOManualExit: SYSTEM-завдання завжди
# передає -NoPause, а IsInputRedirected ловить дочірні процеси
# автоматизації (самотест, CI), які успадкували консоль батьківського
# процесу, але не мають кому відповідати на Read-Host.
if ($credentialHelperLoaded -and -not $NoPause -and
    ($archiveCredentialRequired -or $sftpCredentialRequired)) {
    $missingRequiredCredentialTargets = New-Object System.Collections.Generic.List[string]
    if ($archiveCredentialRequired) {
        $checkTarget = [string]$credentialSettings.Targets.ArchivePassword
        if ([string]::IsNullOrWhiteSpace($checkTarget)) { $checkTarget = "BRAVO_7Z_PASSWORD" }
        if ([string]::IsNullOrWhiteSpace((Get-BRAVOCredentialSecret -Target $checkTarget))) {
            [void]$missingRequiredCredentialTargets.Add($checkTarget)
        }
    }
    if ($sftpCredentialRequired) {
        $checkLoginTarget = [string]$credentialSettings.Targets.SFTPLogin
        if ([string]::IsNullOrWhiteSpace($checkLoginTarget)) { $checkLoginTarget = "BRAVO_SFTP_LOGIN" }
        $checkPasswordTarget = [string]$credentialSettings.Targets.SFTPPassword
        if ([string]::IsNullOrWhiteSpace($checkPasswordTarget)) { $checkPasswordTarget = "BRAVO_SFTP_PASSWORD" }
        if ([string]::IsNullOrWhiteSpace((Get-BRAVOCredentialSecret -Target $checkLoginTarget))) {
            [void]$missingRequiredCredentialTargets.Add($checkLoginTarget)
        }
        if ([string]::IsNullOrWhiteSpace((Get-BRAVOCredentialSecret -Target $checkPasswordTarget))) {
            [void]$missingRequiredCredentialTargets.Add($checkPasswordTarget)
        }
    }

    if ($missingRequiredCredentialTargets.Count -gt 0) {
        $isRealInteractiveSession = $false
        try {
            $isRealInteractiveSession = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
        } catch {
            $isRealInteractiveSession = $false
        }
        if ($isRealInteractiveSession) {
            Write-Host ""
            Write-Host "Вiдсутнi обов'язковi облiковi данi: $($missingRequiredCredentialTargets -join ', ')" -ForegroundColor $logColors.WARNING
            Write-Host "Запускаю налаштування для поточного користувача ($([Security.Principal.WindowsIdentity]::GetCurrent().Name))..." -ForegroundColor $logColors.WARNING
            $credentialsSetupPath = Join-Path $bravoScriptDirectory 'BRAVO_CREDENTIALS_SETUP.ps1'
            if (Test-Path -LiteralPath $credentialsSetupPath -PathType Leaf) {
                # Окремий процес, не dot-source/&: BRAVO_CREDENTIALS_SETUP.ps1
                # сам виконує повне завантаження BRAVO.config і перезаписав
                # би глобальний стан (pathSettings, componentSettings тощо)
                # цього процесу — ізоляція важливіша за швидкість запуску.
                # AUTO-намір: -ConfigPath вбудовується лише за explicit
                # (той самий гейт, що канал Archive->Health) — інакше
                # helper трактував би auto-derived відсутній шлях як
                # explicit і fail-closed ламав first-run налаштування.
                $credentialsSetupConfigArguments = @()
                if ($configPathWasExplicit -and -not [string]::IsNullOrWhiteSpace($ConfigPath)) {
                    $credentialsSetupConfigArguments = @('-ConfigPath', $ConfigPath)
                }
                & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                    -File $credentialsSetupPath `
                    @credentialsSetupConfigArguments `
                    -Action Ensure `
                    -Component Required `
                    -StoreFor CurrentUser
            } else {
                Write-Host "Не знайдено BRAVO_CREDENTIALS_SETUP.ps1 — налаштуйте облiковi данi вручну." -ForegroundColor $logColors.WARNING
            }
        }
    }
}

if ($credentialHelperLoaded) {
    try {
        [void](Import-BRAVOInstitutionSettings `
            -CredentialSettings $credentialSettings `
            -BravoSettings $bravoSettings)
    } catch {
        Write-Host "ПОМИЛКА: Некоректні локальні параметри установи у Credential Manager: $(Protect-BRAVOLogSecret -Text $_.Exception.Message)" `
            -ForegroundColor $logColors.ERROR
        exit 1
    }
} elseif ($institutionSettingsRequired) {
    Write-Host "ПОМИЛКА: Не вдалося завантажити локальні параметри установи: $($script:institutionSettingsInitializationError)" `
        -ForegroundColor $logColors.ERROR
    exit 1
}

if ($credentialHelperLoaded -and $archiveCredentialRequired) {
    try {
        $archiveCredentialTarget = [string]$credentialSettings.Targets.ArchivePassword
        if ([string]::IsNullOrWhiteSpace($archiveCredentialTarget)) {
            $archiveCredentialTarget = "BRAVO_7Z_PASSWORD"
        }
        if ([string]::IsNullOrWhiteSpace($archiveCredentialTarget)) {
            throw "не вдалося визначити назву запису Credential Manager для пароля архівів"
        }
        $script:archivePassword = Get-BRAVOCredentialSecret -Target $archiveCredentialTarget
        if ([string]::IsNullOrWhiteSpace($script:archivePassword)) {
            throw "запис Credential Manager '$archiveCredentialTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
    } catch {
        $script:archiveCredentialInitializationError = Protect-BRAVOLogSecret -Text $_.Exception.Message
    }
}

if ($credentialHelperLoaded -and $sftpCredentialRequired) {
    try {
        $sftpLoginTarget = [string]$credentialSettings.Targets.SFTPLogin
        $sftpPasswordTarget = [string]$credentialSettings.Targets.SFTPPassword
        if ([string]::IsNullOrWhiteSpace($sftpLoginTarget)) {
            $sftpLoginTarget = "BRAVO_SFTP_LOGIN"
        }
        if ([string]::IsNullOrWhiteSpace($sftpPasswordTarget)) {
            $sftpPasswordTarget = "BRAVO_SFTP_PASSWORD"
        }

        $storedSftpLogin = Get-BRAVOCredentialSecret -Target $sftpLoginTarget
        $storedSftpPassword = Get-BRAVOCredentialSecret -Target $sftpPasswordTarget
        if ([string]::IsNullOrWhiteSpace($storedSftpLogin)) {
            throw "запис Credential Manager '$sftpLoginTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
        if ([string]::IsNullOrWhiteSpace($storedSftpPassword)) {
            throw "запис Credential Manager '$sftpPasswordTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }

        $script:Login = ([string]$storedSftpLogin).Trim()
        $legacySftpHostVariable = Get-Variable -Name 'sftpHost' -Scope Global -ErrorAction SilentlyContinue
        $configuredSftpHost = if ($null -ne $legacySftpHostVariable) { [string]$legacySftpHostVariable.Value } else { $null }
        $script:resolvedSftpHost = Resolve-BRAVOSftpHostName `
            -UserName $script:Login `
            -HostTemplate ([string]$sftpHostTemplate) `
            -FallbackHostName $configuredSftpHost
        $script:sftpUrl = New-BRAVOSftpUrl `
            -HostName $script:resolvedSftpHost `
            -Port ([int]$sftpPort) `
            -UserName $script:Login `
            -Password ([string]$storedSftpPassword)
        $storedSftpLogin = $null
        $storedSftpPassword = $null
    } catch {
        $script:credentialInitializationError = Protect-BRAVOLogSecret -Text $_.Exception.Message
    }
}

if ($credentialHelperLoaded -and $smbCredentialRequired) {
    try {
        $smbLoginTarget = [string]$credentialSettings.Targets.SMBLogin
        $smbPasswordTarget = [string]$credentialSettings.Targets.SMBPassword
        if ([string]::IsNullOrWhiteSpace($smbLoginTarget)) {
            $smbLoginTarget = "BRAVO_SMB_LOGIN"
        }
        if ([string]::IsNullOrWhiteSpace($smbPasswordTarget)) {
            $smbPasswordTarget = "BRAVO_SMB_PASSWORD"
        }

        $storedSmbLogin = Get-BRAVOCredentialSecret -Target $smbLoginTarget
        # SecureString, не рядок: далі потрібен лише PSCredential, тому
        # плейнтекст пароля SMB не створюється взагалі (аудит #5).
        $storedSmbPassword = Get-BRAVOCredentialSecureSecret -Target $smbPasswordTarget
        if ([string]::IsNullOrWhiteSpace($storedSmbLogin)) {
            throw "запис Credential Manager '$smbLoginTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
        if ($null -eq $storedSmbPassword -or $storedSmbPassword.Length -eq 0) {
            throw "запис Credential Manager '$smbPasswordTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }

        $script:smbCredential = New-BRAVOSecureCredential `
            -UserName ([string]$storedSmbLogin) `
            -SecureSecret $storedSmbPassword
        $storedSmbLogin = $null
        $storedSmbPassword = $null
    } catch {
        $script:smbCredentialInitializationError = Protect-BRAVOLogSecret -Text $_.Exception.Message
    }
}

# =============================================
# ІНІЦІАЛІЗАЦІЯ ЗМІННИХ З КОНФІГУРАЦІЇ
# =============================================

# РЕЖИМ СУМІСНОСТІ
# Явно $script: — ту саму змінну пише Test-Compatibility
# ($script:compatibilityMode) і читають New-SHA512Hash ($script:) та Main
# (без scope). Некваліфіковане присвоєння всередині Invoke-BRAVOArchive
# створило б локальну копію, яка затінила б для Main фактичний режим.
$script:compatibilityMode = $false  # Автоматично визначається нижче

# =============================================
# НАЛАШТУВАННЯ КОНСОЛІ
# =============================================
$configuredOutputEncoding = [System.Text.Encoding]::GetEncoding($consoleSettings.OutputEncodingCodePage)
$global:OutputEncoding = $configuredOutputEncoding
try {
    # Див. Test-BRAVOConsoleCodePageChangeSafe: UTF-8 у консолі SYSTEM на
    # Windows до 10 ламає Write-Host з кирилицею (Win32 0x1F).
    if (Test-BRAVOConsoleCodePageChangeSafe -CodePage $configuredOutputEncoding.CodePage) {
        [Console]::OutputEncoding = $configuredOutputEncoding
    }
} catch {
    # Деякі PowerShell-hosts і запуски через Task Scheduler не мають
    # дійсного консольного дескриптора. Кодування зовнішніх команд уже
    # налаштовано через $OutputEncoding, тому роботу можна продовжити.
}
try {
    $Host.UI.RawUI.WindowTitle = $consoleSettings.WindowTitleTemplate -f $ScriptVersion
    $Host.UI.RawUI.BackgroundColor = $consoleSettings.BackgroundColor
    $Host.UI.RawUI.ForegroundColor = $consoleSettings.ForegroundColor
} catch {
    # RawUI може бути недоступним у неінтерактивному PowerShell-host.
}
if ($consoleSettings.ClearOnStart) {
    try {
        Clear-Host
    } catch {
        # Очищення екрана не є обов'язковим для роботи скрипта.
    }
}

# =============================================
# ФУНКЦІЇ ПЕРЕВІРКИ СУМІСНОСТІ
# =============================================

function Test-Compatibility {
    Write-BRAVOLog -Component 'STARTUP' -Message "Перевiрка сумiсностi системи..." -Level "INFO"
    $compatibility = Get-BRAVOCompatibilityInfo
    $powerShellUpdate = Get-BRAVOPowerShellUpdateRecommendation
    $script:BRAVOCompatibility = $compatibility
    $script:BRAVOPowerShellUpdate = $powerShellUpdate

    $script:hasFileHash = $compatibility.FileHashProvider -eq "Get-FileHash"
    $script:hasNetConnection = $compatibility.NetworkProvider -eq "Test-NetConnection"
    $script:compatibilityMode = [bool]$compatibility.IsCompatibilityMode

    Write-BRAVOLog -Component 'STARTUP' -Message "Windows: $($BRAVOCompatibility.WindowsVersion); PowerShell: $($BRAVOCompatibility.PowerShellVersion)" -Level "DEBUG"
    Write-BRAVOLog -Component 'STARTUP' -Message "WMI: $($BRAVOCompatibility.WmiProvider); Hash: $($BRAVOCompatibility.FileHashProvider); Network: $($BRAVOCompatibility.NetworkProvider); Files: $($BRAVOCompatibility.ChildItemProvider)" -Level "DEBUG"

    if ($script:compatibilityMode) {
        Write-BRAVOLog -Component 'STARTUP' -Message "Режим сумiсностi активний: несумiснi сучаснi API буде автоматично замiнено" -Level "INFO"
    } else {
        Write-BRAVOLog -Component 'STARTUP' -Message "Стандартний режим" -Level "INFO"
    }
    if ($powerShellUpdate.IsUpdateRecommended) {
        Write-BRAVOLog -Component 'STARTUP' -Message $powerShellUpdate.Message -Level "WARNING" -Environmental
    }
    $osSupportTier = Get-BRAVOOSSupportTier
    $script:BRAVOOSSupportTier = $osSupportTier
    Write-BRAVOLog -Component 'STARTUP' -Message "Підтримка ОС: $($osSupportTier.Tier) — Windows $($osSupportTier.OperatingSystem) ($($osSupportTier.OperatingSystemVersion), build $($osSupportTier.Build)); PowerShell $($osSupportTier.PowerShellVersion); .NET release $($osSupportTier.DotNetRelease)" -Level "INFO"
    if ($osSupportTier.Tier -eq "LegacyBestEffort") {
        # Рівень INFO навмисно: legacy-tier — environmental-метрика, а не
        # результат операції. WARNING тут інкрементував лічильник
        # попереджень, і КОЖЕН успішний прогін на Server 2012 R2/2016
        # завершувався кодом 10 (SuccessWithWarnings), а звіт ішов у канал
        # ALERTS замість GENERAL — хоча на архівацію рівень ОС не впливає.
        # Постійне нагадування про legacy-ОС — відповідальність
        # BRAVO_HEALTH (там воно лишається WARNING), той самий принцип,
        # що вже застосовано до віку Windows-оновлень (health-метрика,
        # а не умова запуску — див. BRAVO_TASKS_INSTALL.ps1).
        Write-BRAVOLog -Component 'STARTUP' -Message $osSupportTier.Message -Level "INFO"
    } elseif ($osSupportTier.Tier -eq "Unsupported") {
        if ($env:BRAVO_ALLOW_UNSUPPORTED_OS -eq "1") {
            Write-BRAVOLog -Component 'STARTUP' -Message "$($osSupportTier.Message) Продовжено через BRAVO_ALLOW_UNSUPPORTED_OS=1." -Level "WARNING"
        } else {
            Write-BRAVOLog -Component 'STARTUP' -Message $osSupportTier.Message -Level "ERROR"
            # #291: exit оминає хвіст Main — статус пишемо тут. Виклик іде з
            # Main після lock і конфігурації ($stateRoot), тож це статус
            # саме цього прогону.
            $unsupportedOsExitCode = Resolve-BRAVOExitCode -InvalidConfiguration
            # Фінальна Operations-подія у finally читає $script:processExitCode —
            # без цього вона звітувала б 0 (Success) при exit 30.
            $script:processExitCode = $unsupportedOsExitCode
            Write-BRAVOArchiveOperationStatus `
                -ExitCode $unsupportedOsExitCode `
                -StartedAt $(if (Test-Path variable:scriptStartTime) { $scriptStartTime } else { Get-Date }) `
                -EarlyExitReason 'UnsupportedOperatingSystem'
            exit $unsupportedOsExitCode
        }
    }

    # $arcPath/$winSCPPath/$winSCPAssemblyPath доступні лише після
    # Import-BravoConfiguration, тому цю перевірку не можна винести у
    # ранній preinit разом із двома вище.
    $toolIntegrity = Get-BRAVOToolIntegrityRecommendation `
        -ToolPaths @($arcPath, $winSCPPath, $winSCPAssemblyPath) `
        -ManifestPath (Join-Path $toolsPath "TOOLS_INTEGRITY.json")
    $script:BRAVOToolIntegrity = $toolIntegrity
    if ($toolIntegrity.HasIntegrityIssue) {
        Write-BRAVOLog -Component 'STARTUP' -Message $toolIntegrity.Message -Level "WARNING"
    }

    # Еталонний маніфест (version-controlled) — на відміну від
    # TOFU-базової лінії вище, він здатний ЗАБЛОКУВАТИ запуск. Це
    # найважливіша перевірка старту: заплановане завдання виконується від
    # NT AUTHORITY\SYSTEM, тому підмінений 7za.exe/WinSCP.com отримав би
    # найвищі права в системі.
    $manifestMode = 'Enforce'
    $manifestPath = Join-Path $toolsPath "TOOLS_MANIFEST.json"
    if ($toolIntegritySettings -is [System.Collections.IDictionary]) {
        if (-not [string]::IsNullOrWhiteSpace([string]$toolIntegritySettings.Mode)) {
            $manifestMode = [string]$toolIntegritySettings.Mode
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$toolIntegritySettings.ManifestPath)) {
            $manifestPath = [string]$toolIntegritySettings.ManifestPath
        }
    }

    # BRAVO.config не входить до RUNTIME_MANIFEST.json (він
    # сервер-специфічний, спільного еталонного хешу не існує), тому
    # послаблення захисту через один рядок конфігурації має бути
    # принаймні гучним у лозі, а не тихим.
    if ($manifestMode -ne 'Enforce') {
        Write-BRAVOLog -Component 'STARTUP' -Message (
            "УВАГА: перевірку цілісності інструментів послаблено в конфігурації " +
            "(toolIntegritySettings.Mode = $manifestMode). Підміна 7za/WinSCP НЕ заблокує запуск. " +
            "Це тимчасовий режим міграції, не для постійної експлуатації."
        ) -Level "WARNING"
    }

    $script:BRAVOToolManifest = Test-BRAVOToolManifestIntegrity `
        -ToolsDirectory $toolsPath `
        -ManifestPath $manifestPath `
        -Mode $manifestMode

    if (-not $script:BRAVOToolManifest.IsValid) {
        $manifestLevel = if ($script:BRAVOToolManifest.ShouldBlock) { "ERROR" } else { "WARNING" }
        Write-BRAVOLog -Component 'STARTUP' -Message $script:BRAVOToolManifest.Message -Level $manifestLevel

        if ($script:BRAVOToolManifest.ShouldBlock) {
            Send-ToolIntegrityAlert -Result $script:BRAVOToolManifest
            # #291: як і для непідтримуваної ОС — статус перед exit.
            $toolIntegrityExitCode = Resolve-BRAVOExitCode -ToolIntegrityViolation
            $script:processExitCode = $toolIntegrityExitCode
            Write-BRAVOArchiveOperationStatus `
                -ExitCode $toolIntegrityExitCode `
                -StartedAt $(if (Test-Path variable:scriptStartTime) { $scriptStartTime } else { Get-Date }) `
                -EarlyExitReason 'ToolIntegrityViolation'
            exit $toolIntegrityExitCode
        }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$script:BRAVOToolManifest.Message)) {
        Write-BRAVOLog -Component 'STARTUP' -Message $script:BRAVOToolManifest.Message -Level "WARNING"
    }

    return $compatibility
}

function Send-ToolIntegrityAlert {
    param([Parameter(Mandatory = $true)]$Result)

    # Критичне сповіщення надсилається незалежно від NotifyOnSuccess та
    # інших "тихих" режимів: це подія безпеки, а не рутинний статус
    # backup. Єдине, що її придушує, — явно вимкнені сповіщення
    # (-NoSlack / notificationMode = none) або ненастроєний webhook.
    #
    # Гейт нотифікації (NoSlack/notificationMode=none/route=none/
    # webhook не налаштовано) раніше завершував функцію через `return`
    # ДО Operations-події внизу — dashboard мовчки не бачив CRITICAL-подію
    # про порушення цілісності лише тому, що Slack/Discord вимкнено на
    # цьому сервері (review finding). Тепер нотифікаційний блок НЕ
    # використовує ранній `return`: він або надсилає сповіщення, або лише
    # логує причину недоставки, а Operations-подія внизу виконується
    # завжди незалежно від результату.
    if ($NoSlack -or $script:notificationMode -eq "none") {
        Write-BRAVOLog -Component 'STARTUP' -Message "Критичне сповіщення про цілісність інструментів не відправлено: сповіщення вимкнено параметрами запуску або конфігурацією" -Level "WARNING"
    } else {
        # Маршрутизація (GENERAL/ALERTS) і резолв webhook — виключно через
        # централізований API BRAVO.Notifications; Archive сам канал не обирає.
        $notificationRoute = Resolve-BRAVONotificationRoute `
            -Severity "CRITICAL" `
            -NotificationMode $script:notificationMode `
            -RoutingTable $backupMonitoring.NotificationRouting
        if ($notificationRoute -eq "none") {
            Write-BRAVOLog -Component 'STARTUP' -Message "Критичне сповіщення про цілісність інструментів не відправлено: сповіщення вимкнено параметрами запуску або конфігурацією" -Level "WARNING"
        } else {
            $notificationWebhookUrl = $null
            try {
                $notificationWebhookUrl = Resolve-BRAVONotificationEndpoint `
                    -Provider $script:notificationProvider `
                    -Route $notificationRoute `
                    -CredentialTargets $backupMonitoring.NotificationCredentialTargets
            } catch {
                Write-BRAVOLog -Component 'STARTUP' -Message "Критичне сповіщення про цілісність інструментів не відправлено: webhook не налаштовано" -Level "WARNING"
            }

            if ($notificationWebhookUrl) {
                try {
                    $hostInformation = Get-HostInformation
                    $archiveBuildIdText = if ([string]::IsNullOrWhiteSpace([string]$ScriptBuildId)) {
                        "невідома"
                    } else {
                        [string]$ScriptBuildId
                    }
                    $alertText = New-BRAVOOperatorNotificationMessage `
                        -Severity "CRITICAL" `
                        -Operation "BRAVO — ПОРУШЕНО ЦІЛІСНІСТЬ КОМПЛЕКТУ" `
                        -ActionText "не запускати backup вручну; перевірити RUNTIME_MANIFEST/TOOLS_MANIFEST та походження змінених файлів." `
                        -ReasonLines @([string]$Result.Message) `
                        -InstitutionName ([string]$backupMonitoring.InstitutionName) `
                        -InstitutionCode ([string]$backupMonitoring.InstitutionCode) `
                        -HostInformation $hostInformation `
                        -ResultLines @("Архівацію не виконано (код завершення 32).") `
                        -Timestamp (Get-Date) `
                        -ProductName "BRAVO Archive" `
                        -Version ([string]$global:ScriptVersion) `
                        -BuildId $archiveBuildIdText `
                        -LogPath ([string]$script:logFile) `
                        -LogLabel "Журнал"

                    $outboundMessages = ConvertTo-BRAVONotificationPayloadText -Provider $script:notificationProvider -Message $alertText
                    Send-BRAVONotificationChunks `
                        -Provider $script:notificationProvider `
                        -WebhookUrl $notificationWebhookUrl `
                        -MessageChunks $outboundMessages `
                        -TimeoutSeconds $script:notificationRequestTimeoutSeconds
                    Write-BRAVOLog -Component 'STARTUP' -Message "Критичне сповіщення про цілісність інструментів відправлено у $($script:notificationProviderDisplayName)" -Level "SUCCESS"
                } catch {
                    # Неможливість сповістити не змінює рішення блокувати запуск.
                    Write-BRAVOLog -Component 'STARTUP' -Message "Не вдалося відправити критичне сповіщення про цілісність інструментів: $(Protect-BRAVOLogSecret -Text $_.Exception.Message)" -Level "ERROR"
                }
            }
        }
    }

    if ($null -ne $operationsReportingSettings) {
        try {
            Send-BRAVOOperationsEvent `
                -OperationsReportingSettings $operationsReportingSettings `
                -CredentialTargets $credentialSettings.Targets `
                -InstitutionCode ([string]$backupMonitoring.InstitutionCode) `
                -Category 'backup' -Severity 'CRITICAL' `
                -Component 'Archive' `
                -Message "Порушено цілісність комплекту: $([string]$Result.Message)"
        } catch {
            Write-BRAVOLog -Component 'STARTUP' -Message "Не вдалося відправити подію в Operations: $(Protect-BRAVOLogSecret -Text $_.Exception.Message)" -Level "WARNING"
        }
    }
}

function Send-BRAVOArchiveFreeSpaceAlert {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][double]$MinimumFreeSpaceGB
    )

    # Гейт нотифікації нижче раніше завершував функцію через `return` ДО
    # Operations-події внизу (той самий review finding, що для
    # Send-ToolIntegrityAlert) — тепер лише логує причину недоставки
    # сповіщення й не блокує Operations-подію.
    if ($NoSlack -or $script:notificationMode -eq 'none') {
        Write-BRAVOLog -Component 'STARTUP' -Message (
            'Критичне сповіщення про нестачу вільного місця не відправлено: ' +
            'сповіщення вимкнено параметрами запуску або конфігурацією'
        ) -Level 'WARNING'
    } else {
        $notificationRoute = Resolve-BRAVONotificationRoute `
            -Severity 'CRITICAL' `
            -NotificationMode $script:notificationMode `
            -RoutingTable $backupMonitoring.NotificationRouting
        if ($notificationRoute -eq 'none') {
            Write-BRAVOLog -Component 'STARTUP' -Message (
                'Критичне сповіщення про нестачу вільного місця не відправлено: ' +
                'сповіщення вимкнено параметрами запуску або конфігурацією'
            ) -Level 'WARNING'
        } else {
            $notificationWebhookUrl = $null
            try {
                $notificationWebhookUrl = Resolve-BRAVONotificationEndpoint `
                    -Provider $script:notificationProvider `
                    -Route $notificationRoute `
                    -CredentialTargets $backupMonitoring.NotificationCredentialTargets
            } catch {
                Write-BRAVOLog -Component 'STARTUP' -Message (
                    'Критичне сповіщення про нестачу вільного місця не відправлено: ' +
                    "webhook для $($script:notificationProviderDisplayName) не налаштовано"
                ) -Level 'WARNING'
            }

            if ($notificationWebhookUrl) {
                try {
                    $hostInformation = Get-HostInformation
                    $archiveBuildIdText = if ([string]::IsNullOrWhiteSpace([string]$ScriptBuildId)) {
                        'невідома'
                    } else {
                        [string]$ScriptBuildId
                    }
                    $reasonLines = @(
                        @($Result.Problems) |
                            ForEach-Object { ":x: $([string]$_)" }
                    )
                    $driveLines = @(
                        @($Result.DriveStatus) |
                            ForEach-Object {
                                ':floppy_disk: {0}: {1} GB вільно з {2} GB' -f `
                                    ([string]$_.Drive).TrimEnd(':'), $_.FreeSpaceGB, $_.TotalSpaceGB
                            }
                    )
                    $alertText = New-BRAVOOperatorNotificationMessage `
                        -Severity 'CRITICAL' `
                        -Operation 'BRAVO ARCHIVE — НЕДОСТАТНЬО ВІЛЬНОГО МІСЦЯ' `
                        -ActionText 'звільнити місце на проблемному диску та повторити запуск архівації.' `
                        -ReasonLines $reasonLines `
                        -InstitutionName ([string]$backupMonitoring.InstitutionName) `
                        -InstitutionCode ([string]$backupMonitoring.InstitutionCode) `
                        -HostInformation $hostInformation `
                        -ResultLines (@(
                                'Архівацію не розпочато (код завершення 40).',
                                "Порогове значення: $MinimumFreeSpaceGB GB на кожному локальному Fixed-диску"
                            ) + $driveLines) `
                        -Timestamp (Get-Date) `
                        -ProductName 'BRAVO Archive' `
                        -Version ([string]$global:ScriptVersion) `
                        -BuildId $archiveBuildIdText `
                        -LogPath ([string]$script:logFile) `
                        -LogLabel 'Журнал'

                    $outboundMessages = ConvertTo-BRAVONotificationPayloadText -Provider $script:notificationProvider -Message $alertText
                    Send-BRAVONotificationChunks `
                        -Provider $script:notificationProvider `
                        -WebhookUrl $notificationWebhookUrl `
                        -MessageChunks $outboundMessages `
                        -TimeoutSeconds $script:notificationRequestTimeoutSeconds
                    Write-BRAVOLog -Component 'STARTUP' -Message (
                        "Критичне повідомлення (помилки місця) відправлено в " +
                        $script:notificationProviderDisplayName
                    ) -Level 'SUCCESS'
                } catch {
                    # Сповіщення є вторинним каналом: його збій не змінює primary exit 40.
                    Write-BRAVOLog -Component 'STARTUP' -Message (
                        'Не вдалося відправити критичне сповіщення про нестачу вільного місця: ' +
                        (Protect-BRAVOLogSecret -Text $_.Exception.Message)
                    ) -Level 'ERROR'
                }
            }
        }
    }

    if ($null -ne $operationsReportingSettings) {
        try {
            Send-BRAVOOperationsEvent `
                -OperationsReportingSettings $operationsReportingSettings `
                -CredentialTargets $credentialSettings.Targets `
                -InstitutionCode ([string]$backupMonitoring.InstitutionCode) `
                -Category 'backup' -Severity 'CRITICAL' `
                -Component 'Archive' `
                -Message 'Недостатньо вільного місця для архівації' `
                -Details @{ minimumFreeSpaceGB = $MinimumFreeSpaceGB; problems = @($Result.Problems) }
        } catch {
            Write-BRAVOLog -Component 'STARTUP' -Message "Не вдалося відправити подію в Operations: $(Protect-BRAVOLogSecret -Text $_.Exception.Message)" -Level "WARNING"
        }
    }
}

function New-SHA512HashLegacy {
    param(
        [string]$FilePath,
        [string]$HashFilePath
    )
    
    Write-BRAVOLog -Component 'HASH' -Message "Створення SHA512 хешу (сумiсний режим): $(Split-Path $FilePath -Leaf)"
    
    if (-not (Test-Path $FilePath)) {
        Write-BRAVOLog -Component 'HASH' -Message "Файл не знайдено: $FilePath" -Level "ERROR"
        return $false
    }
    
    try {
        # Використовуємо .NET для створення хешу в сумiсному режимi
        $fileStream = [System.IO.File]::OpenRead($FilePath)
        $hasher = [System.Security.Cryptography.SHA512]::Create()
        $hashBytes = $hasher.ComputeHash($fileStream)
        $fileStream.Close()
        
        # Конвертуємо байти в hex-рядок
        $hash = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()
        $fileName = (Get-Item $FilePath).Name
        
        # Виправлення для PowerShell 3.0: використовуємо .NET метод замiсть Out-File з -NoNewline
        [System.IO.File]::WriteAllText($HashFilePath, "${hash} *${fileName}", [System.Text.Encoding]::GetEncoding($hashFileEncoding))
        
        Write-BRAVOLog -Component 'HASH' -Message "Хеш створено (сумiсний режим): $HashFilePath" -Level "SUCCESS"
        return $true
    } catch {
        Write-BRAVOLog -Component 'HASH' -Message "Помилка створення хешу (сумiсний режим): $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($hasher) { $hasher.Dispose() }
    }
}

# =============================================
# ДОПОМІЖНІ ФУНКЦІЇ
# =============================================

# Поточний компонент журналу. Секції головного потоку виставляють його, щоб
# записи потрапляли у правильну колонку [COMPONENT] без правки кожного виклику.
$script:BRAVOLogComponent = 'ARCHIVE'

function Set-BRAVOLogComponent {
    param([Parameter(Mandatory = $true)][string]$Component)

    $script:BRAVOLogComponent = $Component
}

# Main — лінійний оркестратор, поділений заголовками "=== СЕКЦІЯ ===".
# Заголовок уже несе семантику етапу, тому компонент виводиться з нього:
# так усі записи секції потрапляють у потрібну колонку без правки викликів.
# Порядок перевірок важливий: "СИНХРОНIЗАЦIЯ BAZA НА SFTP" має дати SFTP,
# а не BAZA. У текстах співіснують кирилична 'І' та латинська 'I'.
function Resolve-BRAVOLogComponentFromHeader {
    param([Parameter(Mandatory = $true)][string]$Header)

    switch -regex ($Header) {
        '(?i)BAZA[_ ]APP'               { return 'BAZA_APP' }
        '(?i)BAZA[_ ]WWW'               { return 'BAZA_WWW' }
        '(?i)SFTP'                      { return 'SFTP-ARCHIVE' }
        'SMB|NAS'                       { return 'SMB' }
        '(?i)АРХ[IІ]ВАЦ[IІ]Я'           { return 'ARCHIVE' }
        '(?i)ХЕШУ'                      { return 'HASH' }
        '(?i)ЛОГ[IІ]В'                  { return 'CLEANUP' }
        '(?i)ШЛЯХ[IІ]В'                 { return 'PATHS' }
        '(?i)ПАРОЛЯ'                    { return 'CREDENTIALS' }
        '(?i)УЗГОДЖЕНОСТ[IІ]'           { return 'VSS' }
        '(?i)СУМ[IІ]СНОСТ[IІ]'          { return 'STARTUP' }
        '(?i)РЕЗЕРВНИХ КОП[IІ]Й'        { return 'HEALTH' }
        '(?i)ЗАВЕРШЕННЯ РОБОТИ'         { return 'SUMMARY' }
        '(?i)ПОЧАТОК РОБОТИ|ОПЦ[IІ]Ї'   { return 'STARTUP' }
        '(?i)BAZA'                      { return 'BAZA' }
    }
    return 'ARCHIVE'
}

# Тимчасовий шим сумісності зі старим Write-Log. Делегує у BRAVO.Logging,
# який сам вирішує, що потрапить у файл, а що — в консоль.
# Прибрати, коли всі виклики перейдуть на Write-BRAVOLog напряму.
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = $defaultLogLevel,
        [int]$SeparatorLength = $logSeparatorLength,
        [switch]$NoTimestamp,
        [switch]$FileOnly
    )

    $component = $script:BRAVOLogComponent

    # Роздільники й заголовки формували структуру старої консолі. Тепер її
    # задають етапи (Write-BRAVOStepResult), тому в консоль вони не йдуть.
    # dev.18: голий роздільник "==="/"=" БІЛЬШЕ НЕ пише окремий запис у
    # журнал. Реальний DEV-LIMS лог показав структуровані записи з
    # timestamp/level/component, але порожнім Message — саме цей виклик
    # (кожен голий "===" стоїть безпосередньо перед "=== ЗАГОЛОВОК ===",
    # який і так фіксує ту саму мить і компонент повноцінним текстом;
    # унікальної хронологічної інформації тут немає). Заголовки нижче
    # (гілка "=== ... ===") лишаються повністю без змін — вони й далі
    # пишуться в журнал з повним текстом заголовка.
    if ($Message -eq "=" -or $Message -eq "===") {
        return
    }
    if ($Message -match "^=== .* ===$") {
        $component = Resolve-BRAVOLogComponentFromHeader -Header $Message
        Set-BRAVOLogComponent -Component $component
        Write-BRAVOLog -Message $Message -Level 'INFO' -Component $component -NoConsole
        return
    }

    $normalizedLevel = if ([string]::IsNullOrWhiteSpace($Level)) {
        'INFO'
    } else {
        $Level.Trim().ToUpperInvariant()
    }
    if (@('TRACE', 'DEBUG', 'INFO', 'SUCCESS', 'WARNING', 'ERROR', 'FATAL') -notcontains $normalizedLevel) {
        $normalizedLevel = 'INFO'
    }

    if ($FileOnly) {
        Write-BRAVOLog -Message $Message -Level $normalizedLevel -Component $component -NoConsole
        return
    }
    Write-BRAVOLog -Message $Message -Level $normalizedLevel -Component $component
}

# Write-BRAVOLogException навмисно зберігає стек на DEBUG для звичайних
# викликів. Для фатального краху Archive дублюємо лише діагностичні деталі
# у файл на INFO, без другого операторського повідомлення в консолі.
function Write-BRAVOArchiveFatalDiagnostics {
    param(
        [Parameter(Mandatory = $true)][Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory = $true)][string]$Context
    )

    Write-BRAVOLogException `
        -ErrorRecord $ErrorRecord `
        -Component 'ARCHIVE' `
        -Context $Context

    $details = New-Object System.Collections.Generic.List[string]
    if ($null -ne $ErrorRecord.Exception) {
        [void]$details.Add("Тип: $($ErrorRecord.Exception.GetType().FullName)")
    }
    if ($null -ne $ErrorRecord.InvocationInfo -and
        -not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.InvocationInfo.PositionMessage)) {
        [void]$details.Add("Розташування: $($ErrorRecord.InvocationInfo.PositionMessage)")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ScriptStackTrace)) {
        [void]$details.Add("Стек: $($ErrorRecord.ScriptStackTrace -replace '\r?\n', ' | ')")
    }
    if ($details.Count -gt 0) {
        Write-BRAVOLog `
            -Message ("$Context. Діагностика: " + ($details -join ' || ')) `
            -Level 'INFO' `
            -Component 'ARCHIVE' `
            -NoConsole
    }
}

function Get-BRAVOArchiveVSSSummaryValue {
    param(
        [object]$SnapshotSet,
        [int]$EnabledArchiveCount
    )

    if ($null -ne $SnapshotSet -and
        -not [string]::IsNullOrWhiteSpace([string]$SnapshotSet.SnapshotSetId)) {
        return "OK ($($SnapshotSet.SnapshotSetId))"
    }
    if ($EnabledArchiveCount -eq 0) {
        return 'SKIPPED'
    }
    return 'FAILED'
}

function Get-BRAVOArchiveGenerationFailureSummaryReason {
    param(
        [bool]$GenerationFinalizationFailed,
        [string]$GenerationFinalizationFailureReason
    )

    if (-not $GenerationFinalizationFailed) {
        return $null
    }
    return "Generation: FAILED. Причина: $GenerationFinalizationFailureReason"
}

# Усі три історичні хелпери прогресу тепер малюють одну смугу
# (BRAVO.Console). Раніше загальна й покомпонентна смуги дублювали одна одну,
# а індикатор 7-Zip додавав третій вкладений рівень.
function Show-ScriptProgress {
    param(
        [string]$Status,
        [int]$PercentComplete = 0,
        [switch]$Completed
    )

    if (-not $progressSettings.Enabled -or -not $progressSettings.ShowOverallProgress) {
        return
    }

    if ($Completed) {
        Complete-BRAVOProgress
        return
    }

    Write-BRAVOProgressPhase -Phase $Status -PercentComplete $PercentComplete
}

# Покомпонентна смуга повністю дублювала загальну ("MODEL (1 з 3)" в обох),
# тому вона більше нічого не малює. Сигнатуру збережено, щоб не правити
# десятки викликів у бізнес-логіці.
function Show-ItemProgress {
    param(
        [int]$Id,
        [string]$Activity,
        [string]$Item,
        [int]$Current,
        [int]$Total,
        [switch]$Completed
    )

    return
}

# Нумерація етапів операційної консолі: [1/6], [2/6], ...
# Загальна кількість рахується на старті за увімкненими компонентами, тому
# вимкнений SFTP чи NAS не створює порожніх етапів.
$script:BRAVOStepCurrent = 0
$script:BRAVOStepTotal = 0

# Накопичує кожен Write-BRAVOArchiveStep за весь прогін скрипта (НЕ
# скидається у Initialize-BRAVOArchiveSteps — той викликається кілька разів
# за один прогін для різних фаз, а зведена Operations-подія генерації
# (нижче, після фіналізації generation) має бачити етапи з усіх фаз).
$script:BRAVOArchiveStepHistory = New-Object System.Collections.Generic.List[object]

function Initialize-BRAVOArchiveSteps {
    param([Parameter(Mandatory = $true)][int]$Total)

    $script:BRAVOStepCurrent = 0
    $script:BRAVOStepTotal = [Math]::Max(1, $Total)
}

function Write-BRAVOArchiveStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('OK', 'SKIPPED', 'WARNING', 'ERROR')]
        [string]$Status = 'OK',
        [string]$Details,
        [Nullable[timespan]]$Duration
    )

    $script:BRAVOStepCurrent++
    Write-BRAVOStepResult `
        -Current $script:BRAVOStepCurrent `
        -Total $script:BRAVOStepTotal `
        -Name $Name `
        -Status $Status `
        -Details $Details `
        -Duration $Duration

    $script:BRAVOArchiveStepHistory.Add([ordered]@{
        name = $Name
        status = $Status
        details = $Details
        durationMs = if ($null -ne $Duration) { [Math]::Round($Duration.TotalMilliseconds) } else { $null }
    })
}

function Show-RunningProgress {
    param(
        [int]$Id,
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete = -1,
        [switch]$Completed
    )

    if (-not $progressSettings.Enabled) {
        return
    }

    # Деталь операції дописується до поточної фази на тій самій смузі, тому
    # завершення операції лише прибирає деталь, а не гасить увесь індикатор.
    if ($Completed) {
        Write-BRAVOProgressDetail -Detail ''
        return
    }

    Write-BRAVOProgressDetail -Detail $Status
}

function Wait-ForManualExit {
    # Спільна реалізація — modules\BRAVO.Console\BRAVO.Console.psm1. Той
    # самий механізм (RawUI.ReadKey з фолбеком на Read-Host для ISE) тепер
    # використовують і Health, і Maintenance; тут лишається тонка обгортка
    # заради стабільності єдиного виклику нижче (рядок ~4230).
    Wait-BRAVOManualExit -NoPause:$NoPause
}

function Group-BRAVOProbeTarget {
    # Один і той самий шлях пробується РІВНО один раз (як і раніше через
    # Select-Object -Unique), але його провал застосовується до ВСІХ власників
    # цього шляху: два компоненти можуть мати спільний каталог призначення, і
    # тоді відмова справедливо стосується обох.
    param([object[]]$Targets)

    # Hashtable для пошуку + List для порядку, а НЕ [ordered]@{}: доступ до
    # .Values порожнього OrderedDictionary кидає ArgumentException
    # ("Argument types do not match") під час загортання в @() — а порожній
    # набір цілей тут цілком штатний (усі компоненти вимкнені).
    $probeGroupIndex = @{}
    $probeGroupList = New-Object System.Collections.Generic.List[object]
    foreach ($probeTarget in @($Targets)) {
        $probeTargetPath = [string]$probeTarget.Path
        if ([string]::IsNullOrWhiteSpace($probeTargetPath)) {
            continue
        }
        $probeGroupKey = $probeTargetPath.ToUpperInvariant()
        if ($probeGroupIndex.ContainsKey($probeGroupKey)) {
            [void]$probeGroupIndex[$probeGroupKey].Owners.Add($probeTarget)
            continue
        }
        $probeGroup = [pscustomobject]@{
            Path = $probeTargetPath
            Owners = (New-Object System.Collections.Generic.List[object])
        }
        [void]$probeGroup.Owners.Add($probeTarget)
        $probeGroupIndex[$probeGroupKey] = $probeGroup
        [void]$probeGroupList.Add($probeGroup)
    }
    # .ToArray(), а НЕ @($probeGroupList): у Windows PowerShell 5.1 загортання
    # ПОРОЖНЬОГО System.Collections.Generic.List у @() кидає
    # ArgumentException "Argument types do not match". Порожній набір цілей
    # тут штатний (усі компоненти вимкнені), тому це був би краш на рівному місці.
    return $probeGroupList.ToArray()
}

function Test-PathWithLog {
    param(
        [string]$Path,
        [string]$Description,
        [bool]$CreateIfMissing = $false
    )

    # Порожній шлях означає нерозв'язане джерело або призначення: напр.
    # BRAVOEXCH, коли каталог із bravo.ini [model] BEXCH не існує, і
    # BRAVO.config обнуляє sourcePaths.BravoExch. Раніше таке значення
    # доходило до Test-Path "" — а той має [ValidateNotNullOrEmpty] на -Path,
    # тому кидав термінальну помилку "Cannot bind argument to parameter
    # 'Path' because it is an empty string" і валив УВЕСЬ прогін кодом 90
    # (InternalError) ще до архівації справних компонентів. Тут це керована
    # відмова одного шляху: викликач сам вирішує, що з нею робити.
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-BRAVOLog -Component 'PATHS' -Message "$Description не визначено: шлях порожній або не вдалося визначити автоматично" -Level "ERROR"
        return $false
    }

    if (Test-Path $Path) {
        Write-BRAVOLog -Component 'PATHS' -Message "$Description знайдено: $Path" -Level "DEBUG"
        return $true
    } else {
        # Створення дозволяється лише для явно позначених каталогів призначення.
        if ($CreateIfMissing) {
            try {
                New-Item -ItemType Directory -Path $Path -Force | Out-Null
                Write-BRAVOLog -Component 'PATHS' -Message "$Description не знайдено, створено автоматично: $Path" -Level "SUCCESS"
                return $true
            } catch {
                Write-BRAVOLog -Component 'PATHS' -Message "$Description не знайдено i не вдалося створити: $Path" -Level "ERROR"
                return $false
            }
        } else {
            Write-BRAVOLog -Component 'PATHS' -Message "$Description не знайдено: $Path" -Level "ERROR"
            return $false
        }
    }
}

function Show-PathCheckSummary {
    param(
        [array]$CheckedPaths,
        [bool]$AllPathsExist
    )
    
    if ($AllPathsExist) {
        Write-BRAVOLog -Component 'PATHS' -Message "Всi необхiднi шляхи перевiрено успiшно" -Level "SUCCESS"
    } else {
        Write-BRAVOLog -Component 'PATHS' -Message "Знайдено помилки в шляхах - див. вище" -Level "ERROR"
    }
}

function Show-ArchiveCleanupSection {
    param([ref]$SectionShown)

    if (-not $SectionShown.Value) {
        Write-BRAVOLog -Component 'CLEANUP' -Message "==="
        Write-BRAVOLog -Component 'CLEANUP' -Message "=== ОЧИЩЕННЯ СТАРИХ АРХIВIВ ==="
        Show-ScriptProgress -Status "Очищення старих архiвiв" -PercentComplete 72
        $SectionShown.Value = $true
    }
}

function Test-BRAVOBackupArtifactPathSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )

    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $fullRoot = [IO.Path]::GetFullPath($BackupRoot).TrimEnd('\', '/')
        return $fullPath.StartsWith(
            $fullRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        )
    } catch {
        return $false
    }
}

function Get-BRAVOGenerationManifestComponents {
    param([object]$Manifest)

    if ($null -eq $Manifest -or $null -eq $Manifest.PSObject.Properties['components']) {
        return @()
    }
    return @($Manifest.components.PSObject.Properties | ForEach-Object { $_.Value })
}

function Test-BRAVOGenerationManifestVerified {
    param([object]$Manifest)

    if ([string]$Manifest.status -ne 'COMPLETE') { return $false }
    $components = @(Get-BRAVOGenerationManifestComponents -Manifest $Manifest)
    if ($components.Count -eq 0) { return $false }
    foreach ($component in $components) {
        if (-not [bool]$component.CreateSuccess -or
            -not [bool]$component.IntegritySuccess -or
            -not [bool]$component.HashSuccess) {
            return $false
        }
        $archivePath = [string]$component.ArchivePath
        $hashPath = [string]$component.HashPath
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
            return $false
        }
        try {
            $hashText = ([IO.File]::ReadAllText($hashPath)).Trim([char]0xFEFF).Trim()
            if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$' -or
                $Matches.FileName -cne [IO.Path]::GetFileName($archivePath)) {
                return $false
            }
            $actualHash = (Get-BRAVOFileHash -Path $archivePath -Algorithm SHA512).Hash.ToUpperInvariant()
            if ($actualHash -cne $Matches.Hash.ToUpperInvariant()) { return $false }
        } catch {
            return $false
        }
    }
    return $true
}

function Resolve-BRAVORetentionGenerationManifest {
    # Retention має бачити ті самі файли generation, що й відновлення
    # (#335). Шляхи в manifest-і абсолютні; після перенесення сховища на
    # інший диск/корінь (задокументований DR-сценарій) вони вказують у
    # нікуди, хоча архіви лежать у канонічному каталозі компонента. Тому
    # використовується та сама canonical rebasing-політика, що в
    # BRAVO_DATA_RESTORE і BRAVO_RESTORE_TEST
    # (ConvertTo-BRAVORebasedLocalGenerationManifest: лише leaf-ім'я +
    # archiveDefinitions[Type].Destination). Записаний шлях лишається в
    # пріоритеті, якщо файл за ним існує і лежить у BackupRoot: так
    # generation, створена до зміни каталогу компонента, не губить свої
    # файли. Без ArchiveDefinitions manifest повертається без змін.
    #
    # Retention ВИДАЛЯЄ файли за перебудованими шляхами, тому перебудова тут
    # fail-closed. Компонент потрапляє в UnresolvedReasons (generation не
    # видаляється, WARNING), якщо:
    #  - файл за записаним шляхом існує, але поза BackupRoot (видалення
    #    manifest-а осиротило б його);
    #  - leaf-ім'я не належить ЦІЙ generation за NameTemplate
    #    (той самий identity gate, що в Get-BRAVOVerifiedGenerationArchive):
    #    інакше manifest із чужим іменем видалив би архів іншої generation
    #    в обхід захищених і поточної;
    #  - канонічний каталог компонента недоступний: відсутній файл там не
    #    доводить, що його вже видалено.
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [object[]]$ArchiveDefinitions
    )

    $unresolvedReasons = @()
    $componentNames = @()
    if ($null -ne $Manifest.PSObject.Properties['components'] -and $null -ne $Manifest.components) {
        $componentNames = @($Manifest.components.PSObject.Properties | ForEach-Object { $_.Name })
    }
    if ($componentNames.Count -eq 0 -or $null -eq $ArchiveDefinitions -or $ArchiveDefinitions.Count -eq 0) {
        return [pscustomobject]@{ Manifest = $Manifest; UnresolvedReasons = $unresolvedReasons }
    }

    $generationId = [string]$Manifest.generationId
    $hashExtension = [string](Get-Variable -Name 'hashFileExtension' -ValueOnly -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($hashExtension)) { $hashExtension = '.sha512' }
    $resolvedManifest = ConvertTo-BRAVORebasedLocalGenerationManifest `
        -Manifest $Manifest `
        -ComponentTypes $componentNames `
        -ArchiveDefinitions @($ArchiveDefinitions)
    foreach ($componentProperty in @($Manifest.components.PSObject.Properties)) {
        $componentName = [string]$componentProperty.Name
        $resolvedComponent = $resolvedManifest.components.PSObject.Properties[$componentName].Value
        $definition = @($ArchiveDefinitions | Where-Object {
            [string]::Equals([string]$_.Type, $componentName, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        # Невідомий тип / порожній Destination звітує
        # Get-BRAVORetentionUnresolvedComponentTypes.
        if ($definition.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$definition[0].Destination)) { continue }
        $destination = [string]$definition[0].Destination
        $nameTemplate = ''
        if ($definition[0] -is [System.Collections.IDictionary]) {
            if ($definition[0].Contains('NameTemplate')) { $nameTemplate = [string]$definition[0]['NameTemplate'] }
        } elseif ($null -ne $definition[0].PSObject.Properties['NameTemplate']) {
            $nameTemplate = [string]$definition[0].NameTemplate
        }
        foreach ($fieldName in @('ArchivePath', 'HashPath')) {
            $recordedProperty = $componentProperty.Value.PSObject.Properties[$fieldName]
            if ($null -eq $recordedProperty) { continue }
            $recordedPath = [string]$recordedProperty.Value
            if ([string]::IsNullOrWhiteSpace($recordedPath)) { continue }
            if (Test-Path -LiteralPath $recordedPath -PathType Leaf) {
                if (Test-BRAVOBackupArtifactPathSafe -Path $recordedPath -BackupRoot $BackupRoot) {
                    $resolvedComponent.$fieldName = $recordedPath
                } else {
                    $unresolvedReasons += "${componentName}: файл за записаним шляхом лежить поза BackupRoot ($recordedPath)"
                }
                continue
            }
            $leaf = Get-BRAVOVerifiedArtifactLeafName -Value $recordedPath
            if ($null -eq $leaf) {
                $unresolvedReasons += "${componentName}: некоректне ім'я файлу в manifest-і ($fieldName)"
                continue
            }
            $canonicalPath = Join-Path $destination $leaf
            $recordedFull = try { [IO.Path]::GetFullPath($recordedPath) } catch { $recordedPath }
            $canonicalFull = try { [IO.Path]::GetFullPath($canonicalPath) } catch { $canonicalPath }
            if ([string]::Equals($recordedFull, $canonicalFull, [StringComparison]::OrdinalIgnoreCase)) {
                # Перебудови немає: файла просто вже немає (як до #335).
                $resolvedComponent.$fieldName = $recordedPath
                continue
            }
            $expectedSuffix = ''
            if (-not [string]::IsNullOrWhiteSpace($nameTemplate)) {
                try { $expectedSuffix = $nameTemplate -f '', $generationId } catch { $expectedSuffix = '' }
            }
            if ($fieldName -eq 'HashPath' -and -not [string]::IsNullOrEmpty($expectedSuffix)) {
                $expectedSuffix += $hashExtension
            }
            if ([string]::IsNullOrEmpty($expectedSuffix) -or
                $leaf.Length -le $expectedSuffix.Length -or
                -not $leaf.EndsWith($expectedSuffix, [StringComparison]::Ordinal)) {
                $unresolvedReasons += "${componentName}: ім'я '$leaf' не належить generation $generationId за NameTemplate"
                continue
            }
            if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
                $unresolvedReasons += "${componentName}: каталог компонента недоступний ($destination)"
                continue
            }
            $resolvedComponent.$fieldName = $canonicalPath
        }
    }
    return [pscustomobject]@{ Manifest = $resolvedManifest; UnresolvedReasons = @($unresolvedReasons | Select-Object -Unique) }
}

function Get-BRAVORetentionUnresolvedComponentTypes {
    # Типи компонентів старого manifest-а, яких немає в поточних
    # ArchiveDefinitions (або в них порожній Destination), напр. після
    # профілів призначень #334. ConvertTo-BRAVORebasedLocalGenerationManifest
    # такі компоненти мовчки лишає з ЗАПИСАНИМИ шляхами; після перенесення
    # сховища ці шляхи вказують у нікуди, і retention вирішив би, що
    # "архівів уже немає", та видалив би manifest разом із тим, що лишилось.
    # Тому generation з нерозв'язаним типом ніколи не видаляється.
    # Без ArchiveDefinitions перевірки немає (поведінка до #335).
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [object[]]$ArchiveDefinitions
    )

    $unresolved = @()
    if ($null -eq $ArchiveDefinitions -or $ArchiveDefinitions.Count -eq 0) { return $unresolved }
    if ($null -eq $Manifest.PSObject.Properties['components'] -or $null -eq $Manifest.components) { return $unresolved }
    foreach ($componentProperty in @($Manifest.components.PSObject.Properties)) {
        $definition = @($ArchiveDefinitions | Where-Object {
            [string]::Equals([string]$_.Type, [string]$componentProperty.Name, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($definition.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$definition[0].Destination)) {
            $unresolved += [string]$componentProperty.Name
        }
    }
    return $unresolved
}

function Get-BRAVOGenerationManifestArtifactProblems {
    # ДЕШЕВА перевірка COMPLETE generation (без читання вмісту архіву і
    # без SHA512): кожен компонент має успішні прапорці, архів і .sha512
    # існують, архів непорожній і збігається за розміром із записаним у
    # manifest ArchiveSize (якщо він є), .sha512 має коректний формат і
    # посилається на цей архів. Повертає перелік проблем (порожній = ок).
    # Саме вона дає WARNING про пошкодження для КОЖНОЇ COMPLETE generation,
    # зокрема старішої за N захищених, не навантажуючи диск (#335).
    param([object]$Manifest)

    $problems = @()
    $componentProperties = @()
    if ($null -ne $Manifest -and $null -ne $Manifest.PSObject.Properties['components'] -and $null -ne $Manifest.components) {
        $componentProperties = @($Manifest.components.PSObject.Properties)
    }
    if ($componentProperties.Count -eq 0) { return @('manifest не містить компонентів') }
    foreach ($componentProperty in $componentProperties) {
        $name = [string]$componentProperty.Name
        $component = $componentProperty.Value
        foreach ($flagName in @('CreateSuccess', 'IntegritySuccess', 'HashSuccess')) {
            $flag = $component.PSObject.Properties[$flagName]
            if ($null -eq $flag -or -not [bool]$flag.Value) {
                $problems += "${name}: ${flagName} не підтверджено в manifest-і"
            }
        }
        $archiveProperty = $component.PSObject.Properties['ArchivePath']
        $hashProperty = $component.PSObject.Properties['HashPath']
        $archivePath = if ($null -ne $archiveProperty) { [string]$archiveProperty.Value } else { '' }
        $hashPath = if ($null -ne $hashProperty) { [string]$hashProperty.Value } else { '' }
        if ([string]::IsNullOrWhiteSpace($archivePath) -or
            -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
            $problems += "${name}: архів відсутній"
            continue
        }
        # Файл міг зникнути після Test-Path або не читатися (ACL, збій
        # сховища): це проблема ЦІЄЇ generation, а не всього прогону.
        $archiveLength = $null
        try {
            $archiveLength = (New-Object System.IO.FileInfo -ArgumentList $archivePath).Length
        } catch {
            $problems += "${name}: метадані архіву не прочитано ($($_.Exception.Message))"
            continue
        }
        if ($archiveLength -le 0) { $problems += "${name}: архів порожній" }
        $sizeProperty = $component.PSObject.Properties['ArchiveSize']
        if ($null -ne $sizeProperty -and $null -ne $sizeProperty.Value) {
            $recordedSize = $null
            try { $recordedSize = [long]$sizeProperty.Value } catch { $recordedSize = $null }
            if ($null -ne $recordedSize -and $recordedSize -gt 0 -and $recordedSize -ne $archiveLength) {
                $problems += "${name}: розмір архіву ($archiveLength) не збігається із записаним ($recordedSize)"
            }
        }
        if ([string]::IsNullOrWhiteSpace($hashPath) -or
            -not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
            $problems += "${name}: hash-файл відсутній"
            continue
        }
        try {
            $hashText = ([IO.File]::ReadAllText($hashPath)).Trim([char]0xFEFF).Trim()
            if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$' -or
                $Matches.FileName -cne [IO.Path]::GetFileName($archivePath)) {
                $problems += "${name}: hash-файл має некоректний формат або належить іншому архіву"
            }
        } catch {
            $problems += "${name}: hash-файл не читається"
        }
    }
    return $problems
}

function Get-BRAVOUnreferencedBackupArchives {
    # Архіви в канонічних каталогах компонентів, на які не посилається
    # жоден придатний generation manifest: архіви версій до generation-
    # схеми, архіви з пошкодженим/невідповідним manifest-ом, залишки
    # ручних дій. Лише звіт (#335, рішення власника 2026-10-01):
    # автоматично такі файли не видаляються. Обідні копії з маркером часу
    # `_HHMM` (Remove-OldLunchArchives прибирає їх своїм строком) не
    # рахуються: вони лежать у тих самих каталогах і мають власний цикл.
    param(
        [object[]]$ArchiveDefinitions,
        [hashtable]$ReferencedArchiveNames
    )

    $count = 0
    [long]$sizeBytes = 0
    $filter = if (-not [string]::IsNullOrWhiteSpace([string]$archiveFileFilter)) { [string]$archiveFileFilter } else { '*.mdz' }
    $seenDirectories = @{}
    foreach ($definition in @($ArchiveDefinitions)) {
        $destination = [string]$definition.Destination
        if ([string]::IsNullOrWhiteSpace($destination) -or $seenDirectories.ContainsKey($destination)) { continue }
        $seenDirectories[$destination] = $true
        if (-not (Test-Path -LiteralPath $destination -PathType Container)) { continue }
        foreach ($archive in @(Get-BRAVOFiles -LiteralPath $destination -Filter $filter)) {
            if ($archive.PSIsContainer) { continue }
            if ($null -ne $ReferencedArchiveNames -and $ReferencedArchiveNames.ContainsKey($archive.Name)) { continue }
            if ($archive.Name -match '_\d{4}\.[^.]+$') { continue }
            $count++
            $sizeBytes += [long]$archive.Length
        }
    }
    return [pscustomobject]@{ Count = $count; SizeBytes = $sizeBytes }
}

function Remove-BRAVOExpiredBackupGenerations {
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$CurrentGenerationId,
        [int]$RetentionDays,
        [ref]$CleanupSectionShown,
        # dev.16 (review round 3): опційний факт-сигнал для operator-console
        # unnumbered result — скільки generation РЕАЛЬНО видалено цим
        # прогоном (не просто "перевірку виконано"). Той самий мінімальний
        # ref-out-параметр паттерн, що вже CleanupSectionShown вище; не
        # змінює retention/delete semantics нижче.
        # ВАЖЛИВО: ім'я НЕ повинно збігатися (регістр-незалежно) з жодною
        # локальною змінною нижче — PowerShell типізує параметр-змінну як
        # [ref] на всю область видимості функції, і будь-яке присвоєння
        # значення змінній з тим самим (з точністю до регістру) іменем
        # тихо обгортається назад у НОВИЙ PSReference замість звичайного
        # int; наступний $x++/$x += кидає "operator works only on numbers"
        # (підтверджено реальним запуском — саме так спершу й було зроблено).
        [ref]$RemovedGenerationCount,
        # Канонічні каталоги компонентів (#335): rebasing шляхів manifest-а
        # як у відновленні і звіт про архіви без manifest-а. Без параметра
        # шляхи беруться з manifest-а як є, а звіт не будується.
        [object[]]$ArchiveDefinitions
    )

    # Контракт безпеки (#335):
    #  - гілку визначає ЗАПИСАНИЙ статус прогону. COMPLETE видаляється лише
    #    за archiveRetentionDays і лише при enableArchiveDeletion; не COMPLETE
    #    — за failedArchiveRetentionDays. Сьогоднішня перевірка архіву гілку
    #    не змінює: пошкодження COMPLETE дає WARNING, а не видалення;
    #  - SHA512 (повне читання архівів) рахується ЛИШЕ коли воно потрібне для
    #    вибору N захищених копій, тобто коли enableArchiveDeletion=$true і є
    #    хоча б одна COMPLETE generation, прострочена за archiveRetentionDays
    #    (інакше захист нічого не вирішує). Хешування йде від найновішої
    #    COMPLETE, що пройшла дешеву перевірку, доки не знайдено N цілих;
    #  - для WARNING про пошкодження ВСІХ COMPLETE (зокрема старших за N
    #    захищених) використовується дешева перевірка без читання вмісту:
    #    існування архіву/hash-файлу, розмір проти ArchiveSize, формат .sha512
    #    (Get-BRAVOGenerationManifestArtifactProblems). Приховане пошкодження
    #    вмісту з незмінним розміром виявляється SHA512 лише у випадку вище;
    #  - manifest видаляється останнім, після всіх знайдених архівів;
    #  - помилка на одній generation не зупиняє решту, прогін повертає $false;
    #  - generation із типом компонента, якого немає в ArchiveDefinitions,
    #    не видаляється (WARNING); архіви без manifest-а лише рахуються.
    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) { return $false }
    $deletedGenerationCount = 0
    $deletedVerifiedExpiredCount = 0
    $deletedFailedIncompleteCount = 0
    $corruptGenerationIds = @()
    $unresolvedGenerationIds = @()
    $failedDeletionIds = @()
    try {
        $validRetentionDays = if ($RetentionDays -gt 0) { $RetentionDays } else { 183 }
        $invalidRetentionDays = if ($failedArchiveRetentionDays -gt 0) { [int]$failedArchiveRetentionDays } else { 30 }
        $validCutoff = (Get-Date).AddDays(-$validRetentionDays)
        $invalidCutoff = (Get-Date).AddDays(-$invalidRetentionDays)
        $records = @()
        $referencedArchiveNames = @{}
        # dev.14: MANIFESTS-first reader (з fallback на legacy корінь
        # BackupRoot) вирішує, ЯКИЙ вміст (Status/StartedAt) керує рішенням
        # про видалення generation. ManifestPath нижче — лише шлях ЦІЄЇ
        # конкретної, обраної для рішення копії; фактичне видалення (нижче)
        # не покладається на це поле — воно шукає й прибирає ВСІ фізичні
        # копії manifest-а через Get-BRAVOBackupGenerationManifestPhysicalFiles.
        foreach ($manifestFile in @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $BackupRoot)) {
            try {
                $manifest = [IO.File]::ReadAllText($manifestFile.FullName) | ConvertFrom-Json -ErrorAction Stop
                $generationId = [string]$manifest.generationId
                if ([string]::IsNullOrWhiteSpace($generationId)) { throw 'generationId is empty' }

                # dev.14 (round 3): filename і JSON generationId МАЮТЬ
                # збігатися. Фізичне видалення (нижче) шукає artifacts і
                # metadata за GenerationId із ЦЬОГО запису — якщо довіряти
                # лише вмісту JSON без звірки з іменем файлу, пошкоджений
                # чи підмінений manifest міг би вказати на ЧУЖУ generation
                # і призвести до видалення її artifacts/metadata. Mismatch
                # виключає запис із retention повністю — жодних artifacts
                # чи metadata не видаляється на основі недовіреного запису.
                $filenameGenerationId = Get-BRAVOBackupManifestFilenameGenerationId -FileName $manifestFile.Name
                if ([string]::IsNullOrEmpty($filenameGenerationId) -or
                    -not [string]::Equals($filenameGenerationId, $generationId, [StringComparison]::Ordinal)) {
                    Write-BRAVOLog -Component 'CLEANUP' -Message (
                        "Generation manifest пропущено для retention через невідповідність generationId: " +
                        "файл '$($manifestFile.Name)' (з імені файлу: '$filenameGenerationId') містить у JSON " +
                        "generationId '$generationId' — можливе пошкодження чи підміна, файл лишається без змін"
                    ) -Level 'WARNING'
                    continue
                }

                # Час запуску невідомий (властивості немає, null, порожній чи
                # нерозбірливий рядок): TimeKnown=$false. Такий запис не
                # видаляється жодною гілкою і не бере участі у виборі N
                # захищених; LastWriteTime файлу видалення не дозволяє.
                # MinValue - лише сортувальна заглушка, її ніхто не порівнює
                # з cutoff без перевірки TimeKnown.
                $startedAt = [datetime]::MinValue
                $timeKnown = $false
                $startedAtProperty = $manifest.PSObject.Properties['startedAt']
                if ($null -ne $startedAtProperty -and $null -ne $startedAtProperty.Value) {
                    if ($startedAtProperty.Value -is [datetime]) {
                        $parsedStartedAt = [datetime]$startedAtProperty.Value
                    } else {
                        $parsedStartedAt = [datetime]::MinValue
                        $startedAtText = [string]$startedAtProperty.Value
                        # Формат ConvertTo-Json Windows PowerShell 5.1 для
                        # [datetime] ("\/Date(ms)\/"), якщо ConvertFrom-Json
                        # лишив його рядком: мілісекунди від епохи UTC.
                        $epochMatch = [regex]::Match($startedAtText, '^/Date\((-?\d+)(?:[+-]\d{4})?\)/$')
                        if ($epochMatch.Success) {
                            $epochMilliseconds = [long]0
                            if ([long]::TryParse($epochMatch.Groups[1].Value, [ref]$epochMilliseconds)) {
                                $parsedStartedAt = (New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).AddMilliseconds($epochMilliseconds)
                            }
                        } elseif (-not [string]::IsNullOrWhiteSpace($startedAtText) -and
                            -not [datetime]::TryParse(
                                $startedAtText,
                                [Globalization.CultureInfo]::InvariantCulture,
                                [Globalization.DateTimeStyles]::None,
                                [ref]$parsedStartedAt)) {
                            $parsedStartedAt = [datetime]::MinValue
                        }
                    }
                    # Cutoff рахується від локального (Get-Date), а порівняння
                    # DateTime ігнорує Kind: UTC-значення (епоха чи DateTime з
                    # ConvertFrom-Json) переводиться в локальний час.
                    if ($parsedStartedAt.Kind -eq [DateTimeKind]::Utc) {
                        $parsedStartedAt = $parsedStartedAt.ToLocalTime()
                    }
                    # Будь-який час у перший день (0001-01-01) - це незаданий
                    # [datetime], а не найстаріша копія: після переходу між
                    # UTC і локальним часом він може стати MinValue + зсув.
                    if ($parsedStartedAt.Date -gt [datetime]::MinValue.Date) {
                        $startedAt = $parsedStartedAt
                        $timeKnown = $true
                    }
                }
                # Імена архівів з ОРИГІНАЛЬНОГО manifest-а для звіту про
                # архіви без manifest-а (незалежно від rebasing і типів).
                foreach ($recordedComponent in @(Get-BRAVOGenerationManifestComponents -Manifest $manifest)) {
                    foreach ($recordedField in @('ArchivePath', 'HashPath')) {
                        $recordedProperty = $recordedComponent.PSObject.Properties[$recordedField]
                        if ($null -eq $recordedProperty) { continue }
                        $recordedLeaf = Get-BRAVOVerifiedArtifactLeafName -Value ([string]$recordedProperty.Value)
                        if ($null -ne $recordedLeaf) { $referencedArchiveNames[$recordedLeaf] = $true }
                    }
                }
                $resolution = Resolve-BRAVORetentionGenerationManifest `
                    -Manifest $manifest `
                    -BackupRoot $BackupRoot `
                    -ArchiveDefinitions $ArchiveDefinitions
                $records += [pscustomobject]@{
                    GenerationId = $generationId
                    Status = [string]$manifest.status
                    IsComplete = ([string]$manifest.status -eq 'COMPLETE')
                    StartedAt = $startedAt
                    TimeKnown = $timeKnown
                    Manifest = $resolution.Manifest
                    UnresolvedTypes = @(@(Get-BRAVORetentionUnresolvedComponentTypes `
                        -Manifest $manifest -ArchiveDefinitions $ArchiveDefinitions) + @($resolution.UnresolvedReasons))
                    ArtifactProblems = @()
                    ManifestPath = $manifestFile.FullName
                }
            } catch {
                Write-BRAVOLog -Component 'CLEANUP' -Message "Generation manifest збережено без змін через parse error: $($manifestFile.FullName) ($($_.Exception.Message))" -Level 'WARNING'
            }
        }

        # Generation з типом компонента, якого немає в ArchiveDefinitions,
        # або з файлами, які не вдалося безпечно перебудувати
        # (Resolve-BRAVORetentionGenerationManifest), лишається в сховищі
        # (WARNING): видалення "відсутніх" файлів губило б manifest.
        foreach ($record in $records) {
            if ($record.UnresolvedTypes.Count -eq 0) { continue }
            $unresolvedGenerationIds += $record.GenerationId
            Write-BRAVOLog -Component 'CLEANUP' -Message (
                "Резервна копія $($record.GenerationId): retention не може однозначно визначити її файли " +
                "($($record.UnresolvedTypes -join '; ')). Retention її не чіпає"
            ) -Level 'WARNING'
        }

        # Дешева перевірка КОЖНОЇ COMPLETE generation (також старшої за N
        # захищених): WARNING про пошкодження без SHA512 і без видалення.
        foreach ($record in @($records | Where-Object { $_.IsComplete -and $_.UnresolvedTypes.Count -eq 0 })) {
            $record.ArtifactProblems = @(Get-BRAVOGenerationManifestArtifactProblems -Manifest $record.Manifest)
            if ($record.ArtifactProblems.Count -eq 0) { continue }
            $corruptGenerationIds += $record.GenerationId
            Write-BRAVOLog -Component 'CLEANUP' -Message (
                "Пошкоджена резервна копія $($record.GenerationId): статус COMPLETE, але " +
                ($record.ArtifactProblems -join '; ') +
                ". Вона не рахується серед захищених і не видаляється як невдала"
            ) -Level 'WARNING'
        }

        # Захищені generation: N найновіших COMPLETE, що проходять ПОВНУ
        # перевірку (SHA512). Потрібні лише для видалення COMPLETE за віком:
        # без enableArchiveDeletion або без прострочених COMPLETE хешування
        # не виконується взагалі.
        $minimumRetainedCount = if ($minimumRetainedVerifiedBackups -gt 0) {
            [int]$minimumRetainedVerifiedBackups
        } else { 1 }
        $protectedGenerationIds = @()
        $hashVerificationNeeded = [bool]$enableArchiveDeletion -and (@($records | Where-Object {
            $_.IsComplete -and $_.TimeKnown -and $_.UnresolvedTypes.Count -eq 0 -and
            $_.GenerationId -ne $CurrentGenerationId -and $_.StartedAt -lt $validCutoff
        }).Count -gt 0)
        if ($hashVerificationNeeded) {
            foreach ($record in @($records | Where-Object {
                $_.IsComplete -and $_.TimeKnown -and $_.UnresolvedTypes.Count -eq 0 -and $_.ArtifactProblems.Count -eq 0
            } | Sort-Object StartedAt -Descending)) {
                if ($protectedGenerationIds.Count -ge $minimumRetainedCount) { break }
                if (Test-BRAVOGenerationManifestVerified -Manifest $record.Manifest) {
                    $protectedGenerationIds += $record.GenerationId
                    continue
                }
                $corruptGenerationIds += $record.GenerationId
                Write-BRAVOLog -Component 'CLEANUP' -Message (
                    "Пошкоджена резервна копія $($record.GenerationId): статус COMPLETE, але SHA512 архіву не " +
                    "збігається з hash-файлом. Вона не рахується серед $minimumRetainedCount захищених копій " +
                    "і не видаляється як невдала"
                ) -Level 'WARNING'
            }
        }

        foreach ($record in @($records | Sort-Object StartedAt)) {
            if ($record.GenerationId -eq $CurrentGenerationId) { continue }
            if ($record.UnresolvedTypes.Count -gt 0) { continue }
            if (-not $record.TimeKnown) {
                Write-BRAVOLog -Component 'CLEANUP' -Message (
                    "Резервна копія $($record.GenerationId): час запуску (startedAt) відсутній або " +
                    "нерозбірливий у manifest-і. Retention її не чіпає"
                ) -Level 'WARNING'
                continue
            }
            # Гілку визначає записаний статус прогону, а не сьогоднішня
            # перевірка (#335).
            $deleteGeneration = $false
            if ($record.IsComplete) {
                $deleteGeneration = [bool]$enableArchiveDeletion -and
                    $record.StartedAt -lt $validCutoff -and
                    $record.GenerationId -notin $protectedGenerationIds
            } elseif ($record.Status -eq 'FAILED' -or $record.Status -eq 'INCOMPLETE') {
                $deleteGeneration = [bool]$enableFailedArchiveDeletion -and
                    $record.StartedAt -lt $invalidCutoff
            } else {
                Write-BRAVOLog -Component 'CLEANUP' -Message (
                    "Резервна копія $($record.GenerationId): невідомий статус '$($record.Status)' " +
                    "(очікується COMPLETE, FAILED або INCOMPLETE). Retention її не чіпає"
                ) -Level 'WARNING'
            }
            if (-not $deleteGeneration) { continue }

            # Помилка на одній generation не зупиняє решту (#335): інакше
            # один заблокований файл блокував би прибирання щоночі.
            try {
                # Усі шляхи перевіряються ДО першого видалення: generation
                # з артефактом поза BackupRoot не чіпається взагалі.
                $artifactPaths = @()
                $missingArtifactCount = 0
                foreach ($component in @(Get-BRAVOGenerationManifestComponents -Manifest $record.Manifest)) {
                    foreach ($artifactPath in @([string]$component.ArchivePath, [string]$component.HashPath)) {
                        if ([string]::IsNullOrWhiteSpace($artifactPath)) { continue }
                        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
                            $missingArtifactCount++
                            continue
                        }
                        if (-not (Test-BRAVOBackupArtifactPathSafe -Path $artifactPath -BackupRoot $BackupRoot)) {
                            throw "manifest references artifact outside BackupRoot: $artifactPath"
                        }
                        $artifactPaths += $artifactPath
                    }
                }

                Show-ArchiveCleanupSection -SectionShown $CleanupSectionShown
                foreach ($artifactPath in $artifactPaths) {
                    Remove-Item -LiteralPath $artifactPath -Force -ErrorAction Stop
                }
                # Manifest видаляється останнім і лише після того, як усі
                # знайдені архіви цієї generation видалено. Якщо видалення
                # архіву впало, manifest лишається, і наступний прогін
                # доведе generation до кінця, а не залишить сирітські архіви.
                # dev.14: видаляється КОЖНА фізична копія manifest-а цієї
                # generation (MANIFESTS і, за наявності, legacy-корінь), а не
                # лише та, яку MANIFESTS-first reader повернув для рішення про
                # видалення. Інакше conflict-копія в іншому розташуванні
                # переживає видалення й на наступному запуску "воскрешає"
                # видалену generation через legacy fallback читання.
                foreach ($physicalManifest in @(
                    Get-BRAVOBackupGenerationManifestPhysicalFiles `
                        -BackupRoot $BackupRoot `
                        -GenerationId $record.GenerationId
                )) {
                    Remove-Item -LiteralPath $physicalManifest.FullName -Force -ErrorAction Stop
                }
                $missingNote = if ($missingArtifactCount -gt 0) { "; файлів, яких уже не було: $missingArtifactCount" } else { '' }
                Write-BRAVOLog -Component 'CLEANUP' -Message "Видалено backup generation $($record.GenerationId) ($($record.Status))$missingNote" -Level 'SUCCESS'
                if ($record.IsComplete) { $deletedVerifiedExpiredCount++ } else { $deletedFailedIncompleteCount++ }
                $deletedGenerationCount++
            } catch {
                $failedDeletionIds += $record.GenerationId
                Write-BRAVOLog -Component 'CLEANUP' -Message (
                    "Не вдалося видалити backup generation $($record.GenerationId): $($_.Exception.Message). " +
                    "Manifest збережено, решта generation обробляється далі"
                ) -Level 'ERROR'
            }
        }
        if ($null -ne $RemovedGenerationCount) { $RemovedGenerationCount.Value = $deletedGenerationCount }

        $unreferencedArchives = [pscustomobject]@{ Count = 0; SizeBytes = [long]0 }
        if ($null -ne $ArchiveDefinitions -and $ArchiveDefinitions.Count -gt 0) {
            $unreferencedArchives = Get-BRAVOUnreferencedBackupArchives `
                -ArchiveDefinitions $ArchiveDefinitions `
                -ReferencedArchiveNames $referencedArchiveNames
            if ($unreferencedArchives.Count -gt 0) {
                Write-BRAVOLog -Component 'CLEANUP' -Message (
                    "Архівів без generation manifest-а: $($unreferencedArchives.Count) " +
                    "($([math]::Round($unreferencedArchives.SizeBytes / 1GB, 2)) ГБ). " +
                    "Автоматично не видаляються; перевірте їх вручну"
                ) -Level 'INFO'
            }
        }

        # Один підсумковий рядок на прогін: скільки generation оцінено,
        # скільки захищено мінімальним порогом verified-копій (і які саме —
        # для forensic-діагностики), скільки реально видалено з розбивкою за
        # причиною. Доповнює вже наявні per-deletion рядки вище, не замінює.
        # Внутрішні дужки навколо конкатенації обов'язкові: -f зв'язується
        # сильніше за +, тому без них форматувався ЛИШЕ другий рядок — в
        # операторському лозі DEV-LIMS перша половина вийшла з літеральними
        # "{0}/{1}/{2}" (діагностика без чисел, помічено на acceptance).
        Write-BRAVOLog -Component 'CLEANUP' -Message (
            ("Аудит retention: generation оцінено={0}; захищено (verified)={1} [{2}]; " +
             "пошкоджено (COMPLETE, не пройшли перевірку)={3}; " +
             "збережено (невідомий тип компонента)={4}; " +
             "видалено (COMPLETE, прострочено)={5}; " +
             "видалено (failed/incomplete, прострочено)={6}; " +
             "помилок видалення={7}; архівів без manifest-а={8}") -f
            $records.Count, $protectedGenerationIds.Count,
            $(if ($hashVerificationNeeded) { $protectedGenerationIds -join ', ' } else { 'SHA512 не потрібен' }),
            $corruptGenerationIds.Count, $unresolvedGenerationIds.Count,
            $deletedVerifiedExpiredCount, $deletedFailedIncompleteCount,
            $failedDeletionIds.Count, $unreferencedArchives.Count
        ) -Level 'INFO'
        return ($failedDeletionIds.Count -eq 0)
    } catch {
        if ($null -ne $RemovedGenerationCount) { $RemovedGenerationCount.Value = $deletedGenerationCount }
        Write-BRAVOLog -Component 'CLEANUP' -Message "Generation-aware retention failed: $($_.Exception.Message)" -Level 'ERROR'
        return $false
    }
}

function Remove-OldLunchArchives {
    param(
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][string[]]$Directories,
        [int]$RetentionMonths = 2,
        # dev.16 (review round 3): опційний факт-сигнал для operator-console
        # unnumbered result — скільки файлів РЕАЛЬНО видалено (те саме
        # $deletedCount, що вже рахується нижче для LOG); мінімальний
        # ref-out-параметр, не змінює retention/delete semantics.
        # ВАЖЛИВО: ім'я НЕ Deleted*Count — нижче вже є локальна змінна
        # $deletedCount; PowerShell типізує параметр-змінну як [ref] на
        # всю область видимості функції, і регістр-незалежний збіг тихо
        # ламає $deletedCount += 2 нижче (кидає "operator works only on
        # numbers", кожне реальне видалення потрапляло б у catch як
        # false-failure — підтверджено реальним запуском).
        [ref]$RemovedFileCount
    )

    if (-not (Test-Path -LiteralPath $ArchiveRoot -PathType Container)) {
        Write-BRAVOLog -Component 'CLEANUP' -Message "Каталог обідніх архівів не знайдено: $ArchiveRoot" -Level "ERROR"
        if ($null -ne $RemovedFileCount) { $RemovedFileCount.Value = 0 }
        return $false
    }

    $resolvedArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot -ErrorAction Stop).Path.TrimEnd([char[]]"\\/")
    $effectiveRetentionMonths = [Math]::Max(1, $RetentionMonths)
    $cutoff = (Get-Date).AddMonths(-$effectiveRetentionMonths)
    $failed = $false
    $deletedCount = 0

    Write-BRAVOLog -Component 'CLEANUP' -Message "==="
    Write-BRAVOLog -Component 'CLEANUP' -Message "=== ОЧИЩЕННЯ СТАРИХ ОБІДНІХ АРХІВІВ ==="
    Write-BRAVOLog -Component 'CLEANUP' -Message "Дата відсічення: $cutoff; маркер імені: _1300." -Level "INFO"

    foreach ($directory in @($Directories | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })) {
        $directoryPath = Join-Path -Path $resolvedArchiveRoot -ChildPath $directory
        if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
            Write-BRAVOLog -Component 'CLEANUP' -Message "Каталог обідніх архівів не знайдено: $directoryPath" -Level "WARNING"
            $failed = $true
            continue
        }
        $resolvedDirectoryPath = (Resolve-Path -LiteralPath $directoryPath -ErrorAction Stop).Path.TrimEnd([char[]]"\\/")
        $archiveRootPrefix = $resolvedArchiveRoot + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedDirectoryPath.StartsWith($archiveRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Write-BRAVOLog -Component 'CLEANUP' -Message "Небезпечний каталог очищення поза ArchiveRoot пропущено: $directory" -Level "ERROR"
            $failed = $true
            continue
        }

        $directoryDeletedCount = 0
        $archiveSets = @{}
        foreach ($file in @(Get-BRAVOFiles -LiteralPath $resolvedDirectoryPath -Filter "*_1300.*")) {
            $setName = if ($file.Name -like "*.mdz.sha512") {
                $file.Name.Substring(0, $file.Name.Length - ".sha512".Length)
            } elseif ($file.Name -like "*.mdz") {
                $file.Name
            } else {
                continue
            }
            if (-not $archiveSets.ContainsKey($setName)) {
                $archiveSets[$setName] = @{}
            }
            if ($file.Name -like "*.mdz.sha512") {
                $archiveSets[$setName].Hash = $file
            } else {
                $archiveSets[$setName].Archive = $file
            }
        }

        foreach ($setName in @($archiveSets.Keys | Sort-Object)) {
            $archiveSet = $archiveSets[$setName]
            if (-not $archiveSet.ContainsKey("Archive") -or -not $archiveSet.ContainsKey("Hash")) {
                Write-BRAVOLog -Component 'CLEANUP' -Message "Неповний обідній комплект залишено без змін: $setName" -Level "WARNING"
                continue
            }
            $setLastWriteTime = (@(
                $archiveSet.Archive.LastWriteTime,
                $archiveSet.Hash.LastWriteTime
            ) | Measure-Object -Maximum).Maximum
            if ($setLastWriteTime -ge $cutoff) {
                continue
            }
            try {
                Remove-Item -LiteralPath $archiveSet.Archive.FullName -Force -ErrorAction Stop
                Remove-Item -LiteralPath $archiveSet.Hash.FullName -Force -ErrorAction Stop
                $directoryDeletedCount += 2
                $deletedCount += 2
                Write-BRAVOLog -Component 'CLEANUP' -Message "Видалено обідній комплект: $setName і $($archiveSet.Hash.Name)" -Level "SUCCESS"
            } catch {
                $failed = $true
                Write-BRAVOLog -Component 'CLEANUP' -Message "Не вдалося видалити обідній комплект ${setName}: $($_.Exception.Message)" -Level "ERROR"
            }
        }

        Write-BRAVOLog -Component 'CLEANUP' -Message "Каталог ${directory}: видалено $directoryDeletedCount обідніх файлів" -Level "INFO"
    }

    Write-BRAVOLog -Component 'CLEANUP' -Message "Усього видалено обідніх файлів: $deletedCount" -Level "INFO"
    if ($null -ne $RemovedFileCount) { $RemovedFileCount.Value = $deletedCount }
    return (-not $failed)
}



function Sync-Folders {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )
    
    Write-BRAVOLog -Component 'BAZA' -Message "Синхронiзацiя: $SourcePath -> $DestinationPath"
    
    if (-not (Test-Path $SourcePath)) {
        Write-BRAVOLog -Component 'BAZA' -Message "Джерельна папка не знайдена: $SourcePath" -Level "ERROR"
        return $false
    }
    
    try {
        # Створюємо цільову папку, якщо не існує
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Write-BRAVOLog -Component 'BAZA' -Message "Створено цiльову папку: $DestinationPath" -Level "SUCCESS"
        }
        
        # Виконуємо синхронізацію за допомогою Robocopy
        $effectiveRobocopyOptions = @($robocopyOptions)
        $showRobocopyProgress = $progressSettings.Enabled -and $progressSettings.ShowRobocopyOutput

        if ($showRobocopyProgress) {
            # /NP приховує відсотки, тому прибираємо його лише для режиму прогресу.
            $effectiveRobocopyOptions = @($effectiveRobocopyOptions | Where-Object { $_ -ine "/NP" })
            foreach ($progressOption in @($progressSettings.RobocopyProgressOptions)) {
                if (-not [string]::IsNullOrWhiteSpace($progressOption) -and
                    -not ($effectiveRobocopyOptions -icontains $progressOption)) {
                    $effectiveRobocopyOptions += $progressOption
                }
            }
        }

        $robocopyArgs = @("`"$SourcePath`"", "`"$DestinationPath`"") + $effectiveRobocopyOptions
        
        Write-BRAVOLog -Component 'BAZA' -Message "Виконання: robocopy $robocopyArgs" -Level "DEBUG"

        if ($showRobocopyProgress) {
            # Локалізований текст Robocopy використовує OEM-кодування і в деяких
            # PowerShell-hosts відображається пошкодженим. Вивід спрямовується у
            # NUL, а скрипт показує власний незалежний індикатор виконання.
            $progressRobocopyArgs = @($robocopyArgs) + @("/LOG:NUL")
            $process = Start-Process `
                -FilePath $robocopyPath `
                -ArgumentList $progressRobocopyArgs `
                -PassThru `
                -WindowStyle $robocopyWindowStyle
            $robocopyStarted = Get-Date
            do {
                $process.Refresh()
                $elapsed = [math]::Floor(((Get-Date) - $robocopyStarted).TotalSeconds)
                Show-RunningProgress `
                    -Id 3 `
                    -Activity "Robocopy — синхронiзацiя BAZA" `
                    -Status (Format-BRAVORunningDetail -ElapsedSeconds $elapsed) `
                    -PercentComplete -1
                if (-not $process.HasExited) {
                    Start-Sleep -Milliseconds 500
                }
            } while (-not $process.HasExited)
            $process.WaitForExit()
            Show-RunningProgress -Id 3 -Activity "Robocopy — синхронiзацiя BAZA" -Completed
            $exitCode = $process.ExitCode
        } else {
            $process = Start-Process -FilePath $robocopyPath -ArgumentList $robocopyArgs -Wait -PassThru -WindowStyle $robocopyWindowStyle
            $exitCode = $process.ExitCode
        }
        
        # Коди виходу Robocopy: 0-7 = успіх, 8+ = помилка
        if ($exitCode -le $robocopyMaxSuccessExitCode) {
            Write-BRAVOLog -Component 'BAZA' -Message "Синхронiзацiя успiшна (код: $exitCode)" -Level "DEBUG"
            return $true
        } else {
            Write-BRAVOLog -Component 'BAZA' -Message "Помилка синхронiзацiї (код: $exitCode)" -Level "ERROR"
            return $false
        }
    }
    catch {
        Write-BRAVOLog -Component 'BAZA' -Message "Помилка синхронiзацiї: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# =============================================
# ФУНКЦІЇ АРХІВАЦІЇ
# =============================================



function Write-SevenZipFailureDiagnostics {
    param([string]$Operation, [string]$StandardOutput, [string]$StandardError)
    foreach ($line in @($StandardOutput, $StandardError)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-BRAVOLog -Component 'ARCHIVE' -Message "${Operation}: $($line.Trim().Substring(0, [math]::Min(4000, $line.Trim().Length)))" -Level 'DEBUG'
        }
    }
}

function Get-BRAVOVSSSnapshotSourcePath {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DeviceObject
    )

    $normalizedSourcePath = $SourcePath.Replace("/", "\")
    $volumeRoot = [IO.Path]::GetPathRoot($normalizedSourcePath)
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or
        $volumeRoot -notmatch '^[A-Za-z]:\\$') {
        throw "VSS підтримує лише локальний шлях із літерою диска: $SourcePath"
    }
    if ([string]::IsNullOrWhiteSpace($DeviceObject)) {
        throw "VSS не повернув шлях DeviceObject для джерела: $SourcePath"
    }

    $snapshotRoot = $DeviceObject.TrimEnd([char[]]"\/")
    $relativePath = $normalizedSourcePath.Substring($volumeRoot.Length).TrimStart([char[]]"\/")
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        return "$snapshotRoot\"
    }
    return "$snapshotRoot\$relativePath"
}

function Get-BRAVOVSSReturnCodeDescription {
    param([int]$ReturnCode)

    $descriptions = @{
        0 = "успішно"
        1 = "доступ заборонено"
        2 = "некоректний аргумент"
        3 = "том не знайдено"
        4 = "том не підтримує VSS"
        5 = "контекст VSS не підтримується"
        6 = "недостатньо місця для shadow copy"
        7 = "том зайнятий"
        8 = "досягнуто максимальну кількість shadow copies"
        9 = "вже виконується інша операція shadow copy"
        10 = "VSS provider відхилив операцію"
        11 = "VSS provider не зареєстрований"
        12 = "помилка VSS provider"
        13 = "невідома помилка VSS"
    }
    if ($descriptions.ContainsKey($ReturnCode)) {
        return $descriptions[$ReturnCode]
    }
    return "невідома помилка VSS"
}

function New-BRAVOVSSSnapshotLink {
    param([Parameter(Mandatory = $true)][string]$DeviceObject)

    # .NET/PowerShell (Test-Path, Get-ChildItem, 7-Zip тощо) не вміють
    # напряму читати "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyN\" —
    # це не звичайний шлях файлової системи. Каталогове симлінк-посилання
    # (той самий прийом, що й diskshadow.exe EXPOSE) робить вміст знімка
    # доступним через звичайний шлях.
    $linkPath = Join-Path ([System.IO.Path]::GetTempPath()) ("BRAVO_VSS_" + [guid]::NewGuid().ToString("N"))
    $target = $DeviceObject.TrimEnd("\", "/") + "\"

    # Явне квотування обох шляхів усередині рядка, який отримує cmd.exe /c
    # — $linkPath (%TEMP%) і $target (VSS DeviceObject) на практиці не
    # містять пробілів, але без лапок cmd.exe розбив би аргумент на кілька
    # токенів, якби це колись змінилось (інший профіль/мапований диск).
    $quotedLinkPath = '"' + $linkPath + '"'
    $quotedTarget = '"' + $target + '"'
    $mklinkOutput = & cmd.exe /c mklink /d $quotedLinkPath $quotedTarget 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $linkPath)) {
        throw "Не вдалося створити символiчне посилання на VSS-знiмок ($target): $mklinkOutput"
    }
    return $linkPath
}

function Remove-BRAVOVSSSnapshotLink {
    param([string]$LinkPath)

    if ([string]::IsNullOrWhiteSpace($LinkPath)) {
        return
    }
    # Directory.Delete(recursive=$false) знімає лише сам reparse-point і не
    # торкається вмісту знімка. Перевірка через Test-Path тут не годиться:
    # для висячого посилання (знімок уже зник) вона дає $false, і сміттєвий
    # каталог залишався б у %TEMP% назавжди.
    try {
        [System.IO.Directory]::Delete($LinkPath, $false)
    } catch [System.IO.DirectoryNotFoundException] {
        # Посилання вже прибрано — нічого робити.
    } catch {
        Write-BRAVOLog -Component 'VSS' -Message "Не вдалося прибрати символiчне посилання на VSS-знiмок: $LinkPath ($($_.Exception.Message))" -Level "WARNING"
    }
}

function Get-BRAVOVSSVolumeRoot {
    # Корінь тому ("D:\") для шляху джерела. VSS працює томами, а не
    # каталогами: саме тому три джерела на одному диску мають дати ОДИН
    # знімок, а не три.
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalizedPath = ([string]$Path).Replace("/", "\").TrimEnd("*")
    $volumeRoot = [IO.Path]::GetPathRoot($normalizedPath)
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or
        $volumeRoot -notmatch '^[A-Za-z]:\\$') {
        throw "Не вдалося визначити локальний том VSS для джерела: $Path"
    }
    return $volumeRoot.ToUpperInvariant()
}

function Get-BRAVOUniqueVSSVolumes {
    # Дедуплікація томів ДО створення знімків. Без неї MODEL, BLOG і
    # BRAVOEXCH з одного диска давали три окремі shadow copies — три різні
    # моменти часу для того, що логічно є одним backup.
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SourcePaths)

    $uniqueVolumes = New-Object System.Collections.Generic.List[string]
    foreach ($sourcePath in @($SourcePaths)) {
        if ([string]::IsNullOrWhiteSpace($sourcePath)) {
            continue
        }
        $volumeRoot = Get-BRAVOVSSVolumeRoot -Path $sourcePath
        if (-not $uniqueVolumes.Contains($volumeRoot)) {
            $uniqueVolumes.Add($volumeRoot)
        }
    }
    return @($uniqueVolumes | Sort-Object)
}

function New-BRAVOVSSVolumeShadow {
    # Один shadow copy одного тому через Win32_ShadowCopy + символічне
    # посилання, щоб 7-Zip міг читати вміст звичайним шляхом.
    param([Parameter(Mandatory = $true)][string]$VolumeRoot)

    $snapshotContext = [string]$backupConsistency.SnapshotContext
    if ([string]::IsNullOrWhiteSpace($snapshotContext)) {
        $snapshotContext = "ClientAccessible"
    }

    $shadowId = $null
    $snapshotLinkPath = $null
    try {
        $shadowClass = [wmiclass]"\\.\root\cimv2:Win32_ShadowCopy"
        $createResult = $shadowClass.Create($VolumeRoot, $snapshotContext)
        if ($null -eq $createResult) {
            throw "Win32_ShadowCopy.Create не повернув результат"
        }
        $returnCode = [int]$createResult.ReturnValue
        if ($returnCode -ne 0) {
            $description = Get-BRAVOVSSReturnCodeDescription -ReturnCode $returnCode
            throw "Win32_ShadowCopy.Create повернув код $returnCode ($description)"
        }
        $shadowId = [string]$createResult.ShadowID
        if ([string]::IsNullOrWhiteSpace($shadowId)) {
            throw "VSS не повернув ідентифікатор створеного знімка"
        }

        $escapedShadowId = $shadowId.Replace("'", "''")
        $shadow = Get-WmiObject `
            -Namespace "root\cimv2" `
            -Class "Win32_ShadowCopy" `
            -Filter ("ID='{0}'" -f $escapedShadowId) `
            -ErrorAction Stop |
            Select-Object -First 1
        if ($null -eq $shadow -or [string]::IsNullOrWhiteSpace([string]$shadow.DeviceObject)) {
            throw "створений VSS-знімок $shadowId не знайдено"
        }

        $snapshotLinkPath = New-BRAVOVSSSnapshotLink -DeviceObject ([string]$shadow.DeviceObject)
        return [pscustomobject]@{
            VolumeRoot = $VolumeRoot
            OriginalVolume = $VolumeRoot
            ShadowId = $shadowId
            SnapshotId = $shadowId
            SetId = [string]$shadow.SetID
            SnapshotSetId = [string]$shadow.SetID
            DeviceObject = [string]$shadow.DeviceObject
            SnapshotDeviceObject = [string]$shadow.DeviceObject
            LinkPath = $snapshotLinkPath
            WmiObject = $shadow
        }
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($snapshotLinkPath)) {
            try {
                Remove-BRAVOVSSSnapshotLink -LinkPath $snapshotLinkPath
            } catch {
                # Основна помилка створення VSS важливіша за помилку best-effort cleanup.
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($shadowId)) {
            try {
                $escapedShadowId = $shadowId.Replace("'", "''")
                $orphanedShadow = Get-WmiObject `
                    -Namespace "root\cimv2" `
                    -Class "Win32_ShadowCopy" `
                    -Filter ("ID='{0}'" -f $escapedShadowId) `
                    -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($null -ne $orphanedShadow) {
                    $null = $orphanedShadow.Delete()
                }
            } catch {
                # Основна помилка створення VSS важливіша за помилку best-effort cleanup.
            }
        }
        throw
    }
}

function Test-BRAVOFileSystemWriteProbe {
    param([Parameter(Mandatory = $true)][string]$Path)

    $probePath = $null
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop)
        }
        $probePath = Join-Path $Path ('.bravo_write_probe_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        $expected = [Text.Encoding]::UTF8.GetBytes('BRAVO_SYSTEM_WRITE_PROBE')
        $stream = [IO.File]::Open(
            $probePath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try {
            $stream.Write($expected, 0, $expected.Length)
            $stream.Flush()
        } finally {
            $stream.Dispose()
        }
        $actual = [IO.File]::ReadAllBytes($probePath)
        if ($actual.Length -ne $expected.Length -or
            [Convert]::ToBase64String($actual) -cne [Convert]::ToBase64String($expected)) {
            throw 'read-back content does not match the probe payload'
        }
        return [pscustomobject]@{ Success = $true; Path = $Path; Error = $null }
    } catch {
        return [pscustomobject]@{ Success = $false; Path = $Path; Error = $_.Exception.Message }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($probePath) -and
            [IO.File]::Exists($probePath)) {
            try {
                [IO.File]::Delete($probePath)
            } catch {
                # Probe result already records the access failure; cleanup is
                # best-effort and must not hide the original diagnostic.
            }
        }
    }
}

function Test-BRAVOSourceReadProbe {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $sourceDirectory = $Path.TrimEnd('*', '\', '/')
        if (-not [IO.Directory]::Exists($sourceDirectory)) {
            throw "source directory does not exist: $sourceDirectory"
        }
        [void][IO.File]::GetAttributes($sourceDirectory)
        $firstEntry = [IO.Directory]::EnumerateFileSystemEntries($sourceDirectory) |
            Select-Object -First 1
        $isEmpty = [string]::IsNullOrWhiteSpace([string]$firstEntry)
        if (-not $isEmpty) {
            [void][IO.File]::GetAttributes([string]$firstEntry)
        }
        return [pscustomobject]@{
            Success = $true
            Path = $sourceDirectory
            Empty = $isEmpty
            Error = $null
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Path = $Path
            Empty = $null
            Error = $_.Exception.Message
        }
    }
}

function Get-BRAVOVSSVolumeIdentityCandidates {
    param([Parameter(Mandatory = $true)][string]$VolumeRoot)

    $candidates = New-Object System.Collections.ArrayList
    $normalizedVolumeRoot = ([string]$VolumeRoot).TrimEnd("\") + "\"
    [void]$candidates.Add($normalizedVolumeRoot.ToUpperInvariant())
    [void]$candidates.Add($normalizedVolumeRoot.TrimEnd("\").ToUpperInvariant())

    try {
        $volume = Get-WmiObject `
            -Namespace "root\cimv2" `
            -Class "Win32_Volume" `
            -Filter ("DriveLetter='{0}'" -f $normalizedVolumeRoot.TrimEnd("\")) `
            -ErrorAction Stop |
            Select-Object -First 1
        if ($null -ne $volume -and -not [string]::IsNullOrWhiteSpace([string]$volume.DeviceID)) {
            $volumeDeviceId = ([string]$volume.DeviceID).TrimEnd("\") + "\"
            [void]$candidates.Add($volumeDeviceId.ToUpperInvariant())
            [void]$candidates.Add($volumeDeviceId.TrimEnd("\").ToUpperInvariant())
        }
    } catch {
        # Drive-letter identity is still usable; Win32_Volume is best-effort for GUID-style VolumeName.
    }

    return @($candidates | Select-Object -Unique)
}

function Test-BRAVOVSSShadowMatchesVolume {
    param(
        [Parameter(Mandatory = $true)][object]$Shadow,
        [Parameter(Mandatory = $true)][string]$VolumeRoot
    )

    $candidates = @(Get-BRAVOVSSVolumeIdentityCandidates -VolumeRoot $VolumeRoot)
    foreach ($shadowVolumeName in @($Shadow.VolumeName)) {
        if ([string]::IsNullOrWhiteSpace([string]$shadowVolumeName)) {
            continue
        }
        $normalizedShadowVolume = ([string]$shadowVolumeName).TrimEnd("\") + "\"
        if ($candidates -contains $normalizedShadowVolume.ToUpperInvariant()) {
            return $true
        }
        if ($candidates -contains $normalizedShadowVolume.TrimEnd("\").ToUpperInvariant()) {
            return $true
        }
    }
    return $false
}

function Get-BRAVOVSSExistingShadowIdMap {
    # Знімок ID усіх наявних shadow copies ДО запуску diskshadow.exe. Потрібен
    # двічі: щоб знайти щойно створений набір, коли вивід diskshadow.exe не
    # вдалося розібрати, і щоб прибрати за собою persistent-знімки, якщо набір
    # створився, але подальші кроки впали.
    $map = @{}
    try {
        foreach ($shadow in @(
                Get-WmiObject -Namespace "root\cimv2" -Class "Win32_ShadowCopy" -ErrorAction Stop
            )) {
            $shadowId = [string]$shadow.ID
            if (-not [string]::IsNullOrWhiteSpace($shadowId)) {
                $map[$shadowId.ToUpperInvariant()] = $true
            }
        }
    } catch {
        # Best-effort baseline: без нього лишаються парсинг виводу diskshadow.exe
        # та відмова з явною помилкою, тому запит WMI не має зривати архівацію.
    }
    return $map
}

function Get-BRAVOVSSDiskshadowSetIdFromOutput {
    # diskshadow.exe друкує людські повідомлення мовою системи, тому шукати в них
    # англійський текст не можна: на локалізованому Windows Server такий пошук не
    # знаходить нічого і архівація падає на успішно створеному наборі. Стабільні
    # тут лише імена alias-ів (ASCII, не перекладаються) і самі GUID-и, тому
    # ідентифікатор набору беремо з рядка з alias-ом VSS_SHADOW_SET.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Output)

    if ([string]::IsNullOrEmpty($Output)) {
        return $null
    }
    $guidPattern = '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}'
    foreach ($line in ($Output -split "`r?`n")) {
        if ($line -notmatch 'VSS_SHADOW_SET') {
            continue
        }
        $guidMatch = [regex]::Match($line, $guidPattern)
        if ($guidMatch.Success) {
            return $guidMatch.Value.ToUpperInvariant()
        }
    }
    return $null
}

function Get-BRAVOVSSDiskshadowSetIdFromWmi {
    # Резервний шлях, коли вивід diskshadow.exe не містить alias-рядка: набором
    # вважається єдиний SetID серед shadow copies, яких не було до запуску.
    param(
        [Parameter(Mandatory = $true)][hashtable]$KnownShadowIds,
        [Parameter(Mandatory = $true)][string[]]$VolumeRoots
    )

    try {
        $currentShadows = @(
            Get-WmiObject -Namespace "root\cimv2" -Class "Win32_ShadowCopy" -ErrorAction Stop
        )
    } catch {
        return $null
    }

    $setIds = New-Object System.Collections.Generic.List[string]
    foreach ($shadow in $currentShadows) {
        $shadowId = [string]$shadow.ID
        if ([string]::IsNullOrWhiteSpace($shadowId) -or
            $KnownShadowIds.ContainsKey($shadowId.ToUpperInvariant())) {
            continue
        }
        $matchesRequestedVolume = $false
        foreach ($volumeRoot in @($VolumeRoots)) {
            if (Test-BRAVOVSSShadowMatchesVolume -Shadow $shadow -VolumeRoot $volumeRoot) {
                $matchesRequestedVolume = $true
                break
            }
        }
        if (-not $matchesRequestedVolume) {
            continue
        }
        $setId = [string]$shadow.SetID
        if (-not [string]::IsNullOrWhiteSpace($setId) -and
            -not $setIds.Contains($setId.ToUpperInvariant())) {
            [void]$setIds.Add($setId.ToUpperInvariant())
        }
    }
    if ($setIds.Count -eq 1) {
        return $setIds[0]
    }
    return $null
}

function Remove-BRAVOVSSDiskshadowOrphanedShadow {
    # SET CONTEXT PERSISTENT NOWRITERS означає, що знімки не звільняються самі:
    # кожен невдалий запуск без цього прибирання лишав на сервері shadow copies,
    # які назавжди тримали місце в тіньовому сховищі томів.
    param(
        [AllowNull()][AllowEmptyString()][string]$SnapshotSetId,
        [Parameter(Mandatory = $true)][hashtable]$KnownShadowIds,
        [Parameter(Mandatory = $true)][string[]]$VolumeRoots
    )

    try {
        $currentShadows = @(
            Get-WmiObject -Namespace "root\cimv2" -Class "Win32_ShadowCopy" -ErrorAction Stop
        )
    } catch {
        return
    }

    $normalizedSetId = if ([string]::IsNullOrWhiteSpace($SnapshotSetId)) {
        $null
    } else {
        $SnapshotSetId.ToUpperInvariant()
    }

    foreach ($shadow in $currentShadows) {
        $shadowId = [string]$shadow.ID
        if ([string]::IsNullOrWhiteSpace($shadowId)) {
            continue
        }
        # Чужі знімки (у т.ч. створені паралельно іншим ПЗ) не чіпаємо: видаляємо
        # лише ті, яких не було до нашого запуску і які лежать на наших томах,
        # або ті, що явно належать нашому набору.
        if ($KnownShadowIds.ContainsKey($shadowId.ToUpperInvariant())) {
            continue
        }
        $isOurs = $false
        if ($null -ne $normalizedSetId -and
            ([string]$shadow.SetID).ToUpperInvariant() -eq $normalizedSetId) {
            $isOurs = $true
        } else {
            foreach ($volumeRoot in @($VolumeRoots)) {
                if (Test-BRAVOVSSShadowMatchesVolume -Shadow $shadow -VolumeRoot $volumeRoot) {
                    $isOurs = $true
                    break
                }
            }
        }
        if (-not $isOurs) {
            continue
        }
        try { [void]$shadow.Delete() } catch {
            # Best-effort cleanup: первинна помилка створення набору важливіша.
        }
    }
}

function New-BRAVOVSSDiskshadowSnapshotSet {
    param([Parameter(Mandatory = $true)][string[]]$VolumeRoots)

    $diskshadowPath = Join-Path $env:SystemRoot "System32\diskshadow.exe"
    if (-not (Test-Path -LiteralPath $diskshadowPath -PathType Leaf)) {
        throw (
            "Джерела backup розташовані на кількох томах ($($VolumeRoots -join ', ')), " +
            "а атомарний багатотомний VSS Snapshot Set потребує diskshadow.exe, якого немає в системі. " +
            "Окремі знімки кожного тому дали б різні моменти часу для однієї generation, тому архівацію зупинено."
        )
    }

    $scriptPath = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_diskshadow_{0}.txt" -f [guid]::NewGuid().ToString("N"))
    # SET METADATA обов'язковий (5.2.1): без нього diskshadow.exe у
    # backup-контексті пише VSS writer metadata .cab з автоіменем
    # (NN-DD.MM.YYYY-HH_--_HOSTNAME.cab) у ПОТОЧНИЙ РОБОЧИЙ КАТАЛОГ
    # процесу — для планової задачі це каталог комплекту, і файли
    # накопичувались у C:\Program Files\BRAVO-Toolkit з кожної
    # багатотомної архівації (реальний звіт SERVER-01/Лабораторія-12
    # 2026-08-26). BRAVO ці метадані не використовує (контекст
    # NOWRITERS), тому файл спрямовується в TEMP і прибирається у finally
    # разом зі сценарієм.
    $metadataPath = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_diskshadow_meta_{0}.cab" -f [guid]::NewGuid().ToString("N"))

    # Одноразове best-effort прибирання ВЖЕ накопичених metadata-.cab від
    # попередніх версій (до SET METADATA вище): у каталозі комплекту вони
    # мають строго розпізнаваний шаблон автоімені diskshadow з іменем
    # ЦЬОГО хоста — нічого іншого під нього не підпадає. Помилка видалення
    # (файл залочено) не блокує backup.
    try {
        $legacyMetadataPattern = "^\d+-\d{2}\.\d{2}\.\d{4}-\d+_--_$([regex]::Escape($env:COMPUTERNAME))\.cab$"
        $legacyMetadataFiles = @(Get-ChildItem -LiteralPath $bravoScriptDirectory -File -Filter '*.cab' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $legacyMetadataPattern })
        foreach ($legacyMetadataFile in $legacyMetadataFiles) {
            Remove-Item -LiteralPath $legacyMetadataFile.FullName -Force -ErrorAction SilentlyContinue
        }
        if (@($legacyMetadataFiles).Count -gt 0) {
            Write-BRAVOLog -Component 'VSS' -Message "Прибрано $(@($legacyMetadataFiles).Count) legacy metadata-.cab diskshadow з каталогу комплекту (тимчасові артефакти попередніх версій)" -Level "INFO"
        }
    } catch {
        # Прибирання суто гігієнічне: збій не має стосунку до створення набору.
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("SET CONTEXT PERSISTENT NOWRITERS")
    $lines.Add("SET VERBOSE ON")
    $lines.Add(("SET METADATA `"{0}`"" -f $metadataPath))
    $lines.Add("BEGIN BACKUP")
    $index = 0
    foreach ($volumeRoot in @($VolumeRoots)) {
        $index++
        $volumeName = ([string]$volumeRoot).TrimEnd("\")
        $lines.Add(("ADD VOLUME {0} ALIAS BRAVOVolume{1}" -f $volumeName, $index))
    }
    $lines.Add("CREATE")
    $lines.Add("END BACKUP")
    # Без EXIT diskshadow.exe доходить до кінця файлу сценарію як до
    # несподіваного завершення інтерактивної сесії і повертає ненульовий код
    # навіть тоді, коли Snapshot Set створено успішно.
    $lines.Add("EXIT")

    $volumeShadows = $null
    $snapshotSetId = $null
    $knownShadowIds = Get-BRAVOVSSExistingShadowIdMap
    try {
        [IO.File]::WriteAllLines($scriptPath, $lines.ToArray(), (New-Object Text.UTF8Encoding($false)))

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $diskshadowPath
        $processInfo.Arguments = "/s `"$scriptPath`""
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        try {
            # diskshadow.exe пише в OEM-кодуванні консолі. Без явного
            # StandardOutputEncoding діагностика в лозі перетворюється на
            # нечитабельні символи саме тоді, коли вона найпотрібніша.
            $oemEncoding = [System.Text.Encoding]::GetEncoding(
                [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
            )
            $processInfo.StandardOutputEncoding = $oemEncoding
            $processInfo.StandardErrorEncoding = $oemEncoding
        } catch {
            # Кодування — питання читабельності діагностики, а не коректності
            # набору: розбір спирається лише на ASCII-alias і GUID-и.
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        # Start-BRAVOProcessOutputCapture сам запускає процес. Додатковий
        # $process.Start() робив Close() поточного процесу і запускав другий
        # diskshadow.exe: набір створював перший процес, а код завершення й
        # WaitForExit бралися вже від другого, тому кожен багатотомний backup
        # падав на успішно створеному наборі.
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        if (-not $process.WaitForExit(300000)) {
            try { $process.Kill() } catch {
                # Основна помилка timeout важливіша: процес міг завершитись між WaitForExit і Kill.
            }
            throw "diskshadow.exe не завершився протягом 300 секунд"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        # Ідентифікатор набору визначаємо ДО перевірки коду завершення: якщо
        # diskshadow.exe встиг створити persistent-знімки і аж потім впав,
        # cleanup у catch має знати, що саме прибирати.
        $snapshotSetId = Get-BRAVOVSSDiskshadowSetIdFromOutput -Output (
            $capturedOutput.StandardOutput + "`n" + $capturedOutput.StandardError
        )
        if ($process.ExitCode -ne 0) {
            throw "diskshadow.exe повернув код $($process.ExitCode): $($capturedOutput.StandardError) $($capturedOutput.StandardOutput)"
        }

        if ([string]::IsNullOrWhiteSpace($snapshotSetId)) {
            $snapshotSetId = Get-BRAVOVSSDiskshadowSetIdFromWmi `
                -KnownShadowIds $knownShadowIds `
                -VolumeRoots $VolumeRoots
        }
        if ([string]::IsNullOrWhiteSpace($snapshotSetId)) {
            throw "diskshadow.exe не повідомив Shadow copy set ID"
        }
        $escapedSetId = $snapshotSetId.Replace("'", "''")
        $wmiShadows = @(
            Get-WmiObject `
                -Namespace "root\cimv2" `
                -Class "Win32_ShadowCopy" `
                -Filter ("SetID='{0}'" -f $escapedSetId) `
                -ErrorAction Stop
        )
        if ($wmiShadows.Count -ne $VolumeRoots.Count) {
            throw "VSS Snapshot Set $snapshotSetId містить $($wmiShadows.Count) shadow copies замість $($VolumeRoots.Count)"
        }

        $volumeShadows = New-Object System.Collections.ArrayList
        foreach ($volumeRoot in @($VolumeRoots)) {
            $shadow = @(
                $wmiShadows | Where-Object {
                    Test-BRAVOVSSShadowMatchesVolume -Shadow $_ -VolumeRoot $volumeRoot
                }
            ) | Select-Object -First 1
            if ($null -eq $shadow) {
                throw "у Snapshot Set $snapshotSetId не знайдено shadow copy для тому $volumeRoot"
            }
            $snapshotLinkPath = New-BRAVOVSSSnapshotLink -DeviceObject ([string]$shadow.DeviceObject)
            [void]$volumeShadows.Add([pscustomobject]@{
                VolumeRoot = $volumeRoot
                OriginalVolume = $volumeRoot
                ShadowId = [string]$shadow.ID
                SnapshotId = [string]$shadow.ID
                SetId = [string]$shadow.SetID
                SnapshotSetId = [string]$shadow.SetID
                DeviceObject = [string]$shadow.DeviceObject
                SnapshotDeviceObject = [string]$shadow.DeviceObject
                LinkPath = $snapshotLinkPath
                WmiObject = $shadow
            })
        }
        return [pscustomobject]@{
            SnapshotSetId = $snapshotSetId
            Volumes = @($volumeShadows)
            UniqueVolumeCount = $VolumeRoots.Count
            CreatedAt = Get-Date
        }
    } catch {
        foreach ($createdShadow in @($volumeShadows)) {
            try {
                Remove-BRAVOVSSSnapshotLink -LinkPath $createdShadow.LinkPath
            } catch {
                # Best-effort cleanup після частково створених link-ів; первинна помилка лишається нижче.
            }
        }
        try {
            # Прибирання не можна ставити в залежність від розібраного SetID:
            # саме коли розбір не вдався, persistent-знімки й лишалися на
            # сервері після кожного невдалого запуску.
            Remove-BRAVOVSSDiskshadowOrphanedShadow `
                -SnapshotSetId $snapshotSetId `
                -KnownShadowIds $knownShadowIds `
                -VolumeRoots $VolumeRoots
        } catch {
            # Не перекриваємо первинну помилку diskshadow/WMI вторинною помилкою cleanup.
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $scriptPath -PathType Leaf) {
            Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
            Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-BRAVOVSSSnapshotSet {
    # ОДИН snapshot set на всю generation: MODEL, BLOG і BRAVOEXCH мають
    # відповідати одному point-in-time. Раніше знімок створювався всередині
    # циклу перед кожним компонентом, тому MODEL, BLOG і BRAVOEXCH одного
    # "backup" фіксували стан системи з різницею в хвилини — поки BRAVO
    # працює, це три різні бази, а не одна узгоджена копія.
    #
    # Win32_ShadowCopy.Create вміє лише один том за виклик і не має способу
    # додати том до вже початого набору — атомарний багатотомний Snapshot Set
    # доступний тільки через VSS COM API або diskshadow.exe. Тому:
    #   * один том    -> один Create, справжній єдиний point-in-time;
    #   * кілька томів -> diskshadow.exe, якщо він є в системі;
    #   * кілька томів без diskshadow.exe -> керована помилка.
    # Тихо створити кілька незалежних знімків і назвати це "набором" не
    # можна: це та сама розсинхронізація, заради усунення якої все й робиться.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SourcePaths,
        # Ін'єкція для self-тестів: дозволяє перевірити дедуплікацію,
        # мапування шляхів і cleanup без створення реальних shadow copies.
        [scriptblock]$VolumeShadowFactory
    )

    $uniqueVolumes = @(Get-BRAVOUniqueVSSVolumes -SourcePaths $SourcePaths)
    if ($uniqueVolumes.Count -eq 0) {
        throw "Для VSS-набору не визначено жодного тому: перевірте шляхи джерел"
    }

    Write-BRAVOLog -Component 'VSS' -Message "Створення VSS Snapshot Set для томів: $($uniqueVolumes -join ', ')" -Level "INFO"
    if ($uniqueVolumes.Count -gt 1 -and $null -eq $VolumeShadowFactory) {
        $snapshotSet = New-BRAVOVSSDiskshadowSnapshotSet -VolumeRoots $uniqueVolumes
        Write-BRAVOLog -Component 'VSS' -Message "VSS Snapshot Set створено: $($snapshotSet.SnapshotSetId) (томів: $($uniqueVolumes.Count))" -Level "SUCCESS"
        return $snapshotSet
    }

    $volumeShadows = New-Object System.Collections.ArrayList
    try {
        foreach ($volumeRoot in $uniqueVolumes) {
            $volumeShadow = if ($null -ne $VolumeShadowFactory) {
                & $VolumeShadowFactory $volumeRoot
            } else {
                New-BRAVOVSSVolumeShadow -VolumeRoot $volumeRoot
            }
            if ($null -eq $volumeShadow) {
                throw "не вдалося створити знімок тому $volumeRoot"
            }
            [void]$volumeShadows.Add($volumeShadow)
        }

        # SetID від VSS, коли він єдиний для всіх томів; інакше — власний
        # кореляційний ідентифікатор, щоб журнал і manifest могли пов'язати
        # знімки однієї generation між собою.
        $distinctSetIds = @(
            $volumeShadows |
                ForEach-Object { [string]$_.SetId } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )
        $snapshotSetId = if ($distinctSetIds.Count -eq 1) {
            $distinctSetIds[0]
        } else {
            "{" + [guid]::NewGuid().ToString().ToUpperInvariant() + "}"
        }

        $snapshotSet = [pscustomobject]@{
            SnapshotSetId = $snapshotSetId
            Volumes = @($volumeShadows)
            UniqueVolumeCount = $uniqueVolumes.Count
            CreatedAt = Get-Date
        }
        Write-BRAVOLog -Component 'VSS' -Message "VSS Snapshot Set створено: $snapshotSetId (томів: $($uniqueVolumes.Count))" -Level "SUCCESS"
        return $snapshotSet
    } catch {
        foreach ($createdShadow in @($volumeShadows)) {
            try {
                [void](Remove-BRAVOVSSVolumeShadow -VolumeShadow $createdShadow)
            } catch {
                # Основна помилка створення набору важливіша за помилку cleanup.
            }
        }
        throw
    }
}

function Resolve-BRAVOSnapshotSourcePath {
    # Оригінальний шлях -> шлях усередині знімка ТОГО САМОГО набору.
    # Якщо тому джерела в наборі немає, це помилка: архівувати "живий" шлях
    # замість знімка означало б мовчки повернути неузгоджену копію.
    param(
        [Parameter(Mandatory = $true)][object]$SnapshotSet,
        [Parameter(Mandatory = $true)][string]$OriginalPath
    )

    $volumeRoot = Get-BRAVOVSSVolumeRoot -Path $OriginalPath
    $volumeShadow = @(
        $SnapshotSet.Volumes | Where-Object {
            [string]::Equals([string]$_.VolumeRoot, $volumeRoot, [StringComparison]::OrdinalIgnoreCase)
        }
    ) | Select-Object -First 1
    if ($null -eq $volumeShadow) {
        throw "У VSS-наборі $($SnapshotSet.SnapshotSetId) немає знімка тому $volumeRoot для джерела: $OriginalPath"
    }

    return Get-BRAVOVSSSnapshotSourcePath `
        -SourcePath $OriginalPath `
        -DeviceObject ([string]$volumeShadow.LinkPath)
}

function Remove-BRAVOVSSVolumeShadow {
    param([Parameter(Mandatory = $true)][object]$VolumeShadow)

    try {
        Remove-BRAVOVSSSnapshotLink -LinkPath $VolumeShadow.LinkPath
    } catch {
        Write-BRAVOLog -Component 'VSS' -Message "Не вдалося прибрати символiчне посилання на VSS-знiмок $($VolumeShadow.ShadowId): $($_.Exception.Message)" -Level "WARNING"
    }

    if ($null -eq $VolumeShadow.WmiObject) {
        return $true
    }
    try {
        $deleteResult = $VolumeShadow.WmiObject.Delete()
        if ($null -ne $deleteResult -and [int]$deleteResult.ReturnValue -ne 0) {
            $returnCode = [int]$deleteResult.ReturnValue
            $description = Get-BRAVOVSSReturnCodeDescription -ReturnCode $returnCode
            Write-BRAVOLog -Component 'VSS' -Message "Не вдалося видалити VSS-знімок $($VolumeShadow.ShadowId): код $returnCode ($description)" -Level "ERROR"
            return $false
        }
        return $true
    } catch {
        Write-BRAVOLog -Component 'VSS' -Message "Не вдалося видалити VSS-знімок $($VolumeShadow.ShadowId): $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Remove-BRAVOVSSSnapshotSet {
    # Викликається ЛИШЕ у finally після завершення всіх компонентів:
    # видалити знімок після MODEL означало б архівувати BLOG уже з іншого
    # стану системи.
    param([Parameter(Mandatory = $true)][object]$SnapshotSet)

    $allRemoved = $true
    foreach ($volumeShadow in @($SnapshotSet.Volumes)) {
        if (-not (Remove-BRAVOVSSVolumeShadow -VolumeShadow $volumeShadow)) {
            $allRemoved = $false
        }
    }
    if ($allRemoved) {
        Write-BRAVOLog -Component 'VSS' -Message "VSS Snapshot Set видалено: $($SnapshotSet.SnapshotSetId)" -Level "SUCCESS"
    }
    return $allRemoved
}

function Get-BRAVOVSSOwnershipStatePath {
    $programDataRoot = [Environment]::GetFolderPath('CommonApplicationData')
    if ([string]::IsNullOrWhiteSpace($programDataRoot)) {
        throw 'CommonApplicationData path is unavailable for VSS ownership state'
    }
    return Join-Path $programDataRoot 'BRAVO\State\BRAVO_VSS_OWNERSHIP.json'
}

function Save-BRAVOVSSOwnershipState {
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$SnapshotSet,
        [Parameter(Mandatory = $true)][string]$GenerationId
    )

    $shadowIds = @(
        $SnapshotSet.Volumes |
            ForEach-Object { [string]$_.ShadowId } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    if ($shadowIds.Count -eq 0) {
        throw 'VSS Snapshot Set does not expose any ShadowId for ownership tracking'
    }

    $stateDirectory = Split-Path -Path $StatePath -Parent
    if (-not [IO.Directory]::Exists($stateDirectory)) {
        [void][IO.Directory]::CreateDirectory($stateDirectory)
    }
    $state = [ordered]@{
        schemaVersion = 1
        owner = 'BRAVO_ARCHIV'
        hostname = [Environment]::MachineName
        pid = $PID
        processStartTime = $(try { (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToString('o') } catch { $null })
        generationId = $GenerationId
        snapshotSetId = [string]$SnapshotSet.SnapshotSetId
        createdAt = (Get-Date).ToString('o')
        shadowIds = $shadowIds
        linkPaths = @(
            $SnapshotSet.Volumes |
                ForEach-Object { [string]$_.LinkPath } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )
    }
    $temporaryStatePath = Join-Path $stateDirectory ('.BRAVO_VSS_OWNERSHIP_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $backupStatePath = Join-Path $stateDirectory ('.BRAVO_VSS_OWNERSHIP_{0}.bak' -f [guid]::NewGuid().ToString('N'))
    $stateReplaced = $false
    try {
        $json = $state | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($temporaryStatePath, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($StatePath)) {
            # .NET Framework rejects a null backup path even though newer runtimes accept it.
            [IO.File]::Replace($temporaryStatePath, $StatePath, $backupStatePath)
            $stateReplaced = $true
        } else {
            [IO.File]::Move($temporaryStatePath, $StatePath)
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

function Remove-BRAVOOwnedOrphanVSSResources {
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        # Injectable exact-ID deleter for self-test. It must return $true when
        # the shadow is absent or was deleted successfully.
        [scriptblock]$DeleteShadowById,
        [scriptblock]$RemoveLink
    )

    if (-not [IO.File]::Exists($StatePath)) {
        return [pscustomobject]@{ Success = $true; Found = $false; Deleted = 0; Error = $null }
    }
    try {
        $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        if ([int]$state.schemaVersion -ne 1 -or [string]$state.owner -ne 'BRAVO_ARCHIV') {
            throw 'VSS ownership state has an unsupported schema or owner'
        }
        if (-not [string]::Equals([string]$state.hostname, [Environment]::MachineName, [StringComparison]::OrdinalIgnoreCase)) {
            throw "VSS ownership state belongs to another host: $($state.hostname)"
        }

        $shadowIds = @($state.shadowIds)
        if ($shadowIds.Count -eq 0) {
            throw 'VSS ownership state does not contain Shadow IDs'
        }
        $deletedCount = 0
        foreach ($rawShadowId in $shadowIds) {
            $shadowId = [string]$rawShadowId
            [guid]$parsedShadowId = [guid]::Empty
            if (-not [guid]::TryParse($shadowId.Trim('{', '}'), [ref]$parsedShadowId)) {
                throw "invalid BRAVO-owned Shadow ID in state: $shadowId"
            }
            $deleted = if ($null -ne $DeleteShadowById) {
                [bool](& $DeleteShadowById $shadowId)
            } else {
                $escapedShadowId = $shadowId.Replace("'", "''")
                $shadow = Get-WmiObject `
                    -Namespace 'root\cimv2' `
                    -Class 'Win32_ShadowCopy' `
                    -Filter ("ID='{0}'" -f $escapedShadowId) `
                    -ErrorAction Stop |
                    Select-Object -First 1
                if ($null -eq $shadow) {
                    $true
                } else {
                    $deleteResult = $shadow.Delete()
                    $null -eq $deleteResult -or [int]$deleteResult.ReturnValue -eq 0
                }
            }
            if (-not $deleted) {
                throw "failed to delete BRAVO-owned VSS shadow $shadowId"
            }
            $deletedCount++
        }

        $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        foreach ($rawLinkPath in @($state.linkPaths)) {
            $linkPath = [string]$rawLinkPath
            if ([string]::IsNullOrWhiteSpace($linkPath)) { continue }
            $fullLinkPath = [IO.Path]::GetFullPath($linkPath)
            if (-not $fullLinkPath.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
                -not ([IO.Path]::GetFileName($fullLinkPath)).StartsWith('BRAVO_VSS_', [StringComparison]::OrdinalIgnoreCase)) {
                throw "unsafe VSS link path in ownership state: $linkPath"
            }
            if ($null -ne $RemoveLink) {
                & $RemoveLink $fullLinkPath
            } else {
                Remove-BRAVOVSSSnapshotLink -LinkPath $fullLinkPath
            }
        }

        [IO.File]::Delete($StatePath)
        return [pscustomobject]@{ Success = $true; Found = $true; Deleted = $deletedCount; Error = $null }
    } catch {
        # Retain the state file. A later run or an operator can retry exact-ID
        # cleanup; deleting the record would lose the ownership boundary.
        return [pscustomobject]@{ Success = $false; Found = $true; Deleted = 0; Error = $_.Exception.Message }
    }
}

function New-BRAVOBackupGenerationId {
    # Один ідентифікатор generation на весь запуск: усі компоненти однієї
    # копії мають нести його в імені, щоб MODEL, BLOG і BRAVOEXCH одного
    # backup можна було впізнати як комплект, а не збирати за часом файлів.
    param([datetime]$Timestamp = (Get-Date))

    return $Timestamp.ToString("yyyyMMdd_HHmmss")
}

function Get-BRAVOCollisionSafeGenerationId {
    param(
        [Parameter(Mandatory = $true)][string]$BaseGenerationId,
        [Parameter(Mandatory = $true)][object[]]$Archives,
        [Parameter(Mandatory = $true)][string]$ArchivePrefix,
        [string]$HashExtension = ".sha512",
        [int]$MaxAttempts = 1000
    )

    for ($suffix = 0; $suffix -le $MaxAttempts; $suffix++) {
        $candidateGenerationId = if ($suffix -eq 0) {
            $BaseGenerationId
        } else {
            "{0}_{1}" -f $BaseGenerationId, $suffix
        }
        $hasCollision = $false
        foreach ($archive in @($Archives)) {
            $candidateName = $archive.NameTemplate -f $ArchivePrefix, $candidateGenerationId
            $candidatePath = Join-Path ([string]$archive.Destination) $candidateName
            if ((Test-Path -LiteralPath $candidatePath) -or
                (Test-Path -LiteralPath ($candidatePath + $HashExtension))) {
                $hasCollision = $true
                break
            }
        }
        if (-not $hasCollision) {
            return $candidateGenerationId
        }
    }
    throw "Не вдалося підібрати вільний GenerationId для $BaseGenerationId"
}

function Get-BRAVOCollisionSafeArchivePath {
    # Наявний валідний backup недоторканний. Навіть із секундами в імені
    # збіг можливий (повторний запуск у ту саму секунду, ручне копіювання),
    # тому фінальне ім'я підбирається так, щоб не існувало ані .mdz, ані
    # відповідного .sha512: hash попередньої generation теж є частиною
    # набору, який не можна перезаписати.
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$FileName,
        [string]$HashExtension = ".sha512",
        [int]$MaxAttempts = 1000
    )

    $baseName = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $extension = [IO.Path]::GetExtension($FileName)
    for ($suffix = 0; $suffix -le $MaxAttempts; $suffix++) {
        $candidateName = if ($suffix -eq 0) {
            $FileName
        } else {
            "${baseName}_${suffix}${extension}"
        }
        $candidatePath = Join-Path $Directory $candidateName
        if (-not (Test-Path -LiteralPath $candidatePath) -and
            -not (Test-Path -LiteralPath ($candidatePath + $HashExtension))) {
            return $candidatePath
        }
    }
    throw "Не вдалося підібрати вільне ім'я архіву для $FileName у $Directory"
}

function New-BRAVOTemporaryArchivePath {
    # Тимчасовий артефакт у підкаталозі .work поруч із призначенням: той
    # самий том, тому публікація — це перейменування, а не копіювання через
    # мережу чи диск. GUID в імені гарантує, що паралельний або перерваний
    # запуск не зустріне чужий .partial.
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $workDirectory = Join-Path $Directory ".work"
    if (-not (Test-Path -LiteralPath $workDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $workDirectory -Force -ErrorAction Stop)
    }
    $baseName = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $extension = [IO.Path]::GetExtension($FileName)
    $temporaryName = "{0}.{1}.partial{2}" -f $baseName, [guid]::NewGuid().ToString("N"), $extension
    return (Join-Path $workDirectory $temporaryName)
}

function Remove-BRAVOTemporaryArchiveArtifacts {
    # Прибирає ЛИШЕ артефакти поточної temporary generation. Попередні
    # валідні backup недоторканні за будь-якої помилки.
    param([string]$TemporaryArchivePath)

    if ([string]::IsNullOrWhiteSpace($TemporaryArchivePath)) {
        return
    }
    foreach ($artifactPath in @($TemporaryArchivePath, ($TemporaryArchivePath + $hashFileExtension))) {
        if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $artifactPath -Force -ErrorAction Stop
            } catch {
                Write-BRAVOLog -Component 'ARCHIVE' -Message "Не вдалося прибрати тимчасовий артефакт ${artifactPath}: $($_.Exception.Message)" -Level "WARNING"
            }
        }
    }
    $workDirectory = Split-Path -Path $TemporaryArchivePath -Parent
    if ((Split-Path -Path $workDirectory -Leaf) -eq ".work" -and
        (Test-Path -LiteralPath $workDirectory -PathType Container) -and
        @(Get-ChildItem -LiteralPath $workDirectory -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        try {
            Remove-Item -LiteralPath $workDirectory -Force -ErrorAction Stop
        } catch {
            # Порожній .work нікому не заважає — це не привід для помилки.
        }
    }
}

function Remove-BRAVOOrphanedTemporaryArchiveArtifacts {
    # Осиротілі .work\*.partial* — залишки перерваного (крах/force-kill/
    # втрата живлення) минулого прогону: Remove-BRAVOTemporaryArchiveArtifacts
    # вище прибирає такі артефакти лише in-process (finally/catch того
    # самого прогону), тому вбитий процес лишає їх назавжди без цієї функції.
    # НІКОЛИ не виходить за межі .work\ конкретного Destination: MANIFESTS\ і
    # опубліковані .mdz/.sha512 поза дією цієї функції (їх коректність і
    # ретеншн гарантує окремо Remove-BRAVOExpiredBackupGenerations).
    param(
        [Parameter(Mandatory = $true)][object[]]$ArchiveDefinitions,
        [int]$RetentionHours,
        [ref]$RemovedFileCount
    )

    $deletedCount = 0
    $failed = $false
    try {
        $effectiveRetentionHours = if ($RetentionHours -gt 0) { $RetentionHours } else { 48 }
        $cutoff = (Get-Date).AddHours(-$effectiveRetentionHours)
        foreach ($archive in @($ArchiveDefinitions)) {
            $destination = [string]$archive.Destination
            if ([string]::IsNullOrWhiteSpace($destination)) { continue }
            $workDirectory = Join-Path $destination ".work"
            # Свідомо БЕЗ окремого Test-Path gate: .NET Directory.Exists (на
            # якому базується файловий провайдер) за дизайном ковтає
            # UnauthorizedAccessException і повертає $false — pure ACL
            # access-denied на ІСНУЮЧОМУ каталозі принципово нерозрізнюване
            # від "не існує" через Test-Path, з -ErrorAction Stop чи без.
            # Замість цього єдине джерело істини — сам Get-ChildItem: він
            # РЕАЛЬНО кидає (підтверджено емпірично в цій сесії), і catch
            # явно класифікує причину:
            # - ItemNotFoundException/DirectoryNotFoundException — .work
            #   справді відсутній, доброякісний SKIP, не помилка sweep'у;
            # - будь-що інше (UnauthorizedAccessException, IOException,
            #   мережева/провайдерська помилка) — fail-visible: $failed=true.
            try {
                $partialFiles = @(
                    Get-ChildItem -LiteralPath $workDirectory -File -Force `
                        -Filter "*.partial*" -ErrorAction Stop
                )
            } catch [System.Management.Automation.ItemNotFoundException], [System.IO.DirectoryNotFoundException] {
                continue
            } catch {
                $failed = $true
                Write-BRAVOLog -Component 'CLEANUP' -Message "Не вдалося прочитати $workDirectory для orphan-sweep: $($_.Exception.Message)" -Level 'ERROR'
                continue
            }

            foreach ($file in $partialFiles) {
                if ($file.LastWriteTime -ge $cutoff) { continue }
                if (-not (Test-BRAVOBackupArtifactPathSafe -Path $file.FullName -BackupRoot $workDirectory)) {
                    throw "orphan sweep candidate outside .work: $($file.FullName)"
                }
                try {
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    $deletedCount++
                    Write-BRAVOLog -Component 'CLEANUP' -Message "Видалено осиротілий тимчасовий артефакт: $($file.FullName)" -Level 'SUCCESS'
                } catch {
                    $failed = $true
                    Write-BRAVOLog -Component 'CLEANUP' -Message "Не вдалося видалити осиротілий артефакт $($file.FullName): $($_.Exception.Message)" -Level 'ERROR'
                }
            }
            # Так само класифіковано, а не Test-Path: помилка enumeration тут
            # НЕ повинна трактуватися як "каталог порожній" — інакше рішення
            # видалити .work спиралося б на недостовірний .Count. Зникнення
            # каталогу МІЖ enumeration вище і цією перевіркою (конкурентний
            # процес) — доброякісний SKIP (нічого видаляти), не помилка.
            try {
                $remainingItems = @(Get-ChildItem -LiteralPath $workDirectory -Force -ErrorAction Stop)
            } catch [System.Management.Automation.ItemNotFoundException], [System.IO.DirectoryNotFoundException] {
                continue
            } catch {
                $failed = $true
                Write-BRAVOLog -Component 'CLEANUP' -Message "Не вдалося перевірити, чи $workDirectory порожній: $($_.Exception.Message)" -Level 'ERROR'
                continue
            }
            if ($remainingItems.Count -eq 0) {
                try {
                    Remove-Item -LiteralPath $workDirectory -Force -ErrorAction Stop
                } catch {
                    # Порожній .work нікому не заважає — це не привід для помилки.
                }
            }
        }
        if ($null -ne $RemovedFileCount) { $RemovedFileCount.Value = $deletedCount }
        return (-not $failed)
    } catch {
        if ($null -ne $RemovedFileCount) { $RemovedFileCount.Value = $deletedCount }
        Write-BRAVOLog -Component 'CLEANUP' -Message "Orphan temp artifact sweep failed: $($_.Exception.Message)" -Level 'ERROR'
        return $false
    }
}

function New-BRAVOArchiveCreationResult {
    # Створення й перевірка цілісності — ДВІ різні події, а не одна.
    # Раніше New-Archive повертав один bool на обидві, тому "архів створено,
    # але 7z t не пройшов" було неможливо відрізнити від "7-Zip не зміг
    # створити архів" — а це різні причини й різна реакція оператора.
    param(
        [bool]$CreateSuccess = $false,
        [bool]$IntegritySuccess = $false,
        [string]$ArchivePath,
        [Nullable[int]]$ExitCode,
        [string]$ErrorStage,
        [string]$Error,
        # T006: 7z t пройшов лише через legacy BOM-у-паролі fallback.
        [bool]$LegacyBomFallbackUsed = $false
    )

    [pscustomobject]@{
        CreateSuccess = $CreateSuccess
        IntegritySuccess = $IntegritySuccess
        ArchivePath = $ArchivePath
        ExitCode = $ExitCode
        ErrorStage = $ErrorStage
        Error = $Error
        LegacyBomPasswordFallbackUsed = $LegacyBomFallbackUsed
    }
}

function New-Archive {
    param(
        [string]$SourcePath,
        [string]$ArchivePath,
        [string]$ArchiveName,
        [string]$ArcPath,
        [string]$ArcParams,
        # Точний шлях створюваного файла. Використовується atomic-конвеєром:
        # архів спершу створюється як тимчасовий артефакт у .work і лише
        # після всіх перевірок публікується під фінальним іменем.
        [string]$FullArchivePath
    )

    # Причина відмови для консольного РЕЗУЛЬТАТ (Причина:/Інструмент:/Код
    # інструменту:) — деталі передаються через script-scope, бо той самий
    # механізм уже читають BAZA_APP.Sync-Folders та інші виклики.
    $script:lastArchiveToolFailure = $null

    $fullArchivePath = if (-not [string]::IsNullOrWhiteSpace($FullArchivePath)) {
        $FullArchivePath
    } else {
        Join-Path $ArchivePath $ArchiveName
    }
    $displayName = [IO.Path]::GetFileName($fullArchivePath)
    Write-BRAVOLog -Component 'ARCHIVE' -Message "Створення архiву: $displayName"

    $archiveDir = Split-Path $fullArchivePath -Parent
    if (-not (Test-Path $archiveDir)) {
        try {
            New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Каталог створено: $archiveDir" -Level "SUCCESS"
        } catch {
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Помилка при створеннi каталогу: $($_.Exception.Message)" -Level "ERROR"
            return (New-BRAVOArchiveCreationResult -ArchivePath $fullArchivePath -ErrorStage 'CREATE' -Error $_.Exception.Message)
        }
    }

    if (-not (Test-Path $SourcePath)) {
        Write-BRAVOLog -Component 'ARCHIVE' -Message "Джерело не знайдено: $SourcePath" -Level "ERROR"
        return (New-BRAVOArchiveCreationResult -ArchivePath $fullArchivePath -ErrorStage 'CREATE' -Error "джерело не знайдено: $SourcePath")
    }

    try {
        if ([string]::IsNullOrWhiteSpace($script:archivePassword)) {
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Пароль архiву не завантажено з Windows Credential Manager" -Level "ERROR"
            return (New-BRAVOArchiveCreationResult -ArchivePath $fullArchivePath -ErrorStage 'CREATE' -Error "пароль архіву не завантажено")
        }
        if ($script:archivePassword.IndexOfAny([char[]]"`r`n") -ge 0) {
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Пароль архiву не може мiстити символи нового рядка" -Level "ERROR"
            return (New-BRAVOArchiveCreationResult -ArchivePath $fullArchivePath -ErrorStage 'CREATE' -Error "пароль архіву містить символ нового рядка")
        }

        $effectiveArcParams = $ArcParams
        $showSevenZipProgress = $progressSettings.Enabled -and $progressSettings.ShowSevenZipOutput
        $integrityTestTimeoutSeconds = if (
            $null -ne $progressSettings.SevenZipTestTimeoutSeconds
        ) {
            [math]::Max(0, [int]$progressSettings.SevenZipTestTimeoutSeconds)
        } else {
            43200
        }

        # Видалення "застарілого" hash-файла перед створенням архіву тут
        # більше немає й бути не може: до цієї зміни повторний запуск міг
        # прибрати .sha512 попередньої валідної generation, а потім впасти —
        # і залишити backup без підтвердження цілісності. Тепер архів
        # створюється як тимчасовий артефакт і публікується під іменем,
        # якого ще не існує, тому чіпати чужі hash-файли не потрібно взагалі.

        # -p без значення вмикає шифрування і читає пароль зі stdin.
        $arguments = "$effectiveArcParams -p `"$fullArchivePath`" `"$SourcePath`""
        Write-BRAVOLog -Component 'ARCHIVE' -Message "Команда: $ArcPath $arguments (пароль передається через stdin)" -Level "DEBUG"
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $ArcPath
        $processInfo.Arguments = $arguments
        $processInfo.RedirectStandardInput = $true
        # Потоки завжди перенаправляються, щоб технічний вивід 7-Zip не
        # дублював журнал. Власний індикатор показує час і поточний розмір.
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        # Сучасні ОС використовують ReadToEndAsync, Windows 7/.NET 4.0 —
        # сумісний подієвий механізм зі спільного модуля.
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        # Пароль пишеться канонічним BOM-free Write-BRAVOProcessInputText
        # (BRAVO.Compatibility): вона ж закриває stdin (EOF). Прямий
        # StandardInput.WriteLine кодує Console.InputEncoding і під UTF-8
        # кодовою сторінкою вводу консолі (chcp 65001) додавав BOM перед
        # паролем — архів шифрувався паролем "U+FEFF<пароль>".
        Write-BRAVOProcessInputText -Process $process -Text $script:archivePassword
        $sevenZipProgressId = 2
        $progressActivity = "7-Zip — $ArchiveName"
        $archiveStarted = Get-Date
        $archiveTimeoutSeconds = if ($null -ne $progressSettings.SevenZipTimeoutSeconds) {
            [math]::Max(0, [int]$progressSettings.SevenZipTimeoutSeconds)
        } else {
            43200
        }
        $archiveTimedOut = $false

        while (-not $process.WaitForExit(500)) {
            $elapsedSeconds = [math]::Floor(((Get-Date) - $archiveStarted).TotalSeconds)
            if ($showSevenZipProgress) {
                $currentSizeText = "очiкування створення файла"
                if (Test-Path -LiteralPath $fullArchivePath -PathType Leaf) {
                    $currentArchiveLength = (Get-Item -LiteralPath $fullArchivePath).Length
                    $currentSizeText = "поточний розмiр: {0:N1} МБ" -f ($currentArchiveLength / 1MB)
                }
                Show-RunningProgress `
                    -Id $sevenZipProgressId `
                    -Activity $progressActivity `
                    -Status (Format-BRAVORunningDetail -ElapsedSeconds $elapsedSeconds -Detail $currentSizeText) `
                    -PercentComplete -1
            }

            if ($archiveTimeoutSeconds -gt 0 -and $elapsedSeconds -ge $archiveTimeoutSeconds) {
                $archiveTimedOut = $true
                try {
                    $process.Kill()
                } catch {
                    # Процес міг завершитися між перевіркою таймауту та Kill().
                }
                break
            }
        }

        if (-not $process.HasExited -and -not $process.WaitForExit(5000)) {
            throw "7-Zip не завершився протягом 5 секунд після спроби примусового завершення"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $standardOutput = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError
        if ($showSevenZipProgress) {
            Show-RunningProgress -Id $sevenZipProgressId -Activity $progressActivity -Completed
        }
        $lastSevenZipOutput = @($standardOutput -split "\r?\n" | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Last 1)

        if ($archiveTimedOut) {
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Архiвацiю перервано: перевищено таймаут $archiveTimeoutSeconds сек.: $displayName" -Level "ERROR"
            if (Test-Path -LiteralPath $fullArchivePath -PathType Leaf) {
                Remove-Item -LiteralPath $fullArchivePath -Force -ErrorAction SilentlyContinue
                Write-BRAVOLog -Component 'ARCHIVE' -Message "Неповний архiв видалено: $fullArchivePath" -Level "WARNING"
            }
            $script:lastArchiveToolFailure = [pscustomobject]@{
                Tool = '7-Zip'
                ToolExitCodeText = $null
                ReasonText = '7-Zip: перевищено час очікування'
            }
            return (New-BRAVOArchiveCreationResult -ArchivePath $fullArchivePath -ErrorStage 'CREATE' -Error "перевищено таймаут $archiveTimeoutSeconds сек.")
        }

        if ($process.ExitCode -eq 0) {
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Архiв створено; виконується контроль цiлiсностi: $fullArchivePath" -Level "INFO"
            # T006: fallback-успіх пише WARNING (-> код 10 через статистику
            # журналу) і позначається в результаті для одного сповіщення на прогін.
            $legacyBomFallbackArchives = New-Object 'System.Collections.Generic.List[string]'
            if (Test-SevenZipArchiveIntegrity `
                -SevenZipPath $ArcPath `
                -ArchivePath $fullArchivePath `
                -Password $script:archivePassword `
                -TimeoutSeconds $integrityTestTimeoutSeconds `
                -Logger { param($Message, $Level) Write-BRAVOLog -Component 'ARCHIVE' -Message $Message -Level $Level } `
                -LegacyBomFallbackCollector $legacyBomFallbackArchives) {
                Write-BRAVOLog -Component 'ARCHIVE' -Message "Архiв створено та перевiрено: $fullArchivePath" -Level "SUCCESS"
                return (New-BRAVOArchiveCreationResult `
                    -CreateSuccess $true `
                    -IntegritySuccess $true `
                    -ArchivePath $fullArchivePath `
                    -ExitCode 0 `
                    -LegacyBomFallbackUsed ($legacyBomFallbackArchives.Count -gt 0))
            }
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Пошкоджений або неперевiрений архiв не буде опублiковано як backup: $fullArchivePath" -Level "ERROR"
            $script:lastArchiveToolFailure = [pscustomobject]@{
                Tool = '7-Zip'
                ToolExitCodeText = $null
                ReasonText = "7-Zip: архів створено, але не пройшов перевірку цілісності"
            }
            # CreateSuccess=true при IntegritySuccess=false — не суперечність,
            # а найважливіша для діагностики пара станів: 7-Zip завершився
            # кодом 0, але вміст архіву не читається.
            return (New-BRAVOArchiveCreationResult `
                -CreateSuccess $true `
                -IntegritySuccess $false `
                -ArchivePath $fullArchivePath `
                -ExitCode 0 `
                -ErrorStage 'INTEGRITY' `
                -Error "архів не пройшов перевірку 7z t")
        } else {
            $toolExitInfo = Get-BRAVOToolExitCodeDescription -Tool '7-Zip' -ExitCode $process.ExitCode
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Помилка архiвацiї 7-Zip (код: $($process.ExitCode) — $($toolExitInfo.OperatorDescription)): $fullArchivePath" -Level "ERROR"
            Write-SevenZipFailureDiagnostics -Operation "Дiагностика 7-Zip create" -StandardOutput $standardOutput -StandardError $errorOutput
            if ($showSevenZipProgress) {
                if (-not [string]::IsNullOrWhiteSpace($lastSevenZipOutput)) {
                    Write-BRAVOLog -Component 'ARCHIVE' -Message "Останнiй вивiд 7-Zip: $lastSevenZipOutput" -Level "DEBUG"
                }
                if (-not [string]::IsNullOrWhiteSpace($errorOutput)) {
                    Write-BRAVOLog -Component 'ARCHIVE' -Message "Помилка 7-Zip: $errorOutput" -Level "DEBUG"
                }
            } else {
                Write-BRAVOLog -Component 'ARCHIVE' -Message "Деталi: $errorOutput" -Level "DEBUG"
            }
            $script:lastArchiveToolFailure = [pscustomobject]@{
                Tool = '7-Zip'
                ToolExitCodeText = "{0} — {1}" -f $toolExitInfo.ExitCode, $toolExitInfo.OperatorDescription
                ReasonText = "7-Zip код {0} — {1}" -f $toolExitInfo.ExitCode, $toolExitInfo.OperatorDescription
            }
            return (New-BRAVOArchiveCreationResult `
                -ArchivePath $fullArchivePath `
                -ExitCode ([int]$process.ExitCode) `
                -ErrorStage 'CREATE' `
                -Error ("7-Zip код {0} — {1}" -f $toolExitInfo.ExitCode, $toolExitInfo.OperatorDescription))
        }
    } catch {
        Write-BRAVOLog -Component 'ARCHIVE' -Message "Помилка архiвацiї: $($_.Exception.Message)" -Level "ERROR"
        return (New-BRAVOArchiveCreationResult -ArchivePath $fullArchivePath -ErrorStage 'CREATE' -Error $_.Exception.Message)
    }
}

function Write-BRAVOFinalHashFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Hash,
        [Parameter(Mandatory = $true)][string]$ArchiveName
    )

    [IO.File]::WriteAllText(
        $Path,
        ("{0} *{1}" -f $Hash.ToLowerInvariant(), $ArchiveName),
        [Text.Encoding]::GetEncoding($hashFileEncoding)
    )
}

function Invoke-BRAVOComponentBackup {
    # Atomic-конвеєр однієї копії компонента:
    #
    #   тимчасовий архів -> 7-Zip код 0 -> 7z t -> SHA512 -> звірка SHA512
    #   -> публікація .mdz -> публікація .sha512
    #
    # Фінальний артефакт з'являється в каталозі backup ЛИШЕ після того, як
    # усі перевірки пройдені. Доти будь-яка відмова торкається виключно
    # тимчасових файлів поточної generation: попередній валідний backup і
    # його hash лишаються байт-у-байт незмінними.
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$GenerationId,
        [string]$OriginalSourcePath,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory,
        [Parameter(Mandatory = $true)][string]$ArchiveName,
        [Parameter(Mandatory = $true)][string]$ArcPath,
        [string]$ArcParams
    )

    $result = [pscustomobject]@{
        Component = $Component
        GenerationId = $GenerationId
        OriginalSourcePath = $(if ([string]::IsNullOrWhiteSpace($OriginalSourcePath)) { $SourcePath } else { $OriginalSourcePath })
        SnapshotSourcePath = $SourcePath
        TemporaryArchivePath = $null
        ArchivePath = Join-Path $DestinationDirectory $ArchiveName
        HashPath = (Join-Path $DestinationDirectory $ArchiveName) + $hashFileExtension
        CreateSuccess = $false
        IntegritySuccess = $false
        HashSuccess = $false
        ArchiveSize = $null
        SHA512 = $null
        ErrorStage = $null
        Error = $null
        LegacyBomPasswordFallbackUsed = $false
    }
    $finalArchivePath = $null
    $finalHashPath = $null

    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        try {
            [void](New-Item -ItemType Directory -Path $DestinationDirectory -Force -ErrorAction Stop)
        } catch {
            $result.ErrorStage = 'CREATE'
            $result.Error = "не вдалося створити каталог призначення ${DestinationDirectory}: $($_.Exception.Message)"
            Write-BRAVOLog -Component 'ARCHIVE' -Message $result.Error -Level "ERROR"
            return $result
        }
    }

    try {
        $result.TemporaryArchivePath = New-BRAVOTemporaryArchivePath `
            -Directory $DestinationDirectory `
            -FileName $ArchiveName
    } catch {
        $result.ErrorStage = 'CREATE'
        $result.Error = "не вдалося підготувати тимчасовий артефакт: $($_.Exception.Message)"
        Write-BRAVOLog -Component 'ARCHIVE' -Message $result.Error -Level "ERROR"
        return $result
    }

    try {
        if ((Test-Path -LiteralPath $result.ArchivePath) -or
            (Test-Path -LiteralPath $result.HashPath)) {
            $result.ErrorStage = 'PUBLISH'
            $result.Error = "фінальний backup уже існує: $($result.ArchivePath)"
            Write-BRAVOLog -Component 'ARCHIVE' -Message $result.Error -Level "ERROR"
            Remove-BRAVOTemporaryArchiveArtifacts -TemporaryArchivePath $result.TemporaryArchivePath
            return $result
        }

        $creationResult = New-Archive `
            -SourcePath $SourcePath `
            -FullArchivePath $result.TemporaryArchivePath `
            -ArcPath $ArcPath `
            -ArcParams $ArcParams
        $result.CreateSuccess = [bool]$creationResult.CreateSuccess
        $result.IntegritySuccess = [bool]$creationResult.IntegritySuccess
        $result.LegacyBomPasswordFallbackUsed = [bool]$creationResult.LegacyBomPasswordFallbackUsed
        if (-not $result.CreateSuccess -or -not $result.IntegritySuccess) {
            $result.ErrorStage = ([string]$creationResult.ErrorStage).ToUpperInvariant()
            $result.Error = [string]$creationResult.Error
            Remove-BRAVOTemporaryArchiveArtifacts -TemporaryArchivePath $result.TemporaryArchivePath
            return $result
        }

        # dev.19: заголовок секції HASH — САМЕ ТУТ, безпосередньо перед
        # першою дією хешування (New-SHA512Hash нижче), а не в Main ПІСЛЯ
        # завершення всього Invoke-BRAVOComponentBackup (де раніше стояв
        # Write-Log "=== СТВОРЕННЯ ХЕШУ ===" — реальний DEV-LIMS лог
        # показував заголовок ПІСЛЯ вже виконаної роботи). Той самий
        # Write-Log (не окрема реалізація), тому Resolve-BRAVOLogComponentFromHeader
        # так само переводить $script:BRAVOLogComponent на HASH. Друкується
        # незалежно від подальшого успіху/невдачі хешування — заголовок
        # описує ПОЧАТОК цієї роботи, не її результат; сама послідовність
        # create -> hash -> verify -> publish нижче не змінена.
        Write-Log "==="
        Write-Log "=== СТВОРЕННЯ ХЕШУ $Component ==="

        $temporaryHashPath = $result.TemporaryArchivePath + $hashFileExtension
        if (-not (New-SHA512Hash -FilePath $result.TemporaryArchivePath -HashFilePath $temporaryHashPath)) {
            $result.ErrorStage = 'HASH'
            $result.Error = "не вдалося створити SHA512"
            Remove-BRAVOTemporaryArchiveArtifacts -TemporaryArchivePath $result.TemporaryArchivePath
            return $result
        }

        # Звірка створеного hash із фактичним вмістом файла: hash, який
        # ніхто не перевірив, підтверджує лише те, що його записали.
        $hashText = ([IO.File]::ReadAllText($temporaryHashPath)).Trim([char]0xFEFF).Trim()
        if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$') {
            $result.ErrorStage = 'HASH'
            $result.Error = "некоректний формат SHA512-файла"
            Remove-BRAVOTemporaryArchiveArtifacts -TemporaryArchivePath $result.TemporaryArchivePath
            return $result
        }
        $recordedHash = $Matches.Hash.ToUpperInvariant()
        $actualHash = (Get-BRAVOFileHash -Path $result.TemporaryArchivePath -Algorithm SHA512).Hash.ToUpperInvariant()
        if ($recordedHash -cne $actualHash) {
            $result.ErrorStage = 'HASH'
            $result.Error = "SHA512 не збігається з вмістом створеного архіву"
            Write-BRAVOLog -Component 'HASH' -Message "$Component`: $($result.Error)" -Level "ERROR"
            Remove-BRAVOTemporaryArchiveArtifacts -TemporaryArchivePath $result.TemporaryArchivePath
            return $result
        }
        $result.SHA512 = $recordedHash

        # Публікація. Ім'я підбирається так, щоб не існувало ані .mdz, ані
        # .sha512 — наявний валідний набір ніколи не перезаписується.
        $finalArchivePath = Join-Path $DestinationDirectory $ArchiveName
        $finalHashPath = $finalArchivePath + $hashFileExtension
        $finalArchiveName = [IO.Path]::GetFileName($finalArchivePath)
        if ((Test-Path -LiteralPath $finalArchivePath) -or
            (Test-Path -LiteralPath $finalHashPath)) {
            $result.ErrorStage = 'PUBLISH'
            $result.Error = "фінальний backup уже існує: $finalArchivePath"
            Write-BRAVOLog -Component 'ARCHIVE' -Message $result.Error -Level "ERROR"
            Remove-BRAVOTemporaryArchiveArtifacts -TemporaryArchivePath $result.TemporaryArchivePath
            return $result
        }

        Move-Item -LiteralPath $result.TemporaryArchivePath -Destination $finalArchivePath -ErrorAction Stop
        $result.ArchivePath = $finalArchivePath
        # Hash-файл містить ім'я архіву, тому після перейменування він
        # переписується під фінальне ім'я, а не просто переноситься.
        Write-BRAVOFinalHashFile `
            -Path $finalHashPath `
            -Hash $recordedHash `
            -ArchiveName $finalArchiveName
        $result.HashPath = $finalHashPath
        if (Test-Path -LiteralPath $temporaryHashPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryHashPath -Force -ErrorAction SilentlyContinue
        }
        Remove-BRAVOTemporaryArchiveArtifacts -TemporaryArchivePath $result.TemporaryArchivePath
        $result.ArchiveSize = (Get-Item -LiteralPath $finalArchivePath).Length
        $result.HashSuccess = $true
        Write-BRAVOLog -Component 'ARCHIVE' -Message "Backup опубліковано: $finalArchiveName (generation $GenerationId)" -Level "SUCCESS"
        return $result
    } catch {
        $result.HashSuccess = $false
        foreach ($publishedPath in @($finalHashPath, $finalArchivePath)) {
            if (-not [string]::IsNullOrWhiteSpace($publishedPath) -and
                (Test-Path -LiteralPath $publishedPath -PathType Leaf)) {
                Remove-Item -LiteralPath $publishedPath -Force -ErrorAction SilentlyContinue
            }
        }
        $result.ArchivePath = $null
        $result.HashPath = $null
        $result.ArchiveSize = $null
        $result.SHA512 = $null
        $result.ErrorStage = if ([string]::IsNullOrWhiteSpace($result.ErrorStage)) { 'PUBLISH' } else { ([string]$result.ErrorStage).ToUpperInvariant() }
        $result.Error = $_.Exception.Message
        Write-BRAVOLog -Component 'ARCHIVE' -Message "Помилка публікації backup ${Component}: $($_.Exception.Message)" -Level "ERROR"
        Remove-BRAVOTemporaryArchiveArtifacts -TemporaryArchivePath $result.TemporaryArchivePath
        return $result
    }
}

function New-BRAVOBackupGenerationState {
    param(
        [Parameter(Mandatory = $true)][string]$GenerationId,
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [object]$SnapshotSet,
        [object[]]$Components,
        [Parameter(Mandatory = $true)][string]$Status,
        # Склад backup set (Resolve-BRAVOBackupComponentScope): компонент ->
        # Planned / NotInstalled / DisabledByConfig / Missing / Unknown.
        # Записується в manifest як доказ, що пропущений компонент
        # пропущено свідомо, а не загублено. $null — склад не обчислено.
        [System.Collections.IDictionary]$ComponentScope
    )

    [pscustomobject]@{
        GenerationId = $GenerationId
        ComponentScope = $ComponentScope
        StartedAt = $StartedAt
        SnapshotSetId = $(if ($null -ne $SnapshotSet) { [string]$SnapshotSet.SnapshotSetId } else { $null })
        SnapshotCreatedAt = $(if ($null -ne $SnapshotSet) { $SnapshotSet.CreatedAt } else { $null })
        Volumes = @(
            if ($null -ne $SnapshotSet) {
                $SnapshotSet.Volumes | ForEach-Object {
                    [pscustomobject]@{
                        OriginalVolume = [string]$_.VolumeRoot
                        SnapshotDeviceObject = [string]$_.DeviceObject
                        SnapshotId = [string]$_.ShadowId
                        SnapshotSetId = [string]$_.SetId
                    }
                }
            }
        )
        Components = @($Components)
        TransferResults = $null
        HealthResult = $null
        Status = $Status
    }
}

function Write-BRAVOBackupGenerationManifest {
    param(
        [Parameter(Mandatory = $true)][object]$GenerationState,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        return
    }

    $components = [ordered]@{}
    foreach ($component in @($GenerationState.Components)) {
        if ($null -eq $component -or [string]::IsNullOrWhiteSpace([string]$component.Component)) {
            continue
        }
        $sourceVolume = $null
        try {
            $sourceVolume = Get-BRAVOVSSVolumeRoot -Path ([string]$component.OriginalSourcePath)
        } catch {
            # A failed component may not have a resolvable source volume.
        }
        $volumeState = @($GenerationState.Volumes | Where-Object {
            [string]::Equals(
                [string]$_.OriginalVolume,
                [string]$sourceVolume,
                [StringComparison]::OrdinalIgnoreCase
            )
        } | Select-Object -First 1)
        $componentStatus = if (
            [bool]$component.CreateSuccess -and
            [bool]$component.IntegritySuccess -and
            [bool]$component.HashSuccess
        ) { 'COMPLETE' } elseif ([bool]$component.CreateSuccess) { 'INCOMPLETE' } else { 'FAILED' }
        $components[[string]$component.Component] = [ordered]@{
            Name = [string]$component.Component
            Enabled = $true
            SourcePath = [string]$component.OriginalSourcePath
            SourceVolume = $sourceVolume
            SnapshotDevice = $(if ($volumeState.Count -gt 0) { [string]$volumeState[0].SnapshotDeviceObject } else { $null })
            SnapshotSourcePath = [string]$component.SnapshotSourcePath
            ArchivePath = [string]$component.ArchivePath
            HashPath = [string]$component.HashPath
            ArchiveSize = $component.ArchiveSize
            SHA512 = [string]$component.SHA512
            CreateSuccess = [bool]$component.CreateSuccess
            IntegritySuccess = [bool]$component.IntegritySuccess
            HashSuccess = [bool]$component.HashSuccess
            Status = $componentStatus
            ErrorStage = [string]$component.ErrorStage
            Error = [string]$component.Error
        }
    }

    $manifest = [ordered]@{
        generationId = [string]$GenerationState.GenerationId
        createdAt = $GenerationState.StartedAt
        snapshotSetId = $GenerationState.SnapshotSetId
        status = [string]$GenerationState.Status
        startedAt = $GenerationState.StartedAt
        snapshotCreatedAt = $GenerationState.SnapshotCreatedAt
        volumes = @($GenerationState.Volumes)
        components = $components
        transferResults = $GenerationState.TransferResults
        healthResult = $GenerationState.HealthResult
    }
    $componentScopeProperty = $GenerationState.PSObject.Properties['ComponentScope']
    if ($null -ne $componentScopeProperty -and $null -ne $componentScopeProperty.Value) {
        $manifest['componentScope'] = $componentScopeProperty.Value
    }
    # dev.14: generation manifest-и живуть у виділеному MANIFESTS\, а не
    # поруч з архівами — lifecycle прив'язаний до generation (retention
    # видаляє manifest разом з нею), а не до незалежного LogDays. Каталог
    # створюється тут ідемпотентно (Force), бо Write- не повинен залежати
    # від того, чи вже відпрацював Initialize-BRAVOBackupManifestStorage
    # (наприклад одразу після апгрейду, до першого запуску Maintenance).
    $manifestRoot = Get-BRAVOBackupManifestRoot -BackupRoot $BackupRoot
    New-Item -ItemType Directory -Path $manifestRoot -Force -ErrorAction Stop | Out-Null
    $manifestPath = Join-Path $manifestRoot ("BRAVO_BACKUP_{0}.json" -f $GenerationState.GenerationId)
    $temporaryManifestPath = Join-Path $manifestRoot ('.BRAVO_BACKUP_{0}_{1}.tmp' -f $GenerationState.GenerationId, [guid]::NewGuid().ToString('N'))
    $backupManifestPath = Join-Path $manifestRoot ('.BRAVO_BACKUP_{0}_{1}.bak' -f $GenerationState.GenerationId, [guid]::NewGuid().ToString('N'))
    $manifestReplaced = $false
    try {
        [IO.File]::WriteAllText(
            $temporaryManifestPath,
            (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
            (New-Object Text.UTF8Encoding($false))
        )
        if ([IO.File]::Exists($manifestPath)) {
            # Windows PowerShell 5.1/.NET Framework requires a legal backup path.
            [IO.File]::Replace($temporaryManifestPath, $manifestPath, $backupManifestPath)
            $manifestReplaced = $true
        } else {
            [IO.File]::Move($temporaryManifestPath, $manifestPath)
        }
    } finally {
        if ([IO.File]::Exists($temporaryManifestPath)) {
            [IO.File]::Delete($temporaryManifestPath)
        }
        if ($manifestReplaced -and [IO.File]::Exists($backupManifestPath)) {
            Remove-Item -LiteralPath $backupManifestPath -Force -ErrorAction SilentlyContinue
        }
    }
    return $manifestPath
}

function New-SHA512Hash {
    param(
        [string]$FilePath,
        [string]$HashFilePath
    )
    
    if ($script:compatibilityMode) {
        # У режимі сумісності використовуємо тільки сумісну функцію
        return New-SHA512HashLegacy -FilePath $FilePath -HashFilePath $HashFilePath
    } else {
        Write-BRAVOLog -Component 'HASH' -Message "Створення SHA512 хешу: $(Split-Path $FilePath -Leaf)"
        
        if (-not (Test-Path $FilePath)) {
            Write-BRAVOLog -Component 'HASH' -Message "Файл не знайдено: $FilePath" -Level "ERROR"
            return $false
        }
        
        try {
            # Використовуємо стандартний метод, якщо доступний
            if ($script:hasFileHash) {
                $hash = (Get-BRAVOFileHash -Path $FilePath -Algorithm SHA512).Hash.ToLower()
                Write-BRAVOLog -Component 'HASH' -Message "Хеш створено (стандартний метод): $HashFilePath" -Level "SUCCESS"
            } else {
                # Використовуємо сумісний метод
                return New-SHA512HashLegacy -FilePath $FilePath -HashFilePath $HashFilePath
            }
            
            $fileName = (Get-Item $FilePath).Name
            
            # Виправлення для PowerShell 4.0: використовуємо .NET метод замість Out-File з -NoNewline
            [System.IO.File]::WriteAllText($HashFilePath, "${hash} *${fileName}", [System.Text.Encoding]::GetEncoding($hashFileEncoding))
            
            return $true
        } catch {
            Write-BRAVOLog -Component 'HASH' -Message "Помилка створення хешу: $($_.Exception.Message)" -Level "ERROR"
            return $false
        }
    }
}

function New-BRAVOTransferOperationResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [bool]$Enabled
    )

    [pscustomobject]@{
        Name = $Name
        Enabled = $Enabled
        Attempted = $false
        Success = $null
        Degraded = $false
        Total = 0
        Completed = 0
        Remaining = $null
        IncompatibleNames = 0
        Error = $null
    }
}

# =============================================
# ФУНКЦІЇ МЕРЕЖІ ТА SFTP
# =============================================

function Test-SFTPConfig {
    param(
        [switch]$BAZAOnly,
        [switch]$SynchronizationOnly,
        # Не встановлені на цьому сервері компоненти (склад backup set):
        # для них SFTP-каталоги не вимагаються, бо їх не копіюють.
        [string[]]$NotInstalledComponents = @()
    )

    $configurationErrors = @()

    if (-not [string]::IsNullOrWhiteSpace($script:credentialInitializationError)) {
        $configurationErrors += $script:credentialInitializationError
    }
    if ([string]::IsNullOrWhiteSpace($Login)) {
        $configurationErrors += "не завантажено SFTP логiн з Credential Manager"
    }
    if ([string]::IsNullOrWhiteSpace($sftpUrl) -or -not $sftpUrl.StartsWith("sftp://")) {
        $configurationErrors += "не вдалося сформувати SFTP URL із захищених облікових даних"
    }
    if ([string]::IsNullOrWhiteSpace($sftpHostKey)) {
        $configurationErrors += "не встановлено SFTP host key"
    }
    if ([string]::IsNullOrWhiteSpace($winSCPPath) -or -not (Test-Path -Path $winSCPPath -PathType Leaf)) {
        $configurationErrors += "не знайдено WinSCP: $winSCPPath"
    }

    if (-not $BAZAOnly -and -not $SynchronizationOnly -and $componentSettings.SFTP.ArchiveUpload) {
        foreach ($archive in ($archiveDefinitions | Where-Object {
            $_.Enabled -and @($NotInstalledComponents) -notcontains [string]$_.Type
        })) {
            if (-not $sftpDirectories.ContainsKey($archive.Type) -or [string]::IsNullOrWhiteSpace($sftpDirectories[$archive.Type])) {
                $configurationErrors += "не встановлено SFTP каталог для архiву $($archive.Type)"
            }
        }
    }

    if (@($NotInstalledComponents) -notcontains 'BAZA_APP' -and
        ($BAZAOnly -or $componentSettings.Synchronization.BAZA_APP_SFTP)) {
        if (-not $sftpDirectories.ContainsKey("BAZA") -or [string]::IsNullOrWhiteSpace($sftpDirectories.BAZA)) {
            $configurationErrors += "не встановлено SFTP каталог для BAZA"
        }
    }
    if (@($NotInstalledComponents) -notcontains 'BAZA_WWW' -and
        $componentSettings.Synchronization.BAZA_WWW_SFTP) {
        if (-not $sftpDirectories.ContainsKey("BAZAWWW") -or
            [string]::IsNullOrWhiteSpace($sftpDirectories.BAZAWWW)) {
            $configurationErrors += "не встановлено SFTP каталог для BAZA WWW"
        }
    }
    if ($BAZAOnly -or
        $componentSettings.Synchronization.BAZA_APP_SFTP -or
        $componentSettings.Synchronization.BAZA_WWW_SFTP) {
        if ([string]$sftpSynchronizationOptions -match '(?i)(^|\s)-delete(\s|$)') {
            $configurationErrors += "опція -delete заборонена для BAZA: віддалені файли мають зберігатися для відновлення"
        }
    }

    if ($configurationErrors.Count -gt 0) {
        foreach ($configurationError in $configurationErrors) {
            Write-BRAVOLog -Component 'SFTP' -Message "Помилка конфiгурацiї SFTP: $configurationError" -Level "ERROR"
        }
        return $false
    }

    Write-BRAVOLog -Component 'SFTP' -Message "Доступ до SFTP налаштовано коректно" -Level "SUCCESS"
    return $true
}

function Test-SMBConfig {
    $configurationErrors = @()

    if (-not [string]::IsNullOrWhiteSpace($script:smbCredentialInitializationError)) {
        $configurationErrors += $script:smbCredentialInitializationError
    }
    if ($null -eq $script:smbCredential) {
        $configurationErrors += "не завантажено NAS/SMB облікові дані з Credential Manager"
    }
    if ([string]::IsNullOrWhiteSpace([string]$smbSettings.RootPath) -or
        [string]$smbSettings.RootPath -notmatch '^\\\\[^\\]+\\[^\\]+') {
        $configurationErrors += "smbSettings.RootPath повинен бути UNC-шляхом виду \\server\share"
    }
    if ([int]$smbSettings.CopyBufferSizeMB -le 0) {
        $configurationErrors += "smbSettings.CopyBufferSizeMB повинен бути більшим за 0"
    }

    foreach ($archive in @($archiveDefinitions | Where-Object { $_.Enabled })) {
        if ($null -eq $smbSettings.Directories -or
            -not $smbSettings.Directories.ContainsKey($archive.Type) -or
            [string]::IsNullOrWhiteSpace([string]$smbSettings.Directories[$archive.Type])) {
            $configurationErrors += "не встановлено NAS/SMB каталог для архіву $($archive.Type)"
        }
    }

    if ($configurationErrors.Count -gt 0) {
        foreach ($configurationError in $configurationErrors) {
            Write-BRAVOLog -Component 'SMB' -Message "Помилка конфігурації NAS/SMB: $configurationError" -Level "ERROR"
        }
        return $false
    }

    Write-BRAVOLog -Component 'SMB' -Message "Доступ до NAS/SMB налаштовано коректно" -Level "SUCCESS"
    return $true
}

function New-BRAVOSMBDrive {
    $driveName = "BRAVOSMB$PID"
    Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue

    try {
        $drive = New-PSDrive `
            -Name $driveName `
            -PSProvider FileSystem `
            -Root ([string]$smbSettings.RootPath) `
            -Credential $script:smbCredential `
            -Scope Script `
            -ErrorAction Stop
        return $drive
    } catch {
        throw "не вдалося підключитися до '$($smbSettings.RootPath)': $($_.Exception.Message)"
    }
}

function Copy-FileToSMBWithProgress {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$Component
    )

    $sourceStream = $null
    $destinationStream = $null
    try {
        $sourceFile = Get-Item -LiteralPath $SourcePath -ErrorAction Stop
        $bufferSize = [math]::Max(1, [int]$smbSettings.CopyBufferSizeMB) * 1MB
        $buffer = New-Object byte[] $bufferSize
        $sourceStream = New-Object System.IO.FileStream(
            $sourceFile.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read,
            $bufferSize,
            [System.IO.FileOptions]::SequentialScan
        )
        $destinationStream = New-Object System.IO.FileStream(
            $DestinationPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            $bufferSize,
            [System.IO.FileOptions]::SequentialScan
        )

        $copiedBytes = [long]0
        while (($readBytes = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $destinationStream.Write($buffer, 0, $readBytes)
            $copiedBytes += $readBytes
            if ($progressSettings.Enabled -and $sourceFile.Length -gt 0) {
                $percent = [math]::Min(100, [math]::Floor(($copiedBytes * 100.0) / $sourceFile.Length))
                Show-RunningProgress `
                    -Id 4 `
                    -Activity "NAS/SMB — копіювання $Component" `
                    -Status "$($sourceFile.Name): $percent%" `
                    -PercentComplete $percent
            }
        }
        $destinationStream.Flush()
        $destinationStream.Dispose()
        $destinationStream = $null
        [System.IO.File]::SetLastWriteTimeUtc($DestinationPath, $sourceFile.LastWriteTimeUtc)

        $destinationFile = Get-Item -LiteralPath $DestinationPath -ErrorAction Stop
        if ([long]$destinationFile.Length -ne [long]$sourceFile.Length) {
            throw "розмір скопійованого файлу не збігається"
        }
        return $true
    } catch {
        if ($destinationStream) {
            $destinationStream.Dispose()
            $destinationStream = $null
        }
        if ($sourceStream) {
            $sourceStream.Dispose()
            $sourceStream = $null
        }
        Write-BRAVOLog -Component 'SMB' -Message "Помилка копіювання на NAS/SMB: $($_.Exception.Message)" -Level "ERROR"
        if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        }
        return $false
    } finally {
        if ($destinationStream) { $destinationStream.Dispose() }
        if ($sourceStream) { $sourceStream.Dispose() }
        if ($progressSettings.Enabled) {
            Show-RunningProgress -Id 4 -Activity "NAS/SMB — копіювання" -Completed
        }
    }
}

function Copy-ArchivesToSMB {
    param(
        [hashtable]$ArchiveResults,
        [string]$GenerationManifestPath
    )

    $drive = $null
    $copySuccess = 0
    $copyQueue = @()

    foreach ($archive in @($archiveDefinitions | Where-Object { $_.Enabled })) {
        if (-not $ArchiveResults.ContainsKey($archive.Type) -or
            -not $ArchiveResults[$archive.Type].ArchiveSuccess -or
            -not $ArchiveResults[$archive.Type].HashSuccess) {
            continue
        }

        $destinationDirectory = Join-Path `
            ([string]$smbSettings.RootPath) `
            ([string]$smbSettings.Directories[$archive.Type])
        foreach ($sourcePath in @(
            [string]$ArchiveResults[$archive.Type].ArchivePath,
            [string]$ArchiveResults[$archive.Type].HashPath
        )) {
            $copyQueue += [pscustomobject]@{
                SourcePath = $sourcePath
                DestinationDirectory = $destinationDirectory
                Component = [string]$archive.Type
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($GenerationManifestPath) -and
        (Test-Path -LiteralPath $GenerationManifestPath -PathType Leaf)) {
        $copyQueue += [pscustomobject]@{
            SourcePath = $GenerationManifestPath
            DestinationDirectory = Join-Path ([string]$smbSettings.RootPath) 'manifests'
            Component = 'MANIFEST'
        }
    }

    $copyTotal = $copyQueue.Count
    if ($copyTotal -eq 0) {
        return [pscustomobject]@{
            Total = 0
            Success = 0
        }
    }

    try {
        $drive = New-BRAVOSMBDrive
        Write-BRAVOLog -Component 'SMB' -Message "Підключення до NAS/SMB успішне: $($smbSettings.RootPath)" -Level "SUCCESS"

        $copyComponentOrder = @(
            $copyQueue | Where-Object { $_.Component -ne 'MANIFEST' } |
                ForEach-Object { $_.Component } | Select-Object -Unique
        )
        $copyComponentTotal = $copyComponentOrder.Count
        $currentCopyComponent = $null
        foreach ($copyItem in $copyQueue) {
            $copyFileName = Split-Path $copyItem.SourcePath -Leaf
            # Операторський підетап — КОМПОНЕНТ (mdz+sha512 = один visible
            # підетап; MANIFEST — коротка фаза без позиції), як і для
            # архівації та SFTP upload.
            if ($copyItem.Component -ne $currentCopyComponent) {
                $currentCopyComponent = $copyItem.Component
                if ($currentCopyComponent -eq 'MANIFEST') {
                    Show-ScriptProgress -Status "Копіювання manifest на NAS/SMB" -PercentComplete 95
                } else {
                    $copyComponentIndex = ([array]::IndexOf($copyComponentOrder, $currentCopyComponent) + 1)
                    $copyComponentProgress = 92 + [Math]::Floor((($copyComponentIndex - 1) * 3) / [Math]::Max(1, $copyComponentTotal))
                    Show-ScriptProgress `
                        -Status (Format-BRAVOSubstepPhase -Name "Копіювання $currentCopyComponent на NAS/SMB" -Current $copyComponentIndex -Total $copyComponentTotal) `
                        -PercentComplete $copyComponentProgress
                }
            }

            if (-not (Test-Path -LiteralPath $copyItem.DestinationDirectory -PathType Container)) {
                New-Item -ItemType Directory -Path $copyItem.DestinationDirectory -Force -ErrorAction Stop | Out-Null
            }

            $destinationPath = Join-Path $copyItem.DestinationDirectory $copyFileName
            Write-BRAVOLog -Component 'SMB' -Message "Копіювання на NAS/SMB: $copyFileName -> $($copyItem.DestinationDirectory)"
            if (Copy-FileToSMBWithProgress `
                -SourcePath $copyItem.SourcePath `
                -DestinationPath $destinationPath `
                -Component $copyItem.Component) {
                $copySuccess++
                Write-BRAVOLog -Component 'SMB' -Message "Файл успішно скопійовано на NAS/SMB: $copyFileName" -Level "SUCCESS"
            }
        }
    } catch {
        Write-BRAVOLog -Component 'SMB' -Message "Помилка NAS/SMB: $($_.Exception.Message)" -Level "ERROR"
    } finally {
        Show-ItemProgress -Id 14 -Activity "BRAVO_ARCHIV — копіювання на NAS/SMB" -Completed
        if ($drive) {
            Remove-PSDrive -Name $drive.Name -Force -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]@{
        Total = $copyTotal
        Success = $copySuccess
    }
}

# Remove-BRAVOWinSCPSensitiveTemporaryScript / New-BRAVOWinSCPTemporaryScriptPath /
# Clear-BRAVOStaleWinSCPSensitiveTemporaryScripts перенесено в
# modules/BRAVO.ArchiveRuntime/BRAVO.ArchiveRuntime.psm1 (canonical owner,
# спільний для Archive і DataRestore — обидва створюють WinSCP-скрипти з
# SFTP URL, що містить облікові дані). Модуль BRAVO.ArchiveRuntime вже
# імпортується вище — виклики нижче лишаються без змін.

function Test-SFTPConnection {
    param(
        [string]$WinSCPPath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey
    )
    
    Write-BRAVOLog -Component 'SFTP' -Message "Перевiрка пiдключення до actual endpoint ${resolvedSftpHost}:$sftpPort" -Level "DEBUG"
    
    if (-not (Test-Path $WinSCPPath)) {
        Write-BRAVOLog -Component 'SFTP' -Message "WinSCP не знайдено: $WinSCPPath" -Level "ERROR"
        return $false
    }
    
    $testCommand = @"
option batch abort
option confirm off
open $RepositorySFTPUrl -hostkey=$HostKey -timeout=$sftpConnectionTimeoutSeconds
ls
exit
"@
    
    $tempScript = New-BRAVOWinSCPTemporaryScriptPath
    try {
        $testCommand | Out-File -FilePath $tempScript -Encoding $winSCPScriptEncoding -Force
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $WinSCPPath
        $processInfo.Arguments = "/ini=$winSCPIniPath /script=`"$tempScript`""
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $WinSCPPath
        if (-not $winSCPAvailability.Available) {
            Write-BRAVOLog -Component 'SFTP' -Message (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "перевірка SFTP-з'єднання") -Level "ERROR"
            return $false
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $completed = $process.WaitForExit(
            [math]::Max(1, [int]$sftpConnectionTimeoutSeconds + 30) * 1000
        )
        if (-not $completed) {
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            } catch {
                # Процес міг завершитися сам між WaitForExit і Kill().
                # Причина таймауту важливіша за невдале завершення, тому
                # тут DEBUG — але слід лишається: без нього незрозуміло,
                # чи WinSCP досі висить у пам'яті.
                Write-BRAVOLog `
                    -Component 'SFTP' `
                    -Message "Не вдалося завершити процес WinSCP після таймауту: $($_.Exception.Message)" `
                    -Level "DEBUG"
            }
            # Lock звільняється лише після ПІДТВЕРДЖЕНОГО завершення WinSCP:
            # якщо процес досі живий, наступна операція могла б захопити
            # звільнений lock і запустити другий WinSCP паралельно з першим.
            # Тоді lock лишається за цим процесом (звільниться з його
            # завершенням), а прогін іде фатальним шляхом, як до #290.
            $winSCPExited = $false
            try {
                $winSCPExited = [bool]$process.HasExited
            } catch {
                $winSCPExited = $false
            }
            if (-not $winSCPExited) {
                # Lock-потік має жити до завершення ПРОЦЕСУ BRAVO: без
                # довгоживучого посилання FileStream після виходу з функції
                # міг би бути фіналізований GC і звільнити lock, поки WinSCP
                # ще працює (а finally Archive далі запускає WinSCP для
                # вивантаження власного журналу). Тримаємо його в script scope.
                $script:BRAVOWinSCPLockHeldForLiveProcess = $outputCapture
                Write-BRAVOLog `
                    -Component 'SFTP' `
                    -Message "Перевищено таймаут перевірки SFTP-з'єднання, але WinSCP не завершився; BRAVO_WINSCP lock не звільняється" `
                    -Level "ERROR"
                throw "перевищено таймаут перевірки SFTP-з'єднання; WinSCP не завершився"
            }
            # Звільняємо ресурси (зокрема BRAVO_WINSCP lock) ДО виходу:
            # раніше throw оминав Complete-BRAVOProcessOutputCapture, lock
            # лишався захопленим, а викликачі (без try) завершувались
            # exit 90 замість шляху "SFTP недоступний".
            try {
                [void](Complete-BRAVOProcessOutputCapture -Capture $outputCapture)
            } catch {
                Write-BRAVOLog `
                    -Component 'SFTP' `
                    -Message "Не вдалося завершити збір виводу WinSCP після таймауту: $($_.Exception.Message)" `
                    -Level "WARNING"
            }
            Write-BRAVOLog -Component 'SFTP' -Message "Перевищено таймаут перевірки SFTP-з'єднання ($([math]::Max(1, [int]$sftpConnectionTimeoutSeconds + 30)) с); WinSCP завершено" -Level "ERROR"
            return $false
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $output = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError
        
        if ($process.ExitCode -eq 0) {
            Write-BRAVOLog -Component 'SFTP' -Message "Пiдключення до SFTP сервера успiшне" -Level "SUCCESS"
            return $true
        } else {
            Write-BRAVOLog -Component 'SFTP' -Message "Помилка пiдключення до SFTP сервера (код: $($process.ExitCode))" -Level "ERROR"
            Write-BRAVOLog -Component 'SFTP' -Message "Вивiд: $(Get-SanitizedWinSCPDiagnostic -Text $output)" -Level "DEBUG"
            Write-BRAVOLog -Component 'SFTP' -Message "Помилка: $(Get-SanitizedWinSCPDiagnostic -Text $errorOutput)" -Level "DEBUG"
            return $false
        }

    } finally {
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $tempScript
        } catch {
            # Див. пояснення вище: файл містить облікові дані SFTP.
            Write-BRAVOLog `
                -Component 'SFTP' `
                -Message "Не вдалося прибрати тимчасовий WinSCP-скрипт з обліковими даними ($tempScript): $($_.Exception.Message). Видаліть файл вручну." `
                -Level "WARNING"
        }
    }
}

function Get-BAZASFTPComparison {
    param(
        [string]$LocalPath,
        [string]$RemotePath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey
    )

    $components = Get-BRAVOWinSCPDotNetComponents `
        -WinSCPAssemblyPath ([string]$winSCPAssemblyPath) `
        -WinSCPPath ([string]$winSCPPath)
    if ($null -eq $components) {
        return [pscustomobject]@{
            Success = $false
            Error = "не знайдено сумісну пару WinSCPnet.dll та WinSCP.exe"
            PendingFiles = @()
        }
    }

    $session = $null
    try {
        if ($null -eq ("WinSCP.Session" -as [type])) {
            Add-Type -Path $components.AssemblyPath -ErrorAction Stop
        }

        $sessionOptions = New-Object WinSCP.SessionOptions
        $sessionOptions.ParseUrl($RepositorySFTPUrl)
        $sessionOptions.SshHostKeyFingerprint = ([string]$HostKey).Trim().Trim('"')
        $sessionOptions.Timeout = [timespan]::FromSeconds(
            [math]::Max(1, [int]$sftpConnectionTimeoutSeconds)
        )

        $session = New-Object WinSCP.Session
        $session.ExecutablePath = $components.ExecutablePath
        $session.Timeout = [timespan]::FromSeconds(
            [math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)
        )
        $session.Open($sessionOptions)

        $mirror = [string]$sftpSynchronizationOptions -match '(?i)(^|\s)-mirror(\s|$)'
        $criteria = [WinSCP.SynchronizationCriteria]::Time
        $criteriaMatch = [regex]::Match(
            [string]$sftpSynchronizationOptions,
            '(?i)(^|\s)-criteria=(?<Value>[^\s]+)'
        )
        if ($criteriaMatch.Success) {
            $criteria = [WinSCP.SynchronizationCriteria]::None
            foreach ($criterion in $criteriaMatch.Groups["Value"].Value.Split(",")) {
                switch ($criterion.ToLowerInvariant()) {
                    "time" {
                        $criteria = $criteria -bor [WinSCP.SynchronizationCriteria]::Time
                    }
                    "size" {
                        $criteria = $criteria -bor [WinSCP.SynchronizationCriteria]::Size
                    }
                    "checksum" {
                        $criteria = $criteria -bor [WinSCP.SynchronizationCriteria]::Checksum
                    }
                }
            }
        }

        # removeFiles = false: додаткові файли у накопичувальній хмарі
        # не видаляються і не потрапляють до списку очікуваних передач.
        $comparison = @(
            $session.CompareDirectories(
                [WinSCP.SynchronizationMode]::Remote,
                $LocalPath,
                $RemotePath,
                $false,
                $mirror,
                $criteria,
                $null
            )
        )

        $pendingFiles = @()
        foreach ($difference in $comparison) {
            $rawAction = [string]$difference.Action
            if ($rawAction -notin @("UploadNew", "UploadUpdate")) {
                continue
            }

            # $difference.Local — це WinSCP.RemoteFileInfo (навіть для
            # локальної сторони порівняння), а не System.IO.FileInfo:
            # .FullName на ньому немає взагалі, лише .FileName (те саме
            # WinSCP CompareDirectories API, що вже коректно працює через
            # $side.FileName у Health.Runtime.ps1). Під Set-StrictMode
            # звернення до .FullName тут падало ще ДО порівняння з
            # порожнім рядком — реальний випадок: щойно створений на SFTP
            # каталог /baza_app зробив цю гілку вперше досяжною (раніше
            # порівняння саме падало на "каталог не знайдено" раніше, ніж
            # доходило сюди).
            $localItem = $difference.Local
            $localItemPath = if ($null -ne $localItem) {
                $fileNameProperty = $localItem.PSObject.Properties['FileName']
                if ($null -ne $fileNameProperty -and $null -ne $fileNameProperty.Value) {
                    [string]$fileNameProperty.Value
                } else {
                    ""
                }
            } else {
                ""
            }
            if (-not [string]::IsNullOrWhiteSpace($localItemPath) -and
                -not [IO.Path]::IsPathRooted($localItemPath)) {
                $localItemPath = Join-Path -Path $LocalPath -ChildPath $localItemPath
            }
            $pendingFiles += [pscustomobject]@{
                Action = $rawAction
                Reason = if ($rawAction -eq "UploadNew") {
                    "відсутній у хмарі"
                } else {
                    "потребує оновлення у хмарі"
                }
                Path = if (-not [string]::IsNullOrWhiteSpace($localItemPath)) {
                    $localItemPath
                } else {
                    "невідомий локальний шлях"
                }
                IsDirectory = [bool]$difference.IsDirectory
                SizeBytes = if ($null -ne $localItem -and -not $difference.IsDirectory) {
                    [long]$localItem.Length
                } else {
                    $null
                }
            }
        }

        return [pscustomobject]@{
            Success = $true
            Error = $null
            PendingFiles = @($pendingFiles)
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Error = $_.Exception.Message
            PendingFiles = @()
        }
    } finally {
        if ($session) {
            $session.Dispose()
        }
    }
}

function Write-BAZASFTPComparisonAudit {
    param(
        [object]$Comparison,
        [ValidateSet("Before", "After")]
        [string]$Stage,
        [string]$ComponentName = "BAZA",
        [object[]]$IncompatibleIssues = @()
    )

    $stageText = if ($Stage -eq "Before") {
        "ДО СИНХРОНIЗАЦIЇ"
    } else {
        "ПIСЛЯ СИНХРОНIЗАЦIЇ"
    }

    if (-not $Comparison.Success) {
        Write-BRAVOLog -Component 'SFTP' -Message "Аудит $ComponentName $stageText не виконано: $($Comparison.Error)" -Level "WARNING"
        return
    }

    $pendingFiles = @($Comparison.PendingFiles)
    $pendingSplit = Split-BAZAPendingFilesByCompatibility `
        -PendingFiles $pendingFiles `
        -IncompatibleIssues $IncompatibleIssues
    $retryablePendingFiles = @($pendingSplit.Retryable)
    $incompatiblePendingFiles = @($pendingSplit.Incompatible)
    $missingCount = @($pendingFiles | Where-Object { $_.Action -eq "UploadNew" }).Count
    $updateCount = @($pendingFiles | Where-Object { $_.Action -eq "UploadUpdate" }).Count
    if ($pendingFiles.Count -eq 0) {
        Write-BRAVOLog -Component 'SFTP' -Message "Аудит $ComponentName ${stageText}: усi локальнi файли синхронiзованi" -Level "SUCCESS"
        return
    }

    $summaryLevel = if ($Stage -eq "Before") {
        "INFO"
    } elseif ($retryablePendingFiles.Count -eq 0 -and $incompatiblePendingFiles.Count -gt 0) {
        "WARNING"
    } else {
        "ERROR"
    }
    Write-BRAVOLog -Component 'SFTP' -Message "Аудит $ComponentName ${stageText}: очiкують передачi: $($pendingFiles.Count) (вiдсутнi у хмарi: $missingCount; потребують оновлення: $updateCount; несумісні імена: $($incompatiblePendingFiles.Count))" -Level $summaryLevel
    foreach ($pendingFile in $retryablePendingFiles) {
        $itemType = if ($pendingFile.IsDirectory) { "КАТАЛОГ" } else { "ФАЙЛ" }
        $sizeText = if ($null -ne $pendingFile.SizeBytes) {
            "; байт: $($pendingFile.SizeBytes)"
        } else {
            ""
        }
        # -FileOnly не існує на Write-BRAVOLog — це параметр локального шиму
        # Write-Log (транслює його в -NoConsole). Реальний випадок: 374
        # елементи в аудиті BAZA вперше зробили цей цикл досяжним і
        # негайно провалили весь runtime помилкою "A parameter cannot be
        # found that matches parameter name 'FileOnly'" — раніше сюди
        # взагалі не доходило через попередні два краші того самого аудиту.
        Write-BRAVOLog -Component 'SFTP' -Message "AUDIT $ComponentName $stageText [$itemType] [$($pendingFile.Reason)] $($pendingFile.Path)$sizeText" -Level $summaryLevel -NoConsole
    }
    foreach ($pendingFile in $incompatiblePendingFiles) {
        Write-BRAVOLog -Component 'SFTP' -Message "AUDIT $ComponentName $stageText [ПРОПУЩЕНО: НЕСУМІСНЕ ІМ'Я] $($pendingFile.Path)" -Level "WARNING" -NoConsole
    }
}

function Test-BAZAPathBlockedByIncompatibleName {
    param(
        [string]$CandidatePath,
        [object[]]$IncompatibleIssues = @()
    )

    if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
        return $false
    }
    try {
        $candidateFullPath = [IO.Path]::GetFullPath($CandidatePath).TrimEnd([char[]]"\\/")
    } catch {
        return $false
    }

    foreach ($issue in @($IncompatibleIssues)) {
        try {
            $issueFullPath = [IO.Path]::GetFullPath([string]$issue.Path).TrimEnd([char[]]"\\/")
        } catch {
            continue
        }
        if ($candidateFullPath.Equals($issueFullPath, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        if ([bool]$issue.IsDirectory) {
            $issuePrefix = $issueFullPath + [IO.Path]::DirectorySeparatorChar
            if ($candidateFullPath.StartsWith($issuePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Split-BAZAPendingFilesByCompatibility {
    param(
        [object[]]$PendingFiles = @(),
        [object[]]$IncompatibleIssues = @()
    )

    $retryable = @()
    $incompatible = @()
    foreach ($pendingFile in @($PendingFiles)) {
        if (Test-BAZAPathBlockedByIncompatibleName `
            -CandidatePath ([string]$pendingFile.Path) `
            -IncompatibleIssues $IncompatibleIssues) {
            $incompatible += $pendingFile
        } else {
            $retryable += $pendingFile
        }
    }
    return [pscustomobject]@{
        Retryable = @($retryable)
        Incompatible = @($incompatible)
    }
}

function Get-BAZASynchronizationOutcome {
    param(
        [int]$WinSCPExitCode,
        [object]$ComparisonBefore,
        [object]$ComparisonAfter,
        [object[]]$IncompatibleIssues = @()
    )

    $verificationSucceeded = $null -ne $ComparisonAfter -and $ComparisonAfter.Success
    $afterSplit = if ($verificationSucceeded) {
        Split-BAZAPendingFilesByCompatibility `
            -PendingFiles @($ComparisonAfter.PendingFiles) `
            -IncompatibleIssues $IncompatibleIssues
    } else {
        $null
    }
    $beforeSplit = if ($null -ne $ComparisonBefore -and $ComparisonBefore.Success) {
        Split-BAZAPendingFilesByCompatibility `
            -PendingFiles @($ComparisonBefore.PendingFiles) `
            -IncompatibleIssues $IncompatibleIssues
    } else {
        $null
    }
    $remainingCount = if ($verificationSucceeded) {
        @($ComparisonAfter.PendingFiles).Count
    } else {
        $null
    }
    $retryableRemainingCount = if ($verificationSucceeded) {
        @($afterSplit.Retryable).Count
    } else {
        $null
    }
    $incompatibleRemainingCount = if ($verificationSucceeded) {
        @($afterSplit.Incompatible).Count
    } else {
        $null
    }
    $beforeCount = if ($null -ne $ComparisonBefore -and $ComparisonBefore.Success) {
        @($ComparisonBefore.PendingFiles).Count
    } else {
        $null
    }
    $completedCount = if ($null -ne $beforeSplit -and $null -ne $afterSplit) {
        [math]::Max(0, @($beforeSplit.Retryable).Count - @($afterSplit.Retryable).Count)
    } else {
        $null
    }

    return [pscustomobject]@{
        VerificationSucceeded = $verificationSucceeded
        ExitCode = $WinSCPExitCode
        BeforeCount = $beforeCount
        CompletedCount = $completedCount
        RemainingCount = $remainingCount
        RetryableRemainingCount = $retryableRemainingCount
        IncompatibleRemainingCount = $incompatibleRemainingCount
        IsComplete = (
            $WinSCPExitCode -eq 0 -and
            $verificationSucceeded -and
            $retryableRemainingCount -eq 0
        )
        IsDegraded = (
            $WinSCPExitCode -eq 0 -and
            $verificationSucceeded -and
            $retryableRemainingCount -eq 0 -and
            $incompatibleRemainingCount -gt 0
        )
        IsPartial = (
            $verificationSucceeded -and
            $retryableRemainingCount -gt 0
        )
    }
}

function Get-BAZARemoteNameCompatibilityIssues {
    param(
        [string]$LocalPath,
        [int]$MaximumFileUtf8Bytes = 255,
        [int]$MaximumDirectoryUtf8Bytes = 255
    )

    $issues = @()
    try {
        $localItems = @(
            Get-ChildItem `
                -LiteralPath $LocalPath `
                -Recurse `
                -Force `
                -ErrorAction Stop
        )
        foreach ($localItem in $localItems) {
            $utf8ByteCount = [System.Text.Encoding]::UTF8.GetByteCount($localItem.Name)
            $maximumUtf8Bytes = if ($localItem.PSIsContainer) {
                $MaximumDirectoryUtf8Bytes
            } else {
                $MaximumFileUtf8Bytes
            }
            if ($utf8ByteCount -le $maximumUtf8Bytes) {
                continue
            }

            $issues += [pscustomobject]@{
                Path = $localItem.FullName
                Name = $localItem.Name
                IsDirectory = [bool]$localItem.PSIsContainer
                CharacterCount = $localItem.Name.Length
                Utf8ByteCount = $utf8ByteCount
                MaximumUtf8Bytes = $maximumUtf8Bytes
                Reason = "ім'я довше за допустимі $maximumUtf8Bytes байт у UTF-8"
            }
        }

        return [pscustomobject]@{
            Success = $true
            Error = $null
            Issues = @($issues)
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Error = $_.Exception.Message
            Issues = @()
        }
    }
}

function Write-BAZARemoteNameCompatibilityAudit {
    param(
        [object]$CompatibilityResult,
        [string]$ComponentName = "BAZA"
    )

    if (-not $CompatibilityResult.Success) {
        Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося перевiрити сумiснiсть iмен $ComponentName з SFTP: $($CompatibilityResult.Error)" -Level "WARNING"
        return
    }

    $issues = @($CompatibilityResult.Issues)
    if ($issues.Count -eq 0) {
        Write-BRAVOLog -Component 'SFTP' -Message "Перевiрка iмен ${ComponentName}: несумiсних iз SFTP iмен не знайдено" -Level "SUCCESS"
        return
    }

    Write-BRAVOLog -Component 'SFTP' -Message "Перевiрка iмен ${ComponentName}: знайдено несумiсних iмен: $($issues.Count). Цi об'єкти буде пропущено; потрiбне скорочення локальних iмен" -Level "ERROR"
    foreach ($issue in $issues) {
        $itemType = if ($issue.IsDirectory) { "КАТАЛОГ" } else { "ФАЙЛ" }
        Write-BRAVOLog -Component 'SFTP' -Message "AUDIT $ComponentName НЕСУМIСНЕ IМ'Я [$itemType] [довжина: $($issue.CharacterCount) символів; $($issue.Utf8ByteCount)/$($issue.MaximumUtf8Bytes) UTF-8 байт] $($issue.Path)" -Level "ERROR" -NoConsole
    }

    # Notification failures must never stop the actual SFTP synchronization.
    try {
        Send-BAZAIncompatibleNameAlert -Issues $issues -ComponentName $ComponentName
    } catch {
        Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося підготувати сповіщення про несумісні імена ${ComponentName}: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Send-BRAVOArchiveLegacyBomFallbackAlert {
    # T006 (рішення власника 2026-09-29): РІВНО одне WARNING-сповіщення на
    # прогін, якщо хоча б один опублікований архів пройшов 7z t лише через
    # legacy BOM-у-паролі fallback. Перелік і підказка — канонічні
    # (Get-BRAVOLegacyBomFallbackNotificationLines, BRAVO.ArchiveHelpers);
    # маршрут/доставка — канонічна Send-BRAVONotification. Збій доставки
    # лише логується і не змінює результат backup.
    param([Parameter(Mandatory = $true)][hashtable]$Results)

    $archiveNames = @(
        $Results.Values |
            Where-Object {
                $_ -is [hashtable] -and
                $_.ContainsKey('LegacyBomPasswordFallbackUsed') -and
                [bool]$_.LegacyBomPasswordFallbackUsed -and
                -not [string]::IsNullOrWhiteSpace([string]$_.ArchivePath)
            } |
            ForEach-Object { Split-Path -Path ([string]$_.ArchivePath) -Leaf } |
            Sort-Object -Unique
    )
    if ($archiveNames.Count -eq 0) {
        return
    }
    if ($NoSlack -or $script:notificationMode -eq 'none') {
        Write-BRAVOLog -Component 'ARCHIVE' -Message 'Сповіщення про legacy BOM-пароль архівів вимкнено параметрами запуску або конфігурацією' -Level 'INFO'
        return
    }
    try {
        $archiveBuildIdText = if ([string]::IsNullOrWhiteSpace([string]$ScriptBuildId)) {
            'невідома'
        } else {
            [string]$ScriptBuildId
        }
        $message = New-BRAVOOperatorNotificationMessage `
            -Severity 'WARNING' `
            -Operation 'BRAVO ARCHIVE — АРХІВИ З LEGACY BOM-ПАРОЛЕМ' `
            -ActionText 'створити нові резервні копії перелічених даних поточною версією BRAVO.' `
            -InstitutionName ([string]$backupMonitoring.InstitutionName) `
            -InstitutionCode ([string]$backupMonitoring.InstitutionCode) `
            -HostInformation (Get-HostInformation) `
            -ResultLines @(Get-BRAVOLegacyBomFallbackNotificationLines -ArchiveNames $archiveNames) `
            -Timestamp (Get-Date) `
            -ProductName 'BRAVO Archive' `
            -Version ([string]$global:ScriptVersion) `
            -BuildId $archiveBuildIdText `
            -LogPath ([string]$script:logFile) `
            -LogLabel 'Журнал'
        [void](Send-BRAVONotification `
            -Severity 'WARNING' `
            -Message $message `
            -Provider $script:notificationProvider `
            -NotificationMode $script:notificationMode `
            -RoutingTable $backupMonitoring.NotificationRouting `
            -CredentialTargets $backupMonitoring.NotificationCredentialTargets `
            -TimeoutSeconds $script:notificationRequestTimeoutSeconds)
        Write-BRAVOLog -Component 'ARCHIVE' -Message "Сповіщення про $($archiveNames.Count) архів(и) з legacy BOM-паролем відправлено у $($script:notificationProviderDisplayName)" -Level 'INFO'
    } catch {
        Write-BRAVOLog -Component 'ARCHIVE' -Message "Не вдалося відправити сповіщення про архіви з legacy BOM-паролем: $(Protect-BRAVOLogSecret -Text $_.Exception.Message)" -Level 'WARNING'
    }
}

function Send-BAZAIncompatibleNameAlert {
    param(
        [object[]]$Issues,
        [string]$ComponentName = "BAZA"
    )

    # Гейт нотифікації нижче раніше завершував функцію через `return` ДО
    # Operations-події внизу (той самий review finding, що для
    # Send-ToolIntegrityAlert/Send-BRAVOArchiveFreeSpaceAlert). Замінено на
    # $notificationWebhookUrl = $null як сигнал "сповіщення пропущено", щоб
    # решта функції (побудова повідомлення й Operations-подія) виконувалась
    # незалежно від стану нотифікаційного гейту.
    $notificationWebhookUrl = $null
    if ($NoSlack -or $script:notificationMode -eq "none") {
        Write-BRAVOLog -Component 'SFTP' -Message "Сповіщення про несумісні імена $ComponentName вимкнено параметрами запуску або конфігурацією" -Level "INFO"
    } else {
        $notificationRoute = Resolve-BRAVONotificationRoute `
            -Severity "WARNING" `
            -NotificationMode $script:notificationMode `
            -RoutingTable $backupMonitoring.NotificationRouting
        if ($notificationRoute -eq "none") {
            Write-BRAVOLog -Component 'SFTP' -Message "Сповіщення про несумісні імена $ComponentName вимкнено параметрами запуску або конфігурацією" -Level "INFO"
        } else {
            try {
                $notificationWebhookUrl = Resolve-BRAVONotificationEndpoint `
                    -Provider $script:notificationProvider `
                    -Route $notificationRoute `
                    -CredentialTargets $backupMonitoring.NotificationCredentialTargets
            } catch {
                Write-BRAVOLog -Component 'SFTP' -Message (
                    "Сповіщення про несумісні імена $ComponentName не відправлено: " +
                    "webhook для $($script:notificationProviderDisplayName) не налаштовано"
                ) -Level "INFO"
            }
        }
    }

    # Review finding (thread 20, rendering cost when the channel is off):
    # гейт нотифікації тепер стоїть ПЕРЕД побудовою повідомлення, а не
    # після неї — так само, як у Send-ToolIntegrityAlert і
    # Send-BRAVOArchiveFreeSpaceAlert. Раніше заміна ранніх `return` на
    # $notificationWebhookUrl = $null лишила всю побудову безумовною, тож
    # при -NoSlack / NotificationMode=none / відсутньому маршруті чи
    # webhook (і навіть при ВИМКНЕНІЙ Operations-звітності) виконувався
    # Get-HostInformation, який без теплого кешу робить зовнішній
    # публічний IP-запит із 5-секундним таймаутом — Archive платив
    # затримкою й робив несподіваний зовнішній запит виключно щоб
    # сформувати текст, який ніколи не буде надіслано. Operations-подія
    # нижче лишається ПОЗА цим гейтом (їй потрібні лише $Issues).
    if ($notificationWebhookUrl) {
        $examples = @(
            $Issues |
                Select-Object -First 3 |
                ForEach-Object {
                    $displayName = [string]$_.Name
                    if ($displayName.Length -gt 120) {
                        $displayName = $displayName.Substring(0, 117) + "..."
                    }

                    # The health formatter lives in a different function scope.
                    # Keep this standalone mode self-contained and only apply
                    # Markdown escaping when the selected provider is Discord.
                    if ($script:notificationProvider -eq "discord") {
                        $displayName = $displayName.Replace("\", "\\")
                        $displayName = $displayName.Replace("*", "\*")
                        $displayName = $displayName.Replace("_", "\_")
                        $displayName = $displayName.Replace("~", "\~")
                        $displayName = $displayName.Replace("|", "\|")
                        $displayName = $displayName.Replace(">", "\>")
                    }
                    $overflowBytes = [int]$_.Utf8ByteCount - [int]$_.MaximumUtf8Bytes
                    ":x: $($_.Utf8ByteCount)/$($_.MaximumUtf8Bytes) байт · перевищення +$overflowBytes байт`n$displayName"
                }
        )
        $exampleLines = New-Object System.Collections.Generic.List[string]
        if ($examples.Count -gt 0) {
            $exampleLines.Add("Приклади:")
            $exampleLines.Add("")
            foreach ($example in $examples) {
                $exampleLines.Add([string]$example)
                $exampleLines.Add("")
            }
        }
        $hostInformation = Get-HostInformation
        $notificationTime = Get-Date
        $archiveVersionText = [string]$global:ScriptVersion
        $archiveBuildIdText = if ([string]::IsNullOrWhiteSpace([string]$ScriptBuildId)) {
            "невідома"
        } else {
            [string]$ScriptBuildId
        }
        $logFilePath = if (-not [string]::IsNullOrWhiteSpace([string]$script:logFile)) {
            [string]$script:logFile
        } else {
            "журнал BRAVO_ARCHIV"
        }
        $fileCountText = Format-BRAVOUkrainianCount -Count $Issues.Count -One "файл" -Few "файли" -Many "файлів"
        $fileCountHeaderText = $fileCountText.ToUpperInvariant()
        $resultLines = @(
            "Причина:",
            "Назви $fileCountText перевищують допустиму довжину для передачі через SFTP.",
            "Проблемні файли пропущено; інші файли синхронізуються штатно.",
            "",
            "Ліміт: $($Issues[0].MaximumUtf8Bytes) UTF-8 байт",
            "Проблемних файлів: $($Issues.Count)"
        ) + $exampleLines.ToArray()
        $message = New-BRAVOOperatorNotificationMessage `
            -Severity "WARNING" `
            -Operation "$ComponentName — $fileCountHeaderText НЕ СИНХРОНІЗОВАНО" `
            -ActionText "скоротити назви зазначених файлів." `
            -InstitutionName ([string]$backupMonitoring.InstitutionName) `
            -InstitutionCode ([string]$backupMonitoring.InstitutionCode) `
            -HostInformation $hostInformation `
            -ResultLines $resultLines `
            -Timestamp $notificationTime `
            -ProductName "BRAVO Archive" `
            -Version $archiveVersionText `
            -BuildId $archiveBuildIdText `
            -LogPath $logFilePath `
            -LogLabel "Повний перелік"

            try {
                $outboundMessages = ConvertTo-BRAVONotificationPayloadText -Provider $script:notificationProvider -Message $message
                Send-BRAVONotificationChunks `
                    -Provider $script:notificationProvider `
                    -WebhookUrl $notificationWebhookUrl `
                    -MessageChunks $outboundMessages `
                    -TimeoutSeconds $script:notificationRequestTimeoutSeconds
                $chunkText = if ($outboundMessages.Count -gt 1) {
                    " частинами: $($outboundMessages.Count)"
                } else {
                    ""
                }
                Write-BRAVOLog -Component 'SFTP' -Message "Сповіщення про $($Issues.Count) несумісних імен $ComponentName відправлено у $($script:notificationProviderDisplayName)$chunkText" -Level "SUCCESS"
            } catch {
                Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося відправити сповіщення про несумісні імена $ComponentName у $($script:notificationProviderDisplayName): $(Protect-BRAVOLogSecret -Text $_.Exception.Message)" -Level "ERROR"
            }
    }

    if ($null -ne $operationsReportingSettings) {
        try {
            Send-BRAVOOperationsEvent `
                -OperationsReportingSettings $operationsReportingSettings `
                -CredentialTargets $credentialSettings.Targets `
                -InstitutionCode ([string]$backupMonitoring.InstitutionCode) `
                -Category 'backup' -Severity 'WARNING' `
                -Component $ComponentName `
                -Message "$($Issues.Count) файлів не синхронізовано через несумісні для SFTP імена" `
                -Details @{ maximumUtf8Bytes = $Issues[0].MaximumUtf8Bytes; issueCount = $Issues.Count }
        } catch {
            Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося відправити подію в Operations: $(Protect-BRAVOLogSecret -Text $_.Exception.Message)" -Level "WARNING"
        }
    }
}

# Чиста (без побічних ефектів) функція: розгортає кожен запитаний
# нормалізований шлях (напр. "/logs/archiv") у ВСІ його батьківські
# сегменти ("/logs", "/logs/archiv"), дедуплікує та впорядковує за
# глибиною (спершу коротші), потім за алфавітом — щоб /logs завжди йшов
# у скрипті WinSCP раніше за /logs/archiv. WinSCP `mkdir` НЕ рекурсивний
# (на відміну від `mkdir -p`): на чистому SFTP-акаунті без жодного з
# батьківських сегментів "mkdir /logs/archiv" провалюється, бо /logs ще
# не існує. "option batch continue" уже й так робить mkdir ідемпотентним
# для сегментів, які існують — ця функція лише гарантує правильний
# порядок (P2-1, PR #136 review).
function Get-BRAVOSFTPOrderedDirectorySegments {
    param([string[]]$Directories)

    $segmentDirectories = New-Object System.Collections.Generic.List[string]
    $seenSegments = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($directory in $Directories) {
        if ([string]::IsNullOrWhiteSpace($directory)) { continue }
        $parts = $directory.Trim('/') -split '/'
        $accumulated = ''
        foreach ($part in $parts) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            $accumulated = "$accumulated/$part"
            if ($seenSegments.Add($accumulated)) {
                [void]$segmentDirectories.Add($accumulated)
            }
        }
    }
    # .ToArray(), а не @($segmentDirectories) напряму — той самий PS 5.1
    # гейт, що Get-BRAVOFileLockingProcesses/Get-BRAVOEmptyLogDateDirectories:
    # @() напряму на System.Collections.Generic.List[T] кидає "Argument
    # types do not match" (емпірично відтворено, версія 5.1.26100.9168).
    # Тут безпечно, бо результат одразу проходить через Sort-Object
    # (пайплайн), а НЕ обгортається в @() напряму навколо самого List[T].
    return $segmentDirectories |
        Sort-Object -Property @{ Expression = { ($_ -split '/').Count } }, @{ Expression = { $_ } }
}

function Initialize-BRAVOSFTPRemoteDirectories {
    # Створює відсутні кореневі каталоги на SFTP (model/blog/bravoexch/
    # baza_app/...) одним пакетним викликом WinSCP, перед тим як
    # Send-FileViaWinSCP/Sync-FolderToSFTP спробують передати щось
    # усередину них. Реальний випадок: WinSCP явно повідомляв "Error
    # listing directory '/baza_app'. No such file or directory" — сам
    # каталог просто ніколи не створювався на сервері.
    #
    # option batch continue навмисно: mkdir на вже наявному каталозі
    # повертає помилку (а після першого успішного запуску каталоги вже
    # існують щоразу), і Sync-FolderToSFTP окремо документує, що це
    # звело б підсумковий $process.ExitCode до 1 навіть у режимі continue.
    # Тому цей виклик — best-effort і НІКОЛИ не є джерелом істини про
    # успіх/невдачу: реальний результат передачі перевіряють окремі
    # виклики Send-FileViaWinSCP/Sync-FolderToSFTP після нього, які на
    # це не зважають.
    param(
        [string]$WinSCPPath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey,
        [string[]]$RemoteDirectories
    )

    $normalizedDirectories = @(
        $RemoteDirectories |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { "/" + $_.Replace("\", "/").Trim("/") } |
            Where-Object { $_ -ne "/" } |
            Select-Object -Unique
    )
    if ($normalizedDirectories.Count -eq 0) {
        return
    }
    if (-not (Test-Path -Path $WinSCPPath -PathType Leaf)) {
        Write-BRAVOLog -Component 'SFTP' -Message "WinSCP не знайдено: $WinSCPPath" -Level "WARNING"
        return
    }

    # WinSCP `mkdir` НЕ рекурсивний (на відміну від `mkdir -p`) — розгортання
    # у батьківські сегменти й впорядкування за глибиною винесене в окрему
    # чисту функцію нижче (Get-BRAVOSFTPOrderedDirectorySegments), щоб її
    # можна було детерміновано перевірити регресійним тестом без реального
    # WinSCP/SFTP (P2-1, PR #136 review).
    $orderedDirectories = @(Get-BRAVOSFTPOrderedDirectorySegments -Directories $normalizedDirectories)

    Write-BRAVOLog -Component 'SFTP' -Message "Перевiрка/створення потрiбних каталогiв на SFTP: $($orderedDirectories -join ', ')"

    $mkdirCommands = ($orderedDirectories | ForEach-Object { "mkdir `"$_`"" }) -join [Environment]::NewLine
    $winscpCommand = @"
option batch continue
option confirm off
open $RepositorySFTPUrl -hostkey=$HostKey -timeout=$sftpConnectionTimeoutSeconds
$mkdirCommands
exit
"@

    $tempScript = New-BRAVOWinSCPTemporaryScriptPath
    try {
        $winscpCommand | Out-File -FilePath $tempScript -Encoding $winSCPScriptEncoding -Force

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $WinSCPPath
        $processInfo.Arguments = "/ini=$winSCPIniPath /script=`"$tempScript`""
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $WinSCPPath
        if (-not $winSCPAvailability.Available) {
            Write-BRAVOLog -Component 'SFTP' -Message (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "створення каталогiв на SFTP") -Level "WARNING"
            return
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $operationTimeoutSeconds = [math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)
        if (-not $process.WaitForExit($operationTimeoutSeconds * 1000)) {
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            } catch {
                Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося завершити WinSCP пiсля таймауту створення каталогiв: $($_.Exception.Message)" -Level "WARNING"
            }
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $safeOutput = Get-SanitizedWinSCPDiagnostic -Text $capturedOutput.StandardOutput
        if (-not [string]::IsNullOrWhiteSpace($safeOutput)) {
            Write-BRAVOLog -Component 'SFTP' -Message "WinSCP вивiд (створення каталогiв): $safeOutput" -Level "DEBUG"
        }
    } catch {
        Write-BRAVOLog -Component 'SFTP' -Message "Помилка пiд час створення каталогiв на SFTP: $($_.Exception.Message)" -Level "WARNING"
    } finally {
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $tempScript
        } catch {
            Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося видалити тимчасовий скрипт: $($_.Exception.Message)" -Level "WARNING"
        }
    }
}

function Send-FileViaWinSCP {
    param(
        [string]$WinSCPPath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey,
        [string]$LocalFilePath,
        [string]$RemoteDirectory
    )
    
    Write-BRAVOLog -Component 'SFTP' -Message "Завантаження через WinSCP: $(Split-Path $LocalFilePath -Leaf) -> $RemoteDirectory"
    
    if (-not (Test-Path $LocalFilePath)) {
        Write-BRAVOLog -Component 'SFTP' -Message "Файл не знайдено: $LocalFilePath" -Level "ERROR"
        return $false
    }
    
    if (-not (Test-Path $WinSCPPath)) {
        Write-BRAVOLog -Component 'SFTP' -Message "WinSCP не знайдено: $WinSCPPath" -Level "ERROR"
        return $false
    }
    
    # Створюємо тимчасовий скрипт для WinSCP
    $winscpCommand = @"
option batch abort
option confirm off
open $RepositorySFTPUrl -hostkey=$HostKey -timeout=$sftpConnectionTimeoutSeconds
cd /$RemoteDirectory
put "$LocalFilePath"
exit
"@
    
    $tempScript = New-BRAVOWinSCPTemporaryScriptPath
    $showWinSCPProgress = $progressSettings.Enabled -and $progressSettings.ShowWinSCPOutput
    $transferFileName = Split-Path $LocalFilePath -Leaf
    $transferActivity = "WinSCP — передача $transferFileName"
    # Розмір локального файлу вже відомий (жодного remote-запиту заради UI):
    # корисна деталь running-рядка для великих mdz-архівів.
    $transferSizeText = $null
    try {
        $transferSizeText = Format-BRAVOFileSize -Bytes ((Get-Item -LiteralPath $LocalFilePath).Length)
    } catch {
        # Розмір -- лише UI-деталь; його відсутність не має впливати на передачу.
        $transferSizeText = $null
    }
    try {
        $winscpCommand | Out-File -FilePath $tempScript -Encoding $winSCPScriptEncoding -Force
        Write-BRAVOLog -Component 'SFTP' -Message "Створено тимчасовий скрипт WinSCP: $tempScript" -Level "DEBUG"
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $WinSCPPath
        $processInfo.Arguments = "/ini=$winSCPIniPath /script=`"$tempScript`""
        # Вивід WinSCP завжди перехоплюється, щоб він не дублював журнал у консолі.
        # Замість нього показується єдиний індикатор Write-Progress.
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        Write-BRAVOLog -Component 'SFTP' -Message "Запуск WinSCP..." -Level "DEBUG"
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $WinSCPPath
        if (-not $winSCPAvailability.Available) {
            Write-BRAVOLog -Component 'SFTP' -Message (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "передача $transferFileName") -Level "ERROR"
            return $false
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $transferStarted = Get-Date
        $operationTimeoutSeconds = [math]::Max(
            1,
            [int]$backupMonitoring.SFTP.OperationTimeoutSeconds
        )
        $transferTimedOut = $false
        while (-not $process.WaitForExit(500)) {
            $elapsedSeconds = [math]::Floor(((Get-Date) - $transferStarted).TotalSeconds)
            if ($showWinSCPProgress) {
                Show-RunningProgress `
                    -Id 11 `
                    -Activity $transferActivity `
                    -Status (Format-BRAVORunningDetail -ElapsedSeconds $elapsedSeconds -Detail $transferSizeText)
            }
            if ($elapsedSeconds -ge $operationTimeoutSeconds) {
                $transferTimedOut = $true
                try {
                    $process.Kill()
                    [void]$process.WaitForExit(5000)
                } catch {
                    Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося завершити WinSCP після таймауту: $($_.Exception.Message)" -Level "WARNING"
                }
                break
            }
        }
        if (-not $process.HasExited -and -not $process.WaitForExit(5000)) {
            throw "WinSCP не завершився після таймауту передачі"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $output = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError
        $safeOutput = Get-SanitizedWinSCPDiagnostic -Text $output
        $safeErrorOutput = Get-SanitizedWinSCPDiagnostic -Text $errorOutput
        
        if (-not [string]::IsNullOrWhiteSpace($safeOutput)) {
            Write-BRAVOLog -Component 'SFTP' -Message "WinSCP вивiд: $safeOutput" -Level "DEBUG"
        }
        if ($transferTimedOut) {
            Write-BRAVOLog -Component 'SFTP' -Message "Передача WinSCP перевищила таймаут $operationTimeoutSeconds сек.: $transferFileName" -Level "ERROR"
            return $false
        }
        
        if ($process.ExitCode -eq 0) {
            Write-BRAVOLog -Component 'SFTP' -Message "Файл успiшно завантажено: $(Split-Path $LocalFilePath -Leaf)" -Level "SUCCESS"
            return $true
        } else {
            Write-BRAVOLog -Component 'SFTP' -Message "Помилка завантаження (код: $($process.ExitCode)): $(Split-Path $LocalFilePath -Leaf)" -Level "ERROR"
            if (-not [string]::IsNullOrEmpty($safeOutput)) {
                Write-BRAVOLog -Component 'SFTP' -Message "Вивiд WinSCP: $safeOutput" -Level "DEBUG"
            }
            if (-not [string]::IsNullOrEmpty($safeErrorOutput)) {
                Write-BRAVOLog -Component 'SFTP' -Message "Помилка WinSCP: $safeErrorOutput" -Level "DEBUG"
            }
            return $false
        }
    } catch {
        Write-BRAVOLog -Component 'SFTP' -Message "Помилка пiд час завантаження через WinSCP: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if ($showWinSCPProgress) {
            Show-RunningProgress -Id 11 -Activity $transferActivity -Completed
        }
        # Очищаємо тимчасовий файл із конфіденційними даними.
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $tempScript
            Write-BRAVOLog -Component 'SFTP' -Message "Тимчасовий скрипт видалено: $tempScript" -Level "DEBUG"
        } catch {
            Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося видалити тимчасовий скрипт: $($_.Exception.Message)" -Level "WARNING"
        }
    }
}

function Sync-FolderToSFTP {
    param(
        [string]$WinSCPPath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey,
        [string]$LocalDirectory,
        [string]$RemoteDirectory,
        [string]$ComponentName = "BAZA"
    )

    $script:lastBAZASyncOutcome = $null
    $normalizedRemoteDirectory = $RemoteDirectory.Replace("\", "/").Trim("/")
    $remotePath = if ([string]::IsNullOrWhiteSpace($normalizedRemoteDirectory)) {
        "/"
    } else {
        "/$normalizedRemoteDirectory"
    }

    Write-BRAVOLog -Component 'SFTP' -Message "Синхронiзацiя каталогу через WinSCP: $LocalDirectory -> $remotePath"

    if (-not (Test-Path -Path $LocalDirectory -PathType Container)) {
        Write-BRAVOLog -Component 'SFTP' -Message "Локальний каталог не знайдено: $LocalDirectory" -Level "ERROR"
        return $false
    }

    if ($synchronizationSafety.RequireNonEmptyBAZASource) {
        $firstSourceFile = Get-BRAVOFiles `
            -LiteralPath $LocalDirectory `
            -Recurse `
            -Force `
            |
            Select-Object -First 1
        if ($null -eq $firstSourceFile) {
            Write-BRAVOLog -Component 'SFTP' -Message "SFTP-синхронiзацiю $ComponentName заблоковано: локальний каталог порожнiй або недоступний" -Level "ERROR"
            return $false
        }
    }

    if (-not (Test-Path -Path $WinSCPPath -PathType Leaf)) {
        Write-BRAVOLog -Component 'SFTP' -Message "WinSCP не знайдено: $WinSCPPath" -Level "ERROR"
        return $false
    }

    $fileNameUtf8Limit = if (
        [string]$sftpSynchronizationOptions -match '(?i)(^|\s)-resumesupport=on(\s|$)'
    ) {
        # WinSCP додає ".filepart" (9 UTF-8 байт) до тимчасового імені.
        246
    } else {
        255
    }
    $nameCompatibility = Get-BAZARemoteNameCompatibilityIssues `
        -LocalPath $LocalDirectory `
        -MaximumFileUtf8Bytes $fileNameUtf8Limit `
        -MaximumDirectoryUtf8Bytes 255
    Write-BAZARemoteNameCompatibilityAudit `
        -CompatibilityResult $nameCompatibility `
        -ComponentName $ComponentName

    $comparisonBefore = Get-BAZASFTPComparison `
        -LocalPath $LocalDirectory `
        -RemotePath $remotePath `
        -RepositorySFTPUrl $RepositorySFTPUrl `
        -HostKey $HostKey
    Write-BAZASFTPComparisonAudit `
        -Comparison $comparisonBefore `
        -Stage "Before" `
        -ComponentName $ComponentName `
        -IncompatibleIssues $(if ($nameCompatibility.Success) { @($nameCompatibility.Issues) } else { @() })

    # Кореневий каталог синхронізації має бути попередньо створений на SFTP.
    # Не виконуємо mkdir: WinSCP повертає код 1, якщо каталог уже існує,
    # навіть коли option batch continue дозволяє перейти до синхронізації.
    # stat однозначно перевіряє каталог і не створює хибної помилки.
    $winscpCommand = @"
option confirm off
open $RepositorySFTPUrl -hostkey=$HostKey -timeout=$sftpConnectionTimeoutSeconds
option batch abort
stat "$remotePath"
option batch continue
synchronize remote $sftpSynchronizationOptions "$LocalDirectory" "$remotePath"
exit
"@

    $tempScript = New-BRAVOWinSCPTemporaryScriptPath
    $showWinSCPProgress = $progressSettings.Enabled -and $progressSettings.ShowWinSCPOutput
    $syncActivity = "WinSCP — синхронiзацiя $ComponentName"
    try {
        $winscpCommand | Out-File -FilePath $tempScript -Encoding $winSCPScriptEncoding -Force

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $WinSCPPath
        $processInfo.Arguments = "/ini=$winSCPIniPath /script=`"$tempScript`""
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        try {
            # WinSCP.com використовує UTF-8 для перенаправленого виводу.
            # Явне декодування запобігає появі тексту виду "╨..." у журналі.
            $winSCPUtf8Encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
            $processInfo.StandardOutputEncoding = $winSCPUtf8Encoding
            $processInfo.StandardErrorEncoding = $winSCPUtf8Encoding
        } catch {
            Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося встановити UTF-8 для виводу WinSCP: $($_.Exception.Message)" -Level "DEBUG"
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $WinSCPPath
        if (-not $winSCPAvailability.Available) {
            Write-BRAVOLog -Component 'SFTP' -Message (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "синхронізація $ComponentName") -Level "ERROR"
            return $false
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $syncStarted = Get-Date
        $configuredSynchronizationTimeout = [int](
            $backupMonitoring.SFTP.SynchronizationTimeoutSeconds
        )
        $operationTimeoutSeconds = if (
            $configuredSynchronizationTimeout -gt 0
        ) {
            $configuredSynchronizationTimeout
        } else {
            # Сумісність зі старими BRAVO.config.
            [math]::Max(
                1,
                [int]$backupMonitoring.SFTP.OperationTimeoutSeconds
            )
        }
        Write-BRAVOLog -Component 'SFTP' -Message (
            "Таймаут синхронiзацiї ${ComponentName}: " +
            "$operationTimeoutSeconds сек."
        ) -Level "INFO"
        $syncTimedOut = $false
        while (-not $process.WaitForExit(500)) {
            $elapsedSeconds = [math]::Floor(((Get-Date) - $syncStarted).TotalSeconds)
            if ($showWinSCPProgress) {
                Show-RunningProgress `
                    -Id 12 `
                    -Activity $syncActivity `
                    -Status (Format-BRAVORunningDetail -ElapsedSeconds $elapsedSeconds)
            }
            if ($elapsedSeconds -ge $operationTimeoutSeconds) {
                $syncTimedOut = $true
                try {
                    $process.Kill()
                    [void]$process.WaitForExit(5000)
                } catch {
                    Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося завершити WinSCP після таймауту синхронізації ${ComponentName}: $($_.Exception.Message)" -Level "WARNING"
                }
                break
            }
        }
        if (-not $process.HasExited -and -not $process.WaitForExit(5000)) {
            throw "WinSCP не завершився після таймауту синхронізації $ComponentName"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $output = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError
        $sanitizedOutput = Get-SanitizedWinSCPDiagnostic -Text $output
        $sanitizedErrorOutput = Get-SanitizedWinSCPDiagnostic -Text $errorOutput

        if (-not [string]::IsNullOrWhiteSpace($sanitizedOutput)) {
            Write-BRAVOLog -Component 'SFTP' -Message "WinSCP вивiд синхронiзацiї ${ComponentName}: $sanitizedOutput" -Level "DEBUG"
        }
        if ($syncTimedOut) {
            Write-BRAVOLog -Component 'SFTP' -Message "Синхронізація $ComponentName перевищила таймаут $operationTimeoutSeconds сек." -Level "ERROR"
            Write-BRAVOLog -Component 'SFTP' -Message "Повторний запуск продовжить передачу файлів із використанням WinSCP resumesupport" -Level "INFO"
            return $false
        }

        $winSCPExitCode = $process.ExitCode
        if ($winSCPExitCode -ne 0) {
            Write-BRAVOLog -Component 'SFTP' -Message "Помилка SFTP-синхронiзацiї $ComponentName (код: $winSCPExitCode)" -Level "ERROR"
            if (-not [string]::IsNullOrWhiteSpace($sanitizedOutput)) {
                Write-BRAVOLog -Component 'SFTP' -Message "Дiагностика WinSCP (stdout): $sanitizedOutput" -Level "ERROR"
            }
            if (-not [string]::IsNullOrWhiteSpace($sanitizedErrorOutput)) {
                Write-BRAVOLog -Component 'SFTP' -Message "Дiагностика WinSCP (stderr): $sanitizedErrorOutput" -Level "ERROR"
            }
            if ([string]::IsNullOrWhiteSpace($sanitizedOutput) -and
                [string]::IsNullOrWhiteSpace($sanitizedErrorOutput)) {
                Write-BRAVOLog -Component 'SFTP' -Message "WinSCP не повернув тексту помилки; перевiрте права доступу до $remotePath" -Level "ERROR"
            }
        }

        # option batch continue може повернути код 0, навіть якщо окремі файли
        # були пропущені. Тому остаточний результат визначає лише повторне
        # read-only порівняння локального каталогу з хмарою.
        $comparisonAfter = Get-BAZASFTPComparison `
            -LocalPath $LocalDirectory `
            -RemotePath $remotePath `
            -RepositorySFTPUrl $RepositorySFTPUrl `
            -HostKey $HostKey
        Write-BAZASFTPComparisonAudit `
            -Comparison $comparisonAfter `
            -Stage "After" `
            -ComponentName $ComponentName `
            -IncompatibleIssues $(if ($nameCompatibility.Success) { @($nameCompatibility.Issues) } else { @() })

        $syncOutcome = Get-BAZASynchronizationOutcome `
            -WinSCPExitCode $winSCPExitCode `
            -ComparisonBefore $comparisonBefore `
            -ComparisonAfter $comparisonAfter `
            -IncompatibleIssues $(if ($nameCompatibility.Success) { @($nameCompatibility.Issues) } else { @() })
        $script:lastBAZASyncOutcome = $syncOutcome

        if (-not $syncOutcome.VerificationSucceeded) {
            Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося пiдтвердити результат синхронiзацiї $ComponentName повторним порiвнянням; результат вважається помилкою" -Level "ERROR"
            return $false
        }

        if ($null -ne $syncOutcome.CompletedCount) {
            $resultLevel = if ($syncOutcome.IsComplete -and -not $syncOutcome.IsDegraded) {
                "SUCCESS"
            } else {
                "WARNING"
            }
            Write-BRAVOLog -Component 'SFTP' -Message "Результат ${ComponentName}: передано або оновлено сумісних об'єктiв: $($syncOutcome.CompletedCount); залишилося несинхронiзованих: $($syncOutcome.RemainingCount)" -Level $resultLevel
        }

        if ($syncOutcome.IsComplete) {
            if ($syncOutcome.IsDegraded) {
                Write-BRAVOLog -Component 'SFTP' -Message "Каталог $ComponentName синхронізовано для всіх сумісних імен; $($syncOutcome.IncompatibleRemainingCount) об'єктів пропущено через незмінювані несумісні імена. Повторний запуск не потрібен." -Level "WARNING"
            } else {
                Write-BRAVOLog -Component 'SFTP' -Message "Каталог $ComponentName повнiстю синхронiзовано з $remotePath" -Level "SUCCESS"
            }
            return $true
        }

        if ($winSCPExitCode -eq 0 -and $syncOutcome.IsPartial) {
            Write-BRAVOLog -Component 'SFTP' -Message "WinSCP повернув код 0, але синхронiзацiя $ComponentName часткова: залишилося об'єктiв: $($syncOutcome.RemainingCount)" -Level "ERROR"
        }
        return $false
    } catch {
        Write-BRAVOLog -Component 'SFTP' -Message "Помилка пiд час SFTP-синхронiзацiї ${ComponentName}: $($_.Exception.Message)" -Level "ERROR"
        $comparisonAfterException = Get-BAZASFTPComparison `
            -LocalPath $LocalDirectory `
            -RemotePath $remotePath `
            -RepositorySFTPUrl $RepositorySFTPUrl `
            -HostKey $HostKey
        Write-BAZASFTPComparisonAudit `
            -Comparison $comparisonAfterException `
            -Stage "After" `
            -ComponentName $ComponentName `
            -IncompatibleIssues $(if ($nameCompatibility.Success) { @($nameCompatibility.Issues) } else { @() })
        return $false
    } finally {
        if ($showWinSCPProgress) {
            Show-RunningProgress -Id 12 -Activity $syncActivity -Completed
        }
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $tempScript
        } catch {
            # Файл містить облікові дані SFTP — його залишок у %TEMP% це
            # витік, а не дрібниця прибирання.
            Write-BRAVOLog `
                -Component 'SFTP' `
                -Message "Не вдалося прибрати тимчасовий WinSCP-скрипт з обліковими даними ($tempScript): $($_.Exception.Message). Видаліть файл вручну." `
                -Level "WARNING"
        }
    }
}

function New-BRAVOBazaArchiveFullAuditProvider {
    # Acceptance DEV-LIMS blocker #4 (2026-08-13): на Windows PowerShell 5.1
    # .GetNewClosure() прив'язує scriptblock до НОВОГО dynamic module —
    # захоплені ЗМІННІ копіюються, але command-lookup приватних функцій
    # цього runtime (Get-BAZASFTPComparison — script-scope, не exported)
    # у dynamic module НЕ резолвиться. Перший реальний виклик провайдера
    # (bootstrap Full Audit через межу модуля BRAVO.BazaSync) падав
    # CommandNotFoundException — підтверджено відтворенням механізму на
    # PS 5.1 і поведінковим self-test-ом (FullAuditProviderCrossesModuleBoundary).
    #
    # Тому ВСІ command-references захоплюються ЯВНО як FunctionInfo ДО
    # створення closure і викликаються через call operator (&): виклик
    # FunctionInfo виконується в session state, де функцію визначено, —
    # незалежно від scope, з якого викликають closure. Це стосується ОБОХ
    # викликів (і ConvertTo-BRAVOBazaFullAuditResult теж: nested-import
    # модуля так само може бути невидимим із dynamic module). Аналогічно
    # всі значення (URL/host key/шляхи) — явні параметри, а не dynamic
    # lookup script-scope змінних.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LocalDirectory,
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [Parameter(Mandatory = $true)][string]$RepositorySFTPUrl,
        [Parameter(Mandatory = $true)][string]$HostKey
    )

    $capturedComparisonCommand = Get-Command `
        -Name 'Get-BAZASFTPComparison' `
        -CommandType Function `
        -ErrorAction Stop
    $capturedConvertAuditCommand = Get-Command `
        -Name 'ConvertTo-BRAVOBazaFullAuditResult' `
        -CommandType Function `
        -ErrorAction Stop
    $capturedLocalDirectory = $LocalDirectory
    $capturedRemotePath = $RemotePath
    $capturedSftpUrl = $RepositorySFTPUrl
    $capturedHostKey = $HostKey

    return {
        param($Snapshot)
        $comparison = & $capturedComparisonCommand `
            -LocalPath $capturedLocalDirectory `
            -RemotePath $capturedRemotePath `
            -RepositorySFTPUrl $capturedSftpUrl `
            -HostKey $capturedHostKey
        return & $capturedConvertAuditCommand `
            -ComparisonSuccess $comparison.Success `
            -ComparisonError $comparison.Error `
            -PendingFiles $comparison.PendingFiles `
            -LocalDirectory $capturedLocalDirectory `
            -LocalSnapshot $Snapshot
    }.GetNewClosure()
}

function Invoke-BRAVOBazaIncrementalSync {
    # Спільна orchestration-точка Archive/Health (ТЗ п.9: ONE synchronization,
    # ONE SyncResult) — FullAuditProvider будується НАВКОЛО вже наявної
    # Get-BAZASFTPComparison (не дублює її), і використовується лише для
    # bootstrap першого запуску або періодичного Full Audit.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$LocalDirectory,
        [Parameter(Mandatory = $true)][string]$RemoteDirectory,
        [switch]$ForceFullAudit
    )

    $normalizedRemoteDirectory = $RemoteDirectory.Replace("\", "/").Trim("/")
    $remotePath = if ([string]::IsNullOrWhiteSpace($normalizedRemoteDirectory)) { "/" } else { "/$normalizedRemoteDirectory" }

    $fullAuditProvider = New-BRAVOBazaArchiveFullAuditProvider `
        -LocalDirectory $LocalDirectory `
        -RemotePath $remotePath `
        -RepositorySFTPUrl $sftpUrl `
        -HostKey $sftpHostKey

    # Одна canonical точка інтерпретації для Archive/Health/DryRun
    # (Get-BRAVOBazaSettingsEffective, BRAVO.ArchiveRuntime) — StateRoot з
    # можливим override, MutationPolicy, FullAuditEnabled/EveryDays.
    $bazaSettingsEffective = Get-BRAVOBazaSettingsEffective
    $mutationPolicy = $bazaSettingsEffective.MutationPolicy
    $autoArchiveMutationThreshold = $bazaSettingsEffective.AutoArchiveMutationThreshold
    $stateRootPath = $bazaSettingsEffective.StateRoot
    # FullAuditEnabled=$false вимикає ПЕРІОДИЧНИЙ audit (FullAuditEveryDays=0
    # для модуля) — bootstrap першого запуску лишається обов'язковим і від
    # цього прапорця не залежить (без нього перший запуск не має звідки
    # взяти seed-стан, ТЗ п.15).
    $fullAuditEveryDays = $bazaSettingsEffective.FullAuditEveryDays

    # $(...), не (...): усередині звичайних дужок if парситься як КОМАНДА
    # з іменем "if" (валідно для парсера!) і падає лише в рантаймі
    # CommandNotFoundException — саме так упав перший реальний прогін
    # BRAVO_ARCHIV на DEV-LIMS (SFTP acceptance, сценарій 1). Guard на цей
    # клас: Diagnostics/NoKeywordParsedAsCommand у BRAVO_SELF_TEST.
    $operationTimeoutSeconds = [int]$(
        if ([int]$backupMonitoring.SFTP.SynchronizationTimeoutSeconds -gt 0) {
            $backupMonitoring.SFTP.SynchronizationTimeoutSeconds
        } else {
            [math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)
        }
    )

    # Acceptance DEV-LIMS (2026-08-13): .NET-асемблі потрібен winscp.exe,
    # а $winSCPPath комплекту — це Tools\WinSCP.com (CLI-стаб для
    # legacy-шляхів): із ним Session.Open зависав на інтерактивному
    # промпті "winscp>" (CPU~0, лог мовчить). Резолвимо ТУ САМУ пару
    # dll+exe, що її вже роками використовує Get-BAZASFTPComparison.
    $winSCPComponents = Get-BRAVOWinSCPDotNetComponents `
        -WinSCPAssemblyPath ([string]$winSCPAssemblyPath) `
        -WinSCPPath ([string]$winSCPPath)
    if ($null -eq $winSCPComponents) {
        $componentsFailure = New-BRAVOBazaSyncResult `
            -Component $Component `
            -CycleId (New-BRAVOBazaCycleId) `
            -StartedUtc (Get-Date).ToUniversalTime() `
            -CutoffUtc (Get-Date).ToUniversalTime()
        $componentsFailure.Status = 'ERROR'
        $componentsFailure.Error = 'не знайдено сумісну пару WinSCPnet.dll та WinSCP.exe для incremental BAZA sync'
        $componentsFailure.CompletedUtc = (Get-Date).ToUniversalTime()
        return $componentsFailure
    }

    return Invoke-BRAVOBazaComponentSyncSession `
        -Component $Component `
        -LocalDirectory $LocalDirectory `
        -RemoteRootPath $remotePath `
        -RepositorySFTPUrl $sftpUrl `
        -HostKey $sftpHostKey `
        -WinSCPAssemblyPath $winSCPComponents.AssemblyPath `
        -WinSCPExecutablePath $winSCPComponents.ExecutablePath `
        -StateRoot $stateRootPath `
        -ConnectionTimeoutSeconds $sftpConnectionTimeoutSeconds `
        -OperationTimeoutSeconds $operationTimeoutSeconds `
        -MutationPolicy $mutationPolicy `
        -AutoArchiveMutationThreshold $autoArchiveMutationThreshold `
        -BootstrapIfNeeded `
        -FullAuditProvider $fullAuditProvider `
        -FullAuditEveryDays $fullAuditEveryDays `
        -ForceFullAudit:$ForceFullAudit `
        -WriteCheckpoint
}

function Invoke-BRAVOBazaCanonicalSync {
    # ЄДИНИЙ production-диспетчер синхронізації BAZA_APP/BAZA_WWW (#292).
    # І основний прогін Archive (Main), і ручна/планова -SyncBAZA (задача
    # BAZASync, кожні 4 год) викликають РІВНО цю функцію — розходження
    # "Main = безпечний двигун, -SyncBAZA = legacy mirror" структурно
    # неможливе: режим обирається тут і лише тут.
    #   IncrementalAppendOnly (типовий) -> Invoke-BRAVOBazaIncrementalSync:
    #     append-only контракт, MutationPolicy, remote conflict, audit drift,
    #     несумісні імена, mutation archive, оновлення incremental-стану.
    #   Legacy (лише якщо оператор явно виставив BAZA.Mode = "Legacy") ->
    #     Sync-FolderToSFTP (`synchronize remote -mirror`, що ПЕРЕЗАПИСУЄ
    #     remote за time/size і не знає про MutationPolicy).
    # Невідоме значення Mode НЕ деградує мовчки до legacy mirror (так
    # опечатка в конфігурації відкривала б шлях перезапису): fail-closed ERROR.
    # Повертає нормалізований результат (Success лише для COMPLETE/успішного
    # legacy); SyncResult — сирий результат двигуна (лише для incremental),
    # який Main передає Health (ONE synchronization, ONE SyncResult).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('BAZA_APP', 'BAZA_WWW')][string]$Component,
        [Parameter(Mandatory = $true)][string]$LocalDirectory,
        [Parameter(Mandatory = $true)][string]$RemoteDirectory,
        [string]$ComponentName = 'BAZA'
    )

    $mode = ([string](Get-BRAVOBazaSyncModeEffective)).Trim()
    # Порожній/пробільний/$null Mode = типовий режим (як у Get-BRAVOBazaSyncModeEffective-
    # семантиці "не задано"); fail-closed лише для непорожнього невідомого значення.
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'IncrementalAppendOnly' }
    $outcome = [pscustomobject]@{
        Component = $Component
        Mode = $mode
        Success = $false
        # Skipped: SKIPPED_CONCURRENT (інший процес зараз синхронізує компонент) — не помилка
        # для -SyncBAZA (Health трактує так само: INFO), але й не успіх циклу.
        Skipped = $false
        Status = 'ERROR'
        SyncResult = $null
        Degraded = $false
        Completed = 0
        Remaining = 0
        IncompatibleNames = 0
        Error = $null
    }

    if ($mode -eq 'IncrementalAppendOnly') {
        $syncResult = Invoke-BRAVOBazaIncrementalSync -Component $Component -LocalDirectory $LocalDirectory -RemoteDirectory $RemoteDirectory
        $outcome.SyncResult = $syncResult
        $outcome.Status = [string]$syncResult.Status
        # #285: MUTATION_AUTO_ARCHIVED — успіх (INFO за контрактом), єдиний helper BazaSync/Health.
        $outcome.Success = [bool](Test-BRAVOBazaSyncStatusSuccess -Status $outcome.Status)
        $outcome.Skipped = ($outcome.Status -eq 'SKIPPED_CONCURRENT')
        $outcome.Completed = [int]($syncResult.Uploaded + $syncResult.AlreadyVerified)
        $outcome.Remaining = [int]$syncResult.Failed
        $outcome.IncompatibleNames = @($syncResult.IncompatibleFiles).Count
        if (-not $outcome.Success) {
            $errorText = [string]$syncResult.Error
            if ($outcome.Status -in @('MUTATION_VIOLATION', 'MUTATION_AUTO_ARCHIVED') -and @($syncResult.MutationViolations).Count -gt 0) {
                $mutationPreview = @(
                    @($syncResult.MutationViolations) | Select-Object -First 3 | ForEach-Object { [string]$_.RelativePath }
                ) -join ', '
                $errorText = "змінено вже підтверджені файли: $(@($syncResult.MutationViolations).Count) (напр.: $mutationPreview) — перезапис заборонено MutationPolicy"
            }
            $outcome.Error = if ([string]::IsNullOrWhiteSpace($errorText)) { [string]$outcome.Status } else { "$($outcome.Status): $errorText" }
        }
    } elseif ($mode -eq 'Legacy') {
        Write-BRAVOLog -Component 'SFTP' -Message "BAZA.Mode = Legacy: синхронізація $ComponentName через legacy mirror (synchronize remote -mirror) без MutationPolicy/incremental-стану" -Level "WARNING"
        $legacySuccess = Sync-FolderToSFTP `
            -WinSCPPath $winSCPPath `
            -RepositorySFTPUrl $sftpUrl `
            -HostKey $sftpHostKey `
            -LocalDirectory $LocalDirectory `
            -RemoteDirectory $RemoteDirectory `
            -ComponentName $ComponentName
        $outcome.Success = [bool]$legacySuccess
        $outcome.Status = if ($outcome.Success) { 'LEGACY_OK' } else { 'LEGACY_FAILED' }
        if ($null -ne $script:lastBAZASyncOutcome) {
            $outcome.Degraded = [bool]$script:lastBAZASyncOutcome.IsDegraded
            $outcome.Completed = [int]$script:lastBAZASyncOutcome.CompletedCount
            $outcome.Remaining = [int]$script:lastBAZASyncOutcome.RetryableRemainingCount
            $outcome.IncompatibleNames = [int]$script:lastBAZASyncOutcome.IncompatibleRemainingCount
        }
        if (-not $outcome.Success) { $outcome.Error = 'post-sync verification failed' }
    } else {
        $outcome.Error = "невідомий backupMonitoring.SFTP.BAZA.Mode = '$mode' (підтримуються IncrementalAppendOnly і Legacy) — синхронізацію зупинено, щоб не деградувати до legacy mirror"
        Write-BRAVOLog -Component 'SFTP' -Message $outcome.Error -Level "ERROR"
    }
    return $outcome
}

# #292 (рев'ю merge train): SKIPPED_CONCURRENT у -SyncBAZA дає exit 0, але
# підсумок запуску має казати "ПРОПУЩЕНО", а не "УСПІШНО" — інакше завислий
# власник lock непомітно блокує кожен цикл, а журнал і Operations-подія зелені.
function Get-BRAVOManualSyncRunOutcomeLabel {
    param([Parameter(Mandatory = $true)][object]$ManualSyncResult)
    if (-not [bool]$ManualSyncResult.Success) { return 'ПОМИЛКА' }
    $skippedProperty = $ManualSyncResult.PSObject.Properties['Skipped']
    if ($null -ne $skippedProperty -and [bool]$skippedProperty.Value) {
        return 'ПРОПУЩЕНО (інший процес синхронізує компонент)'
    }
    return 'УСПІШНО'
}

function Invoke-ManualBAZASFTPSynchronization {
    # Які напрямки синхронізувати, вирішує викликач: прапорці конфігурації
    # з урахуванням складу backup set (NotInstalled компонент не
    # синхронізується). Дефолти зберігають попередню поведінку прямих
    # викликів.
    param(
        [bool]$BazaAppEnabled = [bool]$componentSettings.Synchronization.BAZA_APP_SFTP,
        [bool]$BazaWWWEnabled = [bool]$componentSettings.Synchronization.BAZA_WWW_SFTP
    )
    Write-BRAVOLog -Component 'SFTP' -Message "==="
    Write-BRAVOLog -Component 'SFTP' -Message "=== РУЧНА СИНХРОНIЗАЦIЯ BAZA_APP / BAZA_WWW НА SFTP ==="
    Write-BRAVOLog -Component 'SFTP' -Message "Режим -SyncBAZA: синхронізуються всі увімкнені BAZA_APP/BAZA_WWW; архiвацiю, очищення архiвiв, NAS/SMB та health-check пропущено" -Level "INFO"
    Show-ScriptProgress -Status "Ручна синхронiзацiя BAZA_APP / BAZA_WWW на SFTP" -PercentComplete 20

    $manualResults = [ordered]@{
        SFTPConnection = New-BRAVOTransferOperationResult -Name 'SFTP connection' -Enabled $true
        BAZA_APP = New-BRAVOTransferOperationResult -Name 'SFTP: BAZA_APP' -Enabled $BazaAppEnabled
        BAZA_WWW = New-BRAVOTransferOperationResult -Name 'SFTP: BAZA_WWW' -Enabled $BazaWWWEnabled
        # Нормалізовані результати канонічного двигуна (Mode/Status/SyncResult)
        # для фінальної Operations-події -SyncBAZA.
        SyncOutcomes = @{}
    }
    $syncTargets = @()
    $sourceConfigurationFailed = $false
    if ($BazaAppEnabled) {
        if (Test-PathWithLog -Path $bazaAppPaths.Source -Description "Каталог BAZA_APP" -CreateIfMissing $false) {
            $syncTargets += [pscustomobject]@{
                Name = "BAZA_APP"
                Source = [string]$bazaAppPaths.Source
                Destination = [string]$sftpDirectories.BAZA
            }
        } else {
            $sourceConfigurationFailed = $true
            $manualResults.BAZA_APP.Success = $false
            $manualResults.BAZA_APP.Error = 'локальний каталог недоступний'
            Write-BRAVOLog -Component 'SFTP' -Message "Ручну синхронізацію BAZA_APP пропущено: локальний каталог недоступний" -Level "ERROR"
        }
    }
    if ($BazaWWWEnabled) {
        if ($bazaWWWDetection.Success -and
            -not [string]::IsNullOrWhiteSpace([string]$bazaWWWPaths.Source) -and
            (Test-PathWithLog -Path $bazaWWWPaths.Source -Description "Каталог BAZA_WWW" -CreateIfMissing $false)) {
            $syncTargets += [pscustomobject]@{
                Name = "BAZA_WWW"
                Source = [string]$bazaWWWPaths.Source
                Destination = [string]$sftpDirectories.BAZAWWW
            }
        } else {
            $sourceConfigurationFailed = $true
            $detectionReason = if ($bazaWWWDetection.Success) { "локальний каталог недоступний" } else { [string]$bazaWWWDetection.Reason }
            Write-BRAVOLog -Component 'SFTP' -Message "Ручну синхронізацію BAZA_WWW пропущено: $detectionReason" -Level "ERROR"
            $manualResults.BAZA_WWW.Success = $false
            $manualResults.BAZA_WWW.Error = $detectionReason
        }
    }
    if ($syncTargets.Count -eq 0) {
        Write-BRAVOLog -Component 'SFTP' -Message "Ручну синхронізацію скасовано: BAZA_APP_SFTP і BAZA_WWW_SFTP вимкнені або їхні джерела недоступні" -Level "ERROR"
        return [pscustomobject]@{ Success = $false; Results = $manualResults }
    }

    # Напрямок без прапорця (вимкнений або компонент не встановлений) не
    # потребує SFTP-каталогу.
    $manualNotInstalled = @(
        if (-not $BazaAppEnabled) { 'BAZA_APP' }
        if (-not $BazaWWWEnabled) { 'BAZA_WWW' }
    )
    if (-not (Test-SFTPConfig -SynchronizationOnly -NotInstalledComponents $manualNotInstalled)) {
        Write-BRAVOLog -Component 'SFTP' -Message "Ручну синхронiзацiю BAZA_APP / BAZA_WWW зупинено через помилки конфiгурацiї SFTP" -Level "ERROR"
        $manualResults.SFTPConnection.Success = $false
        $manualResults.SFTPConnection.Error = 'SFTP configuration invalid'
        return [pscustomobject]@{ Success = $false; Results = $manualResults }
    }

    Show-ScriptProgress -Status "Перевiрка з'єднання з SFTP" -PercentComplete 35
    if (-not (Test-SFTPConnection `
        -WinSCPPath $winSCPPath `
        -RepositorySFTPUrl $sftpUrl `
        -HostKey $sftpHostKey)) {
        Write-BRAVOLog -Component 'SFTP' -Message "Ручну синхронiзацiю BAZA_APP / BAZA_WWW зупинено: не вдалося пiдключитися до SFTP" -Level "ERROR"
        $manualResults.SFTPConnection.Attempted = $true
        $manualResults.SFTPConnection.Success = $false
        $manualResults.SFTPConnection.Error = 'actual SFTP endpoint unavailable'
        return [pscustomobject]@{ Success = $false; Results = $manualResults }
    }
    $manualResults.SFTPConnection.Attempted = $true
    $manualResults.SFTPConnection.Success = $true

    Initialize-BRAVOSFTPRemoteDirectories `
        -WinSCPPath $winSCPPath `
        -RepositorySFTPUrl $sftpUrl `
        -HostKey $sftpHostKey `
        -RemoteDirectories @($syncTargets | ForEach-Object { [string]$_.Destination })

    $syncFailed = $sourceConfigurationFailed
    $anySyncSkipped = $false
    $syncIndex = 0
    foreach ($syncTarget in $syncTargets) {
        $syncIndex++
        $progressPercent = 55 + [math]::Floor(($syncIndex - 1) * 35 / [math]::Max(1, $syncTargets.Count))
        Show-ScriptProgress -Status "Синхронiзацiя $($syncTarget.Name) на SFTP" -PercentComplete $progressPercent
        # #292: той самий канонічний двигун, що й у Main — IncrementalAppendOnly/
        # MutationPolicy/remote conflict/audit drift/несумісні імена діють і для
        # -SyncBAZA; legacy mirror лише за явного BAZA.Mode = "Legacy".
        $canonicalOutcome = Invoke-BRAVOBazaCanonicalSync `
            -Component $syncTarget.Name `
            -LocalDirectory $syncTarget.Source `
            -RemoteDirectory $syncTarget.Destination `
            -ComponentName $syncTarget.Name
        # SKIPPED_CONCURRENT (напр. Health тримає lock компонента) — INFO, не збій -SyncBAZA.
        $syncSkipped = [bool]$canonicalOutcome.Skipped
        $syncSuccess = ([bool]$canonicalOutcome.Success -or $syncSkipped)
        $manualResults.SyncOutcomes[$syncTarget.Name] = $canonicalOutcome
        $targetResult = $manualResults[$syncTarget.Name]
        $targetResult.Attempted = $true
        $targetResult.Success = $syncSuccess
        $targetResult.Degraded = [bool]$canonicalOutcome.Degraded
        $targetResult.Completed = [int]$canonicalOutcome.Completed
        $targetResult.Remaining = [int]$canonicalOutcome.Remaining
        $targetResult.IncompatibleNames = [int]$canonicalOutcome.IncompatibleNames
        if ($syncSkipped) {
            $anySyncSkipped = $true
            $targetResult.Degraded = $true
            $targetResult.Error = 'пропущено: інший процес синхронізує компонент (lock зайнято)'
            Write-BRAVOLog -Component 'SFTP' -Message "Ручну синхронiзацiю $($syncTarget.Name) пропущено: інший процес зараз синхронізує компонент; наступний цикл BAZASync повторить" -Level "INFO"
        } elseif ($syncSuccess) {
            Write-BRAVOLog -Component 'SFTP' -Message "Ручну синхронiзацiю $($syncTarget.Name) на SFTP завершено успiшно ($($canonicalOutcome.Mode): $($canonicalOutcome.Status))" -Level "SUCCESS"
        } else {
            $syncFailed = $true
            $targetResult.Error = [string]$canonicalOutcome.Error
            Write-BRAVOLog -Component 'SFTP' -Message "Ручна синхронiзацiя $($syncTarget.Name) на SFTP завершилася з помилкою ($($canonicalOutcome.Mode): $($canonicalOutcome.Status)): $($canonicalOutcome.Error)" -Level "ERROR"
        }
    }

    # Skipped: хоча б один компонент SKIPPED_CONCURRENT — exit 0 (не збій), але
    # результат запуску НЕ "УСПІШНО": нічого не передано, хмарна копія не оновлена.
    return [pscustomobject]@{ Success = (-not $syncFailed); Skipped = $anySyncSkipped; Results = $manualResults }
}

function Get-BRAVOArchiveFreeSpaceResult {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][double]$MinimumFreeSpaceGB,
        [string[]]$ExcludedDrives = @(),
        [object[]]$Drives
    )

    if (-not (Test-Path -LiteralPath $RootPath)) {
        return [pscustomobject]@{
            Success = $false
            CheckedDriveCount = 0
            AllExcluded = $false
            DriveStatus = @()
            Problems = @("шлях $RootPath не існує або недоступний")
        }
    }

    # КРИТИЧНО: @() мусить обгортати ВЕСЬ if/else-вираз ЗОВНІ, а не кожну
    # гілку окремо зсередини. У Windows PowerShell 5.1 якщо if/else
    # використовується як вираз для присвоєння і обрана гілка повертає
    # РІВНО один об'єкт, той об'єкт "розгортається" назад у скаляр при
    # виході з if/else — навіть якщо сама гілка обгорнута власним @().
    # Без Set-StrictMode це проходить непомітно (PowerShell додає
    # синтетичний .Count=1 для скалярів), але під Set-StrictMode -Version
    # 2.0 (BRAVO_CONFIG_LOADER.ps1) $localDrives.Count нижче кидає
    # "The property 'Count' cannot be found on this object" — реально
    # відтворено на сервері з рівно одним Fixed-диском (C:), production
    # incident 2026-08-19. Зовнішній @() навколо if/else гарантує
    # масив незалежно від кількості елементів у будь-якій гілці.
    $localDrives = @(if ($PSBoundParameters.ContainsKey('Drives')) {
        $Drives | Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed } | Sort-Object -Property Name
    } else {
        [System.IO.DriveInfo]::GetDrives() |
            Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed } |
            Sort-Object -Property Name
    })
    if ($localDrives.Count -eq 0) {
        return [pscustomobject]@{
            Success = $false
            CheckedDriveCount = 0
            AllExcluded = $false
            DriveStatus = @()
            Problems = @('локальні диски типу Fixed не знайдено')
        }
    }

    $checkedDriveCount = 0
    $driveStatus = New-Object System.Collections.Generic.List[object]
    $problems = New-Object System.Collections.Generic.List[string]
    $minimumFreeSpaceBytes = $MinimumFreeSpaceGB * 1GB

    foreach ($driveInfo in $localDrives) {
        $driveName = ([string]$driveInfo.Name).TrimEnd('\').ToUpperInvariant()
        if ($ExcludedDrives -contains $driveName) {
            continue
        }

        $checkedDriveCount++
        if (-not [bool]$driveInfo.IsReady) {
            [void]$problems.Add("диск $driveName не готовий або недоступний")
            continue
        }

        $freeSpaceGB = [math]::Round(([double]$driveInfo.AvailableFreeSpace / 1GB), 2)
        $totalSpaceGB = [math]::Round(([double]$driveInfo.TotalSize / 1GB), 2)
        [void]$driveStatus.Add([pscustomobject]@{
            Drive = $driveName
            FreeSpaceGB = $freeSpaceGB
            TotalSpaceGB = $totalSpaceGB
        })
        if ([double]$driveInfo.AvailableFreeSpace -lt $minimumFreeSpaceBytes) {
            [void]$problems.Add(
                "диск ${driveName}: залишилось ${freeSpaceGB} GB, потрібно мінімум ${MinimumFreeSpaceGB} GB"
            )
        }
    }

    return [pscustomobject]@{
        Success = ($problems.Count -eq 0)
        CheckedDriveCount = $checkedDriveCount
        AllExcluded = ($checkedDriveCount -eq 0)
        DriveStatus = $driveStatus.ToArray()
        Problems = $problems.ToArray()
    }
}

function Get-BRAVOArchiveEstimatedSpaceRequirement {
    # Фіксований поріг MinimumFreeSpaceGB (Get-BRAVOArchiveFreeSpaceResult
    # вище) — загальний захист від переповнення диска ОС, не оцінка того,
    # скільки місця реально потребує ЦЕЙ backup. Джерела MODEL/BLOG/
    # BRAVOEXCH ростуть з часом; сервер може мати вільного місця більше за
    # поріг, але менше, ніж потрібно для нового архіву — 7-Zip/VSS падає
    # посеред роботи, хоча preflight-перевірка вище пройшла.
    #
    # Оцінка спирається на розмір ОСТАННЬОГО hash-підтвердженого валідного
    # архіву того самого компонента (Get-BRAVOValidArchiveSizeHistory —
    # той самий канонічний reader, що вже використовує SizeSanity для
    # виявлення підозріло малих архівів) плюс запас на зростання джерела.
    #
    # 5.2.4: додано другу, НЕЗАЛЕЖНУ від історії величину — нестиснутий
    # розмір джерела. Архів фізично не може бути більшим за своє джерело
    # (найгірший випадок 7-Zip — store-режим), тому
    #   sourceBytes * (1 + SourceOverheadPercent/100)
    # є ДОВЕДЕНОЮ верхньою межею, а не прогнозом. Вона застосовується
    # двояко:
    #   - як стеля для history-оцінки: якщо джерело з часу останнього
    #     архіву зменшилось, вимога зменшується разом з ним (тісніше,
    #     ніколи не більше);
    #   - як сама вимога для компонента БЕЗ валідної історії. До 5.2.4
    #     такий компонент мовчки випадав з оцінки взагалі (перший запуск
    #     або всі попередні архіви invalid/FAILED) — тобто саме тоді, коли
    #     передбачити споживання найважче, вимога була нульовою. Захистом
    #     тоді лишався фіксований поріг; у 5.2.4 поріг більше не гейтить
    #     операцію (Resolve-BRAVOArchiveSpaceDecision нижче), тож цю діру
    #     довелось закрити по-справжньому.
    # Джерело, розмір якого виміряти не вдалось (шлях недоступний, порожній
    # або не заданий), лишає компонент без вимоги — як і до 5.2.4. Так само
    # без вимоги лишається джерело, виміряне успішно з нульовим розміром
    # (порожній каталог або лише файли нульової довжини): sourceBytes -eq 0
    # не дає верхньої оцінки, і SourceUpperBoundBytes/EstimatedBytes = $null.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$EnabledArchives,
        [Parameter(Mandatory = $true)][string]$ArchiveFileFilter,
        [Parameter(Mandatory = $true)][string]$HashFileExtension,
        [Parameter(Mandatory = $true)][double]$MarginPercent,
        # Запас на контейнерні накладні витрати 7-Zip понад нестиснутий
        # розмір джерела. Стиснення практично завжди зменшує розмір, але
        # на несжимаємих даних архів може вийти на частки відсотка більшим
        # за вхід — 2% покривають це з запасом і не роблять межу марною.
        [double]$SourceOverheadPercent = 2.0,
        # Той самий injectable-override принцип, що -Drives у
        # Get-BRAVOArchiveFreeSpaceResult вище: детермінований self-test
        # без залежності від реального вільного місця на CI/dev-машині.
        # Елемент: @{ Drive = 'C:'; AvailableFreeSpace = <bytes>; IsReady = $true }.
        [object[]]$Drives,
        # Детермінований self-test без обходу реальної файлової системи:
        # Type -> нестиснуті байти джерела ($null = виміряти не вдалось).
        [hashtable]$SourceSizeOverrides
    )

    $componentEstimates = New-Object System.Collections.Generic.List[object]
    foreach ($archive in $EnabledArchives) {
        $componentType = [string]$archive.Type
        $destination = [string]$archive.Destination

        # Нестиснутий розмір джерела — доведена верхня межа розміру архіву.
        # Обхід каталогу навмисно тут, у preflight: те саме дерево 7-Zip
        # прочитає далі в будь-якому разі, а помилка доступу тут має
        # означати «межу невідомо», а не крах оцінки.
        $sourceBytes = $null
        if ($PSBoundParameters.ContainsKey('SourceSizeOverrides') -and
            $SourceSizeOverrides.ContainsKey($componentType)) {
            $overrideValue = $SourceSizeOverrides[$componentType]
            if ($null -ne $overrideValue) { $sourceBytes = [int64]$overrideValue }
        } else {
            # $EnabledArchives приходять і як [hashtable] (self-test
            # фікстури), і як [pscustomobject] (archiveDefinitions з
            # конфігурації). Для hashtable ключі НЕ є .NET-властивостями,
            # тож PSObject.Properties.Match тут дав би 0 і джерело мовчки
            # не читалося б; для pscustomobject під Set-StrictMode пряме
            # звернення до відсутньої властивості — помилка. Тому окрема
            # гілка на кожен випадок.
            $sourcePath = $null
            if ($archive -is [System.Collections.IDictionary]) {
                if ($archive.Contains('Source')) { $sourcePath = [string]$archive['Source'] }
            } elseif ($archive.PSObject.Properties.Match('Source').Count -gt 0) {
                $sourcePath = [string]$archive.Source
            }
            # #284: production-джерело має форму "<SRC>\*"
            # (BRAVO.Configuration.Derivation: Join-Path <SOURCE> "*") — так
            # 7-Zip бере ВМІСТ каталогу. -LiteralPath шукав би файл з іменем
            # "*" і ніколи не виміряв би джерело, тож межу рахуємо по самому
            # каталогу. Знімається лише завершальний "*" після роздільника;
            # роздільник лишається, щоб корінь тому ("D:\*" -> "D:\") не
            # перетворився на відносний "D:".
            if (-not [string]::IsNullOrWhiteSpace($sourcePath) -and
                ($sourcePath.EndsWith('\*') -or $sourcePath.EndsWith('/*'))) {
                $sourcePath = $sourcePath.Substring(0, $sourcePath.Length - 1)
            }
            if (-not [string]::IsNullOrWhiteSpace($sourcePath)) {
                try {
                    if (Test-Path -LiteralPath $sourcePath) {
                        $measuredSource = Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Force -ErrorAction Stop |
                            Measure-Object -Property Length -Sum
                        if ($null -ne $measuredSource -and $null -ne $measuredSource.Sum) {
                            $sourceBytes = [int64]$measuredSource.Sum
                        }
                    }
                } catch {
                    # Недоступне чи частково недоступне джерело не робить
                    # оцінку недійсною — воно лише лишає межу невідомою.
                    # Сама недоступність джерела ловиться окремо, як
                    # RequiresAccess у класифікаторі.
                    $sourceBytes = $null
                }
            }
        }
        # Порожнє чи нульове джерело НЕ дає стелі: інакше воно обнулило б
        # вимогу компонента, який насправді має що архівувати.
        $sourceUpperBoundBytes = if ($null -ne $sourceBytes -and $sourceBytes -gt 0) {
            [int64][math]::Ceiling($sourceBytes * (1.0 + ($SourceOverheadPercent / 100.0)))
        } else {
            $null
        }

        $history = @(Get-BRAVOValidArchiveSizeHistory `
            -Directory $destination `
            -ArchiveFilter $ArchiveFileFilter `
            -HashFileExtension $HashFileExtension `
            -MaxCount 1)

        if ($history.Count -eq 0) {
            # Bootstrap: історії немає, тож єдина підстава — доведена межа.
            [void]$componentEstimates.Add([pscustomobject]@{
                Type = $componentType
                Destination = $destination
                HasHistory = $false
                LastValidBytes = $null
                SourceBytes = $sourceBytes
                SourceUpperBoundBytes = $sourceUpperBoundBytes
                EstimateBasis = $(if ($null -ne $sourceUpperBoundBytes) { 'SourceUpperBound' } else { 'Unknown' })
                EstimatedBytes = $sourceUpperBoundBytes
            })
            continue
        }

        $lastBytes = [int64]$history[0].Bytes
        $estimatedBytes = [int64][math]::Ceiling($lastBytes * (1.0 + ($MarginPercent / 100.0)))
        $estimateBasis = 'History'
        if ($null -ne $sourceUpperBoundBytes -and $sourceUpperBoundBytes -lt $estimatedBytes) {
            $estimatedBytes = $sourceUpperBoundBytes
            $estimateBasis = 'HistoryCappedBySource'
        }
        [void]$componentEstimates.Add([pscustomobject]@{
            Type = $componentType
            Destination = $destination
            HasHistory = $true
            LastValidBytes = $lastBytes
            SourceBytes = $sourceBytes
            SourceUpperBoundBytes = $sourceUpperBoundBytes
            EstimateBasis = $estimateBasis
            EstimatedBytes = $estimatedBytes
        })
    }

    # Групування за фізичним диском призначення: компоненти можуть лежати
    # на різних томах (нетиповий, але дозволений layout) — кожен том
    # перевіряється проти суми ЛИШЕ своїх компонентів, не всіх разом.
    $volumeGroups = [ordered]@{}
    foreach ($estimate in $componentEstimates) {
        # 5.2.4: критерій участі — наявність вимоги, а не наявність
        # історії. Компонент без історії тепер несе вимогу, виведену з
        # розміру джерела, і мусить враховуватись у сумі по тому.
        if ($null -eq $estimate.EstimatedBytes) { continue }
        $driveLetter = $null
        try {
            $driveLetter = ([IO.Path]::GetPathRoot($estimate.Destination)).TrimEnd('\').ToUpperInvariant()
        } catch {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($driveLetter)) { continue }
        if (-not $volumeGroups.Contains($driveLetter)) {
            $volumeGroups[$driveLetter] = [pscustomobject]@{
                Drive = $driveLetter
                RequiredBytes = [int64]0
                Components = New-Object System.Collections.Generic.List[string]
            }
        }
        $volumeGroups[$driveLetter].RequiredBytes += $estimate.EstimatedBytes
        [void]$volumeGroups[$driveLetter].Components.Add([string]$estimate.Type)
    }

    $injectedDrives = @(if ($PSBoundParameters.ContainsKey('Drives')) { $Drives } else { @() })

    $problems = New-Object System.Collections.Generic.List[string]
    $volumeStatus = New-Object System.Collections.Generic.List[object]
    foreach ($driveLetter in $volumeGroups.Keys) {
        $group = $volumeGroups[$driveLetter]
        $availableBytes = $null
        try {
            if ($PSBoundParameters.ContainsKey('Drives')) {
                $injectedDrive = @($injectedDrives | Where-Object {
                    ([string]$_.Drive).TrimEnd('\').ToUpperInvariant() -eq $driveLetter
                } | Select-Object -First 1)
                if ($injectedDrive.Count -gt 0 -and [bool]$injectedDrive[0].IsReady) {
                    $availableBytes = [int64]$injectedDrive[0].AvailableFreeSpace
                }
            } else {
                $driveInfo = New-Object System.IO.DriveInfo($driveLetter)
                if ($driveInfo.IsReady) {
                    $availableBytes = [int64]$driveInfo.AvailableFreeSpace
                }
            }
        } catch {
            $availableBytes = $null
        }
        $requiredGB = [math]::Round($group.RequiredBytes / 1GB, 2)
        $availableGB = if ($null -ne $availableBytes) { [math]::Round($availableBytes / 1GB, 2) } else { $null }
        $componentsText = $group.Components -join ', '
        [void]$volumeStatus.Add([pscustomobject]@{
            Drive = $driveLetter
            Components = $componentsText
            RequiredGB = $requiredGB
            AvailableGB = $availableGB
        })
        if ($null -eq $availableBytes) {
            [void]$problems.Add("диск ${driveLetter}: не вдалося визначити вільне місце для оцінки ($componentsText)")
            continue
        }
        if ($availableBytes -lt $group.RequiredBytes) {
            [void]$problems.Add(
                "диск ${driveLetter}: розрахункова потреба ${requiredGB} GB ($componentsText; історія + ${MarginPercent}% запасу, обмежена нестиснутим розміром джерела), доступно лише ${availableGB} GB"
            )
        }
    }

    return [pscustomobject]@{
        Success = ($problems.Count -eq 0)
        ComponentEstimates = $componentEstimates.ToArray()
        VolumeStatus = $volumeStatus.ToArray()
        Problems = $problems.ToArray()
    }
}

function Resolve-BRAVOArchiveSpaceDecision {
    # Замінює Merge-BRAVOArchiveSpaceCheckResults (5.2.1, видалено в 5.2.3
    # разом з переходом на спільний shared classifier BRAVO.DiskSpace —
    # fix/5.2.3-operation-aware-disk-space, BRAVO_5_2_2_DISK_SPACE_TASK_FINAL.md).
    #
    # Будує per-entity вхід для Invoke-BRAVODiskSpaceClassifier:
    #   - health-only sweep усіх локальних Fixed-дисків (§11 — health
    #     monitoring не прибирається; RequiresFreeSpace=false для дисків,
    #     які самі по собі не є archive destination);
    #   - per-компонент SOURCE (RequiresAccess=true, RequiresFreeSpace=false —
    #     VSS-джерело саме по собі не потребує додаткового вільного місця,
    #     Phase 0 §5.2/decision #5);
    #   - per-компонент ARCHIVE_DESTINATION (RequiresFreeSpace=true,
    #     RequirementGranularity=Entity, RequiredGB з уже обчисленого
    #     Get-BRAVOArchiveEstimatedSpaceRequirement; з 5.2.4 компонент без
    #     валідної історії несе вимогу з нестиснутого розміру джерела, і
    #     RequiredGB лишається невідомим, коли джерело виміряти не вдалось
    #     або виміряний розмір нульовий (порожнє джерело чи лише файли
    #     нульової довжини) — тоді GroupRequirementState=Unknown, safe floor
    #     fallback BelowFallbackFloorNoEstimate).
    #
    # ВАЖЛИВО (5.2.4, замінює рішення reviewer #2 від 2026-08-30):
    # RequirementPolicy='ArchivePeakSafe'. MinimumFreeSpaceGB — захист
    # ЗДОРОВ'Я тому, а не гейт операції: якщо доведена вимога влазить у
    # доступне місце, прогін ДОЗВОЛЯЄТЬСЯ з WARNING
    # (BelowHealthFloorButRequirementSatisfied), навіть коли вільного
    # менше за поріг. Блокує лише невиконана вимога
    # (EstimatedRequirementNotMet).
    #
    # Чому 5.2.3 вирішила інакше і чому це виправлено. Там below-floor
    # блокував, бо оцінку не вважали peak-safe; названою причиною були
    # retained generations і .work. Обидві не витримують перевірки:
    # .work лежить на тому самому томі й публікується ПЕРЕЙМЕНУВАННЯМ
    # (New-BRAVOTemporaryArchivePath), тобто в піку тримає один розмір
    # архіву, а не два; наявні генерації вже враховані у виміряному
    # AvailableGB, бо вимірювання відбувається до створення нової.
    # Реальною дірою було інше — компонент без історії взагалі випадав з
    # оцінки. Її закрито в Get-BRAVOArchiveEstimatedSpaceRequirement вище
    # доведеною верхньою межею з нестиснутого розміру джерела, і саме це
    # дає право увімкнути ArchivePeakSafe.
    #
    # Наслідок 5.2.3, який це прибирає: сервер із 715 GB вільного і
    # потребою 0.07 GB блокувався лише тому, що поріг стояв вище за
    # вільне (real-server відтворення 13.09.2026, exit 40).
    # Регресії: Archive/A24, A25, A26 і Archive/EstimatedSpace* у self-test.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$EnabledArchives,
        [Parameter(Mandatory = $true)][object]$EstimatedResult,
        [Parameter(Mandatory = $true)][double]$MinimumFreeSpaceGB,
        [string[]]$ExcludedDrives = @(),
        # Той самий injectable-override принцип, що в
        # Get-BRAVOArchiveFreeSpaceResult/Get-BRAVOArchiveEstimatedSpaceRequirement.
        [object[]]$Drives
    )

    $entitySpecs = New-Object System.Collections.Generic.List[object]

    # Injectable -Drives тут використовує BRAVO.DiskSpace-конвенцію
    # (властивість .Drive), а не .Name, як Get-BRAVOArchiveFreeSpaceResult
    # вище в цьому файлі — сумісно з self-test фікстурами
    # Get-BRAVOArchiveEstimatedSpaceRequirement (теж .Drive) і з усім
    # BRAVO.DiskSpace модулем, куди ці об'єкти передаються далі незмінними.
    $usingInjectedDrives = $PSBoundParameters.ContainsKey('Drives')
    $healthDrives = @(if ($usingInjectedDrives) {
        $Drives | Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed }
    } else {
        [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed }
    })
    foreach ($driveInfo in $healthDrives) {
        $driveName = if ($usingInjectedDrives) {
            ([string]$driveInfo.Drive).TrimEnd('\').ToUpperInvariant()
        } else {
            ([string]$driveInfo.Name).TrimEnd('\').ToUpperInvariant()
        }
        [void]$entitySpecs.Add([pscustomobject]@{
            DisplayPath = "$driveName\"
            Roles = @('HealthOnly')
            RequiresAccess = $false
            RequiresFreeSpace = $false
            MinimumFreeSpaceGB = $MinimumFreeSpaceGB
        })
    }

    foreach ($archive in $EnabledArchives) {
        $componentType = [string]$archive.Type
        $sourcePath = [string]$archive.Source
        if (-not [string]::IsNullOrWhiteSpace($sourcePath)) {
            [void]$entitySpecs.Add([pscustomobject]@{
                DisplayPath = $sourcePath
                Roles = @("${componentType}_SOURCE")
                Components = @($componentType)
                RequiresAccess = $true
                RequiresFreeSpace = $false
            })
        }

        $componentEstimate = @($EstimatedResult.ComponentEstimates | Where-Object { [string]$_.Type -eq $componentType } | Select-Object -First 1)
        $requiredGB = $null
        # 5.2.4: вимогу несе будь-який компонент, для якого її вдалося
        # вивести — з історії або з нестиснутого розміру джерела. Умова
        # HasHistory тут була причиною того, що bootstrap-компонент
        # приходив у класифікатор із RequiredGB = $null.
        if ($componentEstimate.Count -gt 0 -and $null -ne $componentEstimate[0].EstimatedBytes) {
            $requiredGB = [double]$componentEstimate[0].EstimatedBytes / 1GB
        }
        [void]$entitySpecs.Add([pscustomobject]@{
            DisplayPath = [string]$archive.Destination
            Roles = @("${componentType}_ARCHIVE_DESTINATION")
            Components = @($componentType)
            RequiresAccess = $true
            RequiresFreeSpace = $true
            RequirementGranularity = 'Entity'
            RequiredGB = $requiredGB
        })
    }

    $classifierParams = @{
        EntitySpecs = $entitySpecs.ToArray()
        MinimumFreeSpaceGB = $MinimumFreeSpaceGB
        ExcludedDrives = $ExcludedDrives
        RequirementPolicy = 'ArchivePeakSafe'
    }
    if ($PSBoundParameters.ContainsKey('Drives')) { $classifierParams.Drives = $Drives }

    # Write-BRAVODiskSpaceDecisionLog (§58) навмисно НЕ викликається тут:
    # ця функція лишається чистою (лише Invoke-BRAVODiskSpaceClassifier,
    # без залежності від Write-Log), щоб self-test міг витягнути й
    # викликати її ізольовано (New-BRAVOSelfTestRuntimeModule екстрагує
    # ЛИШЕ AST названих функцій — Write-Log сюди не потрапив би).
    # Логування декомпозиції виконує виклик-сайт у Main.
    $classified = Invoke-BRAVODiskSpaceClassifier @classifierParams

    return [pscustomobject]@{
        Success = $classified.Success
        Problems = $classified.Problems
        Warnings = $classified.Warnings
        Results = $classified.Results
    }
}

function Write-BRAVOArchivePreflightFailureSummary {
    param(
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $endedAt = Get-Date
    $duration = $endedAt - $StartedAt
    $script:processExitCode = Resolve-BRAVOExitCode -LocalArchiveFailed

    Set-BRAVOLogComponent -Component 'SUMMARY'
    Write-Log '==='
    Write-Log '=== BRAVO_ARCHIV ЗАВЕРШИВ РОБОТУ ==='
    Write-Log "Результат: ПОМИЛКА" -NoTimestamp
    Write-Log "Причина: $Reason" -NoTimestamp
    Write-Log "Тривалiсть: $($duration.ToString($durationFormat))" -NoTimestamp
    Write-Log '==='

    Write-BRAVOResultHeader `
        -Status 'ПОМИЛКА' `
        -StatusColor ([ConsoleColor]::Red) `
        -ExitCode $script:processExitCode `
        -ExitCodeName (Get-BRAVOExitCodeName -Code $script:processExitCode) `
        -Reason $Reason
    Write-BRAVOResultField -Label 'Початок' -Value $StartedAt.ToString('dd.MM.yyyy HH:mm:ss')
    Write-BRAVOResultField -Label 'Завершення' -Value $endedAt.ToString('dd.MM.yyyy HH:mm:ss')
    Write-BRAVOResultField -Label 'Тривалість' -Value (Format-BRAVODuration -Duration $duration)
    Write-BRAVOResultField -Label 'Створено архівів' -Value '0'
    Write-BRAVOResultField -Label 'Generation' -Value ([string]$script:backupGenerationId)
    Write-BRAVOResultField -Label 'Generation status' -Value 'FAILED'
    Write-BRAVOResultFooter -LogFile $script:logFile
    Complete-BRAVOProgress
}

function Write-BRAVOArchiveOperationStatus {
    # Machine-readable status contract v1 (ROADMAP P2.1, BRAVO.Status) для
    # Archive: ЄДИНИЙ запис статусу для хвоста Main і контрольованих ранніх
    # виходів під lock (#291: preflight вільного місця, orphan VSS,
    # Test-Compatibility). Без нього ранній вихід лишав статус попереднього
    # прогону, і моніторинг бачив "OK" при щоночному exit 40. Lock busy і
    # catch-up skip його НЕ викликають навмисно (див. там). Fail-soft:
    # помилка запису лише логується і ніколи не змінює результат Archive
    # (інваріант «telemetry не змінює exit code»); exit code — параметром,
    # уже обчислений викликачем.
    param(
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [hashtable]$Details = @{},
        # Ранній вихід: деталі — ідентифікатор generation і причина
        # (без сирих повідомлень, шляхів чи секретів).
        [string]$EarlyExitReason
    )

    try {
        # BRAVO_STATUS_Archive.json — статус НІЧНОЇ копії: денна BAZA-
        # синхронізація (-SyncBAZA) його не перезаписує, інакше вона
        # приховала б провал нічної копії або зсунула FinishedAt, на який
        # спирається діагностика Health.
        if ((Test-Path variable:SyncBAZA) -and $SyncBAZA) { return }
        $statusDetails = $Details
        if (-not [string]::IsNullOrWhiteSpace($EarlyExitReason)) {
            $statusDetails = @{
                generationId = [string]$script:backupGenerationId
                generationStatus = [string]$script:backupGenerationStatus
                earlyTermination = $true
                earlyExitReason = $EarlyExitReason
            }
        }
        Write-BRAVOOperationStatus `
            -StateRoot $stateRoot `
            -Operation Archive `
            -ExitCode $ExitCode `
            -ExitCodeName (Get-BRAVOExitCodeName -Code $ExitCode) `
            -StartedAt $StartedAt `
            -Details $statusDetails
    } catch {
        # Ранні виходи не мають зовнішнього try: збій самого логування не
        # повинен перетворити 40/30/32 на 90.
        try {
            Write-Log "ПОПЕРЕДЖЕННЯ: не вдалося записати machine-readable status-файл Archive: $($_.Exception.Message)" -Level "WARNING"
        } catch {
            # Телеметрія не змінює exit code.
        }
    }
}

function Enter-BRAVOArchiveProcessLock {
    # Спільний lock для BRAVO_ARCHIV і BRAVO_MAINTENANCE. Він не дозволяє
    # maintenance зупиняти служби або змінювати джерела під час backup.
    param(
        # Задача Планувальника, у якій іде прогін: визначає ліміт очікування
        # lock (Get-BRAVOOperationLockWaitBudget, BRAVO.System).
        [Parameter(Mandatory = $true)][ValidateSet('Backup', 'BAZASync')][string]$TaskType
    )
    $lockPath = [string]$operationLockSettings.Path
    try {
        if ([string]::IsNullOrWhiteSpace($lockPath)) {
            throw 'operationLockSettings.Path не задано'
        }
        $lockDirectory = Split-Path -Path $lockPath -Parent
        if (-not (Test-Path -LiteralPath $lockDirectory -PathType Container)) {
            New-Item `
                -ItemType Directory `
                -Path $lockDirectory `
                -Force `
                -ErrorAction Stop |
                Out-Null
        }
        # T025: очікування обмежене ExecutionTimeLimit задачі $TaskType
        # (-SyncBAZA = задача BAZASync, 2 год; інакше — Backup) мінус запас.
        # Інакше Планувальник убивав -SyncBAZA посеред 6-год очікування
        # без підсумку й без коду з контракту BRAVO.ExitCodes;
        # тепер вичерпане очікування — штатний SkippedLockBusy (20) з ERROR.
        $lockWaitBudget = Get-BRAVOOperationLockWaitBudget `
            -SchedulerSettings $schedulerSettings `
            -TaskType $TaskType
        $waitMinutes = $lockWaitBudget.EffectiveMinutes
        $waitLimitDescription = [string]$lockWaitBudget.LimitDescription
        $deadline = (Get-Date).AddMinutes($waitMinutes)
        $lockStream = $null
        $lastLockError = $null
        do {
            try {
                # FileShare.Read (не .None): дозволяє чужому read-only peek
                # побачити, хто тримає lock, поки він ще активний — не
                # послаблює саму ексклюзивність, бо конкуруючий acquire
                # (той самий ReadWrite/Read виклик) усе одно провалиться
                # проти вже відкритого handle. Раніше .None робив holder-а
                # непрозорим навіть для власної діагностики очікування
                # (порт 127e7e4 з backup/local-developer-rc2-line).
                $lockStream = [System.IO.File]::Open(
                    $lockPath,
                    [System.IO.FileMode]::OpenOrCreate,
                    [System.IO.FileAccess]::ReadWrite,
                    [System.IO.FileShare]::Read
                )
            } catch {
                $lastLockError = $_.Exception.Message
                if ((Get-Date) -lt $deadline) {
                    # Той самий діагностичний peek, що й у
                    # Enter-BRAVOMaintenanceOperationLock (спільний lock,
                    # DEV-LIMS acceptance 2026-08-23: оператор бачив лише
                    # мовчазний Start-Sleep до OperationLockWaitMinutes без
                    # жодного натяку, хто саме тримає lock).
                    $holderDescription = "невідомо (lock ще не опубліковано або читання наразі неможливе)"
                    try {
                        $peekStream = [System.IO.File]::Open(
                            $lockPath,
                            [System.IO.FileMode]::Open,
                            [System.IO.FileAccess]::Read,
                            [System.IO.FileShare]::ReadWrite
                        )
                        try {
                            $peekReader = New-Object System.IO.StreamReader($peekStream, [System.Text.Encoding]::UTF8)
                            $peekText = $peekReader.ReadToEnd()
                        } finally {
                            $peekStream.Dispose()
                        }
                        if (-not [string]::IsNullOrWhiteSpace($peekText)) {
                            $holderInfo = $peekText | ConvertFrom-Json
                            $holderDescription = "operation=$($holderInfo.operation); pid=$($holderInfo.pid); hostname=$($holderInfo.hostname); startedAt=$($holderInfo.startedAt); generationId=$($holderInfo.generationId)"
                        }
                    } catch {
                        # Peek не вдався (гонка з holder-ом, тимчасова
                        # недоступність) — лишаємо дефолтний опис вище.
                    }
                    Write-BRAVOLog -Component 'LOCK' -Message "Очікую звільнення операційного lock ($lockPath); тримає: $holderDescription; залишилось $([math]::Max(0, [int]($deadline - (Get-Date)).TotalMinutes)) хв." -Level "INFO"
                    Start-Sleep -Seconds 30
                }
            }
        } while ($null -eq $lockStream -and (Get-Date) -lt $deadline)
        if ($null -eq $lockStream) {
            throw "lock не звільнився за $waitMinutes хв.$($waitLimitDescription): $lastLockError"
        }
        # JSON замість "PID=...; Started=..." (аудит P1.8): processStartTime і
        # hostname дають змогу відрізнити той самий PID, перевикористаний
        # іншим процесом після перезавантаження, від справді активного
        # BRAVO_ARCHIV, а operation — з якого runtime взято спільний lock
        # (його ділять Archive і Maintenance).
        $lockProcessStartTime = try {
            (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToString("o")
        } catch {
            $null
        }
        $lockText = ([pscustomobject]@{
            pid = $PID
            processStartTime = $lockProcessStartTime
            hostname = [Environment]::MachineName
            operation = "Archive"
            startedAt = (Get-Date).ToString("o")
            packageVersion = [string]$ScriptVersion
            config = $configPath
            generationId = [string]$script:backupGenerationId
        } | ConvertTo-Json -Compress)
        $lockBytes = [System.Text.Encoding]::UTF8.GetBytes($lockText)
        $lockStream.SetLength(0)
        $lockStream.Write($lockBytes, 0, $lockBytes.Length)
        $lockStream.Flush()

        return [pscustomobject]@{
            Success = $true
            Stream = $lockStream
            Path = $lockPath
            Error = $null
        }
    } catch {
        if ($lockStream) {
            $lockStream.Dispose()
        }
        return [pscustomobject]@{
            Success = $false
            Stream = $null
            Path = $lockPath
            Error = $_.Exception.Message
        }
    }
}

# =============================================
# ОСНОВНА ЛОГІКА
# =============================================

function Write-BRAVOBackupExecutionState {
    # Машинний стан — у %ProgramData%\BRAVO\State (той самий stateRoot, що й
    # restore/task-execution стан Maintenance та version state), а не в
    # каталозі логів: стан не є журналом і не підлягає log-retention.
    $path = Join-Path $stateRoot 'BRAVO_TASK_EXECUTION_STATE.json'
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $stateRoot -Force -ErrorAction Stop)
    }
    $state = @{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $previous = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $state.Maintenance = [string]$previous.Maintenance
            $state.Backup = [string]$previous.Backup
        } catch {
            # Пошкоджений файл стану не зупиняє запуск — він перезапишеться
            # нижче. Але мовчазне ігнорування означало, що стан попереднього
            # запуску тихо зникає, і "Maintenance ніколи не виконувався"
            # виглядало як факт, а не як втрачений запис.
            Write-BRAVOLog `
                -Component 'STATE' `
                -Message "Не вдалося прочитати попередній стан завдань ($path): $($_.Exception.Message). Стан буде перезаписано." `
                -Level "DEBUG"
        }
    }
    $state.Backup = ([datetime]::Now).ToString('o')
    Write-BRAVOStateFileAtomic -Path $path -Text ($state | ConvertTo-Json)
}

function Read-BRAVOBackupLastSuccess {
    # Час останньої COMPLETE-копії з BRAVO_TASK_EXECUTION_STATE.json (його
    # пише Write-BRAVOBackupExecutionState вище). $null = запису немає або
    # файл пошкоджений; для -CatchUpMissedBackup це «копії не було».
    # Категорії (усі -> $null, без винятку; рішення «робити копію» безпечне):
    #  відсутній файл (тихо) / нечитабельний або не-JSON-об'єкт / немає
    #  поля Backup / порожнє чи нерозбірливе значення (кожна — INFO у журнал).
    $path = Join-Path $stateRoot 'BRAVO_TASK_EXECUTION_STATE.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-BRAVOLog `
            -Component 'STATE' `
            -Message "Не вдалося прочитати стан завдань ($path): $($_.Exception.Message)" `
            -Level "INFO"
        return $null
    }
    $property = $null
    if ($null -ne $state -and $state -is [psobject] -and $state -isnot [System.Array]) {
        $property = $state.PSObject.Properties['Backup']
    }
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        Write-BRAVOLog `
            -Component 'STATE' `
            -Message "У стані завдань ($path) немає запису про останню успішну копію (Backup)." `
            -Level "INFO"
        return $null
    }
    [datetime]$lastSuccess = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$property.Value, [ref]$lastSuccess)) {
        Write-BRAVOLog `
            -Component 'STATE' `
            -Message "У стані завдань ($path) поле Backup не є датою: '$([string]$property.Value)'." `
            -Level "INFO"
        return $null
    }
    return $lastSuccess
}

function Main {
    # Ініціалізація
    $scriptStartTime = Get-Date
    # ОДИН GenerationId на весь запуск: усі компоненти однієї копії несуть
    # його в імені, тому MODEL, BLOG і BRAVOEXCH одного backup впізнаються
    # як комплект, а не збираються за близькістю часу створення файлів.
    $backupGenerationId = New-BRAVOBackupGenerationId -Timestamp $scriptStartTime
    $script:backupGenerationId = $backupGenerationId
    $script:backupGenerationStatus = 'FAILED'
    $script:backupGenerationResults = @()
    # Ініціалізуємо явно: якщо фіналізація generation кине виняток до першого
    # присвоєння, РЕЗУЛЬТАТ нижче читає $script:backupGenerationState під
    # Set-StrictMode — неоголошена змінна там була б вторинним крахом.
    $script:backupGenerationState = $null
    # Uniqueness is a runtime invariant, not a promise delegated to an old
    # external config template. Seconds + PID prevent concurrent executions
    # from interleaving in one file even when ConfigPath points to legacy config.
    $logTimestamp = $scriptStartTime.ToString('yyyyMMdd_HHmmss')
    $logFileName = $logFileNameTemplate -f $logTimestamp, $PID
    if ($logFileName -notmatch ("PID{0}(?:\.|$)" -f $PID)) {
        $logFileName = "{0}_PID{1}{2}" -f `
            [IO.Path]::GetFileNameWithoutExtension($logFileName), `
            $PID, `
            [IO.Path]::GetExtension($logFileName)
    }
    $script:logFile = Join-Path $logPath $logFileName

    # Журнал і консоль — два незалежні канали з власними порогами.
    $configuredFileLevel = if ($null -ne $consoleSettings.FileLevel) {
        [string]$consoleSettings.FileLevel
    } else {
        'INFO'
    }
    $configuredConsoleLevel = if ($null -ne $consoleSettings.ConsoleLevel) {
        [string]$consoleSettings.ConsoleLevel
    } else {
        'WARNING'
    }
    $configuredStepWidth = if ($null -ne $consoleSettings.StepWidth) {
        [int]$consoleSettings.StepWidth
    } else {
        58
    }
    [void](Initialize-BRAVOLog `
        -LogFile $script:logFile `
        -FileLevel $configuredFileLevel `
        -ConsoleLevel $configuredConsoleLevel)
    Initialize-BRAVOConsole -StepWidth $configuredStepWidth
    Initialize-BRAVOProgress `
        -Activity ([string]$progressSettings.Activity) `
        -Enabled ([bool]$progressSettings.Enabled)
    # Консольна половина журналу теж має йти через BRAVO.Console: інакше
    # WARNING із бізнес-логіки допишеться у хвіст відкритого рядка етапу
    # ("[3/7] BLOG......... " без переводу рядка) і зламає розмітку.
    Set-BRAVOLogConsoleWriter -Writer {
        param($Message, $Level)
        Write-BRAVOConsoleMessage -Message $Message -Level $Level
    }
    Write-BRAVOHeader `
        -Title ("BRAVO ARCHIVE {0}" -f $ScriptVersion) `
        -Institution ([string]$bravoSettings.InstitutionName) `
        -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
        -Mode $(if ($NoPause) { 'SCHEDULED' } else { 'MANUAL' }) `
        -StartedAt $scriptStartTime

    $processLockResult = Enter-BRAVOArchiveProcessLock `
        -TaskType $(if ($SyncBAZA) { 'BAZASync' } else { 'Backup' })
    if (-not $processLockResult.Success) {
        Write-Log (
            "Запуск скасовано: інший екземпляр BRAVO_ARCHIV уже працює " +
            "або файл блокування недоступний: $($processLockResult.Error)"
        ) -Level "ERROR"
        $script:processExitCode = Resolve-BRAVOExitCode -LockBusy
        # Статус-файл тут навмисно НЕ пишемо (#291): lock тримає інший
        # екземпляр, і запис перезаписав би статус прогону, що ще триває.
        return
    }
    $script:archiveProcessLock = $processLockResult.Stream
    $script:archiveProcessLockPath = $processLockResult.Path

    if ($CatchUpMissedBackup -and -not $SyncBAZA) {
        # Boot-завдання BackupCatchUp. Рішення — ПІСЛЯ lock: якщо в цей
        # момент ішла звичайна нічна копія, ми дочекались її й бачимо вже
        # свіжий стан, тож другої копії не буде.
        $catchUpDecision = Get-BRAVOBackupCatchUpDecision `
            -Now (Get-Date) `
            -DailyAt ([string]$schedulerSettings.Backup.DailyAt) `
            -LastSuccess (Read-BRAVOBackupLastSuccess)
        if (-not $catchUpDecision.Run) {
            Write-Log "Підхоплення пропущеної копії не потрібне: $($catchUpDecision.Reason)" -Level "INFO"
            # Це не прогін архівації: без Operations-події й без
            # вивантаження власного журналу, статус-файл лишається від
            # останнього справжнього прогону.
            $script:archiveCatchUpSkipped = $true
            $script:archiveFinalOperationsEventSent = $true
            $script:processExitCode = 0
            $catchUpMetrics = New-Object System.Collections.Specialized.OrderedDictionary
            $catchUpMetrics.Add('Операція', 'Підхоплення пропущеної нічної копії')
            $catchUpMetrics.Add('Рішення', 'не потрібне')
            $catchUpMetrics.Add('Причина', [string]$catchUpDecision.Reason)
            Write-BRAVOSummary `
                -Result 'УСПІШНО' `
                -Duration ((Get-Date) - $scriptStartTime) `
                -Metrics $catchUpMetrics `
                -LogFile $script:logFile
            return
        }
        Write-Log "Підхоплення пропущеної копії після старту сервера: $($catchUpDecision.Reason)" -Level "INFO"
    }

    # A hard process termination skips PowerShell finally blocks. Persisted
    # ownership lets the next lock owner remove only the exact VSS Shadow IDs
    # previously created by BRAVO, without touching snapshots from other apps.
    $vssOwnershipStatePath = Get-BRAVOVSSOwnershipStatePath
    $orphanCleanupResult = Remove-BRAVOOwnedOrphanVSSResources -StatePath $vssOwnershipStatePath
    if (-not $orphanCleanupResult.Success) {
        Write-BRAVOLog -Component 'VSS' -Message (
            "BRAVO-owned orphan VSS cleanup failed; backup blocked to avoid accumulating untracked snapshots: " +
            $orphanCleanupResult.Error
        ) -Level 'ERROR'
        $script:processExitCode = Resolve-BRAVOExitCode -LocalArchiveFailed
        Write-BRAVOArchiveOperationStatus `
            -ExitCode $script:processExitCode `
            -StartedAt $scriptStartTime `
            -EarlyExitReason 'OrphanVssCleanup'
        return
    }
    if ($orphanCleanupResult.Found) {
        Write-BRAVOLog -Component 'VSS' -Message "Removed $($orphanCleanupResult.Deleted) BRAVO-owned orphan VSS shadow(s) from persisted state" -Level 'SUCCESS'
    }

    # Склад backup set за наявністю компонентів на сервері (рішення
    # власника 2026-10-01). Прапорець компонента означає «копіювати, якщо
    # компонент є»: увімкнений, але не встановлений на цьому сервері
    # компонент (NotInstalled) не потрапляє ні в архівацію, ні в BAZA-
    # синхронізацію, і для нього не створюються каталоги. Рішення
    # обчислюється ДО гілки -SyncBAZA, бо обидва прогони мусять бачити
    # той самий склад. Помилку обчислення не ковтаємо: її fail-closed
    # обробляє перевірка складу джерел нижче (як і раніше).
    $backupScope = $null
    $backupScopeError = $null
    $discoveryBaselineImport = $null
    try {
        $discoveryBaselineImport = Import-BRAVODiscoveryBaseline `
            -StateRoot $stateRoot `
            -RuntimeRoot $runtimeRoot
        $previousCompleteEvidence = Get-BRAVOLastCompleteBackupEvidence -BackupRoot $backupRootPath
        $backupScope = Resolve-BRAVOBackupComponentScope `
            -DiscoveryResult $bravoDiscoveryResult `
            -Baseline $discoveryBaselineImport.Baseline `
            -BaselineSourceKind ([string]$discoveryBaselineImport.Source) `
            -EnabledComponents $discoveryEnabledComponents `
            -PreviousCompleteComponents @($previousCompleteEvidence.Components) `
            -PreviousCompleteAt $previousCompleteEvidence.CreatedAtUtc
    } catch {
        $backupScopeError = $_.Exception.Message
    }
    $notInstalledComponents = @(if ($null -ne $backupScope) { $backupScope.NotInstalled })

    $enabledArchives = @(Select-BRAVOExpectedArchiveDefinition `
        -ArchiveDefinitions $archiveDefinitions `
        -NotInstalledComponents $notInstalledComponents)
    $readyArchives = @()
    $results = @{}
    $bazaAppInstalled = Test-BRAVOBackupComponentInstalled -Component 'BAZA_APP' -NotInstalledComponents $notInstalledComponents
    $bazaWWWInstalled = Test-BRAVOBackupComponentInstalled -Component 'BAZA_WWW' -NotInstalledComponents $notInstalledComponents
    $bazaAppLocalSyncEnabled = [bool]$componentSettings.Synchronization.BAZA_APP_LOCAL -and $bazaAppInstalled
    # BAZA_*_SFTP тут беруться вже effective (Get-BRAVOEffectiveSynchronizationConfiguration
    # ANDить componentSettings.SFTP.Enabled у SftpEnabled кожного компонента,
    # 5.2.2) — один канонічний вираз замінює локальний AND і в цьому файлі,
    # і в Health/Maintenance/Dry Run.
    $bazaAppSFTPSyncEnabled = [bool]($bazaSyncEffective.Components | Where-Object { $_.Name -eq 'BAZA_APP' } | Select-Object -First 1 -ExpandProperty SftpEnabled) -and $bazaAppInstalled
    $bazaWWWSFTPSyncEnabled = [bool]($bazaSyncEffective.Components | Where-Object { $_.Name -eq 'BAZA_WWW' } | Select-Object -First 1 -ExpandProperty SftpEnabled) -and $bazaWWWInstalled
    $bazaWWWLocalSyncEnabled = [bool]$componentSettings.Synchronization.BAZA_WWW_LOCAL -and $bazaWWWInstalled
    $sftpArchiveUploadEnabled = [bool]$storageEffective.SFTP.ArchiveUpload
    $smbArchiveCopyEnabled = [bool]$storageEffective.SMB.ArchiveCopy
    $sftpTransferEnabled = (
        $sftpArchiveUploadEnabled -or
        $bazaAppSFTPSyncEnabled -or
        $bazaWWWSFTPSyncEnabled
    )
    $transferResults = [ordered]@{
        ArchiveUpload = New-BRAVOTransferOperationResult -Name 'SFTP: резервні копії' -Enabled $sftpArchiveUploadEnabled
        BAZA_APP = New-BRAVOTransferOperationResult -Name 'SFTP: BAZA_APP' -Enabled $bazaAppSFTPSyncEnabled
        BAZA_WWW = New-BRAVOTransferOperationResult -Name 'SFTP: BAZA_WWW' -Enabled $bazaWWWSFTPSyncEnabled
        SMB = New-BRAVOTransferOperationResult -Name 'SMB' -Enabled $smbArchiveCopyEnabled
        Health = New-BRAVOTransferOperationResult -Name 'Post-backup health' -Enabled $false
        Notification = New-BRAVOTransferOperationResult -Name 'Notification' -Enabled $false
    }
    $script:transferResults = $transferResults
    $operationFailed = $false

    Show-ScriptProgress -Status "Iнiцiалiзацiя" -PercentComplete 2
    
    Write-Log "==="
    Write-Log "=== ПОЧАТОК РОБОТИ СКРИПТА BRAVO_ARCHIV v.$ScriptVersion ==="
    Write-Log "Файл конфiгурацiї: $configPath" -Level "INFO"
    
    # Перевірка сумісності
    Write-Log "==="
    Write-Log "=== ПЕРЕВIРКА СУМIСНОСТI СИСТЕМИ ==="
    Show-ScriptProgress -Status "Перевiрка сумiсностi" -PercentComplete 5
    # Test-Compatibility сама логує знайдені проблеми; повернене значення
    # тут навмисно не використовується (раніше присвоювалось у змінну,
    # яку ніхто не читав).
    [void](Test-Compatibility)

    if ($SyncBAZA) {
        # componentSettings.SFTP.Enabled=false (5.2.2): -SyncBAZA — це
        # суто SFTP-операція, тому глобальний вимикач має чистий SKIPPED
        # exit 0 БЕЗ жодного звернення до Invoke-ManualBAZASFTPSynchronization
        # (нуль credential-читань, нуль Test-SFTPConfig/Test-SFTPConnection,
        # нуль WinSCP). Фіксує 5.2.1-поведінку, де конфігурація без жодної
        # увімкненої SFTP-цілі помилково давала exit 50 (SftpFailed) —
        # навмисно вимкнений destination не є помилкою конфігурації.
        if (-not [bool]$storageEffective.SFTP.Enabled) {
            Write-Log "==="
            Write-Log "=== РУЧНА СИНХРОНIЗАЦIЯ BAZA_APP / BAZA_WWW НА SFTP: SKIPPED ==="
            Write-Log ([string]$storageEffective.SFTP.DisabledReason) -Level "INFO" -NoTimestamp
            $script:processExitCode = 0
            Show-ScriptProgress -Status "Завершено" -PercentComplete 100
            Complete-BRAVOProgress
            Initialize-BRAVOArchiveSteps -Total 1
            Write-BRAVOArchiveStep `
                -Name 'SFTP: BAZA_APP/BAZA_WWW' `
                -Status 'SKIPPED' `
                -Details ([string]$storageEffective.SFTP.DisabledReason)
            $skippedSyncMetrics = New-Object System.Collections.Specialized.OrderedDictionary
            $skippedSyncMetrics.Add('Операція', 'Ручна синхронізація BAZA_APP / BAZA_WWW')
            $skippedSyncMetrics.Add('Причина', [string]$storageEffective.SFTP.DisabledReason)
            Write-BRAVOSummary `
                -Result 'УСПІШНО' `
                -Duration ([timespan]::Zero) `
                -Metrics $skippedSyncMetrics `
                -LogFile $script:logFile
            return
        }
        # Склад backup set: увімкнений у конфігурації, але не встановлений
        # на цьому сервері BAZA-компонент пропускається без помилки. Якщо
        # після цього синхронізувати нічого, це той самий чистий SKIPPED
        # exit 0, що й для глобально вимкненого SFTP, а не exit 50 кожні
        # кілька годин на сервері, де BAZA_APP ніколи не було.
        foreach ($notInstalledBazaComponent in @($notInstalledComponents | Where-Object { @('BAZA_APP', 'BAZA_WWW') -contains $_ })) {
            Write-Log "Компонент $notInstalledBazaComponent на цьому сервері не встановлено: синхронізацію пропущено без помилки" -Level "INFO" -NoTimestamp
        }
        $manualSyncNotInstalledOnly = (-not $bazaAppSFTPSyncEnabled) -and (-not $bazaWWWSFTPSyncEnabled) -and (
            ([bool]$componentSettings.Synchronization.BAZA_APP_SFTP -and -not $bazaAppInstalled) -or
            ([bool]$componentSettings.Synchronization.BAZA_WWW_SFTP -and -not $bazaWWWInstalled)
        )
        if ($manualSyncNotInstalledOnly) {
            $notInstalledSyncReason = 'увімкнені BAZA-компоненти на цьому сервері не встановлено'
            Write-Log "==="
            Write-Log "=== РУЧНА СИНХРОНIЗАЦIЯ BAZA_APP / BAZA_WWW НА SFTP: SKIPPED ==="
            Write-Log $notInstalledSyncReason -Level "INFO" -NoTimestamp
            $script:processExitCode = 0
            Show-ScriptProgress -Status "Завершено" -PercentComplete 100
            Complete-BRAVOProgress
            Initialize-BRAVOArchiveSteps -Total 1
            Write-BRAVOArchiveStep `
                -Name 'SFTP: BAZA_APP/BAZA_WWW' `
                -Status 'SKIPPED' `
                -Details $notInstalledSyncReason
            $notInstalledSyncMetrics = New-Object System.Collections.Specialized.OrderedDictionary
            $notInstalledSyncMetrics.Add('Операція', 'Ручна синхронізація BAZA_APP / BAZA_WWW')
            $notInstalledSyncMetrics.Add('Причина', $notInstalledSyncReason)
            Write-BRAVOSummary `
                -Result 'УСПІШНО' `
                -Duration ([timespan]::Zero) `
                -Metrics $notInstalledSyncMetrics `
                -LogFile $script:logFile
            return
        }
        $manualSyncStarted = Get-Date
        $manualSyncResult = Invoke-ManualBAZASFTPSynchronization `
            -BazaAppEnabled ([bool]$componentSettings.Synchronization.BAZA_APP_SFTP -and $bazaAppInstalled) `
            -BazaWWWEnabled ([bool]$componentSettings.Synchronization.BAZA_WWW_SFTP -and $bazaWWWInstalled)
        $manualSyncSuccess = [bool]$manualSyncResult.Success
        $manualSyncOutcomeLabel = Get-BRAVOManualSyncRunOutcomeLabel -ManualSyncResult $manualSyncResult
        $manualSyncFinished = Get-Date
        $manualSyncDuration = $manualSyncFinished - $manualSyncStarted

        Write-Log "==="
        Write-Log "=== ЗАВЕРШЕННЯ РУЧНОЇ СИНХРОНIЗАЦIЇ BAZA_APP / BAZA_WWW ==="
        Write-Log "Результат: $manualSyncOutcomeLabel" -NoTimestamp
        Write-Log "Тривалiсть: $($manualSyncDuration.ToString($durationFormat))" -NoTimestamp
        Write-Log "Лог-файл: $logFile" -NoTimestamp
        # -SyncBAZA — це суто SFTP-операція за визначенням.
        $script:processExitCode = if ($manualSyncSuccess) { 0 } else { Resolve-BRAVOExitCode -SftpFailed }
        # #292: фінальна Operations-подія -SyncBAZA несе режим і статус
        # канонічного двигуна по кожному компоненту (MUTATION_VIOLATION,
        # REMOTE_CONFLICT, AUDIT_DRIFT, INCOMPATIBLE_NAME ...), а не лише код.
        # Fail-soft: збір контексту не змінює exit code.
        try {
            $manualEventComponents = @{}
            foreach ($manualOutcomeKey in @($manualSyncResult.Results.SyncOutcomes.Keys)) {
                $manualOutcome = $manualSyncResult.Results.SyncOutcomes[$manualOutcomeKey]
                $manualEventComponents[[string]$manualOutcomeKey] = @{
                    mode = [string]$manualOutcome.Mode
                    status = [string]$manualOutcome.Status
                    success = [bool]$manualOutcome.Success
                    error = [string]$manualOutcome.Error
                }
            }
            $manualEventStatuses = @(
                @($manualEventComponents.Keys | Sort-Object) | ForEach-Object { "${_}=$($manualEventComponents[$_].status)" }
            ) -join '; '
            $script:archiveFinalOperationsEventContext = @{
                Message = "Синхронізація BAZA (-SyncBAZA): $manualSyncOutcomeLabel$(if ($manualEventStatuses) { " ($manualEventStatuses)" }), код завершення $($script:processExitCode)"
                Details = @{
                    syncBaza = $true
                    runOutcome = $manualSyncOutcomeLabel
                    components = $manualEventComponents
                    durationMs = [Math]::Round($manualSyncDuration.TotalMilliseconds)
                }
            }
        } catch {
            $script:archiveFinalOperationsEventContext = $null
            Write-Log "Не вдалося зібрати контекст фінальної події Operations для -SyncBAZA: $($_.Exception.Message) — буде надіслано мінімальну подію" -Level "WARNING"
        }
        Show-ScriptProgress -Status "Завершено" -PercentComplete 100
        Complete-BRAVOProgress

        Initialize-BRAVOArchiveSteps -Total (1 + @(
            @('BAZA_APP', 'BAZA_WWW') | Where-Object {
                [bool]$manualSyncResult.Results[$_].Enabled
            }
        ).Count)
        foreach ($manualResultKey in @('SFTPConnection', 'BAZA_APP', 'BAZA_WWW')) {
            $manualResult = $manualSyncResult.Results[$manualResultKey]
            if (-not [bool]$manualResult.Enabled) { continue }
            $manualStepStatus = if (-not [bool]$manualResult.Success) {
                'ERROR'
            } elseif ([bool]$manualResult.Degraded) {
                'WARNING'
            } else {
                'OK'
            }
            Write-BRAVOArchiveStep `
                -Name ([string]$manualResult.Name) `
                -Status $manualStepStatus `
                -Details ([string]$manualResult.Error)
        }

        # Ручна синхронізація завершується до етапів, тому підсумок тут
        # окремий: інакше в консолі не лишилося б жодного зворотного звʼязку.
        $manualSyncStatistics = Get-BRAVOLogStatistics
        $manualSyncMetrics = New-Object System.Collections.Specialized.OrderedDictionary
        $manualSyncMetrics.Add('Операція', 'Ручна синхронізація BAZA_APP / BAZA_WWW')
        $manualSyncMetrics.Add('Попереджень', [string]$manualSyncStatistics.Warnings)
        $manualSyncMetrics.Add('Помилок', [string]$manualSyncStatistics.Errors)
        Write-BRAVOSummary `
            -Result $(if ($manualSyncSuccess) { 'УСПІШНО' } else { 'ПОМИЛКА' }) `
            -Duration $manualSyncDuration `
            -Metrics $manualSyncMetrics `
            -LogFile $script:logFile
        return
    }

    # dev.16 (review round 3): План/dynamic Total нижче навмисно
    # розташовані ПІСЛЯ if ($SyncBAZA) { ...; return } вище, а не до
    # нього — -SyncBAZA це окремий, ізольований SFTP-only flow (BAZA_APP/
    # BAZA_WWW через SFTP) зі своїм власним Initialize-BRAVOArchiveSteps
    # і БЕЗ Плану операцій. Якби цей блок стояв до SyncBAZA-гілки, оператор
    # у режимі -SyncBAZA побачив би "План операцій" повного backup-flow
    # (Архівація/SFTP/SMB/очищення), який до -SyncBAZA взагалі не
    # застосовується. Archive/SyncBazaModeDoesNotGainNormalArchiveOperations
    # це перевіряє.
    # Етапи консолі: середовище + шляхи + по одному на компонент, далі —
    # лише ті передавання й перевірки, що справді увімкнені в конфігурації.
    $healthCheckEnabled = (
        [bool]$backupMonitoring.Enabled -and [bool]$backupMonitoring.RunAfterBackup
    )
    $transferResults.Health.Enabled = $healthCheckEnabled
    # dev.16: локальна синхронізація BAZA_APP/BAZA_WWW реально виконується
    # (Sync-Folders), але досі не мала власного numbered step — додається
    # до знаменника й отримує рядок нижче лише коли реально увімкнена
    # (той самий "вимкнений компонент не займає рядка" принцип, що й решта
    # передавань/перевірок тут).
    # dev.18: старе очищення журналів (завжди оцінюється — рівно один
    # доданок) і очищення backup generation (лише коли реально увімкнене
    # — той самий вираз, що й План нижче, і сам гейт кроку далі)
    # мігрували з unnumbered Write-BRAVOOperationResult на numbered
    # Write-BRAVOArchiveStep; Total має враховувати обидва.
    Initialize-BRAVOArchiveSteps -Total (
        2 +
        1 +
        1 +
        # #158 (етап 3): "Перевірка складу джерел" — завжди присутній
        # numbered крок (виконується незалежно від складу компонентів),
        # тому доданок безумовний. Без нього Current перевищив би Total.
        1 +
        $(if ($bazaAppLocalSyncEnabled) { 1 } else { 0 }) +
        $(if ($bazaWWWLocalSyncEnabled) { 1 } else { 0 }) +
        $enabledArchives.Count +
        $(if ($enableArchiveDeletion -or $enableFailedArchiveDeletion -or $enableLunchArchiveCleanup -or $enableOrphanTempCleanup) { 1 } else { 0 }) +
        $(if ($sftpArchiveUploadEnabled) { 1 } else { 0 }) +
        $(if ($bazaAppSFTPSyncEnabled) { 1 } else { 0 }) +
        $(if ($bazaWWWSFTPSyncEnabled) { 1 } else { 0 }) +
        $(if ($smbArchiveCopyEnabled) { 1 } else { 0 }) +
        $(if ($healthCheckEnabled) { 1 } else { 0 })
    )

    # dev.16: План операцій — те саме "plan-first" правило, що вже
    # застосоване в Maintenance (docs/OPERATOR_CONSOLE_UX.md) — оператор
    # бачить, ЩО саме виконуватиметься, ще до першого кроку. Джерело
    # значень — ті самі прапорці, що вже визначають нумерацію кроків вище
    # (Initialize-BRAVOArchiveSteps) і Total нижче, тому план і фактичне
    # виконання не можуть розійтися. Внутрішні деталі реалізації (VSS
    # ownership state, SHA512, manifest writer, lock bookkeeping,
    # notification transport) свідомо НЕ показуються тут — вони не є
    # окремими operator decisions, лише частина вже перелічених операцій.
    # dev.16 (review round 3): рендер через спільний Write-BRAVOPlan
    # (BRAVO.Console) — той самий helper, що Health, а не власний raw
    # Write-Host у runtime.
    $archivePlanEntries = [ordered]@{}
    $archivePlanEntries['Перевірка вільного місця'] = $true
    # #158 (етап 3): оператор має бачити в плані, що склад джерел
    # звіряється з підтвердженим baseline — інакше зупинка прогону через
    # дрейф виглядала б як несподівана відмова невідомої природи.
    $archivePlanEntries['Перевірка складу джерел'] = $true
    $archivePlanEntries['Локальна синхронізація BAZA_APP'] = [bool]$bazaAppLocalSyncEnabled
    $archivePlanEntries['Локальна синхронізація BAZA_WWW'] = [bool]$bazaWWWLocalSyncEnabled
    foreach ($archiveDefinition in $archiveDefinitions) {
        $archivePlanEntries["Архівація $($archiveDefinition.Type)"] = ([bool]$archiveDefinition.Enabled -and
            $notInstalledComponents -notcontains [string]$archiveDefinition.Type)
    }
    $archivePlanEntries['Завантаження архівів на SFTP'] = [bool]$sftpArchiveUploadEnabled
    $archivePlanEntries['Синхронізація BAZA_APP на SFTP'] = [bool]$bazaAppSFTPSyncEnabled
    $archivePlanEntries['Синхронізація BAZA_WWW на SFTP'] = [bool]$bazaWWWSFTPSyncEnabled
    $archivePlanEntries['Копіювання на NAS/SMB'] = [bool]$smbArchiveCopyEnabled
    # Очищення старих журналів/backup generation — той самий "завжди
    # оцінюється" принцип, що Maintenance/Очистка старих даних/логів:
    # немає власного on/off прапорця, ТАК означає "перевірку буде
    # проведено", а не "щось буде видалено цього разу" (порожній
    # результат рендериться SKIPPED). dev.18: обидві операції тепер
    # numbered [N/TOTAL] кроки (Write-BRAVOArchiveStep, той самий Total
    # вище і той самий вираз нижче, що й тут) — не unnumbered.
    $archivePlanEntries['Очищення старих журналів'] = $true
    $archivePlanEntries['Очищення старих backup generation'] = [bool](
        $enableArchiveDeletion -or $enableFailedArchiveDeletion -or $enableLunchArchiveCleanup -or $enableOrphanTempCleanup
    )
    $archivePlanEntries['Post-backup Health'] = [bool]$healthCheckEnabled
    Write-BRAVOPlan -Title 'План операцій:' -Entries $archivePlanEntries

    # Використовуємо NoTimestamp для інформаційного блоку
    Write-Log "==="
    Write-Log "=== ОПЦIЇ СКРИПТА ==="
    Write-Log "Версiя та дата скрипта: $ScriptVersion вiд $ScriptDate" -NoTimestamp
    Write-Log "Збірка (build): $(if ([string]::IsNullOrWhiteSpace([string]$ScriptBuildId)) { 'невідома' } else { [string]$ScriptBuildId })" -NoTimestamp
    Write-Log "Час початку: $($scriptStartTime.ToString($logTimestampFormat))" -NoTimestamp
    Write-Log "Кореневий каталог: $rootPath" -NoTimestamp
    Write-Log "Каталог резервних копiй: $backupRootPath" -NoTimestamp
    Write-Log "Режим логування: $LogLevel" -NoTimestamp
    Write-Log "Режим сумiсностi: $(if ($compatibilityMode) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Видалення коректних архiвiв за строком зберігання: $(if ($enableArchiveDeletion) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Очищення неповних/пошкоджених комплектів після $failedArchiveRetentionDays днів: $(if ($enableFailedArchiveDeletion) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Очищення обідніх архівів (_1300.): $(if ($enableLunchArchiveCleanup) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Узгодженість щоденних архівів: $([string]$backupConsistency.Mode)" -NoTimestamp
    foreach ($archive in $archiveDefinitions) {
        $archiveLogState = $(if (-not $archive.Enabled) { 'ВИМКНЕНО' } elseif ($notInstalledComponents -contains [string]$archive.Type) { 'НЕ ВСТАНОВЛЕНО (пропущено)' } else { 'УВIМКНЕНО' })
        Write-Log "Архiвацiя $($archive.Type): $archiveLogState" -NoTimestamp
    }
    # Джерело показуємо для кожного увiмкненого компонента — інакше з
    # самого лише "УВIМКНЕНО" не видно, який саме каталог реально обрано
    # автоматичним discovery (bravo.ini) чи легасі-евристикою (BRAVOEXCH).
    if ([bool]$componentSettings.Archive.MODEL) {
        if (-not [string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.MODEL_SOURCE)) {
            Write-Log "Джерело MODEL: $($bravoDiscoveryResult.MODEL_SOURCE) ($($bravoDiscoveryResult.Reasons.MODEL))" -NoTimestamp
        } else {
            Write-Log "Джерело MODEL не визначено: $($bravoDiscoveryResult.Reasons.MODEL)" -Level "ERROR" -NoTimestamp
        }
    }
    if ([bool]$componentSettings.Archive.BLOG) {
        if (-not [string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.BLOG_SOURCE)) {
            Write-Log "Джерело BLOG: $($bravoDiscoveryResult.BLOG_SOURCE) ($($bravoDiscoveryResult.Reasons.BLOG))" -NoTimestamp
        } else {
            Write-Log "Джерело BLOG не визначено: $($bravoDiscoveryResult.Reasons.BLOG)" -Level "ERROR" -NoTimestamp
        }
    }
    if ([bool]$componentSettings.Archive.BRAVOEXCH) {
        if (-not [string]::IsNullOrWhiteSpace([string]$bravoExchSourceDirectory)) {
            Write-Log "Джерело BRAVOEXCH: $bravoExchSourceDirectory (вибрано автоматично)" -NoTimestamp
        } else {
            Write-Log "Джерело BRAVOEXCH не знайдено: жоден із каталогів не існує або не містить файлів: $($bravoExchSourceCandidates -join '; ')" -Level "ERROR" -NoTimestamp
        }
    }
    Write-Log "Локальна синхронiзацiя BAZA APP: $(if ($bazaAppLocalSyncEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    if ($bazaAppLocalSyncEnabled) {
        if (-not [string]::IsNullOrWhiteSpace([string]$bazaAppPaths.Source)) {
            Write-Log "Джерело BAZA APP: $($bazaAppPaths.Source) ($($bravoDiscoveryResult.Reasons.BAZA_APP))" -NoTimestamp
        } else {
            Write-Log "Джерело BAZA APP не визначено: $($bravoDiscoveryResult.Reasons.BAZA_APP)" -Level "ERROR" -NoTimestamp
        }
    }
    Write-Log "Завантаження архiвiв на SFTP: $(if ($sftpArchiveUploadEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Синхронiзацiя BAZA APP на SFTP: $(if ($bazaAppSFTPSyncEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Синхронiзацiя BAZA WWW на SFTP: $(if ($bazaWWWSFTPSyncEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Локальна синхронiзацiя BAZA WWW: $(if ($bazaWWWLocalSyncEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    if ($bazaWWWSFTPSyncEnabled -or $bazaWWWLocalSyncEnabled) {
        if ($bazaWWWDetection.Success) {
            Write-Log (
                "Джерело BAZA WWW: $($bazaWWWPaths.Source); " +
                "служба: $($bazaWWWDetection.ServiceName); " +
                "executable: $($bazaWWWDetection.ServiceExecutable)"
            ) -NoTimestamp
        } else {
            Write-Log "Джерело BAZA WWW не визначено: $($bazaWWWDetection.Reason)" -Level "ERROR" -NoTimestamp
        }
    }
    Write-Log "Копіювання архівів на NAS/SMB: $(if ($smbArchiveCopyEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    # Причина "ВИМКНЕНО" вище — дочірній прапорець чи глобальний
    # componentSettings.SFTP.Enabled/SMB.Enabled (5.2.2)? Явно розрізняємо
    # в логах лише для другого випадку — дочірні ВИМКНЕНО без пояснення
    # це наявна 5.2.1-поведінка, яку тут не змінюємо.
    if (-not [string]::IsNullOrWhiteSpace([string]$storageEffective.SFTP.DisabledReason)) {
        Write-Log $storageEffective.SFTP.DisabledReason -Level "INFO" -NoTimestamp
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$storageEffective.SMB.DisabledReason)) {
        Write-Log $storageEffective.SMB.DisabledReason -Level "INFO" -NoTimestamp
    }

    # Disk preflight виконується до очищення, локальної синхронізації, VSS і
    # створення archive generation. Політика та виключення спільні з
    # Maintenance, тому оператор отримує однакове рішення в обох скриптах.
    $freeSpaceCheckStartedAt = Get-Date
    Show-ScriptProgress -Status 'Перевірка вільного місця' -PercentComplete 8
    Write-Log '==='
    Write-Log '=== ПЕРЕВІРКА ВІЛЬНОГО МІСЦЯ ==='
    # Діагностичний знімок УСІХ виявлених дисків (будь-якого DriveType, не
    # лише Fixed) пишеться безумовно тут, до самого виклику
    # Get-BRAVOArchiveFreeSpaceResult. Якщо цей виклик впаде з винятком
    # (наприклад, нетиповий диск/старий PowerShell на конкретному сервері),
    # лог і так матиме повний перелік того, що фізично бачила система — без
    # цього оператор при "не вдалося перевірити локальні диски" не має
    # жодної підказки, які диски взагалі є в системі.
    try {
        $archiveAllDetectedDrives = @([System.IO.DriveInfo]::GetDrives())
        Write-Log "Виявлено дисків у системі (усі типи): $($archiveAllDetectedDrives.Count)" -Level 'INFO'
        foreach ($detectedDrive in $archiveAllDetectedDrives) {
            $ddName = try { [string]$detectedDrive.Name } catch { '?' }
            $ddType = try { [string]$detectedDrive.DriveType } catch { '?' }
            $ddReady = try { [bool]$detectedDrive.IsReady } catch { $false }
            $ddFormat = if ($ddReady) { try { [string]$detectedDrive.DriveFormat } catch { 'н/д' } } else { 'н/д' }
            $ddFree = if ($ddReady) { try { "$([math]::Round([double]$detectedDrive.AvailableFreeSpace / 1GB, 2)) GB" } catch { 'н/д' } } else { 'н/д' }
            $ddTotal = if ($ddReady) { try { "$([math]::Round([double]$detectedDrive.TotalSize / 1GB, 2)) GB" } catch { 'н/д' } } else { 'н/д' }
            Write-Log "  Диск ${ddName}: тип=$ddType, готовий=$ddReady, формат=$ddFormat, вільно=$ddFree, всього=$ddTotal" -Level 'INFO'
        }
    } catch {
        Write-Log "Не вдалося отримати діагностичний перелік дисків: $($_.Exception.Message)" -Level 'WARNING'
    }
    $freeSpaceExclusionsText = if ($archiveFreeSpaceExcludedDrives.Count -gt 0) {
        $archiveFreeSpaceExcludedDrives -join ', '
    } else {
        'немає'
    }
    Write-Log (
        "Поріг: $archiveMinimumFreeSpaceGB GB на кожному локальному Fixed-диску; " +
        "виключення: $freeSpaceExclusionsText"
    ) -Level 'INFO'
    try {
        # -RootPath тут лише sanity-перевірка "SOME каталог доступний"
        # (сама функція перевіряє ВСІ Fixed-диски, а не лише диск $RootPath)
        # — Test-Path з порожнім рядком кидає виняток, а $rootPath може
        # бути порожнім, коли LIMSRoot не визначено (служба BRAVO
        # відсутня; safety-review "service state != backup policy").
        # $runtimeRoot гарантовано існує (звідти виконується сам скрипт)
        # незалежно від LIMSRoot і не змінює перелік перевірених дисків.
        $archiveFreeSpaceRootPath = if ([string]::IsNullOrWhiteSpace([string]$rootPath)) {
            $runtimeRoot
        } else {
            $rootPath
        }
        $archiveFreeSpaceResult = Get-BRAVOArchiveFreeSpaceResult `
            -RootPath $archiveFreeSpaceRootPath `
            -MinimumFreeSpaceGB $archiveMinimumFreeSpaceGB `
            -ExcludedDrives $archiveFreeSpaceExcludedDrives
    } catch {
        $archiveFreeSpaceResult = [pscustomobject]@{
            Success = $false
            CheckedDriveCount = 0
            AllExcluded = $false
            DriveStatus = @()
            Problems = @("помилка перевірки місця: $($_.Exception.Message)")
        }
    }

    foreach ($driveStatus in @($archiveFreeSpaceResult.DriveStatus)) {
        Write-Log (
            "Диск $($driveStatus.Drive): доступно $($driveStatus.FreeSpaceGB) GB " +
            "з $($driveStatus.TotalSpaceGB) GB (потрібно мінімум: $archiveMinimumFreeSpaceGB GB)"
        ) -Level 'INFO'
    }
    if ($archiveFreeSpaceResult.AllExcluded) {
        Write-Log 'Усі локальні диски виключено з перевірки вільного місця' -Level 'WARNING'
    }

    # Розрахункова перевірка поверх фіксованого порогу вище: скільки місця
    # реально потребує ЦЕЙ backup (за розміром останнього валідного архіву
    # кожного компонента + запас), а не лише "диск ОС не забитий впритул".
    # Компонент без історії з 5.2.4 оцінюється верхньою оцінкою з
    # розміру джерела; без вимоги лишається лише компонент, джерело якого
    # виміряти не вдалось або виміряний розмір якого нульовий (порожнє
    # джерело чи лише файли нульової довжини).
    try {
        $archiveEstimatedSpaceResult = Get-BRAVOArchiveEstimatedSpaceRequirement `
            -EnabledArchives $enabledArchives `
            -ArchiveFileFilter $archiveFileFilter `
            -HashFileExtension $hashFileExtension `
            -MarginPercent $archiveEstimatedSpaceMarginPercent
    } catch {
        Write-Log "Не вдалося виконати розрахункову перевірку місця: $($_.Exception.Message)" -Level 'WARNING'
        $archiveEstimatedSpaceResult = [pscustomobject]@{ Success = $true; ComponentEstimates = @(); VolumeStatus = @(); Problems = @() }
    }
    foreach ($volumeStatusEntry in @($archiveEstimatedSpaceResult.VolumeStatus)) {
        Write-Log (
            "Диск $($volumeStatusEntry.Drive) ($($volumeStatusEntry.Components)): розрахункова потреба " +
            "$($volumeStatusEntry.RequiredGB) GB, доступно $($volumeStatusEntry.AvailableGB) GB"
        ) -Level 'INFO'
    }

    # Operation-aware рішення (fix/5.2.3-operation-aware-disk-space): спільний
    # BRAVO.DiskSpace-класифікатор оцінює кожен volume/шлях відповідно до
    # його реальної ролі в ЦІЙ операції (Participates/RequiresAccess/
    # RequiresFreeSpace), а не як єдиний глобальний floor по всіх Fixed-
    # дисках. $archiveFreeSpaceResult/$archiveEstimatedSpaceResult вище
    # залишаються діагностичним джерелом для per-drive логів і DriveStatus,
    # який Send-BRAVOArchiveFreeSpaceAlert використовує для тексту
    # сповіщення — саме рішення (Success/Problems) тепер належить
    # Resolve-BRAVOArchiveSpaceDecision.
    $archiveSpaceDecision = Resolve-BRAVOArchiveSpaceDecision `
        -EnabledArchives $enabledArchives `
        -EstimatedResult $archiveEstimatedSpaceResult `
        -MinimumFreeSpaceGB $archiveMinimumFreeSpaceGB `
        -ExcludedDrives $archiveFreeSpaceExcludedDrives
    Write-BRAVODiskSpaceDecisionLog -Results $archiveSpaceDecision.Results -Logger { param($line) Write-Log $line -Level 'INFO' }
    foreach ($spaceWarning in @($archiveSpaceDecision.Warnings)) {
        Write-Log $spaceWarning -Level 'WARNING'
    }
    $archiveFreeSpaceResult.Success = $archiveSpaceDecision.Success
    $archiveFreeSpaceResult.Problems = $archiveSpaceDecision.Problems

    $archiveFreeSpaceReason = if ($archiveFreeSpaceResult.Success) {
        $null
    } else {
        "Недостатньо вільного місця або не вдалося перевірити локальні диски: " +
        (@($archiveFreeSpaceResult.Problems) -join '; ')
    }
    if (-not $archiveFreeSpaceResult.Success) {
        Write-Log $archiveFreeSpaceReason -Level 'ERROR'
    }
    Write-BRAVOArchiveStep `
        -Name 'Перевірка вільного місця' `
        -Status $(if ($archiveFreeSpaceResult.Success) { 'OK' } else { 'ERROR' }) `
        -Duration ((Get-Date) - $freeSpaceCheckStartedAt) `
        -Details $archiveFreeSpaceReason

    if (-not $archiveFreeSpaceResult.Success) {
        Send-BRAVOArchiveFreeSpaceAlert `
            -Result $archiveFreeSpaceResult `
            -MinimumFreeSpaceGB $archiveMinimumFreeSpaceGB
        Write-BRAVOArchivePreflightFailureSummary `
            -StartedAt $scriptStartTime `
            -Reason $archiveFreeSpaceReason
        # Код 40 обчислено в summary вище.
        Write-BRAVOArchiveOperationStatus `
            -ExitCode $script:processExitCode `
            -StartedAt $scriptStartTime `
            -EarlyExitReason 'FreeSpacePreflight'
        return
    }

    $archiveCredentialValid = $true
    if ($enabledArchives.Count -gt 0) {
        Write-Log "==="
        Write-Log "=== ПЕРЕВIРКА ПАРОЛЯ АРХIВIВ ==="
        if (-not [string]::IsNullOrWhiteSpace($script:archiveCredentialInitializationError)) {
            Write-Log "Не вдалося завантажити пароль архiвiв: $($script:archiveCredentialInitializationError)" -Level "ERROR"
            $archiveCredentialValid = $false
        } elseif ([string]::IsNullOrWhiteSpace($script:archivePassword)) {
            Write-Log "Пароль архiвiв вiдсутнiй у Windows Credential Manager" -Level "ERROR"
            $archiveCredentialValid = $false
        } elseif ($archiveParams -match '(?i)(^|\s)-p(?=\S|\s|$)') {
            Write-Log "Видалiть параметр -p<пароль> з archiveParams у BRAVO.config: пароль має зберiгатися лише у Credential Manager" -Level "ERROR"
            $archiveCredentialValid = $false
        } else {
            Write-Log "Пароль архiвiв завантажено з Windows Credential Manager" -Level "SUCCESS"
        }
    }

    $archiveConsistencyValid = $true
    if ($enabledArchives.Count -gt 0) {
        Write-Log "==="
        Write-Log "=== ПЕРЕВIРКА УЗГОДЖЕНОСТI АРХIВIВ ==="
        $consistencyMode = [string]$backupConsistency.Mode
        $snapshotContext = [string]$backupConsistency.SnapshotContext
        if ($consistencyMode -ne "VSS") {
            Write-Log "backupConsistency.Mode повинен мати значення VSS; live-архівація заборонена" -Level "ERROR"
            $archiveConsistencyValid = $false
        } elseif ($snapshotContext -ne "ClientAccessible") {
            Write-Log "backupConsistency.SnapshotContext повинен мати значення ClientAccessible" -Level "ERROR"
            $archiveConsistencyValid = $false
        } else {
            # dev.19: фактично виправлений текст — runtime створює ОДИН
            # VSS Snapshot Set на generation (New-BRAVOVSSSnapshotSet,
            # рядок ~5540 нижче), який спільно читають усі увімкнені
            # компоненти (MODEL/BLOG/BRAVOEXCH), а не окремий знімок на
            # кожен. Термінологія — та сама, що вже BRAVO_DRY_RUN.ps1
            # ("один VSS Snapshot Set для всіх enabled archive components").
            # Лише діагностичний текст; сама VSS-логіка не змінена.
            Write-Log "Узгодженість архівів: один VSS Snapshot Set для всіх увімкнених компонентів generation" -Level "SUCCESS"
        }
    }

    # Перевіряємо налаштування SFTP лише для увімкнених компонентів передачі
    $sftpConfigurationValid = $true
    if ($sftpTransferEnabled) {
        Show-ScriptProgress -Status "Перевiрка конфiгурацiї SFTP" -PercentComplete 10
        Write-Log "==="
        Write-Log "=== ПЕРЕВIРКА КОНФIГУРАЦIЇ SFTP ==="
        $sftpConfigurationValid = Test-SFTPConfig -NotInstalledComponents $notInstalledComponents
        if (-not $sftpConfigurationValid) {
            Write-Log "SFTP-компоненти буде пропущено; локальна архiвацiя продовжиться" -Level "WARNING"
            $operationFailed = $true
        }
    } else {
        Write-Log "Перевiрка SFTP не потрiбна: усi компоненти передачi вимкнено" -Level "INFO"
    }

    $smbConfigurationValid = $true
    if ($smbArchiveCopyEnabled) {
        $transferResults.SMB.Attempted = $true
        Show-ScriptProgress -Status "Перевірка конфігурації NAS/SMB" -PercentComplete 11
        Write-Log "==="
        Write-Log "=== ПЕРЕВІРКА КОНФІГУРАЦІЇ NAS/SMB ==="
        $smbConfigurationValid = Test-SMBConfig
        if (-not $smbConfigurationValid) {
            $transferResults.SMB.Success = $false
            $transferResults.SMB.Error = 'SMB configuration invalid'
            Write-Log "Копіювання на NAS/SMB буде пропущено; локальна архівація продовжиться" -Level "WARNING"
            $operationFailed = $true
        }
    } else {
        Write-Log "Перевірка NAS/SMB не потрібна: компонент вимкнено" -Level "INFO"
    }
    
    $oldLogCleanupStartedAt = Get-Date
    $oldLogsToRemove = @()
    $oldLogCleanupPathMissing = $false
    if (Test-Path -LiteralPath $logPath -PathType Container) {
        $logRetentionCutoff = (Get-Date).AddDays(-$logRetentionDays)
        $oldLogsToRemove = @(Get-BRAVOFiles -Path $logPath -Filter $logFileFilter |
            Where-Object { $_.LastWriteTime -lt $logRetentionCutoff })
    } else {
        Write-Log "Шлях журналів не знайдено: $logPath" -Level "ERROR"
        $operationFailed = $true
        $oldLogCleanupPathMissing = $true
    }

    $oldLogCleanupSucceeded = $true
    if ($oldLogsToRemove.Count -gt 0) {
        Write-Log "==="
        Write-Log "=== ОЧИЩЕННЯ СТАРИХ ЛОГIВ ==="
        Show-ScriptProgress -Status "Очищення старих логiв" -PercentComplete 12
        $oldLogCleanupSucceeded = Remove-OldLogsByAge `
                -Path $logPath `
                -Filter $logFileFilter `
                -RetentionDays $logRetentionDays `
                -Logger { param($Message, $Level) Write-Log $Message -Level $Level }
        if (-not $oldLogCleanupSucceeded) {
            $operationFailed = $true
        }
    }

    # dev.18: numbered [N/TOTAL] крок (Write-BRAVOArchiveStep) — раніше
    # unnumbered Write-BRAVOOperationResult; реальний DEV-LIMS вивід
    # показав цю операцію ПОЗА канонічною нумерацією, хоча вона реально
    # виконується щоразу. Позиція виклику (до "Перевірка середовища")
    # не змінена — той самий порядок виконання, лише інший renderer.
    # Retention days/filter/delete semantics не змінені.
    Write-BRAVOArchiveStep `
        -Name 'Очищення старих журналів' `
        -Status $(
            if ($oldLogCleanupPathMissing -or -not $oldLogCleanupSucceeded) { 'ERROR' }
            elseif ($oldLogsToRemove.Count -eq 0) { 'SKIPPED' }
            else { 'OK' }
        ) `
        -Duration ((Get-Date) - $oldLogCleanupStartedAt) `
        -Details $(
            if ($oldLogCleanupPathMissing) { 'шлях журналів не знайдено; деталі у журналі.' }
            elseif (-not $oldLogCleanupSucceeded) { 'перевірте LOG для деталей' }
            elseif ($oldLogsToRemove.Count -eq 0) { 'журналів старших за retention немає' }
            else { "видалено файлів: $($oldLogsToRemove.Count)" }
        )

    # Перевірка шляхів
    Write-Log "==="
    # Етап 1 підсумовує все, що перевірялося до цього: сумісність, пароль,
    # узгодженість, конфігурацію передавання та очищення старих логів.
    $environmentValid = (
        $archiveCredentialValid -and
        $archiveConsistencyValid -and
        $sftpConfigurationValid -and
        $smbConfigurationValid
    )
    Write-BRAVOArchiveStep `
        -Name "Перевірка середовища" `
        -Status $(if ($environmentValid) { 'OK' } else { 'WARNING' })

    # =============================================
    # СКЛАД ДЖЕРЕЛ ВІДНОСНО ПІДТВЕРДЖЕНОГО BASELINE (#158, етап 3)
    # =============================================
    # Раніше baseline читав ЛИШЕ BRAVO_SETUP -ValidateOnly, і лише як
    # необов'язкове попередження. Тобто захист від дрейфу діяв у момент,
    # коли оператор дивиться на екран, і не діяв у запланованому нічному
    # прогоні — саме там, де неповна копія лишається непоміченою. Для
    # інструменту резервного копіювання це найгірший клас відмови.
    #
    # Перевірка стоїть ПЕРЕД перевіркою шляхів і перед будь-якою
    # production-операцією: рішення "склад backup set змінився" не залежить
    # від доступності конкретних каталогів.
    #
    # Гранулярність навмисна і збігається з уже наявним патерном SYSTEM
    # access probe нижче: дрейф КОНКРЕТНОГО компонента вимикає САМЕ його
    # (generation стає INCOMPLETE, а не FAILED), і лише неможливість
    # оцінити baseline узагалі скасовує весь прогін. Зворотне рішення —
    # "будь-який дрейф скасовує все" — означало б, що неоднозначний
    # BAZA_WWW позбавляє резервної копії ще й MODEL/BLOG, тобто зменшує
    # захист даних заради формальної суворості.
    $discoveryBaselineValid = $true
    $discoveryBaselineGlobalFailure = $false
    $driftFailedComponents = @()
    $discoveryDriftFindings = @()
    try {
        # Baseline і склад уже обчислено на початку прогону
        # (Resolve-BRAVOBackupComponentScope поверх тієї самої матриці
        # Test-BRAVODiscoveryComponentDrift); тут лише звітуємо й
        # застосовуємо рішення. Помилка того обчислення — та сама
        # fail-closed гілка, що й раніше.
        if ($null -ne $backupScopeError) {
            throw $backupScopeError
        }
        foreach ($baselineProblem in @($discoveryBaselineImport.Problems)) {
            Write-BRAVOLog -Component 'DISCOVERY' -Message ([string]$baselineProblem) -Level 'WARNING'
        }
        $discoveryDriftFindings = @($backupScope.Findings)
    } catch {
        # Fail-closed: якщо саму перевірку складу виконати не вдалося, ми
        # НЕ знаємо, чи повний backup set. Мовчазне продовження тут
        # повернуло б рівно той дефект, який закриває ця перевірка.
        $discoveryBaselineValid = $false
        $discoveryBaselineGlobalFailure = $true
        Write-BRAVOLog -Component 'DISCOVERY' -Message (
            "Перевірку складу джерел відносно baseline виконати не вдалося: $($_.Exception.Message)"
        ) -Level 'ERROR'
    }
    foreach ($driftFinding in $discoveryDriftFindings) {
        $driftLevel = $(if ([string]$driftFinding.Severity -eq 'Error') { 'ERROR' } else { 'INFO' })
        Write-BRAVOLog -Component 'DISCOVERY' -Message ([string]$driftFinding.Message) -Level $driftLevel
    }
    # Знахідка з Component='BASELINE' означає "оцінити склад нічим"
    # (непридатний до читання baseline, відсутній presence-контракт) —
    # це глобальна умова, а не проблема одного компонента.
    if (@($discoveryDriftFindings | Where-Object {
            [string]$_.Severity -eq 'Error' -and [string]$_.Component -eq 'BASELINE'
        }).Count -gt 0) {
        $discoveryBaselineGlobalFailure = $true
    }
    $driftFailedComponents = @($discoveryDriftFindings |
        Where-Object { [string]$_.Severity -eq 'Error' -and [string]$_.Component -ne 'BASELINE' } |
        ForEach-Object { [string]$_.Component })
    if ($discoveryBaselineGlobalFailure -or $driftFailedComponents.Count -gt 0) {
        $discoveryBaselineValid = $false
    }
    $discoveryDriftDetails = $(if ($discoveryBaselineGlobalFailure) {
        'склад джерел оцінити не вдалося; деталі у журналі.'
    } elseif ($driftFailedComponents.Count -gt 0) {
        "компонентів із дрейфом: $($driftFailedComponents -join ', '); деталі у журналі."
    } elseif ($notInstalledComponents.Count -gt 0) {
        "не встановлено на цьому сервері: $($notInstalledComponents -join ', ')"
    } else {
        ''
    })
    Write-BRAVOArchiveStep `
        -Name "Перевірка складу джерел" `
        -Status $(if ($discoveryBaselineValid) { 'OK' } else { 'ERROR' }) `
        -Details $discoveryDriftDetails

    Write-Log "=== ПЕРЕВIРКА НЕОБХIДНИХ ШЛЯХIВ ==="
    Show-ScriptProgress -Status "Перевiрка необхiдних шляхiв" -PercentComplete 15
    $requiredPaths = @($baseRequiredPaths)
    $archiveToolAvailable = $archiveCredentialValid -and $archiveConsistencyValid
    # dev.16: підсумковий лічильник для compact "Перевірка шляхів" Details
    # нижче (недоступних шляхів/перевірок: N) — рахує КОЖЕН окремий провал:
    # Test-PathWithLog і SYSTEM write/read probes. Існуючі bool-прапорці
    # (basePathsAvailable/sourceAvailable/...) і логіка на їх основі не
    # змінені — рахунок лише додається поруч.
    $pathCheckFailureCount = 0

    if ($enabledArchives.Count -gt 0) {
        $requiredPaths += @{Path=$arcPath; Description="7-Zip"; CreateIfMissing=$false}
    }

    $basePathsAvailable = $true
    foreach ($item in $requiredPaths) {
        if (-not (Test-PathWithLog `
            -Path $item.Path `
            -Description $item.Description `
            -CreateIfMissing ([bool]$item.CreateIfMissing))) {
            $basePathsAvailable = $false
            $pathCheckFailureCount++
            if ($item.Path -eq $arcPath) {
                $archiveToolAvailable = $false
            }
        }
    }

    foreach ($archive in $enabledArchives) {
        $sourceAvailable = Test-PathWithLog `
            -Path $archive.Source `
            -Description "Джерело архiву $($archive.Type) мiстить данi" `
            -CreateIfMissing $false
        $destinationAvailable = Test-PathWithLog `
            -Path $archive.Destination `
            -Description "Каталог архiву $($archive.Type)" `
            -CreateIfMissing $true
        if (-not $sourceAvailable) { $pathCheckFailureCount++ }
        if (-not $destinationAvailable) { $pathCheckFailureCount++ }

        if ($archiveToolAvailable -and $sourceAvailable -and $destinationAvailable) {
            $readyArchives += $archive
        } else {
            $results[$archive.Type] = @{
                ArchiveSuccess = $false
                HashSuccess = $false
                CreateSuccess = $false
                IntegritySuccess = $false
                ErrorStage = 'CONFIGURATION'
                Error = 'Required archive source, destination, or tool is unavailable'
                ToolFailure = $null
            }
            Write-Log "Компонент $($archive.Type) пропущено через помилку налаштувань, шляху або вiдсутнi данi" -Level "ERROR"
            $operationFailed = $true
        }
    }

    $bazaAppSourceAvailable = $true
    $bazaAppDestinationAvailable = $true
    if ($bazaAppLocalSyncEnabled -or $bazaAppSFTPSyncEnabled) {
        $bazaAppSourceAvailable = Test-PathWithLog `
            -Path $bazaAppPaths.Source `
            -Description "Каталог BAZA APP" `
            -CreateIfMissing $false
        if (-not $bazaAppSourceAvailable) { $pathCheckFailureCount++ }
    }
    if ($bazaAppLocalSyncEnabled) {
        $bazaAppDestinationAvailable = Test-PathWithLog `
            -Path $bazaAppPaths.Destination `
            -Description "Каталог архiву BAZA APP" `
            -CreateIfMissing $true
        if (-not $bazaAppDestinationAvailable) { $pathCheckFailureCount++ }
    }
    $bazaWWWSourceAvailable = $true
    $bazaWWWDestinationAvailable = $true
    if ($bazaWWWSFTPSyncEnabled -or $bazaWWWLocalSyncEnabled) {
        if ($bazaWWWDetection.Success -and
            -not [string]::IsNullOrWhiteSpace([string]$bazaWWWPaths.Source)) {
            $bazaWWWSourceAvailable = Test-PathWithLog `
                -Path $bazaWWWPaths.Source `
                -Description "Каталог BAZA WWW" `
                -CreateIfMissing $false
            if (-not $bazaWWWSourceAvailable) { $pathCheckFailureCount++ }
        } else {
            Write-Log "Каталог BAZA WWW недоступний: $($bazaWWWDetection.Reason)" -Level "ERROR"
            $bazaWWWSourceAvailable = $false
            $pathCheckFailureCount++
        }
    }
    if ($bazaWWWLocalSyncEnabled) {
        $bazaWWWDestinationAvailable = Test-PathWithLog `
            -Path $bazaWWWPaths.Destination `
            -Description "Каталог архiву BAZA WWW" `
            -CreateIfMissing $true
        if (-not $bazaWWWDestinationAvailable) { $pathCheckFailureCount++ }
    }

    $allPathsExist = (
        $basePathsAvailable -and
        $readyArchives.Count -eq $enabledArchives.Count -and
        $bazaAppSourceAvailable -and
        $bazaAppDestinationAvailable -and
        $bazaWWWSourceAvailable -and
        $bazaWWWDestinationAvailable
    )
    Show-PathCheckSummary -CheckedPaths $requiredPaths -AllPathsExist $allPathsExist

    # SYSTEM access preflight. Test-Path підтверджує тільки існування, тому
    # перед будь-яким backup виконуємо фактичний write/read-back probe в
    # кожному required writable каталозі й read-only enumeration джерел.
    #
    # dev.16: раніше "Перевірка шляхів" рендерилась ТУТ (одразу після
    # $allPathsExist), ДО цього preflight — оператор бачив OK, а кілька
    # рядків нижче production операції скасовувались через провал SYSTEM
    # access probe. Крок тепер рендериться ПІСЛЯ обчислення
    # $systemAccessValid (нижче), об'єднуючи існування шляхів і фактичний
    # доступ в один Result.
    $systemAccessValid = $true
    # BRAVO_ARCHIV пише лише власні логи ($logPath = RuntimeRoot\LOGS),
    # backup-дані (BackupRoot) і машинний стан (ProgramData\State). Системні
    # журнали (SystemLogRoot) — зона BRAVO_MAINTENANCE, тому тут не пробуються.
    # Кожна probe-ціль належить конкретному ВЛАСНИКУ.
    #
    # 'Shared' — спільна інфраструктура (власні логи, BackupRoot, каталог
    # lock, machine state). Без неї не може виконатись і чесно записатись
    # ЖОДНА операція, тому її провал справедливо скасовує все.
    #
    # 'Archive'/'BAZA_APP'/'BAZA_WWW' — ресурс КОНКРЕТНОГО компонента. Його
    # провал вимикає ЛИШЕ цей компонент, а решта виконуються далі.
    #
    # Раніше тут був один глобальний $systemAccessValid, і будь-який провал
    # скасовував усе: відсутня тека опціональної синхронізації BAZA_WWW
    # давала "опубліковано 0 з 3; VSS Snapshot Set: не створено", хоча
    # джерела MODEL/BLOG/BRAVOEXCH і BAZA_APP були повністю справні, а
    # BAZA_APP ще й отримувала оманливе "локальний source path недоступний".
    # Це суперечило принципу самого циклу архівації: помилка одного
    # компонента не має псувати решту.
    $sharedAccessValid = $true
    $probeFailedComponents = New-Object System.Collections.Generic.List[string]

    $writeProbeTargets = New-Object System.Collections.Generic.List[object]
    foreach ($sharedWritePath in @(
        [string]$logPath,
        [string]$backupRootPath,
        (Split-Path -Path ([string]$operationLockSettings.Path) -Parent),
        [string]$stateRoot
    )) {
        [void]$writeProbeTargets.Add([pscustomobject]@{
            Path = $sharedWritePath; Owner = 'Shared'; Component = $null
        })
    }
    foreach ($archive in $enabledArchives) {
        [void]$writeProbeTargets.Add([pscustomobject]@{
            Path = [string]$archive.Destination; Owner = 'Archive'; Component = [string]$archive.Type
        })
        [void]$writeProbeTargets.Add([pscustomobject]@{
            Path = [System.IO.Path]::Combine([string]$archive.Destination, '.work'); Owner = 'Archive'; Component = [string]$archive.Type
        })
    }
    if ($bazaAppLocalSyncEnabled) {
        [void]$writeProbeTargets.Add([pscustomobject]@{
            Path = [string]$bazaAppPaths.Destination; Owner = 'BAZA_APP'; Component = $null
        })
    }
    if ($bazaWWWLocalSyncEnabled) {
        [void]$writeProbeTargets.Add([pscustomobject]@{
            Path = [string]$bazaWWWPaths.Destination; Owner = 'BAZA_WWW'; Component = $null
        })
    }
    foreach ($probeGroup in (Group-BRAVOProbeTarget -Targets $writeProbeTargets.ToArray())) {
        $writeProbe = Test-BRAVOFileSystemWriteProbe -Path ([string]$probeGroup.Path)
        if ($writeProbe.Success) {
            Write-BRAVOLog -Component 'PATHS' -Message "SYSTEM write probe OK: $($probeGroup.Path)" -Level 'DEBUG'
            continue
        }
        Write-BRAVOLog -Component 'PATHS' -Message "SYSTEM write probe FAILED: $($probeGroup.Path) ($($writeProbe.Error))" -Level 'ERROR'
        $systemAccessValid = $false
        $pathCheckFailureCount++
        foreach ($probeOwner in $probeGroup.Owners) {
            switch ([string]$probeOwner.Owner) {
                'Archive' {
                    if (-not $probeFailedComponents.Contains([string]$probeOwner.Component)) {
                        [void]$probeFailedComponents.Add([string]$probeOwner.Component)
                    }
                }
                'BAZA_APP' { $bazaAppDestinationAvailable = $false }
                'BAZA_WWW' { $bazaWWWDestinationAvailable = $false }
                default { $sharedAccessValid = $false }
            }
        }
    }

    $sourceProbeTargets = New-Object System.Collections.Generic.List[object]
    foreach ($archive in $enabledArchives) {
        [void]$sourceProbeTargets.Add([pscustomobject]@{
            Path = [string]$archive.Source; Owner = 'Archive'; Component = [string]$archive.Type
        })
    }
    if ($bazaAppLocalSyncEnabled -or $bazaAppSFTPSyncEnabled) {
        [void]$sourceProbeTargets.Add([pscustomobject]@{
            Path = [string]$bazaAppPaths.Source; Owner = 'BAZA_APP'; Component = $null
        })
    }
    if ($bazaWWWLocalSyncEnabled -or $bazaWWWSFTPSyncEnabled) {
        [void]$sourceProbeTargets.Add([pscustomobject]@{
            Path = [string]$bazaWWWPaths.Source; Owner = 'BAZA_WWW'; Component = $null
        })
    }
    foreach ($probeGroup in (Group-BRAVOProbeTarget -Targets $sourceProbeTargets.ToArray())) {
        $readProbe = Test-BRAVOSourceReadProbe -Path ([string]$probeGroup.Path)
        if ($readProbe.Success) {
            Write-BRAVOLog -Component 'PATHS' -Message "SYSTEM source read probe OK: $($readProbe.Path)" -Level 'DEBUG'
            continue
        }
        Write-BRAVOLog -Component 'PATHS' -Message "SYSTEM source read probe FAILED: $($probeGroup.Path) ($($readProbe.Error))" -Level 'ERROR'
        $systemAccessValid = $false
        $pathCheckFailureCount++
        foreach ($probeOwner in $probeGroup.Owners) {
            switch ([string]$probeOwner.Owner) {
                'Archive' {
                    if (-not $probeFailedComponents.Contains([string]$probeOwner.Component)) {
                        [void]$probeFailedComponents.Add([string]$probeOwner.Component)
                    }
                }
                'BAZA_APP' { $bazaAppSourceAvailable = $false }
                'BAZA_WWW' { $bazaWWWSourceAvailable = $false }
                default { $sharedAccessValid = $false }
            }
        }
    }

    # Дві різні причини скасувати ВСІ production-операції — одна
    # реалізація скасування. #158 (етап 3) додав другу причину (дрейф
    # складу джерел відносно baseline); дублювати сам механізм зупинки
    # заради неї означало б дві копії однієї політики.
    $productionCancelLogMessage = $null
    $productionCancelResultError = $null
    if (-not $sharedAccessValid) {
        # Спільна інфраструктура недоступна — виконувати нема куди й нема чим.
        $productionCancelLogMessage = 'Production operations cancelled because SYSTEM access preflight failed for shared infrastructure (logs/BackupRoot/lock/state)'
        $productionCancelResultError = 'SYSTEM access preflight failed for shared infrastructure'
    } elseif ($discoveryBaselineGlobalFailure) {
        # Не "компонент зник", а "не можемо встановити, чи зник" — оцінити
        # склад backup set нічим, тому жодна production-операція не має
        # права виглядати успішною.
        $productionCancelLogMessage = 'Production operations cancelled because the confirmed discovery baseline could not be evaluated'
        $productionCancelResultError = 'Discovery baseline could not be evaluated'
    }

    if ($null -ne $productionCancelLogMessage) {
        Write-BRAVOLog -Component 'PATHS' -Message $productionCancelLogMessage -Level 'ERROR'
        # Кожен увімкнений компонент отримує явний результат-відмову: інакше
        # $results лишався порожнім, і РЕЗУЛЬТАТ показував "Створено архівів:
        # 0 з 0" замість "0 з 3", а причиною відмови помилково ставав перший-
        # ліпший наступний збій (напр. SFTP) замість справжнього.
        foreach ($archive in $enabledArchives) {
            if ($results.ContainsKey([string]$archive.Type)) { continue }
            $results[[string]$archive.Type] = @{
                ArchiveSuccess = $false
                HashSuccess = $false
                CreateSuccess = $false
                IntegritySuccess = $false
                ErrorStage = 'CONFIGURATION'
                Error = $productionCancelResultError
                ToolFailure = $null
            }
        }
        $readyArchives = @()
        $bazaAppSourceAvailable = $false
        $bazaAppDestinationAvailable = $false
        $bazaWWWSourceAvailable = $false
        $bazaWWWDestinationAvailable = $false
        $operationFailed = $true
    } elseif ($probeFailedComponents.Count -gt 0) {
        # Вимикаємо ЛИШЕ ті компоненти, чий власний probe не пройшов: решта
        # архівуються, а generation стає INCOMPLETE замість FAILED.
        foreach ($probeFailedComponent in @($probeFailedComponents)) {
            Write-BRAVOLog -Component 'PATHS' -Message "Компонент ${probeFailedComponent} пропущено: SYSTEM access probe для його шляхів не пройдено" -Level 'ERROR'
            $results[$probeFailedComponent] = @{
                ArchiveSuccess = $false
                HashSuccess = $false
                CreateSuccess = $false
                IntegritySuccess = $false
                ErrorStage = 'CONFIGURATION'
                Error = 'SYSTEM access preflight failed for this component'
                ToolFailure = $null
            }
        }
        $failedComponentNames = @($probeFailedComponents)
        $readyArchives = @($readyArchives | Where-Object { $failedComponentNames -notcontains [string]$_.Type })
    }
    # #158 (етап 3): компоненти з дрейфом вимикаються поіменно — той самий
    # принцип, що й $probeFailedComponents вище. Робиться ПІСЛЯ probe-блоку,
    # щоб не дублювати механіку вимкнення, і лише коли прогін не скасовано
    # цілком (інакше вимикати вже нема чого).
    if ($null -eq $productionCancelLogMessage -and $driftFailedComponents.Count -gt 0) {
        foreach ($driftComponent in $driftFailedComponents) {
            if ($driftComponent -eq 'BAZA_APP') {
                $bazaAppSourceAvailable = $false
                continue
            }
            if ($driftComponent -eq 'BAZA_WWW') {
                $bazaWWWSourceAvailable = $false
                continue
            }
            if ($results.ContainsKey($driftComponent)) { continue }
            $results[$driftComponent] = @{
                ArchiveSuccess = $false
                HashSuccess = $false
                CreateSuccess = $false
                IntegritySuccess = $false
                ErrorStage = 'CONFIGURATION'
                Error = 'Discovery baseline drift: component state does not match the confirmed baseline'
                ToolFailure = $null
            }
        }
        $readyArchives = @($readyArchives | Where-Object {
            $driftFailedComponents -notcontains [string]$_.Type
        })
        $operationFailed = $true
    }

    if (-not $systemAccessValid) {
        $operationFailed = $true
    }

    # dev.16: "Перевірка шляхів" рендериться ТУТ — ПІСЛЯ і existence-
    # перевірок (Test-PathWithLog вище), і фактичного SYSTEM write/read
    # access preflight (щойно вище), не до нього. OK лише коли ОБИДВІ
    # групи пройшли; Details — компактний підсумок кількості провалів,
    # повні шляхи й помилки лишаються в LOG (Show-PathCheckSummary/
    # Write-BRAVOLog вище).
    $pathCheckFullyValid = $allPathsExist -and $systemAccessValid
    Write-BRAVOArchiveStep `
        -Name "Перевірка шляхів" `
        -Status $(if ($pathCheckFullyValid) { 'OK' } else { 'ERROR' }) `
        -Details $(if ($pathCheckFullyValid) { '' } else { "недоступних шляхів/перевірок: $pathCheckFailureCount" })

    # Синхронізація BAZA APP
    # dev.16: top-level Archive operation — власний numbered step, коли
    # реально увімкнена (Total уже враховує це вище); вимкнений компонент
    # і далі не займає рядка й не входить у знаменник. ERROR/WARNING
    # відповідно до ІСНУЮЧОЇ семантики нижче (шлях недоступний -> ERROR,
    # Sync-Folders повернув false -> WARNING) — сама семантика не змінена.
    $bazaAppSyncStartedAt = Get-Date
    if ($bazaAppLocalSyncEnabled -and $bazaAppSourceAvailable -and $bazaAppDestinationAvailable) {
        Show-ScriptProgress -Status "Локальна синхронiзацiя BAZA APP" -PercentComplete 20
        Write-Log "==="
        Write-Log "=== СИНХРОНIЗАЦIЯ BAZA APP ==="
        $syncSuccess = Sync-Folders -SourcePath $bazaAppPaths.Source -DestinationPath $bazaAppPaths.Destination

        if ($syncSuccess) {
            Write-Log "Синхронiзацiя BAZA APP успiшна" -Level "SUCCESS"
        } else {
            Write-Log "Помилка синхронiзацiї BAZA APP - архiвацiя може бути неповною" -Level "WARNING"
            $operationFailed = $true
        }
        Write-BRAVOArchiveStep `
            -Name "Локальна синхронізація BAZA_APP" `
            -Status $(if ($syncSuccess) { 'OK' } else { 'WARNING' }) `
            -Duration ((Get-Date) - $bazaAppSyncStartedAt)
    } elseif ($bazaAppLocalSyncEnabled) {
        Write-Log "Локальну синхронiзацiю BAZA APP пропущено через помилку шляху" -Level "ERROR"
        $operationFailed = $true
        Write-BRAVOArchiveStep `
            -Name "Локальна синхронізація BAZA_APP" `
            -Status 'ERROR' `
            -Duration ((Get-Date) - $bazaAppSyncStartedAt) `
            -Details 'недоступне джерело або каталог призначення; деталі у журналі.'
    } else {
        Write-Log "Локальну синхронiзацiю BAZA APP вимкнено в конфiгурацiї" -Level "INFO"
    }

    # Синхронізація BAZA WWW (локальна копія)
    $bazaWWWSyncStartedAt = Get-Date
    if ($bazaWWWLocalSyncEnabled -and $bazaWWWSourceAvailable -and $bazaWWWDestinationAvailable) {
        Show-ScriptProgress -Status "Локальна синхронiзацiя BAZA WWW" -PercentComplete 20
        Write-Log "==="
        Write-Log "=== СИНХРОНIЗАЦIЯ BAZA WWW ==="
        $syncSuccess = Sync-Folders -SourcePath $bazaWWWPaths.Source -DestinationPath $bazaWWWPaths.Destination

        if ($syncSuccess) {
            Write-Log "Синхронiзацiя BAZA WWW успiшна" -Level "SUCCESS"
        } else {
            Write-Log "Помилка синхронiзацiї BAZA WWW - архiвацiя може бути неповною" -Level "WARNING"
            $operationFailed = $true
        }
        Write-BRAVOArchiveStep `
            -Name "Локальна синхронізація BAZA_WWW" `
            -Status $(if ($syncSuccess) { 'OK' } else { 'WARNING' }) `
            -Duration ((Get-Date) - $bazaWWWSyncStartedAt)
    } elseif ($bazaWWWLocalSyncEnabled) {
        Write-Log "Локальну синхронiзацiю BAZA WWW пропущено через помилку шляху" -Level "ERROR"
        $operationFailed = $true
        Write-BRAVOArchiveStep `
            -Name "Локальна синхронізація BAZA_WWW" `
            -Status 'ERROR' `
            -Duration ((Get-Date) - $bazaWWWSyncStartedAt) `
            -Details 'недоступне джерело або каталог призначення; деталі у журналі.'
    } else {
        Write-Log "Локальну синхронiзацiю BAZA WWW вимкнено в конфiгурацiї" -Level "INFO"
    }

    # Створення архівів.
    #
    # ОДИН VSS Snapshot Set на всю generation створюється ДО циклу і
    # видаляється лише після нього. Раніше знімок робився всередині циклу
    # перед кожним компонентом — MODEL о 15:43, BLOG о 15:51, BRAVOEXCH о
    # 15:55 — і три файли одного "backup" фіксували три різні стани
    # працюючої системи. Відновлення з такого комплекту дає неузгоджену базу.
    $archiveIndex = 0
    $generationId = if ($readyArchives.Count -gt 0) {
        Get-BRAVOCollisionSafeGenerationId `
            -BaseGenerationId $backupGenerationId `
            -Archives $readyArchives `
            -ArchivePrefix $archivePrefix `
            -HashExtension $hashFileExtension
    } else {
        $backupGenerationId
    }
    if ($generationId -ne $backupGenerationId) {
        Write-Log "GenerationId $backupGenerationId уже має фінальні backup-артефакти; нову generation заплановано як $generationId" -Level "WARNING"
    }
    $script:backupGenerationId = $generationId
    $generationSnapshotSet = $null
    $generationResults = New-Object System.Collections.Generic.List[object]
    $generationFinalizationFailed = $false
    $generationFinalizationFailureReason = $null

    try {
        if ($readyArchives.Count -gt 0) {
            Write-Log "==="
            Write-Log "=== VSS SNAPSHOT SET ДЛЯ GENERATION $generationId ==="
            Show-ScriptProgress -Status "Створення VSS Snapshot Set" -PercentComplete 28
            try {
                $generationSnapshotSet = New-BRAVOVSSSnapshotSet `
                    -SourcePaths @($readyArchives | ForEach-Object { [string]$_.Source })
                try {
                    [void](Save-BRAVOVSSOwnershipState `
                        -StatePath $vssOwnershipStatePath `
                        -SnapshotSet $generationSnapshotSet `
                        -GenerationId $generationId)
                } catch {
                    # Continuing without an ownership record would make a
                    # hard-killed process leave snapshots that cannot be
                    # distinguished safely from third-party VSS resources.
                    [void](Remove-BRAVOVSSSnapshotSet -SnapshotSet $generationSnapshotSet)
                    $generationSnapshotSet = $null
                    throw "VSS ownership state could not be persisted: $($_.Exception.Message)"
                }
            } catch {
                # Жодного live fallback: архівувати робочі каталоги замість
                # знімка означало б віддати неузгоджену копію під виглядом
                # backup. Краще не мати нового backup, ніж мати такий.
                Write-Log "VSS SNAPSHOT SET FAILED: $($_.Exception.Message)" -Level "ERROR"
                Write-Log "Архівацію MODEL/BLOG/BRAVOEXCH скасовано: узгоджена копія без VSS неможлива, а архівація «живих» каталогів заборонена" -Level "ERROR"
                $generationSnapshotSet = $null
                $operationFailed = $true
                foreach ($archive in $readyArchives) {
                    $vssFailureResult = [pscustomobject]@{
                        Component = $archive.Type
                        GenerationId = $generationId
                        OriginalSourcePath = [string]$archive.Source
                        SnapshotSourcePath = $null
                        TemporaryArchivePath = $null
                        ArchivePath = $null
                        HashPath = $null
                        CreateSuccess = $false
                        IntegritySuccess = $false
                        HashSuccess = $false
                        ArchiveSize = $null
                        SHA512 = $null
                        ErrorStage = 'VSS'
                        Error = $_.Exception.Message
                    }
                    $generationResults.Add($vssFailureResult)
                    $results[$archive.Type] = @{
                        ArchiveSuccess = $false
                        HashSuccess = $false
                        CreateSuccess = $false
                        IntegritySuccess = $false
                        GenerationId = $generationId
                        ErrorStage = 'VSS'
                        Error = $_.Exception.Message
                        ToolFailure = [pscustomobject]@{
                            Tool = 'VSS'
                            ToolExitCodeText = $null
                            ReasonText = "VSS: $($_.Exception.Message)"
                        }
                    }
                    Write-BRAVOArchiveStep `
                        -Name ("Архівація {0}" -f $archive.Type) `
                        -Status 'ERROR' `
                        -Duration ([timespan]::Zero)
                    Write-BRAVOOperatorReason `
                        -Reason "VSS Snapshot Set не створено — архівація без узгодженого знімка заборонена" `
                        -Details ("Не вдалося створити архів {0}" -f $archive.Type)
                }
                $readyArchives = @()
            }
        }

        foreach ($archive in $readyArchives) {
            $archiveIndex++
            $archiveProgress = 30 + [Math]::Floor((($archiveIndex - 1) / [Math]::Max(1, $readyArchives.Count)) * 40)
            # Канонічний формат підетапу (Format-BRAVOSubstepPhase) — той
            # самий для архівації/SFTP/NAS: оператор завжди бачить, ЯКИЙ
            # компонент виконується і його позицію (N з Total).
            Show-ScriptProgress `
                -Status (Format-BRAVOSubstepPhase -Name "Архiвацiя $($archive.Type)" -Current $archiveIndex -Total $readyArchives.Count) `
                -PercentComplete $archiveProgress
            $archiveName = $archive.NameTemplate -f $archivePrefix, $generationId
            Write-Log "==="
            Write-Log "=== АРХIВАЦIЯ $($archive.Type) ==="
            $archiveStepStarted = Get-Date
            $script:lastArchiveToolFailure = $null
            $componentResult = $null
            $snapshotSourcePath = $null
            try {
                $snapshotSourcePath = Resolve-BRAVOSnapshotSourcePath `
                    -SnapshotSet $generationSnapshotSet `
                    -OriginalPath $archive.Source
                $componentResult = Invoke-BRAVOComponentBackup `
                    -Component $archive.Type `
                    -GenerationId $generationId `
                    -OriginalSourcePath ([string]$archive.Source) `
                    -SourcePath $snapshotSourcePath `
                    -DestinationDirectory $archive.Destination `
                    -ArchiveName $archiveName `
                    -ArcPath $arcPath `
                    -ArcParams $archiveParams
            } catch {
                Write-Log "Не вдалося виконати узгоджену VSS-архівацію $($archive.Type): $($_.Exception.Message)" -Level "ERROR"
                $componentResult = [pscustomobject]@{
                    Component = $archive.Type
                    GenerationId = $generationId
                    OriginalSourcePath = [string]$archive.Source
                    SnapshotSourcePath = $snapshotSourcePath
                    TemporaryArchivePath = $null
                    ArchivePath = $null
                    HashPath = $null
                    CreateSuccess = $false
                    IntegritySuccess = $false
                    HashSuccess = $false
                    ArchiveSize = $null
                    SHA512 = $null
                    ErrorStage = 'VSS'
                    Error = $_.Exception.Message
                }
            }
            $generationResults.Add($componentResult)

            $success = [bool]$componentResult.CreateSuccess -and [bool]$componentResult.IntegritySuccess
            $hashSuccess = [bool]$componentResult.HashSuccess
            # Публікація відбувається лише після SHA512, тому "архів є" і
            # "hash є" — тепер одна подія, а не дві незалежні.
            $componentPublished = $success -and $hashSuccess

            if ($componentPublished) {
                # dev.19: заголовок "=== СТВОРЕННЯ ХЕШУ ===" тепер друкує
                # сам Invoke-BRAVOComponentBackup, безпосередньо перед
                # New-SHA512Hash (хронологічно правильна позиція) — не тут,
                # уже ПІСЛЯ повного завершення виклику. Show-ScriptProgress
                # нижче — прогрес-бар, не журнал, лишається на своєму місці.
                $hashProgress = [Math]::Min(69, $archiveProgress + 8)
                Show-ScriptProgress `
                    -Status (Format-BRAVOSubstepPhase -Name "SHA512 для $($archive.Type)" -Current $archiveIndex -Total $readyArchives.Count) `
                    -PercentComplete $hashProgress
                $results[$archive.Type] = @{
                    ArchivePath = $componentResult.ArchivePath
                    HashPath = $componentResult.HashPath
                    ArchiveSuccess = $true
                    HashSuccess = $true
                    CreateSuccess = $true
                    IntegritySuccess = $true
                    GenerationId = $generationId
                    SHA512 = $componentResult.SHA512
                    ErrorStage = $null
                    Error = $null
                    ToolFailure = $null
                }
            } else {
                $results[$archive.Type] = @{
                    ArchiveSuccess = $false
                    HashSuccess = $false
                    CreateSuccess = [bool]$componentResult.CreateSuccess
                    IntegritySuccess = [bool]$componentResult.IntegritySuccess
                    GenerationId = $generationId
                    ErrorStage = [string]$componentResult.ErrorStage
                    Error = [string]$componentResult.Error
                    # Per-компонент, а не єдина script-scope змінна: якщо
                    # відмовить кілька компонентів поспіль, фінальний РЕЗУЛЬТАТ
                    # має показати причину САМЕ першого відмовленого, а не
                    # випадково останню з циклу.
                    ToolFailure = $script:lastArchiveToolFailure
                }
                $operationFailed = $true
            }

            # Розмір показуємо в консолі коротко (component-блок нижче); повні
            # шляхи, аргументи 7-Zip і його вивід лишаються в журналі.
            $archiveStepDuration = (Get-Date) - $archiveStepStarted
            $sizeAnomalyResult = $null
            $createdArchiveSize = $null
            if ($componentPublished) {
                $createdArchivePath = [string]$componentResult.ArchivePath
                if (Test-Path -LiteralPath $createdArchivePath -PathType Leaf) {
                    $createdArchiveSize = [int64]$componentResult.ArchiveSize

                    # AUD-008 (аудит P1.6): sanity-check обсягу — технічно
                    # валідний архів все одно може бути підозріло малим через
                    # неправильне джерело чи зламані permissions. Не блокує
                    # (лишає ArchiveSuccess/HashSuccess як є), лише сигналізує.
                    if ([bool]$backupMonitoring.SizeSanity.Enabled) {
                        try {
                            $sizeAnomalyResult = Test-BRAVOBackupSizeAnomaly `
                                -NewArchiveBytes $createdArchiveSize `
                                -HistoryDirectory $archive.Destination `
                                -ArchiveFilter $archiveFileFilter `
                                -HashFileExtension $hashFileExtension `
                                -ExcludeArchivePath $createdArchivePath `
                                -HistoryCount ([int]$backupMonitoring.SizeSanity.HistoryCount) `
                                -MinimumBytes ([int64]$backupMonitoring.SizeSanity.MinimumBytes) `
                                -MaxSizeDropPercent ([int]$backupMonitoring.SizeSanity.MaxSizeDropPercent)
                            if ([bool]$sizeAnomalyResult.IsAnomaly) {
                                Write-Log "Підозрілий розмір архіву $($archive.Type): $($sizeAnomalyResult.Reason)" -Level "WARNING"
                            }
                        } catch {
                            Write-Log "Не вдалося виконати sanity-check обсягу для $($archive.Type): $($_.Exception.Message)" -Level "WARNING"
                        }
                    }
                    $results[$archive.Type].Bytes = $createdArchiveSize
                    $results[$archive.Type].SizeAnomaly = $sizeAnomalyResult
                    if ([bool]$componentResult.LegacyBomPasswordFallbackUsed) {
                        $results[$archive.Type].LegacyBomPasswordFallbackUsed = $true
                    }
                }
            }
            $archiveStepStatus = if (-not $success) {
                'ERROR'
            } elseif (-not $hashSuccess) {
                'ERROR'
            } elseif ($null -ne $sizeAnomalyResult -and [bool]$sizeAnomalyResult.IsAnomaly) {
                'WARNING'
            } else {
                'OK'
            }
            Write-BRAVOArchiveStep `
                -Name ("Архівація {0}" -f $archive.Type) `
                -Status $archiveStepStatus `
                -Duration $archiveStepDuration

            # Component-деталі (docs/OPERATOR_CONSOLE_UX.md §2): показуються
            # ЛИШЕ коли artifact реально опубліковано. Створення, перевірка
            # цілісності й SHA512 — три окремі факти, тому в рядках нижче
            # немає жодного оптимістичного здогаду.
            if ($componentPublished) {
                Write-BRAVOConsoleDetail -Message ("Архів:".PadRight(11) + [IO.Path]::GetFileName([string]$componentResult.ArchivePath))
                Write-BRAVOConsoleDetail -Message ("Розмір:".PadRight(11) + (Format-BRAVOFileSize -Bytes $createdArchiveSize))
                Write-BRAVOConsoleDetail -Message ("SHA512:".PadRight(11) + 'OK')
                Write-BRAVOConsoleDetail -Message ("Integrity:".PadRight(11) + 'OK')
                if ($null -ne $sizeAnomalyResult -and [bool]$sizeAnomalyResult.IsAnomaly) {
                    Write-BRAVOOperatorReason -Reason $sizeAnomalyResult.Reason
                }
            } else {
                $failureReason = if ($null -ne $script:lastArchiveToolFailure) {
                    $script:lastArchiveToolFailure.ReasonText
                } elseif (-not [string]::IsNullOrWhiteSpace([string]$componentResult.Error)) {
                    "$($componentResult.ErrorStage): $($componentResult.Error)"
                } else {
                    "не вдалося створити архів $($archive.Type)"
                }
                Write-BRAVOOperatorReason -Reason $failureReason -Details ("Не вдалося створити архів {0}" -f $archive.Type)
            }
        }
    } finally {
        # Знімки живуть до кінця циклу й видаляються тут за будь-якого
        # результату: помилка одного компонента не має ані залишати shadow
        # copies в системі, ані псувати вже створені артефакти.
        if ($null -ne $generationSnapshotSet) {
            if (Remove-BRAVOVSSSnapshotSet -SnapshotSet $generationSnapshotSet) {
                try {
                    if ([IO.File]::Exists($vssOwnershipStatePath)) {
                        [IO.File]::Delete($vssOwnershipStatePath)
                    }
                } catch {
                    # Exact ownership metadata may safely survive cleanup. On
                    # the next run, absent IDs are treated as already removed.
                    Write-BRAVOLog -Component 'VSS' -Message "VSS ownership state cleanup deferred: $($_.Exception.Message)" -Level 'WARNING'
                }
            } else {
                # Keep ownership state so the next machine-wide lock owner can
                # retry deletion of these exact BRAVO-created Shadow IDs.
                $operationFailed = $true
            }
        }
    }

    # Статус generation: COMPLETE лише коли КОЖЕН увімкнений компонент
    # пройшов усі три стадії. INCOMPLETE — знімок був, але щось не дійшло до
    # публікації. FAILED — узгодженої копії не отримано взагалі.
    #
    # Уся фіналізація generation (підрахунок опублікованих, побудова state,
    # запис manifest) обгорнута в try/catch: раніше виняток тут (після
    # видалення VSS Snapshot Set, до Write-BRAVOBackupGenerationManifest)
    # тихо обривав увесь прогін — без Generation COMPLETE, без manifest, без
    # transfer/health, і НЕ потрапляв у BRAVO_ARCHIV log. Тепер повна
    # діагностика (тип/повідомлення/розташування/стек) гарантовано логується,
    # статус деградує, а виконання доходить до РЕЗУЛЬТАТ.
    $generationManifestPath = $null
    try {
        $publishedComponentCount = @(
            $generationResults | Where-Object {
                [bool]$_.CreateSuccess -and [bool]$_.IntegritySuccess -and [bool]$_.HashSuccess
            }
        ).Count
        $script:backupGenerationStatus = if ($null -eq $generationSnapshotSet -or $publishedComponentCount -eq 0) {
            'FAILED'
        } elseif ($publishedComponentCount -eq $enabledArchives.Count) {
            'COMPLETE'
        } else {
            'INCOMPLETE'
        }
        # Windows PowerShell 5.1 binder кидає System.ArgumentException
        # ("Argument types do not match") для @($genericList). Явно
        # materialize List[object], перш ніж передавати результати у state.
        $generationResultsArray = $generationResults.ToArray()
        $script:backupGenerationResults = $generationResultsArray
        $script:backupGenerationState = New-BRAVOBackupGenerationState `
            -GenerationId $generationId `
            -StartedAt $scriptStartTime `
            -SnapshotSet $generationSnapshotSet `
            -Components $generationResultsArray `
            -Status $script:backupGenerationStatus `
            -ComponentScope $(if ($null -ne $backupScope) { $backupScope.Components } else { $null })
        if ($enabledArchives.Count -gt 0) {
            try {
                $generationManifestPath = Write-BRAVOBackupGenerationManifest `
                    -GenerationState $script:backupGenerationState `
                    -BackupRoot $backupRootPath
            } catch {
                Write-Log "Не вдалося записати manifest generation ${generationId}: $($_.Exception.Message)" -Level "WARNING"
                $generationFinalizationFailed = $true
                $generationFinalizationFailureReason = $_.Exception.Message
                $script:backupGenerationStatus = 'FAILED'
                $script:backupGenerationState.Status = 'FAILED'
                $generationManifestPath = $null
                $operationFailed = $true
            }
        }
        if ($readyArchives.Count -gt 0 -or $enabledArchives.Count -gt 0) {
            $generationLogLevel = if ($script:backupGenerationStatus -eq 'COMPLETE') { 'SUCCESS' } else { 'WARNING' }
            Write-Log (
                "Generation ${generationId}: $($script:backupGenerationStatus) " +
                "(опубліковано $publishedComponentCount з $($enabledArchives.Count); " +
                "VSS Snapshot Set: $(if ($null -ne $generationSnapshotSet) { $generationSnapshotSet.SnapshotSetId } else { 'не створено' }))"
            ) -Level $generationLogLevel
        }
    } catch {
        Write-BRAVOLogException -ErrorRecord $_ -Component 'GENERATION' -Context "Помилка фіналізації generation ${generationId}"
        # Фіналізація не завершилась — узгодженого COMPLETE-стану немає.
        # Деградуємо статус (COMPLETE тут був би неправдою) і продовжуємо до
        # РЕЗУЛЬТАТ, щоб оператор побачив помилку й код завершення.
        if ([string]::IsNullOrWhiteSpace([string]$script:backupGenerationStatus) -or
            [string]$script:backupGenerationStatus -eq 'COMPLETE') {
            $script:backupGenerationStatus = 'FAILED'
        }
        $generationFinalizationFailed = $true
        $generationFinalizationFailureReason = $_.Exception.Message
        $operationFailed = $true
    }
    # Автоматичне створення й доповнення discovery baseline (рішення
    # власника 2026-10-01): лише після COMPLETE generation з чистою
    # перевіркою складу. Тоді компонент, що вже реально потрапив у
    # резервну копію, береться під захист від тихого зникнення без ручного
    # -ConfirmDiscoveryBaseline. Наявні записи baseline не змінюються.
    if (Test-BRAVOBackupBaselineUpdateAllowed `
            -GenerationStatus ([string]$script:backupGenerationStatus) `
            -BaselineValid ([bool]$discoveryBaselineValid) `
            -BackupScope $backupScope `
            -GenerationManifestPath ([string]$generationManifestPath)) {
        try {
            $baselineUpdate = Update-BRAVODiscoveryBaselineFromScope `
                -DiscoveryResult $bravoDiscoveryResult `
                -ScopeResult $backupScope `
                -StateRoot $stateRoot `
                -RuntimeRoot $runtimeRoot
            if ([string]$baselineUpdate.Action -eq 'Created') {
                Write-BRAVOLog -Component 'DISCOVERY' -Message (
                    "Discovery baseline створено автоматично після COMPLETE generation ${generationId}: " +
                    "під захистом від зникнення $(@($baselineUpdate.AddedComponents) -join ', ')"
                ) -Level 'INFO'
            } elseif ([string]$baselineUpdate.Action -eq 'Extended') {
                Write-BRAVOLog -Component 'DISCOVERY' -Message (
                    "Новий компонент узято під захист у discovery baseline: $(@($baselineUpdate.AddedComponents) -join ', ')"
                ) -Level 'INFO'
            }
        } catch {
            Write-BRAVOLog -Component 'DISCOVERY' -Message (
                "Не вдалося автоматично оновити discovery baseline: $($_.Exception.Message)"
            ) -Level 'WARNING'
        }
    }
    Show-ItemProgress -Id 10 -Activity "BRAVO_ARCHIV — архiвацiя компонентiв" -Completed

    # Зведена Operations-подія на generation НЕ надсилається тут (review
    # finding, thread 11): у цій точці відомий лише
    # $script:backupGenerationStatus, а retention cleanup, SFTP/SMB-
    # трансфер, post-backup health-check і фінальний запис маніфесту ще
    # НЕ виконані — кожен із них може підняти $operationFailed і дати
    # ненульовий код завершення. Подія, надіслана звідси, показувала б у
    # dashboard SUCCESS для прогону, який фактично завершився помилкою, а
    # її stages-список не містив би саме провалених фаз. Надсилання
    # перенесено ПІСЛЯ резолюції $script:processExitCode — той самий
    # канонічний патерн, що Send-BRAVOMaintenanceOperationsEvent
    # (BRAVO.Maintenance.Runtime.ps1), який приймає вже обчислений
    # ExitCode. Шукайте "Operations-подія generation" нижче.

    # dev.16: одна аггрегована unnumbered-операція "Очищення старих backup
    # generation" покриває обидва блоки нижче (generation retention, що
    # всередині Remove-BRAVOExpiredBackupGenerations також прибирає
    # invalid/incomplete сети, + очищення обідніх архівів). Жодних окремих
    # рядків на кожен внутрішній фільтр. Retention days/filters/delete
    # semantics нижче не змінені.
    $backupRetentionCleanupStartedAt = Get-Date
    $backupRetentionCleanupPlanned = [bool]($enableArchiveDeletion -or $enableFailedArchiveDeletion -or $enableLunchArchiveCleanup -or $enableOrphanTempCleanup)
    $generationCleanupAttempted = $false
    $generationCleanupSucceeded = $true
    $generationCleanupDeletedCount = 0
    # dev.16 (review round 3): ініціалізується ТУТ (не лише всередині
    # if-гілки нижче) — інакше під Set-StrictMode посилання на неї в
    # агрегованому результаті нижче кидає виняток, коли generation
    # retention вимкнено/generation ще не COMPLETE цього прогону.
    $archiveCleanupSectionShown = $false
    $lunchCleanupAttempted = $false
    $lunchCleanupSucceeded = $true
    $lunchCleanupConfigError = $false
    $lunchCleanupDeletedCount = 0

    # Видалення старих архівів: розділ логу з'являється лише перед фактичним видаленням.
    if (($enableArchiveDeletion -or $enableFailedArchiveDeletion) -and
        $script:backupGenerationStatus -eq 'COMPLETE') {
        $effectiveArchiveRetentionDays = 183
        # archiveVersions є лише у старих конфігах, тому читаємо його безпечно:
        # пряме звернення до неоголошеної змінної переривало б цю гілку.
        $legacyArchiveVersionsVariable = Get-Variable -Name 'archiveVersions' -Scope Global -ErrorAction SilentlyContinue
        $legacyArchiveVersions = if ($null -ne $legacyArchiveVersionsVariable) { $legacyArchiveVersionsVariable.Value } else { $null }
        try {
            if ($null -ne $archiveRetentionDays -and [int]$archiveRetentionDays -gt 0) {
                $effectiveArchiveRetentionDays = [int]$archiveRetentionDays
            } elseif ($null -ne $legacyArchiveVersions -and [int]$legacyArchiveVersions -gt 0) {
                # Сумісність із конфігами до archiveRetentionDays. Значення
                # archiveVersions використовуємо як строк у днях лише під час міграції.
                $effectiveArchiveRetentionDays = [int]$legacyArchiveVersions
                Write-Log "Застарілий archiveVersions=$effectiveArchiveRetentionDays застосовано як строк зберігання у днях; перенесіть значення до archiveRetentionDays" -Level "WARNING"
            } else {
                Write-Log "archiveRetentionDays відсутній або некоректний; для безпеки застосовано $effectiveArchiveRetentionDays днів" -Level "WARNING"
            }
        } catch {
            Write-Log "archiveRetentionDays не вдалося прочитати; для безпеки застосовано $effectiveArchiveRetentionDays днів" -Level "WARNING"
        }
        $archiveCleanupSectionShown = $false
        $generationCleanupAttempted = $true
        if (-not (Remove-BRAVOExpiredBackupGenerations `
                -BackupRoot $backupRootPath `
                -CurrentGenerationId $generationId `
                -RetentionDays $effectiveArchiveRetentionDays `
                -CleanupSectionShown ([ref]$archiveCleanupSectionShown) `
                -RemovedGenerationCount ([ref]$generationCleanupDeletedCount) `
                -ArchiveDefinitions @($archiveDefinitions))) {
            $operationFailed = $true
            $generationCleanupSucceeded = $false
        }
    }

    if ($enableLunchArchiveCleanup) {
        $effectiveLunchArchiveRetentionMonths = 2
        try {
            if ($null -ne $lunchArchiveRetentionMonths -and [int]$lunchArchiveRetentionMonths -gt 0) {
                $effectiveLunchArchiveRetentionMonths = [int]$lunchArchiveRetentionMonths
            } else {
                Write-Log "lunchArchiveRetentionMonths відсутній або некоректний; для безпеки застосовано $effectiveLunchArchiveRetentionMonths місяці" -Level "WARNING"
            }
        } catch {
            Write-Log "lunchArchiveRetentionMonths не вдалося прочитати; для безпеки застосовано $effectiveLunchArchiveRetentionMonths місяці" -Level "WARNING"
        }

        $lunchArchiveDirectories = @($lunchArchiveCleanupDirectories | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        })
        if ([string]::IsNullOrWhiteSpace([string]$lunchArchiveCleanupPath) -or $lunchArchiveDirectories.Count -eq 0) {
            Write-Log "Очищення обідніх архівів увімкнено, але lunchArchiveCleanupPath або lunchArchiveCleanupDirectories не налаштовано" -Level "ERROR"
            $operationFailed = $true
            $lunchCleanupAttempted = $true
            $lunchCleanupConfigError = $true
        } else {
            $lunchCleanupAttempted = $true
            if (-not (Remove-OldLunchArchives `
                -ArchiveRoot $lunchArchiveCleanupPath `
                -Directories $lunchArchiveDirectories `
                -RetentionMonths $effectiveLunchArchiveRetentionMonths `
                -RemovedFileCount ([ref]$lunchCleanupDeletedCount))) {
                $operationFailed = $true
                $lunchCleanupSucceeded = $false
            }
        }
    }

    # Осиротілі .work\*.partial* — залишок МИНУЛОГО перерваного прогону, не
    # результат СЬОГОДНІШНЬОГО backupGenerationStatus, тому цей блок свідомо
    # НЕ вкладений у "-and $script:backupGenerationStatus -eq 'COMPLETE'"
    # вище: сьогоднішня невдача не повинна блокувати прибирання чужого
    # минулого сміття. Ексклюзивний Enter-BRAVOArchiveProcessLock (тримається
    # увесь прогін) виключає паралельний другий Archive/Maintenance —
    # orphanTempRetentionHours лише додатковий запобіжник проти видалення
    # артефакту повільного, але ще легітимно активного прогону.
    $orphanCleanupAttempted = $false
    $orphanCleanupSucceeded = $true
    $orphanCleanupDeletedCount = 0
    if ($enableOrphanTempCleanup) {
        $orphanCleanupAttempted = $true
        $effectiveOrphanTempRetentionHours = if ($null -ne $orphanTempRetentionHours -and [int]$orphanTempRetentionHours -gt 0) {
            [int]$orphanTempRetentionHours
        } else { 48 }
        if (-not (Remove-BRAVOOrphanedTemporaryArchiveArtifacts `
                -ArchiveDefinitions $archiveDefinitions `
                -RetentionHours $effectiveOrphanTempRetentionHours `
                -RemovedFileCount ([ref]$orphanCleanupDeletedCount))) {
            $operationFailed = $true
            $orphanCleanupSucceeded = $false
        }
    }

    $backupRetentionCleanupAttempted = $generationCleanupAttempted -or $lunchCleanupAttempted -or $orphanCleanupAttempted
    $backupRetentionCleanupFailed = (-not $generationCleanupSucceeded) -or $lunchCleanupConfigError -or (-not $lunchCleanupSucceeded) -or (-not $orphanCleanupSucceeded)
    # dev.16 (review round 3): OK лише коли щось РЕАЛЬНО видалено —
    # attempted+succeeded-без-видалень тепер SKIPPED "даних для очищення
    # немає", не OK. Факт-сигнали: $archiveCleanupSectionShown встановлює
    # Show-ArchiveCleanupSection ЛИШЕ безпосередньо перед фактичним
    # видаленням generation (не при самій лише перевірці); $lunchCleanupDeletedCount —
    # реальний $deletedCount, який Remove-OldLunchArchives вже рахує для
    # LOG. Обидва значення — факт, не вигадані числа.
    $backupRetentionCleanupDidDelete = [bool]$archiveCleanupSectionShown -or ($lunchCleanupDeletedCount -gt 0) -or ($orphanCleanupDeletedCount -gt 0)
    # dev.18: numbered [N/TOTAL] крок — раніше unnumbered
    # Write-BRAVOOperationResult. $backupRetentionCleanupPlanned (той
    # самий вираз, що Total вище і План) тепер вирішує, чи крок
    # РЕНДЕРИТЬСЯ ВЗАГАЛІ (повністю вимкнено -> жодного рядка, жодного
    # SKIPPED-заповнювача), а не лише його статус — Total і фактична
    # наявність рядка більше не можуть розійтися. Позиція виклику (після
    # публікації всіх component, до "Передача на SFTP") не змінена.
    if ($backupRetentionCleanupPlanned) {
        Write-BRAVOArchiveStep `
            -Name 'Очищення старих backup generation' `
            -Status $(
                if ($backupRetentionCleanupFailed) { 'ERROR' }
                elseif (-not $backupRetentionCleanupAttempted) { 'SKIPPED' }
                elseif (-not $backupRetentionCleanupDidDelete) { 'SKIPPED' }
                else { 'OK' }
            ) `
            -Duration ((Get-Date) - $backupRetentionCleanupStartedAt) `
            -Details $(
                if ($backupRetentionCleanupFailed) { 'перевірте LOG для деталей' }
                elseif (-not $backupRetentionCleanupAttempted) { 'відкладено: generation не завершено COMPLETE у цьому циклі' }
                elseif (-not $backupRetentionCleanupDidDelete) { 'даних для очищення немає' }
                else {
                    $retentionCleanupDetailParts = @()
                    if ($generationCleanupDeletedCount -gt 0) {
                        $retentionCleanupDetailParts += "generation: $generationCleanupDeletedCount"
                    }
                    if ($lunchCleanupDeletedCount -gt 0) {
                        $retentionCleanupDetailParts += "обідніх файлів: $lunchCleanupDeletedCount"
                    }
                    if ($orphanCleanupDeletedCount -gt 0) {
                        $retentionCleanupDetailParts += "осиротілих артефактів: $orphanCleanupDeletedCount"
                    }
                    $retentionCleanupDetailParts -join '; '
                }
            )
    }
    
    # Передача на SFTP
    # Статус етапу визначаємо за приростом кількості ERROR у журналі: прапорець
    # $operationFailed накопичується з попередніх фаз і показав би збій навіть
    # тоді, коли саме передавання пройшло успішно.
    $errorsBeforeSftp = (Get-BRAVOLogStatistics).Errors
    # Читається у фінальному резолвері коду виходу незалежно від того, чи
    # передача на SFTP взагалі увімкнена — інакше змінна лишається
    # неоголошеною, коли компонент вимкнено, і StrictMode кидає виняток.
    $sftpStepFailed = $false
    if ($sftpTransferEnabled) {
        Show-ScriptProgress -Status "Перевiрка з'єднання з SFTP" -PercentComplete 78
        if (-not $sftpConfigurationValid) {
            Write-Log "Передачу на SFTP пропущено через помилки конфiгурацiї" -Level "ERROR"
            $operationFailed = $true
        } elseif (-not (Test-SFTPConnection -WinSCPPath $winSCPPath -RepositorySFTPUrl $sftpUrl -HostKey $sftpHostKey)) {
            Write-Log "Помилка пiдключення до SFTP - пропускаємо передачу" -Level "ERROR"
            $operationFailed = $true
        } else {
            $requiredSFTPDirectories = @()
            if ($sftpArchiveUploadEnabled) {
                $requiredSFTPDirectories += @(
                    $enabledArchives | ForEach-Object { [string]$sftpDirectories[$_.Type] }
                )
                if (-not [string]::IsNullOrWhiteSpace($generationManifestPath)) {
                    $requiredSFTPDirectories += [string]$sftpDirectories.Manifest
                }
            }
            if ($bazaAppSFTPSyncEnabled) {
                $requiredSFTPDirectories += [string]$sftpDirectories.BAZA
            }
            if ($bazaWWWSFTPSyncEnabled) {
                $requiredSFTPDirectories += [string]$sftpDirectories.BAZAWWW
            }
            Initialize-BRAVOSFTPRemoteDirectories `
                -WinSCPPath $winSCPPath `
                -RepositorySFTPUrl $sftpUrl `
                -HostKey $sftpHostKey `
                -RemoteDirectories $requiredSFTPDirectories

            if ($sftpArchiveUploadEnabled) {
                $transferResults.ArchiveUpload.Attempted = $true
                $uploadSuccess = 0
                $uploadQueue = @()

                # Формуємо чергу у стабільному порядку компонентів, щоб відсоток
                # і лічильник файлів не змінювали порядок між запусками.
                foreach ($archive in $enabledArchives) {
                    $archiveType = $archive.Type
                    if ($results.ContainsKey($archiveType) -and
                        $results[$archiveType].ArchiveSuccess -and
                        $results[$archiveType].HashSuccess) {
                        $uploadQueue += [pscustomobject]@{
                            LocalPath = [string]$results[$archiveType].ArchivePath
                            RemoteDirectory = [string]$sftpDirectories[$archiveType]
                            Component = [string]$archiveType
                        }
                        $uploadQueue += [pscustomobject]@{
                            LocalPath = [string]$results[$archiveType].HashPath
                            RemoteDirectory = [string]$sftpDirectories[$archiveType]
                            Component = [string]$archiveType
                        }
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($generationManifestPath) -and
                    (Test-Path -LiteralPath $generationManifestPath -PathType Leaf)) {
                    $uploadQueue += [pscustomobject]@{
                        LocalPath = $generationManifestPath
                        RemoteDirectory = [string]$sftpDirectories.Manifest
                        Component = 'manifest'
                    }
                }

                $uploadTotal = $uploadQueue.Count
                $transferResults.ArchiveUpload.Total = $uploadTotal
                # Операторський рівень прогресу — КОМПОНЕНТНИЙ (MODEL/BLOG/
                # BRAVOEXCH), а не файловий: mdz+sha512 одного компонента —
                # один visible підетап; manifest — окрема коротка фаза без
                # позиції. Тому "(1 з 3)", а не "(1 з 7)". Файлові операції
                # й далі детально логуються у файл, як раніше.
                $uploadComponentOrder = @(
                    $uploadQueue | Where-Object { $_.Component -ne 'manifest' } |
                        ForEach-Object { $_.Component } | Select-Object -Unique
                )
                $uploadComponentTotal = $uploadComponentOrder.Count
                if ($uploadTotal -gt 0) {
                    Show-ScriptProgress -Status "Завантаження архiвiв на SFTP" -PercentComplete 82
                    Write-Log "==="
                    Write-Log "=== ЗАВАНТАЖЕННЯ АРХIВIВ НА SFTP ==="
                }
                $currentUploadComponent = $null
                foreach ($uploadItem in $uploadQueue) {
                    if ($uploadItem.Component -ne $currentUploadComponent) {
                        $currentUploadComponent = $uploadItem.Component
                        if ($currentUploadComponent -eq 'manifest') {
                            Show-ScriptProgress -Status "Завантаження manifest на SFTP" -PercentComplete 89
                        } else {
                            $uploadComponentIndex = ([array]::IndexOf($uploadComponentOrder, $currentUploadComponent) + 1)
                            $uploadComponentProgress = 82 + [Math]::Floor((($uploadComponentIndex - 1) * 7) / [Math]::Max(1, $uploadComponentTotal))
                            Show-ScriptProgress `
                                -Status (Format-BRAVOSubstepPhase -Name "Завантаження $currentUploadComponent на SFTP" -Current $uploadComponentIndex -Total $uploadComponentTotal) `
                                -PercentComplete $uploadComponentProgress
                        }
                    }
                    $fileUploaded = Send-FileViaWinSCP `
                        -WinSCPPath $winSCPPath `
                        -RepositorySFTPUrl $sftpUrl `
                        -HostKey $sftpHostKey `
                        -LocalFilePath $uploadItem.LocalPath `
                        -RemoteDirectory $uploadItem.RemoteDirectory
                    if ($fileUploaded) {
                        $uploadSuccess++
                    }
                }

                if ($uploadTotal -gt 0) {
                    $transferResults.ArchiveUpload.Completed = $uploadSuccess
                    $transferResults.ArchiveUpload.Remaining = $uploadTotal - $uploadSuccess
                    $transferResults.ArchiveUpload.Success = ($uploadSuccess -eq $uploadTotal)
                    $uploadLevel = if ($uploadSuccess -eq $uploadTotal) { "SUCCESS" } else { "ERROR" }
                    Write-Log "Завантажено $uploadSuccess з $uploadTotal файлiв на SFTP" -Level $uploadLevel
                    if ($uploadSuccess -ne $uploadTotal) {
                        $transferResults.ArchiveUpload.Error = "завантажено $uploadSuccess з $uploadTotal файлів"
                        $operationFailed = $true
                    }
                } else {
                    $transferResults.ArchiveUpload.Success = ($enabledArchives.Count -eq 0)
                    $transferResults.ArchiveUpload.Remaining = 0
                    Write-Log "Немає успiшно створених архiвiв для завантаження на SFTP" -Level "WARNING"
                    if ($enabledArchives.Count -gt 0) {
                        $transferResults.ArchiveUpload.Error = 'немає опублікованих локальних архівів для передачі'
                        $operationFailed = $true
                    }
                }
            } else {
                Write-Log "Завантаження архiвiв на SFTP вимкнено в конфiгурацiї" -Level "INFO"
            }

            if ($bazaAppSFTPSyncEnabled -and $bazaAppSourceAvailable) {
                $transferResults.BAZA_APP.Attempted = $true
                Show-ScriptProgress -Status "Синхронiзацiя BAZA APP на SFTP" -PercentComplete 90
                Write-Log "==="
                Write-Log "=== СИНХРОНIЗАЦIЯ BAZA APP НА SFTP ==="
                # #292: Main і -SyncBAZA ділять ОДИН диспетчер (див.
                # Invoke-BRAVOBazaCanonicalSync): режим (IncrementalAppendOnly /
                # явний Legacy) обирається там, а не дублюється в call site.
                $bazaAppOutcome = Invoke-BRAVOBazaCanonicalSync -Component 'BAZA_APP' -LocalDirectory $bazaAppPaths.Source -RemoteDirectory $sftpDirectories.BAZA -ComponentName 'BAZA'
                $script:bazaAppSyncResult = $bazaAppOutcome.SyncResult
                $bazaAppSFTPSync = [bool]$bazaAppOutcome.Success
                $transferResults.BAZA_APP.Success = $bazaAppSFTPSync
                $transferResults.BAZA_APP.Degraded = [bool]$bazaAppOutcome.Degraded
                $transferResults.BAZA_APP.Completed = [int]$bazaAppOutcome.Completed
                $transferResults.BAZA_APP.Remaining = [int]$bazaAppOutcome.Remaining
                $transferResults.BAZA_APP.IncompatibleNames = [int]$bazaAppOutcome.IncompatibleNames
                if (-not $bazaAppSFTPSync) {
                    $transferResults.BAZA_APP.Error = [string]$bazaAppOutcome.Error
                    Write-Log "Каталог BAZA APP не вдалося синхронiзувати з SFTP ($($bazaAppOutcome.Mode)): $($bazaAppOutcome.Status)" -Level "WARNING"
                    $operationFailed = $true
                } elseif ($null -ne $script:bazaAppSyncResult) {
                    Write-Log "BAZA APP: cycle $($script:bazaAppSyncResult.CycleId) — передано $($script:bazaAppSyncResult.Uploaded), вже підтверджено $($script:bazaAppSyncResult.AlreadyVerified), помилок 0" -Level "SUCCESS"
                }
            } elseif ($bazaAppSFTPSyncEnabled) {
                $transferResults.BAZA_APP.Success = $false
                $transferResults.BAZA_APP.Error = 'локальний source path недоступний'
                Write-Log "Синхронiзацiю BAZA APP на SFTP пропущено через помилку локального шляху" -Level "ERROR"
                $operationFailed = $true
            } else {
                Write-Log "Синхронiзацiю BAZA APP на SFTP вимкнено в конфiгурацiї" -Level "INFO"
            }

            if ($bazaWWWSFTPSyncEnabled -and $bazaWWWSourceAvailable) {
                $transferResults.BAZA_WWW.Attempted = $true
                Show-ScriptProgress -Status "Синхронiзацiя BAZA WWW на SFTP" -PercentComplete 91
                Write-Log "==="
                Write-Log "=== СИНХРОНIЗАЦIЯ BAZA WWW НА SFTP ==="
                # Той самий канонічний диспетчер, що BAZA APP вище.
                $bazaWWWOutcome = Invoke-BRAVOBazaCanonicalSync -Component 'BAZA_WWW' -LocalDirectory $bazaWWWPaths.Source -RemoteDirectory $sftpDirectories.BAZAWWW -ComponentName 'BAZA WWW'
                $script:bazaWWWSyncResult = $bazaWWWOutcome.SyncResult
                $bazaWWWSFTPSync = [bool]$bazaWWWOutcome.Success
                $transferResults.BAZA_WWW.Success = $bazaWWWSFTPSync
                $transferResults.BAZA_WWW.Degraded = [bool]$bazaWWWOutcome.Degraded
                $transferResults.BAZA_WWW.Completed = [int]$bazaWWWOutcome.Completed
                $transferResults.BAZA_WWW.Remaining = [int]$bazaWWWOutcome.Remaining
                $transferResults.BAZA_WWW.IncompatibleNames = [int]$bazaWWWOutcome.IncompatibleNames
                if (-not $bazaWWWSFTPSync) {
                    $transferResults.BAZA_WWW.Error = [string]$bazaWWWOutcome.Error
                    Write-Log "Каталог BAZA WWW не вдалося синхронiзувати з SFTP ($($bazaWWWOutcome.Mode)): $($bazaWWWOutcome.Status)" -Level "WARNING"
                    $operationFailed = $true
                } elseif ($null -ne $script:bazaWWWSyncResult) {
                    Write-Log "BAZA WWW: cycle $($script:bazaWWWSyncResult.CycleId) — передано $($script:bazaWWWSyncResult.Uploaded), вже підтверджено $($script:bazaWWWSyncResult.AlreadyVerified), помилок 0" -Level "SUCCESS"
                }
            } elseif ($bazaWWWSFTPSyncEnabled) {
                $transferResults.BAZA_WWW.Success = $false
                $transferResults.BAZA_WWW.Error = 'локальний source path недоступний'
                Write-Log "Синхронiзацiю BAZA WWW на SFTP пропущено через помилку автоматичного визначення шляху" -Level "ERROR"
                $operationFailed = $true
            } else {
                Write-Log "Синхронiзацiю BAZA WWW на SFTP вимкнено в конфiгурацiї" -Level "INFO"
            }
        }
    } else {
        Write-Log "Усi компоненти передачi на SFTP вимкнено в конфiгурацiї" -Level "INFO"
    }
    foreach ($transferKey in @('ArchiveUpload', 'BAZA_APP', 'BAZA_WWW')) {
        $transferResult = $transferResults[$transferKey]
        if (-not [bool]$transferResult.Enabled) { continue }
        if ($null -eq $transferResult.Success) {
            $transferResult.Success = $false
            if ([string]::IsNullOrWhiteSpace([string]$transferResult.Error)) {
                $transferResult.Error = 'SFTP configuration or connection failed before this operation'
            }
        }
        $transferStepStatus = if (-not [bool]$transferResult.Success) {
            'ERROR'
        } elseif ([bool]$transferResult.Degraded) {
            'WARNING'
        } else {
            'OK'
        }
        $transferStepDetails = if ([bool]$transferResult.Degraded) {
            "сумісні об'єкти синхронізовано; несумісних імен: $($transferResult.IncompatibleNames)"
        } else {
            [string]$transferResult.Error
        }
        Write-BRAVOArchiveStep -Name ([string]$transferResult.Name) -Status $transferStepStatus -Details $transferStepDetails
    }
    $sftpStepFailed = @(
        @('ArchiveUpload', 'BAZA_APP', 'BAZA_WWW') | Where-Object {
            [bool]$transferResults[$_].Enabled -and -not [bool]$transferResults[$_].Success
        }
    ).Count -gt 0

    # Копіювання успішно створених архівів та hash-файлів на NAS/SMB
    $errorsBeforeSmb = (Get-BRAVOLogStatistics).Errors
    # Той самий захист, що й для $sftpStepFailed вище.
    $smbStepFailed = $false
    if ($smbArchiveCopyEnabled) {
        Show-ScriptProgress -Status "Копіювання архівів на NAS/SMB" -PercentComplete 92
        Write-Log "==="
        Write-Log "=== КОПІЮВАННЯ АРХІВІВ НА NAS/SMB ==="
        if (-not $smbConfigurationValid) {
            Write-Log "Копіювання на NAS/SMB пропущено через помилки конфігурації" -Level "ERROR"
            $operationFailed = $true
        } else {
            $smbCopyResult = Copy-ArchivesToSMB `
                -ArchiveResults $results `
                -GenerationManifestPath $generationManifestPath
            $transferResults.SMB.Total = [int]$smbCopyResult.Total
            $transferResults.SMB.Completed = [int]$smbCopyResult.Success
            $transferResults.SMB.Remaining = [int]$smbCopyResult.Total - [int]$smbCopyResult.Success
            if ($smbCopyResult.Total -eq 0) {
                $transferResults.SMB.Success = ($enabledArchives.Count -eq 0)
                $transferResults.SMB.Error = 'немає опублікованих локальних архівів для копіювання'
                Write-Log "Немає успішно створених архівів для копіювання на NAS/SMB" -Level "WARNING"
                if ($enabledArchives.Count -gt 0) {
                    $operationFailed = $true
                }
            } elseif ($smbCopyResult.Success -eq $smbCopyResult.Total) {
                $transferResults.SMB.Success = $true
                Write-Log "Скопійовано $($smbCopyResult.Success) з $($smbCopyResult.Total) файлів на NAS/SMB" -Level "SUCCESS"
            } else {
                $transferResults.SMB.Success = $false
                $transferResults.SMB.Error = "скопійовано $($smbCopyResult.Success) з $($smbCopyResult.Total) файлів"
                Write-Log "Скопійовано $($smbCopyResult.Success) з $($smbCopyResult.Total) файлів на NAS/SMB" -Level "ERROR"
                $operationFailed = $true
            }
        }
    } else {
        Write-Log "Копіювання архівів на NAS/SMB вимкнено в конфігурації" -Level "INFO"
    }
    if ($smbArchiveCopyEnabled) {
        $smbStepFailed = -not [bool]$transferResults.SMB.Success
        Write-BRAVOArchiveStep `
            -Name "Копіювання архівів на NAS/SMB" `
            -Status $(if ($smbStepFailed) { 'ERROR' } else { 'OK' }) `
            -Details $(if ($smbStepFailed) { 'Деталі записано у журнал.' } else { '' })
    }

    # Завершення
    $scriptEndTime = Get-Date
    $duration = $scriptEndTime - $scriptStartTime
    
    Write-Log "==="
    Write-Log "=== ЗАВЕРШЕННЯ РОБОТИ СКРИПТА ==="
    Write-Log "Час початку: $($scriptStartTime.ToString($logTimestampFormat))" -NoTimestamp
    Write-Log "Час завершення: $($scriptEndTime.ToString($logTimestampFormat))" -NoTimestamp
    Write-Log "Тривалiсть: $($duration.ToString($durationFormat))" -NoTimestamp
    
    # Підсумок
    $successCount = @($results.Values | Where-Object { $_.ArchiveSuccess }).Count
    $totalCount = $results.Count
    if ($readyArchives.Count -ne $enabledArchives.Count -or
        @($results.Values | Where-Object {
            -not $_.ArchiveSuccess -or -not $_.HashSuccess
        }).Count -gt 0) {
        $operationFailed = $true
    }
    
    Write-Log "Створено архiвiв: $successCount з $totalCount" -NoTimestamp
    Write-Log "Лог-файл: $logFile" -NoTimestamp

    $errorsBeforeHealth = (Get-BRAVOLogStatistics).Errors
    # Читається у фінальному резолвері коду виходу нижче незалежно від того,
    # чи здійснювалась перевірка health-check.
    $healthCriticalFailure = $false
    $notificationFailure = $false
    $healthCheckResult = $null
    if ($healthCheckEnabled) {
        $transferResults.Health.Attempted = $true
        Show-ScriptProgress -Status "Перевiрка стану резервних копiй" -PercentComplete 96
        Write-Log "==="
        Write-Log "=== ПЕРЕВIРКА СТАНУ РЕЗЕРВНИХ КОПIЙ ==="

        try {
                $healthParameters = @{
                    ConfigPath = $configPath
                    ConfigPathWasExplicit = $configPathWasExplicit
                }
                $backupNotificationMode = [string]$backupMonitoring.NotificationMode
                if ([string]::IsNullOrWhiteSpace($backupNotificationMode)) {
                    $backupNotificationMode = [string]$backupMonitoring.SlackMode
                }
                if ($backupMonitoring.NotifyOnSuccessAfterBackup -and
                    $backupNotificationMode.ToLowerInvariant() -eq "all") {
                    $healthParameters.NotifyOnSuccess = $true
                }
                # -NoSlack оператора діє на ВЕСЬ прогін, включно з вбудованим
                # Health: без прокидання Health міг надіслати повідомлення,
                # хоча запуск явно заборонив Slack. Передається лише коли
                # прапорець встановлено — поведінка за замовчуванням незмінна.
                if ($NoSlack) {
                    $healthParameters.NoSlack = $true
                }
                $healthModulePath = Join-Path $bravoScriptDirectory 'modules\BRAVO.Health\BRAVO.Health.psd1'
                if (-not (Test-Path -LiteralPath $healthModulePath -PathType Leaf)) {
                    throw "Не знайдено модуль health-check: $healthModulePath"
                }
                Import-Module -Name $healthModulePath -ErrorAction Stop
                $healthParameters.RuntimeRoot = $bravoScriptDirectory
                $healthParameters.EntryScriptPath = Join-Path $bravoScriptDirectory 'BRAVO_HEALTH.ps1'
                # ONE synchronization, ONE SyncResult (safety-review ТЗ п.9):
                # якщо ЦЕЙ прогін щойно виконав incremental BAZA sync, Health
                # отримує вже готовий результат і НЕ повторює його сам —
                # передається лише те, що реально було спробувано (Attempted),
                # інакше Health сам вирішує, чи потрібна власна синхронізація.
                $bazaSyncResultsForHealth = @{}
                if ($transferResults.BAZA_APP.Attempted -and $null -ne $script:bazaAppSyncResult) {
                    $bazaSyncResultsForHealth['BAZA_APP'] = $script:bazaAppSyncResult
                }
                if ($transferResults.BAZA_WWW.Attempted -and $null -ne $script:bazaWWWSyncResult) {
                    $bazaSyncResultsForHealth['BAZA_WWW'] = $script:bazaWWWSyncResult
                }
                if ($bazaSyncResultsForHealth.Count -gt 0) {
                    $healthParameters.BazaSyncResults = $bazaSyncResultsForHealth
                }
                $healthCheckResult = Invoke-BRAVOHealthCheck @healthParameters
                switch ($healthCheckResult.Status) {
                    "Healthy" {
                        $transferResults.Health.Success = $true
                        Write-Log "Health-check: усi резервнi копiї актуальнi; повідомлення: $($healthCheckResult.Notification)" -Level "SUCCESS"
                    }
                    "Disabled" {
                        $transferResults.Health.Success = $true
                        # Сам Health вважає це безпечним станом (вимкнено в
                        # конфігурації) і завершується з exit 0 — Archive не
                        # повинен трактувати чужий "вимкнено" як власну відмову.
                        Write-Log "Health-check вимкнено в конфігурації" -Level "INFO"
                    }
                    "Deferred" {
                        $transferResults.Health.Success = $true
                        # Аналогічно: відкладено через паралельне завдання чи
                        # зайнятий lock — це не відмова, а штатне пропускання.
                        Write-Log "Health-check відкладено: інше завдання вже виконується" -Level "INFO"
                    }
                    "Critical" {
                        $transferResults.Health.Success = $false
                        $transferResults.Health.Error = "issues: $($healthCheckResult.IssueCount)"
                        Write-Log "Health-check: знайдено проблем: $($healthCheckResult.IssueCount); повідомлення: $($healthCheckResult.Notification)" -Level "ERROR"
                        $operationFailed = $true
                        $healthCriticalFailure = $true
                    }
                    "NotificationError" {
                        $healthHasIssues = [int]$healthCheckResult.IssueCount -gt 0
                        $transferResults.Health.Success = -not $healthHasIssues
                        $transferResults.Health.Error = $(if ($healthHasIssues) { "issues: $($healthCheckResult.IssueCount)" } else { $null })
                        $transferResults.Notification.Enabled = $true
                        $transferResults.Notification.Attempted = $true
                        $transferResults.Notification.Success = $false
                        $transferResults.Notification.Error = [string]$healthCheckResult.Error
                        Write-Log "Health-check завершився; notification failed: $($healthCheckResult.Error)" -Level "WARNING"
                        $notificationFailure = $true
                        if ($healthHasIssues) {
                            $operationFailed = $true
                            $healthCriticalFailure = $true
                        }
                    }
                    default {
                        $transferResults.Health.Success = $false
                        $transferResults.Health.Error = "unexpected status: $($healthCheckResult.Status)"
                        Write-Log "Health-check завершився зі статусом: $($healthCheckResult.Status)" -Level "WARNING"
                        $operationFailed = $true
                        $healthCriticalFailure = $true
                    }
                }
        } catch {
            $transferResults.Health.Success = $false
            $transferResults.Health.Error = $_.Exception.Message
            Write-Log "Помилка запуску окремого health-check: $($_.Exception.Message)" -Level "ERROR"
            $operationFailed = $true
            $healthCriticalFailure = $true
        }
    }

    if ($healthCheckEnabled) {
        $healthStepFailed = (Get-BRAVOLogStatistics).Errors -gt $errorsBeforeHealth
        Write-BRAVOArchiveStep `
            -Name "Перевірка резервних копій" `
            -Status $(if ($healthStepFailed) { 'ERROR' } else { 'OK' }) `
            -Details $(if ($healthStepFailed) { 'Деталі записано у журнал.' } else { '' })
    }

    # Локальний manifest є фінальним state object для generation. Remote
    # copy, переданий раніше разом з архівами, фіксує publish-time стан;
    # локальна версія після transfer/health містить повний operational result.
    # Фіналізуємо ДО розрахунку exit code і друку РЕЗУЛЬТАТ, щоб помилка
    # персистенції не могла завершити процес успішно.
    if ($null -ne $script:backupGenerationState -and
        -not [string]::IsNullOrWhiteSpace($generationManifestPath)) {
        $script:backupGenerationState.TransferResults = $transferResults
        $script:backupGenerationState.HealthResult = $healthCheckResult
        try {
            $generationManifestPath = Write-BRAVOBackupGenerationManifest `
                -GenerationState $script:backupGenerationState `
                -BackupRoot $backupRootPath
        } catch {
            $generationFinalizationFailed = $true
            $generationFinalizationFailureReason = $_.Exception.Message
            $operationFailed = $true
            Write-BRAVOLog -Component 'SUMMARY' -Message "Не вдалося фіналізувати generation manifest: $($_.Exception.Message)" -Level 'ERROR'
        }
    }

    # T006: одне WARNING-сповіщення на прогін про архіви, що пройшли 7z t
    # лише через legacy BOM-у-паролі fallback. Код 10 уже забезпечено
    # WARNING-записом кожного такого архіву (статистика журналу нижче).
    Send-BRAVOArchiveLegacyBomFallbackAlert -Results $results

    # Секція health-check (якщо вона виконувалась) залишає компонент журналу
    # на "HEALTH" — без явного повернення на "SUMMARY" підсумковий рядок
    # хибно тегувався б [HEALTH] навіть тоді, коли сам health-check пройшов
    # успішно, а $operationFailed стало $true через щось раніше (наприклад
    # провалену перевірку цілісності архіву).
    Set-BRAVOLogComponent -Component 'SUMMARY'
    Write-Log "Результат: $(if ($operationFailed) {'ПОМИЛКА'} else {'УСПIШНО'})" -NoTimestamp
    Write-Log "==="
    if ($script:backupGenerationStatus -eq 'COMPLETE') {
        Write-BRAVOBackupExecutionState
    }
    Show-ScriptProgress -Status "Завершено" -PercentComplete 100
    Complete-BRAVOProgress

    # Фінальний підсумок операційної консолі.
    $logStatistics = Get-BRAVOLogStatistics
    $summaryResult = if ($operationFailed) {
        if ($successCount -gt 0) { 'ЧАСТКОВО' } else { 'ПОМИЛКА' }
    } else {
        'УСПІШНО'
    }
    $summaryStatusColor = switch ($summaryResult) {
        'УСПІШНО'  { 'Green' }
        'ЧАСТКОВО' { 'Yellow' }
        default    { 'Red' }
    }

    # Код завершення в консолі має завжди збігатися з фактичним process
    # exit code (docs/MANUAL_RUN_CONSOLE_UX.md) — тому обчислюємо його ДО
    # друку РЕЗУЛЬТАТ, а не після, як було раніше (Write-BRAVOSummary тоді
    # ще не міг показати код: він з'являвся лише нижче за течією).
    $anyLocalArchiveFailed = @(
        $results.Values | Where-Object {
            -not [bool]$_.CreateSuccess -or [string]$_.ErrorStage -eq 'PUBLISH'
        }
    ).Count -gt 0
    $anyIntegrityTestFailed = @(
        $results.Values | Where-Object {
            [bool]$_.CreateSuccess -and -not [bool]$_.IntegritySuccess
        }
    ).Count -gt 0
    $anyHashValidationFailed = @(
        $results.Values | Where-Object {
            [bool]$_.CreateSuccess -and
            [bool]$_.IntegritySuccess -and
            -not [bool]$_.HashSuccess -and
            [string]$_.ErrorStage -eq 'HASH'
        }
    ).Count -gt 0
    if ($operationFailed) {
        # Один раз, тут, читаємо вже наявний стан секцій Main і визначаємо
        # найпріоритетнішу категорію відмови — жодна з ~26 точок
        # $operationFailed = $true вище не редагувалась.
        $script:processExitCode = Resolve-BRAVOExitCode `
            -InvalidConfiguration:(-not $sftpConfigurationValid -or -not $smbConfigurationValid -or -not $archiveConsistencyValid -or -not $systemAccessValid -or -not $discoveryBaselineValid) `
            -CredentialsUnavailable:(-not $archiveCredentialValid) `
            -LocalArchiveFailed:($anyLocalArchiveFailed -or $generationFinalizationFailed) `
            -IntegrityTestFailed:$anyIntegrityTestFailed `
            -HashValidationFailed:$anyHashValidationFailed `
            -SftpFailed:([bool]$sftpStepFailed) `
            -SmbFailed:([bool]$smbStepFailed) `
            -HealthCritical:$healthCriticalFailure
    } elseif ($logStatistics.Warnings -gt 0) {
        $script:processExitCode = Resolve-BRAVOExitCode -HasWarnings
    }

    # Operations-подія generation — ОДНА зведена подія на прогін.
    #
    # Тут збирається лише КОНТЕКСТ (message + Details), а сама відправка
    # виконується канонічною Send-BRAVOArchiveFinalOperationsEvent, яку
    # викликає також finally нижче. Причина (review PR #225, P1 "Report
    # Archive failures that bypass the end of Main"): цей блок лежить у
    # ХВОСТІ Main, тому його обходили і зовнішній catch (exit code 90), і
    # п'ять контрольованих ранніх return-ів Main (lock busy, збій
    # прибирання orphan VSS, ручна синхронізація, preflight free-space) —
    # прогін звітував про відмову і в процесі, і в локальному статус-файлі,
    # а dashboard не бачив ЖОДНОЇ події. Це та сама причина, з якої
    # вивантаження власного логу вже живе у finally, а не в хвості Main
    # (той самий контракт, з тієї самої причини).
    #
    # Severity більше НЕ виводиться зі статусу generation: вона походить
    # від фактично резолвленого $script:processExitCode через канонічну
    # Get-BRAVOExitCodeSeverity (BRAVO.ExitCodes). Раніше generation
    # COMPLETE з резолвленим кодом 10 (SuccessWithWarnings) звітував
    # SUCCESS — подія суперечила власному полю exitCode у своєму ж payload.
    # Побудова контексту — теж fail-soft (інваріант «телеметрія не змінює
    # exit code»): збій тут не сміє перетворити успішний бекап у код 90
    # через зовнішній catch. Сама відправка має власний try/catch
    # усередині Send-BRAVOArchiveFinalOperationsEvent; на цьому кроці
    # контекст лишається $null, і finally надішле мінімальну подію з
    # фактичним кодом завершення — це краще за тишу.
    try {
        $generationEventOutcome = if ($operationFailed) {
            if ($successCount -gt 0) { 'ЧАСТКОВО' } else { 'ПОМИЛКА' }
        } else {
            'УСПІШНО'
        }
        $script:archiveFinalOperationsEventContext = @{
            Message = "Generation ${generationId}: $($script:backupGenerationStatus), прогін $generationEventOutcome (опубліковано $publishedComponentCount з $($enabledArchives.Count), код завершення $($script:processExitCode))"
            Details = @{
                generationId = $generationId
                status = [string]$script:backupGenerationStatus
                runOutcome = [string]$generationEventOutcome
                publishedComponentCount = $publishedComponentCount
                enabledComponentCount = $enabledArchives.Count
                snapshotSetId = if ($null -ne $generationSnapshotSet) { $generationSnapshotSet.SnapshotSetId } else { $null }
                durationMs = [Math]::Round(((Get-Date) - $scriptStartTime).TotalMilliseconds)
                # .ToArray(), а НЕ @($script:BRAVOArchiveStepHistory): у Windows
                # PowerShell 5.1 (і в PowerShell 7) загортання
                # System.Collections.Generic.List[object] у @() кидає ArgumentException
                # "Argument types do not match" — той самий задокументований гейт, що
                # вже описаний біля $probeGroupList (BRAVO.Archive.Runtime.ps1) і
                # $emptyDirs (BRAVO.Maintenance.Runtime.ps1). Спрацьовувало на кожному
                # прогоні: подія в Operations не доходила взагалі.
                stages = $script:BRAVOArchiveStepHistory.ToArray()
            }
        }
    } catch {
        $script:archiveFinalOperationsEventContext = $null
        Write-Log "Не вдалося зібрати контекст фінальної події Operations: $($_.Exception.Message) — буде надіслано мінімальну подію" -Level "WARNING"
    }
    Send-BRAVOArchiveFinalOperationsEvent

    # Machine-readable status contract v1 (ROADMAP P2.1, BRAVO.Status):
    # ПІСЛЯ обчислення exit code, fail-soft — помилка запису лише
    # логується і ніколи не змінює результат Archive (інваріант
    # «telemetry не змінює exit code»). Сам запис — у helper'і, спільному
    # з ранніми виходами (#291); try тут лишається для збору агрегатів.
    try {
        $statusComponentsTotal = @($enabledArchives).Count
        $statusComponentsSucceeded = @($results.Values | Where-Object { [bool]$_.ArchiveSuccess }).Count
        $statusTotalCreatedBytes = [long]0
        foreach ($statusComponentResult in $results.Values) {
            # Ключ Bytes є лише в опублікованих компонентів; під StrictMode
            # 2.0 звернення до відсутнього ключа hashtable кидає виняток,
            # і статус-файл не записувався б на прогонах зі збоєм компонента.
            if ($statusComponentResult.ContainsKey('Bytes') -and $null -ne $statusComponentResult['Bytes']) {
                $statusTotalCreatedBytes += [long]$statusComponentResult['Bytes']
            }
        }
        Write-BRAVOArchiveOperationStatus `
            -ExitCode $script:processExitCode `
            -StartedAt $scriptStartTime `
            -Details @{
                generationId = [string]$script:backupGenerationId
                generationStatus = [string]$script:backupGenerationStatus
                componentsSucceeded = $statusComponentsSucceeded
                componentsTotal = $statusComponentsTotal
                totalCreatedBytes = $statusTotalCreatedBytes
            }
    } catch {
        Write-Log "ПОПЕРЕДЖЕННЯ: не вдалося записати machine-readable status-файл Archive: $($_.Exception.Message)" -Level "WARNING"
    }

    # Причина/Інструмент/Код інструменту показуються лише коли головний
    # результат дійсно спричинений конкретним локальним компонентом
    # (docs/MANUAL_RUN_CONSOLE_UX.md) — перший відмовлений компонент за
    # стабільним порядком archiveDefinitions, не випадковий "останній".
    $firstFailedComponent = $null
    if ($anyLocalArchiveFailed -or $anyIntegrityTestFailed -or $anyHashValidationFailed) {
        $firstFailedComponent = $archiveDefinitions | Where-Object {
            $results.ContainsKey($_.Type) -and -not $results[$_.Type].ArchiveSuccess
        } | Select-Object -First 1
    }
    $summaryReason = $null
    $summaryTool = $null
    $summaryToolExitCode = $null
    if ($generationFinalizationFailed) {
        $summaryReason = Get-BRAVOArchiveGenerationFailureSummaryReason `
            -GenerationFinalizationFailed $generationFinalizationFailed `
            -GenerationFinalizationFailureReason $generationFinalizationFailureReason
    } elseif ($null -ne $firstFailedComponent) {
        $failedResult = $results[$firstFailedComponent.Type]
        $summaryReason = switch ([string]$failedResult.ErrorStage) {
            'VSS' { "VSS SNAPSHOT SET FAILED for $($firstFailedComponent.Type)" }
            'INTEGRITY' { "Integrity test failed for $($firstFailedComponent.Type)" }
            'HASH' { "SHA512 generation/verification failed for $($firstFailedComponent.Type)" }
            'PUBLISH' { "Atomic publish failed for $($firstFailedComponent.Type)" }
            default { "Не вдалося створити архів $($firstFailedComponent.Type)" }
        }
        $toolFailure = $results[$firstFailedComponent.Type].ToolFailure
        if ($null -ne $toolFailure) {
            $summaryTool = $toolFailure.Tool
            $summaryToolExitCode = $toolFailure.ToolExitCodeText
        }
    } elseif ([bool]$sftpStepFailed) {
        # Називаємо САМЕ ті передавання, що впали. Раніше тут завжди стояло
        # "Не вдалося передати архіви на SFTP" — навіть коли архіви
        # завантажились успішно, а впала лише синхронізація BAZA_APP/BAZA_WWW.
        # Через це РЕЗУЛЬТАТ суперечив сам собі: причина говорила про архіви,
        # а поруч той самий блок показував "SFTP: резервні копії: OK".
        $failedTransferNames = @(
            @('ArchiveUpload', 'BAZA_APP', 'BAZA_WWW') |
                Where-Object {
                    [bool]$transferResults[$_].Enabled -and -not [bool]$transferResults[$_].Success
                } |
                ForEach-Object { [string]$transferResults[$_].Name }
        )
        $summaryReason = if ($failedTransferNames.Count -gt 0) {
            "Не вдалося виконати передавання SFTP: $($failedTransferNames -join ', ')"
        } else {
            "Не вдалося передати архіви на SFTP"
        }
    }

    Write-BRAVOResultHeader `
        -Status $summaryResult `
        -StatusColor $summaryStatusColor `
        -ExitCode $script:processExitCode `
        -ExitCodeName (Get-BRAVOExitCodeName -Code $script:processExitCode) `
        -Reason $summaryReason `
        -Tool $summaryTool `
        -ToolExitCode $summaryToolExitCode
    Write-BRAVOResultField -Label 'Початок' -Value $scriptStartTime.ToString('dd.MM.yyyy HH:mm:ss')
    Write-BRAVOResultField -Label 'Завершення' -Value $scriptEndTime.ToString('dd.MM.yyyy HH:mm:ss')
    Write-BRAVOResultField -Label 'Тривалість' -Value (Format-BRAVODuration -Duration $duration)
    Write-Host ''
    Write-BRAVOResultField -Label 'Створено архівів' -Value ("{0} з {1}" -f $successCount, $totalCount)
    Write-BRAVOResultField -Label 'Generation' -Value ([string]$script:backupGenerationId)
    Write-BRAVOResultField -Label 'Generation status' -Value ([string]$script:backupGenerationStatus)
    Write-BRAVOResultField `
        -Label 'VSS Snapshot Set' `
        -Value (Get-BRAVOArchiveVSSSummaryValue `
            -SnapshotSet $generationSnapshotSet `
            -EnabledArchiveCount $enabledArchives.Count)
    # Measure-Object -Property не резолвить ключі Hashtable через reflection
    # (results зберігає @{...}, не [pscustomobject]) — тому спершу проєктуємо
    # значення через ForEach-Object, і лише готові числа йдуть у Measure-Object.
    $totalCreatedBytes = (
        $results.Values |
            Where-Object { $_.ArchiveSuccess -and $null -ne $_.Bytes } |
            ForEach-Object { $_.Bytes } |
            Measure-Object -Sum
    ).Sum
    Write-BRAVOResultField -Label 'Загальний розмір' -Value (Format-BRAVOFileSize -Bytes $totalCreatedBytes)
    foreach ($transferKey in @('ArchiveUpload', 'BAZA_APP', 'BAZA_WWW')) {
        $transferResult = $transferResults[$transferKey]
        if (-not [bool]$transferResult.Enabled) { continue }
        $transferValue = if (-not [bool]$transferResult.Success) {
            'ERROR'
        } elseif ([bool]$transferResult.Degraded) {
            "WARNING (несумісних імен: $($transferResult.IncompatibleNames))"
        } else { 'OK' }
        Write-BRAVOResultField -Label ([string]$transferResult.Name) -Value $transferValue
    }

    if ($smbArchiveCopyEnabled) {
        Write-BRAVOResultField -Label 'SMB' -Value $(if ($smbStepFailed) { 'ERROR' } else { 'OK' })
    }
    if ($healthCheckEnabled) {
        Write-BRAVOResultField -Label 'Post-backup health' -Value $(if ([bool]$transferResults.Health.Success) { 'OK' } else { 'CRITICAL' })
    }
    if ($notificationFailure) {
        Write-BRAVOResultField -Label 'Notification' -Value 'ERROR (backup data unaffected)'
    }

    # Архіви: усі заплановані компоненти в стабільному порядку
    # archiveDefinitions — успішний component показує розмір і повний
    # шлях окремим рядком, невдалий — ERROR без вигаданого шляху.
    # Лише компоненти реального складу ($enabledArchives): NotInstalled
    # пропущено без помилки і не має друкуватись як «Архів не створено».
    if ($enabledArchives.Count -gt 0) {
        Write-BRAVOResultSection -Title 'Архіви'
        foreach ($definition in $enabledArchives) {
            $componentResult = $results[$definition.Type]
            if ($null -ne $componentResult -and [bool]$componentResult.ArchiveSuccess) {
                Write-Host ("  {0,-12}{1}" -f $definition.Type, (Format-BRAVOFileSize -Bytes $componentResult.Bytes))
                Write-Host ("    {0}" -f $componentResult.ArchivePath)
            } else {
                Write-Host ("  {0,-12}ERROR" -f $definition.Type)
                Write-Host ("    Архів не створено")
            }
        }
    }
    Write-BRAVOResultFooter -LogFile $script:logFile
}

# Вивантаження ВЛАСНОГО повного логу прогону на SFTP — opt-in
# (componentSettings.SFTP.ArchiveLogUploadEnabled, дефолт $false).
# P2-5 (PR #136 review): раніше виклик існував лише в кінці Main() —
# і фатальний крах, і контрольований ранній `return` із Main() (lock
# busy, VSS orphan cleanup failure, ручна синхронізація, preflight
# free-space failure) узагалі не вивантажували лог, хоча саме крах —
# момент, коли він найпотрібніший для діагностики. Єдиний виклик тепер
# у зовнішньому `finally` (див. нижче) — виконується РІВНО ОДИН РАЗ на
# прогін для будь-якого шляху виходу з Main (успіх/ранній return/
# необроблений виняток), після відповідного footer/summary. Результат
# НІКОЛИ не змінює $script:processExitCode (другорядний/телеметричний
# ефект).
function Invoke-BRAVOArchiveOwnLogUpload {
    # Boot-підхоплення (-CatchUpMissedBackup), яке вирішило, що копія не
    # потрібна, нічого не архівувало — його короткий лог не вивантажується.
    if ($script:archiveCatchUpSkipped) {
        return
    }
    # Увесь блок — в одному try/catch (а не лише сам transfer, як було
    # раніше): якщо крах стався ДО завантаження конфігурації,
    # componentSettings/storageEffective/sftpUrl тощо ще не існують, і
    # звернення до них під Set-StrictMode кинуло б виняток. Тут це
    # трактується як "вивантажити нічого" — WARNING, а не друга помилка,
    # що замаскувала б первинний fatal exception виклику.
    try {
        # P1 (PR #136 review, r3943997859): Complete-BRAVOConfigurationLoad
        # проєктує componentSettings/storageEffective виключно у $global:
        # (як і всюди в цьому файлі — див. рядки 3600, 5983 тощо), ніколи
        # у script-scope. Перевірка на -Scope Script завжди повертала
        # $false, тож вивантаження власного логу було постійним no-op
        # навіть при ArchiveLogUploadEnabled=$true.
        if (-not (Get-Variable -Name componentSettings -Scope Global -ErrorAction SilentlyContinue) -or
            -not (Get-Variable -Name storageEffective -Scope Global -ErrorAction SilentlyContinue)) {
            return
        }
        if (-not ([bool]$componentSettings.SFTP.ArchiveLogUploadEnabled -and
                [bool]$storageEffective.SFTP.Enabled)) {
            return
        }
        if ([string]::IsNullOrWhiteSpace($sftpUrl) -or
            [string]::IsNullOrWhiteSpace($sftpHostKey) -or
            [string]::IsNullOrWhiteSpace($winSCPPath) -or
            -not (Test-Path -LiteralPath $script:logFile -PathType Leaf)) {
            Write-BRAVOLog -Component 'SFTP' -Message "Власний лог: SFTP-конфігурація неповна або лог відсутній — вивантаження пропущено" -Level "WARNING"
            return
        }
        $ownLogRemoteDirectory = [string]$sftpDirectories.ArchivLog
        Initialize-BRAVOSFTPRemoteDirectories `
            -WinSCPPath $winSCPPath `
            -RepositorySFTPUrl $sftpUrl `
            -HostKey $sftpHostKey `
            -RemoteDirectories @($ownLogRemoteDirectory)
        $ownLogUploaded = Send-FileViaWinSCP `
            -WinSCPPath $winSCPPath `
            -RepositorySFTPUrl $sftpUrl `
            -HostKey $sftpHostKey `
            -LocalFilePath $script:logFile `
            -RemoteDirectory $ownLogRemoteDirectory
        if (-not $ownLogUploaded) {
            Write-BRAVOLog -Component 'SFTP' -Message "Власний лог: передачу не завершено (деталі вище) — результат прогону не змінюється" -Level "WARNING"
        }
    } catch {
        try {
            Write-BRAVOLog -Component 'SFTP' -Message "Власний лог: вивантаження не вдалося: $($_.Exception.Message)" -Level "WARNING"
        } catch {
            # Найранніший крах: навіть Write-BRAVOLog може бути недоступний.
            # Мовчазний catch навмисний — телеметрія власного логу не
            # повинна маскувати первинний fatal exception виклику.
        }
    }
}

# Запуск головної функції
$script:processExitCode = 0
$script:archiveProcessLock = $null
$script:archiveProcessLockPath = $null
$script:archiveFinalOperationsEventSent = $false
$script:archiveFinalOperationsEventContext = $null
$script:archiveCatchUpSkipped = $false

function Send-BRAVOArchiveFinalOperationsEvent {
    <#
        ЄДИНИЙ call site відправки фінальної Operations-події прогону
        Archive — рівно один на прогін, незалежно від того, як прогін
        завершився: нормально в хвості Main, одним із контрольованих ранніх
        return-ів Main, чи необробленим винятком у зовнішньому catch.

        Ідемпотентна (прапорець $script:archiveFinalOperationsEventSent):
        нормальний шлях викликає її з Main, finally викликає повторно й
        отримує no-op. Fail-soft за контрактом звітності: жодна помилка тут
        не змінює $script:processExitCode.

        Дозована обережність із наявністю стану навмисна: крах може статися
        ДО завантаження конфігурації або ДО Import-Module, тому і
        конфігурація, і самі функції перевіряються на існування, а не
        припускаються. Під Set-StrictMode звернення до неіснуючої змінної
        кинуло б виняток — у finally це замаскувало б первинну помилку.
    #>
    [CmdletBinding()]
    param()

    if ($script:archiveFinalOperationsEventSent) { return }
    $script:archiveFinalOperationsEventSent = $true

    try {
        # Посилання БЕЗ префікса $global: — цього вимагає guard
        # RuntimeScope/Archive (BRAVO_SELF_TEST.ps1): runtime-стан Archive
        # тримається script-scoped, а перелік дозволених global-змінних у
        # цьому модулі закритий. Конфігурація читається так само, як в
        # усіх інших точках цього файлу (напр. рядки 727/840/4680), тобто
        # неквадифікованим ім'ям; провайдер Variable: розв'язує його за
        # звичайними правилами scope-ланцюга, тому перевірка наявності
        # лишається такою ж надійною, як і з явним global:, і додатково не
        # припускає, у якому саме scope конфігурацію завантажено.
        if (-not (Test-Path -LiteralPath 'Variable:operationsReportingSettings')) { return }
        $finalOperationsSettings = $operationsReportingSettings
        if ($null -eq $finalOperationsSettings) { return }
        if (-not (Test-Path -LiteralPath 'Variable:credentialSettings')) { return }
        if (-not (Get-Command -Name 'Send-BRAVOOperationsEvent' -ErrorAction SilentlyContinue)) { return }
        if (-not (Get-Command -Name 'Get-BRAVOExitCodeSeverity' -ErrorAction SilentlyContinue)) { return }

        $finalExitCode = [int]$script:processExitCode
        $finalSeverity = Get-BRAVOExitCodeSeverity -Code $finalExitCode
        $finalExitCodeName = Get-BRAVOExitCodeName -Code $finalExitCode
        $finalInstitutionCode = ''
        if (Test-Path -LiteralPath 'Variable:backupMonitoring') {
            $finalInstitutionCode = [string]$backupMonitoring.InstitutionCode
        }

        if ($null -ne $script:archiveFinalOperationsEventContext) {
            $finalMessage = [string]$script:archiveFinalOperationsEventContext.Message
            $finalDetails = $script:archiveFinalOperationsEventContext.Details
        } else {
            # Прогін не дійшов до хвоста Main — багатої зведеної статистики
            # не існує. Мінімальна подія все одно краща за тишу: dashboard
            # мусить бачити, що прогін був і чим завершився, а не вважати
            # актуальним результат попереднього прогону.
            $finalMessage = "Прогін BRAVO_ARCHIV завершився без зведення generation (код завершення $finalExitCode / $finalExitCodeName) — зупинка сталася до фінального етапу"
            $finalDetails = @{ earlyTermination = $true }
        }
        $finalDetails['exitCode'] = $finalExitCode
        $finalDetails['exitCodeName'] = [string]$finalExitCodeName

        Send-BRAVOOperationsEvent `
            -OperationsReportingSettings $finalOperationsSettings `
            -CredentialTargets $credentialSettings.Targets `
            -InstitutionCode $finalInstitutionCode `
            -Category 'backup' -Severity $finalSeverity `
            -Component 'Archive' `
            -Message $finalMessage `
            -Details $finalDetails
    } catch {
        try {
            Write-Log "Не вдалося відправити фінальну подію в Operations: $($_.Exception.Message)" -Level "WARNING"
        } catch {
            # Крах міг статись до ініціалізації log writer — телеметрія не
            # має права замаскувати первинну причину завершення прогону.
        }
    }
}

try {
    Main
} catch {
    # Порядок обробки краху (ТЗ «exception visibility»): спершу повна
    # діагностика в лог, потім операторський ERROR + код завершення, і лише
    # ПОТІМ — cleanup і manual pause (у finally). Раніше catch просто робив
    # throw: пауза у finally спрацьовувала ще до того, як виняток десь
    # показувався чи логувався, тож оператор бачив "натисніть клавішу" без
    # жодної причини, а стек не потрапляв у BRAVO_ARCHIV log.
    $fatalErrorRecord = $_
    $fatalMessage = [string]$fatalErrorRecord.Exception.Message
    $script:processExitCode = 90
    # Best-effort machine-readable статус і при фатальному краху (P2.1):
    # без нього моніторинг бачив би застарілий "OK" від попереднього
    # прогону. Мовчазний catch — крах може статися до завантаження
    # конфігурації ($stateRoot) чи модуля статусу.
    # BRAVO_STATUS_Archive.json — статус НІЧНОЇ копії: крах денної BAZA-
    # синхронізації (-SyncBAZA) його теж не перезаписує (#291, той самий
    # guard, що й у helper'і статусу Archive).
    if (-not ((Test-Path variable:SyncBAZA) -and $SyncBAZA)) {
        try {
            Write-BRAVOOperationStatus `
                -StateRoot $stateRoot `
                -Operation Archive `
                -ExitCode 90 `
                -ExitCodeName 'InternalError' `
                -StartedAt $(if (Test-Path variable:scriptStartTime) { $scriptStartTime } else { Get-Date }) `
                -Details @{ fatal = $true }
        } catch {
            # Первинний exception важливіший — не маскуємо його телеметрією.
        }
    }
    try {
        Write-BRAVOArchiveFatalDiagnostics `
            -ErrorRecord $fatalErrorRecord `
            -Context 'Неочікувана помилка виконання BRAVO_ARCHIV'
    } catch {
        # Ранній збій може статись і до повної ініціалізації log writer.
        # Не дозволяємо помилці діагностики замаскувати первинний exception.
        Write-Host (
            "[ERROR] BRAVO_ARCHIV: $fatalMessage " +
            "(не вдалося записати повну діагностику: $($_.Exception.Message))"
        ) -ForegroundColor Red
    }
    try {
        Write-BRAVOResultHeader `
            -Status 'ERROR' `
            -StatusColor ([ConsoleColor]::Red) `
            -ExitCode $script:processExitCode `
            -ExitCodeName (Get-BRAVOExitCodeName -Code $script:processExitCode) `
            -Reason $fatalMessage
        Write-BRAVOResultFooter -LogFile $script:logFile
    } catch {
        # Консоль могла не встигнути ініціалізуватися (крах на ранній стадії) —
        # тоді показуємо мінімум, але процес усе одно завершиться кодом 90.
        Write-Host ("[ERROR] BRAVO_ARCHIV: $fatalMessage (код 90)") -ForegroundColor Red
    }
    # НЕ re-throw: скрипт доходить до власного Exit $script:processExitCode
    # нижче (=90), тож .psm1-обгортка отримує той самий код через $LASTEXITCODE.
} finally {
    # Фінальна Operations-подія — ПЕРЕД вивантаженням власного логу, щоб її
    # рядок потрапив у вивантажений лог, і ПЕРЕД cleanup, щоб dashboard
    # отримав результат навіть якщо cleanup сам щось зламає. Ідемпотентна:
    # на нормальному шляху Main уже її відправив і тут буде no-op. У
    # finally — з тієї самої причини, що вивантаження власного логу
    # нижче: лише finally виконується для БУДЬ-ЯКОГО виходу з try
    # (нормальне завершення, п'ять контрольованих ранніх return-ів Main,
    # необроблений виняток -> код 90).
    Send-BRAVOArchiveFinalOperationsEvent

    # P2-5 (PR #136 review): ЄДИНИЙ спільний call site для вивантаження
    # власного логу — рівно тут, у finally, а НЕ в хвості Main()/catch.
    # Main() має 5 контрольованих раннix return (lock busy, VSS orphan
    # cleanup failure, ручна синхронізація OK/ERROR, preflight free-space
    # failure) — кожен із них уже друкує власний footer/summary ПЕРЕД
    # return, але сам return обходив би виклик, розташований у хвості
    # Main() чи лише в catch. finally виконується для БУДЬ-ЯКОГО виходу з
    # try (нормальне завершення Main, контрольований ранній return,
    # необроблений виняток) — рівно один раз, після відповідного
    # успішного/ERROR footer, ніколи не маскуючи $fatalErrorRecord і не
    # змінюючи $script:processExitCode (функція сама best-effort/
    # ізольована try/catch).
    Invoke-BRAVOArchiveOwnLogUpload
    if ($script:archiveProcessLock) {
        $script:archiveProcessLock.Dispose()
        $script:archiveProcessLock = $null
    }
    # Lock-файл з останньою metadata лишається на диску. Його існування не
    # означає активного процесу; авторитетним є лише exclusive handle.
    if ($script:smbCredential -and $script:smbCredential.Password) {
        $script:smbCredential.Password.Dispose()
        $script:smbCredential = $null
    }
    Show-ScriptProgress -Completed
    Wait-ForManualExit
}

if ($script:processExitCode -ne 0) {
    Exit $script:processExitCode
}
Exit 0
}
# END BRAVO ARCHIVE RUNTIME
if ($MyInvocation.InvocationName -ne '.') {
    $archiveRuntimeParameters = @{
        ConfigPath = $ConfigPath
        ConfigPathWasExplicit = $ConfigPathWasExplicit
        SyncBAZA = $SyncBAZA
        HealthCheckOnly = $HealthCheckOnly
        ForceNotification = $ForceNotification
        NotifyOnSuccess = $NotifyOnSuccess
        NoSlack = $NoSlack
        SkipIfBackupTaskRunning = $SkipIfBackupTaskRunning
        CatchUpMissedBackup = $CatchUpMissedBackup
        NoPause = $NoPause
        RuntimeRoot = $RuntimeRoot
        EntryScriptPath = $EntryScriptPath
    }
    Invoke-BRAVOArchive @archiveRuntimeParameters
}
