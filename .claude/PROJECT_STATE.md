# BRAVO-Toolkit — поточний стан проекту

Останню перевірку виконано: 2026-10-01 (після merge train) (Git + GitHub REST API, лише читання).

Кожне змінне твердження нижче має дату й метод перевірки. Це знімок, а не
гарантія: **перечитати перед дією**. Порядок джерел істини — розділ
«Порядок джерел істини» в кінці файлу; цей файл не є авторизацією на
жодну Git/GitHub-мутацію.

## Канонічна гілка

`developer`

## State baseline SHA

`610e93f80a947d01c8c3e452694a02be0ca05b4a` — `developer`, Merge PR #315
(перевірено `GET /branches/developer`, 2026-10-01).

Попередній baseline — `4a54d34` (2026-09-30). Між ними merge train
2026-09-30/10-01 влив 13 PR (деталі нижче). Цей файл приходить окремим
PR #318 поверх `610e93f`; його merge-коміт не змінює runtime.

Це commit `developer`, відносно якого перевірено handoff; він не мусить
дорівнювати commit-у, що містить сам файл. Якщо `origin/developer` пішов
уперед — визначити доданий delta й перевірити лише зачеплені ним
припущення.

```text
git fetch origin --prune
git status --short
git branch --show-current
git rev-parse HEAD origin/developer origin/master
```

## Live-стан (перевірено 2026-10-01, перечитати перед дією)

| Об'єкт | Значення | Метод |
| --- | --- | --- |
| `origin/developer` | `610e93f` | `GET /branches/developer` |
| `origin/master` | `f8fa5aa` (stable `5.2.4`) | `GET /branches/master` |
| `developer` `VERSION.json` | `packageVersion` `5.3.0-dev.3`, `releaseChannel: development`, `sourceCommit` `d77f3b4` (416 комітів позаду `610e93f`) | файл у дереві |
| CI push-прогін `developer` `610e93f` | 5 перевірок ` (push)` + `Telegram CI summary` — усі success | `GET /commits/610e93f/check-runs` |
| Теги 5.3 | лише `v5.3.0-rc.1` | `git ls-remote --tags` |

## Branch protection — бажане проти перевіреного

Канон, бажана політика й процедура власника — `RELEASE_POLICY.md`
§13.3–§13.4. Payload-и для власника:
`/mnt/project-files/bravo-backlog/branch-protection-payloads/`
(`developer.json`, `master-add-config-parity.json`; поза репозиторієм).

Перевірений стан (GitHub REST API, 2026-10-01, перечитати перед дією):

* `master` — `protected: true`; required checks рівно шість:
  `Parser / BOM / JSON`, `PSScriptAnalyzer`, `BRAVO_SELF_TEST.ps1`,
  `Secret scanning (gitleaks)`, `GitGuardian Security Checks`,
  `BRAVO_DATA_RESTORE_MATRIX_TEST.ps1`. `strict`, `enforce_admins`, вимога
  PR, заборона force push/видалення — **не перевірювані з сесії**
  (`GET .../protection` → 403, потрібен `administration=read`).
* `developer` — **НЕ protected** (`protected: false`, `contexts: []`,
  `GET /rules/branches/developer` → `[]`). Ніщо технічно не блокує merge
  з червоним CI; merge train 2026-09-30/10-01 тримав гейт (8/8 exact-head
  перевірок, 0 відкритих тредів, зелений post-merge CI) процедурно.
* Теги — ruleset `protected-release-tags`: `active`, `refs/tags/v*`.
* `Config parity (BRAVO_CONFIG_LOADER)` — створюється на кожному
  `pull_request`, на push не створюється; **ще не required** ні на
  `master`, ні на `developer`.

