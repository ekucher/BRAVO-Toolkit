# BRAVO-Toolkit — дорожня карта

Цей документ визначає актуальний порядок розвитку BRAVO-Toolkit. Детальні технічні design notes для окремих великих функцій залишаються в `TODO_FEATURES.md`; `ROADMAP.md` є канонічним джерелом пріоритетів і послідовності реалізації.

## Принципи планування

- Спочатку усуваються відомі production-ризики й прогалини release-процесу, потім додаються нові функції.
- Backup вважається надійним лише тоді, коли його регулярно перевірено реальним restore drill.
- Компрометація одного LIMS-сервера не повинна давати можливість знищити всю історію резервних копій.
- Root `BRAVO_*.ps1` залишаються thin entrypoints; нова доменна логіка належить `modules/BRAVO.<Domain>/`.
- Telemetry/monitoring не повинні змінювати exit code або результат Archive/Health/Maintenance/Restore.
- Auto-update не реалізується раніше, ніж існують стабільний release artifact, перевірка цілісності, atomic activation і rollback.

## Актуальні технічні обмеження

### Автентифікація SFTP

Production SFTP для Hetzner Storage Box залишається password-based. Перехід на public-key authentication не є поточним завданням, оскільки використовуване сховище в цьому deployment-профілі працює з парольною автентифікацією.

Найближчі роботи в цій області обмежуються посиленням існуючої моделі:

- host-key pinning залишається обов'язковим;
- credentials зберігаються у Windows Credential Manager;
- секрети не записуються в config/logs;
- зберігається мінімально необхідний доступ SFTP-акаунта;
- окремо опрацьовується захист remote backup history від масового видалення/шифрування.

Public-key authentication можна переглянути пізніше, якщо зміниться backend або з'явиться сумісний режим без погіршення операційної підтримки.

### Authenticode / підписані релізи

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

**Статус (2026-08-25): цикл закрито.** PR #45 (`hotfix/5.0.1`) злито,
stable `5.0.1` випущено 2026-08-18 (тег `v5.0.1`, CHANGELOG §5.0.1) і
синхронізовано назад у `developer`. Формального real-server acceptance
саме PR #45 у репозиторії не зафіксовано (промоція спиралась на
CI + повний self-test із regression-доказом); notification
routing/override поведінку повторно підтверджено real-server
acceptance циклу 5.1.0 (rc.2/rc.4 PASS).

Поточний production-дефект notification override має бути закритий до нових feature-релізів.

Критерії завершення:

- [ ] PR #45 проходить real-server acceptance. *(не зафіксовано окремо;
      покрито опосередковано acceptance 5.1.0-rc.2/rc.4)*
- [ ] Перевірено `NotificationMode=none/errors_only/all` з `-EnableAllSlack`/`-DisableAllSlack`. *(окремий протокол відсутній)*
- [ ] Перевірено GENERAL/ALERTS routing і credential fallback. *(routing підтверджено acceptance 5.1.0-rc.4)*
- [ ] Перевірено Maintenance final report і критичні alerts. *(окремий протокол відсутній)*
- [x] `5.0.1-rc.1` промотовано у stable `5.0.1` без функціональних змін після acceptance.
- [x] Hotfix синхронізовано назад у `developer`.

### P0.2 — Закрити release governance

Мета — унеможливити повторення прямого feature merge у `master` в обхід RC/acceptance.

