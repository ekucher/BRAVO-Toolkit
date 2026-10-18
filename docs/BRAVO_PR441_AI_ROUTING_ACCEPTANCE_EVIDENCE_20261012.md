# PR #441 — фінальний acceptance і готовність до merge

Документ фіксує стан PR #441 (`feature/ai-model-routing-policy` → `developer`) на
момент завершення фінального acceptance-проходу. Жодної публікації, переведення з
Draft, merge, зміни GitHub Settings, release чи деплою не виконано.

Коміт і `push` у гілку PR виконані за явною авторизацією власника, наданою в
поточному завданні для виправлення знайденого P1. Merge авторизації **не має**.

---

## 1. Live baseline

| Параметр | Значення (перевірено через `gh` і `git`) |
|---|---|
| PR | #441, `OPEN`, `isDraft: true` |
| URL | `https://github.com/ekucher/BRAVO-Toolkit/pull/441` |
| Base | `developer` (не змінювався) |
| Base HEAD | `f6251c50e8c7eabf602a19df659a8f6a27e475a7` |
| Head branch | `feature/ai-model-routing-policy` |
| **Head HEAD (фінальний)** | **`2f5faefdb9e8f64d72d85a9348602890819fd2dd`** |
| `mergeable` | `MERGEABLE` |
| Review threads | `0` (GitHub-рев'ю не проводилось; незалежне рев'ю — Codex A2A, розділ 5) |
| Файлів у diff | 17 |
| Розмір diff | +3076 / −14 |
| Локальна гілка | `feature/ai-routing-rebuild` у worktree `E:\GitHub\BRAVO-Toolkit-ai-routing` |
| Worktree | чистий (`git status --short` — порожній) |

### Зміна головки під час цього проходу

HEAD, зафіксований у завданні (`f0025583913a0175af599a8ddd5430b9c743ed92`), більше
не є актуальним. Причина — знайдений і виправлений P1 (розділ 4) і подальші
знахідки незалежного рев'ю. Послідовність:

```text
f002558  (головка на початок проходу)
30a518e  гейт фактичного запису делегованих агентів
bba8722  розв'язання відносної цілі запису; cwd не є другим коренем   (SEC-001/002)
379ac98  корінь проєкту не з payload; UNC/drive-relative — fail-closed
8ee9f17  гейт інструмента делегування під справжнім іменем Agent       (live-знахідка)
25a08ed  термінатор блоку SCOPE на ключі з цифрою/пробілом
2f5faef  device-префікс знімається лише для drive-absolute залишку     (SEC-001 нова нитка)
```

Усі 17 файлів у diff належать задачі. Сторонніх файлів немає:

```text
.claude/CLAUDE.md                          .claude/skills/orchestrate/SKILL.md
.claude/agents/architect.md                .github/workflows/ci.yml
.claude/agents/documentation.md            AGENTS.md
.claude/agents/security-reviewer.md        BRAVO_AGENT_POLICY.md
.claude/ai-routing.json                    RUNTIME_MANIFEST.json
.claude/hooks/record-ai-cost.ps1           Tools/Check-AgentPolicy.ps1
.claude/hooks/tests/Test-AIRouting.ps1     Tools/Get-AICostReport.ps1
.claude/hooks/validate-agent-routing.ps1   docs/ai/MODEL_ROUTING_POLICY.md
.claude/settings.json
```

---

## 2. Exact-head CI

Усі три workflow на фінальній головці `2f5faefdb9e8f64d72d85a9348602890819fd2dd`
завершені успішно.

| Workflow | Run ID | Статус |
|---|---|---|
| `Config parity` | 38201788932 | **success** |
| `Config v2 pilot artifact` | 38201788927 | **success** |
| `CI` | 38201788950 | **success** |

Job-и workflow `CI` (всі 5):

| Job | Результат |
|---|---|
| `Parser / BOM / JSON` | **success** |
| `PSScriptAnalyzer` | **success** |
| `Secret scanning (gitleaks)` | **success** |
| `BRAVO_SELF_TEST.ps1` | **success** |
| `BRAVO_DATA_RESTORE_MATRIX_TEST.ps1` | **success** |

### Перевірка по CI-логу, а не по exit-коду

Лог прогону 38201788950 завантажено й перевірено безпосередньо:

- job `BRAVO_SELF_TEST.ps1` містить рядок
  `Усі перевірки BRAVO-Toolkit успішно пройдено.` (04:17:41Z);
- `[PASS]`-рядків у цьому job — **3581**, тобто рівно стільки ж, скільки в
  локальному прогоні;
- `[FAIL]` трапляється 9 разів, і всі 9 — це текст баннера навмисних
  fixture-тестів («дочірній скрипт нижче МОЖЕ вивести `[FAIL]`…»), а не
  результати перевірок;
- обидва нові блокуючі кроки відпрацювали в job `Parser / BOM / JSON`:
  `BRAVO agent policy check: PASS` і `Total: 336  Failures: 0`.

Тобто успіх Full Self-Test підтверджений змістом логу, а не лише нульовим
exit-кодом harness-а.

Попередні головки цього проходу (`bba8722`, `379ac98`, `25a08ed`) також мали всі
три workflow `success`.

---

