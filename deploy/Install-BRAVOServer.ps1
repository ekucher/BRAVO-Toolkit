[CmdletBinding()]
param(
    [string]$RuntimeRoot = 'C:\Program Files\BRAVO-Toolkit',
    [string]$Tag = 'v5.2.4',
    [string]$ZipPath,
    [string]$StagingRoot = 'C:\Temp\BRAVO_INSTALL',
    [switch]$SeedLocalConfig,
    # Профіль напрямків резервного копіювання для НОВОГО BRAVO.local.config
    # (лише разом із -SeedLocalConfig; наявний файл не змінюється). Явний
    # профіль не ігнорується мовчки: якщо його не можна застосувати або
    # підтвердити за ефективними значеннями, інсталяція зупиняється ДО
    # копіювання в каталог інсталяції (#434):
    #   Cloud         — хмара SFTP, Samba вимкнено (дефолт);
    #   CloudAndSamba — хмара SFTP і копія на NAS/SMB;
    #   SambaOnly     — лише NAS/SMB, SFTP вимкнено;
    #   LocalOnly     — жодної копії за межі сервера.
    # Відображення профіль -> прапорці: Get-BRAVOConfiguratorBackupDestinationProfile.
    [ValidateSet('Cloud', 'CloudAndSamba', 'SambaOnly', 'LocalOnly')]
    [string]$BackupDestination = 'Cloud',
    [switch]$AllowPrereleaseChannel,
    [switch]$SkipSelfTest,
    [switch]$Force,
    [switch]$NoElevation,
    [switch]$NoPause
)

# Проміжний помічник ЧИСТОЇ інсталяції stable-релізу BRAVO-Toolkit на ОДИН
# сервер: завантажити артефакт релізу, звірити SHA-256, розгорнути в порожній
# каталог і довести цілісність комплекту.
#
# Це НЕ P3.2a (ROADMAP.md) і не оновлення. Для переходу 5.2.3 -> 5.2.4
# використовуйте Update-BRAVOServer.ps1; для переходу з лінії 4.2 —
# docs\BRAVO_42_TO_524_MIGRATION_20260913.md (цей скрипт виконує її розділ 6).
#
# ЩО ВІН НАВМИСНО НЕ РОБИТЬ:
#   * не створює і не читає credentials — це інтерактивний BRAVO_SETUP.ps1;
#   * не реєструє завдання Планувальника;
#   * не редагує BRAVO.config — site-відмінності належать BRAVO.local.config;
#   * не видаляє нічого поза власним staging-каталогом;
#   * не видаляє розгорнуті файли після провалу гейта: провалена перевірка
#     цілісності — це доказ, а не сміття.

$ErrorActionPreference = 'Stop'

# Операторський інструмент: помилка має читатися одним рядком, а не
# стек-дампом PowerShell. Код завершення 1 = скрипт зупинився сам.
#
# Це catch, а не trap: тіло скрипта обгорнуте try/finally заради паузи й
# відновлення кодування, а trap спрацював би ПІСЛЯ finally — оператор
# побачив би запит "Натисніть Enter" раніше за причину зупинки.
$script:Failed = $false
Set-StrictMode -Version 2.0

# --- Кирилиця в консолі ------------------------------------------------------
# Windows PowerShell 5.1 на серверах з російською локаллю тримає консоль у
# OEM-866, тому UTF-8-вивід дочірніх процесів BRAVO (BRAVO_DRY_RUN,
# BRAVO_TASKS_INSTALL, BRAVO_CREDENTIALS_SETUP) читається як
# "‹®Ј ¤®Ї®¬?¦­®Ј®". Перемикаємо консоль на UTF-8 на час роботи скрипта;
# дочірні процеси успадковують кодову сторінку. Початковий стан
# повертається у finally наприкінці файлу.

$script:PreviousConsoleEncoding = $null
$script:PreviousOutputEncoding = $null
try {
    $script:PreviousConsoleEncoding = [Console]::OutputEncoding
    $script:PreviousOutputEncoding = $OutputEncoding
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8NoBom
    $global:OutputEncoding = $utf8NoBom
} catch {
    # Вивід перенаправлено або консолі немає — не критично, працюємо далі.
    Write-Host ('Не вдалося перемкнути консоль на UTF-8: ' + $_.Exception.Message) -ForegroundColor Yellow
}

function Wait-BRAVODeployCompletion {
    # Той самий контракт, що Wait-BRAVOSetupCompletion у BRAVO_SETUP.ps1.
    # Пауза безумовна на КОЖНОМУ шляху завершення — успіх, зупинка, провал
    # гейта, UAC-перезапуск: вікно, відкрите подвійним кліком або UAC-ом,
    # інакше закривається миттєво разом із результатом. Вимикається лише
    # явним -NoPause або відсутністю інтерактивної консолі.
    if ($NoPause -or -not [Environment]::UserInteractive) {
        return
    }
    try {
        if ([Console]::IsInputRedirected) { return }
        [void](Read-Host 'Натисніть Enter для завершення')
    } catch {
        # Фоновий або перенаправлений запуск не має падати через брак консолі.
    }
}

function Restore-BRAVOConsoleEncoding {
    try {
        if ($null -ne $script:PreviousConsoleEncoding) {
            [Console]::OutputEncoding = $script:PreviousConsoleEncoding
        }
        if ($null -ne $script:PreviousOutputEncoding) {
            $global:OutputEncoding = $script:PreviousOutputEncoding
        }
    } catch {
        # Відновлення кодування ніколи не має маскувати результат роботи.
    }
}

function Write-Step { param([string]$T) Write-Host ''; Write-Host ('=== ' + $T) -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host ('  [OK]    ' + $T) -ForegroundColor Green }
function Write-Bad  { param([string]$T) Write-Host ('  [FAIL]  ' + $T) -ForegroundColor Red }
function Write-Note { param([string]$T) Write-Host ('  [..]    ' + $T) }
function Write-Warn2{ param([string]$T) Write-Host ('  [УВАГА] ' + $T) -ForegroundColor Yellow }

# Можливості комплекту, без яких профіль напрямків (#434) не можна ні
# застосувати, ні перевірити: файли модулів і визначення потрібних функцій.
# Перевірка БЕЗ імпорту й виконання коду комплекту: файли лише розбираються
# парсером PowerShell (AST). Знімок developer має файли BRAVO.Configurator,
# але не має цих функцій, тож одного Test-Path недостатньо (P3-1). Повертає
# перелік відсутнього; порожній перелік = комплект підтримує профіль. Одна
# перевірка і для явного профілю в кроці 1 (приватна копія комплекту), і для вибору між
# канонічним seed і копією прикладу в кроці 4 (розгорнутий каталог).
# Перелік модулів і функцій — один (Get-BRAVOInstallBackupDestinationRequiredFunctions):
# той самий, за яким Import-BRAVOInstallBackupDestinationModules для явного
# профілю звіряє ЕКСПОРТ після імпорту.
function Get-BRAVOInstallBackupDestinationRequiredFunctions {
    return [ordered]@{
        'modules\BRAVO.Configurator\BRAVO.Configurator.Effective.psm1'   = @()
        'modules\BRAVO.Configurator\BRAVO.Configurator.Persistence.psm1' = @('Get-BRAVOConfiguratorProductionOverrideState', 'New-BRAVOConfiguratorSeedLocalConfig')
        'modules\BRAVO.Configurator\BRAVO.Configurator.Presets.psm1'     = @('Get-BRAVOConfiguratorBackupDestinationProfile', 'Test-BRAVOConfiguratorBackupDestinationEffective')
        'modules\BRAVO.Configuration\BRAVO.Configuration.psd1'           = @()
        'modules\BRAVO.Configuration\BRAVO.Configuration.psm1'           = @('Get-BRAVODefaultConfiguration', 'Resolve-BRAVORawConfiguration')
        'modules\BRAVO.Discovery\BRAVO.Discovery.psd1'                   = @()
        'modules\BRAVO.Discovery\BRAVO.Discovery.psm1'                   = @('Get-BRAVOEffectiveStorageConfiguration', 'Get-BRAVOEffectiveSynchronizationConfiguration')
    }
}

