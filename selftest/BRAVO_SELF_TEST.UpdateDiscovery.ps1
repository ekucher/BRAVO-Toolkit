# Домен-фрагмент self-test: UpdateDiscovery (INS-020, read-only discovery
# встановлення BRAVO.Update, CONTRACTS §3). Усі сценарії працюють на
# sandbox-коренях у тимчасовому каталозі; production-шляхи
# (ProgramData\BRAVO, Program Files\BRAVO-Toolkit) не чіпаються. Read-only
# доводиться знімком SHA-256/розмірів/часу всіх файлів фікстури до і після.
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 -- НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition.

& {
    Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking -ErrorAction Stop
    $updateModule = Get-Module -Name 'BRAVO.Update'

    $discoveryTempPrefix = Join-Path ([IO.Path]::GetTempPath()) 'BRAVO_UPDDISC_'
    $discoveryBase = $discoveryTempPrefix + [guid]::NewGuid().ToString('N')

    # Знімок усіх файлів і каталогів: відносний шлях, SHA-256, розмір, час запису.
    function Get-DiscoverySnapshot {
        param([string]$Path)
        $lines = New-Object System.Collections.ArrayList
        foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object -Property FullName)) {
            $relative = $item.FullName.Substring($Path.Length)
            if ($item.PSIsContainer) {
                [void]$lines.Add("D|$relative")
            } else {
                $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
                [void]$lines.Add("F|$relative|$hash|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)")
            }
        }
        return ($lines.ToArray() -join "`n")
    }

    # Фікстура root: VERSION.json + RUNTIME_MANIFEST.json із реальними SHA-256.
    function New-DiscoveryRoot {
        param([string]$Path, [string]$Channel = 'stable', [string]$Version = '5.3.0', [switch]$NoManifest, [switch]$NoVersion)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        $scriptPath = Join-Path $Path 'BRAVO_FIXTURE.ps1'
        [IO.File]::WriteAllText($scriptPath, "# fixture`r`n", (New-Object Text.UTF8Encoding $true))
        if (-not $NoVersion) {
            $versionJson = '{"product":"BRAVO-Toolkit","packageVersion":"' + $Version + '","releaseChannel":"' + $Channel + '","buildId":"abc1234","sourceCommit":"abc1234abc1234abc1234abc1234abc1234abcd","releaseDate":"2026-10-01"}'
            [IO.File]::WriteAllText((Join-Path $Path 'VERSION.json'), $versionJson, (New-Object Text.UTF8Encoding $false))
        }
        if (-not $NoManifest) {
            $hash = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash
            $manifest = '{"files":{"BRAVO_FIXTURE.ps1":"' + $hash + '"}}'
            [IO.File]::WriteAllText((Join-Path $Path 'RUNTIME_MANIFEST.json'), $manifest, (New-Object Text.UTF8Encoding $false))
        }
    }

    function Invoke-DiscoveryState {
        param([hashtable]$Parameters)
        return (& $updateModule { param($p) Get-BRAVOInstallationState @p } $Parameters)
    }

    function Get-DiscoveryParameters {
        param([string]$Name)
        $stateRoot = Join-Path $discoveryBase "$Name-state"
        $lockRoot = Join-Path $discoveryBase "$Name-locks"
        return @{
            StateRoot         = $stateRoot
            VersionStatePath  = Join-Path $stateRoot 'BRAVO_VERSION_STATE.json'
            LockRoot          = $lockRoot
            OperationLockPath = Join-Path $lockRoot 'BRAVO_OPERATION.lock'
        }
    }

    function Write-DiscoveryJournal {
        param([string]$StateRoot, [string]$OperationId, [string]$State, [bool]$MutationStarted, [string]$RawText)
        $dir = Join-Path $StateRoot 'Journal'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $text = $RawText
        if ([string]::IsNullOrEmpty($text)) {
            $text = ([ordered]@{
                schemaVersion = 1; operationId = $OperationId; planId = [guid]::NewGuid().ToString(); action = 'Update'
                state = $State; runtimeRoot = 'sandbox'; stagingRoot = 'sandbox'; backupRoot = 'sandbox'; artifactSha256 = ('A' * 64)
                sourceVersion = '5.2.6'; targetVersion = '5.3.0'; mutationStarted = $MutationStarted
                phases = @(); lastCompletedPhase = 'Backup'
                backup = @{ path = 'sandbox'; manifestSha256 = ('B' * 64); fileCount = 1 }
                schedulerSnapshot = @{ path = 'sandbox' }; createdOwnership = @()
                createdUtc = '2026-10-29T00:00:00.0000000Z'; updatedUtc = '2026-10-29T00:00:00.0000000Z'
            } | ConvertTo-Json -Depth 6)
        }
        [IO.File]::WriteAllText((Join-Path $dir "$OperationId.json"), $text, (New-Object Text.UTF8Encoding $false))
    }

    try {
        New-Item -ItemType Directory -Path $discoveryBase -Force | Out-Null

        # ===== 0/1 кандидат: NotInstalled / Installed / explicit =====
        & {
            $p = Get-DiscoveryParameters -Name 'a'
            $emptyRoot = Join-Path $discoveryBase 'a-empty'
            New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null
            $goodRoot = Join-Path $discoveryBase 'a-good'
            New-DiscoveryRoot -Path $goodRoot
            $other = Join-Path $discoveryBase 'a-other'
            New-DiscoveryRoot -Path $other
            $snapshotBefore = Get-DiscoverySnapshot -Path $discoveryBase

            $s0 = Invoke-DiscoveryState -Parameters ($p + @{ CandidateRoots = @($emptyRoot) })
            Test-BRAVOCondition -Condition ($s0.state -eq 'NotInstalled' -and $null -eq $s0.runtimeRoot -and @($s0.candidateRoots).Count -eq 0) -Name 'UpdateDiscovery/NotInstalled' -Failure "state=$($s0.state)"

            $s1 = Invoke-DiscoveryState -Parameters ($p + @{ CandidateRoots = @($emptyRoot, $goodRoot) })
            Test-BRAVOCondition -Condition ($s1.state -eq 'Installed' -and $s1.runtimeRoot -eq $goodRoot -and @($s1.candidateRoots).Count -eq 1) -Name 'UpdateDiscovery/SingleCandidateInstalled' -Failure "state=$($s1.state) root=$($s1.runtimeRoot)"
            Test-BRAVOCondition -Condition ($s1.schemaVersion -eq 1 -and $s1.version.packageVersion -eq '5.3.0' -and $s1.version.releaseChannel -eq 'stable' -and $s1.version.buildId -eq 'abc1234') -Name 'UpdateDiscovery/VersionParsedAsData' -Failure ($s1.version | Out-String)
            Test-BRAVOCondition -Condition ($s1.integrity.status -eq 'Valid' -and $s1.integrity.checkedCount -eq 1 -and $s1.integrity.mismatchedCount -eq 0) -Name 'UpdateDiscovery/IntegrityValid' -Failure ($s1.integrity | Out-String)
            Test-BRAVOCondition -Condition ($s1.credentials.status -eq 'Unknown' -and $s1.scheduler.status -eq 'Unknown' -and $s1.lifecycleLock.held -eq $false) -Name 'UpdateDiscovery/DefaultsUnknownScheduler' -Failure ($s1 | Out-String)
            Test-BRAVOCondition -Condition ($s1.configuration.migrationBlocker.blocked -eq $null -and @($s1.configuration.migrationBlocker.reasons) -contains 'not evaluated') -Name 'UpdateDiscovery/MigrationBlockerNotEvaluated' -Failure ($s1.configuration | Out-String)
            # a-other створено до знімка
            # explicit RuntimeRoot перемагає, навіть коли кандидатів кілька.
            $other = Join-Path $discoveryBase 'a-other'
            $sExplicit = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot; CandidateRoots = @($goodRoot, $other) })
            Test-BRAVOCondition -Condition ($sExplicit.state -eq 'Installed' -and $sExplicit.runtimeRoot -eq $goodRoot) -Name 'UpdateDiscovery/ExplicitRootWins' -Failure "state=$($sExplicit.state)"
            $sExplicitEmpty = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $emptyRoot })
            Test-BRAVOCondition -Condition ($sExplicitEmpty.state -eq 'NotInstalled' -and $sExplicitEmpty.runtimeRoot -eq $emptyRoot) -Name 'UpdateDiscovery/ExplicitEmptyRootNotInstalled' -Failure "state=$($sExplicitEmpty.state)"

            # N кандидатів без явного root -> Ambiguous (не вгадуємо).
            $sAmbiguous = Invoke-DiscoveryState -Parameters ($p + @{ CandidateRoots = @($goodRoot, $other) })
            Test-BRAVOCondition -Condition ($sAmbiguous.state -eq 'Ambiguous' -and $null -eq $sAmbiguous.runtimeRoot -and @($sAmbiguous.candidateRoots).Count -eq 2) -Name 'UpdateDiscovery/TwoRootsAmbiguous' -Failure "state=$($sAmbiguous.state)"
            # той самий шлях двічі (інший регістр/слеш) — не два кандидати.
            $sDupe = Invoke-DiscoveryState -Parameters ($p + @{ CandidateRoots = @($goodRoot, ($goodRoot.ToUpperInvariant() + '\')) })
            Test-BRAVOCondition -Condition ($sDupe.state -eq 'Installed' -and @($sDupe.candidateRoots).Count -eq 1) -Name 'UpdateDiscovery/DuplicateCandidatesDeduplicated' -Failure "state=$($sDupe.state) count=$(@($sDupe.candidateRoots).Count)"

            # Усі findings: українські title/meaning, Blocker має action.
            $allFindings = @($s0.findings) + @($s1.findings) + @($sAmbiguous.findings)
            $badFinding = @($allFindings | Where-Object {
                [string]::IsNullOrWhiteSpace($_.title) -or [string]::IsNullOrWhiteSpace($_.meaning) -or
                ($_.title -notmatch '[\u0400-\u04FF]') -or ($_.severity -eq 'Blocker' -and [string]::IsNullOrWhiteSpace($_.action))
            })
            Test-BRAVOCondition -Condition ($allFindings.Count -gt 0 -and $badFinding.Count -eq 0) -Name 'UpdateDiscovery/FindingsUkrainianComplete' -Failure ($badFinding | Out-String)

            # Read-only доказ: жоден файл/каталог не змінився.
            $snapshotAfter = Get-DiscoverySnapshot -Path $discoveryBase
            Test-BRAVOCondition -Condition ($snapshotBefore -ceq $snapshotAfter) -Name 'UpdateDiscovery/ReadOnlyFixtureUnchanged' -Failure 'знімок фікстури змінився після discovery'
        }

        # ===== версії/канали =====
        & {
            $p = Get-DiscoveryParameters -Name 'b'
            $stable = Join-Path $discoveryBase 'b-stable'
            New-DiscoveryRoot -Path $stable -Version '5.3.0'
            $dev = Join-Path $discoveryBase 'b-dev'
            New-DiscoveryRoot -Path $dev -Channel 'development' -Version '5.3.0-dev.3'
            $sDev = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $dev })
            Test-BRAVOCondition -Condition ($sDev.state -eq 'PrereleaseInstalled') -Name 'UpdateDiscovery/PrereleaseChannel' -Failure "state=$($sDev.state)"
            $sNewer = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $stable; KnownStableVersion = '5.4.0' })
            Test-BRAVOCondition -Condition ($sNewer.state -eq 'UpdateAvailable') -Name 'UpdateDiscovery/UpdateAvailableOnlyWithNewerKnown' -Failure "state=$($sNewer.state)"
            $sSame = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $stable; KnownStableVersion = '5.3.0' })
            Test-BRAVOCondition -Condition ($sSame.state -eq 'Installed') -Name 'UpdateDiscovery/EqualKnownIsInstalled' -Failure "state=$($sSame.state)"
            $sOlder = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $stable; KnownStableVersion = '5.2.6' })
            Test-BRAVOCondition -Condition ($sOlder.state -eq 'Installed') -Name 'UpdateDiscovery/OlderKnownIsInstalled' -Failure "state=$($sOlder.state)"
            $sNone = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $stable })
            Test-BRAVOCondition -Condition ($sNone.state -eq 'Installed') -Name 'UpdateDiscovery/NoKnownNoUpdate' -Failure "state=$($sNone.state)"
            $sBad = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $stable; KnownStableVersion = 'not-a-version' })
            Test-BRAVOCondition -Condition ($sBad.state -eq 'Installed' -and @($sBad.findings | Where-Object { $_.id -eq 'Discovery.KnownStable' }).Count -eq 1) -Name 'UpdateDiscovery/InvalidKnownVersionIgnoredWithWarning' -Failure "state=$($sBad.state)"
            $sPreKnown = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $stable; KnownStableVersion = '5.4.0-rc.1' })
            Test-BRAVOCondition -Condition ($sPreKnown.state -eq 'Installed') -Name 'UpdateDiscovery/PrereleaseKnownIsNotStable' -Failure "state=$($sPreKnown.state)"
        }

        # ===== пошкоджений/частковий стан =====
        & {
            $p = Get-DiscoveryParameters -Name 'c'
            $tampered = Join-Path $discoveryBase 'c-tampered'
            New-DiscoveryRoot -Path $tampered
            [IO.File]::WriteAllText((Join-Path $tampered 'BRAVO_FIXTURE.ps1'), "# changed`r`n", (New-Object Text.UTF8Encoding $true))
            $sTampered = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $tampered })
            Test-BRAVOCondition -Condition ($sTampered.state -eq 'RepairRequired' -and $sTampered.integrity.status -eq 'Invalid' -and $sTampered.integrity.mismatchedCount -eq 1) -Name 'UpdateDiscovery/TamperedFileRepairRequired' -Failure "state=$($sTampered.state)"
            $integrityFinding = @($sTampered.findings | Where-Object { $_.id -eq 'Discovery.Integrity' })[0]
            Test-BRAVOCondition -Condition ($integrityFinding.severity -eq 'Blocker' -and $integrityFinding.exitCodeHint -eq 33) -Name 'UpdateDiscovery/IntegrityBlockerExitHint33' -Failure ($integrityFinding | Out-String)

            $noManifest = Join-Path $discoveryBase 'c-nomanifest'
            New-DiscoveryRoot -Path $noManifest -NoManifest
            $sNoManifest = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $noManifest })
            Test-BRAVOCondition -Condition ($sNoManifest.state -eq 'RepairRequired' -and $sNoManifest.integrity.status -eq 'Invalid') -Name 'UpdateDiscovery/MissingManifestRepairRequired' -Failure "state=$($sNoManifest.state)"

            $corrupt = Join-Path $discoveryBase 'c-corruptversion'
            New-DiscoveryRoot -Path $corrupt
            [IO.File]::WriteAllText((Join-Path $corrupt 'VERSION.json'), '{ not json', (New-Object Text.UTF8Encoding $false))
            $sCorrupt = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $corrupt })
            Test-BRAVOCondition -Condition ($sCorrupt.state -eq 'RepairRequired' -and $null -eq $sCorrupt.version) -Name 'UpdateDiscovery/CorruptVersionJsonRepairRequired' -Failure "state=$($sCorrupt.state)"

            $noVersion = Join-Path $discoveryBase 'c-noversion'
            New-DiscoveryRoot -Path $noVersion -NoVersion
            $sNoVersion = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $noVersion })
            Test-BRAVOCondition -Condition ($sNoVersion.state -eq 'RepairRequired') -Name 'UpdateDiscovery/ManifestWithoutVersionRepairRequired' -Failure "state=$($sNoVersion.state)"

            $badSemver = Join-Path $discoveryBase 'c-badsemver'
            New-DiscoveryRoot -Path $badSemver -Version '5.3'
            $sBadSemver = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $badSemver })
            Test-BRAVOCondition -Condition ($sBadSemver.state -eq 'RepairRequired') -Name 'UpdateDiscovery/InvalidPackageVersionRepairRequired' -Failure "state=$($sBadSemver.state)"

            $partial = Join-Path $discoveryBase 'c-partial'
            New-Item -ItemType Directory -Path $partial -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $partial 'BRAVO_ARCHIV.ps1'), "# leftover`r`n", (New-Object Text.UTF8Encoding $true))
            $sPartial = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $partial })
            Test-BRAVOCondition -Condition ($sPartial.state -eq 'RepairRequired') -Name 'UpdateDiscovery/LeftoverFilesRepairRequired' -Failure "state=$($sPartial.state)"

            $missingRoot = Join-Path $discoveryBase 'c-does-not-exist'
            $sMissing = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $missingRoot })
            Test-BRAVOCondition -Condition ($sMissing.state -eq 'NotInstalled') -Name 'UpdateDiscovery/NonexistentExplicitRootNotInstalled' -Failure "state=$($sMissing.state)"
            Test-BRAVOCondition -Condition (-not [IO.Directory]::Exists($missingRoot)) -Name 'UpdateDiscovery/NonexistentRootNotCreated' -Failure 'discovery створив каталог'
        }

        # ===== Cyrillic + пробіли у шляху =====
        & {
            $p = Get-DiscoveryParameters -Name 'd'
            $cyr = Join-Path $discoveryBase 'Мій сервер BRAVO'
            New-DiscoveryRoot -Path $cyr
            $sCyr = Invoke-DiscoveryState -Parameters ($p + @{ CandidateRoots = @($cyr) })
            Test-BRAVOCondition -Condition ($sCyr.state -eq 'Installed' -and $sCyr.runtimeRoot -eq $cyr -and $sCyr.integrity.status -eq 'Valid') -Name 'UpdateDiscovery/CyrillicPathWithSpaces' -Failure "state=$($sCyr.state) root=$($sCyr.runtimeRoot)"
        }

        # ===== журнал =====
        & {
            $p = Get-DiscoveryParameters -Name 'e'
            $goodRoot = Join-Path $discoveryBase 'e-root'
            New-DiscoveryRoot -Path $goodRoot
            $closedId = [guid]::NewGuid().ToString()
            Write-DiscoveryJournal -StateRoot $p.StateRoot -OperationId $closedId -State 'Committed' -MutationStarted $true
            $sClosed = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot })
            Test-BRAVOCondition -Condition ($sClosed.state -eq 'Installed' -and $sClosed.interruptedOperation.present -eq $false) -Name 'UpdateDiscovery/ClosedJournalIgnored' -Failure "state=$($sClosed.state)"

            $openId = [guid]::NewGuid().ToString()
            Write-DiscoveryJournal -StateRoot $p.StateRoot -OperationId $openId -State 'Open' -MutationStarted $false
            $sOpen = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot })
            Test-BRAVOCondition -Condition ($sOpen.state -eq 'InterruptedUpdate' -and $sOpen.interruptedOperation.operationId -eq $openId -and $sOpen.interruptedOperation.action -eq 'Update' -and $sOpen.interruptedOperation.lastCompletedPhase -eq 'Backup') -Name 'UpdateDiscovery/OpenJournalInterrupted' -Failure "state=$($sOpen.state)"

            $mutId = [guid]::NewGuid().ToString()
            Write-DiscoveryJournal -StateRoot $p.StateRoot -OperationId $mutId -State 'Open' -MutationStarted $true
            $sMut = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot })
            Test-BRAVOCondition -Condition ($sMut.state -eq 'RollbackRequired' -and $sMut.interruptedOperation.mutationStarted -eq $true -and $sMut.interruptedOperation.journalPath -like "*$mutId.json") -Name 'UpdateDiscovery/MutationJournalRollbackRequired' -Failure "state=$($sMut.state)"

            # Журнал має пріоритет над Ambiguous і NotInstalled.
            $emptyRoot = Join-Path $discoveryBase 'e-empty'
            New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null
            $sOverEmpty = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $emptyRoot })
            Test-BRAVOCondition -Condition ($sOverEmpty.state -eq 'RollbackRequired') -Name 'UpdateDiscovery/JournalBeatsNotInstalled' -Failure "state=$($sOverEmpty.state)"

            # Пошкоджений журнал fail closed.
            $p2 = Get-DiscoveryParameters -Name 'e2'
            $corruptId = [guid]::NewGuid().ToString()
            Write-DiscoveryJournal -StateRoot $p2.StateRoot -OperationId $corruptId -RawText '{ broken'
            $sCorruptJournal = Invoke-DiscoveryState -Parameters ($p2 + @{ RuntimeRoot = $goodRoot })
            Test-BRAVOCondition -Condition ($sCorruptJournal.state -eq 'RollbackRequired' -and $sCorruptJournal.interruptedOperation.operationId -eq $corruptId) -Name 'UpdateDiscovery/CorruptJournalFailClosed' -Failure "state=$($sCorruptJournal.state)"

            # Інтеграція з W1-функцією (stub у scope модуля): її результат використовується.
            & $updateModule {
                function script:Get-BRAVOUpdateOpenJournal { param([string]$StateRoot) return [pscustomobject]@{ operationId = 'stub-op'; action = 'Repair'; lastCompletedPhase = 'Stage'; mutationStarted = $false } }
            }
            try {
                $p3 = Get-DiscoveryParameters -Name 'e3'
                $sStub = Invoke-DiscoveryState -Parameters ($p3 + @{ RuntimeRoot = $goodRoot })
                Test-BRAVOCondition -Condition ($sStub.state -eq 'InterruptedUpdate' -and $sStub.interruptedOperation.operationId -eq 'stub-op' -and $sStub.interruptedOperation.action -eq 'Repair') -Name 'UpdateDiscovery/UsesOpenJournalFunction' -Failure "state=$($sStub.state)"
            } finally {
                & $updateModule { Remove-Item -LiteralPath 'Function:\Get-BRAVOUpdateOpenJournal' -ErrorAction SilentlyContinue }
            }
        }

        # ===== scheduler / credentials через adapter =====
        & {
            $p = Get-DiscoveryParameters -Name 'f'
            $goodRoot = Join-Path $discoveryBase 'f-root'
            New-DiscoveryRoot -Path $goodRoot
            $calls = @{ Tasks = 0; Cred = 0 }
            $okTasks = @(
                @{ name = 'BRAVO-Archive'; path = '\BRAVO\'; exists = $true; state = 'Ready'; enabled = $true }
                @{ name = 'BRAVO-Maintenance'; path = '\BRAVO\'; exists = $true; state = 'Ready'; enabled = $true }
            )
            $adapterOk = @{
                GetManagedTasks       = { $calls.Tasks++; return $okTasks }.GetNewClosure()
                TestCredentialPresence = { $calls.Cred++; return @([pscustomobject]@{ component = 'Archive'; account = 'TaskAccount'; credentialPresence = 'Found'; password = 'must-not-leak'; secretToken = 'x' }) }.GetNewClosure()
                Now                   = { return [datetime]'2026-10-29T10:00:00Z' }
            }
            $sNoSched = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot; Adapter = $adapterOk })
            Test-BRAVOCondition -Condition ($calls.Tasks -eq 0 -and $calls.Cred -eq 0 -and $sNoSched.scheduler.status -eq 'Unknown' -and $sNoSched.credentials.status -eq 'Unknown') -Name 'UpdateDiscovery/AdapterNotCalledByDefault' -Failure "tasks=$($calls.Tasks) cred=$($calls.Cred)"
            Test-BRAVOCondition -Condition ($sNoSched.generatedUtc -like '2026-10-29T10:00:00*') -Name 'UpdateDiscovery/AdapterNowUsed' -Failure $sNoSched.generatedUtc

            $sOk = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot; Adapter = $adapterOk; IncludeScheduler = $true })
            Test-BRAVOCondition -Condition ($sOk.scheduler.status -eq 'Ok' -and @($sOk.scheduler.tasks).Count -eq 2 -and $sOk.state -eq 'Installed' -and $calls.Cred -eq 0) -Name 'UpdateDiscovery/SchedulerOk' -Failure "status=$($sOk.scheduler.status) state=$($sOk.state)"

            $partialTasks = @(
                @{ name = 'BRAVO-Archive'; path = '\BRAVO\'; exists = $true; state = 'Ready'; enabled = $true }
                @{ name = 'BRAVO-Maintenance'; path = '\BRAVO\'; exists = $false; state = 'Unknown'; enabled = $false }
            )
            $adapterPartial = @{ GetManagedTasks = { return $partialTasks }.GetNewClosure() }
            $sPartial = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot; Adapter = $adapterPartial; IncludeScheduler = $true })
            Test-BRAVOCondition -Condition ($sPartial.scheduler.status -eq 'Partial' -and $sPartial.state -eq 'Degraded') -Name 'UpdateDiscovery/SchedulerPartialDegraded' -Failure "status=$($sPartial.scheduler.status) state=$($sPartial.state)"

            $adapterEmpty = @{ GetManagedTasks = { return @() } }
            $sMissing = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot; Adapter = $adapterEmpty; IncludeScheduler = $true })
            Test-BRAVOCondition -Condition ($sMissing.scheduler.status -eq 'Missing' -and $sMissing.state -eq 'Degraded') -Name 'UpdateDiscovery/SchedulerMissingDegraded' -Failure "status=$($sMissing.scheduler.status) state=$($sMissing.state)"

            $adapterThrow = @{ GetManagedTasks = { throw 'scm denied' } }
            $sThrow = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot; Adapter = $adapterThrow; IncludeScheduler = $true })
            Test-BRAVOCondition -Condition ($sThrow.scheduler.status -eq 'Unknown' -and $sThrow.state -eq 'Installed' -and @($sThrow.findings | Where-Object { $_.id -eq 'Discovery.Scheduler' -and $_.severity -eq 'Warning' }).Count -eq 1) -Name 'UpdateDiscovery/SchedulerErrorNeverThrows' -Failure "status=$($sThrow.scheduler.status) state=$($sThrow.state)"

            # шлях дії задачі додає кандидата -> з двома встановленнями Ambiguous.
            $taskRoot = Join-Path $discoveryBase 'f-taskroot'
            New-DiscoveryRoot -Path $taskRoot
            $actionTasks = @(@{ name = 'BRAVO-Archive'; path = '\BRAVO\'; exists = $true; state = 'Ready'; enabled = $true; actionPath = (Join-Path $taskRoot 'BRAVO_ARCHIV.ps1') })
            $adapterAction = @{ GetManagedTasks = { return $actionTasks }.GetNewClosure() }
            $sAction = Invoke-DiscoveryState -Parameters ($p + @{ CandidateRoots = @($goodRoot); Adapter = $adapterAction; IncludeScheduler = $true })
            Test-BRAVOCondition -Condition ($sAction.state -eq 'Ambiguous' -and @($sAction.candidateRoots).Count -eq 2) -Name 'UpdateDiscovery/TaskActionPathAddsCandidate' -Failure "state=$($sAction.state)"
            $sActionOnly = Invoke-DiscoveryState -Parameters ($p + @{ CandidateRoots = @($taskRoot); Adapter = $adapterAction; IncludeScheduler = $true })
            Test-BRAVOCondition -Condition ($sActionOnly.state -eq 'Installed' -and $sActionOnly.runtimeRoot -eq $taskRoot) -Name 'UpdateDiscovery/TaskActionSameRootDeduplicated' -Failure "state=$($sActionOnly.state)"

            # credentials лише з прапорцем; зайві (секретні) властивості не копіюються.
            $sCred = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot; Adapter = $adapterOk; IncludeCredentials = $true })
            $credJson = $sCred.credentials | ConvertTo-Json -Depth 5
            Test-BRAVOCondition -Condition ($calls.Cred -eq 1 -and $sCred.credentials.status -eq 'Checked' -and @($sCred.credentials.items).Count -eq 1 -and $sCred.credentials.items[0].credentialPresence -eq 'Found' -and $credJson -notmatch 'must-not-leak|secretToken|password') -Name 'UpdateDiscovery/CredentialsOnlyWhenRequestedNoSecrets' -Failure $credJson
            $adapterCredThrow = @{ TestCredentialPresence = { throw 'boom' } }
            $sCredThrow = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot; Adapter = $adapterCredThrow; IncludeCredentials = $true })
            Test-BRAVOCondition -Condition ($sCredThrow.credentials.status -eq 'Unknown' -and $sCredThrow.state -eq 'Installed') -Name 'UpdateDiscovery/CredentialErrorNeverThrows' -Failure "status=$($sCredThrow.credentials.status)"
        }

        # ===== version state, конфігурація, migration blocker =====
        & {
            $p = Get-DiscoveryParameters -Name 'g'
            $goodRoot = Join-Path $discoveryBase 'g-root'
            New-DiscoveryRoot -Path $goodRoot
            New-Item -ItemType Directory -Path $p.StateRoot -Force | Out-Null
            [IO.File]::WriteAllText($p.VersionStatePath, '{"highestVersionFull":"5.3.0-rc.2","highestVersion":"5.3.0"}', (New-Object Text.UTF8Encoding $false))
            $sVs = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot })
            Test-BRAVOCondition -Condition ($sVs.versionState.recordedVersion -eq '5.3.0-rc.2' -and $sVs.versionState.statePathKind -eq 'Sandbox') -Name 'UpdateDiscovery/VersionStateSandboxRead' -Failure ($sVs.versionState | Out-String)
            $productionStatePath = Join-Path (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'BRAVO\State') 'BRAVO_VERSION_STATE_DISCOVERY_NONEXISTENT.json'
            $pProd = $p.Clone(); $pProd['VersionStatePath'] = $productionStatePath
            $sProd = Invoke-DiscoveryState -Parameters ($pProd + @{ RuntimeRoot = $goodRoot })
            Test-BRAVOCondition -Condition ($sProd.versionState.statePathKind -eq 'Production' -and $null -eq $sProd.versionState.recordedVersion -and -not (Test-Path -LiteralPath $productionStatePath)) -Name 'UpdateDiscovery/VersionStateProductionKindNoWrite' -Failure ($sProd.versionState | Out-String)
            [IO.File]::WriteAllText($p.VersionStatePath, '{ broken', (New-Object Text.UTF8Encoding $false))
            $sVsBad = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot })
            Test-BRAVOCondition -Condition ($null -eq $sVsBad.versionState.recordedVersion -and @($sVsBad.findings | Where-Object { $_.id -eq 'Discovery.VersionState' }).Count -eq 1) -Name 'UpdateDiscovery/CorruptVersionStateWarning' -Failure ($sVsBad.versionState | Out-String)

            # Конфігурація: legacy BRAVO.config НЕ виконується (містить throw).
            $sentinel = Join-Path $discoveryBase 'g-config-executed.txt'
            [IO.File]::WriteAllText((Join-Path $goodRoot 'BRAVO.config'), "throw 'EXECUTED'`r`nSet-Content -LiteralPath '$sentinel' -Value x`r`n", (New-Object Text.UTF8Encoding $true))
            [IO.File]::WriteAllText((Join-Path $goodRoot 'BRAVO.local.config'), "@{ 'pathSettings.BackupRoot' = 'E:\ARCHIV' }`r`n", (New-Object Text.UTF8Encoding $true))
            $sCfg = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot })
            Test-BRAVOCondition -Condition ($sCfg.configuration.localConfigPresent -eq $true -and $sCfg.configuration.legacyConfigPresent -eq $true -and $sCfg.configuration.localConfigSchemaValid -eq 'Unknown' -and -not (Test-Path -LiteralPath $sentinel)) -Name 'UpdateDiscovery/ConfigPresenceOnlyNeverExecuted' -Failure ($sCfg.configuration | Out-String)

            # Migration blocker (stub W5 у scope модуля) -> Degraded.
            & $updateModule {
                function script:Test-BRAVOConfigMigrationBlocker { param([string]$RuntimeRoot) return [pscustomobject]@{ Blocked = $true; Reasons = @('legacy BRAVO.config'); Findings = @() } }
            }
            try {
                $sBlock = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot })
                Test-BRAVOCondition -Condition ($sBlock.state -eq 'Degraded' -and $sBlock.configuration.migrationBlocker.blocked -eq $true -and @($sBlock.configuration.migrationBlocker.reasons) -contains 'legacy BRAVO.config') -Name 'UpdateDiscovery/MigrationBlockerDegraded' -Failure "state=$($sBlock.state)"
            } finally {
                & $updateModule { Remove-Item -LiteralPath 'Function:\Test-BRAVOConfigMigrationBlocker' -ErrorAction SilentlyContinue }
            }
        }

        # ===== Unsupported OS =====
        & {
            $p = Get-DiscoveryParameters -Name 'h'
            $goodRoot = Join-Path $discoveryBase 'h-root'
            New-DiscoveryRoot -Path $goodRoot
            & $updateModule {
                function script:Get-BRAVOOSSupportTier { return [pscustomobject]@{ Tier = 'Unsupported'; Message = 'synthetic' } }
            }
            try {
                $sUnsupported = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot })
                Test-BRAVOCondition -Condition ($sUnsupported.state -eq 'Unsupported') -Name 'UpdateDiscovery/UnsupportedOsState' -Failure "state=$($sUnsupported.state)"
            } finally {
                & $updateModule { Remove-Item -LiteralPath 'Function:\Get-BRAVOOSSupportTier' -ErrorAction SilentlyContinue }
            }
        }

        # ===== lock peek (без захоплення) =====
        & {
            $p = Get-DiscoveryParameters -Name 'i'
            $goodRoot = Join-Path $discoveryBase 'i-root'
            New-DiscoveryRoot -Path $goodRoot
            New-Item -ItemType Directory -Path $p.LockRoot -Force | Out-Null
            $lifecycleLockPath = Join-Path $p.LockRoot 'BRAVO_UPDATE.lock'
            [IO.File]::WriteAllText($lifecycleLockPath, '{"operation":"Update"}', (New-Object Text.UTF8Encoding $false))
            $before = Get-Item -LiteralPath $lifecycleLockPath
            $beforeTicks = $before.LastWriteTimeUtc.Ticks
            $beforeLength = $before.Length

            $sFree = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot })
            Test-BRAVOCondition -Condition ($sFree.lifecycleLock.held -eq $false) -Name 'UpdateDiscovery/UnheldLockFileNotHeld' -Failure ($sFree.lifecycleLock | Out-String)

            $holder = New-Object System.IO.FileStream($lifecycleLockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try {
                $sHeld = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot })
                Test-BRAVOCondition -Condition ($sHeld.lifecycleLock.held -eq $true -and -not [string]::IsNullOrWhiteSpace($sHeld.lifecycleLock.holderDescription) -and @($sHeld.findings | Where-Object { $_.id -eq 'Discovery.Lock' -and $_.exitCodeHint -eq 20 }).Count -eq 1) -Name 'UpdateDiscovery/HeldLockDetected' -Failure ($sHeld.lifecycleLock | Out-String)
            } finally {
                $holder.Dispose()
            }
            $sReleased = Invoke-DiscoveryState -Parameters ($p + @{ RuntimeRoot = $goodRoot })
            $after = Get-Item -LiteralPath $lifecycleLockPath
            Test-BRAVOCondition -Condition ($sReleased.lifecycleLock.held -eq $false -and $after.Length -eq $beforeLength) -Name 'UpdateDiscovery/LockPeekDoesNotRetainOrChange' -Failure ($sReleased.lifecycleLock | Out-String)

            # Відсутній LockRoot/OperationLockPath — не помилка і не створення каталогу.
            $p2 = Get-DiscoveryParameters -Name 'i2'
            $sNoLock = Invoke-DiscoveryState -Parameters ($p2 + @{ RuntimeRoot = $goodRoot })
            Test-BRAVOCondition -Condition ($sNoLock.lifecycleLock.held -eq $false -and -not [IO.Directory]::Exists($p2.LockRoot) -and -not [IO.Directory]::Exists($p2.StateRoot)) -Name 'UpdateDiscovery/MissingStateAndLockRootsNotCreated' -Failure 'discovery створив каталоги стану/lock'
        }
    } finally {
        if ($discoveryBase.StartsWith($discoveryTempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $discoveryBase)) {
            Remove-Item -LiteralPath $discoveryBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
