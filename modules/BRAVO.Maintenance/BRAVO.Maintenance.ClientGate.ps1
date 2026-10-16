# ============================================================
# Закриття клієнтів BIS перед реставрацією (#316).
#
# Файл НЕ є самостійним скриптом і не імпортується як модуль: його
# dot-source-ить Invoke-BRAVOMaintenance (BRAVO.Maintenance.Runtime.ps1) у
# власний scope, тим самим патерном, що BRAVO.Maintenance.ServiceCycle.ps1
# (#314) — функції нижче бачать змінні тіла через динамічний scope
# (Write-Log, $script:criticalErrorOccurred, $script:BRAVOWarningCount) і
# пишуть стан прогону через $script:.
#
# WTS-виклики (перелік сесій, повідомлення у сесію) живуть за тестовим швом:
# Invoke-BRAVOMaintenanceClientCloseGate приймає -SessionProvider/
# -MessageSender/-ProcessProvider/-ProcessStopper/-ClockNow/-Waiter як
# scriptblock-и з production-дефолтами, що реально викликають wtsapi32.dll.
# Self-test підміняє їх цілком (той самий dependency-injection принцип, що
# вже використаний для SFTP-примітивів у BRAVO.LogSync, #364) — тому логіка
# ворот (класифікація сесій, очікування, нагадування, примусове закриття)
# перевіряється детерміновано на БУДЬ-ЯКІЙ платформі (Linux/pwsh7 теж),
# без залежності від реального wtsapi32.dll чи реальних RDP-сесій.
#
# PS 3.0-сумісний код (мінімальна підтримувана версія цього проєкту):
# без ::new(), без класів, без ternary/null-coalescing.
# ============================================================

function Add-BRAVOWTSApiType {
    # Ідемпотентна компіляція P/Invoke-типу. На Windows реально резолвить
    # wtsapi32.dll лише в МОМЕНТ ВИКЛИКУ P/Invoke-методу (DllImport), тож сам
    # Add-Type компілюється і на Linux/pwsh7 (Roslyn не потребує наявності
    # самої DLL для компіляції сигнатур) — Windows CI (PS 5.1) перевіряє, що
    # ця компіляція проходить; реальний викоп методів відбувається лише
    # всередині Get-BRAVOWTSSessionInfo/Send-BRAVOWTSTextMessage, які
    # self-test підміняє цілком і ніколи не викликає на Linux.
    if (-not ('BRAVO.Interop.WTSApi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace BRAVO.Interop {
    [StructLayout(LayoutKind.Sequential)]
    public struct WTS_SESSION_INFO {
        public int SessionId;
        public IntPtr pWinStationName;
        public int State;
    }

    public static class WTSApi {
        [DllImport("wtsapi32.dll", SetLastError = true)]
        public static extern bool WTSEnumerateSessionsW(IntPtr hServer, int Reserved, int Version, out IntPtr ppSessionInfo, out int pCount);

        [DllImport("wtsapi32.dll")]
        public static extern void WTSFreeMemory(IntPtr pMemory);

        [DllImport("wtsapi32.dll", SetLastError = true)]
        public static extern bool WTSQuerySessionInformationW(IntPtr hServer, int sessionId, int wtsInfoClass, out IntPtr ppBuffer, out int pBytesReturned);

        [DllImport("wtsapi32.dll", SetLastError = true)]
        public static extern bool WTSSendMessageW(IntPtr hServer, int sessionId, string pTitle, int titleLength, string pMessage, int messageLength, int style, int timeoutSeconds, out int pResponse, bool bWait);
    }
}
'@
    }
}

