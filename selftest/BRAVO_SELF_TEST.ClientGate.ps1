# ============================================================
# #316: закриття клієнтів BIS перед реставрацією.
#
# modules\BRAVO.Maintenance\BRAVO.Maintenance.ClientGate.ps1 НЕ є модулем
# (dot-source-иться в scope Invoke-BRAVOMaintenance, той самий патерн, що
# BRAVO.Maintenance.ServiceCycle.ps1), але сама логіка воріт
# (Invoke-BRAVOMaintenanceClientCloseGate/Get-BRAVOClientGateInventory/
# Get-BRAVOWTSSessionInfo/Send-BRAVOWTSTextMessage/Add-BRAVOWTSApiType) НЕ
# залежить від жодної динамічної Maintenance-змінної (Write-Log, $script:*)
# — лише від injected-параметрів. Тому тут файл дот-сорситься НАПРЯМУ, у
# scope self-test, і тестується без жодного реального wtsapi32.dll/
# Get-Process/Start-Sleep — WTS-виклики за тестовим швом (акцептанс #316).
#
# Invoke-BRAVOMaintenanceClientCloseStep (глей: читання конфігурації,
# Write-Log, Write-BRAVOMaintenanceOperation, $script:criticalErrorOccurred)
# — єдина функція файлу, що читає Maintenance-стан; тестується окремо,
# нижче, з локальними заглушками Write-Log/Write-BRAVOMaintenanceOperation
# у власному child scope (& { ... }), і з -GateInvoker — тим самим
# dependency-injection принципом, що решта файлу.
# ============================================================

. (Join-Path $root 'modules\BRAVO.Maintenance\BRAVO.Maintenance.ClientGate.ps1')

# ------------------------------------------------------------
# 1. Active-сесія отримує попередження з часом автозакриття.
# ------------------------------------------------------------
& {
    $nowBox = @((Get-Date '2026-01-01 10:00:00'))
    $worldProcesses = @([pscustomobject]@{ Id = 101; SessionId = 5 })
    $worldSessions = @([pscustomobject]@{ SessionId = 5; State = 0; UserName = 'USER-01' })
    $stopperCalls = New-Object System.Collections.Generic.List[int]

    $result = Invoke-BRAVOMaintenanceClientCloseGate `
        -ProcessNames @('Bis') -WaitMinutes 5 -ReminderMinutes 1 -PollSeconds 60 `
        -ProcessProvider { param($Name) return $worldProcesses } `
        -SessionProvider { return $worldSessions } `
        -MessageSender { param($SessionId, $Title, $Message) return $true } `
        -ProcessStopper { param($ProcessId) [void]$stopperCalls.Add($ProcessId) } `
        -ClockNow { return $nowBox[0] } `
        -Waiter { param($Seconds) $nowBox[0] = $nowBox[0].AddSeconds($Seconds) }

    Test-BRAVOCondition -Condition (
        $result.Messages.Count -ge 1 -and
        $result.Messages[0].SessionId -eq 5 -and
        $result.Messages[0].Message -match '10:05' -and
        $result.Messages[0].Message -match 'закрито автоматично'
    ) -Name 'ClientGate/ActiveSessionReceivesWarningWithDeadline' `
        -Failure "Active-сесія мусить отримати повідомлення з часом автозакриття (10:05, старт 10:00 + WaitMinutes=5); факт: $($result.Messages | ConvertTo-Json -Compress -Depth 3)"
}

# ------------------------------------------------------------
# 2. Нагадування щохвилини; останнє — "залишилась 1 хвилина".
# ------------------------------------------------------------
& {
    $nowBox = @((Get-Date '2026-01-01 10:00:00'))
    $worldProcesses = @([pscustomobject]@{ Id = 201; SessionId = 7 })
    $worldSessions = @([pscustomobject]@{ SessionId = 7; State = 0; UserName = 'USER-02' })

    $result = Invoke-BRAVOMaintenanceClientCloseGate `
        -ProcessNames @('Bis') -WaitMinutes 3 -ReminderMinutes 1 -PollSeconds 60 `
        -ProcessProvider { param($Name) return $worldProcesses } `
        -SessionProvider { return $worldSessions } `
        -MessageSender { param($SessionId, $Title, $Message) return $true } `
        -ProcessStopper { param($ProcessId) } `
        -ClockNow { return $nowBox[0] } `
        -Waiter { param($Seconds) $nowBox[0] = $nowBox[0].AddSeconds($Seconds) }

    Test-BRAVOCondition -Condition (
        $result.Messages.Count -eq 3 -and
        $result.Messages[2].Message -match 'залишилась 1 хвилина' -and
        $result.ForcedClosures.Count -eq 1
    ) -Name 'ClientGate/ReminderRepeatsEveryMinuteLastSaysOneMinuteLeft' `
        -Failure "очікувано 3 повідомлення (початкове + 2 нагадування), останнє -- 'залишилась 1 хвилина', і примусове закриття після дедлайну; факт: $($result.Messages.Count) повідомлень, останнє='$($result.Messages[-1].Message)', ForcedClosures=$($result.ForcedClosures.Count)"
}

