# BRAVO_SELF_TEST.Archive.ps1 — BRAVO.Archive.Runtime.ps1 (P2-1/P2-5, PR
# #136 review): рекурсивне впорядкування SFTP-каталогів перед mkdir і
# єдиний call site вивантаження власного логу (успіх / контрольований
# ранній return / фатальний крах / вимкнена опція).
#
# Main() — це вся orchestration-функція BRAVO_ARCHIV (реальний backup,
# VSS, BAZA-синхронізація тощо) і не запускається тут повністю: замість
# цього нижче — (1) справжній функціональний тест чистої функції
# впорядкування каталогів, (2) справжній функціональний тест
# Invoke-BRAVOArchiveOwnLogUpload у ізоляції (стаб SFTP-transport), і
# (3) структурні перевірки, що підтверджують РІВНО ОДИН call site в
# `finally` (а не в хвості Main()/catch) — так само, як інші domain-
# фрагменти цього self-test-у роблять для контрактів, які нереально
# відтворити без повного продакшн-оточення.

$archiveScriptPath = Join-Path $root 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1'
$archiveScriptText = [IO.File]::ReadAllText($archiveScriptPath, [Text.Encoding]::UTF8)
# #480: рантайм-функції Archive викликають Test-/ConvertTo-BRAVOSshHostKeyFingerprint зі Schema-модуля.
Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Schema.psd1') -Force -ErrorAction Stop

# ============================================================
# P2-1: Get-BRAVOSFTPOrderedDirectorySegments — чисте розгортання у
# батьківські сегменти + впорядкування за глибиною (WinSCP mkdir не
# рекурсивний).
# ============================================================

$archiveOrderingModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText $archiveScriptText `
    -FunctionNames @("Get-BRAVOSFTPOrderedDirectorySegments")

# 1) Один вкладений шлях: /logs має йти ПЕРЕД /logs/archiv.
$archiveOrderSingle = @(& $archiveOrderingModule { param($d) Get-BRAVOSFTPOrderedDirectorySegments -Directories $d } @('/logs/archiv'))
Test-BRAVOCondition -Condition (
    $archiveOrderSingle.Count -eq 2 -and
    $archiveOrderSingle[0] -eq '/logs' -and
    $archiveOrderSingle[1] -eq '/logs/archiv'
) -Name 'Archive/SftpDirOrderingParentBeforeChild' `
    -Failure "/logs має бути ПЕРЕД /logs/archiv; отримано: $($archiveOrderSingle -join ', ')"

# 2) Кілька вкладених сегментів: /a/b/c/d -> 4 елементи, зростаюча глибина.
$archiveOrderDeep = @(& $archiveOrderingModule { param($d) Get-BRAVOSFTPOrderedDirectorySegments -Directories $d } @('/a/b/c/d'))
Test-BRAVOCondition -Condition (
    $archiveOrderDeep.Count -eq 4 -and
    ($archiveOrderDeep -join ',') -eq '/a,/a/b,/a/b/c,/a/b/c/d'
) -Name 'Archive/SftpDirOrderingMultipleNestedSegments' `
    -Failure "усі 4 батьківські сегменти мають йти в порядку зростання глибини; отримано: $($archiveOrderDeep -join ', ')"

# 3) Кілька незалежних запитів з частково спільними сегментами —
# дедуплікація і стабільний порядок (спершу коротші, потім алфавітно).
$archiveOrderMulti = @(& $archiveOrderingModule { param($d) Get-BRAVOSFTPOrderedDirectorySegments -Directories $d } @('/logs/archiv', '/logs/model', '/logs'))
Test-BRAVOCondition -Condition (
    $archiveOrderMulti.Count -eq 3 -and
    $archiveOrderMulti[0] -eq '/logs' -and
    @($archiveOrderMulti[1], $archiveOrderMulti[2]) -contains '/logs/archiv' -and
    @($archiveOrderMulti[1], $archiveOrderMulti[2]) -contains '/logs/model'
) -Name 'Archive/SftpDirOrderingDeduplicatesSharedParent' `
    -Failure "спільний батьківський /logs має зʼявитись рівно раз і першим; отримано: $($archiveOrderMulti -join ', ')"

# 4) "Батько вже наявний" / "повний шлях уже наявний" — сама функція не
# знає про стан сервера (це відповідальність WinSCP `option batch
# continue`, нижче структурний тест на це); тут перевіряємо лише, що
# ПОВТОРНИЙ запит того самого шляху не породжує дублікатів у списку.
$archiveOrderRepeat = @(& $archiveOrderingModule { param($d) Get-BRAVOSFTPOrderedDirectorySegments -Directories $d } @('/logs', '/logs', '/logs/archiv'))
Test-BRAVOCondition -Condition (
    $archiveOrderRepeat.Count -eq 2
) -Name 'Archive/SftpDirOrderingIdempotentOnRepeatedPath' `
    -Failure "повторний запит уже присутнього каталогу не повинен дублювати сегмент; отримано: $($archiveOrderRepeat -join ', ')"

# 5) Порожній/whitespace вхід ігнорується без винятку.
$archiveOrderEmpty = @(& $archiveOrderingModule { param($d) Get-BRAVOSFTPOrderedDirectorySegments -Directories $d } @('', '  ', $null))
Test-BRAVOCondition -Condition (
    $archiveOrderEmpty.Count -eq 0
) -Name 'Archive/SftpDirOrderingIgnoresBlankInput' `
    -Failure "порожні/blank запити не повинні породжувати сегменти; отримано: $($archiveOrderEmpty -join ', ')"

# ============================================================
# P2-1 (структурні): "проміжний mkdir провалився"/"batch continue" і
# host-key pinning не послаблені. Реальний провал одного mkdir у
# середині пакетного WinSCP-скрипта без живого SFTP-сервера
# невідтворюваний детерміновано в self-test — контракт, що такий провал
# НЕ зупиняє решту пакета (а сама передача даних усе одно перевіряється
# окремо після), гарантує саме "option batch continue" перед mkdir-
# командами; це вже наявна поведінка (не змінена цим PR) — тест фіксує
# контракт, а не додає нову.
# ============================================================

Test-BRAVOCondition -Condition (
    $archiveScriptText -match '(?s)option batch continue\r?\noption confirm off\r?\nopen \$RepositorySFTPUrl -hostkey="\$HostKey".*?\$mkdirCommands'
) -Name 'Archive/SftpMkdirBatchContinuesPastIntermediateFailure' `
    -Failure "'option batch continue' має передувати mkdir-командам, щоб провал одного сегмента (уже наявний/проміжний) не зупиняв решту пакета"

Test-BRAVOCondition -Condition (
    $archiveScriptText -match '-hostkey="\$HostKey"' -and
    $archiveScriptText -notmatch '-hostkey=\$' -and
    $archiveScriptText -notmatch '(?i)accept.?any.?host.?key|AcceptAny|-hostkey=\*'
) -Name 'Archive/SftpMkdirPreservesHostKeyPinning' `
    -Failure "рекурсивне створення каталогів не повинно послаблювати обов'язкове SSH host-key pinning"

# ============================================================
# P2-5: Invoke-BRAVOArchiveOwnLogUpload — функціональна ізоляція
# (тумблер/відсутня конфігурація/помилка transport), плюс структурні
# перевірки єдиного call site.
# ============================================================

$archiveOwnLogStub = @'
function Write-BRAVOLog { param([string]$Component, [string]$Message, [string]$Level = "INFO", [switch]$Secondary) }
function Initialize-BRAVOSFTPRemoteDirectories {
    param([string]$WinSCPPath, [string]$RepositorySFTPUrl, [string]$HostKey, [string[]]$RemoteDirectories)
    $script:archiveOwnLogTestState.InitDirCalls++
}
function Send-FileViaWinSCP {
    param([string]$WinSCPPath, [string]$RepositorySFTPUrl, [string]$HostKey, [string]$LocalFilePath, [string]$RemoteDirectory)
    $script:archiveOwnLogTestState.SendCalls++
    if ($script:archiveOwnLogTestState.SendShouldThrow) {
        throw "simulated SFTP transport failure"
    }
    return $script:archiveOwnLogTestState.SendReturnValue
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
$archiveOwnLogFunctionNames = @("Write-BRAVOLog", "Initialize-BRAVOSFTPRemoteDirectories", "Send-FileViaWinSCP",
    "Get-BRAVOLogMaskSecretSet", "New-BRAVOMaskedLogCopy", "Remove-BRAVOMaskedLogCopy", "Invoke-BRAVOArchiveOwnLogUpload")
$archiveOwnLogCombinedSource = $archiveOwnLogStub + "`n" + $archiveScriptText
$archiveOwnLogModule = New-BRAVOSelfTestRuntimeModule -SourceText $archiveOwnLogCombinedSource -FunctionNames $archiveOwnLogFunctionNames

$archiveOwnLogTestRoot = Join-Path $env:TEMP "BRAVOSelfTest_ArchiveOwnLog_$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $archiveOwnLogTestRoot -Force)
$archiveOwnLogFile = Join-Path $archiveOwnLogTestRoot 'run.log'
[IO.File]::WriteAllText($archiveOwnLogFile, 'log contents')

function Invoke-BRAVOSelfTestArchiveOwnLogUploadScenario {
    param(
        [Parameter(Mandatory = $true)][object]$Module,
        [bool]$Enabled = $true,
        [bool]$SftpEnabled = $true,
        [bool]$DefineConfig = $true,
        [bool]$SendShouldThrow = $false,
        [bool]$SendReturnValue = $true,
        [string]$HostKey = 'ssh-ed25519 255 SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCdE',
        [string]$LogFilePath
    )
    & $Module {
        param($enabled, $sftpEnabled, $defineConfig, $sendShouldThrow, $sendReturnValue, $logFilePath, $hostKey)
        $script:archiveOwnLogTestState = [pscustomobject]@{
            InitDirCalls    = 0
            SendCalls       = 0
            SendShouldThrow = $sendShouldThrow
            SendReturnValue = $sendReturnValue
        }
        if ($defineConfig) {
            # P1 (PR #136 review, r3943997859): у реальному прогоні
            # Complete-BRAVOConfigurationLoad проєктує componentSettings/
            # storageEffective ЛИШЕ у $global: (ніколи у script-scope) —
            # фікстура повинна відтворювати саме це, інакше тест мовчки
            # перевіряв код, якого немає в production.
            $global:componentSettings = [pscustomobject]@{ SFTP = [pscustomobject]@{ ArchiveLogUploadEnabled = $enabled } }
            $global:storageEffective = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $sftpEnabled } }
            $script:sftpUrl = 'sftp://selftest@127.0.0.1/'
            $script:sftpHostKey = $hostKey
            $script:winSCPPath = 'C:\Windows\System32\cmd.exe'
            $script:sftpDirectories = [pscustomobject]@{ ArchivLog = 'logs/archiv' }
            $script:logFile = $logFilePath
        } else {
            Remove-Variable -Name componentSettings -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name storageEffective -Scope Global -ErrorAction SilentlyContinue
        }
        $script:processExitCodeBefore = 42
        $script:processExitCode = 42
        Invoke-BRAVOArchiveOwnLogUpload
        [pscustomobject]@{
            InitDirCalls      = $script:archiveOwnLogTestState.InitDirCalls
            SendCalls         = $script:archiveOwnLogTestState.SendCalls
            ProcessExitCode   = $script:processExitCode
        }
    } $Enabled $SftpEnabled $DefineConfig $SendShouldThrow $SendReturnValue $LogFilePath $HostKey
}

# (a) Тумблер вимкнений (дефолт) -> 0 спроб вивантаження.
$archiveOwnLogDisabled = Invoke-BRAVOSelfTestArchiveOwnLogUploadScenario -Module $archiveOwnLogModule -Enabled $false -LogFilePath $archiveOwnLogFile
Test-BRAVOCondition -Condition (
    $archiveOwnLogDisabled.InitDirCalls -eq 0 -and
    $archiveOwnLogDisabled.SendCalls -eq 0
) -Name 'Archive/OwnLogUploadDisabledMakesZeroAttempts' `
    -Failure "ArchiveLogUploadEnabled=`$false має пропускати вивантаження без жодної спроби; факт: init=$($archiveOwnLogDisabled.InitDirCalls) send=$($archiveOwnLogDisabled.SendCalls)"

# (b) Тумблер увімкнений, повна конфігурація -> рівно 1 спроба вивантаження.
$archiveOwnLogEnabled = Invoke-BRAVOSelfTestArchiveOwnLogUploadScenario -Module $archiveOwnLogModule -Enabled $true -LogFilePath $archiveOwnLogFile
Test-BRAVOCondition -Condition (
    $archiveOwnLogEnabled.InitDirCalls -eq 1 -and
    $archiveOwnLogEnabled.SendCalls -eq 1
) -Name 'Archive/OwnLogUploadEnabledMakesExactlyOneAttempt' `
    -Failure "ArchiveLogUploadEnabled=`$true з повною конфігурацією має вивантажити РІВНО ОДИН раз; факт: init=$($archiveOwnLogEnabled.InitDirCalls) send=$($archiveOwnLogEnabled.SendCalls)"

# (c) Найранніший крах — componentSettings/storageEffective ще не існують
# (симулює крах ДО завантаження конфігурації) -> тихий no-op, БЕЗ винятку.
$archiveOwnLogNoConfig = Invoke-BRAVOSelfTestArchiveOwnLogUploadScenario -Module $archiveOwnLogModule -DefineConfig $false -LogFilePath $archiveOwnLogFile
Test-BRAVOCondition -Condition (
    $archiveOwnLogNoConfig.InitDirCalls -eq 0 -and
    $archiveOwnLogNoConfig.SendCalls -eq 0
) -Name 'Archive/OwnLogUploadMissingConfigIsSilentNoOpNotThrow' `
    -Failure "крах до завантаження конфігурації не повинен кидати виняток назовні — має трактуватись як 'нічого вивантажувати'"

# (d) Transport кидає виняток -> best-effort: не кидає далі,
# $script:processExitCode лишається незмінним (телеметрія власного логу
# ніколи не змінює первинний результат прогону).
$archiveOwnLogSendFails = Invoke-BRAVOSelfTestArchiveOwnLogUploadScenario -Module $archiveOwnLogModule -Enabled $true -SendShouldThrow $true -LogFilePath $archiveOwnLogFile
Test-BRAVOCondition -Condition (
    $archiveOwnLogSendFails.SendCalls -eq 1 -and
    $archiveOwnLogSendFails.ProcessExitCode -eq 42
) -Name 'Archive/OwnLogUploadTransportFailureNeverChangesExitCode' `
    -Failure "збій transport під час вивантаження власного логу не повинен змінювати `$script:processExitCode (первинний результат прогону); факт: exitCode=$($archiveOwnLogSendFails.ProcessExitCode)"

Remove-Item -LiteralPath $archiveOwnLogTestRoot -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================
# #365 (SECURITY): Invoke-BRAVOArchiveOwnLogUpload вивантажує на SFTP
# масковану КОПІЮ власного логу — точні значення секретів Credential
# Manager (SFTP/SMB/7-Zip/Operations/webhook) замінено на ***, навіть без
# ключового слова поруч. Справжні production-функції (AST) з
# BRAVO.Archive.Runtime.ps1, BRAVO.Credentials і BRAVO.Logging; стаби лише
# на межах: Credential Manager (Get-BRAVOCredential — сам CredRead), WinSCP-
# транспорт (Send-FileViaWinSCP, Initialize-BRAVOSFTPRemoteDirectories) і
# лог-синк (Write-BRAVOLog). Секрети — синтетичні плейсхолдери.
# ============================================================

$archiveSecretMaskLoggingText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Logging\BRAVO.Logging.psm1'), [Text.Encoding]::UTF8)
$archiveSecretMaskCredentialsText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Credentials\BRAVO.Credentials.psm1'), [Text.Encoding]::UTF8)
# Значення будуються під час запуску з коротких низькоентропійних частин
# (конвенція репозиторію: жодного суцільного секрето-подібного літерала).
$archiveSecretMaskNewValue = { param([string]$Prefix) $Prefix + [guid]::NewGuid().ToString('N').Substring(0, 12) }
$archiveSecretMaskWebhookFormat = 'https://{0}/synthetic/ar-{1}-{2}'
$archiveSecretMaskByKey = [ordered]@{
    SFTPPassword              = (& $archiveSecretMaskNewValue 'ArSftp')
    SMBPassword               = (& $archiveSecretMaskNewValue 'ArSmb-')
    ArchivePassword           = (& $archiveSecretMaskNewValue 'Ar7z!')
    OperationsBootstrapSecret = (& $archiveSecretMaskNewValue 'ArBoot')
    OperationsApiKey          = (& $archiveSecretMaskNewValue 'ar-ops-')
    SlackWebhookGeneral       = ($archiveSecretMaskWebhookFormat -f 'hooks.example.invalid', 'slack-general', (& $archiveSecretMaskNewValue 'W'))
    SlackWebhookAlerts        = ($archiveSecretMaskWebhookFormat -f 'hooks.example.invalid', 'slack-alerts', (& $archiveSecretMaskNewValue 'W'))
    DiscordWebhookGeneral     = ($archiveSecretMaskWebhookFormat -f 'chat.example.invalid', 'discord-general', (& $archiveSecretMaskNewValue 'W'))
    DiscordWebhookAlerts      = ($archiveSecretMaskWebhookFormat -f 'chat.example.invalid', 'discord-alerts', (& $archiveSecretMaskNewValue 'W'))
}
# Конфігурація без Targets -> усі target-и резолвляться в канонічні дефолти.
$archiveSecretMaskByTarget = @{
    'BRAVO_SFTP_PASSWORD'               = $archiveSecretMaskByKey['SFTPPassword']
    'BRAVO_SMB_PASSWORD'                = $archiveSecretMaskByKey['SMBPassword']
    'BRAVO_7Z_PASSWORD'                 = $archiveSecretMaskByKey['ArchivePassword']
    'BRAVO_OPERATIONS_BOOTSTRAP_SECRET' = $archiveSecretMaskByKey['OperationsBootstrapSecret']
    'BRAVO_OPERATIONS_API_KEY'          = $archiveSecretMaskByKey['OperationsApiKey']
    'BRAVO_SLACK_GENERAL_URL'           = $archiveSecretMaskByKey['SlackWebhookGeneral']
    'BRAVO_SLACK_ALERTS_URL'            = $archiveSecretMaskByKey['SlackWebhookAlerts']
    'BRAVO_DISCORD_GENERAL_URL'         = $archiveSecretMaskByKey['DiscordWebhookGeneral']
    'BRAVO_DISCORD_ALERTS_URL'          = $archiveSecretMaskByKey['DiscordWebhookAlerts']
}

