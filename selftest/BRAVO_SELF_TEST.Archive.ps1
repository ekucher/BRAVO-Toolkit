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
function Send-BRAVOOperationsEvent {
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
            $result = @(Test-SFTPConnection -WinSCPPath $StubPath -RepositorySFTPUrl 'sftp://selftest@127.0.0.1/' -HostKey 'ssh-rsa 2048 aa:bb:cc')
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
# #290 (Codex P1): BRAVO_WINSCP lock звільняється лише після підтвердженого
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
