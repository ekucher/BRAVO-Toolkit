<#
    validate-agent-routing.ps1
    Хук PreToolUse для Claude Code — детермінований enforcement матриці
    .claude/ai-routing.json.

    Отримує на stdin JSON із полями session_id, cwd, hook_event_name,
    tool_name і tool_input. Для tool_name = "Task" перевіряє делегування
    агентам BRAVO; для викликів mcp__codex-agent__* лише аудитує.

    Контракт виходу (конвенція PreToolUse у Claude Code):
        exit 0 — виклик дозволено;
        exit 2 — виклик заблоковано, текст причини йде у stderr.

    Блокує вузький закритий список порушень:
      1. модель виклику не відповідає матриці;
      2. Claude-агента брифують як формальний Codex-гейт
         (review_source: codex-*) — такий гейт закриває лише Codex;
      3. режим claude-qa-fallback без причини з трьох дозволених
         (quota | rate-limit | service-unavailable);
      4. агент documentation отримує SCOPE поза своїми межами запису
         (acceptance-докази, runbook-и, канон, код, манифести).

    Решта викликів — у журнал .claude/logs/ai-routing.log, без блокування.
    Агенти, відсутні в матриці (Explore, general-purpose, плагінні), не
    блокуються ніколи.

    Власна помилка хука (відсутня/пошкоджена матриця, збій розбору stdin):
    fail-closed для гейт-критичних ролей reviewer/architect/security-reviewer,
    fail-open для решти — одна помилка в JSON не повинна паралізувати сесію,
    але й не повинна відкривати шлях підміненому гейту.

    Викликати обов'язково з -NoProfile: вивід профілю PowerShell ламає
    розбір stdin.
#>
$ErrorActionPreference = 'Stop'

# Гейт-критичні роли дублюються тут навмисно: цей список потрібен саме тоді,
# коли матрицю прочитати не вдалося. Test-AIRouting.ps1 звіряє його з
# enforcement.failClosedRoles у матриці.
$script:FailClosedRoles = @('reviewer', 'architect', 'security-reviewer')
$script:CodexToolPrefix = 'mcp__codex-agent__'

function Resolve-ProjectDir {
    param([string]$CwdFromPayload)

    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR)) { return $env:CLAUDE_PROJECT_DIR }
    if (-not [string]::IsNullOrWhiteSpace($CwdFromPayload)) { return $CwdFromPayload }
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Write-RoutingLog {
    param(
        [string]$ProjectDir,
        [string]$Decision,
        [string]$Tool,
        [string]$Agent,
        [string]$Model,
        [string]$Reason
    )

    # Журнал — допоміжний. Його збій не повинен впливати на рішення хука.
    try {
        $logDir = Join-Path $ProjectDir '.claude\logs'
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $line = '{0} | {1} | tool={2} | agent={3} | model={4} | {5}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Decision, $Tool, $Agent, $Model, $Reason
        Add-Content -LiteralPath (Join-Path $logDir 'ai-routing.log') -Value $line -Encoding UTF8
    }
    catch {
        # свідомо проглочено
    }
}

function Deny-Call {
    param(
        [string]$ProjectDir,
        [string]$Tool,
        [string]$Agent,
        [string]$Model,
        [string]$Reason
    )

    Write-RoutingLog -ProjectDir $ProjectDir -Decision 'BLOCK' -Tool $Tool -Agent $Agent -Model $Model -Reason $Reason
    [Console]::Error.WriteLine("BRAVO routing policy blocked this call: $Reason")
    [Console]::Error.WriteLine('Canonical rules: BRAVO_AGENT_POLICY.md, matrix: .claude/ai-routing.json')
    exit 2
}

function Approve-Call {
    param(
        [string]$ProjectDir,
        [string]$Tool,
        [string]$Agent,
        [string]$Model,
        [string]$Reason
    )

    Write-RoutingLog -ProjectDir $ProjectDir -Decision 'ALLOW' -Tool $Tool -Agent $Agent -Model $Model -Reason $Reason
    exit 0
}

