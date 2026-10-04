# BRAVO Validation Architecture

Status: proposed design and implementation plan  
Scope: repository validation, self-test execution model, installation verification, CI and acceptance boundaries  
Baseline used for this design: `developer` at `5de8173d5a75d008278be8c2693cbfb242337251`

## 1. Purpose

BRAVO-Toolkit has grown from a small script set into an operational toolkit with multiple entrypoints, configuration, integrity controls, maintenance, archive, restore, deployment and acceptance workflows.

Validation must therefore serve several different purposes without mixing their trust and safety boundaries:

1. fast feedback while developing a focused change;
2. regression validation for all mandatory repository self-tests;
3. specialized integration and acceptance testing;
4. production-safe verification after installation;
5. ongoing operational health and maintenance.

These are different validation layers. A single full self-test run is not the correct tool for every layer.

The target model is:

```text
Development feedback
    Targeted
       |
    Affected
       |
       v
Repository acceptance
    Full Self-Test
       |
       v
Specialized integration / CI
       |
       v
DEV-LIMS / release acceptance when required

Installation
       |
       v
Post-Install Verify
       |
    READY / BLOCKED
       |
       v
Normal operation
       |
       v
Health / Maintenance
```

## 2. Current verified contract

The following are existing project contracts and must not be weakened by this design.

### 2.1 Canonical Full Self-Test

The canonical full repository self-test remains:

```powershell
.\BRAVO_SELF_TEST.ps1 -NoPause
```

This command must continue to work unchanged and remain the default Full run.

A refactor must not:

- remove, skip, bypass or weaken an existing mandatory check;
- downgrade a failure to a warning merely to make validation green;
- silently exclude a suite from the Full run;
- migrate the self-test framework to Pester;
- introduce in-process runspaces, `-Parallel` or background jobs as a self-test acceleration mechanism;
- make PowerShell 7 evidence substitute for supported Windows PowerShell 5.1 validation.

### 2.2 Runtime and test isolation

BRAVO product and test validation uses Windows PowerShell 5.1.

Tests and fixtures must not read from or write to real BRAVO production state as part of test setup or mutation.

The production VersionState location:

```text
C:\ProgramData\BRAVO\State\BRAVO_VERSION_STATE.json
```

must not be used as test state. Tests use sandbox-local state.

`BRAVO_ALLOW_DOWNGRADE=1` is not an acceptable validation workaround.

### 2.3 Existing validation layers

The repository already contains:

- root `BRAVO_SELF_TEST.ps1`;
- thematic scripts under `selftest/`;
- specialized test entrypoints such as configuration and data-restore validation;
- normal GitHub Actions validation;
- a DEV-LIMS full self-test acceptance workflow.

Specialized validation is not automatically part of the Self-Test harness and must not be merged into it merely for consolidation.

## 3. Architectural decision

BRAVO adopts three repository self-test execution levels:

```text
Targeted -> Affected -> Full
```

### Targeted

Runs explicitly selected thematic suite(s) relevant to the code currently being developed.

Purpose:

- shortest developer feedback loop;
- repeated execution during implementation;
- debugging a known area.

Targeted success is not release or merge acceptance evidence.

### Affected

Runs all suites known to be affected by the changed component, including declared dependent suites.

Purpose:

- catch cross-component regressions before the expensive Full gate;
- provide deterministic validation based on an explicit dependency map;
- avoid a manually curated permanent "Fast" suite that can drift away from actual dependencies.

Affected success is not a replacement for Full acceptance.

### Full

Runs every mandatory Self-Test suite/check covered by the canonical Full contract.

Purpose:

- regression gate on a completed logical change;
- PR/release acceptance evidence where required;
- validation after changes to the Self-Test harness itself;
- validation after meaningful base/integration changes when previous evidence is stale.

Full is not required after every source edit.

## 4. When Full is required

A Full run should be treated as a control-point gate rather than the default inner development loop.

Full is required at minimum when:

- a logical implementation package is ready for acceptance;
- the Self-Test harness, suite discovery, aggregation, counters, logging or exit-code behavior changes;
- a broad/shared component changes and the dependency model cannot safely bound the affected set;
- acceptance policy for the PR/release explicitly requires Full;
- a meaningful integration/base change invalidates previous Full evidence;
- DEV-LIMS or release acceptance explicitly calls for the canonical Full command.

During normal implementation the preferred loop is:

```text
edit
  |
Targeted
  |
edit/fix
  |
Affected
  |
completed logical change
  |
Full
```

## 5. Self-Test target architecture

The desired structural boundary is:

```text
BRAVO_SELF_TEST.ps1
        |
        | canonical thin entrypoint
        v
+-----------------------------+
|       Self-Test Harness     |
| parameter handling          |
| suite selection/discovery   |
| sandbox lifecycle           |
| execution                   |
| result aggregation          |
| counters                    |
| logging                     |
| final exit code             |
+--------------+--------------+
               |
               v
       selftest/*.ps1
       thematic suites
```

The root script remains the stable operator/CI-facing entrypoint. Substantial reusable harness behavior should have one canonical owner rather than being duplicated across root and suites.

This is a target architecture, not evidence that the current root script has already reached this state.

## 6. Suite dependency model

Affected execution requires an explicit mapping from production ownership to validation ownership.

Conceptually:

```text
changed component
      |
      +--> directly owning suite
      |
      +--> dependent suites
      |
      +--> shared-contract suites
```

Example categories, subject to VAL-01 inventory confirmation:

- configuration loader changes may affect configuration, config intent and configurator validation;
- archive changes may affect archive, disk-space, backup-scope and trace/archive validation;
- maintenance changes may affect maintenance-specific suites;
- shared harness changes force Full;
- changes with unknown dependency coverage force Full.

The mapping must be repository-owned, reviewable and deterministic. It must fail toward broader validation when ownership is ambiguous.

Do not create a static "Fast" list as a substitute for dependency ownership.

## 7. Post-Install Verification

Installation verification is a separate production concern.

`BRAVO_SELF_TEST.ps1` answers:

> Is the BRAVO codebase behaving according to its repository test contract?

Post-Install Verify answers:

> Is this specific BRAVO installation complete, internally consistent and safe to enter normal operation?

Therefore a first production installation should not require the development Full Self-Test harness merely to prove that installation succeeded.

### 7.1 Target verification areas

The final check set must be confirmed against installer architecture and runtime ownership, but is expected to cover:

- installed runtime presence and expected layout;
- runtime manifest/integrity verification;
- preservation of the pre-trust runtime-guard boundary;
- configuration load and required settings;
- site/local configuration handling;
- required path availability and permissions;
- required credential presence without disclosing secret values;
- required dependencies;
- scheduled tasks selected by installation, when applicable;
- logging/state path readiness;
- production-safe entrypoint/runtime smoke checks.

### 7.2 Safety contract

Post-Install Verify must:

- be safe to run on a production host;
- avoid synthetic mutations of production data;
- avoid using production state as a test fixture;
- fail closed for integrity/security conditions where BRAVO runtime policy requires it;
- provide actionable diagnostics;
- never print secrets;
- return a meaningful process exit code;
- distinguish successful installation readiness from warnings that do not block operation.

The intended terminal state is:

```text
Installation
     |
Post-Install Verify
     |
 +---+---+
 |       |
READY  BLOCKED
```

The exact executable/script/module name is intentionally not fixed by this design document until implementation ownership is decided.

## 8. Validation boundaries

The project must preserve these conceptual boundaries:

| Layer | Question | Typical environment |
| --- | --- | --- |
| Targeted | Did the focused area still work? | development |
| Affected | Did known dependent behavior still work? | development / pre-review |
| Full Self-Test | Does the complete repository Self-Test contract pass? | development / CI / acceptance |
| Specialized tests | Does a specialized integration contract pass? | CI / acceptance |
| DEV-LIMS acceptance | Does the exact candidate pass required real-host acceptance? | controlled acceptance host |
| Post-Install Verify | Is this installation READY? | installed host |
| Health / Maintenance | Is the installed system healthy during operation? | operational host |

