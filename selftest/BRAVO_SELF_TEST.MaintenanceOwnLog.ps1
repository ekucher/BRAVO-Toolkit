# BRAVO_SELF_TEST.MaintenanceOwnLog.ps1 — R3-1/R3-3 (PR #136, третє коло
# review): гарантований, ідемпотентний epilogue вивантаження власного
# логу Maintenance (Invoke-BRAVOMaintenanceOwnLogUpload) + atomic snapshot
# для range_id_log.json.
#
# Увесь top-level скрипт-файл (BRAVO_MAINTENANCE.ps1 runtime) не
# запускається тут повністю (реальні служби/VSS/BAZA) — замість цього:
# (1) справжній функціональний тест Invoke-BRAVOMaintenanceOwnLogUpload у
# ізоляції (стаб SFTP-transport), включно з ідемпотентністю й snapshot-
# TOCTOU-безпекою; (2) структурні перевірки, що підтверджують РІВНО ДВА
# call site (щасливий шлях перед AutoShutdown + зовнішній finally) — той
# самий прийом, що BRAVO_SELF_TEST.Archive.ps1 використовує для
# Invoke-BRAVOArchiveOwnLogUpload.

Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop

$maintenanceOwnLogScriptPath = Join-Path $root 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'
$maintenanceOwnLogScriptText = [IO.File]::ReadAllText($maintenanceOwnLogScriptPath, [Text.Encoding]::UTF8)

# ============================================================
# Структурні перевірки (текстова інспекція production-джерела)
# ============================================================

$maintenanceOwnLogBareCallSites = @([regex]::Matches($maintenanceOwnLogScriptText, '(?m)^\s*Invoke-BRAVOMaintenanceOwnLogUpload\s*$'))
Test-BRAVOCondition ($maintenanceOwnLogBareCallSites.Count -eq 2) `
    'Maintenance/OwnLogUploadHasExactlyTwoCallSites' `
    "очікувано рівно 2 «голих» виклики Invoke-BRAVOMaintenanceOwnLogUpload (щасливий шлях + зовнішній finally); факт: $($maintenanceOwnLogBareCallSites.Count)"

# Call site №2 має бути МІЖ останнім "} finally {" файлу і фінальним
# Wait-BRAVOManualExit — тобто в ЗОВНІШНЬОМУ finally, що обгортає ввесь
# файл (а не у внутрішньому, що звільняє lock).
$maintenanceOwnLogLastFinallyIndex = $maintenanceOwnLogScriptText.LastIndexOf('} finally {')
$maintenanceOwnLogManualExitIndex = $maintenanceOwnLogScriptText.IndexOf('Wait-BRAVOManualExit', $maintenanceOwnLogLastFinallyIndex)
$maintenanceOwnLogSecondCallIndex = $maintenanceOwnLogScriptText.LastIndexOf('Invoke-BRAVOMaintenanceOwnLogUpload')
Test-BRAVOCondition (
    $maintenanceOwnLogLastFinallyIndex -ge 0 -and $maintenanceOwnLogManualExitIndex -gt $maintenanceOwnLogLastFinallyIndex -and
    $maintenanceOwnLogSecondCallIndex -gt $maintenanceOwnLogLastFinallyIndex -and $maintenanceOwnLogSecondCallIndex -lt $maintenanceOwnLogManualExitIndex
) -Name 'Maintenance/OwnLogUploadSecondCallSiteInOutermostFinallyBeforeManualExit' `
    -Failure "другий call site має бути в ЗОВНІШНЬОМУ finally, ПЕРЕД Wait-BRAVOManualExit"

# Call site №1 має передувати блоку AutoShutdown (зберігає P2-6 ordering:
# upload СТРОГО до shutdown на щасливому шляху).
$maintenanceOwnLogFirstCallIndex = $maintenanceOwnLogScriptText.IndexOf('Invoke-BRAVOMaintenanceOwnLogUpload')
$maintenanceOwnLogAutoShutdownIndex = $maintenanceOwnLogScriptText.IndexOf('ВИКЛИК ФУНКЦІЇ АВТОМАТИЧНОГО ВИМКНЕННЯ')
Test-BRAVOCondition (
    $maintenanceOwnLogFirstCallIndex -ge 0 -and $maintenanceOwnLogAutoShutdownIndex -gt $maintenanceOwnLogFirstCallIndex
) -Name 'Maintenance/OwnLogUploadFirstCallSitePrecedesAutoShutdown' `
    -Failure "перший call site (щасливий шлях) має передувати блоку AutoShutdown — зберігає вже закритий P2-6 ordering"

