# BRAVO-Toolkit — Current Project State

Last verified: 2026-09-21

## Canonical branch

`developer`

## Canonical HEAD

`b5d1691d58f40b6b0a52408e5a628ddd209973b7`

Before starting substantial work, verify:

```powershell
git fetch origin --prune
git status --short
git branch --show-current
git rev-parse HEAD
git rev-parse origin/developer
```

If `origin/developer` differs from the recorded canonical HEAD, determine which commits or PRs were added and whether they invalidate the recorded `NEXT ACTION`.

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

Issue #216 — Wave 0:

**Baseline + Configuration Graph Inventory + Default-Parity Gap Map**

Wave 0 is evidence-only.

No Config V2 implementation changes are authorized during Wave 0.

Required analysis:

1. Verify current `developer` baseline.
2. Run current canonical validation.
3. Inspect current release artifact composition.
4. Inventory every meaningful `BRAVO.config` dependency.
5. Classify each dependency by role.
6. Trace production configuration call graphs.
7. Inventory effective configuration keys from actual consumers.
8. Determine source/provenance for every effective key.
9. Identify settings whose only remaining source is legacy `BRAVO.config`.
10. Audit the allowed `BRAVO.local.config` override surface.
11. Audit `-ConfigPath` semantics and call sites.
12. Audit migration/pilot isolation.
13. Audit Runtime Guard.
14. Audit clean-install and 5.2 → 5.3 update paths.
15. Audit release artifact composition.
16. Map current tests to final Config V2 invariants.
17. Identify exact cutover blockers.
18. Design atomic implementation waves.
19. Select exactly one recommended first implementation wave.

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

Execute **Issue #216 Wave 0** against:

```text
origin/developer
expected baseline:
b5d1691d58f40b6b0a52408e5a628ddd209973b7
```

Requirements:

* use an isolated worktree;
* evidence-only;
* do not modify repository files;
* do not implement the Config V2 cutover.

Expected final classification:

```text
ISSUE #216 BASELINE COMPLETE — READY FOR IMPLEMENTATION WAVES
```

or:

```text
ISSUE #216 BASELINE BLOCKED
```

with exact evidence.

After Wave 0, replace this `NEXT ACTION` with the exact approved first implementation wave.

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
2. Update Canonical HEAD.
3. Keep completed work concise.
4. Record actual validation evidence.
5. Remove stale blockers.
6. Update active issue/PR.
7. Replace `NEXT ACTION` with one concrete executable next step.

Do not turn this file into a chronological session log.

Keep only information necessary for the next Claude Code session.
