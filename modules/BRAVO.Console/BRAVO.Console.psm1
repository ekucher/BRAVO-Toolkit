# Рендер операційної консолі BRAVO.
#
# Цей модуль відповідає лише за те, що бачить оператор: заголовок, етапи,
# короткі результати й фінальний підсумок. Він нічого не пише у журнал —
# цим займається BRAVO.Logging.
#
# Мінімальна підтримувана версія: Windows PowerShell 3.0.

# Set-StrictMode успадковується від конфігураційного завантажувача, тому весь
# стан модуля ініціалізується явно.
$script:BRAVOConsoleStepWidth = 58
$script:BRAVOConsoleStepOpen = $false
$script:BRAVOConsoleEnabled = $true

# Єдиний індикатор прогресу. Раніше паралельно малювались три Write-Progress
# (загальний, покомпонентний і 7-Zip), причому перші два дублювали один одного.
# Тут завжди один Id без ParentId, тому вкладених смуг не виникає.
$script:BRAVOProgressId = 1
$script:BRAVOProgressActivity = 'BRAVO'
$script:BRAVOProgressPhase = $null
$script:BRAVOProgressPercent = 0
$script:BRAVOProgressEnabled = $true

$script:BRAVOConsoleStatusColors = @{
    RUNNING = 'Cyan'
    OK      = 'Green'
    SKIPPED = 'DarkGray'
    WARNING = 'Yellow'
    ERROR   = 'Red'
}

function Initialize-BRAVOConsole {
    [CmdletBinding()]
    param(
        [ValidateRange(20, 200)]
        [int]$StepWidth = 58,

        [bool]$Enabled = $true
    )

    $script:BRAVOConsoleStepWidth = $StepWidth
    $script:BRAVOConsoleStepOpen = $false
    $script:BRAVOConsoleEnabled = $Enabled
}

function Initialize-BRAVOProgress {
    [CmdletBinding()]
    param(
        [string]$Activity = 'BRAVO',
        [bool]$Enabled = $true
    )

    $script:BRAVOProgressActivity = $Activity
    $script:BRAVOProgressEnabled = $Enabled
    $script:BRAVOProgressPhase = $null
    $script:BRAVOProgressPercent = 0
}

# Фаза — це великий етап скрипта. Вона лишається на смузі, поки конкретна
# операція (7-Zip, robocopy, WinSCP) не додасть до неї свій живий деталь.
function Write-BRAVOProgressPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Phase,
        [int]$PercentComplete = -1
    )

    $script:BRAVOProgressPhase = $Phase
    if ($PercentComplete -ge 0) {
        $script:BRAVOProgressPercent = [Math]::Max(0, [Math]::Min(100, $PercentComplete))
    }
    Write-BRAVOProgressDetail -Detail ''
}

function Write-BRAVOProgressDetail {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Detail)

    if (-not $script:BRAVOProgressEnabled) {
        return
    }

    $status = if ([string]::IsNullOrWhiteSpace($Detail)) {
        [string]$script:BRAVOProgressPhase
    } elseif ([string]::IsNullOrWhiteSpace($script:BRAVOProgressPhase)) {
        $Detail
    } else {
        "{0} — {1}" -f $script:BRAVOProgressPhase, $Detail
    }
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = ' '
    }

    Write-Progress `
        -Id $script:BRAVOProgressId `
        -Activity $script:BRAVOProgressActivity `
        -Status $status `
        -PercentComplete $script:BRAVOProgressPercent
}

function Complete-BRAVOProgress {
    [CmdletBinding()]
    param()

    if (-not $script:BRAVOProgressEnabled) {
        return
    }
    $script:BRAVOProgressPhase = $null
    Write-Progress -Id $script:BRAVOProgressId -Activity $script:BRAVOProgressActivity -Completed
}

function Format-BRAVOFileSize {
    [CmdletBinding()]
    param([AllowNull()][Nullable[long]]$Bytes)

    if ($null -eq $Bytes) {
        return 'немає даних'
    }
    if ($Bytes -ge 1TB) { return "$([math]::Round($Bytes / 1TB, 2)) ТБ" }
    if ($Bytes -ge 1GB) { return "$([math]::Round($Bytes / 1GB, 2)) ГБ" }
    if ($Bytes -ge 1MB) { return "$([math]::Round($Bytes / 1MB, 2)) МБ" }
    if ($Bytes -ge 1KB) { return "$([math]::Round($Bytes / 1KB, 2)) КБ" }
    return "$Bytes Б"
}

