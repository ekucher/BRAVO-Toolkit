# BRAVO-Toolkit 5.2.3-rc.3 — зведений acceptance evidence (2026-09-__)

Статус: **ЧЕРНЕТКА — acceptance НЕ завершено.** Це заготовка протоколу, а не
доказ. Поля з `<...>` заповнюються під час прогону на реальних серверах.
Документ не є авторизацією промоції: вердикт acceptance і рішення про
промоцію — окремі кроки (`RELEASE_POLICY.md` §9.3, §4).

Якщо acceptance завершиться іншою датою — перейменувати файл на дату
фактичного завершення (конвенція `docs/BRAVO_520_RC13_ACCEPTANCE_EVIDENCE_20260826.md`).

## 1. Ідентичність кандидата

| Поле | Значення |
|---|---|
| Гілка | `hotfix/5.2.3` (база — `master` `15ce820` = `v5.2.2`, розходження немає) |
| Тег кандидата | `v5.2.3-rc.3` (на коміті-stamp `72c28b5`) |
| sourceCommit / buildId (`VERSION.json` на rc.3) | `a008f781488eb181cdd4c02320351e0e264e5f50` / `a008f78` |
| Голова гілки на момент acceptance | `92f2683` (rc.3 + промоційний bump `3fb1367` + фікс хеша маніфесту) |
| Базова stable (поведінковий baseline) | `5.2.2` (тег `v5.2.2` = `15ce820`) |
| Артефакт | `<BRAVO-Toolkit-5.2.3-rc.3.zip, SHA-256 ...>` або «розгорнуто з робочої копії гілки» |

### 1.1. Ключове звуження обсягу перевірок

Production-runtime кандидата **байт-у-байт ідентичний rc.2**:

```
git diff --name-only 1addec1 92f2683 -- 'modules/**' 'BRAVO_*.ps1' 'Tools/**' 'BRAVO.config'
→ (порожньо)

git diff --name-only 1addec1 92f2683
→ BRAVO_SETUP.md  CHANGELOG.md  README.md  RUNTIME_MANIFEST.json  VERSION.json
   selftest/BRAVO_SELF_TEST.MaintenanceDiskSpace.ps1
```

Отже сценарії, вже пройдені на rc.2, зараховуються без повторного прогону —
їх треба лише перелічити в розділі 2 з поміткою «покрито rc.2». Повторення
вимагають тільки ті кроки, до яких acceptance rc.2 не дійшов.

## 2. Real-server acceptance по кандидатах

| Кандидат | Дата | Сервер(и) | Обсяг | Результат |
|---|---|---|---|---|
| rc.1 | 2026-08-31 | — | acceptance не проводився; кандидата замінено rc.2 | n/a |
| rc.2 | 2026-09-02 | `LIMS-TOP` | виявлено непортативність self-test-фікстур (11 сценаріїв залежали від наявності дисків `D:`/`E:`) | FAIL → rc.3 |
| rc.3 | `<дата>` | `<сервер(и)>` | `<обсяг>` | `<PASS / FAIL>` |

## 3. Обов'язкові перевірки (`RELEASE_POLICY.md` §9.1)

| Перевірка | Команда | Результат | Джерело |
|---|---|---|---|
| Оновлення комплекту | `BRAVO_SETUP.ps1` | `<>` | `<rc.3 / покрито rc.2>` |
| Валідація | `BRAVO_SETUP.ps1 -ValidateOnly` | `<>` | `<>` |
| Доступи під SYSTEM | `BRAVO_DRY_RUN.ps1 -TestAccess` | `<>` | `<>` |
| Реальна архівація | `BRAVO_ARCHIV.ps1` | `<один GenerationId для MODEL/BLOG/BRAVOEXCH, manifest COMPLETE>` | `<>` |
| Перевірка архівів 7-Zip | у складі прогону | `<>` | `<>` |
| SFTP | у складі прогону | `<N/N>` | `<>` |
| SMB | у складі прогону | `<N/N або «компонент вимкнено»>` | `<>` |
| Health | `BRAVO_HEALTH.ps1` | `<0 errors>` | `<>` |
| Maintenance | `BRAVO_MAINTENANCE.ps1` | `<>` | `<>` |
| Запуск від `NT AUTHORITY\SYSTEM` | Task Scheduler | `<>` | `<>` |
| Відсутність секретів у журналах | пошук по логах | `<0 входжень>` | `<>` |
| Коди завершення | Task Scheduler history | `<>` | `<>` |
| Сумісність (Windows / PS 5.1) | — | `<версія ОС, версія PS>` | `<>` |
| Restore test | `BRAVO_DATA_RESTORE` з explicit `-GenerationId` | `<>` | `<>` |

Restore обов'язковий: зміни зачіпають backup-тракт.

## 4. Нова поверхня 5.2.3 — operation-aware disk-space policy

Перевіряється не лише «пройшло/заблоковано», а й **причина в журналі**
(`Write-BRAVODiskSpaceDecisionLog`): саме її побачить оператор о 3:00.