# Функція ніде не присвоює $script:maintenanceRuntimeExitCode — вивантаження
# власного логу НІКОЛИ не змінює первинний результат прогону.
$maintenanceOwnLogFunctionMatch = [regex]::Match($maintenanceOwnLogScriptText,
    '(?s)function Invoke-BRAVOMaintenanceOwnLogUpload \{.*?\n\}\r?\n')
Test-BRAVOCondition (
    $maintenanceOwnLogFunctionMatch.Success -and
    $maintenanceOwnLogFunctionMatch.Value -notmatch '\$script:maintenanceRuntimeExitCode\s*='
) -Name 'Maintenance/OwnLogUploadNeverAssignsRuntimeExitCode' `
    -Failure "Invoke-BRAVOMaintenanceOwnLogUpload не повинна ніде присвоювати `$script:maintenanceRuntimeExitCode"

# ============================================================
# Функціональні тести Invoke-BRAVOMaintenanceOwnLogUpload в ізоляції
# ============================================================

$maintenanceOwnLogStub = @'
function Write-Log { param([string]$Message,[string]$Level="INFO") }
function Get-BRAVOFileHash {
    param([string]$Path, [string]$Algorithm = "SHA512")
    if ($script:maintOwnLogTestState.MutateLiveFileAfterHash -and
        (Test-Path -LiteralPath $script:maintOwnLogTestState.MutateLiveFileAfterHash -PathType Leaf)) {
        [IO.File]::WriteAllText($script:maintOwnLogTestState.MutateLiveFileAfterHash, 'mutated-by-concurrent-service')
    }
    return BRAVO.Compatibility\Get-BRAVOFileHash -Path $Path -Algorithm $Algorithm
}
function Connect-BRAVOOwnLogSftpSession {
    $script:maintOwnLogTestState.ConnectCalls++
    if ($script:maintOwnLogTestState.ConnectShouldReturnNull) { return $null }
    if ($script:maintOwnLogTestState.ConnectShouldThrow) { throw "simulated connect failure" }
    return [pscustomobject]@{ IsFake = $true }
}
function Send-BRAVOOwnLogFile {
    param($Session, [string]$LocalLogPath, [string]$RemoteDirectory, [string]$RemoteFileName, $Logger)
    $script:maintOwnLogTestState.SendCalls++
    [void]$script:maintOwnLogTestState.SendCallPaths.Add($LocalLogPath)
    $content = if (Test-Path -LiteralPath $LocalLogPath -PathType Leaf) { [IO.File]::ReadAllText($LocalLogPath) } else { $null }
    [void]$script:maintOwnLogTestState.SendCallContents.Add($content)
    if ($script:maintOwnLogTestState.SendShouldThrow) { throw "simulated send failure" }
}
function Get-BRAVOSystemRangeIdLogPath {
    return $script:maintOwnLogTestState.RangeIdLogPath
}
function Test-BRAVOOwnLogSftpCredentialAvailable {
    return (-not $script:maintOwnLogTestState.CredentialsMissing)
}
function Sync-BRAVORuntimeLogsToSftp {
    param($Session, [string]$LocalLogRoot, [string]$RemoteDirectory)
    $script:maintOwnLogTestState.SyncCalls++
    $script:maintOwnLogTestState.SyncRemoteDirectory = $RemoteDirectory
    if ($script:maintOwnLogTestState.SyncShouldThrow) { throw "simulated sync failure" }
    return [pscustomobject]@{ Uploaded = 1; Unchanged = 0; Failed = 0; FirstError = $null }
}
'@
$maintenanceOwnLogFunctionNames = @("Write-Log", "Get-BRAVOFileHash", "Connect-BRAVOOwnLogSftpSession",
    "Send-BRAVOOwnLogFile", "Get-BRAVOSystemRangeIdLogPath", "Test-BRAVOOwnLogSftpCredentialAvailable",
    "Sync-BRAVORuntimeLogsToSftp", "Invoke-BRAVOMaintenanceOwnLogUpload")
