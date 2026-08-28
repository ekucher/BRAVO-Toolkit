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

function Read-BRAVOLocalConfigurationOverrides {
    # BRAVO.local.config (5.2.1) — локальні site-відмінності, що ПЕРЕЖИВАЮТЬ
    # оновлення комплекту: оператор більше не редагує BRAVO.config вручну на
    # нетипових інсталяціях. Файл лежить ПОРЯД з effective config і містить
    # data-only hashtable «dot-шлях -> значення», наприклад:
    #
    #     @{
    #         'pathSettings.BackupRoot' = 'E:\ARCHIV'
    #         'maintenanceSettings.Restore.BootRestoreMode' = 'HoldServices'
    #         'backupMonitoring.SFTP.BAZA.AutoArchiveMutationThreshold' = 50
    #         'sftpHostTemplate' = '{0}.example.com'
    #     }
    #
    # Формат навмисно data-only (CheckRestrictedLanguage без жодної
    # дозволеної команди): локальний файл не є кодом і не може виконувати
    # дії — лише значення. Відсутній файл = штатний no-op.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigDirectory
    )

    $localOverridePath = Join-Path $ConfigDirectory 'BRAVO.local.config'
    if (-not (Test-Path -LiteralPath $localOverridePath -PathType Leaf)) {
        return [pscustomobject]@{ Path = $localOverridePath; Present = $false; Overrides = @{} }
    }

    $localOverrideText = Get-Content -LiteralPath $localOverridePath -Raw -Encoding UTF8 -ErrorAction Stop
    $localOverrideScript = [scriptblock]::Create($localOverrideText)
    try {
        # Порожні списки дозволених команд/змінних + заборона змінних
        # оточення: як Import-PowerShellDataFile, лише літеральні дані.
        $localOverrideScript.CheckRestrictedLanguage([string[]]@(), [string[]]@(), $false)
    } catch {
        throw "BRAVO.local.config ('$localOverridePath') мусить бути data-only hashtable без виконуваного коду: $($_.Exception.Message)"
    }
    $localOverrideData = & $localOverrideScript
    if ($localOverrideData -isnot [hashtable]) {
        throw "BRAVO.local.config ('$localOverridePath') мусить повертати hashtable «dot-шлях -> значення» (отримано: $(if ($null -eq $localOverrideData) { 'null' } else { $localOverrideData.GetType().Name }))."
    }
    foreach ($overrideKey in @($localOverrideData.Keys)) {
        if ([string]::IsNullOrWhiteSpace([string]$overrideKey)) {
            throw "BRAVO.local.config ('$localOverridePath'): порожній ключ неприпустимий."
        }
    }
    return [pscustomobject]@{ Path = $localOverridePath; Present = $true; Overrides = $localOverrideData }
}

