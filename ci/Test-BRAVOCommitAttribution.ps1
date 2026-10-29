[CmdletBinding()]
param(
    [string]$Root,

    # Явний діапазон git (`<base>..<head>`) для локального запуску й регресій.
    # Без нього діапазон береться з події GitHub (GITHUB_EVENT_NAME/GITHUB_EVENT_PATH).
    [string]$Range,

    # Лише для self-test: базова лінія тимчасового репозиторію замість
    # канонічної (у тимчасовому репозиторії канонічного коміту немає).
    [string[]]$Baseline = @()
)

# Гейт AI-атрибуції в повідомленнях комітів. Атрибуцію інструментів AI
# (трейлери Co-Authored-By на AI-інструмент, Claude-Session/AI-assisted,
# футер "Generated with/by ...", посилання на сесії й чати, адреса
# noreply AI-провайдера в авторі чи комітері) у продуктовій історії
# заборонено. Перевіряються лише нові коміти: діапазон PR (base..head) або
# push (before..after). Історію до запровадження гейту не переписуємо.
#
# Fail closed: якщо діапазон не визначено чи git не може його перелічити,
# гейт падає, а не пропускає. Вивід називає SHA і правило, але не повторює
# текст рядка (посилання на сесію не потрапляє в лог CI).
#
# Окремий файл, а не `run:` у ci.yml: `run:` записується без BOM, і Windows
# PowerShell 5.1 ламає кириличні рядки (див. ci\Test-BRAVOForbiddenPattern.ps1).

$ErrorActionPreference = 'Stop'

# Базова лінія: коміти, досяжні з неї, створені до гейту й не перевіряються.
# Без неї промоція developer -> master (PR і push) несла б сотні історичних
# комітів і падала б назавжди. Це вершина developer на момент запровадження
# гейту; master тоді був її предком. Нові коміти поза базовою лінією
# перевіряються завжди. Базова лінія не змінюється, щоб не амністувати нові
# коміти.
$script:BRAVOCommitAttributionBaseline = @('1c45476c348086bd2d65f9d6e410a47ac347a003')

function Get-BRAVOCommitAttributionViolation {
    <#
        Чиста функція: правила, порушені одним комітом. Message - повне
        повідомлення (%B), AuthorEmail/CommitterEmail - адреси. Повертає
        масив ідентифікаторів правил (порожній = чисто). Регістр не важить.
        Трейлери перевіряються лише на початку рядка, тож опис самого правила
        в тексті коміту ("забороняє трейлер Co-Authored-By") не спрацьовує.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Message,
        [AllowNull()][AllowEmptyString()][string]$AuthorEmail,
        [AllowNull()][AllowEmptyString()][string]$CommitterEmail
    )

    $aiTool = '(?:claude|anthropic|codex|openai|chatgpt|copilot|gemini)'
    # Співавтор - AI, коли ВСЕ ім'я є назвою інструмента (з необов'язковими моделлю
    # чи версією: "Claude", "Claude Opus 4.5", "GitHub Copilot") або адреса - службова
    # noreply AI-провайдера чи бота GitHub. Підрядок не рахується: людина
    # "Claude Martin" чи адреса @openai.com співавтором-AI не є (PR #531, P2).
    $aiCoAuthorName = '(?i)^(?:github[ \t]+)?' + $aiTool + '(?:[ \t]+(?:code|cli|agent|assistant|opus|sonnet|haiku|fable|pro|ultra|flash|[0-9][0-9.]*))*(?:\[bot\])?$'
    $aiCoAuthorEmail = '(?i)^(?:noreply@(?:anthropic|openai)\.com|(?:[0-9]+\+)?' + $aiTool + '(?:-[a-z0-9-]+)?(?:\[bot\])?@users\.noreply\.github\.com)$'
    $rules = [ordered]@{
        'SESSION_TRAILER'     = '(?im)^[ \t]*claude-session:'
        'AI_ASSISTED_TRAILER' = '(?im)^[ \t]*ai-assisted:'
        # Футер - рядок, де перед "Generated" немає літер (емодзі, пробіли); інакше
        # опис самого правила в прозі ("пояснює, чому Generated with ... заборонено")
        # давав би хибне спрацювання.
        # "GitHub Copilot" - назва продукту з префіксом (Codex QA-001, PR #531).
        'GENERATED_BY_AI'     = '(?im)^[^\p{L}\r\n]*generated[ \t]+(?:with|by)[ \t]+\[?[ \t]*(?:github[ \t]+)?' + $aiTool
        'AI_SESSION_LINK'     = '(?i)https?://(?:www\.)?(?:claude\.ai/(?:code|chat|share|project)|claude\.com/claude-code|chatgpt\.com/(?:c|share|codex)/)'
    }

    $violations = New-Object System.Collections.Generic.List[string]
    $text = if ($null -eq $Message) { '' } else { $Message }
    # \r? перед кінцем рядка: вивід git show у PowerShell приходить із CRLF, а $ у
    # режимі (?m) стоїть лише перед \n.
    foreach ($trailer in [regex]::Matches($text, '(?im)^[ \t]*co-authored-by:[ \t]*([^<\r\n]*?)[ \t]*(?:<([^>\r\n]*)>)?[ \t]*\r?$')) {
        $coAuthorName = $trailer.Groups[1].Value.Trim()
        $coAuthorEmail = $trailer.Groups[2].Value.Trim()
        if ($coAuthorName -match $aiCoAuthorName -or ($coAuthorEmail.Length -gt 0 -and $coAuthorEmail -match $aiCoAuthorEmail)) {
            [void]$violations.Add('CO_AUTHORED_BY_AI')
            break
        }
    }
    # Службова AI-адреса рахується лише як ідентичність у трейлері ("Ключ: Ім'я <адреса>"),
    # а не будь-де в тексті: опис правила в прозі не є атрибуцією (Codex QA-002, PR #531).
    foreach ($trailer in [regex]::Matches($text, '(?im)^[ \t]*[a-z][a-z0-9-]*:[^<\r\n]*<([^>\r\n]*)>[ \t]*\r?$')) {
        if ($trailer.Groups[1].Value.Trim() -match $aiCoAuthorEmail) {
            [void]$violations.Add('AI_NOREPLY_ADDRESS')
            break
        }
    }
    foreach ($rule in $rules.Keys) {
        if ($text -match $rules[$rule]) { [void]$violations.Add($rule) }
    }
    foreach ($identity in @(@{ Name = 'AUTHOR'; Email = $AuthorEmail }, @{ Name = 'COMMITTER'; Email = $CommitterEmail })) {
        if ([string]::IsNullOrEmpty($identity.Email)) { continue }
        # Керівні символи в адресі git зберігає, але вони роблять поле неоднозначним:
        # fail closed (Codex SEC-001, PR #531).
        if ($identity.Email -match '[\x00-\x1f\x7f]') {
            [void]$violations.Add('MALFORMED_' + $identity.Name + '_IDENTITY')
            continue
        }
        # Та сама політика службових адрес, що й для співавторів (PR #531, P2).
        if ($identity.Email.Trim() -match $aiCoAuthorEmail) {
            [void]$violations.Add('AI_' + $identity.Name + '_IDENTITY')
        }
    }
    return $violations.ToArray()
}

