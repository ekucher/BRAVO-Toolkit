# Домен-фрагмент self-test: BazaSync (BRAVO.BazaSync). Dot-sourced з кореневого
# BRAVO_SELF_TEST.ps1 -- НЕ запускається напряму. Успадковує з викликача:
# $root, Test-BRAVOCondition, New-BRAVOSelfTestRuntimeModule, $script:failures.
# Витягнуто без зміни жодного тестового виразу чи -Name (behavior-preserving
# розбиття, characterization baseline: 164 тести BazaSync/*, рядки
# 18518-20376 оригінального файлу на момент витягнення).

    # =====================================================================
    # BAZA SYNC: incremental append-only synchronization engine
    # (BRAVO.BazaSync) -- Sync Cycle/Cutoff, persisted state, Fast Health
    # vs Full Audit, mutation detection, concurrency lock, performance
    # regression. Categories A-G per safety-review specification.
    # =====================================================================
    try {
        if (Enter-BRAVOSelfTestSection -Name 'BazaSync/ConfigDefinesBazaBlock') { try {
        Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
        Import-Module -Name (Join-Path $root "modules\BRAVO.ArchiveRuntime\BRAVO.ArchiveRuntime.psd1") -Force -ErrorAction Stop
        Import-Module -Name (Join-Path $root "modules\BRAVO.BazaSync\BRAVO.BazaSync.psd1") -Force -ErrorAction Stop
        if ($null -eq ('WinSCP.Session' -as [type])) {
            Add-Type -Path (Join-Path $root "Tools\WinSCPnet.dll") -ErrorAction Stop
        }

        # New-BRAVOSelfTestFakeBazaSession (фейкова WinSCP-сесія) визначена
        # у bootstrap-і кореневого BRAVO_SELF_TEST.ps1 (#219): її так само
        # викликає фрагмент TraceArchive, а -Suite TraceArchive без BazaSync
        # падав на CommandNotFound.

        function New-BRAVOSelfTestBazaFile {
            param([string]$Directory, [string]$RelativePath, [int]$SizeBytes = 100, [datetime]$LastWriteTimeUtc)
            $fullPath = Join-Path $Directory $RelativePath
            $parent = Split-Path -Path $fullPath -Parent
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.File]::WriteAllBytes($fullPath, (New-Object byte[] $SizeBytes))
            if ($PSBoundParameters.ContainsKey('LastWriteTimeUtc')) {
                (Get-Item -LiteralPath $fullPath).LastWriteTimeUtc = $LastWriteTimeUtc
            }
            return $fullPath
        }

        # GetTempPath, не $env:TEMP: TEMP сесії може бути 8.3-коротким
        # (C:\Users\E980D~1.KUC\...), а Remove-Item -LiteralPath у PS 5.1
        # падає на короткому сегменті (реальний випадок: DEV-LIMS).
        $bazaSyncTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("bazasynctest_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $bazaSyncTestRoot -Force | Out-Null

        # =======================================================================
        # CONFIG
        # =======================================================================
        # P0 Configuration Foundation (PR B): StateRoot — похідне поле
        # (Resolve-BRAVOConfigurationDerivation), решта — raw-листові
        # поля, що й далі лежать у самому BRAVO.config.
        $bravoConfigText = (
            (Get-BRAVOSelfTestShippedConfigText) +
            [Environment]::NewLine +
            [IO.File]::ReadAllText(
                (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Derivation.psm1'),
                [Text.Encoding]::UTF8
            )
        )
        Test-BRAVOCondition -Condition (
            $bravoConfigText.Contains('BAZA = @{') -and
            $bravoConfigText.Contains('Mode = "IncrementalAppendOnly"') -and
            $bravoConfigText.Contains('SynchronizeBeforeHealth = $true') -and
            $bravoConfigText.Contains('FastHealthEnabled = $true') -and
            $bravoConfigText.Contains('FullAuditEnabled = $true') -and
            $bravoConfigText.Contains('FullAuditEveryDays = 7') -and
            $bravoConfigText.Contains('MutationPolicy = "Fail"') -and
            $bravoConfigText.Contains('StateRoot = $stateRoot')
        ) -Name 'BazaSync/ConfigDefinesBazaBlock' -Failure 'BRAVO.config має містити backupMonitoring.SFTP.BAZA з Mode/SynchronizeBeforeHealth/FastHealthEnabled/FullAuditEnabled/FullAuditEveryDays/MutationPolicy/StateRoot'

        # =======================================================================
        # MODE RESOLUTION
        # =======================================================================
        $global:backupMonitoring = @{ SFTP = @{ } }
        Test-BRAVOCondition -Condition ((Get-BRAVOBazaSyncModeEffective) -eq 'IncrementalAppendOnly' -and (Test-BRAVOBazaIncrementalModeEnabled) -eq $true) `
            -Name 'BazaSync/SyncModeDefaultsToIncrementalAppendOnly' -Failure 'без BAZA.Mode в конфігурації ефективний режим має бути IncrementalAppendOnly'

        $global:backupMonitoring = @{ SFTP = @{ BAZA = @{ Mode = "Legacy" } } }
        Test-BRAVOCondition -Condition ((Test-BRAVOBazaIncrementalModeEnabled) -eq $false) `
            -Name 'BazaSync/SyncModeRespectsLegacyOverride' -Failure 'BAZA.Mode="Legacy" має вимикати Test-BRAVOBazaIncrementalModeEnabled'
        $global:backupMonitoring = $null

        # =======================================================================
        # STATE (category F)
        # =======================================================================
        $stateTestRoot = Join-Path $bazaSyncTestRoot "F_State"
        New-Item -ItemType Directory -Path $stateTestRoot -Force | Out-Null

        $missingRead = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $stateTestRoot -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition ($missingRead.Exists -eq $false -and $missingRead.Corrupt -eq $false) `
            -Name 'BazaSync/StateFirstRunNotExists' -Failure 'відсутній файл стану має бути Exists=false,Corrupt=false (легітимний перший запуск), а не помилка'

        $garbagePath = Get-BRAVOBazaStatePath -StateRoot $stateTestRoot -Component 'BAZA_GARBAGE'
        New-Item -ItemType Directory -Path (Split-Path $garbagePath -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($garbagePath, "{ not valid json !!!", (New-Object Text.UTF8Encoding($false)))
        $garbageRead = Read-BRAVOBazaState -Path $garbagePath
        Test-BRAVOCondition -Condition ($garbageRead.Exists -eq $true -and $garbageRead.Corrupt -eq $true) `
            -Name 'BazaSync/StateCorruptGarbageJsonDetected' -Failure 'непарсований JSON має Corrupt=true -- старі файли НЕ вважаються automatically verified'

        $schemaPath = Get-BRAVOBazaStatePath -StateRoot $stateTestRoot -Component 'BAZA_SCHEMA'
        New-Item -ItemType Directory -Path (Split-Path $schemaPath -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($schemaPath, '{"SchemaVersion":99,"Component":"BAZA_SCHEMA","Files":{}}', (New-Object Text.UTF8Encoding($false)))
        $schemaRead = Read-BRAVOBazaState -Path $schemaPath
        Test-BRAVOCondition -Condition ($schemaRead.Corrupt -eq $true -and $schemaRead.Reason -match 'schemaVersion') `
            -Name 'BazaSync/StateUnsupportedSchemaVersionFailsVisible' -Failure 'непідтримувана SchemaVersion має Corrupt=true з поясненням, а не мовчазну міграцію/скидання'

        $roundTripPath = Get-BRAVOBazaStatePath -StateRoot $stateTestRoot -Component 'BAZA_ROUNDTRIP'
        $roundTripState = New-BRAVOBazaEmptyState -Component 'BAZA_ROUNDTRIP'
        $roundTripState.Files['a.txt'] = [pscustomobject]@{ Size = 123; LastWriteTimeUtc = '2026-01-01T00:00:00.0000000Z'; UploadedUtc = '2026-01-01T00:00:01.0000000Z'; Verified = $true }
        Save-BRAVOBazaState -Path $roundTripPath -State $roundTripState
        $roundTripRead = Read-BRAVOBazaState -Path $roundTripPath
        Test-BRAVOCondition -Condition (
            $roundTripRead.Exists -and -not $roundTripRead.Corrupt -and
            $roundTripRead.State.Files.ContainsKey('a.txt') -and
            [int64]$roundTripRead.State.Files['a.txt'].Size -eq 123 -and
            [bool]$roundTripRead.State.Files['a.txt'].Verified -eq $true
        ) -Name 'BazaSync/StateRoundTripPreservesFilesAndFields' -Failure 'Save->Read має зберегти Files/Size/Verified без втрат'

        # Atomic update interruption: valid state must remain usable even if a stray .tmp exists alongside it
        $interruptedPath = Get-BRAVOBazaStatePath -StateRoot $stateTestRoot -Component 'BAZA_INTERRUPTED'
        $interruptedState = New-BRAVOBazaEmptyState -Component 'BAZA_INTERRUPTED'
        $interruptedState.Files['ok.txt'] = [pscustomobject]@{ Size = 10; LastWriteTimeUtc = '2026-01-01T00:00:00.0000000Z'; UploadedUtc = '2026-01-01T00:00:00.0000000Z'; Verified = $true }
        Save-BRAVOBazaState -Path $interruptedPath -State $interruptedState
        $strayTempPath = Join-Path (Split-Path $interruptedPath -Parent) ('.BRAVO_BAZA_STATE_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($strayTempPath, "{ partial", (New-Object Text.UTF8Encoding($false)))
        $afterInterruptRead = Read-BRAVOBazaState -Path $interruptedPath
        Test-BRAVOCondition -Condition (
            $afterInterruptRead.Exists -and -not $afterInterruptRead.Corrupt -and
            $afterInterruptRead.State.Files.ContainsKey('ok.txt')
        ) -Name 'BazaSync/StateAtomicUpdateInterruptionPreservesPreviousValidState' -Failure 'наявність стороннього .tmp поряд не повинна впливати на читання останнього ВАЛІДНОГО стану'

        # =======================================================================
        # INCREMENTAL SYNC (category A) + CUTOFF (category B)
        # =======================================================================
        # P1-1 (deep review): перший запуск БЕЗ -BootstrapIfNeeded тепер
        # повертає STATE_NOT_INITIALIZED (standalone Health не має права на
        # масовий upload). Сценарії нижче тестують НЕ bootstrap, тому
        # проходять перший запуск через явний bootstrap із "порожнім"
        # аудитом: жоден файл ще не збігається на remote -> всі локальні
        # файли йдуть звичайним інкрементальним планом як ToUpload.
        $bazaFirstRunNoOpAuditProvider = {
            param($Snapshot)
            return [pscustomobject]@{ Success = $true; Error = $null; AlreadyMatchingRelativePaths = @(); LocalSizes = @{}; LastWriteTimesUtc = @{} }
        }

        $incRoot = Join-Path $bazaSyncTestRoot "A_Incremental"
        $incLocal = Join-Path $incRoot "local"
        $incState = Join-Path $incRoot "state"
        New-Item -ItemType Directory -Path $incLocal -Force | Out-Null

        New-BRAVOSelfTestBazaFile -Directory $incLocal -RelativePath "f1.txt" -SizeBytes 100 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $incLocal -RelativePath "sub\f2.txt" -SizeBytes 200 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $incLocal -RelativePath "f3.txt" -SizeBytes 300 | Out-Null

        $session1 = New-BRAVOSelfTestFakeBazaSession
        $result1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $incLocal -RemoteRootPath '/baza_app' -Session $session1 -StateRoot $incState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        Test-BRAVOCondition -Condition (
            $result1.Status -eq 'COMPLETE' -and $result1.Uploaded -eq 3 -and $result1.Failed -eq 0 -and
            $session1.State.PutFilesCallCount -eq 3 -and $result1.DiscoveredWithinCutoff -eq 3
        ) -Name 'BazaSync/FirstSyncUploadsAllDiscoveredFiles' -Failure "очікувалось Status=COMPLETE,Uploaded=3,PutFiles=3; отримано Status=$($result1.Status),Uploaded=$($result1.Uploaded),PutFiles=$($session1.State.PutFilesCallCount),Error=$($result1.Error)"

        $session2 = New-BRAVOSelfTestFakeBazaSession
        $result2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $incLocal -RemoteRootPath '/baza_app' -Session $session2 -StateRoot $incState
        Test-BRAVOCondition -Condition (
            $result2.Status -eq 'COMPLETE' -and $result2.Uploaded -eq 0 -and $result2.AlreadyVerified -eq 3 -and
            $session2.State.PutFilesCallCount -eq 0
        ) -Name 'BazaSync/SecondSyncNoChangesSkipsAllRemoteCalls' -Failure "очікувалось 0 upload/0 PutFiles на незмінних verified файлах (trusted skip); отримано Uploaded=$($result2.Uploaded),PutFiles=$($session2.State.PutFilesCallCount)"

        New-BRAVOSelfTestBazaFile -Directory $incLocal -RelativePath "f4_new.txt" -SizeBytes 50 | Out-Null
        $session3 = New-BRAVOSelfTestFakeBazaSession
        $result3 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $incLocal -RemoteRootPath '/baza_app' -Session $session3 -StateRoot $incState
        Test-BRAVOCondition -Condition (
            $result3.Status -eq 'COMPLETE' -and $result3.Uploaded -eq 1 -and $result3.AlreadyVerified -eq 3 -and
            $session3.State.PutFilesCallCount -eq 1
        ) -Name 'BazaSync/OneNewFileTriggersOnlyThatUpload' -Failure "очікувалось рівно 1 upload для нового файла; отримано Uploaded=$($result3.Uploaded),PutFiles=$($session3.State.PutFilesCallCount)"

        # Crash-during-upload: simulate failure for f4_new on a DIFFERENT clean run
        $crashRoot = Join-Path $bazaSyncTestRoot "A_Crash"
        $crashLocal = Join-Path $crashRoot "local"
        $crashState = Join-Path $crashRoot "state"
        New-Item -ItemType Directory -Path $crashLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $crashLocal -RelativePath "willfail.txt" -SizeBytes 40 | Out-Null
        $crashSession1 = New-BRAVOSelfTestFakeBazaSession -FailOnRelativePaths @('willfail.txt')
        $crashResult1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $crashLocal -RemoteRootPath '/baza_app' -Session $crashSession1 -StateRoot $crashState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        $crashStateRead1 = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $crashState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $crashResult1.Status -eq 'INCOMPLETE' -and $crashResult1.Failed -eq 1 -and $crashResult1.PendingWithinCutoff -eq 1 -and
            $crashStateRead1.State.Files.ContainsKey('willfail.txt') -and
            [bool]$crashStateRead1.State.Files['willfail.txt'].Verified -eq $false
        ) -Name 'BazaSync/FailedUploadNotCommittedAsVerified' -Failure "невдалий upload не повинен позначатись Verified=true в state; Status=$($crashResult1.Status),Failed=$($crashResult1.Failed)"

        $crashSession2 = New-BRAVOSelfTestFakeBazaSession
        $crashResult2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $crashLocal -RemoteRootPath '/baza_app' -Session $crashSession2 -StateRoot $crashState
        Test-BRAVOCondition -Condition (
            $crashResult2.Status -eq 'COMPLETE' -and $crashResult2.Uploaded -eq 1 -and $crashSession2.State.PutFilesCallCount -eq 1
        ) -Name 'BazaSync/RetriedUploadSucceedsNextRun' -Failure "наступний прогін має повторити pending-файл і успішно його передати; Status=$($crashResult2.Status),Uploaded=$($crashResult2.Uploaded)"

        # Mutation detection: change size of an already-verified file
        $mutationRoot = Join-Path $bazaSyncTestRoot "A_Mutation"
        $mutationLocal = Join-Path $mutationRoot "local"
        $mutationState = Join-Path $mutationRoot "state"
        New-Item -ItemType Directory -Path $mutationLocal -Force | Out-Null
        $mutFile = New-BRAVOSelfTestBazaFile -Directory $mutationLocal -RelativePath "verified.txt" -SizeBytes 500
        $mutSession1 = New-BRAVOSelfTestFakeBazaSession
        $mutResult1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $mutationLocal -RemoteRootPath '/baza_app' -Session $mutSession1 -StateRoot $mutationState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        Test-BRAVOCondition -Condition ($mutResult1.Status -eq 'COMPLETE' -and $mutResult1.Uploaded -eq 1) `
            -Name 'BazaSync/MutationSetupInitialUploadSucceeds' -Failure 'setup: перший upload має пройти успішно перед тестом мутації'

        # now mutate: change local file size (append-only violation)
        [IO.File]::WriteAllBytes($mutFile, (New-Object byte[] 999))
        $mutSession2 = New-BRAVOSelfTestFakeBazaSession
        $mutResult2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $mutationLocal -RemoteRootPath '/baza_app' -Session $mutSession2 -StateRoot $mutationState
        Test-BRAVOCondition -Condition (
            $mutResult2.Status -eq 'MUTATION_VIOLATION' -and $mutResult2.MutationViolations.Count -eq 1 -and
            $mutResult2.MutationViolations[0].RelativePath -eq 'verified.txt' -and
            $mutResult2.MutationViolations[0].PreviousSize -eq 500 -and $mutResult2.MutationViolations[0].CurrentSize -eq 999 -and
            $mutSession2.State.PutFilesCallCount -eq 0
        ) -Name 'BazaSync/MutationDetectedBlocksSilentOverwrite' -Failure "зміна розміру verified-файлу має бути виявлена як MutationViolation і НЕ призводити до silent re-upload; Status=$($mutResult2.Status),Violations=$($mutResult2.MutationViolations.Count),PutFiles=$($mutSession2.State.PutFilesCallCount)"

        $fastHealthMutation = Get-BRAVOBazaFastHealthResult -SyncResult $mutResult2
        Test-BRAVOCondition -Condition ($fastHealthMutation.Healthy -eq $false -and $fastHealthMutation.Level -eq 'CRITICAL' -and $fastHealthMutation.Message -match 'verified\.txt') `
            -Name 'BazaSync/MutationViolationIsHealthCritical' -Failure 'MUTATION_VIOLATION має бути CRITICAL/unhealthy з іменем файлу в повідомленні'

        # =======================================================================
        # F-CROSSCHECK-02 (MEDIUM): невалідне MutationPolicy (напр. typo
        # "Failed" замість "Fail") НЕ повинно мовчки поводитись як
        # "альтернативна політика обробки мутації" (замість fail-closed
        # блокування MUTATION_VIOLATION, $MutationPolicy -ne 'Fail' ->
        # $true), інакше mutated-але-того-самого-розміру Verified-файл міг
        # би дійти до upload/AlreadyRemote і отримати false-green
        # Verified=true, хоча remote усе ще містить СТАРИЙ вміст.
        # =======================================================================

        # A. Невалідна політика відхиляється на межі параметра (ValidateSet),
        # ДО того, як Get-BRAVOBazaSyncPlan взагалі зможе її інтерпретувати.
        $mutTypoPlanError = $null
        try {
            [void](Get-BRAVOBazaSyncPlan -Snapshot ([pscustomobject]@{ Entries = @{} }) -State ([pscustomobject]@{ Files = @{} }) -MutationPolicy 'Failed')
        } catch {
            $mutTypoPlanError = $_.Exception.Message
        }
        Test-BRAVOCondition -Condition ($null -ne $mutTypoPlanError -and $mutTypoPlanError -match 'Failed') `
            -Name 'BazaSync/InvalidMutationPolicyRejectedAtPlanBoundary' -Failure "Get-BRAVOBazaSyncPlan -MutationPolicy 'Failed' (typo) має відхилятись ValidateSet, а не мовчки трактуватись як policy != Fail; Error=$mutTypoPlanError"

        # B. Той самий типо на межі повного sync-циклу: файл, попередньо
        # Verified=true, мутує (той самий розмір, новий mtime/вміст) — з
        # невалідною політикою цикл ПОВИНЕН впасти ДО планування/upload,
        # а не дозволити мутації дійти до AlreadyRemote/Verified=true
        # (false-green provenance).
        $mutTypoRoot = Join-Path $bazaSyncTestRoot "A_MutationPolicyTypo"
        $mutTypoLocal = Join-Path $mutTypoRoot "local"
        $mutTypoState = Join-Path $mutTypoRoot "state"
        New-Item -ItemType Directory -Path $mutTypoLocal -Force | Out-Null
        $mutTypoFile = New-BRAVOSelfTestBazaFile -Directory $mutTypoLocal -RelativePath "verified.txt" -SizeBytes 500
        $mutTypoSession1 = New-BRAVOSelfTestFakeBazaSession
        $mutTypoResult1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $mutTypoLocal -RemoteRootPath '/baza_app' -Session $mutTypoSession1 -StateRoot $mutTypoState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        Test-BRAVOCondition -Condition ($mutTypoResult1.Status -eq 'COMPLETE' -and $mutTypoResult1.Uploaded -eq 1) `
            -Name 'BazaSync/MutationPolicyTypoSetupInitialUploadSucceeds' -Failure 'setup: перший upload має пройти успішно перед тестом typo-політики'

        $mutTypoOriginalWriteTime = (Get-Item -LiteralPath $mutTypoFile).LastWriteTimeUtc
        $mutTypoChangedBytes = New-Object byte[] 500
        for ($mutTypoByteIndex = 0; $mutTypoByteIndex -lt $mutTypoChangedBytes.Length; $mutTypoByteIndex++) {
            $mutTypoChangedBytes[$mutTypoByteIndex] = [byte]0xA5
        }
        [IO.File]::WriteAllBytes($mutTypoFile, $mutTypoChangedBytes)
        (Get-Item -LiteralPath $mutTypoFile).LastWriteTimeUtc = $mutTypoOriginalWriteTime.AddSeconds(2)
        $mutTypoStateBefore = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $mutTypoState -Component 'BAZA_APP')
        $mutTypoSession2 = New-BRAVOSelfTestFakeBazaSession
        $mutTypoException2 = $null
        try {
            [void](Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $mutTypoLocal -RemoteRootPath '/baza_app' -Session $mutTypoSession2 -StateRoot $mutTypoState -MutationPolicy 'Failed')
        } catch {
            $mutTypoException2 = $_.Exception.Message
        }
        $mutTypoStateAfter = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $mutTypoState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $null -ne $mutTypoException2 -and $mutTypoException2 -match 'Failed' -and
            $mutTypoSession2.State.PutFilesCallCount -eq 0 -and
            [bool]$mutTypoStateAfter.State.Files['verified.txt'].Verified -eq $true -and
            [string]$mutTypoStateAfter.State.Files['verified.txt'].LastWriteTimeUtc -eq [string]$mutTypoStateBefore.State.Files['verified.txt'].LastWriteTimeUtc
        ) -Name 'BazaSync/InvalidMutationPolicyBlocksSameSizeMutationFalseGreen' -Failure "невалідна MutationPolicy на межі повного циклу має fail-closed ДО планування (нуль PutFiles, state незмінний, БЕЗ AlreadyRemote/Verified=true для нового вмісту); Error=$mutTypoException2,PutFiles=$($mutTypoSession2.State.PutFilesCallCount),Verified=$($mutTypoStateAfter.State.Files['verified.txt'].Verified)"

        # C. Валідна MutationPolicy='Fail' (типова, явно передана) лишається
        # незмінною: та сама мутація і далі MUTATION_VIOLATION, без upload.
        $mutTypoSession3 = New-BRAVOSelfTestFakeBazaSession
        $mutTypoResult3 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $mutTypoLocal -RemoteRootPath '/baza_app' -Session $mutTypoSession3 -StateRoot $mutTypoState -MutationPolicy 'Fail'
        Test-BRAVOCondition -Condition (
            $mutTypoResult3.Status -eq 'MUTATION_VIOLATION' -and $mutTypoResult3.MutationViolations.Count -eq 1 -and
            $mutTypoResult3.MutationViolations[0].RelativePath -eq 'verified.txt' -and
            $mutTypoSession3.State.PutFilesCallCount -eq 0
        ) -Name 'BazaSync/ExplicitValidFailPolicyMutationBehaviorUnchanged' -Failure "явне MutationPolicy='Fail' на тій самій мутації має лишатись MUTATION_VIOLATION без upload (regression); Status=$($mutTypoResult3.Status),Violations=$($mutTypoResult3.MutationViolations.Count),PutFiles=$($mutTypoSession3.State.PutFilesCallCount)"
        } catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'BazaSync/ConfigDefinesBazaBlock' } }
        if (Enter-BRAVOSelfTestSection -Name 'BazaSync/ConfigContractInvalidMutationPolicyRejected' -DependsOn 'BazaSync/ConfigDefinesBazaBlock') { try {

        # D. Config-рівень (Get-BRAVOBazaSettingsEffective): невалідне
        # значення відхиляється fail-closed з точним іменем ключа й
        # значенням, БЕЗ мовчазної нормалізації до 'Fail'.
        $mutCfgTypoPrevBackupMonitoring = $global:backupMonitoring
        try {
            $global:backupMonitoring = @{ SFTP = @{ BAZA = @{ MutationPolicy = 'Failed' } } }
            $mutCfgTypoError = $null
            try { [void](Get-BRAVOBazaSettingsEffective) } catch { $mutCfgTypoError = $_.Exception.Message }
            Test-BRAVOCondition -Condition ($null -ne $mutCfgTypoError -and $mutCfgTypoError -match 'MutationPolicy' -and $mutCfgTypoError -match 'Failed') `
                -Name 'BazaSync/ConfigContractInvalidMutationPolicyRejected' -Failure "backupMonitoring.SFTP.BAZA.MutationPolicy='Failed' (typo) має відхилятись fail-closed з точним ім'ям ключа й значенням, а не мовчки нормалізуватись; Error=$mutCfgTypoError"

            $global:backupMonitoring = @{ SFTP = @{ BAZA = @{ MutationPolicy = 'Fail' } } }
            $mutCfgValidError = $null
            $mutCfgValidResult = $null
            try { $mutCfgValidResult = Get-BRAVOBazaSettingsEffective } catch { $mutCfgValidError = $_.Exception.Message }
            Test-BRAVOCondition -Condition ($null -eq $mutCfgValidError -and $null -ne $mutCfgValidResult -and $mutCfgValidResult.MutationPolicy -eq 'Fail') `
                -Name 'BazaSync/ConfigContractValidMutationPolicyFailAccepted' -Failure "явне MutationPolicy='Fail' має проходити без помилки; Error=$mutCfgValidError"
        }
        finally {
            $global:backupMonitoring = $mutCfgTypoPrevBackupMonitoring
        }

        # AutoArchiveMutationThreshold: default (0, вимкнено) — $mutResult2
        # вище вже підтверджує regression без явного передавання параметра
        # (Invoke-BRAVOBazaSynchronization викликано без -AutoArchiveMutationThreshold).

        # AutoArchiveMutationThreshold: N <= поріг -> авто-архівування
        $aaOkRoot = Join-Path $bazaSyncTestRoot "A_AutoArchiveOk"
        $aaOkLocal = Join-Path $aaOkRoot "local"
        $aaOkState = Join-Path $aaOkRoot "state"
        New-Item -ItemType Directory -Path $aaOkLocal -Force | Out-Null
        $aaOkFile = New-BRAVOSelfTestBazaFile -Directory $aaOkLocal -RelativePath "eqv_11-116.pdf" -SizeBytes 500
        $aaOkSession1 = New-BRAVOSelfTestFakeBazaSession
        $aaOkResult1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $aaOkLocal -RemoteRootPath '/baza_app' -Session $aaOkSession1 -StateRoot $aaOkState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        Test-BRAVOCondition -Condition ($aaOkResult1.Status -eq 'COMPLETE' -and $aaOkResult1.Uploaded -eq 1) `
            -Name 'BazaSync/AutoArchiveSetupInitialUploadSucceeds' -Failure 'setup: перший upload має пройти успішно перед тестом авто-архівування'

        [IO.File]::WriteAllBytes($aaOkFile, (New-Object byte[] 999))
        # Той самий session-об'єкт: "віддалений сервер" фейкового duck-типу
        # тримає RemoteSizes/KnownRemoteDirs у своєму State — новий
        # New-BRAVOSelfTestFakeBazaSession означав би порожній remote
        # (FileExists завжди false), що приховало б реальний rename-шлях.
        $aaOkSession2 = $aaOkSession1
        $aaOkResult2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $aaOkLocal -RemoteRootPath '/baza_app' -Session $aaOkSession2 -StateRoot $aaOkState -AutoArchiveMutationThreshold 5
        $aaOkStateRead = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $aaOkState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $aaOkResult2.Status -eq 'MUTATION_AUTO_ARCHIVED' -and
            $aaOkResult2.AutoArchivedMutations.Accepted.Count -eq 1 -and
            $aaOkResult2.AutoArchivedMutations.Accepted[0] -eq 'eqv_11-116.pdf' -and
            $aaOkSession2.State.MoveFileCalls.Count -eq 1 -and
            ($aaOkSession2.State.MoveFileCalls[0] -match '\.replaced_') -and
            -not $aaOkStateRead.State.Files.ContainsKey('eqv_11-116.pdf') -and
            $aaOkSession2.State.PutFilesCallCount -eq 1
        ) -Name 'BazaSync/AutoArchiveBelowThresholdRenamesAndClearsState' -Failure "мутація <= порогу має автоматично rename-archive: Status=$($aaOkResult2.Status),Accepted=$($aaOkResult2.AutoArchivedMutations.Accepted.Count),MoveFile=$($aaOkSession2.State.MoveFileCalls.Count),PutFiles=$($aaOkSession2.State.PutFilesCallCount)"

        # #285 (Codex 388-C1): збій фінального Save-BRAVOBazaState після
        # авто-архівування. Remote уже перейменовано, а зміну стану не
        # збережено — цикл не може лишатися MUTATION_AUTO_ARCHIVED (успіх
        # для -SyncBAZA/Archive); той самий downgrade, що й для COMPLETE.
        $aaSaveRoot = Join-Path $bazaSyncTestRoot "A_AutoArchiveStateSaveFails"
        $aaSaveLocal = Join-Path $aaSaveRoot "local"
        $aaSaveState = Join-Path $aaSaveRoot "state"
        New-Item -ItemType Directory -Path $aaSaveLocal -Force | Out-Null
        $aaSaveFile = New-BRAVOSelfTestBazaFile -Directory $aaSaveLocal -RelativePath "eqv_12-001.pdf" -SizeBytes 500
        $aaSaveSession = New-BRAVOSelfTestFakeBazaSession
        $aaSaveResult1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $aaSaveLocal -RemoteRootPath '/baza_app' -Session $aaSaveSession -StateRoot $aaSaveState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        [IO.File]::WriteAllBytes($aaSaveFile, (New-Object byte[] 999))
        $aaSaveStatePath = Get-BRAVOBazaStatePath -StateRoot $aaSaveState -Component 'BAZA_APP'
        $aaSaveResult2 = $null
        $aaSaveThrew = $null
        [IO.File]::SetAttributes($aaSaveStatePath, [IO.FileAttributes]::ReadOnly)
        try {
            $aaSaveResult2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $aaSaveLocal -RemoteRootPath '/baza_app' -Session $aaSaveSession -StateRoot $aaSaveState -AutoArchiveMutationThreshold 5
        } catch {
            $aaSaveThrew = $_.Exception.Message
        } finally {
            [IO.File]::SetAttributes($aaSaveStatePath, [IO.FileAttributes]::Normal)
        }
        Test-BRAVOCondition -Condition (
            $aaSaveResult1.Status -eq 'COMPLETE' -and
            $null -eq $aaSaveThrew -and
            $null -ne $aaSaveResult2 -and
            $aaSaveSession.State.MoveFileCalls.Count -eq 1 -and
            $aaSaveResult2.Status -eq 'INCOMPLETE' -and
            [string]$aaSaveResult2.Error -match 'не вдалося зберегти стан' -and
            -not (Test-BRAVOBazaSyncStatusSuccess -Status $aaSaveResult2.Status)
        ) -Name 'BazaSync/AutoArchiveStateSaveFailureIsNotSuccess' -Failure "збій збереження стану після авто-архівування має давати не-успішний INCOMPLETE з Error, а не MUTATION_AUTO_ARCHIVED; setup=$($aaSaveResult1.Status) threw='$aaSaveThrew' Status=$(if ($null -ne $aaSaveResult2) { $aaSaveResult2.Status }) Error='$(if ($null -ne $aaSaveResult2) { $aaSaveResult2.Error })' MoveFile=$($aaSaveSession.State.MoveFileCalls.Count)"

        $fastHealthAutoArchive = Get-BRAVOBazaFastHealthResult -SyncResult $aaOkResult2
        Test-BRAVOCondition -Condition (
            $fastHealthAutoArchive.Healthy -eq $true -and $fastHealthAutoArchive.Level -eq 'INFO' -and
            $fastHealthAutoArchive.Message -match 'eqv_11-116\.pdf' -and $fastHealthAutoArchive.Message -notmatch 'ПОТРІБНА ДІЯ'
        ) -Name 'BazaSync/MutationAutoArchivedIsHealthInfoNotCritical' -Failure "MUTATION_AUTO_ARCHIVED має бути INFO/healthy (не блокує): Level=$($fastHealthAutoArchive.Level),Healthy=$($fastHealthAutoArchive.Healthy)"

        # #293: MUTATION_AUTO_ARCHIVED не має ховати remote-конфлікт/audit-drift/
        # несумісні імена ТОГО САМОГО циклу. (a) Fast Health напряму: статус
        # AUTO_ARCHIVED + непорожній RemoteConflicts -> CRITICAL/не healthy, як для
        # REMOTE_CONFLICT; (b) продакшн-драбина статусів: авто-архівування + remote-
        # конфлікт в одному циклі -> Status НЕ MUTATION_AUTO_ARCHIVED.
        $aa293Now = (Get-Date).ToUniversalTime()
        $aa293Synthetic = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId (New-BRAVOBazaCycleId) -StartedUtc $aa293Now -CutoffUtc $aa293Now
        $aa293Synthetic.Status = 'MUTATION_AUTO_ARCHIVED'
        $aa293Synthetic.MutationViolations = @([pscustomobject]@{ RelativePath = 'eqv_11-116.pdf' })
        $aa293Synthetic.RemoteConflicts = @([pscustomobject]@{ RelativePath = 'c_conflict.txt'; LocalSize = [int64]100; RemoteSize = [int64]55 })
        $aa293Health = Get-BRAVOBazaFastHealthResult -SyncResult $aa293Synthetic
        $aa293Reference = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId (New-BRAVOBazaCycleId) -StartedUtc $aa293Now -CutoffUtc $aa293Now
        $aa293Reference.Status = 'REMOTE_CONFLICT'
        $aa293Reference.RemoteConflicts = $aa293Synthetic.RemoteConflicts
        $aa293ReferenceHealth = Get-BRAVOBazaFastHealthResult -SyncResult $aa293Reference
        Test-BRAVOCondition -Condition (
            $aa293Health.Healthy -eq $false -and $aa293Health.Level -eq $aa293ReferenceHealth.Level -and
            $aa293Health.Level -eq 'CRITICAL' -and $aa293Health.Message -match 'c_conflict\.txt'
        ) -Name 'BazaSync/AutoArchivedDoesNotMaskRemoteConflictInFastHealth' -Failure "MUTATION_AUTO_ARCHIVED + RemoteConflicts має бути CRITICAL/не healthy (як REMOTE_CONFLICT), а не INFO: Level=$($aa293Health.Level),Healthy=$($aa293Health.Healthy)"

        $aa293Root = Join-Path $bazaSyncTestRoot "A_AutoArchiveWithConflict"
        $aa293Local = Join-Path $aa293Root "local"
        $aa293State = Join-Path $aa293Root "state"
        New-Item -ItemType Directory -Path $aa293Local -Force | Out-Null
        $aa293File = New-BRAVOSelfTestBazaFile -Directory $aa293Local -RelativePath "eqv_11-116.pdf" -SizeBytes 500
        $aa293Session = New-BRAVOSelfTestFakeBazaSession
        $aa293Cycle1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $aa293Local -RemoteRootPath '/baza_app' -Session $aa293Session -StateRoot $aa293State -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        [IO.File]::WriteAllBytes($aa293File, (New-Object byte[] 999))
        [void](New-BRAVOSelfTestBazaFile -Directory $aa293Local -RelativePath "b.txt" -SizeBytes 100)
        $aa293Session.State.RemoteSizes['/baza_app/b.txt'] = [int64]55
        $aa293Result = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $aa293Local -RemoteRootPath '/baza_app' -Session $aa293Session -StateRoot $aa293State -AutoArchiveMutationThreshold 5
        Test-BRAVOCondition -Condition (
            $aa293Cycle1.Status -eq 'COMPLETE' -and
            $aa293Result.Status -ne 'MUTATION_AUTO_ARCHIVED' -and $aa293Result.Status -eq 'REMOTE_CONFLICT' -and
            @($aa293Result.RemoteConflicts).Count -eq 1 -and
            $aa293Session.State.MoveFileCalls.Count -eq 1 -and
            (Get-BRAVOBazaFastHealthResult -SyncResult $aa293Result).Healthy -eq $false
        ) -Name 'BazaSync/AutoArchiveWithSameCycleRemoteConflictIsNotAutoArchivedStatus' -Failure "авто-архівування + remote-конфлікт в одному циклі: Status має бути REMOTE_CONFLICT (не MUTATION_AUTO_ARCHIVED), авто-архівування все одно виконано; Status=$($aa293Result.Status),Moves=$($aa293Session.State.MoveFileCalls.Count)"

        # #398 (п.5a): решта двох третин контракту #293. Тести вище доводять
        # лише REMOTE_CONFLICT; тут — AUDIT_DRIFT і INCOMPATIBLE_NAME того
        # самого циклу, для обох кон'юнкцій: Fast Health (синтетичний
        # MUTATION_AUTO_ARCHIVED + непорожній AuditDriftFiles/IncompatibleFiles
        # -> CRITICAL, як для еталонного статусу) і драбини статусів через
        # справжній Invoke-BRAVOBazaSynchronization (авто-архівування виконано,
        # MoveFile = 1, але Status — AUDIT_DRIFT/INCOMPATIBLE_NAME). Блок у
        # дочірній області (#163), closure — у вузькій області.
        & {
            $aa398Now = (Get-Date).ToUniversalTime()
            $aa398DriftSynthetic = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId (New-BRAVOBazaCycleId) -StartedUtc $aa398Now -CutoffUtc $aa398Now
            $aa398DriftSynthetic.Status = 'MUTATION_AUTO_ARCHIVED'
            $aa398DriftSynthetic.MutationViolations = @([pscustomobject]@{ RelativePath = 'eqv_11-116.pdf' })
            $aa398DriftSynthetic.AuditDriftFiles = @([pscustomobject]@{ RelativePath = 'd_drift.txt'; Action = 'UploadUpdate'; LocalSize = [int64]100; RemoteSize = [int64]100; LocalMissing = $false })
            $aa398DriftHealth = Get-BRAVOBazaFastHealthResult -SyncResult $aa398DriftSynthetic
            $aa398DriftReference = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId (New-BRAVOBazaCycleId) -StartedUtc $aa398Now -CutoffUtc $aa398Now
            $aa398DriftReference.Status = 'AUDIT_DRIFT'
            $aa398DriftReference.AuditDriftFiles = $aa398DriftSynthetic.AuditDriftFiles
            $aa398DriftReferenceHealth = Get-BRAVOBazaFastHealthResult -SyncResult $aa398DriftReference
            Test-BRAVOCondition -Condition (
                $aa398DriftHealth.Healthy -eq $false -and $aa398DriftHealth.Level -eq $aa398DriftReferenceHealth.Level -and
                $aa398DriftHealth.Level -eq 'CRITICAL' -and $aa398DriftHealth.Message -match 'd_drift\.txt'
            ) -Name 'BazaSync/AutoArchivedDoesNotMaskAuditDriftInFastHealth' -Failure "MUTATION_AUTO_ARCHIVED + AuditDriftFiles має бути CRITICAL/не healthy (як AUDIT_DRIFT), а не INFO: Level=$($aa398DriftHealth.Level),Healthy=$($aa398DriftHealth.Healthy)"

            $aa398NameSynthetic = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId (New-BRAVOBazaCycleId) -StartedUtc $aa398Now -CutoffUtc $aa398Now
            $aa398NameSynthetic.Status = 'MUTATION_AUTO_ARCHIVED'
            $aa398NameSynthetic.MutationViolations = @([pscustomobject]@{ RelativePath = 'eqv_11-116.pdf' })
            $aa398NameSynthetic.IncompatibleFiles = @([pscustomobject]@{ RelativePath = 'n_badname.txt'; Reason = 'задовге' })
            $aa398NameHealth = Get-BRAVOBazaFastHealthResult -SyncResult $aa398NameSynthetic
            $aa398NameReference = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId (New-BRAVOBazaCycleId) -StartedUtc $aa398Now -CutoffUtc $aa398Now
            $aa398NameReference.Status = 'INCOMPATIBLE_NAME'
            $aa398NameReference.IncompatibleFiles = $aa398NameSynthetic.IncompatibleFiles
            $aa398NameReferenceHealth = Get-BRAVOBazaFastHealthResult -SyncResult $aa398NameReference
            Test-BRAVOCondition -Condition (
                $aa398NameHealth.Healthy -eq $false -and $aa398NameHealth.Level -eq $aa398NameReferenceHealth.Level -and
                $aa398NameHealth.Level -eq 'CRITICAL' -and $aa398NameHealth.Message -match 'n_badname\.txt'
            ) -Name 'BazaSync/AutoArchivedDoesNotMaskIncompatibleNameInFastHealth' -Failure "MUTATION_AUTO_ARCHIVED + IncompatibleFiles має бути CRITICAL/не healthy (як INCOMPATIBLE_NAME), а не INFO: Level=$($aa398NameHealth.Level),Healthy=$($aa398NameHealth.Healthy)"

            # Драбина: мутація в межах порогу + несумісне ім'я того самого
            # циклу (123 кириличні + 1 ASCII = 247 UTF-8 байтів > 246, лише
            # 124 символи — безпечно для Windows MAX_PATH).
            $aa398NameRoot = Join-Path $bazaSyncTestRoot "A_AutoArchiveWithIncompatibleName"
            $aa398NameLocal = Join-Path $aa398NameRoot "local"
            $aa398NameState = Join-Path $aa398NameRoot "state"
            New-Item -ItemType Directory -Path $aa398NameLocal -Force | Out-Null
            $aa398NameFile = New-BRAVOSelfTestBazaFile -Directory $aa398NameLocal -RelativePath "eqv_11-116.pdf" -SizeBytes 500
            $aa398NameSession = New-BRAVOSelfTestFakeBazaSession
            $aa398NameCycle1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $aa398NameLocal -RemoteRootPath '/baza_app' -Session $aa398NameSession -StateRoot $aa398NameState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
            [IO.File]::WriteAllBytes($aa398NameFile, (New-Object byte[] 999))
            $aa398LongName = (([string]([char]0x0410)) * 123) + 'a'
            [void](New-BRAVOSelfTestBazaFile -Directory $aa398NameLocal -RelativePath $aa398LongName -SizeBytes 10)
            $aa398NameResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $aa398NameLocal -RemoteRootPath '/baza_app' -Session $aa398NameSession -StateRoot $aa398NameState -AutoArchiveMutationThreshold 5
            Test-BRAVOCondition -Condition (
                $aa398NameCycle1.Status -eq 'COMPLETE' -and
                $aa398NameResult.Status -ne 'MUTATION_AUTO_ARCHIVED' -and $aa398NameResult.Status -eq 'INCOMPATIBLE_NAME' -and
                @($aa398NameResult.IncompatibleFiles).Count -eq 1 -and
                $aa398NameSession.State.MoveFileCalls.Count -eq 1 -and
                -not (Test-BRAVOBazaSyncStatusSuccess -Status $aa398NameResult.Status) -and
                (Get-BRAVOBazaFastHealthResult -SyncResult $aa398NameResult).Healthy -eq $false
            ) -Name 'BazaSync/AutoArchiveWithSameCycleIncompatibleNameIsNotAutoArchivedStatus' -Failure "авто-архівування + несумісне ім'я в одному циклі: Status має бути INCOMPATIBLE_NAME (не MUTATION_AUTO_ARCHIVED), авто-архівування все одно виконано; Cycle1=$($aa398NameCycle1.Status),Status=$($aa398NameResult.Status),Incompatible=$(@($aa398NameResult.IncompatibleFiles).Count),Moves=$($aa398NameSession.State.MoveFileCalls.Count)"

            # Драбина: мутація в межах порогу + audit drift того самого циклу.
            # Drift дає FullAuditProvider bootstrap-циклу (same-size remote для
            # audit-pending d_drift.txt -> персистований блокер AuditDrift);
            # наступний звичайний цикл несе його в AuditDriftFiles разом із
            # мутацією eqv-файла.
            $aa398DriftRoot = Join-Path $bazaSyncTestRoot "A_AutoArchiveWithAuditDrift"
            $aa398DriftLocal = Join-Path $aa398DriftRoot "local"
            $aa398DriftState = Join-Path $aa398DriftRoot "state"
            New-Item -ItemType Directory -Path $aa398DriftLocal -Force | Out-Null
            $aa398DriftFile = New-BRAVOSelfTestBazaFile -Directory $aa398DriftLocal -RelativePath "eqv_11-116.pdf" -SizeBytes 500
            [void](New-BRAVOSelfTestBazaFile -Directory $aa398DriftLocal -RelativePath "d_drift.txt" -SizeBytes 100)
            $aa398DriftProvider = & { param($aa398DriftLocal) {
                param($Snapshot)
                $pendingFile = [pscustomobject]@{
                    IsDirectory = $false
                    Path = (Join-Path $aa398DriftLocal "d_drift.txt")
                    Action = 'UploadUpdate'
                    Reason = 'розбіжність часу (той самий розмір)'
                }
                return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @($pendingFile) -LocalDirectory $aa398DriftLocal -LocalSnapshot $Snapshot
            }.GetNewClosure() } $aa398DriftLocal
            $aa398DriftSession = New-BRAVOSelfTestFakeBazaSession
            $aa398DriftSession.State.RemoteSizes['/baza_app/d_drift.txt'] = [int64]100
            $aa398DriftSession.State.RemoteSizes['/baza_app/eqv_11-116.pdf'] = [int64]500
            $aa398DriftCycle1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $aa398DriftLocal -RemoteRootPath '/baza_app' -Session $aa398DriftSession -StateRoot $aa398DriftState -BootstrapIfNeeded -FullAuditProvider $aa398DriftProvider
            [IO.File]::WriteAllBytes($aa398DriftFile, (New-Object byte[] 999))
            $aa398DriftResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $aa398DriftLocal -RemoteRootPath '/baza_app' -Session $aa398DriftSession -StateRoot $aa398DriftState -AutoArchiveMutationThreshold 5
            Test-BRAVOCondition -Condition (
                $aa398DriftCycle1.Status -eq 'AUDIT_DRIFT' -and
                $aa398DriftResult.Status -ne 'MUTATION_AUTO_ARCHIVED' -and $aa398DriftResult.Status -eq 'AUDIT_DRIFT' -and
                @($aa398DriftResult.AuditDriftFiles).Count -eq 1 -and
                $aa398DriftResult.AuditDriftFiles[0].RelativePath -eq 'd_drift.txt' -and
                $aa398DriftSession.State.MoveFileCalls.Count -eq 1 -and
                $aa398DriftSession.State.PutFilesCallCount -eq 0 -and
                -not (Test-BRAVOBazaSyncStatusSuccess -Status $aa398DriftResult.Status) -and
                (Get-BRAVOBazaFastHealthResult -SyncResult $aa398DriftResult).Healthy -eq $false
            ) -Name 'BazaSync/AutoArchiveWithSameCycleAuditDriftIsNotAutoArchivedStatus' -Failure "авто-архівування + audit drift в одному циклі: Status має бути AUDIT_DRIFT (не MUTATION_AUTO_ARCHIVED), авто-архівування все одно виконано; Cycle1=$($aa398DriftCycle1.Status),Status=$($aa398DriftResult.Status),Drift=$(@($aa398DriftResult.AuditDriftFiles).Count),Moves=$($aa398DriftSession.State.MoveFileCalls.Count),PutFiles=$($aa398DriftSession.State.PutFilesCallCount)"
        }

        # AutoArchiveMutationThreshold: N > поріг -> як і без опції (жорсткий блок)
        $aaOverRoot = Join-Path $bazaSyncTestRoot "A_AutoArchiveOverThreshold"
        $aaOverLocal = Join-Path $aaOverRoot "local"
        $aaOverState = Join-Path $aaOverRoot "state"
        New-Item -ItemType Directory -Path $aaOverLocal -Force | Out-Null
        $aaOverFile1 = New-BRAVOSelfTestBazaFile -Directory $aaOverLocal -RelativePath "one.pdf" -SizeBytes 100
        $aaOverFile2 = New-BRAVOSelfTestBazaFile -Directory $aaOverLocal -RelativePath "two.pdf" -SizeBytes 100
        $aaOverSession1 = New-BRAVOSelfTestFakeBazaSession
        $aaOverResult1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $aaOverLocal -RemoteRootPath '/baza_app' -Session $aaOverSession1 -StateRoot $aaOverState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        Test-BRAVOCondition -Condition ($aaOverResult1.Status -eq 'COMPLETE' -and $aaOverResult1.Uploaded -eq 2) `
            -Name 'BazaSync/AutoArchiveOverThresholdSetupInitialUploadSucceeds' -Failure 'setup: обидва початкові upload мають пройти успішно'

        [IO.File]::WriteAllBytes($aaOverFile1, (New-Object byte[] 150))
        [IO.File]::WriteAllBytes($aaOverFile2, (New-Object byte[] 150))
        $aaOverSession2 = New-BRAVOSelfTestFakeBazaSession
        $aaOverResult2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $aaOverLocal -RemoteRootPath '/baza_app' -Session $aaOverSession2 -StateRoot $aaOverState -AutoArchiveMutationThreshold 1
        Test-BRAVOCondition -Condition (
            $aaOverResult2.Status -eq 'MUTATION_VIOLATION' -and $aaOverResult2.MutationViolations.Count -eq 2 -and
            $aaOverSession2.State.MoveFileCalls.Count -eq 0
        ) -Name 'BazaSync/AutoArchiveOverThresholdBlocksAsWithoutOption' -Failure "кількість мутацій > порогу має блокувати рівно як без опції: Status=$($aaOverResult2.Status),Violations=$($aaOverResult2.MutationViolations.Count),MoveFile=$($aaOverSession2.State.MoveFileCalls.Count)"

        # AutoArchiveMutationThreshold: невдалий rename -> fail-closed, state не просувається
        $aaFailRoot = Join-Path $bazaSyncTestRoot "A_AutoArchiveRenameFails"
        $aaFailLocal = Join-Path $aaFailRoot "local"
        $aaFailState = Join-Path $aaFailRoot "state"
        New-Item -ItemType Directory -Path $aaFailLocal -Force | Out-Null
        $aaFailFile = New-BRAVOSelfTestBazaFile -Directory $aaFailLocal -RelativePath "will_not_archive.pdf" -SizeBytes 500
        $aaFailSession1 = New-BRAVOSelfTestFakeBazaSession
        $aaFailResult1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $aaFailLocal -RemoteRootPath '/baza_app' -Session $aaFailSession1 -StateRoot $aaFailState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        Test-BRAVOCondition -Condition ($aaFailResult1.Status -eq 'COMPLETE' -and $aaFailResult1.Uploaded -eq 1) `
            -Name 'BazaSync/AutoArchiveRenameFailsSetupInitialUploadSucceeds' -Failure 'setup: перший upload має пройти успішно перед тестом невдалого rename'

        [IO.File]::WriteAllBytes($aaFailFile, (New-Object byte[] 999))
        # Той самий session-об'єкт (див. коментар вище) — MoveFileShouldFail
        # вмикається ПІСЛЯ bootstrap-upload, щоб сам upload не постраждав.
        $aaFailSession2 = $aaFailSession1
        $aaFailSession2.State.MoveFileShouldFail = $true
        $aaFailResult2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $aaFailLocal -RemoteRootPath '/baza_app' -Session $aaFailSession2 -StateRoot $aaFailState -AutoArchiveMutationThreshold 5
        $aaFailStateRead = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $aaFailState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $aaFailResult2.Status -eq 'MUTATION_VIOLATION' -and
            $aaFailResult2.AutoArchivedMutations.Failures.Count -eq 1 -and
            $aaFailStateRead.State.Files.ContainsKey('will_not_archive.pdf')
        ) -Name 'BazaSync/AutoArchiveRenameFailureIsFailClosed' -Failure "невдалий rename під час авто-архівування має лишити state незмінним і Status=MUTATION_VIOLATION: Status=$($aaFailResult2.Status),Failures=$($aaFailResult2.AutoArchivedMutations.Failures.Count),StateHasKey=$($aaFailStateRead.State.Files.ContainsKey('will_not_archive.pdf'))"

        # New file with OLD LastWriteTime must still be discovered (timestamp is a hint, not source of truth)
        $oldTsRoot = Join-Path $bazaSyncTestRoot "A_OldTimestamp"
        $oldTsLocal = Join-Path $oldTsRoot "local"
        $oldTsState = Join-Path $oldTsRoot "state"
        New-Item -ItemType Directory -Path $oldTsLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $oldTsLocal -RelativePath "ancient_but_new.txt" -SizeBytes 77 -LastWriteTimeUtc ([datetime]::Parse('2001-01-01T00:00:00Z').ToUniversalTime()) | Out-Null
        $oldTsSession = New-BRAVOSelfTestFakeBazaSession
        $oldTsResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $oldTsLocal -RemoteRootPath '/baza_app' -Session $oldTsSession -StateRoot $oldTsState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        Test-BRAVOCondition -Condition ($oldTsResult.Status -eq 'COMPLETE' -and $oldTsResult.Uploaded -eq 1 -and $oldTsSession.State.PutFilesCallCount -eq 1) `
            -Name 'BazaSync/NewFileWithOldLastWriteTimeStillDiscovered' -Failure "новий файл зі старим LastWriteTime має бути завантажений як звичайний новий файл; Uploaded=$($oldTsResult.Uploaded)"

        # =======================================================================
        # CUTOFF (category B): NewAfterCutoff is INFO-only, does not fail Health
        # =======================================================================
        $cutoffRoot = Join-Path $bazaSyncTestRoot "B_Cutoff"
        $cutoffLocal = Join-Path $cutoffRoot "local"
        $cutoffState = Join-Path $cutoffRoot "state"
        New-Item -ItemType Directory -Path $cutoffLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $cutoffLocal -RelativePath "before1.txt" -SizeBytes 10 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $cutoffLocal -RelativePath "before2.txt" -SizeBytes 10 | Out-Null
        $cutoffSession = New-BRAVOSelfTestFakeBazaSession
        $cutoffResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $cutoffLocal -RemoteRootPath '/baza_app' -Session $cutoffSession -StateRoot $cutoffState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        Test-BRAVOCondition -Condition ($cutoffResult.Status -eq 'COMPLETE' -and $cutoffResult.DiscoveredWithinCutoff -eq 2) `
            -Name 'BazaSync/CutoffCapturesOnlyFilesPresentAtSnapshotTime' -Failure "DiscoveredWithinCutoff має дорівнювати кількості файлів на момент знімку (2); отримано $($cutoffResult.DiscoveredWithinCutoff)"

        # a file appears AFTER the sync completed
        New-BRAVOSelfTestBazaFile -Directory $cutoffLocal -RelativePath "after_cutoff.txt" -SizeBytes 10 | Out-Null
        $cutoffResultWithNew = Update-BRAVOBazaSyncResultNewAfterCutoff -SyncResult $cutoffResult -LocalDirectory $cutoffLocal -StateRoot $cutoffState
        $cutoffFastHealth = Get-BRAVOBazaFastHealthResult -SyncResult $cutoffResultWithNew
        Test-BRAVOCondition -Condition (
            $cutoffResultWithNew.NewAfterCutoff -eq 1 -and $cutoffResultWithNew.DiscoveredWithinCutoff -eq 2 -and
            $cutoffFastHealth.Healthy -eq $true -and $cutoffFastHealth.Level -eq 'OK' -and
            ($cutoffFastHealth.Info -join ' ') -match 'нові після cutoff'
        ) -Name 'BazaSync/NewAfterCutoffIsInfoOnlyNeverFailsHealth' -Failure "файл, що з'явився ПІСЛЯ sync, має бути NewAfterCutoff=1 (INFO), а НЕ впливати на Healthy; NewAfterCutoff=$($cutoffResultWithNew.NewAfterCutoff),Healthy=$($cutoffFastHealth.Healthy),Level=$($cutoffFastHealth.Level)"

        # a pre-cutoff FAILED upload must trigger a Health alert with cycle/discovered/uploaded/failed detail
        $cutoffFailRoot = Join-Path $bazaSyncTestRoot "B_CutoffFail"
        $cutoffFailLocal = Join-Path $cutoffFailRoot "local"
        $cutoffFailState = Join-Path $cutoffFailRoot "state"
        New-Item -ItemType Directory -Path $cutoffFailLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $cutoffFailLocal -RelativePath "ok1.txt" -SizeBytes 10 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $cutoffFailLocal -RelativePath "bad1.txt" -SizeBytes 10 | Out-Null
        $cutoffFailSession = New-BRAVOSelfTestFakeBazaSession -FailOnRelativePaths @('bad1.txt')
        $cutoffFailResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $cutoffFailLocal -RemoteRootPath '/baza_app' -Session $cutoffFailSession -StateRoot $cutoffFailState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        $cutoffFailHealth = Get-BRAVOBazaFastHealthResult -SyncResult $cutoffFailResult
        Test-BRAVOCondition -Condition (
            $cutoffFailResult.PendingWithinCutoff -eq 1 -and $cutoffFailResult.Failed -eq 1 -and
            $cutoffFailHealth.Healthy -eq $false -and $cutoffFailHealth.Level -eq 'CRITICAL' -and
            $cutoffFailHealth.Message -match [regex]::Escape($cutoffFailResult.CycleId) -and
            $cutoffFailHealth.Message -match 'Виявлено' -and $cutoffFailHealth.Message -match 'Передано' -and $cutoffFailHealth.Message -match 'Не передано'
        ) -Name 'BazaSync/PreCutoffFailedUploadTriggersHealthAlertWithDetail' -Failure "pending/failed в межах cutoff має alert-увати з cycle/discovered/uploaded/failed деталями; PendingWithinCutoff=$($cutoffFailResult.PendingWithinCutoff),Healthy=$($cutoffFailHealth.Healthy),Msg=$($cutoffFailHealth.Message)"

        # =======================================================================
        # FULL AUDIT / BOOTSTRAP (category E, G)
        # =======================================================================
        $bootstrapRoot = Join-Path $bazaSyncTestRoot "G_Bootstrap"
        $bootstrapLocal = Join-Path $bootstrapRoot "local"
        $bootstrapState = Join-Path $bootstrapRoot "state"
        New-Item -ItemType Directory -Path $bootstrapLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $bootstrapLocal -RelativePath "existing1.txt" -SizeBytes 111 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $bootstrapLocal -RelativePath "existing2.txt" -SizeBytes 222 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $bootstrapLocal -RelativePath "existing3.txt" -SizeBytes 333 | Out-Null

        $bootstrapAuditProvider = & { param($bootstrapLocal) {
            param($Snapshot)
            # Simulate: remote already has ALL of these files (fixture already
            # matches production reality) -- PendingFiles empty means everything
            # already matches, nothing needs (re)upload.
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @() -LocalDirectory $bootstrapLocal -LocalSnapshot $Snapshot
        }.GetNewClosure() } $bootstrapLocal

        $bootstrapSession = New-BRAVOSelfTestFakeBazaSession
        $bootstrapResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $bootstrapLocal -RemoteRootPath '/baza_app' -Session $bootstrapSession -StateRoot $bootstrapState -BootstrapIfNeeded -FullAuditProvider $bootstrapAuditProvider
        $bootstrapStateRead = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $bootstrapState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $bootstrapResult.Status -eq 'COMPLETE' -and $bootstrapResult.Bootstrap -eq $true -and
            $bootstrapResult.Uploaded -eq 0 -and $bootstrapSession.State.PutFilesCallCount -eq 0 -and
            $bootstrapStateRead.State.Files.Count -eq 3
        ) -Name 'BazaSync/BootstrapReconciliationSkipsAlreadyMatchingFiles' -Failure "bootstrap над вже-наявним на SFTP fixture НЕ має re-upload-ити файли; Uploaded=$($bootstrapResult.Uploaded),PutFiles=$($bootstrapSession.State.PutFilesCallCount),StateFiles=$($bootstrapStateRead.State.Files.Count)"

        # first run WITHOUT FullAuditProvider (but WITH -BootstrapIfNeeded) must error, not silently skip verification
        $noProviderResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $bootstrapLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot (Join-Path $bootstrapRoot "state_noaudit") -BootstrapIfNeeded
        Test-BRAVOCondition -Condition ($noProviderResult.Status -eq 'ERROR' -and $noProviderResult.Error -match 'FullAuditProvider') `
            -Name 'BazaSync/FirstRunBootstrapWithoutProviderFailsVisible' -Failure "перший запуск з -BootstrapIfNeeded, але без FullAuditProvider, має чесно повернути ERROR, а не мовчки пропустити bootstrap; Status=$($noProviderResult.Status)"

        # Full Audit periodic drift reconciliation: a file WAS verified, but audit now reports it pending (someone deleted it remotely)
        $driftRoot = Join-Path $bazaSyncTestRoot "E_Drift"
        $driftLocal = Join-Path $driftRoot "local"
        $driftState = Join-Path $driftRoot "state"
        New-Item -ItemType Directory -Path $driftLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $driftLocal -RelativePath "stable.txt" -SizeBytes 50 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $driftLocal -RelativePath "driftedaway.txt" -SizeBytes 60 | Out-Null
        $driftSession1 = New-BRAVOSelfTestFakeBazaSession
        $driftResult1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $driftLocal -RemoteRootPath '/baza_app' -Session $driftSession1 -StateRoot $driftState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        Test-BRAVOCondition -Condition ($driftResult1.Status -eq 'COMPLETE' -and $driftResult1.Uploaded -eq 2) `
            -Name 'BazaSync/DriftSetupInitialUploadSucceeds' -Failure 'setup: обидва файли мають спершу успішно завантажитись'

        $driftAuditProvider = & { param($driftLocal) {
            param($Snapshot)
            # Simulate WinSCP full compare now reporting driftedaway.txt as PENDING
            # (i.e. it no longer matches remote -- someone deleted/changed it there).
            $pendingFile = [pscustomobject]@{ IsDirectory = $false; Path = (Join-Path $driftLocal "driftedaway.txt") }
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @($pendingFile) -LocalDirectory $driftLocal -LocalSnapshot $Snapshot
        }.GetNewClosure() } $driftLocal
        $driftSession2 = New-BRAVOSelfTestFakeBazaSession
        $driftResult2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $driftLocal -RemoteRootPath '/baza_app' -Session $driftSession2 -StateRoot $driftState -BootstrapIfNeeded -ForceFullAudit -FullAuditProvider $driftAuditProvider
        Test-BRAVOCondition -Condition (
            $driftResult2.Status -eq 'COMPLETE' -and $driftResult2.Uploaded -eq 1 -and
            $driftSession2.State.PutFilesCalledFor -match 'driftedaway'
        ) -Name 'BazaSync/FullAuditDetectsOldRemoteFileGoneMissingAndReUploads' -Failure "Full Audit має виявити зниклий на remote файл і повторно завантажити САМЕ його; Status=$($driftResult2.Status),Uploaded=$($driftResult2.Uploaded),PutFilesFor=$($driftSession2.State.PutFilesCalledFor -join ',')"

        # =======================================================================
        # CONCURRENCY (section 17)
        # =======================================================================
        $lockRoot = Join-Path $bazaSyncTestRoot "Concurrency"
        $lock1 = Enter-BRAVOBazaSyncLock -StateRoot $lockRoot -Component 'BAZA_APP'
        $lock2 = Enter-BRAVOBazaSyncLock -StateRoot $lockRoot -Component 'BAZA_APP'
        Test-BRAVOCondition -Condition ($lock1.Success -eq $true -and $lock2.Success -eq $false) `
            -Name 'BazaSync/SyncLockPreventsConcurrentSameComponentSync' -Failure 'другий Enter-BRAVOBazaSyncLock на той самий компонент, поки перший тримає lock, має провалитись'
        $lock3 = Enter-BRAVOBazaSyncLock -StateRoot $lockRoot -Component 'BAZA_WWW'
        Test-BRAVOCondition -Condition ($lock3.Success -eq $true) `
            -Name 'BazaSync/SyncLockIsIndependentPerComponent' -Failure 'BAZA_APP і BAZA_WWW мають незалежні locks'
        $lock1.Stream.Dispose(); $lock3.Stream.Dispose()

        $skippedResult = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId 'x' -StartedUtc (Get-Date) -CutoffUtc (Get-Date)
        $skippedResult.Status = 'SKIPPED_CONCURRENT'
        $skippedResult.Error = 'lock held'
        # Hardening (deep review): SKIPPED_CONCURRENT сам по собі більше НЕ
        # доказ актуальності хмарної копії -- INFO лише коли останній
        # успішний цикл свіжий (див. окремі stale/never-succeeded тести нижче).
        $skippedResult.LastSuccessfulSyncUtc = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
        $skippedHealth = Get-BRAVOBazaFastHealthResult -SyncResult $skippedResult
        Test-BRAVOCondition -Condition ($skippedHealth.Healthy -eq $true -and $skippedHealth.Level -eq 'INFO') `
            -Name 'BazaSync/SkippedConcurrentIsHealthyInfoNotAlert' -Failure 'SKIPPED_CONCURRENT не повинен бути alert -- це ознака активної роботи іншого процесу'
        } catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'BazaSync/ConfigContractInvalidMutationPolicyRejected' } }
        if (Enter-BRAVOSelfTestSection -Name 'BazaSync/PerformancePlanScalesWithNewFilesNotTotalFiles' -DependsOn 'BazaSync/ConfigDefinesBazaBlock') { try {

        # =======================================================================
        # PERFORMANCE REGRESSION (section 22)
        # =======================================================================
        $perfSnapshotEntries = @{}
        $perfStateFiles = @{}
        for ($i = 0; $i -lt 100000; $i++) {
            $relPath = "verified_$i.dat"
            $perfSnapshotEntries[$relPath] = [pscustomobject]@{ RelativePath = $relPath; Size = 1000; LastWriteTimeUtc = '2026-01-01T00:00:00.0000000Z'; FullPath = "C:\fake\$relPath" }
            $perfStateFiles[$relPath] = [pscustomobject]@{ Size = 1000; LastWriteTimeUtc = '2026-01-01T00:00:00.0000000Z'; UploadedUtc = '2026-01-01T00:00:01.0000000Z'; Verified = $true }
        }
        for ($i = 0; $i -lt 10; $i++) {
            $relPath = "brandnew_$i.dat"
            $perfSnapshotEntries[$relPath] = [pscustomobject]@{ RelativePath = $relPath; Size = 500; LastWriteTimeUtc = '2026-01-01T00:00:00.0000000Z'; FullPath = "C:\fake\$relPath" }
        }
        $perfSnapshot = [pscustomobject]@{ SnapshotUtc = (Get-Date).ToUniversalTime(); Entries = $perfSnapshotEntries; Success = $true; Error = $null }
        $perfState = [pscustomobject]@{ Files = $perfStateFiles }

        $perfStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $perfPlan = Get-BRAVOBazaSyncPlan -Snapshot $perfSnapshot -State $perfState -MutationPolicy 'Fail'
        $perfStopwatch.Stop()

        Test-BRAVOCondition -Condition (
            $perfPlan.ToUpload.Count -eq 10 -and $perfPlan.TrustedSkip.Count -eq 100000 -and $perfPlan.MutationViolations.Count -eq 0
        ) -Name 'BazaSync/PerformancePlanScalesWithNewFilesNotTotalFiles' -Failure "план над 100000 verified + 10 нових файлів має дати ToUpload=10 (не торкаючись 100000 verified remote-ами); ToUpload=$($perfPlan.ToUpload.Count),TrustedSkip=$($perfPlan.TrustedSkip.Count)"

        Test-BRAVOCondition -Condition ($perfStopwatch.Elapsed.TotalSeconds -lt 30) `
            -Name 'BazaSync/PerformancePlanCompletesQuicklyOn100kFiles' -Failure "план над 100010 файлами тривав $($perfStopwatch.Elapsed.TotalSeconds) с -- підозра на випадкову O(n^2) регресію"

        $bazaHealthScriptText = [IO.File]::ReadAllText((Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"), [Text.Encoding]::UTF8)
        $bazaIncrementalBranchMatch = [regex]::Match(
            $bazaHealthScriptText,
            '(?s)\} elseif \(Test-BRAVOBazaIncrementalModeEnabled\) \{(.*?)\r?\n        \} else \{'
        )
        Test-BRAVOCondition -Condition $bazaIncrementalBranchMatch.Success `
            -Name 'BazaSync/HealthHasIncrementalFastPathBranch' -Failure 'not found: elseif(Test-BRAVOBazaIncrementalModeEnabled) branch in Get-SFTPHealthIssues'

        if ($bazaIncrementalBranchMatch.Success) {
            $bazaIncrementalBranchText = $bazaIncrementalBranchMatch.Groups[1].Value

            Test-BRAVOCondition -Condition (-not $bazaIncrementalBranchText.Contains('Invoke-WinSCPBAZAComparison')) `
                -Name 'BazaSync/FastHealthDoesNotRunFullPreviewComparison' -Failure 'Fast Health branch must not call Invoke-WinSCPBAZAComparison (full tree comparison)'

            Test-BRAVOCondition -Condition (
                $bazaIncrementalBranchText.Contains('if ($null -eq $bazaSyncResult) {') -and
                $bazaIncrementalBranchText.Contains('Invoke-BRAVOBazaComponentSyncSession')
            ) -Name 'BazaSync/HealthSynchronizesBazaBeforeCheckingWhenNoFreshResult' -Failure 'Health must call Invoke-BRAVOBazaComponentSyncSession when no fresh SyncResult is available'

            $noFreshResultGuardIndex = $bazaIncrementalBranchText.IndexOf('if ($null -eq $bazaSyncResult) {')
            $syncSessionCallIndex = $bazaIncrementalBranchText.IndexOf('Invoke-BRAVOBazaComponentSyncSession')
            Test-BRAVOCondition -Condition ($noFreshResultGuardIndex -ge 0 -and $syncSessionCallIndex -gt $noFreshResultGuardIndex) `
                -Name 'BazaSync/HealthFallbackSyncOnlyWhenNoFreshResultReused' -Failure 'Invoke-BRAVOBazaComponentSyncSession must be nested inside the null-check guard, not called unconditionally (ONE synchronization reuse)'

            Test-BRAVOCondition -Condition (
                -not $bazaIncrementalBranchText.Contains('-BootstrapIfNeeded') -and
                -not $bazaIncrementalBranchText.Contains('-FullAuditProvider')
            ) -Name 'BazaSync/HealthFallbackSyncNeverBootstraps' -Failure 'standalone Health fallback sync must not pass -BootstrapIfNeeded/-FullAuditProvider (Archive-exclusive responsibility)'

            Test-BRAVOCondition -Condition ($bazaIncrementalBranchText.Contains('$script:bazaSyncResults') -and $bazaIncrementalBranchText.Contains('ContainsKey($folderCheck.ComponentKey)')) `
                -Name 'BazaSync/HealthChecksArchivePassedResultFirst' -Failure 'Health must check $script:bazaSyncResults (Archive-provided) before falling back to its own sync'

            # Acceptance DEV-LIMS знахідка #5: fallback-шлях Health передавав
            # сирий $winSCPPath (WinSCP.com) у двигун -- guard session-функції
            # зловив це в production (fail-fast замість зависання), але wiring
            # мусить резолвити пару dll+exe так само, як Archive.
            Test-BRAVOCondition -Condition (
                $bazaIncrementalBranchText.Contains('Get-BRAVOWinSCPDotNetComponents') -and
                $bazaIncrementalBranchText.Contains('-WinSCPExecutablePath $winSCPComponents.ExecutablePath') -and
                $bazaIncrementalBranchText.Contains('-WinSCPAssemblyPath $winSCPComponents.AssemblyPath') -and
                -not $bazaIncrementalBranchText.Contains('-WinSCPExecutablePath $winSCPPath')
            ) -Name 'BazaSync/HealthWiringResolvesRealWinSCPExeForEngine' -Failure 'standalone-fallback Health має резолвити winscp.exe через Get-BRAVOWinSCPDotNetComponents (як Archive-wiring), а не передавати сирий $winSCPPath (WinSCP.com)'
        }

        # =======================================================================
        # Archive-side wiring: legacy path preserved, incremental path used when
        # enabled, SyncResult passed to Health only when actually attempted.
        # =======================================================================
        $bazaArchiveScriptText = [IO.File]::ReadAllText((Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"), [Text.Encoding]::UTF8)

        # #292: call sites Main/-SyncBAZA тепер ходять через ЄДИНИЙ диспетчер
        # Invoke-BRAVOBazaCanonicalSync; incremental- і legacy-виклики живуть
        # лише всередині нього (AST-guard: BazaSync/NoProductionBazaSyncPathBypassesCanonicalDispatcher).
        foreach ($component in @(
            @{ Key = 'BAZA_APP'; CanonicalCall = "Invoke-BRAVOBazaCanonicalSync -Component 'BAZA_APP'" }
            @{ Key = 'BAZA_WWW'; CanonicalCall = "Invoke-BRAVOBazaCanonicalSync -Component 'BAZA_WWW'" }
        )) {
            Test-BRAVOCondition -Condition ($bazaArchiveScriptText.Contains($component.CanonicalCall)) `
                -Name "BazaSync/Archive$($component.Key)UsesCanonicalSyncDispatcher" -Failure "не знайдено виклик $($component.CanonicalCall) в Archive.Runtime.ps1"
        }
        Test-BRAVOCondition -Condition (
            $bazaArchiveScriptText.Contains('Invoke-BRAVOBazaIncrementalSync -Component $Component -LocalDirectory $LocalDirectory -RemoteDirectory $RemoteDirectory') -and
            $bazaArchiveScriptText.Contains('$legacySuccess = Sync-FolderToSFTP `')
        ) -Name 'BazaSync/CanonicalDispatcherPreservesIncrementalAndLegacyBranches' `
            -Failure 'Invoke-BRAVOBazaCanonicalSync має містити і incremental-виклик, і legacy Sync-FolderToSFTP (backward-compat при явному Mode=Legacy)'

        Test-BRAVOCondition -Condition (
            $bazaArchiveScriptText.Contains('$bazaSyncResultsForHealth = @{}') -and
            $bazaArchiveScriptText.Contains("if (`$transferResults.BAZA_APP.Attempted -and `$null -ne `$script:bazaAppSyncResult) {") -and
            $bazaArchiveScriptText.Contains("`$bazaSyncResultsForHealth['BAZA_APP'] = `$script:bazaAppSyncResult") -and
            $bazaArchiveScriptText.Contains("if (`$transferResults.BAZA_WWW.Attempted -and `$null -ne `$script:bazaWWWSyncResult) {") -and
            $bazaArchiveScriptText.Contains("`$bazaSyncResultsForHealth['BAZA_WWW'] = `$script:bazaWWWSyncResult") -and
            $bazaArchiveScriptText.Contains('$healthParameters.BazaSyncResults = $bazaSyncResultsForHealth')
        ) -Name 'BazaSync/ArchivePassesSyncResultToHealthOnlyWhenAttempted' -Failure 'Archive має передавати BazaSyncResults у $healthParameters лише для компонентів, де Attempted=true -- інакше Health отримав би застарілий/нульовий результат'

        $healthReuseIndex = $bazaArchiveScriptText.IndexOf('$bazaSyncResultsForHealth = @{}')
        $healthCheckCallIndex = $bazaArchiveScriptText.IndexOf('$healthCheckResult = Invoke-BRAVOHealthCheck @healthParameters')
        Test-BRAVOCondition -Condition ($healthReuseIndex -ge 0 -and $healthCheckCallIndex -gt $healthReuseIndex) `
            -Name 'BazaSync/ArchiveBuildsBazaSyncResultsBeforeInvokingHealth' -Failure 'BazaSyncResults має бути побудовано ДО виклику Invoke-BRAVOHealthCheck'

        # =======================================================================
        # DEEP REVIEW P1-1: standalone Health НІКОЛИ не робить масовий upload
        # при відсутньому state (без -BootstrapIfNeeded -> STATE_NOT_INITIALIZED)
        # =======================================================================
        $drP11Root = Join-Path $bazaSyncTestRoot "DR_P11"
        $drP11Local = Join-Path $drP11Root "local"
        $drP11State = Join-Path $drP11Root "state"
        New-Item -ItemType Directory -Path $drP11Local -Force | Out-Null
        1..20 | ForEach-Object { New-BRAVOSelfTestBazaFile -Directory $drP11Local -RelativePath "file$_.dat" -SizeBytes 1000 | Out-Null }

        # standalone Health: БЕЗ -BootstrapIfNeeded, БЕЗ -FullAuditProvider
        $drP11HealthSession = New-BRAVOSelfTestFakeBazaSession
        $drP11HealthResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $drP11Local -RemoteRootPath '/baza_app' -Session $drP11HealthSession -StateRoot $drP11State
        Test-BRAVOCondition -Condition (
            $drP11HealthResult.Status -eq 'STATE_NOT_INITIALIZED' -and
            $drP11HealthSession.State.PutFilesCallCount -eq 0 -and
            $drP11HealthResult.Uploaded -eq 0
        ) -Name 'BazaSync/StandaloneHealthMissingStateDoesNotUploadAnything' -Failure "очікувалось STATE_NOT_INITIALIZED з 0 upload-ів (НЕ спроба залити все дерево); Status=$($drP11HealthResult.Status),PutFiles=$($drP11HealthSession.State.PutFilesCallCount),Uploaded=$($drP11HealthResult.Uploaded)"

        Test-BRAVOCondition -Condition (
            $drP11HealthResult.Status -eq 'STATE_NOT_INITIALIZED' -and $drP11HealthResult.Error -match 'BAZA_APP'
        ) -Name 'BazaSync/MissingStateWithoutBootstrapReturnsNotInitialized' -Failure "очікувався явний STATE_NOT_INITIALIZED з іменем компонента в Error; Status=$($drP11HealthResult.Status) Error=$($drP11HealthResult.Error)"

        Test-BRAVOCondition -Condition ($drP11HealthSession.State.PutFilesCallCount -eq 0) `
            -Name 'BazaSync/MissingStateNoBootstrapUploadInvocationCountIsZero' -Failure "очікувалось рівно 0 викликів PutFiles; отримано $($drP11HealthSession.State.PutFilesCallCount)"

        $drP11FastHealth = Get-BRAVOBazaFastHealthResult -SyncResult $drP11HealthResult
        Test-BRAVOCondition -Condition (
            $drP11FastHealth.Healthy -eq $false -and
            $drP11FastHealth.Message -match 'не ініціалізовано' -and $drP11FastHealth.Message -match 'bootstrap'
        ) -Name 'BazaSync/MissingStateHealthMessageExplainsBootstrap' -Failure "Health-повідомлення має пояснювати, що стан не ініціалізовано і потрібен bootstrap; Healthy=$($drP11FastHealth.Healthy) Message=$($drP11FastHealth.Message)"

        # Archive: -BootstrapIfNeeded + FullAuditProvider -> штатний bootstrap збережено
        $drP11ArchiveSession = New-BRAVOSelfTestFakeBazaSession
        $drP11ArchiveProvider = & { param($drP11Local) {
            param($Snapshot)
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @() -LocalDirectory $drP11Local -LocalSnapshot $Snapshot
        }.GetNewClosure() } $drP11Local
        $drP11ArchiveResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $drP11Local -RemoteRootPath '/baza_app' -Session $drP11ArchiveSession -StateRoot $drP11State -BootstrapIfNeeded -FullAuditProvider $drP11ArchiveProvider
        Test-BRAVOCondition -Condition (
            $drP11ArchiveResult.Status -eq 'COMPLETE' -and $drP11ArchiveResult.Bootstrap -eq $true -and $drP11ArchiveResult.Uploaded -eq 0
        ) -Name 'BazaSync/ArchiveMissingStateStillBootstraps' -Failure "Archive-шлях (BootstrapIfNeeded+FullAuditProvider) має, як і раніше, виконати bootstrap; Status=$($drP11ArchiveResult.Status),Bootstrap=$($drP11ArchiveResult.Bootstrap),Uploaded=$($drP11ArchiveResult.Uploaded)"

        # =======================================================================
        # DEEP REVIEW P1-2: INCOMPLETE/unknown статуси НІКОЛИ не провалюються в
        # Healthy (success whitelist: лише COMPLETE може дати нормальний OK)
        # =======================================================================
        $drP12SaveFailureResult = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId 'x' -StartedUtc (Get-Date) -CutoffUtc (Get-Date)
        $drP12SaveFailureResult.Status = 'INCOMPLETE'
        $drP12SaveFailureResult.Error = 'передачу завершено, але не вдалося зберегти стан: simulated'
        $drP12SaveFailureResult.Failed = 0
        $drP12SaveFailureResult.PendingWithinCutoff = 0
        $drP12SaveFailureResult.Uploaded = 5
        $drP12FastHealth = Get-BRAVOBazaFastHealthResult -SyncResult $drP12SaveFailureResult
        Test-BRAVOCondition -Condition ($drP12FastHealth.Healthy -eq $false) `
            -Name 'BazaSync/IncompleteStateSaveFailureIsNotHealthy' -Failure "INCOMPLETE з Failed=0/Pending=0 (збій Save-BRAVOBazaState ПІСЛЯ успішних upload-ів) має бути Healthy=false; отримано Healthy=$($drP12FastHealth.Healthy)"
        Test-BRAVOCondition -Condition ($drP12FastHealth.Message -notmatch 'актуальна') `
            -Name 'BazaSync/IncompleteWithZeroFailedNeverSaysCloudCurrent' -Failure "повідомлення НЕ має стверджувати актуальність хмарної копії; отримано: $($drP12FastHealth.Message)"
        } catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'BazaSync/PerformancePlanScalesWithNewFilesNotTotalFiles' } }
        if (Enter-BRAVOSelfTestSection -Name 'BazaSync/UnknownStatusFailsVisible' -DependsOn 'BazaSync/ConfigDefinesBazaBlock') { try {

        $drP12UnknownResult = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId 'x' -StartedUtc (Get-Date) -CutoffUtc (Get-Date)
        $drP12UnknownResult.Status = 'SOME_FUTURE_STATUS_NOBODY_HANDLES'
        $drP12UnknownHealth = Get-BRAVOBazaFastHealthResult -SyncResult $drP12UnknownResult
        Test-BRAVOCondition -Condition ($drP12UnknownHealth.Healthy -eq $false -and $drP12UnknownHealth.Message -match 'SOME_FUTURE_STATUS_NOBODY_HANDLES') `
            -Name 'BazaSync/UnknownStatusFailsVisible' -Failure "невідомий статус має fail visible (Healthy=false, статус названо в повідомленні), НЕ fail open; Healthy=$($drP12UnknownHealth.Healthy) Message=$($drP12UnknownHealth.Message)"

        $drP12CompleteResult = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId 'x' -StartedUtc (Get-Date) -CutoffUtc (Get-Date)
        $drP12CompleteResult.Status = 'COMPLETE'
        $drP12CompleteHealth = Get-BRAVOBazaFastHealthResult -SyncResult $drP12CompleteResult
        Test-BRAVOCondition -Condition ($drP12CompleteHealth.Healthy -eq $true -and $drP12CompleteHealth.Level -eq 'OK') `
            -Name 'BazaSync/OnlyCompleteCanProduceNormalHealthyResult' -Failure "лише справжній COMPLETE може дати Healthy=true/OK; отримано Healthy=$($drP12CompleteHealth.Healthy) Level=$($drP12CompleteHealth.Level)"

        # =======================================================================
        # DEEP REVIEW P1-3: contention (Busy) != інфраструктурний збій lock (Error)
        # =======================================================================
        $drP13Root = Join-Path $bazaSyncTestRoot "DR_P13"
        $drP13Lock1 = Enter-BRAVOBazaSyncLock -StateRoot $drP13Root -Component 'BAZA_APP'
        $drP13Lock2 = Enter-BRAVOBazaSyncLock -StateRoot $drP13Root -Component 'BAZA_APP'
        Test-BRAVOCondition -Condition ($drP13Lock1.Success -and $drP13Lock2.Success -eq $false -and $drP13Lock2.Classification -eq 'Busy') `
            -Name 'BazaSync/LockHeldByAnotherProcessReturnsBusy' -Failure "справжня sharing violation має Classification=Busy; Success=$($drP13Lock2.Success) Classification=$($drP13Lock2.Classification)"
        $drP13Lock1.Stream.Dispose()

        # ACL/readonly denial -> Error, НЕ Busy (не можна маскувати як "інший процес синхронізує")
        $drP13AclRoot = Join-Path $bazaSyncTestRoot "DR_P13_ACL"
        $drP13AclStateDir = Join-Path $drP13AclRoot "BAZA"
        New-Item -ItemType Directory -Path $drP13AclStateDir -Force | Out-Null
        $drP13AclLockPath = Join-Path $drP13AclStateDir "BAZA_APP.sync.lock"
        [IO.File]::WriteAllText($drP13AclLockPath, "x")
        [IO.File]::SetAttributes($drP13AclLockPath, [IO.FileAttributes]::ReadOnly)
        $drP13AclLock = Enter-BRAVOBazaSyncLock -StateRoot $drP13AclRoot -Component 'BAZA_APP'
        Test-BRAVOCondition -Condition ($drP13AclLock.Success -eq $false -and $drP13AclLock.Classification -eq 'Error') `
            -Name 'BazaSync/LockAccessDeniedIsErrorNotConcurrent' -Failure "ACL/readonly denial має Classification=Error, НЕ Busy; Success=$($drP13AclLock.Success) Classification=$($drP13AclLock.Classification)"

        # збій створення каталогу стану: шлях BAZA зайнятий ФАЙЛОМ
        $drP13DirRoot = Join-Path $bazaSyncTestRoot "DR_P13_DIR"
        New-Item -ItemType Directory -Path $drP13DirRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $drP13DirRoot "BAZA"), "x")
        $drP13DirLock = Enter-BRAVOBazaSyncLock -StateRoot $drP13DirRoot -Component 'BAZA_APP'
        Test-BRAVOCondition -Condition ($drP13DirLock.Success -eq $false -and $drP13DirLock.Classification -eq 'Error') `
            -Name 'BazaSync/LockDirectoryCreateFailureIsError' -Failure "шлях каталогу стану, заблокований файлом, має Classification=Error; Success=$($drP13DirLock.Success) Classification=$($drP13DirLock.Classification)"

        # generic I/O: невалідний шлях (вбудований NUL -> ArgumentException)
        $drP13BadLock = Enter-BRAVOBazaSyncLock -StateRoot (Join-Path $bazaSyncTestRoot "DR_P13_BAD`0X") -Component 'BAZA_APP'
        Test-BRAVOCondition -Condition ($drP13BadLock.Success -eq $false -and $drP13BadLock.Classification -eq 'Error') `
            -Name 'BazaSync/LockGenericIoFailureIsError' -Failure "невалідний шлях має Classification=Error; Success=$($drP13BadLock.Success) Classification=$($drP13BadLock.Classification)"

        # інфраструктурний збій lock у session-обгортці -> Status=ERROR -> Health issue
        # (WinSCP не потрібен: збій lock відбувається ДО відкриття сесії)
        $drP13SessionResult = Invoke-BRAVOBazaComponentSyncSession `
            -Component 'BAZA_APP' -LocalDirectory $drP13AclRoot -RemoteRootPath '/baza_app' `
            -RepositorySFTPUrl 'sftp://fake' -HostKey 'fake' -WinSCPAssemblyPath 'unused' -WinSCPExecutablePath 'unused' `
            -StateRoot $drP13AclRoot
        $drP13SessionHealth = Get-BRAVOBazaFastHealthResult -SyncResult $drP13SessionResult
        Test-BRAVOCondition -Condition (
            $drP13SessionResult.Status -eq 'ERROR' -and $drP13SessionResult.Status -ne 'SKIPPED_CONCURRENT' -and
            $drP13SessionHealth.Healthy -eq $false
        ) -Name 'BazaSync/LockInfrastructureFailureTriggersHealthIssue' -Failure "інфраструктурний збій lock має дати Status=ERROR (не SKIPPED_CONCURRENT) і Healthy=false; Status=$($drP13SessionResult.Status) Healthy=$($drP13SessionHealth.Healthy)"
        [IO.File]::SetAttributes($drP13AclLockPath, [IO.FileAttributes]::Normal)

        # =======================================================================
        # DEEP REVIEW P1-4: керована реконсиляція зіпсованого state (Archive-only)
        # =======================================================================
        $drP14Root = Join-Path $bazaSyncTestRoot "DR_P14"
        $drP14Local = Join-Path $drP14Root "local"
        $drP14State = Join-Path $drP14Root "state"
        New-Item -ItemType Directory -Path $drP14Local -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $drP14Local -RelativePath "existing1.txt" -SizeBytes 111 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $drP14Local -RelativePath "existing2.txt" -SizeBytes 222 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $drP14Local -RelativePath "missingremote.txt" -SizeBytes 333 | Out-Null
        $drP14StatePath = Get-BRAVOBazaStatePath -StateRoot $drP14State -Component 'BAZA_APP'
        New-Item -ItemType Directory -Path (Split-Path $drP14StatePath -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($drP14StatePath, "{ this is not valid json !!!", (New-Object Text.UTF8Encoding($false)))

        # standalone Health: без авторизації на відновлення -> STATE_INVALID, 0 upload, файл незайманий
        $drP14HealthSession = New-BRAVOSelfTestFakeBazaSession
        $drP14HealthResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $drP14Local -RemoteRootPath '/baza_app' -Session $drP14HealthSession -StateRoot $drP14State
        Test-BRAVOCondition -Condition (
            $drP14HealthResult.Status -eq 'STATE_INVALID' -and $drP14HealthSession.State.PutFilesCallCount -eq 0
        ) -Name 'BazaSync/CorruptStateStandaloneHealthDoesNotRecoverOrUpload' -Failure "standalone Health на зіпсованому state: очікувалось STATE_INVALID з 0 upload; Status=$($drP14HealthResult.Status) PutFiles=$($drP14HealthSession.State.PutFilesCallCount)"
        Test-BRAVOCondition -Condition (([IO.File]::ReadAllText($drP14StatePath)) -match 'not valid json') `
            -Name 'BazaSync/CorruptStateHealthLeavesFileUntouched' -Failure 'standalone Health-шлях НЕ має чіпати/карантинити зіпсований файл стану'

        # Archive (BootstrapIfNeeded + FullAuditProvider): реконсиляція через Full Audit
        $drP14ArchiveSession = New-BRAVOSelfTestFakeBazaSession
        $drP14ArchiveProvider = & { param($drP14Local) {
            param($Snapshot)
            # existing1/existing2 вже на remote; missingremote.txt -- ні (pending)
            $pendingFile = [pscustomobject]@{ IsDirectory = $false; Path = (Join-Path $drP14Local "missingremote.txt") }
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @($pendingFile) -LocalDirectory $drP14Local -LocalSnapshot $Snapshot
        }.GetNewClosure() } $drP14Local
        $drP14ArchiveResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $drP14Local -RemoteRootPath '/baza_app' -Session $drP14ArchiveSession -StateRoot $drP14State -BootstrapIfNeeded -FullAuditProvider $drP14ArchiveProvider
        Test-BRAVOCondition -Condition (
            $drP14ArchiveResult.Status -eq 'COMPLETE' -and
            $drP14ArchiveResult.Uploaded -eq 1 -and
            $drP14ArchiveSession.State.PutFilesCallCount -eq 1 -and
            ($drP14ArchiveSession.State.PutFilesCalledFor -match 'missingremote')
        ) -Name 'BazaSync/CorruptStateArchiveFullAuditRebuildsState' -Failure "реконсиляція має завантажити ЛИШЕ missingremote.txt (не все дерево); Status=$($drP14ArchiveResult.Status) Uploaded=$($drP14ArchiveResult.Uploaded) PutFiles=$($drP14ArchiveSession.State.PutFilesCallCount)"

        $drP14QuarantineFiles = @(Get-ChildItem -LiteralPath (Split-Path $drP14StatePath -Parent) -Filter 'BAZA_APP.state.corrupt.*.json')
        Test-BRAVOCondition -Condition ($drP14QuarantineFiles.Count -eq 1) `
            -Name 'BazaSync/CorruptStateQuarantineFileCreated' -Failure "очікувався рівно 1 карантин-файл BAZA_APP.state.corrupt.<timestamp>.json; знайдено $($drP14QuarantineFiles.Count)"
        $drP14FreshRead = Read-BRAVOBazaState -Path $drP14StatePath
        Test-BRAVOCondition -Condition ($drP14FreshRead.Exists -and -not $drP14FreshRead.Corrupt -and $drP14FreshRead.State.Files.Count -eq 3) `
            -Name 'BazaSync/CorruptStateArchiveFullAuditRebuildsStateFileValid' -Failure "після реконсиляції canonical шлях має містити свіжий валідний state з 3 файлами; Exists=$($drP14FreshRead.Exists) Corrupt=$($drP14FreshRead.Corrupt) Count=$($drP14FreshRead.State.Files.Count)"

        # збій Full Audit: докази збережено, нічого не довіряємо, масового upload немає
        $drP14FailRoot = Join-Path $bazaSyncTestRoot "DR_P14_Fail"
        $drP14FailLocal = Join-Path $drP14FailRoot "local"
        $drP14FailState = Join-Path $drP14FailRoot "state"
        New-Item -ItemType Directory -Path $drP14FailLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $drP14FailLocal -RelativePath "a.txt" -SizeBytes 10 | Out-Null
        $drP14FailStatePath = Get-BRAVOBazaStatePath -StateRoot $drP14FailState -Component 'BAZA_APP'
        New-Item -ItemType Directory -Path (Split-Path $drP14FailStatePath -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($drP14FailStatePath, "{ corrupt again", (New-Object Text.UTF8Encoding($false)))
        $drP14FailSession = New-BRAVOSelfTestFakeBazaSession
        $drP14FailProvider = { param($Snapshot) return [pscustomobject]@{ Success = $false; Error = 'simulated audit connection failure'; AlreadyMatchingRelativePaths = @(); LocalSizes = @{}; LastWriteTimesUtc = @{} } }
        $drP14FailResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $drP14FailLocal -RemoteRootPath '/baza_app' -Session $drP14FailSession -StateRoot $drP14FailState -BootstrapIfNeeded -FullAuditProvider $drP14FailProvider
        Test-BRAVOCondition -Condition (
            $drP14FailResult.Status -eq 'STATE_INVALID' -and
            $drP14FailSession.State.PutFilesCallCount -eq 0 -and
            ([IO.File]::ReadAllText($drP14FailStatePath)) -match 'corrupt again'
        ) -Name 'BazaSync/CorruptStateFailedAuditPreservesEvidence' -Failure "збій аудиту: очікувалось STATE_INVALID, 0 upload, оригінальний зіпсований файл незайманий; Status=$($drP14FailResult.Status) PutFiles=$($drP14FailSession.State.PutFilesCallCount)"
        Test-BRAVOCondition -Condition (@(Get-ChildItem -LiteralPath (Split-Path $drP14FailStatePath -Parent) -Filter '*.corrupt.*.json').Count -eq 0) `
            -Name 'BazaSync/CorruptRecoveryDoesNotTrustFilesWithoutAudit' -Failure 'збій аудиту НЕ має карантинити (нічим замінити) і НЕ має створювати новий довірений state'

        # непідтримувана SchemaVersion реконсилюється тим самим явним шляхом
        $drP14SchemaRoot = Join-Path $bazaSyncTestRoot "DR_P14_Schema"
        $drP14SchemaLocal = Join-Path $drP14SchemaRoot "local"
        $drP14SchemaState = Join-Path $drP14SchemaRoot "state"
        New-Item -ItemType Directory -Path $drP14SchemaLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $drP14SchemaLocal -RelativePath "b.txt" -SizeBytes 20 | Out-Null
        $drP14SchemaStatePath = Get-BRAVOBazaStatePath -StateRoot $drP14SchemaState -Component 'BAZA_APP'
        New-Item -ItemType Directory -Path (Split-Path $drP14SchemaStatePath -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($drP14SchemaStatePath, '{"SchemaVersion":99,"Component":"BAZA_APP","Files":{}}', (New-Object Text.UTF8Encoding($false)))
        $drP14SchemaSession = New-BRAVOSelfTestFakeBazaSession
        $drP14SchemaProvider = & { param($drP14SchemaLocal) {
            param($Snapshot)
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @() -LocalDirectory $drP14SchemaLocal -LocalSnapshot $Snapshot
        }.GetNewClosure() } $drP14SchemaLocal
        $drP14SchemaResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $drP14SchemaLocal -RemoteRootPath '/baza_app' -Session $drP14SchemaSession -StateRoot $drP14SchemaState -BootstrapIfNeeded -FullAuditProvider $drP14SchemaProvider
        Test-BRAVOCondition -Condition ($drP14SchemaResult.Status -eq 'COMPLETE' -and $drP14SchemaSession.State.PutFilesCallCount -eq 0) `
            -Name 'BazaSync/UnsupportedSchemaCanBeReconciledExplicitly' -Failure "state з непідтримуваною SchemaVersion має реконсилюватись явним Full Audit; Status=$($drP14SchemaResult.Status) PutFiles=$($drP14SchemaSession.State.PutFilesCallCount)"

        # =======================================================================
        # DEEP REVIEW P2: SFTP-сумісність імен у інкрементальному шляху
        # (легасі-правило Get-BAZARemoteNameCompatibilityIssues, O(кандидати))
        # =======================================================================
        $drLongNameCheck = Test-BRAVOBazaRemoteNameCompatibility -RelativePath "$('a' * 300).txt"
        Test-BRAVOCondition -Condition ($drLongNameCheck.Compatible -eq $false) `
            -Name 'BazaSync/FilenameCompatLongFilenameDetected' -Failure "ім'я файлу з 300 ASCII-символів має бути позначене несумісним (ліміт 255 UTF-8 байтів)"

        # UTF-8 multi-byte: 130 кириличних символів = 260 UTF-8 байтів > 255,
        # але лише 130 СИМВОЛІВ (безпечно для Windows MAX_PATH у fixture нижче)
        $drUtf8Name = ([string]([char]0x0410) * 130)
        $drUtf8Check = Test-BRAVOBazaRemoteNameCompatibility -RelativePath "$drUtf8Name.txt"
        Test-BRAVOCondition -Condition ($drUtf8Check.Compatible -eq $false -and $drUtf8Check.Utf8ByteCount -gt 255) `
            -Name 'BazaSync/FilenameCompatUtf8ByteLimitDetected' -Failure "ліміт має рахуватись у UTF-8 БАЙТАХ, не символах; Compatible=$($drUtf8Check.Compatible) Bytes=$($drUtf8Check.Utf8ByteCount)"

        $drLongDirCheck = Test-BRAVOBazaRemoteNameCompatibility -RelativePath "$('d' * 300)\file.txt"
        Test-BRAVOCondition -Condition ($drLongDirCheck.Compatible -eq $false -and $drLongDirCheck.IsDirectory -eq $true) `
            -Name 'BazaSync/FilenameCompatIncompatibleDirectoryDetected' -Failure "задовгий сегмент КАТАЛОГУ має бути позначений IsDirectory=true несумісним; Compatible=$($drLongDirCheck.Compatible) IsDirectory=$($drLongDirCheck.IsDirectory)"

        Test-BRAVOCondition -Condition ((Test-BRAVOBazaRemoteNameCompatibility -RelativePath "normal\path\file.txt").Compatible -eq $true) `
            -Name 'BazaSync/FilenameCompatNormalPathIsCompatible' -Failure 'звичайний короткий шлях має бути сумісним'

        # інтеграція: несумісний кандидат пропускається з явним результатом,
        # сумісний -- завантажується; жодного remote-виклику для несумісного
        $drP2NameRoot = Join-Path $bazaSyncTestRoot "DR_P2_Name"
        $drP2NameLocal = Join-Path $drP2NameRoot "local"
        $drP2NameState = Join-Path $drP2NameRoot "state"
        New-Item -ItemType Directory -Path $drP2NameLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $drP2NameLocal -RelativePath "normal.txt" -SizeBytes 50 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $drP2NameLocal -RelativePath "$drUtf8Name.txt" -SizeBytes 50 | Out-Null
        $drP2NameSession = New-BRAVOSelfTestFakeBazaSession
        $drP2NameResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $drP2NameLocal -RemoteRootPath '/baza_app' -Session $drP2NameSession -StateRoot $drP2NameState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        Test-BRAVOCondition -Condition (
            $drP2NameResult.Uploaded -eq 1 -and
            $drP2NameSession.State.PutFilesCallCount -eq 1 -and
            (@($drP2NameResult.IncompatibleFiles).Count -eq 1) -and
            ($drP2NameResult.IncompatibleFiles[0].RelativePath -match [regex]::Escape($drUtf8Name.Substring(0, 20)))
        ) -Name 'BazaSync/FilenameCompatCompatibleCandidateStillUploads' -Failure "очікувався рівно 1 upload (normal.txt) і 1 явний incompatible-результат; Uploaded=$($drP2NameResult.Uploaded) PutFiles=$($drP2NameSession.State.PutFilesCallCount) Incompatible=$(@($drP2NameResult.IncompatibleFiles).Count)"
        } catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'BazaSync/UnknownStatusFailsVisible' } }
        if (Enter-BRAVOSelfTestSection -Name 'BazaSync/FilenameCompatIncompatibleProducesExplicitResult' -DependsOn 'BazaSync/UnknownStatusFailsVisible') { try {

        $drP2NameHealth = Get-BRAVOBazaFastHealthResult -SyncResult $drP2NameResult
        Test-BRAVOCondition -Condition ($drP2NameHealth.Healthy -eq $false -and $drP2NameHealth.Message -match [regex]::Escape($drUtf8Name.Substring(0, 20))) `
            -Name 'BazaSync/FilenameCompatIncompatibleProducesExplicitResult' -Failure "Health має бути Healthy=false з ТОЧНИМ шляхом проблемного файлу в повідомленні; Healthy=$($drP2NameHealth.Healthy)"

        Test-BRAVOCondition -Condition ($drP2NameSession.State.PutFilesCallCount -eq $drP2NameResult.Uploaded) `
            -Name 'BazaSync/FilenameCompatNoExtraRemoteCallsForIncompatible' -Failure "PutFiles == Uploaded: несумісний кандидат має давати НУЛЬ remote-викликів (перевірка локальна); PutFiles=$($drP2NameSession.State.PutFilesCallCount) Uploaded=$($drP2NameResult.Uploaded)"

        # =======================================================================
        # DEEP REVIEW P2: checkpoint -- атомна публікація і видимий результат
        # =======================================================================
        $drCpSyncResult = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId 'cp-test' -StartedUtc (Get-Date).ToUniversalTime() -CutoffUtc (Get-Date).ToUniversalTime()
        $drCpSyncResult.Status = 'COMPLETE'
        $drCpSyncResult.CompletedUtc = (Get-Date).ToUniversalTime()
        $drCpSyncResult.Uploaded = 1

        $drCpSessionOk = New-BRAVOSelfTestFakeBazaSession
        $drCpOutcomeOk = Write-BRAVOBazaRemoteCheckpoint -Session $drCpSessionOk -RemoteRootPath '/baza_app' -SyncResult $drCpSyncResult
        Test-BRAVOCondition -Condition (
            $drCpOutcomeOk.Attempted -eq $true -and $drCpOutcomeOk.Published -eq $true -and
            $drCpSessionOk.State.MoveFileCalls.Count -eq 1 -and
            ($drCpSessionOk.State.MoveFileCalls[0] -match '\.tmp-') -and
            ($drCpSessionOk.State.MoveFileCalls[0] -match '\.bravo-sync\.json$')
        ) -Name 'BazaSync/CheckpointPublishIsAtomicViaTempThenMove' -Failure "публікація checkpoint має бути атомною: upload у тимчасове remote-ім'я + MoveFile у канонічне; Attempted=$($drCpOutcomeOk.Attempted) Published=$($drCpOutcomeOk.Published) MoveFileCalls=$($drCpSessionOk.State.MoveFileCalls.Count)"

        $drCpSessionMoveFail = New-BRAVOSelfTestFakeBazaSession -MoveFileShouldFail
        $drCpOutcomeMoveFail = Write-BRAVOBazaRemoteCheckpoint -Session $drCpSessionMoveFail -RemoteRootPath '/baza_app' -SyncResult $drCpSyncResult
        Test-BRAVOCondition -Condition (
            $drCpOutcomeMoveFail.Attempted -eq $true -and $drCpOutcomeMoveFail.Published -eq $false -and
            -not [string]::IsNullOrWhiteSpace($drCpOutcomeMoveFail.Error)
        ) -Name 'BazaSync/CheckpointMoveFailureReportsPublishedFalse' -Failure "збій rename має дати Published=false із заповненим Error; Published=$($drCpOutcomeMoveFail.Published) Error=$($drCpOutcomeMoveFail.Error)"

        $bazaSyncModuleText = [IO.File]::ReadAllText((Join-Path $root "modules\BRAVO.BazaSync\BRAVO.BazaSync.psm1"), [Text.Encoding]::UTF8)
        Test-BRAVOCondition -Condition (
            $bazaSyncModuleText.Contains('$syncResult.CheckpointAttempted = $checkpointOutcome.Attempted') -and
            $bazaSyncModuleText.Contains('$syncResult.CheckpointPublished = $checkpointOutcome.Published') -and
            $bazaSyncModuleText.Contains('$syncResult.CheckpointError = $checkpointOutcome.Error') -and
            -not $bazaSyncModuleText.Contains('[void](Write-BRAVOBazaRemoteCheckpoint')
        ) -Name 'BazaSync/CheckpointResultNoLongerDiscarded' -Failure 'Invoke-BRAVOBazaComponentSyncSession має записувати результат checkpoint у SyncResult, а не відкидати через [void](...)'

        # COMPLETE sync + збій публікації checkpoint -> WARNING, Healthy=true (самі дані в безпеці)
        $drCpHealthResult = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId 'cp2' -StartedUtc (Get-Date) -CutoffUtc (Get-Date)
        $drCpHealthResult.Status = 'COMPLETE'
        $drCpHealthResult.CheckpointAttempted = $true
        $drCpHealthResult.CheckpointPublished = $false
        $drCpHealthResult.CheckpointError = 'simulated'
        $drCpFastHealth = Get-BRAVOBazaFastHealthResult -SyncResult $drCpHealthResult
        Test-BRAVOCondition -Condition ($drCpFastHealth.Healthy -eq $true -and $drCpFastHealth.Level -eq 'WARNING') `
            -Name 'BazaSync/CheckpointFailureIsWarningNotCritical' -Failure "збій публікації checkpoint при успішному циклі має бути Healthy=true/WARNING; Healthy=$($drCpFastHealth.Healthy) Level=$($drCpFastHealth.Level)"

        # =======================================================================
        # DEEP REVIEW P2: збій періодичного Full Audit має бути ВИДИМИМ
        # =======================================================================
        $drAuditRoot = Join-Path $bazaSyncTestRoot "DR_P2_Audit"
        $drAuditLocal = Join-Path $drAuditRoot "local"
        $drAuditState = Join-Path $drAuditRoot "state"
        New-Item -ItemType Directory -Path $drAuditLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $drAuditLocal -RelativePath "a.txt" -SizeBytes 10 | Out-Null
        $drAuditSetupResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $drAuditLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $drAuditState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        Test-BRAVOCondition -Condition ($drAuditSetupResult.Status -eq 'COMPLETE') `
            -Name 'BazaSync/AuditVisibilitySetupSucceeds' -Failure "setup-синхронізація має пройти успішно; Status=$($drAuditSetupResult.Status)"

        $drAuditFailProvider = { param($Snapshot) return [pscustomobject]@{ Success = $false; Error = 'simulated periodic audit connection failure'; AlreadyMatchingRelativePaths = @(); LocalSizes = @{}; LastWriteTimesUtc = @{} } }
        $drAuditResult2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $drAuditLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $drAuditState -BootstrapIfNeeded -ForceFullAudit -FullAuditProvider $drAuditFailProvider
        Test-BRAVOCondition -Condition (
            $drAuditResult2.Status -eq 'COMPLETE' -and
            $drAuditResult2.FullAuditAttempted -eq $true -and
            $drAuditResult2.FullAuditSucceeded -eq $false -and
            $drAuditResult2.FullAuditError -match 'simulated periodic audit'
        ) -Name 'BazaSync/PeriodicFullAuditFailureIsVisibleInSyncResult' -Failure "інкрементальний sync має продовжувати працювати (COMPLETE), але FullAuditAttempted/Succeeded/Error мають бути в SyncResult; Status=$($drAuditResult2.Status) Attempted=$($drAuditResult2.FullAuditAttempted) Succeeded=$($drAuditResult2.FullAuditSucceeded) Error=$($drAuditResult2.FullAuditError)"

        $drAuditHealth = Get-BRAVOBazaFastHealthResult -SyncResult $drAuditResult2
        Test-BRAVOCondition -Condition ($drAuditHealth.Healthy -eq $true -and $drAuditHealth.Level -eq 'WARNING') `
            -Name 'BazaSync/SyncSucceededAuditFailedIsAtLeastWarning' -Failure "sync успішний + audit провалився = щонайменше WARNING, ніколи не мовчазне \"все верифіковано\"; Healthy=$($drAuditHealth.Healthy) Level=$($drAuditHealth.Level)"
        Test-BRAVOCondition -Condition (($drAuditHealth.Info -join ' ') -match 'Full Audit') `
            -Name 'BazaSync/AuditFailureNeverSilentlyFullyVerified' -Failure "збій аудиту має бути явно названий у Health Info; Info=$($drAuditHealth.Info -join '; ')"

        # =======================================================================
        # DEEP REVIEW: SKIPPED_CONCURRENT hardening -- "інший процес активний"
        # НЕ доказ актуальності; свіжість LastSuccessfulSyncUtc вирішує рівень
        # =======================================================================
        $drScFresh = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId 'sc1' -StartedUtc (Get-Date) -CutoffUtc (Get-Date)
        $drScFresh.Status = 'SKIPPED_CONCURRENT'
        $drScFresh.LastSuccessfulSyncUtc = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
        $drScFresh.Error = 'lock held'
        $drScFreshHealth = Get-BRAVOBazaFastHealthResult -SyncResult $drScFresh
        Test-BRAVOCondition -Condition ($drScFreshHealth.Healthy -eq $true -and $drScFreshHealth.Level -eq 'INFO') `
            -Name 'BazaSync/SkippedConcurrentWithRecentSuccessIsInfo' -Failure "concurrent + свіжий успішний цикл = Healthy=true/INFO (deferred); Healthy=$($drScFreshHealth.Healthy) Level=$($drScFreshHealth.Level)"

        $drScStale = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId 'sc2' -StartedUtc (Get-Date) -CutoffUtc (Get-Date)
        $drScStale.Status = 'SKIPPED_CONCURRENT'
        $drScStale.LastSuccessfulSyncUtc = (Get-Date).ToUniversalTime().AddDays(-10).ToString('o')
        $drScStale.Error = 'lock held'
        $drScStaleHealth = Get-BRAVOBazaFastHealthResult -SyncResult $drScStale
        Test-BRAVOCondition -Condition ($drScStaleHealth.Healthy -eq $false -and $drScStaleHealth.Level -eq 'WARNING') `
            -Name 'BazaSync/SkippedConcurrentWithStaleSuccessIsWarning' -Failure "concurrent + застарілий успішний цикл = Healthy=false/WARNING; Healthy=$($drScStaleHealth.Healthy) Level=$($drScStaleHealth.Level)"

        $drScNever = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId 'sc3' -StartedUtc (Get-Date) -CutoffUtc (Get-Date)
        $drScNever.Status = 'SKIPPED_CONCURRENT'
        $drScNever.LastSuccessfulSyncUtc = $null
        $drScNever.Error = 'lock held'
        $drScNeverHealth = Get-BRAVOBazaFastHealthResult -SyncResult $drScNever
        Test-BRAVOCondition -Condition ($drScNeverHealth.Healthy -eq $false -and $drScNeverHealth.Level -eq 'WARNING') `
            -Name 'BazaSync/SkippedConcurrentNeverSucceededIsWarning' -Failure "concurrent + жодного успішного циклу = Healthy=false/WARNING; Healthy=$($drScNeverHealth.Healthy) Level=$($drScNeverHealth.Level)"

        Test-BRAVOCondition -Condition ($drScFreshHealth.Message -notmatch 'хмарна копія актуальна') `
            -Name 'BazaSync/SkippedConcurrentFreshNeverClaimsCloudCurrent' -Failure "SKIPPED_CONCURRENT (fresh) НЕ має містити штатне повідомлення про актуальність; отримано: $($drScFreshHealth.Message)"
        Test-BRAVOCondition -Condition ($drScStaleHealth.Message -notmatch 'хмарна копія актуальна') `
            -Name 'BazaSync/SkippedConcurrentStaleNeverClaimsCloudCurrent' -Failure "SKIPPED_CONCURRENT (stale) НЕ має містити штатне повідомлення про актуальність; отримано: $($drScStaleHealth.Message)"
        Test-BRAVOCondition -Condition ($drScNeverHealth.Message -notmatch 'хмарна копія актуальна') `
            -Name 'BazaSync/SkippedConcurrentNeverSucceededNeverClaimsCloudCurrent' -Failure "SKIPPED_CONCURRENT (never) НЕ має містити штатне повідомлення про актуальність; отримано: $($drScNeverHealth.Message)"

        # =======================================================================
        # DEEP REVIEW P2: config-контракт -- жодних ігнорованих BAZA-налаштувань
        # =======================================================================
        $global:backupMonitoring = @{ SFTP = @{ BAZA = @{ SynchronizeBeforeHealth = $false } } }
        $drCfgError1 = $null
        try { [void](Get-BRAVOBazaSettingsEffective) } catch { $drCfgError1 = $_.Exception.Message }
        Test-BRAVOCondition -Condition ($null -ne $drCfgError1 -and $drCfgError1 -match 'SynchronizeBeforeHealth' -and $drCfgError1 -match 'Legacy') `
            -Name 'BazaSync/ConfigContractSynchronizeBeforeHealthFalseRejectedForIncremental' -Failure "SynchronizeBeforeHealth=false при Mode=IncrementalAppendOnly має відхилятись із вказівкою на Mode=Legacy, а не мовчки ігноруватись; Error=$drCfgError1"

        $global:backupMonitoring = @{ SFTP = @{ BAZA = @{ FastHealthEnabled = $false } } }
        $drCfgError2 = $null
        try { [void](Get-BRAVOBazaSettingsEffective) } catch { $drCfgError2 = $_.Exception.Message }
        Test-BRAVOCondition -Condition ($null -ne $drCfgError2 -and $drCfgError2 -match 'FastHealthEnabled' -and $drCfgError2 -match 'Legacy') `
            -Name 'BazaSync/ConfigContractFastHealthEnabledFalseRejectedForIncremental' -Failure "FastHealthEnabled=false при Mode=IncrementalAppendOnly має відхилятись із вказівкою на Mode=Legacy (без мовчазного 50+ ГБ preview); Error=$drCfgError2"

        $global:backupMonitoring = @{ SFTP = @{ BAZA = @{ Mode = 'Legacy'; SynchronizeBeforeHealth = $false; FastHealthEnabled = $false } } }
        $drCfgLegacy = $null
        $drCfgError3 = $null
        try { $drCfgLegacy = Get-BRAVOBazaSettingsEffective } catch { $drCfgError3 = $_.Exception.Message }
        Test-BRAVOCondition -Condition ($null -eq $drCfgError3 -and $null -ne $drCfgLegacy -and $drCfgLegacy.Mode -eq 'Legacy') `
            -Name 'BazaSync/ConfigContractLegacyModeAllowsBothSwitchesOff' -Failure "Mode=Legacy -- ЄДИНИЙ підтримуваний шлях до старої поведінки, обидва прапорці false там дозволені; Error=$drCfgError3"

        $global:backupMonitoring = @{ SFTP = @{ } }
        $drCfgDefaults = $null
        $drCfgError4 = $null
        try { $drCfgDefaults = Get-BRAVOBazaSettingsEffective } catch { $drCfgError4 = $_.Exception.Message }
        Test-BRAVOCondition -Condition (
            $null -eq $drCfgError4 -and $null -ne $drCfgDefaults -and
            $drCfgDefaults.Mode -eq 'IncrementalAppendOnly' -and
            $drCfgDefaults.SynchronizeBeforeHealth -eq $true -and $drCfgDefaults.FastHealthEnabled -eq $true
        ) -Name 'BazaSync/ConfigContractDefaultsDoNotThrow' -Failure "відсутність BAZA-ключів має давати типові true/true без помилки; Error=$drCfgError4"
        $global:backupMonitoring = $null
        } catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'BazaSync/FilenameCompatIncompatibleProducesExplicitResult' } }
        if (Enter-BRAVOSelfTestSection -Name 'BazaSync/NoDeleteAnywhereInIncrementalEngine' -DependsOn 'BazaSync/FilenameCompatIncompatibleProducesExplicitResult') { try {

        # =======================================================================
        # DEEP REVIEW acceptance 10: жодного -delete / remote-видалення даних
        # =======================================================================
        # Кожен RemoveFiles у модулі сміє торкатись ЛИШЕ власних
        # checkpoint-артефактів двигуна (tmp-файл або канонічний
        # .bravo-sync.json при явній заміні) -- ЖОДНОГО видалення даних.
        $drRemoveFilesLines = @(
            ($bazaSyncModuleText -split "`n") | Where-Object { $_ -match '\.RemoveFiles\(' }
        )
        $drRemoveFilesOffCheckpoint = @($drRemoveFilesLines | Where-Object { $_ -notmatch 'RemoteCheckpointPath' })
        Test-BRAVOCondition -Condition (
            -not $bazaSyncModuleText.Contains('SynchronizeDirectories') -and
            -not $bazaSyncModuleText.Contains('SynchronizationMode') -and
            $drRemoveFilesLines.Count -eq 3 -and
            $drRemoveFilesOffCheckpoint.Count -eq 0 -and
            $bazaSyncModuleText.Contains('[void]$Session.RemoveFiles($temporaryRemoteCheckpointPath)') -and
            $bazaSyncModuleText.Contains('$canonicalRemovalResult = $Session.RemoveFiles($canonicalRemoteCheckpointPath)')
        ) -Name 'BazaSync/NoDeleteAnywhereInIncrementalEngine' -Failure "інкрементальний engine НЕ має жодного remote-видалення даних: без SynchronizeDirectories/SynchronizationMode, RemoveFiles лише для ВЛАСНИХ checkpoint-артефактів (2x tmp cleanup + канонічний при заміні, результат якого перевіряється); RemoveFilesLines=$($drRemoveFilesLines.Count), поза checkpoint: $($drRemoveFilesOffCheckpoint.Count)"

        $drPutFilesCalls = @([regex]::Matches($bazaSyncModuleText, '\$Session\.PutFiles\([^\r\n]*'))
        Test-BRAVOCondition -Condition (
            $drPutFilesCalls.Count -ge 2 -and
            (@($drPutFilesCalls | Where-Object { $_.Value -notmatch ',\s*\$false,' }).Count -eq 0)
        ) -Name 'BazaSync/PutFilesNeverDeletesLocalSource' -Failure "кожен PutFiles має передавати remove=`$false (ніколи не видаляти локальне джерело після upload); calls=$($drPutFilesCalls.Count)"

        # =======================================================================
        # HARDENING ROUND 2, P1: несумісні імена НЕ дають успішного циклу
        # (без COMPLETE, без просування LastSuccessfulSyncUtc/LastCycleId,
        # без "успішного" checkpoint; сумісні файли того ж циклу передаються)
        # =======================================================================
        $hr2NameRoot = Join-Path $bazaSyncTestRoot "HR2_Name"
        $hr2NameLocal = Join-Path $hr2NameRoot "local"
        $hr2NameState = Join-Path $hr2NameRoot "state"
        New-Item -ItemType Directory -Path $hr2NameLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr2NameLocal -RelativePath "compatible_seed.txt" -SizeBytes 10 | Out-Null

        # цикл 1: лише сумісний файл -> COMPLETE, provenance просувається
        $hr2Cycle1Result = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr2NameLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr2NameState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        $hr2StateAfterCycle1 = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $hr2NameState -Component 'BAZA_APP')
        $hr2ProvenanceUtc = [string]$hr2StateAfterCycle1.State.LastSuccessfulSyncUtc
        $hr2ProvenanceCycleId = [string]$hr2StateAfterCycle1.State.LastCycleId

        # цикл 2: додається несумісний кандидат (260 UTF-8 байтів > 246)
        New-BRAVOSelfTestBazaFile -Directory $hr2NameLocal -RelativePath "$drUtf8Name.txt" -SizeBytes 20 | Out-Null
        $hr2Cycle2Session = New-BRAVOSelfTestFakeBazaSession
        $hr2Cycle2Result = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr2NameLocal -RemoteRootPath '/baza_app' -Session $hr2Cycle2Session -StateRoot $hr2NameState
        Test-BRAVOCondition -Condition (
            $hr2Cycle1Result.Status -eq 'COMPLETE' -and
            $hr2Cycle2Result.Status -eq 'INCOMPATIBLE_NAME' -and
            $hr2Cycle2Result.Status -ne 'COMPLETE' -and
            $hr2Cycle2Result.Error -match [regex]::Escape($drUtf8Name.Substring(0, 20))
        ) -Name 'BazaSync/IncompatibleCandidateDoesNotProduceComplete' -Failure "цикл із несумісним кандидатом має явний статус INCOMPATIBLE_NAME, ніколи COMPLETE; Cycle1=$($hr2Cycle1Result.Status) Cycle2=$($hr2Cycle2Result.Status) Error=$($hr2Cycle2Result.Error)"

        $hr2StateAfterCycle2 = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $hr2NameState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            -not [string]::IsNullOrWhiteSpace($hr2ProvenanceUtc) -and
            [string]$hr2StateAfterCycle2.State.LastSuccessfulSyncUtc -ceq $hr2ProvenanceUtc -and
            [string]$hr2StateAfterCycle2.State.LastCycleId -ceq $hr2ProvenanceCycleId -and
            [string]$hr2Cycle2Result.LastSuccessfulSyncUtc -ceq $hr2ProvenanceUtc
        ) -Name 'BazaSync/IncompatibleCandidateDoesNotAdvanceLastSuccessfulSyncUtc' -Failure "LastSuccessfulSyncUtc/LastCycleId НЕ мають просуватись циклом з несумісними іменами; було=$hr2ProvenanceUtc стало=$($hr2StateAfterCycle2.State.LastSuccessfulSyncUtc)"

        # checkpoint для такого циклу: Write-BRAVOBazaRemoteCheckpoint сам
        # відмовляється (Status != COMPLETE -> Attempted=false, нуль
        # звернень до сесії), а session-обгортка додатково гейтить виклик.
        $hr2CheckpointSession = New-BRAVOSelfTestFakeBazaSession
        $hr2CheckpointOutcome = Write-BRAVOBazaRemoteCheckpoint -Session $hr2CheckpointSession -RemoteRootPath '/baza_app' -SyncResult $hr2Cycle2Result
        Test-BRAVOCondition -Condition (
            $hr2CheckpointOutcome.Attempted -eq $false -and $hr2CheckpointOutcome.Published -eq $false -and
            $hr2CheckpointSession.State.PutFilesCallCount -eq 0 -and
            $hr2CheckpointSession.State.MoveFileCalls.Count -eq 0 -and
            $bazaSyncModuleText.Contains('if ($WriteCheckpoint -and $syncResult.Status -eq ''COMPLETE'')')
        ) -Name 'BazaSync/IncompatibleCandidateDoesNotPublishSuccessfulCheckpoint' -Failure "INCOMPATIBLE_NAME цикл не має публікувати successful checkpoint (обидва gate: сам Write-* і session-обгортка); Attempted=$($hr2CheckpointOutcome.Attempted) PutFiles=$($hr2CheckpointSession.State.PutFilesCallCount)"

        # змішаний цикл: сумісний новий файл передається, стан для нього
        # комітиться, але цикл усе одно НЕ COMPLETE
        New-BRAVOSelfTestBazaFile -Directory $hr2NameLocal -RelativePath "compatible_new.txt" -SizeBytes 30 | Out-Null
        $hr2MixedSession = New-BRAVOSelfTestFakeBazaSession
        $hr2MixedResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr2NameLocal -RemoteRootPath '/baza_app' -Session $hr2MixedSession -StateRoot $hr2NameState
        $hr2MixedStateRead = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $hr2NameState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $hr2MixedResult.Status -eq 'INCOMPATIBLE_NAME' -and
            $hr2MixedResult.Uploaded -eq 1 -and
            $hr2MixedSession.State.PutFilesCallCount -eq 1 -and
            ($hr2MixedSession.State.PutFilesCalledFor -match 'compatible_new') -and
            $hr2MixedStateRead.State.Files.ContainsKey('compatible_new.txt') -and
            [bool]$hr2MixedStateRead.State.Files['compatible_new.txt'].Verified -eq $true -and
            -not $hr2MixedStateRead.State.Files.ContainsKey("$drUtf8Name.txt")
        ) -Name 'BazaSync/MixedCompatibleAndIncompatibleUploadsCompatibleButCycleNotComplete' -Failure "сумісний кандидат того ж циклу має передатись і закомітитись у state, але цикл НЕ COMPLETE; Status=$($hr2MixedResult.Status) Uploaded=$($hr2MixedResult.Uploaded) PutFiles=$($hr2MixedSession.State.PutFilesCallCount)"

        # =======================================================================
        # HARDENING ROUND 2, P1: явний ResumeSupport=On + легасі-ліміт 246
        # UTF-8 байтів на ім'я файлу (255 - 9 байт ".filepart")
        # =======================================================================
        Test-BRAVOCondition -Condition ($hr2MixedSession.State.LastResumeSupportState -eq 'On') `
            -Name 'BazaSync/ResumeSupportExplicitlyEnabledForTargetedUpload' -Failure "цільовий upload має ЯВНО вмикати TransferOptions.ResumeSupport.State=On (легасі-семантика resumesupport=on); отримано '$($hr2MixedSession.State.LastResumeSupportState)'"

        Test-BRAVOCondition -Condition ((Test-BRAVOBazaRemoteNameCompatibility -RelativePath ('a' * 246)).Compatible -eq $true) `
            -Name 'BazaSync/FileName246Utf8BytesAccepted' -Failure "ім'я файлу рівно в 246 UTF-8 байтів має проходити (246 = 255 - 9 байт '.filepart')"

        # 247 байтів: чиста перевірка на ASCII-рядку + поведінкова на
        # РЕАЛЬНОМУ файлі (123 кириличні + 1 ASCII = 247 UTF-8 байтів, але
        # лише 124 символи -- безпечно для Windows MAX_PATH)
        $hr2Name247 = (([string]([char]0x0410)) * 123) + 'a'
        $hr2Limit247Root = Join-Path $bazaSyncTestRoot "HR2_247"
        $hr2Limit247Local = Join-Path $hr2Limit247Root "local"
        New-Item -ItemType Directory -Path $hr2Limit247Local -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr2Limit247Local -RelativePath $hr2Name247 -SizeBytes 10 | Out-Null
        $hr2Limit247Session = New-BRAVOSelfTestFakeBazaSession
        $hr2Limit247Result = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr2Limit247Local -RemoteRootPath '/baza_app' -Session $hr2Limit247Session -StateRoot (Join-Path $hr2Limit247Root "state") -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        Test-BRAVOCondition -Condition (
            (Test-BRAVOBazaRemoteNameCompatibility -RelativePath ('a' * 247)).Compatible -eq $false -and
            $hr2Limit247Result.Status -eq 'INCOMPATIBLE_NAME' -and
            $hr2Limit247Session.State.PutFilesCallCount -eq 0
        ) -Name 'BazaSync/FileName247Utf8BytesRejectedBeforePutFiles' -Failure "247 UTF-8 байтів має відхилятись ДО PutFiles (валідація узгоджена з '.filepart'); Compatible247=$((Test-BRAVOBazaRemoteNameCompatibility -RelativePath ('a' * 247)).Compatible) Status=$($hr2Limit247Result.Status) PutFiles=$($hr2Limit247Session.State.PutFilesCallCount)"

        $hr2MultibyteCheck = Test-BRAVOBazaRemoteNameCompatibility -RelativePath (([string]([char]0x0410)) * 124)
        Test-BRAVOCondition -Condition (
            $hr2MultibyteCheck.Compatible -eq $false -and $hr2MultibyteCheck.Utf8ByteCount -eq 248
        ) -Name 'BazaSync/MultibyteUtf8FilenameUsesByteCount' -Failure "ліміт рахується в UTF-8 БАЙТАХ: 124 кириличні символи = 248 байтів > 246, хоча символів лише 124; Compatible=$($hr2MultibyteCheck.Compatible) Bytes=$($hr2MultibyteCheck.Utf8ByteCount)"

        Test-BRAVOCondition -Condition ($hr2Limit247Session.State.PutFilesCallCount -eq 0 -and $hr2Limit247Session.State.MoveFileCalls.Count -eq 0) `
            -Name 'BazaSync/IncompatibleNameMakesZeroRemoteUploadCalls' -Failure "цикл, де єдиний кандидат несумісний, має зробити НУЛЬ remote-викликів передачі; PutFiles=$($hr2Limit247Session.State.PutFilesCallCount)"

        # =======================================================================
        # HARDENING ROUND 2, P2: заміна checkpoint ПІСЛЯ першого циклу
        # (fake MoveFile моделює SFTP "rename не перезаписує наявну ціль")
        # =======================================================================
        $hr2CpResult = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId 'hr2-cp' -StartedUtc (Get-Date).ToUniversalTime() -CutoffUtc (Get-Date).ToUniversalTime()
        $hr2CpResult.Status = 'COMPLETE'
        $hr2CpResult.CompletedUtc = (Get-Date).ToUniversalTime()
        $hr2CpSession = New-BRAVOSelfTestFakeBazaSession
        $hr2CpCanonicalPath = '/baza_app/.bravo-sync.json'

        $hr2CpFirst = Write-BRAVOBazaRemoteCheckpoint -Session $hr2CpSession -RemoteRootPath '/baza_app' -SyncResult $hr2CpResult
        Test-BRAVOCondition -Condition (
            $hr2CpFirst.Published -eq $true -and
            $hr2CpSession.State.RemoteSizes.ContainsKey($hr2CpCanonicalPath)
        ) -Name 'BazaSync/CheckpointFirstPublishSucceeds' -Failure "перша публікація checkpoint має пройти (канонічної цілі ще немає); Published=$($hr2CpFirst.Published) Error=$($hr2CpFirst.Error)"

        $hr2CpSecond = Write-BRAVOBazaRemoteCheckpoint -Session $hr2CpSession -RemoteRootPath '/baza_app' -SyncResult $hr2CpResult
        Test-BRAVOCondition -Condition (
            $hr2CpSecond.Published -eq $true -and
            $hr2CpSession.State.RemoteSizes.ContainsKey($hr2CpCanonicalPath)
        ) -Name 'BazaSync/CheckpointSecondPublishReplacesOrSupersedesExisting' -Failure "друга публікація (канонічний checkpoint ВЖЕ існує) має замінити його, а не падати щоциклу; Published=$($hr2CpSecond.Published) Error=$($hr2CpSecond.Error)"

        Test-BRAVOCondition -Condition (
            (@($hr2CpSession.State.RemoveFilesCalls) -contains $hr2CpCanonicalPath) -and
            $hr2CpSession.State.MoveFileCalls.Count -eq 2
        ) -Name 'BazaSync/CheckpointDoesNotDependOnServerRenameOverwrite' -Failure "заміна має йти явним шляхом (RemoveFiles наявної цілі перед MoveFile), НЕ покладаючись на rename-overwrite сервера (fake навмисно кидає виняток при move у наявну ціль); RemoveFilesCalls=$($hr2CpSession.State.RemoveFilesCalls -join ', ')"

        $hr2CpFailSession = New-BRAVOSelfTestFakeBazaSession -MoveFileShouldFail
        $hr2CpFailOutcome = Write-BRAVOBazaRemoteCheckpoint -Session $hr2CpFailSession -RemoteRootPath '/baza_app' -SyncResult $hr2CpResult
        $hr2CpFailHealthResult = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId 'hr2-cp-fail' -StartedUtc (Get-Date) -CutoffUtc (Get-Date)
        $hr2CpFailHealthResult.Status = 'COMPLETE'
        $hr2CpFailHealthResult.CheckpointAttempted = $hr2CpFailOutcome.Attempted
        $hr2CpFailHealthResult.CheckpointPublished = $hr2CpFailOutcome.Published
        $hr2CpFailHealthResult.CheckpointError = $hr2CpFailOutcome.Error
        $hr2CpFailHealth = Get-BRAVOBazaFastHealthResult -SyncResult $hr2CpFailHealthResult
        Test-BRAVOCondition -Condition (
            $hr2CpFailOutcome.Published -eq $false -and
            $hr2CpFailHealth.Healthy -eq $true -and $hr2CpFailHealth.Level -eq 'WARNING'
        ) -Name 'BazaSync/CheckpointFailureStillOnlyWarning' -Failure "збій заміни checkpoint при успішному циклі лишається WARNING (телеметрія, не correctness-джерело); Published=$($hr2CpFailOutcome.Published) Healthy=$($hr2CpFailHealth.Healthy) Level=$($hr2CpFailHealth.Level)"

        # =======================================================================
        # HARDENING ROUND 2, P2: mutation-контракт = size АБО LastWriteTimeUtc
        # (для вже Verified шляху); відсутній у state шлях -- NEW незалежно
        # від timestamp
        # =======================================================================
        $hr2MtimeRoot = Join-Path $bazaSyncTestRoot "HR2_Mtime"
        $hr2MtimeLocal = Join-Path $hr2MtimeRoot "local"
        $hr2MtimeState = Join-Path $hr2MtimeRoot "state"
        New-Item -ItemType Directory -Path $hr2MtimeLocal -Force | Out-Null
        $hr2MtimeFile = New-BRAVOSelfTestBazaFile -Directory $hr2MtimeLocal -RelativePath "steady.txt" -SizeBytes 100
        $hr2MtimeSetup = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr2MtimeLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr2MtimeState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider

        # незмінені size+mtime -> trusted skip (нуль remote-викликів)
        $hr2MtimeSkipSession = New-BRAVOSelfTestFakeBazaSession
        $hr2MtimeSkipResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr2MtimeLocal -RemoteRootPath '/baza_app' -Session $hr2MtimeSkipSession -StateRoot $hr2MtimeState
        Test-BRAVOCondition -Condition (
            $hr2MtimeSetup.Status -eq 'COMPLETE' -and
            $hr2MtimeSkipResult.Status -eq 'COMPLETE' -and $hr2MtimeSkipResult.AlreadyVerified -eq 1 -and
            $hr2MtimeSkipSession.State.PutFilesCallCount -eq 0
        ) -Name 'BazaSync/VerifiedSameSizeSameMtimeIsTrustedSkip' -Failure "Verified + незмінені size і mtime = trusted skip без remote-викликів; Status=$($hr2MtimeSkipResult.Status) AlreadyVerified=$($hr2MtimeSkipResult.AlreadyVerified) PutFiles=$($hr2MtimeSkipSession.State.PutFilesCallCount)"

        # той самий розмір, НОВИЙ mtime -> mutation (перезапис тим самим обсягом)
        [IO.File]::SetLastWriteTimeUtc($hr2MtimeFile, (Get-Date).ToUniversalTime().AddMinutes(5))
        $hr2MtimeMutSession = New-BRAVOSelfTestFakeBazaSession
        $hr2MtimeMutResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr2MtimeLocal -RemoteRootPath '/baza_app' -Session $hr2MtimeMutSession -StateRoot $hr2MtimeState
        Test-BRAVOCondition -Condition (
            $hr2MtimeMutResult.Status -eq 'MUTATION_VIOLATION' -and
            $hr2MtimeMutResult.MutationViolations.Count -eq 1 -and
            $hr2MtimeMutResult.MutationViolations[0].RelativePath -eq 'steady.txt' -and
            [int64]$hr2MtimeMutResult.MutationViolations[0].PreviousSize -eq [int64]$hr2MtimeMutResult.MutationViolations[0].CurrentSize -and
            $hr2MtimeMutResult.MutationViolations[0].PreviousLastWriteTimeUtc -cne $hr2MtimeMutResult.MutationViolations[0].CurrentLastWriteTimeUtc -and
            $hr2MtimeMutSession.State.PutFilesCallCount -eq 0
        ) -Name 'BazaSync/VerifiedSameSizeChangedMtimeIsMutation' -Failure "Verified шлях зі зміненим ЛИШЕ mtime (той самий size) має бути MutationViolation, не мовчазний trusted skip; Status=$($hr2MtimeMutResult.Status) Violations=$($hr2MtimeMutResult.MutationViolations.Count) PutFiles=$($hr2MtimeMutSession.State.PutFilesCallCount)"

        # NEW-файл зі старим timestamp -- НЕ timestamp-only discovery:
        # відсутність у state вирішує, upload відбувається
        $hr2OldTsRoot = Join-Path $bazaSyncTestRoot "HR2_OldTs"
        $hr2OldTsLocal = Join-Path $hr2OldTsRoot "local"
        $hr2OldTsState = Join-Path $hr2OldTsRoot "state"
        New-Item -ItemType Directory -Path $hr2OldTsLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr2OldTsLocal -RelativePath "seed.txt" -SizeBytes 10 | Out-Null
        [void](Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr2OldTsLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr2OldTsState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider)
        New-BRAVOSelfTestBazaFile -Directory $hr2OldTsLocal -RelativePath "ancient_new.txt" -SizeBytes 20 -LastWriteTimeUtc ([datetime]::Parse('2001-06-15T12:00:00Z').ToUniversalTime()) | Out-Null
        $hr2OldTsSession = New-BRAVOSelfTestFakeBazaSession
        $hr2OldTsResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr2OldTsLocal -RemoteRootPath '/baza_app' -Session $hr2OldTsSession -StateRoot $hr2OldTsState
        Test-BRAVOCondition -Condition (
            $hr2OldTsResult.Status -eq 'COMPLETE' -and $hr2OldTsResult.Uploaded -eq 1 -and
            ($hr2OldTsSession.State.PutFilesCalledFor -match 'ancient_new')
        ) -Name 'BazaSync/NewFileWithOldTimestampStillUploads' -Failure "новий (відсутній у state) файл зі старим LastWriteTime має передаватись -- рішення ухвалюється за присутністю в state, не за timestamp; Status=$($hr2OldTsResult.Status) Uploaded=$($hr2OldTsResult.Uploaded)"

        # =======================================================================
        # HARDENING ROUND 3, P1: ЖОДНОГО мовчазного перезапису вже наявного
        # remote-файлу (WinSCP OverwriteMode типово Overwrite -- потрібна
        # цільова pre-upload перевірка КОЖНОГО кандидата)
        # =======================================================================
        # remote-файл уже існує з ТИМ САМИМ розміром -> recovered, нуль PutFiles
        $hr3RecRoot = Join-Path $bazaSyncTestRoot "HR3_Recover"
        $hr3RecLocal = Join-Path $hr3RecRoot "local"
        New-Item -ItemType Directory -Path $hr3RecLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr3RecLocal -RelativePath "a.txt" -SizeBytes 100 | Out-Null
        $hr3RecSession = New-BRAVOSelfTestFakeBazaSession
        $hr3RecSession.State.RemoteSizes['/baza_app/a.txt'] = [int64]100
        $hr3RecResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr3RecLocal -RemoteRootPath '/baza_app' -Session $hr3RecSession -StateRoot (Join-Path $hr3RecRoot "state") -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        $hr3RecStateRead = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot (Join-Path $hr3RecRoot "state") -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $hr3RecResult.Status -eq 'COMPLETE' -and
            $hr3RecResult.RecoveredRemote -eq 1 -and $hr3RecResult.Uploaded -eq 0 -and
            $hr3RecStateRead.State.Files.ContainsKey('a.txt') -and
            [bool]$hr3RecStateRead.State.Files['a.txt'].Verified -eq $true
        ) -Name 'BazaSync/ExistingRemoteSameSizeMarksVerifiedWithoutUpload' -Failure "кандидат із уже наявним remote-файлом того самого розміру має стати Verified=true БЕЗ передачі; Status=$($hr3RecResult.Status) Recovered=$($hr3RecResult.RecoveredRemote) Uploaded=$($hr3RecResult.Uploaded)"
        Test-BRAVOCondition -Condition ($hr3RecSession.State.PutFilesCallCount -eq 0) `
            -Name 'BazaSync/ExistingRemoteSameSizeMakesZeroPutFilesCalls' -Failure "нуль PutFiles для recovered кандидата; отримано $($hr3RecSession.State.PutFilesCallCount)"
        } catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'BazaSync/NoDeleteAnywhereInIncrementalEngine' } }
        if (Enter-BRAVOSelfTestSection -Name 'BazaSync/ExistingRemoteMismatchReturnsRemoteConflict' -DependsOn 'BazaSync/PerformancePlanScalesWithNewFilesNotTotalFiles', 'BazaSync/UnknownStatusFailsVisible') { try {

        # remote-файл існує з ІНШИМ розміром -> REMOTE_CONFLICT, без перезапису
        $hr3ConfRoot = Join-Path $bazaSyncTestRoot "HR3_Conflict"
        $hr3ConfLocal = Join-Path $hr3ConfRoot "local"
        $hr3ConfState = Join-Path $hr3ConfRoot "state"
        New-Item -ItemType Directory -Path $hr3ConfLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr3ConfLocal -RelativePath "c_base.txt" -SizeBytes 50 | Out-Null
        $hr3ConfCycle1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr3ConfLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr3ConfState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        $hr3ConfStateBefore = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $hr3ConfState -Component 'BAZA_APP')
        $hr3ConfProvenanceUtc = [string]$hr3ConfStateBefore.State.LastSuccessfulSyncUtc
        $hr3ConfProvenanceCycleId = [string]$hr3ConfStateBefore.State.LastCycleId

        New-BRAVOSelfTestBazaFile -Directory $hr3ConfLocal -RelativePath "b.txt" -SizeBytes 100 | Out-Null
        $hr3ConfSession = New-BRAVOSelfTestFakeBazaSession
        $hr3ConfSession.State.RemoteSizes['/baza_app/b.txt'] = [int64]55
        $hr3ConfResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr3ConfLocal -RemoteRootPath '/baza_app' -Session $hr3ConfSession -StateRoot $hr3ConfState
        Test-BRAVOCondition -Condition (
            $hr3ConfCycle1.Status -eq 'COMPLETE' -and
            $hr3ConfResult.Status -eq 'REMOTE_CONFLICT' -and
            (@($hr3ConfResult.RemoteConflicts).Count -eq 1) -and
            $hr3ConfResult.RemoteConflicts[0].RelativePath -eq 'b.txt' -and
            [int64]$hr3ConfResult.RemoteConflicts[0].LocalSize -eq 100 -and
            [int64]$hr3ConfResult.RemoteConflicts[0].RemoteSize -eq 55
        ) -Name 'BazaSync/ExistingRemoteMismatchReturnsRemoteConflict' -Failure "кандидат із наявним remote-файлом ІНШОГО розміру має дати REMOTE_CONFLICT з RelativePath/LocalSize/RemoteSize; Status=$($hr3ConfResult.Status) Conflicts=$(@($hr3ConfResult.RemoteConflicts).Count)"
        Test-BRAVOCondition -Condition ($hr3ConfSession.State.PutFilesCallCount -eq 0) `
            -Name 'BazaSync/ExistingRemoteMismatchMakesZeroPutFilesCalls' -Failure "нуль PutFiles для конфліктного кандидата (перезапис заборонено); отримано $($hr3ConfSession.State.PutFilesCallCount)"

        $hr3ConfStateAfter = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $hr3ConfState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            -not [string]::IsNullOrWhiteSpace($hr3ConfProvenanceUtc) -and
            [string]$hr3ConfStateAfter.State.LastSuccessfulSyncUtc -ceq $hr3ConfProvenanceUtc
        ) -Name 'BazaSync/RemoteConflictDoesNotAdvanceLastSuccessfulSyncUtc' -Failure "REMOTE_CONFLICT цикл НЕ має просувати LastSuccessfulSyncUtc; було=$hr3ConfProvenanceUtc стало=$($hr3ConfStateAfter.State.LastSuccessfulSyncUtc)"
        Test-BRAVOCondition -Condition ([string]$hr3ConfStateAfter.State.LastCycleId -ceq $hr3ConfProvenanceCycleId) `
            -Name 'BazaSync/RemoteConflictDoesNotAdvanceLastCycleId' -Failure "REMOTE_CONFLICT цикл НЕ має просувати LastCycleId; було=$hr3ConfProvenanceCycleId стало=$($hr3ConfStateAfter.State.LastCycleId)"

        $hr3ConfCheckpointSession = New-BRAVOSelfTestFakeBazaSession
        $hr3ConfCheckpointOutcome = Write-BRAVOBazaRemoteCheckpoint -Session $hr3ConfCheckpointSession -RemoteRootPath '/baza_app' -SyncResult $hr3ConfResult
        Test-BRAVOCondition -Condition (
            $hr3ConfCheckpointOutcome.Attempted -eq $false -and $hr3ConfCheckpointOutcome.Published -eq $false -and
            $hr3ConfCheckpointSession.State.PutFilesCallCount -eq 0 -and
            $hr3ConfCheckpointSession.State.MoveFileCalls.Count -eq 0
        ) -Name 'BazaSync/RemoteConflictDoesNotPublishCheckpoint' -Failure "REMOTE_CONFLICT цикл не має публікувати successful checkpoint; Attempted=$($hr3ConfCheckpointOutcome.Attempted) PutFiles=$($hr3ConfCheckpointSession.State.PutFilesCallCount)"

        $hr3ConfHealth = Get-BRAVOBazaFastHealthResult -SyncResult $hr3ConfResult
        Test-BRAVOCondition -Condition (
            $hr3ConfHealth.Healthy -eq $false -and $hr3ConfHealth.Level -eq 'CRITICAL' -and
            $hr3ConfHealth.Message -match 'b\.txt' -and
            $hr3ConfHealth.Message -match '\b100\b' -and $hr3ConfHealth.Message -match '\b55\b'
        ) -Name 'BazaSync/RemoteConflictHealthIsCriticalWithExactPathAndSizes' -Failure "Health для REMOTE_CONFLICT має бути CRITICAL з точним шляхом і обома розмірами; Healthy=$($hr3ConfHealth.Healthy) Level=$($hr3ConfHealth.Level) Message=$($hr3ConfHealth.Message)"

        # НАЙВАЖЛИВІШЕ: crash-вікно "PutFiles встиг, Save-State ні" НЕ
        # призводить до повторної передачі (і тим паче до перезапису).
        # Round 6: crash-цикл — ЗВИЧАЙНИЙ (без Full Audit), бо bootstrap-
        # цикл із непрацюючим збереженням тепер коректно відмовляє ще на
        # write-ahead маркері (P1-2) і до передач не доходить. Збій
        # фінального збереження моделюється ReadOnly-атрибутом на файлі
        # стану ([IO.File]::Replace вимагає write-доступу до цілі).
        $hr3CrashRoot = Join-Path $bazaSyncTestRoot "HR3_Crash"
        $hr3CrashLocal = Join-Path $hr3CrashRoot "local"
        $hr3CrashState = Join-Path $hr3CrashRoot "state"
        New-Item -ItemType Directory -Path $hr3CrashLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr3CrashLocal -RelativePath "seed.txt" -SizeBytes 15 | Out-Null
        [void](Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr3CrashLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr3CrashState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider)
        $hr3CrashStatePath = Get-BRAVOBazaStatePath -StateRoot $hr3CrashState -Component 'BAZA_APP'
        New-BRAVOSelfTestBazaFile -Directory $hr3CrashLocal -RelativePath "d.txt" -SizeBytes 40 | Out-Null
        [IO.File]::SetAttributes($hr3CrashStatePath, [IO.FileAttributes]::ReadOnly)
        $hr3CrashSession = New-BRAVOSelfTestFakeBazaSession
        $hr3CrashCycleN = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr3CrashLocal -RemoteRootPath '/baza_app' -Session $hr3CrashSession -StateRoot $hr3CrashState
        $hr3CrashPutFilesAfterCycleN = $hr3CrashSession.State.PutFilesCallCount
        [IO.File]::SetAttributes($hr3CrashStatePath, [IO.FileAttributes]::Normal)
        # ТА САМА сесія = той самий "remote": d.txt уже там після циклу N,
        # а стан на диску його не пам'ятає (старий, до збою)
        $hr3CrashCycleN1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr3CrashLocal -RemoteRootPath '/baza_app' -Session $hr3CrashSession -StateRoot $hr3CrashState
        $hr3CrashStateRead = Read-BRAVOBazaState -Path $hr3CrashStatePath
        Test-BRAVOCondition -Condition (
            $hr3CrashCycleN.Status -eq 'INCOMPLETE' -and $hr3CrashCycleN.Error -match 'зберегти стан' -and
            $hr3CrashPutFilesAfterCycleN -eq 1 -and
            $hr3CrashCycleN1.Status -eq 'COMPLETE' -and $hr3CrashCycleN1.RecoveredRemote -eq 1 -and
            $hr3CrashSession.State.PutFilesCallCount -eq 1 -and
            $hr3CrashStateRead.State.Files.ContainsKey('d.txt') -and
            [bool]$hr3CrashStateRead.State.Files['d.txt'].Verified -eq $true
        ) -Name 'BazaSync/CrashAfterRemoteUploadBeforeStateCommitDoesNotReupload' -Failure "цикл N (звичайний, без audit): upload OK + збій save (INCOMPLETE); цикл N+1: той самий remote-файл, розмір збігся, блокера немає -> 0 нових PutFiles, Verified=true, COMPLETE; CycleN=$($hr3CrashCycleN.Status) CycleN1=$($hr3CrashCycleN1.Status) PutFilesTotal=$($hr3CrashSession.State.PutFilesCallCount) Recovered=$($hr3CrashCycleN1.RecoveredRemote)"

        # remote-перевірка існування -- ЛИШЕ для кандидатів, не для Verified
        $hr3ScopeRoot = Join-Path $bazaSyncTestRoot "HR3_Scope"
        $hr3ScopeLocal = Join-Path $hr3ScopeRoot "local"
        $hr3ScopeState = Join-Path $hr3ScopeRoot "state"
        New-Item -ItemType Directory -Path $hr3ScopeLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr3ScopeLocal -RelativePath "seed1.txt" -SizeBytes 10 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr3ScopeLocal -RelativePath "seed2.txt" -SizeBytes 10 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr3ScopeLocal -RelativePath "seed3.txt" -SizeBytes 10 | Out-Null
        [void](Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr3ScopeLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr3ScopeState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider)
        New-BRAVOSelfTestBazaFile -Directory $hr3ScopeLocal -RelativePath "new1.txt" -SizeBytes 10 | Out-Null
        $hr3ScopeSession = New-BRAVOSelfTestFakeBazaSession
        $hr3ScopeResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr3ScopeLocal -RemoteRootPath '/baza_app' -Session $hr3ScopeSession -StateRoot $hr3ScopeState
        $hr3ScopeVerifiedTouches = @(
            (@($hr3ScopeSession.State.FileExistsCalledFor) + @($hr3ScopeSession.State.GetFileInfoCalledFor)) |
                Where-Object { $_ -match 'seed[123]\.txt' }
        )
        Test-BRAVOCondition -Condition (
            $hr3ScopeResult.Status -eq 'COMPLETE' -and $hr3ScopeResult.Uploaded -eq 1 -and
            $hr3ScopeResult.AlreadyVerified -eq 3 -and
            $hr3ScopeVerifiedTouches.Count -eq 0 -and
            (@($hr3ScopeSession.State.FileExistsCalledFor) -match 'new1\.txt').Count -ge 1
        ) -Name 'BazaSync/RemoteExistingChecksOnlyCandidates' -Failure "перевірка існування remote-файлу має виконуватись ЛИШЕ для кандидатів (TrustedSkip -- нуль remote-звернень); verified-звернень: $($hr3ScopeVerifiedTouches.Count)"

        # 100000 Verified + 10 кандидатів: жодного stat/FileExists для
        # старих Verified-записів (план -- чиста функція над 100010; фаза
        # передачі виконується РЕАЛЬНО для 10 кандидатів)
        $hr3PerfLocal = Join-Path $bazaSyncTestRoot "HR3_Perf"
        New-Item -ItemType Directory -Path $hr3PerfLocal -Force | Out-Null
        $hr3PerfSession = New-BRAVOSelfTestFakeBazaSession
        foreach ($hr3PerfCandidate in $perfPlan.ToUpload) {
            $hr3PerfRealPath = New-BRAVOSelfTestBazaFile -Directory $hr3PerfLocal -RelativePath $hr3PerfCandidate.RelativePath -SizeBytes 500
            $hr3PerfEntry = [pscustomobject]@{
                RelativePath = $hr3PerfCandidate.RelativePath
                Size = [int64]500
                LastWriteTimeUtc = $hr3PerfCandidate.LastWriteTimeUtc
                FullPath = $hr3PerfRealPath
            }
            [void](Invoke-BRAVOBazaFileUpload -Session $hr3PerfSession -Entry $hr3PerfEntry -LocalDirectory $hr3PerfLocal -RemoteRootPath '/baza_app')
        }
        $hr3PerfVerifiedTouches = @(
            (@($hr3PerfSession.State.FileExistsCalledFor) + @($hr3PerfSession.State.GetFileInfoCalledFor)) |
                Where-Object { $_ -match 'verified_' }
        )
        Test-BRAVOCondition -Condition (
            $perfPlan.ToUpload.Count -eq 10 -and
            $hr3PerfSession.State.PutFilesCallCount -eq 10 -and
            $hr3PerfVerifiedTouches.Count -eq 0 -and
            @($hr3PerfSession.State.GetFileInfoCalledFor).Count -eq 10
        ) -Name 'BazaSync/100000VerifiedPlus10CandidatesDoesNotStatOldVerifiedEntries' -Failure "на 100000 Verified + 10 нових: усі remote-виклики мають стосуватись ЛИШЕ 10 кандидатів (жодного stat для verified_*); PutFiles=$($hr3PerfSession.State.PutFilesCallCount) verifiedTouches=$($hr3PerfVerifiedTouches.Count) GetFileInfo=$(@($hr3PerfSession.State.GetFileInfoCalledFor).Count)"

        # =======================================================================
        # #366: WinSCP читає локальне джерело PutFiles і джерело MoveFile як
        # маску. BAZA-імена з `[`/`]` (Windows їх дозволяє) мають передаватись
        # екранованими: інакше `doc[1].txt` збігається з `doc1.txt`.
        # =======================================================================
        $maskLocal = Join-Path $bazaSyncTestRoot "Mask366"
        New-Item -ItemType Directory -Path $maskLocal -Force | Out-Null
        $maskRealPath = New-BRAVOSelfTestBazaFile -Directory $maskLocal -RelativePath 'doc[1].txt' -SizeBytes 500
        [void](New-BRAVOSelfTestBazaFile -Directory $maskLocal -RelativePath 'doc1.txt' -SizeBytes 120)
        $maskSession = New-BRAVOSelfTestWinSCPMaskSession
        [void]$maskSession.State.KnownRemoteDirs.Add('/baza_app')
        $maskEntry = [pscustomobject]@{
            RelativePath = 'doc[1].txt'
            Size = [int64]500
            LastWriteTimeUtc = (Get-Item -LiteralPath $maskRealPath).LastWriteTimeUtc
            FullPath = $maskRealPath
        }
        $maskUpload = Invoke-BRAVOBazaFileUpload -Session $maskSession -Entry $maskEntry -LocalDirectory $maskLocal -RemoteRootPath '/baza_app'
        Test-BRAVOCondition -Condition (
            $maskUpload.Success -eq $true -and $maskUpload.Outcome -eq 'Uploaded' -and
            [int64]$maskSession.State.RemoteSizes['/baza_app/doc[1].txt'] -eq 500 -and
            (@($maskSession.State.PutFilesLocalArgs) -contains (Join-Path $maskLocal 'doc[[]1].txt'))
        ) -Name 'BazaSync/UploadEscapesWinSCPLocalFileMask' -Failure "upload doc[1].txt має передавати у PutFiles екрановане джерело і залити саме цей файл (500 B); Outcome=$($maskUpload.Outcome) Error=$($maskUpload.Error) remote=$($maskSession.State.RemoteSizes['/baza_app/doc[1].txt']) put=$(@($maskSession.State.PutFilesLocalArgs) -join ',')"

        $maskRenameSession = New-BRAVOSelfTestWinSCPMaskSession
        $maskRenameSession.State.RemoteSizes['/baza_app/doc[1].txt'] = [int64]500
        $maskRenameSession.State.RemoteSizes['/baza_app/doc1.txt'] = [int64]120
        $maskRenameState = [pscustomobject]@{ Files = @{ 'doc[1].txt' = [pscustomobject]@{ Size = [int64]500 } } }
        try {
            $maskRenameResult = & (@(Get-Module -Name BRAVO.BazaSync)[0]) {
                param($state, $session)
                Invoke-BRAVOBazaMutationAcceptanceCore -State $state -RemoteRootPath '/baza_app' -Session $session `
                    -MutationPathLookup @{ 'doc[1].txt' = $true } -AcceptRelativePaths @('doc[1].txt')
            } $maskRenameState $maskRenameSession
        } catch {
            $maskRenameResult = [pscustomobject]@{ Accepted = @(); Failures = @([pscustomobject]@{ Error = "виняток: $($_.Exception.Message)" }) }
        }
        $maskRenamedKeys = @($maskRenameSession.State.RemoteSizes.Keys | Where-Object { ([string]$_).StartsWith('/baza_app/doc[1].txt.replaced_', [StringComparison]::Ordinal) })
        Test-BRAVOCondition -Condition (
            (@($maskRenameResult.Accepted) -contains 'doc[1].txt') -and
            @($maskRenameResult.Failures).Count -eq 0 -and
            $maskRenamedKeys.Count -eq 1 -and
            [int64]$maskRenameSession.State.RemoteSizes[$maskRenamedKeys[0]] -eq 500 -and
            -not $maskRenameSession.State.RemoteSizes.ContainsKey('/baza_app/doc[1].txt') -and
            [int64]$maskRenameSession.State.RemoteSizes['/baza_app/doc1.txt'] -eq 120
        ) -Name 'BazaSync/MutationRenameEscapesWinSCPFileMask' -Failure "rename прийнятої мутації doc[1].txt має перейменувати саме її (джерело MoveFile екрановане), doc1.txt недоторканий; Failures=$(@($maskRenameResult.Failures | ForEach-Object { $_.Error }) -join '; ') renamed=$($maskRenamedKeys -join ',') decoy=$($maskRenameSession.State.RemoteSizes['/baza_app/doc1.txt'])"

        # Checkpoint-и мають фіксовані імена без символів маски: те саме
        # правило екранування лишає їх незмінними, тож виклики checkpoint
        # RemoveFiles/MoveFile/PutFiles коректні без екранування.
        $maskCheckpointNames = @(
            (Get-BRAVOBazaRemoteCheckpointName),
            ('.bravo-sync.json.tmp-' + [guid]::NewGuid().ToString('N')),
            ('bravo-sync-{0}.json' -f [guid]::NewGuid().ToString('N'))
        )
        $maskCheckpointUnsafe = @($maskCheckpointNames | Where-Object {
            $maskCheckpointName = $_
            try { (ConvertTo-BRAVOWinSCPFileMask -Path $maskCheckpointName) -cne $maskCheckpointName } catch { $true }
        })
        Test-BRAVOCondition -Condition ($maskCheckpointUnsafe.Count -eq 0) `
            -Name 'BazaSync/CheckpointNamesAreWinSCPMaskSafe' -Failure "імена checkpoint-ів мають бути вільні від символів маски WinSCP; змінюються екрануванням: $($maskCheckpointUnsafe -join ',')"

        # =======================================================================
        # HARDENING ROUND 3, P2: результат RemoveFiles при заміні checkpoint;
        # NewAfterCutoff для INCOMPATIBLE_NAME; обидві категорії у Health
        # =======================================================================
        $hr3CpResult = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId 'hr3-cp' -StartedUtc (Get-Date).ToUniversalTime() -CutoffUtc (Get-Date).ToUniversalTime()
        $hr3CpResult.Status = 'COMPLETE'
        $hr3CpResult.CompletedUtc = (Get-Date).ToUniversalTime()
        $hr3CpSession = New-BRAVOSelfTestFakeBazaSession
        $hr3CpFirst = Write-BRAVOBazaRemoteCheckpoint -Session $hr3CpSession -RemoteRootPath '/baza_app' -SyncResult $hr3CpResult
        $hr3CpSession.State.RemoveFilesShouldFail = $true
        $hr3CpSecond = Write-BRAVOBazaRemoteCheckpoint -Session $hr3CpSession -RemoteRootPath '/baza_app' -SyncResult $hr3CpResult
        $hr3CpFailHealthResult = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId 'hr3-cp2' -StartedUtc (Get-Date) -CutoffUtc (Get-Date)
        $hr3CpFailHealthResult.Status = 'COMPLETE'
        $hr3CpFailHealthResult.CheckpointAttempted = $hr3CpSecond.Attempted
        $hr3CpFailHealthResult.CheckpointPublished = $hr3CpSecond.Published
        $hr3CpFailHealthResult.CheckpointError = $hr3CpSecond.Error
        $hr3CpFailHealth = Get-BRAVOBazaFastHealthResult -SyncResult $hr3CpFailHealthResult
        Test-BRAVOCondition -Condition (
            $hr3CpFirst.Published -eq $true -and
            $hr3CpSecond.Published -eq $false -and
            $hr3CpSecond.Error -match 'прибрати попередній' -and
            $hr3CpSession.State.RemoteSizes.ContainsKey('/baza_app/.bravo-sync.json') -and
            $hr3CpFailHealth.Healthy -eq $true -and $hr3CpFailHealth.Level -eq 'WARNING'
        ) -Name 'BazaSync/CheckpointRemovalFailureReportsPublishedFalse' -Failure "збій RemoveFiles попереднього checkpoint (IsSuccess=false, без винятку) має дати Published=false + WARNING, старий checkpoint лишається; First=$($hr3CpFirst.Published) Second=$($hr3CpSecond.Published) Error=$($hr3CpSecond.Error) Healthy=$($hr3CpFailHealth.Healthy) Level=$($hr3CpFailHealth.Level)"

        # NewAfterCutoff діагностика доступна і для INCOMPATIBLE_NAME циклів.
        # P2 (round 4): membership рахується за ЗНІМКОМ ЦИКЛУ, не за
        # persisted state -- pre-cutoff несумісний файл (свідомо не
        # записаний у state) НЕ є "новим після cutoff".
        $hr3NacRoot = Join-Path $bazaSyncTestRoot "HR3_Nac"
        $hr3NacLocal = Join-Path $hr3NacRoot "local"
        $hr3NacState = Join-Path $hr3NacRoot "state"
        New-Item -ItemType Directory -Path $hr3NacLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr3NacLocal -RelativePath "f_ok.txt" -SizeBytes 10 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr3NacLocal -RelativePath "$drUtf8Name.txt" -SizeBytes 10 | Out-Null
        $hr3NacResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr3NacLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr3NacState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        $hr3NacBeforeExtra = Update-BRAVOBazaSyncResultNewAfterCutoff -SyncResult $hr3NacResult -LocalDirectory $hr3NacLocal -StateRoot $hr3NacState
        Test-BRAVOCondition -Condition (
            $hr3NacResult.Status -eq 'INCOMPATIBLE_NAME' -and
            $hr3NacBeforeExtra.NewAfterCutoff -eq 0
        ) -Name 'BazaSync/IncompatibleBeforeCutoffNotCountedAsNewAfterCutoff' -Failure "pre-cutoff несумісний файл був у знімку циклу -- він НЕ 'новий після cutoff', хоч і відсутній у state; Status=$($hr3NacResult.Status) NewAfterCutoff=$($hr3NacBeforeExtra.NewAfterCutoff)"
        New-BRAVOSelfTestBazaFile -Directory $hr3NacLocal -RelativePath "extra_after.txt" -SizeBytes 10 | Out-Null
        $hr3NacUpdated = Update-BRAVOBazaSyncResultNewAfterCutoff -SyncResult $hr3NacResult -LocalDirectory $hr3NacLocal -StateRoot $hr3NacState
        Test-BRAVOCondition -Condition ($hr3NacUpdated.NewAfterCutoff -eq 1) `
            -Name 'BazaSync/NewAfterCutoffCountsForIncompatibleNameCycles' -Failure "INCOMPATIBLE_NAME цикл отримує NewAfterCutoff-діагностику: лише РЕАЛЬНО доданий після знімка файл (1), БЕЗ pre-cutoff несумісного; NewAfterCutoff=$($hr3NacUpdated.NewAfterCutoff)"

        # мутації та несумісні імена в одному циклі: обидві категорії видимі
        $hr3DualResult = New-BRAVOBazaSyncResult -Component 'BAZA_APP' -CycleId 'hr3-dual' -StartedUtc (Get-Date) -CutoffUtc (Get-Date)
        $hr3DualResult.Status = 'MUTATION_VIOLATION'
        $hr3DualResult.MutationViolations = @([pscustomobject]@{ RelativePath = 'mutated.txt'; PreviousSize = 10; CurrentSize = 10; PreviousLastWriteTimeUtc = '2026-01-01T00:00:00.0000000Z'; CurrentLastWriteTimeUtc = '2026-02-01T00:00:00.0000000Z' })
        $hr3DualResult.IncompatibleFiles = @([pscustomobject]@{ RelativePath = 'badname.txt'; Reason = 'задовге' })
        $hr3DualHealth = Get-BRAVOBazaFastHealthResult -SyncResult $hr3DualResult
        Test-BRAVOCondition -Condition (
            $hr3DualHealth.Healthy -eq $false -and
            $hr3DualHealth.Message -match 'mutated\.txt' -and
            (($hr3DualHealth.Info -join ' ') -match 'badname\.txt')
        ) -Name 'BazaSync/MutationAndIncompatibleBothSurfacedInHealth' -Failure "при співіснуванні мутацій і несумісних імен ОБИДВІ категорії мають бути видимі (одна в Message, друга в Info); Message=$($hr3DualHealth.Message) Info=$($hr3DualHealth.Info -join '; ')"

        # =======================================================================
        # HARDENING ROUND 4, P1: вердикт ПОТОЧНОГО Full Audit переважає
        # generic AlreadyRemote same-size recovery (audit порівнює за
        # time,size -- збіг ЛИШЕ розміру не сміє скасувати його вердикт)
        # =======================================================================
        # bootstrap: audit явно позначив drifted.txt як UploadUpdate (той
        # самий розмір, інший mtime на remote) -- recovery заборонено
        $hr4BootRoot = Join-Path $bazaSyncTestRoot "HR4_Boot"
        $hr4BootLocal = Join-Path $hr4BootRoot "local"
        $hr4BootState = Join-Path $hr4BootRoot "state"
        New-Item -ItemType Directory -Path $hr4BootLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr4BootLocal -RelativePath "drifted.txt" -SizeBytes 100 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr4BootLocal -RelativePath "other.txt" -SizeBytes 60 | Out-Null
        $hr4BootProvider = & { param($hr4BootLocal) {
            param($Snapshot)
            $pendingFile = [pscustomobject]@{
                IsDirectory = $false
                Path = (Join-Path $hr4BootLocal "drifted.txt")
                Action = 'UploadUpdate'
                Reason = 'розбіжність часу (той самий розмір)'
            }
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @($pendingFile) -LocalDirectory $hr4BootLocal -LocalSnapshot $Snapshot
        }.GetNewClosure() } $hr4BootLocal
        $hr4BootSession = New-BRAVOSelfTestFakeBazaSession
        $hr4BootSession.State.RemoteSizes['/baza_app/drifted.txt'] = [int64]100
        $hr4BootResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr4BootLocal -RemoteRootPath '/baza_app' -Session $hr4BootSession -StateRoot $hr4BootState -BootstrapIfNeeded -FullAuditProvider $hr4BootProvider
        $hr4BootStateRead = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $hr4BootState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $hr4BootResult.Status -eq 'AUDIT_DRIFT' -and
            $hr4BootResult.RecoveredRemote -eq 0 -and $hr4BootResult.Uploaded -eq 0 -and
            (@($hr4BootResult.AuditDriftFiles).Count -eq 1) -and
            $hr4BootResult.AuditDriftFiles[0].RelativePath -eq 'drifted.txt' -and
            [int64]$hr4BootResult.AuditDriftFiles[0].RemoteSize -eq 100 -and
            $hr4BootStateRead.State.Files.ContainsKey('other.txt') -and
            [bool]$hr4BootStateRead.State.Files['other.txt'].Verified -eq $true -and
            $hr4BootStateRead.State.Files.ContainsKey('drifted.txt') -and
            [bool]$hr4BootStateRead.State.Files['drifted.txt'].Verified -eq $false -and
            [string]$hr4BootStateRead.State.Files['drifted.txt'].BlockReason -eq 'AuditDrift'
        ) -Name 'BazaSync/BootstrapAuditPendingSameSizeRemoteIsNotRecovered' -Failure "bootstrap: audit-pending кандидат із same-size remote НЕ recovery-иться і НЕ сідиться Verified -- натомість персистується AuditDrift-блокер (round 5), non-pending other.txt сідиться нормально; Status=$($hr4BootResult.Status) Recovered=$($hr4BootResult.RecoveredRemote) Drift=$(@($hr4BootResult.AuditDriftFiles).Count)"

        Test-BRAVOCondition -Condition (
            $hr4BootResult.RecoveredRemote -eq 0 -and
            $hr4BootResult.AuditDriftFiles[0].Action -eq 'UploadUpdate'
        ) -Name 'BazaSync/FullAuditUploadUpdateCandidateNeverBecomesAlreadyRemote' -Failure "UploadUpdate-кандидат НІКОЛИ не стає AlreadyRemote (audit Action зберігається у драфт-записі); Recovered=$($hr4BootResult.RecoveredRemote) Action=$($hr4BootResult.AuditDriftFiles[0].Action)"

        Test-BRAVOCondition -Condition ($hr4BootSession.State.PutFilesCallCount -eq 0) `
            -Name 'BazaSync/AuditPendingRemoteExistingMakesZeroPutFilesCalls' -Failure "audit-pending + remote існує -> НУЛЬ PutFiles (жодного перезапису); отримано $($hr4BootSession.State.PutFilesCallCount)"

        Test-BRAVOCondition -Condition ($hr4BootResult.Status -ne 'COMPLETE' -and $hr4BootResult.Status -eq 'AUDIT_DRIFT') `
            -Name 'BazaSync/AuditPendingDoesNotProduceComplete' -Failure "audit-pending drift не сміє давати COMPLETE; Status=$($hr4BootResult.Status)"

        $hr4BootCheckpointSession = New-BRAVOSelfTestFakeBazaSession
        $hr4BootCheckpointOutcome = Write-BRAVOBazaRemoteCheckpoint -Session $hr4BootCheckpointSession -RemoteRootPath '/baza_app' -SyncResult $hr4BootResult
        Test-BRAVOCondition -Condition (
            $hr4BootCheckpointOutcome.Attempted -eq $false -and $hr4BootCheckpointOutcome.Published -eq $false -and
            $hr4BootCheckpointSession.State.PutFilesCallCount -eq 0 -and
            $hr4BootCheckpointSession.State.MoveFileCalls.Count -eq 0
        ) -Name 'BazaSync/AuditPendingDoesNotPublishCheckpoint' -Failure "AUDIT_DRIFT цикл не публікує successful checkpoint; Attempted=$($hr4BootCheckpointOutcome.Attempted)"

        $hr4BootHealth = Get-BRAVOBazaFastHealthResult -SyncResult $hr4BootResult
        Test-BRAVOCondition -Condition (
            $hr4BootHealth.Healthy -eq $false -and $hr4BootHealth.Level -eq 'CRITICAL' -and
            $hr4BootHealth.Message -match 'drifted\.txt' -and $hr4BootHealth.Message -match 'UploadUpdate'
        ) -Name 'BazaSync/AuditDriftHealthIsCriticalWithActionAndSizes' -Failure "Health для AUDIT_DRIFT: CRITICAL з точним шляхом і audit Action; Healthy=$($hr4BootHealth.Healthy) Level=$($hr4BootHealth.Level) Message=$($hr4BootHealth.Message)"

        # періодичний audit: той самий same-size drift на вже Verified файлі
        $hr4PerRoot = Join-Path $bazaSyncTestRoot "HR4_Periodic"
        $hr4PerLocal = Join-Path $hr4PerRoot "local"
        $hr4PerState = Join-Path $hr4PerRoot "state"
        New-Item -ItemType Directory -Path $hr4PerLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr4PerLocal -RelativePath "drifted2.txt" -SizeBytes 80 | Out-Null
        $hr4PerCycle1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr4PerLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr4PerState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        $hr4PerStateBefore = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $hr4PerState -Component 'BAZA_APP')
        $hr4PerProvenanceUtc = [string]$hr4PerStateBefore.State.LastSuccessfulSyncUtc
        $hr4PerAuditUtcBefore = [string]$hr4PerStateBefore.State.LastFullAuditUtc
        $hr4PerProvider = & { param($hr4PerLocal) {
            param($Snapshot)
            $pendingFile = [pscustomobject]@{
                IsDirectory = $false
                Path = (Join-Path $hr4PerLocal "drifted2.txt")
                Action = 'UploadUpdate'
                Reason = 'remote mtime відрізняється'
            }
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @($pendingFile) -LocalDirectory $hr4PerLocal -LocalSnapshot $Snapshot
        }.GetNewClosure() } $hr4PerLocal
        $hr4PerSession2 = New-BRAVOSelfTestFakeBazaSession
        $hr4PerSession2.State.RemoteSizes['/baza_app/drifted2.txt'] = [int64]80
        $hr4PerResult2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr4PerLocal -RemoteRootPath '/baza_app' -Session $hr4PerSession2 -StateRoot $hr4PerState -BootstrapIfNeeded -ForceFullAudit -FullAuditProvider $hr4PerProvider
        $hr4PerStateAfter = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $hr4PerState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $hr4PerCycle1.Status -eq 'COMPLETE' -and
            $hr4PerResult2.Status -eq 'AUDIT_DRIFT' -and
            $hr4PerSession2.State.PutFilesCallCount -eq 0 -and
            $hr4PerStateAfter.State.Files.ContainsKey('drifted2.txt') -and
            [bool]$hr4PerStateAfter.State.Files['drifted2.txt'].Verified -eq $false
        ) -Name 'BazaSync/PeriodicFullAuditSameSizeDriftIsNotRecovered' -Failure "періодичний audit-pending drift (same size) НЕ recovery-иться: AUDIT_DRIFT, 0 PutFiles, Verified лишається false; Status=$($hr4PerResult2.Status) PutFiles=$($hr4PerSession2.State.PutFilesCallCount)"
        } catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'BazaSync/ExistingRemoteMismatchReturnsRemoteConflict' } }
        if (Enter-BRAVOSelfTestSection -Name 'BazaSync/AuditPendingDoesNotAdvanceLastSuccessfulSyncUtc' -DependsOn 'BazaSync/ExistingRemoteMismatchReturnsRemoteConflict') { try {

        Test-BRAVOCondition -Condition (
            -not [string]::IsNullOrWhiteSpace($hr4PerProvenanceUtc) -and
            [string]$hr4PerStateAfter.State.LastSuccessfulSyncUtc -ceq $hr4PerProvenanceUtc -and
            [string]$hr4PerStateAfter.State.LastFullAuditUtc -cne $hr4PerAuditUtcBefore
        ) -Name 'BazaSync/AuditPendingDoesNotAdvanceLastSuccessfulSyncUtc' -Failure "AUDIT_DRIFT: LastSuccessfulSyncUtc НЕ просувається, але LastFullAuditUtc МОЖЕ (audit успішно завершився і виявив drift -- свіжість аудиту != успіх синхронізації); Provenance=$($hr4PerStateAfter.State.LastSuccessfulSyncUtc) було=$hr4PerProvenanceUtc AuditUtc=$($hr4PerStateAfter.State.LastFullAuditUtc)"

        # audit підтвердив збіг -> сідиться Verified без жодного upload
        $hr4SeedRoot = Join-Path $bazaSyncTestRoot "HR4_Seed"
        $hr4SeedLocal = Join-Path $hr4SeedRoot "local"
        New-Item -ItemType Directory -Path $hr4SeedLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr4SeedLocal -RelativePath "match.txt" -SizeBytes 70 | Out-Null
        $hr4SeedProvider = & { param($hr4SeedLocal) {
            param($Snapshot)
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @() -LocalDirectory $hr4SeedLocal -LocalSnapshot $Snapshot
        }.GetNewClosure() } $hr4SeedLocal
        $hr4SeedSession = New-BRAVOSelfTestFakeBazaSession
        $hr4SeedResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr4SeedLocal -RemoteRootPath '/baza_app' -Session $hr4SeedSession -StateRoot (Join-Path $hr4SeedRoot "state") -BootstrapIfNeeded -FullAuditProvider $hr4SeedProvider
        $hr4SeedStateRead = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot (Join-Path $hr4SeedRoot "state") -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $hr4SeedResult.Status -eq 'COMPLETE' -and $hr4SeedResult.Uploaded -eq 0 -and
            $hr4SeedSession.State.PutFilesCallCount -eq 0 -and
            [bool]$hr4SeedStateRead.State.Files['match.txt'].Verified -eq $true
        ) -Name 'BazaSync/FullAuditMatchingFileSeedsVerifiedWithZeroUpload' -Failure "файл, який audit підтвердив як matching, сідиться Verified=true з НУЛЕМ upload; Status=$($hr4SeedResult.Status) Uploaded=$($hr4SeedResult.Uploaded) PutFiles=$($hr4SeedSession.State.PutFilesCallCount)"

        # =======================================================================
        # HARDENING ROUND 4, P2: NewAfterCutoff = членство у знімку циклу
        # =======================================================================
        Test-BRAVOCondition -Condition (
            ((Update-BRAVOBazaSyncResultNewAfterCutoff -SyncResult $hr3ConfResult -LocalDirectory $hr3ConfLocal -StateRoot $hr3ConfState).NewAfterCutoff) -eq 0
        ) -Name 'BazaSync/RemoteConflictBeforeCutoffNotCountedAsNewAfterCutoff' -Failure "pre-cutoff конфліктний кандидат був у знімку циклу -- він НЕ 'новий після cutoff', хоч і відсутній у state; NewAfterCutoff=$($hr3ConfResult.NewAfterCutoff)"

        $hr4PendRoot = Join-Path $bazaSyncTestRoot "HR4_Pend"
        $hr4PendLocal = Join-Path $hr4PendRoot "local"
        $hr4PendState = Join-Path $hr4PendRoot "state"
        New-Item -ItemType Directory -Path $hr4PendLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr4PendLocal -RelativePath "bad_p.txt" -SizeBytes 10 | Out-Null
        $hr4PendResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr4PendLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession -FailOnRelativePaths @('bad_p.txt')) -StateRoot $hr4PendState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        $hr4PendUpdated = Update-BRAVOBazaSyncResultNewAfterCutoff -SyncResult $hr4PendResult -LocalDirectory $hr4PendLocal -StateRoot $hr4PendState
        Test-BRAVOCondition -Condition (
            $hr4PendResult.Status -eq 'INCOMPLETE' -and $hr4PendUpdated.NewAfterCutoff -eq 0
        ) -Name 'BazaSync/PendingBeforeCutoffNotCountedAsNewAfterCutoff' -Failure "pre-cutoff failed/pending файл був у знімку циклу -- він НЕ 'новий після cutoff'; Status=$($hr4PendResult.Status) NewAfterCutoff=$($hr4PendUpdated.NewAfterCutoff)"

        $hr4NacRoot = Join-Path $bazaSyncTestRoot "HR4_Nac"
        $hr4NacLocal = Join-Path $hr4NacRoot "local"
        $hr4NacState = Join-Path $hr4NacRoot "state"
        New-Item -ItemType Directory -Path $hr4NacLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr4NacLocal -RelativePath "a.txt" -SizeBytes 10 | Out-Null
        $hr4NacResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr4NacLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr4NacState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        New-BRAVOSelfTestBazaFile -Directory $hr4NacLocal -RelativePath "fresh_new.txt" -SizeBytes 10 | Out-Null
        $hr4NacUpdated = Update-BRAVOBazaSyncResultNewAfterCutoff -SyncResult $hr4NacResult -LocalDirectory $hr4NacLocal -StateRoot $hr4NacState
        Test-BRAVOCondition -Condition ($hr4NacUpdated.NewAfterCutoff -eq 1) `
            -Name 'BazaSync/OneActuallyNewAfterCutoffCountsOne' -Failure "рівно один РЕАЛЬНО доданий після знімка файл -> NewAfterCutoff=1; отримано $($hr4NacUpdated.NewAfterCutoff)"

        $hr4BackRoot = Join-Path $bazaSyncTestRoot "HR4_Back"
        $hr4BackLocal = Join-Path $hr4BackRoot "local"
        $hr4BackState = Join-Path $hr4BackRoot "state"
        New-Item -ItemType Directory -Path $hr4BackLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr4BackLocal -RelativePath "b.txt" -SizeBytes 10 | Out-Null
        $hr4BackResult = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr4BackLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr4BackState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        New-BRAVOSelfTestBazaFile -Directory $hr4BackLocal -RelativePath "backdated_new.txt" -SizeBytes 10 -LastWriteTimeUtc ([datetime]::Parse('2001-03-03T03:03:03Z').ToUniversalTime()) | Out-Null
        $hr4BackUpdated = Update-BRAVOBazaSyncResultNewAfterCutoff -SyncResult $hr4BackResult -LocalDirectory $hr4BackLocal -StateRoot $hr4BackState
        Test-BRAVOCondition -Condition ($hr4BackUpdated.NewAfterCutoff -eq 1) `
            -Name 'BazaSync/BackdatedFileAddedAfterSnapshotStillCountsAsNewAfterCutoff' -Failure "файл, доданий ПІСЛЯ знімка зі старим LastWriteTime, все одно рахується (membership -- знімок, не timestamp); отримано $($hr4BackUpdated.NewAfterCutoff)"

        # =======================================================================
        # HARDENING ROUND 5, P1: AUDIT_DRIFT стійкий МІЖ циклами -- persisted
        # блокер у state-записі шляху; очищення лише позитивною розв'язкою
        # =======================================================================
        # головна модель: цикл 0 (успіх, provenance) -> цикл 1 (audit drift)
        # -> цикли 2..3 БЕЗ аудиту мусять лишатись заблокованими
        $hr5Root = Join-Path $bazaSyncTestRoot "HR5_Sticky"
        $hr5Local = Join-Path $hr5Root "local"
        $hr5State = Join-Path $hr5Root "state"
        New-Item -ItemType Directory -Path $hr5Local -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr5Local -RelativePath "ok.txt" -SizeBytes 30 | Out-Null
        $hr5Cycle0 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr5Local -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr5State -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        $hr5StateAfter0 = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $hr5State -Component 'BAZA_APP')
        $hr5ProvenanceUtc = [string]$hr5StateAfter0.State.LastSuccessfulSyncUtc
        $hr5ProvenanceCycleId = [string]$hr5StateAfter0.State.LastCycleId

        New-BRAVOSelfTestBazaFile -Directory $hr5Local -RelativePath "sticky.txt" -SizeBytes 90 | Out-Null
        $hr5StickyProvider = & { param($hr5Local) {
            param($Snapshot)
            $pendingFile = [pscustomobject]@{
                IsDirectory = $false
                Path = (Join-Path $hr5Local "sticky.txt")
                Action = 'UploadUpdate'
                Reason = 'remote mtime відрізняється (той самий розмір)'
            }
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @($pendingFile) -LocalDirectory $hr5Local -LocalSnapshot $Snapshot
        }.GetNewClosure() } $hr5Local
        # ОДНА сесія на всі наступні цикли = персистентний remote
        $hr5Session = New-BRAVOSelfTestFakeBazaSession
        $hr5Session.State.RemoteSizes['/baza_app/sticky.txt'] = [int64]90
        $hr5Cycle1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr5Local -RemoteRootPath '/baza_app' -Session $hr5Session -StateRoot $hr5State -BootstrapIfNeeded -ForceFullAudit -FullAuditProvider $hr5StickyProvider
        $hr5StateAfter1 = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $hr5State -Component 'BAZA_APP')

        # цикл 2: ЗВИЧАЙНИЙ (без Full Audit) -- блокер із state мусить діяти
        $hr5Cycle2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr5Local -RemoteRootPath '/baza_app' -Session $hr5Session -StateRoot $hr5State
        $hr5StateAfter2 = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $hr5State -Component 'BAZA_APP')
        $hr5Cycle2Health = Get-BRAVOBazaFastHealthResult -SyncResult $hr5Cycle2
        Test-BRAVOCondition -Condition (
            $hr5Cycle1.Status -eq 'AUDIT_DRIFT' -and
            [string]$hr5StateAfter1.State.Files['sticky.txt'].BlockReason -eq 'AuditDrift' -and
            $hr5Cycle2.Status -eq 'AUDIT_DRIFT' -and
            $hr5Session.State.PutFilesCallCount -eq 0 -and
            [bool]$hr5StateAfter2.State.Files['sticky.txt'].Verified -eq $false -and
            $hr5Cycle2Health.Healthy -eq $false -and $hr5Cycle2Health.Level -eq 'CRITICAL' -and
            $hr5Cycle2Health.Message -match 'sticky\.txt'
        ) -Name 'BazaSync/AuditDriftRemainsBlockedOnNextNormalCycle' -Failure "цикл N+1 БЕЗ Full Audit мусить лишатись AUDIT_DRIFT через persisted блокер (0 PutFiles, Verified=false, Health CRITICAL); Cycle1=$($hr5Cycle1.Status) Cycle2=$($hr5Cycle2.Status) PutFiles=$($hr5Session.State.PutFilesCallCount) Healthy=$($hr5Cycle2Health.Healthy)"

        $hr5Cycle3 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr5Local -RemoteRootPath '/baza_app' -Session $hr5Session -StateRoot $hr5State
        Test-BRAVOCondition -Condition (
            $hr5Cycle3.Status -eq 'AUDIT_DRIFT' -and
            (@($hr5Cycle3.AuditDriftFiles).Count -eq 1) -and
            $hr5Cycle3.AuditDriftFiles[0].Action -eq 'UploadUpdate' -and
            $hr5Session.State.PutFilesCallCount -eq 0
        ) -Name 'BazaSync/AuditDriftPersistsAcrossMultipleNormalCycles' -Failure "блокер діє й на N+2 (Action із persisted блокера зберігається); Cycle3=$($hr5Cycle3.Status) Action=$($hr5Cycle3.AuditDriftFiles[0].Action) PutFiles=$($hr5Session.State.PutFilesCallCount)"

        Test-BRAVOCondition -Condition (
            $hr5Cycle2.RecoveredRemote -eq 0 -and $hr5Cycle3.RecoveredRemote -eq 0 -and
            $hr5Session.State.PutFilesCallCount -eq 0
        ) -Name 'BazaSync/PersistedAuditDriftNeverUsesAlreadyRemoteRecovery' -Failure "persisted блокер повністю виключає AlreadyRemote-recovery (RecoveredRemote=0, PutFiles=0 на всіх циклах); C2=$($hr5Cycle2.RecoveredRemote) C3=$($hr5Cycle3.RecoveredRemote) PutFiles=$($hr5Session.State.PutFilesCallCount)"

        $hr5StateAfter3 = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $hr5State -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            -not [string]::IsNullOrWhiteSpace($hr5ProvenanceUtc) -and
            [string]$hr5StateAfter3.State.LastSuccessfulSyncUtc -ceq $hr5ProvenanceUtc -and
            [string]$hr5StateAfter3.State.LastCycleId -ceq $hr5ProvenanceCycleId
        ) -Name 'BazaSync/AuditDriftDoesNotAdvanceProvenanceOnLaterNormalCycle' -Failure "пізніші заблоковані цикли НЕ просувають LastSuccessfulSyncUtc/LastCycleId; було=$hr5ProvenanceUtc стало=$($hr5StateAfter3.State.LastSuccessfulSyncUtc)"

        $hr5CheckpointSession = New-BRAVOSelfTestFakeBazaSession
        $hr5CheckpointOutcome = Write-BRAVOBazaRemoteCheckpoint -Session $hr5CheckpointSession -RemoteRootPath '/baza_app' -SyncResult $hr5Cycle2
        Test-BRAVOCondition -Condition (
            $hr5CheckpointOutcome.Attempted -eq $false -and $hr5CheckpointOutcome.Published -eq $false -and
            $hr5CheckpointSession.State.PutFilesCallCount -eq 0
        ) -Name 'BazaSync/AuditDriftDoesNotPublishCheckpointOnLaterNormalCycle' -Failure "заблокований пізніший цикл не публікує checkpoint; Attempted=$($hr5CheckpointOutcome.Attempted)"

        # розв'язка A: пізніший Full Audit підтверджує збіг -> блокер знято
        $hr5MatchProvider = & { param($hr5Local) {
            param($Snapshot)
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @() -LocalDirectory $hr5Local -LocalSnapshot $Snapshot
        }.GetNewClosure() } $hr5Local
        $hr5Cycle4 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr5Local -RemoteRootPath '/baza_app' -Session $hr5Session -StateRoot $hr5State -BootstrapIfNeeded -ForceFullAudit -FullAuditProvider $hr5MatchProvider
        $hr5StateAfter4 = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $hr5State -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $hr5Cycle4.Status -eq 'COMPLETE' -and
            [bool]$hr5StateAfter4.State.Files['sticky.txt'].Verified -eq $true -and
            $null -eq $hr5StateAfter4.State.Files['sticky.txt'].PSObject.Properties['BlockReason'] -and
            [string]$hr5StateAfter4.State.LastSuccessfulSyncUtc -cne $hr5ProvenanceUtc
        ) -Name 'BazaSync/AuditDriftClearedWhenLaterFullAuditMatches' -Failure "пізніший audit, що підтвердив збіг, знімає блокер (Verified=true, без BlockReason) і цикл COMPLETE; Status=$($hr5Cycle4.Status) Verified=$($hr5StateAfter4.State.Files['sticky.txt'].Verified)"

        # розв'язка B: remote прибрано -> targeted upload + верифікація -> блокер знято
        $hr5ResBRoot = Join-Path $bazaSyncTestRoot "HR5_ResB"
        $hr5ResBLocal = Join-Path $hr5ResBRoot "local"
        $hr5ResBState = Join-Path $hr5ResBRoot "state"
        New-Item -ItemType Directory -Path $hr5ResBLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr5ResBLocal -RelativePath "stickyB.txt" -SizeBytes 70 | Out-Null
        $hr5ResBProvider = & { param($hr5ResBLocal) {
            param($Snapshot)
            $pendingFile = [pscustomobject]@{ IsDirectory = $false; Path = (Join-Path $hr5ResBLocal "stickyB.txt"); Action = 'UploadUpdate'; Reason = 'drift' }
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @($pendingFile) -LocalDirectory $hr5ResBLocal -LocalSnapshot $Snapshot
        }.GetNewClosure() } $hr5ResBLocal
        $hr5ResBSession = New-BRAVOSelfTestFakeBazaSession
        $hr5ResBSession.State.RemoteSizes['/baza_app/stickyB.txt'] = [int64]70
        $hr5ResBCycle1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr5ResBLocal -RemoteRootPath '/baza_app' -Session $hr5ResBSession -StateRoot $hr5ResBState -BootstrapIfNeeded -FullAuditProvider $hr5ResBProvider
        $hr5ResBSession.State.RemoteSizes.Remove('/baza_app/stickyB.txt')
        $hr5ResBCycle2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr5ResBLocal -RemoteRootPath '/baza_app' -Session $hr5ResBSession -StateRoot $hr5ResBState
        $hr5ResBStateRead = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $hr5ResBState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $hr5ResBCycle1.Status -eq 'AUDIT_DRIFT' -and
            $hr5ResBCycle2.Status -eq 'COMPLETE' -and $hr5ResBCycle2.Uploaded -eq 1 -and
            $hr5ResBSession.State.PutFilesCallCount -eq 1 -and
            [bool]$hr5ResBStateRead.State.Files['stickyB.txt'].Verified -eq $true -and
            $null -eq $hr5ResBStateRead.State.Files['stickyB.txt'].PSObject.Properties['BlockReason']
        ) -Name 'BazaSync/AuditDriftClearedAfterRemoteRemovedAndSuccessfulUpload' -Failure "remote зник -> звичайний targeted upload + верифікація -> Verified=true, блокер знято; C1=$($hr5ResBCycle1.Status) C2=$($hr5ResBCycle2.Status) PutFiles=$($hr5ResBSession.State.PutFilesCallCount)"

        # bootstrap-drift персистує в наступний цикл
        $hr5BootRoot = Join-Path $bazaSyncTestRoot "HR5_Boot"
        $hr5BootLocal = Join-Path $hr5BootRoot "local"
        $hr5BootState = Join-Path $hr5BootRoot "state"
        New-Item -ItemType Directory -Path $hr5BootLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr5BootLocal -RelativePath "bdrift.txt" -SizeBytes 40 | Out-Null
        $hr5BootProvider = & { param($hr5BootLocal) {
            param($Snapshot)
            $pendingFile = [pscustomobject]@{ IsDirectory = $false; Path = (Join-Path $hr5BootLocal "bdrift.txt"); Action = 'UploadUpdate'; Reason = 'drift при bootstrap' }
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @($pendingFile) -LocalDirectory $hr5BootLocal -LocalSnapshot $Snapshot
        }.GetNewClosure() } $hr5BootLocal
        $hr5BootSession = New-BRAVOSelfTestFakeBazaSession
        $hr5BootSession.State.RemoteSizes['/baza_app/bdrift.txt'] = [int64]40
        $hr5BootCycle1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr5BootLocal -RemoteRootPath '/baza_app' -Session $hr5BootSession -StateRoot $hr5BootState -BootstrapIfNeeded -FullAuditProvider $hr5BootProvider
        $hr5BootCycle2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr5BootLocal -RemoteRootPath '/baza_app' -Session $hr5BootSession -StateRoot $hr5BootState
        Test-BRAVOCondition -Condition (
            $hr5BootCycle1.Status -eq 'AUDIT_DRIFT' -and
            $hr5BootCycle2.Status -eq 'AUDIT_DRIFT' -and
            $hr5BootSession.State.PutFilesCallCount -eq 0
        ) -Name 'BazaSync/BootstrapAuditDriftPersistsIntoNextCycle' -Failure "bootstrap-drift мусить персистувати в наступний звичайний цикл; C1=$($hr5BootCycle1.Status) C2=$($hr5BootCycle2.Status) PutFiles=$($hr5BootSession.State.PutFilesCallCount)"

        # corrupt-реконсиляція: drift-блокер персистує так само
        $hr5CorRoot = Join-Path $bazaSyncTestRoot "HR5_Corrupt"
        $hr5CorLocal = Join-Path $hr5CorRoot "local"
        $hr5CorState = Join-Path $hr5CorRoot "state"
        New-Item -ItemType Directory -Path $hr5CorLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr5CorLocal -RelativePath "goodC.txt" -SizeBytes 20 | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr5CorLocal -RelativePath "stickyC.txt" -SizeBytes 50 | Out-Null
        $hr5CorStatePath = Get-BRAVOBazaStatePath -StateRoot $hr5CorState -Component 'BAZA_APP'
        New-Item -ItemType Directory -Path (Split-Path $hr5CorStatePath -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($hr5CorStatePath, "{ corrupt for hr5", (New-Object Text.UTF8Encoding($false)))
        $hr5CorProvider = & { param($hr5CorLocal) {
            param($Snapshot)
            $pendingFile = [pscustomobject]@{ IsDirectory = $false; Path = (Join-Path $hr5CorLocal "stickyC.txt"); Action = 'UploadUpdate'; Reason = 'drift при реконсиляції' }
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @($pendingFile) -LocalDirectory $hr5CorLocal -LocalSnapshot $Snapshot
        }.GetNewClosure() } $hr5CorLocal
        $hr5CorSession = New-BRAVOSelfTestFakeBazaSession
        $hr5CorSession.State.RemoteSizes['/baza_app/stickyC.txt'] = [int64]50
        $hr5CorCycle1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr5CorLocal -RemoteRootPath '/baza_app' -Session $hr5CorSession -StateRoot $hr5CorState -BootstrapIfNeeded -FullAuditProvider $hr5CorProvider
        $hr5CorCycle2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr5CorLocal -RemoteRootPath '/baza_app' -Session $hr5CorSession -StateRoot $hr5CorState
        $hr5CorStateRead = Read-BRAVOBazaState -Path $hr5CorStatePath
        Test-BRAVOCondition -Condition (
            $hr5CorCycle1.Status -eq 'AUDIT_DRIFT' -and
            $hr5CorCycle2.Status -eq 'AUDIT_DRIFT' -and
            $hr5CorSession.State.PutFilesCallCount -eq 0 -and
            [bool]$hr5CorStateRead.State.Files['goodC.txt'].Verified -eq $true -and
            [string]$hr5CorStateRead.State.Files['stickyC.txt'].BlockReason -eq 'AuditDrift'
        ) -Name 'BazaSync/CorruptStateReconciliationAuditDriftPersists' -Failure "drift, виявлений при corrupt-реконсиляції, персистує в наступний цикл (блокер у свіжому state); C1=$($hr5CorCycle1.Status) C2=$($hr5CorCycle2.Status) PutFiles=$($hr5CorSession.State.PutFilesCallCount)"

        # =======================================================================
        # HARDENING ROUND 5, P2: порожній знімок -- авторитетний; $null --
        # сентинел "знімка немає" (лише тоді fallback на persisted state)
        # =======================================================================
        $hr5EmpRoot = Join-Path $bazaSyncTestRoot "HR5_Empty"
        $hr5EmpLocal = Join-Path $hr5EmpRoot "local"
        $hr5EmpState = Join-Path $hr5EmpRoot "state"
        New-Item -ItemType Directory -Path $hr5EmpLocal -Force | Out-Null
        $hr5EmpFile = New-BRAVOSelfTestBazaFile -Directory $hr5EmpLocal -RelativePath "x.txt" -SizeBytes 10
        [void](Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr5EmpLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr5EmpState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider)
        Remove-Item -LiteralPath $hr5EmpFile -Force
        $hr5EmpCycle2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr5EmpLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr5EmpState
        $hr5EmpNoChange = Update-BRAVOBazaSyncResultNewAfterCutoff -SyncResult $hr5EmpCycle2 -LocalDirectory $hr5EmpLocal -StateRoot $hr5EmpState
        Test-BRAVOCondition -Condition (
            $hr5EmpCycle2.Status -eq 'COMPLETE' -and
            $hr5EmpCycle2.DiscoveredWithinCutoff -eq 0 -and
            $null -ne $hr5EmpCycle2.CutoffSnapshotRelativePaths -and
            $hr5EmpNoChange.NewAfterCutoff -eq 0
        ) -Name 'BazaSync/EmptyCutoffSnapshotIsAuthoritative' -Failure "валідний ПОРОЖНІЙ знімок (не-null, 0 шляхів) авторитетний: без нових файлів NewAfterCutoff=0; Status=$($hr5EmpCycle2.Status) Captured=$($null -ne $hr5EmpCycle2.CutoffSnapshotRelativePaths) NewAfterCutoff=$($hr5EmpNoChange.NewAfterCutoff)"

        New-BRAVOSelfTestBazaFile -Directory $hr5EmpLocal -RelativePath "y.txt" -SizeBytes 10 | Out-Null
        $hr5EmpWithY = Update-BRAVOBazaSyncResultNewAfterCutoff -SyncResult $hr5EmpCycle2 -LocalDirectory $hr5EmpLocal -StateRoot $hr5EmpState
        Test-BRAVOCondition -Condition ($hr5EmpWithY.NewAfterCutoff -eq 1) `
            -Name 'BazaSync/FileAddedAfterEmptySnapshotCountsAsNew' -Failure "файл, доданий після порожнього знімка, рахується новим; отримано $($hr5EmpWithY.NewAfterCutoff)"

        # x.txt повертається ПІСЛЯ порожнього cutoff: старий persisted state
        # досі пам'ятає x.txt -- state-fallback дав би 1 (лише y), membership
        # порожнього знімка чесно дає 2 (x знову з'явився ПІСЛЯ cutoff)
        New-BRAVOSelfTestBazaFile -Directory $hr5EmpLocal -RelativePath "x.txt" -SizeBytes 10 | Out-Null
        $hr5EmpWithXY = Update-BRAVOBazaSyncResultNewAfterCutoff -SyncResult $hr5EmpCycle2 -LocalDirectory $hr5EmpLocal -StateRoot $hr5EmpState
        Test-BRAVOCondition -Condition ($hr5EmpWithXY.NewAfterCutoff -eq 2) `
            -Name 'BazaSync/EmptySnapshotDoesNotFallbackToOldPersistedState' -Failure "порожній знімок НЕ падає у fallback на старий persisted state: x.txt, що повернувся після cutoff, теж рахується (2, не 1); отримано $($hr5EmpWithXY.NewAfterCutoff)"

        # =======================================================================
        # HARDENING ROUND 6, P1-1: sticky AuditDrift-блокер НЕ зникає разом
        # із локальним шляхом (зникнення джерела -- не позитивна розв'язка)
        # =======================================================================
        $hr6MisRoot = Join-Path $bazaSyncTestRoot "HR6_Missing"
        $hr6MisLocal = Join-Path $hr6MisRoot "local"
        $hr6MisState = Join-Path $hr6MisRoot "state"
        New-Item -ItemType Directory -Path $hr6MisLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr6MisLocal -RelativePath "ok0.txt" -SizeBytes 20 | Out-Null
        [void](Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr6MisLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr6MisState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider)
        $hr6MisStatePath = Get-BRAVOBazaStatePath -StateRoot $hr6MisState -Component 'BAZA_APP'
        $hr6MisProvenance = [string](Read-BRAVOBazaState -Path $hr6MisStatePath).State.LastSuccessfulSyncUtc

        $hr6MisGone = New-BRAVOSelfTestBazaFile -Directory $hr6MisLocal -RelativePath "gone.txt" -SizeBytes 90
        $hr6MisProvider = & { param($hr6MisLocal) {
            param($Snapshot)
            $pendingFile = [pscustomobject]@{ IsDirectory = $false; Path = (Join-Path $hr6MisLocal "gone.txt"); Action = 'UploadUpdate'; Reason = 'drift' }
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @($pendingFile) -LocalDirectory $hr6MisLocal -LocalSnapshot $Snapshot
        }.GetNewClosure() } $hr6MisLocal
        $hr6MisSession = New-BRAVOSelfTestFakeBazaSession
        $hr6MisSession.State.RemoteSizes['/baza_app/gone.txt'] = [int64]90
        $hr6MisCycle1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr6MisLocal -RemoteRootPath '/baza_app' -Session $hr6MisSession -StateRoot $hr6MisState -BootstrapIfNeeded -ForceFullAudit -FullAuditProvider $hr6MisProvider

        Remove-Item -LiteralPath $hr6MisGone -Force
        $hr6MisCycle2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr6MisLocal -RemoteRootPath '/baza_app' -Session $hr6MisSession -StateRoot $hr6MisState
        Test-BRAVOCondition -Condition (
            $hr6MisCycle1.Status -eq 'AUDIT_DRIFT' -and
            $hr6MisCycle2.Status -eq 'AUDIT_DRIFT' -and $hr6MisCycle2.Status -ne 'COMPLETE' -and
            (@($hr6MisCycle2.AuditDriftFiles).Count -eq 1) -and
            $hr6MisCycle2.AuditDriftFiles[0].RelativePath -eq 'gone.txt' -and
            [bool]$hr6MisCycle2.AuditDriftFiles[0].LocalMissing -eq $true
        ) -Name 'BazaSync/PersistedAuditDriftMissingLocalNeverProducesComplete' -Failure "блокер зі зниклим локальним шляхом мусить виринати як AUDIT_DRIFT/LocalMissing, ніколи COMPLETE; C1=$($hr6MisCycle1.Status) C2=$($hr6MisCycle2.Status) Drift=$(@($hr6MisCycle2.AuditDriftFiles).Count)"

        $hr6MisHealth = Get-BRAVOBazaFastHealthResult -SyncResult $hr6MisCycle2
        Test-BRAVOCondition -Condition (
            $hr6MisHealth.Healthy -eq $false -and $hr6MisHealth.Level -eq 'CRITICAL' -and
            $hr6MisHealth.Message -match 'gone\.txt'
        ) -Name 'BazaSync/PersistedAuditDriftMissingLocalRemainsUnhealthy' -Failure "Health для missing-local блокера: CRITICAL з точним шляхом; Healthy=$($hr6MisHealth.Healthy) Message=$($hr6MisHealth.Message)"
        } catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'BazaSync/AuditPendingDoesNotAdvanceLastSuccessfulSyncUtc' } }
        if (Enter-BRAVOSelfTestSection -Name 'BazaSync/PersistedAuditDriftMissingLocalDoesNotAdvanceProvenance' -DependsOn 'BazaSync/AuditPendingDoesNotAdvanceLastSuccessfulSyncUtc') { try {

        $hr6MisStateAfter2 = Read-BRAVOBazaState -Path $hr6MisStatePath
        Test-BRAVOCondition -Condition (
            -not [string]::IsNullOrWhiteSpace($hr6MisProvenance) -and
            [string]$hr6MisStateAfter2.State.LastSuccessfulSyncUtc -ceq $hr6MisProvenance
        ) -Name 'BazaSync/PersistedAuditDriftMissingLocalDoesNotAdvanceProvenance' -Failure "missing-local блокер не просуває LastSuccessfulSyncUtc; було=$hr6MisProvenance стало=$($hr6MisStateAfter2.State.LastSuccessfulSyncUtc)"

        $hr6MisCpSession = New-BRAVOSelfTestFakeBazaSession
        $hr6MisCpOutcome = Write-BRAVOBazaRemoteCheckpoint -Session $hr6MisCpSession -RemoteRootPath '/baza_app' -SyncResult $hr6MisCycle2
        Test-BRAVOCondition -Condition ($hr6MisCpOutcome.Attempted -eq $false -and $hr6MisCpSession.State.PutFilesCallCount -eq 0) `
            -Name 'BazaSync/PersistedAuditDriftMissingLocalDoesNotPublishCheckpoint' -Failure "missing-local блокер не публікує checkpoint; Attempted=$($hr6MisCpOutcome.Attempted)"

        $hr6MisMatchProvider = & { param($hr6MisLocal) {
            param($Snapshot)
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @() -LocalDirectory $hr6MisLocal -LocalSnapshot $Snapshot
        }.GetNewClosure() } $hr6MisLocal
        $hr6MisCycle3 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr6MisLocal -RemoteRootPath '/baza_app' -Session $hr6MisSession -StateRoot $hr6MisState -BootstrapIfNeeded -ForceFullAudit -FullAuditProvider $hr6MisMatchProvider
        $hr6MisStateAfter3 = Read-BRAVOBazaState -Path $hr6MisStatePath
        Test-BRAVOCondition -Condition (
            $hr6MisCycle3.Status -eq 'AUDIT_DRIFT' -and
            [string]$hr6MisStateAfter3.State.Files['gone.txt'].BlockReason -eq 'AuditDrift'
        ) -Name 'BazaSync/PersistedAuditDriftMissingLocalSurvivesFullAudit' -Failure "пізніший Full Audit (шлях відсутній у знімку) НЕ сміє мовчки зняти блокер; C3=$($hr6MisCycle3.Status) BlockReason=$($hr6MisStateAfter3.State.Files['gone.txt'].BlockReason)"

        New-BRAVOSelfTestBazaFile -Directory $hr6MisLocal -RelativePath "gone.txt" -SizeBytes 90 | Out-Null
        $hr6MisCycle4 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr6MisLocal -RemoteRootPath '/baza_app' -Session $hr6MisSession -StateRoot $hr6MisState
        Test-BRAVOCondition -Condition (
            $hr6MisCycle4.Status -eq 'AUDIT_DRIFT' -and
            $hr6MisSession.State.PutFilesCallCount -eq 0
        ) -Name 'BazaSync/RestoredLocalPathStillCarriesAuditBlockUntilResolved' -Failure "відновлений локальний шлях досі під блокером (remote зайнятий) -- AUDIT_DRIFT без передач; C4=$($hr6MisCycle4.Status) PutFiles=$($hr6MisSession.State.PutFilesCallCount)"

        # =======================================================================
        # HARDENING ROUND 6, P1-2: write-ahead маркер trust-переходу Full Audit
        # =======================================================================
        $hr6MkRoot = Join-Path $bazaSyncTestRoot "HR6_Marker"
        $hr6MkLocal = Join-Path $hr6MkRoot "local"
        $hr6MkState = Join-Path $hr6MkRoot "state"
        New-Item -ItemType Directory -Path $hr6MkLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr6MkLocal -RelativePath "m1.txt" -SizeBytes 25 | Out-Null
        [void](Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr6MkLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr6MkState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider)
        $hr6MkStatePath = Get-BRAVOBazaStatePath -StateRoot $hr6MkState -Component 'BAZA_APP'

        # маркер неможливо зберегти -> audit НЕ запускається взагалі
        $hr6MkProbe = @{ Invoked = 0 }
        $hr6MkProbeProvider = & { param($hr6MkProbe) {
            param($Snapshot)
            $hr6MkProbe.Invoked++
            return [pscustomobject]@{ Success = $true; Error = $null; AlreadyMatchingRelativePaths = @(); LocalSizes = @{}; LastWriteTimesUtc = @{}; PendingItems = @() }
        }.GetNewClosure() } $hr6MkProbe
        [IO.File]::SetAttributes($hr6MkStatePath, [IO.FileAttributes]::ReadOnly)
        $hr6MkCycleA = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr6MkLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr6MkState -BootstrapIfNeeded -ForceFullAudit -FullAuditProvider $hr6MkProbeProvider
        [IO.File]::SetAttributes($hr6MkStatePath, [IO.FileAttributes]::Normal)
        $hr6MkStateAfterA = Read-BRAVOBazaState -Path $hr6MkStatePath
        Test-BRAVOCondition -Condition (
            $hr6MkCycleA.Status -eq 'ERROR' -and $hr6MkCycleA.Error -match 'маркер' -and
            $hr6MkProbe.Invoked -eq 0 -and
            [bool]$hr6MkStateAfterA.State.AuditReconciliationPending -eq $false
        ) -Name 'BazaSync/FullAuditDoesNotRunIfPendingMarkerCannotBeSaved' -Failure "без збереженого write-ahead маркера Full Audit НЕ запускається (контрольований ERROR, провайдер не викликано); Status=$($hr6MkCycleA.Status) Invoked=$($hr6MkProbe.Invoked)"

        # маркер на диску = true САМЕ на момент виконання audit
        $hr6MkCapture = @{ PendingAtAudit = $null }
        $hr6MkCaptureProvider = & { param($hr6MkCapture, $hr6MkLocal, $hr6MkStatePath) {
            param($Snapshot)
            $diskState = Read-BRAVOBazaState -Path $hr6MkStatePath
            $hr6MkCapture.PendingAtAudit = [bool]$diskState.State.AuditReconciliationPending
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @() -LocalDirectory $hr6MkLocal -LocalSnapshot $Snapshot
        }.GetNewClosure() } $hr6MkCapture $hr6MkLocal $hr6MkStatePath
        $hr6MkCycleB = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr6MkLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr6MkState -BootstrapIfNeeded -ForceFullAudit -FullAuditProvider $hr6MkCaptureProvider
        $hr6MkStateAfterB = Read-BRAVOBazaState -Path $hr6MkStatePath
        Test-BRAVOCondition -Condition (
            $hr6MkCycleB.Status -eq 'COMPLETE' -and
            $hr6MkCapture.PendingAtAudit -eq $true -and
            [bool]$hr6MkStateAfterB.State.AuditReconciliationPending -eq $false
        ) -Name 'BazaSync/FullAuditWritesPendingMarkerBeforeAudit' -Failure "на момент виконання audit маркер на ДИСКУ мусить бути true, після успішного циклу -- false; PendingAtAudit=$($hr6MkCapture.PendingAtAudit) After=$($hr6MkStateAfterB.State.AuditReconciliationPending)"

        # збій ФІНАЛЬНОГО збереження після audit-drift -> маркер лишається true
        New-BRAVOSelfTestBazaFile -Directory $hr6MkLocal -RelativePath "m2.txt" -SizeBytes 35 | Out-Null
        $hr6MkSession = New-BRAVOSelfTestFakeBazaSession
        $hr6MkSession.State.RemoteSizes['/baza_app/m2.txt'] = [int64]35
        $hr6MkDriftProvider = & { param($hr6MkLocal, $hr6MkStatePath) {
            param($Snapshot)
            # ReadOnly ставиться ПІД ЧАС audit (маркер уже збережено) --
            # модель: audit пройшов, фінальне збереження впаде
            [IO.File]::SetAttributes($hr6MkStatePath, [IO.FileAttributes]::ReadOnly)
            $pendingFile = [pscustomobject]@{ IsDirectory = $false; Path = (Join-Path $hr6MkLocal "m2.txt"); Action = 'UploadUpdate'; Reason = 'drift' }
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @($pendingFile) -LocalDirectory $hr6MkLocal -LocalSnapshot $Snapshot
        }.GetNewClosure() } $hr6MkLocal $hr6MkStatePath
        $hr6MkCycleC = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr6MkLocal -RemoteRootPath '/baza_app' -Session $hr6MkSession -StateRoot $hr6MkState -BootstrapIfNeeded -ForceFullAudit -FullAuditProvider $hr6MkDriftProvider
        $hr6MkStateAfterC = Read-BRAVOBazaState -Path $hr6MkStatePath
        Test-BRAVOCondition -Condition (
            $hr6MkCycleC.Status -eq 'AUDIT_DRIFT' -and
            [bool]$hr6MkStateAfterC.State.AuditReconciliationPending -eq $true -and
            [bool]$hr6MkStateAfterC.State.Files['m1.txt'].Verified -eq $true
        ) -Name 'BazaSync/AuditDriftFinalStateSaveFailureLeavesPendingMarker' -Failure "збій фінального збереження після audit лишає на диску маркер true (стара довіра на диску захищена маркером); Status=$($hr6MkCycleC.Status) Pending=$($hr6MkStateAfterC.State.AuditReconciliationPending)"

        [IO.File]::SetAttributes($hr6MkStatePath, [IO.FileAttributes]::Normal)

        # standalone на pending-стані: fail closed, нуль upload/TrustedSkip
        $hr6MkStandaloneSession = New-BRAVOSelfTestFakeBazaSession
        $hr6MkCycleD = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr6MkLocal -RemoteRootPath '/baza_app' -Session $hr6MkStandaloneSession -StateRoot $hr6MkState
        $hr6MkCycleDHealth = Get-BRAVOBazaFastHealthResult -SyncResult $hr6MkCycleD
        Test-BRAVOCondition -Condition (
            $hr6MkCycleD.Status -eq 'RECONCILIATION_REQUIRED' -and
            $hr6MkStandaloneSession.State.PutFilesCallCount -eq 0 -and
            $hr6MkCycleD.Uploaded -eq 0 -and
            $hr6MkCycleDHealth.Healthy -eq $false -and $hr6MkCycleDHealth.Level -eq 'CRITICAL'
        ) -Name 'BazaSync/PendingAuditMarkerStandaloneHealthFailsClosed' -Failure "standalone на pending-маркері: RECONCILIATION_REQUIRED, нуль передач, CRITICAL; Status=$($hr6MkCycleD.Status) PutFiles=$($hr6MkStandaloneSession.State.PutFilesCallCount) Healthy=$($hr6MkCycleDHealth.Healthy)"

        Test-BRAVOCondition -Condition ($hr6MkCycleD.AlreadyVerified -eq 0) `
            -Name 'BazaSync/PendingAuditMarkerNeverTrustedSkipsOldVerifiedEntries' -Failure "pending-маркер: жодного TrustedSkip старих Verified-записів (відмова ДО планувальника); AlreadyVerified=$($hr6MkCycleD.AlreadyVerified)"

        Test-BRAVOCondition -Condition ($hr6MkCycleDHealth.Healthy -eq $false) `
            -Name 'BazaSync/CrashBetweenAuditAndFinalStateSaveCannotBecomeHealthy' -Failure "crash між audit і фінальним збереженням НІКОЛИ не дає Healthy на наступному циклі; Healthy=$($hr6MkCycleDHealth.Healthy)"

        # Archive на pending-стані: реконсиляція примусова (без -ForceFullAudit),
        # маркер знімається лише після успішного фінального збереження
        $hr6MkMatchProbe = @{ Invoked = 0 }
        $hr6MkMatchProvider = & { param($hr6MkLocal, $hr6MkMatchProbe) {
            param($Snapshot)
            $hr6MkMatchProbe.Invoked++
            return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @() -LocalDirectory $hr6MkLocal -LocalSnapshot $Snapshot
        }.GetNewClosure() } $hr6MkLocal $hr6MkMatchProbe
        $hr6MkCycleE = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr6MkLocal -RemoteRootPath '/baza_app' -Session $hr6MkSession -StateRoot $hr6MkState -BootstrapIfNeeded -FullAuditProvider $hr6MkMatchProvider
        $hr6MkStateAfterE = Read-BRAVOBazaState -Path $hr6MkStatePath
        Test-BRAVOCondition -Condition (
            $hr6MkCycleE.Status -eq 'COMPLETE' -and
            $hr6MkMatchProbe.Invoked -eq 1 -and
            $hr6MkCycleE.FullAuditAttempted -eq $true
        ) -Name 'BazaSync/PendingAuditMarkerArchiveReconcilesWithFullAudit' -Failure "Archive на pending-маркері примусово повторює Full Audit (навіть без -ForceFullAudit) і завершує реконсиляцію; Status=$($hr6MkCycleE.Status) Invoked=$($hr6MkMatchProbe.Invoked)"

        Test-BRAVOCondition -Condition (
            [bool]$hr6MkStateAfterC.State.AuditReconciliationPending -eq $true -and
            [bool]$hr6MkStateAfterE.State.AuditReconciliationPending -eq $false
        ) -Name 'BazaSync/PendingAuditMarkerClearsOnlyAfterSuccessfulFinalSave' -Failure "маркер знімається ЛИШЕ успішним фінальним збереженням: після збою -- true, після успішної реконсиляції -- false; AfterC=$($hr6MkStateAfterC.State.AuditReconciliationPending) AfterE=$($hr6MkStateAfterE.State.AuditReconciliationPending)"

        # =======================================================================
        # ACCEPTANCE DEV-LIMS: WinSCP.com-стаб замість winscp.exe -- сесія
        # зависала на інтерактивному промпті "winscp>" (CPU~0)
        # =======================================================================
        $accComStubResult = Invoke-BRAVOBazaComponentSyncSession `
            -Component 'BAZA_APP' -LocalDirectory $bazaSyncTestRoot -RemoteRootPath '/baza_app' `
            -RepositorySFTPUrl 'sftp://fake' -HostKey 'fake' `
            -WinSCPAssemblyPath 'unused' -WinSCPExecutablePath 'C:\fake\Tools\WinSCP.com' `
            -StateRoot (Join-Path $bazaSyncTestRoot "ACC_ComStub")
        Test-BRAVOCondition -Condition (
            $accComStubResult.Status -eq 'ERROR' -and
            $accComStubResult.Error -match 'winscp\.exe' -and
            $accComStubResult.Error -match 'WinSCP\.com'
        ) -Name 'BazaSync/ComStubExecutableFailsFastInsteadOfHanging' -Failure "WinSCP.com як ExecutablePath має давати миттєвий контрольований ERROR з поясненням (потрібен winscp.exe), а не зависання на промпті winscp>; Status=$($accComStubResult.Status) Error=$($accComStubResult.Error)"

        Test-BRAVOCondition -Condition (
            $bazaArchiveScriptText.Contains('$winSCPComponents = Get-BRAVOWinSCPDotNetComponents') -and
            $bazaArchiveScriptText.Contains('-WinSCPExecutablePath $winSCPComponents.ExecutablePath') -and
            $bazaArchiveScriptText.Contains('-WinSCPAssemblyPath $winSCPComponents.AssemblyPath') -and
            -not $bazaArchiveScriptText.Contains('-WinSCPExecutablePath $winSCPPath')
        ) -Name 'BazaSync/ArchiveWiringResolvesRealWinSCPExeForEngine' -Failure 'Invoke-BRAVOBazaIncrementalSync має резолвити пару dll+exe через Get-BRAVOWinSCPDotNetComponents (та сама, що legacy Get-BAZASFTPComparison), а НЕ передавати сирий $winSCPPath (WinSCP.com) у -WinSCPExecutablePath'

        # =======================================================================
        # ACCEPTANCE DEV-LIMS blocker #4: .GetNewClosure() на PS 5.1 губить
        # command-lookup ПРИВАТНИХ функцій runtime (Get-BAZASFTPComparison) --
        # провайдер, викликаний через межу модуля BRAVO.BazaSync, падав
        # CommandNotFoundException. Поведінковий тест іде через РЕАЛЬНУ
        # production-функцію New-BRAVOBazaArchiveFullAuditProvider: приватний
        # fake у module scope -> провайдер створюється всередині модуля ->
        # ВИКОНУЄТЬСЯ ззовні (та сама межа, що в production).
        # =======================================================================
        $hr7ProviderModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText $bazaArchiveScriptText `
            -FunctionNames @('New-BRAVOBazaArchiveFullAuditProvider')
        $hr7Probe = @{ Invoked = 0; Url = $null; HostKey = $null; LocalPath = $null }
        $hr7ProducedProvider = & $hr7ProviderModule {
            param($Probe)
            $script:HR7ProviderProbe = $Probe
            # Приватний (module-scope, НЕ exported) двійник Get-BAZASFTPComparison
            # -- рівно та сама видимість, що в production runtime.
            function Get-BAZASFTPComparison {
                param([string]$LocalPath, [string]$RemotePath, [string]$RepositorySFTPUrl, [string]$HostKey)
                $script:HR7ProviderProbe.Invoked++
                $script:HR7ProviderProbe.Url = $RepositorySFTPUrl
                $script:HR7ProviderProbe.HostKey = $HostKey
                $script:HR7ProviderProbe.LocalPath = $LocalPath
                return [pscustomobject]@{ Success = $true; Error = $null; PendingFiles = @() }
            }
            New-BRAVOBazaArchiveFullAuditProvider `
                -LocalDirectory 'C:\fake\hr7local' `
                -RemotePath '/baza_app' `
                -RepositorySFTPUrl 'sftp://hr7-fake-url' `
                -HostKey 'hr7-fake-hostkey'
        } $hr7Probe
        $hr7Snapshot = [pscustomobject]@{ SnapshotUtc = (Get-Date).ToUniversalTime(); Entries = @{}; Success = $true; Error = $null }
        $hr7ProviderError = $null
        $hr7ProviderResult = $null
        try {
            $hr7ProviderResult = & $hr7ProducedProvider $hr7Snapshot
        } catch {
            $hr7ProviderError = $_.Exception.Message
        }
        Test-BRAVOCondition -Condition (
            $null -eq $hr7ProviderError -and
            $hr7Probe.Invoked -eq 1 -and
            $hr7Probe.Url -eq 'sftp://hr7-fake-url' -and
            $hr7Probe.HostKey -eq 'hr7-fake-hostkey' -and
            $hr7Probe.LocalPath -eq 'C:\fake\hr7local' -and
            $null -ne $hr7ProviderResult -and [bool]$hr7ProviderResult.Success -eq $true -and
            $null -ne $hr7ProviderResult.PSObject.Properties['PendingItems']
        ) -Name 'BazaSync/FullAuditProviderCrossesModuleBoundary' -Failure "production-провайдер, виконаний ЗЗОВНІ модуля-творця, має без CommandNotFoundException викликати захоплені референси з явними значеннями; Error=$hr7ProviderError Invoked=$($hr7Probe.Invoked) Url=$($hr7Probe.Url)"

        # Guard скоупиться на ТІЛО closure провайдера: legacy-шляхи (before/
        # after аудити) легітимно викликають Get-BAZASFTPComparison у
        # ВЛАСНОМУ scope -- заборона стосується лише GetNewClosure-тіла.
        $hr7ClosureMatch = [regex]::Match(
            $bazaArchiveScriptText,
            '(?s)function New-BRAVOBazaArchiveFullAuditProvider.*?return \{(.*?)\}\.GetNewClosure\(\)'
        )
        Test-BRAVOCondition -Condition (
            $hr7ClosureMatch.Success -and
            $hr7ClosureMatch.Groups[1].Value.Contains('& $capturedComparisonCommand') -and
            $hr7ClosureMatch.Groups[1].Value.Contains('& $capturedConvertAuditCommand') -and
            -not $hr7ClosureMatch.Groups[1].Value.Contains('Get-BAZASFTPComparison') -and
            -not $hr7ClosureMatch.Groups[1].Value.Contains('ConvertTo-BRAVOBazaFullAuditResult') -and
            $bazaArchiveScriptText.Contains("-Name 'Get-BAZASFTPComparison'") -and
            $bazaArchiveScriptText.Contains("-Name 'ConvertTo-BRAVOBazaFullAuditResult'")
        ) -Name 'BazaSync/FullAuditProviderDoesNotUseBarePrivateCommandLookup' -Failure 'тіло GetNewClosure-провайдера НЕ сміє містити bare-імена Get-BAZASFTPComparison/ConvertTo-BRAVOBazaFullAuditResult -- лише виклики через захоплені Get-Command референси (& $captured...)'

        # Recovery-ланцюг із PRODUCTION provider-boundary: маркер на диску ->
        # наступний Archive-прогін примусово реконсилюється РЕАЛЬНИМ
        # провайдером (fake лише на рівні приватного порівняння) -> COMPLETE,
        # маркер знято.
        $hr7RecRoot = Join-Path $bazaSyncTestRoot "HR7_Recovery"
        $hr7RecLocal = Join-Path $hr7RecRoot "local"
        $hr7RecState = Join-Path $hr7RecRoot "state"
        New-Item -ItemType Directory -Path $hr7RecLocal -Force | Out-Null
        New-BRAVOSelfTestBazaFile -Directory $hr7RecLocal -RelativePath "m7.txt" -SizeBytes 30 | Out-Null
        [void](Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr7RecLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr7RecState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider)
        $hr7RecStatePath = Get-BRAVOBazaStatePath -StateRoot $hr7RecState -Component 'BAZA_APP'
        $hr7RecStateRead = Read-BRAVOBazaState -Path $hr7RecStatePath
        $hr7RecStateRead.State.AuditReconciliationPending = $true
        Save-BRAVOBazaState -Path $hr7RecStatePath -State $hr7RecStateRead.State

        $hr7RecProbe = @{ Invoked = 0; Url = $null; HostKey = $null; LocalPath = $null }
        $hr7RecProvider = & $hr7ProviderModule {
            param($Probe, $LocalDirectory)
            $script:HR7ProviderProbe = $Probe
            function Get-BAZASFTPComparison {
                param([string]$LocalPath, [string]$RemotePath, [string]$RepositorySFTPUrl, [string]$HostKey)
                $script:HR7ProviderProbe.Invoked++
                return [pscustomobject]@{ Success = $true; Error = $null; PendingFiles = @() }
            }
            New-BRAVOBazaArchiveFullAuditProvider `
                -LocalDirectory $LocalDirectory `
                -RemotePath '/baza_app' `
                -RepositorySFTPUrl 'sftp://hr7-fake-url' `
                -HostKey 'hr7-fake-hostkey'
        } $hr7RecProbe $hr7RecLocal
        $hr7RecCycle = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $hr7RecLocal -RemoteRootPath '/baza_app' -Session (New-BRAVOSelfTestFakeBazaSession) -StateRoot $hr7RecState -BootstrapIfNeeded -FullAuditProvider $hr7RecProvider
        $hr7RecStateAfter = Read-BRAVOBazaState -Path $hr7RecStatePath
        Test-BRAVOCondition -Condition (
            $hr7RecCycle.Status -eq 'COMPLETE' -and
            $hr7RecCycle.FullAuditAttempted -eq $true -and
            $hr7RecProbe.Invoked -eq 1 -and
            [bool]$hr7RecStateAfter.State.AuditReconciliationPending -eq $false -and
            [bool]$hr7RecStateAfter.State.Files['m7.txt'].Verified -eq $true
        ) -Name 'BazaSync/PendingMarkerRecoveryWorksWithProductionProviderBoundary' -Failure "маркер на диску -> наступний Archive-прогін з PRODUCTION-провайдером (реальна межа модуля) реконсилюється: аудит виконано, COMPLETE, маркер false; Status=$($hr7RecCycle.Status) Invoked=$($hr7RecProbe.Invoked) Pending=$($hr7RecStateAfter.State.AuditReconciliationPending)"

        # =====================================================================
        # BRAVO_BAZA_RECONCILE: операторське розв'язання append-only мутацій
        # (інцидент LIMS 2026-08-21). Rename-only + state-removal; жодного
        # delete і жодного upload за конструкцією.
        # =====================================================================
        $mrLocal = Join-Path $bazaSyncTestRoot 'reconcile_local'
        $mrState = Join-Path $bazaSyncTestRoot 'reconcile_state'
        New-Item -ItemType Directory -Path $mrLocal -Force | Out-Null
        New-Item -ItemType Directory -Path $mrState -Force | Out-Null
        [void](New-BRAVOSelfTestBazaFile -Directory $mrLocal -RelativePath 'doc1.pdf' -SizeBytes 100)
        [void](New-BRAVOSelfTestBazaFile -Directory $mrLocal -RelativePath 'Eqv\звіт.pdf' -SizeBytes 120)
        [void](New-BRAVOSelfTestBazaFile -Directory $mrLocal -RelativePath 'keep.txt' -SizeBytes 50)
        $mrSession = New-BRAVOSelfTestFakeBazaSession
        $mrCycle1 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $mrLocal -RemoteRootPath '/baza_app' -Session $mrSession -StateRoot $mrState -BootstrapIfNeeded -FullAuditProvider $bazaFirstRunNoOpAuditProvider
        # Мутації: два Verified-файли перезаписано ІНШИМ розміром (як в
        # інциденті: застосунок перегенерував PDF).
        [void](New-BRAVOSelfTestBazaFile -Directory $mrLocal -RelativePath 'doc1.pdf' -SizeBytes 150)
        [void](New-BRAVOSelfTestBazaFile -Directory $mrLocal -RelativePath 'Eqv\звіт.pdf' -SizeBytes 180)

        $mrReport = Get-BRAVOBazaMutationReport -Component 'BAZA_APP' -LocalDirectory $mrLocal -StateRoot $mrState
        $mrReportEntry = @($mrReport.Mutations | Where-Object { $_.RelativePath -eq 'doc1.pdf' }) | Select-Object -First 1
        Test-BRAVOCondition -Condition (
            $mrCycle1.Status -eq 'COMPLETE' -and
            $mrReport.Success -eq $true -and
            @($mrReport.Mutations).Count -eq 2 -and
            $null -ne $mrReportEntry -and
            [int64]$mrReportEntry.PreviousSize -eq 100 -and
            [int64]$mrReportEntry.CurrentSize -eq 150 -and
            -not [string]::IsNullOrWhiteSpace([string]$mrReportEntry.UploadedUtc)
        ) -Name 'BazaSync/MutationReportListsPreviousAndCurrentVersions' -Failure "звіт мутацій має показувати стару (state) і нову (диск) версії з UploadedUtc; Count=$(@($mrReport.Mutations).Count)"

        # Захист від -Accept довільного шляху: не-мутація відхиляється, state
        # незмінний, remote неторкнутий.
        $mrBadResult = Invoke-BRAVOBazaMutationReconciliation -Component 'BAZA_APP' -LocalDirectory $mrLocal -StateRoot $mrState -RemoteRootPath '/baza_app' -Session $mrSession -AcceptRelativePaths @('keep.txt')
        $mrStateAfterBad = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $mrState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $mrBadResult.Success -eq $false -and
            @($mrBadResult.Failures).Count -eq 1 -and
            [string]$mrBadResult.Failures[0].Stage -eq 'Validate' -and
            $null -ne $mrStateAfterBad.State.Files['keep.txt'] -and
            $null -ne $mrStateAfterBad.State.Files['doc1.pdf']
        ) -Name 'BazaSync/ReconcileRejectsPathThatIsNotACurrentMutation' -Failure 'шлях, що не є поточною мутацією, має відхилятися на етапі Validate без жодних змін state/remote'

        # Fail-closed: збій remote-rename -> state-ключ НЕ видаляється.
        $mrSession.State.MoveFileShouldFail = $true
        $mrFailResult = Invoke-BRAVOBazaMutationReconciliation -Component 'BAZA_APP' -LocalDirectory $mrLocal -StateRoot $mrState -RemoteRootPath '/baza_app' -Session $mrSession -AcceptRelativePaths @('doc1.pdf')
        $mrSession.State.MoveFileShouldFail = $false
        $mrStateAfterFail = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $mrState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $mrFailResult.Success -eq $false -and
            @($mrFailResult.Failures).Count -eq 1 -and
            [string]$mrFailResult.Failures[0].Stage -eq 'RemoteRename' -and
            @($mrFailResult.StateRemoved).Count -eq 0 -and
            $null -ne $mrStateAfterFail.State.Files['doc1.pdf']
        ) -Name 'BazaSync/ReconcileMoveFailureKeepsStateEntry' -Failure 'збій MoveFile має лишати state-запис неторкнутим (fail-closed: довіра знімається лише після успішного rename)'
        } catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'BazaSync/PersistedAuditDriftMissingLocalDoesNotAdvanceProvenance' } }
        if (Enter-BRAVOSelfTestSection -Name 'BazaSync/ReconcileRenamesRemoteAndRemovesStateEntry' -DependsOn 'BazaSync/PersistedAuditDriftMissingLocalDoesNotAdvanceProvenance') { try {

        # Успішний reconcile обох мутацій: старі remote-версії перейменовано
        # у *.replaced_*, ключі прибрано, keep.txt неторкнутий, ЖОДНОГО
        # RemoveFiles/PutFiles від самого інструмента.
        $mrPutCallsBefore = $mrSession.State.PutFilesCallCount
        $mrOkResult = Invoke-BRAVOBazaMutationReconciliation -Component 'BAZA_APP' -LocalDirectory $mrLocal -StateRoot $mrState -RemoteRootPath '/baza_app' -Session $mrSession -AcceptRelativePaths @('doc1.pdf', 'Eqv\звіт.pdf')
        $mrStateAfterOk = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $mrState -Component 'BAZA_APP')
        $mrRenameCalls = @($mrSession.State.MoveFileCalls | Where-Object { $_ -match '\.replaced_' })
        Test-BRAVOCondition -Condition (
            $mrOkResult.Success -eq $true -and
            @($mrOkResult.RenamedRemote).Count -eq 2 -and
            $mrRenameCalls.Count -ge 2 -and
            ($mrRenameCalls -join '; ') -match '/baza_app/doc1\.pdf -> /baza_app/doc1\.pdf\.replaced_' -and
            $null -eq $mrStateAfterOk.State.Files['doc1.pdf'] -and
            $null -eq $mrStateAfterOk.State.Files['Eqv\звіт.pdf'] -and
            $null -ne $mrStateAfterOk.State.Files['keep.txt'] -and
            @($mrSession.State.RemoveFilesCalls).Count -eq 0 -and
            $mrSession.State.PutFilesCallCount -eq $mrPutCallsBefore
        ) -Name 'BazaSync/ReconcileRenamesRemoteAndRemovesStateEntry' -Failure 'успішний reconcile: rename обох старих remote-версій у *.replaced_*, видалення лише прийнятих ключів, нуль delete/upload від інструмента'

        # Кінець-у-кінець: наступний плановий цикл бачить нові версії як
        # кандидатів, remote-шляхи вільні -> Uploaded, COMPLETE, Verified.
        $mrCycle2 = Invoke-BRAVOBazaSynchronization -Component 'BAZA_APP' -LocalDirectory $mrLocal -RemoteRootPath '/baza_app' -Session $mrSession -StateRoot $mrState
        $mrStateAfterCycle2 = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $mrState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $mrCycle2.Status -eq 'COMPLETE' -and
            [bool]$mrStateAfterCycle2.State.Files['doc1.pdf'].Verified -eq $true -and
            [int64]$mrStateAfterCycle2.State.Files['doc1.pdf'].Size -eq 150 -and
            [int64]$mrSession.State.RemoteSizes['/baza_app/doc1.pdf'] -eq 150 -and
            @($mrSession.State.RemoteSizes.Keys | Where-Object { $_ -match '^/baza_app/doc1\.pdf\.replaced_' }).Count -eq 1
        ) -Name 'BazaSync/ReconcileThenNextCycleUploadsNewVersion' -Failure "після reconcile наступний цикл має залити нові версії на звільнені шляхи і стати COMPLETE; Status=$($mrCycle2.Status)"

        # Remote відсутній (state вірив, файлу в хмарі немає): rename не
        # потрібен, ключ видаляється, Success.
        [void](New-BRAVOSelfTestBazaFile -Directory $mrLocal -RelativePath 'keep.txt' -SizeBytes 77)
        $mrSession.State.RemoteSizes.Remove('/baza_app/keep.txt')
        $mrAbsentResult = Invoke-BRAVOBazaMutationReconciliation -Component 'BAZA_APP' -LocalDirectory $mrLocal -StateRoot $mrState -RemoteRootPath '/baza_app' -Session $mrSession -AcceptRelativePaths @('keep.txt')
        $mrStateAfterAbsent = Read-BRAVOBazaState -Path (Get-BRAVOBazaStatePath -StateRoot $mrState -Component 'BAZA_APP')
        Test-BRAVOCondition -Condition (
            $mrAbsentResult.Success -eq $true -and
            @($mrAbsentResult.RemoteAbsent) -contains 'keep.txt' -and
            @($mrAbsentResult.RenamedRemote).Count -eq 0 -and
            $null -eq $mrStateAfterAbsent.State.Files['keep.txt']
        ) -Name 'BazaSync/ReconcileRemoteAbsentSkipsRenameStillRemovesEntry' -Failure 'відсутній remote-файл: rename пропускається (RemoteAbsent), ключ видаляється, результат успішний'

        # Регресія польового дефекту DEV-LIMS E2E (2026-08-21): присвоєння
        # `$acceptList = if (...) {...} else { @($Accept) }` йде через
        # пайплайн і РОЗГОРТАЄ одноелементний масив у скаляр — .Count на
        # ньому падає під успадкованим StrictMode 2.0 (exit 90 після вже
        # виконаних remote/state-кроків). Обгортка @() довкола всього if
        # обов'язкова; гейт тримає саме цю форму в entrypoint.
        $mrReconcileEntrypointText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_BAZA_RECONCILE.ps1'), [Text.Encoding]::UTF8)
        Test-BRAVOCondition -Condition (
            $mrReconcileEntrypointText -match '\$acceptList\s*=\s*@\(if\s'
        ) -Name 'BazaSync/ReconcileAcceptListAssignmentStaysArrayWrapped' -Failure 'BRAVO_BAZA_RECONCILE: $acceptList має присвоюватися як @(if ...) — if-вираз без обгортки розгортає одноелементний масив у скаляр і .Count падає під StrictMode 2.0'
        } catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'BazaSync/ReconcileRenamesRemoteAndRemovesStateEntry' } }
        if (Enter-BRAVOSelfTestSection -Name 'BazaSync/SyncBazaUsesCanonicalEngine') { try {
        # =======================================================================
        # #292: -SyncBAZA (задача BAZASync, кожні 4 год) і Main ділять ОДИН
        # канонічний двигун. Раніше -SyncBAZA завжди йшов у legacy
        # Sync-FolderToSFTP (`synchronize remote -mirror`) повз
        # IncrementalAppendOnly/MutationPolicy: локально зіпсований файл
        # перезаписував перевірену remote-копію.
        # BEGIN SYNCBAZA-CANONICAL
        # =======================================================================
        & {
        $sbArchiveText = [IO.File]::ReadAllText((Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"), [Text.Encoding]::UTF8)
        $sbAst = [System.Management.Automation.Language.Parser]::ParseInput($sbArchiveText, [ref]$null, [ref]$null)
        $sbFunctionAsts = @{}
        foreach ($sbFn in @($sbAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
            if (-not $sbFunctionAsts.ContainsKey($sbFn.Name)) { $sbFunctionAsts[$sbFn.Name] = $sbFn }
        }

        # --- Структурні guard-и: один диспетчер, жодного обхідного шляху ------
        $sbCanonicalAst = $sbFunctionAsts['Invoke-BRAVOBazaCanonicalSync']
        $sbManualAst = $sbFunctionAsts['Invoke-ManualBAZASFTPSynchronization']
        $sbMainAst = $sbFunctionAsts['Main']
        $sbCommandsIn = {
            param($Ast, $CommandName)
            if ($null -eq $Ast) { return @() }
            return @($Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $CommandName
            }, $true))
        }
        Test-BRAVOCondition -Condition (
            $null -ne $sbCanonicalAst -and $null -ne $sbManualAst -and $null -ne $sbMainAst -and
            @(& $sbCommandsIn $sbManualAst 'Invoke-BRAVOBazaCanonicalSync').Count -ge 1 -and
            @(& $sbCommandsIn $sbMainAst 'Invoke-BRAVOBazaCanonicalSync').Count -ge 2
        ) -Name 'BazaSync/SyncBazaAndMainResolveToSameCanonicalDispatcher' `
          -Failure '-SyncBAZA (Invoke-ManualBAZASFTPSynchronization) і Main мають викликати ОДНУ функцію Invoke-BRAVOBazaCanonicalSync (Main — для BAZA_APP і BAZA_WWW) — інакше "Main = безпечний двигун, -SyncBAZA = legacy" знову можливе'

        $sbOutsideCanonical = {
            param($CommandName)
            return @(@(& $sbCommandsIn $sbAst $CommandName) | Where-Object {
                $p = $_.Parent
                while ($null -ne $p -and -not ($p -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $p.Name -eq 'Invoke-BRAVOBazaCanonicalSync')) { $p = $p.Parent }
                $null -eq $p
            })
        }
        $sbLegacyOutside = @(& $sbOutsideCanonical 'Sync-FolderToSFTP')
        $sbIncrementalOutside = @(& $sbOutsideCanonical 'Invoke-BRAVOBazaIncrementalSync')
        Test-BRAVOCondition -Condition (
            $sbLegacyOutside.Count -eq 0 -and $sbIncrementalOutside.Count -eq 0 -and
            @(& $sbCommandsIn $sbCanonicalAst 'Sync-FolderToSFTP').Count -eq 1 -and
            @(& $sbCommandsIn $sbCanonicalAst 'Invoke-BRAVOBazaIncrementalSync').Count -eq 1
        ) -Name 'BazaSync/NoProductionBazaSyncPathBypassesCanonicalDispatcher' `
          -Failure "Sync-FolderToSFTP та Invoke-BRAVOBazaIncrementalSync для BAZA мають викликатися ЛИШЕ з Invoke-BRAVOBazaCanonicalSync; поза ним: legacy=$($sbLegacyOutside.Count) incremental=$($sbIncrementalOutside.Count)"

        $sbCanonicalText = if ($null -ne $sbCanonicalAst) { $sbCanonicalAst.Extent.Text } else { '' }
        Test-BRAVOCondition -Condition (
            $sbCanonicalText.Contains("`$mode -eq 'IncrementalAppendOnly'") -and
            $sbCanonicalText.Contains("`$mode -eq 'Legacy'") -and
            $sbCanonicalText.Contains('невідомий backupMonitoring.SFTP.BAZA.Mode') -and
            $sbCanonicalText.Contains('Test-BRAVOBazaSyncStatusSuccess')
        ) -Name 'BazaSync/CanonicalDispatcherLegacyOnlyOnExplicitModeAndFailsClosed' `
          -Failure 'Invoke-BRAVOBazaCanonicalSync: legacy mirror лише за явного Mode=Legacy, невідомий Mode — fail-closed (не legacy), успіх incremental лише COMPLETE'

        Test-BRAVOCondition -Condition (
            $sbArchiveText.Contains('$script:processExitCode = Resolve-BRAVOSyncBazaExitCode -SyncSucceeded $manualSyncSuccess') -and
            $sbArchiveText.Contains('if (-not $SyncSucceeded) { return (Resolve-BRAVOExitCode -SftpFailed) }') -and
            $sbArchiveText.Contains('$manualSyncSuccess = [bool]$manualSyncResult.Success') -and
            $sbArchiveText.Contains('$script:archiveFinalOperationsEventContext = @{') -and
            $sbArchiveText.Contains('syncBaza = $true')
        ) -Name 'BazaSync/SyncBazaFailureMapsToSftpFailedExitAndOperationsEvent' `
          -Failure '-SyncBAZA: не-COMPLETE результат двигуна має давати exit SftpFailed (50) через $manualSyncResult.Success і нести статус двигуна у фінальній Operations-події'

        # #285: Invoke-BRAVOBazaCanonicalSync (справжня функція з Archive.Runtime,
        # AST) мусить вважати MUTATION_AUTO_ARCHIVED успіхом (INFO за контрактом,
        # OPERATIONS.md); COMPLETE -> успіх; реальні збої -> не успіх. Стаб лише
        # інкрементального двигуна (зовнішня межа) та логування/режиму.
        $sb285Module = New-Module -ScriptBlock {}
        try {
            $sb285Script = [scriptblock]::Create(@'
                $script:StubStatus = 'COMPLETE'
                function Write-BRAVOLog { param($Component, $Message, $Level, [switch]$NoTimestamp) }
                function Get-BRAVOBazaSyncModeEffective { return 'IncrementalAppendOnly' }
                function Invoke-BRAVOBazaIncrementalSync {
                    param($Component, $LocalDirectory, $RemoteDirectory, [switch]$ForceFullAudit)
                    return [pscustomobject]@{
                        Status = $script:StubStatus; Error = $null; Uploaded = 0; AlreadyVerified = 0; Failed = 0
                        IncompatibleFiles = @(); MutationViolations = @(); RemoteConflicts = @(); AuditDriftFiles = @()
                    }
                }
'@ + "`n" + $sbFunctionAsts['Invoke-BRAVOBazaCanonicalSync'].Extent.Text)
            . $sb285Module.NewBoundScriptBlock($sb285Script)
            $sb285Outcomes = @{}
            foreach ($sb285Status in @('COMPLETE', 'MUTATION_AUTO_ARCHIVED', 'MUTATION_VIOLATION', 'REMOTE_CONFLICT', 'INCOMPLETE')) {
                & $sb285Module { param($s) $script:StubStatus = $s } $sb285Status
                $sb285Outcomes[$sb285Status] = & $sb285Module { Invoke-BRAVOBazaCanonicalSync -Component 'BAZA_APP' -LocalDirectory 'C:\fake\local' -RemoteDirectory 'baza_app' }
            }
            Test-BRAVOCondition -Condition ($sb285Outcomes['COMPLETE'].Success -eq $true) `
                -Name 'BazaSync/CanonicalSyncCompleteIsSuccess' -Failure "Invoke-BRAVOBazaCanonicalSync: COMPLETE має бути Success=true; Success=$($sb285Outcomes['COMPLETE'].Success)"
            Test-BRAVOCondition -Condition (
                $sb285Outcomes['MUTATION_AUTO_ARCHIVED'].Success -eq $true -and $null -eq $sb285Outcomes['MUTATION_AUTO_ARCHIVED'].Error
            ) -Name 'BazaSync/CanonicalSyncMutationAutoArchivedIsSuccess' -Failure "Invoke-BRAVOBazaCanonicalSync: MUTATION_AUTO_ARCHIVED (INFO за контрактом) має бути Success=true, інакше exit 50 на кожен цикл; Success=$($sb285Outcomes['MUTATION_AUTO_ARCHIVED'].Success)"
            Test-BRAVOCondition -Condition (
                $sb285Outcomes['MUTATION_VIOLATION'].Success -eq $false -and $sb285Outcomes['REMOTE_CONFLICT'].Success -eq $false -and
                $sb285Outcomes['INCOMPLETE'].Success -eq $false
            ) -Name 'BazaSync/CanonicalSyncFailureStatusesAreNotSuccess' -Failure 'Invoke-BRAVOBazaCanonicalSync: MUTATION_VIOLATION/REMOTE_CONFLICT/INCOMPLETE мають лишатись Success=false'
        } finally { Remove-Module -ModuleInfo $sb285Module -Force -ErrorAction SilentlyContinue }
        Test-BRAVOCondition -Condition (
            (Test-BRAVOBazaSyncStatusSuccess -Status 'COMPLETE') -and (Test-BRAVOBazaSyncStatusSuccess -Status 'MUTATION_AUTO_ARCHIVED') -and
            -not (Test-BRAVOBazaSyncStatusSuccess -Status 'REMOTE_CONFLICT') -and -not (Test-BRAVOBazaSyncStatusSuccess -Status 'ERROR') -and
            -not (Test-BRAVOBazaSyncStatusSuccess -Status '') -and -not (Test-BRAVOBazaSyncStatusSuccess -Status 'SOMETHING_NEW')
        ) -Name 'BazaSync/StatusSuccessHelperWhitelistsCompleteAndAutoArchivedOnly' -Failure 'Test-BRAVOBazaSyncStatusSuccess: успіх лише COMPLETE і MUTATION_AUTO_ARCHIVED; решта/порожнє/незнайоме — ні'

        # --- Поведінкова матриця ЧЕРЕЗ вхідну функцію -SyncBAZA ---------------
        $sbNeededFunctions = @(
            'Invoke-BRAVOBazaCanonicalSync', 'Invoke-BRAVOBazaIncrementalSync',
            'Invoke-ManualBAZASFTPSynchronization', 'New-BRAVOTransferOperationResult',
            'Get-BRAVOManualSyncRunOutcomeLabel'
        )
        $sbDefinitions = (@($sbNeededFunctions | ForEach-Object { $sbFunctionAsts[$_].Extent.Text }) -join "`n`n")
        $sbSavedBackupMonitoring = $null
        $sbHadBackupMonitoring = Test-Path -LiteralPath 'Variable:global:backupMonitoring'
        if ($sbHadBackupMonitoring) { $sbSavedBackupMonitoring = $global:backupMonitoring }
        $sbSavedStateRoot = $null
        $sbHadStateRoot = Test-Path -LiteralPath 'Variable:global:stateRoot'
        if ($sbHadStateRoot) { $sbSavedStateRoot = $global:stateRoot }
        $sbModule = New-Module -ScriptBlock {}
        try {
            # Dot-source у scope модуля: визначення функцій/змінних мають пережити виклик.
            $sbDefinitionScript = [scriptblock]::Create(@'
                $script:LegacyMirrorCalls = 0
                $script:EngineSessionCalls = 0
                $script:EngineSession = $null
                $script:AuditProvider = $null
                $script:Messages = New-Object System.Collections.Generic.List[string]
                $sftpUrl = 'sftp://192.0.2.10'
                $sftpHostKey = 'ssh-ed25519 256 fake'
                $winSCPPath = 'C:\fake\Tools\WinSCP.com'
                $winSCPAssemblyPath = 'C:\fake\Tools\WinSCPnet.dll'
                $sftpConnectionTimeoutSeconds = 30
                $componentSettings = @{ Synchronization = @{ BAZA_APP_SFTP = $true; BAZA_WWW_SFTP = $false } }
                $bazaAppPaths = @{ Source = '' }
                $bazaWWWPaths = @{ Source = '' }
                $bazaWWWDetection = @{ Success = $false; Reason = 'не використовується' }
                $sftpDirectories = @{ BAZA = 'baza_app'; BAZAWWW = 'baza_www' }
                function Write-BRAVOLog { param($Component, $Message, $Level, [switch]$NoTimestamp) [void]$script:Messages.Add([string]$Message) }
                function Show-ScriptProgress { param($Status, $PercentComplete, [switch]$Completed) }
                function Test-PathWithLog { param($Path, $Description, $CreateIfMissing) return (Test-Path -LiteralPath $Path) }
                function Test-SFTPConfig { param([switch]$SynchronizationOnly, [switch]$BAZAOnly, [string[]]$NotInstalledComponents) return $true }
                function Test-SFTPConnection { param($WinSCPPath, $RepositorySFTPUrl, $HostKey) return $true }
                function Initialize-BRAVOSFTPRemoteDirectories { param($WinSCPPath, $RepositorySFTPUrl, $HostKey, $RemoteDirectories) }
                function Get-BRAVOWinSCPDotNetComponents { param($WinSCPAssemblyPath, $WinSCPPath) return [pscustomobject]@{ AssemblyPath = 'C:\fake\WinSCPnet.dll'; ExecutablePath = 'C:\fake\winscp.exe' } }
                function New-BRAVOBazaArchiveFullAuditProvider { param($LocalDirectory, $RemotePath, $RepositorySFTPUrl, $HostKey) return $script:AuditProvider }
                # Legacy `synchronize remote -mirror -criteria=time,size`: remote
                # приводиться до local (перезапис за розміром), без MutationPolicy.
                function Sync-FolderToSFTP {
                    param($WinSCPPath, $RepositorySFTPUrl, $HostKey, $LocalDirectory, $RemoteDirectory, $ComponentName)
                    $script:LegacyMirrorCalls++
                    foreach ($f in @(Get-ChildItem -LiteralPath $LocalDirectory -File)) {
                        $script:EngineSession.State.RemoteSizes["/$($RemoteDirectory.Trim('/'))/$($f.Name)"] = [int64]$f.Length
                    }
                    $script:lastBAZASyncOutcome = $null
                    return $true
                }
                # Справжній двигун + machine-wide lock; лише WinSCP-сесія замінена фейком.
                function Invoke-BRAVOBazaComponentSyncSession {
                    param($Component, $LocalDirectory, $RemoteRootPath, $RepositorySFTPUrl, $HostKey, $WinSCPAssemblyPath, $WinSCPExecutablePath, $StateRoot,
                        $ConnectionTimeoutSeconds, $OperationTimeoutSeconds, $MutationPolicy, $AutoArchiveMutationThreshold,
                        [switch]$BootstrapIfNeeded, $FullAuditProvider, $FullAuditEveryDays, [switch]$ForceFullAudit, [switch]$WriteCheckpoint)
                    $script:EngineSessionCalls++
                    if ($script:ForceSkippedConcurrent) {
                        $sk = New-BRAVOBazaSyncResult -Component $Component -CycleId (New-BRAVOBazaCycleId) -StartedUtc (Get-Date).ToUniversalTime() -CutoffUtc (Get-Date).ToUniversalTime()
                        $sk.Status = 'SKIPPED_CONCURRENT'
                        return $sk
                    }
                    $cycleId = New-BRAVOBazaCycleId
                    $startedUtc = (Get-Date).ToUniversalTime()
                    $lock = Enter-BRAVOBazaSyncLock -StateRoot $StateRoot -Component $Component
                    if (-not $lock.Success) {
                        $r = New-BRAVOBazaSyncResult -Component $Component -CycleId $cycleId -StartedUtc $startedUtc -CutoffUtc $startedUtc
                        $r.Status = if ($lock.Classification -eq 'Busy') { 'SKIPPED_CONCURRENT' } else { 'ERROR' }
                        $r.Error = [string]$lock.Error
                        return $r
                    }
                    try {
                        return Invoke-BRAVOBazaSynchronization -Component $Component -LocalDirectory $LocalDirectory -RemoteRootPath $RemoteRootPath `
                            -Session $script:EngineSession -StateRoot $StateRoot -MutationPolicy $MutationPolicy `
                            -AutoArchiveMutationThreshold $AutoArchiveMutationThreshold -BootstrapIfNeeded:$BootstrapIfNeeded `
                            -FullAuditProvider $FullAuditProvider -FullAuditEveryDays $FullAuditEveryDays -ForceFullAudit:$ForceFullAudit
                    } finally { $lock.Stream.Dispose() }
                }
'@ + "`n" + $sbDefinitions)
            . $sbModule.NewBoundScriptBlock($sbDefinitionScript)

            $sbRun = {
                param($Module, $Local, $State, $Session, $Mode = 'IncrementalAppendOnly', [int]$Threshold = 0, $AuditProvider = $null)
                $global:stateRoot = $State
                $global:backupMonitoring = @{
                    SFTP = @{
                        SynchronizationTimeoutSeconds = 60; OperationTimeoutSeconds = 60
                        BAZA = @{ Mode = $Mode; MutationPolicy = 'Fail'; StateRoot = $State; FullAuditEnabled = $true; FullAuditEveryDays = 7; AutoArchiveMutationThreshold = $Threshold }
                    }
                }
                $noOp = {
                    param($Snapshot)
                    return [pscustomobject]@{ Success = $true; Error = $null; AlreadyMatchingRelativePaths = @(); LocalSizes = @{}; LastWriteTimesUtc = @{} }
                }
                $provider = if ($null -ne $AuditProvider) { $AuditProvider } else { $noOp }
                & $Module {
                    param($L, $S, $P)
                    $script:bazaAppPaths = @{ Source = $L }
                    $script:EngineSession = $S
                    $script:AuditProvider = $P
                    $script:LegacyMirrorCalls = 0
                    $script:EngineSessionCalls = 0
                } $Local $Session $provider
                $result = & $Module { Invoke-ManualBAZASFTPSynchronization }
                $calls = & $Module { [pscustomobject]@{ Legacy = $script:LegacyMirrorCalls; Engine = $script:EngineSessionCalls } }
                return [pscustomobject]@{ Result = $result; LegacyCalls = $calls.Legacy; EngineCalls = $calls.Engine }
            }
            $sbNewCase = {
                param($Name)
                $caseRoot = Join-Path $bazaSyncTestRoot "SB_$Name"
                $caseLocal = Join-Path $caseRoot 'local'
                New-Item -ItemType Directory -Path $caseLocal -Force | Out-Null
                return [pscustomobject]@{ Local = $caseLocal; State = (Join-Path $caseRoot 'state') }
            }

            # 1. Новий файл + стан incremental-двигуна оновлюється через -SyncBAZA
            $sbCase1 = & $sbNewCase 'New'
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase1.Local -RelativePath 'a.txt' -SizeBytes 100)
            $sbSession1 = New-BRAVOSelfTestFakeBazaSession
            $sbRun1 = & $sbRun $sbModule $sbCase1.Local $sbCase1.State $sbSession1
            $sbStatePath1 = Get-BRAVOBazaStatePath -StateRoot $sbCase1.State -Component 'BAZA_APP'
            $sbState1 = Read-BRAVOBazaState -Path $sbStatePath1
            Test-BRAVOCondition -Condition (
                $sbRun1.Result.Success -eq $true -and $sbRun1.Result.Results.SyncOutcomes['BAZA_APP'].Status -eq 'COMPLETE' -and
                $sbRun1.Result.Results.SyncOutcomes['BAZA_APP'].Mode -eq 'IncrementalAppendOnly' -and
                $sbRun1.LegacyCalls -eq 0 -and $sbRun1.EngineCalls -eq 1 -and
                [int64]$sbSession1.State.RemoteSizes['/baza_app/a.txt'] -eq 100 -and
                $sbState1.Exists -and $sbState1.State.Files.ContainsKey('a.txt') -and [bool]$sbState1.State.Files['a.txt'].Verified -and
                -not [string]::IsNullOrWhiteSpace([string]$sbState1.State.LastSuccessfulSyncUtc)
            ) -Name 'BazaSync/SyncBazaNewRemoteFileUploadedViaIncrementalEngineAndStateUpdated' `
              -Failure "-SyncBAZA має передати новий файл через incremental-двигун (не legacy) і оновити incremental-стан; Success=$($sbRun1.Result.Success) Legacy=$($sbRun1.LegacyCalls) Engine=$($sbRun1.EngineCalls)"

            # 2. Без змін: нуль передач, успіх
            $sbSession2 = New-BRAVOSelfTestFakeBazaSession -SeedRemoteState $sbSession1.State
            $sbRun2 = & $sbRun $sbModule $sbCase1.Local $sbCase1.State $sbSession2
            Test-BRAVOCondition -Condition (
                $sbRun2.Result.Success -eq $true -and $sbSession2.State.PutFilesCallCount -eq 0 -and $sbRun2.LegacyCalls -eq 0
            ) -Name 'BazaSync/SyncBazaUnchangedFileMakesNoTransfer' -Failure "-SyncBAZA без змін: нуль PutFiles, успіх; PutFiles=$($sbSession2.State.PutFilesCallCount) Status=$($sbRun2.Result.Results.SyncOutcomes['BAZA_APP'].Status) Error=$($sbRun2.Result.Results.BAZA_APP.Error)"

            # 3. Локально змінений вже підтверджений файл: MUTATION_VIOLATION =
            #    ПОМИЛКА, remote-копія НЕ перезаписана, стан не просунуто.
            $sbProvenance = {
                param($Path)
                $r = Read-BRAVOBazaState -Path $Path
                if ($r.Exists -and -not $r.Corrupt) { return [string]$r.State.LastSuccessfulSyncUtc }
                return ''
            }
            $sbProvenanceBefore = & $sbProvenance $sbStatePath1
            [IO.File]::WriteAllBytes((Join-Path $sbCase1.Local 'a.txt'), (New-Object byte[] 999))
            $sbSession3 = New-BRAVOSelfTestFakeBazaSession -SeedRemoteState $sbSession1.State
            $sbRun3 = & $sbRun $sbModule $sbCase1.Local $sbCase1.State $sbSession3
            Test-BRAVOCondition -Condition (
                $sbRun3.Result.Success -eq $false -and
                $sbRun3.Result.Results.SyncOutcomes['BAZA_APP'].Status -eq 'MUTATION_VIOLATION' -and
                $sbRun3.Result.Results.BAZA_APP.Success -eq $false -and
                [string]$sbRun3.Result.Results.BAZA_APP.Error -match 'a\.txt' -and
                [int64]$sbSession3.State.RemoteSizes['/baza_app/a.txt'] -eq 100 -and
                $sbSession3.State.PutFilesCallCount -eq 0 -and $sbRun3.LegacyCalls -eq 0 -and
                (& $sbProvenance $sbStatePath1) -eq $sbProvenanceBefore
            ) -Name 'BazaSync/SyncBazaMutationViolationFailsAndRemoteGoodCopyNotOverwritten' `
              -Failure "-SyncBAZA: локально змінений підтверджений файл має дати MUTATION_VIOLATION=ПОМИЛКА, remote лишається 100 байт, нуль PutFiles/legacy, provenance не просунуто; Success=$($sbRun3.Result.Success) Status=$($sbRun3.Result.Results.SyncOutcomes['BAZA_APP'].Status) Remote=$($sbSession3.State.RemoteSizes['/baza_app/a.txt']) Legacy=$($sbRun3.LegacyCalls)"

            # 4. Remote змінено поза BRAVO при незмінному local: -SyncBAZA не
            #    перезаписує (append-only), remote лишається як є.
            $sbSession4 = New-BRAVOSelfTestFakeBazaSession -SeedRemoteState $sbSession1.State
            [IO.File]::WriteAllBytes((Join-Path $sbCase1.Local 'a.txt'), (New-Object byte[] 100))
            $sbSession4.State.RemoteSizes['/baza_app/a.txt'] = [int64]7
            $sbRun4 = & $sbRun $sbModule $sbCase1.Local $sbCase1.State $sbSession4
            Test-BRAVOCondition -Condition (
                $sbSession4.State.PutFilesCallCount -eq 0 -and [int64]$sbSession4.State.RemoteSizes['/baza_app/a.txt'] -eq 7 -and $sbRun4.LegacyCalls -eq 0
            ) -Name 'BazaSync/SyncBazaRemoteChangedFileIsNeverBlindlyMirrored' `
              -Failure "-SyncBAZA не має 'вирівнювати' змінений на remote файл перезаписом (legacy mirror); PutFiles=$($sbSession4.State.PutFilesCallCount) Remote=$($sbSession4.State.RemoteSizes['/baza_app/a.txt'])"

            # 5. Same-name конфлікт: новий local-файл, remote-ім'я зайняте іншим розміром
            $sbCase5 = & $sbNewCase 'Conflict'
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase5.Local -RelativePath 'base.txt' -SizeBytes 40)
            [void](& $sbRun $sbModule $sbCase5.Local $sbCase5.State (New-BRAVOSelfTestFakeBazaSession))
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase5.Local -RelativePath 'b.txt' -SizeBytes 100)
            $sbSession5 = New-BRAVOSelfTestFakeBazaSession
            $sbSession5.State.RemoteSizes['/baza_app/b.txt'] = [int64]55
            $sbRun5 = & $sbRun $sbModule $sbCase5.Local $sbCase5.State $sbSession5
            Test-BRAVOCondition -Condition (
                $sbRun5.Result.Success -eq $false -and
                $sbRun5.Result.Results.SyncOutcomes['BAZA_APP'].Status -eq 'REMOTE_CONFLICT' -and
                [int64]$sbSession5.State.RemoteSizes['/baza_app/b.txt'] -eq 55 -and
                $sbSession5.State.PutFilesCallCount -eq 0 -and $sbRun5.LegacyCalls -eq 0
            ) -Name 'BazaSync/SyncBazaRemoteConflictFailsWithoutOverwrite' `
              -Failure "-SyncBAZA: same-name конфлікт має дати REMOTE_CONFLICT=ПОМИЛКА без перезапису; Status=$($sbRun5.Result.Results.SyncOutcomes['BAZA_APP'].Status) Error=$($sbRun5.Result.Results.BAZA_APP.Error) Remote=$($sbSession5.State.RemoteSizes['/baza_app/b.txt'])"

            # 6. Несумісне ім'я: сумісні файли передано, цикл — ПОМИЛКА
            $sbCase6 = & $sbNewCase 'Incompatible'
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase6.Local -RelativePath 'seed.txt' -SizeBytes 10)
            [void](& $sbRun $sbModule $sbCase6.Local $sbCase6.State (New-BRAVOSelfTestFakeBazaSession))
            $sbLongName = ('a' * 250) + '.txt'
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase6.Local -RelativePath $sbLongName -SizeBytes 20)
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase6.Local -RelativePath 'ok_new.txt' -SizeBytes 30)
            $sbSession6 = New-BRAVOSelfTestFakeBazaSession
            $sbRun6 = & $sbRun $sbModule $sbCase6.Local $sbCase6.State $sbSession6
            Test-BRAVOCondition -Condition (
                $sbRun6.Result.Success -eq $false -and
                $sbRun6.Result.Results.SyncOutcomes['BAZA_APP'].Status -eq 'INCOMPATIBLE_NAME' -and
                [int]$sbRun6.Result.Results.BAZA_APP.IncompatibleNames -eq 1 -and
                [int64]$sbSession6.State.RemoteSizes['/baza_app/ok_new.txt'] -eq 30 -and
                -not $sbSession6.State.RemoteSizes.ContainsKey("/baza_app/$sbLongName") -and $sbRun6.LegacyCalls -eq 0
            ) -Name 'BazaSync/SyncBazaIncompatibleNameFailsButCompatibleFilesTransferred' `
              -Failure "-SyncBAZA: несумісне ім'я -> INCOMPATIBLE_NAME=ПОМИЛКА, сумісні файли передано; Status=$($sbRun6.Result.Results.SyncOutcomes['BAZA_APP'].Status)"

            # 7. AUDIT_DRIFT
            $sbCase7 = & $sbNewCase 'AuditDrift'
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase7.Local -RelativePath 'drifted.txt' -SizeBytes 100)
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase7.Local -RelativePath 'other.txt' -SizeBytes 60)
            $sbDriftLocal = $sbCase7.Local
            $sbDriftProvider = {
                param($Snapshot)
                $pending = [pscustomobject]@{ IsDirectory = $false; Path = (Join-Path $sbDriftLocal 'drifted.txt'); Action = 'UploadUpdate'; Reason = 'розбіжність часу (той самий розмір)' }
                return ConvertTo-BRAVOBazaFullAuditResult -ComparisonSuccess $true -ComparisonError $null -PendingFiles @($pending) -LocalDirectory $sbDriftLocal -LocalSnapshot $Snapshot
            }.GetNewClosure()
            $sbSession7 = New-BRAVOSelfTestFakeBazaSession
            $sbSession7.State.RemoteSizes['/baza_app/drifted.txt'] = [int64]100
            $sbRun7 = & $sbRun $sbModule $sbCase7.Local $sbCase7.State $sbSession7 'IncrementalAppendOnly' 0 $sbDriftProvider
            Test-BRAVOCondition -Condition (
                $sbRun7.Result.Success -eq $false -and
                $sbRun7.Result.Results.SyncOutcomes['BAZA_APP'].Status -eq 'AUDIT_DRIFT' -and
                $sbSession7.State.PutFilesCallCount -eq 0 -and $sbRun7.LegacyCalls -eq 0
            ) -Name 'BazaSync/SyncBazaAuditDriftFailsWithoutOverwrite' `
              -Failure "-SyncBAZA: Full Audit drift має дати AUDIT_DRIFT=ПОМИЛКА без перезапису; Status=$($sbRun7.Result.Results.SyncOutcomes['BAZA_APP'].Status) PutFiles=$($sbSession7.State.PutFilesCallCount)"

            # 8. MUTATION_AUTO_ARCHIVED (поріг > 0): rename-preserve, нова версія — наступним циклом
            $sbCase8 = & $sbNewCase 'AutoArchive'
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase8.Local -RelativePath 'a.txt' -SizeBytes 100)
            $sbSession8 = New-BRAVOSelfTestFakeBazaSession
            [void](& $sbRun $sbModule $sbCase8.Local $sbCase8.State $sbSession8 'IncrementalAppendOnly' 1)
            [IO.File]::WriteAllBytes((Join-Path $sbCase8.Local 'a.txt'), (New-Object byte[] 150))
            $sbRun8 = & $sbRun $sbModule $sbCase8.Local $sbCase8.State $sbSession8 'IncrementalAppendOnly' 1
            $sbRenamed8 = @($sbSession8.State.MoveFileCalls | Where-Object { $_ -match '/baza_app/a\.txt -> /baza_app/a\.txt\.replaced_' })
            $sbRun8b = & $sbRun $sbModule $sbCase8.Local $sbCase8.State $sbSession8 'IncrementalAppendOnly' 1
            Test-BRAVOCondition -Condition (
                $sbRun8.Result.Results.SyncOutcomes['BAZA_APP'].Status -eq 'MUTATION_AUTO_ARCHIVED' -and
                $sbRenamed8.Count -eq 1 -and $sbRun8.LegacyCalls -eq 0 -and
                $sbRun8b.Result.Success -eq $true -and [int64]$sbSession8.State.RemoteSizes['/baza_app/a.txt'] -eq 150 -and
                @($sbSession8.State.RemoteSizes.Keys | Where-Object { $_ -match '^/baza_app/a\.txt\.replaced_' }).Count -eq 1
            ) -Name 'BazaSync/SyncBazaMutationAutoArchivedPreservesOldRemoteThenUploadsNewVersion' `
              -Failure "-SyncBAZA з AutoArchiveMutationThreshold: стара remote-версія зберігається (rename *.replaced_*), нова заливається НАСТУПНИМ циклом; Status=$($sbRun8.Result.Results.SyncOutcomes['BAZA_APP'].Status) Renames=$($sbRenamed8.Count) Next=$($sbRun8b.Result.Success)"

            # 9. За явного Mode=Legacy той самий сценарій (локально змінений файл)
            #    ПЕРЕЗАПИСУЄ remote — поведінка, яку до #292 мав кожен -SyncBAZA.
            #    Тест фіксує, що legacy лишився лише за явним вибором.
            $sbCase9 = & $sbNewCase 'LegacyExplicit'
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase9.Local -RelativePath 'a.txt' -SizeBytes 100)
            $sbSession9 = New-BRAVOSelfTestFakeBazaSession
            $sbSession9.State.RemoteSizes['/baza_app/a.txt'] = [int64]100
            [IO.File]::WriteAllBytes((Join-Path $sbCase9.Local 'a.txt'), (New-Object byte[] 999))
            $sbRun9 = & $sbRun $sbModule $sbCase9.Local $sbCase9.State $sbSession9 'Legacy'
            Test-BRAVOCondition -Condition (
                $sbRun9.LegacyCalls -eq 1 -and $sbRun9.EngineCalls -eq 0 -and
                [int64]$sbSession9.State.RemoteSizes['/baza_app/a.txt'] -eq 999 -and
                $sbRun9.Result.Results.SyncOutcomes['BAZA_APP'].Mode -eq 'Legacy'
            ) -Name 'BazaSync/SyncBazaLegacyMirrorOnlyWhenModeExplicitlyLegacy' `
              -Failure "legacy mirror (перезапис remote) допустимий лише за явного BAZA.Mode=Legacy; Legacy=$($sbRun9.LegacyCalls) Engine=$($sbRun9.EngineCalls)"

            # 9b. Контр-доказ: той самий сценарій у типовому режимі — remote ЦІЛИЙ
            $sbCase9b = & $sbNewCase 'LegacyContrast'
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase9b.Local -RelativePath 'a.txt' -SizeBytes 100)
            $sbSession9b = New-BRAVOSelfTestFakeBazaSession
            [void](& $sbRun $sbModule $sbCase9b.Local $sbCase9b.State $sbSession9b)
            [IO.File]::WriteAllBytes((Join-Path $sbCase9b.Local 'a.txt'), (New-Object byte[] 999))
            $sbRun9b = & $sbRun $sbModule $sbCase9b.Local $sbCase9b.State $sbSession9b
            Test-BRAVOCondition -Condition (
                $sbRun9b.LegacyCalls -eq 0 -and [int64]$sbSession9b.State.RemoteSizes['/baza_app/a.txt'] -eq 100 -and $sbRun9b.Result.Success -eq $false
            ) -Name 'BazaSync/SyncBazaDefaultModeKeepsGoodRemoteCopyUnlikeLegacyMirror' `
              -Failure "у типовому режимі той самий сценарій не має перезаписати remote (100 байт); Remote=$($sbSession9b.State.RemoteSizes['/baza_app/a.txt'])"

            # 10. Невідомий Mode: fail-closed, не деградує до legacy mirror
            $sbCase10 = & $sbNewCase 'UnknownMode'
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase10.Local -RelativePath 'a.txt' -SizeBytes 100)
            $sbSession10 = New-BRAVOSelfTestFakeBazaSession
            $sbRun10 = & $sbRun $sbModule $sbCase10.Local $sbCase10.State $sbSession10 'IncrementalAppendOnlyTypo'
            Test-BRAVOCondition -Condition (
                $sbRun10.Result.Success -eq $false -and $sbRun10.LegacyCalls -eq 0 -and $sbRun10.EngineCalls -eq 0 -and
                $sbSession10.State.PutFilesCallCount -eq 0 -and [string]$sbRun10.Result.Results.BAZA_APP.Error -match 'невідомий'
            ) -Name 'BazaSync/SyncBazaUnknownModeFailsClosedInsteadOfLegacyMirror' `
              -Failure "-SyncBAZA з невідомим Mode має завершитися помилкою, а не мовчки піти в legacy mirror; Legacy=$($sbRun10.LegacyCalls)"

            # 11. Спільний machine-wide lock компонента: зайнятий -> нічого не передано, ПОМИЛКА
            $sbCase11 = & $sbNewCase 'Lock'
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase11.Local -RelativePath 'a.txt' -SizeBytes 100)
            $sbHeldLock = Enter-BRAVOBazaSyncLock -StateRoot $sbCase11.State -Component 'BAZA_APP'
            $sbSession11 = New-BRAVOSelfTestFakeBazaSession
            try {
                $sbRun11 = & $sbRun $sbModule $sbCase11.Local $sbCase11.State $sbSession11
            } finally {
                if ($null -ne $sbHeldLock.Stream) { $sbHeldLock.Stream.Dispose() }
            }
            Test-BRAVOCondition -Condition (
                $sbHeldLock.Success -eq $true -and
                $sbRun11.Result.Results.SyncOutcomes['BAZA_APP'].Status -match '^(SKIPPED_CONCURRENT|ERROR)$' -and
                $sbSession11.State.PutFilesCallCount -eq 0 -and $sbRun11.LegacyCalls -eq 0
            ) -Name 'BazaSync/SyncBazaRespectsSharedComponentSyncLock' `
              -Failure "-SyncBAZA має брати той самий lock компонента, що Main/Health: при зайнятому lock нічого не передається; Status=$($sbRun11.Result.Results.SyncOutcomes['BAZA_APP'].Status)"

            # 11b. SKIPPED_CONCURRENT (Health тримає lock) — НЕ збій -SyncBAZA (INFO, exit 0), нічого не передано
            $sbCase11b = & $sbNewCase 'SkippedConcurrent'
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase11b.Local -RelativePath 'a.txt' -SizeBytes 100)
            $sbSession11b = New-BRAVOSelfTestFakeBazaSession
            & $sbModule { $script:ForceSkippedConcurrent = $true }
            try { $sbRun11b = & $sbRun $sbModule $sbCase11b.Local $sbCase11b.State $sbSession11b } finally { & $sbModule { $script:ForceSkippedConcurrent = $false } }
            Test-BRAVOCondition -Condition (
                $sbRun11b.Result.Success -eq $true -and
                $sbRun11b.Result.Results.SyncOutcomes['BAZA_APP'].Status -eq 'SKIPPED_CONCURRENT' -and
                $sbRun11b.Result.Results.SyncOutcomes['BAZA_APP'].Success -eq $false -and
                $sbRun11b.Result.Results.BAZA_APP.Success -eq $true -and
                $sbSession11b.State.PutFilesCallCount -eq 0 -and $sbRun11b.LegacyCalls -eq 0
            ) -Name 'BazaSync/SyncBazaSkippedConcurrentIsInfoNotFailure' `
              -Failure "SKIPPED_CONCURRENT у -SyncBAZA (lock тримає Health) не має давати exit 50; Success=$($sbRun11b.Result.Success)"

            # 11c. Пропуск — не "УСПІШНО": підсумок запуску й Operations-подія кажуть ПРОПУЩЕНО
            $sbLabel = { param($R) & $sbModule { param($X) Get-BRAVOManualSyncRunOutcomeLabel -ManualSyncResult $X } $R }
            $sbLabel11b = & $sbLabel $sbRun11b.Result
            $sbLabel1 = & $sbLabel $sbRun1.Result
            $sbLabelFailedAndSkipped = & $sbLabel ([pscustomobject]@{ Success = $false; Skipped = $true; Results = $null })
            $sbLabelLegacyShape = & $sbLabel ([pscustomobject]@{ Success = $true; Results = $null })
            Test-BRAVOCondition -Condition (
                $sbRun11b.Result.Skipped -eq $true -and $sbLabel11b -like 'ПРОПУЩЕНО*' -and
                $sbRun1.Result.Skipped -eq $false -and $sbLabel1 -eq 'УСПІШНО' -and
                $sbLabelFailedAndSkipped -eq 'ПОМИЛКА' -and $sbLabelLegacyShape -eq 'УСПІШНО' -and
                $sbArchiveText.Contains('runOutcome = $manualSyncOutcomeLabel') -and
                $sbArchiveText.Contains('Синхронізація BAZA (-SyncBAZA): $manualSyncOutcomeLabel')
            ) -Name 'BazaSync/SyncBazaSkippedConcurrentRunOutcomeIsSkippedNotSuccess' `
              -Failure "SKIPPED_CONCURRENT у -SyncBAZA: exit 0, але runOutcome має бути ПРОПУЩЕНО, не УСПІШНО; skipped='$sbLabel11b' success='$sbLabel1' failed+skipped='$sbLabelFailedAndSkipped'"

            # 12. Mode присутній, але порожній/пробільний -> типовий IncrementalAppendOnly (не fail-closed)
            $sbCase12 = & $sbNewCase 'EmptyMode'
            [void](New-BRAVOSelfTestBazaFile -Directory $sbCase12.Local -RelativePath 'a.txt' -SizeBytes 100)
            $sbSession12 = New-BRAVOSelfTestFakeBazaSession
            $sbRun12 = & $sbRun $sbModule $sbCase12.Local $sbCase12.State $sbSession12 '  '
            Test-BRAVOCondition -Condition (
                $sbRun12.Result.Success -eq $true -and $sbRun12.EngineCalls -eq 1 -and $sbRun12.LegacyCalls -eq 0 -and
                $sbRun12.Result.Results.SyncOutcomes['BAZA_APP'].Mode -eq 'IncrementalAppendOnly'
            ) -Name 'BazaSync/SyncBazaEmptyModeTreatedAsDefaultIncremental' `
              -Failure "порожній/пробільний BAZA.Mode має означати типовий IncrementalAppendOnly; Mode=$($sbRun12.Result.Results.SyncOutcomes['BAZA_APP'].Mode) Error=$($sbRun12.Result.Results.BAZA_APP.Error)"
        } finally {
            Remove-Module -ModuleInfo $sbModule -ErrorAction SilentlyContinue
            if ($sbHadBackupMonitoring) { $global:backupMonitoring = $sbSavedBackupMonitoring } else { Remove-Variable -Name backupMonitoring -Scope Global -ErrorAction SilentlyContinue }
            if ($sbHadStateRoot) { $global:stateRoot = $sbSavedStateRoot } else { Remove-Variable -Name stateRoot -Scope Global -ErrorAction SilentlyContinue }
        }
        }
        # END SYNCBAZA-CANONICAL
        } catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'BazaSync/SyncBazaUsesCanonicalEngine' } }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace([string]$bazaSyncTestRoot) -and (Test-Path -LiteralPath $bazaSyncTestRoot)) {
            Remove-Item -LiteralPath $bazaSyncTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
