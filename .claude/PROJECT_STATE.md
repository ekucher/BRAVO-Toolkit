# BRAVO-Toolkit — поточний стан проекту

Останню перевірку виконано: 2026-10-01 (після Production Safety merge train) (Git + GitHub REST API, лише читання).

Кожне змінне твердження нижче має дату й метод перевірки. Це знімок, а не
гарантія: **перечитати перед дією**. Порядок джерел істини — розділ
«Порядок джерел істини» в кінці файлу; цей файл не є авторизацією на
жодну Git/GitHub-мутацію.

## Канонічна гілка

`developer`

## State baseline SHA

`b0f3b2e5c596486dd32bdc3f8636159911c29118` — `developer`, Merge PR #323
(перевірено `GET /branches/developer`, 2026-10-01).

Це останній runtime-merge Production Safety merge train 2026-10-01; PR
із цим файлом (#331) змінює лише документацію й зливається після нього.
Попередній baseline — `4f732e5` (Merge PR #318). Між ними train влив сім
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

## Live-стан (перевірено 2026-10-01, перечитати перед дією)

| Об'єкт | Значення | Метод |
| --- | --- | --- |
| `origin/developer` | `b0f3b2e` | `GET /branches/developer` |
| `origin/master` | `f8fa5aa` (stable `5.2.4`), не змінювався | `GET /branches/master` |
| `developer` `VERSION.json` | `packageVersion` `5.3.0-dev.3`, `releaseChannel: development`, `sourceCommit` `d77f3b4` (далеко позаду `b0f3b2e`) | файл у дереві |
| CI push-прогін `developer` `b0f3b2e` | 5 перевірок ` (push)` + `Telegram CI summary` — усі success | `GET /commits/b0f3b2e/check-runs` |
| Теги 5.3 | лише `v5.3.0-rc.1` | `git ls-remote --tags` |
| Відкриті PR | 5: #331 (цей файл), #332, #334, #336, #339 — усі, крім #331, draft | `GET /pulls?state=open` |
| Відкриті issue | 36 (без PR) | `GET /issues?state=open` |

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
  з червоним CI; обидва merge train-и 2026-10-01 тримали гейт (8/8
  exact-head перевірок, 0 відкритих тредів, зелений post-merge CI)
  процедурно.
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

## Злите з попереднього baseline (перевірено `GET /pulls/{n}`, 2026-10-01)

Production Safety merge train 2026-10-01 (звичайні merge-коміти, по
одному; перед кожним — злиття актуального `developer` у гілку PR,
перегенерований `RUNTIME_MANIFEST.json`, 8/8 exact-head перевірок,
0 відкритих тредів; після кожного — push-CI `developer`):

| PR | Merge | Зміст | Issue |
| --- | --- | --- | --- |
| #328 | `14fa99b` | Configurator не виконує legacy `BRAVO.config`; гейт `GENERATED_LOADER_CALL_TEXT` | #320 закрито |
| #325 | `4af584c` | єдиний читач `Get-BRAVOServiceStartMode` замість прямого `StartType` | #319 закрито |
| #329 | `9752c24` | тимчасовий Disabled служб на вікно реставрації зі знімком типів запуску (Maintenance) | #297 закрито; DataRestore — #333 |
| #326 | `977c3e1` | `-ForceRestore` при Disabled-службі BRAVO виконує реставрацію без зміни типу запуску | #321 закрито |
| #327 | `d8894d4` | `-SyncBAZA` через канонічний incremental-рушій; SKIPPED_CONCURRENT звітує «ПРОПУЩЕНО» | #292 закрито |
| #324 | `10f0d9d` | точний (дзеркальний) відкат `Update-BRAVOServer.ps1`; поведінкова перевірка оркестратора | #289 закрито |
| #323 | `b0f3b2e` | boot catch-up пропущеної нічної копії (`BRAVO_ARCHIV_CATCHUP`) | #322 частково, відкрите |

Push-CI після кожного merge — 6/6 success, крім `10f0d9d`: перший прогін
`BRAVO_SELF_TEST.ps1` упав на нестабільному тесті
`TraceArchive/GraceCompletionExpiry*` (те саме дерево зелене на
exact-head PR #324; один повторний запуск — 6/6 success); причина —
#338.

Під час train рев'ю знайшло й виправило в межах PR два P2: у #327
(пропуск через зайнятий lock звітував «УСПІШНО») і в #324 (оркестратор
відкату перевірявся лише текстом). Codex недоступний (ліміт) з
2026-09-30 ~22:13 UTC; рев'ю виконували окремі агенти.

Попередній merge train 2026-09-30/10-01 (13 PR, #313…#318, фінальний
`4f732e5`) — у git-історії та звіті поза репозиторієм
(`/mnt/project-files/bravo-backlog/merge-train-final-2026-10-01.md`).

## Відкриті PR (перевірено `GET /pulls?state=open`, 2026-10-01)

| PR | Стан | Зміст | Що потрібно |
| --- | --- | --- | --- |
| #331 | ready | цей файл | зливається останнім у train |
| #332 | draft | Maintenance: вивантаження всіх журналів toolkit на SFTP (новий листок `sftpDirectories.RuntimeLogs`) | окреме рішення власника про merge; поза train |
| #334 | draft | резервне копіювання лише встановлених компонентів (#282) | окремий тред; рішення власника |
| #336 | draft | гейт оновлювача приймає exit 10 `BRAVO_SETUP` як PASS WITH WARNING (#330) | рев'ю й рішення власника; поза train |
| #339 | draft | retention не видаляє COMPLETE-генерацію як «невдалу» (#335) | окремий тред; рішення власника |

## Issue (перевірено `GET /issues/{n}`, 2026-10-01)

Закрито в Production Safety merge train: **#320**, **#319**, **#297**,
**#321**, **#292**, **#289** (у кожному коментарі закриття — merged PR,
merge commit, SHA `developer`, CI і scope). Раніше закрито: #304, #288,
#295, #219, #216.

* **#322** — open, частково: boot catch-up зроблено (#323). Лишилось:
  діагностична причина в Health, найновіша не-COMPLETE генерація,
  `LastTaskResult`, `BRAVO_STATUS_Archive`, групування
  `LocalBackupGeneration`, дедуплікація похідних «cloud stale».
* **#330** — open, фікс у draft PR #336 (регресійний тест падає без
  виправлення); не злито.
