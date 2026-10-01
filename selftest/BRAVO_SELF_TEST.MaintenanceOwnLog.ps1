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
    param($Session, [string]$LocalLogPath, [string]$RemoteDirectory, [string]$RemoteFileName, $Logger, $KnownSecrets)
    $script:maintOwnLogTestState.SendCalls++
    $script:maintOwnLogTestState.SendKnownSecrets = @($KnownSecrets)
    [void]$script:maintOwnLogTestState.SendCallPaths.Add($LocalLogPath)
    $content = if (Test-Path -LiteralPath $LocalLogPath -PathType Leaf) { [IO.File]::ReadAllText($LocalLogPath) } else { $null }
    [void]$script:maintOwnLogTestState.SendCallContents.Add($content)
    if ($script:maintOwnLogTestState.SendShouldThrow) { throw "simulated send failure" }
}
function Get-BRAVOSystemRangeIdLogPath {
    return $script:maintOwnLogTestState.RangeIdLogPath
}
function Test-BRAVOOwnLogSftpCredentialAvailable {
    return (-not $script:maintOwnLogTestState.SftpLoginAbsent)
}
function Get-BRAVOOwnLogKnownSecrets {
    return @('seekrit-pass-1')
}
function Sync-BRAVORuntimeLogsToSftp {
    param($Session, [string]$LocalLogRoot, [string]$RemoteDirectory, $KnownSecrets)
    $script:maintOwnLogTestState.SyncCalls++
    $script:maintOwnLogTestState.SyncKnownSecrets = @($KnownSecrets)
    $script:maintOwnLogTestState.SyncRemoteDirectory = $RemoteDirectory
    if ($script:maintOwnLogTestState.SyncShouldThrow) { throw "simulated sync failure" }
    return [pscustomobject]@{ Uploaded = 1; Unchanged = 0; Failed = 0; FirstError = $null }
}
'@
$maintenanceOwnLogFunctionNames = @("Write-Log", "Get-BRAVOFileHash", "Connect-BRAVOOwnLogSftpSession",
    "Send-BRAVOOwnLogFile", "Get-BRAVOSystemRangeIdLogPath", "Test-BRAVOOwnLogSftpCredentialAvailable",
    "Sync-BRAVORuntimeLogsToSftp", "Get-BRAVOOwnLogKnownSecrets", "Get-BRAVORuntimeLogRemoteRoot", "Invoke-BRAVOMaintenanceOwnLogUpload")
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
        [bool]$SftpLoginAbsent = $false,
        [bool]$SyncShouldThrow = $false,
        [int]$InvokeTimes = 1,
        [string]$RuntimeLogsDirectory = 'logs/runtime'
    )
    & $Module {
        param($enabled, $sftpEnabled, $defineConfig, $logFilePath, $rangeIdLogPath,
            $mutateLiveFileAfterHash, $connectShouldReturnNull, $connectShouldThrow, $sendShouldThrow,
            $sftpLoginAbsent, $syncShouldThrow, $invokeTimes, $runtimeLogsDirectory)
        $script:maintOwnLogTestState = [pscustomobject]@{
            ConnectCalls             = 0
            SendCalls                = 0
            SyncCalls                = 0
            SyncRemoteDirectory      = $null
            SyncKnownSecrets         = @()
            SendKnownSecrets         = @()
            SftpLoginAbsent       = $sftpLoginAbsent
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
            $script:sftpDirectories = [pscustomobject]@{ MaintenanceLog = 'logs/maintenance'; RuntimeLogs = $runtimeLogsDirectory }
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
            SyncKnownSecrets = $script:maintOwnLogTestState.SyncKnownSecrets
            SendKnownSecrets = $script:maintOwnLogTestState.SendKnownSecrets
            SendCallPaths    = $script:maintOwnLogTestState.SendCallPaths.ToArray()
            SendCallContents = $script:maintOwnLogTestState.SendCallContents.ToArray()
        }
    } $Enabled $SftpEnabled $DefineConfig $LogFilePath $RangeIdLogPath `
        $MutateLiveFileAfterHash $ConnectShouldReturnNull $ConnectShouldThrow $SendShouldThrow `
        $SftpLoginAbsent $SyncShouldThrow $InvokeTimes $RuntimeLogsDirectory
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
    -Failure "componentSettings.SFTP.Enabled=`$false має пропускати будь-яке вивантаження; факт: connect=$($maintOwnLogSftpOff.ConnectCalls) send=$($maintOwnLogSftpOff.SendCalls) sync=$($maintOwnLogSftpOff.SyncCalls)"

# (a3) SFTP увімкнено, але креденшлів у Credential Manager немає ->
# вивантаження пропускається без спроби з'єднання.
$maintOwnLogNoCredentials = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $true -SftpLoginAbsent $true -LogFilePath $maintenanceOwnLogFile
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

