# Suite InstallerUI: view-model, побудова команд engine, розмір вікна й
# структура головної форми (без ShowDialog). Фрагмент dot-source-иться
# кореневим BRAVO_SELF_TEST.ps1; $root — корінь комплекту.

& {
    Import-Module (Join-Path $root 'modules\BRAVO.Installer.UI\BRAVO.Installer.UI.psd1') -Force -DisableNameChecking

    $mod = Get-Module BRAVO.Installer.UI
    $exported = @($mod.ExportedFunctions.Keys)
    Test-BRAVOCondition -Condition ($exported -contains 'Show-BRAVOInstallerMainForm' -and $exported -notcontains 'Get-BRAVOInstallerProperty') `
        -Name 'InstallerUI/Exports' -Failure 'Публічний API модуля не відповідає очікуваному (private helper експортовано або немає Show-).'

    # --- Home view-model: кожен стан ---
    $expectations = @(
        @{ State = 'NotInstalled';        Key = 'Install';      Label = 'Встановити';                   Enabled = $true  },
        @{ State = 'Installed';           Key = 'CheckUpdates'; Label = 'Перевірити оновлення';         Enabled = $true  },
        @{ State = 'PrereleaseInstalled'; Key = 'CheckUpdates'; Label = 'Перевірити оновлення';         Enabled = $true  },
        @{ State = 'UpdateAvailable';     Key = 'CheckUpdates'; Label = 'Перевірити оновлення';         Enabled = $true  },
        @{ State = 'Degraded';            Key = 'ViewProblems'; Label = 'Переглянути проблеми';         Enabled = $true  },
        @{ State = 'RepairRequired';      Key = 'Repair';       Label = 'Відновити компоненти';         Enabled = $true  },
        @{ State = 'InterruptedUpdate';   Key = 'Recover';      Label = 'Відновити після переривання';  Enabled = $true  },
        @{ State = 'RollbackRequired';    Key = 'Rollback';     Label = 'Завершити відкат';             Enabled = $true  },
        @{ State = 'Ambiguous';           Key = 'SelectRoot';   Label = 'Оберіть каталог встановлення'; Enabled = $true  },
        @{ State = 'Unsupported';         Key = 'Diagnostics';  Label = 'Показати причину';             Enabled = $true  }
    )
    foreach ($case in $expectations) {
        $state = [pscustomobject]@{
            state = $case.State; runtimeRoot = 'C:\Тест Каталог\BRAVO'
            candidateRoots = @('C:\a b\BRAVO', 'D:\Інший\BRAVO')
            version = [pscustomobject]@{ packageVersion = '5.3.0'; releaseChannel = 'stable' }
            integrity = [pscustomobject]@{ status = 'Valid' }
        }
        $vm = ConvertTo-BRAVOInstallerHomeViewModel -State $state
        Test-BRAVOCondition -Condition ($vm.PrimaryAction.Key -eq $case.Key -and $vm.PrimaryAction.Label -eq $case.Label -and $vm.PrimaryAction.Enabled -eq $case.Enabled) `
            -Name "InstallerUI/Home/$($case.State)" -Failure "Primary action для $($case.State): $($vm.PrimaryAction.Key)/$($vm.PrimaryAction.Label)/$($vm.PrimaryAction.Enabled)"
        Test-BRAVOCondition -Condition (-not [string]::IsNullOrWhiteSpace($vm.StatusMarker) -and -not [string]::IsNullOrWhiteSpace($vm.StatusText)) `
            -Name "InstallerUI/Home/$($case.State)/MarkerAndText" -Failure 'Статус має бути текст + маркер.'
        if (-not $vm.PrimaryAction.Enabled -and $vm.PrimaryAction.Key -ne 'SelectRoot') {
            Test-BRAVOCondition -Condition (-not [string]::IsNullOrWhiteSpace($vm.PrimaryAction.Reason)) `
                -Name "InstallerUI/Home/$($case.State)/DisabledReason" -Failure 'Вимкнена дія без пояснення.'
        }
    }

    $update = ConvertTo-BRAVOInstallerHomeViewModel -State ([pscustomobject]@{ state = 'UpdateAvailable'; targetVersion = '5.4.0'; runtimeRoot = 'C:\x' })
    Test-BRAVOCondition -Condition ($update.PrimaryAction.Label -eq 'Оновити до 5.4.0' -and $update.PrimaryAction.Key -eq 'Update') `
        -Name 'InstallerUI/Home/UpdateAvailable/ProvenTarget' -Failure 'Оновити до <v> має з''являтись лише з доведеною ціллю.'

    $none = ConvertTo-BRAVOInstallerHomeViewModel -State ([pscustomobject]@{ state = 'NotInstalled' })
    $settingsAction = @($none.SecondaryActions | Where-Object { $_.Key -eq 'Settings' })[0]
    Test-BRAVOCondition -Condition ($settingsAction.Enabled -eq $false -and $none.VersionText -eq 'Версія: невідома') `
        -Name 'InstallerUI/Home/NotInstalled/NoSettings' -Failure 'Без встановлення Налаштування мають бути вимкнені.'

    $degraded = ConvertTo-BRAVOInstallerHomeViewModel -State ([pscustomobject]@{ state = 'Degraded'; runtimeRoot = 'C:\x' })
    $repair = @($degraded.SecondaryActions | Where-Object { $_.Key -eq 'Repair' })[0]
    Test-BRAVOCondition -Condition ($null -ne $repair -and $repair.Enabled) -Name 'InstallerUI/Home/Degraded/RepairSecondary' -Failure 'Degraded: Відновити компоненти має бути вторинною дією.'

    $recovery = ConvertTo-BRAVOInstallerHomeViewModel -State ([pscustomobject]@{ state = 'RollbackRequired'; runtimeRoot = 'C:\x' })
    $recSettings = @($recovery.SecondaryActions | Where-Object { $_.Key -eq 'Settings' })[0]
    Test-BRAVOCondition -Condition ($recovery.RecoveryFirst -and -not $recSettings.Enabled) -Name 'InstallerUI/Home/Recovery/First' -Failure 'Recovery має мати пріоритет над Налаштуваннями.'

    $amb = ConvertTo-BRAVOInstallerHomeViewModel -State ([pscustomobject]@{ state = 'Ambiguous'; candidateRoots = @('C:\a b', 'D:\c') })
    Test-BRAVOCondition -Condition ($amb.Candidates.Count -eq 2 -and [string]::IsNullOrEmpty($amb.PrimaryAction.Reason)) `
        -Name 'InstallerUI/Home/Ambiguous/Candidates' -Failure 'Кандидати каталогів мають передаватись у view-model.'

    $engineDown = ConvertTo-BRAVOInstallerHomeViewModel -State $null -EngineError 'тест'
    Test-BRAVOCondition -Condition ($engineDown.StateKey -eq 'EngineUnavailable' -and $engineDown.StatusMarker -eq '×' -and $engineDown.PrimaryAction.Key -eq 'Retry') `
        -Name 'InstallerUI/Home/EngineUnavailable' -Failure 'Без state має бути fail-closed «engine недоступний».'

    $unknown = ConvertTo-BRAVOInstallerHomeViewModel -State ([pscustomobject]@{ state = 'Wat' })
    Test-BRAVOCondition -Condition ($unknown.StatusMarker -eq '×') -Name 'InstallerUI/Home/UnknownState' -Failure 'Невідомий стан не може бути «здоровим».'

    $notValid = ConvertTo-BRAVOInstallerHomeViewModel -State ([pscustomobject]@{ state = 'Installed'; integrity = [pscustomobject]@{ status = 'Unknown' } })
    Test-BRAVOCondition -Condition ($notValid.StatusMarker -eq '!') -Name 'InstallerUI/Home/Installed/NoIntegrityNoGreen' -Failure 'Installed без підтвердженої цілісності не зелений.'

    # --- Preflight view-model ---
    $pre = [pscustomobject]@{ canProceed = $false; blockerCount = 1; findings = @(
        [pscustomobject]@{ id = 'A'; severity = 'Ok'; title = 'Система'; meaning = ''; action = ''; details = '' },
        [pscustomobject]@{ id = 'B'; severity = 'Warning'; title = 'Конфіг'; meaning = 'm'; action = 'a'; details = 'd-b' },
        [pscustomobject]@{ id = 'C'; severity = 'Blocker'; title = 'Диск'; meaning = 'мало місця'; action = ''; details = 'd-c' },
        [pscustomobject]@{ id = 'D'; severity = 'NotApplicable'; title = 'Н/З'; meaning = ''; action = ''; details = '' },
        [pscustomobject]@{ id = 'E'; severity = 'Exotic'; title = ''; meaning = ''; action = ''; details = '' }) }
    $pvm = ConvertTo-BRAVOInstallerPreflightViewModel -Preflight $pre
    $markers = @($pvm.Rows | ForEach-Object { $_.Marker }) -join ''
    Test-BRAVOCondition -Condition ($markers -eq '✓!×—×') -Name 'InstallerUI/Preflight/SeverityMarkers' -Failure "Маркери: $markers"
    Test-BRAVOCondition -Condition ($pvm.Rows[2].Action -match 'Дія не вказана' -and $pvm.Rows[4].Title -eq 'E') `
        -Name 'InstallerUI/Preflight/BlockerActionFallback' -Failure 'Blocker без action і severity без title мають мати fallback.'
    Test-BRAVOCondition -Condition ($pvm.SummaryMarker -eq '×' -and -not $pvm.CanProceed -and $pvm.RetryAction.Label -eq 'Повторити перевірку' -and $pvm.BlockerCount -eq 2) `
        -Name 'InstallerUI/Preflight/SummaryBlocked' -Failure "Підсумок: $($pvm.SummaryMarker) $($pvm.SummaryText)"
    $okOnly = ConvertTo-BRAVOInstallerPreflightViewModel -Preflight ([pscustomobject]@{ canProceed = $true; findings = @([pscustomobject]@{ id = 'A'; severity = 'Ok'; title = 't' }) })
    Test-BRAVOCondition -Condition ($okOnly.SummaryMarker -eq '✓' -and $okOnly.CanProceed) -Name 'InstallerUI/Preflight/SummaryOk' -Failure 'Усе Ok → ✓.'
    $warnOnly = ConvertTo-BRAVOInstallerPreflightViewModel -Preflight ([pscustomobject]@{ canProceed = $true; findings = @([pscustomobject]@{ id = 'W'; severity = 'Warning'; title = 't' }) })
    Test-BRAVOCondition -Condition ($warnOnly.SummaryMarker -eq '!') -Name 'InstallerUI/Preflight/SummaryWarning' -Failure 'Warning не має бути зеленим.'
    $empty = ConvertTo-BRAVOInstallerPreflightViewModel -Preflight $null
    Test-BRAVOCondition -Condition ($empty.Rows.Count -eq 0 -and $empty.SummaryMarker -eq '—') -Name 'InstallerUI/Preflight/NotRun' -Failure 'Без даних — «ще не виконано».'

    # --- Progress view-model ---
    $p0 = ConvertTo-BRAVOInstallerProgressViewModel -ProgressEvent @()
    $p1 = ConvertTo-BRAVOInstallerProgressViewModel -ProgressEvent @([pscustomobject]@{ phase = 'Backup'; status = 'Progress'; percent = $null; message = 'Резервна копія' })
    $p2 = ConvertTo-BRAVOInstallerProgressViewModel -ProgressEvent @([pscustomobject]@{ phase = 'Deploy'; status = 'Progress'; percent = 150; message = 'x' })
    Test-BRAVOCondition -Condition ($p0.Indeterminate -and $p1.Indeterminate -and $null -eq $p1.Percent -and $p2.Percent -eq 100 -and -not $p2.Indeterminate) `
        -Name 'InstallerUI/Progress/IndeterminateAndClamp' -Failure 'Невідомий percent має бути indeterminate; значення клемпиться до 100.'

    # --- Команди ---
    $toolkit = 'C:\Теку Тест\BRAVO Toolkit\'
    $resultFile = 'C:\Users\Іван Тест\AppData\Local\Temp\BRAVO_INSTALLER_x\result.json'
    $cmd = New-BRAVOInstallerEngineCommand -ToolkitRoot $toolkit -Action Preflight -ResultPath $resultFile -RuntimeRoot 'D:\Каталог з пробілом\'
    $joined = $cmd.ArgumentString
    Test-BRAVOCondition -Condition ($joined -like '-NoProfile -NonInteractive -File "C:\Теку Тест\BRAVO Toolkit\BRAVO_UPDATE.ps1" -Action Preflight -AsJson -ResultPath "C:\Users\Іван Тест\AppData\Local\Temp\BRAVO_INSTALLER_x\result.json" -RuntimeRoot "D:\Каталог з пробілом\\"') `
        -Name 'InstallerUI/Engine/CommandQuoting' -Failure "Аргументи: $joined"
    Test-BRAVOCondition -Condition ($cmd.FilePath -like '*\WindowsPowerShell\v1.0\powershell.exe') -Name 'InstallerUI/Engine/PowerShell51' -Failure $cmd.FilePath
    Test-BRAVOCondition -Condition ($joined -notmatch '(?i)password|secret|token|credential|Bypass') `
        -Name 'InstallerUI/Engine/NoSecretsNoBypass' -Failure 'Аргументи не мають містити секретів чи обходу політики виконання.'
    $stateCmd = New-BRAVOInstallerEngineCommand -ToolkitRoot 'C:\t' -Action State -ResultPath 'C:\r.json'
    Test-BRAVOCondition -Condition ($stateCmd.ArgumentString -notmatch '-RuntimeRoot' -and $stateCmd.ArgumentString -match '-Action State') `
        -Name 'InstallerUI/Engine/StateWithoutRoot' -Failure $stateCmd.ArgumentString
    $threw = $false
    try { [void](New-BRAVOInstallerEngineCommand -ToolkitRoot 'C:\a"b' -Action State -ResultPath 'C:\r.json') } catch { $threw = $true }
    Test-BRAVOCondition -Condition $threw -Name 'InstallerUI/Engine/RejectsQuoteInPath' -Failure 'Шлях з лапкою має відхилятись.'
    $threw = $false
    try { [void](New-BRAVOInstallerEngineCommand -ToolkitRoot 'C:\a' -Action Execute -ResultPath 'C:\r.json') } catch { $threw = $true }
    Test-BRAVOCondition -Condition $threw -Name 'InstallerUI/Engine/OnlyReadOnlyActions' -Failure 'Дозволені лише State/Preflight.'

    $cfg = New-BRAVOInstallerConfiguratorCommand -ToolkitRoot 'C:\Теку Тест\BRAVO Toolkit'
    Test-BRAVOCondition -Condition ($cfg.ArgumentString -like '*-File "C:\Теку Тест\BRAVO Toolkit\BRAVO_CONFIGURATOR.ps1" -NoPause') `
        -Name 'InstallerUI/Configurator/Command' -Failure $cfg.ArgumentString
    $logs = New-BRAVOInstallerLogsCommand -LogsPath 'C:\Журнали Тест\LOGS'
    Test-BRAVOCondition -Condition ($logs.FilePath -like '*\explorer.exe' -and $logs.ArgumentString -eq '"C:\Журнали Тест\LOGS"') `
        -Name 'InstallerUI/Logs/Command' -Failure $logs.ArgumentString

    # --- Розмір вікна ---
    $small = Get-BRAVOInstallerStartupSize -WorkingAreaWidth 1024 -WorkingAreaHeight 728
    $big = Get-BRAVOInstallerStartupSize -WorkingAreaWidth 3000 -WorkingAreaHeight 2000
    $tiny = Get-BRAVOInstallerStartupSize -WorkingAreaWidth 800 -WorkingAreaHeight 500
    Test-BRAVOCondition -Condition ($small.Width -le 1024 -and $small.Height -le 728 -and $small.MinWidth -le 900 -and $big.Width -eq 1100 -and $tiny.Width -le 800 -and $tiny.MinWidth -le 800 -and $tiny.Height -le 500) `
        -Name 'InstallerUI/StartupSize/Clamp' -Failure "small=$($small.Width)x$($small.Height) tiny=$($tiny.Width)x$($tiny.Height)"

    # --- Приватний каталог результату: чистка лише власних каталогів ---
    $dir = & $mod { New-BRAVOInstallerPrivateDirectory }
    $exists = Test-Path -LiteralPath $dir -PathType Container
    & $mod { param($d) Remove-BRAVOInstallerPrivateDirectory -Path $d } $dir
    $goneAfter = -not (Test-Path -LiteralPath $dir)
    Test-BRAVOCondition -Condition ($exists -and $goneAfter) -Name 'InstallerUI/PrivateDirectory/Lifecycle' -Failure 'Створення/видалення приватного каталогу.'
    $foreign = Join-Path ([IO.Path]::GetTempPath()) ('FOREIGN_INSTALLERUI_TEST_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $foreign -Force)
    try {
        & $mod { param($d) Remove-BRAVOInstallerPrivateDirectory -Path $d } $foreign
        Test-BRAVOCondition -Condition (Test-Path -LiteralPath $foreign) -Name 'InstallerUI/PrivateDirectory/ForeignUntouched' -Failure 'Чужий каталог без префікса не можна видаляти.'
    } finally {
        if ($foreign.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $foreign -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Прогрес JSONL (толерантність до напівзаписаного рядка) ---
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('INSTALLERUI_TEST_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tmp -Force)
    try {
        $jsonl = Join-Path $tmp 'progress.jsonl'
        [IO.File]::WriteAllText($jsonl, ('{"sequence":1,"phase":"Preflight","status":"Started","percent":null,"message":"a"}' + "`n" + '{"sequence":2,"pha'), (New-Object Text.UTF8Encoding $false))
        $events = @(Read-BRAVOInstallerProgress -Path $jsonl)
        Test-BRAVOCondition -Condition ($events.Count -eq 1 -and $events[0].sequence -eq 1) -Name 'InstallerUI/Progress/PartialLine' -Failure "Подій: $($events.Count)"
        Test-BRAVOCondition -Condition (@(Read-BRAVOInstallerProgress -Path (Join-Path $tmp 'nope.jsonl')).Count -eq 0) -Name 'InstallerUI/Progress/Missing' -Failure 'Відсутній файл → порожньо.'
    } finally {
        if ($tmp.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Головна форма без ShowDialog ---
    $formResult = $null
    $formError = ''
    try {
        $formResult = New-BRAVOInstallerMainForm -ToolkitRoot $root
    } catch {
        $formError = $_.Exception.Message
    }
    if ($null -eq $formResult) {
        Test-BRAVOCondition -Condition $true -EnvironmentLimitation -Name 'InstallerUI/Form/Construct' -Failure "WinForms недоступний: $formError"
    } else {
        try {
            $controls = New-Object System.Collections.Generic.List[object]
            $stack = New-Object System.Collections.Stack
            $stack.Push($formResult)
            while ($stack.Count -gt 0) {
                $node = $stack.Pop()
                foreach ($child in $node.Controls) { $controls.Add($child); $stack.Push($child) }
            }
            $interactive = @($controls | Where-Object {
                $_ -is [System.Windows.Forms.Button] -or $_ -is [System.Windows.Forms.TextBox] -or $_ -is [System.Windows.Forms.ComboBox]
            })
            $unnamed = @($interactive | Where-Object { [string]::IsNullOrWhiteSpace($_.AccessibleName) })
            Test-BRAVOCondition -Condition ($interactive.Count -ge 10 -and $unnamed.Count -eq 0) -Name 'InstallerUI/Form/AccessibleNames' `
                -Failure "Без AccessibleName: $(@($unnamed | ForEach-Object { $_.Name }) -join ',') (інтерактивних: $($interactive.Count))"
            $ctx = $formResult.Tag
            $navOrder = @('Home', 'Preflight', 'Settings', 'Diagnostics', 'Logs' | ForEach-Object { $ctx.Controls["Nav.$_"].TabIndex })
            $ascending = $true
            for ($i = 1; $i -lt $navOrder.Count; $i++) { if ($navOrder[$i] -le $navOrder[$i - 1]) { $ascending = $false } }
            $navStops = @('Home', 'Preflight', 'Settings', 'Diagnostics', 'Logs' | Where-Object { -not $ctx.Controls["Nav.$_"].TabStop })
            Test-BRAVOCondition -Condition ($ascending -and $navStops.Count -eq 0) -Name 'InstallerUI/Form/NavTabOrder' -Failure "TabIndex: $($navOrder -join ',')"
            Test-BRAVOCondition -Condition ($formResult.MinimumSize.Width -le 1024 -and $formResult.MinimumSize.Height -le 768 -and
                $formResult.AutoScaleMode -eq [System.Windows.Forms.AutoScaleMode]::Dpi) -Name 'InstallerUI/Form/DpiAndMinSize' `
                -Failure "Min=$($formResult.MinimumSize) AutoScale=$($formResult.AutoScaleMode)"
            $errBox = $ctx.Controls['Error.Box']
            Test-BRAVOCondition -Condition ($errBox.ReadOnly -and $errBox.Multiline -and -not $ctx.Controls['Error.Group'].Visible) -Name 'InstallerUI/Form/ErrorBoxCopyable' `
                -Failure 'Error.Box має бути ReadOnly і прихованим до помилки.'
            $mnemonics = @('Home', 'Preflight', 'Settings', 'Diagnostics', 'Logs' | ForEach-Object { $ctx.Controls["Nav.$_"].Text }) | Where-Object { $_ -match '&' }
            Test-BRAVOCondition -Condition (@($mnemonics).Count -eq 5) -Name 'InstallerUI/Form/Mnemonics' -Failure 'Усі пункти навігації мають Alt-мнемоніку.'
            $homeVm = $ctx.HomeViewModel
            Test-BRAVOCondition -Condition ($null -ne $homeVm -and $ctx.CurrentScreen -eq 'Home') -Name 'InstallerUI/Form/HomeVisible' -Failure 'Головна має бути активним екраном.'
        } finally {
            $formResult.Tag.Timer.Dispose()
            $formResult.Dispose()
        }
    }
}

# ===== Майстер (екрани 3–10), запит/UAC/cancel, результат, Maintenance Center =====
& {
    $mod = Get-Module BRAVO.Installer.UI
    $future = [datetime]::UtcNow.AddMinutes(20).ToString('o')
    $planId = 'a1b2c3d4-0000-4000-8000-000000000001'
    $opId = 'b1b2c3d4-0000-4000-8000-000000000002'
    $plan = [pscustomobject]@{
        schemaVersion = 1; planId = $planId; operationId = $opId; action = 'Update'; expiresUtc = $future
        runtimeRoot = 'C:\Тест Каталог\BRAVO'; changes = [pscustomobject]@{ scheduler = [pscustomobject]@{ activationPolicy = 'ActivateOnSuccessOnly' } }
        findings = @()
    }
    $lines = @('План: Оновлення', 'Буде збережено без змін:')

    # --- Кроки ---
    $installSteps = @(Get-BRAVOInstallerWizardStepList -Operation Install)
    $updateSteps = @(Get-BRAVOInstallerWizardStepList -Operation Update)
    $planStep = ConvertTo-BRAVOInstallerWizardStepViewModel -Operation Install -Screen Plan
    $progressStep = ConvertTo-BRAVOInstallerWizardStepViewModel -Operation Install -Screen Progress
    Test-BRAVOCondition -Condition ($installSteps.Count -eq 8 -and $updateSteps.Count -eq 4 -and $planStep.NextLabel -eq 'Встановити' -and $planStep.PreviousKey -eq 'Schedule' -and
        -not $progressStep.ShowNavigation -and $null -eq $progressStep.PreviousKey) -Name 'InstallerUI/Wizard/Steps' -Failure "Install=$($installSteps.Count) Update=$($updateSteps.Count)"

    # --- Екран 3: джерело ---
    $s0 = ConvertTo-BRAVOInstallerSourceViewModel -Operation Install
    Test-BRAVOCondition -Condition (-not $s0.PrereleaseControlsVisible -and -not $s0.PrereleaseEffective -and $s0.CanContinue -and $s0.TagVisible -and -not $s0.ZipVisible) `
        -Name 'InstallerUI/Source/PrereleaseHiddenByDefault' -Failure 'Prerelease має бути прихований за замовчуванням.'
    Test-BRAVOCondition -Condition (-not (ConvertTo-BRAVOInstallerSourceViewModel -Operation Install -Tag 'v5.x').CanContinue -and (ConvertTo-BRAVOInstallerSourceViewModel -Operation Install -Tag 'v5.3.0').CanContinue) `
        -Name 'InstallerUI/Source/BadTag' -Failure 'Хибний тег.'
    $pre = ConvertTo-BRAVOInstallerSourceViewModel -Operation Update -Tag 'v5.4.0-rc.1'
    $preAdvOnly = ConvertTo-BRAVOInstallerSourceViewModel -Operation Update -Tag 'v5.4.0-rc.1' -AdvancedExpanded $true -AllowPrerelease $true
    $preOk = ConvertTo-BRAVOInstallerSourceViewModel -Operation Update -Tag 'v5.4.0-rc.1' -AdvancedExpanded $true -AllowPrerelease $true -PrereleaseAcknowledged $true
    $preHiddenAck = ConvertTo-BRAVOInstallerSourceViewModel -Operation Update -Tag 'v5.4.0-rc.1' -AdvancedExpanded $false -AllowPrerelease $true -PrereleaseAcknowledged $true
    Test-BRAVOCondition -Condition (-not $pre.CanContinue -and -not $preAdvOnly.CanContinue -and $preOk.CanContinue -and $preOk.PrereleaseEffective -and -not $preHiddenAck.CanContinue) `
        -Name 'InstallerUI/Source/PrereleaseNeedsAdvancedAndAck' -Failure 'Prerelease лише з Розширено + дозвіл + підтвердження.'
    $repairSource = ConvertTo-BRAVOInstallerSourceViewModel -Operation Repair
    Test-BRAVOCondition -Condition (-not $repairSource.CanContinue -and (ConvertTo-BRAVOInstallerSourceViewModel -Operation Repair -Tag 'v5.3.0').CanContinue) -Name 'InstallerUI/Source/RepairNeedsTag' -Failure 'Repair без тегу.'
    $zipDir = Join-Path ([IO.Path]::GetTempPath()) ('INSTALLERUI_G2_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path (Join-Path $zipDir 'Каталог з пробілом') -Force)
    try {
        $zip = Join-Path $zipDir 'Каталог з пробілом\BRAVO Toolkit.zip'
        [IO.File]::WriteAllBytes($zip, [byte[]](1, 2, 3))
        $localSource = ConvertTo-BRAVOInstallerSourceViewModel -Operation Install -SourceKind Local -ZipPath $zip
        $missing = ConvertTo-BRAVOInstallerSourceViewModel -Operation Install -SourceKind Local -ZipPath ($zip + 'x.zip')
        $notZip = ConvertTo-BRAVOInstallerSourceViewModel -Operation Install -SourceKind Local -ZipPath (Join-Path $zipDir 'a.txt')
        $emptyZip = ConvertTo-BRAVOInstallerSourceViewModel -Operation Install -SourceKind Local -ZipPath ''
        Test-BRAVOCondition -Condition ($localSource.CanContinue -and $localSource.ZipVisible -and -not $localSource.TagVisible -and -not $missing.CanContinue -and -not $notZip.CanContinue -and -not $emptyZip.CanContinue) `
            -Name 'InstallerUI/Source/LocalZip' -Failure 'Локальний ZIP зі шляхом із пробілами/кирилицею.'
    } finally {
        if ($zipDir.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $zipDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $sourceJson = (ConvertTo-BRAVOInstallerSourceViewModel -Operation Install -AdvancedExpanded $true | ConvertTo-Json -Depth 5)
    Test-BRAVOCondition -Condition ($sourceJson -notmatch '(?i)ігнор|ignore|skip.?hash|insecure') -Name 'InstallerUI/Source/NoIgnoreHash' -Failure 'Немає «ігнорувати hash».'

    # --- Екран 4: каталоги ---
    $stateWithCred = [pscustomobject]@{ runtimeRoot = 'D:\Каталог BRAVO'; credentials = [pscustomobject]@{ status = 'Unknown'; items = @(
        [pscustomobject]@{ component = 'MODEL'; account = 'TaskAccount'; credentialPresence = 'Found' },
        [pscustomobject]@{ component = 'MODEL'; account = 'CurrentUser'; credentialPresence = 'Missing' },
        [pscustomobject]@{ component = 'BLOG'; account = 'TaskAccount'; credentialPresence = 'Unknown' }) } }
    $dUpdate = ConvertTo-BRAVOInstallerDirectoriesViewModel -Operation Update -State $stateWithCred -DefaultRuntimeRoot 'C:\Program Files\BRAVO-Toolkit'
    $dInstall = ConvertTo-BRAVOInstallerDirectoriesViewModel -Operation Install -State $null -DefaultRuntimeRoot 'C:\Program Files\BRAVO-Toolkit'
    $dBad = ConvertTo-BRAVOInstallerDirectoriesViewModel -Operation Install -State $null -DefaultRuntimeRoot 'C:\x' -ChosenRuntimeRoot 'relative\path'
    Test-BRAVOCondition -Condition ($dUpdate.RuntimeRoot -eq 'D:\Каталог BRAVO' -and -not $dUpdate.RuntimeEditable -and @($dUpdate.Components).Count -eq 2 -and
        $dInstall.RuntimeEditable -and $dInstall.RuntimeRoot -eq 'C:\Program Files\BRAVO-Toolkit' -and $dInstall.CanContinue -and -not $dBad.CanContinue -and @($dInstall.Components).Count -eq 0 -and $dInstall.ComponentsNote) `
        -Name 'InstallerUI/Directories/ViewModel' -Failure "Update=$($dUpdate.RuntimeRoot) comps=$(@($dUpdate.Components).Count)"

    # --- Екран 5: резервні копії ---
    $modes = @(Get-BRAVOInstallerBackupModeList)
    $labels = (@($modes | ForEach-Object { $_.Label }) -join '|')
    $localBackup = ConvertTo-BRAVOInstallerBackupViewModel -Mode LocalOnly
    $both = ConvertTo-BRAVOInstallerBackupViewModel -Mode CloudAndSamba
    $unknownBackup = ConvertTo-BRAVOInstallerBackupViewModel -Mode 'Wat'
    Test-BRAVOCondition -Condition ($labels -eq 'SFTP|Мережева папка|SFTP і мережева папка|Лише локально' -and $localBackup.Warning -match 'віддаленої копії не буде' -and -not $localBackup.HasRemoteCopy -and
        $both.HasRemoteCopy -and [string]::IsNullOrEmpty($both.Warning) -and $both.CanonicalName -eq 'CloudAndSamba' -and (ConvertTo-BRAVOInstallerBackupViewModel -Mode SambaOnly).Label -eq 'Мережева папка' -and
        (ConvertTo-BRAVOInstallerBackupViewModel -Mode Cloud).Label -eq 'SFTP' -and -not $unknownBackup.ModeKnown -and ($both.EffectiveSummary -join ' ') -match 'SFTP: увімкнено' -and ($localBackup.EffectiveSummary -join ' ') -match 'SFTP: вимкнено') `
        -Name 'InstallerUI/Backup/ModesAndLocalOnlyWarning' -Failure $labels

    # --- Екран 6/7 ---
    $cred = ConvertTo-BRAVOInstallerCredentialsViewModel -State $stateWithCred -SetupAvailable $false
    $credJson = $cred | ConvertTo-Json -Depth 6
    Test-BRAVOCondition -Condition (@($cred.Rows).Count -eq 3 -and $cred.Rows[0].Status -eq 'Налаштовано' -and $cred.Rows[1].Marker -eq '!' -and -not $cred.EnterAction.Enabled -and $cred.EnterAction.Reason -and $credJson -notmatch '(?i)password|secret|token') `
        -Name 'InstallerUI/Credentials/StatusOnly' -Failure 'Лише статус, без секретів.'
    $sched = ConvertTo-BRAVOInstallerScheduleViewModel -Operation Install -State ([pscustomobject]@{ scheduler = [pscustomobject]@{ tasks = @(
        [pscustomobject]@{ name = 'BRAVO_Archive'; exists = $true; enabled = $false }, [pscustomobject]@{ name = 'BRAVO_Maintenance'; exists = $false; enabled = $false }) } })
    $schedUpdate = ConvertTo-BRAVOInstallerScheduleViewModel -Operation Update -State $null
    Test-BRAVOCondition -Condition (@($sched.Rows).Count -eq 2 -and $sched.Rows[0].Status -eq 'вимкнене' -and $sched.Rows[1].Status -eq 'відсутнє' -and ($sched.PolicyLines -join ' ') -match 'лишаються неактивними' -and
        ($schedUpdate.PolicyLines -join ' ') -match 'зберігається попередній стан' -and $sched.NoAutoRunNote -match 'не запускаються автоматично' -and $schedUpdate.EmptyNote) `
        -Name 'InstallerUI/Schedule/PolicyD6' -Failure 'Політика D6 у тексті.'

    # --- Екран 8: план ---
    Test-BRAVOCondition -Condition ((Get-BRAVOInstallerPlanShortId -Plan $plan) -eq 'a1b2c3d4' -and $null -eq (Get-BRAVOInstallerPlanShortId -Plan ([pscustomobject]@{ planId = 'xyz' })) -and $null -eq (Get-BRAVOInstallerPlanShortId -Plan $null)) `
        -Name 'InstallerUI/Plan/ShortId' -Failure 'Короткий id = перші 8 hex.'
    $p1 = ConvertTo-BRAVOInstallerPlanViewModel -Plan $plan -PlanLine $lines -Confirmed $false
    $p2 = ConvertTo-BRAVOInstallerPlanViewModel -Plan $plan -PlanLine $lines -Confirmed $true
    $pNone = ConvertTo-BRAVOInstallerPlanViewModel -Plan $null -PlanLine @() -ErrorText 'збій'
    $blockPlan = [pscustomobject]@{ planId = $planId; operationId = $opId; action = 'Update'; expiresUtc = $future
        findings = @([pscustomobject]@{ id = 'B'; severity = 'Blocker'; title = 'Диск'; action = 'Звільніть місце' }) }
    $pBlock = ConvertTo-BRAVOInstallerPlanViewModel -Plan $blockPlan -PlanLine $lines -Confirmed $true
    $expPlan = [pscustomobject]@{ planId = $planId; operationId = $opId; action = 'Update'; expiresUtc = [datetime]::UtcNow.AddMinutes(-1).ToString('o'); findings = @() }
    $pExp = ConvertTo-BRAVOInstallerPlanViewModel -Plan $expPlan -PlanLine $lines -Confirmed $true
    $pNoText = ConvertTo-BRAVOInstallerPlanViewModel -Plan $plan -PlanLine @() -Confirmed $true
    Test-BRAVOCondition -Condition ($p1.ShortId -eq 'a1b2c3d4' -and $p1.ConfirmText -match 'a1b2c3d4' -and $p1.CanConfirm -and -not $p1.ExecuteAction.Enabled -and $p2.ExecuteAction.Enabled -and $p2.ExecuteAction.Label -eq 'Оновити' -and
        -not $pNone.HasPlan -and -not $pNone.ExecuteAction.Enabled -and -not $pBlock.ExecuteAction.Enabled -and $pBlock.BlockerCount -eq 1 -and $pExp.Expired -and -not $pExp.ExecuteAction.Enabled -and -not $pNoText.ExecuteAction.Enabled -and $p1.UacNote -match 'UAC') `
        -Name 'InstallerUI/Plan/ConfirmGating' -Failure 'Підтвердження: галочка + відсутність blocker/expiry/тексту.'

    # --- Запит (без секретів) ---
    $req = New-BRAVOInstallerExecutionRequest -Plan $plan -ConfirmedPlanShortId 'A1B2C3D4' -PrereleaseAuthorized $false -RunSelfTest $true -BackupDestination 'LocalOnly' -SourcePath 'C:\Пакет з пробілом\r.zip'
    $reqJson = $req | ConvertTo-Json -Depth 20
    $threwMismatch = $false
    try { [void](New-BRAVOInstallerExecutionRequest -Plan $plan -ConfirmedPlanShortId 'deadbeef') } catch { $threwMismatch = $true }
    $threwNoPlanId = $false
    try { [void](New-BRAVOInstallerExecutionRequest -Plan ([pscustomobject]@{ planId = 'x' }) -ConfirmedPlanShortId 'x') } catch { $threwNoPlanId = $true }
    Test-BRAVOCondition -Condition ($req.schemaVersion -eq 1 -and $req.planId -eq $planId -and $req.confirmedPlanShortId -eq 'a1b2c3d4' -and $req.options.runSelfTest -and $req.options.backupDestination -eq 'LocalOnly' -and
        $req.options.activationPolicy -eq 'ActivateOnSuccessOnly' -and $req.options.sourcePath -eq 'C:\Пакет з пробілом\r.zip' -and $reqJson -notmatch '(?i)password|secret|token|apikey|passphrase' -and $threwMismatch -and $threwNoPlanId) `
        -Name 'InstallerUI/Request/ShapeNoSecretShortIdChecked' -Failure $reqJson.Substring(0, [Math]::Min(300, $reqJson.Length))

    $stateDir = Join-Path ([IO.Path]::GetTempPath()) ('INSTALLERUI_G2_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $stateDir -Force)
    try {
        $written = $null
        $writeError = ''
        try { $written = Write-BRAVOInstallerExecutionRequest -Request $req -StateRoot (Join-Path $stateDir 'Стан з пробілом') -ToolkitRoot $root } catch { $writeError = $_.Exception.Message }
        $bytes = @()
        if ($written -and (Test-Path -LiteralPath $written)) { $bytes = [IO.File]::ReadAllBytes($written) }
        $hasBom = ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)
        $roundTrip = $null
        if ($bytes.Count -gt 0) { $roundTrip = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json }
        Test-BRAVOCondition -Condition ($written -like '*\Requests\*.json' -and -not $hasBom -and $null -ne $roundTrip -and $roundTrip.planId -eq $planId -and -not (Test-Path -LiteralPath ($written + '.tmp'))) `
            -Name 'InstallerUI/Request/WrittenAtomicNoBom' -Failure "written=$written err=$writeError"

        # Секретне поле в запиті = відмова без створення файлу (fail closed).
        $secretReq = [pscustomobject]@{ requestId = [guid]::NewGuid().ToString(); plan = [pscustomobject]@{ sftpPassword = 'x' } }
        $secretStateRoot = Join-Path $stateDir 'secret-state'
        $secretThrew = $false
        try { [void](Write-BRAVOInstallerExecutionRequest -Request $secretReq -StateRoot $secretStateRoot -ToolkitRoot $root) } catch { $secretThrew = $true }
        Test-BRAVOCondition -Condition ($secretThrew -and -not (Test-Path -LiteralPath (Join-Path $secretStateRoot 'Requests'))) -Name 'InstallerUI/Request/SecretPropertyRejected' -Failure 'Запит із секретним полем не має записуватись.'

        # --- Cancel-файл ---
        $opDir = Join-Path $stateDir 'Operations\op1'
        [void](New-Item -ItemType Directory -Path $opDir -Force)
        $noControl = New-BRAVOInstallerCancelRequest -OperationDirectory $opDir
        [void](New-Item -ItemType Directory -Path (Join-Path $opDir 'control') -Force)
        $cancelOk = New-BRAVOInstallerCancelRequest -OperationDirectory $opDir
        $cancelFile = Join-Path $opDir 'control\cancel'
        $cancelAgain = New-BRAVOInstallerCancelRequest -OperationDirectory $opDir
        Test-BRAVOCondition -Condition (-not $noControl.Success -and $cancelOk.Success -and (Test-Path -LiteralPath $cancelFile -PathType Leaf) -and (Get-Item -LiteralPath $cancelFile).Length -eq 0 -and $cancelAgain.Success -and -not (New-BRAVOInstallerCancelRequest -OperationDirectory '').Success) `
            -Name 'InstallerUI/Cancel/EmptyControlFile' -Failure 'cancel = порожній файл у control\; без каталогу — відмова.'

        # --- Стан операції з диска ---
        $opGuid = '0a0b0c0d-1111-4222-8333-444455556666'
        $stateRoot = Join-Path $stateDir 'ST'
        $realOp = Join-Path $stateRoot "Operations\$opGuid"
        [void](New-Item -ItemType Directory -Path $realOp -Force)
        [IO.File]::WriteAllText((Join-Path $realOp 'progress.jsonl'), ('{"sequence":1,"phase":"Deploy","status":"Started","percent":null,"message":"x"}' + "`n"), (New-Object Text.UTF8Encoding $false))
        $st1 = Read-BRAVOInstallerExecutionState -StateRoot $stateRoot -OperationId $opGuid -ToolkitRoot $root
        [IO.File]::WriteAllText((Join-Path $realOp 'result.json'), '{ not json', (New-Object Text.UTF8Encoding $false))
        $st2 = Read-BRAVOInstallerExecutionState -StateRoot $stateRoot -OperationId $opGuid -ToolkitRoot $root
        $st3 = Read-BRAVOInstallerExecutionState -StateRoot $stateRoot -OperationId '..\evil' -ToolkitRoot $root
        Test-BRAVOCondition -Condition (@($st1.Events).Count -eq 1 -and $st1.MutationStarted -and -not $st1.ResultPresent -and $st2.ResultPresent -and -not $st2.ResultValid -and $null -eq $st2.Result -and $null -eq $st3.Directory -and @($st3.Events).Count -eq 0) `
            -Name 'InstallerUI/Execution/ReadState' -Failure "events=$(@($st1.Events).Count) present=$($st2.ResultPresent) valid=$($st2.ResultValid)"
    } finally {
        if ($stateDir.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # --- Міст до engine: лише read-only allowlist ---
    $bridgeBlocked = & $mod { param($t) try { Invoke-BRAVOInstallerUpdateRead -ToolkitRoot $t -Name 'Invoke-BRAVODeployment'; $false } catch { $true } } $root
    Test-BRAVOCondition -Condition $bridgeBlocked -Name 'InstallerUI/Bridge/MutationFunctionsUnreachable' -Failure 'Mutation-функції не мають бути досяжні з GUI.'

    # --- Cancel / mutationStarted ---
    $c0 = Get-BRAVOInstallerCancelAction -MutationStarted $false
    $c1 = Get-BRAVOInstallerCancelAction -MutationStarted $true
    $cDone = Get-BRAVOInstallerCancelAction -MutationStarted $true -Finished $true
    $cReq = Get-BRAVOInstallerCancelAction -MutationStarted $true -CancelRequested $true
    $cAct = Get-BRAVOInstallerCancelAction -MutationStarted $true -LastPhase 'Activate'
    Test-BRAVOCondition -Condition ($c0.Action.Label -eq 'Скасувати' -and $c0.Action.Key -eq 'Cancel' -and $c0.Action.Enabled -and $c1.Action.Label -eq 'Безпечно зупинити' -and $c1.Action.Key -eq 'SafeStop' -and
        -not $cDone.Action.Enabled -and -not $cReq.Action.Enabled -and $cReq.Action.Reason -and -not $cAct.Action.Enabled -and $c1.Note -match 'не завершується примусово') `
        -Name 'InstallerUI/Cancel/BeforeAfterMutation' -Failure "$($c0.Action.Label)/$($c1.Action.Label)"
    $ev = @([pscustomobject]@{ phase = 'Backup'; status = 'Completed' })
    $evM = @([pscustomobject]@{ phase = 'Backup'; status = 'Completed' }, [pscustomobject]@{ phase = 'Deploy'; status = 'Started' })
    Test-BRAVOCondition -Condition (-not (Test-BRAVOInstallerMutationStarted -ProgressEvent $ev) -and (Test-BRAVOInstallerMutationStarted -ProgressEvent $evM) -and
        (Test-BRAVOInstallerMutationStarted -ProgressEvent $ev -Journal ([pscustomobject]@{ mutationStarted = $true })) -and -not (Test-BRAVOInstallerMutationStarted -ProgressEvent @() -Journal $null)) `
        -Name 'InstallerUI/Cancel/MutationStartedDetection' -Failure 'mutationStarted із журналу або фази.'

    # --- Екран 9: виконання ---
    $now = New-Object DateTime 2026, 10, 29, 12, 0, 0, ([DateTimeKind]::Utc)
    $t0 = $now.AddSeconds(-75)
    $events = @(
        [pscustomobject]@{ sequence = 1; timestampUtc = $t0.ToString('o'); phase = 'Acquire'; status = 'Completed'; percent = 100; message = 'Отримано' },
        [pscustomobject]@{ sequence = 2; timestampUtc = $now.AddSeconds(-30).ToString('o'); phase = 'Verify'; status = 'Failed'; percent = $null; message = 'хеш' },
        [pscustomobject]@{ sequence = 3; timestampUtc = $now.AddSeconds(-10).ToString('o'); phase = 'Stage'; status = 'Heartbeat'; percent = $null; message = 'розпаковка' })
    $ex = ConvertTo-BRAVOInstallerExecutionViewModel -ProgressEvent $events -StartedUtc $t0.AddSeconds(-5) -NowUtc $now
    $phaseKeys = (@($ex.Phases | ForEach-Object { $_.Key }) -join ',')
    Test-BRAVOCondition -Condition ($phaseKeys -eq 'Acquire,Verify,Stage,Backup,Deploy,Configure,Validate,Activate,Commit' -and $ex.Phases[0].Marker -eq '✓' -and $ex.Phases[1].Marker -eq '×' -and $ex.Phases[2].StatusText -eq 'виконується' -and
        $ex.Phases[3].StatusText -eq 'очікує' -and $ex.Indeterminate -and $ex.ElapsedText -eq 'Минуло: 00:01:20' -and $ex.HeartbeatText -match '10 с тому' -and -not $ex.HeartbeatStale -and $ex.Cancel.Label -eq 'Скасувати') `
        -Name 'InstallerUI/Execution/PhasesElapsedHeartbeat' -Failure "$phaseKeys / $($ex.ElapsedText) / $($ex.HeartbeatText)"
    $stale = ConvertTo-BRAVOInstallerExecutionViewModel -ProgressEvent $events -StartedUtc $t0 -NowUtc $now.AddSeconds(400)
    $withPct = ConvertTo-BRAVOInstallerExecutionViewModel -ProgressEvent @([pscustomobject]@{ sequence = 1; phase = 'Deploy'; status = 'Progress'; percent = 42; message = 'копіювання' }) -NowUtc $now
    $rb = ConvertTo-BRAVOInstallerExecutionViewModel -ProgressEvent @([pscustomobject]@{ sequence = 1; phase = 'Rollback'; status = 'Started'; percent = $null; message = 'відкат' }) -NowUtc $now -MutationStarted $true
    $none = ConvertTo-BRAVOInstallerExecutionViewModel -ProgressEvent @() -NowUtc $now
    Test-BRAVOCondition -Condition ($stale.HeartbeatStale -and $stale.HeartbeatText -match 'не подає ознак' -and -not $withPct.Indeterminate -and $withPct.Percent -eq 42 -and @($rb.Phases).Count -eq 10 -and $rb.Phases[9].Key -eq 'Rollback' -and $rb.Cancel.Label -eq 'Безпечно зупинити' -and
        $none.Indeterminate -and $none.Phases[0].StatusText -eq 'очікує' -and $none.CloseWarning -match 'не зупиняє engine') `
        -Name 'InstallerUI/Execution/StaleRollbackPercent' -Failure 'stale/rollback/percent/closing.'

    # --- Екран 10: результат ---
    $mk = {
        param($status, $mutation, $task, $reason, $rollbackStatus)
        [pscustomobject]@{ schemaVersion = 1; operationId = $opId; planId = $planId; action = 'Update'; status = $status; reasonCode = $reason; exitCode = 0; exitCodeName = 'x'
            sourceVersion = '5.2.0'; targetVersion = '5.3.0'; installedVersion = '5.3.0'; lastPhase = 'Commit'; mutationStarted = $mutation
            validation = @([pscustomobject]@{ name = 'Integrity'; status = 'Pass'; message = '' }, [pscustomobject]@{ name = 'Tasks'; status = 'Warn'; message = 'вимкнені' })
            rollback = [pscustomobject]@{ attempted = ($rollbackStatus -ne 'NotNeeded'); status = $rollbackStatus; message = 'rb-msg' }
            taskActivation = [pscustomobject]@{ state = $task; tasks = @() }; findings = @(); logPath = 'C:\Журнал Тест\op.log'; reportPath = $null; journalPath = $null
            startedUtc = $future; finishedUtc = $future }
    }
    $rSuccess = ConvertTo-BRAVOInstallerResultViewModel -Result (& $mk 'Success' $true 'Active' '' 'NotNeeded')
    $rWarn = ConvertTo-BRAVOInstallerResultViewModel -Result (& $mk 'SuccessWithWarnings' $true 'Inactive' '' 'NotNeeded')
    $rFailed = ConvertTo-BRAVOInstallerResultViewModel -Result (& $mk 'Failed' $false 'Unchanged' 'PlanStale' 'NotNeeded')
    $rBack = ConvertTo-BRAVOInstallerResultViewModel -Result (& $mk 'RolledBack' $true 'Unchanged' '' 'Succeeded')
    $rCrit = ConvertTo-BRAVOInstallerResultViewModel -Result (& $mk 'Critical' $true 'Inactive' '' 'Failed')
    $rUnknown = ConvertTo-BRAVOInstallerResultViewModel -Result ([pscustomobject]@{ status = 'Wat' }) -NoResultReason 'код 5'
    $rNull = ConvertTo-BRAVOInstallerResultViewModel -Result $null
    $all = @($rSuccess, $rWarn, $rFailed, $rBack, $rCrit)
    $titles = @($all | ForEach-Object { $_.Title } | Select-Object -Unique)
    $markers = @($all | ForEach-Object { $_.Marker } | Select-Object -Unique)
    $accents = @($all | ForEach-Object { $_.Accent } | Select-Object -Unique)
    Test-BRAVOCondition -Condition ($titles.Count -eq 5 -and $markers.Count -eq 5 -and $accents.Count -eq 5) -Name 'InstallerUI/Result/FiveDistinctVisuals' -Failure "titles=$($titles.Count) markers=$($markers.Count) accents=$($accents.Count)"
    Test-BRAVOCondition -Condition ($rSuccess.Title -eq 'Оновлено і перевірено — завдання увімкнені' -and $rSuccess.Accent -eq 'Success' -and $rSuccess.IsSuccess -and -not $rSuccess.RepeatBlocked -and $rSuccess.TaskActivationText -match 'увімкнені') `
        -Name 'InstallerUI/Result/Success' -Failure $rSuccess.Title
    Test-BRAVOCondition -Condition ($rWarn.Title -match 'але потрібна дія — завдання не активовані' -and $rWarn.Accent -eq 'Warning' -and $rWarn.Accent -ne 'Success' -and $rWarn.Marker -eq '!' -and ($rWarn.Body -join ' ') -match 'Це не повний успіх' -and $rWarn.TaskActivationText -match 'НЕ активовані') `
        -Name 'InstallerUI/Result/SuccessWithWarningsNotGreen' -Failure $rWarn.Title
    Test-BRAVOCondition -Condition ($rFailed.Title -eq 'Операцію не виконано' -and ($rFailed.Body -join ' ') -match 'Runtime не змінювався' -and ($rFailed.Body -join ' ') -match 'план застарів' -and (@($rFailed.Actions | Where-Object { $_.Key -eq 'RestartWizard' }).Count -eq 1) -and -not $rFailed.IsSuccess) `
        -Name 'InstallerUI/Result/FailedBeforeMutation' -Failure ($rFailed.Body -join ' ')
    $failedMutated = ConvertTo-BRAVOInstallerResultViewModel -Result (& $mk 'Failed' $true 'Unchanged' 'Error' 'NotNeeded')
    Test-BRAVOCondition -Condition (($failedMutated.Body -join ' ') -notmatch 'Runtime не змінювався' -and @($failedMutated.Actions | Where-Object { $_.Key -eq 'RestartWizard' }).Count -eq 0) -Name 'InstallerUI/Result/FailedAfterMutationNoUnchangedClaim' -Failure 'Не стверджуємо «не змінювався» після початку змін.'
    Test-BRAVOCondition -Condition ($rBack.Title -eq 'Оновлення не завершено. Попередній стан відновлено й перевірено' -and ($rBack.Body -join ' ') -match 'не успішне завершення' -and $rBack.Accent -eq 'RolledBack' -and -not $rBack.IsSuccess) `
        -Name 'InstallerUI/Result/RolledBackIsFailure' -Failure $rBack.Title
    Test-BRAVOCondition -Condition ($rCrit.Title -match 'КРИТИЧНИЙ СТАН' -and $rCrit.RepeatBlocked -and ($rCrit.Body -join ' ') -match 'Не запускайте подальше оновлення' -and $rCrit.TaskActivationText -match 'Не вмикайте завдання' -and
        -not (@($rCrit.Actions | Where-Object { $_.Key -eq 'Configure' })[0]).Enabled -and @($rCrit.Actions | Where-Object { $_.Key -eq 'RestartWizard' }).Count -eq 0) `
        -Name 'InstallerUI/Result/CriticalBlocksRepeat' -Failure $rCrit.Title
    Test-BRAVOCondition -Condition ($rUnknown.Kind -eq 'Unknown' -and $rUnknown.RepeatBlocked -and $rNull.Kind -eq 'Unknown' -and $rNull.Accent -eq 'Critical' -and ($rUnknown.Body -join ' ') -match 'код 5') -Name 'InstallerUI/Result/UnknownFailsClosed' -Failure 'Невідомий результат = fail closed.'
    $actionKeys = (@($rWarn.Actions | ForEach-Object { $_.Key }) -join ',')
    Test-BRAVOCondition -Condition ($actionKeys -eq 'OpenLog,SaveReport,Configure,Finish' -and ($rWarn.ValidationRows | Where-Object { $_.Marker -eq '!' }).Text -match 'зауваження' -and $rWarn.TechnicalText -match [regex]::Escape($opId) -and $rWarn.TechnicalText -notmatch '(?i)password|secret') `
        -Name 'InstallerUI/Result/ActionsAndTechnical' -Failure $actionKeys
    $instOk = ConvertTo-BRAVOInstallerResultViewModel -Result ([pscustomobject]@{ status = 'Success'; action = 'Install'; taskActivation = [pscustomobject]@{ state = 'Inactive' } })
    Test-BRAVOCondition -Condition ($instOk.Title -eq 'Встановлено і перевірено' -and @($instOk.Actions | Where-Object { $_.Key -eq 'EnterCredentials' }).Count -eq 1) -Name 'InstallerUI/Result/InstallOffersCredentials' -Failure $instOk.Title

    # --- Home / Maintenance ---
    $blocked = ConvertTo-BRAVOInstallerHomeViewModel -State ([pscustomobject]@{ state = 'Installed'; integrity = [pscustomobject]@{ status = 'Valid' }; runtimeRoot = 'C:\x' }) -RepeatBlocked
    $blockedRecover = ConvertTo-BRAVOInstallerHomeViewModel -State ([pscustomobject]@{ state = 'InterruptedUpdate'; runtimeRoot = 'C:\x' }) -RepeatBlocked
    Test-BRAVOCondition -Condition (-not $blocked.PrimaryAction.Enabled -and $blocked.PrimaryAction.Reason -match 'заблоковано' -and $blockedRecover.PrimaryAction.Enabled) -Name 'InstallerUI/Home/RepeatBlockedAfterCritical' -Failure 'Після Critical Install/Update/Repair заблоковано, Recover — ні.'
    $m1 = ConvertTo-BRAVOInstallerMaintenanceViewModel -State ([pscustomobject]@{ state = 'Installed'; runtimeRoot = 'C:\x' })
    $m2 = ConvertTo-BRAVOInstallerMaintenanceViewModel -State ([pscustomobject]@{ state = 'NotInstalled' })
    $m3 = ConvertTo-BRAVOInstallerMaintenanceViewModel -State ([pscustomobject]@{ state = 'RollbackRequired'; runtimeRoot = 'C:\x' })
    $m4 = ConvertTo-BRAVOInstallerMaintenanceViewModel -State ([pscustomobject]@{ state = 'Installed'; runtimeRoot = 'C:\x' }) -RepeatBlocked
    Test-BRAVOCondition -Condition ($m1.RepairAction.Enabled -and $m1.ConfigureAction.Enabled -and -not $m2.RepairAction.Enabled -and $m2.RepairAction.Reason -and -not $m3.RepairAction.Enabled -and -not $m4.RepairAction.Enabled -and $m1.RepairNote -match 'план, підтвердження') `
        -Name 'InstallerUI/Maintenance/Actions' -Failure 'Repair/Configure/Credentials.'

    # --- Журнали ---
    $files = @(
        [pscustomobject]@{ Name = 'a.log'; FullName = 'C:\L\a.log'; Length = 500; LastWriteTime = [datetime]'2026-10-01' },
        [pscustomobject]@{ Name = 'b.log'; FullName = 'C:\L\b.log'; Length = 3MB; LastWriteTime = [datetime]'2026-10-05' })
    $logVm = ConvertTo-BRAVOInstallerLogListViewModel -File $files
    $logEmpty = ConvertTo-BRAVOInstallerLogListViewModel -File @()
    Test-BRAVOCondition -Condition ($logVm.Count -eq 2 -and $logVm.Rows[0].Name -eq 'b.log' -and $logVm.Rows[0].SizeText -match 'МБ' -and $logVm.Rows[1].SizeText -match 'Б' -and $logEmpty.EmptyNote -eq 'Журналів не знайдено.' -and (ConvertTo-BRAVOInstallerLogListViewModel -File $files -MaxItems 1).Count -eq 1) `
        -Name 'InstallerUI/Logs/ListViewModel' -Failure 'Список журналів.'

    # --- Команди ---
    $planCmd = New-BRAVOInstallerPlanCommand -ToolkitRoot 'C:\Теку Тест\BRAVO Toolkit' -Operation Update -ResultPath 'C:\Users\Іван Тест\Temp\p.json' -Tag 'v5.3.0' -BackupDestination LocalOnly -RuntimeRoot 'D:\Каталог з пробілом'
    Test-BRAVOCondition -Condition ($planCmd.ArgumentString -eq '-NoProfile -NonInteractive -File "C:\Теку Тест\BRAVO Toolkit\BRAVO_UPDATE.ps1" -Action Plan -Operation Update -Tag "v5.3.0" -BackupDestination LocalOnly -RuntimeRoot "D:\Каталог з пробілом" -AsJson -ResultPath "C:\Users\Іван Тест\Temp\p.json"') `
        -Name 'InstallerUI/Command/PlanOnlineQuoting' -Failure $planCmd.ArgumentString
    $planZip = New-BRAVOInstallerPlanCommand -ToolkitRoot 'C:\t' -Operation Install -ResultPath 'C:\r.json' -SourcePath 'C:\Пакети Тест\BRAVO 5.3.zip' -AllowPrerelease
    Test-BRAVOCondition -Condition ($planZip.ArgumentString -like '*-Operation Install -SourcePath "C:\Пакети Тест\BRAVO 5.3.zip" -AllowPrerelease -AsJson*' -and $planZip.ArgumentString -notmatch '-Tag') -Name 'InstallerUI/Command/PlanLocalZip' -Failure $planZip.ArgumentString
    $threwBoth = $false; $threwTag = $false; $threwMode = $false
    try { [void](New-BRAVOInstallerPlanCommand -ToolkitRoot 'C:\t' -Operation Install -ResultPath 'C:\r.json' -SourcePath 'C:\a.zip' -Tag 'v5.3.0') } catch { $threwBoth = $true }
    try { [void](New-BRAVOInstallerPlanCommand -ToolkitRoot 'C:\t' -Operation Install -ResultPath 'C:\r.json' -Tag 'v5.3.0" -Foo') } catch { $threwTag = $true }
    try { [void](New-BRAVOInstallerPlanCommand -ToolkitRoot 'C:\t' -Operation Install -ResultPath 'C:\r.json' -BackupDestination 'Other') } catch { $threwMode = $true }
    Test-BRAVOCondition -Condition ($threwBoth -and $threwTag -and $threwMode) -Name 'InstallerUI/Command/PlanRejectsBadInput' -Failure 'ZIP+тег, тег з лапкою, невідомий режим мають відхилятись.'
    $exec = New-BRAVOInstallerExecuteCommand -ToolkitRoot 'C:\Теку Тест\BRAVO Toolkit' -RequestPath 'C:\ProgramData\BRAVO\State\Update\Requests\a b.json'
    Test-BRAVOCondition -Condition ($exec.Verb -eq 'RunAs' -and $exec.ArgumentString -eq '-NoProfile -File "C:\Теку Тест\BRAVO Toolkit\BRAVO_UPDATE.ps1" -Action Execute -RequestPath "C:\ProgramData\BRAVO\State\Update\Requests\a b.json" -NoPause' -and $exec.FilePath -like '*\WindowsPowerShell\v1.0\powershell.exe' -and $exec.ArgumentString -notmatch '(?i)password|secret|token|Bypass|-Command') `
        -Name 'InstallerUI/Command/ExecuteRunAs' -Failure $exec.ArgumentString
    $credCmd = New-BRAVOInstallerCredentialsCommand -RuntimeRoot 'C:\Program Files\BRAVO Toolkit'
    Test-BRAVOCondition -Condition ($credCmd.ArgumentString -eq '-NoProfile -File "C:\Program Files\BRAVO Toolkit\BRAVO_SETUP.ps1" -Action Credentials' -and $credCmd.ArgumentString -notmatch 'Hidden|NonInteractive' -and $null -eq $credCmd.PSObject.Properties['Verb']) `
        -Name 'InstallerUI/Command/CredentialsVisibleConsole' -Failure $credCmd.ArgumentString
    $recCmd = New-BRAVOInstallerRecoverCommand -ToolkitRoot 'C:\t' -RuntimeRoot 'D:\Каталог'
    Test-BRAVOCondition -Condition ($recCmd.Verb -eq 'RunAs' -and $recCmd.ArgumentString -like '*-Action Recover -RuntimeRoot "D:\Каталог" -NoPause') -Name 'InstallerUI/Command/Recover' -Failure $recCmd.ArgumentString
    $logCmd = New-BRAVOInstallerOpenLogCommand -LogPath 'C:\Журнал Тест\op.log'
    Test-BRAVOCondition -Condition ($logCmd.FilePath -like '*\explorer.exe' -and $logCmd.ArgumentString -eq '/select,"C:\Журнал Тест\op.log"') -Name 'InstallerUI/Command/OpenLog' -Failure $logCmd.ArgumentString
    $diagCmd = New-BRAVOInstallerEngineCommand -ToolkitRoot 'C:\t' -Action Diagnose -ResultPath 'C:\r.json'
    Test-BRAVOCondition -Condition ($diagCmd.ArgumentString -match '-Action Diagnose -AsJson') -Name 'InstallerUI/Command/Diagnose' -Failure $diagCmd.ArgumentString

    # --- Форма: нові екрани ---
    $wizardForm = $null
    $wizardFormError = ''
    try { $wizardForm = New-BRAVOInstallerMainForm -ToolkitRoot $root } catch { $wizardFormError = $_.Exception.Message }
    if ($null -eq $wizardForm) {
        Test-BRAVOCondition -Condition $true -EnvironmentLimitation -Name 'InstallerUI/Wizard/FormConstruct' -Failure "WinForms недоступний: $wizardFormError"
    } else {
        try {
            $ctx = $wizardForm.Tag
            $screens = @('Source', 'Directories', 'Backup', 'Credentials', 'Schedule', 'Plan', 'Progress', 'Result')
            $missingScreens = @($screens | Where-Object { -not $ctx.Controls.ContainsKey("Screen.$_") })
            $problems = New-Object System.Collections.Generic.List[string]
            foreach ($screen in $screens) {
                if (-not $ctx.Controls.ContainsKey("Screen.$screen")) { continue }
                $stack = New-Object System.Collections.Stack
                $stack.Push($ctx.Controls["Screen.$screen"])
                $interactive = New-Object System.Collections.Generic.List[object]
                while ($stack.Count -gt 0) {
                    $node = $stack.Pop()
                    foreach ($child in $node.Controls) {
                        if ($child -is [System.Windows.Forms.Button] -or $child -is [System.Windows.Forms.TextBox] -or $child -is [System.Windows.Forms.CheckBox] -or
                            $child -is [System.Windows.Forms.RadioButton] -or $child -is [System.Windows.Forms.ComboBox] -or $child -is [System.Windows.Forms.ListBox]) { $interactive.Add($child) }
                        $stack.Push($child)
                    }
                }
                foreach ($control in $interactive) {
                    if ([string]::IsNullOrWhiteSpace($control.AccessibleName)) { [void]$problems.Add("$screen/$($control.Name): без AccessibleName") }
                }
                $indexes = @($interactive | ForEach-Object { $_.TabIndex })
                if (@($indexes | Select-Object -Unique).Count -ne $indexes.Count) { [void]$problems.Add("${screen}: TabIndex не унікальні") }
            }
            Test-BRAVOCondition -Condition ($missingScreens.Count -eq 0 -and $problems.Count -eq 0) -Name 'InstallerUI/Wizard/FormAccessibleNamesTabIndex' -Failure ("missing=$($missingScreens -join ',') problems=$($problems -join '; ')")
            Test-BRAVOCondition -Condition (-not $ctx.Controls['Source.AdvancedGroup'].Visible -and -not $ctx.RepeatBlocked -and $null -eq $ctx.Exec) -Name 'InstallerUI/Wizard/FormPrereleaseHiddenInitially' -Failure 'Prerelease-група прихована до «Розширено».'

            # Прогін екранів майстра без показу форми: жодних винятків, коректні тексти.
            $walk = & $mod {
                param($c, $planObj, $planText)
                $log = New-Object System.Collections.Generic.List[string]
                try {
                    Enter-BRAVOInstallerWizard -Context $c -Operation 'Install'
                    foreach ($screen in @('Source', 'Directories', 'Backup', 'Credentials', 'Schedule')) {
                        Show-BRAVOInstallerWizardStep -Context $c -Screen $screen
                        $log.Add("$screen=" + $c.Controls["$screen.Step"].Text)
                    }
                    $c.Wizard.BackupMode = 'LocalOnly'
                    Show-BRAVOInstallerWizardStep -Context $c -Screen 'Backup'
                    $log.Add('warn=' + $c.Controls['Backup.Warning'].Text)
                    $c.Wizard.Plan = $planObj; $c.Wizard.PlanLines = @($planText); $c.Wizard.PlanConfirmed = $false
                    Show-BRAVOInstallerWizardStep -Context $c -Screen 'Plan'
                    $log.Add('planNext=' + $c.Controls['Plan.Next'].Enabled)
                    $c.Controls['Plan.Confirm'].Checked = $true
                    $log.Add('planNextAfter=' + $c.Controls['Plan.Next'].Enabled)
                    Update-BRAVOInstallerProgressScreen -Context $c -ViewModel (ConvertTo-BRAVOInstallerExecutionViewModel -ProgressEvent @() -NowUtc ([datetime]::UtcNow))
                    $log.Add('bar=' + $c.Controls['Progress.Bar'].Style)
                    foreach ($status in @('Success', 'SuccessWithWarnings', 'Failed', 'RolledBack', 'Critical')) {
                        $vm = ConvertTo-BRAVOInstallerResultViewModel -Result ([pscustomobject]@{ status = $status; action = 'Update'; mutationStarted = $false; taskActivation = [pscustomobject]@{ state = 'Inactive' } })
                        Update-BRAVOInstallerResultScreen -Context $c -ViewModel $vm
                        $log.Add("$status=" + $c.Controls['Result.Title'].Text)
                    }
                    Show-BRAVOInstallerScreen -Context $c -Name 'Result'
                    $log.Add('current=' + $c.CurrentScreen)
                } catch {
                    $log.Add('EXCEPTION ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber)
                }
                @($log.ToArray())
            } $ctx $plan $lines
            $walkText = ($walk -join ' | ')
            Test-BRAVOCondition -Condition ($walkText -notmatch 'EXCEPTION' -and $walkText -match 'Source=Крок 1 з 8' -and $walkText -match 'Schedule=Крок 5 з 8' -and $walkText -match 'warn=! Увага: віддаленої копії не буде' -and
                $walkText -match 'planNext=False' -and $walkText -match 'planNextAfter=True' -and $walkText -match 'Success=✓ Оновлено' -and $walkText -match 'Critical=‼ КРИТИЧНИЙ' -and $walkText -match 'current=Result') `
                -Name 'InstallerUI/Wizard/FormScreensWalkthrough' -Failure $walkText
        } finally {
            $wizardForm.Tag.Timer.Dispose()
            $wizardForm.Dispose()
        }
    }
}