$archiveSecretMaskStub = @'
function Write-BRAVOLog {
    param([string]$Component, [string]$Message, [string]$Level = "INFO", [switch]$Secondary)
    [void]$script:archiveSecretMaskState.LogLines.Add("[$Level] $Message")
}
function Initialize-BRAVOSFTPRemoteDirectories { param([string]$WinSCPPath, [string]$RepositorySFTPUrl, [string]$HostKey, [string[]]$RemoteDirectories) }
function Send-FileViaWinSCP {
    param([string]$WinSCPPath, [string]$RepositorySFTPUrl, [string]$HostKey, [string]$LocalFilePath, [string]$RemoteDirectory)
    $script:archiveSecretMaskState.SentPath = $LocalFilePath
    $script:archiveSecretMaskState.SentText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($LocalFilePath))
    return $true
}
function Get-BRAVOCredential {
    param([string]$Target)
    if (@($script:archiveSecretMaskState.ThrowTargets) -contains $Target) {
        throw (New-Object System.ComponentModel.Win32Exception(1312, ("synthetic CredRead failure for '" + $Target + "' " + $script:archiveSecretMaskState.ExceptionPayload)))
    }
    if ($script:archiveSecretMaskState.SecretByTarget.ContainsKey($Target)) {
        $selfTestSecure = New-Object System.Security.SecureString
        foreach ($selfTestChar in ([string]$script:archiveSecretMaskState.SecretByTarget[$Target]).ToCharArray()) { $selfTestSecure.AppendChar($selfTestChar) }
        $selfTestSecure.MakeReadOnly()
        return [pscustomobject]@{ TargetName = $Target; UserName = ''; Secret = $selfTestSecure }
    }
    return $null
}
'@

$archiveSecretMaskSourceText = $archiveSecretMaskStub + "`n" + $archiveScriptText + "`n" + $archiveSecretMaskCredentialsText + "`n" + $archiveSecretMaskLoggingText
$archiveSecretMaskUploadFunctions = @('Write-BRAVOLog', 'Initialize-BRAVOSFTPRemoteDirectories', 'Send-FileViaWinSCP',
    'Get-BRAVOCredential', 'Get-BRAVOCredentialSecureSecret', 'ConvertFrom-BRAVOSecureSecret', 'Get-BRAVOCredentialSecret', 'Add-BRAVOCredentialReadSecretRecord',
    'Invoke-BRAVOArchiveOwnLogUpload')
$archiveSecretMaskModule = $null
$archiveSecretMaskSetupError = ''
try {
    $archiveSecretMaskModule = New-BRAVOSelfTestRuntimeModule -SourceText $archiveSecretMaskSourceText `
        -FunctionNames ($archiveSecretMaskUploadFunctions + @(
            'Get-BRAVOCredentialTargetName', 'Get-BRAVOLogMaskSecretSet',
            'Protect-BRAVOLogSecret', 'New-BRAVOMaskedLogCopy', 'Remove-BRAVOMaskedLogCopy'
        ))
} catch {
    $archiveSecretMaskSetupError = "production-функції #365 недоступні: $($_.Exception.Message)"
    # Код до #365: сценарій усе одно виконується на наявному шляху
    # вивантаження — і падає на фактичному витоку, а не лише на setup.
    try {
        $archiveSecretMaskModule = New-BRAVOSelfTestRuntimeModule -SourceText $archiveSecretMaskSourceText -FunctionNames $archiveSecretMaskUploadFunctions
    } catch {
        $archiveSecretMaskModule = $null
        $archiveSecretMaskSetupError = "$archiveSecretMaskSetupError; шлях вивантаження недоступний: $($_.Exception.Message)"
    }
}

$archiveSecretMaskRoot = Join-Path $env:TEMP "BRAVOSelfTest_ArchiveSecretMask365_$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $archiveSecretMaskRoot -Force)
$archiveSecretMaskLogName = 'BRAVO_ARCHIV_20260101_020304.log'
$archiveSecretMaskLogFile = Join-Path $archiveSecretMaskRoot $archiveSecretMaskLogName
$archiveSecretMaskLines = New-Object System.Collections.Generic.List[string]
foreach ($archiveSecretMaskKey in @($archiveSecretMaskByKey.Keys)) {
    $archiveSecretMaskLines.Add("2026-01-01 02:03:04.000 [DEBUG  ] [SFTP] raw $($archiveSecretMaskByKey[$archiveSecretMaskKey]) for $archiveSecretMaskKey")
}
[IO.File]::WriteAllText($archiveSecretMaskLogFile, (($archiveSecretMaskLines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($true)))
$archiveSecretMaskOriginalBytes = [IO.File]::ReadAllBytes($archiveSecretMaskLogFile)

$archiveSecretMaskResult = $null
if ($null -ne $archiveSecretMaskModule) {
    $archiveSecretMaskResult = & $archiveSecretMaskModule {
        param($logFilePath, $secretByTarget, $payload)
        $script:archiveSecretMaskState = [pscustomobject]@{
            LogLines         = (New-Object System.Collections.Generic.List[string])
            SecretByTarget   = $secretByTarget
            ThrowTargets     = @('BRAVO_SMB_PASSWORD')
            ExceptionPayload = $payload
            SentPath         = $null
            SentText         = $null
        }
        $script:archiveCatchUpSkipped = $false
        $global:componentSettings = [pscustomobject]@{ SFTP = [pscustomobject]@{ ArchiveLogUploadEnabled = $true } }
        $global:storageEffective = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $true } }
        $script:credentialSettings = @{}
        $script:sftpUrl = 'sftp://selftest@127.0.0.1/'
        $script:sftpHostKey = 'ssh-ed25519 255 SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCdE'
        $script:winSCPPath = 'C:\Windows\System32\cmd.exe'
        $script:sftpDirectories = [pscustomobject]@{ ArchivLog = 'logs/archiv' }
        $script:logFile = $logFilePath
        $script:processExitCode = 42
        $invokeError = ''
        try { Invoke-BRAVOArchiveOwnLogUpload } catch { $invokeError = [string]$_.Exception.Message }
        [pscustomobject]@{
            SentPath        = $script:archiveSecretMaskState.SentPath
            SentText        = $script:archiveSecretMaskState.SentText
            SentCopyRemains = ($null -ne $script:archiveSecretMaskState.SentPath -and (Test-Path -LiteralPath $script:archiveSecretMaskState.SentPath))
            LogLines        = $script:archiveSecretMaskState.LogLines.ToArray()
            ProcessExitCode = $script:processExitCode
            InvokeError     = $invokeError
        }
    } $archiveSecretMaskLogFile $archiveSecretMaskByTarget ("carrying " + $archiveSecretMaskByKey['ArchivePassword'])
}

$archiveSecretMaskLeaks = New-Object System.Collections.Generic.List[string]
$archiveSecretMaskDiagLeaks = New-Object System.Collections.Generic.List[string]
if ($null -ne $archiveSecretMaskResult) {
    $archiveSecretMaskDiagText = (@($archiveSecretMaskResult.LogLines) -join "`n") + "`n" + [string]$archiveSecretMaskResult.InvokeError
    foreach ($archiveSecretMaskKey in @($archiveSecretMaskByKey.Keys)) {
        $archiveSecretMaskValue = [string]$archiveSecretMaskByKey[$archiveSecretMaskKey]
        if ($archiveSecretMaskKey -ne 'SMBPassword' -and ([string]$archiveSecretMaskResult.SentText).Contains($archiveSecretMaskValue)) { $archiveSecretMaskLeaks.Add($archiveSecretMaskKey) }
        if ($archiveSecretMaskDiagText.Contains($archiveSecretMaskValue)) { $archiveSecretMaskDiagLeaks.Add($archiveSecretMaskKey) }
    }
}
Test-BRAVOCondition -Condition (
    $null -ne $archiveSecretMaskResult -and
    -not [string]::IsNullOrEmpty([string]$archiveSecretMaskResult.SentText) -and
    $archiveSecretMaskLeaks.Count -eq 0 -and
    ([string]$archiveSecretMaskResult.SentText).Contains('raw *** for ArchivePassword') -and
    [string]$archiveSecretMaskResult.SentPath -ne $archiveSecretMaskLogFile -and
    [IO.Path]::GetFileName([string]$archiveSecretMaskResult.SentPath) -ceq $archiveSecretMaskLogName -and
    -not $archiveSecretMaskResult.SentCopyRemains -and
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($archiveSecretMaskLogFile)) -ceq [Convert]::ToBase64String($archiveSecretMaskOriginalBytes)
) -Name 'Archive/OwnLogUploadMasksCredentialSecretsInUploadedBytes' `
    -Failure "Archive має вивантажувати масковану копію власного логу (те саме remote-ім'я, копію прибрано, локальний лог незмінний) без жодного точного значення секрету Credential Manager; витекли ключі: $($archiveSecretMaskLeaks -join ', '); помилка: $archiveSecretMaskSetupError"

$archiveSecretMaskInfo = @()
$archiveSecretMaskWarn = @()
if ($null -ne $archiveSecretMaskResult) {
    $archiveSecretMaskInfo = @($archiveSecretMaskResult.LogLines | Where-Object { $_.StartsWith('[INFO]') -and $_.Contains('BRAVO_SMB_PASSWORD') })
    $archiveSecretMaskWarn = @($archiveSecretMaskResult.LogLines | Where-Object { $_.StartsWith('[WARNING]') -or $_.StartsWith('[ERROR]') })
}
Test-BRAVOCondition -Condition (
    $null -ne $archiveSecretMaskResult -and
    $archiveSecretMaskInfo.Count -ge 1 -and
    $archiveSecretMaskWarn.Count -eq 0 -and
    $archiveSecretMaskDiagLeaks.Count -eq 0 -and
    (@($archiveSecretMaskResult.LogLines) -join "`n") -notmatch 'synthetic CredRead failure' -and
    [int]$archiveSecretMaskResult.ProcessExitCode -eq 42 -and
    [string]::IsNullOrEmpty([string]$archiveSecretMaskResult.InvokeError)
) -Name 'Archive/OwnLogUploadInaccessibleTargetSkippedWithInfoNoLeak' `
    -Failure "недоступний target (CredRead кидає) — INFO з іменем target-а, без WARNING/ERROR, без тексту винятку і жодного секрету в діагностиці, exit code незмінний; INFO=$($archiveSecretMaskInfo.Count) WARNING/ERROR=$($archiveSecretMaskWarn.Count) витекли ключі: $($archiveSecretMaskDiagLeaks -join ', '); помилка: $archiveSecretMaskSetupError"

# --- #365 review: fail-closed і для Archive (дзеркало
# Maintenance/OwnLogUploadFailsClosedWhenMaskedCopyUnavailable). Лог
# заблоковано (FileShare.None) -> масковану копію створити неможливо ->
# Send-FileViaWinSCP НЕ викликається взагалі (немаскований лог назовні не
# йде), WARNING без секретів, виняток назовні не йде, exit code незмінний.
$archiveSecretMaskLockedResult = $null
if ($null -ne $archiveSecretMaskModule) {
    $archiveSecretMaskLockHandle = [IO.File]::Open($archiveSecretMaskLogFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archiveSecretMaskLockedResult = & $archiveSecretMaskModule {
            param($logFilePath, $secretByTarget)
            $script:archiveSecretMaskState = [pscustomobject]@{
                LogLines         = (New-Object System.Collections.Generic.List[string])
                SecretByTarget   = $secretByTarget
                ThrowTargets     = @()
                ExceptionPayload = ''
                SentPath         = $null
                SentText         = $null
            }
            $script:archiveCatchUpSkipped = $false
            $global:componentSettings = [pscustomobject]@{ SFTP = [pscustomobject]@{ ArchiveLogUploadEnabled = $true } }
            $global:storageEffective = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $true } }
            $script:credentialSettings = @{}
            $script:sftpUrl = 'sftp://selftest@127.0.0.1/'
            $script:sftpHostKey = 'ssh-ed25519 255 SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCdE'
            $script:winSCPPath = 'C:\Windows\System32\cmd.exe'
            $script:sftpDirectories = [pscustomobject]@{ ArchivLog = 'logs/archiv' }
            $script:logFile = $logFilePath
            $script:processExitCode = 42
            $invokeError = ''
            try { Invoke-BRAVOArchiveOwnLogUpload } catch { $invokeError = [string]$_.Exception.Message }
            [pscustomobject]@{
                SentPath        = $script:archiveSecretMaskState.SentPath
                LogLines        = $script:archiveSecretMaskState.LogLines.ToArray()
                ProcessExitCode = $script:processExitCode
                InvokeError     = $invokeError
            }
        } $archiveSecretMaskLogFile $archiveSecretMaskByTarget
    } finally {
        $archiveSecretMaskLockHandle.Dispose()
    }
}
$archiveSecretMaskLockedWarn = @()
$archiveSecretMaskLockedLeaks = New-Object System.Collections.Generic.List[string]
if ($null -ne $archiveSecretMaskLockedResult) {
    $archiveSecretMaskLockedWarn = @($archiveSecretMaskLockedResult.LogLines | Where-Object { $_.StartsWith('[WARNING]') })
    $archiveSecretMaskLockedDiag = (@($archiveSecretMaskLockedResult.LogLines) -join "`n") + "`n" + [string]$archiveSecretMaskLockedResult.InvokeError
    foreach ($archiveSecretMaskKey in @($archiveSecretMaskByKey.Keys)) {
        if ($archiveSecretMaskLockedDiag.Contains([string]$archiveSecretMaskByKey[$archiveSecretMaskKey])) { $archiveSecretMaskLockedLeaks.Add($archiveSecretMaskKey) }
    }
}
Test-BRAVOCondition -Condition (
    $null -ne $archiveSecretMaskLockedResult -and
    $null -eq $archiveSecretMaskLockedResult.SentPath -and
    $archiveSecretMaskLockedWarn.Count -ge 1 -and
    $archiveSecretMaskLockedLeaks.Count -eq 0 -and
    [int]$archiveSecretMaskLockedResult.ProcessExitCode -eq 42 -and
    [string]::IsNullOrEmpty([string]$archiveSecretMaskLockedResult.InvokeError)
) -Name 'Archive/OwnLogUploadFailsClosedWhenMaskedCopyUnavailable' `
    -Failure "збій маскування (копію не створено) — fail-closed: жодної передачі немаскованого логу, WARNING без секретів, exit code незмінний, виняток назовні не йде; передано: $(if ($null -ne $archiveSecretMaskLockedResult) { $null -ne $archiveSecretMaskLockedResult.SentPath } else { 'n/a' }); WARNING=$($archiveSecretMaskLockedWarn.Count); витекли ключі: $($archiveSecretMaskLockedLeaks -join ', '); помилка: $archiveSecretMaskSetupError"

Remove-Item -LiteralPath $archiveSecretMaskRoot -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================
# P2-5 (структурні): РІВНО ОДИН call site — у зовнішньому `finally`, а
# НЕ в хвості Main() і НЕ в catch. Це саме контракт, який покриває
# сценарії "успіх", "контрольований ранній return" (Main має 5 таких
# return, кожен з власним footer/summary ПЕРЕД return) і "фатальний
# крах" — з чистого тексту функції їх не відрізнити без повного
# продакшн-запуску Main(), тому перевіряється структурно.
# ============================================================

$archiveMainBodyMatch = [Text.RegularExpressions.Regex]::Match(
    $archiveScriptText, '(?s)^function Main \{.*?\n\}\r?\n', [Text.RegularExpressions.RegexOptions]::Multiline)
Test-BRAVOCondition -Condition (
    $archiveMainBodyMatch.Success -and
    ($archiveMainBodyMatch.Value -notmatch 'Invoke-BRAVOArchiveOwnLogUpload')
) -Name 'Archive/OwnLogUploadNotCalledFromMainTail' `
    -Failure "хвіст Main() НЕ повинен містити прямий виклик Invoke-BRAVOArchiveOwnLogUpload — інакше 5 контрольованих ранніх return усередині Main() пропускали б вивантаження логу"

# НЕ через lazy regex '\} catch \{.*?' від початку файлу: Invoke-
# BRAVOArchiveOwnLogUpload сам містить кілька "} catch {" (власні
# ізольовані try/catch) розташовані РАНІШЕ у файлі, ніж реальний
# фатальний catch у хвості скрипта — lazy-квантифікатор захоплював би
# ВЕСЬ текст від першого-ліпшого "} catch {" аж до реального "} finally
# {", неминуче поглинаючи саме визначення Invoke-BRAVOArchiveOwnLogUpload
# і даючи хибний FAIL. Натомість шукаємо унікальний маркер реального
# фатального catch ($fatalErrorRecord = $_, зустрічається рівно раз).
$archiveFatalCatchStartIndex = $archiveScriptText.IndexOf('$fatalErrorRecord = $_')
$archiveFatalCatchFinallyIndex = if ($archiveFatalCatchStartIndex -ge 0) {
    $archiveScriptText.IndexOf('} finally {', $archiveFatalCatchStartIndex)
} else { -1 }
$archiveFatalCatchBlockText = if ($archiveFatalCatchStartIndex -ge 0 -and $archiveFatalCatchFinallyIndex -gt $archiveFatalCatchStartIndex) {
    $archiveScriptText.Substring($archiveFatalCatchStartIndex, $archiveFatalCatchFinallyIndex - $archiveFatalCatchStartIndex)
} else { '' }
Test-BRAVOCondition -Condition (
    $archiveFatalCatchStartIndex -ge 0 -and
    $archiveFatalCatchFinallyIndex -gt $archiveFatalCatchStartIndex -and
    ($archiveFatalCatchBlockText -notmatch 'Invoke-BRAVOArchiveOwnLogUpload')
) -Name 'Archive/OwnLogUploadNotCalledFromFatalCatch' `
    -Failure "фатальний catch НЕ повинен окремо викликати Invoke-BRAVOArchiveOwnLogUpload — єдиний call site тепер у finally, інакше можливе подвійне вивантаження"

Test-BRAVOCondition -Condition (
    ([Text.RegularExpressions.Regex]::Matches($archiveScriptText, 'Invoke-BRAVOArchiveOwnLogUpload\s*$', [Text.RegularExpressions.RegexOptions]::Multiline)).Count -eq 1
) -Name 'Archive/OwnLogUploadHasExactlyOneCallSite' `
    -Failure "у всьому скрипті має бути РІВНО ОДИН виклик Invoke-BRAVOArchiveOwnLogUpload (в finally) — жодного дубльованого call site"

Test-BRAVOCondition -Condition (
    $archiveScriptText -match '(?s)\} finally \{[^\}]*?Invoke-BRAVOArchiveOwnLogUpload'
) -Name 'Archive/OwnLogUploadCallSiteIsInFinallyBlock' `
    -Failure "єдиний call site Invoke-BRAVOArchiveOwnLogUpload має бути у finally — виконується для БУДЬ-ЯКОГО виходу з try (успіх/ранній return/необроблений виняток), рівно один раз"

# Між `} finally {` і вивантаженням логу тепер стоїть ще один спільний
# call site — Send-BRAVOArchiveFinalOperationsEvent (PR #225, P1: фінальна
# Operations-подія мусить відправлятись і для контрольованих ранніх
# return-ів Main, і для фатального краху). Тому шаблон допускає його поряд
# із коментарями, але вимога лишається та сама: вивантаження логу — ДО
# dispose lock-файлу.
Test-BRAVOCondition -Condition (
    $archiveScriptText -match '(?s)\} finally \{\s*((#[^\r\n]*|Send-BRAVOArchiveFinalOperationsEvent)\r?\n\s*)*Invoke-BRAVOArchiveOwnLogUpload\r?\n\s*if \(\$script:archiveProcessLock\)'
) -Name 'Archive/OwnLogUploadPrecedesLockDisposalInFinally' `
    -Failure "вивантаження власного логу має відбуватись ДО dispose lock-файлу/Wait-ForManualExit у finally"

Test-BRAVOCondition -Condition (
    ([Text.RegularExpressions.Regex]::Match($archiveScriptText, '(?s)function Invoke-BRAVOArchiveOwnLogUpload \{.*?\n\}\r?\n')).Value -notmatch '\$script:processExitCode\s*='
) -Name 'Archive/OwnLogUploadNeverAssignsProcessExitCode' `
    -Failure "Invoke-BRAVOArchiveOwnLogUpload — другорядний/телеметричний ефект і не повинен присвоювати `$script:processExitCode"

# ============================================================
# PR #225 (P1 "Report Archive failures that bypass the end of Main"):
# фінальна Operations-подія прогону мусить мати ОДИН спільний шлях
# відправки, який виконується і для нормального завершення, і для п'яти
# контрольованих ранніх return-ів Main, і для фатального краху (код 90).
# Раніше блок лежав у ХВОСТІ Main, тому кожен із цих шляхів лишав
# dashboard без жодної події, хоч і процес, і локальний статус-файл
# рапортували відмову. Той самий структурний контракт, що вже покриває
# Invoke-BRAVOArchiveOwnLogUpload вище, і з тієї самої причини: відрізнити
# ці сценарії без повного продакшн-запуску Main() неможливо.
# ============================================================

Test-BRAVOCondition -Condition (
    ([Text.RegularExpressions.Regex]::Matches($archiveScriptText, 'Send-BRAVOArchiveFinalOperationsEvent\s*$', [Text.RegularExpressions.RegexOptions]::Multiline)).Count -eq 2
) -Name 'Archive/FinalOperationsEventHasExactlyTwoCallSites' `
    -Failure "Send-BRAVOArchiveFinalOperationsEvent має викликатись РІВНО двічі: у хвості Main (багатий контекст) і у finally (гарантія для ранніх return/краху). Сама функція ідемпотентна, тому другий виклик на нормальному шляху -- no-op; будь-яка інша кількість call site-ів означає або втрачений шлях, або дубльовану політику"

Test-BRAVOCondition -Condition (
    $archiveScriptText -match '(?s)\} finally \{\s*((#[^\r\n]*|Invoke-BRAVOArchiveOwnLogUpload)\r?\n\s*)*Send-BRAVOArchiveFinalOperationsEvent'
) -Name 'Archive/FinalOperationsEventCallSiteIsInFinallyBlock' `
    -Failure "один із двох call site-ів Send-BRAVOArchiveFinalOperationsEvent мусить бути у finally: лише finally виконується для БУДЬ-ЯКОГО виходу з try (успіх, контрольований ранній return, необроблений виняток -> код 90)"

$archiveFinalOpsEventBody = ([Text.RegularExpressions.Regex]::Match(
    $archiveScriptText, '(?s)function Send-BRAVOArchiveFinalOperationsEvent \{.*?\n\}\r?\n')).Value
Test-BRAVOCondition -Condition (
    $archiveFinalOpsEventBody -notmatch '\$script:processExitCode\s*=' -and
    $archiveFinalOpsEventBody -match '\$script:archiveFinalOperationsEventSent' -and
    $archiveFinalOpsEventBody -match 'Get-BRAVOExitCodeSeverity'
) -Name 'Archive/FinalOperationsEventIsIdempotentAndNeverChangesExitCode' `
    -Failure "Send-BRAVOArchiveFinalOperationsEvent мусить бути ідемпотентною (прапорець `$script:archiveFinalOperationsEventSent), брати severity з канонічної Get-BRAVOExitCodeSeverity (а не зі статусу generation -- COMPLETE з кодом 10 звітував SUCCESS) і НІКОЛИ не присвоювати `$script:processExitCode (телеметрія не змінює результат прогону)"

Test-BRAVOCondition -Condition (
    ([Text.RegularExpressions.Regex]::Matches($archiveScriptText, 'Send-BRAVOOperationsEventSafely\s+`')).Count -ge 1 -and
    $archiveFinalOpsEventBody -match 'Send-BRAVOOperationsEvent'
) -Name 'Archive/FinalOperationsEventOwnsTheGenerationEmission' `
    -Failure "сама відправка зведеної generation-події мусить жити всередині Send-BRAVOArchiveFinalOperationsEvent, а не дублюватись у хвості Main -- інакше дві копії політики severity/Details розійдуться"

# Регресія PS 5.1 binder (знайдено CI цього PR, BRAVO_DATA_RESTORE_MATRIX_TEST):
# @($script:BRAVOArchiveStepHistory) кидав ArgumentException "Argument types
# do not match" (PSToObjectArrayBinder, той самий задокументований edge-case,
# що вже описаний біля $probeGroupList у цьому модулі, біля $emptyDirs у
# BRAVO.Maintenance.Runtime.ps1 і біля $model у BRAVO.Configurator.Model.psm1).
# Спрацьовувало на КОЖНОМУ прогоні з непорожньою історією кроків, тобто
# зведена generation-подія не доходила в Operations узагалі. Той самий
# цільовий guard, що вже існує для $generationResults
# (Archive/GenerationResultsMaterializeSafely у BRAVO_SELF_TEST.ps1).
$archiveStepHistoryFiles = @(
    @{ Path = 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1'; Variable = '$script:BRAVOArchiveStepHistory' },
    @{ Path = 'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1';   Variable = '$script:BRAVOHealthStepHistory' }
)
$archiveStepHistoryProblems = New-Object System.Collections.Generic.List[string]
foreach ($archiveStepHistoryEntry in $archiveStepHistoryFiles) {
    $archiveStepHistoryText = [IO.File]::ReadAllText((Join-Path $root $archiveStepHistoryEntry.Path), [Text.Encoding]::UTF8)
    $archiveStepHistoryVariable = [string]$archiveStepHistoryEntry.Variable
    # Матчимо лише виконуваний рядок присвоєння поля payload-а, а не згадку в
    # коментарі (коментарі в цих файлах НАВМИСНО цитують заборонену форму, щоб
    # пояснити, чому її не використовують).
    $archiveStepHistoryWrapPattern = '(?m)^\s*stages\s*=\s*@\(\s*' + [Text.RegularExpressions.Regex]::Escape($archiveStepHistoryVariable) + '\s*\)'
    $archiveStepHistoryToArrayPattern = '(?m)^\s*stages\s*=\s*' + [Text.RegularExpressions.Regex]::Escape($archiveStepHistoryVariable) + '\.ToArray\(\)'
    if ([Text.RegularExpressions.Regex]::IsMatch($archiveStepHistoryText, $archiveStepHistoryWrapPattern)) {
        [void]$archiveStepHistoryProblems.Add("$($archiveStepHistoryEntry.Path): знайдено заборонену форму stages = @($archiveStepHistoryVariable)")
    }
    if (-not [Text.RegularExpressions.Regex]::IsMatch($archiveStepHistoryText, $archiveStepHistoryToArrayPattern)) {
        [void]$archiveStepHistoryProblems.Add("$($archiveStepHistoryEntry.Path): не знайдено жодного stages = $archiveStepHistoryVariable.ToArray()")
    }
}
Test-BRAVOCondition -Condition ($archiveStepHistoryProblems.Count -eq 0) `
    -Name 'Archive/StepHistoryPayloadUsesToArrayNotArraySubexpression' `
    -Failure ("історія кроків у payload Operations-події мусить розгортатись через .ToArray(), а не @(...): прямий @()-каст " +
        "System.Collections.Generic.List[object] під Windows PowerShell 5.1 кидає ArgumentException у PSToObjectArrayBinder і " +
        "подія не доходить узагалі. Проблеми: " + ([string]::Join('; ', $archiveStepHistoryProblems.ToArray())))

# Функціональна ізоляція тієї самої функції: реальний її текст + стаби
# Send-BRAVOOperationsEvent/Write-Log (New-BRAVOSelfTestRuntimeModule тут не
# підходить -- функція читає $script:-стан, який тест мусить виставляти
# всередині того самого module scope, тому модуль складається напряму з
# тексту функції плюс стаби). Перевіряється саме те, що структурний тест
# перевірити не може: який severity і які Details виходять для кожного
# класу завершення прогону.
$archiveFinalOpsStub = @'
function Send-BRAVOOperationsEventSafely {
    param($OperationsReportingSettings, $CredentialTargets, [string]$InstitutionCode,
          [string]$Category, [string]$Severity, [string]$Message, [string]$Component,
          $Services, $Details)
    [void]$global:BRAVOArchiveSelfTestFinalOpsEvents.Add([pscustomobject]@{
        Severity = $Severity; Message = $Message; Details = $Details; InstitutionCode = $InstitutionCode })
}
function Write-Log { param([string]$Message, [string]$Level = 'INFO') }
'@
$archiveFinalOpsModule = New-Module -ScriptBlock ([scriptblock]::Create(
    $archiveFinalOpsStub + "`r`n" + $archiveFinalOpsEventBody))
Import-Module $archiveFinalOpsModule -Force
$global:BRAVOArchiveSelfTestFinalOpsEvents = New-Object System.Collections.Generic.List[object]

function Invoke-BRAVOSelfTestArchiveFinalOpsScenario {
    # Виставляє $script:-стан ВСЕРЕДИНІ module scope (де функція його й
    # читає) і повертає зібрані події.
    param([AllowNull()]$Context, [Parameter(Mandatory = $true)][int]$ExitCode)

    $global:BRAVOArchiveSelfTestFinalOpsEvents.Clear()
    # Вхідні дані передаються через $global:, а не позиційними аргументами
    # scriptblock-а: значення мусять бути видимі САМЕ в module scope, де
    # функція читає свій $script:-стан.
    $global:BRAVOArchiveSelfTestFinalOpsContext = $Context
    $global:BRAVOArchiveSelfTestFinalOpsExitCode = $ExitCode
    & $archiveFinalOpsModule {
        $script:archiveFinalOperationsEventSent = $false
        $script:archiveFinalOperationsEventContext = $global:BRAVOArchiveSelfTestFinalOpsContext
        $script:processExitCode = $global:BRAVOArchiveSelfTestFinalOpsExitCode
        Send-BRAVOArchiveFinalOperationsEvent
    }
    # .ToArray(), а не @($list) напряму: та сама причина, з якої
    # BRAVO_SELF_TEST.ConfigLoader.ps1 робить $parityDiffsList.ToArray() --
    # розгортання generic-списку в масив мусить бути явним.
    #
    # Unary comma перед результатом обов'язкова: `return @(...)` віддає
    # значення в output stream, і для РІВНО одного елемента викликач
    # отримав би скаляр, а наступний `.Count` під Set-StrictMode 2.0 кинув
    # би PropertyNotFoundException (той самий гейт, що вже описаний біля
    # ConvertTo-BRAVONotificationPayloadText у BRAVO_SELF_TEST.ps1). Усі
    # сценарії нижче очікують саме масив -- один із них навмисно перевіряє
    # РІВНО одну подію.
    $archiveFinalOpsCollectedEvents = $global:BRAVOArchiveSelfTestFinalOpsEvents.ToArray()
    return ,$archiveFinalOpsCollectedEvents
}

# Наявні $global:-значення конфігурації зберігаються й відновлюються нижче:
# цей self-test-фрагмент виконується в тому самому процесі, що й решта, і
# мовчки прибрати чи підмінити реальну конфігурацію означало б зламати
# наступні фрагменти. '<<ABSENT>>' відрізняє "змінної не було" від
# "змінна була і дорівнювала $null" -- той самий прийом, що
# Get-BRAVOEffectiveConfigurationSnapshot.
$archiveFinalOpsSavedGlobals = @{}
foreach ($archiveFinalOpsGlobalName in @('operationsReportingSettings', 'credentialSettings', 'backupMonitoring')) {
    $archiveFinalOpsSavedVariable = Get-Variable -Name $archiveFinalOpsGlobalName -Scope Global -ErrorAction SilentlyContinue
    $archiveFinalOpsSavedGlobals[$archiveFinalOpsGlobalName] = if ($null -ne $archiveFinalOpsSavedVariable) { @{ Present = $true; Value = $archiveFinalOpsSavedVariable.Value } } else { @{ Present = $false; Value = $null } }
}

# Крах ДО завантаження конфігурації: жодної події, жодного винятку (у
# finally виняток телеметрії замаскував би первинну причину завершення).
Remove-Variable -Name operationsReportingSettings -Scope Global -Force -ErrorAction SilentlyContinue
$archiveFinalOpsNoConfigThrew = $false
try { [void](Invoke-BRAVOSelfTestArchiveFinalOpsScenario -Context $null -ExitCode 90) } catch { $archiveFinalOpsNoConfigThrew = $true }
Test-BRAVOCondition -Condition (-not $archiveFinalOpsNoConfigThrew -and $global:BRAVOArchiveSelfTestFinalOpsEvents.Count -eq 0) `
    -Name 'Archive/FinalOperationsEventMissingConfigIsSilentNoOpNotThrow' `
    -Failure "крах до завантаження конфігурації не має давати ні події, ні винятку (Set-StrictMode: звернення до неіснуючої `$global: кинуло б у finally і замаскувало первинну причину); threw=$archiveFinalOpsNoConfigThrew events=$($global:BRAVOArchiveSelfTestFinalOpsEvents.Count)"

