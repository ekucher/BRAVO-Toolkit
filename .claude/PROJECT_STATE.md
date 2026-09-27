# BRAVO-Toolkit — Current Project State

Last verified: 2026-09-27

## Canonical branch

`developer`

## State baseline SHA

`64a8b11327f46386b699c1e8a528815cb449a1c1`

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

**CORRECTION (2026-09-27, verified against live GitHub state, not trusted from this file):** the paragraph
below (previously claiming the promotion was applied) was **false**. Direct verification found:

```text
GET /repos/ekucher/BRAVO-Toolkit/branches/developer/protection -> HTTP 403
  (integration token lacks the Administration permission scope; this repo's
  installed GitHub App does not request that scope at all, so no
  installation-settings change can grant it)
GET /repos/ekucher/BRAVO-Toolkit/rulesets -> 200, only one ruleset
  ("protected-release-tags", target: tag) - nothing touching `developer`
GitHub UI screenshot of Settings -> Branches -> Branch protection rules:
  only `master` is listed ("Currently applies to 1 branch") - `developer`
  has NO classic protection rule either
```

**`developer` currently has zero branch protection of any kind** (no classic rule, no ruleset). None of the
required checks below are actually enforced; nothing currently blocks a merge into `developer` even with red
CI. The list, `strict` setting, and "promotion preserved..." claim that follow are **what a future branch
protection rule should contain when created**, not a record of an applied setting - do not repeat the error
of citing this file as evidence that it was applied.

