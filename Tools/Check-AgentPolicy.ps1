#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot
)

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    # PowerShell 5.1: $PSScriptRoot не завжди доступний у виразі default-значення
    # param()-блоку при #requires + CmdletBinding — відтворено емпірично; резолв
    # переносимо в тіло скрипта, де $PSScriptRoot гарантовано заповнений.
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.Generic.List[string]

function Assert-FileExists {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $failures.Add("Missing required file: $Path")
    }
}

function Assert-Contains {
    param([string]$Path, [string]$Pattern, [string]$Message)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text -notmatch $Pattern) {
        $failures.Add($Message)
    }
}

function Assert-NotContains {
    param([string]$Path, [string]$Pattern, [string]$Message)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text -match $Pattern) {
        $failures.Add($Message)
    }
}

# Canonical tracked policy anchor is .claude/CLAUDE.md (the file origin/developer
# actually tracks), not a root CLAUDE.md -- root CLAUDE.md is not part of the
# repository's canonical policy surface and is intentionally not checked here.
$policy = Join-Path $RepoRoot 'BRAVO_AGENT_POLICY.md'
$dotClaudeClaude = Join-Path $RepoRoot '.claude\CLAUDE.md'
$agents = Join-Path $RepoRoot 'AGENTS.md'
$orchestrate = Join-Path $RepoRoot '.claude\skills\orchestrate\SKILL.md'
$reviewer = Join-Path $RepoRoot '.claude\agents\reviewer.md'
$scout = Join-Path $RepoRoot '.claude\agents\scout.md'
$tester = Join-Path $RepoRoot '.claude\agents\tester.md'
$worker = Join-Path $RepoRoot '.claude\agents\worker.md'

@($policy, $dotClaudeClaude, $agents, $orchestrate, $reviewer) | ForEach-Object { Assert-FileExists $_ }

# Referential integrity: a rule-file path referenced anywhere in the portable
# policy surface (e.g. `.claude/rules/05-architecture.md`) must actually exist
# as a tracked file. A reference to a path under a sibling root that was never
# committed (`.agents/rules/...` when only `.claude/rules/...` is tracked) is a
# silent authority gap: a harness following the reference loads nothing and
# cannot tell that loading failed.
function Assert-ReferencedRuleFilesExist {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $text = [System.IO.File]::ReadAllText($Path)
    $ruleRefs = [System.Text.RegularExpressions.Regex]::Matches($text, '\.(?:agents|claude)/rules/[A-Za-z0-9_.\-]+\.md')
    foreach ($ref in $ruleRefs) {
        $relative = $ref.Value -replace '/', '\'
        $candidate = Join-Path $RepoRoot $relative
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $failures.Add("Referenced rule file does not exist: $($ref.Value) (referenced in $Path)")
        }
    }
}

@($policy, $dotClaudeClaude, $agents, $orchestrate, $reviewer, $scout, $tester, $worker) |
    ForEach-Object { Assert-ReferencedRuleFilesExist $_ }

Assert-Contains $dotClaudeClaude 'BRAVO_AGENT_POLICY\.md' '.claude/CLAUDE.md must reference canonical BRAVO_AGENT_POLICY.md.'
Assert-Contains $agents 'BRAVO_AGENT_POLICY\.md' 'AGENTS.md must reference canonical BRAVO_AGENT_POLICY.md.'
Assert-Contains $policy 'No agent may publish, paste, transmit, or embed a link to any chat' 'Canonical policy must contain the chat-link prohibition.'
Assert-Contains $policy 'claude-qa-fallback' 'Canonical policy must contain the Claude QA fallback contract.'
Assert-Contains $policy 'P0' 'Canonical policy must define the P0-P3 severity model.'
Assert-Contains $policy '\*\*P1\*\*' 'Canonical policy must define P1.'
Assert-Contains $policy '\*\*P2\*\*' 'Canonical policy must define P2.'
Assert-Contains $policy '\*\*P3\*\*' 'Canonical policy must define P3.'
Assert-Contains $orchestrate 'codex_delegate' 'Orchestrator must integrate codex_delegate.'
Assert-Contains $orchestrate 'quota/usage limit' 'Orchestrator must implement the Codex limit fallback rule.'
Assert-Contains $reviewer 'claude-qa-fallback' 'Reviewer must support the explicit Claude QA fallback mode.'
Assert-Contains $reviewer 'P0/P1/P2/P3 only' 'Reviewer policy must mandate P0/P1/P2/P3-only findings.'