$global:operationsReportingSettings = @{ Enabled = $true; ApiBaseUrl = 'https://ops.example.invalid'; ProductType = 'LIMS'; RequestTimeoutSeconds = 5 }
$global:credentialSettings = @{ Targets = @{ OperationsApiKey = 'K'; OperationsBootstrapSecret = 'B' } }
$global:backupMonitoring = @{ InstitutionCode = 'SELFTEST' }

# Контрольований ранній return Main (lock busy, код 20): багатого зведення
# generation не існує, але подія мусить бути -- інакше dashboard вважав би
# актуальним результат ПОПЕРЕДНЬОГО прогону.
$archiveFinalOpsEarly = Invoke-BRAVOSelfTestArchiveFinalOpsScenario -Context $null -ExitCode 20
Test-BRAVOCondition -Condition (
    $archiveFinalOpsEarly.Count -eq 1 -and
    $archiveFinalOpsEarly[0].Severity -eq 'WARNING' -and
    [int]$archiveFinalOpsEarly[0].Details.exitCode -eq 20 -and
    [string]$archiveFinalOpsEarly[0].Details.exitCodeName -eq 'SkippedLockBusy' -and
    [bool]$archiveFinalOpsEarly[0].Details.earlyTermination -and
    [string]$archiveFinalOpsEarly[0].InstitutionCode -eq 'SELFTEST'
) -Name 'Archive/FinalOperationsEventCoversControlledEarlyReturn' `
    -Failure "ранній return Main (код 20) мусить давати РІВНО одну подію з severity WARNING, exitCode/exitCodeName і маркером earlyTermination; отримано $($archiveFinalOpsEarly | ConvertTo-Json -Compress -Depth 5)"

# Ідемпотентність: Main і finally викликають функцію обидва.
$archiveFinalOpsIdempotent = Invoke-BRAVOSelfTestArchiveFinalOpsScenario -Context $null -ExitCode 40
& $archiveFinalOpsModule { Send-BRAVOArchiveFinalOperationsEvent }
Test-BRAVOCondition -Condition ($global:BRAVOArchiveSelfTestFinalOpsEvents.Count -eq 1) `
    -Name 'Archive/FinalOperationsEventIsSentExactlyOncePerRun' `
    -Failure "на нормальному шляху функцію викликають ДВІЧІ (хвіст Main і finally) -- подія мусить піти РІВНО один раз; відправлено $($global:BRAVOArchiveSelfTestFinalOpsEvents.Count)"

# Регресія severity: generation COMPLETE, але резолвлений код 10.
$archiveFinalOpsWarnContext = @{
    Message = 'Generation G1: COMPLETE, прогін УСПІШНО'
    Details = @{ generationId = 'G1'; status = 'COMPLETE'; runOutcome = 'УСПІШНО' }
}
$archiveFinalOpsWarn = Invoke-BRAVOSelfTestArchiveFinalOpsScenario -Context $archiveFinalOpsWarnContext -ExitCode 10
Test-BRAVOCondition -Condition (
    $archiveFinalOpsWarn.Count -eq 1 -and
    $archiveFinalOpsWarn[0].Severity -eq 'WARNING' -and
    [int]$archiveFinalOpsWarn[0].Details.exitCode -eq 10 -and
    [string]$archiveFinalOpsWarn[0].Details.status -eq 'COMPLETE'
) -Name 'Archive/FinalOperationsEventSeverityFollowsResolvedExitCode' `
    -Failure "generation COMPLETE з резолвленим кодом 10 (SuccessWithWarnings) мусить давати WARNING, а не SUCCESS -- інакше подія суперечить власному полю exitCode у своєму ж payload; отримано $($archiveFinalOpsWarn | ConvertTo-Json -Compress -Depth 5)"

