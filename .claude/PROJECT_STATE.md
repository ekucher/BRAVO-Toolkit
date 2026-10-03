# BRAVO-Toolkit — поточний стан проекту

Останню перевірку виконано: 2026-10-02 (після Stabilization Wave 2 merge train) (Git + GitHub REST API, лише читання).

Кожне змінне твердження нижче має дату й метод перевірки. Це знімок, а не
гарантія: **перечитати перед дією**. Порядок джерел істини — розділ
«Порядок джерел істини» в кінці файлу; цей файл не є авторизацією на
жодну Git/GitHub-мутацію.

## Канонічна гілка

`developer`

## State baseline SHA

`5d00e207cd10ec1978cd5aebf2e3127f0e1b53e2` — `developer`, Merge PR #334
(перевірено `GET /branches/developer`, 2026-10-02).

Це останній runtime-merge Stabilization Wave 2 merge train 2026-10-02;
PR із цим файлом змінює лише документацію й зливається після нього.
Попередній baseline — `b0f3b2e` (Merge PR #323). Між ними train влив сім
runtime-PR (деталі нижче).

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

## Live-стан (перевірено 2026-10-02, перечитати перед дією)

| Об'єкт | Значення | Метод |
| --- | --- | --- |
| `origin/developer` | `5d00e20` | `GET /branches/developer` |
| `origin/master` | `f8fa5aa` (stable `5.2.4`), не змінювався | `GET /branches/master` |
| `developer` `VERSION.json` | `packageVersion` `5.3.0-dev.3`, `releaseChannel: development`, `sourceCommit` `d77f3b4` (далеко позаду `5d00e20`) | файл у дереві |
| CI push-прогін `developer` `5d00e20` | 5 перевірок ` (push)` + `Telegram CI summary` — усі success; `BRAVO_SELF_TEST` 3000 перевірок, 0 помилок | `GET /commits/5d00e20/check-runs`, журнал job |
| Теги 5.3 | лише `v5.3.0-rc.1` | `git ls-remote --tags` |
| Відкриті PR | 8, усі draft: #332, #339, #342, #346, #348, #351, #352, #353 | `GET /pulls?state=open` |
| Відкриті issue | 33 (без PR) | `GET /issues?state=open` |

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
* `developer` — **НЕ protected** (`protected: false`, перевірено
  2026-10-02). Ніщо технічно не блокує merge з червоним CI; merge train-и
  2026-10-01 і 2026-10-02 тримали гейт (8/8 exact-head перевірок,
  0 відкритих тредів, зелений post-merge CI) процедурно.
* Теги — ruleset `protected-release-tags`: `active`, `refs/tags/v*`.
* `Config parity (BRAVO_CONFIG_LOADER)` — створюється на кожному
  `pull_request`, на push не створюється; **не required** ні на
  `master`, ні на `developer`.

**OWNER ACTION REQUIRED:** створити захист `developer` (6 канонічних +
`Config parity`, `strict: false`, `enforce_admins: true`, PR без
обов'язкових схвалень, без force push/видалення) — `RELEASE_POLICY.md`
§13.4. Додати `Config parity` на `master` — окреме необов'язкове рішення
власника, не застосовано. Записувати «застосовано» лише після
live-перевірки `GET /branches/{b}`.

## Злите з попереднього baseline (перевірено `GET /pulls/{n}`, 2026-10-02)

Stabilization Wave 2 merge train 2026-10-02 (звичайні merge-коміти, по
одному; перед кожним — злиття актуального `developer` у гілку PR,
перегенерований і ідемпотентний `RUNTIME_MANIFEST.json`, 8/8 exact-head
перевірок, 0 відкритих тредів; після кожного — зелений push-CI
`developer` 6/6):

| PR | Merge | Зміст | Issue |
| --- | --- | --- | --- |
| #341 | `79a1cf2` | `TraceArchive/GraceCompletionExpiry*` детерміновані, без залежності від швидкості runner-а | #338 закрито |
| #340 | `7056c2e` | заглушки вбудованих команд self-test не витікають між suite | #337 закрито; 2 відкладені P2 — #350 |
| #336 | `fb3c1a0` | гейт оновлювача приймає exit 10 `BRAVO_SETUP` як PASS WITH WARNINGS | #330 закрито |
| #343 | `6426dde` | Health: причина застарілої generation, дедуп похідних хмарних рядків | #322 закрито |
| #345 | `680bdd2` | DataRestore утримує тип запуску служб через контракт `BRAVO.System` | #333 закрито |
| #344 | `b095d2b` | retention: COMPLETE видаляється лише за строком; fail-closed перебудова шляхів | #335 лишається відкритим (feature — #339) |
| #334 | `5d00e20` | резервне копіювання лише встановлених компонентів, хвиля 1 | #282 закрито |

Перед #344 Codex знайшов 1 P1 (перебудова шляху без identity gate за
`NameTemplate`) і 2 P2; виправлено в PR з тестами. Після злиття #343
у #334 виник семантичний конфлікт у тесті Health (новий виклик
`Get-BRAVOHealthExpectedArchiveDefinitions`); розв'язано в PR до merge.
Звіт train — поза репозиторієм
(`/mnt/project-files/bravo-backlog/stabilization-wave-2-merge-train-2026-10-02.md`).

Попередні train-и (Production Safety 2026-10-01, `b0f3b2e`; 13 PR
2026-09-30/10-01, `4f732e5`) — у git-історії.

## Відкриті PR (перевірено `GET /pulls?state=open`, 2026-10-02)

