# BRAVO.Update.Diagnostics — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Read-only діагностика й support-звіт (INS-024). Жодних змін
# runtime/config/tasks/credentials, жодного мережевого коду, жодного запуску
# дочірніх скриптів: функції лише читають передані дані та логи, а єдиний
# запис — Save-BRAVODiagnosticReport у явно обраний оператором шлях.

$script:BRAVOUpdateDiagnosticReportSchemaVersion = 1

function Get-BRAVOUpdateDiagValue {
    # Безпечне читання властивості під StrictMode 2.0 (властивість може бути
    # відсутня в legacy/частковому state).
    [CmdletBinding()]
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    if ($null -eq $property.Value) { return $Default }
    return $property.Value
}

function Initialize-BRAVOUpdateDiagLogging {
    # Protect-BRAVOLogSecret живе в BRAVO.Logging. Part не може змінити
    # psm1, тому підключаємо модуль ліниво (pure-функція, без побічних
    # ефектів). Відсутній модуль — fail closed: звіт без маскування секретів
    # не створюється.
    [CmdletBinding()]
    param()

    if ($null -ne (Get-Command -Name 'Protect-BRAVOLogSecret' -ErrorAction SilentlyContinue)) {
        return
    }
    $loggingManifest = Join-Path $script:BRAVOUpdateToolkitRoot 'modules\BRAVO.Logging\BRAVO.Logging.psd1'
    if (-not (Test-Path -LiteralPath $loggingManifest -PathType Leaf)) {
        throw "BRAVO.Update: BRAVO.Logging не знайдено ($loggingManifest); звіт без маскування секретів не створюється."
    }
    Import-Module -Name $loggingManifest -DisableNameChecking -ErrorAction Stop
}