function Get-BRAVOInstallBackupDestinationMissingCapabilities {
    param([Parameter(Mandatory = $true)][string]$ModuleRoot)
    $requiredModules = Get-BRAVOInstallBackupDestinationRequiredFunctions
    $missing = @()
    foreach ($relativePath in @($requiredModules.Keys)) {
        $modulePath = Join-Path $ModuleRoot $relativePath
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            $missing += $relativePath
            continue
        }
        $requiredFunctions = @($requiredModules[$relativePath])
        if ($requiredFunctions.Count -eq 0) { continue }
        $parseTokens = $null
        $parseErrors = $null
        $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$parseTokens, [ref]$parseErrors)
        if (@($parseErrors).Count -gt 0) {
            $missing += ($relativePath + ' (не розібрано)')
            continue
        }
        $definedFunctions = @($moduleAst.FindAll({
            param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | ForEach-Object { $_.Name })
        foreach ($functionName in $requiredFunctions) {
            if ($definedFunctions -notcontains $functionName) {
                $missing += ($relativePath + ': ' + $functionName)
            }
        }
    }
    return @($missing)
}

# Цілісність комплекту за RUNTIME_MANIFEST.json ДО першого імпорту його коду
# (#434). SHA-256 архіву не захищає від локального архіву зі «своїм» .sha256
# поруч чи від підміни розпакованих файлів, а крок 5 (guard) запускається вже
# після кроку 4. Тому перед КОЖНИМ Import-Module коду комплекту — над приватною
# копією в кроці 1 і над розгорнутим каталогом у кроці 4 — виконується канонічна
# перевірка Test-BRAVORuntimeManifestIntegrity з BRAVO_RUNTIME_GUARD.ps1 того
# самого комплекту, той самий код, що крок 5. Порядок довіри guard-а:
# pre-trust guard -> цілісність -> лише потім Import-Module. Guard
# самодостатній (лише .NET), dot-source лише оголошує функції в дочірній
# області; його власна межа довіри та сама, що в кроці 5 («ЧЕСНА МЕЖА» у
# guard-і). Власного переліку хешів інсталятор не має. Режим — завжди Enforce.
function Assert-BRAVOInstallBundleIntegrity {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [switch]$BeforeDeploy
    )
    $deployState = $(if ($BeforeDeploy) { ' Нічого не розгорнуто.' } else { ' Розгорнуті файли НЕ видалено — це доказ.' })
    $guardPath = Join-Path $BundleRoot 'BRAVO_RUNTIME_GUARD.ps1'
    $integrity = @()
    $integrityError = $null
    if (-not (Test-Path -LiteralPath $guardPath -PathType Leaf)) {
        $integrityError = 'немає BRAVO_RUNTIME_GUARD.ps1 (' + $guardPath + ')'
    } else {
        try {
            $integrity = @(& {
                param([string]$GuardScriptPath, [string]$IntegrityRoot)
                . $GuardScriptPath
                Test-BRAVORuntimeManifestIntegrity -RuntimeRoot $IntegrityRoot `
                    -ManifestPath (Join-Path $IntegrityRoot 'RUNTIME_MANIFEST.json') -Mode Enforce
            } $guardPath $BundleRoot)
        } catch {
            $integrityError = 'перевірка не виконалась: ' + $_.Exception.Message
        }
        if ($null -eq $integrityError -and ($integrity.Count -ne 1 -or $null -eq $integrity[0] -or
            $null -eq $integrity[0].PSObject.Properties['IsValid'])) {
            $integrityError = 'перевірка не повернула результату'
        } elseif ($null -eq $integrityError -and -not [bool]$integrity[0].IsValid) {
            $integrityError = [string]$integrity[0].Message
        }
    }
    if ($null -ne $integrityError) {
        throw ('Цілісність комплекту ' + $BundleRoot + ' за RUNTIME_MANIFEST.json не підтверджено: ' + $integrityError +
            ' Код комплекту не імпортовано.' + $deployState + ' Візьміть комплект заново (-Tag або -ZipPath ' +
            'з .sha256 і release-manifest.json релізу) і повторіть запуск; не «лагодьте» це правкою маніфеста.')
    }
    Write-Ok ('цілісність комплекту за RUNTIME_MANIFEST.json підтверджена (перевірено файлів: ' + $integrity[0].CheckedCount + ')')
}

# Явний профіль (#434): рішення за ЕФЕКТИВНИМИ значеннями, а не за текстом
# BRAVO.local.config. Читання — канонічний reader
# (Get-BRAVOConfiguratorProductionOverrideState) і злиття
# Resolve-BRAVORawConfiguration (дефолти < BRAVO.local.config); ефективні
# напрямки — Get-BRAVOEffectiveStorageConfiguration (і BAZA —
# Get-BRAVOEffectiveSynchronizationConfiguration) у місці виклику;
# порівняння з профілем — канонічне Test-BRAVOConfiguratorBackupDestinationEffective.
# Файл не змінюється й не «виправляється» автоматично. $ModuleRoot — комплект,
# чиї модулі вже пройшли SHA-256, провенанс, гейт каналу й
# Assert-BRAVOInstallBundleIntegrity (приватна копія в кроці 1 або розгорнутий каталог
# у кроці 4). -BeforeDeploy — виклик у кроці 1, коли
# в каталог інсталяції ще нічого не скопійовано (так і пише причина).
# Імпорт модулів перевірки профілю (#434) і звірка ЕКСПОРТУ (Codex P2,
# раунд 3): AST-перевірка можливостей бачить визначення, але функцію, яку
# модуль не експортує (Export-ModuleMember/FunctionsToExport), викликати не
# можна. Тому після імпорту кожна функція з
# Get-BRAVOInstallBackupDestinationRequiredFunctions мусить бути в
# ExportedFunctions саме того екземпляра модуля, який щойно повернув
# Import-Module -PassThru, чий Path лежить під $ModuleRoot, і Get-Command має
# вказувати на цей екземпляр (Codex P2, раунд 4: однойменний модуль з іншого
# шляху, уже завантажений у сесію, не підміняє перевірку); інакше — відмова.
# Лише для явного профілю (крок 1 над приватною копією, крок 4 над
# розгорнутим каталогом), де код комплекту однаково імпортується; неявний
# шлях не імпортує нічого зайвого.
function Import-BRAVOInstallBackupDestinationModules {
    param(
        [Parameter(Mandatory = $true)][string]$ModuleRoot,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$BeforeDeploy
    )
    $deployState = $(if ($BeforeDeploy) { ' Нічого не розгорнуто.' } else { '' })
    # Ключ — ім'я модуля (для .psd1 PassThru повертає кореневий модуль з тим
    # самим ім'ям і Path = його .psm1), значення — PSModuleInfo щойно
    # імпортованого екземпляра.
    $importedModules = @{}
    $importPaths = @(
        'modules\BRAVO.Configurator\BRAVO.Configurator.Persistence.psm1',
        'modules\BRAVO.Configurator\BRAVO.Configurator.Presets.psm1',
        'modules\BRAVO.Configuration\BRAVO.Configuration.psd1',
        'modules\BRAVO.Discovery\BRAVO.Discovery.psd1'
    )
    foreach ($importPath in $importPaths) {
        foreach ($importedModule in @(Import-Module -Name (Join-Path $ModuleRoot $importPath) -Force -PassThru -ErrorAction Stop)) {
            if ($null -ne $importedModule -and -not $importedModules.ContainsKey([string]$importedModule.Name)) {
                $importedModules[[string]$importedModule.Name] = $importedModule
            }
        }
    }
    $moduleRootPrefix = [System.IO.Path]::GetFullPath($ModuleRoot).Replace('/', '\').TrimEnd('\') + '\'
    $requiredModules = Get-BRAVOInstallBackupDestinationRequiredFunctions
    $notExported = @()
    foreach ($relativePath in @($requiredModules.Keys)) {
        $moduleName = [System.IO.Path]::GetFileNameWithoutExtension(@($relativePath -split '\\')[-1])
        $moduleInfo = $importedModules[$moduleName]
        $modulePath = ''
        if ($null -ne $moduleInfo -and -not [string]::IsNullOrEmpty([string]$moduleInfo.Path)) {
            $modulePath = [System.IO.Path]::GetFullPath([string]$moduleInfo.Path).Replace('/', '\')
        }
        $fromModuleRoot = ($modulePath.Length -gt 0 -and
            $modulePath.StartsWith($moduleRootPrefix, [System.StringComparison]::OrdinalIgnoreCase))
        foreach ($functionName in @($requiredModules[$relativePath])) {
            $exported = ($fromModuleRoot -and $moduleInfo.ExportedFunctions.ContainsKey($functionName))
            if ($exported) {
                $command = @(Get-Command -Name $functionName -CommandType Function -ErrorAction SilentlyContinue)
                $exported = ($command.Count -eq 1 -and $null -ne $command[0].Module -and
                    [string]$command[0].Module.Path -eq [string]$moduleInfo.Path)
            }
            if (-not $exported) {
                $notExported += ($moduleName + ': ' + $functionName)
            }
        }
    }
    if ($notExported.Count -gt 0) {
        throw ('Комплект не підтримує -BackupDestination ' + $Destination + ': модулі не експортують потрібних функцій (' +
            ($notExported -join ', ') + ').' + $deployState + ' Вкажіть -Tag або -ZipPath комплекту, що містить ' +
            'BRAVO.Configurator, або запустіть без -BackupDestination (напрямки потім задає BRAVO_CONFIGURATOR.ps1).')
    }
}

function Get-BRAVOInstallSiteComponentSettings {
    param(
        [Parameter(Mandatory = $true)][string]$ModuleRoot,
        [Parameter(Mandatory = $true)][string]$ConfigDirectory,
        [Parameter(Mandatory = $true)][string]$Destination,
        # Шлях для повідомлення оператору, коли читається знімок файла
        # (крок 1), а не сам файл у каталозі інсталяції.
        [string]$SiteConfigPath = '',
        [switch]$BeforeDeploy
    )
    $deployState = $(if ($BeforeDeploy) { ' Нічого не розгорнуто.' } else { '' })
    if ([string]::IsNullOrEmpty($SiteConfigPath)) { $SiteConfigPath = Join-Path $ConfigDirectory 'BRAVO.local.config' }
    Import-BRAVOInstallBackupDestinationModules -ModuleRoot $ModuleRoot -Destination $Destination -BeforeDeploy:$BeforeDeploy
    try {
        $overrideState = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $ModuleRoot -ProductionConfigDirectory $ConfigDirectory
        $mergedConfiguration = Resolve-BRAVORawConfiguration -DefaultConfiguration (Get-BRAVODefaultConfiguration) `
            -PrimaryOverrides $null -LocalOverrides $overrideState.Overrides
    } catch {
        throw ('-BackupDestination ' + $Destination + ' не перевірено: ' + $SiteConfigPath +
            ' (BRAVO.local.config) не вдалося прочитати чи розібрати: ' + $_.Exception.Message +
            ' Файл не змінено.' + $deployState + ' Виправте BRAVO.local.config (або перевірте його в ' +
            'BRAVO_CONFIGURATOR.ps1) і повторіть запуск.')
    }
    return $mergedConfiguration['componentSettings']
}

# Знімок BRAVO.local.config для явного профілю (#434): байти, прочитані ОДИН
# раз, і відбиток — SHA-256 саме цих байтів ('' за відсутності файла). Крок 1
# розбирає канонічним reader-ом копію цих байтів у приватному каталозі (Codex
# P2, раунд 3: перевірене й відбите — ті самі байти), а перед першим записом
# у каталог інсталяції відбиток живого файла звіряється з цим: файл, змінений
# після перевірки, не повинен дати відмову вже після копіювання.
function Get-BRAVOInstallSiteConfigSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Bytes = $null; Fingerprint = '' }
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fingerprint = ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
    return [pscustomobject]@{ Exists = $true; Bytes = $bytes; Fingerprint = $fingerprint }
}

