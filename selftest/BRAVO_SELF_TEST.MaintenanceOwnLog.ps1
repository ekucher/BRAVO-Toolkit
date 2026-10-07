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
$secretMaskCredentialReadChain = @('Get-BRAVOCredential', 'Get-BRAVOCredentialSecureSecret', 'ConvertFrom-BRAVOSecureSecret', 'Get-BRAVOCredentialSecret')
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
            'Get-BRAVOCredentialTargetName', 'Get-BRAVOArchivePasswordTarget', 'Get-BRAVOLogMaskSecretSet',
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
    $secretMaskLockedUploads = @($secretMaskLockedResult.Uploads)
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
    $secretMaskSetFailUploads = @($secretMaskSetFailResult.Uploads)
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

Remove-Item -LiteralPath $secretMaskTestRoot -Recurse -Force -ErrorAction SilentlyContinue
