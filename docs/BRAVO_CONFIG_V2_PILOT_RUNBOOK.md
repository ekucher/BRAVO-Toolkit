# BRAVO Configuration v2 — controlled real-pilot runbook

**Задача:** #154, крок 2 «Remaining work» (автоматизований pilot-артефакт).
**Дата підготовки:** 2026-09-16.
**Статус:** процедура й інструмент підготовлені; на жодному реальному сервері
ще не виконувались.
**Історія:** автоматизує вручну виконуваний і прийнятий (PR #207) runbook
`docs/BRAVO_CONFIG_V2_PILOT_MIGRATION_RUNBOOK_20260916.md`. Той файл
залишається в репозиторії як історичний доказ acceptance і як fallback-
процедура, якщо з якоїсь причини `Start-BRAVOConfigV2Pilot.ps1`
використати не можна (наприклад, PowerShell Constrained Language Mode на
сервері блокує dot-source бібліотеки). Обидва runbook описують ОДНУ й ту
саму послідовність доказів (BEFORE → delta → review → backup → activation
→ ValidateOnly → semantic parity → SELF_TEST → Health → archive smoke →
acceptance → rollback) — цей документ не суперечить попередньому, а
формалізує його як CLI.

## Purpose

Довести на **одному** реальному сервері, керовано й з повним evidence-
пакетом, що перенесення site-значень із `BRAVO.config` у
`BRAVO.local.config` **не змінює ефективної конфігурації**, і зробити цей
доказ відтворюваним/автоматизованим замість ручного виконання команд.

## Scope

- Один сервер, явно вказаний через `-InstallRoot`.
- Config-міграція; **не** оновлення самого BRAVO-Toolkit (це передумова,
  не частина цієї процедури — див. «Prerequisites»).
- **Не** fleet migration, **не** видалення `BRAVO.config` фізично з
  пакета (лише з активного шляху завантаження на цьому кроці — тобто цей
  крок узагалі не видаляє файл; runbook `..._20260916.md` документує
  окремий, суворо ручний, деструктивний Крок 6, який цей автоматизований
  інструмент НЕ виконує і не збирається виконувати автоматично).

## Safety invariants

- **NO CONFIG LOSS** — backup обов'язковий і перевіряється (SHA-256) до
  будь-якого запису `BRAVO.local.config`.
- **NO SECRET LEAKAGE** — кожен evidence-файл проходить перевірку на
  sensitive-категорії ПЕРЕД записом (`Assert-BRAVOPilotEvidenceSecretSafe`
  у `BRAVOConfigV2Pilot.Runtime.ps1`); запис блокується fail-closed, якщо
  безпека даних не гарантована.
- **NO SILENT SEMANTIC CHANGE** — activation вважається успішною лише
  після `BEFORE == AFTER` semantic parity (`Compare-
  BRAVOConfigEffectiveSnapshot.ps1`, canonical, без дублювання алгоритму).
- **NO PARTIAL ACTIVATION** — запис `BRAVO.local.config` атомарний
  (`[System.IO.File]::Replace`/`Move`); при помилці оригінал лишається
  незмінним.
- `BRAVO.config` **НЕ видаляється** цим інструментом на жодному кроці.

## Prerequisites

1. `-InstallRoot` — уже встановлений комплект BRAVO-Toolkit версії, що
   містить Configuration v2 (перевіряється `-Preflight`:
   `modules\BRAVO.Configuration\BRAVO.Configuration.Snapshot.psd1`,
   `deploy\Get-BRAVOConfigSiteDelta.ps1`,
   `deploy\Compare-BRAVOConfigEffectiveSnapshot.ps1` мають існувати на
   сервері). Це окрема, вже виконана операція (`deploy\Update-
   BRAVOServer.ps1`), НЕ частина цього pilot-артефакту.
2. Windows PowerShell 5.1, права адміністратора на сервері.
3. НЕ найкритичніший LIMS-сервер парку; реальний, але некритичний
   workload.
4. Відомі поточна версія й provenance BRAVO на сервері (`VERSION.json`).
5. Верифікований зовнішній backup усього сервера (поза цим інструментом —
   evidence-backup нижче покриває лише `BRAVO.config`/`BRAVO.local.config`,
   не весь сервер).
6. Оператор присутній фізично/по RDP протягом усієї процедури.
7. Погоджене maintenance-вікно, включно з часом на можливий rollback.
8. Заплановане архівування **поза** вікном pilot (`-Preflight` best-effort
   перевіряє `Get-ScheduledTask` — WARN, не FAIL, якщо не визначено).

## Artifact verification

Перед будь-якою операцією:

```powershell
.\Test-BRAVOConfigV2PilotArtifact.ps1
```

Перевіряє: `PILOT_MANIFEST.json` (тип/схема/provenance), SHA-256 кожного
файлу проти `manifest\SHA256SUMS.json`, відсутність path traversal у
маніфесті, обов'язкові файли присутні, усі `.ps1` парсяться. Будь-яка
розбіжність — **не використовуйте цей артефакт**, отримайте новий.

## Maintenance window requirements

Мінімум: час на Preflight+Prepare (read-only, кілька хвилин) + review
(людський, без обмеження) + Backup+Activate+Validate (`BRAVO_SELF_TEST.ps1`
— історично до ~8 хвилин) + резерв на повний Rollback (та сама тривалість
ще раз). Плануйте вікно не коротше 45 хвилин.

## Procedure

Нижче `$Kit` = `-InstallRoot` (каталог встановленого комплекту на
сервері), `$Art` = каталог розпакованого pilot-артефакту.

### 0. Preflight (read-only)

```powershell
.\Start-BRAVOConfigV2Pilot.ps1 -Preflight -InstallRoot $Kit
```

**Очікується:** `[SUCCESS] Preflight PASSED`. Нічого на сервері не
змінюється — можна виконувати заздалегідь, до вікна обслуговування.

**STOP умова:** будь-який `[FAIL]` у виводі — вирішіть причину
(найчастіше: сервер ще не оновлений до версії з Configuration v2,
відсутній `BRAVO.config`, недостатньо прав) перед продовженням.

### 1. Prepare — baseline + delta

```powershell
.\Start-BRAVOConfigV2Pilot.ps1 -Prepare -InstallRoot $Kit
```

Виконує внутрішньо: Preflight (повторно) → `BRAVO_CONFIG_TEST.ps1
-FullGraph` (BEFORE) → `BRAVO_HEALTH.ps1` (BEFORE) →
`deploy\Get-BRAVOConfigSiteDelta.ps1` (candidate).

**Evidence:** новий каталог `<EvidenceRoot>\<server>-<timestamp>\` з
`preflight.json`, `before.snapshot.json`, `health.before.log`,
`delta.preview.txt`, `delta.metadata.json`, `metadata.json` (стан
`DeltaGenerated`).

**STOP умова:** помилка на будь-якому підкроці — каталог доказів
лишається зі станом `Failed` або незавершеним; перезапустіть `-Prepare`
(новий каталог створюється щоразу).

### 2. Human review gate

Відкрийте `delta.preview.txt` у виведеному `EvidenceDir`. **Це не
механічний крок** — те саме попередження, що й у ручному runbook: рядок у
`BRAVO.config` не доводить, що значення потрібне саме цій установі.

Маркери у файлі — та сама таблиця, що й у `..._20260916.md`, розділ
«Крок 2».

Коли рядки перевірені, погодьте candidate саме за показаним hash:

```powershell
.\Start-BRAVOConfigV2Pilot.ps1 -Approve -EvidenceDir $EvidenceDir -ApprovedCandidateHash <hash з виводу -Prepare>
```

**STOP умова:** якщо `-Approve` відповідає `PILOT_APPROVAL_FAILED` —
candidate змінився з моменту `-Prepare` (TOCTOU-захист); перезапустіть
`-Prepare`.

### 3. Backup + Activation

```powershell
.\Start-BRAVOConfigV2Pilot.ps1 -Activate -InstallRoot $Kit -EvidenceDir $EvidenceDir
```

Виконує: backup `BRAVO.config`(+`BRAVO.local.config` якщо є) із SHA-256
манифестом (evidence `backup-<timestamp>\backup-manifest.json`) →
перевірка цілісності backup → повторна перевірка hash candidate проти
затвердженого (TOCTOU) → синтаксична перевірка candidate (лише
data-only-літерал) → атомарна заміна `BRAVO.local.config`.

Якщо на сервері вже діє `BRAVO.local.config` з тим самим hash —
активація no-op (ідемпотентно), файл не переписується вдруге.

**STOP умова:** будь-яка помилка backup або активації — **зупиніться,
виконайте `-Rollback` нижче**, не продовжуйте до Validate.

### 4. Validate

```powershell
.\Start-BRAVOConfigV2Pilot.ps1 -Validate -InstallRoot $Kit -EvidenceDir $EvidenceDir
```

Послідовно: `BRAVO_SETUP.ps1 -ValidateOnly` (read-only перевірка) →
AFTER-знімок (`BRAVO_CONFIG_TEST.ps1 -FullGraph`) → semantic parity
BEFORE↔AFTER (`Compare-BRAVOConfigEffectiveSnapshot.ps1`) →
`BRAVO_SELF_TEST.ps1` (acceptance: exit 0 **і** відсутність
`[НЕДОСТУПНО]`/`[FAIL]`, контракт `OPERATIONS.md`/`RELEASE_POLICY.md`) →
Health (порівняння нових `[CRITICAL]`/`[FAIL]`/`[ERROR]`-рядків проти
`health.before.log`) → archive smoke (`BRAVO_DRY_RUN.ps1`).

**Evidence:** `validate-only.log`, `after.snapshot.json`, `parity.json`,
`self-test.log`, `health.log`, `archive-smoke.log`.

**STOP умова:** будь-яке `[FAIL]` у виводі команди — стан переходить у
`Failed`, інструмент явно рекомендує `-Rollback`. **Не намагайтесь
виправляти окремі знахідки на цьому кроці pilot.**

### 5. Accept

```powershell
.\Start-BRAVOConfigV2Pilot.ps1 -Accept -EvidenceDir $EvidenceDir
```

Звіряє всі критерії (нижче, «Exit criteria») з фактично зібраним evidence
і записує `acceptance.json` з результатом `PILOT ACCEPTED` або
`PILOT NOT ACCEPTED` (з переліком незадоволених критеріїв).

### 6. Rollback (за потреби, з будь-якого кроку після Activation)

```powershell
.\Start-BRAVOConfigV2Pilot.ps1 -Rollback -InstallRoot $Kit -EvidenceDir $EvidenceDir
```

Відновлює з останнього `backup-*` каталогу в `$EvidenceDir` (незалежно
від того, на якому кроці зупинились), перевіряє SHA-256 відновлених
файлів, потім повторює `ValidateOnly` → знімок → parity з BEFORE →
`BRAVO_SELF_TEST.ps1` → Health. **Rollback НЕ повідомляє успіх, доки всі
ці докази не пройдені** — сам факт копіювання файлів недостатній.

**Evidence:** `rollback.json` з полем `Result` = `ROLLBACK SUCCESS` лише
за повного проходження; інакше `ROLLBACK INCOMPLETE` з переліком кроків,
що не пройшли, — сервер потребує ручного втручання, не вважайте pilot
завершеним.

### 7. Status (у будь-який момент, read-only)

```powershell
.\Start-BRAVOConfigV2Pilot.ps1 -Status -EvidenceDir $EvidenceDir
```

## Evidence collection

Каталог `<EvidenceRoot>\<server>-<timestamp>\` (типово
`%ProgramData%\BRAVO\ConfigV2PilotEvidence\`) містить усі файли, перелічені
вище, плюс `metadata.json` (машинно-читний журнал стану/переходів).
Жоден evidence-файл не містить резолвнутих секретів — гарантовано
перевіркою `Assert-BRAVOPilotEvidenceSecretSafe` перед кожним записом
(fail closed, якщо безпеку не можна гарантувати).

## Troubleshooting

| Симптом | Причина | Дія |
| --- | --- | --- |
| `Preflight` FAIL на `InstallRootHasConfigurationV2Support` | сервер не оновлений | оновіть BRAVO-Toolkit окремою операцією, повторіть Preflight |
| `-Approve` кидає `PILOT_APPROVAL_FAILED` | candidate змінився з моменту `-Prepare` | перезапустіть `-Prepare` |
| `-Activate` кидає `PILOT_ACTIVATION_FAILED` (TOCTOU) | candidate змінився між Approve і Activate | `-Rollback`, потім `-Prepare` заново |
| `-Validate` FAIL на self-test із `[НЕДОСТУПНО]` | AppLocker/Constrained Language Mode на хості | задокументуйте причину окремо; це НЕ автоматично прийнятний результат |
| `-Rollback` завершується `ROLLBACK INCOMPLETE` | один з пост-restore доказів не пройшов | сервер потребує ручного втручання — НЕ вважайте pilot завершеним, ескалюйте власнику |

## Post-pilot observation

Технічне acceptance (`PILOT ACCEPTED`) — **не** те саме, що готовність до
fleet migration. Після acceptance:

- негайне прийняття (evidence-пакет);
- + наступна запланована архівація (спостерігайте лог реальної, не
  smoke-архівації);
- + наступний цикл Health;
- + функціональне підтвердження оператора (продукт справді працює для
  реального workload).

Точна тривалість спостереження узгоджується з існуючою операційною
моделлю BRAVO — цей runbook не вигадує нового SLA.

## Pilot ≠ fleet acceptance

`PILOT ACCEPTED` означає: **один** сервер технічно підтвердив
BEFORE==AFTER semantic parity. Це НЕ:

- дозвіл на fleet migration;
- дозвіл видаляти `BRAVO.config` з пакета (окрема, суворо ручна операція,
  документована в `..._20260916.md`, Крок 6, і не входить у scope цього
  автоматизованого інструменту);
- автоматичне схвалення для будь-якого іншого сервера.

Кожен наступний сервер — окрема, явно авторизована операція.

## Exit criteria

- [ ] `Test-BRAVOConfigV2PilotArtifact.ps1` — `[SUCCESS]`;
- [ ] `-Preflight` — `PASSED`;
- [ ] `-Prepare` — BEFORE-знімок і delta згенеровані;
- [ ] Human review — `human-review.json` з hash, що збігається з
      candidate;
- [ ] `-Activate` — backup verified, атомарна активація без помилок;
- [ ] `-Validate` — `ValidateOnly` read-only PASS, semantic parity
      BEFORE==AFTER (0 неочікуваних відмінностей), `BRAVO_SELF_TEST.ps1`
      exit 0 і без `[НЕДОСТУПНО]`/`[FAIL]`, Health без нових деградацій,
      archive smoke PASS;
- [ ] `-Accept` — `acceptance.json.Result` = `PILOT ACCEPTED`;
- [ ] `BRAVO.config` лишився на місці, не видалений;
- [ ] Rollback перевірений як executable (див. failure-injection тести
      `selftest\BRAVO_SELF_TEST.ConfigV2PilotArtifact.ps1`) — не
      обов'язково виконаний на pilot-сервері, якщо Accept успішний, але
      мусить бути доведено виконуваним на synthetic fixture.

Лише після виконання ВСІХ пунктів має сенс переходити до наступного
кроку спостереження/fleet-обговорення.
