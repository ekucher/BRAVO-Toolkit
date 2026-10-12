<#
    Test-AIRouting.ps1
    Tests for the AI role/model routing matrix (.claude/ai-routing.json) and its
    PreToolUse enforcement hook (.claude/hooks/validate-agent-routing.ps1).

    Not part of BRAVO_SELF_TEST.ps1 — this is local Claude Code tooling,
    not BRAVO runtime. Run directly:

        powershell -NoProfile -File .claude\hooks\tests\Test-AIRouting.ps1

    Exits 0 on all-pass, 1 on any failure (prints [FAIL] lines).

    The hook is exercised as a real child process over stdin, so every
    hook assertion is a real exit-code observation, not a simulation of one.
    Codex quota/rate-limit behavior is asserted against the matrix contract
    and the hook's own decisions — no real Codex quota is consumed.
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent

$matrixPath = Join-Path $root '.claude\ai-routing.json'
$hookPath = Join-Path $root '.claude\hooks\validate-agent-routing.ps1'
$agentsDir = Join-Path $root '.claude\agents'

$script:failures = 0
$script:total = 0

function Assert-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    $script:total++
    if ($Expected -ceq $Actual) {
        Write-Host "[PASS] $Name"
    }
    else {
        $script:failures++
        Write-Host "[FAIL] $Name -- expected '$Expected', got '$Actual'" -ForegroundColor Red
    }
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    $script:total++
    if ($Condition) {
        Write-Host "[PASS] $Name"
    }
    else {
        $script:failures++
        Write-Host "[FAIL] $Name $Detail" -ForegroundColor Red
    }
}

# --- Matrix contract ------------------------------------------------------

Assert-True 'matrix file exists' (Test-Path -LiteralPath $matrixPath -PathType Leaf) $matrixPath

$matrix = $null
if (Test-Path -LiteralPath $matrixPath -PathType Leaf) {
    try {
        $matrix = Get-Content -LiteralPath $matrixPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True 'matrix parses as JSON' $true
    }
    catch {
        Assert-True 'matrix parses as JSON' $false $_.Exception.Message
    }
}

