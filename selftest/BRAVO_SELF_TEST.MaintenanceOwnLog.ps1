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
}function Get-BRAVOLogMaskSecretSet { param($CredentialSettings) return [pscustomobject]@{ Secrets = [string[]]@(); Skipped = @() } }
function New-BRAVOMaskedLogCopy {
    # #365: стаб маскованої копії для тестів тумблера/ідемпотентності —
    # саме маскування перевіряють окремі тести на справжніх функціях.
    param([string]$Path, [string[]]$KnownSecret)
    $copyDirectory = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_masked_log_" + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($copyDirectory)
    $copyPath = Join-Path $copyDirectory ([IO.Path]::GetFileName($Path))
    [IO.File]::Copy($Path, $copyPath)
    return $copyPath
}
function Remove-BRAVOMaskedLogCopy {
    param([string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Path)) { Remove-Item -LiteralPath (Split-Path -Parent $Path) -Recurse -Force -ErrorAction SilentlyContinue }
}
'@
$maintenanceOwnLogFunctionNames = @("Write-Log", "Get-BRAVOFileHash", "Connect-BRAVOOwnLogSftpSession",
    "Send-BRAVOOwnLogFile", "Get-BRAVOSystemRangeIdLogPath", "Get-BRAVOLogMaskSecretSet",
    "New-BRAVOMaskedLogCopy", "Remove-BRAVOMaskedLogCopy", "Invoke-BRAVOMaintenanceOwnLogUpload")
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
        [int]$InvokeTimes = 1
    )
    & $Module {
        param($enabled, $sftpEnabled, $defineConfig, $logFilePath, $rangeIdLogPath,
            $mutateLiveFileAfterHash, $connectShouldReturnNull, $connectShouldThrow, $sendShouldThrow, $invokeTimes)
        $script:maintOwnLogTestState = [pscustomobject]@{
            ConnectCalls             = 0
            SendCalls                = 0
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
            $script:sftpDirectories = [pscustomobject]@{ MaintenanceLog = 'logs/maintenance' }
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
            SendCallPaths    = $script:maintOwnLogTestState.SendCallPaths.ToArray()
            SendCallContents = $script:maintOwnLogTestState.SendCallContents.ToArray()
        }
    } $Enabled $SftpEnabled $DefineConfig $LogFilePath $RangeIdLogPath `
        $MutateLiveFileAfterHash $ConnectShouldReturnNull $ConnectShouldThrow $SendShouldThrow $InvokeTimes
}

# (a) Тумблер вимкнений (дефолт) -> 0 спроб вивантаження.
$maintOwnLogDisabled = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $false -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogDisabled.ConnectCalls -eq 0 -and $maintOwnLogDisabled.SendCalls -eq 0
) -Name 'Maintenance/OwnLogUploadDisabledMakesZeroAttempts' `
    -Failure "MaintenanceLogUploadEnabled=`$false має пропускати вивантаження без жодної спроби; факт: connect=$($maintOwnLogDisabled.ConnectCalls) send=$($maintOwnLogDisabled.SendCalls)"

# (b) Увімкнено, БЕЗ range_id_log.json -> рівно 1 спроба (лише основний лог).
$maintOwnLogEnabledNoRangeId = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $true -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogEnabledNoRangeId.ConnectCalls -eq 1 -and $maintOwnLogEnabledNoRangeId.SendCalls -eq 1
) -Name 'Maintenance/OwnLogUploadEnabledWithoutRangeIdMakesExactlyOneAttempt' `
    -Failure "увімкнено, без range_id_log.json -> рівно 1 передача (основний лог); факт: connect=$($maintOwnLogEnabledNoRangeId.ConnectCalls) send=$($maintOwnLogEnabledNoRangeId.SendCalls)"

# (c) Крах ДО завантаження конфігурації -> тихий no-op, БЕЗ винятку.
$maintOwnLogNoConfig = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -DefineConfig $false -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogNoConfig.ConnectCalls -eq 0 -and $maintOwnLogNoConfig.SendCalls -eq 0
) -Name 'Maintenance/OwnLogUploadMissingConfigIsSilentNoOpNotThrow' `
    -Failure "крах до завантаження конфігурації не повинен кидати виняток назовні"

# (d) Transport кидає виняток -> best-effort, не пробрасывает далі.
$maintOwnLogSendFails = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $true -SendShouldThrow $true -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogSendFails.SendCalls -eq 1
) -Name 'Maintenance/OwnLogUploadTransportFailureCaughtNotPropagated' `
    -Failure "провал передачі не повинен кидати виняток назовні; факт: send=$($maintOwnLogSendFails.SendCalls)"

# (e) R3-1: ідемпотентність — виклик функції ДВІЧІ в одному прогоні (симулює
# call site №1 + call site №2 на щасливому шляху) -> лише ОДНА реальна спроба.
$maintOwnLogIdempotent = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $true -LogFilePath $maintenanceOwnLogFile -InvokeTimes 2
Test-BRAVOCondition (
    $maintOwnLogIdempotent.ConnectCalls -eq 1 -and $maintOwnLogIdempotent.SendCalls -eq 1
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

Remove-Item -LiteralPath $maintenanceOwnLogTestRoot -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================
# #365 (SECURITY): точне маскування секретів Credential Manager у БАЙТАХ,
# що реально йдуть на SFTP (власний лог Maintenance + знімок
# range_id_log.json). Протектор шаблонів (Protect-BRAVOLogSecret без
# -KnownSecret) ловить лише секрети біля ключового слова; сирий пароль
# 7-Zip / SFTP / SMB, API-ключ Operations чи webhook-URL без keyword-а
# раніше вивантажувався як є.
#
# Справжні production-функції (AST): Invoke-BRAVOMaintenanceOwnLogUpload,
# Send-BRAVOOwnLogFile (BRAVO.Maintenance.Runtime.ps1),
# Get-BRAVOCredentialTargetName / Get-BRAVOLogMaskSecretSet
# (BRAVO.Credentials), Protect-BRAVOLogSecret / New-BRAVOMaskedLogCopy /
# Remove-BRAVOMaskedLogCopy (BRAVO.Logging), Get-BRAVODefaultConfiguration
# (BRAVO.Configuration). Стаби — лише на зовнішніх межах: читання
# Credential Manager (Get-BRAVOCredential — сам CredRead; ланцюг
# Get-BRAVOCredentialSecureSecret / Get-BRAVOCredentialSecret /
# ConvertFrom-BRAVOSecureSecret — справжній), SFTP-сесія/транспорт
# (Connect-BRAVOOwnLogSftpSession, Send-BRAVOTraceArchiveFile,
# New-BRAVOBazaRemoteDirectoryRecursive) і лог-синк (Write-Log).
# Усі секрети нижче — синтетичні плейсхолдери.
# ============================================================

$secretMaskLoggingText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Logging\BRAVO.Logging.psm1'), [Text.Encoding]::UTF8)
$secretMaskCredentialsText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Credentials\BRAVO.Credentials.psm1'), [Text.Encoding]::UTF8)
$secretMaskConfigurationText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.psm1'), [Text.Encoding]::UTF8)

# Синтетичні секрети: ключ credentialSettings.Targets -> значення. Жоден не
# стоїть біля password/secret/token і не має форми user:pass@ чи
# Slack/Discord-webhook — тобто шаблони Protect-BRAVOLogSecret їх НЕ ловлять.
# Значення будуються під час запуску з коротких низькоентропійних частин
# (конвенція репозиторію: жодного суцільного секрето-подібного літерала);
# кожен запуск отримує інші значення.
$secretMaskNewValue = { param([string]$Prefix) $Prefix + [guid]::NewGuid().ToString('N').Substring(0, 12) }
$secretMaskWebhookFormat = 'https://{0}/synthetic/{1}-{2}'
$secretMaskSyntheticByKey = [ordered]@{
    SFTPPassword              = (& $secretMaskNewValue 'Sftp')
    SMBPassword               = (& $secretMaskNewValue 'Smb#')
    ArchivePassword           = (& $secretMaskNewValue 'Arch7z!')
    OperationsBootstrapSecret = (& $secretMaskNewValue 'Boot')
    OperationsApiKey          = (& $secretMaskNewValue 'ops-')
    SlackWebhookGeneral       = ($secretMaskWebhookFormat -f 'hooks.example.invalid', 'slack-general', (& $secretMaskNewValue 'W'))
    SlackWebhookAlerts        = ($secretMaskWebhookFormat -f 'hooks.example.invalid', 'slack-alerts', (& $secretMaskNewValue 'W'))
    DiscordWebhookGeneral     = ($secretMaskWebhookFormat -f 'chat.example.invalid', 'discord-general', (& $secretMaskNewValue 'W'))
    DiscordWebhookAlerts      = ($secretMaskWebhookFormat -f 'chat.example.invalid', 'discord-alerts', (& $secretMaskNewValue 'W'))
}
# Частина target-ів перейменована у конфігурації (доводить, що резолв іде
# через канонічний resolver, а не через жорсткі літерали), SMBPassword
# порожній (-> канонічний дефолт), решта відсутня (-> канонічні дефолти).
$secretMaskTargetPrefix = 'SELFTEST_365'
$secretMaskSftpTarget = $secretMaskTargetPrefix + '_SFTP_PW'
$secretMask7zTarget = $secretMaskTargetPrefix + '_7Z_PW'
$secretMaskOpsApiTarget = $secretMaskTargetPrefix + '_OPS_API'
$secretMaskObj7zTarget = $secretMaskTargetPrefix + '_OBJ_7Z'
$secretMaskTargetsConfig = @{
    SFTPPassword     = $secretMaskSftpTarget
    ArchivePassword  = $secretMask7zTarget
    OperationsApiKey = $secretMaskOpsApiTarget
    SMBPassword      = ''
}
$secretMaskTargetNameByKey = [ordered]@{
    SFTPPassword              = $secretMaskSftpTarget
    SMBPassword               = 'BRAVO_SMB_PASSWORD'
    ArchivePassword           = $secretMask7zTarget
    OperationsBootstrapSecret = 'BRAVO_OPERATIONS_BOOTSTRAP_SECRET'
    OperationsApiKey          = $secretMaskOpsApiTarget
    SlackWebhookGeneral       = 'BRAVO_SLACK_GENERAL_URL'
    SlackWebhookAlerts        = 'BRAVO_SLACK_ALERTS_URL'
    DiscordWebhookGeneral     = 'BRAVO_DISCORD_GENERAL_URL'
    DiscordWebhookAlerts      = 'BRAVO_DISCORD_ALERTS_URL'
}
$secretMaskSecretByTarget = @{}
foreach ($secretMaskKey in @($secretMaskSyntheticByKey.Keys)) {
    $secretMaskSecretByTarget[[string]$secretMaskTargetNameByKey[$secretMaskKey]] = [string]$secretMaskSyntheticByKey[$secretMaskKey]
}
$secretMaskAllSecrets = [string[]]@($secretMaskSyntheticByKey.Values)

function Get-BRAVOSelfTestLeakedSecretKeys {
    # Повертає ІМЕНА ключів (не значення!) секретів, знайдених у тексті —
    # повідомлення провалу ніколи не друкує сам секрет.
    param([AllowNull()][string]$Text, [Parameter(Mandatory = $true)]$SecretByKey)
    $leaked = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Text)) { return }
    foreach ($leakKey in @($SecretByKey.Keys)) {
        if ($Text.Contains([string]$SecretByKey[$leakKey])) { $leaked.Add([string]$leakKey) }
    }
    # Розгортання конвеєром: викликач обгортає результат у @(...).
    return $leaked.ToArray()
}

$secretMaskStub = @'
function Write-Log { param([string]$Message, [string]$Level = "INFO") [void]$script:secretMaskTestState.LogLines.Add("[$Level] $Message") }
function Get-BRAVOCredential {
    # Межа = сам CredRead ([BRAVO.Security.CredentialManager]::ReadGeneric):
    # повертає StoredCredential-подібний об'єкт із SecureString, $null для
    # відсутнього запису, Win32Exception для недоступного.
    param([string]$Target)
    [void]$script:secretMaskTestState.ReadTargets.Add($Target)
    if (@($script:secretMaskTestState.ThrowTargets) -contains $Target) {
        # Імітує CredRead під SYSTEM без доступу. Повідомлення винятку
        # навмисно несе ІНШИЙ синтетичний секрет — діагностика не має права
        # його переказати.
        throw (New-Object System.ComponentModel.Win32Exception(5, ("synthetic CredRead failure for '" + $Target + "' " + $script:secretMaskTestState.ExceptionPayload)))
    }
    if (@($script:secretMaskTestState.CorruptTargets) -contains $Target) {
        # CredRead УСПІШНИЙ, але подальша обробка значення падає (тут —
        # перетворення SecureString -> рядок). Це НЕ збій читання.
        return [pscustomobject]@{ TargetName = $Target; UserName = ''; Secret = [pscustomobject]@{ SelfTestCorrupt = $true } }
    }
    if ($script:secretMaskTestState.SecretByTarget.ContainsKey($Target)) {
        $selfTestSecure = New-Object System.Security.SecureString
        foreach ($selfTestChar in ([string]$script:secretMaskTestState.SecretByTarget[$Target]).ToCharArray()) { $selfTestSecure.AppendChar($selfTestChar) }
        $selfTestSecure.MakeReadOnly()
        return [pscustomobject]@{ TargetName = $Target; UserName = ''; Secret = $selfTestSecure }
    }
    return $null
}
function Connect-BRAVOOwnLogSftpSession { $script:secretMaskTestState.ConnectCalls++; return [pscustomobject]@{ IsFake = $true } }
function New-BRAVOBazaRemoteDirectoryRecursive { param($Session, [string]$RemoteDirectoryPath) }
function Send-BRAVOTraceArchiveFile {
    param($Session, [string]$LocalPath, [string]$RemoteFinalPath, $Logger)
    # Спроба фіксується ДО читання: передача з заблокованого живого шляху
    # теж рахується як спроба вивантажити немаскований лог.
    $uploadRecord = [pscustomobject]@{ LocalPath = $LocalPath; RemoteFinalPath = $RemoteFinalPath; Text = $null }
    [void]$script:secretMaskTestState.Uploads.Add($uploadRecord)
    $uploadedBytes = [IO.File]::ReadAllBytes($LocalPath)
    $uploadRecord.Text = [Text.Encoding]::UTF8.GetString($uploadedBytes)
    return [pscustomobject]@{ Success = $true; RemoteSize = [int64]$uploadedBytes.Length; Error = $null }
}
function Get-BRAVOFileHash { param([string]$Path, [string]$Algorithm = "SHA512") return [pscustomobject]@{ Hash = 'SELFTESTHASH' } }
function Get-BRAVOSystemRangeIdLogPath { return $script:secretMaskTestState.RangeIdLogPath }
'@

$secretMaskSourceText = $secretMaskStub + "`n" + $maintenanceOwnLogScriptText + "`n" + $secretMaskCredentialsText + "`n" + $secretMaskLoggingText + "`n" + $secretMaskConfigurationText
# #417: Add-BRAVOCredentialReadSecretRecord — приватний helper обліку
# прочитаних/записаних секретів, який викликають getter і Set-BRAVOCredential.
$secretMaskCredentialReadChain = @('Get-BRAVOCredential', 'Get-BRAVOCredentialSecureSecret', 'ConvertFrom-BRAVOSecureSecret', 'Get-BRAVOCredentialSecret', 'Add-BRAVOCredentialReadSecretRecord')
$secretMaskBoundaryAndUploadFunctions = $secretMaskCredentialReadChain + @(
    'Write-Log', 'Connect-BRAVOOwnLogSftpSession',
    'New-BRAVOBazaRemoteDirectoryRecursive', 'Send-BRAVOTraceArchiveFile', 'Get-BRAVOFileHash',
    'Get-BRAVOSystemRangeIdLogPath', 'Send-BRAVOOwnLogFile', 'Invoke-BRAVOMaintenanceOwnLogUpload'
)
$secretMaskModule = $null
$secretMaskSetupError = ''
try {
    $secretMaskModule = New-BRAVOSelfTestRuntimeModule -SourceText $secretMaskSourceText `
        -FunctionNames ($secretMaskBoundaryAndUploadFunctions + @(
            'Get-BRAVOCredentialTargetName', 'Get-BRAVOLogMaskSecretSet', 'Get-BRAVOArchivePasswordTarget',
            'Protect-BRAVOLogSecret', 'New-BRAVOMaskedLogCopy', 'Remove-BRAVOMaskedLogCopy',
            'Copy-BRAVOConfigurationGraphDeep', 'Get-BRAVODefaultConfiguration'
        ))
} catch {
    $secretMaskModule = $null
    $secretMaskSetupError = "production-функції #365 недоступні: $($_.Exception.Message)"
}
# Інтеграційні сценарії ганяють САМ шлях вивантаження. Якщо функцій
# маскування ще немає (код до #365), сценарії все одно виконуються на
# наявному production-ланцюгу — і падають на фактичному витоку, а не лише
# на відсутності функцій.
$secretMaskUploadModule = $secretMaskModule
if ($null -eq $secretMaskUploadModule) {
    try {
        $secretMaskUploadModule = New-BRAVOSelfTestRuntimeModule -SourceText $secretMaskSourceText -FunctionNames $secretMaskBoundaryAndUploadFunctions
    } catch {
        $secretMaskUploadModule = $null
        $secretMaskSetupError = "$secretMaskSetupError; шлях вивантаження недоступний: $($_.Exception.Message)"
    }
}