# У класичному хості PowerShell Write-Progress малюється поверх верхніх
# рядків вікна й повертає їх лише на -Completed. Через це заголовок і перші
# етапи були невидимі протягом усього запуску — саме тоді, коли оператор
# дивиться на екран. Порожні рядки перед заголовком зсувають вміст під
# смугу, тому нічого не перекривається.
$script:BRAVOConsoleProgressReservedLines = 6

# Ширина ASCII-роздільників header/result block — той самий контракт для
# усіх operator-facing скриптів (docs/OPERATOR_CONSOLE_UX.md, спільний каркас).
$script:BRAVOConsoleSeparatorWidth = 60

function Write-BRAVOHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [string]$Institution,

        [string]$InstitutionCode,

        # За контрактом (docs/OPERATOR_CONSOLE_UX.md §1) заголовок завжди
        # показує hostname — оператор, що дивиться на кілька відкритих
        # консолей різних серверів, інакше не відрізнить їх на перший погляд.
        [string]$ComputerName = $env:COMPUTERNAME,

        # Режим запуску (MANUAL/SCHEDULED/READ-ONLY/... — довільний текст,
        # кожен entrypoint визначає свій набір значень).
        [string]$Mode,

        # Час старту більше НЕ рендериться в заголовку (докладний Початок/
        # Завершення/Тривалість — лише у фінальному РЕЗУЛЬТАТ, щоб не
        # дублювати ту саму інформацію двічі). Параметр лишається заради
        # сумісності викликів, які ще передають -StartedAt.
        [datetime]$StartedAt = (Get-Date),

        # Вбудований виклик (Health усередині кроку Archive) не повинен
        # друкувати повний заголовок ІНШОЇ "програми" — оператор бачить
        # два незалежні на вигляд титульні блоки поспіль, хоча це один
        # прогін. Резервування порожніх рядків під прогрес-бар тут НЕ
        # потрібне: воно захищало саме текст заголовка (Title/Установа/
        # Початок) від накладання прогрес-бару — немає тексту, немає що
        # захищати. Реальний випадок: фіксований блок порожніх рядків
        # лишався видимим розривом між кроками Archive навіть тоді, коли
        # Health не знайшла жодної проблеми для показу.
        [switch]$SuppressText
    )

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }

    if ($SuppressText) {
        return
    }

    if ($script:BRAVOProgressEnabled) {
        for ($i = 0; $i -lt $script:BRAVOConsoleProgressReservedLines; $i++) {
            Write-Host ''
        }
    }

    $separator = '=' * $script:BRAVOConsoleSeparatorWidth
    Write-Host ''
    Write-Host $separator -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($Institution)) {
        $institutionLine = if ([string]::IsNullOrWhiteSpace($InstitutionCode)) {
            " $Institution"
        } else {
            " $Institution [$InstitutionCode]"
        }
        Write-Host $institutionLine
    }
    if (-not [string]::IsNullOrWhiteSpace($ComputerName)) {
        Write-Host " $ComputerName"
    }
    if (-not [string]::IsNullOrWhiteSpace($Mode)) {
        Write-Host " Режим: $Mode"
    }
    Write-Host $separator -ForegroundColor Cyan
    Write-Host ''
}

function Get-BRAVOStepPrefixText {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Name
    )

    $prefix = '[{0}/{1}]' -f $Current, $Total
    return "$prefix $Name"
}

function Write-BRAVOStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Current,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }

    $baseText = Get-BRAVOStepPrefixText -Current $Current -Total $Total -Name $Name
    $dots = '.' * [math]::Max(1, $script:BRAVOConsoleStepWidth - $baseText.Length)
    Write-Host "$baseText$dots " -NoNewline
    $script:BRAVOConsoleStepOpen = $true
}

