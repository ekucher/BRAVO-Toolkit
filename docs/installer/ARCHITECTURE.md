# BRAVO Installer — архітектура

## 1. Призначення

BRAVO Installer має стати єдиним operator-facing lifecycle frontend для clean install, update, repair, configuration, diagnostics, перегляду стану та журналів і, у майбутньому, контрольованого scheduled update.

Архітектура зберігає один canonical implementation deployment policy.

## 2. Цільова модель

```text
+-------------------------------------------------------------+
| BRAVO Installer / Maintenance Center                        |
| Install | Update | Repair | Configure | Diagnose | Logs     |
+------------------------------+------------------------------+
                               |
                               |
+------------------------------v------------------------------+
| BRAVO.Update — canonical lifecycle/deployment domain         |
| State | Preflight | Plan | Acquire | Verify | Stage          |
| Backup | Deploy | Validate | Rollback | Recovery | Journal   |
+----------+-------------------+-------------------+-----------+
           ^                   ^                   ^
           |                   |                   |
 Installer GUI        BRAVO_UPDATE.ps1      Scheduled trigger
   frontend            CLI entrypoint       (коли дозволено)
                               |
                               v
              canonical BRAVO domains
       Configuration | Scheduler | Runtime integrity
```

Назви `BRAVO_UPDATE.ps1`, `modules/BRAVO.Update/` та API нижче є **цільовим design**, доки відповідна реалізація не прийнята.

## 3. Розподіл відповідальності

Точні форми контрактів і назви функцій Installer v1 визначає [CONTRACTS.md](CONTRACTS.md); у разі розбіжності з цим розділом діє CONTRACTS.md.

### Installer GUI

GUI відображає installation state, запускає preflight, збирає operator intent, показує deployment plan, отримує progress events та показує result/rollback state.

GUI не повинен самостійно реалізовувати release provenance, Scheduled Tasks, configuration schema/defaults, rollback, Runtime Guard або виконувати неперевірений payload.

### `BRAVO_UPDATE.ps1`

Тонкий orchestration entrypoint для CLI/operator execution. Не містить substantial reusable deployment logic.

### `BRAVO.Update`

Canonical domain owner для lifecycle deployment.

Proposed public contract:

```text
Get-BRAVOInstallationState
Test-BRAVODeploymentPreflight
Get-BRAVOReleaseCandidate
New-BRAVODeploymentPlan
Invoke-BRAVODeployment
Invoke-BRAVORollback
Repair-BRAVOInstallation
Test-BRAVODeploymentResult
```

API не вважається реалізованим лише через наявність цього design.

## 4. Installation State

Proposed states:

```text
NotInstalled
Installed
UpdateAvailable
PrereleaseInstalled
Degraded
RepairRequired
InterruptedUpdate
RollbackRequired
Unsupported
```

State визначається сукупністю evidence, а не лише наявністю `VERSION.json`. Модель має враховувати runtime root, package version, release channel, build/provenance, runtime integrity, configuration state, scheduler state, interrupted transaction та migration blocker.

## 5. Deployment state machine

```text
Discover
   |
Preflight ---------> Blocked
   |
Select operation
   |
Build plan
   |
Confirm
   |
Acquire -> Verify release -> Stage -> Validate staged runtime
   |
Backup
   |
   +--------- MUTATION BOUNDARY ---------+
   |
Deploy -> Configure/Reconcile -> Validate
   |                              |
   | PASS -> Commit -> Complete   |
   |
   + FAIL -> Rollback
               |
          +----+----+
          |         |
        PASS       FAIL
          |         |
        Failed    Critical
       restored   manual action
```

До mutation оператор може скасувати операцію без зміни installed runtime. Після mutation `Cancel` не повинен означати примусове завершення процесу. Engine переходить до безпечної точки та, якщо потрібно, виконує rollback.

## 6. Update Journal

Journal потрібен для crash/reboot recovery. Proposed fields: `operationId`, operation, state, source/target version, runtime root, staging/backup path, artifact SHA-256, last completed phase та `mutationStarted`.

Вимоги: atomic update, machine-readable format, без credentials/secrets, достатність для визначення interrupted mutation. Recovery v1 орієнтується на повернення до known-good state, а не на складний resume-from-middle.

