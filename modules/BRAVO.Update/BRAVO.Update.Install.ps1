# BRAVO.Update.Install — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Clean install (INS-060…065): Install-BRAVOToolkit за ENGINE_DESIGN.md §9.
# Транзакція повністю журналюється (Journal), корінь і файли, створені
# операцією, записуються в createdOwnership ДО side effect-ів, щоб відкат
# (Invoke-BRAVOInstallRollback, частина Rollback) знав, що саме «наше».
# Фазовий виконавець, Open-BRAVOUpdateOperation (U0-U4), Invoke-BRAVOUpdateAcquireStage (U5-U6), файловий
# набір і копіювання — з частини Deploy; scheduler/validation — з Reconcile і
# Validation. Тут їх не дублюємо: викликаємо за іменем.
#
# Engine не бачить секретів (D7): credentials вводяться окремо, у видимому
# консольному вікні (Get-BRAVOInstallCredentialHandoffCommand).

# Формат записів createdOwnership (контракт Invoke-BRAVOInstallRollback, частина Rollback):
#   dir:<абсолютний корінь>          — каталог створено цією операцією
#   dir:<ключ/з/слешами>             — підкаталог runtime, створений операцією
#   deploykeys:<SHA256 deploy-keys>  — ОДИН запис на всі deploy-ключі (deploy-keys.json в каталозі операції)
#   file:BRAVO.local.config          — intent сіяння (без хешу: файл міг не з'явитись)
#   file:BRAVO.local.config|<SHA256> — засіяний файл (відкат видаляє лише за збігом хешу)
#   marker:preexistingRoot           — корінь існував порожнім і НЕ видаляється відкатом

