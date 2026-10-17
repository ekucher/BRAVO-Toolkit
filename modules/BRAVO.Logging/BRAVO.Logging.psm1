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
        [AllowNull()][AllowEmptyCollection()][string[]]$KnownSecret,

        # Значення в лапках переходить через розрив рядка (див. нижче) — для
        # недовіреного виводу інструмента цілим текстом, а не для журналу.
        [switch]$QuotedValueSpansLines,

        # Межа кількості діапазонів маскування (#463; 0 — без межі). Кожен
        # збіг — діапазон у пам'яті й у сортуванні, тож для недовіреного
        # виводу з мільйонами коротких збігів (` -px` поспіль) ціна росте з
        # їх кількістю. Понад межу — System.OverflowException ДО сортування
        # і без частково замаскованого результату; Protect-BRAVOLogSecretBounded
        # перетворює її на Omitted (fail-closed).
        [ValidateRange(0, 2147483647)][int]$MaximumMaskedSpans = 0
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $sanitized = $Text
    # ЄДИНА модель заміни: збіги і відомих значень, і шаблонів шукаються в
    # ОРИГІНАЛЬНОМУ тексті, перекриті й суміжні діапазони зливаються, і
    # кожен злитий діапазон замінюється одним ***. Послідовна заміна
    # лишала б фрагмент, бо перша заміна руйнує контекст для наступної:
    # - між відомими секретами — для частково перекритих (кінець одного —
    #   початок іншого) перша заміна руйнує збіг другого;
    # - між відомим секретом і шаблоном — короткий відомий секрет, що
    #   збігається із синтаксисом значення (пароль `'`), перетворив би
    #   `token='AAA LEAK'` на `token=***AAA LEAK***`, і шаблон уже не
    #   впізнав би лапковане значення, лишивши `LEAK`;
    # - у зворотному порядку (шаблони першими) — `password=my secret` із
    #   відомим `my secret` дав би `password=*** secret`, і відоме значення
    #   вже не знайшлося б цілим.
    $spanStarts = New-Object 'System.Collections.Generic.List[int]'
    $spanEnds = New-Object 'System.Collections.Generic.List[int]'
    $spanLimitMessage = "Protect-BRAVOLogSecret: понад $MaximumMaskedSpans діапазонів маскування"
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
        # #417 (пункт 4b): секрет може потрапити в текст не лише сирим, а й
        # закодованим — URL-кодованим ([Uri]::EscapeDataString, тією самою
        # функцією, що й New-BRAVOSftpUrl) чи JSON-екранованим (тіло рядка
        # ConvertTo-Json без лапок). Такі форми маскуються як додаткові
        # варіанти, лише коли відрізняються від сирого значення: секрет без
        # спецсимволів дає рівно ті самі варіанти, що й до #417. JSON-форма
        # будується детерміновано, а не через ConvertTo-Json, бо хости
        # екранують по-різному: обидва варіанти екранують " \ і керівні
        # символи (\b \f \n \r \t, решта < 0x20 — \u з 4 hex у нижньому
        # регістрі), а також U+0085, U+2028 і U+2029 (#435). Строгий
        # варіант (PowerShell 7, Newtonsoft.Json) іншого не екранує,
        # HTML-безпечний (Windows PowerShell 5.1, JavaScriptSerializer ->
        # HttpEncoder.JavaScriptStringEncode) додатково екранує & ' < >;
        # тому маскуються обидві форми. Base64 свідомо
        # не додається: його підрядки залежать від вирівнювання і не
        # впізнаються надійно. Виняток кодування не перехоплюється — він
        # іде до викликача (New-BRAVOMaskedLogCopy -> нічого не
        # вивантажується, fail-closed).
        $rawSecretVariants = $secretVariants.ToArray()
        foreach ($rawSecretVariant in $rawSecretVariants) {
            $encodedSecretVariants = New-Object 'System.Collections.Generic.List[string]'
            $encodedSecretVariants.Add([System.Uri]::EscapeDataString($rawSecretVariant))
            foreach ($jsonEscapeHtmlChars in @($false, $true)) {
                $jsonBuilder = New-Object System.Text.StringBuilder
                foreach ($secretChar in $rawSecretVariant.ToCharArray()) {
                    $secretCharCode = [int]$secretChar
                    if ($secretCharCode -eq 34) { [void]$jsonBuilder.Append('\"') }
                    elseif ($secretCharCode -eq 92) { [void]$jsonBuilder.Append('\\') }
                    elseif ($secretCharCode -eq 8) { [void]$jsonBuilder.Append('\b') }
                    elseif ($secretCharCode -eq 12) { [void]$jsonBuilder.Append('\f') }
                    elseif ($secretCharCode -eq 10) { [void]$jsonBuilder.Append('\n') }
                    elseif ($secretCharCode -eq 13) { [void]$jsonBuilder.Append('\r') }
                    elseif ($secretCharCode -eq 9) { [void]$jsonBuilder.Append('\t') }
                    elseif ($secretCharCode -lt 32 -or
                        $secretCharCode -eq 0x0085 -or $secretCharCode -eq 0x2028 -or $secretCharCode -eq 0x2029 -or
                        ($jsonEscapeHtmlChars -and ($secretCharCode -eq 38 -or $secretCharCode -eq 39 -or $secretCharCode -eq 60 -or $secretCharCode -eq 62))) {
                        [void]$jsonBuilder.Append([string][char]92 + 'u' + $secretCharCode.ToString('x4'))
                    } else { [void]$jsonBuilder.Append($secretChar) }
                }
                $encodedSecretVariants.Add($jsonBuilder.ToString())
            }
            foreach ($encodedSecretVariant in $encodedSecretVariants) {
                if (-not [string]::Equals($encodedSecretVariant, $rawSecretVariant, [System.StringComparison]::Ordinal) -and
                    -not $secretVariants.Contains($encodedSecretVariant)) {
                    $secretVariants.Add($encodedSecretVariant)
                }
            }
        }
        # IndexOf(..., Ordinal) — без культури і без regex-семантики:
        # спецсимволи в секреті не інтерпретуються.
        foreach ($secretVariant in $secretVariants) {
            $matchIndex = $sanitized.IndexOf([string]$secretVariant, 0, [System.StringComparison]::Ordinal)
            while ($matchIndex -ge 0) {
                $spanStarts.Add($matchIndex)
                $spanEnds.Add($matchIndex + $secretVariant.Length)
                if ($MaximumMaskedSpans -gt 0 -and $spanStarts.Count -gt $MaximumMaskedSpans) {
                    throw (New-Object System.OverflowException $spanLimitMessage)
                }
                $matchIndex = $sanitized.IndexOf([string]$secretVariant, $matchIndex + 1, [System.StringComparison]::Ordinal)
            }
        }
    }
    # Шаблони: група `v` — значення, яке маскується; контекст перед нею
    # (ключ, схема URL) лишається видимим.
    # Облікові дані всередині URL: sftp://user:password@host -> sftp://user:***@host
    # Значення шаблонів нижче: у подвійних лапках, в ОДИНАРНИХ лапках (інакше
    # `token='AAA LEAK'` маскувалось би лише до першого пробілу й лишало
    # `token=*** LEAK'`) або без лапок до пробілу. Екранована лапка всередині
    # значення — не кінець значення, в усіх поширених формах: подвоєна
    # ('' / "", PowerShell, CSV), зі зворотним слешем (\" / \', C-подібні
    # мови, JSON) і з бектіком (`" — рідне екранування PowerShell). Інакше
    # `token='AAA'' LEAK'` чи `token="AAA\" LEAK"` давали б
    # `token=***' LEAK'` / `token=*** LEAK"`. Символ екранування (\ або `)
    # поглинає наступний символ (будь-який, крім розриву рядка), тож
    # неоднозначний випадок (`'C:\dir\' tail`) маскує БІЛЬШЕ — до кінця
    # рядка, — а не менше. Альтернативи `[^"\\`]`, `[\\`].` і `""`
    # починаються з різних символів і не перетинаються, а завершення
    # (лапка, розрив рядка чи кінець тексту) досяжне завжди, тож шаблон
    # лінійний і без відкату.
    # Значення в лапках не перетинає розрив рядка: New-BRAVOMaskedLogCopy
    # маскує журнал ЦІЛИМ текстом, і лапка без пари в одному записі інакше
    # «з'їла» б усі записи до наступної лапки. Незакрита в межах рядка лапка
    # (обрізаний чи сформований текст) маскує решту рядка: інакше
    # `token='AAA LEAK` втратив би лише `'AAA`.
    # Значення без лапок закінчується на пробільному символі, але те саме
    # правило екранування діє і тут: \ чи ` поглинає наступний символ,
    # включно з пробілом. Інакше password=my, бектік, пробіл, secret
    # (екранований пробіл PowerShell) з відомим секретом `my secret`
    # маскувався б лише до пробілу й лишав `password=*** secret`.
    # -QuotedValueSpansLines (#463) — для виводу зовнішнього інструмента,
    # де логічний рядок може бути перенесений (`-password="AA`, розрив,
    # `SECRET"`): там значення в лапках переходить через розрив рядка, а
    # незакрита лапка маскує решту тексту. Поза лапками значення так само
    # закінчується на пробільному символі. Викликач маскує такий вивід
    # ЦІЛИМ, до будь-яких зрізів по рядках.
    # (Тут сам regex — у одинарно-лапкованому PowerShell-літералі, тому
    # кожна його одинарна лапка записана подвоєною.)
    # #453 (CPR-453-2): \S* одразу за ЗНАЙДЕНОЮ закриваючою лапкою (не в
    # гілках розриву рядка/кінця тексту) — інакше текст, приклеєний за нею
    # без пробілу (password='abc'def), лишався б незамаскованим хвостом; той
    # самий клас дефекту для обох типів лапок і для обох режимів нижче.
    if ($QuotedValueSpansLines) {
        $quotedSecretValue = '(?:"(?:[^"\\`]|[\\`][\s\S]?|"")*(?:"\S*|\z)|''(?:[^''\\`]|[\\`][\s\S]?|'''')*(?:''\S*|\z)|(?:[^\s\\`]|[\\`][^\r\n]?)+)'
    } else {
        $quotedSecretValue = '(?:"(?:[^"\\`\r\n]|[\\`][^\r\n]?|"")*(?:"\S*|(?=[\r\n])|\z)|''(?:[^''\\`\r\n]|[\\`][^\r\n]?|'''')*(?:''\S*|(?=[\r\n])|\z)|(?:[^\s\\`]|[\\`][^\r\n]?)+)'
    }
    $secretPatterns = @(
        # Логін може бути порожнім (`sftp://:password@host`, #463) — пароль
        # маскується і тоді. Схема — ЦІЛИЙ ланцюжок `[a-z0-9+.-]` від його
        # початку, атомарно (#463; та сама вимога лінійності, що й у #453):
        # спроба лише з початку ланцюжка і без повернення, тож робота
        # лінійна. Колишня форма `[a-z][a-z0-9+.-]*` пробувала з КОЖНОГО
        # символу довгого ланцюжка (тисячі імен файлів по 255 символів у
        # виводі синхронізації — десятки секунд). Цілий ланцюжок охоплює
        # будь-який колишній збіг, тож маскується не менше.
        '(?i)(?<![a-z0-9+.\-])(?>[a-z0-9+.\-]+)://[^:/\s@]*:(?<v>[^@\s]+)@',
        # Явні параметри пароля у командних рядках WinSCP і 7-Zip.
        ('(?i)-password=(?<v>' + $quotedSecretValue + ')'),
        # (?!ath|assword) — коротка форма -p, але не -path і не -password=
        # (той має власний шаблон вище).
        ('(?i)\s-p(?!ath|assword)(?<v>' + $quotedSecretValue + ')'),
        ('(?i)(?:password|passwd|secret|token)\s*[:=]\s*(?<v>' + $quotedSecretValue + ')'),
        # Webhook URL — сам bearer-секрет, без user:pass@; підтримувані провайдери
        # (Send-BRAVOWebhookNotification -Provider slack|discord) мають токен
        # прямо у шляху, а не в окремому параметрі.
        '(?i)hooks\.slack\.com/services/(?<v>\S+)',
        '(?i)discord(?:app)?\.com/api/webhooks/(?<v>\S+)'
    )
    # Збіги перебираються по одному (Match/NextMatch), а не колекцією
    # Matches: у пам'яті лишаються лише межі діапазонів.
    foreach ($secretPattern in $secretPatterns) {
        $patternMatch = [regex]::Match($sanitized, $secretPattern)
        while ($patternMatch.Success) {
            $valueGroup = $patternMatch.Groups['v']
            if ($valueGroup.Success -and $valueGroup.Length -gt 0) {
                $spanStarts.Add($valueGroup.Index)
                $spanEnds.Add($valueGroup.Index + $valueGroup.Length)
                if ($MaximumMaskedSpans -gt 0 -and $spanStarts.Count -gt $MaximumMaskedSpans) {
                    throw (New-Object System.OverflowException $spanLimitMessage)
                }
            }
            $patternMatch = $patternMatch.NextMatch()
        }
    }
    if ($spanStarts.Count -gt 0) {
        [int[]]$orderedStarts = $spanStarts.ToArray()
        [int[]]$orderedEnds = $spanEnds.ToArray()
        [Array]::Sort($orderedStarts, $orderedEnds)
        $maskedBuilder = New-Object System.Text.StringBuilder
        $copiedUpTo = 0
        $spanIndex = 0
        while ($spanIndex -lt $orderedStarts.Length) {
            $mergedStart = $orderedStarts[$spanIndex]
            $mergedEnd = $orderedEnds[$spanIndex]
            $spanIndex++
            while ($spanIndex -lt $orderedStarts.Length -and $orderedStarts[$spanIndex] -le $mergedEnd) {
                if ($orderedEnds[$spanIndex] -gt $mergedEnd) { $mergedEnd = $orderedEnds[$spanIndex] }
                $spanIndex++
            }
            [void]$maskedBuilder.Append($sanitized, $copiedUpTo, $mergedStart - $copiedUpTo)
            [void]$maskedBuilder.Append('***')
            $copiedUpTo = $mergedEnd
        }
        [void]$maskedBuilder.Append($sanitized, $copiedUpTo, $sanitized.Length - $copiedUpTo)
        $sanitized = $maskedBuilder.ToString()
    }
    return $sanitized
}

