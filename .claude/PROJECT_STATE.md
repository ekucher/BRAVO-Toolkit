# BRAVO-Toolkit — поточний стан проекту

Останню перевірку виконано: 2026-09-30 ~18:00 UTC (Git + GitHub REST API, лише читання).

Кожне змінне твердження нижче має дату й метод перевірки. Це знімок, а не
гарантія: **перечитати перед дією**. Порядок джерел істини — розділ
«Порядок джерел істини» в кінці файлу; цей файл не є авторизацією на
жодну Git/GitHub-мутацію.

## Канонічна гілка

`developer`

## State baseline SHA

`4a54d34f2a71cc0ce24e7b8c2a0979e3007ba12a` — `developer`, Merge PR #262
(перевірено `git ls-remote` / `GET /branches/developer`, 2026-09-30).

Попередній baseline — `28e6fcd` (2026-09-29). Між ними влито: PR #270,
#271 (Telegram), потяг #272–#278, Wave A #267, #268, #258, #262 (деталі
нижче).

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

## Live-стан (перевірено 2026-09-30, перечитати перед дією)

| Об'єкт | Значення | Метод |
| --- | --- | --- |
| `origin/developer` | `4a54d34` | `GET /branches/developer` |
| `origin/master` | `f8fa5aa` (stable `5.2.4`, `VERSION.json.sourceCommit` `91db94c`) | `GET /branches/master` |
| `developer` `VERSION.json` | `5.3.0-dev.3`, `releaseChannel: development`, `sourceCommit` `d77f3b4` (319 комітів позаду HEAD) | файл у дереві |
| CI push-прогін `developer` `4a54d34` | 5 перевірок ` (push)` + `Telegram CI summary` — усі success | `GET /commits/4a54d34/check-runs` |

## Branch protection — бажане проти перевіреного

Канон, бажана політика й процедура власника — `RELEASE_POLICY.md`
§13.3–§13.4. Payload-и для власника:
`/mnt/project-files/bravo-backlog/branch-protection-payloads/`
(`developer.json`, `master-add-config-parity.json`; поза репозиторієм).

Перевірений стан (GitHub REST API, 2026-09-30, перечитати перед дією):

* `master` — `protected: true`; required checks (`enforcement_level:
  everyone`) рівно шість: `Parser / BOM / JSON`, `PSScriptAnalyzer`,
  `BRAVO_SELF_TEST.ps1`, `Secret scanning (gitleaks)`,
  `GitGuardian Security Checks`, `BRAVO_DATA_RESTORE_MATRIX_TEST.ps1`.
  `strict`, `enforce_admins`, вимога PR, заборона force push/видалення —
  **не перевірювані з сесії** (`GET .../protection` → 403,
  потрібен `administration=read`).
* `developer` — **НЕ protected** (`protected: false`, `contexts: []`,
  `GET /rules/branches/developer` → `[]`). Ніщо технічно не блокує merge
  з червоним CI.
* Теги — ruleset `protected-release-tags` (id 23541829): `active`,
  `refs/tags/v*`, `deletion`/`non_fast_forward`/`update`, bypass порожній.