# (e2) Небезпечний RuntimeLogs-корінь перевіряється ДО SFTP-логіну: з вимкненою
# окремою копією логу з'єднання не відкривається взагалі; з увімкненою — копія
# логу йде, а каталог журналів не синхронізується.
$maintOwnLogBadRootOff = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $false -LogFilePath $maintenanceOwnLogFile -RuntimeLogsDirectory '../escape'
Test-BRAVOCondition (
    $maintOwnLogBadRootOff.ConnectCalls -eq 0 -and $maintOwnLogBadRootOff.SendCalls -eq 0 -and $maintOwnLogBadRootOff.SyncCalls -eq 0
) -Name 'Maintenance/OwnLogBadRuntimeRootDoesNotConnect' `
    -Failure "небезпечний sftpDirectories.RuntimeLogs має відхилятись ДО SFTP-логіну (без з'єднання, коли копія логу вимкнена); факт: connect=$($maintOwnLogBadRootOff.ConnectCalls) send=$($maintOwnLogBadRootOff.SendCalls) sync=$($maintOwnLogBadRootOff.SyncCalls)"
$maintOwnLogBadRootOn = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $true -LogFilePath $maintenanceOwnLogFile -RuntimeLogsDirectory '..'
Test-BRAVOCondition (
    $maintOwnLogBadRootOn.ConnectCalls -eq 1 -and $maintOwnLogBadRootOn.SendCalls -eq 1 -and $maintOwnLogBadRootOn.SyncCalls -eq 0
) -Name 'Maintenance/OwnLogBadRuntimeRootStillUploadsRunLogOnly' `
    -Failure "небезпечний RuntimeLogs + увімкнена копія логу: з'єднання є, логу прогону передається, каталог журналів не синхронізується; факт: connect=$($maintOwnLogBadRootOn.ConnectCalls) send=$($maintOwnLogBadRootOn.SendCalls) sync=$($maintOwnLogBadRootOn.SyncCalls)"

# (e3) Відомі секрети (Credential Manager) передаються і в копію логу, і в синхронізацію.
Test-BRAVOCondition (
    @($maintOwnLogEnabledNoRangeId.SyncKnownSecrets) -contains 'seekrit-pass-1' -and
    @($maintOwnLogEnabledNoRangeId.SendKnownSecrets) -contains 'seekrit-pass-1'
) -Name 'Maintenance/OwnLogPassesKnownSecretsToUploads' `
    -Failure "відомі SFTP/SMB-секрети мають передаватись у Send-BRAVOOwnLogFile і Sync-BRAVORuntimeLogsToSftp; факт: sync=$(@($maintOwnLogEnabledNoRangeId.SyncKnownSecrets) -join ',') send=$(@($maintOwnLogEnabledNoRangeId.SendKnownSecrets) -join ',')"

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
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    [void]$script:runtimeLogSyncState.Warnings.Add("${Level}: $Message")
}
function New-BRAVOBazaRemoteDirectoryRecursive {
    param($Session, [string]$RemoteDirectoryPath)
    [void]$script:runtimeLogSyncState.EnsuredDirectories.Add($RemoteDirectoryPath)
}
function Get-BRAVOCredentialSecret {
    param([string]$Target)
    return $script:runtimeLogSecretStore[$Target]
}
function Send-BRAVOTraceArchiveFile {
    param($Session, [string]$LocalPath, [string]$RemoteFinalPath, $Logger)
    [void]$script:runtimeLogSyncState.SentRemotePaths.Add($RemoteFinalPath)
    [void]$script:runtimeLogSyncState.SentLocalPaths.Add($LocalPath)
    [void]$script:runtimeLogSyncState.SentContents.Add([IO.File]::ReadAllText($LocalPath))
    [void]$script:runtimeLogSyncState.SentHeads.Add((([IO.File]::ReadAllBytes($LocalPath) | Select-Object -First 3 | ForEach-Object { $_.ToString('X2') }) -join ''))
    if ($RemoteFinalPath -like '*fail*') {
        return [pscustomobject]@{ Success = $false; RemoteSize = $null; Error = 'simulated transfer failure' }
    }
    $script:runtimeLogSyncState.Remote[$RemoteFinalPath] = (Get-Item -LiteralPath $LocalPath).Length
    return [pscustomobject]@{ Success = $true; RemoteSize = (Get-Item -LiteralPath $LocalPath).Length; Error = $null }
}
'@
$runtimeLogSyncModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText ($runtimeLogSyncStub + "`n" + $maintenanceOwnLogScriptText + "`n" + [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Logging\BRAVO.Logging.psm1'), [Text.Encoding]::UTF8)) `
    -FunctionNames @('Write-Log', 'Protect-BRAVOLogSecret', 'New-BRAVOMaskedLogSnapshot', 'New-BRAVOBazaRemoteDirectoryRecursive', 'Send-BRAVOTraceArchiveFile', 'Sync-BRAVORuntimeLogsToSftp', 'Send-BRAVOOwnLogFile', 'Get-BRAVOOwnLogKnownSecrets', 'Get-BRAVORuntimeLogRemoteRoot', 'Get-BRAVOCredentialSecret')

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
        SentHeads          = (New-Object System.Collections.Generic.List[string])
        Warnings           = (New-Object System.Collections.Generic.List[string])
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