# Основа приватного каталогу перевірки кроку 1 (#434, Codex P1, раунд 3):
# $env:SystemRoot\Temp, а не [IO.Path]::GetTempPath(). %TEMP% елевованого
# адміністратора — профіль того самого користувача, і процес без елевації має
# там FILE_DELETE_CHILD: міг би перейменувати захищений каталог і підкласти
# на його місце свій. У $env:SystemRoot\Temp звичайні користувачі такого права
# на батьківський каталог не мають. Немає каталогу — відмова (fail closed).
function Get-BRAVOInstallPrivateDirectoryBase {
    $systemRoot = $env:SystemRoot
    $privateBase = $(if ([string]::IsNullOrWhiteSpace($systemRoot)) { '' } else { Join-Path $systemRoot 'Temp' })
    if ([string]::IsNullOrEmpty($privateBase) -or -not (Test-Path -LiteralPath $privateBase -PathType Container)) {
        throw ('Немає каталогу для приватної перевірки -BackupDestination: ' + $(if ([string]::IsNullOrEmpty($privateBase)) { '$env:SystemRoot не задано' } else { $privateBase }) +
            '. Нічого не розгорнуто. Перевірте $env:SystemRoot\Temp на сервері й повторіть запуск.')
    }
    return $privateBase
}