function Invoke-BRAVOLocalConfigurationOverridePhase {
    # Застосовує ще не застосовані overrides, чий кореневий $global:-об'єкт
    # УЖЕ визначено. Викликається з BRAVO.config у двох канонічних точках:
    # після первинних блоків налаштувань (щоб деривації — archiveDirs,
    # discovery, scheduler — підхопили перевизначені первинні значення) і в
    # самому кінці (для пізно визначених leaf-блоків: пороги, розклади).
    # Проміжні вузли шляху НЕ створюються (захист від опечаток): ключ, що
    # так і не застосувався, стане помилкою конфігурації в лоадері.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State
    )

    foreach ($overrideKey in @($State.Overrides.Keys)) {
        if ($State.Applied.Contains([string]$overrideKey)) { continue }
        $segments = @(([string]$overrideKey) -split '\.')
        $rootVariable = Get-Variable -Name $segments[0] -Scope Global -ErrorAction SilentlyContinue
        if ($null -eq $rootVariable -or $null -eq $rootVariable.Value) { continue }

        if ($segments.Count -eq 1) {
            Set-Variable -Name $segments[0] -Scope Global -Value $State.Overrides[$overrideKey]
            [void]$State.Applied.Add([string]$overrideKey)
            continue
        }

        $currentNode = $rootVariable.Value
        $intermediateBroken = $false
        for ($segmentIndex = 1; $segmentIndex -lt ($segments.Count - 1); $segmentIndex++) {
            $segment = $segments[$segmentIndex]
            if ($currentNode -is [hashtable] -and $currentNode.Contains($segment)) {
                $currentNode = $currentNode[$segment]
            } elseif ($null -ne $currentNode -and $null -ne $currentNode.PSObject.Properties[$segment]) {
                $currentNode = $currentNode.$segment
            } else {
                $intermediateBroken = $true
                break
            }
        }
        if ($intermediateBroken -or $null -eq $currentNode) { continue }

        $leafSegment = $segments[$segments.Count - 1]
        if ($currentNode -is [hashtable]) {
            # Новий ключ у hashtable дозволено: опційні властивості з
            # Contains-нормалізацією у споживачах — легітимна ціль override.
            $currentNode[$leafSegment] = $State.Overrides[$overrideKey]
            [void]$State.Applied.Add([string]$overrideKey)
        } elseif ($null -ne $currentNode.PSObject.Properties[$leafSegment]) {
            $currentNode.$leafSegment = $State.Overrides[$overrideKey]
            [void]$State.Applied.Add([string]$overrideKey)
        }
        # Інакше (об'єкт без такої властивості) — лишається незастосованим:
        # лоадер підніме помилку зі списком таких ключів.
    }
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

    # Trace-модель 5.2.0 (добові Trace_YYYYMMDD.mdz): три нові ключі.
    # Старі site-config без них лишаються валідними — ефективна
    # конфігурація МУСИТЬ гарантувати наявність ключів (консумери читають
    # їх напряму і під StrictMode падали б на відсутньому ключі — той
    # самий клас, що інцидент BootRestoreMode вище).
    if ($global:maintenanceSettings -is [hashtable]) {
        if (-not $global:maintenanceSettings.Contains('Trace') -or
            -not ($global:maintenanceSettings.Trace -is [hashtable])) {
            $global:maintenanceSettings.Trace = @{}
        }
        $traceSettingsForValidation = $global:maintenanceSettings.Trace
        if (-not $traceSettingsForValidation.Contains('BISSourcePath')) {
            # Порожньо = AUTO: Maintenance резолвить TraceBIS.out від кореня
            # інсталяції bravo.exe (Resolve-BRAVOTraceBisSourcePath).
            $traceSettingsForValidation.BISSourcePath = ''
        }
        $bisSourcePathValue = [string]$traceSettingsForValidation.BISSourcePath
        if (-not [string]::IsNullOrWhiteSpace($bisSourcePathValue) -and
            -not [string]::Equals($bisSourcePathValue.Trim(), 'off', [System.StringComparison]::OrdinalIgnoreCase) -and
            -not [System.IO.Path]::IsPathRooted($bisSourcePathValue)) {
            throw "maintenanceSettings.Trace.BISSourcePath = '$bisSourcePathValue' має бути абсолютним шляхом до TraceBIS.out, порожнім рядком (AUTO: корінь інсталяції bravo.exe) або 'off' (вимкнути обробку BIS)."
        }

        if ($global:maintenanceSettings.Retention -is [hashtable]) {
            $retentionSettingsForValidation = $global:maintenanceSettings.Retention
            if (-not $retentionSettingsForValidation.Contains('CompressedLogDeletionEnabled')) {
                # Безпечний дефолт: стиснуті .mdz журналів НЕ видаляються
                # автоматично, доки оператор явно не ввімкне політику.
                $retentionSettingsForValidation.CompressedLogDeletionEnabled = $false
            } elseif (-not ($retentionSettingsForValidation.CompressedLogDeletionEnabled -is [bool])) {
                Write-Warning "maintenanceSettings.Retention.CompressedLogDeletionEnabled = '$($retentionSettingsForValidation.CompressedLogDeletionEnabled)' не є `$true/`$false — застосовується безпечне `$false (стиснуті .mdz не видаляються)."
                $retentionSettingsForValidation.CompressedLogDeletionEnabled = $false
            }
        }
    }

    if ($global:sftpDirectories -is [hashtable]) {
        if (-not $global:sftpDirectories.Contains('Trace') -or
            [string]::IsNullOrWhiteSpace([string]$global:sftpDirectories.Trace)) {
            $global:sftpDirectories.Trace = 'trace'
        }
        # Модель logs/: нові каталоги журнальних архівів. Legacy-конфіги без
        # цих ключів отримують канонічні дефолти (compat), Trace лишається
        # джерелом одноразової автоміграції.
        if (-not $global:sftpDirectories.Contains('TraceLogs') -or
            [string]::IsNullOrWhiteSpace([string]$global:sftpDirectories.TraceLogs)) {
            $global:sftpDirectories.TraceLogs = 'logs/trace'
        }
        if (-not $global:sftpDirectories.Contains('ExchangeApiLogs') -or
            [string]::IsNullOrWhiteSpace([string]$global:sftpDirectories.ExchangeApiLogs)) {
            $global:sftpDirectories.ExchangeApiLogs = 'logs/exchangapi'
        }
    }

    if ($global:schedulerSettings -is [hashtable] -and
        $global:schedulerSettings.Contains('Health') -and
        $global:schedulerSettings.Health -is [hashtable]) {
        # 5.2.1: обмежене очікування звільнення архівації перед відкладенням
        # health-прогону. Legacy-конфіги без ключа отримують канонічний
        # дефолт комплекту (60 хв); явний 0 = негайне відкладення (стара
        # поведінка). Значення поза 0..90 хв — некоректне: ExecutionTimeLimit
        # задачі Health = 2 год, очікування мусить лишати запас на перевірку.
        $healthBusyWaitIsValid = $false
        if ($global:schedulerSettings.Health.Contains('BusyWaitMinutes')) {
            $healthBusyWaitParsed = 0
            if ([int]::TryParse([string]$global:schedulerSettings.Health.BusyWaitMinutes, [ref]$healthBusyWaitParsed) -and
                $healthBusyWaitParsed -ge 0 -and $healthBusyWaitParsed -le 90) {
                $global:schedulerSettings.Health.BusyWaitMinutes = $healthBusyWaitParsed
                $healthBusyWaitIsValid = $true
            } else {
                Write-Warning "schedulerSettings.Health.BusyWaitMinutes = '$($global:schedulerSettings.Health.BusyWaitMinutes)' не є цілим числом у межах 0..90 — застосовується канонічний дефолт 60 хв."
            }
        }
        if (-not $healthBusyWaitIsValid) {
            # Legacy-конфіг без ключа (мовчазний compat-дефолт) або
            # некоректне значення (Warning уже виписано вище).
            $global:schedulerSettings.Health.BusyWaitMinutes = 60
        }
    }

    if ($global:backupMonitoring -is [hashtable]) {
        # 5.2.1: вікно дедуплікації зелених success-звітів Health. Legacy-конфіги
        # без ключа отримують канонічний дефолт комплекту (1380 хв = 23 год:
        # максимум один зелений звіт на добу — post-backup після щоденної
        # архівації); явний 0 = дедуп вимкнено (стара поведінка). Верхня межа
        # 2880 хв (дві доби) — стеля для нестандартних розкладів бекапу.
        $successDedupIsValid = $false
        if ($global:backupMonitoring.Contains('SuccessDedupMinutes')) {
            $successDedupParsed = 0
            if ([int]::TryParse([string]$global:backupMonitoring.SuccessDedupMinutes, [ref]$successDedupParsed) -and
                $successDedupParsed -ge 0 -and $successDedupParsed -le 2880) {
                $global:backupMonitoring.SuccessDedupMinutes = $successDedupParsed
                $successDedupIsValid = $true
            } else {
                Write-Warning "backupMonitoring.SuccessDedupMinutes = '$($global:backupMonitoring.SuccessDedupMinutes)' не є цілим числом у межах 0..2880 — застосовується канонічний дефолт 1380 хв (23 год)."
            }
        }
        if (-not $successDedupIsValid) {
            $global:backupMonitoring.SuccessDedupMinutes = 1380
        }
        # Шлях state-файла дедупу: legacy-конфіг без ключа отримує файл поряд
        # з AlertStatePath (той самий State-каталог).
        if ((-not $global:backupMonitoring.Contains('SuccessNotificationStatePath') -or
                [string]::IsNullOrWhiteSpace([string]$global:backupMonitoring.SuccessNotificationStatePath)) -and
            $global:backupMonitoring.Contains('AlertStatePath') -and
            -not [string]::IsNullOrWhiteSpace([string]$global:backupMonitoring.AlertStatePath)) {
            $global:backupMonitoring.SuccessNotificationStatePath = Join-Path `
                (Split-Path -Path ([string]$global:backupMonitoring.AlertStatePath) -Parent) `
                'BRAVO_HEALTH_SUCCESS_NOTIFICATION_STATE.json'
        }
        # Шлях операційного lifecycle-стану Health (RecoveryPending): та сама
        # legacy-деривація від каталогу AlertStatePath.
        if ((-not $global:backupMonitoring.Contains('OperationalStatePath') -or
                [string]::IsNullOrWhiteSpace([string]$global:backupMonitoring.OperationalStatePath)) -and
            $global:backupMonitoring.Contains('AlertStatePath') -and
            -not [string]::IsNullOrWhiteSpace([string]$global:backupMonitoring.AlertStatePath)) {
            $global:backupMonitoring.OperationalStatePath = Join-Path `
                (Split-Path -Path ([string]$global:backupMonitoring.AlertStatePath) -Parent) `
                'BRAVO_HEALTH_OPERATIONAL_STATE.json'
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

    # Локальні site-overrides (BRAVO.local.config поряд з effective config):
    # читаються ДО виконання BRAVO.config; сам config застосовує їх у двох
    # канонічних фазах через Invoke-BRAVOLocalConfigurationOverridePhase.
    $localOverrideRead = Read-BRAVOLocalConfigurationOverrides `
        -ConfigDirectory (Split-Path -Path $resolvedConfigPath -Parent)
    $localOverrideState = $null
    if ($localOverrideRead.Present) {
        $localOverrideState = [pscustomobject]@{
            Path = [string]$localOverrideRead.Path
            Overrides = $localOverrideRead.Overrides
            Applied = New-Object 'System.Collections.Generic.HashSet[string]'
        }
    }
    $global:BravoLocalConfigOverrideState = $localOverrideState

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
        # Реальний DEV-майданчик (2026-08-24, Windows NT 6.2.9200 / PowerShell
        # 3.0 — Get-BRAVOOSSupportTier класифікує PowerShell <4.0 як
        # "Unsupported" незалежно від ОС): помилка виконання BRAVO.config тут
        # спливала як гола .NET NullReferenceException ("Ссылка на объект не
        # указывает на экземпляр объекта") без жодного натяку на причину.
        # Get-BRAVOOSSupportTier (BRAVO.Compatibility) — уже канонічне,
        # протестоване джерело цієї класифікації (використовують Maintenance/
        # Health/Archive), але викликається лише ПІСЛЯ успішного завантаження
        # конфігурації — на ~6000 рядків пізніше в Maintenance — тому жодного
        # шансу спрацювати раніше за цей крах немає. Збагачуємо повідомлення
        # тим самим канонічним висновком тут, а не дублюємо порогове значення
        # версії окремим magic-number: якщо саме збагачення з якоїсь причини
        # не вдається (напр. модуль Compatibility теж не вантажиться на цій
        # системі), мовчазний fallback — оригінальна помилка не повинна
        # загубитися за новою, ще заплутанішою.
        $unsupportedEnvironmentHint = ""
        try {
            $compatibilityModulePath = Join-Path $resolvedRuntimeRoot 'modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1'
            if (Test-Path -LiteralPath $compatibilityModulePath -PathType Leaf) {
                Import-Module -Name $compatibilityModulePath -ErrorAction Stop
                $osSupportTier = Get-BRAVOOSSupportTier
                if ($osSupportTier.Tier -ne 'Supported') {
                    $unsupportedEnvironmentHint = " $($osSupportTier.Message)"
                }
            }
        } catch {
            # Див. коментар вище — діагностичне збагачення не повинне саме
            # кидати нову помилку поверх оригінальної.
        }
        throw "Не вдалося завантажити BRAVO.config '$resolvedConfigPath': $($_.Exception.Message).$unsupportedEnvironmentHint"
    }

    # Fail-closed для overrides: ключ, що не застосувався в жодній фазі, —
    # найімовірніше опечатка в шляху або вузол, якого більше немає. Мовчазне
    # ігнорування означало б «конфіг, що бреше» — сервер працює не так, як
    # оператор налаштував.
    if ($null -ne $localOverrideState) {
        $unappliedOverrideKeys = @(
            $localOverrideState.Overrides.Keys |
                Where-Object { -not $localOverrideState.Applied.Contains([string]$_) } |
                Sort-Object
        )
        if (@($unappliedOverrideKeys).Count -gt 0) {
            throw (
                "BRAVO.local.config ('$($localOverrideState.Path)'): не вдалося застосувати ключ(і): " +
                ($unappliedOverrideKeys -join ', ') +
                ". Перевірте dot-шлях (кореневий об'єкт і проміжні вузли мають існувати в BRAVO.config)."
            )
        }
    }
    $global:BravoLocalConfigOverrideState = $null

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
        # Ключі з BRAVO.local.config, реально застосовані цим завантаженням
        # (порожньо = файла немає) — операторська прозорість для dry-run/діагностики.
        LocalConfigOverrides = @(
            if ($null -ne $localOverrideState) { @($localOverrideState.Applied) | Sort-Object } else { @() }
        )
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
