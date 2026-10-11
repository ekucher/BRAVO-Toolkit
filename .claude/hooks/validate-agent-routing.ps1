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
            $tokens.Add(($token -replace '\\', '/'))
        }
    }

    return $tokens
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
    $reason = 'HOOK-ERROR: stdin parse failed: ' + $_.Exception.Message
    if ($script:FailClosedRoles -contains $agentName) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName -Reason $reason
    }
    Write-RoutingLog -ProjectDir $projectDir -Decision 'ALLOW' -Tool $toolName -Agent $agentName -Model $modelName -Reason $reason
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
if ($prompt -match 'claude-qa-fallback') {
    $allowedReasons = @($matrix.fallback.allowedReasons)
    $reasonMatch = [regex]::Match($prompt, '(?im)^\s*fallback_reason\s*:\s*(?<reason>[a-z\-]+)')

    if (-not $reasonMatch.Success) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName `
            -Reason 'claude-qa-fallback brief declares no fallback_reason'
    }

    $declared = $reasonMatch.Groups['reason'].Value
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
