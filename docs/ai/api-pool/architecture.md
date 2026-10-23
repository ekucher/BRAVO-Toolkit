# Anthropic API Agent Pool v1: архітектура

Цей документ описує призначення, склад файлів, правила модулів і межі інтеграції Agent Pool v1 (офлайн-збірка). Джерелом істини для реалізованих частин є код у `Tools/ApiPool/`; для частин, що ще не потрапили до гілки, наведено проєктний опис із явною позначкою статусу.

## 1. Призначення і межі

Agent Pool — це інструментарій для агентів розробки (аналітичні та допоміжні ролі `api-*`), а не частина production-runtime BRAVO.

- Жоден кореневий `BRAVO_*.ps1` не завантажує `Tools/ApiPool` і не залежить від нього.
- Пул не виконує backup, restore, обслуговування, health-перевірки, роботу з планувальником чи службами.
- Вихід пулу є консультативним (`advisoryOnly`): він ніколи не підміняє обов'язковий gate політики агентів (див. розділ 8).
- Версія v1 є офлайн-збіркою: код, здатний працювати з мережею, не постачається (докладно в `security.md`).

## 2. Склад файлів

Розміщення: `Tools/ApiPool/`.

| Файл | Призначення | Статус у цій гілці |
|---|---|---|
| `modules/ApiPool.Core.psm1` | структуровані помилки, редагування секретів, конфігурація, файлові блокування, атомарний запис, guard шляхів, контекст | реалізовано |
| `modules/ApiPool.Credentials.psm1` | DPAPI-провайдер облікових даних, ротація | реалізовано |
| `modules/ApiPool.Pricing.psm1` | реєстр моделей, обчислення вартості | реалізовано |
| `modules/ApiPool.Budget.psm1` | журнал бюджету (ledger), резервування, аварійна зупинка, ремонт | реалізовано |
| `modules/ApiPool.Transport.psm1` | транспорт: лише скриптований fake; live-конструктор завжди відмовляє | реалізовано |
| `modules/ApiPool.Adapter.psm1` | адаптер Messages: allowlist запиту, повтори, слоти, rate limit | реалізовано |
| `modules/ApiPool.Agents.psm1` | ролі, обрамлення контексту, розбір HANDOFF | реалізовано |
| `modules/ApiPool.Jobs.psm1` | завдання, ідемпотентність, health, capabilities, `Invoke-ApiPoolOrchestrateJob` | реалізовано |
| `Invoke-ApiPool.ps1` | тонка CLI-точка входу (близько 190 рядків) | реалізовано |
| `config/apipool.defaults.json`, `config/models.json` | типові налаштування і ціни | реалізовано |
| `config/agents.json` | визначення ролей | реалізовано |
| `tests/Invoke-ApiPoolTests.ps1`, `tests/ApiPool.TestHarness.ps1`, `tests/suites/*.Tests.ps1`, `tests/helpers/*.ps1` | автономні офлайн-тести (усі набори, включно з `Agents`, `Jobs`, `Cli`, `Orchestrate`) | реалізовано |

Окремого `README.md` у `Tools/ApiPool` у цій гілці немає: документація зібрана в `docs/ai/api-pool/*`.

### 2.1. ЗАМОРОЖЕНИЙ набір файлів

Набір `.ps1` і `.psm1` файлів, що постачаються, заморожений: після першого релізу кожен такий файл є постійним. Додавати, перейменовувати чи видаляти їх можна лише за окремим погодженням.

Причина:

- реліз формується як `git archive` указаного ref;
- розгортання копіює файли без `/MIR`, тобто не видаляє на хості файли, яких уже немає в релізі;
- runtime guard трактує невідомий `.ps1`/`.psm1` як порушення цілісності.

Наслідок: перейменований або видалений файл, що постачався раніше, залишається на хості як невідомий скрипт, і оновлення ламається. Тому нова функціональність додається в наявні файли відповідного домену, а не в нові `.ps1`/`.psm1`. Документація (`.md`) і JSON-конфігурація цим правилом не обмежені, але їхні імена теж не слід змінювати без потреби.

## 3. Правила модулів

