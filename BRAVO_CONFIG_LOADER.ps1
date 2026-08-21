#requires -Version 3.0

Set-StrictMode -Version 2.0

function Resolve-BRAVOReleaseChannelFromGit {
    # Визначає release channel із поточної гілки напряму з файлової
    # системи (.git/HEAD), без виклику git.exe — його може не бути на
    # production-сервері.
    #
    # AUD-016 (аудит): певний час ця функція БУЛА джерелом каналу, бо
    # ручна синхронізація VERSION.json між гілками двічі підвела на
    # fast-forward merge. RELEASE_POLICY.md (розділи 5.3, 5.4) повернув
    # джерело істини в пакет: розгорнутий комплект узагалі не має .git,
    # і канал тоді нізвідки взяти. Причину AUD-016 усунуто інакше —
    # гілки більше ніколи не містять однакової версії (розділ 4), тому
    # fast-forward між ними неможливий, а узгодженість гілки, версії та
    # каналу тепер механічно охороняє ci\Test-BRAVOReleasePolicy.ps1.
    #
    # Тут результат лишається як безкоштовна перехресна перевірка: поки
    # .git поруч, розбіжність із VERSION.json видно (ReleaseChannelMatchesGit).
    #
    # -GitHeadContent дозволяє self-test підставити синтетичний вміст
    # .git/HEAD замість реального файлу (той самий injectable-патерн, що
    # вже використовує BRAVO.Discovery).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigRoot,
        [string]$GitHeadContent
    )

    # Непереданий [string]-параметр PowerShell дефолтить у "" (не $null),
    # тому "чи викликач передав -GitHeadContent" перевіряємо через
    # PSBoundParameters, а не через порівняння з $null — інакше self-test
    # не зміг би підставити явний порожній вміст (detached HEAD без
    # ref-рядка), і водночас звичайний виклик без параметра завжди
    # "знаходив" би порожній рядок замість читання реального .git/HEAD.
    if (-not $PSBoundParameters.ContainsKey('GitHeadContent')) {
        $gitHeadPath = Join-Path $ConfigRoot '.git\HEAD'
        if (-not (Test-Path -LiteralPath $gitHeadPath -PathType Leaf)) {
            return $null
        }
        try {
            $GitHeadContent = (Get-Content -LiteralPath $gitHeadPath -Raw -ErrorAction Stop).Trim()
        } catch {
            return $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($GitHeadContent)) {
        return $null
    }
    if ($GitHeadContent -notmatch '^ref:\s*refs/heads/(?<Branch>.+)$') {
        # detached HEAD (checkout конкретного коміту/тегу) — неоднозначно,
        # який channel мався на увазі; не перевизначаємо.
        return $null
    }
    $branchName = $Matches.Branch.Trim()

    switch -Regex ($branchName) {
        '^(master|main)$' { return 'stable' }
        '^developer$' { return 'development' }
        default { return $null }
    }
}