# Коротка тривалість mm:ss, довга (від години) HH:mm:ss — той самий поріг,
# що docs/MANUAL_RUN_CONSOLE_UX.md задає для рядка етапу й для підсумку.
function Format-BRAVODuration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][timespan]$Duration)

    if ($Duration.TotalHours -ge 1) {
        return '{0:00}:{1:mm}:{1:ss}' -f [int][math]::Floor($Duration.TotalHours), $Duration
    }
    return '{0:mm}:{0:ss}' -f $Duration
}

# Ширина, до якої лівим краєм доповнюється текст статусу перед тривалістю —
# "OK"/"WARNING"/"ERROR"/"PASS"/"SKIPPED" усі вирівнюються по одній колонці
# (docs/MANUAL_RUN_CONSOLE_UX.md: "OK       09:41", "ERROR    00:07").
$script:BRAVOConsoleStatusFieldWidth = 9

function Write-BRAVOStepResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Current,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Name,

        [ValidateSet('RUNNING', 'OK', 'SKIPPED', 'WARNING', 'ERROR', 'PASS', 'FAIL')]
        [string]$Status = 'OK',

        # Сумісність зі старими викликами: короткий текст одразу за статусом
        # на тому самому рядку. Нові виклики, що дотримуються повного
        # контракту (docs/MANUAL_RUN_CONSOLE_UX.md), використовують окремо
        # -Duration тут і Write-BRAVOOperatorReason під рядком етапу —
        # -Details і -Duration навмисно взаємовиключні (Details лишається
        # для короткого inline-випадку на кшталт "SKIPPED  усі вже існують").
        [string]$Details,

        [Nullable[timespan]]$Duration
    )

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }

    # Якщо рядок етапу вже відкрито через Write-BRAVOStep, дописуємо лише
    # статус, щоб етап займав рівно один рядок консолі.
    if (-not $script:BRAVOConsoleStepOpen) {
        $baseText = Get-BRAVOStepPrefixText -Current $Current -Total $Total -Name $Name
        $dots = '.' * [math]::Max(1, $script:BRAVOConsoleStepWidth - $baseText.Length)
        Write-Host "$baseText$dots " -NoNewline
    }
    $script:BRAVOConsoleStepOpen = $false

    $statusColor = if ($script:BRAVOConsoleStatusColors.ContainsKey($Status)) {
        $script:BRAVOConsoleStatusColors[$Status]
    } else {
        'White'
    }
    if ($null -ne $Duration) {
        # PowerShell розгортає Nullable[timespan] у звичайний [timespan]
        # одразу після успішного біндингу параметра — $Duration тут це вже
        # НЕ обгортка Nullable, а сам TimeSpan (.Value кинув би помилку
        # прив'язки аргументу в Format-BRAVODuration нижче).
        $durationText = Format-BRAVODuration -Duration $Duration
        $paddedStatus = $Status.PadRight($script:BRAVOConsoleStatusFieldWidth)
        Write-Host $paddedStatus -ForegroundColor $statusColor -NoNewline
        Write-Host $durationText
    } elseif ([string]::IsNullOrWhiteSpace($Details)) {
        Write-Host $Status -ForegroundColor $statusColor
    } else {
        Write-Host $Status -ForegroundColor $statusColor -NoNewline
        Write-Host "  $Details" -ForegroundColor DarkGray
    }
}

# Причина/деталі під рядком етапу (docs/MANUAL_RUN_CONSOLE_UX.md):
#   Причина: коротка операторська причина WARNING/ERROR
#   Деталі:  необов'язковий короткий safe-текст, ніколи не stack trace
# Обидва підписи вирівняні до однієї ширини, щоб текст після них починався
# з однієї колонки незалежно від того, показано "Деталі" чи ні.
function Write-BRAVOOperatorReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$Details,
        [ConsoleColor]$Color = [ConsoleColor]::DarkGray
    )

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }
    Write-BRAVOConsoleDetail -Message ("Причина: {0}" -f $Reason) -Color $Color
    if (-not [string]::IsNullOrWhiteSpace($Details)) {
        Write-BRAVOConsoleDetail -Message ("Деталі:  {0}" -f $Details) -Color $Color
    }
}

# Пояснення для SKIPPED-етапу: окремий рядок без "Причина:"-підпису, з
# порожнім рядком перед ним (docs/MANUAL_RUN_CONSOLE_UX.md, приклад SKIPPED
# — на відміну від WARNING/ERROR, де "Причина:" йде одразу без відступу).
function Write-BRAVOSkipReason {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reason)

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }
    Write-Host ''
    Write-BRAVOConsoleDetail -Message $Reason
}