function Protect-BRAVOLogSecretBounded {
    # Protect-BRAVOLogSecret для недовіреного виводу зовнішніх інструментів
    # (7-Zip, WinSCP.com) — з межами вартості. Маскується ПОВНИЙ переданий
    # текст, без власних зрізів: межа, проведена по ще не замаскованому
    # тексту, може розрізати секрет, і уламок маскувальник уже не впізнав би.
    #
    # Ціна маскування повного тексту обмежується двома межами, інакше
    # обробка збою могла б зависнути саме тоді, коли діагностика потрібна:
    # - загальна довжина (-MaximumMaskedCharacters): діапазон на кожен збіг
    #   відомого значення й копії тексту на кожен шаблон;
    # - довжина суцільного ланцюжка символів схеми URL `[a-z0-9+.-]`
    #   (-MaximumTokenCharacters): колишня форма шаблону облікових даних в
    #   URL (`[a-z][a-z0-9+.-]*://…`) поводилась квадратично саме на
    #   такому ланцюжку (виміряно: 10 тис. символів — ~2 с, 30 тис. —
    #   ~17 с); схема тепер атомарна й лінійна (#463), межа лишається як
    #   запобіжник. Будь-який інший символ (`\`, `_`, пробіл,
    #   лапки) ланцюжок розриває, тож звичайні шляхи й вивід 7-Zip (короткі
    #   імена записів) обидві межі не досягають;
    # - довжина суцільного фрагмента без пробільних символів, що містить
    #   `://` (-MaximumUrlRunCharacters): той самий шаблон після `://…:`
    #   сканує `[^@\s]+` до кінця фрагмента на КОЖНОМУ входженні, тож текст
    #   на кшталт `a://b:a://b:…` без `@` квадратичний навіть із короткими
    #   ланцюжками схеми (виміряно: ~200 тис. символів одним фрагментом —
    #   ~150 с). Шаблон не перетинає пробільних символів, тож межа на
    #   фрагмент обмежує роботу лінійно від загальної довжини;
    # - кількість діапазонів маскування (-MaximumMaskedSpans, #463): кожен
    #   збіг — діапазон у пам'яті й у сортуванні, тож мільйони коротких
    #   збігів (` -px` поспіль у сформованому виводі) коштували б секунди
    #   й сотні МБ навіть у межах загальної довжини.
    # Текст понад будь-яку межу НЕ маскується і НЕ пишеться (fail-closed):
    # викликач отримує Omitted і записує лише позначку з довжиною.
    #
    # Повертає [pscustomobject]@{ Text; Omitted; Length }.
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [AllowNull()][AllowEmptyCollection()][string[]]$KnownSecret,
        [ValidateRange(1000, 50000000)][int]$MaximumMaskedCharacters = 200000,
        [ValidateRange(64, 100000)][int]$MaximumTokenCharacters = 256,
        [ValidateRange(64, 100000)][int]$MaximumUrlRunCharacters = 512,
        [ValidateRange(100, 10000000)][int]$MaximumMaskedSpans = 10000,
        [switch]$QuotedValueSpansLines
    )

    $sourceText = [string]$Text
    # Обидві перевірки прив'язані до ПОЧАТКУ ланцюжка/фрагмента
    # (негативний lookbehind), тож самі лінійні: без прив'язки спроба з
    # кожної позиції всередині довгого ланцюжка знову була б квадратичною.
    $longTokenPattern = '(?i)(?<![a-z0-9+.\-])[a-z0-9+.\-]{' + ($MaximumTokenCharacters + 1) + '}'
    $longUrlRunPattern = '(?<!\S)(?=\S*://)\S{' + ($MaximumUrlRunCharacters + 1) + '}'
    if ($sourceText.Length -gt $MaximumMaskedCharacters -or
        [regex]::IsMatch($sourceText, $longTokenPattern) -or
        [regex]::IsMatch($sourceText, $longUrlRunPattern)) {
        return [pscustomobject]@{ Text = ''; Omitted = $true; Length = $sourceText.Length }
    }
    try {
        $maskedText = [string](Protect-BRAVOLogSecret -Text $sourceText -KnownSecret $KnownSecret `
            -QuotedValueSpansLines:$QuotedValueSpansLines -MaximumMaskedSpans $MaximumMaskedSpans)
    } catch [System.OverflowException] {
        return [pscustomobject]@{ Text = ''; Omitted = $true; Length = $sourceText.Length }
    }
    return [pscustomobject]@{
        Text = $maskedText
        Omitted = $false
        Length = $sourceText.Length
    }
}

# #365: маскована КОПІЯ журналу для передачі назовні (SFTP). Маскування
# застосовується саме до байтів, що вивантажуються, а не до локального
# журналу заднім числом: локальний файл лишається повним джерелом
# діагностики на сервері, де доступ до LOGS обмежують SYSTEM/Administrators
# (захищений DACL без ACE для групи Users, який виставляє BRAVO_TASKS_INSTALL.ps1;
# BRAVO_TASKS_DIAGNOSE.ps1 попереджає, якщо Users мають читання). Копія кладеться в окремий унікальний каталог під тим
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
    'Protect-BRAVOLogSecretBounded',
    'New-BRAVOMaskedLogCopy',
    'Remove-BRAVOMaskedLogCopy',
    'Get-BRAVOLogStatistics',
    'Complete-BRAVOLog'
)