# Приватний каталог перевірки кроку 1 (#434, Codex P1, раунд 3). Без явного
# DACL він успадкував би права батьківського каталогу, і процес того самого
# користувача без елевації міг би підмінити .psm1 між перевіркою цілісності
# й Import-Module. Тому каталог створюється ОДРАЗУ з явним захищеним DACL
# (як New-BRAVOWinSCPTemporaryScriptPath у BRAVO.ArchiveRuntime: не
# «створити, потім Set-Acl» — у такому вікні відкритий дескриптор пережив би
# зміну прав): успадкування вимкнено, FullControl лише BUILTIN\Administrators
# (S-1-5-32-544) і NT AUTHORITY\SYSTEM (S-1-5-18), власник — Administrators.
# Результат перечитується Get-Acl; будь-яка розбіжність, наявний чи непорожній
# каталог — відмова (fail closed). Можливо лише в елевованому процесі.
function New-BRAVOInstallPrivateDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (Test-Path -LiteralPath $Path) { throw 'каталог уже існує.' }
        $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $allowedSids = @($administratorsSid.Value, $systemSid.Value)
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetOwner($administratorsSid)
        $security.SetAccessRuleProtection($true, $false)
        foreach ($allowedSid in @($administratorsSid, $systemSid)) {
            $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $allowedSid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)))
        }
        # .NET Framework (Windows PowerShell 5.1): Directory.CreateDirectory(path, DirectorySecurity);
        # .NET (PowerShell 7): той самий виклик — FileSystemAclExtensions.CreateDirectory.
        $createWithSecurity = [System.IO.Directory].GetMethod('CreateDirectory',
            [Type[]]@([string], [System.Security.AccessControl.DirectorySecurity]))
        if ($null -ne $createWithSecurity) {
            [void][System.IO.Directory]::CreateDirectory($Path, $security)
        } else {
            [void][System.IO.FileSystemAclExtensions]::CreateDirectory($security, $Path)
        }
        $actual = Get-Acl -LiteralPath $Path
        $problems = @()
        if (-not $actual.AreAccessRulesProtected) { $problems += 'успадкування прав не вимкнено' }
        $ownerSid = [string]$actual.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($ownerSid -ne $administratorsSid.Value) { $problems += ('власник ' + $ownerSid + ', а не BUILTIN\Administrators') }
        $rules = @($actual.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        foreach ($rule in $rules) {
            $ruleSid = [string]$rule.IdentityReference.Value
            if ($rule.IsInherited -or $allowedSids -notcontains $ruleSid -or
                $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
                ($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne [System.Security.AccessControl.FileSystemRights]::FullControl) {
                $problems += ('зайве правило ' + $ruleSid + ' ' + [string]$rule.AccessControlType + ' ' + [string]$rule.FileSystemRights)
            }
        }
        foreach ($allowedSidValue in $allowedSids) {
            if (@($rules | Where-Object { [string]$_.IdentityReference.Value -eq $allowedSidValue }).Count -eq 0) {
                $problems += ('немає правила для ' + $allowedSidValue)
            }
        }
        if (@(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) { $problems += 'каталог не порожній' }
        if ($problems.Count -gt 0) { throw ('DACL не той: ' + ($problems -join '; ') + '.') }
    } catch {
        throw ('Приватний каталог перевірки -BackupDestination ' + $Path + ' не вдалося створити із захищеними правами ' +
            '(без успадкування; лише BUILTIN\Administrators і NT AUTHORITY\SYSTEM): ' + $_.Exception.Message +
            ' Нічого не розгорнуто. Запустіть інсталятор у елевованій консолі адміністратора й повторіть запуск.')
    }
}

function Assert-BRAVOInstallBackupDestinationEffective {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][AllowNull()]$EffectiveStorage,
        [Parameter(Mandatory = $true)][string]$SiteConfigPath,
        # Результат канонічного Get-BRAVOEffectiveSynchronizationConfiguration
        # над тими самими злитими значеннями (BAZA_*_LOCAL для SambaOnly/LocalOnly).
        [AllowNull()]$EffectiveSynchronization = $null,
        [switch]$BeforeDeploy
    )
    $deployState = $(if ($BeforeDeploy) { ' Нічого не розгорнуто.' } else { '' })
    $destinationCheck = Test-BRAVOConfiguratorBackupDestinationEffective -Destination $Destination -EffectiveStorage $EffectiveStorage `
        -EffectiveSynchronization $EffectiveSynchronization
    if (-not $destinationCheck.Compliant) {
        throw ('-BackupDestination ' + $Destination + ' не в силі: з ' + $SiteConfigPath +
            ' (BRAVO.local.config) ефективно суперечать ' + (@($destinationCheck.ConflictingChannels) -join ' і ') + '. ' +
            (@($destinationCheck.Reasons) -join ' ') + ' BRAVO.local.config не змінено.' + $deployState + ' ' +
            'Узгодьте напрямки в ньому з профілем ' + $Destination + ' (вручну або профілем у BRAVO_CONFIGURATOR.ps1) ' +
            'і повторіть запуск, або запустіть без -BackupDestination.')
    }
    Write-Ok ('профіль напрямків ' + $Destination + ' у силі: ефективні SFTP і SMB відповідають ' + $SiteConfigPath)
}

try {
$targetVersion = $Tag.TrimStart('v')

# Політика "який артефакт можна розгортати" спільна з Update-BRAVOServer.ps1 і
# живе в одному екземплярі. Відсутність файлу зупиняє розкатку явно: тихо
# продовжити означало б розгортати БЕЗ гейта.
$script:ReleaseGatePath = Join-Path $PSScriptRoot 'BRAVO.Deploy.ReleaseGate.ps1'
if (-not (Test-Path -LiteralPath $script:ReleaseGatePath -PathType Leaf)) {
    throw ('Поруч зі скриптом немає BRAVO.Deploy.ReleaseGate.ps1 (' + $script:ReleaseGatePath +
        '). Це файл політики гейта релізу — скопіюйте весь каталог deploy\, а не один скрипт.')
}
. $script:ReleaseGatePath

# --- 0. Передумови ----------------------------------------------------------

Write-Step '0. Передумови'

# Явний -BackupDestination (#434) — рішення ДО першого запису чи
# завантаження. Без -SeedLocalConfig і без наявного BRAVO.local.config діють
# дефолти комплекту (SFTP і SMB увімкнені, копія на NAS вимкнена), а вони
# не збігаються з жодним профілем: явний профіль не можна ні застосувати,
# ні підтвердити, тож продовжувати з кодом 0 означало б мовчки працювати з
# іншими напрямками (для LocalOnly — випустити дані за межі сервера).
# Наявний файл перевіряється за ефективними значеннями в кроці 1, до
# копіювання в каталог інсталяції. Перевірка стоїть до UAC-перезапуску:
# причину видно в консолі оператора.
if ($PSBoundParameters.ContainsKey('BackupDestination') -and
    -not $SeedLocalConfig -and -not (Test-Path -LiteralPath (Join-Path $RuntimeRoot 'BRAVO.local.config') -PathType Leaf)) {
    throw ('-BackupDestination ' + $BackupDestination + ' не застосовано: без -SeedLocalConfig новий BRAVO.local.config ' +
        'не створюється, а дефолти комплекту (SFTP і SMB увімкнені, копія на NAS вимкнена) не відповідають ' +
        'жодному профілю напрямків. Повторіть запуск із -SeedLocalConfig -BackupDestination ' + $BackupDestination +
        ' або покладіть у ' + $RuntimeRoot + ' BRAVO.local.config, ефективні напрямки якого відповідають ' +
        'профілю ' + $BackupDestination + ' (для LocalOnly: componentSettings.SFTP.Enabled = $false і ' +
        'componentSettings.SMB.Enabled = $false; для LocalOnly і SambaOnly ще й ' +
        'componentSettings.Synchronization.BAZA_APP_LOCAL = $true і componentSettings.Synchronization.BAZA_WWW_LOCAL = $true). ' +
        'Нічого не завантажено й не записано.')
}

$isElevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# Права адміністратора обов'язкові: скрипт пише у %ProgramFiles%, читає
# Планувальник і запускає BRAVO_SETUP. Замість відмови пропонуємо UAC —
# той самий контракт, що BRAVO_SETUP.ps1 (-NoElevation вимикає підняття й
# передається у перезапущений процес, щоб не було циклу).
#
# ExecutionPolicy тут НЕ послаблюється: перезапуск іде як
# "-NoLogo -NoProfile -File", без -ExecutionPolicy Bypass.

if (-not $isElevated) {
    if ($NoElevation -or -not [Environment]::UserInteractive) {
        throw ('Потрібні права адміністратора. Запустіть PowerShell від імені ' +
            'адміністратора або приберіть -NoElevation, щоб скрипт сам запросив UAC.')
    }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Не вдалося визначити власний шлях для перезапуску з правами адміністратора.'
    }

    Write-Note 'права не підняті — запит UAC і перезапуск в елевованій консолі'

    $argumentParts = New-Object System.Collections.Generic.List[string]
    foreach ($fixed in @('-NoLogo', '-NoProfile', '-File', ('"' + $PSCommandPath + '"'))) {
        [void]$argumentParts.Add($fixed)
    }
    if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        [void]$argumentParts.Add('-RuntimeRoot'); [void]$argumentParts.Add('"' + $RuntimeRoot + '"')
    }
    if (-not [string]::IsNullOrWhiteSpace($Tag)) {
        [void]$argumentParts.Add('-Tag'); [void]$argumentParts.Add('"' + $Tag + '"')
    }
    if (-not [string]::IsNullOrWhiteSpace($ZipPath)) {
        [void]$argumentParts.Add('-ZipPath'); [void]$argumentParts.Add('"' + $ZipPath + '"')
    }
    if (-not [string]::IsNullOrWhiteSpace($StagingRoot)) {
        [void]$argumentParts.Add('-StagingRoot'); [void]$argumentParts.Add('"' + $StagingRoot + '"')
    }
    if ($SeedLocalConfig) { [void]$argumentParts.Add('-SeedLocalConfig') }
    if ($PSBoundParameters.ContainsKey('BackupDestination')) {
        [void]$argumentParts.Add('-BackupDestination'); [void]$argumentParts.Add($BackupDestination)
    }
    if ($AllowPrereleaseChannel) { [void]$argumentParts.Add('-AllowPrereleaseChannel') }
    if ($SkipSelfTest) { [void]$argumentParts.Add('-SkipSelfTest') }
    if ($Force) { [void]$argumentParts.Add('-Force') }
    if ($NoPause) { [void]$argumentParts.Add('-NoPause') }
    [void]$argumentParts.Add('-NoElevation')

    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $elevated = Start-Process -FilePath $powerShellPath `
        -ArgumentList ($argumentParts -join ' ') `
        -Verb RunAs -Wait -PassThru -WindowStyle Normal

    # Елевований прогін іде в ОКРЕМОМУ вікні, тому батьківський процес мусить
    # сказати, чим він скінчився. Без цього оператор бачив лише "запит UAC" і
    # одразу "Натисніть Enter" — без жодної ознаки, спрацювало щось чи ні.
    if ($null -eq $elevated) {
        throw 'UAC-перезапуск не повернув об''єкт процесу — підняття прав не відбулося.'
    }
    $elevatedCode = [int]$elevated.ExitCode
    Write-Host ''
    if ($elevatedCode -eq 0) {
        Write-Ok 'елевований прогін завершився успішно (код 0)'
    } else {
        Write-Bad ('елевований прогін завершився кодом ' + $elevatedCode)
        Write-Host '  Вивід ішов в ОКРЕМЕ вікно. Якщо воно закрилося раніше, ніж ви встигли' -ForegroundColor Yellow
        Write-Host '  прочитати, запустіть скрипт з консолі, відкритої через "Запуск від імені' -ForegroundColor Yellow
        Write-Host '  адміністратора" — тоді весь вивід лишиться в одному вікні.' -ForegroundColor Yellow
    }
    exit $elevatedCode
}
Write-Ok 'запущено з піднятими правами'

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw ('Потрібен Windows PowerShell 5.1 (знайдено ' + $PSVersionTable.PSVersion.ToString() + ').')
}
Write-Ok ('PowerShell ' + $PSVersionTable.PSVersion.ToString())

# Порожній цільовий каталог — умова чистої інсталяції. Наявний комплект
# оновлюється іншим інструментом, і мовчки копіювати поверх нього не можна:
# у чистої інсталяції інший контракт (нові LOGS, новий стан, новий config).
$targetExists = Test-Path -LiteralPath $RuntimeRoot
if ($targetExists) {
    if (Test-Path -LiteralPath (Join-Path $RuntimeRoot 'VERSION.json') -PathType Leaf) {
        $existing = (Get-Content -LiteralPath (Join-Path $RuntimeRoot 'VERSION.json') -Raw -Encoding UTF8 |
            ConvertFrom-Json)
        throw ('У ' + $RuntimeRoot + ' уже встановлено BRAVO ' + $existing.packageVersion +
            '. Для оновлення використовуйте Update-BRAVOServer.ps1, для переходу з 4.2 — ' +
            'процедуру міграції (інсталяція в ІНШИЙ каталог).')
    }
    $content = @(Get-ChildItem -LiteralPath $RuntimeRoot -Force -ErrorAction SilentlyContinue)
    if ($content.Count -gt 0 -and -not $Force) {
        throw ('Каталог не порожній: ' + $RuntimeRoot + ' (' + $content.Count +
            ' об''єктів). Оберіть інший каталог або вкажіть -Force, якщо вміст справді сторонній.')
    }
    Write-Ok ('цільовий каталог існує і придатний: ' + $RuntimeRoot)
} else {
    Write-Note ('цільовий каталог буде створено: ' + $RuntimeRoot)
}

# SYSTEM виконуватиме ці файли, тому каталог не повинен бути доступним на
# запис звичайним користувачам (README §14). ACL-hardening виконує
# BRAVO_TASKS_INSTALL за schedulerSettings.RequireProtectedRuntime; тут лише
# попередження про очевидно невдалий вибір місця.
$programFiles = [Environment]::GetFolderPath('ProgramFiles')
if (-not $RuntimeRoot.StartsWith($programFiles, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Warn2 ('каталог поза ' + $programFiles + ': переконайтесь, що звичайні користувачі ' +
        'не мають права запису — комплект виконується від SYSTEM.')
}

# --- 1. Артефакт ------------------------------------------------------------

Write-Step ('1. Артефакт ' + $Tag)

if (-not (Test-Path -LiteralPath $StagingRoot)) {
    [void](New-Item -ItemType Directory -Path $StagingRoot -Force)
}
$downloadDir = Join-Path $StagingRoot 'download'

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    if (Test-Path -LiteralPath $downloadDir) { Remove-Item -LiteralPath $downloadDir -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $downloadDir -Force)
    # TLS 1.2 не є дефолтом на Windows Server 2016.
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $zipName = 'BRAVO-Toolkit-' + $targetVersion + '.zip'
    $base = 'https://github.com/ekucher/BRAVO-Toolkit/releases/download/' + $Tag + '/'
    $ZipPath = Join-Path $downloadDir $zipName
    Write-Note ('завантаження ' + $base + $zipName)
    Invoke-WebRequest -Uri ($base + $zipName) -OutFile $ZipPath -UseBasicParsing
    Invoke-WebRequest -Uri ($base + $zipName + '.sha256') -OutFile ($ZipPath + '.sha256') -UseBasicParsing
    # release-manifest.json — окремий ассет релізу, тобто джерело провенансу,
    # незалежне від самого архіву. Помилка завантаження не зупиняє розкатку:
    # релізи до появи маніфесту його не мають, а без нього лишаються внутрішні
    # інваріанти комплекту (їх перевіряє гейт нижче).
    try {
        Invoke-WebRequest -Uri ($base + 'release-manifest.json') `
            -OutFile (Join-Path $downloadDir 'release-manifest.json') -UseBasicParsing
    } catch {
        Write-Warn2 ('release-manifest.json не завантажено: ' + $_.Exception.Message)
    }
} else {
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        throw ('Архів не знайдено: ' + $ZipPath)
    }
    Write-Note ('локальний архів: ' + $ZipPath)
}

