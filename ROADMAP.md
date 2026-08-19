# BRAVO-Toolkit Roadmap

Цей документ визначає актуальний порядок розвитку BRAVO-Toolkit. Детальні технічні design notes для окремих великих функцій залишаються в `TODO_FEATURES.md`; `ROADMAP.md` є канонічним джерелом пріоритетів і послідовності реалізації.

## Принципи планування

- Спочатку усуваються відомі production-ризики й прогалини release-процесу, потім додаються нові функції.
- Backup вважається надійним лише тоді, коли його регулярно перевірено реальним restore drill.
- Компрометація одного LIMS-сервера не повинна давати можливість знищити всю історію резервних копій.
- Root `BRAVO_*.ps1` залишаються thin entrypoints; нова доменна логіка належить `modules/BRAVO.<Domain>/`.
- Telemetry/monitoring не повинні змінювати exit code або результат Archive/Health/Maintenance/Restore.
- Auto-update не реалізується раніше, ніж існують стабільний release artifact, перевірка цілісності, atomic activation і rollback.

## Актуальні технічні обмеження

### SFTP authentication

Production SFTP для Hetzner Storage Box залишається password-based. Перехід на public-key authentication не є поточним завданням, оскільки використовуване сховище в цьому deployment-профілі працює з парольною автентифікацією.

Найближчі роботи в цій області обмежуються посиленням існуючої моделі:

- host-key pinning залишається обов'язковим;
- credentials зберігаються у Windows Credential Manager;
- секрети не записуються в config/logs;
- зберігається мінімально необхідний доступ SFTP-акаунта;
- окремо опрацьовується захист remote backup history від масового видалення/шифрування.

Public-key authentication можна переглянути пізніше, якщо зміниться backend або з'явиться сумісний режим без погіршення операційної підтримки.

### Authenticode / signed releases

Authenticode, підписані git tags і криптографічно підписаний release manifest не входять до найближчого плану. До них повертаємось, якщо реалізація не потребує істотних додаткових витрат, окремої складної PKI або значного операційного навантаження.

До того часу основними контролями цілісності лишаються:

- `RUNTIME_MANIFEST.json`;
- `TOOLS_MANIFEST.json`;
- CI;
- PSScriptAnalyzer security rules;
- gitleaks;
- release policy;
- provenance через `VERSION.json.sourceCommit`/`buildId`.

## P0 — стабілізація й production safety

### P0.1 — Завершити hotfix 5.0.1

Поточний production-дефект notification override має бути закритий до нових feature-релізів.

Критерії завершення:

- [ ] PR #45 проходить real-server acceptance.
- [ ] Перевірено `NotificationMode=none/errors_only/all` з `-EnableAllSlack`/`-DisableAllSlack`.
- [ ] Перевірено GENERAL/ALERTS routing і credential fallback.
- [ ] Перевірено Maintenance final report і критичні alerts.
- [ ] `5.0.1-rc.1` промотовано у stable `5.0.1` без функціональних змін після acceptance.
- [ ] Hotfix синхронізовано назад у `developer`.

### P0.2 — Закрити release governance

Мета — унеможливити повторення прямого feature merge у `master` в обхід RC/acceptance.

Критерії завершення:

- [ ] PR #46 доведено до merge після виправлення всіх review findings.
- [ ] Gate перевіряє дозволене джерело PR (`developer` або `hotfix/*`) і repository identity.
- [ ] Gate вимагає семантичне збільшення stable version, а не лише нерівність рядків.
- [ ] `master` не приймає feature/fix PR напряму.
- [ ] Branch/repository settings максимально обмежують direct push, force push і випадковий merge настільки, наскільки це дозволяє поточний GitHub plan.

### P0.3 — Захист remote backup history

Це головний залишковий ризик для даних. Компрометація LIMS-сервера або його SFTP credentials не повинна дозволяти знищити всі історичні копії.

Цільовий напрям:

- окремити створення нової backup generation від права масового видалення історії;
- використовувати server-side snapshots/versioning/immutable policy там, де це підтримує storage backend;
- або організувати pull-based/second-copy процес із системи, credentials якої відсутні на LIMS-сервері;
- перевіряти, що retention не може знищити останню незалежну recoverable copy.

Критерії завершення:

- [x] Обрано конкретну схему для Hetzner Storage Box/вторинного сховища:
      вбудовані Hetzner Storage Box Snapshots (20 знімків, щоденно
      о 05:00 UTC, керовані окремо через Hetzner Robot — credentials,
      відсутні на LIMS-сервері й у Credential Manager). Другий,
      pull-based/offline шар (окрема система з окремими credentials)
      свідомо відкладено на P1.3 — снапшоти вже закривають найгостріший
      сценарій розділу 5 `THREAT_MODEL.md` самостійно.
- [x] Задокументовано threat model і recovery procedure —
      `THREAT_MODEL.md` розділ 5 (мітигація/залишковий ризик) і
      розділ 12 (Recovery procedure).
- [x] Проведено тест: компрометований/видалений primary backup не знищує незалежну історичну копію.
      **Виконано 2026-08-19** на живому Hetzner Storage Box: снапшот-каталоги
      доступні read-only через SFTP (`/.zfs/snapshot/<name>/...`), файли з
      них відновлюються копіюванням без деструктивного повного Restore
      snapshot у Robot (повний Restore навмисно НЕ виконувався — він
      відкотив би весь бокс і видалив новіші снапшоти).

## P1 — доказова відновлюваність і deployment quality

### P1.1 — Автоматичний scheduled Restore Drill