function Write-BRAVOConsoleDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::DarkGray
    )

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }
    if ($script:BRAVOConsoleStepOpen) {
        Write-Host ''
        $script:BRAVOConsoleStepOpen = $false
    }
    Write-Host ("      " + $Message) -ForegroundColor $Color
}

# Рівні журналу мають ті самі кольори, що й статуси етапів: оператор не має
# вчитуватись у префікс, щоб зрозуміти, що сталося. Ключі збігаються з
# рівнями BRAVO.Logging, тому маплення один-в-один без перекладу.
$script:BRAVOConsoleLevelColors = @{
    TRACE   = 'DarkGray'
    DEBUG   = 'DarkGray'
    INFO    = 'Gray'
    SUCCESS = 'Green'
    WARNING = 'Yellow'
    ERROR   = 'Red'
    FATAL   = 'Red'
}

# Єдина точка, через яку в консоль потрапляє повідомлення журналу. Головне,
# що вона робить понад вибір кольору — закриває відкритий рядок етапу, інакше
# WARNING із бізнес-логіки дописався б у хвіст "[3/7] BLOG........." і зламав
# би розмітку саме тоді, коли щось пішло не так.
function Write-BRAVOConsoleMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,

        [ValidateSet('TRACE', 'DEBUG', 'INFO', 'SUCCESS', 'WARNING', 'ERROR', 'FATAL')]
        [string]$Level = 'INFO'
    )

    $color = if ($script:BRAVOConsoleLevelColors.ContainsKey($Level)) {
        [ConsoleColor]$script:BRAVOConsoleLevelColors[$Level]
    } else {
        [ConsoleColor]::Gray
    }
    Write-BRAVOConsoleDetail -Message $Message -Color $color
}

function Write-BRAVOWarning {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-BRAVOConsoleDetail -Message $Message -Color ([ConsoleColor]::Yellow)
}

function Write-BRAVOError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$SeeLog
    )

    Write-BRAVOConsoleDetail -Message $Message -Color ([ConsoleColor]::Red)
    if ($SeeLog) {
        Write-BRAVOConsoleDetail -Message 'Деталі записано у журнал.'
    }
}

function Write-BRAVOSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('УСПІШНО', 'ЧАСТКОВО', 'ПОМИЛКА')]
        [string]$Result,

        [timespan]$Duration,

        # Впорядкований перелік підсумкових показників у форматі "Назва" = "Значення".
        [System.Collections.IDictionary]$Metrics,

        [string]$LogFile
    )

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }
    if ($script:BRAVOConsoleStepOpen) {
        Write-Host ''
        $script:BRAVOConsoleStepOpen = $false
    }

    $resultColor = switch ($Result) {
        'УСПІШНО'  { 'Green' }
        'ЧАСТКОВО' { 'Yellow' }
        default    { 'Red' }
    }

    Write-Host ''
    Write-Host 'Результат: ' -NoNewline
    Write-Host $Result -ForegroundColor $resultColor
    if ($PSBoundParameters.ContainsKey('Duration')) {
        Write-Host ("Тривалість: {0:hh\:mm\:ss}" -f $Duration)
    }
    if ($null -ne $Metrics) {
        foreach ($key in $Metrics.Keys) {
            Write-Host ("{0}: {1}" -f $key, $Metrics[$key])
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        Write-Host ''
        Write-Host 'Детальний журнал:'
        Write-Host $LogFile -ForegroundColor DarkGray
    }
    Write-Host ''
}

# Ширина поля підпису в блоці РЕЗУЛЬТАТ ("Статус:", "Код завершення:",
# "Код інструменту:" — усі вирівнюються по одній колонці значення).
$script:BRAVOResultLabelWidth = 18

# Один рядок "Підпис: значення" у блоці РЕЗУЛЬТАТ — та сама колонка
# вирівнювання, що й спільні поля Write-BRAVOResultHeader (Статус/Код
# завершення/Причина/Інструмент), щоб домен-специфічні поля (Початок/
# Завершення/Тривалість, Створено архівів, Перевірок тощо) не "спливали".
function Write-BRAVOResultField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowEmptyString()][string]$Value
    )

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }
    $paddedLabel = ("{0}:" -f $Label).PadRight($script:BRAVOResultLabelWidth)
    Write-Host ("{0}{1}" -f $paddedLabel, $Value)
}