function Invoke-BRAVOSelfTestSecretMaskScenario {
    # Один прогін Invoke-BRAVOMaintenanceOwnLogUpload з повним реальним
    # ланцюгом маскування. Повертає завантаження (шлях/remote/текст), рядки
    # Write-Log, прочитані target-и і факт наявності тимчасових копій ПІСЛЯ.
    param(
        [Parameter(Mandatory = $true)][object]$Module,
        [Parameter(Mandatory = $true)][string]$LogFilePath,
        [Parameter(Mandatory = $true)][hashtable]$SecretByTarget,
        [Parameter(Mandatory = $true)][hashtable]$TargetsConfig,
        [string[]]$ThrowTargets = @(),
        [string[]]$CorruptTargets = @(),
        [string]$ExceptionPayload = '',
        [string]$RangeIdLogPath = '',
        [bool]$LockLogFile = $false
    )
    $lockHandle = $null
    if ($LockLogFile) {
        $lockHandle = [IO.File]::Open($LogFilePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    try {
        & $Module {
            param($logFilePath, $secretByTarget, $targetsConfig, $throwTargets, $exceptionPayload, $rangeIdLogPath, $corruptTargets)
            # Кожен сценарій стартує з порожнім реєстром раніше прочитаних секретів
            # BRAVO.Credentials: модуль спільний, і значення з попередніх сценаріїв
            # інакше маскували б усе й ховали б регресії (false pass).
            $script:BRAVOCredentialReadSecretRegistry = $null
            $script:secretMaskTestState = [pscustomobject]@{
                LogLines         = (New-Object System.Collections.Generic.List[string])
                ReadTargets      = (New-Object System.Collections.Generic.List[string])
                Uploads          = (New-Object System.Collections.Generic.List[object])
                SecretByTarget   = $secretByTarget
                ThrowTargets     = @($throwTargets)
                CorruptTargets   = @($corruptTargets)
                ExceptionPayload = $exceptionPayload
                RangeIdLogPath   = $rangeIdLogPath
                ConnectCalls     = 0
            }
            $global:componentSettings = [pscustomobject]@{ SFTP = [pscustomobject]@{ MaintenanceLogUploadEnabled = $true } }
            $global:storageEffective = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $true } }
            $script:credentialSettings = @{ Targets = $targetsConfig }
            $script:sftpDirectories = [pscustomobject]@{ MaintenanceLog = 'logs/maintenance' }
            $script:LOG_FILE = $logFilePath
            $script:maintenanceLogRunId = 'selftest_365_run'
            $script:maintenanceOwnLogUploadAttempted = $false
            $invokeError = ''
            try {
                Invoke-BRAVOMaintenanceOwnLogUpload
            } catch {
                $invokeError = [string]$_.Exception.Message
            }
            $uploads = $script:secretMaskTestState.Uploads.ToArray()
            $leftoverCopies = @($uploads | Where-Object { Test-Path -LiteralPath $_.LocalPath })
            [pscustomobject]@{
                Uploads        = $uploads
                LogLines       = $script:secretMaskTestState.LogLines.ToArray()
                ReadTargets    = $script:secretMaskTestState.ReadTargets.ToArray()
                ConnectCalls   = $script:secretMaskTestState.ConnectCalls
                LeftoverCopies = @($leftoverCopies).Count
                InvokeError    = $invokeError
            }
        } $LogFilePath $SecretByTarget $TargetsConfig $ThrowTargets $ExceptionPayload $RangeIdLogPath $CorruptTargets
    } finally {
        if ($null -ne $lockHandle) { $lockHandle.Dispose() }
    }
}

$secretMaskTestRoot = Join-Path $env:TEMP "BRAVOSelfTest_SecretMask365_$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $secretMaskTestRoot -Force)
$secretMaskLogName = 'BRAVO_{0}_{1}_{2}_PID{3}.log' -f 'MAINTENANCE', '20260101', '010203', '365'
$secretMaskLogFile = Join-Path $secretMaskTestRoot $secretMaskLogName
$secretMaskLogLines = New-Object System.Collections.Generic.List[string]
$secretMaskLogLines.Add('[2026-01-01 01:02:03] [INFO] Початок обслуговування — кирилиця має пережити маскування')
foreach ($secretMaskKey in @($secretMaskSyntheticByKey.Keys)) {
    # Сирий секрет БЕЗ ключового слова поруч — саме той випадок, який
    # шаблони не ловлять.
    $secretMaskLogLines.Add("[2026-01-01 01:02:04] [DEBUG] value $($secretMaskSyntheticByKey[$secretMaskKey]) observed for $secretMaskKey")
}
$secretMaskLogLines.Add('[2026-01-01 01:02:05] [INFO] Завершення')
$secretMaskLogOriginalText = ($secretMaskLogLines -join "`r`n") + "`r`n"
[IO.File]::WriteAllText($secretMaskLogFile, $secretMaskLogOriginalText, (New-Object Text.UTF8Encoding($true)))
$secretMaskLogOriginalBytes = [IO.File]::ReadAllBytes($secretMaskLogFile)

# --- (1) Protect-BRAVOLogSecret: чинні шаблони без -KnownSecret незмінні
# (регресійний guard; мусить проходити і ДО, і ПІСЛЯ #365).
$secretMaskProtectOnlyModule = New-BRAVOSelfTestRuntimeModule -SourceText $secretMaskLoggingText -FunctionNames @('Protect-BRAVOLogSecret')
$secretMaskPatternPw = $secretMaskNewValue.Invoke('Pw')[0]
$secretMaskPatternTok = $secretMaskNewValue.Invoke('Tk')[0]
$secretMaskSlackHost = 'hooks' + '.slack.com'
$secretMaskDiscordHost = 'discord' + '.com'
$secretMaskPatternCases = @(
    @{ In = "connect sftp://selftest-user:${secretMaskPatternPw}@sftp.example.invalid:22/"; Out = 'connect sftp://selftest-user:***@sftp.example.invalid:22/' },
    @{ In = "winscp -password=$secretMaskPatternPw next"; Out = 'winscp -password=*** next' },
    @{ In = "7za a -p$secretMaskPatternPw -mhe=on"; Out = '7za a -p*** -mhe=on' },
    @{ In = "password: $secretMaskPatternPw tail"; Out = 'password: *** tail' },
    @{ In = "post https://$secretMaskSlackHost/services/TSYN/BSYN/$secretMaskPatternTok"; Out = 'post https://hooks.slack.com/services/***' },
    @{ In = "post https://$secretMaskDiscordHost/api/webhooks/123/$secretMaskPatternTok"; Out = 'post https://discord.com/api/webhooks/***' },
    @{ In = 'backup at -path C:\Some\Dir'; Out = 'backup at -path C:\Some\Dir' }
)
$secretMaskPatternMismatches = New-Object System.Collections.Generic.List[string]
foreach ($secretMaskCase in $secretMaskPatternCases) {
    $secretMaskActual = & $secretMaskProtectOnlyModule { param($t) Protect-BRAVOLogSecret -Text $t } $secretMaskCase.In
    if ([string]$secretMaskActual -cne [string]$secretMaskCase.Out) { $secretMaskPatternMismatches.Add([string]$secretMaskCase.Out) }
}
Test-BRAVOCondition ($secretMaskPatternMismatches.Count -eq 0) `
    -Name 'Logging/ProtectLogSecretPatternsUnchangedWithoutKnownSecret' `
    -Failure "Protect-BRAVOLogSecret без -KnownSecret має давати рівно ту саму шаблонну масковку, що й до #365; не збіглися очікування: $($secretMaskPatternMismatches -join ' | ')"

# --- (2) Сирий секрет без keyword-а маскується точним значенням.
$secretMaskRawResult = $null
$secretMaskRawError = $secretMaskSetupError
if ($null -ne $secretMaskModule) {
    try {
        $secretMaskRawResult = & $secretMaskModule {
            param($secrets)
            Protect-BRAVOLogSecret -Text ("a " + $secrets[2] + " b " + $secrets[0] + " c") -KnownSecret $secrets
        } $secretMaskAllSecrets
    } catch { $secretMaskRawError = $_.Exception.GetType().FullName }
}
$secretMaskRawLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text ([string]$secretMaskRawResult) -SecretByKey $secretMaskSyntheticByKey)
Test-BRAVOCondition (
    $null -ne $secretMaskRawResult -and $secretMaskRawLeaks.Count -eq 0 -and
    [string]$secretMaskRawResult -ceq 'a *** b *** c'
) -Name 'Logging/KnownSecretMaskedWithoutKeyword' `
    -Failure "Protect-BRAVOLogSecret -KnownSecret має замінювати точні значення секретів на *** навіть без ключового слова поруч; витекли ключі: $($secretMaskRawLeaks -join ', '); помилка: $secretMaskRawError"

# --- (3) Перекривні секрети: довший маскується першим (інакше хвіст
# довшого секрету лишився б у тексті як '***-tail').
$secretMaskOverlapBase = $secretMaskNewValue.Invoke('Overlap')[0]
$secretMaskOverlapTail = $secretMaskNewValue.Invoke('TAIL')[0]
$secretMaskOverlapLong = $secretMaskOverlapBase + '-extended-' + $secretMaskOverlapTail
$secretMaskOverlapResult = $null
$secretMaskOverlapError = $secretMaskSetupError
if ($null -ne $secretMaskModule) {
    try {
        $secretMaskOverlapResult = & $secretMaskModule {
            param($base, $long)
            Protect-BRAVOLogSecret -Text "x $long y $base z" -KnownSecret @($base, $long)
        } $secretMaskOverlapBase $secretMaskOverlapLong
    } catch { $secretMaskOverlapError = $_.Exception.GetType().FullName }
}
Test-BRAVOCondition (
    [string]$secretMaskOverlapResult -ceq 'x *** y *** z'
) -Name 'Logging/KnownSecretOverlappingSecretsLongestFirst' `
    -Failure "коли один секрет — підрядок іншого, довший має маскуватись першим (очікується 'x *** y *** z'); хвіст довшого секрету лишився: $(([string]$secretMaskOverlapResult).Contains($secretMaskOverlapTail)); помилка: $secretMaskOverlapError"

# --- (4) Правило коротких/порожніх значень: порожнє і whitespace-only
# НЕ маскуються (інакше *** замінило б кожен пробіл), будь-яке інше
# непорожнє значення — маскується, навіть коротке (безпечна сторона).
$secretMaskPadBase = $secretMaskNewValue.Invoke('Pad')[0]
$secretMaskShortResult = $null
$secretMaskShortError = $secretMaskSetupError
if ($null -ne $secretMaskModule) {
    try {
        $secretMaskShortResult = & $secretMaskModule {
            param($padBase)
            [pscustomobject]@{
                Blank = (Protect-BRAVOLogSecret -Text 'keep  spaces	and tabs' -KnownSecret @('', '   ', "`t", $null))
                Short = (Protect-BRAVOLogSecret -Text 'pin Q7 end' -KnownSecret @('Q7'))
                Padded = (Protect-BRAVOLogSecret -Text "pad $padBase end" -KnownSecret @("  $padBase`r`n"))
            }
        } $secretMaskPadBase
    } catch { $secretMaskShortError = $_.Exception.GetType().FullName }
}
Test-BRAVOCondition (
    $null -ne $secretMaskShortResult -and
    [string]$secretMaskShortResult.Blank -ceq 'keep  spaces	and tabs' -and
    [string]$secretMaskShortResult.Short -ceq 'pin *** end' -and
    [string]$secretMaskShortResult.Padded -ceq 'pad *** end'
) -Name 'Logging/KnownSecretBlankNeverMaskedShortAndPaddedMasked' `
    -Failure "порожні/whitespace-only значення не маскуються (текст незмінний), коротке непорожнє маскується, значення з краєвими пробілами маскується і в обрізаній формі; помилка: $secretMaskShortError"

# --- (5) Шаблони працюють і разом із -KnownSecret.
$secretMaskCombinedRaw = $secretMaskNewValue.Invoke('Raw')[0]
$secretMaskCombinedResult = $null
$secretMaskCombinedError = $secretMaskSetupError
if ($null -ne $secretMaskModule) {
    try {
        $secretMaskCombinedResult = & $secretMaskModule {
            param($patternPw, $rawValue, $patternTok)
            Protect-BRAVOLogSecret -Text "sftp://selftest-user:${patternPw}@sftp.example.invalid/ and $rawValue and token=$patternTok" `
                -KnownSecret @($rawValue)
        } $secretMaskPatternPw $secretMaskCombinedRaw $secretMaskPatternTok
    } catch { $secretMaskCombinedError = $_.Exception.GetType().FullName }
}
Test-BRAVOCondition (
    [string]$secretMaskCombinedResult -ceq 'sftp://selftest-user:***@sftp.example.invalid/ and *** and token=***'
) -Name 'Logging/KnownSecretKeepsExistingPatternMasking' `
    -Failure "-KnownSecret доповнює, а не замінює шаблонну масковку (URL-креди, token=...); помилка: $secretMaskCombinedError"

# --- (6) Канонічний resolver target-ів: дефолти збігаються з
# Get-BRAVODefaultConfiguration, конфігурація має пріоритет, порожнє
# значення -> канонічний дефолт; Get-BRAVOArchivePasswordTarget делегує.
$secretMaskResolverMismatches = New-Object System.Collections.Generic.List[string]
$secretMaskResolverError = $secretMaskSetupError
if ($null -ne $secretMaskModule) {
    try {
        $secretMaskResolverMismatches = & $secretMaskModule {
            param($targetsConfig, $expectedByKey, $obj7zTarget)
            $mismatches = New-Object System.Collections.Generic.List[string]
            $defaultTargets = (Get-BRAVODefaultConfiguration).credentialSettings.Targets
            foreach ($key in @($defaultTargets.Keys)) {
                $resolved = Get-BRAVOCredentialTargetName -CredentialSettings $null -Key $key
                if ([string]$resolved -cne [string]$defaultTargets[$key]) { $mismatches.Add("default:$key") }
            }
            foreach ($key in @($expectedByKey.Keys)) {
                $resolved = Get-BRAVOCredentialTargetName -CredentialSettings @{ Targets = $targetsConfig } -Key $key
                if ([string]$resolved -cne [string]$expectedByKey[$key]) { $mismatches.Add("configured:$key") }
            }
            $objectSettings = [pscustomobject]@{ Targets = [pscustomobject]@{ ArchivePassword = $obj7zTarget } }
            if ((Get-BRAVOCredentialTargetName -CredentialSettings $objectSettings -Key 'ArchivePassword') -cne $obj7zTarget) { $mismatches.Add('pscustomobject:ArchivePassword') }
            if ((Get-BRAVOCredentialTargetName -CredentialSettings $objectSettings -Key 'SMBPassword') -cne 'BRAVO_SMB_PASSWORD') { $mismatches.Add('pscustomobject:SMBPassword') }
            if ((Get-BRAVOArchivePasswordTarget -CredentialSettings @{ Targets = $targetsConfig }) -cne $expectedByKey['ArchivePassword']) { $mismatches.Add('ArchivePasswordTargetDelegates') }
            $unknownThrew = $false
            try { [void](Get-BRAVOCredentialTargetName -CredentialSettings $null -Key 'NoSuchSelfTestKey') } catch { $unknownThrew = $true }
            if (-not $unknownThrew) { $mismatches.Add('unknown-key-must-throw') }
            ,$mismatches
        } $secretMaskTargetsConfig $secretMaskTargetNameByKey $secretMaskObj7zTarget
    } catch { $secretMaskResolverError = $_.Exception.Message; $secretMaskResolverMismatches.Add('error') }
} else {
    $secretMaskResolverMismatches.Add('setup')
}
Test-BRAVOCondition (@($secretMaskResolverMismatches).Count -eq 0) `
    -Name 'Credentials/TargetNameResolverIsCanonicalAndMatchesDefaults' `
    -Failure "Get-BRAVOCredentialTargetName — єдиний resolver target-ів (дефолти = Get-BRAVODefaultConfiguration, конфіг має пріоритет, порожнє -> дефолт, невідомий ключ -> throw); розбіжності: $(@($secretMaskResolverMismatches) -join ', '); помилка: $secretMaskResolverError"

# --- (7) Набір секретів для маскування: кожен підтримуваний target
# (SFTP, SMB, ArchivePassword, OperationsBootstrapSecret, OperationsApiKey,
# 4 webhook-и), відсутній target пропускається, недоступний (CredRead
# кидає під SYSTEM) пропускається з причиною БЕЗ тексту винятку, решта
# секретів лишається в наборі.
$secretMaskSetResult = $null
$secretMaskSetError = $secretMaskSetupError
$secretMaskSetSecrets = @{}
foreach ($secretMaskTarget in @($secretMaskSecretByTarget.Keys)) {
    if ($secretMaskTarget -ne 'BRAVO_DISCORD_ALERTS_URL') { $secretMaskSetSecrets[$secretMaskTarget] = $secretMaskSecretByTarget[$secretMaskTarget] }
}
if ($null -ne $secretMaskModule) {
    try {
        $secretMaskSetResult = & $secretMaskModule {
            param($secretByTarget, $targetsConfig, $payload, $throwTarget)
            # Кожен сценарій стартує з порожнім реєстром раніше прочитаних секретів
            # BRAVO.Credentials: модуль спільний, і значення з попередніх сценаріїв
            # інакше маскували б усе й ховали б регресії (false pass).
            $script:BRAVOCredentialReadSecretRegistry = $null
            $script:secretMaskTestState = [pscustomobject]@{
                LogLines = (New-Object System.Collections.Generic.List[string]); ReadTargets = (New-Object System.Collections.Generic.List[string])
                Uploads = (New-Object System.Collections.Generic.List[object]); SecretByTarget = $secretByTarget
                ThrowTargets = @($throwTarget); CorruptTargets = @(); ExceptionPayload = $payload; RangeIdLogPath = ''; ConnectCalls = 0
            }
            Get-BRAVOLogMaskSecretSet -CredentialSettings @{ Targets = $targetsConfig }
        } $secretMaskSetSecrets $secretMaskTargetsConfig ("leak " + $secretMaskSyntheticByKey['SFTPPassword']) $secretMask7zTarget
    } catch { $secretMaskSetError = $_.Exception.GetType().FullName }
}
$secretMaskSetValues = @()
$secretMaskSetSkipped = @()
if ($null -ne $secretMaskSetResult) {
    $secretMaskSetValues = @($secretMaskSetResult.Secrets)
    $secretMaskSetSkipped = @($secretMaskSetResult.Skipped)
}
$secretMaskSetMissingKeys = New-Object System.Collections.Generic.List[string]
foreach ($secretMaskKey in @('SFTPPassword', 'SMBPassword', 'OperationsBootstrapSecret', 'OperationsApiKey', 'SlackWebhookGeneral', 'SlackWebhookAlerts', 'DiscordWebhookGeneral')) {
    if ($secretMaskSetValues -cnotcontains [string]$secretMaskSyntheticByKey[$secretMaskKey]) { $secretMaskSetMissingKeys.Add($secretMaskKey) }
}
Test-BRAVOCondition (
    $null -ne $secretMaskSetResult -and $secretMaskSetMissingKeys.Count -eq 0
) -Name 'Credentials/LogMaskSecretSetCoversEverySupportedTarget' `
    -Failure "Get-BRAVOLogMaskSecretSet має повертати значення КОЖНОГО підтримуваного target-а (SFTP/SMB/Operations x2/webhook x4) через канонічний resolver; бракує ключів: $($secretMaskSetMissingKeys -join ', '); помилка: $secretMaskSetError"

