# Домен-фрагмент self-test: UpdateContracts (BRAVO.Update: Paths, Contracts, Journal;
# INS-010…014). Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition.
#
# Функції частин BRAVO.Update не експортуються (psd1), тому логіка виконується в
# області модуля (& $updModule { ... }) і повертає прості факти; перевірки
# Test-BRAVOCondition виконуються тут, у області фрагмента.

Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking -ErrorAction Stop
$updModule = Get-Module -Name 'BRAVO.Update'
$updTempBase = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_UPDATE_SELF_TEST_' + [guid]::NewGuid().ToString('N'))
# Каталог зі пробілом і кирилицею: реальні профілі операторів містять і те, і інше.
$updSandbox = Join-Path $updTempBase 'Каталог зі пробілом'
[void][IO.Directory]::CreateDirectory($updSandbox)

try {
    # ===== Paths / adapter =====
    & {
        $facts = & $updModule {
            param($sandbox)
            $paths = Get-BRAVOUpdateDefaultPaths
            $adapter = New-BRAVOUpdateDefaultAdapter -ToolkitRoot $sandbox
            $keys = @('InvokeGuard', 'InvokeSetupScheduler', 'InvokeSetupValidate', 'InvokeSelfTest', 'GetManagedTasks', 'SetTaskEnabled', 'TestCredentialPresence', 'GetEffectiveConfiguration', 'Now')
            $missingKeys = @($keys | Where-Object { -not $adapter.ContainsKey($_) })
            $notBlocks = @($keys | Where-Object { $adapter.ContainsKey($_) -and ($adapter[$_] -isnot [scriptblock]) })
            $root1 = Join-Path $sandbox 'Root'
            @{
                PathKeys      = @($paths.PSObject.Properties.Name | Sort-Object) -join ','
                StateTail     = $paths.StateRoot.EndsWith('BRAVO\State\Update')
                LockTail      = $paths.OperationLockPath.EndsWith('BRAVO\Locks\BRAVO_OPERATION.lock')
                RuntimeTail   = $paths.RuntimeRoot.EndsWith('BRAVO-Toolkit')
                MissingKeys   = $missingKeys.Count
                NotBlocks     = $notBlocks.Count
                ExtraKeys     = ($adapter.Keys.Count -eq $keys.Count)
                NowKind       = [string](& $adapter.Now).GetType().Name
                Child         = (Test-BRAVOUpdatePathIsUnder -Path (Join-Path $root1 'a\b') -Root $root1)
                ChildUpper    = (Test-BRAVOUpdatePathIsUnder -Path ((Join-Path $root1 'a').ToUpperInvariant()) -Root $root1.ToLowerInvariant())
                Equal         = (Test-BRAVOUpdatePathIsUnder -Path $root1 -Root $root1)
                EqualAllowed  = (Test-BRAVOUpdatePathIsUnder -Path $root1 -Root $root1 -AllowEqual)
                Escape        = (Test-BRAVOUpdatePathIsUnder -Path ($root1 + '\..\Other') -Root $root1)
                SiblingPrefix = (Test-BRAVOUpdatePathIsUnder -Path ($root1 + 'X\a') -Root $root1)
                EmptyPath     = (Test-BRAVOUpdatePathIsUnder -Path '' -Root $root1)
                TrailingSlash = (Test-BRAVOUpdatePathIsUnder -Path (Join-Path $root1 'a') -Root ($root1 + '\'))
                FullPath      = (Get-BRAVOUpdateFullPath -Path ($root1 + '\x\..\y\'))
                Expected      = (Join-Path $root1 'y')
            }
        } $updSandbox
        Test-BRAVOCondition -Condition ($facts.PathKeys -eq 'BackupRoot,LockRoot,OperationLockPath,RuntimeRoot,StagingRoot,StateRoot') -Name 'UpdateContracts/DefaultPathsShape' -Failure 'Get-BRAVOUpdateDefaultPaths має повертати рівно 6 полів контракту'
        Test-BRAVOCondition -Condition ($facts.StateTail -and $facts.LockTail -and $facts.RuntimeTail) -Name 'UpdateContracts/DefaultPathsValues' -Failure 'default-шляхи мають відповідати CONTRACTS §1'
        Test-BRAVOCondition -Condition (($facts.MissingKeys -eq 0) -and ($facts.NotBlocks -eq 0) -and $facts.ExtraKeys) -Name 'UpdateContracts/AdapterShape' -Failure 'adapter має містити рівно 9 ключів-scriptblock'
        Test-BRAVOCondition -Condition ($facts.NowKind -eq 'DateTime') -Name 'UpdateContracts/AdapterNow' -Failure 'adapter.Now має повертати DateTime'
        Test-BRAVOCondition -Condition ($facts.Child -and $facts.ChildUpper -and $facts.TrailingSlash) -Name 'UpdateContracts/PathIsUnderPositive' -Failure 'підкаталог (будь-який регістр, кінцевий роздільник, кирилиця/пробіл) має бути under'
        Test-BRAVOCondition -Condition ((-not $facts.Equal) -and $facts.EqualAllowed -and (-not $facts.Escape) -and (-not $facts.SiblingPrefix) -and (-not $facts.EmptyPath)) -Name 'UpdateContracts/PathIsUnderNegative' -Failure 'збіг, ".." escape, префікс-сусід і порожній шлях не є under'
        Test-BRAVOCondition -Condition ($facts.FullPath -eq $facts.Expected) -Name 'UpdateContracts/FullPathNormalizes' -Failure 'Get-BRAVOUpdateFullPath має згортати .. і прибирати кінцевий роздільник'
    }

    # ===== Finding, секрети, канонічний JSON =====
    & {
        $facts = & $updModule {
            $blockerThrows = $false
            try { [void](New-BRAVOUpdateFinding -Id 'X.Y' -Severity Blocker -Title 't') } catch { $blockerThrows = $true }
            $blocker = New-BRAVOUpdateFinding -Id 'X.Y' -Severity Blocker -Title 't' -Action 'зробіть' -ExitCodeHint 20
            $warning = New-BRAVOUpdateFinding -Id 'X.W' -Severity Warning -Title 'w'
            $summary = Get-BRAVOUpdateFindingSummary -Findings @($blocker, $warning)
            $emptySummary = Get-BRAVOUpdateFindingSummary -Findings @()
            $nullSummary = Get-BRAVOUpdateFindingSummary -Findings $null
            $deep = [pscustomobject]@{ a = @([pscustomobject]@{ b = @{ c = [pscustomobject]@{ apiKey = 'x' } } }) }
            $deepCheck = Test-BRAVOUpdateNoSecretProperty -InputObject $deep
            $upper = Test-BRAVOUpdateNoSecretProperty -InputObject @{ WebHook = 1 }
            $tokenCheck = Test-BRAVOUpdateNoSecretProperty -InputObject ([pscustomobject]@{ items = @([pscustomobject]@{ privateKey = 1 }, [pscustomobject]@{ passphrase = 1 }) })
            $okPresence = Test-BRAVOUpdateNoSecretProperty -InputObject ([pscustomobject]@{ items = @([pscustomobject]@{ credentialPresence = 'Found' }) })
            $badPresence = Test-BRAVOUpdateNoSecretProperty -InputObject ([pscustomobject]@{ credentialPresence = 'hunter2' })
            $a = [ordered]@{ z = 1; a = @(3, 2, 1); m = [pscustomobject]@{ y = 'я'; b = $null } }
            $b = [ordered]@{ m = [pscustomobject]@{ b = $null; y = 'я' }; a = @(3, 2, 1); z = 1 }
            $jsonA = Get-BRAVOUpdateCanonicalJson -InputObject $a
            $jsonB = Get-BRAVOUpdateCanonicalJson -InputObject $b
            $reordered = Get-BRAVOUpdateCanonicalJson -InputObject ([ordered]@{ z = 1; a = @(1, 2, 3); m = [pscustomobject]@{ y = 'я'; b = $null } })
            @{
                BlockerThrows = $blockerThrows
                Hint          = $blocker.exitCodeHint
                Marker        = ((Format-BRAVOUpdateFindingMarker -Severity Ok) + (Format-BRAVOUpdateFindingMarker -Severity Warning) + (Format-BRAVOUpdateFindingMarker -Severity Blocker) + (Format-BRAVOUpdateFindingMarker -Severity NotApplicable))
                SummaryB      = $summary.BlockerCount
                SummaryW      = $summary.WarningCount
                SummaryCan    = $summary.CanProceed
                EmptyCan      = ($emptySummary.CanProceed -and $nullSummary.CanProceed -and $emptySummary.BlockerCount -eq 0)
                FindingValid  = (Test-BRAVOUpdateFinding -InputObject $blocker).IsValid
                FindingBad    = (Test-BRAVOUpdateFinding -InputObject ([pscustomobject]@{ id = 'a'; severity = 'Fatal' })).IsValid
                DeepValid     = $deepCheck.IsValid
                DeepProblem   = ($deepCheck.Problems -join ';')
                UpperValid    = $upper.IsValid
                TokenCount    = @($tokenCheck.Problems).Count
                PresenceOk    = $okPresence.IsValid
                PresenceBad   = $badPresence.IsValid
                Canonical     = ($jsonA -eq $jsonB)
                CanonicalText = $jsonA
                ArrayOrder    = ($jsonA -ne $reordered)
                Sha           = (Get-BRAVOUpdateSha256Text -Text 'abc')
                ShaUtf8       = (Get-BRAVOUpdateSha256Text -Text 'я')
            }
        }
        Test-BRAVOCondition -Condition ($facts.BlockerThrows -and $facts.Hint -eq 20) -Name 'UpdateContracts/FindingBlockerNeedsAction' -Failure 'Blocker без Action має кидати виняток'
        Test-BRAVOCondition -Condition ($facts.Marker -eq ([string]([char]0x2713) + '!' + [string]([char]0xD7) + [string]([char]0x2014))) -Name 'UpdateContracts/FindingMarkers' -Failure 'маркери мають бути ✓ ! × —'
        Test-BRAVOCondition -Condition (($facts.SummaryB -eq 1) -and ($facts.SummaryW -eq 1) -and (-not $facts.SummaryCan) -and $facts.EmptyCan) -Name 'UpdateContracts/FindingSummary' -Failure 'підсумок findings: blocker блокує, порожній/null — дозволяє'
        Test-BRAVOCondition -Condition ($facts.FindingValid -and (-not $facts.FindingBad)) -Name 'UpdateContracts/FindingValidator' -Failure 'валідатор finding: валідний ok, невалідний severity відхилено'
        Test-BRAVOCondition -Condition ((-not $facts.DeepValid) -and ($facts.DeepProblem -match 'apiKey') -and (-not $facts.UpperValid) -and ($facts.TokenCount -eq 2)) -Name 'UpdateContracts/SecretRejectedAtDepth' -Failure 'секретні імена мають відхилятись на будь-якій глибині (PSCustomObject/hashtable/масив)'
        Test-BRAVOCondition -Condition ($facts.PresenceOk -and (-not $facts.PresenceBad)) -Name 'UpdateContracts/CredentialPresenceAllowlist' -Failure 'credentialPresence дозволено лише зі значеннями Found|Missing|Unknown|NotRequired'
        Test-BRAVOCondition -Condition ($facts.Canonical -and $facts.ArrayOrder -and ($facts.CanonicalText -match '^\{"a":\[3,2,1\],"m":\{"b":null,"y":"я"\},"z":1\}$')) -Name 'UpdateContracts/CanonicalJsonStable' -Failure 'канонічний JSON: ключі відсортовані, порядок масиву збережено'
        Test-BRAVOCondition -Condition (($facts.Sha -ceq 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD') -and ($facts.ShaUtf8 -cmatch '^[0-9A-F]{64}$')) -Name 'UpdateContracts/Sha256Upper' -Failure 'SHA-256 має бути UPPER hex (UTF-8)'
    }

    # ===== Конструктори й валідатори контрактів =====
    & {
        $facts = & $updModule {
            param($sandbox)
            $blocker = New-BRAVOUpdateFinding -Id 'P.D' -Severity Blocker -Title 't' -Action 'a' -ExitCodeHint 37
            $fp = Get-BRAVOUpdateSha256Text -Text 'x'
            $state = New-BRAVOUpdateInstallationState -State Installed -RuntimeRoot (Join-Path $sandbox 'rt')
            $pre = New-BRAVOUpdatePreflightResult -Operation Update -RuntimeRoot (Join-Path $sandbox 'rt') -Findings @($blocker) -Fingerprint $fp
            $plan = New-BRAVOUpdateDeploymentPlan -Action Update -RuntimeRoot (Join-Path $sandbox 'rt') -StagingRoot (Join-Path $sandbox 'st') -BackupRoot (Join-Path $sandbox 'bk') -PreconditionsFingerprint $fp
            $evt = New-BRAVOUpdateProgressEvent -OperationId $plan.operationId -Sequence 1 -Phase Deploy -Status Started
            $res = New-BRAVOUpdateDeploymentResult -OperationId $plan.operationId -PlanId $plan.planId -Action Update -Status Success

            $badState = New-BRAVOUpdateInstallationState -State Installed
            $badState.state = 'Bogus'
            $secretState = New-BRAVOUpdateInstallationState -State Installed
            $secretState | Add-Member -NotePropertyName 'smtpPassword' -NotePropertyValue 'x'
            $stateNoVersion = New-BRAVOUpdateInstallationState -State Installed
            $stateNoVersion.schemaVersion = 2
            $badPre = New-BRAVOUpdatePreflightResult -Operation Update -Findings @($blocker) -Fingerprint $fp
            $badPre.canProceed = $true
            $badPlan = New-BRAVOUpdateDeploymentPlan -Action Install -RuntimeRoot 'a' -StagingRoot 'b' -BackupRoot 'c'
            $badPlan2 = New-BRAVOUpdateDeploymentPlan -Action Install -RuntimeRoot 'a' -StagingRoot 'b' -BackupRoot 'c' -PreconditionsFingerprint $fp
            $badPlan2.requiresConfirmation = $false
            $badPlan3 = New-BRAVOUpdateDeploymentPlan -Action Install -RuntimeRoot 'a' -StagingRoot 'b' -BackupRoot 'c' -PreconditionsFingerprint $fp
            $badPlan3.planId = 'NOT-A-GUID'
            $badEvt = New-BRAVOUpdateProgressEvent -OperationId $plan.operationId -Sequence 1 -Phase Deploy -Status Started
            $badEvt.percent = 101
            $badEvt2 = New-BRAVOUpdateProgressEvent -OperationId $plan.operationId -Sequence 1 -Phase Deploy -Status Started
            $badEvt2.sequence = 0
            $badRes = New-BRAVOUpdateDeploymentResult -OperationId $plan.operationId -Action Update -Status Failed
            $badRes2 = New-BRAVOUpdateDeploymentResult -OperationId $plan.operationId -Action Update -Status Success
            $badRes2.exitCode = 80

            $planPath = Join-Path $sandbox 'plan.json'
            [IO.File]::WriteAllText($planPath, (ConvertTo-BRAVOUpdateJson -InputObject $plan), (New-Object System.Text.UTF8Encoding($false)))
            $roundTrip = Read-BRAVOUpdateContractFile -Path $planPath -Kind DeploymentPlan
            $missing = Read-BRAVOUpdateContractFile -Path (Join-Path $sandbox 'nope.json') -Kind DeploymentPlan
            $corruptPath = Join-Path $sandbox 'corrupt.json'
            [IO.File]::WriteAllText($corruptPath, '{ "schemaVersion": 1, "planId": ', (New-Object System.Text.UTF8Encoding($false)))
            $corrupt = Read-BRAVOUpdateContractFile -Path $corruptPath -Kind DeploymentPlan
            $emptyPath = Join-Path $sandbox 'empty.json'
            [IO.File]::WriteAllText($emptyPath, '', (New-Object System.Text.UTF8Encoding($false)))
            $emptyRead = Read-BRAVOUpdateContractFile -Path $emptyPath -Kind DeploymentPlan
            $wrongKind = Read-BRAVOUpdateContractFile -Path $planPath -Kind PreflightResult
            $statePath = Join-Path $sandbox 'state.json'
            [IO.File]::WriteAllText($statePath, (ConvertTo-BRAVOUpdateJson -InputObject $state), (New-Object System.Text.UTF8Encoding($false)))
            $stateRead = Read-BRAVOUpdateContractFile -Path $statePath -Kind InstallationState
            $nullCheck = Test-BRAVOUpdateDeploymentPlan -InputObject $null
            $arrayCheck = Test-BRAVOUpdateDeploymentPlan -InputObject @(1, 2)
            @{
                StateValid = (Test-BRAVOUpdateInstallationState -InputObject $state).IsValid
                PreValid = (Test-BRAVOUpdatePreflightResult -InputObject $pre).IsValid
                PreCanProceed = $pre.canProceed
                PreBlockers = $pre.blockerCount
                PlanValid = (Test-BRAVOUpdateDeploymentPlan -InputObject $plan).IsValid
                PlanProblems = ((Test-BRAVOUpdateDeploymentPlan -InputObject $plan).Problems -join ';')
                PlanTtl = (([datetime]$plan.expiresUtc) - ([datetime]$plan.createdUtc)).TotalMinutes
                PlanGuids = (Test-BRAVOUpdateGuidText -Value $plan.planId) -and (Test-BRAVOUpdateGuidText -Value $plan.operationId) -and ($plan.planId -ne $plan.operationId)
                PlanConfirm = $plan.requiresConfirmation
                EvtValid = (Test-BRAVOUpdateProgressEvent -InputObject $evt).IsValid
                EvtPercentNull = ($null -eq $evt.percent)
                ResValid = (Test-BRAVOUpdateDeploymentResult -InputObject $res).IsValid
                ResProblems = ((Test-BRAVOUpdateDeploymentResult -InputObject $res).Problems -join ';')
                ResCode = $res.exitCode
                ResName = $res.exitCodeName
                BadState = (Test-BRAVOUpdateInstallationState -InputObject $badState).IsValid
                SecretState = (Test-BRAVOUpdateInstallationState -InputObject $secretState).IsValid
                BadSchema = (Test-BRAVOUpdateInstallationState -InputObject $stateNoVersion).IsValid
                BadPre = (Test-BRAVOUpdatePreflightResult -InputObject $badPre).IsValid
                BadPlanFp = (Test-BRAVOUpdateDeploymentPlan -InputObject $badPlan).IsValid
                BadPlanConfirm = (Test-BRAVOUpdateDeploymentPlan -InputObject $badPlan2).IsValid
                BadPlanId = (Test-BRAVOUpdateDeploymentPlan -InputObject $badPlan3).IsValid
                BadEvtPercent = (Test-BRAVOUpdateProgressEvent -InputObject $badEvt).IsValid
                BadEvtSeq = (Test-BRAVOUpdateProgressEvent -InputObject $badEvt2).IsValid
                BadResReason = (Test-BRAVOUpdateDeploymentResult -InputObject $badRes).IsValid
                BadResCode = (Test-BRAVOUpdateDeploymentResult -InputObject $badRes2).IsValid
                NullInvalid = (-not $nullCheck.IsValid) -and (-not $arrayCheck.IsValid)
                RoundTripValid = $roundTrip.IsValid
                RoundTripProblems = ($roundTrip.Problems -join ';')
                RoundTripId = ($roundTrip.Contract.planId -eq $plan.planId)
                RoundTripDateString = ($roundTrip.Contract.createdUtc -is [string])
                MissingFailClosed = (-not $missing.IsValid) -and ($missing.Problems.Count -gt 0)
                CorruptFailClosed = (-not $corrupt.IsValid) -and ($null -eq $corrupt.Contract)
                EmptyFailClosed = (-not $emptyRead.IsValid)
                WrongKind = $wrongKind.IsValid
                StateReadValid = $stateRead.IsValid
                StateReadProblems = ($stateRead.Problems -join ';')
            }
        } $updSandbox
        Test-BRAVOCondition -Condition ($facts.StateValid -and $facts.PreValid -and $facts.PlanValid -and $facts.EvtValid -and $facts.ResValid) -Name 'UpdateContracts/ConstructorsProduceValid' -Failure ("конструктори мають давати валідні контракти: plan=$($facts.PlanProblems); result=$($facts.ResProblems)")
        Test-BRAVOCondition -Condition (($facts.PreCanProceed -eq $false) -and ($facts.PreBlockers -eq 1)) -Name 'UpdateContracts/PreflightCounts' -Failure 'preflight рахує blockers і canProceed'
        Test-BRAVOCondition -Condition (($facts.PlanTtl -eq 30) -and $facts.PlanGuids -and ($facts.PlanConfirm -eq $true) -and $facts.EvtPercentNull) -Name 'UpdateContracts/ConstructorDefaults' -Failure 'default TTL 30 хв, GUID-и згенеровано, requiresConfirmation, percent null'
        Test-BRAVOCondition -Condition (($facts.ResCode -eq 0) -and ($facts.ResName -eq 'Success')) -Name 'UpdateContracts/ResultExitCodeFilled' -Failure 'DeploymentResult має заповнювати exitCode/exitCodeName через BRAVO.ExitCodes'
        Test-BRAVOCondition -Condition ((-not $facts.BadState) -and (-not $facts.SecretState) -and (-not $facts.BadSchema) -and (-not $facts.BadPre)) -Name 'UpdateContracts/InvalidStateAndPreflightRejected' -Failure 'enum, секрет, schemaVersion та неузгоджений canProceed мають відхилятись'
        Test-BRAVOCondition -Condition ((-not $facts.BadPlanFp) -and (-not $facts.BadPlanConfirm) -and (-not $facts.BadPlanId)) -Name 'UpdateContracts/InvalidPlanRejected' -Failure 'план без fingerprint / без confirmation / з поганим GUID має відхилятись'
        Test-BRAVOCondition -Condition ((-not $facts.BadEvtPercent) -and (-not $facts.BadEvtSeq) -and (-not $facts.BadResReason) -and (-not $facts.BadResCode)) -Name 'UpdateContracts/InvalidEventAndResultRejected' -Failure 'percent>100, sequence<1, Failed без reasonCode, невідповідний exitCode мають відхилятись'
        Test-BRAVOCondition -Condition ($facts.NullInvalid) -Name 'UpdateContracts/NullAndArrayInvalid' -Failure 'null і масив замість контракту — IsValid false без винятку'
        Test-BRAVOCondition -Condition ($facts.RoundTripValid -and $facts.RoundTripId -and $facts.RoundTripDateString -and $facts.StateReadValid) -Name 'UpdateContracts/ContractRoundTrip' -Failure ("round-trip через файл (шлях зі пробілом і кирилицею) має бути валідним: $($facts.RoundTripProblems) $($facts.StateReadProblems)")
        Test-BRAVOCondition -Condition ($facts.MissingFailClosed -and $facts.CorruptFailClosed -and $facts.EmptyFailClosed -and (-not $facts.WrongKind)) -Name 'UpdateContracts/ReadFailClosed' -Failure 'відсутній/порожній/пошкоджений файл і невідповідний Kind — IsValid false без винятку'
    }

    # ===== Відображення на коди завершення =====
    & {
        $facts = & $updModule {
            $mk = { param($status, $findings) [pscustomobject]@{ status = $status; findings = @($findings) } }
            $b20 = New-BRAVOUpdateFinding -Id 'a' -Severity Blocker -Title 't' -Action 'a' -ExitCodeHint 20
            $b42 = New-BRAVOUpdateFinding -Id 'b' -Severity Blocker -Title 't' -Action 'a' -ExitCodeHint 42
            $b99 = New-BRAVOUpdateFinding -Id 'c' -Severity Blocker -Title 't' -Action 'a' -ExitCodeHint 99
            $bNone = New-BRAVOUpdateFinding -Id 'd' -Severity Blocker -Title 't' -Action 'a'
            $warn20 = New-BRAVOUpdateFinding -Id 'e' -Severity Warning -Title 't' -ExitCodeHint 20
            $names = @{}
            foreach ($code in @(0, 10, 80, 81, 82)) { $names[$code] = Get-BRAVOExitCodeName -Code $code }
            $critical = New-BRAVOUpdateDeploymentResult -OperationId ([guid]::NewGuid().ToString()) -Action Update -Status Critical
            $rolled = New-BRAVOUpdateDeploymentResult -OperationId ([guid]::NewGuid().ToString()) -Action Update -Status RolledBack
            $failed = New-BRAVOUpdateDeploymentResult -OperationId ([guid]::NewGuid().ToString()) -Action Update -Status Failed -ReasonCode Blocked -Findings @($b42)
            @{
                Success = (ConvertTo-BRAVOUpdateExitCode -Result (& $mk 'Success' @()))
                Warnings = (ConvertTo-BRAVOUpdateExitCode -Result (& $mk 'SuccessWithWarnings' @($warn20)))
                Failed20 = (ConvertTo-BRAVOUpdateExitCode -Result (& $mk 'Failed' @($warn20, $b20, $b42)))
                Failed42 = (ConvertTo-BRAVOUpdateExitCode -Result (& $mk 'Failed' @($b42)))
                FailedUnknownHint = (ConvertTo-BRAVOUpdateExitCode -Result (& $mk 'Failed' @($b99)))
                FailedNoHint = (ConvertTo-BRAVOUpdateExitCode -Result (& $mk 'Failed' @($bNone, $b20)))
                FailedNoFindings = (ConvertTo-BRAVOUpdateExitCode -Result (& $mk 'Failed' @()))
                RolledBack = (ConvertTo-BRAVOUpdateExitCode -Result (& $mk 'RolledBack' @()))
                Critical = (ConvertTo-BRAVOUpdateExitCode -Result (& $mk 'Critical' @()))
                Unknown = (ConvertTo-BRAVOUpdateExitCode -Result (& $mk 'Weird' @()))
                Names = (($names.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $names[$_] }) -join ',')
                CriticalValid = (Test-BRAVOUpdateDeploymentResult -InputObject $critical).IsValid
                CriticalCode = $critical.exitCode
                RolledName = $rolled.exitCodeName
                FailedValid = (Test-BRAVOUpdateDeploymentResult -InputObject $failed).IsValid
                FailedCode = $failed.exitCode
            }
        }
        Test-BRAVOCondition -Condition (($facts.Success -eq 0) -and ($facts.Warnings -eq 10) -and ($facts.RolledBack -eq 81) -and ($facts.Critical -eq 82)) -Name 'UpdateContracts/ExitCodeFixedStatuses' -Failure 'Success=0, SuccessWithWarnings=10, RolledBack=81, Critical=82'
        Test-BRAVOCondition -Condition (($facts.Failed20 -eq 80) -or ($facts.Failed20 -eq 20)) -Name 'UpdateContracts/ExitCodeFailedFirstBlocker' -Failure 'Failed бере hint ПЕРШОГО blocker-а'
        Test-BRAVOCondition -Condition (($facts.Failed20 -eq 20) -and ($facts.Failed42 -eq 42) -and ($facts.FailedUnknownHint -eq 80) -and ($facts.FailedNoHint -eq 80) -and ($facts.FailedNoFindings -eq 80) -and ($facts.Unknown -eq 80)) -Name 'UpdateContracts/ExitCodeFailedMapping' -Failure 'Failed: hint з allowlist, інакше 80; невідомий статус = 80'
        Test-BRAVOCondition -Condition ($facts.Names -eq '0=Success,10=SuccessWithWarnings,80=DeploymentFailed,81=DeploymentRolledBack,82=DeploymentCritical') -Name 'UpdateContracts/ExitCodeNamesFromCanonicalModule' -Failure ("імена кодів мають іти з BRAVO.ExitCodes: $($facts.Names)")
        Test-BRAVOCondition -Condition ($facts.CriticalValid -and ($facts.CriticalCode -eq 82) -and ($facts.RolledName -eq 'DeploymentRolledBack') -and $facts.FailedValid -and ($facts.FailedCode -eq 42)) -Name 'UpdateContracts/ResultConstructorUsesMapping' -Failure 'конструктор result має використовувати відображення §7'
    }

    # ===== Progress JSONL =====
    & {
        $facts = & $updModule {
            param($sandbox)
            $opId = [guid]::NewGuid().ToString()
            $dir = Join-Path $sandbox 'Операції\op 1'
            $path = Join-Path $dir 'progress.jsonl'
            $writer = New-BRAVOUpdateProgressWriter -Path $path -OperationId $opId
            [void]$writer.Emit('Preflight', 'Started', $null, 'k.start', @(), 'Початок')
            [void]$writer.Emit('Deploy', 'Progress', 50, 'k.copy', @('a', 2), 'Копіювання файлів')
            [void](Send-BRAVOUpdateProgress -Writer $writer -Phase Commit -Status Completed -Percent 100 -MessageKey 'k.done')
            $events = @(Read-BRAVOUpdateProgressEvents -Path $path)
            $sequences = @($events | ForEach-Object { [int]$_.sequence })
            $after = @(Read-BRAVOUpdateProgressEvents -Path $path -AfterSequence 2)
            $bytes = [IO.File]::ReadAllBytes($path)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            $lineCount = @(([IO.File]::ReadAllText($path)) -split "`n" | Where-Object { $_.Length -gt 0 }).Count

            # «Рваний» останній рядок: обірваний запис без LF.
            $stream = New-Object System.IO.FileStream($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $torn = (New-Object System.Text.UTF8Encoding($false)).GetBytes('{"schemaVersion":1,"operationId":"' + $opId + '","sequence":4,"time')
            $stream.Write($torn, 0, $torn.Length)
            $stream.Dispose()
            $tornEvents = @(Read-BRAVOUpdateProgressEvents -Path $path)
            $tornThrows = $false
            try { $null = Read-BRAVOUpdateProgressEvents -Path $path } catch { $tornThrows = $true }
            # Новий writer продовжує нумерацію, а запис після уламка не склеюється з ним.
            $writer2 = New-BRAVOUpdateProgressWriter -Path $path -OperationId $opId
            [void]$writer2.Emit('Rollback', 'Started', $null, 'k.rb', @(), 'Відкат')
            $afterTorn = @(Read-BRAVOUpdateProgressEvents -Path $path)
            $missingRead = @(Read-BRAVOUpdateProgressEvents -Path (Join-Path $sandbox 'немає.jsonl'))
            $invalidThrows = $false
            try { Write-BRAVOUpdateProgressEvent -Path $path -Event ([pscustomobject]@{ schemaVersion = 1 }) } catch { $invalidThrows = $true }
            @{
                Sequences = ($sequences -join ',')
                AfterCount = $after.Count
                AfterFirst = [int]$after[0].sequence
                NoBom = (-not $hasBom)
                LineCount = $lineCount
                MessageUtf8 = ($events[1].message -eq 'Копіювання файлів')
                ArgsKept = (@($events[1].messageArgs).Count -eq 2)
                PercentNull = ($null -eq $events[0].percent)
                TornSkipped = ($tornEvents.Count -eq 3)
                TornThrows = $tornThrows
                AfterTornSequences = (@($afterTorn | ForEach-Object { [int]$_.sequence }) -join ',')
                MissingEmpty = ($missingRead.Count -eq 0)
                InvalidThrows = $invalidThrows
                Ts = ($events[0].timestampUtc -is [string])
            }
        } $updSandbox
        Test-BRAVOCondition -Condition (($facts.Sequences -eq '1,2,3') -and ($facts.LineCount -eq 3)) -Name 'UpdateContracts/ProgressSequenceMonotonic' -Failure "sequence має зростати з 1: $($facts.Sequences)"
        Test-BRAVOCondition -Condition (($facts.AfterCount -eq 1) -and ($facts.AfterFirst -eq 3)) -Name 'UpdateContracts/ProgressAfterSequence' -Failure '-AfterSequence має віддавати лише новіші події'
        Test-BRAVOCondition -Condition ($facts.NoBom -and $facts.MessageUtf8 -and $facts.ArgsKept -and $facts.PercentNull -and $facts.Ts) -Name 'UpdateContracts/ProgressEncodingAndFields' -Failure 'JSONL: UTF-8 без BOM, кирилиця збережена, percent null, timestamp рядок'
        Test-BRAVOCondition -Condition ($facts.TornSkipped -and (-not $facts.TornThrows)) -Name 'UpdateContracts/ProgressTornLineTolerated' -Failure 'рваний останній рядок пропускається без винятку'
        Test-BRAVOCondition -Condition ($facts.AfterTornSequences -eq '1,2,3,4') -Name 'UpdateContracts/ProgressResumeAfterTornLine' -Failure "після уламка нумерація продовжується (перший sequence 4), нова подія не склеюється: $($facts.AfterTornSequences)"
        Test-BRAVOCondition -Condition ($facts.MissingEmpty -and $facts.InvalidThrows) -Name 'UpdateContracts/ProgressMissingAndInvalid' -Failure 'відсутній файл = порожньо; невалідна подія не пишеться (виняток)'
    }

    # ===== Журнал =====
    & {
        $facts = & $updModule {
            param($sandbox)
            $stateRoot = Join-Path $sandbox 'Стан оновлення'
            $fp = Get-BRAVOUpdateSha256Text -Text 'artifact'
            $plan = New-BRAVOUpdateDeploymentPlan -Action Update -RuntimeRoot (Join-Path $sandbox 'rt') -StagingRoot (Join-Path $sandbox 'st') -BackupRoot (Join-Path $sandbox 'bk') -PreconditionsFingerprint $fp -CurrentVersion '5.3.0' -TargetVersion '5.4.0'

            $noOpen = @(Get-BRAVOUpdateOpenJournal -StateRoot $stateRoot)
            $journal = New-BRAVOUpdateJournal -Plan $plan -StateRoot $stateRoot
            $path = Get-BRAVOUpdateJournalPath -StateRoot $stateRoot -OperationId $journal.operationId
            $existsAfterNew = [IO.File]::Exists($path)
            $fromPlan = ($journal.planId -eq $plan.planId) -and ($journal.operationId -eq $plan.operationId) -and ($journal.sourceVersion -eq '5.3.0') -and ($journal.targetVersion -eq '5.4.0') -and ($journal.action -eq 'Update')

            [void](Add-BRAVOUpdateJournalPhaseIntent -Journal $journal -Phase 'Backup' -StateRoot $stateRoot)
            $onDiskIntent = Read-BRAVOUpdateJournal -Path $path
            $intentPersisted = $onDiskIntent.IsValid -and (@($onDiskIntent.Journal.phases).Count -eq 1) -and ($null -eq @($onDiskIntent.Journal.phases)[0].completedUtc)
            [void](Complete-BRAVOUpdateJournalPhase -Journal $journal -Phase 'Backup' -Outcome 'Succeeded' -StateRoot $stateRoot)
            $completeNoIntent = $false
            try { [void](Complete-BRAVOUpdateJournalPhase -Journal $journal -Phase 'Deploy' -Outcome 'Succeeded' -StateRoot $stateRoot) } catch { $completeNoIntent = $true }
            [void](Set-BRAVOUpdateJournalMutationStarted -Journal $journal -StateRoot $stateRoot)
            [void](Add-BRAVOUpdateJournalCreatedOwnership -Journal $journal -Key 'runtime\file1.ps1' -StateRoot $stateRoot)
            [void](Add-BRAVOUpdateJournalCreatedOwnership -Journal $journal -Key 'runtime\file1.ps1' -StateRoot $stateRoot)
            [void](Add-BRAVOUpdateJournalCreatedOwnership -Journal $journal -Key 'runtime\каталог' -StateRoot $stateRoot)
            [void](Set-BRAVOUpdateJournalBackup -Journal $journal -Path (Join-Path $sandbox 'bk\b1') -ManifestSha256 $fp -FileCount 7 -StateRoot $stateRoot)
            [void](Set-BRAVOUpdateJournalSchedulerSnapshot -Journal $journal -Path (Join-Path $sandbox 'snap.json') -StateRoot $stateRoot)
            [void](Add-BRAVOUpdateJournalPhaseIntent -Journal $journal -Phase 'Deploy' -StateRoot $stateRoot)
            $reread = Read-BRAVOUpdateJournal -Path $path
            $open = @(Get-BRAVOUpdateOpenJournal -StateRoot $stateRoot)

            # Корумпований журнал: fail closed, не ігнорується.
            $corruptId = [guid]::NewGuid().ToString()
            $corruptPath = Join-Path (Get-BRAVOUpdateJournalDirectory -StateRoot $stateRoot) ($corruptId + '.json')
            [IO.File]::WriteAllText($corruptPath, '{ "schemaVersion": 1, "operat', (New-Object System.Text.UTF8Encoding($false)))
            $withCorrupt = @(Get-BRAVOUpdateOpenJournal -StateRoot $stateRoot)
            $corruptEntry = @($withCorrupt | Where-Object { $_.IsCorrupt })
            # Файл-сміття .tmp ігнорується; невалідна схема (секрет) = corrupt.
            [IO.File]::WriteAllText((Join-Path (Get-BRAVOUpdateJournalDirectory -StateRoot $stateRoot) '.x.tmp'), 'garbage', (New-Object System.Text.UTF8Encoding($false)))
            $secretId = [guid]::NewGuid().ToString()
            $secretJournal = New-BRAVOUpdateJournal -Plan $plan -StateRoot $stateRoot -OperationId $secretId -NoWrite
            $secretJournal | Add-Member -NotePropertyName 'apiToken' -NotePropertyValue 'x'
            $secretWriteThrows = $false
            try { [void](Write-BRAVOUpdateJournal -Journal $secretJournal -StateRoot $stateRoot) } catch { $secretWriteThrows = $true }
            $secretFileWritten = [IO.File]::Exists((Get-BRAVOUpdateJournalPath -StateRoot $stateRoot -OperationId $secretId))
            Remove-Item -LiteralPath $corruptPath -Force
            $traversalThrows = $false
            try { [void](Get-BRAVOUpdateJournalPath -StateRoot $stateRoot -OperationId '..\..\evil') } catch { $traversalThrows = $true }

            [void](Set-BRAVOUpdateJournalState -Journal $journal -State Committed -StateRoot $stateRoot)
            $afterCommit = @(Get-BRAVOUpdateOpenJournal -StateRoot $stateRoot)
            $committed = Read-BRAVOUpdateJournal -Path $path
            $leftovers = @(Get-ChildItem -LiteralPath (Get-BRAVOUpdateJournalDirectory -StateRoot $stateRoot) -Force -File | Where-Object { $_.Name -match '\.(tmp|bak)$' -and $_.Name -ne '.x.tmp' })

            # Атомарний запис поверх наявного файлу: жодних .tmp/.bak, вміст замінено.
            $atomicPath = Join-Path $sandbox 'atomic\файл цілі.json'
            Write-BRAVOUpdateFileAtomic -Path $atomicPath -Text 'перша версія'
            Write-BRAVOUpdateFileAtomic -Path $atomicPath -Text 'друга версія'
            $atomicBytes = [IO.File]::ReadAllBytes($atomicPath)
            $atomicBom = ($atomicBytes.Length -ge 3 -and $atomicBytes[0] -eq 0xEF -and $atomicBytes[1] -eq 0xBB)
            $atomicLeft = @(Get-ChildItem -LiteralPath (Split-Path -Parent $atomicPath) -Force | Where-Object { $_.FullName -ne $atomicPath })
            # Збій створення тимчасового файлу не руйнує ціль: цільовий каталог = файл-перешкода.
            $blocked = Join-Path $sandbox 'blocked'
            [IO.File]::WriteAllText($blocked, 'x')
            $atomicFailThrows = $false
            try { Write-BRAVOUpdateFileAtomic -Path (Join-Path $blocked 'child.json') -Text 'x' } catch { $atomicFailThrows = $true }
            @{
                NoOpenInitially = ($noOpen.Count -eq 0)
                ExistsAfterNew = $existsAfterNew
                FromPlan = $fromPlan
                IntentPersisted = $intentPersisted
                CompleteNoIntentThrows = $completeNoIntent
                RereadValid = $reread.IsValid
                RereadProblems = ($reread.Problems -join ';')
                LastCompleted = $reread.Journal.lastCompletedPhase
                Mutation = $reread.Journal.mutationStarted
                Ownership = (@($reread.Journal.createdOwnership) -join '|')
                BackupCount = $reread.Journal.backup.fileCount
                SnapshotSet = ($null -ne $reread.Journal.schedulerSnapshot.path)
                PhaseCount = @($reread.Journal.phases).Count
                DeployOpenPhase = ($null -eq @($reread.Journal.phases)[1].completedUtc)
                OpenCount = $open.Count
                OpenState = $open[0].State
                OpenFindingBlocker = ($open[0].Finding.severity -eq 'Blocker')
                CorruptCount = $withCorrupt.Count
                CorruptFlag = ($corruptEntry.Count -eq 1) -and ($corruptEntry[0].State -eq 'Unknown') -and ($corruptEntry[0].Finding.id -eq 'Journal.Corrupt') -and ($corruptEntry[0].Finding.severity -eq 'Blocker')
                SecretWriteThrows = $secretWriteThrows
                SecretFileWritten = $secretFileWritten
                TraversalThrows = $traversalThrows
                AfterCommitOpen = $afterCommit.Count
                CommittedState = $committed.Journal.state
                Leftovers = $leftovers.Count
                AtomicText = ([IO.File]::ReadAllText($atomicPath))
                AtomicBom = $atomicBom
                AtomicLeft = $atomicLeft.Count
                AtomicFailThrows = $atomicFailThrows
            }
        } $updSandbox
        Test-BRAVOCondition -Condition ($facts.NoOpenInitially -and $facts.ExistsAfterNew -and $facts.FromPlan) -Name 'UpdateContracts/JournalCreatedFromPlan' -Failure 'журнал з плану записано на диск одразу; поля успадковано'
        Test-BRAVOCondition -Condition ($facts.IntentPersisted -and $facts.CompleteNoIntentThrows) -Name 'UpdateContracts/JournalIntentPersistedBeforeReturn' -Failure 'intent має бути на диску до повернення; Complete без intent кидає виняток'
        Test-BRAVOCondition -Condition ($facts.RereadValid -and ($facts.LastCompleted -eq 'Backup') -and $facts.Mutation -and ($facts.PhaseCount -eq 2) -and $facts.DeployOpenPhase) -Name 'UpdateContracts/JournalPhasesAndMutation' -Failure ("фази/mutationStarted/lastCompletedPhase мають зберігатись: $($facts.RereadProblems)")
        Test-BRAVOCondition -Condition (($facts.Ownership -eq 'runtime\file1.ps1|runtime\каталог') -and ($facts.BackupCount -eq 7) -and $facts.SnapshotSet) -Name 'UpdateContracts/JournalOwnershipBackupSnapshot' -Failure 'ownership (без дублікатів), backup і schedulerSnapshot мають зберігатись'
        Test-BRAVOCondition -Condition (($facts.OpenCount -eq 1) -and ($facts.OpenState -eq 'Open') -and $facts.OpenFindingBlocker) -Name 'UpdateContracts/OpenJournalBlocks' -Failure 'відкритий журнал має повертатись із blocker-finding'
        Test-BRAVOCondition -Condition (($facts.CorruptCount -eq 2) -and $facts.CorruptFlag) -Name 'UpdateContracts/CorruptJournalFailClosed' -Failure 'пошкоджений журнал = Open-with-unknown-state + blocker, ніколи не ігнорується; .tmp ігнорується'
        Test-BRAVOCondition -Condition ($facts.SecretWriteThrows -and (-not $facts.SecretFileWritten) -and $facts.TraversalThrows) -Name 'UpdateContracts/JournalRejectsSecretAndTraversal' -Failure 'журнал із секретним полем не пишеться; operationId не-GUID відхиляється'
        Test-BRAVOCondition -Condition (($facts.AfterCommitOpen -eq 0) -and ($facts.CommittedState -eq 'Committed') -and ($facts.Leftovers -eq 0)) -Name 'UpdateContracts/JournalCommittedClosesAndNoLeftovers' -Failure 'Committed журнал не блокує; тимчасових файлів не лишається'
        Test-BRAVOCondition -Condition (($facts.AtomicText -eq 'друга версія') -and (-not $facts.AtomicBom) -and ($facts.AtomicLeft -eq 0)) -Name 'UpdateContracts/AtomicWriteReplacesExisting' -Failure 'атомарний запис поверх наявного: нова версія, без BOM, без .tmp/.bak'
        Test-BRAVOCondition -Condition ($facts.AtomicFailThrows) -Name 'UpdateContracts/AtomicWriteFailureThrows' -Failure 'збій запису має кидати виняток, а не мовчати'
    }
} finally {
    # Видаляємо лише каталог, створений цим фрагментом, перевіривши префікс.
    $updTempPrefix = Join-Path ([IO.Path]::GetTempPath()) 'BRAVO_UPDATE_SELF_TEST_'
    if ($updTempBase.StartsWith($updTempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $updTempBase)) {
        Remove-Item -LiteralPath $updTempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}