## 3. Routing matrix audit

Джерело маршрутизації — `.claude/ai-routing.json` (`schemaVersion: 1`). Канон
(`BRAVO_AGENT_POLICY.md`) авторитетний над матрицею; §9.1 це фіксує прямо, і
`Check-AgentPolicy.ps1` вимагає, щоб канон, `AGENTS.md`, `.claude/CLAUDE.md` і
skill `/orchestrate` посилались на матрицю.

### Роль → модель

| Роль | Модель | `write` | Закриває Codex-гейт |
|---|---|---|---|
| `scout` | haiku | ні | ні |
| `worker` | sonnet | так (deny-список) | ні |
| `tester` | sonnet | так (deny-список) | ні |
| `documentation` | sonnet | так (allow+deny) | ні |
| `reviewer` | opus | ні | ні |
| `architect` | opus | ні | **ніколи** |
| `security-reviewer` | opus | ні | **ніколи** |

Відповідність матриці та файлів агентів перевіряється в обидва боки (модель у
frontmatter, посилання на канон, наявність HANDOFF-блоку, відсутність зайвих
агентів) — `Check-AgentPolicy.ps1` і `Test-AIRouting.ps1`.

### Рівень ризику → обов'язкові рев'юери

| Рівень | Роли | Гейти | `codexRequired` |
|---|---|---|---|
| `LOW` | — | — | false |
| `MEDIUM` | — | `codex-qa` | true |
| `HIGH` | `architect` | `codex-qa`, `codex-architecture` | true |
| `CRITICAL` | `architect`, `security-reviewer` | `codex-qa`, `codex-security`, `codex-architecture` | true |

### Межі дозволеного запису

- `documentation`: allow `README.md`, `CHANGELOG.md`, `docs`, `docs/*`; deny
  `docs/*ACCEPTANCE*`, `*RUNBOOK*`, `*EVIDENCE*`, `*DISPOSITION*`, канон,
  `.claude/*`, `ci/*`, `*.ps1|psm1|psd1`, `*MANIFEST*.json`, `*INTEGRITY*.json`,
  `VERSION.json`. **Acceptance-докази агент не змінює** — перевірено і на
  делегуванні (SCOPE), і на фактичному записі, і live (розділ 7).
- `worker` / `tester`: `writeAllow` навмисно відсутній (реалізатор пише код, і
  його справжня межа — `SCOPE` задачі, якого хук у момент запису не бачить), але
  статичний `writeDeny` діє завжди: acceptance-докази, runbook-и, канон,
  `.claude/*`, манифести.
- Read-only роли (`scout`, `reviewer`, `architect`, `security-reviewer`) не
  пишуть нічого; `Test-AIRouting.ps1` додатково вимагає, щоб у їхньому
  frontmatter не було `Write`/`Edit`.

### Fallback

`allowedReasons` — рівно три: `quota`, `rate-limit`, `service-unavailable`.
`forbiddenReasons` перелічує `timeout`, `mcp-error`, `bridge-defect`,
`configuration-error`, `protocol-error`, `parse-failure`, `not-configured`,
`convenience`. `secondLevelFallback: false`.
`gatesFallbackMayNotSatisfy`: `codex-security`, `codex-architecture`,
`codex-verification`. Автоматичного downgrade на слабшу модель немає ні в
матриці, ні в хуку: модель ролі закріплена, і будь-який override, що не дорівнює
матриці, блокується.

### Fail-closed для невідомих і некоректних значень

| Ситуація | Поведінка |
|---|---|
| Матриця відсутня або пошкоджена | гейт-критичні роли — блок; решта — пропуск із `HOOK-ERROR` у журналі |
| `schemaVersion` ≠ 1 | те саме |
| Збій розбору stdin | роль відновлюється з сирого тексту (з розескейпуванням `\uXXXX`); будь-яка згадка гейт-критичної роли → блок |
| Агент поза матрицею | ніколи не блокується, лише журналюється |
| Ціль запису «неперевірна» | блок для кожної керованої матрицею роли |
| Ціль запису поза коренем проєкту | роль із allowlist — блок; роль лише з deny — пропуск із `HOOK-ERROR` |

---

## 4. Hook enforcement

Це найважливіший розділ проходу: саме тут знайдено дефекти, яких не було видно
ні в коді першої ревізії, ні в попередньому Codex QA.

### 4.1 P1 — межа запису існувала лише в тексті промпта

`PreToolUse`-matcher покривав тільки `Task` і виклики Codex. `Write`, `Edit`,
`NotebookEdit` не гейтились **узагалі**, а агент `documentation` мав і `Write`, і
`Bash`. При цьому його промпт стверджував:

> «The routing hook blocks these targets independently of this prompt.»

Це було неправдою. Межа трималась виключно на поведінці моделі, а документ
обіцяв механічний контроль. Виправлено:

- matcher розширено на `Write|Edit|NotebookEdit`;
- хук перевіряє межу на самому записі, діючу роль бере з поля `agent_type`
  payload-а (емпірично підтверджено живим прогоном, розділ 7);
- головна сесія (`agent_type` відсутній) не гейтиться — система обмежує
  делегованих виконавців, а не власника процесу;
