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
    $archiveScriptText -match '(?s)option batch continue\r?\noption confirm off\r?\nopen \$RepositorySFTPUrl -hostkey=\$HostKey.*?\$mkdirCommands'
) -Name 'Archive/SftpMkdirBatchContinuesPastIntermediateFailure' `
    -Failure "'option batch continue' має передувати mkdir-командам, щоб провал одного сегмента (уже наявний/проміжний) не зупиняв решту пакета"

Test-BRAVOCondition -Condition (
    $archiveScriptText -match '-hostkey=\$HostKey' -and
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
}
'@
$archiveOwnLogFunctionNames = @("Write-BRAVOLog", "Initialize-BRAVOSFTPRemoteDirectories", "Send-FileViaWinSCP", "Invoke-BRAVOArchiveOwnLogUpload")
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
        [string]$LogFilePath
    )
    & $Module {
        param($enabled, $sftpEnabled, $defineConfig, $sendShouldThrow, $sendReturnValue, $logFilePath)
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
            $script:sftpHostKey = 'ssh-rsa 2048 aa:bb:cc'
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
    } $Enabled $SftpEnabled $DefineConfig $SendShouldThrow $SendReturnValue $LogFilePath
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
    ([Text.RegularExpressions.Regex]::Matches($archiveScriptText, 'Send-BRAVOOperationsEvent\s+`')).Count -ge 1 -and
    $archiveFinalOpsEventBody -match 'Send-BRAVOOperationsEvent'
) -Name 'Archive/FinalOperationsEventOwnsTheGenerationEmission' `
    -Failure "сама відправка зведеної generation-події мусить жити всередині Send-BRAVOArchiveFinalOperationsEvent, а не дублюватись у хвості Main -- інакше дві копії політики severity/Details розійдуться"

# Функціональна ізоляція тієї самої функції: реальний її текст + стаби
# Send-BRAVOOperationsEvent/Write-Log (New-BRAVOSelfTestRuntimeModule тут не
# підходить -- функція читає $script:-стан, який тест мусить виставляти
# всередині того самого module scope, тому модуль складається напряму з
# тексту функції плюс стаби). Перевіряється саме те, що структурний тест
# перевірити не може: який severity і які Details виходять для кожного
# класу завершення прогону.
$archiveFinalOpsStub = @'
function Send-BRAVOOperationsEvent {
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
    return @($global:BRAVOArchiveSelfTestFinalOpsEvents.ToArray())
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
function Send-BRAVOOperationsEvent {
    param($OperationsReportingSettings, $CredentialTargets, $InstitutionCode, $Category, $Severity, $Component, $Message, $Services, $Details)
    $script:archiveGatingTestState.OperationsEventCalls++
    $script:archiveGatingTestState.LastMessage = $Message
    $script:archiveGatingTestState.LastSeverity = $Severity
}
'@
$archiveGatingFunctionNames = @(
    'Write-BRAVOLog', 'Protect-BRAVOLogSecret', 'Get-HostInformation', 'Format-BRAVOUkrainianCount',
    'New-BRAVOOperatorNotificationMessage', 'Resolve-BRAVONotificationRoute', 'Resolve-BRAVONotificationEndpoint',
    'ConvertTo-BRAVONotificationPayloadText', 'Send-BRAVONotificationChunks', 'Send-BRAVOOperationsEvent',
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
