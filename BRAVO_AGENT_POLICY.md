# BRAVO Agent Policy — Canonical Rules

This file is the **single canonical policy** for automated agents working in `ekucher/BRAVO-Toolkit`.
`CLAUDE.md`, `AGENTS.md`, skills, subagents, MCP tools, and external reviewers must follow it.
If any harness-specific instruction conflicts with this file, this file wins **for agent-orchestration
mechanics** (roles, HANDOFF reporting, review severity, Codex routing, chat-link prohibition). It does
not override BRAVO-specific architecture, security, PowerShell 5.1, or release-lifecycle
substance defined in `.claude/CLAUDE.md`, `AGENTS.md`, and `.claude/rules/` / `.agents/rules/` — those remain
authoritative for BRAVO engineering policy.

Постійні повноваження агентів на Git/GitHub-дії (що дозволено автономно для дорученого завдання і що
потребує окремого дозволу власника) визначає розділ 13 цього файлу. Git-правила в `.claude/CLAUDE.md`,
`AGENTS.md`, `CLAUDE.md` і `.claude/rules/02-git.md` посилаються на нього й не встановлюють
паралельних меж.

## 1. Repository and branch safety

- Repository: `ekucher/BRAVO-Toolkit`.
- Main development branch: `developer`.
- Work in a feature branch. Never implement directly on `developer`.
- Never `git push` to `developer`.
- Never merge a PR without explicit owner permission in the current conversation.
- No commit, push, merge, tag, release, deployment, destructive cleanup, or deletion of existing work unless explicitly authorized for the current task.
  Явне доручення issue або завдання є такою авторизацією для commit, звичайного push власної task-гілки
  та PR до `developer` (розділ 13.1); merge, tag, release, deploy та інші дії розділу 13.2 — ні.
- Never force-push unless the owner explicitly authorizes that exact operation.
- Do not start the next staged PR before the current one has been accepted when work is being handed over sequentially.

## 2. Runtime compatibility — hard rule

BRAVO product and test PowerShell must remain compatible with **Windows PowerShell 5.1**.

- Use `powershell.exe` for PowerShell execution.
- Never substitute `pwsh` for BRAVO validation.
- No PowerShell 7-only syntax or cmdlets. Examples of forbidden constructs include:
  `??`, `?.`, ternary `? :`, `&&` / `||` command chains, `ForEach-Object -Parallel`,
  `ConvertFrom-Json -AsHashtable`, multi-argument `Join-Path`, `Get-Error`, `$PSStyle`, and `clean {}` blocks.
- **Only PowerShell child processes are constrained to `powershell.exe`.** Native executables such as `git`, `node`, `codex`, `npm`, compilers, and test runners may be started normally when the task requires them.
- If `powershell.exe` is unavailable in the current environment, do not use `pwsh` as evidence. Report the BRAVO check as `NOT RUN — powershell.exe unavailable`.

## 3. BRAVO self-test contract

- `./BRAVO_SELF_TEST.ps1 -NoPause` must keep working unchanged and remain the default Full run.
- No coverage reduction: do not remove, skip, bypass, or weaken existing checks.
- No `FAIL -> WARN` downgrades to make CI green.
- No in-process parallelization with runspaces, `-Parallel`, or background jobs. Parallelism is allowed only through separate CI jobs/processes where repository policy permits it.
- Do not migrate the BRAVO self-test framework to Pester.
- Structural refactoring of tests must preserve behavior and should start from a characterization baseline.
- A check is evidence only if it actually ran. Report exact command, exit code, and relevant result.

## 4. Production-state safety

Tests and fixtures must never read or write real BRAVO production state.