- у `documentation` прибрано `Bash`, diff передається через `DIFF_FILE`;
- неправдиве твердження замінено на точний опис того, що саме блокує хук, із
  поясненням, чому `Bash` не гейтиться.

### 4.2 P1 — усі перевірки делегування були неактивні в живій сесії

Знайдено **лише** живим прогоном. У Claude Code 2.1.220 інструмент делегування
називається `Agent`, а не `Task`. Журнал реальної сесії:

```text
ALLOW | tool=Agent | agent=n/a | model=n/a | tool not subject to routing policy
```

Доки хук і matcher знали лише `Task`, усі чотири перевірки делегування
пропускались. Підтверджено двома негативними прогонами: `subagent_type: scout`
із `model: opus` **пройшов**; `REVIEW_MODE: claude-qa-fallback` без
`fallback_reason` **пройшов** (агент відмовився сам, на рівні власних
role-інструкцій, а не гейта). Той самий корінь робив облік делегувань порожнім.

Виправлено: хук і matcher розпізнають `Agent` і `Task`; `record-ai-cost.ps1`
рахує обидва; `Check-AgentPolicy.ps1` і `Test-AIRouting.ps1` фіксують обидва
імені. Прогін тих самих тестів проти `379ac98` дає **55 падінь** — це міра
того, наскільки поверхня була мертвою.

### 4.3 Що хук блокує у фінальному стані

1. модель виклику ≠ матриця;
2. Claude-агента брифують як формальний Codex-гейт (`review_source: codex-*`);
3. оголошений режим `claude-qa-fallback` без причини з трьох дозволених
   (причина валідується повністю: `quota/timeout` не проходить як `quota`;
   проста згадка рядка в брифі нічого не блокує);
4. `documentation` отримує `SCOPE` поза межами запису — перевіряється кожен
   токен, включно з каталогами й файлами без розширення;
5. делегований агент **фактично** пише поза межею запису.

Нормалізація шляху спільна для `SCOPE` і для цілі запису: уніфікація
розділювачів, `./`, згортання `..`, зрізання кінцевих точок і пробілів,
обрізання NTFS-потоку (`::$DATA`, `:stream`), визначення кореня **до** згортання.
Для цілі запису додатково: відносний шлях робиться абсолютним відносно `cwd`, а
зведення — виключно до кореня проєкту.

### 4.4 Відомі межі enforcement — свідомо прийняті

| Межа | Чому так |
|---|---|
| `Bash` не гейтиться | інспекція довільної команди на предмет «що вона запише» — евристика з гарантованими обходами. Межа тримається відсутністю інструмента: `documentation` не має `Bash`. |
| `worker`/`tester` мають `Bash` | вони й так пишуть код; їх стримує `SCOPE` брифа й рев'ю diff-а. Обхід статичного `writeDeny` через shell — **залишковий ризик**, задокументований у `docs/ai/MODEL_ROUTING_POLICY.md`. |
| Головна сесія не гейтиться | `agent_type` там відсутній; гейтити означало б блокувати роботу власника. |
| Хук не перевіряє **правдивість** причини fallback | він перевіряє, що оголошено одну з трьох дозволених. Підміна мітки дефекту конфігурації міткою ліміту формально пройшла б хук — її стримує канон §8.2 і дисципліна оркестратора. Зафіксовано live (розділ 7, E8). |
| Read-only роль не можна перевірити через гейт | у неї немає `Write` у tool set, тому виклик не доходить до хука. Межа тримається withholding-гілкою. |

---

## 5. Незалежне Codex-рев'ю

Усі знахідки відтворені власними тестами **проти тієї самої версії**, яку
оглядав Codex, перед виправленням; кожне виправлення верифіковане в тому ж
thread.

### Thread `01a12d02` — QA (попередня фаза, головка `f766b70`→`f002558`)

| ID | Sev | Суть | Статус |
|---|---|---|---|
| QA-001 | P1 | обходи межі запису `documentation` через шлях (traversal, кінцева точка, NTFS-потік, drive-qualified traversal, відкинуті токени) | **fixed** (4 кола) |
| QA-002 | P2 | при збої розбору stdin fail-closed не наставало | **fixed** (2 кола) |
| QA-003 | P2 | overblocking на будь-яку згадку `claude-qa-fallback` | **fixed** |
| QA-004 | P2 | причина fallback валідувалась за префіксом | **fixed** |
| QA-005 | P2 | кумулятивні снапшоти подвоювались у звіті | **fixed** |

### Thread `01a12db7` — Security (головка `30a518e`, 10 напрямків власника)