# ------------------------------------------------------------
# 3. Нова Active-сесія під час очікування отримує повідомлення одразу,
#    з ТИМ САМИМ дедлайном.
# ------------------------------------------------------------
& {
    $nowBox = @((Get-Date '2026-01-01 10:00:00'))
    $worldProcesses = New-Object System.Collections.Generic.List[object]
    $worldProcesses.Add([pscustomobject]@{ Id = 301; SessionId = 11 })
    $worldSessions = New-Object System.Collections.Generic.List[object]
    $worldSessions.Add([pscustomobject]@{ SessionId = 11; State = 0; UserName = 'USER-A' })
    $newSessionAdded = @($false)

    $result = Invoke-BRAVOMaintenanceClientCloseGate `
        -ProcessNames @('Bis') -WaitMinutes 3 -ReminderMinutes 5 -PollSeconds 60 `
        -ProcessProvider { param($Name) return $worldProcesses } `
        -SessionProvider { return $worldSessions } `
        -MessageSender { param($SessionId, $Title, $Message) return $true } `
        -ProcessStopper { param($ProcessId) } `
        -ClockNow { return $nowBox[0] } `
        -Waiter {
            param($Seconds)
            $nowBox[0] = $nowBox[0].AddSeconds($Seconds)
            if (-not $newSessionAdded[0]) {
                # Переприсвоєння $worldProcesses тут було б НЕВИДИМЕ для
                # інших scriptblock-параметрів (кожен closure лексично
                # зв'язаний зі своєю власною локальною копією імені змінної
                # при записі) -- тому мутуємо той самий List[object] методом,
                # а не створюємо новий масив.
                $worldProcesses.Add([pscustomobject]@{ Id = 302; SessionId = 12 })
                $worldSessions.Add([pscustomobject]@{ SessionId = 12; State = 0; UserName = 'USER-B' })
                $newSessionAdded[0] = $true
            }
        }

    $messageForA = @($result.Messages | Where-Object { $_.SessionId -eq 11 })[0]
    $messageForB = @($result.Messages | Where-Object { $_.SessionId -eq 12 })[0]

    Test-BRAVOCondition -Condition (
        $null -ne $messageForA -and $null -ne $messageForB -and
        $messageForA.Message -match '10:03' -and $messageForB.Message -match '10:03'
    ) -Name 'ClientGate/NewActiveSessionDuringWaitGetsSameDeadline' `
        -Failure "нова Active-сесія (12), виявлена під час очікування, мусить отримати повідомлення з ТИМ САМИМ дедлайном (10:03, старт 10:00 + WaitMinutes=3), що й перша (11); факт A='$($messageForA.Message)' B='$($messageForB.Message)'"
}