function Invoke-BRAVOUpdateReportRedaction {
    # Повертає { Text; Counts } — Counts: kind -> кількість замін. Порядок
    # кроків важливий: спочатку конкретніші форми (секрети, fingerprint,
    # e-mail, UNC), потім IP та імена, щоб ім'я хоста в UNC/e-mail не було
    # замінене частково й не лишило залишків.
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [AllowNull()][AllowEmptyCollection()][string[]]$SiteIdentifiers
    )

    $counts = [ordered]@{
        credential = 0; fingerprint = 0; email = 0; unc = 0; ip = 0
        site = 0; host = 0; user = 0; domain = 0
    }
    if ([string]::IsNullOrEmpty($Text)) {
        return [pscustomobject]@{ Text = $Text; Counts = $counts }
    }

    Initialize-BRAVOUpdateDiagLogging
    $value = [string]$Text

    # 1) Секрети за шаблонами спільного маскувальника (***).
    $masked = [string](Protect-BRAVOLogSecret -Text $value)
    $before = ([regex]::Matches($value, '\*\*\*')).Count
    $after = ([regex]::Matches($masked, '\*\*\*')).Count
    if ($after -gt $before) { $counts['credential'] += ($after - $before) }
    $value = $masked

    # 2) Додаткові key=value, які спільний маскувальник міг не знати.
    $kvPattern = '(?i)\b(password|passwd|pwd|passphrase|token|secret|api[_-]?key)(\s*[=:]\s*)(?!\*\*\*|<redacted)("[^"\r\n]*"|''[^''\r\n]*''|[^\s,;]+)'
    $n = ([regex]::Matches($value, $kvPattern)).Count
    if ($n -gt 0) {
        $value = [regex]::Replace($value, $kvPattern, '${1}${2}<redacted:secret>')
        $counts['credential'] += $n
    }

    # 3) SFTP host-key fingerprint: SHA256 base64 рівно 43 символи (довгий
    # hex-хеш артефакта сюди не потрапляє, бо після 43 символів не має бути
    # base64-символу).
    $fpPattern = '(?i)(?:(?:ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp\d+)\s+(?:\d+\s+)?)?SHA256:[A-Za-z0-9+/]{43}=?(?![A-Za-z0-9+/=])'
    $n = ([regex]::Matches($value, $fpPattern)).Count
    if ($n -gt 0) {
        $value = [regex]::Replace($value, $fpPattern, '<redacted:fingerprint>')
        $counts['fingerprint'] += $n
    }

    # 4) E-mail.
    $mailPattern = '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}'
    $n = ([regex]::Matches($value, $mailPattern)).Count
    if ($n -gt 0) {
        $value = [regex]::Replace($value, $mailPattern, '<redacted:email>')
        $counts['email'] += $n
    }

    # 5) UNC: лишається \\<host>\share. Префікси \\?\ і \\.\ — не хости.
    $uncPattern = '\\\\(?![?.]\\)([^\\\s"''<>|/*?]+)(?=\\)'
    $n = ([regex]::Matches($value, $uncPattern)).Count
    if ($n -gt 0) {
        $value = [regex]::Replace($value, $uncPattern, '\\<redacted:host>')
        $counts['unc'] += $n
    }

    # 6) IPv4 (крім loopback 127.0.0.1). Межі (?<![\w.]) / (?!\w|\.\d)
    # не дають зачепити версії на кшталт 5.3.0 (лише 3 частини) чи дати.
    $ipPattern = '(?<![\w.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?!\w|\.\d)'
    $ipCount = 0
    foreach ($m in [regex]::Matches($value, $ipPattern)) {
        if ($m.Value -ne '127.0.0.1') { $ipCount++ }
    }
    if ($ipCount -gt 0) {
        $value = [regex]::Replace($value, $ipPattern, {
                param($match)
                if ($match.Value -eq '127.0.0.1') { return $match.Value }
                return '<redacted:ip>'
            })
        $counts['ip'] += $ipCount
    }

    # 7) Ідентифікатори майданчика від оператора (назва/код установи, хости),
    # потім ім'я машини, користувач і домен. Найдовші першими, щоб коротший
    # збіг не з'їв частину довшого. Мінімальна довжина 3 для імен
    # машини/користувача — інакше ім'я "a" зіпсувало б увесь текст.
    $named = New-Object System.Collections.Generic.List[object]
    foreach ($id in @($SiteIdentifiers)) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $trimmed = $id.Trim()
        if ($trimmed.Length -ge 2) { $named.Add(@{ Kind = 'site'; Token = '<redacted:site>'; Value = $trimmed }) }
    }
    $machine = [string][Environment]::MachineName
    if ($machine.Length -ge 3) { $named.Add(@{ Kind = 'host'; Token = '<redacted:host>'; Value = $machine }) }
    $userName = [string][Environment]::UserName
    if ($userName.Length -ge 3) { $named.Add(@{ Kind = 'user'; Token = '<redacted:user>'; Value = $userName }) }
    $domainName = [string][Environment]::UserDomainName
    if ($domainName.Length -ge 3) { $named.Add(@{ Kind = 'domain'; Token = '<redacted:domain>'; Value = $domainName }) }

    foreach ($entry in @($named | Sort-Object -Property @{ Expression = { $_.Value.Length }; Descending = $true })) {
        $namePattern = '(?i)(?<![\w])' + [regex]::Escape($entry.Value) + '(?![\w])'
        $n = ([regex]::Matches($value, $namePattern)).Count
        if ($n -gt 0) {
            $value = [regex]::Replace($value, $namePattern, $entry.Token)
            $counts[$entry.Kind] += $n
        }
    }

    return [pscustomobject]@{ Text = $value; Counts = $counts }
}

function Protect-BRAVOUpdateReportText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [AllowNull()][AllowEmptyCollection()][string[]]$SiteIdentifiers
    )

    $result = Invoke-BRAVOUpdateReportRedaction -Text $Text -SiteIdentifiers $SiteIdentifiers
    return $result.Text
}

