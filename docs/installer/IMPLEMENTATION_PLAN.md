# BRAVO Installer — план реалізації

## 1. Статус

Цей файл є design backlog. Ідентифікатори `INS-*` не означають, що відповідні GitHub Issues уже створені.

Issues доцільно створювати хвилями після стабілізації попередньої фази, а не переносити весь план у GitHub одночасно.

Реалізацію Installer v1 розпочато в гілці `feature/installer-v1`. Актуальний стан (що вже в коді, що в роботі, що не виконано) ведеться в [README.md](README.md), розділ «Стан реалізації»; цей backlog не є звітом про виконання.

### 1.1 Аудит виконання — 2026-10-29

Знімок гілки `feature/installer-v1` (локальна, не опублікована; push/PR/merge не виконувались).
Позначення: **✓** — реалізовано в коді й покрито sandbox self-test; **◐** — реалізовано частково
або є відкриті знахідки; **✗** — не виконано; **—** — виключено з v1 рішенням D1.
Жоден пункт не є production acceptance: усі перевірки — sandbox зі stub-адаптером, без
реального Task Scheduler, Credential Manager, UAC і VM.

| Фаза | INS | Статус | Докази / що лишилось |
|---|---|---|---|
| 0 | 000 Stabilization disposition | ✗ | Рішення власника; поточні lanes не класифіковано |
| 0 | 001 Fleet inventory | ✗ | Потрібен доступ до парку |
| 0 | 002 Config v2 fleet migration | ✗ | Operator-controlled; у коді є лише fail-closed бар'єр INS-022 |
| 0 | 003 Discovery baseline | ✗ | Operational baseline на хостах |
| 0 | 004 Real-host acceptance | ✗ | Live gates на хостах |
| 0 | 005 Defect disposition | ◐ | Дефекти, знайдені рев'ю цієї гілки, виправлено або передано в роботу; класифікації дефектів парку немає |
| 1 | 010–014 Contracts | ✓ | `CONTRACTS.md`, `BRAVO.Update.{Contracts,Journal,Paths}.ps1`; suite `UpdateContracts`. Architecture review: внутрішній architect + Codex (3 раунди) |
| 2 | 020 Discovery | ✓ | `Get-BRAVOInstallationState`; suite `UpdateDiscovery` (доведено read-only) |
| 2 | 021 Preflight | ✓ | `Test-BRAVODeploymentPreflight`; suite `UpdatePreflight` |
| 2 | 022 Config migration gate | ✓ | `Test-BRAVOConfigMigrationBlocker` (legacy `BRAVO.config` не виконується) |
| 2 | 023 Plan builder | ✓ | `New-BRAVODeploymentPlan`, fingerprint/expiry; suite `UpdatePlan` |
| 2 | 024 Diagnostics | ✓ | Redaction, support report без автоматичного надсилання; suite `UpdateDiagnostics` |
| 3 | 030–034 Release discovery / acquisition / offline / verification / prerelease | ✓ | Один pipeline online/offline, manifest обов'язковий для stable; suite `UpdateRelease`. Без підпису (D5) |
| 3 | 035 Staging | ✓ | Безпечне розпакування ZIP: ACL allowlist, один handle; suite `UpdateStaging` |
| 3 | 036 Staged validation | ✓ | `Test-BRAVOStagedRuntime` довіреним guard |
| 4 | 040 `modules/BRAVO.Update` | ◐ | 19 частин, 108 експортів; частини Deploy/Worker/Rollback/Contracts > 1000 рядків — кандидат на safe-refactor |
| 4 | 041 `BRAVO_UPDATE.ps1` | ✓ | Thin CLI (152 рядки); suite `UpdateWorker` |
| 4 | 042 Mutation boundary | ✓ | `mutationStarted` на U11, cancel до/після межі; suite `UpdateDeploy` |
| 4 | 043 Runtime backup | ✓ | Перевірений backup; suite `UpdateBackup` |
| 4 | 044 Canonical deployment operation | ✓ | `Invoke-BRAVODeployment` U0–U19 для CLI і GUI; suite `UpdateDeploy` |
| 4 | 045 Configuration reconciliation | ✓ | Site config зберігається побайтово (перевірка хешем) |
| 4 | 046 Scheduler reconciliation | ◐ | Через canonical `BRAVO_SETUP`; повторне вимкнення після реєстрації (F1); COM-шлях не перевірено на VM |
| 4 | 047 Post-deployment validation | ✓ | suite `UpdateValidation` |
| 5 | 050–052 Rollback / validation / Critical | ✓ | Quiesce перед відкатом, reparse-перевірки, довіра до журналу, version-state транзакція; suite `UpdateRollback` |
| 5 | 053–054 Interrupted detection / crash recovery | ✓ | suite `UpdateRecovery`, `UpdateEndToEnd` (зокрема crash → CLI Recover → RolledBack; CLI сам знаходить встановлення й передає корені engine) |
| 5 | 055 Failure injection suite | ✓ | `UpdateEndToEnd` (195 перевірок): кожна fault-точка, crash, cancel, rollback failure, сканування секретів |
| 5 | Gate: security + architecture + behavioral review | ◐ | Codex: 6 раундів, усі P1 виправлено, останнє підтвердження — «нових P0–P2 немає». Internal security pre-review: reject → після виправлень accept-with-fixes; N1–N3 і P3 #9 виправлено, повторно не переглядалось. Формальний codex-security gate не виконувався; прийняті залишкові ризики — D14 |
| 6 | 060–065 Clean install | ◐ | `Install-BRAVOToolkit`, root policy, seed config, scheduler deferred без credentials; suite `UpdateInstall`. Seed/COM/UAC реально не перевірено |
| 7 | 070–074 Repair | ✓ | `Repair-BRAVOInstallation -Scope`, без implicit upgrade; suite `UpdateRecovery`, `UpdateEndToEnd` |
| 8 | 080–092 Installer GUI | ◐ | WinForms (D3 — відхилення від WPF, чекає затвердження); suite `InstallerUI` (view-model і побудова форми). DPI/RDP/keyboard/usability не перевірено |
| 9 | 100–104 Maintenance Center | ◐ | Logs, Diagnostics, Configuration/Repair launchers; реальний запуск не перевірено |
| 10 | 110–120 Scheduled update | — | Виключено з v1 (D1) |
| 11 | 130–137 VM acceptance | ✗ | Є лише sandbox-аналоги в `UpdateEndToEnd`; VM не виконувалась |
| 11 | 138–140 Scheduled modes | — | Виключено з v1 |
| 11 | 141 Full BRAVO self-test | ◐ | Повний `BRAVO_SELF_TEST.ps1 -NoPause` на f1a5d839: 5542 PASS / 1 FAIL — `Archive/SftpConnectionTimeoutLogsError` через сторонній активний `WinSCP.com` на хості (Archive гілкою не змінювався; окремий прогін `-Suite Archive` на тій самій голові: 1748 PASS / 0 FAIL). Чистого повного прогону без збою середовища ще немає; CI не запускався |
| 11 | 142 Fresh independent review | ◐ | Codex-рев'ю кожної хвилі й фінальної дельти виконано; незалежне рев'ю людиною — ні |
| 12 | 150–155 Real-host pilot | ✗ | Рішення й доступ власника |

