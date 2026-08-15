##########
# BravoSoft
# Author: Evgeniy Kucher
# Version metadata is loaded from VERSION.json through BRAVO_CONFIG_LOADER.ps1.
##########
#
# BRAVO_DATA_RESTORE — відновлення даних із резервної копії (roadmap: Етап 6,
# Disaster Restore Workflow). Розпаковує перевірену (manifest + SHA512 +
# 7-Zip integrity) COMPLETE generation або її окремий компонент:
#   OutOfPlace — у порожні підкаталоги вказаної оператором директорії
#                (<TargetPath>\MODEL|BLOG|BRAVOEXCH); production і служби
#                не змінюються;
#   InPlace    — у production-шляхи компонентів (джерела discovery) з повним
#                протоколом безпеки: знімок стану служб -> зупинка -> явне
#                типізоване підтвердження -> move-aside поточних даних у
#                <name>.prerestore_<ts> -> розпакування в порожній каталог ->
#                post-verify -> відновлення стану служб -> Health.
# Джерело архівів: Local (BackupRoot) або SFTP (завантаження у staging з
# повторною повною верифікацією).
#
# НЕ ПЛУТАТИ з "реставрацією моделі" (BRAVO_MAINTENANCE / задача
# BRAVO_RESTORE_RECOVERY): то планова перебудова моделі засобами bravocmd,
# а не відновлення даних із резервної копії.
#
# Інваріант безпеки: жоден файл ніколи не розпаковується поверх наявного —
# ціль завжди щойно створений порожній каталог; попередні InPlace-дані
# зберігаються поруч як .prerestore-копія і не видаляються автоматично.

param (
    [string]$ConfigPath,
    [string]$GenerationId,
    [ValidateSet("MODEL", "BLOG", "BRAVOEXCH", "All")]
    [string]$Component = "All",
    [ValidateSet("OutOfPlace", "InPlace")]
    [string]$Mode = "OutOfPlace",
    [string]$TargetPath,
    [ValidateSet("Local", "SFTP")]
    [string]$Source = "Local",
    [string]$StagingPath,
    [switch]$ListGenerations,
    [switch]$Force,
    [switch]$SkipHealthCheck,
    [int]$TimeoutSeconds = 0,
    [switch]$NoPause,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$EntryScriptPath
)

$bravoScriptDirectory = $RuntimeRoot

# Спільні PowerShell-модулі runtime. BRAVO.ArchiveRuntime — заради
# Test-BRAVOWinSCPAvailable/Get-SanitizedWinSCPDiagnostic (режим -Source SFTP).
foreach ($moduleName in @('BRAVO.Compatibility', 'BRAVO.Credentials', 'BRAVO.ArchiveHelpers', 'BRAVO.Logging', 'BRAVO.Console', 'BRAVO.ExitCodes', 'BRAVO.ArchiveRuntime')) {
    $modulePath = Join-Path $bravoScriptDirectory "modules\$moduleName\$moduleName.psd1"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Не знайдено спільний PowerShell-модуль: $modulePath"
    }
    Import-Module -Name $modulePath -ErrorAction Stop
}
Assert-BRAVOPowerShellCompatibility
[void](Initialize-BRAVOConsoleEncoding -CodePage 65001)
$notificationHelpersPath = Join-Path $bravoScriptDirectory 'modules\BRAVO.Notifications\BRAVO.Notifications.psd1'
if (-not (Test-Path -LiteralPath $notificationHelpersPath -PathType Leaf)) {
    throw "Не знайдено PowerShell-модуль notifications: $notificationHelpersPath"
}
Import-Module -Name $notificationHelpersPath -ErrorAction Stop

# Один зовнішній try/finally: exit усередині try гарантовано проходить крізь
# усі finally на своєму шляху, тому ручна пауза охоплює кожну точку виходу
# (той самий принцип, що BRAVO_MAINTENANCE).
try {

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $bravoScriptDirectory "BRAVO.config"
}

