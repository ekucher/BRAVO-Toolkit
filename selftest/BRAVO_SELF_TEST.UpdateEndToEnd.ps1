# Suite UpdateEndToEnd: наскрізні сценарії життєвого циклу Installer v1 через ПУБЛІЧНІ
# точки входу engine (INS-055; sandbox-аналоги INS-130...137). Не окремі частини, а
# весь конвеєр разом: офлайн-джерело -> верифікація -> план -> Install / Update /
# Repair / Recovery / Worker -> журнал, результат, runtime, site-файли, version-state,
# стан задач. Усе в sandbox у тимчасовому каталозі з унікальним GUID (шляхи з пробілами
# й кирилицею); adapter завжди stub (стан задач у пам'яті, guard/setup/self-test --
# керовані коди повернення). Task Scheduler, Credential Manager, C:\ProgramData\BRAVO і
# C:\Program Files\BRAVO-Toolkit не чіпаються.
#
# Це TDD-незалежні regression-тести поверх готової реалізації (не RED/GREEN).
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 -- НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition.

Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking

$e2eModule = Get-Module BRAVO.Update
$e2eTempPrefix = Join-Path ([IO.Path]::GetTempPath()) 'BRAVO_UPD_T1_'
$e2eRoot = $e2eTempPrefix + [guid]::NewGuid().ToString('N')
# Фейковий секрет: стає значенням змінної середовища процесу і полем stub-adapter-а.
# Engine не має права записати його в жоден артефакт (журнал, result.json, progress).
$e2eSecret = 'T1-FAKE-SECRET-' + [guid]::NewGuid().ToString('N')
$e2eSecretEnvName = 'BRAVO_T1_FAKE_SECRET'
$e2ePreviousSecretEnv = [Environment]::GetEnvironmentVariable($e2eSecretEnvName)
$e2eStopwatch = [Diagnostics.Stopwatch]::StartNew()
[void](New-Item -ItemType Directory -Path $e2eRoot -Force)
[Environment]::SetEnvironmentVariable($e2eSecretEnvName, $e2eSecret)

