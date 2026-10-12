---
name: stabilize-and-modularize
description: Freeze an accepted release candidate as a stable behavioral baseline, then start a separate incremental modularization and deduplication development cycle. Use when the user wants to stabilize a verified RC and subsequently transition the repository from monolithic scripts to modular architecture.
disable-model-invocation: true
---

# Stabilize and Modularize

This is a controlled release-and-refactoring workflow.

It consists of strictly separated phases:

    accepted RC
        ->
    stable release
        ->
    immutable behavioral baseline
        ->
    next development line
        ->
    architecture inventory
        ->
    characterization
        ->
    incremental modularization

Never mix stable promotion and refactoring in the same logical change.

This skill must not itself imply authorization to commit, push, merge, tag, or
create a release.

---

# Phase A — Verify accepted RC

Do not edit runtime code.

Establish exact release identity.

Verify:

1. current branch;
2. exact HEAD;
3. working-tree status;
4. VERSION/package version;
5. release channel;
6. provenance/source commit;
7. build ID where applicable;
8. runtime/release manifests;
9. acceptance evidence;
10. CI evidence when available;
11. repository release policy.

Report the exact accepted baseline.

Stop on identity mismatch.

Do not guess missing release identity.

---

# Phase B — Review acceptance findings

Classify known acceptance findings.

Separate:

- blocking P0/P1;
- non-blocking P2;
- environment-only failures already remediated;
- acceptance-harness defects;
- operator-facing issues;
- future architectural improvements.

Blocking correctness, integrity, or security findings prevent stable promotion.

Do not modify the accepted RC merely to fix a non-blocking architectural or
operator-facing issue if that would invalidate exact acceptance identity.

Record appropriate follow-up work for the next development cycle.

---

# Phase C — Prepare stable promotion

Stable promotion must be a minimal independently reviewable operation.

Do not refactor.

Do not optimize.

Do not deduplicate.

Do not perform unrelated cleanup.

Determine exactly which metadata files repository policy requires changing.

Before editing:

1. establish accepted RC identity;
2. determine proposed stable version;
3. identify required metadata changes;
4. identify expected manifest/stamp updates;
5. establish how runtime functional diff will be checked.

After preparing changes, show:

- accepted RC version;
- accepted RC HEAD;
- proposed stable version;
- changed files;
- complete relevant diff;
- runtime functional diff classification;
- validation performed.

Runtime functional diff must be empty.

If runtime behavior changed:

    STOP

The modified runtime requires a new RC/acceptance cycle.

---

# Phase D — Stable Git actions

Do not automatically perform:

- commit;
- push;
- merge;
- pull request creation;
- tag;
- GitHub Release;
- deployment.

Only perform a specific Git/release action after explicit user authorization.

Before any requested release Git write:

1. inspect `git status`;
2. inspect staged/unstaged diff;
3. verify exact branch;
4. verify exact HEAD;
5. verify intended version;
6. verify acceptance/CI evidence;
7. verify no unrelated changes;
8. verify no secrets;
9. verify runtime functional diff constraints.

---

# Phase E — Establish stable baseline

After stable promotion is actually completed and verified, record the stable
behavioral baseline.

Where applicable capture:

- stable version;
- stable commit;
- stable tag;
- accepted RC version;
- accepted RC commit;
- provenance/source commit;
- CI run;
- acceptance evidence;
- release date.

This exact stable state becomes the behavioral reference for subsequent structural
refactoring.

Do not start broad modularization until the baseline is established.

---

# Phase F — Start next development line

Do not refactor stable.

Move development to the appropriate development/prerelease line only after stable
is established.

Determine version according to repository policy and user intent.

For broad architecture modernization, a new minor development line is generally
preferred when policy allows.

Example only:

    5.1.0 stable
        ->
    5.2.0-dev.1

Do not automatically choose this version without verifying release policy.

Version initialization and architecture refactoring should remain separately
reviewable when practical.

---

# Phase G — Read-only architecture inventory

Before changing architecture, perform a repository-wide read-only inventory.

Do not refactor yet.

Collect:

## Entrypoints

For root `.ps1` files:

- path;
- line count;
- parameters;
- responsibilities;
- imported modules;
- major functions/inline logic;
- callers if applicable.

## Modules

For `.psm1`/`.psd1`:

- path;
- line count;
- exported functions;
- private functions;
- responsibilities;
- dependencies;
- consumers.

## Duplication

Search for duplicate or substantially equivalent:

- functions;
- validation logic;
- configuration parsing;
- path normalization;
- filesystem checks;
- free-space checks;
- service lifecycle logic;
- restore logic;
- SFTP/WinSCP logic;
- credentials logic;
- notifications;
- logging;
- scheduler definitions;
- scheduler validation;
- runtime integrity;
- hash validation;
- manifest validation;
- archive generation handling;
- exit-code mapping;
- error handling;
- BAZA state handling.

Do not classify similar code as duplicate solely from textual similarity.

Compare semantics.

## State

Identify:

- `$global:` state;
- `$script:` state;
- environment dependencies;
- current-directory dependencies;
- mutable module state;
- state files;
- locks.

