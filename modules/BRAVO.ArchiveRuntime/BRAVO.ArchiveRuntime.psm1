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
    $mode = Get-BRAVOBazaSyncModeEffective

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
    # AutoArchiveMutationThreshold: 0 = вимкнено (default, безпечна поведінка
    # для всіх існуючих/нових інсталяцій без зміни конфігу — MUTATION_VIOLATION
    # і далі жорстко блокує). Оператор, що свідомо вмикає значення > 0, дозволяє
    # автоматичне rename-preserve-архівування (та сама операція, що ручний
    # BRAVO_BAZA_RECONCILE.ps1 -AcceptAll) для циклів, де кількість мутацій НЕ
    # перевищує поріг; понад поріг поведінка незмінна (жорсткий блок).
    $autoArchiveMutationThresholdEffective = if ($null -ne $bazaSettings -and
        $bazaSettings.Contains('AutoArchiveMutationThreshold') -and
        [int]$bazaSettings.AutoArchiveMutationThreshold -gt 0) {
        [int]$bazaSettings.AutoArchiveMutationThreshold
    } else {
        0
    }

    # P2 (deep review): раніше production Health БЕЗУМОВНО синхронізувала
    # BAZA перед перевіркою і завжди йшла Fast Health-шляхом — SynchronizeBeforeHealth/
    # FastHealthEnabled лише ВІДОБРАЖАЛИСЬ (DryRun), але жоден рантайм-код
    # їх фактично не читав як умову. Config, що обіцяє контроль, якого
    # немає, — гірше за відсутність config: оператор міг поставити
    # SynchronizeBeforeHealth=$false, очікуючи іншої поведінки, і
    # мовчки отримати ту саму стару (обов'язкову sync-before-check).
    #
    # Для Mode=IncrementalAppendOnly ОБИДВА є mandatory-інваріантами, а не
    # звичайним opt-out (ТЗ: "SynchronizeBeforeHealth should NOT be a
    # normal opt-out"; "Do NOT let FastHealthEnabled=false silently
    # restore a full 50+GB preview... unless explicitly Legacy mode") —
    # Legacy-поведінка (повний preview, без обов'язкового sync-перед-
    # перевіркою) уже доступна явно через Mode="Legacy", тому false тут
    # не ігнорується мовчки, а відхиляється з чіткою вказівкою, як
    # виправити.
    if ($mode -eq 'IncrementalAppendOnly' -and -not $synchronizeBeforeHealthEffective) {
        throw (
            "backupMonitoring.SFTP.BAZA.SynchronizeBeforeHealth=`$false несумісний з Mode=`"IncrementalAppendOnly`": " +
            "sync-перед-перевіркою — обов'язковий інваріант цього режиму, не звичайний opt-out. " +
            "Якщо потрібна стара поведінка (без гарантії sync-перед-Health) — встановіть " +
            "backupMonitoring.SFTP.BAZA.Mode=`"Legacy`" явно, а не лише SynchronizeBeforeHealth=`$false."
        )
    }
    if ($mode -eq 'IncrementalAppendOnly' -and -not $fastHealthEnabledEffective) {
        throw (
            "backupMonitoring.SFTP.BAZA.FastHealthEnabled=`$false несумісний з Mode=`"IncrementalAppendOnly`": " +
            "немає підтримуваного «гібридного» режиму (incremental sync, але повний 50+ ГБ preview на Health). " +
            "Якщо потрібен старий full-preview шлях — встановіть backupMonitoring.SFTP.BAZA.Mode=`"Legacy`" явно, " +
            "а не лише FastHealthEnabled=`$false."
        )
    }

    return [pscustomobject]@{
        Mode = $mode
        StateRoot = $stateRootEffective
        MutationPolicy = $mutationPolicyEffective
        FullAuditEnabled = $fullAuditEnabledEffective
        FullAuditEveryDays = $fullAuditEveryDaysEffective
        SynchronizeBeforeHealth = $synchronizeBeforeHealthEffective
        FastHealthEnabled = $fastHealthEnabledEffective
        AutoArchiveMutationThreshold = $autoArchiveMutationThresholdEffective
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

function Remove-BRAVOWinSCPSensitiveTemporaryScript {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]"\/")
    $fullPath = [IO.Path]::GetFullPath($Path)
    $expectedPrefix = $temporaryRoot + [IO.Path]::DirectorySeparatorChar
    $fileName = [IO.Path]::GetFileName($fullPath)
    if (-not $fullPath.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $fileName -notmatch '^BRAVO_WinSCP_[0-9a-f]{32}\.txt$') {
        throw "відхилено небезпечний шлях тимчасового WinSCP-файла: $Path"
    }

    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        # Спершу прибираємо вміст із доступного файлового запису, потім файл.
        [IO.File]::WriteAllText($fullPath, "", [Text.Encoding]::ASCII)
        Remove-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    }
}