function Get-BravoVersionMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigRoot
    )

    $versionPath = Join-Path $ConfigRoot 'VERSION.json'

    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        return [pscustomobject]@{
            Product = 'BRAVO Archive'
            PackageVersion = $null
            ConfigSchemaVersion = 1
            StateSchemaVersion = 1
            UpdaterVersion = $null
            ReleaseDate = $null
            ReleaseChannel = 'legacy'
            ReleaseChannelSource = 'legacy'
            GitBranchReleaseChannel = $null
            ReleaseChannelMatchesGit = $null
            BuildId = $null
            SourceCommit = $null
            VersionFilePath = $versionPath
            VersionFilePresent = $false
        }
    }

    try {
        $rawVersion = Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 -ErrorAction Stop
        $versionData = $rawVersion | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Не вдалося прочитати VERSION.json: $($_.Exception.Message)"
    }

    foreach ($requiredProperty in @('product', 'packageVersion', 'configSchemaVersion', 'stateSchemaVersion', 'updaterVersion', 'releaseDate')) {
        if ($null -eq $versionData.PSObject.Properties[$requiredProperty]) {
            throw "VERSION.json не містить обов'язкової властивості '$requiredProperty'."
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$versionData.packageVersion)) {
        throw 'VERSION.json містить порожню версію пакета.'
    }
    $parsedReleaseDate = [datetime]::MinValue
    if (-not ([datetime]::TryParseExact(
                [string]$versionData.releaseDate,
                'yyyy-MM-dd',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None,
                [ref]$parsedReleaseDate
            ))) {
        throw 'VERSION.json містить некоректну releaseDate; очікується формат YYYY-MM-DD.'
    }

    # buildId — свідомо не обов'язковий: старіші VERSION.json (до цієї
    # версії) його не містять, і requiredProperty-перевірка вище не мала б
    # ламатися при оновленні поверх них.
    $buildId = if ($null -ne $versionData.PSObject.Properties['buildId']) {
        [string]$versionData.buildId
    } else {
        $null
    }

    # sourceCommit (аудит P4) — повний git-hash коміту, з якого зібрано
    # комплект. buildId (короткий hash) не дає однозначної відповіді на
    # питання "який саме код зараз на цьому сервері": короткі hash можуть
    # збігатися, і їх неможливо надійно знайти в історії. Поле необов'язкове
    # з тієї ж причини, що й buildId — сумісність зі старішими VERSION.json.
    $sourceCommit = if ($null -ne $versionData.PSObject.Properties['sourceCommit']) {
        [string]$versionData.sourceCommit
    } else {
        $null
    }

    # RELEASE_POLICY.md, розділи 5.3-5.4: канал релізу зберігається в
    # самому пакеті. Пакет на сервері приходить ZIP-ом, копіюванням,
    # SFTP або SMB — .git там немає, і виведений із гілки канал у
    # production просто недоступний. .git, коли він поруч, лишається
    # перехресною перевіркою: розбіжність видно в ReleaseChannelMatchesGit
    # (у CI її ловить ci\Test-BRAVOReleasePolicy.ps1).
    $staticReleaseChannel = [string]$versionData.releaseChannel
    $gitDetectedReleaseChannel = Resolve-BRAVOReleaseChannelFromGit -ConfigRoot $ConfigRoot
    $effectiveReleaseChannel = $staticReleaseChannel
    $releaseChannelSource = 'VERSION.json'
    $releaseChannelMatchesGit = if ([string]::IsNullOrWhiteSpace($gitDetectedReleaseChannel)) {
        # Гілки немає (розгорнутий пакет, detached HEAD, feature/*) —
        # порівнювати нема з чим; це не "не збігається".
        $null
    } elseif ($gitDetectedReleaseChannel -eq 'stable') {
        $staticReleaseChannel -eq 'stable'
    } else {
        # developer несе і 'development' (dev.N), і 'prerelease' (rc.N).
        $staticReleaseChannel -in @('development', 'prerelease')
    }

    return [pscustomobject]@{
        Product = [string]$versionData.product
        PackageVersion = [string]$versionData.packageVersion
        ConfigSchemaVersion = [int]$versionData.configSchemaVersion
        StateSchemaVersion = [int]$versionData.stateSchemaVersion
        UpdaterVersion = [string]$versionData.updaterVersion
        ReleaseDate = [string]$versionData.releaseDate
        ReleaseChannel = $effectiveReleaseChannel
        ReleaseChannelSource = $releaseChannelSource
        GitBranchReleaseChannel = $gitDetectedReleaseChannel
        ReleaseChannelMatchesGit = $releaseChannelMatchesGit
        BuildId = $buildId
        SourceCommit = $sourceCommit
        VersionFilePath = $versionPath
        VersionFilePresent = $true
    }
}

function Test-BravoLegacyConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$ConfigRoot
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Не знайдено файл конфігурації: $ConfigPath"
    }

    $extension = [System.IO.Path]::GetExtension($ConfigPath)
    if (-not [string]::Equals($extension, '.config', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Непідтримуваний формат конфігурації: $extension"
    }

    if (-not (Test-Path -LiteralPath $ConfigRoot -PathType Container)) {
        throw "Не знайдено каталог конфігурації: $ConfigRoot"
    }

    $rootPrefix = $ConfigRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    if (-not $ConfigPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Файл конфігурації повинен знаходитися в каталозі конфігурації '$ConfigRoot': $ConfigPath"
    }
}