$archiveFinalOpsClean = Invoke-BRAVOSelfTestArchiveFinalOpsScenario -Context @{ Message = 'Generation G2: COMPLETE'; Details = @{ generationId = 'G2' } } -ExitCode 0
$archiveFinalOpsFatal = Invoke-BRAVOSelfTestArchiveFinalOpsScenario -Context $null -ExitCode 90
$archiveFinalOpsIntegrity = Invoke-BRAVOSelfTestArchiveFinalOpsScenario -Context $null -ExitCode 33
Test-BRAVOCondition -Condition (
    $archiveFinalOpsClean[0].Severity -eq 'SUCCESS' -and
    $archiveFinalOpsFatal[0].Severity -eq 'ERROR' -and
    $archiveFinalOpsIntegrity[0].Severity -eq 'CRITICAL'
) -Name 'Archive/FinalOperationsEventMapsExitCodeClassesToSeverity' `
    -Failure "0 -> SUCCESS, 90 (InternalError) -> ERROR, 33 (RuntimeIntegrityViolation) -> CRITICAL; отримано $($archiveFinalOpsClean[0].Severity)/$($archiveFinalOpsFatal[0].Severity)/$($archiveFinalOpsIntegrity[0].Severity)"

Remove-Module -Name $archiveFinalOpsModule.Name -Force -ErrorAction SilentlyContinue
Remove-Item -Path function:Invoke-BRAVOSelfTestArchiveFinalOpsScenario -Force -ErrorAction SilentlyContinue
Remove-Variable -Name BRAVOArchiveSelfTestFinalOpsEvents -Scope Global -Force -ErrorAction SilentlyContinue
Remove-Variable -Name BRAVOArchiveSelfTestFinalOpsContext -Scope Global -Force -ErrorAction SilentlyContinue
Remove-Variable -Name BRAVOArchiveSelfTestFinalOpsExitCode -Scope Global -Force -ErrorAction SilentlyContinue
foreach ($archiveFinalOpsGlobalName in @($archiveFinalOpsSavedGlobals.Keys)) {
    $archiveFinalOpsSavedEntry = $archiveFinalOpsSavedGlobals[$archiveFinalOpsGlobalName]
    if ([bool]$archiveFinalOpsSavedEntry.Present) {
        Set-Variable -Name $archiveFinalOpsGlobalName -Scope Global -Value $archiveFinalOpsSavedEntry.Value
    } else {
        Remove-Variable -Name $archiveFinalOpsGlobalName -Scope Global -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# PR #225 (раунд 3, review): Send-ToolIntegrityAlert/Send-BRAVOArchiveFreeSpaceAlert/
# Send-BAZAIncompatibleNameAlert — гейт нотифікації (NoSlack/notificationMode=
# none/route=none/webhook не налаштовано) раніше завершував функцію через
# ранній `return` ДО Operations-події внизу -- dashboard мовчки не бачив
# CRITICAL/WARNING Operations-подію лише тому, що Slack/Discord вимкнено на
# цьому сервері. Фікс: notification-блок більше не `return`-ить -- лише
# логує причину недоставки й падає крізь решту функції; Operations-подія
# викликається завжди незалежно від стану гейту.
#
# Функціональна ізоляція: реальний текст 3 функцій + стаби залежностей
# (New-BRAVOSelfTestRuntimeModule, той самий прийом, що P2-5 OwnLogUpload
# вище) -- $NoSlack = $true детерміновано вмикає гейт (найпростіший спосіб
# відтворити "сповіщення вимкнено"), Send-BRAVOOperationsEvent замінено на
# лічильник викликів замість реального HTTP.
# ============================================================

$archiveGatingStub = @'
function Write-BRAVOLog { param([string]$Component, [string]$Message, [string]$Level = "INFO", [switch]$Secondary) }
function Protect-BRAVOLogSecret { param([string]$Text) return $Text }
function Get-HostInformation { return [pscustomobject]@{} }
function Format-BRAVOUkrainianCount { param($Count, $One, $Few, $Many) return "$Count $Few" }
function New-BRAVOOperatorNotificationMessage {
    param(
        [string]$Severity, [string]$Operation, [string]$ActionText,
        [string[]]$ReasonLines, [string]$InstitutionName, [string]$InstitutionCode,
        $HostInformation, [string[]]$ResultLines, $Timestamp, [string]$ProductName,
        [string]$Version, [string]$BuildId, [string]$LogPath, [string]$LogLabel
    )
    return "stub-notification-message"
}
function Resolve-BRAVONotificationRoute {
    param($Severity, $NotificationMode, $RoutingTable)
    # Не повинно викликатись у $NoSlack=$true сценарії (гейт коротко
    # замикає ДО цього виклику) -- якщо все ж викликано, повертаємо 'none'
    # (найбезпечніший fallback), а не кидаємо, щоб не приховати справжню
    # причину провалу тесту нижче.
    return 'none'
}
function Resolve-BRAVONotificationEndpoint {
    param($Provider, $Route, $CredentialTargets)
    throw "self-test: Resolve-BRAVONotificationEndpoint НЕ повинен викликатись, коли notification-гейт активний (`$NoSlack=`$true)"
}
function ConvertTo-BRAVONotificationPayloadText { param($Provider, $Message) return @($Message) }
function Send-BRAVONotificationChunks {
    param($Provider, $WebhookUrl, $MessageChunks, $TimeoutSeconds)
    throw "self-test: Send-BRAVONotificationChunks НЕ повинен викликатись, коли notification-гейт активний (`$NoSlack=`$true)"
}
function Send-BRAVOOperationsEventSafely {
    param($OperationsReportingSettings, $CredentialTargets, $InstitutionCode, $Category, $Severity, $Component, $Message, $Services, $Details)
    $script:archiveGatingTestState.OperationsEventCalls++
    $script:archiveGatingTestState.LastMessage = $Message
    $script:archiveGatingTestState.LastSeverity = $Severity
}
'@
$archiveGatingFunctionNames = @(
    'Write-BRAVOLog', 'Protect-BRAVOLogSecret', 'Get-HostInformation', 'Format-BRAVOUkrainianCount',
    'New-BRAVOOperatorNotificationMessage', 'Resolve-BRAVONotificationRoute', 'Resolve-BRAVONotificationEndpoint',
    'ConvertTo-BRAVONotificationPayloadText', 'Send-BRAVONotificationChunks', 'Send-BRAVOOperationsEventSafely',
    'Send-ToolIntegrityAlert', 'Send-BRAVOArchiveFreeSpaceAlert', 'Send-BAZAIncompatibleNameAlert'
)
$archiveGatingCombinedSource = $archiveGatingStub + "`n" + $archiveScriptText
$archiveGatingModule = New-BRAVOSelfTestRuntimeModule -SourceText $archiveGatingCombinedSource -FunctionNames $archiveGatingFunctionNames

function Initialize-BRAVOSelfTestArchiveGatingScriptScope {
    param([Parameter(Mandatory = $true)][object]$Module)
    & $Module {
        $script:archiveGatingTestState = [pscustomobject]@{ OperationsEventCalls = 0; LastMessage = $null; LastSeverity = $null }
        $script:NoSlack = $true
        $script:notificationMode = 'discord'
        $script:notificationProvider = 'discord'
        $script:notificationProviderDisplayName = 'Discord'
        $script:notificationRequestTimeoutSeconds = 5
        $script:logFile = 'C:\selftest\archiv.log'
        $script:ScriptBuildId = 'selftest-build'
        $global:ScriptVersion = '9.9.9-selftest'
        $global:ScriptBuildId = 'selftest-build'
        $script:backupMonitoring = [pscustomobject]@{
            InstitutionName = 'SelfTest Institution'; InstitutionCode = 'ST1'
            NotificationRouting = @{}; NotificationCredentialTargets = @{}
        }
        $script:operationsReportingSettings = @{ Enabled = $true }
        $script:credentialSettings = [pscustomobject]@{ Targets = @{} }
    }
}

# (a) Send-ToolIntegrityAlert: $NoSlack=$true (гейт активний) -> Operations-
# подія МАЄ БУТИ надіслана рівно 1 раз, попри вимкнене сповіщення.
Initialize-BRAVOSelfTestArchiveGatingScriptScope -Module $archiveGatingModule
$toolIntegrityGatingResult = & $archiveGatingModule {
    Send-ToolIntegrityAlert -Result ([pscustomobject]@{ Message = 'selftest: runtime manifest hash mismatch' })
    $script:archiveGatingTestState
}
Test-BRAVOCondition -Condition (
    $toolIntegrityGatingResult.OperationsEventCalls -eq 1 -and
    $toolIntegrityGatingResult.LastSeverity -eq 'CRITICAL' -and
    $toolIntegrityGatingResult.LastMessage -match 'selftest: runtime manifest hash mismatch'
) -Name 'Archive/ToolIntegrityAlertSendsOperationsEventEvenWhenNotificationGated' `
    -Failure "Send-ToolIntegrityAlert з `$NoSlack=`$true (сповіщення вимкнено) все одно МАЄ надіслати РІВНО 1 Operations-подію (review finding: раніше ранній `return` пропускав цю подію повністю); отримано calls=$($toolIntegrityGatingResult.OperationsEventCalls) severity=$($toolIntegrityGatingResult.LastSeverity)"

# (b) Send-BRAVOArchiveFreeSpaceAlert: та сама перевірка.
Initialize-BRAVOSelfTestArchiveGatingScriptScope -Module $archiveGatingModule
$freeSpaceGatingResult = & $archiveGatingModule {
    Send-BRAVOArchiveFreeSpaceAlert -Result ([pscustomobject]@{ Problems = @('C: недостатньо місця'); DriveStatus = @() }) -MinimumFreeSpaceGB 10
    $script:archiveGatingTestState
}
Test-BRAVOCondition -Condition (
    $freeSpaceGatingResult.OperationsEventCalls -eq 1 -and
    $freeSpaceGatingResult.LastSeverity -eq 'CRITICAL'
) -Name 'Archive/FreeSpaceAlertSendsOperationsEventEvenWhenNotificationGated' `
    -Failure "Send-BRAVOArchiveFreeSpaceAlert з `$NoSlack=`$true все одно МАЄ надіслати РІВНО 1 Operations-подію; отримано calls=$($freeSpaceGatingResult.OperationsEventCalls) severity=$($freeSpaceGatingResult.LastSeverity)"

# (c) Send-BAZAIncompatibleNameAlert: та сама перевірка (severity WARNING,
# не CRITICAL -- відмінний контракт цієї функції, не регресія).
Initialize-BRAVOSelfTestArchiveGatingScriptScope -Module $archiveGatingModule
$bazaNameGatingResult = & $archiveGatingModule {
    Send-BAZAIncompatibleNameAlert -Issues @([pscustomobject]@{ Name = 'дуже_довге_імя_файлу.dat'; Utf8ByteCount = 300; MaximumUtf8Bytes = 255 })
    $script:archiveGatingTestState
}
Test-BRAVOCondition -Condition (
    $bazaNameGatingResult.OperationsEventCalls -eq 1 -and
    $bazaNameGatingResult.LastSeverity -eq 'WARNING'
) -Name 'Archive/BAZAIncompatibleNameAlertSendsOperationsEventEvenWhenNotificationGated' `
    -Failure "Send-BAZAIncompatibleNameAlert з `$NoSlack=`$true все одно МАЄ надіслати РІВНО 1 Operations-подію; отримано calls=$($bazaNameGatingResult.OperationsEventCalls) severity=$($bazaNameGatingResult.LastSeverity)"

# ============================================================
# T011 (F010): поведінкова перевірка оркестрації Main.
#
# Порядок фаз, звільнення ресурсів узгодженої копії та код завершення
# досі перевірялися лише структурно. Archive НЕ зупиняє служб: узгодженість
# дає ОДИН VSS Snapshot Set на generation (live-архівація заборонена), тому
# парні ресурси прогону тут — VSS Snapshot Set (створення -> видалення у
# finally циклу компонентів, разом із файлом ownership state) і process
# lock (Enter-BRAVOArchiveProcessLock -> Dispose у зовнішньому finally).
#
# Повний прогін неможливий без конфігурації, VSS, 7-Zip і прав
# адміністратора, тому дочірній процес збирає runtime з ДОСЛІВНОГО тексту
# BRAVO.Archive.Runtime.ps1 (AST): усе тіло Invoke-BRAVOArchive від першого
# визначення функції до кінця — справжні Main, New-BRAVOBackupGenerationState,
# Write-BRAVOArchiveStep, зовнішній try { Main } catch -> 90 / finally і
# фінальний Exit. Преамбулу (імпорт модулів, конфігурацію, елевацію,
# креденшели) замінює seed змінних; VSS, lock, 7-Zip/SHA512, manifest,
# retention, Health, статус-файл, Operations-подія і вивантаження власного
# логу — стаби, що пишуть події у журнал. BRAVO.Console, BRAVO.Logging і
# BRAVO.ExitCodes справжні (Resolve-BRAVOExitCode, статистика WARNING/ERROR).
# Зібраний runtime запускається через справжній Invoke-BRAVOArchiveEntrypoint
# (& runtime, $LASTEXITCODE). Стаби живуть лише в дочірньому процесі;
# жодних VSS-знімків, служб чи мережі тест не чіпає.
# ============================================================
& {
    $archiveOrchestrationRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_ARCHIVE_ORCHESTRATION_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($archiveOrchestrationRoot)
        $archiveOrchestrationStubs = @'
function Add-ProbeEvent { param([string]$Text) [IO.File]::AppendAllText($script:ProbeEventsPath, $Text + "`n", (New-Object Text.UTF8Encoding($false))) }
function Test-Compatibility { return $true }
function Enter-BRAVOArchiveProcessLock {
    param([string]$TaskType)
    Add-ProbeEvent "LOCK-ENTER $TaskType"
    if ($script:ProbeScenario -eq 'LockBusy') {
        # Штатна відмова справжньої функції, коли бюджет очікування
        # (Get-BRAVOOperationLockWaitBudget) вичерпано, а lock досі зайнятий.
        return [pscustomobject]@{ Success = $false; Stream = $null; Path = 'self-test-lock'; Error = 'lock не звільнився за 0 хв. (self-test)' }
    }
    $probeLockStream = [pscustomobject]@{ Path = 'self-test-lock' }
    $probeLockStream | Add-Member -MemberType ScriptMethod -Name Dispose -Value { Add-ProbeEvent 'LOCK-RELEASE' }
    return [pscustomobject]@{ Success = $true; Stream = $probeLockStream; Path = 'self-test-lock'; Error = $null }
}
function Get-BRAVOVSSOwnershipStatePath { return $script:ProbeVssStatePath }
function Remove-BRAVOOwnedOrphanVSSResources {
    param([string]$StatePath)
    Add-ProbeEvent 'VSS-ORPHAN-CHECK'
    if ($script:ProbeScenario -eq 'OrphanVssFails') {
        # #291: штатна відмова справжньої функції — орфанний знімок BRAVO не
        # вдалося видалити, тому архівацію заблоковано (exit 40).
        return [pscustomobject]@{ Success = $false; Found = $true; Deleted = 0; Error = 'self-test: не вдалося видалити orphan VSS' }
    }
    return [pscustomobject]@{ Success = $true; Found = $false; Deleted = 0; Error = $null }
}
function Get-BRAVOArchiveFreeSpaceResult {
    param($RootPath, $MinimumFreeSpaceGB, $ExcludedDrives)
    return [pscustomobject]@{ Success = $true; CheckedDriveCount = 1; AllExcluded = $false; DriveStatus = @(); Problems = @() }
}
function Get-BRAVOArchiveEstimatedSpaceRequirement {
    param($EnabledArchives, $ArchiveFileFilter, $HashFileExtension, $MarginPercent)
    return [pscustomobject]@{ Success = $true; ComponentEstimates = @(); VolumeStatus = @(); Problems = @() }
}
function Resolve-BRAVOArchiveSpaceDecision {
    param($EnabledArchives, $EstimatedResult, $MinimumFreeSpaceGB, $ExcludedDrives)
    if ($script:ProbeScenario -eq 'FreeSpaceFails') {
        # #291: preflight вільного місця провалено (exit 40).
        return [pscustomobject]@{ Success = $false; Results = @(); Warnings = @(); Problems = @('self-test: недостатньо вільного місця') }
    }
    return [pscustomobject]@{ Success = $true; Results = @(); Warnings = @(); Problems = @() }
}
function Send-BRAVOArchiveFreeSpaceAlert {
    param($Result, $MinimumFreeSpaceGB)
    Add-ProbeEvent 'FREE-SPACE-ALERT'
}
function Write-BRAVODiskSpaceDecisionLog { param($Results, $Logger) }
function Get-BRAVOFiles { param($Path, $Filter) return @() }
function Import-BRAVODiscoveryBaseline { param($StateRoot, $RuntimeRoot) return [pscustomobject]@{ Problems = @(); Baseline = $null; Source = 'self-test' } }
function Test-BRAVODiscoveryComponentDrift { param($DiscoveryResult, $Baseline, $BaselineSourceKind, $EnabledComponents) return @() }
function Get-BRAVOLastCompleteBackupComponents { param($BackupRoot) return @() }
function Select-BRAVOExpectedArchiveDefinition { param($ArchiveDefinitions, [string[]]$NotInstalledComponents) return @(@($ArchiveDefinitions) | Where-Object { $_.Enabled -and @($NotInstalledComponents) -notcontains [string]$_.Type }) }
function Test-BRAVOBackupComponentInstalled { param([string]$Component, [string[]]$NotInstalledComponents) return (@($NotInstalledComponents) -notcontains $Component) }
function Test-BRAVOBackupBaselineUpdateAllowed { param($GenerationStatus, $BaselineValid, $BackupScope, $GenerationManifestPath) return ($GenerationStatus -eq 'COMPLETE' -and $BaselineValid -and $null -ne $BackupScope -and -not [string]::IsNullOrWhiteSpace($GenerationManifestPath)) }
function Get-BRAVOLastCompleteBackupEvidence { param($BackupRoot) return [pscustomobject]@{ Components = @(); CreatedAtUtc = $null } }
function Resolve-BRAVOBackupComponentScope {
    param($DiscoveryResult, $Baseline, $BaselineSourceKind, $EnabledComponents, $PreviousCompleteComponents, $PreviousCompleteAt)
    return [pscustomobject]@{ Components = [ordered]@{}; Planned = @(); NotInstalled = @(); EffectiveEnabledComponents = $EnabledComponents; EmptyComposition = $false; Findings = @() }
}
function Update-BRAVODiscoveryBaselineFromScope {
    param($DiscoveryResult, $ScopeResult, $StateRoot, $RuntimeRoot)
    return [pscustomobject]@{ Action = 'Unchanged'; AddedComponents = @(); Path = $null }
}
function Test-PathWithLog { param($Path, $Description, $CreateIfMissing) return $true }
function Show-PathCheckSummary { param($CheckedPaths, $AllPathsExist) }
function Test-BRAVOFileSystemWriteProbe { param($Path) return [pscustomobject]@{ Success = $true; Path = $Path; Error = $null } }
function Test-BRAVOSourceReadProbe { param($Path) return [pscustomobject]@{ Success = $true; Path = $Path; Error = $null } }
function Get-BRAVOCollisionSafeGenerationId { param($BaseGenerationId, $Archives, $ArchivePrefix, $HashExtension) return $BaseGenerationId }
function New-BRAVOVSSSnapshotSet {
    param([string[]]$SourcePaths)
    Add-ProbeEvent 'VSS-CREATE'
    return [pscustomobject]@{ SnapshotSetId = 'self-test-set'; Volumes = @(); UniqueVolumeCount = 1; CreatedAt = (Get-Date) }
}
function Save-BRAVOVSSOwnershipState {
    param($StatePath, $SnapshotSet, $GenerationId)
    [IO.File]::WriteAllText($StatePath, '{}')
    Add-ProbeEvent 'VSS-OWNERSHIP-SAVE'
    return $true
}
function Remove-BRAVOVSSSnapshotSet {
    param($SnapshotSet)
    Add-ProbeEvent 'VSS-REMOVE'
    return $true
}
function Resolve-BRAVOSnapshotSourcePath { param($SnapshotSet, $OriginalPath) return $OriginalPath }
function Invoke-BRAVOComponentBackup {
    param($Component, $GenerationId, $OriginalSourcePath, $SourcePath, $DestinationDirectory, $ArchiveName, $ArcPath, $ArcParams)
    Add-ProbeEvent "COMPONENT-BACKUP $Component"
    if ($script:ProbeScenario -eq 'ComponentThrows') { throw 'self-test: імітований збій архівації компонента' }
    $probeArchivePath = Join-Path $DestinationDirectory $ArchiveName
    [IO.File]::WriteAllText($probeArchivePath, 'self-test')
    return [pscustomobject]@{
        Component = $Component; GenerationId = $GenerationId; OriginalSourcePath = $OriginalSourcePath
        SnapshotSourcePath = $SourcePath; TemporaryArchivePath = $null; ArchivePath = $probeArchivePath
        HashPath = ($probeArchivePath + '.sha512'); CreateSuccess = $true; IntegritySuccess = $true; HashSuccess = $true
        ArchiveSize = 9; SHA512 = 'self-test'; ErrorStage = $null; Error = $null; LegacyBomPasswordFallbackUsed = $false
    }
}
function Write-BRAVOConsoleDetail {
    param([string]$Message)
    if ($script:ProbeScenario -eq 'UnhandledThrow') { throw 'self-test: імітований неочікуваний збій після публікації компонента' }
}
function Write-BRAVOBackupGenerationManifest {
    param($GenerationState, $BackupRoot)
    Add-ProbeEvent ("MANIFEST-WRITE {0}" -f $GenerationState.Status)
    return (Join-Path $BackupRoot 'self-test-manifest.json')
}
function Remove-BRAVOExpiredBackupGenerations {
    param($BackupRoot, $CurrentGenerationId, $RetentionDays, [ref]$CleanupSectionShown, [ref]$RemovedGenerationCount, $ArchiveDefinitions)
    Add-ProbeEvent 'RETENTION-CLEANUP'
    return $true
}
function Invoke-BRAVOHealthCheck {
    param($ConfigPath, $ConfigPathWasExplicit, [switch]$NotifyOnSuccess, [switch]$NoSlack, $RuntimeRoot, $EntryScriptPath, $BazaSyncResults)
    Add-ProbeEvent 'HEALTH'
    return [pscustomobject]@{ Status = 'Healthy'; Notification = 'self-test'; IssueCount = 0; Error = $null }
}
function Write-BRAVOBackupExecutionState { Add-ProbeEvent 'EXECUTION-STATE' }
function Send-BRAVOArchiveLegacyBomFallbackAlert { param($Results) }
function Write-BRAVOOperationStatus {
    param($StateRoot, $Operation, $ExitCode, $ExitCodeName, $StartedAt, $FinishedAt, $Details)
    Add-ProbeEvent "STATUS $ExitCode"
}
function Send-BRAVOOperationsEventSafely {
    param($OperationsReportingSettings, $CredentialTargets, $InstitutionCode, $Category, $Severity, $Component, $Message, $Details)
    Add-ProbeEvent ("OPS-EVENT {0} {1}" -f $Details['exitCode'], $Severity)
}
function Invoke-BRAVOArchiveOwnLogUpload { Add-ProbeEvent 'OWN-LOG-UPLOAD' }
function Write-BRAVOStepResult {
    param([int]$Current, [int]$Total, [string]$Name, [string]$Status, [string]$Details, $Duration)
    Add-ProbeEvent ("STEP {0}/{1} {2} {3}" -f $Current, $Total, $Name, $Status)
}
'@
        $archiveOrchestrationSeed = @'
