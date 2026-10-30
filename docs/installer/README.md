# BRAVO Installer

## Статус

Цей каталог містить design-документацію майбутнього підсистемного напряму **BRAVO Installer & Update Lifecycle**.

Документація описує цільову архітектуру та план реалізації. Вона **не означає, що описані API, модулі, GUI, Scheduled Tasks або режими автоматичного оновлення вже реалізовані**.

Поточні `deploy/Install-BRAVOServer.ps1` і `deploy/Update-BRAVOServer.ps1` залишаються чинними operator-facing deployment helpers до появи та acceptance канонічного lifecycle engine.

## Стан реалізації (гілка feature/installer-v1)

Реалізація Installer v1 іде в гілці `feature/installer-v1`. Цей розділ
відділяє те, що вже є в коді, від того, що лишається design. «Реалізовано»
означає: код є в гілці й покритий названим suite-ом self-test у sandbox
(stub-адаптери, тимчасові корені). Це **не** перевірка на реальному хості.

**Installer v1 не прийнятий для production.** Ніщо в цій гілці не є
production acceptance і не дає дозволу на deployment, merge, release чи pilot.

### Реалізовано в коді

| INS | Що | Де | Suite |
|---|---|---|---|
| INS-010…014 | Контракти State/Preflight/Plan/Progress/Result/Journal, атомарний журнал, шляхи за замовчуванням, adapter | `BRAVO.Update.Contracts.ps1`, `.Journal.ps1`, `.Paths.ps1` | `UpdateContracts` |
| — | Коди завершення `80`/`81`/`82` | `modules/BRAVO.ExitCodes` | — |
| INS-020 | Read-only discovery стану встановлення | `.Discovery.ps1` | `UpdateDiscovery` |
| INS-021, INS-022 | Preflight і бар'єр міграції конфігурації | `.Preflight.ps1` | `UpdatePreflight` |
| INS-023 | Побудова плану, fingerprint передумов | `.Plan.ps1` | `UpdatePlan` |
| INS-024 | Діагностичний звіт з редакцією секретів і ідентифікаторів | `.Diagnostics.ps1` | `UpdateDiagnostics` |
| INS-030…034, INS-036 | Отримання (online за тегом, offline zip), верифікація артефакта, prerelease policy, перевірка staged runtime | `.Release.ps1` | `UpdateRelease` |
| INS-035 | Lifecycle lock, operation lock, приватний staging і безпечне розпакування | `.Lock.ps1`, `.Staging.ps1` | `UpdateStaging` |
| INS-040 | Модуль `modules/BRAVO.Update` | | — |
| INS-041 | Worker-протокол і тонкий CLI `BRAVO_UPDATE.ps1` | `.Worker.ps1`, `BRAVO_UPDATE.ps1` | `UpdateWorker` |
| INS-043 | Верифікований backup runtime | `.Backup.ps1` | `UpdateBackup` |
| INS-045, INS-046 | Baseline site-конфігурації, знімок/призупинення/відновлення задач, reconcile scheduler, активація (D6) | `.Reconcile.ps1` | `UpdateReconcile` |
| INS-047 | Post-deployment validation | `.Validation.ps1` | `UpdateValidation` |
| INS-050…052 | Транзакційний відкат, знімок і відновлення version-state (D13), відкат clean install | `.Rollback.ps1` | `UpdateRollback` |
| INS-053, INS-054 | Виявлення перерваної операції, recovery до known-good | `.Recovery.ps1` | `UpdateRecovery` |
| INS-070…074 | Same-version repair (обгортка над ядром deploy) | `.Repair.ps1` | `UpdateRecovery` |
| INS-042, INS-044 | Mutation boundary, фазовий двигун, orchestrator `Invoke-BRAVODeployment` (U0–U19), cancel через `control\cancel`, replay-захист `ConsumedPlans` | `.Deploy.ps1` | `UpdateDeploy` |
| INS-055 | Наскрізний sandbox-suite: install, upgrade, downgrade, prerelease, tamper, кожна fault-точка, crash → recovery (зокрема через CLI Recover), rollback failure, repair, worker, сканування секретів | — | `UpdateEndToEnd` |
| INS-060…065 | Clean install `Install-BRAVOToolkit`: політика кореня, захищений ACL, seed `BRAVO.local.config`, scheduler лише за наявних credentials, задачі неактивні | `.Install.ps1` | `UpdateInstall` |
| — | Захищені корені стану engine (власник/ACL/reparse), дія `Initialize` (D14) | `.Paths.ps1`, `.Worker.ps1` | `UpdateStaging`, `UpdateWorker`, `UpdatePreflight` |
| INS-080…092, INS-100…104 | GUI на WinForms: головна, перевірка, майстер 3–10, виконання через UAC, прогрес і результат (5 статусів), Maintenance Center (журнали, діагностика, Configurator, Repair) | `BRAVO_INSTALLER.ps1`, `modules/BRAVO.Installer.UI` | `InstallerUI` |