| ID | Sev | Суть | Статус |
|---|---|---|---|
| SEC-001 | P2 | відносна ціль не розв'язувалась: `../<ім'я-репо>/.claude/ai-routing.json` обходив deny — `worker` міг перезаписати саму матрицю | **fixed**, верифіковано на `bba8722` |
| SEC-002 | P2 | `cwd` трактувався як другий дозволений корінь: `E:/outside/docs/x.md` зрізався до `docs/x.md` і проходив allowlist | **fixed**, верифіковано на `bba8722` |

У верифікації Codex окремо вказав два залишкові пункти, обидва закриті
комітом `379ac98`: корінь проєкту більше не береться з payload (інакше SEC-002
повертався через інший вхід), і «неперевірні» форми шляху (drive-relative,
корінь диска, UNC) тепер fail-closed для кожної керованої роли, бо UNC може
бути аліасом файлу з deny-списку.

### Thread `01a12e27` — Security (фінальна дельта `bba8722`→`25a08ed`)

| ID | Sev | Суть | Статус |
|---|---|---|---|
| SEC-001 | P2 | **регресія, внесена моїм же фіксом**: зняття device-префікса застосовувалось до будь-якого залишку, тому `//?/GLOBALROOT/Device/HarddiskVolume3/<корінь>/BRAVO_AGENT_POLICY.md` з `cwd=<корінь>/docs` ставав `docs/GLOBALROOT/.../BRAVO_AGENT_POLICY.md` і проходив allow-патерн `docs/*` | **fixed** на `2f5faef` |

Верифікація SEC-001 на `2f5faef` виконана Codex-ом із **58 фактичними
прогонами** хука з обох ref-ів (Windows PowerShell 5.1.26100.9444), а не лише
читанням коду: оригінальний payload блокується для `Write`/`Edit`/`NotebookEdit`,
легітимний аліас `//?/<корінь>/modules/...` для `worker` лишається дозволеним, а
аліас на канон блокується саме deny-списком, не гілкою «неперевірно». Нових
дефектів не виявлено.

### Незалежність рев'ю

Codex оглядав дельту, авторську щодо попередніх виправлень, у трьох окремих
thread-ах; фінальна дельта рев'юилась у **новому** thread (`01a12e27`), не в
тому, де закривались SEC-001/002 попередньої ітерації. Інструкція кожного разу
забороняла механічне повторення попереднього рев'ю й вимагала атакувати
фінальний стан.

**Unresolved P0/P1/P2 — немає.**

---

## 6. Validation matrix

Платформа всюди — Windows PowerShell 5.1 (Windows 11 Pro 26200), worktree
`E:\GitHub\BRAVO-Toolkit-ai-routing`. PowerShell 7 як доказ сумісності не
використовувався.

| Перевірка | Команда | SHA | Exit | Ключовий результат | Вердикт |
|---|---|---|---|---|---|
| Тести маршрутизації | `.claude\hooks\tests\Test-AIRouting.ps1` | `2f5faef` | 0 | 336 перевірок, 0 падінь | **PASS** |
| Нетривіальність: гейт запису | ті самі тести проти попереднього хука | `f002559`→ | 1 | усі write-перевірки давали `0` замість `2` | **PASS** |
| Нетривіальність: SEC-001/002 | ті самі тести проти `30a518e` | `30a518e` | 1 | 4 падіння | **PASS** |
| Нетривіальність: UNC/корінь | ті самі тести проти `bba8722` | `bba8722` | 1 | 15 падінь | **PASS** |
| Нетривіальність: ім'я `Agent` | ті самі тести проти `379ac98` | `379ac98` | 1 | **55 падінь** | **PASS** |
| Нетривіальність: device-префікс | ті самі тести проти `25a08ed` | `25a08ed` | 1 | 6 падінь | **PASS** |
| Хук через stdin | дочірній процес на кожен клас | `2f5faef` | 0/2 | реальні exit-коди, не симуляція | **PASS** |
| Policy-чекер | `Tools\Check-AgentPolicy.ps1` | `2f5faef` | 0 | PASS | **PASS** |
| Нетривіальність policy-чекера | відкат matcher-а / повернення `Bash` | — | 1 | 3 падіння / 1 падіння | **PASS** |
| Заборонені патерни | `ci\Test-BRAVOForbiddenPattern.ps1` | `2f5faef` | 0 | 173 файли, чисто | **PASS** |
| PSScriptAnalyzer (security) | `ci\Invoke-BRAVOSecurityAnalysis.ps1` | `2f5faef` | 0 | 171 файл, чисто | **PASS** |
| Release-політика | `ci\Test-BRAVOReleasePolicy.ps1` | `2f5faef` | 0 | узгоджено | **PASS** |
| Парсер PS 5.1 | `[Parser]::ParseFile` на всіх змінених `.ps1` | `2f5faef` | — | 0 помилок | **PASS** |
| BOM / CRLF | побайтова перевірка | `2f5faef` | — | BOM у `.ps1`, без BOM у `.md`, 0 lone-LF | **PASS** |
| JSON | `ConvertFrom-Json` на матриці та `settings.json` | `2f5faef` | — | валідні | **PASS** |
| Цілісність рантайму | `ci\Update-BRAVORuntimeManifest.ps1 -Apply` | `2f5faef` | 0 | розбіжностей немає (163 файли) | **PASS** |
| **Канонічний Full Self-Test** | `BRAVO_SELF_TEST.ps1 -NoPause` | `2f5faef` | 0 | **3581 PASS, 0 FAIL**, «Усі перевірки BRAVO-Toolkit успішно пройдено», 18–19 хв | **PASS** |
| CI `Config parity` | GitHub Actions | `2f5faef` | — | success | **PASS** |
| CI `Config v2 pilot artifact` | GitHub Actions | `2f5faef` | — | success | **PASS** |
| CI `CI` (5 job-ів) | GitHub Actions run 38201788950 | `2f5faef` | — | success; у логу 3581 `[PASS]`, 0 справжніх `[FAIL]`, «Усі перевірки BRAVO-Toolkit успішно пройдено» | **PASS** |
| Нові блокуючі кроки в CI | job `Parser / BOM / JSON` | `2f5faef` | — | `BRAVO agent policy check: PASS`, `Total: 336  Failures: 0` | **PASS** |