$secretMaskSkippedTargets = @($secretMaskSetSkipped | ForEach-Object { [string]$_.Target })
$secretMaskSkippedText = (@($secretMaskSetSkipped | ForEach-Object { "$($_.Target)=$($_.Reason)" }) -join '; ')
$secretMaskSkippedLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text $secretMaskSkippedText -SecretByKey $secretMaskSyntheticByKey)
Test-BRAVOCondition (
    $null -ne $secretMaskSetResult -and
    $secretMaskSkippedTargets -contains $secretMask7zTarget -and
    $secretMaskSkippedTargets -contains 'BRAVO_DISCORD_ALERTS_URL' -and
    $secretMaskSetValues -cnotcontains [string]$secretMaskSyntheticByKey['ArchivePassword'] -and
    $secretMaskSkippedLeaks.Count -eq 0 -and
    $secretMaskSkippedText -notmatch 'synthetic CredRead failure'
) -Name 'Credentials/LogMaskSecretSetSkipsMissingAndInaccessibleTargetsWithoutLeak' `
    -Failure "відсутній target і недоступний (CredRead кидає) мають потрапляти у Skipped з причиною, яка не містить тексту винятку і жодного секрету; skipped=$($secretMaskSkippedTargets -join ', '); витекли ключі: $($secretMaskSkippedLeaks -join ', '); помилка: $secretMaskSetError"

# --- (8) Інтеграція: вивантажені БАЙТИ власного логу не містять жодного
# секрету, remote-ім'я незмінне, локальний лог не переписано, тимчасова
# маскована копія прибрана.
$secretMaskUploadResult = $null
if ($null -ne $secretMaskUploadModule) {
    $secretMaskUploadResult = Invoke-BRAVOSelfTestSecretMaskScenario -Module $secretMaskUploadModule `
        -LogFilePath $secretMaskLogFile -SecretByTarget $secretMaskSecretByTarget -TargetsConfig $secretMaskTargetsConfig
}
$secretMaskMainUpload = $null
if ($null -ne $secretMaskUploadResult) {
    $secretMaskMainUpload = @($secretMaskUploadResult.Uploads | Where-Object { [string]$_.RemoteFinalPath -eq "/logs/maintenance/$secretMaskLogName" }) | Select-Object -First 1
}
$secretMaskMainLeaks = @()
if ($null -ne $secretMaskMainUpload) { $secretMaskMainLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text ([string]$secretMaskMainUpload.Text) -SecretByKey $secretMaskSyntheticByKey) }
$secretMaskLocalAfterBytes = [IO.File]::ReadAllBytes($secretMaskLogFile)
Test-BRAVOCondition (
    $null -ne $secretMaskMainUpload -and
    $secretMaskMainLeaks.Count -eq 0 -and
    ([string]$secretMaskMainUpload.Text).Contains('value *** observed for ArchivePassword') -and
    ([string]$secretMaskMainUpload.Text).Contains('кирилиця має пережити маскування') -and
    ([string]$secretMaskMainUpload.Text).StartsWith([string][char]0xFEFF)
) -Name 'Maintenance/OwnLogUploadMasksEveryCredentialSecretInUploadedBytes' `
    -Failure "байти власного логу, що йдуть на SFTP, мають містити *** замість точного значення КОЖНОГО секрету Credential Manager (без keyword-а поруч), зберігши UTF-8 BOM і кирилицю; upload знайдено: $($null -ne $secretMaskMainUpload); витекли ключі: $($secretMaskMainLeaks -join ', '); помилка: $secretMaskSetupError"

Test-BRAVOCondition (
    $null -ne $secretMaskUploadResult -and
    $null -ne $secretMaskMainUpload -and
    [string]$secretMaskMainUpload.LocalPath -ne $secretMaskLogFile -and
    [int]$secretMaskUploadResult.LeftoverCopies -eq 0 -and
    [Convert]::ToBase64String($secretMaskLocalAfterBytes) -ceq [Convert]::ToBase64String($secretMaskLogOriginalBytes)
) -Name 'Maintenance/OwnLogUploadMasksTemporaryCopyNotLocalLog' `
    -Failure "маскування застосовується до тимчасової копії, яку й вивантажено (не до живого шляху), локальний лог лишається байт-у-байт незмінним, копія прибирається після передачі; помилка: $secretMaskSetupError"

# --- (9) SYSTEM-недоступний target: вивантаження відбувається, target
# пропущено з INFO (без WARNING), решта секретів замаскована, а жоден
# рядок діагностики не містить секрету — навіть коли текст винятку його
# несе.
$secretMaskInaccessibleResult = $null
if ($null -ne $secretMaskUploadModule) {
    $secretMaskInaccessibleResult = Invoke-BRAVOSelfTestSecretMaskScenario -Module $secretMaskUploadModule `
        -LogFilePath $secretMaskLogFile -SecretByTarget $secretMaskSecretByTarget -TargetsConfig $secretMaskTargetsConfig `
        -ThrowTargets @('BRAVO_OPERATIONS_BOOTSTRAP_SECRET') -ExceptionPayload ("carrying " + $secretMaskSyntheticByKey['ArchivePassword'])
}
$secretMaskInaccessibleUpload = $null
$secretMaskInaccessibleLines = @()
if ($null -ne $secretMaskInaccessibleResult) {
    $secretMaskInaccessibleUpload = @($secretMaskInaccessibleResult.Uploads | Where-Object { [string]$_.RemoteFinalPath -eq "/logs/maintenance/$secretMaskLogName" }) | Select-Object -First 1
    $secretMaskInaccessibleLines = @($secretMaskInaccessibleResult.LogLines)
}
$secretMaskInaccessibleOtherKeys = [ordered]@{}
foreach ($secretMaskKey in @($secretMaskSyntheticByKey.Keys)) {
    if ($secretMaskKey -ne 'OperationsBootstrapSecret') { $secretMaskInaccessibleOtherKeys[$secretMaskKey] = $secretMaskSyntheticByKey[$secretMaskKey] }
}
$secretMaskInaccessibleUploadLeaks = @()
if ($null -ne $secretMaskInaccessibleUpload) { $secretMaskInaccessibleUploadLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text ([string]$secretMaskInaccessibleUpload.Text) -SecretByKey $secretMaskInaccessibleOtherKeys) }
$secretMaskInfoLines = @($secretMaskInaccessibleLines | Where-Object { $_.StartsWith('[INFO]') -and $_.Contains('BRAVO_OPERATIONS_BOOTSTRAP_SECRET') })
$secretMaskWarningLines = @($secretMaskInaccessibleLines | Where-Object { $_.StartsWith('[WARNING]') -or $_.StartsWith('[ERROR]') })
Test-BRAVOCondition (
    $null -ne $secretMaskInaccessibleUpload -and
    $secretMaskInaccessibleUploadLeaks.Count -eq 0 -and
    $secretMaskInfoLines.Count -ge 1 -and
    $secretMaskWarningLines.Count -eq 0 -and
    [string]::IsNullOrEmpty([string]$secretMaskInaccessibleResult.InvokeError)
) -Name 'Maintenance/OwnLogUploadInaccessibleTargetSkippedWithInfoOthersMasked' `
    -Failure "недоступний під SYSTEM target не ламає вивантаження: INFO з іменем target-а, жодного WARNING/ERROR, решта секретів замаскована; upload: $($null -ne $secretMaskInaccessibleUpload); INFO: $($secretMaskInfoLines.Count); WARNING/ERROR: $($secretMaskWarningLines.Count); витекли ключі: $($secretMaskInaccessibleUploadLeaks -join ', '); помилка: $secretMaskSetupError"

$secretMaskDiagnosticText = ($secretMaskInaccessibleLines -join "`n") + "`n" + [string]$(if ($null -ne $secretMaskInaccessibleResult) { $secretMaskInaccessibleResult.InvokeError } else { '' })
$secretMaskDiagnosticLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text $secretMaskDiagnosticText -SecretByKey $secretMaskSyntheticByKey)
Test-BRAVOCondition (
    $null -ne $secretMaskInaccessibleResult -and
    $secretMaskDiagnosticLeaks.Count -eq 0 -and
    $secretMaskDiagnosticText -notmatch 'synthetic CredRead failure'
) -Name 'Maintenance/OwnLogUploadDiagnosticsNeverContainSecret' `
    -Failure "рядки INFO/WARNING і винятки шляху маскування не повинні містити жодного секрету чи переказаного тексту винятку CredRead; витекли ключі: $($secretMaskDiagnosticLeaks -join ', '); помилка: $secretMaskSetupError"

# --- (10) Знімок range_id_log.json — теж лог, що йде на SFTP: маскується.
$secretMaskRangeIdFile = Join-Path $secretMaskTestRoot 'range_id_log.json'
[IO.File]::WriteAllText($secretMaskRangeIdFile, ('{"note":"' + $secretMaskSyntheticByKey['OperationsApiKey'] + '","r":1}'), (New-Object Text.UTF8Encoding($false)))
$secretMaskRangeIdResult = $null
if ($null -ne $secretMaskUploadModule) {
    $secretMaskRangeIdResult = Invoke-BRAVOSelfTestSecretMaskScenario -Module $secretMaskUploadModule `
        -LogFilePath $secretMaskLogFile -SecretByTarget $secretMaskSecretByTarget -TargetsConfig $secretMaskTargetsConfig `
        -RangeIdLogPath $secretMaskRangeIdFile
}
$secretMaskRangeIdUpload = $null
if ($null -ne $secretMaskRangeIdResult) {
    $secretMaskRangeIdUpload = @($secretMaskRangeIdResult.Uploads | Where-Object { [string]$_.RemoteFinalPath -eq '/logs/maintenance/range_id_log_selftest_365_run.json' }) | Select-Object -First 1
}
Test-BRAVOCondition (
    $null -ne $secretMaskRangeIdUpload -and
    [string]$secretMaskRangeIdUpload.Text -ceq '{"note":"***","r":1}' -and
    [int]$secretMaskRangeIdResult.LeftoverCopies -eq 0
) -Name 'Maintenance/OwnLogUploadRangeIdSnapshotAlsoMasked' `
    -Failure "знімок range_id_log.json, що вивантажується на SFTP, теж має йти маскованою копією (без BOM, якщо його не було) і прибиратись після; помилка: $secretMaskSetupError"

# --- (11) Fail-closed: якщо масковану копію неможливо створити (файл
# заблоковано), лог НЕ вивантажується немаскованим; прогін не падає.
$secretMaskLockedResult = $null
if ($null -ne $secretMaskUploadModule) {
    $secretMaskLockedResult = Invoke-BRAVOSelfTestSecretMaskScenario -Module $secretMaskUploadModule `
        -LogFilePath $secretMaskLogFile -SecretByTarget $secretMaskSecretByTarget -TargetsConfig $secretMaskTargetsConfig `
        -LockLogFile $true
}
$secretMaskLockedUploads = @()
$secretMaskLockedLines = @()
if ($null -ne $secretMaskLockedResult) {
    $secretMaskLockedUploads = @($secretMaskLockedResult.Uploads | ForEach-Object { $_ })
    $secretMaskLockedLines = @($secretMaskLockedResult.LogLines)
}
$secretMaskLockedLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text ($secretMaskLockedLines -join "`n") -SecretByKey $secretMaskSyntheticByKey)
Test-BRAVOCondition (
    $null -ne $secretMaskLockedResult -and
    $secretMaskLockedUploads.Count -eq 0 -and
    @($secretMaskLockedLines | Where-Object { $_.StartsWith('[WARNING]') }).Count -ge 1 -and
    $secretMaskLockedLeaks.Count -eq 0 -and
    [string]::IsNullOrEmpty([string]$secretMaskLockedResult.InvokeError)
) -Name 'Maintenance/OwnLogUploadFailsClosedWhenMaskedCopyUnavailable' `
    -Failure "збій маскування (копію не створено) — fail-closed: жодної передачі немаскованого логу, WARNING без секретів, виняток назовні не йде; uploads=$($secretMaskLockedUploads.Count); помилка: $secretMaskSetupError"

# ============================================================
# #365 review (P2): секрет, прочитаний РАНІШЕ в цьому ж процесі, лишається
# в наборі маскування, навіть якщо до моменту вивантаження запис змінили
# (ротація BRAVO_7Z_PASSWORD під час довгого Archive), видалили (Operations
# видаляє API-ключ на 401) або він став нечитабельним. Перечитування лише в
# момент вивантаження дає тільки ПОТОЧНЕ значення — старе, яке вже могло
# потрапити в журнал, вивантажилось би як є.
# Кожен сценарій — у власному свіжому модулі (окремий "процес").
# ============================================================
$secretMaskEarlyFunctions = $secretMaskCredentialReadChain + @('Get-BRAVOCredentialTargetName', 'Get-BRAVOLogMaskSecretSet')
$secretMaskEarlyByKey = [ordered]@{
    ArchivePasswordBeforeRotation = (& $secretMaskNewValue 'Arch7zOld!')
    ArchivePasswordAfterRotation  = (& $secretMaskNewValue 'Arch7zNew!')
    SMBPasswordDeletedMidRun      = (& $secretMaskNewValue 'SmbOld#')
    OperationsApiKeyUnreadable    = (& $secretMaskNewValue 'opsOld-')
}
$secretMaskEarlyResult = $null
$secretMaskEarlyError = ''
try {
    $secretMaskEarlyModule = New-BRAVOSelfTestRuntimeModule -SourceText $secretMaskSourceText -FunctionNames $secretMaskEarlyFunctions
    $secretMaskEarlyResult = & $secretMaskEarlyModule {
        param($targetsConfig, $early)
        $credentialSettings = @{ Targets = $targetsConfig }
        $sevenZipTarget = Get-BRAVOCredentialTargetName -CredentialSettings $credentialSettings -Key 'ArchivePassword'
        $smbTarget = Get-BRAVOCredentialTargetName -CredentialSettings $credentialSettings -Key 'SMBPassword'
        $opsApiTarget = Get-BRAVOCredentialTargetName -CredentialSettings $credentialSettings -Key 'OperationsApiKey'
        $secretByTarget = @{}
        $secretByTarget[$sevenZipTarget] = $early['ArchivePasswordBeforeRotation']
        $secretByTarget[$smbTarget] = $early['SMBPasswordDeletedMidRun']
        $secretByTarget[$opsApiTarget] = $early['OperationsApiKeyUnreadable']
        $script:secretMaskTestState = [pscustomobject]@{
            LogLines = (New-Object System.Collections.Generic.List[string]); ReadTargets = (New-Object System.Collections.Generic.List[string])
            Uploads = (New-Object System.Collections.Generic.List[object]); SecretByTarget = $secretByTarget
            ThrowTargets = @(); CorruptTargets = @(); ExceptionPayload = ''; RangeIdLogPath = ''; ConnectCalls = 0
        }
        # Раніше в прогоні runtime читає секрети справжніми getter-ами:
        # плейнтекстовим (7-Zip, API-ключ) і SecureString-шляхом (SMB).
        [void](Get-BRAVOCredentialSecret -Target $sevenZipTarget)
        [void](Get-BRAVOCredentialSecret -Target $opsApiTarget)
        [void](Get-BRAVOCredentialSecureSecret -Target $smbTarget)
        # До вивантаження: 7-Zip ротовано, SMB видалено, API-ключ нечитабельний.
        $secretByTarget[$sevenZipTarget] = $early['ArchivePasswordAfterRotation']
        $secretByTarget.Remove($smbTarget)
        $script:secretMaskTestState.ThrowTargets = @($opsApiTarget)
        Get-BRAVOLogMaskSecretSet -CredentialSettings $credentialSettings
    } $secretMaskTargetsConfig $secretMaskEarlyByKey
} catch { $secretMaskEarlyError = $_.Exception.GetType().FullName }
$secretMaskEarlyValues = @()
$secretMaskEarlySkippedText = ''
if ($null -ne $secretMaskEarlyResult) {
    $secretMaskEarlyValues = @($secretMaskEarlyResult.Secrets)
    $secretMaskEarlySkippedText = (@($secretMaskEarlyResult.Skipped | ForEach-Object { "$($_.Target)=$($_.Reason)" }) -join '; ')
}
$secretMaskEarlyMissing = New-Object System.Collections.Generic.List[string]
foreach ($secretMaskKey in @($secretMaskEarlyByKey.Keys)) {
    if ($secretMaskEarlyValues -cnotcontains [string]$secretMaskEarlyByKey[$secretMaskKey]) { $secretMaskEarlyMissing.Add($secretMaskKey) }
}
$secretMaskEarlyDistinct = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach ($secretMaskEarlyValue in $secretMaskEarlyValues) { [void]$secretMaskEarlyDistinct.Add([string]$secretMaskEarlyValue) }
$secretMaskEarlySkippedLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text $secretMaskEarlySkippedText -SecretByKey $secretMaskEarlyByKey)
Test-BRAVOCondition (
    $null -ne $secretMaskEarlyResult -and
    $secretMaskEarlyMissing.Count -eq 0 -and
    $secretMaskEarlyDistinct.Count -eq $secretMaskEarlyValues.Count -and
    $secretMaskEarlySkippedLeaks.Count -eq 0
) -Name 'Credentials/LogMaskSecretSetIncludesSecretsReadEarlierInProcess' `
    -Failure "Get-BRAVOLogMaskSecretSet має містити КОЖНЕ значення, яке справжні getter-и повернули раніше в цьому процесі (ротований/видалений/нечитабельний на момент вивантаження запис), плюс поточне — без дублікатів; бракує: $($secretMaskEarlyMissing -join ', '); значень: $($secretMaskEarlyValues.Count), унікальних: $($secretMaskEarlyDistinct.Count); Skipped витекли: $($secretMaskEarlySkippedLeaks -join ', '); помилка: $secretMaskEarlyError"