if ($null -ne $matrix) {
    Assert-Equal 'matrix schemaVersion is 1' '1' ([string]$matrix.schemaVersion)

    $expectedRoles = @{
        'scout'             = 'haiku'
        'worker'            = 'sonnet'
        'tester'            = 'sonnet'
        'documentation'     = 'sonnet'
        'reviewer'          = 'opus'
        'architect'         = 'opus'
        'security-reviewer' = 'opus'
    }

    foreach ($roleName in $expectedRoles.Keys) {
        $role = $matrix.roles.$roleName
        Assert-True "matrix defines role '$roleName'" ($null -ne $role)
        if ($null -ne $role) {
            Assert-Equal "role '$roleName' model" $expectedRoles[$roleName] ([string]$role.model)
        }
    }

    # Every agent file on disk must be in the matrix, and vice versa, so the
    # matrix cannot silently drift from what Claude Code actually loads.
    $agentFiles = @()
    if (Test-Path -LiteralPath $agentsDir -PathType Container) {
        $agentFiles = @(Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File)
    }
    Assert-True 'agents directory is not empty' ($agentFiles.Count -gt 0)

    foreach ($file in $agentFiles) {
        $agentName = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        $role = $matrix.roles.$agentName
        Assert-True "agent '$agentName' is present in the matrix" ($null -ne $role)

        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        $modelMatch = [regex]::Match($text, '(?m)^model:\s*(?<model>[A-Za-z0-9._\-\[\]]+)\s*$')
        Assert-True "agent '$agentName' declares a model in frontmatter" $modelMatch.Success
        if ($modelMatch.Success -and $null -ne $role) {
            Assert-Equal "agent '$agentName' frontmatter model matches matrix" ([string]$role.model) $modelMatch.Groups['model'].Value
        }

        $nameMatch = [regex]::Match($text, '(?m)^name:\s*(?<name>\S+)\s*$')
        Assert-True "agent '$agentName' frontmatter name matches file name" ($nameMatch.Success -and $nameMatch.Groups['name'].Value -ceq $agentName)

        Assert-True "agent '$agentName' references canonical policy" ($text -match 'BRAVO_AGENT_POLICY\.md')
        Assert-True "agent '$agentName' carries a HANDOFF block" ($text -match '(?m)^HANDOFF\s*$')
    }

    foreach ($roleName in $matrix.roles.PSObject.Properties.Name) {
        $file = Join-Path $agentsDir ($roleName + '.md')
        Assert-True "matrix role '$roleName' has an agent file" (Test-Path -LiteralPath $file -PathType Leaf)
    }

    # Read-only roles must not carry write tools in their frontmatter.
    foreach ($roleName in $matrix.roles.PSObject.Properties.Name) {
        $role = $matrix.roles.$roleName
        if ($role.write -eq $false) {
            $file = Join-Path $agentsDir ($roleName + '.md')
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $text = Get-Content -LiteralPath $file -Raw -Encoding UTF8
                $toolsMatch = [regex]::Match($text, '(?m)^tools:\s*(?<tools>.+)$')
                $hasWriteTool = $toolsMatch.Success -and ($toolsMatch.Groups['tools'].Value -match '\b(Edit|Write|NotebookEdit)\b')
                Assert-True "read-only role '$roleName' declares no write tools" (-not $hasWriteTool) $(if ($toolsMatch.Success) { $toolsMatch.Groups['tools'].Value } else { '(no tools line)' })
            }
        }
    }

    # --- Risk levels map onto BRAVO_AGENT_POLICY.md section 9 -------------

    Assert-True 'LOW requires no Codex gate' (@($matrix.riskLevels.LOW.requiredGates).Count -eq 0 -and $matrix.riskLevels.LOW.codexRequired -eq $false)
    Assert-True 'MEDIUM requires exactly codex-qa' (@($matrix.riskLevels.MEDIUM.requiredGates) -join ',' -ceq 'codex-qa')
    Assert-True 'HIGH requires codex-qa and codex-architecture' ((@($matrix.riskLevels.HIGH.requiredGates) -contains 'codex-qa') -and (@($matrix.riskLevels.HIGH.requiredGates) -contains 'codex-architecture'))
    Assert-True 'HIGH requires the architect role' (@($matrix.riskLevels.HIGH.requiredRoles) -contains 'architect')
    Assert-True 'CRITICAL requires qa + security + architecture gates' ((@($matrix.riskLevels.CRITICAL.requiredGates) -contains 'codex-qa') -and (@($matrix.riskLevels.CRITICAL.requiredGates) -contains 'codex-security') -and (@($matrix.riskLevels.CRITICAL.requiredGates) -contains 'codex-architecture'))
    Assert-True 'CRITICAL requires architect and security-reviewer roles' ((@($matrix.riskLevels.CRITICAL.requiredRoles) -contains 'architect') -and (@($matrix.riskLevels.CRITICAL.requiredRoles) -contains 'security-reviewer'))

    # --- Fallback limits (BRAVO_AGENT_POLICY.md section 8.2) --------------

    $allowed = @($matrix.fallback.allowedReasons)
    Assert-Equal 'exactly three fallback reasons are allowed' '3' ([string]$allowed.Count)
    Assert-True 'allowed fallback reasons are quota, rate-limit, service-unavailable' (($allowed -contains 'quota') -and ($allowed -contains 'rate-limit') -and ($allowed -contains 'service-unavailable'))
    Assert-True 'timeout is not an allowed fallback reason' ($allowed -notcontains 'timeout')
    Assert-True 'mcp-error is not an allowed fallback reason' ($allowed -notcontains 'mcp-error')
    Assert-True 'configuration defects are explicitly forbidden fallback reasons' ((@($matrix.fallback.forbiddenReasons) -contains 'configuration-error') -and (@($matrix.fallback.forbiddenReasons) -contains 'mcp-error') -and (@($matrix.fallback.forbiddenReasons) -contains 'timeout'))
    Assert-True 'no second-level fallback to a weaker model' ($matrix.fallback.secondLevelFallback -eq $false)
    Assert-Equal 'the single Claude fallback role is reviewer' 'reviewer' ([string]$matrix.fallback.claudeFallbackRole)
    Assert-True 'fallback may not satisfy security/architecture/verification gates' ((@($matrix.fallback.gatesFallbackMayNotSatisfy) -contains 'codex-security') -and (@($matrix.fallback.gatesFallbackMayNotSatisfy) -contains 'codex-architecture') -and (@($matrix.fallback.gatesFallbackMayNotSatisfy) -contains 'codex-verification'))

    # --- documentation write boundaries ----------------------------------

    $deny = @($matrix.roles.documentation.writeDeny)
    Assert-True 'documentation may write CHANGELOG.md' (@($matrix.roles.documentation.writeAllow) -contains 'CHANGELOG.md')
    Assert-True 'documentation is denied acceptance evidence' ($deny -contains 'docs/*ACCEPTANCE*')
    Assert-True 'documentation is denied runbooks' ($deny -contains 'docs/*RUNBOOK*')
    Assert-True 'documentation is denied canonical policy' ($deny -contains 'BRAVO_AGENT_POLICY.md')
    Assert-True 'documentation is denied PowerShell sources' ($deny -contains '*.ps1')
    Assert-True 'documentation is denied integrity manifests' ($deny -contains '*MANIFEST*.json')

    # worker/tester carry a static deny list: they write code, never release
    # evidence, canonical policy, agent configuration or integrity manifests.
    foreach ($implementer in @('worker', 'tester')) {
        $implementerDeny = @($matrix.roles.$implementer.writeDeny)
        Assert-True "role '$implementer' declares a static writeDeny" ($implementerDeny.Count -gt 0)
        Assert-True "role '$implementer' is denied acceptance evidence" ($implementerDeny -contains 'docs/*ACCEPTANCE*')
        Assert-True "role '$implementer' is denied runbooks" ($implementerDeny -contains 'docs/*RUNBOOK*')
        Assert-True "role '$implementer' is denied canonical policy" ($implementerDeny -contains 'BRAVO_AGENT_POLICY.md')
        Assert-True "role '$implementer' is denied agent configuration" ($implementerDeny -contains '.claude/*')
        Assert-True "role '$implementer' is denied integrity manifests" ($implementerDeny -contains '*MANIFEST*.json')
        Assert-True "role '$implementer' keeps no writeAllow (code is not allowlisted)" ($null -eq $matrix.roles.$implementer.writeAllow)
    }

    # The documentation agent must not hold Bash: after the write gate, Bash
    # would be the one remaining ungated write path.
    $docAgentPath = Join-Path $agentsDir 'documentation.md'
    if (Test-Path -LiteralPath $docAgentPath -PathType Leaf) {
        $docText = Get-Content -LiteralPath $docAgentPath -Raw -Encoding UTF8
        $docTools = [regex]::Match($docText, '(?m)^tools:\s*(?<tools>.+)$')
        Assert-True 'documentation agent declares a tools line' $docTools.Success
        if ($docTools.Success) {
            Assert-True 'documentation agent has no Bash' ($docTools.Groups['tools'].Value -notmatch '\bBash\b') $docTools.Groups['tools'].Value
            Assert-True 'documentation agent keeps Read/Write for its job' (($docTools.Groups['tools'].Value -match '\bRead\b') -and ($docTools.Groups['tools'].Value -match '\bWrite\b'))
        }

        # The earlier revision claimed the hook blocked these targets
        # "independently of this prompt" while the hook never saw Write/Edit at
        # all. The claim must not reappear in that unqualified form.
        Assert-True 'documentation agent makes no unqualified claim about hook coverage' ($docText -notmatch 'blocks these targets independently of this prompt')
        Assert-True 'documentation agent states where the diff comes from' ($docText -match '(?i)diff')
    }

    # --- enforcement wiring ----------------------------------------------

    Assert-Equal 'matrix points at the enforcement hook' '.claude/hooks/validate-agent-routing.ps1' ([string]$matrix.enforcement.hook)
    Assert-True 'unmanaged agents are ignored by design' ($matrix.enforcement.unmanagedAgentsIgnored -eq $true)
    Assert-True 'fail-closed roles are exactly the gate-critical ones' ((@($matrix.enforcement.failClosedRoles) -contains 'reviewer') -and (@($matrix.enforcement.failClosedRoles) -contains 'architect') -and (@($matrix.enforcement.failClosedRoles) -contains 'security-reviewer') -and (@($matrix.enforcement.failClosedRoles).Count -eq 3))
}

