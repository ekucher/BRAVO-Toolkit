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
        @{ State = 'NotInstalled';        Key = 'Install';      Label = 'Встановити';                   Enabled = $false },
        @{ State = 'Installed';           Key = 'CheckUpdates'; Label = 'Перевірити оновлення';         Enabled = $false },
        @{ State = 'PrereleaseInstalled'; Key = 'CheckUpdates'; Label = 'Перевірити оновлення';         Enabled = $false },
        @{ State = 'UpdateAvailable';     Key = 'CheckUpdates'; Label = 'Перевірити оновлення';         Enabled = $false },
        @{ State = 'Degraded';            Key = 'ViewProblems'; Label = 'Переглянути проблеми';         Enabled = $true  },
        @{ State = 'RepairRequired';      Key = 'Repair';       Label = 'Відновити компоненти';         Enabled = $false },
        @{ State = 'InterruptedUpdate';   Key = 'Recover';      Label = 'Відновити після переривання';  Enabled = $false },
        @{ State = 'RollbackRequired';    Key = 'Rollback';     Label = 'Завершити відкат';             Enabled = $false },
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
            Test-BRAVOCondition -Condition ($vm.PrimaryAction.Reason -eq 'Доступно після приймання engine') `
                -Name "InstallerUI/Home/$($case.State)/DisabledReason" -Failure 'Вимкнена mutation-дія без пояснення.'
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
    Test-BRAVOCondition -Condition ($null -ne $repair -and -not $repair.Enabled) -Name 'InstallerUI/Home/Degraded/RepairSecondary' -Failure 'Degraded: Відновити компоненти має бути вторинною вимкненою дією.'

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
