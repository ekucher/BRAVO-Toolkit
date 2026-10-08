# ADP Phase 1 — контракт авторизації та оркестрації

**Статус:** PROPOSED / implementation gates NOT RUN  
**Дата:** 2026-10-08  
**Режим:** PR_ONLY  
**Підстава:** погоджені власником рішення К1–К7 від 2026-10-08 і Phase 0 gap analysis.  
**База підготовки:** `developer` @ `7cc1e136e9c0ae8e74fef1b950cf6af5875078ad`.

> Цей документ не замінює `BRAVO_AGENT_POLICY.md`, `AGENTS.md`, `.claude/CLAUDE.md`, tracked `.claude/rules/*.md` чи `docs/design/BRAVO_VALIDATION_ARCHITECTURE.md`. До прийняття змін у canonical policies їхні поточні обмеження діють без винятків.

## 1. Межі Phase 1

Phase 1 розширює наявний brief у `.claude/skills/orchestrate/SKILL.md` та canonical HANDOFF, не створюючи другого формату. Пакети: ADP-101 (моделі), ADP-102 (authorization envelope), ADP-103 (mutation/read-only slots), ADP-104 (lifecycle/HANDOFF), ADP-105 (проєкт спеціалізованого fallback), ADP-106 (policy checker).

Поточний документ фіксує контракт для реалізації. Він **не** засвідчує, що runtime enforcement, модельні alias, Windows checks чи незалежний review уже виконані.

## 2. Authorization envelope (розширення PERMISSIONS)

Для кожного mutation package Lead повинен мати підтверджений дозвіл власника:

| Поле | Семантика |
|---|---|
| `task_id` | Стабільний ідентифікатор пакета |
| `source_issue_or_pr` | GitHub Issue/PR або `none` |
| `base_branch`, `base_sha` | Live-verified база |
| `allowed_paths` | Явний перелік файлів/каталогів для запису |
| `allowed_operations` | Окремо `edit`, `commit`, `push`, `create_pr`, `update_pr`, `issue_write` |
| `expires_at_or_condition` | Строк або умова завершення дозволу |
| `owner_approval_reference` | Non-URL ідентифікатор рішення власника або стислий опис дозволу |
| `mutation_lane_owner` | Один writer, який утримує lane |

**Fail closed:** відсутнє поле або неоднозначний дозвіл означає відсутність відповідного права. `PR_ONLY` — верхня межа workflow, а не автоматичний дозвіл на git mutation. Будь-який вихід за `allowed_paths` чи `allowed_operations` → STOP / NEEDS_OWNER_DECISION. Зміни в `developer` напряму, merge, release, deploy, force-push і destructive cleanup не входять до Phase 1.

## 3. Concurrency та ізоляція

- Не більше **4 одночасних Claude read-only агентів**. Claude reviewer займає один Claude read-only slot.
- Codex не займає Claude slot, але **всі** Claude/Codex reviewers разом займають не більше **3 одночасних reviewer slots**.
- **Один mutation lane** на весь workflow; два writers ніколи не редагують той самий файл, manifest, schema чи shared artifact паралельно.
- Reviewer має бути fresh, не автором зміни, без прав на mutation.
- Текстова заборона Bash mutations у `scout`/`reviewer` не є технічним sandbox. До впровадження enforceable read-only доступу ці ролі вважаються **policy-only / not technically enforced**.
- Спроба п'ятого Claude read-only, четвертого reviewer або другого writer повинна блокуватися механічно в реалізації scheduler, а не лише інструкцією.

## 4. Lifecycle (розширення HANDOFF)

`DISCOVERED → TRIAGED → SCOPED → AUTHORIZED → IMPLEMENTING → TARGETED_VALIDATION → AFFECTED_VALIDATION → INDEPENDENT_REVIEW → PUBLISHED_PR → CI_VALIDATION → READY_FOR_OWNER`.

Додаткові стани: `BLOCKED`, `NEEDS_OWNER_DECISION`, `ENVIRONMENT_BLOCKED`, `REVIEW_REWORK`, `CI_REWORK`, `SUPERSEDED`, `ALREADY_FIXED`, `NOT_REPRODUCIBLE`.

Поля для подальшого доповнення canonical HANDOFF: `task_id`, `state`, `head_sha`, `ci_run_id`, `ci_tested_sha`, `merge_recommendation`, `authorization`. Поточні `result`, `review_source`, `fallback_reason`, `independence`, `merge_gate` зберігають canonical enum і значення. `READY_FOR_OWNER` не означає merge authorization.

Новий candidate head SHA інвалідовує SHA-залежне acceptance evidence. Зсув `developer` вимагає оцінки base drift та повтору зачеплених gates. `NOT RUN` не є `PASS`.

## 5. Моделі та review

Погоджена маршрутизація: **Opus 5.5** для Lead/Worker/Tester/Claude Reviewer, **Haiku 4.5** для Scout, **Codex** для незалежного formal QA/Security/Architecture/Verification. Sonnet і Fable не входять до стандартного ADP.

**Блокер ADP-101:** перед зміною `model:` у frontmatter перевірити підтримувані точні model IDs/aliases у встановленому Claude Code. Не вводити непідтверджений alias.

Для behavioral/high-risk змін застосовувати `BRAVO_AGENT_POLICY.md` §8–§10. Погодження К5 дозволяє **проєктувати** тимчасовий спеціалізований Claude fallback, але не активує його. До окремого owner-approved policy amendment спеціалізовані Codex Security/Architecture/Verification gates при недоступності Codex залишаються BLOCKED. Claude QA fallback діє лише за чинними трьома причинами та з `independence: degraded`.

## 6. Validation та publication

Validation V0–V3 визначається **лише** `docs/design/BRAVO_VALIDATION_ARCHITECTURE.md`. Не послаблювати Full або self-tests. Windows CI Full може бути acceptance evidence тільки після ACC-01: відповідний tested SHA/tree, exit 0, `SELF-TEST PASSED`, нуль `[НЕДОСТУПНО]`, усі required checks. Windows PowerShell 5.1 обов'язковий; `pwsh` не замінює `powershell.exe`. Manifest generation — canonical scripts у Windows lane.

Перед зовнішньою публікацією перевіряти заборону chat/session URLs, заборонену AI-атрибуцію та захист реальних ідентифікаторів згідно з canonical policies. Гілки `fix/`, `feature/`, `docs/`, `security/`; якщо harness нав'язує іншу — лише після перевірки її унікальності. Одна задача ↔ одна гілка ↔ один PR. `hotfix`/`master` поза ADP v1.

## 7. Acceptance для реалізації Phase 1

- ADP-101: model aliases реально підтримуються; стандартний routing без Sonnet/Fable.
- ADP-102: негативний сценарій без `edit`/`commit`/`push` відхиляється до дії; scope expansion → STOP.
- ADP-103: 5-й Claude read-only, 4-й reviewer, 2-й writer відхиляються; read-only технічно enforced.
- ADP-104: переходи lifecycle й нові поля HANDOFF перевіряються без порушення canonical enum.
- ADP-105: спеціалізований fallback задокументований як **draft, not authorized for use**, до окремого рішення власника.
- ADP-106: policy checker і негативні fixtures перевірені на Windows PowerShell 5.1.

**Стан цієї зміни:** contract documentation only; implementation, tests, CI, review — NOT RUN. Жодних дозволів на merge/deploy цей документ не надає.
