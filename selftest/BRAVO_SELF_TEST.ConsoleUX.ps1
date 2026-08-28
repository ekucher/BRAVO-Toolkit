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

    # 22-23. Регресія для New-BRAVOSelfTestRuntimeModule: коли SourceText
    # містить ДВА визначення однієї функції (production-текст + навмисний
    # test-only silent-stub, доданий ПІСЛЯ — точний патерн DataRestore/
    # ManifestStorage negative-path battery), екстракція має брати ОСТАННЄ
    # визначення. Корінь оманливих КРИТИЧНО:/ПОМИЛКА:/УВАГА: у консолі
    # self-test-у: -First 1 мовчки повертав production-версію (перше
    # визначення), і призначений silent-stub ставав мертвим кодом —
    # реальний Write-DataRestoreLog/Write-BRAVOLog виконувався і друкував
    # справжній production-рендер під час свідомо симульованого negative-
    # path сценарію, хоча жодної реальної аварії сервера не було.
    $duplicateDefinitionSource = @'
function Test-BRAVOSelfTestDuplicateDefinition {
    Write-Host "REAL-NOISE-MARKER-НЕ-МАЄ-ПОТРАПИТИ-У-КОНСОЛЬ"
    Write-Warning "REAL-WARNING-MARKER-НЕ-МАЄ-ПОТРАПИТИ-У-КОНСОЛЬ"
}
'@
    $duplicateDefinitionStub = @'