function Get-BRAVOWTSSessionInfo {
    # Реальний перелік RDP/консольних сесій цього хоста: SessionId, стан
    # з'єднання (WTS_CONNECTSTATE_CLASS; 0=Active, 4=Disconnected, решта —
    # для цілей #316 трактується як "невідомий"), ім'я користувача
    # (WTSQuerySessionInformationW, WTSUserName=5; порожнє — сесія без
    # користувача, зокрема сесія 0 служб).
    Add-BRAVOWTSApiType
    $sessions = New-Object System.Collections.Generic.List[object]
    $pSessionInfo = New-Object IntPtr 0
    $count = 0
    $ok = [BRAVO.Interop.WTSApi]::WTSEnumerateSessionsW((New-Object IntPtr 0), 0, 1, [ref]$pSessionInfo, [ref]$count)
    if (-not $ok) { return $sessions.ToArray() }
    try {
        $structSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'BRAVO.Interop.WTS_SESSION_INFO')
        for ($sessionIndex = 0; $sessionIndex -lt $count; $sessionIndex++) {
            $currentPtr = New-Object IntPtr ($pSessionInfo.ToInt64() + ($sessionIndex * $structSize))
            $info = [Runtime.InteropServices.Marshal]::PtrToStructure($currentPtr, [type]'BRAVO.Interop.WTS_SESSION_INFO')
            $userName = ''
            $pBuffer = New-Object IntPtr 0
            $bytesReturned = 0
            $gotUser = [BRAVO.Interop.WTSApi]::WTSQuerySessionInformationW((New-Object IntPtr 0), $info.SessionId, 5, [ref]$pBuffer, [ref]$bytesReturned)
            if ($gotUser -and $pBuffer -ne [IntPtr]::Zero) {
                try { $userName = [Runtime.InteropServices.Marshal]::PtrToStringUni($pBuffer) }
                finally { [BRAVO.Interop.WTSApi]::WTSFreeMemory($pBuffer) }
            }
            [void]$sessions.Add([pscustomobject]@{
                SessionId = [int]$info.SessionId
                State     = [int]$info.State
                UserName  = [string]$userName
            })
        }
    } finally {
        [BRAVO.Interop.WTSApi]::WTSFreeMemory($pSessionInfo)
    }
    return $sessions.ToArray()
}

function Send-BRAVOWTSTextMessage {
    # bWait=$false (не блокує відправника, користувач закриває MessageBox
    # сам); стиль 0 = MB_OK; TimeoutSeconds — автозакриття вікна на клієнті.
    param(
        [Parameter(Mandatory = $true)][int]$SessionId,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$TimeoutSeconds = 60
    )
    Add-BRAVOWTSApiType
    $response = 0
    $ok = [BRAVO.Interop.WTSApi]::WTSSendMessageW((New-Object IntPtr 0), $SessionId, $Title, $Title.Length, $Message, $Message.Length, 0, $TimeoutSeconds, [ref]$response, $false)
    return [bool]$ok
}

function Get-BRAVOClientGateInventory {
    # Зводить процеси (за іменем, у БУДЬ-ЯКІЙ сесії) із переліком сесій у
    # класифікацію, потрібну воротам: Active (чекати й попереджати) чи
    # Disconnected/NoUser/Unknown (закривати негайно, без попередження).
    param(
        [Parameter(Mandatory = $true)][string[]]$ProcessNames,
        [Parameter(Mandatory = $true)][scriptblock]$ProcessProvider,
        [Parameter(Mandatory = $true)][scriptblock]$SessionProvider
    )
    $sessions = @(& $SessionProvider)
    $sessionById = @{}
    foreach ($sessionEntry in $sessions) {
        $sessionById[[int]$sessionEntry.SessionId] = $sessionEntry
    }

    $inventory = New-Object System.Collections.Generic.List[object]
    foreach ($procName in $ProcessNames) {
        $procs = @(& $ProcessProvider $procName)
        foreach ($proc in $procs) {
            if ($null -eq $proc) { continue }
            $sessionId = [int]$proc.SessionId
            $classification = 'Unknown'
            $userName = ''
            if ($sessionId -eq 0) {
                # Сесія 0 — службова, без інтерактивного користувача (issue #316, п.2).
                $classification = 'NoUser'
            } elseif (-not $sessionById.ContainsKey($sessionId)) {
                $classification = 'Unknown'
            } else {
                $sessionEntry = $sessionById[$sessionId]
                $userName = [string]$sessionEntry.UserName
                if ([string]::IsNullOrEmpty($userName)) {
                    $classification = 'NoUser'
                } elseif ([int]$sessionEntry.State -eq 0) {
                    $classification = 'Active'
                } elseif ([int]$sessionEntry.State -eq 4) {
                    $classification = 'Disconnected'
                } else {
                    $classification = 'Unknown'
                }
            }
            [void]$inventory.Add([pscustomobject]@{
                ProcessId      = [int]$proc.Id
                ProcessName    = [string]$procName
                SessionId      = $sessionId
                UserName       = $userName
                Classification = $classification
            })
        }
    }
    return $inventory.ToArray()
}