try {
    & {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $e2eHolder = @{ InstallSb = $null; InstallOutputCount = 0 }
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        # ------------------------------------------------------------------
        # Допоміжні функції sandbox
        # ------------------------------------------------------------------
        function Write-T1File {
            param([string]$Path, [string]$Text)
            $dir = [IO.Path]::GetDirectoryName($Path)
            if (-not [IO.Directory]::Exists($dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            [IO.File]::WriteAllText($Path, $Text, $utf8)
        }
        function Get-T1Sha {
            param([string]$Path)
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
        }
        function Get-T1TreeHash {
            # Відбиток дерева: файли (шлях + SHA-256) і каталоги. Порожній/відсутній корінь = 'absent'.
            param([string]$Root)
            if (-not [IO.Directory]::Exists($Root)) { return 'absent' }
            $base = $Root.TrimEnd('\')
            $lines = New-Object System.Collections.Generic.List[string]
            foreach ($item in (Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object -Property FullName)) {
                if ($item.PSIsContainer) { $lines.Add('D ' + $item.FullName.Substring($base.Length)) }
                else { $lines.Add('F ' + $item.FullName.Substring($base.Length) + ' ' + (Get-T1Sha -Path $item.FullName)) }
            }
            return ($lines.ToArray() -join '|')
        }
        function Get-T1SiteHash {
            # Site-owned файли: мають лишатись побайтово незмінними при будь-якій операції.
            param([string]$Runtime)
            $parts = New-Object System.Collections.Generic.List[string]
            foreach ($rel in @('BRAVO.local.config', 'BRAVO.config', 'TOOLS_INTEGRITY.json', 'WinSCP.ini', 'LOGS\a.log', 'BAZA\db.dat')) {
                $path = Join-Path $Runtime $rel
                if ([IO.File]::Exists($path)) { $parts.Add($rel + '=' + (Get-T1Sha -Path $path)) } else { $parts.Add($rel + '=absent') }
            }
            return ($parts.ToArray() -join '|')
        }
        function Write-T1Manifest {
            # Integrity-манифест у форматі ci\Update-BRAVORuntimeManifest.ps1: ключі з '\', SHA-256 UPPER.
            param([string]$Root, [string[]]$Relative)
            $files = [ordered]@{}
            foreach ($rel in $Relative) { $files[$rel] = Get-T1Sha -Path (Join-Path $Root $rel) }
            Write-T1File (Join-Path $Root 'RUNTIME_MANIFEST.json') ((@{ schemaVersion = 1; description = 'fixture'; files = $files } | ConvertTo-Json -Depth 4))
        }

        function New-T1Release {
            # Fake-реліз: stage-дерево + integrity-манифест + zip + .sha256 + release-manifest.json
            # (схема ci\New-BRAVOReleaseArtifact.ps1). Variant: 'N' (старий), 'N1' (новіший), 'Pre' (prerelease).
            param([string]$Base, [string]$Tag, [string]$Commit, [ValidateSet('N', 'N1', 'Pre')][string]$Variant, [string]$Channel = 'stable')
            $version = $Tag.Substring(1)
            $stage = Join-Path $Base 'stage'
            $out = Join-Path $Base 'out'
            [void](New-Item -ItemType Directory -Path $stage -Force)
            [void](New-Item -ItemType Directory -Path $out -Force)
            $versionJson = (@{ product = 'BRAVO-Toolkit'; packageVersion = $version; configSchemaVersion = 1; stateSchemaVersion = 1; updaterVersion = '1.0.0'
                    releaseDate = '2026-09-13'; releaseChannel = $Channel; buildId = $Commit.Substring(0, 7); sourceCommit = $Commit } | ConvertTo-Json)
            Write-T1File (Join-Path $stage 'VERSION.json') $versionJson
            Write-T1File (Join-Path $stage 'BRAVO_RUNTIME_GUARD.ps1') ('# guard ' + $Variant)
            Write-T1File (Join-Path $stage 'BRAVO_SETUP.ps1') '# setup stub'
            Write-T1File (Join-Path $stage 'BRAVO_CONFIG_LOADER.ps1') ('# loader ' + $Variant)
            Write-T1File (Join-Path $stage 'Tools\TOOLS_MANIFEST.json') '{}'
            Write-T1File (Join-Path $stage 'docs\README.txt') ('readme ' + $Variant)
            $relative = @('BRAVO_RUNTIME_GUARD.ps1', 'BRAVO_SETUP.ps1', 'BRAVO_CONFIG_LOADER.ps1', 'VERSION.json', 'Tools\TOOLS_MANIFEST.json')
            if ($Variant -eq 'N') {
                Write-T1File (Join-Path $stage 'modules\Старий модуль\old.psm1') '# old module'
                $relative += 'modules\Старий модуль\old.psm1'
            } else {
                Write-T1File (Join-Path $stage 'modules\X\X.psm1') '# module stub'
                $relative += 'modules\X\X.psm1'
            }
            Write-T1Manifest -Root $stage -Relative $relative
            $entries = New-Object System.Collections.Generic.List[object]
            foreach ($file in (Get-ChildItem -LiteralPath $stage -Recurse -File)) {
                $rel = $file.FullName.Substring($stage.Length + 1).Replace('\', '/')
                $entries.Add([pscustomobject]@{ path = $rel; sizeBytes = [long]$file.Length; sha256 = (Get-T1Sha -Path $file.FullName).ToLowerInvariant() })
            }
            $zipName = 'BRAVO-Toolkit-{0}.zip' -f $version
            $zipPath = Join-Path $out $zipName
            $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($file in (Get-ChildItem -LiteralPath $stage -Recurse -File)) {
                    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $file.FullName.Substring($stage.Length + 1).Replace('\', '/'))
                }
            } finally { $zip.Dispose() }
            $zipHash = (Get-T1Sha -Path $zipPath).ToLowerInvariant()
            Write-T1File ($zipPath + '.sha256') ("{0} *{1}`n" -f $zipHash, $zipName)
            $manifestPath = Join-Path $out 'release-manifest.json'
            $manifest = [pscustomobject]@{
                schemaVersion = 1; product = 'BRAVO-Toolkit'; packageVersion = $version; releaseChannel = $Channel; releaseDate = '2026-09-13'
                sourceCommit = $Commit; buildId = $Commit.Substring(0, 7); archiveRef = $Tag; archiveCommit = $Commit; tag = $Tag; generatedUtc = '2026-09-13T00:00:00Z'
                artifact = [pscustomobject]@{ name = $zipName; sizeBytes = (Get-Item -LiteralPath $zipPath).Length; sha256 = $zipHash }; files = $entries.ToArray()
            }
            Write-T1File $manifestPath ($manifest | ConvertTo-Json -Depth 5)
            return [pscustomobject]@{ Base = $Base; Stage = $stage; Out = $out; Zip = $zipPath; ManifestPath = $manifestPath; Tag = $Tag; Version = $version; Variant = $Variant }
        }

        function Add-T1SiteFiles {
            # Файли простору сервера: engine не має права їх змінювати.
            param([string]$Runtime, [switch]$Legacy)
            if ($Legacy) { Write-T1File (Join-Path $Runtime 'BRAVO.config') 'site config' }
            Write-T1File (Join-Path $Runtime 'BRAVO.local.config') '@{ Site = ''Приклад Лабораторія'' }'
            Write-T1File (Join-Path $Runtime 'TOOLS_INTEGRITY.json') '{}'
            Write-T1File (Join-Path $Runtime 'WinSCP.ini') 'ini'
            Write-T1File (Join-Path $Runtime 'LOGS\a.log') 'лог'
            Write-T1File (Join-Path $Runtime 'BAZA\db.dat') 'дані'
        }

        function New-T1Adapter {
            # Stub-adapter: стан задач у пам'яті, guard/setup/self-test з керованими кодами,
            # TestCredentialPresence, GetEffectiveConfiguration, seams Install/Preflight.
            param([hashtable]$Cfg)
            $a = @{}
            $a.GetManagedTasks = {
                param($TaskPath, $RuntimeRoot)
                if ($null -ne $Cfg.Hook) { & $Cfg.Hook }
                @(foreach ($n in @($Cfg.Tasks.Keys)) {
                        if ($Cfg.Exists[$n]) { [pscustomobject]@{ Name = $n; Path = '\BRAVO\'; Exists = $true; State = 'Ready'; Enabled = [bool]$Cfg.Tasks[$n] } }
                    })
            }.GetNewClosure()
            $a.SetTaskEnabled = {
                param($TaskPath, $Name, $Enabled)
                $Cfg.TaskLog.Add(($Name + '=' + [bool]$Enabled))
                if ($Cfg.FailSetTask -eq $Name) { return [pscustomobject]@{ Success = $false; Message = 'stub: збій SetTaskEnabled' } }
                $Cfg.Tasks[$Name] = [bool]$Enabled
                [pscustomobject]@{ Success = $true; Message = '' }
            }.GetNewClosure()
            $a.InvokeGuard = { param($RuntimeRoot, $LogPath) $Cfg.Calls.Add('Guard'); [pscustomobject]@{ ExitCode = [int]$Cfg.GuardExit; Output = ''; TimedOut = $false } }.GetNewClosure()
            $a.InvokeSetupScheduler = {
                param($RuntimeRoot, $LogPath)
                $Cfg.Calls.Add('SetupScheduler')
                # Реєстрація задач завжди вмикає їх (факт F1), а запуск entrypoint-ів піднімає version-state.
                foreach ($n in @($Cfg.Tasks.Keys)) { $Cfg.Exists[$n] = $true; $Cfg.Tasks[$n] = $true }
                $versionPath = Join-Path $RuntimeRoot 'VERSION.json'
                if ([IO.File]::Exists($versionPath)) {
                    $recorded = [string]((Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json).packageVersion)
                    [IO.File]::WriteAllText($Cfg.VersionState, ('{"highestVersion":"' + $recorded + '","highestVersionFull":"' + $recorded + '"}'), (New-Object System.Text.UTF8Encoding($false)))
                }
                [pscustomobject]@{ ExitCode = [int]$Cfg.SchedulerExit; Output = ''; TimedOut = $false }
            }.GetNewClosure()
            $a.InvokeSetupValidate = { param($RuntimeRoot, $LogPath) $Cfg.Calls.Add('SetupValidate'); [pscustomobject]@{ ExitCode = [int]$Cfg.ValidateExit; Output = ''; TimedOut = $false } }.GetNewClosure()
            $a.InvokeSelfTest = { param($RuntimeRoot, $LogPath) $Cfg.Calls.Add('SelfTest'); [pscustomobject]@{ ExitCode = [int]$Cfg.SelfTestExit; Output = ''; TimedOut = $false } }.GetNewClosure()
            $a.TestCredentialPresence = { param($RuntimeRoot, $Component) [pscustomobject]@{ Component = $Component; Presence = [string]$Cfg.Presence; ExitCode = 0; Secret = $Cfg.Secret } }.GetNewClosure()
            $a.GetEffectiveConfiguration = {
                param($RuntimeRoot)
                [pscustomobject]@{ Success = $true; ExitCode = 0; Message = ''; Configuration = [pscustomobject]@{
                        schedulerSettings = [pscustomobject]@{ TaskPath = '\BRAVO\'; Backup = [pscustomobject]@{ TaskName = 'BRAVO_A'; Enabled = $true }; Maintenance = [pscustomobject]@{ TaskName = 'BRAVO_B'; Enabled = $false } }
                        notificationSettings = [pscustomobject]@{ WebhookToken = $Cfg.Secret }
                    }
                }
            }.GetNewClosure()
            $a.Now = { [datetime]::UtcNow }
            $a.GetPreflightEnvironment = {
                [pscustomobject]@{ OsTier = 'Supported'; OsDescription = 'Example OS (test)'; PowerShellVersion = [version]'5.1.20348.0'; PowerShellEdition = 'Desktop'; DotNetRelease = 528372; Is64BitOS = $true; IsAdministrator = $true }
            }
            $a.GetUserProfileRoots = { @('C:\Users\Example-Nobody') }
            $a.SeedLocalConfig = {
                param($RuntimeRoot, $BackupDestination)
                $Cfg.Calls.Add('Seed')
                $path = Join-Path $RuntimeRoot 'BRAVO.local.config'
                [IO.File]::WriteAllText($path, ('@{ BackupDestination = ''' + $BackupDestination + ''' }'), (New-Object System.Text.UTF8Encoding($false)))
                [pscustomobject]@{ Created = $true; Stage = 'Complete'; Path = $path; Reasons = @() }
            }.GetNewClosure()
            return $a
        }

        function New-T1Sandbox {
            # Sandbox-корені під одним тимчасовим каталогом. Із -Installed у runtime розгортається
            # стадійне дерево релізу (+ site-файли); без нього runtime-каталог відсутній (clean install).
            param([string]$Name, $Installed = $null, [string]$Presence = 'Found', [switch]$NoTasks, [switch]$LegacyConfig)
            $base = Join-Path $e2eRoot ($Name + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $parent = Join-Path $base 'Програми Toolkit'
            $runtime = Join-Path $parent 'runtime dir'
            [void](New-Item -ItemType Directory -Path $parent -Force)
            $paths = [pscustomobject][ordered]@{
                RuntimeRoot = $runtime; StateRoot = (Join-Path $base 'state'); LockRoot = (Join-Path $base 'locks'); StagingRoot = (Join-Path $base 'staging')
                BackupRoot = (Join-Path $base 'backup'); OperationLockPath = (Join-Path $base 'locks\BRAVO_OPERATION.lock'); VersionStatePath = (Join-Path $base 'state\BRAVO_VERSION_STATE.json')
            }
            foreach ($dir in @($paths.StateRoot, $paths.LockRoot)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            $work = Join-Path $base 'work'
            [void](New-Item -ItemType Directory -Path $work -Force)
            if ($null -ne $Installed) {
                [void](New-Item -ItemType Directory -Path $runtime -Force)
                Copy-Item -Path (Join-Path $Installed.Stage '*') -Destination $runtime -Recurse -Force
                Add-T1SiteFiles -Runtime $runtime -Legacy:$LegacyConfig
                Write-T1File $paths.VersionStatePath ('{"highestVersion":"' + $Installed.Version + '","highestVersionFull":"' + $Installed.Version + '"}')
            }
            $cfg = @{
                Tasks = [ordered]@{ BRAVO_A = $true; BRAVO_B = $false }
                Exists = @{ BRAVO_A = ($null -ne $Installed); BRAVO_B = ($null -ne $Installed) }
                TaskLog = (New-Object 'System.Collections.Generic.List[string]')
                Calls = (New-Object 'System.Collections.Generic.List[string]')
                Hook = $null; GuardExit = 0; SchedulerExit = 0; ValidateExit = 0; SelfTestExit = 0; Presence = $Presence
                Secret = $e2eSecret; VersionState = $paths.VersionStatePath; FailSetTask = ''
            }
            if ($NoTasks) { $cfg.Exists = @{ BRAVO_A = $false; BRAVO_B = $false } }
            return [pscustomobject]@{
                Base = $base; Runtime = $runtime; Paths = $paths; Work = $work; Cfg = $cfg; Adapter = (New-T1Adapter -Cfg $cfg)
                State = $paths.StateRoot; Lock = $paths.LockRoot; Staging = $paths.StagingRoot; Backup = $paths.BackupRoot
                OpLock = $paths.OperationLockPath; VersionState = $paths.VersionStatePath
            }
        }

        function New-T1Plan {
            # Реальний конвеєр плану: Get-BRAVOInstallationState -> офлайн-джерело -> верифікація -> staging ->
            # preflight -> New-BRAVODeploymentPlan (через Invoke-BRAVOUpdateCliPlanStep, як CLI/GUI).
            param($Sandbox, [ValidateSet('Install', 'Update', 'Repair')][string]$Operation, $Release, [switch]$AllowPrerelease, [string]$SourcePath = '')
            if ($SourcePath -eq '') { $SourcePath = $Release.Zip }
            $stateArguments = @{ RuntimeRoot = $Sandbox.Runtime; Paths = $Sandbox.Paths; Adapter = $Sandbox.Adapter }
            return (Invoke-BRAVOUpdateCliPlanStep -Operation $Operation -StateArguments $stateArguments -Paths $Sandbox.Paths -Adapter $Sandbox.Adapter `
                    -SourcePath $SourcePath -AllowPrerelease:$AllowPrerelease -WorkRoot $Sandbox.Work)
        }
        function Get-T1BlockerIds {
            param($Plan)
            return @(@($Plan.findings) | Where-Object { [string]$_.severity -ceq 'Blocker' } | ForEach-Object { [string]$_.id })
        }
        function Get-T1FindingIds {
            param($Result)
            return @(@($Result.findings) | ForEach-Object { [string]$_.id })
        }
        function Invoke-T1Update {
            # Update або Repair через публічні orchestrator-и (Repair-BRAVOInstallation для action=Repair).
            param($Sandbox, $Plan, $Release, [hashtable]$Fault = $null, [string]$SourcePath = '')
            if ($SourcePath -eq '') { $SourcePath = $Release.Zip }
            $arguments = @{
                Plan = $Plan; Adapter = $Sandbox.Adapter; RuntimeRoot = $Sandbox.Runtime; StateRoot = $Sandbox.State; LockRoot = $Sandbox.Lock
                StagingRoot = $Sandbox.Staging; BackupRoot = $Sandbox.Backup; OperationLockPath = $Sandbox.OpLock; VersionStatePath = $Sandbox.VersionState
                SourcePath = $SourcePath
            }
            if ($null -ne $Fault) { $arguments['FaultInjection'] = $Fault }
            if ([string]$Plan.action -ceq 'Repair') { return (Repair-BRAVOInstallation @arguments) }
            return (Invoke-BRAVODeployment @arguments)
        }
        function Invoke-T1Install {
            param($Sandbox, $Plan, $Release, [hashtable]$Fault = $null, [string]$Destination = 'LocalOnly')
            $arguments = @{
                Plan = $Plan; Adapter = $Sandbox.Adapter; BackupDestination = $Destination; RuntimeRoot = $Sandbox.Runtime; StateRoot = $Sandbox.State; LockRoot = $Sandbox.Lock
                StagingRoot = $Sandbox.Staging; BackupRoot = $Sandbox.Backup; OperationLockPath = $Sandbox.OpLock; VersionStatePath = $Sandbox.VersionState
                SourcePath = $Release.Zip
            }
            if ($null -ne $Fault) { $arguments['FaultInjection'] = $Fault }
            # Install-BRAVOToolkit має повертати ОДИН DeploymentResult; кількість елементів виводу фіксуємо окремо.
            $output = @(Install-BRAVOToolkit @arguments)
            $e2eHolder.InstallOutputCount = $output.Count
            return ($output | Where-Object { ($null -ne $_.PSObject.Properties['status']) -and ($null -ne $_.PSObject.Properties['operationId']) } | Select-Object -Last 1)
        }
        function Invoke-T1Recovery {
            param($Sandbox, [hashtable]$Fault = $null)
            $arguments = @{ StateRoot = $Sandbox.State; LockRoot = $Sandbox.Lock; OperationLockPath = $Sandbox.OpLock; Adapter = $Sandbox.Adapter; VersionStatePath = $Sandbox.VersionState; RuntimeRoot = $Sandbox.Runtime; StagingRoot = $Sandbox.Staging; BackupRoot = $Sandbox.Backup }
            if ($null -ne $Fault) { $arguments['FaultInjection'] = $Fault }
            return (Invoke-BRAVORecovery @arguments)
        }
        function Read-T1Journal {
            param($Sandbox, $Plan)
            $path = Get-BRAVOUpdateJournalPath -StateRoot $Sandbox.State -OperationId ([string]$Plan.operationId)
            if (-not [IO.File]::Exists($path)) { return $null }
            return (Read-BRAVOUpdateJournal -Path $path).Journal
        }
        function Get-T1JournalState {
            param($Sandbox, $Plan)
            $journal = Read-T1Journal -Sandbox $Sandbox -Plan $Plan
            if ($null -eq $journal) { return 'no-journal' }
            return [string]$journal.state
        }
        function Test-T1LocksFree {
            param($Sandbox)
            $life = Enter-BRAVOUpdateLifecycleLock -LockRoot $Sandbox.Lock -OperationId ([guid]::NewGuid().ToString())
            $op = Enter-BRAVOUpdateOperationLock -OperationLockPath $Sandbox.OpLock -OperationId ([guid]::NewGuid().ToString()) -PackageVersion '0'
            $free = ($life.Success -and $op.Success)
            if ($life.Success) { Exit-BRAVOUpdateLifecycleLock -Lock $life }
            if ($op.Success) { Exit-BRAVOUpdateOperationLock -Lock $op }
            return $free
        }
        function Test-T1ExitCodeConsistent {
            param($Result)
            return ([int]$Result.exitCode -eq [int](ConvertTo-BRAVOUpdateExitCode -Result $Result))
        }
        function Get-T1TaskState {
            param($Sandbox)
            return (($Sandbox.Cfg.Tasks.Keys | ForEach-Object { $_ + '=' + $(if ($Sandbox.Cfg.Tasks[$_]) { 'on' } else { 'off' }) }) -join ',')
        }
        function Format-T1Result {
            param($Result)
            return ('status=' + $Result.status + ' reason=' + $Result.reasonCode + ' exit=' + $Result.exitCode + ' findings=' + ((@($Result.findings) | ForEach-Object { $_.id + '[' + $_.details + ']' }) -join ','))
        }

        $releaseN = New-T1Release -Base (Join-Path $e2eRoot 'release-N') -Tag 'v5.2.6' -Commit ('a' * 40) -Variant N
        $releaseN1 = New-T1Release -Base (Join-Path $e2eRoot 'release-N1') -Tag 'v5.3.0' -Commit 'd77f3b4d021c3d3d53565a604a2497d1d962dcb4' -Variant N1

        # ================================================================
        # 0. Передумова конвеєра: New-BRAVODeploymentPlan не кидає на кожному виклику.
        #    Plan.ps1 викликає валідатор плану з -Plan, а Test-BRAVOUpdateDeploymentPlan
        #    приймає лише -InputObject (Codex P1 #1, Plan.ps1:705). Поки це не виправлено,
        #    ця перевірка ПАДАЄ (задокументована помилка продукту), а решта сценаріїв
        #    виконується з тест-only shim-ом у scope модуля (див. нижче), інакше жоден
        #    наскрізний сценарій неможливо побудувати.
        # ================================================================
        $e2eProbe = New-T1Sandbox -Name 'probe' -Installed $releaseN
        $e2eProbePlan = New-T1Plan -Sandbox $e2eProbe -Operation Update -Release $releaseN1
        $e2eValidatorBug = ($null -eq $e2eProbePlan.Plan)
        Test-BRAVOCondition -Condition (-not $e2eValidatorBug) -Name 'UpdateEndToEnd/Plan/PipelineBuildsPlanWithoutShim' `
            -Failure ('ПОМИЛКА ПРОДУКТУ (Plan.ps1:705): New-BRAVODeploymentPlan не будує план: ' + ((@($e2eProbePlan.Findings) | ForEach-Object { [string]$_.details }) -join ' | '))
        if ($e2eValidatorBug) {
            # TEST-ONLY shim: приймає і -Plan, і -InputObject та делегує оригінальному валідатору.
            & $e2eModule {
                $script:T1ValidatorOriginal = (Get-Command -Name 'Test-BRAVOUpdateDeploymentPlan' -CommandType Function).ScriptBlock
                function script:Test-BRAVOUpdateDeploymentPlan {
                    [CmdletBinding()]
                    param([Parameter(Mandatory = $true)][Alias('Plan')]$InputObject)
                    & $script:T1ValidatorOriginal -InputObject $InputObject
                }
            }
        }

        # ================================================================
        # Допоміжні функції сценаріїв
        # ================================================================
        function Get-T1Snapshot {
            # Повний відбиток спостережуваного стану sandbox: runtime, site-файли, version-state, задачі.
            param($Sandbox)
            $versionHash = 'absent'
            if ([IO.File]::Exists($Sandbox.VersionState)) { $versionHash = Get-T1Sha -Path $Sandbox.VersionState }
            return [pscustomobject]@{
                Tree = (Get-T1TreeHash -Root $Sandbox.Runtime); Site = (Get-T1SiteHash -Runtime $Sandbox.Runtime)
                Version = $versionHash; Tasks = (Get-T1TaskState -Sandbox $Sandbox)
            }
        }
        function Get-T1SnapshotDiff {
            param($Before, $After, [string[]]$Skip = @())
            $diff = New-Object System.Collections.Generic.List[string]
            foreach ($name in @('Tree', 'Site', 'Version', 'Tasks')) {
                if ($Skip -contains $name) { continue }
                if ([string]$Before.$name -cne [string]$After.$name) { $diff.Add($name) }
            }
            return $diff.ToArray()
        }
        function Copy-T1Plan {
            # Клон плану для іншого sandbox (корені, planId, operationId). Передумови однакові, тому
            # fingerprint збігається; це лише економія часу в матриці збоїв -- одноразові сценарії
            # будують план повним конвеєром (New-T1Plan).
            param($Template, $Sandbox)
            $plan = $Template.PSObject.Copy()
            $plan.planId = [guid]::NewGuid().ToString()
            $plan.operationId = [guid]::NewGuid().ToString()
            $plan.runtimeRoot = $Sandbox.Runtime
            $plan.stagingRoot = $Sandbox.Staging
            $plan.backupRoot = $Sandbox.Backup
            return $plan
        }
        function Test-T1PathExists {
            param([string]$Path)
            return ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path))
        }
        function Invoke-T1Worker {
            # Worker-протокол: запит -> файл у Requests -> Invoke-BRAVOUpdateWorker (admin і корені через seams).
            param($Sandbox, $Plan, [string]$SourcePath = '', $IsAdministrator = $true, [string]$RequestPath = '', [string[]]$CandidateRoots = $null)
            [void](Initialize-BRAVOUpdateStateDirectories -StateRoot $Sandbox.State)
            if ($RequestPath -eq '') {
                $options = @{ backupDestination = 'LocalOnly' }
                if ($SourcePath -ne '') { $options['sourcePath'] = $SourcePath }
                $request = New-BRAVOUpdateRequest -Plan $Plan -ConfirmedPlanShortId ([string]$Plan.planId).Substring(0, 8) -Option $options
                $RequestPath = Write-BRAVOUpdateRequestFile -Request $request -StateRoot $Sandbox.State
            }
            if ($null -eq $CandidateRoots) { $CandidateRoots = @($Sandbox.Runtime) }
            $out = Invoke-BRAVOUpdateWorker -RequestPath $RequestPath -Adapter $Sandbox.Adapter -Paths $Sandbox.Paths -CandidateRoots $CandidateRoots -IsAdministrator $IsAdministrator
            return [pscustomobject]@{ Out = $out; Result = $out.Result; RequestPath = $RequestPath }
        }
        function Test-T1RuntimeMatchesRelease {
            param([string]$Runtime, $Release)
            $match = Test-BRAVODeployRuntimeMatchesManifest -RuntimeRoot $Runtime -ManifestPath (Join-Path $Release.Stage 'RUNTIME_MANIFEST.json') -ExcludeDirs @((Get-BRAVOUpdateSiteOwnedPaths).Dirs)
            return $match.IsMatch
        }
        function Get-T1ResultProblem {
            # Спільні перевірки будь-якого результату: контракт, код завершення, lock-и звільнено.
            param($Sandbox, $Result)
            $problems = New-Object System.Collections.Generic.List[string]
            $valid = Test-BRAVOUpdateDeploymentResult -InputObject $Result
            if (-not $valid.IsValid) { $problems.Add('результат не відповідає контракту: ' + ($valid.Problems -join ';')) }
            if (-not (Test-T1ExitCodeConsistent -Result $Result)) { $problems.Add('exitCode не відповідає ConvertTo-BRAVOUpdateExitCode') }
            if (-not (Test-T1LocksFree -Sandbox $Sandbox)) { $problems.Add('lock-и не звільнено') }
            return $problems.ToArray()
        }
        function Get-T1PreBoundaryProblem {
            # Збій ДО межі mutation: Failed, runtime/site/version/задачі без змін, журнал Abandoned,
            # staging і backup операції прибрано.
            param($Case, $Result, [string]$Reason = 'Error', $ExitCode = 80)
            $sb = $Case.Sb
            $opId = [string]$Case.Plan.operationId
            $problems = New-Object System.Collections.Generic.List[string]
            foreach ($p in @(Get-T1ResultProblem -Sandbox $sb -Result $Result)) { $problems.Add($p) }
            if ([string]$Result.status -cne 'Failed') { $problems.Add('status=' + $Result.status + ' (очікувалось Failed)') }
            if ([string]$Result.reasonCode -cne $Reason) { $problems.Add('reasonCode=' + $Result.reasonCode + ' (очікувалось ' + $Reason + ')') }
            if ($Result.mutationStarted) { $problems.Add('mutationStarted=true до межі') }
            if ([int]$Result.exitCode -ne [int]$ExitCode) { $problems.Add('exitCode=' + $Result.exitCode + ' (очікувалось ' + $ExitCode + ')') }
            $journalState = Get-T1JournalState -Sandbox $sb -Plan $Case.Plan
            if ($journalState -cne 'Abandoned') { $problems.Add('журнал=' + $journalState + ' (очікувалось Abandoned)') }
            if (Test-T1PathExists -Path (Join-Path $sb.Staging $opId)) { $problems.Add('staging операції лишився') }
            if (Test-T1PathExists -Path (Join-Path $sb.Backup $opId)) { $problems.Add('backup операції лишився') }
            $diff = @(Get-T1SnapshotDiff -Before $Case.Pre -After (Get-T1Snapshot -Sandbox $sb))
            if ($diff.Count -gt 0) { $problems.Add('змінено: ' + ($diff -join ',')) }
            if ($sb.Cfg.TaskLog.Count -ne 0) { $problems.Add('задачі чіпались: ' + ($sb.Cfg.TaskLog.ToArray() -join ',')) }
            return $problems.ToArray()
        }
        function Get-T1RolledBackProblem {
            # Збій ПІСЛЯ межі: RolledBack (81), стан повернуто побайтово, журнал RolledBack.
            param($Case, $Result)
            $sb = $Case.Sb
            $problems = New-Object System.Collections.Generic.List[string]
            foreach ($p in @(Get-T1ResultProblem -Sandbox $sb -Result $Result)) { $problems.Add($p) }
            if ([string]$Result.status -cne 'RolledBack') { $problems.Add('status=' + $Result.status + ' (очікувалось RolledBack)') }
            if ([int]$Result.exitCode -ne 81) { $problems.Add('exitCode=' + $Result.exitCode + ' (очікувалось 81)') }
            if (-not $Result.mutationStarted) { $problems.Add('mutationStarted=false після межі') }
            if ([string]$Result.rollback.status -cne 'Succeeded') { $problems.Add('rollback.status=' + $Result.rollback.status) }
            $journalState = Get-T1JournalState -Sandbox $sb -Plan $Case.Plan
            if ($journalState -cne 'RolledBack') { $problems.Add('журнал=' + $journalState + ' (очікувалось RolledBack)') }
            $diff = @(Get-T1SnapshotDiff -Before $Case.Pre -After (Get-T1Snapshot -Sandbox $sb))
            if ($diff.Count -gt 0) { $problems.Add('після відкату змінено: ' + ($diff -join ',')) }
            return $problems.ToArray()
        }

        # Шаблон плану Update N -> N+1 (повний конвеєр один раз; клони -- у матриці збоїв).
        $e2eTemplateSandbox = New-T1Sandbox -Name 'template' -Installed $releaseN
        $e2eTemplatePlan = (New-T1Plan -Sandbox $e2eTemplateSandbox -Operation Update -Release $releaseN1).Plan
        function New-T1UpdateCase {
            param([string]$Name)
            $sb = New-T1Sandbox -Name $Name -Installed $releaseN
            $plan = Copy-T1Plan -Template $e2eTemplatePlan -Sandbox $sb
            return [pscustomobject]@{ Sb = $sb; Plan = $plan; Pre = (Get-T1Snapshot -Sandbox $sb) }
        }

        # Передумова clean install: реальний Install не відхиляє власний план як застарілий.
        # Install-BRAVOToolkit (Install.ps1, крок U7) повторно викликає Test-BRAVODeploymentPlanCurrent ПІСЛЯ
        # створення власного Open-журналу, а fingerprint плану враховує відкриті журнали, тож кожен реальний
        # Install завершується Failed/PlanStale (Deploy.ps1 обходить це через Test-BRAVOUpdatePlanStillCurrent).
        # UpdateInstall цього не бачить: підміняє Test-BRAVODeploymentPlanCurrent заглушкою. Поки це не
        # виправлено, перевірка ПАДАЄ, а решта сценаріїв працює з тест-only shim-ом у scope модуля
        # (повторна перевірка виключає власний operationId, як Test-BRAVOUpdatePlanStillCurrent).
        & {
            $sb = New-T1Sandbox -Name 'install-probe' -Presence 'Found'
            $plan = (New-T1Plan -Sandbox $sb -Operation Install -Release $releaseN).Plan
            $probeResult = Invoke-T1Install -Sandbox $sb -Plan $plan -Release $releaseN
            $e2eHolder.PlanStaleBug = (($probeResult.status -ceq 'Failed') -and ($probeResult.reasonCode -ceq 'PlanStale'))
            Test-BRAVOCondition -Condition (-not $e2eHolder.PlanStaleBug) -Name 'UpdateEndToEnd/Install/RealInstallNotRejectedAsStale' `
                -Failure ('ПОМИЛКА ПРОДУКТУ (Install.ps1, крок U7 після створення власного журналу): ' + (Format-T1Result -Result $probeResult))
            if ($e2eHolder.PlanStaleBug) {
                & $e2eModule {
                    $script:T1PlanCurrentOriginal = (Get-Command -Name 'Test-BRAVODeploymentPlanCurrent' -CommandType Function).ScriptBlock
                    function script:Test-BRAVODeploymentPlanCurrent {
                        [CmdletBinding()]
                        param([Parameter(Mandatory = $true)]$Plan, [Parameter(Mandatory = $true)][string]$RuntimeRoot, [Parameter(Mandatory = $true)][string]$StateRoot, [hashtable]$Adapter = $null, [object]$Now = $null)
                        $result = & $script:T1PlanCurrentOriginal -Plan $Plan -RuntimeRoot $RuntimeRoot -StateRoot $StateRoot -Adapter $Adapter -Now $Now
                        if ($result.IsCurrent -or $result.Expired) { return $result }
                        $artifact = [string]$Plan.source.artifactSha256
                        $manifest = [string]$Plan.source.manifestSha256
                        $preconditions = Get-BRAVODeploymentPreconditions -RuntimeRoot $RuntimeRoot -StateRoot $StateRoot -ArtifactSha256 $artifact -ManifestSha256 $manifest -Adapter $Adapter
                        $own = [string]$Plan.operationId
                        $preconditions.openJournalIds = @(@($preconditions.openJournalIds) | Where-Object { [string]$_ -cne $own })
                        $current = Get-BRAVOUpdatePreconditionsFingerprint -Preconditions $preconditions
                        if ($current -ceq ([string]$Plan.preconditionsFingerprint).ToUpperInvariant()) {
                            return [pscustomobject][ordered]@{ IsCurrent = $true; Expired = $false; FingerprintMatches = $true; Problems = @() }
                        }
                        return $result
                    }
                }
            }
        }

        # ================================================================
        # 1. Clean install з офлайн-джерела (INS-130)
        # ================================================================
        $e2eInstallSb = $null
        & {
            $sb = New-T1Sandbox -Name 'install' -Presence 'Found'
            $planResult = New-T1Plan -Sandbox $sb -Operation Install -Release $releaseN
            $plan = $planResult.Plan
            Test-BRAVOCondition -Condition (($null -ne $plan) -and (@(Get-T1BlockerIds -Plan $plan).Count -eq 0)) -Name 'UpdateEndToEnd/Install/PlanHasNoBlockers' `
                -Failure ('план Install: ' + $(if ($null -eq $plan) { 'не побудовано: ' + ((@($planResult.Findings) | ForEach-Object { $_.id + ':' + $_.details }) -join '|') } else { (Get-T1BlockerIds -Plan $plan) -join ',' }))
            if ($null -eq $plan) { return }
            $result = Invoke-T1Install -Sandbox $sb -Plan $plan -Release $releaseN
            $problems = @(Get-T1ResultProblem -Sandbox $sb -Result $result)
            Test-BRAVOCondition -Condition (($result.status -ceq 'Success') -and ($result.exitCode -eq 0) -and ($problems.Count -eq 0)) -Name 'UpdateEndToEnd/Install/Success' `
                -Failure ((Format-T1Result -Result $result) + ' problems=' + ($problems -join ';'))
            Test-BRAVOCondition -Condition ($e2eHolder.InstallOutputCount -eq 1) -Name 'UpdateEndToEnd/Install/ReturnsSingleResultObject' `
                -Failure ('ПОМИЛКА ПРОДУКТУ (Install.ps1:523,849,902): Install-BRAVOToolkit повернув ' + $e2eHolder.InstallOutputCount + ' об''єктів замість одного DeploymentResult: Remove-BRAVOUpdateOperationDirectory без [void] потрапляє у pipeline.')
            Test-BRAVOCondition -Condition (Test-T1RuntimeMatchesRelease -Runtime $sb.Runtime -Release $releaseN) -Name 'UpdateEndToEnd/Install/RuntimeMatchesRelease' -Failure 'Після install runtime не збігається з manifest релізу.'
            $localConfig = Join-Path $sb.Runtime 'BRAVO.local.config'
            Test-BRAVOCondition -Condition ([IO.File]::Exists($localConfig) -and (@($sb.Cfg.Calls | Where-Object { $_ -ceq 'Seed' }).Count -eq 1) -and ([IO.File]::ReadAllText($localConfig).Contains('LocalOnly'))) `
                -Name 'UpdateEndToEnd/Install/LocalConfigSeededOnce' -Failure 'BRAVO.local.config має бути засіяно один раз через adapter (призначення LocalOnly).'
            Test-BRAVOCondition -Condition ((Get-T1TaskState -Sandbox $sb) -ceq 'BRAVO_A=off,BRAVO_B=off') -Name 'UpdateEndToEnd/Install/TasksInactive' -Failure ('Після install задачі мають бути вимкнені: ' + (Get-T1TaskState -Sandbox $sb))
            Test-BRAVOCondition -Condition ([string]$result.taskActivation.state -ceq 'Inactive') -Name 'UpdateEndToEnd/Install/ActivationInactive' -Failure ('taskActivation=' + $result.taskActivation.state)
            Test-BRAVOCondition -Condition ((Get-T1JournalState -Sandbox $sb -Plan $plan) -ceq 'Committed') -Name 'UpdateEndToEnd/Install/JournalCommitted' -Failure (Get-T1JournalState -Sandbox $sb -Plan $plan)
            Test-BRAVOCondition -Condition ((-not (Test-T1PathExists -Path (Join-Path $sb.Staging ([string]$plan.operationId)))) -and [IO.File]::Exists((Join-Path $sb.State ('ConsumedPlans\' + [string]$plan.planId)))) `
                -Name 'UpdateEndToEnd/Install/StagingRemovedPlanConsumed' -Failure 'Staging має бути прибрано, план -- позначено використаним.'
            # Повтор того самого плану після успіху: не виконується вдруге.
            $afterInstall = Get-T1Snapshot -Sandbox $sb
            $again = Invoke-T1Install -Sandbox $sb -Plan $plan -Release $releaseN
            Test-BRAVOCondition -Condition (($again.status -ceq 'Failed') -and (@('Blocked', 'PlanStale') -ccontains [string]$again.reasonCode) -and (-not $again.mutationStarted) -and ((Get-T1Snapshot -Sandbox $sb).Tree -ceq $afterInstall.Tree)) -Name 'UpdateEndToEnd/Install/ReplayRefusedWithoutChanges' -Failure (Format-T1Result -Result $again)
            $e2eHolder.InstallSb = $sb
        }
        $e2eInstallSb = $e2eHolder.InstallSb

        # Credentials Missing -> інсталяція завершується, але планувальник відкладено (SchedulerDeferred).
        & {
            $sb = New-T1Sandbox -Name 'install-nocred' -Presence 'Missing'
            $plan = (New-T1Plan -Sandbox $sb -Operation Install -Release $releaseN).Plan
            $result = Invoke-T1Install -Sandbox $sb -Plan $plan -Release $releaseN
            $problems = @(Get-T1ResultProblem -Sandbox $sb -Result $result)
            Test-BRAVOCondition -Condition (($result.status -ceq 'SuccessWithWarnings') -and ($result.exitCode -eq 10) -and ((Get-T1FindingIds -Result $result) -contains 'Install.SchedulerDeferred') -and ($problems.Count -eq 0)) `
                -Name 'UpdateEndToEnd/Install/CredentialsMissingDefersScheduler' -Failure ((Format-T1Result -Result $result) + ' problems=' + ($problems -join ';'))
            Test-BRAVOCondition -Condition ((@($sb.Cfg.Calls | Where-Object { $_ -ceq 'SetupScheduler' }).Count -eq 0) -and ((Get-T1TaskState -Sandbox $sb) -ceq 'BRAVO_A=on,BRAVO_B=off') -and (-not $sb.Cfg.Exists['BRAVO_A'])) `
                -Name 'UpdateEndToEnd/Install/CredentialsMissingNoTasksRegistered' -Failure 'Без credentials планувальник не реєструється (BRAVO_SETUP -Action Scheduler не викликається).'
            Test-BRAVOCondition -Condition (Test-T1RuntimeMatchesRelease -Runtime $sb.Runtime -Release $releaseN) -Name 'UpdateEndToEnd/Install/CredentialsMissingRuntimeInstalled' -Failure 'Файли комплекту мають бути розгорнуті попри відкладений планувальник.'
        }

        # ================================================================
        # 2. Та сама версія вдруге: Install заблоковано, Update заблоковано (пропонується Repair)
        # ================================================================
        & {
            $sb = $e2eInstallSb
            $before = Get-T1Snapshot -Sandbox $sb
            $journalFiles = @(Get-ChildItem -LiteralPath (Join-Path $sb.State 'Journal') -File).Count
            $installPlan = (New-T1Plan -Sandbox $sb -Operation Install -Release $releaseN).Plan
            Test-BRAVOCondition -Condition ((Get-T1BlockerIds -Plan $installPlan) -contains 'Plan.InstallOnExisting') -Name 'UpdateEndToEnd/SameVersion/InstallPlanBlocked' -Failure ('blockers=' + ((Get-T1BlockerIds -Plan $installPlan) -join ','))
            $blocked = Invoke-T1Install -Sandbox $sb -Plan $installPlan -Release $releaseN
            Test-BRAVOCondition -Condition (($blocked.status -ceq 'Failed') -and ($blocked.reasonCode -ceq 'Blocked') -and (-not $blocked.mutationStarted) -and ((Get-T1Snapshot -Sandbox $sb).Tree -ceq $before.Tree) -and (@(Get-ChildItem -LiteralPath (Join-Path $sb.State 'Journal') -File).Count -eq $journalFiles)) `
                -Name 'UpdateEndToEnd/SameVersion/InstallOnExistingEngineRefuses' -Failure ('Install у наявний runtime мав бути відхилено без змін: ' + (Format-T1Result -Result $blocked))
            $updatePlan = (New-T1Plan -Sandbox $sb -Operation Update -Release $releaseN).Plan
            $same = @(@($updatePlan.findings) | Where-Object { [string]$_.id -ceq 'Plan.UpdateSameVersion' })
            Test-BRAVOCondition -Condition (($same.Count -eq 1) -and ([string]$same[0].severity -ceq 'Blocker') -and ([string]$same[0].action).Contains('Відновити')) -Name 'UpdateEndToEnd/SameVersion/UpdatePlanBlockedSuggestsRepair' `
                -Failure ('Update тієї ж версії має бути blocker-ом із підказкою «Відновити»: ' + ((Get-T1BlockerIds -Plan $updatePlan) -join ','))
            $worker = Invoke-T1Worker -Sandbox $sb -Plan $updatePlan -SourcePath $releaseN.Zip
            Test-BRAVOCondition -Condition (($worker.Result.status -ceq 'Failed') -and ($worker.Out.ExitCode -ne 0) -and ((Get-T1FindingIds -Result $worker.Result) -contains 'Plan.UpdateSameVersion') -and ((Get-T1Snapshot -Sandbox $sb).Tree -ceq $before.Tree)) `
                -Name 'UpdateEndToEnd/SameVersion/WorkerRefusesUpdate' -Failure ('Worker має відхилити Update тієї ж версії без змін: ' + (Format-T1Result -Result $worker.Result))
            $repairPlan = (New-T1Plan -Sandbox $sb -Operation Repair -Release $releaseN).Plan
            $versionBlockers = @((Get-T1BlockerIds -Plan $repairPlan) | Where-Object { $_ -in @('Plan.RepairVersionMismatch', 'Plan.UpdateSameVersion', 'Plan.UpdateDowngrade') })
            Test-BRAVOCondition -Condition (($null -ne $repairPlan) -and ($versionBlockers.Count -eq 0)) -Name 'UpdateEndToEnd/SameVersion/RepairPlanAllowedForSameVersion' -Failure ('Repair тієї ж версії не має version-blocker-ів: ' + ($versionBlockers -join ','))
        }

        # ================================================================
        # 3. Upgrade N -> N+1 на тому самому сервері (після clean install) (INS-131)
        # ================================================================
        & {
            $sb = $e2eInstallSb
            # Оператор активував планувальник і накопичив site-дані після встановлення.
            $sb.Cfg.Tasks['BRAVO_A'] = $true
            Write-T1File (Join-Path $sb.Runtime 'LOGS\a.log') 'лог оператора'
            Write-T1File (Join-Path $sb.Runtime 'BAZA\db.dat') 'дані оператора'
            Write-T1File (Join-Path $sb.Runtime 'TOOLS_INTEGRITY.json') '{"site":true}'
            Write-T1File (Join-Path $sb.Runtime 'WinSCP.ini') 'ini'
            $pre = Get-T1Snapshot -Sandbox $sb
            $planResult = New-T1Plan -Sandbox $sb -Operation Update -Release $releaseN1
            $plan = $planResult.Plan
            Test-BRAVOCondition -Condition (($null -ne $plan) -and (@(Get-T1BlockerIds -Plan $plan).Count -eq 0) -and ([string]$plan.currentVersion -ceq '5.2.6') -and ([string]$plan.targetVersion -ceq '5.3.0')) -Name 'UpdateEndToEnd/Upgrade/PlanClean' `
                -Failure ('план Update без blocker-ів 5.2.6 -> 5.3.0: ' + $(if ($null -eq $plan) { 'не побудовано' } else { (Get-T1BlockerIds -Plan $plan) -join ',' }))
            if ($null -eq $plan) { return }
            $sb.Cfg.TaskLog.Clear()
            $result = Invoke-T1Update -Sandbox $sb -Plan $plan -Release $releaseN1
            $problems = @(Get-T1ResultProblem -Sandbox $sb -Result $result)
            Test-BRAVOCondition -Condition (($result.status -ceq 'Success') -and ($result.exitCode -eq 0) -and ([string]$result.installedVersion -ceq '5.3.0') -and ($problems.Count -eq 0)) -Name 'UpdateEndToEnd/Upgrade/Success' `
                -Failure ((Format-T1Result -Result $result) + ' problems=' + ($problems -join ';'))
            $post = Get-T1Snapshot -Sandbox $sb
            Test-BRAVOCondition -Condition (Test-T1RuntimeMatchesRelease -Runtime $sb.Runtime -Release $releaseN1) -Name 'UpdateEndToEnd/Upgrade/RuntimeMatchesNewRelease' -Failure 'Після upgrade runtime не збігається з manifest N+1.'
            Test-BRAVOCondition -Condition (-not (Test-T1PathExists -Path (Join-Path $sb.Runtime 'modules\Старий модуль'))) -Name 'UpdateEndToEnd/Upgrade/RemovedFileAndEmptyDirGone' -Failure 'Файл і порожній каталог старого релізу мають зникнути.'
            Test-BRAVOCondition -Condition ($post.Site -ceq $pre.Site) -Name 'UpdateEndToEnd/Upgrade/SiteFilesByteIdentical' -Failure ('Site-файли змінились: до=' + $pre.Site + ' після=' + $post.Site)
            Test-BRAVOCondition -Condition ($post.Tasks -ceq 'BRAVO_A=on,BRAVO_B=off') -Name 'UpdateEndToEnd/Upgrade/PreviousEnabledTasksRestored' -Failure ('Задачі після upgrade: ' + $post.Tasks)
            $log = $sb.Cfg.TaskLog.ToArray()
            $firstA = [array]::IndexOf($log, 'BRAVO_A=False')
            $lastA = [array]::LastIndexOf($log, 'BRAVO_A=True')
            Test-BRAVOCondition -Condition (($firstA -ge 0) -and ($lastA -gt $firstA)) -Name 'UpdateEndToEnd/Upgrade/TasksQuiescedThenReactivated' -Failure ('Порядок змін задач: ' + ($log -join ','))
            $versionState = [IO.File]::ReadAllText($sb.VersionState)
            Test-BRAVOCondition -Condition ($versionState.Contains('"highestVersion":"5.3.0"')) -Name 'UpdateEndToEnd/Upgrade/VersionStateReflectsNewVersion' -Failure $versionState
            $opId = [string]$plan.operationId
            Test-BRAVOCondition -Condition ([IO.File]::Exists((Join-Path $sb.Backup ($opId + '\backup-manifest.json'))) -and (-not (Test-T1PathExists -Path (Join-Path $sb.Staging $opId)))) -Name 'UpdateEndToEnd/Upgrade/BackupKeptStagingRemoved' -Failure 'Backup має лишитись, staging -- зникнути.'
            $journal = Read-T1Journal -Sandbox $sb -Plan $plan
            $phases = @(@($journal.phases) | ForEach-Object { [string]$_.phase })
            Test-BRAVOCondition -Condition (([string]$journal.state -ceq 'Committed') -and ($phases -join ',') -ceq 'Backup,QuiesceTasks,Deploy,ConfigureScheduler,Activate,Commit') -Name 'UpdateEndToEnd/Upgrade/JournalCommittedWithAllPhases' -Failure ([string]$journal.state + ' phases=' + ($phases -join ','))
            $events = @(Read-BRAVOUpdateProgressEvents -Path (Join-Path $sb.State ('Operations\' + $opId + '\progress.jsonl')))
            $monotonic = $true
            for ($i = 1; $i -lt $events.Count; $i++) { if ([long]$events[$i].sequence -le [long]$events[$i - 1].sequence) { $monotonic = $false } }
            Test-BRAVOCondition -Condition (($events.Count -gt 10) -and $monotonic -and ($events[$events.Count - 1].phase -ceq 'Commit') -and ($events[$events.Count - 1].status -ceq 'Completed')) -Name 'UpdateEndToEnd/Upgrade/ProgressStreamComplete' -Failure ('подій=' + $events.Count)
            $state = Get-BRAVOInstallationState -RuntimeRoot $sb.Runtime -StateRoot $sb.State -VersionStatePath $sb.VersionState -OperationLockPath $sb.OpLock -LockRoot $sb.Lock -Adapter $sb.Adapter
            Test-BRAVOCondition -Condition (([string]$state.integrity.status -ceq 'Valid') -and ([string]$state.version.packageVersion -ceq '5.3.0')) -Name 'UpdateEndToEnd/Upgrade/DiscoveryReportsValidNewVersion' -Failure ('integrity=' + $state.integrity.status + ' version=' + $state.version.packageVersion + ' state=' + $state.state)
        }

        # ================================================================
        # 4. Downgrade N+1 -> N: блокується до mutation (35) (INS-132)
        # ================================================================
        & {
            # (a) Version-state запам'ятав 5.3.0: старіший пакет не проходить уже верифікацію при побудові плану.
            $sb = New-T1Sandbox -Name 'downgrade' -Installed $releaseN1
            $pre = Get-T1Snapshot -Sandbox $sb
            $planned = New-T1Plan -Sandbox $sb -Operation Update -Release $releaseN
            $hint35 = @(@($planned.Findings) | Where-Object { ([string]$_.severity -ceq 'Blocker') -and ($null -ne $_.PSObject.Properties['exitCodeHint']) -and ($_.exitCodeHint -eq 35) })
            Test-BRAVOCondition -Condition (($null -eq $planned.Plan) -and ($hint35.Count -gt 0) -and ((Get-T1Snapshot -Sandbox $sb).Tree -ceq $pre.Tree)) -Name 'UpdateEndToEnd/Downgrade/RecordedVersionStateRefusesOlderPackage' `
                -Failure ('plan=' + ($null -ne $planned.Plan) + ' findings=' + ((@($planned.Findings) | ForEach-Object { $_.id + ':' + $_.exitCodeHint }) -join ','))

            # (b) Без version-state (його ще не було) старіший пакет доходить до плану, де це blocker 35.
            $sbNoState = New-T1Sandbox -Name 'downgrade-nostate' -Installed $releaseN1
            [IO.File]::Delete($sbNoState.VersionState)
            $plan = (New-T1Plan -Sandbox $sbNoState -Operation Update -Release $releaseN).Plan
            $down = @(@($plan.findings) | Where-Object { [string]$_.id -ceq 'Plan.UpdateDowngrade' })
            Test-BRAVOCondition -Condition (($down.Count -eq 1) -and ([int]$down[0].exitCodeHint -eq 35)) -Name 'UpdateEndToEnd/Downgrade/PlanBlockerHint35' -Failure ('blockers=' + ((Get-T1BlockerIds -Plan $plan) -join ','))
            $preNoState = Get-T1Snapshot -Sandbox $sbNoState
            $worker = Invoke-T1Worker -Sandbox $sbNoState -Plan $plan -SourcePath $releaseN.Zip
            Test-BRAVOCondition -Condition (($worker.Out.ExitCode -eq 35) -and ($worker.Result.status -ceq 'Failed') -and (-not $worker.Result.mutationStarted) -and ((Get-T1Snapshot -Sandbox $sbNoState).Tree -ceq $preNoState.Tree) -and (@(Get-ChildItem -LiteralPath $sbNoState.Staging -Force -ErrorAction SilentlyContinue).Count -eq 0)) `
                -Name 'UpdateEndToEnd/Downgrade/WorkerBlocks35NoMutation' -Failure (Format-T1Result -Result $worker.Result)
            Test-BRAVOCondition -Condition (@(Get-ChildItem -LiteralPath (Join-Path $sbNoState.State 'Journal') -File -ErrorAction SilentlyContinue).Count -eq 0) -Name 'UpdateEndToEnd/Downgrade/NoJournalCreated' -Failure 'Заблокований downgrade не має створювати журнал.'

            # (c) Навіть якщо план без blocker-ів передали engine напряму, version-state зупиняє Verify (35) до mutation.
            $sbDirect = New-T1Sandbox -Name 'downgrade-direct' -Installed $releaseN1
            $directPlan = Copy-T1Plan -Template $plan -Sandbox $sbDirect
            $directPlan.findings = @()
            $directCase = [pscustomobject]@{ Sb = $sbDirect; Plan = $directPlan; Pre = (Get-T1Snapshot -Sandbox $sbDirect) }
            $direct = Invoke-T1Update -Sandbox $sbDirect -Plan $directPlan -Release $releaseN
            $problems = @(Get-T1PreBoundaryProblem -Case $directCase -Result $direct -Reason 'VerificationFailed' -ExitCode 35)
            Test-BRAVOCondition -Condition ($problems.Count -eq 0) -Name 'UpdateEndToEnd/Downgrade/EngineVerifyRefusesAgainstVersionState' -Failure (($problems -join '; ') + ' | ' + (Format-T1Result -Result $direct))

            # Обхід захисту змінною середовища заборонено і для engine, і для worker.
            $previousOverride = [Environment]::GetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE')
            [Environment]::SetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE', '1')
            try {
                $sbEnv = New-T1Sandbox -Name 'downgrade-env' -Installed $releaseN1
                $envPlan = Copy-T1Plan -Template $plan -Sandbox $sbEnv
                $envPlan.findings = @()
                $envPre = Get-T1Snapshot -Sandbox $sbEnv
                $engine = Invoke-T1Update -Sandbox $sbEnv -Plan $envPlan -Release $releaseN
                $viaWorker = Invoke-T1Worker -Sandbox $sbEnv -Plan (Copy-T1Plan -Template $envPlan -Sandbox $sbEnv) -SourcePath $releaseN.Zip
            } finally {
                [Environment]::SetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE', $previousOverride)
            }
            Test-BRAVOCondition -Condition (($engine.status -ceq 'Failed') -and ($engine.exitCode -eq 35) -and ($viaWorker.Out.ExitCode -eq 35) -and ((Get-T1Snapshot -Sandbox $sbEnv).Tree -ceq $envPre.Tree)) `
                -Name 'UpdateEndToEnd/Downgrade/AllowDowngradeEnvRefused' -Failure ('engine: ' + (Format-T1Result -Result $engine) + ' | worker exit=' + $viaWorker.Out.ExitCode)
        }

        # ================================================================
        # 5. Prerelease без дозволу і з дозволом (INS-133)
        # ================================================================
        & {
            $releasePre = New-T1Release -Base (Join-Path $e2eRoot 'release-Pre') -Tag 'v5.4.0-rc.1' -Commit ('b' * 40) -Variant Pre -Channel 'prerelease'
            $sb = New-T1Sandbox -Name 'pre-denied' -Installed $releaseN1
            $deniedPlan = New-T1Plan -Sandbox $sb -Operation Update -Release $releasePre
            $hint42 = @(@($deniedPlan.Findings) | Where-Object { ([string]$_.severity -ceq 'Blocker') -and ($null -ne $_.PSObject.Properties['exitCodeHint']) -and ($_.exitCodeHint -eq 42) })
            Test-BRAVOCondition -Condition (($null -eq $deniedPlan.Plan) -and ($hint42.Count -gt 0)) -Name 'UpdateEndToEnd/Prerelease/DeniedWithoutAuthorization' `
                -Failure ('Без дозволу план не будується (blocker 42): plan=' + ($null -ne $deniedPlan.Plan) + ' findings=' + ((@($deniedPlan.Findings) | ForEach-Object { $_.id }) -join ','))

            $sbOk = New-T1Sandbox -Name 'pre-allowed' -Installed $releaseN1
            $okPlan = (New-T1Plan -Sandbox $sbOk -Operation Update -Release $releasePre -AllowPrerelease).Plan
            Test-BRAVOCondition -Condition (($null -ne $okPlan) -and ($okPlan.source.prereleaseAuthorized -eq $true) -and (@(Get-T1BlockerIds -Plan $okPlan).Count -eq 0)) -Name 'UpdateEndToEnd/Prerelease/AuthorizedPlanBuilt' `
                -Failure ('З дозволом план без blocker-ів: ' + $(if ($null -eq $okPlan) { 'не побудовано' } else { (Get-T1BlockerIds -Plan $okPlan) -join ',' }))
            if ($null -ne $okPlan) {
                $okResult = Invoke-T1Update -Sandbox $sbOk -Plan $okPlan -Release $releasePre
                $problems = @(Get-T1ResultProblem -Sandbox $sbOk -Result $okResult)
                Test-BRAVOCondition -Condition ((@('Success', 'SuccessWithWarnings') -ccontains [string]$okResult.status) -and ([string]$okResult.installedVersion -ceq '5.4.0-rc.1') -and (Test-T1RuntimeMatchesRelease -Runtime $sbOk.Runtime -Release $releasePre) -and ($problems.Count -eq 0)) `
                    -Name 'UpdateEndToEnd/Prerelease/AuthorizedUpdateSucceeds' -Failure ((Format-T1Result -Result $okResult) + ' problems=' + ($problems -join ';'))
            }

            # Defense in depth: план без дозволу, виконаний engine, відхиляється на Verify.
            $sbTamper = New-T1Sandbox -Name 'pre-flag' -Installed $releaseN1
            $tamperPlan = (New-T1Plan -Sandbox $sbTamper -Operation Update -Release $releasePre -AllowPrerelease).Plan
            if ($null -ne $tamperPlan) {
                $tamperPlan.source.prereleaseAuthorized = $false
                $case = [pscustomobject]@{ Sb = $sbTamper; Plan = $tamperPlan; Pre = (Get-T1Snapshot -Sandbox $sbTamper) }
                $result = Invoke-T1Update -Sandbox $sbTamper -Plan $tamperPlan -Release $releasePre
                $problems = @(Get-T1PreBoundaryProblem -Case $case -Result $result -Reason 'VerificationFailed' -ExitCode 42)
                Test-BRAVOCondition -Condition ($problems.Count -eq 0) -Name 'UpdateEndToEnd/Prerelease/UnauthorizedPlanRejectedByVerify' -Failure ($problems -join '; ')
            }
        }

        # ================================================================
        # 6. Пошкоджений артефакт / неправильний хеш / неправильний manifest (42) (INS-134)
        # ================================================================
        & {
            function New-T1TamperedRelease {
                param([string]$Case)
                $dir = Join-Path $e2eRoot ('tamper_' + $Case + '_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
                [void](New-Item -ItemType Directory -Path $dir -Force)
                foreach ($file in (Get-ChildItem -LiteralPath $releaseN1.Out -File)) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $dir $file.Name) }
                $zip = Join-Path $dir ([IO.Path]::GetFileName($releaseN1.Zip))
                $manifest = Join-Path $dir 'release-manifest.json'
                switch ($Case) {
                    'zip-flipped-byte' {
                        $bytes = [IO.File]::ReadAllBytes($zip)
                        $bytes[[int]($bytes.Length / 2)] = [byte]($bytes[[int]($bytes.Length / 2)] -bxor 0xFF)
                        [IO.File]::WriteAllBytes($zip, $bytes)
                    }
                    'checksum-wrong' { Write-T1File ($zip + '.sha256') (('0' * 64) + ' *' + [IO.Path]::GetFileName($zip) + "`n") }
                    'manifest-file-size' {
                        $doc = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json
                        $doc.files[0].sizeBytes = [long]$doc.files[0].sizeBytes + 1
                        Write-T1File $manifest ($doc | ConvertTo-Json -Depth 5)
                    }
                    'manifest-script-unlisted' {
                        $doc = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json
                        $doc.files = @($doc.files | Where-Object { [string]$_.path -cne 'BRAVO_SETUP.ps1' })
                        Write-T1File $manifest ($doc | ConvertTo-Json -Depth 5)
                    }
                    'manifest-missing' { [IO.File]::Delete($manifest) }
                    'manifest-swapped-after-plan' {
                        $doc = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json
                        $doc.generatedUtc = '2026-09-14T00:00:00Z'
                        Write-T1File $manifest ($doc | ConvertTo-Json -Depth 5)
                    }
                }
                return $zip
            }
            foreach ($case in @('zip-flipped-byte', 'checksum-wrong', 'manifest-file-size', 'manifest-script-unlisted', 'manifest-missing', 'manifest-swapped-after-plan')) {
                $zip = New-T1TamperedRelease -Case $case
                if ($case -cne 'manifest-swapped-after-plan') {
                    $sbPlan = New-T1Sandbox -Name 'tamper-plan' -Installed $releaseN
                    $planned = New-T1Plan -Sandbox $sbPlan -Operation Update -Release $releaseN1 -SourcePath $zip
                    $blocker42 = @(@($planned.Findings) | Where-Object { ([string]$_.severity -ceq 'Blocker') -and ($null -ne $_.PSObject.Properties['exitCodeHint']) -and ($_.exitCodeHint -eq 42) })
                    Test-BRAVOCondition -Condition (($null -eq $planned.Plan) -and ($blocker42.Count -gt 0)) -Name ('UpdateEndToEnd/Tamper/' + $case + '/PlanRefused') -Failure ('Конвеєр плану має відхилити артефакт (42): plan=' + ($null -ne $planned.Plan) + ' findings=' + ((@($planned.Findings) | ForEach-Object { $_.id }) -join ','))
                }
                $execCase = New-T1UpdateCase -Name 'tamper-exec'
                $result = Invoke-T1Update -Sandbox $execCase.Sb -Plan $execCase.Plan -Release $releaseN1 -SourcePath $zip
                $problems = @(Get-T1PreBoundaryProblem -Case $execCase -Result $result -Reason 'VerificationFailed' -ExitCode 42)
                Test-BRAVOCondition -Condition ($problems.Count -eq 0) -Name ('UpdateEndToEnd/Tamper/' + $case + '/EngineRefusesBeforeMutation') -Failure (($problems -join '; ') + ' | ' + (Format-T1Result -Result $result))
            }
        }

        # ================================================================
        # 7. Failure injection: КОЖЕН ключ FaultInjection з Deploy.ps1 (INS-135)
        # ================================================================
        & {
            $deploySource = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.Deploy.ps1'))
            $phasesInSource = @([regex]::Matches($deploySource, 'Invoke-BRAVOUpdatePhase -Context \$\w+ -Phase ''(\w+)''') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $backupSource = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.Backup.ps1'))
            $countKeysInSource = @([regex]::Matches($deploySource + $backupSource, '''(\w+\.AfterFileCount)''') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $prePhases = @('Acquire', 'Verify', 'Stage', 'StageValidation', 'PlanRecheck', 'OperationLock', 'Baseline', 'Backup')
            $postPhases = @('QuiesceTasks', 'Deploy', 'ConfigureScheduler', 'Validate', 'Commit')
            $special = @('MutationBoundary', 'Activate')
            $known = @($prePhases + $postPhases + $special | Sort-Object -Unique)
            Test-BRAVOCondition -Condition (($phasesInSource -join ',') -ceq ($known -join ',')) -Name 'UpdateEndToEnd/FaultMatrix/PhaseListMatchesSource' `
                -Failure ('Список фаз у тесті не збігається з Deploy.ps1: джерело=' + ($phasesInSource -join ',') + ' тест=' + ($known -join ','))
            Test-BRAVOCondition -Condition (($countKeysInSource -join ',') -ceq 'Backup.AfterFileCount,Deploy.AfterFileCount') -Name 'UpdateEndToEnd/FaultMatrix/CountKeysMatchSource' -Failure ('ключі AfterFileCount у джерелі: ' + ($countKeysInSource -join ','))

            $points = @('Before', 'AfterIntent', 'AfterSideEffect', 'AfterComplete')
            $run = {
                param([string]$Key, $Mode, [string]$Kind)
                $case = New-T1UpdateCase -Name 'fault'
                $result = Invoke-T1Update -Sandbox $case.Sb -Plan $case.Plan -Release $releaseN1 -Fault @{ $Key = $Mode }
                $problems = @()
                if ($Kind -ceq 'Pre') { $problems = @(Get-T1PreBoundaryProblem -Case $case -Result $result) }
                elseif ($Kind -ceq 'Post') { $problems = @(Get-T1RolledBackProblem -Case $case -Result $result) }
                else {
                    # Activate: після успішної Validate збій активації не відкочує розгортання (warning, Committed).
                    $problems = @(Get-T1ResultProblem -Sandbox $case.Sb -Result $result)
                    if ([string]$result.status -cne 'SuccessWithWarnings') { $problems += ('status=' + $result.status) }
                    if ((Get-T1FindingIds -Result $result) -cnotcontains 'Activate.Failed') { $problems += 'немає finding Activate.Failed' }
                    if ((Get-T1JournalState -Sandbox $case.Sb -Plan $case.Plan) -cne 'Committed') { $problems += 'журнал не Committed' }
                    if (-not (Test-T1RuntimeMatchesRelease -Runtime $case.Sb.Runtime -Release $releaseN1)) { $problems += 'runtime не відповідає N+1' }
                    if ($Key -like '*Before' -or $Key -like '*AfterIntent') {
                        if ((Get-T1TaskState -Sandbox $case.Sb) -cne 'BRAVO_A=off,BRAVO_B=off') { $problems += ('задачі мають лишитись вимкненими: ' + (Get-T1TaskState -Sandbox $case.Sb)) }
                    } elseif ((Get-T1TaskState -Sandbox $case.Sb) -cne 'BRAVO_A=on,BRAVO_B=off') {
                        $problems += ('задачі мають бути відновлені: ' + (Get-T1TaskState -Sandbox $case.Sb))
                    }
                }
                Test-BRAVOCondition -Condition ($problems.Count -eq 0) -Name ('UpdateEndToEnd/FaultMatrix/' + $Key + '=' + $Mode) -Failure (($problems -join '; ') + ' | ' + (Format-T1Result -Result $result))
            }
            foreach ($phase in $prePhases) { foreach ($point in $points) { & $run ($phase + '.' + $point) 'Throw' 'Pre' } }
            # MutationBoundary: Before/AfterIntent ще ДО межі, AfterSideEffect/AfterComplete уже після неї.
            & $run 'MutationBoundary.Before' 'Throw' 'Pre'
            & $run 'MutationBoundary.AfterIntent' 'Throw' 'Pre'
            & $run 'MutationBoundary.AfterSideEffect' 'Throw' 'Post'
            & $run 'MutationBoundary.AfterComplete' 'Throw' 'Post'
            foreach ($phase in $postPhases) { foreach ($point in $points) { & $run ($phase + '.' + $point) 'Throw' 'Post' } }
            foreach ($point in $points) { & $run ('Activate.' + $point) 'Throw' 'Activate' }
            & $run 'Backup.AfterFileCount' 2 'Pre'
            & $run 'Deploy.AfterFileCount' 1 'Post'
            & $run 'Deploy.AfterFileCount' 3 'Post'

            # Cancel: до межі -> Failed/Cancelled (Abandoned); після межі -> RolledBack + finding.
            $cancelPre = New-T1UpdateCase -Name 'cancel-pre'
            $cancelPreResult = Invoke-T1Update -Sandbox $cancelPre.Sb -Plan $cancelPre.Plan -Release $releaseN1 -Fault @{ 'Stage.AfterComplete' = 'Cancel' }
            $problems = @(Get-T1PreBoundaryProblem -Case $cancelPre -Result $cancelPreResult -Reason 'Cancelled' -ExitCode 80)
            Test-BRAVOCondition -Condition ($problems.Count -eq 0) -Name 'UpdateEndToEnd/FaultMatrix/CancelBeforeMutation' -Failure (($problems -join '; ') + ' | ' + (Format-T1Result -Result $cancelPreResult))
            $cancelPost = New-T1UpdateCase -Name 'cancel-post'
            $cancelPostResult = Invoke-T1Update -Sandbox $cancelPost.Sb -Plan $cancelPost.Plan -Release $releaseN1 -Fault @{ 'QuiesceTasks.AfterComplete' = 'Cancel' }
            $problems = @(Get-T1RolledBackProblem -Case $cancelPost -Result $cancelPostResult)
            if ((Get-T1FindingIds -Result $cancelPostResult) -cnotcontains 'Operation.CancelledAfterMutation') { $problems += 'немає finding Operation.CancelledAfterMutation' }
            Test-BRAVOCondition -Condition ($problems.Count -eq 0) -Name 'UpdateEndToEnd/FaultMatrix/CancelAfterMutationRollsBack' -Failure (($problems -join '; ') + ' | ' + (Format-T1Result -Result $cancelPostResult))
        }

        # ================================================================
        # 8. Crash у кожній durable-фазі -> стан -> Recovery -> стан до оновлення (INS-136)
        # ================================================================
        & {
            $crashCases = @(
                @{ Key = 'Stage.AfterSideEffect'; Expect = 'Abandoned' }
                @{ Key = 'Backup.AfterIntent'; Expect = 'Abandoned' }
                @{ Key = 'MutationBoundary.AfterIntent'; Expect = 'Abandoned' }
                @{ Key = 'MutationBoundary.AfterSideEffect'; Expect = 'RolledBack' }
                @{ Key = 'QuiesceTasks.AfterIntent'; Expect = 'RolledBack' }
                @{ Key = 'Deploy.AfterSideEffect'; Expect = 'RolledBack' }
                @{ Key = 'ConfigureScheduler.AfterIntent'; Expect = 'RolledBack' }
                @{ Key = 'Validate.Before'; Expect = 'RolledBack' }
                @{ Key = 'Activate.AfterIntent'; Expect = 'RolledBack' }
                @{ Key = 'Commit.AfterSideEffect'; Expect = 'RolledBack' }
            )
            $index = 0
            foreach ($crash in $crashCases) {
                $index++
                $case = New-T1UpdateCase -Name 'crash'
                $sb = $case.Sb
                $thrown = ''
                try { [void](Invoke-T1Update -Sandbox $sb -Plan $case.Plan -Release $releaseN1 -Fault @{ $crash.Key = 'Crash' }) } catch { $thrown = [string]$_.Exception.Message }
                $name = 'UpdateEndToEnd/Crash/' + $crash.Key
                Test-BRAVOCondition -Condition ($thrown.StartsWith('BRAVOUpdate.SimulatedCrash', [StringComparison]::Ordinal)) -Name ($name + '/ProcessDies') -Failure ('Crash має виходити винятком SimulatedCrash: ' + $thrown)
                $journalState = Get-T1JournalState -Sandbox $sb -Plan $case.Plan
                $discovered = Get-BRAVOInstallationState -RuntimeRoot $sb.Runtime -StateRoot $sb.State -VersionStatePath $sb.VersionState -OperationLockPath $sb.OpLock -LockRoot $sb.Lock -Adapter $sb.Adapter
                $expectedState = 'RollbackRequired'; if ($crash.Expect -ceq 'Abandoned') { $expectedState = 'InterruptedUpdate' }
                Test-BRAVOCondition -Condition (($journalState -ceq 'Open') -and ([string]$discovered.state -ceq $expectedState) -and (Test-T1LocksFree -Sandbox $sb)) -Name ($name + '/JournalOpenStateReported') `
                    -Failure ('журнал=' + $journalState + ' state=' + $discovered.state + ' (очікувалось Open/' + $expectedState + ') lock-и вільні=' + (Test-T1LocksFree -Sandbox $sb))
                if ($index -le 2) {
                    $blockedPlan = New-T1Plan -Sandbox $sb -Operation Update -Release $releaseN1
                    Test-BRAVOCondition -Condition (@(Get-T1BlockerIds -Plan $blockedPlan.Plan).Count -gt 0) -Name ($name + '/NewPlanBlockedWhileJournalOpen') -Failure 'Нова операція при відкритому журналі має бути заблокована preflight-ом.'
                }
                $recovery = Invoke-T1Recovery -Sandbox $sb
                $recoveryProblems = New-Object System.Collections.Generic.List[string]
                $afterRecovery = Get-T1Snapshot -Sandbox $sb
                $diff = @(Get-T1SnapshotDiff -Before $case.Pre -After $afterRecovery)
                if ($diff.Count -gt 0) { $recoveryProblems.Add('після recovery змінено: ' + ($diff -join ',')) }
                $validRecovery = Test-BRAVOUpdateDeploymentResult -InputObject $recovery
                if (-not $validRecovery.IsValid) { $recoveryProblems.Add('результат recovery не валідний: ' + ($validRecovery.Problems -join ';')) }
                if ([string]$recovery.action -cne 'Recovery') { $recoveryProblems.Add('action=' + $recovery.action) }
                if ($crash.Expect -ceq 'Abandoned') {
                    if (([string]$recovery.status -cne 'Failed') -or ((Get-T1FindingIds -Result $recovery) -cnotcontains 'Recovery.AbandonedBeforeMutation')) { $recoveryProblems.Add('очікувалось Failed/Recovery.AbandonedBeforeMutation: ' + (Format-T1Result -Result $recovery)) }
                    if ((Get-T1JournalState -Sandbox $sb -Plan $case.Plan) -cne 'Abandoned') { $recoveryProblems.Add('журнал не Abandoned') }
                    if ((Test-T1PathExists -Path (Join-Path $sb.Staging ([string]$case.Plan.operationId))) -or (Test-T1PathExists -Path (Join-Path $sb.Backup ([string]$case.Plan.operationId)))) { $recoveryProblems.Add('staging/backup операції лишились') }
                } else {
                    if (([string]$recovery.status -cne 'RolledBack') -or ([int]$recovery.exitCode -ne 81)) { $recoveryProblems.Add('очікувалось RolledBack/81: ' + (Format-T1Result -Result $recovery)) }
                    if ((Get-T1JournalState -Sandbox $sb -Plan $case.Plan) -cne 'RolledBack') { $recoveryProblems.Add('журнал не RolledBack') }
                }
                Test-BRAVOCondition -Condition ($recoveryProblems.Count -eq 0) -Name ($name + '/RecoveryRestoresPreUpdateState') -Failure ($recoveryProblems -join '; ')
                $second = Invoke-T1Recovery -Sandbox $sb
                Test-BRAVOCondition -Condition (([string]$second.status -ceq 'Success') -and ($second.exitCode -eq 0) -and ((Get-T1FindingIds -Result $second) -contains 'Recovery.NothingToRecover') -and (@(Get-T1SnapshotDiff -Before $afterRecovery -After (Get-T1Snapshot -Sandbox $sb)).Count -eq 0)) `
                    -Name ($name + '/SecondRecoveryIsNoOp') -Failure (Format-T1Result -Result $second)
            }

            # Crash усередині самого rollback (після збою Deploy): recovery доводить відкат до кінця.
            $case = New-T1UpdateCase -Name 'crash-rollback'
            $sb = $case.Sb
            $thrown = ''
            try { [void](Invoke-T1Update -Sandbox $sb -Plan $case.Plan -Release $releaseN1 -Fault @{ 'Deploy.AfterIntent' = 'Throw'; 'Rollback.RestoreFiles.AfterIntent' = 'Crash' }) } catch { $thrown = [string]$_.Exception.Message }
            $journal = Read-T1Journal -Sandbox $sb -Plan $case.Plan
            Test-BRAVOCondition -Condition ($thrown.StartsWith('BRAVOUpdate.SimulatedCrash', [StringComparison]::Ordinal) -and ([string]$journal.state -ceq 'Open') -and ([int]$journal.rollbackAttempts -eq 1)) -Name 'UpdateEndToEnd/Crash/InsideRollback/JournalOpenAttemptRecorded' `
                -Failure ('thrown=' + $thrown + ' state=' + $journal.state + ' attempts=' + $journal.rollbackAttempts)
            $recovery = Invoke-T1Recovery -Sandbox $sb
            $diff = @(Get-T1SnapshotDiff -Before $case.Pre -After (Get-T1Snapshot -Sandbox $sb))
            Test-BRAVOCondition -Condition (([string]$recovery.status -ceq 'RolledBack') -and ($diff.Count -eq 0) -and ((Get-T1JournalState -Sandbox $sb -Plan $case.Plan) -ceq 'RolledBack')) -Name 'UpdateEndToEnd/Crash/InsideRollback/RecoveryCompletesRollback' `
                -Failure ((Format-T1Result -Result $recovery) + ' змінено: ' + ($diff -join ','))
        }

        # ================================================================
        # 9. Збій відкату: пошкоджений backup -> Critical (82) (INS-137)
        # ================================================================
        & {
            $case = New-T1UpdateCase -Name 'critical'
            $sb = $case.Sb
            $opId = [string]$case.Plan.operationId
            $hookState = @{ Done = $false }
            $backupRoot = $sb.Backup
            # Хук спрацьовує на першому читанні задач ПІСЛЯ створення backup (фаза Baseline): псуємо файл у backup.
            $sb.Cfg.Hook = {
                if ($hookState.Done) { return }
                $victim = Join-Path $backupRoot ($opId + '\runtime\BRAVO_RUNTIME_GUARD.ps1')
                if ([IO.File]::Exists($victim)) {
                    [IO.File]::WriteAllText($victim, '# CORRUPTED BACKUP COPY', (New-Object System.Text.UTF8Encoding($false)))
                    $hookState.Done = $true
                }
            }.GetNewClosure()
            $result = Invoke-T1Update -Sandbox $sb -Plan $case.Plan -Release $releaseN1 -Fault @{ 'Deploy.AfterSideEffect' = 'Throw' }
            $sb.Cfg.Hook = $null
            $problems = @(Get-T1ResultProblem -Sandbox $sb -Result $result)
            Test-BRAVOCondition -Condition ($hookState.Done -and ([string]$result.status -ceq 'Critical') -and ($result.exitCode -eq 82) -and ($problems.Count -eq 0)) -Name 'UpdateEndToEnd/RollbackFailure/CriticalExit82' `
                -Failure ('backup зіпсовано=' + $hookState.Done + ' ' + (Format-T1Result -Result $result) + ' problems=' + ($problems -join ';'))
            Test-BRAVOCondition -Condition ((Get-T1JournalState -Sandbox $sb -Plan $case.Plan) -ceq 'Critical') -Name 'UpdateEndToEnd/RollbackFailure/JournalCritical' -Failure (Get-T1JournalState -Sandbox $sb -Plan $case.Plan)
            Test-BRAVOCondition -Condition ((Get-T1TaskState -Sandbox $sb) -ceq 'BRAVO_A=off,BRAVO_B=off') -Name 'UpdateEndToEnd/RollbackFailure/TasksDisabled' -Failure ('Після Critical задачі мають бути вимкнені: ' + (Get-T1TaskState -Sandbox $sb))
            Test-BRAVOCondition -Condition ([IO.File]::Exists((Join-Path $sb.Backup ($opId + '\backup-manifest.json')))) -Name 'UpdateEndToEnd/RollbackFailure/BackupPreservedForManualRecovery' -Failure 'Backup операції має лишитись для ручного відновлення.'
            # Наступний Update не повинен проходити preflight: сервер у невизначеному стані.
            $next = New-T1Plan -Sandbox $sb -Operation Update -Release $releaseN1
            $nextBlockers = @()
            if ($null -ne $next.Plan) { $nextBlockers = @(Get-T1BlockerIds -Plan $next.Plan) }
            Test-BRAVOCondition -Condition (($null -eq $next.Plan) -or ($nextBlockers.Count -gt 0)) -Name 'UpdateEndToEnd/RollbackFailure/NextUpdateBlockedByPreflight' `
                -Failure 'ПОМИЛКА ПРОДУКТУ (Journal.ps1 Get-BRAVOUpdateOpenJournal / Plan.ps1 Get-BRAVOUpdatePlanOpenJournalId): журнал у стані Critical не блокує нові операції (враховується лише state=Open), preflight не знаходить blocker-ів після невдалого відкату.'
            if (($null -ne $next.Plan) -and ($nextBlockers.Count -gt 0)) {
                $worker = Invoke-T1Worker -Sandbox $sb -Plan $next.Plan -SourcePath $releaseN1.Zip
                Test-BRAVOCondition -Condition (($worker.Result.status -ceq 'Failed') -and (-not $worker.Result.mutationStarted)) -Name 'UpdateEndToEnd/RollbackFailure/WorkerRefusesNextUpdate' -Failure (Format-T1Result -Result $worker.Result)
            }
        }

        # ================================================================
        # 10. Repair тієї ж версії (INS-070/071 end-to-end)
        # ================================================================
        & {
            $sb = New-T1Sandbox -Name 'repair' -Installed $releaseN
            $guardPath = Join-Path $sb.Runtime 'BRAVO_RUNTIME_GUARD.ps1'
            Write-T1File $guardPath '# tampered guard'
            [IO.File]::Delete((Join-Path $sb.Runtime 'BRAVO_CONFIG_LOADER.ps1'))
            $stateBefore = Get-BRAVOInstallationState -RuntimeRoot $sb.Runtime -StateRoot $sb.State -VersionStatePath $sb.VersionState -OperationLockPath $sb.OpLock -LockRoot $sb.Lock -Adapter $sb.Adapter
            Test-BRAVOCondition -Condition (([string]$stateBefore.integrity.status -ceq 'Invalid') -and ([string]$stateBefore.state -ceq 'RepairRequired')) -Name 'UpdateEndToEnd/Repair/DamageDetected' -Failure ('integrity=' + $stateBefore.integrity.status + ' state=' + $stateBefore.state)
            $repairPlan = (New-T1Plan -Sandbox $sb -Operation Repair -Release $releaseN).Plan
            Test-BRAVOCondition -Condition (($null -ne $repairPlan) -and (@(Get-T1BlockerIds -Plan $repairPlan).Count -eq 0)) -Name 'UpdateEndToEnd/Repair/PlanClean' -Failure ('blockers=' + $(if ($null -eq $repairPlan) { 'plan=null' } else { (Get-T1BlockerIds -Plan $repairPlan) -join ',' }))
            # Спершу збій після межі (окремий sandbox, щоб Critical не впливав на наступний успішний repair):
            # runtime лишається пошкодженим РІВНО як до repair, оператор про це попереджений.
            $sbFail = New-T1Sandbox -Name 'repair-fail' -Installed $releaseN
            Write-T1File (Join-Path $sbFail.Runtime 'BRAVO_RUNTIME_GUARD.ps1') '# tampered guard'
            [IO.File]::Delete((Join-Path $sbFail.Runtime 'BRAVO_CONFIG_LOADER.ps1'))
            $failedCase = [pscustomobject]@{ Sb = $sbFail; Plan = (Copy-T1Plan -Template $repairPlan -Sandbox $sbFail); Pre = (Get-T1Snapshot -Sandbox $sbFail) }
            $failed = Invoke-T1Update -Sandbox $sbFail -Plan $failedCase.Plan -Release $releaseN -Fault @{ 'Deploy.AfterSideEffect' = 'Throw' }
            $problems = @(Get-T1RolledBackProblem -Case $failedCase -Result $failed)
            if ((Get-T1FindingIds -Result $failed) -cnotcontains 'Repair.RuntimeStillDamaged') { $problems += 'немає finding Repair.RuntimeStillDamaged' }
            Test-BRAVOCondition -Condition ($problems.Count -eq 0) -Name 'UpdateEndToEnd/Repair/FailedRepairRollsBackToDamagedState' `
                -Failure ('ПОМИЛКА ПРОДУКТУ (Rollback.ps1, Test-BRAVORollbackBackupFiles: звірка runtime з backup\runtime\RUNTIME_MANIFEST.json): відкат Repair пошкодженого runtime завжди Critical, бо backup містить власний manifest справного комплекту. ' + ($problems -join '; ') + ' | ' + (Format-T1Result -Result $failed))
            # Тепер успішний repair тим самим пакетом.
            $plan = (New-T1Plan -Sandbox $sb -Operation Repair -Release $releaseN).Plan
            $siteBefore = (Get-T1Snapshot -Sandbox $sb).Site
            $localConfigBefore = Get-T1Sha -Path (Join-Path $sb.Runtime 'BRAVO.local.config')
            $result = Invoke-T1Update -Sandbox $sb -Plan $plan -Release $releaseN
            $problems = @(Get-T1ResultProblem -Sandbox $sb -Result $result)
            Test-BRAVOCondition -Condition ((@('Success', 'SuccessWithWarnings') -ccontains [string]$result.status) -and ([string]$result.action -ceq 'Repair') -and ($problems.Count -eq 0)) -Name 'UpdateEndToEnd/Repair/Succeeds' -Failure ((Format-T1Result -Result $result) + ' problems=' + ($problems -join ';'))
            $stateAfter = Get-BRAVOInstallationState -RuntimeRoot $sb.Runtime -StateRoot $sb.State -VersionStatePath $sb.VersionState -OperationLockPath $sb.OpLock -LockRoot $sb.Lock -Adapter $sb.Adapter
            Test-BRAVOCondition -Condition (([string]$stateAfter.integrity.status -ceq 'Valid') -and (Test-T1RuntimeMatchesRelease -Runtime $sb.Runtime -Release $releaseN)) -Name 'UpdateEndToEnd/Repair/IntegrityValidAfterRepair' -Failure ('integrity=' + $stateAfter.integrity.status)
            Test-BRAVOCondition -Condition (((Get-T1Sha -Path (Join-Path $sb.Runtime 'BRAVO.local.config')) -ceq $localConfigBefore) -and ((Get-T1Snapshot -Sandbox $sb).Site -ceq $siteBefore)) -Name 'UpdateEndToEnd/Repair/LocalConfigAndSiteFilesUnchanged' -Failure 'Repair змінив site-файли або BRAVO.local.config.'
            Test-BRAVOCondition -Condition ((Get-T1TaskState -Sandbox $sb) -ceq 'BRAVO_A=on,BRAVO_B=off') -Name 'UpdateEndToEnd/Repair/TasksRestored' -Failure (Get-T1TaskState -Sandbox $sb)

            # Repair пакетом N+1 -- не прихований upgrade.
            $sbUp = New-T1Sandbox -Name 'repair-upgrade' -Installed $releaseN
            $upPlan = (New-T1Plan -Sandbox $sbUp -Operation Repair -Release $releaseN1).Plan
            Test-BRAVOCondition -Condition ((Get-T1BlockerIds -Plan $upPlan) -contains 'Plan.RepairVersionMismatch') -Name 'UpdateEndToEnd/Repair/NewerPackagePlanBlocked' -Failure ('blockers=' + ((Get-T1BlockerIds -Plan $upPlan) -join ','))
            $upCase = [pscustomobject]@{ Sb = $sbUp; Plan = $upPlan; Pre = (Get-T1Snapshot -Sandbox $sbUp) }
            $upResult = Invoke-T1Update -Sandbox $sbUp -Plan $upPlan -Release $releaseN1
            Test-BRAVOCondition -Condition (([string]$upResult.status -ceq 'Failed') -and (-not $upResult.mutationStarted) -and ((Get-T1FindingIds -Result $upResult) -contains 'Repair.VersionMismatch') -and (@(Get-T1SnapshotDiff -Before $upCase.Pre -After (Get-T1Snapshot -Sandbox $sbUp)).Count -eq 0)) `
                -Name 'UpdateEndToEnd/Repair/EngineRefusesImplicitUpgrade' -Failure (Format-T1Result -Result $upResult)
        }

        # ================================================================
        # 11. Worker-протокол: запит -> worker -> результат; replay = PlanStale
        # ================================================================
        & {
            $sb = New-T1Sandbox -Name 'worker' -Installed $releaseN
            $plan = (New-T1Plan -Sandbox $sb -Operation Update -Release $releaseN1).Plan
            $pre = Get-T1Snapshot -Sandbox $sb
            # Без прав адміністратора worker нічого не пише.
            $denied = Invoke-T1Worker -Sandbox $sb -Plan $plan -SourcePath $releaseN1.Zip -IsAdministrator $false
            Test-BRAVOCondition -Condition (($denied.Out.ExitCode -eq 36) -and ((Get-T1JournalState -Sandbox $sb -Plan $plan) -ceq 'no-journal') -and ((Get-T1Snapshot -Sandbox $sb).Tree -ceq $pre.Tree)) -Name 'UpdateEndToEnd/Worker/PrivilegeRequiredWritesNothing' -Failure ('exit=' + $denied.Out.ExitCode)
            # Чужий корінь: каталог, якого engine не знаходить як встановлення.
            $foreignPlan = Copy-T1Plan -Template $plan -Sandbox $sb
            $foreign = Invoke-T1Worker -Sandbox $sb -Plan $foreignPlan -SourcePath $releaseN1.Zip -CandidateRoots @((Join-Path $e2eRoot 'no-such-install'))
            Test-BRAVOCondition -Condition (($foreign.Result.status -ceq 'Failed') -and ((Get-T1FindingIds -Result $foreign.Result) -contains 'Worker.ForeignRoot') -and ((Get-T1Snapshot -Sandbox $sb).Tree -ceq $pre.Tree)) -Name 'UpdateEndToEnd/Worker/ForeignRootRefused' -Failure (Format-T1Result -Result $foreign.Result)
            # Успішне виконання.
            $worker = Invoke-T1Worker -Sandbox $sb -Plan $plan -SourcePath $releaseN1.Zip
            $resultFile = [string]$worker.Out.ResultPath
            $parsed = $null
            if (($resultFile -ne '') -and [IO.File]::Exists($resultFile)) { $parsed = ([IO.File]::ReadAllText($resultFile) | ConvertFrom-Json) }
            Test-BRAVOCondition -Condition (($worker.Out.ExitCode -eq 0) -and ($worker.Result.status -ceq 'Success') -and (Test-T1RuntimeMatchesRelease -Runtime $sb.Runtime -Release $releaseN1)) -Name 'UpdateEndToEnd/Worker/UpdateSucceeds' -Failure ('exit=' + $worker.Out.ExitCode + ' ' + (Format-T1Result -Result $worker.Result))
            Test-BRAVOCondition -Condition (($null -ne $parsed) -and ([string]$parsed.status -ceq 'Success') -and ([string]$parsed.operationId -ceq [string]$plan.operationId) -and [IO.File]::Exists((Join-Path $sb.State ('Operations\' + [string]$plan.operationId + '\request.json')))) `
                -Name 'UpdateEndToEnd/Worker/ResultAndRequestPersisted' -Failure ('result.json=' + $resultFile)
            # Replay того самого запиту.
            $postWorker = Get-T1Snapshot -Sandbox $sb
            $replay = Invoke-T1Worker -Sandbox $sb -Plan $plan -RequestPath $worker.RequestPath
            Test-BRAVOCondition -Condition (($replay.Result.status -ceq 'Failed') -and ($replay.Result.reasonCode -ceq 'PlanStale') -and ((Get-T1FindingIds -Result $replay.Result) -contains 'Worker.PlanReplay') -and (@(Get-T1SnapshotDiff -Before $postWorker -After (Get-T1Snapshot -Sandbox $sb)).Count -eq 0)) `
                -Name 'UpdateEndToEnd/Worker/ReplayIsPlanStale' -Failure (Format-T1Result -Result $replay.Result)
        }

        # ================================================================
        # 13. Legacy BRAVO.config: міграційний gate (30); site-файли недоторкані
        # ================================================================
        & {
            $sb = New-T1Sandbox -Name 'legacy' -Installed $releaseN -LegacyConfig
            $pre = Get-T1Snapshot -Sandbox $sb
            $planResult = New-T1Plan -Sandbox $sb -Operation Update -Release $releaseN1
            $plan = $planResult.Plan
            $legacy = @(@($plan.findings) | Where-Object { [string]$_.id -ceq 'Preflight.LegacyConfig' })
            Test-BRAVOCondition -Condition (($legacy.Count -ge 1) -and ([int]$legacy[0].exitCodeHint -eq 30)) -Name 'UpdateEndToEnd/LegacyConfig/PlanBlockedWith30' -Failure ('blockers=' + ((Get-T1BlockerIds -Plan $plan) -join ','))
            $worker = Invoke-T1Worker -Sandbox $sb -Plan $plan -SourcePath $releaseN1.Zip
            Test-BRAVOCondition -Condition (($worker.Out.ExitCode -eq 30) -and ((Get-T1Snapshot -Sandbox $sb).Tree -ceq $pre.Tree)) -Name 'UpdateEndToEnd/LegacyConfig/WorkerRefuses30NoMutation' -Failure (Format-T1Result -Result $worker.Result)
            # Навіть якщо gate обійдено (план без blocker-ів), BRAVO.config і решта site-файлів лишаються побайтово.
            $bypass = Copy-T1Plan -Template $plan -Sandbox $sb
            $bypass.findings = @()
            $result = Invoke-T1Update -Sandbox $sb -Plan $bypass -Release $releaseN1
            Test-BRAVOCondition -Condition ((@('Success', 'SuccessWithWarnings') -ccontains [string]$result.status) -and ((Get-T1Snapshot -Sandbox $sb).Site -ceq $pre.Site) -and ((Get-T1Snapshot -Sandbox $sb).Site).Contains('BRAVO.config=' + (Get-T1Sha -Path (Join-Path $sb.Runtime 'BRAVO.config')))) `
                -Name 'UpdateEndToEnd/LegacyConfig/BypassedGateKeepsBravoConfigByteIdentical' -Failure ((Format-T1Result -Result $result) + ' site до=' + $pre.Site)
        }

        # ================================================================
        # 12. Скан секретів: жоден артефакт операцій не містить фейкових секретів
        # ================================================================
        & {
            $scanned = 0
            $leaks = New-Object System.Collections.Generic.List[string]
            foreach ($stateDir in @(Get-ChildItem -LiteralPath $e2eRoot -Directory -Recurse -Filter 'state' -ErrorAction SilentlyContinue)) {
                foreach ($file in @(Get-ChildItem -LiteralPath $stateDir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                    if ($file.Length -gt 5242880) { continue }
                    $scanned++
                    $text = ''
                    try { $text = [IO.File]::ReadAllText($file.FullName) } catch { $text = '' }
                    if ($text.Contains($e2eSecret)) { $leaks.Add($file.FullName.Substring($e2eRoot.Length)) }
                }
            }
            Test-BRAVOCondition -Condition (($scanned -gt 50) -and ($leaks.Count -eq 0)) -Name 'UpdateEndToEnd/Secrets/NoFakeSecretInStateArtifacts' -Failure ('файлів переглянуто=' + $scanned + ' витоки: ' + (($leaks | Select-Object -First 5) -join '; '))
            # Знімок із вихідних даних: фейковий секрет справді передавався engine (скан не порожній за змістом).
            $adapterProbe = New-T1Adapter -Cfg @{ Secret = $e2eSecret; Presence = 'Found' }
            $probe = & $adapterProbe.TestCredentialPresence 'x' 'y'
            Test-BRAVOCondition -Condition (([string]$probe.Secret -ceq $e2eSecret) -and ([Environment]::GetEnvironmentVariable($e2eSecretEnvName) -ceq $e2eSecret)) -Name 'UpdateEndToEnd/Secrets/ProbeSecretWasAvailableToEngine' -Failure 'Фейковий секрет має бути в adapter-і та середовищі процесу.'
        }
    }
} finally {
    [Environment]::SetEnvironmentVariable($e2eSecretEnvName, $e2ePreviousSecretEnv)
    # Видаляємо лише каталог, створений цим фрагментом (префікс + GUID у тимчасовому каталозі).
    if ($e2eRoot.StartsWith($e2eTempPrefix, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($e2eRoot)) {
        Remove-Item -LiteralPath $e2eRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
