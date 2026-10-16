# Shared BRAVO archive helpers with explicit Compatibility and Logging dependencies.

$compatibilityManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.Compatibility\BRAVO.Compatibility.psd1'
Import-Module -Name $compatibilityManifest -ErrorAction Stop

# Protect-BRAVOLogSecret (маскування діагностики 7-Zip до першого запису)
# мусить бути видимим з області ЦЬОГО модуля. Не можна покладатися на те,
# що викликач уже імпортував BRAVO.Logging: production-runtime
# (BRAVO.Archive.Runtime.ps1) виконується в session state модуля
# BRAVO.Archive, тож його Import-Module BRAVO.Logging — вкладений, а не
# глобальний, і звідси функції не видно. Без цього імпорту fail-closed
# гілка маскування спрацьовувала б у кожному production-прогоні й
# приховувала б саме ту причину збою, яку діагностика має показати.
# BRAVO.Logging — нижчий інфраструктурний модуль без власних імпортів;
# уже завантажений у сесії модуль використовується повторно (той самий
# стан журналу).
$loggingManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.Logging\BRAVO.Logging.psd1'
Import-Module -Name $loggingManifest -ErrorAction Stop

function Write-BRAVOArchiveHelperLog {
    param(
        [AllowNull()][scriptblock]$Logger,
        [string]$Message,
        [string]$Level = 'INFO'
    )

    if ($null -ne $Logger) {
        & $Logger $Message $Level
    }
}

function Remove-OldLogsByAge {
    param(
        [string]$Path,
        [string]$Filter,
        [int]$RetentionDays,
        [AllowNull()][scriptblock]$Logger
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $failed = $false
    foreach ($file in @(Get-BRAVOFiles -Path $Path -Filter $Filter |
        Where-Object { $_.LastWriteTime -lt $cutoff })) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            Write-BRAVOArchiveHelperLog `
                -Logger $Logger `
                -Message "Видалено старий лог: $($file.Name)" `
                -Level "SUCCESS"
        } catch {
            $failed = $true
            Write-BRAVOArchiveHelperLog `
                -Logger $Logger `
                -Message "Не вдалося видалити лог $($file.Name): $($_.Exception.Message)" `
                -Level "ERROR"
        }
    }
    return (-not $failed)
}

function Register-BRAVOLegacyBomPasswordFallback {
    # T006 (рішення власника 2026-09-29): успіх 7-Zip ЛИШЕ через legacy
    # BOM-у-паролі fallback (LegacyBomPasswordFallbackUsed=$true з
    # Invoke-BRAVOSevenZipIntegrityTest/Invoke-BRAVOSevenZipExtraction,
    # BRAVO.Compatibility) більше не мовчазний: WARNING у журнал з іменем
    # архіву і реєстрація імені в явному колекторі прогону, з якого
    # entrypoint надсилає ОДНЕ сповіщення на прогін і піднімає код
    # завершення щонайменше до SuccessWithWarnings. Єдина канонічна точка
    # цієї політики для integrity-тесту (Test-SevenZipArchiveIntegrity
    # нижче) і для розпакування (викликачі Invoke-BRAVOSevenZipExtraction).
    # Пароль сюди не передається взагалі — у журнал потрапляє лише ім'я
    # файла архіву і текст Warning (він пароля не містить).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]$Result,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [AllowNull()][System.Collections.Generic.List[string]]$Collector,
        [AllowNull()][scriptblock]$Logger
    )

    if ($null -eq $Result) { return $false }
    $fallbackProperty = $Result.PSObject.Properties['LegacyBomPasswordFallbackUsed']
    if ($null -eq $fallbackProperty -or -not [bool]$fallbackProperty.Value) {
        return $false
    }

    $archiveLeafName = Split-Path -Path $ArchivePath -Leaf
    $warningProperty = $Result.PSObject.Properties['Warning']
    $warningText = if ($null -ne $warningProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$warningProperty.Value)) {
        [string]$warningProperty.Value
    } else {
        'Архів відкрито лише через legacy BOM-у-паролі fallback.'
    }
    Write-BRAVOArchiveHelperLog `
        -Logger $Logger `
        -Message "Legacy BOM-пароль: ${archiveLeafName} — $warningText" `
        -Level 'WARNING'

    if ($null -ne $Collector) {
        $alreadyCollected = $false
        foreach ($collectedName in $Collector) {
            if ([string]::Equals($collectedName, $archiveLeafName, [StringComparison]::OrdinalIgnoreCase)) {
                $alreadyCollected = $true
                break
            }
        }
        if (-not $alreadyCollected) {
            $Collector.Add($archiveLeafName)
        }
    }
    return $true
}

function Get-BRAVOLegacyBomFallbackNotificationLines {
    # Канонічний текст ОДНОГО сповіщення на прогін про архіви, відкриті
    # лише через legacy BOM-у-паролі fallback: обмежений перелік імен +
    # підказка оператору. Спільний для Archive/Maintenance/DataRestore/
    # Restore Drill — кожен entrypoint лише вставляє ці рядки у свій
    # наявний шлях сповіщення.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$ArchiveNames,
        [ValidateRange(1, 100)][int]$MaximumListed = 10
    )

    $names = @($ArchiveNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($names.Count -eq 0) {
        # Порожній вивід; викликачі загортають результат у @(...).
        return
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("Архіви, відкриті лише через legacy BOM-у-паролі fallback: {0}" -f $names.Count))
    foreach ($name in @($names | Select-Object -First $MaximumListed)) {
        $lines.Add(("- {0}" -f $name))
    }
    if ($names.Count -gt $MaximumListed) {
        $lines.Add(("- … та ще {0} (повний перелік — у журналі)" -f ($names.Count - $MaximumListed)))
    }
    $lines.Add(
        'Ці архіви зашифровано паролем із BOM-префіксом (U+FEFF): так пароль ' +
        'передавали у 7-Zip версії BRAVO під UTF-8-консоллю (chcp 65001). ' +
        'Дані читаються, але лише через сумісний fallback.'
    )
    $lines.Add(
        'Що зробити: створіть нові резервні копії цих даних поточною ' +
        'версією BRAVO (повторна архівація) і переконайтеся, що прогін, ' +
        'який їх відкриває, завершується без цього попередження; старі ' +
        'архіви не видаляйте, доки нова копія не пройде перевірку цілісності.'
    )
    return $lines.ToArray()
}

function Get-BRAVOSevenZipDiagnosticStreamLines {
    # Приватний helper Write-BRAVOSevenZipFailureDiagnostics: непорожні рядки
    # ОДНОГО потоку з хвостовою межею. Винесено окремою функцією саме щоб
    # межа stderr і межа stdout лишались однією реалізацією, а не двома
    # копіями, які можуть розійтися (рівно так розійшлися create- і
    # test-шляхи до цього фікса).
    param(
        [AllowNull()][AllowEmptyString()][string]$StreamText,
        [ValidateRange(1, 500)][int]$MaximumLines
    )

    # Межа рядка — і CRLF, і одиночний LF, і одиночний CR: Write-BRAVOLog
    # зберігає CR без нормалізації, тож у журналі одиночний CR — це теж
    # окремий візуальний рядок. Розбиття лише по \r?\n дозволило б сотням
    # таких рядків (імена записів з CR) обійти -MaximumLines як «один рядок».
    $allStreamLines = @(
        [string]$StreamText -split '\r\n|\r|\n' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $streamLines = @(
        $allStreamLines |
            Select-Object -Last $MaximumLines |
            ForEach-Object { ConvertTo-BRAVOSevenZipDiagnosticSafeLine -Line $_ }
    )
    # Відкинуті межею рядків початкові рядки позначаються так само, як
    # символьне обрізання, і В МЕЖАХ того самого бюджету рядків (маркер —
    # префікс першого збереженого рядка, а не окремий рядок): інакше
    # короткий хвіст, що вміщається в символьну межу, читався б як повний
    # вивід інструмента.
    if ($allStreamLines.Count -gt $streamLines.Count -and $streamLines.Count -gt 0) {
        $streamLines[0] = '(обрізано) … ' + $streamLines[0]
    }
    return $streamLines
}

function ConvertTo-BRAVOSevenZipDiagnosticSafeLine {
    # Приватний helper: один рядок недовіреного тексту (імена записів архіву,
    # тексти винятків) без керівних символів. Розриви рядків уже розділені
    # викликачем; решта керівних символів замінюється на '?', щоб
    # сформований архів не міг підробити вигляд журналу чи консолі:
    # - \p{Cc} — C0 (ESC для ANSI-послідовностей, VT/FF), DEL і C1 (NEL,
    #   CSI U+009B, який термінал виконує як ESC [);
    # - \p{Cf} — невидимі символи форматування, зокрема керування напрямком
    #   тексту (U+202A–U+202E, U+2066–U+2069, U+200E/U+200F, U+061C), що
    #   візуально переставляють ім'я запису чи вердикт;
    # - U+2028/U+2029, які деякі переглядачі показують як розрив.
    # Табуляція лишається; CR/LF тут уже не трапляються (і не чіпаються).
    param([AllowNull()][AllowEmptyString()][string]$Line)

    return ([string]$Line -replace '[\p{Cc}\p{Cf}\u2028\u2029-[\t\r\n]]', '?')
}

function Join-BRAVOSevenZipDiagnosticRecordLines {
    # Приватний helper: багаторядковий payload запису -> текст для logger-а.
    # Write-BRAVOLog ставить timestamp і рівень лише перед ПЕРШИМ фізичним
    # рядком; без маркування рядок продовження з недовіреного виводу на
    # кшталт `2026-10-16 01:00:00.000 [SUCCESS] [ARCHIVE] backup verified`
    # виглядав би як окремий справжній запис журналу (і в masked-копії на
    # SFTP, і в консолі). Тому кожен рядок продовження починається з
    # непідроблюваного префікса — справжній запис журналу завжди
    # починається з timestamp у першій колонці.
    param([AllowNull()][AllowEmptyString()][string]$Text)

    $continuationPrefix = '  | '
    return ([string]$Text -replace '\r\n|\r|\n', ([Environment]::NewLine + $continuationPrefix))
}

function Get-BRAVOSevenZipDiagnosticReasonText {
    # Приватний helper: нормалізація причини збою (Error/Description
    # результату, текст винятку запуску/preflight) — довільного й потенційно
    # багаторядкового тексту. Перші -MaximumLines непорожніх рядків, бо суть
    # причини — на ПОЧАТКУ (заголовок винятку), на відміну від потоків 7-Zip.
    # З -SingleLine — лише перший непорожній рядок (для однорядкових
    # headline-записів). З -MaximumLength — обрізання кінця з видимою
    # позначкою, маркер входить у бюджет. Секрети тут НЕ маскуються:
    # викликач передає вже замаскований текст.
    param(
        [AllowNull()][AllowEmptyString()][string]$Reason,
        [ValidateRange(1, 500)][int]$MaximumLines = 20,
        [ValidateRange(0, 100000)][int]$MaximumLength = 0,
        [switch]$SingleLine
    )

    $lineLimit = if ($SingleLine) { 1 } else { $MaximumLines }
    # Межа рядка — CRLF, одиночний LF і одиночний CR (див.
    # Get-BRAVOSevenZipDiagnosticStreamLines): інакше текст з одиночними CR
    # обходив би і -MaximumLines, і однорядковість headline.
    $allReasonLines = @(
        [string]$Reason -split '\r\n|\r|\n' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $reasonLines = @($allReasonLines | Select-Object -First $lineLimit)
    $reasonText = ($reasonLines | ForEach-Object { (ConvertTo-BRAVOSevenZipDiagnosticSafeLine -Line $_).Trim() }) -join [Environment]::NewLine
    $tailTruncationMarker = ' … (обрізано)'
    $linesDropped = ($allReasonLines.Count -gt $reasonLines.Count)
    if ($MaximumLength -gt $tailTruncationMarker.Length -and
        ($reasonText.Length -gt $MaximumLength -or
            ($linesDropped -and ($reasonText.Length + $tailTruncationMarker.Length) -gt $MaximumLength))) {
        $reasonText = $reasonText.Substring(0, $MaximumLength - $tailTruncationMarker.Length) + $tailTruncationMarker
    } elseif ($linesDropped) {
        $reasonText += $tailTruncationMarker
    }
    return $reasonText
}

function Protect-BRAVOSevenZipDiagnosticText {
    # Приватний helper: ЄДИНА модель маскування діагностики 7-Zip — канонічний
    # Protect-BRAVOLogSecret (відомі значення, у т.ч. їхні URL/JSON-варіанти,
    # потім шаблони) на ПОВНОМУ тексті, ДО будь-якого обрізання. Жодних
    # власних зрізів до маскування: будь-яка межа, проведена по ще не
    # замаскованому тексту, може розрізати секрет (значення в лапках із
    # пробілами, закодований варіант пароля), і уламок маскувальник уже не
    # впізнав би.
    #
    # Ціна маскування повного тексту обмежується двома межами, інакше
    # обробка збою могла б зависнути саме тоді, коли діагностика потрібна:
    # - загальна довжина (-MaximumMaskedCharacters): діапазон на кожен збіг
    #   відомого значення й копії тексту на кожен шаблон;
    # - довжина суцільного ланцюжка символів схеми URL `[a-z0-9+.-]`
    #   (-MaximumTokenCharacters): шаблон облікових даних в URL у
    #   канонічному маскувальнику (`[a-z][a-z0-9+.-]*://…`) поводиться
    #   квадратично саме на такому ланцюжку (виміряно: 10 тис. символів —
    #   ~2 с, 30 тис. — ~17 с). Будь-який інший символ (`\`, `_`, пробіл,
    #   лапки) ланцюжок розриває, тож звичайні шляхи й вивід 7-Zip (короткі
    #   імена записів) обидві межі не досягають;
    # - довжина суцільного фрагмента без пробільних символів, що містить
    #   `://` (-MaximumUrlRunCharacters): той самий шаблон після `://…:`
    #   сканує `[^@\s]+` до кінця фрагмента на КОЖНОМУ входженні, тож текст
    #   на кшталт `a://b:a://b:…` без `@` квадратичний навіть із короткими
    #   ланцюжками схеми (виміряно: ~200 тис. символів одним фрагментом —
    #   ~150 с). Шаблон не перетинає пробільних символів, тож межа на
    #   фрагмент обмежує роботу лінійно від загальної довжини.
    # Текст понад будь-яку межу НЕ маскується і НЕ пишеться (fail-closed):
    # викликач отримує Omitted і записує лише позначку з довжиною.
    #
    # Повертає [pscustomobject]@{ Text; Omitted; Length }.
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [AllowNull()][AllowEmptyCollection()][string[]]$KnownSecret,
        [ValidateRange(1000, 50000000)][int]$MaximumMaskedCharacters = 200000,
        [ValidateRange(64, 100000)][int]$MaximumTokenCharacters = 256,
        [ValidateRange(64, 100000)][int]$MaximumUrlRunCharacters = 512
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
    return [pscustomobject]@{
        Text = [string](Protect-BRAVOLogSecret -Text $sourceText -KnownSecret $KnownSecret)
        Omitted = $false
        Length = $sourceText.Length
    }
}