$maintenanceOwnLogCombinedSource = $maintenanceOwnLogStub + "`n" + $maintenanceOwnLogScriptText
$maintenanceOwnLogModule = New-BRAVOSelfTestRuntimeModule -SourceText $maintenanceOwnLogCombinedSource -FunctionNames $maintenanceOwnLogFunctionNames

$maintenanceOwnLogTestRoot = Join-Path $env:TEMP "BRAVOSelfTest_MaintenanceOwnLog_$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $maintenanceOwnLogTestRoot -Force)
$maintenanceOwnLogFile = Join-Path $maintenanceOwnLogTestRoot 'run.log'
[IO.File]::WriteAllText($maintenanceOwnLogFile, 'maintenance log contents')

function Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario {
    param(
        [Parameter(Mandatory = $true)][object]$Module,
        [bool]$Enabled = $true,
        [bool]$SftpEnabled = $true,
        [bool]$DefineConfig = $true,
        [string]$LogFilePath,
        [string]$RangeIdLogPath = '',
        [string]$MutateLiveFileAfterHash = '',
        [bool]$ConnectShouldReturnNull = $false,
        [bool]$ConnectShouldThrow = $false,
        [bool]$SendShouldThrow = $false,
        [bool]$CredentialsMissing = $false,
        [bool]$SyncShouldThrow = $false,
        [int]$InvokeTimes = 1
    )
    & $Module {
        param($enabled, $sftpEnabled, $defineConfig, $logFilePath, $rangeIdLogPath,
            $mutateLiveFileAfterHash, $connectShouldReturnNull, $connectShouldThrow, $sendShouldThrow,
            $credentialsMissing, $syncShouldThrow, $invokeTimes)
        $script:maintOwnLogTestState = [pscustomobject]@{
            ConnectCalls             = 0
            SendCalls                = 0
            SyncCalls                = 0
            SyncRemoteDirectory      = $null
            CredentialsMissing       = $credentialsMissing
            SyncShouldThrow          = $syncShouldThrow
            SendCallPaths            = (New-Object System.Collections.Generic.List[string])
            SendCallContents         = (New-Object System.Collections.Generic.List[object])
            RangeIdLogPath           = $rangeIdLogPath
            MutateLiveFileAfterHash  = $mutateLiveFileAfterHash
            ConnectShouldReturnNull  = $connectShouldReturnNull
            ConnectShouldThrow       = $connectShouldThrow
            SendShouldThrow          = $sendShouldThrow
        }
        if ($defineConfig) {
            # Той самий Global-scope контракт, що Complete-BRAVOConfigurationLoad
            # реально використовує (R3-1 mirrors P1-fix для Archive).
            $global:componentSettings = [pscustomobject]@{ SFTP = [pscustomobject]@{ MaintenanceLogUploadEnabled = $enabled } }
            $global:storageEffective = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $sftpEnabled } }
            $script:sftpDirectories = [pscustomobject]@{ MaintenanceLog = 'logs/maintenance'; RuntimeLogs = 'logs/runtime' }
            # Global, як і в production (Complete-BRAVOConfigurationLoad);
            # наявне значення інших фрагментів не перезаписується — заглушка
            # Sync-BRAVORuntimeLogsToSftp каталог не читає.
            if (-not (Get-Variable -Name runtimeLogRoot -Scope Global -ErrorAction SilentlyContinue)) {
                $global:runtimeLogRoot = Split-Path -Path $logFilePath -Parent
            }
            $script:LOG_FILE = $logFilePath
            $script:maintenanceLogRunId = 'selftest_run_id'
        } else {
            Remove-Variable -Name componentSettings -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name storageEffective -Scope Global -ErrorAction SilentlyContinue
        }
        $script:maintenanceOwnLogUploadAttempted = $false
        for ($i = 0; $i -lt $invokeTimes; $i++) {
            Invoke-BRAVOMaintenanceOwnLogUpload
        }
        # ПРИМІТКА (PS 5.1): @(List[object]) кидає "Argument types do not
        # match" для System.Collections.Generic.List[object] (навіть
        # непорожнього) — відомий квирк унарного @()-оператора для
        # object-типізованих generic-колекцій під Windows PowerShell 5.1.
        # .ToArray() — безпечний канонічний спосіб розгортання тут.
        [pscustomobject]@{
            ConnectCalls     = $script:maintOwnLogTestState.ConnectCalls
            SendCalls        = $script:maintOwnLogTestState.SendCalls
            SyncCalls        = $script:maintOwnLogTestState.SyncCalls
            SyncRemoteDirectory = $script:maintOwnLogTestState.SyncRemoteDirectory
            SendCallPaths    = $script:maintOwnLogTestState.SendCallPaths.ToArray()
            SendCallContents = $script:maintOwnLogTestState.SendCallContents.ToArray()
        }
    } $Enabled $SftpEnabled $DefineConfig $LogFilePath $RangeIdLogPath `
        $MutateLiveFileAfterHash $ConnectShouldReturnNull $ConnectShouldThrow $SendShouldThrow `
        $CredentialsMissing $SyncShouldThrow $InvokeTimes
}

