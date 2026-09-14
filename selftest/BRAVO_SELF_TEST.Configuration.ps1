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
        Test-BRAVOCondition `
            -Condition ($deltaNone.Count -eq 0) `
            -Name "Delta/IdenticalGraphsProduceNoDifference" `
            -Failure "порівняння canonical defaults із самими собою має дати 0 відмінностей (отримано $($deltaNone.Count))"

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