# Fallback reason must stay restricted to quota/rate-limit/service-unavailable.
Assert-Contains $policy 'fallback_reason:\s*quota \| rate-limit \| service-unavailable' 'Canonical policy must restrict fallback_reason to quota|rate-limit|service-unavailable.'

# Fallback must not be usable to hide MCP/config/protocol/code/test failures.
Assert-Contains $policy 'not\*\* allowed to hide (bridge defects|MCP)' 'Canonical policy must forbid using the Claude QA fallback to hide MCP/config/protocol/code failures.'
Assert-Contains $policy 'configuration errors, protocol errors, parsing failures, test failures, or implementation bugs' 'Canonical policy must enumerate the failure classes the fallback may not hide.'

Assert-NotContains $policy 'Any child process must be started as `powershell\.exe`' 'Old over-broad child-process rule detected.'
Assert-NotContains $reviewer '(?im)^\s*[-*]?\s*(blocker|should-fix|nit)\s*:\s*$' 'Legacy reviewer severity labels detected; use P0-P3.'
Assert-NotContains $orchestrate 'harnessmachine/codex-orchestrate' 'Legacy standalone codex-orchestrate dependency detected.'
Assert-NotContains $orchestrate 'standalone codex-orchestrate' 'Standalone codex-orchestrate dependency detected; route Codex only through codex_delegate/claude-codex-a2a.'

# --- Routing matrix wiring ----------------------------------------------
#
# The matrix (.claude/ai-routing.json) is the machine-readable source of truth
# for role-to-model assignment, risk-level gates and fallback limits. Detailed
# behavior is covered by .claude/hooks/tests/Test-AIRouting.ps1; the checks here
# guard the policy surface: the matrix must exist, parse, stay consistent with
# the agent files Claude Code actually loads, and be referenced from every
# canonical document that claims authority over agent orchestration.

$matrixPath = Join-Path $RepoRoot '.claude\ai-routing.json'
$settingsPath = Join-Path $RepoRoot '.claude\settings.json'
$routingHook = Join-Path $RepoRoot '.claude\hooks\validate-agent-routing.ps1'
$routingTests = Join-Path $RepoRoot '.claude\hooks\tests\Test-AIRouting.ps1'

@($matrixPath, $settingsPath, $routingHook, $routingTests) | ForEach-Object { Assert-FileExists $_ }

Assert-Contains $policy 'ai-routing\.json' 'Canonical policy must name .claude/ai-routing.json as the role/model source of truth.'
Assert-Contains $agents 'ai-routing\.json' 'AGENTS.md must reference .claude/ai-routing.json.'
Assert-Contains $dotClaudeClaude 'ai-routing\.json' '.claude/CLAUDE.md must reference .claude/ai-routing.json for delegation.'
Assert-Contains $orchestrate 'ai-routing\.json' 'Orchestrator must resolve roles/models from .claude/ai-routing.json.'
Assert-Contains $settingsPath 'validate-agent-routing\.ps1' 'settings.json must register the PreToolUse routing hook.'
Assert-Contains $settingsPath '"PreToolUse"' 'settings.json must declare a PreToolUse hook entry.'