Passing one layer must not be reported as evidence that another layer passed unless that other layer was actually executed.

## 9. Installer dependency

The Installer should not be blocked by completion of the entire Self-Test refactor.

The dependency is:

```text
Self-Test inventory
       |
Characterization baseline
       |
Validation architecture
       |
Post-Install Verify contract
       |
       +-------------------+
       |                   |
       v                   v
Self-Test evolution    Installer MVP
       |                   |
       +---------+---------+
                 |
        Verify integration
```

Before Installer implementation relies on validation, the project needs:

1. current Self-Test inventory;
2. characterization of the canonical Full behavior;
3. accepted Validation Architecture;
4. accepted Post-Install Verify contract.

Deep Self-Test harness cleanup can continue independently after those foundations exist.

## 10. Implementation plan

### VAL-01 - Self-Test Inventory

Read-only inventory of:

- root Self-Test responsibilities;
- thematic suites;
- suite/check ownership;
- global/script state;
- fixtures;
- temp/sandbox usage;
- production-path access risks;
- duplicated harness behavior;
- ordering dependencies;
- logging, counters and exit behavior;
- CI and DEV-LIMS consumers.

Deliverable: ownership/dependency inventory.

Estimated effort: 3-5 hours.

### VAL-02 - Full Characterization Baseline

Freeze the externally observable canonical Full contract before structural refactoring.

Characterize:

- command-line behavior;
- mandatory suite/check execution;
- ordering dependencies where behaviorally relevant;
- PASS/FAIL aggregation;
- counters;
- logs;
- process exit behavior;
- relevant failure modes.

No check weakening is permitted.

Estimated effort: 4-8 hours.

### VAL-03 - Validation Architecture Specification

Review and update this document using VAL-01/VAL-02 evidence.

Resolve any assumptions in this initial design.

Estimated effort: 3-5 hours.

### VAL-04 - Targeted Suite Execution

Implement a supported way to execute selected thematic suites while preserving the existing Full default unchanged.

Requirements:

- Windows PowerShell 5.1;
- deterministic selection;
- invalid suite selection fails clearly;
- Full command unchanged;
- no silent skip behavior;
- existing logs/result semantics preserved where applicable.

Estimated effort: 4-8 hours.

### VAL-05 - Affected Suite Mapping

Introduce repository-owned dependency mapping.

Requirements:

- component-to-suite ownership;
- dependent-suite relationships;
- conservative fallback to Full for unknown/shared changes;
- characterization tests for mapping behavior;
- no manually maintained generic Fast bucket.

Estimated effort: 6-10 hours.

### VAL-06 - Post-Install Verification Contract

Convert section 7 into an implementation-ready contract based on the Installer architecture and actual runtime ownership.

Define:

- mandatory checks;
- READY/BLOCKED semantics;
- warning semantics;
- exit codes;
- diagnostics;
- integrity/trust ordering;
- safe operations;
- forbidden production mutations.

Estimated effort: 4-6 hours.

### INS-01 - Installer Technical Architecture

Define Installer phases and integration points for Post-Install Verify.

This task belongs to the Installer track but depends on VAL-06.

Estimated effort: 4-8 hours.

### INS-02 - Installer MVP

Implement the separately approved Installer MVP according to its design.

Estimated effort: 1-2 days.

### VAL-07 - Post-Install Verifier

Implement the production-safe verifier defined by VAL-06.

Estimated effort: 1-2 days.

### INS-03 - Installer Verification Integration

Connect Installer completion to Post-Install Verify and present actionable READY/BLOCKED diagnostics.

Estimated effort: 4-8 hours.

### VAL-08 - Self-Test Harness Boundary

Reduce root Self-Test responsibilities toward orchestration and establish canonical ownership of reusable harness behavior.

This is structural work and requires characterization-first validation.

Estimated effort: 1-2 days.

### VAL-09 - Suite Normalization and Isolation

Normalize suite lifecycle and remove unsafe/duplicated fixture/sandbox patterns without changing test intent.

