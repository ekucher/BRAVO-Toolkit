# Archive-specific extensions of the shared BRAVO runtime.
# They serialize WinSCP.com access and import their Compatibility dependency.
$compatibilityManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.Compatibility\BRAVO.Compatibility.psd1'
Import-Module -Name $compatibilityManifest -ErrorAction Stop

function Get-BRAVOBazaSyncModeEffective {
    # Одна canonical точка інтерпретації (safety-review ТЗ п.20: "не
    # дублювати business rules у Archive/Health/DryRun/Diagnose — один
    # canonical config interpretation") — Archive, Health і DryRun читають
    # РІВНО цю функцію (спільний модуль, вже імпортований обома), а не
    # $backupMonitoring.SFTP.BAZA напряму кожен по-своєму.
    $bazaSettings = $backupMonitoring.SFTP.BAZA
    $mode = if ($null -ne $bazaSettings -and $bazaSettings.Contains('Mode')) {
        [string]$bazaSettings.Mode
    } else {
        'IncrementalAppendOnly'
    }
    return $mode
}

function Test-BRAVOBazaIncrementalModeEnabled {
    return ((Get-BRAVOBazaSyncModeEffective) -eq 'IncrementalAppendOnly')
}

function Get-BRAVOBazaSettingsEffective {
    # Одна canonical точка інтерпретації ВСІХ backupMonitoring.SFTP.BAZA
    # налаштувань (ТЗ п.20/25) — StateRoot/MutationPolicy/FullAuditEveryDays/
    # SynchronizeBeforeHealth/FastHealthEnabled. Раніше Archive
    # (Invoke-BRAVOBazaIncrementalSync) і Health (fallback-sync у
    # Get-SFTPHealthIssues) обчислювали ці fallback-и НЕЗАЛЕЖНО одне від
    # одного: Archive поважав можливий BAZA.StateRoot override, а Health —
    # ні (завжди йшов у типовий $stateRoot). Якщо оператор колись
    # налаштує нетиповий StateRoot, Archive і Health писали б і читали б
    # ДВА РІЗНІ файли стану того самого компонента — тихе розходження
    # стану без жодної помилки. Спільна функція усуває цей клас багів
    # структурно: обидва викликачі (і DryRun) читають РІВНО цю точку.
    $bazaSettings = $backupMonitoring.SFTP.BAZA

    $stateRootEffective = if ($null -ne $bazaSettings -and $bazaSettings.Contains('StateRoot') -and
        -not [string]::IsNullOrWhiteSpace([string]$bazaSettings.StateRoot)) {
        [string]$bazaSettings.StateRoot
    } else {
        [string]$stateRoot
    }
    $mutationPolicyEffective = if ($null -ne $bazaSettings -and $bazaSettings.Contains('MutationPolicy') -and
        -not [string]::IsNullOrWhiteSpace([string]$bazaSettings.MutationPolicy)) {
        [string]$bazaSettings.MutationPolicy
    } else {
        'Fail'
    }
    $fullAuditEnabledEffective = if ($null -ne $bazaSettings -and $bazaSettings.Contains('FullAuditEnabled')) {
        [bool]$bazaSettings.FullAuditEnabled
    } else {
        $true
    }
    $fullAuditEveryDaysEffective = if ($fullAuditEnabledEffective -and $null -ne $bazaSettings -and
        $bazaSettings.Contains('FullAuditEveryDays') -and [double]$bazaSettings.FullAuditEveryDays -gt 0) {
        [double]$bazaSettings.FullAuditEveryDays
    } elseif ($fullAuditEnabledEffective) {
        7
    } else {
        0
    }
    $synchronizeBeforeHealthEffective = if ($null -ne $bazaSettings -and $bazaSettings.Contains('SynchronizeBeforeHealth')) {
        [bool]$bazaSettings.SynchronizeBeforeHealth
    } else {
        $true
    }
    $fastHealthEnabledEffective = if ($null -ne $bazaSettings -and $bazaSettings.Contains('FastHealthEnabled')) {
        [bool]$bazaSettings.FastHealthEnabled
    } else {
        $true
    }

    return [pscustomobject]@{
        Mode = Get-BRAVOBazaSyncModeEffective
        StateRoot = $stateRootEffective
        MutationPolicy = $mutationPolicyEffective
        FullAuditEnabled = $fullAuditEnabledEffective
        FullAuditEveryDays = $fullAuditEveryDaysEffective
        SynchronizeBeforeHealth = $synchronizeBeforeHealthEffective
        FastHealthEnabled = $fastHealthEnabledEffective
    }
}

function Get-BRAVOWinSCPDotNetComponents {
    [CmdletBinding()]
    param(
        [string]$WinSCPAssemblyPath,
        [string]$WinSCPPath
    )

    $assemblyCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($WinSCPAssemblyPath)) {
        $assemblyCandidates += $WinSCPAssemblyPath
    }
    if (-not [string]::IsNullOrWhiteSpace($WinSCPPath)) {
        $assemblyCandidates += Join-Path `
            (Split-Path -Path $WinSCPPath -Parent) `
            'WinSCPnet.dll'
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $assemblyCandidates += Join-Path `
            ${env:ProgramFiles(x86)} `
            'WinSCP\WinSCPnet.dll'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $assemblyCandidates += Join-Path `
            $env:ProgramFiles `
            'WinSCP\WinSCPnet.dll'
    }

    foreach ($assemblyPath in @($assemblyCandidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
            continue
        }
        $executablePath = Join-Path `
            (Split-Path -Path $assemblyPath -Parent) `
            'WinSCP.exe'
        if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
            continue
        }

        return [pscustomobject]@{
            AssemblyPath = (Resolve-Path -LiteralPath $assemblyPath).Path
            ExecutablePath = (Resolve-Path -LiteralPath $executablePath).Path
        }
    }

    return $null
}