if (Test-Path -LiteralPath $matrixPath -PathType Leaf) {
    $matrix = $null
    try {
        $matrix = [System.IO.File]::ReadAllText($matrixPath) | ConvertFrom-Json
    }
    catch {
        $failures.Add("Routing matrix is not valid JSON: $($_.Exception.Message)")
    }

    if ($null -ne $matrix) {
        if ([string]$matrix.schemaVersion -cne '1') {
            $failures.Add('Routing matrix schemaVersion must be 1.')
        }
        if ($null -eq $matrix.roles -or @($matrix.roles.PSObject.Properties).Count -eq 0) {
            $failures.Add('Routing matrix defines no roles.')
        }

        # Fallback limits must not drift wider than canonical policy section 8.2.
        $allowedReasons = @($matrix.fallback.allowedReasons)
        $expectedReasons = @('quota', 'rate-limit', 'service-unavailable')
        if (($allowedReasons.Count -ne $expectedReasons.Count) -or (@($allowedReasons | Where-Object { $expectedReasons -notcontains $_ }).Count -gt 0)) {
            $failures.Add('Routing matrix fallback.allowedReasons must be exactly quota, rate-limit, service-unavailable.')
        }
        if ($matrix.fallback.secondLevelFallback -ne $false) {
            $failures.Add('Routing matrix must not enable a second-level fallback to a weaker model.')
        }
        foreach ($gate in @('codex-security', 'codex-architecture', 'codex-verification')) {
            if (@($matrix.fallback.gatesFallbackMayNotSatisfy) -notcontains $gate) {
                $failures.Add("Routing matrix must keep '$gate' outside what the Claude fallback may satisfy.")
            }
        }

        # Matrix and agent files must agree, in both directions.
        $agentsDir = Join-Path $RepoRoot '.claude\agents'
        foreach ($roleName in $matrix.roles.PSObject.Properties.Name) {
            $agentFile = Join-Path $agentsDir ($roleName + '.md')
            if (-not (Test-Path -LiteralPath $agentFile -PathType Leaf)) {
                $failures.Add("Routing matrix role '$roleName' has no agent file: .claude/agents/$roleName.md")
                continue
            }
            $agentText = [System.IO.File]::ReadAllText($agentFile)
            $modelMatch = [System.Text.RegularExpressions.Regex]::Match($agentText, '(?m)^model:\s*(?<model>[A-Za-z0-9._\-\[\]]+)\s*$')
            if (-not $modelMatch.Success) {
                $failures.Add("Agent '$roleName' declares no model in frontmatter.")
            }
            elseif ($modelMatch.Groups['model'].Value -cne [string]$matrix.roles.$roleName.model) {
                $failures.Add("Agent '$roleName' model '$($modelMatch.Groups['model'].Value)' does not match routing matrix model '$([string]$matrix.roles.$roleName.model)'.")
            }
            if ($agentText -notmatch 'BRAVO_AGENT_POLICY\.md') {
                $failures.Add("Agent '$roleName' must reference canonical BRAVO_AGENT_POLICY.md.")
            }
            if ($agentText -notmatch '(?m)^HANDOFF\s*$') {
                $failures.Add("Agent '$roleName' must carry the canonical HANDOFF block.")
            }
        }

        if (Test-Path -LiteralPath $agentsDir -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File)) {
                $agentName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                if ($null -eq $matrix.roles.$agentName) {
                    $failures.Add("Agent file .claude/agents/$($file.Name) is absent from the routing matrix.")
                }
            }
        }
    }
}

# --- Commit authorship ---------------------------------------------------
#
# Owner policy: no AI-authorship trailers in new commits. This checks only the
# commits this branch adds on top of origin/developer, so historical commits are
# never rewritten or flagged. Absent git / absent origin/developer is reported as
# a skip, not a pass, because a missing check is not evidence.

$authorshipPatterns = @(
    'Co-Authored-By:\s*Claude',
    'Co-authored-by:\s*Claude',
    'Generated with \[?Claude',
    'Claude-Session:',
    'noreply@anthropic\.com'
)

$gitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
if (-not $gitAvailable) {
    Write-Host 'NOTE: commit-authorship check SKIPPED - git not available.'
}
else {
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $baseRef = 'origin/developer'
        & git -C $RepoRoot rev-parse --verify --quiet $baseRef *>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "NOTE: commit-authorship check SKIPPED - $baseRef not available locally."
        }
        else {
            $log = & git -C $RepoRoot log "$baseRef..HEAD" --format='%H%x1f%an%x1f%ae%x1f%B%x1e' 2>$null
            if ($LASTEXITCODE -eq 0 -and $null -ne $log) {
                # Windows PowerShell 5.1: немає escape `u{...}, тому розділювачі
                # беремо через [char] — git віддає їх як %x1f / %x1e.
                $unitSeparator = [string][char]0x1f
                $recordSeparator = [string][char]0x1e
                $joined = ($log -join "`n")
                foreach ($record in ($joined -split $recordSeparator)) {
                    if ([string]::IsNullOrWhiteSpace($record)) { continue }
                    $parts = $record -split $unitSeparator
                    if ($parts.Count -lt 4) { continue }
                    $sha = $parts[0].Trim()
                    $body = $parts[3]
                    foreach ($pattern in $authorshipPatterns) {
                        if ($body -match $pattern) {
                            $failures.Add("Commit $($sha.Substring(0, [Math]::Min(8, $sha.Length))) contains a forbidden AI-authorship trailer matching '$pattern'.")
                        }
                    }
                }
            }
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'BRAVO agent policy check: FAIL'
    foreach ($failure in $failures) {
        Write-Host (" - " + $failure)
    }
    exit 1
}

Write-Host 'BRAVO agent policy check: PASS'
Write-Host 'Canonical policy (.claude/CLAUDE.md anchor), A2A routing, Claude QA fallback (with restricted reason + no-hide guarantee), P0-P3 severity, and chat-link prohibition are present.'
exit 0