Інструкція оператора — [OPERATOR_GUIDE.md](OPERATOR_GUIDE.md).

### Перевірки та відкриті пункти

Повний `BRAVO_SELF_TEST.ps1 -NoPause` на голові `f1a5d839`: 5542 PASS / 1 FAIL —
`Archive/SftpConnectionTimeoutLogsError` через сторонній активний `WinSCP.com` на
хості (Archive гілкою не змінювався; окремий прогін `-Suite Archive` на тій самій
голові — 1748 PASS / 0 FAIL). Повна таблиця по INS — `IMPLEMENTATION_PLAN.md`,
розділ 1.1.

Потребують реального хоста або VM: COM Task Scheduler (увімкнення/вимкнення
задач), ACL під SYSTEM і UAC-токеном, справжній UAC-потік GUI, `File.Replace`
для version-state, DPI/RDP і доступність GUI.
Рішення, закладені за замовчуванням і ще не затверджені власником, — у
[DECISIONS.md](DECISIONS.md) (зокрема відкриті R1–R7).

### Явно не виконано

- fleet inventory і Config v2 fleet migration (INS-001, INS-002);
- scheduled update — `NotifyOnly`/`StageOnly`/`Automatic` (INS-110…120)
  виключено зі scope v1 (D1);
- VM acceptance (INS-130…142);
- pilot і рішення про rollout (INS-150…155).

### Перевірки, які потребують реального хоста або VM

Self-test у sandbox їх не замінює:

- COM Task Scheduler: читання, вимкнення й увімкнення реальних задач
  (`GetManagedTasks`/`SetTaskEnabled`), повторна реєстрація через
  `BRAVO_SETUP -Action Scheduler` і негайне вимкнення;
- ACL каталогів протоколу (`Requests`, `Operations`, `control`,
  `ConsumedPlans`), staging і backup під SYSTEM та під елевованим
  адміністратором;
- UAC-потік: неелевований CLI/GUI → `Start-Process -Verb RunAs` → worker,
  скасування UAC (код 36);
- ACL `BRAVO_VERSION_STATE.json` після `File.Replace` під час відновлення
  version-state;
- GUI: масштабування DPI, RDP-сесії, Server Core без desktop.

## Мета

Перетворити встановлення, оновлення, відновлення та діагностику BRAVO Toolkit з набору окремих операторських сценаріїв на один безпечний lifecycle:

```text
              BRAVO.Update
             /     |      \
            /      |       \
 Installer GUI   CLI entry   Scheduled trigger
                 |
          BRAVO_UPDATE.ps1

BRAVO.Update є canonical lifecycle/deployment domain.
GUI, CLI entrypoint і майбутній Scheduled trigger не створюють
паралельних implementation deployment policy.
```

GUI не є власником deployment policy. Він відображає стан, збирає вибір оператора, показує план, запускає канонічний engine та відображає structured progress/result.

## Документи

- [ARCHITECTURE.md](ARCHITECTURE.md) — архітектура, trust boundary, deployment transaction, rollback/recovery, configuration, credentials та scheduled update.
- [UX.md](UX.md) — затверджений UX baseline Installer/Maintenance Center і поведінка всіх основних екранів.
- [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) — поетапний implementation train, залежності, gates, acceptance та Definition of Done.
- [CONTRACTS.md](CONTRACTS.md) — implementation contract engine Installer v1 (State, Plan, Progress, Result, Journal, lock, worker protocol).
- [DECISIONS.md](DECISIONS.md) — рішення Installer v1 (ADR), що чекають затвердження власником.

## Основні інваріанти

1. Windows PowerShell 5.1 залишається підтримуваним runtime для BRAVO product/tests.
2. `BRAVO_RUNTIME_GUARD.ps1` зберігає pre-trust boundary.
3. GUI не дублює release, configuration, scheduler, integrity або rollback policy.
4. Site configuration та production data не повинні втрачатися під час install/update/repair.
5. Legacy `BRAVO.config` не видаляється і не мігрує автоматично без доведеної operator-controlled migration.
6. Після початку mutation failure має завершитися або доведено успішним rollback, або явним `CRITICAL/Manual intervention required`.
7. Scheduled update використовує той самий engine, що й ручне оновлення.
8. Production `Automatic` update не входить у P3.2a та залишається hard-blocked до завершення й acceptance повного P3.2: versioned release directories, deployment pointer, staging/validation, atomic activation, automatic rollback та update journal.
9. Prerelease deployment залишається fail-closed без explicit authorization.
10. Merged code не дорівнює real-host acceptance.

## Поточні залежності

Реалізація read-only foundation може починатися незалежно від production rollout. Реальне розгортання Installer/automatic update має враховувати окремі operational acceptance gates, зокрема fleet inventory, Config v2 migration та real-host acceptance.

Актуальний стан таких gates завжди перевіряється live перед deployment; цей документ не є snapshot їхнього статусу.
