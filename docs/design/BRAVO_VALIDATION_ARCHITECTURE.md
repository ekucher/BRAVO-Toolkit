# Архітектура валідації BRAVO-Toolkit

Статус: запропонований дизайн і план реалізації  
Область: репозиторна валідація, модель виконання Self-Test, перевірка встановлення, CI та межі acceptance  
Базова лінія цього дизайну: `developer` @ `5de8173d5a75d008278be8c2693cbfb242337251`

## 1. Призначення

BRAVO-Toolkit виріс із набору скриптів у повноцінний операційний toolkit із кількома entrypoint-скриптами, конфігурацією, контролем цілісності, maintenance, archive, restore, deployment та acceptance-процесами.

Валідація повинна вирішувати різні задачі без змішування їхніх trust/safety boundaries:

1. швидкий зворотний зв'язок під час розробки вузької зміни;
2. регресійна перевірка всіх обов'язкових repository self-tests;
3. спеціалізовані integration та acceptance перевірки;
4. production-safe перевірка після встановлення;
5. постійний operational health та maintenance.

Це різні рівні валідації. Повний Self-Test не є правильним інструментом для кожного рівня.

Цільова модель:

```text
Розробка
    Targeted
       |
    Affected
       |
       v
Repository acceptance
    Full Self-Test
       |
       v
Specialized integration / CI
       |
       v
DEV-LIMS / release acceptance за потреби

Встановлення
       |
       v
Post-Install Verify
       |
    READY / BLOCKED
       |
       v
Нормальна експлуатація
       |
       v
Health / Maintenance
```

## 2. Поточний підтверджений контракт

Наведені нижче правила вже є контрактами проєкту й не можуть бути послаблені цим дизайном.

### 2.1 Канонічний Full Self-Test

Канонічний повний repository self-test:

```powershell
.\BRAVO_SELF_TEST.ps1 -NoPause
```

Ця команда повинна й надалі працювати без змін і залишатися стандартним Full-прогоном.

Рефакторинг не повинен:

- видаляти, пропускати, обходити або послаблювати обов'язкові перевірки;
- перетворювати FAIL на WARN лише заради green validation;
- приховано виключати suite з Full-прогону;
- мігрувати Self-Test framework на Pester;
- використовувати in-process runspaces, `-Parallel` або background jobs для прискорення Self-Test;
- використовувати PowerShell 7 як заміну evidence на підтримуваному Windows PowerShell 5.1.

### 2.2 Runtime та ізоляція тестів

BRAVO product/tests валідуються у Windows PowerShell 5.1.

Tests і fixtures не повинні читати або змінювати реальний production state BRAVO як частину тестового setup чи mutation.

Production VersionState:

```text
C:\ProgramData\BRAVO\State\BRAVO_VERSION_STATE.json
```

не може використовуватися як test state. Тести повинні працювати із sandbox-local state.

`BRAVO_ALLOW_DOWNGRADE=1` не є допустимим workaround для валідації.

### 2.3 Наявні рівні валідації

У репозиторії вже є:

- root `BRAVO_SELF_TEST.ps1`;
- тематичні скрипти у `selftest/`;
- спеціалізовані test entrypoints, зокрема для configuration і data restore;
- стандартна GitHub Actions validation;
- DEV-LIMS workflow для Full Self-Test acceptance.

Спеціалізовані перевірки не стають автоматично частиною Self-Test harness і не повинні об'єднуватися з ним лише заради консолідації.

## 3. Архітектурне рішення

BRAVO використовуватиме три рівні виконання repository self-test:

```text
Targeted -> Affected -> Full
```

### Targeted

Запускає явно вибрані тематичні suite, пов'язані з кодом, що змінюється.

Призначення:

- найкоротший developer feedback loop;
- повторний запуск під час реалізації;
- діагностика конкретної області.

Успішний Targeted не є release або merge acceptance evidence.

### Affected

Запускає всі suite, відомі як залежні від зміненого компонента, включно з declared dependent suites.

Призначення:

- виявлення cross-component regressions до дорогого Full gate;
- deterministic validation на основі explicit dependency map;
- відмова від постійного вручну підтримуваного набору `Fast`, який може втратити актуальність.

Успішний Affected не замінює Full acceptance.

### Full