# (a) Тумблер окремої копії логу вимкнений (дефолт), SFTP увімкнено і
# креденшли є -> окрема копія не передається, але весь каталог журналів
# toolkit вивантажується (рішення власника 2026-10-01).
$maintOwnLogDisabled = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $false -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogDisabled.ConnectCalls -eq 1 -and $maintOwnLogDisabled.SendCalls -eq 0 -and
    $maintOwnLogDisabled.SyncCalls -eq 1 -and [string]$maintOwnLogDisabled.SyncRemoteDirectory -eq 'logs/runtime'
) -Name 'Maintenance/OwnLogToggleOffStillSyncsRuntimeLogs' `
    -Failure "MaintenanceLogUploadEnabled=`$false: окрема копія логу пропускається, але каталог журналів іде в sftpDirectories.RuntimeLogs; факт: connect=$($maintOwnLogDisabled.ConnectCalls) send=$($maintOwnLogDisabled.SendCalls) sync=$($maintOwnLogDisabled.SyncCalls) dir=$($maintOwnLogDisabled.SyncRemoteDirectory)"

# (a2) SFTP вимкнено глобально -> жодної мережевої спроби.
$maintOwnLogSftpOff = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $true -SftpEnabled $false -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogSftpOff.ConnectCalls -eq 0 -and $maintOwnLogSftpOff.SendCalls -eq 0 -and $maintOwnLogSftpOff.SyncCalls -eq 0
) -Name 'Maintenance/RuntimeLogUploadSkippedWhenSftpDisabled' `
    -Failure "storageSettings.SFTP.Enabled=`$false має пропускати будь-яке вивантаження; факт: connect=$($maintOwnLogSftpOff.ConnectCalls) send=$($maintOwnLogSftpOff.SendCalls) sync=$($maintOwnLogSftpOff.SyncCalls)"