function Enter-BRAVOWinSCPProcessLock {
    [CmdletBinding()]
    param(
        [string]$LogPath
    )

    # Явний параметр з fallback на $global:logPath (для зворотної
    # сумісності з існуючими викликами без -LogPath). Раніше функція
    # читала лише $logPath без параметра — якщо модуль колись
    # імпортується до того, як BRAVO.config встановить $global:logPath,
    # lock-файл мовчки створювався у відносному шляху поточної теки,
    # ламаючи атомарність serialize-механізму для WinSCP.com.
    if (-not $PSBoundParameters.ContainsKey('LogPath') -or [string]::IsNullOrWhiteSpace($LogPath)) {
        $LogPath = $global:logPath
    }
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        return [pscustomobject]@{
            Success = $false
            Stream = $null
            Path = $null
            Error = "Enter-BRAVOWinSCPProcessLock: LogPath не задано і `$global:logPath не ініціалізовано"
        }
    }

    $lockPath = Join-Path $LogPath "BRAVO_WINSCP.lock"
    try {
        if (-not (Test-Path -LiteralPath $LogPath -PathType Container)) {
            New-Item -ItemType Directory -Path $LogPath -Force -ErrorAction Stop | Out-Null
        }
        $stream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        return [pscustomobject]@{ Success = $true; Stream = $stream; Path = $lockPath; Error = $null }
    } catch {
        return [pscustomobject]@{ Success = $false; Stream = $null; Path = $lockPath; Error = $_.Exception.Message }
    }
}

function Test-BRAVOWinSCPAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WinSCPPath
    )

    # BRAVO запускає консольний клієнт WinSCP.com. Відкритий графічний
    # WinSCP.exe не блокує задачу, а інший WinSCP.com може одночасно змінювати
    # той самий SFTP-каталог, тому запуск у такому разі забороняємо.
    $processName = [System.IO.Path]::GetFileName($WinSCPPath)
    if ([string]::IsNullOrWhiteSpace($processName)) {
        return [pscustomobject]@{
            Available = $false
            Processes = @()
            Error = "не вдалося визначити ім'я процесу WinSCP"
        }
    }

    try {
        $activeProcesses = @(
            Get-BRAVOWmiInstance -ClassName Win32_Process -Filter "Name = '$processName'" |
                ForEach-Object {
                    [pscustomobject]@{
                        ProcessId = [int]$_.ProcessId
                        Started = [string]$_.CreationDate
                    }
                }
        )
        return [pscustomobject]@{
            Available = ($activeProcesses.Count -eq 0)
            Processes = $activeProcesses
            Error = $null
        }
    } catch {
        # Без достовірної перевірки не запускаємо передачу паралельно.
        return [pscustomobject]@{
            Available = $false
            Processes = @()
            Error = "не вдалося перевірити активні процеси ${processName}: $($_.Exception.Message)"
        }
    }
}

function Get-BRAVOWinSCPBusyMessage {
    param(
        [Parameter(Mandatory = $true)]
        $Availability,
        [string]$Operation = "операція SFTP"
    )

    # Результат іде у Write-BRAVOLog (Archive) і в throw (Health), тобто в
    # журнал і в сповіщення — тому проходить ту саму єдину точку
    # санітизації, що й stdout/stderr WinSCP.
    #
    # ЧОМУ ЦЕ НЕ ЗАЙВЕ (аудит Low #10): $Availability.Error — це вільний
    # текст, узятий з $_.Exception.Message запиту WMI, а $Availability
    # описує ЧУЖИЙ процес WinSCP. Сьогодні звідти беруться лише ProcessId,
    # і витікати нема чому. Але найприроднішим розширенням діагностики
    # "який саме WinSCP зараз працює" є CommandLine з Win32_Process — а він
    # містить sftp://user:password@host. Тоді повідомлення про зайнятість
    # стало б місцем витоку пароля в лог. Санітизація тут робить це
    # розширення безпечним заздалегідь, а не після інциденту.
    if (-not [string]::IsNullOrWhiteSpace([string]$Availability.Error)) {
        return (Get-SanitizedWinSCPDiagnostic `
            -Text "Запуск WinSCP для ${Operation} заблоковано: $($Availability.Error)")
    }

    $processDetails = @($Availability.Processes | ForEach-Object {
        "PID=$($_.ProcessId)"
    }) -join ", "
    return (Get-SanitizedWinSCPDiagnostic `
        -Text "Запуск WinSCP для ${Operation} заблоковано: виявлено активний WinSCP.com ($processDetails)")
}

function Get-SanitizedWinSCPDiagnostic {
    # Спільна санітизація stdout/stderr WinSCP.com для Archive і Health
    # runtime — раніше була продубльована окремо в кожному з них, тож
    # правка регексу маскування пароля/host key ризикувала застосуватись
    # лише в одному місці.
    param(
        [AllowNull()]
        [string]$Text,
        [int]$MaximumLines = 80
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $sanitized = $Text
    $sanitized = $sanitized -replace '(?i)(sftp://)[^@\s]+@', '$1***@'
    $sanitized = $sanitized -replace '(?i)(-password=)(?:"[^"]*"|\S+)', '$1***'
    $lines = @(
        $sanitized -split '\r?\n' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $safeMaximumLines = [math]::Max(1, $MaximumLines)
    if ($lines.Count -gt $safeMaximumLines) {
        $omittedCount = $lines.Count - $safeMaximumLines
        $lines = @(
            "... пропущено рядкiв WinSCP: $omittedCount ..."
            $lines | Select-Object -Last $safeMaximumLines
        )
    }

    return ($lines -join [Environment]::NewLine)
}

