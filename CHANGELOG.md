# Changelog

## 5.1.0-dev.1 — 2026-08-12

Opens the next development cycle on top of the 5.0.0 stable baseline
(`master` merged into `developer`). Minor version: this cycle already
carries new functionality (Retention Safety Invariants), not only fixes.
No configuration schema, state schema, credential target, archive format,
transfer protocol, or supported-OS contract changed. The default minimum
retained verified generations did change (1 -> 2, see Retention Safety
Invariants below).

- Automatic restore recovery now guarantees a daily retry inside the
  configured `Restore.WindowStart`/`WindowEnd` window regardless of
  `Maintenance.DailyAt` or server reboots. The `Recovery` scheduled task
  gains a second, daily trigger at `Restore.WindowStart` on the same task
  definition (same `-RunMissedRestoreOnly` action as the existing
  boot trigger) — previously only a boot-triggered retry (15 min for 8
  hours) existed, so a server that stayed up with `Maintenance.DailyAt`
  outside the restore window could skip a missed restore indefinitely.
  The Maintenance.DailyAt-outside-window log message no longer claims the
  daily path is lost and is downgraded from `WARNING` to `INFO`. The
  `Recovery` task itself is now always registered (`Scheduler.Recovery.Enabled`
  is no longer tied to `Restore.RunMissedOnStartup`): the daily trigger is
  unconditional, and `Restore.RunMissedOnStartup` now only controls whether
  the additional boot trigger is also created — previously setting it to
  `false` disabled the daily safety net along with the boot retry.
- Automatic restore now re-validates `Restore.WindowStart`/`WindowEnd`
  immediately before the destructive `bravocmd.exe` call, not only once at
  the start of the run. `$shouldRestore` was computed before
  `Enter-BRAVOMaintenanceOperationLock` (up to `OperationLockWaitMinutes`,
  360 min by default), service stop, and the before-restore archive — the
  window could close during that wait and the old check was never a final
  authorization. Two barriers (before entering the restore sequence, and
  immediately before `bravocmd.exe`) call the same `Test-BRAVORestoreExecutionStillAllowed`
  check; a window that closes in between now postpones the restore (clear
  `WARNING`, no `bravocmd.exe` call, no success marker/state write, the
  scheduled slot stays retryable) instead of running past the window.
  `-ForceRestore` is unaffected by either barrier.
- `Remove-BRAVOOrphanedTemporaryArchiveArtifacts` (orphaned `.work\*.partial*`
  cleanup, introduced in 5.0.0) no longer uses `Test-Path` to check whether
  `.work` exists. `Test-Path` cannot be fail-visible for a pure local ACL
  access-denied on an existing directory — `.NET Directory.Exists` (which
  the filesystem provider uses) swallows `UnauthorizedAccessException` by
  design and returns `$false`, indistinguishable from "doesn't exist." The
  existence check is now folded into the same `Get-ChildItem` call that
  already enumerates `.partial*` files, classified by exception type:
  `ItemNotFoundException`/`DirectoryNotFoundException` is a benign skip,
  anything else (`UnauthorizedAccessException`, `IOException`, provider/
  network errors) marks the operation failed and logs `ERROR`.
- `Recovery`'s daily trigger now has `StartWhenAvailable=true` (every other
  task type keeps the global default of `false`): if the trigger is missed
  because the server was asleep/offline, Task Scheduler catches it up as
  soon as the server is available again, instead of waiting for the next
  scheduled occurrence. Safe only because of the two TOCTOU barriers above
  — a late catch-up that lands outside the window now correctly no-ops.
- Retention Safety Invariants: generation-aware backup retention now also
  sweeps orphaned `.work\*.partial*` temporary archive artifacts left behind
  by a killed process, raises the default minimum retained verified
  generations from 1 to 2, and emits a single per-run retention audit log
  line (evaluated/protected/deleted counts).
- Windows service run-state (`Running`/`Stopped`/`Disabled`/not installed)
  can no longer gate backup — only the operations that genuinely require a
  stopped service (destructive restore, other destructive MODEL operations,
  open application-log rotation) may depend on it; this is now a documented
  architectural contract (`OPERATIONS.md`, "Стан служб не визначає політику
  backup"). `Find-BRAVOServiceByCandidates` (used by installation-path
  discovery for `BRAVO_ROOT`, `WEB_ROOT`/`BAZA_WWW`) previously excluded any
  service with `StartMode=Disabled`, conflating "administratively disabled"
  with "not installed": a `Disabled` BRAVO Web/Apache service made
  `BAZA_WWW` backup (both SFTP and local synchronization) silently
  unresolvable even though its `DocumentRoot` directory remained fully
  readable on disk — a service-state gate with no underlying filesystem
  error. The `Disabled` exclusion is removed; service state no longer
  affects path identity (the same principle `Resolve-BRAVOEffectiveLimsRoot`
  already documented for `LIMSRoot`), and a `Disabled` match now appends a
  diagnostic-only `[УВАГА: служба має тип запуску Disabled]` note to
  `BRAVO_ROOT`/`WEB_ROOT` reasons instead of failing discovery. When the
  BRAVO Web/Apache service is genuinely absent (not just disabled) and no
  `discoverySettings.Sources.BAZA_WWW`/`.WebRoot` override is configured,
  `BAZA_WWW`'s discovery-failure reason now explicitly says the service
  could not be found (previously a dangling, unexplained "BAZA_WWW не
  визначено: ") — a controlled "source unknown" failure, never phrased as
  a service-state policy denial. Regular backup generation (MODEL/BLOG/
  BRAVOEXCH, sourced only from `bravo.ini`), pre-/post-restore MODEL
  backups, and `ArchiveAfterMaintenance` were already service-state
  independent; audited and confirmed with new regression coverage.
- Closed a second, deeper instance of the same invariant: `BRAVO.config`
  called `Resolve-BRAVOEffectiveLimsRoot` for `pathSettings.LIMSRoot`
  (default `""` = AUTO from the BRAVO service) and `throw`n immediately
  when the service was absent — before `Resolve-BRAVOInstallationDiscovery`
  (MODEL/BLOG/BRAVOEXCH) ever ran. A production-loader-level test (driving
  the real `Import-BravoConfiguration` + `BRAVO.config`, not the Discovery
  helper directly) confirmed this: with the BRAVO service absent, a
  perfectly valid canonical `bravo.ini`, and an explicit `BackupRoot`,
  config loading still failed on the LIMSRoot check alone. `LIMSRoot`/
  `SystemLogRoot` resolution no longer throws inside `BRAVO.config` itself;
  each consumer now decides its own criticality. `BRAVO_ARCHIV` reads
  neither value (confirmed by grep: MODEL/BLOG/BRAVOEXCH come only from
  `bravo.ini`, `BackupRoot` has its own independent explicit-or-AUTO
  resolution with its own `Error`/throw, and `BRAVO_HEALTH` reads neither
  value either — it already only requires `BackupRoot`). `BRAVO_MAINTENANCE`
  is unaffected: it already had its own explicit, independent guard
  (`effectiveLimsRoot`/`systemLogRoot`/`backupRootPath` non-empty, `exit 30`
  otherwise) immediately after loading configuration, so Maintenance's
  fail-closed behavior when it genuinely needs the installation root is
  unchanged — now protected by a regression test
  (`ProductionConfig/MaintenanceOwnLimsRootGuardStillBlocks`) so it cannot
  be silently weakened later. Two related latent bugs, both surfaced only
  by testing the real config-loader path (not the Discovery helper in
  isolation): `Resolve-BRAVOInstallationDiscovery`'s unused `-LimsRoot`
  parameter was `Mandatory`, so passing the now-legitimately-empty
  `$rootPath` threw a parameter-binding error instead of proceeding — fixed
  by dropping `Mandatory` from a parameter the function body never reads;
  and Archive's free-space preflight passed the same possibly-empty
  `$rootPath` as `-RootPath` to `Get-BRAVOArchiveFreeSpaceResult`, whose own
  sanity `Test-Path` throws on an empty string — fixed by falling back to
  `$runtimeRoot` (always valid) when `$rootPath` is empty; the free-space
  check itself already evaluates every fixed drive regardless of
  `-RootPath`, so this changes no free-space behavior.
- Regression coverage: real COM `Schedule.Service` tests prove the
  `Recovery` task registers boot+daily triggers when `RunMissedOnStartup=true`,
  daily-only (task still registered, not disabled) when `false`, and
  `StartWhenAvailable=true` only for `Recovery`; a behavioral test with an
  injectable time provider proves the TOCTOU re-check blocks automatic
  restore once the window has passed while still allowing `-ForceRestore`;
  structural tests prove both barriers sit exactly where they must, ahead
  of the destructive call; four behavioral orphan-sweep cases cover
  missing `.work` (benign), access-denied, and a distinct I/O failure type,
  plus a structural test proving `Test-Path` is no longer called at all;
  a composite test proves a corrupted newest backup generation cannot
  evict an older verified-valid one from the retention-protected set.
  Service-state independence has two coverage layers, named to match what
  each actually proves: `Discovery/BackupSourcesResolveWhenBravo*` and
  `Discovery/BazaWWWResolvesWhenApache*` are behavioral tests of
  `Resolve-BRAVOInstallationDiscovery` alone (all three BRAVO/BravoWeb
  service states resolve `BRAVO_ROOT`/`MODEL`/`BLOG`/`BRAVOEXCH`/
  `BAZA_APP`/`BAZA_WWW` identically, `BAZA_WWW` from the same `httpd.conf`
  in every case) — an earlier round of these tests was named
  `Backup/WorksWhenBravoService*`, which misleadingly implied execution
  coverage for what was actually discovery-only coverage; renamed. Two more
  Discovery-level tests cover the service-genuinely-absent case distinctly
  from "disabled" (explicit override still resolves `BAZA_WWW`; no override
  gives a controlled "source not found" failure, not a service-denial
  message), and one proves `MODEL`/`BLOG`/`BRAVOEXCH` still resolve from
  `bravo.ini` with the BRAVO service entirely absent. Beyond discovery,
  three genuinely behavioral tests (`Backup/ArchiveInvokedWhenBravoService*`)
  drive the real Invoke-BRAVOComponentBackup control flow — its own atomic
  create/hash/verify/publish orchestration is exercised unmocked; only the
  archive/hash primitives (`New-Archive`, `New-SHA512Hash`,
  `Get-BRAVOFileHash`, `Write-BRAVOFinalHashFile`) are stubbed — from a
  discovered source through to a published archive on disk, once per BRAVO
  service state, confirming the archiver is actually invoked (a call
  counter proves it) and the archive actually exists regardless of service
  state. A third layer (`ProductionConfig/*`) goes one level deeper still:
  nine tests drive the real `Import-BravoConfiguration` against the real
  `BRAVO.config` text (targeted, verified regex substitution of specific
  config values only — the same technique `Version/AuthoritativeLoader`
  already used for `LIMSRoot`), with `Get-CimInstance`/`Get-WmiObject`
  shadowed at global scope to control service presence deterministically
  (the only reliable interception point across a module boundary — BRAVO's
  own functions cannot be shadowed that way, each module keeps its own
  session state, but foreign cmdlets resolve through the caller's scope
  chain). These prove, end to end: BRAVO absent + canonical `bravo.ini` +
  explicit `BackupRoot` reaches a ready `archiveDefinitions[MODEL].Source`;
  BRAVO absent + explicit source overrides work with no `bravo.ini` at all;
  BRAVO absent + no source of any kind fails closed with a "source unknown"
  reason, never a service-state one; the same two contrasting outcomes for
  Apache-absent `BAZA_WWW`; and Running/Stopped/Disabled remain unchanged
  through the full loader, not just the Discovery helper. Structural tests
  (clearly labeled as such, not behavioral) separately prove the
  pre-/post-restore archive calls and the `ArchiveAfterMaintenance` launch
  decision contain no service-status re-check; a true behavioral invocation
  test for the latter was judged impractical without restructuring
  `BRAVO_MAINTENANCE.ps1`'s monolithic top-level flow into a callable
  function purely for testability.

## 5.0.0 — 2026-08-11

Stable production release promoted from the verified 5.0.0-rc.1 candidate.
The candidate passed the complete Windows CI pipeline and real-server checks
on Windows Server 2022 / Windows PowerShell 5.1: archive generation and 7-Zip
validation, SHA512 publication, SFTP upload, health-check, maintenance and
notifications. No configuration schema, state schema, credential target,
archive format, retention default, transfer protocol, or supported-OS contract
changed during promotion.

- Archive now performs the same fixed-drive free-space preflight as
  Maintenance before cleanup, local synchronization, VSS, or archive
  generation can mutate state. It uses `Limits.MinimumFreeSpaceGB` and
  `Limits.ExcludedDrives`, reports every checked drive, stops with the
  canonical local-archive exit code `40`, and renders a normal final failure
  summary instead of ending without an operator result.
- A failed Archive free-space preflight now sends one immediate `CRITICAL`
  Discord/Slack notification in `errors_only` or `all` mode. The message
  identifies the affected drive, free/total space, configured threshold,
  action required, log path and exit code. `NotificationMode=none` and
  `-NoSlack` remain authoritative; webhook failure is logged with protected
  secrets and never replaces the primary exit code.
- VSS ownership state and generation manifests are now written through
  temporary files and atomically replaced with legal backup paths compatible
  with Windows PowerShell 5.1/.NET Framework. A failed replacement preserves
  the previous valid state/manifest and cleans temporary backup files.
- Archive publication is fail-closed when the final `.sha512` sidecar cannot
  be written. The already moved archive and any partial sidecar are rolled
  back, published paths/hash fields are cleared, and the failure is classified
  as `PUBLISH`/exit `40` rather than a misleading hash-validation failure.
- Generation finalization now occurs before exit-code calculation and the
  operator summary. Failure to persist the final transfer/health state marks
  the run failed. Result objects also carry stable failure fields, scalar
  success counts are StrictMode-safe, and snapshot paths are initialized per
  component so stale values cannot leak into an exception path.
- Maintenance low-disk termination now renders the standard final summary,
  uses the resolved BRAVO exit code, respects `-NoPause`, and writes unique
  second-and-PID log names. The default scheduled restore day is explicitly
  Sunday (`7`).
- The narrowly required `ExecutionPolicy Bypass` allowance for generated
  manual launchers is documented and scoped to `BRAVO_SETUP.ps1`; all other
  forbidden-pattern checks remain blocking.
- `modules/BRAVO.Notifications/BRAVO.Notifications.psd1` now carries the
  repository-required UTF-8 BOM. A clean GitHub Actions checkout previously
  failed both the explicit BOM gate and the Windows PowerShell 5.1 self-test,
  even though local parser and runtime checks passed on the development host.
- Regression coverage was added for free-space policy and notifications,
  preflight ordering, atomic state replacement, failed SHA512 publication,
  manifest finalization, failure-stage mapping, StrictMode result handling,
  Maintenance early summaries/log naming/default schedule, and launcher
  policy. `RUNTIME_MANIFEST.json` is regenerated from the final RC files.

## 5.0.0-dev.19 — 2026-08-11

Minimal observability/correctness release, from two real DEV-LIMS
acceptance runs of 5.0.0-dev.18, with a review pass applied before
release that replaced an initial, still-independent status-classification
design with one that consumes the actual resolved BRAVO exit code (see
the first two bullets below). Four focused fixes — no backup, restore,
VSS, SHA512, retention, MANIFESTS, transfer, notification routing,
`NotificationMode`, scheduler, or exit-code numerical semantics
changed; Range ID missing-file warning-only semantics untouched.

- Maintenance's final human-readable status (log `=== СТАТУС: ... ===`,
  console `РЕЗУЛЬТАТ` "Статус" field, and the success/warnings-branch
  Discord/Slack notification) now derives from the SAME resolved BRAVO
  exit code that the process actually exits with — not from an
  independent re-check of `$script:criticalErrorOccurred`/
  `$script:BRAVOWarningCount`. `Get-BRAVOMaintenanceResolvedExitCode`
  is the one place that priority policy (critical > warnings > success,
  40/41/60 via `Resolve-BRAVOExitCode`) lives; `Get-BRAVOMaintenanceFinalStatus
  -ExitCode <resolved code>` is a pure function that classifies that
  number via `Get-BRAVOExitCodeName` (`Success`/`SuccessWithWarnings`/
  anything else) into text/color — it no longer inspects the two flags
  itself. The exit-code resolution was also moved earlier: it now runs
  immediately after the outer try/catch closes (all business operations
  and fail-safe handling, including the catch's own critical-flag set,
  have already completed) and before the LOG `=== СТАТУС ===` line is
  written, not after it as in the first cut of this fix — so the LOG
  can no longer read a value computed from a different, earlier
  snapshot than the process's actual exit code. `Send-FinalReport`'s
  notification runs earlier still (inside the try, before its catch),
  so it takes its own snapshot through the same canonical resolver;
  if a later unhandled exception changes the outcome, the real,
  later-computed `$script:maintenanceRuntimeExitCode` — not this
  notification — governs the process exit code, exactly as before. A
  real run with a missing Range ID log (`Test-RangeIdUsage`'s existing
  `WARNING`-only path — unchanged) resolved exit code 10
  (`SuccessWithWarnings`), but the LOG/console/notification all said
  `УСПІШНО` with no mention of the warning; they now say `УСПІШНО З
  ПОПЕРЕДЖЕННЯМИ` (the console previously said `ЧАСТКОВО` for the same
  condition). `ПОМИЛКА` (any of 40/41/60, or any other non-success/
  non-warning code) and plain `УСПІШНО` are unchanged.
- The warnings notification no longer pairs a ✅ icon with "Дій не
  потрібно" (no action needed) — `New-MaintenanceNotificationMessage`'s
  severity classification now checks its canonical `:warning:` marker
  before the `Title`-text "УСПІШ" match (previously the text match
  always won, so a warnings-flavored Title with an explicit `:warning:`
  emoji still classified as SUCCESS). The rendered notification for
  warnings now shows `:warning: BRAVO MAINTENANCE — ПОТРІБНА ДІЯ` /
  "Потрібна дія: перевірити журнал BRAVO_MAINTENANCE." — the repository's
  existing warning-severity wording (same two fixed strings the other
  `:warning:`-emoji call site, `Send-InactiveServiceWarning`, already
  produces), not literal Title text. Plain success is unaffected (still
  `:white_check_mark:` / "Дій не потрібно"); routing, `NotificationMode`,
  `allowed_mentions`, timeout, and delivery mechanics are untouched.
- Maintenance runtime-log bare `"==="` separators — Maintenance's own,
  separate `Write-Log`/`Write-BRAVOMaintenanceLogFile` implementation,
  not shared with Archive's dev.18 fix — no longer write a log record.
  Root cause: `Write-BRAVOMaintenanceLogFile -Entry ("=" * $SeparatorLength)`
  built a literal 100-character `====...====` row with zero diagnostic
  value, always immediately adjacent to a real `"=== HEADING ==="` call
  that already logs the same moment with full text. Applied uniformly
  to every bare `"==="` call site, including the start/end banners —
  the same call, same `"==="` argument, with no separate "banner-only"
  code path in the source. Meaningful `=== HEADING ===` records
  (ДЖЕРЕЛА ЖУРНАЛІВ, ПЕРЕВІРКА ВІЛЬНОГО МІСЦЯ, ЗУПИНКА СЛУЖБ, ПЕРЕВІРКА
  РОЗМІРІВ .MD ФАЙЛІВ, РЕСТАВРАЦІЯ МОДЕЛІ, ОБРОБКА TRACE-ФАЙЛІВ, ОБРОБКА
  ЛОГІВ EXCHANGAPI, ВІДНОВЛЕННЯ ПОЧАТКОВОГО СТАНУ СЛУЖБ, ОЧИСТКА СТАРИХ
  ДАНИХ, ВІДПРАВКА ПОВІДОМЛЕННЯ ПРО ПОДІЮ, and both banner headings)
  are completely unchanged.
- Archive's VSS diagnostic log line ("Узгодженість архівів: ...") is
  now factually correct. It said "окремий VSS-знімок для кожного
  компонента" (a separate snapshot per component), while the runtime
  has always created exactly one VSS Snapshot Set per generation
  (`New-BRAVOVSSSnapshotSet`), shared by every enabled component
  (MODEL/BLOG/BRAVOEXCH) — the same terminology `BRAVO_DRY_RUN.ps1`
  already uses. This was flagged as a known, deliberately-deferred
  issue in the dev.18 changelog entry above; it is fixed here. Text
  only — VSS creation/cleanup, `SnapshotContext`, `SnapshotSetId`,
  volume discovery, snapshot lifetime, and generation semantics are
  unchanged.
- Archive's `=== СТВОРЕННЯ ХЕШУ <компонент> ===` heading now prints
  immediately before the first hash-generation action
  (`New-SHA512Hash`), inside `Invoke-BRAVOComponentBackup` itself,
  instead of in `Main` after the entire component backup (create +
  hash + verify + publish) had already finished. A real run's log
  showed the heading appearing after the work it described. The single
  call site (`Invoke-BRAVOComponentBackup`, inside the `foreach
  ($archive in $readyArchives)` loop) means the fix applies uniformly
  to every enabled component without per-component duplication. Moving
  the heading also fixes log component attribution for free:
  `Resolve-BRAVOLogComponentFromHeader`/`Set-BRAVOLogComponent` now
  switch `$script:BRAVOLogComponent` to `HASH` before, rather than
  after, the hash work. SHA512 computation, sidecar filename/encoding,
  integrity verification, archive publication, generation-COMPLETE
  rules, and transfer ordering are unchanged.
