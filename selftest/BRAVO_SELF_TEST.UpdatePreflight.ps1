# Suite UpdatePreflight: INS-021 (Test-BRAVODeploymentPreflight) та INS-022
# (Test-BRAVOConfigMigrationBlocker). Усі корені — у тимчасовому sandbox із
# пробілами й кирилицею; C:\ProgramData\BRAVO та Program Files не чіпаються.
# Дані середовища (admin, OS tier, .NET) підставляються через adapter-seam
# GetPreflightEnvironment, тож результат не залежить від хоста.

& {
    $pfTModule = $null
    $pfTBase = $null
    $pfTHeld = New-Object System.Collections.Generic.List[object]
    try {
        Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking
        $pfTModule = Get-Module BRAVO.Update

        # --- TEST SHIM: W1-функції (контракти), якщо ще не інтегровані. ----
        # Лише в тестовому harness-і; production-файл їх не дублює.
        & $pfTModule {
            if ($null -eq (Get-Command -Name New-BRAVOUpdateFinding -CommandType Function -ErrorAction SilentlyContinue)) {
                function script:New-BRAVOUpdateFinding {
                    param([string]$Id, [string]$Severity, [string]$Title, [string]$Meaning, [string]$Action, [string]$Details, $ExitCodeHint)
                    [pscustomobject]@{ schemaVersion = 1; id = $Id; severity = $Severity; title = $Title; meaning = $Meaning
                        action = $Action; details = $Details; exitCodeHint = $ExitCodeHint }
                }
                function script:Get-BRAVOUpdateCanonicalJson {
                    param($InputObject)
                    ConvertTo-Json -InputObject $InputObject -Depth 10 -Compress
                }
                function script:Get-BRAVOUpdateSha256Text {
                    param([string]$Text)
                    $sha = [System.Security.Cryptography.SHA256]::Create()
                    try {
                        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
                    } finally { $sha.Dispose() }
                    ([System.BitConverter]::ToString($bytes)).Replace('-', '')
                }
                function script:New-BRAVOUpdatePreflightResult {
                    param([string]$Operation, [string]$RuntimeRoot, $Findings, [string]$Fingerprint)
                    $blockers = 0; $warnings = 0
                    foreach ($f in $Findings) {
                        if ($f.severity -eq 'Blocker') { $blockers++ }
                        if ($f.severity -eq 'Warning') { $warnings++ }
                    }
                    [pscustomobject]@{ schemaVersion = 1; generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                        operation = $Operation; runtimeRoot = $RuntimeRoot; findings = $Findings
                        canProceed = ($blockers -eq 0); blockerCount = $blockers; warningCount = $warnings; fingerprint = $Fingerprint }
                }
            }
            if ($null -eq (Get-Command -Name Get-BRAVOUpdateOpenJournal -CommandType Function -ErrorAction SilentlyContinue)) {
                function script:Get-BRAVOUpdateOpenJournal {
                    param([string]$StateRoot)
                    $dir = Join-Path $StateRoot 'Journal'
                    if (-not (Test-Path -LiteralPath $dir)) { return }
                    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File) {
                        $j = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
                        if ($j.state -eq 'Open') { $j }
                    }
                }
            }
        }

        $pfTBase = Join-Path ([System.IO.Path]::GetTempPath()) ('BRAVO_UPDATE_SELF_TEST_PREFLIGHT_' + [guid]::NewGuid().ToString('N'))
        $pfTSite = Join-Path $pfTBase 'Сервер BRAVO тест'
        [void](New-Item -ItemType Directory -Path $pfTSite -Force)
        $rt = Join-Path $pfTSite 'Програма BRAVO'
        $st = Join-Path $pfTSite 'State'
        $lk = Join-Path $pfTSite 'Locks'
        $sg = Join-Path $pfTSite 'Staging'
        $bk = Join-Path $pfTSite 'Backup'
        foreach ($dir in @($rt, $st, $lk, $sg, $bk)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText((Join-Path $rt 'VERSION.json'), '{"packageVersion":"5.3.0"}', $utf8Bom)
        [System.IO.File]::WriteAllText((Join-Path $rt 'RUNTIME_MANIFEST.json'), '{}', $utf8Bom)
        $opLock = Join-Path $lk 'BRAVO_OPERATION.lock'
        $lcLock = Join-Path $lk 'BRAVO_UPDATE.lock'

        $envOk = {
            [pscustomobject]@{ OsTier = 'Supported'; OsDescription = 'Example OS (версія 10.0.20348)'
                PowerShellVersion = [version]'5.1.20348.0'; PowerShellEdition = 'Desktop'; DotNetRelease = 528372
                Is64BitOS = $true; IsAdministrator = $true }
        }
        $newEnv = {
            param([hashtable]$Over)
            $e = [ordered]@{ OsTier = 'Supported'; OsDescription = 'Example OS'; PowerShellVersion = [version]'5.1.20348.0'
                PowerShellEdition = 'Desktop'; DotNetRelease = 528372; Is64BitOS = $true; IsAdministrator = $true }
            foreach ($k in $Over.Keys) { $e[$k] = $Over[$k] }
            $obj = [pscustomobject]$e
            return @{ GetPreflightEnvironment = { $obj }.GetNewClosure(); GetManagedTasks = { @() } }
        }
        $call = {
            param([hashtable]$Over)
            $p = @{ Operation = 'Update'; RuntimeRoot = $rt; StateRoot = $st; LockRoot = $lk; OperationLockPath = $opLock
                StagingRoot = $sg; BackupRoot = $bk; Adapter = @{ GetPreflightEnvironment = $envOk; GetManagedTasks = { @() } } }
            if ($null -ne $Over) { foreach ($k in $Over.Keys) { $p[$k] = $Over[$k] } }
            & $pfTModule { param($x) Test-BRAVODeploymentPreflight @x } $p
        }
        $find = {
            param($Result, [string]$Id)
            foreach ($f in $Result.findings) { if ($f.id -eq $Id) { return $f } }
            return $null
        }
        $treeHash = {
            param([string]$Dir)
            $lines = New-Object System.Collections.Generic.List[string]
            foreach ($f in (Get-ChildItem -LiteralPath $Dir -Recurse -Force)) {
                $h = ''
                if (-not $f.PSIsContainer) { $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
                [void]$lines.Add("$($f.FullName)|$($f.Length)|$h")
            }
            ($lines.ToArray() | Sort-Object) -join "`n"
        }

        # ---- Базовий сценарій ----------------------------------------------
        & {
            $r = & $call $null
            Test-BRAVOCondition -Condition ($r.canProceed -and $r.blockerCount -eq 0) -Name 'UpdatePreflight/HealthyUpdateProceeds' -Failure 'Здорове оновлення має проходити без blocker-ів'
            Test-BRAVOCondition -Condition ($r.operation -eq 'Update' -and $r.runtimeRoot -eq $rt) -Name 'UpdatePreflight/ResultShape' -Failure 'operation/runtimeRoot не відображено'
            $allPrefixed = $true; $blockerActionOk = $true
            foreach ($f in $r.findings) { if (-not $f.id.StartsWith('Preflight.')) { $allPrefixed = $false } }
            Test-BRAVOCondition -Condition $allPrefixed -Name 'UpdatePreflight/FindingIdsPrefixed' -Failure 'id Finding має починатись з Preflight.'
            Test-BRAVOCondition -Condition ($r.findings.Count -ge 14) -Name 'UpdatePreflight/AllChecksPresent' -Failure "Очікувано щонайменше 14 перевірок, отримано $($r.findings.Count)"
            $r2 = & $call $null
            Test-BRAVOCondition -Condition ($r.fingerprint -eq $r2.fingerprint -and $r.fingerprint -match '^[0-9A-F]{64}$') -Name 'UpdatePreflight/FingerprintStable' -Failure 'Fingerprint нестабільний або не SHA-256'
            $r3 = & $call @{ RequiredBytes = 12345 }
            Test-BRAVOCondition -Condition ($r.fingerprint -ne $r3.fingerprint) -Name 'UpdatePreflight/FingerprintTracksInputs' -Failure 'Fingerprint не залежить від входів'
            $real = & $pfTModule { param($x) Test-BRAVODeploymentPreflight @x } @{ Operation = 'Diagnose'; RuntimeRoot = $rt; StateRoot = $st; LockRoot = $lk
                OperationLockPath = $opLock; StagingRoot = $sg; BackupRoot = $bk }
            Test-BRAVOCondition -Condition ($null -ne (& $find $real 'Preflight.OperatingSystem') -and $null -ne (& $find $real 'Preflight.DotNet')) -Name 'UpdatePreflight/RealEnvironmentProbe' -Failure 'Реальне середовище не дало Finding ОС/.NET'
        }

        # ---- Preflight нічого не пише ---------------------------------------
        & {
            $before = & $treeHash $pfTBase
            [void](& $call $null)
            [void](& $call @{ Operation = 'Install'; RuntimeRoot = (Join-Path $pfTSite 'Новий каталог') })
            [void](& $call @{ Operation = 'Diagnose' })
            $after = & $treeHash $pfTBase
            Test-BRAVOCondition -Condition ($before -eq $after) -Name 'UpdatePreflight/ReadOnlyNoWrites' -Failure 'Preflight змінив файлову систему'
            Test-BRAVOCondition -Condition (-not (Test-Path -LiteralPath (Join-Path $pfTSite 'Новий каталог'))) -Name 'UpdatePreflight/NoDirectoryCreated' -Failure 'Preflight створив каталог'
        }

        # ---- Середовище ----------------------------------------------------
        & {
            $r = & $call @{ Adapter = (& $newEnv @{ OsTier = 'Unsupported' }) }
            $f = & $find $r 'Preflight.OperatingSystem'
            Test-BRAVOCondition -Condition ($f.severity -eq 'Blocker' -and $f.exitCodeHint -eq 37 -and -not $r.canProceed) -Name 'UpdatePreflight/OsUnsupportedBlocks' -Failure 'Unsupported ОС має блокувати (37)'
            $r = & $call @{ Adapter = (& $newEnv @{ OsTier = 'LegacyBestEffort' }) }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.OperatingSystem').severity -eq 'Warning' -and $r.canProceed) -Name 'UpdatePreflight/OsLegacyWarns' -Failure 'LegacyBestEffort має бути Warning'
            $r = & $call @{ Adapter = (& $newEnv @{ OsTier = 'Unknown' }) }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.OperatingSystem').severity -eq 'Blocker') -Name 'UpdatePreflight/OsUnknownFailsClosed' -Failure 'Невизначений tier має блокувати'
            $r = & $call @{ Adapter = (& $newEnv @{ PowerShellEdition = 'Core'; PowerShellVersion = [version]'7.4.0' }) }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.PowerShell').severity -eq 'Blocker') -Name 'UpdatePreflight/PowerShellCoreBlocks' -Failure 'PowerShell 7/Core має блокувати'
            $r = & $call @{ Adapter = (& $newEnv @{ PowerShellVersion = [version]'5.0.1' }) }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.PowerShell').severity -eq 'Blocker') -Name 'UpdatePreflight/PowerShell50Blocks' -Failure 'PowerShell 5.0 має блокувати'
            $r = & $call @{ Adapter = (& $newEnv @{ DotNetRelease = 461808 }) }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.DotNet').severity -eq 'Blocker') -Name 'UpdatePreflight/OldDotNetBlocks' -Failure '.NET нижче 528040 має блокувати'
            $r = & $call @{ Adapter = (& $newEnv @{ DotNetRelease = 528040 }) }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.DotNet').severity -eq 'Ok') -Name 'UpdatePreflight/DotNetBoundaryOk' -Failure '.NET 528040 має проходити'
            $r = & $call @{ Adapter = (& $newEnv @{ Is64BitOS = $false }) }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.Architecture').severity -eq 'Blocker') -Name 'UpdatePreflight/32BitBlocks' -Failure '32-розрядна ОС має блокувати'
        }

        # ---- Elevation -----------------------------------------------------
        & {
            $r = & $call @{ Adapter = (& $newEnv @{ IsAdministrator = $false }) }
            $f = & $find $r 'Preflight.Elevation'
            Test-BRAVOCondition -Condition ($f.severity -eq 'Warning' -and $f.title -like '*UAC*' -and $r.canProceed) -Name 'UpdatePreflight/NotElevatedWarnsUac' -Failure 'Без elevation має бути Warning про UAC'
            $r = & $call @{ Adapter = (& $newEnv @{ IsAdministrator = $false }); RequireElevation = $true }
            $f = & $find $r 'Preflight.Elevation'
            Test-BRAVOCondition -Condition ($f.severity -eq 'Blocker' -and $f.exitCodeHint -eq 36) -Name 'UpdatePreflight/RequireElevationBlocks36' -Failure 'RequireElevation без прав має бути Blocker 36'
            $r = & $call @{ Operation = 'Diagnose'; Adapter = (& $newEnv @{ IsAdministrator = $false }); RequireElevation = $true }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.Elevation').severity -eq 'NotApplicable') -Name 'UpdatePreflight/DiagnoseElevationNotApplicable' -Failure 'Diagnose: elevation NotApplicable'
            $r = & $call $null
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.Elevation').severity -eq 'Ok') -Name 'UpdatePreflight/ElevatedOk' -Failure 'Підвищений процес має бути Ok'
        }

        # ---- Шляхи ---------------------------------------------------------
        & {
            $r = & $call @{ RuntimeRoot = '\\host-a\share\BRAVO' }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.RuntimeRootPath').severity -eq 'Blocker' -and -not $r.canProceed) -Name 'UpdatePreflight/UncRuntimeBlocks' -Failure 'UNC runtime root має блокувати'
            $r = & $call @{ RuntimeRoot = 'BRAVO\relative' }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.RuntimeRootPath').severity -eq 'Blocker') -Name 'UpdatePreflight/RelativeRuntimeBlocks' -Failure 'Відносний шлях має блокувати'
            $r = & $call @{ RuntimeRoot = ($rt + '\..\Інший') }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.RuntimeRootPath').severity -eq 'Blocker') -Name 'UpdatePreflight/DotDotRuntimeBlocks' -Failure 'Шлях із .. має блокувати'
            $winDir = [System.Environment]::GetEnvironmentVariable('SystemRoot')
            $r = & $call @{ RuntimeRoot = (Join-Path $winDir 'BRAVO-NOT-CREATED') }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.RuntimeRootPath').severity -eq 'Blocker') -Name 'UpdatePreflight/WindowsDirRuntimeBlocks' -Failure 'Каталог під Windows має блокувати'
            $driveRoot = [System.IO.Path]::GetPathRoot($pfTBase)
            $r = & $call @{ RuntimeRoot = $driveRoot }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.RuntimeRootPath').severity -eq 'Blocker') -Name 'UpdatePreflight/DriveRootBlocks' -Failure 'Корінь диска має блокувати'
            $r = & $call @{ StagingRoot = (Join-Path $rt 'Staging') }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.WorkRootsPath').severity -eq 'Blocker') -Name 'UpdatePreflight/StagingInsideRuntimeBlocks' -Failure 'Staging усередині runtime має блокувати'
            $r = & $call @{ BackupRoot = (Join-Path $rt 'Backup') }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.WorkRootsPath').severity -eq 'Blocker') -Name 'UpdatePreflight/BackupInsideRuntimeBlocks' -Failure 'Backup усередині runtime має блокувати'
            $r = & $call @{ BackupRoot = $rt }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.WorkRootsPath').severity -eq 'Blocker') -Name 'UpdatePreflight/BackupEqualsRuntimeBlocks' -Failure 'Backup == runtime має блокувати'
            $r = & $call @{ BackupRoot = (Join-Path $sg 'Nested') }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.WorkRootsPath').severity -eq 'Blocker') -Name 'UpdatePreflight/BackupInsideStagingBlocks' -Failure 'Backup у staging має блокувати'
            $r = & $call @{ StagingRoot = '\\host-a\share\staging' }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.WorkRootsPath').severity -eq 'Blocker') -Name 'UpdatePreflight/UncStagingBlocks' -Failure 'UNC staging має блокувати'
            $r = & $call @{ RuntimeRoot = ($rt + 'Suffix') }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.WorkRootsPath').severity -eq 'Ok') -Name 'UpdatePreflight/PrefixSiblingNotInside' -Failure 'Сусід із спільним префіксом не є вкладеним'

            # Junction як runtime root.
            $junctionTarget = Join-Path $pfTSite 'ціль junction'
            $junction = Join-Path $pfTSite 'junction runtime'
            [void](New-Item -ItemType Directory -Path $junctionTarget -Force)
            $created = $false
            try {
                [void](New-Item -ItemType Junction -Path $junction -Value $junctionTarget -ErrorAction Stop)
                $created = $true
            } catch { $created = $false }
            if ($created) {
                try {
                    $r = & $call @{ RuntimeRoot = $junction }
                    Test-BRAVOCondition -Condition ((& $find $r 'Preflight.RuntimeRootPath').severity -eq 'Blocker') -Name 'UpdatePreflight/JunctionRuntimeBlocks' -Failure 'Junction як runtime має блокувати'
                    $r = & $call @{ RuntimeRoot = (Join-Path $junction 'вкладений') }
                    Test-BRAVOCondition -Condition ((& $find $r 'Preflight.RuntimeRootPath').severity -eq 'Blocker') -Name 'UpdatePreflight/JunctionAncestorBlocks' -Failure 'Reparse point серед предків має блокувати'
                } finally {
                    # Видаляється лише власний junction (не рекурсивно).
                    if ($junction.StartsWith($pfTBase, [System.StringComparison]::OrdinalIgnoreCase)) { [System.IO.Directory]::Delete($junction) }
                }
            } else {
                Test-BRAVOCondition -Condition $true -EnvironmentLimitation -Name 'UpdatePreflight/JunctionRuntimeBlocks' -Failure 'Junction не вдалося створити в sandbox'
            }

            # Diagnose: ті самі проблеми не блокують звіт.
            $r = & $call @{ Operation = 'Diagnose'; RuntimeRoot = '\\host-a\share\BRAVO'; StagingRoot = (Join-Path $rt 'S') }
            $f = & $find $r 'Preflight.RuntimeRootPath'
            Test-BRAVOCondition -Condition ($f.severity -eq 'Warning' -and $r.canProceed -and $r.blockerCount -eq 0) -Name 'UpdatePreflight/DiagnoseNeverBlocks' -Failure 'Diagnose не має мати blocker-ів'
        }

        # ---- Диск ----------------------------------------------------------
        & {
            $r = & $call @{ RequiredBytes = ([long]::MaxValue / 2) }
            $f = & $find $r 'Preflight.DiskSpace'
            Test-BRAVOCondition -Condition ($f.severity -eq 'Blocker' -and -not $r.canProceed) -Name 'UpdatePreflight/HugeRequirementBlocks' -Failure 'Величезна вимога до диска має блокувати'
            $r = & $call @{ RequiredBytes = ([long]::MaxValue) }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.DiskSpace').severity -eq 'Blocker') -Name 'UpdatePreflight/MaxRequirementNoOverflow' -Failure 'Long.MaxValue + резерв не має переповнювати'
            $r = & $call @{ RequiredBytes = 1024 }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.DiskSpace').severity -eq 'Ok') -Name 'UpdatePreflight/SmallRequirementOk' -Failure 'Мала вимога має проходити'
        }

        # ---- Locks ---------------------------------------------------------
        & {
            $r = & $call $null
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.LifecycleLock').severity -eq 'Ok' -and (& $find $r 'Preflight.OperationLock').severity -eq 'Ok') -Name 'UpdatePreflight/NoLockFilesOk' -Failure 'Відсутні lock-файли мають бути Ok'

            # Застарілий lock (файл є, хендла немає) — не активний.
            [System.IO.File]::WriteAllText($opLock, '{"operation":"Archive","pid":1,"startedAt":"2020-01-01T00:00:00Z"}')
            $r = & $call $null
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.OperationLock').severity -eq 'Ok') -Name 'UpdatePreflight/StaleOperationLockIgnored' -Failure 'Застарілий JSON без хендла не є активним lock'

            $fs = $null
            try {
                $fs = New-Object System.IO.FileStream($lcLock, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                [void]$pfTHeld.Add($fs)
                $r = & $call $null
                $f = & $find $r 'Preflight.LifecycleLock'
                Test-BRAVOCondition -Condition ($f.severity -eq 'Blocker' -and $f.exitCodeHint -eq 20 -and -not $r.canProceed) -Name 'UpdatePreflight/LifecycleLockBusyBlocks20' -Failure 'Зайнятий lifecycle lock має бути Blocker 20'
                $r = & $call @{ IgnoreOwnLocks = $true }
                Test-BRAVOCondition -Condition ((& $find $r 'Preflight.LifecycleLock').severity -eq 'NotApplicable') -Name 'UpdatePreflight/IgnoreOwnLocks' -Failure 'IgnoreOwnLocks має пропускати власні lock-и'
                $r = & $call @{ Operation = 'Diagnose' }
                Test-BRAVOCondition -Condition ($r.canProceed -and (& $find $r 'Preflight.LifecycleLock').severity -eq 'Warning') -Name 'UpdatePreflight/DiagnoseLockBusyWarns' -Failure 'Diagnose: зайнятий lock лише Warning'
            } finally {
                if ($null -ne $fs) { $fs.Dispose(); [void]$pfTHeld.Remove($fs) }
            }
            $r = & $call $null
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.LifecycleLock').severity -eq 'Ok') -Name 'UpdatePreflight/LifecycleLockReleasedOk' -Failure 'Після звільнення lock має бути Ok'

            # Operation lock так, як його тримає Archive/Maintenance: ReadWrite + FileShare.Read.
            $ofs = $null
            try {
                $ofs = New-Object System.IO.FileStream($opLock, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
                [void]$pfTHeld.Add($ofs)
                $json = '{"operation":"Archive","pid":4242,"startedAt":"2026-01-01T00:00:00Z","hostname":"host-a"}'
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $ofs.SetLength(0); $ofs.Write($bytes, 0, $bytes.Length); $ofs.Flush()
                $r = & $call $null
                $f = & $find $r 'Preflight.OperationLock'
                Test-BRAVOCondition -Condition ($f.severity -eq 'Blocker' -and $f.exitCodeHint -eq 20 -and $f.action -like '*Дочекайтеся*') -Name 'UpdatePreflight/OperationLockBusyBlocks20' -Failure 'Активний BRAVO_OPERATION.lock має блокувати з порадою дочекатись'
                Test-BRAVOCondition -Condition ($f.details -like '*operation=Archive*' -and $f.details -notlike '*host-a*') -Name 'UpdatePreflight/OperationLockHolderDescribed' -Failure 'Опис власника має містити operation і не містити зайвих полів'
            } finally {
                if ($null -ne $ofs) { $ofs.Dispose(); [void]$pfTHeld.Remove($ofs) }
            }
            Test-BRAVOCondition -Condition ($pfTHeld.Count -eq 0) -Name 'UpdatePreflight/LocksReleased' -Failure 'Тестові lock-и не звільнені'
            Remove-Item -LiteralPath $opLock -Force
            Remove-Item -LiteralPath $lcLock -Force
        }

        # ---- Керовані задачі -----------------------------------------------
        & {
            $running = @{ GetPreflightEnvironment = $envOk; GetManagedTasks = { @([pscustomobject]@{ name = 'BRAVO_ARCHIV'; state = 'Running' }, [pscustomobject]@{ name = 'BRAVO_MAINTENANCE'; state = 'Ready' }) } }
            $r = & $call @{ Adapter = $running }
            $f = & $find $r 'Preflight.RunningTasks'
            Test-BRAVOCondition -Condition ($f.severity -eq 'Blocker' -and $f.details -like '*BRAVO_ARCHIV*' -and $f.exitCodeHint -eq 20) -Name 'UpdatePreflight/RunningTaskBlocks' -Failure 'Running задача має блокувати'
            $idle = @{ GetPreflightEnvironment = $envOk; GetManagedTasks = { @([pscustomobject]@{ name = 'BRAVO_ARCHIV'; state = 'Ready' }) } }
            $r = & $call @{ Adapter = $idle }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.RunningTasks').severity -eq 'Ok') -Name 'UpdatePreflight/IdleTasksOk' -Failure 'Ready задачі не блокують'
            $broken = @{ GetPreflightEnvironment = $envOk; GetManagedTasks = { throw 'scheduler unavailable' } }
            $r = & $call @{ Adapter = $broken }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.RunningTasks').severity -eq 'Blocker') -Name 'UpdatePreflight/TaskEnumerationFailureBlocks' -Failure 'Збій перелічення задач — fail closed'
            $r = & $call @{ Adapter = @{ GetPreflightEnvironment = $envOk } }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.RunningTasks').severity -eq 'Warning' -and $r.canProceed) -Name 'UpdatePreflight/NoTaskAdapterWarns' -Failure 'Без GetManagedTasks — Warning'
            $r = & $call @{ Adapter = $null }
            Test-BRAVOCondition -Condition ($null -ne (& $find $r 'Preflight.RunningTasks')) -Name 'UpdatePreflight/NullAdapterTolerated' -Failure 'Null adapter не має кидати'
        }

        # ---- Журнал --------------------------------------------------------
        & {
            $journalDir = Join-Path $st 'Journal'
            [void](New-Item -ItemType Directory -Path $journalDir -Force)
            $jPath = Join-Path $journalDir 'aaaaaaaa-0000-4000-8000-000000000001.json'
            [System.IO.File]::WriteAllText($jPath, '{"schemaVersion":1,"operationId":"aaaaaaaa-0000-4000-8000-000000000001","state":"Open","mutationStarted":false}')
            $r = & $call $null
            $f = & $find $r 'Preflight.OpenJournal'
            Test-BRAVOCondition -Condition ($f.severity -eq 'Blocker' -and $f.details -like '*aaaaaaaa-0000*') -Name 'UpdatePreflight/OpenJournalBlocks' -Failure 'Відкритий журнал має блокувати'
            $r = & $call @{ AllowOpenJournal = $true }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.OpenJournal').severity -eq 'NotApplicable') -Name 'UpdatePreflight/RecoveryAllowsOpenJournal' -Failure 'Recovery не блокується журналом'
            [System.IO.File]::WriteAllText($jPath, '{"schemaVersion":1,"operationId":"aaaaaaaa-0000-4000-8000-000000000001","state":"Committed"}')
            $r = & $call $null
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.OpenJournal').severity -eq 'Ok') -Name 'UpdatePreflight/CommittedJournalOk' -Failure 'Committed журнал не блокує'
            [System.IO.File]::WriteAllText($jPath, '{ це не json')
            $r = & $call $null
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.OpenJournal').severity -eq 'Blocker') -Name 'UpdatePreflight/CorruptJournalBlocks' -Failure 'Пошкоджений журнал — fail closed'
            Remove-Item -LiteralPath $jPath -Force
            $r = & $call $null
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.OpenJournal').severity -eq 'Ok') -Name 'UpdatePreflight/NoJournalOk' -Failure 'Без журналів має бути Ok'
        }

        # ---- Install target ------------------------------------------------
        & {
            $fresh = Join-Path $pfTSite 'Чистий каталог'
            $r = & $call @{ Operation = 'Install'; RuntimeRoot = $fresh }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.InstallTarget').severity -eq 'Ok' -and $r.canProceed) -Name 'UpdatePreflight/InstallMissingDirOk' -Failure 'Install у відсутній каталог має проходити'
            [void](New-Item -ItemType Directory -Path $fresh -Force)
            $r = & $call @{ Operation = 'Install'; RuntimeRoot = $fresh }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.InstallTarget').severity -eq 'Ok') -Name 'UpdatePreflight/InstallEmptyDirOk' -Failure 'Install у порожній каталог має проходити'
            $r = & $call @{ Operation = 'Install' }
            $f = & $find $r 'Preflight.InstallTarget'
            Test-BRAVOCondition -Condition ($f.severity -eq 'Blocker' -and $f.action -like '*Оновити*' -and -not $r.canProceed) -Name 'UpdatePreflight/InstallOverExistingBlocks' -Failure 'Install поверх VERSION.json має блокувати з порадою Оновити/Відновити'
            [System.IO.File]::WriteAllText((Join-Path $fresh 'чужий файл.txt'), 'x')
            $r = & $call @{ Operation = 'Install'; RuntimeRoot = $fresh }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.InstallTarget').severity -eq 'Blocker') -Name 'UpdatePreflight/InstallNonEmptyForeignBlocks' -Failure 'Install у довільний непорожній каталог має блокувати'
            Remove-Item -LiteralPath (Join-Path $fresh 'чужий файл.txt') -Force
            [System.IO.File]::WriteAllText((Join-Path $fresh 'BRAVO_SETUP.ps1'), '# x')
            $r = & $call @{ Operation = 'Install'; RuntimeRoot = $fresh }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.InstallTarget').severity -eq 'Blocker') -Name 'UpdatePreflight/InstallPartialBravoBlocks' -Failure 'Install у каталог із файлами BRAVO без VERSION.json має блокувати'
            Remove-Item -LiteralPath (Join-Path $fresh 'BRAVO_SETUP.ps1') -Force
            $r = & $call @{ Operation = 'Update'; RuntimeRoot = $fresh }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.InstallTarget').severity -eq 'Blocker') -Name 'UpdatePreflight/UpdateWithoutInstallBlocks' -Failure 'Update без інсталяції має блокувати'
            $r = & $call @{ Operation = 'Repair' }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.InstallTarget').severity -eq 'Ok') -Name 'UpdatePreflight/RepairExistingOk' -Failure 'Repair наявної інсталяції має проходити'
        }

        # ---- Цілісність ----------------------------------------------------
        & {
            $state = [pscustomobject]@{ integrity = [pscustomobject]@{ status = 'Invalid'; mismatchedCount = 2 } }
            $r = & $call @{ InstallationState = $state }
            $f = & $find $r 'Preflight.RuntimeIntegrity'
            Test-BRAVOCondition -Condition ($f.severity -eq 'Warning' -and $r.canProceed) -Name 'UpdatePreflight/UpdateInvalidIntegrityWarns' -Failure 'Update: порушена цілісність — Warning'
            $r = & $call @{ Operation = 'Repair'; InstallationState = $state }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.RuntimeIntegrity').severity -eq 'NotApplicable' -and $r.canProceed) -Name 'UpdatePreflight/RepairInvalidIntegrityExpected' -Failure 'Repair: порушена цілісність очікувана'
            $ok = [pscustomobject]@{ integrity = [pscustomobject]@{ status = 'Valid' } }
            $r = & $call @{ InstallationState = $ok }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.RuntimeIntegrity').severity -eq 'Ok') -Name 'UpdatePreflight/ValidIntegrityOk' -Failure 'Valid цілісність має бути Ok'
            $r = & $call $null
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.RuntimeIntegrity').severity -eq 'NotApplicable') -Name 'UpdatePreflight/NoStateIntegrityNotApplicable' -Failure 'Без InstallationState — NotApplicable'
        }

        # ---- Міграційний gate (INS-022) ------------------------------------
        & {
            $marker = Join-Path $pfTSite 'EXECUTED.marker'
            $legacy = Join-Path $rt 'BRAVO.config'
            $legacyText = "Set-Content -LiteralPath '$marker' -Value 'executed'`r`nthrow 'EXECUTED'`r`n"
            [System.IO.File]::WriteAllText($legacy, $legacyText, $utf8Bom)

            $gate = & $pfTModule { param($x) Test-BRAVOConfigMigrationBlocker -RuntimeRoot $x } $rt
            Test-BRAVOCondition -Condition ($gate.Blocked -and $gate.Reasons.Count -eq 1 -and $gate.Findings.Count -eq 1) -Name 'UpdatePreflight/LegacyConfigBlocked' -Failure 'Legacy BRAVO.config без доказу міграції має блокувати'
            Test-BRAVOCondition -Condition (-not (Test-Path -LiteralPath $marker)) -Name 'UpdatePreflight/LegacyConfigNeverExecuted' -Failure 'BRAVO.config було виконано!'
            Test-BRAVOCondition -Condition ($gate.Findings[0].exitCodeHint -eq 30 -and $gate.Findings[0].action -like '*RUNBOOK*') -Name 'UpdatePreflight/LegacyConfigActionPointsToRunbook' -Failure 'Дія має вказувати на runbook міграції'
            foreach ($op in @('Update', 'Repair')) {
                $r = & $call @{ Operation = $op }
                $f = & $find $r 'Preflight.LegacyConfig'
                Test-BRAVOCondition -Condition ($null -ne $f -and $f.severity -eq 'Blocker' -and $f.exitCodeHint -eq 30 -and -not $r.canProceed) -Name "UpdatePreflight/${op}LegacyBlocks30" -Failure "$op з legacy BRAVO.config має блокувати (30)"
            }
            Test-BRAVOCondition -Condition (-not (Test-Path -LiteralPath $marker)) -Name 'UpdatePreflight/PreflightNeverExecutesLegacy' -Failure 'Preflight виконав BRAVO.config!'
            $r = & $call @{ Operation = 'Diagnose' }
            Test-BRAVOCondition -Condition ($r.canProceed -and (& $find $r 'Preflight.LegacyConfig').severity -eq 'Warning') -Name 'UpdatePreflight/DiagnoseLegacyWarns' -Failure 'Diagnose: legacy лише Warning'

            # Legacy як каталог або BRAVO.config.local теж блокують.
            Remove-Item -LiteralPath $legacy -Force
            [void](New-Item -ItemType Directory -Path $legacy -Force)
            $gate = & $pfTModule { param($x) Test-BRAVOConfigMigrationBlocker -RuntimeRoot $x } $rt
            Test-BRAVOCondition -Condition $gate.Blocked -Name 'UpdatePreflight/LegacyAsDirectoryBlocked' -Failure 'Об''єкт із ім''ям BRAVO.config (каталог) має блокувати'
            Remove-Item -LiteralPath $legacy -Force
            [System.IO.File]::WriteAllText((Join-Path $rt 'BRAVO.config.local'), "throw 'EXECUTED'", $utf8Bom)
            $gate = & $pfTModule { param($x) Test-BRAVOConfigMigrationBlocker -RuntimeRoot $x } $rt
            Test-BRAVOCondition -Condition $gate.Blocked -Name 'UpdatePreflight/LegacyConfigLocalBlocked' -Failure 'BRAVO.config.local має блокувати'
            Remove-Item -LiteralPath (Join-Path $rt 'BRAVO.config.local') -Force

            $gate = & $pfTModule { param($x) Test-BRAVOConfigMigrationBlocker -RuntimeRoot $x } $rt
            Test-BRAVOCondition -Condition (-not $gate.Blocked -and $gate.Reasons.Count -eq 0 -and $gate.Findings.Count -eq 0) -Name 'UpdatePreflight/NoLegacyNotBlocked' -Failure 'Без legacy-файлів блокування немає'
            $gate = & $pfTModule { param($x) Test-BRAVOConfigMigrationBlocker -RuntimeRoot $x } (Join-Path $pfTSite 'немає такого')
            Test-BRAVOCondition -Condition (-not $gate.Blocked) -Name 'UpdatePreflight/MissingRootNotBlocked' -Failure 'Відсутній root: нічого мігрувати'
            $r = & $call @{ Operation = 'Install'; RuntimeRoot = (Join-Path $pfTSite 'Нова інсталяція') }
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.ConfigMigration').severity -eq 'NotApplicable') -Name 'UpdatePreflight/InstallMigrationNotApplicable' -Failure 'Install: міграція NotApplicable'
        }

        # ---- Схема BRAVO.local.config --------------------------------------
        & {
            $marker = Join-Path $pfTSite 'LOCAL-EXECUTED.marker'
            $localPath = Join-Path $rt 'BRAVO.local.config'
            $r = & $call $null
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.LocalConfigSchema').severity -eq 'Ok') -Name 'UpdatePreflight/NoLocalConfigOk' -Failure 'Відсутній BRAVO.local.config — Ok'

            [System.IO.File]::WriteAllText($localPath, "@{ configSchemaVersion = 2; 'pathSettings.BackupRoot' = 'D:\Резерв BRAVO' }", $utf8Bom)
            $r = & $call $null
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.LocalConfigSchema').severity -eq 'Ok' -and $r.canProceed) -Name 'UpdatePreflight/ValidLocalConfigOk' -Failure 'Валідний local config має проходити'

            [System.IO.File]::WriteAllText($localPath, "@{ 'pathSettings.BackupRoot' = 5 }", $utf8Bom)
            $r = & $call $null
            $f = & $find $r 'Preflight.LocalConfigSchema'
            Test-BRAVOCondition -Condition ($f.severity -eq 'Blocker' -and $f.exitCodeHint -eq 30) -Name 'UpdatePreflight/WrongTypeLocalConfigBlocks30' -Failure 'Неправильний тип значення має блокувати (30)'

            [System.IO.File]::WriteAllText($localPath, "@{ configSchemaVersion = 99 }", $utf8Bom)
            $r = & $call $null
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.LocalConfigSchema').severity -eq 'Blocker') -Name 'UpdatePreflight/UnsupportedSchemaVersionBlocks' -Failure 'Непідтримувана версія схеми має блокувати'

            [System.IO.File]::WriteAllText($localPath, "Set-Content -LiteralPath '$marker' -Value x`r`n@{ 'a' = 1 }", $utf8Bom)
            $r = & $call $null
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.LocalConfigSchema').severity -eq 'Blocker' -and -not (Test-Path -LiteralPath $marker)) -Name 'UpdatePreflight/ExecutableLocalConfigRejectedNotRun' -Failure 'Виконуваний local config має відхилятись без виконання'

            [System.IO.File]::WriteAllText($localPath, "@{ 'a' = (Set-Content -LiteralPath '$marker' -Value x) }", $utf8Bom)
            $r = & $call $null
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.LocalConfigSchema').severity -eq 'Blocker' -and -not (Test-Path -LiteralPath $marker)) -Name 'UpdatePreflight/ExpressionLocalConfigNotRun' -Failure 'Вираз у local config не має виконуватись'

            [System.IO.File]::WriteAllText($localPath, '@{ не hashtable', $utf8Bom)
            $r = & $call $null
            Test-BRAVOCondition -Condition ((& $find $r 'Preflight.LocalConfigSchema').severity -eq 'Blocker') -Name 'UpdatePreflight/CorruptLocalConfigBlocks' -Failure 'Пошкоджений local config має блокувати'

            $r = & $call @{ Operation = 'Diagnose' }
            Test-BRAVOCondition -Condition ($r.canProceed -and (& $find $r 'Preflight.LocalConfigSchema').severity -eq 'Warning') -Name 'UpdatePreflight/DiagnoseCorruptLocalConfigWarns' -Failure 'Diagnose: local config лише Warning'
            Remove-Item -LiteralPath $localPath -Force
        }

        # ---- Структура Finding ---------------------------------------------
        & {
            $bad = & $call @{ Operation = 'Update'; RuntimeRoot = '\\host-a\x'; Adapter = (& $newEnv @{ OsTier = 'Unsupported'; DotNetRelease = 0 }) }
            $complete = $true
            foreach ($f in $bad.findings) {
                if ($f.severity -eq 'Blocker' -and [string]::IsNullOrWhiteSpace($f.action)) { $complete = $false }
                if ([string]::IsNullOrWhiteSpace($f.title)) { $complete = $false }
            }
            Test-BRAVOCondition -Condition ($complete -and $bad.blockerCount -ge 3) -Name 'UpdatePreflight/BlockersHaveActionAndTitle' -Failure 'Кожен Blocker має title і action'
            Test-BRAVOCondition -Condition ($bad.blockerCount -eq @($bad.findings | Where-Object { $_.severity -eq 'Blocker' }).Count) -Name 'UpdatePreflight/BlockerCountConsistent' -Failure 'blockerCount не збігається'
        }
    } finally {
        foreach ($held in $pfTHeld.ToArray()) { $held.Dispose() }
        if (-not [string]::IsNullOrEmpty($pfTBase) -and
            $pfTBase.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase) -and
            $pfTBase -like '*BRAVO_UPDATE_SELF_TEST_PREFLIGHT_*' -and
            (Test-Path -LiteralPath $pfTBase)) {
            Remove-Item -LiteralPath $pfTBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