# ------------------------------------------------------------
# 4. Користувач закриває BIS сам -- журнал з часом очікування, без
#    примусового закриття.
# ------------------------------------------------------------
& {
    $nowBox = @((Get-Date '2026-01-01 10:00:00'))
    $worldProcesses = New-Object System.Collections.Generic.List[object]
    $worldProcesses.Add([pscustomobject]@{ Id = 401; SessionId = 21 })
    $worldSessions = @([pscustomobject]@{ SessionId = 21; State = 0; UserName = 'USER-03' })
    $closedByUser = @($false)
    $stopperCalls = New-Object System.Collections.Generic.List[int]

    $result = Invoke-BRAVOMaintenanceClientCloseGate `
        -ProcessNames @('Bis') -WaitMinutes 2 -ReminderMinutes 1 -PollSeconds 60 `
        -ProcessProvider { param($Name) return $worldProcesses } `
        -SessionProvider { return $worldSessions } `
        -MessageSender { param($SessionId, $Title, $Message) return $true } `
        -ProcessStopper { param($ProcessId) [void]$stopperCalls.Add($ProcessId) } `
        -ClockNow { return $nowBox[0] } `
        -Waiter {
            param($Seconds)
            $nowBox[0] = $nowBox[0].AddSeconds($Seconds)
            if (-not $closedByUser[0]) { $worldProcesses.Clear(); $closedByUser[0] = $true }
        }

    Test-BRAVOCondition -Condition (
        $result.UserClosures.Count -eq 1 -and
        $result.UserClosures[0].SessionId -eq 21 -and
        $result.UserClosures[0].WaitedSeconds -eq 60 -and
        $result.ForcedClosures.Count -eq 0 -and
        $stopperCalls.Count -eq 0
    ) -Name 'ClientGate/UserClosedBisLoggedWithWaitTimeNoForceClose' `
        -Failure "BIS, закрита користувачем до дедлайну, мусить фіксуватись у UserClosures з часом очікування (60с) і НЕ викликати ProcessStopper; факт UserClosures=$($result.UserClosures.Count), ForcedClosures=$($result.ForcedClosures.Count), stopperCalls=$($stopperCalls.Count)"
}

# ------------------------------------------------------------
# 5. BIS, що лишилась після дедлайну, закривається примусово із записом
#    сесії/користувача/PID/часу.
# ------------------------------------------------------------
& {
    $nowBox = @((Get-Date '2026-01-01 10:00:00'))
    $worldProcesses = @([pscustomobject]@{ Id = 501; SessionId = 31 })
    $worldSessions = @([pscustomobject]@{ SessionId = 31; State = 0; UserName = 'USER-04' })

    $result = Invoke-BRAVOMaintenanceClientCloseGate `
        -ProcessNames @('Bis') -WaitMinutes 1 -ReminderMinutes 1 -PollSeconds 60 `
        -ProcessProvider { param($Name) return $worldProcesses } `
        -SessionProvider { return $worldSessions } `
        -MessageSender { param($SessionId, $Title, $Message) return $true } `
        -ProcessStopper { param($ProcessId) } `
        -ClockNow { return $nowBox[0] } `
        -Waiter { param($Seconds) $nowBox[0] = $nowBox[0].AddSeconds($Seconds) }

    Test-BRAVOCondition -Condition (
        $result.ForcedClosures.Count -eq 1 -and
        $result.ForcedClosures[0].SessionId -eq 31 -and
        $result.ForcedClosures[0].UserName -eq 'USER-04' -and
        $result.ForcedClosures[0].ProcessId -eq 501 -and
        $null -ne $result.ForcedClosures[0].At
    ) -Name 'ClientGate/StillOpenAfterDeadlineForcedWithSessionUserPid' `
        -Failure "BIS, що лишилась після дедлайну, мусить потрапити у ForcedClosures із сесією/користувачем/PID/часом; факт: $($result.ForcedClosures | ConvertTo-Json -Compress -Depth 3)"
}

# ------------------------------------------------------------
# 6/7/8. Disconnected / сесія без користувача (0) / невідомий стан --
#    закриваються негайно, без очікування і повідомлень.
# ------------------------------------------------------------
& {
    $worldProcesses = @(
        [pscustomobject]@{ Id = 601; SessionId = 41 },  # Disconnected
        [pscustomobject]@{ Id = 602; SessionId = 0 },   # NoUser (сесія 0)
        [pscustomobject]@{ Id = 603; SessionId = 42 }   # Unknown (нема в переліку сесій)
    )
    $worldSessions = @([pscustomobject]@{ SessionId = 41; State = 4; UserName = 'USER-05' })
    $waiterCalls = @(0)

    $result = Invoke-BRAVOMaintenanceClientCloseGate `
        -ProcessNames @('Bis') -WaitMinutes 5 -ReminderMinutes 1 -PollSeconds 10 `
        -ProcessProvider { param($Name) return $worldProcesses } `
        -SessionProvider { return $worldSessions } `
        -MessageSender { param($SessionId, $Title, $Message) return $true } `
        -ProcessStopper { param($ProcessId) } `
        -ClockNow { return (Get-Date '2026-01-01 10:00:00') } `
        -Waiter { param($Seconds) $waiterCalls[0]++ }

    $classifications = @($result.ImmediateClosures | ForEach-Object { $_.Classification } | Sort-Object)
    Test-BRAVOCondition -Condition (
        $result.ImmediateClosures.Count -eq 3 -and
        ($classifications -join ',') -ceq 'Disconnected,NoUser,Unknown' -and
        $result.Messages.Count -eq 0 -and
        $waiterCalls[0] -eq 0
    ) -Name 'ClientGate/DisconnectedNoUserUnknownClosedImmediatelyNoWaitNoMessage' `
        -Failure "Disconnected/сесія 0/невідомий стан мусять закриватись негайно, без очікування (Waiter не викликається) і без повідомлень; факт ImmediateClosures=$($result.ImmediateClosures.Count) ($($classifications -join ',')), Messages=$($result.Messages.Count), waiterCalls=$($waiterCalls[0])"
}