function Invoke-BRAVOMaintenanceClientCloseGate {
    <#
        Ворота закриття BIS перед реставрацією (#316, рішення власника
        2026-09-30). Повертає результат (ImmediateClosures/UserClosures/
        ForcedClosures/StillRunning/Messages) — викликач (Invoke-
        BRAVOMaintenanceClientCloseStep у BRAVO.Maintenance.Runtime.ps1)
        перетворює його на журнал/операцію/сповіщення/критичну відмову.

        WaitMinutes=0 — закривати без очікування і без попереджень УСІ
        знайдені процеси, включно з Active-сесіями (акцептанс-критерій).
    #>
    [CmdletBinding()]
    param(
        [string[]]$ProcessNames = @('Bis'),
        [int]$WaitMinutes = 5,
        [int]$ReminderMinutes = 1,
        [int]$PollSeconds = 10,
        [scriptblock]$ProcessProvider = { param($Name) Get-Process -Name $Name -ErrorAction SilentlyContinue },
        [scriptblock]$SessionProvider = { Get-BRAVOWTSSessionInfo },
        [scriptblock]$MessageSender = { param($SessionId, $Title, $Message) Send-BRAVOWTSTextMessage -SessionId $SessionId -Title $Title -Message $Message },
        [scriptblock]$ProcessStopper = { param($ProcessId) Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue },
        [scriptblock]$ClockNow = { Get-Date },
        [scriptblock]$Waiter = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )

    $result = [pscustomobject]@{
        ImmediateClosures = New-Object System.Collections.Generic.List[object]
        UserClosures      = New-Object System.Collections.Generic.List[object]
        ForcedClosures    = New-Object System.Collections.Generic.List[object]
        StillRunning      = New-Object System.Collections.Generic.List[object]
        Messages          = New-Object System.Collections.Generic.List[object]
    }

    $startTime = & $ClockNow
    $noWait = ($WaitMinutes -le 0)
    $deadline = $startTime.AddMinutes([Math]::Max($WaitMinutes, 0))

    $inventory = @(Get-BRAVOClientGateInventory -ProcessNames $ProcessNames -ProcessProvider $ProcessProvider -SessionProvider $SessionProvider)
    # sessionId -> стан очікування (UserName, StartTime, NextReminderAt).
    $activeSessions = @{}

    foreach ($entry in $inventory) {
        if ((-not $noWait) -and $entry.Classification -eq 'Active') {
            if (-not $activeSessions.ContainsKey($entry.SessionId)) {
                $activeSessions[$entry.SessionId] = [pscustomobject]@{
                    UserName       = $entry.UserName
                    StartTime      = $startTime
                    NextReminderAt = $startTime.AddMinutes($ReminderMinutes)
                }
            }
        } else {
            [void](& $ProcessStopper $entry.ProcessId)
            [void]$result.ImmediateClosures.Add($entry)
        }
    }

    if ((-not $noWait) -and $activeSessions.Count -gt 0) {
        $deadlineText = $deadline.ToString('HH:mm')
        foreach ($sessionId in @($activeSessions.Keys)) {
            $message = "Увага: збережіть роботу і закрийте BIS. О $deadlineText програму буде закрито автоматично."
            [void](& $MessageSender $sessionId 'BRAVO: автоматичне закриття BIS' $message)
            [void]$result.Messages.Add([pscustomobject]@{ SessionId = $sessionId; UserName = $activeSessions[$sessionId].UserName; Message = $message; At = $startTime })
        }

        while ($activeSessions.Count -gt 0) {
            $now = & $ClockNow
            if ($now -ge $deadline) { break }

            [void](& $Waiter $PollSeconds)
            $now = & $ClockNow

            $currentInventory = @(Get-BRAVOClientGateInventory -ProcessNames $ProcessNames -ProcessProvider $ProcessProvider -SessionProvider $SessionProvider)
            $currentActiveBySession = @{}
            foreach ($entry in $currentInventory) {
                if ($entry.Classification -eq 'Active') {
                    if (-not $currentActiveBySession.ContainsKey($entry.SessionId)) {
                        $currentActiveBySession[$entry.SessionId] = $entry
                    }
                } else {
                    # Нова stray-поява (інша сесія/NoUser/Unknown) під час очікування — закрити одразу.
                    [void](& $ProcessStopper $entry.ProcessId)
                    [void]$result.ImmediateClosures.Add($entry)
                }
            }

            # Нова Active-сесія з BIS, виявлена під час очікування — повідомлення одразу, той самий дедлайн.
            foreach ($sessionId in @($currentActiveBySession.Keys)) {
                if (-not $activeSessions.ContainsKey($sessionId)) {
                    $newEntry = $currentActiveBySession[$sessionId]
                    $activeSessions[$sessionId] = [pscustomobject]@{
                        UserName       = $newEntry.UserName
                        StartTime      = $now
                        NextReminderAt = $now.AddMinutes($ReminderMinutes)
                    }
                    $deadlineText = $deadline.ToString('HH:mm')
                    $message = "Увага: збережіть роботу і закрийте BIS. О $deadlineText програму буде закрито автоматично."
                    [void](& $MessageSender $sessionId 'BRAVO: автоматичне закриття BIS' $message)
                    [void]$result.Messages.Add([pscustomobject]@{ SessionId = $sessionId; UserName = $newEntry.UserName; Message = $message; At = $now })
                }
            }

            # Сесії, де BIS уже не видно — користувач закрив сам.
            foreach ($sessionId in @($activeSessions.Keys)) {
                if (-not $currentActiveBySession.ContainsKey($sessionId)) {
                    $tracked = $activeSessions[$sessionId]
                    $waitedSeconds = [int]($now - $tracked.StartTime).TotalSeconds
                    [void]$result.UserClosures.Add([pscustomobject]@{ SessionId = $sessionId; UserName = $tracked.UserName; WaitedSeconds = $waitedSeconds })
                    $activeSessions.Remove($sessionId)
                }
            }

            # Нагадування щохвилини (ReminderMinutes); останнє — "залишилась 1 хвилина".
            foreach ($sessionId in @($activeSessions.Keys)) {
                $tracked = $activeSessions[$sessionId]
                if ($now -ge $tracked.NextReminderAt -and $now -lt $deadline) {
                    $remainingMinutes = [Math]::Ceiling(($deadline - $now).TotalMinutes)
                    if ($remainingMinutes -le [Math]::Max($ReminderMinutes, 1)) {
                        $message = "Увага: залишилась 1 хвилина — BIS буде закрито автоматично."
                    } else {
                        $deadlineText = $deadline.ToString('HH:mm')
                        $message = "Нагадування: збережіть роботу і закрийте BIS. О $deadlineText програму буде закрито автоматично."
                    }
                    [void](& $MessageSender $sessionId 'BRAVO: автоматичне закриття BIS' $message)
                    [void]$result.Messages.Add([pscustomobject]@{ SessionId = $sessionId; UserName = $tracked.UserName; Message = $message; At = $now })
                    $tracked.NextReminderAt = $tracked.NextReminderAt.AddMinutes($ReminderMinutes)
                }
            }
        }

        # Дедлайн настав — хто лишився, закривається примусово.
        if ($activeSessions.Count -gt 0) {
            $finalInventory = @(Get-BRAVOClientGateInventory -ProcessNames $ProcessNames -ProcessProvider $ProcessProvider -SessionProvider $SessionProvider)
            foreach ($entry in $finalInventory) {
                if ($activeSessions.ContainsKey($entry.SessionId)) {
                    [void](& $ProcessStopper $entry.ProcessId)
                    [void]$result.ForcedClosures.Add([pscustomobject]@{
                        SessionId = $entry.SessionId
                        UserName  = $activeSessions[$entry.SessionId].UserName
                        ProcessId = $entry.ProcessId
                        At        = (& $ClockNow)
                    })
                }
            }
        }
    }

    # Фінальна перевірка (акцептанс #5): будь-що з ProcessNames, що лишилось, — CRITICAL.
    $verifyInventory = @(Get-BRAVOClientGateInventory -ProcessNames $ProcessNames -ProcessProvider $ProcessProvider -SessionProvider $SessionProvider)
    foreach ($entry in $verifyInventory) {
        [void]$result.StillRunning.Add($entry)
    }

    return $result
}