function Get-BRAVOInstallAdapter {
    <#
    .SYNOPSIS
        Доповнює adapter ключами, які потрібні лише clean install:
        SeedLocalConfig і GetUserProfileRoots (acquire/stage — Deploy part).
    .DESCRIPTION
        Тести передають stub-и під тими самими ключами. Базові ключі
        (TestCredentialPresence тощо) беруться з переданого adapter-а без змін.
          SeedLocalConfig     param([string]$RuntimeRoot, [string]$BackupDestination)
                              -> { Created, Stage, Path, Reasons[] }
          GetUserProfileRoots param() -> string[] (каталоги, у які не можна встановлювати)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        # Корінь staging для робочого каталогу дочірнього скрипта сіяння (H1); порожній = типовий engine.
        [string]$StagingRoot = ''
    )

    $full = @{}
    foreach ($key in @($Adapter.Keys)) { $full[$key] = $Adapter[$key] }
    if (-not $full.ContainsKey('SeedLocalConfig')) {
        $full['SeedLocalConfig'] = {
            param([string]$RuntimeRoot, [string]$BackupDestination)
            Invoke-BRAVOInstallSeedLocalConfigDefault -RuntimeRoot $RuntimeRoot -BackupDestination $BackupDestination -StagingRoot $StagingRoot
        }.GetNewClosure()
    }
    if (-not $full.ContainsKey('GetUserProfileRoots')) {
        $full['GetUserProfileRoots'] = {
            # Правило BRAVO_TASKS_INSTALL.ps1:70-83 (SYSTEM-задачі не можна ставити з профілю
            # користувача). Скрипт виконує side effect-и вже під час dot-source, тому його не
            # викликаємо, а правило реалізовано тут ОДИН раз. Посилюємо: також батьківський
            # каталог профілів (чужі профілі теж не є довіреними для SYSTEM).
            $profileRoot = [Environment]::GetFolderPath('UserProfile')
            $roots = New-Object System.Collections.Generic.List[string]
            if (-not [string]::IsNullOrWhiteSpace($profileRoot)) {
                [void]$roots.Add($profileRoot)
                $parent = [IO.Path]::GetDirectoryName($profileRoot.TrimEnd('\', '/'))
                if (-not [string]::IsNullOrWhiteSpace($parent)) { [void]$roots.Add($parent) }
            }
            return $roots.ToArray()
        }
    }
    return $full
}

function Test-BRAVOInstallRuntimeRootPolicy {
    <#
    .SYNOPSIS
        Політика кореня для clean install (ENGINE_DESIGN §9.1, п. 2).
        Повертає { IsValid, PreexistingEmpty, FullPath, Problems[], Findings[] }; не кидає.
    .DESCRIPTION
        Спільні перевірки шляху (локальний фіксований диск, не UNC, без '..',
        без reparse у самому шляху й предках) і системні каталоги беруться з
        Preflight (Get-BRAVOPreflightPathProblem / Get-BRAVOPreflightSystemPathProblem):
        другої копії правил немає. Додатково тут: не в профілі (правило
        BRAVO_TASKS_INSTALL.ps1:70-83), не перетинається зі State/Staging/Backup/Lock,
        батьківський каталог існує (інакше CreateDirectory мовчки створив би
        предків із нашим DACL поза ownership), корінь відсутній або порожній.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$RuntimeRoot,
        [string]$StateRoot = '',
        [string]$StagingRoot = '',
        [string]$BackupRoot = '',
        [string]$LockRoot = '',
        [string[]]$ProfileRoot = @()
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $preexistingEmpty = $false
    $full = $null
    foreach ($problem in @(Get-BRAVOPreflightPathProblem -Path $RuntimeRoot)) { [void]$problems.Add([string]$problem) }
    if ($problems.Count -eq 0) {
        $full = Get-BRAVOPreflightFullPath -Path $RuntimeRoot
        foreach ($problem in @(Get-BRAVOPreflightSystemPathProblem -Path $full)) { [void]$problems.Add([string]$problem) }
        foreach ($profile in @($ProfileRoot)) {
            if ([string]::IsNullOrWhiteSpace($profile)) { continue }
            if (Test-BRAVOUpdatePathIsUnder -Path $full -Root $profile -AllowEqual) {
                [void]$problems.Add("SYSTEM-завдання не можна встановлювати з профілю користувача: $full.")
                break
            }
        }
        $others = @{ 'State' = $StateRoot; 'Staging' = $StagingRoot; 'Backup' = $BackupRoot; 'Lock' = $LockRoot }
        foreach ($name in @($others.Keys)) {
            $other = [string]$others[$name]
            if ([string]::IsNullOrWhiteSpace($other)) { continue }
            if ((Test-BRAVOUpdatePathIsUnder -Path $full -Root $other -AllowEqual) -or (Test-BRAVOUpdatePathIsUnder -Path $other -Root $full -AllowEqual)) {
                [void]$problems.Add("Каталог встановлення перетинається з каталогом $name ($other).")
            }
        }
        if ($problems.Count -eq 0) {
            if ([IO.File]::Exists($full)) {
                [void]$problems.Add('Шлях існує і є файлом.')
            } elseif ([IO.Directory]::Exists($full)) {
                $entries = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue)
                if ($entries.Count -gt 0) {
                    [void]$problems.Add('Каталог встановлення вже існує і не порожній: чисте встановлення не перезаписує наявні дані (використайте Update/Repair).')
                } else {
                    $preexistingEmpty = $true
                }
            } else {
                $parent = [IO.Path]::GetDirectoryName($full)
                if ([string]::IsNullOrWhiteSpace($parent) -or -not [IO.Directory]::Exists($parent)) {
                    [void]$problems.Add('Батьківський каталог кореня встановлення не існує.')
                }
            }
        }
    }

    $findings = New-Object System.Collections.Generic.List[object]
    foreach ($problem in $problems) {
        [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Install.RootPolicy' -Severity Blocker `
                -Title 'Каталог встановлення не відповідає політиці' -Meaning 'Чисте встановлення в цей каталог небезпечне або неможливе.' `
                -Action 'Оберіть порожній каталог на локальному фіксованому диску поза профілем користувача (наприклад, у Program Files).' -Details $problem))
    }
    return [pscustomobject][ordered]@{
        IsValid          = ($problems.Count -eq 0)
        PreexistingEmpty = $preexistingEmpty
        FullPath         = $full
        Problems         = $problems.ToArray()
        Findings         = $findings.ToArray()
    }
}

function New-BRAVOInstallProtectedDirectory {
    <#
    .SYNOPSIS
        Створює (або застосовує до наявного порожнього) корінь runtime з тим самим DACL, що
        Set-BRAVOProtectedRuntimeAcl: Administrators FC, SYSTEM FC, Users RX, власник
        Administrators; успадкування вимкнено. Повертає { Success, Path, Problems[] }.
    .DESCRIPTION
        Правила ідентичні BRAVO_TASKS_INSTALL.ps1:67-153 (ті самі SID і права; для
        дочірніх елементів — ContainerInherit|ObjectInherit). Відмінність лише для
        процесу без прав адміністратора (тести): власника Administrators призначити
        неможливо, а поточний користувач не мав би запису — тому він додається з
        FullControl. Реалізація — єдина New-BRAVOUpdateProtectedDirectory (Paths, H1):
        тут лише набір правил (Kind Operation = Administrators/SYSTEM FC + Users RX).
        Повторне hardening усіх файлів робить Scheduler-крок. Set-Acl не
        використовується: потребує SeSecurityPrivilege.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $includeCurrent = Test-BRAVOUpdateTrustCurrentUser
        $rule = @(Get-BRAVOUpdateWorkerAclRule -Kind Operation -IncludeCurrentUser:$includeCurrent)
        $result = New-BRAVOUpdateProtectedDirectory -Path $Path -Rule $rule
        if ($result.Success) { return $result }
        return [pscustomobject]@{ Success = $false; Path = $result.Path; Problems = @($result.Problems | ForEach-Object { 'Каталог встановлення ' + $Path + ': ' + [string]$_ }) }
    } catch {
        return [pscustomobject]@{ Success = $false; Path = $Path; Problems = @('Каталог встановлення ' + $Path + ' не створено: ' + $_.Exception.Message) }
    }
}

function Update-BRAVOInstallJournalOwnership {
    <#
    .SYNOPSIS
        Додає (і за потреби замінює) записи createdOwnership ОДНИМ записом журналу.
    .DESCRIPTION
        Add-BRAVOUpdateJournalCreatedOwnership пише журнал на кожен ключ; для сотень
        deploy-ключів це сотні fsync до першого копіювання. Тут — один атомарний запис
        через Write-BRAVOUpdateJournal (валідація й атомарність ті самі).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string[]]$Add = @(),
        [string[]]$Remove = @()
    )

    $current = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Journal.createdOwnership)) {
        $text = [string]$entry
        if ($Remove -ccontains $text) { continue }
        if (-not $current.Contains($text)) { [void]$current.Add($text) }
    }
    foreach ($entry in @($Add)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if (-not $current.Contains($entry)) { [void]$current.Add($entry) }
    }
    $Journal.createdOwnership = $current.ToArray()
    [void](Write-BRAVOUpdateJournal -Journal $Journal -StateRoot $StateRoot)
    return $Journal
}

function Get-BRAVOInstallOwnershipEntry {
    <#
    .SYNOPSIS
        Записи createdOwnership для набору deploy-ключів: підкаталоги (від найменшої
        глибини) і файли з хешами. Некоректний ключ ('..', абсолютний) — виняток.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$DeployKeys)

    $directories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $keys = @()
    if ($DeployKeys -is [System.Collections.IDictionary]) {
        $keys = @($DeployKeys.Keys)
    } else {
        $keys = @($DeployKeys.PSObject.Properties | ForEach-Object { $_.Name })
    }
    foreach ($key in ($keys | Sort-Object)) {
        $normalized = ([string]$key) -replace '\\', '/'
        $parts = @($normalized -split '/')
        if ($normalized -match '^[A-Za-z]:' -or $normalized.StartsWith('/') -or $parts -contains '..' -or $parts -contains '.' -or $parts -contains '') {
            throw "BRAVO.Update: недопустимий ключ deploy '$key'."
        }
        for ($index = 1; $index -lt $parts.Count; $index++) {
            [void]$directories.Add([string]::Join('/', $parts[0..($index - 1)]))
        }
    }
    $ordered = @($directories | Sort-Object -Property @{ Expression = { @($_ -split '/').Count } }, @{ Expression = { $_ } })
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($directory in $ordered) { [void]$entries.Add('dir:' + $directory) }
    return $entries.ToArray()
}

function Invoke-BRAVOInstallSeedLocalConfigDefault {
    <#
    .SYNOPSIS
        Типова реалізація adapter.SeedLocalConfig: сіє BRAVO.local.config у ДОЧІРНЬОМУ
        powershell.exe з розгорнутого runtime. Повертає { Created, Stage, Path, Reasons[] }.
    .DESCRIPTION
        Модулі Configurator не завантажуються в процес engine: вони імпортуються лише з
        runtime, цілісність якого звіряється з RUNTIME_MANIFEST.json безпосередньо перед
        запуском (Test-BRAVODeployRuntimeMatchesManifest), як Assert-BRAVOInstallBundleIntegrity
        у deploy\Install-BRAVOServer.ps1. Наявний файл ніколи не змінюється
        (New-BRAVOConfiguratorSeedLocalConfig повертає Stage=Exists).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][ValidateSet('Cloud', 'CloudAndSamba', 'SambaOnly', 'LocalOnly')][string]$BackupDestination,
        [string]$StagingRoot = ''
    )

    $localConfigPath = Join-Path $RuntimeRoot 'BRAVO.local.config'
    $fail = {
        param([string]$Stage, [string]$Reason)
        [pscustomobject]@{ Created = $false; Stage = $Stage; Path = $localConfigPath; Reasons = @($Reason) }
    }
    $integrity = Test-BRAVODeployRuntimeMatchesManifest -RuntimeRoot $RuntimeRoot -ManifestPath (Join-Path $RuntimeRoot 'RUNTIME_MANIFEST.json')
    if (-not $integrity.IsMatch) {
        return (& $fail 'Integrity' ('Цілісність розгорнутого runtime не підтверджена: ' + (@($integrity.Problems) -join '; ')))
    }
    # H1: скрипт сіяння виконується елевованим процесом, тож лежить лише у захищеному
    # робочому каталозі під staging engine (не в %TEMP%) і видаляється guarded-видалювачем.
    if ([string]::IsNullOrWhiteSpace($StagingRoot)) { $StagingRoot = [string](Get-BRAVOUpdateDefaultPaths).StagingRoot }
    $work = New-BRAVOUpdateChildWorkDirectory -Root $StagingRoot
    if (-not $work.Success) { return (& $fail 'WorkDirectory' ('Робочий каталог не створено: ' + (@($work.Problems) -join '; '))) }
    $workDir = $work.WorkDirectory
    try {
        $childPath = Join-Path $workDir 'Seed-LocalConfig.ps1'
        $resultPath = Join-Path $workDir 'seed.json'
        # Шляхи передаються аргументами (кирилиця/апостроф не потрапляють у текст скрипта).
        $lines = @(
            'param([string]$RuntimeRoot, [string]$BackupDestination, [string]$ResultPath)',
            'Set-StrictMode -Version 2.0',
            '$ErrorActionPreference = ''Stop''',
            'try {',
            '    foreach ($name in @(''Effective'', ''Persistence'', ''Presets'')) {',
            '        Import-Module -Name (Join-Path $RuntimeRoot (''modules\BRAVO.Configurator\BRAVO.Configurator.'' + $name + ''.psm1'')) -Force -ErrorAction Stop',
            '    }',
            '    $destinationProfile = Get-BRAVOConfiguratorBackupDestinationProfile -Destination $BackupDestination',
            '    $seed = New-BRAVOConfiguratorSeedLocalConfig -RuntimeRoot $RuntimeRoot -ConfigDirectory $RuntimeRoot -Overrides $destinationProfile.Overrides',
            '    $out = [ordered]@{ Created = [bool]$seed.Created; Stage = [string]$seed.Stage; Path = [string]$seed.Path; Reasons = @($seed.Reasons) }',
            '} catch {',
            '    $out = [ordered]@{ Created = $false; Stage = ''Exception''; Path = ''''; Reasons = @([string]$_.Exception.Message) }',
            '}',
            '[IO.File]::WriteAllText($ResultPath, ($out | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($true)))'
        )
        [IO.File]::WriteAllText($childPath, ([string]::Join([Environment]::NewLine, $lines)), (New-Object System.Text.UTF8Encoding($true)))
        $installRun = Invoke-BRAVOUpdateChildProcess -ScriptPath $childPath -ScriptArgument @($RuntimeRoot, $BackupDestination, $resultPath) -TimeoutSeconds 300
        if ($installRun.TimedOut) { return (& $fail 'Timeout' 'Сіяння BRAVO.local.config перевищило час очікування.') }
        if (-not [IO.File]::Exists($resultPath)) { return (& $fail 'Child' ('Дочірній процес не повернув результат (код ' + [string]$installRun.ExitCode + ').')) }
        $parsed = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
        return [pscustomobject]@{ Created = [bool]$parsed.Created; Stage = [string]$parsed.Stage; Path = [string]$parsed.Path; Reasons = @($parsed.Reasons) }
    } finally {
        Remove-BRAVOUpdateChildWorkDirectory -WorkInfo $work
    }
}

function Install-BRAVOToolkit {
    <#
    .SYNOPSIS
        Чисте встановлення BRAVO Toolkit у порожній каталог (ENGINE_DESIGN §9.1).
    .DESCRIPTION
        Політика кореня → U0-U4 (Open-BRAVOUpdateOperation, частина Deploy: актуальність плану,
        lifecycle lock, відкриті журнали, ConsumedPlans, каталог операції, журнал, контекст) →
        U5-U6 (Invoke-BRAVOUpdateAcquireStage) → U7 (повторна перевірка плану й кореня) →
        U9 operation lock → U10 знімок version-state → U11 mutationStarted (межа) →
        CreateRuntimeRoot → Deploy → SeedLocalConfig → [ConfigureScheduler лише якщо
        credentials Found] → Validate(Install) → [Activate: Install → Inactive] → Commit.
        Збій: Resolve-BRAVOUpdateOperationFailure (до межі — Abandoned і прибирання; після —
        Invoke-BRAVORollback, Install-гілка). SimulatedCrash не перехоплюється: журнал лишається
        Open для Invoke-BRAVORecovery. Backup на install немає: старого runtime не існує.
        Передумови, загальні для всіх операцій (U0-U7), не дублюються: їх виконує Deploy part.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][hashtable]$Adapter,
        [Parameter(Mandatory = $true)][ValidateSet('Cloud', 'CloudAndSamba', 'SambaOnly', 'LocalOnly')][string]$BackupDestination,
        [string]$RuntimeRoot = '',
        [string]$StateRoot = '',
        [string]$LockRoot = '',
        [string]$StagingRoot = '',
        [string]$BackupRoot = '',
        [string]$OperationLockPath = '',
        [string]$VersionStatePath = '',
        [string]$SourcePath = '',
        [string]$ChecksumPath = '',
        [string]$ManifestPath = '',
        [scriptblock]$Downloader = $null,
        [string]$RepositoryBaseUri = '',
        [hashtable]$FaultInjection = $null
    )

    $startedUtc = Get-BRAVOUpdateUtcNowText
    # Корені: явні параметри; відсутні — з плану (runtime/staging/backup) або з
    # Get-BRAVOUpdateDefaultPaths (єдине місце production-значень).
    $defaults = $null
    foreach ($name in @('StateRoot', 'LockRoot', 'OperationLockPath', 'VersionStatePath')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-Variable -Name $name -ValueOnly))) {
            if ($null -eq $defaults) { $defaults = Get-BRAVOUpdateDefaultPaths }
            Set-Variable -Name $name -Value ([string]$defaults.$name)
        }
    }
    foreach ($pair in @(@('RuntimeRoot', 'runtimeRoot'), @('StagingRoot', 'stagingRoot'), @('BackupRoot', 'backupRoot'))) {
        if ([string]::IsNullOrWhiteSpace([string](Get-Variable -Name $pair[0] -ValueOnly))) {
            Set-Variable -Name $pair[0] -Value ([string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name $pair[1] -Default ''))
        }
    }
    $earlyFail = {
        param([string]$Reason, $Finding)
        New-BRAVOUpdateOperationResult -Plan $Plan -Status Failed -ReasonCode $Reason -Findings @($Finding) -StartedUtc $startedUtc
    }

    # --- Передумови без side effect-ів ---------------------------------------------------------
    if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE'))) {
        return (& $earlyFail 'Blocked' (New-BRAVOUpdateFinding -Id 'Operation.AllowDowngradeSet' -Severity Blocker -Title 'У середовищі задано BRAVO_ALLOW_DOWNGRADE' `
                    -Meaning 'Installer не працює при вимкненому захисті від відкату версії.' -Action 'Приберіть змінну BRAVO_ALLOW_DOWNGRADE і повторіть.' -ExitCodeHint 35))
    }
    if ([string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'action' -Default '') -cne 'Install') {
        return (& $earlyFail 'Blocked' (New-BRAVOUpdateFinding -Id 'Install.WrongPlanAction' -Severity Blocker -Title 'План не є планом чистого встановлення' `
                    -Meaning 'Install-BRAVOToolkit приймає лише план з action=Install.' -Action 'Побудуйте новий план для встановлення.'))
    }
    $fullAdapter = Get-BRAVOInstallAdapter -Adapter $Adapter -StagingRoot $StagingRoot
    $profileRoots = @(& $fullAdapter.GetUserProfileRoots)
    $installPolicy = Test-BRAVOInstallRuntimeRootPolicy -RuntimeRoot $RuntimeRoot -StateRoot $StateRoot -StagingRoot $StagingRoot -BackupRoot $BackupRoot -LockRoot $LockRoot -ProfileRoot $profileRoots
    if (-not $installPolicy.IsValid) {
        return (New-BRAVOUpdateOperationResult -Plan $Plan -Status Failed -ReasonCode Blocked -Findings @($installPolicy.Findings) -StartedUtc $startedUtc)
    }
    $RuntimeRoot = [string]$installPolicy.FullPath
    $paths = [pscustomobject][ordered]@{
        RuntimeRoot = $RuntimeRoot; StateRoot = $StateRoot; LockRoot = $LockRoot; StagingRoot = $StagingRoot
        BackupRoot = $BackupRoot; OperationLockPath = $OperationLockPath; VersionStatePath = $VersionStatePath
    }

    $context = $null
    try {
        # U0-U4: спільна частина операції (Deploy part).
        $opened = $null
        try {
            $opened = Open-BRAVOUpdateOperation -Plan $Plan -Adapter $fullAdapter -Paths $paths -FaultInjection $FaultInjection
        } catch {
            if ((Get-BRAVOUpdateExceptionKind -ErrorRecord $_).Kind -ceq 'Crash') { throw }
            return (& $earlyFail 'Error' (New-BRAVOUpdateFinding -Id 'Operation.StartFailed' -Severity Blocker -Title 'Не вдалося розпочати операцію' `
                        -Meaning 'Підготовку (lock, журнал, реєстр планів) не завершено; змін runtime немає.' -Action 'Перевірте каталог State та права доступу і повторіть.' -Details ([string]$_.Exception.Message)))
        }
        if ($null -ne $opened.EarlyResult) { return $opened.EarlyResult }
        $context = $opened.Context
        $context.Data['Deferred'] = $false
        $context.Data['Tasks'] = @()
        $context.Data['InstallValidation'] = 'Pass'
        $context.Data['PreexistingEmpty'] = [bool]$installPolicy.PreexistingEmpty

        try {
            # U5-U6: отримання, перевірка, розпакування, staged-валідація, файловий набір.
            [void](Invoke-BRAVOUpdateAcquireStage -Context $context -SourcePath $SourcePath -ChecksumPath $ChecksumPath -ManifestPath $ManifestPath -Downloader $Downloader -RepositoryBaseUri $RepositoryBaseUri)

            # U7: повторна перевірка плану і політики кореня (TOCTOU між preflight і межею).
            Invoke-BRAVOUpdatePlanRecheck -Context $context
            $policyAgain = Test-BRAVOInstallRuntimeRootPolicy -RuntimeRoot $RuntimeRoot -StateRoot $StateRoot -StagingRoot $StagingRoot -BackupRoot $BackupRoot -LockRoot $LockRoot -ProfileRoot $profileRoots
            if (-not $policyAgain.IsValid) {
                foreach ($finding in @($policyAgain.Findings)) { Add-BRAVOUpdateContextFinding -Context $context -Finding $finding }
                throw (New-BRAVOUpdateTypedException -Message 'Каталог встановлення змінився й не відповідає політиці.' -Kind Blocked -FindingId 'Install.RootPolicy')
            }

            # U9: канонічний operation lock ДО межі (зайнятий lock не повинен давати фіктивний RolledBack).
            Invoke-BRAVOUpdateEnterOperationLock -Context $context

            # U10: знімок version-state для відкату (§7.2). Знімків scheduler/site-config немає:
            # runtime і задач ще не існує (legacy-задачі — blocker preflight).
            [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'Baseline' -ProgressPhase Backup -Percent 60 -Action {
                    param($Context)
                    $versionSnapshot = Get-BRAVOVersionStateSnapshot -VersionStatePath $Context.Paths.VersionStatePath -OperationDirectory $Context.OperationDirectory
                    $Context.Data['VersionStateSnapshot'] = $versionSnapshot
                    [void](Set-BRAVOUpdateJournalField -Journal $Context.Journal -StateRoot $Context.Paths.StateRoot -Name 'versionState' -Value ([pscustomobject][ordered]@{
                                present         = (Get-BRAVOUpdatePropertyValue -InputObject $versionSnapshot -Name 'present')
                                sha256          = (Get-BRAVOUpdatePropertyValue -InputObject $versionSnapshot -Name 'sha256')
                                recordedVersion = (Get-BRAVOUpdatePropertyValue -InputObject $versionSnapshot -Name 'recordedVersion')
                                snapshotPath    = (Get-BRAVOUpdatePropertyValue -InputObject $versionSnapshot -Name 'snapshotPath')
                            }))
                })

            # U11: MUTATION BOUNDARY.
            Start-BRAVOUpdateMutation -Context $context

            # --- CreateRuntimeRoot ------------------------------------------------------------
            [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'CreateRuntimeRoot' -ProgressPhase Deploy -Durable -Percent 65 -Action {
                    param($Context)
                    # Ownership — ДО side effect-у: збій між записом і створенням відкат переживе
                    # (відсутній каталог просто пропускається).
                    if ($Context.Data['PreexistingEmpty']) {
                        [void](Update-BRAVOInstallJournalOwnership -Journal $Context.Journal -StateRoot $Context.Paths.StateRoot -Add @('marker:preexistingRoot'))
                    } else {
                        [void](Update-BRAVOInstallJournalOwnership -Journal $Context.Journal -StateRoot $Context.Paths.StateRoot -Add @('dir:' + $Context.Paths.RuntimeRoot))
                    }
                    $created = New-BRAVOInstallProtectedDirectory -Path $Context.Paths.RuntimeRoot
                    if (-not $created.Success) { throw ('Корінь встановлення не створено: ' + (@($created.Problems) -join '; ')) }
                })

            # --- Deploy -----------------------------------------------------------------------
            [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'Deploy' -ProgressPhase Deploy -Durable -Percent 70 -Action {
                    param($Context)
                    # Один запис deploykeys (хеш deploy-keys.json) + каталоги — до першого копіювання;
                    # хеші файлів відкат бере з deploy-keys.json.
                    $directoryEntries = @(Get-BRAVOInstallOwnershipEntry -DeployKeys $Context.Data['FileSet'].DeployKeys)
                    $ownership = @('deploykeys:' + ([string]$Context.Data['KeySet'].Sha256).ToUpperInvariant()) + $directoryEntries
                    [void](Update-BRAVOInstallJournalOwnership -Journal $Context.Journal -StateRoot $Context.Paths.StateRoot -Add $ownership)
                    $deployed = Invoke-BRAVORuntimeDeploy -Context $Context -StagedRoot ([string]$Context.Data['StagedRoot']) -FileSet $Context.Data['FileSet']
                    if (@(Get-BRAVOUpdateArrayProperty -InputObject $deployed -Name 'Errors').Count -gt 0) {
                        throw (New-BRAVOUpdateTypedException -Message ('Розгортання файлів не вдалося: ' + (@($deployed.Errors) -join '; ')) -Kind Error -FindingId 'Deploy.Failed')
                    }
                    $Context.Data['Deployed'] = $deployed
                })

            # --- SeedLocalConfig --------------------------------------------------------------
            [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'SeedLocalConfig' -ProgressPhase Configure -Durable -Percent 75 -Action {
                    param($Context)
                    $seedRoot = [string]$Context.Paths.RuntimeRoot
                    $seedPath = Join-Path $seedRoot 'BRAVO.local.config'
                    # Наявний файл — не «наш»: не журналюємо ownership і не перезаписуємо.
                    if ([IO.File]::Exists($seedPath)) { throw 'BRAVO.local.config уже існує в новому корені: сіяння не перезаписує файл.' }
                    $intent = 'file:BRAVO.local.config'
                    [void](Update-BRAVOInstallJournalOwnership -Journal $Context.Journal -StateRoot $Context.Paths.StateRoot -Add @($intent))
                    $seed = & $Context.Adapter['SeedLocalConfig'] $seedRoot $BackupDestination
                    if (-not [bool]$seed.Created) {
                        [void](Update-BRAVOInstallJournalOwnership -Journal $Context.Journal -StateRoot $Context.Paths.StateRoot -Remove @($intent))
                        throw ('BRAVO.local.config не створено (' + [string](Get-BRAVOUpdatePropertyValue -InputObject $seed -Name 'Stage' -Default '') + '): ' + (@(Get-BRAVOUpdatePropertyValue -InputObject $seed -Name 'Reasons' -Default @()) -join ' '))
                    }
                    $hash = (Get-FileHash -LiteralPath $seedPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
                    [void](Update-BRAVOInstallJournalOwnership -Journal $Context.Journal -StateRoot $Context.Paths.StateRoot -Remove @($intent) -Add @($intent + '|' + $hash))
                })

            # --- Scheduler: лише якщо credentials Found (інакше відкладено) -----------------------
            $presence = & $fullAdapter.TestCredentialPresence $RuntimeRoot 'Required'
            $presenceValue = [string](Get-BRAVOUpdatePropertyValue -InputObject $presence -Name 'Presence' -Default 'Unknown')
            $schedulerSnapshot = $null
            if ($presenceValue -ceq 'Found') {
                [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'ConfigureScheduler' -ProgressPhase Configure -Durable -Percent 80 -Action {
                        param($Context)
                        $snapshot = Get-BRAVOSchedulerSnapshot -Adapter $Context.Adapter -RuntimeRoot $Context.Paths.RuntimeRoot
                        $Context.Data['SchedulerSnapshot'] = $snapshot
                        $reconcile = Invoke-BRAVOSchedulerReconcile -Context $Context -Snapshot $snapshot
                        $Context.Data['SchedulerReconcile'] = $reconcile
                        $Context.Data['Tasks'] = @(Get-BRAVOUpdateArrayProperty -InputObject $reconcile -Name 'CreatedTasks')
                        # Той самий контракт, що в Deploy: дерево процесів BRAVO_SETUP не підтверджено завершеним -> Critical
                        # без подальших змін (уцілілий процес міг продовжувати реєструвати задачі).
                        if ([bool](Get-BRAVOUpdatePropertyValue -InputObject $reconcile -Name 'TreeNotContained' -Default $false)) {
                            throw (New-BRAVOUpdateTypedException -Message 'Дерево процесів налаштування планувальника не підтверджено завершеним.' -Kind ProcessTreeNotContained -FindingId 'Process.TreeNotContained' -Action 'Потрібне ручне втручання: переконайтесь, що процеси BRAVO_SETUP/guard/self-test завершено (за потреби перезавантажте сервер), потім виконайте відновлення.')
                        }
                        $verdict = [string](Get-BRAVOUpdatePropertyValue -InputObject $reconcile -Name 'Verdict' -Default 'FAIL')
                        if ($verdict -ceq 'FAIL') {
                            throw (New-BRAVOUpdateTypedException -Message ('Реєстрація задач завершилась помилкою: ' + ((@(Get-BRAVOUpdateArrayProperty -InputObject $reconcile -Name 'Problems') | Select-Object -First 5) -join '; ')) -Kind Error -FindingId 'Scheduler.ReconcileFailed')
                        }
                        if ($verdict -ceq 'PASS_WITH_WARNING') {
                            Add-BRAVOUpdateContextFinding -Context $Context -Finding (New-BRAVOUpdateFinding -Id 'Install.SchedulerWarning' -Severity Warning -Title 'Реєстрація задач завершилась із попередженнями' `
                                    -Meaning 'Задачі зареєстровано, але вимагають уваги.' -Action 'Перегляньте журнал BRAVO_SETUP.')
                        }
                    })
            } else {
                $context.Data['Deferred'] = $true
                Add-BRAVOUpdateContextFinding -Context $context -Finding (New-BRAVOUpdateFinding -Id 'Install.SchedulerDeferred' -Severity Warning -Title 'Реєстрацію планувальника відкладено' `
                        -Meaning 'Облікові дані ще не введено (або їх стан невідомий): задачі не створюються, архівація не працюватиме.' `
                        -Action 'Введіть облікові дані у вікні консолі, потім виконайте Repair зі scope Scheduler і підтвердіть активацію задач.' -Details ('credentialPresence=' + $presenceValue))
            }

            # --- Validate (Install) -------------------------------------------------------------
            [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'Validate' -ProgressPhase Validate -Percent 88 -Action {
                    param($Context)
                    $baseline = Get-BRAVOSiteConfigurationBaseline -RuntimeRoot $Context.Paths.RuntimeRoot
                    $validation = Test-BRAVODeploymentValidation -Context $Context -Mode Install -ExpectedVersion ([string](Get-BRAVOUpdatePropertyValue -InputObject $Context.Plan -Name 'targetVersion' -Default '')) `
                        -ExpectedManifestPath (Join-Path $Context.Paths.RuntimeRoot 'RUNTIME_MANIFEST.json') -SiteBaseline $baseline
                    foreach ($item in @(Get-BRAVOUpdateArrayProperty -InputObject $validation -Name 'Items')) { $Context.Validation.Add($item) }
                    if ([bool](Get-BRAVOUpdatePropertyValue -InputObject $validation -Name 'TreeNotContained' -Default $false)) {
                        throw (New-BRAVOUpdateTypedException -Message 'Дерево процесів валідації не підтверджено завершеним.' -Kind ProcessTreeNotContained -FindingId 'Process.TreeNotContained' -Action 'Потрібне ручне втручання: переконайтесь, що процеси BRAVO_SETUP/guard/self-test завершено (за потреби перезавантажте сервер), потім виконайте відновлення.')
                    }
                    $validationStatus = [string](Get-BRAVOUpdatePropertyValue -InputObject $validation -Name 'Status' -Default 'Fail')
                    $Context.Data['InstallValidation'] = $validationStatus
                    if ($validationStatus -ceq 'Warn') {
                        Add-BRAVOUpdateContextFinding -Context $Context -Finding (New-BRAVOUpdateFinding -Id 'Validate.Warnings' -Severity Warning -Title 'Валідація завершилась із попередженнями' -Meaning 'Деякі перевірки дали попередження; див. validation.')
                    } elseif ($validationStatus -cne 'Pass') {
                        $failedNames = @($Context.Validation.ToArray() | Where-Object { [string](Get-BRAVOUpdatePropertyValue -InputObject $_ -Name 'status') -ceq 'Fail' } | ForEach-Object { [string](Get-BRAVOUpdatePropertyValue -InputObject $_ -Name 'name') })
                        throw (New-BRAVOUpdateTypedException -Message ('Валідація встановлення не пройшла: ' + ($failedNames -join ', ')) -Kind Verification -FindingId 'Validate.Failed' -Action 'Виконано відкат; перегляньте validation у результаті.')
                    }
                })

            if (Test-BRAVOUpdateCancelRequested -Context $context) {
                throw (New-BRAVOUpdateTypedException -Message 'Операцію скасовано перед завершенням: виконується відкат.' -Kind CancelAfterMutation)
            }

            # --- Activate: Install → Inactive (D6). Задачі вмикає лише явне підтвердження оператора.
            $taskActivation = [pscustomobject][ordered]@{ state = 'Inactive'; tasks = @() }
            if (-not $context.Data['Deferred']) {
                $outcomeStatus = 'Success'
                foreach ($item in $context.Findings) { if ([string]$item.severity -ceq 'Warning') { $outcomeStatus = 'SuccessWithWarnings' } }
                $activationPolicy = [string](Get-BRAVOUpdatePropertyValue -InputObject (Get-BRAVOUpdatePropertyValue -InputObject (Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'changes') -Name 'scheduler') -Name 'activationPolicy' -Default 'ActivateOnSuccessOnly')
                try {
                    $activation = Invoke-BRAVOUpdatePhase -Context $context -Phase 'Activate' -ProgressPhase Activate -Durable -IgnoreCancel -Percent 94 -Action {
                        param($Context)
                        Set-BRAVOTaskActivation -Policy $activationPolicy -Snapshot $Context.Data['SchedulerSnapshot'] -Adapter $Context.Adapter -OutcomeStatus $outcomeStatus -Action Install
                    }
                    $taskActivation = Get-BRAVOUpdatePropertyValue -InputObject $activation -Name 'TaskActivation' -Default $taskActivation
                    foreach ($activationFinding in @(Get-BRAVOUpdateArrayProperty -InputObject $activation -Name 'Findings')) { Add-BRAVOUpdateContextFinding -Context $context -Finding $activationFinding }
                } catch {
                    if ((Get-BRAVOUpdateExceptionKind -ErrorRecord $_).Kind -ceq 'Crash') { throw }
                    # Після успішної Validate збій Activate не відкочує встановлення: задачі лишаються вимкненими.
                    $taskActivation = [pscustomobject][ordered]@{ state = 'Unknown'; tasks = @() }
                    Add-BRAVOUpdateContextFinding -Context $context -Finding (New-BRAVOUpdateFinding -Id 'Activate.Failed' -Severity Warning -Title 'Не вдалося підтвердити стан задач після встановлення' `
                            -Meaning 'Встановлення перевірено й збережено, але стан активації задач невідомий.' -Action 'Перевірте стан задач у планувальнику.' -Details ([string]$_.Exception.Message))
                }
            }

            # --- Commit: журнал Committed ПІСЛЯ фази (збій до цього ще веде до відкату) ----------
            [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'Commit' -ProgressPhase Commit -Durable -IgnoreCancel -Percent 99 -Action {
                    param($Context)
                    $null = $Context.Journal
                })
            [void](Set-BRAVOUpdateJournalState -Journal $context.Journal -State Committed -StateRoot $StateRoot)
            Close-BRAVOUpdateOperationHandles -Context $context
            try {
                $removal = Remove-BRAVOUpdateOperationDirectory -Path (Join-Path $StagingRoot $context.OperationId) -ExpectedParent $StagingRoot -OperationId $context.OperationId -AllowedRoot @($StagingRoot)
                if (@($removal.Problems).Count -gt 0) {
                    Add-BRAVOUpdateContextFinding -Context $context -Finding (New-BRAVOUpdateFinding -Id 'Commit.StagingNotRemoved' -Severity Warning -Title 'Staging операції видалено не повністю' `
                            -Meaning 'Залишки не впливають на роботу; їх можна видалити вручну.' -Details ((@($removal.Problems) | Select-Object -First 5) -join '; '))
                }
            } catch {
                Add-BRAVOUpdateContextFinding -Context $context -Finding (New-BRAVOUpdateFinding -Id 'Commit.StagingNotRemoved' -Severity Warning -Title 'Staging операції не видалено' `
                        -Meaning 'Залишки не впливають на роботу; їх можна видалити вручну.' -Details ([string]$_.Exception.Message))
            }

            $finalStatus = 'Success'
            foreach ($item in $context.Findings) { if ([string]$item.severity -ceq 'Warning') { $finalStatus = 'SuccessWithWarnings' } }
            foreach ($item in $context.Validation) { if ([string](Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'status') -ceq 'Warn') { $finalStatus = 'SuccessWithWarnings' } }
            if ($context.Data['Deferred'] -or ([string](Get-BRAVOUpdatePropertyValue -InputObject $taskActivation -Name 'state' -Default '') -ceq 'Unknown')) { $finalStatus = 'SuccessWithWarnings' }
            return (New-BRAVOUpdateOperationResult -Plan $Plan -Context $context -Status $finalStatus `
                    -Findings @($context.Findings.ToArray()) -Validation @($context.Validation.ToArray()) -TaskActivation $taskActivation `
                    -InstalledVersion (Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'targetVersion') -LastPhase $context.LastPhase -MutationStarted $true `
                    -JournalPath (Get-BRAVOUpdateJournalPath -StateRoot $StateRoot -OperationId $context.OperationId) -StartedUtc $startedUtc)
        } catch {
            return (Resolve-BRAVOUpdateOperationFailure -Context $context -ErrorRecord $_ -StartedUtc $startedUtc)
        }
    } finally {
        Close-BRAVOUpdateOperationHandles -Context $context
    }
}

function Get-BRAVOInstallCredentialHandoffCommand {
    <#
    .SYNOPSIS
        Команда видимого консольного вікна для введення облікових даних (ENGINE_DESIGN §9.2, D7).
        Повертає { FilePath, ArgumentList[], ArgumentString, WorkingDirectory, RequiresVisibleConsole }.
    .DESCRIPTION
        Нічого не запускає і не приймає секретів: лише шлях до runtime. Викликач (CLI/GUI)
        відкриває вікно сам (Start-Process без -WindowStyle Hidden), далі Repair -Scope Scheduler
        і явна активація задач.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)

    if ([string]::IsNullOrWhiteSpace($RuntimeRoot) -or $RuntimeRoot -notmatch '^[A-Za-z]:[\\/]') {
        throw 'BRAVO.Update: для команди credentials потрібен абсолютний локальний шлях runtime.'
    }
    $root = Get-BRAVOUpdateFullPath -Path $RuntimeRoot
    $setupScript = Join-Path $root 'BRAVO_SETUP.ps1'
    $arguments = @('-NoProfile', '-File', $setupScript, '-Action', 'Credentials')
    $argumentString = '-NoProfile -File ' + (ConvertTo-BRAVOUpdateQuotedArgument -Value $setupScript) + ' -Action Credentials'
    return [pscustomobject][ordered]@{
        FilePath               = 'powershell.exe'
        ArgumentList           = $arguments
        ArgumentString         = $argumentString
        WorkingDirectory       = $root
        RequiresVisibleConsole = $true
    }
}