# --- settings.json registers the hook ------------------------------------

$settingsPath = Join-Path $root '.claude\settings.json'
Assert-True 'settings.json exists' (Test-Path -LiteralPath $settingsPath -PathType Leaf)
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $settingsText = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
    Assert-True 'settings.json registers a PreToolUse hook' ($settingsText -match '"PreToolUse"')
    Assert-True 'settings.json wires validate-agent-routing.ps1' ($settingsText -match 'validate-agent-routing\.ps1')

    # The matcher must cover the write tools, not only delegation briefs:
    # otherwise the write boundary exists in prompt text only.
    $matcherMatch = [regex]::Match($settingsText, '"matcher"\s*:\s*"(?<m>[^"]*Task[^"]*)"')
    Assert-True 'PreToolUse matcher is present for Task' $matcherMatch.Success
    if ($matcherMatch.Success) {
        $matcher = $matcherMatch.Groups['m'].Value
        Assert-True 'matcher covers Write' ($matcher -match '\bWrite\b') $matcher
        Assert-True 'matcher covers Edit' ($matcher -match '\bEdit\b') $matcher
        Assert-True 'matcher covers NotebookEdit' ($matcher -match 'NotebookEdit') $matcher
        Assert-True 'matcher still covers Codex calls' ($matcher -match 'codex-agent') $matcher
    }
    Assert-True 'settings.json keeps the PreCompact hook' ($settingsText -match 'precompact-checkpoint\.ps1')
    Assert-True 'settings.json keeps the save-task hook' ($settingsText -match 'save-task\.ps1')
    Assert-True 'settings.json keeps the Slack notification hook' ($settingsText -match 'notify-slack\.ps1')
    try {
        $null = $settingsText | ConvertFrom-Json
        Assert-True 'settings.json parses as JSON' $true
    }
    catch {
        Assert-True 'settings.json parses as JSON' $false $_.Exception.Message
    }
}

# --- Hook behavior: real child process, real exit codes ------------------

Assert-True 'enforcement hook exists' (Test-Path -LiteralPath $hookPath -PathType Leaf) $hookPath

function Invoke-RoutingHook {
    <#
        Runs the real hook as a child process over stdin and returns its exit
        code. 0 = allow, 2 = block (Claude Code PreToolUse convention).
    #>
    param(
        [string]$ProjectDir,
        [hashtable]$Payload
    )

    if (-not (Test-Path -LiteralPath $hookPath -PathType Leaf)) { return -1 }

    $json = $Payload | ConvertTo-Json -Depth 6 -Compress
    $previous = $env:CLAUDE_PROJECT_DIR
    $env:CLAUDE_PROJECT_DIR = $ProjectDir

    # Блокування хука йде в stderr. У Windows PowerShell 5.1 перехоплення
    # stderr нативного процесу через 2>&1 при $ErrorActionPreference = 'Stop'
    # перетворює кожен рядок stderr у термінальний NativeCommandError, тому
    # тут глушимо всі потоки через *> і локально знімаємо 'Stop': перевіряємо
    # саме exit-код, а не текст діагностики.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $json | & powershell.exe -NoProfile -File $hookPath *>$null
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
        if ($null -eq $previous) {
            Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:CLAUDE_PROJECT_DIR = $previous
        }
    }
}

function Get-TaskPayload {
    param(
        [string]$Agent,
        [string]$Model,
        [string]$Prompt = 'OBJECTIVE: bounded test brief'
    )
    $toolInput = @{ subagent_type = $Agent; prompt = $Prompt }
    if ($PSBoundParameters.ContainsKey('Model') -and -not [string]::IsNullOrEmpty($Model)) {
        $toolInput['model'] = $Model
    }
    return @{
        session_id      = 'routing-test'
        hook_event_name = 'PreToolUse'
        tool_name       = 'Task'
        cwd             = $root
        tool_input      = $toolInput
    }
}