# (a3) SFTP увімкнено, але креденшлів у Credential Manager немає ->
# вивантаження пропускається без спроби з'єднання.
$maintOwnLogNoCredentials = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $true -CredentialsMissing $true -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogNoCredentials.ConnectCalls -eq 0 -and $maintOwnLogNoCredentials.SendCalls -eq 0 -and $maintOwnLogNoCredentials.SyncCalls -eq 0
) -Name 'Maintenance/RuntimeLogUploadSkippedWithoutCredentials' `
    -Failure "без SFTP-креденшлів вивантаження має пропускатись без з'єднання; факт: connect=$($maintOwnLogNoCredentials.ConnectCalls) send=$($maintOwnLogNoCredentials.SendCalls) sync=$($maintOwnLogNoCredentials.SyncCalls)"

# (a4) Провал синхронізації каталогу журналів не пробивається назовні.
$maintOwnLogSyncFails = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $false -SyncShouldThrow $true -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogSyncFails.SyncCalls -eq 1
) -Name 'Maintenance/RuntimeLogSyncFailureCaughtNotPropagated' `
    -Failure "провал синхронізації журналів не повинен кидати виняток назовні; факт: sync=$($maintOwnLogSyncFails.SyncCalls)"

# (b) Увімкнено, БЕЗ range_id_log.json -> рівно 1 спроба (лише основний лог).
$maintOwnLogEnabledNoRangeId = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $true -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogEnabledNoRangeId.ConnectCalls -eq 1 -and $maintOwnLogEnabledNoRangeId.SendCalls -eq 1 -and
    $maintOwnLogEnabledNoRangeId.SyncCalls -eq 1
) -Name 'Maintenance/OwnLogUploadEnabledWithoutRangeIdMakesExactlyOneAttempt' `
    -Failure "увімкнено, без range_id_log.json -> рівно 1 передача (основний лог) і одна синхронізація журналів; факт: connect=$($maintOwnLogEnabledNoRangeId.ConnectCalls) send=$($maintOwnLogEnabledNoRangeId.SendCalls) sync=$($maintOwnLogEnabledNoRangeId.SyncCalls)"

# (c) Крах ДО завантаження конфігурації -> тихий no-op, БЕЗ винятку.
$maintOwnLogNoConfig = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -DefineConfig $false -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogNoConfig.ConnectCalls -eq 0 -and $maintOwnLogNoConfig.SendCalls -eq 0
) -Name 'Maintenance/OwnLogUploadMissingConfigIsSilentNoOpNotThrow' `
    -Failure "крах до завантаження конфігурації не повинен кидати виняток назовні"

# (d) Transport кидає виняток -> best-effort, не пробрасывает далі.
$maintOwnLogSendFails = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $true -SendShouldThrow $true -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogSendFails.SendCalls -eq 1 -and $maintOwnLogSendFails.SyncCalls -eq 1
) -Name 'Maintenance/OwnLogUploadTransportFailureCaughtNotPropagated' `
    -Failure "провал передачі не повинен кидати виняток назовні і не скасовує синхронізацію журналів; факт: send=$($maintOwnLogSendFails.SendCalls) sync=$($maintOwnLogSendFails.SyncCalls)"

# (e) R3-1: ідемпотентність — виклик функції ДВІЧІ в одному прогоні (симулює
# call site №1 + call site №2 на щасливому шляху) -> лише ОДНА реальна спроба.
$maintOwnLogIdempotent = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $true -LogFilePath $maintenanceOwnLogFile -InvokeTimes 2
Test-BRAVOCondition (
    $maintOwnLogIdempotent.ConnectCalls -eq 1 -and $maintOwnLogIdempotent.SendCalls -eq 1 -and
    $maintOwnLogIdempotent.SyncCalls -eq 1
) -Name 'Maintenance/OwnLogUploadIdempotentAcrossTwoCallSites' `
    -Failure "виклик двічі (call site №1 + №2) має дати РІВНО одну реальну спробу; факт: connect=$($maintOwnLogIdempotent.ConnectCalls) send=$($maintOwnLogIdempotent.SendCalls)"