function Write-BRAVOSevenZipFailureDiagnostics {
    # ЄДИНИЙ канонічний запис діагностичного виводу 7-Zip на шляху збою —
    # і для integrity-тесту (Test-SevenZipArchiveIntegrity нижче), і для
    # створення архіву (адаптер Write-SevenZipFailureDiagnostics у
    # BRAVO.Archive.Runtime.ps1).
    #
    # ІНВАРІАНТ: діагностика несе рівень того збою, який вона пояснює, і
    # НІКОЛИ не пише на DEBUG. Причина конкретна й перевірена: файловий
    # гейт журналу — $script:BRAVOLogFileLevel (BRAVO.Logging), канонічний
    # дефолт consoleSettings.FileLevel = "INFO" (BRAVO.Configuration), а
    # DEBUG(1) < INFO(2). Запис на DEBUG відкидається ДО потрапляння у
    # файл, тому оператор бачив лише «код: 2 — критична помилка» без
    # жодного тексту від самого інструмента.
    #
    # Історія регресії (щоб її не повторили втретє): 878dd86 (2026-07-27)
    # свідомо підняв ці рядки до ERROR «незалежно від LogLevel» і додав
    # гілку для порожнього виводу; ce4855d (2026-07-28, рукотворний
    # release-snapshot v4.0.2) відкотив усе разом із функцією; пізніший
    # коміт повернув деградовану DEBUG-копію лише для create-шляху.
    # Наслідок у production: рядків [DEBUG] у журналах архівації немає, і
    # збій 7-Zip лишався без пояснення.
    #
    # Рівень НЕ фіксований на ERROR навмисно: #300/#422 ввели WARNING для
    # retention старих архівів, і пояснення WARNING-події мусить бути
    # WARNING, інакше в журналі з'явився б ERROR для архіву, який продукт
    # свідомо толерує. Видимості це не коштує — WARNING(4) >= INFO(2).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][scriptblock]$Logger,
        [Parameter(Mandatory = $true)][string]$Operation,
        [AllowNull()][AllowEmptyString()][string]$StandardOutput,
        [AllowNull()][AllowEmptyString()][string]$StandardError,
        [ValidateSet('ERROR', 'WARNING')][string]$Level = 'ERROR',
        # Текст причини для випадку, коли 7-Zip не дав ЖОДНОГО рядка
        # (Error/Description результату). Саме це — production-форма
        # збоїв «7-Zip не знайдено», «архів не знайдено» і вбитого по
        # таймауту процесу: потоки порожні, і причина існує лише там.
        [AllowNull()][AllowEmptyString()][string]$EmptyOutputReason,
        # Точні значення секретів (пароль архіву), які маскуються в усьому,
        # що пише writer (Protect-BRAVOLogSecret -KnownSecret), — незалежно
        # від ключового слова поруч.
        [AllowNull()][AllowEmptyCollection()][string[]]$KnownSecret,
        [ValidateRange(1, 500)][int]$MaximumLines = 20,
        [ValidateRange(100, 100000)][int]$MaximumLength = 4000,
        # Межа тексту, який узагалі маскується (див.
        # Protect-BRAVOSevenZipDiagnosticText): довший потік чи причина (або
        # з надто довгим суцільним фрагментом) пропускаються з позначкою
        # довжини, а не пишуться.
        [ValidateRange(1000, 50000000)][int]$MaximumMaskedCharacters = 200000
    )

    # Межа рядків — ОДНА на весь запис (-MaximumLines), але stderr має
    # ПРІОРИТЕТ: спершу береться хвіст stderr, а stdout отримує лише
    # залишок бюджету. Емпірично (`Tools\7za.exe` 26.02, `t -y -bb1`,
    # чотири класи збою) операторо-значущий вердикт 7-Zip друкує саме у
    # stderr, а НЕ в хвості stdout:
    #
    #   усічений архів   -> stderr: "ERROR: … / Cannot open the file as archive"
    #   архів не існує   -> stderr: "ERROR: The system cannot find the file specified."
    #   невірний пароль  -> stderr: "Cannot open encrypted archive. Wrong password?"
    #   CRC на записах   -> stderr: "ERROR: CRC Failed : <ім'я запису>" (рядок на запис)
    #
    # stdout при цьому несе пер-записний прогрес `-bb1` ("T <ім'я>") і лише
    # агрегат у самому кінці ("Sub items Errors: 13", "Archives with Errors: 1").
    #
    # Тому `-Last N` по злитій послідовності небезпечний: архів із 40 записів
    # дає 55 рядків stdout проти 13 рядків stderr, і спільний хвіст (stderr
    # першим) викидав ВСІ 13 рядків stderr — оператор отримував
    # "Sub items Errors: 13" без імен тих 13 записів. Окремі квоти на кожен
    # потік цю проблему знімали, але давали запис до 2 x MaximumLines рядків;
    # пріоритетний розподіл одного бюджету тримає і межу, і вердикт.
    $separator = [Environment]::NewLine
    $recordPrefix = "${Operation}: "

    # Маскування — канонічним Protect-BRAVOLogSecret на ПОВНОМУ тексті, ДО
    # будь-якого обрізання і ДО першого запису (див.
    # Protect-BRAVOSevenZipDiagnosticText). Вивід 7-Zip містить імена записів
    # архіву, причина порожнього виводу — текст винятку; локальний журнал сам
    # не маскується, тож редагування тут — єдиний бар'єр для першого запису.
    # Пароль архіву передається викликачем як -KnownSecret.
    #
    # Fail-closed: якщо маскування недоступне або впало, сирий текст НЕ
    # пишеться — лише фіксований запис без вмісту потоків.
    try {
        if ($null -eq (Get-Command -Name 'Protect-BRAVOLogSecret' -CommandType Function -ErrorAction SilentlyContinue)) {
            throw 'Protect-BRAVOLogSecret недоступна'
        }
        $maskedStandardError = Protect-BRAVOSevenZipDiagnosticText `
            -Text $StandardError -KnownSecret $KnownSecret -MaximumMaskedCharacters $MaximumMaskedCharacters
        $maskedStandardOutput = Protect-BRAVOSevenZipDiagnosticText `
            -Text $StandardOutput -KnownSecret $KnownSecret -MaximumMaskedCharacters $MaximumMaskedCharacters
        $maskedEmptyOutputReason = Protect-BRAVOSevenZipDiagnosticText `
            -Text $EmptyOutputReason -KnownSecret $KnownSecret -MaximumMaskedCharacters $MaximumMaskedCharacters
    } catch {
        Write-BRAVOArchiveHelperLog `
            -Logger $Logger `
            -Message "${recordPrefix}діагностику 7-Zip не записано: маскування секретів недоступне (вивід інструмента свідомо відкинуто)" `
            -Level $Level
        return $false
    }

    # Пропущений надто великий потік — видима позначка з довжиною на місці
    # ЙОГО вмісту, а не тиша: «вивід був, але не записаний» мусить
    # відрізнятись від «інструмент промовчав». Позначка займає місце саме
    # того потоку, який замінює, тож пріоритет stderr не порушується:
    # позначка пропущеного stdout отримує лише залишок бюджету рядків після
    # stderr і ніколи не витісняє вердикт stderr.
    # @(...) навколо if-виразу: if-вираз розгортає порожній масив у $null, і
    # під StrictMode .Count нижче кинув би виняток (клас дефекту #449).
    $errorLines = @(if ($maskedStandardError.Omitted) {
        @("stderr 7-Zip ($($maskedStandardError.Length) символів) не записано: надто великий або з надто довгим суцільним фрагментом для безпечного маскування")
    } else {
        @(Get-BRAVOSevenZipDiagnosticStreamLines `
            -StreamText ([string]$maskedStandardError.Text) -MaximumLines $MaximumLines)
    })
    $outputLines = @()
    $outputLineBudget = $MaximumLines - $errorLines.Count
    if ($outputLineBudget -gt 0) {
        $outputLines = @(if ($maskedStandardOutput.Omitted) {
            @("stdout 7-Zip ($($maskedStandardOutput.Length) символів) не записано: надто великий або з надто довгим суцільним фрагментом для безпечного маскування")
        } else {
            @(Get-BRAVOSevenZipDiagnosticStreamLines `
                -StreamText ([string]$maskedStandardOutput.Text) -MaximumLines $outputLineBudget)
        })
    }
    $diagnosticLines = @($errorLines) + @($outputLines)

    # -MaximumLength — межа ВСЬОГО повідомлення, переданого logger-у, разом
    # із префіксом операції; інакше запис рівно на межі виходив би за неї на
    # довжину префікса. Мінімум гарантує місце хоча б для маркера обрізання.
    $truncationMarker = '(обрізано) … '
    $tailTruncationMarker = ' … (обрізано)'
    # Запас під префікс рядків продовження (Join-BRAVOSevenZipDiagnosticRecordLines):
    # він додається вже після бюджетування, тож мусить бути врахований тут —
    # рівно за кількістю рядків цього запису, інакше багаторядковий запис
    # вийшов би за межу на довжину префіксів.
    $continuationPrefixLength = '  | '.Length
    $continuationReserve = [math]::Max(0, $diagnosticLines.Count - 1) * $continuationPrefixLength
    $payloadBudget = [math]::Max($MaximumLength - $recordPrefix.Length - $continuationReserve, $truncationMarker.Length + 1)

    if ($diagnosticLines.Count -eq 0) {
        # «Інструмент промовчав» мусить відрізнятись від «діагностику
        # втратили»: саме цієї двозначності не можна було розв'язати по
        # production-логу.
        $emptyMessage = "7-Zip не повернув діагностичного тексту (stdout/stderr порожні)"
        $reasonText = if ($maskedEmptyOutputReason.Omitted) {
            "($($maskedEmptyOutputReason.Length) символів) не записано: надто велика або з надто довгим суцільним фрагментом для безпечного маскування"
        } else {
            Get-BRAVOSevenZipDiagnosticReasonText `
                -Reason ([string]$maskedEmptyOutputReason.Text) -MaximumLines $MaximumLines
        }
        if (-not [string]::IsNullOrEmpty($reasonText)) {
            $emptyMessage += "; причина: $reasonText"
        }
        # Гілка порожнього виводу має власну кількість рядків (рядки причини).
        $emptyLineCount = @($emptyMessage -split '\r\n|\r|\n').Count
        $emptyBudget = [math]::Max(
            $MaximumLength - $recordPrefix.Length - ([math]::Max(0, $emptyLineCount - 1) * $continuationPrefixLength),
            $tailTruncationMarker.Length + 1)
        if ($emptyMessage.Length -gt $emptyBudget) {
            # TrimEnd: зріз міг розірвати CRLF, а одиночний CR у Join
            # коштує на символ більше, ніж закладено в резерв.
            $emptyMessage = $emptyMessage.Substring(0, $emptyBudget - $tailTruncationMarker.Length).TrimEnd("`r") +
                $tailTruncationMarker
        }
        Write-BRAVOArchiveHelperLog -Logger $Logger -Message ($recordPrefix + (Join-BRAVOSevenZipDiagnosticRecordLines -Text $emptyMessage)) -Level $Level
        return $false
    }

    # Обрізання робиться видимим: обрізаний запис не повинен читатись як
    # повний. Межа лишається, бо ці записи йдуть і у файл журналу, і в
    # masked-копію, що вивантажується на SFTP — сильно пошкоджений архів
    # інакше дав би мегабайти на один збій саме тоді, коли журнал найбільше
    # потрібен читабельним.
    #
    # Бюджет витрачається в порядку діагностичної цінності: stderr несе
    # вердикт, тому зберігається ЦІЛИМ; stdout отримує залишок і
    # обрізається з ПОЧАТКУ, щоб уціліли його кінцеві агрегати. Спільне
    # обрізання початку було б тим самим дефектом, що й спільна межа
    # рядків: stderr стоїть першим, тому гинув би першим.
    #
    # Маркер входить У БЮДЖЕТ, а не додається поверх нього: інакше параметр
    # обіцяв би межу, якої запис не тримає. Обрізання тут — уже по
    # замаскованому тексту, тож уламка секрету воно не створює. TrimStart:
    # зріз хвоста міг розірвати CRLF, а одиночний LF у
    # Join-BRAVOSevenZipDiagnosticRecordLines коштує на символ більше, ніж
    # закладено в $continuationReserve.
    $errorText = $errorLines -join $separator
    $outputText = $outputLines -join $separator

    # Обрізати stderr лише коли він справді НЕ вміщається в бюджет. Порівняння
    # з (бюджет - довжина маркера) обрізало б і stderr, що вміщається цілим, —
    # і викидало б саме його початок, тобто перший рядок вердикту 7-Zip.
    if ($errorText.Length -gt $payloadBudget) {
        # Навіть сам stderr перебирає бюджет (пошкоджено дуже багато
        # записів): лишаємо його хвіст, stdout не додаємо взагалі — там
        # усе одно лише пер-записний прогрес.
        $diagnosticText = $truncationMarker +
            $errorText.Substring($errorText.Length - ($payloadBudget - $truncationMarker.Length)).TrimStart("`n")
    } else {
        $outputBudget = $payloadBudget - $errorText.Length
        if ($errorText.Length -gt 0 -and $outputText.Length -gt 0) {
            $outputBudget -= $separator.Length
        }
        if ($outputText.Length -gt $outputBudget) {
            if ($outputBudget -gt $truncationMarker.Length) {
                $outputText = $truncationMarker +
                    $outputText.Substring($outputText.Length - ($outputBudget - $truncationMarker.Length)).TrimStart("`n")
            } else {
                # Для stdout не лишилось навіть на маркер — пишемо лише stderr.
                $outputText = ''
            }
        }
        $diagnosticParts = @()
        if ($errorText.Length -gt 0) { $diagnosticParts += $errorText }
        if ($outputText.Length -gt 0) { $diagnosticParts += $outputText }
        $diagnosticText = $diagnosticParts -join $separator
    }
    Write-BRAVOArchiveHelperLog `
        -Logger $Logger `
        -Message ($recordPrefix + (Join-BRAVOSevenZipDiagnosticRecordLines -Text $diagnosticText)) `
        -Level $Level
    return $true
}

function Test-SevenZipArchiveIntegrity {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Тонка обгортка над Invoke-BRAVOSevenZipIntegrityTest — пароль іде далі через redirected stdin.')]
    param(
        [string]$SevenZipPath,
        [string]$ArchivePath,
        [string]$Password,
        [int]$TimeoutSeconds = 43200,
        [AllowNull()][scriptblock]$Logger,
        # T006: необов'язковий колектор прогону (List[string]) для імен
        # архівів, що пройшли лише через legacy BOM-у-паролі fallback.
        # Bool-контракт повернення НЕ змінено; без колектора WARNING у
        # журнал однаково пишеться (див. Register-BRAVOLegacyBomPasswordFallback).
        [AllowNull()][System.Collections.Generic.List[string]]$LegacyBomFallbackCollector,
        # #300 (follow-up): рівень рядка "не пройдена" ЛИШЕ для
        # archive-specific збою (7-Zip запустився і сам повідомив, що архів
        # пошкоджений/не відкривається: код 1 або 2). Збій запуску
        # інструмента (немає 7-Zip, помилка старту, таймаут, інші коди)
        # завжди лишається ERROR. Типово ERROR — інші викликачі не змінюються.
        [ValidateSet('ERROR', 'WARNING')][string]$ArchiveFailureLevel = 'ERROR',
        # #300 (follow-up): необов'язковий hashtable, у який записується
        # класифікація результату (ArchiveSpecific, ExitCode, TimedOut).
        # Bool-контракт повернення НЕ змінено.
        [AllowNull()][hashtable]$FailureInfo
    )

    Write-BRAVOArchiveHelperLog `
        -Logger $Logger `
        -Message "Перевiрка цiлiсностi 7-Zip: $(Split-Path $ArchivePath -Leaf)"
    $testResult = Invoke-BRAVOSevenZipIntegrityTest `
        -SevenZipPath $SevenZipPath `
        -ArchivePath $ArchivePath `
        -Password $Password `
        -TimeoutSeconds $TimeoutSeconds
    # #300: порожній результат (валідатор нічого не повернув) — збій виконання,
    # не виняток: нормалізується до структурованого результату ДО першого
    # звернення до властивостей (StrictMode кидає на $null.ExitCode).
    if ($null -eq $testResult) {
        $testResult = New-Object PSObject -Property @{
            Success = $false; ExitCode = $null; TimedOut = $false
            Description = 'валідатор 7-Zip не повернув результат'
            StandardOutput = ''; StandardError = ''
            Error = 'Invoke-BRAVOSevenZipIntegrityTest не повернув результат'
        }
    }

    $exitCodeText = if ($null -eq $testResult.ExitCode) {
        "немає"
    } else {
        [string]$testResult.ExitCode
    }
    if ($testResult.Success) {
        Write-BRAVOArchiveHelperLog `
            -Logger $Logger `
            -Message "Цiлiснiсть архiву пiдтверджено 7-Zip (код: 0): $ArchivePath" `
            -Level "SUCCESS"
        [void](Register-BRAVOLegacyBomPasswordFallback `
            -Result $testResult `
            -ArchivePath $ArchivePath `
            -Collector $LegacyBomFallbackCollector `
            -Logger $Logger)
        return $true
    }

    # #300 (follow-up): archive-specific = 7-Zip реально відпрацював і сам
    # забракував архів; усе інше (код $null — 7-Zip не знайдено/не стартував,
    # таймаут, 7/8/255, невідомі коди, відмова доступу/зайнятий файл будь-якою
    # мовою, незавершена legacy BOM-спроба) — збій виконання інструмента, НЕ
    # доказ проти архіву (fail-closed). #394: рішення приймає ЄДИНИЙ
    # класифікатор Test-BRAVOSevenZipArchiveSpecificFailure (BRAVO.Compatibility),
    # той самий, що класифікує другу спробу в Invoke-BRAVOSevenZipIntegrityTest.
    # TimedOut читається через PSObject.Properties (StrictMode: не всі джерела
    # результату його мають). Пряме присвоєння, не if-вираз: if-вираз
    # розгортає колекцію властивостей у масив, і індексація за іменем ламається.
    $resultProperties = $testResult.PSObject.Properties
    $failureTimedOut = ($null -ne $resultProperties['TimedOut'] -and [bool]$testResult.TimedOut)
    $archiveSpecificFailure = [bool](Test-BRAVOSevenZipArchiveSpecificFailure -Result $testResult -ArchivePath $ArchivePath)
    if ($null -ne $FailureInfo) {
        $FailureInfo['ArchiveSpecific'] = [bool]$archiveSpecificFailure
        $FailureInfo['ExitCode'] = $testResult.ExitCode
        $FailureInfo['TimedOut'] = [bool]$failureTimedOut
        # #422: ознаки для викликача, що вирішує про видалення. Класифікацію
        # (рівень рядка, коди) вони не змінюють. PasswordRejected — 7-Zip
        # відхилив пароль (пароль міг змінитися). ContentCorruption — лише
        # власні повідомлення 7-Zip про пошкоджені дані (CRC, Data Error,
        # заголовки, обрив) без відхиленого пароля і без непідтримуваного
        # методу/можливості: решта archive-specific збоїв (формат, метод,
        # "не архів") може означати несумісність інструмента, а не вмісту.
        $failureOutputText = ''
        foreach ($failureOutputName in @('StandardError', 'StandardOutput')) {
            if ($null -ne $resultProperties[$failureOutputName]) {
                $failureOutputText += "$([string]$resultProperties[$failureOutputName].Value)`n"
            }
        }
        $failurePasswordRejected = [bool]($failureOutputText -match '(?i)Wrong password')
        $FailureInfo['PasswordRejected'] = $failurePasswordRejected
        $FailureInfo['ContentCorruption'] = [bool](
            $archiveSpecificFailure -and
            -not $failurePasswordRejected -and
            $failureOutputText -match '(?i)CRC Failed|Data Error|Headers Error|Unexpected end of (archive|data)' -and
            $failureOutputText -notmatch '(?i)Unsupported (Method|feature)'
        )
    }
    $failureLevel = if ($archiveSpecificFailure) { $ArchiveFailureLevel } else { 'ERROR' }

    # Description може нести довільний текст винятку preflight/запуску
    # (зокрема повний шлях архіву), тому в однорядковий headline іде лише
    # його перший рядок, замаскований і обмежений. Маскування — та сама
    # єдина модель, що й у Write-BRAVOSevenZipFailureDiagnostics: канонічний
    # Protect-BRAVOLogSecret на ПОВНОМУ тексті до обрізання; надто довгий
    # опис не маскується й не пишеться. Fail-closed: без маскування опис не
    # пишеться зовсім.
    #
    # Шлях архіву теж маскується ДО обрізання: якщо зріз пройде всередині
    # значення на кшталт `password=…` у шляху, уламок без ключа вже не
    # впізнав би ні Write-BRAVOLog, ні маскування SFTP-копії. Без
    # маскування сирий шлях не пишеться.
    $headlineDescription = ''
    $headlinePath = ''
    try {
        if ($null -eq (Get-Command -Name 'Protect-BRAVOLogSecret' -CommandType Function -ErrorAction SilentlyContinue)) {
            throw 'Protect-BRAVOLogSecret недоступна'
        }
        $maskedDescription = Protect-BRAVOSevenZipDiagnosticText `
            -Text ([string]$testResult.Description) -KnownSecret @($Password)
        $headlineDescription = if ($maskedDescription.Omitted) {
            "опис ($($maskedDescription.Length) символів) не записано: надто великий або з надто довгим суцільним фрагментом для безпечного маскування"
        } else {
            Get-BRAVOSevenZipDiagnosticReasonText `
                -Reason ([string]$maskedDescription.Text) -SingleLine -MaximumLength 1000
        }
        # Headline — однорядковий запис: CR/LF у шляху (на NTFS недосяжні, але
        # -ArchivePath — довільний рядок) замінюються пробілом, щоб шлях не
        # розгортався в багато рядків журналу.
        # Шлях — через ту саму модель із межами вартості, що й решта
        # діагностики: прямий виклик маскувальника на довгому суцільному
        # ланцюжку міг би загальмувати шлях обробки збою.
        $maskedPath = Protect-BRAVOSevenZipDiagnosticText -Text ([string]$ArchivePath) -KnownSecret @($Password)
        $headlinePath = if ($maskedPath.Omitted) {
            "(шлях $($maskedPath.Length) символів не записано: надто довгий суцільний фрагмент для безпечного маскування)"
        } else {
            ([string]$maskedPath.Text) -replace '[\r\n]+', ' '
        }
    } catch {
        $headlineDescription = 'опис приховано: маскування секретів недоступне'
        $headlinePath = '(шлях приховано: маскування секретів недоступне)'
    }
    # Межа 4000 символів — на ВЕСЬ headline: шлях архіву (extended-length
    # шлях — тисячі символів) додається вже після обмеженого опису, тож
    # обмеження лише опису межі не тримає. Якщо запис не вміщається,
    # обрізається ПОЧАТОК шляху з видимою позначкою: ім'я архіву в кінці
    # шляху оператору потрібніше за кореневі каталоги.
    $headlinePrefix = "Перевiрка цiлiсностi 7-Zip не пройдена (код: $exitCodeText — $headlineDescription): "
    $headlinePathMarker = '(обрізано) … '
    $headlinePathBudget = 4000 - $headlinePrefix.Length
    if ($headlinePath.Length -gt $headlinePathBudget) {
        $headlinePath = if ($headlinePathBudget -gt $headlinePathMarker.Length) {
            $headlinePathMarker + $headlinePath.Substring($headlinePath.Length - ($headlinePathBudget - $headlinePathMarker.Length))
        } else {
            $headlinePathMarker.TrimEnd()
        }
    }
    Write-BRAVOArchiveHelperLog `
        -Logger $Logger `
        -Message ($headlinePrefix + $headlinePath) `
        -Level $failureLevel
    # Діагностика пише рівнем $failureLevel — тим самим, що headline-рядок
    # вище (див. інваріант у Write-BRAVOSevenZipFailureDiagnostics). Раніше
    # тут був жорсткий "DEBUG", який канонічний FileLevel=INFO відкидав, і
    # оператор не бачив причини збою взагалі.
    # Причина для порожнього виводу — Error, інакше Description: під
    # StrictMode читаються через PSObject.Properties, бо не кожне джерело
    # результату має обидві властивості.
    $emptyDiagnosticReason = ''
    foreach ($reasonPropertyName in @('Error', 'Description')) {
        if ($null -ne $resultProperties[$reasonPropertyName] -and
            -not [string]::IsNullOrWhiteSpace([string]$resultProperties[$reasonPropertyName].Value)) {
            $emptyDiagnosticReason = [string]$resultProperties[$reasonPropertyName].Value
            break
        }
    }
    [void](Write-BRAVOSevenZipFailureDiagnostics `
        -Logger $Logger `
        -Operation 'Дiагностика 7-Zip test' `
        -StandardOutput ([string]$testResult.StandardOutput) `
        -StandardError ([string]$testResult.StandardError) `
        -Level $failureLevel `
        -EmptyOutputReason $emptyDiagnosticReason `
        -KnownSecret @($Password))
    return $false
}