`BRAVO_RESTORE_TEST.ps1` має стати штатним елементом експлуатації, а не ручною процедурою.

Цільова поведінка:

```text
останній COMPLETE generation
        ↓
ізольований restore
        ↓
7z/hash/manifest validation
        ↓
file-count/size sanity
        ↓
cleanup
        ↓
machine-readable result + notification
```

Критерії завершення:

- [ ] Додано окремий scheduler task, наприклад `BRAVO_RESTORE_VERIFY`.
- [ ] Розклад задається конфігурацією; типовий інтервал — щотижня.
- [ ] Restore drill не торкається production paths і не зупиняє служби.
- [ ] Є stable exit code/result contract.
- [ ] Health може показати вік останньої успішної restore verification.
- [ ] Failure піднімає WARNING/CRITICAL залежно від причини.
- [ ] Є bounded cleanup тимчасових restore artifacts.

### P1.2 — Stable release artifact

Мета — перестати трактувати довільний checkout/набір файлів як release package.

Мінімальний artifact:

```text
BRAVO-Toolkit-X.Y.Z.zip
BRAVO-Toolkit-X.Y.Z.zip.sha256
release-manifest.json
```

Критерії завершення:

- [ ] Artifact збирається автоматично з конкретного release commit/tag.
- [ ] SHA-256 перевіряється до deployment.
- [ ] Manifest містить product, version, sourceCommit і список файлів/хешів.
- [ ] Artifact проходить CI/self-test перед публікацією.
- [ ] Документація оновлення посилається на artifact, а не на ручне копіювання випадкового checkout.

Підпис artifact/manifest є optional future hardening, не blocker для цього етапу.

### P1.3 — Backup lifecycle / retention separation

Мета — зменшити blast radius credentials, якими користується Archive.

Напрями:

- BRAVO створює нові generations;
- destructive retention виконується окремим authority/process там, де це технічно можливо;
- останні verified generations мають незалежний захист від помилкового або зловмисного видалення.

Цей пункт може бути реалізований разом із P0.3, якщо storage architecture дозволяє.

## P2 — централізована експлуатація

### P2.1 — Machine-readable health/status contract

Уніфікувати JSON-result для Archive, Health, Maintenance і Restore Verification.

Мінімальні поля:

```json
{
  "schemaVersion": 1,
  "host": "...",
  "packageVersion": "...",
  "operation": "Health",
  "status": "OK",
  "exitCode": 0,
  "lastCompleteGeneration": "...",
  "lastRestoreVerifiedAt": "...",
  "localVerified": true,
  "sftpVerified": true,
  "smbVerified": true,
  "runtimeIntegrity": "OK",
  "toolIntegrity": "OK"
}
```

Критерії завершення:

- [ ] Один versioned schema для machine consumers.
- [ ] Жодних secret-bearing values.
- [ ] Exit codes лишаються canonical source of failure class.
- [ ] JSON можна використовувати Zabbix/telemetry без парсингу console text.

### P2.2 — Remote Fleet Telemetry

Продовжити FEAT-003 із `TODO_FEATURES.md`, але після появи стабільного локального machine-readable contract.

Порядок:

1. schema + server identity;
2. durable outbox;
3. heartbeat і Task Scheduler inspection;
4. HTTPS/443 + per-server HMAC;
5. gateway + PostgreSQL + idempotency;
6. task.started/task.finished;
7. stale/offline/overdue evaluation;
8. fleet dashboard / Zabbix integration.

Telemetry залишається outbound-only і не перетворюється на remote-command channel.

## P3 — configuration і lifecycle automation

### P3.1 — Config v2

FEAT-001 із `TODO_FEATURES.md` залишається важливим, але не випереджає production safety та restore verification.

Ціль: package defaults + site-local data-only overrides + deterministic schema validation + legacy migration.

Починати після стабілізації P0/P1, якщо ручний merge `BRAVO.config` продовжує створювати реальний операційний ризик.

### P3.2 — Atomic versioned deployment / rollback

FEAT-002 реалізується після stable release artifact і, бажано, Config v2.

Порядок:

1. stable launcher;
2. versioned release directories;
3. deployment pointer;
4. staging + validation;
5. atomic activation;
6. automatic rollback;
7. update journal;
8. лише після цього — можливість auto-download/auto-update.

Silent auto-update production серверів до завершення цих етапів заборонений архітектурно.

## P4 — optional hardening

Виконувати лише після основних operational задач або коли з'явиться дешевий/простий шлях реалізації:

- Authenticode для PowerShell;
- signed release manifest;
- signed git tags;
- SFTP public-key authentication для backend, який це підтримує;
- інші supply-chain controls, що потребують окремої PKI/сертифікатів.

Ці пункти не повинні блокувати P0–P3.

## Рекомендована послідовність

```text
1. 5.0.1 hotfix acceptance/stable
2. master/release governance gate
3. remote backup history protection
4. scheduled Restore Drill
5. stable release ZIP + SHA-256 + manifest
6. retention authority separation
7. machine-readable status contract
8. remote fleet telemetry / Zabbix integration
9. Config v2
10. atomic deployment + rollback
11. auto-update
12. optional signing/public-key hardening
```

## Що не є поточним пріоритетом

- загальний refactoring без конкретного defect/security/testability benefit;
- microservice-style дроблення PowerShell-модулів;
- SFTP public-key migration для Hetzner Storage Box;
- Authenticode лише заради формальної наявності підпису;
- remote command execution через telemetry gateway;
- auto-update до появи atomic rollback і перевіреного release artifact.