# (f) R3-3: snapshot — range_id_log.json вивантажується ЗІ SNAPSHOT-шляху,
# НЕ з живого шляху, і знімок прибирається після завершення.
$maintOwnLogRangeIdFile = Join-Path $maintenanceOwnLogTestRoot 'range_id_log.json'
[IO.File]::WriteAllText($maintOwnLogRangeIdFile, 'original-range-id-content')
$maintOwnLogSnapshotResult = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule `
    -Enabled $true -LogFilePath $maintenanceOwnLogFile -RangeIdLogPath $maintOwnLogRangeIdFile
Test-BRAVOCondition (
    $maintOwnLogSnapshotResult.SendCalls -eq 2 -and
    $maintOwnLogSnapshotResult.SendCallPaths[1] -ne $maintOwnLogRangeIdFile -and
    -not (Test-Path -LiteralPath $maintOwnLogSnapshotResult.SendCallPaths[1])
) -Name 'Maintenance/OwnLogUploadRangeIdSnapshotUsesTemporaryCopyAndCleansUp' `
    -Failure "range_id_log.json має вивантажуватись ЗІ SNAPSHOT-шляху (не з живого), і знімок має бути прибраний після; факт: sendCalls=$($maintOwnLogSnapshotResult.SendCalls) snapshotPath=$($maintOwnLogSnapshotResult.SendCallPaths[1]) stillExists=$(Test-Path -LiteralPath $maintOwnLogSnapshotResult.SendCallPaths[1])"

# (g) R3-3 (найважливіший тест, буквальна вимога review): живий
# range_id_log.json МІНЯЄТЬСЯ між моментом снімку і фактичною передачею
# (симулює конкурентний запис служби BRAVO) -> вивантажений вміст
# лишається ОРИГІНАЛЬНИМ (снятим ДО мутації), а не пошкодженим/змішаним.
[IO.File]::WriteAllText($maintOwnLogRangeIdFile, 'original-range-id-content')
$maintOwnLogRaceResult = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule `
    -Enabled $true -LogFilePath $maintenanceOwnLogFile -RangeIdLogPath $maintOwnLogRangeIdFile `
    -MutateLiveFileAfterHash $maintOwnLogRangeIdFile
$maintOwnLogLiveContentAfter = [IO.File]::ReadAllText($maintOwnLogRangeIdFile)
Test-BRAVOCondition (
    $maintOwnLogRaceResult.SendCalls -eq 2 -and
    [string]$maintOwnLogRaceResult.SendCallContents[1] -eq 'original-range-id-content' -and
    $maintOwnLogLiveContentAfter -eq 'mutated-by-concurrent-service'
) -Name 'Maintenance/OwnLogUploadRangeIdSnapshotSurvivesConcurrentLiveFileMutation' `
    -Failure "живий файл змінився ПІСЛЯ снімку (симуляція служби BRAVO) — вивантажений вміст має лишитись ОРИГІНАЛЬНИМ (знятим до мутації); факт: sendCalls=$($maintOwnLogRaceResult.SendCalls) uploadedContent='$([string]$maintOwnLogRaceResult.SendCallContents[1])' liveContentAfter='$maintOwnLogLiveContentAfter'"

# ============================================================
# Sync-BRAVORuntimeLogsToSftp: весь <RuntimeRoot>\LOGS на SFTP
# (рішення власника 2026-10-01)
# ============================================================

$runtimeLogSyncStub = @'
function New-BRAVOBazaRemoteDirectoryRecursive {
    param($Session, [string]$RemoteDirectoryPath)
    [void]$script:runtimeLogSyncState.EnsuredDirectories.Add($RemoteDirectoryPath)
}
function Send-BRAVOTraceArchiveFile {
    param($Session, [string]$LocalPath, [string]$RemoteFinalPath, $Logger)
    [void]$script:runtimeLogSyncState.SentRemotePaths.Add($RemoteFinalPath)
    [void]$script:runtimeLogSyncState.SentLocalPaths.Add($LocalPath)
    [void]$script:runtimeLogSyncState.SentContents.Add([IO.File]::ReadAllText($LocalPath))
    if ($RemoteFinalPath -like '*fail*') {
        return [pscustomobject]@{ Success = $false; RemoteSize = $null; Error = 'simulated transfer failure' }
    }
    $script:runtimeLogSyncState.Remote[$RemoteFinalPath] = (Get-Item -LiteralPath $LocalPath).Length
    return [pscustomobject]@{ Success = $true; RemoteSize = (Get-Item -LiteralPath $LocalPath).Length; Error = $null }
}
'@
$runtimeLogSyncModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText ($runtimeLogSyncStub + "`n" + $maintenanceOwnLogScriptText) `
    -FunctionNames @('New-BRAVOBazaRemoteDirectoryRecursive', 'Send-BRAVOTraceArchiveFile', 'Sync-BRAVORuntimeLogsToSftp')