**OWNER ACTION REQUIRED:** створити захист `developer` (6 канонічних +
`Config parity`, `strict: false`, `enforce_admins: true`, PR без
обов'язкових схвалень, без force push/видалення) — `RELEASE_POLICY.md`
§13.4. Додати `Config parity` на `master` — окреме необов'язкове рішення
власника, не застосовано. Записувати «застосовано» лише після
live-перевірки `GET /branches/{b}`.

## Злите з попереднього baseline (перевірено `GET /pulls/{n}`, 2026-10-01)

Merge train 2026-09-30/10-01 (звичайні merge-коміти, у такому порядку;
кожен — 8/8 exact-head перевірок, 0 відкритих тредів, зелений push-CI
на `developer` після merge):

| PR | Merge | Зміст |
| --- | --- | --- |
| #313 | `ec49423` | правило проти реальних ідентифікаторів у `.claude/CLAUDE.md` |
| #308 | `1e884f7` | #304: DataRestore відхиляє диск-/корінь-відносний `-TargetPath` |
| #309 | `79655b0` | #288: `time` у `Test-RangeIdUsage` під StrictMode |
| #310 | `be9abc7` | #295: `StartType` під StrictMode у Health |
| #317 | `347533a` | #154 B7: heartbeat не виконує підкладений `BRAVO.config`; гейт `CONFIG_LOADER_CALLER_COMPLETENESS`; матриця регресій 5.3-шляху |
| #259 | `75d41d2` | A5+A6: dataflow-guard `@(List[object])` під StrictMode |
| #261 | `8c81a54` | T026: формулювання ArchivePeakSafe і нульового джерела |
| #260 | `d1573c6` | T033: джерела конфігурації та секретів 5.3 |
| #263 | `4916dd5` | T027: шар розбору Markdown і перевірка посилань |
| #311 | `cd421e7` | #219 A: самодостатні вибіркові suite |
| #312 | `d17b062` | #219 B: секційна ізоляція фатальних винятків |
| #315 | `610e93f` | реальні назви установ, хостів і коди замінено вигаданими |

Codex перестав рев'юїти 2026-09-30 ~22:13 UTC (вичерпано ліміт). Після
цього незалежне рев'ю виконувалось окремими агентами.

## Відкриті PR (перевірено `GET /pulls?state=open`, 2026-10-01)

| PR | Стан | Зміст | Що потрібно |
| --- | --- | --- | --- |
| #318 | draft → цей файл | governance: бажана політика проти live-стану | merge останнім у train |
| #323 | draft, base `developer` | #322: пропущена нічна копія після старту сервера | поза merge train; review |

## Issue (перевірено `GET /issues/{n}`, 2026-10-01)

Закрито в merge train: **#304**, **#288**, **#295**, **#219** (обидві
частини злито; кожна вимога перевірена в коментарі закриття).

* **#216** (P0 cutover) — closed 2026-09-28. Runtime-cutover
  реалізовано; real-server acceptance **не виконувався**.
* **#154** (EPIC Config v2) — open. B0–B4, B6 виконано; **B7** — матрицю
  злито (#317), але parity ще не required check (немає захисту
  `developer`).
  * **B5** (міграція парку) — **не виконано**. Pilot 2026-09-29: 12/13
    критеріїв PASS, `Result: PILOT NOT ACCEPTED` лише через
    `SelfTestPass=false` (`Notifications/PublicIPLookupEnabledByDefault`).
    Решта парку не мігрована. **CI не може довести B5.**
* **#239** (8 відомих обмежень гейту `LEGACY_READER_ISOLATION`) — open,
  відкладено: лише окремий dataflow-дизайн. Відомий непрямий випадок —
  дочірній процес Configurator (#320).
* **#279**, **#280**, **#281** — open, чекають рішення власника (документацію
  #279/#280 виправлено в #261/#260, runtime-питання лишились).
* Нові з merge train: **#319** (пряме `StartType` поза Health), **#320**
  (Configurator виконує застарілий `BRAVO.config` у дочірньому процесі).
* Відкриті `bug`-issue без фіксу: #282–#287, #289–#294, #296–#303,
  #305–#307 (перевалідовано 2026-09-30 на `4a54d34`; runtime-зміни train
  їх не зачіпають), а також #319–#322.
* Дизайни, чекають рішення/реалізації: #314 (автовідновлення служб),
  #316 (закриття BIS перед реставрацією, після #314 хвилі 2).
* Acceptance-issue на реальних хостах: #152 (тег `v5.2.0-rc.2` досі
  відсутній), #155, #158 (чекліст виправлено 2026-10-01: baseline
  фіксується без `-ValidateOnly`) — open, не автономні.

## Пілотний сервер: невирішене після pilot (стан 2026-09-29; з цієї сесії не перевірялось)

* Виправити `PublicIPLookupEnabled` окремим кроком, повторити
  `-Validate`/`-Accept` до чистого `PILOT ACCEPTED`.
* Рішення власника: модель авторизації міграції решти парку
  (посерверна чи загальна).