## Tests

Map test coverage to each candidate responsibility.

---

# Phase H — Produce modularization map

For each architectural candidate report:

- current owner;
- current files;
- callers;
- duplicated locations;
- proposed canonical owner;
- proposed module;
- public contract;
- hidden dependencies;
- global state;
- test coverage;
- operational risk;
- data-integrity risk;
- expected benefit;
- required characterization tests.

Rank candidates by:

1. correctness/data-integrity risk;
2. operational risk;
3. duplication;
4. coupling;
5. test coverage;
6. clarity of responsibility;
7. expected maintainability improvement.

Do not automatically refactor the largest file first.

Prefer components with a clear ownership boundary and sufficient validation.

---

# Phase I — Characterization baseline

Before moving critical operational behavior, establish characterization evidence.

Use the stable release as the reference behavior.

Depending on the responsibility, characterize:

- parameters;
- defaults;
- exit codes;
- returned objects;
- filesystem effects;
- state-file effects;
- service state transitions;
- scheduler XML;
- archive paths;
- hashes;
- SFTP behavior;
- BAZA counters;
- logs;
- notification behavior;
- cleanup behavior.

Add tests before extraction where existing coverage is insufficient.

Do not silently codify a known defect as desirable behavior.

If characterization reveals a defect, report it separately.

---

# Phase J — Incremental modularization

Refactor one cohesive responsibility at a time.

For each extraction:

1. identify exact responsibility;
2. identify canonical owner;
3. identify all callers;
4. identify observable behavior;
5. ensure adequate characterization;
6. extract implementation;
7. preserve public contract;
8. migrate intended callers;
9. run targeted tests;
10. inspect diff;
11. remove obsolete duplicated implementation;
12. run broader validation;
13. compare against stable behavior.

Do not perform repository-wide rewrites.

Prefer small independently reviewable steps.

---

# Phase K — Entrypoint reduction

The desired direction is:

    root .ps1
        =
    parameters + bootstrap + imports + orchestration + exit

When refactoring a large entrypoint:

Do not merely split arbitrary ranges of lines.

Extract cohesive responsibilities.

Examples:

    planning
    validation
    service lifecycle
    archive operations
    restore operations
    notification construction
    evidence collection

only when these boundaries match actual repository behavior.

---

# Phase L — Deduplication

Do not perform blind textual deduplication.

For each suspected duplicate:

1. compare semantics;
2. compare callers;
3. compare error handling;
4. compare logging;
5. compare configuration;
6. compare side effects;
7. compare compatibility constraints.

Only converge implementations that should genuinely share one policy.

When convergence is valid:

1. choose canonical owner;
2. implement/reuse canonical function;
3. migrate callers;
4. validate;
5. remove obsolete copies.

---

# Phase M — Prevent new monoliths

During modernization:

- keep root entrypoints thin;
- review modules approaching 800+ lines;
- do not create new 1000+ line implementation files;
- avoid `Common`/`Utils` dumping grounds;
- do not create parallel helpers;
- keep domain ownership explicit.

Line count alone is not success.

Success requires improved responsibility boundaries and reduced duplication/coupling.

---

# Phase N — PowerShell compatibility

Preserve Windows PowerShell 5.1 compatibility throughout modernization.

Check:

- syntax;
- array semantics;
- `Set-StrictMode`;
- JSON behavior;
- native command execution;
- `$LASTEXITCODE`;
- COM/WMI/Scheduled Tasks behavior;
- encoding;
- exception semantics.

Do not validate only under PowerShell 7.

---

# Phase O — Validation for each refactor

For each modularization step:

1. syntax/static validation;
2. targeted regression tests;
3. component self-tests;
4. broader self-test when safe;
5. inspect final diff;
6. inspect architecture impact;
7. compare stable behavioral expectations.

Do not accumulate many unvalidated extractions before testing.

---

# Phase P — Architecture review

Before completing each stage, verify:

- root entrypoint line count decreased or remained appropriate;
- duplication decreased;
- canonical ownership improved;
- no new dumping-ground module appeared;
- no monolith was merely relocated;
- hidden state did not increase;
- dependency direction remains sane;
- callers migrated consistently;
- stable behavior preserved;
- PowerShell 5.1 compatibility preserved.

---

# Phase Q — Reporting

After each modularization stage report:

- responsibility changed;
- previous location;
- canonical module owner;
- files changed;
- callers migrated;
- duplication removed;
- entrypoint line count before/after when relevant;
- tests executed and results;
- behavior differences;
- remaining architectural debt;
- next recommended extraction.

Clearly distinguish verified facts from recommendations.

---

# Hard prohibitions

This workflow must never silently:

- modify an accepted RC before stable promotion;
- mix stable promotion and refactoring;
- rewrite the repository wholesale;
- create a generic helper dumping ground;
- duplicate canonical configuration parsing;
- duplicate exit-code contracts;
- introduce PowerShell 7-only behavior;
- weaken integrity/security controls;
- commit;
- push;
- merge;
- tag;
- create a GitHub Release;
- deploy;

without the appropriate explicit user request.