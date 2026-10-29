# BRAVO.Update.Install — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Clean install (INS-060…065): Install-BRAVOToolkit за ENGINE_DESIGN.md §9.
# Транзакція повністю журналюється (Journal), корінь і файли, створені
# операцією, записуються в createdOwnership ДО side effect-ів, щоб відкат
# (Invoke-BRAVOInstallRollback, частина Rollback) знав, що саме «наше».
# Фазовий виконавець (Invoke-BRAVOUpdatePhase), контекст операції, файловий
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
        SeedLocalConfig, StageRelease, GetUserProfileRoots.
    .DESCRIPTION
        Тести передають stub-и під тими самими ключами. Базові ключі
        (TestCredentialPresence тощо) беруться з переданого adapter-а без змін.
          SeedLocalConfig     param([string]$RuntimeRoot, [string]$BackupDestination)
                              -> { Created, Stage, Path, Reasons[] }
          StageRelease        param($Plan, [string]$SourcePath, [string]$StagingDirectory, $Downloader)
                              -> { Success, StagedRoot, Problems[], Findings[] }
          GetUserProfileRoots param() -> string[] (каталоги, у які не можна встановлювати)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Adapter)

    $full = @{}
    foreach ($key in @($Adapter.Keys)) { $full[$key] = $Adapter[$key] }
    if (-not $full.ContainsKey('SeedLocalConfig')) {
        $full['SeedLocalConfig'] = {
            param([string]$RuntimeRoot, [string]$BackupDestination)
            Invoke-BRAVOInstallSeedLocalConfigDefault -RuntimeRoot $RuntimeRoot -BackupDestination $BackupDestination
        }
    }
    if (-not $full.ContainsKey('StageRelease')) {
        $full['StageRelease'] = {
            param($Plan, [string]$SourcePath, [string]$StagingDirectory, $Downloader)
            Invoke-BRAVOInstallStageReleaseDefault -Plan $Plan -SourcePath $SourcePath -StagingDirectory $StagingDirectory -Downloader $Downloader
        }
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
        неелевованого процесу (тести): власника Administrators призначити неможливо, а
        поточний користувач не мав би запису — тому він додається з FullControl (так само,
        як у New-BRAVOUpdatePrivateDirectory). У production worker елевований, додаткового
        принципала немає. Повторне hardening усіх файлів робить Scheduler-крок.
        Set-Acl не використовується: потребує SeSecurityPrivilege.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $problems = New-Object System.Collections.Generic.List[string]
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $exists = [IO.Directory]::Exists($fullPath)
        $administrators = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
        $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
        $isElevatedAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $currentSid = $currentIdentity.User

        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $propagation = [Security.AccessControl.PropagationFlags]::None
        $allow = [Security.AccessControl.AccessControlType]::Allow
        $fullControl = [Security.AccessControl.FileSystemRights]::FullControl
        $readExecute = [Security.AccessControl.FileSystemRights]::ReadAndExecute

        $expected = New-Object System.Collections.Generic.List[object]
        [void]$expected.Add(@{ Sid = $administrators; Rights = $fullControl })
        [void]$expected.Add(@{ Sid = $system; Rights = $fullControl })
        [void]$expected.Add(@{ Sid = $users; Rights = $readExecute })
        if (-not $isElevatedAdmin -and $currentSid.Value -ne $system.Value -and $currentSid.Value -ne $administrators.Value) {
            [void]$expected.Add(@{ Sid = $currentSid; Rights = $fullControl })
        }

        $security = New-Object Security.AccessControl.DirectorySecurity
        $security.SetAccessRuleProtection($true, $false)
        if ($isElevatedAdmin) { $security.SetOwner($administrators) }
        foreach ($item in $expected) {
            $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($item.Sid, $item.Rights, $inheritance, $propagation, $allow)))
        }

        if ($exists) {
            if (@(Get-ChildItem -LiteralPath $fullPath -Force).Count -gt 0) { throw 'каталог не порожній.' }
            $directoryInfo = New-Object System.IO.DirectoryInfo($fullPath)
            $existingAcl = $directoryInfo.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
            $existingAcl.SetAccessRuleProtection($true, $false)
            foreach ($oldRule in @($existingAcl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) {
                [void]$existingAcl.RemoveAccessRuleSpecific($oldRule)
            }
            foreach ($newRule in @($security.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) {
                $existingAcl.AddAccessRule($newRule)
            }
            $directoryInfo.SetAccessControl($existingAcl)
        } else {
            $createWithSecurity = [IO.Directory].GetMethod('CreateDirectory', [Type[]]@([string], [Security.AccessControl.DirectorySecurity]))
            if ($null -ne $createWithSecurity) {
                [void][IO.Directory]::CreateDirectory($fullPath, $security)
            } else {
                [void][IO.FileSystemAclExtensions]::CreateDirectory($security, $fullPath)
            }
        }

        # Перевірка результату: рівно очікуваний набір явних правил.
        $actual = Get-Acl -LiteralPath $fullPath
        if (-not $actual.AreAccessRulesProtected) { [void]$problems.Add('успадкування прав не вимкнено') }
        $rules = @($actual.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        foreach ($rule in $rules) {
            $match = $null
            foreach ($item in $expected) { if ([string]$rule.IdentityReference.Value -eq $item.Sid.Value) { $match = $item } }
            if ($rule.IsInherited -or $null -eq $match -or $rule.AccessControlType -ne $allow -or
                (($rule.FileSystemRights -band $match.Rights) -ne $match.Rights)) {
                [void]$problems.Add('зайве або неповне правило ' + [string]$rule.IdentityReference.Value + ' ' + [string]$rule.FileSystemRights)
            }
        }
        foreach ($item in $expected) {
            if (@($rules | Where-Object { [string]$_.IdentityReference.Value -eq $item.Sid.Value }).Count -eq 0) {
                [void]$problems.Add('немає правила для ' + $item.Sid.Value)
            }
        }
        if ($problems.Count -gt 0) {
            # Створений нами порожній каталог із хибним DACL не лишаємо (лише порожній, нерекурсивно).
            if (-not $exists) { try { [IO.Directory]::Delete($fullPath, $false) } catch { $null = $_ } }
            return [pscustomobject]@{ Success = $false; Path = $fullPath; Problems = $problems.ToArray() }
        }
        return [pscustomobject]@{ Success = $true; Path = $fullPath; Problems = @() }
    } catch {
        [void]$problems.Add('Каталог встановлення ' + $Path + ' не створено: ' + $_.Exception.Message)
        return [pscustomobject]@{ Success = $false; Path = $Path; Problems = $problems.ToArray() }
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
    $files = New-Object System.Collections.Generic.List[string]
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
    foreach ($file in $files) { [void]$entries.Add($file) }
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
        [Parameter(Mandatory = $true)][ValidateSet('Cloud', 'CloudAndSamba', 'SambaOnly', 'LocalOnly')][string]$BackupDestination
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
    $workDir = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_UPDATE_SEED_' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($workDir)
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
        if ((Test-BRAVOUpdatePathIsUnder -Path $workDir -Root ([IO.Path]::GetTempPath())) -and [IO.Directory]::Exists($workDir)) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-BRAVOInstallStageReleaseDefault {
    <#
    .SYNOPSIS
        Типова реалізація adapter.StageRelease: отримання (онлайн/офлайн) → перевірка проти
        plan.source.*Sha256 → безпечне розпакування → Test-BRAVOStagedRuntime.
        Повертає { Success, StagedRoot, Problems[], Findings[] }.
    .DESCRIPTION
        Усе — через функції Release/Staging хвилі 1; власної перевірки провенансу тут немає.
        Артефакти лежать у <StagingDirectory>\download, staged runtime — у <StagingDirectory>\runtime.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [AllowEmptyString()][string]$SourcePath = '',
        [Parameter(Mandatory = $true)][string]$StagingDirectory,
        $Downloader = $null
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $findings = New-Object System.Collections.Generic.List[object]
    $result = {
        param([bool]$Ok, [string]$Root)
        [pscustomobject]@{ Success = $Ok; StagedRoot = $Root; Problems = $problems.ToArray(); Findings = $findings.ToArray() }
    }
    $source = Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'source'
    $kind = [string](Get-BRAVOUpdatePropertyValue -InputObject $source -Name 'kind' -Default '')
    $tag = [string](Get-BRAVOUpdatePropertyValue -InputObject $source -Name 'tag' -Default '')
    $expectedArtifact = [string](Get-BRAVOUpdatePropertyValue -InputObject $source -Name 'artifactSha256' -Default '')
    $expectedManifest = [string](Get-BRAVOUpdatePropertyValue -InputObject $source -Name 'manifestSha256' -Default '')
    $packageVersion = [string](Get-BRAVOUpdatePropertyValue -InputObject $source -Name 'packageVersion' -Default '')
    $prerelease = [bool](Get-BRAVOUpdatePropertyValue -InputObject $source -Name 'prereleaseAuthorized' -Default $false)
    $downloadRoot = Join-Path $StagingDirectory 'download'
    $installStagedRoot = Join-Path $StagingDirectory 'runtime'
    try {
        foreach ($directory in @($downloadRoot, $installStagedRoot)) {
            $created = New-BRAVOUpdatePrivateDirectory -Path $directory
            if (-not $created.Success) {
                foreach ($p in @($created.Problems)) { [void]$problems.Add([string]$p) }
                return (& $result $false $installStagedRoot)
            }
        }
        $acquired = $null
        if ($kind -ceq 'Offline') {
            if ([string]::IsNullOrWhiteSpace($SourcePath)) {
                [void]$problems.Add('Офлайн-джерело потребує шляху до архіву.')
                return (& $result $false $installStagedRoot)
            }
            $acquired = Get-BRAVOOfflineReleaseSource -ZipPath $SourcePath -DestinationRoot $downloadRoot
        } else {
            $candidate = Get-BRAVOReleaseCandidate -Tag $tag
            $saveArguments = @{ Candidate = $candidate; DestinationRoot = $downloadRoot }
            if ($null -ne $Downloader) { $saveArguments['Downloader'] = $Downloader }
            $acquired = Save-BRAVOReleaseArtifact @saveArguments
        }
        if (-not $acquired.Success) {
            foreach ($p in @($acquired.Problems)) { [void]$problems.Add([string]$p) }
            return (& $result $false $installStagedRoot)
        }

        $verifyArguments = @{ ZipPath = $acquired.ZipPath; ChecksumPath = $acquired.ChecksumPath; ManifestPath = [string]$acquired.ManifestPath; ExpectedTag = $tag }
        if ($prerelease) { $verifyArguments['AllowPrerelease'] = $true }
        $verified = Test-BRAVOReleaseArtifact @verifyArguments
        foreach ($f in @($verified.Findings)) { [void]$findings.Add($f) }
        if (-not $verified.IsValid) {
            [void]$problems.Add('Перевірка релізного артефакта не пройдена.')
            return (& $result $false $installStagedRoot)
        }
        if (-not [string]::Equals([string]$verified.ArtifactSha256, $expectedArtifact, [StringComparison]::OrdinalIgnoreCase)) {
            [void]$problems.Add('SHA-256 артефакта не збігається з планом.')
            return (& $result $false $installStagedRoot)
        }
        if (-not [string]::IsNullOrWhiteSpace($expectedManifest) -and -not [string]::Equals([string]$verified.ManifestSha256, $expectedManifest, [StringComparison]::OrdinalIgnoreCase)) {
            [void]$problems.Add('SHA-256 release-manifest не збігається з планом.')
            return (& $result $false $installStagedRoot)
        }
        $expanded = Expand-BRAVOUpdateArchiveSafe -ZipPath $acquired.ZipPath -DestinationRoot $installStagedRoot -ExpectedSha256 $expectedArtifact
        if (-not $expanded.Success) {
            foreach ($p in @($expanded.Problems)) { [void]$problems.Add([string]$p) }
            return (& $result $false $installStagedRoot)
        }
        $staged = Test-BRAVOStagedRuntime -StagedRoot $installStagedRoot -ExpectedVersion $packageVersion
        foreach ($f in @($staged.Findings)) { [void]$findings.Add($f) }
        if (-not $staged.IsValid) {
            [void]$problems.Add('Staged runtime не пройшов перевірку.')
            return (& $result $false $installStagedRoot)
        }
        return (& $result $true $installStagedRoot)
    } catch {
        [void]$problems.Add('Збій підготовки релізу: ' + $_.Exception.Message)
        return (& $result $false $installStagedRoot)
    }
}

function New-BRAVOInstallResult {
    # Єдиний конструктор результату install: усе через New-BRAVOUpdateDeploymentResult.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Run,
        [Parameter(Mandatory = $true)][ValidateSet('Success', 'SuccessWithWarnings', 'Failed', 'RolledBack', 'Critical')][string]$Status,
        [ValidateSet('', 'Blocked', 'Cancelled', 'PlanStale', 'VerificationFailed', 'Error')][string]$ReasonCode = '',
        $Rollback = $null,
        $TaskActivation = $null,
        $InstalledVersion = $null
    )

    $arguments = @{
        OperationId      = [string]$Run.OperationId
        PlanId           = [string]$Run.PlanId
        Action           = 'Install'
        Status           = $Status
        SourceVersion    = $Run.SourceVersion
        TargetVersion    = $Run.TargetVersion
        InstalledVersion = $InstalledVersion
        LastPhase        = [string]$Run.LastPhase
        MutationStarted  = [bool]$Run.MutationStarted
        Validation       = @($Run.Validation.ToArray())
        Findings         = @($Run.Findings.ToArray())
        JournalPath      = [string]$Run.JournalPath
        StartedUtc       = [string]$Run.StartedUtc
        FinishedUtc      = [datetime]::UtcNow.ToString('o')
    }
    if ($ReasonCode -ne '') { $arguments['ReasonCode'] = $ReasonCode }
    if ($null -ne $Rollback) { $arguments['Rollback'] = $Rollback }
    if ($null -ne $TaskActivation) { $arguments['TaskActivation'] = $TaskActivation }
    return (New-BRAVOUpdateDeploymentResult @arguments)
}

function Complete-BRAVOInstallPreMutation {
    <#
    .SYNOPSIS
        Збій ДО межі mutation: журнал Abandoned, staging операції видаляється, результат Failed.
        Runtime-корінь не створювався, тому відкат не потрібен.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Run,
        [Parameter(Mandatory = $true)][ValidateSet('Blocked', 'Cancelled', 'PlanStale', 'VerificationFailed', 'Error')][string]$Reason
    )

    if ($null -ne $Run.Journal) {
        try { [void](Set-BRAVOUpdateJournalState -Journal $Run.Journal -State Abandoned -StateRoot $Run.StateRoot) } catch { $null = $_ }
        try {
            Remove-BRAVOUpdateOperationDirectory -Path (Join-Path $Run.StagingRoot ([string]$Run.OperationId)) -ExpectedParent $Run.StagingRoot -OperationId ([string]$Run.OperationId)
        } catch {
            [void]$Run.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.StagingCleanup' -Severity Warning -Title 'Staging операції не прибрано' `
                    -Meaning 'Тимчасові файли лишились у каталозі staging.' -Details ([string]$_.Exception.Message)))
        }
    }
    return (New-BRAVOInstallResult -Run $Run -Status Failed -ReasonCode $Reason)
}