function Test-BravoDataRootValue {
    # Валідація значення production data root. Порожнє значення допустиме
    # для LIMSRoot і SystemLogRoot (== AUTO); для непорожнього — розкриття
    # %ENV%, зняття лапок і вимога абсолютного шляху.
    #
    # GetFullPath навмисно застосовується ЛИШЕ до вже абсолютного значення:
    # для відносного він добудував би шлях від поточного каталогу процесу, а
    # під заплановим завданням це C:\Windows\System32. Саме так «тихий
    # відносний шлях» перетворюється на кореневий каталог Windows — тому
    # відносне значення є помилкою конфігурації, а не приводом здогадуватись.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Value,
        [switch]$AllowEmpty
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($AllowEmpty) {
            return
        }
        throw "pathSettings.$Name не задано. Залиште """" для AUTO-визначення або задайте явний абсолютний шлях."
    }

    $normalized = $Value.Trim()
    if ($normalized.Length -ge 2 -and $normalized.StartsWith('"') -and $normalized.EndsWith('"')) {
        $normalized = $normalized.Substring(1, $normalized.Length - 2).Trim()
    }
    $normalized = [Environment]::ExpandEnvironmentVariables($normalized)
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        if ($AllowEmpty) {
            return
        }
        throw "pathSettings.$Name порожній після розкриття змінних середовища (вихідне значення: '$Value')."
    }
    if ($normalized -notmatch '^([A-Za-z]:[\\/]|\\\\[^\\/]+[\\/])') {
        throw "pathSettings.$Name повинен бути абсолютним шляхом ('D:\LIMS-NEW' або '\\server\share\...'), а не '$Value'."
    }
}

function Assert-BravoDataRootsAreIndependent {
    # CODE IS NOT DATA. RuntimeRoot — місце виконуваного комплекту; LIMSRoot,
    # SystemLogRoot і BackupRoot — місця даних, які НЕ виводяться з
    # розташування комплекту.
    #
    # Контракт значень (ТЗ RuntimeRoot/LIMSRoot §31-§32; ТЗ "1. LIMSRoot"):
    #   LIMSRoot      "" = AUTO через службу BRAVO; непорожнє = абсолютний шлях.
    #   SystemLogRoot "" = <EffectiveLIMSRoot>\ARCHIV\LOGS; непорожнє = абсолютний.
    #   BackupRoot    "" = <EffectiveLIMSRoot>\ARCHIV;      непорожнє = абсолютний.
    # Усі три "" — валідна all-AUTO configuration. Перевірка абсолютності
    # виконується лише для НЕпорожнього значення (звідси -AllowEmpty).
    # Ефективні значення (з урахуванням AUTO) обчислює сам BRAVO.config через
    # Resolve-BRAVOEffectiveLimsRoot / Resolve-BRAVOEffectiveSystemLogRoot /
    # Resolve-BRAVOEffectiveBackupRoot.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$PathSettings)

    Test-BravoDataRootValue -Name 'LIMSRoot' -Value ([string]$PathSettings['LIMSRoot']) -AllowEmpty
    Test-BravoDataRootValue -Name 'SystemLogRoot' -Value ([string]$PathSettings['SystemLogRoot']) -AllowEmpty
    Test-BravoDataRootValue -Name 'BackupRoot' -Value ([string]$PathSettings['BackupRoot']) -AllowEmpty
}

function Assert-BravoLoadedConfiguration {
    [CmdletBinding()]
    param()

    $requiredGlobalVariables = @(
        'bravoSettings',
        'credentialSettings',
        'pathSettings',
        'maintenanceSettings',
        'componentSettings'
    )

    $missingVariables = New-Object System.Collections.Generic.List[string]

    foreach ($variableName in $requiredGlobalVariables) {
        $variable = Get-Variable -Name $variableName -Scope Global -ErrorAction SilentlyContinue
        if ($null -eq $variable -or $null -eq $variable.Value) {
            $missingVariables.Add($variableName)
        }
    }

    if ($missingVariables.Count -gt 0) {
        throw "BRAVO.config не створив обов'язкові глобальні змінні: $($missingVariables -join ', ')"
    }

    if (-not ($global:bravoSettings -is [hashtable])) {
        throw 'bravoSettings повинен бути хеш-таблицею.'
    }

    # NotificationRouting — необов'язковий підключ (старі config без нього
    # лишаються валідними; BRAVO.Notifications і backupMonitoring-проєкція
    # застосовують безпечний дефолт). Тут лише м'яке попередження, якщо
    # ключ присутній, але має неправильний тип — не throw, щоб не зробити
    # стару/помилкову конфігурацію фатальною через опційне налаштування.
    if ($global:bravoSettings.Contains('NotificationRouting') -and
        -not ($global:bravoSettings.NotificationRouting -is [hashtable])) {
        Write-Warning 'bravoSettings.NotificationRouting має бути хеш-таблицею — застосовується дефолтна маршрутизація (SUCCESS=general, WARNING/ERROR/CRITICAL=alerts).'
    }

    # Restore.BootRestoreMode (5.2.0) замінив Restore.RunMissedOnStartup:
    # семантика boot-recovery змінилась (реставрація ПОЗА вікном з
    # утриманням служб), тому стара назва навмисно не мапиться мовчки —
    # оператор має свідомо обрати профіль сервера.
    if ($global:maintenanceSettings -is [hashtable] -and
        $global:maintenanceSettings.Restore -is [hashtable]) {
        $restoreSettingsForValidation = $global:maintenanceSettings.Restore
        if ($restoreSettingsForValidation.Contains('RunMissedOnStartup')) {
            Write-Warning 'maintenanceSettings.Restore.RunMissedOnStartup застарів і ігнорується — задайте Restore.BootRestoreMode = "None" (24/7-сервер) або "HoldServices" (сервер робочого часу: реставрація при старті з утриманням служб).'
        }
        $bootRestoreModeValue = if ($restoreSettingsForValidation.Contains('BootRestoreMode')) {
            [string]$restoreSettingsForValidation.BootRestoreMode
        } else {
            ''
        }
        if (-not [string]::IsNullOrWhiteSpace($bootRestoreModeValue) -and
            $bootRestoreModeValue -notin @('None', 'HoldServices')) {
            Write-Warning "maintenanceSettings.Restore.BootRestoreMode = '$bootRestoreModeValue' не розпізнано — застосовується безпечний профіль 'None' (24/7: без boot-recovery; пропущену реставрацію підхоплює планове Maintenance)."
            $restoreSettingsForValidation.BootRestoreMode = 'None'
        }
        if (-not $restoreSettingsForValidation.Contains('BootRestoreMode')) {
            # Старий site-config (5.0/5.1) взагалі без нового ключа:
            # ефективна конфігурація МУСИТЬ гарантувати його наявність —
            # консумери (BRAVO_TASKS_INSTALL, Maintenance) читають
            # $maintenanceSettings.Restore.BootRestoreMode напряму й під
            # StrictMode падали на відсутньому ключі ("property cannot be
            # found"), всупереч обіцянці «застарілий ключ ігнорується»
            # (реальний випадок: DEV-LIMS, site-config rc.4-ери). Дефолт —
            # безпечний 24/7-профіль 'None'.
            $restoreSettingsForValidation.BootRestoreMode = 'None'
        }
    }

    if (-not ($global:pathSettings -is [hashtable])) {
        throw 'pathSettings повинен бути хеш-таблицею.'
    }

    if (-not ($global:componentSettings -is [hashtable])) {
        throw 'componentSettings повинен бути хеш-таблицею.'
    }

    Assert-BravoDataRootsAreIndependent -PathSettings $global:pathSettings
}

function Import-BravoConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigRoot,

        [string]$ConfigPath,

        # Каталог самого комплекту (де лежать modules\, Tools\, VERSION.json,
        # RUNTIME_MANIFEST.json). За замовчуванням збігається з ConfigRoot —
        # так було й до появи цього параметра. Але -ConfigPath може вказувати
        # на конфігурацію в іншому каталозі (C:\BRAVO\CONFIGS\SERVER1.config),
        # і тоді modules\ треба шукати не поруч із нею, а поруч зі скриптами.
        [string]$RuntimeRoot,

        [switch]$PassThru
    )

    $resolvedConfigRoot = [System.IO.Path]::GetFullPath($ConfigRoot)
    $resolvedRuntimeRoot = if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $resolvedConfigRoot
    } else {
        [System.IO.Path]::GetFullPath($RuntimeRoot)
    }

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $resolvedConfigRoot 'BRAVO.config'
    }

    $resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)

    Test-BravoLegacyConfiguration `
        -ConfigPath $resolvedConfigPath `
        -ConfigRoot $resolvedConfigRoot

    $versionMetadata = Get-BravoVersionMetadata -ConfigRoot $resolvedRuntimeRoot

    # BRAVO.config викликає Resolve-BRAVOInstallationDiscovery, тому цей
    # модуль має бути в scope ще до виконання самого config-скрипта.
    # BRAVO.config сам ніколи не імпортує модулі (покладається на те, що
    # виклик Import-BravoConfiguration уже їх завантажив) — тому це єдина
    # точка, спільна для всіх ~10 entrypoint-ів, які дот-сорсять цей файл.
    $discoveryModulePath = Join-Path $resolvedRuntimeRoot 'modules\BRAVO.Discovery\BRAVO.Discovery.psd1'
    if (Test-Path -LiteralPath $discoveryModulePath -PathType Leaf) {
        Import-Module -Name $discoveryModulePath -ErrorAction Stop
    }

    try {
        # Files with a non-.ps1 extension are not reliably dot-sourced by
        # Windows PowerShell. Read the legacy file explicitly and compile it
        # as a script block, preserving its param(ConfigRoot) contract.
        $legacyConfigText = Get-Content `
            -LiteralPath $resolvedConfigPath `
            -Raw `
            -Encoding UTF8 `
            -ErrorAction Stop

        $legacyConfigScript = [scriptblock]::Create($legacyConfigText)
        & $legacyConfigScript -ConfigRoot $resolvedConfigRoot -RuntimeRoot $resolvedRuntimeRoot
    }
    catch {
        throw "Не вдалося завантажити BRAVO.config '$resolvedConfigPath': $($_.Exception.Message)"
    }

    Assert-BravoLoadedConfiguration

    $legacyScriptVersionVariable = Get-Variable `
        -Name 'ScriptVersion' `
        -Scope Global `
        -ErrorAction SilentlyContinue

    $legacyScriptVersion = $null
    $versionMatches = $null

    if ($null -ne $legacyScriptVersionVariable) {
        $legacyScriptVersion = [string]$legacyScriptVersionVariable.Value

        if ($versionMetadata.VersionFilePresent) {
            $versionMatches = [string]::Equals(
                $legacyScriptVersion,
                [string]$versionMetadata.PackageVersion,
                [System.StringComparison]::OrdinalIgnoreCase
            )

            if (-not $versionMatches) {
                Write-Warning (
                    "VERSION.json ('$($versionMetadata.PackageVersion)') і BRAVO.config " +
                    "('$legacyScriptVersion') містять різні версії пакета. " +
                    'Це тимчасово допустимо, але вказує на розсинхронізовану конфігурацію.'
                )
            }
        }
    }

    if ($versionMetadata.VersionFilePresent) {
        $global:ScriptVersion = [string]$versionMetadata.PackageVersion
        $global:ScriptDate = [string]$versionMetadata.ReleaseDate
        $global:ScriptBuildId = [string]$versionMetadata.BuildId
    }
    elseif ([string]::IsNullOrWhiteSpace($legacyScriptVersion)) {
        throw (
            'Не вдалося визначити версію пакета: відсутній VERSION.json ' +
            'і BRAVO.config не містить ScriptVersion.'
        )
    }
    else {
        $global:ScriptVersion = $legacyScriptVersion
        $global:ScriptBuildId = $null
    }

    $global:BravoVersionMetadata = $versionMetadata
    $global:BravoConfigurationMetadata = [pscustomobject]@{
        Format = 'legacy-config'
        ConfigPath = $resolvedConfigPath
        ConfigRoot = $resolvedConfigRoot
        RuntimeRoot = $resolvedRuntimeRoot
        ConfigSchemaVersion = [int]$versionMetadata.ConfigSchemaVersion
        LegacyScriptVersion = $legacyScriptVersion
        LegacyScriptVersionPresent = ($null -ne $legacyScriptVersionVariable)
        PackageVersion = [string]$global:ScriptVersion
        PackageVersionMatchesLegacyConfig = $versionMatches
        ReleaseDate = [string]$global:ScriptDate
        BuildId = [string]$global:ScriptBuildId
        LoadedAt = Get-Date
    }

    if ($PassThru) {
        return [pscustomobject]@{
            Version = $global:BravoVersionMetadata
            Configuration = $global:BravoConfigurationMetadata
            BravoSettings = $global:bravoSettings
            CredentialSettings = $global:credentialSettings
            PathSettings = $global:pathSettings
            MaintenanceSettings = $global:maintenanceSettings
            ComponentSettings = $global:componentSettings
        }
    }
}
