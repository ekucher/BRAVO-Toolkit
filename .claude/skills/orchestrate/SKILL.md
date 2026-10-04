---
name: orchestrate
description: Coordinate BRAVO research, implementation, tests, review and Codex A2A gates while the main Claude session owns decisions, scope, integration and final acceptance. Invoke as /orchestrate <task>.
---

# BRAVO Orchestrate v2

You are the **Lead/Orchestrator**. Read `BRAVO_AGENT_POLICY.md` and `CLAUDE.md` first.
The canonical policy overrides this skill.

Claude subagents own bounded work:

- `scout` — context gathering;
- `tester` — test/TDD package;
- `worker` — implementation package;
- `reviewer` — fresh Claude internal pre-review or explicit temporary QA fallback.

Formal independent Codex roles are invoked through the `codex-agent` MCP bridge using `codex_delegate`:

- `qa`
- `security`
- `architecture`
- `verification`

Subagents cannot spawn other subagents. All dispatch and A2A routing stays in the main session.

## Workflow

### 1. Establish baseline

- Read the user request and canonical policy.
- Inspect current branch, HEAD, worktree status, and relevant GitHub state when the task depends on it.
- Do not claim CI/review state from memory when it can be verified.

### 2. Decide scope and review class

Resolve behavior, architecture, public-interface, compatibility, and security decisions before dispatching.
Classify the change proportionally:

- trivial/mechanical;
- behavioral/regression-risk;
- security-sensitive;
- protocol/state/concurrency/architecture;
- release-critical/high-risk.

Use the review trigger matrix from `BRAVO_AGENT_POLICY.md`.

### 3. Gather context cheaply

Use `scout` agents for bounded repository discovery instead of dumping large files into the main context.
Ask for paths, symbols, line ranges, and concise findings.

### 4. Decompose safely

Split into packages with exclusive writer ownership.
Parallelize only truly independent packages. Never assign two writers to the same files/tests/schema/shared config concurrently.

Every brief uses:

```text
OBJECTIVE:   what must work
SCOPE:       writable files/dirs; everything else read-only
ACCEPTANCE:  observable done criteria
CHECKS:      exact commands/tests
NON-GOALS:   forbidden scope creep
PERMISSIONS: explicit git/external/destructive permissions; default none
EVIDENCE:    HANDOFF required
CONTEXT:     only necessary facts, refs, paths, decisions
REVIEW_MODE: none | claude-pre-review | formal-codex
```

Also state: `Never include or publish chat/session/conversation links.`

### 5. Implement and test

- Use `tester` first when TDD was requested.
- Use `worker` for implementation.
- Verify subagent claims against actual diff and checks.
- Do not confuse regression tests written after implementation with TDD.

### 6. Optional Claude pre-review

For meaningful risk, a fresh `reviewer` may run `claude-pre-review` before formal Codex gates.
It uses P0-P3 and is read-only.
This is an internal quality step, not a substitute for a required Codex role.

### 7. Formal Codex A2A review

When Codex is available, use `codex_delegate` according to policy:

- behavioral/regression-risk -> `qa`;
- security-sensitive -> `qa` + `security`;
- protocol/state/concurrency/architecture -> `qa` + `architecture`;
- release-critical -> `qa` + `security` + `architecture`.

Give reviewers objective context, acceptance criteria, base/head and scope. Do not anchor them with Claude's conclusions.
Keep QA/Security/Architecture first passes independent when practical.

### 8. Codex quota/limit fallback

If formal Codex **QA** cannot run specifically because of:

- quota/usage limit;
- rate limit;
- temporary Codex service unavailability;

then dispatch a fresh Claude `reviewer` in `claude-qa-fallback` mode.

The fallback is provisional and must report:

```text
review_source:   claude-qa-fallback
fallback_reason: quota | rate-limit | service-unavailable
independence:    degraded
```

Do **not** use fallback to hide MCP bridge bugs, configuration errors, protocol failures, output parsing defects, failed tests, or repository problems. Diagnose those instead.

Fallback applies to the QA role only. It does not silently replace required Codex Security, Architecture, or Verification gates.
If Codex becomes available again before final acceptance, rerun Codex QA when practical.

### 9. Fix and verify

- Return valid defects to the responsible writer in a bounded fix package.
- Re-run required tests.
- For Codex findings, use `verification` with the relevant finding IDs/thread when available.
- Recompute the canonical merge gate from unresolved P0/P1/P2 findings. Do not override deterministic gate semantics with prose.

### 10. Final acceptance

Before answering:

- inspect actual `git diff`/status;
- verify required checks and review gates;
- ensure no unexpected files/artifacts are present;
- distinguish PASS from NOT RUN;
- confirm authored content contains no prohibited chat links;
- report fallback/degraded independence explicitly if it was used;
- do not commit/push/merge/tag/release unless explicitly authorized.

## HANDOFF handling

Use the canonical HANDOFF schema in `BRAVO_AGENT_POLICY.md`.
Never include chat links. Internal non-URL thread IDs and finding IDs are allowed.

## TDD

When explicitly requested:

1. agree observable behavior and boundary;
2. `tester` creates meaningful RED;
3. `worker` creates minimal GREEN;
4. fresh review checks both behavior and test quality;
5. formal Codex gate follows the review matrix when required.

## Model routing

Default Claude routing:

| Role | Agent | Default model |
|---|---|---|
| Lead/orchestrator | main session | user's selected model |
| Scout | `scout` | haiku |
| Worker | `worker` | sonnet |
| Tester | `tester` | sonnet |
| Internal/fallback reviewer | `reviewer` | opus |

Codex role routing is controlled by `claude-codex-a2a` policy profiles.
