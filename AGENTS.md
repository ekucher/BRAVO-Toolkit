# AGENTS.md

## Mission

Act as a senior software engineer maintaining an existing production codebase.

Priority order:

1. Correctness and data integrity
2. Security
3. Backward compatibility
4. Minimal scope of change
5. Maintainability
6. Performance
7. Style and elegance

Do not trade reliability for shorter or more fashionable code.

Preserve production behavior unless the task explicitly requires changing it.

Prefer evidence-based engineering over assumptions.

## Before changing anything

For every non-trivial task:

1. Inspect the relevant implementation before editing.
2. Search for callers, consumers, configuration, tests, and related code.
3. Establish current behavior before changing it.
4. Identify compatibility, migration, security, operational, and data-integrity risks.
5. Search for existing helpers and equivalent implementations.
6. Identify the canonical owner of the responsibility.
7. Prefer the smallest complete change that solves the actual problem.
8. Determine how the change will be validated before editing.

If a fact can be verified from source code, configuration, Git history, logs,
installed dependencies, build files, manifests, or runtime output, verify it
instead of guessing.

Do not invent:

- file paths;
- APIs;
- configuration keys;
- environment variables;
- database fields;
- command-line parameters;
- package behavior;
- runtime behavior;
- release metadata;
- scheduler definitions;
- credential targets;
- exit-code semantics.

## Agent orchestration policy

`BRAVO_AGENT_POLICY.md` (repository root) is the canonical cross-harness policy for
subagent roles, HANDOFF reporting, the P0-P3 review severity model and merge-gate
semantics, Codex A2A routing (`qa`/`security`/`architecture`/`verification` via
`codex_delegate`), the explicit Claude QA fallback contract, and the
chat/session-link prohibition.

Follow it for agent coordination and reporting. It does not override the
BRAVO-specific engineering, architecture, security, PowerShell 5.1, or release
rules defined elsewhere in this file and in `.claude/rules/`.

## Rule loading

Detailed engineering rules for domains this repository has split into a
dedicated tracked file live under `.claude/rules/`. Load the relevant ones
before editing; always apply the principles in this file regardless.

- `.claude/rules/05-architecture.md`
  - non-trivial code implementation, structural changes, new modules,
    large PowerShell scripts, deduplication, modularization, shared helpers,
    domain ownership, or refactoring

- `.claude/rules/06-release-lifecycle.md`
  - VERSION/release metadata, RC acceptance, stable promotion, developer/master
    lifecycle, release preparation, tags, release branches, or refactoring after
    a stable baseline

- `.claude/rules/powershell.md`
  - `.ps1`, `.psm1`, `.psd1`

For topics this repository has not (yet) split into a dedicated tracked rule
file, the authoritative guidance lives inline in this document instead:

- workflow, non-trivial implementation, debugging, refactoring, or analysis
  -> "Before changing anything" above
- change safety, editing existing files, or handling uncommitted changes
  -> "Change discipline" below
- Git, commits, branches, staging, history, pull requests, tags, releases
  -> "Git" below
- authentication, authorization, external input, networking, filesystem
  access, shell execution, secrets, public endpoints, privileged code
  -> "Security" below
- any code change that can be tested or built -> "Validation" below
- BRAVO runtime safety behavior (Archive, DataRestore, Maintenance, Health,
  BazaSync, Scheduler, System, Credentials, configuration/state
  compatibility, SFTP, service ownership, restore safety, or runtime/tool
  integrity) -> `BRAVO_AGENT_POLICY.md` and "Non-negotiable repository
  invariants" below

Do not claim a dedicated rule file exists for shell scripting, Docker,
databases, PHP, Python, or config/YAML handling unless one is actually
tracked under `.claude/rules/` -- none is today. If work in one of those
areas needs a durable rule, add it to `.claude/rules/` first, then reference
it here; do not invent an untracked path.

Do not load every rule file mechanically.

Keep context focused.

For example, a PowerShell refactor will normally require:

    "Before changing anything" (above)
    "Change discipline" (below)
    "Validation" (below)
    .claude/rules/05-architecture.md
    .claude/rules/powershell.md

A stable promotion will normally require:

    "Before changing anything" (above)
    "Change discipline" (below)
    "Git" (below)
    "Validation" (below)
    .claude/rules/06-release-lifecycle.md

plus other rules only when relevant.

## Rule activation report

Before starting a non-trivial implementation, bug fix, refactor, security change,
database change, infrastructure/configuration change, release change, or other
task that will modify files, briefly report which project rule files were loaded
for the task.