# Seed замість преамбули Invoke-BRAVOArchive: один компонент MODEL; SFTP,
# SMB і BAZA-синхронізацію вимкнено; retention generation і post-backup
# Health увімкнено, щоб їхнє місце в послідовності фаз теж перевірялось.
$bravoScriptDirectory = $RuntimeRoot
$runtimeRoot = $RuntimeRoot
$configPath = Join-Path $probeWorkRoot 'BRAVO.config'
$configPathWasExplicit = $false
$ScriptVersion = 'self-test'
$ScriptDate = 'self-test'
$ScriptBuildId = 'self-test'
$logPath = Join-Path $probeWorkRoot 'logs'
$logFileNameTemplate = 'BRAVO_ARCHIV_{0}_PID{1}.log'
$logFileFilter = 'BRAVO_ARCHIV_*.log'
$logRetentionDays = 30
$logTimestampFormat = 'yyyy-MM-dd HH:mm:ss'
$durationFormat = 'hh\:mm\:ss'
$defaultLogLevel = 'INFO'
$logSeparatorLength = 100
$LogLevel = 'INFO'
$consoleSettings = @{ FileLevel = 'INFO'; ConsoleLevel = 'ERROR'; StepWidth = 58 }
$progressSettings = @{ Enabled = $false; ShowOverallProgress = $false; Activity = 'self-test' }
$bravoSettings = [pscustomobject]@{ InstitutionName = 'self-test'; InstitutionCode = 'SELFTEST' }
$rootPath = Join-Path $probeWorkRoot 'lims'
$backupRootPath = Join-Path $probeWorkRoot 'backup'
$stateRoot = Join-Path $probeWorkRoot 'state'
$arcPath = Join-Path $probeWorkRoot 'Tools\7za.exe'
$archiveParams = 'a -t7z'
$archivePrefix = 'SELFTEST'
$hashFileExtension = '.sha512'
$archiveFileFilter = '*.7z'
$archiveDefinitions = @(
    [pscustomobject]@{ Type = 'MODEL'; Enabled = $true; Source = (Join-Path $probeWorkRoot 'lims\Model'); Destination = (Join-Path $probeWorkRoot 'backup\MODEL'); NameTemplate = '{0}_MODEL_{1}.7z' }
)
$componentSettings = @{ Archive = @{ MODEL = $true; BLOG = $false; BRAVOEXCH = $false }; Synchronization = @{ BAZA_APP_LOCAL = $false; BAZA_WWW_LOCAL = $false } }
$bazaSyncEffective = [pscustomobject]@{ Components = @(
    [pscustomobject]@{ Name = 'BAZA_APP'; SftpEnabled = $false },
    [pscustomobject]@{ Name = 'BAZA_WWW'; SftpEnabled = $false }
) }
$storageEffective = [pscustomobject]@{
    SFTP = [pscustomobject]@{ Enabled = $false; ArchiveUpload = $false; DisabledReason = '' }
    SMB = [pscustomobject]@{ Enabled = $false; ArchiveCopy = $false; DisabledReason = '' }
}
$backupConsistency = @{ Mode = 'VSS'; SnapshotContext = 'ClientAccessible' }
$backupMonitoring = @{ Enabled = $true; RunAfterBackup = $true; NotificationMode = 'none'; SlackMode = 'none'; NotifyOnSuccessAfterBackup = $false; InstitutionCode = 'SELFTEST'; SizeSanity = @{ Enabled = $false } }
$compatibilityMode = $false
$enableArchiveDeletion = $true
$enableFailedArchiveDeletion = $false
$failedArchiveRetentionDays = 14
$enableLunchArchiveCleanup = $false
$enableOrphanTempCleanup = $false
$archiveRetentionDays = 183
$archiveMinimumFreeSpaceGB = 1
$archiveFreeSpaceExcludedDrives = @()
$archiveEstimatedSpaceMarginPercent = 25.0
$baseRequiredPaths = @()
$operationLockSettings = @{ Path = (Join-Path $probeWorkRoot 'lock\BRAVO_OPERATION.lock') }
$bravoDiscoveryResult = [pscustomobject]@{ MODEL_SOURCE = (Join-Path $probeWorkRoot 'lims\Model'); BLOG_SOURCE = ''; Reasons = @{ MODEL = 'self-test'; BLOG = 'self-test'; BAZA_APP = 'self-test' } }
$discoveryEnabledComponents = @('MODEL')
$operationsReportingSettings = @{ Enabled = $true }
$credentialSettings = @{ Targets = @{} }
$script:archivePassword = 'self-test-placeholder'
$script:archiveCredentialInitializationError = $null
$script:smbCredential = $null
'@
        $archiveOrchestrationProbeScript = @'
