# BRAVO Agent Policy — Canonical Rules

This file is the **single canonical policy** for automated agents working in `ekucher/BRAVO-Toolkit`.
`CLAUDE.md`, `AGENTS.md`, skills, subagents, MCP tools, and external reviewers must follow it.
If any harness-specific instruction conflicts with this file, this file wins **for agent-orchestration
mechanics** (roles, HANDOFF reporting, review severity, Codex routing, chat-link prohibition). It does
not override BRAVO-specific architecture, security, PowerShell 5.1, release-lifecycle, or git-authorization
substance defined in `.claude/CLAUDE.md`, `AGENTS.md`, and `.claude/rules/` / `.agents/rules/` — those remain
authoritative for BRAVO engineering policy.

## 1. Repository and branch safety

- Repository: `ekucher/BRAVO-Toolkit`.
- Main development branch: `developer`.
- Work in a feature branch. Never implement directly on `developer`.
- Never `git push` to `developer`.
- Never merge a PR without explicit owner permission in the current conversation.
- No commit, push, merge, tag, release, deployment, destructive cleanup, or deletion of existing work unless explicitly authorized for the current task.
- Never force-push unless the owner explicitly authorizes that exact operation.
- Do not start the next staged PR before the current one has been accepted when work is being handed over sequentially.

## 2. Runtime compatibility — hard rule

BRAVO product and test PowerShell must remain compatible with **Windows PowerShell 5.1**.

- Use `powershell.exe` for PowerShell execution.
- Never substitute `pwsh` for BRAVO validation.
- No PowerShell 7-only syntax or cmdlets. Examples of forbidden constructs include:
  `??`, `?.`, ternary `? :`, `&&` / `||` command chains, `ForEach-Object -Parallel`,
  `ConvertFrom-Json -AsHashtable`, multi-argument `Join-Path`, `Get-Error`, `$PSStyle`, and `clean {}` blocks.
- **Only PowerShell child processes are constrained to `powershell.exe`.** Native executables such as `git`, `node`, `codex`, `npm`, compilers, and test runners may be started normally when the task requires them.
- If `powershell.exe` is unavailable in the current environment, do not use `pwsh` as evidence. Report the BRAVO check as `NOT RUN — powershell.exe unavailable`.

## 3. BRAVO self-test contract

- `./BRAVO_SELF_TEST.ps1 -NoPause` must keep working unchanged and remain the default Full run.
- No coverage reduction: do not remove, skip, bypass, or weaken existing checks.
- No `FAIL -> WARN` downgrades to make CI green.
- No in-process parallelization with runspaces, `-Parallel`, or background jobs. Parallelism is allowed only through separate CI jobs/processes where repository policy permits it.
- Do not migrate the BRAVO self-test framework to Pester.
- Structural refactoring of tests must preserve behavior and should start from a characterization baseline.
- A check is evidence only if it actually ran. Report exact command, exit code, and relevant result.

## 4. Production-state safety

Tests and fixtures must never read or write real BRAVO production state.