Запускає всі обов'язкові Self-Test suites/checks канонічного Full contract.

Призначення:

- regression gate для завершеної логічної зміни;
- PR/release acceptance evidence, коли це вимагається;
- валідація змін самого Self-Test harness;
- повторна валідація після суттєвих integration/base змін, якщо попереднє evidence стало неактуальним.

Full не потрібен після кожного редагування коду.

## 4. Коли потрібен Full

Full слід використовувати як контрольний gate, а не як внутрішній цикл кожної зміни.

Full обов'язковий щонайменше коли:

- логічний пакет реалізації готовий до acceptance;
- змінюються Self-Test harness, suite discovery, aggregation, counters, logging або exit-code behavior;
- змінюється широкий/shared component і dependency model не дозволяє безпечно обмежити affected set;
- acceptance policy PR/release прямо вимагає Full;
- суттєва integration/base зміна робить попереднє Full evidence неактуальним;
- DEV-LIMS або release acceptance прямо вимагає канонічну Full-команду.

Нормальний development loop:

```text
edit
  |
Targeted
  |
edit/fix
  |
Affected
  |
завершена логічна зміна
  |
Full
```

## 5. Класифікація змін та вимоги до валідації

Вимога запуску Full Self-Test визначається не самим фактом наявності PR і не розширенням зміненого файла, а впливом зміни на executable/runtime behavior, validation contract, packaging, configuration, integrity та release behavior.

Для планування валідації зміни класифікуються за найвищим застосовним класом ризику:

| Клас | Характер зміни | Мінімальна вимога |
| --- | --- | --- |
| V0 — Non-runtime | зміна не може вплинути на executable/runtime behavior або validation contract | релевантні documentation/governance/static checks; Full Self-Test не потрібен |
| V1 — Static / governance | зміна стосується repository mechanics або доказово non-semantic content | релевантні static/governance checks; Full визначається фактичним впливом |
| V2 — Behavioral scoped | production/test behavior змінюється у відомій області з визначеним ownership | Targeted -> Affected -> Full перед acceptance |
| V3 — Critical / broad | security, integrity, trust boundary, shared behavior, harness, packaging/release-critical або невідомий широкий вплив | Full + усі релевантні specialized gates + відповідний independent review |

### 5.1 V0 — зміни, для яких Full Self-Test не потрібен

До V0 належить documentation-only change, якщо весь diff складається лише з документації й документація не є executable/generated input для runtime, packaging, CI або release process.

Типові приклади:

- Markdown-документація під `docs/`;
- `README.md`, операторські інструкції та design-документи;
- текстові виправлення документації;
- PR/Issue metadata, якщо вони не змінюють repository tree;
- інші суто документальні зміни, для яких механічно підтверджено відсутність runtime/validation впливу.

Для V0:

```text
BRAVO_SELF_TEST.ps1:
NOT RUN — validation class V0; Full Self-Test not required
```

Це не `PASS` і не доказ проходження Self-Test. Це явне твердження, що Full не запускався, оскільки за класифікацією зміни він не є необхідним gate.

V0 не скасовує релевантні repository checks, наприклад перевірку Markdown encoding, secret scanning або інші governance checks, якщо вони застосовні.

### 5.2 V1 — static / governance changes

V1 охоплює зміни, які не повинні змінювати product runtime behavior, але можуть впливати на repository mechanics або потребують спеціальної статичної перевірки.

Потенційні приклади, які потребують підтвердження фактичного diff:

- доказово non-semantic formatting/comment-only зміни у коді;
- repository metadata;
- окремі governance rules;
- допоміжні metadata-файли, що не входять до runtime/release/validation contract.

V1 не означає автоматичне звільнення від Full. Якщо зміна governance або metadata впливає на validation, build, packaging, release чи runtime contract, вона переходить до V2 або V3.

### 5.3 V2 — behavioral scoped changes

До V2 належать зміни production або test behavior з відомим domain ownership та достатньо визначеною dependency model.

Нормальна послідовність:

```text
Targeted
   |
Affected
   |
Full перед acceptance
```

Успішні Targeted/Affected дають швидкий feedback, але не замінюють Full acceptance.

### 5.4 V3 — critical / broad changes

До V3 належать щонайменше зміни, що зачіпають:

- security/integrity behavior;
- pre-trust runtime guard boundary;
- credentials або authorization;
- Self-Test harness, discovery, aggregation, counters, logging чи exit-code contract;
- shared behavior із невизначеним або широким dependency graph;
- packaging/deployment/update behavior, коли воно впливає на runtime candidate;
- release-critical generated artifacts;
- зміни, для яких неможливо надійно визначити affected validation set.

V3 вимагає Full та всіх релевантних specialized gates. Глибина independent review визначається repository review policy.

### 5.5 Файли, які не можна автоматично вважати V0/V1

Класифікація не повинна ґрунтуватися лише на extension або назві каталогу.

Зокрема, такі області не отримують автоматичного Self-Test exemption:

- `VERSION.json`;
- `RUNTIME_MANIFEST.json`;
- `.github/workflows/**`;
- `ci/**`;
- `selftest/**`;
- production `*.ps1`, `*.psm1`, `*.psd1`;
- configuration/schema/defaults;
- packaging/deploy/update scripts;
- generated artifacts або їхні canonical inputs;
- приклади конфігурації, якщо вони є machine-consumed input або частиною acceptance/release contract.

Для них клас визначається фактичним впливом.

### 5.6 Fail-safe правило класифікації

Застосовується найвищий клас серед усіх змінених artifacts.

```text
тільки V0          -> V0
V0 + V1            -> V1
V0 + behavioral    -> V2/V3
unknown impact     -> V3 або Full як conservative fallback
```

Якщо неможливо механічно або evidence-based підтвердити, що зміна non-behavioral, Self-Test exemption не застосовується.

Жоден агент не повинен знижувати клас лише для скорочення часу CI або отримання green status.

### 5.7 CI semantics для not-required checks

Required-capable workflow не слід вимикати workflow-level `paths:` лише для optimization, якщо це може призвести до відсутності required status check.

Цільова CI-модель повинна відокремлювати:

1. створення/наявність required check status;
2. relevance decision;
3. фактичний запуск дорогого test harness.

Для V0/V1 job може завершитися успішним статусом `N/A / not required`, якщо repository protection потребує check result, але це не можна звітувати як `BRAVO_SELF_TEST.ps1 PASS`.

Поточний CI може продовжувати запускати Full на всіх PR до окремої, reviewed behavioral зміни workflow. Цей design сам по собі не авторизує зміну `ci.yml`.

### 5.8 Початкова Validation Requirement Matrix

| Тип зміни | Targeted | Affected | Full Self-Test | Додаткова валідація |
| --- | --- | --- | --- | --- |
| Documentation-only, V0 | не потрібен | не потрібен | NOT REQUIRED | docs/governance/static checks |
| PR/Issue metadata без repository diff | не потрібен | не потрібен | NOT REQUIRED | за потреби |
| Доказово non-semantic code change | зазвичай не потрібен | зазвичай не потрібен | визначається evidence; не автоматично | parser/static checks |
| Repository/governance metadata | за потреби | за потреби | залежить від впливу | governance checks |
| CI/workflow | релевантні | релевантні | залежить від впливу; validation-contract change може вимагати Full | workflow/governance checks |
| Test-only | змінений test | affected tests | REQUIRED, якщо змінюється Full contract/harness/coverage; інакше за risk classification | відповідний test contract |
| Self-Test harness/discovery/aggregation | не є достатнім | не є достатнім | REQUIRED | governance/characterization |
| Production PowerShell | REQUIRED | REQUIRED | REQUIRED перед acceptance | domain-specific gates |
| Configuration/schema/defaults | REQUIRED | REQUIRED | REQUIRED | Config parity та інші config gates |
| Runtime integrity/manifest | REQUIRED | REQUIRED | REQUIRED | integrity/release gates |
| Packaging/deploy/update | REQUIRED | REQUIRED | REQUIRED, якщо змінюється runtime candidate/behavior | artifact/deployment gates |
| Security/trust/credentials | REQUIRED | REQUIRED | REQUIRED | security validation/review |
| Release/version metadata | за потреби | за потреби | згідно release policy та фактичного runtime impact | release gates |
| Generated runtime artifact/input | REQUIRED | REQUIRED | REQUIRED | generation/idempotency/integrity |
| Mixed або unknown scope | conservative | conservative | REQUIRED | усі релевантні specialized gates |