# --- #365 review (P2): лише збій САМОГО читання Credential Manager дає
# пропуск target-а. Збій ПІСЛЯ успішного CredRead (тут — перетворення
# значення на рядок) має вийти назовні, щоб викликач нічого не вивантажив
# (fail-closed), а не тихо продовжив без цього секрету в наборі.
$secretMaskPropagateResult = $null
$secretMaskPropagateError = ''
try {
    $secretMaskPropagateModule = New-BRAVOSelfTestRuntimeModule -SourceText $secretMaskSourceText -FunctionNames $secretMaskEarlyFunctions
    $secretMaskPropagateResult = & $secretMaskPropagateModule {
        param($secretByTarget, $targetsConfig, $corruptTarget)
        $script:secretMaskTestState = [pscustomobject]@{
            LogLines = (New-Object System.Collections.Generic.List[string]); ReadTargets = (New-Object System.Collections.Generic.List[string])
            Uploads = (New-Object System.Collections.Generic.List[object]); SecretByTarget = $secretByTarget
            ThrowTargets = @(); CorruptTargets = @($corruptTarget); ExceptionPayload = ''; RangeIdLogPath = ''; ConnectCalls = 0
        }
        try {
            $maskSet = Get-BRAVOLogMaskSecretSet -CredentialSettings @{ Targets = $targetsConfig }
            [pscustomobject]@{ Threw = $false; SkippedText = (@($maskSet.Skipped | ForEach-Object { "$($_.Target)=$($_.Reason)" }) -join '; '); ErrorText = '' }
        } catch {
            [pscustomobject]@{ Threw = $true; SkippedText = ''; ErrorText = [string]$_.Exception.Message }
        }
    } $secretMaskSecretByTarget $secretMaskTargetsConfig $secretMask7zTarget
} catch { $secretMaskPropagateError = $_.Exception.GetType().FullName }
$secretMaskPropagateLeaks = @()
if ($null -ne $secretMaskPropagateResult) { $secretMaskPropagateLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text ([string]$secretMaskPropagateResult.ErrorText + [string]$secretMaskPropagateResult.SkippedText) -SecretByKey $secretMaskSyntheticByKey) }
Test-BRAVOCondition (
    $null -ne $secretMaskPropagateResult -and
    [bool]$secretMaskPropagateResult.Threw -and
    $secretMaskPropagateLeaks.Count -eq 0
) -Name 'Credentials/LogMaskSecretSetPropagatesNonReadFailure' `
    -Failure "збій після успішного CredRead (не саме читання) має виходити з Get-BRAVOLogMaskSecretSet винятком, а не перетворюватися на тихий пропуск target-а; виняток: $(if ($null -ne $secretMaskPropagateResult) { [bool]$secretMaskPropagateResult.Threw } else { 'n/a' }); skipped: $(if ($null -ne $secretMaskPropagateResult) { [string]$secretMaskPropagateResult.SkippedText } else { '' }); витекли ключі: $($secretMaskPropagateLeaks -join ', '); помилка: $secretMaskPropagateError"

# Інтеграція того самого: Maintenance нічого не вивантажує, пише WARNING
# без секретів, виняток назовні не йде (exit code не чіпається — див.
# Maintenance/OwnLogUploadNeverAssignsRuntimeExitCode).
$secretMaskSetFailResult = $null
if ($null -ne $secretMaskUploadModule) {
    $secretMaskSetFailResult = Invoke-BRAVOSelfTestSecretMaskScenario -Module $secretMaskUploadModule `
        -LogFilePath $secretMaskLogFile -SecretByTarget $secretMaskSecretByTarget -TargetsConfig $secretMaskTargetsConfig `
        -CorruptTargets @($secretMask7zTarget)
}
$secretMaskSetFailUploads = @()
$secretMaskSetFailLines = @()
if ($null -ne $secretMaskSetFailResult) {
    $secretMaskSetFailUploads = @($secretMaskSetFailResult.Uploads | ForEach-Object { $_ })
    $secretMaskSetFailLines = @($secretMaskSetFailResult.LogLines)
}
$secretMaskSetFailLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text ($secretMaskSetFailLines -join "`n") -SecretByKey $secretMaskSyntheticByKey)
Test-BRAVOCondition (
    $null -ne $secretMaskSetFailResult -and
    $secretMaskSetFailUploads.Count -eq 0 -and
    @($secretMaskSetFailLines | Where-Object { $_.StartsWith('[WARNING]') }).Count -ge 1 -and
    $secretMaskSetFailLeaks.Count -eq 0 -and
    [string]::IsNullOrEmpty([string]$secretMaskSetFailResult.InvokeError)
) -Name 'Maintenance/OwnLogUploadFailsClosedWhenSecretSetFails' `
    -Failure "збій збирання набору секретів (не CredRead) — fail-closed: жодної передачі, WARNING без секретів, виняток назовні не йде; uploads=$($secretMaskSetFailUploads.Count); витекли ключі: $($secretMaskSetFailLeaks -join ', '); помилка: $secretMaskSetupError"

# ============================================================
# #417: облік секретів процесу (реєстр BRAVO.Credentials) ізольований від
# самого читання і доповнюється записами Set-BRAVOCredential.
# (а) значення, записане Set-BRAVOCredential у цьому процесі (Operations
#     зберігає API-ключ під час Maintenance), маскується навіть тоді, коли
#     пізніший CredRead у Get-BRAVOLogMaskSecretSet падає;
# (б) збій обліку не ламає звичайне читання секрету, але робить набір
#     маскування неповним -> Get-BRAVOLogMaskSecretSet кидає (fail-closed);
# (в) на цьому fail-closed шляху власний лог не вивантажується, а
#     діагностика не переказує ні секрет, ні текст первинного винятку.
# Межі: CredWrite ([BRAVO.Security.CredentialManager]::WriteGeneric —
# у тексті Set-BRAVOCredential замінюється на тестовий записувач) і CredRead
# (Get-BRAVOCredential). Решта — справжній production-код. Збій обліку
# імітується пошкодженим реєстром модуля: його TryGetValue кидає виняток,
# у повідомленні якого — синтетичний секрет.
# Кожен сценарій — у власному свіжому модулі (окремий "процес").
# ============================================================
$secretMask417ByKey = [ordered]@{
    OperationsApiKeyWritten = (& $secretMaskNewValue 'opsW-')
    SftpReadDuringFailure   = (& $secretMaskNewValue 'SftpR')
    RegistryFailurePayload  = (& $secretMaskNewValue 'RegX')
}
$secretMask417LeakByKey = [ordered]@{}
foreach ($secretMaskKey in @($secretMaskSyntheticByKey.Keys)) { $secretMask417LeakByKey[$secretMaskKey] = $secretMaskSyntheticByKey[$secretMaskKey] }
foreach ($secretMaskKey in @($secretMask417ByKey.Keys)) { $secretMask417LeakByKey[$secretMaskKey] = $secretMask417ByKey[$secretMaskKey] }

# Тестовий записувач замість CredWrite: фіксує лише target, значення в
# SecretByTarget НЕ потрапляє (пізніший CredRead його не поверне). Заміна
# має відбутися рівно один раз — інакше справжній CredWrite лишився б
# досяжним, і сценарій не запускається взагалі.
$secretMask417WriteBoundary = '[BRAVO.Security.CredentialManager]::WriteGeneric('
$secretMask417WriteBoundaryCount = @([regex]::Matches($secretMaskCredentialsText, [regex]::Escape($secretMask417WriteBoundary))).Count
$secretMask417WriteStub = @'
function Initialize-BRAVOCredentialManager { }
'@
$secretMask417WriterExpression = '$script:secretMaskTestState.CredentialWriter'
$secretMask417WriteSourceText = $secretMask417WriteStub + "`n" + $secretMaskStub + "`n" +
    $secretMaskCredentialsText.Replace($secretMask417WriteBoundary, $secretMask417WriterExpression + '.WriteGeneric(')

function Get-BRAVOSelfTest417CredWriteGuardProblem {
    # Безпековий gate перед запуском будь-якого сценарію з Set-BRAVOCredential:
    # після заміни межі CredWrite розбирає (AST) саме ті визначення, які
    # потраплять у тестовий модуль (перше визначення кожного імені — як у
    # New-BRAVOSelfTestRuntimeModule), і перевіряє, що справжній запис у
    # Credential Manager недосяжний. Повертає список проблем; порожній —
    # сценарій можна виконувати.
    param(
        [Parameter(Mandatory = $true)][string]$SourceText,
        [Parameter(Mandatory = $true)][string[]]$ModuleFunctionNames,
        [Parameter(Mandatory = $true)][string]$WriterExpressionText
    )
    $problems = New-Object System.Collections.Generic.List[string]
    $guardTokens = $null
    $guardErrors = $null
    $guardAst = [System.Management.Automation.Language.Parser]::ParseInput($SourceText, [ref]$guardTokens, [ref]$guardErrors)
    if (@($guardErrors).Count -gt 0) {
        $problems.Add("підставлений текст не розбирається ($(@($guardErrors).Count) помилок)")
        return $problems.ToArray()
    }
    $allDefinitions = @($guardAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    $setDefinitions = @($allDefinitions | Where-Object { $_.Name -eq 'Set-BRAVOCredential' })
    if ($setDefinitions.Count -ne 1) {
        $problems.Add("визначень Set-BRAVOCredential: $($setDefinitions.Count) (очікується 1)")
        return $problems.ToArray()
    }
    $setAst = $setDefinitions[0]
    # (1) Рівно один виклик тестового записувача і жодного іншого WriteGeneric.
    $writeCalls = @($setAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
        Where-Object { [string]$_.Member.Extent.Text -ieq 'WriteGeneric' })
    $stubWriteCalls = @($writeCalls | Where-Object { -not $_.Static -and [string]$_.Expression.Extent.Text -ceq $WriterExpressionText })
    if ($writeCalls.Count -ne 1 -or $stubWriteCalls.Count -ne 1) {
        $problems.Add("викликів WriteGeneric у Set-BRAVOCredential: $($writeCalls.Count), з них тестового записувача: $($stubWriteCalls.Count) (очікується 1 і 1)")
    }
    $stubCallTextCount = @([regex]::Matches($setAst.Extent.Text, [regex]::Escape($WriterExpressionText + '.WriteGeneric('))).Count
    if ($stubCallTextCount -ne 1) {
        $problems.Add("текст виклику тестового записувача у Set-BRAVOCredential трапляється $stubCallTextCount раз(ів) (очікується 1)")
    }
    # (2) Жодного посилання на справжній CredentialManager і жодного Add-Type
    # у кожному визначенні, що потрапить у модуль.
    foreach ($moduleFunctionName in $ModuleFunctionNames) {
        $firstDefinition = @($allDefinitions | Where-Object { $_.Name -eq $moduleFunctionName } | Select-Object -First 1)
        if ($firstDefinition.Count -ne 1) {
            $problems.Add("визначення $moduleFunctionName не знайдено")
            continue
        }
        # Текст визначення без коментарів (коментар-пояснення межі в
        # заглушці CredRead не є посиланням).
        $definitionStart = $firstDefinition[0].Extent.StartOffset
        $definitionEnd = $firstDefinition[0].Extent.EndOffset
        $definitionCodeText = (@($guardTokens | Where-Object {
                    $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment -and
                    $_.Extent.StartOffset -ge $definitionStart -and $_.Extent.EndOffset -le $definitionEnd
                } | ForEach-Object { $_.Text }) -join ' ')
        if ($definitionCodeText -match '(?i)BRAVO\.Security\.CredentialManager') {
            $problems.Add("$moduleFunctionName посилається на [BRAVO.Security.CredentialManager]")
        }
        $credentialManagerTypes = @($firstDefinition[0].FindAll({
                    param($node)
                    ($node -is [System.Management.Automation.Language.TypeExpressionAst] -or $node -is [System.Management.Automation.Language.TypeConstraintAst]) -and
                    [string]$node.TypeName.FullName -match '(?i)CredentialManager'
                }, $true))
        if ($credentialManagerTypes.Count -gt 0) {
            $problems.Add("$moduleFunctionName містить тип CredentialManager")
        }
        $addTypeCalls = @($firstDefinition[0].FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and [string]$node.GetCommandName() -ieq 'Add-Type' }, $true))
        if ($addTypeCalls.Count -gt 0) {
            $problems.Add("$moduleFunctionName викликає Add-Type")
        }
    }
    # (3) Set-BRAVOCredential викликає лише команди з переліку модуля
    # (інакше ім'я розв'язалося б у сесії поза модулем).
    foreach ($setCommand in @($setAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        $setCommandName = $setCommand.GetCommandName()
        if ([string]::IsNullOrEmpty($setCommandName)) {
            $problems.Add('Set-BRAVOCredential містить динамічний виклик команди')
        } elseif (-not ($ModuleFunctionNames -contains $setCommandName)) {
            $problems.Add("Set-BRAVOCredential викликає команду поза переліком модуля: $setCommandName")
        }
    }
    return $problems.ToArray()
}

$secretMask417WrittenFunctionNames = @($secretMaskEarlyFunctions + @('Initialize-BRAVOCredentialManager', 'Set-BRAVOCredential'))
$secretMask417WrittenGuardProblems = @(Get-BRAVOSelfTest417CredWriteGuardProblem -SourceText $secretMask417WriteSourceText `
        -ModuleFunctionNames $secretMask417WrittenFunctionNames -WriterExpressionText $secretMask417WriterExpression)

