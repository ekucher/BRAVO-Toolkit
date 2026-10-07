# BRAVO-Toolkit — поточний стан проекту

Останню перевірку виконано: 2026-10-07 (після Autonomous Correctness Green Wave, #412 і #391) (Git + GitHub REST API, лише читання).

Кожне змінне твердження нижче має дату й метод перевірки. Це знімок, а не
гарантія: **перечитати перед дією**. Порядок джерел істини — розділ
«Порядок джерел істини» в кінці файлу; цей файл не є авторизацією на
жодну Git/GitHub-мутацію.

## Канонічна гілка

`developer`

## State baseline SHA

`2e3a5da27a7edd99868e2dfd164d16851fed2425` — `developer`, Merge PR #391
(перевірено `git rev-parse origin/developer`, 2026-10-07).

Це останній runtime-merge Autonomous Correctness Green Wave 2026-10-06/07;
PR із цим файлом змінює лише документацію й зливається після нього.
Попередній baseline — `b0f3b2e` (Merge PR #323, 2026-10-01). Між ними в
`developer` злито 56 PR (`git rev-list --count --first-parent b0f3b2e..2e3a5da` = 56, усі — merge PR; деталі нижче).

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

## Live-стан (перевірено 2026-10-07, перечитати перед дією)

| Об'єкт | Значення | Метод |
| --- | --- | --- |
| `origin/developer` | `2e3a5da` | `git rev-parse origin/developer` |
| `origin/master` | `f8fa5aa` (stable `5.2.4`), не змінювався | `git rev-parse origin/master` |
| `developer` `VERSION.json` | `packageVersion` `5.3.0-dev.3`, `releaseChannel: development`, `sourceCommit` `d77f3b4` (далеко позаду `2e3a5da`) | файл у дереві |
| CI push-прогін `developer` `2e3a5da` | run 37596365619 — на момент запису в процесі; перечитати | `GET /commits/2e3a5da/check-runs` |
| Теги | `v5.3.0-rc.1`; `v5.2.5-rc.1`…`rc.4` (hotfix); `v5.2.5-rc.5` ще не опубліковано | `git ls-remote --tags` |
| Відкриті PR | лише цей файл | `GET /pulls?state=open` |
| Відкриті issue | 17 (без PR) | `GET /issues?state=open` |

## Branch protection — бажане проти перевіреного

Канон, бажана політика й процедура власника — `RELEASE_POLICY.md`
§13.3–§13.4. Payload-и для власника:
`/mnt/project-files/bravo-backlog/branch-protection-payloads/`
(`developer.json`, `master-add-config-parity.json`; поза репозиторієм).

Перевірений стан (GitHub REST API, 2026-10-07, перечитати перед дією):

* `master` — `protected: true`; required checks рівно шість:
  `Parser / BOM / JSON`, `PSScriptAnalyzer`, `BRAVO_SELF_TEST.ps1`,
  `Secret scanning (gitleaks)`, `GitGuardian Security Checks`,
  `BRAVO_DATA_RESTORE_MATRIX_TEST.ps1`. `strict`, `enforce_admins`, вимога
  PR, заборона force push/видалення — **не перевірювані з сесії**
  (`GET .../protection` → 403, потрібен `administration=read`).
* `developer` — **НЕ protected** (`protected: false`, `contexts: []`,
  `GET /rules/branches/developer` → `[]`). Ніщо технічно не блокує merge
  з червоним CI; усі merge-хвилі 2026-10-01…10-07 тримали гейт (8/8
  exact-head перевірок з першої спроби, 0 відкритих тредів, зелений
  post-merge CI) процедурно.
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

## Злите з попереднього baseline (перевірено `git log --first-parent`, 2026-10-07)

Між `b0f3b2e` і `2e3a5da` злито 56 PR; усі звичайними merge-комітами,
кожен на окремій авторизації власника (merge train-и й Lead-треди
2026-10-01…10-07). Подробиці кожного — у тілі PR і коментарі закриття
issue.

**Autonomous Correctness Green Wave (2026-10-06/07)**, кожен PR: RED
(лише тести, self-test на Windows PowerShell 5.1 падає на нових тестах)
→ фікс → рев'ю → 8/8 exact-head перевірок CI з першої спроби → merge →
TREE_EQUAL → закриття issue з відповідністю критеріїв доказам.

* RED: у #388, #393, #403 і #404 перший RED-прогін був недійсним
  (дефект тестового каркаса або неоновлений `RUNTIME_MANIFEST.json`);
  доказом для них є повторний RED на незміненому runtime. У #406 одна
  з двох нових перевірок проходить і на старому коді (лише регресійний
  guard). У #391 self-test на проміжному head bf46716 впав (дефект
  нового тесту і застаріла текстова перевірка); виправлено в 9fdbf6f, і
  8/8 отримано на 9fdbf6f без повторного запуску. Деталі й номери
  прогонів — у тілі кожного PR.
* 8 перевірок exact-head (за check-runs PR): на Windows —
  `Parser / BOM / JSON`, `PSScriptAnalyzer`, `BRAVO_SELF_TEST.ps1`,
  `BRAVO_DATA_RESTORE_MATRIX_TEST.ps1`, `Config parity
  (BRAVO_CONFIG_LOADER)`, `Build + verify + happy-path + rollback +
  failure-injection`; на Ubuntu — `Secret scanning (gitleaks)`; зовнішній
  застосунок — `GitGuardian Security Checks`. `Telegram summary logic
  test` (Ubuntu) запускається лише на зміни своїх файлів і в ці 8 не
  входив.

| PR | Merge | Зміст | Issue |
| --- | --- | --- | --- |
| #382 | `6104c51` | оцінка місця вимірює production-джерело | #284 |
| #385 | `c696f6a` | Health: alert при блокуванні цілісності інструментів | #296 |
| #383 | `b9aed81` | DataRestore: пропущені маніфести при автовиборі дають WARNING | #294 |
| #384 | `e8b29be` | Archive: status-файл при контрольованих ранніх виходах | #291 |
| #390 | `6a36428` | Credentials: відкат сховища користувача при винятку SYSTEM-кроку | #302 |
| #387 | `1096dbb` | Archive: таймаут перевірки SFTP звільняє WinSCP lock | #290 |
| #386 | `dbf8d7c` | retention: старий битий архів — WARNING, не exit 41 | #300 |
| #388 | `16518ae` | BazaSync: MUTATION_AUTO_ARCHIVED не маскує drift/конфлікт | #285, #293 |
| #389 | `245ead0` | Maintenance: алерт errors_only за ознакою критичної помилки | #298 |
| #392 | `249362f` | Credentials: FatalError worker-а до запису теж відкочує | #302 |
| #393 | `72487a6` | Operations: outbox без EventId іде в DeadLetter | #305 |
| #399 | `a6078f4` | оцінка місця враховує метадані кожного файлу | #279 |
| #401 | `ea4d786` | Maintenance: ранні виходи доставляють алерти одразу | #299 |
| #402 | `44a68b6` | Operations: витіснені outbox-події redrain-яться, втрати рахуються | #280 |
| #403 | `609c801` | WinSCP-маски в шляхах екрануються | #366 |
| #406 | `b3ea0cb` | Dry run пише result-файл атомарно | #306 |
| #407 | `b34717b` | write-probe Dry run прибирає всі створені порожні каталоги | #283 |
| #404 | `c4689f9` | Health не звітує відкладену SFTP-перевірку як OK | #303 |
| #405 | `fe4afa5` | Configurator екранує типографські апострофи | #307 |
| #409 | `b146a09` | порожній FatalError SYSTEM-worker-а — збій, не успіх | #395 |
| #410 | `c27a3e6` | оцінка місця: дерева з нульовими файлами і записи каталогів | #400 |
| #412 | `24f7318` | Credentials: доказ round-trip позначки «worker не стартував» | #302 |
| #391 | `2e3a5da` | порожній каталог компонента — Warning, не блокує (рішення власника) | #301 |

Рев'ю: на початку хвилі (до ~23:22 UTC 2026-10-06) PR переглядав Codex,
і його зауваження виправлено до merge: #384 (P1 і P2: 13592a2, a6baff9),
#385 (P2: 3665c5c), #386 (P2), #387 (P1: таймаут WinSCP без звільнення
lock), #388 (388-C1). Далі ліміт Codex вичерпався, і рев'ю виконував
Claude QA fallback (`review_source: claude-qa-fallback`, `independence:
degraded`). З 2026-10-07 Codex знову доступний і переглянув #405, #409,
#410, #412 без зауважень. #391 пройшов чотири раунди Codex (усі P1/P2
виправлено з RED-тестами; четвертий раунд — за рішенням власника «Ще один
раунд»), після вичерпання ліміту Codex — Claude QA fallback = CLEAR.

