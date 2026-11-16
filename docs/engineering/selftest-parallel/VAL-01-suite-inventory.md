# VAL-01: інвентар suite і check-universe Full Self-Test

Статус: характеризація (лише документація, без змін коду). Закриває VAL-01 з
`docs/design/BRAVO_VALIDATION_ARCHITECTURE.md` у частині інвентаря suite і
множини ID перевірок. Правила ідентичності й модель еквівалентності:
[VAL-02](VAL-02-check-identity.md).

Контекст: workstream CI-SELFTEST-PARALLELIZATION (аудит PAR-CI-00). Рішення
власника OD-32: «c, поетапно»: спершу (a) швидкий non-required сигнал на
`developer`, потім (b) заміна required check лише за умов. Цей документ ніщо не
змінює в CI, `BRAVO_SELF_TEST.ps1` або branch protection і не дублює
`ROADMAP.md`.

## Застереження про актуальність

Усі числа нижче виміряні для об'єкта `origin/developer` `3d441d4e`
(`3d441d4eaeba5640c2da0250e4ac7e0dbc569ead`). Після будь-якого коміту, що
змінює `BRAVO_SELF_TEST.ps1`, `selftest/*.ps1` або склад дерева, вони
застарівають і потребують перевимірювання. Тести в межах аудиту не запускалися;
runtime-база це один Full у CI (job `124152374732`, push у `developer`,
windows-2025, Windows PowerShell 5.1). Відтворюваність між прогонами на цьому
SHA не перевірена (на ньому лише один Full).

## Джерела й хеші

Машинні артефакти аудиту PAR-CI-00 лежать поза репозиторієм у каталозі
`data` запуску `run-20261031-010026-8c1787b5` (сховище evidence оркестратора
`parallel-selftest-readiness-20261031`). У репозиторій вони не копіюються.
SHA-256 нижче збігаються з `data/README.md` запуску (перераховано
`Get-FileHash` при підготовці цього документа: 35 з 35 файлів збігаються, 0
розбіжностей).

| Файл | Що містить | SHA-256 |
|---|---|---|
| `check-id-universe-3d441d4e.json` | статичний universe ID за suite (AST) і лічильники | `87d5602fae39872c5d636c87e1a49edd3964cb6434f9f63f21c29ef9f3be001d` |
| `coverage-inventory.csv` | інвентар check-сайтів, 3 755 рядків | `681ec3da422bb70a38f21f53c9fbd0dc83a4b943b2f9d4330776d8a720cf8f98` |
| `runtime-check-ids-3d441d4e-job124152374732.txt` | ID з `[PASS]` еталонного Full, 4 172 рядки | `97c7d74ca303b8a4fa120462acd7fcf184c457a0a343a1787438b63486b821c3` |
| `runtime-only-ids-3d441d4e.csv` | ID, що існують лише в runtime, 607 рядків | `5fbb8407a41d1da2daa2e77249df9d2ac16ec7e44c40b5587afae13ff4f65eb9` |
| `static-only-ids-3d441d4e.csv` | ID, що є лише в статичному аналізі, 24 рядки | `8e36ba1f5182cc69d8b136e3111bba2eef83ad1652df0fc3bb898086b6d885ad` |
| `suite-module-matrix.csv` | матриця suite × модулі/скрипти | `f9b1749b974669813c3b116638cecc45abf4c31f8460bdbe8ba88cf4508a5501` |
| `root-inline-classification.csv` | класифікація root-inline секцій | `c653609f086a95b3fb169f1483c5017ca8c7bdfbbc3014c9b303b98f35271c99` |

Аналітичні звіти того самого запуску (текстові, не машинні дані):
`02-COVERAGE-AUDIT.md` (SHA-256
`1ae9bd5744a7cb0c03c5953a694d03a201cb1892d82179f231d9a575dc894ee9`) і
`03-DEPENDENCIES.md` (SHA-256
`2b8233fa7d0e10ce75dc4ea267eda435b8b5e907a50d0b08a616f32b9d7aca21`).

## Виміряні числа

| Величина | Значення | Джерело |
|---|---:|---|
| Runtime check ID еталонного Full (`[PASS]`, 0 FAIL, 0 `[НЕДОСТУПНО]`, 0 дублікатів) | 4 172 | `runtime-check-ids-…txt`: 4 172 рядки; `check-id-universe-…json`: поле `runtime_total_checks_run_41081744186` = 4 172 |
| Статичні виклики перевірок | 3 664 | `check-id-universe-…json`, `counts.static_calls_total` |
| Унікальні статичні ID | 3 589 | там само, `counts.unique_static_ids` |
| Параметризовані шаблони (expandable) | 48 | там само, `counts.expandable_calls` |
| Динамічні сайти | 27 | там само, `counts.dynamic_sites` |
| Групи дублікатів ID | 0 | там само, `counts.duplicate_id_groups` |
| Runtime-only ID (є в Full, немає як статичний літерал) | 607 | `runtime-only-ids-…csv`: 607 рядків даних |
| з них env-залежні | 22 | там само, колонка `determinism` = `env-dependent` |
| Static-only ID (є в коді, немає в чистому Full) | 24 | `static-only-ids-…csv`: 24 рядки даних |
| з них env-залежні (`env-dependent` та `env-dependent (only on probe failure)`) | 3 | там само, колонка `determinism` (1 + 2) |
| Рядки `coverage-inventory.csv` | 3 755 | файл; `in_canonical_full` = yes у 3 667, no у 88 (усі 88 належать `ConfigV2PilotArtifact`) |

