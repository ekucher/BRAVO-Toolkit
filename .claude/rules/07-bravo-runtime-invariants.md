# BRAVO Runtime Safety Invariants

Apply this rule to changes affecting BRAVO runtime behavior, especially Archive,
DataRestore, Maintenance, Health, BazaSync, Scheduler, System, Credentials,
configuration loading, persisted state, SFTP, or runtime integrity.

These are operational safety contracts. Do not weaken them as cleanup,
refactoring, UX improvement, compatibility workaround, or test-fix work.

## Fail-closed behavior

- Critical or destructive operations fail closed when BRAVO cannot prove that
  continuing is safe.
- Failure to validate integrity, ownership, scope, paths, credentials, host
  identity, or persisted state is not permission to continue.
- Do not convert a safety stop into a warning merely to keep an operation moving.
- Do not suppress exceptions, ignore exit codes, or add fallback success around
  backup, restore, SFTP, service-control, scheduler, integrity, or state writes
  unless that behavior is an explicit part of the design.

## Configuration compatibility

- Assume deployed `BRAVO.config` files may predate the repository version.
- Every new optional configuration property must receive a safe canonical
  default/normalization before runtime consumers use it.
- The canonical configuration loader owns compatibility normalization. Do not
  scatter missing-property compatibility checks across consumers when the loader
  can normalize the value once.
- Under `Set-StrictMode`, test a legacy configuration that does not contain the
  newly introduced property.
- Do not silently change an existing default.

## Persisted state is an API

- Treat files under `%ProgramData%\BRAVO\State` and other persisted BRAVO state
  as compatibility contracts, not disposable implementation details.
- Before changing state, identify valid states, terminal states, legal
  transitions, retry behavior, partial-failure behavior, and compatibility with
  state written by older versions.
- Never overwrite a stronger/terminal state with a weaker state unless that
  transition is explicitly part of the state machine.
- Preserve atomic write semantics where state protects destructive or recovery
  operations.
- Validate legacy, partial/interrupted, corrupted, and retry scenarios when they
  are relevant to the changed state machine.

## Service quiescence and recovery ownership

- `STOPPED` does not mean `owned by BRAVO`.
- Health must never start an arbitrary stopped service merely because it is
  stopped.
- Automatic recovery requires valid BRAVO ownership evidence and all applicable
  marker checks, including host/schema identity, owner liveness/identity,
  managed-service allowlisting, and restart-suppression semantics.
- Failure to create the required ownership/quiescence marker must abort service
  stopping when that marker is required for safe recovery.
- Do not broaden the managed-service set implicitly.
- Manual administrator service state must not be silently overridden by BRAVO.

## BazaSync append-only and reconciliation

- Append-only mutation detection is a data-integrity/security property.
- Do not silently resolve `MUTATION_VIOLATION`.
- Operator acceptance of an intentional mutation must remain explicit.
- Reconciliation must preserve the previous remote object/evidence according to
  the existing rename/archive design before canonical state advances.
- Do not introduce automatic remote overwrite or delete as a shortcut for
  mutation reconciliation.
- If remote preservation/rename fails, canonical mutation state must not advance
  as though reconciliation succeeded.
- Narrow, explicitly owner-authorized exception: `BAZA.AutoArchiveMutationThreshold`
  (kit default `25` since 5.2.1 — explicit owner decision 2026-08-27 after
  the ДНДІЛДВСЕ incident; `0` = disabled) may auto-run the existing rename-preserve
  reconciliation (never delete, never a new archival layout) when a single
  cycle's mutation count is at or below the configured threshold; above the
  threshold the fail-closed block/CRITICAL path is unchanged. This does not
  authorize a general auto-overwrite policy, a second archival mechanism, or
  removing the fail-closed default — any further weakening of this invariant
  requires the same explicit, conscious owner decision, not incidental
  extension of this exception.

## SFTP and credentials

- SSH host-key pinning is mandatory for BRAVO SFTP sessions.
- Forbidden workarounds include accept-any-host-key, empty fingerprint,
  interactive trust, or fallback that disables host verification.
- Password-based SFTP authentication is an intentional supported deployment
  model. Do not replace it with public-key authentication as an incidental
  refactor unless deployment requirements explicitly change.
- Credentials must come through the canonical BRAVO credential mechanism
  (Windows Credential Manager / `BRAVO.Credentials` where applicable).
- Credential target names may be logged when useful; credential values may not.
- Never log or persist secret-bearing URIs such as
  `sftp://user:password@host/...`.
- Minimize creation of additional plaintext password strings when an API accepts
  a secure credential representation directly.

## Runtime and tool integrity

- Runtime/tool integrity failures are security events, not manifest-maintenance
  prompts.
- Do not weaken or bypass `RUNTIME_MANIFEST` / `TOOLS_MANIFEST` verification to
  make a deployment or test pass.
- Establish why a tracked runtime/tool file changed before regenerating hashes.
- Regenerate manifests only through the repository's canonical scripts, such as
  `ci/Update-BRAVORuntimeManifest.ps1` and
  `ci/Update-BRAVOToolsManifest.ps1`, when those are the current canonical
  owners. Never hand-edit generated hashes.
- Third-party binary updates require intentional source/version review,
  integrity-manifest update, and compatibility validation.

## Restore safety

- Backup creation is not proof of recoverability.
- Do not delete or invalidate the last known recoverable copy as part of a
  normal restore/cleanup path.
- Restore must use validated generations and preserve enough evidence for
  diagnosis/rollback after failure.
- Do not silently select a different generation when the preferred generation
  is malformed/unavailable without making that anomaly observable and preserving
  the documented restore policy.
- Component restore must not silently cross generation boundaries unless that is
  explicitly part of the restore contract.

## Operational contracts

- Exit-code semantics are an operational API. Use the canonical `BRAVO.ExitCodes`
  ownership and do not invent conflicting meanings.
- Notification and telemetry are secondary effects unless explicitly defined as
  part of the primary operation contract. Their failure must not silently rewrite
  a successful backup/restore result into a different primary result.
- Operator-facing failures should state what failed, the affected component,
  required operator action when known, and where authoritative detail is logged.

## Runtime-state architecture

- Do not introduce new `$global:` runtime state when explicit parameters, return
  objects, module-local state, or an explicit runtime context are practical.
- Existing `$global:` usage is compatibility debt. Do not migrate all globals as
  opportunistic work inside an unrelated bug fix.
- New reusable domain logic belongs in the canonical domain module, not in a root
  orchestration entrypoint.

## Validation expectations

For runtime bug fixes, where practical demonstrate:

1. pre-fix reproduction fails;
2. the same regression passes after the fix;
3. affected domain tests pass;
4. full `BRAVO_SELF_TEST.ps1` passes when the change is runtime-relevant.

For collection-sensitive PowerShell logic, test zero, one, and multiple results.
For config changes, test current, legacy-missing-property, and invalid-value cases.
For persisted-state changes, test clean, legacy, interrupted/partial, and retry
cases when applicable.

Do not describe a change as production-safe solely because CI passed when the
behavior depends on real Windows services, Task Scheduler, Credential Manager,
WinSCP/SFTP, boot behavior, or destructive restore/reconcile semantics. State the
required real-server acceptance explicitly.