# Відкриває фінальний блок РЕЗУЛЬТАТ: роздільники, Статус (кольоровий,
# домен сам вирішує колір — словник статусів надто різний між Archive
# ("УСПІШНО"), Restore Test ("PASS: 3"), Dry Run ("ГОТОВО ДО ЗАПУСКУ") тощо,
# щоб тримати єдиний lookup тут) і спільні для будь-якого failure поля:
# Код завершення (BRAVO.ExitCodes, ніколи не native tool code), Причина,
# Інструмент/Код інструменту — лише коли головний результат дійсно
# спричинений зовнішнім tool (docs/MANUAL_RUN_CONSOLE_UX.md).
# Домен-специфічні поля (Початок/Завершення/Тривалість, Створено архівів,
# Перевірок тощо) додаються окремими викликами Write-BRAVOResultField ПІСЛЯ
# цього виклику, до Write-BRAVOResultFooter.
function Write-BRAVOResultHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [ConsoleColor]$StatusColor = [ConsoleColor]::White,

        # BRAVO exit code (BRAVO.ExitCodes) — ніколи native tool code.
        [Nullable[int]]$ExitCode,
        [string]$ExitCodeName,

        [string]$Reason,
        [string]$Tool,

        # Уже сформований текст "N — опис" (Get-BRAVOToolExitCodeDescription)
        # — сама функція нічого не знає про конкретні tools.
        [string]$ToolExitCode
    )

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }
    if ($script:BRAVOConsoleStepOpen) {
        Write-Host ''
        $script:BRAVOConsoleStepOpen = $false
    }

    $separator = '-' * $script:BRAVOConsoleSeparatorWidth
    Write-Host ''
    Write-Host $separator
    Write-Host ' РЕЗУЛЬТАТ'
    Write-Host $separator
    Write-Host (("{0}:" -f 'Статус').PadRight($script:BRAVOResultLabelWidth)) -NoNewline
    Write-Host $Status -ForegroundColor $StatusColor

    if ($null -ne $ExitCode) {
        $exitText = if ([string]::IsNullOrWhiteSpace($ExitCodeName)) {
            [string]$ExitCode
        } else {
            "{0} — {1}" -f $ExitCode, $ExitCodeName
        }
        Write-BRAVOResultField -Label 'Код завершення' -Value $exitText
    }
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        Write-BRAVOResultField -Label 'Причина' -Value $Reason
    }
    if (-not [string]::IsNullOrWhiteSpace($Tool)) {
        Write-BRAVOResultField -Label 'Інструмент' -Value $Tool
    }
    if (-not [string]::IsNullOrWhiteSpace($ToolExitCode)) {
        Write-BRAVOResultField -Label 'Код інструменту' -Value $ToolExitCode
    }
    Write-Host ''
}

# Порожній рядок усередині блоку РЕЗУЛЬТАТ (наприклад, між основними
# полями і Перевірок/Успішно/Попереджень/Помилок) — для доменів, які самі
# не мають права на голий Write-Host (Health: Console/HealthRendersNoRawWriteHost).
function Write-BRAVOResultBlankLine {
    [CmdletBinding()]
    param()

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }
    Write-Host ''
}

# Заголовок довільної секції всередині блоку РЕЗУЛЬТАТ ("Архіви:",
# "Резервні копії:", "Проблеми:") — сам вміст секції домен формує
# самостійно (Write-Host/Write-BRAVOResultField), бо структура списку
# надто різна між скриптами, щоб узагальнювати в один helper.
function Write-BRAVOResultSection {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Title)

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }
    Write-Host ''
    Write-Host ("{0}:" -f $Title)
}

# Закриває блок РЕЗУЛЬТАТ: нижній роздільник, опційно шлях до журналу.
function Write-BRAVOResultFooter {
    [CmdletBinding()]
    param([string]$LogFile)

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        Write-Host ''
        Write-Host 'Детальний журнал:'
        Write-Host $LogFile -ForegroundColor DarkGray
    }
    Write-Host ('-' * $script:BRAVOConsoleSeparatorWidth)
    Write-Host ''
}