Число «52 env-залежних ID» (і «45 EnvironmentLimitation-сайтів») наведене лише
в `02-COVERAGE-AUDIT.md` (розділ про детермінізм і таблиця ризиків) як
результат статичного аналізу PAR-A09. З файлів `data/` воно не перераховане:
`runtime-only` і `static-only` разом дають лише 22 + 3 env-залежні рядки, а
окремого файлу зі списком усіх 52 ID у `data/` немає. Тому 52 і 45 тут
цитуються зі звіту, не як перевірені за `data/`; перерахунок залишається
відкритим питанням.

## 30 suite і root-порядок

Джерело переліку: каталог `$script:BRAVOSelfTestSuiteCatalog` у
`selftest/BRAVOSelfTestSuiteMap.ps1` (на HEAD = `3d441d4e`), 30 імен, **в
алфавітному порядку**. Каталог не є порядком виконання.

Джерело root-порядку: порядок рядків dot-source `selftest\BRAVO_SELF_TEST.<Ім'я>.ps1`
у `BRAVO_SELF_TEST.ps1` на `3d441d4e`. Full завжди виконує suite у цьому порядку
незалежно від порядку `-Suite`; порядок каталогу і root-порядок розходяться
(у `03-DEPENDENCIES.md`: інверсія в 234 з 435 пар). Маркер PARTIAL, навпаки,
перелічує suite у порядку запиту.

| # | Suite | Рядок dot-source у `BRAVO_SELF_TEST.ps1` |
|---:|---|---:|
| 1 | Governance | 16407 |
| 2 | DataRestore | 26201 |
| 3 | ServiceQuiescence | 26209 |
| 4 | ServiceRecovery | 26217 |
| 5 | ManifestStorage | 26358 |
| 6 | Paths | 31327 |
| 7 | LogRotation | 33712 |
| 8 | ConsoleUX | 33719 |
| 9 | Archive | 35620 |
| 10 | BackupScope | 35628 |
| 11 | BackupDestinations | 35637 |
| 12 | SftpCredentialsRequired | 35644 |
| 13 | LogSync | 35651 |
| 14 | MaintenanceOwnLog | 35658 |
| 15 | BazaSync | 35665 |
| 16 | ClientGate | 35671 |
| 17 | Operations | 35678 |
| 18 | TraceArchive | 35688 |
| 19 | MaintenanceRepair | 35697 |
| 20 | RestoreSynthetic | 35708 |
| 21 | RestoreVerify | 35718 |
| 22 | Status | 35728 |
| 23 | ConfigLoader | 35738 |
| 24 | Configuration | 35750 |
| 25 | ConfigIntent | 35760 |
| 26 | Configurator | 35769 |
| 27 | ConfiguratorUI | 35780 |
| 28 | DiskSpace | 35789 |
| 29 | ArchiveDiskSpace | 35798 |
| 30 | MaintenanceDiskSpace | 35806 |

Примітки до таблиці (за `check-id-universe-…json` і `coverage-inventory.csv`):

- Номери рядків дійсні лише для `3d441d4e`.
- Окрім 30 suite, інвентар містить `ConfigV2PilotArtifact` (88 сайтів, не
  входить до canonical Full), `ManualLaunchers` (30 сайтів, вбудований у
  `LogRotation`), `Phase0` (4 сайти в інвентарі) і root-inline секції
  (`Root (inline)`, 1 381 сайт). Ці групи не є suite з `-Suite`.
- Root-inline перевірки виконуються поза suite-файлами. Еталон: Root 1 632 + Phase0
  9 = 1 641 runtime-інстанс (`02-COVERAGE-AUDIT.md`); це число звіту, а не
  перерахунок з `data/` (інвентар рахує сайти, не runtime-інстанси).

## Full-only ID (X_full)

Рівно 2 ID існують лише в повному прогоні й не виконуються в жодному
`-Suite` worker-і (за `02-COVERAGE-AUDIT.md`, перевірено на `3d441d4e`; gate
`$suiteRequested`, `BRAVO_SELF_TEST.ps1` рядки 38155-38171):

1. `Framework/FullCanonicalRunIsDefault`
2. `Framework/FullRunEnablesEverySuite`

`X_sel` (ID, що з'являються лише в `-Suite`) = порожня множина. Наслідок:
об'єднання вибіркових прогонів за побудовою не дорівнює Full; носій X_full
потрібен окремо (OD-03). Це рішення власника, а не частина цього документа.

## Що цей документ не робить

- Не проектує розбиття на shard-и, агрегатор чи workflow (це PAR-3…PAR-6,
  `ROADMAP.md` і звіти аудиту).
- Не фіксує продуктивність (таймінги окремо:
  [selftest-performance](../selftest-performance/baseline.md)).
- Не змінює рішення OD-01…OD-36; посилається лише на OD-32 (мета) і OD-03 (X_full).