# ---- Безпека вивантаження (приймальний список власника PR #332) ----
function New-BRAVORuntimeLogSyncTestState {
    param([hashtable]$Remote = @{})
    [pscustomobject]@{
        Remote             = $Remote
        EnsuredDirectories = (New-Object System.Collections.Generic.List[string])
        SentRemotePaths    = (New-Object System.Collections.Generic.List[string])
        SentLocalPaths     = (New-Object System.Collections.Generic.List[string])
        SentContents       = (New-Object System.Collections.Generic.List[string])
        SentHeads          = (New-Object System.Collections.Generic.List[string])
        Warnings           = (New-Object System.Collections.Generic.List[string])
    }
}
$runtimeLogSyncRun = {
    param($localRoot, $remoteDirectory, $state)
    $script:runtimeLogSyncState = $state
    $fakeSession = New-Object PSObject
    $fakeSession | Add-Member -MemberType ScriptMethod -Name FileExists -Value {
        param($path) return $script:runtimeLogSyncState.Remote.ContainsKey($path)
    }
    $fakeSession | Add-Member -MemberType ScriptMethod -Name GetFileInfo -Value {
        param($path) return [pscustomobject]@{ Length = $script:runtimeLogSyncState.Remote[$path] }
    }
    Sync-BRAVORuntimeLogsToSftp -Session $fakeSession -LocalLogRoot $localRoot -RemoteDirectory $remoteDirectory
}

