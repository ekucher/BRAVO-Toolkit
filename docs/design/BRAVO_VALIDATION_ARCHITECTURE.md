# Архітектура валідації BRAVO-Toolkit

Статус: запропонований дизайн і план реалізації  
Область: репозиторна валідація, модель виконання Self-Test, перевірка встановлення, CI та межі acceptance  
Базова лінія цього дизайну: `developer` @ `1cd67b231f23bedf9148f038bdb74367a6c027db` (актуальність тверджень про Self-Test повторно перевіряється у VAL-01 на поточному SHA)

## 1. Призначення

BRAVO-Toolkit виріс із набору скриптів у повноцінний операційний toolkit із кількома entrypoint-скриптами, конфігурацією, контролем цілісності, maintenance, archive, restore, deployment та acceptance-процесами.

Валідація повинна вирішувати різні задачі без змішування їхніх меж довіри та безпеки:

1. швидкий зворотний зв'язок під час розробки вузької зміни;
2. регресійна перевірка всіх обов'язкових self-test репозиторію;
3. спеціалізовані інтеграційні та acceptance-перевірки;
4. безпечна для production перевірка після встановлення;
5. постійний операційний health та maintenance.

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

Канонічний повний self-test репозиторію:

```powershell
.\BRAVO_SELF_TEST.ps1 -NoPause
```

Ця команда повинна й надалі працювати без змін і залишатися стандартним Full-прогоном.

Рефакторинг не повинен:

- видаляти, пропускати, обходити або послаблювати обов'язкові перевірки;
- перетворювати FAIL на WARN лише заради зеленого результату валідації;
- приховано виключати suite з Full-прогону;
- мігрувати Self-Test framework на Pester;
- використовувати in-process runspaces, `-Parallel` або background jobs для прискорення Self-Test;
- використовувати PowerShell 7 як заміну доказів на підтримуваному Windows PowerShell 5.1.

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
- стандартна GitHub Actions validation: `.github/workflows/ci.yml` (Full на кожен PR без `paths:`) і `.github/workflows/config-parity.yml` (required check створюється завжди, рішення про релевантність приймається всередині job);
- DEV-LIMS workflow для Full Self-Test acceptance;
- вибірковий developer-прогін `-Suite` у `BRAVO_SELF_TEST.ps1` (не acceptance; друкує `SELF-TEST PARTIAL` замість `SELF-TEST PASSED`; невідоме ім'я suite завершується помилкою; Full лишається типовим режимом).

Наявні guard-и CI: `Framework/CiWorkflowNeverNarrowsSelfTest` (ci.yml не звужує Self-Test) і `Governance/RequiredChecksListCoversCiWorkflowJobs` (pull_request-job-и ci.yml відповідають переліку required checks у `RELEASE_POLICY.md`).

Спеціалізовані перевірки не стають автоматично частиною Self-Test harness і не повинні об'єднуватися з ним лише заради консолідації.

## 3. Архітектурне рішення

BRAVO використовуватиме три рівні виконання repository self-test:

```text
Targeted -> Affected -> Full
```

### Targeted

Запускає явно вибрані тематичні suite, пов'язані з кодом, що змінюється.

Призначення:

- найкоротший цикл зворотного зв'язку для розробника;
- повторний запуск під час реалізації;
- діагностика конкретної області.

Успішний Targeted не є доказом release- або merge-acceptance.

### Affected

Запускає всі suite, відомі як залежні від зміненого компонента, включно з declared dependent suites.

Призначення:

- виявлення міжкомпонентних регресій до дорогого Full gate;
- детермінована валідація на основі явної карти залежностей;
- відмова від постійного вручну підтримуваного набору `Fast`, який може втратити актуальність.

Успішний Affected не замінює Full acceptance.

### Full

Запускає всі обов'язкові Self-Test suites/checks канонічного Full contract.

Призначення:

- регресійний gate для завершеної логічної зміни;
- докази PR/release acceptance, коли це вимагається;
- валідація змін самого Self-Test harness;
- повторна валідація після суттєвих інтеграційних змін або змін бази, якщо попередні докази стали неактуальними.

Full не потрібен після кожного редагування коду.

## 4. Коли потрібен Full

Full слід використовувати як контрольний gate, а не як внутрішній цикл кожної зміни.

Full обов'язковий щонайменше коли:

- логічний пакет реалізації готовий до acceptance;
- змінюються Self-Test harness, suite discovery, aggregation, counters, logging або exit-code behavior;
- змінюється широкий/shared component і dependency model не дозволяє безпечно обмежити affected set;
- acceptance policy PR/release прямо вимагає Full;
- суттєва інтеграційна зміна або зміна бази робить попередні докази Full неактуальними;
- DEV-LIMS або release acceptance прямо вимагає канонічну Full-команду.

Нормальний цикл розробки:

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

Вимога запуску Full Self-Test визначається не самим фактом наявності PR і не розширенням зміненого файла, а впливом зміни на виконувану/runtime-поведінку, validation contract, packaging, конфігурацію, цілісність та release-поведінку.

Для планування валідації зміни класифікуються за найвищим застосовним класом ризику:

| Клас | Характер зміни | Мінімальна вимога |
| --- | --- | --- |
| V0 — Non-runtime | зміна не може вплинути на executable/runtime behavior або validation contract | релевантні documentation/governance/static checks; Full Self-Test не потрібен |
| V1 — Static / governance | зміна стосується repository mechanics або доказово non-semantic content | релевантні static/governance checks; Full визначається фактичним впливом |
| V2 — Behavioral scoped | production/test behavior змінюється у відомій області з визначеним ownership | Targeted -> Affected -> Full перед acceptance |
| V3 — Critical / broad | security, integrity, trust boundary, shared behavior, harness, packaging/release-critical або невідомий широкий вплив | Full + усі релевантні specialized gates + відповідний independent review |

### 5.1 V0 — зміни, для яких Full Self-Test не потрібен

До V0 належить зміна лише документації, якщо весь diff складається лише з документації й документація не є виконуваним/згенерованим входом для runtime, packaging, CI або release process і не входить у вхідний набір Governance-перевірок.

Типові приклади:

- Markdown під `docs/`, на який не посилаються живі документи;
- design-документи, які не входять у вхідний набір Governance;
- текстові виправлення документації;
- PR/Issue metadata, якщо вони не змінюють repository tree;
- інші суто документальні зміни, для яких механічно підтверджено відсутність runtime/validation впливу.

Не належать до V0 живі документи, які читає Governance: `README.md`, `OPERATIONS.md`, `SECURITY.md`, `RELEASE_CHECKLIST.md`, `RELEASE_POLICY.md`, `THREAT_MODEL.md`, `BRAVO_SETUP.md`, `PROJECT.md`, `deploy/README.md`. Для них потрібен Governance suite (`-Suite Governance`) або Full. Навіть для Markdown під `docs/` перевірка `Documentation/RelativeLinksResolve` виконується над усіма tracked `*.md`.

Для V0:

```text
BRAVO_SELF_TEST.ps1:
NOT RUN — validation class V0; Full Self-Test not required
```

Це не `PASS` і не доказ проходження Self-Test. Це явне твердження, що Full не запускався, оскільки за класифікацією зміни він не є необхідним gate.

V0 не скасовує релевантні перевірки репозиторію, наприклад перевірку кодування Markdown, secret scanning або інші governance-перевірки, якщо вони застосовні.

### 5.2 V1 — static / governance changes

V1 охоплює зміни, які не повинні змінювати runtime-поведінку продукту, але можуть впливати на механіку репозиторію або потребують спеціальної статичної перевірки.

Потенційні приклади, які потребують підтвердження фактичного diff:

- доказово несемантичні зміни форматування або коментарів у коді, лише поза файлами, що входять до `RUNTIME_MANIFEST.json` або `Tools/TOOLS_MANIFEST.json`;
- repository metadata;
- окремі governance rules;
- допоміжні metadata-файли, що не входять до runtime/release/validation contract.

Файли, що входять до `RUNTIME_MANIFEST.json` або `Tools/TOOLS_MANIFEST.json` (зокрема `BRAVO_SELF_TEST.ps1` і `selftest/*`), мають мінімум клас V2 незалежно від характеру diff. V1 для коду можливий лише за механічного доказу (порівняння AST/токенів без коментарів) і все одно вимагає `Integrity manifests are current` та Full. Self-Test перевіряє також текст і коментарі вихідників, тому навіть зміна коментаря може зламати Full.

V1 не означає автоматичне звільнення від Full. Якщо зміна governance або metadata впливає на validation, build, packaging, release чи runtime contract, вона переходить до V2 або V3.

### 5.3 V2 — behavioral scoped changes

До V2 належать зміни production- або test-поведінки з відомим domain ownership та достатньо визначеною моделлю залежностей.

Нормальна послідовність:

```text
Targeted
   |
Affected
   |
Full перед acceptance
```

Успішні Targeted/Affected дають швидкий зворотний зв'язок, але не замінюють Full acceptance.

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

V3 вимагає Full та всіх релевантних specialized gates. Глибина незалежного рев'ю визначається політикою рев'ю репозиторію.

### 5.5 Файли, які не можна автоматично вважати V0/V1

Класифікація не повинна ґрунтуватися лише на extension або назві каталогу.

Зокрема, такі області не отримують автоматичного Self-Test exemption:

- `VERSION.json`;
- `RUNTIME_MANIFEST.json` і `Tools/TOOLS_MANIFEST.json` (мінімум V2, див. 5.2);
- живі документи, які читає Governance (див. 5.1);
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
unknown impact     -> V3 (Full + усі релевантні specialized gates + independent review)
```

Якщо неможливо механічно або на основі доказів підтвердити, що зміна не змінює поведінку, виняток для Self-Test не застосовується, а застосовується V3.

Жоден агент не повинен знижувати клас лише для скорочення часу CI або отримання green status.

### 5.7 CI semantics для not-required checks

Прецедент: `.github/workflows/config-parity.yml` + `ci/Test-BRAVOConfigParityRelevantPath.ps1`. Required check там створюється завжди, рішення про релевантність приймається всередині job, а для нерелевантного шляху job завершується успішно зі статусом «не застосовується». VAL-10 повторно використовує цей патерн і не дублює логіку релевантності.

Workflow, що може бути required, не слід обмежувати workflow-level `paths:` лише заради оптимізації, якщо це може призвести до відсутності required status check.

Модель CI повинна відокремлювати:

1. створення/наявність статусу required check;
2. рішення про релевантність;
3. фактичний запуск дорогого test harness.

Для V0/V1 job може завершитися успішним статусом `N/A / not required`, якщо branch protection потребує результату check, але це не можна звітувати як `BRAVO_SELF_TEST.ps1 PASS`.

Поточний CI продовжує запускати Full на всіх PR до окремої, перевіреної рев'ю зміни поведінки workflow. Цей design сам по собі не авторизує зміну `ci.yml`. Зміна guard-ів `Framework/CiWorkflowNeverNarrowsSelfTest` і `Governance/RequiredChecksListCoversCiWorkflowJobs` та переліку required checks — клас V3 і окреме рішення власника.

### 5.8 Початкова Validation Requirement Matrix

| Тип зміни | Targeted | Affected | Full Self-Test | Додаткова валідація |
| --- | --- | --- | --- | --- |
| Documentation-only, V0 | не потрібен | не потрібен | NOT REQUIRED | Governance (`Documentation/RelativeLinksResolve` над усіма `*.md`), static checks |
| PR/Issue metadata без repository diff | не потрібен | не потрібен | NOT REQUIRED | за потреби |
| Доказово несемантична зміна коду | зазвичай не потрібен | зазвичай не потрібен | визначається доказами; для файлів під manifest — REQUIRED | parser/static checks; `Integrity manifests are current` |
| Repository/governance metadata | за потреби | за потреби | залежить від впливу | governance checks |
| CI/workflow | релевантні | релевантні | залежить від впливу; validation-contract change може вимагати Full | workflow/governance checks |
| Test-only | змінений test | залежні tests | REQUIRED, якщо змінюється Full contract/harness/coverage; інакше за risk classification | відповідний test contract |
| Self-Test harness/discovery/aggregation | не є достатнім | не є достатнім | REQUIRED | governance/characterization |
| Production PowerShell | REQUIRED | REQUIRED | REQUIRED перед acceptance | domain-specific gates |
| Configuration/schema/defaults | REQUIRED | REQUIRED | REQUIRED | Config parity та інші config gates |
| Runtime integrity/manifest (файли під `RUNTIME_MANIFEST.json`/`Tools/TOOLS_MANIFEST.json` — мінімум V2) | REQUIRED | REQUIRED | REQUIRED | integrity/release gates |
| Packaging/deploy/update | REQUIRED | REQUIRED | REQUIRED, якщо змінюється runtime candidate/behavior | artifact/deployment gates |
| Security/trust/credentials | REQUIRED | REQUIRED | REQUIRED | security validation/review |
| Release/version metadata | за потреби | за потреби | згідно release policy та фактичного runtime impact | release gates |
| Generated runtime artifact/input | REQUIRED | REQUIRED | REQUIRED | generation/idempotency/integrity |
| Mixed або unknown scope | V3 | V3 | REQUIRED | усі релевантні specialized gates |

Матриця є базовою лінією дизайну. VAL-01/VAL-02 повинні підтвердити або уточнити категорії на основі фактичного ownership та поточного Self-Test contract.

## 6. Цільова архітектура Self-Test

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

Root script залишається стабільним entrypoint для оператора та CI. Значна повторно використовувана логіка harness повинна мати одного canonical owner, а не дублюватися між root і suites.

Це цільова архітектура, а не твердження, що поточний root script уже відповідає цій структурі. Вибір suite вже існує як `-Suite` у `BRAVO_SELF_TEST.ps1` (каталог suite, fail-closed на невідоме ім'я, маркер `SELF-TEST PARTIAL`); inline-корінь виконується завжди.

## 7. Модель залежностей suites

Affected execution потребує явної карти production ownership → validation ownership. Канонічний власник такої карти — `selftest/BRAVOSelfTestSuiteMap.ps1`: каталог `-Suite`, підказка `Get-BRAVOSelfTestSuiteForChangedPath` (порожній результат означає «невідомо → повний прогін») і план `Get-BRAVOSelfTestAffectedPlan`; `BRAVO_SELF_TEST.ps1` лише dot-source-ить цей файл після перевірки цілісності `RUNTIME_MANIFEST.json` і до розбору `-Suite`. Друга карта заборонена.

```text
змінений компонент
      |
      +--> suite прямого власника
      |
      +--> dependent suites
      |
      +--> shared-contract suites
```

Приклади категорій, які мають бути підтверджені у VAL-01:

- зміни configuration loader можуть вимагати configuration, config intent і configurator validation;
- зміни archive можуть вимагати archive, disk-space, backup-scope і trace/archive validation;
- зміни maintenance можуть вимагати maintenance-specific suites;
- зміни shared harness завжди вимагають Full;
- зміни з невідомим dependency coverage вимагають Full.

Карта повинна зберігатися в репозиторії, бути придатною для рев'ю та детермінованою. За неоднозначного ownership вона повинна обирати ширшу валідацію.

Не створювати статичний список `Fast` як заміну dependency ownership.

### 7.1 Правила класів у плані Affected

План (`Get-BRAVOSelfTestAffectedPlan`) — чиста функція; його клас є **мінімальним за картою шляхів**, а не класифікацією PR, і ніколи не є acceptance (`IsAcceptanceEvidence = $false`). Класифікація PR за §5 лишається обов'язковою й може підвищити клас.

- **V0 план не видає ніколи.** Документ поза вхідним набором Governance механічно довести неможливо (`Documentation/RelativeLinksResolve` читає всі tracked `*.md`), а runner не друкує «Full не потрібен».
- **Невідомий шлях → V3 і `Suite = @()`.** Змішаний набір відомих і невідомих шляхів теж V3: запускати лише відомі suite небезпечно. Некоректний шлях (порожній, змінюваний `Trim`, абсолютний, з сегментами `..`, `.` чи порожніми) → V3; вхід ніколи не обрізається.
- **Governance** (shared-contract) додається до union завжди, коли клас нижчий за V3; union упорядковано за каталогом.
- **V2 лише для** каталожних фрагментів `selftest/BRAVO_SELF_TEST.<Ім'я>.ps1` (suite = однойменний) і **leaf-модулів** (owner + dependents). Leaf-модуль — модуль без вхідних ребер від не-фрагментів (інших модулів, `BRAVO_CONFIG_LOADER.ps1`, кореневих `BRAVO_*.ps1`, `deploy/*.ps1`, `ci/*.ps1`); інваріант стереже AST-guard `Framework/AffectedPlan.LeafModulesHaveNoNonFragmentInboundEdge`, який також відмовляє (fail closed) за динамічного складання імені модуля. На базі `18137d9` усі модулі з suite мають такі ребра, тож таблиця leaf-модулів порожня й будь-яка зміна модуля дає V3. Видалений фрагмент → V3.
- **Супутній `RUNTIME_MANIFEST.json`** (похідний артефакт, регенерується після зміни будь-якого `.ps1/.psm1/.psd1`): якщо обидва тексти — коректний JSON, верхній рівень і поля `schemaVersion`, `description`, `updateProcedure` ідентичні, а кожен доданий, видалений чи змінений запис `files` (без регістру, `\` → `/`) є шляхом змінених файлів, маніфест — супутник, що дає **щонайменше V2** (навіть з порожньою розібраною дельтою) і gate «Integrity manifests are current». Інакше, а також якщо маніфест єдиний у наборі, — V3. `Tools/TOOLS_MANIFEST.json` і `VERSION.json` завжди V3.
- **Таблиця споживаних документів** (клас V1 із своїми споживачами): `README.md`, `SECURITY.md`, `RELEASE_CHECKLIST.md`, `RELEASE_POLICY.md`, `THREAT_MODEL.md`, `PROJECT.md`, `deploy/README.md` → Governance; `OPERATIONS.md` → Governance, DataRestore; `BRAVO_SETUP.md` → Governance, ConfigLoader; `CHANGELOG.md` → Governance. Для `README.md`, `BRAVO_SETUP.md`, `CHANGELOG.md` додається gate Release policy. Будь-який інший `*.md` (зокрема `docs/**`) → V3.
- **База порівняння (контракт збирача, PR2):** `merge-base(Base, HEAD)` з робочим деревом, untracked-файли включено; `git diff --no-renames --name-status -z` (rename дає обидва шляхи, видалення включено); шляхи не обрізаються; shallow-репозиторій, збій будь-якої команди git (зокрема `git status`) і порожній diff — помилка, а не порожній прогін.

Деталі реалізації й матриця тестів — у VAL-05 нижче.

## 8. Post-Install Verification

Installation verification — окрема production-задача.

`BRAVO_SELF_TEST.ps1` відповідає на питання:

> Чи відповідає код BRAVO repository test contract?

Post-Install Verify відповідає на питання:

> Чи є конкретне встановлення BRAVO повним, внутрішньо узгодженим і готовим до нормальної експлуатації?

Тому Full Self-Test не повинен бути єдиним доказом готовності встановлення.

Поточний стан: `deploy/Install-BRAVOServer.ps1` за замовчуванням запускає повний `BRAVO_SELF_TEST.ps1 -NoPause` (крок 6; обхід — `-SkipSelfTest`) і далі `BRAVO_SETUP.ps1 -ValidateOnly` (крок 7). Заміна кроку 6 на Post-Install Verify — окреме рішення власника після VAL-07, з характеризацією й без послаблення перевірок цілісності; цей дизайн такої зміни не вимагає й не авторизує.

### 8.1 Цільові області перевірки

Остаточний набір checks має бути підтверджений архітектурою Installer і фактичним runtime ownership. Очікувані області:

- наявність встановленого runtime та очікуваної структури;
- runtime manifest/integrity verification;
- збереження pre-trust runtime-guard boundary;
- завантаження configuration і required settings;
- коректна робота site/local configuration;
- доступність required paths та permissions (під ідентичністю запланованих завдань);
- наявність required credentials у Credential Manager цієї ідентичності без розкриття secret values;
- required dependencies;
- scheduled tasks, вибрані під час installation, якщо застосовно;
- готовність logging/state paths;
- безпечні для production smoke-перевірки entrypoint/runtime.

Ідентичність запланованих завдань визначає `schedulerSettings.RunAsUser` (див. `BRAVO_CREDENTIALS_SETUP.ps1`); `LogonType` лише обирає спосіб автентифікації. Сьогодні `BRAVO_SETUP.ps1 -ValidateOnly` делегує цій ідентичності тільки перевірку credentials (через короткочасне завдання), а безпечний тестовий прогін доступу/smoke виконує під обліковим записом того, хто запустив інсталятор. Тому Post-Install Verify повинен виконувати **кожну** операційну перевірку (шляхи, права, credentials, smoke) у worker-і під ідентичністю `RunAsUser`, розширивши наявний механізм короткочасного завдання, а не створюючи другий. Доки цього немає, перевірки під обліковим записом інсталятора звітуються окремо, а результат — не READY.

### 8.2 Safety contract

Post-Install Verify повинен:

- бути безпечним для production host;
- не виконувати синтетичних змін production-даних;
- не використовувати production state як test fixture;
- відмовляти в закритий стан (fail closed) за умов цілісності/безпеки, де цього вимагає політика runtime;
- надавати діагностику, придатну для дій оператора;
- ніколи не виводити secrets;
- повертати змістовний код завершення процесу (через `modules/BRAVO.ExitCodes/`);
- відрізняти готовність встановлення від попереджень, які не блокують експлуатацію.

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

## 9. Межі валідації

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

## 10. Залежність від Installer

Installer не повинен блокуватися до завершення повного Self-Test refactor.

Наявний стан: чисте встановлення виконує `deploy/Install-BRAVOServer.ps1`, оновлення — `deploy/Update-BRAVOServer.ps1`; `deploy/README.md` і `ROADMAP.md` резервують майбутнього власника `BRAVO_UPDATE.ps1` + `modules/BRAVO.Update/` (поки не реалізовано). Канонічного власника встановлення потрібно визначити до задач INS.

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
4. погоджений мінімальний інтерфейс Post-Install Verify (VAL-06a, без залежності від Installer).

Глибокий cleanup Self-Test harness може продовжуватися окремо після створення цих foundations.

## 11. План реалізації

### VAL-01 — Інвентаризація Self-Test

Інвентаризація лише для читання:

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

Зафіксувати зовнішньо спостережуваний канонічний Full contract до структурного рефакторингу:

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

Переглянути й оновити цей документ на основі доказів VAL-01/VAL-02. Усунути припущення початкового дизайну.

Оцінка: 3–5 годин.

### VAL-04 — Аудит і розширення наявного `-Suite`

Аудит і розширення наявного `-Suite` (#187/#219) у `BRAVO_SELF_TEST.ps1`: охарактеризувати поточну поведінку, зафіксувати прогалини (inline-корінь виконується завжди; фрагменти поза каталогом suite), не створювати другої реалізації вибору suite.

Наявна поведінка, яку потрібно зберегти: параметр `-Suite`; каталог suite; fail-closed на невідоме ім'я; маркер `SELF-TEST PARTIAL` замість `SELF-TEST PASSED`; guard-и `Framework/FullCanonicalRunIsDefault` і `Framework/SelectiveRunNeverPrintsReleaseMarker`; опис у `README.md`.

Вимоги:

- Windows PowerShell 5.1;
- детермінований вибір;
- Full command незмінна;
- без тихого пропуску (silent skip);
- існуюча семантика логів і результатів зберігається, де застосовно.

Оцінка: перерахувати після VAL-01.

### VAL-05 — Affected: карта та виконуваний інтерфейс

Характеризувати й розширити наявного власника `Get-BRAVOSelfTestSuiteForChangedPath`; друга карта заборонена. PR1 виносить каталог, підказку й план у `selftest/BRAVOSelfTestSuiteMap.ps1` (правила класів — §7.1) разом з міграцією споживачів і тестів `Framework/ChangedPathMap.*` та проб `-Suite`; git-збирач і runner — окремі PR. Якщо власника переносять, споживачів і характеризаційні перевірки (`Framework/ChangedFragmentMapsToItsOwnSuite`, `ChangedModuleMapsToSuiteOfSameDomain`, `ChangedPathHintNeverGuesses`) мігрувати в тому ж пакеті.

Карта:

- відповідність компонента та suite (ownership);
- залежні suite;
- консервативний перехід до Full для невідомих/спільних змін;
- характеризаційні тести поведінки карти;
- без generic `Fast` bucket.

Виконуваний інтерфейс Affected (сьогодні помічник викликається лише власними перевірками, виконуваного режиму немає):

- вхід: база порівняння (exact base SHA) і повний перелік змінених шляхів;
- результат: об'єднання (union) suite усіх шляхів;
- будь-який шлях без відповідності, у тому числі змішаний набір відомих і невідомих шляхів, -> Full і клас V3;
- порожній diff -> помилка, не порожній прогін;
- результат ніколи не друкує `SELF-TEST PASSED`.

Оцінка: 6–10 годин.

### VAL-06a — Мінімальний інтерфейс Post-Install Verify

Мінімальний інтерфейс без залежності від Installer:

- вхід: RuntimeRoot, ConfigPath, ідентичність виконання;
- вихід: READY/BLOCKED/WARN + код завершення через `modules/BRAVO.ExitCodes/`.

Це розриває цикл VAL-06/INS-01: INS-01 спирається на VAL-06a, а не на повний контракт.

Оцінка: 2–3 години.

### VAL-06b — Повний контракт Post-Install Verification

Перетворити розділ 8 на implementation-ready contract на основі VAL-06a і фактичного runtime ownership; виконується після INS-01.

Визначити:

- mandatory checks;
- семантику READY/BLOCKED;
- семантику warning;
- exit codes — лише через `modules/BRAVO.ExitCodes/` (повторне використання наявних, напр. 30/31/33/37, або зміна контракту модуля з валідацією всіх споживачів); локальна таблиця заборонена (інсталятор уже локально інтерпретує 33/34/35 — цей борг новий verifier не множить);
- diagnostics;
- порядок integrity/trust;
- safe operations;
- заборонені мутації production.

Оцінка: 2–3 години.

### INS-01 — Технічна архітектура Installer

Першим пунктом визначити канонічного власника встановлення: розширення `deploy/Install-BRAVOServer.ps1` чи міграція до `BRAVO_UPDATE.ps1`/`modules/BRAVO.Update/`; шлях міграції та депрекації інших. INS-02 не створює паралельного інсталятора.

Далі визначити фази Installer та точки інтеграції Post-Install Verify.

Це задача Installer track, залежна від VAL-06a.

Оцінка: 4–8 годин.

### INS-02 — Installer MVP

Реалізувати окремо погоджений Installer MVP відповідно до його design, у межах власника, визначеного в INS-01.

Оцінка: 1–2 робочі дні.

### VAL-07 — Post-Install Verifier

Реалізувати безпечний для production verifier за контрактом VAL-06b.

Оцінка: 1–2 робочі дні.

### INS-03 — Інтеграція verification в Installer

Підключити завершення Installer до Post-Install Verify і показувати діагностику READY/BLOCKED, придатну для дій оператора.

Оцінка: 4–8 годин.

### VAL-08 — Межа Self-Test Harness

Зменшити responsibilities root Self-Test до orchestration та встановити canonical ownership повторно використовуваної поведінки harness.

Це структурна робота, що потребує валідації за принципом «спочатку характеризація».

Оцінка: 1–2 робочі дні.

### VAL-09 — Нормалізація та ізоляція suites

Нормалізувати suite lifecycle та усунути небезпечні/дубльовані патерни fixture/sandbox без зміни test intent.

Окремо перевірити відсутність забруднення fixtures production state.

Оцінка: 1–2 робочі дні.

### VAL-10 — CI Validation Model

Залежить від виконуваного інтерфейсу Affected з VAL-05. Використовувати Targeted/Affected execution для швидшого зворотного зв'язку там, де це корисно, з обов'язковим збереженням Full coverage на acceptance gates.

Повторно використовувати патерн `config-parity.yml` + `ci/Test-BRAVOConfigParityRelevantPath.ps1` (див. 5.7). Зміна guard-ів `Framework/CiWorkflowNeverNarrowsSelfTest` і `Governance/RequiredChecksListCoversCiWorkflowJobs` та required checks — клас V3, окреме рішення власника. Required check `BRAVO_SELF_TEST.ps1` лишається повним канонічним прогоном; швидкий Affected — лише додатковий не-required job.

Будь-який CI parallelism має використовувати окремі supported processes/jobs. Заборонений in-process Self-Test parallelism не вводити.

Оцінка: 4–8 годин.

### ACC-01 — Full Regression

Виконати required Windows PowerShell 5.1 Full та specialized validation на exact candidate.

Evidence має містити фактичну команду, exit code та key result.

Full валідний лише якщо: exit 0, маркер `SELF-TEST PASSED`, 0 рядків `[НЕДОСТУПНО]`, 0 перерваних/пропущених секцій і всі required checks зелені на exact SHA: увесь канонічний перелік із `RELEASE_POLICY.md` §13.3 (`Parser / BOM / JSON`, `PSScriptAnalyzer`, `BRAVO_SELF_TEST.ps1`, `BRAVO_DATA_RESTORE_MATRIX_TEST.ps1`, `Secret scanning (gitleaks)`, `GitGuardian Security Checks`) плюс умовні перевірки, коли вони запускаються (наприклад `Config parity (BRAVO_CONFIG_LOADER)`). Перелік читається з канонічної політики, а не копіюється сюди як окреме джерело; відсутня чи не запущена required-перевірка інвалідує acceptance. Exit 0 і маркер недостатні: `[НЕДОСТУПНО]` не входить у failures, тож за обмежень хоста Self-Test друкує `SELF-TEST PASSED` з exit 0, але такий прогін не є повним прийманням. Наявність `[НЕДОСТУПНО]` на required checks інвалідує Full acceptance.

Оцінка: приблизно 0,5 робочого дня.

### ACC-02 — Незалежне рев'ю

Незалежний рецензент (fresh reviewer) перевіряє поведінкову/архітектурну зміну за P0–P3 та звичайною merge-gate policy.

Оцінка: 2–4 години.

### ACC-03 — DEV-LIMS Acceptance

Коли це потрібно і operational gates дозволяють, виконати exact-SHA canonical Full acceptance у контрольованому DEV-LIMS environment. Той самий критерій валідності Full, що й в ACC-01 (exit 0, `SELF-TEST PASSED`, 0 `[НЕДОСТУПНО]`, 0 перерваних/пропущених секцій), застосовується тут; exit 0 і маркер самі по собі недостатні.

Завершення попередніх задач саме по собі не авторизує цю дію.

Оцінка: 2–4 години без урахування environment blockers.

## 12. Хвилі реалізації

### Wave 1 — Фундамент

```text
VAL-01 -> VAL-02 -> VAL-03
```

Широкий implementation refactor не повинен передувати цій базовій лінії.

Орієнтир: 1–2 робочі дні.

### Wave 2 — Швидкий зворотний зв'язок та installation contract

```text
VAL-04 -> VAL-05

VAL-06a -> INS-01 -> VAL-06b
```

Tracks можуть виконуватися незалежно після виконання dependencies, з дотриманням правила про один mutation lane для файлів/artifacts, що перетинаються.

### Wave 3 — Installer MVP та verifier

```text
VAL-07 ----+
           +--> INS-03 -> ACC-01 -> ACC-02 -> ACC-03 за потреби
INS-02 ----+
```

INS-02/INS-03 змінюють поведінку розгортання, тому це V3: Installer MVP, доставлений незалежно від Wave 4, проходить власний acceptance-шлях на exact SHA (Full за ACC-01, спеціалізована перевірка Installer/Post-Install Verify, незалежне рев'ю ACC-02, ACC-03 за потреби) і не вважається завершеним без нього. Цей шлях не чекає на VAL-08–VAL-10.

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

Будь-яка зміна коду/harness за знахідкою ACC-02 -> Targeted/Affected -> повтор ACC-01 на новому SHA -> verification знахідки. Evidence ACC-01/ACC-02/ACC-03 прив'язане до фінального SHA. ACC-03 не компенсує пропущений повтор ACC-01.

## 13. Загальна оцінка

Початкова оцінка планування:

- фундамент перед серйозною реалізацією Installer: 1–2 робочі дні;
- Installer MVP + Post-Install Verify: приблизно ще 2–4 робочі дні;
- повна Validation Architecture, cleanup, CI integration та review: приблизно 6–10 робочих днів загалом.

Це оцінки планування, а не зобов'язання. Після VAL-01/VAL-02 їх потрібно замінити оцінкою на основі доказів з урахуванням фактичної зв'язності та harness ownership.

## 14. Що не входить у цю архітектуру

Цей дизайн не дозволяє і не вимагає:

- скорочувати Full Self-Test coverage;
- замінювати Windows PowerShell 5.1 на PowerShell 7;
- мігрувати на Pester;
- послаблювати integrity/security gates;
- вимагати Full Self-Test як єдиного доказу готовності встановлення (поточний крок 6 `deploy/Install-BRAVOServer.ps1` не змінюється без окремого рішення власника);
- вважати Post-Install Verify release acceptance;
- вважати Health/Maintenance repository testing;
- об'єднувати всі specialized tests в один script;
- дозволяти паралельним writers змінювати ті самі test/harness artifacts;
- виконувати deployment, release або merge.

## 15. Acceptance invariants

Реалізація прийнятна лише якщо всі застосовні invariants залишаються істинними:

1. `.\BRAVO_SELF_TEST.ps1 -NoPause` залишається канонічним незмінним Full entrypoint.
2. Full охоплює всі mandatory checks, які він охоплював до зміни.
3. Targeted/Affected є додатковими механізмами зворотного зв'язку для розробника, а не слабшими замінниками acceptance.
4. Unknown dependency ownership переходить до ширшої validation, аж до Full.
5. Windows PowerShell 5.1 залишається supported validation runtime.
6. Test fixtures/state ізольовані від real BRAVO production state.
7. Runtime integrity і pre-trust guard boundary не послаблюються.
8. Post-Install Verify безпечний для production, відокремлений від Self-Test репозиторію й виконує перевірки під ідентичністю запланованих завдань.
9. Evidence звітується лише для commands/checks, які фактично виконувалися; `[НЕДОСТУПНО]` на required checks інвалідує Full acceptance.
10. Поведінкові/високоризикові зміни проходять свіже незалежне рев'ю перед acceptance; будь-яка зміна після ACC-01 повертає цикл до Targeted/Affected + Full на фінальному SHA.

## 16. Наступна дія

Наступна implementation action — не Self-Test refactor.

Спочатку виконати VAL-01 і VAL-02 як хвилю збору доказів лише для читання. Їхні результати використати для уточнення цього design до того, як VAL-04 або VAL-08 змінюватимуть test behavior чи structure.

Такий порядок зберігає поточний Full contract і створює безпечний шлях до швидшої валідації під час розробки та зручного для людини Installer.