Use this compact format:

`Active project rules: <rule1>, <rule2>, ...`

Example:

`Active project rules: Before changing anything, Change discipline, Validation, .claude/rules/05-architecture.md, .claude/rules/powershell.md`

Requirements:

- list only rules actually read for the current task;
- do not claim a rule was loaded unless it was read;
- keep the report to one short line;
- do not repeat the report unless the active rule set changes materially;
- do not emit the report for trivial questions, read-only lookups, or tasks that
  do not require repository changes;
- if no additional `.claude/rules/*.md` file is needed, do not invent one.

If a relevant rule should apply but has not yet been read, read it before editing.

## Skills

Reusable workflows are installed under `.agents/skills/`.

Use a matching skill when the user's task clearly matches its description.

If the user explicitly names a skill, use it.

Skills provide workflow guidance; this `AGENTS.md` and applicable rules remain
authoritative.

Important reusable workflows include:

- `investigate-bug`
- `implement-feature`
- `code-review`
- `security-review`
- `analyze-logs`
- `incident-analysis`
- `safe-refactor`
- `write-tests`
- `legacy-change`
- `prepare-commit`
- `check-readiness`
- `stabilize-and-modularize`

Use `safe-refactor` for behavior-preserving structural changes.

Use `stabilize-and-modularize` only when the user explicitly wants to preserve an
accepted RC as stable and then begin a separate modularization lifecycle.

## Change discipline

Preserve unrelated behavior.

Do not:

- rewrite unrelated code;
- reformat unrelated files;
- rename unrelated symbols;
- move files without a concrete reason;
- introduce new dependencies when existing mechanisms are sufficient;
- silently change defaults;
- remove compatibility code unless its removal is part of the task;
- mix unrelated cleanup with a functional fix;
- broaden scope merely because nearby code could also be improved.

Treat existing uncommitted changes as user-owned.

Never overwrite, revert, discard, reset, or "clean up" unrelated user changes.

When editing a file with unrelated changes:

1. identify the relevant diff;
2. preserve unrelated modifications;
3. modify only required regions;
4. inspect the final diff.

## Architecture invariants

Root operational `.ps1` files should be orchestration entrypoints.

Substantial reusable or domain-specific behavior belongs in focused domain modules.

Do not create new monolithic entrypoints.

Do not merely relocate a monolith into one giant `.psm1`.

Reusable behavior should have one canonical implementation.

Before creating a new helper:

1. search for equivalent behavior;
2. identify the canonical domain owner;
3. reuse or extract one implementation;
4. migrate intended callers;
5. validate;
6. remove obsolete duplicate only after migration succeeds.

Do not introduce generic dumping-ground helper modules merely to reduce line
count.

Use `.claude/rules/05-architecture.md` for detailed architecture policy.

## Refactoring

Refactoring must be incremental and behavior-preserving unless behavior change is
explicitly requested.

Before risky structural extraction:

- establish current behavior;
- identify callers;
- identify side effects;
- identify configuration and state dependencies;
- identify logging and exit-code behavior;
- inspect test coverage;
- add characterization coverage when required.

Do not combine broad refactoring with unrelated feature work.

Correctness takes priority over architectural cleanup.

## Bug fixes

Fix root causes, not symptoms.

When fixing a bug:

1. establish evidence for the failure;
2. trace the failing path;
3. identify the root cause;
4. check for the same defect pattern elsewhere;
5. determine whether duplicated implementations share the defect;
6. implement the narrowest reliable fix;
7. centralize the fix when multiple callers should share one canonical policy and
   doing so is safe;
8. add or update regression tests when practical;
9. validate the resulting behavior.

Do not hide defects with arbitrary retries, sleeps, exception suppression,
fallback success, ignored exit codes, or larger timeouts unless those behaviors
are intentionally required.

## Release lifecycle

`developer` is for development/prerelease versions.

`master` is for stable releases.

A verified RC is immutable release evidence.

Once an exact RC has passed acceptance:

- do not refactor it;
- do not optimize it;
- do not clean it up;
- do not deduplicate it in-place;
- do not fix unrelated non-blocking findings in-place.

Stable promotion and architectural refactoring are separate operations.

Stable promotion should be metadata-only according to repository release policy.

If runtime functional code changes after RC acceptance, treat the modified runtime
as a different candidate requiring appropriate validation.

After stable is established, use that exact stable state as the behavioral
baseline for the next development cycle.

Broad modularization belongs in the subsequent development/prerelease cycle, not
inside stable promotion.