function Clear-BRAVOStaleWinSCPSensitiveTemporaryScripts {
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $staleBefore = (Get-Date).AddDays(-1)
    foreach ($file in @(
            Get-ChildItem `
                -LiteralPath $temporaryRoot `
                -Filter "BRAVO_WinSCP_*.txt" `
                -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $staleBefore }
        )) {
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $file.FullName
        } catch {
            # Файл іншого облікового запису може мати закритий ACL.
        }
    }
}

function New-BRAVOWinSCPTemporaryScriptPath {
    # WinSCP script містить URL з обліковими даними, тому файл створюється
    # ОДРАЗУ з фінальним DACL — доступ лише поточному користувачу, SYSTEM і
    # Administrators.
    #
    # ЧОМУ НЕ "створити, потім Set-Acl" (аудит Low #9): між створенням файлу
    # й накладанням ACL файл існує з успадкованими від %TEMP% правами. Для
    # запланованого завдання %TEMP% — це C:\Windows\Temp, куди має доступ
    # значно ширше коло. Порожній файл у цьому вікні секрету ще не містить,
    # але Windows перевіряє права в момент ВІДКРИТТЯ дескриптора, а не при
    # кожному читанні: відкритий у цьому вікні дескриптор переживе зміну ACL
    # і прочитає облікові дані, які запише сюди викликач. Передача
    # FileSecurity у конструктор FileStream прибирає вікно повністю — файл
    # ніколи не існує з успадкованими правами.
    #
    # Спільний для Archive і DataRestore (обидва створюють WinSCP-скрипти з
    # SFTP URL, що містить облікові дані) — canonical owner: BRAVO.ArchiveRuntime.
    Clear-BRAVOStaleWinSCPSensitiveTemporaryScripts
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $temporaryPath = Join-Path `
        -Path $temporaryRoot `
        -ChildPath ("BRAVO_WinSCP_{0}.txt" -f [guid]::NewGuid().ToString("N"))

    # DACL будується ДО створення файлу.
    $security = New-Object System.Security.AccessControl.FileSecurity
    $security.SetAccessRuleProtection($true, $false)
    $uniqueSids = @{}
    foreach ($sid in @(
            [Security.Principal.WindowsIdentity]::GetCurrent().User,
            (New-Object Security.Principal.SecurityIdentifier("S-1-5-18")),
            (New-Object Security.Principal.SecurityIdentifier("S-1-5-32-544"))
        )) {
        if ($null -eq $sid -or $uniqueSids.ContainsKey($sid.Value)) {
            continue
        }
        $uniqueSids[$sid.Value] = $true
        $rule = New-Object `
            -TypeName System.Security.AccessControl.FileSystemAccessRule `
            -ArgumentList @(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow
            )
        [void]$security.AddAccessRule($rule)
    }

    $stream = $null
    try {
        $stream = New-Object `
            -TypeName System.IO.FileStream `
            -ArgumentList @(
                $temporaryPath,
                [IO.FileMode]::CreateNew,
                [Security.AccessControl.FileSystemRights]::Write,
                [IO.FileShare]::None,
                4096,
                [IO.FileOptions]::None,
                $security
            )
        $stream.Dispose()
        $stream = $null

        return $temporaryPath
    } catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            try {
                Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $temporaryPath
            } catch {
                # WARNING, а не мовчазний пропуск: цей файл містить облікові
                # дані SFTP. Якщо його не вдалося затерти й видалити, секрет
                # лишився в %TEMP% — оператор має про це дізнатися саме
                # зараз, а не під час розслідування витоку.
                Write-BRAVOLog `
                    -Component 'SFTP' `
                    -Message "Не вдалося прибрати тимчасовий WinSCP-скрипт з обліковими даними ($temporaryPath): $($_.Exception.Message). Видаліть файл вручну." `
                    -Level "WARNING"
            }
        }
        throw
    }
}