param([string]$Scenario, [string]$RepositoryRoot, [string]$ProbeRoot)
$ErrorActionPreference = 'Stop'
$probeResultPath = Join-Path $ProbeRoot 'result.json'
$probeUtf8 = New-Object Text.UTF8Encoding($false)
try {
    $probeRuntimeText = [IO.File]::ReadAllText(
        (Join-Path $RepositoryRoot 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1'), [Text.Encoding]::UTF8)
    $probeParseErrors = $null
    $probeAst = [Management.Automation.Language.Parser]::ParseInput($probeRuntimeText, [ref]$null, [ref]$probeParseErrors)
    if (@($probeParseErrors).Count -gt 0) { throw "runtime не парситься: $($probeParseErrors[0].Message)" }
    $probeWrapper = @($probeAst.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Invoke-BRAVOArchive'
        }) | Select-Object -First 1
    if ($null -eq $probeWrapper) { throw 'у runtime немає функції Invoke-BRAVOArchive' }
    $probeStatements = @($probeWrapper.Body.EndBlock.Statements)
    $probeRegionStartIndex = -1
    for ($probeIndex = 0; $probeIndex -lt $probeStatements.Count; $probeIndex++) {
        if ($probeStatements[$probeIndex] -is [Management.Automation.Language.FunctionDefinitionAst]) {
            $probeRegionStartIndex = $probeIndex
            break
        }
    }
    if ($probeRegionStartIndex -lt 0) { throw 'у тілі Invoke-BRAVOArchive немає визначень функцій' }
    $probeOuterTry = @($probeStatements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] }) | Select-Object -Last 1
    if ($null -eq $probeOuterTry -or $null -eq $probeOuterTry.Finally -or $probeOuterTry.Body.Extent.Text -notmatch '^\{\s*Main\s*\}$') {
        throw 'у тілі немає зовнішнього try { Main } ... finally'
    }
    if (-not ($probeStatements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Main' })) {
        throw 'у тілі немає функції Main'
    }

    $probeStubs = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $ProbeRoot) 'stubs.ps1'), [Text.Encoding]::UTF8)
    $probeStubNames = @{}
    foreach ($probeStubAst in @([Management.Automation.Language.Parser]::ParseInput($probeStubs, [ref]$null, [ref]$null).EndBlock.Statements)) {
        if ($probeStubAst -is [Management.Automation.Language.FunctionDefinitionAst]) { $probeStubNames[$probeStubAst.Name] = $true }
    }
    # Дослівний текст тіла від першого визначення функції (після преамбули:
    # імпорт модулів, конфігурація, елевація, креденшели, консоль) до кінця
    # (Main, зовнішній try/catch/finally, фінальний Exit). Затінені стабами
    # визначення функцій замінюються пробілами, інакше вони перевизначили б
    # стаб під час виконання.
    $probeRegionStart = $probeStatements[$probeRegionStartIndex].Extent.StartOffset
    $probeRegionEnd = $probeStatements[$probeStatements.Count - 1].Extent.EndOffset
    $probeRegion = New-Object Text.StringBuilder($probeRuntimeText.Substring($probeRegionStart, $probeRegionEnd - $probeRegionStart))
    foreach ($probeDefinition in @($probeWrapper.Body.FindAll({
                    param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]
                }, $true) | Where-Object {
                $_.Extent.StartOffset -ge $probeRegionStart -and $probeStubNames.ContainsKey($_.Name)
            })) {
        $probeLength = $probeDefinition.Extent.EndOffset - $probeDefinition.Extent.StartOffset
        [void]$probeRegion.Remove($probeDefinition.Extent.StartOffset - $probeRegionStart, $probeLength)
        [void]$probeRegion.Insert($probeDefinition.Extent.StartOffset - $probeRegionStart, (' ' * $probeLength))
    }

    $probeEventsPath = Join-Path $ProbeRoot 'events.txt'
    $probeVssStatePath = Join-Path $ProbeRoot 'state\BRAVO_VSS_OWNERSHIP.json'
    foreach ($probeDirectory in @('logs', 'state', 'lims\Model', 'backup\MODEL', 'Tools', 'modules\BRAVO.Health')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $ProbeRoot $probeDirectory))
    }
    # Import-Module справжнього Main потребує валідного маніфесту BRAVO.Health
    # під RuntimeRoot; сам Invoke-BRAVOHealthCheck затінює стаб.
    [IO.File]::WriteAllText((Join-Path $ProbeRoot 'modules\BRAVO.Health\BRAVO.Health.psm1'), '', $probeUtf8)
    [IO.File]::WriteAllText((Join-Path $ProbeRoot 'modules\BRAVO.Health\BRAVO.Health.psd1'), "@{ ModuleVersion = '1.0'; RootModule = 'BRAVO.Health.psm1'; FunctionsToExport = @() }", $probeUtf8)
    $probeScenarioSeed = @(
        ('$script:ProbeEventsPath = ''{0}''' -f $probeEventsPath.Replace("'", "''")),
        ('$script:ProbeVssStatePath = ''{0}''' -f $probeVssStatePath.Replace("'", "''")),
        ('$script:ProbeScenario = ''{0}''' -f $Scenario.Replace("'", "''")),
        ('$probeWorkRoot = ''{0}''' -f $ProbeRoot.Replace("'", "''"))
    ) -join "`n"
    $probeGenerated = @(
        $probeAst.ParamBlock.Extent.Text,
        'function Invoke-BRAVOArchiveOrchestrationProbe {',
        'Set-StrictMode -Version 2.0',
        $probeStubs,
        $probeScenarioSeed,
        [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $ProbeRoot) 'seed.ps1'), [Text.Encoding]::UTF8),
        $probeRegion.ToString(),
        '}',
        'Invoke-BRAVOArchiveOrchestrationProbe'
    ) -join "`n"
    $probeGeneratedPath = Join-Path $ProbeRoot 'runtime.ps1'
    [IO.File]::WriteAllText($probeGeneratedPath, $probeGenerated, (New-Object Text.UTF8Encoding($true)))

    foreach ($probeModule in @('BRAVO.Console', 'BRAVO.Logging', 'BRAVO.ExitCodes', 'BRAVO.Archive')) {
        Import-Module -Name (Join-Path $RepositoryRoot "modules\$probeModule\$probeModule.psd1") -Force
    }
    & (Get-Module -Name 'BRAVO.Archive') { param($Path) $script:runtimePath = $Path } $probeGeneratedPath
    $global:LASTEXITCODE = 77
    $probeErrors = $null
    $ErrorActionPreference = 'Continue'
    $probeExitCode = Invoke-BRAVOArchiveEntrypoint -Parameters @{
        RuntimeRoot = $ProbeRoot
        EntryScriptPath = (Join-Path $ProbeRoot 'BRAVO_ARCHIV.ps1')
        NoPause = $true
    } -ErrorVariable probeErrors 2>$null
    $probeEvents = @()
    if (Test-Path -LiteralPath $probeEventsPath -PathType Leaf) {
        $probeEvents = @([IO.File]::ReadAllLines($probeEventsPath, [Text.Encoding]::UTF8))
    }
    $probeLogLines = @()
    foreach ($probeLogFile in @(Get-ChildItem -LiteralPath (Join-Path $ProbeRoot 'logs') -Filter '*.log' -ErrorAction SilentlyContinue)) {
        $probeLogLines += @([IO.File]::ReadAllLines($probeLogFile.FullName, [Text.Encoding]::UTF8) | Where-Object { $_ -match '\b(ERROR|WARNING|FATAL)\b' })
    }
    $probeResult = [pscustomobject]@{
        ExitCode = [int]$probeExitCode
        ExitCodeName = [string](Get-BRAVOExitCodeName -Code ([int]$probeExitCode))
        Events = $probeEvents
        VssOwnershipStateLeft = [IO.File]::Exists($probeVssStatePath)
        LogProblems = $probeLogLines
        Errors = @(@($probeErrors) | ForEach-Object { [string]$_ })
    }
} catch {
    $probeResult = [pscustomobject]@{ ProbeError = [string]$_.Exception.Message }
}
[IO.File]::WriteAllText($probeResultPath, ($probeResult | ConvertTo-Json -Compress -Depth 4), $probeUtf8)
'@
        $archiveOrchestrationUtf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $archiveOrchestrationRoot 'stubs.ps1'), $archiveOrchestrationStubs, $archiveOrchestrationUtf8)
        [IO.File]::WriteAllText((Join-Path $archiveOrchestrationRoot 'seed.ps1'), $archiveOrchestrationSeed, $archiveOrchestrationUtf8)
        $archiveOrchestrationProbePath = Join-Path $archiveOrchestrationRoot 'probe.ps1'
        [IO.File]::WriteAllText($archiveOrchestrationProbePath, $archiveOrchestrationProbeScript, (New-Object Text.UTF8Encoding($true)))
        $archiveOrchestrationHost = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $archiveOrchestrationResults = @{}
        foreach ($archiveOrchestrationScenario in @('Happy', 'ComponentThrows', 'UnhandledThrow', 'LockBusy', 'FreeSpaceFails', 'OrphanVssFails')) {
            $archiveOrchestrationScenarioRoot = Join-Path $archiveOrchestrationRoot $archiveOrchestrationScenario
            [void][IO.Directory]::CreateDirectory($archiveOrchestrationScenarioRoot)
            # Без -ExecutionPolicy Bypass навмисно (ci\Test-BRAVOForbiddenPattern.ps1
            # не дозволяє нових Bypass-місць): дочірній процес успадковує
            # політику батьківського прогону self-test — через
            # PSExecutionPolicyPreference, коли її задано -ExecutionPolicy,
            # або ту саму машинну політику, за якою вже виконуються локальні
            # непідписані фрагменти й модулі цього прогону.
            $null = & $archiveOrchestrationHost -NoLogo -NoProfile -NonInteractive `
                -File $archiveOrchestrationProbePath `
                -Scenario $archiveOrchestrationScenario -RepositoryRoot $root -ProbeRoot $archiveOrchestrationScenarioRoot
            $archiveOrchestrationResultPath = Join-Path $archiveOrchestrationScenarioRoot 'result.json'
            $archiveOrchestrationResults[$archiveOrchestrationScenario] = if (Test-Path -LiteralPath $archiveOrchestrationResultPath -PathType Leaf) {
                [IO.File]::ReadAllText($archiveOrchestrationResultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            } else {
                [pscustomobject]@{ ProbeError = "проба не записала result.json (код виходу $LASTEXITCODE)" }
            }
        }
        $archiveOrchestrationEvents = {
            param($Result)
            if ($null -ne $Result.PSObject.Properties['ProbeError']) { return @() }
            return @($Result.Events | ForEach-Object { [string]$_ })
        }
        $archiveOrchestrationIndex = {
            param([object[]]$Events, [string]$Pattern)
            for ($eventIndex = 0; $eventIndex -lt $Events.Count; $eventIndex++) {
                if ([string]$Events[$eventIndex] -match $Pattern) { return $eventIndex }
            }
            return -1
        }

        # (1) Щасливий шлях: рівно та послідовність фаз, яку задає Main.
        # Lock і прибирання orphan VSS — до першого етапу; п'ять етапів
        # перевірок до створення знімка; VSS Snapshot Set створено й
        # ownership state збережено ДО архівації компонента, видалено ПІСЛЯ
        # неї й ДО manifest; retention лише після manifest COMPLETE; Health
        # після retention; фінальний manifest, стан виконання, Operations-
        # подія і статус-файл із кодом 0; вивантаження власного логу, і lock
        # звільнено останнім. Файл ownership state прибрано.
        $archiveHappy = $archiveOrchestrationResults['Happy']
        $archiveHappyEvents = @(& $archiveOrchestrationEvents $archiveHappy)
        $archiveHappyExpected = @(
            'LOCK-ENTER Backup',
            'VSS-ORPHAN-CHECK',
            'STEP 1/8 Перевірка вільного місця OK',
            'STEP 2/8 Очищення старих журналів SKIPPED',
            'STEP 3/8 Перевірка середовища OK',
            'STEP 4/8 Перевірка складу джерел OK',
            'STEP 5/8 Перевірка шляхів OK',
            'VSS-CREATE',
            'VSS-OWNERSHIP-SAVE',
            'COMPONENT-BACKUP MODEL',
            'STEP 6/8 Архівація MODEL OK',
            'VSS-REMOVE',
            'MANIFEST-WRITE COMPLETE',
            'RETENTION-CLEANUP',
            'STEP 7/8 Очищення старих backup generation SKIPPED',
            'HEALTH',
            'STEP 8/8 Перевірка резервних копій OK',
            'MANIFEST-WRITE COMPLETE',
            'EXECUTION-STATE',
            'OPS-EVENT 0 SUCCESS',
            'STATUS 0',
            'OWN-LOG-UPLOAD',
            'LOCK-RELEASE'
        )
        Test-BRAVOCondition `
            -Condition (
                $null -eq $archiveHappy.PSObject.Properties['ProbeError'] -and
                $archiveHappy.ExitCode -eq 0 -and
                $archiveHappy.ExitCodeName -eq 'Success' -and
                ($archiveHappyEvents -join '|') -ceq ($archiveHappyExpected -join '|') -and
                -not [bool]$archiveHappy.VssOwnershipStateLeft -and
                @($archiveHappy.LogProblems).Count -eq 0
            ) `
            -Name 'Archive/OrchestrationRunsPhasesInContractOrder' `
            -Failure "Main на щасливому шляху має пройти фази в затвердженому порядку (lock -> перевірки [1/8]..[5/8] -> VSS -> архівація -> видалення VSS -> manifest -> retention -> Health -> статус -> lock звільнено останнім) і завершитися кодом 0 без WARNING/ERROR; проба: $($archiveHappy | ConvertTo-Json -Compress -Depth 4)"

        # (2) Збій архівації компонента (виняток усередині
        # Invoke-BRAVOComponentBackup) обробляється локально: VSS Snapshot Set
        # усе одно видаляється рівно раз і лише після спроби компонента, а
        # ownership state прибрано; generation FAILED, тому retention
        # (видалення старих generation) НЕ запускається й стан виконання не
        # пишеться; код завершення — 40 (LocalArchiveFailed) і в процесі, і в
        # Operations-події, а machine-readable статус-файл записано з кодом 40
        # (ключ Bytes відсутній у невдалого компонента); lock звільнено
        # останнім.
        $archiveComponent = $archiveOrchestrationResults['ComponentThrows']
        $archiveComponentEvents = @(& $archiveOrchestrationEvents $archiveComponent)
        $archiveComponentBackup = & $archiveOrchestrationIndex $archiveComponentEvents '^COMPONENT-BACKUP MODEL$'
        $archiveComponentStep = & $archiveOrchestrationIndex $archiveComponentEvents '^STEP 6/8 Архівація MODEL ERROR$'
        $archiveComponentVssRemove = & $archiveOrchestrationIndex $archiveComponentEvents '^VSS-REMOVE$'
        $archiveComponentManifest = & $archiveOrchestrationIndex $archiveComponentEvents '^MANIFEST-WRITE '
        Test-BRAVOCondition `
            -Condition (
                $null -eq $archiveComponent.PSObject.Properties['ProbeError'] -and
                $archiveComponent.ExitCode -eq 40 -and
                $archiveComponent.ExitCodeName -eq 'LocalArchiveFailed' -and
                $archiveComponentBackup -ge 0 -and
                $archiveComponentStep -gt $archiveComponentBackup -and
                $archiveComponentVssRemove -gt $archiveComponentStep -and
                $archiveComponentManifest -gt $archiveComponentVssRemove -and
                @($archiveComponentEvents | Where-Object { $_ -eq 'VSS-REMOVE' }).Count -eq 1 -and
                [string]$archiveComponentEvents[$archiveComponentManifest] -eq 'MANIFEST-WRITE FAILED' -and
                @($archiveComponentEvents | Where-Object { $_ -eq 'RETENTION-CLEANUP' -or $_ -eq 'EXECUTION-STATE' }).Count -eq 0 -and
                @($archiveComponentEvents | Where-Object { $_ -eq 'OPS-EVENT 40 ERROR' }).Count -eq 1 -and
                @($archiveComponentEvents | Where-Object { $_ -eq 'STATUS 40' }).Count -eq 1 -and
                -not [bool]$archiveComponent.VssOwnershipStateLeft -and
                $archiveComponentEvents.Count -gt 1 -and
                $archiveComponentEvents[$archiveComponentEvents.Count - 1] -eq 'LOCK-RELEASE' -and
                $archiveComponentEvents[$archiveComponentEvents.Count - 2] -eq 'OWN-LOG-UPLOAD' -and
                @($archiveComponentEvents | Where-Object { $_ -eq 'LOCK-RELEASE' }).Count -eq 1
            ) `
            -Name 'Archive/OrchestrationReleasesSnapshotWhenComponentFails' `
            -Failure "збій архівації компонента має лишити VSS Snapshot Set видаленим (рівно раз, після спроби), не запускати retention для FAILED generation, дати код 40 (LocalArchiveFailed) і звільнити lock останнім; проба: $($archiveComponent | ConvertTo-Json -Compress -Depth 4)"

        # (3) Необроблений виняток посеред фази архівації (після публікації
        # компонента, поза локальним catch компонента) проходить крізь
        # finally циклу: VSS Snapshot Set видалено й ownership state
        # прибрано ДО обробки винятку; жодна пізніша фаза (manifest,
        # retention, Health, [7/8], [8/8]) не виконується; зовнішній catch
        # дає 90 (InternalError), пише статус 90 і діагностику в журнал;
        # зовнішній finally надсилає Operations-подію з 90, вивантажує
        # власний лог і звільняє lock останнім.
        $archiveThrow = $archiveOrchestrationResults['UnhandledThrow']
        $archiveThrowEvents = @(& $archiveOrchestrationEvents $archiveThrow)
        $archiveThrowBackup = & $archiveOrchestrationIndex $archiveThrowEvents '^COMPONENT-BACKUP MODEL$'
        $archiveThrowVssRemove = & $archiveOrchestrationIndex $archiveThrowEvents '^VSS-REMOVE$'
        $archiveThrowStatus = & $archiveOrchestrationIndex $archiveThrowEvents '^STATUS 90$'
        Test-BRAVOCondition `
            -Condition (
                $null -eq $archiveThrow.PSObject.Properties['ProbeError'] -and
                $archiveThrow.ExitCode -eq 90 -and
                $archiveThrow.ExitCodeName -eq 'InternalError' -and
                $archiveThrowBackup -ge 0 -and
                $archiveThrowVssRemove -gt $archiveThrowBackup -and
                $archiveThrowStatus -gt $archiveThrowVssRemove -and
                @($archiveThrowEvents | Where-Object { $_ -eq 'VSS-REMOVE' }).Count -eq 1 -and
                @($archiveThrowEvents | Where-Object {
                        $_ -like 'MANIFEST-WRITE*' -or $_ -eq 'RETENTION-CLEANUP' -or $_ -eq 'HEALTH' -or
                        $_ -eq 'EXECUTION-STATE' -or $_ -match '^STEP [78]/8 '
                    }).Count -eq 0 -and
                @($archiveThrowEvents | Where-Object { $_ -eq 'OPS-EVENT 90 ERROR' }).Count -eq 1 -and
                @($archiveThrow.LogProblems | Where-Object { ([string]$_).Contains('self-test: імітований неочікуваний збій після публікації компонента') }).Count -gt 0 -and
                -not [bool]$archiveThrow.VssOwnershipStateLeft -and
                $archiveThrowEvents.Count -gt 1 -and
                $archiveThrowEvents[$archiveThrowEvents.Count - 1] -eq 'LOCK-RELEASE' -and
                $archiveThrowEvents[$archiveThrowEvents.Count - 2] -eq 'OWN-LOG-UPLOAD' -and
                @($archiveThrowEvents | Where-Object { $_ -eq 'LOCK-RELEASE' }).Count -eq 1
            ) `
            -Name 'Archive/OrchestrationReleasesSnapshotAndLockWhenPhaseThrows' `
            -Failure "необроблений виняток у фазі архівації має пройти крізь finally: VSS Snapshot Set видалено до обробки винятку, пізніші фази не виконуються, код 90 (InternalError) у процесі, статусі й Operations-події, lock звільнено останнім; проба: $($archiveThrow | ConvertTo-Json -Compress -Depth 4)"

        # (4) T025: lock не захоплено за бюджет очікування (зайнятий lock,
        # бюджет задачі вичерпано). Main завершується ШТАТНО з кодом 20
        # (SkippedLockBusy з BRAVO.ExitCodes) — у процесі й Operations-події
        # (WARNING), з ERROR-рядком у журналі, а зовнішній finally ще
        # вивантажує власний лог. Жодна фаза під lock (orphan VSS, перевірки,
        # VSS Snapshot Set, архівація, manifest, статус-файл) не запускається
        # і нічого не звільняється, бо нічого не захоплено — фіксується
        # точна послідовність подій. Звичайний запуск (без -SyncBAZA) передає
        # задачу Backup.
        $archiveLockBusy = $archiveOrchestrationResults['LockBusy']
        $archiveLockBusyEvents = @(& $archiveOrchestrationEvents $archiveLockBusy)
        Test-BRAVOCondition `
            -Condition (
                $null -eq $archiveLockBusy.PSObject.Properties['ProbeError'] -and
                $archiveLockBusy.ExitCode -eq 20 -and
                $archiveLockBusy.ExitCodeName -eq 'SkippedLockBusy' -and
                ($archiveLockBusyEvents -join '|') -ceq 'LOCK-ENTER Backup|OPS-EVENT 20 WARNING|OWN-LOG-UPLOAD' -and
                @($archiveLockBusy.LogProblems | Where-Object { ([string]$_) -match '\bERROR\b' -and ([string]$_).Contains('lock не звільнився за 0 хв. (self-test)') }).Count -gt 0
            ) `
            -Name 'Archive/OrchestrationLockWaitTimeoutEndsWithSkippedLockBusy' `
            -Failure "вичерпане очікування операційного lock має завершити Main штатно кодом 20 (SkippedLockBusy) у процесі й Operations-події (WARNING), з ERROR у журналі, без жодної фази під lock і без звільнення незахопленого lock; задача звичайного запуску — Backup; проба: $($archiveLockBusy | ConvertTo-Json -Compress -Depth 4)"

        # (5) #291: lock busy НЕ пише machine-readable статус. Інший екземпляр
        # BRAVO_ARCHIV (чи Maintenance) тримає lock і сам запише свій
        # результат; запис тут перезаписав би статус прогону, що ще йде.
        Test-BRAVOCondition `
            -Condition (
                $null -eq $archiveLockBusy.PSObject.Properties['ProbeError'] -and
                @($archiveLockBusyEvents | Where-Object { $_ -like 'STATUS*' }).Count -eq 0
            ) `
            -Name 'Archive/OrchestrationLockBusyDoesNotWriteStatus' `
            -Failure "lock busy (exit 20) не повинен записувати status-файл Archive: lock тримає інший екземпляр, і його статус не можна перезаписувати; проба: $($archiveLockBusy | ConvertTo-Json -Compress -Depth 4)"

        # (6) #291: провал preflight вільного місця — ранній вихід 40 до
        # будь-якої мутації (VSS, архівація). Без запису статусу моніторинг
        # бачив би "OK" учорашнього прогону, хоча кожна ніч завершується 40.
        # Статус пишеться рівно раз, з кодом 40, ПІСЛЯ рішення preflight і
        # ДО вивантаження власного логу; lock звільнено останнім.
        $archiveFreeSpace = $archiveOrchestrationResults['FreeSpaceFails']
        $archiveFreeSpaceEvents = @(& $archiveOrchestrationEvents $archiveFreeSpace)
        $archiveFreeSpaceStep = & $archiveOrchestrationIndex $archiveFreeSpaceEvents '^STEP 1/8 Перевірка вільного місця ERROR$'
        $archiveFreeSpaceStatus = & $archiveOrchestrationIndex $archiveFreeSpaceEvents '^STATUS 40$'
        $archiveFreeSpaceUpload = & $archiveOrchestrationIndex $archiveFreeSpaceEvents '^OWN-LOG-UPLOAD$'
        Test-BRAVOCondition `
            -Condition (
                $null -eq $archiveFreeSpace.PSObject.Properties['ProbeError'] -and
                $archiveFreeSpace.ExitCode -eq 40 -and
                $archiveFreeSpace.ExitCodeName -eq 'LocalArchiveFailed' -and
                $archiveFreeSpaceStep -ge 0 -and
                $archiveFreeSpaceStatus -gt $archiveFreeSpaceStep -and
                $archiveFreeSpaceUpload -gt $archiveFreeSpaceStatus -and
                @($archiveFreeSpaceEvents | Where-Object { $_ -like 'STATUS*' }).Count -eq 1 -and
                @($archiveFreeSpaceEvents | Where-Object { $_ -eq 'VSS-CREATE' -or $_ -like 'COMPONENT-BACKUP*' -or $_ -like 'MANIFEST-WRITE*' }).Count -eq 0 -and
                $archiveFreeSpaceEvents.Count -gt 1 -and
                $archiveFreeSpaceEvents[$archiveFreeSpaceEvents.Count - 1] -eq 'LOCK-RELEASE'
            ) `
            -Name 'Archive/OrchestrationFreeSpacePreflightFailureWritesStatus' `
            -Failure "провал preflight вільного місця (exit 40) має записати status-файл Archive рівно раз із кодом 40 після рішення preflight і до вивантаження логу, без VSS/архівації; проба: $($archiveFreeSpace | ConvertTo-Json -Compress -Depth 4)"

        # (7) #291: провал очищення orphan VSS — ранній вихід 40 одразу після
        # lock, до будь-якого етапу. Статус пишеться рівно раз, з кодом 40,
        # ПІСЛЯ перевірки orphan VSS; жоден етап не стартує; lock звільнено
        # останнім.
        $archiveOrphan = $archiveOrchestrationResults['OrphanVssFails']
        $archiveOrphanEvents = @(& $archiveOrchestrationEvents $archiveOrphan)
        $archiveOrphanCheck = & $archiveOrchestrationIndex $archiveOrphanEvents '^VSS-ORPHAN-CHECK$'
        $archiveOrphanStatus = & $archiveOrchestrationIndex $archiveOrphanEvents '^STATUS 40$'
        $archiveOrphanUpload = & $archiveOrchestrationIndex $archiveOrphanEvents '^OWN-LOG-UPLOAD$'
        Test-BRAVOCondition `
            -Condition (
                $null -eq $archiveOrphan.PSObject.Properties['ProbeError'] -and
                $archiveOrphan.ExitCode -eq 40 -and
                $archiveOrphan.ExitCodeName -eq 'LocalArchiveFailed' -and
                $archiveOrphanCheck -ge 0 -and
                $archiveOrphanStatus -gt $archiveOrphanCheck -and
                $archiveOrphanUpload -gt $archiveOrphanStatus -and
                @($archiveOrphanEvents | Where-Object { $_ -like 'STATUS*' }).Count -eq 1 -and
                @($archiveOrphanEvents | Where-Object { $_ -like 'STEP *' -or $_ -eq 'VSS-CREATE' -or $_ -like 'COMPONENT-BACKUP*' }).Count -eq 0 -and
                $archiveOrphanEvents.Count -gt 1 -and
                $archiveOrphanEvents[$archiveOrphanEvents.Count - 1] -eq 'LOCK-RELEASE'
            ) `
            -Name 'Archive/OrchestrationOrphanVssCleanupFailureWritesStatus' `
            -Failure "провал очищення orphan VSS (exit 40) має записати status-файл Archive рівно раз із кодом 40 після перевірки orphan VSS і до вивантаження логу, без жодного етапу; проба: $($archiveOrphan | ConvertTo-Json -Compress -Depth 4)"
    } finally {
        if (Test-Path -LiteralPath $archiveOrchestrationRoot -PathType Container) {
            Remove-Item -LiteralPath $archiveOrchestrationRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================
# #291: exit усередині Test-Compatibility (непідтримувана ОС ->
# InvalidConfiguration; заблокована цілісність інструментів ->
# ToolIntegrityViolation) оминає хвіст Main, тож status-файл Archive
# лишався від попереднього прогону. Test-Compatibility викликається з Main
# ПІСЛЯ захоплення lock і після конфігурації ($stateRoot), тому статус
# можна писати безпечно. У пробі оркестрації вона затінена стабом, отже
# тут — структурна перевірка AST: кожен exit у Test-Compatibility має
# безпосередньо перед собою виклик fail-soft helper'а статусу з тим самим
# кодом завершення.
# ============================================================
& {
    $compatParseErrors = $null
    $compatAst = [Management.Automation.Language.Parser]::ParseInput($archiveScriptText, [ref]$null, [ref]$compatParseErrors)
    $compatFunction = @($compatAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-Compatibility'
            }, $true)) | Select-Object -First 1
    $compatExits = @(if ($null -ne $compatFunction) {
            $compatFunction.Body.FindAll({ param($node) $node -is [Management.Automation.Language.ExitStatementAst] }, $true)
        })
    $compatUncoveredExits = @()
    foreach ($compatExit in $compatExits) {
        $compatExitCodeText = if ($null -ne $compatExit.Pipeline) { [string]$compatExit.Pipeline.Extent.Text } else { '' }
        $compatPreviousText = ''
        $compatExitCodeAssignText = ''
        if ($compatExit.Parent -is [Management.Automation.Language.StatementBlockAst]) {
            $compatSiblings = @($compatExit.Parent.Statements)
            for ($compatIndex = 1; $compatIndex -lt $compatSiblings.Count; $compatIndex++) {
                if ([object]::ReferenceEquals($compatSiblings[$compatIndex], $compatExit)) {
                    $compatPreviousText = [string]$compatSiblings[$compatIndex - 1].Extent.Text
                    if ($compatIndex -ge 2) {
                        $compatExitCodeAssignText = [string]$compatSiblings[$compatIndex - 2].Extent.Text
                    }
                    break
                }
            }
        }
        $compatCovered = (
            $compatExitCodeText -match '^\$[A-Za-z]\w*$' -and
            $compatPreviousText -match '^Write-BRAVOArchiveOperationStatus\b' -and
            $compatPreviousText -match ('-ExitCode\s+' + [regex]::Escape($compatExitCodeText) + '(?!\w)') -and
            # Фінальна Operations-подія у finally читає $script:processExitCode.
            $compatExitCodeAssignText -match ('^\$script:processExitCode\s*=\s*' + [regex]::Escape($compatExitCodeText) + '\s*$')
        )
        if (-not $compatCovered) {
            $compatUncoveredExits += [string]$compatExit.Extent.Text
        }
    }
    Test-BRAVOCondition `
        -Condition (
            @($compatParseErrors).Count -eq 0 -and
            $null -ne $compatFunction -and
            $compatExits.Count -ge 2 -and
            $compatUncoveredExits.Count -eq 0
        ) `
        -Name 'Archive/CompatibilityExitsWriteStatusBeforeExit' `
        -Failure "кожен exit у Test-Compatibility має безпосередньо після запису статусу (Write-BRAVOArchiveOperationStatus -ExitCode <той самий код>, перед ним `$script:processExitCode = <той самий код>) завершувати процес, інакше моніторинг бачить застарілий статус; без статусу: $($compatUncoveredExits -join ' | ')"
}


