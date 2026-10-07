# Єдиний журнал BRAVO з розділенням каналів.
#
# Принцип: бізнес-логіка лише повідомляє, що сталося. Цей модуль вирішує, що
# записати у файл, а що показати в консолі. Рівні файлу й консолі незалежні,
# тому докладний журнал не перевантажує оператора.
#
# Мінімальна підтримувана версія: Windows PowerShell 3.0.

# Set-StrictMode успадковується від конфігураційного завантажувача, тому весь
# стан модуля ініціалізується явно.
$script:BRAVOLogFile = $null
$script:BRAVOLogFileLevel = 'INFO'
$script:BRAVOLogConsoleLevel = 'WARNING'
$script:BRAVOLogActive = $false
$script:BRAVOLogWarningCount = 0
$script:BRAVOLogErrorCount = 0

# Куди саме йде консольна половина запису. За замовчуванням — Write-Host,
# щоб модуль лишався самодостатнім. Runtime, який рендерить операційну
# консоль, підмінює це на BRAVO.Console: інакше WARNING із бізнес-логіки
# дописався б у хвіст відкритого рядка етапу.
#
# Це навмисно callback, а не залежність від BRAVO.Console: журналювання —
# нижчий шар, і воно має працювати там, де консолі немає взагалі
# (допоміжні скрипти, -AsJson, виклик із планувальника).
$script:BRAVOLogConsoleWriter = $null

# Порядок важливий: SUCCESS свідомо нижче за WARNING, щоб підняття порога
# ніколи не приховало попереджень і помилок. У старому $global:logLevels
# SUCCESS=4 був вище за ERROR=3, через що $LogLevel="SUCCESS" ховав збої.
$script:BRAVOLogSeverity = @{
    TRACE   = 0
    DEBUG   = 1
    INFO    = 2
    SUCCESS = 3
    WARNING = 4
    ERROR   = 5
    FATAL   = 6
}

$script:BRAVOLogColors = @{
    TRACE   = 'DarkGray'
    DEBUG   = 'DarkGray'
    INFO    = 'White'
    SUCCESS = 'Green'
    WARNING = 'Yellow'
    ERROR   = 'Red'
    FATAL   = 'Red'
}

function Get-BRAVOLogSeverityValue {
    param([string]$Level)

    if (-not [string]::IsNullOrWhiteSpace($Level)) {
        $normalized = $Level.Trim().ToUpperInvariant()
        if ($script:BRAVOLogSeverity.ContainsKey($normalized)) {
            return [int]$script:BRAVOLogSeverity[$normalized]
        }
    }
    return [int]$script:BRAVOLogSeverity['INFO']
}