$shaFile = $ZipPath + '.sha256'
if (-not (Test-Path -LiteralPath $shaFile -PathType Leaf)) {
    throw ('Немає файлу контрольної суми: ' + $shaFile + ' — покладіть його поруч із архівом. ' +
        'Без нього походження комплекту не підтверджене, і розгортання не виконується.')
}
$expected = (((Get-Content -LiteralPath $shaFile -Raw).Trim()) -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expected -ne $actual) {
    throw ('SHA-256 не збігається. очікувано=' + $expected + ' фактично=' + $actual)
}
Write-Ok ('sha256 ' + $actual)

# Файл, завантажений з Інтернету, несе Zone.Identifier: без Unblock-File
# Expand-Archive і подальший запуск .ps1 можуть блокуватись.
try { Unblock-File -LiteralPath $ZipPath -ErrorAction Stop } catch { }

$staged = Join-Path $StagingRoot 'staged'
if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Recurse -Force }
Expand-Archive -LiteralPath $ZipPath -DestinationPath $staged -Force

$stagedVersionFile = Join-Path $staged 'VERSION.json'
if (-not (Test-Path -LiteralPath $stagedVersionFile -PathType Leaf)) {
    throw ('У розпакованому архіві немає VERSION.json: ' + $staged)
}
$stagedVersion = (Get-Content -LiteralPath $stagedVersionFile -Raw -Encoding UTF8 | ConvertFrom-Json)
if ([string]$stagedVersion.packageVersion -ne $targetVersion) {
    throw ('У комплекті версія ' + $stagedVersion.packageVersion + ', очікувалась ' + $targetVersion)
}
$stagedCommit = if ($null -ne $stagedVersion.PSObject.Properties['sourceCommit']) {
    [string]$stagedVersion.sourceCommit
} else { '(немає у VERSION.json)' }
Write-Ok ('розпаковано: ' + $stagedVersion.packageVersion + ' / ' + $stagedVersion.releaseChannel +
          ' (sourceCommit ' + $stagedCommit + ')')

# --- Гейт релізу ------------------------------------------------------------
# Доти тут було лише Write-Warn2: prerelease-комплект розгортався в установі
# без жодного свідомого рішення. Саме так сервер парку опинився
# в production на
# 5.2.0-rc.2 — версії, тега якої не існує.