### Про «успішний Full Self-Test, а не exit 0 через дефект harness»

Перший локальний прогін дав `exit=1` із трьома падіннями в
`Framework/SuiteSelectionContract.*`. Причина встановлена і **не** в репозиторії:
мій виклик мав `2>&1`, що в Windows PowerShell 5.1 при
`$ErrorActionPreference='Stop'` перетворює кожен рядок stderr дочірнього
`powershell.exe` у термінальний `NativeCommandError`. Проби контракту `-Suite`
навмисно запускають дочірній процес, який кидає виняток у stderr. Прогін без
`2>&1` на тому самому дереві: `3581 PASS / 0 FAIL / exit 0`, і всі три проби
`PASS`.

Тобто exit-код не брався на віру: підтверджено рядком
«Усі перевірки BRAVO-Toolkit успішно пройдено», нульовою кількістю `[FAIL]` і
3581 `[PASS]`.

---

## 7. Live delegation results

Останній незакритий пункт acceptance. Прогін виконувався **не** stdin-симуляцією,
а реальними headless-сесіями Claude Code (`claude -p`, промпт через stdin,
`--permission-mode acceptEdits`) у цьому ізольованому checkout, який є окремим
worktree від основної робочої копії. Deструктивних мутацій не виконувалось:
кожен негативний тест націлений на шлях, який мусить бути заблокований, тому
при проходженні тесту запису не відбувається взагалі; єдиний позитивний запис —
untracked scratch-файл у межах allowlist, видалений у `finally`.

Докази прив'язані до фінальної головки `2f5faef` (прогін повторювався після
кожної зміни хука).

| # | Сценарій | Що спостережено | Вердикт |
|---|---|---|---|
| E1 | делегування read-only задачі `scout` | `ALLOW tool=Agent agent=scout`; агент повернув коректні експорти `BRAVO.ExitCodes`, 0 записів | **PASS** |
| E2 | `scout` із `model: opus` | `BLOCK tool=Agent agent=scout model=opus — role 'scout' is pinned to model 'haiku'`; агент не стартував | **PASS** |
| E3 | `claude-qa-fallback` без причини | `BLOCK tool=Agent agent=reviewer — claude-qa-fallback brief declares no fallback_reason` на `PreToolUse` | **PASS** |
| E4 | `documentation` зі `SCOPE` на acceptance-доказ | `BLOCK tool=Agent agent=documentation — SCOPE '...ACCEPTANCE_EVIDENCE...' is outside the write boundary` | **PASS** |
| E5 | **фактичний запис** субагента | `ALLOW tool=Write agent=documentation` на `docs/ai/_LIVE_WRITEGATE_SCRATCH.md`; `BLOCK tool=Write agent=documentation` на `BRAVO_AGENT_POLICY.md` | **PASS** |
| E7 | `worker` із забороненою ціллю | `BLOCK tool=Agent agent=worker — SCOPE 'BRAVO_AGENT_POLICY.md' is outside the write boundary of role 'worker'` | **PASS** |
| E6 | read-only роль пробує писати | `Write` відсутній у tool set `reviewer`; виклик не дійшов до хука | **NOT RUN** (межа тримається withholding, не хуком) |
| E8 | Codex недоступний (зламаний `.mcp.json`) | гейт `codex-qa` оголошено `NOT RUN / BLOCKED`; причина класифікована як `not-configured`/`configuration-error`/`bridge-defect` → `forbiddenReasons`; Claude-рев'ювера як Codex-гейт **не делеговано**; жодного файлу не записано; повторних спроб не було | **PASS** |
| — | облік вартості | `.claude/logs/ai-cost.jsonl` заповнено реальними сесіями; звіт по 29 сесіях: 144 відповіді, 76 903 output-токени, делегування `documentation` 7 / `reviewer` 6 / `scout` 5 / `worker` 3 | **PASS** |
| — | стан робочого дерева після прогону | `git status --short` порожній; scratch-файл видалено | **PASS** |

Дослівні блокування з сесій (приклад):

```text
PreToolUse:Agent hook error: BRAVO routing policy blocked this call:
role 'scout' is pinned to model 'haiku' by .claude/ai-routing.json

PreToolUse:Write hook error: BRAVO routing policy blocked this call:
'BRAVO_AGENT_POLICY.md' is outside the write boundary of role 'documentation' (denied)
```

Два дефекти знайдені **тільки** цим прогоном: ім'я інструмента делегування
(розділ 4.2) і хибне блокування легітимного брифа через термінатор блоку `SCOPE`
(розділ 8, P3-1). Жодна stdin-симуляція їх не виявила б.

---

## 8. Формальні знахідки P0–P3

Усі `P0`/`P1`/`P2` закриті з доказами відтворення до виправлення.

