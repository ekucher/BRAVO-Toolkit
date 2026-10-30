# SELF_TEST: результати оптимізації (OPT-12)

Дата виміру: 2026-10-29/30. Гілка: `perf/selftest-optimization`, база `1c45476c`.
Машина: той самий VM, що й у [baseline](baseline.md) (16 vCPU, 32 GB, Windows PowerShell 5.1).
Метод: 3 пари повних прогонів `.\BRAVO_SELF_TEST.ps1 -NoPause`, чергування baseline (B) і оптимізованої гілки (N).
Під час пар 2–3 інших навантажень на VM не було. Під час N1 приблизно хвилину паралельно працював read-only рев'юер.

## Повний прогін

| Прогін | Total wall-clock | Перевірок | FAIL | Вердикт |
|---|---:|---:|---:|---|
| B1 | 17:25.5 | 3941 | 0 | SELF-TEST PASSED |
| N1 | 17:05.9 | 3946 | 0 | SELF-TEST PASSED |
| B2 | 16:36.7 | 3941 | 0 | SELF-TEST PASSED |
| N2 | 16:03.7 | 3946 | 0 | SELF-TEST PASSED |
| B3 | 17:34.2 | 3941 | 0 | SELF-TEST PASSED |
| N3 | 15:46.1 | 3946 | 0 | SELF-TEST PASSED |

- Медіана B: 17:25.5 (діапазон 16:36.7–17:34.2).
- Медіана N: 16:03.7 (діапазон 15:46.1–17:05.9).
- Різниця медіан: −81.8 с (−7.8%). За парами: −19.6 с, −33.0 с, −108.1 с.
- +5 перевірок — нові `Framework/TimingSummaryProfile*` (OPT-02). Жоден наявний тестовий ID не видалено.

Три пари — мала вибірка; власний шум baseline між прогонами ≈ 58 с. P95 не оцінювався.

## Змінені області (медіана з трьох)

| Suite | B | N | Різниця |
|---|---:|---:|---:|
| Root (inline) | 297.7 с (282.1–304.9) | 248.5 с (234.9–251.1) | −49.2 с (−16.5%) |
| Governance | 106.8 с (105.3–107.2) | 85.8 с (80.7–87.3) | −21.0 с (−19.7%) |

Діапазони B і N для цих suite не перетинаються. Решта suite не змінювалась і коливається в межах шуму:
наприклад, Configurator 253.4–258.9 с (B) проти 234.8–298.5 с (N).

## Що дало ефект

| Зміна | OPT | Інтервал до → після (прогін B1/N1) |
|---|---|---|
| Структурні AST-перевірки без scriptblock на кожен вузол | OPT-03/07 | SelectiveSuitesHaveNoCrossSuiteDependency 26.8 → 9.9 с; SectionBoundariesAreWellFormed 16.7 с → поза top-20; Json/NoCollapsedArrayFromPipeline 10.9 с → поза top-20 |
| Closure-проба: генероване присвоєння замість `Set-Variable` у циклі | OPT-07 | SelfTestClosureNarrowScopeSurvivesLargeCreatorScope 17.3 с → поза top-20 |
| Health-проба: 13 child-процесів → 1 з канарками | OPT-08 | Health/OrchestrationRunsChecksInContractOrder 17.0 → 7.8 с |
| Maintenance-проба: похідні рядки раз на child | OPT-08 | Maintenance/OrchestrationScenariosShareOneChildProcess 62.1 → 51.2 с (у межах шуму) |
| Parse-memo в одному виклику CutoverGates | OPT-03 | AutoExecGuardHoldsForEveryRepositoryTarget 19.8 → 18.1 с (у межах шуму) |
| Розбір Markdown для посилань | OPT-06 | RelativeLinksResolve 25.1 → 22.7 с (у межах шуму) |

## Межі доказу й відкладене

- Ціль плану (−20–30% Full) не досягнута: −7.8% за медіаною.
- Найдорожчі незмінені області — Configurator, BackupDestinations, ConfigLoader (≈ 470 с разом). Їхній час — реальні child-процеси production-коду або installer-а, тобто предмет перевірки. Подальше скорочення можливе лише окремим рішенням щодо production або через паралельні процеси ([parallelism-inventory.md](parallelism-inventory.md), OPT-11).
- Health-проба в одному child: ізоляція спирається на канарки й очищення global-змінних; вони не доводять повної ізоляції процесного стану, але конкретного забруднення не знайдено, а mutation probe дає 9 FAIL.
- Не виконано: Full із release-like розпакованого ZIP, required CI, PSScriptAnalyzer для змінених файлів.