function Invoke-BRAVOMaintenanceClientCloseStep {
    param(
        # Self-test seam: підміняє реальний виклик Invoke-BRAVOMaintenanceClientCloseGate
        # заготовленим результатом, щоб перевірити журнал/операцію/критичну
        # відмову цієї функції без реального wtsapi32.dll чи Get-Process.
        [scriptblock]$GateInvoker
    )
    # Викликається з Invoke-BRAVOMaintenance (Runtime.ps1) ПЕРЕД "Зупинка
    # служб", коли $shouldRestore=$true (#316, рішення власника 2026-09-30).
    # Не нумерований [N/8]-крок (ту стабільну нумерацію свідомо не чіпаємо) —
    # рендериться через Write-BRAVOMaintenanceOperation, той самий unnumbered
    # патерн, що вже "Повторна зупинка служб перед архівацією".
    #
    # Повертає $true, якщо реставрацію можна продовжувати, $false — якщо BIS
    # не вдалося закрити й реставрацію потрібно скасувати (CRITICAL: generic
    # exit 60 MaintenanceFailed через $script:criticalErrorOccurred — новий
    # код НЕ вводиться, та сама §56.1 політика, що й решта критичних відмов
    # цього runtime).
    # Test-Path Variable: -- $maintenanceSettings живе у ЦЬОМУ файлі лише
    # динамічним scope з Invoke-BRAVOMaintenance; під Set-StrictMode -Version
    # 2.0 пряме звернення до змінної, яку викликач взагалі не оголосив (self-
    # test orchestration-проба не завжди її сіє), кидає виняток ДО того, як
    # -is [hashtable] встигне повернути $false. Той самий принцип, що Test-Path
    # Variable:-гейти в Send-BRAVOArchiveFinalOperationsEvent (#448).
    $clientCloseSettings = $null
    if ((Test-Path Variable:maintenanceSettings) -and $maintenanceSettings -is [hashtable] -and
        $maintenanceSettings.Restore -is [hashtable] -and $maintenanceSettings.Restore.ClientClose -is [hashtable]) {
        $clientCloseSettings = $maintenanceSettings.Restore.ClientClose
    }
    $clientCloseWaitMinutes = 5
    $clientCloseReminderMinutes = 1
    $clientClosePollSeconds = 10
    $clientCloseProcessNames = @('Bis')
    if ($null -ne $clientCloseSettings) {
        $clientCloseWaitMinutes = [int]$clientCloseSettings.WaitMinutes
        $clientCloseReminderMinutes = [int]$clientCloseSettings.ReminderMinutes
        $clientClosePollSeconds = [int]$clientCloseSettings.PollSeconds
        $clientCloseProcessNames = @($clientCloseSettings.ProcessNames)
    }

    if ($null -ne $GateInvoker) {
        $clientGateResult = & $GateInvoker
    } else {
        $clientGateResult = Invoke-BRAVOMaintenanceClientCloseGate `
            -ProcessNames $clientCloseProcessNames `
            -WaitMinutes $clientCloseWaitMinutes `
            -ReminderMinutes $clientCloseReminderMinutes `
            -PollSeconds $clientClosePollSeconds
    }

    # $clientGateResult.* -- властивості List[object] (New-Object): @(...)
    # на них напряму кидає ArgumentException "Argument types do not match" у
    # Windows PowerShell 5.1 (Governance/GenericObjectListNeverWrappedInArraySubexpression) --
    # foreach/.Count/pipe працюють з List[object] напряму, без @()-касту.
    foreach ($immediateClosure in $clientGateResult.ImmediateClosures) {
        Write-Log -Message "BIS ($($immediateClosure.ProcessName), PID $($immediateClosure.ProcessId)) закрито негайно: сесія $($immediateClosure.SessionId) ($($immediateClosure.Classification)), без очікування і повідомлень" -Level "INFO"
    }
    foreach ($userClosure in $clientGateResult.UserClosures) {
        Write-Log -Message "BIS закрито користувачем $($userClosure.UserName) (сесія $($userClosure.SessionId)) самостійно, час очікування $($userClosure.WaitedSeconds) с -- примусове закриття не застосовувалось" -Level "INFO"
    }
    foreach ($gateMessage in $clientGateResult.Messages) {
        Write-Log -Message "Попередження про автозакриття BIS надіслано у сесію $($gateMessage.SessionId) ($($gateMessage.UserName)): $($gateMessage.Message)" -Level "INFO"
    }
    foreach ($forcedClosure in $clientGateResult.ForcedClosures) {
        Write-Log -Message "BIS примусово закрито після закінчення очікування: користувач $($forcedClosure.UserName), сесія $($forcedClosure.SessionId), PID $($forcedClosure.ProcessId)" -Level "WARNING"
    }

    $stillRunningEntries = $clientGateResult.StillRunning
    if ($stillRunningEntries.Count -gt 0) {
        $stillRunningDetails = (($stillRunningEntries | ForEach-Object { "сесія $($_.SessionId) PID $($_.ProcessId)" }) -join '; ')
        Write-Log -Message "BIS не вдалося закрити перед реставрацією: $stillRunningDetails -- реставрацію скасовано" -Level "ERROR"
        $script:criticalErrorOccurred = $true
        Write-BRAVOMaintenanceOperation -Name 'Закриття клієнтів BIS' -Status 'FAIL' -Details $stillRunningDetails
        return $false
    }

    $forcedClosures = $clientGateResult.ForcedClosures
    $closedCount = $clientGateResult.ImmediateClosures.Count + $clientGateResult.UserClosures.Count + $forcedClosures.Count
    if ($forcedClosures.Count -gt 0) {
        $forcedDetails = (($forcedClosures | ForEach-Object { "$($_.UserName)@сесія $($_.SessionId)" }) -join '; ')
        Write-BRAVOMaintenanceOperation -Name 'Закриття клієнтів BIS' -Status 'WARN' -Details $forcedDetails
    } elseif ($closedCount -gt 0) {
        Write-BRAVOMaintenanceOperation -Name 'Закриття клієнтів BIS' -Status 'OK' -Details "закрито клієнтів: $closedCount"
    } else {
        Write-BRAVOMaintenanceOperation -Name 'Закриття клієнтів BIS' -Status 'SKIPPED' -Details 'активних клієнтів BIS не знайдено'
    }

    return $true
}