$runtimeLogSyncRoot = Join-Path $maintenanceOwnLogTestRoot 'LOGS'
[void](New-Item -ItemType Directory -Path (Join-Path $runtimeLogSyncRoot 'HELPERS') -Force)
[IO.File]::WriteAllText((Join-Path $runtimeLogSyncRoot 'BRAVO_ARCHIV_1.log'), 'archive-log')
[IO.File]::WriteAllText((Join-Path $runtimeLogSyncRoot 'BRAVO_HEALTH_1.log'), 'health-log-grown')
[IO.File]::WriteAllText((Join-Path $runtimeLogSyncRoot 'HELPERS\BRAVO_SETUP_1.log'), 'helper-log')
[IO.File]::WriteAllText((Join-Path $runtimeLogSyncRoot 'HELPERS\fail_1.log'), 'will-fail')

$runtimeLogSyncResult = & $runtimeLogSyncModule {
    param($localRoot)
    $script:runtimeLogSyncState = [pscustomobject]@{
        # BRAVO_ARCHIV_1.log уже на SFTP з тим самим розміром; лог Health
        # там коротший (локально дописаний) — має передатися знову.
        Remote             = @{ '/logs/runtime/BRAVO_ARCHIV_1.log' = [int64]11; '/logs/runtime/BRAVO_HEALTH_1.log' = [int64]5 }
        EnsuredDirectories = (New-Object System.Collections.Generic.List[string])
        SentRemotePaths    = (New-Object System.Collections.Generic.List[string])
        SentLocalPaths     = (New-Object System.Collections.Generic.List[string])
        SentContents       = (New-Object System.Collections.Generic.List[string])
    }
    $fakeSession = New-Object PSObject
    $fakeSession | Add-Member -MemberType ScriptMethod -Name FileExists -Value {
        param($path) return $script:runtimeLogSyncState.Remote.ContainsKey($path)
    }
    $fakeSession | Add-Member -MemberType ScriptMethod -Name GetFileInfo -Value {
        param($path) return [pscustomobject]@{ Length = $script:runtimeLogSyncState.Remote[$path] }
    }
    $summary = Sync-BRAVORuntimeLogsToSftp -Session $fakeSession -LocalLogRoot $localRoot -RemoteDirectory 'logs/runtime/'
    [pscustomobject]@{
        Summary            = $summary
        SentRemotePaths    = $script:runtimeLogSyncState.SentRemotePaths.ToArray()
        SentLocalPaths     = $script:runtimeLogSyncState.SentLocalPaths.ToArray()
        SentContents       = $script:runtimeLogSyncState.SentContents.ToArray()
        EnsuredDirectories = $script:runtimeLogSyncState.EnsuredDirectories.ToArray()
    }
} $runtimeLogSyncRoot

