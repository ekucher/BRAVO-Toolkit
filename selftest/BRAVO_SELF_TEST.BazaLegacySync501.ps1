# ============================================================
# #501: legacy-синхронізація BAZA (Sync-FolderToSFTP) класифікує залишок
# пост-аудиту за знімком локального дерева перед стартом WinSCP. Об'єкти,
# що з'явилися під час циклу, — ПОПЕРЕДЖЕННЯ (код 10), а не ПОМИЛКА; не
# передані об'єкти знімка, змінені під час передачі, ненульовий код WinSCP і
# недоступний аудит лишаються помилкою.
#
# Справжні Sync-FolderToSFTP -> Invoke-ManualBAZASFTPSynchronization;
# фейкові лише процес WinSCP (cmd.exe
# /c exit N) і read-only порівняння з хмарою. Гонку моделює крок "LIMS пише
# після сканування WinSCP" усередині фейкового старту процесу — без Start-Sleep.
#
# Домен-фрагмент self-test: backport #501 на лінію 5.2.x (hotfix/5.2.5).
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 -- НЕ запускається напряму.
# Успадковує з викликача: $root, $archiveScriptText (BRAVO.Archive.Runtime.ps1),
# Test-BRAVOCondition, New-BRAVOSelfTestRuntimeModule.
#
# Порт регресійних кейсів S01-S18, F01-F32h, B1-B4, D1-D2, S16 і
# SnapshotTakenBeforeWinSCPStart з developer (злиття 90ca868,
# selftest/BRAVO_SELF_TEST.Archive.ps1); ідентифікатори кейсів збережено.
# Це РЕГРЕСІЙНІ тести після реалізації backport-а, а не TDD.
# Адаптація до 5.2.5: немає Invoke-BRAVOBazaCanonicalSync,
# Get-BRAVOManualSyncRunOutcomeLabel, Resolve-BRAVOSyncBazaExitCode,
# Get-BRAVOExitCodeSeverity; Invoke-ManualBAZASFTPSynchronization керується
# $componentSettings, а слово "Результат" і код завершення -SyncBAZA
# обчислюються inline у Main (вирази витягуються з тексту рантайму й
# виконуються, див. Get-Late501MainOutcome). Додаткові кейси: P525-*.
# ============================================================

Import-Module -Name (Join-Path $root 'modules\BRAVO.BazaSync\BRAVO.BazaSync.psd1') -ErrorAction Stop
Import-Module -Name (Join-Path $root 'modules\BRAVO.ExitCodes\BRAVO.ExitCodes.psd1') -ErrorAction Stop

$late501Stub = @'
function Write-BRAVOLog { param([string]$Component, [string]$Message, [string]$Level = "INFO", [switch]$NoConsole, [switch]$NoTimestamp)
    [void]$script:late501Log.Add([pscustomobject]@{ Level = $Level; Message = $Message }) }