function Get-BRAVOCommitAttributionRange {
    <#
        Діапазон комітів події GitHub. Повертає { Range; Error }: Range -
        аргументи для git rev-list; Error - причина, чому діапазон не
        визначено (fail closed у викликача). Для не-PR/не-push події та
        видалення гілки Range і Error порожні (перевіряти нічого).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$EventName,
        [AllowNull()][AllowEmptyString()][string]$EventPath,
        [AllowNull()][AllowEmptyString()][string]$RefName
    )

    $result = [pscustomobject]@{ Range = @(); Error = '' }
    if ($EventName -notin @('pull_request', 'pull_request_target', 'push')) { return $result }
    if ([string]::IsNullOrWhiteSpace($EventPath) -or -not (Test-Path -LiteralPath $EventPath -PathType Leaf)) {
        $result.Error = "подія $EventName без GITHUB_EVENT_PATH"
        return $result
    }
    try {
        $payload = Get-Content -LiteralPath $EventPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $result.Error = "не вдалося розпарсити GITHUB_EVENT_PATH: $($_.Exception.Message)"
        return $result
    }
    $shaPattern = '^[0-9a-f]{40}$'
    if ($EventName -like 'pull_request*') {
        $base = [string]$payload.pull_request.base.sha
        $head = [string]$payload.pull_request.head.sha
        if ($base -notmatch $shaPattern -or $head -notmatch $shaPattern) {
            $result.Error = 'у payload pull_request немає base.sha/head.sha'
            return $result
        }
        $result.Range = @("$base..$head")
        return $result
    }
    $before = [string]$payload.before
    $after = [string]$payload.after
    if ($after -notmatch $shaPattern) {
        $result.Error = 'у payload push немає after'
        return $result
    }
    if ($after -match '^0{40}$') { return $result }  # видалення гілки: нових комітів немає
    if ($before -match $shaPattern -and $before -notmatch '^0{40}$') {
        $result.Range = @("$before..$after")
        return $result
    }
    # Нова гілка: коміти, яких немає в жодній іншій гілці origin.
    if ([string]::IsNullOrWhiteSpace($RefName)) {
        $result.Error = 'push нової гілки без GITHUB_REF_NAME'
        return $result
    }
    # Шаблон --exclude для --remotes пишеться без префікса refs/remotes/; із
    # префіксом сама нова гілка лишалась би негативною й ховала всі свої коміти.
    $result.Range = @($after, '--not', "--exclude=origin/$RefName", '--remotes=origin')
    return $result
}

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path -LiteralPath (Join-Path $Root 'BRAVO_SELF_TEST.ps1') -PathType Leaf)) {
    Write-Host "::error::Не схоже на корінь репозиторію BRAVO (немає BRAVO_SELF_TEST.ps1): $Root"
    exit 1
}