* Прибрати слід: Scheduled Task `BRAVO-Agent-Runner` зі збереженим
  паролем `Admin`, `C:\Temp\BRAVO_UPDATE\`, встановлений Git for Windows.
* Крок 6 (фізичне видалення `BRAVO.config` на пілотному сервері) — не виконано,
  потребує окремої авторизації.

## Класифікація 5.3 (лише класифікація; без promote/tag/release)

Стан на `developer` `610e93f`, 2026-10-01. Рівні послідовні: ENGINEERING
READY → OPERATIONAL ACCEPTANCE (PENDING → ACCEPTED) → зняття RELEASE
BLOCKED.

| Рівень | Критерій | Вердикт зараз |
| --- | --- | --- |
| ENGINEERING READY | Runtime-cutover Config V2 (#216) у всіх production-entrypoint-ах | ТАК для прямих викликів (гейт `CONFIG_LOADER_CALLER_COMPLETENESS`, #317); непрямі виклики — #239, Configurator — #320 |
| ENGINEERING READY | B7: матриця регресій 5.3-шляху в required-наборі | ЧАСТКОВО — матриця в `BRAVO_SELF_TEST.ps1` (required на `master`), але `developer` без захисту |
| ENGINEERING READY | CI зелений на HEAD `developer` | ТАК (push-прогін `610e93f`) |
| ENGINEERING READY | Немає відкритих bug-issue щодо коректності runtime без рішення | НІ — 23 `bug`-issue у #282–#307 і ще #319–#322 |
| OPERATIONAL ACCEPTANCE | B5: pilot `PILOT ACCEPTED` + мігровані хости парку з доказами | НІ — `PILOT NOT ACCEPTED`, парк не мігровано |
| OPERATIONAL ACCEPTANCE | Acceptance-issue на реальних хостах (#152/#155/#158) | НІ — open |
| RELEASE | `VERSION.json` provenance відповідає HEAD | НІ — `sourceCommit` `d77f3b4` ≠ `610e93f` → `PROVENANCE_STALE` |
| RELEASE | Прийнятий RC | НІ — `v5.3.0-rc.1` immutable, приймання не проходив; `rc.2` не створено |
| RELEASE | Захист `developer` застосовано й перевірено live | НІ — OWNER ACTION REQUIRED (§13.4) |
| RELEASE | Питання #281 вирішено | НІ — open |

**Підсумок:** ENGINEERING READY — не досягнуто (відкриті runtime-баги);
OPERATIONAL ACCEPTANCE — PENDING; **RELEASE BLOCKED**.

## Жорсткі зупинки (hard stops)

* **Не розгортати поточний `developer` (5.3) на немігровані хости епохи
  5.2** і не рекомендувати таке розгортання, доки немає доказів B5:
  безумовний `-DisallowLegacyPrimaryAutoDetect` змусить runtime
  ігнорувати legacy `BRAVO.config` → тиха втрата site-перевизначень
  (наприклад, нестандартного `BackupRoot`).
* Жодних promote, tag, release, GitHub Release для 5.3.
* Без явної авторизації користувача в поточному завданні: жодних
  commit, push, force-push, amend, reset, rebase, merge, змін branch
  protection, tag, release, видалення гілок.
* Merge з автоматичної сесії — лише за явною авторизацією власника на
  конкретний перелік PR (як merge train 2026-09-30/10-01); без неї
  довести PR до green/mergeable і передати merge власнику.

## NEXT ACTION

```text
1. Власник застосовує захист developer за RELEASE_POLICY.md §13.4;
   сесія після цього перечитує GET /branches/developer і лише тоді
   оновлює §13.3 та цей файл.
2. Власник вирішує щодо #279/#280/#281 і пріоритету runtime-багів
   #282–#307, #319–#322; фікси — окремими PR у developer.
3. B5: довести pilot до PILOT ACCEPTED (PublicIPLookupEnabled),
   рішення про модель міграції парку. До доказів B5 — hard stop нижче.
4. #314 хвиля 1 (після «починай» власника), потім #316.
Перед кроком 1 перечитати: git rev-parse origin/developer, GET /pulls?state=open.
```

Merge `developer` → `master`, теги, RC/stable release, GitHub Release і
розгортання — лише за окремим рішенням власника.

## Корисні технічні нотатки

* `deploy/New-BRAVOConfigV2PilotArtifact.ps1` і
  `New-BRAVOPilotSyntheticInstallRoot` у self-test беруть вміст через
  `git show`/`git archive` від ref (типово `HEAD`), тож незакомічена
  правка їм невидима. Незакомічений фікс валідують копією self-test у
  scratch-каталозі з `Copy-Item`-накладанням робочого файлу після кроку
  `git archive` — без stash і без commit.
* `BRAVO_SELF_TEST.ps1` з `-NonInteractive` без `-NoPause` зависає на
  «press any key» після завершення — передавати `-NoPause`.
* Заборона підписів про AI-авторство, виміри боргу й інжектований
  інтеграцією рядок у тілах PR/issue — канонічно в `.claude/CLAUDE.md`;
  не перередаговувати ці тіла повторно.

## Порядок джерел істини

```text
Git/GitHub factual state
    >
current repository code/tests/configuration
    >
PROJECT_STATE.md
    >
current plans/roadmaps
    >
historical PR descriptions / old session context
```

Документація (`RELEASE_POLICY.md`, `SECURITY.md`, `ROADMAP.md`, цей
файл) ніколи не переважає live-налаштувань GitHub.

## Підтримка handoff

Після кожної завершеної суттєвої хвилі:

1. Перевірити `origin/developer`.
2. Оновити State baseline SHA до commit-у `developer`, відносно якого
   фактично перевірено стан.
3. Тримати завершене стисло; фіксувати фактичну валідацію.
4. Прибрати застарілі блокери; оновити активні issue/PR.
5. Замінити `NEXT ACTION` конкретною виконуваною дією.

Не перетворювати файл на журнал сесій.