$runtimeLogSyncSentSorted = @($runtimeLogSyncResult.SentRemotePaths | Sort-Object)
Test-BRAVOCondition (
    $runtimeLogSyncResult.Summary.Uploaded -eq 2 -and
    $runtimeLogSyncResult.Summary.Unchanged -eq 1 -and
    $runtimeLogSyncResult.Summary.Failed -eq 1 -and
    [string]$runtimeLogSyncResult.Summary.FirstError -like 'HELPERS/fail_1.log*' -and
    $runtimeLogSyncSentSorted.Count -eq 3 -and
    $runtimeLogSyncSentSorted[0] -eq '/logs/runtime/BRAVO_HEALTH_1.log' -and
    $runtimeLogSyncSentSorted[1] -eq '/logs/runtime/HELPERS/BRAVO_SETUP_1.log' -and
    $runtimeLogSyncSentSorted[2] -eq '/logs/runtime/HELPERS/fail_1.log'
) -Name 'Maintenance/RuntimeLogSyncUploadsNewAndGrownFilesRecursively' `
    -Failure "очікувано: нові й дописані журнали (включно з HELPERS) передаються, незмінний пропускається, помилка одного файла рахується і не зупиняє решту; факт: uploaded=$($runtimeLogSyncResult.Summary.Uploaded) unchanged=$($runtimeLogSyncResult.Summary.Unchanged) failed=$($runtimeLogSyncResult.Summary.Failed) sent=$($runtimeLogSyncSentSorted -join ',')"

$runtimeLogSyncSnapshotsLeft = @($runtimeLogSyncResult.SentLocalPaths | Where-Object { Test-Path -LiteralPath $_ })
$runtimeLogSyncLiveSent = @($runtimeLogSyncResult.SentLocalPaths | Where-Object { $_ -like "$runtimeLogSyncRoot*" })
Test-BRAVOCondition (
    $runtimeLogSyncSnapshotsLeft.Count -eq 0 -and $runtimeLogSyncLiveSent.Count -eq 0 -and
    @($runtimeLogSyncResult.SentContents) -contains 'health-log-grown' -and
    @($runtimeLogSyncResult.EnsuredDirectories) -contains '/logs/runtime/HELPERS'
) -Name 'Maintenance/RuntimeLogSyncUsesSnapshotsAndCleansUp' `
    -Failure "кожен файл має передаватись через тимчасовий знімок (не живий шлях), знімки прибираються, remote-підкаталог створюється; факт: leftover=$($runtimeLogSyncSnapshotsLeft.Count) liveSent=$($runtimeLogSyncLiveSent.Count) dirs=$(@($runtimeLogSyncResult.EnsuredDirectories) -join ',')"

$runtimeLogSyncMissingRoot = & $runtimeLogSyncModule {
    param($missingRoot)
    Sync-BRAVORuntimeLogsToSftp -Session (New-Object PSObject) -LocalLogRoot $missingRoot -RemoteDirectory 'logs/runtime'
} (Join-Path $maintenanceOwnLogTestRoot 'NO_SUCH_LOGS')
Test-BRAVOCondition (
    $runtimeLogSyncMissingRoot.Uploaded -eq 0 -and $runtimeLogSyncMissingRoot.Failed -eq 0
) -Name 'Maintenance/RuntimeLogSyncMissingLocalRootIsNoOp' `
    -Failure "відсутній локальний каталог журналів — тихий no-op; факт: uploaded=$($runtimeLogSyncMissingRoot.Uploaded) failed=$($runtimeLogSyncMissingRoot.Failed)"

Remove-Item -LiteralPath $maintenanceOwnLogTestRoot -Recurse -Force -ErrorAction SilentlyContinue