| ID | Sev | Джерело | Суть | Статус |
|---|---|---|---|---|
| AUD-1 | **P1** | власний аудит (Phase B) | `PreToolUse` не покривав `Write`/`Edit`/`NotebookEdit`; межа запису існувала лише в тексті промпта; `documentation` мав `Bash`; промпт стверджував механічне блокування, якого не було | **fixed** (`30a518e`) |
| LIVE-1 | **P1** | live-прогін (Phase E) | справжнє ім'я інструмента делегування — `Agent`; усі 4 перевірки делегування були неактивні в живій сесії; облік делегувань порожній | **fixed** (`8ee9f17`), 55 падінь проти попередньої головки |
| SEC-001a | P2 | Codex `01a12db7` | відносна ціль не розв'язувалась → `worker` міг перезаписати матрицю маршрутизації | **fixed** (`bba8722`), верифіковано |
| SEC-002 | P2 | Codex `01a12db7` | `cwd` як другий дозволений корінь → `documentation` міг писати поза репозиторієм | **fixed** (`bba8722`), верифіковано |
| SEC-001b | P2 | Codex `01a12e27` | регресія фіксу аліасів: device-префікс знімався для будь-якого залишку → обхід deny через `GLOBALROOT/Device` | **fixed** (`2f5faef`), верифіковано 58 прогонами |
| AUD-2 | P2 | власний перегляд diff-а | у гейті запису перевірка «нерозпізнана ціль → дозволити» стояла **перед** перевіркою read-only: запис із невідомим полем шляху проходив би саме тому, що хук не зміг прочитати ціль | **fixed** (`30a518e`) |
| AUD-3 | P2 | залишок верифікації Codex | корінь проєкту брався з payload при відсутній `CLAUDE_PROJECT_DIR` → SEC-002 через інший вхід; «неперевірні» форми були fail-open для deny-only ролей | **fixed** (`379ac98`) |
| P3-1 | P3 | live-прогін | блок `SCOPE` не закривався рядком `STEP 1:` (цифра між словом і двокрапкою), тому проза брифа парсилась як цілі запису і легітимний бриф відхилявся | **fixed** (`25a08ed`) — не блокує, але виправлено |
| P3-2 | P3 | live-сесія E8 | хук перевіряє, що оголошено одну з трьох дозволених причин fallback, але не правдивість причини: підміна мітки дефекту конфігурації міткою ліміту формально пройшла б | **прийнято як межа** (розділ 4.4), задокументовано |
| P3-3 | P3 | live-сесія E6 | проба write-gate через read-only роль не перевіряє гейт: роль не має `Write`, виклик не доходить до хука | **прийнято**, замінено пробою E7 через `worker` |

---

## 9. Залишкові ризики

1. **`Bash` для `worker`/`tester`.** Ці роли мають shell, а їхню межу в хуку
   описує лише статичний `writeDeny`. Обхід deny-списку через shell-команду
   можливий. Свідомо прийнято: інспекція довільної команди — евристика з
   гарантованими обходами; стримування — `SCOPE` брифа й рев'ю diff-а. Явно
   задокументовано в `docs/ai/MODEL_ROUTING_POLICY.md`.
2. **Правдивість причини fallback не перевіряється механічно** (P3-2).
3. **Головна сесія не гейтиться.** Це дизайн: власник процесу не обмежується.
   Наслідок — enforcement стосується делегованих виконавців, не самого
   оркестратора.
4. **Поведінка read-only ролей на запис не перевіряється хуком** — лише
   відсутністю інструмента. Якщо комусь із них колись додадуть `Write`, гейт
   відпрацює (перевірено stdin-тестами), але live-доказу на це немає.
5. **Залежність від імені інструмента.** Enforcement делегування прив'язаний до
   `tool_name`. Якщо Claude Code перейменує інструмент ще раз, перевірки знову
   стануть неактивними **тихо**. Пом'якшення: обидва відомі імені зафіксовані
   тестами і `Check-AgentPolicy.ps1`, а журнал `ai-routing.log` робить таку
   ситуацію видимою (рядок `tool not subject to routing policy` на делегуванні —
   сигнал). Повністю це не закрито: нове, третє ім'я знову пройде як
   «не підлягає політиці». Це найсерйозніший залишковий ризик системи, і
   пункт 5 post-merge checklist призначений саме для його виявлення.
6. **Тести маршрутизації поза `BRAVO_SELF_TEST.ps1`** — свідомо: це
   інструментарій Claude Code, не BRAVO-рантайм (прецедент `.claude/hooks/tests/`).
   Вони виконуються в CI окремим блокуючим кроком у job `Parser / BOM / JSON`.
7. **Production-код BRAVO не змінюється.** Real-server acceptance для цього PR
   не потрібен: зміни не торкаються Windows-сервісів, Task Scheduler,
   Credential Manager, WinSCP/SFTP, restore чи reconcile.

---

## 10. Merge gate