function Get-WritePayload {
    <#
        Payload для Write/Edit/NotebookEdit. Ключове поле — agent_type: за
        документацією Claude Code hooks спрацьовують і всередині субагента, і
        payload несе agent_id/agent_type, тобто того, ХТО діє. Відсутній
        agent_type означає головну сесію.
    #>
    param(
        [string]$Tool = 'Write',
        [string]$AgentType,
        [string]$Path,
        [string]$ProjectDir
    )

    $toolInput = @{}
    if ($Tool -ceq 'NotebookEdit') { $toolInput['notebook_path'] = $Path } else { $toolInput['file_path'] = $Path }
    if ($Tool -ceq 'Edit') { $toolInput['old_string'] = 'a'; $toolInput['new_string'] = 'b' } else { $toolInput['content'] = 'x' }

    $payload = @{
        session_id      = 'routing-test'
        hook_event_name = 'PreToolUse'
        tool_name       = $Tool
        cwd             = $ProjectDir
        tool_input      = $toolInput
    }
    if ($PSBoundParameters.ContainsKey('AgentType') -and -not [string]::IsNullOrEmpty($AgentType)) {
        $payload['agent_id'] = 'agent-test'
        $payload['agent_type'] = $AgentType
    }
    return $payload
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("bravo-routing-test-{0}" -f [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path (Join-Path $sandbox '.claude') -Force | Out-Null
    if (Test-Path -LiteralPath $matrixPath -PathType Leaf) {
        Copy-Item -LiteralPath $matrixPath -Destination (Join-Path $sandbox '.claude\ai-routing.json') -Force
    }

    # 1) Legitimate calls are allowed.
    Assert-Equal 'scout on haiku is allowed' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'scout' -Model 'haiku')))
    Assert-Equal 'worker on sonnet is allowed' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'worker' -Model 'sonnet')))
    Assert-Equal 'agent call without an explicit model override is allowed' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'reviewer')))

    # 2) Model must match the matrix.
    Assert-Equal 'scout forced onto opus is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'scout' -Model 'opus')))
    Assert-Equal 'reviewer downgraded to haiku is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'reviewer' -Model 'haiku')))
    Assert-Equal 'reviewer downgraded to sonnet is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'reviewer' -Model 'sonnet')))

    # 3) Fallback discipline: reason required, and only the three allowed ones.
    $fallbackNoReason = 'REVIEW_MODE: claude-qa-fallback' + "`n" + 'OBJECTIVE: review the change'
    Assert-Equal 'claude-qa-fallback without a reason is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'reviewer' -Prompt $fallbackNoReason)))

    foreach ($reason in @('quota', 'rate-limit', 'service-unavailable')) {
        $prompt = 'REVIEW_MODE: claude-qa-fallback' + "`n" + ('fallback_reason: {0}' -f $reason) + "`n" + 'OBJECTIVE: review the change'
        Assert-Equal ("claude-qa-fallback with reason '$reason' is allowed") '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'reviewer' -Prompt $prompt)))
    }

    foreach ($reason in @('timeout', 'mcp-error', 'configuration-error', 'not-configured', 'convenience')) {
        $prompt = 'REVIEW_MODE: claude-qa-fallback' + "`n" + ('fallback_reason: {0}' -f $reason) + "`n" + 'OBJECTIVE: review the change'
        Assert-Equal ("claude-qa-fallback with forbidden reason '$reason' is blocked") '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'reviewer' -Prompt $prompt)))
    }

    # 4) A Claude agent must never be briefed as a Codex gate.
    foreach ($source in @('codex-qa', 'codex-security', 'codex-architecture', 'codex-verification')) {
        $prompt = ('review_source: {0}' -f $source) + "`n" + 'OBJECTIVE: close the gate'
        Assert-Equal ("claude agent briefed as '$source' is blocked") '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'reviewer' -Prompt $prompt)))
    }
    Assert-Equal 'architect briefed as the codex architecture gate is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'architect' -Model 'opus' -Prompt "review_source: codex-architecture`nOBJECTIVE: sign off")))
    Assert-Equal 'security-reviewer briefed as the codex security gate is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'security-reviewer' -Model 'opus' -Prompt "review_source: codex-security`nOBJECTIVE: sign off")))
    Assert-Equal 'declaring claude-pre-review is allowed' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'reviewer' -Prompt "review_source: claude-pre-review`nOBJECTIVE: internal pre-review")))

    # 5) documentation write boundaries.
    Assert-Equal 'documentation writing CHANGELOG.md is allowed' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: record the change`nSCOPE: CHANGELOG.md, README.md")))
    Assert-Equal 'documentation writing a design note is allowed' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: update design note`nSCOPE: docs/BRAVO_HEALTH_FUTURE_MONITORING_DESIGN.md")))
    Assert-Equal 'documentation rewriting acceptance evidence is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: refresh docs`nSCOPE: docs/BRAVO_523_RC6_ACCEPTANCE_EVIDENCE_20260913.md")))
    Assert-Equal 'documentation rewriting a runbook is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: refresh docs`nSCOPE: docs/BRAVO_524_FLEET_ROLLOUT_RUNBOOK_20260913.md")))
    Assert-Equal 'documentation editing canonical policy is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy policy`nSCOPE: BRAVO_AGENT_POLICY.md")))
    Assert-Equal 'documentation editing a PowerShell source is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: fix comment`nSCOPE: BRAVO_ARCHIV.ps1")))
    Assert-Equal 'documentation editing a manifest is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: refresh hashes`nSCOPE: RUNTIME_MANIFEST.json")))

    # 5a) Write-boundary bypass via path traversal (QA-001).
    #
    # 'docs/../AGENTS.md' matches the writeAllow pattern 'docs/*' and dodges every
    # deny pattern, yet resolves to canonical policy outside the boundary. The
    # boundary must be applied to the normalized path, not to the literal token.
    Assert-Equal 'documentation SCOPE escaping via ../ is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: docs/../AGENTS.md")))
    Assert-Equal 'documentation SCOPE escaping via backslash ..\ is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: docs\..\BRAVO_AGENT_POLICY.md")))
    Assert-Equal 'documentation SCOPE escaping into a module is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: docs/../modules/BRAVO.Archive/BRAVO.Archive.psm1")))
    Assert-Equal 'documentation SCOPE escaping above the repository is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: ../other-repo/docs/x.md")))
    # Windows відкидає кінцеві точки й пробіли в імені файлу, тому
    # 'docs/source.ps1.' відкриває 'docs/source.ps1' — межа запису мусить це
    # враховувати, інакше deny-патерн '*.ps1' обходиться однією точкою.
    Assert-Equal 'documentation SCOPE with a trailing dot on a .ps1 is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: docs/source.ps1.")))
    Assert-Equal 'documentation SCOPE with trailing dots on a .psm1 is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: docs/module.psm1...")))
    Assert-Equal 'documentation SCOPE with a trailing dot on a manifest is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: RUNTIME_MANIFEST.json.")))
    # NTFS-синтаксис альтернативного потоку адресує той самий файл і не повинен
    # обходити deny-патерни за розширенням.
    Assert-Equal 'documentation SCOPE using NTFS stream syntax on a .ps1 is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: docs/source.ps1::`$DATA")))
    Assert-Equal 'documentation SCOPE using a named NTFS stream on a .psm1 is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: docs/module.psm1:hidden")))
    Assert-Equal 'documentation SCOPE with an absolute path is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: C:/BRAVO/docs/x.md")))
    # Drive-qualified traversal: згортання '..' не повинно перетворювати
    # абсолютний шлях на дозволений відносний.
    Assert-Equal 'documentation SCOPE with drive-qualified traversal is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: C:/../docs/x.md")))
    Assert-Equal 'documentation SCOPE with deep drive-qualified traversal is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: C:/BRAVO/../../docs/x.md")))
    Assert-Equal 'documentation SCOPE with a UNC path is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: //server/share/docs/x.md")))
    Assert-Equal 'documentation SCOPE with a device path is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: \\?\C:\docs\x.md")))
    Assert-Equal 'documentation SCOPE with a harmless leading ./ stays allowed' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: ./docs/MANUAL_RUN_CONSOLE_UX.md")))

    # 5d) Extensionless and directory scopes must be checked, not discarded.
    # 'Tools' or 'POLICY' are write targets too; dropping tokens without a
    # slash or dot let them skip the boundary entirely.
    Assert-Equal 'documentation SCOPE naming a code directory is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: Tools")))
    Assert-Equal 'documentation SCOPE naming an extensionless root file is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: write policy`nSCOPE: POLICY")))
    Assert-Equal 'documentation SCOPE naming the modules tree is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: modules")))
    Assert-Equal 'documentation SCOPE naming the docs directory stays allowed' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: docs")))
    Assert-Equal 'documentation SCOPE declared as none stays allowed (audit-only)' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: audit drift`nSCOPE: none")))
    # Проза у SCOPE блокується свідомо: SCOPE — список шляхів, і бриф треба
    # виправити, а не трактувати довільний текст як обсяг запису.
    Assert-Equal 'documentation SCOPE written as prose is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'documentation' -Model 'sonnet' -Prompt "OBJECTIVE: tidy`nSCOPE: only the documentation files that describe the change")))
    # Інші роли межі запису не мають — їх ця перевірка не стосується.
    Assert-Equal 'worker SCOPE naming a module stays allowed' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'worker' -Model 'sonnet' -Prompt "OBJECTIVE: implement`nSCOPE: modules/BRAVO.Archive/BRAVO.Archive.psm1")))

    # 5b) Fallback enforcement must key on an actual mode declaration (QA-003),
    # not on any mention of the string, otherwise briefs that implement or test
    # fallback handling are blocked for no reason.
    Assert-Equal 'worker brief merely mentioning claude-qa-fallback is allowed' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'worker' -Model 'sonnet' -Prompt 'OBJECTIVE: implement tests for claude-qa-fallback handling')))
    Assert-Equal 'reviewer brief discussing fallback without declaring the mode is allowed' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'reviewer' -Prompt 'OBJECTIVE: check that claude-qa-fallback wording in the policy is consistent')))

    # 5c) The declared reason must be validated in full (QA-004): a valid prefix
    # followed by a forbidden remainder must not pass.
    foreach ($bad in @('quota/timeout', 'quota timeout', 'quota,timeout', 'rate-limit-ish', 'service-unavailable/mcp-error')) {
        $prompt = 'REVIEW_MODE: claude-qa-fallback' + "`n" + ('fallback_reason: {0}' -f $bad) + "`n" + 'OBJECTIVE: review'
        Assert-Equal ("fallback_reason '$bad' is blocked") '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'reviewer' -Prompt $prompt)))
    }

    # 6) Unmanaged agents are never blocked.
    Assert-Equal 'Explore agent is ignored' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'Explore' -Model 'opus')))
    Assert-Equal 'general-purpose agent is ignored' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'general-purpose' -Model 'haiku')))
    Assert-Equal 'plugin agent is ignored' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-TaskPayload -Agent 'pr-review-toolkit:code-reviewer' -Model 'opus')))

    # 6a) Write gate: the boundary must hold on the ACTUAL write, not only on
    # the SCOPE text of a delegation brief. The acting agent comes from
    # agent_type; the target comes from tool_input.file_path.

    $repoFile = { param($rel) (Join-Path $root $rel) }

    # documentation: denied targets
    foreach ($denied in @(
            'docs\BRAVO_523_RC6_ACCEPTANCE_EVIDENCE_20260913.md',
            'docs\BRAVO_524_FLEET_ROLLOUT_RUNBOOK_20260913.md',
            'BRAVO_AGENT_POLICY.md',
            'AGENTS.md',
            'BRAVO_ARCHIV.ps1',
            'modules\BRAVO.Archive\BRAVO.Archive.psm1',
            'RUNTIME_MANIFEST.json',
            '.claude\ai-routing.json',
            'ci\Test-BRAVOForbiddenPattern.ps1'
        )) {
        Assert-Equal "documentation Write to '$denied' is blocked" '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -AgentType 'documentation' -Path (& $repoFile $denied) -ProjectDir $root)))
        Assert-Equal "documentation Edit of '$denied' is blocked" '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Edit' -AgentType 'documentation' -Path (& $repoFile $denied) -ProjectDir $root)))
    }

    # documentation: allowed targets
    foreach ($allowed in @('CHANGELOG.md', 'README.md', 'docs\MANUAL_RUN_CONSOLE_UX.md', 'docs\ai\MODEL_ROUTING_POLICY.md')) {
        Assert-Equal "documentation Write to '$allowed' is allowed" '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -AgentType 'documentation' -Path (& $repoFile $allowed) -ProjectDir $root)))
    }

    # documentation: traversal and stream tricks must not get through the write gate either
    Assert-Equal 'documentation Write via traversal is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -AgentType 'documentation' -Path (& $repoFile 'docs\..\AGENTS.md') -ProjectDir $root)))
    Assert-Equal 'documentation Write via NTFS stream is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -AgentType 'documentation' -Path ((& $repoFile 'docs\source.ps1') + '::$DATA') -ProjectDir $root)))
    Assert-Equal 'documentation Write outside the repository is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -AgentType 'documentation' -Path 'C:\Temp\evil.md' -ProjectDir $root)))
    Assert-Equal 'documentation NotebookEdit of a denied path is blocked' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'NotebookEdit' -AgentType 'documentation' -Path (& $repoFile 'docs\BRAVO_523_RC6_ACCEPTANCE_EVIDENCE_20260913.md') -ProjectDir $root)))

    # Read-only roles must not write at all, whatever their frontmatter says.
    foreach ($readOnly in @('scout', 'reviewer', 'architect', 'security-reviewer')) {
        Assert-Equal "$readOnly Write to CHANGELOG.md is blocked (write:false)" '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -AgentType $readOnly -Path (& $repoFile 'CHANGELOG.md') -ProjectDir $root)))
        Assert-Equal "$readOnly Edit of a module is blocked (write:false)" '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Edit' -AgentType $readOnly -Path (& $repoFile 'modules\BRAVO.Archive\BRAVO.Archive.psm1') -ProjectDir $root)))
    }

    # worker/tester: static deny only — they must write code, but never release
    # evidence, canonical policy, agent configuration or integrity manifests.
    foreach ($implementer in @('worker', 'tester')) {
        Assert-Equal "$implementer Write to a module is allowed" '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -AgentType $implementer -Path (& $repoFile 'modules\BRAVO.Archive\BRAVO.Archive.psm1') -ProjectDir $root)))
        Assert-Equal "$implementer Write to a root entrypoint is allowed" '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -AgentType $implementer -Path (& $repoFile 'BRAVO_ARCHIV.ps1') -ProjectDir $root)))
        Assert-Equal "$implementer Write to acceptance evidence is blocked" '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -AgentType $implementer -Path (& $repoFile 'docs\BRAVO_523_RC6_ACCEPTANCE_EVIDENCE_20260913.md') -ProjectDir $root)))
        Assert-Equal "$implementer Write to canonical policy is blocked" '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -AgentType $implementer -Path (& $repoFile 'BRAVO_AGENT_POLICY.md') -ProjectDir $root)))
        Assert-Equal "$implementer Write to the routing matrix is blocked" '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -AgentType $implementer -Path (& $repoFile '.claude\ai-routing.json') -ProjectDir $root)))
        Assert-Equal "$implementer Write to the runtime manifest is blocked" '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -AgentType $implementer -Path (& $repoFile 'RUNTIME_MANIFEST.json') -ProjectDir $root)))
    }

    # The main session is not gated: agent_type is absent there, and gating it
    # would block the owner's own work (deliberate, documented decision).
    Assert-Equal 'main session Write to acceptance evidence is allowed (no agent_type)' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -Path (& $repoFile 'docs\BRAVO_523_RC6_ACCEPTANCE_EVIDENCE_20260913.md') -ProjectDir $root)))
    Assert-Equal 'main session Write to canonical policy is allowed (no agent_type)' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -Path (& $repoFile 'BRAVO_AGENT_POLICY.md') -ProjectDir $root)))

    # Agents outside the matrix are never gated.
    Assert-Equal 'unmanaged agent Write is allowed' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -AgentType 'Explore' -Path (& $repoFile 'BRAVO_AGENT_POLICY.md') -ProjectDir $root)))
    Assert-Equal 'plugin agent Write is allowed' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (Get-WritePayload -Tool 'Write' -AgentType 'pr-review-toolkit:code-reviewer' -Path (& $repoFile 'RUNTIME_MANIFEST.json') -ProjectDir $root)))

    # Unresolvable target: a write call whose payload carries no path field the
    # hook recognizes. A read-only role must still be blocked — otherwise the
    # bypass is simply "send a field name the hook does not know". A role with
    # an allowlist is blocked too, because its boundary is defined by what IS
    # permitted, and an unverifiable target is not in it. A deny-list-only role
    # is allowed, since its real boundary is the task SCOPE either way.
    $noTargetPayload = {
        param([string]$AgentType)

        $p = @{
            session_id      = 'routing-test'
            hook_event_name = 'PreToolUse'
            tool_name       = 'Write'
            cwd             = $root
            tool_input      = @{ path = 'BRAVO_AGENT_POLICY.md'; content = 'x' }
        }
        if (-not [string]::IsNullOrEmpty($AgentType)) {
            $p['agent_id'] = 'agent-test'
            $p['agent_type'] = $AgentType
        }
        return $p
    }
    Assert-Equal 'unresolvable write target still blocks reviewer' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (& $noTargetPayload 'reviewer')))
    Assert-Equal 'unresolvable write target still blocks architect' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (& $noTargetPayload 'architect')))
    Assert-Equal 'unresolvable write target blocks an allowlisted role (fail-closed)' '2' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (& $noTargetPayload 'documentation')))
    Assert-Equal 'unresolvable write target allows a deny-list-only role (fail-open)' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (& $noTargetPayload 'worker')))
    Assert-Equal 'unresolvable write target in the main session is allowed' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload (& $noTargetPayload '')))

    # KNOWN LIMITATION, pinned on purpose: Bash is not gated. Inspecting an
    # arbitrary command for "what it would write" is a heuristic with
    # guaranteed bypasses, so the answer for Bash is to withhold the tool from
    # write-bounded roles, not to pretend the hook controls it. If this
    # assertion ever starts failing, the claim in docs must change with it.
    $bashPayload = @{
        session_id      = 'routing-test'
        hook_event_name = 'PreToolUse'
        tool_name       = 'Bash'
        cwd             = $root
        agent_id        = 'agent-test'
        agent_type      = 'documentation'
        tool_input      = @{ command = 'Set-Content -Path docs\BRAVO_523_RC6_ACCEPTANCE_EVIDENCE_20260913.md -Value x' }
    }
    Assert-Equal 'Bash is NOT gated by the hook (documented limitation)' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload $bashPayload))

    # 7) Codex MCP calls are audited, never blocked by this hook.
    $codexPayload = @{
        session_id      = 'routing-test'
        hook_event_name = 'PreToolUse'
        tool_name       = 'mcp__codex-agent__codex_delegate'
        cwd             = $root
        tool_input      = @{ role = 'qa'; prompt = 'review the diff' }
    }
    Assert-Equal 'codex_delegate is allowed through' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload $codexPayload))

    # 8) Non-Task tools are untouched.
    $bashPayload = @{
        session_id      = 'routing-test'
        hook_event_name = 'PreToolUse'
        tool_name       = 'Bash'
        cwd             = $root
        tool_input      = @{ command = 'git status' }
    }
    Assert-Equal 'unrelated tools are allowed through' '0' ([string](Invoke-RoutingHook -ProjectDir $sandbox -Payload $bashPayload))

    # 9) The audit log is actually written.
    $auditLog = Join-Path $sandbox '.claude\logs\ai-routing.log'
    Assert-True 'hook writes an audit log' (Test-Path -LiteralPath $auditLog -PathType Leaf) $auditLog
    if (Test-Path -LiteralPath $auditLog -PathType Leaf) {
        $logText = Get-Content -LiteralPath $auditLog -Raw
        Assert-True 'audit log records a block decision' ($logText -match 'BLOCK')
        Assert-True 'audit log records an allow decision' ($logText -match 'ALLOW')
    }
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Hook self-failure: fail-closed for gate-critical roles only ---------