* `Config parity (BRAVO_CONFIG_LOADER)` — створюється на кожному
  `pull_request` (`config-parity.yml`: тригер без фільтрів, крок N/A →
  `exit 0`; live-підтверджено на PR #263, #310); на push не створюється;
  **ще не required** ні на `master`, ні на `developer`.

**OWNER ACTION REQUIRED:** створити захист `developer` (6 канонічних +
`Config parity`, `strict: false`, `enforce_admins: true`, PR без
обов'язкових схвалень, без force push/видалення) — `RELEASE_POLICY.md`
§13.4. Додати `Config parity` на `master` — окреме необов'язкове рішення
власника, не застосовано. Записувати «застосовано» лише після
live-перевірки `GET /branches/{b}`.

## Злите з попереднього baseline (перевірено `GET /pulls/{n}`, 2026-09-30)

Telegram-підсумок CI (merged 2026-09-29):

* PR #270 `c440c2e` — `.github/workflows/telegram-ci-summary.yml`,
  notifier лише на push у `developer`, без checkout коду.
* PR #271 `f12e57a` — без авто-повторів `sendMessage`, значки
  `waiting`/`requested`; закрив два post-merge P2 з #270.
  Відкритих follow-up-ів щодо Telegram не знайдено.

Потяг #272–#278 (merged 2026-09-30, фінальний merge `e90dd00` = PR #277):

* #272 `7764a9d` — T001, блок перенаправленого `toolIntegritySettings.ManifestPath`;
* #273 `be7d390` — T021, походження бінарників у `TOOLS_MANIFEST.json`;
* #274 `c0eb84f`, #275 `bd23d4c` — T023, одна реалізація нотифікацій;
* #276 `de5cefd` — T011 Archive Main; #278 `fd6ef71` — статус-файл Archive при збої;
* #277 `e90dd00` — T011 Health.

Wave A (merged 2026-09-30):

* #267 `4af465c` — T011 Maintenance; #268 `323026e` — T011 DataRestore;
* #258 `1d982ab` — T025 scheduler lock-wait; #262 `4a54d34` — A10 мовний аудит документації.

## Відкриті PR (перевірено `GET /pulls?state=open`, 2026-09-30)

| PR | Стан | Зміст | Що потрібно |
| --- | --- | --- | --- |
| #259 | ready, `7abc039` | A5+A6: guard `@(List[object])` під StrictMode | рішення власника щодо Codex раунду 2, потім merge |
| #260 | ready, `4932c16` | T033: пріоритет Credential Manager | те саме |
| #261 | ready, `1f075dc` | T026: формулювання ArchivePeakSafe | те саме |
| #263 | ready, `dd3162e` | T027: хибні посилання + CI-перевірка | те саме |
| #311 | draft, base `developer` | #219 частина A: самодостатні вибіркові suite | review → ready → merge власником |
| #312 | draft, base `claude/project-thread-fzdylk` (= #311) | #219 частина B: секційна ізоляція фатальних винятків | після #311; перенацілити base на `developer` |
| #308 | draft | #304: відхиляти диск-/корінь-відносний `-TargetPath` (DataRestore) | review |
| #309 | draft | #288: `time` у `Test-RangeIdUsage` під StrictMode (Maintenance) | review |
| #310 | draft | #295: `StartType` під StrictMode (Health) | review |

Жоден із #259/#260/#261/#263 **не злито**. Codex залишив коментарі
раунду 2 на поточних head-ах (2026-09-30 ~16:00–17:06 UTC); рішення,
чи опрацьовувати їх до merge, — за власником.

## Issue (перевірено `GET /issues/{n}`, 2026-09-30)

* **#216** (P0 cutover) — closed/completed 2026-09-28. Runtime-cutover
  реалізовано для фіксованого переліку 14 entrypoint-ів; real-server
  acceptance **не виконувався**. «Runtime реалізовано» ≠ «міграцію парку
  прийнято» ≠ «release governance завершено».
* **#154** (EPIC Config v2) — open. B0–B4, B6 виконано.
  * **B5** (міграція парку) — **не виконано**. Pilot на пілотному сервері
    2026-09-29: 12/13 критеріїв PASS, `Result: PILOT NOT ACCEPTED` лише через
    `SelfTestPass=false` (`Notifications/PublicIPLookupEnabledByDefault` —
    передіснуюча site-policy розбіжність; `SemanticParityZeroDiff=true`,
    `HealthPass=true`). Докази: `C:\ProgramData\BRAVO\ConfigV2PilotEvidence\<pilot-id>`.
    Решта парку не мігрована. **CI не може довести B5** — pilot-artifact
    self-test працює на синтетичному InstallRoot.
  * **B7** (матриця регресій 5.3-шляху + parity як required gate) — у
    роботі: локальна гілка `claude/b7-config-regression-matrix`
    (worktree `/home/claude/wc-b7`, від `4a54d34`; на remote станом на
    2026-09-30 відсутня, PR немає). Інвентар прогалин —
    `/mnt/project-files/bravo-backlog/wave-c-evidence.md` §4, зокрема
    підтверджений розрив: `BRAVO_OPERATIONS_HEARTBEAT.ps1` викликає
    `Import-BravoConfiguration` без `-DisallowLegacyPrimaryAutoDetect` і
    не входить у перелік гейту `LEGACY_CONFIG_AUTOEXEC`.
* **#219** (self-test resilience) — open; заплановано двома PR:
  частина A = #311, частина B = #312 (обидва draft).
* **#239** (8 відомих обмежень гейту `LEGACY_READER_ISOLATION`) — open,
  **відкладено без змін**: рішення власника — жодних інкрементальних
  патчів, лише окремий dataflow-дизайн. Не закривати.
* **#279** (bug, Archive: оцінка «розмір джерела + 2%» не обмежує
  метадані 7-Zip), **#280** (question, Operations outbox → DeadLetter
  після enrollment), **#281** (question, коли прибрати виконання legacy
  `BRAVO.config` через явний `-ConfigPath`) — нові, чекають рішення
  власника. #281 логічно після B5.