| # | Сценарій | Очікувано | Факт |
|---|---|---|---|
| 1 | Місця вистачає всюди | архівація йде; `ArchivePeakSafe`, `RequirementGranularity` = `Entity` або `CapacityGroup` | `<>` |
| 2 | Мало місця на диску, який операція НЕ використовує (`C:` з логами при архівації на `D:`/`E:`) | **не блокує**; health-попередження `BelowHealthFloorNoFreeSpaceRequirement` | `<>` |
| 3 | Мало місця на required диску призначення | блокує; `EstimatedRequirementNotMet` | `<>` |
| 4 | Вільне трохи нижче порогу, оцінка потреби мала (клас ~19.4 GB проти порогу 20 GB) | **блокує** (у 5.2.2 пропускало); `BelowFloorEstimateNotPeakSafe` | `<>` |
| 5 | Диск у `ExcludedDrives`, реально потрібний операції | блокує попри виключення; `ExclusionIgnoredForRequiredVolume` | `<>` |
| 6 | Maintenance: `ROOT_LIMS` як єдина write-required ціль | `RequirementGranularity=Unknown`; floor лише до цього тому, без глобального проходу по всіх Fixed-дисках | `<>` |

Сценарії 4 і 5 — це свідома зміна поведінки проти 5.2.2; без їх відтворення
тут вони відтворяться самі після розкатки на бойовому сервері.

### 4.1. Негативні перевірки (чого НЕ має статись)

| Перевірка | Факт |
|---|---|
| Заблокований прогін не залишає часткову generation і не псує попередню valid | `<>` |
| Заблокований прогін не рапортує успіх (код завершення не 0; алерт у ALERTS, не GENERAL) | `<>` |
| Maintenance більше не сканує всі Fixed-диски підряд (health-only sweep + одна write-required ціль) | `<>` |
| У журналі немає `Cannot bind argument to parameter 'Path'` / «Помилка запису у файл логу» | `<>` |

## 5. Передпольотна інвентаризація парку

Не частина acceptance кандидата, але обов'язкова до розкатки: обидві зміни
розділу 4 (сценарії 4 і 5) знімають обходи, якими могли користуватись
конфігурації на місцях.

| Сервер | `MinimumFreeSpaceGB` | Фактично вільно на required томі | `ExcludedDrives` | Дія до оновлення |
|---|---|---|---|---|
| `<>` | `<>` | `<>` | `<>` | `<підняти місце / знизити поріг / нічого>` |

## 6. Мінімальний протокол по серверу (`RELEASE_POLICY.md` §9.2)

Копія блоку на кожен тестовий сервер:

```text
Server:
OS:
PowerShell:
Previous version:
Tested version:      5.2.3-rc.3 (голова 92f2683)
Install/update result:
ValidateOnly result:
Dry-run result:
Archive result:
SFTP result:
SMB result:
Health result:
Maintenance result:
Restore test result:
DiskSpace scenarios:  1..6 —
Detected issues:
Decision:
```

## 7. CI / детерміновані перевірки

PR #141 (`hotfix/5.2.3` → `master`), голова `92f2683` — прогін
`actions/runs/34719455688`, усі перевірки зелені:

- `Parser / BOM / JSON` (у складі: release policy проти базової гілки
  `master`, master merge policy, інтегріті-маніфести, forbidden patterns,
  BOM, JSON);
- `PSScriptAnalyzer` — security (блокуючий) і решта правил;
- `BRAVO_SELF_TEST.ps1` — повний прогін;
- `BRAVO_DATA_RESTORE_MATRIX_TEST.ps1`;
- `Secret scanning (gitleaks)`, `GitGuardian Security Checks`.

Це перший незалежний прогін CI по лінії 5.2.3: `ci.yml` тригериться лише на
push у `master`/`developer` та на PR у них, а PR із цієї гілки досі не
відкривався — попередні «1533 PASS» були локальним прогоном автора.

Попередній прогін на `3fb1367` дав три червоні кроки з однієї причини:
промоційний bump змінив manifest-covered `VERSION.json`, не оновивши
`RUNTIME_MANIFEST.json`, і `BRAVO_RUNTIME_GUARD.ps1` заблокував запуск —
у matrix-тесті як реальний `BRAVO_ARCHIV.ps1` exit 33
(`RuntimeIntegrityViolation`), у self-test як єдиний `[FAIL]
RuntimeManifest/RepositoryManifestMatchesRuntime` при 1532 перевірках.
Гейт цілісності відпрацював штатно; дефекту в лінії 5.2.3 не виявлено.
Виправлено в `92f2683`.

## 8. Незакриті позиції на момент вердикту

- **Stamp провенансу не виконано.** `VERSION.json` голови несе
  `packageVersion 5.2.3` / `stable`, але `buildId`/`sourceCommit` ще
  вказують на коміт rc.3 (`a008f78`). Перед merge:
  `ci\Update-BRAVOVersionStamp.ps1 -Apply`, далі
  `ci\Update-BRAVORuntimeManifest.ps1 -Apply` окремим комітом, останнім.
- **A2-протокол (`RELEASE_CHECKLIST` §1.1) не застосовується:** він
  обов'язковий для релізів, що змінюють передачу пароля 7-Zip, кодування
  або сумісність архівів; 5.2.3 змінює лише політику вільного місця.
- `<інші знахідки прогону, що не блокують промоцію>`

## 9. Висновок

`<Заповнюється після завершення прогону. Формат: перелік закритих пунктів
§9.1, результат сценаріїв 1-6, наявність/відсутність блокуючих дефектів і
security-регресій, і рекомендація — metadata-only промоція stable 5.2.3 чи
новий кандидат rc.4.>`