# Пауза перед закриттям вікна консолі при ручному запуску — інакше вікно,
# відкрите подвійним кліком чи ярликом, зникає разом з помилкою, щойно
# скрипт завершується, і оператор нічого не встигає прочитати.
#
# Ніколи не повинна спрацювати під час запланованого завдання: це
# зупинило б нічне резервне копіювання назавжди, без жодного індикатора
# для моніторингу. Тому перевірки нижче навмисно асиметрично обережні —
# за замовчуванням НЕ чекати, щойно з'являється хоч найменший сумнів:
#   1. -NoPause — явний сигнал від Планувальника (BRAVO_TASKS_INSTALL.ps1
#      додає його до кожного запланованого завдання) і від самотесту.
#      Найнадійніший сигнал, бо не залежить від жодної евристики.
#   2. consoleSettings.PauseOnExit — ручне вимкнення в BRAVO.config.
#   3. [Environment]::UserInteractive — false в сесії 0 (SYSTEM-завдання
#      "Run whether user is logged on or not").
#   4. [Console]::IsInputRedirected — true, коли stdin перенаправлено
#      (CI, автоматизація, дочірній процес самотесту).
# Кожна з трьох останніх перевірок обгорнута в try/catch: будь-яка
# помилка під час перевірки веде до пропуску паузи, а не до її форсування.
function Wait-BRAVOManualExit {
    [CmdletBinding()]
    param([switch]$NoPause)

    if ($NoPause) {
        return
    }

    $pauseOnExit = $true
    $prompt = "Натиснiть будь-яку клавiшу для закриття вiкна..."
    try {
        # $global:consoleSettings може бути ще не завантажений (рання
        # помилка до Import-BravoConfiguration) — Set-StrictMode тоді
        # кидає помилку на самому зверненні до змінної; catch нижче
        # лишає безпечні дефолти (чекати, стандартний текст).
        if ($global:consoleSettings.Contains('PauseOnExit')) {
            $pauseOnExit = [bool]$global:consoleSettings.PauseOnExit
        }
        if ($global:consoleSettings.Contains('PausePrompt') -and
            -not [string]::IsNullOrWhiteSpace([string]$global:consoleSettings.PausePrompt)) {
            $prompt = [string]$global:consoleSettings.PausePrompt
        }
    } catch {
        # Конфігурація недоступна — дефолти вище лишаються чинними.
    }

    if (-not $pauseOnExit) {
        return
    }

    try {
        if (-not [Environment]::UserInteractive) {
            return
        }
        if ([Console]::IsInputRedirected) {
            return
        }
    } catch {
        # Немає доступу до консолі взагалі (нетиповий хост) — не блокуємо.
        return
    }

    Write-Host ""
    Write-Host $prompt -ForegroundColor Cyan
    try {
        # RawUI.ReadKey не підтримується у Windows PowerShell ISE — там
        # немає справжнього дескриптора консолі, і виклик кидає виняток.
        [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        try {
            [void](Read-Host)
        } catch {
            # Фоновий/нетиповий хост без можливості почекати на клавішу —
            # це не привід завершити скрипт помилкою.
        }
    }
}

Export-ModuleMember -Function @(
    'Initialize-BRAVOConsole',
    'Initialize-BRAVOProgress',
    'Write-BRAVOProgressPhase',
    'Write-BRAVOProgressDetail',
    'Complete-BRAVOProgress',
    'Format-BRAVOFileSize',
    'Format-BRAVODuration',
    'Write-BRAVOHeader',
    'Write-BRAVOStep',
    'Write-BRAVOStepResult',
    'Write-BRAVOOperatorReason',
    'Write-BRAVOSkipReason',
    'Write-BRAVOConsoleDetail',
    'Write-BRAVOConsoleMessage',
    'Write-BRAVOWarning',
    'Write-BRAVOError',
    'Write-BRAVOSummary',
    'Write-BRAVOResultField',
    'Write-BRAVOResultBlankLine',
    'Write-BRAVOResultHeader',
    'Write-BRAVOResultSection',
    'Write-BRAVOResultFooter',
    'Wait-BRAVOManualExit'
)
