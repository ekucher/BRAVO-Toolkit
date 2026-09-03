Set-StrictMode -Version 2.0

# BRAVO.Configuration.Derivation — canonical derivation resolver (P0
# Configuration Foundation, PR B).
#
# Це ДОСЛІВНЕ (behavior-preserving) перенесення derivation-секції, яка
# сьогодні живе всередині BRAVO.config (рядки приблизно 608-1300:
# discovery, effective LIMS/Backup/SystemLog корені, sourcePaths,
# archiveDirs/archiveDefinitions, storageEffective/bazaSyncEffective,
# похідні листові поля backupMonitoring/schedulerSettings, шляхи
# інструментів/стану/логів). Мета — ОДИН canonical resolver, який
# викликають ОБИДВА шляхи (BRAVO.config present і BRAVO.config absent),
# а не дві незалежні копії derivation-логіки (docs/design/
# BRAVO_CONFIGURATION_FOUNDATION_DESIGN.md, розділ 6.2 п.7).
#
# Залежність: Resolve-BRAVOEffectiveLimsRoot, Resolve-BRAVOInstallation
# Discovery, Resolve-BRAVOEffectiveBackupRoot, Resolve-
# BRAVOEffectiveSystemLogRoot, Get-BRAVOEffectiveStorageConfiguration,
# Get-BRAVOEffectiveSynchronizationConfiguration — усі з
# modules/BRAVO.Discovery.
#
# CI remediation (fresh-process defect, BRAVO_DATA_RESTORE_MATRIX_TEST.ps1):
# попередній коментар тут стверджував, що викликач (BRAVO_CONFIG_LOADER.ps1)
# "вже імпортує BRAVO.Discovery ПЕРЕД виконанням BRAVO.config/цієї функції"
# — це припущення НЕ тримається в реальному fresh-process execution path.
# BRAVO_CONFIG_LOADER.ps1 імпортує BRAVO.Discovery з-під ланцюжка
# dot-source, який виконується ВСЕРЕДИНІ SessionState модуля BRAVO.Archive
# (RootModule BRAVO.Archive.psm1 дот-сорсить BRAVO.Archive.Runtime.ps1,
# який дот-сорсить BRAVO_CONFIG_LOADER.ps1). PowerShell 5.1 Import-Module,
# викликаний із СЕРЕДИНИ чужого модуля (без -Global), імпортує залежність
# у ПРИВАТНИЙ SessionState цього викликача (BRAVO.Archive), а НЕ в global
# scope. Цей модуль (BRAVO.Configuration.Derivation) імпортується
# ОКРЕМИМ Import-Module-викликом (з BRAVO.config, теж усередині
# BRAVO.Archive scope) — тобто отримує СВІЙ ВЛАСНИЙ ізольований
# SessionState, який НЕ бачить приватний імпорт BRAVO.Discovery, зроблений
# іншим модулем. Функція нижче резолвить виклики лише проти власного
# SessionState модуля + справжнього global scope — жодного з них
# Discovery не займає, звідси "Resolve-BRAVOEffectiveLimsRoot is not
# recognized" у fresh child powershell.exe (BRAVO_SELF_TEST.ps1 це не
# ловив: self-test виконує цю функцію в іншому, спрощеному scope-ланцюжку,
# не через повний BRAVO_ARCHIV.ps1 -> BRAVO.Archive module -> BRAVO.config
# ланцюг). Тому цей модуль явно й детерміновано імпортує СВОЮ ВЛАСНУ
# залежність нижче — не покладаючись на випадковий caller scope.
$discoveryModulePathForDerivation = Join-Path -Path $PSScriptRoot -ChildPath '..\BRAVO.Discovery\BRAVO.Discovery.psd1'
Import-Module -Name $discoveryModulePathForDerivation -ErrorAction Stop
#
# Свідома зміна поведінки (докладно — design-документ, ТЗ Test 17): у
# поточному BRAVO.config sftpDirectories/backupMonitoring/
# schedulerSettings/restoreVerifySettings визначаються ПІЗНО (після
# storageEffective/bazaSyncEffective) і перевизначаються окремою
# "фазою 2" BRAVO.local.config В САМОМУУ КІНЦІ файла — тобто today
# local-override sftpDirectories НЕ встигає вплинути на вже обчислений
# bazaSyncEffective того самого завантаження (stale pre-merge derived
# value). Ця функція приймає ці блоки як RAW-параметри, ВЖЕ з
# застосованими overrides (виклик відбувається ПІСЛЯ повного merge,
# однією фазою) — derived-поля (BAZASync.Enabled тощо) тепер коректно
# відображають фінальне значення. Для чинного (незміненого) BRAVO.config
# це не змінює результат: перевизначення sftpDirectories через
# BRAVO.local.config — рідкісний edge case, не задокументований як
# навмисна залежність жодним відомим консьюмером.
function Resolve-BRAVOConfigurationDerivation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$runtimeRoot,

        [Parameter(Mandatory = $true)][hashtable]$bravoSettings,
        [Parameter(Mandatory = $true)][hashtable]$credentialSettings,
        [Parameter(Mandatory = $true)][hashtable]$pathSettings,
        [Parameter(Mandatory = $true)][hashtable]$maintenanceSettings,
        [Parameter(Mandatory = $true)][hashtable]$componentSettings,

        # НЕ overridable через BRAVO.local.config (визначається в
        # BRAVO.config ПІСЛЯ фази overrides) — навмисно, щоб зберегти
        # контракт "discoverySettings не перевизначається" з
        # BRAVO.local.config.example.
        [Parameter(Mandatory = $true)][hashtable]$discoverySettings,

        [Parameter(Mandatory = $true)][hashtable]$sftpDirectories,

        # Raw-листові поля (уже з застосованими overrides) — функція
        # ДОДАЄ до них похідні поля (мутує той самий hashtable-об'єкт і
        # повертає результат у $global:*, як і сьогоднішній BRAVO.config).
        [Parameter(Mandatory = $true)][hashtable]$backupMonitoring,
        [Parameter(Mandatory = $true)][hashtable]$schedulerSettings,
        [Parameter(Mandatory = $true)][hashtable]$restoreVerifySettings
    )

    # credentialSettings.HelperPath/SetupScriptPath — похідні від
    # runtimeRoot шляхи runtime-ресурсів комплекту (не raw-configurable
    # значення). У BRAVO.config вони обчислювались inline одразу при
    # оголошенні $global:credentialSettings, ДО появи цього canonical
    # resolver-а — переносимо сюди, щоб no-config-шлях (BRAVO.config
    # відсутній) отримував той самий результат без другої копії цієї
    # логіки.
    $global:credentialSettings = $credentialSettings
    $global:credentialSettings.HelperPath = Join-Path $runtimeRoot "modules\BRAVO.Credentials\BRAVO.Credentials.psd1"
    $global:credentialSettings.SetupScriptPath = Join-Path $runtimeRoot "BRAVO_CREDENTIALS_SETUP.ps1"

    # maintenanceSettings.General.ObjectName/ArchivePrefix — той самий
    # клас: похідні від bravoSettings значення, обчислені inline при
    # оголошенні $global:maintenanceSettings у BRAVO.config, ДО появи
    # цього resolver-а. Це лише ПОЧАТКОВЕ/placeholder-значення:
    # Import-BRAVOInstitutionSettings (BRAVO.Credentials.psm1, викликана
    # entrypoint-ом одразу після Import-BravoConfiguration) перезаписує
    # обидва поля реальними даними з Credential Manager — але до ТОГО
    # моменту консюмери читають напряму (BRAVO.Maintenance.Runtime.ps1)
    # і під StrictMode впали б на відсутньому ключі без цього дефолту.
    if ($maintenanceSettings.Contains('General') -and $maintenanceSettings.General -is [hashtable]) {
        if ($bravoSettings.Contains('InstitutionName') -and $bravoSettings.Contains('InstitutionCode')) {
            $maintenanceSettings.General.ObjectName = "$($bravoSettings.InstitutionName) [$($bravoSettings.InstitutionCode)]"
        }
        if ($bravoSettings.Contains('ArchivePrefix')) {
            $maintenanceSettings.General.ArchivePrefix = [string]$bravoSettings.ArchivePrefix
        }
    }

    # =============================================
    # ШЛЯХИ ДО ДЖЕРЕЛ ДАНИХ
    # =============================================
    $global:scriptPath = $runtimeRoot

    # EffectiveLIMSRoot: explicit pathSettings.LIMSRoot або AUTO через
    # канонічну службу BRAVO (Name + DisplayName). Відсутність самої
    # служби при LIMSRoot="" НЕ throw тут ("service state != backup
    # policy") — LIMSRoot функціонально потрібен лише BRAVO_MAINTENANCE,
    # яка має власну явну перевірку одразу після Import-BravoConfiguration.
    $global:limsRootResult = Resolve-BRAVOEffectiveLimsRoot `
        -ConfiguredPath ([string]$pathSettings.LIMSRoot) `
        -BravoServiceName ([string]$maintenanceSettings.Services.BravoName) `
        -BravoDisplayName @($maintenanceSettings.Services.BravoDisplayName)
    $global:effectiveLimsRoot = [string]$limsRootResult.EffectivePath
    $global:LIMS_PATH = $global:effectiveLimsRoot
    $global:rootPath = $global:effectiveLimsRoot

    # =============================================
    # АВТОМАТИЧНИЙ DISCOVERY ДЖЕРЕЛ
    # =============================================
    # $discoverySettings прийшов як параметр (визначений у BRAVO.config
    # ПІСЛЯ фази overrides — не overridable, див. коментар параметра).
    $global:discoverySettings = $discoverySettings
    $global:bravoDiscoveryResult = Resolve-BRAVOInstallationDiscovery `
        -LimsRoot $rootPath `
        -DiscoverySettings $discoverySettings `
        -BravoServiceName ([string]$maintenanceSettings.Services.BravoName) `
        -BravoDisplayName @($maintenanceSettings.Services.BravoDisplayName) `
        -WebServiceCandidates @($maintenanceSettings.Services.BravoWebCandidates) `
        -ExchangeApiServiceName ([string]$maintenanceSettings.Services.ExchangeApiName)

    $global:bravoExchSourceCandidates = @(
        [string]$bravoDiscoveryResult.BRAVOEXCH_SOURCE |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $global:bravoExchSourceDirectory = $null
    foreach ($candidateDirectory in $bravoExchSourceCandidates) {
        if (-not (Test-Path -LiteralPath $candidateDirectory -PathType Container)) {
            continue
        }
        # BEXCH is a queue tree and can legitimately contain only empty
        # directories between exchanges. The canonical bravo.ini path plus an
        # existing directory is sufficient identity; requiring a current file
        # would disable backups exactly while the queue is idle.
        $global:bravoExchSourceDirectory = $candidateDirectory
        break
    }
    $bravoExchArchiveSource = if (
        -not [string]::IsNullOrWhiteSpace($bravoExchSourceDirectory)
    ) {
        Join-Path $bravoExchSourceDirectory "*"
    } else {
        $null
    }

    # Джерело істини — Resolve-BRAVOInstallationDiscovery (BAZA_WWW уже
    # обчислено вище): служба Apache2.4/Br-a-vo.web -> httpd.conf ->
    # DocumentRoot -> {DocumentRoot}\BAZA.
    $global:bazaWWWDetection = if (-not (
            [bool]$componentSettings.Synchronization.BAZA_WWW_SFTP -or
            [bool]$componentSettings.Synchronization.BAZA_WWW_LOCAL
        )) {
        [pscustomobject]@{
            Success = $false
            Source = $null
            ServiceName = $null
            ServiceDisplayName = $null
            ServiceExecutable = $null
            Reason = "синхронізацію BAZA WWW вимкнено в конфігурації"
            Presence = [string]$bravoDiscoveryResult.BAZA_WWW_Presence
        }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.BAZA_WWW)) {
        [pscustomobject]@{
            Success = $true
            Source = [string]$bravoDiscoveryResult.BAZA_WWW
            ServiceName = [string]$bravoDiscoveryResult.WebServiceName
            ServiceDisplayName = [string]$bravoDiscoveryResult.WebServiceDisplayName
            ServiceExecutable = [string]$bravoDiscoveryResult.WebServiceExecutable
            Reason = $null
            Presence = [string]$bravoDiscoveryResult.BAZA_WWW_Presence
        }
    } else {
        [pscustomobject]@{
            Success = $false
            Source = $null
            ServiceName = $null
            ServiceDisplayName = $null
            ServiceExecutable = $null
            Reason = [string]$bravoDiscoveryResult.Reasons.BAZA_WWW
            Presence = [string]$bravoDiscoveryResult.BAZA_WWW_Presence
        }
    }

    $global:sourcePaths = @{
        Model = $(if ([string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.MODEL_SOURCE)) { $null } else { Join-Path ([string]$bravoDiscoveryResult.MODEL_SOURCE) "*" })
        Blog = $(if ([string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.BLOG_SOURCE)) { $null } else { Join-Path ([string]$bravoDiscoveryResult.BLOG_SOURCE) "*" })
        BravoExch = $bravoExchArchiveSource
    }

    # =============================================
    # КАТАЛОГИ ПРИЗНАЧЕННЯ
    # =============================================
    $global:backupRootResult = Resolve-BRAVOEffectiveBackupRoot `
        -ConfiguredPath ([string]$pathSettings.BackupRoot) `
        -EffectiveLimsRoot $global:effectiveLimsRoot
    if ([string]$backupRootResult.Source -eq 'Error' -or
        [string]::IsNullOrWhiteSpace([string]$backupRootResult.EffectivePath)) {
        throw "Не вдалося визначити BackupRoot: $($backupRootResult.Reason)"
    }
    $global:backupRootPath = [string]$backupRootResult.EffectivePath

    $global:systemLogRootResult = Resolve-BRAVOEffectiveSystemLogRoot `
        -ConfiguredPath ([string]$pathSettings.SystemLogRoot) `
        -EffectiveLimsRoot $global:effectiveLimsRoot
    $global:systemLogRoot = [string]$systemLogRootResult.EffectivePath

    # RuntimeLogRoot — журнали САМИХ PowerShell-скриптів. ЗАВЖДИ
    # <RuntimeRoot>\LOGS, незалежно від LIMSRoot/SystemLogRoot/BackupRoot.
    $global:runtimeLogRoot = Join-Path $runtimeRoot "LOGS"
    $global:logPath = $global:runtimeLogRoot

    # Машинний стан — поруч з operation lock у %ProgramData%\BRAVO\State.
    $programDataRoot = if ([string]::IsNullOrWhiteSpace($env:ProgramData)) {
        'C:\ProgramData'
    } else {
        [Environment]::ExpandEnvironmentVariables($env:ProgramData)
    }
    $global:stateRoot = Join-Path $programDataRoot 'BRAVO\State'

    # Operation lock — той самий %ProgramData%\BRAVO корінь, що й state.
    # Раніше обчислювався окремо, inline у самому BRAVO.config (ДО появи
    # цього canonical resolver-а) — переносимо сюди, бо це той самий клас
    # похідного (від programDataRoot), не raw-configurable значення, що й
    # stateRoot поруч, і no-config-шлях (BRAVO.config відсутній) потребує
    # того самого обчислення без другої копії цієї логіки.
    $global:operationLockSettings = @{
        Path = Join-Path $programDataRoot 'BRAVO\Locks\BRAVO_OPERATION.lock'
    }

    # Tools\ — runtime-залежності комплекту, лежать поруч зі скриптами
    # (RuntimeRoot).
    $global:toolsPath = Join-Path $runtimeRoot "Tools"
    $global:arcPath = Join-Path $toolsPath "7za.exe"
    $global:winSCPPath = Join-Path $toolsPath "WinSCP.com"
    $global:winSCPAssemblyPath = Join-Path $toolsPath "WinSCPnet.dll"

    $global:toolIntegritySettings = @{
        Mode = "Enforce"
        ManifestPath = Join-Path $toolsPath "TOOLS_MANIFEST.json"
    }

    # ЛОКАЛЬНІ КАТАЛОГИ ДЛЯ ЗБЕРІГАННЯ АРХІВІВ
    $global:archiveDirs = @{
        Model = [System.IO.Path]::Combine($backupRootPath, "MODEL")
        Blog = [System.IO.Path]::Combine($backupRootPath, "BLOG")
        BravoExch = [System.IO.Path]::Combine($backupRootPath, "BRAVOEXCH")
    }

    $global:bazaAppPaths = @{
        Source = [string]$bravoDiscoveryResult.BAZA_APP
        Destination = [System.IO.Path]::Combine($backupRootPath, "BAZA_APP")
    }
    $global:bazaWWWPaths = @{
        Source = [string]$bazaWWWDetection.Source
        Destination = [System.IO.Path]::Combine($backupRootPath, "BAZA_WWW")
    }

    # sftpDirectories — уже повністю raw-параметр (без похідних полів),
    # переданий з уже застосованими overrides. Проєкція в $global: для
    # сумісності з наявними консьюмерами.
    $global:sftpDirectories = $sftpDirectories

    # =============================================
    # ЕФЕКТИВНА КОНФІГУРАЦІЯ ЗОВНІШНІХ СХОВИЩ — ЄДИНЕ ДЖЕРЕЛО ПРАВДИ
    # =============================================
    $global:storageEffective = Get-BRAVOEffectiveStorageConfiguration `
        -ComponentSettings $componentSettings

    # =============================================
    # ЕФЕКТИВНА КОНФІГУРАЦІЯ СИНХРОНІЗАЦІЇ BAZA — ЄДИНЕ ДЖЕРЕЛО ПРАВДИ
    # =============================================
    $global:bazaSyncEffective = Get-BRAVOEffectiveSynchronizationConfiguration `
        -Synchronization $componentSettings.Synchronization `
        -GlobalSftpEnabled ([bool]$global:storageEffective.SFTP.Enabled) `
        -BazaAppSource ([string]$bazaAppPaths.Source) `
        -BazaWWWSource ([string]$bazaWWWPaths.Source) `
        -BazaWWWDetection $bazaWWWDetection `
        -SftpDirectories $sftpDirectories

    # БАЗОВІ ШЛЯХИ, ЯКІ ПЕРЕВІРЯЮТЬСЯ ЗАВЖДИ
    $global:baseRequiredPaths = @(
        @{Path=$logPath; Description="Каталог логiв"; CreateIfMissing=$true}
    )

    # ОПИСИ АРХІВІВ
    $global:archiveDefinitions = @(
        @{
            Type = "MODEL"
            Enabled = $componentSettings.Archive.MODEL
            NameTemplate = "{0}_{1}.mdz"
            Source = $sourcePaths.Model
            Destination = $archiveDirs.Model
        },
        @{
            Type = "BLOG"
            Enabled = $componentSettings.Archive.BLOG
            NameTemplate = "{0}_blog_{1}.mdz"
            Source = $sourcePaths.Blog
            Destination = $archiveDirs.Blog
        },
        @{
            Type = "BRAVOEXCH"
            Enabled = $componentSettings.Archive.BRAVOEXCH
            NameTemplate = "{0}_bravoexch_{1}.mdz"
            Source = $sourcePaths.BravoExch
            Destination = $archiveDirs.BravoExch
        }
    )

    # =============================================
    # МОНІТОРИНГ ЛОКАЛЬНИХ І ВІДДАЛЕНИХ РЕЗЕРВНИХ КОПІЙ
    # =============================================
    $global:backupHealthScriptPath = Join-Path $runtimeRoot "BRAVO_HEALTH.ps1"

    # $backupMonitoring прийшов як raw-параметр (усі листові поля з
    # BRAVO.local.config.example, з уже застосованими overrides) —
    # додаємо похідні поля (мирор bravoSettings/credentialSettings,
    # шляхи стану) в ТОЙ САМИЙ hashtable-об'єкт.
    $global:backupMonitoring = $backupMonitoring
    $global:backupMonitoring.InstitutionName = $bravoSettings.InstitutionName
    $global:backupMonitoring.InstitutionCode = $bravoSettings.InstitutionCode
    $global:backupMonitoring.NotificationProvider = $bravoSettings.NotificationProvider
    $global:backupMonitoring.NotificationMode = $bravoSettings.NotificationMode
    $global:backupMonitoring.NotificationCredentialTargets = $credentialSettings.Targets
    $global:backupMonitoring.NotificationRequestTimeoutSeconds = $bravoSettings.NotificationRequestTimeoutSeconds
    # Safe-default дублюється навмисно: BRAVO.config парситься до
    # гарантованого імпорту BRAVO.Notifications, тому не може покладатись
    # на дефолт усередині модуля.
    $global:backupMonitoring.NotificationRouting = if ($bravoSettings.Contains("NotificationRouting") -and
        $bravoSettings.NotificationRouting -is [hashtable]) {
        $bravoSettings.NotificationRouting
    } else {
        @{ SUCCESS = "general"; WARNING = "alerts"; ERROR = "alerts"; CRITICAL = "alerts" }
    }
    $global:backupMonitoring.AlertStatePath = Join-Path $stateRoot "BRAVO_ARCHIV_HEALTH_ALERT_STATE.json"
    $global:backupMonitoring.SuccessNotificationStatePath = Join-Path $stateRoot "BRAVO_HEALTH_SUCCESS_NOTIFICATION_STATE.json"
    $global:backupMonitoring.OperationalStatePath = Join-Path $stateRoot "BRAVO_HEALTH_OPERATIONAL_STATE.json"
    if ($global:backupMonitoring.Contains('SFTP') -and $global:backupMonitoring.SFTP -is [hashtable] -and
        $global:backupMonitoring.SFTP.Contains('BAZA') -and $global:backupMonitoring.SFTP.BAZA -is [hashtable]) {
        $global:backupMonitoring.SFTP.BAZA.StateRoot = $stateRoot
    }

    # =============================================
    # ПЛАНУВАЛЬНИК ЗАВДАНЬ WINDOWS
    # =============================================
    # $schedulerSettings прийшов як raw-параметр (з уже застосованими
    # overrides) — додаємо похідні поля (ScriptPath, Recovery.Enabled,
    # BAZASync.Enabled) у ТОЙ САМИЙ hashtable-об'єкт.
    $global:schedulerSettings = $schedulerSettings
    $global:schedulerSettings.PowerShellExecutable = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

    if ($global:schedulerSettings.Contains('Backup') -and $global:schedulerSettings.Backup -is [hashtable]) {
        $global:schedulerSettings.Backup.ScriptPath = Join-Path $runtimeRoot "BRAVO_ARCHIV.ps1"
    }
    if ($global:schedulerSettings.Contains('Maintenance') -and $global:schedulerSettings.Maintenance -is [hashtable]) {
        $global:schedulerSettings.Maintenance.ScriptPath = Join-Path $runtimeRoot "BRAVO_MAINTENANCE.ps1"
    }
    if ($global:schedulerSettings.Contains('Health') -and $global:schedulerSettings.Health -is [hashtable]) {
        $global:schedulerSettings.Health.ScriptPath = $backupHealthScriptPath
    }
    if ($global:schedulerSettings.Contains('Recovery') -and $global:schedulerSettings.Recovery -is [hashtable]) {
        # Recovery-завдання реєструється ЛИШЕ на серверах робочого часу
        # (Restore.BootRestoreMode="HoldServices"). Захисне читання
        # (Contains, а не пряме .BootRestoreMode): цей derivation-виклик
        # виконується ВСЕРЕДИНІ BRAVO.config, тобто ДО
        # Assert-BravoLoadedConfiguration (BRAVO_CONFIG_LOADER.ps1) —
        # canonical backfill відсутнього ключа для legacy-конфігів
        # спрацьовує лише ПІСЛЯ повного завантаження, а не тут. Безпечний
        # дефолт 'None' — той самий, що й built-in default і backfill.
        $effectiveBootRestoreMode = if ($maintenanceSettings.Contains('Restore') -and $maintenanceSettings.Restore -is [hashtable] -and
            $maintenanceSettings.Restore.Contains('BootRestoreMode')) {
            [string]$maintenanceSettings.Restore.BootRestoreMode
        } else {
            'None'
        }
        $global:schedulerSettings.Recovery.Enabled = ($effectiveBootRestoreMode -eq "HoldServices")
        $global:schedulerSettings.Recovery.ScriptPath = Join-Path $runtimeRoot "BRAVO_MAINTENANCE.ps1"
        $global:schedulerSettings.Recovery.StartupDelayMinutes = if ($maintenanceSettings.Contains('Restore') -and $maintenanceSettings.Restore -is [hashtable] -and
            $maintenanceSettings.Restore.Contains('StartupDelayMinutes')) {
            $maintenanceSettings.Restore.StartupDelayMinutes
        } else {
            0
        }
    }
    if ($global:schedulerSettings.Contains('BAZASync') -and $global:schedulerSettings.BAZASync -is [hashtable]) {
        # BAZASync — суто SFTP-синхронізація BAZA_APP/BAZA_WWW.
        # Enabled береться з канонічного $bazaSyncEffective (APP_SFTP OR
        # WWW_SFTP).
        $global:schedulerSettings.BAZASync.Enabled = $bazaSyncEffective.ScheduledSftpSyncRequired
        $global:schedulerSettings.BAZASync.ScriptPath = Join-Path $runtimeRoot "BRAVO_ARCHIV.ps1"
    }
    # Захисне читання (Contains, а не пряме .RestoreVerify): той самий
    # клас ризику, що й Recovery/BootRestoreMode вище — legacy site-
    # config (до появи RestoreVerify-завдання) може взагалі не мати цього
    # вузла в schedulerSettings, а canonical backfill (BRAVO_CONFIG_LOADER
    # .ps1, Assert-BravoLoadedConfiguration) спрацьовує лише ПІСЛЯ
    # повного завантаження, тобто вже після цього виклику.
    if ($global:schedulerSettings.Contains('RestoreVerify') -and
        $global:schedulerSettings.RestoreVerify -is [hashtable]) {
        $global:schedulerSettings.RestoreVerify.ScriptPath = Join-Path $runtimeRoot "BRAVO_RESTORE_TEST.ps1"
    }

    # Пороги перевірки відновлюваності — уже повністю raw-параметр.
    $global:restoreVerifySettings = $restoreVerifySettings
}

function Get-BRAVOCanonicalDiscoverySettings {
    # Канонічна, фіксована (НЕ raw-configurable) структура discoverySettings
    # — той самий літерал, який BRAVO.config визначає інлайн (навмисно
    # ПІСЛЯ фази local-overrides, щоб спроба перевизначити 'discoverySettings.*'
    # через BRAVO.local.config провалювалась fail-closed, а не мовчки
    # ігнорувалась). Винесено сюди як ОДНЕ джерело, яким користуються ОБИДВА
    # шляхи (BRAVO.config present і absent) — без цього no-config-шлях мав би
    # тримати другу незалежну копію цього самого літералу.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        BravoIniPath = $null
        BravoRoot = $null
        WebRoot = $null
        Sources = @{
            MODEL = $null
            BLOG = $null
            BRAVOEXCH = $null
            BAZA_APP = $null
            BAZA_WWW = $null
            BACKUP_ROOT = $null
        }
    }
}