function Protect-BRAVOLogSecret {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,

        # #365: точні значення секретів (Get-BRAVOLogMaskSecretSet), які
        # маскуються НЕЗАЛЕЖНО від ключового слова поруч. Шаблони нижче
        # ловлять лише "password=...", URL-креди і webhook-и відомих
        # провайдерів; сирий пароль 7-Zip чи API-ключ без контексту вони
        # пропускають. Без параметра поведінка функції незмінна.
        [AllowNull()][AllowEmptyCollection()][string[]]$KnownSecret
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $sanitized = $Text
    if ($null -ne $KnownSecret) {
        # Правило значень: порожнє і whitespace-only НЕ маскуються (інакше
        # *** замінило б кожен пробіл, а секрету там немає); будь-яке інше
        # значення маскується незалежно від довжини — коротке значення
        # краще зіпсує читабельність, ніж витече. Значення з краєвими
        # пробілами маскується і як є, і в обрізаній формі (так його
        # зазвичай і використовують/логують).
        $secretVariants = New-Object 'System.Collections.Generic.List[string]'
        foreach ($knownSecretValue in $KnownSecret) {
            if ([string]::IsNullOrWhiteSpace($knownSecretValue)) { continue }
            foreach ($secretVariant in @($knownSecretValue, $knownSecretValue.Trim())) {
                if (-not $secretVariants.Contains($secretVariant)) { $secretVariants.Add($secretVariant) }
            }
        }
        # Довші — першими: якщо один секрет є підрядком іншого, коротший
        # першим перетворив би довший на "***<хвіст>", і хвіст витік би.
        foreach ($secretVariant in @($secretVariants | Sort-Object -Property Length -Descending)) {
            # String.Replace(string, string) — ordinal і без regex-семантики:
            # спецсимволи в секреті не інтерпретуються.
            $sanitized = $sanitized.Replace([string]$secretVariant, '***')
        }
    }
    # Облікові дані всередині URL: sftp://user:password@host -> sftp://user:***@host
    $sanitized = $sanitized -replace '(?i)([a-z][a-z0-9+.-]*://[^:/\s@]+):[^@\s]+@', '$1:***@'
    # Явні параметри пароля у командних рядках WinSCP і 7-Zip.
    $sanitized = $sanitized -replace '(?i)(-password=)(?:"[^"]*"|\S+)', '$1***'
    # (?!ath|assword) — інакше це правило повторно "з'їдає" вже замасковане
    # -password=*** з рядка вище, розпізнавши його як коротку форму -p.
    $sanitized = $sanitized -replace '(?i)(\s-p)(?!ath|assword)(?:"[^"]*"|\S+)', '$1***'
    $sanitized = $sanitized -replace '(?i)((?:password|passwd|secret|token)\s*[:=]\s*)(?:"[^"]*"|\S+)', '$1***'
    # Webhook URL — сам bearer-секрет, без user:pass@; підтримувані провайдери
    # (Send-BRAVOWebhookNotification -Provider slack|discord) мають токен
    # прямо у шляху, а не в окремому параметрі.
    $sanitized = $sanitized -replace '(?i)(hooks\.slack\.com/services/)\S+', '$1***'
    $sanitized = $sanitized -replace '(?i)(discord(?:app)?\.com/api/webhooks/)\S+', '$1***'
    return $sanitized
}

# #365: маскована КОПІЯ журналу для передачі назовні (SFTP). Маскування
# застосовується саме до байтів, що вивантажуються, а не до локального
# журналу заднім числом: локальний файл лишається повним джерелом
# діагностики на сервері, де він і так під тим самим захистом, що й
# Credential Manager. Копія кладеться в окремий унікальний каталог під тим
# самим ім'ям файлу — тому remote-ім'я (WinSCP put бере leaf-ім'я
# джерела) не змінюється. Будь-яка помилка читання/запису — виняток:
# викликач НЕ вивантажує нічого (fail-closed), а не оригінал.
function New-BRAVOMaskedLogCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][AllowEmptyCollection()][string[]]$KnownSecret
    )

    $copyDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('BRAVO_masked_log_' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($copyDirectory)
    try {
        $copyPath = Join-Path $copyDirectory ([System.IO.Path]::GetFileName($Path))
        # FileShare.ReadWrite: журнал прогону може бути відкритий на дозапис
        # іншим записувачем; читаємо узгоджений знімок, не блокуючи його.
        $sourceStream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            # BOM визначає кодування (UTF-8 з BOM — конвенція журналів
            # проєкту); без BOM — UTF-8 без BOM. Те саме кодування (і та сама
            # наявність преамбули) зберігається в копії.
            $sourceReader = New-Object System.IO.StreamReader($sourceStream, (New-Object System.Text.UTF8Encoding($false)), $true)
            try {
                $sourceText = $sourceReader.ReadToEnd()
                $sourceEncoding = $sourceReader.CurrentEncoding
            } finally {
                $sourceReader.Dispose()
            }
        } finally {
            $sourceStream.Dispose()
        }
        $maskedText = Protect-BRAVOLogSecret -Text $sourceText -KnownSecret $KnownSecret
        if ($null -eq $maskedText) { $maskedText = '' }
        [System.IO.File]::WriteAllText($copyPath, $maskedText, $sourceEncoding)
        return $copyPath
    } catch {
        Remove-Item -LiteralPath $copyDirectory -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Remove-BRAVOMaskedLogCopy {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $copyDirectory = [System.IO.Path]::GetDirectoryName($Path)
    # Прибирається лише власний каталог New-BRAVOMaskedLogCopy — ніколи не
    # довільний батьківський каталог переданого шляху.
    if ([string]::IsNullOrWhiteSpace($copyDirectory) -or
        -not ([System.IO.Path]::GetFileName($copyDirectory)).StartsWith('BRAVO_masked_log_', [System.StringComparison]::Ordinal)) {
        return
    }
    Remove-Item -LiteralPath $copyDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

function Initialize-BRAVOLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogFile,

        [string]$FileLevel = 'INFO',

        [string]$ConsoleLevel = 'WARNING'
    )

    $logDirectory = Split-Path -Path $LogFile -Parent
    if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and
        -not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($logDirectory)
    }

    $script:BRAVOLogFile = $LogFile
    $script:BRAVOLogFileLevel = $FileLevel
    $script:BRAVOLogConsoleLevel = $ConsoleLevel
    $script:BRAVOLogActive = $true
    $script:BRAVOLogWarningCount = 0
    $script:BRAVOLogErrorCount = 0

    return $LogFile
}

