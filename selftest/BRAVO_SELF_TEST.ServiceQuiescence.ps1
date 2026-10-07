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
    # #314 хвиля 2: зупинка служб винесена у функції runtime
    # (Stop-BRAVOMaintenanceManagedServices / Get-BRAVOMaintenancePreArchiveBarrierPlan),
    # тому порядок перевіряється за ВИКЛИКАМИ в тілі прогону (AST, поза
    # тілами вкладених функцій): запис маркера йде до виклику фази зупинки,
    # і жодного прямого Invoke-ServiceStateChange -DesiredStatus Stopped у
    # тілі прогону немає.
    $maintenanceQuiescenceAst = [Management.Automation.Language.Parser]::ParseInput($maintenanceRuntimeTextForQuiescence, [ref]$null, [ref]$null)
    $maintenanceBodyAst = @($maintenanceQuiescenceAst.FindAll({
                param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-BRAVOMaintenance'
            }, $true)) | Select-Object -First 1
    $maintenanceBodyCommands = @()
    if ($null -ne $maintenanceBodyAst) {
        $maintenanceBodyCommands = @($maintenanceBodyAst.Body.FindAll({
                    param($node)
                    if ($node -isnot [Management.Automation.Language.CommandAst]) { return $false }
                    $ownerAst = $node.Parent
                    while ($null -ne $ownerAst -and $ownerAst -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $ownerAst = $ownerAst.Parent }
                    $null -ne $ownerAst -and $ownerAst.Name -eq 'Invoke-BRAVOMaintenance'
                }, $true) | Sort-Object { $_.Extent.StartOffset })
    }
    $maintenanceMarkerWriteCall = @($maintenanceBodyCommands | Where-Object { $_.GetCommandName() -eq 'Write-BRAVOServiceQuiescenceState' }) | Select-Object -First 1
    $maintenanceStopPhaseCall = @($maintenanceBodyCommands | Where-Object { $_.GetCommandName() -eq 'Stop-BRAVOMaintenanceManagedServices' }) | Select-Object -First 1
    $maintenanceInlineStops = @($maintenanceBodyCommands | Where-Object {
            $_.GetCommandName() -eq 'Invoke-ServiceStateChange' -and $_.Extent.Text -match '-DesiredStatus\s+Stopped'
        })
    Test-BRAVOCondition `
        -Condition (
            $null -ne $maintenanceMarkerWriteCall -and
            $null -ne $maintenanceStopPhaseCall -and
            $maintenanceMarkerWriteCall.Extent.StartOffset -lt $maintenanceStopPhaseCall.Extent.StartOffset -and
            $maintenanceInlineStops.Count -eq 0
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
    # #314 хвиля 2: знімок наміру — Get-BRAVOManagedServiceRestartIntent
    # (BRAVO.System) з -HoldAllEnabled для boot-hold; поведінку перевіряє
    # ServiceRecovery/LifecyclePlan* і характеризація циклу служб.
    Test-BRAVOCondition `
        -Condition (
            $maintenanceRuntimeTextForQuiescence.Contains('$serviceWasRunning = Get-BRAVOManagedServiceRestartIntent') -and
            $maintenanceRuntimeTextForQuiescence.Contains('-HoldAllEnabled:([bool]$bootRestoreIgnoresWindow)') -and
            $maintenanceRuntimeTextForQuiescence.Contains("@{ Key = 'Bravo'; Name = [string]`$BravoServiceName; Enabled = [bool]`$BravoMaintenanceEnabled;") -and
            $maintenanceRuntimeTextForQuiescence.Contains("@{ Key = 'ExchangeApi'; Name = [string]`$ExchangAPIServiceName; Enabled = [bool]`$exchangAPIServiceEnabled;") -and
            $maintenanceRuntimeTextForQuiescence.Contains("@{ Key = 'BravoWeb'; Name = [string]`$BravoWebServiceName; Enabled = [bool]`$BravoWebMaintenanceEnabled;")
        ) `
        -Name "ServiceQuiescence/MaintenanceBootHoldForcesManagedServicesIntoQuiescenceScope" `
        -Failure "boot-профіль (bootRestoreIgnoresWindow) має примусово включати всі увімкнені керовані служби у зупинку/маркер/restart-intent"
    # РЕГРЕСІЯ (#64 review, п.3): знімок стану служб рахує StartPending як
    # «працювала» — інакше служба, що саме стартує, була б зупинена без
    # restart-intent і лишилася лежати після обслуговування.
    # #314 хвиля 2: одна канонічна перевірка Test-BRAVOManagedServiceActiveStatus
    # (BRAVO.System) і для знімка (через Get-BRAVOManagedServiceRestartIntent),
    # і для активності перед зупинкою.
    Test-BRAVOCondition `
        -Condition (
            $systemModuleTextForQuiescence.Contains("return ([string]`$Status -in @('Running', 'StartPending'))") -and
            $maintenanceRuntimeTextForQuiescence.Contains('$serviceWasRunning = Get-BRAVOManagedServiceRestartIntent') -and
            $maintenanceRuntimeTextForQuiescence.Contains('if (-not (Test-BRAVOManagedServiceActiveStatus -Status $managedServiceStatus)) { continue }') -and
            $maintenanceRuntimeTextForQuiescence -notmatch [regex]::Escape("-in @('Running', 'StartPending')")
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
    # Службу видалено з SCM між Get-Service і Refresh().
    if ([string]$Name -eq 'BravoVanished') { Add-Member -InputObject $svc -MemberType ScriptMethod -Name Refresh -Value { throw 'служба вже не існує (stub)' } -Force }
    return $svc
}
function Read-BRAVOServiceQuiescenceState {
    if ($script:startTypeMarkerThrows) { throw 'маркер не прочитано (stub)' }
    return $script:startTypeMarker
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
        -SourceText ($startTypeStubs + "`n" + $healthRuntimeTextForQuiescence + "`n" + $systemModuleTextForQuiescence) `
        -FunctionNames @('Write-HealthLog', 'Get-Service', 'Read-BRAVOServiceQuiescenceState', 'Get-BRAVOWmiInstance', 'Test-BRAVOSettingEnabled',
            'Get-BRAVOWin32ServiceInfo', 'Test-BRAVOServiceDisabledByOperator',
            'Get-BRAVOServiceStartMode', 'Get-BRAVOManagedServiceCondition', 'Get-ManagedServiceHealthIssues')
    $startTypeProbe = {
        param($ServiceName, [bool]$WmiFails = $false, $Marker = $null, [bool]$MarkerThrows = $false)
        Set-StrictMode -Version 2.0
        $script:startTypeWmiFails = $WmiFails
        $script:startTypeMarker = $Marker
        $script:startTypeMarkerThrows = $MarkerThrows
        $script:backupMonitoring = @{ CheckManagedServices = $true }
        $script:maintenanceSettings = [pscustomobject]@{
            Services = [pscustomobject]@{ BravoName = $ServiceName; ExchangeApiName = ''; BravoWebEnabled = $false; BravoWebCandidates = @() }
        }
        $thrown = $null
        $issues = @()
        try { $issues = @(Get-ManagedServiceHealthIssues) } catch { $thrown = $_.Exception.Message }
        [pscustomobject]@{ Thrown = $thrown; IssueCount = @($issues).Count; Reasons = @($issues | ForEach-Object { [string]$_.Reason }) }
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

    # #314 FR-1: тимчасовий Disabled від BRAVO (#297, знімок типу в маркері)
    # Health і далі не рапортує як issue (осиротілий маркер відпрацьовує
    # watchdog), а зупинена служба під маркером без утримання — issue, як і
    # до переходу на Get-BRAVOManagedServiceCondition.
    $heldMarker = [pscustomobject]@{
        owner = 'BRAVO_DATA_RESTORE'
        services = @([pscustomobject]@{ Name = 'BravoDisabled'; RestartIntent = $true })
        startTypeSnapshot = @([pscustomobject]@{ Name = 'BravoDisabled'; StartMode = 'Automatic' })
    }
    $markedMarker = [pscustomobject]@{
        owner = 'BRAVO_MAINTENANCE'
        services = @([pscustomobject]@{ Name = 'bravoauto'; RestartIntent = $true })
        startTypeSnapshot = @()
    }
    $startTypeHeld = & $startTypeModule $startTypeProbe 'BravoDisabled' $false $heldMarker
    $startTypeMarked = & $startTypeModule $startTypeProbe 'BravoAuto' $false $markedMarker
    Test-BRAVOCondition `
        -Condition (
            $null -eq $startTypeHeld.Thrown -and $startTypeHeld.IssueCount -eq 0 -and
            $null -eq $startTypeMarked.Thrown -and $startTypeMarked.IssueCount -eq 1
        ) `
        -Name "Health/ManagedServiceIssuesUnchangedUnderQuiescenceMarker" `
        -Failure "Get-ManagedServiceHealthIssues після переходу на Get-BRAVOManagedServiceCondition: утримана BRAVO служба (Disabled зі знімком у маркері) не дає issue, зупинена служба з маркера дає issue, як і раніше. Отримано: утримана(Thrown='$($startTypeHeld.Thrown)', Issues=$($startTypeHeld.IssueCount)), у маркері(Thrown='$($startTypeMarked.Thrown)', Issues=$($startTypeMarked.IssueCount))"

    # Службу видалено між Get-Service і Refresh(): одна issue з явною
    # причиною (не «стан: » з порожнім станом), без винятку; збій читання
    # маркера не обриває Health, служба перевіряється без маркера.
    $startTypeVanished = & $startTypeModule $startTypeProbe 'BravoVanished'
    $startTypeMarkerFails = & $startTypeModule $startTypeProbe 'BravoAuto' $false $null $true
    Test-BRAVOCondition `
        -Condition (
            $null -eq $startTypeVanished.Thrown -and $startTypeVanished.IssueCount -eq 1 -and
            ([string]$startTypeVanished.Reasons[0]).Contains('видалено під час перевірки') -and
            $null -eq $startTypeMarkerFails.Thrown -and $startTypeMarkerFails.IssueCount -eq 1 -and
            ([string]$startTypeMarkerFails.Reasons[0]).Contains('стан: Stopped')
        ) `
        -Name "Health/ManagedServiceVanishedOrMarkerUnreadableIsHandled" `
        -Failure "Get-ManagedServiceHealthIssues: служба, видалена між Get-Service і Refresh(), дає одну issue з причиною 'видалено під час перевірки'; збій читання маркера не кидає виняток. Отримано: видалена(Thrown='$($startTypeVanished.Thrown)', Reasons='$($startTypeVanished.Reasons -join ' | ')'), маркер(Thrown='$($startTypeMarkerFails.Thrown)', Reasons='$($startTypeMarkerFails.Reasons -join ' | ')')"

    $healthManagedServiceFunctionText = $healthRuntimeTextForQuiescence.Substring(
        $healthRuntimeTextForQuiescence.IndexOf('function Get-ManagedServiceHealthIssues'))
    $healthManagedServiceFunctionText = $healthManagedServiceFunctionText.Substring(0,
        $healthManagedServiceFunctionText.IndexOf('function Get-BRAVOManagedServiceStatusSnapshot'))
    Test-BRAVOCondition `
        -Condition (
            $healthManagedServiceFunctionText.Contains('Get-BRAVOManagedServiceCondition') -and
            -not $healthManagedServiceFunctionText.Contains("PSObject.Properties['StartType']") -and
            -not $healthManagedServiceFunctionText.Contains('-ieq "Disabled"')
        ) `
        -Name "Health/ManagedServiceUsesCanonicalCondition" `
        -Failure "Get-ManagedServiceHealthIssues має класифікувати служби лише через Get-BRAVOManagedServiceCondition (BRAVO.System, #314 FR-1), без власного читання StartType/Disabled"

    # ============================================================
    # #314 FR-1: Get-BRAVOManagedServiceCondition — єдина класифікація
    # стану керованої служби. Таблиця Auto/Manual/Disabled ×
    # Running/Stopped/Pending × маркер з підміненими Get-Service/WMI,
    # під StrictMode 2.0. Функція лише читає.
    # ============================================================
    $conditionStubs = @'
function Get-Service {
    param($Name, $ErrorAction)
    if ([string]$Name -eq 'BravoMissing') { return $null }
    return [pscustomobject]@{ Name = [string]$Name; Status = 'Stopped' }
}
function Get-BRAVOWmiInstance {
    param($ClassName, $Filter)
    $script:conditionWmiFilters += @([string]$Filter)
    return [pscustomobject]@{ Name = 'BravoQueried'; StartMode = 'Manual'; ExitCode = 1067; ServiceSpecificExitCode = 0 }
}
function Read-BRAVOServiceQuiescenceState { return $script:conditionMarker }
'@
    $conditionModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($conditionStubs + "`n" + $systemModuleTextForQuiescence) `
        -FunctionNames @('Get-Service', 'Get-BRAVOWmiInstance', 'Read-BRAVOServiceQuiescenceState',
            'Get-BRAVOWin32ServiceInfo', 'Test-BRAVOServiceDisabledByOperator',
            'Get-BRAVOServiceStartMode', 'Get-BRAVOManagedServiceCondition')
    $conditionMarker = [pscustomobject]@{
        owner = 'BRAVO_MAINTENANCE'
        services = @(
            [pscustomobject]@{ Name = 'BRAVO'; RestartIntent = $true },
            [pscustomobject]@{ Name = 'exchangAPI'; RestartIntent = $true },
            [pscustomobject]@{ Name = 'BravoOperatorDisabled'; RestartIntent = $true }
        )
        startTypeSnapshot = @([pscustomobject]@{ Name = 'BRAVOWEB'; StartMode = 'Manual' })
    }
    $conditionCases = @(
        @{ Case = 'AutoRunning'; StartType = 'Automatic'; Status = 'Running'; Marker = $false; Expected = 'Running' },
        @{ Case = 'ManualRunning'; StartType = 'Manual'; Status = 'Running'; Marker = $false; Expected = 'Running' },
        @{ Case = 'AutoStopped'; StartType = 'Automatic'; Status = 'Stopped'; Marker = $false; Expected = 'Failed' },
        @{ Case = 'ManualStopped'; StartType = 'Manual'; Status = 'Stopped'; Marker = $false; Expected = 'Failed' },
        @{ Case = 'AutoStartPending'; StartType = 'Automatic'; Status = 'StartPending'; Marker = $false; Expected = 'Pending' },
        @{ Case = 'ManualStopPending'; StartType = 'Manual'; Status = 'StopPending'; Marker = $false; Expected = 'Pending' },
        @{ Case = 'AutoContinuePending'; StartType = 'Automatic'; Status = 'ContinuePending'; Marker = $false; Expected = 'Pending' },
        @{ Case = 'AutoPausePending'; StartType = 'Automatic'; Status = 'PausePending'; Marker = $false; Expected = 'Pending' },
        @{ Case = 'AutoPaused'; StartType = 'Automatic'; Status = 'Paused'; Marker = $false; Expected = 'Failed' },
        @{ Case = 'UnknownStartModeStopped'; StartType = 'Boot'; Status = 'Stopped'; Marker = $false; Expected = 'Failed' },
        @{ Case = 'DisabledStopped'; StartType = 'Disabled'; Status = 'Stopped'; Marker = $false; Expected = 'Disabled' },
        @{ Case = 'DisabledRunning'; StartType = 'Disabled'; Status = 'Running'; Marker = $false; Expected = 'Disabled' },
        @{ Case = 'AutoStoppedInMarker'; Name = 'bravo'; StartType = 'Automatic'; Status = 'Stopped'; Marker = $true; Expected = 'OwnedByBravo' },
        @{ Case = 'ManualStoppedInMarker'; Name = 'exchangAPI'; StartType = 'Manual'; Status = 'Stopped'; Marker = $true; Expected = 'OwnedByBravo' },
        @{ Case = 'AutoRunningInMarker'; Name = 'BRAVO'; StartType = 'Automatic'; Status = 'Running'; Marker = $true; Expected = 'Running' },
        @{ Case = 'AutoPendingInMarker'; Name = 'BRAVO'; StartType = 'Automatic'; Status = 'StartPending'; Marker = $true; Expected = 'Pending' },
        @{ Case = 'DisabledHeldBySnapshot'; Name = 'BravoWeb'; StartType = 'Disabled'; Status = 'Stopped'; Marker = $true; Expected = 'OwnedByBravo' },
        @{ Case = 'DisabledByOperatorInMarker'; Name = 'BravoOperatorDisabled'; StartType = 'Disabled'; Status = 'Stopped'; Marker = $true; Expected = 'Disabled' },
        @{ Case = 'AutoStoppedOtherMarker'; Name = 'BravoOther'; StartType = 'Automatic'; Status = 'Stopped'; Marker = $true; Expected = 'Failed' },
        @{ Case = 'SnapshotOnlyNotDisabledStopped'; Name = 'BravoWeb'; StartType = 'Manual'; Status = 'Stopped'; Marker = $true; Expected = 'Failed' }
    )
    $conditionProbe = {
        param($Cases, $Marker)
        Set-StrictMode -Version 2.0
        $rows = @()
        foreach ($case in @($Cases)) {
            $serviceName = if ($case.ContainsKey('Name')) { [string]$case.Name } else { 'Bravo' + [string]$case.Case }
            $service = [pscustomobject]@{ Name = $serviceName; Status = [string]$case.Status; StartType = [string]$case.StartType }
            $caseMarker = if ($case.Marker) { $Marker } else { $null }
            $thrown = $null
            $condition = $null
            try {
                $condition = Get-BRAVOManagedServiceCondition -Name $serviceName -Service $service -ServiceInfo $null -QuiescenceState $caseMarker -NoWmiQuery
            } catch { $thrown = $_.Exception.Message }
            $rows += [pscustomobject]@{
                Case = [string]$case.Case
                Expected = [string]$case.Expected
                Actual = if ($null -ne $condition) { [string]$condition.Condition } else { "виняток: $thrown" }
                Held = if ($null -ne $condition) { [bool]$condition.HeldByBravo } else { $false }
                Original = if ($null -ne $condition) { [string]$condition.OriginalStartMode } else { '' }
                Owner = if ($null -ne $condition) { [string]$condition.MarkerOwner } else { '' }
            }
        }
        return @($rows)
    }
    $conditionRows = @(& $conditionModule $conditionProbe $conditionCases $conditionMarker)
    $conditionMismatches = @($conditionRows | Where-Object { $_.Actual -ne $_.Expected } |
        ForEach-Object { '{0}: очікувано {1}, отримано {2}' -f $_.Case, $_.Expected, $_.Actual })
    Test-BRAVOCondition `
        -Condition ($conditionRows.Count -eq $conditionCases.Count -and $conditionMismatches.Count -eq 0) `
        -Name "ServiceRecovery/ConditionMatrix" `
        -Failure "Get-BRAVOManagedServiceCondition: таблиця FR-1 #314 (Automatic і Manual однаково; Disabled має пріоритет над станом; служба з маркера — OwnedByBravo; Pending окремо). Розбіжності: $($conditionMismatches -join '; ')"

    $heldRow = @($conditionRows | Where-Object { $_.Case -eq 'DisabledHeldBySnapshot' }) | Select-Object -First 1
    $operatorRow = @($conditionRows | Where-Object { $_.Case -eq 'DisabledByOperatorInMarker' }) | Select-Object -First 1
    $markedRow = @($conditionRows | Where-Object { $_.Case -eq 'AutoStoppedInMarker' }) | Select-Object -First 1
    Test-BRAVOCondition `
        -Condition (
            $null -ne $heldRow -and $heldRow.Held -and $heldRow.Original -eq 'Manual' -and $heldRow.Owner -eq 'BRAVO_MAINTENANCE' -and
            $null -ne $operatorRow -and -not $operatorRow.Held -and
            $null -ne $markedRow -and -not $markedRow.Held -and $markedRow.Owner -eq 'BRAVO_MAINTENANCE'
        ) `
        -Name "ServiceRecovery/ConditionHeldDisabledIsOwnedByBravo" `
        -Failure "Disabled зі знімком типу в маркері (#297/#329) — це OwnedByBravo з HeldByBravo і початковим типом, а не «навмисно вимкнено»; Disabled без знімка лишається рішенням оператора"

    $conditionDetailProbe = {
        Set-StrictMode -Version 2.0
        $script:conditionWmiFilters = @()
        $script:conditionMarker = [pscustomobject]@{
            owner = 'BRAVO_DATA_RESTORE'
            services = @([pscustomobject]@{ Name = 'BravoQueried'; RestartIntent = $true })
            startTypeSnapshot = @()
        }
        $missing = Get-BRAVOManagedServiceCondition -Name 'BravoMissing'
        # Без -ServiceInfo/-QuiescenceState: власний WMI-запит за іменем і
        # читання маркера; StartType відсутній (.NET < 4.6.1) -> WMI StartMode.
        $queried = Get-BRAVOManagedServiceCondition -Name 'BravoQueried'
        $wmiFiltersAfterQuery = @($script:conditionWmiFilters).Count
        $noWmi = Get-BRAVOManagedServiceCondition -Name 'BravoNoWmi' -NoWmiQuery -QuiescenceState $null
        $fallback = Get-BRAVOManagedServiceCondition -Name 'BravoFallback' -NoWmiQuery -QuiescenceState $null `
            -ServiceInfo ([pscustomobject]@{ Name = 'BravoFallback'; StartMode = 'Disabled'; ExitCode = 0; ServiceSpecificExitCode = 0 })
        [pscustomobject]@{
            MissingCondition = [string]$missing.Condition
            MissingExists = [bool]$missing.Exists
            QueriedCondition = [string]$queried.Condition
            QueriedStartMode = [string]$queried.StartMode
            QueriedSource = [string]$queried.StartModeSource
            QueriedExitCode = $queried.ExitCode
            QueriedFilter = (@($script:conditionWmiFilters) -join '|')
            WmiFiltersAfterQuery = $wmiFiltersAfterQuery
            WmiFiltersTotal = @($script:conditionWmiFilters).Count
            NoWmiCondition = [string]$noWmi.Condition
            NoWmiStartMode = [string]$noWmi.StartMode
            NoWmiExitCode = $noWmi.ExitCode
            FallbackCondition = [string]$fallback.Condition
        }
    }
    $conditionDetail = $null
    $conditionDetailThrown = $null
    try { $conditionDetail = & $conditionModule $conditionDetailProbe } catch { $conditionDetailThrown = $_.Exception.Message }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $conditionDetailThrown -and $null -ne $conditionDetail -and
            $conditionDetail.MissingCondition -eq 'NotInstalled' -and -not $conditionDetail.MissingExists -and
            $conditionDetail.QueriedCondition -eq 'OwnedByBravo' -and
            $conditionDetail.QueriedStartMode -eq 'Manual' -and $conditionDetail.QueriedSource -eq 'FallbackStartMode' -and
            $conditionDetail.QueriedExitCode -eq 1067 -and
            $conditionDetail.QueriedFilter -eq "Name = 'BravoQueried'" -and
            $conditionDetail.WmiFiltersAfterQuery -eq 1 -and $conditionDetail.WmiFiltersTotal -eq 1 -and
            $conditionDetail.NoWmiCondition -eq 'Failed' -and $conditionDetail.NoWmiStartMode -eq 'Unknown' -and
            $null -eq $conditionDetail.NoWmiExitCode -and
            $conditionDetail.FallbackCondition -eq 'Disabled'
        ) `
        -Name "ServiceRecovery/ConditionSourcesAndExitCode" `
        -Failure "Get-BRAVOManagedServiceCondition: відсутня служба -> NotInstalled; без StartType тип береться з одного WMI-запиту за іменем (разом з ExitCode), маркер читається сам; -NoWmiQuery не робить запиту (тип Unknown -> Failed). Виняток: '$conditionDetailThrown'; отримано: $(if ($null -ne $conditionDetail) { ($conditionDetail | Out-String).Trim() })"

    # Функція лише читає: у тілі немає жодної команди, що змінює службу,
    # тип запуску, маркер чи файли.
    $conditionParseTokens = $null
    $conditionParseErrors = $null
    $conditionFunctionAst = [Management.Automation.Language.Parser]::ParseInput($systemModuleTextForQuiescence, [ref]$conditionParseTokens, [ref]$conditionParseErrors).FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-BRAVOManagedServiceCondition'
        }, $true) | Select-Object -First 1
    $conditionCommandNames = @()
    if ($null -ne $conditionFunctionAst) {
        $conditionCommandNames = @($conditionFunctionAst.Body.FindAll({
                    param($node) $node -is [Management.Automation.Language.CommandAst]
                }, $true) | ForEach-Object { [string]$_.GetCommandName() } | Where-Object { $_ } | Select-Object -Unique)
    }
    $conditionAllowedCommands = @('Get-Service', 'Get-Command', 'Get-BRAVOWin32ServiceInfo', 'Select-Object', 'Where-Object',
        'ForEach-Object', 'Get-BRAVOServiceStartMode', 'Read-BRAVOServiceQuiescenceState', 'Test-BRAVOServiceDisabledByOperator')
    $conditionUnexpectedCommands = @($conditionCommandNames | Where-Object { $conditionAllowedCommands -notcontains $_ })
    Test-BRAVOCondition `
        -Condition ($null -ne $conditionFunctionAst -and $conditionCommandNames.Count -gt 0 -and $conditionUnexpectedCommands.Count -eq 0) `
        -Name "ServiceRecovery/ConditionIsReadOnly" `
        -Failure "Get-BRAVOManagedServiceCondition має лише читати (FR-1 #314); неочікувані команди: $($conditionUnexpectedCommands -join ', ')"

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
        -FunctionNames @('Get-Service', 'Get-BRAVOWmiInstance', 'Get-BRAVOWin32ServiceInfo', 'Get-BRAVOServiceStartMode')
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
        -FunctionNames @('Get-Service', 'Get-BRAVOWmiInstance', 'Get-BRAVOWin32ServiceInfo', 'Get-BRAVOServiceStartMode', 'Get-ConfiguredServiceState', 'Test-BRAVOServiceDisabledBySystem')
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
        -FunctionNames @('Get-Service', 'Get-BRAVOWmiInstance', 'Get-BRAVOWin32ServiceInfo', 'Test-BRAVOServiceDisabledByOperator', 'Get-BRAVOServiceStartMode', 'Get-BRAVODataRestoreServiceSnapshot')
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
        -FunctionNames @('Get-Service', 'Get-BRAVOWmiInstance', 'Get-BRAVOWin32ServiceInfo', 'Get-BRAVOServiceStartMode', 'Get-BRAVODryRunConfiguredServiceState')
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
        -FunctionNames @('Get-Service', 'Get-BRAVOWmiInstance', 'Get-BRAVOWin32ServiceInfo', 'Get-BRAVOServiceDelayedAutoStart', 'Get-BRAVOServiceStartMode', 'Set-BRAVOBootRestoreServiceStartType')
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
        $firstServiceStartIndex = $maintenanceTextForStartMode.IndexOf('Start-BRAVOMaintenanceManagedServices `', [Math]::Max(0, $finallyIndex))
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

    # ============================================================
    # #314 хвиля 2: характеризація циклу «зупинка служб -> журнали -> запуск»
    # нічного Maintenance (ТЗ §6 п.2 у формі характеризації). Тест виконує
    # СПРАВЖНІ фрагменти BRAVO.Maintenance.Runtime.ps1 між стабільними
    # якорями (знімок/зупинка, обробка журналів, finally-запуск) у
    # in-memory пісочниці: Get-Service, Invoke-ServiceStateChange,
    # Get/Stop-Process, маркер і сповіщення затінені стабами, що лише
    # записують дії в трасу. Траса кожного сценарію порівнюється з
    # еталоном, знятим на коді ДО винесення циклу у функції: читабельна
    # частина (порядок зупинки/запуску й kill Bis) і SHA256 повної траси
    # (тексти журналу, рівні, сповіщення, маркер, кроки) — винесення не
    # має змінити жодного рядка поведінки.
    # ============================================================
    #region #314-wave2-lifecycle-characterization
    & {
    $lifecycleRuntimeText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"), [Text.Encoding]::UTF8).Replace("`r`n", "`n")
    $lifecycleSystemText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.System\BRAVO.System.psm1"), [Text.Encoding]::UTF8).Replace("`r`n", "`n")
    # #314 хвиля 3: облік спроб і тексти сповіщень (BRAVO.ServiceRecovery) —
    # справжні функції модуля; читання/запис state-файлу затінені стабами.
    $lifecycleRecoveryText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.ServiceRecovery\BRAVO.ServiceRecovery.psm1"), [Text.Encoding]::UTF8).Replace("`r`n", "`n")
    $lifecycleSliceProblems = New-Object System.Collections.Generic.List[string]
    $getLifecycleSlice = {
        param([string]$Text, [string]$StartAnchor, [string]$EndPattern, [bool]$IncludeStart, [bool]$IncludeEnd, [bool]$LastStart = $false)
        $startIndex = if ($LastStart) { $Text.LastIndexOf($StartAnchor, [StringComparison]::Ordinal) } else { $Text.IndexOf($StartAnchor, [StringComparison]::Ordinal) }
        if ($startIndex -lt 0) { [void]$lifecycleSliceProblems.Add("якір '$StartAnchor' не знайдено"); return '' }
        if (-not $IncludeStart) { $startIndex += $StartAnchor.Length }
        $endMatch = ([regex]$EndPattern).Match($Text, $startIndex)
        if (-not $endMatch.Success) { [void]$lifecycleSliceProblems.Add("кінцевий якір '$EndPattern' не знайдено"); return '' }
        $endIndex = if ($IncludeEnd) { $endMatch.Index + $endMatch.Length } else { $endMatch.Index }
        return $Text.Substring($startIndex, $endIndex - $startIndex)
    }
    # Знімок стану -> маркер -> зупинка (до реставрації). Фрагмент відкриває
    # два try-блоки прогону, які закриваються далі у файлі.
    $lifecycleStopSlice = (& $getLifecycleSlice $lifecycleRuntimeText '$script:bravoServiceStartedThisRun = $false' '# ===== ОПЕРАЦІЇ ПІСЛЯ ЗУПИНКИ СЕРВІСІВ =====' $false $false) +
        "`n} finally { }`n} finally { }`n"
    # Обробка журналів, поки служби зупинені (останнє входження якоря:
    # перше належить кроку реставрації).
    $lifecycleLogSlice = & $getLifecycleSlice $lifecycleRuntimeText '$logsCriticalBefore = $script:criticalErrorOccurred' '(?m)^\} finally \{' $true $false $true
    $lifecycleStartSlice = & $getLifecycleSlice $lifecycleRuntimeText "Write-BRAVOProgressPhase -Phase 'Відновлення стану служб'" '-WarningsBefore \$restoreServicesWarningsBefore\)' $true $true
    foreach ($lifecycleSlicePair in @(@('stop', $lifecycleStopSlice), @('logs', $lifecycleLogSlice), @('start', $lifecycleStartSlice))) {
        $lifecycleParseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseInput([string]$lifecycleSlicePair[1], [ref]$null, [ref]$lifecycleParseErrors)
        if (@($lifecycleParseErrors).Count -gt 0) {
            [void]$lifecycleSliceProblems.Add("фрагмент '$($lifecycleSlicePair[0])' не парситься: $(@($lifecycleParseErrors | ForEach-Object { $_.Message }) -join ' | ')")
        }
    }
    # Усі визначення функцій BRAVO.System і runtime (поза тілами інших
    # функцій runtime), потім стаби — вони перекривають однойменні справжні функції.
    $getLifecycleDefinitions = {
        param([string]$Text)
        $definitionAst = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        $definitionTexts = foreach ($functionAst in @($definitionAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
            $parentAst = $functionAst.Parent
            $nested = $false
            while ($null -ne $parentAst) {
                # Тіло runtime — одна функція Invoke-BRAVOMaintenance; її
                # вкладені функції і є функціями runtime.
                if ($parentAst -is [Management.Automation.Language.FunctionDefinitionAst] -and $parentAst.Name -ne 'Invoke-BRAVOMaintenance') { $nested = $true; break }
                $parentAst = $parentAst.Parent
            }
            if (-not $nested -and $functionAst.Name -ne 'Invoke-BRAVOMaintenance') { $functionAst.Extent.Text }
        }
        return (@($definitionTexts) -join "`n`n")
    }
    $lifecycleStubs = @'
function Add-LifecycleTrace { param([string]$Text) [void]$script:fx.Trace.Add($Text) }
function Get-Service {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name, [string]$DisplayName)
    if ($script:fx.Services.ContainsKey($Name)) {
        return [pscustomobject]@{ Name = $Name; DisplayName = $Name; Status = [string]$script:fx.Services[$Name] }
    }
    Write-Error -Message "fake: службу $Name не знайдено" -Category ObjectNotFound
}
function Get-Process {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)
    if (@($script:fx.Processes) -contains $Name) { return [pscustomobject]@{ Name = $Name } }
    Write-Error -Message "fake: процесу $Name немає" -Category ObjectNotFound
}
function Stop-Process {
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force)
    process { Add-LifecycleTrace ("KILL|{0}|Force={1}" -f $InputObject.Name, [bool]$Force) }
}
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
function Write-BRAVOProgressPhase { param([string]$Phase, [int]$PercentComplete) }
function Write-Log {
    param([Parameter(Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO', [switch]$NoConsole, [switch]$Environmental)
    if ($Level -eq 'WARNING' -and -not $Environmental) { $script:BRAVOWarningCount++ }
    Add-LifecycleTrace "LOG|$Level|$Message"
}
function Send-SlackAlert {
    param([string]$Message, [switch]$IsCritical, [string]$Severity)
    if ($IsCritical) { $script:criticalErrorOccurred = $true }
    Add-LifecycleTrace ("ALERT|{0}|{1}|{2}" -f [bool]$IsCritical, $Severity, $Message)
}
# Ранній вихід (exit 20 guard-а -RunMissedRestoreOnly) завершив би процес
# self-test: стаб фіксує його і перериває сценарій винятком.
function Send-BRAVOMaintenanceEarlyExitAlerts { param([string]$Reason) Add-LifecycleTrace "EARLYEXIT|$Reason"; throw "LIFECYCLE-EARLY-EXIT|$Reason" }
function Read-BRAVOServiceQuiescenceState { return $script:fx.Marker }
function Get-BRAVOManagedServiceCondition {
    # Класифікація за правилами Get-BRAVOManagedServiceCondition (FR-1) з
    # фікстури: Running/Pending за станом, інакше Failed (зокрема Paused);
    # Conditions перекриває (OwnedByBravo/Disabled), ExitCodes — ExitCode.
    [CmdletBinding()]
    param([string]$Name, [AllowNull()][object]$Service, [AllowNull()][object]$ServiceInfo, [AllowNull()][object]$QuiescenceState, [switch]$NoWmiQuery)
    $status = if ($script:fx.Services.ContainsKey($Name)) { [string]$script:fx.Services[$Name] } else { $null }
    $condition = if ($script:fx.Conditions.ContainsKey($Name)) { [string]$script:fx.Conditions[$Name] } elseif ($null -eq $status) { 'NotInstalled' } elseif ($status -eq 'Running') { 'Running' } elseif ($status -like '*Pending') { 'Pending' } else { 'Failed' }
    $exitCode = if ($script:fx.ExitCodes.ContainsKey($Name)) { $script:fx.ExitCodes[$Name] } else { $null }
    return [pscustomobject]@{ Name = $Name; Exists = ($null -ne $status); StartMode = 'Auto'; StartModeSource = 'fake'; Status = $status; ExitCode = $exitCode; ServiceSpecificExitCode = $null; Condition = $condition; HeldByBravo = $false; OriginalStartMode = $null; MarkerOwner = $null }
}
function Read-BRAVOServiceRecoveryState {
    Add-LifecycleTrace 'RSTATE-READ'
    $state = $script:fx.RecoveryState
    if ($null -eq $state) { $state = New-BRAVOServiceRecoveryEmptyState }
    return [pscustomobject]@{ State = $state; Status = 'Ok'; Warning = $script:fx.RecoveryReadWarning; QuarantinedPath = $null }
}
function Write-BRAVOServiceRecoveryState {
    param([AllowNull()][object]$State, [datetime]$Now = (Get-Date))
    if ($script:fx.RecoveryWriteFails) { throw 'fake: state відновлення не записано' }
    $script:fx.RecoveryState = $State
    Add-LifecycleTrace ("RSTATE-WRITE|{0}" -f (@(@($State.services.Keys) | Sort-Object | ForEach-Object { '{0}=attempts:{1},critical:{2}' -f $_, @($State.services[$_].attempts).Count, ($null -ne $State.services[$_].lastCriticalAt) }) -join ';'))
}
function Get-BRAVOForeignServiceQuiescenceContext {
    if ($null -ne $script:fx.Foreign) { return $script:fx.Foreign }
    return [pscustomobject]@{ Present = $false; OwnerAlive = $false; RestartSuppressed = $false; RestartIntentNames = @(); Owner = $null; HeldSnapshot = @() }
}
function New-BRAVOServiceStartTypeSnapshot {
    param([string[]]$ServiceNames)
    Add-LifecycleTrace ("SNAPSHOT|{0}" -f (@($ServiceNames) -join ','))
    return @(@($ServiceNames) | ForEach-Object { [pscustomobject]@{ Name = $_; StartMode = 'Automatic' } })
}
function Get-BRAVOMaintenanceUnrestorableServiceNames { param([string[]]$ManagedNames, [object[]]$Snapshot) return @() }
function Write-BRAVOServiceQuiescenceState {
    param([string]$Owner, [object[]]$Services, [string]$LogFile, [object[]]$StartTypeSnapshot, [switch]$RestartSuppressed, [switch]$PreserveForeignStartTypeSnapshot)
    Add-LifecycleTrace ("MARKER|{0}|{1}|suppressed={2}" -f $Owner, (@($Services | ForEach-Object { '{0}={1}' -f $_.Name, [bool]$_.RestartIntent }) -join ','), [bool]$RestartSuppressed)
}
function Suspend-BRAVOServiceAutostart {
    param([object[]]$Snapshot)
    Add-LifecycleTrace ("SUSPEND|{0}" -f (@($Snapshot | ForEach-Object { $_.Name }) -join ','))
    return [pscustomobject]@{ Applied = @($Snapshot | ForEach-Object { $_.Name }); Failed = @() }
}
function Restore-BRAVOServiceStartTypeSnapshot {
    param([object[]]$Snapshot)
    Add-LifecycleTrace ("RESTORETYPES|{0}" -f (@($Snapshot | ForEach-Object { $_.Name }) -join ','))
    return [pscustomobject]@{ Restored = @($Snapshot | ForEach-Object { $_.Name }); Failed = @(); Foreign = @() }
}
function Clear-BRAVOServiceQuiescenceState { Add-LifecycleTrace 'MARKERCLEAR'; return $true }
function Invoke-ServiceStateChange {
    param([string]$Name, [string]$DesiredStatus, [int]$TimeoutSeconds, [int]$PollIntervalSeconds = 2, [switch]$Force)
    Add-LifecycleTrace ("SVC|{0}>{1}|Force={2}" -f $Name, $DesiredStatus, [bool]$Force)
    if (@($script:fx.Failures) -contains "$Name>$DesiredStatus") {
        return [pscustomobject]@{ Success = $false; AlreadyInState = $false; StateChangeIssued = $true; FinalStatus = [string]$script:fx.Services[$Name]; Error = "fake: $Name не перейшла в $DesiredStatus" }
    }
    $script:fx.Services[$Name] = $DesiredStatus
    return [pscustomobject]@{ Success = $true; AlreadyInState = $false; StateChangeIssued = $true; FinalStatus = $DesiredStatus; Error = $null }
}
function Write-BRAVOMaintenanceStep { param([string]$Name, [string]$Status, [string]$Details) Add-LifecycleTrace "STEP|$Name|$Status|$Details" }
function Write-BRAVOMaintenanceOperation { param([string]$Name, [string]$Status, [string]$Details) Add-LifecycleTrace "OPERATION|$Name|$Status|$Details" }
function Invoke-BRAVOTraceRotation { param([object[]]$Sources, [string]$DestinationDirectory, [int]$RetryCount, [int]$RetryDelaySeconds, $Logger) Add-LifecycleTrace 'ROTATE|trace'; return [pscustomobject]@{ Moved = 2; Errors = 0 } }
function Invoke-BRAVOExchangeApiLogRotation { param([string]$SourceDirectory, [string]$DestinationDirectory, [object[]]$Patterns, [int]$RetryCount, [int]$RetryDelaySeconds, $Logger) Add-LifecycleTrace 'ROTATE|exchangAPI'; return [pscustomobject]@{ Found = 3; Moved = 3; Errors = 0 } }
function Invoke-BRAVOApacheLogRotation { param([string]$SourceDirectory, [string]$DestinationDirectory, [string]$Filter, [int]$RetryCount, [int]$RetryDelaySeconds, $Logger) Add-LifecycleTrace 'ROTATE|apache'; return [pscustomobject]@{ Moved = 1; Errors = 0 } }
function Invoke-BRAVOWebApplicationLogRotation { param([string]$SourceDirectory, [string]$DestinationDirectory, [string]$Filter, [int]$RetryCount, [int]$RetryDelaySeconds, $Logger) Add-LifecycleTrace 'ROTATE|www'; return [pscustomobject]@{ Moved = 1; Errors = 0 } }
'@
    $lifecycleModule = $null
    if ($lifecycleSliceProblems.Count -eq 0) {
        $lifecycleModule = New-Module -ScriptBlock {
            param([string]$DefinitionsText, [string]$StubsText)
            Set-StrictMode -Version 2.0
            . ([scriptblock]::Create($DefinitionsText))
            . ([scriptblock]::Create($StubsText))
        } -ArgumentList @(((& $getLifecycleDefinitions $lifecycleSystemText) + "`n`n" + (& $getLifecycleDefinitions $lifecycleRecoveryText) + "`n`n" + (& $getLifecycleDefinitions $lifecycleRuntimeText)), $lifecycleStubs)
    }
    $runLifecycleScenario = {
        param([hashtable]$Scenario)
        & $lifecycleModule {
            param([hashtable]$Scenario, [string]$StopSlice, [string]$LogSlice, [string]$StartSlice)
            $flag = { param([string]$Key, $Default) if ($Scenario.ContainsKey($Key)) { $Scenario[$Key] } else { $Default } }
            $script:fx = @{
                Services = @{ 'BRAVO' = $Scenario.Bravo; 'exchangAPI' = $Scenario.Exchange; 'Apache2.4' = $Scenario.Web }
                Processes = @(& $flag 'Processes' @('Bis'))
                Failures = @(& $flag 'Failures' @())
                Foreign = (& $flag 'Foreign' $null)
                Marker = (& $flag 'Marker' $null)
                Conditions = (& $flag 'Conditions' @{})
                ExitCodes = (& $flag 'ExitCodes' @{})
                RecoveryState = (& $flag 'RecoveryState' $null)
                RecoveryReadWarning = (& $flag 'RecoveryReadWarning' $null)
                RecoveryWriteFails = [bool](& $flag 'RecoveryWriteFails' $false)
                Trace = New-Object System.Collections.Generic.List[string]
            }
            $script:criticalErrorOccurred = $false
            $script:BRAVOWarningCount = 0
            $script:bravoServiceStartedThisRun = $false
            $script:modelIntegrityEstablished = [bool](& $flag 'Integrity' $true)
            $script:BRAVOMaintenanceLogsStepEnabled = $true
            $BravoServiceName = 'BRAVO'; $ExchangAPIServiceName = 'exchangAPI'; $BravoWebServiceName = 'Apache2.4'
            $BravoMaintenanceEnabled = [bool](& $flag 'BravoEnabled' $true)
            $BravoServiceDisabledBySystem = [bool](& $flag 'BravoDisabled' $false)
            $exchangAPIServiceEnabled = [bool](& $flag 'ExchangeEnabled' $true)
            $exchangAPIServiceDisabled = [bool](& $flag 'ExchangeDisabled' $false)
            $BravoWebMaintenanceEnabled = [bool](& $flag 'WebEnabled' $true)
            $restoreOnDisabledBravo = [bool](& $flag 'RestoreOnDisabledBravo' $false)
            $bootRestoreIgnoresWindow = [bool](& $flag 'BootHold' $false)
            $shouldRestore = [bool](& $flag 'ShouldRestore' $false)
            $RunMissedRestoreOnly = [bool](& $flag 'RunMissedRestoreOnly' $false); $missedDailyWork = [bool](& $flag 'RunMissedRestoreOnly' $false); $missedRestoreDue = $false; $scheduledOccurrence = $null
            $LOG_FILE = 'C:\BRAVO\LOGS\BRAVO_MAINTENANCE_selftest.log'
            $ARC_DIR = 'D:\ARC'; $ARCH_NAME1 = 'before.mdz'
            $ServiceStopTimeoutSeconds = 120; $ServiceStartTimeoutSeconds = 180; $ServicePollIntervalSeconds = 2
            $traceConfiguration = $null
            $traceOutSources = @('C:\BRAVO\bravo.out'); $TRACE_DIR = 'D:\TRACE'; $MoveRetryCount = 1; $MoveRetryDelaySeconds = 0; $bravoLogRotationLogger = $null
            $traceOutputProcessedCount = 0; $traceOutputProcessed = $false
            $exchangAPILogsFoundCount = 0; $exchangAPILogsProcessedCount = 0; $webApacheLogsProcessedCount = 0; $webWwwLogsProcessedCount = 0
            $exchangeApiRuntime = [pscustomobject]@{ Directory = 'C:\exchangAPI\logs' }
            $EXCHANGE_LOG_DIR = 'D:\EXCHANGE'; $EXCHANGAPI_LOG_FILTERS = @('*.log')
            $ApacheEnabled = [bool](& $flag 'ApacheEnabled' $true)
            $APACHE_LOGS_DIR = 'C:\Apache24\logs'; $APACHE_DAILY_LOG_DIR = 'D:\APACHE'; $APACHE_LOG_FILTER = '*.log'
            $WWW_LOGS_DIR = 'C:\www\logs'; $BRAVOWEB_APP_DAILY_LOG_DIR = 'D:\WWW'; $BRAVOWEB_APP_LOG_FILTER = '*.log'
            . ([scriptblock]::Create($StopSlice)) | ForEach-Object { Add-LifecycleTrace "OUT|$_" }
            # Між зупинкою і журналами runtime знімає стан BRAVO для воріт
            # файлової фази (поза межами циклу служб) — та сама формула.
            $bravoStatus = if ($BravoMaintenanceEnabled -or $restoreOnDisabledBravo) { [string](Get-Service -Name $BravoServiceName).Status } else { 'Unavailable' }
            $bravoFilePhaseAllowed = (($BravoMaintenanceEnabled -or $restoreOnDisabledBravo) -and $bravoStatus -in @('Stopped', 'Paused'))
            . ([scriptblock]::Create($LogSlice)) | ForEach-Object { Add-LifecycleTrace "OUT|$_" }
            Add-LifecycleTrace ("COUNTS|trace={0}/{1}|exchange={2}/{3}|apache={4}|www={5}" -f $traceOutputProcessedCount, $traceOutputProcessed, $exchangAPILogsFoundCount, $exchangAPILogsProcessedCount, $webApacheLogsProcessedCount, $webWwwLogsProcessedCount)
            . ([scriptblock]::Create($StartSlice)) | ForEach-Object { Add-LifecycleTrace "OUT|$_" }
            Add-LifecycleTrace ("END|critical={0}|warnings={1}|restartFailed={2}|bravoStarted={3}|final={4}" -f $script:criticalErrorOccurred, $script:BRAVOWarningCount, $serviceRestartFailed, $script:bravoServiceStartedThisRun,
                $((@('BRAVO', 'exchangAPI', 'Apache2.4') | ForEach-Object { '{0}={1}' -f $_, $script:fx.Services[$_] }) -join ','))
            return $script:fx.Trace.ToArray()
        } $Scenario $lifecycleStopSlice $lifecycleLogSlice $lifecycleStartSlice
    }
    $getLifecycleOrderSummary = {
        param([string[]]$Trace)
        $stopPart = @($Trace | Where-Object { $_ -match '^SVC\|.+>Stopped' -or $_ -like 'KILL|*' } | ForEach-Object { if ($_ -like 'KILL|*') { 'kill ' + $_.Split('|')[1] } else { $_.Split('|')[1].Split('>')[0] } }) -join ' '
        $startPart = @($Trace | Where-Object { $_ -match '^SVC\|.+>Running' } | ForEach-Object { $_.Split('|')[1].Split('>')[0] }) -join ' '
        return "stop: $stopPart | start: $startPart"
    }
    $getLifecycleTraceHash = {
        param([string[]]$Trace)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Trace -join "`n"))) | ForEach-Object { $_.ToString('x2') }) -join '')
        } finally { $sha.Dispose() }
    }
    # Еталон знято на коді до винесення (developer 758df84). Order —
    # фактичний порядок зупинки (з kill Bis) і запуску.
    # #314 хвиля 3 (FR-2), свідома зміна поведінки: зупинена (не Disabled/
    # OwnedByBravo) керована служба — «впала» і запускається після
    # обслуговування з обліком спроби та WARNING Recovered; попередження
    # Send-InactiveServiceWarning прибрано. Сценарії без впалих служб
    # (AllRunning, BravoStartPendingWebPaused, ExchangeAndWebUnmanaged,
    # BootHoldAllStopped, ModelIntegrityNotEstablished, ExchangeStartFails,
    # ExchangeStopFails, BravoStartFails, BravoDisabledNoRestore,
    # NoApacheLogs) мають ту саму трасу без рядка INACTIVE (порядок
    # незмінний, змінився лише хеш); у решті впала служба додалася до
    # маркера і запуску. У InheritedExchangeIntent exchangAPI — під маркером
    # мертвого власника (OwnedByBravo), як і в реальному класифікаторі.
    $lifecycleScenarios = [ordered]@{
        AllRunning = @{ Spec = @{ Bravo = 'Running'; Exchange = 'Running'; Web = 'Running' }; Order = 'stop: Apache2.4 exchangAPI kill Bis BRAVO | start: BRAVO exchangAPI Apache2.4'; Hash = '04559c8be40ea57529898ac438fa1935720e1e5b2d7c85650860ca51b5576f53' }
        OnlyBravoRunning = @{ Spec = @{ Bravo = 'Running'; Exchange = 'Stopped'; Web = 'Stopped' }; Order = 'stop: kill Bis BRAVO | start: BRAVO exchangAPI Apache2.4'; Hash = 'b73c13f5cac98d581ee1b2c1f87d9d46c1c5006dffade93386c4e70781827a2d' }
        OnlyExchangeRunning = @{ Spec = @{ Bravo = 'Stopped'; Exchange = 'Running'; Web = 'Stopped' }; Order = 'stop: exchangAPI | start: BRAVO exchangAPI Apache2.4'; Hash = 'ddbfe85aa7dc54701d6ceaf984502032560d476146b6150883247d220ae6c804' }
        OnlyWebRunning = @{ Spec = @{ Bravo = 'Stopped'; Exchange = 'Stopped'; Web = 'Running' }; Order = 'stop: Apache2.4 | start: BRAVO exchangAPI Apache2.4'; Hash = '1023df171a69ba9b926391a8895eee4bef5fd0c2fb84a640c958ca9c115e82a0' }
        BravoAndExchangeRunning = @{ Spec = @{ Bravo = 'Running'; Exchange = 'Running'; Web = 'Stopped' }; Order = 'stop: exchangAPI kill Bis BRAVO | start: BRAVO exchangAPI Apache2.4'; Hash = '6b0d235a11c500877f54f8666c6f918f2cfe165a386735370ab9e27578f6178a' }
        BravoFailedOthersRunning = @{ Spec = @{ Bravo = 'Stopped'; Exchange = 'Running'; Web = 'Running' }; Order = 'stop: Apache2.4 exchangAPI | start: BRAVO exchangAPI Apache2.4'; Hash = '7eb4fb00d12931443cb7a5abccb58f6eeabfb03922693220907f76101b476cdf' }
        AllStopped = @{ Spec = @{ Bravo = 'Stopped'; Exchange = 'Stopped'; Web = 'Stopped' }; Order = 'stop:  | start: BRAVO exchangAPI Apache2.4'; Hash = '3391d5389c523068eaad874ff67e0f708defa3e80b66a15c385adfb8d2060a0e' }
        BravoStartPendingWebPaused = @{ Spec = @{ Bravo = 'StartPending'; Exchange = 'Running'; Web = 'Paused' }; Order = 'stop: exchangAPI kill Bis BRAVO | start: BRAVO exchangAPI'; Hash = '7820af31fee912b7e362b4b705609e13e4c78029f31233610a700dd8fe730518' }
        ExchangeAndWebUnmanaged = @{ Spec = @{ Bravo = 'Running'; Exchange = 'Stopped'; Web = 'Running'; ExchangeEnabled = $false; ExchangeDisabled = $true; WebEnabled = $false }; Order = 'stop: kill Bis BRAVO | start: BRAVO'; Hash = 'a617ef1e79c8e6809b4cdeea72948c8f3f10a71cf5393727976e5fc31429d854' }
        BootHoldAllStopped = @{ Spec = @{ Bravo = 'Stopped'; Exchange = 'Stopped'; Web = 'Stopped'; BootHold = $true; ShouldRestore = $true }; Order = 'stop:  | start: BRAVO exchangAPI Apache2.4'; Hash = 'd5e9a69f7d9472fbf469e40c3e4fc53432938bcd1ea701687aadaeba345ac19d' }
        RestoreHoldsAllManaged = @{ Spec = @{ Bravo = 'Running'; Exchange = 'Stopped'; Web = 'Running'; ShouldRestore = $true }; Order = 'stop: Apache2.4 kill Bis BRAVO | start: BRAVO exchangAPI Apache2.4'; Hash = '6d8d01ee8ff7dc2c16f07997ee231a540b17b83b5187f3d5aa4e14c19659680d' }
        InheritedExchangeIntent = @{ Spec = @{ Bravo = 'Running'; Exchange = 'Stopped'; Web = 'Stopped'; Foreign = [pscustomobject]@{ Present = $true; OwnerAlive = $false; RestartSuppressed = $false; RestartIntentNames = @('exchangAPI'); Owner = 'BRAVO_MAINTENANCE'; HeldSnapshot = @() }; Conditions = @{ exchangAPI = 'OwnedByBravo' } }; Order = 'stop: kill Bis BRAVO | start: BRAVO exchangAPI Apache2.4'; Hash = 'fef70ddf21962d79247dad8d8a0704db80c0aca763f8e91a2d2b54da0f497346' }
        ModelIntegrityNotEstablished = @{ Spec = @{ Bravo = 'Running'; Exchange = 'Running'; Web = 'Running'; Integrity = $false }; Order = 'stop: Apache2.4 exchangAPI kill Bis BRAVO | start: '; Hash = 'bba0f62a7854e4c4943ab5d131810cd9a583cfb12192e5aa63eef8c00e8421db' }
        BravoStopFails = @{ Spec = @{ Bravo = 'Running'; Exchange = 'Running'; Web = 'Stopped'; Failures = @('BRAVO>Stopped') }; Order = 'stop: exchangAPI kill Bis BRAVO | start: exchangAPI Apache2.4'; Hash = '4add142801345196e65d64f4f33eaa5ad335cec8c229deca7074db04e28243ac' }
        ExchangeStartFails = @{ Spec = @{ Bravo = 'Running'; Exchange = 'Running'; Web = 'Running'; Failures = @('exchangAPI>Running') }; Order = 'stop: Apache2.4 exchangAPI kill Bis BRAVO | start: BRAVO exchangAPI Apache2.4'; Hash = 'f5e3076b91598d61a588f180d80df4adc45da36448bb7e9a46752928424e6679' }
        WebStopFails = @{ Spec = @{ Bravo = 'Running'; Exchange = 'Stopped'; Web = 'Running'; Failures = @('Apache2.4>Stopped') }; Order = 'stop: Apache2.4 kill Bis BRAVO | start: BRAVO exchangAPI'; Hash = '62dde77579a5403942b2a27f8f1ff173216f38b6713c67183196b12176adacbe' }
        DisabledBravoForceRestore = @{ Spec = @{ Bravo = 'Stopped'; Exchange = 'Running'; Web = 'Stopped'; BravoEnabled = $false; BravoDisabled = $true; RestoreOnDisabledBravo = $true }; Order = 'stop: exchangAPI kill Bis | start: exchangAPI Apache2.4'; Hash = 'b752c332645c737abcdbf10d2ab7a545a87e9d4737f49969da8d4bcea7ad16c5' }
        ExchangeStopFails = @{ Spec = @{ Bravo = 'Running'; Exchange = 'Running'; Web = 'Running'; Failures = @('exchangAPI>Stopped') }; Order = 'stop: Apache2.4 exchangAPI kill Bis BRAVO | start: BRAVO Apache2.4'; Hash = '1a8e477ed2acd85c7a46389b8cdef563682a0774deaac62ce86958993b0cdcb5' }
        BravoStartFails = @{ Spec = @{ Bravo = 'Running'; Exchange = 'Running'; Web = 'Running'; Failures = @('BRAVO>Running') }; Order = 'stop: Apache2.4 exchangAPI kill Bis BRAVO | start: BRAVO exchangAPI Apache2.4'; Hash = '874549aa7d4df955beca593b79da74c9045d123a18dbcaf5ac09e4c5e806e094' }
        BravoDisabledNoRestore = @{ Spec = @{ Bravo = 'Stopped'; Exchange = 'Running'; Web = 'Running'; BravoEnabled = $false; BravoDisabled = $true }; Order = 'stop: Apache2.4 exchangAPI | start: exchangAPI Apache2.4'; Hash = '1f89afe18b1bd755502fc8ba81d35a19bda610b193bd608312a7863751c1eb25' }
        BravoNotInstalled = @{ Spec = @{ Bravo = 'Stopped'; Exchange = 'Running'; Web = 'Stopped'; BravoEnabled = $false }; Order = 'stop: exchangAPI | start: exchangAPI Apache2.4'; Hash = '7052b26159c89c57126529493178c9912f64fe1bc5537a5f2add9e49b52e0f94' }
        NoApacheLogs = @{ Spec = @{ Bravo = 'Running'; Exchange = 'Running'; Web = 'Running'; ApacheEnabled = $false; Processes = @() }; Order = 'stop: Apache2.4 exchangAPI BRAVO | start: BRAVO exchangAPI Apache2.4'; Hash = '1e1141a5aa174f9331491caa98f3d68f4b46f2f967ca88a91a6d46752a182cf9' }
    }
    $lifecycleDiffs = New-Object System.Collections.Generic.List[string]
    $lifecycleActual = [ordered]@{}
    if ($null -ne $lifecycleModule) {
        foreach ($lifecycleName in $lifecycleScenarios.Keys) {
            $lifecycleCase = $lifecycleScenarios[$lifecycleName]
            $lifecycleTrace = @()
            try {
                $lifecycleTrace = @(& $runLifecycleScenario $lifecycleCase.Spec)
            } catch {
                [void]$lifecycleDiffs.Add("${lifecycleName}: виняток $($_.Exception.Message)")
                continue
            }
            $lifecycleOrder = & $getLifecycleOrderSummary $lifecycleTrace
            $lifecycleHash = & $getLifecycleTraceHash $lifecycleTrace
            $lifecycleActual[$lifecycleName] = "$lifecycleHash :: $lifecycleOrder"
            if ($lifecycleOrder -cne [string]$lifecycleCase.Order) {
                [void]$lifecycleDiffs.Add("${lifecycleName}: порядок '$lifecycleOrder' (очікувався '$($lifecycleCase.Order)')")
            }
            if ($lifecycleHash -cne [string]$lifecycleCase.Hash) {
                [void]$lifecycleDiffs.Add("${lifecycleName}: траса $lifecycleHash (еталон $($lifecycleCase.Hash)): $($lifecycleTrace -join ' ¶ ')")
            }
        }
    }
    if ($env:BRAVO_SELFTEST_LIFECYCLE_DUMP) {
        foreach ($lifecycleName in $lifecycleActual.Keys) { Write-Host "LIFECYCLE $lifecycleName = $($lifecycleActual[$lifecycleName])" }
        if ($env:BRAVO_SELFTEST_LIFECYCLE_DUMP -ne "1") { $lifecycleDumpTrace = @(& $runLifecycleScenario $lifecycleScenarios[$env:BRAVO_SELFTEST_LIFECYCLE_DUMP].Spec); $lifecycleDumpTrace | ForEach-Object { Write-Host "  $_" } }
    }
    Test-BRAVOCondition `
        -Condition ($lifecycleSliceProblems.Count -eq 0 -and $lifecycleDiffs.Count -eq 0) `
        -Name "ServiceRecovery/MaintenanceLifecycleCharacterization" `
        -Failure "цикл служб нічного Maintenance (знімок -> маркер -> зупинка Web/exchangAPI/BRAVO -> журнали -> запуск BRAVO/exchangAPI/Web) має поводитися як до винесення у функції: $(@($lifecycleSliceProblems) + @($lifecycleDiffs) -join ' || ')"
    # ============================================================
    # #314 хвиля 3 (тест 7, FR-2/FR-6): нічний Maintenance вважає впалою
    # службу, що Stopped і не Disabled/OwnedByBravo/NotInstalled (план §0.3):
    # вона входить у маркер із RestartIntent, запускається після
    # обслуговування в канонічному порядку, спроба рахується в state-файлі
    # (нічний прогін паузу ігнорує), успіх -> INFO + WARNING «Recovered»
    # (+ CRITICAL «циклічно падає» за CyclicAlertDue), невдача -> наявна
    # CRITICAL-гілка з текстом StartFailed. Guard -RunMissedRestoreOnly
    # дивиться на фактично активні служби. Та сама пісочниця, що й
    # характеризація вище (справжні фрагменти runtime).
    # ============================================================
    $nightlyProblems = New-Object System.Collections.Generic.List[string]
    $nightlyLog = 'C:\BRAVO\LOGS\BRAVO_MAINTENANCE_selftest.log'
    $runNightlyScenario = {
        param([string]$Label, [hashtable]$Spec)
        $nightlyEarlyExit = $null
        $nightlyTrace = @()
        try {
            $nightlyTrace = @(& $runLifecycleScenario $Spec)
        } catch {
            if ($_.Exception.Message -like 'LIFECYCLE-EARLY-EXIT|*') {
                $nightlyEarlyExit = $_.Exception.Message
                $nightlyTrace = @(& $lifecycleModule { $script:fx.Trace.ToArray() })
            } else {
                [void]$nightlyProblems.Add("${Label}: виняток $($_.Exception.Message)")
            }
        }
        return [pscustomobject]@{ Trace = $nightlyTrace; EarlyExit = $nightlyEarlyExit; Text = ($nightlyTrace -join ' ¶ ') }
    }
    $nightlyExpect = {
        param([string]$Label, $Run, [bool]$Condition, [string]$What)
        if (-not $Condition) { [void]$nightlyProblems.Add("${Label}: $What; траса: $($Run.Text)") }
    }
    $nightlyStarts = { param($Run) (@($Run.Trace | Where-Object { $_ -match '^SVC\|.+>Running' } | ForEach-Object { $_.Split('|')[1].Split('>')[0] }) -join ' ') }
    $nightlyHas = { param($Run, [string]$Prefix) @($Run.Trace | Where-Object { $_.StartsWith($Prefix, [StringComparison]::Ordinal) }).Count -gt 0 }
    $nightlyLast = { param($Run, [string]$Prefix) @($Run.Trace | Where-Object { $_.StartsWith($Prefix, [StringComparison]::Ordinal) }) | Select-Object -Last 1 }

    if ($null -ne $lifecycleModule) {
        # (1) exchangAPI впала (ExitCode 1067), BRAVO і BRAVO Web працюють.
        $run = & $runNightlyScenario 'ExchangeFailed' @{ Bravo = 'Running'; Exchange = 'Stopped'; Web = 'Running'; ExitCodes = @{ exchangAPI = 1067 } }
        & $nightlyExpect 'ExchangeFailed' $run (& $nightlyHas $run 'MARKER|BRAVO_MAINTENANCE|BRAVO=True,exchangAPI=True,Apache2.4=True|') 'маркер має містити exchangAPI з RestartIntent=True'
        & $nightlyExpect 'ExchangeFailed' $run ((& $nightlyStarts $run) -ceq 'BRAVO exchangAPI Apache2.4') "запуск має бути BRAVO -> exchangAPI -> Apache2.4, отримано '$(& $nightlyStarts $run)'"
        & $nightlyExpect 'ExchangeFailed' $run (& $nightlyHas $run 'LOG|INFO|Служба exchangAPI була зупинена до обслуговування (ExitCode 1067) — буде запущена після обслуговування (#314)') 'INFO на старті про впалу службу'
        & $nightlyExpect 'ExchangeFailed' $run (& $nightlyHas $run 'LOG|INFO|Служба exchangAPI була зупинена до обслуговування (ExitCode 1067), запущена') 'INFO про запуск впалої служби'
        & $nightlyExpect 'ExchangeFailed' $run (& $nightlyHas $run "ALERT|False|WARNING|Служба exchangAPI впала (ExitCode 1067), журнали збережено, запущена. Спроба 1 за добу. Журнал: $nightlyLog") 'WARNING Recovered без -IsCritical'
        & $nightlyExpect 'ExchangeFailed' $run ((& $nightlyLast $run 'RSTATE-WRITE|') -ceq 'RSTATE-WRITE|exchangAPI=attempts:1,critical:False') "облік спроби в state: '$(& $nightlyLast $run 'RSTATE-WRITE|')'"
        & $nightlyExpect 'ExchangeFailed' $run (-not ($run.Text -match 'циклічно падає')) 'на першій спробі CRITICAL «циклічно падає» не надсилається'
        & $nightlyExpect 'ExchangeFailed' $run (-not ($run.Text -match 'До початку maintenance не запущені служби|INACTIVE\|')) 'попередження про неактивні служби прибрано'
        & $nightlyExpect 'ExchangeFailed' $run (& $nightlyHas $run 'END|critical=False|warnings=0|restartFailed=False|') 'прогін без критичних помилок і попереджень'

        # (2) Третя спроба за добу -> CRITICAL «циклічно падає» (без -IsCritical) і lastCriticalAt.
        $nightlyNow = Get-Date
        $nightlyPriorState = [pscustomobject]@{
            schemaVersion = 1; hostname = [Environment]::MachineName; updatedAt = $null
            services = @{ exchangAPI = [pscustomobject]@{ attempts = @($nightlyNow.AddHours(-3).ToString('o'), $nightlyNow.AddHours(-2).ToString('o')); lastCriticalAt = $null; stableSince = $null } }
        }
        $run = & $runNightlyScenario 'ExchangeCyclic' @{ Bravo = 'Running'; Exchange = 'Stopped'; Web = 'Running'; ExitCodes = @{ exchangAPI = 1067 }; RecoveryState = $nightlyPriorState }
        & $nightlyExpect 'ExchangeCyclic' $run (& $nightlyHas $run 'ALERT|False|WARNING|Служба exchangAPI впала (ExitCode 1067), журнали збережено, запущена. Спроба 3 за добу.') 'Recovered зі спробою 3'
        & $nightlyExpect 'ExchangeCyclic' $run (& $nightlyHas $run ('ALERT|False|CRITICAL|Служба exchangAPI циклічно падає: 3 падінь з {0}, потрібне втручання. Журнал: {1}' -f $nightlyNow.AddHours(-3).ToString('dd.MM HH:mm', [Globalization.CultureInfo]::InvariantCulture), $nightlyLog)) 'CRITICAL «циклічно падає» без -IsCritical'
        & $nightlyExpect 'ExchangeCyclic' $run ((& $nightlyLast $run 'RSTATE-WRITE|') -ceq 'RSTATE-WRITE|exchangAPI=attempts:3,critical:True') "lastCriticalAt у state: '$(& $nightlyLast $run 'RSTATE-WRITE|')'"
        & $nightlyExpect 'ExchangeCyclic' $run (& $nightlyHas $run 'END|critical=False|') 'Cyclic не провалює прогін'

        # (3) Запуск впалої служби не вдався -> CRITICAL StartFailed (-IsCritical), без Recovered.
        $run = & $runNightlyScenario 'ExchangeFailedStartFails' @{ Bravo = 'Running'; Exchange = 'Stopped'; Web = 'Running'; ExitCodes = @{ exchangAPI = 1067 }; Failures = @('exchangAPI>Running') }
        & $nightlyExpect 'ExchangeFailedStartFails' $run (& $nightlyHas $run "ALERT|True||Не вдалося запустити службу exchangAPI після падіння (ExitCode 1067): fake: exchangAPI не перейшла в Running. Спроба 1 за добу. Журнал: $nightlyLog") 'CRITICAL StartFailed'
        & $nightlyExpect 'ExchangeFailedStartFails' $run (-not ($run.Text -match 'ALERT\|False\|WARNING\|Служба exchangAPI впала')) 'без Recovered'
        & $nightlyExpect 'ExchangeFailedStartFails' $run ((& $nightlyLast $run 'RSTATE-WRITE|') -ceq 'RSTATE-WRITE|exchangAPI=attempts:1,critical:False') 'невдала спроба теж рахується'
        & $nightlyExpect 'ExchangeFailedStartFails' $run ((& $nightlyHas $run 'END|critical=True|') -and $run.Text.Contains('|restartFailed=True|')) 'критична помилка, маркер лишається'
        & $nightlyExpect 'ExchangeFailedStartFails' $run ((& $nightlyStarts $run) -ceq 'BRAVO exchangAPI Apache2.4') 'Apache2.4 запускається після невдачі exchangAPI'

        # (4) Зупинена служба під маркером BRAVO (OwnedByBravo) — не впала, не запускається.
        $run = & $runNightlyScenario 'ExchangeOwnedByBravo' @{ Bravo = 'Running'; Exchange = 'Stopped'; Web = 'Running'; Conditions = @{ exchangAPI = 'OwnedByBravo' } }
        & $nightlyExpect 'ExchangeOwnedByBravo' $run ((& $nightlyStarts $run) -ceq 'BRAVO Apache2.4') "OwnedByBravo не запускається, отримано '$(& $nightlyStarts $run)'"
        & $nightlyExpect 'ExchangeOwnedByBravo' $run (-not (& $nightlyHas $run 'RSTATE-')) 'state відновлення не чіпається'

        # (5) Усі служби працюють — state відновлення не читається і не пишеться.
        $run = & $runNightlyScenario 'AllRunning' @{ Bravo = 'Running'; Exchange = 'Running'; Web = 'Running' }
        & $nightlyExpect 'AllRunning' $run (-not (& $nightlyHas $run 'RSTATE-') -and -not ($run.Text -match 'ALERT\|')) 'без впалих служб — ні state, ні сповіщень'

        # (6) #321: -ForceRestore при Disabled BRAVO — BRAVO не запускається, впалі exchangAPI/BRAVO Web — запускаються.
        $run = & $runNightlyScenario 'DisabledBravoForceRestoreFailedOthers' @{ Bravo = 'Stopped'; Exchange = 'Stopped'; Web = 'Stopped'; BravoEnabled = $false; BravoDisabled = $true; RestoreOnDisabledBravo = $true }
        & $nightlyExpect 'DisabledBravoForceRestoreFailedOthers' $run ((& $nightlyStarts $run) -ceq 'exchangAPI Apache2.4') "очікувався запуск exchangAPI Apache2.4, отримано '$(& $nightlyStarts $run)'"
        & $nightlyExpect 'DisabledBravoForceRestoreFailedOthers' $run (-not ($run.Text -match 'Служба BRAVO впала')) 'Disabled BRAVO не є впалою'
        & $nightlyExpect 'DisabledBravoForceRestoreFailedOthers' $run (& $nightlyHas $run 'KILL|Bis|') 'точка розширення #316 для Disabled BRAVO лишається'

        # (7) Guard -RunMissedRestoreOnly: впалі служби не є «уже працюючими».
        $run = & $runNightlyScenario 'RecoveryTickAllFailed' @{ Bravo = 'Stopped'; Exchange = 'Stopped'; Web = 'Stopped'; RunMissedRestoreOnly = $true }
        & $nightlyExpect 'RecoveryTickAllFailed' $run ($null -eq $run.EarlyExit) "впалі служби не мають давати exit 20 ($($run.EarlyExit))"
        & $nightlyExpect 'RecoveryTickAllFailed' $run ((& $nightlyStarts $run) -ceq 'BRAVO exchangAPI Apache2.4') "впалі служби запускаються, отримано '$(& $nightlyStarts $run)'"
        $run = & $runNightlyScenario 'RecoveryTickBravoRunning' @{ Bravo = 'Running'; Exchange = 'Stopped'; Web = 'Stopped'; RunMissedRestoreOnly = $true }
        & $nightlyExpect 'RecoveryTickBravoRunning' $run ($null -ne $run.EarlyExit -and $run.Text.Contains('уже працюють служби BRAVO. Recovery не зупиняє служби.')) 'працююча BRAVO лишає guard (exit 20) з переліком лише фактично працюючих служб'

        # (8) Boot-hold профілю робочого часу: зупинені на boot служби — утримання, а не падіння.
        $run = & $runNightlyScenario 'BootHoldNoRecoveryAccounting' @{ Bravo = 'Stopped'; Exchange = 'Stopped'; Web = 'Stopped'; BootHold = $true; ShouldRestore = $true }
        & $nightlyExpect 'BootHoldNoRecoveryAccounting' $run ((& $nightlyStarts $run) -ceq 'BRAVO exchangAPI Apache2.4' -and -not (& $nightlyHas $run 'RSTATE-') -and -not ($run.Text -match 'впала')) 'boot-hold піднімає служби без обліку спроб і Recovered'

        # (9) Збій запису state — лише WARNING, служба все одно запускається.
        $run = & $runNightlyScenario 'RecoveryStateWriteFails' @{ Bravo = 'Running'; Exchange = 'Stopped'; Web = 'Running'; RecoveryWriteFails = $true }
        & $nightlyExpect 'RecoveryStateWriteFails' $run ((& $nightlyStarts $run) -ceq 'BRAVO exchangAPI Apache2.4' -and (& $nightlyHas $run 'LOG|WARNING|') -and (& $nightlyHas $run 'END|critical=False|')) 'збій state не блокує запуск і не є критичним'
    } else {
        [void]$nightlyProblems.Add('пісочниця runtime не зібрана')
    }
    Test-BRAVOCondition `
        -Condition ($lifecycleSliceProblems.Count -eq 0 -and $nightlyProblems.Count -eq 0) `
        -Name "ServiceRecovery/NightlyMaintenanceStartsFailedServices" `
        -Failure "нічний Maintenance має піднімати впалу службу (маркер RestartIntent, порядок BRAVO -> exchangAPI -> BRAVO Web, облік спроби, WARNING Recovered / CRITICAL Cyclic / CRITICAL StartFailed, guard за фактично активними): $(@($lifecycleSliceProblems) + @($nightlyProblems) -join ' || ')"
    }
    #endregion #314-wave2-lifecycle-characterization

    # ============================================================
    # #314 хвиля 2: чисті функції плану життєвого циклу керованих служб
    # (BRAVO.System) — «кого зупиняти / кого запускати і в якому порядку»
    # без Windows (ТЗ §6 п.2). Порядки збігаються з характеризацією циклу
    # служб нічного Maintenance вище (без kill Bis — це точка розширення
    # #316, а не рішення плану). StrictMode 2.0; 0/1/кілька служб.
    # ============================================================
    #region #314-wave2-lifecycle-plan
    & {
    $lifecyclePlanModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $systemModuleTextForQuiescence `
        -FunctionNames @('Get-BRAVOManagedServiceOrder', 'Test-BRAVOManagedServiceActiveStatus', 'Test-BRAVOServiceStartRequired',
            'Get-BRAVOServiceStopDecision', 'Get-BRAVOManagedServiceRestartIntent', 'Get-BRAVOInheritedServiceRestartIntent',
            'Get-BRAVOServiceQuiescenceScope', 'Get-BRAVOManagedServiceLifecyclePlan', 'Test-BRAVOServiceDisabledByOperator')
    $lifecyclePlanProbe = & $lifecyclePlanModule {
        Set-StrictMode -Version 2.0
        $newServices = {
            param([string]$Bravo, [string]$Exchange, [string]$Web, [bool]$BravoEnabled = $true, [bool]$ExchangeEnabled = $true, [bool]$WebEnabled = $true)
            @(
                @{ Key = 'Bravo'; Name = 'BRAVO'; Enabled = $BravoEnabled; Status = $Bravo },
                @{ Key = 'ExchangeApi'; Name = 'exchangAPI'; Enabled = $ExchangeEnabled; Status = $Exchange },
                @{ Key = 'BravoWeb'; Name = 'Apache2.4'; Enabled = $WebEnabled; Status = $Web }
            )
        }
        $formatPlan = {
            param($Plan)
            'stop: {0} | start: {1} | marker: {2}' -f (@($Plan.StopOrder) -join ' '), (@($Plan.StartOrder) -join ' '),
                (@($Plan.QuiescenceServices | ForEach-Object { '{0}={1}' -f $_.Name, $_.RestartIntent }) -join ',')
        }
        $out = [ordered]@{}
        $out['Order'] = '{0} / {1}' -f (@(Get-BRAVOManagedServiceOrder -Direction Start) -join ','), (@(Get-BRAVOManagedServiceOrder -Direction Stop) -join ',')
        $out['AllRunning'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'Running' 'Running' 'Running'))
        $out['OnlyBravoRunning'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'Running' 'Stopped' 'Stopped'))
        $out['OnlyExchangeRunning'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'Stopped' 'Running' 'Stopped'))
        $out['OnlyWebRunning'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'Stopped' 'Stopped' 'Running'))
        $out['BravoAndExchangeRunning'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'Running' 'Running' 'Stopped'))
        $out['BravoFailedOthersRunning'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'Stopped' 'Running' 'Running'))
        $out['AllStopped'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'Stopped' 'Stopped' 'Stopped'))
        $out['BravoStartPendingWebPaused'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'StartPending' 'Running' 'Paused'))
        $out['ExchangeAndWebUnmanaged'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'Running' 'Stopped' 'Running' $true $false $false))
        $out['BravoUnmanaged'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'Stopped' 'Running' 'Running' $false $true $true))
        $out['BootHoldAllStopped'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'Stopped' 'Stopped' 'Stopped') -HoldAllEnabled -HoldAllManagedForRestore)
        $out['RestoreHoldsAllManaged'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'Running' 'Stopped' 'Running') -HoldAllManagedForRestore)
        $out['InheritedExchangeIntent'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'Running' 'Stopped' 'Stopped') -InheritedRestartIntentNames @('EXCHANGAPI'))
        $out['ModelIntegrityNotEstablished'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'Running' 'Running' 'Running') -ModelIntegrityEstablished $false)
        $out['BravoStopPendingNoIntent'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services (& $newServices 'StopPending' 'Running' 'Stopped'))
        $out['SingleServiceList'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services @(@{ Key = 'ExchangeApi'; Name = 'exchangAPI'; Enabled = $true; Status = 'Running' }))
        $out['EmptyServiceList'] = & $formatPlan (Get-BRAVOManagedServiceLifecyclePlan -Services @())
        # Знімок наміру: StartPending = працює; boot-hold — усі керовані.
        $intent = Get-BRAVOManagedServiceRestartIntent -Services (& $newServices 'StartPending' 'Paused' $null $true $true $false)
        $intentHold = Get-BRAVOManagedServiceRestartIntent -Services (& $newServices 'Stopped' 'Stopped' 'Stopped' $true $true $false) -HoldAllEnabled
        $out['RestartIntent'] = 'Bravo={0},ExchangeApi={1},BravoWeb={2} / hold: Bravo={3},ExchangeApi={4},BravoWeb={5}' -f $intent.Bravo, $intent.ExchangeApi, $intent.BravoWeb, $intentHold.Bravo, $intentHold.ExchangeApi, $intentHold.BravoWeb
        $inherited = @(Get-BRAVOInheritedServiceRestartIntent -Services (& $newServices 'Running' 'Stopped' 'Stopped' $true $true $false) -RestartIntent @{ Bravo = $true; ExchangeApi = $false; BravoWeb = $false } -ForeignRestartIntentNames @('BRAVO', 'exchangapi', 'Apache2.4'))
        $out['Inherited'] = @($inherited | ForEach-Object { '{0}:{1}' -f $_.Key, $_.Name }) -join ','
        # Рішення зупинки (#360) і запуску.
        $out['StopDecision'] = @(
            @($null, $false, $true), @('', $true, $true), @('Stopped', $true, $true), @('Paused', $true, $true), @('PausePending', $false, $true),
            @('ContinuePending', $true, $true), @('StopPending', $false, $true), @('StopPending', $true, $true), @('Running', $true, $false),
            @('StartPending', $false, $true), @('Running', $false, $true), @('Running', $true, $true)
        ) | ForEach-Object { '{0}/{1}/{2}={3}' -f $_[0], $_[1], $_[2], (Get-BRAVOServiceStopDecision -Status $_[0] -HasRestartIntent $_[1] -InQuiescenceScope $_[2]) }
        $out['StopDecision'] = @($out['StopDecision']) -join ' '
        $out['StartRequired'] = @(@('Running', 'Paused', 'PausePending', 'ContinuePending', 'Stopped', 'StopPending', 'StartPending', '') |
                ForEach-Object { '{0}={1}' -f $_, (Test-BRAVOServiceStartRequired -Status $_) }) -join ' '
        $out['ActiveStatus'] = @(@('Running', 'StartPending', 'StopPending', 'Paused', 'Stopped', '') |
                ForEach-Object { '{0}={1}' -f $_, (Test-BRAVOManagedServiceActiveStatus -Status $_) }) -join ' '
        # R379-4: Disabled від оператора vs тимчасове утримання BRAVO.
        $out['DisabledByOperator'] = @(
            @('BRAVO', 'Disabled', @()), @('BRAVO', 'disabled', @('Other')), @('BRAVO', 'Disabled', @('bravo')),
            @('BRAVO', 'Automatic', @()), @('BRAVO', 'Manual', @('BRAVO')), @('BRAVO', $null, @())
        ) | ForEach-Object { '{0}/{1}/{2}={3}' -f $_[0], $_[1], (@($_[2]) -join '+'), (Test-BRAVOServiceDisabledByOperator -Name $_[0] -StartMode $_[1] -HeldServiceNames $_[2]) }
        $out['DisabledByOperator'] = @($out['DisabledByOperator']) -join ' '
        $out
    }
    $lifecyclePlanExpected = [ordered]@{
        Order = 'Bravo,ExchangeApi,BravoWeb / BravoWeb,ExchangeApi,Bravo'
        AllRunning = 'stop: Apache2.4 exchangAPI BRAVO | start: BRAVO exchangAPI Apache2.4 | marker: BRAVO=True,exchangAPI=True,Apache2.4=True'
        OnlyBravoRunning = 'stop: BRAVO | start: BRAVO | marker: BRAVO=True'
        OnlyExchangeRunning = 'stop: exchangAPI | start: exchangAPI | marker: exchangAPI=True'
        OnlyWebRunning = 'stop: Apache2.4 | start: Apache2.4 | marker: Apache2.4=True'
        BravoAndExchangeRunning = 'stop: exchangAPI BRAVO | start: BRAVO exchangAPI | marker: BRAVO=True,exchangAPI=True'
        BravoFailedOthersRunning = 'stop: Apache2.4 exchangAPI | start: exchangAPI Apache2.4 | marker: exchangAPI=True,Apache2.4=True'
        AllStopped = 'stop:  | start:  | marker: '
        BravoStartPendingWebPaused = 'stop: exchangAPI BRAVO | start: BRAVO exchangAPI | marker: BRAVO=True,exchangAPI=True'
        ExchangeAndWebUnmanaged = 'stop: BRAVO | start: BRAVO | marker: BRAVO=True'
        BravoUnmanaged = 'stop: Apache2.4 exchangAPI | start: exchangAPI Apache2.4 | marker: exchangAPI=True,Apache2.4=True'
        BootHoldAllStopped = 'stop:  | start: BRAVO exchangAPI Apache2.4 | marker: BRAVO=True,exchangAPI=True,Apache2.4=True'
        RestoreHoldsAllManaged = 'stop: Apache2.4 BRAVO | start: BRAVO Apache2.4 | marker: BRAVO=True,exchangAPI=False,Apache2.4=True'
        InheritedExchangeIntent = 'stop: BRAVO | start: BRAVO exchangAPI | marker: BRAVO=True,exchangAPI=True'
        ModelIntegrityNotEstablished = 'stop: Apache2.4 exchangAPI BRAVO | start:  | marker: BRAVO=True,exchangAPI=True,Apache2.4=True'
        BravoStopPendingNoIntent = 'stop: exchangAPI | start: exchangAPI | marker: exchangAPI=True'
        SingleServiceList = 'stop: exchangAPI | start: exchangAPI | marker: exchangAPI=True'
        EmptyServiceList = 'stop:  | start:  | marker: '
        RestartIntent = 'Bravo=True,ExchangeApi=False,BravoWeb=False / hold: Bravo=True,ExchangeApi=True,BravoWeb=False'
        Inherited = 'ExchangeApi:exchangAPI'
        StopDecision = '/False/True=NotActive /True/True=NotActive Stopped/True/True=NotActive Paused/True/True=KeepState PausePending/False/True=KeepState ContinuePending/True/True=KeepState StopPending/False/True=KeepState StopPending/True/True=Stop Running/True/False=OutsideContract StartPending/False/True=PromoteIntent Running/False/True=PromoteIntent Running/True/True=Stop'
        StartRequired = 'Running=False Paused=False PausePending=False ContinuePending=False Stopped=True StopPending=True StartPending=True =True'
        ActiveStatus = 'Running=True StartPending=True StopPending=False Paused=False Stopped=False =False'
        DisabledByOperator = 'BRAVO/Disabled/=True BRAVO/disabled/Other=True BRAVO/Disabled/bravo=False BRAVO/Automatic/=False BRAVO/Manual/BRAVO=False BRAVO//=False'
    }
    $lifecyclePlanDiffs = @($lifecyclePlanExpected.Keys | Where-Object { [string]$lifecyclePlanProbe[$_] -cne [string]$lifecyclePlanExpected[$_] } |
        ForEach-Object { "$_ => '$($lifecyclePlanProbe[$_])' (очікувалось '$($lifecyclePlanExpected[$_])')" })
    Test-BRAVOCondition `
        -Condition ($lifecyclePlanDiffs.Count -eq 0) `
        -Name "ServiceRecovery/LifecyclePlanStopStartOrderMatrix" `
        -Failure "план циклу служб (BRAVO.System) має давати канонічний порядок зупинки Web -> exchangAPI -> BRAVO і запуску BRAVO -> exchangAPI -> Web для кожної комбінації станів, як нічний Maintenance: $($lifecyclePlanDiffs -join ' | ')"

    # Чистота: функції плану не звертаються до SCM/WMI/маркера/журналу —
    # лише одна до одної та до вбудованих cmdlet-ів обробки колекцій.
    $lifecyclePlanAst = [Management.Automation.Language.Parser]::ParseInput($systemModuleTextForQuiescence, [ref]$null, [ref]$null)
    $lifecyclePlanFunctionNames = @('Get-BRAVOManagedServiceOrder', 'Test-BRAVOManagedServiceActiveStatus', 'Test-BRAVOServiceStartRequired',
        'Get-BRAVOServiceStopDecision', 'Get-BRAVOManagedServiceRestartIntent', 'Get-BRAVOInheritedServiceRestartIntent',
        'Get-BRAVOServiceQuiescenceScope', 'Get-BRAVOManagedServiceLifecyclePlan', 'Test-BRAVOServiceDisabledByOperator')
    $lifecyclePlanAllowedCommands = @($lifecyclePlanFunctionNames) + @('Where-Object', 'ForEach-Object', 'Select-Object')
    $lifecyclePlanImpure = New-Object System.Collections.Generic.List[string]
    foreach ($lifecyclePlanFunctionName in $lifecyclePlanFunctionNames) {
        $lifecyclePlanFunctionAst = @($lifecyclePlanAst.FindAll({
                    param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $lifecyclePlanFunctionName
                }, $true)) | Select-Object -First 1
        if ($null -eq $lifecyclePlanFunctionAst) { [void]$lifecyclePlanImpure.Add("$lifecyclePlanFunctionName відсутня"); continue }
        foreach ($lifecyclePlanCommand in @($lifecyclePlanFunctionAst.Body.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))) {
            $lifecyclePlanCommandName = [string]$lifecyclePlanCommand.GetCommandName()
            if ($lifecyclePlanAllowedCommands -notcontains $lifecyclePlanCommandName) { [void]$lifecyclePlanImpure.Add("$lifecyclePlanFunctionName -> $lifecyclePlanCommandName") }
        }
    }
    Test-BRAVOCondition `
        -Condition ($lifecyclePlanImpure.Count -eq 0) `
        -Name "ServiceRecovery/LifecyclePlanFunctionsArePure" `
        -Failure "функції плану циклу служб у BRAVO.System мають бути чистими (без Get-Service/WMI/маркера/журналу): $($lifecyclePlanImpure -join ', ')"

    # Maintenance ухвалює рішення тими самими чистими функціями (без копій
    # логіки), а побічні дії живуть в окремих функціях runtime; #316 —
    # явна точка розширення перед зупинкою служби.
    $lifecycleRuntimeTextForPlan = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"), [Text.Encoding]::UTF8)
    $lifecycleRuntimeAstForPlan = [Management.Automation.Language.Parser]::ParseInput($lifecycleRuntimeTextForPlan, [ref]$null, [ref]$null)
    $getLifecycleRuntimeFunction = {
        param([string]$Name)
        @($lifecycleRuntimeAstForPlan.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)) |
            Select-Object -First 1
    }
    $getLifecycleCalls = {
        param($FunctionAst)
        if ($null -eq $FunctionAst) { return @() }
        @($FunctionAst.Body.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) |
                Sort-Object { $_.Extent.StartOffset } | ForEach-Object { [string]$_.GetCommandName() })
    }
    $stopServiceCalls = @(& $getLifecycleCalls (& $getLifecycleRuntimeFunction 'Stop-BRAVOMaintenanceManagedService'))
    $stopPhaseCalls = @(& $getLifecycleCalls (& $getLifecycleRuntimeFunction 'Stop-BRAVOMaintenanceManagedServices'))
    $startPhaseCalls = @(& $getLifecycleCalls (& $getLifecycleRuntimeFunction 'Start-BRAVOMaintenanceManagedServices'))
    $startServiceCalls = @(& $getLifecycleCalls (& $getLifecycleRuntimeFunction 'Start-BRAVOMaintenanceManagedService'))
    $hookCalls = @(& $getLifecycleCalls (& $getLifecycleRuntimeFunction 'Invoke-BRAVOMaintenanceBeforeServiceStopHook'))
    $contractCalls = @(& $getLifecycleCalls (& $getLifecycleRuntimeFunction 'Confirm-BRAVOMaintenanceServiceStopContract'))
    $hookIndex = [array]::IndexOf($stopServiceCalls, 'Invoke-BRAVOMaintenanceBeforeServiceStopHook')
    $stopInvokeIndex = [array]::IndexOf($stopServiceCalls, 'Invoke-ServiceStateChange')
    $confirmIndex = [array]::IndexOf($stopServiceCalls, 'Confirm-BRAVOMaintenanceServiceStopContract')
    Test-BRAVOCondition `
        -Condition (
            $confirmIndex -ge 0 -and $hookIndex -gt $confirmIndex -and $stopInvokeIndex -gt $hookIndex -and
            $hookCalls -contains 'Stop-BRAVOMaintenanceStrayProcess' -and
            $stopPhaseCalls -contains 'Get-BRAVOManagedServiceOrder' -and $stopPhaseCalls -contains 'Invoke-BRAVOMaintenanceBeforeServiceStopHook' -and
            $startPhaseCalls -contains 'Get-BRAVOManagedServiceOrder' -and $startServiceCalls -contains 'Test-BRAVOServiceStartRequired' -and
            $contractCalls -contains 'Get-BRAVOServiceStopDecision' -and
            $lifecycleRuntimeTextForPlan.Contains('$quiescenceServices = @(Get-BRAVOServiceQuiescenceScope') -and
            $lifecycleRuntimeTextForPlan.Contains('Get-BRAVOInheritedServiceRestartIntent') -and
            @([regex]::Matches($lifecycleRuntimeTextForPlan, 'Stop-BRAVOMaintenanceStrayProcess(?!\s*\{)')).Count -ge 1 -and
            @($lifecycleRuntimeAstForPlan.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Stop-BRAVOMaintenanceStrayProcess' }, $true)).Count -eq 1
        ) `
        -Name "ServiceRecovery/MaintenanceUsesLifecyclePlanAndBisHook" `
        -Failure "Maintenance має зупиняти/запускати служби через Stop-/Start-BRAVOMaintenanceManagedServices у порядку Get-BRAVOManagedServiceOrder, рішення — чистими функціями BRAVO.System, а Stop-BRAVOMaintenanceStrayProcess викликатися лише з точки розширення #316 Invoke-BRAVOMaintenanceBeforeServiceStopHook перед Invoke-ServiceStateChange (виклики Stop-BRAVOMaintenanceManagedService: $($stopServiceCalls -join ', '))"

    # R379-3/R379-4: один пошук Win32_Service за іменем у BRAVO.System; спільний
    # контракт тимчасового Disabled для класифікації й DataRestore.
    $lifecycleDataRestoreText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.DataRestore\BRAVO.DataRestore.Runtime.ps1"), [Text.Encoding]::UTF8)
    $win32FilterQueries = @([regex]::Matches($systemModuleTextForQuiescence, "-ClassName Win32_Service -Filter")).Count
    $conditionFunctionForR379 = @($lifecyclePlanAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-BRAVOManagedServiceCondition' }, $true)) | Select-Object -First 1
    $startModeFunctionForR379 = @($lifecyclePlanAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-BRAVOServiceStartMode' }, $true)) | Select-Object -First 1
    Test-BRAVOCondition `
        -Condition (
            $win32FilterQueries -eq 1 -and
            $null -ne $conditionFunctionForR379 -and $conditionFunctionForR379.Extent.Text.Contains('Get-BRAVOWin32ServiceInfo -Name') -and
            $conditionFunctionForR379.Extent.Text.Contains('Test-BRAVOServiceDisabledByOperator') -and
            $null -ne $startModeFunctionForR379 -and $startModeFunctionForR379.Extent.Text.Contains('Get-BRAVOWin32ServiceInfo -Name') -and
            $lifecycleDataRestoreText.Contains('Disabled = (Test-BRAVOServiceDisabledByOperator -Name $ServiceName -StartMode $startMode -HeldServiceNames $TemporarilyDisabledServiceNames)') -and
            $lifecycleDataRestoreText -notmatch '-ClassName\s+Win32_Service\s+`?\s*-Filter'
        ) `
        -Name "ServiceRecovery/SingleWin32ServiceLookupAndSharedHeldDisabledContract" `
        -Failure "R379-3/R379-4: пошук Win32_Service за іменем має бути один (Get-BRAVOWin32ServiceInfo, знайдено -Filter-запитів: $win32FilterQueries), а Get-BRAVOManagedServiceCondition і знімок служб DataRestore — спиратися на спільний Test-BRAVOServiceDisabledByOperator"
    }
    #endregion #314-wave2-lifecycle-plan
