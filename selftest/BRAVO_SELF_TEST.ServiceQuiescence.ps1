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
    $maintenanceBravocmdIndex = $maintenanceRuntimeTextForQuiescence.IndexOf('Виконання реставрації моделі ($MODEL_NAME)')
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

    # Get-ManagedServiceHealthIssues під StrictMode 2.0: ServiceController без
    # StartType (.NET < 4.6.1) не має обривати Health винятком, а тип запуску
    # має братись із WMI-fallback (Disabled -> службу пропущено).
    # ServiceControllerStatus (System.ServiceProcess) не завжди завантажений
    # у процесі self-test; і stub, і production-порівняння Status його потребують.
    Add-Type -AssemblyName System.ServiceProcess
    $startTypeStubs = @'
function Write-HealthLog { param($Message, $Level) }
function Get-Service {
    param($Name, $DisplayName, $ErrorAction)
    $svc = [pscustomobject]@{ Name = [string]$Name; Status = [System.ServiceProcess.ServiceControllerStatus]::Stopped }
    # Сучасний .NET (>= 4.6.1): ServiceController має StartType.
    if ([string]$Name -eq 'BravoStartTypeDisabled') { Add-Member -InputObject $svc -MemberType NoteProperty -Name StartType -Value 'Disabled' }
    if ([string]$Name -eq 'BravoStartTypeAutomatic') { Add-Member -InputObject $svc -MemberType NoteProperty -Name StartType -Value 'Automatic' }
    Add-Member -InputObject $svc -MemberType ScriptMethod -Name Refresh -Value { } -Force
    return $svc
}
function Get-BRAVOWmiInstance {
    param($ClassName)
    if ($script:startTypeWmiFails) { throw 'WMI недоступний (stub)' }
    return @(
        [pscustomobject]@{ Name = 'BravoDisabled'; StartMode = 'Disabled' },
        [pscustomobject]@{ Name = 'BravoAuto'; StartMode = 'Auto' },
        [pscustomobject]@{ Name = 'BravoStartTypeDisabled'; StartMode = 'Auto' },
        [pscustomobject]@{ Name = 'BravoStartTypeAutomatic'; StartMode = 'Disabled' }
    )
}
'@
    $startTypeModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($startTypeStubs + "`n" + $healthRuntimeTextForQuiescence) `
        -FunctionNames @('Write-HealthLog', 'Get-Service', 'Get-BRAVOWmiInstance', 'Test-BRAVOSettingEnabled', 'Get-ManagedServiceHealthIssues')
    $startTypeProbe = {
        param($ServiceName, [bool]$WmiFails = $false)
        Set-StrictMode -Version 2.0
        $script:startTypeWmiFails = $WmiFails
        $script:backupMonitoring = @{ CheckManagedServices = $true }
        $script:maintenanceSettings = [pscustomobject]@{
            Services = [pscustomobject]@{ BravoName = $ServiceName; ExchangeApiName = ''; BravoWebEnabled = $false; BravoWebCandidates = @() }
        }
        $thrown = $null
        $issues = @()
        try { $issues = @(Get-ManagedServiceHealthIssues) } catch { $thrown = $_.Exception.Message }
        [pscustomobject]@{ Thrown = $thrown; IssueCount = @($issues).Count }
    }
    $startTypeDisabled = & $startTypeModule $startTypeProbe 'BravoDisabled'
    $startTypeAuto = & $startTypeModule $startTypeProbe 'BravoAuto'
    Test-BRAVOCondition `
        -Condition (
            $null -eq $startTypeDisabled.Thrown -and $startTypeDisabled.IssueCount -eq 0 -and
            $null -eq $startTypeAuto.Thrown -and $startTypeAuto.IssueCount -eq 1
        ) `
        -Name "Health/ManagedServiceStartTypeMissingDoesNotThrowUnderStrictMode" `
        -Failure "Get-ManagedServiceHealthIssues має читати StartType через PSObject.Properties: ServiceController без StartType (.NET < 4.6.1) не повинен кидати виняток під StrictMode 2.0, а тип запуску має братись із WMI (Disabled -> пропуск, Auto -> проблема). Отримано: Disabled(Thrown='$($startTypeDisabled.Thrown)', Issues=$($startTypeDisabled.IssueCount)), Auto(Thrown='$($startTypeAuto.Thrown)', Issues=$($startTypeAuto.IssueCount))"

    # Решта матриці #295: наявний StartType має пріоритет над WMI (обидва
    # напрями), а збій WMI без StartType не обриває Health — служба
    # перевіряється як не-Disabled.
    $startTypePresentDisabled = & $startTypeModule $startTypeProbe 'BravoStartTypeDisabled'
    $startTypePresentAutomatic = & $startTypeModule $startTypeProbe 'BravoStartTypeAutomatic'
    $startTypeWmiFailure = & $startTypeModule $startTypeProbe 'BravoAuto' $true
    Test-BRAVOCondition `
        -Condition (
            $null -eq $startTypePresentDisabled.Thrown -and $startTypePresentDisabled.IssueCount -eq 0 -and
            $null -eq $startTypePresentAutomatic.Thrown -and $startTypePresentAutomatic.IssueCount -eq 1 -and
            $null -eq $startTypeWmiFailure.Thrown -and $startTypeWmiFailure.IssueCount -eq 1
        ) `
        -Name "Health/ManagedServiceStartTypePresentAndWmiFailureUnderStrictMode" `
        -Failure "Get-ManagedServiceHealthIssues під StrictMode 2.0: наявний StartType має пріоритет над WMI (Disabled -> пропуск, Automatic -> проблема), а збій WMI без StartType не кидає виняток. Отримано: StartType=Disabled(Thrown='$($startTypePresentDisabled.Thrown)', Issues=$($startTypePresentDisabled.IssueCount)), StartType=Automatic(Thrown='$($startTypePresentAutomatic.Thrown)', Issues=$($startTypePresentAutomatic.IssueCount)), WMI-збій(Thrown='$($startTypeWmiFailure.Thrown)', Issues=$($startTypeWmiFailure.IssueCount))"

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

    & {
    # --- #319: ServiceController.StartType існує лише з .NET Framework 4.6.1.
    # Під Set-StrictMode -Version 2.0 пряме звернення до відсутньої властивості
    # кидає PropertyNotFoundStrict. Усі місця читання типу запуску мають іти
    # через канонічний Get-BRAVOServiceStartMode (BRAVO.System). Службовий
    # об'єкт у stub-ах — PSCustomObject БЕЗ StartType (як ServiceController на
    # .NET < 4.6.1); WMI керується прапорцями $script:svcWmi*.
    $startModeIssueSystemText = $systemModuleTextForQuiescence
    $startModeIssueMaintenanceText = [IO.File]::ReadAllText((Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"), [Text.Encoding]::UTF8)
    $startModeIssueDataRestoreText = [IO.File]::ReadAllText((Join-Path $root "modules\BRAVO.DataRestore\BRAVO.DataRestore.Runtime.ps1"), [Text.Encoding]::UTF8)
    $startModeIssueDryRunText = [IO.File]::ReadAllText((Join-Path $root "BRAVO_DRY_RUN.ps1"), [Text.Encoding]::UTF8)
    # Порядок у -SourceText: спершу текст runtime (його param() має бути першим
    # оператором), потім stub-и й BRAVO.System.
    $startModeIssueStubs = @'
function Get-Service {
    param($Name, $ErrorAction)
    $svc = [pscustomobject]@{ Name = [string]$Name; DisplayName = [string]$Name; Status = 'Running' }
    if ($script:svcStartType) { Add-Member -InputObject $svc -MemberType NoteProperty -Name StartType -Value $script:svcStartType }
    return $svc
}
function Get-BRAVOWmiInstance {
    param($ClassName, $Filter)
    $script:svcWmiCalls = 1 + [int]$script:svcWmiCalls
    if ($script:svcWmiFails) { throw 'WMI недоступний (stub)' }
    if ([string]::IsNullOrEmpty($script:svcWmiMode)) { return @() }
    return @([pscustomobject]@{ Name = 'SvcProbe'; StartMode = $script:svcWmiMode })
}
function Get-BRAVOServiceDelayedAutoStart { param($ServiceName) return $false }
'@
    # Сценарії: StartType службового об'єкта ($null = властивості немає),
    # WMI StartMode, чи падає WMI.
    $startModeScenarios = [ordered]@{
        NoST_WmiDisabled   = @{ ST = $null;        Wmi = 'Disabled'; Fail = $false }
        NoST_WmiAuto       = @{ ST = $null;        Wmi = 'Auto';     Fail = $false }
        NoST_WmiManual     = @{ ST = $null;        Wmi = 'Manual';   Fail = $false }
        NoST_WmiFails      = @{ ST = $null;        Wmi = $null;      Fail = $true }
        STDisabled_WmiAuto = @{ ST = 'Disabled';   Wmi = 'Auto';     Fail = $false }
        STAuto_WmiDisabled = @{ ST = 'Automatic';  Wmi = 'Disabled'; Fail = $false }
        STDisabled_WmiFail = @{ ST = 'Disabled';   Wmi = $null;      Fail = $true }
        STAuto_WmiFails    = @{ ST = 'Automatic';  Wmi = $null;      Fail = $true }
    }

    # 1) Юніт-тести канонічного helper-а (нормалізація, пріоритет джерел, Unknown).
    $startModeHelperModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($startModeIssueStubs + "`n" + $startModeIssueSystemText) `
        -FunctionNames @('Get-Service', 'Get-BRAVOWmiInstance', 'Get-BRAVOServiceStartMode')
    $startModeHelperProbe = & $startModeHelperModule {
        Set-StrictMode -Version 2.0
        $out = [ordered]@{}
        $run = {
            param($Key, $Service, $WmiMode, [bool]$WmiFails, $Fallback, [bool]$NoWmi)
            $script:svcWmiMode = $WmiMode; $script:svcWmiFails = $WmiFails; $script:svcWmiCalls = 0
            $thrown = $null; $r = $null
            try {
                if ($NoWmi) { $r = Get-BRAVOServiceStartMode -Service $Service -FallbackStartMode $Fallback -NoWmiQuery }
                else { $r = Get-BRAVOServiceStartMode -Service $Service -FallbackStartMode $Fallback }
            } catch { $thrown = $_.Exception.Message }
            $out[$Key] = if ($null -ne $thrown) { "THROW:$thrown" } else { '{0}/{1}/{2}/calls={3}' -f $r.StartMode, $r.Source, [bool]$r.FailureReason, $script:svcWmiCalls }
        }
        $withST = { param($v) [pscustomobject]@{ Name = 'SvcProbe'; StartType = $v } }
        $noST = [pscustomobject]@{ Name = 'SvcProbe' }
        & $run 'ST_Automatic' (& $withST 'Automatic') 'Disabled' $false $null $false
        & $run 'ST_Manual' (& $withST 'Manual') 'Auto' $false $null $false
        & $run 'ST_Disabled_beats_WMI' (& $withST 'Disabled') 'Auto' $false $null $false
        & $run 'ST_Auto_alias' (& $withST 'Auto') $null $false $null $false
        & $run 'NoST_WmiAuto' $noST 'Auto' $false $null $false
        & $run 'NoST_WmiManual' $noST 'Manual' $false $null $false
        & $run 'NoST_WmiDisabled' $noST 'Disabled' $false $null $false
        & $run 'NoST_WmiFails' $noST $null $true $null $false
        & $run 'NoST_WmiEmpty' $noST $null $false $null $false
        & $run 'NoST_WmiUnrecognized' $noST 'Boot' $false $null $false
        & $run 'NoST_Fallback_noQuery' $noST 'Disabled' $false 'Manual' $false
        & $run 'NoST_NoWmiQuery' $noST 'Disabled' $false $null $true
        & $run 'ST_Blank_WmiAuto' (& $withST '') 'Auto' $false $null $false
        & $run 'ST_Unrecognized_WmiManual' (& $withST 'Boot') 'Manual' $false $null $false
        & $run 'NullService' $null 'Auto' $false $null $false
        $out
    }
    $startModeHelperExpected = [ordered]@{
        ST_Automatic = 'Automatic/StartType/False/calls=0'
        ST_Manual = 'Manual/StartType/False/calls=0'
        ST_Disabled_beats_WMI = 'Disabled/StartType/False/calls=0'
        ST_Auto_alias = 'Automatic/StartType/False/calls=0'
        NoST_WmiAuto = 'Automatic/WMI/False/calls=1'
        NoST_WmiManual = 'Manual/WMI/False/calls=1'
        NoST_WmiDisabled = 'Disabled/WMI/False/calls=1'
        NoST_WmiFails = 'Unknown/None/True/calls=1'
        NoST_WmiEmpty = 'Unknown/None/True/calls=1'
        NoST_WmiUnrecognized = 'Unknown/None/True/calls=1'
        NoST_Fallback_noQuery = 'Manual/FallbackStartMode/False/calls=0'
        NoST_NoWmiQuery = 'Unknown/None/True/calls=0'
        ST_Blank_WmiAuto = 'Automatic/WMI/False/calls=1'
        ST_Unrecognized_WmiManual = 'Manual/WMI/False/calls=1'
        NullService = 'Unknown/None/True/calls=0'
    }
    $startModeHelperDiffs = @($startModeHelperExpected.Keys | Where-Object { [string]$startModeHelperProbe[$_] -ne [string]$startModeHelperExpected[$_] } |
        ForEach-Object { "$_ => '$($startModeHelperProbe[$_])' (очікувалось '$($startModeHelperExpected[$_])')" })
    Test-BRAVOCondition `
        -Condition ($startModeHelperDiffs.Count -eq 0) `
        -Name "ServiceStartMode/HelperNormalizationPrecedenceAndUnknown" `
        -Failure "Get-BRAVOServiceStartMode під StrictMode 2.0: нормалізація (Auto->Automatic), пріоритет StartType над WMI, WMI/Fallback без StartType, Unknown + FailureReason замість винятку. Розбіжності: $($startModeHelperDiffs -join ' | ')"

    # 2) Maintenance: Get-ConfiguredServiceState (fallback після збою WMI) і
    # Test-BRAVOServiceDisabledBySystem (верхній рівень, безумовне читання).
    $startModeMaintenanceModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($startModeIssueMaintenanceText + "`n" + $startModeIssueStubs + "`n" + $startModeIssueSystemText) `
        -FunctionNames @('Get-Service', 'Get-BRAVOWmiInstance', 'Get-BRAVOServiceStartMode', 'Get-ConfiguredServiceState', 'Test-BRAVOServiceDisabledBySystem')
    $startModeMaintenanceProbe = & $startModeMaintenanceModule {
        param($Scenarios)
        Set-StrictMode -Version 2.0
        $out = [ordered]@{}
        foreach ($key in $Scenarios.Keys) {
            $s = $Scenarios[$key]
            $script:svcStartType = $s.ST; $script:svcWmiMode = $s.Wmi; $script:svcWmiFails = $s.Fail; $script:svcWmiCalls = 0
            $thrown = $null; $state = $null
            try { $state = Get-ConfiguredServiceState -Name 'SvcProbe' } catch { $thrown = $_.Exception.Message }
            $out["State_$key"] = if ($null -ne $thrown) { "THROW:$thrown" } else { 'Exists={0},Disabled={1},Enabled={2}' -f $state.Exists, $state.Disabled, $state.Enabled }
        }
        foreach ($case in @(
            @{ K = 'Top_NoST_CimEmpty'; ST = $null; Cim = '' },
            @{ K = 'Top_NoST_CimDisabled'; ST = $null; Cim = 'Disabled' },
            @{ K = 'Top_NoST_CimAuto'; ST = $null; Cim = 'Auto' },
            @{ K = 'Top_STDisabled_CimEmpty'; ST = 'Disabled'; Cim = '' },
            @{ K = 'Top_STAuto_CimEmpty'; ST = 'Automatic'; Cim = '' }
        )) {
            $script:svcStartType = $case.ST; $script:svcWmiCalls = 0
            $svc = Get-Service -Name 'SvcProbe'
            $thrown = $null; $disabled = $null
            try { $disabled = Test-BRAVOServiceDisabledBySystem -Service $svc -CimStartMode $case.Cim } catch { $thrown = $_.Exception.Message }
            $out[$case.K] = if ($null -ne $thrown) { "THROW:$thrown" } else { "Disabled=$disabled,calls=$($script:svcWmiCalls)" }
        }
        $out
    } $startModeScenarios
    $startModeMaintenanceExpected = [ordered]@{
        State_NoST_WmiDisabled = 'Exists=True,Disabled=True,Enabled=False'
        State_NoST_WmiAuto = 'Exists=True,Disabled=False,Enabled=True'
        State_NoST_WmiManual = 'Exists=True,Disabled=False,Enabled=True'
        State_NoST_WmiFails = 'Exists=True,Disabled=False,Enabled=True'
        State_STDisabled_WmiAuto = 'Exists=True,Disabled=False,Enabled=True'
        State_STAuto_WmiDisabled = 'Exists=True,Disabled=True,Enabled=False'
        State_STDisabled_WmiFail = 'Exists=True,Disabled=True,Enabled=False'
        State_STAuto_WmiFails = 'Exists=True,Disabled=False,Enabled=True'
        Top_NoST_CimEmpty = 'Disabled=False,calls=0'
        Top_NoST_CimDisabled = 'Disabled=True,calls=0'
        Top_NoST_CimAuto = 'Disabled=False,calls=0'
        Top_STDisabled_CimEmpty = 'Disabled=True,calls=0'
        Top_STAuto_CimEmpty = 'Disabled=False,calls=0'
    }
    $startModeMaintenanceDiffs = @($startModeMaintenanceExpected.Keys | Where-Object { [string]$startModeMaintenanceProbe[$_] -ne [string]$startModeMaintenanceExpected[$_] } |
        ForEach-Object { "$_ => '$($startModeMaintenanceProbe[$_])' (очікувалось '$($startModeMaintenanceExpected[$_])')" })
    Test-BRAVOCondition `
        -Condition ($startModeMaintenanceDiffs.Count -eq 0) `
        -Name "Maintenance/ServiceStartTypeMissingDoesNotThrowUnderStrictMode" `
        -Failure "Maintenance (Get-ConfiguredServiceState і визначення BravoWeb Disabled): служба без StartType (.NET < 4.6.1) не має кидати виняток під StrictMode 2.0; WMI-збій без StartType не обриває прогін (служба вважається не-Disabled), наявний StartType читається. Розбіжності: $($startModeMaintenanceDiffs -join ' | ')"

    # 3) DataRestore: Get-BRAVODataRestoreServiceSnapshot (fallback після збою WMI).
    $startModeDataRestoreModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($startModeIssueDataRestoreText + "`n" + $startModeIssueStubs + "`n" + $startModeIssueSystemText) `
        -FunctionNames @('Get-Service', 'Get-BRAVOWmiInstance', 'Get-BRAVOServiceStartMode', 'Get-BRAVODataRestoreServiceSnapshot')
    $startModeDataRestoreProbe = & $startModeDataRestoreModule {
        param($Scenarios)
        Set-StrictMode -Version 2.0
        $out = [ordered]@{}
        foreach ($key in $Scenarios.Keys) {
            $s = $Scenarios[$key]
            $script:svcStartType = $s.ST; $script:svcWmiMode = $s.Wmi; $script:svcWmiFails = $s.Fail; $script:svcWmiCalls = 0
            $thrown = $null; $entries = @()
            try {
                $entries = @(Get-BRAVODataRestoreServiceSnapshot -ServicesSettings @{ BravoName = 'SvcProbe'; ExchangeApiName = ''; BravoWebEnabled = $false; BravoWebCandidates = @() })
            } catch { $thrown = $_.Exception.Message }
            $bravoEntry = @($entries | Where-Object { $_.Key -eq 'Bravo' }) | Select-Object -First 1
            $out[$key] = if ($null -ne $thrown) { "THROW:$thrown" } elseif ($null -eq $bravoEntry) { 'NOENTRY' } else { "Managed=$($bravoEntry.Managed)" }
        }
        $out
    } $startModeScenarios
    $startModeDataRestoreExpected = [ordered]@{
        NoST_WmiDisabled = 'Managed=False'
        NoST_WmiAuto = 'Managed=True'
        NoST_WmiManual = 'Managed=True'
        NoST_WmiFails = 'Managed=True'
        STDisabled_WmiAuto = 'Managed=True'
        STAuto_WmiDisabled = 'Managed=False'
        STDisabled_WmiFail = 'Managed=False'
        STAuto_WmiFails = 'Managed=True'
    }
    $startModeDataRestoreDiffs = @($startModeDataRestoreExpected.Keys | Where-Object { [string]$startModeDataRestoreProbe[$_] -ne [string]$startModeDataRestoreExpected[$_] } |
        ForEach-Object { "$_ => '$($startModeDataRestoreProbe[$_])' (очікувалось '$($startModeDataRestoreExpected[$_])')" })
    Test-BRAVOCondition `
        -Condition ($startModeDataRestoreDiffs.Count -eq 0) `
        -Name "DataRestore/ServiceStartTypeMissingDoesNotThrowUnderStrictMode" `
        -Failure "Get-BRAVODataRestoreServiceSnapshot: служба без StartType (.NET < 4.6.1) не має кидати виняток під StrictMode 2.0; WMI-збій без StartType не обриває знімок (служба керована), StartType=Disabled при збої WMI -> не керована. Розбіжності: $($startModeDataRestoreDiffs -join ' | ')"

    # 4) BRAVO_DRY_RUN.ps1: Get-BRAVODryRunConfiguredServiceState (StartType -> WMI).
    $startModeDryRunModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($startModeIssueDryRunText + "`n" + $startModeIssueStubs + "`n" + $startModeIssueSystemText) `
        -FunctionNames @('Get-Service', 'Get-BRAVOWmiInstance', 'Get-BRAVOServiceStartMode', 'Get-BRAVODryRunConfiguredServiceState')
    $startModeDryRunProbe = & $startModeDryRunModule {
        param($Scenarios)
        Set-StrictMode -Version 2.0
        $out = [ordered]@{}
        foreach ($key in $Scenarios.Keys) {
            $s = $Scenarios[$key]
            $script:svcStartType = $s.ST; $script:svcWmiMode = $s.Wmi; $script:svcWmiFails = $s.Fail; $script:svcWmiCalls = 0
            $thrown = $null; $state = $null
            try { $state = Get-BRAVODryRunConfiguredServiceState -ServiceCandidates @('SvcProbe') } catch { $thrown = $_.Exception.Message }
            $out[$key] = if ($null -ne $thrown) { "THROW:$thrown" } else { "Exists=$($state.Exists),Disabled=$($state.Disabled)" }
        }
        $out
    } $startModeScenarios
    $startModeDryRunExpected = [ordered]@{
        NoST_WmiDisabled = 'Exists=True,Disabled=True'
        NoST_WmiAuto = 'Exists=True,Disabled=False'
        NoST_WmiManual = 'Exists=True,Disabled=False'
        NoST_WmiFails = 'Exists=True,Disabled=False'
        STDisabled_WmiAuto = 'Exists=True,Disabled=True'
        STAuto_WmiDisabled = 'Exists=True,Disabled=False'
        STDisabled_WmiFail = 'Exists=True,Disabled=True'
        STAuto_WmiFails = 'Exists=True,Disabled=False'
    }
    $startModeDryRunDiffs = @($startModeDryRunExpected.Keys | Where-Object { [string]$startModeDryRunProbe[$_] -ne [string]$startModeDryRunExpected[$_] } |
        ForEach-Object { "$_ => '$($startModeDryRunProbe[$_])' (очікувалось '$($startModeDryRunExpected[$_])')" })
    Test-BRAVOCondition `
        -Condition ($startModeDryRunDiffs.Count -eq 0) `
        -Name "DryRun/ServiceStartTypeMissingDoesNotThrowUnderStrictMode" `
        -Failure "Get-BRAVODryRunConfiguredServiceState: служба без StartType (.NET < 4.6.1) не має кидати виняток під StrictMode 2.0, тип запуску береться з WMI, наявний StartType має пріоритет над WMI, збій WMI не обриває Dry Run. Розбіжності: $($startModeDryRunDiffs -join ' | ')"

    # 5) BRAVO.System: Set-BRAVOBootRestoreServiceStartType без StartType.
    $startModeBootRestoreModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($startModeIssueStubs + "`n" + $startModeIssueSystemText) `
        -FunctionNames @('Get-Service', 'Get-BRAVOWmiInstance', 'Get-BRAVOServiceDelayedAutoStart', 'Get-BRAVOServiceStartMode', 'Set-BRAVOBootRestoreServiceStartType')
    $startModeBootRestoreProbe = & $startModeBootRestoreModule {
        param($Scenarios)
        Set-StrictMode -Version 2.0
        $out = [ordered]@{}
        foreach ($key in $Scenarios.Keys) {
            $s = $Scenarios[$key]
            foreach ($hold in @($true, $false)) {
                $script:svcStartType = $s.ST; $script:svcWmiMode = $s.Wmi; $script:svcWmiFails = $s.Fail; $script:svcWmiCalls = 0
                $thrown = $null; $r = @()
                try { $r = @(Set-BRAVOBootRestoreServiceStartType -ServiceNames @('SvcProbe') -HoldServices $hold -ValidateOnly) } catch { $thrown = $_.Exception.Message }
                $out["${key}_Hold$hold"] = if ($null -ne $thrown) { "THROW:$thrown" } else { "$($r[0].StartType)/$($r[0].Action)/Success=$($r[0].Success)" }
            }
        }
        $out
    } $startModeScenarios
    $startModeBootRestoreExpected = [ordered]@{
        NoST_WmiDisabled_HoldTrue = 'Disabled/SkippedNotAutomatic/Success=True'
        NoST_WmiAuto_HoldTrue = 'Automatic/SetDelayedAuto/Success=True'
        NoST_WmiAuto_HoldFalse = 'Automatic/None/Success=True'
        NoST_WmiManual_HoldTrue = 'Manual/SkippedNotAutomatic/Success=True'
        NoST_WmiFails_HoldTrue = 'Unknown/SkippedUnknownStartType/Success=False'
        NoST_WmiFails_HoldFalse = 'Unknown/SkippedUnknownStartType/Success=True'
        STDisabled_WmiAuto_HoldTrue = 'Disabled/SkippedNotAutomatic/Success=True'
        STAuto_WmiDisabled_HoldTrue = 'Automatic/SetDelayedAuto/Success=True'
        STAuto_WmiFails_HoldTrue = 'Automatic/SetDelayedAuto/Success=True'
    }
    $startModeBootRestoreDiffs = @($startModeBootRestoreExpected.Keys | Where-Object {
        [string]$startModeBootRestoreProbe[$_] -ne [string]$startModeBootRestoreExpected[$_]
    } | ForEach-Object { "$_ => '$($startModeBootRestoreProbe[$_])' (очікувалось '$($startModeBootRestoreExpected[$_])')" })
    Test-BRAVOCondition `
        -Condition ($startModeBootRestoreDiffs.Count -eq 0) `
        -Name "BootRestore/ServiceStartTypeMissingUsesWmiAndFailsClosed" `
        -Failure "Set-BRAVOBootRestoreServiceStartType: служба без StartType (.NET < 4.6.1) не має кидати виняток під StrictMode 2.0; тип запуску береться з WMI; якщо невідомий і HoldServices — Success=False (SkippedUnknownStartType), у None — не збій; наявний StartType має пріоритет над WMI. Розбіжності: $($startModeBootRestoreDiffs -join ' | ')"
    }

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

    # ============================================================
    # #297: тимчасове утримання служб від автостарту на час restore
    # (start type -> Disabled, write-ahead знімок у ownership-маркері,
    # повернення у finally, самовідновлення після аварії, hard-recheck
    # перед before-archive/bravocmd). Реальні служби/sc.exe/реєстр НІКОЛИ
    # не чіпаються: Get/Set-BRAVOServiceStartMode (шви читання/запису) і
    # Get/Stop-Service затінені in-memory стабами (стаб ПЕРШИМ).
    # ============================================================
    #region #297-start-type-suppression
    & {
    $startModeStubs = @'
function Reset-BRAVOSelfTestStartModes {
    param([hashtable]$Modes, [hashtable]$Status = @{}, [string[]]$SetFailures = @(), [string[]]$StopFailures = @())
    $script:Q297Modes = $Modes.Clone()
    $script:Q297Status = $Status.Clone()
    $script:Q297SetFailures = @($SetFailures)
    $script:Q297StopFailures = @($StopFailures)
    $script:Q297SetLog = @()
    $script:Q297OwnerAlive = $false
}
function Get-BRAVOServiceRegistryStartMode {
    param([string]$ServiceName)
    if ($script:Q297Modes.ContainsKey($ServiceName)) {
        # #349: 'THROW' — збій читання реєстру (тип запуску не прочитано).
        if ([string]$script:Q297Modes[$ServiceName] -ceq 'THROW') { throw "self-test: тип запуску $ServiceName не прочитано з реєстру" }
        return [string]$script:Q297Modes[$ServiceName]
    }
    return $null
}
function Set-BRAVOServiceStartMode {
    param([string]$ServiceName, [string]$StartMode)
    $script:Q297SetLog += @("$ServiceName=$StartMode")
    if (@($script:Q297SetFailures) -contains $ServiceName) { return $false }
    $script:Q297Modes[$ServiceName] = $StartMode
    return $true
}
function Test-BRAVOProcessAlive {
    param([int]$ProcessId, [string]$ProcessStartTime)
    return [bool]$script:Q297OwnerAlive
}
function Get-Service {
    param([string]$Name, $ErrorAction)
    $status = if ($script:Q297Status.ContainsKey($Name)) { [string]$script:Q297Status[$Name] } else { 'Stopped' }
    $object = [pscustomobject]@{ Name = $Name; Status = $status }
    Add-Member -InputObject $object -MemberType ScriptMethod -Name Refresh -Value { } -Force
    return $object
}
function Stop-Service {
    param([string]$Name, [switch]$Force, $ErrorAction, $WarningAction)
    if (@($script:Q297StopFailures) -notcontains $Name) { $script:Q297Status[$Name] = 'Stopped' }
}
function Start-Sleep { param($Seconds) }
'@
    $startModeModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($quiescenceStateStubs + "`n" + $startModeStubs + "`n" + $systemModuleTextForQuiescence) `
        -FunctionNames @(
            'Get-BRAVOServiceQuiescenceStatePath',
            'Set-BRAVOSelfTestQuiescenceStatePath',
            'Reset-BRAVOSelfTestStartModes',
            'Get-BRAVOServiceRegistryStartMode',
            'Set-BRAVOServiceStartMode',
            'Test-BRAVOProcessAlive',
            'Get-Service',
            'Stop-Service',
            'Start-Sleep',
            'Protect-BRAVOMachineStateRoot',
            'Get-BRAVOCurrentProcessStartTimeText',
            'Test-BRAVOServiceQuiescenceStateOwnedByCurrentProcess',
            'Write-BRAVOStateTemporaryText',
            'Write-BRAVOStateFileAtomic',
            'Write-BRAVOServiceQuiescenceState',
            'Read-BRAVOServiceQuiescenceState',
            'Clear-BRAVOServiceQuiescenceState',
            'Set-BRAVOServiceQuiescenceRestartSuppressed',
            'New-BRAVOServiceStartTypeSnapshot',
            'Suspend-BRAVOServiceAutostart',
            'Restore-BRAVOServiceStartTypeSnapshot',
            'Repair-BRAVOOrphanedServiceStartTypes',
            'Get-BRAVOForeignServiceQuiescenceContext',
            'Confirm-BRAVOServicesQuiesced'
        )
    # New-Module імпортує заглушки в глобальну область. Заглушка Start-Sleep
    # потрібна лише всередині модуля (виклики в ньому резолвляться в модулі й
    # без глобальної копії); глобальна копія гасила справжні паузи наступних
    # suite (TraceArchive/GraceCompletionExpiry...), тож прибираємо її одразу.
    $startModeLeakedSleep = Get-Command -Name 'Start-Sleep' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $startModeLeakedSleep -and $startModeLeakedSleep.ModuleName -eq $startModeModule.Name) {
        Remove-Item -Path 'function:Start-Sleep' -Force -ErrorAction Stop
    }
    Test-BRAVOCondition `
        -Condition (
            [string](Get-Command -Name 'Start-Sleep').ModuleName -ne $startModeModule.Name -and
            [string](& $startModeModule { (Get-Command -Name 'Start-Sleep').CommandType }) -eq 'Function'
        ) `
        -Name "ServiceQuiescence/StartModeSleepStubDoesNotLeakIntoSession" `
        -Failure "заглушка Start-Sleep тестів #297 має діяти лише всередині тестового модуля, а не в сесії self-test"
    $startModeTestRoot = Join-Path ([IO.Path]::GetTempPath()) (
        "bravo_selftest_startmode_{0}" -f ([guid]::NewGuid().ToString("N"))
    )
    [void][IO.Directory]::CreateDirectory($startModeTestRoot)
    try {
        $startModeStatePath = Join-Path $startModeTestRoot 'BRAVO_SERVICE_QUIESCENCE.json'
        & $startModeModule { param($Path) Set-BRAVOSelfTestQuiescenceStatePath -Path $Path } $startModeStatePath
        $startModeManaged = @('BRAVO', 'exchangAPI', 'BravoWeb')

        # (1) Утримання застосовується ДО restore, точні початкові типи
        # (Delayed/Auto/Manual) повертаються після успіху; Disabled лишається
        # Disabled і ніколи не змінюється (жодного Set для нього).
        $suppressScenario = & $startModeModule {
            Reset-BRAVOSelfTestStartModes -Modes @{
                BRAVO = 'AutomaticDelayed'; exchangAPI = 'Automatic'; BravoWeb = 'Manual'; OperatorOff = 'Disabled'
            }
            $snapshot = @(New-BRAVOServiceStartTypeSnapshot -ServiceNames @('BRAVO', 'exchangAPI', 'BravoWeb', 'OperatorOff', 'Missing'))
            [void](Write-BRAVOServiceQuiescenceState -Owner 'BRAVO_MAINTENANCE' `
                -Services @(@{ Name = 'BRAVO'; RestartIntent = $true }) -LogFile 'C:\LOGS\m.log' -StartTypeSnapshot $snapshot)
            $suspend = Suspend-BRAVOServiceAutostart -Snapshot $snapshot
            $duringWindow = @{ BRAVO = $script:Q297Modes['BRAVO']; exchangAPI = $script:Q297Modes['exchangAPI']; BravoWeb = $script:Q297Modes['BravoWeb']; OperatorOff = $script:Q297Modes['OperatorOff'] }
            $marker = Read-BRAVOServiceQuiescenceState
            $restore = Restore-BRAVOServiceStartTypeSnapshot -Snapshot $snapshot
            [pscustomobject]@{
                SnapshotCount = $snapshot.Count; Suspend = $suspend; During = $duringWindow; Marker = $marker
                Restore = $restore; After = $script:Q297Modes.Clone(); SetLog = @($script:Q297SetLog)
            }
        }
        Test-BRAVOCondition `
            -Condition (
                $suppressScenario.SnapshotCount -eq 3 -and
                @($suppressScenario.Suspend.Failed).Count -eq 0 -and
                $suppressScenario.During.BRAVO -eq 'Disabled' -and
                $suppressScenario.During.exchangAPI -eq 'Disabled' -and
                $suppressScenario.During.BravoWeb -eq 'Disabled' -and
                $suppressScenario.During.OperatorOff -eq 'Disabled' -and
                @($suppressScenario.Marker.startTypeSnapshot).Count -eq 3 -and
                [string]$suppressScenario.Marker.startTypeSnapshot[0].StartMode -eq 'AutomaticDelayed' -and
                $suppressScenario.After.BRAVO -eq 'AutomaticDelayed' -and
                $suppressScenario.After.exchangAPI -eq 'Automatic' -and
                $suppressScenario.After.BravoWeb -eq 'Manual' -and
                $suppressScenario.After.OperatorOff -eq 'Disabled' -and
                @($suppressScenario.Restore.Failed).Count -eq 0
            ) `
            -Name "ServiceQuiescence/StartTypeSuppressedDuringWindowAndExactlyRestored" `
            -Failure "утримання: на час вікна керовані служби Disabled (знімок у маркері), після успіху точні типи (AutomaticDelayed/Automatic/Manual) повернуто"
        Test-BRAVOCondition `
            -Condition (
                @($suppressScenario.SetLog) -notcontains 'OperatorOff=Disabled' -and
                @($suppressScenario.SetLog | Where-Object { $_ -like 'OperatorOff=*' }).Count -eq 0 -and
                @($suppressScenario.SetLog | Where-Object { $_ -like 'Missing=*' }).Count -eq 0
            ) `
            -Name "ServiceQuiescence/StartTypeDisabledByOperatorNeverTouched" `
            -Failure "служба, вимкнена оператором (Disabled), і відсутня служба не потрапляють у знімок і НІКОЛИ не змінюються/не стартують"

        # (1b) #349: служба, яку Maintenance зупиняє, але яку знімок мовчки
        # пропустив (start type не прочитано / Other), не можна утримати від
        # автостарту — це збій утримання (fail-closed), а не тиха пропущена
        # служба. Disabled-оператором — легітимно поза знімком і не змінюється.
        $unrestorableMaintenanceTextSrc = [IO.File]::ReadAllText((Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"), [Text.Encoding]::UTF8)
        $unrestorableModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText ($unrestorableMaintenanceTextSrc + "`n" + $startModeStubs + "`n" + $systemModuleTextForQuiescence) `
            -FunctionNames @(
                'Reset-BRAVOSelfTestStartModes', 'Get-BRAVOServiceRegistryStartMode', 'Set-BRAVOServiceStartMode',
                'New-BRAVOServiceStartTypeSnapshot', 'Suspend-BRAVOServiceAutostart',
                'Get-BRAVOMaintenanceUnrestorableServiceNames'
            )
        $unrestorableScenario = & $unrestorableModule {
            $out = @{}
            $managed = @('BRAVO', 'exchangAPI', 'BravoWeb')
            # Нечитаний ($null: служби немає в реєстрі стабу) і Other
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Automatic'; exchangAPI = 'Other' }
            $snapshot = @(New-BRAVOServiceStartTypeSnapshot -ServiceNames $managed)
            $out.MixedSnapshotCount = $snapshot.Count
            $out.Mixed = @(Get-BRAVOMaintenanceUnrestorableServiceNames -ManagedNames $managed -Snapshot $snapshot)
            # Збій читання реєстру для служби поза знімком — теж неутримувана
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Automatic'; exchangAPI = 'THROW'; BravoWeb = 'Disabled' }
            $out.Throws = @(Get-BRAVOMaintenanceUnrestorableServiceNames -ManagedNames $managed -Snapshot @(@{ Name = 'BRAVO'; StartMode = 'Automatic' }))
            # Імена служб Windows нечутливі до регістру: запис знімка в іншому регістрі —
            # та сама служба, а не неутримувана (тип Other тут не має значення).
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Automatic'; exchangAPI = 'Other'; BravoWeb = 'Disabled' }
            $out.CaseInsensitive = @(Get-BRAVOMaintenanceUnrestorableServiceNames -ManagedNames $managed -Snapshot @(@{ Name = 'bravo'; StartMode = 'Automatic' }, @{ Name = 'EXCHANGAPI'; StartMode = 'Automatic' }))
            # Disabled оператором: без збою і лишається Disabled
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Automatic'; exchangAPI = 'Disabled'; BravoWeb = 'Manual' }
            $snapshot = @(New-BRAVOServiceStartTypeSnapshot -ServiceNames $managed)
            $out.DisabledFailures = @(Get-BRAVOMaintenanceUnrestorableServiceNames -ManagedNames $managed -Snapshot $snapshot)
            [void](Suspend-BRAVOServiceAutostart -Snapshot $snapshot)
            $out.DisabledMode = $script:Q297Modes['exchangAPI']
            $out.DisabledSetLog = @($script:Q297SetLog)
            # Усі Automatic/Manual: утримано як і раніше, збоїв немає
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Automatic'; exchangAPI = 'AutomaticDelayed'; BravoWeb = 'Manual' }
            $snapshot = @(New-BRAVOServiceStartTypeSnapshot -ServiceNames $managed)
            $out.NormalFailures = @(Get-BRAVOMaintenanceUnrestorableServiceNames -ManagedNames $managed -Snapshot $snapshot)
            $suspend = Suspend-BRAVOServiceAutostart -Snapshot $snapshot
            $out.NormalHeld = @($suspend.Applied).Count
            $out.NormalModes = @($managed | ForEach-Object { [string]$script:Q297Modes[$_] })
            [pscustomobject]$out
        }
        Test-BRAVOCondition `
            -Condition (
                $unrestorableScenario.MixedSnapshotCount -eq 1 -and
                @($unrestorableScenario.Mixed).Count -eq 2 -and
                (@($unrestorableScenario.Mixed) -join '|') -like '*exchangAPI (*Other*' -and
                (@($unrestorableScenario.Mixed) -join '|') -like '*BravoWeb (*не прочитано*' -and
                (@($unrestorableScenario.Throws) -join '|') -ceq 'exchangAPI (тип запуску: не прочитано)' -and
                @($unrestorableScenario.CaseInsensitive).Count -eq 0
            ) `
            -Name "ServiceQuiescence/MaintenanceUnreadableAndOtherStartTypeIsFailure" `
            -Failure "Maintenance (#349): служба зі start type Other, нечитаним ($null) або зі збоєм читання реєстру поза знімком має бути названа як неутримувана (fail-closed), а не тихо пропущена"
        Test-BRAVOCondition `
            -Condition (
                @($unrestorableScenario.DisabledFailures).Count -eq 0 -and
                $unrestorableScenario.DisabledMode -eq 'Disabled' -and
                @($unrestorableScenario.DisabledSetLog | Where-Object { $_ -like 'exchangAPI=*' }).Count -eq 0
            ) `
            -Name "ServiceQuiescence/MaintenanceOperatorDisabledIsNotFailureAndStaysDisabled" `
            -Failure "Maintenance (#349): служба Disabled оператором не є збоєм утримання і не змінюється"
        Test-BRAVOCondition `
            -Condition (
                @($unrestorableScenario.NormalFailures).Count -eq 0 -and
                $unrestorableScenario.NormalHeld -eq 3 -and
                (@($unrestorableScenario.NormalModes) -join ',') -ceq 'Disabled,Disabled,Disabled'
            ) `
            -Name "ServiceQuiescence/MaintenanceNormalStartTypesStillHeld" `
            -Failure "Maintenance (#349): Automatic/AutomaticDelayed/Manual без збоїв і, як і раніше, утримуються (Disabled на час вікна)"
        # Проводку перевірки в оркестрацію (ERROR -> startModeSuppressionFailures ->
        # скасування реставрації ДО архіву й bravocmd) доводять поведінкові сценарії
        # Maintenance/StartMode* у BRAVO_SELF_TEST.ps1 (справжня оркестрація).

        # (2) Збій у середині restore (виняток): finally власника повертає
        # типи. Моделюємо try/catch/finally тим самим викликом, що й
        # Maintenance (порядок «Restore перед стартом служб» — окремий
        # статичний чек нижче).
        $failureScenario = & $startModeModule {
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'AutomaticDelayed'; exchangAPI = 'Automatic' }
            $snapshot = @(New-BRAVOServiceStartTypeSnapshot -ServiceNames @('BRAVO', 'exchangAPI'))
            [void](Suspend-BRAVOServiceAutostart -Snapshot $snapshot)
            $thrown = $false
            try {
                try { throw 'self-test: bravocmd впав' } finally {
                    $script:Q297FinallyResult = Restore-BRAVOServiceStartTypeSnapshot -Snapshot $snapshot
                }
            } catch { $thrown = $true }
            [pscustomobject]@{ Thrown = $thrown; After = $script:Q297Modes.Clone(); Result = $script:Q297FinallyResult }
        }
        Test-BRAVOCondition `
            -Condition (
                $failureScenario.Thrown -and
                $failureScenario.After.BRAVO -eq 'AutomaticDelayed' -and
                $failureScenario.After.exchangAPI -eq 'Automatic' -and
                @($failureScenario.Result.Failed).Count -eq 0
            ) `
            -Name "ServiceQuiescence/StartTypeRestoredAfterRestoreFailure" `
            -Failure "після винятку посеред restore finally має повернути точні початкові типи запуску"

        # (3) Збій відновлення окремої служби не губиться: Failed непорожній
        # (викликач лишає маркер), решта служб відновлена.
        $partialRestore = & $startModeModule {
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Automatic'; exchangAPI = 'Manual' }
            $snapshot = @(New-BRAVOServiceStartTypeSnapshot -ServiceNames @('BRAVO', 'exchangAPI'))
            [void](Suspend-BRAVOServiceAutostart -Snapshot $snapshot)
            $script:Q297SetFailures = @('BRAVO')
            $result = Restore-BRAVOServiceStartTypeSnapshot -Snapshot $snapshot
            [pscustomobject]@{ Result = $result; After = $script:Q297Modes.Clone() }
        }
        Test-BRAVOCondition `
            -Condition (
                @($partialRestore.Result.Failed).Count -eq 1 -and
                [string]$partialRestore.Result.Failed[0] -match '^BRAVO:' -and
                $partialRestore.After.exchangAPI -eq 'Manual' -and
                $partialRestore.After.BRAVO -eq 'Disabled'
            ) `
            -Name "ServiceQuiescence/StartTypePartialRestoreFailureReported" `
            -Failure "збій повернення типу однієї служби має потрапити в Failed (маркер лишається), інші служби відновлюються"

        # (4) Маркер зберігає знімок через Suppress; Read відкидає зіпсовані
        # записи й нормалізує відсутнє поле (старі маркери).
        $markerScenario = & $startModeModule {
            Reset-BRAVOSelfTestStartModes -Modes @{}
            [void](Write-BRAVOServiceQuiescenceState -Owner 'BRAVO_MAINTENANCE' `
                -Services @(@{ Name = 'BRAVO'; RestartIntent = $true }) -LogFile 'x' `
                -StartTypeSnapshot @(@{ Name = 'BRAVO'; StartMode = 'AutomaticDelayed' }))
            [void](Set-BRAVOServiceQuiescenceRestartSuppressed)
            $suppressed = Read-BRAVOServiceQuiescenceState
            $path = Get-BRAVOServiceQuiescenceStatePath
            $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $raw.startTypeSnapshot = @(
                [pscustomobject]@{ Name = 'BRAVO'; StartMode = 'Bogus' },
                [pscustomobject]@{ Name = 'exchangAPI'; StartMode = 'Disabled' },
                [pscustomobject]@{ Name = 'BravoWeb'; StartMode = 'Manual' }
            )
            [IO.File]::WriteAllText($path, ($raw | ConvertTo-Json -Depth 5))
            $sanitized = Read-BRAVOServiceQuiescenceState
            $raw.PSObject.Properties.Remove('startTypeSnapshot')
            [IO.File]::WriteAllText($path, ($raw | ConvertTo-Json -Depth 5))
            $legacy = Read-BRAVOServiceQuiescenceState
            [pscustomobject]@{ Suppressed = $suppressed; Sanitized = $sanitized; Legacy = $legacy }
        }
        Test-BRAVOCondition `
            -Condition (
                [bool]$markerScenario.Suppressed.restartSuppressed -and
                @($markerScenario.Suppressed.startTypeSnapshot).Count -eq 1 -and
                [string]$markerScenario.Suppressed.startTypeSnapshot[0].StartMode -eq 'AutomaticDelayed' -and
                @($markerScenario.Sanitized.startTypeSnapshot).Count -eq 1 -and
                [string]$markerScenario.Sanitized.startTypeSnapshot[0].Name -eq 'BravoWeb' -and
                $null -ne $markerScenario.Legacy -and
                @($markerScenario.Legacy.startTypeSnapshot).Count -eq 0
            ) `
            -Name "ServiceQuiescence/StartTypeSnapshotSurvivesMarkerRewriteAndIsSanitized" `
            -Failure "Suppress має зберігати знімок типів; Read відкидає невалідні записи (Bogus/Disabled) і нормалізує маркер без поля (старі версії)"

        # (5) Аварія: маркер лишився, служби Disabled, власник мертвий ->
        # наступний прогін повертає точні типи й чистить знімок (маркер,
        # pid, createdAt збережено — Health-watchdog і далі стартує служби).
        $crashScenario = & $startModeModule {
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'AutomaticDelayed'; exchangAPI = 'Automatic'; BravoWeb = 'Manual' }
            $snapshot = @(New-BRAVOServiceStartTypeSnapshot -ServiceNames @('BRAVO', 'exchangAPI', 'BravoWeb'))
            $written = Write-BRAVOServiceQuiescenceState -Owner 'BRAVO_MAINTENANCE' `
                -Services @(@{ Name = 'BRAVO'; RestartIntent = $true }) -LogFile 'x' -StartTypeSnapshot $snapshot
            [void](Suspend-BRAVOServiceAutostart -Snapshot $snapshot)
            $duringCrash = $script:Q297Modes.Clone()
            # процес «загинув» — finally не виконався; власник мертвий
            $script:Q297OwnerAlive = $false
            $repair = Repair-BRAVOOrphanedServiceStartTypes -AllowedServiceNames @('BRAVO', 'exchangAPI', 'BravoWeb')
            $afterRepair = $script:Q297Modes.Clone()
            $markerAfter = Read-BRAVOServiceQuiescenceState
            $secondRepair = Repair-BRAVOOrphanedServiceStartTypes -AllowedServiceNames @('BRAVO', 'exchangAPI', 'BravoWeb')
            [pscustomobject]@{
                During = $duringCrash; Repair = $repair; After = $afterRepair; Marker = $markerAfter
                Second = $secondRepair; CreatedAt = $written.createdAt
            }
        }
        Test-BRAVOCondition `
            -Condition (
                $crashScenario.During.BRAVO -eq 'Disabled' -and
                [string]$crashScenario.Repair.Status -eq 'Repaired' -and
                $crashScenario.After.BRAVO -eq 'AutomaticDelayed' -and
                $crashScenario.After.exchangAPI -eq 'Automatic' -and
                $crashScenario.After.BravoWeb -eq 'Manual' -and
                $null -ne $crashScenario.Marker -and
                ([datetime]$crashScenario.Marker.createdAt).ToUniversalTime().Ticks -eq ([datetime]$crashScenario.CreatedAt).ToUniversalTime().Ticks -and
                @($crashScenario.Marker.startTypeSnapshot).Count -eq 0 -and
                [string]$crashScenario.Second.Status -eq 'NoSnapshot'
            ) `
            -Name "ServiceQuiescence/CrashLeavesMarkerNextRunRepairsExactStartTypes" `
            -Failure "аварійний вихід у вікні утримання: наступний прогін має повернути точні типи з маркера мертвого власника, зберегти маркер (watchdog стартує служби) і очистити знімок (повтор = NoSnapshot)"

        # (5b) #333: контекст ЧУЖОГО маркера для DataRestore (єдине місце читання):
        # власний маркер — не чужий; мертвий чужий власник віддає RestartIntent-
        # служби та знімок; живий — нічого; зіпсований/відсутній — Present=$false.
        $foreignContext = & $startModeModule {
            $out = @{}
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'AutomaticDelayed'; exchangAPI = 'Automatic' }
            $snapshot = @(New-BRAVOServiceStartTypeSnapshot -ServiceNames @('BRAVO', 'exchangAPI'))
            [void](Write-BRAVOServiceQuiescenceState -Owner 'BRAVO_MAINTENANCE' `
                -Services @(@{ Name = 'BRAVO'; RestartIntent = $true }, @{ Name = 'exchangAPI'; RestartIntent = $false }) -LogFile 'x' -RestartSuppressed -StartTypeSnapshot $snapshot)
            $out.Own = Get-BRAVOForeignServiceQuiescenceContext
            $statePath = Get-BRAVOServiceQuiescenceStatePath
            $raw = [IO.File]::ReadAllText($statePath)
            [IO.File]::WriteAllText($statePath, ($raw -replace '"pid":\s*\d+', '"pid": 999999'))
            $script:Q297OwnerAlive = $false
            $out.Dead = Get-BRAVOForeignServiceQuiescenceContext
            $script:Q297OwnerAlive = $true
            $out.Alive = Get-BRAVOForeignServiceQuiescenceContext
            [IO.File]::WriteAllText($statePath, '{ not json')
            $out.Garbage = Get-BRAVOForeignServiceQuiescenceContext
            Remove-Item -LiteralPath $statePath -Force
            $out.Missing = Get-BRAVOForeignServiceQuiescenceContext
            $out
        }
        Test-BRAVOCondition `
            -Condition (
                -not $foreignContext.Own.Present -and
                $foreignContext.Dead.Present -and -not $foreignContext.Dead.OwnerAlive -and $foreignContext.Dead.RestartSuppressed -and
                (@($foreignContext.Dead.RestartIntentNames) -join ',') -ceq 'BRAVO' -and
                @($foreignContext.Dead.HeldSnapshot).Count -eq 2 -and
                [string]$foreignContext.Dead.HeldSnapshot[0].StartMode -eq 'AutomaticDelayed' -and
                $foreignContext.Alive.Present -and $foreignContext.Alive.OwnerAlive -and
                @($foreignContext.Alive.RestartIntentNames).Count -eq 0 -and @($foreignContext.Alive.HeldSnapshot).Count -eq 0 -and
                -not $foreignContext.Garbage.Present -and -not $foreignContext.Missing.Present
            ) `
            -Name "ServiceQuiescence/ForeignContextForDataRestoreOwnership" `
            -Failure "Get-BRAVOForeignServiceQuiescenceContext: власний маркер не чужий; мертвий чужий власник віддає RestartIntent і знімок; живий — нічого; зіпсований/відсутній — Present=false"

        # (6) Stale/foreign/неочікувані маркери — безпечні відмови.
        $staleScenario = & $startModeModule {
            $allowed = @('BRAVO', 'exchangAPI', 'BravoWeb')
            $out = @{}
            # 6a: власник ЖИВИЙ -> не втручатись
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Automatic' }
            $snapshot = @(New-BRAVOServiceStartTypeSnapshot -ServiceNames @('BRAVO'))
            [void](Write-BRAVOServiceQuiescenceState -Owner 'BRAVO_MAINTENANCE' -Services @(@{ Name = 'BRAVO'; RestartIntent = $true }) -LogFile 'x' -StartTypeSnapshot $snapshot)
            [void](Suspend-BRAVOServiceAutostart -Snapshot $snapshot)
            $script:Q297OwnerAlive = $true
            $out.Alive = Repair-BRAVOOrphanedServiceStartTypes -AllowedServiceNames $allowed
            $out.AliveMode = $script:Q297Modes['BRAVO']
            # 6b: маркер restartSuppressed (перервана реставрація) -> лишається Disabled
            $script:Q297OwnerAlive = $false
            [void](Set-BRAVOServiceQuiescenceRestartSuppressed)
            $out.Held = Repair-BRAVOOrphanedServiceStartTypes -AllowedServiceNames $allowed
            $out.HeldMode = $script:Q297Modes['BRAVO']
            # 6c: оператор уже сам змінив тип (Manual) -> не перезаписувати
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Automatic' }
            [void](Write-BRAVOServiceQuiescenceState -Owner 'BRAVO_MAINTENANCE' -Services @(@{ Name = 'BRAVO'; RestartIntent = $true }) -LogFile 'x' -StartTypeSnapshot $snapshot)
            $script:Q297Modes['BRAVO'] = 'Manual'
            $out.Foreign = Repair-BRAVOOrphanedServiceStartTypes -AllowedServiceNames $allowed
            $out.ForeignMode = $script:Q297Modes['BRAVO']
            # 6d: служба поза керованим набором (підроблений маркер) -> відмова
            Reset-BRAVOSelfTestStartModes -Modes @{ SomeOtherSvc = 'Disabled' }
            [void](Write-BRAVOServiceQuiescenceState -Owner 'BRAVO_MAINTENANCE' -Services @(@{ Name = 'BRAVO'; RestartIntent = $true }) -LogFile 'x' `
                -StartTypeSnapshot @(@{ Name = 'SomeOtherSvc'; StartMode = 'Automatic' }))
            $out.Outside = Repair-BRAVOOrphanedServiceStartTypes -AllowedServiceNames $allowed
            $out.OutsideMode = $script:Q297Modes['SomeOtherSvc']
            # 6e: маркер чужого hostname -> Read = $null -> NoMarker
            $path = Get-BRAVOServiceQuiescenceStatePath
            $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $raw.hostname = 'SRV-OTHER-HOST'
            [IO.File]::WriteAllText($path, ($raw | ConvertTo-Json -Depth 5))
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Disabled' }
            $out.Foreigner = Repair-BRAVOOrphanedServiceStartTypes -AllowedServiceNames $allowed
            $out.ForeignerMode = $script:Q297Modes['BRAVO']
            [pscustomobject]$out
        }
        Test-BRAVOCondition `
            -Condition (
                [string]$staleScenario.Alive.Status -eq 'OwnerAlive' -and $staleScenario.AliveMode -eq 'Disabled' -and
                [string]$staleScenario.Held.Status -eq 'HeldSuppressed' -and $staleScenario.HeldMode -eq 'Disabled' -and
                [string]$staleScenario.Foreign.Status -eq 'Repaired' -and @($staleScenario.Foreign.Foreign).Count -eq 1 -and $staleScenario.ForeignMode -eq 'Manual' -and
                [string]$staleScenario.Outside.Status -eq 'RepairFailed' -and $staleScenario.OutsideMode -eq 'Disabled' -and
                [string]$staleScenario.Foreigner.Status -eq 'NoMarker' -and $staleScenario.ForeignerMode -eq 'Disabled'
            ) `
            -Name "ServiceQuiescence/StartTypeRepairHandlesStaleForeignAndSuppressedMarkers" `
            -Failure "живий власник/suppressed/зміна оператора/служба поза набором/чужий hostname: жодних небезпечних змін типу запуску (Disabled лишається Disabled)"

        # (7) Hard-recheck: служба, запущена «SCM» посеред вікна, виявляється.
        $recheckScenario = & $startModeModule {
            $names = @('BRAVO', 'exchangAPI')
            $snap = @(@{ Name = 'BRAVO'; StartMode = 'Automatic' }, @{ Name = 'exchangAPI'; StartMode = 'Manual' })
            $out = @{}
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Disabled'; exchangAPI = 'Disabled' } -Status @{}
            $out.Clean = Confirm-BRAVOServicesQuiesced -ServiceNames $names -Snapshot $snap
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Disabled'; exchangAPI = 'Disabled' } -Status @{ BRAVO = 'Running' }
            $out.StartedMidWindow = Confirm-BRAVOServicesQuiesced -ServiceNames $names -Snapshot $snap
            $out.StartedStatusUntouched = $script:Q297Status['BRAVO']
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Disabled'; exchangAPI = 'Disabled' } -Status @{ BRAVO = 'Running' }
            $out.Restopped = Confirm-BRAVOServicesQuiesced -ServiceNames $names -Snapshot $snap -StopRunning
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Disabled'; exchangAPI = 'Disabled' } -Status @{ BRAVO = 'Running' } -StopFailures @('BRAVO')
            $out.CannotStop = Confirm-BRAVOServicesQuiesced -ServiceNames $names -Snapshot $snap -StopRunning -StopTimeoutSeconds 1 -PollIntervalSeconds 1
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Automatic'; exchangAPI = 'Disabled' }
            $out.SuppressionLost = Confirm-BRAVOServicesQuiesced -ServiceNames $names -Snapshot $snap
            Reset-BRAVOSelfTestStartModes -Modes @{ BRAVO = 'Automatic'; exchangAPI = 'Disabled' }
            $out.Reapplied = Confirm-BRAVOServicesQuiesced -ServiceNames $names -Snapshot $snap -StopRunning
            $out.ReappliedMode = $script:Q297Modes['BRAVO']
            [pscustomobject]$out
        }
        Test-BRAVOCondition `
            -Condition (
                $recheckScenario.Clean.Ok -and
                -not $recheckScenario.StartedMidWindow.Ok -and
                @($recheckScenario.StartedMidWindow.Offenders).Count -eq 1 -and
                $recheckScenario.StartedStatusUntouched -eq 'Running' -and
                $recheckScenario.Restopped.Ok -and @($recheckScenario.Restopped.StoppedAgain) -contains 'BRAVO' -and
                -not $recheckScenario.CannotStop.Ok -and
                -not $recheckScenario.SuppressionLost.Ok -and
                $recheckScenario.Reapplied.Ok -and $recheckScenario.ReappliedMode -eq 'Disabled'
            ) `
            -Name "ServiceQuiescence/RecheckDetectsServiceStartedMidWindow" `
            -Failure "Confirm-BRAVOServicesQuiesced: запущена посеред вікна служба = Offender (fail-closed перед bravocmd); перед архівом -StopRunning зупиняє знову; втрачене утримання виявляється/перезастосовується"

        # (8) Watchdog (Health): типи запуску повертаються ПЕРЕД Start-Service
        # (Disabled блокує старт); збій повернення -> маркер лишається.
        $watchdogStartModeStubs = @'
