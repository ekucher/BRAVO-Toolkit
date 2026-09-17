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
        -Failure "мутація об'єкта, поверненого одним викликом Get-BRAVODefaultConfiguration, не повинна впливати на наступний виклик (спільний mutable reference)"

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

    # --- #154 (A2): невідомий ОСТАННІЙ сегмент — приймається, але видимий ---
    # Блок у дочірній області (& { ... }) через ліміт 4096 змінних на
    # область self-test (#163).
    & {
        $unknownLeafSink = New-Object 'System.Collections.Generic.List[string]'
        $unknownLeafResult = ConvertTo-BRAVONestedOverride `
            -DotPathOverrides @{ 'maintenanceSettings.Limits.MinFreeSpaceGB' = 20 } `
            -ReferenceConfiguration $configurationDefaults `
            -UnknownLeafPathSink $unknownLeafSink
        Test-BRAVOCondition `
            -Condition (
                $unknownLeafResult.maintenanceSettings.Limits.MinFreeSpaceGB -eq 20 -and
                @($unknownLeafSink).Count -eq 1 -and
                [string]$unknownLeafSink[0] -eq 'maintenanceSettings.Limits.MinFreeSpaceGB'
            ) `
            -Name 'Configuration/UnknownLeafIsAcceptedAndReported' `
            -Failure ("невідомий кінцевий сегмент має ЛИШАТИСЬ прийнятим (forward-compat) і водночас потрапляти " +
                "в UnknownLeafPathSink; отримано значення=$($unknownLeafResult.maintenanceSettings.Limits.MinFreeSpaceGB) " +
                "sink=$(@($unknownLeafSink) -join ', ')")

        # Відомий leaf не повинен потрапляти в sink — інакше попередження
        # звучало б на кожному нормальному override і його перестали б читати.
        $knownLeafSink = New-Object 'System.Collections.Generic.List[string]'
        ConvertTo-BRAVONestedOverride `
            -DotPathOverrides @{ 'maintenanceSettings.Limits.ExcludedDrives' = @('F:\') } `
            -ReferenceConfiguration $configurationDefaults `
            -UnknownLeafPathSink $knownLeafSink | Out-Null
        Test-BRAVOCondition `
            -Condition (@($knownLeafSink).Count -eq 0) `
            -Name 'Configuration/KnownLeafIsNeverReportedAsUnknown' `
            -Failure "відомий кінцевий сегмент не має потрапляти в UnknownLeafPathSink; отримано: $(@($knownLeafSink) -join ', ')"

        # Діагностика не послаблює fail-closed: невідомий БАТЬКІВСЬКИЙ вузол
        # і далі кидає виняток, і такий шлях у sink не потрапляє.
        $rejectedSink = New-Object 'System.Collections.Generic.List[string]'
        $rejectedThrew = $false
        try {
            ConvertTo-BRAVONestedOverride `
                -DotPathOverrides @{ 'maintenanceSettings.Limit.ExcludedDrives' = @() } `
                -ReferenceConfiguration $configurationDefaults `
                -UnknownLeafPathSink $rejectedSink | Out-Null
        } catch {
            $rejectedThrew = $true
        }
        Test-BRAVOCondition `
            -Condition ($rejectedThrew -and @($rejectedSink).Count -eq 0) `
            -Name 'Configuration/UnknownParentStillFailsClosedWithSink' `
            -Failure ("невідомий батьківський вузол має лишатись fail-closed навіть із переданим sink, і не " +
                "реєструватись як 'прийнятий невідомий leaf'; threw=$rejectedThrew sink=$(@($rejectedSink) -join ', ')")
    }

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

    # --- P1 security hardening (CI remediation #129): Get-BRAVOCanonicalDiscoverySettings
    # two-factor fail-closed test-only discovery override seam
    # (Assert-BRAVODiscoverySettingsTestOverride, BRAVO.Configuration.Derivation.psm1).
    # DataRestore Matrix fixture-only seam; НЕ supported production configuration.

    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Derivation.psd1') -Force

    $discoveryOverrideTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("BRAVO_DiscoveryOverrideTest_" + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $discoveryOverrideTestRoot -Force -ErrorAction Stop)
    $discoveryOverrideBeforeHooks = $env:BRAVO_DATARESTORE_TEST_HOOKS
    $discoveryOverrideBeforePath = $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH

    function Reset-BRAVODiscoveryOverrideTestEnv {
        Remove-Item -Path 'Env:\BRAVO_DATARESTORE_TEST_HOOKS' -ErrorAction SilentlyContinue
        Remove-Item -Path 'Env:\BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH' -ErrorAction SilentlyContinue
    }

    function New-BRAVODiscoveryOverrideFixturePsd1 {
        param([string]$Name, [string]$Content)
        $fixturePath = Join-Path $discoveryOverrideTestRoot $Name
        Set-Content -LiteralPath $fixturePath -Value $Content -Encoding UTF8
        return $fixturePath
    }

    $validFixtureModel = Join-Path $discoveryOverrideTestRoot 'MODEL'
    $validFixtureBlog = Join-Path $discoveryOverrideTestRoot 'BLOG'
    $validFixtureExch = Join-Path $discoveryOverrideTestRoot 'BRAVOEXCH'
    $validFixtureContent = "@{`n    BravoIniPath = `$null`n    BravoRoot = `$null`n    WebRoot = `$null`n    Sources = @{`n        MODEL = '$validFixtureModel'`n        BLOG = '$validFixtureBlog'`n        BRAVOEXCH = '$validFixtureExch'`n        BAZA_APP = `$null`n        BAZA_WWW = `$null`n        BACKUP_ROOT = `$null`n    }`n}`n"
    $validFixturePath = New-BRAVODiscoveryOverrideFixturePsd1 -Name 'valid.psd1' -Content $validFixtureContent

    try {
        # --- DiscoveryOverride/NoVariablesReturnsCanonicalSettings ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $canonicalResult = Get-BRAVOCanonicalDiscoverySettings
        Test-BRAVOCondition `
            -Condition (
                $null -eq $canonicalResult.BravoIniPath -and
                $null -eq $canonicalResult.Sources.MODEL
            ) `
            -Name "Configuration/DiscoveryOverride/NoVariablesReturnsCanonicalSettings" `
            -Failure "без обох env var Get-BRAVOCanonicalDiscoverySettings має повертати canonical null-літерал"

        # --- DiscoveryOverride/SentinelOnlyDoesNotActivateOverride ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $sentinelOnlyResult = Get-BRAVOCanonicalDiscoverySettings
        Test-BRAVOCondition `
            -Condition ($null -eq $sentinelOnlyResult.Sources.MODEL) `
            -Name "Configuration/DiscoveryOverride/SentinelOnlyDoesNotActivateOverride" `
            -Failure "сам по собі BRAVO_DATARESTORE_TEST_HOOKS без OVERRIDE_PATH не повинен нічого активувати"

        # --- DiscoveryOverride/PathWithoutSentinelFailsClosed ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = $validFixturePath
        $pathWithoutSentinelThrew = $false
        try { Get-BRAVOCanonicalDiscoverySettings | Out-Null } catch { $pathWithoutSentinelThrew = $true }
        Test-BRAVOCondition `
            -Condition $pathWithoutSentinelThrew `
            -Name "Configuration/DiscoveryOverride/PathWithoutSentinelFailsClosed" `
            -Failure "OVERRIDE_PATH без sentinel BRAVO_DATARESTORE_TEST_HOOKS=ACCEPTANCE_ONLY має fail-closed THROW, а не мовчазний canonical fallback"

        # --- DiscoveryOverride/WrongSentinelFailsClosed ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'wrong'
        $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = $validFixturePath
        $wrongSentinelThrew = $false
        try { Get-BRAVOCanonicalDiscoverySettings | Out-Null } catch { $wrongSentinelThrew = $true }
        Test-BRAVOCondition `
            -Condition $wrongSentinelThrew `
            -Name "Configuration/DiscoveryOverride/WrongSentinelFailsClosed" `
            -Failure "неточний (case/значення) sentinel має fail-closed THROW"

        # --- DiscoveryOverride/MissingFileFailsClosed ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = Join-Path $discoveryOverrideTestRoot 'missing.psd1'
        $missingFileThrew = $false
        try { Get-BRAVOCanonicalDiscoverySettings | Out-Null } catch { $missingFileThrew = $true }
        Test-BRAVOCondition `
            -Condition $missingFileThrew `
            -Name "Configuration/DiscoveryOverride/MissingFileFailsClosed" `
            -Failure "неіснуючий OVERRIDE_PATH-файл має fail-closed THROW"

        # --- DiscoveryOverride/RelativePathRejected ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = 'relative\discovery.psd1'
        $relativePathThrew = $false
        try { Get-BRAVOCanonicalDiscoverySettings | Out-Null } catch { $relativePathThrew = $true }
        Test-BRAVOCondition `
            -Condition $relativePathThrew `
            -Name "Configuration/DiscoveryOverride/RelativePathRejected" `
            -Failure "відносний OVERRIDE_PATH має fail-closed THROW"

        # --- DiscoveryOverride/UncPathRejected ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = '\\server\share\discovery.psd1'
        $uncPathThrew = $false
        try { Get-BRAVOCanonicalDiscoverySettings | Out-Null } catch { $uncPathThrew = $true }
        Test-BRAVOCondition `
            -Condition $uncPathThrew `
            -Name "Configuration/DiscoveryOverride/UncPathRejected" `
            -Failure "UNC OVERRIDE_PATH має fail-closed THROW"

        # --- DiscoveryOverride/WrongExtensionRejected ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $wrongExtPath = New-BRAVODiscoveryOverrideFixturePsd1 -Name 'wrongext.txt' -Content '@{ BravoIniPath = $null; BravoRoot = $null; WebRoot = $null; Sources = @{} }'
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = $wrongExtPath
        $wrongExtThrew = $false
        try { Get-BRAVOCanonicalDiscoverySettings | Out-Null } catch { $wrongExtThrew = $true }
        Test-BRAVOCondition `
            -Condition $wrongExtThrew `
            -Name "Configuration/DiscoveryOverride/WrongExtensionRejected" `
            -Failure "OVERRIDE_PATH не з розширенням .psd1 має fail-closed THROW"

        # --- DiscoveryOverride/InvalidPsd1Rejected ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $invalidPsd1Path = New-BRAVODiscoveryOverrideFixturePsd1 -Name 'invalid.psd1' -Content 'this is not valid restricted-language PSD1 { [ } ='
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = $invalidPsd1Path
        $invalidPsd1Threw = $false
        try { Get-BRAVOCanonicalDiscoverySettings | Out-Null } catch { $invalidPsd1Threw = $true }
        Test-BRAVOCondition `
            -Condition $invalidPsd1Threw `
            -Name "Configuration/DiscoveryOverride/InvalidPsd1Rejected" `
            -Failure "невалідний .psd1 (Import-PowerShellDataFile parse error) має fail-closed THROW"

        # --- DiscoveryOverride/UnknownTopLevelKeyRejected ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $unknownTopLevelPath = New-BRAVODiscoveryOverrideFixturePsd1 -Name 'unknown-top.psd1' -Content '@{ BravoIniPath = $null; BravoRoot = $null; WebRoot = $null; Sources = @{}; UnknownKey = "x" }'
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = $unknownTopLevelPath
        $unknownTopLevelThrew = $false
        try { Get-BRAVOCanonicalDiscoverySettings | Out-Null } catch { $unknownTopLevelThrew = $true }
        Test-BRAVOCondition `
            -Condition $unknownTopLevelThrew `
            -Name "Configuration/DiscoveryOverride/UnknownTopLevelKeyRejected" `
            -Failure "невідомий top-level ключ у .psd1 має fail-closed THROW"

        # --- DiscoveryOverride/UnknownSourceKeyRejected ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $unknownSourcePath = New-BRAVODiscoveryOverrideFixturePsd1 -Name 'unknown-source.psd1' -Content '@{ BravoIniPath = $null; BravoRoot = $null; WebRoot = $null; Sources = @{ UNKNOWN_SOURCE = $null } }'
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = $unknownSourcePath
        $unknownSourceThrew = $false
        try { Get-BRAVOCanonicalDiscoverySettings | Out-Null } catch { $unknownSourceThrew = $true }
        Test-BRAVOCondition `
            -Condition $unknownSourceThrew `
            -Name "Configuration/DiscoveryOverride/UnknownSourceKeyRejected" `
            -Failure "невідомий Sources-ключ у .psd1 має fail-closed THROW"

        # --- DiscoveryOverride/InvalidTopLevelValueTypeRejected ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $invalidTopLevelTypePath = New-BRAVODiscoveryOverrideFixturePsd1 -Name 'invalid-top-type.psd1' -Content '@{ BravoIniPath = 42; BravoRoot = $null; WebRoot = $null; Sources = @{} }'
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = $invalidTopLevelTypePath
        $invalidTopLevelTypeThrew = $false
        try { Get-BRAVOCanonicalDiscoverySettings | Out-Null } catch { $invalidTopLevelTypeThrew = $true }
        Test-BRAVOCondition `
            -Condition $invalidTopLevelTypeThrew `
            -Name "Configuration/DiscoveryOverride/InvalidTopLevelValueTypeRejected" `
            -Failure "нестроковий/не-null top-level scalar (integer) має fail-closed THROW"

        # --- DiscoveryOverride/InvalidSourceValueTypeRejected ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $invalidSourceTypePath = New-BRAVODiscoveryOverrideFixturePsd1 -Name 'invalid-source-type.psd1' -Content '@{ BravoIniPath = $null; BravoRoot = $null; WebRoot = $null; Sources = @{ MODEL = @(1,2,3) } }'
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = $invalidSourceTypePath
        $invalidSourceTypeThrew = $false
        try { Get-BRAVOCanonicalDiscoverySettings | Out-Null } catch { $invalidSourceTypeThrew = $true }
        Test-BRAVOCondition `
            -Condition $invalidSourceTypeThrew `
            -Name "Configuration/DiscoveryOverride/InvalidSourceValueTypeRejected" `
            -Failure "масив як значення Sources.MODEL має fail-closed THROW"

        # --- DiscoveryOverride/ValidFixtureAccepted ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = $validFixturePath
        $validFixtureResult = Get-BRAVOCanonicalDiscoverySettings
        Test-BRAVOCondition `
            -Condition (
                [string]$validFixtureResult.Sources.MODEL -eq $validFixtureModel -and
                [string]$validFixtureResult.Sources.BLOG -eq $validFixtureBlog -and
                [string]$validFixtureResult.Sources.BRAVOEXCH -eq $validFixtureExch
            ) `
            -Name "Configuration/DiscoveryOverride/ValidFixtureAccepted" `
            -Failure "валідний two-factor fixture .psd1 має повернути точно задані MODEL/BLOG/BRAVOEXCH шляхи"

        # --- DiscoveryOverride/DefaultBehaviorUnchangedAfterFailedTest ---
        Reset-BRAVODiscoveryOverrideTestEnv
        $afterFailedTestResult = Get-BRAVOCanonicalDiscoverySettings
        Test-BRAVOCondition `
            -Condition (
                $null -eq $afterFailedTestResult.BravoIniPath -and
                $null -eq $afterFailedTestResult.Sources.MODEL
            ) `
            -Name "Configuration/DiscoveryOverride/DefaultBehaviorUnchangedAfterFailedTest" `
            -Failure "після серії fail-closed тестів (і після env var очищено) canonical поведінка має лишатись повністю незмінною"
    } finally {
        Reset-BRAVODiscoveryOverrideTestEnv
        if ($null -ne $discoveryOverrideBeforeHooks) { $env:BRAVO_DATARESTORE_TEST_HOOKS = $discoveryOverrideBeforeHooks }
        if ($null -ne $discoveryOverrideBeforePath) { $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = $discoveryOverrideBeforePath }
        Remove-Item -LiteralPath $discoveryOverrideTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # =====================================================================
    # BRAVO.Configuration.Delta — порівняння графів (#154, задача B0)
    # =====================================================================
    # Окремий child scope (& { ... }): усі 25 фрагментів self-test
    # дот-сорсяться в ОДИН scope, і кожна змінна тут з'їдала б спільний
    # ліміт $MaximumVariableCount.
    & {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Delta.psd1') -Force

        # --- Delta/IdenticalGraphsProduceNoDifference ---
        # Найважливіший інваріант інструменту: сервер, чий BRAVO.config
        # побайтово збігається з дефолтами, мусить дати ПОРОЖНЮ дельту.
        # Інакше міграція B5 перенесла б у site-файл копію дефолтів.
        $deltaDefaults = Get-BRAVODefaultConfiguration
        $deltaSame = Get-BRAVODefaultConfiguration
        $deltaNone = @(Compare-BRAVOConfigurationGraph -ReferenceConfiguration $deltaDefaults -CandidateConfiguration $deltaSame)
        # Повідомлення про провал називає САМІ шляхи: "отримано N" не дає
        # жодної зачіпки, а порожній рядок у переліку одразу вказав би на
        # null-запис від рекурсії (див. Delta/EmptyRecursionAddsNoNullEntry).
        $deltaNonePaths = @($deltaNone | ForEach-Object { if ($null -eq $_) { '<null>' } else { [string]$_.Path } })
        Test-BRAVOCondition `
            -Condition ($deltaNone.Count -eq 0) `
            -Name "Delta/IdenticalGraphsProduceNoDifference" `
            -Failure "порівняння canonical defaults із самими собою має дати 0 відмінностей (отримано $($deltaNone.Count): $([string]::Join(', ', $deltaNonePaths)))"

        # --- Delta/EmptyAndSingleElementArraysCompareEqual ---
        # Регресія на реальний дефект (CI 2026-09-14): еталонне значення
        # діставалось через "$x = if (...) { $hash[$key] } else { $null }",
        # і присвоєння РЕЗУЛЬТАТУ statement-а розгортало колекцію —
        # порожній масив ставав $null, одноелементний ставав самим
        # елементом. Кандидат читався прямим індексуванням, тож
        # порівнювались різні ТИПИ, і кожен такий ключ давав хибну
        # "відмінність". Саме такі значення є в canonical defaults
        # (ExcludedDrives = @(), RobocopyProgressOptions = @('/ETA')).
        $deltaArrayShape = @{
            emptyArray = @()
            singleElement = @('one')
            multiElement = @('a', 'b')
            plainScalar = 'x'
        }
        $deltaArrayShapeCopy = @{
            emptyArray = @()
            singleElement = @('one')
            multiElement = @('a', 'b')
            plainScalar = 'x'
        }
        $deltaArrayShapeSame = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration $deltaArrayShape `
            -CandidateConfiguration $deltaArrayShapeCopy)
        $deltaArrayShapePaths = @($deltaArrayShapeSame | ForEach-Object { if ($null -eq $_) { '<null>' } else { [string]$_.Path } })
        # Позитивний контроль: одноелементний масив з ІНШИМ значенням
        # мусить лишатись видимою відмінністю — фікс не сміє "зрівняти все".
        $deltaArrayShapeChanged = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ singleElement = @('one') } `
            -CandidateConfiguration @{ singleElement = @('two') })
        Test-BRAVOCondition `
            -Condition (
                $deltaArrayShapeSame.Count -eq 0 -and
                $deltaArrayShapeChanged.Count -eq 1
            ) `
            -Name "Delta/EmptyAndSingleElementArraysCompareEqual" `
            -Failure "порожній і одноелементний масиви з однаковим вмістом мусять бути РІВНИМИ, а зміна значення — видимою: однакові дали $($deltaArrayShapeSame.Count) ($([string]::Join(', ', $deltaArrayShapePaths))), змінений дав $($deltaArrayShapeChanged.Count)"

        # --- Delta/EmptyRecursionAddsNoNullEntry ---
        # Регресія на реальний дефект (CI 2026-09-14): рекурсія у вузол БЕЗ
        # відмінностей повертала порожній масив, який PowerShell розгортає
        # в $null, а @($null) — це масив з ОДНИМ елементом. Кожен такий
        # вузол додавав порожній запис у результат. Тут два вкладені блоки
        # без відмінностей і рівно одна справжня зміна.
        $deltaNullProbe = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{
                quiet1 = @{ a = 'x'; b = 'y' }
                quiet2 = @{ c = @{ d = 'z' } }
                loud = @{ value = 'before' }
            } `
            -CandidateConfiguration @{
                quiet1 = @{ a = 'x'; b = 'y' }
                quiet2 = @{ c = @{ d = 'z' } }
                loud = @{ value = 'after' }
            })
        Test-BRAVOCondition `
            -Condition (
                $deltaNullProbe.Count -eq 1 -and
                $null -ne $deltaNullProbe[0] -and
                [string]$deltaNullProbe[0].Path -eq 'loud.value'
            ) `
            -Name "Delta/EmptyRecursionAddsNoNullEntry" `
            -Failure "рекурсія у вузли без відмінностей не сміє додавати порожні (`$null) записи: очікувався рівно один результат 'loud.value', отримано $($deltaNullProbe.Count)"

        # --- Delta/ChangedLeafReportedWithDotPath ---
        $deltaReference = @{ pathSettings = @{ BackupRoot = 'E:\ARCHIV'; StateRoot = 'C:\State' } }
        $deltaCandidate = @{ pathSettings = @{ BackupRoot = 'E:\ARCHIV_LIMS'; StateRoot = 'C:\State' } }
        $deltaChanged = @(Compare-BRAVOConfigurationGraph -ReferenceConfiguration $deltaReference -CandidateConfiguration $deltaCandidate)
        Test-BRAVOCondition `
            -Condition (
                $deltaChanged.Count -eq 1 -and
                [string]$deltaChanged[0].Path -eq 'pathSettings.BackupRoot' -and
                [string]$deltaChanged[0].Kind -eq 'Changed' -and
                [string]$deltaChanged[0].CandidateValue -eq 'E:\ARCHIV_LIMS'
            ) `
            -Name "Delta/ChangedLeafReportedWithDotPath" `
            -Failure "змінений лист має повертатись рівно один раз як Changed з dot-path 'pathSettings.BackupRoot'"

        # --- Delta/StringComparisonIsCaseSensitive ---
        # 'E:\ARCHIV' і 'e:\archiv' — та сама тека, але РІЗНИЙ site-запис:
        # оператор мусить бачити, що на сервері значення записане інакше.
        $deltaCaseChanged = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ pathSettings = @{ BackupRoot = 'E:\ARCHIV' } } `
            -CandidateConfiguration @{ pathSettings = @{ BackupRoot = 'e:\archiv' } })
        Test-BRAVOCondition `
            -Condition ($deltaCaseChanged.Count -eq 1) `
            -Name "Delta/StringComparisonIsCaseSensitive" `
            -Failure "різниця лише в регістрі рядка має бути ВИДИМОЮ відмінністю"

        # --- Delta/ArrayComparedElementWiseNotFiltered ---
        # Класична пастка Windows PowerShell 5.1: -eq з масивом ліворуч
        # ФІЛЬТРУЄ й повертає підмножину замість булевого значення. Якби
        # порівняння було через -eq, підмножина @('/E') проти @('/E','/R:3')
        # дала б "рівні" й дельта мовчки загубила б site-значення.
        $deltaArraySubset = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ robocopyOptions = @('/E', '/R:3') } `
            -CandidateConfiguration @{ robocopyOptions = @('/E') })
        $deltaArrayOrder = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ robocopyOptions = @('/E', '/R:3') } `
            -CandidateConfiguration @{ robocopyOptions = @('/R:3', '/E') })
        $deltaArrayEqual = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ robocopyOptions = @('/E', '/R:3') } `
            -CandidateConfiguration @{ robocopyOptions = @('/E', '/R:3') })
        Test-BRAVOCondition `
            -Condition (
                $deltaArraySubset.Count -eq 1 -and
                $deltaArrayOrder.Count -eq 1 -and
                $deltaArrayEqual.Count -eq 0
            ) `
            -Name "Delta/ArrayComparedElementWiseNotFiltered" `
            -Failure "масиви мусять порівнюватись поелементно: підмножина й інший порядок = відмінність, ідентичний масив = ні (отримано $($deltaArraySubset.Count)/$($deltaArrayOrder.Count)/$($deltaArrayEqual.Count))"

        # --- Delta/UnknownNestedKeyReportedAsOnlyInCandidate ---
        # Саме ця гілка робить видимою знахідку F1 (#154): вкладений ключ,
        # якого немає в канонічних дефолтах, сьогодні зливається МОВЧКИ.
        $deltaUnknown = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ pathSettings = @{ BackupRoot = 'E:\ARCHIV' } } `
            -CandidateConfiguration @{ pathSettings = @{ BackupRoot = 'E:\ARCHIV'; LegacyRoot = 'D:\OLD' } })
        Test-BRAVOCondition `
            -Condition (
                $deltaUnknown.Count -eq 1 -and
                [string]$deltaUnknown[0].Path -eq 'pathSettings.LegacyRoot' -and
                [string]$deltaUnknown[0].Kind -eq 'OnlyInCandidate'
            ) `
            -Name "Delta/UnknownNestedKeyReportedAsOnlyInCandidate" `
            -Failure "невідомий канонічним дефолтам вкладений ключ має повертатись як OnlyInCandidate"

        # --- Delta/UnknownNodeExpandedToLeafPaths ---
        # Оператору потрібен конкретний dot-path, а не "десь у цьому блоці
        # щось є": невідомий БЛОК розкривається до листів.
        $deltaUnknownNode = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ pathSettings = @{ BackupRoot = 'E:\ARCHIV' } } `
            -CandidateConfiguration @{ pathSettings = @{ BackupRoot = 'E:\ARCHIV'; Legacy = @{ Root = 'D:\OLD'; Mode = 'Off' } } })
        $deltaUnknownNodePaths = @($deltaUnknownNode | ForEach-Object { [string]$_.Path })
        Test-BRAVOCondition `
            -Condition (
                $deltaUnknownNode.Count -eq 2 -and
                $deltaUnknownNodePaths -contains 'pathSettings.Legacy.Mode' -and
                $deltaUnknownNodePaths -contains 'pathSettings.Legacy.Root'
            ) `
            -Name "Delta/UnknownNodeExpandedToLeafPaths" `
            -Failure "невідомий вкладений БЛОК має розкриватись до листових dot-path, а не повертатись одним вузлом"

        # --- Delta/ShapeChangeReportedNotRecursed ---
        $deltaShape = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ smbSettings = @{ RootPath = '' } } `
            -CandidateConfiguration @{ smbSettings = 'ВИМКНЕНО' })
        Test-BRAVOCondition `
            -Condition (
                $deltaShape.Count -eq 1 -and
                [string]$deltaShape[0].Path -eq 'smbSettings' -and
                [string]$deltaShape[0].Kind -eq 'Changed'
            ) `
            -Name "Delta/ShapeChangeReportedNotRecursed" `
            -Failure "скаляр там, де еталон має блок, має повертатись одним Changed по шляху самого блоку"

        # --- Delta/MissingInCandidateRequiresExplicitSwitch ---
        # Для питання "що перевизначено на цьому сервері" відсутність ключа
        # означає "діє дефолт", а не відмінність — інакше дельта містила б
        # увесь канонічний граф.
        $deltaMissingDefault = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ pathSettings = @{ BackupRoot = 'E:\ARCHIV'; StateRoot = 'C:\State' } } `
            -CandidateConfiguration @{ pathSettings = @{ BackupRoot = 'E:\ARCHIV' } })
        $deltaMissingExplicit = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ pathSettings = @{ BackupRoot = 'E:\ARCHIV'; StateRoot = 'C:\State' } } `
            -CandidateConfiguration @{ pathSettings = @{ BackupRoot = 'E:\ARCHIV' } } `
            -IncludeMissingInCandidate)
        Test-BRAVOCondition `
            -Condition (
                $deltaMissingDefault.Count -eq 0 -and
                $deltaMissingExplicit.Count -eq 1 -and
                [string]$deltaMissingExplicit[0].Kind -eq 'OnlyInReference' -and
                [string]$deltaMissingExplicit[0].Path -eq 'pathSettings.StateRoot'
            ) `
            -Name "Delta/MissingInCandidateRequiresExplicitSwitch" `
            -Failure "відсутній у кандидаті ключ має з'являтись ЛИШЕ з -IncludeMissingInCandidate"

        # --- Delta/OutputOrderIsDeterministic ---
        # Два прогони на тому самому сервері мусять давати однаковий вивід,
        # інакше порівняти дельти між собою неможливо (порядок ключів
        # hashtable у PowerShell не визначений).
        $deltaOrderSource = @{ zebra = 'z'; alpha = 'a'; middle = 'm' }
        $deltaOrderFirst = @(Compare-BRAVOConfigurationGraph -ReferenceConfiguration @{} -CandidateConfiguration $deltaOrderSource | ForEach-Object { [string]$_.Path })
        $deltaOrderSecond = @(Compare-BRAVOConfigurationGraph -ReferenceConfiguration @{} -CandidateConfiguration $deltaOrderSource | ForEach-Object { [string]$_.Path })
        Test-BRAVOCondition `
            -Condition (
                ([string]::Join('|', $deltaOrderFirst)) -eq 'alpha|middle|zebra' -and
                ([string]::Join('|', $deltaOrderSecond)) -eq 'alpha|middle|zebra'
            ) `
            -Name "Delta/OutputOrderIsDeterministic" `
            -Failure "вивід має бути відсортованим за Path і однаковим між прогонами (отримано '$([string]::Join('|', $deltaOrderFirst))')"

        # --- Delta/SiteDeltaToolReusesCanonicalPrimaryReader ---
        # Архітектурний guard: інструмент дельти НЕ сміє мати власної копії
        # "виконати BRAVO.config і зібрати $global:" — це політика того, що
        # комплект приймає від primary-шару, і вона має один екземпляр
        # (Read-BRAVOLegacyPrimaryRawOverrides у BRAVO_CONFIG_LOADER.ps1).
        $deltaToolPath = Join-Path $root 'deploy\Get-BRAVOConfigSiteDelta.ps1'
        $deltaToolText = [IO.File]::ReadAllText($deltaToolPath, [Text.Encoding]::UTF8)
        Test-BRAVOCondition `
            -Condition (
                $deltaToolText.Contains('Read-BRAVOLegacyPrimaryRawOverrides') -and
                -not $deltaToolText.Contains('[scriptblock]::Create')
            ) `
            -Name "Delta/SiteDeltaToolReusesCanonicalPrimaryReader" `
            -Failure "deploy\Get-BRAVOConfigSiteDelta.ps1 мусить читати primary-шар через Read-BRAVOLegacyPrimaryRawOverrides і не містити власного [scriptblock]::Create"

        # --- Delta/SiteDeltaToolNeverOverwrites ---
        # Операторський інструмент на production-сервері: єдиний запис —
        # явний -OutputPath, і наявний файл за ним не перезаписується.
        Test-BRAVOCondition `
            -Condition (
                $deltaToolText.Contains('уже існує — інструмент нічого не перезаписує') -and
                ([regex]::Matches($deltaToolText, 'Set-Content').Count -eq 1)
            ) `
            -Name "Delta/SiteDeltaToolNeverOverwrites" `
            -Failure "інструмент дельти мусить мати рівно один запис на диск (за -OutputPath) і відмовляти на наявному файлі"
    }