function Install-BRAVOToolkit {
    <#
    .SYNOPSIS
        Чисте встановлення BRAVO Toolkit у порожній каталог (ENGINE_DESIGN §9.1).
    .DESCRIPTION
        Політика кореня → U0 план актуальний → U1 lifecycle lock → U2 відкритий журнал →
        U3 ConsumedPlans → U4 журнал/каталог операції → Stage → U7 повторна перевірка →
        U9 operation lock → U10 знімок version-state → U11 mutationStarted (межа) →
        CreateRuntimeRoot → Deploy → SeedLocalConfig → [ConfigureScheduler лише якщо
        credentials Found] → Validate(Install) → Commit. taskActivation = Inactive завжди
        (D6/§5). Збій після межі → Invoke-BRAVORollback (Install-гілка, частина Rollback).
        SimulatedCrash (FaultInjection=Crash) не відкочується: журнал лишається Open для
        Invoke-BRAVORecovery. Backup на install немає: старого runtime не існує.
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
        [scriptblock]$Downloader = $null,
        [hashtable]$FaultInjection = $null
    )

    # Корені: явні параметри; відсутні — з Get-BRAVOUpdateDefaultPaths (єдине місце
    # production-значень); runtime за відсутності береться з плану.
    $defaults = $null
    foreach ($name in @('StateRoot', 'LockRoot', 'StagingRoot', 'BackupRoot', 'OperationLockPath', 'VersionStatePath')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-Variable -Name $name -ValueOnly))) {
            if ($null -eq $defaults) { $defaults = Get-BRAVOUpdateDefaultPaths }
            Set-Variable -Name $name -Value ([string]$defaults.$name)
        }
    }
    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'runtimeRoot' -Default '') }
    $planSource = Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'source'
    $planId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'planId' -Default '')
    $operationId = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'operationId' -Default '')
    if ($operationId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { $operationId = [guid]::NewGuid().ToString() }
    $targetVersion = [string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'targetVersion' -Default '')
    if ($targetVersion -eq '') { $targetVersion = [string](Get-BRAVOUpdatePropertyValue -InputObject $planSource -Name 'packageVersion' -Default '') }
    $sourceVersion = Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'currentVersion' -Default $null

    $installRun = @{
        OperationId     = $operationId
        PlanId          = $planId
        StateRoot       = $StateRoot
        StagingRoot     = $StagingRoot
        Journal         = $null
        JournalPath     = ''
        MutationStarted = $false
        LastPhase       = ''
        SourceVersion   = $sourceVersion
        TargetVersion   = $(if ($targetVersion -eq '') { $null } else { $targetVersion })
        StartedUtc      = [datetime]::UtcNow.ToString('o')
        Findings        = (New-Object System.Collections.Generic.List[object])
        Validation      = (New-Object System.Collections.Generic.List[object])
        FailReason      = 'Error'
        Deferred        = $false
        Tasks           = @()
    }
    $lifecycleLock = $null
    $operationLock = $null
    $context = $null
    $fullAdapter = $null

    try {
        # --- Передумови без side effect-ів ------------------------------------------------
        if ($null -ne [Environment]::GetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE')) {
            [void]$installRun.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.AllowDowngradeSet' -Severity Blocker -Title 'У середовищі задано BRAVO_ALLOW_DOWNGRADE' `
                    -Meaning 'Engine не працює з обходом перевірки версій.' -Action 'Приберіть змінну BRAVO_ALLOW_DOWNGRADE із середовища процесу й повторіть.'))
            return (New-BRAVOInstallResult -Run $installRun -Status Failed -ReasonCode Blocked)
        }
        if ([string](Get-BRAVOUpdatePropertyValue -InputObject $Plan -Name 'action' -Default '') -cne 'Install') {
            [void]$installRun.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.WrongPlanAction' -Severity Blocker -Title 'План не є планом чистого встановлення' `
                    -Meaning 'Install-BRAVOToolkit приймає лише план з action=Install.' -Action 'Побудуйте новий план для встановлення.'))
            return (New-BRAVOInstallResult -Run $installRun -Status Failed -ReasonCode Blocked)
        }
        $fullAdapter = Get-BRAVOInstallAdapter -Adapter $Adapter
        $profileRoots = @(& $fullAdapter.GetUserProfileRoots)
        $installPolicy = Test-BRAVOInstallRuntimeRootPolicy -RuntimeRoot $RuntimeRoot -StateRoot $StateRoot -StagingRoot $StagingRoot -BackupRoot $BackupRoot -LockRoot $LockRoot -ProfileRoot $profileRoots
        if (-not $installPolicy.IsValid) {
            foreach ($finding in @($installPolicy.Findings)) { [void]$installRun.Findings.Add($finding) }
            return (New-BRAVOInstallResult -Run $installRun -Status Failed -ReasonCode Blocked)
        }
        $RuntimeRoot = [string]$installPolicy.FullPath

        # U0
        $current = Test-BRAVODeploymentPlanCurrent -Plan $Plan -RuntimeRoot $RuntimeRoot -StateRoot $StateRoot -Adapter $fullAdapter
        if (-not $current.IsCurrent) {
            [void]$installRun.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.PlanStale' -Severity Blocker -Title 'План застарів' `
                    -Meaning 'Передумови змінились після побудови плану.' -Action 'Виконайте новий preflight і підтвердьте новий план.' -Details (@($current.Problems) -join '; ')))
            return (New-BRAVOInstallResult -Run $installRun -Status Failed -ReasonCode PlanStale)
        }

        # U1
        $lifecycleLock = Enter-BRAVOUpdateLifecycleLock -LockRoot $LockRoot -OperationId $operationId
        if (-not $lifecycleLock.Success) {
            [void]$installRun.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.LifecycleLockBusy' -Severity Blocker -Title 'Інша операція оновлення виконується' `
                    -Meaning 'Одночасні операції заборонені.' -Action 'Дочекайтеся завершення іншої операції й повторіть.' -Details ([string]$lifecycleLock.Error) -ExitCodeHint 20))
            $lifecycleLock = $null
            return (New-BRAVOInstallResult -Run $installRun -Status Failed -ReasonCode Blocked)
        }

        # U2
        $openJournals = @(Get-BRAVOUpdateOpenJournal -StateRoot $StateRoot)
        if ($openJournals.Count -gt 0) {
            foreach ($entry in $openJournals) { [void]$installRun.Findings.Add($entry.Finding) }
            return (New-BRAVOInstallResult -Run $installRun -Status Failed -ReasonCode Blocked)
        }

        # U3: одноразовість плану (replay → PlanStale). CreateNew атомарний між процесами.
        $consumedRoot = Join-Path $StateRoot 'ConsumedPlans'
        [void][IO.Directory]::CreateDirectory($consumedRoot)
        $consumedPath = Join-Path $consumedRoot $planId
        $consumedStream = $null
        try {
            $consumedStream = New-Object System.IO.FileStream($consumedPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $consumedBytes = [Text.Encoding]::UTF8.GetBytes($operationId)
            $consumedStream.Write($consumedBytes, 0, $consumedBytes.Length)
        } catch [System.IO.IOException] {
            if ([IO.File]::Exists($consumedPath)) {
                [void]$installRun.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.PlanReplay' -Severity Blocker -Title 'План уже використано' `
                        -Meaning 'Той самий план не виконується двічі.' -Action 'Виконайте новий preflight і побудуйте новий план.'))
                return (New-BRAVOInstallResult -Run $installRun -Status Failed -ReasonCode PlanStale)
            }
            throw
        } finally {
            if ($null -ne $consumedStream) { $consumedStream.Dispose() }
        }

        # U4: каталог операції й журнал Open (mutationStarted=false).
        $operationDirectory = Join-Path (Join-Path $StateRoot 'Operations') $operationId
        $directoryResult = New-BRAVOUpdatePrivateDirectory -Path $operationDirectory
        if (-not $directoryResult.Success) { throw ('Каталог операції не створено: ' + (@($directoryResult.Problems) -join '; ')) }
        $journal = New-BRAVOUpdateJournal -StateRoot $StateRoot -Plan $Plan -OperationId $operationId -RuntimeRoot $RuntimeRoot -StagingRoot $StagingRoot -BackupRoot $BackupRoot
        $installRun.Journal = $journal
        $installRun.JournalPath = Get-BRAVOUpdateJournalPath -StateRoot $StateRoot -OperationId $operationId
        $paths = [pscustomobject]@{
            RuntimeRoot = $RuntimeRoot; StateRoot = $StateRoot; LockRoot = $LockRoot; StagingRoot = $StagingRoot
            BackupRoot = $BackupRoot; OperationLockPath = $OperationLockPath; VersionStatePath = $VersionStatePath
        }
        $contextArguments = @{ Plan = $Plan; Adapter = $fullAdapter; Paths = $paths; OperationDirectory = $operationDirectory; Journal = $journal }
        if ($null -ne $FaultInjection) { $contextArguments['FaultInjection'] = $FaultInjection }
        $context = New-BRAVOUpdateOperationContext @contextArguments

        # --- Stage (до межі mutation: збій = Abandoned, runtime не чіпаємо) ----------------
        $stagingDirectory = Join-Path $StagingRoot $operationId
        $stageDirectoryResult = New-BRAVOUpdatePrivateDirectory -Path $stagingDirectory
        if (-not $stageDirectoryResult.Success) { throw ('Каталог staging не створено: ' + (@($stageDirectoryResult.Problems) -join '; ')) }
        $installStageSlot = @{ Root = '' }
        $stageAction = {
            $staged = & $fullAdapter.StageRelease $Plan $SourcePath $stagingDirectory $Downloader
            foreach ($finding in @(Get-BRAVOUpdatePropertyValue -InputObject $staged -Name 'Findings' -Default @())) { [void]$installRun.Findings.Add($finding) }
            if (-not [bool]$staged.Success) {
                $installRun.FailReason = 'VerificationFailed'
                throw ('Отримання/перевірка релізу не пройдені: ' + (@(Get-BRAVOUpdatePropertyValue -InputObject $staged -Name 'Problems' -Default @()) -join '; '))
            }
            $installStageSlot.Root = [string]$staged.StagedRoot
        }
        [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'Stage' -ProgressPhase 'Stage' -Action $stageAction)
        $installStagedRoot = [string]$installStageSlot.Root

        # U6: версія й файловий набір staged-комплекту. Site-файли в payload —
        # blocker уже у Test-BRAVOStagedRuntime (типова реалізація StageRelease).
        $stagedVersion = ''
        $versionFile = Join-Path $installStagedRoot 'VERSION.json'
        if ([IO.File]::Exists($versionFile)) {
            try { $stagedVersion = [string](([IO.File]::ReadAllText($versionFile) | ConvertFrom-Json).packageVersion) } catch { $stagedVersion = '' }
        }
        if ($targetVersion -ne '' -and $stagedVersion -ne $targetVersion) {
            [void]$installRun.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.StagedVersion' -Severity Blocker -Title 'Версія staged-комплекту не збігається з планом' `
                    -Meaning 'Розпаковано не той реліз.' -Action 'Побудуйте новий план і повторіть.' -Details "staged '$stagedVersion', план '$targetVersion'" -ExitCodeHint 42))
            return (Complete-BRAVOInstallPreMutation -Run $installRun -Reason VerificationFailed)
        }
        $installFileSet = Get-BRAVODeploymentFileSet -StagedRoot $installStagedRoot -RuntimeRoot $RuntimeRoot -OldManifestPath (Join-Path $RuntimeRoot 'RUNTIME_MANIFEST.json')
        $fileSetProblems = New-Object System.Collections.Generic.List[string]
        foreach ($listName in @('UnknownScripts', 'NamespaceViolations', 'ReparsePoints')) {
            foreach ($item in @(Get-BRAVOUpdatePropertyValue -InputObject $installFileSet -Name $listName -Default @())) { [void]$fileSetProblems.Add($listName + ': ' + [string]$item) }
        }
        if ($fileSetProblems.Count -gt 0) {
            [void]$installRun.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.FileSet' -Severity Blocker -Title 'Файловий набір релізу не придатний для розгортання' `
                    -Meaning 'Staged-комплект містить заборонені елементи.' -Action 'Отримайте реліз знову з довіреного джерела.' -Details ($fileSetProblems -join '; ') -ExitCodeHint 42))
            return (Complete-BRAVOInstallPreMutation -Run $installRun -Reason VerificationFailed)
        }
        $installKeySet = Save-BRAVODeploymentKeySet -FileSet $installFileSet -OperationDirectory $operationDirectory

        # U7: повторна перевірка плану й політики кореня (TOCTOU між preflight і межею).
        $recheck = Test-BRAVODeploymentPlanCurrent -Plan $Plan -RuntimeRoot $RuntimeRoot -StateRoot $StateRoot -Adapter $fullAdapter
        if (-not $recheck.IsCurrent) {
            [void]$installRun.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.PlanStale' -Severity Blocker -Title 'План застарів під час підготовки' `
                    -Meaning 'Передумови змінились до початку змін.' -Action 'Виконайте новий preflight і підтвердьте новий план.' -Details (@($recheck.Problems) -join '; ')))
            return (Complete-BRAVOInstallPreMutation -Run $installRun -Reason PlanStale)
        }
        $policyAgain = Test-BRAVOInstallRuntimeRootPolicy -RuntimeRoot $RuntimeRoot -StateRoot $StateRoot -StagingRoot $StagingRoot -BackupRoot $BackupRoot -LockRoot $LockRoot -ProfileRoot $profileRoots
        if (-not $policyAgain.IsValid) {
            foreach ($finding in @($policyAgain.Findings)) { [void]$installRun.Findings.Add($finding) }
            return (Complete-BRAVOInstallPreMutation -Run $installRun -Reason Blocked)
        }

        # U9: канонічний operation lock ДО межі: зайнятий lock не повинен давати фіктивний RolledBack.
        $operationLock = Enter-BRAVOUpdateOperationLock -OperationLockPath $OperationLockPath -OperationId $operationId -PackageVersion $targetVersion
        if (-not $operationLock.Success) {
            [void]$installRun.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.OperationLockBusy' -Severity Blocker -Title 'Виконується Archive/Maintenance' `
                    -Meaning 'Встановлення не стартує посеред операції сервера.' -Action 'Дочекайтеся завершення операції й повторіть.' -Details ([string]$operationLock.Error) -ExitCodeHint 20))
            $operationLock = $null
            return (Complete-BRAVOInstallPreMutation -Run $installRun -Reason Blocked)
        }

        # U10: знімок version-state для відкату (7.2). Scheduler/site-config знімків немає:
        # задач і runtime ще не існує (legacy-задачі — blocker preflight).
        [void](Get-BRAVOVersionStateSnapshot -VersionStatePath $VersionStatePath -OperationDirectory $operationDirectory)

        # U11: MUTATION BOUNDARY.
        [void](Set-BRAVOUpdateJournalMutationStarted -Journal $journal -StateRoot $StateRoot)
        $installRun.MutationStarted = $true
        if (Test-BRAVOUpdateHasProperty -InputObject $context -Name 'MutationStarted') { $context.MutationStarted = $true }

        # --- CreateRuntimeRoot ----------------------------------------------------------------
        $createAction = {
            # Ownership — ДО side effect-у: збій між записом і створенням відкат переживе
            # (відсутній каталог просто пропускається).
            if ($installPolicy.PreexistingEmpty) {
                [void](Update-BRAVOInstallJournalOwnership -Journal $journal -StateRoot $StateRoot -Add @('marker:preexistingRoot'))
            } else {
                [void](Update-BRAVOInstallJournalOwnership -Journal $journal -StateRoot $StateRoot -Add @('dir:' + $RuntimeRoot))
            }
            $created = New-BRAVOInstallProtectedDirectory -Path $RuntimeRoot
            if (-not $created.Success) { throw ('Корінь встановлення не створено: ' + (@($created.Problems) -join '; ')) }
        }
        [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'CreateRuntimeRoot' -ProgressPhase 'Deploy' -Durable -Action $createAction)

        # --- Deploy ---------------------------------------------------------------------------
        $deployAction = {
            # Один запис ownership з усіма ключами (з хешами) і каталогами — до першого копіювання.
            # Один запис deploykeys (хеш deploy-keys.json) + каталоги; хеші файлів відкат бере з deploy-keys.json.
            $ownership = @('deploykeys:' + ([string]$installKeySet.Sha256).ToUpperInvariant()) + @(Get-BRAVOInstallOwnershipEntry -DeployKeys $installFileSet.DeployKeys)
            [void](Update-BRAVOInstallJournalOwnership -Journal $journal -StateRoot $StateRoot -Add $ownership)
            $deployed = Invoke-BRAVORuntimeDeploy -Context $context -StagedRoot $installStagedRoot -FileSet $installFileSet
            $errors = @(Get-BRAVOUpdatePropertyValue -InputObject $deployed -Name 'Errors' -Default @())
            if ($errors.Count -gt 0) { throw ('Помилки розгортання файлів: ' + ($errors -join '; ')) }
        }
        [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'Deploy' -ProgressPhase 'Deploy' -Durable -Action $deployAction)

        # --- SeedLocalConfig ------------------------------------------------------------------
        $localConfigPath = Join-Path $RuntimeRoot 'BRAVO.local.config'
        $seedAction = {
            # Наявний файл — не «наш»: не журналюємо ownership і не перезаписуємо.
            if ([IO.File]::Exists($localConfigPath)) { throw 'BRAVO.local.config уже існує в новому корені: сіяння не перезаписує файл.' }
            $intent = 'file:BRAVO.local.config'
            [void](Update-BRAVOInstallJournalOwnership -Journal $journal -StateRoot $StateRoot -Add @($intent))
            $seed = & $fullAdapter.SeedLocalConfig $RuntimeRoot $BackupDestination
            if (-not [bool]$seed.Created) {
                [void](Update-BRAVOInstallJournalOwnership -Journal $journal -StateRoot $StateRoot -Remove @($intent))
                throw ('BRAVO.local.config не створено (' + [string](Get-BRAVOUpdatePropertyValue -InputObject $seed -Name 'Stage' -Default '') + '): ' + (@(Get-BRAVOUpdatePropertyValue -InputObject $seed -Name 'Reasons' -Default @()) -join ' '))
            }
            $hash = (Get-FileHash -LiteralPath $localConfigPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
            [void](Update-BRAVOInstallJournalOwnership -Journal $journal -StateRoot $StateRoot -Remove @($intent) -Add @($intent + '|' + $hash))
        }
        [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'SeedLocalConfig' -ProgressPhase 'Configure' -Durable -Action $seedAction)

        # --- Scheduler: лише якщо credentials Found (інакше відкладено) ------------------------
        $presence = & $fullAdapter.TestCredentialPresence $RuntimeRoot 'Required'
        $presenceValue = [string](Get-BRAVOUpdatePropertyValue -InputObject $presence -Name 'Presence' -Default 'Unknown')
        if ($presenceValue -ceq 'Found') {
            $schedulerAction = {
                $snapshot = Get-BRAVOSchedulerSnapshot -Adapter $fullAdapter -RuntimeRoot $RuntimeRoot
                $reconciled = Invoke-BRAVOSchedulerReconcile -Context $context -Snapshot $snapshot
                $verdict = [string](Get-BRAVOUpdatePropertyValue -InputObject $reconciled -Name 'Verdict' -Default 'FAIL')
                if ($verdict -ceq 'FAIL') { throw ('Реєстрація задач завершилась помилкою: ' + (@(Get-BRAVOUpdatePropertyValue -InputObject $reconciled -Name 'Problems' -Default @()) -join '; ')) }
                if ($verdict -ceq 'PASS_WITH_WARNING') {
                    [void]$installRun.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.SchedulerWarning' -Severity Warning -Title 'Реєстрація задач завершилась із попередженнями' `
                            -Meaning 'Задачі зареєстровано, але вимагають уваги.' -Action 'Перегляньте журнал BRAVO_SETUP.'))
                }
                $installRun.Tasks = @(Get-BRAVOUpdatePropertyValue -InputObject $reconciled -Name 'CreatedTasks' -Default @())
            }
            [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'ConfigureScheduler' -ProgressPhase 'Configure' -Durable -Action $schedulerAction)
        } else {
            $installRun.Deferred = $true
            [void]$installRun.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.SchedulerDeferred' -Severity Warning -Title 'Реєстрацію планувальника відкладено' `
                    -Meaning 'Облікові дані ще не введено (або їх стан невідомий): задачі не створюються, архівація не працюватиме.' `
                    -Action 'Введіть облікові дані у вікні консолі, потім виконайте Repair зі scope Scheduler і підтвердіть активацію задач.' -Details ('credentialPresence=' + $presenceValue)))
        }

        # --- Validate (Install) ---------------------------------------------------------------
        $installValidateSlot = @{ Status = 'Pass' }
        $validateAction = {
            $baseline = Get-BRAVOSiteConfigurationBaseline -RuntimeRoot $RuntimeRoot
            $validation = Test-BRAVODeploymentValidation -Context $context -Mode Install -ExpectedVersion $targetVersion `
                -ExpectedManifestPath (Join-Path $RuntimeRoot 'RUNTIME_MANIFEST.json') -SiteBaseline $baseline
            foreach ($item in @(Get-BRAVOUpdatePropertyValue -InputObject $validation -Name 'Items' -Default @())) {
                [void]$installRun.Validation.Add([pscustomobject][ordered]@{
                        name    = [string](Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'name' -Default (Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'Name' -Default ''))
                        status  = [string](Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'status' -Default (Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'Status' -Default 'Skipped'))
                        message = [string](Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'message' -Default (Get-BRAVOUpdatePropertyValue -InputObject $item -Name 'Message' -Default ''))
                    })
            }
            $installValidateSlot.Status = [string](Get-BRAVOUpdatePropertyValue -InputObject $validation -Name 'Status' -Default 'Fail')
            if ($installValidateSlot.Status -ceq 'Fail') { throw 'Валідація встановлення не пройдена.' }
        }
        [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'Validate' -ProgressPhase 'Validate' -Action $validateAction)

        # --- Commit ---------------------------------------------------------------------------
        $commitAction = {
            [void](Set-BRAVOUpdateJournalState -Journal $journal -State Committed -StateRoot $StateRoot)
        }
        [void](Invoke-BRAVOUpdatePhase -Context $context -Phase 'Commit' -ProgressPhase 'Commit' -Durable -Action $commitAction)
        $installRun.LastPhase = 'Commit'
        Exit-BRAVOUpdateOperationLock -Lock $operationLock
        $operationLock = $null
        try {
            Remove-BRAVOUpdateOperationDirectory -Path $stagingDirectory -ExpectedParent $StagingRoot -OperationId $operationId
        } catch {
            [void]$installRun.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.StagingCleanup' -Severity Warning -Title 'Staging операції не прибрано' `
                    -Meaning 'Тимчасові файли лишились у каталозі staging; встановлення завершене.' -Details ([string]$_.Exception.Message)))
        }

        $warningFindings = @($installRun.Findings.ToArray() | Where-Object { $_.severity -ceq 'Warning' })
        $hasWarning = $installRun.Deferred -or ($installValidateSlot.Status -ceq 'Warn') -or ($warningFindings.Count -gt 0)
        $taskNames = New-Object System.Collections.Generic.List[string]
        foreach ($task in @($installRun.Tasks)) {
            if ($task -is [string]) { [void]$taskNames.Add($task) } else { [void]$taskNames.Add([string](Get-BRAVOUpdatePropertyValue -InputObject $task -Name 'Name' -Default ([string]$task))) }
        }
        # Install: задачі лишаються неактивними до явного підтвердження оператора (D6).
        $activation = [pscustomobject][ordered]@{ state = 'Inactive'; tasks = $taskNames.ToArray() }
        $status = 'Success'
        if ($hasWarning) { $status = 'SuccessWithWarnings' }
        return (New-BRAVOInstallResult -Run $installRun -Status $status -TaskActivation $activation -InstalledVersion $targetVersion)
    } catch {
        $failure = $_
        $failureText = [string]$failure.Exception.Message
        if ($failureText -like '*SimulatedCrash*' -or [string]$failure.FullyQualifiedErrorId -like '*SimulatedCrash*') {
            # Імітація аварії процесу: нічого не відкочуємо, журнал лишається Open
            # (finally звільнить лише handle-и), далі працює Invoke-BRAVORecovery.
            throw
        }
        $isCancel = ($failureText -like '*BRAVOUpdate.Cancel*')
        if (-not $installRun.MutationStarted) {
            [void]$installRun.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.PhaseFailed' -Severity Blocker -Title 'Підготовка встановлення завершилась помилкою' `
                    -Meaning 'Змін у системі не зроблено.' -Action 'Усуньте причину й повторіть із новим планом.' -Details $failureText))
            $reason = [string]$installRun.FailReason
            if ($isCancel) { $reason = 'Cancelled' }
            return (Complete-BRAVOInstallPreMutation -Run $installRun -Reason $reason)
        }
        # Після межі: відкат встановлення (E5); корінь має повернутись до «відсутній»
        # (або лишитись порожнім, якщо існував до операції).
        $phaseFinding = New-BRAVOUpdateFinding -Id 'Install.PhaseFailed' -Severity Warning -Title 'Встановлення перервано помилкою' `
            -Meaning 'Виконано відкат створених файлів і каталогів.' -Details $failureText
        try {
            $rollbackArguments = @{
                Journal = $installRun.Journal; Context = $context; Adapter = $fullAdapter; StateRoot = $StateRoot; LockRoot = $LockRoot
                OperationLockPath = $OperationLockPath; VersionStatePath = $VersionStatePath
            }
            if ($null -ne $FaultInjection) { $rollbackArguments['FaultInjection'] = $FaultInjection }
            # Операційний lock звільняємо перед відкатом: Invoke-BRAVORollback бере його сам
            # (повторне відкриття в тому ж процесі дало б sharing violation).
            if ($null -ne $operationLock) { Exit-BRAVOUpdateOperationLock -Lock $operationLock; $operationLock = $null }
            # Install-гілка Invoke-BRAVORollback викликає Invoke-BRAVOInstallRollback (cleanup за createdOwnership).
            $rollbackOutput = @(Invoke-BRAVORollback @rollbackArguments)
            # Береться саме DeploymentResult (останній об'єкт з exitCode): сторонній вивід кроків відкату не повинен ламати результат.
            $rolledBack = @($rollbackOutput | Where-Object { Test-BRAVOUpdateHasProperty -InputObject $_ -Name 'exitCode' } | Select-Object -Last 1)[0]
            if ($null -eq $rolledBack) { throw 'Invoke-BRAVORollback не повернув результат.' }
            $rolledBack.findings = @(@($rolledBack.findings) + $phaseFinding)
            try {
                Remove-BRAVOUpdateOperationDirectory -Path (Join-Path $StagingRoot $operationId) -ExpectedParent $StagingRoot -OperationId $operationId
            } catch { $null = $_ }
            return $rolledBack
        } catch {
            if (([string]$_.Exception.Message).StartsWith('BRAVOUpdate.SimulatedCrash', [StringComparison]::Ordinal)) { throw }
            $rollbackError = [string]$_.Exception.Message
            try { [void](Set-BRAVOUpdateJournalState -Journal $installRun.Journal -State Critical -StateRoot $StateRoot) } catch { $null = $_ }
            try { [void](Disable-BRAVOAllManagedTasks -Adapter $fullAdapter) } catch { $null = $_ }
            [void]$installRun.Findings.Add($phaseFinding)
            [void]$installRun.Findings.Add((New-BRAVOUpdateFinding -Id 'Install.RollbackFailed' -Severity Blocker -Title 'Відкат встановлення не завершився' `
                    -Meaning 'Частина файлів або каталогів може лишитись; задачі не активуються.' -Action 'Перегляньте журнал операції й виконайте ручне прибирання за інструкцією.' -Details $rollbackError))
            $rollbackInfo = [pscustomobject][ordered]@{ attempted = $true; status = 'Failed'; message = $rollbackError }
            return (New-BRAVOInstallResult -Run $installRun -Status Critical -Rollback $rollbackInfo)
        }
    } finally {
        # Handle-и звільняються завжди (у тому числі при імітації crash); файли lock не видаляються.
        if ($null -ne $operationLock) { Exit-BRAVOUpdateOperationLock -Lock $operationLock }
        if ($null -ne $lifecycleLock) { Exit-BRAVOUpdateLifecycleLock -Lock $lifecycleLock }
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