# 1) Секрет у сирому транскрипті HELPERS маскується у знімку; BOM/CRLF
# зберігаються; нетекстовий файл пропускається з WARNING; розмір на SFTP
# порівнюється із ЗАМАСКОВАНИМ знімком (другий прогін — «без змін»).
$runtimeLogSecRoot = Join-Path $maintenanceOwnLogTestRoot 'SECLOGS'
[void](New-Item -ItemType Directory -Path (Join-Path $runtimeLogSecRoot 'HELPERS') -Force)
$runtimeLogSecTranscript = "Transcript start`r`npassword=hunter2secret`r`nconnect sftp://svc:p4ssw0rdX@10.0.0.5/data`r`nTranscript end`r`n"
[IO.File]::WriteAllText((Join-Path $runtimeLogSecRoot 'HELPERS\transcript_1.log'), $runtimeLogSecTranscript, (New-Object Text.UTF8Encoding($true)))
[IO.File]::WriteAllBytes((Join-Path $runtimeLogSecRoot 'HELPERS\binary_1.log'), [byte[]](0x41, 0x00, 0x42, 0x00, 0x01, 0x02))
$runtimeLogSecState = New-BRAVORuntimeLogSyncTestState
$runtimeLogSecFirst = & $runtimeLogSyncModule $runtimeLogSyncRun $runtimeLogSecRoot 'logs/runtime' $runtimeLogSecState
$runtimeLogSecSentText = (@($runtimeLogSecState.SentContents) -join "`n")
$runtimeLogSecBinaryWarnings = @($runtimeLogSecState.Warnings | Where-Object { $_ -like 'WARNING:*binary_1.log*' }).Count
$runtimeLogSecSecond = & $runtimeLogSyncModule $runtimeLogSyncRun $runtimeLogSecRoot 'logs/runtime' $runtimeLogSecState
Test-BRAVOCondition (
    $runtimeLogSecFirst.Uploaded -eq 1 -and $runtimeLogSecFirst.Skipped -eq 1 -and
    $runtimeLogSecSentText -notmatch 'hunter2secret' -and $runtimeLogSecSentText -notmatch 'p4ssw0rdX' -and
    $runtimeLogSecSentText -match 'password=\*\*\*' -and $runtimeLogSecSentText -match 'svc:\*\*\*@10\.0\.0\.5' -and
    $runtimeLogSecSentText -match "Transcript end`r`n" -and
    @($runtimeLogSecState.SentHeads)[0] -eq 'EFBBBF' -and
    @($runtimeLogSecState.SentRemotePaths) -notcontains '/logs/runtime/HELPERS/binary_1.log' -and
    $runtimeLogSecBinaryWarnings -eq 1 -and
    $runtimeLogSecSecond.Uploaded -eq 0 -and $runtimeLogSecSecond.Unchanged -eq 1
) -Name 'Maintenance/RuntimeLogSyncMasksSecretsInHelperTranscripts' `
    -Failure "секрети в сирому транскрипті мають маскуватись у знімку (BOM/CRLF збережено), нетекстовий файл — пропуск із WARNING, повторний прогін — без змін за розміром замаскованого знімка; факт: uploaded=$($runtimeLogSecFirst.Uploaded) skipped=$($runtimeLogSecFirst.Skipped) second=$($runtimeLogSecSecond.Uploaded)/$($runtimeLogSecSecond.Unchanged) head=$(@($runtimeLogSecState.SentHeads) -join ',') sent='$runtimeLogSecSentText' warnings=$(@($runtimeLogSecState.Warnings) -join ' | ')"

# 2) Reparse point (junction/symlink: каталог і файл) не відкривається;
# вміст поза LOGS не вивантажується. Фікстура потребує створення посилань
# (Linux: symlink; Windows: symlink або junction) — якщо це неможливо,
# тест явно позначається як пропущений.
$runtimeLogLinkRoot = Join-Path $maintenanceOwnLogTestRoot 'LINKLOGS'
$runtimeLogLinkOutside = Join-Path $maintenanceOwnLogTestRoot 'OUTSIDE'
[void](New-Item -ItemType Directory -Path $runtimeLogLinkRoot -Force)
[void](New-Item -ItemType Directory -Path $runtimeLogLinkOutside -Force)
[IO.File]::WriteAllText((Join-Path $runtimeLogLinkRoot 'real_1.log'), 'real-log')
[IO.File]::WriteAllText((Join-Path $runtimeLogLinkOutside 'outside_secret_1.log'), 'OUTSIDE-SECRET-CONTENT')
$runtimeLogLinkDir = Join-Path $runtimeLogLinkRoot 'LINKDIR'
$runtimeLogLinkFile = Join-Path $runtimeLogLinkRoot 'linkfile_1.log'
$runtimeLogLinkFixtureNote = ''
$runtimeLogLinkDirCreated = $false
$runtimeLogLinkFileCreated = $false
try { [void](New-Item -ItemType SymbolicLink -Path $runtimeLogLinkDir -Target $runtimeLogLinkOutside -ErrorAction Stop) } catch { $runtimeLogLinkFixtureNote = $_.Exception.Message }
if (-not (Test-Path -LiteralPath $runtimeLogLinkDir)) {
    try { [void](New-Item -ItemType Junction -Path $runtimeLogLinkDir -Target $runtimeLogLinkOutside -ErrorAction Stop) } catch { $runtimeLogLinkFixtureNote = $_.Exception.Message }
}
if (-not (Test-Path -LiteralPath $runtimeLogLinkDir) -and $env:OS -eq 'Windows_NT') {
    # Directory junction не потребує прав адміністратора.
    $runtimeLogLinkFixtureNote = (& cmd.exe /c mklink /J "`"$runtimeLogLinkDir`"" "`"$runtimeLogLinkOutside`"" 2>&1 | Out-String)
}
$runtimeLogLinkDirCreated = (Test-Path -LiteralPath $runtimeLogLinkDir)
try { [void](New-Item -ItemType SymbolicLink -Path $runtimeLogLinkFile -Target (Join-Path $runtimeLogLinkOutside 'outside_secret_1.log') -ErrorAction Stop) } catch { $runtimeLogLinkFixtureNote = $_.Exception.Message }
$runtimeLogLinkFileCreated = (Test-Path -LiteralPath $runtimeLogLinkFile)
if (-not $runtimeLogLinkDirCreated) {
    # На Windows junction створюється завжди — тоді відсутність посилання
    # є ПОМИЛКОЮ тесту, а не пропуском; пропуск лише на не-Windows хості.
    Test-BRAVOCondition ($env:OS -ne 'Windows_NT') -Name 'Maintenance/RuntimeLogSyncSkipsReparsePoints' `
        -Failure "SKIPPED/FAIL: не вдалося створити symlink/junction у цьому середовищі: $runtimeLogLinkFixtureNote"
} else {
    $runtimeLogLinkState = New-BRAVORuntimeLogSyncTestState
    $runtimeLogLinkSummary = & $runtimeLogSyncModule $runtimeLogSyncRun $runtimeLogLinkRoot 'logs/runtime' $runtimeLogLinkState
    $runtimeLogLinkExpectedSkipped = 1 + [int]$runtimeLogLinkFileCreated
    Test-BRAVOCondition (
        $runtimeLogLinkSummary.Uploaded -eq 1 -and $runtimeLogLinkSummary.Skipped -eq $runtimeLogLinkExpectedSkipped -and
        @($runtimeLogLinkState.SentRemotePaths).Count -eq 1 -and
        @($runtimeLogLinkState.SentRemotePaths)[0] -eq '/logs/runtime/real_1.log' -and
        (@($runtimeLogLinkState.SentContents) -join '|') -notmatch 'OUTSIDE-SECRET' -and
        @($runtimeLogLinkState.Warnings | Where-Object { $_ -like 'WARNING:*reparse point*' }).Count -eq $runtimeLogLinkExpectedSkipped
    ) -Name 'Maintenance/RuntimeLogSyncSkipsReparsePoints' `
        -Failure "посилання (каталог$(if ($runtimeLogLinkFileCreated) { ' і файл' })) не відкриваються й не обходяться, вміст поза LOGS не вивантажується, кожен пропуск — WARNING; факт: uploaded=$($runtimeLogLinkSummary.Uploaded) skipped=$($runtimeLogLinkSummary.Skipped) sent=$(@($runtimeLogLinkState.SentRemotePaths) -join ',') warnings=$(@($runtimeLogLinkState.Warnings).Count)"
    # Посилання видаляються ДО рекурсивного прибирання — інакше Remove-Item
    # на PS 5.1 міг би зайти у junction.
    if ($runtimeLogLinkFileCreated) { try { [IO.File]::Delete($runtimeLogLinkFile) } catch { $runtimeLogLinkFixtureNote = $_.Exception.Message } }
    try { [IO.Directory]::Delete($runtimeLogLinkDir) } catch { $runtimeLogLinkFixtureNote = $_.Exception.Message }

    # Сам корінь LOGS — посилання (легітимне налаштування): вивантаження
    # триває, а вкладені посилання все одно пропускаються.
    $runtimeLogRootLink = Join-Path $maintenanceOwnLogTestRoot 'ROOTLINK'
    $runtimeLogRootLinkNested = Join-Path $runtimeLogLinkRoot 'NESTED'
    try { [void](New-Item -ItemType SymbolicLink -Path $runtimeLogRootLink -Target $runtimeLogLinkRoot -ErrorAction Stop) } catch { $runtimeLogLinkFixtureNote = $_.Exception.Message }
    if (-not (Test-Path -LiteralPath $runtimeLogRootLink)) {
        try { [void](New-Item -ItemType Junction -Path $runtimeLogRootLink -Target $runtimeLogLinkRoot -ErrorAction Stop) } catch { $runtimeLogLinkFixtureNote = $_.Exception.Message }
    }
    if (-not (Test-Path -LiteralPath $runtimeLogRootLink) -and $env:OS -eq 'Windows_NT') {
        $runtimeLogLinkFixtureNote = (& cmd.exe /c mklink /J "`"$runtimeLogRootLink`"" "`"$runtimeLogLinkRoot`"" 2>&1 | Out-String)
    }
    $runtimeLogRootLinkCreated = (Test-Path -LiteralPath $runtimeLogRootLink)
    try { [void](New-Item -ItemType SymbolicLink -Path $runtimeLogRootLinkNested -Target $runtimeLogLinkOutside -ErrorAction Stop) } catch { $runtimeLogLinkFixtureNote = $_.Exception.Message }
    if (-not (Test-Path -LiteralPath $runtimeLogRootLinkNested)) {
        try { [void](New-Item -ItemType Junction -Path $runtimeLogRootLinkNested -Target $runtimeLogLinkOutside -ErrorAction Stop) } catch { $runtimeLogLinkFixtureNote = $_.Exception.Message }
    }
    $runtimeLogRootLinkState = New-BRAVORuntimeLogSyncTestState
    $runtimeLogRootLinkSummary = $null
    if ($runtimeLogRootLinkCreated) {
        $runtimeLogRootLinkSummary = & $runtimeLogSyncModule $runtimeLogSyncRun $runtimeLogRootLink 'logs/runtime' $runtimeLogRootLinkState
    }
    Test-BRAVOCondition (
        $runtimeLogRootLinkCreated -and $null -ne $runtimeLogRootLinkSummary -and -not $runtimeLogRootLinkSummary.Rejected -and
        @($runtimeLogRootLinkState.SentRemotePaths) -contains '/logs/runtime/real_1.log' -and
        (@($runtimeLogRootLinkState.SentContents) -join '|') -notmatch 'OUTSIDE-SECRET' -and
        @($runtimeLogRootLinkState.SentRemotePaths | Where-Object { $_ -like '*NESTED*' -or $_ -like '*outside*' }).Count -eq 0
    ) -Name 'Maintenance/RuntimeLogSyncAllowsReparsePointAsLogsRoot' `
        -Failure "корінь LOGS-посилання дозволений (вивантаження триває), вкладене посилання пропущено; факт: created=$runtimeLogRootLinkCreated sent=$(@($runtimeLogRootLinkState.SentRemotePaths) -join ',') note=$runtimeLogLinkFixtureNote"
    try { [IO.Directory]::Delete($runtimeLogRootLinkNested) } catch { $runtimeLogLinkFixtureNote = $_.Exception.Message }
    try { [IO.Directory]::Delete($runtimeLogRootLink) } catch { $runtimeLogLinkFixtureNote = $_.Exception.Message }
}

# 3) Небезпечний remote-корінь відхиляється без вивантаження: WARNING, жодного Send.
$runtimeLogBadRemoteOk = $true
$runtimeLogBadRemoteFacts = @()
foreach ($runtimeLogBadRemote in @('', '   ', '.', '/', '\', '..', '../x', 'a/../../b', '..\x', 'logs/./x', 'logs//x')) {
    $runtimeLogBadState = New-BRAVORuntimeLogSyncTestState
    $runtimeLogBadSummary = & $runtimeLogSyncModule $runtimeLogSyncRun $runtimeLogSecRoot $runtimeLogBadRemote $runtimeLogBadState
    $runtimeLogBadWarnings = @($runtimeLogBadState.Warnings | Where-Object { $_ -like 'WARNING:*RuntimeLogs*' }).Count
    if (-not ($runtimeLogBadSummary.Rejected -and $runtimeLogBadSummary.Uploaded -eq 0 -and
            @($runtimeLogBadState.SentRemotePaths).Count -eq 0 -and @($runtimeLogBadState.EnsuredDirectories).Count -eq 0 -and
            $runtimeLogBadWarnings -eq 1)) {
        $runtimeLogBadRemoteOk = $false
        $runtimeLogBadRemoteFacts += "'$runtimeLogBadRemote'=>rejected:$($runtimeLogBadSummary.Rejected) sent:$(@($runtimeLogBadState.SentRemotePaths).Count) warn:$runtimeLogBadWarnings"
    }
}
Test-BRAVOCondition $runtimeLogBadRemoteOk -Name 'Maintenance/RuntimeLogSyncRejectsUnsafeRemoteRoot' `
    -Failure "порожній/'.'/'/'/'..'-сегмент remote-кореня мають відхилятись із одним WARNING і без вивантаження; факт: $($runtimeLogBadRemoteFacts -join '; ')"


# ---- Маскування секретів (Protect-BRAVOLogSecret): по тесту на кожен формат ----
# Кожен кейс падає, якщо видалити відповідне регулярне правило.
$runtimeLogMaskCases = @(
    @{ Name = 'Pwd'; In = 'Server=db1;Pwd=Zq9plainsecret;Timeout=5'; Leak = 'Zq9plainsecret' },
    @{ Name = 'JsonPassword'; In = '{"password": "Zq9plainsecret"}'; Leak = 'Zq9plainsecret' },
    @{ Name = 'JsonTokenNoSpace'; In = '{"token":"Zq9plainsecret","x":1}'; Leak = 'Zq9plainsecret' },
    @{ Name = 'JsonTokenQuotedKeyGap'; In = '{"token" : "Zq9plainsecret"}'; Leak = 'Zq9plainsecret' },
    @{ Name = 'SingleQuotedKey'; In = "{'api_key' : 'Zq9plainsecret'}"; Leak = 'Zq9plainsecret' },
    @{ Name = 'BearerToken'; In = 'Authorization: Bearer Zq9.plain-secret_1'; Leak = 'Zq9.plain-secret_1' },
    @{ Name = 'BasicAuthorization'; In = 'Authorization: Basic WnE5cGxhaW5zZWNyZXQ='; Leak = 'WnE5cGxhaW5zZWNyZXQ=' },
    @{ Name = 'ApiKeyUnderscore'; In = 'api_key=Zq9plainsecret&x=1'; Leak = 'Zq9plainsecret' },
    @{ Name = 'ApiKeyNoSeparator'; In = 'apikey: Zq9plainsecret'; Leak = 'Zq9plainsecret' },
    @{ Name = 'XApiKeyHeader'; In = 'X-Api-Key: Zq9plainsecret'; Leak = 'Zq9plainsecret' },
    @{ Name = 'Passphrase'; In = 'Passphrase=Zq9plainsecret'; Leak = 'Zq9plainsecret' },
    @{ Name = 'CliSpaceP'; In = 'tool.exe -p Zq9plainsecret --flag'; Leak = 'Zq9plainsecret' },
    @{ Name = 'CliSpacePw'; In = 'plink.exe -pw Zq9plainsecret host'; Leak = 'Zq9plainsecret' },
    @{ Name = 'CliSpacePwQuotedSpaces'; In = 'plink.exe -pw "Zq9 plain secret" host'; Leak = 'plain secret' },
    @{ Name = 'CliSpacePwSingleQuotedSpaces'; In = "plink.exe -pw 'Zq9 plain secret' host"; Leak = 'plain secret' },
    @{ Name = 'QuotedValueWithSpaces'; In = "password = 'Zq9 plain secret' next"; Leak = 'plain secret' },
    @{ Name = 'DoubleQuotedEscapedQuote'; In = 'password = "Zq9 pl\"ain secret" next'; Leak = 'secret"' },
    @{ Name = 'TokenThenBearer'; In = 'token: Bearer Zq9plainsecret'; Leak = 'Zq9plainsecret' },
    @{ Name = 'UrlCredentials'; In = 'sftp://svc:Zq9plainsecret@10.0.0.5/x'; Leak = 'Zq9plainsecret' },
    @{ Name = 'LongPasswordParam'; In = 'x.exe -password=Zq9plainsecret'; Leak = 'Zq9plainsecret' },
    @{ Name = 'ShortPasswordParam'; In = 'x.exe -pZq9plainsecret'; Leak = 'Zq9plainsecret' },
    @{ Name = 'SlackWebhook'; In = 'POST https://hooks.slack.com/services/T000/B000/Zq9plainsecret'; Leak = 'Zq9plainsecret' },
    @{ Name = 'DiscordWebhook'; In = 'POST https://discord.com/api/webhooks/123/Zq9plainsecret'; Leak = 'Zq9plainsecret' }
)
foreach ($runtimeLogMaskCase in $runtimeLogMaskCases) {
    $runtimeLogMaskOut = & $runtimeLogSyncModule { param($t) Protect-BRAVOLogSecret -Text $t } $runtimeLogMaskCase.In
    $runtimeLogMaskAgain = & $runtimeLogSyncModule { param($t) Protect-BRAVOLogSecret -Text $t } $runtimeLogMaskOut
    Test-BRAVOCondition (
        $runtimeLogMaskOut -notlike "*$($runtimeLogMaskCase.Leak)*" -and $runtimeLogMaskOut -like '*`*`*`**' -and $runtimeLogMaskAgain -ceq $runtimeLogMaskOut
    ) -Name "Logging/MaskSecret_$($runtimeLogMaskCase.Name)" `
        -Failure "формат '$($runtimeLogMaskCase.Name)' має маскуватись повністю й ідемпотентно; вхід='$($runtimeLogMaskCase.In)' вихід='$runtimeLogMaskOut' повторно='$runtimeLogMaskAgain'"
}
$runtimeLogMaskProse = & $runtimeLogSyncModule { Protect-BRAVOLogSecret -Text 'basic setup done; keep prose; mkdir -p' }
Test-BRAVOCondition ($runtimeLogMaskProse -ceq 'basic setup done; keep prose; mkdir -p') -Name 'Logging/MaskSecretKeepsPlainProse' `
    -Failure "звичайний текст без секретів не змінюється; факт: '$runtimeLogMaskProse'"

$runtimeLogMaskKnown = & $runtimeLogSyncModule {
    [pscustomobject]@{
        Literal = (Protect-BRAVOLogSecret -Text 'dump: Zq9literalKey and again Zq9literalKey end' -KnownSecrets @('Zq9literalKey'))
        Short   = (Protect-BRAVOLogSecret -Text 'abc stays; ab stays' -KnownSecrets @('abc', 'ab', '', $null))
        Encoded = (Protect-BRAVOLogSecret -Text 'url=p%40ss%21word&x' -KnownSecrets @('p@ss!word'))
        Longest = (Protect-BRAVOLogSecret -Text 'val Zq9literalKeyLong end' -KnownSecrets @('Zq9literalKey', 'Zq9literalKeyLong'))
        Null    = (Protect-BRAVOLogSecret -Text 'plain text' -KnownSecrets $null)
    }
}
Test-BRAVOCondition (
    $runtimeLogMaskKnown.Literal -ceq 'dump: *** and again *** end' -and
    $runtimeLogMaskKnown.Short -ceq 'abc stays; ab stays' -and
    $runtimeLogMaskKnown.Encoded -ceq 'url=***&x' -and
    $runtimeLogMaskKnown.Longest -ceq 'val *** end' -and
    $runtimeLogMaskKnown.Null -ceq 'plain text'
) -Name 'Logging/MaskKnownSecretLiterals' `
    -Failure "відомі секрети (>=4 символів) замінюються дослівно (разом із URL-кодованою формою, довші першими), короткі й порожні ігноруються; факт: $($runtimeLogMaskKnown.Literal) | $($runtimeLogMaskKnown.Short) | $($runtimeLogMaskKnown.Encoded) | $($runtimeLogMaskKnown.Longest)"

# Продуктивність: великий файл без пробілів / з незакритими лапками не дає
# катастрофічного відкату (було б квадратично).
$runtimeLogMaskPerf = & $runtimeLogSyncModule {
    $bigText = ('a' * 200000) + "`n" + ('password="' * 20000) + "`n" + ("token: `"a`n" * 20000) + ('\' * 100000)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    [void](Protect-BRAVOLogSecret -Text $bigText)
    $watch.Elapsed.TotalSeconds
}
Test-BRAVOCondition ($runtimeLogMaskPerf -lt 10) -Name 'Logging/MaskSecretLargeInputNoCatastrophicBacktracking' `
    -Failure "маскування ~0.5 МБ патологічного вводу має бути лінійним; факт: $runtimeLogMaskPerf с"

# Облікові дані з Credential Manager збираються дослівно (SFTP + SMB), короткі відкидаються.
$runtimeLogKnownCollected = & $runtimeLogSyncModule {
    $script:runtimeLogSecretStore = @{ 'BRAVO_SFTP_LOGIN' = ' svc-user1 '; 'BRAVO_SFTP_PASSWORD' = 'Zq9sftpSecret'; 'BRAVO_SMB_LOGIN' = 'abc'; 'BRAVO_SMB_PASSWORD' = 'Zq9smbSecret' }
    $script:credentialSettings = [pscustomobject]@{ Targets = [pscustomobject]@{ SFTPLogin = 'BRAVO_SFTP_LOGIN' } }
    @(Get-BRAVOOwnLogKnownSecrets)
}
Test-BRAVOCondition (
    @($runtimeLogKnownCollected).Count -eq 3 -and @($runtimeLogKnownCollected) -contains 'Zq9sftpSecret' -and
    @($runtimeLogKnownCollected) -contains 'Zq9smbSecret' -and @($runtimeLogKnownCollected) -contains 'svc-user1' -and
    @($runtimeLogKnownCollected) -notcontains 'abc'
) -Name 'Maintenance/OwnLogKnownSecretsCollectedFromCredentialManager' `
    -Failure "очікувано логін/пароль SFTP і пароль SMB (>=4 символів, без пробілів по краях); факт: $(@($runtimeLogKnownCollected) -join ',')"

# Синхронізація з відомим секретом без ключового слова: у знімку його немає.
$runtimeLogKnownRoot = Join-Path $maintenanceOwnLogTestRoot 'KNOWNLOGS'
[void](New-Item -ItemType Directory -Path $runtimeLogKnownRoot -Force)
[IO.File]::WriteAllText((Join-Path $runtimeLogKnownRoot 'echo_1.log'), "Read-Host echo: Zq9bareSecret\r\nend")
$runtimeLogKnownState = New-BRAVORuntimeLogSyncTestState
[void](& $runtimeLogSyncModule {
    param($localRoot, $state)
    $script:runtimeLogSyncState = $state
    $fakeSession = New-Object PSObject
    $fakeSession | Add-Member -MemberType ScriptMethod -Name FileExists -Value { param($path) return $false }
    Sync-BRAVORuntimeLogsToSftp -Session $fakeSession -LocalLogRoot $localRoot -RemoteDirectory 'logs/runtime' -KnownSecrets @('Zq9bareSecret')
} $runtimeLogKnownRoot $runtimeLogKnownState)
Test-BRAVOCondition (
    @($runtimeLogKnownState.SentContents).Count -eq 1 -and (@($runtimeLogKnownState.SentContents) -join '|') -notmatch 'Zq9bareSecret' -and
    (@($runtimeLogKnownState.SentContents) -join '|') -match 'Read-Host echo: \*\*\*'
) -Name 'Maintenance/RuntimeLogSyncMasksKnownCredentialLiterals' `
    -Failure "литерал облікових даних без ключового слова має бути замаскований у знімку; факт: '$(@($runtimeLogKnownState.SentContents) -join '|')'"

# ---- Send-BRAVOOwnLogFile: замаскований знімок, а не сирий живий лог ----
$runtimeLogOwnRoot = Join-Path $maintenanceOwnLogTestRoot 'OWNFILE'
[void](New-Item -ItemType Directory -Path $runtimeLogOwnRoot -Force)
$runtimeLogOwnLive = Join-Path $runtimeLogOwnRoot 'run_1.log'
$runtimeLogOwnLiveText = "start`r`npassword=Zq9liveSecret`r`nbare Zq9bareSecret`r`nПривіт`r`n"
[IO.File]::WriteAllText($runtimeLogOwnLive, $runtimeLogOwnLiveText, (New-Object Text.UnicodeEncoding($false, $true)))
$runtimeLogOwnBinary = Join-Path $runtimeLogOwnRoot 'blob_1.log'
[IO.File]::WriteAllBytes($runtimeLogOwnBinary, [byte[]](0x41, 0x00, 0x42, 0x00, 0x01, 0x02))
$runtimeLogOwnTempBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'BRAVO_log_snapshot_*.tmp' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$runtimeLogOwnState = New-BRAVORuntimeLogSyncTestState
$runtimeLogOwnBinaryState = New-BRAVORuntimeLogSyncTestState
& $runtimeLogSyncModule {
    param($live, $binary, $state, $binaryState)
    $script:runtimeLogSyncState = $state
    Send-BRAVOOwnLogFile -Session (New-Object PSObject) -LocalLogPath $live -RemoteDirectory 'logs/maintenance' -KnownSecrets @('Zq9bareSecret')
    $script:runtimeLogSyncState = $binaryState
    Send-BRAVOOwnLogFile -Session (New-Object PSObject) -LocalLogPath $binary -RemoteDirectory 'logs/maintenance'
} $runtimeLogOwnLive $runtimeLogOwnBinary $runtimeLogOwnState $runtimeLogOwnBinaryState
$runtimeLogOwnTempLeft = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'BRAVO_log_snapshot_*.tmp' -ErrorAction SilentlyContinue | Where-Object { $runtimeLogOwnTempBefore -notcontains $_.FullName })
$runtimeLogOwnSentText = (@($runtimeLogOwnState.SentContents) -join '|')
Test-BRAVOCondition (
    @($runtimeLogOwnState.SentRemotePaths).Count -eq 1 -and @($runtimeLogOwnState.SentRemotePaths)[0] -eq '/logs/maintenance/run_1.log' -and
    @($runtimeLogOwnState.SentLocalPaths)[0] -ne $runtimeLogOwnLive -and
    $runtimeLogOwnSentText -notmatch 'Zq9liveSecret' -and $runtimeLogOwnSentText -notmatch 'Zq9bareSecret' -and
    $runtimeLogOwnSentText -match 'password=\*\*\*' -and $runtimeLogOwnSentText -match 'Привіт' -and
    @($runtimeLogOwnState.SentHeads)[0] -eq 'FFFE73' -and
    [IO.File]::ReadAllText($runtimeLogOwnLive) -match 'Zq9liveSecret' -and
    @($runtimeLogOwnTempLeft).Count -eq 0
) -Name 'Maintenance/OwnLogFileUploadsMaskedSnapshotNotLiveLog' `
    -Failure "Send-BRAVOOwnLogFile має передавати замаскований знімок (UTF-16LE BOM збережено), живий лог не змінюється, знімок прибирається; факт: paths=$(@($runtimeLogOwnState.SentLocalPaths) -join ',') head=$(@($runtimeLogOwnState.SentHeads) -join ',') content='$runtimeLogOwnSentText' leftover=$(@($runtimeLogOwnTempLeft).Count)"
Test-BRAVOCondition (
    @($runtimeLogOwnBinaryState.SentRemotePaths).Count -eq 0 -and
    @($runtimeLogOwnBinaryState.Warnings | Where-Object { $_ -like 'WARNING:*blob_1.log*' }).Count -eq 1 -and
    @($runtimeLogOwnTempLeft).Count -eq 0
) -Name 'Maintenance/OwnLogFileSkipsNonTextAndCleansSnapshot' `
    -Failure "нетекстовий файл не вивантажується (WARNING), знімок не лишається; факт: sent=$(@($runtimeLogOwnBinaryState.SentRemotePaths).Count) warnings=$(@($runtimeLogOwnBinaryState.Warnings) -join ' | ') leftover=$(@($runtimeLogOwnTempLeft).Count)"


Remove-Item -LiteralPath $maintenanceOwnLogTestRoot -Recurse -Force -ErrorAction SilentlyContinue