## 7. Release acquisition та verification

```text
Online source  ----\
                    +--> Verify --> Stage --> Validate
Offline source ----/
```

Online та offline acquisition сходяться в один verification pipeline. Майбутній engine перевикористовує canonical release eligibility/provenance policy. Prerelease залишається explicit opt-in та fail-closed.

Неперевірений downloaded/staged payload не імпортується як trusted code до завершення required verification.

## 8. Runtime integrity та trust boundary

Обов'язковий порядок:

```text
pre-trust bootstrap
        |
release/runtime verification
        |
trusted import/execution
```

`BRAVO_RUNTIME_GUARD.ps1` не переноситься за trust boundary без окремого security design.

## 9. Configuration

Installer не створює другий configuration engine. Використовуються canonical Config v2 schema, defaults, validation, persistence та Configurator.

`BRAVO.local.config` є site-owned override path і не повинен перезаписуватися update/repair. Legacy `BRAVO.config` не видаляється автоматично. Якщо state потребує operator-controlled migration, update блокується fail-closed.

## 10. Credentials

Secrets не повинні потрапляти в command line, deployment plan, journal, result JSON, installer log або crash report. Конкретний secure handoff contract має пройти security review до реалізації.

## 11. Scheduler

Installer не генерує Scheduled Task definitions самостійно. Reconciliation/installation використовує canonical scheduler logic. Майбутній scheduled update також не містить власного updater.

## 12. Install, Update та Repair

Clean install використовує той самий release verification, staging, validation та result contracts.

Update змінює runtime тільки через transactional engine.

Repair не означає upgrade: базовий repair відновлює поточну версію та її canonical runtime state, зберігаючи site configuration.

## 13. Scheduled Update

Proposed policy modes:

```text
NotifyOnly
StageOnly
Automatic
```

Default production design: `NotifyOnly`.

`StageOnly` дозволяє acquire + verify + stage без activation. `Automatic` **не входить у P3.2a** і не дозволяється лише на підставі acceptance manual transactional update. Production automatic mutation залишається hard-blocked до завершення та acceptance **повного P3.2**: versioned release directories, deployment pointer, staging/validation, atomic activation, automatic rollback та update journal.

Після виконання full P3.2 gate перед кожною automatic mutation додатково потрібен fail-closed preflight: allowed release channel, valid release, sufficient disk, no conflicting BRAVO task, valid configuration, no unresolved transaction, no migration blocker. Невизначеність означає skip, а не force.

## 14. Result та progress contracts

Proposed semantic results:

```text
Success
SuccessWithWarnings
Failed
RolledBack
Critical
```

Numeric exit codes не дублюються; canonical `BRAVO.ExitCodes` залишається source of truth. Відображення результатів на коди (зокрема `80`/`81`/`82`) — у [CONTRACTS.md](CONTRACTS.md) §7.

`BRAVO_SETUP.ps1` фактично завершується лише кодом `0` або `1`; код `10` setup не повертає. Mapping `10` → `PASS_WITH_WARNING` у `Get-BRAVODeploySetupExitVerdict` — залишок сумісності legacy deploy. Engine трактує setup `0` як `Pass`, ненульовий — як `Fail` (див. [DECISIONS.md](DECISIONS.md) D10).

GUI не парсить декоративний console output. Structured progress містить щонайменше operation ID, phase, status, percent, message та timestamp.

## 15. GUI technology

Цільовий GUI — Windows-native operator application. Попередній design candidate — C#/.NET Framework/WPF, але exact framework/runtime compatibility має бути окремо перевірена проти підтримуваної Windows matrix до implementation freeze.

GUI technology не змінює вимогу Windows PowerShell 5.1 для BRAVO product/test validation.

Installer v1 використовує Windows PowerShell 5.1 + WinForms замість WPF — див. [DECISIONS.md](DECISIONS.md) D3.

## 16. Acceptance boundary

```text
engine tests
-> BRAVO full self-test
-> clean VM install
-> VM upgrade
-> injected failure + rollback
-> interrupted update recovery
-> scheduled modes
-> real-host pilot
-> operational acceptance
```

Real-host deployment завжди підпорядковується актуальним live operational gates.