# Елевація потрібна всім режимам, що виконують реальні дії (7-Zip у
# production-каталоги, керування службами, ACL). -ListGenerations — read-only
# перегляд і виконується без елевації (як BRAVO_RESTORE_TEST). SYSTEM не має
# інтерактивного UAC-сеансу, Start-Process -Verb RunAs там повертає 0x80070001.
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isLocalSystem = $currentIdentity.User.Value -eq 'S-1-5-18'
if (-not $ListGenerations -and -not $isLocalSystem -and -not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $elevatedArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$EntryScriptPath`"")
    if (-not [string]::IsNullOrWhiteSpace($GenerationId)) { $elevatedArguments += @("-GenerationId", $GenerationId) }
    $elevatedArguments += @("-Component", $Component, "-Mode", $Mode, "-Source", $Source)
    if (-not [string]::IsNullOrWhiteSpace($TargetPath)) { $elevatedArguments += @("-TargetPath", "`"$TargetPath`"") }
    if (-not [string]::IsNullOrWhiteSpace($StagingPath)) { $elevatedArguments += @("-StagingPath", "`"$StagingPath`"") }
    if ($Force) { $elevatedArguments += "-Force" }
    if ($SkipHealthCheck) { $elevatedArguments += "-SkipHealthCheck" }
    if ($TimeoutSeconds -gt 0) { $elevatedArguments += @("-TimeoutSeconds", [string]$TimeoutSeconds) }
    if ($NoPause) { $elevatedArguments += "-NoPause" }
    $elevatedArguments += @("-ConfigPath", "`"$ConfigPath`"")
    $elevatedProcess = Start-Process powershell.exe -ArgumentList $elevatedArguments -Verb RunAs -Wait -PassThru
    Exit $elevatedProcess.ExitCode
}

# Примусово TLS 1.2 для webhook-сповіщень. Числове значення 3072 сумісне зі
# старими .NET/PowerShell, де ім'я Tls12 може бути відсутнім у переліку enum.
[Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
[Net.ServicePointManager]::Expect100Continue = $false

# ===== СТАН ПРОГОНУ =====
# Set-StrictMode успадковується від конфігураційного завантажувача, тому весь
# стан ініціалізується явно до першого читання.
$script:ScriptStartTime = [DateTime]::Now
$script:dataRestoreControlledAbort = $false
$script:dataRestoreAbortReason = $null
$script:flagInvalidConfiguration = $false
$script:flagCredentialsUnavailable = $false
$script:flagIntegrityTestFailed = $false
$script:flagHashValidationFailed = $false
$script:flagRestoreFailed = $false
$script:flagSftpFailed = $false
$script:flagInternalError = $false
$script:dataRestoreWarningCount = 0
$script:dataRestoreComponentResults = New-Object System.Collections.ArrayList
$script:dataRestoreOperationLock = $null
$script:dataRestoreOperationLockPath = $null
$script:dataRestoreServiceSnapshot = $null
$script:dataRestoreServicesStopped = $false
$script:dataRestoreHealthExitCode = $null
$script:dataRestoreSelectedGenerationId = $null
$script:dataRestoreStagingGenerationRoot = $null
$script:dataRestoreStagingKept = $false
$script:dataRestoreLogFile = $null
$script:dataRestoreSftpUrl = $null
$script:dataRestoreTemporaryRoot = $null
$script:archivePassword = $null

# ===== ЗАВАНТАЖЕННЯ НАЛАШТУВАНЬ =====
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Write-Host "ПОМИЛКА: Не знайдено конфігураційний файл: $ConfigPath" -ForegroundColor Red
    exit 30
}
try {
    $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $configRoot = Split-Path -Path $ConfigPath -Parent
    $configurationLoaderPath = Join-Path $bravoScriptDirectory 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration `
        -ConfigRoot $configRoot `
        -ConfigPath $ConfigPath `
        -RuntimeRoot $bravoScriptDirectory
    $script:ScriptVersion = [string]$global:ScriptVersion
    $script:ScriptDate = [string]$global:ScriptDate
    $script:ScriptBuildId = [string]$global:ScriptBuildId

    if ($null -eq $credentialSettings -or
        $null -eq (Get-Command -Name Initialize-BRAVOCredentialManager -ErrorAction SilentlyContinue)) {
        throw "вбудований Credential Manager недоступний"
    }
    [void](Import-BRAVOInstitutionSettings `
        -CredentialSettings $credentialSettings `
        -BravoSettings $bravoSettings)

    # Обов'язкові для відновлення значення конфігурації — усі з наявних
    # секцій, жодного нового ключа BRAVO.config цей runtime не вводить.
    $requiredScalarValues = @(
        @{ Name = 'operationLockSettings.Path'; Value = [string]$operationLockSettings.Path },
        @{ Name = 'backupRootPath (EffectiveBackupRoot)'; Value = [string]$backupRootPath },
        @{ Name = 'arcPath (Tools\7za.exe)'; Value = [string]$arcPath },
        @{ Name = 'toolsPath'; Value = [string]$toolsPath },
        @{ Name = 'runtimeLogRoot'; Value = [string]$global:runtimeLogRoot },
        @{ Name = 'maintenanceSettings.Services.BravoName'; Value = [string]$maintenanceSettings.Services.BravoName },
        @{ Name = 'maintenanceSettings.Services.ExchangeApiName'; Value = [string]$maintenanceSettings.Services.ExchangeApiName }
    )
    foreach ($requiredScalar in $requiredScalarValues) {
        if ([string]::IsNullOrWhiteSpace([string]$requiredScalar.Value)) {
            throw "У конфігурації відсутній обов'язковий параметр '$($requiredScalar.Name)'"
        }
    }
    if ($null -eq $global:archiveDefinitions -or @($global:archiveDefinitions).Count -eq 0) {
        throw "У конфігурації відсутній обов'язковий параметр 'archiveDefinitions'"
    }
    if ($null -eq $maintenanceSettings.Limits -or $null -eq $maintenanceSettings.Limits.MinimumFreeSpaceGB) {
        throw "У конфігурації відсутній обов'язковий параметр 'maintenanceSettings.Limits.MinimumFreeSpaceGB'"
    }
    if ($null -eq $global:progressSettings -or $null -eq $progressSettings.SevenZipTimeoutSeconds) {
        throw "У конфігурації відсутній обов'язковий параметр 'progressSettings.SevenZipTimeoutSeconds'"
    }
    if ($null -eq $global:schedulerSettings -or -not $schedulerSettings.Contains('OperationLockWaitMinutes')) {
        throw "У конфігурації відсутній обов'язковий параметр 'schedulerSettings.OperationLockWaitMinutes'"
    }
} catch {
    Write-Host "ПОМИЛКА читання конфігурації '$ConfigPath': $(Protect-BRAVOLogSecret -Text $_.Exception.Message)" -ForegroundColor Red
    exit 30
}

# Ефективні значення прогону.
$script:effectiveSevenZipTimeoutSeconds = if ($TimeoutSeconds -gt 0) {
    $TimeoutSeconds
} else {
    [int]$progressSettings.SevenZipTimeoutSeconds
}
$stagingRootPath = if ([string]::IsNullOrWhiteSpace($StagingPath)) {
    Join-Path $backupRootPath 'RESTORE_STAGING'
} else {
    [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StagingPath))
}
$serviceStartTimeoutSeconds = if ([int]$maintenanceSettings.Services.StartTimeoutSeconds -gt 0) {
    [int]$maintenanceSettings.Services.StartTimeoutSeconds
} else { 180 }
$serviceStopTimeoutSeconds = if ([int]$maintenanceSettings.Services.StopTimeoutSeconds -gt 0) {
    [int]$maintenanceSettings.Services.StopTimeoutSeconds
} else { 120 }
$servicePollIntervalSeconds = if ([int]$maintenanceSettings.Services.PollIntervalSeconds -gt 0) {
    [int]$maintenanceSettings.Services.PollIntervalSeconds
} else { 2 }
$runTimestamp = $script:ScriptStartTime.ToString('yyyyMMdd_HHmmss')

# ===== ЖУРНАЛ =====
$script:dataRestoreLogFile = Join-Path $global:runtimeLogRoot ("BRAVO_DATA_RESTORE_{0}_PID{1}.log" -f $runTimestamp, $PID)
Initialize-BRAVOLog -LogFile $script:dataRestoreLogFile -FileLevel 'INFO' -ConsoleLevel 'WARNING'

function Write-DataRestoreLog {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [string]$Level = 'INFO',
        [switch]$Console
    )
    Write-BRAVOLog -Message $Message -Level $Level -Component 'DATARESTORE' -Console:$Console
}

# Test-only deterministic failpoint для acceptance-тестів cross-component
# rollback (B20 і подібні). НЕ CLI-параметр, НЕ config-ключ, НЕ
# документована production-функція — активується виключно двома явними
# process environment variables, обидва мають точно збігтися. За
# відсутності/некоректності будь-якого з двох факторів — no-op, БЕЗ жодного
# side effect (файлова система/служби/мережа/config не торкаються).
#
# TWO-FACTOR guard (жодна змінна сама по собі недостатня):
#   BRAVO_DATARESTORE_TEST_HOOKS     — має дорівнювати РІВНО "ACCEPTANCE_ONLY"
#                                       (case-sensitive sentinel).
#   BRAVO_DATARESTORE_TEST_FAILPOINT — canonical форма "Point:Component",
#                                       напр. "AfterMoveAside:BAZA".
#
# Порівняння Point/Component — точна case-insensitive рівність (жодних
# wildcard/regex/substring/"All"). Викликається виключно з існуючого
# production pipeline у точці, де реальна помилка мала б статися
# природно — throw тут не створює окремого test-only rollback шляху:
# виняток летить у той самий catch, що обробляє й реальні відмови.
function Invoke-BRAVODataRestoreTestFailPoint {
    param(
        [Parameter(Mandatory = $true)][string]$Point,
        [Parameter(Mandatory = $true)][string]$Component
    )

    $hooksGuard = [string]$env:BRAVO_DATARESTORE_TEST_HOOKS
    if (-not [string]::Equals($hooksGuard, 'ACCEPTANCE_ONLY', [StringComparison]::Ordinal)) {
        return
    }

    $failPointRaw = [string]$env:BRAVO_DATARESTORE_TEST_FAILPOINT
    if ([string]::IsNullOrWhiteSpace($failPointRaw)) {
        return
    }

    $failPointParts = $failPointRaw -split ':', 2
    if ($failPointParts.Count -ne 2) {
        return
    }

    $configuredPoint = $failPointParts[0].Trim()
    $configuredComponent = $failPointParts[1].Trim()
    if ([string]::IsNullOrWhiteSpace($configuredPoint) -or [string]::IsNullOrWhiteSpace($configuredComponent)) {
        return
    }

    if (-not [string]::Equals($configuredPoint, $Point, [StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    if (-not [string]::Equals($configuredComponent, $Component, [StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    throw "BRAVO_DATARESTORE_TEST_FAILPOINT: deterministic test-injected failure at $configuredPoint for component $configuredComponent"
}

# Контрольоване переривання пайплайна: виставляє категорію для контракту
# кодів завершення й кидає виняток, який головний catch розпізнає як
# заплановану зупинку (не InternalError). Використовується ПІСЛЯ захоплення
# lock — раніші відмови виходять літеральними exit 30/31/32, як у Maintenance.
function Stop-BRAVODataRestoreRun {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('InvalidConfiguration', 'CredentialsUnavailable', 'IntegrityTestFailed', 'HashValidationFailed', 'RestoreFailed', 'SftpFailed')]
        [string]$Category,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    switch ($Category) {
        'InvalidConfiguration'  { $script:flagInvalidConfiguration = $true }
        'CredentialsUnavailable' { $script:flagCredentialsUnavailable = $true }
        'IntegrityTestFailed'   { $script:flagIntegrityTestFailed = $true }
        'HashValidationFailed'  { $script:flagHashValidationFailed = $true }
        'RestoreFailed'         { $script:flagRestoreFailed = $true }
        'SftpFailed'            { $script:flagSftpFailed = $true }
    }
    $script:dataRestoreControlledAbort = $true
    $script:dataRestoreAbortReason = $Reason
    Write-DataRestoreLog -Message "ЗУПИНКА ($Category): $Reason" -Level 'ERROR'
    throw "DATA_RESTORE_ABORT: $Reason"
}

function Test-BRAVODataRestorePathWithin {
    # Чи лежить Path строго всередині Directory (нормалізовані повні шляхи,
    # OrdinalIgnoreCase — NTFS нечутлива до регістру).
    param([string]$Path, [string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Directory)) {
        return $false
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $fullDirectory = [System.IO.Path]::GetFullPath($Directory)
        $directoryPrefix = $fullDirectory.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        return $fullPath.StartsWith($directoryPrefix, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        # Некоректний шлях безпечніше вважати "всередині" (заборонити), ніж дозволити.
        return $true
    }
}

function Test-BRAVODataRestorePathEquals {
    param([string]$First, [string]$Second)

    if ([string]::IsNullOrWhiteSpace($First) -or [string]::IsNullOrWhiteSpace($Second)) {
        return $false
    }
    try {
        $firstFull = [System.IO.Path]::GetFullPath($First).TrimEnd('\', '/')
        $secondFull = [System.IO.Path]::GetFullPath($Second).TrimEnd('\', '/')
        return [string]::Equals($firstFull, $secondFull, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $true
    }
}

function Test-BRAVODataRestoreAsciiPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return ($Path -match '^[\x20-\x7E]+$')
}

function Test-BRAVODataRestoreToolIntegrity {
    # Той самий Enforce/Warn-контракт, що Test-Compatibility у Archive:
    # runtime виконує 7za.exe/WinSCP.com від імені адміністратора, тому
    # перед запуском інструмент звіряється з version-controlled
    # TOOLS_MANIFEST.json.
    param([Parameter(Mandatory = $true)][string[]]$ToolNames)

    $integrityMode = 'Enforce'
    $manifestPath = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$toolIntegritySettings.Mode)) {
            $integrityMode = [string]$toolIntegritySettings.Mode
        }
        $manifestPath = [string]$toolIntegritySettings.ManifestPath
    } catch {
        $manifestPath = $null
    }
    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
        $manifestPath = Join-Path $toolsPath 'TOOLS_MANIFEST.json'
    }

    $problems = @()
    $manifestTools = $null
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $problems += "маніфест інструментів не знайдено: $manifestPath"
    } else {
        try {
            $manifestDocument = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -ErrorAction Stop
            $manifestTools = $manifestDocument.tools
        } catch {
            $problems += "маніфест інструментів не прочитано: $($_.Exception.Message)"
        }
    }
    if ($null -ne $manifestTools) {
        foreach ($toolName in $ToolNames) {
            $toolPath = Join-Path $toolsPath $toolName
            $expectedProperty = $manifestTools.PSObject.Properties[$toolName]
            if ($null -eq $expectedProperty -or [string]::IsNullOrWhiteSpace([string]$expectedProperty.Value)) {
                $problems += "у TOOLS_MANIFEST.json немає еталонного хешу для $toolName"
                continue
            }
            if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
                $problems += "інструмент не знайдено: $toolPath"
                continue
            }
            $actualHash = (Get-BRAVOFileHash -Path $toolPath -Algorithm SHA256).Hash
            if (-not [string]::Equals($actualHash, [string]$expectedProperty.Value, [StringComparison]::OrdinalIgnoreCase)) {
                $problems += "хеш $toolName не збігається з TOOLS_MANIFEST.json (можлива підміна інструменту)"
            }
        }
    }
    return [pscustomobject]@{
        Mode = $integrityMode
        Problems = @($problems)
    }
}

function Enter-BRAVODataRestoreOperationLock {
    # Canonical machine-wide operation lock — той самий контракт і файл, що
    # Archive/Maintenance ($operationLockSettings.Path): активність визначає
    # ексклюзивний handle, а не існування файла; метадані лишаються після
    # завершення як остання діагностика.
    $lockPath = [string]$operationLockSettings.Path
    try {
        if ([string]::IsNullOrWhiteSpace($lockPath)) {
            throw 'operationLockSettings.Path не задано'
        }
        $lockDirectory = Split-Path -Path $lockPath -Parent
        if (-not (Test-Path -LiteralPath $lockDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $lockDirectory -Force -ErrorAction Stop)
        }
        $waitMinutes = [math]::Max(0, [int]$schedulerSettings.OperationLockWaitMinutes)
        $deadline = (Get-Date).AddMinutes($waitMinutes)
        $stream = $null
        $lastLockError = $null
        do {
            try {
                $stream = [System.IO.File]::Open(
                    $lockPath,
                    [System.IO.FileMode]::OpenOrCreate,
                    [System.IO.FileAccess]::ReadWrite,
                    [System.IO.FileShare]::None
                )
            } catch {
                $lastLockError = $_.Exception.Message
                if ((Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 30
                }
            }
        } while ($null -eq $stream -and (Get-Date) -lt $deadline)
        if ($null -eq $stream) {
            throw "lock не звільнився за $waitMinutes хв.: $lastLockError"
        }
        $lockProcessStartTime = try {
            (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToString("o")
        } catch {
            $null
        }
        $lockText = ([pscustomobject]@{
            pid = $PID
            processStartTime = $lockProcessStartTime
            hostname = [Environment]::MachineName
            operation = "DataRestore"
            startedAt = (Get-Date).ToString("o")
            packageVersion = [string]$script:ScriptVersion
            config = $ConfigPath
            generationId = $null
        } | ConvertTo-Json -Compress)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($lockText)
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        return [pscustomobject]@{
            Success = $true
            Stream = $stream
            Path = $lockPath
            Error = $null
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Stream = $null
            Path = $lockPath
            Error = $_.Exception.Message
        }
    }
}

function Exit-BRAVODataRestoreOperationLock {
    if ($script:dataRestoreOperationLock) {
        $script:dataRestoreOperationLock.Dispose()
        $script:dataRestoreOperationLock = $null
    }
    # Файл метаданих навмисно лишається: активність визначає лише handle.
    $script:dataRestoreOperationLockPath = $null
}

function Get-BRAVODataRestoreGenerationCandidates {
    # Швидкий огляд наявних generation для -ListGenerations і журналу:
    # прапорці manifest + фізична наявність артефактів + парсинг sidecar,
    # БЕЗ перерахунку SHA512 (не хешувати десятки ГБ на кожен перегляд —
    # повний перерахунок робить строгий gate перед фактичним відновленням).
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [int]$Limit = 25
    )

    $candidates = @()
    foreach ($manifestFile in @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $BackupRoot)) {
        try {
            $manifest = [IO.File]::ReadAllText($manifestFile.FullName) | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }
        $createdAt = $manifestFile.LastWriteTime
        foreach ($dateProperty in @('createdAt', 'startedAt')) {
            $property = $manifest.PSObject.Properties[$dateProperty]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                try { $createdAt = [datetime]$property.Value } catch {
                    # Нечитабельна дата в manifest не дискваліфікує generation:
                    # лишаємо LastWriteTime файлу як сортувальний fallback.
                }
                break
            }
        }
        $componentSummaries = @()
        $componentsProperty = $manifest.PSObject.Properties['components']
        if ($null -ne $componentsProperty -and $null -ne $componentsProperty.Value) {
            foreach ($componentProperty in @($componentsProperty.Value.PSObject.Properties)) {
                $state = $componentProperty.Value
                if (-not [bool]$state.Enabled) { continue }
                $summary = 'OK'
                if (-not ([bool]$state.CreateSuccess -and [bool]$state.IntegritySuccess -and [bool]$state.HashSuccess)) {
                    $summary = 'НЕПОВНИЙ'
                } elseif (-not ((Test-Path -LiteralPath ([string]$state.ArchivePath) -PathType Leaf) -and
                        (Test-Path -LiteralPath ([string]$state.HashPath) -PathType Leaf))) {
                    $summary = 'НЕМАЄ ФАЙЛІВ'
                } else {
                    try {
                        $sidecarText = ([IO.File]::ReadAllText([string]$state.HashPath)).Trim([char]0xFEFF).Trim()
                        $archiveLeafName = Split-Path ([string]$state.ArchivePath) -Leaf
                        if ($sidecarText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$' -or
                            $Matches.FileName -cne $archiveLeafName) {
                            $summary = 'SIDECAR?'
                        }
                    } catch {
                        $summary = 'SIDECAR?'
                    }
                }
                $componentSummaries += ("{0}:{1}" -f $componentProperty.Name, $summary)
            }
        }
        $candidates += [pscustomobject]@{
            GenerationId = [string]$manifest.generationId
            Status = [string]$manifest.status
            CreatedAt = $createdAt
            ComponentSummary = ($componentSummaries -join '  ')
        }
    }
    return @($candidates | Sort-Object CreatedAt -Descending | Select-Object -First ([math]::Max(1, $Limit)))
}

function Get-BRAVODataRestoreComponentSelection {
    # Перелік компонентів для відновлення: запитане ∩ увімкнене у manifest.
    # Явно запитаний компонент, якого немає або який вимкнено в manifest, —
    # керована відмова (RestoreFailed), а не мовчазний пропуск.
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$RequestedComponent
    )

    $componentsProperty = $Manifest.PSObject.Properties['components']
    if ($null -eq $componentsProperty -or $null -eq $componentsProperty.Value) {
        throw 'generation manifest не містить components'
    }
    $canonicalOrder = @('MODEL', 'BLOG', 'BRAVOEXCH')
    $enabledTypes = @()
    foreach ($canonicalType in $canonicalOrder) {
        $componentProperty = @($componentsProperty.Value.PSObject.Properties | Where-Object {
            [string]::Equals($_.Name, $canonicalType, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($componentProperty.Count -gt 0 -and [bool]$componentProperty[0].Value.Enabled) {
            $enabledTypes += $canonicalType
        }
    }
    if ($RequestedComponent -ne 'All') {
        if ($enabledTypes -notcontains $RequestedComponent) {
            throw "generation не містить увімкненого компонента $RequestedComponent"
        }
        return @($RequestedComponent)
    }
    if ($enabledTypes.Count -eq 0) {
        throw 'у generation немає жодного увімкненого archive-компонента'
    }
    return @($enabledTypes)
}

function Get-BRAVODataRestorePlan {
    # План цілей відновлення: для кожного компонента — куди розпаковувати і
    # (для InPlace) куди зносити вбік поточні дані. Уся валідація шляхів
    # зосереджена тут; функція нічого не змінює на диску (unit-testable).
    param(
        [Parameter(Mandatory = $true)][string[]]$ComponentTypes,
        [Parameter(Mandatory = $true)][string]$RestoreMode,
        [string]$RequestedTargetPath,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeRootPath,
        [Parameter(Mandatory = $true)][string]$StagingRoot,
        [Parameter(Mandatory = $true)][object[]]$ArchiveDefinitions,
        [Parameter(Mandatory = $true)][string]$RunStamp
    )

    $liveSources = @{}
    foreach ($definition in $ArchiveDefinitions) {
        $definitionSource = [string]$definition.Source
        $liveSources[[string]$definition.Type] = if ([string]::IsNullOrWhiteSpace($definitionSource)) {
            $null
        } else {
            Split-Path $definitionSource -Parent
        }
    }

    $planComponents = @()
    if ($RestoreMode -eq 'OutOfPlace') {
        if ([string]::IsNullOrWhiteSpace($RequestedTargetPath)) {
            return [pscustomobject]@{ Success = $false; Error = 'для режиму OutOfPlace обов''язковий параметр -TargetPath'; TargetRoot = $null; Components = @() }
        }
        $expandedTarget = [Environment]::ExpandEnvironmentVariables($RequestedTargetPath)
        if (-not [System.IO.Path]::IsPathRooted($expandedTarget)) {
            return [pscustomobject]@{ Success = $false; Error = "-TargetPath має бути абсолютним шляхом: $RequestedTargetPath"; TargetRoot = $null; Components = @() }
        }
        try {
            $targetRoot = [System.IO.Path]::GetFullPath($expandedTarget)
        } catch {
            return [pscustomobject]@{ Success = $false; Error = "-TargetPath некоректний: $($_.Exception.Message)"; TargetRoot = $null; Components = @() }
        }
        if (Test-Path -LiteralPath $targetRoot -PathType Leaf) {
            return [pscustomobject]@{ Success = $false; Error = "-TargetPath вказує на файл, а не каталог: $targetRoot"; TargetRoot = $null; Components = @() }
        }
        # Заборонені цілі: комплект, резервні копії, staging, live-джерела —
        # у будь-який бік вкладеності. Відновлення ПОВЕРХ цих місць або
        # НАВКОЛО них зробило б retention/backup/runtime непередбачуваними.
        $forbiddenDirectories = @(
            @{ Name = 'BackupRoot'; Path = $BackupRoot },
            @{ Name = 'RuntimeRoot'; Path = $RuntimeRootPath },
            @{ Name = 'staging'; Path = $StagingRoot }
        )
        foreach ($componentType in $ComponentTypes) {
            if (-not [string]::IsNullOrWhiteSpace([string]$liveSources[$componentType])) {
                $forbiddenDirectories += @{ Name = "live-джерело $componentType"; Path = [string]$liveSources[$componentType] }
            }
        }
        foreach ($forbidden in $forbiddenDirectories) {
            if ((Test-BRAVODataRestorePathEquals -First $targetRoot -Second $forbidden.Path) -or
                (Test-BRAVODataRestorePathWithin -Path $targetRoot -Directory $forbidden.Path) -or
                (Test-BRAVODataRestorePathWithin -Path $forbidden.Path -Directory $targetRoot)) {
                return [pscustomobject]@{ Success = $false; Error = "-TargetPath перетинається з захищеним розташуванням ($($forbidden.Name)): $($forbidden.Path)"; TargetRoot = $null; Components = @() }
            }
        }
        foreach ($componentType in $ComponentTypes) {
            $componentTarget = Join-Path $targetRoot $componentType
            if (Test-Path -LiteralPath $componentTarget -PathType Leaf) {
                return [pscustomobject]@{ Success = $false; Error = "ціль компонента існує як файл: $componentTarget"; TargetRoot = $null; Components = @() }
            }
            if (Test-Path -LiteralPath $componentTarget -PathType Container) {
                $existingChildren = @(Get-ChildItem -LiteralPath $componentTarget -Force -ErrorAction Stop)
                if ($existingChildren.Count -gt 0) {
                    return [pscustomobject]@{ Success = $false; Error = "ціль компонента не порожня (нічого не перезаписуємо): $componentTarget"; TargetRoot = $null; Components = @() }
                }
            }
            $planComponents += [pscustomobject]@{
                Type = $componentType
                LiveSourceDirectory = [string]$liveSources[$componentType]
                TargetDirectory = $componentTarget
                PrerestoreDirectory = $null
            }
        }
        return [pscustomobject]@{ Success = $true; Error = $null; TargetRoot = $targetRoot; Components = @($planComponents) }
    }

    # InPlace: -TargetPath заборонений (щоб оператор не міг ДУМАТИ, що керує
    # ціллю, коли нею керує discovery), джерело кожного компонента має бути
    # однозначно визначене — мовчазний fallback заборонений проєктом.
    if (-not [string]::IsNullOrWhiteSpace($RequestedTargetPath)) {
        return [pscustomobject]@{ Success = $false; Error = 'для режиму InPlace параметр -TargetPath заборонений: ціль визначає discovery (bravo.ini)'; TargetRoot = $null; Components = @() }
    }
    foreach ($componentType in $ComponentTypes) {
        $liveSource = [string]$liveSources[$componentType]
        if ([string]::IsNullOrWhiteSpace($liveSource)) {
            return [pscustomobject]@{ Success = $false; Error = "live-джерело компонента $componentType не визначено (bravo.ini/discovery) — InPlace неможливий"; TargetRoot = $null; Components = @() }
        }
        $prerestoreBase = "{0}.prerestore_{1}" -f $liveSource.TrimEnd('\', '/'), $RunStamp
        $prerestoreDirectory = $prerestoreBase
        $collisionIndex = 1
        while (Test-Path -LiteralPath $prerestoreDirectory) {
            $prerestoreDirectory = "{0}_{1}" -f $prerestoreBase, $collisionIndex
            $collisionIndex++
        }
        $planComponents += [pscustomobject]@{
            Type = $componentType
            LiveSourceDirectory = $liveSource
            TargetDirectory = $liveSource
            PrerestoreDirectory = $prerestoreDirectory
        }
    }
    return [pscustomobject]@{ Success = $true; Error = $null; TargetRoot = $null; Components = @($planComponents) }
}

function Get-BRAVOSevenZipArchiveInventory {
    # Інвентаризація архіву БЕЗ розпакування: кількість файлів/каталогів і
    # сумарний нестиснутий розмір (free-space preflight + post-verify еталон).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Пароль передається 7-Zip через redirected stdin (не в аргументи процесу) — той самий патерн, що Invoke-BRAVOSevenZipIntegrityTest.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SevenZipPath,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Password,
        [int]$TimeoutSeconds = 43200
    )

    $process = $null
    $capture = $null
    $timedOut = $false
    $exitCode = $null
    try {
        if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
            throw "архів не знайдено: $ArchivePath"
        }
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $SevenZipPath
        $processInfo.Arguments = "l -slt `"$ArchivePath`""
        $processInfo.RedirectStandardInput = $true
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $capture = Start-BRAVOProcessOutputCapture -Process $process
        $process.StandardInput.WriteLine($Password)
        $process.StandardInput.Close()

        if ($TimeoutSeconds -gt 0) {
            $completed = $process.WaitForExit([int][math]::Min([double][int]::MaxValue, [double]$TimeoutSeconds * 1000))
        } else {
            $process.WaitForExit()
            $completed = $true
        }
        if (-not $completed) {
            $timedOut = $true
            try { $process.Kill(); [void]$process.WaitForExit(5000) } catch {
                # Kill процесу, що вже завершився сам, кидає InvalidOperation —
                # результат той самий (процес мертвий), логувати нічого.
            }
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $capture
        $capture = $null
        if ($process.HasExited) { $exitCode = [int]$process.ExitCode }
        if ($timedOut -or $exitCode -ne 0) {
            return [pscustomobject]@{
                Success = $false
                FileCount = 0
                DirectoryCount = 0
                TotalUncompressedBytes = [long]0
                Description = (Get-BRAVOSevenZipExitCodeDescription -ExitCode $exitCode -TimedOut:$timedOut)
            }
        }

        $fileCount = 0
        $directoryCount = 0
        $totalBytes = [long]0
        $inEntries = $false
        $currentIsDirectory = $false
        $currentSize = [long]0
        $currentOpen = $false
        foreach ($outputLine in ([string]$capturedOutput.StandardOutput -split "\r?\n")) {
            if (-not $inEntries) {
                if ($outputLine -match '^-{5,}\s*$') { $inEntries = $true }
                continue
            }
            if ($outputLine -match '^Path = ') {
                if ($currentOpen) {
                    if ($currentIsDirectory) { $directoryCount++ } else { $fileCount++; $totalBytes += $currentSize }
                }
                $currentOpen = $true
                $currentIsDirectory = $false
                $currentSize = [long]0
                continue
            }
            if (-not $currentOpen) { continue }
            if ($outputLine -match '^Size = (\d+)\s*$') {
                $currentSize = [long]$Matches[1]
            } elseif ($outputLine -match '^Attributes = (\S+)') {
                if (([string]$Matches[1]).StartsWith('D')) { $currentIsDirectory = $true }
            } elseif ($outputLine -match '^Folder = \+') {
                $currentIsDirectory = $true
            }
        }
        if ($currentOpen) {
            if ($currentIsDirectory) { $directoryCount++ } else { $fileCount++; $totalBytes += $currentSize }
        }
        return [pscustomobject]@{
            Success = $true
            FileCount = $fileCount
            DirectoryCount = $directoryCount
            TotalUncompressedBytes = $totalBytes
            Description = $null
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            FileCount = 0
            DirectoryCount = 0
            TotalUncompressedBytes = [long]0
            Description = $_.Exception.Message
        }
    } finally {
        if ($null -ne $capture) {
            try { [void](Complete-BRAVOProcessOutputCapture -Capture $capture) } catch {
                # Cleanup-гілка після помилки: збій закриття capture не має
                # маскувати первинний exception, який зараз летить нагору.
            }
        }
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Test-BRAVODataRestoreFreeSpace {
    # Free-space preflight ДО будь-якої зміни на диску: агрегує вимоги по
    # томах, вимагає, щоб ПІСЛЯ відновлення лишався поріг
    # maintenanceSettings.Limits.MinimumFreeSpaceGB, і write-probe-ом
    # перевіряє фактичну можливість запису. UNC-цілі перевіряються лише
    # write-probe-ом (розмір вільного місця share надійно не визначається).
    param(
        [Parameter(Mandatory = $true)][object[]]$Requirements,
        [Parameter(Mandatory = $true)][double]$MinimumFreeGigabytes
    )

    $problems = @()
    $notes = @()
    $volumeRequiredBytes = @{}
    foreach ($requirement in $Requirements) {
        $targetDirectory = [string]$requirement.TargetDirectory
        try {
            $volumeRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($targetDirectory))
        } catch {
            $problems += "некоректний шлях цілі: $targetDirectory"
            continue
        }
        if ([string]::IsNullOrWhiteSpace($volumeRoot)) {
            $problems += "не визначено том для цілі: $targetDirectory"
            continue
        }
        if (-not $volumeRequiredBytes.ContainsKey($volumeRoot)) {
            $volumeRequiredBytes[$volumeRoot] = [long]0
        }
        $volumeRequiredBytes[$volumeRoot] = [long]$volumeRequiredBytes[$volumeRoot] + [long]$requirement.RequiredBytes
    }
    foreach ($volumeRoot in @($volumeRequiredBytes.Keys)) {
        if ($volumeRoot.StartsWith('\\')) {
            $notes += "том $volumeRoot — мережевий: перевірка вільного місця пропущена, лишається write-probe"
            continue
        }
        try {
            $driveInfo = New-Object System.IO.DriveInfo($volumeRoot)
            $availableBytes = [long]$driveInfo.AvailableFreeSpace
        } catch {
            $problems += "не вдалося визначити вільне місце тому ${volumeRoot}: $($_.Exception.Message)"
            continue
        }
        $requiredBytes = [long]$volumeRequiredBytes[$volumeRoot]
        $floorBytes = [long]($MinimumFreeGigabytes * 1GB)
        if (($availableBytes - $requiredBytes) -lt $floorBytes) {
            $problems += ("недостатньо місця на {0}: доступно {1}, потрібно {2} + резерв {3}" -f `
                $volumeRoot,
                (Format-BRAVOFileSize -Bytes $availableBytes),
                (Format-BRAVOFileSize -Bytes $requiredBytes),
                (Format-BRAVOFileSize -Bytes $floorBytes))
        }
    }
    foreach ($requirement in $Requirements) {
        $probeDirectory = [string]$requirement.TargetDirectory
        try {
            $probeDirectory = [System.IO.Path]::GetFullPath($probeDirectory)
        } catch {
            continue
        }
        while (-not [string]::IsNullOrWhiteSpace($probeDirectory) -and
            -not (Test-Path -LiteralPath $probeDirectory -PathType Container)) {
            $probeDirectory = Split-Path -Path $probeDirectory -Parent
        }
        if ([string]::IsNullOrWhiteSpace($probeDirectory)) {
            $problems += "не знайдено жодного наявного батьківського каталогу для цілі: $($requirement.TargetDirectory)"
            continue
        }
        $probeFile = Join-Path $probeDirectory ("BRAVO_DATA_RESTORE_PROBE_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
        try {
            [IO.File]::WriteAllText($probeFile, 'probe')
            Remove-Item -LiteralPath $probeFile -Force -ErrorAction Stop
        } catch {
            $problems += "write-probe не пройдено для ${probeDirectory}: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{
        Success = ($problems.Count -eq 0)
        Problems = @($problems)
        Notes = @($notes)
    }
}

function Set-BRAVODataRestoreCreatedDirectoryAcl {
    # ACL для щойно СТВОРЕНОГО нами out-of-place каталогу: лише SYSTEM,
    # Administrators і поточний обліковий запис — видобуті дані LIMS не
    # мають бути читабельні іншим користувачам машини (той самий патерн, що
    # RestoreDrill у BRAVO_RESTORE_TEST.ps1). ACL наявних каталогів не
    # змінюємо — вони належать операторові.
    param([Parameter(Mandatory = $true)][string]$Path)

    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $none = [Security.AccessControl.PropagationFlags]::None
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }
    $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $accessSids = @("S-1-5-18", "S-1-5-32-544") + @([string]$currentUserSid) | Select-Object -Unique
    foreach ($sidText in $accessSids) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $none,
            $allow
        )))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Copy-BRAVODataRestoreDirectoryAcl {
    # InPlace: свіжостворений каталог має успадкувати фактичні права
    # знесеного вбік попередника, а не права батьківського каталогу —
    # інакше служба BRAVO може втратити доступ до власної моделі.
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    $sourceAcl = Get-Acl -LiteralPath $SourceDirectory
    Set-Acl -LiteralPath $DestinationDirectory -AclObject $sourceAcl
}

function Get-BRAVODataRestoreServiceSnapshot {
    # Знімок стану трьох керованих служб ДО будь-яких дій. Дзеркало підходу
    # Maintenance ($serviceWasRunning + Get-ConfiguredServiceState): відсутня
    # або системно відключена (Disabled) служба не керується взагалі.
    # BravoWeb резолвиться за списком кандидатів (Name або DisplayName) —
    # документований fallback-шлях самого Maintenance.
    param([Parameter(Mandatory = $true)][hashtable]$ServicesSettings)

    $resolveServiceState = {
        param([string]$ServiceName)
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        $startMode = ""
        if ($service) {
            try {
                $escapedName = $ServiceName.Replace("'", "''")
                $serviceInfo = Get-BRAVOWmiInstance `
                    -ClassName Win32_Service `
                    -Filter "Name = '$escapedName'" |
                    Select-Object -First 1
            } catch {
                $serviceInfo = $null
            }
            $startMode = if ($serviceInfo) { [string]$serviceInfo.StartMode } else { [string]$service.StartType }
        }
        [pscustomobject]@{
            Exists = ($null -ne $service)
            Disabled = ($startMode -ieq 'Disabled')
            Running = ($null -ne $service -and [string]$service.Status -eq 'Running')
        }
    }

    $bravoName = [string]$ServicesSettings.BravoName
    $exchangeName = [string]$ServicesSettings.ExchangeApiName
    $bravoWebEnabled = $true
    if ($ServicesSettings -is [System.Collections.IDictionary] -and $ServicesSettings.Contains('BravoWebEnabled')) {
        $bravoWebEnabled = [System.Convert]::ToBoolean($ServicesSettings.BravoWebEnabled)
    }
    $bravoWebName = $null
    if ($bravoWebEnabled) {
        $installedServices = @(Get-Service -ErrorAction SilentlyContinue)
        foreach ($candidate in @($ServicesSettings.BravoWebCandidates | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })) {
            $match = $installedServices | Where-Object {
                $_.Name -ieq $candidate -or $_.DisplayName -ieq $candidate
            } | Select-Object -First 1
            if ($match) { $bravoWebName = $match.Name; break }
        }
    }

    $entries = @()
    # Порядок елементів = порядок ЗУПИНКИ (BravoWeb -> exchangAPI -> BRAVO);
    # запуск виконується у зворотному порядку.
    foreach ($definition in @(
        @{ Key = 'BravoWeb'; Name = $bravoWebName; ComponentEnabled = $bravoWebEnabled; KillProcesses = @() },
        @{ Key = 'ExchangeApi'; Name = $exchangeName; ComponentEnabled = $true; KillProcesses = @() },
        @{ Key = 'Bravo'; Name = $bravoName; ComponentEnabled = $true; KillProcesses = @('Bis') }
    )) {
        $stateExists = $false
        $stateDisabled = $false
        $stateRunning = $false
        if ($definition.ComponentEnabled -and -not [string]::IsNullOrWhiteSpace([string]$definition.Name)) {
            $state = & $resolveServiceState ([string]$definition.Name)
            $stateExists = [bool]$state.Exists
            $stateDisabled = [bool]$state.Disabled
            $stateRunning = [bool]$state.Running
        }
        $entries += [pscustomobject]@{
            Key = [string]$definition.Key
            Name = [string]$definition.Name
            Managed = ($definition.ComponentEnabled -and $stateExists -and -not $stateDisabled)
            WasRunning = $stateRunning
            KillProcesses = @($definition.KillProcesses)
        }
    }
    return @($entries)
}

function Invoke-BRAVODataRestoreServiceStateChange {
    # Дзеркало Invoke-ServiceStateChange (Maintenance): команда + очікування
    # фактичного стану з таймаутом, без довіри до проміжних помилок cmdlet.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet("Running", "Stopped")][string]$DesiredStatus,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [int]$PollIntervalSeconds = 2,
        [switch]$Force
    )

    $operationErrors = @()
    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
        $service.Refresh()
        if ([string]$service.Status -eq $DesiredStatus) {
            return [pscustomobject]@{ Success = $true; AlreadyInState = $true; FinalStatus = [string]$service.Status; Error = $null }
        }
        if ($DesiredStatus -eq "Running") {
            Start-Service -Name $Name -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -ErrorVariable operationErrors
        } else {
            Stop-Service -Name $Name -Force:$Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -ErrorVariable operationErrors
        }
        $deadline = (Get-Date).AddSeconds([math]::Max(1, $TimeoutSeconds))
        $pollSeconds = [math]::Max(1, $PollIntervalSeconds)
        do {
            $service = Get-Service -Name $Name -ErrorAction Stop
            $service.Refresh()
            if ([string]$service.Status -eq $DesiredStatus) {
                return [pscustomobject]@{ Success = $true; AlreadyInState = $false; FinalStatus = [string]$service.Status; Error = $null }
            }
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds $pollSeconds
        } while ($true)
        $operationErrorText = @($operationErrors | ForEach-Object { $_.Exception.Message } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "; "
        $details = if ([string]::IsNullOrWhiteSpace($operationErrorText)) {
            "перевищено таймаут $TimeoutSeconds сек."
        } else {
            "$operationErrorText; після очікування $TimeoutSeconds сек. стан: $($service.Status)"
        }
        return [pscustomobject]@{ Success = $false; AlreadyInState = $false; FinalStatus = [string]$service.Status; Error = $details }
    } catch {
        return [pscustomobject]@{ Success = $false; AlreadyInState = $false; FinalStatus = "Unknown"; Error = $_.Exception.Message }
    }
}

function Stop-BRAVODataRestoreServices {
    # Зупинка ВСІХ керованих служб незалежно від компонента: BRAVO тримає
    # MODEL і пише BLOG, exchangAPI пише BRAVOEXCH, BravoWeb роздає похідні
    # моделі дані — уніфікований протокол надійніший за мінімізацію для
    # рідкісної disaster-операції. Повертає перелік відмов (порожній = успіх).
    param(
        [Parameter(Mandatory = $true)][object[]]$Snapshot,
        [Parameter(Mandatory = $true)][int]$StopTimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$PollIntervalSeconds
    )

    $failures = @()
    foreach ($entry in $Snapshot) {
        if (-not $entry.Managed -or -not $entry.WasRunning) { continue }
        foreach ($processName in @($entry.KillProcesses)) {
            $lingeringProcess = Get-Process -Name $processName -ErrorAction SilentlyContinue
            if ($lingeringProcess) {
                Write-DataRestoreLog -Message "Завершення процесу $processName перед зупинкою $($entry.Name)..." -Level 'INFO'
                $lingeringProcess | Stop-Process -Force
                Start-Sleep -Seconds 1
            }
        }
        Write-DataRestoreLog -Message "Зупинка служби $($entry.Name)..." -Level 'INFO'
        $stopResult = Invoke-BRAVODataRestoreServiceStateChange `
            -Name $entry.Name `
            -DesiredStatus Stopped `
            -TimeoutSeconds $StopTimeoutSeconds `
            -PollIntervalSeconds $PollIntervalSeconds `
            -Force
        if ($stopResult.Success) {
            Write-DataRestoreLog -Message "Службу $($entry.Name) зупинено" -Level 'SUCCESS'
        } else {
            $failures += "не вдалося зупинити $($entry.Name): $($stopResult.Error)"
            Write-DataRestoreLog -Message "ПОМИЛКА: не вдалося зупинити $($entry.Name): $($stopResult.Error)" -Level 'ERROR'
        }
    }
    return @($failures)
}

function Restore-BRAVODataRestoreServices {
    # Відновлення СТАНУ (не сліпий запуск): стартують лише ті служби, які
    # працювали на момент знімка, у зворотному до зупинки порядку.
    param(
        [Parameter(Mandatory = $true)][object[]]$Snapshot,
        [Parameter(Mandatory = $true)][int]$StartTimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$PollIntervalSeconds
    )

    $failures = @()
    $reversed = @($Snapshot)
    [array]::Reverse($reversed)
    foreach ($entry in $reversed) {
        if (-not $entry.Managed -or -not $entry.WasRunning) { continue }
        Write-DataRestoreLog -Message "Запуск служби $($entry.Name)..." -Level 'INFO'
        $startResult = Invoke-BRAVODataRestoreServiceStateChange `
            -Name $entry.Name `
            -DesiredStatus Running `
            -TimeoutSeconds $StartTimeoutSeconds `
            -PollIntervalSeconds $PollIntervalSeconds
        if ($startResult.Success) {
            Write-DataRestoreLog -Message "Службу $($entry.Name) запущено" -Level 'SUCCESS'
        } else {
            $failures += "не вдалося запустити $($entry.Name): $($startResult.Error)"
            Write-DataRestoreLog -Message "ПОМИЛКА: не вдалося запустити $($entry.Name): $($startResult.Error)" -Level 'ERROR'
        }
    }
    return @($failures)
}

function Request-BRAVODataRestoreConfirmation {
    # Типізоване підтвердження деструктивного InPlace: оператор має НАБРАТИ
    # GenerationId (сильніше за Y/N — вимагає прочитати план). -Force — обхід
    # для дистанційних runbook-ів; неінтерактивна сесія без -Force
    # відмовляється fail-closed.
    param(
        [Parameter(Mandatory = $true)][string]$GenerationIdToConfirm,
        [switch]$ForceConfirmation
    )

    if ($ForceConfirmation) {
        Write-DataRestoreLog -Message "Підтвердження пропущено параметром -Force (GenerationId $GenerationIdToConfirm)" -Level 'WARNING'
        return $true
    }
    $interactive = $true
    try {
        if (-not [Environment]::UserInteractive) { $interactive = $false }
    } catch {
        $interactive = $false
    }
    if (-not $interactive) {
        Write-DataRestoreLog -Message 'Неінтерактивна сесія без -Force: InPlace-відновлення відхилено' -Level 'ERROR'
        return $false
    }
    Write-BRAVOResultNote -Text ''
    Write-BRAVOResultNote -Text 'УВАГА: поточні production-дані буде знесено вбік (.prerestore) і замінено даними з резервної копії.'
    $typedValue = $null
    try {
        $typedValue = Read-Host "Для підтвердження введіть GenerationId ($GenerationIdToConfirm)"
    } catch {
        Write-DataRestoreLog -Message "Підтвердження недоступне в цьому хості: $($_.Exception.Message)" -Level 'ERROR'
        return $false
    }
    if ([string]$typedValue -cne $GenerationIdToConfirm) {
        Write-DataRestoreLog -Message 'Введений GenerationId не збігається — відновлення скасовано оператором' -Level 'WARNING'
        return $false
    }
    Write-DataRestoreLog -Message "Оператор підтвердив InPlace-відновлення generation $GenerationIdToConfirm" -Level 'INFO'
    return $true
}

function Get-BRAVODataRestoreLockingProcessText {
    # Хто тримає дерево, якщо move-aside не вдався. Windows каже лише "file
    # is being used by another process" — Restart Manager (rstrtmgr.dll)
    # називає винуватця. Суто діагностична best-effort функція: реєструє
    # сам каталог + обмежену вибірку файлів (перші 200), ніколи не кидає
    # виняток і нічого не зупиняє.
    param([Parameter(Mandatory = $true)][string]$Directory)

    try {
        if (-not ('BRAVODataRestoreLockInspector' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class BRAVODataRestoreLockInspector
{
    [StructLayout(LayoutKind.Sequential)]
    private struct RM_UNIQUE_PROCESS
    {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    private const int CCH_RM_MAX_APP_NAME = 255;
    private const int CCH_RM_MAX_SVC_NAME = 63;
    private const int ERROR_MORE_DATA = 234;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)]
        public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)]
        public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmEndSession(uint pSessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
        uint nApplications, [In] RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded,
        ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    public static List<string> GetHolders(string[] paths)
    {
        List<string> holders = new List<string>();
        uint sessionHandle;
        if (RmStartSession(out sessionHandle, 0, Guid.NewGuid().ToString()) != 0)
        {
            return holders;
        }
        try
        {
            if (RmRegisterResources(sessionHandle, (uint)paths.Length, paths, 0, null, 0, null) != 0)
            {
                return holders;
            }
            uint needed = 0;
            uint count = 0;
            uint reasons = 0;
            int result = RmGetList(sessionHandle, out needed, ref count, null, ref reasons);
            if (result != ERROR_MORE_DATA || needed == 0)
            {
                return holders;
            }
            RM_PROCESS_INFO[] infos = new RM_PROCESS_INFO[needed];
            count = needed;
            if (RmGetList(sessionHandle, out needed, ref count, infos, ref reasons) != 0)
            {
                return holders;
            }
            for (int i = 0; i < count; i++)
            {
                string holder = infos[i].strAppName + " (PID " + infos[i].Process.dwProcessId + ")";
                if (!string.IsNullOrEmpty(infos[i].strServiceShortName))
                {
                    holder += " [служба " + infos[i].strServiceShortName + "]";
                }
                if (!holders.Contains(holder))
                {
                    holders.Add(holder);
                }
            }
            return holders;
        }
        finally
        {
            RmEndSession(sessionHandle);
        }
    }
}
'@
        }
        $samplePaths = New-Object 'System.Collections.Generic.List[string]'
        $samplePaths.Add($Directory)
        foreach ($sampleFile in @(Get-ChildItem -LiteralPath $Directory -Recurse -File -ErrorAction SilentlyContinue |
                Select-Object -First 200)) {
            $samplePaths.Add($sampleFile.FullName)
        }
        $holders = [BRAVODataRestoreLockInspector]::GetHolders($samplePaths.ToArray())
        if ($holders.Count -eq 0) {
            return 'власника не визначено (Restart Manager не побачив відкритих handle у вибірці файлів)'
        }
        return ($holders -join '; ')
    } catch {
        return "діагностика власників недоступна: $($_.Exception.Message)"
    }
}

function Invoke-BRAVODataRestoreMoveAside {
    # Safety-збереження поточних даних: атомарний rename у межах того самого
    # батьківського каталогу (той самий том). Провал rename — це fail-closed
    # ДОКАЗ, що щось іще тримає дерево: нічого не знищено, лише діагностика.
    param(
        [Parameter(Mandatory = $true)][string]$LiveDirectory,
        [Parameter(Mandatory = $true)][string]$PrerestoreDirectory
    )

    if (-not (Test-Path -LiteralPath $LiveDirectory -PathType Container)) {
        Write-DataRestoreLog -Message "Live-каталог відсутній ($LiveDirectory) — prerestore-копія не створюється (джерело знищено?)" -Level 'WARNING'
        return [pscustomobject]@{ Success = $true; Performed = $false; Error = $null }
    }
    try {
        [System.IO.Directory]::Move($LiveDirectory, $PrerestoreDirectory)
        Write-DataRestoreLog -Message "Поточні дані знесено вбік: $LiveDirectory -> $PrerestoreDirectory" -Level 'SUCCESS'
        return [pscustomobject]@{ Success = $true; Performed = $true; Error = $null }
    } catch {
        $holdersText = Get-BRAVODataRestoreLockingProcessText -Directory $LiveDirectory
        $message = "move-aside не вдався для ${LiveDirectory}: $($_.Exception.Message); ймовірні власники: $holdersText"
        Write-DataRestoreLog -Message "ПОМИЛКА: $message" -Level 'ERROR'
        return [pscustomobject]@{ Success = $false; Performed = $false; Error = $message }
    }
}

function Undo-BRAVODataRestoreMoveAside {
    # Rollback невдалого InPlace-відновлення: прибрати частково розпакований
    # свіжий каталог і повернути prerestore-копію на original ім'я.
    param(
        [Parameter(Mandatory = $true)][string]$LiveDirectory,
        [Parameter(Mandatory = $true)][string]$PrerestoreDirectory,
        [Parameter(Mandatory = $true)][bool]$MoveAsidePerformed
    )

    try {
        if (Test-Path -LiteralPath $LiveDirectory -PathType Container) {
            Remove-Item -LiteralPath $LiveDirectory -Recurse -Force -ErrorAction Stop
        }
        if ($MoveAsidePerformed) {
            [System.IO.Directory]::Move($PrerestoreDirectory, $LiveDirectory)
        }
        Write-DataRestoreLog -Message "Rollback виконано: $LiveDirectory повернуто до стану перед відновленням" -Level 'SUCCESS'
        return [pscustomobject]@{ Success = $true; Error = $null }
    } catch {
        # Найгірший сценарій: rollback теж не вдався. Дані НЕ втрачені —
        # prerestore-копія на місці; оператору потрібна точна ручна команда.
        $manualCommand = "Rename-Item -LiteralPath `"$PrerestoreDirectory`" -NewName `"$(Split-Path $LiveDirectory -Leaf)`""
        $message = "rollback не вдався: $($_.Exception.Message). Дані збережені у $PrerestoreDirectory. Ручне повернення: $manualCommand"
        Write-DataRestoreLog -Message "КРИТИЧНО: $message" -Level 'ERROR'
        return [pscustomobject]@{ Success = $false; Error = $message }
    }
}

function Undo-BRAVODataRestoreCompletedComponents {
    # Крос-компонентний rollback InPlace: якщо компонент N не відновився,
    # ВЖЕ відновлені компоненти цього ж прогону теж повертаються до стану
    # перед відновленням. Інакше production лишився б у змішаному стані —
    # MODEL з нової generation, BLOG зі старими даними, — а узгодженість
    # MODEL/BLOG/BRAVOEXCH між собою є передумовою працездатності LIMS.
    #
    # Порядок ЗВОРОТНИЙ до відновлення: останній відновлений відкочується
    # першим (дзеркало порядку зупинки/запуску служб).
    #
    # Відмова відкату одного компонента НЕ зупиняє відкат решти: кожен
    # компонент незалежний, і зупинка на першій помилці лишила б без
    # спроби ті, які ще можна врятувати. Усі відмови повертаються
    # викликачеві разом.
    #
    # Failures — структуровані записи (Type + Error), а не лише текст:
    # викликач мусить знати, ЯКОМУ саме компонентові виставити термінальний
    # статус ROLLBACK_FAILED, а не тільки що написати в журнал.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$CompletedComponents
    )

    $rolledBack = @()
    $failures = @()
    $reversed = @($CompletedComponents)
    [array]::Reverse($reversed)
    foreach ($completed in $reversed) {
        $componentType = [string]$completed.Type
        Write-DataRestoreLog -Message "Відкат раніше відновленого компонента $componentType (збій іншого компонента цього прогону)..." -Level 'WARNING'
        $undoResult = Undo-BRAVODataRestoreMoveAside `
            -LiveDirectory ([string]$completed.LiveDirectory) `
            -PrerestoreDirectory ([string]$completed.PrerestoreDirectory) `
            -MoveAsidePerformed ([bool]$completed.MoveAsidePerformed)
        if ($undoResult.Success) {
            $rolledBack += $componentType
        } else {
            $failures += [pscustomobject]@{
                Type = $componentType
                Error = [string]$undoResult.Error
            }
        }
    }
    return [pscustomobject]@{
        RolledBack = @($rolledBack)
        Failures = @($failures)
    }
}

function Get-BRAVODataRestoreRollbackStatusUpdates {
    # Переклад результату крос-відкату в термінальні статуси компонентів.
    # Винесено окремо від головного потоку, бо саме тут вирішується, що
    # оператор побачить у підсумку: компонент, відкат якого НЕ завершився,
    # не має лишатися RESTORED. Функція чиста (нічого не пише) — її можна
    # перевіряти тестом разом із фактичним станом файлової системи.
    param(
        [Parameter(Mandatory = $true)][object]$CrossRollbackResult,
        [Parameter(Mandatory = $true)][string]$FailedComponent
    )

    $updates = @()
    foreach ($rolledBackComponent in @($CrossRollbackResult.RolledBack)) {
        $updates += [pscustomobject]@{
            Component = [string]$rolledBackComponent
            Status = 'ROLLED_BACK'
            Detail = "відкочено до стану перед відновленням (збій компонента $FailedComponent)"
        }
    }
    foreach ($rollbackFailure in @($CrossRollbackResult.Failures)) {
        $updates += [pscustomobject]@{
            Component = [string]$rollbackFailure.Type
            Status = 'ROLLBACK_FAILED'
            Detail = ("відкат не завершено (збій компонента {0}): {1}" -f $FailedComponent, $rollbackFailure.Error)
        }
    }
    return @($updates)
}

function Format-BRAVODataRestoreRollbackFailureText {
    # Єдине місце форматування відмов відкату в текст (журнал, підсумкова
    # причина, сповіщення) — щоб оператор бачив однакове формулювання
    # скрізь, а не три різні варіанти того самого факту.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Failures
    )

    return @($Failures | ForEach-Object { "$($_.Type): $($_.Error)" })
}

function Test-BRAVODataRestoreExtractionResult {
    # Post-restore verification: фактична кількість файлів і сумарний розмір
    # у цілі мають ТОЧНО збігтися з інвентаризацією архіву (7za l -slt).
    # Каталоги — лише довідково: 7z відтворює їх і як entries, і як батьків
    # файлів, тому їхня кількість не є стабільним еталоном.
    param(
        [Parameter(Mandatory = $true)][string]$TargetDirectory,
        [Parameter(Mandatory = $true)][object]$Inventory
    )

    $extractedFiles = @(Get-ChildItem -LiteralPath $TargetDirectory -Recurse -File -Force -ErrorAction SilentlyContinue)
    $extractedByteSum = [long]0
    foreach ($extractedFile in $extractedFiles) {
        $extractedByteSum += [long]$extractedFile.Length
    }
    $problems = @()
    if ($extractedFiles.Count -ne [int]$Inventory.FileCount) {
        $problems += "кількість файлів не збігається: розпаковано $($extractedFiles.Count), в архіві $($Inventory.FileCount)"
    }
    if ($extractedByteSum -ne [long]$Inventory.TotalUncompressedBytes) {
        $problems += ("сумарний розмір не збігається: розпаковано {0}, в архіві {1}" -f `
            (Format-BRAVOFileSize -Bytes $extractedByteSum),
            (Format-BRAVOFileSize -Bytes ([long]$Inventory.TotalUncompressedBytes)))
    }
    if ($extractedFiles.Count -eq 0 -and [int]$Inventory.FileCount -gt 0) {
        $problems += 'ціль порожня після розпакування'
    }
    return [pscustomobject]@{
        Success = ($problems.Count -eq 0)
        FileCount = $extractedFiles.Count
        ByteCount = $extractedByteSum
        Problems = @($problems)
    }
}

function Add-BRAVODataRestoreComponentResult {
    param(
        [Parameter(Mandatory = $true)][string]$ComponentType,
        # RESTORED       — компонент реально лишився відновленим;
        # ROLLED_BACK    — попередній стан успішно повернуто;
        # ROLLBACK_FAILED— відкат розпочато й НЕ завершено: кінцевий стан
        #                  каталогу не можна вважати гарантовано відновленим,
        #                  потрібне ручне втручання (OPERATIONS.md, код 43);
        # FAILED         — відновлення компонента не вдалося;
        # NOT_RUN        — черга до компонента не дійшла.
        [Parameter(Mandatory = $true)][ValidateSet('RESTORED', 'ROLLED_BACK', 'ROLLBACK_FAILED', 'FAILED', 'NOT_RUN')][string]$Status,
        [string]$TargetDirectory,
        [string]$PrerestoreDirectory,
        [int]$FileCount = 0,
        [long]$ByteCount = 0,
        [Nullable[double]]$DurationSeconds,
        [string]$Detail
    )

    [void]$script:dataRestoreComponentResults.Add([pscustomobject]@{
        Component = $ComponentType
        Status = $Status
        TargetDirectory = $TargetDirectory
        PrerestoreDirectory = $PrerestoreDirectory
        FileCount = $FileCount
        ByteCount = $ByteCount
        DurationSeconds = $DurationSeconds
        Detail = $Detail
    })
}

# ===== SFTP-ДЖЕРЕЛО =====

function Get-BRAVODataRestoreTemporaryRoot {
    # ASCII-безпечний каталог для командних/XML-файлів WinSCP (той самий
    # принцип, що Get-BRAVOHealthTemporaryRoot: командний файл WinSCP може
    # використовувати ASCII-кодування, тому службові шляхи сеансу тримаємо
    # в гарантовано ASCII-каталозі).
    if (-not [string]::IsNullOrWhiteSpace([string]$script:dataRestoreTemporaryRoot) -and
        (Test-Path -LiteralPath $script:dataRestoreTemporaryRoot -PathType Container)) {
        return $script:dataRestoreTemporaryRoot
    }
    $candidateRoots = @((Join-Path $bravoScriptDirectory 'TEMP'))
    $commonApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if (-not [string]::IsNullOrWhiteSpace($commonApplicationData)) {
        $candidateRoots += Join-Path $commonApplicationData 'BRAVO\TEMP'
    }
    $systemTemporaryRoot = [System.IO.Path]::GetTempPath()
    if (Test-BRAVODataRestoreAsciiPath -Path $systemTemporaryRoot) {
        $candidateRoots += Join-Path $systemTemporaryRoot 'BRAVO'
    }
    foreach ($candidateRoot in @($candidateRoots | Select-Object -Unique)) {
        if (-not (Test-BRAVODataRestoreAsciiPath -Path $candidateRoot)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $candidateRoot -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $candidateRoot -Force -ErrorAction Stop)
            }
            $script:dataRestoreTemporaryRoot = $candidateRoot
            return $candidateRoot
        } catch {
            continue
        }
    }
    throw 'не знайдено ASCII-безпечного тимчасового каталогу для WinSCP-сеансу'
}

