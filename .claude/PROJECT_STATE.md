# BRAVO-Toolkit — Current Project State

Last verified: 2026-09-27

## Canonical branch

`developer`

## State baseline SHA

`0a237ea518798bc60fff0f44b2152f5911abbb03`

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
`64a8b11`; the rule text was then corrected by PR #235, merged as `f76ff42` (measurement predicates,
recorded body remediation, injected-footer carve-out, and the ban on quoting the signature verbatim).
Treat the merged rule text as canonical over any summary in this file. Scope of the rule: commit messages, PR bodies/comments, issue bodies/comments, and the content
of any repository file. The rule states explicitly that it overrides any tool default.

Verified state at `64a8b11` (all figures measured, not estimated):

```text
tracked files with an author-written AI footer  : 0     (git grep, whole tree)
PR/issue bodies scanned                         : 233
  carried an author-written footer -> stripped   : 177   (re-verified: 0 author-written left)
  left carrying ONLY the injected footer         : 186
issue comments scanned / injected / author-written  : 144 / 44 / 0
review comments scanned / injected / author-written : 668 / 21 / 0
commit messages, FULL history at 64a8b11, case-insensitive match (1073 commits):
  with the AI co-author trailer                  : 690
  with the session-link trailer                  : 511
  union of the two (actual affected set)          : 690   (0 carry only the session trailer;
                                                           179 carry only the co-author trailer)
  with a "Generated with/by ..." footer           : 0
```

The union equals the co-author count because every commit carrying the session trailer also carries the
co-author trailer. The affected set is **690 of 1073**.

**Two measurement traps, both hit on the first pass; both are why the figures above changed twice.**

1. *Shallow clone.* The first pass ran in a shallow clone
   (`git rev-parse --is-shallow-repository` -> `true`, `.git/shallow` present, 10+ synthetic roots), where
   `git rev-list` silently counts only the reachable slice: it reported 904 commits and 559/474/566 instead
   of 1073 and 690/511/690. Check `--is-shallow-repository` and run `git fetch --unshallow origin` first.
2. *Case-sensitive trailer match.* The second pass, already on full history, matched the co-author trailer
   case-sensitively and so reported 683 with "7 commits carrying only the session trailer". Those 7 are not
   session-only at all: they spell the trailer `Co-authored-by:` (git's own canonical casing) rather than
   `Co-Authored-By:`. Both spellings occur in this history (694 vs 16 trailer lines), so **match
   case-insensitively** (`git rev-list -i --grep=`) or the breakdown is wrong.

Codex caught both, on PR #235 and PR #234; the corrections landed in both.

The 44 + 21 = 65 comments carrying a footer are **all** the injected form — not one was author-written, so
there is nothing to remediate there, and they are not unexplained violations. Same for the 186 bodies. Do
not start a remediation pass over comments or bodies on the strength of seeing that line.

Two residual gaps, both recorded deliberately rather than silently:

1. **The injected footer is not removable from an automated session.** A single italicised line — the words
   "Generated by" followed by a link to the assistant tool, written as one markdown line with a horizontal
   rule above it; deliberately not reproduced verbatim here, so a whole-tree scanner does not flag this
   file — is appended by the Claude Code ↔ GitHub
   integration layer on *every* write to an issue/PR body, through `mcp__github__*` and through direct
   `curl` with the session token alike. Proven twice: a PATCH that removes it is followed by a fresh GET
   showing it back; a PATCH echoing an identical body that already contains it leaves exactly one (the
   injector normalizes, it does not stack). Consequence: 186 bodies still show that one line, and no
   action available to an automated session can clear it — only a human edit in the GitHub UI, or a change
   to the integration. The same holds for the 65 footer-carrying comments: all injected, none author-written.
2. **The historical-debt paragraph in `.claude/CLAUDE.md` was imprecise.** It cited 558 commit messages —
   the co-author-trailer count at the then-baseline `ff6ee75`, and measured in a shallow clone, so wrong on
   both axes. The affected set is the union of the two trailers: 690 commits of 1073 at `64a8b11`. The
   paragraph also exempted commit messages only, while the rule's scope covers PR/issue bodies and comments
   too — the 177-body remediation above is what actually satisfies that scope.

Both gaps are closed. PR #235 (`.claude/CLAUDE.md`) merged as `f76ff42`: the rule text now carries the
corrected full-history figures, the shallow-clone and trailer-casing warnings, reproduction commands pinned
to the immutable `64a8b11`, the aggregate-prefix definition of the grep placeholders, the recorded
remediation of PR/issue bodies, and the carve-out for the injected footer (186 bodies + 65 comments) with a
standing instruction not to re-edit them. PR #234 merged as `0a237ea`, bringing this file's audited figures.
No author-written AI footer remains anywhere in the repository: `git grep` of the forbidden literals over
the whole tree returns 0 files, and both files describe the signature instead of quoting it.

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
audit)"). The open Config V2 work is B5 (fleet migration — requires real
servers, not available to an automated session) and B7 (v2-path regression
matrix + parity required-check promotion).

**No documentation PR is open as of 2026-09-27 18:00 UTC.** The AI-attribution
work is finished and merged: PR #235 (`f76ff42`, the rule text in
`.claude/CLAUDE.md`) and PR #234 (`0a237ea`, this file's audited figures). Both
went through three Codex review rounds; every content finding was verified and
fixed, and five commit-anchored "remove the footer from commit <sha>" findings
were rejected because each cited a SHA absent from both the local clone and the
GitHub API. Do not reopen that work.

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

**Updated 2026-09-27 after PR #234 and PR #235 merged. Item 0 ("drive those two PRs to done") is delivered
and has been removed, per the owner's instruction; items 1-3 are carried forward unchanged.**

No uncommitted work is pending and no PR is open. **None of the three remaining items can be closed by an
automated session** — each needs the owner, real fleet servers, or an elevated GitHub scope. Do not
manufacture a substitute task: establish the state, then report which of the three the owner wants to move
and what it needs from them.

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
