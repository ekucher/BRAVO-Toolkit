# Спільне transcript-журналювання для допоміжних скриптів BRAVO.
# Production-скрипти мають власні предметні журнали й цей файл не підключають.

$script:BRAVOHelperLogActive = $false
$script:BRAVOHelperLogPath = $null
$script:BRAVOHelperLogQuietConsole = $false
$script:BRAVOHelperLogSuspended = $false
# $null — canary-перевірку ще не виконували; $true/$false — кешований результат.
$script:BRAVOHelperLogSuspensionEffective = $null

function Start-BRAVOHelperLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [string]$ConfigPath,

        [switch]$QuietConsole,

        [ValidateRange(1, 3650)]
        [int]$RetentionDays = 31
    )

    if ($script:BRAVOHelperLogActive) {
        return [string]$script:BRAVOHelperLogPath
    }

    $scriptDirectory = Split-Path -Path $ScriptPath -Parent
    if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
        $scriptDirectory = [Environment]::CurrentDirectory
    }

    $preferredLogDirectory = Join-Path $scriptDirectory "LOGS\HELPERS"
    $logDirectory = $preferredLogDirectory
    try {
        [void][IO.Directory]::CreateDirectory($logDirectory)
    } catch {
        $logDirectory = Join-Path ([IO.Path]::GetTempPath()) "BRAVO\LOGS\HELPERS"
        try {
            [void][IO.Directory]::CreateDirectory($logDirectory)
            if (-not $QuietConsole) {
                Write-Warning (
                    "Не вдалося створити каталог журналів '$preferredLogDirectory'. " +
                    "Використовується резервний каталог '$logDirectory'."
                )
            }
        } catch {
            if (-not $QuietConsole) {
                Write-Warning "Не вдалося створити каталог журналів допоміжних скриптів: $($_.Exception.Message)"
            }
            return $null
        }
    }

    $scriptName = [IO.Path]::GetFileNameWithoutExtension($ScriptPath)
    $safeScriptName = $scriptName -replace '[^A-Za-z0-9_.-]', '_'
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    $logFileName = "{0}_{1}_PID{2}.log" -f $safeScriptName, $timestamp, $PID
    $logPath = Join-Path $logDirectory $logFileName

    try {
        $retentionThreshold = (Get-Date).AddDays(-$RetentionDays)
        Get-ChildItem -LiteralPath $logDirectory -Filter "*.log" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $retentionThreshold } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        if (-not $QuietConsole) {
            Write-Warning "Не вдалося очистити застарілі helper-логи: $($_.Exception.Message)"
        }
    }

    try {
        Start-Transcript -Path $logPath -Force | Out-Null
        $script:BRAVOHelperLogActive = $true
        $script:BRAVOHelperLogPath = $logPath
        $script:BRAVOHelperLogQuietConsole = [bool]$QuietConsole
        if (-not $QuietConsole) {
            Write-Host "Лог допоміжного скрипта: $logPath" -ForegroundColor DarkGray
            Write-Host (
                "Запуск: script=$scriptName; user=$([Security.Principal.WindowsIdentity]::GetCurrent().Name); " +
                "computer=$env:COMPUTERNAME; PID=$PID; PowerShell=$($PSVersionTable.PSVersion)"
            ) -ForegroundColor DarkGray
            if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
                Write-Host "Config: $ConfigPath" -ForegroundColor DarkGray
            }
        }
        return $logPath
    } catch {
        $script:BRAVOHelperLogActive = $false
        $script:BRAVOHelperLogPath = $null
        $script:BRAVOHelperLogQuietConsole = $false
        if (-not $QuietConsole) {
            Write-Warning "Не вдалося розпочати журнал допоміжного скрипта: $($_.Exception.Message)"
        }
        return $null
    }
}

function Suspend-BRAVOHelperLog {
    # Тимчасово зупиняє transcript, щоб те, що зараз з'явиться на екрані, НЕ
    # потрапило у файл журналу. Використовується для інтерактивного вводу
    # облікових даних: оператор має бачити, що набирає, але значення не має
    # осідати в лозі, який потім пересилають у підтримку.
    #
    # Повертає $true ЛИШЕ при фактичному успіху. Викликач зобов'язаний
    # трактувати $false як заборону показувати щось чутливе: журнал усе ще
    # пише. Функція ніколи не кидає — інакше помилка журналювання зривала б
    # саму операцію.
    [CmdletBinding()]
    param()

    if (-not $script:BRAVOHelperLogActive) {
        # Журналу немає взагалі — писати нікуди, отже вивід уже «прихований».
        return $true
    }
    if ($script:BRAVOHelperLogSuspended) {
        return $true
    }
    try {
        Stop-Transcript | Out-Null
        $script:BRAVOHelperLogSuspended = $true
        return $true
    } catch {
        $script:BRAVOHelperLogSuspended = $false
        return $false
    }
}