Prepared (not yet applied) required-checks list, exact `pull_request`-event names (verified live against a
recent PR head commit, e.g. #231):

* Parser / BOM / JSON
* PSScriptAnalyzer
* BRAVO_SELF_TEST.ps1
* Secret scanning (gitleaks)
* GitGuardian Security Checks
* BRAVO_DATA_RESTORE_MATRIX_TEST.ps1
* Config parity (BRAVO_CONFIG_LOADER) — both required live proofs already exist (RUN on PR #214, NOT
  APPLICABLE on PR #221/#231), so it is ready to include once the rule is created

Recommended settings for the `developer` rule: PR required, the 7 checks above required, `strict = false`
(per `RELEASE_POLICY.md` §13.2/§13.3 — `developer`, unlike `master`, does not require an up-to-date branch),
`enforce_admins = true`, force-push and branch deletion disabled.

Creating this branch-protection rule requires either (a) the repository owner doing it directly in the
GitHub UI, or (b) a credential with the `Administration` scope (a PAT), since the installed GitHub App
structurally cannot obtain it. This is a pending action, not completed work.

### Persistent Claude handoff

PR #221 merged.

Purpose: add the cross-session startup/handoff protocol and `PROJECT_STATE.md` without changing BRAVO runtime behavior.

Merge commit:

`832e238efd5563e6be6bf91bc42e2f3767ade69c`

### Issue #216 Wave B — B4 part 2 (2026-09-27 status audit)

Read-only audit against `origin/developer` HEAD `ff6ee75`, cross-referenced with Issue #154's own B4/B5/B7
tracker and Issue #216. This was verification, not new implementation.

**B4 part 2 — physical removal of `BRAVO.config` from the package — is DONE.** Commit `75b3b39` (2026-09-25,
merged via PR #226/#227 line) untracked the root `BRAVO.config` from git and the staged bundle, froze its
exact byte content as `selftest/fixtures/BravoConfigLegacyFrozen.config`, extended
`-DisallowLegacyPrimaryAutoDetect` to all 14 production/operator entrypoints, and added the
`LEGACY_CONFIG_REMOVED` release-artifact gate. Full self-test PASS (2225/0) is cited in that commit.

**B5 — fleet migration — is NOT done.** No evidence of any real server migration exists anywhere in the
repository. `CHANGELOG.md` states outright ("Міграція парку (B5) свідомо НЕ реалізована в цій задачі").
`deploy/Update-BRAVOServer.ps1` still deliberately excludes `BRAVO.config`/`BRAVO.local.config` from what it
touches on a target server (line ~472) and contains no migration/parity-verification gate before deploying.

**B7 — v2-path regression matrix + parity as a mandatory gate — is NOT done** as a distinct deliverable. The
one `B7` string found in the repo is an unrelated, coincidentally-reused label on a self-test case name
(`BRAVO_SELF_TEST.Configuration.ps1:2681`), not the actual matrix. Issue #216 Phase 11 ("Permanent governance
tests") is the closest current restatement of the same requirement and its checklist is entirely unchecked.

**Operational risk flagged, not yet mitigated.** Issue #154's own "Problem" section explicitly warned that
removing `BRAVO.config` from the package does **not** remove it from already-deployed fleet servers, and its
"Remaining work" checklist explicitly required pilot migration + full B5 to happen *before* B4 part 2
("Пункт 3 не можна робити раніше за 1-2"). That ordering was overridden by the later Issue #216 owner mandate
(2026-09-24/26: "у версії 5.3 взагалі не повинно бути BRAVO.config"), which landed B4 part 2 first. The
practical consequence: deploying the current `developer` build via `deploy/Update-BRAVOServer.ps1` to a real
5.2-era fleet server that has **not** been through the pilot migration would silently drop that server's
legacy `BRAVO.config` site overrides (e.g. a non-default `BackupRoot`) on the next Archive/Maintenance run,
because the newly-unconditional `-DisallowLegacyPrimaryAutoDetect` guard makes production runtime ignore the
physically-present legacy file. This was a deliberate, owner-confirmed re-sequencing decision (Issue #216 is
later and owner-confirmed), not a defect introduced by this audit — but it means Issue #154/#216 must not be
declared complete, and this `developer` build must not be pushed to real fleet servers, until B5 has actual
evidence.

Do not treat Config V2 (Issue #154 / Issue #216) as closed while B5 and B7-equivalent evidence are missing,
regardless of what the "Config v2 — ціль змінено Issue #216" note in `ROADMAP.md` might otherwise suggest.

### AI-attribution footer prohibition (2026-09-27, owner decision)

Owner instruction: AI-authorship footers must not exist in this repository. Codified as
`.claude/CLAUDE.md` section «Заборона підписів про AI-авторство» — PR #233, commit `287ca27`, merged as
`64a8b11`. Scope of the rule: commit messages, PR bodies/comments, issue bodies/comments, and the content
of any repository file. The rule states explicitly that it overrides any tool default.

Verified state at `64a8b11` (all figures measured, not estimated):

```text
tracked repository files with an AI-attribution footer : 0   (git grep, whole tree)
PR/issue bodies scanned                                : 233
  bodies that carried a model-written footer            : 177  -> all stripped, re-verified 0 remaining
  bodies left carrying ONLY the server-injected footer  : 186
issue comments scanned / with footer / removable        : 144 / 44 / 0
review comments scanned / with footer / removable       : 668 / 21 / 0
commit messages on developer (904 commits total):
  with `Co-Authored-By: Claude`                         : 559
  with `Claude-Session:`                                : 474
  union of the two (actual affected commit set)         : 566   (7 carry only `Claude-Session:`)
```

Two residual gaps, both recorded deliberately rather than silently:

1. **Server-injected footer is not removable from an automated session.** A single line
   `_Generated by [Claude Code](https://claude.ai/code)_` is appended by the Claude Code ↔ GitHub
   integration layer on *every* write to an issue/PR body, through `mcp__github__*` and through direct
   `curl` with the session token alike. Proven twice: a PATCH that removes it is followed by a fresh GET
   showing it back; a PATCH echoing an identical body that already contains it leaves exactly one (the
   injector normalizes, it does not stack). Consequence: 186 bodies still show that one line, and no
   action available to an automated session can clear it — only a human edit in the GitHub UI, or a change
   to the integration. `.claude/CLAUDE.md` does not yet record this carve-out.
2. **The historical-debt paragraph in `.claude/CLAUDE.md` is imprecise.** It cites 558 commit messages,
   which was the exact `Co-Authored-By: Claude` count at the then-baseline `ff6ee75`. The affected set is
   larger: the union with `Claude-Session:` is 566 at `64a8b11` (565 at `ff6ee75`), because 7 commits carry
   only the session trailer. The paragraph also exempts commit messages only, while the rule's scope covers
   PR/issue bodies too — the 177-body remediation above is what actually satisfies that scope, and it is
   not recorded in the rule text.

Commit-message history is **not** being rewritten: `rebase`/`filter-repo` + force-push would invalidate
every existing clone, every PR/issue cross-reference, and the `VERSION.json.sourceCommit` provenance chain.
The rule therefore binds new commits only. Do not re-litigate this without new evidence.

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

**CORRECTION (2026-09-27):** this section described PR #224 as the active unit of work with an OPEN state
verified 2026-09-23. That is stale. PR #224 **merged** into `developer` as merge commit `2c5e82b` (part of
the commit range already folded into the current State baseline SHA above). The detailed record below is
kept as an accurate historical account of that PR's F1 remediation (including the reusable pilot-artifact
validation technique), not as a description of current active work.

Issue #216 has progressed well past Wave 0 (see git/GitHub history for the
actual wave sequence — this file was not kept current through that
progression, and per the 2026-09-27 audit above, still is not fully current:
B5/B7 remain open — see "Issue #216 Wave B — B4 part 2 (2026-09-27 status
audit)"). There is no single active PR right now; the open work is B5 (fleet
migration — requires real servers, not available to an automated session)
and B7 (v2-path regression matrix + parity required-check promotion).