# =====================================================================
# BRAVO.Configuration.DataFile — невиконуючий парсер site-файлу
# (#154, задача B1)
# =====================================================================
# Окремий child scope (& { ... }) з тієї ж причини, що й блок Delta вище:
# усі фрагменти self-test дот-сорсяться в ОДИН scope і ділять спільний
# $MaximumVariableCount.
& {
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.DataFile.psd1') -Force

    # Спільний предикат "цей вміст МУСИТЬ бути відхилений". Окрема
    # функція, а не 12 копій try/catch: кожна копія з'їдала б змінні
    # спільного scope і ховала б, який саме випадок упав.
    function Test-BRAVODataFileRejected {
        param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body)
        try {
            [void](ConvertFrom-BRAVOConfigurationDataFileText -Text $Body -SourceName 'selftest')
            return $false
        } catch {
            return $true
        }
    }

    # --- DataFile/AcceptsCanonicalSiteFileShape ---
    # Усі форми значень, які реально генерує
    # ConvertTo-BRAVOConfiguratorPowerShellLiteral, плюс коментарі й
    # порожні рядки навколо них.
    $dataFileAccepted = ConvertFrom-BRAVOConfigurationDataFileText -SourceName 'selftest' -Text @'
# Згенеровано BRAVO Configurator.

