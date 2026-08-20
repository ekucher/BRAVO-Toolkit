# Домен-фрагмент self-test: ConsoleUX (уніфікований Operator Console UX,
# BRAVO.md §20). Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 -- НЕ
# запускається напряму. Успадковує з викликача: $root, Test-BRAVOCondition,
# New-BRAVOSelfTestRuntimeModule, $script:failures.
#
# ПРИХОВАНІ ЗАЛЕЖНОСТІ (виявлені при розбитті, 2026-08-18): оригінальний блок
# повторно використовував 8 source-text змінних, вперше прочитаних набагато
# раніше в монолітному файлі (рядки 2021-10123), не всередині самого
# ConsoleUX-блоку. Той самий підхід, що й для ManifestStorage: локальні
# read-only перечитування нижче (той самий вміст файлу, immutable протягом
# self-test-прогону).
$archiveScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"),
    [Text.Encoding]::UTF8
)
$compatibilityScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psm1"),
    [Text.Encoding]::UTF8
)
$dryRunScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "BRAVO_DRY_RUN.ps1"),
    [Text.Encoding]::UTF8
)
$healthRuntimeText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
    [Text.Encoding]::UTF8
)
$maintenanceScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
    [Text.Encoding]::UTF8
)
$restoreTestScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "BRAVO_RESTORE_TEST.ps1"),
    [Text.Encoding]::UTF8
)
$setupScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "BRAVO_SETUP.ps1"),
    [Text.Encoding]::UTF8
)
$taskInstallerText = [IO.File]::ReadAllText(
    (Join-Path $root "BRAVO_TASKS_INSTALL.ps1"),
    [Text.Encoding]::UTF8
)


    # ===== ОПЕРАЦІЙНА КОНСОЛЬ: 21 сценарій (Завдання_ реалізувати
    # уніфікований Operator Console UX для BRAVO.md, §20) =====
    $credentialsSetupScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_CREDENTIALS_SETUP.ps1"),
        [Text.Encoding]::UTF8
    )
    $consoleModuleText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Console\BRAVO.Console.psm1"),
        [Text.Encoding]::UTF8
    )

    # 1. Ручний успішний прогін Archive: гілка 'УСПІШНО' існує саме тоді,
    # коли operationFailed=$false (жодна з ~26 умов відмови не спрацювала).
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('if ($operationFailed) {') -and
            $archiveScriptText -match "\}\s*else\s*\{\s*'УСПІШНО'\s*\}"
        ) `
        -Name "ConsoleUX/01-ArchiveManualSuccess" `
        -Failure "Archive має показувати Статус=УСПІШНО, коли жоден компонент не відмовив"

    # 2. Частковий збій Archive: 'ЧАСТКОВО', коли є і успішні, і невдалі
    # компоненти — на відміну від 'ПОМИЛКА', коли не вдалося жодного.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("if (`$successCount -gt 0) { 'ЧАСТКОВО' } else { 'ПОМИЛКА' }")
        ) `
        -Name "ConsoleUX/02-ArchivePartialFailure" `
        -Failure "Archive має розрізняти 'ЧАСТКОВО' (частина компонентів вдалась) від 'ПОМИЛКА' (жодного)"

    # 3. SFTP-збій ПІСЛЯ успішних локальних архівів — окрема Причина, а не
    # загальне "не вдалося створити архів", коли локальні компоненти вже ОК.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('"Не вдалося передати архіви на SFTP"') -and
            $archiveScriptText.Contains('elseif ([bool]$sftpStepFailed)') -and
            $archiveScriptText.Contains("@('ArchiveUpload', 'BAZA_APP', 'BAZA_WWW')")
        ) `
        -Name "ConsoleUX/03-SftpFailureAfterLocalSuccess" `
        -Failure "SFTP-збій після вдалих локальних архівів має власну Причину, не спільну з локальним провалом"

    # 4. Трансляція нативного коду завершення 7-Zip у Причину/Інструмент/
    # Код інструменту через централізовану Get-BRAVOToolExitCodeDescription.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Get-BRAVOToolExitCodeDescription -Tool '7-Zip'")
        ) `
        -Name "ConsoleUX/04-SevenZipExitCodeTranslation" `
        -Failure "New-Archive має транслювати нативний код 7-Zip через Get-BRAVOToolExitCodeDescription"

    # 5. Невідомий нативний код інструменту не падає й не губиться —
    # "UNKNOWN(N)" замість винятку чи мовчазного null.
    Test-BRAVOCondition `
        -Condition (
            $compatibilityScriptText.Contains('"UNKNOWN($code)"')
        ) `
        -Name "ConsoleUX/05-UnknownToolExitCode" `
        -Failure "Get-BRAVOToolExitCodeDescription має мати fallback UNKNOWN(N) для нерозпізнаного коду"

    # 6. WARNING: аномалія розміру архіву показується як Причина під
    # рядком етапу, а не мовчки ігнорується чи змінює Статус на ERROR.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('Write-BRAVOOperatorReason -Reason $sizeAnomalyResult.Reason')
        ) `
        -Name "ConsoleUX/06-WarningReasonDisplayed" `
        -Failure "Аномалія розміру архіву має показувати Причину через Write-BRAVOOperatorReason (WARNING)"

    # 7. SKIPPED: пропущений крок показує пояснення без підпису "Причина:",
    # а не просто мовчазний пропуск нумерації. dev.14 (round 3): той самий
    # централізований plain-рендерер (Write-BRAVOConsoleDetail), що й
    # OK/WARN/FAIL — не окрема гілка Write-BRAVOSkipReason.
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptText.Contains('foreach ($detailLine in ($Details -split "`r?`n")) {') -and
            $maintenanceScriptText.Contains('Write-BRAVOConsoleDetail -Message $detailLine')
        ) `
        -Name "ConsoleUX/07-SkippedReasonDisplayed" `
        -Failure "SKIPPED-крок Maintenance має пояснення через Write-BRAVOSkipReason"

    # 8. .mdz — єдине зовнішньо видиме розширення артефакту: жоден
    # мігрований runtime не показує оператору буквальний ".7z".
    $mdzOnlyScripts = @(
        @{ Text = $archiveScriptText; Name = "Archive" },
        @{ Text = $healthRuntimeText; Name = "Health" },
        @{ Text = $restoreTestScriptText; Name = "RestoreTest" }
    )
    $scriptsWithVisible7z = @(
        $mdzOnlyScripts | Where-Object {
            $_.Text -match "['""]\.7z['""]" -or $_.Text -match "Write-Host[^\n]*\.7z"
        } | ForEach-Object { $_.Name }
    )
    Test-BRAVOCondition `
        -Condition ($scriptsWithVisible7z.Count -eq 0) `
        -Name "ConsoleUX/08-MdzOnlyArtifactExtension" `
        -Failure "Оператор не повинен бачити '.7z' як ім'я артефакту; знайдено в: $($scriptsWithVisible7z -join ', ')"

    # 9. Кількість артефактів X з Y у фінальному РЕЗУЛЬТАТ.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Write-BRAVOResultField -Label 'Створено архівів' -Value (`"{0} з {1}`" -f `$successCount, `$totalCount)")
        ) `
        -Name "ConsoleUX/09-ArtifactCountXofY" `
        -Failure "РЕЗУЛЬТАТ Archive має показувати 'Створено архівів: X з Y'"

    # 10. Загальний розмір створених архівів у фінальному РЕЗУЛЬТАТ.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Write-BRAVOResultField -Label 'Загальний розмір' -Value (Format-BRAVOFileSize -Bytes `$totalCreatedBytes)")
        ) `
        -Name "ConsoleUX/10-TotalSizeField" `
        -Failure "РЕЗУЛЬТАТ Archive має показувати 'Загальний розмір'"

    # 11. SHA512/Integrity ніколи не "OK" без реальної перевірки: обидва
    # рядки друкуються ЛИШЕ після публікації component backup. Публікація
    # відбувається тільки коли create, 7z t і SHA512 verification успішні.
    $archiveComponentBlockMatch = [regex]::Match(
        $archiveScriptText,
        '(?s)if \(\$componentPublished\) \{.*?SHA512:.*?Integrity:.*?\} else \{'
    )
    Test-BRAVOCondition `
        -Condition ($archiveComponentBlockMatch.Success) `
        -Name "ConsoleUX/11-Sha512IntegrityNeverFakedOk" `
        -Failure "SHA512/Integrity мають друкуватись лише після успішної публікації component backup, інакше це вигаданий OK"

    # 12/13/14. Ручна пауза / -NoPause / перенаправлений неінтерактивний
    # запуск — усі три керуються спільним Wait-BRAVOManualExit, а не
    # окремою логікою в кожному entrypoint.
    $waitManualExitFunctionMatch = [regex]::Match(
        $consoleModuleText,
        '(?s)function Wait-BRAVOManualExit \{.*?\n\}'
    )
    $waitManualExitText = if ($waitManualExitFunctionMatch.Success) { $waitManualExitFunctionMatch.Value } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $waitManualExitText.Contains('if ($NoPause) {') -and
            $waitManualExitText.Contains('return')
        ) `
        -Name "ConsoleUX/12-NoPauseSkipsWait" `
        -Failure "Wait-BRAVOManualExit має негайно повертатись при -NoPause"
    # dev.18: реальний DEV-LIMS ручний (MANUAL) запуск довів, що
    # [Console]::IsInputRedirected сам по собі помилково відхиляв
    # справжню операторську консоль ДО спроби RawUI.ReadKey — вікно
    # закривалось одразу після РЕЗУЛЬТАТ замість очікування. Тепер
    # [Environment]::UserInteractive лишається єдиною такою pre-check
    # причиною пропустити паузу; IsInputRedirected більше не окрема
    # самостійна умова (перевіряється explicit-negative тестом нижче).
    Test-BRAVOCondition `
        -Condition (
            $waitManualExitText.Contains('[Environment]::UserInteractive')
        ) `
        -Name "ConsoleUX/13-NonInteractiveSessionSkipsWait" `
        -Failure "Wait-BRAVOManualExit має пропускати очікування, коли [Environment]::UserInteractive=false (SYSTEM-сесія)"
    Test-BRAVOCondition `
        -Condition (
            $waitManualExitText.Contains('$Host.UI.RawUI.ReadKey(') -and
            $waitManualExitText.Contains('Натиснiть будь-яку клавiшу для закриття вiкна...')
        ) `
        -Name "ConsoleUX/14-ManualPauseWaitsForKey" `
        -Failure "Wait-BRAVOManualExit має справді чекати на клавішу в інтерактивному режимі без -NoPause"

    # 15. Health: фінальний підсумок включає Перевірок/Успішно/Попереджень/
    # Помилок — не лише голий Статус.
    Test-BRAVOCondition `
        -Condition (
            $healthRuntimeText.Contains("Write-BRAVOResultField -Label 'Перевірок'") -and
            $healthRuntimeText.Contains("Write-BRAVOResultField -Label 'Успішно'") -and
            $healthRuntimeText.Contains("Write-BRAVOResultField -Label 'Попереджень'") -and
            $healthRuntimeText.Contains("Write-BRAVOResultField -Label 'Помилок'")
        ) `
        -Name "ConsoleUX/15-HealthSummaryCounters" `
        -Failure "Health РЕЗУЛЬТАТ має показувати Перевірок/Успішно/Попереджень/Помилок"

    # 16. Restore Test: PASS/WARN/FAIL — усі три статуси в одному ValidateSet
    # (WARN, а не WARNING — власна термінологія drill-скрипта, docs §4).
    Test-BRAVOCondition `
        -Condition (
            $restoreTestScriptText.Contains("[ValidateSet('PASS', 'WARN', 'FAIL')]")
        ) `
        -Name "ConsoleUX/16-RestoreTestPassWarnFail" `
        -Failure "Restore Test має підтримувати рівно PASS/WARN/FAIL у власному словнику статусів"

    # 17. Dry Run: PASS/WARN/FAIL/PLAN — усі чотири власні статуси мають
    # кольорове відображення (docs §6: "не потрібно насильно переводити
    # в Archive-style OK/ERROR").
    $dryRunStatusColorsMatch = [regex]::Match(
        $dryRunScriptText,
        '(?s)\$dryRunStatusColors = @\{.*?\}'
    )
    $dryRunStatusColorsText = if ($dryRunStatusColorsMatch.Success) { $dryRunStatusColorsMatch.Value } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $dryRunStatusColorsText.Contains('PASS') -and
            $dryRunStatusColorsText.Contains('WARN') -and
            $dryRunStatusColorsText.Contains('FAIL') -and
            $dryRunStatusColorsText.Contains('PLAN')
        ) `
        -Name "ConsoleUX/17-DryRunFourStatuses" `
        -Failure "Dry Run має власні кольори для всіх чотирьох статусів PASS/WARN/FAIL/PLAN"

    # 18. Setup: DISCOVERY-блок виводить реальні джерела (не заглушку) —
    # BRAVO_ROOT/MODEL/BLOG/BRAVOEXCH/BAZA_APP/WEB_ROOT/BAZA_WWW.
    Test-BRAVOCondition `
        -Condition (
            $setupScriptText.Contains("Write-BRAVOResultField -Label 'BRAVO_ROOT'") -and
            $setupScriptText.Contains("Write-BRAVOResultField -Label 'MODEL'") -and
            $setupScriptText.Contains("Write-BRAVOResultField -Label 'BAZA_WWW'")
        ) `
        -Name "ConsoleUX/18-SetupDiscoveryOutput" `
        -Failure "Setup має показувати реальний DISCOVERY-блок (BRAVO_ROOT/MODEL/BAZA_WWW тощо)"

    # 19. Credentials Setup ніколи не показує значення секрету: фінальний
    # рендер оперує лише Target (назва запису)/Status/Scope/Component —
    # жодного посилання на Password/Secret/SecureSecret/.Value.
    $credentialResultBlockMatch = [regex]::Match(
        $credentialsSetupScriptText,
        '(?s)function Write-BRAVOCredentialResultBlock \{.*?\n\}'
    )
    $credentialResultBlockText = if ($credentialResultBlockMatch.Success) { $credentialResultBlockMatch.Value } else { '' }
    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($credentialResultBlockText) -and
            $credentialResultBlockText.Contains('$result.Target') -and
            $credentialResultBlockText -notmatch 'Password|SecureSecret|\.Value\b|\$result\.Secret'
        ) `
        -Name "ConsoleUX/19-CredentialsNoSecretLeak" `
        -Failure "Write-BRAVOCredentialResultBlock не повинен звертатись до значення секрету — лише Target/Status/Scope"

    # 20. Tasks Install: підсумок по кожному завданню ("Завдання:") і
    # фінальні лічильники Встановлено/Оновлено/Заплановано.
    Test-BRAVOCondition `
        -Condition (
            $taskInstallerText.Contains("Write-Host 'Завдання:'") -and
            $taskInstallerText.Contains("Write-BRAVOResultField -Label 'Встановлено'") -and
            $taskInstallerText.Contains("Write-BRAVOResultField -Label 'Заплановано'")
        ) `
        -Name "ConsoleUX/20-TasksInstallSummary" `
        -Failure "Tasks Install має показувати 'Завдання:' і підсумкові лічильники в РЕЗУЛЬТАТ"

    # 21. Код завершення процесу не залежить від рендеру консолі: в
    # Archive/Health/Maintenance числовий код обчислюється РАНІШЕ виклику
    # Write-BRAVOResultHeader і зберігається в змінній, яку читає
    # підсумковий exit — не перераховується вдруге після друку.
    $exitBeforeRenderChecks = @(
        @{
            Name = "Archive"
            Text = $archiveScriptText
            ExitVar = '$script:processExitCode ='
        },
        @{
            Name = "Health"
            Text = $healthRuntimeText
            ExitVar = '$healthExitCode = switch'
        },
        @{
            Name = "Maintenance"
            Text = $maintenanceScriptText
            # dev.19 (виправлено): inline if/elseif/else замінено викликом
            # Get-BRAVOMaintenanceResolvedExitCode (та сама формула,
            # піднята ще вище — тепер ДО ЛОГ "=== СТАТУС ===", не лише ДО
            # РЕЗУЛЬТАТ).
            ExitVar = '$script:maintenanceRuntimeExitCode = Get-BRAVOMaintenanceResolvedExitCode'
        }
    )
    $exitOrderFailures = @(
        $exitBeforeRenderChecks | Where-Object {
            $exitVarIndex = $_.Text.IndexOf($_.ExitVar)
            $renderIndex = $_.Text.IndexOf('Write-BRAVOResultHeader')
            $exitVarIndex -lt 0 -or $renderIndex -lt 0 -or $exitVarIndex -gt $renderIndex
        } | ForEach-Object { $_.Name }
    )
    Test-BRAVOCondition `
        -Condition ($exitOrderFailures.Count -eq 0) `
        -Name "ConsoleUX/21-ExitCodeComputedBeforeRender" `
        -Failure "Код завершення має обчислюватись ДО Write-BRAVOResultHeader, інакше підсумок бреше; порушено в: $($exitOrderFailures -join ', ')"