* Відкриті `bug`-issue: 27 у діапазоні #279–#307 (#307 — апостроф
  U+2019 ламає згенерований `BRAVO.local.config`, fail-closed).
* Acceptance-issue на реальних хостах: #152, #155, #158, #188 — open, не
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

Стан на `developer` `4a54d34`, 2026-09-30. Рівні послідовні: ENGINEERING
READY → OPERATIONAL ACCEPTANCE (PENDING → ACCEPTED) → зняття RELEASE
BLOCKED.

| Рівень | Критерій | Вердикт зараз |
| --- | --- | --- |
| ENGINEERING READY | Runtime-cutover Config V2 (#216) у всіх production-entrypoint-ах | ЧАСТКОВО: 14 з переліку — так; `BRAVO_OPERATIONS_HEARTBEAT.ps1` — ні |
| ENGINEERING READY | B7: матриця регресій 5.3-шляху в required-наборі | НІ — у роботі, гілка локальна, PR немає |
| ENGINEERING READY | CI зелений на HEAD `developer` | ТАК (push-прогін `4a54d34`) |
| ENGINEERING READY | Немає відкритих bug-issue щодо коректності runtime без рішення | НІ — 27 `bug`-issue #279–#307; draft-фікси #308–#310 |
| ENGINEERING READY | Відкриті Wave A PR (#259/#260/#261/#263) завершено | НІ — чекають рішення щодо Codex раунду 2 |
| OPERATIONAL ACCEPTANCE | B5: pilot `PILOT ACCEPTED` + мігровані хости парку з доказами | НІ — пілотний сервер: `PILOT NOT ACCEPTED`, парк не мігровано |
| OPERATIONAL ACCEPTANCE | Acceptance-issue на реальних хостах (#152/#155/#158/#188) | НІ — open |
| RELEASE | `VERSION.json` provenance відповідає HEAD | НІ — `sourceCommit` `d77f3b4` ≠ `4a54d34` → `PROVENANCE_STALE` у `ci/New-BRAVOReleaseArtifact.ps1` |
| RELEASE | Прийнятий RC | НІ — `v5.3.0-rc.1` (commit `3a87079`) immutable, приймання не проходив; наступний кандидат — `rc.2`, не створено |
| RELEASE | Захист `developer` застосовано й перевірено live | НІ — OWNER ACTION REQUIRED (§13.4) |
| RELEASE | Питання #281 вирішено | НІ — open |

**Підсумок:** ENGINEERING READY — не досягнуто; OPERATIONAL ACCEPTANCE —
PENDING (не розпочато для парку); **RELEASE BLOCKED**.

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
* Merge з автоматичної сесії без approving review відхиляє класифікатор
  дозволів harness-а (`[Merge Without Review]`) — це не політика
  репозиторію; довести PR до green/mergeable і передати merge власнику.

## NEXT ACTION

```text
1. Власник вирішує щодо Codex раунду 2 на #263/#260/#261/#259
   (опрацювати чи прийняти як є). Потім довести ці PR до green
   і передати merge власнику в порядку #263 -> #260 -> #261 -> #259,
   перечитуючи base після кожного merge.
2. #311 (частина A #219): review, draft -> ready, merge власником;
   потім #312 перенацілити на developer, review, merge власником.
3. B7: у /home/claude/wc-b7 (гілка claude/b7-config-regression-matrix)
   закрити прогалини з wave-c-evidence.md §4 (починаючи з heartbeat
   + інваріанта повноти переліку AUTOEXEC), повний self-test,
   PR у developer лише з авторизацією на push.
4. Власник застосовує захист developer за RELEASE_POLICY.md §13.4;
   сесія після цього перечитує GET /branches/developer і лише тоді
   оновлює §13.3 та цей файл.
Перед кроком 1 перечитати: git rev-parse origin/developer, GET /pulls?state=open.
```

Паралельно, лише за рішенням власника: draft-фікси #308–#310; питання
#279–#281; пілотний сервер (розділ вище).

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