Рішення D1–D13 та R1–R7 (`DECISIONS.md`) мають статус «Запропоновано — чекає затвердження
власником».

## 2. Dependency graph

```text
Current stabilization
        |
        +-----------------> Installer read-only foundation
        |
        v
Fleet inventory / Config migration / operational acceptance
        |
        v
Release acquisition
        |
        v
BRAVO.Update transaction engine
        |
        v
Rollback / Recovery
        |
        +------> Install
        +------> Repair
        |
        v
Installer GUI
        |
Maintenance Center
        |
Scheduled Update
        |
VM Acceptance
        |
Real-host Pilot
```

## 3. Phase 0 — prerequisites та operational truth

- **INS-000 — Stabilization disposition.** Завершити або чітко відділити поточні correctness/mutation lanes від Installer mutation work.
- **INS-001 — Fleet inventory.** Отримати фактичну version/provenance matrix парку.
- **INS-002 — Config v2 fleet migration.** Завершити operator-controlled migration або визначити fail-closed blocker.
- **INS-003 — Discovery baseline.** Завершити необхідний operational baseline до широкого rollout.
- **INS-004 — Relevant real-host acceptance.** Перевіряти live gates перед pilot/deployment.
- **INS-005 — Defect disposition.** Класифікувати deployment/configuration/credential/integrity defects, які можуть змінити Installer contract.

Phase 0 не блокує read-only design/foundation, але блокує неконтрольований production rollout.

## 4. Phase 1 — contracts