function Write-BRAVOLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('TRACE', 'DEBUG', 'INFO', 'SUCCESS', 'WARNING', 'ERROR', 'FATAL')]
        [string]$Level = 'INFO',

        [string]$Component = 'GENERAL',

        # Показати запис у консолі навіть якщо його рівень нижчий за поріг.
        [switch]$Console,

        # Ніколи не показувати запис у консолі.
        [switch]$NoConsole,

        # Environmental-нагадування (застарілі оновлення ОС/PowerShell) —
        # це стан середовища, а не результат операції. Такий запис лишається
        # видимим як WARNING, але НЕ інкрементує лічильник попереджень:
        # інакше кожен успішний прогін на невідновленому сервері назавжди
        # завершувався б кодом 10 (SuccessWithWarnings) зі статусом ЧАСТКОВО,
        # поки адміністратор не встановить оновлення Windows.
        [switch]$Environmental,

        # Діагностика ДРУГОРЯДНОЇ (не основної) операції прогону —
        # телеметрія, звітність, фонова синхронізація стану. Такий запис
        # лишається видимим як WARNING, але НЕ інкрементує лічильник
        # попереджень, бо він не описує результат того, заради чого прогін
        # виконувався.
        #
        # Той самий механізм і та сама мотивація, що в $Environmental вище,
        # інша причина: там стан середовища, тут — побічний канал. Спільна
        # гілка нижче навмисно одна: політика "що рахується попередженням"
        # мусить лишатись в ОДНОМУ місці.
        #
        # Приклад, заради якого введено (review PR #225, P1): недоступність
        # Operations API під час post-backup Health робила
        # $logStatistics.Warnings > 0, і BRAVO_ARCHIV резолвив успішному
        # бекапу exit code 10 (SuccessWithWarnings, статус ЧАСТКОВО). Тобто
        # збій вторинної телеметрії змінював рапортований результат
        # ПЕРВИННОЇ операції, всупереч fail-soft інваріанту звітності.
        [switch]$Secondary
    )

    $severity = Get-BRAVOLogSeverityValue -Level $Level
    if ($severity -ge (Get-BRAVOLogSeverityValue -Level 'WARNING')) {
        if ($severity -ge (Get-BRAVOLogSeverityValue -Level 'ERROR')) {
            # $Environmental/$Secondary свідомо НЕ впливають на помилки:
            # прапорець знімає лише вагу попередження, а не приховує
            # справжню відмову.
            $script:BRAVOLogErrorCount++
        } elseif (-not $Environmental -and -not $Secondary) {
            $script:BRAVOLogWarningCount++
        }
    }

    $safeMessage = Protect-BRAVOLogSecret -Text $Message

    if ($script:BRAVOLogActive -and
        $severity -ge (Get-BRAVOLogSeverityValue -Level $script:BRAVOLogFileLevel)) {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        $line = '{0} [{1,-7}] [{2}] {3}' -f $timestamp, $Level, $Component, $safeMessage
        try {
            # UTF-8 із BOM — конвенція журналів проєкту ($logFileEncoding = "UTF8").
            # Без BOM Windows PowerShell 5.1, Notepad і частина засобів перегляду
            # читають файл як ANSI і показують кирилицю кракозябрами.
            # AppendAllText пише преамбулу лише під час створення файлу.
            [System.IO.File]::AppendAllText(
                $script:BRAVOLogFile,
                $line + [Environment]::NewLine,
                (New-Object System.Text.UTF8Encoding($true))
            )
        } catch {
            Write-Warning "Не вдалося записати журнал: $($_.Exception.Message)"
        }
    }

    $showInConsole = $severity -ge (Get-BRAVOLogSeverityValue -Level $script:BRAVOLogConsoleLevel)
    if ($Console) {
        $showInConsole = $true
    }
    if ($NoConsole) {
        $showInConsole = $false
    }
    if (-not $showInConsole) {
        return
    }

    if ($null -ne $script:BRAVOLogConsoleWriter) {
        # Помилка рендера консолі не має ховати сам запис: файл уже
        # записано вище, тому тут лишається дати оператору побачити текст
        # хоч у сирому вигляді.
        try {
            & $script:BRAVOLogConsoleWriter $safeMessage $Level
            return
        } catch {
            Write-Warning "Не вдалося відрендерити запис журналу в консоль: $($_.Exception.Message)"
        }
    }

    $color = if ($script:BRAVOLogColors.ContainsKey($Level)) {
        $script:BRAVOLogColors[$Level]
    } else {
        'White'
    }
    Write-Host $safeMessage -ForegroundColor $color
}