# ------------------------------------------------------------
# 6a. Review (P0, fail-safe): WTSEnumerateSessionsW провалився повністю
#     (-SessionProvider повертає $null) -- BIS МАЄ попереджатись (Active),
#     а не закриватись мовчки. Збій WTS API не повинен мати той самий
#     ефект, що справді відключена/невідома сесія.
# ------------------------------------------------------------
& {
    $worldProcesses = @([pscustomobject]@{ Id = 611; SessionId = 81 })

    $result = Invoke-BRAVOMaintenanceClientCloseGate `
        -ProcessNames @('Bis') -WaitMinutes 0 -ReminderMinutes 1 -PollSeconds 10 `
        -ProcessProvider { param($Name) return $worldProcesses } `
        -SessionProvider { return $null } `
        -MessageSender { param($SessionId, $Title, $Message) return $true } `
        -ProcessStopper { param($ProcessId) } `
        -ClockNow { return (Get-Date '2026-01-01 10:00:00') } `
        -Waiter { param($Seconds) }

    Test-BRAVOCondition -Condition (
        $result.ImmediateClosures.Count -eq 1 -and $result.ImmediateClosures[0].Classification -eq 'Active'
    ) -Name 'ClientGate/WtsEnumerationFailureDefaultsToActiveNotSilentClose' `
        -Failure "повний провал WTSEnumerateSessionsW (SessionProvider=`$null) мусить класифікувати BIS як Active (попередити), а не Unknown/NoUser (закрити мовчки); факт: $($result.ImmediateClosures | ConvertTo-Json -Compress -Depth 3)"
}

# ------------------------------------------------------------
# 6b. Review (P0, fail-safe): WTSQuerySessionInformationW не дав ім'я
#     користувача для ОДНІЄЇ сесії (UserName=$null, провал запиту, а не
#     справді порожнє ім'я) -- та сама сесія МАЄ попереджатись (Active).
# ------------------------------------------------------------
& {
    $worldProcesses = @([pscustomobject]@{ Id = 621; SessionId = 82 })
    $worldSessions = @([pscustomobject]@{ SessionId = 82; State = 0; UserName = $null })

    $result = Invoke-BRAVOMaintenanceClientCloseGate `
        -ProcessNames @('Bis') -WaitMinutes 0 -ReminderMinutes 1 -PollSeconds 10 `
        -ProcessProvider { param($Name) return $worldProcesses } `
        -SessionProvider { return $worldSessions } `
        -MessageSender { param($SessionId, $Title, $Message) return $true } `
        -ProcessStopper { param($ProcessId) } `
        -ClockNow { return (Get-Date '2026-01-01 10:00:00') } `
        -Waiter { param($Seconds) }

    Test-BRAVOCondition -Condition (
        $result.ImmediateClosures.Count -eq 1 -and $result.ImmediateClosures[0].Classification -eq 'Active'
    ) -Name 'ClientGate/WtsUserNameQueryFailureDefaultsToActiveNotNoUser' `
        -Failure "провал WTSQuerySessionInformationW для ОДНІЄЇ сесії (UserName=`$null) мусить класифікувати її як Active (попередити), а не NoUser (закрити мовчки навіть якщо сесія справді активна); факт: $($result.ImmediateClosures | ConvertTo-Json -Compress -Depth 3)"
}