- Tests: 20 new checks — `Maintenance/Exit0RendersSuccess` /
  `Exit10RendersSuccessWithWarnings` / `Exit40RendersFailure` /
  `Exit41RendersFailure` / `Exit60RendersFailure` (functional calls to
  the real, isolated `Get-BRAVOMaintenanceFinalStatus -ExitCode`, one
  per code Maintenance can actually produce); `Maintenance/FinalStatusConsumesResolvedExitCode`
  (AST proof `Get-BRAVOMaintenanceFinalStatus`'s own body never
  references `$script:criticalErrorOccurred`/`$script:BRAVOWarningCount`,
  `Get-BRAVOMaintenanceResolvedExitCode` genuinely calls
  `Resolve-BRAVOExitCode`, and the LOG/console assignments occur in
  source AFTER `$script:maintenanceRuntimeExitCode`'s one assignment —
  actual data flow, not just co-located text); `Maintenance/FinalStatusDoesNotCallIndependentWarningPolicy`
  (the `УСПІШНО З ПОПЕРЕДЖЕННЯМИ` literal exists exactly once in the
  source, and the helper is called from exactly its three consuming
  sites); `Maintenance/WarningsNotificationUsesWarningMarkerNotSuccess`
  / `PureSuccessNotificationUnaffectedBySeverityReorder` (real,
  isolated `New-MaintenanceNotificationMessage` calls confirming the
  ✅/⚠️ + operation/action-text consistency fix, and that it leaves the
  plain-success rendering unchanged); `Maintenance/RangeIdMissingRemainsWarningOnly`
  (`Test-RangeIdUsage`'s missing-file branch untouched: one `Test-Path`,
  no `New-Item`, `WARNING`-level); `Maintenance/SectionSeparatorsDoNotEmitBareLogRecords`
  / `SectionHeadingsRemainLogged` / `RuntimeLogHasNoRedundantSeparatorOnlySections`
  (structural proof of the bare-separator branch plus a real functional
  round-trip through Maintenance's own `Write-Log` into a temp file);
  `Archive/VssDiagnosticDescribesSingleGenerationSnapshotSet` /
  `VssDiagnosticDoesNotClaimPerComponentSnapshots` /
  `VssBehaviorCodeUnchangedByDiagnosticFix` (AST call-count proof that
  `New-BRAVOVSSSnapshotSet`/`Remove-BRAVOVSSSnapshotSet` are untouched);
  `Archive/HashHeadingPrecedesHashWork` /
  `HashHeadingPrecedesHashWorkForAllEnabledComponents` /
  `HashLogsUseHashComponentAfterHeading` /
  `HashBusinessCallsRemainUnchanged` (AST source-order proof plus a
  real functional round-trip confirming the HASH component tag). Two
  pre-existing tests were updated in place: `Maintenance/FinalSummarySuccess`
  (dev.14, asserted the now-superseded `ЧАСТКОВО`/independent `elseif`
  wording) and `ConsoleUX/21-ExitCodeComputedBeforeRender` (dev.16,
  its Maintenance anchor text matched the old inline exit-code
  assignment); two source-order tests (`Maintenance/FinalSummaryOccursBeforeManualPause`,
  `Maintenance/PostOperationsPrecedeFinalSummary`, both dev.15) picked
  up the same new anchor automatically since they reuse the shared
  index variable. Full suite: 713/713.

## 5.0.0-dev.18 — 2026-08-10

Minimal operator-flow/observability correctness release, from a real
manual DEV-LIMS `BRAVO_ARCHIV` 5.0.0-dev.17 run. Three related defects,
tightly scoped — no backup, VSS, retention-policy, MANIFESTS, transfer,
notification, scheduler, or exit-code semantics changed. (A separate,
already-known factual VSS diagnostic-wording issue — "Узгодженість
архівів: окремий VSS-знімок для кожного компонента", while the runtime
actually uses one Snapshot Set per generation — is intentionally **not**
addressed here; it will be handled separately.)

- Manual Archive/Health/Maintenance operator executions no longer skip
  the configured exit pause solely because stdin is reported as
  redirected when a usable interactive console exists. The real run's
  header correctly said `MANUAL`, but the window closed immediately
  after the final RESULT instead of waiting — `Wait-BRAVOManualExit`
  (`BRAVO.Console`, shared by all three runtimes) treated
  `[Console]::IsInputRedirected` as an independent, unconditional
  reason to skip the pause, before `$Host.UI.RawUI.ReadKey(...)` (which
  reads the console input buffer directly and does not depend on
  stdin redirection) ever got a chance to run. `-NoPause` remains the
  authoritative scheduled/automation pause bypass (`BRAVO_TASKS_INSTALL.ps1`
  adds it to every scheduled task; the Maintenance→Archive child launch
  and the self-test both already use it explicitly), and
  `consoleSettings.PauseOnExit = $false` remains the explicit
  configuration bypass — neither changed. `RawUI.ReadKey` stays
  primary, `Read-Host` stays its ISE/non-console fallback.
- Archive old-log cleanup (`Очищення старих журналів`) and
  backup-generation cleanup (`Очищення старих backup generation`) now
  participate in the same dynamic `[N/M]` numbered-step sequence as
  every other operator-visible Archive operation, instead of rendering
  as unnumbered rows outside the canonical sequence. Old-log cleanup is
  always evaluated and always occupies one step; generation cleanup
  occupies one step only when the existing enablement expression
  (`enableArchiveDeletion -or enableFailedArchiveDeletion -or
  enableLunchArchiveCleanup` — unchanged) is true, and no step at all
  when fully disabled. The dynamic step `Total` and the `План операцій:`
  entries were already driven by the same flags and needed no semantic
  change, only the two cleanup operations' own render call
  (`Write-BRAVOOperationResult` → `Write-BRAVOArchiveStep`). Execution
  order is unchanged — only which renderer each call uses.
- Empty structured Archive runtime-log records used only as visual
  section separators (`timestamp [INFO] [COMPONENT]` with a blank
  Message — one per section transition: STARTUP, CREDENTIALS, VSS,
  SFTP-ARCHIVE, PATHS, ARCHIVE, HASH, BAZA_APP, SUMMARY, ...) are no
  longer emitted. Root cause: the bare `"==="` separator (always
  immediately adjacent to a real `"=== HEADING ==="` call, which
  already logs the same moment and component with full text) built its
  log line as `"=" * $SeparatorLength`, and the `$SeparatorLength`
  default resolved to an empty string in this call path. Rather than
  chase that resolution further, the bare-separator branch of Archive's
  `Write-Log` shim now simply does not write a log record at all — the
  adjacent heading already carries the section-transition information,
  so no diagnostic value is lost. Meaningful `=== HEADING ===` records
  (`=== ОПЦІЇ СКРИПТА ===`, `=== АРХІВАЦІЯ MODEL ===`, `=== ЗАВЕРШЕННЯ
  РОБОТИ СКРИПТА ===`, etc.) are completely unchanged. Timestamp/level/
  component format, log file paths, retention, and console thresholds
  are untouched; shared `BRAVO.Logging` was not modified.
- Tests: ~19 new/updated checks — `Console/ManualExit*` (NoPause and
  PauseOnExit=false bypass functionally via real, non-blocking calls to
  `Wait-BRAVOManualExit`; structural proof `IsInputRedirected` is no
  longer a standalone pre-check while `UserInteractive` remains one;
  RawUI/Read-Host fallback intact), `Archive/ManualModeAndPauseUseSameNoPauseContract`
  (Archive/Health/Maintenance all delegate to the one shared helper, no
  duplicated `RawUI.ReadKey`), `Archive/*CleanupUsesNumberedStep*` /
  `DynamicTotalIncludesCleanupOperations` / `PlanAndCleanupStepsShareEnablementSemantics`
  / `CleanupNoWorkRendersSkipped` / `CleanupOperationsNoLongerUseUnnumberedRenderer`,
  and `Logging/RuntimeLogHasNoEmptyStructuredRecords` (a real functional
  round-trip through Archive's `Write-Log` and `BRAVO.Logging` into a
  temp file, asserting no physical line has an empty Message) plus
  `Archive/SectionSeparatorsDoNotEmitEmptyLogEvents` /
  `SectionHeadingsRemainLogged`. Two pre-existing dev.16 tests
  (`Archive/LogCleanupIsUnnumberedOperation`, `Archive/BackupRetentionCleanupAggregatesSubCleanup`)
  and one dev.16 Console test (`ConsoleUX/13-RedirectedNonInteractiveSkipsWait`)
  were updated in place, since their assertions encoded exactly the
  now-corrected (unnumbered renderer / IsInputRedirected-as-blocker)
  behavior. Full suite: 693/693.

Note: `BRAVO.Maintenance.Runtime.ps1` has its own, separate copy of the
same bare-`"==="`-separator pattern (`Write-BRAVOMaintenanceLogFile
-Entry ("=" * $SeparatorLength)`), which may have the same defect. It
was deliberately left untouched here — out of scope for this
Archive-focused release ("do not change Maintenance business logic");
worth a follow-up look separately.

## 5.0.0-dev.17 — 2026-08-10

Minimal correctness fix on top of dev.16, from a real DEV-LIMS
acceptance run (generation `20260810_185725`, backup ~18:57 local
server time). Health confirmed all components and SFTP `OK` for that
generation — but the Discord success notification showed `🕒 Остання
резервна копія: 10.08.2026 15:57` next to a correct `⏳ Вік копії: 5
хв.`. Generation selection, backup-age calculation, and UTC
normalization were all correct; only the human-readable absolute
timestamp was wrong — it rendered the internally normalized UTC value
(`15:57`) as if it were the server's local time (`18:57`).

- `Get-BRAVOHealthLatestBackupSummary` (`BRAVO.Health.Runtime.ps1`):
  `TimestampText` now converts the UTC timestamp to local time
  (`.ToLocalTime()`) immediately before formatting — the internal
  model, `AgeText` (still `Format-BackupAge`/`Get-BRAVOUtcAge` on the
  raw UTC value), and generation selection are all unchanged. This is
  the single point both the success (`Остання резервна копія`) and
  problem (`Остання успішна резервна копія`) notification builders
  read `TimestampText` from, so both are fixed by the one change — no
  duplicated timezone-conversion logic.
- Manifest `createdAt`/`startedAt` semantics, `ConvertTo-BRAVOUtcDateTime`,
  backup generation selection, `MaxBackupAgeHours`, retention, MANIFESTS
  lifecycle, archive format, VSS, SFTP/SMB, BAZA synchronization, Health
  PASS/WARN/FAIL logic, notification routing/mode, and exit codes are
  all unchanged.
- Tests: `Health/LatestBackupTimestampRendersLocalTime` (functional —
  reproduces the exact DEV-LIMS numbers via `[datetime]::SpecifyKind`,
  timezone-independent, no hardcoded UTC+3),
  `Health/BackupAgeStillUsesUtcSemantics` (confirms `AgeText` is
  unaffected), `Health/SuccessAndProblemNotificationsReuseLatestBackupTimestamp`
  (confirms both notification builders share the one conversion point).
  Full suite: 679/679.

## 5.0.0-dev.16 — 2026-08-10

Minimal PowerShell 5.1 / `Set-StrictMode` reliability fix on top of the
published dev.15: no operator-console/UX change, no MANIFESTS/retention
policy/business-semantics change.

Real DEV-LIMS dev.15 acceptance confirmed `[1/8]`..`[8/8]`, the `[5/8]`
Restore `SKIPPED` line, the `[8/8]` Range ID single-render, and the final
summary printing before the manual pause — all as designed. But after
`[8/8]`, cleanup threw `The property 'Count' cannot be found on this
object. Verify that the property exists.` The dev.15 fail-safe catch
(finalization block introduced in dev.15) correctly turned this into a
critical run (exit 60) and still printed the final summary — exactly the
behavior it was built for — but the underlying exception itself is now
fixed at its root cause.

- `Remove-OldRestoreArchives`: two `Where-Object` pipelines that can
  legitimately return exactly one match (`$beforeCount`/`$afterCount`, the
  before/after archive count for a kept restore session) now materialize
  their result as an array via `@(...)` before `.Count`. Under
  PowerShell 5.1 with `Set-StrictMode` active (inherited from the
  configuration loader, per existing project convention — see the
  `PropertyNotFoundStrict` precedent already fixed for `$missingDirs` in
  the same file), a single-result pipeline returns a scalar object instead
  of a collection, and `.Count` on that scalar throws exactly the observed
  error. Same fix applied to `$remainingFiles` (the post-deletion "what's
  left" debug listing), which had the identical `Get-ChildItem` +
  unwrapped `.Count` shape.
- Scope: only `Remove-OldRestoreArchives` was audited and only these two
  call sites needed the fix — every other `.Count` in that function was
  already array-wrapped at assignment (`$mainArchiveFiles`, `$sortedGroups`,
  `$groupsToKeep`, `$groupsToDelete`, `$staleInvalidGroups`), and
  `$group.Count` (a `Group-Object` `GroupInfo.Count`) is a real, always-safe
  property left untouched. No repository-wide sweep.
- The dev.15 fail-safe finalization (outer `try/catch` around Range ID /
  cleanup / `BRAVO_ARCHIV` / auto-shutdown / final-report, non-empty
  swallow-catch bodies) is unchanged — it already did its job correctly
  for this exact real-world exception and stays as the safety net for any
  future one.
- Tests: 4 new isolated regression checks for `Remove-OldRestoreArchives`
  (real function via AST extraction, synthetic TEMP directories — never
  production DEV-LIMS paths — running under a real `Set-StrictMode
  -Version Latest` inside the invocation, reproducing the exact failure
  condition rather than simulating it): a single-result `before`/`after`
  count each reads back as `1` without throwing, a single remaining file
  after deletion doesn't throw, and the whole call completes cleanly under
  strict mode with a single-item pipeline result.

**Operator-visibility pass** (still dev.16, unpublished): closes the gap
where four top-level `BRAVO_MAINTENANCE.ps1` operations that really run
every time had no console execution result — LOG-only. The approved
`[1/8]`..`[8/8]` contract, `Initialize-BRAVOMaintenanceSteps -Total 8`
(literal), MANIFESTS, and retention semantics are all unchanged; none of
the four gets a `[N/8]` number or touches the step counters.

- `Write-BRAVOOperationResult` (new, `BRAVO.Console`): the same
  alignment/status/duration/details contract as the numbered-step
  renderer, minus the `[N/TOTAL]` prefix (6-space indent instead) and
  without touching step counters — for top-level operations that are
  real but intentionally outside the numbered contract.
- Legacy log migration, old-data cleanup, the `BRAVO_ARCHIV.ps1` launch,
  and auto-shutdown scheduling each now print a `SKIPPED`/`OK`/`WARN`/
  `FAIL` result line (with a short `-Details` reason on warning/failure),
  in their existing execution position — migration keeps running between
  directory creation and service stop, cleanup/archive/shutdown keep
  running after `[8/8]`. `Invoke-AutoShutdown` now returns a symbolic
  final state — `Scheduled`/`Cancelled`/`Failed` — instead of a plain
  boolean, so the console line reflects what actually happened
  (including the operator interactively cancelling an already-scheduled
  shutdown) rather than only "the command was issued." The interactive
  confirm/cancel dialog and the shutdown command itself are untouched.
- `План операцій:` gained `Очистка старих даних/логів` (always `ТАК` —
  the check runs unconditionally every invocation, there is no on/off
  flag for it; a run with nothing stale still renders `SKIPPED` on the
  operation itself).
- Exact failure attribution: `$script:currentMaintenanceOperation` is set
  before Range ID / cleanup / archive / auto-shutdown / final-report, so
  the dev.15 fail-safe catch now logs "Помилка операції ...<operation
  name>..." instead of the generic "Range ID/очистка/BRAVO_ARCHIV/
  AutoShutdown/фінальний звіт" list. If the exception happened inside an
  operation that has its own result line and that line never printed, the
  catch prints its `FAIL` exactly once (a `*Reported` flag per operation
  prevents a double print).
- The `RunMissedRestoreOnly`-with-nothing-pending recovery path no longer
  exits with a bare `exit 0` and no summary at all: it now prints a
  compact `BRAVO MAINTENANCE — УСПІШНО` / `Код завершення` / `Результат`
  / `Журнал` summary first (still no `[1/8]`..`[8/8]` — there is no real
  work this run) before the same outer `finally` → `Wait-BRAVOManualExit`
  as every other exit path.
- Tests: 21 new checks (plan wiring/order, each operation's unnumbered
  render and SKIPPED/OK/WARN/FAIL branches, step-total/counter isolation,
  render ordering after `[8/8]` and before the final summary, exact
  failure attribution, single-print-on-failure, and the recovery no-op
  summary) — all via source/AST inspection or direct calls to the real,
  side-effect-free `Write-BRAVOOperationResult`, never by running the
  real `Main()` or the real `Invoke-AutoShutdown` (which would issue an
  actual `shutdown` command). Two pre-existing dev.15 tests
  (`Maintenance/FinalSummaryOccursBeforeManualPause`,
  `Maintenance/FinalSummaryContainsOnlyApprovedFields`) had their source
  search bounded to start after the outer-try marker, since
  `Write-BRAVOFinalSummaryHeader`/`Footer` now also appear once, earlier,
  in the new recovery-path summary — both still pass unchanged.

**Archive/Health operator-visibility pass** (still dev.16, unpublished):
extends the same numbered-step/unnumbered-operation contract to
`BRAVO_ARCHIV.ps1` and `BRAVO_HEALTH.ps1` so real top-level operations
and checks stop being LOG-only. No backup format, retention period,
MANIFESTS lifecycle, SFTP/SMB protocol, notification routing, or
exit-code semantics change.

- `Write-BRAVOPlan` (new, `BRAVO.Console`): shared `План операцій:`/
  `План перевірок:` renderer for Archive and Health, matching the
  Maintenance plan layout/style (Maintenance itself keeps its own
  existing render, untouched) — both now render through it instead of
  their own raw `Write-Host` — Health has none at all (`Console/
  HealthRendersNoRawWriteHost`).
- Archive: `План операцій:` now reflects the same effective flags that
  drive the dynamic step `Total` (BAZA_APP/BAZA_WWW local sync,
  per-archive components, SFTP/SMB transfers, log/retention cleanup,
  post-backup Health). Local BAZA_APP/BAZA_WWW synchronization each get
  their own numbered step when enabled. `Перевірка шляхів` now renders
  strictly after both the path-existence checks and the SYSTEM write/
  read access preflight complete — previously it rendered `OK` right
  after the existence checks, before the preflight could still cancel
  the run. Old-log cleanup (`Remove-OldLogsByAge`) and backup-generation
  retention cleanup (`Remove-BRAVOExpiredBackupGenerations` +
  `Remove-OldLunchArchives`, aggregated into one operation, not one row
  per internal filter) both now print `Write-BRAVOOperationResult` lines;
  retention renders `OK` with a factual delete-count aggregate only when
  something was actually removed, `SKIPPED` otherwise — no invented
  counts. `-SyncBAZA` (a separate, SFTP-only manual-sync flow) is
  confirmed isolated: its own `Initialize-BRAVOArchiveSteps`/steps run
  and `return` before the new Plan/Total code path.
- Health: standalone runs (not embedded in Archive) now show a `План
  перевірок:` before the first check. The combined `BAZA (локальна
  копія)` and `SFTP` steps are split into independent dynamic steps —
  `BAZA_APP (локальна копія)`/`BAZA_WWW (локальна копія)` and `SFTP:
  резервні копії`/`SFTP: BAZA_APP`/`SFTP: BAZA_WWW` — each gated by its
  own enable flag and counted in `Total` exactly once;
  `Get-SFTPHealthIssues` still runs a single WinSCP session per call, its
  already-returned issue list is partitioned by the existing `Component`
  field, and a shared connection-prerequisite failure attaches to every
  enabled SFTP step (logged once, not once per step). `Керовані
  служби`/`Локальні резервні копії` stay single steps but gain a compact
  `служби: ...`/`компоненти: ...` detail line built from the issues'
  existing `Location`/`Component` fields. Dynamic `Total` is now the
  literal sum of the flags gating each step render
  (`Health/StepTotalMatchesVisibleEnabledChecks`); the
  `Complete-BRAVOHealthResult` notification off-by-one invariant, the
  embedded (`-SuppressHeader`) path, and `$script:BRAVOHealthSftpStepEnabled`
  (still consumed by the standalone summary footer) are all unchanged.
- Fixed a real bug introduced while adding the retention-cleanup delete
  counters: `[ref]`-typed parameters permanently type-constrain the
  variable for the rest of the function in PowerShell, so a same-named
  (case-insensitively) local counter silently gets re-wrapped into a new
  `PSReference` on every assignment instead of staying a plain `int`.
  `Remove-OldLunchArchives`'s pre-existing `$deletedCount` collided with
  the first draft of its new `[ref]$DeletedCount` output parameter,
  which would have made `$deletedCount += 2` throw and every real,
  successful lunch-archive deletion register as a caught failure.
  Renamed both new output parameters (`RemovedGenerationCount`/
  `RemovedFileCount`) to avoid any case-insensitive collision; verified
  with an isolated repro before and after.
- Maintenance: renamed a `Main`-scope variable that duplicated
  `Remove-OldRestoreArchives`'s own local `$groupsToDelete` under a
  different, unrelated computation (candidate count for console
  `Details` only, not the function's validity-aware retention decision)
  to `$restoreArchiveDeleteCandidateGroups`, to remove the confusing
  same-name/different-scope pattern. `Invoke-AutoShutdown` confirmed to
  have exactly one production call site (AST-counted).
- Tests: ~30 new checks across Archive, Health, and Maintenance (Plan
  reflects effective components, BAZA local/SFTP independent steps,
  path-step ordering, log/retention cleanup SKIPPED-vs-OK, `-SyncBAZA`
  isolation, embedded Health stays one step, Health dynamic-Total exact
  match, embedded Health suppresses Plan/summary, AutoShutdown
  Scheduled/Cancelled/Failed rendering and single-call-site, cleanup
  scope isolation). Full suite: 674/674.

## 5.0.0-dev.15 — 2026-08-10

Stabilizes the `BRAVO_MAINTENANCE.ps1` operator console step contract
introduced in dev.14 and makes end-of-run finalization resilient to a late
exception. No change to archive contents, 7-Zip, SHA512, VSS, SFTP/SMB
paths, credentials, notification routing, Health thresholds, backup-age
logic, or the exit-code formula.

- **Stable 8-step contract.** `Initialize-BRAVOMaintenanceSteps` now takes a
  literal `-Total 8`, never a computed expression. The approved operator
  contract is exactly `[1/8]` Перевірка вільного місця, `[2/8]` Створення
  необхідних директорій, `[3/8]` Зупинка служб, `[4/8]` Перевірка розмірів
  `.md`, `[5/8]` Реставрація моделі, `[6/8]` Обробка trace і логів, `[7/8]`
  Відновлення стану служб, `[8/8]` Контроль діапазонів ID — all eight always
  render, in this fixed order, on every run; a disabled/not-scheduled step
  renders `SKIPPED` on its own permanent number instead of shifting the
  numbering of the steps after it.
- Legacy log-structure migration, old-data cleanup, and the `BRAVO_ARCHIV.ps1`
  launch are confirmed non-numbered: each stays a detailed-LOG-only /
  Плану-операцій-visible operation and no longer calls
  `Write-BRAVOMaintenanceStep`, so it can never inflate the step count past 8.
- Fixed an ordering defect where, whenever a restore was not scheduled for
  the run (the common daily case), `[6/8]` Обробка trace і логів rendered
  *before* the `[5/8]` Реставрація моделі `SKIPPED` line, swapping the two
  numbers relative to the approved contract. The restore fallback now always
  renders first, regardless of scenario.
- **Fail-safe end-of-run finalization.** The Range ID / cleanup /
  `BRAVO_ARCHIV` / auto-shutdown / final-report block now runs inside a
  `try/catch`: any unhandled exception there is caught, still marks the run
  critical, and execution still reaches exit-code calculation and the final
  `BRAVO MAINTENANCE — <СТАТУС>` summary, instead of jumping straight past it
  to `Wait-BRAVOManualExit` with no summary printed at all. Inside the catch,
  `criticalErrorOccurred` is set unconditionally first, and the diagnostic
  logging/notification calls are each wrapped in their own isolated,
  non-rethrowing `try/catch` (each catch body explicitly discards the
  caught error via `$null = $_` — no `Write-Log`/`Send-SlackAlert`/`throw`/
  `exit`/`return` inside it) so a failure writing the log or sending the
  Slack alert cannot itself swallow the summary.
- `Write-Log` gained an opt-in `-NoConsole` switch (log file and
  notifications unaffected; no existing call site's behavior changes).
  `Test-RangeIdUsage` uses it for the three warnings that are already shown
  to the operator via the `[8/8]` step's `-Details`, so a missing/unreadable/
  over-threshold `range_id_log.json` no longer prints twice. A missing file
  now reports a two-line detail (label, then path) instead of one long line.
- The `План операцій:` block now closes with the same `=`-separator
  (`Write-BRAVOHeaderSeparator`, new in `BRAVO.Console`) that frames the run
  header, instead of the `-`-separator used by the unrelated `РЕЗУЛЬТАТ`
  block style.
- Tests: 15 new regression checks covering the fixed 8-step total (AST-level,
  rejects a dynamic `-Total`), each disabled step's `SKIPPED` render, the
  Restore/Logs step order, the fail-safe catch path (including simulated
  logging/notification failure inside it), the Range ID single-console-render
  and multiline-detail behavior, and the plan separator style — all via
  isolated source/AST extraction, never by running the real
  `BRAVO_MAINTENANCE.ps1` `Main()`.

## 5.0.0-dev.14 — 2026-08-09

Minimal structural/metadata change on top of dev.13: backup generation
manifests (`BRAVO_BACKUP_<GenerationId>.json`) now live in a dedicated
`<BackupRoot>\MANIFESTS\` storage location, separate from operational logs
(`LOGS\`) and disposable runtime data (`TEMP\`). No change to archive
contents, 7-Zip, SHA512, VSS, SFTP/SMB, credentials, notifications, Health
thresholds, backup-age logic, exit-code semantics, or the dev.13 elevation
contract.

- `modules\BRAVO.ArchiveHelpers`: three new centralized helpers —
  `Get-BRAVOBackupManifestRoot` (single source of truth for the physical
  path, `<BackupRoot>\MANIFESTS`), `Get-BRAVOBackupGenerationManifestFiles`
  (MANIFESTS-first reader with a non-recursive legacy-root fallback, dedup
  by GenerationId with MANIFESTS priority), and
  `Initialize-BRAVOBackupManifestStorage` (idempotent, non-recursive
  migration of legacy root manifests into `MANIFESTS\`: identical files are
  deduplicated by SHA256, conflicting files are never overwritten or
  deleted — both are preserved and a WARNING names the GenerationId).
- `Write-BRAVOBackupGenerationManifest` (`BRAVO.Archive.Runtime.ps1`) now
  writes new manifests directly into `MANIFESTS\`, creating the directory
  on first use.
- `Remove-BRAVOExpiredBackupGenerations` (retention), `Get-BackupHealthIssues`
  (`BRAVO_HEALTH.ps1`) and `Get-BRAVORestoreGenerationManifest`
  (`BRAVO_RESTORE_TEST.ps1`) all now discover manifests through the
  centralized reader instead of independently duplicating the same
  `Get-BRAVOFiles -Filter 'BRAVO_BACKUP_*.json'` call. `BRAVO_HEALTH.ps1`
  stays strictly read-only — it never migrates or writes.
- `BRAVO_MAINTENANCE.ps1` runs the migration once per invocation, under the
  same operation lock as the existing legacy-log-structure migration, and
  never fails the run: a migration error or conflict is logged as a
  WARNING only.
- `Get-BRAVOBackupGenerationManifestPhysicalFiles` (new): retention now
  deletes *every* physical copy of a generation's manifest (`MANIFESTS\`
  and, if still unmigrated, the legacy `BackupRoot` root) when that
  generation is expired, instead of only the one copy the MANIFESTS-first
  reader picked for the deletion decision. Previously a conflicting legacy
  duplicate could survive a generation's deletion and "resurrect" its
  metadata on the next run through the reader's legacy fallback. The new
  helper resolves candidates by filename match against real, already-
  enumerated files — it never builds a filesystem path from the untrusted
  `generationId` string read out of manifest JSON, so a crafted
  `generationId` cannot be used for path traversal.
- `BRAVO_MAINTENANCE.ps1` operator console UX: adopts the same
  `[N/TOTAL] Назва... STATUS mm:ss` step contract as Archive/Health, with
  a Maintenance-specific `OK`/`WARN`/`FAIL`/`SKIPPED` vocabulary (renamed
  from `OK`/`WARNING`/`ERROR`/`SKIPPED`, console-display only — log levels
  and exit-code semantics are unchanged). MANIFESTS init/migration is now
  folded into the existing "Створення необхідних директорій" step's detail
  instead of its own line, so a steady-state run shows nothing new.
  "Контроль діапазонів ID" gets its own step for the first time (it
  previously ran silently, log/Slack only); a missing or unreadable
  `range_id_log.json` shows as `WARN` on the console — the existing
  `Send-SlackAlert -IsCritical`/exit-code behavior for that condition is
  unchanged. The plan-preview line for the restore step is renamed
  "Реставрація моделі" to match the step's actual name (previously
  "Відновлення пропущених операцій", same underlying flag), and a
  "Контроль діапазонів ID" line was added so the plan can't diverge from
  what actually runs. The final `РЕЗУЛЬТАТ` block gains Початок/Завершення
  and a Кроків/Успішно/Попереджень/Пропущено/Помилок breakdown, mirroring
  `BRAVO_HEALTH.ps1`'s existing summary counters.
- Regression tests: 18 `ManifestStorage/*` checks covering root
  resolution, writer placement, reader priority/fallback/non-recursion,
  and migration; 2 more (`RetentionDeletesBothPhysicalManifestCopies`,
  `DeletedGenerationCannotReappearViaLegacyFallback`) covering the
  retention cleanup fix; 23 new `Maintenance/*` checks covering the header,
  plan wiring, step format/vocabulary/duration, the folded-in directory/
  MANIFESTS step, the Range ID step, and the final summary — all via
  isolated function extraction or static source checks, never by running
  the real `BRAVO_MAINTENANCE.ps1` `Main()`.
- Docs: README.md §2/§12 and OPERATIONS.md document the three-part storage
  split and the upgrade/migration behavior operators will see in the
  Maintenance log.

Correctness/UX follow-up (round 3):
- `Get-BRAVOBackupManifestFilenameGenerationId` (new): retention now
  requires the generationId encoded in a manifest's physical filename to
  match the generationId inside its JSON content before trusting that
  manifest for any deletion decision. A mismatch (corruption or tampering)
  excludes the record from retention entirely -- it can no longer cause
  deletion of its own artifacts or, via the round-2 physical-cleanup fix,
  of an unrelated generation's metadata that the JSON happened to name.
- `Get-BRAVOMaintenanceExecutionMode` (new, pure: takes only a SID):
  the Maintenance header's MANUAL/SCHEDULED mode no longer depends on
  `-NoPause` (a UX-only switch an operator can pass manually). It now
  reflects the actual caller: SYSTEM (S-1-5-18) is SCHEDULED, anyone else
  is MANUAL.
- Plan preview: restored `Відновлення пропущених операцій` (state of the
  missed-operation-recovery mechanism: `-RunMissedRestoreOnly` and actual
  missed work) as its own line, distinct from `Реставрація моделі` (will
  the model-restore step actually run this invocation). The two had been
  collapsed into one line; removed the Range ID line from the plan (the
  step itself is unaffected).
- Range ID: a missing/unreadable `range_id_log.json` no longer makes the
  whole Maintenance run `MaintenanceFailed`. `Send-SlackAlert -IsCritical`
  still fires (notification delivery in `errors_only` mode is unchanged);
  only its `criticalErrorOccurred` side effect is reverted for this one
  call, and only when nothing else had already set it.
- Migration step status mapping corrected: a manifest-migration conflict
  or error now maps to `WARN` (matching the non-fatal/retryable contract
  from round 1), not `FAIL`. `FAIL` is reserved for a real directory-
  creation failure.
- Step details (`Write-BRAVOMaintenanceStep`) no longer prefix WARN/FAIL
  text with "Причина:" -- every status (OK/WARN/FAIL/SKIPPED) now renders
  through the same plain, 6-space-indented `Write-BRAVOConsoleDetail`.
- `Write-BRAVOFinalSummaryHeader` (new, `BRAVO.Console`): Maintenance's
  final summary now opens with "BRAVO MAINTENANCE — <СТАТУС>" under the
  same `=`-separator style as the run's own header, instead of the
  generic " РЕЗУЛЬТАТ" block. Archive/Health/other callers keep using
  `Write-BRAVOResultHeader` unchanged. The summary's "Попереджень" field
  is reported exactly once (the step-level tally, matching Health's
  existing counter convention), not duplicated against the separate
  global warning count.
- 26 more regression tests: execution-mode (3), plan semantics (1), Range
  ID severity decoupling (3), retention filename/JSON identity (3), and
  7 "exact render" checks (header/plan/step/Range-ID-warning/summary x3)
  that assert actual rendered layout -- separators, label alignment,
  status vocabulary, absence of "Причина:", no duplicated "Попереджень"
  -- not just source-text presence.

Final polish (round 4):
- `Write-BRAVOFinalSummaryFooter` (new, `BRAVO.Console`, pairs with
  `Write-BRAVOFinalSummaryHeader`): Maintenance's summary now closes with
  "Журнал:" + the log path on its own line + a closing `=`-separator,
  matching the run header's style, instead of `Write-BRAVOResultFooter`'s
  "Детальний журнал:" + `-`-separator. Archive/Health keep
  `Write-BRAVOResultFooter` unchanged.
- The folded-in "Створення необхідних директорій" step (directory
  creation + MANIFESTS init/migration) now renders multiple detail facts
  as separate 6-space-indented lines, not joined with `; `.
- 1 more regression test (`Maintenance/DirectoryDetailsRenderAsSeparateLines`);
  the three summary-render tests now also assert the footer layout
  (`Журнал:` exactly once, log path on the next line, closing separator,
  absence of `Детальний журнал:`/`-`-separator).

Compact summary trim (round 5):
- The `Maintenance`/`Архівація`/`Shutdown` fields are no longer printed in
  the final compact operator summary -- they weren't part of the approved
  field set (Статус/Код завершення/Початок/Завершення/Тривалість/Кроків/
  Успішно/Попереджень/Пропущено/Помилок/Журнал) and duplicated what the
  "План операцій" block already shows at the start of the run.
- 1 more regression test (`Maintenance/FinalSummaryContainsOnlyApprovedFields`)
  reads the real final-summary source block in `BRAVO.Maintenance.Runtime.ps1`
  and asserts it contains exactly the approved fields and neither the
  removed ones nor the old `Write-BRAVOResultFooter`/"Детальний журнал"/
  " РЕЗУЛЬТАТ" contract.

## 5.0.0-dev.13 — 2026-08-09

Minimal reliability fix on top of the dev.12 UX fixes: manual `BRAVO_HEALTH.ps1`
runs without administrator rights no longer misreport a local permission
failure as an SFTP outage.

- `BRAVO_HEALTH.ps1` now detects elevation state (Administrator/SYSTEM/
  Standard) before doing any work. A manual interactive run without
  elevation self-relaunches through `Start-Process -Verb RunAs` (UAC),
  propagating the real `$PSBoundParameters` (ConfigPath, NoPause,
  NotifyOnSuccess, NoSlack, ForceNotification, SkipIfBackupTaskRunning) as a
  deterministically built, correctly quoted argument list, then exits with
  the elevated child's exit code. SYSTEM (scheduled task) and an
  already-elevated console are unaffected — no relaunch, no UAC, same
  behavior as dev.12. A cancelled UAC prompt prints a clear message instead
  of a raw stack trace.
- Non-interactive detection no longer relies solely on
  `[Environment]::UserInteractive`/`[Console]::IsInputRedirected` (neither
  actually proves PowerShell received `-NonInteractive`). The entrypoint now
  additionally reads its own process argv via the built-in .NET Framework
  API `[Environment]::GetCommandLineArgs()` — already parsed, Windows
  PowerShell 5.1-compatible, and, importantly, has no CIM/WMI dependency at
  all — and does an exact (not substring/`-like`) match for a standalone
  `-NonInteractive` element, so it does not false-match text inside
  `-ConfigPath`'s value or a file path. An explicit `-NonInteractive`
  overrides an otherwise-interactive-looking session and fails fast (exit
  36) without ever attempting UAC.
- `BRAVO.Health.Runtime.ps1` now probes write access to the runtime LOGS and
  TEMP roots before any real health check (services/local backups/SFTP/SMB).
  Previously a local `AccessDenied` on those paths only surfaced deep inside
  the SFTP stage's temporary-directory creation and was misclassified as
  `ERROR SFTP` / `SftpVerified=False`. On a preflight failure, none of the
  real checks run, and the operator sees an honest environment/privilege
  message (never "SFTP недоступний"), sent as a notification if configured.
  The failure is classified: only `UnauthorizedAccessException` (anywhere in
  the exception chain) is treated as a privilege problem; other I/O failures
  (disk full, `PathTooLong`, a broken filesystem, ...) are reported as a
  generic environment problem and do not tell the operator to run as
  administrator. This holds even when the runtime TEMP directory does not
  exist yet: the typed exception from a failed directory creation is now
  preserved end to end (as an `InnerException`) instead of being flattened
  to plain text before classification.
- New exit codes in `modules\BRAVO.ExitCodes`, documented in README.md's
  exit-code tables: `36 = PrivilegeRequired` for the privilege case above
  (also used by the entrypoint's UAC-cancel/non-interactive-fail-fast
  paths), and `37 = EnvironmentUnavailable` for the non-privilege
  environment/I/O case. `70 = HealthCritical` keeps its existing meaning —
  a real health-check failure that actually ran.
- If the health-check log itself could not be created/written, the
  environment notification and the console summary no longer claim a log
  path that does not exist.
- `Write-HealthLog` no longer floods the console with the same "не вдалося
  записати health-check лог" warning on every one of the dozens of calls in
  a run once the log file has become unwritable — it now warns once and
  stops retrying the write for the rest of that run.
- ACL of the runtime root is not weakened anywhere by this change — the fix
  is elevation on demand, not broader write access for regular users.
- `BRAVO_ARCHIV.ps1`/`BRAVO_MAINTENANCE.ps1` already had their own, simpler
  SYSTEM/Administrator self-elevation (predating this change) and were not
  touched here. Unlike the new Health gate, neither distinguishes
  interactive from non-interactive before attempting `-Verb RunAs`, and
  Maintenance has no dedicated handling for a cancelled UAC prompt — noted
  as a possible follow-up, not fixed here.

## 5.0.0-dev.12 — 2026-08-09

Minimal UX fix on top of the dev.11 operator notification unification.

- Component/destination status rows (BLOG/BRAVOEXCH/MODEL, Local, SFTP,
  BAZA_APP/BAZA_WWW, SMB) are now status-first (`✅ 📦 NAME — detail`) via the
  new shared `Format-BRAVOOperatorStatusLine` helper, instead of padding the
  component name with fixed spaces before the status icon. Discord and Slack
  render with a proportional font, so space-padding never aligned and broke
  differently depending on component name length.
- `BRAVO_DRY_RUN.ps1 -SendTestNotification` now converts the Discord test
  message through the same `ConvertTo-DiscordNotificationText` contract as
  Archive/Health/Maintenance, instead of sending raw `:emoji:` tokens to the
  Discord webhook. Slack is unaffected — Slack resolves `:shortcode:` natively.
- No changes to PASS/WARN/FAIL business logic, archive/VSS/retention/SFTP
  semantics, exit codes, or NotificationMode behavior.

## 5.0.0-dev.11 — 2026-08-09

Operator notification UX is unified across Slack and Discord.

- Added shared `BRAVO.Notifications` presentation helpers for severity headers,
  institution/host/public-IP blocks, version/build lines, log references,
  durations and Ukrainian file-count pluralization.
- Health success notifications now use `Остання резервна копія`, omit full
  archive filenames, and show compact component/destination status. Health
  warning/error notifications use `Остання успішна резервна копія` and put the
  concrete action before server metadata.
- BAZA_APP/BAZA_WWW long-name warnings now explain that only problematic files
  were skipped, show UTF-8 byte actual/limit/overflow, and include at most
  three examples in Slack/Discord while keeping the full list in logs.
- Maintenance success notifications are compact, avoid ambiguous restore
  scheduling text, show only the minimum free-space disk in success, and show
  disk deficit details for low-space failures.
- Test/restore/security notifications now use the same operator envelope while
  preserving NotificationMode, Discord chunking and disabled mentions.

## 5.0.0-dev.2 — 2026-08-09

Виправлення, виявлені під час тестового розгортання 5.0.0-dev.1. Централізовано
effective-конфігурацію: Setup, Dry Run, Task Installer, Task Diagnose і
production runtime тепер користуються однаковими правилами.

- Перевірка облікового запису запланованих завдань — за SID
  (`Test-BRAVOAccountIdentityEquivalent`), а не за текстом. Локалізована назва
  Task Scheduler ("СИСТЕМА") мовно-незалежно дорівнює `SYSTEM`/`S-1-5-18`, тому
  правильно встановлене завдання більше не отримує false FAIL і не валить Setup.
- `Test-BRAVOScheduledTaskDefinition` перевіряє визначення проти EFFECTIVE
  `schedulerSettings` (акаунт/LogonType/RunLevel через новий
  `Get-BRAVOExpectedSchedulerPrincipal`), а не проти хардкоду SYSTEM/5/Highest:
  прийняте Installer-ом визначення не оголошується invalid у Diagnose.
- Завершено розділення RuntimeRoot / ConfigRoot. Скрипти-завдання, Dry Run,
  модулі та ACL-hardening резолвяться з RuntimeRoot (каталог комплекту), а не з
  каталогу конфігурації; `-ConfigPath` лишається зовнішнім. RuntimeRoot більше
  не виводиться через `Split-Path $ConfigPath`.
- Новий канонічний `Get-BRAVOEffectiveSynchronizationConfiguration` (публікується
  як `$bazaSyncEffective`): чи потрібне BAZASync-завдання (`BAZA_APP_SFTP -or
  BAZA_WWW_SFTP`), які BAZA-джерела обов'язкові, які SFTP-каталоги потрібні.
  Валідна пара `BAZA_APP_SFTP=$false`/`BAZA_WWW_SFTP=$true` тепер вмикає
  заплановану синхронізацію; `BAZASync` визначено в `BRAVO.config`, тому Diagnose
  його більше не пропускає.
- Dry Run валідує джерело КОЖНОГО увімкненого BAZA-компонента (LOCAL і SFTP): без
  джерела — `FAIL` і ненульовий exit, а не `ГОТОВО ДО ЗАПУСКУ`. У `-TestAccess`
  Dry Run стат-ить кожен увімкнений SFTP-каталог призначення (`/baza_app`,
  `/baza_www`) через `FileExists`; відсутній — `FAIL` (каталоги не створюються).
- `BAZA_WWW_SFTP` за замовчуванням `$false` (узгоджено з коментарем і
  документацією): сервери без BRAVO Web більше не блокуються увімкненим прапорцем
  із невизначеним джерелом.
- Recovery (boot-тригер) показує «після наступного старту Windows (+затримка)»
  замість sentinel `30.12.1899`; `LastTaskResult` подається як історія
  виконання, окремо від валідації поточного визначення.
- Провенанс версії: `ci\Update-BRAVOVersionStamp.ps1` відхиляє stamp на брудній
  копії; self-test `Version/StampConsistency` перевіряє `buildId` як префікс
  `sourceCommit`; RELEASE_CHECKLIST документує «розгортати тег, а не проміжний
  коміт коду».

## 5.0.0-dev.1 — 2026-08-08

Generation-aware backup refactor. Compatibility changes are intentional:
Health/Restore now require a `COMPLETE` generation manifest, unsafe discovery
fallbacks are rejected, and writable machine state no longer lives under code.

- MODEL, BLOG and BRAVOEXCH are archived from one VSS Snapshot Set with one
  `GenerationId`. Same-volume sources share one shadow copy; multi-volume
  sources remain in the same set. VSS failure performs zero live archive work.
- Local publication is atomic and no-overwrite: `.work` -> 7-Zip create ->
  `7z t` -> SHA512 creation -> real SHA512 comparison -> final `.mdz` and
  sidecar. Existing valid backups and hashes are never removed first.
- `BRAVO_BACKUP_<GenerationId>.json` records snapshot, volume and component
  state, transfer results and Health result. Health evaluates the latest
  `COMPLETE` generation; Restore Test selects one generation automatically or
  through `-GenerationId`, so components from different runs cannot be mixed.
- Path architecture split into four independent roots: **RuntimeRoot**
  (complect + `Tools\` + version-controlled manifests + script logs
  `<RuntimeRoot>\LOGS`), **LIMSRoot**, **SystemLogRoot** and **BackupRoot**.
  `pathSettings.ArchiveRoot` is removed as a production concept.
  - `LIMSRoot=""` auto-discovers the canonical BRAVO service (Name +
    DisplayName); Disabled is a valid identity; missing or ambiguous services
    fail closed; explicit `LIMSRoot` always wins.
  - `SystemLogRoot=""` resolves to `<EffectiveLIMSRoot>\ARCHIV\LOGS`; an
    explicit value is used exactly. Trace/exchangAPI/BravoWeb live here.
  - `BackupRoot=""` resolves to `<EffectiveLIMSRoot>\ARCHIV`; an explicit value
    is used exactly. All three roots empty is the default all-AUTO layout, so
    the shipped `pathSettings` carries no machine-specific paths.
  - PowerShell script execution logs are always `<RuntimeRoot>\LOGS`
    (helpers: `<RuntimeRoot>\LOGS\HELPERS`), never a data root.
  - Machine state (`BRAVO_TASK_EXECUTION_STATE.json`,
    `BRAVO_ARCHIV_HEALTH_ALERT_STATE.json`, restore/version/VSS state) and the
    operation lock live under `%ProgramData%\BRAVO\{State,Locks}`.
  - Local backup destinations are `BackupRoot\{MODEL,BLOG,BRAVOEXCH,BAZA_APP,
    BAZA_WWW}` — the app copy is `BAZA_APP`, not `BAZA`.
  - Script-log, system-log and backup retention are three independent
    policies over three separate roots. Tools and manifests resolve from
    RuntimeRoot; effective ConfigPath is preserved through guard, loader,
    runtime and scheduled tasks. `BRAVO_CONFIG_TEST` / `BRAVO_DRY_RUN` /
    `BRAVO_TASKS_DIAGNOSE` report configured vs effective roots and probe them
    under SYSTEM.
- Canonical `bravo.ini` is `%SystemRoot%\SysWOW64\bravo.ini` on x64 and
  `%SystemRoot%\System32\bravo.ini` on x86. Missing service/INI/key now fails
  controlled; silent `LIMSRoot\Model`, `BLOG`, `bravoexch` and BRAVO_ROOT
  fallbacks were removed.
- Production and dry-run perform real SYSTEM source-read and
  create/write/read/delete probes. Archive and Maintenance share
  `C:\ProgramData\BRAVO\Locks\BRAVO_OPERATION.lock`; execution logs include
  seconds and PID.
- SFTP uses the actual configured endpoint, with no `google.com` prerequisite.
  Archive upload, BAZA_APP and BAZA_WWW have separate result objects, console
  steps and diagnostics; existing WinSCP post-sync comparison is preserved.
- Create, `7z t` integrity and SHA512 failures are distinct; SHA512 failure is
  exit code `42`. Windows Update freshness remains Health-only. A local
  `COMPLETE` generation stays complete when SFTP/SMB fails.
- Retention works by generation manifest, protects current and the minimum
  number of verified complete generations, and applies separate retention to
  incomplete/failed generations. Remote copies receive the generation manifest.
- Hard-termination VSS cleanup persists exact BRAVO-owned Shadow IDs in
  `C:\ProgramData\BRAVO\State\BRAVO_VSS_OWNERSHIP.json`; the next
  machine-wide lock owner removes only those IDs. Foreign/corrupt state and
  failed exact-ID deletion are retained and fail closed.
- Health now checks the same ProgramData operation lock used by Archive and
  Maintenance instead of the obsolete ArchiveRoot-relative marker.

## 4.5.0-dev.3 — 2026-08-08

CODE IS NOT DATA. Комплект, LIMS, операційні журнали й резервні копії стали
чотирма незалежними поняттями, а не наслідками фізичного розташування одне
одного. Разом із цим — фактична перевірка прав SYSTEM замість припущень.

- **`RuntimeRoot`, `LIMSRoot`, `ArchiveRoot`, `BackupRoot` розділені.**
  Раніше `LIMSRoot` обчислювався як «каталог на рівень вище комплекту», а
  `ArchiveRoot` — як «каталог самого комплекту». Це працювало лише тоді,
  коли комплект випадково лежав усередині LIMS. Для комплекту в `C:\BRAVO`
  ті самі формули давали `LIMSRoot = "C:\"` і `ArchiveRoot = "C:\BRAVO"` —
  тобто журнали писалися б у каталог із виконуваним кодом, а джерелом LIMS
  вважався б корінь системного диска.

  Тепер три корені задаються в `BRAVO.config` явно; порожнє, відносне або
  некоректне значення — помилка конфігурації з назвою параметра
  (`Resolve-BravoDataRoot`), а не мовчазний здогад. Значення проходять
  зняття лапок, `ExpandEnvironmentVariables` і нормалізацію, і не залежать
  ані від поточного каталогу процесу, ані від `$PSScriptRoot`, ані від
  каталогу, з якого Планувальник запустив завдання.

  `RuntimeRoot` передається в завантажувач окремим параметром, тому
  `-ConfigPath C:\BRAVO\CONFIGS\SERVER1.config` більше не змушує шукати
  `modules\` і `VERSION.json` поруч із конфігурацією.

- **`Tools\` переїхали до `RuntimeRoot`.** `7za.exe`, `WinSCP.com`,
  `WinSCP.exe`, `WinSCPnet.dll` — це виконувані залежності комплекту під
  захистом маніфесту, а не дані бекапу. Доти, доки вони лежали в
  `ArchiveRoot`, перенесення архівів на інший диск тягнуло за собою
  перенесення виконуваного коду, а `ArchiveRoot` доводилося захищати ACL
  так само суворо, як сам комплект. Заразом Maintenance перестав шукати
  архіватор власним `Join-Path $ARCHIVE_ROOT "Tools\7za.exe"`: тепер
  джерело те саме, що в Archive.

- **Effective ConfigPath використовується всюди.** `-ConfigPath` тепер
  розкривається, нормалізується й нормалізованим іде в перевірку
  перемикачів безпеки, завантажувач і дочірні скрипти. Раніше
  `Test-BRAVORuntimeSecuritySettings` завжди читав
  `$PSScriptRoot\BRAVO.config` — тобто запуск із власною конфігурацією
  проходив перевірку ЧУЖОГО файлу, а та, за якою скрипт реально працював,
  лишалася неперевіреною. Порядок бар'єрів збережено: перевірка цілісності
  комплекту (код 33) лишається найпершою.

- **Діагностика завдань покриває всі production-завдання, включно з
  BAZASync.** Він був єдиним, чия неправильна реєстрація виявлялася б лише
  з відсутності даних у хмарі. Для кожного завдання перевіряється фактично
  зареєстроване визначення: `SYSTEM` / `ServiceAccount` / `Highest`,
  `Action.Path` = налаштований `powershell.exe`, наявність `-NoProfile`,
  `-NonInteractive`, `-ExecutionPolicy Bypass`, правильні `-File` і
  `-ConfigPath`, `WorkingDirectory` = каталог скрипта, ненульовий
  `ExecutionTimeLimit`, а також task-специфічні перемикачі (`-NoPause`,
  `-RunMissedRestoreOnly`, `-SyncBAZA`, `-NotifyOnSuccess`).

- **SYSTEM preflight перевіряє права по-справжньому.** Замість `Test-Path`
  виконується повний probe: створити → записати відомі байти → прочитати
  назад → видалити. Наявність каталогу нічого не гарантує: ACL може
  дозволяти перелічення й забороняти запис саме для SYSTEM, і тоді ротація
  падає вже на production. Перевіряються читання `RuntimeRoot`,
  `ConfigPath`, `modules\`, `Tools\`, `LIMSRoot`, `bravo.ini` і запис
  `ArchiveRoot`, `BackupRoot`, `LOGS\` та всіх каталогів призначення
  ротації.

- **Буква підключеного мережевого диска більше не може бути
  production-залежністю.** `Z:\BRAVO` існує лише в інтерактивному сеансі
  користувача: під SYSTEM такий шлях працює вручну й мовчки зникає вночі.
  І діагностика завдань, і dry-run позначають це помилкою й рекомендують
  UNC `\\server\share\...`.

- **Свіжість оновлень Windows лишилась тільки в `BRAVO_HEALTH`.** Це
  health-метрика, а не умова виконання: в Archive, Maintenance, Recovery,
  Tasks Install/Uninstall і Credentials Setup вона лише додавала WARNING
  (а з ним ненульовий код завершення) до операції, на результат якої вік
  патчів не впливає. Перевірки платформи — ОС, build, PowerShell, .NET,
  архітектура, API — лишились на місці всюди.

- Закрито 10 сценаріями `Runtime/01…10` у `BRAVO_SELF_TEST.ps1`, зокрема
  probe запису на справжніх тимчасових каталогах. Жоден сценарій не керує
  реальними службами й не змінює production-дані.

## 4.5.0-dev.2 — 2026-08-08

Ротація, міграція, архівація та retention програмних журналів доведені до
production-grade рівня. Зміна функціональна: змінюються розкладка журналів
на диску, discovery джерел, семантика нумерації та політики зберігання —
саме тому версія пакета підвищена, а не залишена попередньою.

- **`bravo.ini` шукається рівно за одним шляхом, визначеним архітектурою
  ОС.** `%SystemRoot%\SysWOW64\bravo.ini` на x64, `%SystemRoot%\System32\bravo.ini`
  на x86 — і жодного fallback. Раніше, якщо системного файлу не було,
  Discovery читав `bravo.ini` поруч із `bravo.exe`. На машині, де є обидва,
  це означало тиху роботу за чужою конфігурацією: Maintenance ротував би
  trace, якого служба не пише. Тепер відсутність файлу — керована помилка з
  назвою перевіреного шляху.

- **Відносний `[Debug]/FILE` резолвиться від каталогу інсталяції BRAVO.**
  `FILE=TraceSRV.out` при `D:\LIMS-NEW\bravo.exe` означає
  `D:\LIMS-NEW\TraceSRV.out` — не поточний каталог процесу, не ArchiveRoot і
  не `SysWOW64`, де лежить сам `bravo.ini`. Trace поза каталогом інсталяції
  не блокується (шлях може вести на окремий диск свідомо), але позначається
  окремим WARNING: це розбіжність між конфігурацією й очікуванням, яку
  оператор має побачити в журналі, а не з'ясовувати під час інциденту.

- **`exchangAPI`: обидва історичні шаблони імен + обов'язкова
  дедуплікація.** Пошук іде і за `exchangAPI_*.log`, і за `exchangAPI*.log`:
  перший не ловить поточний `exchangAPI.log`, другий писався не на всіх
  розгортаннях. `exchangAPI_1.log` відповідає обом, тому після злиття
  результатів виконується дедуплікація за `FullName` — інакше той самий
  фізичний файл обробився б двічі.

- **Apache: тільки журнали.** Фільтр `*.log` замість «усі файли каталогу».
  `httpd.pid`, `*.lock` і тимчасові файли — службові: Apache очікує знайти
  їх на місці після старту, а не в архіві за вчорашню дату.

- **BRAVO Web application logs обходяться рекурсивно зі збереженням
  структури.** `www\log` має вкладені каталоги (`API\`, `Integration\API\`),
  і в різних гілках трапляються однакові імена. Сплющування в один
  каталог-дату злило б різні `request.log` в одну послідовність і знищило б
  контекст походження, тому відносний шлях зберігається, а нумерація
  рахується окремо для кожного відносного каталогу:
  `API\request_1.log` та `Integration\API\request_1.log` незалежні.

- **Автоматична міграція старої структури.** `<ArchiveRoot>\Trace`,
  `<ArchiveRoot>\exchangAPI` і `<ArchiveRoot>\Br-a-vo.web` переїжджають під
  `<ArchiveRoot>\LOGS\...`. Просто перестати туди писати було замало:
  накопичена історія залишилася б поза будь-яким retention і поза очима
  оператора. Міграція ідемпотентна й неруйнівна — джерело видаляється лише
  після підтвердженого переміщення (призначення існує, джерела немає,
  розмір збігся), часткова невдача лишає решту для наступного запуску, а
  перезапис призначення неможливий. Плоскі журнали старого формату
  отримують каталог-дату за власним `LastWriteTime` і проходять через той
  самий sequence engine, тобто одразу стають частиною нормального циклу.

- **`CompressedLogDays` — окрема політика зберігання `.mdz`.**
  `ArchiveDays` відповідає на питання «коли пакувати каталог-дату»,
  `CompressedLogDays` — «коли видаляти вже спакований архів». Змішувати їх
  не можна: перше вимірюється тижнями, друге — місяцями, і спільне число
  означало б або роздутий диск, або втрату історії. Вік архіву рахується за
  датою в його імені, а не за `LastWriteTime`: час файлу змінює будь-яке
  копіювання комплекту. Видаляються лише архіви очікуваного формату свого
  компонента — жодного узагальненого `*.mdz`.

- **Структурований результат переміщення.** `Move-BRAVOLogWithSequence`
  повертає `Status/SourcePath/DestinationPath/SourceSize/DestinationSize/
  Sequence/Attempts/Error` — те саме джерело і для журналу, і для підсумку,
  і для тестів. Агрегована статистика компонента розширена до
  `знайдено / непорожніх / переміщено / порожніх / пропущено / помилок`.

- **Порожній журнал лишається в джерелі** — не переміщується, не
  видаляється, не перейменовується і не займає номер у послідовності.
  Відсутній trace — діагностичне повідомлення, не помилка: BRAVO створює
  його лише під час першої debug-події. Після запуску служби в журнал
  додано інформаційний рядок про те, чи trace з'явився заново; на код
  завершення це не впливає.

- Закрито 27 сценаріями `LogRotation/01…27` у `BRAVO_SELF_TEST.ps1` — на
  справжніх файлах у тимчасовому каталозі. Жоден сценарій не керує
  реальними службами: усе, що стосується BRAVO/Apache/exchangAPI,
  перевіряється на синтетичних об'єктах служб і файлових фікстурах.

## 4.5.0-dev.1 — 2026-08-05

Перший development-реліз циклу `4.5.0`. Відкриває нову модель гілок і
версій, описану в `RELEASE_POLICY.md`.

- **Ротація програмних журналів переписана: детерміноване джерело,
  детермінована нумерація, жодного перезапису.** До цієї зміни кожен із
  чотирьох компонентів шукав свої журнали власною здогадкою, і кожен
  помилявся по-своєму.

  BRAVO Trace шукався як `*.out` у `LIMSRoot` — хоча точний шлях і назву
  задає сам BRAVO в `bravo.ini`, секція `[Debug]`, ключ `FILE`. Тепер це
  єдине джерело істини: `Resolve-BRAVOInstallationDiscovery` віддає
  `TRACE_FILE` (з trim, зняттям лапок, розкриттям `%ENV%` і перевіркою,
  що шлях абсолютний), а `BRAVO.config` цей параметр не дублює —
  конфігурація trace належить BRAVO, не Maintenance. Неможливість
  визначити `[Debug]/FILE` — помилка конфігурації з поіменно названими
  `bravo.ini`, `[Debug]` і `FILE`, а не мовчазний пропуск.

  `exchangAPI` шукався фільтром `exchangAPI_*.log` відносно `LIMSRoot` —
  тобто пропускав поточний `exchangAPI.log` (єдиний, що існує завжди) і
  дивився не туди, де служба насправді працює. Джерело — фактичний
  робочий каталог служби: `Win32_Service.PathName`, а для служб під NSSM
  — `AppDirectory`/`Application` з гілки `Parameters` (де `PathName`
  вказує на сам `nssm.exe`). Файли `exchangAPI.log`, `exchangAPI_1.log`,
  `exchangAPI_2.log` тепер належать одній логічній послідовності, тому
  `exchangAPI_1.log` стає `exchangAPI_3.log`, а не `exchangAPI_1_1.log`.

  Apache і BRAVO Web application logs розділені структурно: `apache\logs`
  і `www\log` більше не змішуються в один каталог-дату.

  Усі програмні журнали переїхали під `<ArchiveRoot>\LOGS`:
  `Trace\`, `exchangAPI\`, `BravoWeb\Apache\`, `BravoWeb\Application\` —
  замість трьох окремих каталогів у корені `ArchiveRoot`.

- **`Move-WithSequence`/`Move-ExchangAPILogs` замінені спільним
  механізмом.** Дві майже однакові копії циклу переміщення розійшлися в
  поведінці рівно там, де це коштує даних: `Move-ExchangAPILogs`
  переміщував файл під тим самим іменем з `-Force`, тобто мовчки
  перезаписував уже наявний журнал у призначенні, а `Move-WithSequence`
  нумерував як `_000001` і після невдалої архівації повертався до вже
  використаних номерів.

  Тепер один `Move-BRAVOLogWithSequence`: номер — `MAX(наявних) + 1` у
  межах каталогу-дати (пропуски не перевикористовуються), ім'я
  підбирається безпосередньо перед кожною спробою (файл міг з'явитися між
  обчисленням і `Move`), `-Force` немає взагалі, а після переміщення
  звіряються три факти одночасно: джерела немає, призначення існує,
  розмір збігся з вихідним. Порожній файл не переміщується і не є
  помилкою. Кожен компонент завершується агрегованим рядком
  `знайдено / переміщено / порожніх / помилок`, а успішне переміщення
  показує обидва імені (`exchangAPI_2.log -> exchangAPI_6.log`).

- **Джерела журналів визначаються ДО зупинки служб.** Окремий блок
  `=== ДЖЕРЕЛА ЖУРНАЛІВ ===` друкує `bravo.ini`, `[Debug]/FILE`, робочий
  каталог `exchangAPI` і всі чотири каталоги призначення ще до того, як
  BRAVO зупинено: з'ясовувати «а звідки взагалі брати trace» під час
  простою служби — найдорожчий момент для цього питання. Журнали кожного
  компонента переміщуються лише після фактичного `Stopped` його служби.

- **Retention програмних журналів відокремлено від службового.**
  `Process-OldData` тепер викликається для кожної гілки окремо
  (`Trace`/`exchangAPI`/`Apache`/`BravoWeb`), каталог-дата видаляється
  лише після коду `0` і успішного `7z t`, а `Remove-OldLogFiles`
  лишається нерекурсивним whitelist-очищенням виключно верхнього рівня
  `LOGS\`. Заразом прибрано мертвий виклик `Remove-OldLogFiles` для
  каталогу `exchangAPI`: його whitelist ніколи не містив `exchangAPI_*.log`,
  тому старі журнали exchangAPI не видалялися взагалі.

- **Виправлено рядок етапу «Обробка trace і логів».** Він друкувався
  всередині блоку BRAVO Web, тому на інсталяції без Apache щоразу
  показував `SKIPPED — службу BRAVO не було зупинено`, хоча trace і
  exchangAPI щойно оброблені успішно.

- Закрито 21 сценарієм `LogRotation/01…21` у `BRAVO_SELF_TEST.ps1` —
  на справжніх файлах у тимчасовому каталозі, а не текстовим пошуком:
  нумерація, стабільний порядок джерела, незалежні послідовності для
  кожного `BaseName`, збереження наявного файлу призначення, звірка
  розміру після `Move`, NSSM-каталог і fallback.

- **`RELEASE_POLICY.md`.** Що дозволено випускати з кожної гілки:
  `developer` — лише `X.Y.Z-dev.N` / `X.Y.Z-rc.N`, `master` — лише
  `X.Y.Z`; гілки ніколи не несуть однакової версії; stable виникає лише
  promotion перевіреного RC, без нових функцій. Чек-лист відповідає на
  питання «що зробити перед випуском», політика — «що взагалі дозволено
  випускати звідси».

- **`releaseChannel` повернувся у `VERSION.json`.** AUD-016 колись
  вивів його з `.git/HEAD`, бо ручна синхронізація між гілками двічі
  підвела на fast-forward merge. Але розгорнутий на сервері комплект
  приходить ZIP-ом, копіюванням, SFTP або SMB — `.git` там немає взагалі,
  і канал нізвідки взяти. Причину AUD-016 усунуто інакше: гілки більше
  не можуть містити однакову версію, тому fast-forward між ними
  неможливий, а замість людської дисципліни працює механічний gate.

  `Resolve-BRAVOReleaseChannelFromGit` лишилась — уже не як джерело
  значення, а як перехресна перевірка (`ReleaseChannelMatchesGit`).

- **`ci\Test-BRAVOReleasePolicy.ps1` + крок CI.** Stable-версія на
  `developer` або `-dev`/`-rc` на `master` тепер валить CI, а не їде на
  сервер непоміченою. Перевіряє також `ModuleVersion`, наявність версії
  в `CHANGELOG.md` і заголовки `README.md` / `BRAVO_SETUP.md`. У Pull
  Request гілка береться з цільової (`GITHUB_BASE_REF`): promotion
  `developer` → `master` несе вже stable-версію і має перевірятись
  правилами `master`.

- **`ModuleVersion` = базова частина версії.** `ModuleVersion` це
  `[System.Version]` — prerelease-суфікса він не приймає, а
  `New-ModuleManifest` у Windows PowerShell 5.1 не має `-Prerelease`
  (перевірено на цільовій платформі). Тому маніфести модулів несуть
  `4.5.0`, а повна версія пакета (`4.5.0-dev.1`) завжди береться з
  `VERSION.json`.

- Закрито тестами `Version/DeveloperBranchCarriesPrereleaseVersion`,
  `Version/ReleaseChannelStoredInPackage`, `Version/ModuleManifests`,
  `Documentation/ReleasePolicyExists`,
  `Documentation/ReleasePolicyCoversVersionModel`,
  `ReleasePolicy/CiGateEnforcesBranchVersionChannel`.

- **Ручний запуск не через Планувальник тепер чекає на клавішу — в усіх
  трьох runtime, а не лише в Archive.** `BRAVO_ARCHIV.ps1` уже мав робочу
  паузу (`RawUI.ReadKey` з фолбеком на `Read-Host` для ISE);
  `BRAVO_HEALTH.ps1` приймав `-NoPause`, але ніде його не використовував
  — Health ніколи не чекав; `BRAVO_MAINTENANCE.ps1` не мав ні параметра,
  ні паузи взагалі. Обидва тепер працюють так само, як Archive.

  Спільна реалізація — `Wait-BRAVOManualExit` (`BRAVO.Console`) — не
  спрацьовує без явного дозволу: `-NoPause`, вимкнений `PauseOnExit` у
  `BRAVO.config`, `[Environment]::UserInteractive = $false` (сесія 0,
  де й виконуються SYSTEM-завдання) чи перенаправлений stdin — кожна з
  цих причин самостійно скасовує очікування. Для 6 ранніх `exit`
  guard-блоку (до `Import-Module`, коли жоден модуль BRAVO ще не
  довірений) — самодостатній інлайн-варіант без залежності від модулів,
  за тим самим принципом, що й сам guard.

  `Maintenance.Runtime.ps1` має майже 30 точок `exit`, розкиданих по
  всьому файлу. Замість редагування кожної — один зовнішній
  `try/finally`: `exit` усередині `try` гарантовано проходить крізь усі
  `finally` на своєму шляху, перш ніж процес завершиться (властивість
  PowerShell, перевірено емпірично, включно з вкладеними
  `try/catch/finally`), тому один `finally` на весь файл охоплює їх усі.

  Попутно знайдено й закрито реальну прогалину: `BRAVO_TASKS_INSTALL.ps1`
  додавав `-NoPause` вибірково за типом завдання — `Recovery` і
  `Maintenance` (нічний, найризикованіший) його не отримували взагалі.
  Не мало наслідків, доки в цих runtime не було паузи; після цієї зміни
  було б реальним ризиком зависання нічної автоматизації. Тепер
  `-NoPause` додається безумовно для кожного типу.

- Закрито тестами `Console/WaitManualExitChecksNoPauseFirst`,
  `Console/WaitManualExitNoPauseReturnsImmediately`,
  `Console/EarlyGuardExitsPauseBeforeClosing`,
  `Console/HealthPausesOnEveryExitPath`,
  `Console/MaintenancePausesOnEveryExitPath`,
  `Console/MaintenanceAcceptsNoPauseParameter`,
  `Console/EntrypointsForwardNoPauseToRuntime`,
  `Scheduler/EveryTaskTypeGetsNoPauseUnconditionally`.

- **Discovery: уточнене джерело істини для служби BRAVO — за прямою
  вказівкою користувача.** Три виправлення:

  1. **Ідентифікація служби BRAVO** — тепер Service name ТА Display name
     одночасно (`"BRAVO"` і `"BRAVO Service"`), а не будь-яке з них
     окремо. Сторонній сервіс із випадково схожим ім'ям більше не
     проходить як BRAVO.

  2. **`bravo.ini` шукається в системному каталозі Windows**
     (`%SystemRoot%\SysWOW64` на 64-бітній ОС, `\System32` на 32-бітній),
     а не поруч із `bravo.exe`, як вважалось раніше. Причина —
     WOW64 File System Redirector: BRAVO 32-бітний, і коли він пише в
     "System32", 64-бітна Windows прозоро перенаправляє це в SysWOW64;
     64-бітний PowerShell (типово для запланованих завдань), звертаючись
     до "System32" напряму, бачить каталог без редиректу — і файлу там
     просто немає. Підтверджено буквально: на машині розробки він
     справді лежить у `SysWOW64`, і початкова версія тестів це
     випадково довела, підхопивши реальний файл замість фікстури.
     Старий шлях (поруч із `bravo.exe`) лишився вторинним fallback.

  3. **`BACKUP_ROOT`** — каталог збереження бекапів тепер визначається як
     підкаталог `ARCHIV` усередині шляху встановлення служби BRAVO, а не
     LIMSRoot-відносний шлях. `BRAVO.config` використовує це значення як
     дефолт `pathSettings.BackupRoot`, лише якщо адміністратор не змінив
     `BackupRoot` вручну — override ніколи не перезаписується мовчки,
     той самий принцип, що й для решти discovery-полів.

  Закрито тестами `Discovery/BravoServiceRequiresNameAndDisplayNameMatch`,
  `Discovery/SystemDirectoryIsPrimaryBravoIniSource`,
  `Discovery/Win32UsesSystem32NotSysWOW64`,
  `Discovery/FallsBackNextToExecutableWhenSystemIniMissing`,
  `Discovery/BackupRootDerivedFromBravoRoot`,
  `Discovery/BackupRootOverrideWins`,
  `Discovery/ConfigUsesStrictBravoIdentityAndBackupRoot`.

  (Поле переймено на `BACKUP_ROOT` уже в цьому циклі — `ARCHIV_ROOT`
  збігалося з уже наявним `pathSettings.ArchiveRoot`, геть іншим
  поняттям: каталогом самого скрипта, де лежать `Tools\`/`LOGS\`.)

- **`Tools\TOOLS_MANIFEST.json` — маніфест переїхав у той самий
  каталог, що й самі утиліти.** Раніше шукався поруч зі скриптом
  (`$archivPath\TOOLS_MANIFEST.json`), окремо від `Tools\`, де
  фактично лежать `7za.exe`/`WinSCP.*`. Тепер — `Tools\TOOLS_MANIFEST.json`,
  узгоджено з `TOOLS_INTEGRITY.json` (TOFU-базова лінія), який завжди
  був там. Оновлено всюди: `BRAVO.config`, fallback-значення в усіх
  трьох runtime, `ci\Update-BRAVOToolsManifest.ps1`,
  `ci\Update-BRAVORuntimeManifest.ps1` (сам маніфест теж
  version-controlled і входить у `RUNTIME_MANIFEST.json` — довелось
  оновити шлях і там, інакше він випав би з перевірки цілісності
  мовчки), `README.md`, `SECURITY.md`.

  Закрито тестами `ToolManifest/ManifestPathIsInsideToolsDirectory`,
  `ToolManifest/ManifestFileLivesInsideTools`.

- **`pathSettings.ArchiveRoot` дефолтився в обчислений здогад, а не в
  каталог самого скрипта — корінь того, чому маніфест "губився".**
  Раніше: `Join-Path (Split-Path -Parent $ConfigRoot) "ARCHIV"` —
  «піднятись на рівень вище й зайти в підкаталог, що зветься буквально
  ARCHIV». Працювало лише випадково, коли комплект розгорнутий у теці з
  таким іменем. Запущений з git-чекауту (інша назва теки — наприклад,
  `ARCHIV_LIMS_MONOLITH`) — обчислення тихо вказувало на каталог, якого
  не існує, і `Tools\TOOLS_MANIFEST.json` "губився", хоча фізично лежав
  поруч зі скриптом. Тепер — `$ConfigRoot` напряму.

  Той самий недолік був і в `Resolve-BRAVOInstallationDiscovery`:
  legacy-fallback для `BACKUP_ROOT` (коли служби BRAVO не знайдено)
  теж комбінував `LIMSRoot + "ARCHIV"` — друга здогадка поверх першої,
  і гірша за власний дефолт `BRAVO.config`. Тепер у цьому випадку
  `BACKUP_ROOT` лишається порожнім, і перемагає дефолт `ArchiveRoot`.

  Закрито тестами `Discovery/ArchiveRootDefaultsToScriptDirectory`,
  `Discovery/BackupRootStaysEmptyWithoutRealService`.

- **Ручний запуск `BRAVO_ARCHIV.ps1` з відсутніми обов'язковими
  обліковими даними тепер сам пропонує їх налаштувати**, замість того
  щоб просто впасти з помилкою `Не вдалося завантажити пароль архiвiв`
  і змусити шукати окремий скрипт. Якщо запуск інтерактивний (не
  `-NoPause`, реальна консоль — та сама перевірка
  `[Environment]::UserInteractive -and -not [Console]::IsInputRedirected`,
  що вже охороняє паузу перед закриттям) і не вистачає `BRAVO_7Z_PASSWORD`
  та/або `BRAVO_SFTP_LOGIN`/`BRAVO_SFTP_PASSWORD` (останні — лише якщо
  компонент їх справді потребує), автоматично запускається
  `BRAVO_CREDENTIALS_SETUP.ps1 -Action Ensure -Component Required
  -StoreFor CurrentUser` окремим процесом (ізольовано, щоб не
  перезаписати глобальний стан поточного запуску) — і лише для
  поточного користувача; обліковий запис запланованого завдання
  (`-StoreFor ScheduledTaskAccount`) як і раніше налаштовується окремо
  через `BRAVO_SETUP.ps1`/`BRAVO_CREDENTIALS_SETUP.ps1`.

  Закрито тестами `Console/ArchiveOffersCredentialSetupOnlyWhenInteractive`,
  `Console/ArchiveCredentialSetupUsesEnsureAndCurrentUserOnly`,
  `Console/ArchiveCredentialSetupRunsAsIsolatedProcess`.

- **Лог-файл тепер показує обране джерело для MODEL/BLOG/BAZA**, а не
  лише "УВIМКНЕНО"/"ВИМКНЕНО" як раніше. Секція `=== ОПЦIЇ СКРИПТА ===`
  для кожного увімкненого компонента додатково виводить рядок
  `Джерело <TYPE>: <шлях> (<причина>)`, де причина береться з
  `bravoDiscoveryResult.Reasons` (наприклад, `bravo.ini [model]
  MODEL=D:\LIMS-NEW\Model\lims` або `legacy fallback: ...`) — той самий
  формат, що вже показує `BRAVO_SETUP.ps1 -ValidateOnly`. Якщо джерело
  не вдалось визначити — `ERROR`-рядок з тією ж причиною замість
  мовчазного `null`. BRAVOEXCH і BAZA WWW це вже мали (окремі блоки),
  тепер симетрично й для MODEL/BLOG/BAZA.

  Закрито тестами `Console/ArchiveLogsModelSource`,
  `Console/ArchiveLogsBlogSource`, `Console/ArchiveLogsBazaLocalSource`.

- **Health падав із "The property 'ActionCounts' cannot be found on
  this object" щоразу, коли синхронізація BAZA на SFTP увімкнена, а
  локальний каталог BAZA відсутній.** Той самий клас бага, що вже
  ловив AUD (`Get-AlertFingerprint` і `DifferenceCount` для `Kind =
  "Service"`), але в іншому полі й інших місцях: лише ОДИН з чотирьох
  способів побудови проблеми `"SFTPSynchronization"`
  (`Get-SFTPHealthIssues`, гілка "у хмарі відсутні...") насправді
  встановлює `ActionCounts`. Три інших ("не вдалося визначити локальне
  джерело", "локальний каталог не знайдено", "не вдалося порівняти
  каталоги") — ні, а консольний журнал і `Format-CompactSFTPIssue`
  зверталися до `$healthIssue.ActionCounts`/`$Issue.ActionCounts`
  напряму навіть усередині `if ($null -ne ...)` — під `Set-StrictMode`
  це падає ще до самого порівняння. Archive (де Health викликається
  in-process) ловив це як повну відмову health-check замість звичайної
  проблеми в звіті — оператор не отримував жодної тривоги.

  Новий `Get-BRAVOHealthIssueActionCounts` (той самий підхід, що вже
  має `Get-BRAVOHealthIssueField`: `PSObject.Properties['ActionCounts']`
  замість прямої крапки) замінив усі небезпечні звернення в обох
  місцях. Перевірено живим прогоном `BRAVO_HEALTH.ps1` за тих самих
  умов, що й реальний збій: третя проблема тепер коректно потрапляє у
  звіт (`SFTP BAZA: локальний каталог BAZA не знайдено; ...; типи
  розбіжностей: немає даних`) замість краху всього health-check.

  Закрито тестом `Health/SFTPSynchronizationToleratesMissingActionCounts`.

- **`BAZA_APP` шукався поруч із `LIMSRoot`, а не поруч із реальним
  `MODEL`/`BLOG` з `bravo.ini`.** `BAZA` не має власного ключа в
  `bravo.ini`, тому `BAZA_APP` завжди виводився як `<BRAVO_ROOT>\BAZA`
  — а `BRAVO_ROOT`, коли Windows-службу BRAVO не знайдено (типова
  dev/test-машина без встановленої служби, лише з конфігом), деградує
  до `LIMSRoot`-фолбеку. Реальний випадок: `bravo.ini` знайдено
  (системний каталог Windows не залежить від служби), `MODEL`/`BLOG` з
  нього коректно вказували на `D:\LIMS-NEW\...`, а `BAZA_APP` усе одно
  шукався в `C:\Users\...\Documents\BAZA` — зовсім іншому місці.

  Тепер, коли `MODEL` або `BLOG` вже взято з `bravo.ini`, `BAZA_APP`
  виводиться як сусідній каталог у тому самому корені інсталяції
  (`Split-Path -Parent` від `MODEL_SOURCE`/`BLOG_SOURCE`) — і лише
  якщо жоден з них з `bravo.ini` не прийшов, лишається старий
  `<BRAVO_ROOT>\BAZA` fallback.

  Закрито тестом
  `Discovery/BazaAppFollowsIniInstallationRootNotBravoRootFallback`.

- **SFTP: скрипт тепер сам створює відсутні кореневі каталоги**
  (`model`/`blog`/`bravoexch`/`baza_app`/...) замість того, щоб просто
  падати. Реальний випадок: WinSCP явно повідомляв `Error listing
  directory '/baza_app'. No such file or directory` — жоден із
  каталогів на сервері ще не існував, і кожна передача (як окремих
  файлів, так і синхронізація BAZA) провалювалася кодом 1.

  Новий `Initialize-BRAVOSFTPRemoteDirectories` викликається одним
  пакетним WinSCP-скриптом одразу після підтвердженого з'єднання, перед
  Send-FileViaWinSCP/Sync-FolderToSFTP — і в автоматичному потоці, і в
  ручній `-SyncBAZA`. `option batch continue` навмисно: `mkdir` на вже
  наявному каталозі повертає помилку (а після першого успішного запуску
  каталоги вже існують щоразу), тому виклик — best-effort і ніколи не є
  джерелом істини про успіх; реальний результат перевіряють окремі
  виклики передачі, які на це не зважають.

  Це оголило два раніше недосяжні StrictMode-баги в самій `Sync-FolderToSFTP`
  (аудит BAZA до цього завжди падав на "каталог не знайдено" ще до того,
  як доходило до цього коду):
  - `Get-BAZASFTPComparison` читав ім'я локального елемента порівняння
    через `.FullName` — а `$difference.Local` з WinSCP `CompareDirectories`
    це `WinSCP.RemoteFileInfo` (навіть для локальної сторони), а не
    `System.IO.FileInfo`: такої властивості там немає взагалі, лише
    `.FileName` (той самий API, що вже коректно працює через
    `$side.FileName` у `BRAVO.Health.Runtime.ps1`).
  - `Write-BAZASFTPComparisonAudit`/`Write-BAZARemoteNameCompatibilityAudit`
    викликали `Write-BRAVOLog -FileOnly` — цей перемикач існує лише на
    локальному шимі `Write-Log` (транслює його в `-NoConsole`), а сам
    `Write-BRAVOLog` такого параметра не має і падає з
    `InputValidationError`.

  Перевірено живим прогоном на реальному SFTP (Hetzner Storage Box):
  до фіксів — 0 з 6 файлів; після mkdir-фіксу — 6 з 6 файлів, але аудит
  BAZA падав на `.FullName`; після `.FileName`-фіксу — падав на
  `-FileOnly` при спробі залогувати 374 елементи аудиту; після всіх
  трьох фіксів разом — `374 з 374` файлів BAZA синхронізовано,
  `Каталог BAZA повнiстю синхронiзовано з /baza_app`.

  Закрито тестами `Console/ArchiveEnsuresSFTPDirectoriesBeforeTransfer`,
  `Console/BazaComparisonReadsFileNameSafely`,
  `Console/BazaAuditUsesNoConsoleNotFileOnly`.

- **Власний прогрес-бокс `Test-NetConnection` ("Attempting TCP connect",
  "Waiting for response") усе одно з'являвся в консолі поверх кроків
  BRAVO**, хоча мав бути прихованим. `Test-BRAVOTcpConnection` уже
  придушував його через `$ProgressPreference = 'SilentlyContinue'`, але
  локальне присвоєння (без `$global:`) ненадійне для цього конкретного
  командлета — відомий нюанс Windows PowerShell 5.1, коли сам
  `Test-NetConnection` не завжди резолвить preference-змінну лише з
  локального scope виклику.

  Тепер тимчасово підміняється ГЛОБАЛЬНЕ `$ProgressPreference`
  (з гарантованим відновленням попереднього значення в `finally`) —
  саме так, як і задумувалося коментарем, що вже існував у коді.

  Закрито тестом `Compatibility/TcpConnectionSuppressesGlobalProgress`.

- **`BRAVO_ARCHIV.ps1` друкував ПОВНИЙ заголовок Health усередині
  власного кроку "Перевірка резервних копій"** — "BRAVO HEALTH X.X.X /
  Установа / Початок" виглядало як друга незалежна програма всередині
  виводу Archive, з власною версією й міткою часу, хоча це один
  прогін. Реальний випадок (скріншот користувача): "дублювання
  зявляється при запуску BRAVO_ARCHIV.ps1 + BRAVO_HEALTH.ps1 — у
  кожного свої заголовки та етапи".

  `Invoke-BRAVOHealth` отримав новий `-SuppressHeader`, який передається
  лише зі шляху `Invoke-BRAVOHealthCheck` (`BRAVO.Health.psm1`) —
  вбудований виклик з Archive. Самостійний запуск `BRAVO_HEALTH.ps1`
  проходить іншим шляхом (без цього параметра), тому там заголовок
  лишається без змін. `Write-BRAVOHeader` (BRAVO.Console) отримав
  `-SuppressText`: приховує сам текст заголовка, але зберігає
  резервування порожніх рядків під прогрес-бар — без цього перші рядки
  вбудованого Health-звіту ризикували опинитися під смугою.

  Закрито тестом `Console/EmbeddedHealthSuppressesDuplicateHeader`.

- **Уніфіковано вбудований звіт Health усередині `BRAVO_ARCHIV.ps1`** —
  прибирання заголовка (див. вище) закрило лише частину проблеми
  (реальний скріншот користувача, зроблений після цього): вбудований
  виклик усе одно друкував ВЛАСНУ покрокову нумерацію `[N/5]` поряд із
  нумерацією Archive `[N/7]`, ВЛАСНИЙ підсумок (`Результат`/
  `Тривалість`/.../`Детальний журнал`) поряд із підсумком Archive —
  фактично два незалежні звіти замість одного. Плюс `SFTP MODEL:
  серверний SHA архіву недоступний; використано повний збіг
  віддаленого hash-файлу` показувалось як WARNING, хоча перевірка все
  одно успішна (просто іншим методом).

  `Write-BRAVOHealthStep` тепер пропускає власний друк `[N/5]` при
  `-SuppressHeader`, не збиваючи внутрішній лічильник кроків (від нього
  залежить нумерація кроку "Сповіщення"). `Complete-BRAVOHealthResult`
  придушує власний `Write-BRAVOSummary` — `Complete-BRAVOProgress`
  (очищення прогрес-бару) лишається безумовним. Фолбек на `.sha512`
  тепер логується як INFO, а не WARNING: перевірка успішна, це нотатка
  про метод, а не привід для уваги оператора. Разом з попереднім
  прибиранням заголовка вбудований виклик тепер показує лише те, що
  справді потрібно: значущі "Проблема ..." деталі (якщо є) і ОДИН
  підсумок Archive з ОДНИМ посиланням на лог-файл.

  Закрито тестами `Health/EmbeddedCallSuppressesStepNumbering`,
  `Health/EmbeddedCallSuppressesOwnSummary`,
  `Health/ServerSideHashFallbackIsInfoNotWarning`.

- **Зайвий порожній розрив між `[6/7]` і `[7/7]` усередині
  `BRAVO_ARCHIV.ps1`** — після прибирання заголовка й підсумку Health
  (див. вище) лишався фіксований блок із 6 порожніх рядків
  (`BRAVOConsoleProgressReservedLines`), який раніше захищав текст
  заголовка Health від накладання прогрес-бару. Без самого тексту
  захищати вже нічого, а блок лишався видимим розривом навіть тоді,
  коли Health не знаходила жодної проблеми для показу (реальний
  скріншот користувача). `Write-BRAVOHeader -SuppressText` тепер
  пропускає ввесь вивід одразу — і текст, і резервування рядків.

- **`BAZA_WWW` (бекап `{DocumentRoot}\BAZA` встановленого Apache) тепер
  визначається автоматично, а не задається вручну.** `Resolve-BRAVOInstallationDiscovery`
  шукає службу Apache2.4/Br-a-vo.web (той самий канал кандидатів, що й
  раніше), знаходить її `httpd.exe`, читає `<ServerRoot>\conf\httpd.conf`
  новим парсером `Get-BRAVOApacheDocumentRoot` і бере `DocumentRoot`
  звідти — а не вгадує його з розташування `apache\`. Синхронізація
  вмикається лише тоді, коли служба справді встановлена і `DocumentRoot`
  вдалось прочитати; каталог на SFTP лишається `baza_www`, без змін.
  `BRAVO.config` більше не містить окремої логіки пошуку (видалено
  ~130-рядковий `Find-BRAVOWebBAZASource` з обходом предків і евристикою
  "перша непорожня папка") — тепер це тонкий адаптер над результатом
  Discovery.

  Попутно знайдено й виправлено реальний баг, який виявився лише на
  живій машині з дійсно встановленою службою Apache: `BRAVO.Discovery`
  викликає `Get-BRAVOWmiInstance` (з `BRAVO.Compatibility`), не
  імпортувавши цей модуль сам — і те, що виклик модуля-споживача
  (наприклад, `BRAVO.Health.Runtime.ps1`) імпортує `BRAVO.Compatibility`
  РАНІШЕ, не робить її функції видимими всередині чужого модуля: кожен
  PowerShell-модуль має власний session state. Через це `WEB_ROOT` і
  `BAZA_WWW` мовчки лишались порожніми на машині з реально запущеною
  службою `Br-a-vo.web`, хоча той самий пошук служби прекрасно
  спрацьовував поза модулем. Виправлено додаванням явного
  `Import-Module BRAVO.Compatibility` на початку `BRAVO.Discovery.psm1`
  — той самий патерн, що вже застосовано в `BRAVO.Notifications`,
  `BRAVO.ArchiveRuntime`, `BRAVO.ArchiveHelpers`.

  Закрито тестами `Discovery/ApacheDocumentRootParserReadsQuotedForwardSlashPath`,
  `Discovery/ApacheDocumentRootParserIgnoresCommentedDirective`,
  `Discovery/BazaWwwUsesHttpdConfDocumentRoot`. Підтверджено живим
  прогоном `BRAVO_HEALTH.ps1` на машині з реальною службою
  `Br-a-vo.web`: `WEB_ROOT`, `HttpdConfPath`, `BAZA_WWW` заповнюються
  коректно зі справжнього `httpd.conf`.

- **Визначення BAZA обмежено рівно чотирма незалежними значеннями:
  `BAZA_APP_SFTP`, `BAZA_WWW_SFTP`, `BAZA_APP_LOCAL`, `BAZA_WWW_LOCAL`.**
  Раніше `componentSettings.Synchronization` називав ці прапорці
  `BAZALocal`/`BAZASFTP`/`BAZAWWWSFTP` — бареве `BAZA` без суфікса
  означало "APP", що легко сплутати з `BAZA WWW` при читанні коду чи
  конфігурації. Перейменовано наскрізно (`BRAVO.config`, `BRAVO.Archive`,
  `BRAVO.Health`, `BRAVO_DRY_RUN.ps1`, `BRAVO_SETUP.ps1`,
  `BRAVO_CREDENTIALS_SETUP.ps1`, `BRAVO_TASKS_INSTALL.ps1`) разом із
  похідними змінними (`bazaAppLocalSyncEnabled` тощо) і текстом логів
  ("Синхронiзацiя BAZA APP на SFTP" замість голого "BAZA"). Discovery-поля
  (`BAZA_APP`/`BAZA_WWW` — шляхи-джерела, не прапорці) і каталоги на SFTP
  (`baza_app`/`baza_www`) не чіпались — вони й так уже однозначні.

  **`BAZA_WWW_LOCAL` — нова функція**, а не просто перейменування: локальна
  копія `BAZA_WWW` (`{DocumentRoot}\BAZA` встановленого Apache/Br-a-vo.web)
  у каталог `BackupRoot\BAZA_WWW`, точно за тим самим принципом, що вже
  давно робить `BAZA_APP_LOCAL` (`Sync-Folders` через robocopy). За
  замовчуванням вимкнено (`$false`), як і `BAZA_APP_LOCAL`. Health отримав
  той самий read-only `robocopy /L` контроль актуальності, що вже був для
  `BAZA_APP_LOCAL` (спільна `Get-BAZALocalSyncHealthIssues`, раніше
  `Get-BAZALocalHealthIssues`, з новим параметром `-Label`).

  Закрито тестами `Discovery/ConfigDefinesExactlyFourBazaSyncFlags`,
  `Discovery/ArchiveReadsExactlyFourBazaSyncFlags`,
  `Console/ArchiveSyncsBazaWwwLocally`, `Health/BazaWwwLocalHealthCheckWired`.

- **`BRAVO_MAINTENANCE.ps1` відмовлявся запускатись, якщо каталог скрипта
  назвався не буквально `ARCHIV`.** Той самий крихкий здогад, що вже
  прибрано з `ArchiveRoot` (`pathSettings`, дивись запис нижче в цьому ж
  циклі) — і так само працював лише випадково, коли комплект розгорнутий
  саме в теці з таким іменем. Будь-яке інше розташування (наприклад,
  git-чекаут з іменем репозиторію) блокувало Maintenance повідомленням
  "Скрипт має запускатись лише з папки ARCHIV!" (код `90`) без жодної
  реальної причини — `ArchiveRoot`/`LIMSRoot` і так явно задаються
  окремо в `pathSettings`. Перевірку прибрано; жодне інше місце в
  комплекті на неї не покладалось.

- **`BRAVO_MAINTENANCE.ps1` мовчки пропускав до 3 із 7 етапів, коли
  `LIMSRoot` не вказує на реальний корінь LIMS-інсталяції.** `Check-MdFileSizes`
  сканував `$MODEL_PATH = "$ROOT_LIMS\Model"` — той самий крихкий
  LIMSRoot-відносний здогад, що вже прибрано з `MODEL_SOURCE` в Archive.
  Коли реальний каталог MODEL не збігався з цим здогадом (`LIMSRoot`
  вказував не на корінь інсталяції), `EnumerateFiles` кидав
  `DirectoryNotFoundException`, який ніхто не ловив аж до
  `Invoke-BRAVOMaintenanceEntrypoint`: `finally`-блоки встигали відновити
  служби й показати "Натисніть будь-яку клавішу", але етапи "Реставрація
  моделі"/"Обробка trace і логів"/"Очистка" пропускались мовчки, без
  видимої помилки в консолі (лише after-the-fact `Write-Error`, після
  натискання клавіші).

  Той самий здогад використовувала й **реставрація моделі через
  `bravocmd.exe`** (`$ROOT_LIMS\MODEL\lims`) та шлях до самого
  `bravocmd.exe` (`$ROOT_LIMS\bravocmd.exe`) — деструктивна операція, яка
  на нетиповій структурі диска так само вказувала б у порожнечу.

  Усі три джерела істини — `bravoDiscoveryResult.MODEL_SOURCE`,
  `.MODEL_PROJECT_FILE` (точне значення `MODEL=` з `bravo.ini`, те, що
  приймає `bravocmd.exe`) і `.BRAVO_ROOT` (каталог `bravo.exe`, де
  логічно лежить і `bravocmd.exe`) — з тим самим фолбеком на старий
  LIMSRoot-відносний шлях, коли Discovery нічого не знайшов (bravo.ini чи
  служба відсутні), тому поведінка на типовому розгортанні не змінюється.

  Перевірка: живий прогін на машині, де раніше падало на кроці
  "Перевірка розмірів .md" — тепер усі 7 етапів показуються й
  завершуються, результат УСПІШНО.

- **Заголовок `BRAVO_MAINTENANCE.ps1` дублював код установи:**
  "Установа: Тестова установа [0000000] [0000000]". `Write-BRAVOHeader`
  сам додає `[InstitutionCode]` до `-Institution`, а Maintenance передавав
  туди вже складений `$script:ObjectName` (`"$InstitutionName [$InstitutionCode]"`,
  той самий рядок, що йде в Slack/лог-підсумок) — замість самої лише
  назви, як роблять Archive і Health. Виправлено на `bravoSettings.InstitutionName`,
  узгоджено з обома іншими runtime. Підтверджено живим прогоном.

- **Консольний підсумок `BRAVO_MAINTENANCE.ps1` теж повторював установу**
  окремим рядком "Установа: ..." після "Попереджень: 0" — зайве, коли та
  сама інформація вже показана в заголовку рядком вище. Ні Archive, ні
  Health установу в підсумку не дублюють. Прибрано.

## 4.4.2 — 2026-08-05

Виправлення за результатами першого тестового розгортання на реальному
сервері. Обидва дефекти — не в тому, що BRAVO робить, а в тому, що він
**показує**: перевірка готовності звітувала «все гаразд» там, де запуск
би не відбувся, а діагностика виводила результат нечитабельним.

- **`BRAVO_DRY_RUN.ps1` не перевіряв цілісність комплекту.** Він звітував
  «помилок — 0» на комплекті, у `Tools\` якого лежали залишки старого
  розкладання; кожен запуск за розкладом на тому ж комплекті завершився б
  кодом `33`, бо entrypoint кличе guard, а dry-run — ні.

  Перевірка готовності, яка не перевіряє того, що перевіряє сам запуск,
  дає хибну впевненість — а це найгірше, що вона може зробити. Тепер
  dry-run виконує ті самі три перевірки (`33`, `34`, `35`), причому
  `Test-BRAVOVersionDowngrade` — з `-NoWrite`: dry-run не має права
  фіксувати розгортання, якого ще не було.

  Закрито тестами `DryRun/VerifiesRuntimeIntegrity` і
  `DryRun/DoesNotRecordVersionState`.

- **`OPERATIONS.md`:** два розділи за реальними симптомами цього
  розгортання — «сторонні скрипти в комплекті» (код `33`, найчастіша
  причина на свіжому сервері, з прямою забороною «узаконювати» знахідку
  оновленням маніфесту на сервері) і «Цей хост невідомий» для SFTP (це
  DNS та ім'я, що будується з логіна й шаблону, а не автентифікація).

- **Результат SYSTEM dry-run у `BRAVO_TASKS_DIAGNOSE.ps1` друкувався одним
  нечитабельним рядком.** `ConvertFrom-Json` у Windows PowerShell 5.1
  віддає JSON-масив **одним об'єктом**, не розгортаючи його в конвеєр, тому
  `@(... | ConvertFrom-Json)` давало масив із єдиного елемента-масиву: цикл
  виконувався один раз, `$result.Status` ставав `System.Object[]`, і весь
  звіт злипався у `[PASS PASS FAIL ...] Конфігурація Скрипти ...: шлях шлях`.

  Саме цей вивід читають, коли треба зрозуміти, чому завдання від `SYSTEM`
  не працює. Виявлено на тестовому сервері.

  Закрито двома тестами: функціональним (обидві форми, з перевіркою що
  хибна справді згортає) і AST-сканером усіх скриптів комплекту. Сканер
  саме по AST, а не підрядком, щоб не ловити власні пояснювальні коментарі.

## 4.4.1 — 2026-08-05

Патч безпеки, знайдений першим же тестовим розгортанням 4.4.0. Ставте
на сервер саме цю версію, а не 4.4.0.

- **Незавантажуваний `BRAVO_RUNTIME_GUARD.ps1` більше не вимикає весь шар
  цілісності.** `Test-Path` підтверджував лише наявність файлу. Якщо
  dot-source не виконувався — `ExecutionPolicy AllSigned` без підпису,
  синтаксична помилка, блокування файлу — entrypoint мовчки йшов далі:
  усі три перевірки (`33`, `34`, `35`) падали з `CommandNotFound`, не
  зупиняючи запуск, і справа доходила до `Import-Module`.

  Тобто найдешевшим способом обійти перевірку цілісності було не
  підбирати SHA-256, а зробити guard непрацездатним. Тепер dot-source
  обгорнуто в `try/catch`, а наявність усіх трьох функцій підтверджується
  через `Get-Command`; будь-який збій — код `33` до завантаження модулів.
  Виявлено під час тестового розгортання 4.4.0 на сервері з `AllSigned`.

  Закрито двома тестами: статичним (`try/catch` + `Get-Command` у всіх
  трьох entrypoint) і функціональним — справжній entrypoint поруч із
  guard-ом, що не парситься, мусить завершитись кодом `33`. До
  виправлення той самий сценарій давав `90`, тобто прохід повз перевірки.

- **`OPERATIONS.md`:** окремий розділ для `33` під `ExecutionPolicy
  AllSigned`. Це не атака, а політика виконання: заплановані завдання
  працюють (`-ExecutionPolicy Bypass`), ручний запуск із консолі — ні.
  Прямо сказано, чого робити не можна: знижувати політику машини заради
  зручності.

## 4.4.0 — 2026-08-05

Реліз для тестового розгортання. Основне — єдиний стиль операційної
консолі для всіх трьох runtime; дорогою закрито зовнішнє рев'ю, кілька
пунктів аудиту й два дефекти, через які моніторинг мовчав.

**Перед першим запуском на сервері:** `BRAVO_MAINTENANCE.ps1` цієї версії
жодного разу не виконувався наскрізь — його логування, шкала рівнів і
структура виводу змінені й перевірені статично, самотестом і на стенді,
але не живим прогоном. Перший запуск має бути ручним і під наглядом, не
за розкладом: Maintenance зупиняє служби LIMS, реставрує модель і
видаляє дані.

- **Єдиний стиль відображення для всіх трьох runtime.** `BRAVO.Console`
  існував і робив саме те, що треба — заголовок, нумеровані етапи
  `[1/7] Назва.....OK`, сталі кольори статусів, одна смуга прогресу,
  підсумок, — але користувався ним лише Archive. Health вивалював в
  консоль кожен запис журналу суцільним потоком `[LEVEL] текст` без
  жодного кольору; Maintenance малював `=== ЗАГОЛОВОК ===` і власну
  палітру. Оператор бачив три різні програми.

  Health і Maintenance переведено на `BRAVO.Console`: заголовок, етапи,
  підсумок із метриками. Вимкнений у конфігурації компонент не показуємо
  й не рахуємо — знаменник обчислюється за увімкненими, як це від
  початку робив Archive. Вимкнені BAZA, NAS/SMB і сповіщення дають
  `[1/4]…[4/4]`, а не `[1/7]…[7/7]` із трьома порожніми рядками.
  Реставрація моделі показується лише тоді, коли справді виконуватиметься
  цього запуску; якщо вона була запланована, але службу BRAVO не вдалося
  зупинити, рядок лишається — це не «не настав час», а заплановане й
  невиконане. У Health підсумок друкується з
  `Complete-BRAVOHealthResult`, через яку проходить кожен зі шляхів
  виходу, тому нова гілка не може лишитися без підсумку.

  Консольна половина журналу теж тепер іде через `BRAVO.Console`
  (`Set-BRAVOLogConsoleWriter`): `WARNING` із бізнес-логіки дописувався
  у хвіст відкритого рядка етапу й ламав розмітку рівно тоді, коли
  щось пішло не так. Це callback, а не залежність: журналювання —
  нижчий шар і має працювати там, де консолі немає взагалі.

  З підсумку Health прибрано метрики вимкнених призначень: рядок
  `NAS/SMB: True` читався як «перевірено й усе гаразд», хоча перевірки
  не було взагалі.

  Заголовок тепер зсуває вміст під смугу прогресу: у класичному хості
  `Write-Progress` малюється поверх верхніх рядків вікна й повертає їх
  лише на `-Completed`, через що заголовок і перші етапи були невидимі
  протягом усього запуску.

- **Health падав із кодом `90` щоразу, коли лежала керована служба.**
  Об'єкт проблеми `Kind = "Service"` не несе полів `DifferenceCount` і
  `ActionCounts`, а `Get-AlertFingerprint` читав їх у всіх проблем без
  розбору. Під `Set-StrictMode` це помилка, тому runtime завершувався
  внутрішньою помилкою **замість того, щоб надіслати тривогу**: рівно
  той тип мовчазного моніторингу, проти якого існує Health. Поля тепер
  читаються через `Get-BRAVOHealthIssueField`.

- **`LogLevel = "SUCCESS"` приховував помилки в Maintenance.** У
  локальній шкалі рівнів `SUCCESS=4` стояв вище за `ERROR=3`, тому
  найвища детальність відсікала саме помилки й попередження. Шкалу
  приведено до тієї, що в `BRAVO.Logging`, де `SUCCESS` свідомо нижче
  за `WARNING`. Ту саму пастку `BRAVO.Logging` виправив раніше — тут
  вона лишалася в копії.

- **`THREAT_MODEL.md` приведено у відповідність до коду.** Документ
  описував як відкриті три ризики, які код уже закрив: послаблення
  перемикачів безпеки в `BRAVO.config` (код `34`), відкат версії
  (код `35`) і секрет як звичайний .NET `string`. Модель загроз, що
  перебільшує ризик, шкодить не менше за ту, що применшує — власник
  ухвалює інфраструктурні рішення саме за її списком пріоритетів.

  Перероблено розділи 3 (`BRAVO.config` як AST, умови блокування,
  `BRAVO_ALLOW_WEAKENED_SECURITY`), 4 (`SecureString`-ланцюг і чесна межа:
  SFTP URL і пароль 7-Zip лишаються незанулюваними рядками), 7 (перевірка
  `34` стежить за перемикачами, не за самим призначенням), 8 (стан у
  `LOGS\BRAVO_VERSION_STATE.json`, `BRAVO_ALLOW_DOWNGRADE`, і прямо
  сказано, що це захист від помилкового відкату, не від зловмисного —
  файл стану лежить на тому самому сервері) і 11 (перелік пріоритетів
  перебудовано, закриті пункти винесено окремо).

  Дрейф закрито тестами `Documentation/ThreatModelReflectsImplementedControls`
  і `Documentation/ThreatModelHasNoStaleResidualRisk`.

- **Аудит #5: секрет із Credential Manager більше не матеріалізується як
  звичайний рядок.** `StoredCredential.Secret` тепер `SecureString`. У
  .NET рядок незмінний, тому його неможливо занулити — копія пароля
  лишалась у керованій купі до збирання сміття, і кожне читання
  створювало ще одну, а Archive/Health/Maintenance читають облікові дані
  кілька разів за запуск.

  Декодування blob'а йде в `char[]` (масив можна очистити) з посимвольним
  додаванням у `SecureString`; масив байтів і масив символів зануляються
  у `finally`. Повного відкритого пароля не існує в керованій пам'яті на
  жодному кроці читання.

  **SMB-шлях плейнтексту не створює взагалі:** новий
  `New-BRAVOSecureCredential` будує `PSCredential` напряму з
  `SecureString`. Раніше пароль SMB ставав рядком лише для того, щоб
  одразу перетворитись назад.

  `ConvertFrom-BRAVOSecureSecret` — єдина точка перетворення в
  плейнтекст, із детермінованим зануленням проміжного BSTR
  (`ZeroFreeBSTR`). `Get-BRAVOCredentialSecret` збережено без зміни
  сигнатури, щоб не переписувати 19 місць runtime одним махом.

  **Чесна межа задокументована в SECURITY.md:** рядок, повернутий із
  точки перетворення, лишається незанулюваним. Зміна прибирає зайві
  копії й робить кожне перетворення видимим, але не усуває плейнтекст як
  такий — WinSCP приймає URL `sftp://user:pass@host`, а 7-Zip пароль
  через stdin. Повне усунення потребує SFTP-автентифікації ключем.

  Покрито `Secrets/CredentialSecretIsSecureString`,
  `SecureSecretRoundTrip` (кирилиця й спецсимволи — C# декодує байти
  вручну), `SecureCredentialSkipsPlainText`,
  `SmbPasswordNeverBecomesPlainText`.

- **Літерали, що виглядають як облікові дані, прибрані з тестових
  фікстур.** У тесті `Protect-BRAVOLogSecret` лежали sftp-URL із паролем,
  повні Slack/Discord webhook-URL із токенами й паролі 7-Zip — записані
  літералами. Значення вигадані, але для сканера це справжні секрети:
  саме через них GitGuardian періодично піднімав інциденти, які
  доводилось закривати вручну.

  Альтернатива «додати виняток сканеру» гірша: виняток глушить і
  справжній витік у тому самому файлі. Тому фікстури тепер збираються з
  частин у рантаймі, а перевірки звіряються зі змінними — маскування
  тестується так само строго.

  Самотест `Secrets/NoCredentialShapedLiterals` не дає їм повернутись.
  Перевіряються лише **строкові літерали з AST**: коментарі й
  документація свідомо поза межами, бо там форма URL з обліковими даними
  потрібна, щоб пояснити, що саме маскується. Плейсхолдерами вважаються
  узагальнені слова (`pass`, `password`), маска `***`, підстановка
  формату `{0}` і посилання на змінну — останнє обов'язкове, бо
  `New-BRAVOSftpUrl` будує саме такий рядок із `${escapedPassword}`, і
  перша версія перевірки на цьому робочому коді спіткнулась.

- **Аудит Low #10: `Get-BRAVOWinSCPBusyMessage` формував текст в обхід
  єдиної точки санітизації.** Її результат іде у `Write-BRAVOLog`
  (Archive) і в `throw` (Health) — тобто в журнал і в сповіщення, — тоді
  як `Get-SanitizedWinSCPDiagnostic` застосовувалась лише до
  stdout/stderr WinSCP.

  Сьогодні витікати нема чому: в `$Availability.Processes` лежать самі
  `ProcessId`. Але `$Availability.Error` — це вільний текст із
  `$_.Exception.Message`, а найприроднішим розширенням діагностики «який
  саме WinSCP зараз працює» є `CommandLine` з `Win32_Process`, у якому
  лежить `sftp://user:password@host`. Тоді повідомлення про зайнятість
  стало б місцем витоку пароля в журнал і Slack/Discord.

  Тепер обидві гілки повідомлення проходять спільну санітизацію.
  Покрито двома самотестами: `Secrets/WinSCPBusyMessageIsSanitized`
  (пароль у `sftp://` і в `-password=` замаскований) і
  `Secrets/WinSCPBusyMessageKeepsDiagnostics` (PID і назва операції
  лишаються читабельними — інакше санітизацію почнуть обходити).

  На цьому закрито всі три Low-зауваження початкового аудиту (#8, #9,
  #10).

- **Аудит Low #9: вікно між створенням тимчасового WinSCP-файла й
  накладанням ACL.** `New-BRAVOWinSCPTemporaryScriptPath` створювала файл
  через `[IO.File]::Open`, а потім захищала його через `Set-Acl` —
  попри коментар, який стверджував, що файл створюється «атомарно».

  У вікні між цими двома діями файл існує з успадкованими від `%TEMP%`
  правами. Для запланованого завдання `%TEMP%` — це `C:\Windows\Temp`,
  куди має доступ значно ширше коло. Порожній файл секрету ще не
  містить, але **Windows перевіряє права в момент відкриття
  дескриптора, а не при кожному читанні**: відкритий у цьому вікні
  дескриптор переживає зміну ACL і прочитає облікові дані SFTP, які
  запише туди викликач.

  Тепер DACL будується ДО створення й передається у конструктор
  `System.IO.FileStream` разом із `FileSecurity` — файл ніколи не існує
  з успадкованими правами, вікна немає взагалі.

  Наявний функціональний тест `Runtime/ProtectedWinSCPTemporaryScript`
  посилено (жодного успадкованого правила, жодного зайвого SID), але
  сам по собі він цю ваду не ловить: **результат в обох схемах
  однаковий**, різниця лише у вікні. Регресійна перевірка це
  підтвердила — під час повернення старої схеми функціональний тест
  лишився зеленим. Тому додано статичний
  `SFTP/TemporaryScriptCreatedWithFinalAcl`, який вимагає `FileSecurity`
  у конструкторі `FileStream` і забороняє виклики `Set-Acl`/`Get-Acl` у
  цій функції. Виклики шукаються в AST, а не пошуком підрядка: текст
  функції містить слово `Set-Acl` у коментарі, що пояснює її
  відсутність.

- **Аудит Low #8: порожні `catch {}` ковтали діагностику.** У комплекті
  було 35 порожніх `catch`, з них 11 — без жодного пояснення. Проблема
  не в тому, що блок порожній (частина з них законна: прибирання у
  `finally`, де початкова помилка важливіша), а в тому, що він **мовчить
  без причини** — саме тоді, коли діагностика потрібна найбільше.

  Три з них були не діагностичною, а **безпековою** проблемою:
  `Remove-BRAVOWinSCPSensitiveTemporaryScript` затирає й видаляє
  тимчасовий WinSCP-скрипт, який містить облікові дані SFTP. Мовчазна
  помилка означала, що файл із секретом лишається в `%TEMP%`, і ніхто
  про це не дізнається. Тепер — `WARNING` з іменем файлу, який треба
  видалити вручну.

  Решта отримала `DEBUG` (завершення процесу після таймауту, DNS-запит
  локальної IP для сповіщення, читання попереднього стану завдань,
  дренаж потоків) або `Write-Warning` (невидалене тимчасове завдання
  Планувальника — наступний запуск діагностики впав би на імені, що вже
  існує). У `BRAVO.Compatibility` логування свідомо не додано: це
  найнижчий шар, він завантажується до `BRAVO.Logging` і навмисно не має
  від нього залежності — тепер це записано в самому `catch`, а не
  мається на увазі.

  Самотест `Diagnostics/NoSilentEmptyCatch` вимагає, щоб кожен порожній
  `catch` у production-комплекті або логував, або **всередині блоку**
  пояснював, чому логування тут недоречне.

- **Захист від відкату на старішу версію (новий код завершення `35`).**
  Четвертий залишковий ризик із THREAT_MODEL §11. Усі наявні перевірки
  звіряють комплект із його **власним** маніфестом — старий, внутрішньо
  узгоджений комплект проходить їх бездоганно, разом із вразливостями,
  які відтоді закрили, і без перевірок, яких у ньому ще не існувало.
  Найпростіший спосіб вимкнути `Enforce` — не ламати його, а розгорнути
  версію, де його ще не було.

  Сервер запам'ятовує найвищу версію, яку на ньому запускали
  (`LOGS\BRAVO_VERSION_STATE.json`: `highestVersion`, `sourceCommit`,
  `recordedAt`), і відмовляється виконувати старішу. Свідомий відкат —
  через `BRAVO_ALLOW_DOWNGRADE=1`.

  Файл стану навмисно НЕ поводиться як маніфест: пошкоджений або
  відсутній — не блокує. Він не є еталоном довіри, і його втрата не
  мусить зупиняти backup; наступний успішний запуск запише його наново.
  Ручний запуск `BRAVO_RUNTIME_GUARD.ps1` перевіряє версію з `-NoWrite`,
  щоб діагностика не змінювала стан, який вона перевіряє.

  Чесна межа задокументована в SECURITY.md і OPERATIONS.md: той, хто має
  права підмінити комплект, зазвичай має права й видалити файл стану.
  Перевірка робить відкат помітним і таким, що потребує ще однієї
  свідомої дії; проти випадкового відкату вона працює повністю.

  Покрито `VersionState/*` (8 тестів, включно з повним циклом запису на
  диск) і `ExitCodes/VersionDowngradePriority`.

- **Захист перемикачів безпеки в `BRAVO.config` (новий код завершення
  `34`).** THREAT_MODEL §11 називав це третім залишковим ризиком; окремо
  виявилось, що коментар у `BRAVO_RUNTIME_GUARD.ps1` уже посилався на
  `Test-BRAVORuntimeSecuritySettings` як на наявну перевірку — функції не
  існувало. Документація обіцяла захист, якого не було.

  `BRAVO.config` навмисно не входить до `RUNTIME_MANIFEST.json`: він
  різний на кожному сервері, спільного еталонного хешу не існує. Через це
  він лишався єдиним файлом комплекту, який можна змінити без сліду — а в
  ньому є перемикачі, що вимикають решту захисту:
  `toolIntegritySettings.Mode = "Warn"` (підмінений `7za.exe` більше не
  блокує) і `backupConsistency.Mode ≠ "VSS"` (архів без VSS-знімка).
  Рядок у текстовому файлі коштує дешевше за підміну бінарника.

  Значення читаються **розбором AST** (`[Parser]::ParseFile`), без
  виконання: завантажити `BRAVO.config` означало б виконати довільний
  PowerShell-код ще до перевірки. Послаблення лишається можливим, але
  вимагає двох дій у двох різних місцях — правки конфігурації й
  `BRAVO_ALLOW_WEAKENED_SECURITY=1`, за зразком уже наявного
  `BRAVO_ALLOW_UNSUPPORTED_OS`. Друга дія лишає слід поза комплектом.

  Обхід через обчислюване значення (`$m = "Warn"; Mode = $m`) статично не
  підтверджується й тому блокує так само — інакше він був би дешевшим за
  пряме послаблення.

  Код `34` у контракті стоїть нижче за `33` (там факт підміни), але вище
  за `32` і `20`: доки перемикачі вимкнені, будь-який успіх нижче
  означає менше, ніж здається. Покрито `ConfigSecurity/*` (8 тестів) і
  `ExitCodes/SecuritySettingsWeakenedPriority`.

  Під час розробки функціональний тест виявив дефект, якого не було б
  видно в рев'ю: `return ,@()` віддає порожній масив як один елемент, і
  зайве `@()` на місці виклику робило з нього масив із порожнім рядком —
  конфігурація, яка взагалі не згадує ці налаштування, помилково
  вважалася послабленою. Обидва місця тепер із поясненням у коді.

- Зовнішнє рев'ю 2026-08-05, P2: [OPERATIONS.md](OPERATIONS.md) —
  операторський runbook. README пояснює, як налаштувати; матриця в
  розділі 12 — де шукати причину. Не було документа, який відповідає на
  питання «зламалось, які дії зараз». Кожен із 12 кодів завершення
  (`20`–`90`) отримав розділ за структурою: симптом, що означає, **чого
  не робити**, команди діагностики, безпечне виправлення, умова
  ескалації. Плюс сценарії поза кодами: розбіжність контекстів
  `SYSTEM`/адміністратора, оновлення `7za`/WinSCP, помилка Discovery,
  ransomware, відновлення на чистий сервер.

  Розділ «чого не робити» — не оформлення, а суть документа. Найдорожча
  помилка в історії репозиторію (порада видалити `TOOLS_INTEGRITY.json`)
  належала саме до цієї категорії, для якої не існувало місця в
  документації. Тому в runbook зафіксовані як заборони: не видаляти
  маніфест і не оновлювати його на сервері (`32`/`33`), не підганяти
  `sftpHostKey` під те, що прийшло по мережі (`50`), не видаляти
  пошкоджений архів — він навмисно лишається для діагностики (`41`), не
  «лікувати» health ручним запуском Archive (`70`), не запускати
  Archive і Maintenance при підозрі на ransomware — вони перезапишуть і
  видалять те, що ще вціліло.

  Покрито самотестами `Documentation/OperationsRunbook*` (наявність,
  повнота за кодами завершення, наявність «чого не робити» щонайменше у
  8 сценаріях, критичні сценарії поза кодами, заборона поради видалити
  маніфест).

- Зовнішнє рев'ю 2026-08-05, P1 «документація не встигає за кодом»:
  - **README описував застарілу модель довіри до `Tools/`.** Розділ 1
    досі подавав trust-on-first-use як основний контроль і радив
    «видаліть `TOOLS_INTEGRITY.json`, щоб прийняти нову базову лінію»,
    хоча код уже блокував запуск за `TOOLS_MANIFEST.json` (код `32`).
    Ризик не теоретичний: адміністратор, який після security-алерту
    сумлінно виконає застарілу інструкцію, власноруч легітимізує
    підмінений бінарник. Розділ переписано під фактичну модель
    (`Enforce`, сторонні DLL, заборона автостворення маніфесту);
    `TOOLS_INTEGRITY.json` лишився описаним, але явно позначений як
    додатковий шар виявлення дрейфу, а не еталон. Охороняється
    самотестами `Documentation/ReadmeDescribesManifestToolTrust` і
    `ReadmeNeverAdvisesDeletingManifest` — другий забороняє будь-яку
    пораду видалити маніфест цілісності.
  - **`SECURITY.md` містив `[заповнити]` замість контакту й SLA.**
    Політика без строків не є політикою. Розділ 2 заповнено конкретним
    каналом (приватний репозиторій — Issue з міткою `security` або
    власник; Security Advisory, якщо репозиторій стане публічним) і
    таблицею строків: підтвердження 2 робочі дні, первинна оцінка 5,
    виправлення критичної вразливості 7–14 календарних днів. Самотест
    `Documentation/SecurityPolicyHasNoPlaceholders` не дає заглушці
    повернутись. Це скасовує свідоме рішення версії 4.2.0 лишити
    заглушки як є.

## 4.3.0 — 2026-08-04

- Аудит P3/P4/P5:
  - **P3.** Усі сторонні GitHub Actions зафіксовані на повний commit SHA
    замість рухомого тега (`@v4` можна переписати, 40-символьний SHA —
    ні). Версія PSScriptAnalyzer закріплена через `-RequiredVersion`,
    інакше нове правило ламає CI без жодної зміни коду. Охороняється
    самотестами `StaticAnalysis/ActionsPinnedToCommitSha` і
    `AnalyzerVersionPinned`.
  - **P4.** `VERSION.json.sourceCommit` — повний 40-символьний git-hash.
    Короткий `buildId` не давав однозначної відповіді, який саме код
    розгорнуто: короткі hash збігаються й погано шукаються в історії.
    `ci\Update-BRAVOVersionStamp.ps1` проставляє обидва поля, зберігаючи
    форматування файлу (`ConvertTo-Json` у PowerShell 5.1 переформатовує
    весь файл і вже ламав самотест).
  - **P5.** [THREAT_MODEL.md](THREAT_MODEL.md) — 9 сценаріїв
    (компрометація адміністратора, підміна Tools і runtime, витік
    credentials, ransomware, VSS, підміна призначення, rollback,
    паралельні запуски), кожен із явним розділом залишкового ризику.
    Найбільший незакритий — ransomware на SFTP-призначення: воно
    доступне на запис тими самими обліковими даними, немає
    immutable-сховища. Самотест вимагає наявності розділу залишкового
    ризику, щоб модель не перетворилась на рекламу.
  - `.gitleaks.toml`: SHA-256 у маніфестах цілісності — не секрети.
    Виняток навмисно вузький (`condition = "AND"`): лише 64-hex, лише в
    двох файлах маніфестів.

- Аудит P2: цілісність усього PowerShell-комплекту, а не лише `Tools/`.
  - `RUNTIME_MANIFEST.json` (version-controlled) — еталонні SHA-256 54
    файлів: `.ps1`, `.psm1`, `.psd1`, `VERSION.json`,
    `TOOLS_MANIFEST.json`.
  - `BRAVO_RUNTIME_GUARD.ps1` — перевірка виконується **до**
    `Import-Module`, тому guard навмисно самодостатній (лише .NET, без
    жодного модуля BRAVO): інакше довелося б завантажити модуль, щоб
    перевірити модулі. Усі три entrypoint dot-source-ять його першим і
    завершуються кодом `33` (`RuntimeIntegrityViolation`).
  - Блокує змінений хеш, відсутній файл і **підкинутий сторонній
    `.ps1`/`.psm1`** — останній може бути dot-source-нутий або
    підхоплений як модуль. Відсутній чи пошкоджений маніфест — теж
    відмова.
  - `ci\Update-BRAVORuntimeManifest.ps1` — оновлення на робочій станції;
    CI-крок «Integrity manifests are current» не дасть змержити
    застарілий маніфест (інакше свіжий комплект заблокував би сам себе).
  - `BRAVO.config` навмисно поза маніфестом (сервер-специфічний), але
    послаблення захисту через нього тепер гучне: усі три runtime пишуть
    `WARNING`, якщо `toolIntegritySettings.Mode` не `Enforce`.
  - Чесні межі задокументовані в `SECURITY.md` 4.1: сам guard і
    entrypoint уже виконуються на момент перевірки — повне закриття
    потребує Authenticode-підпису (P0.3, не реалізовано).

- Рев'ю попереднього кроку виявило дві прогалини в захисті `Tools/` —
  обидві виправлено:
  - **Health більше не запускає інструменти, цілісність яких не
    підтверджена.** Попереднє рішення («Health read-only, тому не
    блокуємо») було обґрунтоване хибно: небезпечний не запис на SFTP, а
    сам запуск `WinSCP.com` / завантаження `WinSCPnet.dll` — підмінений
    бінарник виконує довільний код з правами `SYSTEM` незалежно від
    того, що робить Health. Тепер `Test-SFTPHealthConfiguration`
    пропускає всю SFTP-гілку (єдиний шлях до `Tools/` у Health), а сам
    Health завершується кодом `32`. Локальні перевірки (служби, диски,
    вік копій) інструментів не запускають і виконуються далі.
  - **Сторонній `.exe`/`.dll`/`.com` у `Tools/` тепер блокує запуск** у
    режимі `Enforce`, а не лише повідомляється. Причина — DLL
    side-loading: підміняти `WinSCP.exe` не обов'язково, достатньо
    підкласти DLL з відповідним іменем у той самий каталог, і жоден хеш
    у маніфесті не зміниться. Самотест
    `ToolManifest/UnknownExecutableIsReportedNotBlocking`, який
    закріплював стару поведінку, замінено на
    `ToolManifest/UnknownExecutableBlocksInEnforce` і
    `ToolManifest/UnknownDllBlocksInEnforceWarnsInWarn`.

- Аудит P1 (найнебезпечніший сценарій: підмінений інструмент запускається
  від `NT AUTHORITY\SYSTEM`): цілісність `Tools/` тепер БЛОКУЄ запуск, а
  не лише попереджає.
  - Новий version-controlled `TOOLS_MANIFEST.json` — еталонні SHA-256
    усіх семи виконуваних файлів `Tools/` (не лише `.exe`: підміна
    `7za.dll` не менш небезпечна). Потрапляє на сервер разом з
    комплектом і проходить код-рев'ю як звичайна зміна.
  - `Test-BRAVOToolManifestIntegrity` (`BRAVO.Compatibility`): режим
    `Enforce` (типово) зупиняє Archive і Maintenance з кодом `32`
    (`ToolIntegrityViolation`) і надсилає критичне сповіщення; Health
    як read-only діагностика звітує рівнем `ERROR`, не блокуючи себе.
    Режим `Warn` (`$global:toolIntegritySettings.Mode`) лишає стару
    поведінку для міграції.
  - Маніфест **ніколи** не створюється й не оновлюється автоматично.
    Відсутній, порожній чи пошкоджений маніфест у `Enforce` — теж
    відмова: інакше найпростішим обходом було б просто видалити еталон.
  - Сторонній `.exe`/`.dll`/`.com` у `Tools/` повідомляється окремо, але
    не блокує запуск (може взагалі не використовуватись).
  - `ci\Update-BRAVOToolsManifest.ps1` — оновлення еталона на робочій
    станції; без `-Apply` лише показує розбіжності.
  - Новий код завершення `32` має пріоритет вище за `LockBusy`, щоб
    подія безпеки не губилась у Планувальнику як буденне «зайнято».
  - 11 нових самотестів (`ToolManifest/*`, `Runtime/ToolManifest*`,
    `ExitCodes/ToolIntegrityViolationPriority`), включно з перевіркою,
    що маніфест у репозиторії відповідає реальним `Tools/` — інакше
    свіжий комплект заблокував би сам себе на першому запуску.

- Аудит P1 (PSScriptAnalyzer майже не блокував небезпечні патерни):
  CI блокував лише `Severity=Error`, а `PSAvoidUsingInvokeExpression`,
  `PSAvoidUsingConvertToSecureStringWithPlainText`,
  `PSAvoidUsingUsernameAndPasswordParams` та інші виключались
  **глобально** — тобто новий небезпечний код у будь-якому файлі теж
  мовчки проходив CI.
  - Новий `PSScriptAnalyzerSettings.psd1`: явний блокуючий
    security-набір (`IncludeRules`) + інформаційний прохід для решти.
  - Глобальні `-ExcludeRule` для security-правил прибрані. Натомість
    11 точкових `SuppressMessageAttribute` із `Justification` біля
    конкретних функцій (плюс 3 для хибних спрацювань правила на
    параметрах, чия назва містить «Credential», але які не є секретом).
  - `New-BRAVOPlainTextCredential` (`BRAVO.Credentials`) — блок
    `ConvertTo-SecureString` + `New-Object PSCredential` був
    продубльований у Archive- і Health-runtime; тепер це одна функція з
    одним точковим виключенням замість двох розсіяних.
  - Новий CI-крок «Заборонені патерни»: `Invoke-Expression`/`iex`,
    мережеве завантаження коду (`DownloadString`/`Net.WebClient`),
    секрет у `-ArgumentList`, `ExecutionPolicy Bypass` поза allowlist
    із шести файлів, де він легітимний. Коментарі ігноруються.
  - PSScriptAnalyzer тепер обходить файли поодинці: окремі правила
    здатні кинути `NullReferenceException` на конкретному файлі й
    обірвати весь аналіз, замаскувавши решту знахідок.
  - Побічно виправлено знайдене цим набором: `clear` → `Clear-Host` і
    `$x -ne $null` → `$null -ne $x` (Maintenance), два мертвих
    присвоєння (`$compatibilityIssues` в Archive, `$pendingAge` в
    Health).
  - Самотест: `StaticAnalysis/SecurityRulesAreBlocking`,
    `StaticAnalysis/NoGlobalSecurityRuleExclusions` та ще три —
    охороняють від повернення глобальних виключень.

- Внутрішній код-рев'ю, рефакторинг: `Get-SanitizedWinSCPDiagnostic`
  (маскування паролю/host key у діагностиці WinSCP.com) перенесено зі
  `BRAVO.Archive.Runtime.ps1` у спільний `BRAVO.ArchiveRuntime` — раніше
  функція була продубльована лише в Archive, а `Invoke-WinSCPHealthSession`
  (`BRAVO.Health.Runtime.ps1`) повертав `Output`/`ErrorOutput` без
  санітизації взагалі; тепер обидва runtime використовують одну спільну
  реалізацію, і Health-сесія санітизує результат одразу в джерелі.
- Внутрішній код-рев'ю (не з формального аудиту, точкові виправлення):
  - `Enter-BRAVOWinSCPProcessLock` (`BRAVO.ArchiveRuntime`) тепер приймає
    явний параметр `-LogPath` замість мовчазного покладання на
    `$global:logPath` — якщо модуль колись імпортується до ініціалізації
    конфігу, функція явно повертає помилку замість створення lock-файлу
    у непередбачуваному відносному шляху.
  - `Get-HostInformation` (`BRAVO.Notifications`) логує `WARNING`, якщо
    `$global:hostInformationSettings` взагалі не ініціалізовано — раніше
    public IP lookup тихо трактувався як вимкнений без жодного сліду.
  - `New-BRAVOVSSSnapshotLink` (`BRAVO.Archive.Runtime.ps1`): шляхи для
    `cmd.exe /c mklink` тепер явно квотуються.
  - `BRAVO_ARCHIV.ps1`/`BRAVO_HEALTH.ps1`/`BRAVO_MAINTENANCE.ps1`:
    невдалий `Import-Module` на старті (пошкоджене розгортання) тепер
    завершує процес кодом `90` (`InternalError`) замість довільного
    коду виключення PowerShell — дотримання контракту кодів завершення
    навіть на найранішому етапі entrypoint.

- AUD-001 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md (P0.1): доданий CI —
  `.github/workflows/ci.yml`, `windows-latest` (проєкт цільово Windows
  PowerShell 5.1, не PowerShell 7 — між ними вже траплялись реальні
  поведінкові розбіжності в цьому репозиторії, тому раннер саме
  Windows, кроки через `shell: powershell`). Запускається на кожен
  push і PR у `master`/`developer`: парсинг усіх `.ps1`/`.psm1`/`.psd1`,
  UTF-8 BOM (обов'язковий для PowerShell-файлів, заборонений для
  `.md`), валідність JSON, `PSScriptAnalyzer` (блокує на
  `Severity=Error`, `Warning`/`Information` — інформаційно, кілька
  правил навмисно виключено як такі, що суперечать усталеній
  архітектурі — `PSAvoidUsingWriteHost`/`PSAvoidGlobalVars`), повний
  `BRAVO_SELF_TEST.ps1`, сканування секретів (`gitleaks`, окрема
  Linux-джоба).

  **Явно НЕ зроблено:** GitHub branch protection (required status
  checks, заборона прямого push у `master`) — CI лише показує статус,
  технічно ще не блокує merge, доки власник репозиторію не ввімкне це
  вручну в налаштуваннях GitHub. `SECURITY.md`/`RELEASE_CHECKLIST.md`
  оновлені, щоб чесно відображати цей проміжний стан.

- AUD-016 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md: усунено структурну
  причину повторюваного бага з `releaseChannel`. Раніше значення
  зберігалося як буквальний рядок, що вручну підтримувався різним на
  `master` (`"stable"`) і `developer` (`"development"`) — кожен merge
  `developer` → `master` вимагав окремого follow-up commit; у цій самій
  сесії fast-forward-мержі двічі мовчки протягували значення не в той
  бік (спочатку `"development"` на `master` після мержу PR, потім
  `"stable"` назад на `developer` після виправлення).

  `VERSION.json.releaseChannel` тепер — нейтральний fallback
  (`"stable"`), **однаковий на обох гілках**. Реальний channel визначає
  новий `Resolve-BRAVOReleaseChannelFromGit` (`BRAVO_CONFIG_LOADER.ps1`)
  напряму з `.git/HEAD` (без виклику `git.exe`): `master`/`main` →
  `stable`, `developer` → `development`, будь-яка інша гілка, detached
  HEAD або відсутній `.git` (розгорнутий production-сервер) — fallback
  на статичне значення з `VERSION.json`. Новий `ReleaseChannelSource`
  (`git-branch`/`VERSION.json`/`legacy`) у метаданих версії показує,
  звідки взято ефективне значення.

  Додано self-test `Version/ReleaseChannelResolvedFromGitBranch`
  (`Resolve-BRAVOReleaseChannelFromGit` із синтетичним `.git/HEAD`),
  `Version/DeveloperBranchResolvesToDevelopmentViaGit`,
  `Version/StaticReleaseChannelIsNeutralFallback`.

  Під час розробки виявлено ще один класичний PowerShell-гачок:
  непереданий параметр типу `[string]` дефолтить у `""`, а не `$null` —
  перевірка `if ($null -eq $GitHeadContent)` для визначення "чи викликач
  передав -GitHeadContent явно" завжди була `$false`, тому функція
  ніколи не читала реальний `.git/HEAD`. Виправлено через
  `$PSBoundParameters.ContainsKey('GitHeadContent')`.

- AUD-008 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md (P1.6): sanity-check
  обсягу backup. Технічно валідний архів (7za test + SHA512 збігається)
  все одно може бути підозріло малим через неправильне джерело, зламані
  permissions чи неповний VSS exposure. Нові
  `Test-BRAVOBackupSizeAnomaly`/`Get-BRAVOValidArchiveSizeHistory`
  (`modules\BRAVO.ArchiveHelpers`) порівнюють розмір щойно створеного
  архіву з медіаною останніх валідних (hash-підтверджених) архівів того
  самого компонента; новий `backupMonitoring.SizeSanity` у `BRAVO.config`
  (`Enabled`/`HistoryCount`/`MinimumBytes`/`MaxSizeDropPercent`).
  Перший backup компонента (без історії) не вважається аномалією.
  Виявлена аномалія НЕ блокує backup — лише `WARNING` у журналі й статус
  кроку `Архівація <компонент>` підвищується до `WARNING`, що потрапляє в
  лічильник попереджень і Slack/Discord-сповіщення.

- AUD-004 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md (P0.4): доданий restore
  drill — `BRAVO_RESTORE_TEST.ps1`. Читабельний і навіть SHA-512/7za-
  перевірений архів доводить лише незмінність байтів, не відновлюваність
  системи; новий скрипт бере найновіший локальний backup із коректним
  `.sha512` для кожного увімкненого компонента (`MODEL`/`BLOG`/`BRAVOEXCH`,
  `-Component` для одного або всіх), запускає `7za t` (перевикористано
  `Test-SevenZipArchiveIntegrity`), розпаковує в ІЗОЛЬОВАНИЙ тимчасовий
  каталог (не production-шлях, ACL SYSTEM+Administrators+поточний
  користувач, видаляється одразу після перевірки — навіть при помилці,
  через `finally`), звіряє кількість розпакованих файлів проти
  `-MinimumFileCount` і повертає контрактний exit code (`0`/`10`/`41`)
  та машинно-читаний JSON (`-ResultPath`/`-AsJson`). Сповіщення в
  Slack/Discord — лише при `WARN`/`FAIL`, якщо не задано
  `-SkipNotification`. Read-only діагностика: не видаляє, не переміщує й
  не змінює жоден існуючий backup, елевація не потрібна.

  Новий спільний компонент `Invoke-BRAVOSevenZipExtraction`
  (`modules\BRAVO.Compatibility`) — розпакування архіву, дзеркалить уже
  наявний `Invoke-BRAVOSevenZipIntegrityTest` (той самий
  ProcessStartInfo/stdin-пароль патерн, пароль ніколи не потрапляє до
  командного рядка чи логів).

  Restore drill НЕ входить до типового набору завдань
  `BRAVO_TASKS_INSTALL.ps1` — рекомендовано (розділ 6.1 README.md)
  додати окреме щотижневе/щомісячне завдання Планувальника вручну.

- AUD-007 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md (P1.1/P1.2): захист від
  неоднозначного й дрейфового discovery. `Resolve-BRAVOInstallationDiscovery`
  тепер позначає `Ambiguous.BravoRoot`/`Ambiguous.WebRoot`, якщо знайдено
  кілька служб BRAVO/Apache із РІЗНИМИ виконуваними файлами (ознака
  stale/дублюючої інсталяції) — `Test-BRAVODiscoveryResult` блокує
  валідацію для будь-якого увімкненого компонента, що залежить від
  неоднозначного кореня. Додано `Save-BRAVODiscoveryBaseline` і
  `Compare-BRAVODiscoveryBaseline`: `BRAVO_SETUP.ps1 -ValidateOnly`
  порівнює поточний discovery-результат зі збереженим
  `LOGS\DISCOVERY_BASELINE.json` (поза git) і повідомляє про дрейф
  джерел відносно останнього підтвердженого запуску (лише попередження,
  не блокує); новий switch `-ConfirmDiscoveryBaseline` явно фіксує
  поточний результат як baseline.

  Під час розробки виявлено й виправлено реальний баг у самому модулі
  `BRAVO.Discovery`: ідіома `return ,@($collection.ToArray())`
  (застосована раніше для фіксу розгортання 1-елементного масиву в
  скаляр під Set-StrictMode -Version 2.0 на Windows PowerShell 5.1) при
  ПОРОЖНІЙ колекції створює масив з ОДНИМ елементом-порожнім-масивом, а
  не порожній масив — той самий клас бага, лише в інший бік. Спроба
  виправити через `Write-Output -NoEnumerate` натомість ламала виклики,
  де результат додатково обгортається `@(...)` на боці клієнта
  (подвійне обгортання). Остаточне рішення: звичайний `return
  $collection.ToArray()` у `Test-BRAVODiscoveryResult` і
  `Compare-BRAVODiscoveryBaseline`, а всі точки виклику (в
  `BRAVO_SETUP.ps1` і `BRAVO_SELF_TEST.ps1`) уніфіковано завжди
  обгортають виклик `@(...)` — єдиний послідовний контракт, який
  коректно повертає масив для 0, 1 і N елементів незалежно від стилю
  виклику.

- AUD-017 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md: виправлено застарілий
  рядок у `SECURITY.md` (розділ 8), який стверджував, що
  `RELEASE_CHECKLIST.md` "наразі не існує" — файл вже доданий раніше
  (P2.6). Розділ 8 тепер лише чесно перелічує те, що справді ще не
  реалізовано (threat model, CI/CD gate, SFTP/SMB key auth,
  `AppLocker`/`WDAC`/`gMSA`), без згадки вже виконаних пунктів.
  Контакт і SLA в розділі 2 (`[заповнити]`) свідомо лишені як є —
  власник репозиторію ще не надав реальні значення.

- CLAUDE_CODE_TZ_ARCHIV_LIMS_MONOLITH.md: визначення джерел резервного
  копіювання (`MODEL`, `BLOG`, `BRAVOEXCH`, `BAZA_APP`, `BAZA_WWW`,
  `BRAVO_ROOT`, `WEB_ROOT`) тепер відбувається автоматично на основі
  активної інсталяції BRAVO (служба `BRAVO`, служба Apache, файл
  `bravo.ini`), з повним ручним перевизначенням через
  `$global:discoverySettings` у `BRAVO.config`. Новий модуль
  `modules\BRAVO.Discovery\` (`Get-BRAVOServiceExecutablePath`,
  `Find-BRAVOServiceByCandidates`, `ConvertFrom-BRAVOIniFile`,
  `Resolve-BRAVOInstallationDiscovery`, `Test-BRAVODiscoveryResult`)
  реалізує пріоритетний ланцюг: явний override → значення з `bravo.ini`
  → попередня LIMSRoot-відносна поведінка (legacy fallback) — 100%
  зворотної сумісності для інсталяцій без служби BRAVO/Apache або без
  `bravo.ini`. Слабка евристика `Find-BRAVOExchSourceDirectory`
  (фіксований список кандидатів) замінена: значення з `bravo.ini`
  (`BEXCH=`) тепер має найвищий пріоритет, а старі жорстко задані
  кандидати (`exchangAPI`, `bravoexch`, `C:\bravoexch`) лишаються лише як
  запасний варіант. `Archive.Runtime.ps1`/`Health.Runtime.ps1`/
  `Maintenance.Runtime.ps1` не змінювались — вони читають ті самі
  глобальні змінні (`$global:sourcePaths`, `$global:bazaPaths` тощо), які
  тепер заповнюються результатом discovery замість прямих обчислень.

  `BRAVO_SETUP.ps1 -ValidateOnly` виводить новий розділ
  `=== DISCOVERY ДЖЕРЕЛ ===` (знайдені служби, шлях `bravo.ini`, кожне
  джерело з поясненням походження значення) і викликає
  `Test-BRAVODiscoveryResult` для перевірки увімкнених джерел і
  каталогів призначення — без аварійного завершення самого wizard.
  `BRAVO.config` свідомо НЕ виконує жорстку валідацію (throw) при
  звичайному завантаженні: увімкнені за замовчуванням компоненти
  (`MODEL`/`BLOG`/`BRAVOEXCH`) на сервері без реальної інсталяції LIMS
  зламали б кожен виклик `Import-BravoConfiguration`, включно з
  `BRAVO_SELF_TEST.ps1`.

  Додано self-test `Discovery/IniParserHandlesRealBravoIniFormat`,
  `Discovery/ResolvesFromServiceAndIniWithoutOverride`,
  `Discovery/ExplicitOverrideWinsAndIsNeverReplaced`,
  `Discovery/LegacyFallbackWhenNoServiceFound`,
  `Discovery/ValidationDetectsMissingEnabledSourceOnly`,
  `Discovery/WiredIntoConfigLoaderAndSetup`.

  Під час розробки `Test-BRAVODiscoveryResult` спершу повертав масив
  помилок через `return @($errors)`, що на Windows PowerShell 5.1 і
  `Set-StrictMode -Version 2.0` розгортається пайплайном у скаляр при
  рівно одному елементі — виклик `.Count` на такому скалярі (рядку) падав
  з `PropertyNotFoundStrict`, бо `String` не має `.Count` до PowerShell 7.
  Виправлено уніарною комою (`return ,@($errors.ToArray())`), що
  гарантує повернення масиву незалежно від кількості елементів.

## 4.2.13 — 2026-08-04

- P2.7 з плану виправлень: виправлено дрібні зауваження документації.
  README.md більше не має дубльованого рядка-заглушки `BRAVO_*.ps1` у
  дереві каталогів (розділ 2) — дерево тепер перелічує реальні файли
  комплекту, включно з `SECURITY.md`/`RELEASE_CHECKLIST.md`/`VERSION.json`
  і каталогом `modules`. Додано матрицю діагностики за кодом завершення
  (розділ 12): для кожного коду (`20`–`90`) — найімовірніша причина і де
  саме в журналі шукати деталі, доповнює вже наявну таблицю значень
  кодів і `LastTaskResult` Task Scheduler. Пункти аудиту про lifecycle
  `.partial`, manifest архіву й restore drill свідомо НЕ додано до
  README — ці функції ще не реалізовані (P1.4/P1.5/P0.5), документувати
  їх як наявні означало б написати неправду; прогалини вже чесно
  перелічені в `SECURITY.md`/`RELEASE_CHECKLIST.md`. Опис підтримуваних
  версій ОС і чітке розділення development/stable вже було зроблено
  раніше (P0.4/P0.6) — цей пункт лише перевірено, без змін.

  Під час розробки матриці власний новий self-test спершу хибно падав
  через несподіваний артефакт: у PowerShell зворотна лапка `` ` `` є
  символом екранування навіть у звичайному подвійному рядку, тому
  `"| `31` |"` тихо перетворювалось на `"| 31 |"` (без лапок) ще на
  етапі парсингу — Contains-перевірка порівнювала вже спотворений
  рядок і завжди повертала false. Виправлено переходом на одинарні
  лапки для цього шаблону.

- P2.6 з плану виправлень: додано `RELEASE_CHECKLIST.md`. Розділ 1 —
  пункти, які реально виконуються сьогодні й частина яких уже забезпечена
  self-test (`Version/ModuleManifests`, `Version/BuildIdSurfacedInRuntimes`,
  `Version/StableBranchNotDevelopmentChannel`). Розділ 2 — свідомо окремо
  винесені рекомендації аудиту, які в цьому репозиторії ще не
  автоматизовано (PSScriptAnalyzer, secret scanning, підписаний release
  manifest, restore drill тощо) — не позначені чекбоксами обов'язкового
  виконання, щоб чек-лист не створював хибного враження виконаної роботи.
  Додано self-test `Documentation/ReleaseChecklistExists` і
  `Documentation/ReleaseChecklistCoversRequiredSteps`.

- P2.4 з плану виправлень: додано `SECURITY.md` — підтримувані версії
  (продукт і ОС/PowerShell), порядок повідомлення про вразливості, модель
  секретів (Credential Manager, `Protect-BRAVOLogSecret`, очищення
  script-scope змінних), модель довіри до Tools (TOFU, чесно
  задокументовані відсутні Authenticode/Fail-режим/підписані завдання),
  модель ACL, обмеження Credential Manager (прив'язка до облікового
  запису, відсутність gMSA), політика оновлення. Документ описує
  фактичний поточний стан, включно з відомими незакритими прогалинами —
  не видає заплановане за вже реалізоване. Секції SLA/контакту для
  повідомлення про вразливості лишено як явний placeholder для власника
  репозиторію. Додано self-test `Documentation/SecurityMdExists` і
  `Documentation/SecurityMdCoversRequiredSections`.

- P1.6 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`): Health
  тепер окремо повертає `LocalVerified`/`SftpVerified`/`SmbVerified` у
  result object (усі 7 гілок `return Complete-BRAVOHealthResult`), а не
  лише агрегований `Status`/`IssueCount` — зовнішній моніторинг більше не
  втрачає деталізацію "локальні копії в порядку, а SFTP деградував" за
  єдиним `Status = "Critical"`. Кожен напрямок обчислюється незалежним
  викликом (`Get-BackupHealthIssues`/`Get-BAZALocalHealthIssues`/
  `Get-SFTPHealthIssues`/`Get-SMBHealthIssues`) — жоден не перериває
  виконання інших при відмові, тому сам механізм перевірок не
  редагувався, лише додано `Get-BRAVOHealthDestinationSummary`, яка
  зводить уже наявні незалежні списки issues у три прапорці. Додано
  self-test `Health/DestinationSummaryAlgorithm` (функціональний, на
  синтетичних issues) і `Health/DestinationSummaryWiredIntoAllResults`
  (текстовий, підтверджує підключення до всіх 7 місць повернення).

- P1.8 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  `BRAVO_OPERATION.lock` (спільний exclusive-lock Archive/Maintenance)
  тепер містить структуровані JSON-метадані замість голого
  `"PID=...; Started=...; Config=..."`: `pid`, `processStartTime`
  (реальний час старту процесу з `Get-Process`, не лише PID — відрізняє
  той самий PID, перевикористаний після перезавантаження сервера, від
  справді активного запуску), `hostname`, `operation`
  (`Archive`/`Maintenance`), `startedAt`, `packageVersion`, `config`.
  Сам механізм lock не змінено — це вже реальний ексклюзивний файловий
  handle (`FileShare.None`), який Windows звільняє автоматично при
  аварійному завершенні процесу, тому окремої перевірки "живий PID перед
  видаленням stale lock" не було потрібно, на відміну від класичних
  PID-файлів. Додано self-test `Scheduler/OperationLockMetadata`.

- P1.9 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  катастрофи ErrorRecord навколо завантаження `BRAVO.config` і читання
  Credential Manager (SFTP/SMB/архів/webhook) в Archive/Health/Maintenance
  друкували `$_.Exception.Message` через `Write-Host`/`Write-Error`
  напряму в консоль, минаючи єдину точку масковки секретів
  (`Write-Log`/`Write-BRAVOLog`/`Write-HealthLog`, яка вже маскує
  `Protect-BRAVOLogSecret`). Тепер ці catch-блоки маскують повідомлення
  винятку одразу при захопленні — так безпечним лишається кожне подальше
  читання відповідних script-scope змінних (`credentialInitializationError`,
  `archiveCredentialInitializationError`, `smbCredentialInitializationError`,
  `notificationCredentialInitializationError`,
  `ArchiveCredentialError`/`NotificationCredentialError` у Maintenance), а
  не лише перший вивід. Додано self-test
  `Runtime/CredentialAndConfigErrorsMaskedAtCapture`.

- P1.10 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  `hostInformationSettings.PublicIPLookupEnabled` у `BRAVO.config` тепер
  `$false` за замовчуванням — раніше кожен запуск Health/Maintenance
  звертався до `api.ipify.org`/`checkip.amazonaws.com`, зайвої зовнішньої
  залежності, яка розкриває стороннім сервісам факт і час запуску backup.
  Внутрішній fallback у `Get-HostInformation` (`BRAVO.Notifications`) на
  випадок відсутньої конфігурації узгоджено з тим самим `$false`. Якщо
  вимкнено, `Get-HostInformation` не робить жодного мережевого запиту й
  одразу повертає `PublicIP = "вимкнено"`. Додано self-test
  `Notifications/PublicIPLookupDisabledByDefault`.

- P0.4 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  формалізовано мінімально підтримувану ОС трьома рівнями — Supported
  (Windows Server 2019+, Windows 10/11, PowerShell 5.1), Legacy best-effort
  (Server 2012 R2, Server 2016, без гарантій) і Unsupported (Windows 7,
  Server 2008 R2, PowerShell 3.0). Раніше README декларував єдиний
  розмитий baseline "Windows 7 / Server 2008 R2 або новіша", без жодної
  різниці в поведінці між дуже старою й сучасною системою. Нова
  `Get-BRAVOOSSupportTier` (`BRAVO.Compatibility`) визначає рівень при
  кожному запуску Archive/Health/Maintenance і завжди пише в журнал точну
  версію ОС, build, PowerShell і .NET, незалежно від рівня. `Legacy
  best-effort` лише попереджає; `Unsupported` блокує production-запуск
  (код `30`, `InvalidConfiguration`) — продовжити свідомо можна лише через
  явний override `BRAVO_ALLOW_UNSUPPORTED_OS=1` в середовищі процесу.
  Для Health, яка може викликатися програмно через dot-source
  (`Invoke-BRAVOHealthCheck`), заборона повертається як звичайний
  `Status = "ConfigurationError"`, а не через `exit`, щоб не завершувати
  процес виклика́ча. Додано функціональні self-test на синтетичних
  Win32_OperatingSystem-подібних даних (Get-BRAVOOSSupportTier не можна
  протестувати на реальній іншій ОС) і текстову перевірку підключення
  guard-у в усі три runtime.

- P1.7 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  `Remove-OldBackupSets` більше не може видалити останню перевірену
  копію компонента. Раніше retention був прив'язаний лише до календарного
  віку (`archiveRetentionDays`) — серія невдалих backup, після якої всі
  ще валідні (SHA512 збігається) комплекти виявились старшими за retention,
  могла видалити їх усі й лишити компонент без жодної придатної копії.
  Новий `BRAVO.config`-параметр `minimumRetainedVerifiedBackups`
  (за замовчуванням `1`) захищає N найновіших перевірених комплектів від
  видалення незалежно від віку; список кандидатів на видалення будується
  через `Select-Object -Skip $minimumRetainedCount` на вже відсортованому
  за спаданням часу списку. Додано текстову перевірку self-test, що
  підтверджує підключення механізму в реальний код, і окрему функціональну
  перевірку алгоритму відбору на синтетичних даних (Archive.Runtime.ps1
  безумовно запускає `Main` при dot-source, тому саму функцію в self-test
  безпечно викликати не можна).

- Упорядковано release channels (P0.6 з плану виправлень
  `ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`): `VERSION.json.releaseChannel`
  тепер відповідає гілці — `development` на `developer`, `stable` на
  `master`. Додано self-test `Version/StableBranchNotDevelopmentChannel`,
  який визначає поточну git-гілку і забороняє `releaseChannel=development`
  на `master`/`main`; перевірка м'яко пропускається, якщо `.git`
  недоступний (розгорнутий release-пакет без клону репозиторію). У
  README задокументовано відповідність гілка → канал.

- Повторний аудит (`ARCHIV_LIMS_MONOLITH_REPEAT_AUDIT.md`, P1) вказав: після
  релізного коміту `v.4.2.12` у код внесено суттєві зміни (StrictMode-фікси,
  VSS exposure, ACL runtime, нове логування, маскування секретів, integrity
  preflight, формальна модель exit code, класифікація restore errors,
  виправлення тегів журналу), але `VERSION.json` і всі 13 module manifests
  продовжували показувати `4.2.12` — дві збірки з однаковим номером версії
  могли мати різний код і різну поведінку.
- `VERSION.json` отримав нове обов'язкове для нових релізів (але не для
  вже розгорнутих старих копій) поле `buildId` — короткий git-hash коміту,
  з якого зібрано випуск. `Get-BravoVersionMetadata`
  (`BRAVO_CONFIG_LOADER.ps1`) читає його як необов'язкову властивість,
  щоб оновлення поверх старішого `VERSION.json` без `buildId` не ламалось.
  Значення прокидається як `$global:ScriptBuildId`, той самий шаблон, що
  вже використовувався для `ScriptVersion`/`ScriptDate`.
- Archive, Health і Maintenance тепер показують build ID у консолі/журналі
  та в Slack/Discord-сповіщеннях поруч з версією й датою (`Версiя та дата
  скрипта: 4.2.13 вiд 2026-08-04` + окремий рядок `Збірка (build): ...` в
  Archive; `(build ...)` у сповіщеннях Health і Maintenance).
- `ModuleVersion` усіх 13 module manifests і версія в заголовках `README.md`
  та `BRAVO_SETUP.md` синхронізовано з `VERSION.json` (`4.2.13`).
- Додано self-test `Version/BuildIdSurfacedInRuntimes` (build ID справді
  прокидається у всі три runtime) і розширено `Version/AuthoritativeLoader`
  перевіркою, що `ScriptBuildId` відповідає `buildId` у `VERSION.json`.

## 4.2.12 — 2026-08-03

- Виправлено хибне тегування підсумкового рядка `Результат:` у
  `BRAVO_ARCHIV`: заголовок секції health-check (`=== ПЕРЕВІРКА СТАНУ
  РЕЗЕРВНИХ КОПІЙ ===`) виставляв компонент журналу на `HEALTH` і нічого не
  повертало його назад на `SUMMARY`, тому фінальний рядок з результатом
  усього запуску потрапляв у лог під тегом `[HEALTH]` навіть тоді, коли
  сам health-check пройшов успішно, а `ПОМИЛКА` була викликана чимось
  іншим (наприклад провалом перевірки цілісності одного з архівів). Тепер
  `Set-BRAVOLogComponent -Component 'SUMMARY'` явно виставляється перед
  цим рядком.

- Формальний контракт кодів завершення (`modules/BRAVO.ExitCodes`): замість
  `0`/`1` Archive, Health і Maintenance тепер повертають одне з `0`
  (успішно), `10` (успішно з попередженнями), `20` (пропущено — lock
  зайнятий), `30` (некоректна конфігурація), `31` (немає credentials),
  `40` (помилка локальної архівації), `41` (не підтверджено цілісність),
  `50` (SFTP failed), `51` (SMB failed), `60` (Maintenance failed), `70`
  (Health critical), `90` (внутрішня непередбачена помилка). Дозволяє
  зовнішньому моніторингу (Task Scheduler history, Zabbix) розрізняти
  причину збою, а не лише факт його наявності. При одночасних відмовах
  переможець визначається пріоритетом (lock > config > creds > local
  archive > integrity > SFTP > SMB > maintenance > health > warnings).
  Заразом узгоджено: Archive більше не трактує статуси Health `Disabled`/
  `Deferred` як власну відмову — сам Health вважає їх безпечними. Maintenance
  також розрізняє `40`/`41` для власних операцій відновлення: помилка
  створення/розпакування локального архіву (`Restore-FromArchive`, попередній/
  контрольний архів навколо відновлення) повертає `40`, а провал 7-Zip test /
  SHA512-звірки чи розбіжність розміру файлів — `41`; решта відмов Maintenance
  (сервіси, диск, файлове господарство, оркестрація BRAVO_ARCHIV) лишаються
  спільним `60`, як і раніше.
- Runtime Archive, Health і Maintenance та спільні бібліотеки перенесено до
  versioned PowerShell-модулів у каталозі `modules`; task-entrypoint-и залишено
  тонкими стабільними wrappers.
- `BRAVO.ArchiveHelpers` отримав явний logger callback і більше не залежить від
  приватного `Write-Log` caller-а; додано runtime smoke-test цієї межі модуля.
- Програмний Health API гарантовано очищає SFTP/SMB credential state у `finally`.
- Пошук WinSCP .NET components і перевірку цілісності 7-Zip централізовано у
  спільних модулях без дубльованих реалізацій у domain runtime.
- Процедуру оновлення змінено на атомарну заміну всього комплекту разом із
  каталогом `modules`; опис передачі пароля 7-Zip синхронізовано з реалізацією.
- Виправлено конфігурацію SFTP, яка падала на кожному запуску: `$sftpHost`
  ніде не присвоюється, а централізований завантажувач конфігурації привніс
  `Set-StrictMode`, тому звернення до неоголошеної змінної стало помилкою.
  Archive, Health і dry-run тепер читають legacy-змінні через `Get-Variable`.
- Тим самим способом полагоджено legacy-гілки `$archiveVersions` (строк
  зберігання архівів) і `$networkCopyConfig` (шлях SMB у dry-run): раніше вони
  не могли спрацювати й обривали відповідну перевірку.
- VSS-архівація більше не передає 7-Zip шлях `\\?\GLOBALROOT\Device\...`,
  який .NET не читає: знімок експонується через каталогове символічне
  посилання, що прибирається разом зі знімком.
- Завантажувач конфігурації читає `VERSION.json` і `BRAVO.config` явно як
  UTF-8, попереджає про розбіжність версій між ними і вимагає, щоб файл
  конфігурації лежав усередині каталогу конфігурації.
- Версію в `README.md` і `BRAVO_SETUP.md` синхронізовано з `VERSION.json`.
- Прибрано `REMOVE_OLD_ARCHIV_LIMS.ps1` разом із блоком `Cleanup/*` у
  самотесті, який безумовно читав цей файл і через це падав.
- Виправлено аудит P1 (ненадійний `$LASTEXITCODE`): у `Archive.Runtime.ps1`
  повторний `throw` усередині `catch { $script:processExitCode = 1; throw }`
  ніколи не доходив до власного `Exit` runtime, і код виходу процесу
  визначала загальна поведінка PowerShell на необроблену помилку, а не
  керована логіка BRAVO. Усі три `.psm1`-обгортки (Archive/Maintenance/
  Health) тепер викликають runtime у `try/catch`: на непередбаченому
  винятку повертається керована `1` (пізніше синхронізовано з новим
  контрактом exit code — див. вище), повідомлення виводиться через
  `Write-Error`.
- Маскування секретів (`Protect-BRAVOLogSecret`) поширено з Archive також
  на Health (`Write-HealthLog`) і Maintenance (`Write-Log`): раніше вони
  писали повідомлення без маскування, і виняток WinSCP чи webhook-запиту
  міг потрапити в лог/консоль разом з обліковими даними. Заразом
  виправлено дві прогалини самого `Protect-BRAVOLogSecret`: Slack/Discord
  webhook URL не маскувались зовсім, а коротка форма пароля 7-Zip (`-p`)
  повторно "з'їдала" вже замасковане правило `-password=***`.
- Додано integrity preflight для інструментів у `Tools`
  (`7za.exe`, `WinSCP.com`, `WinSCPnet.dll`): `Get-BRAVOToolIntegrityRecommendation`
  (`BRAVO.Compatibility`) за моделлю trust-on-first-use на першому запуску
  фіксує SHA-256 кожного наявного інструмента в `Tools\TOOLS_INTEGRITY.json`,
  а на кожному наступному звіряє і лише попереджає при розбіжності —
  виконання свідомо не блокується, підміна файлу могла бути легітимним
  оновленням. Підключено в Archive/Health/Maintenance поруч із наявними
  рекомендаціями про PowerShell і Windows.

## 4.2.11 — 2026-08-03

- `BRAVO_SETUP -ValidateOnly` більше не запитує UAC: режим виконує лише
  read-only перевірки.

## 4.2.10 — 2026-08-03

- WinSCP process lock інтегровано у спільний compatibility runtime; прибрано
  дубльовані `Start/Complete-BRAVOProcessOutputCapture` з SFTP runtime.

## 4.2.9 — 2026-08-03

- Standalone `BRAVO_HEALTH` підключає SFTP runtime з перевіркою активного
  WinSCP та process lock, тому SFTP health-check не залежить від архіватора.

## 4.2.8 — 2026-08-03

- Інтервал health-check тепер визначається лише `BRAVO.config` (240 хвилин);
  інсталятор Планувальника більше не змінює його неявно.
- Перевірка активного WinSCP використовує спільний WMI/CIM fallback і працює
  на підтримуваних старих версіях Windows PowerShell.

## 4.2.7 — 2026-08-03

- Health-перевірку винесено з `BRAVO_ARCHIV.ps1` у самостійний
  `BRAVO_HEALTH.ps1`; Планувальник запускає його напряму.
- `BRAVO_ARCHIV` після backup викликає спільний health runtime, а застарілий
  параметр `-HealthCheckOnly` лише сумісно перенаправляє до нового скрипта.
- Health runtime підключає `BRAVO_COMPATIBILITY.ps1` і
  `BRAVO_CREDENTIALS.ps1`, не дублюючи їхню функціональність.
- `BRAVO_ARCHIV` і `BRAVO_MAINTENANCE` також переведено зі вбудованих копій
  compatibility/credentials на спільні файли. Специфічний WinSCP lock
  архіватора винесено до `BRAVO_ARCHIV_RUNTIME.ps1`.

## 4.2.6 — 2026-08-03

- Планувальні завдання `BRAVO_ARCHIV` і `BRAVO_MAINTENANCE`, запущені від
  `SYSTEM`, більше не намагаються відкрити інтерактивний UAC (`RunAs`). Це
  усуває код результату Планувальника `0x80070001` / `2147942401`.
- Додано регресійну перевірку, що обидва сценарії розпізнають SID LocalSystem
  `S-1-5-18` і не запускають UAC у цьому контексті.

## 4.2.5 — 2026-08-03

- Runtime ACL тепер застосовується рекурсивно до наявних файлів і папок перед
  реєстрацією SYSTEM-завдань.
- Усі BRAVO-утиліти використовують спільний loader конфігурації; VETOFFICE
  залишається окремим legacy-шляхом.
- Усунуто колізію імен у credentials-утиліті з функцією loader-а PowerShell.
- Версію та дату релізу централізовано у `VERSION.json`; усунено розбіжність
  документації з фактичною періодичністю health-check.

## 4.2.4 — 2026-08-03

- Виправлено виклики централізованого завантажувача конфігурації в обох
  entrypoint-ах `BRAVO_ARCHIV.ps1`: тепер вони передають обов'язковий
  параметр `-ConfigRoot`.
- `BRAVO_TASKS_INSTALL.ps1` і `BRAVO_SELF_TEST.ps1` переведено на спільний
  `BRAVO_CONFIG_LOADER.ps1`; додано регресійну перевірку контракту loader-а.
- Прибрано хибне попередження про розбіжність версій, коли legacy-версія в
  `BRAVO.config` навмисно відсутня.

## 4.2.1 — 2026-07-30

### Узгодженість резервних копій

- Щоденні архіви `MODEL`, `BLOG` і `BRAVOEXCH` тепер створюються з окремих
  моментальних VSS-знімків локальних томів у контексті `ClientAccessible`.
- `BRAVO_ARCHIV` не зупиняє служби під час backup. Якщо VSS-знімок створити
  неможливо, компонент завершується з помилкою без небезпечного переходу до
  архівації live-каталогу.
- Після штатного завершення або обробленої помилки компонента VSS-знімок
  видаляється у `finally`; окремо обробляються та журналюються коди помилок
  створення й очищення VSS.
- У `BRAVO.config` додано обов'язковий блок `backupConsistency`; self-test
  перевіряє режим `VSS`, контекст і побудову шляху `GLOBALROOT`.

### SFTP-синхронізація BAZA

- Режим `-SyncBAZA` синхронізує всі увімкнені джерела `BAZA_APP` і
  `BAZA_WWW`, окремо перевіряє їхні локальні шляхи та повертає загальний
  результат виконання.
- Webhook Slack/Discord завантажується також у режимі `-SyncBAZA`; виправлено
  ситуацію, коли налаштований webhook ставав порожнім через область видимості
  змінної.
- Несумісні з обмеженням WinSCP імена визначаються до синхронізації за
  фактичною довжиною UTF-8. Сумісні файли передаються, а несумісний залишок
  класифікується як завершений `degraded`-результат без марного повтору всього
  backup.
- Аудит до й після синхронізації розділяє передані, retryable та несумісні
  об'єкти; журнал пояснює, коли повторний запуск не потрібен.
- Сповіщення про несумісні імена містить установу, машину, IP-адреси, версію,
  час, ліміт WinSCP, п'ять читабельних прикладів і шлях до повного журналу.
- Імена в Discord екрануються як literal text і виводяться кожне з нового
  рядка без злиття через Markdown. Довгі повідомлення розбиваються на частини
  до 1900 символів.
- Виправлено граничний підрахунок Windows `CRLF`: двосимвольне перенесення
  рядка більше не створює Discord-повідомлення довжиною 1901 символ.

### Health-звіти

- У локальних і хмарних секціях health-звіту показується ім'я останнього
  архіву разом із віком і розміром.
- Ім'я локального еталонного архіву додається не лише до простроченої
  SFTP-копії, а й до повідомлень про відсутній файл, невідповідний розмір та
  інші помилки віддаленої копії.
- Символи Markdown у назвах файлів екрануються лише для Discord; Slack
  отримує початкове ім'я без зайвих зворотних рисок.

### Захист секретів і тимчасових файлів

- Пароль 7-Zip більше не додається до командного рядка процесу. Створення,
  перевірка та розпакування архівів передають пароль через `stdin` у
  `BRAVO_ARCHIV`, `BRAVO_MAINTENANCE`, `ARCHIV_VETOFFICE` і спільному модулі
  сумісності.
- Заборонено лише паролі з символами нового рядка; подвійні лапки більше не
  потребують вставлення або маскування в process arguments.
- Тимчасові WinSCP-скрипти `BRAVO_ARCHIV` і `ARCHIV_VETOFFICE` створюються
  атомарно з GUID-іменами та захищеним ACL лише для поточного користувача,
  `SYSTEM` і `Administrators`.
- Перед видаленням конфіденційний тимчасовий файл очищується. Шлях
  перевіряється на належність системному temp-каталогу, а застарілі файли
  прибираються під час наступного запуску.
- SYSTEM-worker налаштування Credential Manager працює без `Write-Host`, коли
  немає інтерактивної консолі.

### Maintenance, setup і очищення

- Журнал maintenance має однозначне ім'я
  `BRAVO_MAINTENANCE_yyyyMMdd_HHmm.log`; очищення журналів підтримує новий і
  попередній формати назв.
- Планову реставрацію перенесено із середи `00:20` на неділю `03:00`;
  startup-recovery пропущеного запуску збережено.
- `BRAVO_SETUP.ps1` очікує підтвердження перед закриттям інтерактивного вікна;
  для автоматизованого запуску додано `-NoPause`, який зберігається після UAC
  elevation.
- Додано кероване очищення повних пар обідніх архівів `_1300.mdz` і
  `.sha512` за календарним віком. Очищення вимкнене за замовчуванням,
  перевіряє containment каталогу та не видаляє неповні комплекти.
- Додано окремий `REMOVE_OLD_ARCHIV_LIMS.ps1` із підтримкою `-WhatIf`,
  параметрами шляху, каталогів, строку зберігання й каталогу журналів.
  Часткові помилки, відсутні або небезпечні каталоги повертають exit code `1`;
  успішне виконання повертає `0`.

### Перевірки та документація

- `BRAVO_SELF_TEST` розширено зі статичного аналізу до static + runtime:
  фактично створюється й перевіряється зашифрований 7-Zip-архів із паролем
  через `stdin`.
- Додано runtime-перевірки Discord escaping і chunking, degraded-результату
  BAZA, VSS-шляху, ACL та видалення WinSCP-файлів, а також exit codes
  cleanup-скрипта.
- Статичні перевірки блокують повернення пароля 7-Zip до process arguments,
  live-архівацію без VSS, повторне використання небезпечних temp-файлів та
  втрату імен архівів у health-звіті.
- Dry-run, README і setup-документацію синхронізовано з VSS-вимогами, новими
  параметрами та єдиною версією `4.2.1`; згадку видаленого
  `QuiesceForBackup` прибрано з preflight-звіту.

## 4.2.0 — 2026-07-30

- Єдина версія та дата релізу зберігаються у `BRAVO.config` і додаються до повідомлень архівації, обслуговування та dry-run.
- Health-звіт показує лише увімкнені компоненти резервного копіювання, включно з окремими каталогами `BAZA_APP` і `BAZA_WWW`.
- Коректні комплекти резервних копій очищуються за календарним віком; типовий строк — 183 дні.
- Додано атомарне блокування запусків WinSCP та повідомлення про несумісні імена BAZA.

## 4.9.2 — 2026-07-27

- `BRAVO_ARCHIV` більше не зупиняє і не запускає Windows-служби за жодних
  налаштувань: він лише читає їхній стан, пише його в журнал і надсилає
  попередження, якщо служба не працює.
- Видалено `QuiesceForBackup`, функції керування службами та блок
  stop/start навколо створення архівів. Керування службами залишається лише у
  `BRAVO_MAINTENANCE`.
- Self-test перевіряє відсутність `Stop-Service`, `Start-Service` і колишніх
  функцій керування службами у `BRAVO_ARCHIV`.
- Версія конфігурації: 4.9.2; BRAVO_ARCHIV: 4.0.2;
  BRAVO_MAINTENANCE: 1.7.1.

## 4.9.1 — 2026-07-27

- `BRAVO_ARCHIV` і `BRAVO_MAINTENANCE` до зупинки служб перевіряють їхній
  початковий стан та негайно надсилають одне зведене попередження у Slack/Discord,
  якщо одна або кілька керованих служб не працюють.
- Погодинний `BRAVO_ARCHIV_HEALTH` також контролює встановлені служби з типом
  запуску, відмінним від `Disabled`; активний operation lock запобігає хибним
  тривогам під час штатного backup/maintenance.
- Негайне попередження основних скриптів надсилається також у режимі
  `errors_only`, але саме по собі не змінює їхній exit code: початково зупинені
  служби не запускаються автоматично після backup/maintenance.
- Додано спільний HTTPS webhook-клієнт і статичні self-test перевірки цього сценарію.
- Версія конфігурації: 4.9.1; BRAVO_ARCHIV: 4.0.1;
  BRAVO_MAINTENANCE: 1.7.1.

## 4.9.0 — 2026-07-27

- Marker успішної реставрації MODEL тепер створюється атомарно в UTF-8 без BOM
  замість системного ANSI-кодування Windows PowerShell.
- При code `1+` або таймауті 7-Zip журнал архівації тепер записує останні
  діагностичні рядки stdout/stderr на рівні `ERROR`, незалежно від `LogLevel`;
  пароль архіву маскується.
- Перевірка principal Планувальника тепер порівнює вбудовані service accounts
  за SID, тому локалізовані назви на кшталт `СИСТЕМА` коректно розпізнаються
  як `SYSTEM` (`S-1-5-18`) і не спричиняють помилковий rollback.
- Допоміжні setup, dry-run, credentials, scheduler і self-test скрипти
  отримали окремі transcript-журнали у `LOGS\HELPERS`, фінальний exit code,
  31-денний retention і fallback до `%TEMP%`, якщо runtime недоступний.
- Додано кореневий `README.md` з єдиним маршрутом першої інсталяції,
  оновлення, dry-run, налаштування Credential Manager, Планувальника,
  діагностики запуску від `SYSTEM` і окремими командами VETOFFICE.
- Додано спільний `BRAVO_OPERATION.lock` для взаємного виключення backup і
  maintenance; конфліктуюче завдання очікує lock до шести годин.
- Щоденна архівація зупиняє лише служби, які працювали, створює та перевіряє
  локальні архіви, після чого гарантовано повертає початковий стан служб.
- Для щоденного backup вилучено `-ssw`: відкритий стороннім процесом файл
  спричиняє fail-closed помилку замість потенційно неузгодженого архіву.
- Credential setup отримав режим `Ensure`; повторний setup не перезаписує
  наявні секрети та параметри установи.
- Операції Credential Manager і реєстрація завдань отримали rollback при
  частковій помилці.
- Додано `BRAVO_TASKS_DIAGNOSE.ps1/.cmd`: перевірка реєстрації, action,
  working directory, `LastTaskResult` і dry-run від `NT AUTHORITY\SYSTEM`.
- Setup після встановлення Планувальника перевіряє SFTP, SMB, Credential
  Manager і тестове повідомлення від task account.
- Інсталятор вмикає Task Scheduler Operational log, захищає runtime ACL і
  відмовляється створювати SYSTEM-завдання з профілю користувача.
- Версія конфігурації: 4.9; BRAVO_ARCHIV: 4.0.0;
  BRAVO_MAINTENANCE: 1.7.0.