Explicitly verify absence of production-state fixture contamination.

Estimated effort: 1-2 days.

### VAL-10 - CI Validation Model

Use Targeted/Affected execution for faster feedback where it provides value while retaining mandatory Full coverage at acceptance gates.

Any CI parallelism must use separate supported processes/jobs. Do not introduce prohibited in-process Self-Test parallelism.

Estimated effort: 4-8 hours.

### ACC-01 - Full Regression

Execute the required Windows PowerShell 5.1 Full and specialized validation on the exact candidate.

Evidence must include actual command, exit code and key result.

Estimated effort: approximately 0.5 day.

### ACC-02 - Independent Review

Fresh reviewer assesses the behavioral/architectural change using P0-P3 findings and normal merge-gate policy.

Estimated effort: 2-4 hours.

### ACC-03 - DEV-LIMS Acceptance

When required and operational gates permit it, run exact-SHA canonical Full acceptance on the controlled DEV-LIMS environment.

This is not automatically authorized by completion of earlier tasks.

Estimated effort: 2-4 hours excluding environment blockers.

## 11. Suggested delivery waves

### Wave 1 - Foundation

```text
VAL-01 -> VAL-02 -> VAL-03
```

No broad implementation refactor should precede this baseline.

Expected duration: about 1-2 working days.

### Wave 2 - Fast feedback and installation contract

```text
VAL-04 -> VAL-05

VAL-06 -> INS-01
```

These tracks can proceed independently after their dependencies are satisfied, subject to the project's one-mutation-lane rules for overlapping files/artifacts.

### Wave 3 - Installer MVP and verifier

```text
VAL-07 ----+
           +--> INS-03
INS-02 ----+
```

Expected duration: about 2-4 working days depending on Installer scope.

### Wave 4 - Harness completion

```text
VAL-08 -> VAL-09 -> VAL-10
                    |
                    v
                  ACC-01
                    |
                  ACC-02
                    |
                  ACC-03 when required
```

## 12. Overall estimate

Initial planning estimate:

- foundation before serious Installer implementation: 1-2 working days;
- Installer MVP plus Post-Install Verify: approximately 2-4 additional working days;
- complete Validation Architecture cleanup, CI integration and review: approximately 6-10 working days total.

These are planning estimates, not commitments. VAL-01/VAL-02 should replace them with evidence-based estimates after hidden coupling and current harness ownership are known.

## 13. Non-goals

This architecture does not authorize or require:

- reducing Full Self-Test coverage;
- replacing Windows PowerShell 5.1 with PowerShell 7;
- migrating to Pester;
- weakening integrity/security gates;
- executing Full Self-Test on every production installation;
- treating Post-Install Verify as release acceptance;
- treating Health/Maintenance as repository testing;
- merging all specialized tests into one script;
- parallel writers changing the same test/harness artifacts;
- deployment, release, merge or production-host changes.

## 14. Acceptance invariants

Implementation is acceptable only if all applicable invariants remain true:

1. `.\BRAVO_SELF_TEST.ps1 -NoPause` remains the canonical unchanged Full entrypoint.
2. Full still covers every mandatory check that it covered before the change.
3. Targeted/Affected modes are additive developer feedback mechanisms, not weaker acceptance substitutes.
4. Unknown dependency ownership falls back to broader validation, ultimately Full.
5. Windows PowerShell 5.1 remains the supported validation runtime.
6. Test fixtures/state remain isolated from real BRAVO production state.
7. Runtime integrity and the pre-trust guard boundary are not weakened.
8. Post-Install Verify is production-safe and separate from repository Self-Test.
9. Evidence is reported only for commands/checks actually executed.
10. Behavioral/high-risk changes receive fresh independent review before acceptance.

## 15. Immediate next action

The next implementation action is not a Self-Test refactor.

Start with VAL-01 and VAL-02 as a read-only evidence-gathering wave. Use their results to revise this design before VAL-04 or VAL-08 changes test behavior or structure.

That sequence preserves the existing Full contract while creating a safe path toward faster development validation and a human-oriented Installer.