# ------------------------------------------------------------
# 9. Процес не завершився навіть після примусового закриття -- фінальна
#    перевірка повертає його у StillRunning (=> CRITICAL на рівні кроку).
# ------------------------------------------------------------
& {
    $nowBox = @((Get-Date '2026-01-01 10:00:00'))
    $worldProcesses = @([pscustomobject]@{ Id = 701; SessionId = 51 })
    $worldSessions = @([pscustomobject]@{ SessionId = 51; State = 0; UserName = 'USER-06' })

    $result = Invoke-BRAVOMaintenanceClientCloseGate `
        -ProcessNames @('Bis') -WaitMinutes 1 -ReminderMinutes 1 -PollSeconds 60 `
        -ProcessProvider { param($Name) return $worldProcesses } `
        -SessionProvider { return $worldSessions } `
        -MessageSender { param($SessionId, $Title, $Message) return $true } `
        -ProcessStopper { param($ProcessId) <# імітація: Stop-Process не спрацював -- процес лишається у $worldProcesses #> } `
        -ClockNow { return $nowBox[0] } `
        -Waiter { param($Seconds) $nowBox[0] = $nowBox[0].AddSeconds($Seconds) }

    Test-BRAVOCondition -Condition (
        $result.StillRunning.Count -eq 1 -and $result.StillRunning[0].ProcessId -eq 701
    ) -Name 'ClientGate/StillRunningAfterForceFailsVerification' `
        -Failure "якщо примусове закриття не спрацювало, фінальна перевірка мусить повернути процес у StillRunning; факт: $($result.StillRunning.Count)"
}

# ------------------------------------------------------------
# 10. WaitMinutes=0 -- закривати все негайно, без очікування і повідомлень,
#     навіть Active-сесії.
# ------------------------------------------------------------
& {
    $worldProcesses = @(
        [pscustomobject]@{ Id = 801; SessionId = 61 },  # Active
        [pscustomobject]@{ Id = 802; SessionId = 62 }   # Disconnected
    )
    $worldSessions = @(
        [pscustomobject]@{ SessionId = 61; State = 0; UserName = 'USER-07' },
        [pscustomobject]@{ SessionId = 62; State = 4; UserName = 'USER-08' }
    )
    $waiterCalls = @(0)
    $messageCalls = @(0)

    $result = Invoke-BRAVOMaintenanceClientCloseGate `
        -ProcessNames @('Bis') -WaitMinutes 0 -ReminderMinutes 1 -PollSeconds 10 `
        -ProcessProvider { param($Name) return $worldProcesses } `
        -SessionProvider { return $worldSessions } `
        -MessageSender { param($SessionId, $Title, $Message) $messageCalls[0]++; return $true } `
        -ProcessStopper { param($ProcessId) } `
        -ClockNow { return (Get-Date '2026-01-01 10:00:00') } `
        -Waiter { param($Seconds) $waiterCalls[0]++ }

    Test-BRAVOCondition -Condition (
        $result.ImmediateClosures.Count -eq 2 -and
        $waiterCalls[0] -eq 0 -and $messageCalls[0] -eq 0
    ) -Name 'ClientGate/WaitMinutesZeroClosesEverythingImmediatelyNoMessages' `
        -Failure "WaitMinutes=0 мусить закрити УСІ знайдені процеси (включно з Active) негайно, без очікування і без повідомлень; факт ImmediateClosures=$($result.ImmediateClosures.Count), waiterCalls=$($waiterCalls[0]), messageCalls=$($messageCalls[0])"
}

# ------------------------------------------------------------
# 11. Немає жодного процесу з переліку ProcessNames -- порожній результат
#     (нічний прогін без реставрації / профіль -RecoverServices не зачіпає
#     цю логіку взагалі -- ворота не викликаються, коли $shouldRestore=$false,
#     але навіть якщо викликані напряму, порожній список -- без побічних дій).
# ------------------------------------------------------------
& {
    $result = Invoke-BRAVOMaintenanceClientCloseGate `
        -ProcessNames @('Bis') -WaitMinutes 5 -ReminderMinutes 1 -PollSeconds 10 `
        -ProcessProvider { param($Name) return @() } `
        -SessionProvider { return @() } `
        -MessageSender { param($SessionId, $Title, $Message) return $true } `
        -ProcessStopper { param($ProcessId) } `
        -ClockNow { return (Get-Date '2026-01-01 10:00:00') } `
        -Waiter { param($Seconds) throw 'self-test: Waiter не повинен викликатись без жодного BIS-процесу' }

    Test-BRAVOCondition -Condition (
        $result.ImmediateClosures.Count -eq 0 -and $result.UserClosures.Count -eq 0 -and
        $result.ForcedClosures.Count -eq 0 -and $result.StillRunning.Count -eq 0 -and
        $result.Messages.Count -eq 0
    ) -Name 'ClientGate/NoBisProcessesReturnsEmptyResultWithoutSideEffects' `
        -Failure "за відсутності будь-якого BIS-процесу ворота мусять повернути геть порожній результат без побічних дій (Waiter не викликається)"
}