@{
    'pathSettings.BackupRoot' = 'E:\ARCHIV_LIMS'
    'bravoSettings.InstitutionName' = 'МОЯ УСТАНОВА'
    'bravoSettings.NotificationRequestTimeoutSeconds' = 30
    'maintenanceSettings.Limits.MaximumMdFileSizeGB' = 1.5
    'maintenanceSettings.Services.BravoWebEnabled' = $true
    'hostInformationSettings.PublicIPLookupEnabled' = $false
    'componentSettings.SFTP.Enabled' = $null
    'maintenanceSettings.Services.BravoDisplayName' = @('BRAVO Service', 'BRAVO Server')
    'maintenanceSettings.Limits.ExcludedDrives' = @()
}
'@
    Test-BRAVOCondition `
        -Condition (
            $dataFileAccepted -is [hashtable] -and
            $dataFileAccepted.Count -eq 9 -and
            [string]$dataFileAccepted['pathSettings.BackupRoot'] -ceq 'E:\ARCHIV_LIMS' -and
            [string]$dataFileAccepted['bravoSettings.InstitutionName'] -ceq 'МОЯ УСТАНОВА' -and
            $dataFileAccepted['bravoSettings.NotificationRequestTimeoutSeconds'] -eq 30 -and
            $dataFileAccepted['maintenanceSettings.Limits.MaximumMdFileSizeGB'] -eq 1.5 -and
            $dataFileAccepted['maintenanceSettings.Services.BravoWebEnabled'] -eq $true -and
            $dataFileAccepted['hostInformationSettings.PublicIPLookupEnabled'] -eq $false -and
            $null -eq $dataFileAccepted['componentSettings.SFTP.Enabled'] -and
            @($dataFileAccepted['maintenanceSettings.Services.BravoDisplayName']).Count -eq 2
        ) `
        -Name "DataFile/AcceptsCanonicalSiteFileShape" `
        -Failure "канонічна форма site-файлу (рядки, числа, `$true/`$false/`$null, масиви, коментарі) мусить вилучатись без виконання; отримано ключів: $(if ($dataFileAccepted -is [hashtable]) { $dataFileAccepted.Count } else { 'не hashtable' })"

    # --- DataFile/EmptyArrayStaysEmptyArray ---
    # PowerShell 5.1: результат функції проходить через output pipeline,
    # який РОЗГОРТАЄ колекції — прямий `return @()` став би $null, і
    # порожній ExcludedDrives мовчки перетворився б на «значення не
    # задано». Саме тому вилучення значень іде через обгортку.
    $dataFileEmptyArray = ConvertFrom-BRAVOConfigurationDataFileText -SourceName 'selftest' `
        -Text "@{ 'a' = @(); 'b' = @('one') }"
    Test-BRAVOCondition `
        -Condition (
            $null -ne $dataFileEmptyArray['a'] -and
            $dataFileEmptyArray['a'] -is [array] -and
            @($dataFileEmptyArray['a']).Count -eq 0 -and
            $dataFileEmptyArray['b'] -is [array] -and
            @($dataFileEmptyArray['b']).Count -eq 1
        ) `
        -Name "DataFile/EmptyArrayStaysEmptyArray" `
        -Failure "@() мусить лишитись ПОРОЖНІМ МАСИВОМ (не `$null), а @('one') — масивом з одного елемента (не рядком)"

    # --- DataFile/RejectsArithmeticExpression ---
    # Головна відмінність від попереднього механізму: обмежена мова даних
    # PowerShell приймала арифметику, а перевірений блок ПОТІМ
    # виконувався — тобто 1 + 1 обчислювалось у 2. Тепер це відмова.
    Test-BRAVOCondition `
        -Condition (Test-BRAVODataFileRejected -Body "@{ 'a' = 1 + 1 }") `
        -Name "DataFile/RejectsArithmeticExpression" `
        -Failure "арифметичний вираз у значенні мусить відхилятись (у файлі даних не може бути обчислень)"

    # --- DataFile/RejectsRangeExpression ---
    Test-BRAVOCondition `
        -Condition (Test-BRAVODataFileRejected -Body "@{ 'a' = 1..3 }") `
        -Name "DataFile/RejectsRangeExpression" `
        -Failure "діапазон 1..3 мусить відхилятись — це обчислення, а не літерал"

    # --- DataFile/RejectsCommandInvocation ---
    Test-BRAVOCondition `
        -Condition (Test-BRAVODataFileRejected -Body "@{ 'a' = (Get-Date).ToString() }") `
        -Name "DataFile/RejectsCommandInvocation" `
        -Failure "виклик команди мусить відхилятись"

    # --- DataFile/RejectsEnvironmentAndScopedVariables ---
    # Три різні форми звернення до стану сесії/середовища; жодна не є
    # даними. `$global:true` — навмисно схожий на дозволену константу:
    # розпізнавання йде за ТОЧНИМ UserPath, який зберігає префікс області.
    Test-BRAVOCondition `
        -Condition (
            (Test-BRAVODataFileRejected -Body "@{ 'a' = `$env:PATH }") -and
            (Test-BRAVODataFileRejected -Body "@{ 'a' = `$global:bravoSettings }") -and
            (Test-BRAVODataFileRejected -Body "@{ 'a' = `$global:true }") -and
            (Test-BRAVODataFileRejected -Body "@{ 'a' = `$someVariable }")
        ) `
        -Name "DataFile/RejectsEnvironmentAndScopedVariables" `
        -Failure "`$env:, `$global:, `$global:true і довільна `$змінна мусять відхилятись — дозволені лише `$true/`$false/`$null"

    # --- DataFile/RejectsMemberAccessCastAndSubExpression ---
    Test-BRAVOCondition `
        -Condition (
            (Test-BRAVODataFileRejected -Body "@{ 'a' = 'x'.Length }") -and
            (Test-BRAVODataFileRejected -Body "@{ 'a' = [int]'5' }") -and
            (Test-BRAVODataFileRejected -Body "@{ 'a' = `$('x') }") -and
            (Test-BRAVODataFileRejected -Body "@{ 'a' = { 'x' } }")
        ) `
        -Name "DataFile/RejectsMemberAccessCastAndSubExpression" `
        -Failure "доступ до члена, приведення типу, підвираз і scriptblock мусять відхилятись"

    # --- DataFile/RejectsInterpolatedString ---
    Test-BRAVOCondition `
        -Condition (Test-BRAVODataFileRejected -Body "@{ 'a' = `"prefix`$env:PATH`" }") `
        -Name "DataFile/RejectsInterpolatedString" `
        -Failure "рядок з підстановкою мусить відхилятись — підстановка читає стан середовища"

    # --- DataFile/RejectsScriptShape ---
    # Файл даних не має param()/begin/process і не містить другої
    # інструкції поряд з hashtable.
    Test-BRAVOCondition `
        -Condition (
            (Test-BRAVODataFileRejected -Body "param(`$x)`r`n@{ 'a' = 1 }") -and
            (Test-BRAVODataFileRejected -Body "@{ 'a' = 1 }`r`n'друга інструкція'") -and
            (Test-BRAVODataFileRejected -Body "'не hashtable'") -and
            (Test-BRAVODataFileRejected -Body '')
        ) `
        -Name "DataFile/RejectsScriptShape" `
        -Failure "param(), друга інструкція, не-hashtable верхній рівень і порожній вміст мусять відхилятись"

    # --- DataFile/RejectsDuplicateAndEmptyKeys ---
    # Повторний ключ раніше відхиляв САМ PowerShell під час виконання
    # блока. Виконання більше немає — перевірка мусить жити в парсері,
    # інакше дублікат мовчки перезаписував би попереднє значення.
    Test-BRAVOCondition `
        -Condition (
            (Test-BRAVODataFileRejected -Body "@{ 'a' = 1; 'A' = 2 }") -and
            (Test-BRAVODataFileRejected -Body "@{ '' = 1 }")
        ) `
        -Name "DataFile/RejectsDuplicateAndEmptyKeys" `
        -Failure "повторний ключ (регістронезалежно) і порожній ключ мусять відхилятись"

    # --- DataFile/AcceptsSignedNumber ---
    # Знак перед числовою константою — форма запису ЧИСЛА, а не
    # обчислення: PowerShell залежно від контексту розбирає -5 і як
    # константу, і як унарний вираз, тому дозволено явно.
    $dataFileSigned = ConvertFrom-BRAVOConfigurationDataFileText -SourceName 'selftest' `
        -Text "@{ 'a' = -5; 'b' = +7 }"
    Test-BRAVOCondition `
        -Condition ($dataFileSigned['a'] -eq -5 -and $dataFileSigned['b'] -eq 7) `
        -Name "DataFile/AcceptsSignedNumber" `
        -Failure "від'ємне/додатне число мусить вилучатись як число; отримано a=$($dataFileSigned['a']) b=$($dataFileSigned['b'])"

    # --- DataFile/NestedHashtableExtracted ---
    $dataFileNested = ConvertFrom-BRAVOConfigurationDataFileText -SourceName 'selftest' `
        -Text "@{ 'a' = @{ 'inner' = 'value' } }"
    Test-BRAVOCondition `
        -Condition (
            $dataFileNested['a'] -is [hashtable] -and
            [string]$dataFileNested['a']['inner'] -ceq 'value'
        ) `
        -Name "DataFile/NestedHashtableExtracted" `
        -Failure "вкладений hashtable-літерал мусить вилучатись як дані"

    # --- DataFile/LoaderNoLongerInvokesSiteFile ---
    # Архітектурний guard: canonical читач site-файлу не сміє повернутись
    # до «перевірити, потім виконати». Текстова перевірка тут доречна саме
    # тому, що поведінкові тести вище доводять ВІДМОВУ, але не довели б
    # відсутність виклику, якби хтось додав його поряд.
    $dataFileLoaderText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_CONFIG_LOADER.ps1'), [Text.Encoding]::UTF8)
    Test-BRAVOCondition `
        -Condition (
            $dataFileLoaderText.Contains('ConvertFrom-BRAVOConfigurationDataFileText') -and
            -not $dataFileLoaderText.Contains('$localOverrideScript')
        ) `
        -Name "DataFile/LoaderNoLongerInvokesSiteFile" `
        -Failure "Read-BRAVOLocalConfigurationOverrides мусить вилучати дані через ConvertFrom-BRAVOConfigurationDataFileText і не створювати/не викликати scriptblock site-файлу"
}