function Get-BRAVOValidArchiveSizeHistory {
    # AUD-008 (аудит P1.6): для sanity-check обсягу backup потрібна історія
    # РОЗМІРІВ попередніх валідних (hash-підтверджених) архівів того самого
    # компонента. Валідація — та сама пара архів + .sha512 з SHA512,
    # що й у retention (Test-BRAVOGenerationManifestVerified,
    # BRAVO.Archive.Runtime.ps1); тут лише збирається .Length, видалення
    # не відбувається.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$ArchiveFilter,
        [Parameter(Mandatory = $true)][string]$HashFileExtension,
        [string]$ExcludeArchivePath,
        [int]$MaxCount = 5
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return @()
    }
    $validSizes = New-Object System.Collections.Generic.List[pscustomobject]
    $candidates = @(Get-BRAVOFiles -Path $Directory -Filter $ArchiveFilter |
        Sort-Object -Property LastWriteTime -Descending)
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($ExcludeArchivePath) -and
            [string]::Equals($candidate.FullName, $ExcludeArchivePath, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $hashPath = "$($candidate.FullName)$HashFileExtension"
        try {
            if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
                continue
            }
            $hashText = ([System.IO.File]::ReadAllText($hashPath)).Trim([char]0xFEFF).Trim()
            if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$') {
                continue
            }
            if ($Matches.FileName -cne $candidate.Name) {
                continue
            }
            $expectedHash = $Matches.Hash.ToUpperInvariant()
            $actualHash = (Get-BRAVOFileHash -Path $candidate.FullName -Algorithm SHA512).Hash.ToUpperInvariant()
            if ($actualHash -cne $expectedHash) {
                continue
            }
        } catch {
            continue
        }
        $validSizes.Add([pscustomobject]@{
            Path = $candidate.FullName
            Bytes = [int64]$candidate.Length
            LastWriteTime = $candidate.LastWriteTime
        })
        if ($validSizes.Count -ge $MaxCount) {
            break
        }
    }
    return @($validSizes)
}

