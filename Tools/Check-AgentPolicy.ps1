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