function Get-ScopeToken {
    <#
        Витягує шляхи з блоку SCOPE: у брифі. Продовження блоку триває до
        наступного ключа у верхньому регістрі (OBJECTIVE:, ACCEPTANCE: тощо).
    #>
    param([string]$Prompt)

    $tokens = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return $tokens }

    $inScope = $false
    foreach ($rawLine in ($Prompt -split "`r?`n")) {
        $line = $rawLine.Trim()

        if ($line -match '^(?i)SCOPE\s*:\s*(.*)$') {
            $inScope = $true
            $line = $Matches[1]
        }
        elseif ($inScope -and $line -match '^[A-Z_]{3,}\s*:') {
            $inScope = $false
            continue
        }
        elseif (-not $inScope) {
            continue
        }

        foreach ($piece in ($line -split '[,;\s]+')) {
            $token = $piece.Trim().Trim('`', '"', "'", '*', '-', '(', ')', '[', ']')
            if ([string]::IsNullOrWhiteSpace($token)) { continue }
            if ($token -notmatch '[\\/.]') { continue }
            $tokens.Add((ConvertTo-NormalizedScopePath -Path $token))
        }
    }

    return $tokens
}

function ConvertTo-NormalizedScopePath {
    <#
        Нормалізує шлях зі SCOPE перед перевіркою меж запису: уніфікує
        розділювачі, прибирає './' і логічно згортає '..'.

        Без цього 'docs/../AGENTS.md' проходив би перевірку, бо літерально
        відповідає writeAllow-патерну 'docs/*' і не відповідає жодному
        writeDeny-патерну, хоча фактично вказує на канонічну політику поза
        межами запису. Згортання робиться логічно (не через Resolve-Path): шлях
        у брифі може ще не існувати на диску, а перевірка межі не повинна
        залежати від того, створений файл чи ні.

        Якщо шлях виходить за корінь (лишається провідний '..'), повертається
        рядок із провідним '../', і жоден writeAllow-патерн його не покриє —
        тобто виклик буде заблокований.
    #>
    param([string]$Path)

    $value = ($Path -replace '\\', '/')
    $isRooted = $value.StartsWith('/')

    $segments = New-Object System.Collections.Generic.List[string]
    foreach ($segment in ($value -split '/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -ceq '.') { continue }
        if ($segment -ceq '..') {
            if ($segments.Count -gt 0 -and $segments[$segments.Count - 1] -cne '..') {
                $segments.RemoveAt($segments.Count - 1)
            }
            else {
                $segments.Add('..')
            }
            continue
        }

        # Windows відкидає кінцеві точки й пробіли в імені: 'source.ps1.' і
        # 'source.ps1 ' відкриють той самий файл, що 'source.ps1'. Без цього
        # зрізання 'docs/source.ps1.' проходив би межу запису, бо не відповідає
        # deny-патерну '*.ps1', хоча фактично вказує саме на такий файл.
        $trimmed = $segment.TrimEnd('.', ' ')
        if ([string]::IsNullOrEmpty($trimmed)) { continue }
        $segments.Add($trimmed)
    }

    $normalized = [string]::Join('/', $segments)
    if ($isRooted) { $normalized = '/' + $normalized }
    return $normalized
}

function ConvertFrom-JsonEscapedText {
    <#
        Розескейпує \uXXXX і прості \-послідовності в сирому тексті payload.

        Потрібно лише на шляху відновлення роли після збою розбору stdin:
        ConvertFrom-Json там уже впав, а порівнювати ім'я роли з літеральним
        'reviewer' доводиться по сирому тексту. Без розескейпування
        "subagent_type":"reviewer" не впізнавався б як гейт-критична роль.

        Реалізовано без MatchEvaluator-скриптблоку: у Windows PowerShell 5.1
        такий виклик [regex]::Replace поводиться непослідовно між хостами.
    #>
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return '' }

    $result = $Value
    foreach ($match in [regex]::Matches($Value, '\\u(?<code>[0-9a-fA-F]{4})')) {
        $literal = $match.Value
        $decoded = [string][char][Convert]::ToInt32($match.Groups['code'].Value, 16)
        $result = $result.Replace($literal, $decoded)
    }

    # Решта простих escape-послідовностей JSON: прибираємо зворотний слеш,
    # лишаючи сам символ, щоб "revie\wer" теж не маскувало ім'я роли.
    return ($result -replace '\\(.)', '$1')
}