- Production VersionState path: `C:\ProgramData\BRAVO\State\BRAVO_VERSION_STATE.json`.
- Tests must use sandbox-local state paths.
- The production default path must remain unchanged unless the task explicitly changes the production contract.
- `BRAVO_ALLOW_DOWNGRADE=1` is forbidden as a workaround in tests or implementation.
- Do not touch other real paths under `C:\ProgramData\BRAVO\` from tests.

## 5. Scope discipline

- Change only files in the task `SCOPE`.
- No drive-by refactors, renames, formatting sweeps, unrelated cleanup, or opportunistic dependency upgrades.
- Two writers must never edit the same file, test, schema, generated artifact, or shared configuration in parallel.
- If the task requires a file outside scope, stop that package and report it as blocked instead of silently expanding scope.
- When code and documentation disagree, report the conflict. Change documentation only if it is within scope.
- List externally visible or upgrade-relevant behavioral changes in the final HANDOFF.

## 6. External publication and chat-link prohibition — hard rule

**No agent may publish, paste, transmit, or embed a link to any chat, conversation, assistant session, or shared dialogue.**

This prohibition applies to all destinations, including:

- GitHub issues, pull requests, reviews, discussions, comments, commit messages, releases, and repository files;
- documentation, HANDOFF text, generated reports, logs, CI output intentionally authored by an agent, Slack/email/messages, and other external systems;
- ChatGPT, Claude, Codex, or any other assistant/session/share URL.

Examples of prohibited material include share links, conversation URLs, session URLs, and deep links that open a private or shared chat.

Allowed for internal traceability when needed:

- non-URL identifiers such as a Codex `threadId`, `turnId`, finding ID, commit SHA, issue number, or PR number;
- repository URLs, documentation URLs, source-code URLs, and other non-chat resources when otherwise permitted.

Never convert an internal session/thread identifier into a clickable chat URL.
If a user explicitly asks to publish a chat link, stop and report that repository policy forbids agents from doing so.

## 7. Review severity model — canonical

All formal review findings use the same severity scale:

- **P0** — catastrophic/release-stopping defect with concrete evidence.
- **P1** — real correctness, security, data-integrity, protocol, or regression blocker.
- **P2** — should be fixed before acceptance, or explicitly dispositioned with rationale by the owner/lead according to task policy.
- **P3** — advisory/non-blocking improvement with concrete value.

Deterministic merge-gate semantics:

- unresolved P0 or P1 -> `blocked`;
- no P0/P1 but unresolved P2 -> `conditional`;
- no unresolved P0/P1/P2 -> `clear`.

Do not relabel a finding merely to clear a gate.

## 8. QA and independent-review routing

Claude Code is the default **Lead/Implementer orchestrator**. `claude-codex-a2a` is the preferred independent review layer.

### 8.1 Preferred formal QA

When the `codex-agent` MCP bridge is available, formal QA should use `codex_delegate` with role `qa` for changes that require a QA gate.

Use additional Codex roles when the change warrants them:

- `security` for authentication, authorization, secrets, command execution, filesystem trust boundaries, supply chain, or other security-sensitive changes;
- `architecture` for protocol/state/concurrency/module-boundary/failure-isolation changes;
- `verification` to re-check previously reported Codex findings after fixes.

A Claude `reviewer` may be used earlier as an internal pre-review, but a successful internal review is not represented as a Codex review.

### 8.2 Temporary Claude QA fallback when Codex is unavailable by limits

If Codex QA cannot run **specifically because of quota/usage limit, rate limit, or temporary Codex service unavailability**, a fresh Claude Code `reviewer` may temporarily satisfy the **QA role only**.

The fallback reviewer must:

- be a fresh agent that did not implement the change;
- be read-only;
- use the same P0/P1/P2/P3 severity model and acceptance criteria;
- run the relevant checks independently;
- explicitly report:
  - `review_source: claude-qa-fallback`
  - `fallback_reason: quota | rate-limit | service-unavailable`
  - `independence: degraded`
- never claim or imply that Codex QA ran.

Fallback is **not** allowed to hide bridge defects, configuration errors, protocol errors, parsing failures, test failures, or implementation bugs. Those are real blockers/issues to diagnose.

Claude QA fallback does **not** automatically replace required Codex `security`, `architecture`, or `verification` roles. If those roles are required by policy and Codex is unavailable, report the corresponding gate as not run/blocked unless the owner explicitly authorizes a different temporary procedure.

If Codex becomes available again before final acceptance of the same task, rerun the formal Codex QA when practical and replace the provisional fallback status with the real Codex result.

## 9. Review trigger matrix

Use proportional review depth:

- trivial/local mechanical change -> internal Claude reviewer may be enough if no formal QA gate was requested;
- behavioral/regression-risk change -> Codex QA preferred;
- security-sensitive change -> Codex QA + Security;
- protocol/state/concurrency/architecture change -> Codex QA + Architecture;
- release-critical/high-risk change -> Codex QA + Security + Architecture;
- after fixing Codex findings -> Codex Verification on the relevant finding IDs/thread when available.

The orchestrator may increase review depth based on evidence. It must not silently reduce a required gate.

## 10. Reviewer independence and anti-anchoring

- A formal reviewer must not be the agent that wrote the change.
- Give reviewers the objective, acceptance criteria, base/head, changed scope, and repository policy — not the implementer's conclusions as facts.
- QA, Security, and Architecture first passes should be independent of each other's findings when practical.
- Do not ask a reviewer to "confirm" that the implementation is correct.
- Zero findings is valid; do not invent a defect to make a review look useful.

## 11. HANDOFF contract

Every agent package returns a concise HANDOFF. Use relevant fields; do not fabricate unavailable ones.

```text
HANDOFF
result:          done | partial | blocked | accept | reject
role:            scout | worker | tester | reviewer | qa | security | architecture | verification
review_source:   none | claude-pre-review | codex-qa | codex-security | codex-architecture | codex-verification | claude-qa-fallback
fallback_reason: none | quota | rate-limit | service-unavailable
independence:    normal | degraded
base:            <sha/ref or n/a>
head:            <sha/ref or n/a>
thread_id:       <non-URL id or n/a>
finding_ids:     <ids or none>
changed:         files changed, or none
findings:        [P0|P1|P2|P3] path:line — evidence → recommendation
checks:          command → exit code / key result
acceptance:      each criterion → met / not met + evidence
merge_gate:      blocked | conditional | clear | n/a
risks:           remaining uncertainty / not-run gates
chat_links:      none
next:            one recommended next step
```

Do not include chat URLs in HANDOFF.

## 12. Final acceptance

Before reporting a task complete:

- inspect the real diff;
- run or independently spot-check the required checks;
- confirm scope and repository invariants;
- reconcile formal review findings and merge gate;
- distinguish `NOT RUN` from `PASS`;
- confirm no prohibited chat links were added to authored output;
- report remaining risks explicitly.