Раніше в тому ж проміжку (окремі хвилі, git-історія й звіти поза
репозиторієм у `/mnt/project-files/bravo-backlog/`): Production Safety
state (#331), Wave 2 (#334, #336, #340, #341, #343, #344, #345), self-test
стабілізація (#346, #348, #351, #355, #375, #378), Configurator кеш
DefaultConfig (#352), політика оркестрації агентів v2 (#356), DataRestore UNC і reparse-тести (#342, #358),
Maintenance StartMode/lifecycle (#353, #361), range-ID (#359), Affected
self-test (#367, #368, #370, #371), validation docs (#362), retention
(#363), B-4/D-1/J-1 (#372–#374), хвиля інтеграції (#376, #377, #379 —
#314 хвиля 1).

## Відкриті PR (перевірено `GET /pulls?state=open`, 2026-10-07)

Відкритий лише PR із цим файлом.

## Issue (перевірено `GET /issues?state=open`, 2026-10-07)

Відкритих issue — 17. Відкритих `bug`-issue щодо коректності runtime
без рішення немає: #301 закрито (#391), #302 закрито (#412).

* **Рішення власника:** #381 (календарна схема retention Д/Т/М/Р),
  #314 (хвилі 2+ автовідновлення служб; кожна хвиля — окремий дозвіл на
  merge), #316 (закриття BIS перед реставрацією, після #314 хвилі 2),
  #364 і #365 (журнали на SFTP і маскування цілей Credential Manager).
* **Config V2 (виключено з автономних хвиль):** #154 (EPIC), #239, #281.
* **Реальні хости (не автономні):** #152, #155, #158.
* **Follow-up з correctness wave (тестовий борг, P2/P3):** #394
  (retention після #300), #396 (Credentials після #302), #397 (DeadLetter
  після #305), #398 (Maintenance/BazaSync після #298, #285/#293), #408
  (write-probe Archive preflight, аналог #283), #413 (Discovery після
  #301: HARDENING, TEST_DEBT, CLEANUP з deferred-debt proof).

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

Стан на `developer` `2e3a5da`, 2026-10-07. Рівні послідовні: ENGINEERING
READY → OPERATIONAL ACCEPTANCE (PENDING → ACCEPTED) → зняття RELEASE
BLOCKED.

| Рівень | Критерій | Вердикт зараз |
| --- | --- | --- |
| ENGINEERING READY | Runtime-cutover Config V2 (#216) у всіх production-entrypoint-ах | ТАК для прямих викликів і Configurator (#317, #328); непрямі виклики — #239 |
| ENGINEERING READY | B7: матриця регресій 5.3-шляху в required-наборі | ЧАСТКОВО — матриця в `BRAVO_SELF_TEST.ps1` (required на `master`), але `developer` без захисту |
| ENGINEERING READY | CI зелений на HEAD `developer` | ПЕРЕВІРИТИ — push-прогін `2e3a5da` (run 37596365619) на момент запису в процесі; попередній `24f7318` — success |
| ENGINEERING READY | Немає відкритих bug-issue щодо коректності runtime без рішення | ТАК — #301 і #302 закрито; лишився follow-up борг #394/#396–#398/#408/#413 (не acceptance) |
| OPERATIONAL ACCEPTANCE | B5: pilot `PILOT ACCEPTED` + мігровані хости парку з доказами | НІ — `PILOT NOT ACCEPTED`, парк не мігровано |
| OPERATIONAL ACCEPTANCE | Acceptance-issue на реальних хостах (#152/#155/#158) | НІ — open |
| RELEASE | `VERSION.json` provenance відповідає HEAD | НІ — `sourceCommit` `d77f3b4` ≠ `2e3a5da` → `PROVENANCE_STALE` |
| RELEASE | Прийнятий RC | НІ — `v5.3.0-rc.1` immutable, приймання не проходив; `rc.2` не створено |
| RELEASE | Захист `developer` застосовано й перевірено live | НІ — OWNER ACTION REQUIRED (§13.4) |
| RELEASE | Питання #281 вирішено | НІ — open |

**Підсумок:** ENGINEERING READY — не досягнуто (захист `developer`,
#239); OPERATIONAL ACCEPTANCE — PENDING; **RELEASE BLOCKED**.

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
  конкретний перелік PR або хвилю (як merge train-и 2026-10-01 і
  correctness wave 2026-10-06/07; ці авторизації вичерпано); без неї
  довести PR до green/mergeable і передати merge власнику.

## NEXT ACTION

```text
1. Власник публікує pre-release v5.2.5-rc.5 (target hotfix/5.2.5,
   stamp 9790a50) і перевіряє RC на сервері, де падав self-test.
2. Власник застосовує захист developer за RELEASE_POLICY.md §13.4
   (6 канонічних + Config parity); сесія після цього перечитує
   GET /branches/developer і лише тоді оновлює §13.3 та цей файл.
3. Власник вирішує щодо #381, #364/#365.
4. #314 хвиля 2 (окремий дозвіл), потім #316.
5. Follow-up борг #394, #396, #397, #398, #408, #413 — окремими
   PR у developer (потрібна нова авторизація на merge).
6. B5: довести pilot до PILOT ACCEPTED (PublicIPLookupEnabled),
   рішення про модель міграції парку. До доказів B5 — hard stop нижче.
Перед кроком 1 перевірити кандидат hotfix (RC незмінний після публікації):
  git rev-parse origin/hotfix/5.2.5        # очікується 9790a50
  git show origin/hotfix/5.2.5:VERSION.json # 5.2.5-rc.5, sourceCommit 3f181ba
  CI на 9790a50 зелений (workflow_dispatch run 37528388423)
  git diff --stat 3f181ba 9790a50          # лише VERSION.json і RUNTIME_MANIFEST.json
  git ls-remote --tags origin 'v5.2.5-rc.5*' і список release — порожні
Під час перевірки RC на сервері (RELEASE_POLICY.md §8) записати в
issue/звіт результати BRAVO_SETUP.ps1 -ValidateOnly і BRAVO_DRY_RUN.ps1
(код завершення, рядки ERROR/WARNING); без них RC не вважати перевіреним.
Перед кроками 2–5 перечитати: git rev-parse origin/developer, GET /pulls?state=open.
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