function Test-PatternMatch {
    param([string]$Value, $Patterns)

    foreach ($pattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($Value -like ($pattern -replace '\\', '/')) { return $true }
    }
    return $false
}

# --- stdin ---------------------------------------------------------------

$projectDir = Resolve-ProjectDir -CwdFromPayload $null
$agentName = ''
$modelName = ''
$toolName = ''

$raw = ''

try {
    $raw = [Console]::In.ReadToEnd()
    $payload = $raw | ConvertFrom-Json

    $toolName = [string]$payload.tool_name
    $projectDir = Resolve-ProjectDir -CwdFromPayload ([string]$payload.cwd)

    if ($toolName -like ($script:CodexToolPrefix + '*')) {
        $role = ''
        if ($null -ne $payload.tool_input -and $null -ne $payload.tool_input.role) { $role = [string]$payload.tool_input.role }
        Approve-Call -ProjectDir $projectDir -Tool $toolName -Agent "codex:$role" -Model 'codex' -Reason 'codex call audited, not gated by this hook'
    }

    if ($toolName -cne 'Task') {
        Approve-Call -ProjectDir $projectDir -Tool $toolName -Agent 'n/a' -Model 'n/a' -Reason 'tool not subject to routing policy'
    }

    $agentName = [string]$payload.tool_input.subagent_type
    if ($null -ne $payload.tool_input.model) { $modelName = [string]$payload.tool_input.model }
    $prompt = ''
    if ($null -ne $payload.tool_input.prompt) { $prompt = [string]$payload.tool_input.prompt }
}
catch {
    # Збій розбору stdin — та сама логіка, що й для пошкодженої матриці:
    # закрито для гейт-критичних ролей, відкрито для решти.
    #
    # Роль при цьому ще не визначена, тому її доводиться відновити з сирого
    # тексту: інакше обіцяне fail-closed не настало б ніколи (порожнє
    # $agentName не входить до жодного списку, і хук пропускав би будь-який
    # зіпсований payload, навіть той, що називає reviewer).
    $reason = 'HOOK-ERROR: stdin parse failed: ' + $_.Exception.Message
    $recovered = ''

    # Сире тіло спершу розескейпуємо: ім'я роли в JSON може бути записане як
    # "reviewer", і порівняння з літеральним 'reviewer' його не впізнало б —
    # тобто гейт-критичний виклик пройшов би саме через escape-послідовність.
    $rawDecoded = ConvertFrom-JsonEscapedText -Value $raw

    $recoverMatch = [regex]::Match($rawDecoded, '"subagent_type"\s*:\s*"(?<agent>[^"]+)"')
    if ($recoverMatch.Success) {
        $recovered = $recoverMatch.Groups['agent'].Value
    }
    else {
        # Навіть імені роли не видно: якщо в тексті взагалі згадана гейт-критична
        # роль, трактуємо виклик як гейт-критичний.
        foreach ($critical in $script:FailClosedRoles) {
            if ($rawDecoded -match ('"' + [regex]::Escape($critical) + '"')) { $recovered = $critical; break }
        }
    }

    if ($script:FailClosedRoles -contains $recovered) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $recovered -Model $modelName `
            -Reason ($reason + ' — gate-critical role recovered from raw payload, blocked (fail-closed)')
    }
    Write-RoutingLog -ProjectDir $projectDir -Decision 'ALLOW' -Tool $toolName -Agent $recovered -Model $modelName `
        -Reason ($reason + ' — no gate-critical role identified, allowed (fail-open)')
    exit 0
}

# --- матриця -------------------------------------------------------------

$matrix = $null
$matrixError = ''
try {
    $matrixPath = Join-Path $projectDir '.claude\ai-routing.json'
    if (-not (Test-Path -LiteralPath $matrixPath -PathType Leaf)) {
        throw "routing matrix not found: $matrixPath"
    }
    $matrix = Get-Content -LiteralPath $matrixPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$matrix.schemaVersion -cne '1') { throw 'unsupported routing matrix schemaVersion' }
    if ($null -eq $matrix.roles -or @($matrix.roles.PSObject.Properties).Count -eq 0) { throw 'routing matrix defines no roles' }
}
catch {
    $matrix = $null
    $matrixError = $_.Exception.Message
}