Матриця є design baseline. VAL-01/VAL-02 повинні підтвердити або уточнити категорії на основі фактичного ownership та поточного Self-Test contract.

## 5. Цільова архітектура Self-Test

```text
BRAVO_SELF_TEST.ps1
        |
        | канонічний thin entrypoint
        v
+-----------------------------+
|       Self-Test Harness     |
| parameter handling          |
| suite selection/discovery   |
| sandbox lifecycle           |
| execution                   |
| result aggregation          |
| counters                    |
| logging                     |
| final exit code             |
+--------------+--------------+
               |
               v
       selftest/*.ps1
       тематичні suites
```

Root script залишається стабільним entrypoint для operator/CI. Значна reusable harness logic повинна мати одного canonical owner, а не дублюватися між root і suites.

Це цільова архітектура, а не твердження, що поточний root script уже відповідає цій структурі.

## 6. Модель залежностей suites

Affected execution потребує явної карти production ownership → validation ownership.

```text
змінений компонент
      |
      +--> suite прямого власника
      |
      +--> dependent suites
      |
      +--> shared-contract suites
```

Приклади категорій, які мають бути підтверджені VAL-01:

- зміни configuration loader можуть вимагати configuration, config intent і configurator validation;
- зміни archive можуть вимагати archive, disk-space, backup-scope і trace/archive validation;
- зміни maintenance можуть вимагати maintenance-specific suites;
- зміни shared harness завжди вимагають Full;
- зміни з невідомим dependency coverage вимагають Full.

Карта повинна зберігатися в репозиторії, бути reviewable та deterministic. За неоднозначного ownership вона повинна обирати ширшу валідацію.

Не створювати статичний список `Fast` як заміну dependency ownership.

## 7. Post-Install Verification

Installation verification — окрема production-задача.

`BRAVO_SELF_TEST.ps1` відповідає на питання:

> Чи відповідає код BRAVO repository test contract?

Post-Install Verify відповідає на питання:

> Чи є конкретне встановлення BRAVO повним, внутрішньо узгодженим і готовим до нормальної експлуатації?

Тому перша production installation не повинна вимагати development Full Self-Test harness лише для підтвердження успішного встановлення.

### 7.1 Цільові області перевірки

Остаточний набір checks має бути підтверджений Installer architecture і фактичним runtime ownership. Очікувані області:

- наявність встановленого runtime та очікуваної структури;
- runtime manifest/integrity verification;
- збереження pre-trust runtime-guard boundary;
- завантаження configuration і required settings;
- коректна робота site/local configuration;
- доступність required paths та permissions;
- наявність required credentials без розкриття secret values;
- required dependencies;
- scheduled tasks, вибрані під час installation, якщо застосовно;
- готовність logging/state paths;
- production-safe entrypoint/runtime smoke checks.

### 7.2 Safety contract

Post-Install Verify повинен:

- бути безпечним для production host;
- не виконувати synthetic mutations production data;
- не використовувати production state як test fixture;
- fail closed для integrity/security conditions, де цього вимагає runtime policy;
- надавати actionable diagnostics;
- ніколи не виводити secrets;
- повертати meaningful process exit code;
- відрізняти installation readiness від warnings, які не блокують operation.

Цільовий результат:

```text
Installation
     |
Post-Install Verify
     |
 +---+---+
 |       |
READY  BLOCKED
```

Точна назва script/module навмисно не фіксується до визначення implementation ownership.

## 8. Межі валідації

| Рівень | Питання | Типове середовище |
| --- | --- | --- |
| Targeted | Чи працює вузька змінена область? | development |
| Affected | Чи працює відома залежна поведінка? | development / pre-review |
| Full Self-Test | Чи проходить повний repository Self-Test contract? | development / CI / acceptance |
| Specialized tests | Чи проходить спеціалізований integration contract? | CI / acceptance |
| DEV-LIMS acceptance | Чи проходить exact candidate необхідний real-host acceptance? | controlled acceptance host |
| Post-Install Verify | Чи має конкретна installation статус READY? | installed host |
| Health / Maintenance | Чи є встановлена система здоровою під час operation? | operational host |

Проходження одного рівня не можна подавати як evidence проходження іншого, якщо той фактично не запускався.

## 9. Залежність від Installer

