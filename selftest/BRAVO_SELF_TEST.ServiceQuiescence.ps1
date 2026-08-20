# Домен-фрагмент self-test: ownership-маркер зупинки служб
# (BRAVO_SERVICE_QUIESCENCE.json, BRAVO.System) + Health-watchdog аварійного
# відновлення. Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається
# напряму. Успадковує з викликача: $root, Test-BRAVOCondition,
# New-BRAVOSelfTestRuntimeModule, $script:failures.

    # ============================================================
    # State round-trip (BRAVO.System): реальні Write/Read/Clear/
    # Suppress у TEMP-каталозі — Get-BRAVOServiceQuiescenceStatePath
    # затінюється стабом, щоб самотест НІКОЛИ не торкався справжнього
    # %ProgramData%\BRAVO\State.
    # ============================================================
    $systemModuleTextForQuiescence = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.System\BRAVO.System.psm1"),
        [Text.Encoding]::UTF8
    )
    $quiescenceStateStubs = @'
function Get-BRAVOServiceQuiescenceStatePath {
    if ([string]::IsNullOrWhiteSpace($script:BRAVOSelfTestQuiescenceStatePath)) {
        throw 'self-test: шлях quiescence-стану не ініціалізовано'
    }
    return $script:BRAVOSelfTestQuiescenceStatePath
}
function Set-BRAVOSelfTestQuiescenceStatePath {
    param([string]$Path)
    $script:BRAVOSelfTestQuiescenceStatePath = $Path
}
'@
    $quiescenceStateModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($quiescenceStateStubs + "`n" + $systemModuleTextForQuiescence) `
        -FunctionNames @(
            'Get-BRAVOServiceQuiescenceStatePath',
            'Set-BRAVOSelfTestQuiescenceStatePath',
            'Write-BRAVOServiceQuiescenceState',
            'Read-BRAVOServiceQuiescenceState',
            'Clear-BRAVOServiceQuiescenceState',
            'Set-BRAVOServiceQuiescenceRestartSuppressed',
            'Test-BRAVOProcessAlive'
        )
    $quiescenceTestRoot = Join-Path ([IO.Path]::GetTempPath()) (
        "bravo_selftest_quiescence_{0}" -f ([guid]::NewGuid().ToString("N"))
    )
    [void][IO.Directory]::CreateDirectory($quiescenceTestRoot)
    try {
        $quiescenceTestStatePath = Join-Path $quiescenceTestRoot 'BRAVO_SERVICE_QUIESCENCE.json'
        & $quiescenceStateModule {
            param($Path)
            Set-BRAVOSelfTestQuiescenceStatePath -Path $Path
        } $quiescenceTestStatePath

        [void](& $quiescenceStateModule {
            Write-BRAVOServiceQuiescenceState `
                -Owner 'BRAVO_MAINTENANCE' `
                -Services @(
                    @{ Name = 'BRAVO'; RestartIntent = $true },
                    @{ Name = 'BravoWeb'; RestartIntent = $false }
                ) `
                -LogFile 'C:\LOGS\maintenance.log'
        })
        $readQuiescenceState = & $quiescenceStateModule { Read-BRAVOServiceQuiescenceState }
        Test-BRAVOCondition `
            -Condition (
                $null -ne $readQuiescenceState -and
                [int]$readQuiescenceState.schemaVersion -eq 1 -and
                [string]$readQuiescenceState.owner -eq 'BRAVO_MAINTENANCE' -and
                [string]$readQuiescenceState.hostname -eq [Environment]::MachineName -and
                [int]$readQuiescenceState.pid -eq $PID -and
                -not [string]::IsNullOrWhiteSpace([string]$readQuiescenceState.processStartTime) -and
                [bool]$readQuiescenceState.restartSuppressed -eq $false -and
                @($readQuiescenceState.services).Count -eq 2 -and
                [string]$readQuiescenceState.services[0].Name -eq 'BRAVO' -and
                [bool]$readQuiescenceState.services[0].RestartIntent -eq $true -and
                [bool]$readQuiescenceState.services[1].RestartIntent -eq $false
            ) `
            -Name "ServiceQuiescence/StateRoundTripPreservesOwnershipAndServices" `
            -Failure "Write->Read має зберігати schemaVersion/owner/hostname/pid/processStartTime/services[].RestartIntent"
        Test-BRAVOCondition `
            -Condition (@(Get-ChildItem -LiteralPath $quiescenceTestRoot -File -Filter '.BRAVO_SERVICE_QUIESCENCE_*').Count -eq 0) `
            -Name "ServiceQuiescence/AtomicWriteLeavesNoTemporaryFiles" `
            -Failure "після атомарного запису маркера в каталозі не має лишатися .tmp/.bak файлів"

        $suppressedQuiescenceState = & $quiescenceStateModule {
            [void](Set-BRAVOServiceQuiescenceRestartSuppressed)
            Read-BRAVOServiceQuiescenceState
        }
        Test-BRAVOCondition `
            -Condition (
                $null -ne $suppressedQuiescenceState -and
                [bool]$suppressedQuiescenceState.restartSuppressed -eq $true -and
                [string]$suppressedQuiescenceState.owner -eq 'BRAVO_MAINTENANCE' -and
                @($suppressedQuiescenceState.services).Count -eq 2
            ) `
            -Name "ServiceQuiescence/SuppressKeepsOwnershipAndServices" `
            -Failure "Set-...RestartSuppressed має виставляти restartSuppressed=true, зберігаючи owner і services"

        & $quiescenceStateModule { Clear-BRAVOServiceQuiescenceState }
        $clearedQuiescenceState = & $quiescenceStateModule {
            # Друге Clear поспіль перевіряє ідемпотентність.
            Clear-BRAVOServiceQuiescenceState
            Read-BRAVOServiceQuiescenceState
        }
        Test-BRAVOCondition `
            -Condition ($null -eq $clearedQuiescenceState) `
            -Name "ServiceQuiescence/ClearIsIdempotentAndReadReturnsNull" `
            -Failure "Clear має бути ідемпотентним, а Read після нього — повертати null"

        # Read відхиляє чужий hostname і незнайому schemaVersion — watchdog
        # у цих випадках НЕ має права діяти.
        $foreignHostJson = '{"schemaVersion":1,"owner":"BRAVO_MAINTENANCE","hostname":"OTHER-HOST","pid":1,"processStartTime":"","createdAt":"","logFile":"","restartSuppressed":false,"services":[]}'
        [IO.File]::WriteAllText($quiescenceTestStatePath, $foreignHostJson, (New-Object Text.UTF8Encoding($false)))
        $foreignHostRead = & $quiescenceStateModule { Read-BRAVOServiceQuiescenceState }
        $unknownSchemaJson = '{"schemaVersion":2,"owner":"BRAVO_MAINTENANCE","hostname":"' + [Environment]::MachineName + '","pid":1,"processStartTime":"","createdAt":"","logFile":"","restartSuppressed":false,"services":[]}'
        [IO.File]::WriteAllText($quiescenceTestStatePath, $unknownSchemaJson, (New-Object Text.UTF8Encoding($false)))
        $unknownSchemaRead = & $quiescenceStateModule { Read-BRAVOServiceQuiescenceState }
        [IO.File]::WriteAllText($quiescenceTestStatePath, '{ broken json', (New-Object Text.UTF8Encoding($false)))
        $brokenJsonRead = & $quiescenceStateModule { Read-BRAVOServiceQuiescenceState }
        Test-BRAVOCondition `
            -Condition ($null -eq $foreignHostRead -and $null -eq $unknownSchemaRead -and $null -eq $brokenJsonRead) `
            -Name "ServiceQuiescence/ReadRejectsForeignHostUnknownSchemaAndBrokenJson" `
            -Failure "Read має повертати null для чужого hostname, schemaVersion!=1 і зіпсованого JSON"

        # Liveness-предикат: живий власний процес -> true; той самий PID з
        # іншим startTime (симуляція PID-реюзу) -> false; неіснуючий PID -> false.
        # Module-qualified: DataRestore-домен уже влив у сесію стаб Get-Process
        # без -Id (New-Module авто-імпортує members).
        $ownProcessStartTime = (Microsoft.PowerShell.Management\Get-Process -Id $PID).StartTime.ToString('o')
        $aliveResult = & $quiescenceStateModule {
            param($ProcessId, $StartTime)
            Test-BRAVOProcessAlive -ProcessId $ProcessId -ProcessStartTime $StartTime
        } $PID $ownProcessStartTime
        $reusedPidResult = & $quiescenceStateModule {
            param($ProcessId, $StartTime)
            Test-BRAVOProcessAlive -ProcessId $ProcessId -ProcessStartTime $StartTime
        } $PID ((Get-Date).AddYears(-1).ToString('o'))
        $usedProcessIds = @((Microsoft.PowerShell.Management\Get-Process).Id)
        $deadProcessId = 99991
        while ($usedProcessIds -contains $deadProcessId) { $deadProcessId += 8 }
        $deadPidResult = & $quiescenceStateModule {
            param($ProcessId, $StartTime)
            Test-BRAVOProcessAlive -ProcessId $ProcessId -ProcessStartTime $StartTime
        } $deadProcessId $ownProcessStartTime
        Test-BRAVOCondition `
            -Condition ($aliveResult -eq $true -and $reusedPidResult -eq $false -and $deadPidResult -eq $false) `
            -Name "ServiceQuiescence/ProcessAliveDetectsDeathAndPidReuse" `
            -Failure "Test-BRAVOProcessAlive: живий PID+startTime=true; інший startTime (PID-реюз)=false; мертвий PID=false"
    } finally {
        Remove-Item -LiteralPath $quiescenceTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ============================================================
    # Health-watchdog (поведінкові): Invoke-BRAVOServiceQuiescenceWatchdog
    # в ізольованому модулі; Read/Test-Alive/Get-Service/Start-Service/
    # Clear — стаби, реальні служби НІКОЛИ не чіпаються.
    # ============================================================
    $healthRuntimeTextForQuiescence = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $quiescenceWatchdogStubs = @'
function Write-HealthLog {
    param([AllowEmptyString()][string]$Message, [string]$Level = 'INFO')
}
function Read-BRAVOServiceQuiescenceState {
    return $script:BRAVOSelfTestQuiescenceReadResult
}
function Test-BRAVOProcessAlive {
    param([int]$ProcessId, [string]$ProcessStartTime)
    return [bool]$script:BRAVOSelfTestQuiescenceOwnerAlive
}
function Get-Service {
    param([string]$Name, $ErrorAction)
    return [pscustomobject]@{ Name = $Name; Status = 'Stopped' }
}
function Start-Service {
    param([string]$Name, $ErrorAction)
    if (@($script:BRAVOSelfTestQuiescenceStartFailures) -contains $Name) {
        throw "self-test: імітований збій старту служби $Name"
    }
    $script:BRAVOSelfTestQuiescenceStartedServices += @($Name)
}
function Clear-BRAVOServiceQuiescenceState {
    $script:BRAVOSelfTestQuiescenceCleared = $true
}
function Invoke-BRAVOSelfTestQuiescenceScenario {
    param($State, [bool]$OwnerAlive, [string[]]$StartFailures)
    $script:BRAVOSelfTestQuiescenceReadResult = $State
    $script:BRAVOSelfTestQuiescenceOwnerAlive = $OwnerAlive
    $script:BRAVOSelfTestQuiescenceStartFailures = @($StartFailures)
    $script:BRAVOSelfTestQuiescenceStartedServices = @()
    $script:BRAVOSelfTestQuiescenceCleared = $false
    $issues = @(Invoke-BRAVOServiceQuiescenceWatchdog)
    return [pscustomobject]@{
        Issues = $issues
        StartedServices = @($script:BRAVOSelfTestQuiescenceStartedServices)
        MarkerCleared = [bool]$script:BRAVOSelfTestQuiescenceCleared
    }
}
'@
    $quiescenceWatchdogModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($quiescenceWatchdogStubs + "`n" + $healthRuntimeTextForQuiescence) `
        -FunctionNames @(
            'Write-HealthLog',
            'Read-BRAVOServiceQuiescenceState',
            'Test-BRAVOProcessAlive',
            'Get-Service',
            'Start-Service',
            'Clear-BRAVOServiceQuiescenceState',
            'Invoke-BRAVOSelfTestQuiescenceScenario',
            'Invoke-BRAVOServiceQuiescenceWatchdog'
        )
    $orphanedQuiescenceMarker = [pscustomobject]@{
        schemaVersion = 1
        owner = 'BRAVO_MAINTENANCE'
        hostname = [Environment]::MachineName
        pid = 12345
        processStartTime = '2026-08-20T23:55:00.0000000+03:00'
        createdAt = '2026-08-20T23:55:01.0000000+03:00'
        logFile = 'C:\LOGS\maintenance.log'
        restartSuppressed = $false
        services = @(
            [pscustomobject]@{ Name = 'BRAVO'; RestartIntent = $true },
            [pscustomobject]@{ Name = 'exchangAPI'; RestartIntent = $true },
            [pscustomobject]@{ Name = 'BravoWeb'; RestartIntent = $false }
        )
    }

    # (а) Осиротілий маркер, власник мертвий -> старт РІВНО RestartIntent-служб,
    # маркер очищено, WARNING-issue робить аварію видимою оператору.
    $deadOwnerScenario = & $quiescenceWatchdogModule {
        param($State)
        Invoke-BRAVOSelfTestQuiescenceScenario -State $State -OwnerAlive $false -StartFailures @()
    } $orphanedQuiescenceMarker
    Test-BRAVOCondition `
        -Condition (
            @($deadOwnerScenario.StartedServices).Count -eq 2 -and
            @($deadOwnerScenario.StartedServices) -contains 'BRAVO' -and
            @($deadOwnerScenario.StartedServices) -contains 'exchangAPI' -and
            -not (@($deadOwnerScenario.StartedServices) -contains 'BravoWeb') -and
            $deadOwnerScenario.MarkerCleared -eq $true -and
            @($deadOwnerScenario.Issues).Count -eq 1 -and
            [string]$deadOwnerScenario.Issues[0].Reason -match 'відновлено автоматично'
        ) `
        -Name "ServiceQuiescence/WatchdogRestoresOnlyRestartIntentServicesAndClearsMarker" `
        -Failure "мертвий власник: старт рівно services[].RestartIntent=true, Clear маркера, issue про аварійне відновлення"

    # (б) Власник живий (Maintenance/DataRestore саме працює) -> нуль дій.
    $aliveOwnerScenario = & $quiescenceWatchdogModule {
        param($State)
        Invoke-BRAVOSelfTestQuiescenceScenario -State $State -OwnerAlive $true -StartFailures @()
    } $orphanedQuiescenceMarker
    Test-BRAVOCondition `
        -Condition (
            @($aliveOwnerScenario.StartedServices).Count -eq 0 -and
            $aliveOwnerScenario.MarkerCleared -eq $false -and
            @($aliveOwnerScenario.Issues).Count -eq 0
        ) `
        -Name "ServiceQuiescence/WatchdogDoesNothingWhileOwnerAlive" `
        -Failure "живий власник маркера: watchdog не стартує служби, не чистить маркер, не створює issues"

    # (в) restartSuppressed=true (DataRestore лишив служби зупиненими навмисно,
    # rollback неповний) -> нуль стартів + issue про ручне втручання.
    $suppressedMarker = $orphanedQuiescenceMarker.PSObject.Copy()
    $suppressedMarker.restartSuppressed = $true
    $suppressedScenario = & $quiescenceWatchdogModule {
        param($State)
        Invoke-BRAVOSelfTestQuiescenceScenario -State $State -OwnerAlive $false -StartFailures @()
    } $suppressedMarker
    Test-BRAVOCondition `
        -Condition (
            @($suppressedScenario.StartedServices).Count -eq 0 -and
            $suppressedScenario.MarkerCleared -eq $false -and
            @($suppressedScenario.Issues).Count -eq 1 -and
            [string]$suppressedScenario.Issues[0].Reason -match 'РУЧНЕ'
        ) `
        -Name "ServiceQuiescence/WatchdogRespectsSuppressedMarker" `
        -Failure "suppressed-маркер: жодного старту, маркер лишається, issue про потребу ручного відновлення"

    # (г) РЕГРЕСІЯ ГОЛОВНОЇ ВИМОГИ: маркера немає (техпідтримка зупинила
    # служби вручну) -> watchdog НІКОЛИ не стартує.
    $manualStopScenario = & $quiescenceWatchdogModule {
        Invoke-BRAVOSelfTestQuiescenceScenario -State $null -OwnerAlive $false -StartFailures @()
    }
    Test-BRAVOCondition `
        -Condition (
            @($manualStopScenario.StartedServices).Count -eq 0 -and
            $manualStopScenario.MarkerCleared -eq $false -and
            @($manualStopScenario.Issues).Count -eq 0
        ) `
        -Name "ServiceQuiescence/WatchdogNeverStartsServicesWithoutMarker" `
        -Failure "без маркера (ручна зупинка техпідтримкою) watchdog не має права стартувати служби"

    # (д) Частковий збій старту -> маркер ЛИШАЄТЬСЯ (наступний Health
    # повторить), issue містить перелік невдач.
    $partialFailureScenario = & $quiescenceWatchdogModule {
        param($State)
        Invoke-BRAVOSelfTestQuiescenceScenario -State $State -OwnerAlive $false -StartFailures @('exchangAPI')
    } $orphanedQuiescenceMarker
    Test-BRAVOCondition `
        -Condition (
            @($partialFailureScenario.StartedServices).Count -eq 1 -and
            @($partialFailureScenario.StartedServices) -contains 'BRAVO' -and
            $partialFailureScenario.MarkerCleared -eq $false -and
            @($partialFailureScenario.Issues).Count -eq 1 -and
            [string]$partialFailureScenario.Issues[0].Reason -match 'не вдалося відновити' -and
            [string]$partialFailureScenario.Issues[0].Reason -match 'exchangAPI'
        ) `
        -Name "ServiceQuiescence/WatchdogKeepsMarkerOnPartialStartFailure" `
        -Failure "частковий збій старту: маркер зберігається для повтору, issue перелічує невдалі служби"

    # ============================================================
    # Статичні перевірки інтеграції маркера в рантайми.
    # ============================================================
    $maintenanceRuntimeTextForQuiescence = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $maintenanceMarkerWriteIndex = $maintenanceRuntimeTextForQuiescence.IndexOf('Write-BRAVOServiceQuiescenceState')
    $maintenanceFirstStopIndex = $maintenanceRuntimeTextForQuiescence.IndexOf('-DesiredStatus Stopped')
    Test-BRAVOCondition `
        -Condition (
            $maintenanceMarkerWriteIndex -ge 0 -and
            $maintenanceFirstStopIndex -ge 0 -and
            $maintenanceMarkerWriteIndex -lt $maintenanceFirstStopIndex
        ) `
        -Name "ServiceQuiescence/MaintenanceWritesMarkerBeforeFirstServiceStop" `
        -Failure "Maintenance має писати ownership-маркер ДО першої зупинки служби (fail-closed)"
    Test-BRAVOCondition `
        -Condition ($maintenanceRuntimeTextForQuiescence.Contains('if ($script:quiescenceMarkerWrittenThisRun -and -not $serviceRestartFailed)')) `
        -Name "ServiceQuiescence/MaintenanceClearsOnlyOwnMarkerAfterSuccessfulRestarts" `
        -Failure "Maintenance має чистити ЛИШЕ власний маркер і лише коли всі старти служб успішні"

    $dataRestoreRuntimeTextForQuiescence = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.DataRestore\BRAVO.DataRestore.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $dataRestoreMarkerWriteIndex = $dataRestoreRuntimeTextForQuiescence.IndexOf('Write-BRAVOServiceQuiescenceState')
    $dataRestoreStoppedFlagIndex = $dataRestoreRuntimeTextForQuiescence.IndexOf('$script:dataRestoreServicesStopped = $true')
    Test-BRAVOCondition `
        -Condition (
            $dataRestoreMarkerWriteIndex -ge 0 -and
            $dataRestoreStoppedFlagIndex -ge 0 -and
            $dataRestoreRuntimeTextForQuiescence.Contains('Set-BRAVOServiceQuiescenceRestartSuppressed') -and
            $dataRestoreRuntimeTextForQuiescence.Contains('if ($script:dataRestoreQuiescenceMarkerWritten)')
        ) `
        -Name "ServiceQuiescence/DataRestoreWritesMarkerAndSuppressesOnIncompleteRollback" `
        -Failure "DataRestore має писати маркер при зупинці служб і виставляти restartSuppressed у гілці неповного rollback"

    $healthWatchdogInvokeIndex = $healthRuntimeTextForQuiescence.IndexOf('$quiescenceWatchdogIssues = @(Invoke-BRAVOServiceQuiescenceWatchdog)')
    $healthManagedServicesIndex = $healthRuntimeTextForQuiescence.IndexOf('$serviceHealthIssues = @($quiescenceWatchdogIssues) + @(Get-ManagedServiceHealthIssues)')
    Test-BRAVOCondition `
        -Condition (
            $healthWatchdogInvokeIndex -ge 0 -and
            $healthManagedServicesIndex -ge 0 -and
            $healthWatchdogInvokeIndex -lt $healthManagedServicesIndex
        ) `
        -Name "ServiceQuiescence/HealthRunsWatchdogBeforeManagedServiceChecks" `
        -Failure "Health має запускати watchdog ДО оцінки керованих служб і вливати його issues у результат"
