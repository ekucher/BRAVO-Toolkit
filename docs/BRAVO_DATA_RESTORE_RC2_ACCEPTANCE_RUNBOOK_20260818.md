# BRAVO DataRestore 5.1.0-rc.2 — Acceptance Runbook (готовність до наступного DEV-LIMS прогону)

Цей документ — підготовка до наступного реального acceptance-прогону на
DEV-LIMS, **не сам прогін і не evidence**. Він фіксує: (1) що змінилось з
моменту останнього NO-GO вердикту, (2) відтворені процедури для сценаріїв, чиє
визначення підтверджено в репозиторії/історії PR, (3) явну прогалину для
сценаріїв, чиє визначення в репозиторії відсутнє, (4) чек-лист перед стартом.
Заповнювати результатами реального прогону варто в окремому файлі за зразком
`docs/BRAVO_DATA_RESTORE_RC2_ACCEPTANCE_20260815.md` (гілка
`evidence/33c5aca-rc2-devlims-acceptance`), а не в цьому.

## 1. Candidate identity (на момент підготовки цього runbook)

```
HEAD:            d498a9d (developer)
VERSION.json:
  packageVersion:  5.1.0-rc.2
  releaseChannel:  prerelease
  buildId:         0a51d97
  sourceCommit:    0a51d9780c114130f9e4c7b325d4926f8f20c8bb
```