- **INS-010 — Installation State contract.** States, fields, serialization; no mutation.
- **INS-011 — Deployment Plan contract.** Action, source/target version, runtime root, configuration/scheduler impact, backup requirement, warnings, blockers.
- **INS-012 — Deployment Result contract.** `Success`, `SuccessWithWarnings`, `Failed`, `RolledBack`, `Critical`; numeric exit codes не дублюються.
- **INS-013 — Progress Event contract.** Structured phase/status/percent/message.
- **INS-014 — Update Journal contract.** Crash-safe schema та atomic persistence.

**Gate:** fresh architecture review перед mutation design.

## 5. Phase 2 — read-only foundation

- **INS-020 — Installation discovery.** Proposed `Get-BRAVOInstallationState`; no production mutation.
- **INS-021 — Deployment preflight.** OS/runtime, elevation, disk, runtime state, conflicting tasks, configuration, integrity, legacy state, interrupted transaction.
- **INS-022 — Config migration blocker.** Unsafe legacy state блокує update fail-closed.
- **INS-023 — Plan builder.** Proposed `New-BRAVODeploymentPlan`.
- **INS-024 — Diagnostic report.** Read-only machine/operator report без secrets.

Після цієї фази можливий перший безпечний GUI prototype, який нічого не встановлює.

## 6. Phase 3 — release acquisition

- **INS-030 — Release discovery.** Explicit release/tag metadata.
- **INS-031 — Online acquisition.** Release artifact та required metadata.
- **INS-032 — Offline source.** Той самий verification pipeline.
- **INS-033 — Release verification.** Reuse canonical release eligibility/provenance policy.
- **INS-034 — Prerelease policy.** Explicit opt-in; fail-closed.
- **INS-035 — Staging.** Payload поза active runtime.
- **INS-036 — Staged runtime validation.** Validation до production mutation.

## 7. Phase 4 — BRAVO.Update

- **INS-040 — `modules/BRAVO.Update`.** Canonical lifecycle domain owner.
- **INS-041 — `BRAVO_UPDATE.ps1`.** Thin orchestration entrypoint.
- **INS-042 — Mutation boundary.** Formal cancellation/rollback semantics.
- **INS-043 — Runtime backup.** Recoverable verified backup до mutation.
- **INS-044 — Canonical deployment operation.** Одна implementation для CLI, GUI та Scheduler.
- **INS-045 — Configuration reconciliation.** Reuse canonical configuration/setup.
- **INS-046 — Scheduler reconciliation.** Reuse canonical scheduler.
- **INS-047 — Post-deployment validation.** Version, Runtime Guard, configuration, scheduler, integrity та required setup/test gates.

## 8. Phase 5 — rollback та recovery

- **INS-050 — Automatic rollback.**
- **INS-051 — Rollback validation.**
- **INS-052 — Rollback failure.** Явний `Critical`/manual intervention state.
- **INS-053 — Interrupted update detection.**
- **INS-054 — Crash recovery.** V1: recovery to known-good state.
- **INS-055 — Failure injection suite.**

**Gate:** fresh security + architecture + behavioral review.

## 9. Phase 6 — clean install

- **INS-060 — Clean-install workflow**
- **INS-061 — Runtime root та ACL**
- **INS-062 — Configuration integration**
- **INS-063 — Secure credentials integration**
- **INS-064 — Scheduled Tasks installation**
- **INS-065 — Post-install validation**

Clean install не створює окремий release/deployment engine.

## 10. Phase 7 — repair

- **INS-070 — Repair analysis**
- **INS-071 — Same-version runtime repair**
- **INS-072 — Scheduler repair**
- **INS-073 — Site configuration preservation**
- **INS-074 — Repair validation**

Repair не виконує implicit upgrade.

## 11. Phase 8 — Installer GUI

Ця фаза реалізує `UX.md`.

- **INS-080 — Installer shell**
- **INS-081 — Welcome**
- **INS-082 — Preflight**
- **INS-083 — Installation detection**
- **INS-084 — Action selection**
- **INS-085 — Release selection**
- **INS-086 — Configuration**
- **INS-087 — Deployment Plan**
- **INS-088 — Progress**
- **INS-089 — Validation**
- **INS-090 — Success result**
- **INS-091 — Update available**
- **INS-092 — Failure / rollback / critical UX**

GUI не має власної deployment policy.

## 12. Phase 9 — Maintenance Center