* Нові з train: **#333** (DataRestore без тимчасового утримання типу
  запуску, продовження #297), **#337** (заглушки self-test витікають у
  глобальну сесію), **#338** (нестабільний `TraceArchive/GraceCompletionExpiry*`).
  Інший тред відкрив **#335** (retention видаляє COMPLETE-генерацію як
  «невдалу»); фікс у draft PR #339.
* **#154** (EPIC Config v2) — open. B0–B4, B6 виконано; **B7** — матрицю
  злито (#317), але parity ще не required check (немає захисту
  `developer`).
  * **B5** (міграція парку) — **не виконано**. Pilot 2026-09-29: 12/13
    критеріїв PASS, `Result: PILOT NOT ACCEPTED` лише через
    `SelfTestPass=false` (`Notifications/PublicIPLookupEnabledByDefault`).
    Решта парку не мігрована. **CI не може довести B5.**
* **#239** (обмеження гейту `LEGACY_READER_ISOLATION`) — open, відкладено.
  Факт від #328 записано в коментарі: гейт `GENERATED_LOADER_CALL_TEXT`
  не вакуумний, не охоплює конкатенований текст і `deploy\`.
* **#279**, **#280**, **#281** — open, чекають рішення власника.
* Відкриті `bug`-issue без фіксу: #282–#287, #290, #291, #293, #294,
  #296, #298–#303, #305–#307, #333, #337, #338 (#279 і #322 теж мають
  мітку `bug`).
* Дизайни, чекають рішення/реалізації: #314 (автовідновлення служб),
  #316 (закриття BIS перед реставрацією, після #314 хвилі 2).
* Acceptance-issue на реальних хостах: #152 (тег `v5.2.0-rc.2` досі
  відсутній), #155, #158 — open, не автономні.

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

Стан на `developer` `b0f3b2e`, 2026-10-01. Рівні послідовні: ENGINEERING
READY → OPERATIONAL ACCEPTANCE (PENDING → ACCEPTED) → зняття RELEASE
BLOCKED.

| Рівень | Критерій | Вердикт зараз |
| --- | --- | --- |
| ENGINEERING READY | Runtime-cutover Config V2 (#216) у всіх production-entrypoint-ах | ТАК для прямих викликів і Configurator (#317, #328); непрямі виклики — #239 |
| ENGINEERING READY | B7: матриця регресій 5.3-шляху в required-наборі | ЧАСТКОВО — матриця в `BRAVO_SELF_TEST.ps1` (required на `master`), але `developer` без захисту |
| ENGINEERING READY | CI зелений на HEAD `developer` | ТАК (push-прогін `b0f3b2e`, 6/6) |
| ENGINEERING READY | Немає відкритих bug-issue щодо коректності runtime без рішення | НІ — 20 `bug`-issue у #282–#307, а також #330 (фікс у draft #336), #333, #335 |
| OPERATIONAL ACCEPTANCE | B5: pilot `PILOT ACCEPTED` + мігровані хости парку з доказами | НІ — `PILOT NOT ACCEPTED`, парк не мігровано |
| OPERATIONAL ACCEPTANCE | Acceptance-issue на реальних хостах (#152/#155/#158) | НІ — open |
| RELEASE | `VERSION.json` provenance відповідає HEAD | НІ — `sourceCommit` `d77f3b4` ≠ `b0f3b2e` → `PROVENANCE_STALE` |
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
  конкретний перелік PR (як обидва merge train-и 2026-10-01); без неї
  довести PR до green/mergeable і передати merge власнику.

## NEXT ACTION

```text
1. Власник застосовує захист developer за RELEASE_POLICY.md §13.4
   (6 канонічних + Config parity); сесія після цього перечитує
   GET /branches/developer і лише тоді оновлює §13.3 та цей файл.
2. Власник вирішує щодо draft PR #336 (#330) і #332; фікс #338
   (нестабільний тест) — окремим PR, без пропуску тесту.
3. Власник визначає пріоритет #333, #335, #337 і решти runtime-багів
   #282–#307, а також #279/#280/#281; фікси — окремими PR у developer.
4. B5: довести pilot до PILOT ACCEPTED (PublicIPLookupEnabled),
   рішення про модель міграції парку. До доказів B5 — hard stop нижче.
5. #314 хвиля 1 (після «починай» власника), потім #316; решта #322.
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