**Статус (2026-08-26): закрито.** PR #46 злито
(`ci/Test-BRAVOMasterMergePolicy.ps1` працює в CI). PR #92 додав
семантичне порівняння stable-версій (`Test-BRAVOStableVersionPromotion`
з регресіями, включно з кейсом `5.10.0 > 5.9.0`). Гілка
`hardening/release-governance` додала перевірку repository identity
(`Test-BRAVOMasterMergeSource`: PR у `master` приймається лише з
`developer`/`hotfix/*` ЦЬОГО репозиторію; fork з однойменною гілкою —
FAIL; невідомий head-репозиторій — fail-closed). Репозиторій став
публічним, тож branch protection доступний без GitHub Pro: увімкнено
для `master` і `developer` (PR-only, required checks, заборона force
push/видалення, `enforce_admins` — admin-обхід на кшталт прецеденту
PR #61 у вікні промоції 5.1.0 технічно заблоковано). Фактична
конфігурація — `RELEASE_POLICY.md`, розділ 13.

Критерії завершення:

- [x] PR #46 доведено до merge після виправлення всіх review findings.
- [x] Gate перевіряє дозволене джерело PR (`developer` або `hotfix/*`) і repository identity.
- [x] Gate вимагає семантичне збільшення stable version, а не лише нерівність рядків. *(PR #92)*
- [x] `master` не приймає feature/fix PR напряму. *(CI-гейт + branch protection з `enforce_admins`)*
- [x] Branch/repository settings максимально обмежують direct push, force push і випадковий merge настільки, наскільки це дозволяє поточний GitHub plan. *(branch protection увімкнено на `master` і `developer`, 2026-08-26)*

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

**Статус (2026-08-26, цикл 5.3.0): реалізовано** (гілка
`feature/restore-verify`): задача `BRAVO_RESTORE_VERIFY` (weekly-тригер,
типово Сб 04:00, `schedulerSettings.RestoreVerify`) запускає наявний
`BRAVO_RESTORE_TEST.ps1 -NoPause -NotifyOnSuccess`; стан у
`%ProgramData%\BRAVO\State\BRAVO_RESTORE_VERIFY_STATE.json`
(модуль `BRAVO.RestoreVerify`, атомарний запис, `LastVerifiedAt`
оновлюється лише повністю чистим прогоном); Health-крок
«Відновлюваність (restore drill)» оцінює вік проти
`restoreVerifySettings.MaxVerificationAgeHours` (типово 216 год).
Drill отримав runtime guard і bounded cleanup покинутих drill-каталогів.
Real-server acceptance розкладу/нотифікацій — окремим прогоном.

`BRAVO_RESTORE_TEST.ps1` став штатним елементом експлуатації, а не ручною процедурою.

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

- [x] Додано окремий scheduler task `BRAVO_RESTORE_VERIFY`.
- [x] Розклад задається конфігурацією (`RestoreVerify.WeeklyOn/At`); типовий інтервал — щотижня (Сб 04:00).
- [x] Restore drill не торкається production paths і не зупиняє служби. *(незмінна властивість BRAVO_RESTORE_TEST)*
- [x] Є stable exit code/result contract. *(0/10/41/90 + JSON `-ResultPath`/`-AsJson` — без змін; + state-файл)*
- [x] Health може показати вік останньої успішної restore verification. *(крок «Відновлюваність (restore drill)»)*
- [x] Failure піднімає WARNING/CRITICAL залежно від причини. *(WARN→WARNING, FAIL→CRITICAL в ALERTS; SUCCESS→GENERAL для scheduled)*
- [x] Є bounded cleanup тимчасових restore artifacts. *(сироти >7 діб, ≤10 за прогін)*

### P1.2 — Стабільний release-артефакт

Мета — перестати трактувати довільний checkout/набір файлів як release package.

Мінімальний artifact:

```text
BRAVO-Toolkit-X.Y.Z.zip
BRAVO-Toolkit-X.Y.Z.zip.sha256
release-manifest.json
```

**Статус (2026-08-25): закрито.** Реалізовано
`.github/workflows/release-artifact.yml` +
`ci/New-BRAVOReleaseArtifact.ps1`: збірка з конкретного git ref із
провенанс-гейтом (`sourceCommit` має бути повним hash), `*.zip.sha256`,
`release-manifest.json` (product/version/sourceCommit/files+hashes),
повний self-test із розпакованого артефакту перед публікацією; процедура
отримання/перевірки описана в `BRAVO_SETUP.md`, розділ «Отримання
комплекту (release artifact)».

Критерії завершення:

- [x] Artifact збирається автоматично з конкретного release commit/tag.
- [x] SHA-256 перевіряється до deployment.
- [x] Manifest містить product, version, sourceCommit і список файлів/хешів.
- [x] Artifact проходить CI/self-test перед публікацією.
- [x] Документація оновлення посилається на artifact, а не на ручне копіювання випадкового checkout.

Підпис artifact/manifest є optional future hardening, не blocker для цього етапу.

### P1.3 — Життєвий цикл backup / розділення retention

Мета — зменшити blast radius credentials, якими користується Archive.

Напрями:

- BRAVO створює нові generations;
- destructive retention виконується окремим authority/process там, де це технічно можливо;
- останні verified generations мають незалежний захист від помилкового або зловмисного видалення.

Цей пункт може бути реалізований разом із P0.3, якщо storage architecture дозволяє.

### P1.4 — SELF_TEST fail-fast structural validation і timing telemetry

**Статус: DONE** (PR #138, змерджено в `developer` 2026-09-09, squash
commit `57b16cba77ea4f30fa4464a9be2d8bfa122c132a`).

Реалізовано:

- рання fail-closed structural preflight (runtime manifest integrity,
  обов'язкові manifest-файли, синтаксис production `*.Runtime.ps1`,
  критичний JSON) на bootstrap-межі, до імпорту manifest-covered
  helper-модулів;
- контрольований (не uncontrolled exception) fail-closed шлях для
  bootstrap integrity-scan збоїв;
- Phase 0 short-circuit: структурний провал зупиняє доменні тести й
  виходить через стандартний report-шлях;
- diagnostic timing telemetry: total wall-clock, per-suite wall-clock,
  `Root (inline)` wall-clock, assertion interval telemetry, Top 20
  найдовших assertion-інтервалів;
- framework-регресії для bootstrap integrity, tampered manifest-covered
  helper, invalid bootstrap manifest, Phase 0 short-circuit, fixture
  setup/cleanup провалів (включно з ACL/access-denied cleanup-станами
  і TEMP-незалежним fixture setup через `[IO.Path]::GetTempPath()`).

Final validation evidence: `PASS: 1893, FAIL: 0, Exit: 0, Total
wall-clock: 00:07:57.113`.

**Важливо:** ця telemetry — вимірювання/діагностика, НЕ P1
performance optimization. `SELF_TEST` не став суттєво швидшим
внаслідок цього PR; він лише отримав інструменти для вимірювання, де
саме витрачається час. Проблема довгого `SELF_TEST` (P1.5 нижче)
залишається відкритою.

### P1.5 — Оптимізація продуктивності SELF_TEST

**Статус: IN PROGRESS.** Фаза 1 і селективний прогін реалізовані;
подальші напрями лишаються відкритими. Окремо від P1.4, яка додала лише
вимірювання, не пришвидшення.

**Фаза 1 — DONE** (PR #182, `0208515`; вихідна задача #157). Прибрано
рівно ту роботу, що виконувалась кілька разів над тими самими файлами:
чотири статичні аналізи, які кожен окремо повністю розбирав КОЖЕН файл
комплекту, тепер живляться спільним AST (один розбір на файл); власне
джерело `BRAVO_SELF_TEST.ps1` (~1.3 МБ) більше не розбирається заново
трьома структурними guard-ами. Жодної перевірки не видалено, не
пропущено й не переведено в selective-режим; порядок assert-ів не
змінено. AST комплекту навмисно НЕ кешується між файлами, тож пікова
пам'ять не зросла.

**Селективний прогін — DONE** (PR #192, `444f93c`; вихідна задача #187,
фаза 2). `BRAVO_SELF_TEST.ps1 -Suite <Fragment>[,<Fragment>]` виконує
лише названі фрагменти. Два обмеження зафіксовані в самій реалізації, а
не в домовленості:

- inline-тіло кореня виконується ЗАВЖДИ — фрагменти не самодостатні,
  вони споживають фікстури, які готує саме це тіло (перевірено поіменно:
  `$archiveScriptText`, `$archiveRuntimeModuleText`, `$resolvedConfig`,
  `$backupRootPath`, `$statePath`). Тому економія обмежена зверху:
  корінь — це 961 з 2107 перевірок і 188.6 с із 477.5 с сумарного часу
  suite-ів;
- **повний канонічний прогін без `-Suite` лишається ЄДИНИМ gate-ом
  мержу й релізу.** `-Suite` — інструмент розробки, а не заміна
  release-gate-у.

Напрями, що **лишаються відкритими** (жоден ще не реалізований):

- `-Affected` — вибір фрагментів за зміненими файлами;
- оптимізація runtime child-process smoke-test фікстур;
- декомпозиція кореневого `BRAVO_SELF_TEST.ps1` на менші одиниці
  виконання без втрати hermetic-гарантій;
- скорочення/видалення непотрібних `Start-Sleep`-очікувань там, де
  timing telemetry (P1.4) підтверджує, що вони не потрібні;
- безпечний паралелізм там, де fixture-ізоляція це дозволяє.

Використовувати timing telemetry з P1.4 (per-suite wall-clock, Top 20
найдовших assertion-інтервалів) як evidence base для пріоритизації цієї
роботи, а не здогадки. Кожна наступна оптимізація приймається лише з
BEFORE/AFTER raw timings щонайменше трьох повних прогонів того самого
HEAD; за відсутності доказової переваги — не комітити спекулятивний
rewrite.

## P2 — централізована експлуатація

### P2.1 — Машинозчитуваний health/status-контракт

**Статус (2026-08-26, цикл 5.3.0): реалізовано** (гілка
`feature/status-contract`): модуль `modules/BRAVO.Status/` — канонічний
власник контракту; кожна з чотирьох операцій після обчислення exit code
атомарно пише `%ProgramData%\BRAVO\State\STATUS\BRAVO_STATUS_<Operation>.json`
(fail-soft: помилка запису ніколи не змінює результат операції).
Спільне ядро схеми + `details` per-operation; поля
`lastCompleteGeneration`/`lastRestoreVerifiedAt`/`*Verified`/
`runtimeIntegrity`/`toolIntegrity` з ескізу нижче живуть у `details`
Health-файла. Транспорт/моніторинг поверх файлів — P2.2 (свідомо не
входить у v1 за рішенням власника: «моніторинг поки не робимо,
укріплюємо основу»).

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

- [x] Один versioned schema для machine consumers. *(BRAVO.Status, schemaVersion 1)*
- [x] Жодних secret-bearing values. *(контракт + самотест Status/NoSecretBearingFields)*
- [x] Exit codes лишаються canonical source of failure class. *(status — проєкція exitCode; fail-soft самотести CallSiteIsFailSoft)*
- [x] JSON можна використовувати Zabbix/telemetry без парсингу console text. *(4 файли в `STATUS\`; сама інтеграція — P2.2)*

### P2.2 — Віддалена телеметрія парку серверів

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

**Статус: Foundation completed; B0–B6 і pilot tooling merged; лишаються
B5 (міграція парку), B4 частина 2 і B7.**

FEAT-001 із `TODO_FEATURES.md` залишається важливим, але не випереджає production safety та restore verification.

Ціль: package defaults + site data-only overrides + deterministic schema validation + legacy migration.

**P0 Configuration Foundation — DONE** (змерджено в `developer`):
canonical built-in defaults, deterministic deep merge (array replace,
явний `@()` — валідний override, `Limits.ExcludedDrives` дефолт —
`@()`), опційний `BRAVO.config`, `-ConfigPath` AUTO/EXPLICIT-контракт,
derivation після merge, post-merge security-invariant re-validation,
data-only `BRAVO.local.config` (dot-шлях → значення).

**Site-шар перейшов на non-executing AST-parser (#154, B1).** Раніше
тут було `CheckRestrictedLanguage` з порожніми command/variable
allow-lists, а потім `& $scriptBlock`: виклики cmdlet/функцій і
посилання на недозволені змінні блокувались до виконання, але
граматика від цього не ставала суто літеральною (restricted-language
усе ще допускає окремі вирази — наприклад, арифметичні/range), і
validated `ScriptBlock` усе одно ВИКОНУВАВСЯ, тож дозволений вираз
обчислювався. Тепер site-файл парситься в AST і обходиться за явним
fail-closed переліком дозволених вузлів-літералів
(`modules/BRAVO.Configuration/BRAVO.Configuration.DataFile.psm1`);
scriptblock не створюється й не викликається. Сам `BRAVO.config`
лишається виконуваним PowerShell-скриптом — і таким лишиться до
прибирання з пакета (B4, частина 2); на DATA-only формат він не
переводиться. Precedence сьогодні (перехідний стан): `DEFAULT <
BRAVO.config (опційно) < BRAVO.local.config (опційно)`. Деталі —
`docs/design/BRAVO_CONFIGURATION_FOUNDATION_DESIGN.md`.

**Канонічний цільовий контракт (НОРМАТИВНО).** Цільова модель —
**двошарова**:

```text
Built-in defaults  <  BRAVO.local.config (опціональний, DATA-only)
```

- рішенням власника **D2** (2026-09-14, PR #173) перейменування
  локального шару скасовано: назва `BRAVO.local.config` лишається,
  файлу `BRAVO.config.local` не буде, окремого машинно-локального шару
  не буде;
- рішенням власника від 2026-09-14 (#154) `BRAVO.config` **не
  конвертується** у DATA-only формат — він прибирається з пакета (B4,
  частина 2). DATA-only `BRAVO.config` не є і ніколи не був
  затвердженою ціллю після цього рішення;
- на час переходу завантажувач продовжує читати наявний на сервері
  legacy `BRAVO.config` (пріоритет `DEFAULT < BRAVO.config <
  BRAVO.local.config`), і комплект **ніколи** не видаляє цей файл із
  сервера сам — крок виконує оператор після звірки;
- рішенням власника **D3** (2026-09-14, PR #173) forward-compat для
  невідомого КІНЦЕВОГО сегмента (leaf) збережено як кінцевий стан:
  невідомий top-level блок і невідомий батьківський вузол — fail
  closed, невідомий leaf — приймається з попередженням і метаданими.

**Config v2 — IN PROGRESS / не завершено.** Merged: B0 (#169), B1
(#174), B2 (#183), B3 (#184), B6 (#185), B4 частина 1 (#186), parity
harness у CI (#193), а також контрольований pilot-інструментарій
міграції — артефакт, оркестратор `deploy/Start-BRAVOConfigV2Pilot.ps1`
та фікси, знайдені реальними e2e-прогонами на throwaway VM (#207–#212).
`VERSION.json.configSchemaVersion` лишається `1`.

**Залишилося рівно три етапи**, у жорсткому порядку:

1. **B5** — послідовна міграція парку (по одному серверу) на
   `BRAVO.local.config` без зміни ефективної конфігурації;
2. **B4, частина 2** — прибирання `BRAVO.config` з пакета; блокується
   B5, виконується окремими комітами (фікстури self-test → parity
   harness → видалення файлу);
3. **B7** — Definition-of-Done regression matrix на фінальному шляху
   завантаження плюс промоція `Config parity (BRAVO_CONFIG_LOADER)` у
   required status check.

**Config v2 не можна позначати завершеним**, доки B5, B4 частина 2 і B7
не завершені фактично, з доказами. Повний перелік залишкових gaps,
target architecture, safe declarative parser requirement, схема,
міграція й DoD regression matrix —
`docs/design/BRAVO_CONFIGURATION_V2_COMPLETION.md`; виконавча обгортка —
Issue #154.

### P3.2 — Атомарний версійований deployment / rollback

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

### P3.2a — BRAVO_UPDATE.ps1: operator-triggered оновлення (перенесено на 5.3.0)

**Не реалізовується у 5.2.0.** Раніше запланований на цикл 5.2.0, але
перенесений на `5.3.0`: це окремий функціональний цикл із новою
поверхнею атаки (download release-артефакта з GitHub, перевірка
цілісності отриманого артефакта, staging, `robocopy /MIR` у runtime,
partial-update semantics, rollback, recovery після перерваного update,
trust/integrity guarantees) — кожен пункт вимагає власного acceptance,
який не повинен блокувати вже готовий 5.2.0 scope (виправлення
production-інцидентів циклу dev.1). У коді 5.2.0 щодо P3.2a — нуль змін;
`BRAVO_UPDATE.ps1` і `modules/BRAVO.Update/` реалізуються окремим циклом.

Проміжний етап P3.2 (закриває його кроки staging + validation +
rollback у спрощеній формі), запланований на цикл 5.2.0. Автоматизує
рівно те, що виконувалось вручну при оновленні парку до v5.1.0
(production-сервер BRAVO, 2026-08-20), разом із виявленими там граблями.

Форма: thin entrypoint `BRAVO_UPDATE.ps1` + домен-модуль
`modules/BRAVO.Update/`. Запуск — ЛИШЕ явною командою оператора на
сервері (elevated); жодного scheduled-тригера і жодного silent-режиму.

Обов'язкові кроки одного прогону:

1. TLS 1.2 примусово (legacy-сервери 2016 не мають його дефолтом);
2. завантаження артефакта GitHub Release за явним тегом (`-Tag vX.Y.Z`,
   без "latest" за замовчуванням) + звірка SHA-256 з `.zip.sha256`;
3. staged-розпакування в тимчасовий каталог, НЕ в runtime;
4. диф `BRAVO.config` поточного комплекту зі staged: змінені ЗНАЧЕННЯ
   (не коментарі/нові дефолти) -> STOP з переліком, оновлення
   продовжується тільки після явного підтвердження перенесення;
5. preflight: жодне завдання `\BRAVO\` не Running;
6. backup поточного комплекту копіюванням у `<runtime>.old_<ver>`
   (Rename-Item каталогу runtime НЕМОЖЛИВИЙ — ACL-захист
   BRAVO_TASKS_INSTALL забороняє його навіть адміністратору; спроба
   rename+move кладе новий комплект УСЕРЕДИНУ старого і блокує нічні
   завдання guard-ом з кодом 33);
7. дзеркалення staged у runtime НА МІСЦІ (robocopy /MIR з виключенням
   LOGS) — шлях, ACL і визначення завдань Планувальника не змінюються;
8. гейти після заміни: VERSION.json = очікуваний тег; Runtime Guard
   exit 0; `BRAVO_SETUP -Action Scheduler` (нові завдання версії);
   `BRAVO_SETUP -Action Test` без FAIL;
9. update journal: запис (стара/нова версія, тег, sha256, оператор,
   результати гейтів) у machine state;
10. автоматичний відкат із backup-копії при провалі будь-якого гейта
    8 (дзеркалення назад тим самим механізмом), зі збереженням логів
    невдалої спроби.

Свідомо НЕ входить у P3.2a (лишається за повним P3.2/P4):
versioned-каталоги з deployment pointer, atomic activation,
auto-download за розкладом, будь-який silent-режим, підпис артефактів.
Довіра до артефакта в P3.2a = TLS до GitHub + SHA-256 з того самого
каналу — прийнятно для операції, яку ініціює і спостерігає оператор,
недостатньо для автономної.

## P4 — опційне посилення захисту

Виконувати лише після основних operational задач або коли з'явиться дешевий/простий шлях реалізації:

- Authenticode для PowerShell;
- signed release manifest;
- signed git tags;
- SFTP public-key authentication для backend, який це підтримує;
- інші supply-chain controls, що потребують окремої PKI/сертифікатів.

Ці пункти не повинні блокувати P0–P3.

## Рекомендована послідовність

```text
1. acceptance/stable для hotfix 5.0.1
2. gate управління релізами master/release governance
3. захист історії віддалених резервних копій
4. плановий Restore Drill
5. stable release ZIP + SHA-256 + маніфест
6. розділення повноважень retention
7. машинозчитуваний контракт статусу
8. віддалена телеметрія парку серверів / інтеграція Zabbix
9. Config v2
10. атомарний deployment + rollback
11. auto-update
12. опційне підписання / посилення захисту public-key
```

## Що не є поточним пріоритетом

- загальний refactoring без конкретного defect/security/testability benefit;
- microservice-style дроблення PowerShell-модулів;
- SFTP public-key migration для Hetzner Storage Box;
- Authenticode лише заради формальної наявності підпису;
- remote command execution через telemetry gateway;
- auto-update до появи atomic rollback і перевіреного release artifact.