# ------------------------------------------------------------
# 12. Кілька Active-сесій одночасно -- незалежне відстеження: одна
#     закривається користувачем, інша лишається до примусового закриття.
# ------------------------------------------------------------
& {
    $nowBox = @((Get-Date '2026-01-01 10:00:00'))
    $worldProcesses = New-Object System.Collections.Generic.List[object]
    $worldProcesses.Add([pscustomobject]@{ Id = 901; SessionId = 71 })
    $worldProcesses.Add([pscustomobject]@{ Id = 902; SessionId = 72 })
    $worldSessions = @(
        [pscustomobject]@{ SessionId = 71; State = 0; UserName = 'USER-09' },
        [pscustomobject]@{ SessionId = 72; State = 0; UserName = 'USER-10' }
    )
    $closedByUser = @($false)

    $result = Invoke-BRAVOMaintenanceClientCloseGate `
        -ProcessNames @('Bis') -WaitMinutes 2 -ReminderMinutes 1 -PollSeconds 60 `
        -ProcessProvider { param($Name) return $worldProcesses } `
        -SessionProvider { return $worldSessions } `
        -MessageSender { param($SessionId, $Title, $Message) return $true } `
        -ProcessStopper { param($ProcessId) } `
        -ClockNow { return $nowBox[0] } `
        -Waiter {
            param($Seconds)
            $nowBox[0] = $nowBox[0].AddSeconds($Seconds)
            if (-not $closedByUser[0]) {
                $survivors = @($worldProcesses | Where-Object { $_.SessionId -ne 71 })
                $worldProcesses.Clear()
                foreach ($survivor in $survivors) { $worldProcesses.Add($survivor) }
                $closedByUser[0] = $true
            }
        }

    Test-BRAVOCondition -Condition (
        $result.UserClosures.Count -eq 1 -and $result.UserClosures[0].SessionId -eq 71 -and
        $result.ForcedClosures.Count -eq 1 -and $result.ForcedClosures[0].SessionId -eq 72
    ) -Name 'ClientGate/MultipleActiveSessionsTrackedIndependently' `
        -Failure "дві одночасні Active-сесії мусять відстежуватись незалежно: 71 закрита користувачем, 72 лишається до примусового закриття; факт UserClosures=$($result.UserClosures.Count), ForcedClosures=$($result.ForcedClosures.Count)"
}

