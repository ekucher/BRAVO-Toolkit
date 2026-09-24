# BRAVO-Toolkit — Current Project State

Last verified: 2026-09-24

## Canonical branch

`developer`

## State baseline SHA

`3e9e172a4b1fc1b41da8066b105ff46dadf66cb3`

Before starting substantial work, verify:

```powershell
git fetch origin --prune
git status --short
git branch --show-current
git rev-parse HEAD
git rev-parse origin/developer
```

This SHA is the `developer` commit against which this handoff state was verified. It is intentionally not a self-referential "current HEAD" and may differ from the commit that contains this file after the handoff itself is committed or merged.

If `origin/developer` differs from the recorded state baseline SHA, inspect the commits/PRs added since the baseline and determine whether they invalidate the recorded `NEXT ACTION`. Do not treat the difference itself as an error.

## Current objective

GitHub Issue #216:

**P0: Complete BRAVO 5.3 Config V2 cutover — remove BRAVO.config from runtime contract**

Final BRAVO 5.3 runtime configuration contract:

```text
Built-in canonical defaults
    + BRAVO.local.config
    + Windows Credential Manager
    + deterministic derivation
    = Effective Configuration
```

Normal BRAVO 5.3 production execution must not read, locate, execute, dot-source, parse, or fall back to `BRAVO.config`.

Legacy `BRAVO.config` may remain only where explicitly justified for:

* supported 5.2 → 5.3 migration;
* migration tests and fixtures;
* parity evidence;
* historical documentation.

It must not remain part of the normal 5.3 runtime configuration graph.

## Recently completed

### Wave 1A — Credential transaction correctness

PR #217 merged.

Purpose: make transactional credential rollback SecureString-safe.

Merge commit:

`97a502b7935925872ee4de40f04883ff56ad9a77`

### Wave 1B — BazaSync MutationPolicy

PR #218 merged.

Purpose: invalid `MutationPolicy` fails closed.

Merge commit:

`f93de16df7e811da404ae722d5526c9be3d59cee`

### Config parity governance

PR #214 merged.

Purpose: make Config parity safe for promotion to a required status check.

Merge commit:

`22eebc6a25f7b3a2fb83e5609f7007d8d08486e6`

Live GitHub Actions proved both paths:

```text
RELEVANT PR
    -> Config foundation parity executes
    -> success

NOT APPLICABLE PR
    -> canonical Config parity check still exists
    -> Config foundation parity skipped
    -> N/A step succeeds
```

### Config parity required promotion

PR #220 provided the live docs-only N/A proof and was merged.

Merge commit:

`b5d1691d58f40b6b0a52408e5a628ddd209973b7`

`Config parity (BRAVO_CONFIG_LOADER)` is now a required check on `developer`.

Recorded required checks:

* Parser / BOM / JSON
* PSScriptAnalyzer
* BRAVO_SELF_TEST.ps1
* Secret scanning (gitleaks)
* GitGuardian Security Checks
* BRAVO_DATA_RESTORE_MATRIX_TEST.ps1
* Config parity (BRAVO_CONFIG_LOADER)

Recorded branch-protection setting:

`strict = true`

Promotion preserved all previously required checks and unrelated branch-protection settings.

Post-merge CI on current developer completed successfully.

### Persistent Claude handoff

PR #221 merged.

Purpose: add the cross-session startup/handoff protocol and `PROJECT_STATE.md` without changing BRAVO runtime behavior.

Merge commit:

`832e238efd5563e6be6bf91bc42e2f3767ade69c`

## Closed / superseded work

### PR #213

Closed, not merged.

Superseded by Issue #216.

Do not resurrect its large Config V2 documentation rewrite as-is.

### PR #215

Closed and deferred.

Do not cherry-pick or resurrect its broad self-test restructuring as-is.

Follow-up:

Issue #219 — **Self-test resilience: isolate fatal section failures without hiding remaining diagnostics**

Issue #219 remains backlog work unless explicitly reprioritized.

## Current active work

Issue #216 has progressed well past Wave 0 (see git/GitHub history for the
actual wave sequence — this file was not kept current through that
progression). The active unit of work now is **PR #224**
(`fix/config-v2-local-override-authorization` -> `developer`), worked in
isolated worktree `E:\GitHub\BRAVO-Toolkit-216-wave2`.

PR #224 state verified 2026-09-23: OPEN, MERGEABLE, base `developer`,
reviewDecision empty (no formal review decision recorded yet).