function Get-BRAVOUpdateLogTail {
    # Pure read: хвости найновіших *.log під LOGS root. Журнали можуть бути
    # відкриті власником запису, тому FileShare.ReadWrite (+Delete), і читаємо
    # лише обмежений хвіст файлу — не весь багатогігабайтний журнал.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][string]$LogRoot,
        [ValidateRange(1, 5000)][int]$MaxLines = 200,
        [ValidateRange(1, 20)][int]$MaxFiles = 3,
        [ValidateRange(1024, 4194304)][int]$MaxBytesPerFile = 262144
    )

    if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
        return @()
    }

    $files = @(Get-ChildItem -LiteralPath $LogRoot -Filter '*.log' -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { 0 -eq ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            Sort-Object -Property LastWriteTimeUtc -Descending |
            Select-Object -First $MaxFiles)

    # Від найстаршого з відібраних до найновішого — хронологічний порядок.
    [array]::Reverse($files)
    $collected = New-Object System.Collections.Generic.List[string]
    foreach ($file in $files) {
        $stream = $null
        try {
            $stream = New-Object System.IO.FileStream($file.FullName,
                [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            $length = $stream.Length
            $start = [Math]::Max([long]0, $length - $MaxBytesPerFile)
            [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin)
            $buffer = New-Object byte[] ([int]($length - $start))
            $read = 0
            while ($read -lt $buffer.Length) {
                $got = $stream.Read($buffer, $read, $buffer.Length - $read)
                if ($got -le 0) { break }
                $read += $got
            }
            $text = (New-Object System.Text.UTF8Encoding($false)).GetString($buffer, 0, $read)
            $lines = @($text -split "\r?\n")
            # Хвіст міг починатися посеред рядка (або посеред UTF-8
            # символу) — перший неповний рядок відкидаємо.
            if ($start -gt 0 -and $lines.Count -gt 1) { $lines = @($lines | Select-Object -Skip 1) }
            if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
                $lines = @($lines | Select-Object -First ($lines.Count - 1))
            }
            foreach ($line in $lines) { $collected.Add([string]$line) }
        }
        catch {
            # Недоступний файл не ламає звіт — фіксуємо факт без шляху.
            $collected.Add('[журнал недоступний для читання: ' + $file.Name + ']')
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }

    $all = $collected.ToArray()
    if ($all.Length -gt $MaxLines) {
        return @($all[($all.Length - $MaxLines)..($all.Length - 1)])
    }
    return @($all)
}

function New-BRAVOUpdateDiagFinding {
    [CmdletBinding()]
    param($Finding, [scriptblock]$Redact)

    $severity = [string](Get-BRAVOUpdateDiagValue -Object $Finding -Name 'severity' -Default 'Warning')
    return [pscustomobject][ordered]@{
        id       = & $Redact ([string](Get-BRAVOUpdateDiagValue -Object $Finding -Name 'id' -Default ''))
        severity = $severity
        title    = & $Redact ([string](Get-BRAVOUpdateDiagValue -Object $Finding -Name 'title' -Default ''))
        meaning  = & $Redact ([string](Get-BRAVOUpdateDiagValue -Object $Finding -Name 'meaning' -Default ''))
        action   = & $Redact ([string](Get-BRAVOUpdateDiagValue -Object $Finding -Name 'action' -Default ''))
        details  = & $Redact ([string](Get-BRAVOUpdateDiagValue -Object $Finding -Name 'details' -Default ''))
    }
}

function New-BRAVODiagnosticReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$InstallationState,
        [Parameter(Mandatory = $true)]$Preflight,
        [AllowNull()][AllowEmptyCollection()]$RecentResults,
        [AllowNull()][AllowEmptyCollection()][string[]]$LogTail,
        [AllowNull()][AllowEmptyCollection()][string[]]$SiteIdentifiers
    )

    $totals = [ordered]@{
        credential = 0; fingerprint = 0; email = 0; unc = 0; ip = 0
        site = 0; host = 0; user = 0; domain = 0
    }
    # Кожен рядок звіту проходить через єдиний redactor; лічильники
    # накопичуються в $totals (посилальний тип, тож closure бачить зміни).
    $redact = {
        param([AllowNull()]$Value)
        if ($null -eq $Value) { return '' }
        $r = Invoke-BRAVOUpdateReportRedaction -Text ([string]$Value) -SiteIdentifiers $SiteIdentifiers
        foreach ($k in @($r.Counts.Keys)) { $totals[$k] += $r.Counts[$k] }
        return $r.Text
    }.GetNewClosure()

    $sections = New-Object System.Collections.Generic.List[object]
    $addSection = {
        param([string]$Title, [string[]]$Lines, $Findings)
        $sections.Add([pscustomobject][ordered]@{
                title    = $Title
                lines    = @($Lines)
                findings = @($Findings)
            })
    }.GetNewClosure()

    # --- Загальне ---
    $version = Get-BRAVOUpdateDiagValue -Object $InstallationState -Name 'version'
    $general = @(
        ('Стан встановлення: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $InstallationState -Name 'state' -Default 'Unknown'))),
        ('Кореневий каталог: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $InstallationState -Name 'runtimeRoot' -Default '(не визначено)'))),
        ('Версія пакета: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $version -Name 'packageVersion' -Default '(невідомо)'))),
        ('Канал: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $version -Name 'releaseChannel' -Default '(невідомо)'))),
        ('Збірка: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $version -Name 'buildId' -Default '(невідомо)'))),
        ('Дата релізу: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $version -Name 'releaseDate' -Default '(невідомо)'))),
        ('ОС: ' + (& $redact ([Environment]::OSVersion.VersionString))),
        ('PowerShell: ' + (& $redact ($PSVersionTable.PSVersion.ToString())))
    )
    foreach ($candidateRoot in @(Get-BRAVOUpdateDiagValue -Object $InstallationState -Name 'candidateRoots' -Default @())) {
        $general += ('Знайдений каталог: ' + (& $redact $candidateRoot))
    }
    & $addSection 'Загальне' $general @()

    # --- Цілісність ---
    $integrity = Get-BRAVOUpdateDiagValue -Object $InstallationState -Name 'integrity'
    $integrityLines = @(
        ('Статус: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $integrity -Name 'status' -Default 'Unknown'))),
        ('Перевірено: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $integrity -Name 'checkedCount' -Default 0))),
        ('Не збігається: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $integrity -Name 'mismatchedCount' -Default 0))),
        ('Відсутні: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $integrity -Name 'missingCount' -Default 0))),
        ('Повідомлення: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $integrity -Name 'message' -Default '')))
    )
    & $addSection 'Цілісність' $integrityLines @()

    # --- Конфігурація ---
    $config = Get-BRAVOUpdateDiagValue -Object $InstallationState -Name 'configuration'
    $configLines = @(
        ('Локальна конфігурація: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $config -Name 'localConfigPresent' -Default 'невідомо'))),
        ('Застаріла (legacy) конфігурація: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $config -Name 'legacyConfigPresent' -Default 'невідомо'))),
        ('Схема локальної конфігурації валідна: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $config -Name 'localConfigSchemaValid' -Default 'невідомо')))
    )
    $migration = Get-BRAVOUpdateDiagValue -Object $config -Name 'migrationBlocker'
    $configLines += ('Блокер міграції: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $migration -Name 'blocked' -Default 'невідомо')))
    foreach ($reason in @(Get-BRAVOUpdateDiagValue -Object $migration -Name 'reasons' -Default @())) {
        $configLines += ('  причина: ' + (& $redact $reason))
    }
    & $addSection 'Конфігурація' $configLines @()

    # --- Планувальник (лише факти про задачі, без облікових записів) ---
    $scheduler = Get-BRAVOUpdateDiagValue -Object $InstallationState -Name 'scheduler'
    $schedLines = @('Статус: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $scheduler -Name 'status' -Default 'Unknown')))
    foreach ($task in @(Get-BRAVOUpdateDiagValue -Object $scheduler -Name 'tasks' -Default @())) {
        $schedLines += ('Задача ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $task -Name 'name' -Default '?')) +
            ': існує=' + (& $redact (Get-BRAVOUpdateDiagValue -Object $task -Name 'exists' -Default '?')) +
            ', стан=' + (& $redact (Get-BRAVOUpdateDiagValue -Object $task -Name 'state' -Default '?')) +
            ', увімкнена=' + (& $redact (Get-BRAVOUpdateDiagValue -Object $task -Name 'enabled' -Default '?')))
    }
    & $addSection 'Планувальник' $schedLines @()

    # --- Облікові дані: лише наявність, без значень ---
    $credentials = Get-BRAVOUpdateDiagValue -Object $InstallationState -Name 'credentials'
    $credLines = @('Статус: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $credentials -Name 'status' -Default 'Unknown')))
    foreach ($item in @(Get-BRAVOUpdateDiagValue -Object $credentials -Name 'items' -Default @())) {
        $credLines += ((& $redact (Get-BRAVOUpdateDiagValue -Object $item -Name 'component' -Default '?')) +
            ': ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $item -Name 'credentialPresence' -Default 'Unknown')))
    }
    & $addSection 'Облікові дані (лише наявність)' $credLines @()

    # --- Перервана операція / lock ---
    $interrupted = Get-BRAVOUpdateDiagValue -Object $InstallationState -Name 'interruptedOperation'
    $lock = Get-BRAVOUpdateDiagValue -Object $InstallationState -Name 'lifecycleLock'
    $opLines = @(
        ('Перервана операція: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $interrupted -Name 'present' -Default $false))),
        ('Остання завершена фаза: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $interrupted -Name 'lastCompletedPhase' -Default '(немає)'))),
        ('Зміни розпочато: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $interrupted -Name 'mutationStarted' -Default $false))),
        ('Lifecycle lock утримується: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $lock -Name 'held' -Default $false)))
    )
    & $addSection 'Операції' $opLines @()

    # --- Знахідки стану та preflight ---
    $stateFindings = @()
    foreach ($f in @(Get-BRAVOUpdateDiagValue -Object $InstallationState -Name 'findings' -Default @())) {
        $stateFindings += New-BRAVOUpdateDiagFinding -Finding $f -Redact $redact
    }
    & $addSection 'Знахідки стану' @() $stateFindings

    $preflightFindings = @()
    foreach ($f in @(Get-BRAVOUpdateDiagValue -Object $Preflight -Name 'findings' -Default @())) {
        $preflightFindings += New-BRAVOUpdateDiagFinding -Finding $f -Redact $redact
    }
    $preflightLines = @(
        ('Можна продовжувати: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $Preflight -Name 'canProceed' -Default 'невідомо'))),
        ('Блокерів: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $Preflight -Name 'blockerCount' -Default 0))),
        ('Попереджень: ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $Preflight -Name 'warningCount' -Default 0)))
    )
    & $addSection 'Передперевірка (preflight)' $preflightLines $preflightFindings

    # --- Останні результати ---
    $resultLines = @()
    foreach ($r in @($RecentResults)) {
        if ($null -eq $r) { continue }
        $resultLines += ((& $redact (Get-BRAVOUpdateDiagValue -Object $r -Name 'finishedUtc' -Default '?')) +
            ' ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $r -Name 'action' -Default '?')) +
            ': ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $r -Name 'status' -Default '?')) +
            ', код ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $r -Name 'exitCode' -Default '?')) +
            ', остання фаза ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $r -Name 'lastPhase' -Default '?')) +
            ', версія ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $r -Name 'sourceVersion' -Default '?')) +
            ' -> ' + (& $redact (Get-BRAVOUpdateDiagValue -Object $r -Name 'targetVersion' -Default '?')))
    }
    if ($resultLines.Count -eq 0) { $resultLines = @('(немає записів)') }
    & $addSection 'Останні результати' $resultLines @()

    # --- Хвіст журналу ---
    $tailLines = @()
    foreach ($line in @($LogTail)) {
        if ($null -eq $line) { continue }
        $tailLines += (& $redact $line)
    }
    if ($tailLines.Count -eq 0) { $tailLines = @('(журнал порожній або недоступний)') }
    & $addSection 'Хвіст журналу' $tailLines @()

    $report = [pscustomobject][ordered]@{
        schemaVersion     = $script:BRAVOUpdateDiagnosticReportSchemaVersion
        generatedUtc      = [DateTime]::UtcNow.ToString('o')
        sections          = $sections.ToArray()
        redactionsApplied = [pscustomobject]$totals
    }
    # Канонічна перевірка «секретних» імен властивостей на готовому звіті.
    $check = Test-BRAVOUpdateNoSecretProperty $report
    $report | Add-Member -NotePropertyName 'containsSecretsCheck' -NotePropertyValue $check
    return $report
}

function Get-BRAVOUpdateDiagMarkerText {
    # Маркер із текстом: ✓/!/×/— разом з назвою (не лише символ/колір).
    [CmdletBinding()]
    param([string]$Severity)

    $text = switch ($Severity) {
        'Ok' { 'Гаразд' }
        'Warning' { 'Увага' }
        'Blocker' { 'Блокер' }
        'NotApplicable' { 'Не застосовується' }
        default { $Severity }
    }
    $marker = $null
    if ($null -ne (Get-Command -Name 'Format-BRAVOUpdateFindingMarker' -ErrorAction SilentlyContinue)) {
        $marker = [string](Format-BRAVOUpdateFindingMarker -Severity $Severity)
    }
    if ([string]::IsNullOrEmpty($marker)) { $marker = '?' }
    return ($marker + ' ' + $text)
}

function Format-BRAVODiagnosticReportText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)]$Report)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('=== Діагностичний звіт BRAVO Installer ===')
    [void]$builder.AppendLine('Сформовано (UTC): ' + [string](Get-BRAVOUpdateDiagValue -Object $Report -Name 'generatedUtc' -Default ''))
    [void]$builder.AppendLine('Звіт створено лише для читання; нічого не змінено й нікуди не надіслано.')
    [void]$builder.AppendLine('Секрети та ідентифікатори майданчика замасковано; перегляньте текст перед передачею.')
    foreach ($section in @(Get-BRAVOUpdateDiagValue -Object $Report -Name 'sections' -Default @())) {
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('--- ' + [string](Get-BRAVOUpdateDiagValue -Object $section -Name 'title' -Default '') + ' ---')
        foreach ($line in @(Get-BRAVOUpdateDiagValue -Object $section -Name 'lines' -Default @())) {
            [void]$builder.AppendLine([string]$line)
        }
        foreach ($f in @(Get-BRAVOUpdateDiagValue -Object $section -Name 'findings' -Default @())) {
            $sev = [string](Get-BRAVOUpdateDiagValue -Object $f -Name 'severity' -Default '')
            [void]$builder.AppendLine((Get-BRAVOUpdateDiagMarkerText -Severity $sev) + ': ' + [string](Get-BRAVOUpdateDiagValue -Object $f -Name 'title' -Default ''))
            foreach ($pair in @(@('Що це означає', 'meaning'), @('Що зробити', 'action'), @('Подробиці', 'details'))) {
                $v = [string](Get-BRAVOUpdateDiagValue -Object $f -Name $pair[1] -Default '')
                if ($v -ne '') { [void]$builder.AppendLine('    ' + $pair[0] + ': ' + $v) }
            }
        }
    }
    $applied = Get-BRAVOUpdateDiagValue -Object $Report -Name 'redactionsApplied'
    if ($null -ne $applied) {
        $parts = @($applied.PSObject.Properties | Where-Object { [int]$_.Value -gt 0 } | ForEach-Object { $_.Name + '=' + $_.Value })
        [void]$builder.AppendLine('')
        $summary = 'Замасковано: '
        if ($parts.Count -eq 0) { $summary += 'нічого' } else { $summary += ($parts -join ', ') }
        [void]$builder.AppendLine($summary)
    }
    return $builder.ToString()
}

function Save-BRAVODiagnosticReport {
    # Запис лише в ЯВНИЙ шлях, обраний оператором. Не перезаписує наявний
    # файл без -Force і ніколи не пише всередину runtime root (звіт не має
    # стати частиною manifest-керованого runtime).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$RuntimeRoot,
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Save-BRAVODiagnosticReport: шлях збереження не вказано.'
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath.EndsWith('\') -or $fullPath.EndsWith('/') -or (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "Save-BRAVODiagnosticReport: шлях має вказувати на файл, а не каталог: $fullPath"
    }

    $forbidden = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($RuntimeRoot)) { if (-not [string]::IsNullOrWhiteSpace($r)) { $forbidden.Add($r) } }
    $forbidden.Add($script:BRAVOUpdateToolkitRoot)
    if ($null -ne (Get-Command -Name 'Get-BRAVOUpdateDefaultPaths' -ErrorAction SilentlyContinue)) {
        $defaults = Get-BRAVOUpdateDefaultPaths
        $defaultRuntime = Get-BRAVOUpdateDiagValue -Object $defaults -Name 'RuntimeRoot'
        if ($null -ne $defaultRuntime) { $forbidden.Add([string]$defaultRuntime) }
    }
    foreach ($candidate in $forbidden) {
        $rootFull = [IO.Path]::GetFullPath($candidate).TrimEnd('\', '/')
        if ($fullPath.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Save-BRAVODiagnosticReport: збереження звіту всередині runtime каталогу заборонено ($rootFull). Оберіть інше місце."
        }
    }

    if ((Test-Path -LiteralPath $fullPath) -and -not $Force) {
        throw "Save-BRAVODiagnosticReport: файл уже існує ($fullPath); використайте -Force лише якщо перезапис навмисний."
    }

    $text = Format-BRAVODiagnosticReportText -Report $Report
    # Write-BRAVOUpdateFileAtomic пише UTF-8 без BOM (tmp + replace).
    Write-BRAVOUpdateFileAtomic -Path $fullPath -Text $text
    return [pscustomobject]@{ Path = $fullPath; Bytes = (New-Object System.Text.UTF8Encoding($false)).GetByteCount($text) }
}