function Test-BRAVOSelfTestDuplicateDefinition {
    # навмисно тихий test-only override
}
'@
    # Без прапорця -PreferLastDefinitionOnDuplicate поведінка НЕ змінилась
    # (перше визначення перемагає) — саме на цьому й досі спираються
    # ServiceQuiescence та ще 50+ інших виклик-площин (заглушка ПЕРШОЮ,
    # реальний модульний текст ДРУГИМ). Регресія цього дефолту зламала б
    # їх мовчки під час первинної спроби виправлення (виявлено повним
    # прогоном self-test — ServiceQuiescence/ClearAndSuppressNeverTouch-
    # ForeignMarker і сусідній тест впали, коли дефолт тимчасово змінили
    # на -Last без опт-ін прапорця).
    $duplicateDefinitionModuleDefault = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($duplicateDefinitionSource + [Environment]::NewLine + $duplicateDefinitionStub) `
        -FunctionNames @('Test-BRAVOSelfTestDuplicateDefinition')
    $duplicateDefinitionDefaultOutput = & $duplicateDefinitionModuleDefault { Test-BRAVOSelfTestDuplicateDefinition } 6>&1 3>&1 | Out-String

    $duplicateDefinitionModuleLast = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($duplicateDefinitionSource + [Environment]::NewLine + $duplicateDefinitionStub) `
        -FunctionNames @('Test-BRAVOSelfTestDuplicateDefinition') `
        -PreferLastDefinitionOnDuplicate
    $duplicateDefinitionLastOutput = & $duplicateDefinitionModuleLast { Test-BRAVOSelfTestDuplicateDefinition } 6>&1 3>&1 | Out-String

    Test-BRAVOCondition `
        -Condition (
            $duplicateDefinitionDefaultOutput.Contains('REAL-NOISE-MARKER') -and
            $duplicateDefinitionDefaultOutput.Contains('REAL-WARNING-MARKER')
        ) `
        -Name "ConsoleUX/22-RuntimeModuleExtractionDefaultStillPrefersFirstDefinition" `
        -Failure "без -PreferLastDefinitionOnDuplicate New-BRAVOSelfTestRuntimeModule має й далі брати ПЕРШЕ визначення (історична поведінка, на якій тримається ServiceQuiescence та інші виклик-площини із заглушкою-першою)"
    Test-BRAVOCondition `
        -Condition (
            -not $duplicateDefinitionLastOutput.Contains('REAL-NOISE-MARKER') -and
            -not $duplicateDefinitionLastOutput.Contains('REAL-WARNING-MARKER')
        ) `
        -Name "ConsoleUX/23-RuntimeModulePreferLastDefinitionSwitchSuppressesEarlierWriteHostAndWarning" `
        -Failure "з -PreferLastDefinitionOnDuplicate New-BRAVOSelfTestRuntimeModule має брати ОСТАННЄ визначення (test-only silent-stub після production-тексту — конвенція DataRestore/ManifestStorage), інакше очікувані negative-path сценарії друкують справжній Write-Host/Write-Warning у консоль self-test-у"

    # 24. Структурний якір: ManifestStorage retention/orphan-sweep
    # battery (реальні Remove-BRAVOExpiredBackupGenerations/Remove-
    # BRAVOOrphanedTemporaryArchiveArtifacts, WARNING/ERROR-гілки
    # Archive.Runtime.ps1) має власний silent-stub для Write-BRAVOLog —
    # без нього реальний production Write-BRAVOLog (BRAVO.Logging уже
    # імпортовано self-test-прогоном раніше) друкує ПОМИЛКА:/КРИТИЧНО:/
    # УВАГА: у консоль під час навмисно очікуваного negative-path сценарію.
    $manifestStorageScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "selftest\BRAVO_SELF_TEST.ManifestStorage.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $manifestStorageScriptText.Contains("function Write-BRAVOLog {") -and
            $manifestStorageScriptText -match "retentionCleanupModule[\s\S]*?'Write-BRAVOLog'[\s\S]*?-PreferLastDefinitionOnDuplicate" -and
            $manifestStorageScriptText -match "orphanSweepModule[\s\S]*?'Write-BRAVOLog'\)[\s\S]*?-PreferLastDefinitionOnDuplicate"
        ) `
        -Name "ConsoleUX/24-ManifestStorageRetentionOrphanSweepSilenceWriteBRAVOLog" `
        -Failure "retentionCleanupModule і orphanSweepModule мають включати silent-stub Write-BRAVOLog у FunctionNames ТА -PreferLastDefinitionOnDuplicate, інакше production-визначення Write-BRAVOLog (перше в SourceText) переможе, і реальні WARNING/ERROR негативні сценарії друкують production-лог у консоль self-test-у"

    # 25-30. SELF-TEST Operator UX: завершальний operator summary +
    # manual-exit pause самого BRAVO_SELF_TEST.ps1. Структурні перевірки на
    # власному тексті кореневого скрипта (той самий підхід, що й ConsoleUX/
    # 21 вище: exitOrderFailures) — реальний живий прогін цих сценаріїв
    # неможливий зсередини self-test-у, який сам виконується прямо зараз.
    $selfTestScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_SELF_TEST.ps1"),
        [Text.Encoding]::UTF8
    )

    # 25. Operator summary рендериться ЧЕРЕЗ ті самі канонічні BRAVO.Console
    # примітиви, що Archive/Health/Maintenance (Write-BRAVOFinalSummaryHeader/
    # Footer, Write-BRAVOResultField) — не окрема паралельна box-drawing
    # реалізація. Machine-readable маркери "SELF-TEST PASSED"/"SELF-TEST
    # FAILED:" лишаються дослівними (CI/RELEASE_CHECKLIST.md залежать від
    # точного тексту) — операторський підсумок додається НАД ними, не
    # замінює їх.
    Test-BRAVOCondition `
        -Condition (
            $selfTestScriptText.Contains("Write-BRAVOFinalSummaryHeader -Title 'BRAVO SELF-TEST'") -and
            $selfTestScriptText.Contains('Write-BRAVOFinalSummaryFooter -LogFile $script:selfTestHelperLogPath') -and
            $selfTestScriptText.Contains('Write-Host "SELF-TEST PASSED" -ForegroundColor Green') -and
            $selfTestScriptText -match 'Write-Host\s+"SELF-TEST FAILED:\s+\$\(\$script:failures\.Count\)"'
        ) `
        -Name "ConsoleUX/25-SelfTestOperatorSummaryUsesCanonicalConsolePrimitives" `
        -Failure "BRAVO_SELF_TEST.ps1 має рендерити фінальний operator summary через канонічні Write-BRAVOFinalSummaryHeader/Footer (BRAVO.Console) і зберігати дослівні machine-readable маркери SELF-TEST PASSED/FAILED"

    # 26. PASS-лічильник у підсумку — динамічний ($script:passCount), не
    # hardcoded число. Test-BRAVOCondition інкрементує його при кожному
    # успіху (єдина точка обліку, той самий $script:failures, що вже
    # рахує FAIL).
    Test-BRAVOCondition `
        -Condition (
            $selfTestScriptText.Contains("`$script:passCount++") -and
            $selfTestScriptText.Contains("-Value ([string]`$script:passCount)") -and
            -not [regex]::IsMatch($selfTestScriptText, "-Label 'Перевірки' -Value '1420'")
        ) `
        -Name "ConsoleUX/26-SelfTestSummaryUsesDynamicPassCount" `
        -Failure "Перевірки: у operator summary мають братися з динамічного `$script:passCount (інкрементується в Test-BRAVOCondition), а не з hardcoded числа"

    # 27. Один resolved exit code — обчислюється РІВНО один раз
    # ($script:selfTestExitCode) і використовується і для поля 'Код
    # завершення', і для Complete-BRAVOHelperLog -ExitCode; жодного
    # повторного обчислення після паузи (P16).
    $selfTestExitCodeAssignments = @([regex]::Matches(
        $selfTestScriptText, '\$script:selfTestExitCode\s*='
    ))
    Test-BRAVOCondition `
        -Condition (
            $selfTestExitCodeAssignments.Count -eq 1 -and
            $selfTestScriptText.Contains("-Label 'Код завершення' -Value ([string]`$script:selfTestExitCode)") -and
            $selfTestScriptText.Contains('Complete-BRAVOHelperLog -ExitCode $script:selfTestExitCode')
        ) `
        -Name "ConsoleUX/27-SelfTestResolvedExitCodeSingleSource" `
        -Failure "`$script:selfTestExitCode має обчислюватись рівно один раз і використовуватись і operator summary, і фактичним Complete-BRAVOHelperLog — знайдено присвоєнь: $($selfTestExitCodeAssignments.Count)"

    # 28. Один виклик Wait-BRAVOManualExit у самому BRAVO_SELF_TEST.ps1 —
    # жодної другої паузи (P18), і сам виклик прокидає параметр -NoPause
    # скрипта (forwarding, не hardcoded true/false). AST CommandAst, а не
    # текстовий пошук: BRAVO_SELF_TEST.ps1 містить десятки СТРОКОВИХ
    # ЛІТЕРАЛІВ з тим самим текстом "Wait-BRAVOManualExit -NoPause:$NoPause"
    # усередині ІНШИХ структурних перевірок (Archive/Health/Maintenance
    # ManualModeAndPauseUseSameNoPauseContract тощо) — .Contains()/regex
    # порахував би їх теж і дав хибно завищений count.
    $selfTestAst = [Management.Automation.Language.Parser]::ParseInput($selfTestScriptText, [ref]$null, [ref]$null)
    $selfTestManualExitCalls = @(
        $selfTestAst.FindAll(
            {
                param($candidate)
                $candidate -is [Management.Automation.Language.CommandAst] -and
                $candidate.GetCommandName() -eq 'Wait-BRAVOManualExit'
            },
            $true
        ) | Where-Object { $_.Extent.Text -eq 'Wait-BRAVOManualExit -NoPause:$NoPause' }
    )
    Test-BRAVOCondition `
        -Condition (
            $selfTestManualExitCalls.Count -eq 1 -and
            $selfTestScriptText -match '(?m)^\s*\[switch\]\$NoPause\s*$'
        ) `
        -Name "ConsoleUX/28-SelfTestSinglePauseForwardsNoPauseParameter" `
        -Failure "BRAVO_SELF_TEST.ps1 має приймати [switch]`$NoPause у param() і РЕАЛЬНО (не в текстовому літералі іншої перевірки) викликати Wait-BRAVOManualExit -NoPause:`$NoPause рівно один раз; знайдено викликів: $($selfTestManualExitCalls.Count)"

    # 29. Operator summary (включно з маркером SELF-TEST PASSED/FAILED і
    # Complete-BRAVOHelperLog) друкується ДО паузи (P17) — Complete-
    # BRAVOHelperLog викликається всередині try, Wait-BRAVOManualExit — у
    # відповідному finally; exit усередині Complete-BRAVOHelperLog
    # проходить крізь finally ПЕРЕД реальним завершенням процесу (той
    # самий емпірично підтверджений принцип, що Maintenance.Runtime.ps1
    # використовує навколо свого exit) — тому пауза не може змінити вже
    # викликаний exit-код.
    $selfTestCompleteHelperLogIndex = $selfTestScriptText.IndexOf('Complete-BRAVOHelperLog -ExitCode $script:selfTestExitCode')
    $selfTestManualExitIndex = $selfTestScriptText.LastIndexOf('Wait-BRAVOManualExit -NoPause:$NoPause')
    Test-BRAVOCondition `
        -Condition (
            $selfTestCompleteHelperLogIndex -ge 0 -and
            $selfTestManualExitIndex -gt $selfTestCompleteHelperLogIndex -and
            [regex]::IsMatch(
                $selfTestScriptText,
                '(?s)try\s*\{\s*Complete-BRAVOHelperLog -ExitCode \$script:selfTestExitCode\s*\}\s*finally\s*\{\s*Wait-BRAVOManualExit -NoPause:\$NoPause\s*\}'
            )
        ) `
        -Name "ConsoleUX/29-SelfTestSummaryBeforePauseOrdering" `
        -Failure "Complete-BRAVOHelperLog (яка друкує SELF-TEST PASSED/FAILED-контекст і власний Код завершення/Лог) має бути всередині try, а Wait-BRAVOManualExit -NoPause:`$NoPause — у парному finally, у цьому порядку"

    # 30. -NoPause лишається авторитетним і повертається миттєво навіть
    # після operator summary — той самий генеричний Wait-BRAVOManualExit
    # (BRAVO.Console), жодної окремої paralel-реалізації для self-test.
    $selfTestNoPauseElapsed = Measure-Command { Wait-BRAVOManualExit -NoPause }
    Test-BRAVOCondition `
        -Condition ($selfTestNoPauseElapsed.TotalSeconds -lt 2) `
        -Name "ConsoleUX/30-SelfTestNoPauseStillReturnsImmediately" `
        -Failure "Wait-BRAVOManualExit -NoPause (та сама функція, яку BRAVO_SELF_TEST.ps1 викликає наприкінці) має повертатися миттєво; зайняло $($selfTestNoPauseElapsed.TotalSeconds) с"