Installer не повинен блокуватися до завершення повного Self-Test refactor.

```text
Self-Test inventory
       |
Characterization baseline
       |
Validation architecture
       |
Post-Install Verify contract
       |
       +-------------------+
       |                   |
       v                   v
Self-Test evolution    Installer MVP
       |                   |
       +---------+---------+
                 |
        Verify integration
```

До того, як Installer почне залежати від validation contract, потрібні:

1. inventory поточного Self-Test;
2. characterization канонічного Full behavior;
3. погоджена Validation Architecture;
4. погоджений Post-Install Verify contract.

Глибокий cleanup Self-Test harness може продовжуватися окремо після створення цих foundations.

## 10. План реалізації

### VAL-01 — Інвентаризація Self-Test

Read-only inventory:

- responsibilities root Self-Test;
- thematic suites;
- suite/check ownership;
- global/script state;
- fixtures;
- temp/sandbox usage;
- production-path access risks;
- duplicated harness behavior;
- ordering dependencies;
- logging, counters та exit behavior;
- CI і DEV-LIMS consumers.

Результат: ownership/dependency inventory.

Оцінка: 3–5 годин.

### VAL-02 — Characterization baseline Full

Зафіксувати externally observable canonical Full contract до structural refactoring:

- command-line behavior;
- mandatory suite/check execution;
- behaviorally relevant ordering dependencies;
- PASS/FAIL aggregation;
- counters;
- logs;
- process exit behavior;
- relevant failure modes.

Послаблення checks заборонене.

Оцінка: 4–8 годин.

### VAL-03 — Специфікація Validation Architecture

Переглянути й оновити цей документ на основі evidence VAL-01/VAL-02. Усунути припущення початкового дизайну.

Оцінка: 3–5 годин.

### VAL-04 — Targeted Suite Execution

Реалізувати підтримуваний запуск вибраних thematic suites зі збереженням існуючого Full default без змін.

Вимоги:

- Windows PowerShell 5.1;
- deterministic selection;
- invalid suite selection завершується зрозумілою помилкою;
- Full command незмінна;
- без silent skip behavior;
- existing logs/result semantics зберігаються, де застосовно.

Оцінка: 4–8 годин.

### VAL-05 — Affected Suite Mapping

Додати repository-owned dependency mapping:

- component-to-suite ownership;
- dependent-suite relationships;
- conservative fallback до Full для unknown/shared changes;
- characterization tests для mapping behavior;
- без generic `Fast` bucket.

Оцінка: 6–10 годин.

### VAL-06 — Контракт Post-Install Verification

Перетворити розділ 7 на implementation-ready contract на основі Installer architecture і actual runtime ownership.

Визначити:

- mandatory checks;
- READY/BLOCKED semantics;
- warning semantics;
- exit codes;
- diagnostics;
- integrity/trust ordering;
- safe operations;
- forbidden production mutations.

Оцінка: 4–6 годин.

### INS-01 — Технічна архітектура Installer

Визначити Installer phases та integration points для Post-Install Verify.

Це задача Installer track, залежна від VAL-06.

Оцінка: 4–8 годин.

### INS-02 — Installer MVP

Реалізувати окремо погоджений Installer MVP відповідно до його design.

Оцінка: 1–2 робочі дні.

### VAL-07 — Post-Install Verifier

Реалізувати production-safe verifier за контрактом VAL-06.

Оцінка: 1–2 робочі дні.

### INS-03 — Інтеграція verification в Installer

Підключити завершення Installer до Post-Install Verify і показувати actionable READY/BLOCKED diagnostics.

Оцінка: 4–8 годин.

### VAL-08 — Межа Self-Test Harness

Зменшити responsibilities root Self-Test до orchestration та встановити canonical ownership reusable harness behavior.

Це structural work і потребує characterization-first validation.

Оцінка: 1–2 робочі дні.

### VAL-09 — Нормалізація та ізоляція suites

Нормалізувати suite lifecycle та усунути unsafe/duplicated fixture/sandbox patterns без зміни test intent.

Окремо перевірити відсутність production-state fixture contamination.

Оцінка: 1–2 робочі дні.

### VAL-10 — CI Validation Model

Використовувати Targeted/Affected execution для швидшого feedback там, де це корисно, з обов'язковим збереженням Full coverage на acceptance gates.