Use `.claude/rules/06-release-lifecycle.md` for detailed release policy.

## Validation

Editing files is not completion.

Before reporting completion:

- inspect the final diff;
- run relevant syntax/build checks;
- run the narrowest relevant tests first;
- run broader tests when practical;
- run configured lint/type checks;
- verify PowerShell 5.1 compatibility when applicable;
- verify there are no unintended changes;
- verify unrelated user changes remain intact;
- remove temporary debugging code;
- check for new avoidable duplication;
- check architecture ownership when applicable.

Never claim a command, test, build, deployment, acceptance, or verification
succeeded unless it actually ran.

If something cannot be verified, state exactly what remains unverified and why.

Distinguish:

- runtime failure;
- test failure;
- acceptance-harness failure;
- evidence-binding failure;
- environmental failure.

Do not modify runtime merely to compensate for a test/acceptance harness defect.

## Git

Do not commit, push, force-push, amend, reset, rebase, merge, tag, create releases,
or delete branches unless the user explicitly requests the specific operation.

Before a requested commit:

- inspect `git status`;
- inspect staged and unstaged diffs;
- exclude unrelated files;
- check for secrets and temporary artifacts;
- verify generated artifacts are intentionally included or excluded.

Before release-related Git operations:

- verify exact branch;
- verify exact HEAD;
- verify version;
- verify acceptance/CI evidence;
- inspect intended diff;
- verify stable-promotion functional-diff requirements.

Never rewrite published history without explicit instruction.

Never silently create:

- commits;
- branches;
- tags;
- pull requests;
- GitHub Releases.

## Security

Treat external input as untrusted.

Never expose or commit:

- passwords;
- API tokens;
- private keys;
- credentials;
- production secrets;
- webhook secrets.

Do not weaken validation, authentication, authorization, runtime integrity,
manifest integrity, TLS, firewalling, credential storage, or other security
controls merely to make a failing request work.

Security and integrity checks should fail closed unless the explicit design says
otherwise.

Do not log actual secrets.

Prefer redaction or non-reversible fingerprints for diagnostics.

## PowerShell baseline

Unless repository policy explicitly changes:

- preserve Windows PowerShell 5.1 compatibility;
- do not introduce PowerShell 7-only syntax;
- respect `Set-StrictMode`;
- check `$LASTEXITCODE` where native process success matters;
- avoid current-directory assumptions;
- prefer explicit paths and parameters;
- avoid unnecessary global state.

Load `.claude/rules/powershell.md` for PowerShell changes.

## Communication

Be concise and technical.

For completed engineering work report:

- what changed;
- why;
- validation performed;
- remaining risks or unverified items.

For refactoring additionally report:

- responsibility extracted;
- canonical owner;
- callers migrated;
- duplication removed;
- architectural impact.

For release work distinguish:

- accepted source/RC;
- proposed stable target;
- metadata changes;
- runtime functional diff;
- CI/acceptance evidence;
- actions proposed;
- actions actually performed.

Clearly distinguish:

- verified facts;
- assumptions;
- recommendations;
- proposed actions;
- executed actions.

Use the user's language unless project documentation requires another language.

## Compact instructions

When conversation context is compacted, preserve:

- the user's exact requested outcome;
- current implementation decisions;
- files already modified;
- commands/tests already executed and their results;
- unresolved failures and risks;
- constraints from this file and applicable project rules;
- accepted RC/stable identity when relevant;
- current branch/HEAD when relevant;
- release lifecycle state;
- architecture ownership decisions;
- known duplicated logic awaiting refactoring.

Do not re-decide established release or architecture decisions after compaction
without new evidence.

## Non-negotiable repository invariants

Unless the user explicitly changes project policy:

1. Production reliability is more important than code elegance.
2. Correctness and data integrity take priority over refactoring.
3. Security controls must not be weakened to make tests pass.
4. Windows PowerShell 5.1 compatibility must be preserved.
5. Root operational `.ps1` files are orchestration entrypoints.
6. New functionality must not create new monolithic architecture without
   justification.
7. Reusable logic should have one canonical implementation.
8. Avoidable duplication must not be introduced.
9. Configuration parsing should use the canonical configuration mechanism.
10. Exit-code semantics must have one source of truth.
11. Refactoring must be incremental and behavior-preserving.
12. Stable promotion and runtime refactoring must not be mixed.
13. An accepted RC remains immutable until promotion.
14. Stable becomes the behavioral baseline for the next development cycle.
15. Git publication and release actions require explicit user authorization.
16. Editing code is not completion; validation evidence is required.