# ------------------------------------------------------------
# 13-16. Invoke-BRAVOMaintenanceClientCloseStep (глей): мапування
# результату воріт на Write-BRAVOMaintenanceOperation і критичну відмову.
# Локальні заглушки Write-Log/Write-BRAVOMaintenanceOperation у власному
# child scope -- та сама причина, що решта self-test (фрагменти дот-
# сорсяться в ОДИН scope, заглушки не повинні просочитись далі).
# ------------------------------------------------------------
& {
    function Write-Log { param([string]$Message, [string]$Level = "INFO") }
    $script:clientGateStepOperations = New-Object System.Collections.Generic.List[object]
    function Write-BRAVOMaintenanceOperation {
        param([string]$Name, [string]$Status = 'OK', [Nullable[timespan]]$Duration, [string]$Details)
        [void]$script:clientGateStepOperations.Add([pscustomobject]@{ Name = $Name; Status = $Status; Details = $Details })
    }

    $script:criticalErrorOccurred = $false
    $stillRunningResult = [pscustomobject]@{
        ImmediateClosures = @(); UserClosures = @(); ForcedClosures = @()
        StillRunning      = @([pscustomobject]@{ SessionId = 1; ProcessId = 1 })
        Messages          = @()
    }
    $stepReturn = Invoke-BRAVOMaintenanceClientCloseStep -GateInvoker { return $stillRunningResult }
    Test-BRAVOCondition -Condition (
        $stepReturn -eq $false -and $script:criticalErrorOccurred -eq $true -and
        $script:clientGateStepOperations.Count -eq 1 -and $script:clientGateStepOperations[0].Status -eq 'FAIL'
    ) -Name 'ClientGate/StepReturnsFalseAndSetsCriticalOnStillRunning' `
        -Failure "StillRunning -> крок мусить повернути `$false, встановити `$script:criticalErrorOccurred=`$true і Write-BRAVOMaintenanceOperation Status='FAIL'; факт return=$stepReturn critical=$script:criticalErrorOccurred ops=$($script:clientGateStepOperations.Count)"

    $script:criticalErrorOccurred = $false
    $script:clientGateStepOperations.Clear()
    $forcedResult = [pscustomobject]@{
        ImmediateClosures = @(); UserClosures = @()
        ForcedClosures    = @([pscustomobject]@{ SessionId = 1; UserName = 'USER-11'; ProcessId = 1; At = (Get-Date) })
        StillRunning      = @(); Messages = @()
    }
    $stepReturn = Invoke-BRAVOMaintenanceClientCloseStep -GateInvoker { return $forcedResult }
    Test-BRAVOCondition -Condition (
        $stepReturn -eq $true -and $script:criticalErrorOccurred -eq $false -and
        $script:clientGateStepOperations.Count -eq 1 -and $script:clientGateStepOperations[0].Status -eq 'WARN'
    ) -Name 'ClientGate/StepWarnStatusOnForcedClosuresWithoutCritical' `
        -Failure "ForcedClosures без StillRunning -> крок мусить повернути `$true і Write-BRAVOMaintenanceOperation Status='WARN', без критичної відмови; факт return=$stepReturn critical=$script:criticalErrorOccurred status=$($script:clientGateStepOperations[0].Status)"

    $script:clientGateStepOperations.Clear()
    $okResult = [pscustomobject]@{
        ImmediateClosures = @([pscustomobject]@{ SessionId = 0; ProcessId = 1; ProcessName = 'Bis'; Classification = 'NoUser' })
        UserClosures      = @(); ForcedClosures = @(); StillRunning = @(); Messages = @()
    }
    [void](Invoke-BRAVOMaintenanceClientCloseStep -GateInvoker { return $okResult })
    Test-BRAVOCondition -Condition (
        $script:clientGateStepOperations.Count -eq 1 -and $script:clientGateStepOperations[0].Status -eq 'OK'
    ) -Name 'ClientGate/StepOkStatusWhenClosedWithoutForcing' `
        -Failure "закриття без примусу й без StillRunning -> Write-BRAVOMaintenanceOperation Status='OK'; факт: $($script:clientGateStepOperations[0].Status)"

    $script:clientGateStepOperations.Clear()
    $emptyResult = [pscustomobject]@{ ImmediateClosures = @(); UserClosures = @(); ForcedClosures = @(); StillRunning = @(); Messages = @() }
    [void](Invoke-BRAVOMaintenanceClientCloseStep -GateInvoker { return $emptyResult })
    Test-BRAVOCondition -Condition (
        $script:clientGateStepOperations.Count -eq 1 -and $script:clientGateStepOperations[0].Status -eq 'SKIPPED'
    ) -Name 'ClientGate/StepSkippedStatusWhenNothingFound' `
        -Failure "жодного BIS-процесу -> Write-BRAVOMaintenanceOperation Status='SKIPPED'; факт: $($script:clientGateStepOperations[0].Status)"

    Remove-Variable -Name clientGateStepOperations, criticalErrorOccurred -Scope Script -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
# 17. Windows CI (PS 5.1): Add-BRAVOWTSApiType реально компілюється
#     (акцептанс #316 -- не лише текстовий seam, реальний P/Invoke-тип
#     мусить бути придатний до компіляції на підтримуваній платформі).
# ------------------------------------------------------------
Test-BRAVOCondition -Condition (
    $(try { Add-BRAVOWTSApiType; $null -ne ('BRAVO.Interop.WTSApi' -as [type]) } catch { $false })
) -Name 'ClientGate/WTSApiTypeCompiles' `
    -Failure 'Add-BRAVOWTSApiType мусить успішно скомпілювати P/Invoke-тип BRAVO.Interop.WTSApi (wtsapi32.dll WTSEnumerateSessionsW/WTSQuerySessionInformationW/WTSSendMessageW/WTSFreeMemory)'