$secretMask417WrittenResult = $null
$secretMask417WrittenError = ''
if ($secretMask417WriteBoundaryCount -eq 1 -and $secretMask417WrittenGuardProblems.Count -eq 0) {
    try {
        $secretMask417WrittenModule = New-BRAVOSelfTestRuntimeModule -SourceText $secretMask417WriteSourceText `
            -FunctionNames $secretMask417WrittenFunctionNames
        $secretMask417WrittenResult = & $secretMask417WrittenModule {
            param($targetsConfig, $writtenValue)
            $credentialSettings = @{ Targets = $targetsConfig }
            $opsApiTarget = Get-BRAVOCredentialTargetName -CredentialSettings $credentialSettings -Key 'OperationsApiKey'
            $writer = New-Object psobject
            Add-Member -InputObject $writer -MemberType NoteProperty -Name Calls -Value (New-Object System.Collections.Generic.List[string])
            Add-Member -InputObject $writer -MemberType ScriptMethod -Name WriteGeneric -Value {
                param($target, $userName, $secret)
                [void]$this.Calls.Add([string]$target)
            }
            # CredRead для API-ключа падає (SYSTEM без доступу тощо).
            $script:secretMaskTestState = [pscustomobject]@{
                LogLines = (New-Object System.Collections.Generic.List[string]); ReadTargets = (New-Object System.Collections.Generic.List[string])
                Uploads = (New-Object System.Collections.Generic.List[object]); SecretByTarget = @{}
                ThrowTargets = @($opsApiTarget); CorruptTargets = @(); ExceptionPayload = ''; RangeIdLogPath = ''; ConnectCalls = 0
                CredentialWriter = $writer
            }
            $writtenSecure = New-Object System.Security.SecureString
            foreach ($writtenChar in $writtenValue.ToCharArray()) { $writtenSecure.AppendChar($writtenChar) }
            $writtenSecure.MakeReadOnly()
            Set-BRAVOCredential -Target $opsApiTarget -Secret $writtenSecure
            $maskSet = Get-BRAVOLogMaskSecretSet -CredentialSettings $credentialSettings
            [pscustomobject]@{
                Secrets      = [string[]]@($maskSet.Secrets)
                SkippedText  = (@($maskSet.Skipped | ForEach-Object { "$($_.Target)=$($_.Reason)" }) -join '; ')
                WriteCalls   = [string[]]$writer.Calls.ToArray()
                OpsApiTarget = $opsApiTarget
            }
        } $secretMaskTargetsConfig ([string]$secretMask417ByKey['OperationsApiKeyWritten'])
    } catch { $secretMask417WrittenError = $_.Exception.GetType().FullName }
} else {
    # Сценарій НЕ виконується: справжній CredWrite міг би лишитися досяжним.
    $secretMask417WrittenError = "сценарій не виконано: межа CredWrite у тексті модуля — $secretMask417WriteBoundaryCount раз(ів) (очікується 1); проблеми AST-перевірки заміни: $($secretMask417WrittenGuardProblems -join '; ')"
}
$secretMask417WrittenSecrets = @()
$secretMask417WrittenCalls = @()
$secretMask417WrittenLeaks = @()
if ($null -ne $secretMask417WrittenResult) {
    $secretMask417WrittenSecrets = @($secretMask417WrittenResult.Secrets)
    $secretMask417WrittenCalls = @($secretMask417WrittenResult.WriteCalls)
    $secretMask417WrittenLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text ([string]$secretMask417WrittenResult.SkippedText) -SecretByKey $secretMask417LeakByKey)
}
Test-BRAVOCondition (
    $null -ne $secretMask417WrittenResult -and
    $secretMask417WrittenCalls.Count -eq 1 -and
    [string]$secretMask417WrittenCalls[0] -eq [string]$secretMask417WrittenResult.OpsApiTarget -and
    $secretMask417WrittenSecrets -ccontains [string]$secretMask417ByKey['OperationsApiKeyWritten'] -and
    $secretMask417WrittenLeaks.Count -eq 0
) -Name 'Credentials/LogMaskSecretSetIncludesSecretsWrittenInProcess' `
    -Failure "значення, записане Set-BRAVOCredential у цьому процесі, має бути в наборі маскування навіть коли пізніший CredRead того самого target-а падає; викликів CredWrite: $($secretMask417WrittenCalls.Count); значень у наборі: $($secretMask417WrittenSecrets.Count); записане значення в наборі: $($secretMask417WrittenSecrets -ccontains [string]$secretMask417ByKey['OperationsApiKeyWritten']); Skipped витекли: $($secretMask417WrittenLeaks -join ', '); помилка: $secretMask417WrittenError"

# --- (б) збій обліку: читання успішне, набір маскування — fail-closed.
$secretMask417BookkeepingResult = $null
$secretMask417BookkeepingError = ''
try {
    $secretMask417BookkeepingModule = New-BRAVOSelfTestRuntimeModule -SourceText $secretMaskSourceText -FunctionNames $secretMaskEarlyFunctions
    $secretMask417BookkeepingResult = & $secretMask417BookkeepingModule {
        param($targetsConfig, $readValue, $payload)
        $credentialSettings = @{ Targets = $targetsConfig }
        $sftpTarget = Get-BRAVOCredentialTargetName -CredentialSettings $credentialSettings -Key 'SFTPPassword'
        $secretByTarget = @{}
        $secretByTarget[$sftpTarget] = $readValue
        $script:secretMaskTestState = [pscustomobject]@{
            LogLines = (New-Object System.Collections.Generic.List[string]); ReadTargets = (New-Object System.Collections.Generic.List[string])
            Uploads = (New-Object System.Collections.Generic.List[object]); SecretByTarget = $secretByTarget
            ThrowTargets = @(); CorruptTargets = @(); ExceptionPayload = ''; RangeIdLogPath = ''; ConnectCalls = 0
        }
        $failureText = 'synthetic registry bookkeeping failure ' + $payload
        $brokenRegistry = New-Object psobject
        Add-Member -InputObject $brokenRegistry -MemberType ScriptMethod -Name TryGetValue -Value ({ throw $failureText }.GetNewClosure())
        $script:BRAVOCredentialReadSecretRegistry = $brokenRegistry
        $readOut = $null
        $readErrorType = ''
        try { $readOut = Get-BRAVOCredentialSecret -Target $sftpTarget } catch { $readErrorType = $_.Exception.GetType().FullName }
        # Codex P1: пошкоджений реєстр ЛИШАЄТЬСЯ в стані модуля (як у
        # реальному процесі). Набір маскування має кинути фіксоване
        # повідомлення, а не виняток самого реєстру (у ньому — секрет).
        $maskThrew = $false
        $maskErrorText = ''
        try {
            [void](Get-BRAVOLogMaskSecretSet -CredentialSettings $credentialSettings)
        } catch {
            $maskThrew = $true
            $maskErrorText = [string]$_.Exception.Message + ' | ' + [string]$_
        }
        # Ознака неповноти знята, реєстр і далі пошкоджений: збій доступу до
        # реєстру в самому наборі маскування теж стає фіксованим
        # повідомленням (fail-closed), без тексту первинного винятку.
        $script:BRAVOCredentialReadSecretRegistryIncomplete = $false
        $maskThrewDirect = $false
        $maskErrorTextDirect = ''
        try {
            [void](Get-BRAVOLogMaskSecretSet -CredentialSettings $credentialSettings)
        } catch {
            $maskThrewDirect = $true
            $maskErrorTextDirect = [string]$_.Exception.Message + ' | ' + [string]$_
        }
        [pscustomobject]@{
            ReadValue = [string]$readOut; ReadErrorType = $readErrorType; MaskThrew = $maskThrew; MaskErrorText = $maskErrorText
            MaskThrewDirect = $maskThrewDirect; MaskErrorTextDirect = $maskErrorTextDirect
        }
    } $secretMaskTargetsConfig ([string]$secretMask417ByKey['SftpReadDuringFailure']) ([string]$secretMask417ByKey['RegistryFailurePayload'])
} catch { $secretMask417BookkeepingError = $_.Exception.GetType().FullName }
$secretMask417BookkeepingLeaks = @()
if ($null -ne $secretMask417BookkeepingResult) {
    $secretMask417BookkeepingLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text ([string]$secretMask417BookkeepingResult.MaskErrorText + "`n" + [string]$secretMask417BookkeepingResult.MaskErrorTextDirect) -SecretByKey $secretMask417LeakByKey)
}
Test-BRAVOCondition (
    $null -ne $secretMask417BookkeepingResult -and
    [string]$secretMask417BookkeepingResult.ReadValue -ceq [string]$secretMask417ByKey['SftpReadDuringFailure'] -and
    [string]::IsNullOrEmpty([string]$secretMask417BookkeepingResult.ReadErrorType) -and
    [bool]$secretMask417BookkeepingResult.MaskThrew -and
    [bool]$secretMask417BookkeepingResult.MaskThrewDirect -and
    ([string]$secretMask417BookkeepingResult.MaskErrorText).Contains('(#417)') -and
    ([string]$secretMask417BookkeepingResult.MaskErrorTextDirect).Contains('(#417)') -and
    -not ([string]$secretMask417BookkeepingResult.MaskErrorText).Contains('synthetic registry bookkeeping failure') -and
    -not ([string]$secretMask417BookkeepingResult.MaskErrorTextDirect).Contains('synthetic registry bookkeeping failure') -and
    $secretMask417BookkeepingLeaks.Count -eq 0
) -Name 'Credentials/RegistryBookkeepingFailureDoesNotBreakReadButFailsMaskSet' `
    -Failure "збій обліку прочитаних секретів не має ламати читання (getter повертає значення), але Get-BRAVOLogMaskSecretSet після цього має кидати (fail-closed) без секрету в повідомленні; читання повернуло значення: $(if ($null -ne $secretMask417BookkeepingResult) { [string]$secretMask417BookkeepingResult.ReadValue -ceq [string]$secretMask417ByKey['SftpReadDuringFailure'] } else { 'n/a' }); виняток читання: $(if ($null -ne $secretMask417BookkeepingResult) { [string]$secretMask417BookkeepingResult.ReadErrorType } else { 'n/a' }); набір кинув: $(if ($null -ne $secretMask417BookkeepingResult) { [bool]$secretMask417BookkeepingResult.MaskThrew } else { 'n/a' }); набір кинув за пошкодженого реєстру без ознаки: $(if ($null -ne $secretMask417BookkeepingResult) { [bool]$secretMask417BookkeepingResult.MaskThrewDirect } else { 'n/a' }); повідомлення фіксоване: $(if ($null -ne $secretMask417BookkeepingResult) { -not ([string]$secretMask417BookkeepingResult.MaskErrorText + [string]$secretMask417BookkeepingResult.MaskErrorTextDirect).Contains('synthetic registry bookkeeping failure') } else { 'n/a' }); витекли ключі: $($secretMask417BookkeepingLeaks -join ', '); помилка: $secretMask417BookkeepingError"

# --- (в) інтеграція: Invoke-BRAVOMaintenanceOwnLogUpload після збою обліку
# нічого не вивантажує, пише WARNING без секретів і без тексту первинного
# винятку, виняток назовні не йде.
$secretMask417UploadResult = $null
$secretMask417UploadError = $secretMaskSetupError
try {
    $secretMask417UploadModule = New-BRAVOSelfTestRuntimeModule -SourceText $secretMaskSourceText `
        -FunctionNames ($secretMaskBoundaryAndUploadFunctions + @(
            'Get-BRAVOCredentialTargetName', 'Get-BRAVOLogMaskSecretSet', 'Get-BRAVOArchivePasswordTarget',
            'Protect-BRAVOLogSecret', 'New-BRAVOMaskedLogCopy', 'Remove-BRAVOMaskedLogCopy',
            'Copy-BRAVOConfigurationGraphDeep', 'Get-BRAVODefaultConfiguration'
        ))
    $secretMask417UploadResult = & $secretMask417UploadModule {
        param($logFilePath, $secretByTarget, $targetsConfig, $payload)
        $script:secretMaskTestState = [pscustomobject]@{
            LogLines = (New-Object System.Collections.Generic.List[string]); ReadTargets = (New-Object System.Collections.Generic.List[string])
            Uploads = (New-Object System.Collections.Generic.List[object]); SecretByTarget = $secretByTarget
            ThrowTargets = @(); CorruptTargets = @(); ExceptionPayload = ''; RangeIdLogPath = ''; ConnectCalls = 0
        }
        $global:componentSettings = [pscustomobject]@{ SFTP = [pscustomobject]@{ MaintenanceLogUploadEnabled = $true } }
        $global:storageEffective = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $true } }
        $script:credentialSettings = @{ Targets = $targetsConfig }
        $script:sftpDirectories = [pscustomobject]@{ MaintenanceLog = 'logs/maintenance' }
        $script:LOG_FILE = $logFilePath
        $script:maintenanceLogRunId = 'selftest_417_run'
        $script:maintenanceOwnLogUploadAttempted = $false
        $sftpTarget = Get-BRAVOCredentialTargetName -CredentialSettings $script:credentialSettings -Key 'SFTPPassword'
        $failureText = 'synthetic registry bookkeeping failure ' + $payload
        $brokenRegistry = New-Object psobject
        Add-Member -InputObject $brokenRegistry -MemberType ScriptMethod -Name TryGetValue -Value ({ throw $failureText }.GetNewClosure())
        $script:BRAVOCredentialReadSecretRegistry = $brokenRegistry
        $readOut = $null
        $readErrorType = ''
        try { $readOut = Get-BRAVOCredentialSecret -Target $sftpTarget } catch { $readErrorType = $_.Exception.GetType().FullName }
        # Codex P1: пошкоджений реєстр лишається в стані модуля.
        $invokeError = ''
        try {
            Invoke-BRAVOMaintenanceOwnLogUpload
        } catch {
            $invokeError = [string]$_.Exception.Message
        }
        [pscustomobject]@{
            ReadValue     = [string]$readOut
            ReadErrorType = $readErrorType
            Uploads       = $script:secretMaskTestState.Uploads.ToArray()
            LogLines      = $script:secretMaskTestState.LogLines.ToArray()
            InvokeError   = $invokeError
        }
    } $secretMaskLogFile $secretMaskSecretByTarget $secretMaskTargetsConfig ([string]$secretMask417ByKey['RegistryFailurePayload'])
} catch { $secretMask417UploadError = "$secretMask417UploadError; $($_.Exception.GetType().FullName)" }
$secretMask417UploadUploads = @()
$secretMask417UploadLines = @()
$secretMask417UploadLeaks = @()
if ($null -ne $secretMask417UploadResult) {
    $secretMask417UploadUploads = @($secretMask417UploadResult.Uploads | ForEach-Object { $_ })
    $secretMask417UploadLines = @($secretMask417UploadResult.LogLines)
    $secretMask417UploadLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text (($secretMask417UploadLines -join "`n") + "`n" + [string]$secretMask417UploadResult.InvokeError) -SecretByKey $secretMask417LeakByKey)
}
Test-BRAVOCondition (
    $null -ne $secretMask417UploadResult -and
    [string]$secretMask417UploadResult.ReadValue -ceq [string]$secretMaskSyntheticByKey['SFTPPassword'] -and
    [string]::IsNullOrEmpty([string]$secretMask417UploadResult.ReadErrorType) -and
    $secretMask417UploadUploads.Count -eq 0 -and
    @($secretMask417UploadLines | Where-Object { $_.StartsWith('[WARNING]') }).Count -ge 1 -and
    @($secretMask417UploadLines | Where-Object { $_.Contains('synthetic registry bookkeeping failure') }).Count -eq 0 -and
    $secretMask417UploadLeaks.Count -eq 0 -and
    [string]::IsNullOrEmpty([string]$secretMask417UploadResult.InvokeError)
) -Name 'Maintenance/OwnLogUploadFailsClosedWithoutLeakWhenSecretRegistryIncomplete' `
    -Failure "після збою обліку секретів: читання успішне, власний лог НЕ вивантажується, WARNING без секрету й без тексту первинного винятку, виняток назовні не йде; виняток читання: $(if ($null -ne $secretMask417UploadResult) { [string]$secretMask417UploadResult.ReadErrorType } else { 'n/a' }); uploads=$($secretMask417UploadUploads.Count); витекли ключі: $($secretMask417UploadLeaks -join ', '); помилка: $secretMask417UploadError"

# --- (г) security review P2: облік не вдається, а доступ до реєстру з
# Get-BRAVOLogMaskSecretSet ПРАЦЮЄ (TryGetValue повертає $false, лише
# додавання запису падає). Тоді fail-closed тримається тільки на ознаці
# неповноти: перевірка на початку (читання ДО набору) і перевірка в кінці
# (читання ВСЕРЕДИНІ набору ставить ознаку). Обидві мають кинути рівно
# фіксоване повідомлення #417 без секретів, і вивантаження не відбувається.
$secretMask417ExpectedMessage = 'Набір маскування секретів неповний: облік секретів, отриманих цим процесом із Credential Manager, не вдався (#417). Вивантаження журналу скасовано (fail-closed).'
$secretMask417RecordFailRegistryInit = {
    # Реєстр, у якому TryGetValue працює (повертає $false, рахує виклики),
    # але запис нового target-а падає (індексатор недоступний).
    $recordFailRegistry = New-Object psobject
    Add-Member -InputObject $recordFailRegistry -MemberType NoteProperty -Name LookupCalls -Value 0
    Add-Member -InputObject $recordFailRegistry -MemberType ScriptMethod -Name TryGetValue -Value {
        param($key, $valueReference)
        $this.LookupCalls = $this.LookupCalls + 1
        return $false
    }
    $script:BRAVOCredentialReadSecretRegistry = $recordFailRegistry
    $script:BRAVOCredentialReadSecretRegistryIncomplete = $false
    return $recordFailRegistry
}
$secretMask417RecordFailResult = $null
$secretMask417RecordFailError = ''
try {
    $secretMask417RecordFailModule = New-BRAVOSelfTestRuntimeModule -SourceText $secretMaskSourceText -FunctionNames $secretMaskEarlyFunctions
    $secretMask417RecordFailResult = & $secretMask417RecordFailModule {
        param($targetsConfig, $readValue, $registryInit)
        $credentialSettings = @{ Targets = $targetsConfig }
        $sftpTarget = Get-BRAVOCredentialTargetName -CredentialSettings $credentialSettings -Key 'SFTPPassword'
        $secretByTarget = @{}
        $secretByTarget[$sftpTarget] = $readValue
        $script:secretMaskTestState = [pscustomobject]@{
            LogLines = (New-Object System.Collections.Generic.List[string]); ReadTargets = (New-Object System.Collections.Generic.List[string])
            Uploads = (New-Object System.Collections.Generic.List[object]); SecretByTarget = $secretByTarget
            ThrowTargets = @(); CorruptTargets = @(); ExceptionPayload = ''; RangeIdLogPath = ''; ConnectCalls = 0
        }
        # (1) Перевірка на початку: читання ДО набору ставить ознаку; набір
        # кидає ще до будь-якого доступу до реєстру.
        $registry = . ([scriptblock]::Create($registryInit))
        $readOut = $null
        $readErrorType = ''
        try { $readOut = Get-BRAVOCredentialSecret -Target $sftpTarget } catch { $readErrorType = $_.Exception.GetType().FullName }
        $earlyFlag = [bool]$script:BRAVOCredentialReadSecretRegistryIncomplete
        $earlyLookupsBefore = [int]$registry.LookupCalls
        $earlyMessage = $null
        try { [void](Get-BRAVOLogMaskSecretSet -CredentialSettings $credentialSettings) } catch { $earlyMessage = [string]$_.Exception.Message }
        $earlyLookupsInSet = [int]$registry.LookupCalls - $earlyLookupsBefore
        # (2) Перевірка в кінці: жодного читання ДО набору; ознаку ставить
        # читання всередині набору, доступ до реєстру при цьому працює.
        $registry = . ([scriptblock]::Create($registryInit))
        $lateMessage = $null
        try { [void](Get-BRAVOLogMaskSecretSet -CredentialSettings $credentialSettings) } catch { $lateMessage = [string]$_.Exception.Message }
        [pscustomobject]@{
            ReadValue = [string]$readOut; ReadErrorType = $readErrorType; EarlyFlag = $earlyFlag
            EarlyMessage = $earlyMessage; EarlyLookupsInSet = $earlyLookupsInSet
            LateMessage = $lateMessage; LateLookupsInSet = [int]$registry.LookupCalls
            LateFlag = [bool]$script:BRAVOCredentialReadSecretRegistryIncomplete
        }
    } $secretMaskTargetsConfig ([string]$secretMask417ByKey['SftpReadDuringFailure']) ([string]$secretMask417RecordFailRegistryInit)
} catch { $secretMask417RecordFailError = $_.Exception.GetType().FullName }
$secretMask417RecordFailLeaks = @()
if ($null -ne $secretMask417RecordFailResult) {
    $secretMask417RecordFailLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text ([string]$secretMask417RecordFailResult.EarlyMessage + "`n" + [string]$secretMask417RecordFailResult.LateMessage) -SecretByKey $secretMask417LeakByKey)
}
Test-BRAVOCondition (
    $null -ne $secretMask417RecordFailResult -and
    [string]$secretMask417RecordFailResult.ReadValue -ceq [string]$secretMask417ByKey['SftpReadDuringFailure'] -and
    [string]::IsNullOrEmpty([string]$secretMask417RecordFailResult.ReadErrorType) -and
    [bool]$secretMask417RecordFailResult.EarlyFlag -and
    [string]$secretMask417RecordFailResult.EarlyMessage -ceq $secretMask417ExpectedMessage -and
    [int]$secretMask417RecordFailResult.EarlyLookupsInSet -eq 0 -and
    [string]$secretMask417RecordFailResult.LateMessage -ceq $secretMask417ExpectedMessage -and
    [int]$secretMask417RecordFailResult.LateLookupsInSet -gt 0 -and
    [bool]$secretMask417RecordFailResult.LateFlag -and
    $secretMask417RecordFailLeaks.Count -eq 0
) -Name 'Credentials/RecordFailureWithReadableRegistryFailsMaskSetByFlag' `
    -Failure "збій лише ЗАПИСУ в облік (реєстр читається) має ставити ознаку неповноти, і Get-BRAVOLogMaskSecretSet має кидати рівно фіксоване повідомлення #417 — і за читання ДО набору (перевірка на початку, без доступу до реєстру), і за читання всередині набору (перевірка в кінці); $(if ($null -ne $secretMask417RecordFailResult) { "читання повернуло значення: $([string]$secretMask417RecordFailResult.ReadValue -ceq [string]$secretMask417ByKey['SftpReadDuringFailure']); ознака після читання: $([bool]$secretMask417RecordFailResult.EarlyFlag); на початку кинуто фіксоване: $([string]$secretMask417RecordFailResult.EarlyMessage -ceq $secretMask417ExpectedMessage); звернень до реєстру до перевірки на початку: $([int]$secretMask417RecordFailResult.EarlyLookupsInSet); у кінці кинуто фіксоване: $([string]$secretMask417RecordFailResult.LateMessage -ceq $secretMask417ExpectedMessage); звернень до реєстру в наборі: $([int]$secretMask417RecordFailResult.LateLookupsInSet); ознака в кінці: $([bool]$secretMask417RecordFailResult.LateFlag)" } else { 'n/a' }); витекли ключі: $($secretMask417RecordFailLeaks -join ', '); помилка: $secretMask417RecordFailError"

# --- (ґ) той самий збій лише запису в облік на шляху вивантаження:
# ознаку ставить читання всередині набору (перевірка в кінці), передачі
# немає, WARNING без секретів, виняток назовні не йде.
$secretMask417RecordFailUploadResult = $null
$secretMask417RecordFailUploadError = $secretMaskSetupError
try {
    $secretMask417RecordFailUploadModule = New-BRAVOSelfTestRuntimeModule -SourceText $secretMaskSourceText `
        -FunctionNames ($secretMaskBoundaryAndUploadFunctions + @(
            'Get-BRAVOCredentialTargetName', 'Get-BRAVOLogMaskSecretSet', 'Get-BRAVOArchivePasswordTarget',
            'Protect-BRAVOLogSecret', 'New-BRAVOMaskedLogCopy', 'Remove-BRAVOMaskedLogCopy',
            'Copy-BRAVOConfigurationGraphDeep', 'Get-BRAVODefaultConfiguration'
        ))
    $secretMask417RecordFailUploadResult = & $secretMask417RecordFailUploadModule {
        param($logFilePath, $secretByTarget, $targetsConfig, $registryInit)
        $script:secretMaskTestState = [pscustomobject]@{
            LogLines = (New-Object System.Collections.Generic.List[string]); ReadTargets = (New-Object System.Collections.Generic.List[string])
            Uploads = (New-Object System.Collections.Generic.List[object]); SecretByTarget = $secretByTarget
            ThrowTargets = @(); CorruptTargets = @(); ExceptionPayload = ''; RangeIdLogPath = ''; ConnectCalls = 0
        }
        $global:componentSettings = [pscustomobject]@{ SFTP = [pscustomobject]@{ MaintenanceLogUploadEnabled = $true } }
        $global:storageEffective = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $true } }
        $script:credentialSettings = @{ Targets = $targetsConfig }
        $script:sftpDirectories = [pscustomobject]@{ MaintenanceLog = 'logs/maintenance' }
        $script:LOG_FILE = $logFilePath
        $script:maintenanceLogRunId = 'selftest_417_record_run'
        $script:maintenanceOwnLogUploadAttempted = $false
        $registry = . ([scriptblock]::Create($registryInit))
        $invokeError = ''
        try {
            Invoke-BRAVOMaintenanceOwnLogUpload
        } catch {
            $invokeError = [string]$_.Exception.Message
        }
        [pscustomobject]@{
            Uploads      = $script:secretMaskTestState.Uploads.ToArray()
            LogLines     = $script:secretMaskTestState.LogLines.ToArray()
            ConnectCalls = $script:secretMaskTestState.ConnectCalls
            LookupCalls  = [int]$registry.LookupCalls
            Flag         = [bool]$script:BRAVOCredentialReadSecretRegistryIncomplete
            InvokeError  = $invokeError
        }
    } $secretMaskLogFile $secretMaskSecretByTarget $secretMaskTargetsConfig ([string]$secretMask417RecordFailRegistryInit)
} catch { $secretMask417RecordFailUploadError = "$secretMask417RecordFailUploadError; $($_.Exception.GetType().FullName)" }
$secretMask417RecordFailUploadUploads = @()
$secretMask417RecordFailUploadLines = @()
$secretMask417RecordFailUploadLeaks = @()
if ($null -ne $secretMask417RecordFailUploadResult) {
    $secretMask417RecordFailUploadUploads = @($secretMask417RecordFailUploadResult.Uploads | ForEach-Object { $_ })
    $secretMask417RecordFailUploadLines = @($secretMask417RecordFailUploadResult.LogLines)
    $secretMask417RecordFailUploadLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text (($secretMask417RecordFailUploadLines -join "`n") + "`n" + [string]$secretMask417RecordFailUploadResult.InvokeError) -SecretByKey $secretMask417LeakByKey)
}
Test-BRAVOCondition (
    $null -ne $secretMask417RecordFailUploadResult -and
    $secretMask417RecordFailUploadUploads.Count -eq 0 -and
    [int]$secretMask417RecordFailUploadResult.LookupCalls -gt 0 -and
    [bool]$secretMask417RecordFailUploadResult.Flag -and
    @($secretMask417RecordFailUploadLines | Where-Object { $_.StartsWith('[WARNING]') }).Count -ge 1 -and
    $secretMask417RecordFailUploadLeaks.Count -eq 0 -and
    [string]::IsNullOrEmpty([string]$secretMask417RecordFailUploadResult.InvokeError)
) -Name 'Maintenance/OwnLogUploadFailsClosedWhenRecordFailsButRegistryReadable' `
    -Failure "збій лише запису в облік (реєстр читається) на шляху вивантаження: передачі немає, WARNING без секретів, виняток назовні не йде; uploads=$($secretMask417RecordFailUploadUploads.Count); звернень до реєстру: $(if ($null -ne $secretMask417RecordFailUploadResult) { [int]$secretMask417RecordFailUploadResult.LookupCalls } else { 'n/a' }); ознака: $(if ($null -ne $secretMask417RecordFailUploadResult) { [bool]$secretMask417RecordFailUploadResult.Flag } else { 'n/a' }); витекли ключі: $($secretMask417RecordFailUploadLeaks -join ', '); помилка: $secretMask417RecordFailUploadError"

# --- (д) security review P3: збій CredWrite у Set-BRAVOCredential завжди
# виходить назовні й нічого не записує в облік — навіть коли викликач не
# має try (без try виняток .NET-методу лише завершує інструкцію, і наступний
# рядок виконався б). Тому сценарій іде в окремому runspace без жодного try
# над викликом. Межа CredWrite — тестовий записувач, що кидає; сценарій
# виконується лише після тієї самої AST-перевірки заміни.
$secretMask417FailedWriteFunctionNames = @('Initialize-BRAVOCredentialManager', 'Add-BRAVOCredentialReadSecretRecord', 'Set-BRAVOCredential')
$secretMask417FailedWriteGuardProblems = @(Get-BRAVOSelfTest417CredWriteGuardProblem -SourceText $secretMask417WriteSourceText `
        -ModuleFunctionNames $secretMask417FailedWriteFunctionNames -WriterExpressionText $secretMask417WriterExpression)
