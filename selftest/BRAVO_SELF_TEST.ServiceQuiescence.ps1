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
            'Protect-BRAVOMachineStateRoot',
            'Get-BRAVOCurrentProcessStartTimeText',
            'Test-BRAVOServiceQuiescenceStateOwnedByCurrentProcess',
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

        $firstClearResult = & $quiescenceStateModule { Clear-BRAVOServiceQuiescenceState }
        $clearedQuiescenceState = & $quiescenceStateModule {
            # Друге Clear поспіль перевіряє ідемпотентність (маркера вже
            # немає -> $true, «мета досягнута»).
            [void](Clear-BRAVOServiceQuiescenceState)
            Read-BRAVOServiceQuiescenceState
        }
        Test-BRAVOCondition `
            -Condition ($firstClearResult -eq $true -and $null -eq $clearedQuiescenceState) `
            -Name "ServiceQuiescence/ClearIsIdempotentAndReadReturnsNull" `
            -Failure "Clear власного маркера має повертати true, бути ідемпотентним, а Read після нього — повертати null"

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

        # РЕГРЕСІЯ (review F3): валідний JSON з валідним header, але без
        # обов'язкових полів (частково відредагований вручну маркер) МУСИТЬ
        # давати null, а не PropertyNotFoundException під Set-StrictMode
        # глибше у watchdog (це валило б увесь Health-прогін).
        $ownHostnameText = [Environment]::MachineName
        $missingPidJson = '{"schemaVersion":1,"owner":"BRAVO_MAINTENANCE","hostname":"' + $ownHostnameText + '","processStartTime":"","createdAt":"","logFile":"","restartSuppressed":false,"services":[]}'
        [IO.File]::WriteAllText($quiescenceTestStatePath, $missingPidJson, (New-Object Text.UTF8Encoding($false)))
        $missingPidRead = & $quiescenceStateModule { Read-BRAVOServiceQuiescenceState }
        $missingServicesJson = '{"schemaVersion":1,"owner":"BRAVO_MAINTENANCE","hostname":"' + $ownHostnameText + '","pid":1,"processStartTime":"","createdAt":"","logFile":"","restartSuppressed":false}'
        [IO.File]::WriteAllText($quiescenceTestStatePath, $missingServicesJson, (New-Object Text.UTF8Encoding($false)))
        $missingServicesRead = & $quiescenceStateModule { Read-BRAVOServiceQuiescenceState }
        $nonNumericPidJson = '{"schemaVersion":1,"owner":"BRAVO_MAINTENANCE","hostname":"' + $ownHostnameText + '","pid":"abc","processStartTime":"","createdAt":"","logFile":"","restartSuppressed":false,"services":[]}'
        [IO.File]::WriteAllText($quiescenceTestStatePath, $nonNumericPidJson, (New-Object Text.UTF8Encoding($false)))
        $nonNumericPidRead = & $quiescenceStateModule { Read-BRAVOServiceQuiescenceState }
        $serviceWithoutIntentJson = '{"schemaVersion":1,"owner":"BRAVO_MAINTENANCE","hostname":"' + $ownHostnameText + '","pid":1,"processStartTime":"","createdAt":"","logFile":"","restartSuppressed":false,"services":[{"Name":"BRAVO"}]}'
        [IO.File]::WriteAllText($quiescenceTestStatePath, $serviceWithoutIntentJson, (New-Object Text.UTF8Encoding($false)))
        $serviceWithoutIntentRead = & $quiescenceStateModule { Read-BRAVOServiceQuiescenceState }
        Test-BRAVOCondition `
            -Condition (
                $null -eq $missingPidRead -and
                $null -eq $missingServicesRead -and
                $null -eq $nonNumericPidRead -and
                $null -eq $serviceWithoutIntentRead
            ) `
            -Name "ServiceQuiescence/ReadRejectsMarkerWithMissingRequiredFields" `
            -Failure "Read має повертати null для маркера без pid/services, з нечисловим pid і з services-записом без RestartIntent"

        # РЕГРЕСІЯ (review F2): Clear/Suppress НЕ чіпають чужий маркер
        # (записаний іншим процесом) — перетин власників (DataRestore під
        # час планового Maintenance) не має дозволяти одному процесу
        # видалити/переписати маркер іншого.
        $foreignOwnerPid = $PID + 1
        $foreignOwnedJson = '{"schemaVersion":1,"owner":"BRAVO_DATA_RESTORE","hostname":"' + $ownHostnameText + '","pid":' + $foreignOwnerPid + ',"processStartTime":"2001-01-01T00:00:00.0000000+02:00","createdAt":"2026-08-21T00:00:00.0000000+03:00","logFile":"C:\\LOGS\\datarestore.log","restartSuppressed":false,"services":[{"Name":"BRAVO","RestartIntent":true}]}'
        [IO.File]::WriteAllText($quiescenceTestStatePath, $foreignOwnedJson, (New-Object Text.UTF8Encoding($false)))
        $foreignClearResult = & $quiescenceStateModule { Clear-BRAVOServiceQuiescenceState }
        $foreignSuppressResult = & $quiescenceStateModule { Set-BRAVOServiceQuiescenceRestartSuppressed }
        $foreignMarkerAfterGuards = & $quiescenceStateModule { Read-BRAVOServiceQuiescenceState }
        Test-BRAVOCondition `
            -Condition (
                $foreignClearResult -eq $false -and
                $null -eq $foreignSuppressResult -and
                $null -ne $foreignMarkerAfterGuards -and
                [bool]$foreignMarkerAfterGuards.restartSuppressed -eq $false -and
                ($foreignMarkerAfterGuards.pid -as [int]) -eq $foreignOwnerPid
            ) `
            -Name "ServiceQuiescence/ClearAndSuppressNeverTouchForeignMarker" `
            -Failure "Clear має повертати false, а Suppress — null, лишаючи чужий маркер (інший pid/processStartTime) без змін"

        # РЕГРЕСІЯ (review F2): Clear -ExpectedState (шлях watchdog) видаляє
        # РІВНО очікуваний маркер; якщо на диску вже інший (новий власник
        # встиг перезаписати) — не чіпає.
        $staleExpectedState = & $quiescenceStateModule { Read-BRAVOServiceQuiescenceState }
        $replacementOwnedJson = '{"schemaVersion":1,"owner":"BRAVO_MAINTENANCE","hostname":"' + $ownHostnameText + '","pid":' + $foreignOwnerPid + ',"processStartTime":"2002-02-02T00:00:00.0000000+02:00","createdAt":"2026-08-21T01:00:00.0000000+03:00","logFile":"C:\\LOGS\\maintenance.log","restartSuppressed":false,"services":[{"Name":"BRAVO","RestartIntent":true}]}'
        [IO.File]::WriteAllText($quiescenceTestStatePath, $replacementOwnedJson, (New-Object Text.UTF8Encoding($false)))
        $mismatchedExpectedClearResult = & $quiescenceStateModule {
            param($Expected)
            Clear-BRAVOServiceQuiescenceState -ExpectedState $Expected
        } $staleExpectedState
        $currentExpectedState = & $quiescenceStateModule { Read-BRAVOServiceQuiescenceState }
        $matchedExpectedClearResult = & $quiescenceStateModule {
            param($Expected)
            Clear-BRAVOServiceQuiescenceState -ExpectedState $Expected
        } $currentExpectedState
        $markerAfterExpectedClear = & $quiescenceStateModule { Read-BRAVOServiceQuiescenceState }
        Test-BRAVOCondition `
            -Condition (
                $mismatchedExpectedClearResult -eq $false -and
                $null -ne $currentExpectedState -and
                $matchedExpectedClearResult -eq $true -and
                $null -eq $markerAfterExpectedClear
            ) `
            -Name "ServiceQuiescence/ClearWithExpectedStateDeletesOnlyThatExactMarker" `
            -Failure "Clear -ExpectedState має видаляти лише рівно очікуваний маркер (owner+pid+createdAt) і повертати false для переписаного"

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
    # Черга дозволяє симулювати TOCTOU: перший Read бачить один маркер,
    # повторний (verification перед Start-Service) — інший або жодного
    # ($null у черзі — легітимний елемент «маркер зник»; саме тому індекс,
    # а не зрізання масиву: @(... | Select-Object -Skip 1) губить $null).
    # Вичерпана/порожня черга -> завжди той самий ReadResult (штатні
    # сценарії).
    if ($script:BRAVOSelfTestQuiescenceReadIndex -lt @($script:BRAVOSelfTestQuiescenceReadQueue).Count) {
        $nextQueuedState = $script:BRAVOSelfTestQuiescenceReadQueue[$script:BRAVOSelfTestQuiescenceReadIndex]
        $script:BRAVOSelfTestQuiescenceReadIndex = $script:BRAVOSelfTestQuiescenceReadIndex + 1
        return $nextQueuedState
    }
    return $script:BRAVOSelfTestQuiescenceReadResult
}
function Test-BRAVOProcessAlive {
    param([int]$ProcessId, [string]$ProcessStartTime)
    return [bool]$script:BRAVOSelfTestQuiescenceOwnerAlive
}
function Get-BRAVOQuiescenceWatchdogAllowedServiceNames {
    return @($script:BRAVOSelfTestQuiescenceAllowedServices)
}
function Get-Service {
    param([string]$Name, $ErrorAction)
    $serviceStatus = if (@($script:BRAVOSelfTestQuiescenceRunningServices) -contains $Name) { 'Running' } else { 'Stopped' }
    return [pscustomobject]@{ Name = $Name; Status = $serviceStatus }
}
function Start-Service {
    param([string]$Name, $ErrorAction)
    if (@($script:BRAVOSelfTestQuiescenceStartFailures) -contains $Name) {
        throw "self-test: імітований збій старту служби $Name"
    }
    $script:BRAVOSelfTestQuiescenceStartedServices += @($Name)
}
function Clear-BRAVOServiceQuiescenceState {
    param([object]$ExpectedState)
    $script:BRAVOSelfTestQuiescenceCleared = $true
    $script:BRAVOSelfTestQuiescenceClearExpectedState = $ExpectedState
    return $true
}
function Invoke-BRAVOSelfTestQuiescenceScenario {
    param(
        $State,
        [bool]$OwnerAlive,
        [string[]]$StartFailures,
        [object[]]$ReadQueue = @(),
        [string[]]$AllowedServices = @('BRAVO', 'exchangAPI', 'BravoWeb'),
        [string[]]$RunningServices = @()
    )
    $script:BRAVOSelfTestQuiescenceReadResult = $State
    $script:BRAVOSelfTestQuiescenceReadQueue = @($ReadQueue)
    $script:BRAVOSelfTestQuiescenceReadIndex = 0
    $script:BRAVOSelfTestQuiescenceAllowedServices = @($AllowedServices)
    $script:BRAVOSelfTestQuiescenceRunningServices = @($RunningServices)
    $script:BRAVOSelfTestQuiescenceOwnerAlive = $OwnerAlive
    $script:BRAVOSelfTestQuiescenceStartFailures = @($StartFailures)
    $script:BRAVOSelfTestQuiescenceStartedServices = @()
    $script:BRAVOSelfTestQuiescenceCleared = $false
    $script:BRAVOSelfTestQuiescenceClearExpectedState = $null
    $issues = @(Invoke-BRAVOServiceQuiescenceWatchdog)
    return [pscustomobject]@{
        Issues = $issues
        StartedServices = @($script:BRAVOSelfTestQuiescenceStartedServices)
        MarkerCleared = [bool]$script:BRAVOSelfTestQuiescenceCleared
        ClearExpectedState = $script:BRAVOSelfTestQuiescenceClearExpectedState
    }
}
'@
    $quiescenceWatchdogModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($quiescenceWatchdogStubs + "`n" + $healthRuntimeTextForQuiescence) `
        -FunctionNames @(
            'Write-HealthLog',
            'Read-BRAVOServiceQuiescenceState',
            'Test-BRAVOProcessAlive',
            # Стаб (перший у SourceText) затіняє реальний однойменний хелпер
            # з Health-тексту: FindAll бере перше визначення.
            'Get-BRAVOQuiescenceWatchdogAllowedServiceNames',
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
            $null -ne $deadOwnerScenario.ClearExpectedState -and
            [string]$deadOwnerScenario.ClearExpectedState.createdAt -eq [string]$orphanedQuiescenceMarker.createdAt -and
            @($deadOwnerScenario.Issues).Count -eq 1 -and
            [string]$deadOwnerScenario.Issues[0].Reason -match 'відновлено автоматично' -and
            [string]$deadOwnerScenario.Issues[0].ActionText -match 'причину аварійного переривання'
        ) `
        -Name "ServiceQuiescence/WatchdogRestoresOnlyRestartIntentServicesAndClearsMarker" `
        -Failure "мертвий власник: старт рівно services[].RestartIntent=true, Clear РІВНО прочитаного маркера (-ExpectedState), issue про аварійне відновлення"

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
            [string]$suppressedScenario.Issues[0].Reason -match 'РУЧНЕ' -and
            [string]$suppressedScenario.Issues[0].Reason -match 'код(ом)? 43' -and
            # Компактність: без внутрішнього жаргону в операторському тексті.
            [string]$suppressedScenario.Issues[0].Reason -notmatch 'restartSuppressed' -and
            [string]$suppressedScenario.Issues[0].ActionText -match 'код 43'
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
            [string]$partialFailureScenario.Issues[0].Reason -match 'exchangAPI' -and
            [string]$partialFailureScenario.Issues[0].ActionText -match 'запустити служби вручну'
        ) `
        -Name "ServiceQuiescence/WatchdogKeepsMarkerOnPartialStartFailure" `
        -Failure "частковий збій старту: маркер зберігається для повтору, issue перелічує невдалі служби"

    # (е) РЕГРЕСІЯ (review F2, TOCTOU): між першим Read і Start-Service
    # маркер перезаписав НОВИЙ власник (Maintenance о 23:55 перетнувся з
    # Health) або маркер зник — watchdog МУСИТЬ вийти без жодної дії
    # (ані стартів, ані Clear, ані issues).
    $replacedQuiescenceMarker = $orphanedQuiescenceMarker.PSObject.Copy()
    $replacedQuiescenceMarker.pid = 54321
    $replacedQuiescenceMarker.createdAt = '2026-08-21T03:00:00.0000000+03:00'
    $markerReplacedScenario = & $quiescenceWatchdogModule {
        param($State, $Replacement)
        Invoke-BRAVOSelfTestQuiescenceScenario -State $State -OwnerAlive $false -StartFailures @() -ReadQueue @($State, $Replacement)
    } $orphanedQuiescenceMarker $replacedQuiescenceMarker
    $markerVanishedScenario = & $quiescenceWatchdogModule {
        param($State)
        Invoke-BRAVOSelfTestQuiescenceScenario -State $State -OwnerAlive $false -StartFailures @() -ReadQueue @($State, $null)
    } $orphanedQuiescenceMarker
    Test-BRAVOCondition `
        -Condition (
            @($markerReplacedScenario.StartedServices).Count -eq 0 -and
            $markerReplacedScenario.MarkerCleared -eq $false -and
            @($markerReplacedScenario.Issues).Count -eq 0 -and
            @($markerVanishedScenario.StartedServices).Count -eq 0 -and
            $markerVanishedScenario.MarkerCleared -eq $false -and
            @($markerVanishedScenario.Issues).Count -eq 0
        ) `
        -Name "ServiceQuiescence/WatchdogAbortsWhenMarkerReplacedOrVanishedBeforeStart" `
        -Failure "TOCTOU: маркер перезаписано новим власником або зник перед Start-Service — watchdog не стартує, не чистить, не створює issues"

    # (є) РЕГРЕСІЯ (review F4): маркер вимагає службу поза канонічним
    # керованим набором конфігурації (підкинутий/відредагований файл) —
    # watchdog МУСИТЬ відмовити саме їй, лишити маркер і зробити відмову
    # видимою оператору; легітимні служби з маркера стартують.
    $tamperedQuiescenceMarker = $orphanedQuiescenceMarker.PSObject.Copy()
    $tamperedQuiescenceMarker.services = @(
        [pscustomobject]@{ Name = 'BRAVO'; RestartIntent = $true },
        [pscustomobject]@{ Name = 'EvilSvc'; RestartIntent = $true }
    )
    $tamperedMarkerScenario = & $quiescenceWatchdogModule {
        param($State)
        Invoke-BRAVOSelfTestQuiescenceScenario -State $State -OwnerAlive $false -StartFailures @()
    } $tamperedQuiescenceMarker
    Test-BRAVOCondition `
        -Condition (
            @($tamperedMarkerScenario.StartedServices).Count -eq 1 -and
            @($tamperedMarkerScenario.StartedServices) -contains 'BRAVO' -and
            $tamperedMarkerScenario.MarkerCleared -eq $false -and
            @($tamperedMarkerScenario.Issues).Count -eq 1 -and
            [string]$tamperedMarkerScenario.Issues[0].Reason -match 'EvilSvc' -and
            [string]$tamperedMarkerScenario.Issues[0].Reason -match 'не входить до керованого набору'
        ) `
        -Name "ServiceQuiescence/WatchdogRefusesServiceOutsideManagedSet" `
        -Failure "служба поза керованим набором конфігурації: відмова у старті, маркер лишається, issue називає відхилену службу"

    # (ж) РЕГРЕСІЯ (review F4, fail-safe): порожній керований набір
    # (конфігурація недоступна) — жодного старту взагалі.
    $emptyAllowedScenario = & $quiescenceWatchdogModule {
        param($State)
        Invoke-BRAVOSelfTestQuiescenceScenario -State $State -OwnerAlive $false -StartFailures @() -AllowedServices @()
    } $orphanedQuiescenceMarker
    Test-BRAVOCondition `
        -Condition (
            @($emptyAllowedScenario.StartedServices).Count -eq 0 -and
            $emptyAllowedScenario.MarkerCleared -eq $false -and
            @($emptyAllowedScenario.Issues).Count -eq 1
        ) `
        -Name "ServiceQuiescence/WatchdogRefusesAllWhenManagedSetUnavailable" `
        -Failure "без керованого набору конфігурації watchdog не має права стартувати жодну службу (fail-safe)"

    # (з) РЕГРЕСІЯ (review F5): службу, що вже працює, НЕ рапортуємо як
    # «відновлену» — оператор має бачити фактичний масштаб аварії; маркер
    # при цьому прибирається (мета — служби працюють — досягнута).
    $alreadyRunningScenario = & $quiescenceWatchdogModule {
        param($State)
        Invoke-BRAVOSelfTestQuiescenceScenario -State $State -OwnerAlive $false -StartFailures @() -RunningServices @('BRAVO')
    } $orphanedQuiescenceMarker
    Test-BRAVOCondition `
        -Condition (
            @($alreadyRunningScenario.StartedServices).Count -eq 1 -and
            @($alreadyRunningScenario.StartedServices) -contains 'exchangAPI' -and
            -not (@($alreadyRunningScenario.StartedServices) -contains 'BRAVO') -and
            $alreadyRunningScenario.MarkerCleared -eq $true -and
            @($alreadyRunningScenario.Issues).Count -eq 1 -and
            [string]$alreadyRunningScenario.Issues[0].Reason -match 'відновлено автоматично' -and
            [string]$alreadyRunningScenario.Issues[0].Reason -match 'вже працювали'
        ) `
        -Name "ServiceQuiescence/WatchdogDoesNotReportAlreadyRunningAsRecovered" `
        -Failure "вже запущена служба не потрапляє у «відновлено автоматично»; issue розділяє відновлені та ті, що вже працювали"

    # ============================================================
    # Реальний хелпер білого списку (review F4): резолюція канонічного
    # керованого набору з maintenanceSettings.Services — імена BRAVO/
    # exchangAPI напряму, BravoWeb через кандидатів (Name і DisplayName);
    # відсутня конфігурація -> порожній список (fail-safe).
    # ============================================================
    $allowedNamesStubs = @'
function Test-BRAVOSettingEnabled { param($Value) return [bool]$Value }
function Get-Service {
    param([string]$Name, [string]$DisplayName, $ErrorAction)
    if ($PSBoundParameters.ContainsKey('Name') -and $Name -eq 'Apache2.4') {
        return [pscustomobject]@{ Name = 'Apache2.4' }
    }
    if ($PSBoundParameters.ContainsKey('DisplayName') -and $DisplayName -eq 'BRAVO Web Display') {
        return [pscustomobject]@{ Name = 'ApacheByDisplay' }
    }
    return $null
}
'@
    $allowedNamesModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($allowedNamesStubs + "`n" + $healthRuntimeTextForQuiescence) `
        -FunctionNames @(
            'Test-BRAVOSettingEnabled',
            'Get-Service',
            'Get-BRAVOQuiescenceWatchdogAllowedServiceNames'
        )
    $resolvedAllowedNames = & $allowedNamesModule {
        $script:maintenanceSettings = @{
            Services = @{
                BravoName = 'BRAVO'
                ExchangeApiName = 'exchangAPI'
                BravoWebEnabled = $true
                BravoWebCandidates = @('NoSuchSvc', 'BRAVO Web Display', 'Apache2.4')
            }
        }
        Get-BRAVOQuiescenceWatchdogAllowedServiceNames
    }
    $absentConfigAllowedNames = & $allowedNamesModule {
        # Явний null у module-scope: перекриває можливий global
        # $maintenanceSettings із сесії self-test.
        $script:maintenanceSettings = $null
        Get-BRAVOQuiescenceWatchdogAllowedServiceNames
    }
    Test-BRAVOCondition `
        -Condition (
            @($resolvedAllowedNames).Count -eq 4 -and
            @($resolvedAllowedNames) -contains 'BRAVO' -and
            @($resolvedAllowedNames) -contains 'exchangAPI' -and
            @($resolvedAllowedNames) -contains 'ApacheByDisplay' -and
            @($resolvedAllowedNames) -contains 'Apache2.4' -and
            -not (@($resolvedAllowedNames) -contains 'NoSuchSvc') -and
            @($absentConfigAllowedNames).Count -eq 0
        ) `
        -Name "ServiceQuiescence/AllowedServiceNamesResolveFromCanonicalConfigOnly" `
        -Failure "білий список: BravoName/ExchangeApiName + резолвлені web-кандидати (Name і DisplayName), нерозв'язні кандидати відкинуті; без конфігурації — порожній"

    # ============================================================
    # Protect-BRAVOMachineStateRoot (review F4): зміцнення ACL
    # State-кореня — на ІЗОЛЬОВАНОМУ TEMP-каталозі, реальний
    # %ProgramData% не торкається (-Path).
    # ============================================================
    $stateAclTestRoot = Join-Path ([IO.Path]::GetTempPath()) (
        "bravo_selftest_stateacl_{0}" -f ([guid]::NewGuid().ToString("N"))
    )
    [void][IO.Directory]::CreateDirectory($stateAclTestRoot)
    try {
        $stateAclCheckBefore = & $quiescenceStateModule {
            param($Path)
            Protect-BRAVOMachineStateRoot -CheckOnly -Path $Path
        } $stateAclTestRoot
        $stateAclApplyResult = & $quiescenceStateModule {
            param($Path)
            Protect-BRAVOMachineStateRoot -Path $Path
        } $stateAclTestRoot
        $stateAclSecondApplyResult = & $quiescenceStateModule {
            param($Path)
            Protect-BRAVOMachineStateRoot -Path $Path
        } $stateAclTestRoot
        $stateAclAfterApply = Get-Acl -LiteralPath $stateAclTestRoot
        $stateAclIdentitySids = @($stateAclAfterApply.Access | ForEach-Object {
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        } | Sort-Object -Unique)
        Test-BRAVOCondition `
            -Condition (
                $stateAclCheckBefore.Compliant -eq $false -and
                $stateAclCheckBefore.Applied -eq $false -and
                $stateAclApplyResult.Applied -eq $true -and
                $stateAclSecondApplyResult.Compliant -eq $true -and
                $stateAclSecondApplyResult.Applied -eq $false -and
                $stateAclAfterApply.AreAccessRulesProtected -eq $true -and
                @($stateAclIdentitySids).Count -eq 2 -and
                @($stateAclIdentitySids) -contains 'S-1-5-18' -and
                @($stateAclIdentitySids) -contains 'S-1-5-32-544'
            ) `
            -Name "ServiceQuiescence/ProtectStateRootDisablesInheritanceAndLimitsToSystemAndAdmins" `
            -Failure "Protect-BRAVOMachineStateRoot: CheckOnly не змінює, apply вимикає успадкування і лишає лише SYSTEM+Administrators, повторний apply ідемпотентний"
    } finally {
        Remove-Item -LiteralPath $stateAclTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

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
    # РЕГРЕСІЯ (#64 review, п.1): деструктивна фаза реставрації моделі
    # (bravocmd) має проходити під suppressed-маркером — жорсткий kill
    # посеред bravocmd НЕ повинен дати watchdog-у автостартувати служби
    # поверх напіввідновленої моделі; після повернення консистентності
    # (успіх без критичних змін або довершений відкат) suppression
    # знімається хелпером Restore-BRAVOMaintenanceQuiescenceAutostart.
    $maintenanceSuppressIndex = $maintenanceRuntimeTextForQuiescence.IndexOf('Set-BRAVOServiceQuiescenceRestartSuppressed')
    $maintenanceBravocmdIndex = $maintenanceRuntimeTextForQuiescence.IndexOf('Виконання реставрації моделі LIMS')
    $maintenanceUnsuppressHelperIndex = $maintenanceRuntimeTextForQuiescence.IndexOf('function Restore-BRAVOMaintenanceQuiescenceAutostart')
    $maintenanceUnsuppressLastCallIndex = $maintenanceRuntimeTextForQuiescence.LastIndexOf('Restore-BRAVOMaintenanceQuiescenceAutostart')
    $maintenanceUnsuppressHelperBlock = if ($maintenanceUnsuppressHelperIndex -ge 0) {
        $maintenanceRuntimeTextForQuiescence.Substring($maintenanceUnsuppressHelperIndex, 1400)
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $maintenanceSuppressIndex -ge 0 -and
            $maintenanceBravocmdIndex -ge 0 -and
            $maintenanceSuppressIndex -lt $maintenanceBravocmdIndex -and
            $maintenanceUnsuppressHelperIndex -ge 0 -and
            $maintenanceUnsuppressLastCallIndex -gt $maintenanceBravocmdIndex -and
            $maintenanceUnsuppressHelperBlock.Contains('Write-BRAVOServiceQuiescenceState') -and
            -not $maintenanceUnsuppressHelperBlock.Contains('-RestartSuppressed')
        ) `
        -Name "ServiceQuiescence/MaintenanceSuppressesMarkerAroundDestructiveModelRestore" `
        -Failure "Maintenance має переводити маркер у suppressed ДО bravocmd і знімати suppression (helper без -RestartSuppressed) лише ПІСЛЯ повернення консистентності моделі"
    # РЕГРЕСІЯ (#64 review, п.2): у boot-профілі робочого часу «hold» —
    # детермінований кінцевий стан: усі УВІМКНЕНІ керовані служби входять
    # у зупинку/маркер/restart-intent незалежно від того, чи встигли вони
    # піднятися на момент знімка (інакше SCM стартував би delayed-службу
    # посеред деструктивної фази, а маркер її не покривав би).
    Test-BRAVOCondition `
        -Condition (
            $maintenanceRuntimeTextForQuiescence.Contains('if ($bootRestoreIgnoresWindow) {') -and
            $maintenanceRuntimeTextForQuiescence.Contains('$serviceWasRunning.Bravo = $BravoMaintenanceEnabled') -and
            $maintenanceRuntimeTextForQuiescence.Contains('$serviceWasRunning.ExchangeApi = $exchangAPIServiceEnabled') -and
            $maintenanceRuntimeTextForQuiescence.Contains('$serviceWasRunning.BravoWeb = $BravoWebMaintenanceEnabled')
        ) `
        -Name "ServiceQuiescence/MaintenanceBootHoldForcesManagedServicesIntoQuiescenceScope" `
        -Failure "boot-профіль (bootRestoreIgnoresWindow) має примусово включати всі увімкнені керовані служби у зупинку/маркер/restart-intent"
    # РЕГРЕСІЯ (#64 review, п.3): знімок стану служб рахує StartPending як
    # «працювала» — інакше служба, що саме стартує, була б зупинена без
    # restart-intent і лишилася лежати після обслуговування.
    Test-BRAVOCondition `
        -Condition (
            @([regex]::Matches(
                $maintenanceRuntimeTextForQuiescence,
                [regex]::Escape("-in @('Running', 'StartPending')")
            )).Count -eq 3
        ) `
        -Name "ServiceQuiescence/MaintenanceServiceSnapshotIncludesStartPending" `
        -Failure "усі три перевірки знімка служб Maintenance мають рахувати StartPending нарівні з Running"
    # РЕГРЕСІЯ (review F1): маркер Maintenance МУСИТЬ лишатися придатним до
    # автостарту (робота Maintenance між stop/start не змінює live
    # filesystem) — жодного -RestartSuppressed у його виклику запису.
    $maintenanceMarkerWriteBlock = $maintenanceRuntimeTextForQuiescence.Substring(
        $maintenanceRuntimeTextForQuiescence.IndexOf("-Owner 'BRAVO_MAINTENANCE'"), 300)
    Test-BRAVOCondition `
        -Condition (-not $maintenanceMarkerWriteBlock.Contains('-RestartSuppressed')) `
        -Name "ServiceQuiescence/MaintenanceMarkerAllowsWatchdogAutostart" `
        -Failure "маркер Maintenance не має писатися з -RestartSuppressed: автостарт після жорсткого kill Maintenance безпечний і обов'язковий"

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
        -Failure "DataRestore має писати маркер при зупинці служб і підтверджувати restartSuppressed у гілці неповного rollback"
    # РЕГРЕСІЯ (review F1, БЛОКЕР): маркер DataRestore МУСИТЬ писатися
    # -RestartSuppressed від самого створення. Інакше жорсткий kill посеред
    # деструктивної фази (finally не виконується, suppression ніхто не
    # виставить) призвів би до автостарту служб watchdog-ом поверх
    # напіввідновленої live filesystem.
    $dataRestoreMarkerWriteBlock = $dataRestoreRuntimeTextForQuiescence.Substring(
        $dataRestoreRuntimeTextForQuiescence.IndexOf("-Owner 'BRAVO_DATA_RESTORE'"), 500)
    Test-BRAVOCondition `
        -Condition ($dataRestoreMarkerWriteBlock.Contains('-RestartSuppressed')) `
        -Name "ServiceQuiescence/DataRestoreMarkerIsSuppressedFromCreation" `
        -Failure "маркер DataRestore має писатися одразу з -RestartSuppressed: автостарт поверх невизначеної live filesystem заборонено навіть після жорсткого kill"

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

    # Review F4: SETUP має зміцнювати ACL State-кореня (apply з адмін-правами,
    # CheckOnly для ValidateOnly/неелевованого прогону), а watchdog —
    # фільтрувати служби маркера через канонічний білий список.
    $setupTextForQuiescence = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_SETUP.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $setupTextForQuiescence.Contains('Protect-BRAVOMachineStateRoot') -and
            $setupTextForQuiescence.Contains('Protect-BRAVOMachineStateRoot -CheckOnly')
        ) `
        -Name "ServiceQuiescence/SetupHardensStateRootAcl" `
        -Failure "BRAVO_SETUP.ps1 має викликати Protect-BRAVOMachineStateRoot (apply + CheckOnly-гілка)"
    $watchdogFunctionBlock = $healthRuntimeTextForQuiescence.Substring(
        $healthRuntimeTextForQuiescence.IndexOf('function Invoke-BRAVOServiceQuiescenceWatchdog'))
    Test-BRAVOCondition `
        -Condition ($watchdogFunctionBlock.Contains('Get-BRAVOQuiescenceWatchdogAllowedServiceNames')) `
        -Name "ServiceQuiescence/WatchdogConsultsManagedServiceWhitelist" `
        -Failure "watchdog має фільтрувати служби маркера через Get-BRAVOQuiescenceWatchdogAllowedServiceNames перед Start-Service"