Two documentation-only PRs merged on 2026-09-27 after that audit: PR #232 (`7734a55`) synchronised this file
with the audited B4/B5/B7 state and corrected its false "Config parity is now a required check" claim, and
PR #233 (`64a8b11`) codified the AI-attribution prohibition. Both were docs-only; neither changed runtime
behaviour, so the stable/RC behavioural baseline is untouched.

### PR #224 — F1 lazy dependency regression remediation (MERGED, historical record)

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

**Updated 2026-09-27 after PR #232 and PR #233 merged. Replaces the previous entry (whose items 1-3 remain
valid and are carried forward below) rather than patching it, per this file's maintenance rule #7.**

No PR is currently active and no uncommitted work is pending. The one action that is fully executable by an
automated session — no fleet, no owner UI, no elevated scope required — is item 0:

```text
0. Open a docs-only PR into `developer` from a branch off the current State baseline SHA, correcting the
   two recorded imprecisions in the `.claude/CLAUDE.md` section «Заборона підписів про AI-авторство»
   (see "AI-attribution footer prohibition" above for the measured evidence):
     a. replace the "558 commit messages" figure with the actual affected set - 566 commits at `64a8b11`
        (559 `Co-Authored-By: Claude`, 474 `Claude-Session:`, 7 carrying only the session trailer);
        state which trailer each number counts, so the figure is reproducible;
     b. record that PR/issue bodies were remediated (177 bodies stripped, 0 model-written footers left),
        so the rule's stated scope has a recorded remediation and not only a commit-message exemption;
     c. record the server-injected `_Generated by [Claude Code](https://claude.ai/code)_` line as a known
        residue outside an automated session's control, with the two-test proof, so a future session does
        not read the 186 remaining bodies as an unremediated violation and start re-editing them.
   Docs-only, no runtime surface. Validation: no BOM on the `.md`, CRLF preserved, balanced fences, and the
   edit must not itself contain a literal forbidden footer string (a future mechanical scanner would flag
   the rule file). Commit with no AI-attribution trailers - the rule now binds.
```

Then the three pre-existing items, none of which an automated session can close alone:

```text
1. B5 (fleet migration) has zero evidence of execution anywhere in the repository and requires real
   production servers. Confirm with the owner whether/when a pilot migration + fleet rollout will happen,
   using the existing tooling (deploy/Start-BRAVOConfigV2Pilot.ps1,
   deploy/Get-BRAVOConfigSiteDelta.ps1, deploy/Compare-BRAVOConfigEffectiveSnapshot.ps1) and the runbook
   docs/BRAVO_CONFIG_V2_PILOT_MIGRATION_RUNBOOK_20260916.md. Until this happens, do NOT deploy current
   `developer` to any real fleet server — see the operational-risk note under "Issue #216 Wave B — B4 part 2"
   above (silent loss of legacy `BRAVO.config` site overrides).
2. B7 (v2-path regression matrix + Config parity promoted to a required status check) has no distinct
   artifact yet. Issue #216 Phase 11's checklist is the closest current restatement — decide with the owner
   whether to treat that as the canonical B7 definition going forward, or to write a dedicated matrix.
3. `developer` branch protection currently does not exist at all (see the corrected "Config parity required
   promotion" section above) - creating it needs either the repository owner acting directly in the GitHub
   UI, or a PAT with `Administration` scope, since the installed GitHub App cannot obtain that scope. A
   candidate required-checks list and settings are recorded in that section.
```

Note for any session that reaches a merge step: merging a PR from an automated session is refused by the
harness permission classifier with reason `[Merge Without Review]` while the PR carries no approving review.
That is not a repository policy and not a defect to work around — prepare the PR to a green, mergeable state
and hand the merge to the owner, or ask for an approving review first.

Before acting on any of the above, re-verify current state
(`git fetch origin --prune`, `git rev-parse origin/developer`, GitHub issue #154 and #216) —
do not trust this file if the remote has moved past the State baseline SHA recorded above.

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