# Runtime викликає це один раз після імпорту BRAVO.Console. Виклик без
# -Writer повертає стандартний Write-Host — потрібно для допоміжних
# скриптів і машинних режимів, де операційної консолі немає.
function Set-BRAVOLogConsoleWriter {
    [CmdletBinding()]
    param([AllowNull()][scriptblock]$Writer)

    $script:BRAVOLogConsoleWriter = $Writer
}

function Write-BRAVOLogException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [string]$Component = 'GENERAL',

        [string]$Context
    )

    $header = if ([string]::IsNullOrWhiteSpace($Context)) {
        $ErrorRecord.Exception.Message
    } else {
        "${Context}: $($ErrorRecord.Exception.Message)"
    }
    # Саме повідомлення потрібне оператору, а stack trace — лише в журналі.
    Write-BRAVOLog -Message $header -Level 'ERROR' -Component $Component

    $details = New-Object System.Collections.Generic.List[string]
    $details.Add("Тип: $($ErrorRecord.Exception.GetType().FullName)")
    if ($null -ne $ErrorRecord.InvocationInfo) {
        $details.Add("Розташування: $($ErrorRecord.InvocationInfo.PositionMessage -replace "`r?`n", ' ')")
    }
    if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.ScriptStackTrace)) {
        $details.Add("Стек: $($ErrorRecord.ScriptStackTrace -replace "`r?`n", ' | ')")
    }
    foreach ($detail in $details) {
        Write-BRAVOLog -Message $detail -Level 'DEBUG' -Component $Component -NoConsole
    }
}

function Get-BRAVOLogStatistics {
    [CmdletBinding()]
    param()

    return New-Object PSObject -Property @{
        LogFile = $script:BRAVOLogFile
        Warnings = $script:BRAVOLogWarningCount
        Errors = $script:BRAVOLogErrorCount
        FileLevel = $script:BRAVOLogFileLevel
        ConsoleLevel = $script:BRAVOLogConsoleLevel
    }
}

function Complete-BRAVOLog {
    [CmdletBinding()]
    param()

    $statistics = Get-BRAVOLogStatistics
    $script:BRAVOLogActive = $false
    return $statistics
}

Export-ModuleMember -Function @(
    'Initialize-BRAVOLog',
    'Set-BRAVOLogConsoleWriter',
    'Write-BRAVOLog',
    'Write-BRAVOLogException',
    'Protect-BRAVOLogSecret',
    'New-BRAVOMaskedLogCopy',
    'Remove-BRAVOMaskedLogCopy',
    'Get-BRAVOLogStatistics',
    'Complete-BRAVOLog'
)