| Гейт | Стан | Підстава |
|---|---|---|
| `code_review_gate` | **clear** | Codex QA (`01a12d02`) + Codex Security (`01a12db7`, `01a12e27`) + верифікації; усі P1/P2 `fixed`; unresolved немає |
| `ci_gate` | **clear** | усі три workflow `success` на `2f5faef`; Full Self-Test підтверджений змістом логу, не лише exit-кодом; нові блокуючі кроки відпрацювали |
| `security_gate` | **clear** | свіже Codex-рев'ю за всіма 10 напрямками власника на фінальному стані; обидві дельти після нього також оглянуті; SEC-001b верифіковано 58 фактичними прогонами |
| `live_hook_acceptance` | **clear** | 7 із 8 сценаріїв `PASS` у реальних headless-сесіях на `2f5faef`; E6 `NOT RUN` із конкретною причиною (роль не має `Write`) і замінений рівноцінною пробою E7 |
| `merge_gate` | **clear** | усі чотири гейти закриті; unresolved `P0`/`P1`/`P2` немає |

За політикою: unresolved `P0`/`P1` → BLOCKED; unresolved `P2` без рішення
власника → CONDITIONAL; без unresolved `P0`/`P1`/`P2` → CLEAR; `P3` не блокує.
Unresolved `P0`/`P1`/`P2` відсутні; усі три `P3` або виправлені, або прийняті як
задокументовані межі → `merge_gate: clear`.

---

## 11. Рішення власника

### Потрібне рішення

**Merge PR #441** — авторизації немає, і це єдина відкрита позиція. PR у стані
`Draft`, тому потрібні два окремі дозволи: переведення з Draft і сам merge.
Технічних перешкод більше немає: усі гейти закриті.

### Прийняті раніше в цьому проході (зафіксовано)

- коміт і `--force-with-lease` push для виправлення P1 — **дозволено**
  власником у поточному завданні;
- `live_hook_acceptance` — **обов'язковий pre-merge гейт** (рішення власника),
  тому post-merge follow-up для нього не оформлюється;
- `documentation` отримує diff через файл замість повернення `Bash`;
- головна сесія не гейтиться;
- для `worker`/`tester` — статичний deny-список без allowlist.

### Не потребує рішення

Залишкові ризики 1–6 із розділу 9 задокументовані в репозиторії й не блокують
merge за наявною політикою.

---

## 12. Post-merge smoke checklist

Виконати в основній робочій копії **після** merge, бо жива сесія читає
`.claude/settings.json` з кореня робочої копії, а не з worktree гілки.

1. `git -C E:\GitHub\BRAVO-Toolkit pull` на `developer`; звірити, що
   `.claude/settings.json` містить matcher
   `Agent|Task|Write|Edit|NotebookEdit|mcp__codex-agent__.*` і що BOM на місці.
2. `.\BRAVO_RUNTIME_GUARD.ps1` або будь-який кореневий entrypoint — переконатись,
   що цілісність рантайму не порушена (`Tools/` відстежується манифестом).
3. `powershell -NoProfile -File .claude\hooks\tests\Test-AIRouting.ps1` —
   очікувано 336 перевірок, 0 падінь.
4. `powershell -NoProfile -File Tools\Check-AgentPolicy.ps1` — очікувано PASS.
5. У **звичайній інтерактивній** сесії Claude Code делегувати будь-яку read-only
   задачу `scout` і перевірити, що в `.claude/logs/ai-routing.log` з'явився рядок
   `ALLOW | tool=Agent | agent=scout`. Відсутність рядка або
   `tool not subject to routing policy` на делегуванні означає, що ім'я
   інструмента знову змінилось (ризик 5) — це блокуючий сигнал.
6. Один негативний прогін: делегувати `scout` із явним `model: opus` і
   переконатись, що виклик заблокований із посиланням на матрицю.
7. Перевірити, що `Stop`-хук пише `.claude/logs/ai-cost.jsonl`, і що
   `Tools\Get-AICostReport.ps1` показує непорожнє «Делегування агентам».
8. Прогнати `.\BRAVO_SELF_TEST.ps1 -NoPause` **без** `2>&1` у виклику (див.
   розділ 6) і переконатись у рядку «Усі перевірки BRAVO-Toolkit успішно
   пройдено».

---

## Фінальний висновок

```text
READY FOR OWNER MERGE AUTHORIZATION
```

Головка: `2f5faefdb9e8f64d72d85a9348602890819fd2dd`.

Підстава: `code_review_gate` clear, `ci_gate` clear (усі три workflow `success`,
Full Self-Test підтверджений змістом логу), `security_gate` clear,
`live_hook_acceptance` clear (enforcement доведено реальними headless-сесіями на
цій самій головці), `merge_gate` clear. Unresolved `P0`/`P1`/`P2` немає. Робоче
дерево чисте, цілісність манифесту підтверджена, production-код BRAVO не
змінюється.

Істотно для оцінки довіри до цього вердикту: з п'яти знайдених у цьому проході
дефектів **два найважчі** (`AUD-1` і `LIVE-1`, обидва P1) робили заявлений
enforcement неіснуючим, і `LIVE-1` неможливо було знайти ніяк інакше, ніж живим
прогоном. Саме тому `live_hook_acceptance` як обов'язковий pre-merge гейт був
правильним рішенням власника, а попередній вердикт «merge ready» на головці
`f002558` був помилковим — його відкликано.

Merge, переведення з Draft, зміну GitHub Settings, release і деплой **не
виконано** і без явного дозволу власника виконано не буде.

---

## 13. Post-merge підтвердження (дописано 2026-10-12 після авторизації власника)