$secretMask417FailedWriteResult = $null
$secretMask417FailedWriteError = ''
$secretMask417FailedWriteErrorText = ''
$secretMask417FailedWriteFailureMarker = 'synthetic CredWrite failure ' + [guid]::NewGuid().ToString('N')
if ($secretMask417WriteBoundaryCount -eq 1 -and $secretMask417FailedWriteGuardProblems.Count -eq 0) {
    $secretMask417FailedWriteRunspace = $null
    try {
        # Текст модуля — ті самі перші визначення, що розібрала AST-перевірка.
        $secretMask417FailedWriteTokens = $null
        $secretMask417FailedWriteParseErrors = $null
        $secretMask417FailedWriteAst = [System.Management.Automation.Language.Parser]::ParseInput($secretMask417WriteSourceText, [ref]$secretMask417FailedWriteTokens, [ref]$secretMask417FailedWriteParseErrors)
        $secretMask417FailedWriteDefinitions = @($secretMask417FailedWriteAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $secretMask417FailedWriteModuleText = (@($secretMask417FailedWriteFunctionNames | ForEach-Object {
                    $failedWriteName = $_
                    @($secretMask417FailedWriteDefinitions | Where-Object { $_.Name -eq $failedWriteName } | Select-Object -First 1)[0].Extent.Text
                }) -join "`n")
        $secretMask417FailedWriteRunspace = [runspacefactory]::CreateRunspace()
        $secretMask417FailedWriteRunspace.Open()
        $secretMask417FailedWriteWriteScript = @'
param($ModuleText, $Target, $Value, $FailureMarker)
$global:BRAVOSelfTest417FailedWriteModule = New-Module -Name BRAVOSelfTest417FailedWrite -ScriptBlock ([scriptblock]::Create($ModuleText))
& $global:BRAVOSelfTest417FailedWriteModule {
    param($target, $value, $failureMarker)
    $writer = New-Object psobject
    Add-Member -InputObject $writer -MemberType NoteProperty -Name Calls -Value (New-Object System.Collections.Generic.List[string])
    Add-Member -InputObject $writer -MemberType NoteProperty -Name FailureMarker -Value $failureMarker
    Add-Member -InputObject $writer -MemberType ScriptMethod -Name WriteGeneric -Value {
        param($writeTarget, $writeUserName, $writeSecret)
        [void]$this.Calls.Add([string]$writeTarget)
        throw (New-Object System.ComponentModel.Win32Exception(5, $this.FailureMarker))
    }
    $script:secretMaskTestState = [pscustomobject]@{ CredentialWriter = $writer }
    $script:BRAVOCredentialReadSecretRegistry = $null
    $script:BRAVOCredentialReadSecretRegistryIncomplete = $false
    $script:selfTest417ReachedAfterWrite = $false
    $secure = New-Object System.Security.SecureString
    foreach ($secureChar in $value.ToCharArray()) { $secure.AppendChar($secureChar) }
    $secure.MakeReadOnly()
    Set-BRAVOCredential -Target $target -Secret $secure
    $script:selfTest417ReachedAfterWrite = $true
} $Target $Value $FailureMarker
'@
        $secretMask417FailedWriteProbeScript = @'
& $global:BRAVOSelfTest417FailedWriteModule {
    $registry = $script:BRAVOCredentialReadSecretRegistry
    $recordedCount = 0
    if ($null -ne $registry) { $recordedCount = [int]$registry.Count }
    [pscustomobject]@{
        ReachedAfterWrite = [bool]$script:selfTest417ReachedAfterWrite
        WriteCalls        = [string[]]$script:secretMaskTestState.CredentialWriter.Calls.ToArray()
        RecordedTargets   = $recordedCount
        Incomplete        = [bool]$script:BRAVOCredentialReadSecretRegistryIncomplete
    }
}
'@
        $secretMask417FailedWriteShell = [powershell]::Create()
        try {
            $secretMask417FailedWriteShell.Runspace = $secretMask417FailedWriteRunspace
            [void]$secretMask417FailedWriteShell.AddScript($secretMask417FailedWriteWriteScript).AddArgument($secretMask417FailedWriteModuleText).AddArgument('BRAVO_SELFTEST_417_FAILED_WRITE').AddArgument([string]$secretMask417ByKey['OperationsApiKeyWritten']).AddArgument($secretMask417FailedWriteFailureMarker)
            try {
                [void]$secretMask417FailedWriteShell.Invoke()
            } catch {
                $secretMask417FailedWriteErrorText = [string]$_.Exception.ToString()
            }
            foreach ($failedWriteRecord in @($secretMask417FailedWriteShell.Streams.Error)) {
                $secretMask417FailedWriteErrorText = $secretMask417FailedWriteErrorText + "`n" + [string]$failedWriteRecord.Exception.ToString()
            }
        } finally {
            $secretMask417FailedWriteShell.Dispose()
        }
        $secretMask417FailedWriteProbe = [powershell]::Create()
        try {
            $secretMask417FailedWriteProbe.Runspace = $secretMask417FailedWriteRunspace
            [void]$secretMask417FailedWriteProbe.AddScript($secretMask417FailedWriteProbeScript)
            $secretMask417FailedWriteResult = @($secretMask417FailedWriteProbe.Invoke()) | Select-Object -First 1
        } finally {
            $secretMask417FailedWriteProbe.Dispose()
        }
    } catch {
        $secretMask417FailedWriteError = $_.Exception.GetType().FullName
    } finally {
        if ($null -ne $secretMask417FailedWriteRunspace) { $secretMask417FailedWriteRunspace.Dispose() }
    }
} else {
    # Сценарій НЕ виконується: справжній CredWrite міг би лишитися досяжним.
    $secretMask417FailedWriteError = "сценарій не виконано: межа CredWrite у тексті модуля — $secretMask417WriteBoundaryCount раз(ів) (очікується 1); проблеми AST-перевірки заміни: $($secretMask417FailedWriteGuardProblems -join '; ')"
}
$secretMask417FailedWriteLeaks = @(Get-BRAVOSelfTestLeakedSecretKeys -Text $secretMask417FailedWriteErrorText -SecretByKey $secretMask417LeakByKey)
Test-BRAVOCondition (
    $null -ne $secretMask417FailedWriteResult -and
    @($secretMask417FailedWriteResult.WriteCalls).Count -eq 1 -and
    -not [bool]$secretMask417FailedWriteResult.ReachedAfterWrite -and
    [int]$secretMask417FailedWriteResult.RecordedTargets -eq 0 -and
    -not [bool]$secretMask417FailedWriteResult.Incomplete -and
    $secretMask417FailedWriteErrorText.Contains($secretMask417FailedWriteFailureMarker) -and
    $secretMask417FailedWriteLeaks.Count -eq 0
) -Name 'Credentials/SetCredentialFailedWriteRecordsNothingAndPropagates' `
    -Failure "збій CredWrite у Set-BRAVOCredential (викликач без try) має перервати виклик і нічого не записати в облік; $(if ($null -ne $secretMask417FailedWriteResult) { "викликів CredWrite: $(@($secretMask417FailedWriteResult.WriteCalls).Count); інструкція після виклику виконалась: $([bool]$secretMask417FailedWriteResult.ReachedAfterWrite); записаних target-ів: $([int]$secretMask417FailedWriteResult.RecordedTargets); ознака неповноти: $([bool]$secretMask417FailedWriteResult.Incomplete)" } else { 'n/a' }); помилка CredWrite дійшла до викликача: $($secretMask417FailedWriteErrorText.Contains($secretMask417FailedWriteFailureMarker)); витекли ключі: $($secretMask417FailedWriteLeaks -join ', '); помилка: $secretMask417FailedWriteError"

# --- #365 review (P3): частково перекриті секрети (кінець одного —
# початок іншого) і секрети впритул не лишають фрагмента: збіги всіх
# варіантів шукаються в ОРИГІНАЛЬНОМУ тексті, перекриті/суміжні діапазони
# зливаються й замінюються одним ***. Значення похідні від одного
# runtime-значення, без літералів.
$secretMaskPartialValue = $secretMaskNewValue.Invoke('Part')[0]
$secretMaskPartialHead = $secretMaskPartialValue.Substring(0, 10)
$secretMaskPartialTail = $secretMaskPartialValue.Substring(6)
$secretMaskAdjacentLeft = $secretMaskNewValue.Invoke('AdjL')[0]
$secretMaskAdjacentRight = $secretMaskNewValue.Invoke('AdjR')[0]
$secretMaskPartialResult = $null
$secretMaskPartialError = $secretMaskSetupError
if ($null -ne $secretMaskModule) {
    try {
        $secretMaskPartialResult = & $secretMaskModule {
            param($whole, $head, $tail, $left, $right)
            Protect-BRAVOLogSecret -Text "p $whole q $left$right r" -KnownSecret @($head, $tail, $left, $right)
        } $secretMaskPartialValue $secretMaskPartialHead $secretMaskPartialTail $secretMaskAdjacentLeft $secretMaskAdjacentRight
    } catch { $secretMaskPartialError = $_.Exception.GetType().FullName }
}
$secretMaskPartialFragmentLeft = ([string]$secretMaskPartialResult).Contains($secretMaskPartialValue.Substring(10)) -or ([string]$secretMaskPartialResult).Contains($secretMaskPartialValue.Substring(0, 6))
Test-BRAVOCondition (
    [string]$secretMaskPartialResult -ceq 'p *** q *** r'
) -Name 'Logging/KnownSecretPartialOverlapLeavesNoFragment' `
    -Failure "частково перекриті й суміжні секрети мають замінюватись одним *** на злитий діапазон (очікується 'p *** q *** r'); фрагмент секрету лишився: $secretMaskPartialFragmentLeft; помилка: $secretMaskPartialError"

# --- #417 (пункт 4b): закодовані форми відомих секретів. Точний збіг
# -KnownSecret не впізнавав секрет, який потрапив у текст у URL-кодованій
# формі ([Uri]::EscapeDataString — так кодує New-BRAVOSftpUrl) чи
# JSON-екранованій формі (тіло рядка ConvertTo-Json без лапок). Шаблон
# URL-кредів ловить лише scheme://user:pass@, тож фрагмент без схеми
# витікав. Значення будуються під час запуску; спецсимволи — з кодів
# символів, без суцільних секрето-подібних літералів.
$secretMaskEncodedBase = $secretMaskNewValue.Invoke('Enc')[0]
$secretMaskUrlSecret = $secretMaskEncodedBase.Substring(0, 7) + [char]64 + $secretMaskEncodedBase.Substring(7) + [char]32 + [char]37 + 'x'
$secretMaskUrlEncoded = [System.Uri]::EscapeDataString($secretMaskUrlSecret)
$secretMaskUrlResult = $null
$secretMaskUrlError = $secretMaskSetupError
if ($null -ne $secretMaskModule) {
    try {
        $secretMaskUrlResult = & $secretMaskModule {
            param($secret, $encoded)
            Protect-BRAVOLogSecret -Text ("login selftest-user:" + $encoded + "@host-a done") -KnownSecret @($secret)
        } $secretMaskUrlSecret $secretMaskUrlEncoded
    } catch { $secretMaskUrlError = $_.Exception.GetType().FullName }
}
Test-BRAVOCondition (
    $secretMaskUrlEncoded -cne $secretMaskUrlSecret -and
    [string]$secretMaskUrlResult -ceq 'login selftest-user:***@host-a done'
) -Name 'Logging/KnownSecretUrlEncodedFormMasked' `
    -Failure "URL-кодована форма відомого секрету (як у New-BRAVOSftpUrl) без scheme:// має маскуватись (очікується 'login selftest-user:***@host-a done'); закодована форма лишилась: $(([string]$secretMaskUrlResult).Contains($secretMaskUrlEncoded)); помилка: $secretMaskUrlError"

# JSON-екранування відрізняється між хостами: Windows PowerShell 5.1
# (JavaScriptSerializer) додатково екранує & < > ' як \u00XX, PowerShell 7
# — " \, керівні символи й U+0085/U+2028/U+2029 (окремий тест нижче).
# Перевіряються ОБИДВІ форми, побудовані
# детерміновано, і фактичний вивід ConvertTo-Json поточного хоста.
$secretMaskJsonSecret = $secretMaskEncodedBase.Substring(0, 5) + [char]34 + $secretMaskEncodedBase.Substring(5, 4) + [char]92 + 'c' + [char]38 + 'd' + [char]60 + [char]39 + $secretMaskEncodedBase.Substring(9)
$secretMaskJsonStrict = $secretMaskJsonSecret.Replace([string][char]92, '\\').Replace([string][char]34, '\"')
$secretMaskJsonHtmlSafe = $secretMaskJsonStrict.Replace([string][char]38, ([string][char]92 + 'u0026')).Replace([string][char]60, ([string][char]92 + 'u003c')).Replace([string][char]39, ([string][char]92 + 'u0027'))
$secretMaskJsonNative = [string]($secretMaskJsonSecret | ConvertTo-Json -Compress)
$secretMaskJsonNative = $secretMaskJsonNative.Substring(1, $secretMaskJsonNative.Length - 2)
$secretMaskJsonResult = $null
$secretMaskJsonError = $secretMaskSetupError
if ($null -ne $secretMaskModule) {
    try {
        $secretMaskJsonResult = & $secretMaskModule {
            param($secret, $strict, $htmlSafe, $native)
            Protect-BRAVOLogSecret -Text ('{"k":"' + $strict + '","h":"' + $htmlSafe + '","n":"' + $native + '"}') -KnownSecret @($secret)
        } $secretMaskJsonSecret $secretMaskJsonStrict $secretMaskJsonHtmlSafe $secretMaskJsonNative
    } catch { $secretMaskJsonError = $_.Exception.GetType().FullName }
}
Test-BRAVOCondition (
    $secretMaskJsonStrict -cne $secretMaskJsonSecret -and
    [string]$secretMaskJsonResult -ceq '{"k":"***","h":"***","n":"***"}'
) -Name 'Logging/KnownSecretJsonEscapedFormMasked' `
    -Failure "JSON-екранована форма відомого секрету (обидва варіанти ConvertTo-Json: PS 5.1 і PS 7) має маскуватись (очікується '{`"k`":`"***`",`"h`":`"***`",`"n`":`"***`"}'); лишились форми: strict=$(([string]$secretMaskJsonResult).Contains($secretMaskJsonStrict)) html=$(([string]$secretMaskJsonResult).Contains($secretMaskJsonHtmlSafe)) native=$(([string]$secretMaskJsonResult).Contains($secretMaskJsonNative)); помилка: $secretMaskJsonError"

# #435: строга JSON-форма (PowerShell 7, Newtonsoft.Json) екранує також
# U+0085, U+2028 і U+2029 як \u + 4 hex у нижньому регістрі. Секрет із
# кожним із цих символів має маскуватись і в такій формі, і у фактичному
# виводі ConvertTo-Json поточного хоста. Символи — лише з кодів, значення
# будуються під час запуску.
$secretMaskJsonLineSecrets = New-Object 'System.Collections.Generic.List[string]'
$secretMaskJsonLineEscaped = New-Object 'System.Collections.Generic.List[string]'
$secretMaskJsonLineNative = New-Object 'System.Collections.Generic.List[string]'
foreach ($secretMaskJsonLineCode in @(0x0085, 0x2028, 0x2029)) {
    $secretMaskJsonLineBase = $secretMaskNewValue.Invoke('Ln' + $secretMaskJsonLineCode.ToString('x4'))[0]
    $secretMaskJsonLineSecret = $secretMaskJsonLineBase.Substring(0, 6) + [string][char]$secretMaskJsonLineCode + $secretMaskJsonLineBase.Substring(6)
    $secretMaskJsonLineSecrets.Add($secretMaskJsonLineSecret)
    $secretMaskJsonLineEscaped.Add($secretMaskJsonLineSecret.Replace([string][char]$secretMaskJsonLineCode, ([string][char]92 + 'u' + $secretMaskJsonLineCode.ToString('x4'))))
    $secretMaskJsonLineNativeText = [string]($secretMaskJsonLineSecret | ConvertTo-Json -Compress)
    $secretMaskJsonLineNative.Add($secretMaskJsonLineNativeText.Substring(1, $secretMaskJsonLineNativeText.Length - 2))
}
$secretMaskJsonLineText = ''
for ($secretMaskJsonLineIndex = 0; $secretMaskJsonLineIndex -lt $secretMaskJsonLineSecrets.Count; $secretMaskJsonLineIndex++) {
    $secretMaskJsonLineText += '{"k":"' + $secretMaskJsonLineEscaped[$secretMaskJsonLineIndex] + '","n":"' + $secretMaskJsonLineNative[$secretMaskJsonLineIndex] + '"} '
}
$secretMaskJsonLineResult = $null
$secretMaskJsonLineError = $secretMaskSetupError
if ($null -ne $secretMaskModule) {
    try {
        $secretMaskJsonLineResult = & $secretMaskModule {
            param($text, $secrets)
            Protect-BRAVOLogSecret -Text $text -KnownSecret $secrets
        } $secretMaskJsonLineText $secretMaskJsonLineSecrets.ToArray()
    } catch { $secretMaskJsonLineError = $_.Exception.GetType().FullName }
}
$secretMaskJsonLineLeft = New-Object 'System.Collections.Generic.List[string]'
for ($secretMaskJsonLineIndex = 0; $secretMaskJsonLineIndex -lt $secretMaskJsonLineSecrets.Count; $secretMaskJsonLineIndex++) {
    $secretMaskJsonLineLabel = ([int][char]$secretMaskJsonLineSecrets[$secretMaskJsonLineIndex][6]).ToString('X4')
    if (([string]$secretMaskJsonLineResult).Contains($secretMaskJsonLineEscaped[$secretMaskJsonLineIndex])) { $secretMaskJsonLineLeft.Add("strict:U+$secretMaskJsonLineLabel") }
    if (([string]$secretMaskJsonLineResult).Contains($secretMaskJsonLineNative[$secretMaskJsonLineIndex])) { $secretMaskJsonLineLeft.Add("native:U+$secretMaskJsonLineLabel") }
}
Test-BRAVOCondition (
    @($secretMaskJsonLineEscaped | Where-Object { $_.IndexOf([string][char]92 + 'u') -lt 0 }).Count -eq 0 -and
    [string]$secretMaskJsonLineResult -ceq '{"k":"***","n":"***"} {"k":"***","n":"***"} {"k":"***","n":"***"} '
) -Name 'Logging/KnownSecretJsonEscapedLineSeparatorsMasked' `
    -Failure "JSON-екранована форма відомого секрету з U+0085/U+2028/U+2029 (\u0085, \u2028, \u2029 — строга форма PS 7) і фактичний вивід ConvertTo-Json поточного хоста мають маскуватись; лишились форми: $(@($secretMaskJsonLineLeft) -join ', '); помилка: $secretMaskJsonLineError"

# #435: HTML-безпечна JSON-форма (Windows PowerShell 5.1,
# JavaScriptSerializer -> HttpEncoder.JavaScriptStringEncode) екранує
# водночас і & ' < >, і U+0085/U+2028/U+2029 — обидва як \u + 4 hex у
# нижньому регістрі. Секрет, що містить HTML-символ І один із цих
# роздільників, у виводі PS 5.1 не збігається ні зі строгою формою
# (там HTML-символ сирий), ні з формою, де екрановано лише HTML-символи,
# — тож ця форма теж має маскуватись, як і фактичний вивід ConvertTo-Json
# поточного хоста. Символи — лише з кодів, значення будуються під час
# запуску.
$secretMaskJsonMixLineCodes = @(0x0085, 0x2028, 0x2029)
$secretMaskJsonMixHtmlCodes = @(60, 38, 62)
$secretMaskJsonMixSecrets = New-Object 'System.Collections.Generic.List[string]'
$secretMaskJsonMixHtmlSafe = New-Object 'System.Collections.Generic.List[string]'
$secretMaskJsonMixNative = New-Object 'System.Collections.Generic.List[string]'
for ($secretMaskJsonMixIndex = 0; $secretMaskJsonMixIndex -lt $secretMaskJsonMixLineCodes.Count; $secretMaskJsonMixIndex++) {
    $secretMaskJsonMixLineCode = [int]$secretMaskJsonMixLineCodes[$secretMaskJsonMixIndex]
    $secretMaskJsonMixHtmlCode = [int]$secretMaskJsonMixHtmlCodes[$secretMaskJsonMixIndex]
    $secretMaskJsonMixBase = $secretMaskNewValue.Invoke('Mx' + $secretMaskJsonMixLineCode.ToString('x4'))[0]
    $secretMaskJsonMixSecret = $secretMaskJsonMixBase.Substring(0, 5) + [string][char]$secretMaskJsonMixHtmlCode + $secretMaskJsonMixBase.Substring(5, 3) + [string][char]34 + $secretMaskJsonMixBase.Substring(8, 2) + [string][char]$secretMaskJsonMixLineCode + $secretMaskJsonMixBase.Substring(10)
    $secretMaskJsonMixSecrets.Add($secretMaskJsonMixSecret)
    $secretMaskJsonMixHtmlSafe.Add($secretMaskJsonMixSecret.Replace([string][char]92, '\\').Replace([string][char]34, '\"').Replace([string][char]$secretMaskJsonMixHtmlCode, ([string][char]92 + 'u' + $secretMaskJsonMixHtmlCode.ToString('x4'))).Replace([string][char]$secretMaskJsonMixLineCode, ([string][char]92 + 'u' + $secretMaskJsonMixLineCode.ToString('x4'))))
    $secretMaskJsonMixNativeText = [string]($secretMaskJsonMixSecret | ConvertTo-Json -Compress)
    $secretMaskJsonMixNative.Add($secretMaskJsonMixNativeText.Substring(1, $secretMaskJsonMixNativeText.Length - 2))
}
$secretMaskJsonMixText = ''
for ($secretMaskJsonMixIndex = 0; $secretMaskJsonMixIndex -lt $secretMaskJsonMixSecrets.Count; $secretMaskJsonMixIndex++) {
    $secretMaskJsonMixText += '{"h":"' + $secretMaskJsonMixHtmlSafe[$secretMaskJsonMixIndex] + '","n":"' + $secretMaskJsonMixNative[$secretMaskJsonMixIndex] + '"} '
}
$secretMaskJsonMixResult = $null
$secretMaskJsonMixError = $secretMaskSetupError
if ($null -ne $secretMaskModule) {
    try {
        $secretMaskJsonMixResult = & $secretMaskModule {
            param($text, $secrets)
            Protect-BRAVOLogSecret -Text $text -KnownSecret $secrets
        } $secretMaskJsonMixText $secretMaskJsonMixSecrets.ToArray()
    } catch { $secretMaskJsonMixError = $_.Exception.GetType().FullName }
}
$secretMaskJsonMixLeft = New-Object 'System.Collections.Generic.List[string]'
for ($secretMaskJsonMixIndex = 0; $secretMaskJsonMixIndex -lt $secretMaskJsonMixSecrets.Count; $secretMaskJsonMixIndex++) {
    $secretMaskJsonMixLabel = ([int]$secretMaskJsonMixLineCodes[$secretMaskJsonMixIndex]).ToString('X4') + '+' + ([int]$secretMaskJsonMixHtmlCodes[$secretMaskJsonMixIndex]).ToString('X4')
    if (([string]$secretMaskJsonMixResult).Contains($secretMaskJsonMixHtmlSafe[$secretMaskJsonMixIndex])) { $secretMaskJsonMixLeft.Add("html:U+$secretMaskJsonMixLabel") }
    if (([string]$secretMaskJsonMixResult).Contains($secretMaskJsonMixNative[$secretMaskJsonMixIndex])) { $secretMaskJsonMixLeft.Add("native:U+$secretMaskJsonMixLabel") }
}
Test-BRAVOCondition (
    @($secretMaskJsonMixHtmlSafe | Where-Object { ([regex]::Matches($_, '\\u[0-9a-f]{4}')).Count -ne 2 }).Count -eq 0 -and
    [string]$secretMaskJsonMixResult -ceq '{"h":"***","n":"***"} {"h":"***","n":"***"} {"h":"***","n":"***"} '
) -Name 'Logging/KnownSecretJsonEscapedHtmlAndSeparatorMasked' `
    -Failure "HTML-безпечна JSON-форма відомого секрету з HTML-символом (< & >) і U+0085/U+2028/U+2029 (обидва екрановані як \u + 4 hex — форма PS 5.1) і фактичний вивід ConvertTo-Json поточного хоста мають маскуватись; лишились форми: $(@($secretMaskJsonMixLeft) -join ', '); помилка: $secretMaskJsonMixError"

# Регресія: секрет без спецсимволів (закодовані форми збігаються з сирою)
# маскується рівно як раніше — одне *** на входження, без *** поруч
# (артефакт подвійного маскування) і без змін у решті тексту.
$secretMaskPlainSecret = $secretMaskNewValue.Invoke('Plain')[0]
$secretMaskPlainResult = $null
$secretMaskPlainError = $secretMaskSetupError
if ($null -ne $secretMaskModule) {
    try {
        $secretMaskPlainResult = & $secretMaskModule {
            param($secret)
            Protect-BRAVOLogSecret -Text ("a $secret b user:" + $secret + '@host-a {"k":"' + $secret + '"} ' + $secret) -KnownSecret @($secret)
        } $secretMaskPlainSecret
    } catch { $secretMaskPlainError = $_.Exception.GetType().FullName }
}
Test-BRAVOCondition (
    [System.Uri]::EscapeDataString($secretMaskPlainSecret) -ceq $secretMaskPlainSecret -and
    [string]$secretMaskPlainResult -ceq 'a *** b user:***@host-a {"k":"***"} ***' -and
    -not ([string]$secretMaskPlainResult).Contains('******')
) -Name 'Logging/KnownSecretPlainFormStillMasked' `
    -Failure "секрет без спецсимволів має маскуватись як до #417 (очікується 'a *** b user:***@host-a {`"k`":`"***`"} ***', без артефактів подвійного маскування); факт містить секрет: $(([string]$secretMaskPlainResult).Contains($secretMaskPlainSecret)); помилка: $secretMaskPlainError"

Remove-Item -LiteralPath $secretMaskTestRoot -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================
# #417: ЄДИНИЙ resolver імен записів Credential Manager.
# Get-BRAVOCredentialTargetName (BRAVO.Credentials) — канонічний власник
# розв'язання credentialSettings.Targets.<Key>: значення з конфігурації,
# а якщо воно відсутнє/порожнє/лише з пробілів — канонічний дефолт. Ключ
# реєстру прочитаних секретів і пошук у Get-BRAVOLogMaskSecretSet мусять
# давати те саме ім'я, тому незалежна копія цієї політики в runtime-файлі
# — дрейф, який рано чи пізно розсинхронізує маскування.
# ============================================================

# --- (1) Структурний guard: жодного прямого читання ключа з
# credentialSettings.Targets поза власниками. Обсяг — runtime-файли
# комплекту (.ps1/.psm1 з RUNTIME_MANIFEST.json); виключені власник
# resolver-а (modules\BRAVO.Credentials), власник схеми й дефолтів
# конфігурації (modules\BRAVO.Configuration), self-test і CI-інструменти.
# Передача таблиці цілком (-CredentialTargets $credentialSettings.Targets
# для BRAVO.Notifications) і перелік її властивостей (.PSObject) — не
# читання ключа й не порушення.
# #435: таблицею вважається й змінна-псевдонім, якій присвоєно таблицю
# ($t = $credentialSettings.Targets, також через [тип], (...) і ланцюжок
# псевдонімів; обсяг — увесь файл, без урахування областей видимості, тож
# детектор радше перестрахується). Читання ключа через
# <таблиця>.PSObject.Properties['X'] / .Item('X') — теж порушення.
$targetsGuardFindHits = {
    param([string]$SourceText)
    $hits = New-Object System.Collections.Generic.List[int]
    $guardTokens = $null
    $guardErrors = $null
    $guardAst = [System.Management.Automation.Language.Parser]::ParseInput($SourceText, [ref]$guardTokens, [ref]$guardErrors)
    if (@($guardErrors).Count -gt 0) { throw "файл не розбирається ($(@($guardErrors).Count) помилок)" }
    $aliasNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $getVariableName = {
        param($variableNode)
        return (([string]$variableNode.VariablePath.UserPath) -ireplace '^(global|script|local|private):', '')
    }
    $unwrapExpression = {
        param($node)
        while ($null -ne $node) {
            if ($node -is [System.Management.Automation.Language.ConvertExpressionAst]) { $node = $node.Child; continue }
            if ($node -is [System.Management.Automation.Language.ParenExpressionAst]) { $node = $node.Pipeline; continue }
            if ($node -is [System.Management.Automation.Language.PipelineAst]) {
                if (@($node.PipelineElements).Count -ne 1) { break }
                $node = $node.PipelineElements[0]
                continue
            }
            if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) {
                if (@($node.Redirections).Count -gt 0) { break }
                $node = $node.Expression
                continue
            }
            break
        }
        return $node
    }
    $isTargetsTable = {
        param($node)
        $node = & $unwrapExpression $node
        if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
            return $aliasNames.Contains((& $getVariableName $node))
        }
        if ($node -isnot [System.Management.Automation.Language.MemberExpressionAst]) { return $false }
        if ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) { return $false }
        if ($node.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $false }
        if ([string]$node.Member.Value -ine 'Targets') { return $false }
        if ($node.Expression -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $false }
        return ([string]$node.Expression.VariablePath.UserPath -imatch '^((global|script):)?credentialSettings$')
    }
    $isNamedMember = {
        param($node, [string]$MemberName)
        if ($node -isnot [System.Management.Automation.Language.MemberExpressionAst]) { return $false }
        if ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) { return $false }
        if ($node.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $false }
        return ([string]$node.Member.Value -ieq $MemberName)
    }
    # <таблиця>.PSObject.Properties — колекція властивостей таблиці.
    $isTargetsPropertyCollection = {
        param($node)
        if (-not (& $isNamedMember $node 'Properties')) { return $false }
        if (-not (& $isNamedMember $node.Expression 'PSObject')) { return $false }
        return (& $isTargetsTable $node.Expression.Expression)
    }
    # Псевдоніми: до нерухомої точки, щоб ланцюжок $u = $t теж ловився.
    $assignmentNodes = @($guardAst.FindAll({ param($candidate)
                $candidate -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
    $aliasAdded = $true
    while ($aliasAdded) {
        $aliasAdded = $false
        foreach ($assignmentNode in $assignmentNodes) {
            $assignedNode = & $unwrapExpression $assignmentNode.Left
            if ($assignedNode -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            if (-not (& $isTargetsTable $assignmentNode.Right)) { continue }
            if ($aliasNames.Add((& $getVariableName $assignedNode))) { $aliasAdded = $true }
        }
    }
    foreach ($node in @($guardAst.FindAll({ param($candidate)
                    $candidate -is [System.Management.Automation.Language.MemberExpressionAst] -or
                    $candidate -is [System.Management.Automation.Language.IndexExpressionAst] }, $true))) {
        if ($node -is [System.Management.Automation.Language.IndexExpressionAst]) {
            if ((& $isTargetsTable $node.Target) -or (& $isTargetsPropertyCollection $node.Target)) { $hits.Add($node.Extent.StartLineNumber) }
            continue
        }
        if ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            (& $isTargetsPropertyCollection $node.Expression)) {
            $hits.Add($node.Extent.StartLineNumber)
            continue
        }
        if (-not (& $isTargetsTable $node.Expression)) { continue }
        if ($node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            [string]$node.Member.Value -ieq 'PSObject') { continue }
        $hits.Add($node.Extent.StartLineNumber)
    }
    $hits
}

# Самоперевірка детектора на синтетичному тексті: інакше зламаний
# детектор (0 знахідок завжди) мовчки дав би PASS.
$targetsGuardSelfCheckProblems = New-Object System.Collections.Generic.List[string]
try {
    # #435: обходи через псевдонім таблиці ($t = ...Targets; $t.X / $t['X'],
    # зокрема ланцюжок псевдонімів) і через .PSObject.Properties['X'].Value
    # — теж читання ключа.
    $targetsGuardPositive = @(& $targetsGuardFindHits ('$a = [string]$credentialSettings.Targets.SFTPLogin' + "`n" +
            '$b = $global:credentialSettings.Targets[''SMBLogin'']' + "`n" +
            '$c = $CredentialSettings.Targets.ArchivePassword' + "`n" +
            '$t = $credentialSettings.Targets' + "`n" +
            '$d = $t.SFTPLogin' + "`n" +
            '$e = $t[''SMBLogin'']' + "`n" +
            '$u = ($t)' + "`n" +
            '$f = [string]$u.SFTPPassword' + "`n" +
            '$g = $credentialSettings.Targets.PSObject.Properties[''ArchivePassword''].Value' + "`n" +
            '$h = $t.PSObject.Properties[''SMBPassword''].Value'))
    if ($targetsGuardPositive.Count -ne 8) { $targetsGuardSelfCheckProblems.Add("позитивні зразки: $($targetsGuardPositive.Count) з 8") }
    $targetsGuardNegative = @(& $targetsGuardFindHits ('Send-X -CredentialTargets $credentialSettings.Targets' + "`n" +
            'foreach ($p in $credentialSettings.Targets.PSObject.Properties) { }' + "`n" +
            '$t = $credentialSettings.Targets' + "`n" +
            'Send-X -CredentialTargets $t' + "`n" +
            'foreach ($p in $t.PSObject.Properties) { }' + "`n" +
            '$n = Get-BRAVOCredentialTargetName -CredentialSettings $credentialSettings -Key ''SFTPLogin'''))
    if ($targetsGuardNegative.Count -ne 0) { $targetsGuardSelfCheckProblems.Add("негативні зразки дали знахідки: $($targetsGuardNegative.Count)") }
} catch {
    $targetsGuardSelfCheckProblems.Add("детектор кинув: $($_.Exception.Message)")
}

$targetsGuardHits = New-Object System.Collections.Generic.List[string]
$targetsGuardScanned = 0
$targetsGuardError = ''
try {
    $targetsGuardManifest = [IO.File]::ReadAllText((Join-Path $root 'RUNTIME_MANIFEST.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $targetsGuardPaths = @($targetsGuardManifest.files.PSObject.Properties | ForEach-Object { [string]$_.Name } | Where-Object {
            $_ -imatch '\.(ps1|psm1)$' -and
            $_ -inotmatch '^(selftest|ci)\\' -and
            $_ -inotmatch '^BRAVO_SELF_TEST' -and
            $_ -inotmatch '^modules\\BRAVO\.(Credentials|Configuration)\\'
        } | Sort-Object)
    foreach ($targetsGuardRelativePath in $targetsGuardPaths) {
        $targetsGuardText = [IO.File]::ReadAllText((Join-Path $root $targetsGuardRelativePath), [Text.Encoding]::UTF8)
        $targetsGuardScanned++
        foreach ($targetsGuardLine in @(& $targetsGuardFindHits $targetsGuardText)) {
            $targetsGuardHits.Add("${targetsGuardRelativePath}:$targetsGuardLine")
        }
    }
} catch {
    $targetsGuardError = $_.Exception.Message
}
Test-BRAVOCondition (
    [string]::IsNullOrEmpty($targetsGuardError) -and
    $targetsGuardSelfCheckProblems.Count -eq 0 -and
    $targetsGuardScanned -gt 20 -and
    $targetsGuardHits.Count -eq 0
) -Name 'Credentials/NoDirectTargetsReadOutsideResolver' `
    -Failure "ім'я запису Credential Manager розв'язується лише через Get-BRAVOCredentialTargetName (BRAVO.Credentials); прямі читання credentialSettings.Targets.<Key>/[...] поза BRAVO.Credentials і BRAVO.Configuration: $($targetsGuardHits.Count) [$(@($targetsGuardHits) -join ', ')]; проскановано файлів: $targetsGuardScanned; самоперевірка детектора: $(@($targetsGuardSelfCheckProblems) -join '; '); помилка: $targetsGuardError"

# --- (2) Характеризація BRAVO_CREDENTIALS_SETUP.ps1: Get-CredentialTarget
# (імена компонентів setup) — тонка проекція на канонічний resolver.
# Справжні функції з джерела; доступу до Credential Manager немає.
$setupTargetComponentKeyMap = [ordered]@{
    'SFTPLogin'                 = 'SFTPLogin'
    'SFTPPassword'              = 'SFTPPassword'
    'SMBLogin'                  = 'SMBLogin'
    'SMBPassword'               = 'SMBPassword'
    'Slack.General'             = 'SlackWebhookGeneral'
    'Slack.Alerts'              = 'SlackWebhookAlerts'
    'Discord.General'           = 'DiscordWebhookGeneral'
    'Discord.Alerts'            = 'DiscordWebhookAlerts'
    'Archive'                   = 'ArchivePassword'
    'InstitutionName'           = 'InstitutionName'
    'InstitutionCode'           = 'InstitutionCode'
    'ArchivePrefix'             = 'ArchivePrefix'
    'OperationsBootstrapSecret' = 'OperationsBootstrapSecret'
}
$setupTargetModule = $null
$setupTargetSetupError = ''
try {
    $setupTargetSourceText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_CREDENTIALS_SETUP.ps1'), [Text.Encoding]::UTF8) + "`n" +
        [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Credentials\BRAVO.Credentials.psm1'), [Text.Encoding]::UTF8)
    $setupTargetModule = New-BRAVOSelfTestRuntimeModule -SourceText $setupTargetSourceText `
        -FunctionNames @('Get-CredentialTarget', 'Get-BRAVOCredentialTargetName')
} catch {
    $setupTargetSetupError = $_.Exception.Message
}

# (2a) Конфігуроване значення лише з пробілів -> канонічний дефолт (як
# у resolver-і й у кожному runtime-читанні), а не пробіли дослівно.
$setupTargetWhitespaceMismatches = New-Object System.Collections.Generic.List[string]
$setupTargetWhitespaceError = $setupTargetSetupError
if ($null -ne $setupTargetModule) {
    try {
        $setupTargetWhitespaceMismatches = & $setupTargetModule {
            param($componentKeyMap)
            $mismatches = New-Object System.Collections.Generic.List[string]
            $whitespaceTargets = @{}
            foreach ($key in @($componentKeyMap.Values)) { $whitespaceTargets[$key] = "  `t " }
            $script:credentialSettings = @{ Targets = $whitespaceTargets }
            foreach ($component in @($componentKeyMap.Keys)) {
                $expected = Get-BRAVOCredentialTargetName -CredentialSettings $null -Key $componentKeyMap[$component]
                $actual = Get-CredentialTarget -Name $component
                if ([string]$actual -cne [string]$expected) { $mismatches.Add("${component}='$actual'") }
            }
            ,$mismatches
        } $setupTargetComponentKeyMap
    } catch { $setupTargetWhitespaceError = $_.Exception.Message; $setupTargetWhitespaceMismatches.Add('error') }
} else {
    $setupTargetWhitespaceMismatches.Add('setup')
}
Test-BRAVOCondition (@($setupTargetWhitespaceMismatches).Count -eq 0) `
    -Name 'Credentials/SetupCredentialTargetWhitespaceUsesCanonicalDefault' `
    -Failure "Get-CredentialTarget (BRAVO_CREDENTIALS_SETUP.ps1) для target-у лише з пробілів має повертати канонічний дефолт Get-BRAVOCredentialTargetName, а не пробіли; розбіжності: $(@($setupTargetWhitespaceMismatches) -join ', '); помилка: $setupTargetWhitespaceError"