function Restore-BRAVOServiceStartTypeSnapshot {
    param($Snapshot, $AllowedServiceNames)
    $script:BRAVOSelfTestRestoreBeforeStart = (@($script:BRAVOSelfTestQuiescenceStartedServices).Count -eq 0)
    $script:BRAVOSelfTestRestoreSnapshot = @($Snapshot)
    if ($script:BRAVOSelfTestRestoreFail) {
        return [pscustomobject]@{ Restored = @(); Unchanged = @(); Foreign = @(); Failed = @('BRAVO: self-test збій') }
    }
    return [pscustomobject]@{ Restored = @('BRAVO=Automatic'); Unchanged = @(); Foreign = @(); Failed = @() }
}
'@
        $watchdogStartModeModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText ($quiescenceWatchdogStubs + "`n" + $watchdogStartModeStubs + "`n" + $healthRuntimeTextForQuiescence) `
            -FunctionNames @(
                'Write-HealthLog', 'Read-BRAVOServiceQuiescenceState', 'Test-BRAVOProcessAlive',
                'Get-BRAVOQuiescenceWatchdogAllowedServiceNames', 'Get-Service', 'Start-Service',
                'Clear-BRAVOServiceQuiescenceState', 'Invoke-BRAVOSelfTestQuiescenceScenario',
                'Restore-BRAVOServiceStartTypeSnapshot', 'Invoke-BRAVOServiceQuiescenceWatchdog'
            )
        $snapshotMarker = [pscustomobject]@{
            schemaVersion = 1; owner = 'BRAVO_MAINTENANCE'; hostname = [Environment]::MachineName
            pid = 12345; processStartTime = '2026-08-20T23:55:00.0000000+03:00'
            createdAt = '2026-08-20T23:55:01.0000000+03:00'; logFile = 'C:\LOGS\maintenance.log'
            restartSuppressed = $false
            services = @([pscustomobject]@{ Name = 'BRAVO'; RestartIntent = $true })
            startTypeSnapshot = @([pscustomobject]@{ Name = 'BRAVO'; StartMode = 'Automatic' })
        }
        $watchdogOk = & $watchdogStartModeModule {
            param($State)
            $script:BRAVOSelfTestRestoreFail = $false; $script:BRAVOSelfTestRestoreBeforeStart = $null
            $scenario = Invoke-BRAVOSelfTestQuiescenceScenario -State $State -OwnerAlive $false -StartFailures @()
            [pscustomobject]@{ Scenario = $scenario; RestoreBeforeStart = $script:BRAVOSelfTestRestoreBeforeStart; Snapshot = $script:BRAVOSelfTestRestoreSnapshot }
        } $snapshotMarker
        $watchdogFail = & $watchdogStartModeModule {
            param($State)
            $script:BRAVOSelfTestRestoreFail = $true
            Invoke-BRAVOSelfTestQuiescenceScenario -State $State -OwnerAlive $false -StartFailures @()
        } $snapshotMarker
        Test-BRAVOCondition `
            -Condition (
                $watchdogOk.RestoreBeforeStart -eq $true -and
                @($watchdogOk.Snapshot).Count -eq 1 -and
                @($watchdogOk.Scenario.StartedServices) -contains 'BRAVO' -and
                $watchdogOk.Scenario.MarkerCleared -eq $true -and
                $watchdogFail.MarkerCleared -eq $false
            ) `
            -Name "ServiceQuiescence/WatchdogRestoresStartTypesBeforeStartingServices" `
            -Failure "Health-watchdog мертвого власника: спочатку повернути start type зі знімка (Disabled блокує старт), потім Start-Service; збій повернення типу лишає маркер"

        # (9) Статичний порядок у Maintenance: самовідновлення ДО читання
        # start type; recheck ПЕРЕД before-archive і ПЕРЕД bravocmd; повернення
        # типів у finally ПЕРЕД стартом служб; write-ahead знімок у маркері.
        $maintenanceTextForStartMode = [IO.File]::ReadAllText(
            (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
            [Text.Encoding]::UTF8
        )
        $repairCallIndex = $maintenanceTextForStartMode.IndexOf('Repair-BRAVOOrphanedServiceStartTypes')
        $firstStartModeReadIndex = $maintenanceTextForStartMode.IndexOf('$bravoServiceState = Get-ConfiguredServiceState')
        $markerWriteIndex = $maintenanceTextForStartMode.IndexOf('-StartTypeSnapshot $script:startTypeSnapshot)')
        $suspendIndex = $maintenanceTextForStartMode.IndexOf('Suspend-BRAVOServiceAutostart -Snapshot')
        $archiveRecheckIndex = $maintenanceTextForStartMode.IndexOf('$preArchiveQuiescence = Confirm-BRAVOServicesQuiesced')
        $archiveRunIndex = $maintenanceTextForStartMode.IndexOf('-Description "Архівація моделі перед реставрацією"')
        $bravocmdRecheckIndex = $maintenanceTextForStartMode.IndexOf('$preRestoreQuiescence = Confirm-BRAVOServicesQuiesced')
        $bravocmdRunIndex = $maintenanceTextForStartMode.IndexOf('-Description "Виконання реставрації моделі')
        $finallyIndex = $maintenanceTextForStartMode.IndexOf("Write-BRAVOProgressPhase -Phase 'Відновлення стану служб'")
        $finallyRestoreIndex = $maintenanceTextForStartMode.IndexOf('Restore-BRAVOServiceStartTypeSnapshot -Snapshot $script:startTypeSnapshot')
        $firstServiceStartIndex = $maintenanceTextForStartMode.IndexOf('# 1. Запуск служби BRAVO')
        Test-BRAVOCondition `
            -Condition (
                $repairCallIndex -ge 0 -and $repairCallIndex -lt $firstStartModeReadIndex -and
                $markerWriteIndex -ge 0 -and $suspendIndex -gt $markerWriteIndex -and
                $archiveRecheckIndex -ge 0 -and $archiveRecheckIndex -lt $archiveRunIndex -and
                $bravocmdRecheckIndex -gt $archiveRunIndex -and $bravocmdRecheckIndex -lt $bravocmdRunIndex -and
                $finallyIndex -ge 0 -and $finallyRestoreIndex -gt $finallyIndex -and $finallyRestoreIndex -lt $firstServiceStartIndex
            ) `
            -Name "ServiceQuiescence/MaintenanceOrdersRepairSuppressRecheckRestore" `
            -Failure "Maintenance: Repair до читання start type; знімок у маркері до Suspend; Confirm перед before-archive і перед bravocmd; Restore start type у finally ПЕРЕД стартом служб"

        # (10) P2: запис маркера не губить чужий знімок типів. Чужий маркер
        # (pid іншого процесу) із непорожнім знімком: Maintenance-запис
        # відхиляється (маркер недоторканий); DataRestore-запис переносить
        # знімок (старий запис чинний для тієї ж служби); порожній знімок
        # чужого маркера не блокує запис.
        $foreignWrite = & $startModeModule {
            $out = @{}
            Reset-BRAVOSelfTestStartModes -Modes @{}
            $path = Get-BRAVOServiceQuiescenceStatePath
            $makeForeign = {
                param($Snapshot)
                [void](Write-BRAVOServiceQuiescenceState -Owner 'BRAVO_MAINTENANCE' -Services @(@{ Name = 'BRAVO'; RestartIntent = $true }) -LogFile 'x' -StartTypeSnapshot $Snapshot)
                $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                $raw.pid = 1
                [IO.File]::WriteAllText($path, ($raw | ConvertTo-Json -Depth 5))
            }
            & $makeForeign @(@{ Name = 'BRAVO'; StartMode = 'AutomaticDelayed' })
            $out.Refused = $false
            try {
                [void](Write-BRAVOServiceQuiescenceState -Owner 'BRAVO_MAINTENANCE' -Services @(@{ Name = 'exchangAPI'; RestartIntent = $true }) -LogFile 'y' -StartTypeSnapshot @(@{ Name = 'exchangAPI'; StartMode = 'Automatic' }))
            } catch { $out.Refused = $true }
            $out.AfterRefuse = Read-BRAVOServiceQuiescenceState
            [void](Write-BRAVOServiceQuiescenceState -Owner 'BRAVO_DATA_RESTORE' -Services @(@{ Name = 'BRAVO'; RestartIntent = $true }) -LogFile 'z' -RestartSuppressed -PreserveForeignStartTypeSnapshot `
                -StartTypeSnapshot @(@{ Name = 'BRAVO'; StartMode = 'Manual' }, @{ Name = 'BravoWeb'; StartMode = 'Automatic' }))
            $out.Merged = Read-BRAVOServiceQuiescenceState
            & $makeForeign @()
            $out.EmptyAllowed = $true
            try {
                [void](Write-BRAVOServiceQuiescenceState -Owner 'BRAVO_MAINTENANCE' -Services @(@{ Name = 'BRAVO'; RestartIntent = $true }) -LogFile 'w' -StartTypeSnapshot @())
            } catch { $out.EmptyAllowed = $false }
            [pscustomobject]$out
        }
        $mergedByName = @{}
        foreach ($mergedEntry in @($foreignWrite.Merged.startTypeSnapshot)) { $mergedByName[[string]$mergedEntry.Name] = [string]$mergedEntry.StartMode }
        Test-BRAVOCondition `
            -Condition (
                $foreignWrite.Refused -and
                @($foreignWrite.AfterRefuse.startTypeSnapshot).Count -eq 1 -and
                [string]$foreignWrite.AfterRefuse.startTypeSnapshot[0].StartMode -eq 'AutomaticDelayed' -and
                $mergedByName.Count -eq 2 -and $mergedByName['BRAVO'] -eq 'AutomaticDelayed' -and $mergedByName['BravoWeb'] -eq 'Automatic' -and
                $foreignWrite.EmptyAllowed
            ) `
            -Name "ServiceQuiescence/MarkerWriteNeverDropsForeignStartTypeSnapshot" `
            -Failure "запис маркера: чужий знімок типів не перезаписується (Maintenance throw, маркер недоторканий); DataRestore переносить його (старий запис виграє); порожній знімок не блокує"

        # (11) P2: класифікація Disabled перевіряється ПІСЛЯ отримання lock,
        # до будь-яких дій (зупинка служб), а DataRestore зберігає знімок.
        $lockIndex = $maintenanceTextForStartMode.IndexOf('$script:maintenanceOperationLockPath = $maintenanceLockResult.Path')
        $postLockRepairIndex = $maintenanceTextForStartMode.IndexOf('$postLockRepair = Repair-BRAVOOrphanedServiceStartTypes')
        $reclassifyIndex = $maintenanceTextForStartMode.IndexOf('$reBravoEnabled = ')
        $reclassifyExitIndex = $maintenanceTextForStartMode.IndexOf('Resolve-BRAVOExitCode -LockBusy', $reclassifyIndex)
        $logRotationIndex = $maintenanceTextForStartMode.IndexOf('$bravoLogRotationLogger = ')
        $dataRestoreTextForStartMode = [IO.File]::ReadAllText(
            (Join-Path $root "modules\BRAVO.DataRestore\BRAVO.DataRestore.Runtime.ps1"),
            [Text.Encoding]::UTF8
        )
        Test-BRAVOCondition `
            -Condition (
                $lockIndex -ge 0 -and $postLockRepairIndex -gt $lockIndex -and
                $reclassifyIndex -gt $postLockRepairIndex -and $reclassifyExitIndex -gt $reclassifyIndex -and
                $logRotationIndex -gt $reclassifyExitIndex -and
                $dataRestoreTextForStartMode.Contains('-PreserveForeignStartTypeSnapshot')
            ) `
            -Name "ServiceQuiescence/MaintenanceRechecksClassificationAfterLock" `
            -Failure "після lock Maintenance має повторити Repair і перевірити класифікацію служб (зміна -> fail-closed exit 20) до будь-яких дій; DataRestore пише маркер з -PreserveForeignStartTypeSnapshot"

        # (12) #333: DataRestore користується ТИМИ САМИМИ канонічними функціями
        # BRAVO.System, що й Maintenance (без копій логіки), у контрактному
        # порядку: Repair до знімка служб; знімок -> маркер зі знімком -> Suspend;
        # у finally Restore типів ПЕРЕД стартом служб. Поведінку перевіряють
        # DataRestore/StartMode* (Orchestration-проба).
        # Порядок перевіряється за AST CommandAst (імена викликів), а не за іменами локальних змінних.
        $dataRestoreContractAst = [Management.Automation.Language.Parser]::ParseInput($dataRestoreTextForStartMode, [ref]$null, [ref]$null)
        $dataRestoreContractOrder = @(
            'Repair-BRAVOOrphanedServiceStartTypes', 'Get-BRAVODataRestoreServiceSnapshot', 'New-BRAVOServiceStartTypeSnapshot',
            'Write-BRAVOServiceQuiescenceState', 'Suspend-BRAVOServiceAutostart', 'Confirm-BRAVOServicesQuiesced',
            'Restore-BRAVOServiceStartTypeSnapshot', 'Restore-BRAVODataRestoreServices')
        $dataRestoreContractOffsets = @($dataRestoreContractOrder | ForEach-Object {
                $contractName = $_
                $contractCall = @($dataRestoreContractAst.FindAll({
                            param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq $contractName
                        }, $true) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
                if ($contractCall.Count -eq 0) { -1 } else { $contractCall[0].Extent.StartOffset }
            })
        $dataRestoreContractMissing = @(for ($contractIndex = 0; $contractIndex -lt $dataRestoreContractOrder.Count; $contractIndex++) {
                if ($dataRestoreContractOffsets[$contractIndex] -lt 0) { $dataRestoreContractOrder[$contractIndex] }
            })
        $dataRestoreContractOrdered = $true
        for ($contractIndex = 1; $contractIndex -lt $dataRestoreContractOffsets.Count; $contractIndex++) {
            if ($dataRestoreContractOffsets[$contractIndex] -le $dataRestoreContractOffsets[$contractIndex - 1]) { $dataRestoreContractOrdered = $false }
        }
        Test-BRAVOCondition `
            -Condition (
                $dataRestoreContractMissing.Count -eq 0 -and $dataRestoreContractOrdered -and
                $dataRestoreTextForStartMode -notmatch 'sc\.exe' -and
                $dataRestoreTextForStartMode -notmatch 'HKLM:'
            ) `
            -Name "ServiceQuiescence/DataRestoreUsesCanonicalStartTypeHoldContract" `
            -Failure "DataRestore має викликати канонічні функції BRAVO.System (відсутні: $($dataRestoreContractMissing -join ', ')) у порядку Repair -> знімок служб -> знімок типів -> маркер -> Suspend -> Confirm -> Restore типів -> старт служб, без власних sc.exe/реєстру"
    } finally {
        Remove-Item -LiteralPath $startModeTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    }
    #endregion #297-start-type-suppression