function Initialize-BRAVODataRestoreSftpCredentials {
    # Той самий шлях, що Health: Credential Manager -> Resolve-BRAVOSftpHostName
    # -> New-BRAVOSftpUrl. Секрети не потрапляють ні в аргументи, ні в журнал.
    $sftpLoginTarget = [string]$credentialSettings.Targets.SFTPLogin
    $sftpPasswordTarget = [string]$credentialSettings.Targets.SFTPPassword
    if ([string]::IsNullOrWhiteSpace($sftpLoginTarget)) { $sftpLoginTarget = 'BRAVO_SFTP_LOGIN' }
    if ([string]::IsNullOrWhiteSpace($sftpPasswordTarget)) { $sftpPasswordTarget = 'BRAVO_SFTP_PASSWORD' }
    $storedSftpLogin = Get-BRAVOCredentialSecret -Target $sftpLoginTarget
    $storedSftpPassword = Get-BRAVOCredentialSecret -Target $sftpPasswordTarget
    if ([string]::IsNullOrWhiteSpace($storedSftpLogin)) {
        throw "запис Credential Manager '$sftpLoginTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    }
    if ([string]::IsNullOrWhiteSpace($storedSftpPassword)) {
        throw "запис Credential Manager '$sftpPasswordTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    }
    $sftpLogin = ([string]$storedSftpLogin).Trim()
    $legacySftpHostVariable = Get-Variable -Name 'sftpHost' -Scope Global -ErrorAction SilentlyContinue
    $configuredSftpHost = if ($null -ne $legacySftpHostVariable) { [string]$legacySftpHostVariable.Value } else { $null }
    $resolvedSftpHost = Resolve-BRAVOSftpHostName `
        -UserName $sftpLogin `
        -HostTemplate ([string]$sftpHostTemplate) `
        -FallbackHostName $configuredSftpHost
    $script:dataRestoreSftpUrl = New-BRAVOSftpUrl `
        -HostName $resolvedSftpHost `
        -Port ([int]$sftpPort) `
        -UserName $sftpLogin `
        -Password ([string]$storedSftpPassword)
    $storedSftpLogin = $null
    $storedSftpPassword = $null
}

function Invoke-BRAVODataRestoreWinSCPScript {
    # Параметризоване дзеркало Invoke-WinSCPHealthSession: тимчасовий
    # командний файл + /xmllog, таймаут із kill, розбір XML. Вивід
    # санітизується у джерелі (Get-SanitizedWinSCPDiagnostic).
    param(
        [Parameter(Mandatory = $true)][string[]]$Commands,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $temporaryName = "BRAVO_DATA_RESTORE_$([guid]::NewGuid().ToString('N'))"
    $temporaryRoot = Get-BRAVODataRestoreTemporaryRoot
    $temporaryScriptPath = Join-Path $temporaryRoot "$temporaryName.txt"
    $temporaryXmlPath = Join-Path $temporaryRoot "$temporaryName.xml"
    $process = $null
    $outputCapture = $null
    try {
        $scriptLines = @(
            "option batch continue",
            "option confirm off",
            "open $script:dataRestoreSftpUrl -hostkey=$sftpHostKey -timeout=$sftpConnectionTimeoutSeconds"
        )
        $scriptLines += @($Commands)
        $scriptLines += "exit"
        $scriptEncoding = [System.Text.Encoding]::GetEncoding($winSCPScriptEncoding)
        [System.IO.File]::WriteAllLines($temporaryScriptPath, $scriptLines, $scriptEncoding)

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $winSCPPath
        $processInfo.Arguments = "/ini=$winSCPIniPath /xmllog=`"$temporaryXmlPath`" /xmlgroups /script=`"$temporaryScriptPath`""
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $winSCPPath
        if (-not $winSCPAvailability.Available) {
            throw (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "SFTP-відновлення")
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $completed = $process.WaitForExit([math]::Max(1, $TimeoutSeconds) * 1000)
        if (-not $completed) {
            try { $process.Kill(); [void]$process.WaitForExit(5000) } catch {
                # Kill процесу, що вже завершився сам, кидає InvalidOperation —
                # результат той самий (процес мертвий), логувати нічого.
            }
            if ($null -ne $outputCapture) {
                [void](Complete-BRAVOProcessOutputCapture -Capture $outputCapture)
                $outputCapture = $null
            }
            throw "перевищено таймаут SFTP-операції ($TimeoutSeconds сек.)"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $outputCapture = $null
        if (-not (Test-Path -LiteralPath $temporaryXmlPath -PathType Leaf)) {
            throw "WinSCP не створив XML-журнал (код: $($process.ExitCode))"
        }
        $xml = New-Object System.Xml.XmlDocument
        $xml.Load($temporaryXmlPath)
        if ($process.ExitCode -ne 0) {
            Write-DataRestoreLog -Message "WinSCP завершився з кодом $($process.ExitCode); аналізуємо доступні XML-результати" -Level 'WARNING'
        }
        return [pscustomobject]@{
            Success = $true
            ExitCode = $process.ExitCode
            Xml = $xml
            Output = Get-SanitizedWinSCPDiagnostic -Text ([string]$capturedOutput.StandardOutput)
            ErrorOutput = Get-SanitizedWinSCPDiagnostic -Text ([string]$capturedOutput.StandardError)
            Error = $null
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            ExitCode = if ($process -and $process.HasExited) { $process.ExitCode } else { $null }
            Xml = $null
            Output = ""
            ErrorOutput = ""
            Error = $_.Exception.Message
        }
    } finally {
        if ($null -ne $outputCapture) {
            try { [void](Complete-BRAVOProcessOutputCapture -Capture $outputCapture) } catch {
                # Cleanup-гілка після помилки: збій закриття capture не має
                # маскувати первинний exception, який зараз летить нагору.
            }
        }
        foreach ($temporaryPath in @($temporaryScriptPath, $temporaryXmlPath)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
        if ($process) { $process.Dispose() }
    }
}

function New-BRAVODataRestoreWinSCPNamespaceManager {
    param([System.Xml.XmlDocument]$Xml)

    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $namespaceManager.AddNamespace("w", "http://winscp.net/schema/session/1.0")
    return ,$namespaceManager
}

function Get-BRAVODataRestoreWinSCPListingNames {
    # Імена файлів з усіх ls-результатів XML-журналу WinSCP.
    param([System.Xml.XmlDocument]$Xml)

    $names = @()
    if ($null -eq $Xml) { return @() }
    $namespaceManager = New-BRAVODataRestoreWinSCPNamespaceManager -Xml $Xml
    foreach ($listingNode in @($Xml.SelectNodes("//w:ls", $namespaceManager))) {
        foreach ($fileNode in @($listingNode.SelectNodes("w:files/w:file", $namespaceManager))) {
            $nameNode = $fileNode.SelectSingleNode("w:filename", $namespaceManager)
            if ($nameNode) { $names += [string]$nameNode.GetAttribute("value") }
        }
    }
    return @($names)
}

function Get-BRAVODataRestoreWinSCPDownloads {
    param([System.Xml.XmlDocument]$Xml)

    $downloads = @()
    if ($null -eq $Xml) { return @() }
    $namespaceManager = New-BRAVODataRestoreWinSCPNamespaceManager -Xml $Xml
    foreach ($downloadNode in @($Xml.SelectNodes("//w:download", $namespaceManager))) {
        $fileNode = $downloadNode.SelectSingleNode("w:filename", $namespaceManager)
        $resultNode = $downloadNode.SelectSingleNode("w:result", $namespaceManager)
        $messages = if ($resultNode) {
            @($resultNode.SelectNodes("w:message", $namespaceManager) |
                ForEach-Object { ([string]$_.InnerText).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        } else {
            @()
        }
        $downloads += [pscustomobject]@{
            RemotePath = if ($fileNode) { [string]$fileNode.GetAttribute("value") } else { "" }
            Success = ($resultNode -and $resultNode.GetAttribute("success") -eq "true")
            Error = ($messages -join "; ")
        }
    }
    return @($downloads)
}

function Get-BRAVODataRestoreSftpDirectoryForComponent {
    param([Parameter(Mandatory = $true)][string]$ComponentType)

    switch ($ComponentType) {
        'MODEL' { return [string]$sftpDirectories.MODEL }
        'BLOG' { return [string]$sftpDirectories.Blog }
        'BRAVOEXCH' { return [string]$sftpDirectories.BravoExch }
    }
    throw "невідомий компонент для SFTP: $ComponentType"
}

function Get-BRAVODataRestoreSftpOperationTimeoutSeconds {
    $operationTimeout = 1800
    try {
        if ($null -ne $backupMonitoring -and $null -ne $backupMonitoring.SFTP -and
            [int]$backupMonitoring.SFTP.OperationTimeoutSeconds -gt 0) {
            $operationTimeout = [int]$backupMonitoring.SFTP.OperationTimeoutSeconds
        }
    } catch {
        # Некоректне значення в конфігурації — тихий fallback на дефолт:
        # той самий контракт читання SFTP-таймаутів, що в Health/Archive.
    }
    return $operationTimeout
}

function Get-BRAVODataRestoreSftpTransferTimeoutSeconds {
    # Повне завантаження великих архівів — окремий, суттєво більший таймаут
    # (той самий поділ, що OperationTimeoutSeconds/SynchronizationTimeoutSeconds
    # у Health/Archive).
    $transferTimeout = 14400
    try {
        if ($null -ne $backupMonitoring -and $null -ne $backupMonitoring.SFTP -and
            [int]$backupMonitoring.SFTP.SynchronizationTimeoutSeconds -gt 0) {
            $transferTimeout = [int]$backupMonitoring.SFTP.SynchronizationTimeoutSeconds
        }
    } catch {
        # Некоректне значення в конфігурації — тихий fallback на дефолт:
        # той самий контракт читання SFTP-таймаутів, що в Health/Archive.
    }
    return $transferTimeout
}

function Invoke-BRAVODataRestoreSftpManifestFetch {
    # Вибір і завантаження generation manifest-а з SFTP у staging. Manifest
    # НІКОЛИ не потрапляє в <BackupRoot>\MANIFESTS — локальні listing/retention
    # не повинні бачити чужу generation як свою.
    param(
        [Parameter(Mandatory = $true)][string]$StagingManifestDirectory,
        [string]$RequestedGenerationId
    )

    if (-not (Test-Path -LiteralPath $StagingManifestDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $StagingManifestDirectory -Force -ErrorAction Stop)
    }
    $remoteManifestDirectory = [string]$sftpDirectories.Manifest
    if ([string]::IsNullOrWhiteSpace($remoteManifestDirectory)) {
        throw 'sftpDirectories.Manifest не задано в конфігурації'
    }
    $operationTimeout = Get-BRAVODataRestoreSftpOperationTimeoutSeconds

    $manifestNames = @()
    if (-not [string]::IsNullOrWhiteSpace($RequestedGenerationId)) {
        $manifestNames = @("BRAVO_BACKUP_{0}.json" -f $RequestedGenerationId)
    } else {
        $listingSession = Invoke-BRAVODataRestoreWinSCPScript `
            -Commands @("ls `"$remoteManifestDirectory`"") `
            -TimeoutSeconds $operationTimeout
        if (-not $listingSession.Success) {
            throw "не вдалося отримати перелік manifest-ів з SFTP: $($listingSession.Error)"
        }
        $manifestNames = @(Get-BRAVODataRestoreWinSCPListingNames -Xml $listingSession.Xml |
            Where-Object { $_ -match '^BRAVO_BACKUP_\d{8}_\d{6}(?:_\d+)?\.json$' } |
            Sort-Object -Descending |
            Select-Object -First 10)
        if ($manifestNames.Count -eq 0) {
            throw "на SFTP ($remoteManifestDirectory) не знайдено жодного generation manifest"
        }
    }

    $getCommands = @()
    foreach ($manifestName in $manifestNames) {
        $localManifestPath = Join-Path $StagingManifestDirectory $manifestName
        if (Test-Path -LiteralPath $localManifestPath) {
            Remove-Item -LiteralPath $localManifestPath -Force -ErrorAction SilentlyContinue
        }
        $getCommands += "get `"$remoteManifestDirectory/$manifestName`" `"$localManifestPath`""
    }
    $downloadSession = Invoke-BRAVODataRestoreWinSCPScript `
        -Commands $getCommands `
        -TimeoutSeconds $operationTimeout
    if (-not $downloadSession.Success) {
        throw "не вдалося завантажити manifest-и з SFTP: $($downloadSession.Error)"
    }

    # Найновіший COMPLETE серед завантажених (або точно запитаний).
    $candidates = @()
    foreach ($manifestName in $manifestNames) {
        $localManifestPath = Join-Path $StagingManifestDirectory $manifestName
        if (-not (Test-Path -LiteralPath $localManifestPath -PathType Leaf)) { continue }
        try {
            $manifest = [IO.File]::ReadAllText($localManifestPath) | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }
        if ([string]$manifest.status -ne 'COMPLETE') { continue }
        $candidates += [pscustomobject]@{
            Manifest = $manifest
            ManifestPath = $localManifestPath
            Name = $manifestName
        }
    }
    $selected = $candidates | Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $selected) {
        if (-not [string]::IsNullOrWhiteSpace($RequestedGenerationId)) {
            throw "COMPLETE generation '$RequestedGenerationId' не знайдено на SFTP"
        }
        throw 'серед завантажених manifest-ів немає жодного COMPLETE'
    }
    return $selected
}

function Invoke-BRAVODataRestoreSftpArchiveFetch {
    # Завантаження .mdz + .sha512 обраних компонентів у staging з
    # resumesupport. Імена файлів беруться ЛИШЕ як basename із manifest
    # (шляхи origin-сервера недовірені відносно нашої файлової системи).
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string[]]$ComponentTypes,
        [Parameter(Mandatory = $true)][string]$StagingGenerationRoot
    )

    $componentsProperty = $Manifest.PSObject.Properties['components']
    $stagedPaths = @{}
    $transferTimeout = Get-BRAVODataRestoreSftpTransferTimeoutSeconds
    foreach ($componentType in $ComponentTypes) {
        $componentProperty = @($componentsProperty.Value.PSObject.Properties | Where-Object {
            [string]::Equals($_.Name, $componentType, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($componentProperty.Count -eq 0) {
            throw "manifest не містить component $componentType"
        }
        $componentState = $componentProperty[0].Value
        $archiveFileName = [System.IO.Path]::GetFileName([string]$componentState.ArchivePath)
        if ([string]::IsNullOrWhiteSpace($archiveFileName) -or
            $archiveFileName -notmatch '^[^\\/:*?"<>|]+\.mdz$') {
            throw "manifest містить підозріле ім'я архіву для ${componentType}: '$archiveFileName'"
        }
        $remoteDirectory = Get-BRAVODataRestoreSftpDirectoryForComponent -ComponentType $componentType
        $componentStagingDirectory = Join-Path $StagingGenerationRoot $componentType
        if (-not (Test-Path -LiteralPath $componentStagingDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $componentStagingDirectory -Force -ErrorAction Stop)
        }
        # Стейлові часткові завантаження попередніх спроб.
        foreach ($stalePartial in @(Get-ChildItem -LiteralPath $componentStagingDirectory -Filter '*.filepart' -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $stalePartial.FullName -Force -ErrorAction SilentlyContinue
        }
        $localArchivePath = Join-Path $componentStagingDirectory $archiveFileName
        $localHashPath = "$localArchivePath$hashFileExtension"
        $downloadSession = Invoke-BRAVODataRestoreWinSCPScript `
            -Commands @(
                "get -resumesupport=on `"$remoteDirectory/$archiveFileName`" `"$localArchivePath`"",
                "get `"$remoteDirectory/$archiveFileName$hashFileExtension`" `"$localHashPath`""
            ) `
            -TimeoutSeconds $transferTimeout
        if (-not $downloadSession.Success) {
            throw "не вдалося завантажити $componentType з SFTP: $($downloadSession.Error)"
        }
        $downloadFailures = @(Get-BRAVODataRestoreWinSCPDownloads -Xml $downloadSession.Xml |
            Where-Object { -not $_.Success })
        if ($downloadFailures.Count -gt 0) {
            $failureText = @($downloadFailures | ForEach-Object { "$($_.RemotePath): $($_.Error)" }) -join '; '
            throw "SFTP-завантаження $componentType завершилося з помилками: $failureText"
        }
        if (-not (Test-Path -LiteralPath $localArchivePath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $localHashPath -PathType Leaf)) {
            throw "після завантаження $componentType відсутній архів або sidecar у staging"
        }
        $stagedPaths[$componentType] = [pscustomobject]@{
            ArchivePath = $localArchivePath
            HashPath = $localHashPath
        }
        Write-DataRestoreLog -Message "Завантажено з SFTP: $archiveFileName + sidecar -> $componentStagingDirectory" -Level 'SUCCESS'
    }
    return $stagedPaths
}

function ConvertTo-BRAVODataRestoreStagedManifest {
    # Глибока копія manifest-а з переписаними на staging шляхами артефактів —
    # далі весь pipeline (строгий gate включно) працює source-agnostic.
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][hashtable]$StagedPaths
    )

    $clone = $Manifest | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    foreach ($componentType in @($StagedPaths.Keys)) {
        $componentProperty = @($clone.components.PSObject.Properties | Where-Object {
            [string]::Equals($_.Name, $componentType, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($componentProperty.Count -eq 0) { continue }
        $componentProperty[0].Value.ArchivePath = [string]$StagedPaths[$componentType].ArchivePath
        $componentProperty[0].Value.HashPath = [string]$StagedPaths[$componentType].HashPath
    }
    return $clone
}

function Invoke-BRAVODataRestorePostHealth {
    # Health після InPlace-відновлення — дочірнім процесом (той самий
    # прецедент, що запуск BRAVO_ARCHIV із Maintenance), ПІСЛЯ звільнення
    # operation lock: Health інспектує спільний lock і деградує перевірки
    # служб, поки той утримується.
    $healthScriptPath = [string]$global:backupHealthScriptPath
    if ([string]::IsNullOrWhiteSpace($healthScriptPath) -or
        -not (Test-Path -LiteralPath $healthScriptPath -PathType Leaf)) {
        Write-DataRestoreLog -Message "BRAVO_HEALTH.ps1 не знайдено ($healthScriptPath) — post-restore Health пропущено" -Level 'WARNING'
        return $null
    }
    try {
        Write-DataRestoreLog -Message 'Запуск post-restore BRAVO_HEALTH...' -Level 'INFO'
        $healthArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$healthScriptPath`" -ConfigPath `"$ConfigPath`" -NoPause"
        $healthProcess = Start-Process -FilePath $schedulerSettings.PowerShellExecutable `
            -ArgumentList $healthArguments `
            -Wait `
            -PassThru `
            -NoNewWindow
        Write-DataRestoreLog -Message "BRAVO_HEALTH завершився з кодом $($healthProcess.ExitCode)" -Level 'INFO'
        return [int]$healthProcess.ExitCode
    } catch {
        Write-DataRestoreLog -Message "Не вдалося запустити post-restore Health: $($_.Exception.Message)" -Level 'WARNING'
        return $null
    }
}

function Send-BRAVODataRestoreNotification {
    # Webhook-сповіщення оператору. Збій сповіщення ніколи не змінює
    # результат відновлення — лише WARNING у журналі.
    param(
        [Parameter(Mandatory = $true)][ValidateSet('SUCCESS', 'WARNING', 'CRITICAL')][string]$Severity,
        [Parameter(Mandatory = $true)][string[]]$ResultLines,
        [string]$ActionText
    )

    try {
        $notificationProvider = ([string]$bravoSettings.NotificationProvider).Trim().ToLowerInvariant()
        if ($notificationProvider -ne 'discord' -and $notificationProvider -ne 'slack') {
            $notificationProvider = 'discord'
        }
        $webhookTarget = if ($notificationProvider -eq 'discord') {
            [string]$credentialSettings.Targets.DiscordWebhook
        } else {
            [string]$credentialSettings.Targets.SlackWebhook
        }
        $webhookUrl = Get-BRAVOCredentialSecret -Target $webhookTarget
        if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
            Write-DataRestoreLog -Message "Webhook URL не знайдено (target '$webhookTarget') — сповіщення пропущено" -Level 'WARNING'
            return
        }
        $message = New-BRAVOOperatorNotificationMessage `
            -Severity $Severity `
            -Operation 'BRAVO DATA RESTORE — ВІДНОВЛЕННЯ ДАНИХ' `
            -ActionText $ActionText `
            -InstitutionName ([string]$bravoSettings.InstitutionName) `
            -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
            -HostInformation (Get-HostInformation) `
            -ResultLines $ResultLines `
            -Timestamp (Get-Date) `
            -ProductName 'BRAVO Data Restore' `
            -Version ([string]$script:ScriptVersion) `
            -BuildId ([string]$script:ScriptBuildId) `
            -LogPath ([string]$script:dataRestoreLogFile)
        Send-BRAVOWebhookNotification `
            -Provider $notificationProvider `
            -WebhookUrl $webhookUrl `
            -Message $message
    } catch {
        $script:dataRestoreWarningCount++
        Write-DataRestoreLog -Message "Не вдалося надіслати сповіщення: $($_.Exception.Message)" -Level 'WARNING'
    }
}

# ===== ГОЛОВНИЙ ПОТІК =====

Initialize-BRAVOConsole
Initialize-BRAVOProgress -Enabled $false
$headerModeText = if ($ListGenerations) {
    'LIST GENERATIONS / READ-ONLY'
} elseif ($Mode -eq 'InPlace') {
    "IN-PLACE PRODUCTION RESTORE ($Source)"
} else {
    "OUT-OF-PLACE RESTORE ($Source)"
}
Write-BRAVOHeader `
    -Title ("BRAVO Data Restore {0}" -f $script:ScriptVersion) `
    -Institution ([string]$bravoSettings.InstitutionName) `
    -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
    -Mode $headerModeText
Write-DataRestoreLog -Message "BRAVO Data Restore $script:ScriptVersion (build $script:ScriptBuildId): Mode=$Mode, Source=$Source, Component=$Component, GenerationId='$GenerationId', ListGenerations=$ListGenerations" -Level 'INFO'

# Ранні інваріанти параметрів — до lock і будь-яких дій.
if (-not [string]::IsNullOrWhiteSpace($GenerationId) -and
    $GenerationId -notmatch '^\d{8}_\d{6}(?:_\d+)?$') {
    Write-Host "ПОМИЛКА: GenerationId має формат yyyyMMdd_HHmmss (або collision-safe variant): '$GenerationId'" -ForegroundColor Red
    Write-DataRestoreLog -Message "Некоректний GenerationId: '$GenerationId'" -Level 'ERROR'
    exit 30
}
if (-not $ListGenerations) {
    if ($Mode -eq 'OutOfPlace' -and [string]::IsNullOrWhiteSpace($TargetPath)) {
        Write-Host "ПОМИЛКА: для режиму OutOfPlace обов'язковий параметр -TargetPath (порожня або нова директорія)" -ForegroundColor Red
        Write-DataRestoreLog -Message 'OutOfPlace без -TargetPath — відхилено' -Level 'ERROR'
        exit 30
    }
    if ($Mode -eq 'InPlace' -and -not [string]::IsNullOrWhiteSpace($TargetPath)) {
        Write-Host "ПОМИЛКА: для режиму InPlace параметр -TargetPath заборонений — ціль визначає discovery (bravo.ini)" -ForegroundColor Red
        Write-DataRestoreLog -Message 'InPlace із -TargetPath — відхилено' -Level 'ERROR'
        exit 30
    }
}

# Цілісність інструментів перед їх запуском від імені адміністратора.
$requiredTools = @('7za.exe')
if ($Source -eq 'SFTP') { $requiredTools += 'WinSCP.com' }
$toolIntegrity = Test-BRAVODataRestoreToolIntegrity -ToolNames $requiredTools
if (@($toolIntegrity.Problems).Count -gt 0) {
    foreach ($toolProblem in $toolIntegrity.Problems) {
        Write-DataRestoreLog -Message "Цілісність інструментів: $toolProblem" -Level 'ERROR' -Console
    }
    if ([string]$toolIntegrity.Mode -ine 'Warn') {
        Write-Host 'ПОМИЛКА: перевірка цілісності інструментів (Tools\) не пройдена — запуск заблоковано' -ForegroundColor Red
        exit 32
    }
    $script:dataRestoreWarningCount++
}

# ===== РЕЖИМ ПЕРЕГЛЯДУ =====
if ($ListGenerations) {
    if ($Source -eq 'Local') {
        $listCandidates = @()
        try {
            $listCandidates = @(Get-BRAVODataRestoreGenerationCandidates -BackupRoot $backupRootPath -Limit 25)
        } catch {
            Write-Host "ПОМИЛКА: $($_.Exception.Message)" -ForegroundColor Red
            exit 43
        }
        Write-BRAVOResultSection -Title "Доступні generation (BackupRoot: $backupRootPath)"
        if ($listCandidates.Count -eq 0) {
            Write-BRAVOResultNote -Text '  (жодного generation manifest не знайдено)'
        }
        foreach ($listCandidate in $listCandidates) {
            Write-BRAVOResultNote -Text ("  {0}  {1,-10}  {2:yyyy-MM-dd HH:mm}  {3}" -f `
                $listCandidate.GenerationId, $listCandidate.Status, $listCandidate.CreatedAt, $listCandidate.ComponentSummary)
        }
        Write-BRAVOResultNote -Text ''
        Write-BRAVOResultNote -Text 'Відновлюються лише COMPLETE generation; повна SHA512-верифікація виконується перед фактичним відновленням.'
        exit 0
    }
    # SFTP-перегляд: завантажуємо до 10 найновіших manifest-ів у тимчасовий
    # staging-підкаталог і показуємо їхній стан.
    try {
        Initialize-BRAVOCredentialManager
        Initialize-BRAVODataRestoreSftpCredentials
    } catch {
        Write-Host "ПОМИЛКА: $($_.Exception.Message)" -ForegroundColor Red
        exit 31
    }
    $listStagingDirectory = Join-Path $stagingRootPath ("_list_{0}" -f ([guid]::NewGuid().ToString('N')))
    try {
        [void](New-Item -ItemType Directory -Path $listStagingDirectory -Force -ErrorAction Stop)
        $remoteManifestDirectory = [string]$sftpDirectories.Manifest
        $listingSession = Invoke-BRAVODataRestoreWinSCPScript `
            -Commands @("ls `"$remoteManifestDirectory`"") `
            -TimeoutSeconds (Get-BRAVODataRestoreSftpOperationTimeoutSeconds)
        if (-not $listingSession.Success) {
            throw "не вдалося отримати перелік manifest-ів з SFTP: $($listingSession.Error)"
        }
        $remoteManifestNames = @(Get-BRAVODataRestoreWinSCPListingNames -Xml $listingSession.Xml |
            Where-Object { $_ -match '^BRAVO_BACKUP_\d{8}_\d{6}(?:_\d+)?\.json$' } |
            Sort-Object -Descending |
            Select-Object -First 10)
        Write-BRAVOResultSection -Title "Доступні generation на SFTP ($remoteManifestDirectory)"
        if ($remoteManifestNames.Count -eq 0) {
            Write-BRAVOResultNote -Text '  (жодного generation manifest не знайдено)'
            if ([int]$listingSession.ExitCode -ne 0) {
                Write-BRAVOResultNote -Text '  Примітка: WinSCP повернув помилку listing — можливо, віддаленого каталогу manifests не існує.'
            }
        } else {
            $listGetCommands = @()
            foreach ($remoteManifestName in $remoteManifestNames) {
                $listGetCommands += "get `"$remoteManifestDirectory/$remoteManifestName`" `"$(Join-Path $listStagingDirectory $remoteManifestName)`""
            }
            $listDownloadSession = Invoke-BRAVODataRestoreWinSCPScript `
                -Commands $listGetCommands `
                -TimeoutSeconds (Get-BRAVODataRestoreSftpOperationTimeoutSeconds)
            if (-not $listDownloadSession.Success) {
                throw "не вдалося завантажити manifest-и: $($listDownloadSession.Error)"
            }
            foreach ($remoteManifestName in $remoteManifestNames) {
                $localListManifestPath = Join-Path $listStagingDirectory $remoteManifestName
                $listLine = "  $remoteManifestName"
                if (Test-Path -LiteralPath $localListManifestPath -PathType Leaf) {
                    try {
                        $listManifest = [IO.File]::ReadAllText($localListManifestPath) | ConvertFrom-Json -ErrorAction Stop
                        $listLine = ("  {0}  {1,-10}" -f [string]$listManifest.generationId, [string]$listManifest.status)
                    } catch {
                        $listLine = "  $remoteManifestName  (не прочитано)"
                    }
                }
                Write-BRAVOResultNote -Text $listLine
            }
        }
        Write-BRAVOResultNote -Text ''
        Write-BRAVOResultNote -Text 'Перелік показує стан за manifest; артефакти верифікуються повністю після завантаження.'
        exit 0
    } catch {
        Write-Host "ПОМИЛКА: $($_.Exception.Message)" -ForegroundColor Red
        exit 50
    } finally {
        if (Test-Path -LiteralPath $listStagingDirectory) {
            Remove-Item -LiteralPath $listStagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ===== CREDENTIALS =====
try {
    Initialize-BRAVOCredentialManager
    $archiveCredentialTarget = [string]$credentialSettings.Targets.ArchivePassword
    if ([string]::IsNullOrWhiteSpace($archiveCredentialTarget)) {
        $archiveCredentialTarget = 'BRAVO_7Z_PASSWORD'
    }
    $script:archivePassword = Get-BRAVOCredentialSecret -Target $archiveCredentialTarget
    if ([string]::IsNullOrWhiteSpace($script:archivePassword)) {
        throw "пароль архіву не знайдено в Credential Manager (target '$archiveCredentialTarget') для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    }
    if ($Source -eq 'SFTP') {
        Initialize-BRAVODataRestoreSftpCredentials
    }
} catch {
    Write-Host "ПОМИЛКА: $($_.Exception.Message)" -ForegroundColor Red
    Write-DataRestoreLog -Message "Credentials: $($_.Exception.Message)" -Level 'ERROR'
    exit 31
}

# WinSCP-скрипт використовує ASCII-кодування (config) — локальні шляхи
# staging мусять бути ASCII, інакше командний файл їх спотворить.
if ($Source -eq 'SFTP' -and
    ([string]$winSCPScriptEncoding) -ieq 'ASCII' -and
    -not (Test-BRAVODataRestoreAsciiPath -Path $stagingRootPath)) {
    Write-Host "ПОМИЛКА: staging-шлях містить не-ASCII символи ($stagingRootPath); задайте -StagingPath з ASCII-шляхом" -ForegroundColor Red
    Write-DataRestoreLog -Message "Не-ASCII staging для ASCII WinSCP-скрипта: $stagingRootPath" -Level 'ERROR'
    exit 30
}

# ===== OPERATION LOCK =====
$lockAcquisition = Enter-BRAVODataRestoreOperationLock
if (-not $lockAcquisition.Success) {
    Write-Host "Пропущено: інша операція BRAVO вже виконується ($($lockAcquisition.Error))" -ForegroundColor Yellow
    Write-DataRestoreLog -Message "Operation lock зайнятий: $($lockAcquisition.Error)" -Level 'WARNING'
    exit 20
}
$script:dataRestoreOperationLock = $lockAcquisition.Stream
$script:dataRestoreOperationLockPath = $lockAcquisition.Path
Write-DataRestoreLog -Message "Operation lock захоплено: $($lockAcquisition.Path)" -Level 'INFO'

# ===== ОСНОВНИЙ PIPELINE =====
$selectedManifest = $null
$componentTypes = @()
$restorePlan = $null
$componentArtifacts = @{}
$componentInventories = @{}
try {
    try {
        # --- 1. Вибір generation ---
        $stageStartedAt = Get-Date
        if ($Source -eq 'Local') {
            $selectedGeneration = $null
            try {
                $selectedGeneration = Get-BRAVORestoreGenerationManifest `
                    -BackupRoot $backupRootPath `
                    -RequestedGenerationId $GenerationId
            } catch {
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason $_.Exception.Message
            }
            $selectedManifest = $selectedGeneration.Manifest
        } else {
            $script:dataRestoreStagingGenerationRoot = $null
            $stagingManifestDirectory = Join-Path $stagingRootPath '_manifests'
            $sftpSelected = $null
            try {
                $sftpSelected = Invoke-BRAVODataRestoreSftpManifestFetch `
                    -StagingManifestDirectory $stagingManifestDirectory `
                    -RequestedGenerationId $GenerationId
            } catch {
                Stop-BRAVODataRestoreRun -Category SftpFailed -Reason $_.Exception.Message
            }
            $selectedManifest = $sftpSelected.Manifest
        }
        $script:dataRestoreSelectedGenerationId = [string]$selectedManifest.generationId
        if ([string]::IsNullOrWhiteSpace($script:dataRestoreSelectedGenerationId)) {
            Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason 'обраний manifest не містить generationId'
        }
        Write-BRAVOOperationResult `
            -Name 'Вибір generation' `
            -Status 'OK' `
            -Duration ((Get-Date) - $stageStartedAt) `
            -Details $script:dataRestoreSelectedGenerationId
        Write-DataRestoreLog -Message "Обрано generation $script:dataRestoreSelectedGenerationId (Source=$Source)" -Level 'INFO'

        # --- 2. Компоненти ---
        try {
            $componentTypes = @(Get-BRAVODataRestoreComponentSelection `
                -Manifest $selectedManifest `
                -RequestedComponent $Component)
        } catch {
            Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason $_.Exception.Message
        }
        foreach ($componentType in $componentTypes) {
            Add-BRAVODataRestoreComponentResult -ComponentType $componentType -Status 'NOT_RUN' -Detail 'очікує'
        }

        # --- 3. План цілей ---
        $restorePlan = Get-BRAVODataRestorePlan `
            -ComponentTypes $componentTypes `
            -RestoreMode $Mode `
            -RequestedTargetPath $TargetPath `
            -BackupRoot $backupRootPath `
            -RuntimeRootPath $bravoScriptDirectory `
            -StagingRoot $stagingRootPath `
            -ArchiveDefinitions @($global:archiveDefinitions) `
            -RunStamp $runTimestamp
        if (-not $restorePlan.Success) {
            Stop-BRAVODataRestoreRun -Category InvalidConfiguration -Reason $restorePlan.Error
        }

        # --- 4. SFTP: staging free-space + завантаження артефактів ---
        if ($Source -eq 'SFTP') {
            $stagingRequirements = @()
            $componentsPropertyForSizes = $selectedManifest.PSObject.Properties['components']
            foreach ($componentType in $componentTypes) {
                $componentStateForSize = @($componentsPropertyForSizes.Value.PSObject.Properties | Where-Object {
                    [string]::Equals($_.Name, $componentType, [StringComparison]::OrdinalIgnoreCase)
                } | Select-Object -First 1)[0].Value
                $stagingRequirements += [pscustomobject]@{
                    TargetDirectory = Join-Path (Join-Path $stagingRootPath $script:dataRestoreSelectedGenerationId) $componentType
                    RequiredBytes = [long]$componentStateForSize.ArchiveSize
                }
            }
            $stagingSpaceCheck = Test-BRAVODataRestoreFreeSpace `
                -Requirements $stagingRequirements `
                -MinimumFreeGigabytes ([double]$maintenanceSettings.Limits.MinimumFreeSpaceGB)
            foreach ($stagingSpaceNote in $stagingSpaceCheck.Notes) {
                Write-DataRestoreLog -Message "Staging free-space: $stagingSpaceNote" -Level 'INFO'
            }
            if (-not $stagingSpaceCheck.Success) {
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason ("staging: " + ($stagingSpaceCheck.Problems -join '; '))
            }
            $script:dataRestoreStagingGenerationRoot = Join-Path $stagingRootPath $script:dataRestoreSelectedGenerationId
            $stageStartedAt = Get-Date
            $stagedPaths = $null
            try {
                $stagedPaths = Invoke-BRAVODataRestoreSftpArchiveFetch `
                    -Manifest $selectedManifest `
                    -ComponentTypes $componentTypes `
                    -StagingGenerationRoot $script:dataRestoreStagingGenerationRoot
            } catch {
                $script:dataRestoreStagingKept = $true
                Stop-BRAVODataRestoreRun -Category SftpFailed -Reason $_.Exception.Message
            }
            Write-BRAVOOperationResult `
                -Name 'Завантаження з SFTP' `
                -Status 'OK' `
                -Duration ((Get-Date) - $stageStartedAt)
            $selectedManifest = ConvertTo-BRAVODataRestoreStagedManifest `
                -Manifest $selectedManifest `
                -StagedPaths $stagedPaths
        }

        # --- 5. Строгий gate по кожному компоненту ---
        $componentsProperty = $selectedManifest.PSObject.Properties['components']
        foreach ($componentType in $componentTypes) {
            $stageStartedAt = Get-Date
            $componentState = @($componentsProperty.Value.PSObject.Properties | Where-Object {
                [string]::Equals($_.Name, $componentType, [StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1)[0].Value

            # 5a. Прапорці manifest і фізична наявність — категорія RestoreFailed
            # (неповна generation), окремо від хеш-проблем.
            if (-not ([bool]$componentState.Enabled -and [bool]$componentState.CreateSuccess -and
                    [bool]$componentState.IntegritySuccess -and [bool]$componentState.HashSuccess)) {
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "component $componentType не має COMPLETE archive/integrity/SHA512 state у manifest"
            }
            $manifestArchivePath = [string]$componentState.ArchivePath
            $manifestHashPath = [string]$componentState.HashPath
            if (-not (Test-Path -LiteralPath $manifestArchivePath -PathType Leaf) -or
                -not (Test-Path -LiteralPath $manifestHashPath -PathType Leaf)) {
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "component ${componentType}: архів або sidecar відсутні ($manifestArchivePath)"
            }
            # 5b. Manifest-шляхи — недовірений вхід: для Local вони мусять
            # лежати в межах BackupRoot (захист від path traversal). Для SFTP
            # шляхи вже переписані на наш власний staging.
            $artifactContainmentRoot = if ($Source -eq 'Local') { $backupRootPath } else { $script:dataRestoreStagingGenerationRoot }
            foreach ($artifactPath in @($manifestArchivePath, $manifestHashPath)) {
                if (-not (Test-BRAVODataRestorePathWithin -Path $artifactPath -Directory $artifactContainmentRoot)) {
                    Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "component ${componentType}: артефакт поза межами довіреного кореня ($artifactPath)"
                }
            }
            # 5c. Спільний строгий gate (sidecar + фактичний SHA512). Після
            # пре-перевірок вище будь-яка його відмова — саме хеш-клас (42).
            $verifiedArchive = $null
            try {
                $verifiedArchive = Get-BRAVOVerifiedGenerationArchive `
                    -Manifest $selectedManifest `
                    -Component $componentType
            } catch {
                Stop-BRAVODataRestoreRun -Category HashValidationFailed -Reason $_.Exception.Message
            }
            # 5d. Крос-перевірка sidecar проти хешу, записаного в manifest.
            $manifestRecordedHash = [string]$componentState.SHA512
            if (-not [string]::IsNullOrWhiteSpace($manifestRecordedHash)) {
                $sidecarText = ([IO.File]::ReadAllText($manifestHashPath)).Trim([char]0xFEFF).Trim()
                if ($sidecarText -match '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$') {
                    if ($Matches.Hash.ToUpperInvariant() -cne $manifestRecordedHash.ToUpperInvariant()) {
                        Stop-BRAVODataRestoreRun -Category HashValidationFailed -Reason "component ${componentType}: SHA512 у sidecar і в manifest не збігаються"
                    }
                }
            }
            # 5e. 7-Zip integrity.
            $integrityOk = Test-SevenZipArchiveIntegrity `
                -SevenZipPath $arcPath `
                -ArchivePath $verifiedArchive.FullName `
                -Password $script:archivePassword `
                -TimeoutSeconds $script:effectiveSevenZipTimeoutSeconds `
                -Logger { param($m, $l) Write-DataRestoreLog -Message $m -Level $l }
            if (-not $integrityOk) {
                Stop-BRAVODataRestoreRun -Category IntegrityTestFailed -Reason "component ${componentType}: 7za t (перевірка цілісності) не пройдено"
            }
            $componentArtifacts[$componentType] = $verifiedArchive
            Write-BRAVOOperationResult `
                -Name "Перевірка $componentType" `
                -Status 'OK' `
                -Duration ((Get-Date) - $stageStartedAt) `
                -Details $verifiedArchive.Name
        }

        # --- 6. Інвентаризація архівів ---
        $stageStartedAt = Get-Date
        foreach ($componentType in $componentTypes) {
            $inventory = Get-BRAVOSevenZipArchiveInventory `
                -SevenZipPath $arcPath `
                -ArchivePath $componentArtifacts[$componentType].FullName `
                -Password $script:archivePassword `
                -TimeoutSeconds $script:effectiveSevenZipTimeoutSeconds
            if (-not $inventory.Success) {
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "component ${componentType}: інвентаризація архіву не вдалася ($($inventory.Description))"
            }
            $componentInventories[$componentType] = $inventory
            Write-DataRestoreLog -Message ("Інвентаризація {0}: файлів {1}, каталогів {2}, обсяг {3}" -f `
                $componentType, $inventory.FileCount, $inventory.DirectoryCount,
                (Format-BRAVOFileSize -Bytes ([long]$inventory.TotalUncompressedBytes))) -Level 'INFO'
        }
        Write-BRAVOOperationResult `
            -Name 'Інвентаризація архівів' `
            -Status 'OK' `
            -Duration ((Get-Date) - $stageStartedAt)

        # --- 7. Free-space preflight цілей ---
        $stageStartedAt = Get-Date
        $targetRequirements = @()
        foreach ($planComponent in $restorePlan.Components) {
            $targetRequirements += [pscustomobject]@{
                TargetDirectory = [string]$planComponent.TargetDirectory
                RequiredBytes = [long]$componentInventories[[string]$planComponent.Type].TotalUncompressedBytes
            }
        }
        $targetSpaceCheck = Test-BRAVODataRestoreFreeSpace `
            -Requirements $targetRequirements `
            -MinimumFreeGigabytes ([double]$maintenanceSettings.Limits.MinimumFreeSpaceGB)
        foreach ($spaceNote in $targetSpaceCheck.Notes) {
            Write-DataRestoreLog -Message "Free-space: $spaceNote" -Level 'INFO'
        }
        if (-not $targetSpaceCheck.Success) {
            Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason ($targetSpaceCheck.Problems -join '; ')
        }
        Write-BRAVOOperationResult `
            -Name 'Перевірка вільного місця' `
            -Status 'OK' `
            -Duration ((Get-Date) - $stageStartedAt)

        # --- 8. План відновлення (друк) + InPlace-специфіка ---
        Write-BRAVOResultSection -Title 'План відновлення'
        Write-BRAVOResultNote -Text ("  Generation: {0}" -f $script:dataRestoreSelectedGenerationId)
        foreach ($planComponent in $restorePlan.Components) {
            $planInventory = $componentInventories[[string]$planComponent.Type]
            Write-BRAVOResultNote -Text ("  {0}: {1} файлів, {2} -> {3}" -f `
                $planComponent.Type, $planInventory.FileCount,
                (Format-BRAVOFileSize -Bytes ([long]$planInventory.TotalUncompressedBytes)),
                $planComponent.TargetDirectory)
            if (-not [string]::IsNullOrWhiteSpace([string]$planComponent.PrerestoreDirectory)) {
                Write-BRAVOResultNote -Text ("      поточні дані -> {0}" -f $planComponent.PrerestoreDirectory)
            }
        }

        if ($Mode -eq 'InPlace') {
            # Наявні .prerestore-копії попередніх відновлень — видимі, не мовчазні.
            foreach ($planComponent in $restorePlan.Components) {
                $liveParent = Split-Path ([string]$planComponent.LiveSourceDirectory) -Parent
                $liveLeaf = Split-Path ([string]$planComponent.LiveSourceDirectory) -Leaf
                if (-not [string]::IsNullOrWhiteSpace($liveParent) -and (Test-Path -LiteralPath $liveParent -PathType Container)) {
                    foreach ($existingPrerestore in @(Get-ChildItem -LiteralPath $liveParent -Directory -Filter "$liveLeaf.prerestore_*" -ErrorAction SilentlyContinue)) {
                        Write-BRAVOResultNote -Text ("      наявна попередня копія: {0} (від {1:yyyy-MM-dd HH:mm})" -f $existingPrerestore.FullName, $existingPrerestore.LastWriteTime)
                    }
                }
            }
            # Знімок стану служб.
            $stageStartedAt = Get-Date
            $script:dataRestoreServiceSnapshot = Get-BRAVODataRestoreServiceSnapshot `
                -ServicesSettings $maintenanceSettings.Services
            $servicesToStop = @($script:dataRestoreServiceSnapshot | Where-Object { $_.Managed -and $_.WasRunning })
            Write-BRAVOResultNote -Text ("  Служби для зупинки: {0}" -f $(if ($servicesToStop.Count -gt 0) { @($servicesToStop | ForEach-Object { $_.Name }) -join ', ' } else { 'немає (жодна не працює)' }))
            Write-BRAVOOperationResult `
                -Name 'Знімок стану служб' `
                -Status 'OK' `
                -Duration ((Get-Date) - $stageStartedAt)

            # Підтвердження — після повного плану, до першої деструктивної дії.
            if (-not (Request-BRAVODataRestoreConfirmation `
                    -GenerationIdToConfirm $script:dataRestoreSelectedGenerationId `
                    -ForceConfirmation:$Force)) {
                Stop-BRAVODataRestoreRun -Category InvalidConfiguration -Reason 'підтвердження оператора не отримано — відновлення скасовано, жодних змін не виконано'
            }

            # Зупинка служб.
            $stageStartedAt = Get-Date
            $script:dataRestoreServicesStopped = $true
            $stopFailures = Stop-BRAVODataRestoreServices `
                -Snapshot $script:dataRestoreServiceSnapshot `
                -StopTimeoutSeconds $serviceStopTimeoutSeconds `
                -PollIntervalSeconds $servicePollIntervalSeconds
            if (@($stopFailures).Count -gt 0) {
                Write-BRAVOOperationResult -Name 'Зупинка служб' -Status 'FAIL' -Duration ((Get-Date) - $stageStartedAt)
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason ($stopFailures -join '; ')
            }
            Write-BRAVOOperationResult `
                -Name 'Зупинка служб' `
                -Status $(if ($servicesToStop.Count -gt 0) { 'OK' } else { 'SKIPPED' }) `
                -Duration ((Get-Date) - $stageStartedAt)
        }

        # --- 9. Відновлення по компонентах (fail-fast) ---
        # Успішно відновлені InPlace-компоненти цього прогону: потрібні, щоб
        # при збої наступного компонента повернути production до узгодженого
        # стану (крос-компонентний rollback), а не лишити суміш generation.
        $completedInPlaceComponents = New-Object System.Collections.ArrayList
        $createdTargetRoot = $false
        if ($Mode -eq 'OutOfPlace' -and -not (Test-Path -LiteralPath $restorePlan.TargetRoot -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $restorePlan.TargetRoot -Force -ErrorAction Stop)
            $createdTargetRoot = $true
            try {
                Set-BRAVODataRestoreCreatedDirectoryAcl -Path $restorePlan.TargetRoot
            } catch {
                $script:dataRestoreWarningCount++
                Write-DataRestoreLog -Message "Не вдалося застосувати захисний ACL до $($restorePlan.TargetRoot): $($_.Exception.Message)" -Level 'WARNING'
            }
        }
        foreach ($planComponent in $restorePlan.Components) {
            $componentType = [string]$planComponent.Type
            $componentStartedAt = Get-Date
            $moveAsidePerformed = $false
            try {
                if ($Mode -eq 'InPlace') {
                    $moveAsideResult = Invoke-BRAVODataRestoreMoveAside `
                        -LiveDirectory $planComponent.LiveSourceDirectory `
                        -PrerestoreDirectory $planComponent.PrerestoreDirectory
                    if (-not $moveAsideResult.Success) {
                        throw $moveAsideResult.Error
                    }
                    $moveAsidePerformed = [bool]$moveAsideResult.Performed
                    # Test-only deterministic failpoint (B20 acceptance):
                    # ПІСЛЯ підтвердженого move-aside SUCCESS (компонент уже
                    # мутований), ДО створення цільового каталогу й
                    # extraction. No-op у будь-якому production/normal
                    # test-запуску — див. Invoke-BRAVODataRestoreTestFailPoint.
                    Invoke-BRAVODataRestoreTestFailPoint -Point 'AfterMoveAside' -Component $componentType
                }
                # Свіжий порожній каталог цілі — нічого не перезаписується
                # за конструкцією.
                [void](New-Item -ItemType Directory -Path $planComponent.TargetDirectory -Force -ErrorAction Stop)
                if ($Mode -eq 'InPlace' -and $moveAsidePerformed) {
                    try {
                        Copy-BRAVODataRestoreDirectoryAcl `
                            -SourceDirectory $planComponent.PrerestoreDirectory `
                            -DestinationDirectory $planComponent.TargetDirectory
                    } catch {
                        $script:dataRestoreWarningCount++
                        Write-DataRestoreLog -Message "Не вдалося перенести ACL на $($planComponent.TargetDirectory): $($_.Exception.Message)" -Level 'WARNING'
                    }
                }
                $extractionResult = Invoke-BRAVOSevenZipExtraction `
                    -SevenZipPath $arcPath `
                    -ArchivePath $componentArtifacts[$componentType].FullName `
                    -Password $script:archivePassword `
                    -ExtractDirectory $planComponent.TargetDirectory `
                    -TimeoutSeconds $script:effectiveSevenZipTimeoutSeconds
                if (-not $extractionResult.Success) {
                    throw "розпакування не вдалося: $($extractionResult.Description)"
                }
                $verification = Test-BRAVODataRestoreExtractionResult `
                    -TargetDirectory $planComponent.TargetDirectory `
                    -Inventory $componentInventories[$componentType]
                if (-not $verification.Success) {
                    throw "post-verify не пройдено: $($verification.Problems -join '; ')"
                }
                $componentDurationSeconds = ((Get-Date) - $componentStartedAt).TotalSeconds
                $existingResult = @($script:dataRestoreComponentResults | Where-Object { $_.Component -eq $componentType })[0]
                [void]$script:dataRestoreComponentResults.Remove($existingResult)
                Add-BRAVODataRestoreComponentResult `
                    -ComponentType $componentType `
                    -Status 'RESTORED' `
                    -TargetDirectory $planComponent.TargetDirectory `
                    -PrerestoreDirectory $(if ($moveAsidePerformed) { $planComponent.PrerestoreDirectory } else { $null }) `
                    -FileCount $verification.FileCount `
                    -ByteCount $verification.ByteCount `
                    -DurationSeconds $componentDurationSeconds `
                    -Detail 'відновлено й перевірено'
                Write-BRAVOOperationResult `
                    -Name "Відновлення $componentType" `
                    -Status 'OK' `
                    -Duration ((Get-Date) - $componentStartedAt) `
                    -Details ("файлів: {0}, обсяг: {1}" -f $verification.FileCount, (Format-BRAVOFileSize -Bytes $verification.ByteCount))
                Write-DataRestoreLog -Message ("Компонент {0} відновлено: {1} файлів, {2} -> {3}" -f `
                    $componentType, $verification.FileCount,
                    (Format-BRAVOFileSize -Bytes $verification.ByteCount),
                    $planComponent.TargetDirectory) -Level 'SUCCESS'
                if ($Mode -eq 'InPlace') {
                    [void]$completedInPlaceComponents.Add([pscustomobject]@{
                        Type = $componentType
                        LiveDirectory = [string]$planComponent.TargetDirectory
                        PrerestoreDirectory = [string]$planComponent.PrerestoreDirectory
                        MoveAsidePerformed = $moveAsidePerformed
                    })
                }
            } catch {
                $componentFailureReason = $_.Exception.Message
                # Rollback: InPlace повертає prerestore-копію; OutOfPlace
                # прибирає частково розпакований підкаталог, який створили ми.
                if ($Mode -eq 'InPlace') {
                    $rollback = Undo-BRAVODataRestoreMoveAside `
                        -LiveDirectory $planComponent.TargetDirectory `
                        -PrerestoreDirectory $planComponent.PrerestoreDirectory `
                        -MoveAsidePerformed $moveAsidePerformed
                    if (-not $rollback.Success) {
                        $componentFailureReason = "$componentFailureReason; $($rollback.Error)"
                        Send-BRAVODataRestoreNotification `
                            -Severity 'CRITICAL' `
                            -ResultLines @("Rollback компонента $componentType не вдався", [string]$rollback.Error) `
                            -ActionText 'негайно перевірити стан каталогів компонента вручну.'
                    }
                    # Крос-компонентний rollback: production не можна лишати
                    # зі змішаними generation (частина компонентів з backup,
                    # частина — зі старими даними), тому вже відновлені
                    # компоненти цього прогону теж повертаються назад.
                    if ($completedInPlaceComponents.Count -gt 0) {
                        $crossRollback = Undo-BRAVODataRestoreCompletedComponents `
                            -CompletedComponents @($completedInPlaceComponents.ToArray())
                        # ROLLED_BACK / ROLLBACK_FAILED: компонент, відкат якого
                        # НЕ завершився, не можна лишати зі статусом RESTORED —
                        # його каталог не є гарантовано ані новим, ані попереднім
                        # станом. Для ROLLBACK_FAILED зберігаємо PrerestoreDirectory:
                        # копія лишилась на місці й потрібна для ручного повернення.
                        foreach ($statusUpdate in @(Get-BRAVODataRestoreRollbackStatusUpdates `
                                -CrossRollbackResult $crossRollback `
                                -FailedComponent $componentType)) {
                            $previousResult = @($script:dataRestoreComponentResults |
                                Where-Object { $_.Component -eq $statusUpdate.Component })[0]
                            $preservedPrerestoreDirectory = $null
                            if ($null -ne $previousResult) {
                                if ([string]$statusUpdate.Status -eq 'ROLLBACK_FAILED') {
                                    $preservedPrerestoreDirectory = [string]$previousResult.PrerestoreDirectory
                                }
                                [void]$script:dataRestoreComponentResults.Remove($previousResult)
                            }
                            Add-BRAVODataRestoreComponentResult `
                                -ComponentType ([string]$statusUpdate.Component) `
                                -Status ([string]$statusUpdate.Status) `
                                -PrerestoreDirectory $preservedPrerestoreDirectory `
                                -Detail ([string]$statusUpdate.Detail)
                        }
                        if (@($crossRollback.Failures).Count -gt 0) {
                            $crossRollbackFailureText = @(Format-BRAVODataRestoreRollbackFailureText -Failures @($crossRollback.Failures))
                            $componentFailureReason = "$componentFailureReason; $($crossRollbackFailureText -join '; ')"
                            Send-BRAVODataRestoreNotification `
                                -Severity 'CRITICAL' `
                                -ResultLines (@('Відкат раніше відновлених компонентів не завершився') + $crossRollbackFailureText) `
                                -ActionText 'негайно перевірити стан каталогів компонентів вручну — production може бути у змішаному стані.'
                        }
                        [void]$completedInPlaceComponents.Clear()
                    }
                } else {
                    try {
                        if (Test-Path -LiteralPath $planComponent.TargetDirectory) {
                            Remove-Item -LiteralPath $planComponent.TargetDirectory -Recurse -Force -ErrorAction Stop
                        }
                    } catch {
                        $script:dataRestoreWarningCount++
                        Write-DataRestoreLog -Message "Не вдалося прибрати частковий результат $($planComponent.TargetDirectory): $($_.Exception.Message)" -Level 'WARNING'
                    }
                }
                $existingResult = @($script:dataRestoreComponentResults | Where-Object { $_.Component -eq $componentType })[0]
                [void]$script:dataRestoreComponentResults.Remove($existingResult)
                Add-BRAVODataRestoreComponentResult `
                    -ComponentType $componentType `
                    -Status 'FAILED' `
                    -TargetDirectory $planComponent.TargetDirectory `
                    -DurationSeconds ((Get-Date) - $componentStartedAt).TotalSeconds `
                    -Detail $componentFailureReason
                Write-BRAVOOperationResult `
                    -Name "Відновлення $componentType" `
                    -Status 'FAIL' `
                    -Duration ((Get-Date) - $componentStartedAt) `
                    -Details $componentFailureReason
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "component ${componentType}: $componentFailureReason"
            }
        }

        # --- 10. SFTP staging: успіх -> прибрати ---
        if ($Source -eq 'SFTP' -and -not [string]::IsNullOrWhiteSpace([string]$script:dataRestoreStagingGenerationRoot)) {
            try {
                if (Test-Path -LiteralPath $script:dataRestoreStagingGenerationRoot) {
                    Remove-Item -LiteralPath $script:dataRestoreStagingGenerationRoot -Recurse -Force -ErrorAction Stop
                }
                $script:dataRestoreStagingKept = $false
            } catch {
                $script:dataRestoreStagingKept = $true
                $script:dataRestoreWarningCount++
                Write-DataRestoreLog -Message "Не вдалося прибрати staging $($script:dataRestoreStagingGenerationRoot): $($_.Exception.Message)" -Level 'WARNING'
            }
        }
    } catch {
        if (-not $script:dataRestoreControlledAbort) {
            $script:flagInternalError = $true
            Write-DataRestoreLog -Message "НЕОЧІКУВАНА ПОМИЛКА: $($_.Exception.Message)" -Level 'ERROR' -Console
            Write-DataRestoreLog -Message ([string]$_.ScriptStackTrace) -Level 'DEBUG'
        }
        if ($Source -eq 'SFTP' -and -not [string]::IsNullOrWhiteSpace([string]$script:dataRestoreStagingGenerationRoot) -and
            (Test-Path -LiteralPath $script:dataRestoreStagingGenerationRoot)) {
            # Невдалий прогін лишає staging для діагностики/повтору (resume).
            $script:dataRestoreStagingKept = $true
        }
    } finally {
        # Відновлення стану служб — гарантовано, навіть після необробленої
        # помилки: запускаються лише ті, що працювали на момент знімка.
        if ($script:dataRestoreServicesStopped -and $null -ne $script:dataRestoreServiceSnapshot) {
            $restoreServicesStartedAt = Get-Date
            $startFailures = Restore-BRAVODataRestoreServices `
                -Snapshot $script:dataRestoreServiceSnapshot `
                -StartTimeoutSeconds $serviceStartTimeoutSeconds `
                -PollIntervalSeconds $servicePollIntervalSeconds
            if (@($startFailures).Count -gt 0) {
                # Дані могли бути відновлені, але production не працює —
                # операційно це невдале відновлення (43), не warning.
                $script:flagRestoreFailed = $true
                if ([string]::IsNullOrWhiteSpace([string]$script:dataRestoreAbortReason)) {
                    $script:dataRestoreAbortReason = ($startFailures -join '; ')
                }
                Write-BRAVOOperationResult -Name 'Відновлення стану служб' -Status 'FAIL' -Duration ((Get-Date) - $restoreServicesStartedAt) -Details ($startFailures -join '; ')
            } else {
                Write-BRAVOOperationResult -Name 'Відновлення стану служб' -Status 'OK' -Duration ((Get-Date) - $restoreServicesStartedAt)
            }
        }
    }
} finally {
    Exit-BRAVODataRestoreOperationLock
}

# ===== POST-RESTORE HEALTH (лише успішний InPlace) =====
$anyFailure = ($script:flagInternalError -or $script:flagInvalidConfiguration -or
    $script:flagCredentialsUnavailable -or $script:flagIntegrityTestFailed -or
    $script:flagHashValidationFailed -or $script:flagRestoreFailed -or $script:flagSftpFailed)
if ($Mode -eq 'InPlace' -and -not $anyFailure -and -not $SkipHealthCheck) {
    $healthStartedAt = Get-Date
    $script:dataRestoreHealthExitCode = Invoke-BRAVODataRestorePostHealth
    if ($null -eq $script:dataRestoreHealthExitCode) {
        $script:dataRestoreWarningCount++
        Write-BRAVOOperationResult -Name 'Health після відновлення' -Status 'WARN' -Duration ((Get-Date) - $healthStartedAt) -Details 'не вдалося запустити'
    } elseif ([int]$script:dataRestoreHealthExitCode -ne 0) {
        # Ненульовий Health одразу після старту служб — попередження (служби
        # можуть ще прогріватися), НЕ підстава оголошувати відновлення
        # невдалим і не 70: детальна діагностика — у журналі самого Health.
        $script:dataRestoreWarningCount++
        Write-BRAVOOperationResult -Name 'Health після відновлення' -Status 'WARN' -Duration ((Get-Date) - $healthStartedAt) -Details ("код {0} — {1}" -f $script:dataRestoreHealthExitCode, (Get-BRAVOExitCodeName -Code ([int]$script:dataRestoreHealthExitCode)))
    } else {
        Write-BRAVOOperationResult -Name 'Health після відновлення' -Status 'OK' -Duration ((Get-Date) - $healthStartedAt)
    }
}

# ===== КОД ЗАВЕРШЕННЯ + ПІДСУМОК =====
# Код обчислюється ОДИН раз, до друку підсумку — журнал і консоль не можуть
# розійтися (той самий принцип, що Archive/Health/Maintenance).
$dataRestoreExitCode = Resolve-BRAVOExitCode `
    -InternalError:$script:flagInternalError `
    -InvalidConfiguration:$script:flagInvalidConfiguration `
    -CredentialsUnavailable:$script:flagCredentialsUnavailable `
    -IntegrityTestFailed:$script:flagIntegrityTestFailed `
    -HashValidationFailed:$script:flagHashValidationFailed `
    -RestoreFailed:$script:flagRestoreFailed `
    -SftpFailed:$script:flagSftpFailed `
    -HasWarnings:($script:dataRestoreWarningCount -gt 0)

$summaryStatus = if ($dataRestoreExitCode -eq 0) {
    'УСПІШНО'
} elseif ($dataRestoreExitCode -eq 10) {
    'УСПІШНО З ПОПЕРЕДЖЕННЯМИ'
} else {
    'ПОМИЛКА'
}
$summaryStatusColor = switch ($summaryStatus) {
    'УСПІШНО' { [ConsoleColor]::Green }
    'УСПІШНО З ПОПЕРЕДЖЕННЯМИ' { [ConsoleColor]::Yellow }
    default { [ConsoleColor]::Red }
}
Write-BRAVOResultHeader `
    -Status $summaryStatus `
    -StatusColor $summaryStatusColor `
    -ExitCode $dataRestoreExitCode `
    -ExitCodeName (Get-BRAVOExitCodeName -Code $dataRestoreExitCode) `
    -Reason $script:dataRestoreAbortReason
Write-BRAVOResultField -Label 'Режим' -Value $(if ($Mode -eq 'InPlace') { 'InPlace (production)' } else { "OutOfPlace ($TargetPath)" })
Write-BRAVOResultField -Label 'Джерело' -Value $Source
Write-BRAVOResultField -Label 'GenerationId' -Value $(if ([string]::IsNullOrWhiteSpace([string]$script:dataRestoreSelectedGenerationId)) { 'не вибрано' } else { [string]$script:dataRestoreSelectedGenerationId })
Write-BRAVOResultField -Label 'Початок' -Value $script:ScriptStartTime.ToString('yyyy-MM-dd HH:mm:ss')
Write-BRAVOResultField -Label 'Завершення' -Value ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))
Write-BRAVOResultField -Label 'Тривалість' -Value (Format-BRAVODuration -Duration ([DateTime]::Now - $script:ScriptStartTime))
if ($null -ne $script:dataRestoreHealthExitCode) {
    Write-BRAVOResultField -Label 'Health' -Value ("{0} — {1}" -f $script:dataRestoreHealthExitCode, (Get-BRAVOExitCodeName -Code ([int]$script:dataRestoreHealthExitCode)))
}
if (@($script:dataRestoreComponentResults).Count -gt 0) {
    Write-BRAVOResultSection -Title 'Компоненти'
    foreach ($componentResult in $script:dataRestoreComponentResults) {
        $componentStatusText = switch ([string]$componentResult.Status) {
            'RESTORED' { 'ВІДНОВЛЕНО' }
            'ROLLED_BACK' { 'ВІДКОЧЕНО' }
            'ROLLBACK_FAILED' { 'ПОМИЛКА ВІДКАТУ' }
            'FAILED' { 'ПОМИЛКА' }
            default { 'НЕ ВИКОНУВАВСЯ' }
        }
        $componentLine = "  {0}: {1}" -f $componentResult.Component, $componentStatusText
        if ([string]$componentResult.Status -eq 'RESTORED') {
            $componentLine += (" ({0} файлів, {1}) -> {2}" -f $componentResult.FileCount,
                (Format-BRAVOFileSize -Bytes ([long]$componentResult.ByteCount)), $componentResult.TargetDirectory)
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$componentResult.Detail)) {
            $componentLine += (" — {0}" -f $componentResult.Detail)
        }
        Write-BRAVOResultNote -Text $componentLine
    }
}
# Успішно відкочені компоненти сюди НЕ потрапляють: їхню prerestore-копію
# вже повернуто на оригінальне ім'я, і надрукований шлях більше не існує.
# ROLLBACK_FAILED, навпаки, лишається: копія на місці й саме вона потрібна
# для ручного повернення.
$prerestoreDirectories = @($script:dataRestoreComponentResults |
    Where-Object {
        [string]$_.Status -ne 'ROLLED_BACK' -and
        -not [string]::IsNullOrWhiteSpace([string]$_.PrerestoreDirectory)
    } |
    ForEach-Object { [string]$_.PrerestoreDirectory })
$rollbackFailedComponents = @($script:dataRestoreComponentResults |
    Where-Object { [string]$_.Status -eq 'ROLLBACK_FAILED' } |
    ForEach-Object { [string]$_.Component })
if ($prerestoreDirectories.Count -gt 0) {
    Write-BRAVOResultSection -Title 'Prerestore-копії (попередні дані)'
    foreach ($prerestoreDirectory in $prerestoreDirectories) {
        Write-BRAVOResultNote -Text "  $prerestoreDirectory"
    }
    Write-BRAVOResultNote -Text '  Копії не видаляються автоматично: після підтвердження працездатності видаліть їх вручну.'
    if ($rollbackFailedComponents.Count -gt 0) {
        Write-BRAVOResultNote -Text ("  УВАГА: відкат не завершено для {0} — стан цих каталогів не гарантований." -f ($rollbackFailedComponents -join ', '))
        Write-BRAVOResultNote -Text '  Не видаляйте їхні prerestore-копії: поверніть дані вручну за OPERATIONS.md, розділ коду 43.'
    }
}
if ($script:dataRestoreStagingKept -and -not [string]::IsNullOrWhiteSpace([string]$script:dataRestoreStagingGenerationRoot)) {
    Write-BRAVOResultNote -Text ''
    Write-BRAVOResultNote -Text ("Staging збережено для діагностики/повтору: {0}" -f $script:dataRestoreStagingGenerationRoot)
}
if ($Mode -eq 'OutOfPlace' -and $dataRestoreExitCode -le 10) {
    Write-BRAVOResultNote -Text ''
    Write-BRAVOResultNote -Text 'Production-дані не змінювались.'
}
Write-BRAVOResultFooter -LogFile $script:dataRestoreLogFile

# ===== СПОВІЩЕННЯ =====
# none — ніколи; errors_only — відмови/попередження + успішний InPlace
# (production-відновлення заслуговує запису); all — усе.
$notificationMode = ([string]$bravoSettings.NotificationMode).Trim().ToLowerInvariant()
if ($notificationMode -ne 'none') {
    $notificationLines = @("Режим: $Mode, джерело: $Source, generation: $($script:dataRestoreSelectedGenerationId)")
    foreach ($componentResult in $script:dataRestoreComponentResults) {
        $notificationLines += ("{0}: {1}{2}" -f $componentResult.Component, $componentResult.Status,
            $(if ([string]::IsNullOrWhiteSpace([string]$componentResult.Detail)) { '' } else { " — $($componentResult.Detail)" }))
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:dataRestoreAbortReason)) {
        $notificationLines += "Причина: $script:dataRestoreAbortReason"
    }
    if ($dataRestoreExitCode -ge 20) {
        Send-BRAVODataRestoreNotification `
            -Severity 'CRITICAL' `
            -ResultLines $notificationLines `
            -ActionText 'перевірити журнал відновлення даних.'
    } elseif ($dataRestoreExitCode -eq 10) {
        Send-BRAVODataRestoreNotification `
            -Severity 'WARNING' `
            -ResultLines $notificationLines `
            -ActionText 'переглянути попередження в журналі відновлення даних.'
    } elseif ($Mode -eq 'InPlace' -or $notificationMode -eq 'all') {
        Send-BRAVODataRestoreNotification `
            -Severity 'SUCCESS' `
            -ResultLines $notificationLines
    }
}

Write-DataRestoreLog -Message "Завершення з кодом $dataRestoreExitCode ($(Get-BRAVOExitCodeName -Code $dataRestoreExitCode))" -Level 'INFO'
exit $dataRestoreExitCode

} finally {
    Wait-BRAVOManualExit -NoPause:$NoPause
}