# (2b) Незмінна поведінка: непорожнє значення з конфігурації — дослівно;
# відсутній/порожній ключ — канонічний дефолт; невідомий компонент — throw.
$setupTargetMapMismatches = New-Object System.Collections.Generic.List[string]
$setupTargetMapError = $setupTargetSetupError
if ($null -ne $setupTargetModule) {
    try {
        $setupTargetMapMismatches = & $setupTargetModule {
            param($componentKeyMap)
            $mismatches = New-Object System.Collections.Generic.List[string]
            $configuredTargets = @{}
            foreach ($key in @($componentKeyMap.Values)) { $configuredTargets[$key] = "SELFTEST_417_$key" }
            $script:credentialSettings = @{ Targets = $configuredTargets }
            foreach ($component in @($componentKeyMap.Keys)) {
                $actual = Get-CredentialTarget -Name $component
                if ([string]$actual -cne ("SELFTEST_417_" + $componentKeyMap[$component])) { $mismatches.Add("configured:$component") }
            }
            $script:credentialSettings = @{ Targets = @{ SFTPLogin = '' } }
            foreach ($component in @($componentKeyMap.Keys)) {
                $expected = Get-BRAVOCredentialTargetName -CredentialSettings $null -Key $componentKeyMap[$component]
                if ([string](Get-CredentialTarget -Name $component) -cne [string]$expected) { $mismatches.Add("default:$component") }
            }
            $unknownThrew = $false
            try { [void](Get-CredentialTarget -Name 'NoSuchSelfTestComponent') } catch { $unknownThrew = $true }
            if (-not $unknownThrew) { $mismatches.Add('unknown-component-must-throw') }
            ,$mismatches
        } $setupTargetComponentKeyMap
    } catch { $setupTargetMapError = $_.Exception.Message; $setupTargetMapMismatches.Add('error') }
} else {
    $setupTargetMapMismatches.Add('setup')
}
Test-BRAVOCondition (@($setupTargetMapMismatches).Count -eq 0) `
    -Name 'Credentials/SetupCredentialTargetMapsOntoResolver' `
    -Failure "Get-CredentialTarget (BRAVO_CREDENTIALS_SETUP.ps1): непорожній target з конфігурації — дослівно, відсутній/порожній — канонічний дефолт, невідомий компонент — throw; розбіжності: $(@($setupTargetMapMismatches) -join ', '); помилка: $setupTargetMapError"