`sourceCommit` вказує на batьківський коміт `0a51d97` (PR #48, канонічний
ROADMAP.md) — стандартний self-referencing patern stamp-коміту. Якщо перед
реальним прогоном додасться ще хоч один коміт на `developer` (включно з
docs-only) — **обов'язково перестемпити** (`ci\Update-BRAVOVersionStamp.ps1
-Apply`) перед стартом, інакше evidence-документ знову описуватиме не той
коміт, що реально тестувався (та сама проблема, що вже сталась із
`fb1b6ba` → `0a51d97`, 15 комітів розходження).

## 2. Що змінилось з моменту NO-GO (`33c5aca`, 15.08.2026, candidate `047d321`)

| Коміт/PR | Зміна |
|---|---|
| PR #40 (`497e7b1`…`f142b38`) | Детермінований B20 failpoint (`BRAVO_DATARESTORE_TEST_HOOKS=ACCEPTANCE_ONLY` + `BRAVO_DATARESTORE_TEST_FAILPOINT=Point:Component`, default OFF, без нових CLI-параметрів) + 6 раундів review, 37 findings (кілька P1: move-aside-armed guard проти видалення непорушеної live-директорії, generationId-injection захист, ACL-copy тепер fatal, WinSCP script permissions, rollback-failure gate на service-restart). |
| PR #41 (`f142b38`+7) | Сьомий review-раунд, 7 findings (2 P1: fail-open service-state check, хибне повідомлення про наявність prerestore-копії при rollback). |
| PR #42 | Реальний DEV-LIMS-знайдений дефект: **кожен `-Source SFTP` restore падав з exit 90** на staging free-space preflight (`ProbeDirectory` не оголошено на staging-requirement). Виправлено + regression-тест. Це прямо стосується сценарію "PHASE 3/B4" з попереднього прогону. |
| PR #43/#44 | `BRAVO_DATA_RESTORE_MATRIX_TEST.ps1` — автоматизована E2E-матриця, **Source=Local лише**, синтетичні фікстури, 16 комбінацій (`Component` × `Mode` × сценарій), тепер у CI на кожен PR. Це **не замінює** реальний DEV-LIMS/SFTP acceptance, але знімає частину ручного навантаження для Local-комбінацій. |

Отже: сам B20-механізм детермінізовано, знайдений і виправлений реальний SFTP-дефект (B4-клас), і пройшло 44+ review-виправлень — але **жодного повторного PASS-вердикту на DEV-LIMS не задокументовано** після цих змін.

## 3. Відтворені процедури (з попереднього evidence + опису PR — підтверджено)

### PHASE 0-4 (базова готовність)
З попереднього прогону: перевірка candidate identity, конфігурації,
Runtime Guard, наявності `COMPLETE` generation manifest. Деталей самих
PHASE-кроків у репозиторії немає (лише підсумок PASS у `33c5aca`) — при
підготовці реального прогону звірити з `RELEASE_POLICY.md` §9.2
("Мінімальний протокол перевірки") як базовим шаблоном.

### B4-клас — SFTP staging preflight (раніше падало, тепер виправлено PR #42)
**Мета:** підтвердити, що `-Source SFTP` restore більше не падає з exit 90
на free-space preflight.
**Процедура:** `BRAVO_DATA_RESTORE.ps1 -Source SFTP -Component <X> -Mode OutOfPlace` —
очікується проходження staging free-space preflight (exit code відмінний
від 90 з причини `ProbeDirectory`; подальший результат залежить від
фактичного стану SFTP-джерела).
**Статус:** regression-тест `DataRestore/SftpStagingFreeSpaceRequirementDeclaresProbeDirectory`
у `BRAVO_SELF_TEST.ps1` підтверджує механізм статично; **реальний SFTP
прогін на DEV-LIMS ще не виконувався** після фіксу.

### B15 — single-component InPlace
**Процедура (з `33c5aca`):** `-Component <X> -Mode InPlace`, підтвердити:
exit 0, move-aside у `<Live>.prerestore_<timestamp>`, Health PASS,
BLOG-дрейф (якщо є) класифікований як "expected service activity", а не
regression.

### B16 — InPlace All
**Процедура:** `-Component All -Mode InPlace`, підтвердити: exit 0, усі 3
компоненти PASS, попередні prerestore-директорії (з B15) збережені,
служби відновлені, `BRAVO.config`/canonical generation незмінні, Runtime
Guard PASS.

### B19 — single-component rollback (fault injection)
**Процедура:** `BRAVO_DATARESTORE_TEST_HOOKS=ACCEPTANCE_ONLY`,
`BRAVO_DATARESTORE_TEST_FAILPOINT=AfterMoveAside:<X>`, `-Component <X>
-Mode InPlace`. Очікується: exit 43, move-aside відбувся, rollback
викликаний і завершений, файли/байти/fingerprint до/після ідентичні,
служби відновлені, config/canonical незмінні.

### B20 — cross-component rollback (раніше BLOCKED, тепер має бути детерміновано тестовним)
**Процедура:** `BRAVO_DATARESTORE_TEST_HOOKS=ACCEPTANCE_ONLY`,
`BRAVO_DATARESTORE_TEST_FAILPOINT=AfterMoveAside:<пізній компонент>`,
`-Component All -Mode InPlace` — тепер, з детермінованим failpoint (PR
#40), пізній компонент має падати ПІСЛЯ успішного завершення раніших
компонентів, і очікується перевірка, що **rollback коректно відкочує
лише той компонент, що реально мутувався**, а не всі. **Це головний
сценарій, заради якого весь цикл review відбувся — критичний для
PASS-вердикту.**

## 4. B17/B21/B22 — визначено наново (2026-08-18)

Оригінальне визначення цих трьох сценаріїв ніде не існує (підтверджено
користувачем — не інша машина, не інша сесія; споріднений harness для
B9/B10 теж, за словами PR #42, існував лише "in the scratchpad
acceptance harness only — not part of this repository"). Визначено
наново на основі підтвердженої білої плями: **жодна з 16 комбінацій
CI-матриці (PR #43/44) не використовує `Source=SFTP`** — CI повністю
Local-only, тому SFTP-шлях (де й стався реальний дефект PR #42) можна
підтвердити лише на реальному DEV-LIMS.

### B17 — SFTP-source restore success

**Мета:** підтвердити, що фікс PR #42 (`ProbeDirectory`) працює
end-to-end на реальному SFTP, не лише проходить preflight.
**Процедура:** `BRAVO_DATA_RESTORE.ps1 -Source SFTP -Mode OutOfPlace
-Component <один компонент, напр. MODEL>` — найбезпечніший варіант,
не чіпає live-директорію. Очікується: exit 0, staging free-space
preflight проходить (не exit 90/`ProbeDirectory`), файл фактично
завантажений з SFTP і розпакований у target, sha512/manifest-перевірка
PASS, fingerprint збігається з canonical генерацією.

### B21 — чистий аборт при збої SFTP-завантаження (перевизначено з "rollback під час download")

**Технічна знахідка (перевірено кодом, 2026-08-18):** `Invoke-BRAVODataRestoreSftpArchiveFetch`
завантажує ВСІ запитані компоненти одноразово, **до** початку циклу
move-aside/extraction (`modules/BRAVO.DataRestore/BRAVO.DataRestore.Runtime.ps1`,
рядок ~3265). Тобто на момент SFTP-завантаження жодна live-директорія
ще не займана — переривання під час завантаження не має що
відкочувати; rollback тут не застосовний за конструкцією.
**Процедура:** спричинити керовану, безпечну відмову SFTP-завантаження
(напр. `-GenerationId` із маніфестом, чий архів фактично відсутній на
SFTP, або тимчасове мережеве переривання) з `-Source SFTP`. Очікується:
exit **50** (`SftpFailed`, `modules/BRAVO.ExitCodes/BRAVO.ExitCodes.psm1`
рядок 38), **ЖОДНОЇ live-мутації** (нічого не move-aside'до — design-гарантія,
не лише очікування), і **staging-каталог НАВМИСНО збережений** (не
видалений автоматично) з повідомленням "Staging збережено для
діагностики/повтору" (`$script:dataRestoreStagingKept`, рядок 3270) —
**це задокументована навмисна поведінка, не "сміття", яке слід
очікувати прибраним.**

### B22 — real concurrent-operation lock contention

**Мета:** підтвердити, що `DataRestore` коректно очікує/відмовляє при
зайнятому machine-wide operation lock, а не виконується паралельно з
Archive/Maintenance на живих даних.
**Процедура:** запустити `BRAVO_MAINTENANCE.ps1` (або `BRAVO_ARCHIV.ps1`)
у фоні, поки він тримає `$operationLockSettings.Path`, спробувати
одночасно запустити `BRAVO_DATA_RESTORE.ps1`. За кодом
(`Enter-BRAVODataRestoreOperationLock`, рядок 737): DataRestore
polling що 30с до `schedulerSettings.OperationLockWaitMinutes`, потім
або отримує lock (якщо перший процес звільнив), або кидає помилку
"lock не звільнився за N хв.". Очікується: **жодного одночасного
доступу** до live-директорій, чіткий exit/повідомлення в обох сценаріях
(lock звільнився вчасно / timeout).

## 5. Рекомендований обсяг наступного реального прогону

Мінімально необхідне для зняття NO-GO (за спаданням пріоритету):
1. **B20** — головна причина попереднього NO-GO; тепер має бути
   детермінованим завдяки PR #40 failpoint-механізму.
2. **B17** (SFTP success) — підтвердити реальний фікс PR #42 на живому
   SFTP-джерелі (CI-матриця цього не покриває, вона Local-only).
3. **B21** (SFTP-аборт) і **B22** (lock contention) — нові сценарії,
   визначені в розділі 4; нижчий пріоритет за B20/B17, але закривають
   реальні білі плями поза CI-матрицею.
4. Повторити **B15/B16/B19** для підтвердження, що жоден з 44+
   review-фіксів не порушив раніше PASS-сценарії.

## 6. Чек-лист перед стартом (з `dev-lims-environment-facts` пам'яті сесії)

- [ ] `developer` re-stamp актуальний на момент старту (звірити HEAD == `sourceCommit`).
- [ ] Оператор на DEV-LIMS — саме `BSYSTEM\e.kucher` (домен `BSYSTEM`, не WORKGROUP).
- [ ] Runtime/BackupRoot: `E:\ARCHIV_LIMS_MONOLITH` (не застарілий `D:\BRAVO`/`D:\LIMS` шлях dev.19-стенду).
- [ ] Config: `E:\ARCHIV_LIMS_MONOLITH\BRAVO.config`.
- [ ] Є хоча б одна `COMPLETE` generation manifest для реального restore-тесту.
- [ ] Existing prerestore-evidence з попередніх прогонів не буде випадково прийнято за нове.
- [ ] Evidence-документ нового прогону комітиться і **пушиться в origin**
      одразу (не лишається лише локальним, як сталось із `33c5aca` і
      PHASE-3/B4-прогоном за PR #42).