- Production VersionState path: `C:\ProgramData\BRAVO\State\BRAVO_VERSION_STATE.json`.
- Tests must use sandbox-local state paths.
- The production default path must remain unchanged unless the task explicitly changes the production contract.
- `BRAVO_ALLOW_DOWNGRADE=1` is forbidden as a workaround in tests or implementation.
- Do not touch other real paths under `C:\ProgramData\BRAVO\` from tests.

## 5. Scope discipline

- Change only files in the task `SCOPE`.
- No drive-by refactors, renames, formatting sweeps, unrelated cleanup, or opportunistic dependency upgrades.
- Two writers must never edit the same file, test, schema, generated artifact, or shared configuration in parallel.
- If the task requires a file outside scope, stop that package and report it as blocked instead of silently expanding scope.
- When code and documentation disagree, report the conflict. Change documentation only if it is within scope.
- List externally visible or upgrade-relevant behavioral changes in the final HANDOFF.

## 6. External publication and chat-link prohibition — hard rule

**No agent may publish, paste, transmit, or embed a link to any chat, conversation, assistant session, or shared dialogue.**

This prohibition applies to all destinations, including:

- GitHub issues, pull requests, reviews, discussions, comments, commit messages, releases, and repository files;
- documentation, HANDOFF text, generated reports, logs, CI output intentionally authored by an agent, Slack/email/messages, and other external systems;
- ChatGPT, Claude, Codex, or any other assistant/session/share URL.

Examples of prohibited material include share links, conversation URLs, session URLs, and deep links that open a private or shared chat.

Allowed for internal traceability when needed:

- non-URL identifiers such as a Codex `threadId`, `turnId`, finding ID, commit SHA, issue number, or PR number;
- repository URLs, documentation URLs, source-code URLs, and other non-chat resources when otherwise permitted.

Never convert an internal session/thread identifier into a clickable chat URL.
If a user explicitly asks to publish a chat link, stop and report that repository policy forbids agents from doing so.

## 7. Review severity model — canonical

All formal review findings use the same severity scale:

- **P0** — catastrophic/release-stopping defect with concrete evidence.
- **P1** — real correctness, security, data-integrity, protocol, or regression blocker.
- **P2** — should be fixed before acceptance, or explicitly dispositioned with rationale by the owner/lead according to task policy.
- **P3** — advisory/non-blocking improvement with concrete value.

Deterministic merge-gate semantics:

- unresolved P0 or P1 -> `blocked`;
- no P0/P1 but unresolved P2 -> `conditional`;
- no unresolved P0/P1/P2 -> `clear`.

Do not relabel a finding merely to clear a gate.

## 8. QA and independent-review routing

Claude Code is the default **Lead/Implementer orchestrator**. `claude-codex-a2a` is the preferred independent review layer.

### 8.1 Preferred formal QA

When the `codex-agent` MCP bridge is available, formal QA should use `codex_delegate` with role `qa` for changes that require a QA gate.

Use additional Codex roles when the change warrants them:

- `security` for authentication, authorization, secrets, command execution, filesystem trust boundaries, supply chain, or other security-sensitive changes;
- `architecture` for protocol/state/concurrency/module-boundary/failure-isolation changes;
- `verification` to re-check previously reported Codex findings after fixes.

A Claude `reviewer` may be used earlier as an internal pre-review, but a successful internal review is not represented as a Codex review.

The bridge is configured per workstation in `.mcp.json`, which is deliberately
untracked because it carries absolute paths to a local `claude-codex-a2a` build.
Copy `.mcp.json.example` and substitute the real path. A missing or misconfigured
`.mcp.json` means the Codex gates are simply unreachable on that machine — that is
a configuration defect to fix, and section 8.2 does **not** permit it as a fallback
reason.

### 8.2 Temporary Claude QA fallback when Codex is unavailable by limits

If Codex QA cannot run **specifically because of quota/usage limit, rate limit, or temporary Codex service unavailability**, a fresh Claude Code `reviewer` may temporarily satisfy the **QA role only**.

The fallback reviewer must:

- be a fresh agent that did not implement the change;
- be read-only;
- use the same P0/P1/P2/P3 severity model and acceptance criteria;
- run the relevant checks independently;
- explicitly report:
  - `review_source: claude-qa-fallback`
  - `fallback_reason: quota | rate-limit | service-unavailable`
  - `independence: degraded`
- never claim or imply that Codex QA ran.

Fallback is **not** allowed to hide bridge defects, configuration errors, protocol errors, parsing failures, test failures, or implementation bugs. Those are real blockers/issues to diagnose.

Claude QA fallback does **not** automatically replace required Codex `security`, `architecture`, or `verification` roles. If those roles are required by policy and Codex is unavailable, report the corresponding gate as not run/blocked unless the owner explicitly authorizes a different temporary procedure.

If Codex becomes available again before final acceptance of the same task, rerun the formal Codex QA when practical and replace the provisional fallback status with the real Codex result.

## 9. Review trigger matrix

Use proportional review depth:

- trivial/local mechanical change -> internal Claude reviewer may be enough if no formal QA gate was requested;
- behavioral/regression-risk change -> Codex QA preferred;
- security-sensitive change -> Codex QA + Security;
- protocol/state/concurrency/architecture change -> Codex QA + Architecture;
- release-critical/high-risk change -> Codex QA + Security + Architecture;
- after fixing Codex findings -> Codex Verification on the relevant finding IDs/thread when available.

The orchestrator may increase review depth based on evidence. It must not silently reduce a required gate.

### 9.1 Role/model routing matrix

`.claude/ai-routing.json` is the machine-readable source of truth for which model each role runs on,
which roles and gates each risk level (`LOW`/`MEDIUM`/`HIGH`/`CRITICAL`) requires, which fallback
reasons are permitted, and the write boundary of each role. It encodes this policy; it
does not extend it. Where the matrix and this file could be read as disagreeing, this file wins, and
the matrix is the defect to fix.

The orchestrator resolves role and model from the matrix instead of asking the owner to pick a model
per task. The `PreToolUse` hook `.claude/hooks/validate-agent-routing.ps1` runs on the delegation
tool (`Agent`, historically `Task`), on `Write`/`Edit`/`NotebookEdit`, and on Codex calls, and
enforces a narrow closed list — model mismatch, a Claude agent briefed as a formal Codex gate, `claude-qa-fallback` without
one of the three permitted reasons, `documentation` scoped outside its write boundary, and a
delegated agent's actual `Write`/`Edit`/`NotebookEdit` outside its write boundary — and logs every
other decision. The acting role for a write comes from the hook payload's `agent_type`; the main
session has no `agent_type` and is not write-gated, because the system constrains delegated
executors, not the owner of the process. `Bash` is not gated: a shell command cannot be reliably
inspected for what it would write, so the boundary is kept by withholding `Bash` from write-bounded
roles rather than by claiming hook coverage it does not have. Agents absent from the matrix are never
blocked. When the hook itself cannot decide, gate-critical roles (`reviewer`, `architect`,
`security-reviewer`) fail closed and everything else fails open with a logged hook error.

`architect` and `security-reviewer` are internal Claude roles. They never satisfy the formal Codex
`architecture` or `security` gates, and section 8.2 continues to govern what the Claude fallback may
and may not replace.

The Lead/Orchestrator of section 8 is itself defined as `.claude/agents/lead.md` (role `lead`,
model `inherit` — the owner's selected model). It runs only as the main session
(`claude --agent lead`): the matrix marks it `mainSessionOnly`, and the hook denies any delegation
call with `subagent_type: lead`, so dispatch and A2A routing cannot be nested below the owner's
session or escape the human merge gate.

## 10. Reviewer independence and anti-anchoring

- A formal reviewer must not be the agent that wrote the change.
- Give reviewers the objective, acceptance criteria, base/head, changed scope, and repository policy — not the implementer's conclusions as facts.
- QA, Security, and Architecture first passes should be independent of each other's findings when practical.
- Do not ask a reviewer to "confirm" that the implementation is correct.
- Zero findings is valid; do not invent a defect to make a review look useful.

## 11. HANDOFF contract

Every agent package returns a concise HANDOFF. Use relevant fields; do not fabricate unavailable ones.

```text
HANDOFF
result:          done | partial | blocked | accept | reject
role:            scout | worker | tester | reviewer | qa | security | architecture | verification
review_source:   none | claude-pre-review | codex-qa | codex-security | codex-architecture | codex-verification | claude-qa-fallback
fallback_reason: none | quota | rate-limit | service-unavailable
independence:    normal | degraded
base:            <sha/ref or n/a>
head:            <sha/ref or n/a>
thread_id:       <non-URL id or n/a>
finding_ids:     <ids or none>
changed:         files changed, or none
findings:        [P0|P1|P2|P3] path:line — evidence → recommendation
checks:          command → exit code / key result
acceptance:      each criterion → met / not met + evidence
merge_gate:      blocked | conditional | clear | n/a
risks:           remaining uncertainty / not-run gates
chat_links:      none
next:            one recommended next step
```

Do not include chat URLs in HANDOFF.

## 12. Final acceptance

Before reporting a task complete:

- inspect the real diff;
- run or independently spot-check the required checks;
- confirm scope and repository invariants;
- reconcile formal review findings and merge gate;
- distinguish `NOT RUN` from `PASS`;
- confirm no prohibited chat links were added to authored output;
- report remaining risks explicitly.

## 13. Постійні повноваження автономної роботи

Цей розділ — канонічне джерело постійних повноважень агентів на Git/GitHub-дії в
`ekucher/BRAVO-Toolkit`. Формулювання «лише за явним запитом», «explicitly requested»,
«explicitly authorized», «без явної авторизації» в `AGENTS.md`, `CLAUDE.md`, `.claude/CLAUDE.md`,
`.claude/rules/02-git.md`, `.claude/PROJECT_STATE.md`, `.claude/skills/*/SKILL.md`,
`.claude/agents/*.md` та інших правилах читаються разом із ним:
**явне доручення власником конкретного issue або завдання є авторизацією дій розділу 13.1 у межах
цього завдання**. Дії розділу 13.2 таким дорученням не авторизуються.

Винятки й уточнення:

- skill `/prepare-commit` — окремий ручний workflow «лише підготувати commit»; його виклик сам по
  собі є явним обмеженням завдання (розділ 13.2, останній абзац): commit — лише якщо запит прямо
  його просить, push — ні;
- «не створювати мовчки» commit-и, гілки чи PR (`AGENTS.md`, розділ «Git») означає «не створювати
  без звіту»: кожна така дія за розділом 13.1 фіксується в оновленнях і фінальному звіті.

Мета: власник задає issue та бажаний результат, а агент сам проходить
аналіз → реалізацію → перевірки → рев'ю → локальний гейт (розділ 13.12) → commit → push → PR → CI,
не виходячи за ці межі.

Повноваження належать головній сесії (Lead, розділ 9.1). Делеговані ролі зберігають свої вужчі межі з
`.claude/agents/*.md` і `.claude/ai-routing.json` (наприклад, `reviewer`, `scout`, `architect`
лишаються read-only; `worker` не робить commit/push, якщо бриф не дозволяє цього в `PERMISSIONS`).

### 13.1 Постійні повноваження

Для явно дорученого issue або конкретного завдання за замовчуванням дозволено автономно:

- читати репозиторій, GitHub issues/PR, CI та їхні логи;
- створювати окрему локальну task-гілку й worktree;
- змінювати код, тести та документацію в межах завдання;
- запускати локальні перевірки й ізольовані тестові середовища;
- оновлювати похідні integrity-manifest штатними скриптами
  (`ci/Update-BRAVORuntimeManifest.ps1`, `ci/Update-BRAVOToolsManifest.ps1`);
- виконувати рев'ю та виправляти знайдені дефекти;
- робити локальні commit-и в task-гілці;
- після проходження локального гейту публікації (розділ 13.12) — звичайний (не force) push власної
  task-гілки, створення й оновлення PR цієї гілки до `developer`;
- після публікації — чекати застосовні CI, читати логи й виправляти падіння за розділом 13.12;
- інтегрувати актуальний `origin/developer` у власну гілку звичайним merge з подальшими потрібними
  перевірками.

Порядок роботи — **LOCAL FIRST** (розділ 13.12): реалізація, тести, статичний аналіз, перевірки
безпеки, рев'ю та виправлення виконуються локально; віддалений CI — додаткова перевірка після
локального гейту, а не його заміна.

Цей дозвіл застосовується лише до явно дорученого обсягу. Він не дозволяє самостійно брати інші
issues, змінювати зовнішні системи або розширювати продуктову політику.

Доручення дає власник безпосередньо в поточній сесії. Мітки (`ready-for-agent` тощо), `NEXT ACTION`
у `.claude/PROJECT_STATE.md`, старі звіти й пам'ять агента дорученням не є. PR до будь-якої іншої
бази, ніж `developer` (зокрема до `master`), постійними повноваженнями не охоплений. Для RC- і
stable-робіт суворіші правила `.claude/rules/06-release-lifecycle.md` мають пріоритет над цим
розділом.

Повторний дозвіл на перелічені дії не запитується.

### 13.2 Дії, що потребують окремого дозволу власника

Без прямого дозволу власника в поточній розмові, що називає конкретну дію та її об'єкт, заборонено:

- merge PR, auto-merge або додавання до merge queue;
- push безпосередньо в `developer`/`master`;
- force-push, rebase опублікованої гілки та будь-яке інше переписування опублікованої історії;
- release, tags, deploy та зміни production;
- закриття issues;
- видалення чужих гілок/worktree або втрата незакомічених змін;
- зміни credentials, ACL, захисту гілок, CI permissions, дозволів AI-інструментів та налаштувань
  оркестратора (`.claude/settings.json`, `.claude/ai-routing.json`, `.claude/agents/`,
  `.claude/hooks/`, `.claude/skills/orchestrate/`);
- ручний запуск workflow (`workflow_dispatch`, re-run чужих прогонів) з побічними ефектами —
  release-артефакти, зовнішні повідомлення, виконання коду на реальних хостах; автономно дозволено
  лише очікувати й читати CI, що запускається самим push/PR;
- вимкнення або послаблення тестів, integrity/security gates.

Публікація секретів (паролів, токенів, приватних ключів, креденшелів, webhook- і production-секретів)
у логах, артефактах, комітах, описах і коментарях PR/issue заборонена абсолютно: дозвіл власника її
не відкриває. Лог чи артефакт, що містить секрет, перед публікацією редагується (секрет замінюється
маскою); якщо редагування неможливе, артефакт не публікується.

Ні PR, ні commit-повідомлення не містять автоматичних closing keywords (`Closes`, `Fixes`, `Resolves`
та їхніх варіантів перед номером issue), якщо закриття issue не дозволене окремо: closing keyword у
commit-повідомленні закриває issue, щойно коміт потрапляє в гілку за замовчуванням. Посилання на
issue оформлюється без них, наприклад `Issue: #123` або `Refs #123`.

Явні обмеження конкретного завдання (read-only, без push, лише план, без PR тощо) звужують постійні
повноваження і мають пріоритет над розділом 13.1.

### 13.3 Початок роботи

Перед змінами:

- прочитати застосовні правила (маршрут читання — на початку `AGENTS.md`);
- перевірити GitHub і актуальний SHA цільової гілки (`git fetch origin --prune`);
- прочитати issue з коментарями та пов'язаний код;
- перевірити наявні PR і локальні worktree на дублювання чи перетин файлів;
- перевірити `git status`;
- зафіксувати базовий SHA, scope та критерії приймання.

Старий звіт, `.claude/PROJECT_STATE.md` або пам'ять агента не є доказом поточного стану. Не
реалізовувати повторно те, що вже є в `developer`.

### 13.4 Ізоляція і паралельна робота

- Одна task-гілка та окремий worktree на кожне незалежне завдання.
- Не працювати в чужому dirty worktree.

Якщо доступна делегація:

- до 4 допоміжних read-only агентів одночасно;
- одна mutation lane на worktree;
- рев'юер окремий від автора (розділ 10);
- кілька агентів ніколи не змінюють ті самі файли одночасно (розділ 5);
- жорсткіші обмеження середовища й політик мають пріоритет: ліміти платформи, `mainSessionOnly`
  і межі запису з `.claude/ai-routing.json`, один повний `BRAVO_SELF_TEST.ps1` на машину.

Для конфлікту бізнес-рішень або неоднозначних критеріїв приймання: спочатку дослідити факти,
продовжити незалежні частини, а потім поставити власнику одне конкретне питання у форматі
`.claude/rules/owner-escalation.md`.

### 13.5 Реалізація

Обирати мінімальну достатню дельту. Зберігати контракти й інваріанти, визначені кодом і
документацією. Для BRAVO-Toolkit обов'язкові:

- Windows PowerShell 5.1 (розділ 2);
- Windows Server 2012+ та Windows 10/11;
- transport-neutral Notification;
- українська документація (`.claude/rules/08-documentation-language.md`);
- чинні вимоги BOM, кодування та завершень рядків (`.gitattributes`, `.claude/rules/powershell.md`).

Не додавати сторонній рефакторинг, нові залежності, конфігураційні параметри або зміни політики без
потреби завдання.

Integrity-manifest оновлювати лише штатним генератором після перегляду preview та diff. Не обходити
integrity-gate для запуску тестів.

### 13.6 Перевірки та докази

Перевіряти фактичну поведінку, а не лише текст реалізації. Для виправлення регресії додавати тест,
який виявляє дефект (`.claude/rules/04-testing-validation.md`).

Виконувати застосовні перевірки репозиторію. Windows PowerShell 5.1 (`powershell.exe`) не
підміняти `pwsh`.

Для кожного результату фіксувати:

- команду або штатний спосіб запуску;
- SHA або ідентифікацію перевіреного робочого дерева;
- exit code;
- підсумок;
- шлях до логу.

Exit code дочірнього процесу зберігати одразу після його завершення. Зберігати stdout і stderr або
явно пояснювати, де вони. Читати логи, а не покладатися лише на зелений індикатор.

Статуси розрізняються: `PASS`, `FAIL`, `NOT RUN`, `BLOCKED`, `NOT VERIFIED`. Пропущена частина
перевірки не є повним `PASS`.

Не переносити результати старого SHA на змінений код. Після змін повторювати потрібні перевірки;
повний канонічний прогін — коли цього вимагає політика або зміна зачіпає спільні runtime-контракти.

Оцінки продуктивності не називати вимірюваннями. Fixture-тести не доводять швидкість
production-сховища.

### 13.7 Рев'ю

Цикл: review → fix → re-review. Формальні QA/Security/Architecture gates запускаються, коли їх
вимагають розділи 8–9 і `.claude/ai-routing.json`.

Внутрішнє Claude-рев'ю, зовнішній перегляд diff і формальний Codex gate — різні види доказів; один
не підміняє інший (розділи 8.2, 9.1). Недоступний обов'язковий gate позначається `BLOCKED`; публікація
(включно з draft PR) за такого стану — лише за окремим рішенням власника (розділ 13.12), і навіть тоді
PR не оголошується готовим до merge.

### 13.8 Commit, PR і CI

Перед commit перевіряти diff і staged files. Додавати лише файли завдання — без випадкових логів,
секретів, локальних конфігів та evidence-пакетів. Не використовувати `git add .` без перегляду складу
змін.

Дотримуватися чинної політики commit message: один логічний change на commit, без підписів про
AI-авторство (`.claude/CLAUDE.md`, розділ «Заборона підписів про AI-авторство»; commit-и перевіряє
`Tools/Check-AgentPolicy.ps1`). Та сама заборона діє для описів PR.

PR до `developer` містить:

- проблему й отриману поведінку;
- scope змін;
- докази перевірок із SHA;
- ризики, обмеження та неперевірені критерії;
- посилання на issue без автоматичного закриття (розділ 13.2).

Перед створенням PR шукати наявний PR власної гілки; дублікатів не створювати.

Push і PR — лише після локального гейту публікації (розділ 13.12). Дочекатися застосовних CI на
фінальному head SHA і прочитати логи jobs. Падіння в межах scope виправляти й перевіряти локально, і
лише потім додатковим commit/push; CI повторно перевіряти на новому SHA. Не робити нескінченних
rerun без аналізу причини.

### 13.9 Блокування та дозволи

Не зупинятися на рутинному кроці, який уже дозволений, і не просити власника вручну виконати
доступну дозволену дію.

Автоматичну відмову інструмента не обходити: не змінювати синтаксис або спосіб запуску лише заради
обходу контролю, не вимикати захист.

При блокуванні:

- вказати точну дію й джерело заборони;
- пояснити причину;
- виконати незалежну дозволену роботу;
- надати конкретний спосіб розблокування (формат — `.claude/rules/owner-escalation.md`).

Не просити загальне «дозволь усе». Правила репозиторію не можуть скасувати обмеження платформи.

### 13.10 Завершення і комунікація

Під час тривалої роботи давати короткі змістовні оновлення. Не запитувати «продовжувати?» між
дозволеними етапами.

Нормальне завершення автономного завдання:

- реалізація та потрібні локальні перевірки завершені;
- рев'ю опрацьоване;
- наведені блокери й обмеження;
- merge/deploy не виконані без дозволу.

Якщо завдання створює зміни для публікації і його обмеження дозволяють push та PR, додатково:

- локальний гейт публікації (розділ 13.12) пройдено до першого push;
- task-гілка опублікована;
- PR створений або оновлений;
- CI перевірені на фінальному SHA.

Для завдань read-only, лише план, без push чи без PR (розділ 13.2) ці чотири пункти не
застосовуються, і їх відсутність не робить завдання незавершеним.

Фінальний звіт містить: base/head SHA, результати перевірок (у форматі розділу 13.6), залишкові
ризики та `git status`; для опублікованих змін — також URL PR, коміти й посилання на CI.

Блоки команд для власника: PowerShell починати з `Clear-Host`, Bash — із `clear`.

### 13.11 Зведена таблиця

| Дія | Режим |
|---|---|
| Читання репозиторію, issues/PR, CI і логів | автономно |
| Task-гілка й worktree | автономно |
| Зміни коду, тестів, документації в межах завдання | автономно |
| Локальні перевірки, ізольовані тестові середовища | автономно |
| Регенерація integrity-manifest штатним скриптом | автономно |
| Рев'ю й виправлення знайдених дефектів | автономно |
| Локальні commit-и в task-гілці | автономно |
| Звичайний push власної task-гілки | автономно після локального гейту (13.12) |
| Створення/оновлення PR своєї гілки до `developer` (включно з draft) | автономно після локального гейту (13.12) |
| Очікування CI, читання логів, виправлення падінь (спершу локально) | автономно після локального гейту (13.12) |
| Push, PR чи віддалені workflow до проходження локального гейту | заборонено |
| Публікація при `NOT RUN`/`BLOCKED` обов'язкової локальної перевірки | потрібне рішення власника |
| Merge `origin/developer` у власну гілку | автономно |
| Інший issue, розширення scope чи продуктової політики | потрібен дозвіл |
| Merge PR, auto-merge, merge queue | потрібен дозвіл |
| Push у `developer`/`master` | потрібен дозвіл |
| Force-push, rebase опублікованої гілки, переписування історії | потрібен дозвіл |
| Release, tags, deploy, production | потрібен дозвіл |
| Закриття issues, closing keywords у PR і commit-повідомленнях | потрібен дозвіл |
| Видалення чужих гілок/worktree, втрата незакомічених змін | потрібен дозвіл |
| Credentials, ACL, захист гілок, CI permissions, дозволи AI-інструментів, оркестратор | потрібен дозвіл |
| Вимкнення/послаблення тестів, integrity/security gates | потрібен дозвіл |
| Публікація секретів у логах/артефактах/PR/issue | заборонено завжди (лише після маскування) |

### 13.12 Порядок LOCAL FIRST і локальний гейт публікації

**До публікації.** Реалізація, тести, статичний аналіз, перевірки безпеки, рев'ю та виправлення
виконуються локально в окремому worktree. Читання віддаленого репозиторію, `git fetch`, перегляд
issues/PR і CI-логів дозволені на будь-якому етапі. Локальні commit-и дозволені. Push, створення PR
(draft не є винятком) і запуск віддалених workflow до проходження локального гейту заборонені.

**Локальний гейт.** Гілку публікують лише коли:

- реалізація завершена в погодженому scope;
- обов'язкові локальні тести й статичні перевірки (перелік нижче) пройшли;
- потрібні локальні review gates (розділи 8–9, 13.7) завершені;
- блокувальні знахідки виправлені й повторно перевірені;
- похідні manifest актуальні;
- фінальний diff і staged files перевірені;
- секретів і сторонніх файлів немає;
- докази (розділ 13.6) відповідають фінальному стану коду.

`NOT RUN` або `BLOCKED` обов'язкової локальної перевірки не дозволяє публікацію без окремого
рішення власника. Необов'язкові перевірки та приймання, що потребують production-середовища або
реального сервера, позначаються окремо й не видаються за `PASS`.

**Обов'язкові локальні перевірки BRAVO-Toolkit** (через `powershell.exe`, з робочого дерева
task-гілки):

| Коли | Перевірка |
|---|---|
| завжди | `Tools/Check-AgentPolicy.ps1`; `ci/Test-BRAVOForbiddenPattern.ps1`; `ci/Test-BRAVOReleasePolicy.ps1`; `ci/Update-BRAVOToolsManifest.ps1` і `ci/Update-BRAVORuntimeManifest.ps1` без `-Apply` (manifest актуальні); `BRAVO_RUNTIME_GUARD.ps1`; inline-кроки job `static-checks` у `.github/workflows/ci.yml` — parser, BOM `.ps1`/`.psm1`/`.psd1`, JSON, відсутність BOM у Markdown — виконані локально тим самим кодом (parser покриває й smoke skill `run-bravo-toolkit`); `git diff --check`; `git ls-files --eol` без `w/lf`/`w/mixed` |
| завжди | `ci/Invoke-BRAVOAffectedSelfTest.ps1 -BaseRef origin/developer`; якщо він не підтвердив вибірковий прогін (exit ≠ 0) — повний `BRAVO_SELF_TEST.ps1 -NoPause` |
| зачеплено будь-який `.ps1`/`.psm1`/`.psd1`, `selftest/`, `.github/workflows/` або документ, який перевіряє self-test (`README.md`, `RELEASE_POLICY.md`, `CHANGELOG.md`), чи зміна може вплинути на runtime-контракти | повний `BRAVO_SELF_TEST.ps1 -NoPause` (за його заголовком — єдиний gate мержу; `-Suite` дає лише швидкий зворотний зв'язок; один прогін на машину) |
| зачеплено `.ps1`/`.psm1`/`.psd1` | `ci/Invoke-BRAVOSecurityAnalysis.ps1` (PSScriptAnalyzer тієї ж версії, що в job `psscriptanalyzer`) |
| зачеплено завантаження конфігурації | `BRAVO_CONFIG_TEST.ps1`; `ci/Test-BRAVOConfigFoundationParity.ps1`; `ci/Test-BRAVOConfigV2CutoverGatesOnPullRequest.ps1` (якщо скрипт потребує контексту PR — позначається віддаленим, не `PASS`) |
| зачеплено `.claude/hooks/` або `.claude/ai-routing.json` | `.claude/hooks/tests/Test-AIRouting.ps1` |
| PR до `master` | `ci/Test-BRAVOMasterMergePolicy.ps1 -BaseRef ... -HeadRef ...`; без них скрипт пропускає перевірку, і такий exit 0 не є `PASS` |

Обов'язкова перевірка з FAIL блокує публікацію. FAIL, що відтворюється на базовому SHA з тим самим
ID перевірки й тим самим повідомленням/assertion, фіксується як наявний до зміни з доказами обох
прогонів, але публікація з ним — лише за окремим рішенням власника, як для `NOT RUN`/`BLOCKED`, і в PR
він указується як не-`PASS`. Jobs, які виконуються лише в CI (матричний E2E DataRestore, secret scan
gitleaks тощо), позначаються як віддалені й не замінюються локальним `PASS`.

**Перевірка бази перед публікацією.** Виконати `git fetch origin --prune` і перевірити актуальність
`origin/developer`. Якщо інтеграція бази змінила код, до першого push повторити потрібні перевірки й
рев'ю.

**Публікація.** Після успішного локального гейту автономно: фінальний commit (рівно перевірене дерево,
без нових змін), звичайний push власної task-гілки, створення або оновлення PR, очікування віддалених
CI на фінальному head SHA, читання логів і звіт про результат. Гейт діє для **кожного** push, зокрема
після правок за рев'ю, а не лише для першого.

**Виправлення після CI.** Якщо CI виявив дефект: дослідити логи, виправити й перевірити локально,
повторити застосовні локальні перевірки, лише потім додатковий commit/push і перевірка CI на новому
SHA. Віддалений CI не використовується як цикл пробних push для неперевіреного локально коду.

Merge, release і deploy — лише за окремим дозволом (розділ 13.2).