if ($Baseline.Count -gt 0) { $script:BRAVOCommitAttributionBaseline = @($Baseline) }

if (-not [string]::IsNullOrWhiteSpace($Range)) {
    $revArgs = @($Range)
} else {
    $resolved = Get-BRAVOCommitAttributionRange `
        -EventName ([Environment]::GetEnvironmentVariable('GITHUB_EVENT_NAME')) `
        -EventPath ([Environment]::GetEnvironmentVariable('GITHUB_EVENT_PATH')) `
        -RefName ([Environment]::GetEnvironmentVariable('GITHUB_REF_NAME'))
    if ($resolved.Error -ne '') {
        Write-Host "::error::COMMIT_ATTRIBUTION_RANGE_UNKNOWN: $($resolved.Error)"
        exit 1
    }
    $revArgs = @($resolved.Range)
    if ($revArgs.Count -eq 0) {
        Write-Host 'Не PR/push-подія і -Range не задано - перевіряти нічого.'
        exit 0
    }
}
Write-Host ("Діапазон: " + ($revArgs -join ' '))

$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    foreach ($baseline in $script:BRAVOCommitAttributionBaseline) {
        $null = & git -C $Root cat-file -e "$baseline^{commit}" 2>&1
        if ($LASTEXITCODE -ne 0) {
            # Без базової лінії в історію потрапили б історичні коміти, а мовчки
            # пропустити її - означало б не знати, що саме перевірено.
            Write-Host "::error::COMMIT_ATTRIBUTION_RANGE_UNKNOWN: базового коміту $baseline немає в checkout (потрібна повна історія, fetch-depth: 0)"
            exit 1
        }
    }
    # ^<базова лінія> стоїть ПЕРЕД діапазоном: --not у діапазоні нової гілки
    # інвертував би все, що після нього, і базова лінія стала б позитивною.
    $baselineArgs = @($script:BRAVOCommitAttributionBaseline | ForEach-Object { '^' + $_ })
    $shaOutput = & git -C $Root rev-list @baselineArgs @revArgs 2>&1
    $revListExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorAction
}
if ($revListExit -ne 0) {
    Write-Host "::error::COMMIT_ATTRIBUTION_RANGE_UNKNOWN: git rev-list завершився з кодом $revListExit (неповна історія checkout?)"
    exit 1
}
$shas = @($shaOutput | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^[0-9a-f]{40}$' })
Write-Host "Комітів у діапазоні: $($shas.Count)"

$failed = 0
foreach ($sha in $shas) {
    # Кожне поле - окремим викликом: роздільник в одному форматі можна підробити
    # тим самим символом усередині адреси й зсунути поля (Codex SEC-001, PR #531).
    $fields = @{}
    $readFailed = $false
    foreach ($field in @(@{ Key = 'Author'; Format = '--format=%ae' }, @{ Key = 'Committer'; Format = '--format=%ce' }, @{ Key = 'Message'; Format = '--format=%B' })) {
        $ErrorActionPreference = 'Continue'
        try {
            $value = (& git -C $Root -c i18n.logOutputEncoding=UTF-8 show -s --no-show-signature $field.Format $sha 2>$null | Out-String)
            $showExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorAction
        }
        if ($showExit -ne 0) { $readFailed = $true; break }
        # Out-String додає кінцевий розрив рядка; для адрес він не належить полю.
        $fields[$field.Key] = if ($field.Key -eq 'Message') { $value } else { $value.TrimEnd("`r", "`n") }
    }
    if ($readFailed) {
        Write-Host "::error::COMMIT_ATTRIBUTION_READ_FAILED: $sha (git show, код $showExit)"
        $failed++
        continue
    }
    $hits = @(Get-BRAVOCommitAttributionViolation -AuthorEmail $fields['Author'] -CommitterEmail $fields['Committer'] -Message $fields['Message'])
    if ($hits.Count -gt 0) {
        Write-Host ("::error::COMMIT_ATTRIBUTION_FORBIDDEN: {0} [{1}]" -f $sha.Substring(0, 12), ($hits -join ', '))
        $failed++
    }
}

if ($failed -gt 0) {
    Write-Host "AI-атрибуція в комітах заборонена: виправте повідомлення ($failed коміт(ів)) і оновіть гілку."
    exit 1
}
Write-Host "COMMIT_ATTRIBUTION ($($shas.Count)): AI-атрибуції не знайдено."
exit 0