function New-BRAVOWinSCPTemporaryScriptPath {
    return (Join-Path $script:late501CaseRoot ('winscp_' + [guid]::NewGuid().ToString('N') + '.txt'))
}
function Remove-BRAVOWinSCPSensitiveTemporaryScript { param([string]$Path) Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
function Test-BRAVOWinSCPAvailable { param($WinSCPPath) return [pscustomobject]@{ Available = $true } }
function Get-BRAVOWinSCPBusyMessage { param($Availability, $Operation) return 'busy' }
function Get-SanitizedWinSCPDiagnostic { param($Text) return [string]$Text }
function Show-RunningProgress { param($Id, $Activity, $Status, [switch]$Completed) }
function Show-ScriptProgress { param($Status, $PercentComplete, [switch]$Completed) }
function Format-BRAVORunningDetail { param($ElapsedSeconds) return '' }
function Get-BAZARemoteNameCompatibilityIssues { param($LocalPath, $MaximumFileUtf8Bytes, $MaximumDirectoryUtf8Bytes) return [pscustomobject]@{ Success = $true; Issues = @() } }
function Write-BAZARemoteNameCompatibilityAudit { param($CompatibilityResult, $ComponentName) }
function Get-BRAVOBazaSyncModeEffective { return 'Legacy' }
function Test-PathWithLog { param($Path, $Description, $CreateIfMissing) return (Test-Path -LiteralPath $Path) }
function Test-SFTPConfig { param([switch]$SynchronizationOnly, [string[]]$NotInstalledComponents) return $true }
function Test-SFTPConnection { param($WinSCPPath, $RepositorySFTPUrl, $HostKey) return $true }
function Initialize-BRAVOSFTPRemoteDirectories { param($WinSCPPath, $RepositorySFTPUrl, $HostKey, $RemoteDirectories) }
# Фейк read-only CompareDirectories(Remote, removeFiles=$false): усе локальне,
# чого немає в хмарі, — UploadNew; інший розмір — UploadUpdate.
function Get-BAZASFTPComparison {
    param($LocalPath, $RemotePath, $RepositorySFTPUrl, $HostKey, $LocalSnapshot = $null, [object[]]$PreAuditPending = @(), [switch]$SnapshotUnavailable)
    $script:late501ComparisonCalls++
    $script:late501ComponentComparisons++
    if ($script:late501AfterAuditFails -and $script:late501ComparisonCalls -ge 2) {
        return [pscustomobject]@{ Success = $false; Error = 'аудит недоступний (selftest)'; PendingFiles = @() }
    }
    $result = Get-Late501RemoteDifference -LocalPath $LocalPath -RemotePath $RemotePath
    # Перший аудит компонента — аудит ДО: його залишок передається пост-аудиту.
    if ($script:late501ComponentComparisons -eq 1) { $script:late501PreAuditPending = @($result.PendingFiles) }
    # Пост-аудит зі знімком: та сама production-функція, що й у справжньому
    # Get-BAZASFTPComparison (звіряння знімка ПІСЛЯ порівняння + stat), лише
    # сесія — фейкова хмара. Стадія AfterCompare — LIMS діє між локальним
    # обходом пост-аудиту і звірянням знімка.
    if ($null -ne $LocalSnapshot) {
        Invoke-Late501Ops -Stage 'AfterCompare'
        $result = Add-BAZASnapshotConsistencyEvidence -ComparisonResult $result -Session (New-Late501FakeSession -RemotePath $RemotePath) `
            -RemotePath $RemotePath -LocalSnapshot $LocalSnapshot -LocalPath $LocalPath -MaximumProbeCount $script:late501ProbeCap `
            -PreAuditPending @($PreAuditPending)
        # Стадія AfterProbe: LIMS діє ПІСЛЯ збору проби (локальний + хмарний stat),
        # але до класифікації результату.
        Invoke-Late501Ops -Stage 'AfterProbe'
    }
    # Знімок запитано, але не вдався (LocalSnapshot $null): та сама production-
    # функція збирає stat у хмарі для об'єктів аудиту ДО, LIMS діє на стадії
    # AfterCompare між порівнянням і збиранням доказу.
    if ($null -eq $LocalSnapshot -and $SnapshotUnavailable) {
        Invoke-Late501Ops -Stage 'AfterCompare'
        $result = Add-BAZASnapshotUnavailableEvidence -ComparisonResult $result -Session (New-Late501FakeSession -RemotePath $RemotePath) `
            -RemotePath $RemotePath -LocalPath $LocalPath -MaximumProbeCount $script:late501ProbeCap `
            -PreAuditPending @($PreAuditPending)
        Invoke-Late501Ops -Stage 'AfterProbe'
    }
    # Перший аудит компонента — ДО синхронізації: LIMS діє вже після нього.
    if ($script:late501ComponentComparisons -eq 1) { Invoke-Late501Ops -Stage 'BeforeAudit' }
    return $result
}
# Фейкова WinSCP .NET Session над фейковою хмарою: FileExists/GetFileInfo
# для '/baza_app/KZ/...' (час — з точністю SFTP, секунди).
function New-Late501FakeSession {
    param([string]$RemotePath)
    $session = New-Object psobject
    $session | Add-Member -NotePropertyName RemoteRoot -NotePropertyValue $RemotePath
    $session | Add-Member -MemberType ScriptMethod -Name RelativeOf -Value {
        param($Path) $Path.Substring($this.RemoteRoot.TrimEnd('/').Length + 1).Replace('/', '\')
    }
    $session | Add-Member -MemberType ScriptMethod -Name FileExists -Value {
        param($Path)
        $relative = $this.RelativeOf($Path)
        if (@($script:late501ProbeErrorPaths) -contains $relative) { throw 'симульований збій stat у хмарі (selftest)' }
        $script:late501Remote[$this.RemoteRoot].ContainsKey($relative)
    }
    $session | Add-Member -MemberType ScriptMethod -Name GetFileInfo -Value {
        param($Path)
        $relative = $this.RelativeOf($Path)
        $length = [long]$script:late501Remote[$this.RemoteRoot][$relative]
        $times = $script:late501Remote['#times'][$this.RemoteRoot]
        [pscustomobject]@{
            IsDirectory = ($length -eq -1)
            Length = $length
            LastWriteTime = $(if ($times.ContainsKey($relative)) { New-Object DateTime ([long]$times[$relative]), ([DateTimeKind]::Utc) } else { [datetime]::MinValue })
        }
    }
    return $session
}
function Get-Late501RemoteDifference {
    param($LocalPath, $RemotePath)
    $remote = $script:late501Remote[$RemotePath]
    $rootPath = (Get-Item -LiteralPath $LocalPath).FullName.TrimEnd('\')
    $pending = @()
    # .NET-перелік, як у WinSCP і знімку: заходить у junction (Get-ChildItem
    # -Recurse у PS 5.1 — ні).
    foreach ($item in @((New-Object IO.DirectoryInfo($rootPath)).EnumerateFileSystemInfos('*', [IO.SearchOption]::AllDirectories))) {
        $relative = $item.FullName.Substring($rootPath.Length + 1)
        if ($item -is [IO.DirectoryInfo]) {
            if (-not $remote.ContainsKey($relative)) {
                $pending += [pscustomobject]@{ Action = 'UploadNew'; Reason = 'відсутній у хмарі'; Path = $item.FullName; IsDirectory = $true; SizeBytes = $null }
            }
            continue
        }
        if (-not $remote.ContainsKey($relative)) {
            $pending += [pscustomobject]@{ Action = 'UploadNew'; Reason = 'відсутній у хмарі'; Path = $item.FullName; IsDirectory = $false; SizeBytes = [long]$item.Length }
        } elseif ([long]$remote[$relative] -ne [long]$item.Length) {
            $pending += [pscustomobject]@{ Action = 'UploadUpdate'; Reason = 'потребує оновлення у хмарі'; Path = $item.FullName; IsDirectory = $false; SizeBytes = [long]$item.Length }
        }
    }
    return [pscustomobject]@{ Success = $true; Error = $null; PendingFiles = @($pending) }
}
# Фейковий WinSCP: (1) сканує локальне дерево, (2) LIMS пише ПІСЛЯ
# сканування, (3) передає просканований стан, крім late501FailPaths.
function Start-BRAVOProcessOutputCapture {
    param([System.Diagnostics.Process]$Process)
    $script:late501WinSCPRuns++
    $remoteKey = $script:late501CurrentRemotePath
    $localRoot = (Get-Item -LiteralPath $script:late501CurrentLocal).FullName.TrimEnd('\')
    $scanned = @(
        @((New-Object IO.DirectoryInfo($localRoot)).EnumerateFileSystemInfos('*', [IO.SearchOption]::AllDirectories)) | ForEach-Object {
            $isDirectory = $_ -is [IO.DirectoryInfo]
            [pscustomobject]@{ Relative = $_.FullName.Substring($localRoot.Length + 1); IsDirectory = $isDirectory; Length = $(if ($isDirectory) { -1 } else { [long]$_.Length }); Ticks = $_.LastWriteTimeUtc.Ticks }
        }
    )
    foreach ($write in @($script:late501DuringSyncWrites | Where-Object { $_.Component -eq $script:late501CurrentComponent })) {
        $writeDirectory = [IO.Path]::GetDirectoryName($write.Path)
        if (-not [IO.Directory]::Exists($writeDirectory)) { [void][IO.Directory]::CreateDirectory($writeDirectory) }
        [IO.File]::WriteAllBytes($write.Path, (New-Object byte[] ([int]$write.Size)))
        if ($null -ne $write.LastWriteUtc) { [IO.File]::SetLastWriteTimeUtc($write.Path, [datetime]$write.LastWriteUtc) }
    }
    Invoke-Late501Ops -Stage 'Sync'
    foreach ($scannedItem in $scanned) {
        if ($script:late501FailPaths -contains $scannedItem.Relative) { continue }
        $script:late501Remote[$remoteKey][$scannedItem.Relative] = $scannedItem.Length
        # Хмара зберігає час модифікації з точністю SFTP (секунди).
        $script:late501Remote['#times'][$remoteKey][$scannedItem.Relative] = $scannedItem.Ticks - ($scannedItem.Ticks % [TimeSpan]::TicksPerSecond)
    }
    $Process.StartInfo.FileName = $env:ComSpec
    $Process.StartInfo.Arguments = "/c exit $script:late501ExitCode"
    [void]$Process.Start()
    return $null
}
function Complete-BRAVOProcessOutputCapture { param($Capture) return [pscustomobject]@{ StandardOutput = ''; StandardError = '' } }
# Справжній знімок; дії стадії 'Snapshot' — об'єкти, що з'явилися/зникли вже
# після обходу свого каталогу, але до старту WinSCP (неатомарний обхід).
function Get-BRAVOBazaLocalSnapshot {
    param([string]$LocalDirectory, [switch]$IncludeHiddenSystem, [switch]$IncludeDirectories)
    $snapshot = BRAVO.BazaSync\Get-BRAVOBazaLocalSnapshot -LocalDirectory $LocalDirectory -IncludeHiddenSystem:$IncludeHiddenSystem -IncludeDirectories:$IncludeDirectories
    Invoke-Late501Ops -Stage 'Snapshot'
    # Збій обходу (напр., об'єкт зник під час читання метаданих): та сама
    # форма результату, що й у catch production-функції.
    if ($script:late501SnapshotFails) {
        return [pscustomobject]@{ SnapshotUtc = $snapshot.SnapshotUtc; Entries = @{}; Directories = $snapshot.Directories; ReparsePointDirectoryCount = $snapshot.ReparsePointDirectoryCount; Success = $false; Error = 'симульований збій обходу знімка' }
    }
    return $snapshot
}
# Дії "LIMS" на заданій стадії циклу поточного компонента (дані, без closure).
function Invoke-Late501Ops {
    param([string]$Stage)
    foreach ($op in @($script:late501Ops | Where-Object { $_.Stage -eq $Stage -and $_.Component -eq $script:late501CurrentComponent })) {
        switch ($op.Op) {
            'Write' {
                $opDirectory = [IO.Path]::GetDirectoryName($op.Path)
                if (-not [IO.Directory]::Exists($opDirectory)) { [void][IO.Directory]::CreateDirectory($opDirectory) }
                [IO.File]::WriteAllBytes($op.Path, (New-Object byte[] ([int]$op.Size)))
            }
            'Delete' { [IO.File]::Delete($op.Path) }
            'DeleteTree' { [IO.Directory]::Delete($op.Path, $true) }
            'MkDir' { [void][IO.Directory]::CreateDirectory($op.Path) }
            'Move' { [IO.File]::Move($op.Path, $op.Target) }
            'SetCreation' { [IO.File]::SetCreationTimeUtc($op.Path, [datetime]$op.Time) }
            'SetLastWrite' { [IO.File]::SetLastWriteTimeUtc($op.Path, [datetime]$op.Time) }
            'Junction' {
                $mklinkOutput = & $env:ComSpec /c mklink /J "$($op.Path)" "$($op.Target)" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "mklink /J не вдався: $mklinkOutput" }
            }
        }
    }
}
'@
$late501Module = New-BRAVOSelfTestRuntimeModule `
    -SourceText ($late501Stub + "`n" + $archiveScriptText) `
    -FunctionNames @(
        'Write-BRAVOLog', 'New-BRAVOWinSCPTemporaryScriptPath', 'Remove-BRAVOWinSCPSensitiveTemporaryScript',
        'Test-BRAVOWinSCPAvailable', 'Get-BRAVOWinSCPBusyMessage', 'Get-SanitizedWinSCPDiagnostic', 'Show-RunningProgress',
        'Show-ScriptProgress', 'Format-BRAVORunningDetail', 'Get-BAZARemoteNameCompatibilityIssues',
        'Write-BAZARemoteNameCompatibilityAudit', 'Get-BRAVOBazaSyncModeEffective', 'Test-PathWithLog', 'Test-SFTPConfig',
        'Test-SFTPConnection', 'Initialize-BRAVOSFTPRemoteDirectories', 'Get-BAZASFTPComparison',
        'Get-Late501RemoteDifference', 'Get-BRAVOBazaLocalSnapshot', 'Invoke-Late501Ops',
        'Start-BRAVOProcessOutputCapture', 'Complete-BRAVOProcessOutputCapture',
        'Write-BAZASFTPComparisonAudit', 'Test-BAZAPathBlockedByIncompatibleName', 'Split-BAZAPendingFilesByCompatibility',
        'Get-BAZASyncStartBoundaryUtc', 'Test-BAZACreationClockTrusted', 'Test-BAZAVanishedSnapshotObjectBackedUp', 'Get-BAZARemoteVanishedProbe',
        'Add-BAZASnapshotConsistencyEvidence', 'Add-BAZASnapshotUnavailableEvidence', 'Test-BAZAPathHasReparsePoint', 'New-Late501FakeSession',
        'Get-BAZAPendingFileCycleClassification', 'Get-BAZASynchronizationOutcome', 'Sync-FolderToSFTP',
        'New-BRAVOTransferOperationResult', 'Invoke-ManualBAZASFTPSynchronization',
        'Resolve-BRAVOLogComponentFromHeader'
    )

# P525: вирази Main для -SyncBAZA (слово "Результат", код завершення, Result
# підсумку) обчислюються inline, а не окремими функціями, як у developer.
# Щоб тестувати РЕАЛЬНИЙ production-код, а не його копію, вирази витягуються
# з тексту рантайму й виконуються над заданим результатом
# Invoke-ManualBAZASFTPSynchronization. Якщо вираз у рантаймі зміниться так,
# що його не знайдено, функція кидає виняток (кейс падає, а не мовчить).
function Get-Late501MainOutcome {
    param([Parameter(Mandatory = $true)]$ManualSyncResult)
    $lines = @($archiveScriptText -split "\r?\n")
    $countLine = @($lines | Where-Object { $_ -match '^\s*\$manualNewAfterCutoffCount\s*=\s*if\s*\(' })
    $labelLine = @($lines | Where-Object { $_ -match '^\s*Write-Log\s+"Результат:\s*\$\(.*\)"\s+-NoTimestamp\s*$' -and $_ -match 'manualNewAfterCutoffCount' })
    $exitLine = @($lines | Where-Object { $_ -match '^\s*\$script:processExitCode\s*=\s*if\s*\(-not\s+\$manualSyncSuccess\)' })
    $summaryLine = @($lines | Where-Object { $_ -match '^\s*-Result\s+\$\(if\s*\(-not\s+\$manualSyncSuccess\)' })
    if ($countLine.Count -ne 1 -or $labelLine.Count -ne 1 -or $exitLine.Count -ne 1 -or $summaryLine.Count -ne 1) {
        throw "не знайдено inline-вирази -SyncBAZA у Main: count=$($countLine.Count) label=$($labelLine.Count) exit=$($exitLine.Count) summary=$($summaryLine.Count)"
    }
    $labelExpression = ([regex]::Match($labelLine[0], '^\s*Write-Log\s+"Результат:\s*\$\((?<e>.*)\)"\s+-NoTimestamp\s*$')).Groups['e'].Value
    $exitExpression = ([regex]::Match($exitLine[0], '^\s*\$script:processExitCode\s*=\s*(?<e>.*)$')).Groups['e'].Value
    $summaryExpression = ([regex]::Match($summaryLine[0], '^\s*-Result\s+\$\((?<e>.*)\)\s*`?\s*$')).Groups['e'].Value
    $countExpression = ([regex]::Match($countLine[0], '^\s*\$manualNewAfterCutoffCount\s*=\s*(?<e>.*)$')).Groups['e'].Value
    $evaluate = {
        param($ManualSyncResult, $CountExpression, $LabelExpression, $ExitExpression, $SummaryExpression)
        $manualSyncResult = $ManualSyncResult
        $manualSyncSuccess = [bool]$ManualSyncResult.Success
        $manualNewAfterCutoffCount = & ([scriptblock]::Create($CountExpression))
        [pscustomobject]@{
            Label = [string](& ([scriptblock]::Create($LabelExpression)))
            ExitCode = [int](& ([scriptblock]::Create($ExitExpression)))
            SummaryResult = [string](& ([scriptblock]::Create($SummaryExpression)))
        }
    }
    return (& $evaluate $ManualSyncResult $countExpression $labelExpression $exitExpression $summaryExpression)
}

# Один прогін -SyncBAZA (або лише Sync-FolderToSFTP): повертає результат,
# мітку, код завершення, outcome-и компонентів і журнал.
# $late501RunRaw виконує справжній Invoke-ManualBAZASFTPSynchronization;
# $late501Run (нижче) додає Label/ExitCode/SummaryResult з виразів Main.
$late501RunRaw = {
    param(
        [string]$CaseRoot,
        [hashtable]$Remote,
        [object[]]$DuringSyncWrites = @(),
        [string[]]$FailPaths = @(),
        [int]$ExitCode = 0,
        [switch]$AfterAuditFails,
        [switch]$WithWWW,
        [object[]]$Ops = @(),
        [int]$ProbeCap = 1000,
        [switch]$SnapshotFails,
        [string[]]$ProbeErrorPaths = @()
    )
    & $late501Module {
        param($CaseRoot, $Remote, $DuringSyncWrites, $FailPaths, $ExitCode, $AfterAuditFails, $WithWWW, $Ops, $ProbeCap, $SnapshotFails, $ProbeErrorPaths)
        $script:late501ProbeCap = $ProbeCap
        $script:late501ProbeErrorPaths = @($ProbeErrorPaths)
        $script:late501PreAuditPending = @()
        $script:late501SnapshotFails = [bool]$SnapshotFails
        $script:late501Log = New-Object System.Collections.ArrayList
        $script:late501CaseRoot = $CaseRoot
        $script:late501Remote = $Remote
        $script:late501DuringSyncWrites = @($DuringSyncWrites)
        $script:late501Ops = @($Ops)
        $script:late501CurrentComponent = $null
        $script:late501FailPaths = @($FailPaths)
        $script:late501ExitCode = $ExitCode
        $script:late501AfterAuditFails = [bool]$AfterAuditFails
        $script:late501ComparisonCalls = 0
        $script:late501WinSCPRuns = 0
        $script:winSCPPath = $env:ComSpec
        $script:winSCPAssemblyPath = 'C:\fake\WinSCPnet.dll'
        $script:sftpUrl = 'sftp://selftest@192.0.2.10/'
        $script:sftpHostKey = 'ssh-ed25519 255 SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCdE'
        $script:sftpConnectionTimeoutSeconds = 5
        $script:sftpSynchronizationOptions = '-mirror -criteria=time,size -resumesupport=on'
        $script:winSCPScriptEncoding = 'ASCII'
        $script:winSCPIniPath = 'nul'
        $script:synchronizationSafety = [pscustomobject]@{ RequireNonEmptyBAZASource = $false }
        $script:progressSettings = [pscustomobject]@{ Enabled = $false; ShowWinSCPOutput = $false }
        $script:backupMonitoring = [pscustomobject]@{ SFTP = [pscustomobject]@{ SynchronizationTimeoutSeconds = 60; OperationTimeoutSeconds = 60 } }
        $script:componentSettings = @{ Synchronization = @{ BAZA_APP_SFTP = $true; BAZA_WWW_SFTP = [bool]$WithWWW } }
        $script:bazaAppPaths = @{ Source = (Join-Path $CaseRoot 'APP') }
        $script:bazaWWWPaths = @{ Source = (Join-Path $CaseRoot 'WWW') }
        $script:bazaWWWDetection = @{ Success = $true; Reason = '' }
        $script:sftpDirectories = @{ BAZA = 'baza_app'; BAZAWWW = 'baza_www' }
        # Фейковий старт процесу бере поточні шлях/компонент звідси; ім'я компонента
        # і шлях для кожного виклику Sync-FolderToSFTP ставить обгортка нижче.
        $script:late501Outcomes = @{}
        $script:late501OriginalSync = ${function:script:Sync-FolderToSFTP}
        ${function:script:Sync-FolderToSFTP} = {
            param($WinSCPPath, $RepositorySFTPUrl, $HostKey, $LocalDirectory, $RemoteDirectory, $ComponentName)
            $script:late501CurrentLocal = $LocalDirectory
            $script:late501CurrentComponent = $ComponentName
            $script:late501ComponentComparisons = 0
            $script:late501CurrentRemotePath = '/' + $RemoteDirectory.Trim('/')
            $result = & $script:late501OriginalSync -WinSCPPath $WinSCPPath -RepositorySFTPUrl $RepositorySFTPUrl -HostKey $HostKey -LocalDirectory $LocalDirectory -RemoteDirectory $RemoteDirectory -ComponentName $ComponentName
            $script:late501Outcomes[$ComponentName] = $script:lastBAZASyncOutcome
            return $result
        }
        try {
            # 5.2.5: набір компонентів задає $script:componentSettings (вище);
            # параметрів -BazaAppEnabled/-BazaWWWEnabled тут немає.
            $manual = Invoke-ManualBAZASFTPSynchronization
        } finally {
            ${function:script:Sync-FolderToSFTP} = $script:late501OriginalSync
        }
        return [pscustomobject]@{
            Manual = $manual
            Log = @($script:late501Log.ToArray())
            App = $script:late501Outcomes['BAZA_APP']
            Www = $(if ($script:late501Outcomes.ContainsKey('BAZA_WWW')) { $script:late501Outcomes['BAZA_WWW'] } else { $null })
            WinSCPRuns = $script:late501WinSCPRuns
        }
    } $CaseRoot $Remote @($DuringSyncWrites) $FailPaths $ExitCode ([bool]$AfterAuditFails) ([bool]$WithWWW) @($Ops) $ProbeCap ([bool]$SnapshotFails) @($ProbeErrorPaths)
}
$late501Run = {
    param(
        [string]$CaseRoot,
        [hashtable]$Remote,
        [object[]]$DuringSyncWrites = @(),
        [string[]]$FailPaths = @(),
        [int]$ExitCode = 0,
        [switch]$AfterAuditFails,
        [switch]$WithWWW,
        [object[]]$Ops = @(),
        [int]$ProbeCap = 1000,
        [switch]$SnapshotFails,
        [string[]]$ProbeErrorPaths = @()
    )
    $raw = & $late501RunRaw -CaseRoot $CaseRoot -Remote $Remote -DuringSyncWrites $DuringSyncWrites -FailPaths $FailPaths `
        -ExitCode $ExitCode -AfterAuditFails:$AfterAuditFails -WithWWW:$WithWWW -Ops $Ops -ProbeCap $ProbeCap `
        -SnapshotFails:$SnapshotFails -ProbeErrorPaths $ProbeErrorPaths
    $mainOutcome = Get-Late501MainOutcome -ManualSyncResult $raw.Manual
    return [pscustomobject]@{
        Manual = $raw.Manual
        # Production-токен успіху в 5.2.5 -- 'УСПIШНО' (латинська I); для
        # збереження ідентичних асершенів developer ('УСПІШНО', кирилична І)
        # мітка нормалізується. Сирий токен окремо перевіряє P525-c.
        Label = ([string]$mainOutcome.Label).Replace([string][char]0x0049, [string][char]0x0406)
        RawLabel = [string]$mainOutcome.Label
        ExitCode = $mainOutcome.ExitCode
        SummaryResult = $mainOutcome.SummaryResult
        App = $raw.App
        Www = $raw.Www
        Log = $raw.Log
        WinSCPRuns = $raw.WinSCPRuns
    }
}

$late501NewFile = {
    param([string]$Path, [int]$Size = 64, [Nullable[datetime]]$LastWriteUtc = $null)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Size))
    if ($null -ne $LastWriteUtc) { [IO.File]::SetLastWriteTimeUtc($Path, [datetime]$LastWriteUtc) }
}
# Новий кейс: APP (і WWW) з базовими файлами, хмара вже має все, крім
# $PendingCount файлів, які чекають першої передачі.
$late501NewCase = {
    param([string]$Name, [int]$SyncedCount = 3, [int]$PendingCount = 2)
    $caseRoot = Join-Path $late501Root $Name
    $remote = @{ '/baza_app' = @{}; '/baza_www' = @{}; '#times' = @{ '/baza_app' = @{}; '/baza_www' = @{} } }
    foreach ($component in @('APP', 'WWW')) {
        $componentRoot = Join-Path $caseRoot $component
        [void](New-Item -ItemType Directory -Path (Join-Path $componentRoot 'KZ\2026') -Force)
        $remoteKey = if ($component -eq 'APP') { '/baza_app' } else { '/baza_www' }
        $remote[$remoteKey]['KZ'] = -1
        $remote[$remoteKey]['KZ\2026'] = -1
        for ($i = 1; $i -le $SyncedCount; $i++) {
            & $late501NewFile (Join-Path $componentRoot "KZ\2026\synced_$i.pdf") 100
            $remote[$remoteKey]["KZ\2026\synced_$i.pdf"] = 100
            $syncedTicks = [IO.File]::GetLastWriteTimeUtc((Join-Path $componentRoot "KZ\2026\synced_$i.pdf")).Ticks
            $remote['#times'][$remoteKey]["KZ\2026\synced_$i.pdf"] = $syncedTicks - ($syncedTicks % [TimeSpan]::TicksPerSecond)
        }
        for ($i = 1; $i -le $PendingCount; $i++) {
            & $late501NewFile (Join-Path $componentRoot "KZ\2026\pending_$i.pdf") 200
        }
    }
    return [pscustomobject]@{ Root = $caseRoot; App = (Join-Path $caseRoot 'APP'); Www = (Join-Path $caseRoot 'WWW'); Remote = $remote }
}
# Запис "LIMS під час WinSCP": дані, які пише фейковий старт процесу (без closure).
$late501Write = { param([string]$Component, [string]$Path, [int]$Size = 64, $LastWriteUtc = $null) [pscustomobject]@{ Component = $Component; Path = $Path; Size = $Size; LastWriteUtc = $LastWriteUtc } }
# Дія "LIMS" на стадії циклу: BeforeAudit (після аудиту ДО, ще до знімка),
# Snapshot (після обходу знімка, до старту WinSCP), Sync (після сканування
# WinSCP, до передачі).
$late501Op = { param([string]$Stage, [string]$Op, [string]$Path, [string]$Target = $null, [int]$Size = 64, $Time = $null, [string]$Component = 'BAZA_APP') [pscustomobject]@{ Stage = $Stage; Op = $Op; Path = $Path; Target = $Target; Size = $Size; Time = $Time; Component = $Component } }
$late501Errors = { param($Run) @($Run.Log | Where-Object { $_.Level -eq 'ERROR' }) }
$late501Warnings = { param($Run) @($Run.Log | Where-Object { $_.Level -eq 'WARNING' }) }

$late501Root = Join-Path ([IO.Path]::GetTempPath()) "BRAVOSelfTest_Late501_$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $late501Root -Force)
try {
    # 1. Усі об'єкти знімка передано, нових немає -> УСПІШНО, код 0.
    $c1 = & $late501NewCase 'S01'
    $r1 = & $late501Run -CaseRoot $c1.Root -Remote $c1.Remote
    Test-BRAVOCondition -Condition (
        $r1.Manual.Success -and $r1.Label -eq 'УСПІШНО' -and $r1.ExitCode -eq 0 -and
        $r1.App.IsComplete -and -not $r1.App.IsCompleteWithNewAfterCutoff -and $r1.App.SnapshotAvailable -and
        $r1.App.CompletedCount -eq 2 -and @(& $late501Errors $r1).Count -eq 0
    ) -Name 'Archive/501/S01SnapshotCompleteNoNewIsSuccess' `
      -Failure "повна передача знімка без нових об'єктів має давати УСПІШНО/0; label=$($r1.Label) exit=$($r1.ExitCode) completed=$($r1.App.CompletedCount)"

    # 2. Новий файл з'явився під час WinSCP -> ПОПЕРЕДЖЕННЯ, код 10, без ERROR.
    $c2 = & $late501NewCase 'S02'
    $r2 = & $late501Run -CaseRoot $c2.Root -Remote $c2.Remote -DuringSyncWrites @(& $late501Write 'BAZA_APP' (Join-Path $c2.App 'KZ\2026\late.pdf') 50)

    Test-BRAVOCondition -Condition (
        $r2.Manual.Success -and $r2.Label -eq 'ПОПЕРЕДЖЕННЯ' -and $r2.ExitCode -eq 10 -and
        $r2.App.IsCompleteWithNewAfterCutoff -and $r2.App.NewAfterCutoffCount -eq 1 -and $r2.App.RealMissingCount -eq 0 -and
        @(& $late501Errors $r2).Count -eq 0 -and
        @(& $late501Warnings $r2 | Where-Object { $_.Message -like "*з'явилися після старту синхронізації*late.pdf*" }).Count -eq 1 -and
        # 5.2.5: немає Results.SyncOutcomes; кількість несе сам результат ручної синхронізації.
        $r2.Manual.Results.BAZA_APP.Degraded -and $r2.Manual.NewAfterCutoffCount -eq 1
    ) -Name 'Archive/501/S02NewFileDuringSyncIsWarning' `
      -Failure "файл, створений під час WinSCP, має давати ПОПЕРЕДЖЕННЯ/10 без ERROR; label=$($r2.Label) exit=$($r2.ExitCode) errors=$((& $late501Errors $r2 | ForEach-Object { $_.Message }) -join ' | ')"

    # 3. Відтворення інциденту #501: шість нових PDF із кириличними іменами (імена вигадані).
    $c3 = & $late501NewCase 'S03' -SyncedCount 4 -PendingCount 8
    $late501IncidentNames = @(
        '900001_пм_26_20990101-100001.pdf', '900002_пм_26_20990101-100002.pdf', '900003_пм_26_20990101-100003.pdf',
        '900004_пм_26_20990101-100004.pdf', '900005_пм_26_20990101-100005.pdf', '900006_пм_26_20990101-100006.pdf'
    )
    $r3 = & $late501Run -CaseRoot $c3.Root -Remote $c3.Remote -DuringSyncWrites @(foreach ($n in $late501IncidentNames) { & $late501Write 'BAZA_APP' (Join-Path $c3.App "KZ\2026\$n") 4096 })

    Test-BRAVOCondition -Condition (
        $r3.Label -eq 'ПОПЕРЕДЖЕННЯ' -and $r3.ExitCode -eq 10 -and
        $r3.App.NewAfterCutoffCount -eq 6 -and $r3.App.RealMissingCount -eq 0 -and $r3.App.ChangedDuringSyncCount -eq 0 -and
        $r3.App.BeforeCount -eq 8 -and $r3.App.CompletedCount -eq 8 -and $r3.App.RetryableRemainingCount -eq 6 -and
        @(& $late501Errors $r3).Count -eq 0 -and
        @($r3.Log | Where-Object { $_.Level -eq 'WARNING' -and $_.Message -like "AUDIT BAZA_APP*[З'ЯВИВСЯ ПІД ЧАС СИНХРОНІЗАЦІЇ]*_пм_26_*" }).Count -eq 6
    ) -Name 'Archive/501/S03IncidentSixNewPdfIsWarning' `
      -Failure "інцидент #501 (6 нових PDF після старту) має давати ПОПЕРЕДЖЕННЯ, CompletedCount=8, а не ПОМИЛКА; label=$($r3.Label) new=$($r3.App.NewAfterCutoffCount) completed=$($r3.App.CompletedCount)"

    # 4. Старий файл не переданий -> ПОМИЛКА, код 50.
    $c4 = & $late501NewCase 'S04'
    $r4 = & $late501Run -CaseRoot $c4.Root -Remote $c4.Remote -FailPaths @('KZ\2026\pending_1.pdf')
    Test-BRAVOCondition -Condition (
        -not $r4.Manual.Success -and $r4.Label -eq 'ПОМИЛКА' -and $r4.ExitCode -eq 50 -and
        $r4.App.RealMissingCount -eq 1 -and -not $r4.App.IsCompleteWithNewAfterCutoff -and
        @(& $late501Errors $r4 | Where-Object { $_.Message -like '*WinSCP повернув код 0, але синхронiзацiя BAZA_APP часткова*не передано зі знімка циклу: 1*' }).Count -eq 1
    ) -Name 'Archive/501/S04OldFileNotTransferredIsError' `
      -Failure "непереданий файл знімка має лишатися ПОМИЛКА/50; label=$($r4.Label) exit=$($r4.ExitCode)"

    # 5. NEGATIVE CONTROL: старий файл не переданий, поруч з'явився новий -> ПОМИЛКА.
    $c5 = & $late501NewCase 'S05'
    $r5 = & $late501Run -CaseRoot $c5.Root -Remote $c5.Remote -FailPaths @('KZ\2026\pending_2.pdf') -DuringSyncWrites @(& $late501Write 'BAZA_APP' (Join-Path $c5.App 'KZ\2026\late.pdf') 50)

    Test-BRAVOCondition -Condition (
        -not $r5.Manual.Success -and $r5.Label -eq 'ПОМИЛКА' -and $r5.ExitCode -eq 50 -and
        $r5.App.RealMissingCount -eq 1 -and $r5.App.NewAfterCutoffCount -eq 1 -and -not $r5.App.IsCompleteWithNewAfterCutoff -and
        @(& $late501Errors $r5 | Where-Object { $_.Message -like 'AUDIT BAZA_APP*pending_2.pdf*' }).Count -eq 1
    ) -Name 'Archive/501/S05NegativeControlOldMissingWithNewStaysError' `
      -Failure "НЕГАТИВНИЙ КОНТРОЛЬ: непереданий старий файл лишається ПОМИЛКА навіть поруч із новим; label=$($r5.Label) real=$($r5.App.RealMissingCount) new=$($r5.App.NewAfterCutoffCount)"

    # 6. Новий файл із давнім LastWriteTime -> класифікується за знімком (ПОПЕРЕДЖЕННЯ).
    $c6 = & $late501NewCase 'S06'
    $r6 = & $late501Run -CaseRoot $c6.Root -Remote $c6.Remote -DuringSyncWrites @(& $late501Write 'BAZA_APP' (Join-Path $c6.App 'KZ\2026\old-stamp.pdf') 50 ([datetime]'2019-01-01T00:00:00Z'))

    Test-BRAVOCondition -Condition (
        $r6.Label -eq 'ПОПЕРЕДЖЕННЯ' -and $r6.App.NewAfterCutoffCount -eq 1 -and $r6.App.RealMissingCount -eq 0
    ) -Name 'Archive/501/S06NewFileWithOldTimestampClassifiedBySnapshot' `
      -Failure "новий файл з давнім LastWriteTime має класифікуватись за знімком, а не за часом; label=$($r6.Label)"

    # 7. Старий файл змінено після сканування WinSCP -> окремий mutation-клас, ПОМИЛКА.
    $c7 = & $late501NewCase 'S07'
    $r7 = & $late501Run -CaseRoot $c7.Root -Remote $c7.Remote -DuringSyncWrites @(& $late501Write 'BAZA_APP' (Join-Path $c7.App 'KZ\2026\pending_1.pdf') 333)

    Test-BRAVOCondition -Condition (
        -not $r7.Manual.Success -and $r7.Label -eq 'ПОМИЛКА' -and
        $r7.App.ChangedDuringSyncCount -eq 1 -and $r7.App.RealMissingCount -eq 0 -and $r7.App.NewAfterCutoffCount -eq 0 -and
        @(& $late501Errors $r7 | Where-Object { $_.Message -like 'AUDIT BAZA_APP*[ЗМІНЕНО ПІД ЧАС СИНХРОНІЗАЦІЇ]*pending_1.pdf*' }).Count -eq 1
    ) -Name 'Archive/501/S07ChangedDuringSyncIsSeparateErrorClass' `
      -Failure "файл знімка, змінений під час передачі, — окремий клас і лишається помилкою; label=$($r7.Label) changed=$($r7.App.ChangedDuringSyncCount)"

    # 8. WinSCP повернув ненульовий код (лише нові об'єкти в залишку) -> ПОМИЛКА.
    $c8 = & $late501NewCase 'S08'
    $r8 = & $late501Run -CaseRoot $c8.Root -Remote $c8.Remote -ExitCode 1 -DuringSyncWrites @(& $late501Write 'BAZA_APP' (Join-Path $c8.App 'KZ\2026\late.pdf') 50)

    Test-BRAVOCondition -Condition (
        -not $r8.Manual.Success -and $r8.Label -eq 'ПОМИЛКА' -and $r8.ExitCode -eq 50 -and
        -not $r8.App.IsCompleteWithNewAfterCutoff -and
        @(& $late501Errors $r8 | Where-Object { $_.Message -like '*Помилка SFTP-синхронiзацiї BAZA_APP (код: 1)*' }).Count -eq 1
    ) -Name 'Archive/501/S08WinSCPTransportFailureStaysError' `
      -Failure "ненульовий код WinSCP лишається ПОМИЛКА незалежно від класифікації; label=$($r8.Label)"

    # 9. Код 0, але реально бракує прихованого файла знімка в підкаталозі -> ПОМИЛКА.
    $c9 = & $late501NewCase 'S09'
    $hiddenOld = Join-Path $c9.App 'KZ\2026\hidden-old.pdf'
    & $late501NewFile $hiddenOld 77
    (Get-Item -LiteralPath $hiddenOld -Force).Attributes = 'Hidden'
    $r9 = & $late501Run -CaseRoot $c9.Root -Remote $c9.Remote -FailPaths @('KZ\2026\hidden-old.pdf')
    Test-BRAVOCondition -Condition (
        -not $r9.Manual.Success -and $r9.Label -eq 'ПОМИЛКА' -and $r9.App.RealMissingCount -eq 1 -and $r9.App.NewAfterCutoffCount -eq 0
    ) -Name 'Archive/501/S09ExitZeroButHiddenSnapshotFileMissingIsError' `
      -Failure "прихований файл знімка, якого бракує після коду 0, не може стати 'новим'; label=$($r9.Label) new=$($r9.App.NewAfterCutoffCount)"

    # 10. Пост-аудит недоступний -> ПОМИЛКА (VerificationSucceeded = false).
    $c10 = & $late501NewCase 'S10'
    $r10 = & $late501Run -CaseRoot $c10.Root -Remote $c10.Remote -AfterAuditFails
    Test-BRAVOCondition -Condition (
        -not $r10.Manual.Success -and $r10.Label -eq 'ПОМИЛКА' -and -not $r10.App.VerificationSucceeded -and
        $null -eq $r10.App.NewAfterCutoffCount -and -not $r10.App.IsCompleteWithNewAfterCutoff
    ) -Name 'Archive/501/S10AfterAuditUnavailableIsError' `
      -Failure "недоступний пост-аудит лишається ПОМИЛКА; label=$($r10.Label)"

    # 11. BAZA_APP і BAZA_WWW мають власні знімки: файл, створений у WWW під час
    # синхронізації APP, належить знімку WWW і передається; новий у APP — попередження.
    $c11 = & $late501NewCase 'S11'
    $r11 = & $late501Run -CaseRoot $c11.Root -Remote $c11.Remote -WithWWW -DuringSyncWrites @(
        (& $late501Write 'BAZA_APP' (Join-Path $c11.App 'KZ\2026\late-app.pdf') 50),
        (& $late501Write 'BAZA_APP' (Join-Path $c11.Www 'KZ\2026\written-during-app.pdf') 50)
    )
    Test-BRAVOCondition -Condition (
        $r11.Manual.Success -and $r11.Label -eq 'ПОПЕРЕДЖЕННЯ' -and $r11.ExitCode -eq 10 -and
        $r11.App.NewAfterCutoffCount -eq 1 -and $r11.Www.IsComplete -and $r11.Www.NewAfterCutoffCount -eq 0 -and
        $r11.App.CycleId -ne $r11.Www.CycleId -and
        ([datetime]$r11.Www.SyncStartUtc) -gt ([datetime]$r11.App.SyncStartUtc) -and
        $c11.Remote['/baza_www'].ContainsKey('KZ\2026\written-during-app.pdf')
    ) -Name 'Archive/501/S11AppAndWwwHaveIndependentCutoffs' `
      -Failure "кожен компонент має власні CycleId/SyncStartUtc; app=$($r11.App.CycleId)@$($r11.App.SyncStartUtc) www=$($r11.Www.CycleId)@$($r11.Www.SyncStartUtc)"

    # 12. Наступний цикл передає нові файли -> УСПІШНО.
    $r12 = & $late501Run -CaseRoot $c2.Root -Remote $c2.Remote
    Test-BRAVOCondition -Condition (
        $r12.Manual.Success -and $r12.Label -eq 'УСПІШНО' -and $r12.ExitCode -eq 0 -and $r12.App.IsComplete -and
        $c2.Remote['/baza_app'].ContainsKey('KZ\2026\late.pdf')
    ) -Name 'Archive/501/S12NextCycleTransfersLateFilesSuccess' `
      -Failure "наступний цикл має передати нові файли й дати УСПІШНО; label=$($r12.Label)"

    # 13. Перерваний цикл (WinSCP код 1, нічого не передано) -> ПОМИЛКА; повторний запуск -> УСПІШНО.
    $c13 = & $late501NewCase 'S13'
    $r13a = & $late501Run -CaseRoot $c13.Root -Remote $c13.Remote -ExitCode 1 -FailPaths @('KZ\2026\pending_1.pdf', 'KZ\2026\pending_2.pdf')
    $r13b = & $late501Run -CaseRoot $c13.Root -Remote $c13.Remote
    Test-BRAVOCondition -Condition (
        $r13a.Label -eq 'ПОМИЛКА' -and $r13a.ExitCode -eq 50 -and $r13a.App.RealMissingCount -eq 2 -and
        $r13b.Label -eq 'УСПІШНО' -and $r13b.ExitCode -eq 0 -and $r13b.App.IsComplete
    ) -Name 'Archive/501/S13InterruptedThenRetrySucceeds' `
      -Failure "перерваний цикл — ПОМИЛКА, повтор — УСПІШНО; a=$($r13a.Label) b=$($r13b.Label)"

    # 14. Сумісність: старий виклик Get-BAZASynchronizationOutcome (без знімка)
    # дає попередню семантику; типовий Get-BRAVOBazaLocalSnapshot не змінився;
    # старий shape результату -SyncBAZA (без NewAfterCutoffCount) -> УСПІШНО/0.
    $compat = & $late501Module {
        param($LocalRoot)
        $after = [pscustomobject]@{ Success = $true; PendingFiles = @([pscustomobject]@{ Action = 'UploadNew'; Path = (Join-Path $LocalRoot 'x.pdf'); IsDirectory = $false }) }
        $before = [pscustomobject]@{ Success = $true; PendingFiles = @() }
        [pscustomobject]@{
            Outcome = Get-BAZASynchronizationOutcome -WinSCPExitCode 0 -ComparisonBefore $before -ComparisonAfter $after
        }
    } $c1.App
    # Старий shape результату -SyncBAZA (без NewAfterCutoffCount): вирази Main з рантайму.
    $compatMain = Get-Late501MainOutcome -ManualSyncResult ([pscustomobject]@{ Success = $true; Skipped = $false; Results = $null })
    $compat | Add-Member -NotePropertyName Label -NotePropertyValue ([string]$compatMain.Label).Replace([string][char]0x0049, [string][char]0x0406)
    $compat | Add-Member -NotePropertyName Exit -NotePropertyValue $compatMain.ExitCode
    $hiddenDefault = Join-Path $c1.App 'KZ\2026\hidden-default.pdf'
    & $late501NewFile $hiddenDefault 10
    (Get-Item -LiteralPath $hiddenDefault -Force).Attributes = 'Hidden'
    $defaultSnapshot = Get-BRAVOBazaLocalSnapshot -LocalDirectory $c1.App
    $extendedSnapshot = Get-BRAVOBazaLocalSnapshot -LocalDirectory $c1.App -IncludeHiddenSystem -IncludeDirectories
    Test-BRAVOCondition -Condition (
        $compat.Outcome.IsPartial -and -not $compat.Outcome.IsCompleteWithNewAfterCutoff -and -not $compat.Outcome.SnapshotAvailable -and
        $compat.Outcome.RealMissingCount -eq 1 -and $compat.Outcome.NewAfterCutoffCount -eq 0 -and
        $compat.Label -eq 'УСПІШНО' -and $compat.Exit -eq 0 -and
        $null -eq $defaultSnapshot.Directories -and -not $defaultSnapshot.Entries.ContainsKey('KZ\2026\hidden-default.pdf') -and
        $extendedSnapshot.Entries.ContainsKey('KZ\2026\hidden-default.pdf') -and $extendedSnapshot.Directories.Contains('KZ\2026') -and
        $extendedSnapshot.Directories.Contains('kz\2026')
    ) -Name 'Archive/501/S14BackwardCompatibleContracts' `
      -Failure "виклики без знімка, типовий знімок і старий shape результату -SyncBAZA мають зберегти попередню поведінку"

    # 15. Великий обсяг: 3000 об'єктів знімка + 2000 нових під час циклу —
    # точні лічильники без втрат (класифікація по хешу, не по масиву).
    $c15 = & $late501NewCase 'S15' -SyncedCount 0 -PendingCount 0
    for ($i = 1; $i -le 3000; $i++) {
        $p = Join-Path $c15.App ("KZ\2026\big_{0:D5}.pdf" -f $i)
        [IO.File]::WriteAllBytes($p, [byte[]](1))
        $c15.Remote['/baza_app']["KZ\2026\big_{0:D5}.pdf" -f $i] = 1
    }
    $r15 = & $late501Run -CaseRoot $c15.Root -Remote $c15.Remote -DuringSyncWrites @(for ($j = 1; $j -le 2000; $j++) { & $late501Write 'BAZA_APP' (Join-Path $c15.App ("KZ\2026\late_{0:D5}.pdf" -f $j)) 1 })
    Test-BRAVOCondition -Condition (
        $r15.Label -eq 'ПОПЕРЕДЖЕННЯ' -and $r15.App.NewAfterCutoffCount -eq 2000 -and $r15.App.RealMissingCount -eq 0 -and
        @($r15.Log | Where-Object { $_.Message -like "*з'явилися після старту*ще 1980 — див. рядки AUDIT*" }).Count -eq 1
    ) -Name 'Archive/501/S15LargeVolumeCountsAndCappedSummary' `
      -Failure "2000 нових серед 3000 знімка: точні лічильники й обмежений перелік у підсумку; new=$($r15.App.NewAfterCutoffCount)"

    # 17. Шлях, який GetFullPath змінює не лише роздільниками (кінцева '.'/' '
    # імені), або об'єкт, якого зараз немає за шляхом WinSCP, не може стати
    # "новим": інакше постійна непередача щоразу ставала б ПОПЕРЕДЖЕННЯМ.
    $c17 = & $late501NewCase 'S17' -SyncedCount 0 -PendingCount 0
    $c17Dir = Join-Path $c17.App 'KZ\2026'
    foreach ($odd in @('trail.', 'space ')) { [IO.File]::WriteAllBytes(('\\?\' + (Join-Path $c17Dir $odd)), [byte[]](7)) }
    $c17Snapshot = Get-BRAVOBazaLocalSnapshot -LocalDirectory $c17.App -IncludeHiddenSystem -IncludeDirectories
    $c17Pending = @(
        [pscustomobject]@{ Action = 'UploadNew'; Reason = 'x'; Path = (Join-Path $c17Dir 'trail.'); IsDirectory = $false; SizeBytes = 1 },
        [pscustomobject]@{ Action = 'UploadNew'; Reason = 'x'; Path = (Join-Path $c17Dir 'space '); IsDirectory = $false; SizeBytes = 1 },
        [pscustomobject]@{ Action = 'UploadNew'; Reason = 'x'; Path = (Join-Path $c17Dir 'no-such-file.pdf'); IsDirectory = $false; SizeBytes = 1 },
        [pscustomobject]@{ Action = 'UploadNew'; Reason = 'x'; Path = (Join-Path $c17Dir 'no-such-dir'); IsDirectory = $true; SizeBytes = $null },
        [pscustomobject]@{ Action = 'UploadNew'; Reason = 'x'; Path = ($c17Dir + '\sub\..\x.pdf'); IsDirectory = $false; SizeBytes = 1 }
    )
    $c17Result = & $late501Module {
        param($Pending, $Snapshot, $Root)
        Get-BAZAPendingFileCycleClassification -PendingFiles $Pending -LocalSnapshot $Snapshot -LocalRoot $Root
    } $c17Pending $c17Snapshot $c17.App
    Test-BRAVOCondition -Condition (
        $c17Snapshot.Entries.ContainsKey('KZ\2026\trail.') -and
        @($c17Result.RealMissing).Count -eq 5 -and @($c17Result.NewAfterCutoff).Count -eq 0
    ) -Name 'Archive/501/S17UnmatchablePathsFailClosed' `
      -Failure "кінцева '.'/' ', неіснуючий об'єкт і '..' мають давати RealMissing; real=$(@($c17Result.RealMissing).Count) new=$(@($c17Result.NewAfterCutoff).Count)"
    foreach ($odd in @('trail.', 'space ')) { [IO.File]::Delete('\\?\' + (Join-Path $c17Dir $odd)) }
    # 18. Шлях змінив тип під час циклу (каталог знімка замінено файлом і
    # навпаки) — заміна, а не новий об'єкт: ChangedDuringSync (ERROR).
    # Контроль: справжні нові файл і каталог лишаються NewAfterCutoff.
    $c18 = & $late501NewCase 'S18' -SyncedCount 0 -PendingCount 0
    $c18Dir = Join-Path $c18.App 'KZ\2026'
    [void][IO.Directory]::CreateDirectory((Join-Path $c18Dir 'swap-dir'))
    [IO.File]::WriteAllBytes((Join-Path $c18Dir 'swap-file.pdf'), [byte[]](1))
    $c18Snapshot = Get-BRAVOBazaLocalSnapshot -LocalDirectory $c18.App -IncludeHiddenSystem -IncludeDirectories
    [IO.Directory]::Delete((Join-Path $c18Dir 'swap-dir'))
    [IO.File]::WriteAllBytes((Join-Path $c18Dir 'swap-dir'), [byte[]](2))
    [IO.File]::Delete((Join-Path $c18Dir 'swap-file.pdf'))
    [void][IO.Directory]::CreateDirectory((Join-Path $c18Dir 'swap-file.pdf'))
    [IO.File]::WriteAllBytes((Join-Path $c18Dir 'brand-new.pdf'), [byte[]](3))
    [void][IO.Directory]::CreateDirectory((Join-Path $c18Dir 'brand-new-dir'))
    $c18Pending = @(
        [pscustomobject]@{ Action = 'UploadNew'; Reason = 'x'; Path = (Join-Path $c18Dir 'swap-dir'); IsDirectory = $false; SizeBytes = 1 },
        [pscustomobject]@{ Action = 'UploadNew'; Reason = 'x'; Path = (Join-Path $c18Dir 'swap-file.pdf'); IsDirectory = $true; SizeBytes = $null },
        [pscustomobject]@{ Action = 'UploadNew'; Reason = 'x'; Path = (Join-Path $c18Dir 'brand-new.pdf'); IsDirectory = $false; SizeBytes = 1 },
        [pscustomobject]@{ Action = 'UploadNew'; Reason = 'x'; Path = (Join-Path $c18Dir 'brand-new-dir'); IsDirectory = $true; SizeBytes = $null }
    )
    $c18Result = & $late501Module {
        param($Pending, $Snapshot, $Root)
        # Межа старту передачі — до створення "справжніх нових" об'єктів.
        Get-BAZAPendingFileCycleClassification -PendingFiles $Pending -LocalSnapshot $Snapshot -LocalRoot $Root -SyncStartUtc ([datetime]'2000-01-01T00:00:00Z')
    } $c18Pending $c18Snapshot $c18.App
    $c18Changed = @(@($c18Result.ChangedDuringSync) | ForEach-Object { Split-Path -Leaf ([string]$_.Path) } | Sort-Object)
    $c18New = @(@($c18Result.NewAfterCutoff) | ForEach-Object { Split-Path -Leaf ([string]$_.Path) } | Sort-Object)
    Test-BRAVOCondition -Condition (
        $c18Changed.Count -eq 2 -and $c18Changed -contains 'swap-dir' -and $c18Changed -contains 'swap-file.pdf' -and
        $c18New.Count -eq 2 -and $c18New -contains 'brand-new-dir' -and $c18New -contains 'brand-new.pdf' -and
        @($c18Result.RealMissing).Count -eq 0
    ) -Name 'Archive/501/S18TypeReplacementIsChangedNotNew' `
      -Failure "заміна файл<->каталог під час циклу має бути ChangedDuringSync, справжні нові — NewAfterCutoff; changed=$($c18Changed -join ',') new=$($c18New -join ',')"

    # ------------------------------------------------------------
    # #501 follow-up: консистентність знімка.
    #   P2 — обхід знімка неатомарний: об'єкт поза знімком "новий" лише тоді,
    #        коли створений після межі старту передачі (CreationTimeUtc).
    #   P1 — об'єкти знімка, що зникли/змінили тип локально, виявляються
    #        звірянням знімка з живим деревом, а не лише через залишок аудиту.
    # ------------------------------------------------------------
    $late501Info = { param($Run) @($Run.Log | Where-Object { $_.Level -eq 'INFO' }) }

    # F01 (P2). Файл з'явився в уже обійденому каталозі під час обходу знімка
    # (до старту WinSCP), WinSCP пропустив його з кодом 0 -> ПОМИЛКА, не "новий".
    $f01 = & $late501NewCase 'F01'
    $f01Late = Join-Path $f01.App 'KZ\2026\during-snapshot.pdf'
    $rf01 = & $late501Run -CaseRoot $f01.Root -Remote $f01.Remote -FailPaths @('KZ\2026\during-snapshot.pdf') -Ops @(& $late501Op 'Snapshot' 'Write' $f01Late)
    Test-BRAVOCondition -Condition (
        -not $rf01.Manual.Success -and $rf01.Label -eq 'ПОМИЛКА' -and $rf01.ExitCode -eq 50 -and
        $rf01.App.RealMissingCount -eq 1 -and $rf01.App.NewAfterCutoffCount -eq 0 -and
        @(& $late501Errors $rf01 | Where-Object { $_.Message -like 'AUDIT BAZA_APP*during-snapshot.pdf*' }).Count -eq 1
    ) -Name 'Archive/501/F01CreatedDuringSnapshotEnumerationIsError' `
      -Failure "файл, створений під час обходу знімка й не переданий, — ПОМИЛКА, а не ПОПЕРЕДЖЕННЯ; label=$($rf01.Label) real=$($rf01.App.RealMissingCount) new=$($rf01.App.NewAfterCutoffCount)"

    # F02 (P2). Контроль: такий самий файл WinSCP передав -> УСПІШНО (без хибних помилок).
    $f02 = & $late501NewCase 'F02'
    $rf02 = & $late501Run -CaseRoot $f02.Root -Remote $f02.Remote -Ops @(& $late501Op 'Snapshot' 'Write' (Join-Path $f02.App 'KZ\2026\during-snapshot.pdf'))
    Test-BRAVOCondition -Condition (
        $rf02.Manual.Success -and $rf02.Label -eq 'УСПІШНО' -and $rf02.ExitCode -eq 0 -and $rf02.App.IsComplete -and
        @(& $late501Errors $rf02).Count -eq 0
    ) -Name 'Archive/501/F02CreatedDuringSnapshotAndTransferredIsSuccess' `
      -Failure "переданий файл, створений під час обходу знімка, не дає помилки; label=$($rf02.Label)"

    # F03 (P2). Новий каталог із файлом з'явився після обходу знімка, до старту
    # WinSCP; WinSCP пропустив обидва -> ПОМИЛКА (існували до старту передачі).
    $f03 = & $late501NewCase 'F03'
    $rf03 = & $late501Run -CaseRoot $f03.Root -Remote $f03.Remote -FailPaths @('KZ\2026\new-dir', 'KZ\2026\new-dir\before-start.pdf') -Ops @(
        (& $late501Op 'Snapshot' 'MkDir' (Join-Path $f03.App 'KZ\2026\new-dir')),
        (& $late501Op 'Snapshot' 'Write' (Join-Path $f03.App 'KZ\2026\new-dir\before-start.pdf'))
    )
    Test-BRAVOCondition -Condition (
        $rf03.Label -eq 'ПОМИЛКА' -and $rf03.App.RealMissingCount -eq 2 -and $rf03.App.NewAfterCutoffCount -eq 0
    ) -Name 'Archive/501/F03DirectoryCreatedBeforeTransferStartIsError' `
      -Failure "каталог і файл, що існували до старту WinSCP і не передані, — ПОМИЛКА; label=$($rf03.Label) real=$($rf03.App.RealMissingCount) new=$($rf03.App.NewAfterCutoffCount)"

    # F04 (P1). Файл знімка, що чекав передачі, видалено до старту WinSCP -> ПОМИЛКА.
    $f04 = & $late501NewCase 'F04'
    $rf04 = & $late501Run -CaseRoot $f04.Root -Remote $f04.Remote -Ops @(& $late501Op 'Snapshot' 'Delete' (Join-Path $f04.App 'KZ\2026\pending_1.pdf'))
    Test-BRAVOCondition -Condition (
        -not $rf04.Manual.Success -and $rf04.Label -eq 'ПОМИЛКА' -and $rf04.ExitCode -eq 50 -and
        $rf04.App.ChangedDuringSyncCount -eq 1 -and -not $rf04.App.IsComplete -and
        @(& $late501Errors $rf04 | Where-Object { $_.Message -like 'AUDIT BAZA_APP*[ЗМІНЕНО ПІД ЧАС СИНХРОНІЗАЦІЇ]*pending_1.pdf*' }).Count -eq 1
    ) -Name 'Archive/501/F04SnapshotFileDeletedBeforeTransferIsError' `
      -Failure "файл знімка, видалений до передачі, не може дати УСПІШНО; label=$($rf04.Label) changed=$($rf04.App.ChangedDuringSyncCount)"

    # F05 (P1). Файл знімка видалено після сканування WinSCP, до upload (WinSCP
    # пропустив, код 0, пост-аудит його не бачить) -> ПОМИЛКА.
    $f05 = & $late501NewCase 'F05'
    $rf05 = & $late501Run -CaseRoot $f05.Root -Remote $f05.Remote -FailPaths @('KZ\2026\pending_2.pdf') -Ops @(& $late501Op 'Sync' 'Delete' (Join-Path $f05.App 'KZ\2026\pending_2.pdf'))
    Test-BRAVOCondition -Condition (
        -not $rf05.Manual.Success -and $rf05.Label -eq 'ПОМИЛКА' -and $rf05.ExitCode -eq 50 -and
        $rf05.App.ChangedDuringSyncCount -eq 1 -and $rf05.App.RetryableRemainingCount -eq 0 -and
        @(& $late501Errors $rf05 | Where-Object { $_.Message -like '*BAZA_APP*зникли*' -or $_.Message -like '*BAZA_APP*зник*' }).Count -ge 1
    ) -Name 'Archive/501/F05SnapshotFileDeletedAfterScanBeforeUploadIsError' `
      -Failure "файл знімка, зниклий до upload, — ПОМИЛКА навіть без залишку в пост-аудиті; label=$($rf05.Label) changed=$($rf05.App.ChangedDuringSyncCount)"

    # F06 (P1). Перейменування файла знімка під час синхронізації: нове ім'я
    # зберігає CreationTime -> не "новий" -> ПОМИЛКА.
    $f06 = & $late501NewCase 'F06'
    $rf06 = & $late501Run -CaseRoot $f06.Root -Remote $f06.Remote -Ops @(& $late501Op 'Sync' 'Move' (Join-Path $f06.App 'KZ\2026\synced_1.pdf') -Target (Join-Path $f06.App 'KZ\2026\renamed_1.pdf'))
    Test-BRAVOCondition -Condition (
        $rf06.Label -eq 'ПОМИЛКА' -and $rf06.App.NewAfterCutoffCount -eq 0 -and $rf06.App.RealMissingCount -eq 1 -and
        @(& $late501Errors $rf06 | Where-Object { $_.Message -like 'AUDIT BAZA_APP*renamed_1.pdf*' }).Count -eq 1
    ) -Name 'Archive/501/F06RenamedSnapshotFileIsNotNew' `
      -Failure "нове ім'я перейменованого файла знімка не є безпечним NewAfterCutoff; label=$($rf06.Label) new=$($rf06.App.NewAfterCutoffCount) real=$($rf06.App.RealMissingCount)"

    # F07 (P1). Переміщення файла знімка, що чекав передачі, в інший підкаталог -> ПОМИЛКА.
    $f07 = & $late501NewCase 'F07'
    $rf07 = & $late501Run -CaseRoot $f07.Root -Remote $f07.Remote -FailPaths @('KZ\2026\pending_1.pdf') -Ops @(& $late501Op 'Sync' 'Move' (Join-Path $f07.App 'KZ\2026\pending_1.pdf') -Target (Join-Path $f07.App 'KZ\pending_1.pdf'))
    Test-BRAVOCondition -Condition (
        $rf07.Label -eq 'ПОМИЛКА' -and $rf07.App.NewAfterCutoffCount -eq 0 -and
        $rf07.App.ChangedDuringSyncCount -eq 1 -and $rf07.App.RealMissingCount -eq 1
    ) -Name 'Archive/501/F07MovedBetweenDirectoriesIsError' `
      -Failure "переміщення файла знімка між каталогами — зник (Changed) + поза знімком до старту (RealMissing); changed=$($rf07.App.ChangedDuringSyncCount) real=$($rf07.App.RealMissingCount) new=$($rf07.App.NewAfterCutoffCount)"

    # F08 (P1). Файл знімка замінено каталогом під час синхронізації -> ПОМИЛКА.
    $f08 = & $late501NewCase 'F08'
    $f08Path = Join-Path $f08.App 'KZ\2026\synced_2.pdf'
    $rf08 = & $late501Run -CaseRoot $f08.Root -Remote $f08.Remote -Ops @((& $late501Op 'Sync' 'Delete' $f08Path), (& $late501Op 'Sync' 'MkDir' $f08Path))
    Test-BRAVOCondition -Condition (
        $rf08.Label -eq 'ПОМИЛКА' -and $rf08.App.ChangedDuringSyncCount -eq 1 -and $rf08.App.NewAfterCutoffCount -eq 0
    ) -Name 'Archive/501/F08SnapshotFileReplacedByDirectoryIsError' `
      -Failure "файл знімка, замінений каталогом, — ChangedDuringSync (один раз); label=$($rf08.Label) changed=$($rf08.App.ChangedDuringSyncCount)"

    # F09 (P1). Каталог знімка замінено файлом -> ПОМИЛКА.
    $f09 = & $late501NewCase 'F09'
    $f09Dir = Join-Path $f09.App 'KZ\2026\sub'
    [void][IO.Directory]::CreateDirectory($f09Dir)
    $f09.Remote['/baza_app']['KZ\2026\sub'] = -1
    $rf09 = & $late501Run -CaseRoot $f09.Root -Remote $f09.Remote -Ops @((& $late501Op 'Sync' 'DeleteTree' $f09Dir), (& $late501Op 'Sync' 'Write' $f09Dir))
    Test-BRAVOCondition -Condition (
        $rf09.Label -eq 'ПОМИЛКА' -and $rf09.App.ChangedDuringSyncCount -eq 1 -and $rf09.App.NewAfterCutoffCount -eq 0
    ) -Name 'Archive/501/F09SnapshotDirectoryReplacedByFileIsError' `
      -Failure "каталог знімка, замінений файлом, — ChangedDuringSync; label=$($rf09.Label) changed=$($rf09.App.ChangedDuringSyncCount)"

    # F10. Одночасно новий файл, видалений файл знімка й справжня непередача -> ПОМИЛКА з усіма класами.
    $f10 = & $late501NewCase 'F10' -PendingCount 3
    $rf10 = & $late501Run -CaseRoot $f10.Root -Remote $f10.Remote -FailPaths @('KZ\2026\pending_1.pdf', 'KZ\2026\pending_2.pdf') -Ops @(
        (& $late501Op 'Sync' 'Delete' (Join-Path $f10.App 'KZ\2026\pending_2.pdf')),
        (& $late501Op 'Sync' 'Write' (Join-Path $f10.App 'KZ\2026\late.pdf'))
    )
    Test-BRAVOCondition -Condition (
        $rf10.Label -eq 'ПОМИЛКА' -and $rf10.ExitCode -eq 50 -and
        $rf10.App.RealMissingCount -eq 1 -and $rf10.App.ChangedDuringSyncCount -eq 1 -and $rf10.App.NewAfterCutoffCount -eq 1 -and
        -not $rf10.App.IsCompleteWithNewAfterCutoff
    ) -Name 'Archive/501/F10NewDeletedAndRealFailureTogetherIsError' `
      -Failure "новий + зниклий + непереданий -> ПОМИЛКА з точними лічильниками; real=$($rf10.App.RealMissingCount) changed=$($rf10.App.ChangedDuringSyncCount) new=$($rf10.App.NewAfterCutoffCount)"

    # F11. Незалежні цикли: файл знімка WWW видалено під час синхронізації APP
    # (до знімка WWW) — не впливає на жоден компонент; новий у APP -> ПОПЕРЕДЖЕННЯ.
    $f11 = & $late501NewCase 'F11'
    $rf11 = & $late501Run -CaseRoot $f11.Root -Remote $f11.Remote -WithWWW -Ops @(
        (& $late501Op 'Sync' 'Delete' (Join-Path $f11.Www 'KZ\2026\pending_1.pdf')),
        (& $late501Op 'Sync' 'Write' (Join-Path $f11.App 'KZ\2026\late-app.pdf'))
    )
    Test-BRAVOCondition -Condition (
        $rf11.Label -eq 'ПОПЕРЕДЖЕННЯ' -and $rf11.App.NewAfterCutoffCount -eq 1 -and $rf11.App.ChangedDuringSyncCount -eq 0 -and
        $rf11.Www.IsComplete -and $rf11.Www.ChangedDuringSyncCount -eq 0
    ) -Name 'Archive/501/F11IndependentComponentSnapshotsWithDrift' `
      -Failure "зміни дерева WWW до його знімка не впливають на APP/WWW; label=$($rf11.Label) wwwChanged=$($rf11.Www.ChangedDuringSyncCount)"

    # F12. Наступний цикл після гонки (F05): видаленого файла вже немає у знімку -> УСПІШНО.
    $rf12 = & $late501Run -CaseRoot $f05.Root -Remote $f05.Remote
    Test-BRAVOCondition -Condition (
        $rf12.Label -eq 'УСПІШНО' -and $rf12.ExitCode -eq 0 -and $rf12.App.IsComplete -and $rf12.App.ChangedDuringSyncCount -eq 0
    ) -Name 'Archive/501/F12NextCycleAfterSnapshotRaceSucceeds' `
      -Failure "наступний цикл після зникнення файла має бути УСПІШНО; label=$($rf12.Label)"

    # F13. Контроль: файл, уже синхронізований ДО циклу, видалено під час
    # синхронізації — копія в хмарі є (-delete заборонено) -> УСПІШНО, INFO.
    $f13 = & $late501NewCase 'F13'
    $rf13 = & $late501Run -CaseRoot $f13.Root -Remote $f13.Remote -Ops @(& $late501Op 'Sync' 'Delete' (Join-Path $f13.App 'KZ\2026\synced_3.pdf'))
    Test-BRAVOCondition -Condition (
        $rf13.Manual.Success -and $rf13.Label -eq 'УСПІШНО' -and $rf13.ExitCode -eq 0 -and $rf13.App.IsComplete -and
        $rf13.App.VanishedAfterBackupCount -eq 1 -and $rf13.App.ChangedDuringSyncCount -eq 0 -and
        @(& $late501Info $rf13 | Where-Object { $_.Message -like 'AUDIT BAZA_APP*synced_3.pdf*' }).Count -eq 1
    ) -Name 'Archive/501/F13DeletedAlreadyBackedUpFileIsNotError' `
      -Failure "видалення вже зарезервованого файла не є збоєм синхронізації; label=$($rf13.Label) vanishedAfterBackup=$($rf13.App.VanishedAfterBackupCount)"

    # F14. Зарезервований файл змінено після знімка, -mirror перезалив у хмару
    # нову версію, потім файл видалено: копія в хмарі вже не версія знімка -> ПОМИЛКА.
    $f14 = & $late501NewCase 'F14'
    $f14Path = Join-Path $f14.App 'KZ\2026\synced_3.pdf'
    $rf14 = & $late501Run -CaseRoot $f14.Root -Remote $f14.Remote -Ops @(
        (& $late501Op 'Snapshot' 'Write' $f14Path -Size 64),
        (& $late501Op 'Sync' 'Delete' $f14Path)
    )
    Test-BRAVOCondition -Condition (
        $rf14.Label -eq 'ПОМИЛКА' -and $rf14.App.ChangedDuringSyncCount -eq 1 -and $rf14.App.VanishedAfterBackupCount -eq 0
    ) -Name 'Archive/501/F14ModifiedThenDeletedIsError' `
      -Failure "зниклий файл знімка, чия копія в хмарі не збігається зі знімком, не може бути 'зарезервованим'; label=$($rf14.Label) changed=$($rf14.App.ChangedDuringSyncCount)"

    # F15. Метадані часу: новий файл зі "старим" CreationTime (копія зі збереженням
    # часу) -> fail-closed ПОМИЛКА; файл знімка зі зміненим лише LastWriteTime,
    # не переданий -> ChangedDuringSync.
    $f15 = & $late501NewCase 'F15'
    $f15New = Join-Path $f15.App 'KZ\2026\copied-with-times.pdf'
    $rf15 = & $late501Run -CaseRoot $f15.Root -Remote $f15.Remote -FailPaths @('KZ\2026\pending_1.pdf') -Ops @(
        (& $late501Op 'Sync' 'Write' $f15New),
        (& $late501Op 'Sync' 'SetCreation' $f15New -Time ([datetime]'2019-01-01T00:00:00Z')),
        (& $late501Op 'Sync' 'SetLastWrite' (Join-Path $f15.App 'KZ\2026\pending_1.pdf') -Time ([datetime]'2020-02-02T00:00:00Z'))
    )
    Test-BRAVOCondition -Condition (
        $rf15.Label -eq 'ПОМИЛКА' -and $rf15.App.NewAfterCutoffCount -eq 0 -and
        $rf15.App.RealMissingCount -eq 1 -and $rf15.App.ChangedDuringSyncCount -eq 1
    ) -Name 'Archive/501/F15TimeMetadataChangesFailClosed' `
      -Failure "давній CreationTime нового файла й змінений LastWriteTime файла знімка — помилка, не попередження; real=$($rf15.App.RealMissingCount) changed=$($rf15.App.ChangedDuringSyncCount) new=$($rf15.App.NewAfterCutoffCount)"

    # F16. Обсяг: 3000 синхронізованих, 1000 із них видалено під час циклу,
    # 500 нових -> точні лічильники, ПОПЕРЕДЖЕННЯ.
    $f16 = & $late501NewCase 'F16' -SyncedCount 0 -PendingCount 0
    for ($i = 1; $i -le 3000; $i++) {
        $f16File = Join-Path $f16.App ("KZ\2026\vol_{0:D5}.pdf" -f $i)
        [IO.File]::WriteAllBytes($f16File, [byte[]](1))
        $f16.Remote['/baza_app']["KZ\2026\vol_{0:D5}.pdf" -f $i] = 1
        $f16Ticks = [IO.File]::GetLastWriteTimeUtc($f16File).Ticks
        $f16.Remote['#times']['/baza_app']["KZ\2026\vol_{0:D5}.pdf" -f $i] = $f16Ticks - ($f16Ticks % [TimeSpan]::TicksPerSecond)
    }
    $f16Ops = @(
        for ($i = 1; $i -le 1000; $i++) { & $late501Op 'Sync' 'Delete' (Join-Path $f16.App ("KZ\2026\vol_{0:D5}.pdf" -f $i)) }
        for ($j = 1; $j -le 500; $j++) { & $late501Op 'Sync' 'Write' (Join-Path $f16.App ("KZ\2026\fresh_{0:D5}.pdf" -f $j)) -Size 1 }
    )
    $rf16 = & $late501Run -CaseRoot $f16.Root -Remote $f16.Remote -Ops $f16Ops
    Test-BRAVOCondition -Condition (
        $rf16.Label -eq 'ПОПЕРЕДЖЕННЯ' -and $rf16.App.NewAfterCutoffCount -eq 500 -and
        $rf16.App.VanishedAfterBackupCount -eq 1000 -and $rf16.App.ChangedDuringSyncCount -eq 0 -and $rf16.App.RealMissingCount -eq 0
    ) -Name 'Archive/501/F16LargeVolumeDriftCounts' `
      -Failure "3000 знімка, 1000 видалених зарезервованих, 500 нових; new=$($rf16.App.NewAfterCutoffCount) vanished=$($rf16.App.VanishedAfterBackupCount) changed=$($rf16.App.ChangedDuringSyncCount)"

    # F17. Звіряння знімка з живим деревом: зниклі, змінені тип/вміст об'єкти;
    # кирилиця, пробіли, перейменування лише регістром — не зникнення.
    $f17 = & $late501NewCase 'F17' -SyncedCount 0 -PendingCount 0
    $f17Dir = Join-Path $f17.App 'KZ\2026'
    foreach ($n in @('звіт 01.pdf', 'Case.pdf', 'gone.pdf', 'grow.pdf', 'to-dir.pdf')) { [IO.File]::WriteAllBytes((Join-Path $f17Dir $n), [byte[]](1)) }
    [void][IO.Directory]::CreateDirectory((Join-Path $f17Dir 'папка з пробілом'))
    [void][IO.Directory]::CreateDirectory((Join-Path $f17Dir 'to-file'))
    $f17Snapshot = Get-BRAVOBazaLocalSnapshot -LocalDirectory $f17.App -IncludeHiddenSystem -IncludeDirectories
    [IO.File]::Move((Join-Path $f17Dir 'Case.pdf'), (Join-Path $f17Dir 'case.PDF'))
    [IO.File]::Delete((Join-Path $f17Dir 'gone.pdf'))
    [IO.File]::WriteAllBytes((Join-Path $f17Dir 'grow.pdf'), [byte[]](1, 2))
    [IO.File]::Delete((Join-Path $f17Dir 'to-dir.pdf')); [void][IO.Directory]::CreateDirectory((Join-Path $f17Dir 'to-dir.pdf'))
    [IO.Directory]::Delete((Join-Path $f17Dir 'to-file')); [IO.File]::WriteAllBytes((Join-Path $f17Dir 'to-file'), [byte[]](1))
    [IO.Directory]::Delete((Join-Path $f17Dir 'папка з пробілом'))
    $f17Drift = Compare-BRAVOBazaLocalSnapshotToLiveTree -Snapshot $f17Snapshot -LocalDirectory $f17.App
    $f17Vanished = @(@($f17Drift.Vanished) | ForEach-Object { $_.RelativePath } | Sort-Object)
    $f17Type = @(@($f17Drift.TypeReplaced) | ForEach-Object { $_.RelativePath } | Sort-Object)
    $f17Modified = @(@($f17Drift.Modified) | ForEach-Object { $_.RelativePath })
    Test-BRAVOCondition -Condition (
        $f17Drift.Success -and
        $f17Vanished.Count -eq 2 -and $f17Vanished -contains 'KZ\2026\gone.pdf' -and $f17Vanished -contains 'KZ\2026\папка з пробілом' -and
        $f17Type.Count -eq 2 -and $f17Type -contains 'KZ\2026\to-dir.pdf' -and $f17Type -contains 'KZ\2026\to-file' -and
        $f17Modified.Count -eq 1 -and $f17Modified[0] -eq 'KZ\2026\grow.pdf'
    ) -Name 'Archive/501/F17SnapshotDriftDetection' `
      -Failure "звіряння знімка: vanished=$($f17Vanished -join ',') type=$($f17Type -join ',') modified=$($f17Modified -join ',')"

    # F18. Довіра до CreationTime: лише локальний том; UNC/мережевий -> ні (fail-closed);
    # без межі старту передачі об'єкт поза знімком не може бути "новим".
    $f18 = & $late501NewCase 'F18' -SyncedCount 0 -PendingCount 0
    $f18Snapshot = Get-BRAVOBazaLocalSnapshot -LocalDirectory $f18.App -IncludeHiddenSystem -IncludeDirectories
    [IO.File]::WriteAllBytes((Join-Path $f18.App 'KZ\2026\fresh.pdf'), [byte[]](1))
    $f18Result = & $late501Module {
        param($Root, $Snapshot)
        $pending = @([pscustomobject]@{ Action = 'UploadNew'; Reason = 'x'; Path = (Join-Path $Root 'KZ\2026\fresh.pdf'); IsDirectory = $false; SizeBytes = 1 })
        [pscustomobject]@{
            Local = Test-BAZACreationClockTrusted -LocalRoot $Root
            Unc = Test-BAZACreationClockTrusted -LocalRoot '\\file-server-01\baza\app'
            NoBoundary = Get-BAZAPendingFileCycleClassification -PendingFiles $pending -LocalSnapshot $Snapshot -LocalRoot $Root
            OldBoundary = Get-BAZAPendingFileCycleClassification -PendingFiles $pending -LocalSnapshot $Snapshot -LocalRoot $Root -SyncStartUtc ([datetime]'2000-01-01T00:00:00Z')
        }
    } $f18.App $f18Snapshot
    Test-BRAVOCondition -Condition (
        $f18Result.Local -and -not $f18Result.Unc -and
        @($f18Result.NoBoundary.NewAfterCutoff).Count -eq 0 -and @($f18Result.NoBoundary.RealMissing).Count -eq 1 -and
        @($f18Result.OldBoundary.NewAfterCutoff).Count -eq 1
    ) -Name 'Archive/501/F18CreationClockTrustAndBoundaryRequired' `
      -Failure "UNC не довіряється, без межі старту немає NewAfterCutoff; local=$($f18Result.Local) unc=$($f18Result.Unc)"

    # F19. Межа старту передачі: строго після будь-якого вже створеного об'єкта.
    $f19Probe = Join-Path $late501Root 'F19-probe.bin'
    [IO.File]::WriteAllBytes($f19Probe, [byte[]](1))
    $f19Boundary = & $late501Module { Get-BAZASyncStartBoundaryUtc }
    $f19After = Join-Path $late501Root 'F19-after.bin'
    [IO.File]::WriteAllBytes($f19After, [byte[]](1))
    Test-BRAVOCondition -Condition (
        $f19Boundary.Established -and
        ([IO.File]::GetCreationTimeUtc($f19Probe)).Ticks -lt ([datetime]$f19Boundary.BoundaryUtc).Ticks -and
        ([IO.File]::GetCreationTimeUtc($f19After)).Ticks -gt ([datetime]$f19Boundary.BoundaryUtc).Ticks
    ) -Name 'Archive/501/F19SyncStartBoundarySeparatesCreationTimes' `
      -Failure "межа старту передачі має відокремлювати раніше й пізніше створені файли; boundary=$($f19Boundary.BoundaryUtc)"

    # F20. Read-only stat у хмарі лише для зниклих об'єктів (фейкова сесія
    # WinSCP .NET) і доказ "версія знімка у хмарі": той самий розмір і час з
    # точністю до секунди; збій stat або перевищення ліміту — Complete = $false.
    $f20 = & $late501Module {
        $remoteTime = New-Object DateTime 2026, 10, 20, 12, 30, 45, ([DateTimeKind]::Utc)
        $session = New-Object psobject
        $session | Add-Member -MemberType ScriptMethod -Name FileExists -Value { param($Path) $Path -ne '/baza_app/KZ/missing.pdf' }
        $session | Add-Member -MemberType ScriptMethod -Name GetFileInfo -Value {
            param($Path)
            if ($Path -eq '/baza_app/KZ/broken.pdf') { throw 'stat failed' }
            [pscustomobject]@{ IsDirectory = ($Path -eq '/baza_app/KZ/dir'); Length = 100; LastWriteTime = (New-Object DateTime 2026, 10, 20, 12, 30, 45, ([DateTimeKind]::Utc)).ToLocalTime() }
        }
        $vanished = @(
            [pscustomobject]@{ RelativePath = 'KZ\same.pdf'; IsDirectory = $false },
            [pscustomobject]@{ RelativePath = 'KZ\missing.pdf'; IsDirectory = $false },
            [pscustomobject]@{ RelativePath = 'KZ\dir'; IsDirectory = $true }
        )
        $probe = Get-BAZARemoteVanishedProbe -Session $session -RemotePath '/baza_app' -Vanished $vanished
        $broken = Get-BAZARemoteVanishedProbe -Session $session -RemotePath '/baza_app' -Vanished @([pscustomobject]@{ RelativePath = 'KZ\broken.pdf'; IsDirectory = $false })
        $overCap = Get-BAZARemoteVanishedProbe -Session $session -RemotePath '/baza_app' -Vanished $vanished -MaximumProbeCount 2
        $entry = { param($Ms) [pscustomobject]@{ Size = 100; LastWriteTimeUtc = $remoteTime.AddMilliseconds($Ms).ToString('o') } }
        [pscustomobject]@{
            Complete = $probe.Complete
            SameBackedUp = Test-BAZAVanishedSnapshotObjectBackedUp -Vanished $vanished[0] -SnapshotEntry (& $entry 400) -Probe $probe.Entries['KZ\same.pdf']
            OtherSecond = Test-BAZAVanishedSnapshotObjectBackedUp -Vanished $vanished[0] -SnapshotEntry (& $entry 1400) -Probe $probe.Entries['KZ\same.pdf']
            OtherSize = Test-BAZAVanishedSnapshotObjectBackedUp -Vanished $vanished[0] -SnapshotEntry ([pscustomobject]@{ Size = 99; LastWriteTimeUtc = $remoteTime.ToString('o') }) -Probe $probe.Entries['KZ\same.pdf']
            Missing = Test-BAZAVanishedSnapshotObjectBackedUp -Vanished $vanished[1] -SnapshotEntry (& $entry 0) -Probe $probe.Entries['KZ\missing.pdf']
            Directory = Test-BAZAVanishedSnapshotObjectBackedUp -Vanished $vanished[2] -SnapshotEntry $null -Probe $probe.Entries['KZ\dir']
            DirAsFile = Test-BAZAVanishedSnapshotObjectBackedUp -Vanished ([pscustomobject]@{ RelativePath = 'KZ\dir'; IsDirectory = $false }) -SnapshotEntry (& $entry 0) -Probe $probe.Entries['KZ\dir']
            BrokenComplete = $broken.Complete
            BrokenUnknown = ($null -eq $broken.Entries['KZ\broken.pdf'].Exists)
            BrokenBackedUp = Test-BAZAVanishedSnapshotObjectBackedUp -Vanished ([pscustomobject]@{ RelativePath = 'KZ\broken.pdf'; IsDirectory = $false }) -SnapshotEntry (& $entry 0) -Probe $broken.Entries['KZ\broken.pdf']
            BrokenError = [string]$broken.Error
            OverCapComplete = $overCap.Complete
            OverCapEntries = $overCap.Entries.Count
        }
    }
    Test-BRAVOCondition -Condition (
        $f20.Complete -and $f20.SameBackedUp -and -not $f20.OtherSecond -and -not $f20.OtherSize -and -not $f20.Missing -and
        $f20.Directory -and -not $f20.DirAsFile -and
        $f20.BrokenComplete -and $f20.BrokenUnknown -and -not $f20.BrokenBackedUp -and $f20.BrokenError -like '*stat failed*' -and
        -not $f20.OverCapComplete -and $f20.OverCapEntries -eq 0
    ) -Name 'Archive/501/F20RemoteVanishedProbeAndBackupProof' `
      -Failure "stat зниклих у хмарі й доказ версії знімка: $($f20 | ConvertTo-Json -Compress)"

    # F21 (рев'ю). Новий файл знімка не переданий (WinSCP пропустив, його
    # видалено), під час обходу пост-аудиту його немає, а до звіряння знімка
    # LIMS відтворює його з іншим вмістом: у хмарі немає жодної версії -> ПОМИЛКА.
    $f21 = & $late501NewCase 'F21'
    $f21Path = Join-Path $f21.App 'KZ\2026\pending_1.pdf'
    $rf21 = & $late501Run -CaseRoot $f21.Root -Remote $f21.Remote -FailPaths @('KZ\2026\pending_1.pdf') -Ops @(
        (& $late501Op 'Sync' 'Delete' $f21Path),
        (& $late501Op 'AfterCompare' 'Write' $f21Path -Size 77)
    )
    Test-BRAVOCondition -Condition (
        -not $rf21.Manual.Success -and $rf21.Label -eq 'ПОМИЛКА' -and $rf21.ExitCode -eq 50 -and
        $rf21.App.ChangedDuringSyncCount -eq 1 -and $rf21.App.RetryableRemainingCount -eq 0 -and
        @(& $late501Errors $rf21 | Where-Object { $_.Message -like 'AUDIT BAZA_APP*[ЗМІНЕНО ПІД ЧАС СИНХРОНІЗАЦІЇ]*pending_1.pdf*' }).Count -eq 1
    ) -Name 'Archive/501/F21ReappearedWithOtherContentBetweenAuditsIsError' `
      -Failure "файл знімка, відтворений з іншим вмістом між пост-аудитом і звірянням, без копії у хмарі — ПОМИЛКА; label=$($rf21.Label) changed=$($rf21.App.ChangedDuringSyncCount)"

    # F21b. Контроль: файл знімка змінено, і WinSCP передав нову версію (у
    # хмарі — поточна версія) -> не помилка.
    $f21b = & $late501NewCase 'F21b'
    $rf21b = & $late501Run -CaseRoot $f21b.Root -Remote $f21b.Remote -Ops @(& $late501Op 'Snapshot' 'Write' (Join-Path $f21b.App 'KZ\2026\synced_1.pdf') -Size 55)
    Test-BRAVOCondition -Condition (
        $rf21b.Manual.Success -and $rf21b.Label -eq 'УСПІШНО' -and $rf21b.App.IsComplete -and $rf21b.App.ChangedDuringSyncCount -eq 0
    ) -Name 'Archive/501/F21bModifiedAndTransferredIsNotError' `
      -Failure "змінений і переданий файл знімка не є порушенням; label=$($rf21b.Label) changed=$($rf21b.App.ChangedDuringSyncCount)"

    # F22 (Codex QA-001). Junction, створений під час обходу знімка в уже
    # обійденому каталозі, веде на дерево з "годинником попереду" (CreationTime
    # у майбутньому): ReparsePointDirectoryCount знімка = 0, але кандидат іде
    # через reparse point -> не "новий" -> ПОМИЛКА.
    $f22 = & $late501NewCase 'F22'
    $f22Target = Join-Path $f22.Root 'ahead-volume'
    [void][IO.Directory]::CreateDirectory($f22Target)
    $f22Ahead = Join-Path $f22Target 'ahead.pdf'
    [IO.File]::WriteAllBytes($f22Ahead, [byte[]](1))
    [IO.File]::SetCreationTimeUtc($f22Ahead, [DateTime]::UtcNow.AddHours(1))
    $f22Link = Join-Path $f22.App 'KZ\2026\link'
    try {
        $rf22 = & $late501Run -CaseRoot $f22.Root -Remote $f22.Remote -FailPaths @('KZ\2026\link', 'KZ\2026\link\ahead.pdf') -Ops @(& $late501Op 'Snapshot' 'Junction' $f22Link -Target $f22Target)
        $f22New = @(@($rf22.App.CycleClassification.NewAfterCutoff) | ForEach-Object { [string]$_.Path })
        $f22Real = @(@($rf22.App.CycleClassification.RealMissing) | ForEach-Object { [string]$_.Path })
        Test-BRAVOCondition -Condition (
            $rf22.Label -eq 'ПОМИЛКА' -and $rf22.App.NewAfterCutoffCount -eq 0 -and
            @($f22Real | Where-Object { $_ -like '*\link\ahead.pdf' }).Count -eq 1 -and
            @($f22New | Where-Object { $_ -like '*ahead.pdf' }).Count -eq 0
        ) -Name 'Archive/501/F22JunctionCreatedDuringSnapshotIsNotTrusted' `
          -Failure "об'єкт за junction, створеним під час обходу знімка, не може бути 'новим'; label=$($rf22.Label) new=$($f22New -join ',') real=$($f22Real -join ',')"
    } finally {
        if ([IO.Directory]::Exists($f22Link)) { [IO.Directory]::Delete($f22Link) }
    }

    # F23. Зниклих об'єктів більше за ліміт перевірки у хмарі (тут ліміт 2,
    # зникло 3 уже зарезервованих) -> доказу немає -> ПОМИЛКА, причина в журналі.
    $f23 = & $late501NewCase 'F23'
    $rf23 = & $late501Run -CaseRoot $f23.Root -Remote $f23.Remote -ProbeCap 2 -Ops @(
        foreach ($n in 1..3) { & $late501Op 'Sync' 'Delete' (Join-Path $f23.App "KZ\2026\synced_$n.pdf") }
    )
    Test-BRAVOCondition -Condition (
        $rf23.Label -eq 'ПОМИЛКА' -and $rf23.App.ChangedDuringSyncCount -eq 3 -and $rf23.App.VanishedAfterBackupCount -eq 0 -and
        @(& $late501Errors $rf23 | Where-Object { $_.Message -like '*більше за ліміт перевірки 2*' }).Count -eq 1
    ) -Name 'Archive/501/F23VanishedOverProbeLimitIsError' `
      -Failure "понад ліміт stat зниклі об'єкти лишаються помилкою; label=$($rf23.Label) changed=$($rf23.App.ChangedDuringSyncCount)"

    # F24 (Codex, PR #503). Корінь синхронізації чи його предок замінено на
    # junction після Test-BAZACreationClockTrusted: ланцюг кандидата
    # перевіряється до кореня тому включно, а не лише нижче кореня.
    $f24Base = Join-Path $late501Root 'F24'
    $f24Real = Join-Path $f24Base 'real-volume'
    [void][IO.Directory]::CreateDirectory((Join-Path $f24Real 'sub'))
    [IO.File]::WriteAllBytes((Join-Path $f24Real 'root-file.pdf'), [byte[]](1))
    [IO.File]::WriteAllBytes((Join-Path $f24Real 'sub\nested-file.pdf'), [byte[]](1))
    $f24RootLink = Join-Path $f24Base 'root-link'
    $f24AncestorLink = Join-Path $f24Base 'ancestor-link'
    try {
        foreach ($f24Link in @($f24RootLink, $f24AncestorLink)) {
            $f24MklinkOutput = & $env:ComSpec /c mklink /J "$f24Link" "$f24Real" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "mklink /J не вдався: $f24MklinkOutput" }
        }
        $f24 = & $late501Module {
            param($RootLink, $AncestorLink, $Real)
            [pscustomobject]@{
                # Корінь = сам junction, кандидат безпосередньо в ньому.
                RootJunction = Test-BAZAPathHasReparsePoint -FullPath (Join-Path $RootLink 'root-file.pdf')
                # Корінь = ancestor-link\sub, junction — предок кореня.
                AncestorJunction = Test-BAZAPathHasReparsePoint -FullPath (Join-Path $AncestorLink 'sub\nested-file.pdf')
                # Контроль: той самий файл без reparse point у ланцюгу.
                Plain = Test-BAZAPathHasReparsePoint -FullPath (Join-Path $Real 'sub\nested-file.pdf')
            }
        } $f24RootLink $f24AncestorLink $f24Real
        Test-BRAVOCondition -Condition (
            $f24.RootJunction -eq $true -and $f24.AncestorJunction -eq $true -and $f24.Plain -eq $false
        ) -Name 'Archive/501/F24RootOrAncestorJunctionIsNotTrusted' `
          -Failure "junction у корені синхронізації чи його предку має знімати довіру до CreationTime; root=$($f24.RootJunction) ancestor=$($f24.AncestorJunction) plain=$($f24.Plain)"
    } finally {
        foreach ($f24Link in @($f24RootLink, $f24AncestorLink)) {
            if ([IO.Directory]::Exists($f24Link)) { [IO.Directory]::Delete($f24Link) }
        }
    }

    # F25 (Codex, PR #503). Файл аудиту ДО, зниклий під час синхронізації без
    # версії у хмарі (F05), не рахується переданим: передано 1 з 2, і рядок
    # результату називає порушення знімка.
    $f25ResultLine = @($rf05.Log | Where-Object { $_.Message -like 'Результат BAZA_APP:*' })
    Test-BRAVOCondition -Condition (
        $rf05.App.BeforeCount -eq 2 -and $rf05.App.CompletedCount -eq 1 -and
        $rf05.App.SnapshotDriftViolationCount -eq 1 -and
        $f25ResultLine.Count -eq 1 -and
        $f25ResultLine[0].Message -like "*передано або оновлено сумісних об'єктiв: 1;*без підтвердженої версії у хмарі: 1"
    ) -Name 'Archive/501/F25VanishedPendingFileIsNotCountedAsTransferred' `
      -Failure "зниклий файл аудиту ДО не можна рахувати переданим; before=$($rf05.App.BeforeCount) completed=$($rf05.App.CompletedCount) drift=$($rf05.App.SnapshotDriftViolationCount) line=$(@($f25ResultLine | ForEach-Object { $_.Message }) -join ' | ')"

    # F26 (Codex, PR #503). Два файли чекали передачі: pending_1 передано, а
    # pending_2 перейменовано на renamed_2 після сканування WinSCP. Нове ім'я
    # є в пост-аудиті, а pending_2 — у порушеннях знімка, але це один об'єкт:
    # передано рівно 1, а не 0.
    $f26 = & $late501NewCase 'F26'
    $rf26 = & $late501Run -CaseRoot $f26.Root -Remote $f26.Remote -FailPaths @('KZ\2026\pending_2.pdf') -Ops @(& $late501Op 'Sync' 'Move' (Join-Path $f26.App 'KZ\2026\pending_2.pdf') -Target (Join-Path $f26.App 'KZ\2026\renamed_2.pdf'))
    Test-BRAVOCondition -Condition (
        $rf26.Label -eq 'ПОМИЛКА' -and $rf26.App.BeforeCount -eq 2 -and $rf26.App.CompletedCount -eq 1 -and
        $rf26.App.RealMissingCount -eq 1 -and $rf26.App.SnapshotDriftViolationCount -eq 1
    ) -Name 'Archive/501/F26RenamedPendingFileCountedOnce' `
      -Failure "перейменований файл аудиту ДО не може двічі зменшувати кількість переданих; label=$($rf26.Label) before=$($rf26.App.BeforeCount) completed=$($rf26.App.CompletedCount) real=$($rf26.App.RealMissingCount) drift=$($rf26.App.SnapshotDriftViolationCount)"

    # F27 (Codex, PR #503, P1). Знімок циклу не вдався, бо pending_2 зник під
    # час обходу. WinSCP і пост-аудит його вже не бачать (код 0, залишку
    # немає), але аудит ДО довів, що файл чекав передачі -> ПОМИЛКА.
    $f27 = & $late501NewCase 'F27'
    $rf27 = & $late501Run -CaseRoot $f27.Root -Remote $f27.Remote -SnapshotFails -Ops @(& $late501Op 'Snapshot' 'Delete' (Join-Path $f27.App 'KZ\2026\pending_2.pdf'))
    Test-BRAVOCondition -Condition (
        -not $rf27.Manual.Success -and $rf27.Label -eq 'ПОМИЛКА' -and $rf27.ExitCode -eq 50 -and
        -not $rf27.App.IsComplete -and -not $rf27.App.SnapshotConsistencyVerified -and
        $rf27.App.SnapshotUnavailableVanishedCount -eq 1 -and $rf27.App.CompletedCount -eq 1 -and
        @(& $late501Errors $rf27 | Where-Object { $_.Message -like '*BAZA_APP не підтверджено: знімок циклу не створено*pending_2.pdf*' }).Count -eq 1
    ) -Name 'Archive/501/F27SnapshotUnavailableVanishedPendingIsError' `
      -Failure "без знімка зниклий файл аудиту ДО не може дати УСПІШНО; label=$($rf27.Label) exit=$($rf27.ExitCode) verified=$($rf27.App.SnapshotConsistencyVerified) vanished=$($rf27.App.SnapshotUnavailableVanishedCount) completed=$($rf27.App.CompletedCount)"

    # F27b. Контроль: знімок не вдався, але все з аудиту ДО передано й лежить
    # локально -> УСПІШНО, як і до #501 (збій знімка сам не є аварією).
    $f27b = & $late501NewCase 'F27b'
    $rf27b = & $late501Run -CaseRoot $f27b.Root -Remote $f27b.Remote -SnapshotFails
    Test-BRAVOCondition -Condition (
        $rf27b.Manual.Success -and $rf27b.Label -eq 'УСПІШНО' -and $rf27b.ExitCode -eq 0 -and
        $rf27b.App.IsComplete -and $rf27b.App.SnapshotUnavailableVanishedCount -eq 0 -and $rf27b.App.CompletedCount -eq 2
    ) -Name 'Archive/501/F27bSnapshotUnavailableNothingVanishedIsSuccess' `
      -Failure "збій знімка без зниклих файлів аудиту ДО лишається УСПІШНО; label=$($rf27b.Label) exit=$($rf27b.ExitCode) completed=$($rf27b.App.CompletedCount)"

    # F28 (Codex, PR #503, P1). Знімок циклу УСПІШНИЙ, але pending_2 зник між
    # аудитом ДО і обходом знімка: у знімку його немає, пост-аудит порожній.
    # Звіряння знімка його не бачить, тож без окремої перевірки цикл був би
    # УСПІШНО попри втрачений файл -> ПОМИЛКА.
    $f28 = & $late501NewCase 'F28'
    $rf28 = & $late501Run -CaseRoot $f28.Root -Remote $f28.Remote -Ops @(& $late501Op 'BeforeAudit' 'Delete' (Join-Path $f28.App 'KZ\2026\pending_2.pdf'))
    Test-BRAVOCondition -Condition (
        -not $rf28.Manual.Success -and $rf28.Label -eq 'ПОМИЛКА' -and $rf28.ExitCode -eq 50 -and
        $rf28.App.SnapshotAvailable -and -not $rf28.App.IsComplete -and -not $rf28.App.SnapshotConsistencyVerified -and
        $rf28.App.SnapshotUnavailableVanishedCount -eq 1 -and $rf28.App.CompletedCount -eq 1 -and
        @(& $late501Errors $rf28 | Where-Object { $_.Message -like '*BAZA_APP не підтверджено: знімок циклу не містить об*pending_2.pdf*' }).Count -eq 1
    ) -Name 'Archive/501/F28SnapshotSucceededButMissingVanishedPendingIsError' `
      -Failure "успішний знімок без зниклого файлу аудиту ДО не може дати УСПІШНО; label=$($rf28.Label) exit=$($rf28.ExitCode) available=$($rf28.App.SnapshotAvailable) verified=$($rf28.App.SnapshotConsistencyVerified) vanished=$($rf28.App.SnapshotUnavailableVanishedCount) completed=$($rf28.App.CompletedCount)"

    # F28b. Контроль: pending_2 зник до знімка, але до старту WinSCP LIMS
    # відтворив його (є локально, у знімку немає) -> WinSCP передав його, залишку
    # немає, файл існує -> УСПІШНО, без хибної помилки.
    $f28b = & $late501NewCase 'F28b'
    $f28bPath = Join-Path $f28b.App 'KZ\2026\pending_2.pdf'
    $rf28b = & $late501Run -CaseRoot $f28b.Root -Remote $f28b.Remote -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f28bPath),
        (& $late501Op 'Snapshot' 'Write' $f28bPath -Size 200)
    )
    Test-BRAVOCondition -Condition (
        $rf28b.Manual.Success -and $rf28b.Label -eq 'УСПІШНО' -and $rf28b.ExitCode -eq 0 -and
        $rf28b.App.IsComplete -and $rf28b.App.SnapshotUnavailableVanishedCount -eq 0 -and $rf28b.App.CompletedCount -eq 2
    ) -Name 'Archive/501/F28bSnapshotMissingButPresentAndTransferredIsSuccess' `
      -Failure "файл аудиту ДО, якого немає у знімку, але який є локально і переданий, не є помилкою; label=$($rf28b.Label) exit=$($rf28b.ExitCode) vanished=$($rf28b.App.SnapshotUnavailableVanishedCount) completed=$($rf28b.App.CompletedCount)"

    # F29 (Codex, PR #503, P1). pending_2 замінено за тим самим шляхом ДО обходу
    # знімка: каталогом (F29) або меншим файлом (F29b). Шлях є у знімку,
    # але це не той об'єкт, що в аудиті ДО: оригінал не захоплено -> ПОМИЛКА,
    # переданим він не рахується. F29c — контроль: незмінений файл покритий.
    $f29 = & $late501NewCase 'F29'
    $f29Path = Join-Path $f29.App 'KZ\2026\pending_2.pdf'
    $rf29 = & $late501Run -CaseRoot $f29.Root -Remote $f29.Remote -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f29Path),
        (& $late501Op 'BeforeAudit' 'MkDir' $f29Path)
    )
    Test-BRAVOCondition -Condition (
        -not $rf29.Manual.Success -and $rf29.Label -eq 'ПОМИЛКА' -and $rf29.ExitCode -eq 50 -and
        $rf29.App.SnapshotAvailable -and -not $rf29.App.IsComplete -and
        $rf29.App.SnapshotUnavailableVanishedCount -eq 1 -and $rf29.App.CompletedCount -eq 1 -and
        @(& $late501Errors $rf29 | Where-Object { $_.Message -like '*BAZA_APP не підтверджено:*pending_2.pdf*' }).Count -eq 1
    ) -Name 'Archive/501/F29FileReplacedByDirectoryBeforeSnapshotIsError' `
      -Failure "файл аудиту ДО, замінений каталогом до знімка, не покритий знімком; label=$($rf29.Label) exit=$($rf29.ExitCode) vanished=$($rf29.App.SnapshotUnavailableVanishedCount) completed=$($rf29.App.CompletedCount)"

    $f29b = & $late501NewCase 'F29b'
    $f29bPath = Join-Path $f29b.App 'KZ\2026\pending_2.pdf'
    $rf29b = & $late501Run -CaseRoot $f29b.Root -Remote $f29b.Remote -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f29bPath),
        (& $late501Op 'BeforeAudit' 'Write' $f29bPath -Size 77)
    )
    Test-BRAVOCondition -Condition (
        -not $rf29b.Manual.Success -and $rf29b.Label -eq 'ПОМИЛКА' -and $rf29b.ExitCode -eq 50 -and
        -not $rf29b.App.IsComplete -and $rf29b.App.SnapshotUnavailableVanishedCount -eq 1 -and $rf29b.App.CompletedCount -eq 1
    ) -Name 'Archive/501/F29bFileReplacedBySmallerFileBeforeSnapshotIsError' `
      -Failure "файл аудиту ДО, замінений меншим файлом до знімка, не покритий знімком; label=$($rf29b.Label) exit=$($rf29b.ExitCode) vanished=$($rf29b.App.SnapshotUnavailableVanishedCount) completed=$($rf29b.App.CompletedCount)"

    $f29c = & $late501NewCase 'F29c'
    $f29cPath = Join-Path $f29c.App 'KZ\2026\pending_2.pdf'
    $rf29c = & $late501Run -CaseRoot $f29c.Root -Remote $f29c.Remote -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f29cPath),
        (& $late501Op 'BeforeAudit' 'Write' $f29cPath -Size 200)
    )
    Test-BRAVOCondition -Condition (
        $rf29c.Manual.Success -and $rf29c.Label -eq 'УСПІШНО' -and $rf29c.ExitCode -eq 0 -and
        $rf29c.App.IsComplete -and $rf29c.App.SnapshotUnavailableVanishedCount -eq 0 -and $rf29c.App.CompletedCount -eq 2
    ) -Name 'Archive/501/F29cSameKindAndSizeCoveredBySnapshotIsSuccess' `
      -Failure "об'єкт аудиту ДО того ж виду й розміру покритий знімком; label=$($rf29c.Label) exit=$($rf29c.ExitCode) vanished=$($rf29c.App.SnapshotUnavailableVanishedCount) completed=$($rf29c.App.CompletedCount)"

    # F29d. Контроль: файл аудиту ДО дописано (виріс 200 -> 300) до знімка — звичайна
    # динаміка append-only. Більшу версію знімка перевіряє звіряння знімка -> УСПІШНО.
    $f29d = & $late501NewCase 'F29d'
    $rf29d = & $late501Run -CaseRoot $f29d.Root -Remote $f29d.Remote -Ops @(& $late501Op 'BeforeAudit' 'Write' (Join-Path $f29d.App 'KZ\2026\pending_2.pdf') -Size 300)
    Test-BRAVOCondition -Condition (
        $rf29d.Manual.Success -and $rf29d.Label -eq 'УСПІШНО' -and $rf29d.ExitCode -eq 0 -and
        $rf29d.App.IsComplete -and $rf29d.App.SnapshotUnavailableVanishedCount -eq 0 -and $rf29d.App.CompletedCount -eq 2
    ) -Name 'Archive/501/F29dGrownFileBeforeSnapshotIsNotError' `
      -Failure "дописаний до знімка файл аудиту ДО не є помилкою; label=$($rf29d.Label) exit=$($rf29d.ExitCode) vanished=$($rf29d.App.SnapshotUnavailableVanishedCount) completed=$($rf29d.App.CompletedCount)"
    # F30 (Codex, PR #503, P1). pending_2 зник до знімка, WinSCP і пост-аудит його
    # не бачили, а LIMS відтворив його вже ПІСЛЯ пост-аудиту (стадія AfterCompare):
    # на диску він є, у знімку й залишку його немає, у хмарі його немає ->
    # передачу не доведено -> ПОМИЛКА, переданим не рахується.
    $f30 = & $late501NewCase 'F30'
    $f30Path = Join-Path $f30.App 'KZ\2026\pending_2.pdf'
    $rf30 = & $late501Run -CaseRoot $f30.Root -Remote $f30.Remote -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f30Path),
        (& $late501Op 'AfterCompare' 'Write' $f30Path -Size 200)
    )
    Test-BRAVOCondition -Condition (
        -not $rf30.Manual.Success -and $rf30.Label -eq 'ПОМИЛКА' -and $rf30.ExitCode -eq 50 -and
        $rf30.App.SnapshotAvailable -and -not $rf30.App.IsComplete -and -not $rf30.App.SnapshotConsistencyVerified -and
        $rf30.App.SnapshotUnavailableVanishedCount -eq 1 -and $rf30.App.CompletedCount -eq 1
    ) -Name 'Archive/501/F30SnapshotOmittedReappearedPendingIsError' `
      -Failure "файл аудиту ДО поза знімком, відтворений після пост-аудиту й відсутній у хмарі, не є переданим; label=$($rf30.Label) exit=$($rf30.ExitCode) verified=$($rf30.App.SnapshotConsistencyVerified) vanished=$($rf30.App.SnapshotUnavailableVanishedCount) completed=$($rf30.App.CompletedCount)"

    # F30b. Як F28b (відтворено до старту WinSCP, передано), але stat у хмарі для
    # цього шляху не вдався -> версію не доведено -> ПОМИЛКА.
    $f30b = & $late501NewCase 'F30b'
    $f30bPath = Join-Path $f30b.App 'KZ\2026\pending_2.pdf'
    $rf30b = & $late501Run -CaseRoot $f30b.Root -Remote $f30b.Remote -ProbeErrorPaths @('KZ\2026\pending_2.pdf') -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f30bPath),
        (& $late501Op 'Snapshot' 'Write' $f30bPath -Size 200)
    )
    Test-BRAVOCondition -Condition (
        -not $rf30b.Manual.Success -and $rf30b.Label -eq 'ПОМИЛКА' -and $rf30b.ExitCode -eq 50 -and
        -not $rf30b.App.IsComplete -and $rf30b.App.SnapshotUnavailableVanishedCount -eq 1 -and $rf30b.App.CompletedCount -eq 1
    ) -Name 'Archive/501/F30bSnapshotOmittedProbeErrorIsError' `
      -Failure "збій stat у хмарі для об'єкта поза знімком не дає доказу; label=$($rf30b.Label) exit=$($rf30b.ExitCode) vanished=$($rf30b.App.SnapshotUnavailableVanishedCount) completed=$($rf30b.App.CompletedCount)"

    # F30c. Те саме, але ліміт перевірки у хмарі 0 -> доказ не збирається -> ПОМИЛКА.
    $f30c = & $late501NewCase 'F30c'
    $f30cPath = Join-Path $f30c.App 'KZ\2026\pending_2.pdf'
    $rf30c = & $late501Run -CaseRoot $f30c.Root -Remote $f30c.Remote -ProbeCap 0 -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f30cPath),
        (& $late501Op 'Snapshot' 'Write' $f30cPath -Size 200)
    )
    Test-BRAVOCondition -Condition (
        -not $rf30c.Manual.Success -and $rf30c.Label -eq 'ПОМИЛКА' -and $rf30c.ExitCode -eq 50 -and
        -not $rf30c.App.IsComplete -and $rf30c.App.SnapshotUnavailableVanishedCount -eq 1 -and $rf30c.App.CompletedCount -eq 1
    ) -Name 'Archive/501/F30cSnapshotOmittedOverProbeLimitIsError' `
      -Failure "понад ліміт перевірки у хмарі об'єкт поза знімком лишається помилкою; label=$($rf30c.Label) exit=$($rf30c.ExitCode) vanished=$($rf30c.App.SnapshotUnavailableVanishedCount) completed=$($rf30c.App.CompletedCount)"

    # F31 (Codex, PR #503, P1). Знімок запитано, але не вдався; pending_2 зник ДО
    # WinSCP (і до пост-аудиту), а LIMS відтворив його ПІСЛЯ порівняння: на диску
    # він є, у залишку пост-аудиту й у хмарі його немає. Голе Exists не доводить
    # передачі -> не рахується переданим, ПОМИЛКА.
    $f31 = & $late501NewCase 'F31'
    $f31Path = Join-Path $f31.App 'KZ\2026\pending_2.pdf'
    $rf31 = & $late501Run -CaseRoot $f31.Root -Remote $f31.Remote -SnapshotFails -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f31Path),
        (& $late501Op 'AfterCompare' 'Write' $f31Path -Size 200)
    )
    Test-BRAVOCondition -Condition (
        -not $rf31.Manual.Success -and $rf31.Label -eq 'ПОМИЛКА' -and $rf31.ExitCode -eq 50 -and
        -not $rf31.App.IsComplete -and -not $rf31.App.SnapshotConsistencyVerified -and
        $rf31.App.SnapshotUnavailableVanishedCount -eq 1 -and $rf31.App.CompletedCount -eq 1 -and
        @(& $late501Errors $rf31 | Where-Object { $_.Message -like '*BAZA_APP не підтверджено: знімок циклу не створено*pending_2.pdf*' }).Count -eq 1
    ) -Name 'Archive/501/F31SnapshotFailedReappearedPendingWithoutCloudEvidenceIsError' `
      -Failure "без знімка відтворений після пост-аудиту файл аудиту ДО без версії у хмарі не є переданим; label=$($rf31.Label) exit=$($rf31.ExitCode) complete=$($rf31.App.IsComplete) vanished=$($rf31.App.SnapshotUnavailableVanishedCount) completed=$($rf31.App.CompletedCount)"

    # F31b. Контроль: знімок не вдався, pending_2 відтворено до старту WinSCP й
    # передано; повна проба в тій самій сесії підтверджує той самий розмір і час
    # -> передано, УСПІШНО.
    $f31b = & $late501NewCase 'F31b'
    $f31bPath = Join-Path $f31b.App 'KZ\2026\pending_2.pdf'
    $rf31b = & $late501Run -CaseRoot $f31b.Root -Remote $f31b.Remote -SnapshotFails -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f31bPath),
        (& $late501Op 'Snapshot' 'Write' $f31bPath -Size 200)
    )
    Test-BRAVOCondition -Condition (
        $rf31b.Manual.Success -and $rf31b.Label -eq 'УСПІШНО' -and $rf31b.ExitCode -eq 0 -and
        $rf31b.App.IsComplete -and $rf31b.App.SnapshotUnavailableVanishedCount -eq 0 -and $rf31b.App.CompletedCount -eq 2
    ) -Name 'Archive/501/F31bSnapshotFailedPendingConfirmedInCloudIsSuccess' `
      -Failure "без знімка файл аудиту ДО з підтвердженою у хмарі версією рахується переданим; label=$($rf31b.Label) exit=$($rf31b.ExitCode) vanished=$($rf31b.App.SnapshotUnavailableVanishedCount) completed=$($rf31b.App.CompletedCount)"

    # F31c. Те саме, але ліміт перевірки у хмарі 0 -> проба неповна -> ПОМИЛКА.
    $f31c = & $late501NewCase 'F31c'
    $f31cPath = Join-Path $f31c.App 'KZ\2026\pending_2.pdf'
    $rf31c = & $late501Run -CaseRoot $f31c.Root -Remote $f31c.Remote -SnapshotFails -ProbeCap 0 -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f31cPath),
        (& $late501Op 'Snapshot' 'Write' $f31cPath -Size 200)
    )
    Test-BRAVOCondition -Condition (
        -not $rf31c.Manual.Success -and $rf31c.Label -eq 'ПОМИЛКА' -and $rf31c.ExitCode -eq 50 -and
        -not $rf31c.App.IsComplete -and $rf31c.App.SnapshotUnavailableVanishedCount -eq 2 -and $rf31c.App.CompletedCount -eq 0 -and
        @(& $late501Errors $rf31c | Where-Object { $_.Message -like '*BAZA_APP не підтверджено: знімок циклу не створено*причина:*більше за ліміт перевірки 0*повторіть цикл*' }).Count -eq 1
    ) -Name 'Archive/501/F31cSnapshotFailedOverProbeLimitIsError' `
      -Failure "без знімка понад ліміт перевірки у хмарі лишається помилкою; label=$($rf31c.Label) exit=$($rf31c.ExitCode) vanished=$($rf31c.App.SnapshotUnavailableVanishedCount) completed=$($rf31c.App.CompletedCount)"

    # F31d. Те саме, але stat у хмарі для pending_2 не вдався -> версію не доведено.
    $f31d = & $late501NewCase 'F31d'
    $f31dPath = Join-Path $f31d.App 'KZ\2026\pending_2.pdf'
    $rf31d = & $late501Run -CaseRoot $f31d.Root -Remote $f31d.Remote -SnapshotFails -ProbeErrorPaths @('KZ\2026\pending_2.pdf') -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f31dPath),
        (& $late501Op 'Snapshot' 'Write' $f31dPath -Size 200)
    )
    Test-BRAVOCondition -Condition (
        -not $rf31d.Manual.Success -and $rf31d.Label -eq 'ПОМИЛКА' -and $rf31d.ExitCode -eq 50 -and
        -not $rf31d.App.IsComplete -and $rf31d.App.SnapshotUnavailableVanishedCount -eq 1 -and $rf31d.App.CompletedCount -eq 1 -and
        @(& $late501Errors $rf31d | Where-Object { $_.Message -like '*BAZA_APP не підтверджено: знімок циклу не створено*причина:*симульований збій stat*pending_2.pdf*' }).Count -eq 1
    ) -Name 'Archive/501/F31dSnapshotFailedProbeErrorIsError' `
      -Failure "без знімка збій stat у хмарі не дає доказу; label=$($rf31d.Label) exit=$($rf31d.ExitCode) vanished=$($rf31d.App.SnapshotUnavailableVanishedCount) completed=$($rf31d.App.CompletedCount)"

    # F31e. Контроль для каталогу: знімок не вдався, новий каталог аудиту ДО
    # передано, проба підтверджує той самий вид -> передано, УСПІШНО.
    $f31e = & $late501NewCase 'F31e'
    [void](New-Item -ItemType Directory -Path (Join-Path $f31e.App 'KZ\newdir') -Force)
    $rf31e = & $late501Run -CaseRoot $f31e.Root -Remote $f31e.Remote -SnapshotFails
    Test-BRAVOCondition -Condition (
        $rf31e.Manual.Success -and $rf31e.Label -eq 'УСПІШНО' -and $rf31e.App.IsComplete -and
        $rf31e.App.BeforeCount -eq 3 -and $rf31e.App.SnapshotUnavailableVanishedCount -eq 0 -and $rf31e.App.CompletedCount -eq 3
    ) -Name 'Archive/501/F31eSnapshotFailedDirectoryConfirmedInCloudIsSuccess' `
      -Failure "без знімка каталог аудиту ДО з підтвердженим у хмарі видом рахується переданим; label=$($rf31e.Label) before=$($rf31e.App.BeforeCount) vanished=$($rf31e.App.SnapshotUnavailableVanishedCount) completed=$($rf31e.App.CompletedCount)"

    # F31f. Каталог аудиту ДО зник до WinSCP і відтворений після пост-аудиту:
    # у хмарі його немає -> не передано, ПОМИЛКА.
    $f31f = & $late501NewCase 'F31f'
    $f31fDir = Join-Path $f31f.App 'KZ\newdir'
    [void](New-Item -ItemType Directory -Path $f31fDir -Force)
    $rf31f = & $late501Run -CaseRoot $f31f.Root -Remote $f31f.Remote -SnapshotFails -Ops @(
        (& $late501Op 'BeforeAudit' 'DeleteTree' $f31fDir),
        (& $late501Op 'AfterCompare' 'MkDir' $f31fDir)
    )
    Test-BRAVOCondition -Condition (
        -not $rf31f.Manual.Success -and $rf31f.Label -eq 'ПОМИЛКА' -and -not $rf31f.App.IsComplete -and
        $rf31f.App.SnapshotUnavailableVanishedCount -eq 1 -and $rf31f.App.CompletedCount -eq 2
    ) -Name 'Archive/501/F31fSnapshotFailedReappearedDirectoryWithoutCloudEvidenceIsError' `
      -Failure "без знімка відтворений каталог аудиту ДО без версії у хмарі не є переданим; label=$($rf31f.Label) vanished=$($rf31f.App.SnapshotUnavailableVanishedCount) completed=$($rf31f.App.CompletedCount)"

    # F32 (Codex, PR #503, P2). Доказ передачі об'єкта аудиту ДО — локальний stat,
    # знятий у пробі безпосередньо перед stat у хмарі, а не повторне читання диска
    # пізніше. Знімок не вдався; pending_2 (UploadUpdate: у хмарі стара версія) передано;
    # проба бачить у хмарі ту саму версію, а ПІСЛЯ проби LIMS дописує файл (F32a) або
    # видаляє його (F32b) -> передача була, це не ПОМИЛКА.
    $f32a = & $late501NewCase 'F32a'
    $f32aPath = Join-Path $f32a.App 'KZ\2026\pending_2.pdf'
    $f32a.Remote['/baza_app']['KZ\2026\pending_2.pdf'] = 150
    $rf32a = & $late501Run -CaseRoot $f32a.Root -Remote $f32a.Remote -SnapshotFails -Ops @(& $late501Op 'AfterProbe' 'Write' $f32aPath -Size 300)
    Test-BRAVOCondition -Condition (
        $rf32a.Manual.Success -and $rf32a.Label -eq 'УСПІШНО' -and $rf32a.ExitCode -eq 0 -and
        $rf32a.App.IsComplete -and $rf32a.App.SnapshotUnavailableVanishedCount -eq 0 -and $rf32a.App.CompletedCount -eq 2 -and
        @(& $late501Errors $rf32a).Count -eq 0
    ) -Name 'Archive/501/F32aSnapshotFailedTransferredThenAppendedAfterProbeIsNotError' `
      -Failure "файл аудиту ДО, переданий і дописаний ПІСЛЯ проби, не є помилкою; label=$($rf32a.Label) exit=$($rf32a.ExitCode) vanished=$($rf32a.App.SnapshotUnavailableVanishedCount) completed=$($rf32a.App.CompletedCount) errors=$((& $late501Errors $rf32a | ForEach-Object { $_.Message }) -join ' | ')"

    $f32b = & $late501NewCase 'F32b'
    $f32bPath = Join-Path $f32b.App 'KZ\2026\pending_2.pdf'
    $f32b.Remote['/baza_app']['KZ\2026\pending_2.pdf'] = 150
    $rf32b = & $late501Run -CaseRoot $f32b.Root -Remote $f32b.Remote -SnapshotFails -Ops @(& $late501Op 'AfterProbe' 'Delete' $f32bPath)
    Test-BRAVOCondition -Condition (
        $rf32b.Manual.Success -and $rf32b.Label -eq 'УСПІШНО' -and $rf32b.ExitCode -eq 0 -and
        $rf32b.App.IsComplete -and $rf32b.App.SnapshotUnavailableVanishedCount -eq 0 -and $rf32b.App.CompletedCount -eq 2 -and
        @(& $late501Errors $rf32b).Count -eq 0
    ) -Name 'Archive/501/F32bSnapshotFailedTransferredThenDeletedAfterProbeIsNotError' `
      -Failure "файл аудиту ДО, переданий і видалений ПІСЛЯ проби, не є помилкою; label=$($rf32b.Label) exit=$($rf32b.ExitCode) vanished=$($rf32b.App.SnapshotUnavailableVanishedCount) completed=$($rf32b.App.CompletedCount) errors=$((& $late501Errors $rf32b | ForEach-Object { $_.Message }) -join ' | ')"

    # F32c. Контроль fail-closed: те саме, але файл ЗМІНЕНО ДО проби (після
    # порівняння; локальний stat проби розходиться з хмарою) -> не доведено -> ПОМИЛКА.
    $f32c = & $late501NewCase 'F32c'
    $f32cPath = Join-Path $f32c.App 'KZ\2026\pending_2.pdf'
    $rf32c = & $late501Run -CaseRoot $f32c.Root -Remote $f32c.Remote -SnapshotFails -Ops @(& $late501Op 'AfterCompare' 'Write' $f32cPath -Size 300)
    Test-BRAVOCondition -Condition (
        -not $rf32c.Manual.Success -and $rf32c.Label -eq 'ПОМИЛКА' -and $rf32c.ExitCode -eq 50 -and
        $rf32c.App.SnapshotUnavailableVanishedCount -eq 1
    ) -Name 'Archive/501/F32cSnapshotFailedModifiedBeforeProbeStaysError' `
      -Failure "файл, змінений до проби (інша версія, ніж у хмарі), лишається помилкою; label=$($rf32c.Label) exit=$($rf32c.ExitCode) vanished=$($rf32c.App.SnapshotUnavailableVanishedCount)"

    # F32d. Змішана причина (знімок не вдався): pending_1 відтворено після порівняння
    # (у хмарі його немає), для pending_2 stat у хмарі не вдався. Помилку проби
    # віднесено лише до pending_2, суфікс про збій знімка є (знімок справді не вдався).
    $f32d = & $late501NewCase 'F32d'
    $f32d1 = Join-Path $f32d.App 'KZ\2026\pending_1.pdf'
    $f32d2 = Join-Path $f32d.App 'KZ\2026\pending_2.pdf'
    $rf32d = & $late501Run -CaseRoot $f32d.Root -Remote $f32d.Remote -SnapshotFails -ProbeErrorPaths @('KZ\2026\pending_2.pdf') -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f32d1),
        (& $late501Op 'AfterCompare' 'Write' $f32d1 -Size 200),
        (& $late501Op 'BeforeAudit' 'Delete' $f32d2),
        (& $late501Op 'Snapshot' 'Write' $f32d2 -Size 200)
    )
    $f32dErrors = @(& $late501Errors $rf32d | Where-Object { $_.Message -like '*BAZA_APP не підтверджено: знімок циклу не створено*' })
    Test-BRAVOCondition -Condition (
        -not $rf32d.Manual.Success -and $rf32d.ExitCode -eq 50 -and $rf32d.App.SnapshotUnavailableVanishedCount -eq 2 -and
        $rf32d.App.SnapshotProbeError -like '*не перевірено у хмарі: 1;*pending_2.pdf*' -and
        $rf32d.App.SnapshotProbeError -notlike '*pending_1.pdf*' -and
        $f32dErrors.Count -eq 1 -and $f32dErrors[0].Message -like '*(причина: не перевірено у хмарі: 1;*pending_2.pdf*)*усуньте причину збою знімка*'
    ) -Name 'Archive/501/F32dMixedCauseProbeErrorAttributedOnlyToStatFailedObject' `
      -Failure "помилка проби має стосуватися лише об'єкта зі збоєм stat; probeError=$($rf32d.App.SnapshotProbeError) msg=$(@($f32dErrors | ForEach-Object { $_.Message }) -join ' | ')"

    # F32e. УСПІШНИЙ знімок: pending_1 відтворено після порівняння (поза знімком, у
    # хмарі немає), synced_1 зник після знімка, а stat у хмарі для synced_1 не вдався.
    # Помилка проби стосується synced_1 (порушення знімка), а не pending_1: у причині
    # недоведеного об'єкта її немає; суфікса про збій знімка теж немає.
    $f32e = & $late501NewCase 'F32e'
    $f32e1 = Join-Path $f32e.App 'KZ\2026\pending_1.pdf'
    $rf32e = & $late501Run -CaseRoot $f32e.Root -Remote $f32e.Remote -ProbeErrorPaths @('KZ\2026\synced_1.pdf') -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f32e1),
        (& $late501Op 'AfterCompare' 'Write' $f32e1 -Size 200),
        (& $late501Op 'Sync' 'Delete' (Join-Path $f32e.App 'KZ\2026\synced_1.pdf'))
    )
    $f32eErrors = @(& $late501Errors $rf32e | Where-Object { $_.Message -like '*BAZA_APP не підтверджено:*' })
    Test-BRAVOCondition -Condition (
        -not $rf32e.Manual.Success -and $rf32e.App.SnapshotAvailable -and $rf32e.App.SnapshotUnavailableVanishedCount -eq 1 -and
        $null -eq $rf32e.App.SnapshotProbeError -and
        $f32eErrors.Count -eq 1 -and $f32eErrors[0].Message -notlike '*причина:*' -and $f32eErrors[0].Message -notlike '*збою знімка*'
    ) -Name 'Archive/501/F32eProbeErrorOfOtherObjectIsNotBlamedOnUnavailableObject' `
      -Failure "помилка stat іншого об'єкта не відноситься до недоведеного pending_1; probeError=$($rf32e.App.SnapshotProbeError) msg=$(@($f32eErrors | ForEach-Object { $_.Message }) -join ' | ')"

    # F32f. Успішний знімок + збій stat саме недоведеного об'єкта (F30b): причина є,
    # а "збою знімка" немає — знімок не падав.
    $f32fErrors = @(& $late501Errors $rf30b | Where-Object { $_.Message -like '*BAZA_APP не підтверджено:*' })
    Test-BRAVOCondition -Condition (
        $rf30b.App.SnapshotAvailable -and $f32fErrors.Count -eq 1 -and
        $f32fErrors[0].Message -like '*(причина: не перевірено у хмарі: 1;*pending_2.pdf*); повторіть цикл*' -and
        $f32fErrors[0].Message -notlike '*збою знімка*'
    ) -Name 'Archive/501/F32fSuccessfulSnapshotProbeErrorHasNoSnapshotFailureSuffix' `
      -Failure "за успішного знімка в помилці не має бути 'збою знімка'; msg=$(@($f32fErrors | ForEach-Object { $_.Message }) -join ' | ')"

    # F32g. Зберігання локального stat у записі проби і контракт Get-BAZASynchronizationOutcome:
    # без збережених локальних полів / LocalExists $false / розбіжність розміру -> не доведено;
    # повний запис -> доведено (диск не читається: шляхів на диску не існує).
    $f32g = & $late501Module {
        $root = 'C:\selftest-f32g\root'
        $time = New-Object DateTime 2026, 10, 20, 12, 30, 45, ([DateTimeKind]::Utc)
        $mk = {
            param([hashtable]$Local)
            $entry = [ordered]@{ Exists = $true; IsDirectory = $false; Size = 200; LastWriteTimeUtc = $time }
            foreach ($key in $Local.Keys) { $entry[$key] = $Local[$key] }
            $probe = [pscustomobject]@{ Complete = $true; Error = $null; Entries = @{ 'KZ\a.pdf' = [pscustomobject]$entry } }
            $before = [pscustomobject]@{ Success = $true; PendingFiles = @([pscustomobject]@{ Action = 'UploadUpdate'; Path = "$root\KZ\a.pdf"; IsDirectory = $false; SizeBytes = 200 }) }
            $after = [pscustomobject]@{ Success = $true; PendingFiles = @(); RemoteProbe = $probe }
            (Get-BAZASynchronizationOutcome -WinSCPExitCode 0 -ComparisonBefore $before -ComparisonAfter $after `
                -LocalSnapshot ([pscustomobject]@{ Success = $false; Error = 'selftest' }) -LocalRoot $root).SnapshotUnavailableVanishedCount
        }
        $stored = @{ LocalExists = $true; LocalIsDirectory = $false; LocalSize = 200; LocalLastWriteTimeUtc = $time.ToString('o') }
        [pscustomobject]@{
            Full = (& $mk $stored)
            NoFields = (& $mk @{})
            PartialFields = (& $mk @{ LocalExists = $true; LocalIsDirectory = $false })
            LocalMissing = (& $mk @{ LocalExists = $false; LocalIsDirectory = $false; LocalSize = $null; LocalLastWriteTimeUtc = $null })
            SizeMismatch = (& $mk @{ LocalExists = $true; LocalIsDirectory = $false; LocalSize = 300; LocalLastWriteTimeUtc = $time.ToString('o') })
            KindMismatch = (& $mk @{ LocalExists = $true; LocalIsDirectory = $true; LocalSize = $null; LocalLastWriteTimeUtc = $null })
        }
    }
    Test-BRAVOCondition -Condition (
        $f32g.Full -eq 0 -and $f32g.NoFields -eq 1 -and $f32g.PartialFields -eq 1 -and
        $f32g.LocalMissing -eq 1 -and $f32g.SizeMismatch -eq 1 -and $f32g.KindMismatch -eq 1
    ) -Name 'Archive/501/F32gPreAuditProofUsesOnlyStoredLocalStatAndFailsClosed' `
      -Failure "доказ лише зі збереженого локального stat: $($f32g | ConvertTo-Json -Compress)"

    # F28c/F31g/F31h (follow-up, P2). Об'єкт аудиту ДО, якого немає в успішному
    # (F28c) чи невдалому (F31g) знімку, замінено МЕНШИМ файлом після обходу
    # знімка; WinSCP його передав. Зменшення = заміна чи мутація, не передача
    # -> ПОМИЛКА (як F29b). F31h — контроль: дописаний (виріс) файл -> УСПІШНО.
    $f28c = & $late501NewCase 'F28c'
    $f28cPath = Join-Path $f28c.App 'KZ\2026\pending_2.pdf'
    $rf28c = & $late501Run -CaseRoot $f28c.Root -Remote $f28c.Remote -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f28cPath),
        (& $late501Op 'Snapshot' 'Write' $f28cPath -Size 77)
    )
    Test-BRAVOCondition -Condition (
        -not $rf28c.Manual.Success -and $rf28c.Label -eq 'ПОМИЛКА' -and $rf28c.ExitCode -eq 50 -and
        -not $rf28c.App.IsComplete -and $rf28c.App.SnapshotUnavailableVanishedCount -eq 1
    ) -Name 'Archive/501/F28cSnapshotOmittedObjectShrunkAfterWalkIsError' `
      -Failure "об'єкт аудиту ДО поза знімком, зменшений після обходу, не доведений переданим; label=$($rf28c.Label) exit=$($rf28c.ExitCode) vanished=$($rf28c.App.SnapshotUnavailableVanishedCount)"

    $f31g = & $late501NewCase 'F31g'
    $f31gPath = Join-Path $f31g.App 'KZ\2026\pending_2.pdf'
    $rf31g = & $late501Run -CaseRoot $f31g.Root -Remote $f31g.Remote -SnapshotFails -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f31gPath),
        (& $late501Op 'Snapshot' 'Write' $f31gPath -Size 77)
    )
    Test-BRAVOCondition -Condition (
        -not $rf31g.Manual.Success -and $rf31g.Label -eq 'ПОМИЛКА' -and $rf31g.ExitCode -eq 50 -and
        -not $rf31g.App.IsComplete -and $rf31g.App.SnapshotUnavailableVanishedCount -eq 1 -and $rf31g.App.CompletedCount -eq 1 -and
        @(& $late501Errors $rf31g | Where-Object { $_.Message -like '*знімок циклу не створено*' }).Count -ge 1
    ) -Name 'Archive/501/F31gSnapshotFailedPreAuditObjectShrunkIsError' `
      -Failure "без знімка зменшений відносно аудиту ДО файл не є переданим; label=$($rf31g.Label) exit=$($rf31g.ExitCode) complete=$($rf31g.App.IsComplete) vanished=$($rf31g.App.SnapshotUnavailableVanishedCount) completed=$($rf31g.App.CompletedCount)"

    $f31h = & $late501NewCase 'F31h'
    $f31hPath = Join-Path $f31h.App 'KZ\2026\pending_2.pdf'
    $rf31h = & $late501Run -CaseRoot $f31h.Root -Remote $f31h.Remote -SnapshotFails -Ops @(
        (& $late501Op 'BeforeAudit' 'Delete' $f31hPath),
        (& $late501Op 'Snapshot' 'Write' $f31hPath -Size 300)
    )
    Test-BRAVOCondition -Condition (
        $rf31h.Manual.Success -and $rf31h.Label -eq 'УСПІШНО' -and $rf31h.ExitCode -eq 0 -and
        $rf31h.App.IsComplete -and $rf31h.App.SnapshotUnavailableVanishedCount -eq 0 -and $rf31h.App.CompletedCount -eq 2
    ) -Name 'Archive/501/F31hSnapshotFailedPreAuditObjectGrownIsSuccess' `
      -Failure "без знімка дописаний відносно аудиту ДО файл, переданий і підтверджений у хмарі, не є помилкою; label=$($rf31h.Label) exit=$($rf31h.ExitCode) vanished=$($rf31h.App.SnapshotUnavailableVanishedCount) completed=$($rf31h.App.CompletedCount)"

    # F32h. Одиничний контракт: розмір аудиту ДО проти збереженого локального розміру проби.
    $f32h = & $late501Module {
        $root = 'C:\selftest-f32h\root'
        $time = New-Object DateTime 2026, 10, 20, 12, 30, 45, ([DateTimeKind]::Utc)
        $mk = {
            param($PreSize, [long]$LocalSize)
            $entry = [pscustomobject]@{
                Exists = $true; IsDirectory = $false; Size = $LocalSize; LastWriteTimeUtc = $time
                LocalExists = $true; LocalIsDirectory = $false; LocalSize = $LocalSize; LocalLastWriteTimeUtc = $time.ToString('o')
            }
            $probe = [pscustomobject]@{ Complete = $true; Error = $null; Entries = @{ 'KZ\a.pdf' = $entry } }
            $before = [pscustomobject]@{ Success = $true; PendingFiles = @([pscustomobject]@{ Action = 'UploadUpdate'; Path = "$root\KZ\a.pdf"; IsDirectory = $false; SizeBytes = $PreSize }) }
            $after = [pscustomobject]@{ Success = $true; PendingFiles = @(); RemoteProbe = $probe }
            (Get-BAZASynchronizationOutcome -WinSCPExitCode 0 -ComparisonBefore $before -ComparisonAfter $after `
                -LocalSnapshot ([pscustomobject]@{ Success = $false; Error = 'selftest' }) -LocalRoot $root).SnapshotUnavailableVanishedCount
        }
        [pscustomobject]@{ Shrunk = (& $mk 200 150); Grown = (& $mk 200 250); NoPreSize = (& $mk $null 150) }
    }
    Test-BRAVOCondition -Condition (
        $f32h.Shrunk -eq 1 -and $f32h.Grown -eq 0 -and $f32h.NoPreSize -eq 0
    ) -Name 'Archive/501/F32hPreAuditProofRejectsShrinkOnly' `
      -Failure "зменшення відносно аудиту ДО не доводить передачі, зростання/невідомий розмір доводить: $($f32h | ConvertTo-Json -Compress)"

    # B1-B4, D1-D2. Несумісне за іменем ('inc.pdf') не передається за дизайном:
    # залишок лишається degraded, зникнення — ПОМИЛКА, зміна під час циклу, поки
    # файл досі в залишку, — не drift-порушення; зникнення/заміна типу лишаються ПОМИЛКОЮ.
    $f501Inc = & $late501Module {
        $root = 'C:\selftest-incompat\root'
        $incPath = "$root\KZ\inc.pdf"
        $time = New-Object DateTime 2026, 10, 20, 12, 30, 45, ([DateTimeKind]::Utc)
        $issues = @([pscustomobject]@{ Path = $incPath; IsDirectory = $false })
        $incItem = { param([long]$Size) [pscustomobject]@{ Action = 'UploadUpdate'; Path = $incPath; IsDirectory = $false; SizeBytes = $Size } }
        $before = [pscustomobject]@{ Success = $true; PendingFiles = @(& $incItem 200) }
        $failedSnapshot = [pscustomobject]@{ Success = $false; Error = 'selftest' }
        $mkSnapshot = {
            param([bool]$WithInc)
            $entries = @{}
            if ($WithInc) { $entries['KZ\inc.pdf'] = [pscustomobject]@{ Size = 200; LastWriteTimeUtc = $time.ToString('o') } }
            $dirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            [void]$dirs.Add('KZ')
            [pscustomobject]@{ Success = $true; Entries = $entries; Directories = $dirs }
        }
        $noDrift = [pscustomobject]@{ Success = $true; TypeReplaced = @(); Vanished = @(); Modified = @() }
        $run = {
            param($Snapshot, $AfterPending, $Drift)
            $after = [pscustomobject]@{ Success = $true; PendingFiles = @($AfterPending); RemoteProbe = $null }
            if ($null -ne $Drift) { $after | Add-Member -NotePropertyName SnapshotDrift -NotePropertyValue $Drift }
            Get-BAZASynchronizationOutcome -WinSCPExitCode 0 -ComparisonBefore $before -ComparisonAfter $after `
                -IncompatibleIssues $issues -LocalSnapshot $Snapshot -LocalRoot $root
        }
        [pscustomobject]@{
            B1 = (& $run $failedSnapshot @() $null)
            B2 = (& $run $failedSnapshot @(& $incItem 200) $null)
            B3 = (& $run (& $mkSnapshot $false) @() $noDrift)
            B4 = (& $run (& $mkSnapshot $true) @(& $incItem 200) $noDrift)
            D1 = (& $run (& $mkSnapshot $true) @(& $incItem 260) ([pscustomobject]@{ Success = $true; TypeReplaced = @(); Vanished = @(); Modified = @([pscustomobject]@{ RelativePath = 'KZ\inc.pdf' }) }))
            D2 = (& $run (& $mkSnapshot $true) @(& $incItem 200) ([pscustomobject]@{ Success = $true; TypeReplaced = @(); Vanished = @([pscustomobject]@{ RelativePath = 'KZ\inc.pdf'; IsDirectory = $false }); Modified = @() }))
        }
    }
    Test-BRAVOCondition -Condition (
        $f501Inc.B1.SnapshotUnavailableVanishedCount -eq 1 -and -not $f501Inc.B1.IsComplete
    ) -Name 'Archive/501/B1FailedSnapshotVanishedIncompatibleIsError' `
      -Failure "зниклий несумісний об'єкт аудиту ДО (знімок не вдався) має бути помилкою; vanished=$($f501Inc.B1.SnapshotUnavailableVanishedCount) complete=$($f501Inc.B1.IsComplete)"
    Test-BRAVOCondition -Condition (
        $f501Inc.B2.SnapshotUnavailableVanishedCount -eq 0 -and $f501Inc.B2.IsDegraded -and $f501Inc.B2.IncompatibleRemainingCount -eq 1
    ) -Name 'Archive/501/B2FailedSnapshotStillPendingIncompatibleStaysDegraded' `
      -Failure "несумісний об'єкт, що досі в залишку, не зник; vanished=$($f501Inc.B2.SnapshotUnavailableVanishedCount) degraded=$($f501Inc.B2.IsDegraded)"
    Test-BRAVOCondition -Condition (
        $f501Inc.B3.SnapshotUnavailableVanishedCount -eq 1 -and -not $f501Inc.B3.IsComplete -and -not $f501Inc.B3.SnapshotConsistencyVerified
    ) -Name 'Archive/501/B3SuccessfulSnapshotOmittedVanishedIncompatibleIsError' `
      -Failure "несумісний об'єкт поза успішним знімком, якого немає в залишку, — помилка; vanished=$($f501Inc.B3.SnapshotUnavailableVanishedCount) complete=$($f501Inc.B3.IsComplete)"
    Test-BRAVOCondition -Condition (
        $f501Inc.B4.SnapshotUnavailableVanishedCount -eq 0 -and $f501Inc.B4.SnapshotDriftViolationCount -eq 0 -and
        $f501Inc.B4.IsComplete -and $f501Inc.B4.IsDegraded
    ) -Name 'Archive/501/B4SuccessfulSnapshotStillPendingIncompatibleStaysDegraded' `
      -Failure "незмінений несумісний об'єкт зі знімка лишається degraded; vanished=$($f501Inc.B4.SnapshotUnavailableVanishedCount) violations=$($f501Inc.B4.SnapshotDriftViolationCount) degraded=$($f501Inc.B4.IsDegraded)"
    Test-BRAVOCondition -Condition (
        $f501Inc.D1.ChangedDuringSyncCount -eq 0 -and $f501Inc.D1.SnapshotDriftViolationCount -eq 0 -and
        $f501Inc.D1.IsComplete -and $f501Inc.D1.IsDegraded
    ) -Name 'Archive/501/D1ModifiedStillPendingIncompatibleIsDegradedNotDrift' `
      -Failure "змінений під час циклу несумісний об'єкт, що досі в залишку, — degraded, не drift; changed=$($f501Inc.D1.ChangedDuringSyncCount) violations=$($f501Inc.D1.SnapshotDriftViolationCount) complete=$($f501Inc.D1.IsComplete)"
    Test-BRAVOCondition -Condition (
        $f501Inc.D2.SnapshotDriftViolationCount -eq 1 -and -not $f501Inc.D2.IsComplete -and
        @($f501Inc.D2.CycleClassification.ChangedDuringSync | Where-Object { $_.Action -eq 'LocalVanished' }).Count -eq 1
    ) -Name 'Archive/501/D2VanishedIncompatibleStaysError' `
      -Failure "зниклий під час циклу несумісний об'єкт лишається ПОМИЛКОЮ; violations=$($f501Inc.D2.SnapshotDriftViolationCount) complete=$($f501Inc.D2.IsComplete)"

    # 16. Моніторинг: рядок "[BAZA_APP] Результат: <СЛОВО>" (заголовок ЗАВЕРШЕННЯ
    # РУЧНОЇ СИНХРОНIЗАЦIЇ дає компонент BAZA_APP), regex \S+ і мапінг шаблону;
    # пріоритет агрегації ERROR > WARNING > SUCCESS; код 10 = severity WARNING.
    $late501HeaderComponent = & $late501Module { Resolve-BRAVOLogComponentFromHeader -Header '=== ЗАВЕРШЕННЯ РУЧНОЇ СИНХРОНIЗАЦIЇ BAZA_APP / BAZA_WWW ===' }
    # ЕМУЛЯЦІЯ зовнішнього контракту: шаблон Zabbix поза репозиторієм; мапінг нижче відтворює
    # описаний в issue #501 regex/мапінг, а production-код перевіряють мітки, компонент рядка і severity.
    $late501Zabbix = {
        param([string]$Line)
        $m = [regex]::Match($Line, '\[BAZA_APP\] Результат: (\S+)')
        if (-not $m.Success) { return $null }
        $v = $m.Groups[1].Value
        if ($v -like 'УСП*') { return 1 }
        if ($v -like '*ПОПЕРЕДЖ*' -or $v -like '*WARN*') { return 2 }
        return 0
    }
    $late501ZabbixValues = @{}
    foreach ($pair in @(@('S01', $r1), @('S02', $r2), @('S04', $r4), @('S11', $r11))) {
        $late501ZabbixValues[$pair[0]] = & $late501Zabbix "2026-10-20 16:18:11 [INFO] [$late501HeaderComponent] Результат: $($pair[1].Label)"
    }
    # 5.2.5 (адаптація S16): немає Get-BRAVOManualSyncRunOutcomeLabel /
    # Get-BRAVOExitCodeSeverity. Слово й код беруться з inline-виразів Main
    # (Get-Late501MainOutcome виконує їх з тексту рантайму); канонічна назва
    # коду 10 -- Get-BRAVOExitCodeName (SuccessWithWarnings).
    $late501ErrorAndWarning = (Get-Late501MainOutcome -ManualSyncResult ([pscustomobject]@{ Success = $false; Skipped = $false; NewAfterCutoffCount = 3; Results = $null })).Label
    $late501Severity = Get-BRAVOExitCodeName -Code $r2.ExitCode
    Test-BRAVOCondition -Condition (
        $late501HeaderComponent -eq 'BAZA_APP' -and
        $late501ZabbixValues['S01'] -eq 1 -and $late501ZabbixValues['S02'] -eq 2 -and
        $late501ZabbixValues['S04'] -eq 0 -and $late501ZabbixValues['S11'] -eq 2 -and
        ($r2.Label -notmatch '\s') -and $late501ErrorAndWarning -eq 'ПОМИЛКА' -and
        $r2.ExitCode -eq 10 -and [string]$late501Severity -eq 'SuccessWithWarnings' -and
        [regex]::Matches($archiveScriptText, '(?m)^\s*Write-Log\s+"Результат:\s*\$\(if \(-not \$manualSyncSuccess\)').Count -eq 1
    ) -Name 'Archive/501/S16MonitoringParsingSeverityAndStatus' `
      -Failure "Zabbix: УСПІШНО->1, ПОПЕРЕДЖЕННЯ->2, ПОМИЛКА->0, одне слово; ERROR переважає WARNING; код 10 -> SuccessWithWarnings; значення: $($late501ZabbixValues | ConvertTo-Json -Compress) severity=$late501Severity"

    # ------------------------------------------------------------
    # P525 (backport #501 на 5.2.5, нові кейси; регресійні, не TDD).
    # ------------------------------------------------------------
    # P525-a. Ручна синхронізація: файл, що з'явився під час успішного циклу,
    # ставить крок у Degraded/WARNING і повертає NewAfterCutoffCount > 0;
    # без пізніх файлів Degraded немає, лічильник 0.
    $p525a = $r2
    $p525aClean = $r1
    Test-BRAVOCondition -Condition (
        $p525a.Manual.Success -and $p525a.Manual.NewAfterCutoffCount -gt 0 -and
        $p525a.Manual.Results.BAZA_APP.Success -and $p525a.Manual.Results.BAZA_APP.Degraded -and
        $p525a.Manual.Results.BAZA_APP.Error -like "з'явилися під час синхронізації: 1 (буде передано наступним запуском)" -and
        $p525a.App.IsCompleteWithNewAfterCutoff -and
        @(& $late501Warnings $p525a | Where-Object { $_.Message -like "*з'явилися після старту синхронізації*late.pdf*" }).Count -eq 1 -and
        @(& $late501Errors $p525a).Count -eq 0 -and
        $p525aClean.Manual.Success -and $p525aClean.Manual.NewAfterCutoffCount -eq 0 -and
        -not $p525aClean.Manual.Results.BAZA_APP.Degraded -and $null -eq $p525aClean.Manual.Results.BAZA_APP.Error
    ) -Name 'Archive/501/P525-aManualSyncLateFilesDegradedWithCount' `
      -Failure "ручна синхронізація з пізнім файлом має давати Degraded/WARNING і NewAfterCutoffCount>0, без пізніх файлів -- 0/без Degraded; late: success=$($p525a.Manual.Success) count=$($p525a.Manual.NewAfterCutoffCount) degraded=$($p525a.Manual.Results.BAZA_APP.Degraded) error=$($p525a.Manual.Results.BAZA_APP.Error)"

    # P525-b. Нічний Main, гілка legacy BAZA_APP: блок присвоєння
    # Degraded/NewAfterCutoff/Error береться з AST справжнього Main і
    # виконується над реальними outcome-ами циклу (late -> $r2, чистий -> $r1);
    # без успіху синхронізації ($bazaAppSFTPSync = $false) блок не спрацьовує.
    $p525bMainAst = [Management.Automation.Language.Parser]::ParseInput($archiveScriptText, [ref]$null, [ref]$null)
    $p525bMain = $p525bMainAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Main' }, $true)
    $p525bIfs = @($p525bMain.FindAll({
        param($n)
        $n -is [Management.Automation.Language.IfStatementAst] -and
        $n.Clauses[0].Item1.Extent.Text -match '^\$bazaAppSFTPSync\s+-and\s+\$null\s+-ne\s+\$lateOutcomeProperty\s+-and' -and
        $n.Clauses[0].Item2.Extent.Text -like '*transferResults.BAZA_APP.NewAfterCutoff*'
    }, $true))
    $p525bIfStart = if ($p525bIfs.Count -ge 1) { [int]$p525bIfs[0].Extent.StartOffset } else { -1 }
    $p525bAssigns = @($p525bMain.FindAll({
        param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$lateOutcomeProperty' -and
        $n.Right.Extent.Text -like '*lastBAZASyncOutcome.PSObject.Properties*IsCompleteWithNewAfterCutoff*' -and
        $n.Extent.StartOffset -lt $p525bIfStart
    }, $true))
    $p525bAssign = $p525bAssigns | Sort-Object { $_.Extent.StartOffset } | Select-Object -Last 1
    $p525bFound = ($p525bIfs.Count -ge 1 -and $null -ne $p525bAssign)
    $p525bRun = {
        param($Outcome, [bool]$SyncOk)
        & $late501Module {
            param($Outcome, $SyncOk, $AssignText, $IfText)
            $script:lastBAZASyncOutcome = $Outcome
            $bazaAppSFTPSync = $SyncOk
            $transferResults = @{ BAZA_APP = New-BRAVOTransferOperationResult -Name 'SFTP: BAZA_APP' -Enabled $true }
            . ([scriptblock]::Create($AssignText + "`n" + $IfText))
            $transferResults.BAZA_APP
        } $Outcome $SyncOk $p525bAssign.Extent.Text $p525bIfs[0].Extent.Text
    }
    if ($p525bFound) {
        $p525bLate = & $p525bRun $r2.App $true
        $p525bClean = & $p525bRun $r1.App $true
        $p525bFailed = & $p525bRun $r2.App $false
    } else {
        $p525bLate = $p525bClean = $p525bFailed = $null
    }
    Test-BRAVOCondition -Condition (
        $p525bFound -and
        $p525bLate.Degraded -and $p525bLate.NewAfterCutoff -eq 1 -and
        $p525bLate.Error -like "з'явилися під час синхронізації: 1 (буде передано наступним запуском)" -and
        -not $p525bClean.Degraded -and $p525bClean.NewAfterCutoff -eq 0 -and $null -eq $p525bClean.Error -and
        -not $p525bFailed.Degraded -and $p525bFailed.NewAfterCutoff -eq 0
    ) -Name 'Archive/501/P525-bMainLegacyBazaAppBranchSetsDegradedNewAfterCutoff' `
      -Failure "гілка legacy BAZA_APP у Main має ставити Degraded/NewAfterCutoff/Error для пізніх файлів і не чіпати чистий/невдалий результат; знайдено блок: $p525bFound"

    # P525-c. -SyncBAZA: відображення результату на слово "Результат", код
    # завершення (0/10/50) і Result підсумку, з виразів справжнього Main.
    $p525cClean = Get-Late501MainOutcome -ManualSyncResult ([pscustomobject]@{ Success = $true; NewAfterCutoffCount = 0; Results = $null })
    $p525cWarn = Get-Late501MainOutcome -ManualSyncResult ([pscustomobject]@{ Success = $true; NewAfterCutoffCount = 2; Results = $null })
    $p525cFail = Get-Late501MainOutcome -ManualSyncResult ([pscustomobject]@{ Success = $false; NewAfterCutoffCount = 0; Results = $null })
    $p525cFailWithLate = Get-Late501MainOutcome -ManualSyncResult ([pscustomobject]@{ Success = $false; NewAfterCutoffCount = 2; Results = $null })
    # Допустимі значення -Result у Write-BRAVOSummary: статично з AST модуля
    # BRAVO.Console (без імпорту й побічних ефектів).
    $p525cConsoleAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'modules\BRAVO.Console\BRAVO.Console.psm1'), [ref]$null, [ref]$null)
    $p525cSummaryFunction = $p525cConsoleAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-BRAVOSummary' }, $true)
    $p525cResultParameter = @($p525cSummaryFunction.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Result' })[0]
    $p525cSummaryValidValues = @($p525cResultParameter.Attributes |
        Where-Object { $_.TypeName.Name -eq 'ValidateSet' } |
        ForEach-Object { $_.PositionalArguments | ForEach-Object { [string]$_.Value } })
    Test-BRAVOCondition -Condition (
        $p525cClean.ExitCode -eq 0 -and $p525cClean.Label -notmatch '\s' -and $p525cClean.Label -ceq ('УСП' + [char]0x0049 + 'ШНО') -and
        $p525cWarn.ExitCode -eq 10 -and $p525cWarn.ExitCode -eq (Resolve-BRAVOExitCode -HasWarnings) -and $p525cWarn.Label -eq 'ПОПЕРЕДЖЕННЯ' -and
        $p525cFail.ExitCode -eq 50 -and $p525cFail.ExitCode -eq (Resolve-BRAVOExitCode -SftpFailed) -and $p525cFail.Label -eq 'ПОМИЛКА' -and
        $p525cFailWithLate.ExitCode -eq 50 -and $p525cFailWithLate.Label -eq 'ПОМИЛКА' -and
        $p525cClean.SummaryResult -like 'УСП*' -and $p525cWarn.SummaryResult -eq 'ПОПЕРЕДЖЕННЯ' -and $p525cFail.SummaryResult -eq 'ПОМИЛКА' -and
        @($p525cClean.SummaryResult, $p525cWarn.SummaryResult, $p525cFail.SummaryResult | ForEach-Object { $p525cSummaryValidValues -contains $_ }) -notcontains $false
    ) -Name 'Archive/501/P525-cSyncBazaExitAndResultMapping' `
      -Failure "-SyncBAZA: чисто -> 0/УСПIШНО, пізні файли -> 10/ПОПЕРЕДЖЕННЯ, збій -> 50/ПОМИЛКА (навіть із пізніми); clean=$($p525cClean | ConvertTo-Json -Compress) warn=$($p525cWarn | ConvertTo-Json -Compress) fail=$($p525cFail | ConvertTo-Json -Compress) validSummary=$($p525cSummaryValidValues -join ',')"

    # P525-d. Конструктор результату передачі несе NewAfterCutoff = 0 за замовчуванням.
    $p525d = & $late501Module { New-BRAVOTransferOperationResult -Name 'SFTP: BAZA_APP' -Enabled $true }
    Test-BRAVOCondition -Condition (
        $null -ne $p525d.PSObject.Properties['NewAfterCutoff'] -and $p525d.NewAfterCutoff -eq 0 -and
        $p525d.NewAfterCutoff -is [int] -and -not $p525d.Degraded -and $p525d.IncompatibleNames -eq 0
    ) -Name 'Archive/501/P525-dTransferOperationResultDefaultsNewAfterCutoffZero' `
      -Failure "New-BRAVOTransferOperationResult має містити NewAfterCutoff = 0 (int) за замовчуванням; властивість: $(if ($null -ne $p525d.PSObject.Properties['NewAfterCutoff']) { $p525d.NewAfterCutoff } else { 'відсутня' })"

    # Структура: знімок береться до старту процесу WinSCP, класифікація — до запису пост-аудиту.
    $late501SyncText = & $late501Module { ${function:Sync-FolderToSFTP}.ToString() }
    Test-BRAVOCondition -Condition (
        $late501SyncText.IndexOf('Get-BRAVOBazaLocalSnapshot') -gt 0 -and
        $late501SyncText.IndexOf('Get-BRAVOBazaLocalSnapshot') -lt $late501SyncText.IndexOf('Start-BRAVOProcessOutputCapture') -and
        $late501SyncText.IndexOf('-LocalSnapshot $cycleSnapshot') -lt $late501SyncText.IndexOf('-Outcome $syncOutcome') -and
        # Follow-up: межа старту — після знімка й до старту WinSCP; пост-аудит отримує знімок.
        $late501SyncText.IndexOf('Get-BAZASyncStartBoundaryUtc') -gt $late501SyncText.IndexOf('Get-BRAVOBazaLocalSnapshot') -and
        $late501SyncText.IndexOf('Get-BAZASyncStartBoundaryUtc') -lt $late501SyncText.IndexOf('Start-BRAVOProcessOutputCapture') -and
        $late501SyncText.Contains('-LocalSnapshot $(if ($cycleSnapshot.Success) { $cycleSnapshot } else { $null })') -and
        @($r1.Log | Where-Object { $_.Message -like 'Знімок циклу BAZA_APP: CycleId=*; SyncStartUtc=*' }).Count -eq 1 -and
        # Нічний Main: Degraded без несумісних імен називає справжню причину (#501), а не "несумісних імен: 0".
        $archiveScriptText.Contains("об'єкти знімка синхронізовано; нові під час синхронізації буде передано наступним запуском") -and
        $archiveScriptText.Contains('WARNING (нові під час синхронізації — наступним запуском)')
    ) -Name 'Archive/501/SnapshotTakenBeforeWinSCPStart' `
      -Failure 'знімок циклу має братися до старту WinSCP і передаватися в класифікацію до запису пост-аудиту'
} finally {
    Remove-Item -LiteralPath $late501Root -Recurse -Force -ErrorAction SilentlyContinue
}