# =============================================================
# #158 (етап 4): discovery overrides застосовуються ДО discovery
# =============================================================
# Перевіряється ВЕСЬ ланцюг, а не лише одна функція: flat dot-path з
# BRAVO.local.config -> Resolve-BRAVORawConfiguration (фаза мерджу) ->
# Resolve-BRAVOEffectiveDiscoverySettings (валідація/нормалізація) ->
# Resolve-BRAVOInstallationDiscovery (фактичне discovery). Саме розрив
# у цьому ланцюгу й був дефектом: раніше loader безумовно перезаписував
# змерджене значення канонічним літералом.
& {
    if (-not (Get-Module -Name 'BRAVO.Discovery')) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Discovery\BRAVO.Discovery.psd1') -ErrorAction Stop
    }

    $preloadSavedOverridePath = $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH
    $preloadSavedHooks = $env:BRAVO_DATARESTORE_TEST_HOOKS
    $preloadRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_DISCOVERY_PRELOAD_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        # Env-seam має бути вимкнений: він навмисно має ВИЩИЙ пріоритет за
        # site-конфіг, тож активний seam знецінив би всі перевірки нижче.
        $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = ''
        $env:BRAVO_DATARESTORE_TEST_HOOKS = ''

        [void][IO.Directory]::CreateDirectory($preloadRoot)
        function New-BRAVOPreloadDirectory {
            param([string]$Path)
            [void][IO.Directory]::CreateDirectory($Path)
            [IO.File]::WriteAllText((Join-Path $Path 'fixture.txt'), 'x', (New-Object Text.UTF8Encoding($false)))
            return $Path
        }

        # Інсталяція, яку знаходить AUTO-discovery (служба + системний bravo.ini).
        $preloadAutoInstall = Join-Path $preloadRoot 'auto-install'
        $preloadAutoModel = New-BRAVOPreloadDirectory -Path (Join-Path $preloadAutoInstall 'Model')
        $preloadAutoBlog = New-BRAVOPreloadDirectory -Path (Join-Path $preloadAutoInstall 'BLOG')
        $preloadAutoExe = Join-Path $preloadAutoInstall 'bravo.exe'
        [IO.File]::WriteAllText($preloadAutoExe, 'stub')

        # Інсталяція, на яку вказує ЯВНИЙ site-override — інша, ніж AUTO.
        $preloadExplicitInstall = Join-Path $preloadRoot 'explicit-install'
        $preloadExplicitModel = New-BRAVOPreloadDirectory -Path (Join-Path $preloadExplicitInstall 'Model')
        [void](New-BRAVOPreloadDirectory -Path $preloadExplicitInstall)
        $preloadExplicitWebRoot = New-BRAVOPreloadDirectory -Path (Join-Path $preloadRoot 'explicit-web')

        $preloadSystemRoot = Join-Path $preloadRoot 'FixtureWindows'
        $preloadSystemIni = Join-Path $preloadSystemRoot 'SysWOW64\bravo.ini'
        [void][IO.Directory]::CreateDirectory((Split-Path -Path $preloadSystemIni -Parent))
        [IO.File]::WriteAllLines($preloadSystemIni, @(
            '[model]',
            ("MODEL={0}" -f (Join-Path $preloadAutoModel 'lims')),
            ("BLOG={0}\" -f $preloadAutoBlog)
        ))

        # Альтернативний bravo.ini, який видно ЛИШЕ через явний BravoIniPath.
        $preloadCustomIni = Join-Path (New-BRAVOPreloadDirectory -Path (Join-Path $preloadRoot 'custom-ini')) 'bravo.ini'
        [IO.File]::WriteAllLines($preloadCustomIni, @(
            '[model]',
            ("MODEL={0}" -f (Join-Path $preloadExplicitModel 'lims'))
        ))

        $preloadServices = @(
            [pscustomobject]@{ Name = 'BRAVO'; DisplayName = 'BRAVO Service'; State = 'Running'; StartMode = 'Auto'; PathName = ('"{0}"' -f $preloadAutoExe) }
        )

        # Повний ланцюг "як у loader-і", але без самого loader-а: саме так
        # site-конфіг доходить до discovery у production.
        function Resolve-BRAVOPreloadDiscovery {
            param([hashtable]$LocalOverrides, [object[]]$Services)
            $merged = Resolve-BRAVORawConfiguration `
                -DefaultConfiguration (Get-BRAVODefaultConfiguration) `
                -PrimaryOverrides $null `
                -LocalOverrides $LocalOverrides
            $effectiveDiscoverySettings = Resolve-BRAVOEffectiveDiscoverySettings `
                -CanonicalBase (Get-BRAVOCanonicalDiscoverySettings) `
                -SiteOverrides $merged['discoverySettings']
            return Resolve-BRAVOInstallationDiscovery `
                -LimsRoot $preloadAutoInstall `
                -BravoServiceName 'BRAVO' `
                -WebServiceCandidates @('Apache2.4') `
                -Services $Services `
                -SystemRoot $preloadSystemRoot `
                -Is64BitOperatingSystem $true `
                -DiscoverySettings $effectiveDiscoverySettings
        }

        # --- DiscoveryOverride/ModelSourceAffectsDiscovery ---
        # bravo.ini оголошує MODEL в auto-інсталяції; site-override вказує
        # на іншу. Раніше override сюди просто не доходив.
        $preloadModelOverride = Resolve-BRAVOPreloadDiscovery `
            -LocalOverrides @{ 'discoverySettings.Sources.MODEL' = $preloadExplicitModel } `
            -Services $preloadServices
        Test-BRAVOCondition `
            -Condition (
                [string]$preloadModelOverride.MODEL_SOURCE -eq $preloadExplicitModel -and
                [bool]$preloadModelOverride.Overrides['MODEL'] -and
                [string]$preloadModelOverride.Reasons.MODEL -match '(?i)override'
            ) `
            -Name "DiscoveryOverride/ModelSourceAffectsDiscovery" `
            -Failure "discoverySettings.Sources.MODEL з BRAVO.local.config має доходити до discovery і давати MODEL_SOURCE з override, а не з bravo.ini"

        # --- DiscoveryOverride/BravoRootAffectsDiscovery ---
        $preloadBravoRootOverride = Resolve-BRAVOPreloadDiscovery `
            -LocalOverrides @{ 'discoverySettings.BravoRoot' = $preloadExplicitInstall } `
            -Services $preloadServices
        Test-BRAVOCondition `
            -Condition (
                [string]$preloadBravoRootOverride.BRAVO_ROOT -eq $preloadExplicitInstall -and
                [bool]$preloadBravoRootOverride.Overrides['BravoRoot']
            ) `
            -Name "DiscoveryOverride/BravoRootAffectsDiscovery" `
            -Failure "discoverySettings.BravoRoot з BRAVO.local.config має визначати BRAVO_ROOT"

        # --- DiscoveryOverride/WebRootAffectsDiscovery ---
        $preloadWebRootOverride = Resolve-BRAVOPreloadDiscovery `
            -LocalOverrides @{ 'discoverySettings.WebRoot' = $preloadExplicitWebRoot } `
            -Services $preloadServices
        Test-BRAVOCondition `
            -Condition (
                [string]$preloadWebRootOverride.WEB_ROOT -eq $preloadExplicitWebRoot -and
                [bool]$preloadWebRootOverride.Overrides['WebRoot']
            ) `
            -Name "DiscoveryOverride/WebRootAffectsDiscovery" `
            -Failure "discoverySettings.WebRoot з BRAVO.local.config має визначати WEB_ROOT"

        # --- DiscoveryOverride/BravoIniPathAffectsDiscovery ---
        # Найсильніший доказ, що override діє ДО discovery: змінюється не
        # готове значення, а сам ФАЙЛ, з якого discovery читає джерела.
        $preloadIniOverride = Resolve-BRAVOPreloadDiscovery `
            -LocalOverrides @{ 'discoverySettings.BravoIniPath' = $preloadCustomIni } `
            -Services $preloadServices
        Test-BRAVOCondition `
            -Condition (
                [string]$preloadIniOverride.BravoIniPath -eq $preloadCustomIni -and
                [string]$preloadIniOverride.MODEL_SOURCE -eq $preloadExplicitModel -and
                [bool]$preloadIniOverride.Overrides['BravoIniPath']
            ) `
            -Name "DiscoveryOverride/BravoIniPathAffectsDiscovery" `
            -Failure "discoverySettings.BravoIniPath має підмінити сам файл bravo.ini, з якого discovery читає MODEL/BLOG"

        # --- DiscoveryOverride/ExplicitOverrideWins ---
        # Служба BRAVO присутня й однозначна — auto-discovery дало б
        # auto-інсталяцію. Явне значення все одно перемагає.
        $preloadAutoOnly = Resolve-BRAVOPreloadDiscovery -LocalOverrides @{} -Services $preloadServices
        Test-BRAVOCondition `
            -Condition (
                [string]$preloadAutoOnly.BRAVO_ROOT -eq $preloadAutoInstall -and
                [string]$preloadBravoRootOverride.BRAVO_ROOT -eq $preloadExplicitInstall
            ) `
            -Name "DiscoveryOverride/ExplicitOverrideWins" `
            -Failure "за наявної однозначної служби BRAVO auto-discovery дає auto-каталог, але явний discoverySettings.BravoRoot мусить його перемагати"

        # --- DiscoveryOverride/AutoDiscoveryNeverOverwritesExplicit ---
        # Override одного поля не вимикає auto-discovery для сусідніх і не
        # перезаписується ним: MODEL з override, BLOG і далі з bravo.ini.
        Test-BRAVOCondition `
            -Condition (
                [string]$preloadModelOverride.MODEL_SOURCE -eq $preloadExplicitModel -and
                [string]$preloadModelOverride.BLOG_SOURCE -eq $preloadAutoBlog -and
                -not $preloadModelOverride.Overrides.Contains('BLOG')
            ) `
            -Name "DiscoveryOverride/AutoDiscoveryNeverOverwritesExplicit" `
            -Failure "явне значення не має перезаписуватись автоматично знайденим, а сусідні поля мають лишатись на auto-discovery"

        # --- DiscoveryOverride/UnknownParentStillFailsClosed ---
        $preloadUnknownParentThrew = $false
        try {
            [void](Resolve-BRAVORawConfiguration `
                -DefaultConfiguration (Get-BRAVODefaultConfiguration) `
                -PrimaryOverrides $null `
                -LocalOverrides @{ 'discoverySettingsTypo.BravoRoot' = 'C:\BRAVO' })
        } catch {
            $preloadUnknownParentThrew = $true
        }
        Test-BRAVOCondition `
            -Condition $preloadUnknownParentThrew `
            -Name "DiscoveryOverride/UnknownParentStillFailsClosed" `
            -Failure "невідомий батьківський/top-level ключ мусить лишатись fail-closed — контракт конфігурації не послаблюється тим, що discoverySettings став raw-блоком"

        # --- DiscoveryOverride/UnknownLeafContractUnchanged ---
        # Рішення D3: невідомий LEAF приймається з попередженням і
        # метаданими, не валить запуск і не має ефекту.
        $preloadUnknownLeafSink = New-Object System.Collections.Generic.List[string]
        $preloadUnknownLeafThrew = $false
        $preloadUnknownLeafMerged = $null
        try {
            $preloadUnknownLeafMerged = Resolve-BRAVORawConfiguration `
                -DefaultConfiguration (Get-BRAVODefaultConfiguration) `
                -PrimaryOverrides $null `
                -LocalOverrides @{ 'discoverySettings.Sources.TYPO' = 'C:\BRAVO' } `
                -UnknownLeafPathSink $preloadUnknownLeafSink
        } catch {
            $preloadUnknownLeafThrew = $true
        }
        $preloadUnknownLeafEffective = $null
        if (-not $preloadUnknownLeafThrew) {
            $preloadUnknownLeafEffective = Resolve-BRAVOEffectiveDiscoverySettings `
                -CanonicalBase (Get-BRAVOCanonicalDiscoverySettings) `
                -SiteOverrides $preloadUnknownLeafMerged['discoverySettings']
        }
        Test-BRAVOCondition `
            -Condition (
                -not $preloadUnknownLeafThrew -and
                @($preloadUnknownLeafSink) -contains 'discoverySettings.Sources.TYPO' -and
                $null -ne $preloadUnknownLeafEffective -and
                -not $preloadUnknownLeafEffective['Sources'].Contains('TYPO')
            ) `
            -Name "DiscoveryOverride/UnknownLeafContractUnchanged" `
            -Failure "невідомий leaf під discoverySettings має прийматись (D3: accept + warning + metadata), потрапляти в UnknownLeafPathSink і не мати ефекту — а не валити запуск"

        # --- DiscoveryOverride/EmptyStringIsNotAnOverride ---
        # Закоментований-і-повернений порожній ключ не має мовчки вимикати
        # auto-discovery.
        $preloadEmptyOverride = Resolve-BRAVOPreloadDiscovery `
            -LocalOverrides @{ 'discoverySettings.BravoRoot' = '' } `
            -Services $preloadServices
        Test-BRAVOCondition `
            -Condition (
                [string]$preloadEmptyOverride.BRAVO_ROOT -eq $preloadAutoInstall -and
                -not $preloadEmptyOverride.Overrides.Contains('BravoRoot')
            ) `
            -Name "DiscoveryOverride/EmptyStringIsNotAnOverride" `
            -Failure "порожній рядок у discoverySettings має означати 'не задано' (auto-discovery), а не явне порожнє значення"

        # --- DiscoveryOverride/NonLocalPathFailsClosed ---
        $preloadUncThrew = $false
        try {
            [void](Resolve-BRAVOEffectiveDiscoverySettings `
                -CanonicalBase (Get-BRAVOCanonicalDiscoverySettings) `
                -SiteOverrides @{
                    BravoRoot = '\\NAS\BRAVO'
                    Sources = @{}
                })
        } catch {
            $preloadUncThrew = $true
        }
        Test-BRAVOCondition `
            -Condition $preloadUncThrew `
            -Name "DiscoveryOverride/NonLocalPathFailsClosed" `
            -Failure "UNC/мережевий шлях у discoverySettings має відхилятись fail-closed тим самим правилом, що й у test-only env-seam"

        # --- Configuration/DiscoverySettingsDefaultsMatchCanonical ---
        # Механічний guard проти дрейфу двох описів однієї структури:
        # raw-defaults (BRAVO.Configuration) і канонічної порожньої форми
        # (BRAVO.Configuration.Derivation).
        $preloadDefaultsBlock = (Get-BRAVODefaultConfiguration)['discoverySettings']
        $preloadCanonicalBlock = Get-BRAVOCanonicalDiscoverySettings
        $preloadDefaultKeys = @(@($preloadDefaultsBlock.Keys) | Sort-Object)
        $preloadCanonicalKeys = @(@($preloadCanonicalBlock.Keys) | Sort-Object)
        $preloadDefaultSourceKeys = @(@($preloadDefaultsBlock['Sources'].Keys) | Sort-Object)
        $preloadCanonicalSourceKeys = @(@($preloadCanonicalBlock['Sources'].Keys) | Sort-Object)
        $preloadDefaultsAllNull = @(@($preloadDefaultsBlock.Keys) | Where-Object {
            $_ -ne 'Sources' -and $null -ne $preloadDefaultsBlock[$_]
        }).Count -eq 0
        Test-BRAVOCondition `
            -Condition (
                ($preloadDefaultKeys -join ',') -eq ($preloadCanonicalKeys -join ',') -and
                ($preloadDefaultSourceKeys -join ',') -eq ($preloadCanonicalSourceKeys -join ',') -and
                $preloadDefaultsAllNull
            ) `
            -Name "Configuration/DiscoverySettingsDefaultsMatchCanonical" `
            -Failure "raw-defaults discoverySettings і Get-BRAVOCanonicalDiscoverySettings мусять мати ІДЕНТИЧНУ форму з усіма `$null — інакше site-override і canonical база розійдуться"

        # --- Структурні guard-и ланцюга ---
        $preloadLoaderText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_CONFIG_LOADER.ps1'), [Text.Encoding]::UTF8)
        $preloadExampleText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.local.config.example'), [Text.Encoding]::UTF8)
        Test-BRAVOCondition `
            -Condition (
                $preloadLoaderText.Contains('Resolve-BRAVOEffectiveDiscoverySettings') -and
                -not $preloadLoaderText.Contains('$global:discoverySettings = Get-BRAVOCanonicalDiscoverySettings') -and
                -not $preloadExampleText.Contains('override не подіє')
            ) `
            -Name "DiscoveryOverride/LoaderAppliesOverridesBeforeDerivation" `
            -Failure "BRAVO_CONFIG_LOADER мусить резолвити discoverySettings через Resolve-BRAVOEffectiveDiscoverySettings (а не перезаписувати змерджене значення канонічним літералом), а приклад site-конфігу не повинен далі стверджувати, що override не діє"
    } finally {
        $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH = $preloadSavedOverridePath
        $env:BRAVO_DATARESTORE_TEST_HOOKS = $preloadSavedHooks
        Remove-Item -LiteralPath $preloadRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# BRAVO.Configuration.Schema — формальна схема Configuration v2 (#154, B2)
# =====================================================================
# Окремий child scope (& { ... }) — з тієї самої причини, що й блок
# Delta вище: усі фрагменти self-test дот-сорсяться в ОДИН scope.
& {
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Schema.psd1') -Force

    function Add-BRAVOSchemaTestLeaf {
        # Плоский перелік ЛИСТІВ канонічного графа: 'dot.path' -> значення.
        # Sink мутується, а не повертається: PowerShell 5.1 розгорнув би
        # колекцію-значення, і масив-лист перетворився б на свій елемент.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Node,
            [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prefix,
            [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$Sink
        )
        if ($Node -is [hashtable]) {
            foreach ($nodeKey in @($Node.Keys)) {
                $childPrefix = ''
                if ([string]::IsNullOrEmpty($Prefix)) { $childPrefix = [string]$nodeKey } else { $childPrefix = "$Prefix.$nodeKey" }
                Add-BRAVOSchemaTestLeaf -Node $Node[$nodeKey] -Prefix $childPrefix -Sink $Sink
            }
            return
        }
        $Sink[$Prefix] = $Node
    }

    $schemaDefaults = Get-BRAVODefaultConfiguration
    $schemaCatalog = Get-BRAVOConfigurationSchema -ReferenceConfiguration $schemaDefaults
    $schemaCanonicalLeaves = @{}
    Add-BRAVOSchemaTestLeaf -Node $schemaDefaults -Prefix '' -Sink $schemaCanonicalLeaves

    # --- Schema/AcceptsCanonicalConfiguration ---
    # Найсильніший інваріант: канонічна конфігурація, подана САМА СОБІ як
    # шар перевизначень, мусить пройти схему без жодного порушення.
    # Якщо ні — схема суперечить дефолтам, які вона описує.
    $schemaSelfResult = Test-BRAVOConfigurationOverrideSchema -DotPathOverrides $schemaCanonicalLeaves -Schema $schemaCatalog
    $schemaSelfMessages = @(@($schemaSelfResult.Violations) | ForEach-Object { [string]$_.Message })
    Test-BRAVOCondition `
        -Condition ([bool]$schemaSelfResult.IsValid) `
        -Name "Schema/AcceptsCanonicalConfiguration" `
        -Failure "канонічні дефолти мусять проходити власну схему без порушень; отримано $($schemaSelfMessages.Count): $([string]::Join(' | ', $schemaSelfMessages))"

    # --- Schema/CoversEveryCanonicalLeaf ---
    # "Обов'язковість" у термінах B2: жодного листа без типу. Перевіряє і
    # зворотний бік — що в схемі немає дескриптора-листа, якому в
    # канонічному графі ніщо не відповідає (застарілий запис таблиці
    # невизначених листів).
    $schemaLeafDescriptors = @(@($schemaCatalog.Keys) | Where-Object { [string]$schemaCatalog[$_].Kind -ne 'Node' })
    $schemaMissingLeaves = @(@($schemaCanonicalLeaves.Keys) | Where-Object { -not $schemaCatalog.Contains([string]$_) })
    $schemaOrphanLeaves = @(@($schemaLeafDescriptors) | Where-Object { -not $schemaCanonicalLeaves.Contains([string]$_) })
    $schemaWeakDescriptors = @(@($schemaLeafDescriptors) | Where-Object {
        $descriptor = $schemaCatalog[$_]
        $kindIsKnown = @('Boolean', 'String', 'Number', 'Array') -contains [string]$descriptor.Kind
        $elementIsKnown = $true
        if ([string]$descriptor.Kind -eq 'Array') {
            $elementIsKnown = @('Boolean', 'String', 'Number') -contains [string]$descriptor.ElementKind
        }
        -not ($kindIsKnown -and $elementIsKnown)
    })
    Test-BRAVOCondition `
        -Condition (
            $schemaMissingLeaves.Count -eq 0 -and
            $schemaOrphanLeaves.Count -eq 0 -and
            $schemaWeakDescriptors.Count -eq 0
        ) `
        -Name "Schema/CoversEveryCanonicalLeaf" `
        -Failure "схема мусить покривати КОЖЕН канонічний лист типом, який реально перевіряється; без опису: $([string]::Join(', ', $schemaMissingLeaves)); зайві дескриптори: $([string]::Join(', ', $schemaOrphanLeaves)); без придатного роду: $([string]::Join(', ', $schemaWeakDescriptors))"

    # --- Schema/RejectsWrongScalarType ---
    $schemaWrongScalar = Test-BRAVOConfigurationOverrideSchema `
        -DotPathOverrides @{ 'maintenanceSettings.Limits.MinimumFreeSpaceGB' = 'двадцять' } `
        -Schema $schemaCatalog
    Test-BRAVOCondition `
        -Condition (-not [bool]$schemaWrongScalar.IsValid -and @($schemaWrongScalar.Violations).Count -eq 1) `
        -Name "Schema/RejectsWrongScalarType" `
        -Failure "рядок на місці числового ліста мусить бути порушенням схеми (отримано порушень: $(@($schemaWrongScalar.Violations).Count))"

    # --- Schema/ReportsExactInvalidPath ---
    # Повідомлення мусить називати САМЕ той шлях, який оператор написав:
    # "недійсний тип у конфігурації" без шляху не дає що виправляти.
    $schemaExactPathMessage = ''
    if (@($schemaWrongScalar.Violations).Count -gt 0) { $schemaExactPathMessage = [string](@($schemaWrongScalar.Violations)[0].Message) }
    Test-BRAVOCondition `
        -Condition (
            $schemaExactPathMessage.StartsWith('maintenanceSettings.Limits.MinimumFreeSpaceGB:') -and
            $schemaExactPathMessage.Contains('двадцять')
        ) `
        -Name "Schema/ReportsExactInvalidPath" `
        -Failure "повідомлення мусить починатись точним dot-шляхом і містити фактичне значення; отримано: '$schemaExactPathMessage'"

    # --- Schema/RejectsWrongArrayType ---
    # Дві різні помилки одного роду: скаляр замість масиву й елемент
    # неправильного типу всередині масиву.
    $schemaScalarForArray = Test-BRAVOConfigurationOverrideSchema `
        -DotPathOverrides @{ 'maintenanceSettings.Limits.MdFileSizeExclusions' = 'KZPpatArc.md' } `
        -Schema $schemaCatalog
    $schemaBadElement = Test-BRAVOConfigurationOverrideSchema `
        -DotPathOverrides @{ 'maintenanceSettings.Limits.MdFileSizeExclusions' = @('KZPpatArc.md', 5) } `
        -Schema $schemaCatalog
    $schemaBadElementPath = ''
    if (@($schemaBadElement.Violations).Count -gt 0) { $schemaBadElementPath = [string](@($schemaBadElement.Violations)[0].Path) }
    Test-BRAVOCondition `
        -Condition (
            -not [bool]$schemaScalarForArray.IsValid -and
            -not [bool]$schemaBadElement.IsValid -and
            $schemaBadElementPath -eq 'maintenanceSettings.Limits.MdFileSizeExclusions[1]'
        ) `
        -Name "Schema/RejectsWrongArrayType" `
        -Failure "скаляр замість масиву й нерядковий елемент мусять бути порушеннями, а індекс елемента — у шляху; отримано шлях '$schemaBadElementPath'"

    # --- Schema/EmptyArraySemanticsPreserved ---
    # Явний @() лишається ВАЛІДНИМ навмисним перевизначенням (контракт
    # мерджу Foundation) — схема не сміє зробити його помилкою, і мердж
    # після перевірки мусить дати саме порожній масив.
    $schemaEmptyArrayResult = Test-BRAVOConfigurationOverrideSchema `
        -DotPathOverrides @{ 'maintenanceSettings.Limits.ExcludedDrives' = @() } `
        -Schema $schemaCatalog
    $schemaEmptyArrayMerged = Resolve-BRAVORawConfiguration `
        -DefaultConfiguration (Get-BRAVODefaultConfiguration) `
        -PrimaryOverrides @{ maintenanceSettings = @{ Limits = @{ ExcludedDrives = @('F:\') } } } `
        -LocalOverrides @{ 'maintenanceSettings.Limits.ExcludedDrives' = @() }
    Test-BRAVOCondition `
        -Condition (
            [bool]$schemaEmptyArrayResult.IsValid -and
            @($schemaEmptyArrayMerged.maintenanceSettings.Limits.ExcludedDrives).Count -eq 0
        ) `
        -Name "Schema/EmptyArraySemanticsPreserved" `
        -Failure "явний @() мусить лишатись валідним перевизначенням і після мерджу давати порожній масив (отримано елементів: $(@($schemaEmptyArrayMerged.maintenanceSettings.Limits.ExcludedDrives).Count))"

    # --- Schema/NullSemanticsPreserved ---
    # $null допустимий РІВНО там, де канонічний дефолт сам $null
    # (discoverySettings.* = "покластись на auto-discovery", #158 етап 4),
    # і ніде більше: $null у pathSettings.BackupRoot мовчки вимкнув би
    # явно заданий корінь резервних копій.
    $schemaNullAllowed = Test-BRAVOConfigurationOverrideSchema `
        -DotPathOverrides @{ 'discoverySettings.BravoRoot' = $null } -Schema $schemaCatalog
    $schemaNullRejected = Test-BRAVOConfigurationOverrideSchema `
        -DotPathOverrides @{ 'pathSettings.BackupRoot' = $null } -Schema $schemaCatalog
    $schemaEmptyStringAllowed = Test-BRAVOConfigurationOverrideSchema `
        -DotPathOverrides @{ 'discoverySettings.BravoRoot' = '' } -Schema $schemaCatalog
    Test-BRAVOCondition `
        -Condition (
            [bool]$schemaNullAllowed.IsValid -and
            [bool]$schemaEmptyStringAllowed.IsValid -and
            -not [bool]$schemaNullRejected.IsValid
        ) `
        -Name "Schema/NullSemanticsPreserved" `
        -Failure "`$null мусить прийматись лише для nullable-листів (discoverySettings.*) і відхилятись для решти; allowed=$($schemaNullAllowed.IsValid) empty=$($schemaEmptyStringAllowed.IsValid) rejected=$($schemaNullRejected.IsValid)"

    # --- Schema/NodeOverrideIsTypeChecked ---
    # Перевизначення ЦІЛОГО вузла не повинно бути дірою в перевірці типів:
    # 'bravoSettings.NotificationRouting' = @{ SUCCESS = 42 } мерджиться
    # рекурсивно, тож і перевірятись мусить рекурсивно.
    $schemaNodeOverride = Test-BRAVOConfigurationOverrideSchema `
        -DotPathOverrides @{ 'bravoSettings.NotificationRouting' = @{ SUCCESS = 42 } } `
        -Schema $schemaCatalog
    $schemaNodeOverridePath = ''
    if (@($schemaNodeOverride.Violations).Count -gt 0) { $schemaNodeOverridePath = [string](@($schemaNodeOverride.Violations)[0].Path) }
    Test-BRAVOCondition `
        -Condition (
            -not [bool]$schemaNodeOverride.IsValid -and
            $schemaNodeOverridePath -eq 'bravoSettings.NotificationRouting.SUCCESS'
        ) `
        -Name "Schema/NodeOverrideIsTypeChecked" `
        -Failure "перевизначення вузла мусить перевірятись рекурсивно з точним шляхом листа; отримано '$schemaNodeOverridePath'"

    # --- Schema/UnknownLeafForwardCompatibilityIsPreserved ---
    # Рішення власника D3: невідомий КІНЦЕВИЙ сегмент і далі приймається
    # (+ облік), а не відхиляється. Схема НЕ сміє це змінити — ні
    # власним порушенням, ні через наскрізний мердж.
    $schemaUnknownLeaf = Test-BRAVOConfigurationOverrideSchema `
        -DotPathOverrides @{ 'maintenanceSettings.Limits.FutureKnobFromNewerToolkit' = 'x' } `
        -Schema $schemaCatalog
    $schemaUnknownLeafSink = New-Object System.Collections.Generic.List[string]
    $schemaUnknownLeafMerged = Resolve-BRAVORawConfiguration `
        -DefaultConfiguration (Get-BRAVODefaultConfiguration) `
        -PrimaryOverrides $null `
        -LocalOverrides @{ 'maintenanceSettings.Limits.FutureKnobFromNewerToolkit' = 'x' } `
        -UnknownLeafPathSink $schemaUnknownLeafSink
    Test-BRAVOCondition `
        -Condition (
            [bool]$schemaUnknownLeaf.IsValid -and
            [string]$schemaUnknownLeafMerged.maintenanceSettings.Limits.FutureKnobFromNewerToolkit -eq 'x' -and
            $schemaUnknownLeafSink.Count -eq 1
        ) `
        -Name "Schema/UnknownLeafForwardCompatibilityIsPreserved" `
        -Failure "невідомий leaf мусить лишатись прийнятим і облікованим (рішення D3), а не ставати порушенням схеми; valid=$($schemaUnknownLeaf.IsValid) sink=$($schemaUnknownLeafSink.Count)"

    # --- Schema/RejectsUnknownTopLevel ---
    # Політика невідомих шляхів лишається за ConvertTo-BRAVONestedOverride
    # (одна канонічна реалізація), тому перевіряється через наскрізний
    # мердж: додавання схеми не сміє послабити цю відмову.
    $schemaUnknownTopLevelThrew = $false
    try {
        [void](Resolve-BRAVORawConfiguration `
            -DefaultConfiguration (Get-BRAVODefaultConfiguration) `
            -PrimaryOverrides $null `
            -LocalOverrides @{ 'noSuchTopLevelBlock' = 1 })
    } catch { $schemaUnknownTopLevelThrew = $true }
    Test-BRAVOCondition `
        -Condition $schemaUnknownTopLevelThrew `
        -Name "Schema/RejectsUnknownTopLevel" `
        -Failure "невідомий top-level ключ мусить лишатись fail-closed після введення схеми v2"

    # --- Schema/RejectsUnknownParent ---
    $schemaUnknownParentThrew = $false
    try {
        [void](Resolve-BRAVORawConfiguration `
            -DefaultConfiguration (Get-BRAVODefaultConfiguration) `
            -PrimaryOverrides $null `
            -LocalOverrides @{ 'maintenanceSettings.NoSuchNode.Leaf' = 1 })
    } catch { $schemaUnknownParentThrew = $true }
    Test-BRAVOCondition `
        -Condition $schemaUnknownParentThrew `
        -Name "Schema/RejectsUnknownParent" `
        -Failure "невідомий батьківський вузол мусить лишатись fail-closed після введення схеми v2"

    # --- Schema/DocumentedCatalogKindsAgree ---
    # Замість другої копії типів із каталогу Configurator-а — механічний
    # доказ, що обидві декларації описують ОДНУ форму. Розбіжність
    # (напр. документований Integer там, де канонічний дефолт — рядок)
    # валить перевірку замість того, щоб тихо жити в двох місцях.
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configurator\BRAVO.Configurator.Schema.psd1')
    $schemaCatalogKindByDocumentedType = @{
        'String' = 'String'; 'Path' = 'String'; 'UNCPath' = 'String'; 'Time' = 'String'; 'Enum' = 'String'
        'Integer' = 'Number'; 'Number' = 'Number'
        'Boolean' = 'Boolean'
        'StringArray' = 'Array:String'; 'NumberArray' = 'Array:Number'
    }
    $schemaCatalogMismatches = New-Object System.Collections.Generic.List[string]
    foreach ($documentedDescriptor in @(Get-BRAVOConfiguratorSchemaCatalog)) {
        $documentedPath = [string]$documentedDescriptor['Path']
        if (-not $schemaCatalog.Contains($documentedPath)) { continue }
        $documentedType = [string]$documentedDescriptor['Type']
        if (-not $schemaCatalogKindByDocumentedType.Contains($documentedType)) {
            [void]$schemaCatalogMismatches.Add("$documentedPath (невідомий документований тип '$documentedType')")
            continue
        }
        $schemaDescriptor = $schemaCatalog[$documentedPath]
        $actualKindText = [string]$schemaDescriptor.Kind
        if ($actualKindText -eq 'Array') { $actualKindText = "Array:$([string]$schemaDescriptor.ElementKind)" }
        if ($actualKindText -ne [string]$schemaCatalogKindByDocumentedType[$documentedType]) {
            [void]$schemaCatalogMismatches.Add("$documentedPath (каталог '$documentedType' -> схема '$actualKindText')")
        }
    }
    Test-BRAVOCondition `
        -Condition ($schemaCatalogMismatches.Count -eq 0) `
        -Name "Schema/DocumentedCatalogKindsAgree" `
        -Failure "задокументований каталог Configurator-а і схема v2 мусять описувати однакові роди значень; розбіжності: $([string]::Join('; ', $schemaCatalogMismatches))"

    # --- Schema/LoaderValidatesLocalLayerBeforeMerge ---
    # Структурний guard: перевірка типів мусить стояти в канонічному
    # конвеєрі ДО мерджу, інакше недійсне значення встигло б потрапити в
    # ефективну конфігурацію, і "fail-closed" був би лише на папері.
    $schemaLoaderText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_CONFIG_LOADER.ps1'), [Text.Encoding]::UTF8)
    $schemaValidationIndex = $schemaLoaderText.IndexOf('Test-BRAVOConfigurationOverrideSchema')
    $schemaMergeIndex = $schemaLoaderText.IndexOf('$mergedConfiguration = Resolve-BRAVORawConfiguration')
    Test-BRAVOCondition `
        -Condition (
            $schemaValidationIndex -gt 0 -and
            $schemaMergeIndex -gt 0 -and
            $schemaValidationIndex -lt $schemaMergeIndex
        ) `
        -Name "Schema/LoaderValidatesLocalLayerBeforeMerge" `
        -Failure "BRAVO_CONFIG_LOADER мусить валідувати типи site-шару ДО Resolve-BRAVORawConfiguration (validation=$schemaValidationIndex merge=$schemaMergeIndex)"
}

# =====================================================================
# Версійний диспетч site-файлу (#154, B3)
# =====================================================================
& {
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Schema.psd1') -Force
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.DataFile.psd1') -Force

    $versionContract = Get-BRAVOConfigurationSchemaVersionContract

    # --- ConfigVersion/V2Loads ---
    # Маркер приймається, дає версію 2 і НЕ потрапляє в перевизначення.
    $versionV2Data = ConvertFrom-BRAVOConfigurationDataFileText `
        -Text "@{ configSchemaVersion = 2`r`n'pathSettings.BackupRoot' = 'E:\ARCHIV' }" `
        -SourceName 'v2-fixture'
    $versionV2 = Resolve-BRAVOConfigurationSchemaVersion -DataFileContent $versionV2Data -SourceName 'v2-fixture'
    Test-BRAVOCondition `
        -Condition (
            [int]$versionV2.DeclaredVersion -eq 2 -and
            [int]$versionV2.EffectiveVersion -eq 2 -and
            [bool]$versionV2.WasDeclared -and
            @($versionV2.Overrides.Keys).Count -eq 1 -and
            $versionV2.Overrides.Contains('pathSettings.BackupRoot')
        ) `
        -Name "ConfigVersion/V2Loads" `
        -Failure "оголошена версія 2 має прийматись, а маркер — НЕ ставати перевизначенням; declared=$($versionV2.DeclaredVersion) ключів=$(@($versionV2.Overrides.Keys) -join ', ')"

    # --- ConfigVersion/MarkerIsNotATopLevelOverride ---
    # Ключова причина, чому маркер знімається саме в канонічному читачі:
    # 'configSchemaVersion' — односегментний dot-шлях, тобто top-level,
    # і ConvertTo-BRAVONestedOverride відхилив би його fail-closed.
    # Доводимо обидві половини: без зняття — відмова, зі зняттям — мердж.
    $versionUnstrippedThrew = $false
    try {
        [void](Resolve-BRAVORawConfiguration `
            -DefaultConfiguration (Get-BRAVODefaultConfiguration) `
            -PrimaryOverrides $null `
            -LocalOverrides @{ 'configSchemaVersion' = 2 })
    } catch { $versionUnstrippedThrew = $true }
    $versionStrippedMerged = Resolve-BRAVORawConfiguration `
        -DefaultConfiguration (Get-BRAVODefaultConfiguration) `
        -PrimaryOverrides $null `
        -LocalOverrides $versionV2.Overrides
    Test-BRAVOCondition `
        -Condition (
            $versionUnstrippedThrew -and
            [string]$versionStrippedMerged.pathSettings.BackupRoot -eq 'E:\ARCHIV'
        ) `
        -Name "ConfigVersion/MarkerIsNotATopLevelOverride" `
        -Failure "незнятий маркер мусить відхилятись як невідомий top-level ключ, а знятий — не заважати мерджу; unstrippedThrew=$versionUnstrippedThrew BackupRoot='$($versionStrippedMerged.pathSettings.BackupRoot)'"

    # --- ConfigVersion/LegacyCompatibilityMatchesDocumentedPolicy ---
    # Кожен розгорнутий сьогодні site-файл маркера НЕ має. Політика:
    # приймається як версія 1 (інакше перше ж оновлення зупинило б увесь
    # парк), і це саме те, що написано в задокументованому контракті.
    $versionLegacyData = ConvertFrom-BRAVOConfigurationDataFileText `
        -Text "@{ 'pathSettings.BackupRoot' = 'E:\ARCHIV' }" -SourceName 'legacy-fixture'
    $versionLegacy = Resolve-BRAVOConfigurationSchemaVersion -DataFileContent $versionLegacyData -SourceName 'legacy-fixture'
    $versionExampleText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.local.config.example'), [Text.Encoding]::UTF8)
    Test-BRAVOCondition `
        -Condition (
            $null -eq $versionLegacy.DeclaredVersion -and
            [int]$versionLegacy.EffectiveVersion -eq [int]$versionContract.LegacyVersion -and
            [int]$versionContract.LegacyVersion -eq 1 -and
            -not [bool]$versionLegacy.WasDeclared -and
            $versionExampleText.Contains('маркера немає') -and
            $versionExampleText.Contains('configSchemaVersion = 1 або 2')
        ) `
        -Name "ConfigVersion/LegacyCompatibilityMatchesDocumentedPolicy" `
        -Failure "файл без маркера мусить прийматись як версія $($versionContract.LegacyVersion), і рівно це мусить бути задокументовано в BRAVO.local.config.example; effective=$($versionLegacy.EffectiveVersion) declared=$($versionLegacy.DeclaredVersion)"

    # --- ConfigVersion/UnsupportedVersionFailsClosed ---
    # Файл новішого формату НЕ читається як старіший "на удачу": це
    # мовчазно застосувало б підмножину ключів за чужими правилами.
    $versionUnsupportedThrew = $false
    $versionUnsupportedMessage = ''
    try {
        [void](Resolve-BRAVOConfigurationSchemaVersion `
            -DataFileContent @{ 'configSchemaVersion' = 99 } -SourceName 'future-fixture')
    } catch { $versionUnsupportedThrew = $true; $versionUnsupportedMessage = [string]$_.Exception.Message }
    Test-BRAVOCondition `
        -Condition ($versionUnsupportedThrew -and $versionUnsupportedMessage.Contains('99')) `
        -Name "ConfigVersion/UnsupportedVersionFailsClosed" `
        -Failure "непідтримувана версія мусить fail-closed із вказанням значення; threw=$versionUnsupportedThrew message='$versionUnsupportedMessage'"

    # --- ConfigVersion/VersionMustBeCorrectType ---
    # '2' у лапках, $true, масив і $null — не версія схеми. Прийняти
    # рядок означало б, що будь-яке значення, приводне до числа, стає
    # версією — тобто контракт версії перестає бути контрактом.
    # Перелік будується через List, а НЕ через @('2', $true, @(2), ...):
    # PowerShell 5.1 розгортає вкладений масив у літералі масиву на один
    # рівень, тому @(2) перетворився б на число 2 — і випадок "масив"
    # мовчки перевіряв би зовсім не те.
    $versionBadValues = New-Object System.Collections.Generic.List[object]
    [void]$versionBadValues.Add('2')
    [void]$versionBadValues.Add($true)
    [void]$versionBadValues.Add(@(2))
    [void]$versionBadValues.Add($null)
    [void]$versionBadValues.Add(2.5)
    $versionBadTypeResults = New-Object System.Collections.Generic.List[string]
    foreach ($versionBadValue in $versionBadValues) {
        $versionBadThrew = $false
        try {
            [void](Resolve-BRAVOConfigurationSchemaVersion `
                -DataFileContent @{ 'configSchemaVersion' = $versionBadValue } -SourceName 'badtype-fixture')
        } catch { $versionBadThrew = $true }
        if (-not $versionBadThrew) {
            [void]$versionBadTypeResults.Add("$(if ($null -eq $versionBadValue) { '$null' } else { [string]$versionBadValue })")
        }
    }
    Test-BRAVOCondition `
        -Condition ($versionBadTypeResults.Count -eq 0) `
        -Name "ConfigVersion/VersionMustBeCorrectType" `
        -Failure "версія мусить бути цілим числом; помилково прийнято: $([string]::Join(', ', $versionBadTypeResults))"

    # --- ConfigVersion/VersionReadDoesNotExecuteFile ---
    # Версія береться з ДАНИХ, а не з виконання: 'configSchemaVersion =
    # 1 + 1' не стає двійкою, а відхиляється ще AST-парсером як вираз.
    # Інакше маркер версії був би єдиним полем файлу, здатним виконати
    # обчислення — тобто діркою в data-only контракті B1.
    $versionExpressionThrew = $false
    try {
        [void](ConvertFrom-BRAVOConfigurationDataFileText `
            -Text '@{ configSchemaVersion = 1 + 1 }' -SourceName 'expression-fixture')
    } catch { $versionExpressionThrew = $true }
    Test-BRAVOCondition `
        -Condition $versionExpressionThrew `
        -Name "ConfigVersion/VersionReadDoesNotExecuteFile" `
        -Failure "вираз у значенні маркера версії мусить відхилятись парсером, а не обчислюватись"

    # --- ConfigVersion/SeededExampleIsValidVersionedNoOpConfig ---
    # deploy\Install-BRAVOServer.ps1 -SeedLocalConfig копіює приклад в
    # АКТИВНИЙ site-файл. Отже приклад мусить бути не лише читабельним
    # документом, а й валідною конфігурацією: розбиратись канонічним
    # парсером, оголошувати поточну версію формату (інакше свіжий
    # інстал одразу попереджав би про відсутній маркер) і при цьому НЕ
    # перевизначати жодного ключа. Це також регресія на #154 B6:
    # скопійований приклад ніколи не має ставати мовчазним override.
    $versionExampleData = ConvertFrom-BRAVOConfigurationDataFileText `
        -Text ([IO.File]::ReadAllText((Join-Path $root 'BRAVO.local.config.example'), [Text.Encoding]::UTF8)) `
        -SourceName 'BRAVO.local.config.example'
    $versionExampleResolved = Resolve-BRAVOConfigurationSchemaVersion `
        -DataFileContent $versionExampleData -SourceName 'BRAVO.local.config.example'
    Test-BRAVOCondition `
        -Condition (
            [bool]$versionExampleResolved.WasDeclared -and
            [int]$versionExampleResolved.EffectiveVersion -eq [int]$versionContract.CurrentVersion -and
            @($versionExampleResolved.Overrides.Keys).Count -eq 0
        ) `
        -Name "ConfigVersion/SeededExampleIsValidVersionedNoOpConfig" `
        -Failure "BRAVO.local.config.example мусить бути валідним site-файлом, що оголошує версію $($versionContract.CurrentVersion) і не перевизначає нічого; declared=$($versionExampleResolved.WasDeclared) version=$($versionExampleResolved.EffectiveVersion) ключів=$(@($versionExampleResolved.Overrides.Keys) -join ', ')"

    # --- ConfigVersion/ConfiguratorWritesMarkerFromSingleSource ---
    # Серіалізаторів site-файлу ДВА (production-запис і кандидат для
    # ізольованого effective). Обидва мусять брати форму маркера з
    # канонічної функції, інакше копії розійдуться, і кандидат почне
    # відповідати іншій версії формату, ніж записаний файл.
    $versionDeclarationLine = Get-BRAVOConfigurationSchemaVersionDeclarationLine
    $versionPersistenceText = [IO.File]::ReadAllText(
        (Join-Path $root 'modules\BRAVO.Configurator\BRAVO.Configurator.Persistence.psm1'), [Text.Encoding]::UTF8)
    $versionEffectiveText = [IO.File]::ReadAllText(
        (Join-Path $root 'modules\BRAVO.Configurator\BRAVO.Configurator.Effective.psm1'), [Text.Encoding]::UTF8)
    Test-BRAVOCondition `
        -Condition (
            $versionDeclarationLine.Trim() -eq "$($versionContract.KeyName) = $($versionContract.CurrentVersion)" -and
            $versionPersistenceText.Contains('Get-BRAVOConfigurationSchemaVersionDeclarationLine') -and
            $versionEffectiveText.Contains('Get-BRAVOConfigurationSchemaVersionDeclarationLine')
        ) `
        -Name "ConfigVersion/ConfiguratorWritesMarkerFromSingleSource" `
        -Failure "обидва серіалізатори site-файлу мусять брати маркер з канонічної функції; рядок='$versionDeclarationLine'"

    # --- ConfigVersion/WrittenMarkerRoundTrips ---
    # Найважливіше для вікна сумісності: файл, ЗАПИСАНИЙ комплектом,
    # мусить читатись назад як версія 2 і не приносити зайвого ключа.
    $versionRoundTripText = "@{`r`n$versionDeclarationLine`r`n    'consoleSettings.ConsoleLevel' = 'ERROR'`r`n}"
    $versionRoundTripData = ConvertFrom-BRAVOConfigurationDataFileText `
        -Text $versionRoundTripText -SourceName 'roundtrip-fixture'
    $versionRoundTrip = Resolve-BRAVOConfigurationSchemaVersion `
        -DataFileContent $versionRoundTripData -SourceName 'roundtrip-fixture'
    Test-BRAVOCondition `
        -Condition (
            [int]$versionRoundTrip.EffectiveVersion -eq [int]$versionContract.CurrentVersion -and
            @($versionRoundTrip.Overrides.Keys).Count -eq 1 -and
            [string]$versionRoundTrip.Overrides['consoleSettings.ConsoleLevel'] -eq 'ERROR'
        ) `
        -Name "ConfigVersion/WrittenMarkerRoundTrips" `
        -Failure "записаний комплектом маркер мусить читатись назад як версія $($versionContract.CurrentVersion) без зайвих ключів; effective=$($versionRoundTrip.EffectiveVersion) ключів=$(@($versionRoundTrip.Overrides.Keys) -join ', ')"

    # =====================================================================
    # BRAVO.Configuration.Snapshot — знімок ефективної конфігурації (#154)
    # =====================================================================
    # Окремий child scope (& { ... }) з тієї самої причини, що й у секції
    # Delta вище: спільний $MaximumVariableCount на всі фрагменти.
    & {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Snapshot.psd1') -Force

        # --- Snapshot/VariableNameListIsUsable ---
        # Перелік — єдине джерело істини для ДВОХ доказів (паритет у CI і
        # міграція на сервері). Порожній або з дублікатами він знецінив би
        # обидва: порожній дав би "відмінностей немає" ні про що, дублікат
        # мовчки перезаписав би ключ у знімку.
        $snapshotNames = @(Get-BRAVOEffectiveConfigurationVariableName)
        $snapshotUnique = @($snapshotNames | Sort-Object -Unique)
        Test-BRAVOCondition `
            -Condition ($snapshotNames.Count -gt 0 -and $snapshotUnique.Count -eq $snapshotNames.Count) `
            -Name "Snapshot/VariableNameListIsUsable" `
            -Failure "канонічний перелік імен ефективної конфігурації має бути непорожнім і без дублікатів; усього=$($snapshotNames.Count) унікальних=$($snapshotUnique.Count)"

        # --- Snapshot/AbsentIsDistinguishableFromNull ---
        # $null є ЛЕГАЛЬНИМ значенням конфігурації. Якби відсутнє поле теж
        # давало $null, доказ міграції не відрізнив би "поля не стало" від
        # "поле дорівнює $null" — і зникнення значення пройшло б як PASS.
        $snapshotNullName = 'BRAVOSelfTestSnapshotNullProbe'
        $snapshotMissingName = 'BRAVOSelfTestSnapshotMissingProbe'
        try {
            Set-Variable -Name $snapshotNullName -Scope Global -Value $null
            $snapshotProbe = Get-BRAVOEffectiveConfigurationSnapshot -VariableName @($snapshotNullName, $snapshotMissingName)
            Test-BRAVOCondition `
                -Condition (
                    $null -eq $snapshotProbe[$snapshotNullName] -and
                    [string]$snapshotProbe[$snapshotMissingName] -eq '<<ABSENT>>'
                ) `
                -Name "Snapshot/AbsentIsDistinguishableFromNull" `
                -Failure "відсутня змінна має давати маркер '<<ABSENT>>', а наявна зі значенням `$null — саме `$null; отримано null-проба='$($snapshotProbe[$snapshotNullName])' missing-проба='$($snapshotProbe[$snapshotMissingName])'"
        } finally {
            Remove-Variable -Name $snapshotNullName -Scope Global -ErrorAction SilentlyContinue
        }

        # --- Snapshot/PreservesRequestedOrder ---
        # Порядок ключів визначає порядок рядків у файлі доказу, який
        # оператор порівнює побайтово. Хеш-таблиця без [ordered] дала б
        # різний порядок між прогонами й зробила б порівняння неможливим.
        $snapshotOrderNames = @('zzzSnapshotProbeC', 'aaaSnapshotProbeA', 'mmmSnapshotProbeB')
        $snapshotOrdered = Get-BRAVOEffectiveConfigurationSnapshot -VariableName $snapshotOrderNames
        $snapshotOrderedKeys = @($snapshotOrdered.Keys)
        Test-BRAVOCondition `
            -Condition ([string]::Join(',', $snapshotOrderedKeys) -ceq [string]::Join(',', $snapshotOrderNames)) `
            -Name "Snapshot/PreservesRequestedOrder" `
            -Failure "знімок має зберігати порядок запитаних імен; запитано=[$([string]::Join(',', $snapshotOrderNames))] отримано=[$([string]::Join(',', $snapshotOrderedKeys))]"

        # --- Snapshot/ParityHarnessUsesCanonicalList ---
        # Governance: перелік переїхав із ci\Test-BRAVOConfigFoundationParity.ps1
        # у модуль саме тому, що споживачів стало двоє. Повернення літерала
        # в harness відновило б дві копії — і доказ паритету в CI почав би
        # мовчки дивитись на інший граф, ніж доказ міграції на сервері.
        $snapshotHarnessPath = Join-Path $root 'ci\Test-BRAVOConfigFoundationParity.ps1'
        $snapshotHarnessText = [IO.File]::ReadAllText($snapshotHarnessPath, [Text.Encoding]::UTF8)
        $snapshotHarnessCallsCanonical = $snapshotHarnessText.Contains('Get-BRAVOEffectiveConfigurationVariableName')
        # Літеральний перелік розпізнається за присвоєнням $capturedNames
        # масиву, що ПОЧИНАЄТЬСЯ з рядка в лапках.
        $snapshotHarnessHasLiteralList = [regex]::IsMatch($snapshotHarnessText, '\$capturedNames\s*=\s*@\(\s*[\r\n]*\s*[''"]')
        Test-BRAVOCondition `
            -Condition ($snapshotHarnessCallsCanonical -and -not $snapshotHarnessHasLiteralList) `
            -Name "Snapshot/ParityHarnessUsesCanonicalList" `
            -Failure "ci\Test-BRAVOConfigFoundationParity.ps1 має брати перелік імен з Get-BRAVOEffectiveConfigurationVariableName і не тримати власного літерального переліку; викликає=$snapshotHarnessCallsCanonical літерал=$snapshotHarnessHasLiteralList"
    }
}

# =====================================================================
# Configuration v2 Pilot Safety — синтетична матриця + наскрізний round-trip
# (Configuration v2 Pilot Preparation, розгортає прогалини, знайдені
# незалежним аудитом перед першим реальним pilot-переносом)
# =====================================================================
# Окремий top-level child scope (& { ... }), той самий прийом, що й Delta/
# DataFile вище: власний $MaximumVariableCount, не змішується з рештою
# фрагментів файлу.
& {
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.psd1') -Force
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Delta.psd1') -Force
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configurator\BRAVO.Configurator.Effective.psd1') -Force

    # --- PilotSafety/DeltaMatrix: типи, яких не було в наявній Delta/*-матриці ---
    # Delta/* вище вже покриває no-changes/nested/array(incl. empty)/
    # unknown-leaf/unknown-parent/wrong-type/legacy-only/детермінізм.
    # Тут — конкретні прогалини, знайдені аудитом: scalar number, boolean
    # true/false, явний empty string, і security-sensitive (credential
    # reference) шлях. Один $matrixReference/$matrixCandidate на весь
    # набір — кожен випадок змінює РІВНО одне поле, тож Test-BRAVOCondition
    # для кожного випадку перевіряє саме той один шлях.
    $matrixReference = @{
        scalarNumber   = 24
        scalarBoolTrue  = $true
        scalarBoolFalse = $false
        emptyString    = 'було-не-порожньо'
        credentialRef  = 'BRAVO_SFTP_PASSWORD'
    }
    $matrixCandidate = @{
        scalarNumber   = 40
        scalarBoolTrue  = $false
        scalarBoolFalse = $true
        emptyString    = ''
        credentialRef  = 'BRAVO_SFTP_PASSWORD_SITE2'
    }
    $matrixDiff = @(Compare-BRAVOConfigurationGraph -ReferenceConfiguration $matrixReference -CandidateConfiguration $matrixCandidate)
    $matrixByPath = @{}
    foreach ($d in $matrixDiff) { $matrixByPath[[string]$d.Path] = $d }

    Test-BRAVOCondition `
        -Condition (
            $matrixByPath.Contains('scalarNumber') -and
            $matrixByPath['scalarNumber'].Kind -eq 'Changed' -and
            $matrixByPath['scalarNumber'].CandidateValue -eq 40 -and
            $matrixByPath['scalarNumber'].CandidateValue -isnot [string]
        ) `
        -Name "PilotSafety/DeltaMatrixScalarNumberChanged" `
        -Failure "зміна числового скаляра (24 -> 40) має дати Changed зі збереженим числовим типом кандидата"

    Test-BRAVOCondition `
        -Condition (
            $matrixByPath.Contains('scalarBoolTrue') -and $matrixByPath['scalarBoolTrue'].Kind -eq 'Changed' -and
            $matrixByPath['scalarBoolTrue'].CandidateValue -eq $false -and
            $matrixByPath.Contains('scalarBoolFalse') -and $matrixByPath['scalarBoolFalse'].Kind -eq 'Changed' -and
            $matrixByPath['scalarBoolFalse'].CandidateValue -eq $true
        ) `
        -Name "PilotSafety/DeltaMatrixBooleanBothDirectionsChanged" `
        -Failure "зміна булевого скаляра в ОБИДВА боки (true->false і false->true) має дати Changed з коректним булевим кандидатом"

    Test-BRAVOCondition `
        -Condition (
            $matrixByPath.Contains('emptyString') -and $matrixByPath['emptyString'].Kind -eq 'Changed' -and
            $matrixByPath['emptyString'].CandidateValue -is [string] -and
            [string]$matrixByPath['emptyString'].CandidateValue -eq ''
        ) `
        -Name "PilotSafety/DeltaMatrixExplicitEmptyStringChanged" `
        -Failure "явна зміна непорожнього рядка на порожній ('') має дати Changed з порожнім РЯДКОМ, а не `$null чи відсутнім записом"

    Test-BRAVOCondition `
        -Condition (
            $matrixByPath.Contains('credentialRef') -and $matrixByPath['credentialRef'].Kind -eq 'Changed' -and
            [string]$matrixByPath['credentialRef'].CandidateValue -eq 'BRAVO_SFTP_PASSWORD_SITE2' -and
            [string]$matrixByPath['credentialRef'].ReferenceValue -eq 'BRAVO_SFTP_PASSWORD'
        ) `
        -Name "PilotSafety/DeltaMatrixCredentialReferenceChanged" `
        -Failure "зміна Credential Manager target-name (посилання, не секрет) має пройти компаратор як звичайний рядок без спеціальної обробки"

    # --- PilotSafety/LiteralRoundTrip: ConvertTo-BRAVOConfiguratorPowerShellLiteral не мовчки коерсить типи ---
    # Фіксує рендер РІВНО тих типів, які реально проходять через
    # dot-path override (BRAVO.local.config є плоским скаляр|масив-
    # контрактом — nested hashtable свідомо не підтримується, див.
    # fail-closed throw у самій функції).
    $literalCases = @(
        @{ Value = 40; Expected = '40' },
        @{ Value = $true; Expected = '$true' },
        @{ Value = $false; Expected = '$false' },
        @{ Value = ''; Expected = "''" },
        @{ Value = 'BRAVO_SFTP_PASSWORD_SITE2'; Expected = "'BRAVO_SFTP_PASSWORD_SITE2'" },
        @{ Value = $null; Expected = '$null' },
        @{ Value = @('D:\', 'E:\'); Expected = "@('D:\', 'E:\')" }
    )
    $literalFailures = New-Object System.Collections.Generic.List[string]
    foreach ($case in $literalCases) {
        $rendered = ConvertTo-BRAVOConfiguratorPowerShellLiteral -Value $case.Value
        if ($rendered -cne $case.Expected) {
            [void]$literalFailures.Add("очікував '$($case.Expected)', отримав '$rendered' для значення типу $(if ($null -eq $case.Value) { '<null>' } else { $case.Value.GetType().Name })")
        }
    }
    Test-BRAVOCondition `
        -Condition ($literalFailures.Count -eq 0) `
        -Name "PilotSafety/LiteralRoundTripPreservesType" `
        -Failure "ConvertTo-BRAVOConfiguratorPowerShellLiteral мусить рендерити число/bool/порожній рядок/`$null/масив БЕЗ коерсії в рядок: $([string]::Join(' | ', $literalFailures))"

    # --- PilotSafety/EndToEndParity: головний семантичний інваріант пілота ---
    # EffectiveConfig(original) == EffectiveConfig(canonical defaults +
    # generated site delta). Раніше в репозиторії НЕ було тесту, що
    # проганяє САМЕ ці кроки в САМЕ такому порядку (незалежний аудит
    # Configuration v2 Pilot Preparation, 2026-09-16): ci\Test-
    # BRAVOConfigFoundationParity.ps1 порівнює знімки одного great fixed
    # override-набору між двома комітами (регресія pipeline), а не
    # "дельта, згенерована з legacy-фікстури, відтворює legacy-фікстуру".
    #
    # Кроки навмисно ті самі функції, що й реальні інструменти оператора:
    #   Compare-BRAVOConfigurationGraph      -- те саме, що deploy\Get-BRAVOConfigSiteDelta.ps1
    #   ConvertTo-BRAVONestedOverride        -- те саме, що BRAVO_CONFIG_LOADER.ps1 для BRAVO.local.config
    #   Merge-BRAVOConfiguration             -- те саме, що Resolve-BRAVORawConfiguration
    # Текстовий рендер/парсинг BRAVO.local.config (AST-парсер у
    # BRAVO.Configuration.DataFile) тут навмисно НЕ бере участі: він має
    # власне окреме покриття (DataFile/* вище) і не є частиною семантики
    # merge/delta, яку доводить саме цей тест.
    $pilotDefaults = Get-BRAVODefaultConfiguration
    $pilotLegacyRawOverrides = @{
        bravoSettings = @{ InstitutionName = 'Синтетична Лікарня Pilot' }
        maintenanceSettings = @{ Limits = @{ ExcludedDrives = @('D:\', 'E:\') } }
        hostInformationSettings = @{ PublicIPLookupEnabled = $false }
        backupMonitoring = @{ SFTP = @{ BAZA = @{ AutoArchiveMutationThreshold = 40 } } }
        credentialSettings = @{ SFTPPassword = 'BRAVO_SFTP_PASSWORD_PILOT_SITE' }
        sftpHostTemplate = ''
    }
    # "BEFORE" = ефективна конфігурація сервера з наявним BRAVO.config
    # (тут — синтетична legacy-фікстура замість реального файлу).
    $pilotBefore = Merge-BRAVOConfiguration -Base $pilotDefaults -Override $pilotLegacyRawOverrides

    # Крок generate delta (двічі — доказ ідемпотентності: та сама пара
    # графів на вході завжди дає той самий упорядкований набір відмінностей).
    $pilotDeltaRun1 = @(Compare-BRAVOConfigurationGraph -ReferenceConfiguration $pilotDefaults -CandidateConfiguration $pilotLegacyRawOverrides)
    $pilotDeltaRun2 = @(Compare-BRAVOConfigurationGraph -ReferenceConfiguration $pilotDefaults -CandidateConfiguration $pilotLegacyRawOverrides)
    $pilotDeltaRun1Paths = [string]::Join('|', @($pilotDeltaRun1 | ForEach-Object { "$($_.Path)=$($_.CandidateValue)" }))
    $pilotDeltaRun2Paths = [string]::Join('|', @($pilotDeltaRun2 | ForEach-Object { "$($_.Path)=$($_.CandidateValue)" }))
    Test-BRAVOCondition `
        -Condition ($pilotDeltaRun1.Count -gt 0 -and $pilotDeltaRun1Paths -ceq $pilotDeltaRun2Paths) `
        -Name "PilotSafety/DeltaGenerationIsIdempotent" `
        -Failure "повторна генерація дельти з тим самим входом мусить дати той самий упорядкований результат; run1=[$pilotDeltaRun1Paths] run2=[$pilotDeltaRun2Paths]"

    # Крок "construct v2/local representation": те, що оператор вставив би
    # у BRAVO.local.config, — плаский dot-path override для кожного
    # Changed/OnlyInCandidate запису (те саме правило вибору, що
    # deploy\Get-BRAVOConfigSiteDelta.ps1 застосовує до свого виводу).
    $pilotFlatOverrides = @{}
    foreach ($d in $pilotDeltaRun1) {
        if ($d.Kind -eq 'Changed' -or $d.Kind -eq 'OnlyInCandidate') {
            $pilotFlatOverrides[[string]$d.Path] = $d.CandidateValue
        }
    }
    $pilotNestedOverrides = ConvertTo-BRAVONestedOverride -DotPathOverrides $pilotFlatOverrides -ReferenceConfiguration $pilotDefaults

    # "AFTER" = ефективна конфігурація сервера БЕЗ BRAVO.config, лише з
    # BRAVO.local.config, що містить згенеровану дельту.
    $pilotAfter = Merge-BRAVOConfiguration -Base $pilotDefaults -Override $pilotNestedOverrides

    # Семантичне порівняння (не текстове): той самий Compare-
    # BRAVOConfigurationGraph, з -IncludeMissingInCandidate, щоб зникнення
    # ключа теж зареєструвалось як відмінність, а не мовчки пройшло як
    # "діє дефолт".
    $pilotParityDiff = @(Compare-BRAVOConfigurationGraph -ReferenceConfiguration $pilotBefore -CandidateConfiguration $pilotAfter -IncludeMissingInCandidate)
    $pilotParityDiffPaths = @($pilotParityDiff | ForEach-Object { "$($_.Path) ($($_.Kind)): '$($_.ReferenceValue)' -> '$($_.CandidateValue)'" })
    Test-BRAVOCondition `
        -Condition ($pilotParityDiff.Count -eq 0) `
        -Name "PilotSafety/EndToEndParityBeforeEqualsAfter" `
        -Failure "EffectiveConfig(original) має дорівнювати EffectiveConfig(defaults + згенерована дельта) семантично; знайдено $($pilotParityDiff.Count) відмінностей: $([string]::Join('; ', $pilotParityDiffPaths))"

    # Ідемпотентність усього конвеєра "construct + merge", не лише самої
    # генерації дельти вище: та сама flat-дельта, застосована двічі
    # незалежно, має дати побітово той самий AFTER-граф.
    $pilotNestedOverrides2 = ConvertTo-BRAVONestedOverride -DotPathOverrides $pilotFlatOverrides -ReferenceConfiguration $pilotDefaults
    $pilotAfter2 = Merge-BRAVOConfiguration -Base $pilotDefaults -Override $pilotNestedOverrides2
    $pilotReapplyDiff = @(Compare-BRAVOConfigurationGraph -ReferenceConfiguration $pilotAfter -CandidateConfiguration $pilotAfter2 -IncludeMissingInCandidate)
    Test-BRAVOCondition `
        -Condition ($pilotReapplyDiff.Count -eq 0) `
        -Name "PilotSafety/ConstructAndMergeIsIdempotent" `
        -Failure "повторне застосування тієї самої дельти (construct+merge) мусить дати той самий AFTER-граф; знайдено $($pilotReapplyDiff.Count) відмінностей"

    # --- PilotSafety/CredentialReferenceNeverResolved ---
    # Секретна безпека: credentialSettings у AFTER лишається символічним
    # посиланням (те, що прийшло з legacy-фікстури як РЯДОК-ім'я запису
    # Credential Manager), а НЕ якимось резолвнутим значенням. Якби десь
    # у merge/delta/construct конвеєрі відбувалась підстановка реального
    # секрету замість імені — це значення відрізнялось би від вхідного
    # рядка фікстури.
    Test-BRAVOCondition `
        -Condition (
            [string]$pilotAfter.credentialSettings.SFTPPassword -eq 'BRAVO_SFTP_PASSWORD_PILOT_SITE'
        ) `
        -Name "PilotSafety/CredentialReferenceNeverResolved" `
        -Failure "credentialSettings.SFTPPassword після повного конвеєра має лишатись ТОЧНО тим самим рядком-посиланням, що прийшов із legacy-фікстури ('BRAVO_SFTP_PASSWORD_PILOT_SITE'), не резолвнутим значенням; отримано '$($pilotAfter.credentialSettings.SFTPPassword)'"
}