# Конвенція одна: release-manifest.json лежить поруч з архівом — і коли його
# завантажив цей скрипт, і коли оператор приніс zip разом з ассетами релізу.
$releaseManifestPath = Join-Path (Split-Path -Parent $ZipPath) 'release-manifest.json'
$releaseManifest = $null
if (Test-Path -LiteralPath $releaseManifestPath -PathType Leaf) {
    try {
        $releaseManifest = (Get-Content -LiteralPath $releaseManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        throw ('release-manifest.json пошкоджений (' + $releaseManifestPath + '): ' + $_.Exception.Message +
            ' — провенанс не підтверджується, розгортання зупинено.')
    }
}

$provenance = Get-BRAVODeployProvenanceVerdict -VersionMetadata $stagedVersion `
    -ReleaseManifest $releaseManifest -ArtifactSha256 $actual -ExpectedTag $Tag
if (-not $provenance.IsValid) {
    throw $provenance.Message
}
if ($provenance.Severity -eq 'Warning') { Write-Warn2 $provenance.Message } else { Write-Ok $provenance.Message }

$channelDecision = Get-BRAVODeployReleaseChannelDecision -VersionMetadata $stagedVersion `
    -AllowPrereleaseChannel:$AllowPrereleaseChannel
if (-not $channelDecision.Allowed) {
    throw $channelDecision.Message
}
if ($channelDecision.OverrideUsed) { Write-Warn2 $channelDecision.Message } else { Write-Ok $channelDecision.Message }

foreach ($required in @('BRAVO_RUNTIME_GUARD.ps1', 'RUNTIME_MANIFEST.json', 'BRAVO_SETUP.ps1',
                        'BRAVO_CONFIG_LOADER.ps1', 'Tools\TOOLS_MANIFEST.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $staged $required) -PathType Leaf)) {
        throw ('У комплекті бракує обов''язкового файлу: ' + $required)
    }
}
# BRAVO.config (issue #216, Wave B, B4-2): з 5.3 більше НЕ входить у
# комплект і не є обов'язковим — production entrypoints тепер
# синтезують BuiltInOnly/BuiltIn+Local ефективну конфігурацію без
# нього (-DisallowLegacyPrimaryAutoDetect). Толерантність в обидва
# боки: старіші комплекти (до 5.3), де файл ще фізично лежить поруч
# з архівом, лишаються встановлюваними — просто без окремої
# обов'язкової перевірки цього файлу.
if (Test-Path -LiteralPath (Join-Path $staged 'BRAVO.config') -PathType Leaf) {
    Write-Note 'BRAVO.config присутній у комплекті (старший пакет до 5.3) — інсталятор його ігнорує, production entrypoints не читають його автоматично'
}
Write-Ok 'обов''язкові файли комплекту на місці'

# Явний профіль напрямків (#434): усе, що може його відхилити, перевіряється
# тут — після SHA-256, провенансу й гейта каналу, але ДО копіювання в каталог
# інсталяції. Тому відмова не лишає часткового runtime чи VERSION.json, і
# повторний запуск з тими самими аргументами після виправлення працює.
# Неявний профіль (без -BackupDestination) цих перевірок не має: комплекти
# без BRAVO.Configurator встановлюються, як раніше.
$existingSiteConfig = Join-Path $RuntimeRoot 'BRAVO.local.config'
$siteConfigCheckedFingerprint = $null
if ($PSBoundParameters.ContainsKey('BackupDestination')) {
    # Код комплекту для цієї перевірки не імпортується з $StagingRoot: той
    # каталог може бути створений заздалегідь і доступний на запис звичайному
    # користувачеві, тож файл, підмінений між перевіркою цілісності й
    # Import-Module, виконався б із піднятими правами (TOCTOU). Тому — свіжий
    # приватний каталог елевованого процесу ($env:SystemRoot\Temp,
    # Get-BRAVOInstallPrivateDirectoryBase; випадкова назва): туди копіюється архів, його SHA-256 звіряється з уже
    # перевіреним значенням, і комплект розпаковується заново. Можливості,
    # цілісність за RUNTIME_MANIFEST.json і імпорт — над ЦИМ самим коренем.
    # Каталог створюється одразу із захищеним DACL (New-BRAVOInstallPrivateDirectory),
    # до першого запису в нього; видаляється у finally.
    $verifiedBundleRoot = Join-Path (Get-BRAVOInstallPrivateDirectoryBase) ('BRAVO_INSTALL_VERIFY_' + [guid]::NewGuid().ToString('N'))
    try {
        New-BRAVOInstallPrivateDirectory -Path $verifiedBundleRoot
        $verifiedZipPath = Join-Path $verifiedBundleRoot (Split-Path -Leaf $ZipPath)
        Copy-Item -LiteralPath $ZipPath -Destination $verifiedZipPath
        if ((Get-FileHash -LiteralPath $verifiedZipPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $actual) {
            throw ('Архів ' + $ZipPath + ' змінився після перевірки SHA-256 (копія для перевірки -BackupDestination ' +
                'не збігається з ' + $actual + '). Нічого не розгорнуто. Перевірте, хто має право запису в каталог ' +
                'архіву, і повторіть запуск.')
        }
        $verifiedBundle = Join-Path $verifiedBundleRoot 'bundle'
        Expand-Archive -LiteralPath $verifiedZipPath -DestinationPath $verifiedBundle -Force
        $stagedMissingCapabilities = @(Get-BRAVOInstallBackupDestinationMissingCapabilities -ModuleRoot $verifiedBundle)
        if ($stagedMissingCapabilities.Count -gt 0) {
            throw ('Комплект ' + $targetVersion + ' не підтримує -BackupDestination ' + $BackupDestination +
                ': бракує модулів чи функцій BRAVO.Configurator/конфігурації (' + ($stagedMissingCapabilities -join ', ') +
                '). Нічого не розгорнуто. Вкажіть -Tag або -ZipPath комплекту, що містить BRAVO.Configurator, ' +
                'або запустіть без -BackupDestination (напрямки потім задає BRAVO_CONFIGURATOR.ps1).')
        }
        Write-Ok ('комплект підтримує -BackupDestination ' + $BackupDestination)
        # Цілісність за RUNTIME_MANIFEST.json — до першого імпорту коду
        # комплекту нижче і до копіювання (відмова не лишає часткового runtime).
        Assert-BRAVOInstallBundleIntegrity -BundleRoot $verifiedBundle -BeforeDeploy
        # BRAVO.local.config читається ОДИН раз: відбиток — з цих байтів,
        # канонічний reader розбирає їхню копію в приватному каталозі; крок 3
        # звіряє відбиток з живим файлом перед першим записом у каталог інсталяції.
        $siteConfigSnapshot = Get-BRAVOInstallSiteConfigSnapshot -Path $existingSiteConfig
        $siteConfigCheckedFingerprint = $siteConfigSnapshot.Fingerprint
        if ($siteConfigSnapshot.Exists) {
            $verifiedSiteConfigDirectory = Join-Path $verifiedBundleRoot 'site'
            [void](New-Item -ItemType Directory -Path $verifiedSiteConfigDirectory)
            [System.IO.File]::WriteAllBytes((Join-Path $verifiedSiteConfigDirectory 'BRAVO.local.config'), $siteConfigSnapshot.Bytes)
            $stagedSiteSettings = Get-BRAVOInstallSiteComponentSettings -ModuleRoot $verifiedBundle -ConfigDirectory $verifiedSiteConfigDirectory `
                -SiteConfigPath $existingSiteConfig -Destination $BackupDestination -BeforeDeploy
            $stagedSiteStorage = Get-BRAVOEffectiveStorageConfiguration -ComponentSettings $stagedSiteSettings
            $stagedSiteSynchronization = Get-BRAVOEffectiveSynchronizationConfiguration -Synchronization $stagedSiteSettings['Synchronization'] `
                -GlobalSftpEnabled ([bool]$stagedSiteStorage.SFTP.Enabled)
            Assert-BRAVOInstallBackupDestinationEffective -Destination $BackupDestination `
                -EffectiveStorage $stagedSiteStorage -EffectiveSynchronization $stagedSiteSynchronization `
                -SiteConfigPath $existingSiteConfig -BeforeDeploy
        } else {
            # Файла немає (буде -SeedLocalConfig): модулі, якими крок 4 його
            # засіє й перевірить, звіряються за експортом уже тут, до копіювання.
            Import-BRAVOInstallBackupDestinationModules -ModuleRoot $verifiedBundle -Destination $BackupDestination -BeforeDeploy
        }
    } finally {
        try {
            if (Test-Path -LiteralPath $verifiedBundleRoot) { Remove-Item -LiteralPath $verifiedBundleRoot -Recurse -Force -ErrorAction Stop }
        } catch {
            Write-Warn2 ('тимчасовий каталог перевірки не видалено: ' + $verifiedBundleRoot + ' (' + $_.Exception.Message + ')')
        }
    }
}

# --- 2. Вільне місце --------------------------------------------------------

Write-Step '2. Вільне місце на цільовому томі'

$stagedSum = (Get-ChildItem -LiteralPath $staged -Recurse -Force -File |
    Measure-Object -Property Length -Sum).Sum
if ($null -eq $stagedSum) { $stagedSum = 0 }
$stagedBytes = [long]$stagedSum
$needBytes = [long]($stagedBytes * 1.2)
$targetQualifier = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($RuntimeRoot))
$freeBytes = $null
if ($targetQualifier -match '^[A-Za-z]:') {
    try {
        $drive = Get-PSDrive -Name ($targetQualifier.Substring(0, 1)) -ErrorAction Stop
        $freeBytes = [long]$drive.Free
    } catch {
        Write-Warn2 ('не вдалося визначити вільне місце на ' + $targetQualifier + ': ' + $_.Exception.Message)
    }
} else {
    Write-Warn2 ('цільовий шлях не на локальному томі з літерою (' + $targetQualifier +
        '): перевірку вільного місця пропущено.')
}
Write-Note ('комплект: ' + [math]::Round($stagedBytes / 1MB, 1) + ' MB')
if ($null -ne $freeBytes) {
    Write-Note ('вільно на ' + $targetQualifier + ': ' + [math]::Round($freeBytes / 1GB, 2) + ' GB')
    if ($freeBytes -lt $needBytes) {
        throw ('Недостатньо місця на ' + $targetQualifier + ': потрібно щонайменше ' +
            [math]::Round($needBytes / 1MB, 1) + ' MB.')
    }
    Write-Ok 'місця достатньо'
}

# Це перевірка місця САМЕ ПІД КОМПЛЕКТ. Вона нічого не каже про місце під
# архіви й обслуговування — його перевіряє BRAVO за
# maintenanceSettings.Limits.MinimumFreeSpaceGB (розділ 8 процедури міграції).

# --- 3. Розгортання ---------------------------------------------------------

Write-Step '3. Розгортання'

# Явний профіль (#434): BRAVO.local.config, перевірений у кроці 1, мусить
# бути тим самим і зараз — до ПЕРШОГО запису в каталог інсталяції. Інакше
# крок 4 відмовив би вже після копіювання, лишивши VERSION.json і частковий
# runtime.
if ($null -ne $siteConfigCheckedFingerprint -and
    (Get-BRAVOInstallSiteConfigSnapshot -Path $existingSiteConfig).Fingerprint -ne $siteConfigCheckedFingerprint) {
    throw ($existingSiteConfig + ' (BRAVO.local.config) змінився, з''явився чи зник після перевірки -BackupDestination ' +
        $BackupDestination + ' у кроці 1. Нічого не розгорнуто, файл не змінено. Завершіть редагування ' +
        'BRAVO.local.config і повторіть запуск.')
}

if (-not $targetExists) {
    [void](New-Item -ItemType Directory -Path $RuntimeRoot -Force)
    Write-Ok ('створено ' + $RuntimeRoot)
}

# Без /MIR і без /PURGE: цільовий каталог порожній, а знищувальні режими
# robocopy на кореневому каталозі — саме те, чого тут не має бути.
# /XF BRAVO.local.config (#434, Codex Security P1): site-файл не входить у
# RUNTIME_MANIFEST.json, тож комплект із ним лишається «цілісним», а копія
# переписала б наявний файл (уже після звірки відбитка вище) чи підклала б
# чужий замість seed. Site-файл у каталозі інсталяції створює лише крок 4.
$robocopyLog = Join-Path $StagingRoot ('robocopy_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
$null = & robocopy.exe $staged $RuntimeRoot /E /R:2 /W:2 /NFL /NDL /NP /XF 'BRAVO.local.config' ('/LOG:' + $robocopyLog)
$robocopyCode = $LASTEXITCODE
if ($robocopyCode -ge 8) {
    throw ('robocopy завершився кодом ' + $robocopyCode + '; журнал: ' + $robocopyLog)
}
Write-Ok ('файли скопійовано (robocopy ' + $robocopyCode + ')')

$deployedVersion = (Get-Content -LiteralPath (Join-Path $RuntimeRoot 'VERSION.json') -Raw -Encoding UTF8 |
    ConvertFrom-Json)
if ([string]$deployedVersion.packageVersion -ne $targetVersion) {
    throw ('Після копіювання VERSION.json показує ' + $deployedVersion.packageVersion)
}
Write-Ok ('VERSION.json: ' + $deployedVersion.packageVersion + ' / ' + $deployedVersion.releaseChannel)

# --- 4. BRAVO.local.config --------------------------------------------------

Write-Step '4. Шар site-відмінностей'

$localConfig = Join-Path $RuntimeRoot 'BRAVO.local.config'
$localExample = Join-Path $RuntimeRoot 'BRAVO.local.config.example'
$backupDestinationExplicit = $PSBoundParameters.ContainsKey('BackupDestination')
$backupDestinationSkippedExisting = $false
$localConfigExists = $false
# Модулі Configurator (і для запису, і для читання site-файлу) вже розгорнуто
# з архіву, SHA-256 якого звірено в кроці 1; перед їх імпортом розгорнутий
# каталог звіряється з RUNTIME_MANIFEST.json (Assert-BRAVOInstallBundleIntegrity).
$configuratorModuleRoot = Join-Path $RuntimeRoot 'modules\BRAVO.Configurator'
if (Test-Path -LiteralPath $localConfig -PathType Leaf) {
    Write-Ok 'BRAVO.local.config уже існує — не чіпаємо'
    $localConfigExists = $true
    $backupDestinationSkippedExisting = $SeedLocalConfig -and -not $backupDestinationExplicit
} elseif ($SeedLocalConfig) {
    if (-not $backupDestinationExplicit -and
        @(Get-BRAVOInstallBackupDestinationMissingCapabilities -ModuleRoot $RuntimeRoot).Count -gt 0) {
        # Комплект без можливостей профілю напрямків (старші релізи або знімок
        # developer) і неявний профіль: зворотно сумісна поведінка developer —
        # копія прикладу. Явний профіль сюди не потрапляє: такий комплект
        # відхилено в кроці 1 тією самою перевіркою.
        if (-not (Test-Path -LiteralPath $localExample -PathType Leaf)) {
            throw ('Немає прикладу ' + $localExample)
        }
        Copy-Item -LiteralPath $localExample -Destination $localConfig
        Write-Ok ('створено з прикладу: ' + $localConfig)
        Write-Warn2 'усі ключі в ньому закоментовані — внесіть site-відмінності ДО BRAVO_SETUP.'
    } else {
        # Новий файл пише канонічний код Configurator (той самий серіалізатор і
        # перевірка повторним читанням, що й Apply) — інсталятор не має власного
        # запису чи парсера BRAVO.local.config. Розгорнутий каталог спершу
        # звіряється з RUNTIME_MANIFEST.json: guard кроку 5 ще не запускався.
        Assert-BRAVOInstallBundleIntegrity -BundleRoot $RuntimeRoot
        foreach ($configuratorModuleName in @('BRAVO.Configurator.Effective', 'BRAVO.Configurator.Persistence', 'BRAVO.Configurator.Presets')) {
            Import-Module -Name (Join-Path $configuratorModuleRoot ($configuratorModuleName + '.psm1')) -Force -ErrorAction Stop
        }
        $destinationProfile = Get-BRAVOConfiguratorBackupDestinationProfile -Destination $BackupDestination
        $seedResult = New-BRAVOConfiguratorSeedLocalConfig -RuntimeRoot $RuntimeRoot `
            -ConfigDirectory $RuntimeRoot -Overrides $destinationProfile.Overrides
        if (-not $seedResult.Created) {
            throw ('BRAVO.local.config не створено (' + $seedResult.Stage + '): ' + (@($seedResult.Reasons) -join ' '))
        }
        Write-Ok ('створено: ' + $localConfig)
        Write-Ok ('профіль напрямків: ' + $BackupDestination + ' — ' + $destinationProfile.Label)
        foreach ($appliedPath in @($seedResult.AppliedPaths)) {
            Write-Note ($appliedPath + ' = ' + [string]$destinationProfile.Overrides[$appliedPath])
        }
        if ([bool]$destinationProfile.Overrides['componentSettings.SMB.ArchiveCopy']) {
            Write-Warn2 'для Samba задайте smbSettings.RootPath (UNC \\сервер\ресурс) у BRAVO.local.config ДО BRAVO_SETUP.'
        }
        Write-Note ('інші site-відмінності — за каталогом ключів ' + $localExample)
    }
} else {
    Write-Note ('не створено (додайте -SeedLocalConfig або скопіюйте вручну з ' +
        'BRAVO.local.config.example)')
    if ($backupDestinationExplicit) {
        # Захист на глибину: крок 0 уже відмовив би в цьому випадку.
        throw ('-BackupDestination ' + $BackupDestination + ' не застосовано: без -SeedLocalConfig і без ' +
            'BRAVO.local.config діють дефолти комплекту, які не відповідають жодному профілю напрямків. ' +
            'Повторіть запуск із -SeedLocalConfig -BackupDestination ' + $BackupDestination + '.')
    }
}
if ($backupDestinationSkippedExisting) {
    Write-Note ('профіль напрямків ' + $BackupDestination + ' НЕ застосовано: наявний файл не змінюється ' +
        '(напрямки задає BRAVO_CONFIGURATOR.ps1)')
}
if ($backupDestinationExplicit) {
    # Явний профіль діє лише тоді, коли його підтверджують ефективні значення
    # файла — щойно засіяного або наявного (для наявного це захист на глибину:
    # той самий висновок, що в кроці 1, тепер над розгорнутими модулями, які
    # перед імпортом знову звіряються з RUNTIME_MANIFEST.json).
    Assert-BRAVOInstallBundleIntegrity -BundleRoot $RuntimeRoot
    $siteSettings = Get-BRAVOInstallSiteComponentSettings -ModuleRoot $RuntimeRoot -ConfigDirectory $RuntimeRoot -Destination $BackupDestination
    $siteStorage = Get-BRAVOEffectiveStorageConfiguration -ComponentSettings $siteSettings
    $siteSynchronization = Get-BRAVOEffectiveSynchronizationConfiguration -Synchronization $siteSettings['Synchronization'] `
        -GlobalSftpEnabled ([bool]$siteStorage.SFTP.Enabled)
    Assert-BRAVOInstallBackupDestinationEffective -Destination $BackupDestination `
        -EffectiveStorage $siteStorage -EffectiveSynchronization $siteSynchronization -SiteConfigPath $localConfig
}
Write-Note 'BRAVO.config з комплекту не редагується — site-значення належать BRAVO.local.config.'

# --- 5. Гейт цілісності -----------------------------------------------------

Write-Step '5. Гейт: цілісність комплекту'

Push-Location $RuntimeRoot
try {
    & (Join-Path $RuntimeRoot 'BRAVO_RUNTIME_GUARD.ps1')
    $guardCode = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($guardCode -ne 0) {
    Write-Bad ('BRAVO_RUNTIME_GUARD.ps1 -> exit ' + $guardCode)
    switch ($guardCode) {
        33 { Write-Host '  33 = цілісність комплекту порушена: файл не збігається з RUNTIME_MANIFEST.json, відсутній, або в комплекті є сторонній .ps1/.psm1.' -ForegroundColor Red }
        34 { Write-Host '  34 = BRAVO.config послаблює захист (Tools Mode=Warn або backupConsistency.Mode != VSS).' -ForegroundColor Red }
        35 { Write-Host '  35 = на цьому сервері вже запускали новішу версію (BRAVO_VERSION_STATE.json).' -ForegroundColor Red }
        default { }
    }
    Write-Host ''
    Write-Host '  Розгорнуті файли НЕ видалено — це доказ. Не "лагодьте" цю помилку' -ForegroundColor Yellow
    Write-Host '  видаленням маніфеста: так вимикається перевірка, а не усувається причина.' -ForegroundColor Yellow
    Write-Host '  Порядок дій за кодом — матриця діагностики в README §12.' -ForegroundColor Yellow
    exit $guardCode
}
Write-Ok 'BRAVO_RUNTIME_GUARD.ps1 -> exit 0'

# --- 6. Self-test -----------------------------------------------------------

Write-Step '6. Self-test'

if ($SkipSelfTest) {
    Write-Note 'пропущено (-SkipSelfTest)'
} else {
    Write-Note 'виконується, це кілька хвилин...'
    Push-Location $RuntimeRoot
    try {
        # -NoPause обов'язковий: без нього self-test чекає клавішу
        # (Wait-BRAVOManualExit) і зупиняє весь автоматичний прогін
        # посеред кроку 6 — спіймано на реальній інсталяції.
        & (Join-Path $RuntimeRoot 'BRAVO_SELF_TEST.ps1') -NoPause
        $selfTestCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($selfTestCode -eq 0) {
        Write-Ok 'BRAVO_SELF_TEST.ps1 -> exit 0'
    } else {
        Write-Bad ('BRAVO_SELF_TEST.ps1 -> exit ' + $selfTestCode)
        Write-Host ''
        Write-Host '  Комплект розгорнуто, але не провалідовано. Розберіть рядки [FAIL] вище' -ForegroundColor Yellow
        Write-Host '  і журнал у LOGS\HELPERS перед налаштуванням. Частина перевірок залежить' -ForegroundColor Yellow
        Write-Host '  від середовища хоста (політики PowerShell, доступність мережевих шляхів),' -ForegroundColor Yellow
        Write-Host '  тому провал self-test не завжди означає дефект комплекту. Свідомо' -ForegroundColor Yellow
        Write-Host '  пропустити перевірку можна параметром -SkipSelfTest.' -ForegroundColor Yellow
        exit $selfTestCode
    }
}

# --- 7. Діагностична валідація (не блокує) ----------------------------------

Write-Step '7. Валідація конфігурації (діагностична)'

Push-Location $RuntimeRoot
try {
    & (Join-Path $RuntimeRoot 'BRAVO_SETUP.ps1') -ValidateOnly -NoPause
    $validateCode = $LASTEXITCODE
} finally {
    Pop-Location
}

# Вердикт — той самий канонічний помічник, що й у гейтах оновлювача (#330):
# 0 = PASS, 10 = PASS WITH WARNING, інше = FAIL. Помічник читається в
# дочірній області (його Set-StrictMode не змінює режим цього скрипта);
# без файлу крок лише діагностичний, тож вердикт = FAIL з кодом у журналі.
$validateVerdict = 'FAIL'
$rollbackHelperPath = Join-Path $PSScriptRoot 'BRAVO.Deploy.Rollback.ps1'
if ($null -ne $validateCode -and (Test-Path -LiteralPath $rollbackHelperPath -PathType Leaf)) {
    $validateVerdict = & { . $rollbackHelperPath; Get-BRAVODeploySetupExitVerdict -ExitCode $validateCode }
}

if ($validateVerdict -eq 'PASS') {
    Write-Ok 'BRAVO_SETUP.ps1 -ValidateOnly -> exit 0'
} elseif ($validateVerdict -eq 'PASS_WITH_WARNING') {
    Write-Ok 'BRAVO_SETUP.ps1 -ValidateOnly -> exit 10 (PASS WITH WARNING: успіх із попередженнями)'
} else {
    Write-Warn2 ('BRAVO_SETUP.ps1 -ValidateOnly -> exit ' + $validateCode)
    Write-Host '  На ЧИСТОМУ сервері це очікувано: 30 — не задані site-шляхи,' -ForegroundColor Yellow
    Write-Host '  31 — ще немає записів Credential Manager. Обидва усуваються на кроках нижче.' -ForegroundColor Yellow
}

# --- Підсумок ---------------------------------------------------------------

Write-Step 'Готово: комплект розгорнуто'

Write-Host ('  каталог:     ' + $RuntimeRoot)
Write-Host ('  версія:      ' + $deployedVersion.packageVersion + ' / ' + $deployedVersion.releaseChannel)
Write-Host ('  sourceCommit: ' + $stagedCommit)
Write-Host ('  staging:     ' + $StagingRoot + ' (можна видалити)')
Write-Host ''
Write-Host '  Сервер ЩЕ НЕ налаштований: credentials не створені, завдання' -ForegroundColor Yellow
Write-Host '  Планувальника не зареєстровані, архівація не виконується.' -ForegroundColor Yellow
Write-Host ''
Write-Host '  Далі, вручну й по порядку:' -ForegroundColor Cyan
Write-Host ('    1. ' + $localConfig + '  — внести site-відмінності')
Write-Host '    2. .\BRAVO_SETUP.ps1 -Action Test -ValidateOnly        — звірити DISCOVERY ДЖЕРЕЛ'
Write-Host '    3. .\BRAVO_SETUP.ps1 -Action Test -ValidateOnly -ConfirmDiscoveryBaseline'
Write-Host '    4. .\BRAVO_SETUP.ps1                                   — credentials + Планувальник'
Write-Host '    5. .\BRAVO_TASKS_DIAGNOSE.ps1 -InspectOnly'
Write-Host '    6. .\BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess'
Write-Host '    7. .\BRAVO_DRY_RUN.ps1                                 — прогін без production-дій'
Write-Host ''
exit 0
} catch {
    Write-Host ''
    Write-Host ('ЗУПИНЕНО: ' + $_.Exception.Message) -ForegroundColor Red
    $script:Failed = $true
} finally {
    Wait-BRAVODeployCompletion
    Restore-BRAVOConsoleEncoding
}

if ($script:Failed) { exit 1 }