Власник авторизував undraft і merge. Фактично виконано:

| Дія | Результат |
|---|---|
| `gh pr ready 441` | PR переведено з Draft, `mergeStateStatus: CLEAN` |
| `gh pr merge 441 --merge` | `MERGED` 2026-10-12 07:23 UTC |
| merge-коміт | `05b5985d5a031f450b63456f0f2912f8725fa708` |
| батьки merge-коміта | `f6251c50e8c7eabf602a19df659a8f6a27e475a7` + `2f5faefdb9e8f64d72d85a9348602890819fd2dd` |
| збереження історії | 12 комітів гілки присутні в `developer`; squash свідомо не застосовано |
| віддалена гілка | `origin/feature/ai-model-routing-policy` видалено автоматично при merge |

Прийнята головка `2f5faef` є предком `developer` (`git merge-base --is-ancestor`
→ так), тобто ідентичність прийнятого доказу збережена.

### Post-merge smoke на `developer` @ `05b5985`

Виконано у worktree `E:\GitHub\BRAVO-Toolkit-ai-routing`, перемкненому на
`developer` (у головній робочій копії `E:\GitHub\BRAVO-Toolkit` прогнати пункт 1
чеклиста неможливо: вона стоїть на `feature/bsystem-operations-foundation` і
відстає на 947 комітів, тому `git pull` там був би неавторизованою мутацією
чужої гілки — перевірку проведено на фактично змердженому `developer`).

| # | Перевірка | Команда | Результат | Статус |
|---|---|---|---|---|
| 1 | matcher у `settings.json` | `Test-AIRouting.ps1` (асерти matcher-а) | `Agent\|Task\|Write\|Edit\|NotebookEdit\|mcp__codex-agent__.*`, BOM на місці | PASS |
| 2 | цілісність рантайму | `Test-BRAVORuntimeManifestIntegrity` | `IsValid=True`, 163 файли, 0 розбіжностей, `ShouldBlock=False` | PASS |
| 3 | тести маршрутизації | `.claude\hooks\tests\Test-AIRouting.ps1` | `Total: 336  Failures: 0`, exit 0 | PASS |
| 4 | політика агентів | `Tools\Check-AgentPolicy.ps1` | `PASS`, exit 0 | PASS |
| 5 | **живе делегування** | `claude -p` у worktree, делегування `scout` | `2026-10-12 10:27:45 \| ALLOW \| tool=Agent \| agent=scout \| routing policy satisfied` | PASS |
| 6 | негативний прогін моделі | те саме з `model: opus` | `BLOCK \| tool=Agent \| agent=scout \| model=opus \| role 'scout' is pinned to model 'haiku'` | PASS |
| 7 | облік вартості | `.claude\logs\ai-cost.jsonl` | 31 запис, `agentCalls: {"scout":1}` у двох останніх сесіях | PASS |
| 8 | повний self-test (локально) | `BRAVO_SELF_TEST.ps1 -NoPause` | 3582 `[PASS]`, 0 `[FAIL]`, exit 0, «Усі перевірки BRAVO-Toolkit успішно пройдено» у `LOGS/HELPERS/BRAVO_SELF_TEST_20261012_110708_546_PID49836.log` | PASS |
| 8a | повний self-test (CI) | job `BRAVO_SELF_TEST.ps1 (push)`, прогін `38220436409` | 3581 `[PASS]`, той самий канонічний фінальний рядок — перевірено **змістом логу**, не exit-кодом | PASS |

Пункт 5 — не формальність: рядок `ALLOW | tool=Agent` доводить, що
enforcement живий саме в змердженому стані. Якби на його місці був
`tool not subject to routing policy`, це означало б, що ім'я інструмента знову
змінилось і система тихо мертва.

Окремо зафіксовано **пастку середовища**: `BRAVO_SELF_TEST.ps1` **без**
`-NoPause` зависає в `Wait-BRAVOManualExit` (операторська пауза) і виглядає як
нескінченний прогін. Перший локальний post-merge запуск був убитий саме через
це; повторний із `-NoPause` відпрацював нормально. Для автоматизованих прогонів
`-NoPause` обов'язковий.

### Залишковий ризик 5 закрито

Ризик «наступне перейменування інструмента делегування тихо вимикає
enforcement» закрито активним детектором у `Stop`-хуку
(`.claude/hooks/record-ai-cost.ps1`): делегування під невідомим гейту іменем
дає рядок `ALERT` у `ai-routing.log`, поле `unknownDelegationTools` у
`ai-cost.jsonl` і окремий блок у `Get-AICostReport.ps1`; інваріанта додана в
`Check-AgentPolicy.ps1`. Гілка `feature/ai-routing-tool-name-detector`, коміт
`1c53513060fc6b2359e55ee72659a3e7e27c0f99`; `Test-AIRouting.ps1` 353/0
(6 нових асертів падають проти `05b5985` — нетривіальність доведено); CI
`workflow_dispatch` на цій гілці: `CI`, `Config parity`,
`Config v2 pilot artifact` — усі `success`. PR по цій гілці **не створено**:
окремого дозволу на це не було.

Залишкові ризики 1–4 і 6 лишаються прийнятими без змін.
