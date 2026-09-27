# Issue #216 — фінальний синтезований Lead-звіт (2026-09-26)

Крос-рев'ю всіх попередніх звітів (Agent A/B/D/E/F/G/H/I, R1, R2, Standards/Spec
code-review, попередній Lead-звіт) проти фактичного коду репозиторію та проти
git-історії. Це звіт read-only агента: жодних commit/push/merge не виконано.

## 1. Підтверджені факти (перевірено напряму в коді)

- **Parent-сесія фактично виконала задекларовані tasks #1-6** у worktree
  `E:\GitHub\BRAVO-Toolkit-216-b-inventory` (HEAD `7433d42`, некомічені зміни):
  `git status --short` показує рівно ті 9 файлів (7 модифікованих + 2 нових),
  які tasks #1/#2/#3/#4/#5/#6 мали торкнутись — жодного зайвого файлу, жодного
  пропущеного. `git diff --stat HEAD` дає розміри правок, узгоджені з описом
  кожної задачі (Discovery.psm1 +81/-… для 5 нових existence-check-гілок,
  Governance.ps1 +120 для нового H-1-тестового блоку, і т.д.).
- **PR #224 (`fix/config-v2-local-override-authorization`, tip `8113a19`) РЕАЛЬНО
  містить `Test-BRAVOConfigurationOverrideAuthorization` та класифікаційну
  таблицю з класами `ALLOW_SITE` / `ALLOW_WITH_VALIDATOR` / `DENY_DERIVED` /
  `DENY_CREDENTIAL_BACKED` / `DENY_SECURITY_CONTROL` / `DENY_EXECUTION_CONTROL` /
  `DENY_INTERNAL_METADATA`** — у `modules/BRAVO.Configuration/BRAVO.Configuration.Schema.psm1`.
  Це **суперечить** твердженню Agent F / Standards-review ("ALLOW_SITE/DENY_*
  не існують буквально в коді") — те твердження було правильним ЛИШЕ для бази
  `588b866` (Wave B до PR #224), не для PR #224 самого. Обидва звіти технічно
  точні для свого observed-scope, але це важливий нюанс, який попередній
  Lead-звіт не виокремив явно.
- **Усі 9 листів `discoverySettings.*` на PR #224 класифіковані `ALLOW_SITE`**
  (рядки 701-709 схеми), НЕ `ALLOW_WITH_VALIDATOR`. Це підтверджує
  докс-агента (`agent/config-docs-i`) непевну нотатку ("discoverySettings
  ймовірно ALLOW_SITE, потребує підтвердження") — тепер підтверджено як факт.
- **Диспетчер валідаторів PR #224** (`Test-BRAVOConfigurationAuthorizationValidatorValue`)
  підтримує рівно 8 видів: `Enum`, `EnumTrimmed`, `IntegerRange`, `NonEmptyString`,
  `TaskSchedulerPath`, `UrlArray`, `WindowsCodePage`, `DotNetEncodingName`. **Немає
  жодного виду "шлях має існувати на диску"**. Це означає: якби Q7 (грилінг-раунд
  4) обрав "generic schema-level validator hook" замість "мінімальна
  точкова перевірка", довелось би спершу винаходити НОВИЙ вид валідатора в
  канонічній схемі PR #224 — істотно більший обсяг роботи, ніж передбачалося
  на момент рішення. **Висновок: рішення користувача (точкова перевірка в
  `BRAVO.Discovery.psm1`, а не схема-рівень) залишається правильним і після
  цього нового факту** — не потребує перегляду.
- **Ці два шари не конфліктують і не дублюються**: класифікація PR #224
  (`ALLOW_SITE` для discoverySettings.*) відповідає на питання "чи дозволено
  сайту перевизначити цей лист взагалі" (авторизаційний шар); точкова
  Wave-B-перевірка в `BRAVO.Discovery.psm1` (task #3) відповідає на інше
  питання — "чи семантично коректне (існуюче) значення переданого override"
  (консьюмер-шар). Обидва потрібні одночасно; інтеграція гілок не вимагає
  вибору між ними.
- **Agent D's characterization test `Delta/SecurityWeakeningOverrideSurfacedNotSuppressed`**
  (на гілці `agent/config-migration-d`) і parent's новий
  `Delta/SecurityInvariantValuesAreVisiblyMarked` (некомічений, у
  `216-b-inventory`) **вирішують той самий DENY-UX-гап** через різні назви й,
  ймовірно, різну механіку маркування. Потребують явного порівняння коду
  (не лише назв) в момент інтеграції гілок (task #10) — ризик дублювання
  тестового покриття або, гірше, двох різних непослідовних реалізацій
  маркування в тому самому `Get-BRAVOConfigSiteDelta.ps1`. **Це відкрите
  питання для інтеграції, не для поточної фази.**
- **R2's dead-code-sink знахідка (task #1) і Agent F's regex-flaw знахідка
  (tasks #2/#6) підтверджено — це справді той самий root cause, вже закритий
  parent-сесією.** Жодних розбіжностей.
- **Agent F's "нуль regression-покриття для `-DisallowLegacyPrimaryAutoDetect`"
  знахідка підтверджено закритою**: Proof B (коміт `7433d42`) саме цю поведінку
  й доводить (CLEAN vs POISONED `BRAVO.config`, обидва прогони з
  `-DisallowLegacyPrimaryAutoDetect`, нуль ефекту крім 3 provenance-полів).
- **PROJECT_STATE.md-історія по гілці `chore/issue-216-lead-handoff-20260926`
  має 8 записів, а `--all` дає 10** (`9e49a56` та `f94605f` існують лише в
  ширшому графі, не на цій конкретній гілці) — це не аномалія: ці 2 коміти є
  предками поточної гілки (звичайна лінійна історія), просто `git log <branch> --
  <path>` і `git log --all -- <path>` дають різні, але не суперечливі,
  підмножини при однаковому дереві. Не є розбіжністю звітів.

## 2. Нові знахідки цього крос-рев'ю (не в жодному попередньому звіті)

1. **[ІНФОРМАЦІЙНЕ] Agent B's лічильник "18 листів discoverySettings"
   не збігається з фактичною кількістю (9)** у поточній схемі PR #224.
   Ймовірно, Agent B рахував щось інше (напр. усі pathSettings-related листи
   разом) або схема на момент його аналізу мала інший склад. Не блокуюче —
   фактична кількість (9) підтверджена напряму зараз.
2. **[ДЛЯ ІНТЕГРАЦІЇ, НЕ ТЕРМІНОВЕ] Дублювання DENY-UX-покриття** між Agent D's
   `Delta/SecurityWeakeningOverrideSurfacedNotSuppressed` і parent's
   `Delta/SecurityInvariantValuesAreVisiblyMarked` — потребує явного порівняння
   коду в момент rebase Wave B на PR #224 + cherry-pick з `agent/config-migration-d`.
3. **[АРХІТЕКТУРНА МОЖЛИВІСТЬ, НЕ ЗАДАЧА]** Після merge PR #224, довгостроково
   можна б перекласифікувати `discoverySettings.*` з `ALLOW_SITE` на
   `ALLOW_WITH_VALIDATOR` із новим видом валідатора ("шлях існує"), щоб
   авторизаційна схема сама відображала інваріант, який зараз забезпечує лише
   консьюмер (`BRAVO.Discovery.psm1`). Це НЕ виправляє жодного дефекту (задача
   #3 вже fail-closed на рівні консьюмера) — це питання архітектурної
   прозорості для майбутнього циклу розробки, не для Issue #216.

## 3. Точний перелік §9-пунктів: статус

| # | Пункт | Статус |
|---|---|---|
| 1 | R2 dead-code sink (D3 unknown-leaf) | ЗАКРИТО, некомічено (`BRAVO_CONFIG_LOADER.ps1`) |
| 2 | H-1 gate (release-only → PR-рівень) | ЗАКРИТО, некомічено (`ci/BRAVOConfigV2CutoverGates.ps1` + workflow) |
| 3 | discoverySettings ALLOW_WITH_VALIDATOR (точкова) | ЗАКРИТО, некомічено (5 нових existence-check у `BRAVO.Discovery.psm1`) |
| 4 | DENY-UX marking у site-delta | ЗАКРИТО, некомічено — **потребує звірки з Agent D's тестом при інтеграції** |
| 5 | Централізація 14-entrypoint list | ЗАКРИТО, некомічено (`ci/BRAVOConfigV2CutoverGates.ps1`) |
| 6 | Governance self-test для H-1 | ЗАКРИТО, некомічено (`BRAVO_SELF_TEST.Governance.ps1`) |
| 7 | Точкові тестові гепи (toolIntegritySettings.Mode DENY, credential-runtime, migration e2e) | ЗАКРИТО за даними живого task-трекера parent-сесії (виконувалось паралельно з цим крос-рев'ю; код цього пункту НЕ перевірено цим Lead-звітом напряму — рекомендується окрема швидка звірка перед task #9) |
| 8 | Мінімальний Health selftest (Config V2 scope) | IN PROGRESS за даними живого task-трекера parent-сесії на момент запису цього звіту |
| 9 | Фінальна регенерація RUNTIME_MANIFEST + широка валідація | НЕ ПОЧАТО (залежить від #7/#8) |
| 10 | Інтеграція гілок у один PR проти `developer` | БЛОКОВАНО — потребує явної git-авторизації користувача в момент дії |

## 4. Що НЕ виконано і чому (прозоро)

- **Real-server acceptance (Task Scheduler, Windows-сервіси, WinSCP/SFTP,
  Credential Manager)**: НЕ ВИКОНАНО (немає доступу до реального хоста в цьому
  sandbox). Усі висновки цього звіту — статичний аналіз коду й ізольовані
  PowerShell-харнеси, не production-акцептанс.
- Повний `BRAVO_SELF_TEST.ps1` для некомічених tasks #1-6 (парент вже
  задокументував це обмеження: ACL-проб-тест не проходить у неелевованому
  середовищі й блокує домен ConfigLoader) — верифікація виконана ізольованими
  харнесами per-task, не повним прогоном.
- Порівняння Agent D's і parent's DENY-UX тестів код-в-код (лише назви й
  контекст порівняно, не повний diff двох реалізацій) — залишено як явний
  пункт для моменту інтеграції (розділ 2, пункт 2).

## 5. Рекомендований NEXT ACTION

Продовжити tasks #7 → #8 → #9 у поточному worktree (без git-мутацій), потім
запитати в користувача явну авторизацію на task #10 (інтеграція гілок), у
межах якої першим кроком звірити код Agent D's і parent's DENY-UX тестів
(розділ 2, пункт 2) перед тим, як вирішувати, яку версію(-ї) залишити.