| PR | Стан | Зміст | Що потрібно |
| --- | --- | --- | --- |
| #332 | draft | Maintenance: вивантаження всіх журналів toolkit на SFTP | власник: закрити інциденти GitGuardian, підтвердити SFTP-default, окремий дозвіл на merge |
| #339 | draft | Calendar Д/Т/М/Р і проріджування retention (#335, feature) | рішення власника щодо opt-in; звузити до дельти поверх #344 |
| #342 | draft | недосяжний UNC не обриває DataRestore і self-test | окремий дозвіл власника |
| #346 | draft | очікувані помилки self-test не червоні (#347) | окремий дозвіл власника |
| #348 | draft | кодова сторінка консолі на Windows < 10 | окремий дозвіл власника |
| #351, #352 | draft | швидкодія self-test і Configurator (інший тред) | рішення власника |
| #353 | draft | Maintenance fail-closed для служби, яку неможливо утримати від автостарту (#349) | CI, рев'ю, дозвіл на merge |

## Issue (перевірено `GET /issues/{n}`, 2026-10-02)

Закрито в Stabilization Wave 2 merge train: **#338**, **#337**, **#330**,
**#322**, **#333**, **#282** (у кожному коментарі закриття — PR, merge
commit, SHA `developer`, тести, CI і scope). **#335** — open: safety-частина
злита (#344), feature-частина в #339.

* Нові: **#349** (Maintenance зупиняє службу з нечитаним/`Other` типом
  запуску без утримання; фікс — draft PR #353), **#350** (2 відкладені P2
  ізоляції self-test після #340, за рішенням власника).
* **#154** (EPIC Config v2) — open. B0–B4, B6 виконано; **B7** — матрицю
  злито (#317), але parity ще не required check (немає захисту
  `developer`).
  * **B5** (міграція парку) — **не виконано**. Pilot 2026-09-29: 12/13
    критеріїв PASS, `Result: PILOT NOT ACCEPTED` лише через
    `SelfTestPass=false` (`Notifications/PublicIPLookupEnabledByDefault`).
    Решта парку не мігрована. **CI не може довести B5.**
* **#239** (обмеження гейту `LEGACY_READER_ISOLATION`) — open, відкладено.
* **#279**, **#280**, **#281** — open, чекають рішення власника.
* Відкриті `bug`-issue без злитого фіксу: #283–#287, #290, #291, #293,
  #294, #296, #298–#303, #305–#307, #349.
* Дизайни, чекають рішення/реалізації: #314 (автовідновлення служб),
  #316 (закриття BIS перед реставрацією, після #314 хвилі 2), #347.
* Acceptance-issue на реальних хостах: #152, #155, #158 — open, не
  автономні.

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

Стан на `developer` `5d00e20`, 2026-10-02. Рівні послідовні: ENGINEERING
READY → OPERATIONAL ACCEPTANCE (PENDING → ACCEPTED) → зняття RELEASE
BLOCKED.

| Рівень | Критерій | Вердикт зараз |
| --- | --- | --- |
| ENGINEERING READY | Runtime-cutover Config V2 (#216) у всіх production-entrypoint-ах | ТАК для прямих викликів і Configurator (#317, #328); непрямі виклики — #239 |
| ENGINEERING READY | B7: матриця регресій 5.3-шляху в required-наборі | ЧАСТКОВО — матриця в `BRAVO_SELF_TEST.ps1` (required на `master`), але `developer` без захисту |
| ENGINEERING READY | CI зелений на HEAD `developer` | ТАК (push-прогін `5d00e20`, 6/6) |
| ENGINEERING READY | Немає відкритих bug-issue щодо коректності runtime без рішення | НІ — 19 `bug`-issue у #283–#307, #349 (фікс у draft #353), #335 feature (#339) |
| OPERATIONAL ACCEPTANCE | B5: pilot `PILOT ACCEPTED` + мігровані хости парку з доказами | НІ — `PILOT NOT ACCEPTED`, парк не мігровано |
| OPERATIONAL ACCEPTANCE | Acceptance-issue на реальних хостах (#152/#155/#158) | НІ — open |
| RELEASE | `VERSION.json` provenance відповідає HEAD | НІ — `sourceCommit` `d77f3b4` ≠ `5d00e20` → `PROVENANCE_STALE` |
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
* Жодних promote, tag, release, GitHub Release для 5.3; не stamp-ити
  `VERSION.json`, не створювати 5.3 RC.
* Без явної авторизації користувача в поточному завданні: жодних
  commit, push, force-push, amend, reset, rebase, merge, змін branch
  protection, tag, release, видалення гілок.
* Merge з автоматичної сесії — лише за явною авторизацією власника на
  конкретний перелік PR (як merge train-и 2026-10-01 і 2026-10-02;
  авторизацію кожного вичерпано); без неї
  довести PR до green/mergeable і передати merge власнику.

## NEXT ACTION

```text
1. Власник застосовує захист developer за RELEASE_POLICY.md §13.4
   (6 канонічних + Config parity); сесія після цього перечитує
   GET /branches/developer і лише тоді оновлює §13.3 та цей файл.
2. Власник вирішує щодо draft PR #353 (#349): після зеленого CI —
   дозвіл на merge.
3. Власник вирішує #339 (opt-in проріджування) і #332 (інциденти
   GitGuardian, SFTP-default); окремо — #342, #346, #348, #351, #352.
4. Власник визначає пріоритет решти runtime-багів #283–#307, #350 і
   #279/#280/#281; фікси — окремими PR у developer.
5. B5: довести pilot до PILOT ACCEPTED (PublicIPLookupEnabled),
   рішення про модель міграції парку. До доказів B5 — hard stop нижче.
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
* `RUNTIME_MANIFEST.json` при конфлікті злиття: взяти сторону `developer`,
  повернути записи нових файлів гілки й перегенерувати хеші; повторний
  прогін перевірки мусить не мати розбіжностей.
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