if ($null -eq $matrix) {
    $reason = "HOOK-ERROR: $matrixError"
    if ($script:FailClosedRoles -contains $agentName) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName -Reason ($reason + ' — gate-critical role blocked (fail-closed)')
    }
    Write-RoutingLog -ProjectDir $projectDir -Decision 'ALLOW' -Tool $toolName -Agent $agentName -Model $modelName -Reason ($reason + ' — non-gate role allowed (fail-open)')
    exit 0
}

$role = $matrix.roles.$agentName
if ($null -eq $role) {
    Approve-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName -Reason 'agent is not managed by the routing matrix'
}

# 1) Модель мусить відповідати матриці.
if (-not [string]::IsNullOrWhiteSpace($modelName)) {
    $expectedModel = [string]$role.model
    if ($modelName -cne $expectedModel) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName `
            -Reason ("role '$agentName' is pinned to model '$expectedModel' by .claude/ai-routing.json")
    }
}

# 2) Claude-агент не може бути брифований як формальний Codex-гейт.
$codexSourceMatch = [regex]::Match($prompt, '(?im)^\s*review_source\s*:\s*(?<source>codex-[a-z]+)')
if ($codexSourceMatch.Success) {
    Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName `
        -Reason ("brief declares review_source '" + $codexSourceMatch.Groups['source'].Value + "' — only Codex closes that gate (BRAVO_AGENT_POLICY.md 8.1/8.2)")
}

# 3) Режим claude-qa-fallback вимагає однієї з трьох дозволених причин.
#
# Тригер — саме ОГОЛОШЕННЯ режиму окремим ключем (REVIEW_MODE / review_source /
# mode), а не будь-яка згадка рядка 'claude-qa-fallback' у брифі. Інакше
# блокувались би легітимні виклики: бриф worker-а «реалізуй обробку
# claude-qa-fallback» або бриф reviewer-а «перевір формулювання про
# claude-qa-fallback у політиці» — жоден із них не є виконанням ролі fallback.
$fallbackDeclared = [regex]::IsMatch($prompt, '(?im)^\s*(REVIEW_MODE|review_source|mode)\s*:\s*claude-qa-fallback\s*$')
if ($fallbackDeclared) {
    $allowedReasons = @($matrix.fallback.allowedReasons)

    # Причина читається ДО кінця рядка і валідується повністю. Часткове
    # зіставлення ('quota' у 'quota/timeout') пропускало б явно заборонену
    # причину, прикриту дозволеним префіксом.
    $reasonMatch = [regex]::Match($prompt, '(?im)^\s*fallback_reason\s*:\s*(?<reason>.+?)\s*$')

    if (-not $reasonMatch.Success) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName `
            -Reason 'claude-qa-fallback brief declares no fallback_reason'
    }

    $declared = $reasonMatch.Groups['reason'].Value.Trim()
    if ($allowedReasons -notcontains $declared) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName `
            -Reason ("fallback_reason '$declared' is not allowed — only " + ($allowedReasons -join ', ') + "; anything else is a defect to diagnose, not a fallback trigger")
    }
}

# 4) Межі запису агента documentation.
if ($null -ne $role.writeDeny -or $null -ne $role.writeAllow) {
    foreach ($token in (Get-ScopeToken -Prompt $prompt)) {
        if (Test-PatternMatch -Value $token -Patterns $role.writeDeny) {
            Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName `
                -Reason ("SCOPE '$token' is outside the write boundary of role '$agentName' (denied)")
        }
        if ($null -ne $role.writeAllow -and -not (Test-PatternMatch -Value $token -Patterns $role.writeAllow)) {
            Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName `
                -Reason ("SCOPE '$token' is not inside the write allowlist of role '$agentName'")
        }
    }
}

Approve-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName -Reason 'routing policy satisfied'