Будь-який CI parallelism має використовувати окремі supported processes/jobs. Заборонений in-process Self-Test parallelism не вводити.

Оцінка: 4–8 годин.

### ACC-01 — Full Regression

Виконати required Windows PowerShell 5.1 Full та specialized validation на exact candidate.

Evidence має містити фактичну команду, exit code та key result.

Оцінка: приблизно 0,5 робочого дня.

### ACC-02 — Незалежне рев'ю

Fresh reviewer перевіряє behavioral/architectural change за P0–P3 та звичайною merge-gate policy.

Оцінка: 2–4 години.

### ACC-03 — DEV-LIMS Acceptance

Коли це потрібно і operational gates дозволяють, виконати exact-SHA canonical Full acceptance у контрольованому DEV-LIMS environment.

Завершення попередніх задач саме по собі не авторизує цю дію.

Оцінка: 2–4 години без урахування environment blockers.

## 11. Хвилі реалізації

### Wave 1 — Foundation

```text
VAL-01 -> VAL-02 -> VAL-03
```

Broad implementation refactor не повинен передувати цій baseline.

Орієнтир: 1–2 робочі дні.

### Wave 2 — Швидкий feedback та installation contract

```text
VAL-04 -> VAL-05

VAL-06 -> INS-01
```

Tracks можуть виконуватися незалежно після виконання dependencies, з дотриманням правила про один mutation lane для overlapping files/artifacts.

### Wave 3 — Installer MVP та verifier

```text
VAL-07 ----+
           +--> INS-03
INS-02 ----+
```

Орієнтир: 2–4 робочі дні залежно від scope Installer.

### Wave 4 — Завершення Harness

```text
VAL-08 -> VAL-09 -> VAL-10
                    |
                    v
                  ACC-01
                    |
                  ACC-02
                    |
                  ACC-03 за потреби
```

## 12. Загальна оцінка

Початкова planning estimate:

- foundation перед серйозною реалізацією Installer: 1–2 робочі дні;
- Installer MVP + Post-Install Verify: приблизно ще 2–4 робочі дні;
- повна Validation Architecture, cleanup, CI integration та review: приблизно 6–10 робочих днів загалом.

Це planning estimates, а не commitments. Після VAL-01/VAL-02 їх потрібно замінити evidence-based оцінкою з урахуванням фактичного coupling та harness ownership.

## 13. Що не входить у цю архітектуру

Цей дизайн не дозволяє і не вимагає:

- скорочувати Full Self-Test coverage;
- замінювати Windows PowerShell 5.1 на PowerShell 7;
- мігрувати на Pester;
- послаблювати integrity/security gates;
- виконувати Full Self-Test на кожній production installation;
- вважати Post-Install Verify release acceptance;
- вважати Health/Maintenance repository testing;
- об'єднувати всі specialized tests в один script;
- дозволяти parallel writers змінювати ті самі test/harness artifacts;
- виконувати deployment, release або merge.

## 14. Acceptance invariants

Реалізація прийнятна лише якщо всі застосовні invariants залишаються істинними:

1. `.\BRAVO_SELF_TEST.ps1 -NoPause` залишається канонічним незмінним Full entrypoint.
2. Full охоплює всі mandatory checks, які він охоплював до зміни.
3. Targeted/Affected є додатковими developer feedback mechanisms, а не слабшими acceptance substitutes.
4. Unknown dependency ownership переходить до ширшої validation, аж до Full.
5. Windows PowerShell 5.1 залишається supported validation runtime.
6. Test fixtures/state ізольовані від real BRAVO production state.
7. Runtime integrity і pre-trust guard boundary не послаблюються.
8. Post-Install Verify production-safe та відокремлений від repository Self-Test.
9. Evidence звітується лише для commands/checks, які фактично виконувалися.
10. Behavioral/high-risk changes проходять fresh independent review перед acceptance.

## 15. Наступна дія

Наступна implementation action — не Self-Test refactor.

Спочатку виконати VAL-01 і VAL-02 як read-only evidence-gathering wave. Їхні результати використати для уточнення цього design до того, як VAL-04 або VAL-08 змінюватимуть test behavior чи structure.

Такий порядок зберігає поточний Full contract і створює безпечний шлях до швидшої development validation та зручного для людини Installer.
