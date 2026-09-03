[CmdletBinding()]
param(
    # Базовий коміт "ДО" (за замовчуванням — точка розгалуження PR C від
    # PR B, обчислена динамічно; НЕ хардкодиться, щоб скрипт не застарів,
    # якщо стек гілок зміниться). Приймає будь-який git-ref.
    [string]$BaseRef = 'feature/config-foundation-derivation',

    # Каталог комплекту "ПІСЛЯ" — за замовчуванням поточний working tree
    # (включно з незакомміченими змінами PR C) відносно розташування
    # цього скрипта.
    [string]$AfterRoot = (Split-Path -Path $PSScriptRoot -Parent)
)

<#
.SYNOPSIS
    P0 Configuration Foundation, Task #10: формальний characterization-тест
    паритету "config-present" сценарію ДО (PR B, merge-base) і ПІСЛЯ (PR C,
    включно з незакомміченим станом working tree) над ПОВНИМ effective
    graph (усі $global:*-змінні, які виставляє BRAVO_CONFIG_LOADER.ps1 +
    BRAVO.config), а не лише вибірковими полями.
.DESCRIPTION
    НЕ частина BRAVO_SELF_TEST.ps1 — той набір мусить лишатись git-
    незалежним (виконується і на розгорнутих у клієнта комплектах без
    .git). Цей скрипт — dev/CI-інструмент (той самий клас, що
    ci\Update-BRAVORuntimeManifest.ps1): запускається вручну під час
    рефакторингу конфігураційного пайплайна, не при кожному self-test.

    Методика:
      1. Ізольований git worktree за $BaseRef (не займає поточний working
         tree, не потребує commit/checkout).
      2. Два окремі ізольовані ConfigRoot-каталоги (BEFORE/AFTER), кожен —
         copy патченого BRAVO.config відповідної версії (LIMSRoot/
         BackupRoot підмінено на fixture-шляхи — без цього auto-discovery
         впаде на будь-якій машині без встановленого LIMS) + ІДЕНТИЧНИЙ
         BRAVO.local.config із широким набором overrides (schedulerSettings,
         notification, retention, SFTP/SMB, componentSettings/storage/
         bazaSync — усі домени, які Task #10 явно вимагав покрити).
      3. Дочірній процес Windows PowerShell для кожної версії: dot-source
         власного BRAVO_CONFIG_LOADER.ps1, Import-BravoConfiguration
         -PassThru, JSON-знімок повного набору $global:-змінних.
      4. Рекурсивний diff двох знімків із нормалізацією fixture-шляхів
         (сам корінь fixture різний за побудовою — це artifact методики
         тесту, не поведінки коду) і документованим allowlist для
         НАВМИСНИХ відмінностей (адитивні метадані Секцій 2-3, canonical-
         default фікс Секції 5 lunchArchiveCleanupPath).

    Будь-яка ІНША відмінність — регресія: скрипт завершується з exit 1 і
    повним переліком.
.EXAMPLE
    .\ci\Test-BRAVOConfigFoundationParity.ps1
    Порівнює merge-base (feature/config-foundation-derivation) з поточним
    working tree.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ===== Список $global:-імен, які захоплюємо (повний перелік, зібраний з
# BRAVO_CONFIG_LOADER.ps1 + BRAVO.config обох версій — grep
# '\$global:[A-Za-z_]+' по обох файлах) =====
$capturedNames = @(
    'BravoConfigurationMetadata', 'BravoLocalConfigOverrideState',
    'ScriptVersion', 'ScriptDate', 'ScriptBuildId',
    'archivePrefix', 'backupConsistency', 'backupMonitoring', 'bravoSettings',
    'componentSettings', 'credentialSettings', 'discoverySettings',
    'maintenanceSettings', 'pathSettings', 'restoreVerifySettings',
    'runtimeRoot', 'schedulerSettings', 'sftpDirectories', 'storageEffective',
    'toolIntegritySettings', 'LogLevel', 'archiveFileFilter', 'archiveParams',
    'archiveRetentionDays', 'archiveTimestampFormat', 'consoleSettings',
    'defaultLogLevel', 'durationFormat', 'elevationSettings',
    'enableArchiveDeletion', 'enableFailedArchiveDeletion',
    'enableLunchArchiveCleanup', 'enableOrphanTempCleanup',
    'failedArchiveRetentionDays', 'hashFileEncoding', 'hashFileExtension',
    'hashFileFilter', 'hostInformationSettings', 'logColors',
    'logFileDateFormat', 'logFileEncoding', 'logFileFilter',
    'logFileNameTemplate', 'logLevels', 'logRetentionDays',
    'logSeparatorLength', 'logTimestampFormat',
    'lunchArchiveCleanupDirectories', 'lunchArchiveCleanupPath',
    'lunchArchiveRetentionMonths', 'minimumRetainedVerifiedBackups',
    'operationLockSettings', 'orphanTempRetentionHours', 'progressSettings',
    'requireAdministrator', 'robocopyMaxSuccessExitCode', 'robocopyOptions',
    'robocopyPath', 'robocopyWindowStyle', 'sftpConnectionTimeoutSeconds',
    'sftpHostKey', 'sftpHostTemplate', 'sftpPort',
    'sftpSynchronizationOptions', 'smbSettings', 'synchronizationSafety',
    'winSCPIniPath', 'winSCPScriptEncoding', 'effectiveLimsRoot',
    'systemLogRoot', 'backupRootPath', 'archiveDefinitions', 'archiveDirs',
    'bazaAppPaths', 'bazaWWWPaths', 'sourcePaths', 'bazaSyncEffective'
)

# ===== Широкий BRAVO.local.config, що покриває всі домени з Task #10 =====
$localConfigLiteral = @'
@{
    'bravoSettings.NotificationProvider' = 'discord'
    'bravoSettings.NotificationMode' = 'errors_only'
    'bravoSettings.NotificationRequestTimeoutSeconds' = 45
    'bravoSettings.NotificationRouting.SUCCESS' = 'general'
    'bravoSettings.NotificationRouting.WARNING' = 'alerts'
    'bravoSettings.NotificationRouting.ERROR' = 'alerts'
    'bravoSettings.NotificationRouting.CRITICAL' = 'alerts'
    'maintenanceSettings.Retention.ArchiveDays' = 45
    'maintenanceSettings.Retention.LogDays' = 21
    'maintenanceSettings.Retention.CompressedLogDays' = 120
    'maintenanceSettings.Retention.CompressedLogDeletionEnabled' = $true
    'maintenanceSettings.Retention.FailedArchiveDays' = 10
    'maintenanceSettings.Limits.ExcludedDrives' = @('X:\', 'Y:\')
    'componentSettings.SFTP.Enabled' = $true
    'componentSettings.SFTP.ArchiveUpload' = $true
    'componentSettings.SMB.Enabled' = $true
    'componentSettings.SMB.ArchiveCopy' = $true
    'componentSettings.Synchronization.BAZA_APP_LOCAL' = $true
    'componentSettings.Synchronization.BAZA_APP_SFTP' = $true
    'componentSettings.Synchronization.BAZA_WWW_LOCAL' = $true
    'componentSettings.Synchronization.BAZA_WWW_SFTP' = $true
    'componentSettings.Archive.BLOG' = $true
    'componentSettings.Archive.BRAVOEXCH' = $true
    'componentSettings.Archive.MODEL' = $true
    'backupMonitoring.SFTP.Enabled' = $true
    'backupMonitoring.SFTP.CheckArchiveUploads' = $true
    'backupMonitoring.SFTP.CheckBAZASynchronization' = $true
    'backupMonitoring.SFTP.RemoteBackupMaxAgeHours' = 30
    'backupMonitoring.SFTP.OperationTimeoutSeconds' = 90
    'backupMonitoring.SFTP.SynchronizationTimeoutSeconds' = 60
    'backupMonitoring.SFTP.VerifyRemoteArchiveHash' = $true
    'backupMonitoring.SFTP.RequireServerSideArchiveHash' = $true
    'backupMonitoring.SFTP.BAZAPendingAlertAfterHours' = 12
    'backupMonitoring.SFTP.BAZA.Mode' = 'Full'
    'backupMonitoring.SFTP.BAZA.SynchronizeBeforeHealth' = $true
    'backupMonitoring.SFTP.BAZA.FastHealthEnabled' = $true
    'backupMonitoring.SFTP.BAZA.FullAuditEnabled' = $true
    'backupMonitoring.SFTP.BAZA.FullAuditEveryDays' = 3
    'backupMonitoring.SFTP.BAZA.AutoArchiveMutationThreshold' = 5
    'backupMonitoring.SMB.Enabled' = $true
    'backupMonitoring.SMB.RemoteBackupMaxAgeHours' = 30
    'backupMonitoring.NotifyOnSuccessAfterBackup' = $true
    'sftpHostTemplate' = 'sftp-parity-test.example.local'
    'sftpPort' = 2222
    'sftpConnectionTimeoutSeconds' = 45
    'smbSettings.RootPath' = '\\PARITY-TEST-NAS\BRAVO_BACKUP'
    'smbSettings.CopyBufferSizeMB' = 8
    'smbSettings.Directories.BLOG' = 'PARITY_BLOG'
    'smbSettings.Directories.BRAVOEXCH' = 'PARITY_EXCH'
    'smbSettings.Directories.MODEL' = 'PARITY_MODEL'
    'sftpDirectories.Blog' = 'parity_blog'
    'sftpDirectories.BravoExch' = 'parity_exch'
    'sftpDirectories.MODEL' = 'parity_model'
    'sftpDirectories.Manifest' = 'parity_manifest'
    'sftpDirectories.TraceLogs' = 'parity_trace'
    'sftpDirectories.ExchangeApiLogs' = 'parity_exchapi'
    'schedulerSettings.Backup.Enabled' = $true
    'schedulerSettings.Backup.DailyAt' = '23:15'
    'schedulerSettings.Backup.ExecutionTimeLimitHours' = 6
    'schedulerSettings.Maintenance.Enabled' = $true
    'schedulerSettings.Maintenance.DailyAt' = '04:30'
    'schedulerSettings.Health.Enabled' = $true
    'schedulerSettings.Health.StartAt' = '06:00'
    'schedulerSettings.Health.RepeatEveryMinutes' = 30
    'schedulerSettings.Health.BusyWaitMinutes' = 5
    'schedulerSettings.Health.SkipIfBackupTaskRunning' = $true
    'schedulerSettings.BAZASync.StartAt' = '01:00'
    'schedulerSettings.BAZASync.RepeatEveryHours' = 2
    'schedulerSettings.OperationLockWaitMinutes' = 15
    'schedulerSettings.StartWhenAvailable' = $true
    'schedulerSettings.WakeToRun' = $true
}
'@

# ===== Дочірній-процес шаблон: dot-source власного лоадера версії,
# Import-BravoConfiguration -PassThru, JSON-знімок =====
$captureChildTemplate = @'
param(
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$ConfigRoot,
    [Parameter(Mandatory = $true)][string]$OutputJsonPath,
    [Parameter(Mandatory = $true)][string]$ErrorJsonPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $RuntimeRoot 'BRAVO_CONFIG_LOADER.ps1')
    $null = Import-BravoConfiguration -ConfigRoot $ConfigRoot -RuntimeRoot $RuntimeRoot -PassThru
    $names = @(__CAPTURED_NAMES_LITERAL__)
    $snapshot = [ordered]@{}
    foreach ($name in $names) {
        $variable = Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
        $snapshot[$name] = if ($null -ne $variable) { $variable.Value } else { '<<ABSENT>>' }
    }
    $snapshot | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $OutputJsonPath -Encoding UTF8
} catch {
    [pscustomobject]@{ Message = $_.Exception.Message; ScriptStackTrace = $_.ScriptStackTrace } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ErrorJsonPath -Encoding UTF8
    exit 1
}
'@

function New-PatchedFixtureConfigRoot {
    param([Parameter(Mandatory = $true)][string]$SourceKitRoot, [Parameter(Mandatory = $true)][string]$DestConfigRoot)

    $limsRoot = Join-Path $DestConfigRoot 'FIXTURE_LIMS'
    $backupRoot = Join-Path $DestConfigRoot 'FIXTURE_BACKUP'
    New-Item -ItemType Directory -Path $limsRoot -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $backupRoot -Force -ErrorAction Stop | Out-Null

    $kitConfigText = Get-Content -LiteralPath (Join-Path $SourceKitRoot 'BRAVO.config') -Raw
    $limsLine = '    LIMSRoot      = ""'
    $backupLine = '    BackupRoot    = ""'
    if (-not $kitConfigText.Contains($limsLine) -or -not $kitConfigText.Contains($backupLine)) {
        throw "New-PatchedFixtureConfigRoot: очікувані рядки LIMSRoot/BackupRoot не знайдено в $SourceKitRoot\BRAVO.config"
    }
    $patched = $kitConfigText.
        Replace($limsLine, "    LIMSRoot      = '$($limsRoot.Replace("'", "''"))'").
        Replace($backupLine, "    BackupRoot    = '$($backupRoot.Replace("'", "''"))'")
    [IO.File]::WriteAllText((Join-Path $DestConfigRoot 'BRAVO.config'), $patched, (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $DestConfigRoot 'BRAVO.local.config'), $localConfigLiteral, (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{ LimsRoot = $limsRoot; BackupRoot = $backupRoot }
}

function Invoke-ParityCapture {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot, [Parameter(Mandatory = $true)][string]$ConfigRoot, [Parameter(Mandatory = $true)][string]$WorkDir)

    $childScriptPath = Join-Path $WorkDir 'CaptureChild.ps1'
    $namesLiteral = ($capturedNames | ForEach-Object { "'$_'" }) -join ', '
    $childScriptContent = $captureChildTemplate.Replace('__CAPTURED_NAMES_LITERAL__', $namesLiteral)
    [IO.File]::WriteAllText($childScriptPath, $childScriptContent, (New-Object System.Text.UTF8Encoding($false)))

    $outputJsonPath = Join-Path $WorkDir 'result.json'
    $errorJsonPath = Join-Path $WorkDir 'error.json'
    $stdoutPath = Join-Path $WorkDir 'stdout.log'
    $stderrPath = Join-Path $WorkDir 'stderr.log'

    $processArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $childScriptPath,
        '-RuntimeRoot', $RuntimeRoot, '-ConfigRoot', $ConfigRoot,
        '-OutputJsonPath', $outputJsonPath, '-ErrorJsonPath', $errorJsonPath)
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $processArgs -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    if ($process.ExitCode -ne 0 -or (Test-Path -LiteralPath $errorJsonPath -PathType Leaf)) {
        $errorDetail = if (Test-Path -LiteralPath $errorJsonPath -PathType Leaf) { Get-Content -LiteralPath $errorJsonPath -Raw } else { '' }
        $stderrText = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
        throw "Invoke-ParityCapture: дочірній процес завершився з помилкою (ExitCode=$($process.ExitCode)). $errorDetail $stderrText"
    }
    if (-not (Test-Path -LiteralPath $outputJsonPath -PathType Leaf)) {
        throw 'Invoke-ParityCapture: дочірній процес завершився без помилки, але результат відсутній.'
    }
    return (Get-Content -LiteralPath $outputJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-ParityNormalizedString {
    # Fixture-методика використовує ДВА окремі корені на сторону (RuntimeRoot
    # — worktree/AfterRoot; ConfigRoot — тимчасовий BEFORE/AFTER fixture-
    # каталог) — captured-поля походять то з одного, то з іншого (ScriptPath/
    # ManifestPath/HelperPath з RuntimeRoot; archiveDefinitions/archiveDirs/
    # pathSettings з ConfigRoot). Обидва мають бути нормалізовані, інакше
    # чисто methodology-артефакт (різні GUID-based temp-каталоги для двох
    # прогонів) хибно позначається як регресія.
    param([string]$Value, [string[]]$RootPrefixes)
    $normalized = $Value
    foreach ($prefix in $RootPrefixes) {
        if (-not [string]::IsNullOrEmpty($prefix)) {
            $normalized = $normalized.Replace($prefix, '<<ROOT>>')
            # archiveDefinitions/archiveDirs проходять через ConvertTo-Json
            # -Compress ЗНОВУ в цій функції (array-гілка Compare-ParitySnapshot)
            # -> зворотні слеші подвоюються ("C:\\Users\\...") у JSON-тексті,
            # а $RootPrefixes — сирі .NET-шляхи з одинарними слешами. Без
            # цієї другої заміни fixture-шлях у JSON-полях лишається
            # ненормалізованим і хибно виглядає регресією (реально
            # відтворено: archiveDefinitions.Destination).
            $normalized = $normalized.Replace($prefix.Replace('\', '\\'), '<<ROOT>>')
        }
    }
    return $normalized
}

function Compare-ParitySnapshot {
    param($Path, $Left, $Right, [System.Collections.Generic.List[string]]$Diffs, [string[]]$LeftRootPrefixes, [string[]]$RightRootPrefixes)

    $leftIsObj = $null -ne $Left -and $Left -is [System.Management.Automation.PSCustomObject]
    $rightIsObj = $null -ne $Right -and $Right -is [System.Management.Automation.PSCustomObject]
    if ($leftIsObj -or $rightIsObj) {
        $leftProps = if ($leftIsObj) { @($Left.PSObject.Properties.Name) } else { @() }
        $rightProps = if ($rightIsObj) { @($Right.PSObject.Properties.Name) } else { @() }
        foreach ($p in @($leftProps + $rightProps | Sort-Object -Unique)) {
            $lv = if ($leftIsObj -and $leftProps -contains $p) { $Left.$p } else { $null }
            $rv = if ($rightIsObj -and $rightProps -contains $p) { $Right.$p } else { $null }
            Compare-ParitySnapshot "$Path.$p" $lv $rv $Diffs $LeftRootPrefixes $RightRootPrefixes
        }
        return
    }
    $leftIsArr = $Left -is [array]
    $rightIsArr = $Right -is [array]
    if ($leftIsArr -or $rightIsArr) {
        # -InputObject (не pipe): порожній @() через pipe розгортається в
        # НУЛЬ об'єктів вхідного потоку -> ConvertTo-Json нічого не отримує
        # і повертає $null замість "[]" (P2-фікс, реально відтворено).
        $lJson = ConvertTo-Json -InputObject @($Left) -Depth 10 -Compress
        $rJson = ConvertTo-Json -InputObject @($Right) -Depth 10 -Compress
        $lNorm = Get-ParityNormalizedString -Value $lJson -RootPrefixes $LeftRootPrefixes
        $rNorm = Get-ParityNormalizedString -Value $rJson -RootPrefixes $RightRootPrefixes
        if ($lNorm -ne $rNorm) { $Diffs.Add("$Path : BEFORE=$lJson | AFTER=$rJson") }
        return
    }
    $lStr = if ($null -eq $Left) { '<null>' } else { [string]$Left }
    $rStr = if ($null -eq $Right) { '<null>' } else { [string]$Right }
    $lNorm = Get-ParityNormalizedString -Value $lStr -RootPrefixes $LeftRootPrefixes
    $rNorm = Get-ParityNormalizedString -Value $rStr -RootPrefixes $RightRootPrefixes
    if ($lNorm -ne $rNorm) { $Diffs.Add("$Path : BEFORE=$lStr | AFTER=$rStr") }
}

# ===== Відомі, задокументовані НАВМИСНІ відмінності (allowlist по
# root-шляху властивості) — усе інше є регресією =====
$knownIntentionalDiffPrefixes = @(
    # Адитивні поля метаданих (Секції 2-3): PR B їх узагалі не мав
    # (властивість відсутня -> $null), PR C додав як НОВІ, не змінивши
    # жодне вже наявне поле.
    'BravoConfigurationMetadata.AppliedLocalOverrideKeys',
    'BravoConfigurationMetadata.LocalConfigPath',
    'BravoConfigurationMetadata.LocalConfigPresent',
    'BravoConfigurationMetadata.Mode',
    'BravoConfigurationMetadata.PrimaryConfigPath',
    'BravoConfigurationMetadata.PrimaryConfigPresent',
    'BravoConfigurationMetadata.PrimaryConfigWasExplicit',
    # Час завантаження — очікувано різний між двома окремими прогонами.
    'BravoConfigurationMetadata.LoadedAt',
    # Секція 5, задокументований canonical-default фікс (перевірено
    # окремим self-test ConfigLoader/CommittedBravoConfigMatchesCanonicalDefaults):
    # "E:\Archiv" (застарілий placeholder BRAVO.config) -> "" (canonical).
    # Тут НЕ перекрито через local.config override (свідомо, щоб цей
    # шлях лишався видимим у diff і підтверджував саме цю, а не іншу,
    # причину).
    'lunchArchiveCleanupPath'
)

$worktreePath = $null
$beforeConfigRoot = $null
$afterConfigRoot = $null
$beforeWorkDir = $null
$afterWorkDir = $null
try {
    Write-Host "Base ref: $BaseRef" -ForegroundColor Cyan
    Write-Host "After root: $AfterRoot" -ForegroundColor Cyan

    # PowerShell 5.1: 2>&1 на нативному exe під $ErrorActionPreference='Stop'
    # обгортає КОЖЕН рядок stderr у термінуючий NativeCommandError, навіть
    # якщо exe завершився з ExitCode=0 (git worktree add сам по собі пише
    # прогрес-повідомлення в stderr) — тимчасово послаблюємо лише навколо
    # виклику, перевірка $LASTEXITCODE нижче лишається справжнім gate.
    $callEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $baseCommit = & git -C $AfterRoot rev-parse $BaseRef 2>&1
    $ErrorActionPreference = $callEap
    if ($LASTEXITCODE -ne 0) { throw "Не вдалося resolve base ref '$BaseRef': $baseCommit" }
    Write-Host "Base commit: $baseCommit" -ForegroundColor Cyan

    $tempRoot = [IO.Path]::GetTempPath()
    $worktreePath = Join-Path $tempRoot ('BRAVO_PARITY_WORKTREE_' + [guid]::NewGuid().ToString('N'))
    $beforeConfigRoot = Join-Path $tempRoot ('BRAVO_PARITY_BEFORE_' + [guid]::NewGuid().ToString('N'))
    $afterConfigRoot = Join-Path $tempRoot ('BRAVO_PARITY_AFTER_' + [guid]::NewGuid().ToString('N'))
    $beforeWorkDir = Join-Path $tempRoot ('BRAVO_PARITY_BEFORE_CHILD_' + [guid]::NewGuid().ToString('N'))
    $afterWorkDir = Join-Path $tempRoot ('BRAVO_PARITY_AFTER_CHILD_' + [guid]::NewGuid().ToString('N'))
    foreach ($d in @($beforeConfigRoot, $afterConfigRoot, $beforeWorkDir, $afterWorkDir)) {
        New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
    }

    $callEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $worktreeOutput = & git -C $AfterRoot worktree add --detach $worktreePath $baseCommit 2>&1
    $ErrorActionPreference = $callEap
    if ($LASTEXITCODE -ne 0) { throw "git worktree add провалився: $worktreeOutput" }

    $beforeFixture = New-PatchedFixtureConfigRoot -SourceKitRoot $worktreePath -DestConfigRoot $beforeConfigRoot
    $afterFixture = New-PatchedFixtureConfigRoot -SourceKitRoot $AfterRoot -DestConfigRoot $afterConfigRoot

    Write-Host "Захоплення BEFORE (base) знімку..." -ForegroundColor Cyan
    $beforeSnapshot = Invoke-ParityCapture -RuntimeRoot $worktreePath -ConfigRoot $beforeConfigRoot -WorkDir $beforeWorkDir
    Write-Host "Захоплення AFTER (поточний) знімку..." -ForegroundColor Cyan
    $afterSnapshot = Invoke-ParityCapture -RuntimeRoot $AfterRoot -ConfigRoot $afterConfigRoot -WorkDir $afterWorkDir

    $diffs = New-Object System.Collections.Generic.List[string]
    foreach ($name in $capturedNames) {
        Compare-ParitySnapshot $name $beforeSnapshot.$name $afterSnapshot.$name $diffs `
            @($beforeConfigRoot, $worktreePath) @($afterConfigRoot, $AfterRoot)
    }

    $unexpectedDiffs = @($diffs | Where-Object {
        $line = $_
        -not (@($knownIntentionalDiffPrefixes | Where-Object { $line.StartsWith($_) })).Count
    })

    Write-Host ""
    Write-Host "Усього відмінностей (сирих, до фільтра root-шляхів і allowlist): $($diffs.Count)" -ForegroundColor Cyan
    Write-Host "Неочікуваних (потенційна регресія): $($unexpectedDiffs.Count)" -ForegroundColor $(if ($unexpectedDiffs.Count -gt 0) { 'Red' } else { 'Green' })

    if ($unexpectedDiffs.Count -gt 0) {
        Write-Host ""
        Write-Host "РЕГРЕСІЯ: наступні поля effective graph відрізняються між BEFORE (PR B, $baseCommit) і AFTER без задокументованого обґрунтування:" -ForegroundColor Red
        $unexpectedDiffs | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        exit 1
    }

    Write-Host ""
    Write-Host "PASS: config-present сценарій паритетний між BEFORE (PR B, $baseCommit) і AFTER — усі відмінності або path-артефакти fixture-методики, або задокументовані навмисні зміни (адитивні метадані Секцій 2-3, canonical-default фікс Секції 5)." -ForegroundColor Green
    exit 0
} finally {
    if ($worktreePath -and (Test-Path -LiteralPath $worktreePath)) {
        $callEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & git -C $AfterRoot worktree remove --force $worktreePath 2>&1 | Out-Null
        $ErrorActionPreference = $callEap
    }
    foreach ($d in @($beforeConfigRoot, $afterConfigRoot, $beforeWorkDir, $afterWorkDir)) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