- **INS-100 — Installed-product home**
- **INS-101 — Logs**
- **INS-102 — Diagnostics UI**
- **INS-103 — Configuration launcher**
- **INS-104 — Repair launcher**

## 13. Phase 10 — scheduled update

Scheduled update розділяється за рівнем mutation. `NotifyOnly`/read-only check може проєктуватися окремо після появи стабільного canonical check path. `StageOnly` потребує окремого approved contract для acquire/verify/stage без activation. `Automatic` production mutation **не входить у P3.2a** і залишається hard-blocked до завершення та acceptance повного P3.2 (versioned release directories, deployment pointer, staging/validation, atomic activation, automatic rollback, update journal).

- **INS-110 — Update Check Scheduled Task.** Запускає canonical update/check path.
- **INS-111 — Update policy.** `NotifyOnly`, `StageOnly`, `Automatic`; default `NotifyOnly`.
- **INS-112 — Stable release polling**
- **INS-113 — Update notification**
- **INS-114 — Stage-only mode**
- **INS-115 — Maintenance window**
- **INS-116 — Automatic preflight**
- **INS-117 — Scheduled automatic deployment.** Gate: full P3.2 accepted; не реалізовувати як розширення P3.2a
- **INS-118 — Scheduled rollback**
- **INS-119 — Result notification**
- **INS-120 — Update Settings UI**

Unsafe/ambiguous preflight означає skip, не force.

## 14. Phase 11 — acceptance

- **INS-130 — Clean VM install**
- **INS-131 — Stable upgrade**
- **INS-132 — Offline install/update**
- **INS-133 — Corrupt artifact rejection**
- **INS-134 — Prerelease rejection without authorization**
- **INS-135 — Configuration preservation**
- **INS-136 — Rollback acceptance**
- **INS-137 — Interruption/recovery acceptance**
- **INS-138 — Scheduled `NotifyOnly`**
- **INS-139 — Scheduled `StageOnly`**
- **INS-140 — Scheduled `Automatic`.** Acceptance тільки після full P3.2 gate
- **INS-141 — Full BRAVO self-test**
- **INS-142 — Fresh independent review**

BRAVO validation evidence використовує `powershell.exe`; `pwsh` не є достатнім evidence для product acceptance.

## 15. Phase 12 — real-host pilot

- **INS-150 — Single pilot / NotifyOnly**
- **INS-151 — Manual Installer update pilot**
- **INS-152 — Repair pilot**
- **INS-153 — StageOnly pilot**
- **INS-154 — Automatic update pilot**
- **INS-155 — Fleet rollout decision**

Automatic update є останнім pilot mode, а не першим, і не допускається до pilot до завершення та acceptance full P3.2.

## 16. Рекомендована перша implementation wave

```text
INS-010 Installation State
INS-011 Deployment Plan
INS-012 Deployment Result
INS-013 Progress Event
INS-014 Update Journal
INS-020 Read-only Installation Discovery
INS-021 Deployment Preflight
INS-022 Config Migration Gate
INS-023 Plan Builder
INS-024 Diagnostics
```

Цей пакет мінімізує production risk і дозволяє створити живий read-only prototype Installer до mutation engine.

## 17. Validation strategy

Мінімальна behavioral matrix:

```text
Clean install
Existing same version
Upgrade
Downgrade attempt
Prerelease without authorization
Prerelease authorized
Corrupt artifact
Wrong hash
Wrong manifest/provenance
Insufficient disk
Conflicting BRAVO task
Legacy configuration
Invalid local configuration
Failure before mutation
Failure after mutation
Rollback success
Rollback failure
Interrupted transaction
Repair valid runtime
Repair damaged runtime
NotifyOnly
StageOnly
Automatic update
```

Tests/fixtures не читають і не пишуть реальний production BRAVO state.

## 18. Definition of Done

BRAVO Installer v1 може перейти до production acceptance, коли оператор без знання внутрішньої структури toolkit може запустити один Installer, побачити доведений state та preflight, переглянути plan до mutation, безпечно install/update/repair, отримати однозначний structured result, а failure після mutation завершується перевіреним rollback або явним critical state.

Site configuration та production data зберігаються відповідно до ownership contract; diagnostics не виконує mutation; GUI, CLI та Scheduler працюють поверх одного canonical deployment engine.

Production acceptance додатково вимагає реальних test/CI/VM/pilot evidence; документація або merged code самі по собі не є PASS.