# ============================================================
# #290: таймаут Test-SFTPConnection має повертати $false (шлях "SFTP
# failed", exit 50), а не кидати виняток повз Complete-BRAVOProcessOutputCapture.
# Раніше `throw` після Kill() оминав Complete-BRAVOProcessOutputCapture, який
# звільняє BRAVO_WINSCP lock: викликачі без try завершувались exit 90, а
# lock лишався захопленим до кінця процесу.
#
# Справжній Test-SFTPConnection (AST) запускає справжній Start-BRAVOProcessOutputCapture
# зі стабом WinSCP.com: крихітний консольний exe, що висне (скомпільований
# Add-Type, бо lock береться лише для файлу з іменем WinSCP.com, а .cmd/.ps1
# під UseShellExecute=$false не запускається).
# ============================================================

$sftpTimeoutStub = @'
function Write-BRAVOLog { param([string]$Component, [string]$Message, [string]$Level = "INFO", [switch]$Secondary)
    [void]$script:sftpTimeoutLogEntries.Add([pscustomobject]@{ Level = $Level; Message = $Message }) }
'@
$sftpTimeoutModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText ($sftpTimeoutStub + "`n" + $archiveScriptText) `
    -FunctionNames @('Write-BRAVOLog', 'Test-SFTPConnection')
Import-Module -Name (Join-Path $root 'modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path $root 'modules\BRAVO.ArchiveRuntime\BRAVO.ArchiveRuntime.psd1') -Force -ErrorAction Stop

$sftpTimeoutRoot = Join-Path ([IO.Path]::GetTempPath()) "BRAVOSelfTest_SftpTimeout_$([Guid]::NewGuid().ToString('N'))"
$sftpTimeoutHadGlobalLogPath = Test-Path -LiteralPath 'Variable:global:logPath'
$sftpTimeoutPreviousGlobalLogPath = if ($sftpTimeoutHadGlobalLogPath) { $global:logPath } else { $null }
$sftpTimeoutProbe = $null
$sftpTimeoutStubPath = $null
try {
    [void](New-Item -ItemType Directory -Path $sftpTimeoutRoot -Force)
    $sftpTimeoutLogDir = Join-Path $sftpTimeoutRoot 'logs'
    [void](New-Item -ItemType Directory -Path $sftpTimeoutLogDir -Force)
    $sftpTimeoutStubPath = Join-Path $sftpTimeoutRoot 'WinSCP.com'
    # Справжній PE: компілюємо exe через CodeDom (GenerateExecutable), потім
    # копіюємо під іменем WinSCP.com (CreateProcess вантажить PE незалежно від
    # розширення, як і справжній WinSCP.com).
    $sftpTimeoutStubExe = Join-Path $sftpTimeoutRoot 'stub.exe'
    $sftpTimeoutCompiler = New-Object Microsoft.CSharp.CSharpCodeProvider
    $sftpTimeoutCompilerParameters = New-Object System.CodeDom.Compiler.CompilerParameters
    $sftpTimeoutCompilerParameters.GenerateExecutable = $true
    $sftpTimeoutCompilerParameters.GenerateInMemory = $false
    $sftpTimeoutCompilerParameters.OutputAssembly = $sftpTimeoutStubExe
    $sftpTimeoutCompileResult = $sftpTimeoutCompiler.CompileAssemblyFromSource(
        $sftpTimeoutCompilerParameters,
        'public static class BRAVOSftpHangStub { public static void Main() { System.Threading.Thread.Sleep(120000); } }')
    if (Test-Path -LiteralPath $sftpTimeoutStubExe -PathType Leaf) {
        Copy-Item -LiteralPath $sftpTimeoutStubExe -Destination $sftpTimeoutStubPath -Force
    }
    $sftpTimeoutStubIsPe = $false
    if (Test-Path -LiteralPath $sftpTimeoutStubPath -PathType Leaf) {
        $sftpTimeoutStubHead = New-Object byte[] 2
        $sftpTimeoutStubStream = [IO.File]::OpenRead($sftpTimeoutStubPath)
        try { [void]$sftpTimeoutStubStream.Read($sftpTimeoutStubHead, 0, 2) } finally { $sftpTimeoutStubStream.Dispose() }
        $sftpTimeoutStubIsPe = ($sftpTimeoutStubHead[0] -eq 0x4D -and $sftpTimeoutStubHead[1] -eq 0x5A)
    }
    Test-BRAVOCondition -Condition $sftpTimeoutStubIsPe `
        -Name 'Archive/SftpConnectionTimeoutStubIsRunnable' `
        -Failure "стаб WinSCP.com має бути справжнім PE (MZ), інакше Process.Start не запуститься і таймаут не перевіряється; помилки компіляції: $(@($sftpTimeoutCompileResult.Errors | ForEach-Object { $_.ToString() }) -join ' | ')"
    $global:logPath = $sftpTimeoutLogDir

    $sftpTimeoutProbe = & $sftpTimeoutModule {
        param($StubPath)
        $script:sftpTimeoutLogEntries = New-Object System.Collections.ArrayList
        $script:resolvedSftpHost = '127.0.0.1'
        $script:sftpPort = 22
        $script:winSCPScriptEncoding = 'ASCII'
        $script:winSCPIniPath = 'nul'
        # Таймаут очікування = max(1, N + 30) с; N = -29 дає 1 с (self-test швидкий).
        $script:sftpConnectionTimeoutSeconds = -29
        $thrown = $null
        $result = $null
        try {
            $result = @(Test-SFTPConnection -WinSCPPath $StubPath -RepositorySFTPUrl 'sftp://selftest@127.0.0.1/' -HostKey 'ssh-ed25519 255 SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCdE')
        } catch {
            $thrown = $_.Exception.Message
        }
        [pscustomobject]@{
            Thrown  = $thrown
            Results = $result
            Logs    = @($script:sftpTimeoutLogEntries.ToArray())
        }
    } $sftpTimeoutStubPath

    $sftpTimeoutLockAfter = Enter-BRAVOWinSCPProcessLock -LogPath $sftpTimeoutLogDir
    if ($sftpTimeoutLockAfter.Success -and $sftpTimeoutLockAfter.Stream) {
        $sftpTimeoutLockAfter.Stream.Dispose()
    }

    Test-BRAVOCondition -Condition (
        $null -eq $sftpTimeoutProbe.Thrown -and
        @($sftpTimeoutProbe.Results).Count -eq 1 -and
        $sftpTimeoutProbe.Results[0] -is [bool] -and
        $sftpTimeoutProbe.Results[0] -eq $false
    ) -Name 'Archive/SftpConnectionTimeoutReturnsFalse' `
        -Failure "таймаут перевірки SFTP має повертати `$false (викликачі ведуть у шлях SFTP failed, exit 50), а не кидати виняток; Thrown='$($sftpTimeoutProbe.Thrown)' Results=$(@($sftpTimeoutProbe.Results) -join ',')"

    Test-BRAVOCondition -Condition (
        $sftpTimeoutLockAfter.Success -eq $true
    ) -Name 'Archive/SftpConnectionTimeoutReleasesWinSCPLock' `
        -Failure "після таймауту BRAVO_WINSCP lock має бути звільнений (Complete-BRAVOProcessOutputCapture), інакше наступний WinSCP-запуск блокується; Error=$($sftpTimeoutLockAfter.Error)"

    Test-BRAVOCondition -Condition (
        @($sftpTimeoutProbe.Logs | Where-Object { $_.Level -eq 'ERROR' -and $_.Message -like '*таймаут*' }).Count -ge 1
    ) -Name 'Archive/SftpConnectionTimeoutLogsError' `
        -Failure "таймаут перевірки SFTP має логуватись рівнем ERROR з описом таймауту; журнал: $(@($sftpTimeoutProbe.Logs | ForEach-Object { $_.Level + ':' + $_.Message }) -join ' | ')"
} finally {
    foreach ($sftpTimeoutLeftover in @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -eq $sftpTimeoutStubPath } catch { $false }
        })) {
        try { $sftpTimeoutLeftover.Kill() } catch { Write-Host "self-test cleanup: не вдалося завершити стаб WinSCP: $($_.Exception.Message)" }
    }
    if ($sftpTimeoutHadGlobalLogPath) { $global:logPath = $sftpTimeoutPreviousGlobalLogPath }
    else { Remove-Variable -Name logPath -Scope Global -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $sftpTimeoutRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# #290 (рев'ю P1): BRAVO_WINSCP lock звільняється лише після підтвердженого
# завершення WinSCP. Якщо Kill()/WaitForExit не завершили процес, гілка
# таймауту НЕ викликає Complete-BRAVOProcessOutputCapture (він звільняє lock)
# і йде фатальним шляхом (throw), інакше наступна операція запустила б другий
# WinSCP паралельно. Невбивний процес у self-test не відтворити, тому це
# перевірка тексту справжньої гілки таймауту Test-SFTPConnection.
$sftpTimeoutBranchMatch = [regex]::Match(
    $archiveScriptText,
    'if\s*\(-not \$completed\)\s*\{[\s\S]*?Перевищено таймаут перевірки SFTP-з''єднання \('
)
$sftpTimeoutBranchText = if ($sftpTimeoutBranchMatch.Success) { $sftpTimeoutBranchMatch.Value } else { '' }
$sftpNotExitedBlockMatch = [regex]::Match(
    $sftpTimeoutBranchText,
    'if\s*\(-not \$winSCPExited\)\s*\{[\s\S]*?\bthrow\b[^\r\n]*\r?\n\s*\}'
)
$sftpHasExitedIndex = $sftpTimeoutBranchText.IndexOf('$process.HasExited')
$sftpCompleteIndex = $sftpTimeoutBranchText.IndexOf('Complete-BRAVOProcessOutputCapture')
Test-BRAVOCondition `
    -Condition (
        $sftpTimeoutBranchMatch.Success -and
        $sftpNotExitedBlockMatch.Success -and
        -not $sftpNotExitedBlockMatch.Value.Contains('Complete-BRAVOProcessOutputCapture') -and
        $sftpNotExitedBlockMatch.Value -match '\$script:\w+\s*=\s*\$outputCapture\b' -and
        $sftpHasExitedIndex -ge 0 -and
        $sftpCompleteIndex -gt $sftpHasExitedIndex -and
        $sftpNotExitedBlockMatch.Index -lt $sftpCompleteIndex
    ) `
    -Name 'Archive/SftpConnectionTimeoutKeepsLockWhileWinSCPAlive' `
    -Failure 'гілка таймауту Test-SFTPConnection має перевірити $process.HasExited ДО Complete-BRAVOProcessOutputCapture і, якщо WinSCP не завершився, кинути виняток без звільнення BRAVO_WINSCP lock, зберігши capture (з lock-потоком) у script scope, щоб GC не звільнив lock'

# ============================================================
# Контракт кодів завершення: кожен літеральний `exit <число>` у
# BRAVO.Archive.Runtime.ps1 має належати канонічній множині
# BRAVO.ExitCodes. Множина виводиться з таблиці $script:BRAVOExitCodeNames
# модуля під час тесту (не копія). Голий `exit 1` (конфігурація, UAC,
# параметри установи) раніше був поза контрактом.
# ============================================================

$archiveExitCodesModulePath = Join-Path $root 'modules\BRAVO.ExitCodes\BRAVO.ExitCodes.psm1'
$archiveExitCodesText = [IO.File]::ReadAllText($archiveExitCodesModulePath, [Text.Encoding]::UTF8)
$archiveCanonicalExitCodes = @(
    [regex]::Matches($archiveExitCodesText, '(?m)^\s+(\d+)\s*=\s*"[A-Za-z]+"\s*$') |
        ForEach-Object { [int]$_.Groups[1].Value }
)
$archiveLiteralExitCodes = @(
    [regex]::Matches($archiveScriptText, '(?im)^\s*exit\s+(\d+)\b') |
        ForEach-Object { [int]$_.Groups[1].Value }
)
$archiveNonCanonicalExitCodes = @($archiveLiteralExitCodes | Where-Object { $archiveCanonicalExitCodes -notcontains $_ } | Sort-Object -Unique)
Test-BRAVOCondition `
    -Condition (
        $archiveCanonicalExitCodes.Count -ge 15 -and
        $archiveCanonicalExitCodes -contains 30 -and
        $archiveLiteralExitCodes.Count -ge 5 -and
        $archiveNonCanonicalExitCodes.Count -eq 0
    ) `
    -Name 'Archive/LiteralExitCodesAreCanonical' `
    -Failure "кожен літеральний exit <число> у BRAVO.Archive.Runtime.ps1 має бути кодом із BRAVO.ExitCodes; поза контрактом: [$($archiveNonCanonicalExitCodes -join ', ')]; літералів: $($archiveLiteralExitCodes.Count); канонічних кодів: $($archiveCanonicalExitCodes.Count)"

# ============================================================
# #480 (F3): валідація sftpHostKey у Archive. Невалідний ключ ('*', acceptnew,
# CRLF-ін'єкція, неповний відбиток) -> Test-SFTPConfig = $false (шлях
# $sftpConfigurationValid=$false -> SFTP-гілку заблоковано, локальний архів
# триває, підсумок 30), WinSCP-функції самі fail-closed повертають $false ДО
# створення командного файлу/процесу, власний лог не вивантажується,
# -SyncBAZA завершується 30.
# ============================================================

$archiveHostKeyValid = 'ssh-ed25519 255 SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCdE'
$archiveHostKeyInvalidCases = @(
    @{ Name = 'Star'; Value = '*' }
    @{ Name = 'AcceptNew'; Value = 'acceptnew' }
    @{ Name = 'CrLfPut'; Value = "`"ssh-rsa 2048 aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99`"`r`nput C:\x /" }
    @{ Name = 'ShortFingerprint'; Value = 'ssh-rsa 2048 aa:bb:cc' }
)

$archiveHostKeyStub = @'
function Write-BRAVOLog { param([string]$Component, [string]$Message, [string]$Level = "INFO", [switch]$Secondary)
    [void]$script:archiveHostKeyLog.Add([pscustomobject]@{ Level = $Level; Message = $Message }) }
function New-BRAVOWinSCPTemporaryScriptPath {
    $script:archiveHostKeyScriptCreated++
    return (Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_hostkey_selftest_' + [guid]::NewGuid().ToString('N') + '.txt'))
}
'@
$archiveHostKeyModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText ($archiveHostKeyStub + "`n" + $archiveScriptText) `
    -FunctionNames @('Write-BRAVOLog', 'New-BRAVOWinSCPTemporaryScriptPath', 'Get-BRAVOSFTPOrderedDirectorySegments', 'Test-SFTPConfig', 'Test-SFTPConnection', 'Send-FileViaWinSCP', 'Initialize-BRAVOSFTPRemoteDirectories', 'Sync-FolderToSFTP')
$archiveHostKeyRoot = Join-Path ([IO.Path]::GetTempPath()) "BRAVOSelfTest_ArchiveHostKey_$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $archiveHostKeyRoot -Force)
try {
    $archiveHostKeyLocalFile = Join-Path $archiveHostKeyRoot 'payload.bin'
    [IO.File]::WriteAllText($archiveHostKeyLocalFile, 'payload')
    $archiveHostKeyProbe = & $archiveHostKeyModule {
        param($ValidKey, $Cases, $LocalFile, $LocalDirectory)
        $script:archiveHostKeyLog = New-Object System.Collections.ArrayList
        $script:archiveHostKeyScriptCreated = 0
        $script:credentialInitializationError = ''
        $script:Login = 'selftest'
        $script:sftpUrl = 'sftp://selftest@127.0.0.1/'
        $script:winSCPPath = 'C:\Windows\System32\cmd.exe'
        $script:winSCPScriptEncoding = 'ASCII'
        $script:winSCPIniPath = 'nul'
        $script:resolvedSftpHost = '127.0.0.1'
        $script:sftpPort = 22
        $script:sftpConnectionTimeoutSeconds = 5
        $script:sftpSynchronizationOptions = ''
        $script:sftpDirectories = @{}
        $script:archiveDefinitions = @()
        $script:componentSettings = [pscustomobject]@{
            SFTP = [pscustomobject]@{ ArchiveUpload = $false }
            Synchronization = [pscustomobject]@{ BAZA_APP_SFTP = $false; BAZA_WWW_SFTP = $false }
        }
        $script:synchronizationSafety = [pscustomobject]@{ RequireNonEmptyBAZASource = $false }
        $script:backupMonitoring = [pscustomobject]@{ SFTP = [pscustomobject]@{ OperationTimeoutSeconds = 5 } }
        $script:progressSettings = [pscustomobject]@{ Enabled = $false; ShowWinSCPOutput = $false }

        $script:sftpHostKey = $ValidKey
        $validConfig = Test-SFTPConfig -SynchronizationOnly
        $rows = @()
        foreach ($case in $Cases) {
            $script:archiveHostKeyLog.Clear()
            $script:archiveHostKeyScriptCreated = 0
            $script:sftpHostKey = [string]$case.Value
            $configResult = Test-SFTPConfig -SynchronizationOnly
            $configLog = @($script:archiveHostKeyLog.ToArray() | ForEach-Object { [string]$_.Message })
            $script:archiveHostKeyLog.Clear()
            $connection = @(Test-SFTPConnection -WinSCPPath $script:winSCPPath -RepositorySFTPUrl $script:sftpUrl -HostKey ([string]$case.Value))
            $send = @(Send-FileViaWinSCP -WinSCPPath $script:winSCPPath -RepositorySFTPUrl $script:sftpUrl -HostKey ([string]$case.Value) -LocalFilePath $LocalFile -RemoteDirectory 'x')
            $initialize = @(Initialize-BRAVOSFTPRemoteDirectories -WinSCPPath $script:winSCPPath -RepositorySFTPUrl $script:sftpUrl -HostKey ([string]$case.Value) -RemoteDirectories @('x/y'))
            $sync = @(Sync-FolderToSFTP -WinSCPPath $script:winSCPPath -RepositorySFTPUrl $script:sftpUrl -HostKey ([string]$case.Value) -LocalDirectory $LocalDirectory -RemoteDirectory 'x')
            $rows += [pscustomobject]@{
                Name = [string]$case.Name
                ConfigResult = $configResult
                ConfigLog = $configLog
                Connection = $connection
                Send = $send
                Initialize = $initialize
                Sync = $sync
                ScriptCreated = $script:archiveHostKeyScriptCreated
                Log = @($script:archiveHostKeyLog.ToArray() | ForEach-Object { [string]$_.Message })
            }
        }
        [pscustomobject]@{ ValidConfig = $validConfig; Rows = $rows }
    } $archiveHostKeyValid $archiveHostKeyInvalidCases $archiveHostKeyLocalFile $archiveHostKeyRoot
} finally {
    Remove-Item -LiteralPath $archiveHostKeyRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Test-BRAVOCondition -Condition ([bool]$archiveHostKeyProbe.ValidConfig) `
    -Name 'Archive/HostKeyValidFingerprintPassesSftpConfig' `
    -Failure "Test-SFTPConfig мусить приймати валідний відбиток (ssh-ed25519 255 SHA256:...); інакше SFTP блокується завжди"

$archiveHostKeyConfigFailures = @(
    $archiveHostKeyProbe.Rows | Where-Object {
        $_.ConfigResult -ne $false -or
        @($_.ConfigLog | Where-Object { $_ -like '*SFTP host key*' }).Count -lt 1
    } | ForEach-Object { $_.Name }
)
Test-BRAVOCondition -Condition ($archiveHostKeyConfigFailures.Count -eq 0) `
    -Name 'Archive/HostKeyInvalidFailsSftpConfig' `
    -Failure "Test-SFTPConfig мусить повертати `$false і логувати причину для невалідного sftpHostKey (шлях до exit 30 через `$sftpConfigurationValid); збої: $([string]::Join(', ', $archiveHostKeyConfigFailures))"

$archiveHostKeyTransportFailures = @(
    $archiveHostKeyProbe.Rows | Where-Object {
        -not ($_.Connection.Count -eq 1 -and $_.Connection[0] -eq $false -and
            $_.Send.Count -eq 1 -and $_.Send[0] -eq $false -and
            $_.Sync.Count -eq 1 -and $_.Sync[0] -eq $false -and
            $_.Initialize.Count -eq 0 -and
            $_.ScriptCreated -eq 0 -and
            @($_.Log | Where-Object { $_ -like '*SFTP host key відхилено*' }).Count -eq 4)
    } | ForEach-Object { $_.Name }
)
Test-BRAVOCondition -Condition ($archiveHostKeyTransportFailures.Count -eq 0) `
    -Name 'Archive/HostKeyInvalidNeverCreatesWinSCPScriptOrProcess' `
    -Failure "Test-SFTPConnection/Send-FileViaWinSCP/Initialize-BRAVOSFTPRemoteDirectories/Sync-FolderToSFTP з невалідним ключем мусять fail-closed повернутись ДО створення командного файлу WinSCP (жодного скрипта/процесу); збої: $([string]::Join(', ', $archiveHostKeyTransportFailures))"

$archiveHostKeyEchoes = @(
    $archiveHostKeyProbe.Rows | Where-Object {
        $row = $_
        $value = [string](@($archiveHostKeyInvalidCases | Where-Object { $_.Name -eq $row.Name })[0].Value)
        $value.Length -ge 3 -and $row.Name -ne 'AcceptNew' -and
        @(@($row.Log) + @($row.ConfigLog) | Where-Object { ([string]$_).Contains($value) }).Count -gt 0
    } | ForEach-Object { $_.Name }
)
Test-BRAVOCondition -Condition ($archiveHostKeyEchoes.Count -eq 0) `
    -Name 'Archive/HostKeyInvalidIsNotEchoedToLog' `
    -Failure "журнал не повинен містити сирого значення sftpHostKey; збої: $([string]::Join(', ', $archiveHostKeyEchoes))"

# Власний лог: невалідний ключ -> жодного вивантаження (best-effort WARNING).
$archiveOwnLogBadKey = Invoke-BRAVOSelfTestArchiveOwnLogUploadScenario -Module $archiveOwnLogModule -Enabled $true -HostKey '*' -LogFilePath $archiveOwnLogFile
Test-BRAVOCondition -Condition (
    $archiveOwnLogBadKey.InitDirCalls -eq 0 -and
    $archiveOwnLogBadKey.SendCalls -eq 0
) -Name 'Archive/OwnLogUploadSkippedForInvalidHostKey' `
    -Failure "вивантаження власного логу з sftpHostKey='*' має бути пропущено; факт: init=$($archiveOwnLogBadKey.InitDirCalls) send=$($archiveOwnLogBadKey.SendCalls)"

# -SyncBAZA: невалідна SFTP-конфігурація (зокрема sftpHostKey) -> 30 раніше за SftpFailed.
$archiveSyncExitModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText $archiveScriptText `
    -FunctionNames @('Resolve-BRAVOSyncBazaExitCode')
$archiveSyncExitCodes = & $archiveSyncExitModule {
    [pscustomobject]@{
        InvalidConfig = (Resolve-BRAVOSyncBazaExitCode -SyncSucceeded $false -EmptySourceWarningCount 0 -InvalidConfiguration $true)
        InvalidConfigBeatsSuccess = (Resolve-BRAVOSyncBazaExitCode -SyncSucceeded $true -EmptySourceWarningCount 0 -InvalidConfiguration $true)
        SftpFailed = (Resolve-BRAVOSyncBazaExitCode -SyncSucceeded $false -EmptySourceWarningCount 0)
        Clean = (Resolve-BRAVOSyncBazaExitCode -SyncSucceeded $true -EmptySourceWarningCount 0)
    }
}
Test-BRAVOCondition -Condition (
    $archiveSyncExitCodes.InvalidConfig -eq 30 -and
    $archiveSyncExitCodes.InvalidConfigBeatsSuccess -eq 30 -and
    $archiveSyncExitCodes.SftpFailed -eq (Resolve-BRAVOExitCode -SftpFailed) -and
    $archiveSyncExitCodes.Clean -eq 0 -and
    $archiveScriptText.Contains('ConfigurationInvalid = $true') -and
    $archiveScriptText -match '(?s)Resolve-BRAVOSyncBazaExitCode -SyncSucceeded \$manualSyncSuccess -EmptySourceWarningCount \$syncBazaEmptySourceWarned\.Count -InvalidConfiguration'
) -Name 'Archive/SyncBazaInvalidSftpConfigurationExits30' `
    -Failure "-SyncBAZA з невалідною SFTP-конфігурацією (sftpHostKey) мусить завершуватись 30 (InvalidConfiguration), а не 50; отримано: $($archiveSyncExitCodes | ConvertTo-Json -Compress)"

# ============================================================
# #501: legacy-синхронізація BAZA (Sync-FolderToSFTP) класифікує залишок
# пост-аудиту за знімком локального дерева перед стартом WinSCP. Об'єкти,
# що з'явилися під час циклу, — ПОПЕРЕДЖЕННЯ (код 10), а не ПОМИЛКА; не
# передані об'єкти знімка, змінені під час передачі, ненульовий код WinSCP і
# недоступний аудит лишаються помилкою.
#
# Справжні Sync-FolderToSFTP -> Invoke-BRAVOBazaCanonicalSync ->
# Invoke-ManualBAZASFTPSynchronization; фейкові лише процес WinSCP (cmd.exe
# /c exit N) і read-only порівняння з хмарою. Гонку моделює крок "LIMS пише
# після сканування WinSCP" усередині фейкового старту процесу — без Start-Sleep.
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
        'Invoke-BRAVOBazaCanonicalSync', 'New-BRAVOTransferOperationResult', 'Invoke-ManualBAZASFTPSynchronization',
        'Get-BRAVOManualSyncRunOutcomeLabel', 'Resolve-BRAVOSyncBazaExitCode', 'Resolve-BRAVOLogComponentFromHeader'
    )

# Один прогін -SyncBAZA (або лише Sync-FolderToSFTP): повертає результат,
# мітку, код завершення, outcome-и компонентів і журнал.
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
            $manual = Invoke-ManualBAZASFTPSynchronization -BazaAppEnabled $true -BazaWWWEnabled ([bool]$WithWWW)
        } finally {
            ${function:script:Sync-FolderToSFTP} = $script:late501OriginalSync
        }
        $label = Get-BRAVOManualSyncRunOutcomeLabel -ManualSyncResult $manual
        $exitCode = Resolve-BRAVOSyncBazaExitCode -SyncSucceeded ([bool]$manual.Success) -EmptySourceWarningCount 0 -NewAfterCutoffCount $(if ($manual.PSObject.Properties['NewAfterCutoffCount']) { [int]$manual.NewAfterCutoffCount } else { 0 })
        return [pscustomobject]@{
            Manual = $manual
            Label = $label
            ExitCode = $exitCode
            App = $script:late501Outcomes['BAZA_APP']
            Www = $(if ($script:late501Outcomes.ContainsKey('BAZA_WWW')) { $script:late501Outcomes['BAZA_WWW'] } else { $null })
            Log = @($script:late501Log.ToArray())
            WinSCPRuns = $script:late501WinSCPRuns
        }
    } $CaseRoot $Remote @($DuringSyncWrites) $FailPaths $ExitCode ([bool]$AfterAuditFails) ([bool]$WithWWW) @($Ops) $ProbeCap ([bool]$SnapshotFails) @($ProbeErrorPaths)
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
        $r2.Manual.Results.BAZA_APP.Degraded -and $r2.Manual.Results.SyncOutcomes['BAZA_APP'].NewAfterCutoff -eq 1
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
            Label = Get-BRAVOManualSyncRunOutcomeLabel -ManualSyncResult ([pscustomobject]@{ Success = $true; Skipped = $false; Results = $null })
            Exit = Resolve-BRAVOSyncBazaExitCode -SyncSucceeded $true -EmptySourceWarningCount 0
        }
    } $c1.App
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

    # F22 (QA-001). Junction, створений під час обходу знімка в уже
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

    # F24 (рев'ю PR #503). Корінь синхронізації чи його предок замінено на
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

    # F25 (рев'ю PR #503). Файл аудиту ДО, зниклий під час синхронізації без
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

    # F26 (рев'ю PR #503). Два файли чекали передачі: pending_1 передано, а
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

    # F27 (рев'ю PR #503, P1). Знімок циклу не вдався, бо pending_2 зник під
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

    # F28 (рев'ю PR #503, P1). Знімок циклу УСПІШНИЙ, але pending_2 зник між
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

    # F29 (рев'ю PR #503, P1). pending_2 замінено за тим самим шляхом ДО обходу
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
    # F30 (рев'ю PR #503, P1). pending_2 зник до знімка, WinSCP і пост-аудит його
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

    # F31 (рев'ю PR #503, P1). Знімок запитано, але не вдався; pending_2 зник ДО
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

    # F32 (рев'ю PR #503, P2). Доказ передачі об'єкта аудиту ДО — локальний stat,
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
    $late501ErrorAndWarning = & $late501Module {
        Get-BRAVOManualSyncRunOutcomeLabel -ManualSyncResult ([pscustomobject]@{ Success = $false; Skipped = $false; NewAfterCutoffCount = 3; Results = $null })
    }
    # -SyncBAZA не пише BRAVO_STATUS_Archive; його код 10 — канонічна severity WARNING.
    $late501Severity = Get-BRAVOExitCodeSeverity -Code $r2.ExitCode
    Test-BRAVOCondition -Condition (
        $late501HeaderComponent -eq 'BAZA_APP' -and
        $late501ZabbixValues['S01'] -eq 1 -and $late501ZabbixValues['S02'] -eq 2 -and
        $late501ZabbixValues['S04'] -eq 0 -and $late501ZabbixValues['S11'] -eq 2 -and
        ($r2.Label -notmatch '\s') -and $late501ErrorAndWarning -eq 'ПОМИЛКА' -and
        $r2.ExitCode -eq 10 -and [string]$late501Severity -eq 'WARNING' -and
        $archiveScriptText.Contains('Write-Log "Результат: $manualSyncOutcomeLabel" -NoTimestamp')
    ) -Name 'Archive/501/S16MonitoringParsingSeverityAndStatus' `
      -Failure "Zabbix: УСПІШНО->1, ПОПЕРЕДЖЕННЯ->2, ПОМИЛКА->0, одне слово; ERROR переважає WARNING; код 10 -> severity WARNING; значення: $($late501ZabbixValues | ConvertTo-Json -Compress) severity=$late501Severity"

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

# ============================================================
# 5.2.6 known issue: diskshadow читає сценарій як ANSI/OEM, тому
# сценарій і metadata-.cab мусять лежати в каталозі з ASCII-шляхом
# (ручний запуск з профілю з кириличним TEMP). Admin-free: diskshadow
# не запускається, перевіряється лише вибір каталогу і текст функції.
# ============================================================
$vssWorkDirModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText $archiveScriptText `
    -FunctionNames @('Get-BRAVOVSSDiskshadowWorkDirectory')
# ASCII-фікстури мусять мати ASCII-батьківський шлях: на установці з
# кириличним %TEMP% (саме цей сценарій виправляється) корінь у GetTempPath()
# зробив би не-ASCII і "ASCII"-кандидатів, і тест падав би при коректному
# хелпері. Як у ManualLaunchers: C:\Windows\Temp завжди ASCII.
$vssWorkDirTempBase = [IO.Path]::GetTempPath()
if ($vssWorkDirTempBase -cmatch '[^\x00-\x7F]') {
    $vssWorkDirTempBase = Join-Path $env:SystemRoot 'Temp'
}
$vssWorkDirRoot = Join-Path $vssWorkDirTempBase ('BRAVO_VSS_WORKDIR_SELF_TEST_{0}' -f [guid]::NewGuid().ToString('N'))
try {
    $vssAsciiTemp = Join-Path $vssWorkDirRoot 'AsciiTemp'
    $vssFakeSystemRoot = Join-Path $vssWorkDirRoot 'FakeWindows'
    $vssFakeSystemTemp = Join-Path $vssFakeSystemRoot 'Temp'
    $vssCyrillicTemp = Join-Path $vssWorkDirRoot ('Тест Кирилиця' + '\Temp')
    $vssCyrillicSystemRoot = Join-Path $vssWorkDirRoot 'Вінда'
    foreach ($vssDir in @($vssAsciiTemp, $vssFakeSystemTemp, $vssCyrillicTemp, (Join-Path $vssCyrillicSystemRoot 'Temp'))) {
        [void][IO.Directory]::CreateDirectory($vssDir)
    }

    $vssWorkDirProbe = & $vssWorkDirModule {
        param($AsciiTemp, $CyrillicTemp, $FakeSystemRoot, $CyrillicSystemRoot)
        [pscustomobject]@{
            AsciiUsed = Get-BRAVOVSSDiskshadowWorkDirectory -TempPath $AsciiTemp -SystemRootPath $FakeSystemRoot
            NonAscii = Get-BRAVOVSSDiskshadowWorkDirectory -TempPath $CyrillicTemp -SystemRootPath $FakeSystemRoot
            NoCandidate = Get-BRAVOVSSDiskshadowWorkDirectory -TempPath $CyrillicTemp -SystemRootPath $CyrillicSystemRoot
        }
    } $vssAsciiTemp $vssCyrillicTemp $vssFakeSystemRoot $vssCyrillicSystemRoot

    Test-BRAVOCondition -Condition (
        $vssWorkDirProbe.AsciiUsed -eq $vssAsciiTemp
    ) -Name 'Archive/VSSDiskshadowWorkDirAsciiTempUsedAsIs' `
      -Failure 'ASCII TEMP має використовуватися як є'
    Test-BRAVOCondition -Condition (
        $vssWorkDirProbe.NonAscii -eq $vssFakeSystemTemp -and
        $vssWorkDirProbe.NonAscii -cmatch '^[\x20-\x7E]+$'
    ) -Name 'Archive/VSSDiskshadowWorkDirNonAsciiTempFallsBack' `
      -Failure 'не-ASCII TEMP має замінюватися на ASCII-каталог SystemRoot\Temp і ніколи не повертатися'
    Test-BRAVOCondition -Condition (
        $null -eq $vssWorkDirProbe.NoCandidate
    ) -Name 'Archive/VSSDiskshadowWorkDirNoAsciiCandidateReturnsNull' `
      -Failure 'коли обидва кандидати не-ASCII, має повертатися $null (fail-closed, без live-fallback)'
} finally {
    Remove-Item -LiteralPath $vssWorkDirRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$vssDiskshadowFunctionText = [regex]::Match(
    $archiveScriptText,
    '(?s)function New-BRAVOVSSDiskshadowSnapshotSet \{.*?\r?\n\}\r?\n'
).Value
Test-BRAVOCondition -Condition (
    -not [string]::IsNullOrWhiteSpace($vssDiskshadowFunctionText) -and
    -not $vssDiskshadowFunctionText.Contains('GetTempPath') -and
    $vssDiskshadowFunctionText.Contains('Get-BRAVOVSSDiskshadowWorkDirectory') -and
    $vssDiskshadowFunctionText.Contains('WriteAllLines($scriptPath, $lines.ToArray(), [Text.Encoding]::ASCII)') -and
    $vssDiskshadowFunctionText.Contains('^[\x20-\x7E]*$')
) -Name 'Archive/VSSDiskshadowScriptIsAsciiInAsciiDirectory' `
  -Failure 'New-BRAVOVSSDiskshadowSnapshotSet має брати каталог з Get-BRAVOVSSDiskshadowWorkDirectory (без прямого GetTempPath), перевіряти ASCII-чистоту сценарію і писати його ASCII-кодуванням'
