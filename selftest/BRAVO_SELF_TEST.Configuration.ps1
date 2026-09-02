# Домен-фрагмент self-test: BRAVO.Configuration (P0 Configuration
# Foundation, PR A) — canonical built-in raw defaults +
# Merge-BRAVOConfiguration/ConvertTo-BRAVONestedOverride/
# Resolve-BRAVORawConfiguration. Модуль ще нікуди не підключений
# (BRAVO_CONFIG_LOADER.ps1/BRAVO.config без змін) — тут перевіряється
# лише сама merge/precedence-логіка як самодостатній building block.
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 -- НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition, $script:failures.

    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.psd1') -Force

    # --- Built-in default: ExcludedDrives = @() (розділ 5 ТЗ) ---
    $configurationDefaults = Get-BRAVODefaultConfiguration
    Test-BRAVOCondition `
        -Condition (
            $configurationDefaults.maintenanceSettings.Limits.ExcludedDrives -is [array] -and
            $configurationDefaults.maintenanceSettings.Limits.ExcludedDrives.Count -eq 0
        ) `
        -Name "Configuration/DefaultExcludedDrivesEmpty" `
        -Failure "built-in default maintenanceSettings.Limits.ExcludedDrives має бути @() (жодного environment-specific диска)"

    # --- Immutability / no cross-load leakage (Test 13/15 ТЗ) ---
    $firstLoad = Get-BRAVODefaultConfiguration
    $firstLoad.maintenanceSettings.Limits.ExcludedDrives = @('F:\')
    $firstLoad.bravoSettings.InstitutionName = 'MUTATED'
    $secondLoad = Get-BRAVODefaultConfiguration
    Test-BRAVOCondition `
        -Condition (
            $secondLoad.maintenanceSettings.Limits.ExcludedDrives.Count -eq 0 -and
            [string]$secondLoad.bravoSettings.InstitutionName -eq 'УСТАНОВА'
        ) `
        -Name "Configuration/NoCrossLoadLeakage" `
        -Failure "мутація об'єкта, поверненого одним викликом Get-BRAVODefaultConfiguration, не повинна впливати на наступний виклик (spільний mutable reference)"

    # --- Merge: hashtable рекурсія зберігає sibling-поля ---
    $mergeBase = @{ scheduler = @{ Backup = @{ Enabled = $true; DailyAt = '23:00' } } }
    $mergeOverride = @{ scheduler = @{ Backup = @{ DailyAt = '01:00' } } }
    $mergeResult = Merge-BRAVOConfiguration -Base $mergeBase -Override $mergeOverride
    Test-BRAVOCondition `
        -Condition (
            [bool]$mergeResult.scheduler.Backup.Enabled -eq $true -and
            [string]$mergeResult.scheduler.Backup.DailyAt -eq '01:00'
        ) `
        -Name "Configuration/MergeRecursiveHashtablePreservesSiblings" `
        -Failure "рекурсивний merge має перевизначати лише задане листове поле, зберігаючи сусідні (Enabled) незмінними"

    # --- Merge: масив повністю замінюється, не конкатенується ---
    $arrayBase = @{ arr = @('D:\') }
    $arrayReplaceResult = Merge-BRAVOConfiguration -Base $arrayBase -Override @{ arr = @('F:\') }
    Test-BRAVOCondition `
        -Condition (
            @($arrayReplaceResult.arr).Count -eq 1 -and [string]$arrayReplaceResult.arr[0] -eq 'F:\'
        ) `
        -Name "Configuration/MergeArrayReplacesNotConcatenates" `
        -Failure "override-масив має ПОВНІСТЮ замінювати base-масив (отримано: $($arrayReplaceResult.arr -join ', '))"

    # --- Merge: явний @() override теж застосовується (не ігнорується як falsy) ---
    $explicitEmptyResult = Merge-BRAVOConfiguration -Base $arrayBase -Override @{ arr = @() }
    Test-BRAVOCondition `
        -Condition (@($explicitEmptyResult.arr).Count -eq 0) `
        -Name "Configuration/MergeExplicitEmptyArrayApplied" `
        -Failure "явний override @() має дати порожній масив, а не успадкувати base (@('D:\'))"

    # --- Merge: жодної мутації вхідних об'єктів ---
    Test-BRAVOCondition `
        -Condition (@($arrayBase.arr).Count -eq 1 -and [string]$arrayBase.arr[0] -eq 'D:\') `
        -Name "Configuration/MergeDoesNotMutateInputs" `
        -Failure "Merge-BRAVOConfiguration не повинен мутувати вхідний -Base (отримано: $($arrayBase.arr -join ', '))"

    # --- Детермінований repeated merge (Test 15 ТЗ) ---
    $repeatBase = Get-BRAVODefaultConfiguration
    $repeatOverride = @{ maintenanceSettings = @{ Restore = @{ Time = '01:00' } } }
    $repeatResult1 = Merge-BRAVOConfiguration -Base $repeatBase -Override $repeatOverride
    $repeatResult2 = Merge-BRAVOConfiguration -Base $repeatBase -Override $repeatOverride
    Test-BRAVOCondition `
        -Condition (
            [string]$repeatResult1.maintenanceSettings.Restore.Time -eq [string]$repeatResult2.maintenanceSettings.Restore.Time -and
            [string]$repeatResult1.maintenanceSettings.Restore.WindowStart -eq [string]$repeatResult2.maintenanceSettings.Restore.WindowStart
        ) `
        -Name "Configuration/DeterministicRepeatedMerge" `
        -Failure "два незалежні merge з однаковими входами мають давати однаковий результат"

    # --- ConvertTo-BRAVONestedOverride: невідомий dot-path -> fail-closed (Test 12 ТЗ) ---
    $unknownPathThrew = $false
    $unknownPathMessage = $null
    try {
        ConvertTo-BRAVONestedOverride `
            -DotPathOverrides @{ 'maintenanceSettings.Limit.ExcludedDrives' = @() } `
            -ReferenceConfiguration $configurationDefaults | Out-Null
    } catch {
        $unknownPathThrew = $true
        $unknownPathMessage = $_.Exception.Message
    }
    Test-BRAVOCondition `
        -Condition ($unknownPathThrew -and $unknownPathMessage -match 'maintenanceSettings\.Limit\.ExcludedDrives') `
        -Name "Configuration/UnknownDotPathFailsClosed" `
        -Failure "опечатка в dot-path (Limit замість Limits) має завершуватись помилкою, а не мовчки створювати новий вузол"

    # --- ConvertTo-BRAVONestedOverride: відомий dot-path -> коректний nested-граф ---
    $knownPathResult = ConvertTo-BRAVONestedOverride `
        -DotPathOverrides @{ 'maintenanceSettings.Limits.ExcludedDrives' = @('F:\') } `
        -ReferenceConfiguration $configurationDefaults
    Test-BRAVOCondition `
        -Condition (
            @($knownPathResult.maintenanceSettings.Limits.ExcludedDrives).Count -eq 1 -and
            [string]$knownPathResult.maintenanceSettings.Limits.ExcludedDrives[0] -eq 'F:\'
        ) `
        -Name "Configuration/KnownDotPathConvertsToNestedGraph" `
        -Failure "відомий dot-path має коректно розгортатись у вкладений hashtable-вузол"

    # --- Resolve-BRAVORawConfiguration: повна precedence DEFAULT < primary < local ---
    $precedencePrimary = @{ maintenanceSettings = @{ Restore = @{ Time = '22:00' } } }
    $precedenceLocal = @{ 'maintenanceSettings.Restore.Time' = '01:00' }
    $precedenceResult = Resolve-BRAVORawConfiguration `
        -DefaultConfiguration $configurationDefaults `
        -PrimaryOverrides $precedencePrimary `
        -LocalOverrides $precedenceLocal
    Test-BRAVOCondition `
        -Condition (
            [string]$precedenceResult.maintenanceSettings.Restore.Time -eq '01:00' -and
            [string]$precedenceResult.maintenanceSettings.Restore.WindowStart -eq '21:00'
        ) `
        -Name "Configuration/FullPrecedenceDefaultPrimaryLocal" `
        -Failure "local override (01:00) має перемагати primary (22:00), а неперевизначені поля (WindowStart) мають зберігати built-in default"

    # --- Resolve-BRAVORawConfiguration: обидва overrides відсутні (BuiltInOnly, Test 1/9 ТЗ) ---
    $builtInOnlyResult = Resolve-BRAVORawConfiguration `
        -DefaultConfiguration $configurationDefaults `
        -PrimaryOverrides $null `
        -LocalOverrides $null
    Test-BRAVOCondition `
        -Condition (
            @($builtInOnlyResult.maintenanceSettings.Limits.ExcludedDrives).Count -eq 0 -and
            [string]$builtInOnlyResult.bravoSettings.InstitutionName -eq 'УСТАНОВА'
        ) `
        -Name "Configuration/BuiltInOnlyModeResolves" `
        -Failure "за відсутності і primary, і local overrides результат має дорівнювати built-in defaults без помилки"

    # --- Resolve-BRAVORawConfiguration: local-only (Test 4 ТЗ) ---
    $localOnlyResult = Resolve-BRAVORawConfiguration `
        -DefaultConfiguration $configurationDefaults `
        -PrimaryOverrides $null `
        -LocalOverrides @{ 'maintenanceSettings.Limits.ExcludedDrives' = @('F:\') }
    Test-BRAVOCondition `
        -Condition (
            @($localOnlyResult.maintenanceSettings.Limits.ExcludedDrives).Count -eq 1 -and
            [string]$localOnlyResult.maintenanceSettings.Limits.ExcludedDrives[0] -eq 'F:\'
        ) `
        -Name "Configuration/LocalOnlyModeApplies" `
        -Failure "local override має застосовуватись навіть без primary-шару"
