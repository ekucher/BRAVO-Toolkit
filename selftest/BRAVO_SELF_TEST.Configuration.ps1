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

        # --- Delta/TypeChangeIsNotHiddenByCoercion ---
        # Регресія на реальний дефект (рев'ю #205): оператори PowerShell
        # приводять типи, тож $true -eq 1 і [string]30 -ceq '30' дають
        # True. Для доказу міграції це дірка: значення, що з $true стало
        # 1, змінює тип у JSON і в ефективній конфігурації, але
        # порівняння оголосило б його незмінним.
        $deltaTypeBool = @{ Enabled = $true }
        $deltaTypeInt = @{ Enabled = 1 }
        $deltaTypeBoolVsInt = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration $deltaTypeBool -CandidateConfiguration $deltaTypeInt)
        $deltaTypeFalseVsZero = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ Enabled = $false } -CandidateConfiguration @{ Enabled = 0 })
        $deltaTypeNumVsString = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ Days = 30 } -CandidateConfiguration @{ Days = '30' })
        # Той самий дефект усередині масиву словників — шлях, доданий цим
        # же PR.
        $deltaTypeInArray = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ defs = @(@{ Enabled = $true }) } `
            -CandidateConfiguration @{ defs = @(@{ Enabled = 1 }) })
        # НЕГАТИВНИЙ контроль: Int32 і Int64 з тим самим значенням — це НЕ
        # відмінність. Інакше звичайний JSON-цикл (який робить з Int32
        # Int64) давав би хибну відмінність на двох ІДЕНТИЧНИХ знімках і
        # знецінив би весь доказ.
        $deltaTypeIntWidth = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ Days = [int32]30 } -CandidateConfiguration @{ Days = [int64]30 })
        Test-BRAVOCondition `
            -Condition (
                $deltaTypeBoolVsInt.Count -eq 1 -and
                $deltaTypeFalseVsZero.Count -eq 1 -and
                $deltaTypeNumVsString.Count -eq 1 -and
                $deltaTypeInArray.Count -eq 1 -and
                $deltaTypeIntWidth.Count -eq 0
            ) `
            -Name "Delta/TypeChangeIsNotHiddenByCoercion" `
            -Failure ("зміна ТИПУ значення має лишатись видимою відмінністю, а різна ширина цілого — ні; " +
                "bool/int=$($deltaTypeBoolVsInt.Count) (1), false/0=$($deltaTypeFalseVsZero.Count) (1), " +
                "num/string=$($deltaTypeNumVsString.Count) (1), у масиві=$($deltaTypeInArray.Count) (1), " +
                "Int32/Int64=$($deltaTypeIntWidth.Count) (0)")

        # --- Delta/ArraysOfDictionariesCompareStructurally ---
        # Регресія на реальний дефект (рев'ю #203): гілка колекцій
        # рекурсувала в Test-BRAVOConfigurationValueEquality, а той
        # БЕЗУМОВНО повертав false для будь-якого словника. Наслідок:
        # $global:archiveDefinitions — масив із трьох hashtable — завжди
        # звітував "Changed", тож два ІДЕНТИЧНІ знімки ефективної
        # конфігурації ніколи не могли зійтись, і доказ міграції був
        # недосяжним за побудовою.
        $deltaDictArray = @{
            archiveDefinitions = @(
                @{ Type = 'MODEL'; Enabled = $true; Source = 'D:\a' },
                @{ Type = 'BLOG'; Enabled = $false; Source = 'D:\b' }
            )
        }
        $deltaDictArrayCopy = @{
            archiveDefinitions = @(
                @{ Type = 'MODEL'; Enabled = $true; Source = 'D:\a' },
                @{ Type = 'BLOG'; Enabled = $false; Source = 'D:\b' }
            )
        }
        $deltaDictArraySame = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration $deltaDictArray `
            -CandidateConfiguration $deltaDictArrayCopy)
        # Позитивний контроль: справжня відмінність усередині словника
        # масиву мусить лишитись видимою — фікс не сміє "зрівняти все".
        $deltaDictArrayChangedCandidate = @{
            archiveDefinitions = @(
                @{ Type = 'MODEL'; Enabled = $true; Source = 'D:\a' },
                @{ Type = 'BLOG'; Enabled = $false; Source = 'D:\ІНШЕ' }
            )
        }
        $deltaDictArrayChanged = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration $deltaDictArray `
            -CandidateConfiguration $deltaDictArrayChangedCandidate)
        # Другий контроль: зайвий ключ у словнику теж є відмінністю.
        $deltaDictArrayExtraKey = @{
            archiveDefinitions = @(
                @{ Type = 'MODEL'; Enabled = $true; Source = 'D:\a'; Extra = 1 },
                @{ Type = 'BLOG'; Enabled = $false; Source = 'D:\b' }
            )
        }
        $deltaDictArrayExtra = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration $deltaDictArray `
            -CandidateConfiguration $deltaDictArrayExtraKey)
        Test-BRAVOCondition `
            -Condition (
                $deltaDictArraySame.Count -eq 0 -and
                $deltaDictArrayChanged.Count -eq 1 -and
                $deltaDictArrayExtra.Count -eq 1
            ) `
            -Name "Delta/ArraysOfDictionariesCompareStructurally" `
            -Failure "масив словників має порівнюватись структурно: однакові=$($deltaDictArraySame.Count) (очікується 0), змінене значення=$($deltaDictArrayChanged.Count) (1), зайвий ключ=$($deltaDictArrayExtra.Count) (1)"

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

        # --- Delta/ArrayOfHashtableElementsComparedStructurally ---
        # #154 крок 2: archiveDefinitions/bazaSyncEffective.Components —
        # реальні масиви ХЕШ-ТАБЛИЦЬ, не рядків. Test-BRAVOConfigurationValueEquality
        # раніше безумовно повертав $false для будь-якого елемента-словника
        # (fail-safe для вузлів графа) — це означало, що ІДЕНТИЧНИЙ масив
        # об'єктів завжди звітував про зміну (знайдено першим реальним
        # прогоном pilot-артефакту Configuration v2 semantic parity).
        $deltaHashArraySame = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ archiveDefinitions = @(@{ Type = 'MODEL'; Enabled = $true }, @{ Type = 'BLOG'; Enabled = $true }) } `
            -CandidateConfiguration @{ archiveDefinitions = @(@{ Type = 'MODEL'; Enabled = $true }, @{ Type = 'BLOG'; Enabled = $true }) })
        $deltaHashArrayChanged = @(Compare-BRAVOConfigurationGraph `
            -ReferenceConfiguration @{ archiveDefinitions = @(@{ Type = 'MODEL'; Enabled = $true }) } `
            -CandidateConfiguration @{ archiveDefinitions = @(@{ Type = 'MODEL'; Enabled = $false }) })
        Test-BRAVOCondition `
            -Condition ($deltaHashArraySame.Count -eq 0 -and $deltaHashArrayChanged.Count -eq 1) `
            -Name "Delta/ArrayOfHashtableElementsComparedStructurally" `
            -Failure "масив ідентичних hashtable-елементів не повинен звітувати про зміну, а реально інший — повинен (отримано $($deltaHashArraySame.Count)/$($deltaHashArrayChanged.Count))"

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
# Wave 2 (#216): авторизація local-override шляхів BRAVO.local.config
# =====================================================================
# Окремий child scope (& { ... }) — з тієї самої причини, що й решта
# фрагментів вище: усі фрагменти self-test дот-сорсяться в ОДИН scope.
& {
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.psd1') -Force
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Schema.psd1') -Force

    $authDefaults = Get-BRAVODefaultConfiguration
    $authSchema = Get-BRAVOConfigurationSchema -ReferenceConfiguration $authDefaults
    $authRegistry = Get-BRAVOConfigurationSchemaAuthorizationClass
    $authLeaves = @(@($authSchema.Keys) | Where-Object { [string]$authSchema[$_].Kind -ne 'Node' })
    $authKnownClasses = @('ALLOW_SITE', 'ALLOW_WITH_VALIDATOR', 'DENY_DERIVED', 'DENY_CREDENTIAL_BACKED', 'DENY_SECURITY_CONTROL', 'DENY_EXECUTION_CONTROL', 'DENY_INTERNAL_METADATA')

    # --- Authorization/RegistryCoversEveryCanonicalLeaf ---
    # Wave 2 (WAVE2-CONTRACT.md, розділ 8/11.3): кожен канонічний лист
    # мусить мати ЯВНИЙ запис класу — мовчазний allow-by-omission
    # заборонений архітектурним рішенням.
    $authMissingLeaves = @(@($authLeaves) | Where-Object { -not $authRegistry.Contains([string]$_) })
    $authOrphanEntries = @(@($authRegistry.Keys) | Where-Object { $authLeaves -notcontains [string]$_ })
    Test-BRAVOCondition `
        -Condition ($authMissingLeaves.Count -eq 0 -and $authOrphanEntries.Count -eq 0) `
        -Name "Authorization/RegistryCoversEveryCanonicalLeaf" `
        -Failure "авторизаційний реєстр мусить мати рівно один запис на кожен канонічний лист: відсутні=$($authMissingLeaves.Count) ($([string]::Join(', ', $authMissingLeaves))), осиротілі=$($authOrphanEntries.Count) ($([string]::Join(', ', $authOrphanEntries)))"

    # --- Authorization/Exactly271CanonicalLeaves ---
    Test-BRAVOCondition `
        -Condition ($authLeaves.Count -eq 271) `
        -Name "Authorization/Exactly271CanonicalLeaves" `
        -Failure "WAVE2-CONTRACT.md фіксує рівно 271 канонічний лист; фактично отримано $($authLeaves.Count) — контракт і схема розійшлися, потребує повторного узгодження, а не мовчазної зміни очікуваного числа"

    # --- Authorization/AllClassesRecognized ---
    $authUnrecognizedClasses = @(@($authRegistry.Values) | ForEach-Object { [string]$_.Class } | Where-Object { $authKnownClasses -notcontains $_ } | Select-Object -Unique)
    Test-BRAVOCondition `
        -Condition ($authUnrecognizedClasses.Count -eq 0) `
        -Name "Authorization/AllClassesRecognized" `
        -Failure "кожен запис реєстру мусить використовувати один із 7 визнаних класів; знайдено невідомі: $([string]::Join(', ', $authUnrecognizedClasses))"

    # --- Authorization/ClassCountsMatchContract ---
    # Точні підрахунки з WAVE2-CONTRACT.md (розділ 1/7, owner-approved
    # 2026-09-21): ALLOW_SITE=200, ALLOW_WITH_VALIDATOR=25, DENY_DERIVED=2,
    # DENY_CREDENTIAL_BACKED=0, DENY_SECURITY_CONTROL=6,
    # DENY_EXECUTION_CONTROL=21, DENY_INTERNAL_METADATA=17.
    $authClassGroups = @($authRegistry.Values) | Group-Object { [string]$_.Class }
    function Get-BRAVOAuthTestClassCount {
        param([array]$Groups, [string]$ClassName)
        $match = @(@($Groups) | Where-Object { $_.Name -eq $ClassName })
        if ($match.Count -eq 0) { return 0 }
        return $match[0].Count
    }
    $authAllowSiteCount = Get-BRAVOAuthTestClassCount -Groups $authClassGroups -ClassName 'ALLOW_SITE'
    $authAllowValidatorCount = Get-BRAVOAuthTestClassCount -Groups $authClassGroups -ClassName 'ALLOW_WITH_VALIDATOR'
    $authDenyDerivedCount = Get-BRAVOAuthTestClassCount -Groups $authClassGroups -ClassName 'DENY_DERIVED'
    $authDenyCredentialCount = Get-BRAVOAuthTestClassCount -Groups $authClassGroups -ClassName 'DENY_CREDENTIAL_BACKED'
    $authDenySecurityCount = Get-BRAVOAuthTestClassCount -Groups $authClassGroups -ClassName 'DENY_SECURITY_CONTROL'
    $authDenyExecutionCount = Get-BRAVOAuthTestClassCount -Groups $authClassGroups -ClassName 'DENY_EXECUTION_CONTROL'
    $authDenyInternalCount = Get-BRAVOAuthTestClassCount -Groups $authClassGroups -ClassName 'DENY_INTERNAL_METADATA'
    # PR #224 review, N3 (2026-09-22): sftpDirectories.BAZA/BAZAWWW
    # пере-класифіковано DENY_DERIVED -> ALLOW_SITE (доведено трасою:
    # BRAVO.Configuration.Derivation.psm1:285-288, "sftpDirectories — уже
    # повністю raw-параметр", пряма проєкція без деривації; та
    # Get-BRAVOEffectiveSynchronizationConfiguration передає
    # $SftpDirectories['BAZA']/['BAZAWWW'] as-is, без обчислення). ALLOW_SITE
    # 200->202, DENY_DERIVED 2->0, TOTAL лишається 271, решта класів
    # незмінні.
    Test-BRAVOCondition `
        -Condition (
            $authAllowSiteCount -eq 202 -and $authAllowValidatorCount -eq 25 -and
            $authDenyDerivedCount -eq 0 -and $authDenyCredentialCount -eq 0 -and
            $authDenySecurityCount -eq 6 -and $authDenyExecutionCount -eq 21 -and
            $authDenyInternalCount -eq 17
        ) `
        -Name "Authorization/ClassCountsMatchContract" `
        -Failure "class counts мусять точно збігатись з WAVE2-CONTRACT.md (з урахуванням N3-корекції sftpDirectories.BAZA/BAZAWWW): ALLOW_SITE=$authAllowSiteCount(202) ALLOW_WITH_VALIDATOR=$authAllowValidatorCount(25) DENY_DERIVED=$authDenyDerivedCount(0) DENY_CREDENTIAL_BACKED=$authDenyCredentialCount(0) DENY_SECURITY_CONTROL=$authDenySecurityCount(6) DENY_EXECUTION_CONTROL=$authDenyExecutionCount(21) DENY_INTERNAL_METADATA=$authDenyInternalCount(17)"

    # --- Authorization/EveryValidatorIdentifierResolves ---
    # Кожен ALLOW_WITH_VALIDATOR-запис мусить посилатись на валідатор,
    # який РЕАЛЬНО диспетчерується (не кидає "невідомий ідентифікатор").
    # Перевіряємо на заздалегідь відомому правдоподібному значенні для
    # кожного validator-класу; для деяких валідаторів (Enum/IntegerRange)
    # правдоподібне значення обчислюємо з самого ідентифікатора.
    $authValidatorEntries = @(@($authRegistry.GetEnumerator()) | Where-Object { [string]$_.Value.Class -eq 'ALLOW_WITH_VALIDATOR' })
    $authUnresolvedValidators = New-Object System.Collections.Generic.List[string]
    foreach ($authEntry in $authValidatorEntries) {
        $authValidatorId = [string]$authEntry.Value.Validator
        $authProbeValue = $null
        if ($authValidatorId.StartsWith('Enum:')) {
            $authProbeValue = ($authValidatorId.Substring(5) -split ',')[0]
        } elseif ($authValidatorId.StartsWith('IntegerRange:')) {
            $authProbeValue = [int](($authValidatorId.Substring(13) -split ',')[0])
        } elseif ($authValidatorId -eq 'WindowsCodePage') {
            $authProbeValue = 65001
        } elseif ($authValidatorId -eq 'DotNetEncodingName') {
            $authProbeValue = 'UTF8'
        } elseif ($authValidatorId.StartsWith('UrlArray:')) {
            $authProbeValue = @('https://example.invalid/ip')
        } elseif ($authValidatorId -eq 'TaskSchedulerPath') {
            $authProbeValue = '\BRAVO\'
        } elseif ($authValidatorId -eq 'NonEmptyString') {
            $authProbeValue = 'probe-value'
        }
        try {
            [void](Test-BRAVOConfigurationAuthorizationValidatorValue -ValidatorId $authValidatorId -Value $authProbeValue -Path ([string]$authEntry.Key))
        } catch {
            [void]$authUnresolvedValidators.Add("$($authEntry.Key) -> $authValidatorId ($($_.Exception.Message))")
        }
    }
    Test-BRAVOCondition `
        -Condition ($authUnresolvedValidators.Count -eq 0) `
        -Name "Authorization/EveryValidatorIdentifierResolves" `
        -Failure "кожен Validator-ідентифікатор у реєстрі мусить реально диспетчеруватись Test-BRAVOConfigurationAuthorizationValidatorValue без throw; нерозв'язані: $([string]::Join(' | ', $authUnresolvedValidators))"

    # --- Authorization/UnknownValidatorIdFailsClosed ---
    $authUnknownValidatorThrew = $false
    try {
        [void](Test-BRAVOConfigurationAuthorizationValidatorValue -ValidatorId 'NoSuchValidator:1,2' -Value 'x' -Path 'probe.path')
    } catch {
        $authUnknownValidatorThrew = $true
    }
    Test-BRAVOCondition `
        -Condition $authUnknownValidatorThrew `
        -Name "Authorization/UnknownValidatorIdFailsClosed" `
        -Failure "невідомий ідентифікатор валідатора мусить FAIL CLOSED (throw), а не мовчазний accept"

    # --- Authorization/AllowSiteAccepted ---
    $authAllowSiteResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'archiveRetentionDays' = 45 } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ([bool]$authAllowSiteResult.IsValid) `
        -Name "Authorization/AllowSiteAccepted" `
        -Failure "ALLOW_SITE лист (archiveRetentionDays) мусить бути прийнятий без додаткових умов"

    # --- Authorization/AllowWithValidatorValidAccepted ---
    $authValidValidatorResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'robocopyMaxSuccessExitCode' = 7 } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ([bool]$authValidValidatorResult.IsValid) `
        -Name "Authorization/AllowWithValidatorValidAccepted" `
        -Failure "robocopyMaxSuccessExitCode=7 (в межах 0..7) мусить бути прийнятий"

    # --- Authorization/AllowWithValidatorInvalidRejected ---
    $authInvalidValidatorResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'robocopyMaxSuccessExitCode' = 8 } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authInvalidValidatorResult.IsValid -and $authInvalidValidatorResult.Violations.Count -eq 1 -and [string]$authInvalidValidatorResult.Violations[0].Path -eq 'robocopyMaxSuccessExitCode') `
        -Name "Authorization/AllowWithValidatorInvalidRejected" `
        -Failure "robocopyMaxSuccessExitCode=8 (поза 0..7) мусить бути відхилений з точним rejected path"

    # =====================================================================
    # PR #224 review, N2: TaskSchedulerPath-валідатор раніше вимагав, щоб
    # СИРЕ значення вже було у нормалізованій формі '\...\' — суворіше за
    # канонічний runtime-контракт ConvertTo-BRAVOTaskPath
    # (modules/BRAVO.System/BRAVO.System.psm1), який приймає 'BRAVO',
    # '\BRAVO', 'BRAVO\' і нормалізує сам. Фікс — авторизація тепер РЕАЛЬНО
    # викликає ConvertTo-BRAVOTaskPath (не дублює його regex-граматику) і
    # трактує виняток як IsValid=$false. Матриця нижче доводить паритет
    # прийняття/відхилення між авторизацією й самим нормалізатором на
    # ідентичних значеннях.
    # =====================================================================
    if (-not (Get-Module -Name 'BRAVO.System')) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.System\BRAVO.System.psd1') -Force
    }

    $taskPathAcceptedValues = @('BRAVO', '\BRAVO', 'BRAVO\', '\BRAVO\', '  BRAVO', 'BRAVO  ', '\')
    $taskPathParityMismatches = New-Object System.Collections.Generic.List[string]
    foreach ($taskPathValue in $taskPathAcceptedValues) {
        $normalizerThrew = $false
        try { [void](ConvertTo-BRAVOTaskPath -TaskPath $taskPathValue) } catch { $normalizerThrew = $true }
        $authResult = Test-BRAVOConfigurationAuthorizationValidatorValue -ValidatorId 'TaskSchedulerPath' -Value $taskPathValue -Path 'schedulerSettings.TaskPath'
        if ($normalizerThrew -or -not [bool]$authResult.IsValid) {
            [void]$taskPathParityMismatches.Add("ACCEPT-case '$taskPathValue': normalizerThrew=$normalizerThrew authValid=$($authResult.IsValid)")
        }
    }
    Test-BRAVOCondition `
        -Condition ($taskPathParityMismatches.Count -eq 0) `
        -Name "Authorization/TaskSchedulerPathAcceptsHistoricalNormalizerForms" `
        -Failure "усі історично прийнятні форми TaskPath ('BRAVO','\BRAVO','BRAVO\','\BRAVO\','  BRAVO','BRAVO  ','\') мусять бути прийняті і нормалізатором, і авторизацією; розбіжності: $($taskPathParityMismatches -join '; ')"

    $taskPathRejectedValues = @('A/B', 'A:B', 'A*', 'A?', 'A"', 'A<', 'A>', 'A|', '.', '..', 'A\..\B', 'A\.\B', '   ')
    $taskPathRejectParityMismatches = New-Object System.Collections.Generic.List[string]
    foreach ($taskPathValue in $taskPathRejectedValues) {
        $normalizerThrew = $false
        try { [void](ConvertTo-BRAVOTaskPath -TaskPath $taskPathValue) } catch { $normalizerThrew = $true }
        $authResult = Test-BRAVOConfigurationAuthorizationValidatorValue -ValidatorId 'TaskSchedulerPath' -Value $taskPathValue -Path 'schedulerSettings.TaskPath'
        if (-not $normalizerThrew -or [bool]$authResult.IsValid) {
            [void]$taskPathRejectParityMismatches.Add("REJECT-case '$taskPathValue': normalizerThrew=$normalizerThrew authValid=$($authResult.IsValid)")
        }
    }
    Test-BRAVOCondition `
        -Condition ($taskPathRejectParityMismatches.Count -eq 0) `
        -Name "Authorization/TaskSchedulerPathRejectsInvalidFormsSameAsNormalizer" `
        -Failure "усі історично неприпустимі форми TaskPath мусять бути відхилені і нормалізатором, і авторизацією; розбіжності: $($taskPathRejectParityMismatches -join '; ')"

    # --- Authorization/TaskSchedulerPathRejectsNonStringAndNull ---
    $taskPathNullResult = Test-BRAVOConfigurationAuthorizationValidatorValue -ValidatorId 'TaskSchedulerPath' -Value $null -Path 'schedulerSettings.TaskPath'
    $taskPathBoolResult = Test-BRAVOConfigurationAuthorizationValidatorValue -ValidatorId 'TaskSchedulerPath' -Value $true -Path 'schedulerSettings.TaskPath'
    $taskPathIntResult = Test-BRAVOConfigurationAuthorizationValidatorValue -ValidatorId 'TaskSchedulerPath' -Value 7 -Path 'schedulerSettings.TaskPath'
    Test-BRAVOCondition `
        -Condition ((-not [bool]$taskPathNullResult.IsValid) -and (-not [bool]$taskPathBoolResult.IsValid) -and (-not [bool]$taskPathIntResult.IsValid)) `
        -Name "Authorization/TaskSchedulerPathRejectsNonStringAndNull" `
        -Failure "`$null/Boolean/Integer мусять лишитись відхиленими; отримано Null=$($taskPathNullResult.IsValid) Bool=$($taskPathBoolResult.IsValid) Int=$($taskPathIntResult.IsValid)"

    # --- Authorization/TaskSchedulerPathValidationDoesNotMutateOriginalValue ---
    $taskPathMutationProbeOverrides = @{ 'schedulerSettings.TaskPath' = 'BRAVO' }
    [void](Test-BRAVOConfigurationOverrideAuthorization -DotPathOverrides $taskPathMutationProbeOverrides -Schema $authSchema)
    Test-BRAVOCondition `
        -Condition ([string]$taskPathMutationProbeOverrides['schedulerSettings.TaskPath'] -eq 'BRAVO') `
        -Name "Authorization/TaskSchedulerPathValidationDoesNotMutateOriginalValue" `
        -Failure "авторизація НЕ повинна нормалізувати/мутувати сире значення на місці; отримано '$($taskPathMutationProbeOverrides['schedulerSettings.TaskPath'])' замість 'BRAVO'"

    # =====================================================================
    # PR #224 review, F3: enum-валідатор БЕЗ trim відхиляв би значення на
    # кшталт ' all ' (з пробілами), хоча щонайменше два ALLOW_WITH_VALIDATOR
    # enum-листи (bravoSettings.NotificationMode/NotificationProvider)
    # мають ДОВЕДЕНУ pre-Wave-2 нормалізацію .Trim().ToLowerInvariant() на
    # ВСІХ реальних runtime-точках споживання (BRAVO_DRY_RUN.ps1 x4,
    # BRAVO_NOTIFICATION_TEST.ps1, BRAVO_RESTORE_TEST.ps1). Фікс — окремий
    # named-валідатор 'EnumTrimmed:' (НЕ узагальнене послаблення 'Enum:'
    # для всіх 18 enum-листів без доказу) — Test-BRAVOConfigurationAuthorizationEnumValue
    # порівнює з Trim(), значення при цьому НЕ мутується.
    # =====================================================================

    # --- Authorization/NotificationModeWhitespaceTolerated ---
    $authNotifModeWhitespaceResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'bravoSettings.NotificationMode' = ' all ' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ([bool]$authNotifModeWhitespaceResult.IsValid) `
        -Name "Authorization/NotificationModeWhitespaceTolerated" `
        -Failure "bravoSettings.NotificationMode=' all ' (пробіли) мусить бути прийнятий — усі runtime-споживачі вже роблять .Trim() перед використанням; отримано IsValid=$($authNotifModeWhitespaceResult.IsValid)"

    # --- Authorization/NotificationModeStillRejectsGenuinelyInvalidValue ---
    $authNotifModeInvalidResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'bravoSettings.NotificationMode' = ' definitely-invalid ' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authNotifModeInvalidResult.IsValid) `
        -Name "Authorization/NotificationModeStillRejectsGenuinelyInvalidValue" `
        -Failure "trim-tolerance НЕ повинна ослабити реальну enum-перевірку — ' definitely-invalid ' мусить лишитись відхиленим; отримано IsValid=$($authNotifModeInvalidResult.IsValid)"

    # --- Authorization/NotificationModeNonStringStillRejected ---
    $authNotifModeNonStringResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'bravoSettings.NotificationMode' = 5 } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authNotifModeNonStringResult.IsValid) `
        -Name "Authorization/NotificationModeNonStringStillRejected" `
        -Failure "не-рядкове значення мусить лишитись відхиленим навіть для EnumTrimmed-валідатора (Trim — лише для рядків); отримано IsValid=$($authNotifModeNonStringResult.IsValid)"

    # --- Authorization/NotificationModeBooleanStillRejected ---
    $authNotifModeBooleanResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'bravoSettings.NotificationMode' = $true } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authNotifModeBooleanResult.IsValid) `
        -Name "Authorization/NotificationModeBooleanStillRejected" `
        -Failure "Boolean `$true мусить лишитись відхиленим навіть для EnumTrimmed-валідатора (Trim — лише для рядків, не для Boolean-to-string коерсії); отримано IsValid=$($authNotifModeBooleanResult.IsValid)"

    # --- Authorization/NotificationModeNullStillRejected ---
    $authNotifModeNullResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'bravoSettings.NotificationMode' = $null } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authNotifModeNullResult.IsValid) `
        -Name "Authorization/NotificationModeNullStillRejected" `
        -Failure "`$null мусить лишитись відхиленим і для EnumTrimmed-валідатора; отримано IsValid=$($authNotifModeNullResult.IsValid)"

    # --- Authorization/EnumTrimmedValidationDoesNotMutateOriginalValue ---
    # Валідація — лише перевірка; саме значення, що йде далі в merge, не
    # повинно набувати обрізаної/lower-case форми звідси (той самий
    # незмінний runtime-consumer сам робить .Trim().ToLowerInvariant()).
    $authNotifModeMutationProbeValue = ' All '
    $authNotifModeMutationProbeOverrides = @{ 'bravoSettings.NotificationMode' = $authNotifModeMutationProbeValue }
    [void](Test-BRAVOConfigurationOverrideAuthorization -DotPathOverrides $authNotifModeMutationProbeOverrides -Schema $authSchema)
    Test-BRAVOCondition `
        -Condition ([string]$authNotifModeMutationProbeOverrides['bravoSettings.NotificationMode'] -eq $authNotifModeMutationProbeValue) `
        -Name "Authorization/EnumTrimmedValidationDoesNotMutateOriginalValue" `
        -Failure "Test-BRAVOConfigurationOverrideAuthorization НЕ повинен мутувати вхідне значення на місці (Trim лише для внутрішнього порівняння); отримано '$($authNotifModeMutationProbeOverrides['bravoSettings.NotificationMode'])' замість очікуваного '$authNotifModeMutationProbeValue'"

    # --- Authorization/NotificationModeWhitespaceAndCaseBothTolerated ---
    $authNotifModeCaseWhitespaceResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'bravoSettings.NotificationMode' = ' ALL ' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ([bool]$authNotifModeCaseWhitespaceResult.IsValid) `
        -Name "Authorization/NotificationModeWhitespaceAndCaseBothTolerated" `
        -Failure "trim і case-insensitive порівняння мусять діяти РАЗОМ (' ALL ' -> 'all'); отримано IsValid=$($authNotifModeCaseWhitespaceResult.IsValid)"

    # --- Authorization/NotificationProviderWhitespaceTolerated ---
    $authNotifProviderWhitespaceResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'bravoSettings.NotificationProvider' = ' discord ' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ([bool]$authNotifProviderWhitespaceResult.IsValid) `
        -Name "Authorization/NotificationProviderWhitespaceTolerated" `
        -Failure "bravoSettings.NotificationProvider=' discord ' мусить бути прийнятий (та сама доведена trim-tolerance, що NotificationMode); отримано IsValid=$($authNotifProviderWhitespaceResult.IsValid)"

    # --- Authorization/OtherEnumLeavesRemainUntrimmedByDefault ---
    # Регресійна межа: інший enum-лист (maintenanceSettings.Logging.Level),
    # для якого НЕМАЄ доказу pre-Wave-2 trim-tolerance, мусить лишитись на
    # звичайному строгому 'Enum:' (без trim) — фікс не узагальнюється без
    # підстави. ConsoleLevel/FileLevel більше НЕ підходять для цього
    # регресійного зразка (R3-5, PR #224 third review): обидва тепер самі
    # мають доведену trim-tolerance і перевіряються окремим блоком нижче.
    $authOtherEnumWhitespaceResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'maintenanceSettings.Logging.Level' = ' WARNING ' } `
        -Schema $authSchema
    $authOtherEnumExactResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'maintenanceSettings.Logging.Level' = 'WARNING' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ((-not [bool]$authOtherEnumWhitespaceResult.IsValid) -and [bool]$authOtherEnumExactResult.IsValid) `
        -Name "Authorization/OtherEnumLeavesRemainUntrimmedByDefault" `
        -Failure "maintenanceSettings.Logging.Level НЕ має доказу trim-tolerance — з пробілами мусить відхилятись (IsValid=$($authOtherEnumWhitespaceResult.IsValid)), точне значення мусить і далі прийматись (IsValid=$($authOtherEnumExactResult.IsValid))"

    # --- Authorization/EnumTrimmedValidatorRegisteredForBothEvidencedPaths ---
    Test-BRAVOCondition `
        -Condition (
            ([string]$authRegistry['bravoSettings.NotificationMode'].Validator).StartsWith('EnumTrimmed:', [System.StringComparison]::Ordinal) -and
            ([string]$authRegistry['bravoSettings.NotificationProvider'].Validator).StartsWith('EnumTrimmed:', [System.StringComparison]::Ordinal)
        ) `
        -Name "Authorization/EnumTrimmedValidatorRegisteredForBothEvidencedPaths" `
        -Failure "реєстр мусить використовувати 'EnumTrimmed:' саме для NotificationMode/NotificationProvider; отримано NotificationMode=$($authRegistry['bravoSettings.NotificationMode'].Validator) NotificationProvider=$($authRegistry['bravoSettings.NotificationProvider'].Validator)"

    # =====================================================================
    # PR #224 third review, R3-5: consoleSettings.ConsoleLevel/FileLevel —
    # canonical runtime-споживач (Get-BRAVOLogSeverityValue,
    # modules/BRAVO.Logging/BRAVO.Logging.psm1) уже робить
    # .Trim().ToUpperInvariant() ДО порівняння з таблицею рівнів, тому ці
    # два листи мусять зберегти pre-Wave-2 tolerance до пробілів.
    # =====================================================================

    # --- Authorization/ConsoleLevelValidatorIsTrimmed ---
    Test-BRAVOCondition `
        -Condition (([string]$authRegistry['consoleSettings.ConsoleLevel'].Validator).StartsWith('EnumTrimmed:', [System.StringComparison]::Ordinal)) `
        -Name "Authorization/ConsoleLevelValidatorIsTrimmed" `
        -Failure "реєстр мусить використовувати 'EnumTrimmed:' для consoleSettings.ConsoleLevel; отримано $($authRegistry['consoleSettings.ConsoleLevel'].Validator)"

    # --- Authorization/FileLevelValidatorIsTrimmed ---
    Test-BRAVOCondition `
        -Condition (([string]$authRegistry['consoleSettings.FileLevel'].Validator).StartsWith('EnumTrimmed:', [System.StringComparison]::Ordinal)) `
        -Name "Authorization/FileLevelValidatorIsTrimmed" `
        -Failure "реєстр мусить використовувати 'EnumTrimmed:' для consoleSettings.FileLevel; отримано $($authRegistry['consoleSettings.FileLevel'].Validator)"

    # --- Preview/ConsoleLevelWhitespaceAccepted ---
    $r35ConsoleLevelWhitespaceResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'consoleSettings.ConsoleLevel' = ' ERROR ' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ([bool]$r35ConsoleLevelWhitespaceResult.IsValid) `
        -Name "Preview/ConsoleLevelWhitespaceAccepted" `
        -Failure "consoleSettings.ConsoleLevel=' ERROR ' мусить бути прийнятий (доведена trim-tolerance runtime-споживача); отримано IsValid=$($r35ConsoleLevelWhitespaceResult.IsValid)"

    # --- Preview/FileLevelWhitespaceAccepted ---
    $r35FileLevelWhitespaceResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'consoleSettings.FileLevel' = ' INFO ' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ([bool]$r35FileLevelWhitespaceResult.IsValid) `
        -Name "Preview/FileLevelWhitespaceAccepted" `
        -Failure "consoleSettings.FileLevel=' INFO ' мусить бути прийнятий (доведена trim-tolerance runtime-споживача); отримано IsValid=$($r35FileLevelWhitespaceResult.IsValid)"

    # --- Preview/ConsoleFileLevelInvalidValueStillRejected ---
    $r35ConsoleLevelInvalidResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'consoleSettings.ConsoleLevel' = ' NOTALEVEL ' } `
        -Schema $authSchema
    $r35FileLevelInvalidResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'consoleSettings.FileLevel' = ' NOTALEVEL ' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ((-not [bool]$r35ConsoleLevelInvalidResult.IsValid) -and (-not [bool]$r35FileLevelInvalidResult.IsValid)) `
        -Name "Preview/ConsoleFileLevelInvalidValueStillRejected" `
        -Failure "trim не повинен послаблювати перелік дозволених значень — невідомий рівень мусить лишитись відхиленим для обох листів; отримано ConsoleLevel.IsValid=$($r35ConsoleLevelInvalidResult.IsValid) FileLevel.IsValid=$($r35FileLevelInvalidResult.IsValid)"

    # --- Preview/ConsoleFileLevelNonStringStillRejected ---
    $r35ConsoleLevelNonStringResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'consoleSettings.ConsoleLevel' = 5 } `
        -Schema $authSchema
    $r35FileLevelNonStringResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'consoleSettings.FileLevel' = $true } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ((-not [bool]$r35ConsoleLevelNonStringResult.IsValid) -and (-not [bool]$r35FileLevelNonStringResult.IsValid)) `
        -Name "Preview/ConsoleFileLevelNonStringStillRejected" `
        -Failure "не-рядкове значення мусить лишитись відхиленим для обох листів навіть після EnumTrimmed; отримано ConsoleLevel.IsValid=$($r35ConsoleLevelNonStringResult.IsValid) FileLevel.IsValid=$($r35FileLevelNonStringResult.IsValid)"

    # --- Preview/ConsoleLevelValidationDoesNotMutateOriginalValue ---
    $r35ConsoleLevelMutationProbeValue = ' ERROR '
    $r35ConsoleLevelMutationProbeOverrides = @{ 'consoleSettings.ConsoleLevel' = $r35ConsoleLevelMutationProbeValue }
    [void](Test-BRAVOConfigurationOverrideAuthorization -DotPathOverrides $r35ConsoleLevelMutationProbeOverrides -Schema $authSchema)
    Test-BRAVOCondition `
        -Condition ([string]$r35ConsoleLevelMutationProbeOverrides['consoleSettings.ConsoleLevel'] -eq $r35ConsoleLevelMutationProbeValue) `
        -Name "Preview/ConsoleLevelValidationDoesNotMutateOriginalValue" `
        -Failure "Test-BRAVOConfigurationOverrideAuthorization НЕ повинен мутувати вхідне ConsoleLevel-значення на місці; отримано '$($r35ConsoleLevelMutationProbeOverrides['consoleSettings.ConsoleLevel'])' замість очікуваного '$r35ConsoleLevelMutationProbeValue'"

    # =====================================================================
    # PR #224 review, четвертий раунд (P2, "Preserve trimming for
    # defaultLogLevel"): Write-Log (modules/BRAVO.Archive/BRAVO.Archive.Runtime.ps1)
    # використовує $defaultLogLevel як default для параметра $Level і сам
    # нормалізує через `$Level.Trim().ToUpperInvariant()` ПЕРЕД
    # порівнянням з переліком рівнів — та сама доведена pre-Wave-2
    # tolerance-семантика, що NotificationMode/NotificationProvider/
    # ConsoleLevel/FileLevel вище. Раніше цей лист лишався на звичайному
    # 'Enum:' (без trim) — startup-регресія для існуючих
    # ' ERROR '-подібних значень.
    # =====================================================================

    # --- Configuration/DefaultLogLevelValidatorIsTrimmed ---
    Test-BRAVOCondition `
        -Condition (([string]$authRegistry['defaultLogLevel'].Validator).StartsWith('EnumTrimmed:', [System.StringComparison]::Ordinal)) `
        -Name "Configuration/DefaultLogLevelValidatorIsTrimmed" `
        -Failure "реєстр мусить використовувати 'EnumTrimmed:' для defaultLogLevel; отримано $($authRegistry['defaultLogLevel'].Validator)"

    # --- Configuration/DefaultLogLevelTrimmedAccepted (B1/B2) ---
    $defaultLogLevelErrorWhitespaceResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'defaultLogLevel' = ' ERROR ' } `
        -Schema $authSchema
    $defaultLogLevelInfoWhitespaceResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'defaultLogLevel' = ' INFO ' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ([bool]$defaultLogLevelErrorWhitespaceResult.IsValid -and [bool]$defaultLogLevelInfoWhitespaceResult.IsValid) `
        -Name "Configuration/DefaultLogLevelTrimmedAccepted" `
        -Failure "defaultLogLevel=' ERROR '/' INFO ' мусять бути прийняті (доведена trim-tolerance Write-Log); отримано ERROR.IsValid=$($defaultLogLevelErrorWhitespaceResult.IsValid) INFO.IsValid=$($defaultLogLevelInfoWhitespaceResult.IsValid)"

    # --- Configuration/DefaultLogLevelWhitespaceAndCaseBothTolerated (B3) ---
    # Write-Log сам робить .Trim().ToUpperInvariant(), а
    # Test-BRAVOConfigurationAuthorizationEnumValue завжди порівнює
    # case-insensitive (не лише для EnumTrimmed) — реальна runtime-
    # семантика й авторизація мусять узгоджуватись для мішаного case.
    $defaultLogLevelLowerWhitespaceResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'defaultLogLevel' = ' warning ' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ([bool]$defaultLogLevelLowerWhitespaceResult.IsValid) `
        -Name "Configuration/DefaultLogLevelWhitespaceAndCaseBothTolerated" `
        -Failure "defaultLogLevel=' warning ' (пробіли + нижній регістр) мусить бути прийнятий (той самий .Trim().ToUpperInvariant(), що Write-Log); отримано IsValid=$($defaultLogLevelLowerWhitespaceResult.IsValid)"

    # --- Configuration/DefaultLogLevelInvalidRejected (B4/B5) ---
    $defaultLogLevelInvalidResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'defaultLogLevel' = 'BOGUS' } `
        -Schema $authSchema
    $defaultLogLevelInvalidWhitespaceResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'defaultLogLevel' = ' BOGUS ' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ((-not [bool]$defaultLogLevelInvalidResult.IsValid) -and (-not [bool]$defaultLogLevelInvalidWhitespaceResult.IsValid)) `
        -Name "Configuration/DefaultLogLevelInvalidRejected" `
        -Failure "trim не повинен послаблювати перелік дозволених значень — 'BOGUS'/' BOGUS ' мусять лишитись відхиленими; отримано Exact.IsValid=$($defaultLogLevelInvalidResult.IsValid) Whitespace.IsValid=$($defaultLogLevelInvalidWhitespaceResult.IsValid)"

    # --- Configuration/DefaultLogLevelNonStringRejected (B6) ---
    $defaultLogLevelIntResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'defaultLogLevel' = 5 } `
        -Schema $authSchema
    $defaultLogLevelBoolResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'defaultLogLevel' = $true } `
        -Schema $authSchema
    $defaultLogLevelNullResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'defaultLogLevel' = $null } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ((-not [bool]$defaultLogLevelIntResult.IsValid) -and (-not [bool]$defaultLogLevelBoolResult.IsValid) -and (-not [bool]$defaultLogLevelNullResult.IsValid)) `
        -Name "Configuration/DefaultLogLevelNonStringRejected" `
        -Failure "не-рядкове/`$null значення мусить лишитись відхиленим навіть для EnumTrimmed-валідатора; отримано Int.IsValid=$($defaultLogLevelIntResult.IsValid) Bool.IsValid=$($defaultLogLevelBoolResult.IsValid) Null.IsValid=$($defaultLogLevelNullResult.IsValid)"

    # --- Configuration/DefaultLogLevelValidationDoesNotMutateOriginalValue (B7) ---
    $defaultLogLevelMutationProbeValue = ' Error '
    $defaultLogLevelMutationProbeOverrides = @{ 'defaultLogLevel' = $defaultLogLevelMutationProbeValue }
    [void](Test-BRAVOConfigurationOverrideAuthorization -DotPathOverrides $defaultLogLevelMutationProbeOverrides -Schema $authSchema)
    Test-BRAVOCondition `
        -Condition ([string]$defaultLogLevelMutationProbeOverrides['defaultLogLevel'] -eq $defaultLogLevelMutationProbeValue) `
        -Name "Configuration/DefaultLogLevelValidationDoesNotMutateOriginalValue" `
        -Failure "Test-BRAVOConfigurationOverrideAuthorization НЕ повинен мутувати вхідне defaultLogLevel-значення на місці; отримано '$($defaultLogLevelMutationProbeOverrides['defaultLogLevel'])' замість очікуваного '$defaultLogLevelMutationProbeValue'"

    # --- Authorization/RobocopyExitCodeBoundaryMatrix ---
    # Owner-decision test matrix (WAVE2-CONTRACT.md, розділ 11.0/11.6): 0/7
    # accepted; 8/-1/7.5/'7' rejected. Рядок '7' НЕ повинен коерситись у
    # число.
    & {
        $robocopyCases = @(
            @{ Value = 0;    Expected = $true;  Label = '0' }
            @{ Value = 7;    Expected = $true;  Label = '7' }
            @{ Value = 8;    Expected = $false; Label = '8' }
            @{ Value = -1;   Expected = $false; Label = '-1' }
            @{ Value = 7.5;  Expected = $false; Label = '7.5' }
            @{ Value = '7';  Expected = $false; Label = "'7' (рядок)" }
        )
        foreach ($robocopyCase in $robocopyCases) {
            $robocopyResult = Test-BRAVOConfigurationOverrideAuthorization `
                -DotPathOverrides @{ 'robocopyMaxSuccessExitCode' = $robocopyCase.Value } `
                -Schema $authSchema
            Test-BRAVOCondition `
                -Condition ([bool]$robocopyResult.IsValid -eq [bool]$robocopyCase.Expected) `
                -Name "Authorization/RobocopyExitCodeBoundary_$($robocopyCase.Label)" `
                -Failure "robocopyMaxSuccessExitCode=$($robocopyCase.Label) мусить дати IsValid=$($robocopyCase.Expected), отримано $($robocopyResult.IsValid)"
        }
    }

    # --- Authorization/DenyDerivedRejected ---
    # PR #224 review, N3 (2026-09-22): sftpDirectories.BAZA/BAZAWWW
    # пере-класифіковано DENY_DERIVED -> ALLOW_SITE (сирі site-параметри,
    # не похідні значення — див. коментар при реєстрації в
    # BRAVO.Configuration.Schema.psm1). Реєстр більше не має ЖОДНОГО
    # DENY_DERIVED-запису (клас лишається визначеним у механізмі
    # дозволу/заборони, просто наразі без членів). Доводимо, що сам
    # механізм класу DENY_DERIVED і далі безумовно відхиляє, через
    # тимчасовий синтетичний лист у приватному script-стані модуля (той
    # самий підхід, що Authorization/FutureLeafWithoutExplicitWeakeningOverrideFailsClosed
    # вище використовує для DENY_SECURITY_CONTROL) — видаляється у finally
    # незалежно від результату.
    & {
        $denyDerivedProbePath = '__SELFTEST_SYNTHETIC_DENY_DERIVED_LEAF__'
        $denyDerivedProbeModule = Get-Module -Name 'BRAVO.Configuration.Schema'
        $denyDerivedProbeAdded = $false
        try {
            & $denyDerivedProbeModule {
                param($path)
                $script:BRAVOConfigurationSchemaAuthorizationClass[$path] = @{ Class = 'DENY_DERIVED' }
            } $denyDerivedProbePath
            $denyDerivedProbeAdded = $true

            $denyDerivedProbeSchema = @{}
            foreach ($k in @($authSchema.Keys)) { $denyDerivedProbeSchema[$k] = $authSchema[$k] }
            $denyDerivedProbeSchema[$denyDerivedProbePath] = @{ Kind = 'String'; Nullable = $false }

            $authDenyDerivedResult = Test-BRAVOConfigurationOverrideAuthorization `
                -DotPathOverrides @{ $denyDerivedProbePath = 'anything' } `
                -Schema $denyDerivedProbeSchema
            Test-BRAVOCondition `
                -Condition (
                    -not [bool]$authDenyDerivedResult.IsValid -and
                    $authDenyDerivedResult.Violations.Count -eq 1 -and
                    [string]$authDenyDerivedResult.Violations[0].Class -eq 'DENY_DERIVED'
                ) `
                -Name "Authorization/DenyDerivedRejected" `
                -Failure "клас DENY_DERIVED мусить безумовно відхиляти незалежно від запропонованого значення, навіть коли наразі жоден реальний лист цим класом не позначений; отримано IsValid=$($authDenyDerivedResult.IsValid)"
        } finally {
            if ($denyDerivedProbeAdded) {
                & $denyDerivedProbeModule {
                    param($path)
                    $script:BRAVOConfigurationSchemaAuthorizationClass.Remove($path)
                } $denyDerivedProbePath
            }
        }
    }

    # --- Authorization/SftpDirectoriesBazaAndBazaWwwAreSiteConfigurable ---
    # N3: позитивний контрольний тест — обидва тепер ALLOW_SITE, кастомне
    # значення оператора мусить прийматись без валідатора.
    $authBazaAllowedResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'sftpDirectories.BAZA' = 'custom_baza_app'; 'sftpDirectories.BAZAWWW' = 'custom_baza_www' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ([bool]$authBazaAllowedResult.IsValid) `
        -Name "Authorization/SftpDirectoriesBazaAndBazaWwwAreSiteConfigurable" `
        -Failure "sftpDirectories.BAZA/BAZAWWW (ALLOW_SITE після N3-корекції) мусять приймати довільне site-значення без валідатора; отримано IsValid=$($authBazaAllowedResult.IsValid) Violations=$($authBazaAllowedResult.Violations.Count)"

    # --- Authorization/DenySecurityControlRejected ---
    $authDenySecurityResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'winSCPIniPath' = 'C:\custom.ini' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authDenySecurityResult.IsValid) `
        -Name "Authorization/DenySecurityControlRejected" `
        -Failure "winSCPIniPath (DENY_SECURITY_CONTROL) мусить бути відхилений"

    # --- Authorization/DenyExecutionControlRejected ---
    $authDenyExecutionResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'robocopyPath' = 'C:\evil.exe' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authDenyExecutionResult.IsValid) `
        -Name "Authorization/DenyExecutionControlRejected" `
        -Failure "robocopyPath (DENY_EXECUTION_CONTROL) мусить бути відхилений"

    # --- Authorization/DenyInternalMetadataRejected ---
    $authDenyInternalResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'hashFileExtension' = '.custom' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authDenyInternalResult.IsValid) `
        -Name "Authorization/DenyInternalMetadataRejected" `
        -Failure "hashFileExtension (DENY_INTERNAL_METADATA) мусить бути відхилений"

    # --- Authorization/DenyCredentialBackedClassRejectsSyntheticDescriptor ---
    # DENY_CREDENTIAL_BACKED сьогодні має 0 реальних канонічних листів
    # (WAVE2-CONTRACT.md, розділ 1) — перевіряємо ОБРОБКУ класу на рівні
    # unit-виклику диспетчера відмов, а не через реальний лист, якого
    # немає.
    & {
        $syntheticRegistry = @{}
        foreach ($syntheticKey in @($authRegistry.Keys)) { $syntheticRegistry[$syntheticKey] = $authRegistry[$syntheticKey] }
        $syntheticRegistry['archiveRetentionDays'] = @{ Class = 'DENY_CREDENTIAL_BACKED'; Validator = $null }
        # Тимчасово підміняємо $script:-реєстр НЕ можна (модуль-приватний
        # стан) — натомість перевіряємо семантику класу напряму через
        #ReadOnly-адаптер Configurator-а, який так само трактує будь-який
        # НЕ-ALLOW_SITE/ALLOW_WITH_VALIDATOR клас як "не для site-шару"
        # лише для DENY_-префіксних класів. DENY_CREDENTIAL_BACKED
        # відповідає цьому патерну ідентично іншим DENY_*-класам.
        Test-BRAVOCondition `
            -Condition ([string]'DENY_CREDENTIAL_BACKED').StartsWith('DENY_') `
            -Name "Authorization/DenyCredentialBackedClassNameFollowsDenyPrefixConvention" `
            -Failure "DENY_CREDENTIAL_BACKED мусить лишатись у DENY_-неймінг-конвенції, яку розпізнає диспетчер відмов (0 реальних листів сьогодні — WAVE2-CONTRACT.md, розділ 1)"
    }

    # --- Authorization/OwnerDecisionBravoNameDeniedUnconditionally ---
    $authBravoNameResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'maintenanceSettings.Services.BravoName' = 'BravoBackupService' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authBravoNameResult.IsValid) `
        -Name "Authorization/OwnerDecisionBravoNameDeniedUnconditionally" `
        -Failure "maintenanceSettings.Services.BravoName мусить бути відхилений БЕЗУМОВНО (рішення власника 2026-09-21), навіть коли запропоноване значення виглядає правдоподібним"

    # --- Authorization/OwnerDecisionBazaModeLegacyDenied ---
    $authBazaLegacyResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'backupMonitoring.SFTP.BAZA.Mode' = 'Legacy' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authBazaLegacyResult.IsValid) `
        -Name "Authorization/OwnerDecisionBazaModeLegacyDenied" `
        -Failure "backupMonitoring.SFTP.BAZA.Mode='Legacy' мусить бути відхилений (safety downgrade, рішення власника 2026-09-21)"

    # --- Authorization/OwnerDecisionBazaModeIncrementalAppendOnlyAlsoDenied ---
    # КРИТИЧНО: лист заборонений НЕЗАЛЕЖНО від значення — навіть коли
    # запропоноване значення збігається з канонічним дефолтом.
    $authBazaIncrementalResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'backupMonitoring.SFTP.BAZA.Mode' = 'IncrementalAppendOnly' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authBazaIncrementalResult.IsValid) `
        -Name "Authorization/OwnerDecisionBazaModeIncrementalAppendOnlyAlsoDenied" `
        -Failure "backupMonitoring.SFTP.BAZA.Mode='IncrementalAppendOnly' МУСИТЬ теж бути відхилений — авторизація про володіння листом, не про безпечність значення"

    # --- Authorization/UnknownTerminalLeafUnderKnownNodeStillD3Accepted ---
    # D3 (рішення власника 2026-09-14) не повинен зламатись Wave 2:
    # невідомий кінцевий сегмент під ВІДОМИМ вузлом не класифікується
    # авторизацією взагалі (проходить повз, як і повз type-перевірку).
    $authUnknownLeafResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'maintenanceSettings.Limits.SomeFutureLeaf' = 'x' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ([bool]$authUnknownLeafResult.IsValid) `
        -Name "Authorization/UnknownTerminalLeafUnderKnownNodeStillD3Accepted" `
        -Failure "невідомий кінцевий сегмент під відомим вузлом мусить лишитись ACCEPT (D3) — авторизація не повинна класифікувати шляхи поза схемою"

    # --- Authorization/UnknownParentNodeStillFailsClosedUnchanged ---
    # Невідомий БАТЬКІВСЬКИЙ вузол і далі fail-closed через
    # ConvertTo-BRAVONestedOverride (не через авторизацію) — Wave 2 не
    # розширює D3 на цей випадок.
    $authUnknownParentThrew = $false
    try {
        ConvertTo-BRAVONestedOverride `
            -DotPathOverrides @{ 'maintenanceSettings.NoSuchNode.Value' = 'x' } `
            -ReferenceConfiguration $authDefaults | Out-Null
    } catch {
        $authUnknownParentThrew = $true
    }
    Test-BRAVOCondition `
        -Condition $authUnknownParentThrew `
        -Name "Authorization/UnknownParentNodeStillFailsClosedUnchanged" `
        -Failure "невідомий батьківський вузол мусить і далі fail-closed через ConvertTo-BRAVONestedOverride, незмінно Wave 2"

    # --- Authorization/CaseInsensitivePathCannotBypassDeny ---
    # PowerShell hashtable-семантика — case-insensitive за замовчуванням;
    # DENY-класифікація мусить діяти ІДЕНТИЧНО для будь-якого регістру
    # шляху, а не "проковзнути" як D3 unknown через регістрову
    # невідповідність.
    $authUpperCaseResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'MAINTENANCESETTINGS.SERVICES.BRAVONAME' = 'AnyValue' } `
        -Schema $authSchema
    $authMixedCaseResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'MaintenanceSettings.services.bravoname' = 'AnyValue' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ((-not [bool]$authUpperCaseResult.IsValid) -and (-not [bool]$authMixedCaseResult.IsValid)) `
        -Name "Authorization/CaseInsensitivePathCannotBypassDeny" `
        -Failure "DENY-класифікація maintenanceSettings.Services.BravoName мусить діяти незалежно від регістру шляху (UPPERCASE=$($authUpperCaseResult.IsValid) MixedCase=$($authMixedCaseResult.IsValid))"

    # --- Authorization/NestedDenyPathAuthorizedAtCorrectDepth ---
    # Вкладений (3-рівневий) DENY_SECURITY_CONTROL-шлях
    # (backupMonitoring.SFTP.BAZA.MutationPolicy) мусить відхилятись так
    # само надійно, як top-level шлях — авторизація діє на КОЖНОМУ рівні
    # глибини, не лише на верхньому.
    $authNestedDenyResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'backupMonitoring.SFTP.BAZA.MutationPolicy' = 'Fail' } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authNestedDenyResult.IsValid) `
        -Name "Authorization/NestedDenyPathAuthorizedAtCorrectDepth" `
        -Failure "вкладений (3-рівневий) DENY_SECURITY_CONTROL-шлях backupMonitoring.SFTP.BAZA.MutationPolicy мусить бути відхилений так само, як top-level DENY-шлях"

    # --- Authorization/ArrayValueClassifiedAsWhole ---
    # Масив (DENY_EXECUTION_CONTROL: robocopyOptions) класифікується як
    # ЄДИНЕ ціле, не по елементах — заміна всього масиву на елементи, що
    # виглядають нешкідливо, все одно відхиляється.
    $authArrayResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'robocopyOptions' = @('/E') } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authArrayResult.IsValid) `
        -Name "Authorization/ArrayValueClassifiedAsWhole" `
        -Failure "robocopyOptions (Array, DENY_EXECUTION_CONTROL) мусить бути відхилений як ціле, незалежно від того, наскільки нешкідливі елементи"

    # --- Authorization/DiagnosticMessageNamesExactPathAndClass ---
    $authDiagnosticResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'maintenanceSettings.Services.BravoName' = 'X' } `
        -Schema $authSchema
    $authDiagnosticViolation = $authDiagnosticResult.Violations[0]
    Test-BRAVOCondition `
        -Condition (
            [string]$authDiagnosticViolation.Path -eq 'maintenanceSettings.Services.BravoName' -and
            [string]$authDiagnosticViolation.Class -eq 'DENY_EXECUTION_CONTROL' -and
            [string]$authDiagnosticViolation.Message -match [regex]::Escape('maintenanceSettings.Services.BravoName')
        ) `
        -Name "Authorization/DiagnosticMessageNamesExactPathAndClass" `
        -Failure "порушення мусить називати точний Path і Class у структурованому результаті (отримано Path=$($authDiagnosticViolation.Path) Class=$($authDiagnosticViolation.Class))"

    # --- Authorization/EmptyOverrideLayerValid ---
    $authEmptyResult = Test-BRAVOConfigurationOverrideAuthorization -DotPathOverrides @{} -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ([bool]$authEmptyResult.IsValid) `
        -Name "Authorization/EmptyOverrideLayerValid" `
        -Failure "порожній local-override шар мусить бути IsValid без жодних порушень"

    # --- Authorization/LoaderCallsAuthorizationAfterSchemaBeforeMerge ---
    # Структурний guard, той самий патерн, що вже перевіряє
    # Schema/LoaderValidatesLocalLayerBeforeMerge вище: авторизація мусить
    # стояти в конвеєрі ПІСЛЯ type-перевірки й ДО Resolve-BRAVORawConfiguration
    # (merge) — інакше атомарність (weight 9/17) не гарантована.
    $authLoaderText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_CONFIG_LOADER.ps1'), [Text.Encoding]::UTF8)
    $authSchemaCallIndex = $authLoaderText.IndexOf('Test-BRAVOConfigurationOverrideSchema')
    $authAuthorizationCallIndex = $authLoaderText.IndexOf('Test-BRAVOConfigurationOverrideAuthorization')
    $authMergeCallIndex = $authLoaderText.IndexOf('$mergedConfiguration = Resolve-BRAVORawConfiguration')
    Test-BRAVOCondition `
        -Condition (
            $authSchemaCallIndex -gt 0 -and $authAuthorizationCallIndex -gt 0 -and $authMergeCallIndex -gt 0 -and
            $authSchemaCallIndex -lt $authAuthorizationCallIndex -and
            $authAuthorizationCallIndex -lt $authMergeCallIndex
        ) `
        -Name "Authorization/LoaderCallsAuthorizationAfterSchemaBeforeMerge" `
        -Failure "BRAVO_CONFIG_LOADER мусить викликати Test-BRAVOConfigurationOverrideAuthorization ПІСЛЯ type-перевірки й ДО Resolve-BRAVORawConfiguration (schema=$authSchemaCallIndex authorization=$authAuthorizationCallIndex merge=$authMergeCallIndex)"

    # =====================================================================
    # Owner remediation (Issue #216 Wave 2): WeakeningOverride —
    # canonical-registry-owned escape-hatch eligibility. ДО цього блоку
    # BRAVO_CONFIG_LOADER.ps1 мав власний жорстко закодований перелік
    # dot-шляхів (BAZA.Mode/MutationPolicy), виключених з
    # BRAVO_ALLOW_WEAKENED_SECURITY-обходу — друга копія авторизаційної
    # політики поза реєстром. Тести нижче доводять, що ЄДИНЕ джерело
    # цього рішення тепер — канонічний реєстр, а не loader.
    # =====================================================================
    $authKnownWeakeningOverrides = @('None', 'ExistingSecurityEscapeHatch')

    # --- Authorization/AllWeakeningOverrideValuesRecognized ---
    $authUnrecognizedWeakeningOverrides = @(@($authRegistry.Values) | ForEach-Object { [string]$_.WeakeningOverride } | Where-Object { $authKnownWeakeningOverrides -notcontains $_ } | Select-Object -Unique)
    Test-BRAVOCondition `
        -Condition ($authUnrecognizedWeakeningOverrides.Count -eq 0) `
        -Name "Authorization/AllWeakeningOverrideValuesRecognized" `
        -Failure "кожен запис реєстру мусить мати WeakeningOverride з визнаного набору ('None'/'ExistingSecurityEscapeHatch'); знайдено невідомі: $([string]::Join(', ', $authUnrecognizedWeakeningOverrides))"

    # --- Authorization/EscapeHatchEligibleSetIsMechanicallyEnumerableAndExactlyRequireAdministrator ---
    # Owner-decision (Wave 1, збережено Wave 2): ЄДИНИЙ лист сьогодні з
    # WeakeningOverride='ExistingSecurityEscapeHatch' — requireAdministrator.
    # Механічне enumeration з реєстру (не hardcoded loader-список) —
    # якщо колись власник свідомо додасть ще один escapable-лист, цей
    # тест НЕ зламається мовчки: він або підтвердить нову множину, або
    # провалиться з точним переліком, що вимагає свідомого рев'ю.
    $authEscapeHatchEligiblePaths = @(@($authRegistry.GetEnumerator()) | Where-Object { [string]$_.Value.WeakeningOverride -eq 'ExistingSecurityEscapeHatch' } | ForEach-Object { [string]$_.Key } | Sort-Object)
    Test-BRAVOCondition `
        -Condition ($authEscapeHatchEligiblePaths.Count -eq 1 -and $authEscapeHatchEligiblePaths[0] -eq 'requireAdministrator') `
        -Name "Authorization/EscapeHatchEligibleSetIsMechanicallyEnumerableAndExactlyRequireAdministrator" `
        -Failure "рівно ОДИН лист (requireAdministrator) мусить мати WeakeningOverride='ExistingSecurityEscapeHatch' сьогодні; отримано ($($authEscapeHatchEligiblePaths.Count)): $([string]::Join(', ', $authEscapeHatchEligiblePaths))"

    # --- Authorization/CanonicalWeakeningOverridePolicyMatrix ---
    # Пряма перевірка трьох owner-decision листів, названих у ремедіації:
    # BAZA.Mode/MutationPolicy = None (безумовна відмова), requireAdministrator
    # = ExistingSecurityEscapeHatch (наявна Wave 1 поведінка збережена).
    Test-BRAVOCondition `
        -Condition (
            [string]$authRegistry['backupMonitoring.SFTP.BAZA.Mode'].WeakeningOverride -eq 'None' -and
            [string]$authRegistry['backupMonitoring.SFTP.BAZA.MutationPolicy'].WeakeningOverride -eq 'None' -and
            [string]$authRegistry['requireAdministrator'].WeakeningOverride -eq 'ExistingSecurityEscapeHatch'
        ) `
        -Name "Authorization/CanonicalWeakeningOverridePolicyMatrix" `
        -Failure ("канонічна WeakeningOverride-матриця: BAZA.Mode=$($authRegistry['backupMonitoring.SFTP.BAZA.Mode'].WeakeningOverride)(очікується None) " +
                  "BAZA.MutationPolicy=$($authRegistry['backupMonitoring.SFTP.BAZA.MutationPolicy'].WeakeningOverride)(очікується None) " +
                  "requireAdministrator=$($authRegistry['requireAdministrator'].WeakeningOverride)(очікується ExistingSecurityEscapeHatch)")

    # --- Authorization/ViolationObjectExposesWeakeningOverrideForBazaAndRequireAdministrator ---
    # Структурована ознака (Violation.WeakeningOverride), яку canonical
    # Test-BRAVOConfigurationWeakeningEscapeHatchAllowed реально читає
    # ЗАМІСТЬ dot-path-порівняння (PR #224 third review, final cleanup:
    # BRAVO_CONFIG_LOADER.ps1 більше не читає це поле напряму — делегує
    # рішення повністю canonical helper-у) — доводимо на РЕАЛЬНИХ
    # DENY_SECURITY_CONTROL-порушеннях (не лише на сирому реєстрі вище).
    $authBazaModeViolationCheck = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'backupMonitoring.SFTP.BAZA.Mode' = 'Legacy' } `
        -Schema $authSchema
    $authReqAdminViolationCheck = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'requireAdministrator' = $false } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (
            $authBazaModeViolationCheck.Violations.Count -eq 1 -and
            [string]$authBazaModeViolationCheck.Violations[0].WeakeningOverride -eq 'None' -and
            $authReqAdminViolationCheck.Violations.Count -eq 1 -and
            [string]$authReqAdminViolationCheck.Violations[0].WeakeningOverride -eq 'ExistingSecurityEscapeHatch'
        ) `
        -Name "Authorization/ViolationObjectExposesWeakeningOverrideForBazaAndRequireAdministrator" `
        -Failure "Violation.WeakeningOverride мусить бути 'None' для BAZA.Mode-порушення й 'ExistingSecurityEscapeHatch' для requireAdministrator-порушення — саме це поле canonical Test-BRAVOConfigurationWeakeningEscapeHatchAllowed тепер читає замість dot-path-списку"

    # --- Authorization/FutureLeafWithoutExplicitWeakeningOverrideFailsClosed ---
    # Issue #216 Wave 2 owner remediation, п.9: МАЙБУТНІЙ (гіпотетичний,
    # НЕ справжній) DENY_SECURITY_CONTROL-лист без явного WeakeningOverride
    # мусить fail-closed до 'None' — доводимо на РЕАЛЬНОМУ виклику
    # Test-BRAVOConfigurationOverrideAuthorization із тимчасово доданим
    # синтетичним листом у ПРИВАТНИЙ script-стан модуля (не постійний
    # запис реєстру — видаляється в finally, незалежно від результату).
    & {
        $futureLeafPath = '__SELFTEST_SYNTHETIC_FUTURE_DENY_LEAF__'
        $futureLeafModule = Get-Module -Name 'BRAVO.Configuration.Schema'
        $futureLeafAdded = $false
        try {
            & $futureLeafModule {
                param($path)
                # Синтетичний запис БЕЗ WeakeningOverride-ключа взагалі —
                # рівно той сценарій, що майбутній контриб'ютор створив
                # би, додавши новий DENY_SECURITY_CONTROL-лист і забувши
                # (або свідомо не бажаючи) позначити його escapable.
                $script:BRAVOConfigurationSchemaAuthorizationClass[$path] = @{ Class = 'DENY_SECURITY_CONTROL' }
            } $futureLeafPath
            $futureLeafAdded = $true

            $futureLeafSchema = @{}
            foreach ($k in @($authSchema.Keys)) { $futureLeafSchema[$k] = $authSchema[$k] }
            $futureLeafSchema[$futureLeafPath] = @{ Kind = 'String'; Nullable = $false }

            $futureLeafResult = Test-BRAVOConfigurationOverrideAuthorization `
                -DotPathOverrides @{ $futureLeafPath = 'anything' } `
                -Schema $futureLeafSchema

            Test-BRAVOCondition `
                -Condition (
                    -not [bool]$futureLeafResult.IsValid -and
                    $futureLeafResult.Violations.Count -eq 1 -and
                    [string]$futureLeafResult.Violations[0].WeakeningOverride -eq 'None'
                ) `
                -Name "Authorization/FutureLeafWithoutExplicitWeakeningOverrideFailsClosed" `
                -Failure "гіпотетичний майбутній DENY_SECURITY_CONTROL-лист БЕЗ явного WeakeningOverride мусить fail-closed до 'None' (не мовчки успадковувати escapability); отримано IsValid=$($futureLeafResult.IsValid), WeakeningOverride=$(if ($futureLeafResult.Violations.Count -gt 0) { $futureLeafResult.Violations[0].WeakeningOverride } else { '<немає порушень>' })"
        } finally {
            if ($futureLeafAdded) {
                & $futureLeafModule {
                    param($path)
                    $script:BRAVOConfigurationSchemaAuthorizationClass.Remove($path)
                } $futureLeafPath
            }
        }
    }

    # =====================================================================
    # PR #224 review, F1: вкладений (nested hashtable) Node-шлях local
    # override мусить рекурсивно авторизуватись по КОЖНОМУ дочірньому
    # листу — реєстр авторизації навмисно leaf-only (Node-записів немає),
    # тож ДО фіксу такий override помилково провалювався з
    # MissingAuthorizationPolicy/UNREGISTERED замість реальної
    # leaf-по-leaf перевірки.
    # =====================================================================

    # --- Authorization/NestedAllowedNodeAccepted ---
    $authNestedAllowedResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'bravoSettings.NotificationRouting' = @{ SUCCESS = 'general'; WARNING = 'alerts' } } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ([bool]$authNestedAllowedResult.IsValid) `
        -Name "Authorization/NestedAllowedNodeAccepted" `
        -Failure "вкладений Node-override з усіма ALLOW_* дочірніми листами мусить бути прийнятий; отримано IsValid=$($authNestedAllowedResult.IsValid) Violations=$($authNestedAllowedResult.Violations.Count)"

    # --- Authorization/NestedNodeDeniedLeafBlocked ---
    $authNestedDeniedResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'maintenanceSettings.Services' = @{ BravoName = 'OtherService' } } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (
            (-not [bool]$authNestedDeniedResult.IsValid) -and
            $authNestedDeniedResult.Violations.Count -eq 1 -and
            [string]$authNestedDeniedResult.Violations[0].Path -eq 'maintenanceSettings.Services.BravoName'
        ) `
        -Name "Authorization/NestedNodeDeniedLeafBlocked" `
        -Failure "вкладений Node-override, чий єдиний дочірній лист DENY_*, мусить бути відхилений з точним Path дочірнього листа; отримано IsValid=$($authNestedDeniedResult.IsValid) Path=$(if ($authNestedDeniedResult.Violations.Count -gt 0) { $authNestedDeniedResult.Violations[0].Path } else { '<немає>' })"

    # --- Authorization/NestedMixedAllowedAndDeniedFailsAtomically ---
    # Node з ДВОМА дочірніми листами — один ALLOW_SITE
    # (BravoDisplayName), один DENY_EXECUTION_CONTROL (BravoName) — весь
    # ШАР мусить провалитись атомарно (не лише конкретний лист).
    $authNestedMixedResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'maintenanceSettings.Services' = @{ BravoName = 'OtherService'; BravoDisplayName = 'Custom Display' } } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authNestedMixedResult.IsValid) `
        -Name "Authorization/NestedMixedAllowedAndDeniedFailsAtomically" `
        -Failure "Node з мішаними ALLOW/DENY дочірніми листами мусить провалити ВЕСЬ шар атомарно; отримано IsValid=$($authNestedMixedResult.IsValid)"

    # --- Authorization/NestedPathCaseInsensitive ---
    $authNestedCaseResult = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'MAINTENANCESETTINGS.SERVICES' = @{ BRAVONAME = 'OtherService' } } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition (-not [bool]$authNestedCaseResult.IsValid) `
        -Name "Authorization/NestedPathCaseInsensitive" `
        -Failure "вкладена DENY-класифікація мусить діяти незалежно від регістру і батьківського Node-шляху, і дочірнього ключа; отримано IsValid=$($authNestedCaseResult.IsValid)"

    # --- Authorization/NestedUnknownChildUnderKnownNodeStillD3Accepted ---
    # D3 мусить лишитись незмінним і для вкладеної форми: невідомий
    # дочірній ключ під ВІДОМИМ Node-шляхом — accept, не UNREGISTERED.
    $authNestedD3Result = Test-BRAVOConfigurationOverrideAuthorization `
        -DotPathOverrides @{ 'maintenanceSettings.Limits' = @{ SomeFutureLeaf = 'x' } } `
        -Schema $authSchema
    Test-BRAVOCondition `
        -Condition ([bool]$authNestedD3Result.IsValid) `
        -Name "Authorization/NestedUnknownChildUnderKnownNodeStillD3Accepted" `
        -Failure "невідомий дочірній ключ під відомим Node-шляхом мусить лишитись D3 ACCEPT у вкладеній формі так само, як у пласкій; отримано IsValid=$($authNestedD3Result.IsValid)"

    # --- Authorization/NestedRegistryStaysLeafOnly ---
    # Реєстр авторизації НЕ повинен отримати запис для самого Node-шляху
    # (bravoSettings.NotificationRouting) — лише для його листів; фікс F1
    # не мав додавати Node-записи в реєстр.
    Test-BRAVOCondition `
        -Condition (-not $authRegistry.Contains('bravoSettings.NotificationRouting')) `
        -Name "Authorization/NestedRegistryStaysLeafOnly" `
        -Failure "реєстр авторизації мусить лишатись leaf-only — bravoSettings.NotificationRouting (Node) не повинен мати власного запису в реєстрі"
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