### PR #224 — F1 lazy dependency regression remediation (COMMITTED, PUSHED)

Context: PR #224 has been through multiple Codex review rounds (fixes
tracked informally as F1..F17-style labels in self-test comments, not a
formal numbering owned by this file). Push
`b1d705464030b9d907e78c4b9c5c87d0e1e7339e` fixed a Codex F1 finding
(unreliable `Get-Module` presence guard around a `BRAVO.System` import
inside `Test-BRAVOConfigurationAuthorizationTaskSchedulerPath`) but in
doing so introduced a **regression**: the `BRAVO.System` import was
moved to module-load time in `BRAVO.Configuration.Schema.psm1`'s
preamble, which broke the `Config v2 pilot artifact` GitHub Actions
workflow (that artifact intentionally does NOT bundle
`modules\BRAVO.System\` — `deploy/New-BRAVOConfigV2PilotArtifact.ps1:16`).
Independently rediscovered and confirmed by a 2026-09-24 read-only
project-wide audit (Phase 2/3/6).

This was root-caused and remediated in this worktree, restoring the
dependency to **lazy** (imported only inside
`Test-BRAVOConfigurationAuthorizationTaskSchedulerPath`, immediately
before `ConvertTo-BRAVOTaskPath`) while keeping it **unconditional** (no
`Get-Module` guard — the original Codex F1 finding stays fixed).

Committed and pushed 2026-09-24 with explicit user authorization:
commit `276d25755bdfd23b293029727b7cdb35f5425c3f` on
`fix/config-v2-local-override-authorization`, now = `origin/...` HEAD
(0 ahead/0 behind).

Working tree contents of that commit:

* `modules/BRAVO.Configuration/BRAVO.Configuration.Schema.psm1` — production fix.
* `selftest/BRAVO_SELF_TEST.Configuration.ps1` — corrected structural tests
  (`SchemaTaskPathImportHasNoProcessWidePresenceGuard`,
  `SchemaSystemDependencyIsLazyTaskPathOnly`) + new behavioral coverage
  (`SchemaTaskSchedulerPathLazilyLoadsSystemWhenUsed`,
  `SchemaImportAndUnrelatedAuthorizationSucceedWithoutSystemModule`).
* `RUNTIME_MANIFEST.json` — regenerated via `ci\Update-BRAVORuntimeManifest.ps1 -Apply`
  (exactly the 2 changed-file hashes; no unrelated drift).

Validation actually executed and passed in this worktree (see full 21-item
report in-session for exact evidence):

* Pilot artifact regression reproduced pre-fix, resolved post-fix (verified
  via a non-mutating simulation — see below — since the real builder reads
  content via `git show HEAD:...`, and HEAD cannot reflect an uncommitted
  fix without violating the no-commit boundary).
* Full `BRAVO_SELF_TEST.ps1`: **2483 PASS / 0 FAIL / 0 exceptions**,
  `SELF-TEST PASSED`, wall-clock ~12m28s.
* `ci\Invoke-BRAVOSecurityAnalysis.ps1`, `ci\Test-BRAVOForbiddenPattern.ps1`,
  `git diff --check`: all clean.
* F2 (UrlArray blank handling)/F3 (Configurator MultiRepresentation
  recovery)/F4 (LogLevel EnumTrimmed) regression fragments re-run
  standalone: 208/208 (Configuration) and 209/209 (Configurator) PASS.

Known environment quirk (not a defect): running
`BRAVO_SELF_TEST.ps1` via `-NonInteractive` without `-NoPause` hangs on a
"press any key" prompt after all checks already completed and were
logged — pass `-NoPause` next time to avoid needing to kill the process.

Known technique used for pilot-artifact validation without committing:
`deploy/New-BRAVOConfigV2PilotArtifact.ps1` and the self-test's
`New-BRAVOPilotSyntheticInstallRoot` both source content via
`git show`/`git archive` against a ref (default `HEAD`), by deliberate
design (byte-fidelity, independent of working-tree state) — so an
uncommitted fix is invisible to them. Validated instead via a scratch copy
of the self-test script with a `Copy-Item` overlay of the working-tree
file added right after the `git archive` extraction step — no git
mutation, only file copies, real logic otherwise unchanged. This is the
correct way to validate an uncommitted fix against `git`-ref-based
builders in this repository; reuse it rather than `git stash create` (a
stash operation is explicitly out of bounds under a "no stash" mutation
rule) or an actual commit.

## Issue #216 target invariants

The final implementation must eventually prove:

* clean 5.3 runtime contains no `BRAVO.config`;
* release artifact contains no `BRAVO.config`;
* normal production execution does not read it;
* an arbitrary adjacent `BRAVO.config` has zero effect;
* Archive, Maintenance, Health, and DataRestore use the same canonical Config V2 graph;
* local site overrides survive package updates;
* secrets remain outside repository configuration;
* supported 5.2 installations migrate without effective-config drift;
* migration is verified before legacy configuration is retired;
* migration is idempotent;
* production runtime cannot invoke the legacy migration reader;
* CI permanently enforces the final architecture.

Do not declare Issue #216 complete while normal BRAVO 5.3 execution retains any runtime fallback to `BRAVO.config`.

## NEXT ACTION

The F1 lazy dependency regression fix (see "Current active work" above)
was committed and pushed 2026-09-24 with explicit user authorization:
commit `276d25755bdfd23b293029727b7cdb35f5425c3f` on
`fix/config-v2-local-override-authorization`. PR #224 CI re-triggered on
this HEAD; `mergeStateStatus=BLOCKED` (branch protection requires all
checks green — several were still `pending`, including the pilot-artifact
check this fix targets, at last observation). No merge attempted or
authorized.

Before doing anything else, re-verify this state is still accurate
(`git status --short`, `git rev-parse HEAD`, `git rev-parse
origin/fix/config-v2-local-override-authorization`, `gh pr checks 224`) —
do not trust this file if the worktree, remote, or CI has moved.

```text
Re-check PR #224 CI on HEAD 276d257 (gh pr checks 224). If the pilot-
artifact check and all other required checks are now green, report
MERGE READY. If still failing, diagnose against the new HEAD before
assuming this fix was insufficient. Separately, PR #224 still carries 18
unresolved Codex review threads (2xP1 whitespace/enum-normalization
regressions, 16xP2) from the 2026-09-24 audit — decide with the user
whether those must be addressed before merge, independent of the CI
gate (developer branch protection does not require conversation
resolution or any approving review, so it is not a hard technical
blocker, only a project-policy one).
```

Commit/push of any further changes still require explicit user
authorization in the session, per standing project Git policy.

If state does NOT match (worktree dirty differently, HEAD moved, PR #224
closed/merged/retargeted): stop, establish actual current state from
git/GitHub, and do not proceed mechanically from this stale note.

## Standard workflow

```text
AUDIT
-> VERIFY FINDINGS
-> DEFINE ATOMIC WAVE
-> ISOLATED WORKTREE
-> IMPLEMENT
-> TARGETED TESTS
-> FULL SELF-TEST
-> DIFF / MANIFEST REVIEW
-> COMMIT only when authorized
-> PUSH only when authorized
-> CI
-> PR
-> MERGE only when authorized
-> UPDATE PROJECT_STATE
```

## Current hard stops

Unless explicitly authorized by the user:

* no commit;
* no push;
* no force-push;
* no amend;
* no reset;
* no rebase;
* no merge;
* no branch-protection mutation;
* no tag;
* no release;
* no remote branch deletion.

For Issue #216 Wave 0 specifically:

* no code changes;
* no test changes;
* no documentation changes;
* no manifest `-Apply`;
* no deletion of `BRAVO.config`;
* no cutover implementation.

## Source-of-truth order

If state differs:

```text
Git/GitHub factual state
    >
current repository code/tests/configuration
    >
PROJECT_STATE.md
    >
current plans/roadmaps
    >
historical PR descriptions / old session context
```

Never silently trust stale handoff state over repository evidence.

`PROJECT_STATE.md` is not authorization for commit, push, merge, release, branch-protection changes, or other mutations requiring explicit user approval.

## Handoff maintenance

After each substantial completed wave:

1. Verify canonical `origin/developer`.
2. Update State baseline SHA to the `developer` commit against which the handoff was actually verified. Do not try to make it equal to the commit that contains `PROJECT_STATE.md` itself.
3. Keep completed work concise.
4. Record actual validation evidence.
5. Remove stale blockers.
6. Update active issue/PR.
7. Replace `NEXT ACTION` with one concrete executable next step.

Do not turn this file into a chronological session log.

Keep only information necessary for the next Claude Code session.