$brokenSandbox = Join-Path ([IO.Path]::GetTempPath()) ("bravo-routing-broken-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $brokenSandbox '.claude') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $brokenSandbox '.claude\ai-routing.json') -Value '{ "schemaVersion": 1, "roles": { ' -Encoding UTF8

    Assert-Equal 'broken matrix blocks reviewer (fail-closed)' '2' ([string](Invoke-RoutingHook -ProjectDir $brokenSandbox -Payload (Get-TaskPayload -Agent 'reviewer')))
    Assert-Equal 'broken matrix blocks architect (fail-closed)' '2' ([string](Invoke-RoutingHook -ProjectDir $brokenSandbox -Payload (Get-TaskPayload -Agent 'architect')))
    Assert-Equal 'broken matrix blocks security-reviewer (fail-closed)' '2' ([string](Invoke-RoutingHook -ProjectDir $brokenSandbox -Payload (Get-TaskPayload -Agent 'security-reviewer')))
    Assert-Equal 'broken matrix still allows worker (fail-open)' '0' ([string](Invoke-RoutingHook -ProjectDir $brokenSandbox -Payload (Get-TaskPayload -Agent 'worker')))
    Assert-Equal 'broken matrix still allows scout (fail-open)' '0' ([string](Invoke-RoutingHook -ProjectDir $brokenSandbox -Payload (Get-TaskPayload -Agent 'scout')))

    $brokenLog = Join-Path $brokenSandbox '.claude\logs\ai-routing.log'
    Assert-True 'hook logs its own failure loudly' ((Test-Path -LiteralPath $brokenLog -PathType Leaf) -and ((Get-Content -LiteralPath $brokenLog -Raw) -match 'HOOK-ERROR'))
}
finally {
    Remove-Item -LiteralPath $brokenSandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Missing matrix behaves the same way ---------------------------------

$emptySandbox = Join-Path ([IO.Path]::GetTempPath()) ("bravo-routing-empty-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $emptySandbox '.claude') -Force | Out-Null
    Assert-Equal 'missing matrix blocks reviewer (fail-closed)' '2' ([string](Invoke-RoutingHook -ProjectDir $emptySandbox -Payload (Get-TaskPayload -Agent 'reviewer')))
    Assert-Equal 'missing matrix allows worker (fail-open)' '0' ([string](Invoke-RoutingHook -ProjectDir $emptySandbox -Payload (Get-TaskPayload -Agent 'worker')))
}
finally {
    Remove-Item -LiteralPath $emptySandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Malformed stdin (QA-002) --------------------------------------------
#
# A payload the hook cannot parse leaves the role unidentified. The promised
# fail-closed behavior must still hold for gate-critical roles: the hook has to
# recover the role name from the raw text rather than silently allowing the call
# because its own parse failed.

function Invoke-RoutingHookRaw {
    param(
        [string]$ProjectDir,
        [string]$RawStdin
    )

    if (-not (Test-Path -LiteralPath $hookPath -PathType Leaf)) { return -1 }

    $previous = $env:CLAUDE_PROJECT_DIR
    $env:CLAUDE_PROJECT_DIR = $ProjectDir
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $RawStdin | & powershell.exe -NoProfile -File $hookPath *>$null
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
        if ($null -eq $previous) {
            Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:CLAUDE_PROJECT_DIR = $previous
        }
    }
}

$stdinSandbox = Join-Path ([IO.Path]::GetTempPath()) ("bravo-routing-stdin-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $stdinSandbox '.claude') -Force | Out-Null
    Copy-Item -LiteralPath $matrixPath -Destination (Join-Path $stdinSandbox '.claude\ai-routing.json') -Force -ErrorAction SilentlyContinue

    $malformedReviewer = '{"tool_name":"Task","tool_input":{"subagent_type":"reviewer",,"prompt":"x"}}'
    $malformedArchitect = '{"tool_name":"Task","tool_input":{"subagent_type":"architect",,"prompt":"x"}}'
    $malformedWorker = '{"tool_name":"Task","tool_input":{"subagent_type":"worker",,"prompt":"x"}}'

    Assert-Equal 'malformed stdin naming reviewer blocks (fail-closed)' '2' ([string](Invoke-RoutingHookRaw -ProjectDir $stdinSandbox -RawStdin $malformedReviewer))
    Assert-Equal 'malformed stdin naming architect blocks (fail-closed)' '2' ([string](Invoke-RoutingHookRaw -ProjectDir $stdinSandbox -RawStdin $malformedArchitect))
    Assert-Equal 'malformed stdin naming worker allows (fail-open)' '0' ([string](Invoke-RoutingHookRaw -ProjectDir $stdinSandbox -RawStdin $malformedWorker))
    Assert-Equal 'empty stdin allows (fail-open, no role to protect)' '0' ([string](Invoke-RoutingHookRaw -ProjectDir $stdinSandbox -RawStdin ''))

    # Ім'я гейт-критичної роли, замасковане escape-послідовностями, не повинно
    # обходити fail-closed лише через те, що хук порівнює сирий текст.
    $escapedReviewer = '{"tool_name":"Task","tool_input":{"subagent_type":"rev\u0069ewer",,"prompt":"x"}}'
    $escapedArchitect = '{"tool_name":"Task","tool_input":{"subagent_type":"arch\u0069tect",,"prompt":"x"}}'
    $escapedSecurity = '{"tool_name":"Task","tool_input":{"subagent_type":"secur\u0069ty-reviewer",,"prompt":"x"}}'
    Assert-Equal 'malformed stdin with \u-escaped reviewer blocks (fail-closed)' '2' ([string](Invoke-RoutingHookRaw -ProjectDir $stdinSandbox -RawStdin $escapedReviewer))
    Assert-Equal 'malformed stdin with \u-escaped architect blocks (fail-closed)' '2' ([string](Invoke-RoutingHookRaw -ProjectDir $stdinSandbox -RawStdin $escapedArchitect))
    Assert-Equal 'malformed stdin with \u-escaped security-reviewer blocks (fail-closed)' '2' ([string](Invoke-RoutingHookRaw -ProjectDir $stdinSandbox -RawStdin $escapedSecurity))
    # Розескейпування стирає межі JSON-рядків, тому приклад усередині prompt
    # може стояти перед справжнім оголошенням роли. Відновлення мусить дивитись
    # на ВСІ згадки, інакше гейт-критична роль маскується прикладом.
    $embeddedDecoy = '{"tool_name":"Task","tool_input":{"prompt":"Example: \"subagent_type\":\"worker\"","subagent_type":"reviewer",,}}'
    Assert-Equal 'malformed stdin where a prompt example precedes the real reviewer blocks' '2' ([string](Invoke-RoutingHookRaw -ProjectDir $stdinSandbox -RawStdin $embeddedDecoy))

    # Навмисна консервативність: згадка гейт-критичної роли в зіпсованому
    # payload блокує навіть якщо справжня роль звичайна. Цей шлях досягається
    # лише при вже зіпсованому payload, і помилкове блокування тут дешевше за
    # пропущений підмінений гейт.
    $criticalMention = '{"tool_name":"Task","tool_input":{"prompt":"compare against \"reviewer\" output","subagent_type":"worker",,}}'
    Assert-Equal 'malformed stdin merely mentioning a gate-critical role blocks (conservative)' '2' ([string](Invoke-RoutingHookRaw -ProjectDir $stdinSandbox -RawStdin $criticalMention))

    Assert-Equal 'malformed stdin with \u-escaped worker still allows (fail-open)' '0' ([string](Invoke-RoutingHookRaw -ProjectDir $stdinSandbox -RawStdin '{"tool_name":"Task","tool_input":{"subagent_type":"work\u0065r",,"prompt":"x"}}'))

    $stdinLog = Join-Path $stdinSandbox '.claude\logs\ai-routing.log'
    Assert-True 'malformed stdin is logged as HOOK-ERROR' ((Test-Path -LiteralPath $stdinLog -PathType Leaf) -and ((Get-Content -LiteralPath $stdinLog -Raw) -match 'HOOK-ERROR'))
}
finally {
    Remove-Item -LiteralPath $stdinSandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Cost report aggregation (QA-005) ------------------------------------
#
# The Stop hook fires at the end of every assistant response, not once per
# session, and each record carries CUMULATIVE totals re-read from the whole
# transcript. The report must therefore keep only the latest snapshot per
# sessionId; summing raw snapshots inflates sessions, tokens and duration.

$reportScript = Join-Path $root 'Tools\Get-AICostReport.ps1'
Assert-True 'cost report script exists' (Test-Path -LiteralPath $reportScript -PathType Leaf) $reportScript

$costSandbox = Join-Path ([IO.Path]::GetTempPath()) ("bravo-cost-test-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    $costLogDir = Join-Path $costSandbox '.claude\logs'
    New-Item -ItemType Directory -Path $costLogDir -Force | Out-Null
    $costLog = Join-Path $costLogDir 'ai-cost.jsonl'

    $records = @(
        '{"recordedAt":"2026-10-12T01:00:00.0000000+03:00","sessionId":"s1","models":["claude-opus-5"],"assistantTurns":3,"inputTokens":10,"outputTokens":100,"cacheCreationTokens":5,"cacheReadTokens":50,"agentCalls":{"scout":1},"codexCalls":{},"fallbackReasons":[],"durationMinutes":5.0}',
        '{"recordedAt":"2026-10-12T01:30:00.0000000+03:00","sessionId":"s1","models":["claude-opus-5"],"assistantTurns":7,"inputTokens":20,"outputTokens":200,"cacheCreationTokens":9,"cacheReadTokens":90,"agentCalls":{"scout":2},"codexCalls":{"codex_delegate:qa":1},"fallbackReasons":["quota"],"durationMinutes":12.0}',
        '{"recordedAt":"2026-10-12T02:00:00.0000000+03:00","sessionId":"s2","models":["claude-sonnet-5"],"assistantTurns":2,"inputTokens":1,"outputTokens":30,"cacheCreationTokens":0,"cacheReadTokens":4,"agentCalls":{"worker":1},"codexCalls":{},"fallbackReasons":[],"durationMinutes":3.0}'
    )
    Set-Content -LiteralPath $costLog -Value ($records -join "`r`n") -Encoding UTF8

    # Викликаємо в тому ж процесі: через дочірній powershell.exe об'єкт
    # повернувся б як текст, і перевіряти агрегати було б нічим.
    $report = & $reportScript -RepoRoot $costSandbox -AsObject
    Assert-True 'cost report returns an object' ($null -ne $report)
    if ($null -ne $report) {
        Assert-Equal 'two cumulative snapshots of one session count as one session' '2' ([string]$report.Sessions)
        Assert-Equal 'only the latest snapshot per session is counted (turns)' '9' ([string]$report.AssistantTurns)
        Assert-Equal 'only the latest snapshot per session is counted (output tokens)' '230' ([string]$report.OutputTokens)
        Assert-Equal 'only the latest snapshot per session is counted (cache reads)' '94' ([string]$report.CacheReadTokens)
        Assert-Equal 'agent calls are not double counted' '2' ([string]$report.AgentCalls['scout'])
        Assert-Equal 'duration is not double counted' '15' ([string]$report.TotalMinutes)
        Assert-Equal 'codex calls come from the latest snapshot' '1' ([string]$report.CodexCalls['codex_delegate:qa'])
        Assert-Equal 'fallback reasons come from the latest snapshot' '1' ([string]$report.FallbackReasons['quota'])
    }
}
finally {
    Remove-Item -LiteralPath $costSandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Summary -------------------------------------------------------------

Write-Host ''
Write-Host ("Total: {0}  Failures: {1}" -f $script:total, $script:failures)
if ($script:failures -gt 0) { exit 1 }
exit 0