- Модулі ніколи не викликають `Import-Module` один для одного. Точка входу та тестовий runner імпортують їх у глобальну область у фіксованому порядку: `Core`, `Credentials`, `Pricing`, `Budget`, `Transport`, `Adapter`, `Agents`, `Jobs`.
- Напрямок залежностей без циклів: `Core` <- `Credentials`, `Pricing` <- `Budget` (Core, Pricing) <- `Transport` (Core, Credentials) <- `Adapter` <- `Agents` (Core) <- `Jobs` (Adapter, Agents, Budget).
- `Core` має закритий список експорту; він не повинен перетворюватися на загальний `Utils`.
- Усі шляхи, похідні від кореня стану (`budget\`, `budget\quarantine\`, `jobs\`, `slots\`, `ratelimit\`), будуються лише через `Resolve-ApiPoolStatePath` (`Core`): вона відхиляє `..`, кореневі й дисково-кваліфіковані відносні частини, вихід за корінь та будь-який наявний компонент шляху (включно з листом), що є reparse-point (`STATE_PATH_FORBIDDEN`). Перевірка виконується до будь-якого відкриття, створення чи запису.
- Маніфестів `.psd1` немає. У всіх модулях `Set-StrictMode -Version Latest`. Цільове середовище: Windows PowerShell 5.1.
- Кожна функція, що змінює стан, приймає явний `-StateRoot` або `-Context`. Модулі ніколи не вибирають типові шляхи: типовий корінь стану (`%LOCALAPPDATA%\BRAVO\ApiPool\state`) визначає лише точка входу.
- Помилки: `ErrorRecord` з `FullyQualifiedErrorId` вигляду `ApiPool.<CODE>` і повідомленням `[<CODE>] ...` (текст пропускається через редагування секретів). Код помилки читає `Get-ApiPoolErrorCode`. Таблицю кодів наведено в `troubleshooting.md`.
- Коди завершення точки входу: 0 успіх, 1 помилка (зокрема `health` із `UNHEALTHY` і `orchestrate` зі `status = failed`), 2 неправильне використання; `BRAVO.ExitCodes` не імпортується (пул не є частиною runtime BRAVO).

## 4. Блокування і конкурентність

Іменованих mutex/semaphore немає. Усі блокування є файловими: `FileStream` з `FileShare.None`, повтор до таймауту, ОС звільняє дескриптор при завершенні процесу.

| Блокування | Шлях |
|---|---|
| журнал бюджету | `<stateRoot>/budget/ledger.lock` |
| слоти конкурентності | `<stateRoot>/slots/slot-<n>.lock`, `n = 1..maxConcurrency` |
| rate limit (стан) | `<stateRoot>/ratelimit/<model>.json` |
| rate limit (замок) | `<stateRoot>/ratelimit/<model>.lock` (незалежний від журналу) |
| завдання | `<stateRoot>/jobs/<jobId>.lock` (маркер скасування: `<jobId>.cancel`) |

Другого планувальника немає: виклики синхронні, виконуються в процесі викликача. Фонових служб, Scheduled Task, `Start-Job`, runspace чи відокремлених `Start-Process` пул не створює.

## 5. Потік запиту (Adapter)

1. Перевірка allowlist запиту, моделі та `max_tokens` до будь-якого резервування (помилки програміста чи конфігурації кидаються).
2. Для кожної спроби: слот конкурентності, claim rate limit (очікування поза слотом), резервування бюджету, виклик транспорту.
3. Результат спроби: фіксація витрат (`COMMIT`), скасування резервування (`UNDO`, лише для зрозуміло незаряджених помилок) або `UNRECONCILED` (залишається в обліку).
4. Повтор за детермінованим backoff, перевірка маркера скасування перед спробою та під час очікування.

Бюджетні відмови (`BUDGET_*`, `LEDGER_*`) повертаються в результаті, а не кидаються. Докладно: `budget.md`.

## 6. Контракт apipool.orchestrate/1

`Invoke-ApiPoolOrchestrateJob` (у модулі `Jobs`; окремого модуля Orchestrate немає) повертає об'єкт:

| Поле | Значення |
|---|---|
| `schema` | `apipool.orchestrate/1` |
| `status` | `completed`, `fallback` або `failed` |
| `reasonCode` | код причини |
| `jobId` | ідентифікатор завдання |
| `handoff` | розібраний HANDOFF (дозволені поля, примусові значення) |
| `costMicroUsd` | вартість у micro-USD |
| `advisoryOnly` | завжди `true` |

`fallback` повертається, коли немає контексту або транспорту (`POOL_DISABLED`), коли бюджет зупинено (`BUDGET_STOPPED`), журнал пошкоджено чи не ініціалізовано (`LEDGER_CORRUPT`, `LEDGER_UNINITIALIZED`), а також коли завдання завершилося помилкою `BUDGET_EXHAUSTED_*`, `BUDGET_STOPPED` або `LEDGER_*`. Викликач у такому разі продовжує без пулу (наприклад, звичайним маршрутом ролей). Інші помилки дають `status = failed` із `reasonCode` (код помилки завдання, а за відсутності помилки `JOB_<СТАН>`, наприклад `JOB_CANCELLED`). У офлайн-збірці через CLI `orchestrate` повертає `fallback` з `reasonCode` `POOL_DISABLED` (код завершення 0); `status = failed` дає код завершення 1.

Завдання: `jobId = 'job-' + sha256(role + "\n" + key)[0..23]`; без ключа використовується GUID (дедуплікації немає). Формат ідентифікатора `^job-[0-9a-f]{24}$` перевіряється в кожній операції (`REQUEST_INVALID`), тому символи шляху в ньому неможливі. Той самий ключ і той самий хеш корисного навантаження повертають наявне завдання; інше навантаження дає `IDEMPOTENCY_CONFLICT`. Файл завдання має `schemaVersion = 1`; будь-яке інше значення (або не ціле число) дає `JOB_SCHEMA_UNSUPPORTED` без жодної зміни файлу, і `run`, `resume`, `cancel`, `status`, `result` відмовляють (не повторюється).

Стани: `queued` -> `running` -> `succeeded` | `failed` | `cancelled`, а також `interrupted`. Володар блокування завдання є власником стану `running`; якщо блокування вдається взяти, а стан `running`, завдання позначається `interrupted` і `run` повертає `JOB_INTERRUPTED`: продовжити можна лише явним `resume`. `cancel` для завдання в `queued` чи `interrupted` одразу ставить `cancelled`; для `running` створює маркер `<jobId>.cancel`, який бачить виконавець. Відновлення (`resume`) можливе лише з `interrupted` або `failed` (retryable), з `-Reason`, лічильником спроб (`maxAttempts = 3`) і межею `RESUME_LIMIT`; резервування завжди нове; термінальний стан (`succeeded`, `failed`, `cancelled`) не перезаписується (`JOB_TERMINAL`).

## 7. Агенти

Ролі: `api-scout`, `api-pr-analyst`, `api-issues-analyst`, `api-test-designer`, `api-doc-reviewer`, `api-architecture-advisory`. Визначення ролей (`config/agents.json`, `schemaVersion = 1`, інакше `CONFIG_INVALID`) перевіряються суворо: невідомі ключі та будь-які ключі `tools`/`tool_choice`/`mcp*` відхиляються. Агенти текстові, без інструментів. Вхідний контекст (brief до 8000 символів, дані до 200000) подається як обмежені недовірені дані, вихід очищується і розбирається до дозволених полів HANDOFF. Докладно: `security.md`.

## 8. Інтеграційний пакет .claude/* (ЗАБЛОКОВАНО)

Статус: окремий пакет, заблокований до рішення власника; у цю документацію й код пулу він не входить. Перелік очікуваних змін (окремий PR):

- розділ у `SKILL.md` про використання пулу;
- ролі `api-*` в `.claude/ai-routing.json` з `writes: none`;
- твердження в `BRAVO_AGENT_POLICY.md`: вихід пулу ніколи не задовольняє gate (незалежне рев'ю, codex-qa, codex-security, codex-architecture тощо);
- правило allow у налаштуваннях (settings) для запуску точки входу пулу;
- випадки в `Check-AgentPolicy` та `Test-AIRouting`;
- примітка в `CLAUDE.md`.

До злиття цього пакета пул не є частиною маршрутизації агентів.

## 9. Збережений стан

Типовий корінь стану: `%LOCALAPPDATA%\BRAVO\ApiPool\state` (визначає лише точка входу; guard шляхів див. у `security.md`).

| Шлях | Вміст |
|---|---|
| `budget/ledger.jsonl` | append-only журнал бюджету з хеш-ланцюгом |
| `budget/ledger.lock` | замок журналу |
| `budget/EMERGENCY_STOP` | маркер аварійної зупинки |
| `budget/quarantine/ledger-<stamp>.jsonl` | копія журналу перед ремонтом хвоста |
| `slots/slot-<n>.lock` | слоти конкурентності |
| `ratelimit/<model>.json`, `<model>.lock` | підказки throttling (не гроші) |
| `jobs/<jobId>.json` | документ завдання (стан, історія, результат; містить `brief` і `contextData` у відкритому вигляді, див. `security.md`) |
| `jobs/<jobId>.lock`, `jobs/<jobId>.cancel` | замок виконавця та маркер скасування |

Файл облікових даних живе поза коренем стану: `%LOCALAPPDATA%\BRAVO\ApiPool\anthropic-api-key.dpapi` (див. `installation.md`).