function Resume-BRAVOHelperLog {
    # Парна до Suspend-BRAVOHelperLog; викликається ЛИШЕ з finally, інакше
    # виняток під час вводу лишив би журнал вимкненим до кінця процесу.
    [CmdletBinding()]
    param()

    if (-not $script:BRAVOHelperLogSuspended) {
        return $true
    }
    $resumePath = [string]$script:BRAVOHelperLogPath
    if ([string]::IsNullOrWhiteSpace($resumePath)) {
        $script:BRAVOHelperLogSuspended = $false
        return $false
    }
    try {
        Start-Transcript -Path $resumePath -Append | Out-Null
        $script:BRAVOHelperLogSuspended = $false
        return $true
    } catch {
        $script:BRAVOHelperLogSuspended = $false
        return $false
    }
}

function Test-BRAVOHelperLogSuspensionEffective {
    # Транскрипція перехоплює вивід по-різному в Windows PowerShell 5.1 і
    # PowerShell 7, а поведінка хоста може залежати ще й від групової політики.
    # Тому справність паузи НЕ приймається на віру: друкуємо унікальний маркер
    # у вікні паузи й перевіряємо, що у файлі його немає.
    #
    # Знайдений маркер означає, що на цьому хості пауза не працює. Єдина
    # коректна реакція викликача — fail-closed: не показувати значення взагалі.
    [CmdletBinding()]
    param()

    if ($null -ne $script:BRAVOHelperLogSuspensionEffective) {
        return [bool]$script:BRAVOHelperLogSuspensionEffective
    }
    if (-not $script:BRAVOHelperLogActive) {
        # Немає активного transcript — немає й файлу, куди могло б протекти.
        $script:BRAVOHelperLogSuspensionEffective = $true
        return $true
    }

    $canaryPath = [string]$script:BRAVOHelperLogPath
    $canary = 'BRAVO-LOG-SUSPENSION-CANARY-{0}' -f [guid]::NewGuid().ToString('N')
    $effective = $false
    try {
        if (Suspend-BRAVOHelperLog) {
            try {
                # Маркер друкується тим самим каналом, що й реальні підказки
                # вводу — інакше перевірка стосувалася б не того шляху.
                Write-Host $canary
            } finally {
                [void](Resume-BRAVOHelperLog)
            }
            $logText = ''
            try {
                $logText = [IO.File]::ReadAllText($canaryPath)
            } catch {
                # Файл не прочитався — довести відсутність витоку неможливо.
                $logText = $canary
            }
            $effective = -not $logText.Contains($canary)
        }
    } catch {
        $effective = $false
    }

    $script:BRAVOHelperLogSuspensionEffective = $effective
    return $effective
}

function Complete-BRAVOHelperLog {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    if ($script:BRAVOHelperLogActive) {
        $completedLogPath = [string]$script:BRAVOHelperLogPath
        $quietConsole = [bool]$script:BRAVOHelperLogQuietConsole
        if (-not $quietConsole) {
            Write-Host "Код завершення допоміжного скрипта: $ExitCode" -ForegroundColor DarkGray
            Write-Host "Лог допоміжного скрипта: $completedLogPath" -ForegroundColor DarkGray
        }
        try {
            Stop-Transcript | Out-Null
        } catch {
            if (-not $quietConsole) {
                Write-Warning "Не вдалося коректно завершити transcript: $($_.Exception.Message)"
            }
        }
        if ($quietConsole) {
            try {
                [IO.File]::AppendAllText(
                    $completedLogPath,
                    "`r`nBRAVO helper process exit code: $ExitCode`r`n",
                    [Text.Encoding]::UTF8
                )
            } catch {
                # Machine-readable stdout має залишатися чистим навіть при помилці логування.
            }
        }
        $script:BRAVOHelperLogActive = $false
        $script:BRAVOHelperLogQuietConsole = $false
        $script:BRAVOHelperLogSuspended = $false
    }

    exit $ExitCode
}
