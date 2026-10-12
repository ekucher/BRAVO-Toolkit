---
name: safe-refactor
description: Refactor existing code while preserving observable behavior, public contracts, compatibility, operational semantics, and tests. Use when simplifying structure, extracting modules, removing duplication, reducing monolithic entrypoints, improving maintainability, or reorganizing implementation without intended behavior changes.
---

# Safe Refactor

Refactor `$ARGUMENTS`.

The purpose of this workflow is to improve structure without silently changing
observable behavior.

Correctness and operational safety take priority over architectural elegance.

---

## 1. Load applicable project policy

Before editing, read and apply the relevant project instructions and rules,
including architecture, change safety, testing, security, PowerShell, and release
rules when applicable.

Do not treat this skill as overriding repository instructions.

---

## 2. Establish scope

Define the exact responsibility being refactored.

Do not use a broad request such as "make this cleaner" as justification for an
unbounded repository rewrite.

Identify:

- target files;
- intended responsibility;
- expected callers;
- desired structural improvement;
- behavior that must remain unchanged.

---

## 3. Inspect before editing

Before changing code:

1. read the relevant implementation;
2. find all callers and consumers;
3. inspect imported and dependent modules;
4. inspect relevant configuration;
5. inspect tests;
6. inspect logging and exit-code behavior;
7. inspect global/script state;
8. search for duplicated or equivalent implementations.

Do not assume the target file is the correct architectural owner.

---

## 4. Establish observable behavior

Record the behavior that must remain equivalent.

Depending on the component, this may include:

- parameters;
- default values;
- return objects;
- exit codes;
- log messages;
- generated file names;
- directory structure;
- state-file behavior;
- archive behavior;
- hash behavior;
- service lifecycle;
- scheduler definitions;
- network/SFTP behavior;
- notifications;
- cleanup behavior.

If behavior is not sufficiently covered by existing tests, add characterization
tests where practical before moving critical logic.

---

## 5. Identify canonical ownership

Before extracting code, determine which domain owns the responsibility.

Prefer an existing focused BRAVO module.

Examples may include:

    BRAVO.Archive
    BRAVO.BazaSync
    BRAVO.Health
    BRAVO.Maintenance
    BRAVO.Notifications
    BRAVO.ExitCodes
    BRAVO.Acceptance

Use actual repository structure as authoritative.

Do not invent a new module until existing ownership has been checked.

---

## 6. Architecture requirements

During refactoring:

- prefer making root entrypoints thinner;
- keep orchestration in `.ps1` entrypoints;
- keep implementation in cohesive modules;
- do not move a monolith unchanged into one large `.psm1`;
- do not introduce generic dumping-ground modules;
- avoid hidden global state;
- preserve Windows PowerShell 5.1 compatibility;
- preserve existing configuration ownership;
- preserve canonical exit-code ownership;
- preserve operational logging evidence.

When touching a large root entrypoint, reduce or preserve its implementation
complexity rather than increasing it unnecessarily.

---

## 7. Duplication analysis

Before introducing a helper:

1. search for equivalent functions;
2. search for substantially equivalent code;
3. compare semantics;
4. determine whether the implementations can safely converge.

If equivalent logic exists in multiple places:

- identify one canonical owner;
- extract or reuse one implementation;
- migrate intended callers;
- validate behavior;
- remove old duplicate only after migration succeeds.

Do not copy/paste implementation into another file.

Do not force convergence when similar-looking code intentionally implements
different policy.

---

## 8. Change incrementally

Refactor one cohesive responsibility at a time.

Preferred sequence:

1. establish current behavior;
2. add characterization coverage if needed;
3. identify canonical owner;
4. extract implementation;
5. preserve function/entrypoint contract;
6. migrate one logical caller set;
7. run targeted validation;
8. inspect diff;
9. remove obsolete duplicate;
10. run broader validation.

Avoid large simultaneous module rewrites.

---

## 9. Preserve compatibility

Do not silently change:

- public parameters;
- parameter aliases;
- default values;
- configuration semantics;
- filesystem layout;
- state formats;
- task names;
- exit codes;
- logging contracts;
- service behavior;
- retry behavior;
- timing behavior;
- notification semantics.

If any observable behavior must change, stop treating the entire task as a pure
refactor.

Separate and report the behavior change.

---

## 10. PowerShell requirements

For PowerShell refactors:

- preserve Windows PowerShell 5.1 compatibility;
- account for `Set-StrictMode`;
- avoid PowerShell 7-only syntax;
- do not rely on caller current directory;
- preserve `$LASTEXITCODE` semantics around native programs;
- preserve exception behavior;
- preserve array/enumeration behavior;
- use explicit parameters where practical;
- avoid introducing new `$global:` or `$script:` dependencies.

---

## 11. Validate after each meaningful extraction

Run the narrowest relevant validation first.

Depending on repository capabilities:

1. syntax validation;
2. targeted self/unit tests;
3. regression tests;
4. affected component tests;
5. broader `BRAVO_SELF_TEST.ps1` when safe;
6. integration validation where appropriate.

Never claim equivalence without executing reasonable evidence-producing checks.

---

## 12. Inspect final diff

Before completion, inspect the complete diff.

Check for:

- accidental semantic changes;
- unrelated formatting;
- unrelated renaming;
- duplicate implementation left behind;
- caller migration omissions;
- PowerShell 5.1 incompatibility;
- unintended logging changes;
- unintended exit-code changes;
- increased hidden state;
- accidental generated files;
- secrets;
- temporary diagnostics.

---

## 13. Architecture completion review

Before declaring completion, answer:

- Did the entrypoint become thinner or remain appropriately thin?
- Did duplication decrease?
- Did any duplicate implementation remain unnecessarily?
- Is the code now owned by the correct domain?
- Was a generic helper dumping ground introduced?
- Was a monolith merely moved elsewhere?
- Did coupling decrease or remain controlled?
- Did testability improve or remain adequate?
- Did global state increase?
- Were all intended callers migrated?
- Was externally observable behavior preserved?

If the refactor violates repository architecture policy, correct it before
reporting completion.

---

## 14. Reporting

For completed refactoring report:

- responsibility refactored;
- old location;
- canonical new/existing owner;
- callers migrated;
- duplication removed;
- files changed;
- validation actually performed;
- behavior differences, if any;
- remaining architectural debt;
- any unverified risk.

If safe behavior preservation cannot be demonstrated, say so explicitly.

Do not describe the work as a successful pure refactor when behavior equivalence
is uncertain.