function Test-BRAVOBackupSizeAnomaly {
    # AUD-008 (аудит P1.6): "успішний" backup технічно валідний (7za test +
    # SHA512 збігається), але може бути ПІДОЗРІЛО малим через неправильне
    # джерело, поламані permissions, неповний VSS exposure чи помилку
    # wildcard — сам файл при цьому виглядає коректним. Порівнює новий
    # архів із медіаною останніх валідних архівів того самого компонента;
    # НЕ блокує (лише сигналізує) — критичність лишається за викликачем.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int64]$NewArchiveBytes,
        [Parameter(Mandatory = $true)][string]$HistoryDirectory,
        [Parameter(Mandatory = $true)][string]$ArchiveFilter,
        [Parameter(Mandatory = $true)][string]$HashFileExtension,
        [string]$ExcludeArchivePath,
        [int]$HistoryCount = 5,
        [int64]$MinimumBytes = 1024,
        [int]$MaxSizeDropPercent = 50
    )

    $history = @(Get-BRAVOValidArchiveSizeHistory `
        -Directory $HistoryDirectory `
        -ArchiveFilter $ArchiveFilter `
        -HashFileExtension $HashFileExtension `
        -ExcludeArchivePath $ExcludeArchivePath `
        -MaxCount $HistoryCount)

    if ($NewArchiveBytes -lt $MinimumBytes) {
        return [pscustomobject]@{
            IsAnomaly = $true
            Reason = "розмір архіву ($NewArchiveBytes байт) менший за мінімально допустимий ($MinimumBytes байт)"
            HistorySampleCount = $history.Count
            MedianHistoricalBytes = $null
            NewArchiveBytes = $NewArchiveBytes
            DropPercent = $null
        }
    }

    if ($history.Count -eq 0) {
        return [pscustomobject]@{
            IsAnomaly = $false
            Reason = "недостатньо історії валідних архівів для порівняння (перший backup цього компонента чи ще не накопичено історію)"
            HistorySampleCount = 0
            MedianHistoricalBytes = $null
            NewArchiveBytes = $NewArchiveBytes
            DropPercent = $null
        }
    }

    $sortedSizes = @($history | Select-Object -ExpandProperty Bytes | Sort-Object)
    $middleIndex = [math]::Floor($sortedSizes.Count / 2)
    $medianBytes = if ($sortedSizes.Count % 2 -eq 0 -and $sortedSizes.Count -ge 2) {
        [int64][math]::Round(($sortedSizes[$middleIndex - 1] + $sortedSizes[$middleIndex]) / 2.0)
    } else {
        [int64]$sortedSizes[$middleIndex]
    }

    if ($medianBytes -le 0) {
        return [pscustomobject]@{
            IsAnomaly = $false
            Reason = "медіана історичних розмірів нульова — порівняння неможливе"
            HistorySampleCount = $history.Count
            MedianHistoricalBytes = $medianBytes
            NewArchiveBytes = $NewArchiveBytes
            DropPercent = $null
        }
    }

    $dropPercent = [math]::Round((1.0 - ([double]$NewArchiveBytes / [double]$medianBytes)) * 100.0, 1)
    if ($dropPercent -gt $MaxSizeDropPercent) {
        return [pscustomobject]@{
            IsAnomaly = $true
            Reason = "розмір архіву впав на $dropPercent% відносно медіани останніх $($history.Count) валідних backup (поріг: $MaxSizeDropPercent%)"
            HistorySampleCount = $history.Count
            MedianHistoricalBytes = $medianBytes
            NewArchiveBytes = $NewArchiveBytes
            DropPercent = $dropPercent
        }
    }

    return [pscustomobject]@{
        IsAnomaly = $false
        Reason = "у межах норми (відхилення від медіани: $dropPercent%)"
        HistorySampleCount = $history.Count
        MedianHistoricalBytes = $medianBytes
        NewArchiveBytes = $NewArchiveBytes
        DropPercent = $dropPercent
    }
}

function Get-BRAVOBackupManifestRoot {
    # dev.14: generation manifest-и (BRAVO_BACKUP_<GenerationId>.json)
    # зберігаються окремо від LOGS/TEMP — їхній lifecycle прив'язаний до
    # backup generation (видаляються разом з нею), а не до незалежного
    # LogDays/CompressedLogDays. Єдине місце, що знає фізичний шлях —
    # інші функції завжди отримують його звідси, а не будують Join-Path самі.
    param([Parameter(Mandatory = $true)][string]$BackupRoot)

    return (Join-Path $BackupRoot 'MANIFESTS')
}

function Get-BRAVOBackupGenerationManifestFiles {
    # Централізований reader generation manifest-ів. MANIFESTS\ — джерело
    # істини; корінь BackupRoot — fallback для файлів, які ще не мігровані
    # (Initialize-BRAVOBackupManifestStorage не виконувалась, наприклад одразу
    # після апгрейду до dev.14) або лишились там після конфлікту міграції.
    # Корінь читається БЕЗ -Recurse, тому підпапка MANIFESTS у нього фізично
    # не потрапляє — дублювання виникає лише коли той самий generationId
    # реально існує в обох місцях, і тоді пріоритет завжди за MANIFESTS.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [string]$GenerationId
    )

    $manifestRoot = Get-BRAVOBackupManifestRoot -BackupRoot $BackupRoot

    if (-not [string]::IsNullOrWhiteSpace($GenerationId)) {
        $fileName = "BRAVO_BACKUP_{0}.json" -f $GenerationId
        $newPath = Join-Path $manifestRoot $fileName
        if (Test-Path -LiteralPath $newPath -PathType Leaf) {
            return @(Get-Item -LiteralPath $newPath)
        }
        $legacyPath = Join-Path $BackupRoot $fileName
        if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
            return @(Get-Item -LiteralPath $legacyPath)
        }
        return @()
    }

    $newManifests = if (Test-Path -LiteralPath $manifestRoot -PathType Container) {
        @(Get-BRAVOFiles -Path $manifestRoot -Filter 'BRAVO_BACKUP_*.json')
    } else {
        @()
    }
    $legacyManifests = @(Get-BRAVOFiles -Path $BackupRoot -Filter 'BRAVO_BACKUP_*.json')

    # Дедуплікація за іменем файлу (== generationId): MANIFESTS додається
    # першим, тому саме він "виграє" колізію, а не порядок файлової системи.
    $seenNames = New-Object 'System.Collections.Generic.HashSet[string]'
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($file in $newManifests) {
        if ($seenNames.Add($file.Name)) {
            $result.Add($file)
        }
    }
    foreach ($file in $legacyManifests) {
        if ($seenNames.Add($file.Name)) {
            $result.Add($file)
        }
    }
    return $result.ToArray()
}

function Initialize-BRAVOBackupManifestStorage {
    # dev.14: одноразова (ідемпотентна) міграція legacy manifest-ів —
    # BRAVO_BACKUP_*.json безпосередньо в корені BackupRoot — у виділений
    # MANIFESTS\. Пошук legacy — БЕЗ -Recurse (лише корінь BackupRoot,
    # підпапка MANIFESTS у нього не потрапляє).
    #
    # Колізії при непорожньому destination:
    #   - файлів немає в MANIFESTS               => Move-Item;
    #   - є, і байтово ідентичний (SHA256)        => legacy-дублікат
    #     видаляється, MANIFESTS лишається єдиним джерелом;
    #   - є, і відрізняється                      => ЖОДЕН файл не
    #     видаляється й не перезаписується, лише WARNING у лог із
    #     generationId конфлікту; reader (Get-BRAVOBackupGenerationManifestFiles)
    #     все одно віддасть перевагу версії з MANIFESTS.
    #
    # Нічого з цього не є фатальним для виклику — весь стан повертається
    # викликачу через результат; невдала міграція нічого не знищує і
    # повторюється на наступному запуску.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [AllowNull()][scriptblock]$Logger
    )

    $result = [ordered]@{
        ManifestRoot = $null
        ManifestRootCreated = $false
        Migrated = @()
        Deduplicated = @()
        Conflicts = @()
        Errors = @()
    }

    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        $result.Errors += "BackupRoot не знайдено: $BackupRoot"
        return [pscustomobject]$result
    }

    $manifestRoot = Get-BRAVOBackupManifestRoot -BackupRoot $BackupRoot
    $result.ManifestRoot = $manifestRoot
    try {
        if (-not (Test-Path -LiteralPath $manifestRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $manifestRoot -Force -ErrorAction Stop | Out-Null
            $result.ManifestRootCreated = $true
            Write-BRAVOArchiveHelperLog -Logger $Logger `
                -Message "Створено каталог метаданих backup: $manifestRoot" -Level "SUCCESS"
        }
    } catch {
        $result.Errors += "Не вдалося створити ${manifestRoot}: $($_.Exception.Message)"
        Write-BRAVOArchiveHelperLog -Logger $Logger -Message $result.Errors[-1] -Level "ERROR"
        return [pscustomobject]$result
    }

    foreach ($legacyFile in @(Get-BRAVOFiles -Path $BackupRoot -Filter 'BRAVO_BACKUP_*.json')) {
        $generationLabel = $legacyFile.Name -replace '^BRAVO_BACKUP_(.+)\.json$', '$1'
        $destinationPath = Join-Path $manifestRoot $legacyFile.Name
        try {
            if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                Move-Item -LiteralPath $legacyFile.FullName -Destination $destinationPath -ErrorAction Stop
                $result.Migrated += $legacyFile.Name
                Write-BRAVOArchiveHelperLog -Logger $Logger `
                    -Message "Перенесено manifest generation ${generationLabel} у MANIFESTS" -Level "SUCCESS"
                continue
            }

            $legacyHash = (Get-BRAVOFileHash -Path $legacyFile.FullName -Algorithm SHA256).Hash
            $destinationHash = (Get-BRAVOFileHash -Path $destinationPath -Algorithm SHA256).Hash
            if ([string]::Equals($legacyHash, $destinationHash, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $legacyFile.FullName -Force -ErrorAction Stop
                $result.Deduplicated += $legacyFile.Name
                Write-BRAVOArchiveHelperLog -Logger $Logger `
                    -Message "Manifest generation ${generationLabel} уже є в MANIFESTS (ідентичний); legacy-копію в корені прибрано" `
                    -Level "INFO"
            } else {
                $result.Conflicts += $legacyFile.Name
                Write-BRAVOArchiveHelperLog -Logger $Logger `
                    -Message "Конфлікт manifest generation ${generationLabel}: версії в корені BackupRoot і в MANIFESTS відрізняються — обидва файли збережено без змін, читання пріоритетно бере версію з MANIFESTS" `
                    -Level "WARNING"
            }
        } catch {
            $result.Errors += "Не вдалося обробити manifest generation ${generationLabel}: $($_.Exception.Message)"
            Write-BRAVOArchiveHelperLog -Logger $Logger -Message $result.Errors[-1] -Level "ERROR"
        }
    }

    return [pscustomobject]$result
}

function Get-BRAVOBackupManifestFilenameGenerationId {
    # dev.14 (round 3): строгий parser/validator generationId, закодованого
    # у ФІЗИЧНОМУ імені файлу manifest-а (BRAVO_BACKUP_<GenerationId>.json).
    # Формат GenerationId — yyyyMMdd_HHmmss або той самий з collision-safe
    # суфіксом (_N) — той самий контракт, що BRAVO_RESTORE_TEST.ps1 вже
    # валідує для параметра -GenerationId. Повертає $null, якщо ім'я файлу
    # НЕ відповідає точно цьому формату — викликач тоді не повинен
    # довіряти файлу як trustworthy retention record.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$FileName)

    if ($FileName -match '^BRAVO_BACKUP_(?<GenerationId>\d{8}_\d{6}(?:_\d+)?)\.json$') {
        return $Matches.GenerationId
    }
    return $null
}

function Get-BRAVOBackupGenerationManifestPhysicalFiles {
    # Усі фізичні копії manifest-файлу ОДНІЄЇ generation — на відміну від
    # Get-BRAVOBackupGenerationManifestFiles (читання, MANIFESTS-first,
    # дедуплікація ховає legacy-дублікат/конфлікт), ця функція повертає їх
    # УСІ. Потрібна retention: коли generation підтверджено видаляється,
    # видалені мають бути ВСІ фізичні представлення її metadata — інакше
    # legacy-копія переживає видалення MANIFESTS-копії і на наступному
    # запуску "воскрешає" видалену generation через legacy fallback читання.
    #
    # GenerationId походить із вмісту manifest-файлу (JSON, недовірений
    # вхід відносно файлової системи) — шлях свідомо НЕ конструюється
    # (Join-Path недовіреного рядка з коренем був би path traversal).
    # Замість цього кандидати відбираються фільтром .Name серед РЕАЛЬНО
    # перелічених файлів (Get-BRAVOFiles, лише MANIFESTS + корінь
    # BackupRoot, без -Recurse) — попадання неможливе поза цими двома
    # каталогами незалежно від вмісту GenerationId.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$GenerationId
    )

    $expectedFileName = "BRAVO_BACKUP_{0}.json" -f $GenerationId
    $manifestRoot = Get-BRAVOBackupManifestRoot -BackupRoot $BackupRoot
    $allPhysicalFiles = @(
        $(if (Test-Path -LiteralPath $manifestRoot -PathType Container) {
            Get-BRAVOFiles -Path $manifestRoot -Filter 'BRAVO_BACKUP_*.json'
        })
        $(Get-BRAVOFiles -Path $BackupRoot -Filter 'BRAVO_BACKUP_*.json')
    )
    return @($allPhysicalFiles | Where-Object {
        [string]::Equals($_.Name, $expectedFileName, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Get-BRAVORestoreGenerationManifest {
    # Selector generation для restore-інструментів (BRAVO_RESTORE_TEST і
    # BRAVO_DATA_RESTORE): найновіший COMPLETE generation manifest або точний
    # -RequestedGenerationId. Живе тут, а не в кожному скрипті окремо, щоб
    # обидва restore-потоки гарантовано вибирали generation за одними й тими
    # самими правилами (MANIFESTS-first читання, лише status=COMPLETE,
    # сортування за createdAt/startedAt/LastWriteTime).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [string]$RequestedGenerationId
    )

    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        throw "BackupRoot не знайдено: $BackupRoot"
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedGenerationId) -and
        $RequestedGenerationId -notmatch '^\d{8}_\d{6}(?:_\d+)?$') {
        throw "GenerationId має формат yyyyMMdd_HHmmss або collision-safe variant"
    }

    # dev.14: MANIFESTS-first reader з fallback на legacy корінь BackupRoot —
    # той самий централізований reader, що Archive-retention і Health.
    $manifestFiles = @(Get-BRAVOBackupGenerationManifestFiles `
        -BackupRoot $BackupRoot `
        -GenerationId $RequestedGenerationId)

    $candidates = @()
    # Аномалії, пропущені fail-closed'ом ПІД ЧАС АВТОМАТИЧНОГО вибору
    # (нечитабельний manifest, identity mismatch). Сам пропуск — правильна
    # поведінка, але він НЕ має бути мовчазним: тихе падіння на старішу
    # generation оператор інакше не побачить. Штатні не-COMPLETE manifest-и
    # аномалією не вважаються. Модуль навмисно нічого не логує сам —
    # список повертається викликачам (DATA_RESTORE / RESTORE_TEST) як
    # властивість SkippedManifests результату, і кожен логує своїм логером.
    $skippedAnomalies = @()
    foreach ($manifestFile in $manifestFiles) {
        try {
            $manifest = [IO.File]::ReadAllText($manifestFile.FullName) | ConvertFrom-Json -ErrorAction Stop
            if ([string]$manifest.status -ne 'COMPLETE') { continue }
            # Identity invariant: ім'я файлу (BRAVO_BACKUP_<generationId>.json)
            # і generationId усередині JSON мають бути ТОЧНО тим самим
            # значенням. Без цієї перевірки пошкоджений/перейменований
            # manifest міг би пройти лише format-валідацію RequestedGenerationId
            # (яка звіряється із самим ІМ'ЯМ файлу — Get-BRAVOBackupGenerationManifestFiles
            # будує ім'я з нього), а фактично відновити зовсім іншу
            # generation, вказану всередині файлу.
            $filenameGenerationId = [IO.Path]::GetFileNameWithoutExtension($manifestFile.Name) -replace '^BRAVO_BACKUP_', ''
            $jsonGenerationId = [string]$manifest.generationId
            if ([string]::IsNullOrWhiteSpace($jsonGenerationId) -or
                $jsonGenerationId -notmatch '^\d{8}_\d{6}(?:_\d+)?$' -or
                -not [string]::Equals($filenameGenerationId, $jsonGenerationId, [StringComparison]::Ordinal)) {
                if (-not [string]::IsNullOrWhiteSpace($RequestedGenerationId)) {
                    throw "manifest '$($manifestFile.Name)' не пройшов перевірку ідентичності: ім'я файлу вказує generation '$filenameGenerationId', а вміст JSON — '$jsonGenerationId'"
                }
                # Автоматичний вибір (без explicit -RequestedGenerationId):
                # fail-closed — пропускаємо підозрілий manifest, а не
                # ризикуємо вибрати generation, вказану лише в JSON.
                $skippedAnomalies += [pscustomobject]@{
                    ManifestPath = $manifestFile.FullName
                    Reason       = "identity mismatch: ім'я файлу вказує generation '$filenameGenerationId', а вміст JSON — '$jsonGenerationId'"
                }
                continue
            }
            $createdAt = $manifestFile.LastWriteTime
            foreach ($dateProperty in @('createdAt', 'startedAt')) {
                $property = $manifest.PSObject.Properties[$dateProperty]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    $createdAt = [datetime]$property.Value
                    break
                }
            }
            $candidates += [pscustomobject]@{
                Manifest = $manifest
                ManifestPath = $manifestFile.FullName
                CreatedAt = $createdAt
            }
        } catch {
            if (-not [string]::IsNullOrWhiteSpace($RequestedGenerationId)) {
                throw "Generation manifest не прочитано: $($_.Exception.Message)"
            }
            $skippedAnomalies += [pscustomobject]@{
                ManifestPath = $manifestFile.FullName
                Reason       = "manifest не прочитано: $($_.Exception.Message)"
            }
        }
    }
    $selected = $candidates | Sort-Object CreatedAt -Descending | Select-Object -First 1
    if ($null -eq $selected) {
        if ([string]::IsNullOrWhiteSpace($RequestedGenerationId)) {
            if (@($skippedAnomalies).Count -gt 0) {
                throw "не знайдено жодного COMPLETE generation manifest (пропущено з аномаліями: $(@($skippedAnomalies).Count) — $((@($skippedAnomalies) | ForEach-Object { $_.Reason }) -join '; '))"
            }
            throw 'не знайдено жодного COMPLETE generation manifest'
        }
        throw "COMPLETE generation '$RequestedGenerationId' не знайдено"
    }
    Add-Member -InputObject $selected -MemberType NoteProperty -Name 'SkippedManifests' -Value @($skippedAnomalies) -Force
    return $selected
}

function Get-BRAVOVerifiedGenerationArchive {
    # Строгий per-component gate для restore-інструментів: прапорці manifest
    # (Enabled/CreateSuccess/IntegritySuccess/HashSuccess), фізична наявність
    # архіву й sidecar, коректний формат sidecar із case-sensitive збігом
    # імені файлу та ФАКТИЧНИЙ перерахунок SHA512. Будь-яка розбіжність —
    # throw: компонент не можна ані вважати відновлюваним (RESTORE_TEST),
    # ані відновлювати (DATA_RESTORE).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$Component,
        # Canonical naming policy of the backup PRODUCER (той самий
        # NameTemplate, яким генерувалось ім'я архіву — BRAVO.config
        # archiveDefinitions[Type].NameTemplate -f archivePrefix,
        # generationId). Використовується лише для СТРУКТУРИ суфіксу
        # (роздільник + generationId + розширення), НЕ для конкретного
        # значення ArchivePrefix — див. коментар нижче.
        [Parameter(Mandatory = $true)][string]$NameTemplate,
        # Canonical (не мутований поточними налаштуваннями) каталог, де
        # ЛЕГІТИМНО зберігаються артефакти САМЕ цього Component — для
        # Local це archiveDefinitions[Type].Destination, для SFTP-staging
        # це per-component підкаталог staging generation root
        # (Invoke-BRAVODataRestoreSftpArchiveFetch кладе кожен компонент
        # у власний підкаталог). Основа identity-binding: ArchivePrefix —
        # оператор-конфігурований рядок, що ЗМІНЮЄТЬСЯ з часом (ротація);
        # README.md документує, що архіви, створені під СТАРИМ префіксом,
        # лишаються legitimate й мають лишатись відновлюваними. Каталог,
        # натомість, детермінований типом компонента і не залежить від
        # поточного значення ArchivePrefix.
        [Parameter(Mandatory = $true)][string]$ComponentDirectory
    )

    $componentsProperty = $Manifest.PSObject.Properties['components']
    if ($null -eq $componentsProperty -or $null -eq $componentsProperty.Value) {
        throw 'generation manifest не містить components'
    }
    $componentProperty = @($componentsProperty.Value.PSObject.Properties | Where-Object {
        [string]::Equals($_.Name, $Component, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)
    if ($componentProperty.Count -eq 0) {
        throw "generation не містить component $Component"
    }
    $componentState = $componentProperty[0].Value
    if (-not [bool]$componentState.Enabled -or
        -not [bool]$componentState.CreateSuccess -or
        -not [bool]$componentState.IntegritySuccess -or
        -not [bool]$componentState.HashSuccess) {
        throw "component $Component не має COMPLETE archive/integrity/SHA512 state"
    }

    $archivePath = [string]$componentState.ArchivePath
    $hashPath = [string]$componentState.HashPath
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
        throw "component $Component посилається на відсутній archive/hash artifact"
    }
    $archive = Get-Item -LiteralPath $archivePath

    # Component identity binding: артефакт МУСИТЬ фізично лежати в
    # canonical каталозі саме цього Component — інакше пошкоджений/
    # підмінений manifest міг би підставити реальний, криптографічно
    # валідний архів ІНШОГО компонента (він лежить у СВОЄМУ каталозі, не
    # в цьому), і кожна перевірка нижче (SHA512, sidecar) пройшла б, бо
    # файл сам по собі не пошкоджений. На відміну від попередньої
    # реалізації (порівняння повного імені файлу з поточним ArchivePrefix),
    # ця перевірка НЕ залежить від того, яким був ArchivePrefix у момент
    # створення архіву — ротація префіксу не інвалідує старі backup.
    $archiveDirectoryFull = try { [System.IO.Path]::GetFullPath($archive.DirectoryName).TrimEnd('\', '/') } catch { $archive.DirectoryName }
    $expectedDirectoryFull = try { [System.IO.Path]::GetFullPath($ComponentDirectory).TrimEnd('\', '/') } catch { $ComponentDirectory }
    if (-not [string]::Equals($archiveDirectoryFull, $expectedDirectoryFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "component ${Component}: артефакт '$($archive.FullName)' лежить поза canonical каталогом цього компонента ('$ComponentDirectory') — можлива підміна компонента у manifest"
    }

    # Generation identity binding: ім'я артефакта має закінчуватись саме
    # тим суфіксом (роздільник(и) + generationId + розширення), який
    # NameTemplate виробляє для CIЄЇ generationId — це прив'язує до
    # generation, знову ж НЕЗАЛЕЖНО від значення ArchivePrefix (підставляємо
    # порожній рядок у позицію {0}, суфікс — те, що лишається праворуч).
    $manifestGenerationId = [string]$Manifest.generationId
    $expectedNameSuffix = $NameTemplate -f '', $manifestGenerationId
    if ([string]::IsNullOrEmpty($expectedNameSuffix) -or
        $archive.Name.Length -le $expectedNameSuffix.Length -or
        -not $archive.Name.EndsWith($expectedNameSuffix, [StringComparison]::Ordinal)) {
        throw "component ${Component}: ім'я артефакта '$($archive.Name)' не відповідає generation '$manifestGenerationId' за canonical NameTemplate — можлива підміна generation у manifest"
    }
    $hashText = ([IO.File]::ReadAllText($hashPath)).Trim([char]0xFEFF).Trim()
    if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$' -or
        $Matches.FileName -cne $archive.Name) {
        throw "component $Component має некоректний SHA512 sidecar"
    }
    $actualHash = (Get-BRAVOFileHash -Path $archive.FullName -Algorithm SHA512).Hash.ToUpperInvariant()
    if ($actualHash -cne $Matches.Hash.ToUpperInvariant()) {
        throw "component $Component не пройшов фактичну SHA512 verification"
    }
    return $archive
}

function Get-BRAVOVerifiedArtifactLeafName {
    # Витягує ІМ'Я файлу з недовіреного manifest-шляху і підтверджує, що
    # воно безпечне для Join-Path з канонічним каталогом компонента: САМЕ
    # leaf-ім'я бере участь у реконструкції шляху, ніколи решта каталогів
    # зі старого/чужого manifest-шляху. Canonical для обох споживачів
    # generation-manifest (BRAVO_DATA_RESTORE, BRAVO_RESTORE_TEST) — раніше
    # існувала лише приватна копія в BRAVO.DataRestore.Runtime.ps1
    # (round-7 P2), promoted сюди, щоб drill і реальне відновлення
    # використовували ОДНУ політику rebasing.
    #
    # [System.IO.Path]::GetFileName — ЧИСТА рядкова операція (лише те, що
    # після останнього роздільника), а НЕ Split-Path -Leaf: Split-Path є
    # provider-aware й резолвить відносні сегменти (напр. буквальний "..")
    # проти ПОТОЧНОГО робочого каталогу процесу, тому для значення ".."
    # повернув би ім'я батьківського каталогу поточного $PWD (недетерміновано
    # й ніяк не пов'язано зі змістом самого manifest-рядка) замість
    # відхилення traversal-сегмента як такого. GetFileName трактує "..\..\"
    # суто текстово й повертає порожній/traversal-фрагмент без звернення до
    # файлової системи — саме це й потрібно для недовіреного вхідного рядка.
    # Порожнє значення, "."/"..", чи ім'я з недопустимими символами
    # файлової системи — відхиляється (повертає $null).
    [CmdletBinding()]
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $leaf = $null
    try {
        $leaf = [System.IO.Path]::GetFileName($Value)
    } catch {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $null }
    if ($leaf -eq '.' -or $leaf -eq '..') { return $null }
    if ($leaf.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $null }
    return $leaf
}

function ConvertTo-BRAVORebasedLocalGenerationManifest {
    # Canonical local-repository rebasing policy, спільна для
    # BRAVO_DATA_RESTORE (реальне відновлення) і BRAVO_RESTORE_TEST
    # (read-only pre-restore drill) — обидва мають бачити ОДНУ семантику
    # генерації: якщо repository резервних копій скопійовано/змонтовано
    # під іншим диском/коренем (документований disaster-recovery
    # сценарій), manifest.ArchivePath/HashPath (записані ПРОДЮСЕРОМ, інший
    # сервер) фізично не існують за старою адресою, хоча байти архіву,
    # sidecar і сам manifest валідні під ПОТОЧНИМ BackupRoot. Раніше
    # BRAVO_DATA_RESTORE переписував шляхи приватною копією
    # (ConvertTo-BRAVODataRestoreRebasedLocalManifest в
    # BRAVO.DataRestore.Runtime.ps1, round-7), а BRAVO_RESTORE_TEST
    # довіряв необробленому manifest-у напряму — той самий relocated
    # repository міг пройти BRAVO_DATA_RESTORE, але провалити
    # BRAVO_RESTORE_TEST (P2 follow-up review 4945879933).
    #
    # Manifest-шлях лишається НЕДОВІРЕНИМ: з нього беруться ЛИШЕ leaf-імена
    # (Get-BRAVOVerifiedArtifactLeafName), решта шляху відкидається. Нове
    # ArchivePath/HashPath — canonical каталог компонента
    # (archiveDefinitions[Type].Destination, довірене значення з
    # BRAVO.config) + validated leaf-ім'я. Get-BRAVOVerifiedGenerationArchive
    # (незмінно) далі вимагає, щоб фактичний каталог артефакту БУКВАЛЬНО
    # збігався з ComponentDirectory — тому rebased шлях структурно НЕ може
    # вийти за межі canonical каталогу компонента: перевірка тут не
    # послаблює жодного з існуючих integrity/containment gate, лише додає
    # ще один незалежний рівень (leaf-only, без traversal-сегментів).
    # Rotated ArchivePrefix (round-4) теж незмінно підтримується — тут
    # ЛИШЕ переписуються шляхи, історичний basename з manifest-а НЕ
    # реконструюється з поточного префіксу.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string[]]$ComponentTypes,
        [Parameter(Mandatory = $true)][object[]]$ArchiveDefinitions
    )

    $clone = $Manifest | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    foreach ($componentType in $ComponentTypes) {
        $componentProperty = @($clone.components.PSObject.Properties | Where-Object {
            [string]::Equals($_.Name, $componentType, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($componentProperty.Count -eq 0) { continue }

        $componentDestination = [string]@($ArchiveDefinitions | Where-Object {
            [string]::Equals([string]$_.Type, $componentType, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1).Destination
        if ([string]::IsNullOrWhiteSpace($componentDestination)) { continue }

        $archiveLeaf = Get-BRAVOVerifiedArtifactLeafName -Value ([string]$componentProperty[0].Value.ArchivePath)
        $hashLeaf = Get-BRAVOVerifiedArtifactLeafName -Value ([string]$componentProperty[0].Value.HashPath)
        if ($null -eq $archiveLeaf -or $null -eq $hashLeaf) {
            # Небезпечне/непарсиме ім'я — НЕ переписуємо; нижчий строгий
            # gate однаково відхилить компонент (Test-Path на оригінальному
            # значенні не пройде, або containment-перевірка провалиться) —
            # fail-safe, не мовчазний пропуск.
            continue
        }
        $componentProperty[0].Value.ArchivePath = Join-Path $componentDestination $archiveLeaf
        $componentProperty[0].Value.HashPath = Join-Path $componentDestination $hashLeaf
    }
    return $clone
}
