# RELEASE_POLICY.md

## 1. Призначення документа

Цей документ визначає політику розробки, тестування та випуску релізів у
репозиторії `BRAVO-Toolkit`.

Основні цілі:

- відокремити розробку та тестування від production-релізів;
- не допускати потрапляння неперевіреного коду в `master`;
- забезпечити однозначне розрізнення development і production-пакетів;
- формалізувати перевірку релізів на реальних серверах;
- зробити процес випуску відтворюваним і контрольованим.

Практичний бік цих правил (що саме перевірити перед тегуванням) —
`RELEASE_CHECKLIST.md`. Цей документ відповідає на питання «яка версія
де дозволена», чек-лист — на питання «що зробити перед випуском».

---

## 2. Основні гілки

У репозиторії використовуються дві постійні гілки:

- `developer` — розробка, інтеграція, тестування та prerelease-релізи;
- `master` — лише перевірені production-релізи.

### 2.1. Гілка `developer`

Гілка `developer` використовується для:

- розробки нових функцій;
- виправлення помилок;
- security-виправлень;
- інтеграції змін;
- запуску автоматичних тестів;
- формування тестових релізів;
- перевірки на тестових і пілотних серверах.

У `developer` дозволені лише prerelease-версії:

```text
X.Y.Z-dev.N
X.Y.Z-rc.N
```

Приклади:

```text
4.5.0-dev.1
4.5.0-dev.2
4.5.0-rc.1
4.5.0-rc.2
```

У `developer` заборонено публікувати stable-релізи без prerelease-суфікса.

### 2.2. Гілка `master`

Гілка `master` використовується лише для production-релізів.

У `master` дозволено публікувати тільки код, який:

1. пройшов розробку та CI у `developer`;
2. був опублікований як prerelease;
3. пройшов тестування на реальному сервері;
4. успішно виконав основні production-операції;
5. не має відомих блокуючих дефектів;
6. схвалений для production-використання.

У `master` дозволені лише stable-версії:

```text
X.Y.Z
```

Приклади:

```text
4.4.2
4.5.0
4.5.1
```

У `master` заборонені версії:

```text
4.5.0-dev.1
4.5.0-rc.1
```

---

## 3. Політика версій

Проєкт використовує Semantic Versioning:

```text
MAJOR.MINOR.PATCH
```

де:

- `MAJOR` — несумісні зміни;
- `MINOR` — нова функціональність зі збереженням сумісності;
- `PATCH` — сумісні виправлення.

Для development-релізів використовуються prerelease-суфікси.

### 3.1. Development-версії

Формат:

```text
X.Y.Z-dev.N
```

Використовуються для:

- активної розробки;
- внутрішнього тестування;
- ранньої перевірки змін;
- пакетів, які ще не готові до тестування як кандидат у production.

Приклад:

```text
4.5.0-dev.1
4.5.0-dev.2
4.5.0-dev.3
```

### 3.2. Release Candidate

Формат:

```text
X.Y.Z-rc.N
```

Release Candidate використовується для пакета, який:

- функціонально завершений;
- пройшов CI;
- пройшов self-test;
- готовий до перевірки на реальному сервері;
- не повинен отримувати нові функції.

Після створення RC дозволені лише:

- виправлення дефектів;
- виправлення документації;
- виправлення manifest-файлів;
- виправлення тестів;
- зміни, необхідні для успішного production-тестування.

Приклад:

```text
4.5.0-rc.1
4.5.0-rc.2
```

### 3.3. Stable-версії

Формат:

```text
X.Y.Z
```

Stable-реліз створюється лише шляхом promotion перевіреного RC.

Приклад:

```text
4.5.0-rc.2 -> 4.5.0
```

Stable-реліз не повинен містити нових функціональних змін порівняно з
останнім перевіреним RC.

Допустимі лише release-зміни:

- видалення prerelease-суфікса;
- зміна `releaseChannel`;
- оновлення `releaseDate`;
- оновлення `buildId`;
- оновлення `sourceCommit`;
- оновлення `CHANGELOG.md`;
- оновлення release metadata;
- перегенерація manifest-файлів.

### 3.4. `ModuleVersion` і prerelease-суфікс

`ModuleVersion` у `modules\*\*.psd1` — це тип `[System.Version]`, який не
приймає prerelease-суфікса, а `New-ModuleManifest` у Windows PowerShell
5.1 не має параметра `-Prerelease` (перевірено на цільовій платформі).
Тому діє таке правило:

```text
VERSION.json  packageVersion = 4.5.0-dev.1
modules\*.psd1 ModuleVersion  = 4.5.0
```

`ModuleVersion` дорівнює **базовій частині** `packageVersion` (без
суфікса). Самотест `Version/ModuleManifests` перевіряє саме це, а
`Version/DeveloperBranchCarriesPrereleaseVersion` — що суфікс
відповідає гілці. Повна версія пакета завжди береться з `VERSION.json`,
а не з маніфестів модулів.

З цього правила випливає **свідоме обмеження release contract BRAVO**:
BRAVO використовує Semantic Versioning `X.Y.Z`, але через цільову
платформу Windows PowerShell 5.1 базова частина `packageVersion` має
бути представима типом `System.Version`, оскільки той самий `X.Y.Z`
записується як `ModuleVersion` у `*.psd1`. Тобто кожен із
MAJOR/MINOR/PATCH не перевищує `2147483647` (`Int32.MaxValue`).
Синтаксично коректний, але непредставимий core (наприклад
`2147483648.0.0`) — **непідтримувана** `packageVersion`: її відхиляє і
`ci\Test-BRAVOReleasePolicy.ps1` (до порівняння `ModuleVersion`, однією
root-cause помилкою), і runtime guard кожного entrypoint (fail-closed
malformed-шлях захисту від відкату).

Обмеження стосується лише MAJOR/MINOR/PATCH. Числовий
prerelease-ідентифікатор `N` у `-dev.N` / `-rc.N` **не** обмежується
розміром `Int32`: він валідується за SemVer і порівнюється як число
довільної довжини.

---

## 4. Вимога різних версій у `developer` та `master`

Гілки `developer` і `master` не повинні тривалий час містити однакову
версію пакета.

Нормальний стан:

```text
master:    4.4.2
developer: 4.5.0-dev.1
```

Після promotion:

```text
master:    4.5.0
developer: 4.5.1-dev.1
```

Якщо після merge гілки тимчасово містять однаковий код, у `developer`
необхідно одразу відкрити наступний development-цикл та змінити версію.

Для patch-циклу:

```text
master:    4.5.0
developer: 4.5.1-dev.1
```

Для minor-циклу:

```text
master:    4.5.0
developer: 4.6.0-dev.1
```

Однакова версія в обох гілках ускладнює визначення походження пакета та
створює ризик випадкового встановлення тестового комплекту на
production-сервер.

---

## 5. `VERSION.json`

### 5.1. Приклад для `developer`

Development-реліз:

```json
{
  "product": "BRAVO-Toolkit",
  "packageVersion": "4.5.0-dev.1",
  "configSchemaVersion": 1,
  "stateSchemaVersion": 1,
  "updaterVersion": "1.0.0",
  "releaseDate": "2026-08-05",
  "releaseChannel": "development",
  "buildId": "abcdef1",
  "sourceCommit": "abcdef1234567890abcdef1234567890abcdef12"
}
```

Release Candidate:

```json
{
  "product": "BRAVO-Toolkit",
  "packageVersion": "4.5.0-rc.1",
  "configSchemaVersion": 1,
  "stateSchemaVersion": 1,
  "updaterVersion": "1.0.0",
  "releaseDate": "2026-08-05",
  "releaseChannel": "prerelease",
  "buildId": "abcdef1",
  "sourceCommit": "abcdef1234567890abcdef1234567890abcdef12"
}
```

### 5.2. Приклад для `master`

```json
{
  "product": "BRAVO-Toolkit",
  "packageVersion": "4.5.0",
  "configSchemaVersion": 1,
  "stateSchemaVersion": 1,
  "updaterVersion": "1.0.0",
  "releaseDate": "2026-08-05",
  "releaseChannel": "stable",
  "buildId": "1234567",
  "sourceCommit": "1234567890abcdef1234567890abcdef12345678"
}
```

### 5.3. Обов'язкові правила

Для `developer`:

```text
packageVersion = X.Y.Z-dev.N або X.Y.Z-rc.N
releaseChannel = development або prerelease
```

Для `master`:

```text
packageVersion = X.Y.Z
releaseChannel = stable
```

Канал релізу повинен бути записаний у самому пакеті.

Не можна покладатися лише на `.git/HEAD`, оскільки production-комплект
може бути:

- завантажений як ZIP;
- скопійований на сервер без `.git`;
- розгорнутий через файловий архів;
- переданий через SFTP або SMB.

#### `releaseDate` звіряється із заголовком `CHANGELOG.md`

`releaseDate` — не коментар, а значення, яке пакет несе на сервер:
`BRAVO_CONFIG_LOADER.ps1` валідує його і віддає як `$global:ScriptDate`,
а `ci\New-BRAVOReleaseArtifact.ps1` переносить у `release-manifest.json`
**кожного** артефакту. Оператор, який звіряє провенанс за §16.3, бачить
саме це поле.

Тому діє правило:

```text
VERSION.json.releaseDate == дата в заголовку CHANGELOG.md
                            для тієї самої packageVersion
```

Звірку виконує `ci\Test-BRAVOReleasePolicy.ps1` (задача
`Parser / BOM / JSON`, required check за §13.3).

**Чому джерелом істини обрано заголовок `CHANGELOG.md`, а не дату
коміту `sourceCommit`.** Заголовок не потребує ані `.git`, ані повного
(не shallow) клону — перевірка працює й на розпакованому архіві, тобто
там, де провенанс звірити вже нічим.

**Виняток — недатований заголовок лінії в роботі** (наприклад
`## 5.2.3-dev.1 (fix/..., у розробці)`): звіряти немає з чим, і
вигадувати дату, щоб задовольнити перевірку, гірше, ніж не звіряти.
Поза `master` це попередження в лозі CI; на `master` — відмова, бо
кожен stable-заголовок датований.

**Підстава емпірична.** У гілці `developer` поле залишалось
`2026-08-26` — датою штампу `5.3.0-rc.1` — наскрізь через штампи
`5.3.0-dev.2`, restamp `dev.2` і `5.3.0-dev.3`, поки stable-штампи
оновлювали його коректно. Три тижні артефактів заявляли чужу дату.
Поле веде людина, жоден скрипт `ci\` його не записував, і помітити
дрейф не могло ніщо. Це той самий клас дефекту, що закрила
автоматизація parity harness (§14.4): обов'язок без механізму не
виконується.

---

### 5.4. Чому канал знову зберігається в пакеті (AUD-016)

Раніше `releaseChannel` зберігався однаковим на обох гілках
(`"stable"`), а реальне значення виводилось із `.git/HEAD`
(`Resolve-BRAVOReleaseChannelFromGit`). Причина була конкретна: кожен
merge `developer` → `master` вимагав ручного follow-up commit, і
fast-forward двічі мовчки протягнув значення не в ту гілку.

Ця політика усуває саму причину інакше: `developer` і `master` більше
ніколи не містять однакового `VERSION.json` (розділ 4), тому
fast-forward між ними неможливий — promotion завжди явна зміна версії й
каналу. А замість людської дисципліни, яка тоді підвела, працює
механічний gate `ci\Test-BRAVOReleasePolicy.ps1`: невідповідність гілки,
версії та каналу валить CI.

`Resolve-BRAVOReleaseChannelFromGit` залишається — але вже не як джерело
значення, а як перехресна перевірка: якщо поруч є `.git` і гілка
суперечить записаному каналу, CI червоніє. Джерело істини — `VERSION.json`
(розділ 5.3).

---

## 6. Стандартний workflow розробки

### 6.1. Створення робочої гілки

Рекомендовані типи тимчасових гілок:

```text
feature/*
fix/*
security/*
docs/*
refactor/*
```

Приклади:

```text
feature/add-archive-validation
fix/winscp-timeout
security/credential-hardening
docs/release-policy
```

Гілки створюються від актуальної `developer`:

```bash
git switch developer
git pull --ff-only origin developer
git switch -c feature/add-archive-validation
```

### 6.2. Merge змін

Допустимий маршрут:

```text
feature/*  -> developer
fix/*      -> developer
security/* -> developer
docs/*     -> developer
```

Заборонений маршрут:

```text
feature/* -> master
fix/*     -> master
```

Усі звичайні зміни мають пройти через `developer`.

---

## 7. Development release flow

### 7.1. Початок нового циклу

Після production-релізу:

```bash
git switch developer
git merge --ff-only master
```

Після цього версія змінюється на наступну development-версію.

Приклад:

```text
master:    4.5.0
developer: 4.5.1-dev.1
```

або:

```text
master:    4.5.0
developer: 4.6.0-dev.1
```

### 7.2. Створення development-релізу

Перед створенням `dev`-релізу необхідно:

- оновити `VERSION.json`;
- синхронізувати всі `ModuleVersion` (розділ 3.4);
- оновити заголовки документації;
- оновити `CHANGELOG.md`;
- перегенерувати manifest-файли;
- запустити CI;
- запустити `BRAVO_SELF_TEST.ps1`.

Тег:

```bash
git tag -a v4.5.0-dev.1 -m "BRAVO-Toolkit 4.5.0-dev.1"
git push origin v4.5.0-dev.1
```

GitHub Release має бути позначений як:

```text
Pre-release: true
Latest release: false
```

---

## 8. Release Candidate flow

RC створюється після завершення функціональної розробки.

Приклад переходу:

```text
4.5.0-dev.3 -> 4.5.0-rc.1
```

Перед створенням RC необхідно:

- завершити функціональні зміни;
- закрити блокуючі дефекти;
- пройти всі автоматичні тести;
- пройти перевірку `BRAVO_SETUP.ps1 -ValidateOnly`;
- пройти `BRAVO_DRY_RUN.ps1`;
- перевірити актуальність manifest-файлів;
- оновити документацію;
- підготувати release notes.

Тег:

```bash
git tag -a v4.5.0-rc.1 -m "BRAVO-Toolkit 4.5.0-rc.1"
git push origin v4.5.0-rc.1
```

GitHub Release:

```text
Pre-release: true
Latest release: false
```

---

## 9. Перевірка RC на реальних серверах

Перед promotion у `master` RC повинен пройти перевірку щонайменше на
одному реальному сервері.

Для критичних змін рекомендується перевірка на кількох серверах із
різними конфігураціями.

### 9.1. Обов'язкові перевірки

Необхідно перевірити:

- інсталяцію або оновлення через `BRAVO_SETUP.ps1`;
- `BRAVO_SETUP.ps1 -ValidateOnly`;
- `BRAVO_DRY_RUN.ps1`;
- реальну архівацію;
- створення локальних архівів;
- перевірку архівів через 7-Zip;
- передавання на SFTP;
- копіювання на SMB/NAS, якщо компонент увімкнений;
- health-check;
- maintenance;
- запуск завдань від `SYSTEM`;
- відсутність секретів у журналах;
- коректність кодів завершення;
- коректність сповіщень;
- сумісність із цільовою Windows та Windows PowerShell 5.1;
- restore test, якщо зміни стосуються резервного копіювання або
  відновлення.

### 9.2. Мінімальний протокол перевірки

Для кожного тестового сервера потрібно зафіксувати:

```text
Server:
OS:
PowerShell:
Previous version:
Tested version:
Install/update result:
ValidateOnly result:
Dry-run result:
Archive result:
SFTP result:
SMB result:
Health result:
Maintenance result:
Restore test result:
Detected issues:
Decision:
```

### 9.3. Критерії готовності

RC готовий до promotion, якщо:

- усі обов'язкові перевірки пройдені;
- зібрані докази по RC-матриці приймання по ОС (§9.4) для обов'язкових
  цілей;
- немає блокуючих дефектів;
- немає security-регресій;
- немає втрати backup-файлів;
- немає пошкодження конфігурації;
- немає помилок під час запуску від `SYSTEM`;
- немає некоректної роботи після оновлення;
- документація відповідає фактичній поведінці.

### 9.4. RC-матриця приймання по ОС

Один сервер із §9 — мінімум, а не контракт. Ця матриця визначає, які
саме платформи мусять мати доказ перед promotion у `master`.

**Підстава емпірична, не теоретична.** Обидва дефекти, виправлені в
PR #148, **неможливо було знайти в CI**:

| Дефект | Чому CI його не бачив |
|---|---|
| `volumes=d:, D:` → хибна вимога `diskshadow.exe` → `[FAIL] VSS` | потрібен `bravo.ini` зі змішаним регістром **і** клієнтська Windows, де `diskshadow.exe` відсутній; на раннері обидві умови не збігаються |
| `Test-Path` по недосяжному UNC піднімає `The network path was not found` | на доменному хості ім'я резолвиться і йде спроба SMB; на раннері ім'я не резолвиться, і `Test-Path` тихо повертає `$false` |

Платформо-чутлива функціональність: VSS, `diskshadow`, Планувальник
завдань, запуск від `SYSTEM`, ACL, провайдери файлової системи, UNC,
UAC, відмінності клієнтської Windows і Windows Server, локаль консолі
(OEM-866 ламає кирилицю в дочірніх процесах).

#### Цілі приймання

Рівні підтримки визначає `modules\BRAVO.Compatibility`; матриця їх
**не розширює**, а лише каже, що саме треба довести.

| Ціль | Рівень | Обов'язковість |
|---|---|---|
| Windows Server 2022 + Windows PowerShell 5.1 | Supported | **обов'язково** |
| Windows 11 + Windows PowerShell 5.1 | Supported | **обов'язково** |
| Windows Server 2016 | Legacy best-effort | за наявності ресурсу |
| Windows Server 2012 R2 | Legacy best-effort | за наявності ресурсу |

Клієнтська Windows у переліку обов'язкових не випадково: саме на ній
відсутній `diskshadow.exe`, і саме там знайдено перший дефект PR #148.

Приймання по матриці — вимога **promotion RC → stable**, а не gate на
кожен PR.

#### Мінімальний набір сценаріїв на хост

На кожній цілі матриці треба довести:

1. архівацію з VSS;
2. обслуговування (`BRAVO_MAINTENANCE.ps1`);
3. виконання завдання Планувальника від `SYSTEM`;
4. `BRAVO_SELF_TEST.ps1` — або його класифіковану недоступність (нижче).

Решта перевірок §9.1 лишається обов'язковою для того сервера, на якому
виконується повний протокол §9.2.

#### Self-test може бути недоступним — і це не провал приймання

На жорстко налаштованому хості (GPO-транскрипція PowerShell,
Constrained Language Mode через AppLocker/WDAC) дочірні проби self-test
не можуть виконатись. Зафіксований випадок: на RDSH-сервері
`HelperLogging/SuspensionHidesConsoleOutput` і
`HelperLogging/CanaryDetectsIneffectiveSuspension` дали `[FAIL]`, бо
проба не повернула JSON.

Такий результат **не** вважається провалом приймання і **не**
вважається доказом справності комплекту. Він фіксується окремо, з
причиною:

```powershell
$ExecutionContext.SessionState.LanguageMode
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription' -ErrorAction SilentlyContinue
```

На такому хості self-test не є придатним gate інсталяції, і пункт 4
набору сценаріїв замінюється записом про причину недоступності.
Класифікація цього стану самим harness-ом — окрема інженерна задача.

#### Доказ

Для кожної цілі матриці фіксується протокол §9.2, доповнений рядками:

```text
Acceptance target:      Windows Server 2022 | Windows 11 | Server 2016 | Server 2012 R2
Support tier:           Supported | LegacyBestEffort
VSS archive result:
Maintenance result:
SYSTEM scheduled task result:
Self-test result:       PASS | FAIL | НЕДОСТУПНИЙ (причина)
```

Докази зберігаються там само, де наявні acceptance-документи —
`docs\`, з посиланням із release notes.

---

## 10. Promotion у `master`

Production-реліз створюється лише з перевіреного RC.

Приклад:

```text
developer: 4.5.0-rc.2
master:    4.5.0
```

### 10.1. Дозволені зміни під час promotion

Під час promotion дозволено:

- змінити `4.5.0-rc.2` на `4.5.0`;
- встановити `releaseChannel: stable`;
- оновити `releaseDate`;
- оновити `buildId`;
- оновити `sourceCommit`;
- оновити release notes;
- оновити `CHANGELOG.md`;
- перегенерувати `RUNTIME_MANIFEST.json`;
- перегенерувати інші manifest-файли, які залежать від release metadata.

Під час promotion заборонено:

- додавати нові функції;
- змінювати бізнес-логіку;
- виконувати не протестований refactoring;
- додавати нові залежності;
- виправляти сторонні дефекти без повторного RC-тестування.

Якщо під час підготовки stable-релізу потрібна функціональна зміна,
необхідно:

1. повернути зміну в `developer`;
2. створити новий RC;
3. повторити тестування;
4. лише після цього виконати promotion.

### 10.2. Merge у `master`

Рекомендований маршрут:

```text
developer -> master
```

Merge виконується лише через Pull Request.

Після merge:

```bash
git switch master
git pull --ff-only origin master
git tag -a v4.5.0 -m "BRAVO-Toolkit 4.5.0"
git push origin v4.5.0
```

GitHub Release:

```text
Pre-release: false
Latest release: true
```

---

## 11. Дії після production-релізу

Після публікації stable-релізу необхідно:

1. переконатися, що тег `vX.Y.Z` вказує на правильний commit;
2. переконатися, що GitHub Release не позначений як Pre-release;
3. перевірити release artifact;
4. перевірити `VERSION.json` у завантаженому пакеті;
5. синхронізувати `developer` із `master`;
6. відкрити наступний development-цикл;
7. змінити версію в `developer` на наступну prerelease-версію.

Приклад:

```text
master:    4.5.0
developer: 4.5.1-dev.1
```

---

## 12. Hotfix flow

Hotfix використовується лише для критичних production-проблем.

Приклади:

- production-реліз не запускається;
- архівації не створюються;
- backup пошкоджуються;
- виникла security-вразливість;
- не працює критичне передавання;
- оновлення блокує роботу реального сервера.

### 12.1. Створення hotfix

Hotfix-гілка створюється від `master`:

```bash
git switch master
git pull --ff-only origin master
git switch -c hotfix/4.5.1
```

Версія для тестування:

```text
4.5.1-rc.1
```

Hotfix також повинен пройти:

- CI;
- self-test;
- dry-run;
- реальні серверні перевірки;
- RC-етап.

Після перевірки:

```text
4.5.1-rc.1 -> 4.5.1
```

### 12.2. Обов'язкова синхронізація

Після merge hotfix у `master` ті самі зміни необхідно перенести в
`developer`.

Допустимі варіанти:

```bash
git switch developer
git merge master
```

або selective cherry-pick, якщо `developer` вже суттєво випереджає
`master`.

Hotfix не можна залишати лише в `master`, інакше наступний
production-реліз може повторно повернути вже виправлений дефект.

---

## 13. Branch protection

### 13.1. `master`

Для `master` рекомендуються:

- заборонити прямі push;
- дозволяти зміни лише через Pull Request;
- вимагати успішний CI;
- вимагати проходження всіх required checks;
- заборонити force push;
- заборонити видалення гілки;
- вимагати актуальну гілку перед merge;
- обмежити merge лише дозволеним користувачам;
- заборонити merge з `feature/*` напряму;
- дозволяти production promotion лише з `developer` або `hotfix/*`.

### 13.2. `developer`

Для `developer` рекомендуються:

- заборонити force push;
- заборонити видалення гілки;
- вимагати CI для Pull Request;
- дозволити merge робочих гілок;
- не дозволяти stable-версії.

### 13.3. Перелік required checks

Канонічний перелік імен, які мусять бути налаштовані як required для
`master` і `developer`:

- `Parser / BOM / JSON`
- `PSScriptAnalyzer`
- `BRAVO_SELF_TEST.ps1`
- `BRAVO_DATA_RESTORE_MATRIX_TEST.ps1`
- `Secret scanning (gitleaks)`
- `GitGuardian Security Checks`

Перші п'ять — задачі `.github/workflows/ci.yml` (включно з
`Secret scanning (gitleaks)`, яку запускає `gitleaks-action` усередині
цього ж workflow); `GitGuardian Security Checks` надає зовнішній
GitHub App, тому серед задач workflow її немає. Імена наведені саме в
`pull_request`-варіанті, **без** суфікса ` (push)`. Це не косметика:
branch protection зіставляє required checks за ІМЕНЕМ, і під час
промоції stable той самий head SHA несе одночасно зелений
`pull_request`-прогін і навмисно червоний `push`-прогін (stable-версія
на `developer` провалює release-policy гейт у контексті гілки —
задокументований транзієнт). Саме через збіг імен merge 5.1.0 довелося
проводити обходом адміністратора; розділення імен за подією в `ci.yml`
існує, щоб це не повторилось.

Відповідність цього переліку задачам `ci.yml` перевіряється механічно
(`Governance/RequiredChecksListCoversCiWorkflowJobs` у self-test): нова
задача в workflow, не додана сюди, валить self-test. Рівно цей дрейф і
був причиною issue #149 — перелік вівся вручну, `ci.yml` пішов уперед,
і провалений матричний тест лишався технічно немерджблокуючим.

Технічний стан (перевірено 2026-08-26, репозиторій публічний —
branch protection доступний без платного плану): protection
**увімкнено** для обох гілок.

- `master`: зміни лише через Pull Request; required checks
  «Parser / BOM / JSON», «PSScriptAnalyzer», «BRAVO_SELF_TEST.ps1»,
  «Secret scanning (gitleaks)», «GitGuardian Security Checks»
  (strict — гілка мусить бути актуальною); force push і видалення
  гілки заборонені; `enforce_admins` увімкнено (обхід адміністратором
  заблоковано — прецедент merge PR #61 у вікні промоції 5.1.0 більше
  технічно неможливий).
- `developer`: зміни лише через Pull Request; ті самі required
  checks (без strict-вимоги актуальності гілки); force push і
  видалення заборонені; `enforce_admins` увімкнено.

> **`BRAVO_DATA_RESTORE_MATRIX_TEST.ps1` у налаштуваннях ЩЕ НЕ
> ввімкнено** (issue #149). Задача виконується на кожному PR і має
> стабільне ім'я (перевірено за `ci.yml`: тригер `pull_request: {}` без
> умов, креденціал генерується в самій задачі, тож зовнішніх секретів
> вона не потребує й не пропускається), але доки її не додано в
> required checks обох гілок, **провалений E2E-тест відновлення мердж
> не блокує**. Документування адміністративного контролю не є його
> впровадженням: цей абзац оновлюється лише після фактичного
> ввімкнення, з новою датою перевірки.

Дозволене джерело промоції в `master` (`developer`/`hotfix/*` з
ЦЬОГО репозиторію, а не fork з однойменною гілкою) і семантичне
підняття stable-версії додатково контролює CI-гейт
`ci\Test-BRAVOMasterMergePolicy.ps1` (крок у required check
«Parser / BOM / JSON»), тож порушення політики блокує merge
технічно, а не лише процедурно.

---

## 14. CI-політика версій

CI повинен перевіряти гілку та значення `VERSION.json`.

Реалізація — `ci\Test-BRAVOReleasePolicy.ps1`, крок «Release policy
(branch / version / channel)» у `.github/workflows/ci.yml`. Той самий
скрипт можна запустити локально перед комітом:

```powershell
.\ci\Test-BRAVOReleasePolicy.ps1
```

### 14.1. Для `developer`

Обов'язкові умови:

```text
packageVersion matches:
^\d+\.\d+\.\d+-(dev|rc)\.\d+$

releaseChannel is:
development або prerelease
```

### 14.2. Для `master`

Обов'язкові умови:

```text
packageVersion matches:
^\d+\.\d+\.\d+$

releaseChannel is:
stable
```

### 14.3. Додаткові перевірки

CI також повинен перевіряти:

- відповідність `ModuleVersion` (базова частина версії, розділ 3.4);
- відповідність заголовків документації;
- наявність версії в `CHANGELOG.md`;
- актуальність `RUNTIME_MANIFEST.json`;
- актуальність `TOOLS_MANIFEST.json`;
- коректність JSON;
- відсутність заборонених секретів;
- успішний `BRAVO_SELF_TEST.ps1`;
- успішний PSScriptAnalyzer;
- відсутність stable-версії в `developer`;
- відсутність prerelease-версії в `master`.

### 14.4. Обов'язковий крок для змін конфігураційного пайплайна

`ci\Test-BRAVOConfigFoundationParity.ps1` — характеризаційний доказ того,
що зміна пайплайна завантаження конфігурації зберегла **повний** граф
`$global:`-змінних, а не лише вибіркові поля. Він навмисно не входить у
`BRAVO_SELF_TEST.ps1` — той набір мусить лишатись git-незалежним.

**Виконується автоматично** workflow-ом `.github/workflows/config-parity.yml`
для PR, що торкаються `BRAVO_CONFIG_LOADER.ps1`, `BRAVO.config`,
`BRAVO.local.config.example`, `modules/BRAVO.Configuration/`,
`modules/BRAVO.Configurator/` або самого harness. Доступний і вручну
(`workflow_dispatch`).

Причина автоматизації емпірична: доти запуск був обов'язковим лише «на
словах», і за шість merged PR конфігураційного пайплайна harness не
запускався жодного разу. Обов'язок без механізму не виконується.

**Це ще не required check.** Наявність задачі в CI не робить її
блокуючою — перелік required checks задається в налаштуваннях GitHub
(див. §13.3). Промоція цієї перевірки в блокуючу — свідоме рішення
власника, і приймати його варто після того, як прогін стабільно зелений.

Результат (паритет або повний перелік відмінностей із обґрунтуванням
кожної) лишається частиною доказової бази PR. Ручний запуск потребує
Windows PowerShell 5.1 і повного (не shallow) клону — у workflow це
забезпечено `fetch-depth: 0`, без якого коміт-база паритету недосяжна.

Базою за замовчуванням є **незмінний коміт**, а не ім'я гілки: allowlist
навмисних відмінностей прив'язаний саме до того стану, а прибирання
стале гілок не повинно мовчки позбавляти інструмент точки відліку.

Наслідок незмінної бази: поки лінія розробки йде вперед, **allowlist
зростає**. Кожен новий ключ конфігурації й кожне штампування версії
додають очікувану відмінність, і її треба внести поіменно з
обґрунтуванням. Це штатне обслуговування інструмента, а не ознака
регресії — але й не привід пропускати FAIL: перш ніж вносити шлях в
allowlist, треба довести, що поле **адитивне** (у базі його не існувало),
а не змінене. Найпростіший доказ — прогін harness на самому `developer`
без жодного PR: відмінності, що зʼявляються там, до PR стосунку не
мають.

Перепривʼязка бази на `master` або тег стане можливою лише після того,
як Configuration Foundation потрапить у stable: доти в `master` немає
навіть `modules/BRAVO.Configuration/`, і порівнювати не було б із чим.

---

## 15. Політика тегів

### 15.1. Development

```text
vX.Y.Z-dev.N
```

Приклад:

```text
v4.5.0-dev.1
```

### 15.2. Release Candidate

```text
vX.Y.Z-rc.N
```

Приклад:

```text
v4.5.0-rc.2
```

### 15.3. Stable

```text
vX.Y.Z
```

Приклад:

```text
v4.5.0
```

Теги повинні бути анотованими:

```bash
git tag -a v4.5.0 -m "BRAVO-Toolkit 4.5.0"
```

Перезапис опублікованих тегів заборонений.

---

## 16. Політика GitHub Releases

### Development та RC

```text
Pre-release: true
Latest release: false
```

### Stable

```text
Pre-release: false
Latest release: true
```

Stable-реліз повинен містити:

- номер версії;
- короткий опис;
- список ключових змін;
- список виправлень;
- відомі обмеження;
- інструкцію з оновлення;
- відомості про перевірений RC;
- перелік перевірених середовищ;
- checksum release artifact, якщо artifact публікується.

### 16.1. Незмінність опублікованих ассетів

Контракт: **один тег — один незмінний набір артефактів.**

`.github/workflows/release-artifact.yml` розрізняє два стани релізу:

| Стан релізу | Поведінка при повторному прогоні |
|---|---|
| **draft** | заміна згенерованих ассетів дозволена (ремонтний сценарій) — артефакт ще нікому не виданий |
| **опублікований**, той самий SHA-256 | no-op, успіх — повторний прогін лишається ідемпотентним |
| **опублікований**, інший SHA-256 | **FAIL**, жоден байт не замінюється |
| **опублікований**, ассета немає | доливається лише відсутній — це не заміна |

Звірка виконується завантаженням опублікованого ассета й обчисленням SHA-256,
а не читанням `.sha256`-супутника: супутник сам є ассетом і був би замінений
тим самим прогоном, який мав би стерегти.

Якщо перезбірка тега дає інші байти — це не привід замінити опублікований
артефакт, а привід випустити новий тег.

### 16.2. Захист тегів — адміністративна дія

Реліз запускається саме від `refs/tags/v*`, тож тег є коренем довіри всього
ланцюга «тег → артефакт → сервер установи». Для `refs/tags/v*` потрібен
GitHub ruleset, що забороняє видалення, force-update і тихе перестворення.

Це **налаштування GitHub**, а не код репозиторію: пункт не вважається
закритим, доки захист фактично не увімкнено (issue #151).

Точна конфігурація, щоб її не довелося щоразу відновлювати з пам'яті —
Settings → Rules → Rulesets → New ruleset → New tag ruleset:

| Параметр | Значення |
|---|---|
| Ruleset Name | `protected-release-tags` |
| Enforcement status | `Active` |
| Bypass list | порожній |
| Target tags → Include | `refs/tags/v*` |
| Restrict deletions | увімкнено |
| Restrict updates | увімкнено |
| Block force pushes | увімкнено |

`Restrict deletions` і `Restrict updates` разом закривають і тихе
перестворення: видалити тег, щоб створити його наново вже на інший
коміт, стає неможливо, тож пара «тег → опубліковані байти» лишається
однозначною. Порожній bypass-list тут принциповий — виняток для
адміністратора повернув би рівно той сценарій, який §16.1 закриває
кодом.

Код своєї половини контракту вже виконує: заміна опублікованого ассета
іншими байтами провалює workflow (§16.1), а форму виклику
`gh release upload` стереже регресія в `BRAVO_SELF_TEST.ps1`
(рівно один `--clobber`, і лише в draft-гілці). Незакритим лишається
саме ruleset — без нього тег можна пересунути, і тоді незмінність
ассетів захищає вже не той корінь довіри.

---

### 16.3. Prerelease у production і провенанс артефакту

**Два різні поняття, які доти змішувались.**

`VERSION.json.sourceCommit` у гілці розробки — **метадані гілки**. Вони
можуть відставати від `HEAD`: це прийнятно і навмисно, інакше кожен
мердж у `developer` породжував би stamp-коміт.

**Провенанс артефакту** — інше. Він мусить бути прив'язаний до точного
ref, з якого зібрано, і підтверджуватись джерелом, **незалежним від
самого архіву**. Таким джерелом є `release-manifest.json`: окремий ассет
релізу, який `ci\New-BRAVOReleaseArtifact.ps1` будує разом із zip і який
містить `packageVersion`, `releaseChannel`, `sourceCommit`, `buildId`,
`archiveCommit`, `tag` і SHA-256 самого архіву.

**Чому недостатньо `VERSION.json` усередині архіву.** Він підтверджує
лише той архів, у якому лежить. Комплект, зібраний не релізним
конвеєром, несе власний `VERSION.json` і виглядає автентично.

#### Політика розкатки

У production розгортається **stable**-реліз.

```text
releaseChannel = stable                          -> розгортається
releaseChannel != stable, без явного рішення     -> ВІДМОВА (fail-closed)
releaseChannel != stable, з -AllowPrereleaseChannel -> розгортається,
                                                    гучний запис
releaseChannel відсутній                         -> ВІДМОВА
```

Розгортання `prerelease` або `development` в установі вимагає **явного
рішення оператора** (`-AllowPrereleaseChannel` у
`deploy\Install-BRAVOServer.ps1` і `deploy\Update-BRAVOServer.ps1`) і
фіксації цього рішення в журналі розкатки.

Підстава не гіпотетична: сервер LIMS-TOP тривало працював у production
на `5.2.0-rc.2`, для якого в репозиторії **немає тега** — версія існує
лише комітом. Відтворити точний склад того комплекту можна лише
археологією історії, і жодна acceptance-процедура до нього не
прив'язана.

#### Канонічний власник політики

    deploy\BRAVO.Deploy.ReleaseGate.ps1

Обидва скрипти розкатки беруть рішення звідти. Другої копії цієї
політики в репозиторії бути не повинно — це закрито механічними
перевірками `Deploy/*` у self-test.

## 17. Матриця дозволених операцій

| Операція | `developer` | `master` |
|---|---:|---:|
| Розробка функцій | Так | Ні |
| Виправлення звичайних дефектів | Так | Ні |
| Security-виправлення | Так | Лише через hotfix |
| Development release | Так | Ні |
| RC release | Так | Ні |
| Stable release | Ні | Так |
| Тестування на реальному сервері | Так | Ні |
| Прямий push | Небажано | Заборонено |
| Merge `feature/*` | Так | Ні |
| Merge `developer` | Не застосовується | Так |
| Force push | Заборонено | Заборонено |

---

## 18. Приклад повного циклу

Поточний production:

```text
master: 4.4.2
```

Початок розробки:

```text
developer: 4.5.0-dev.1
```

Наступні development-релізи:

```text
4.5.0-dev.2
4.5.0-dev.3
```

Перший кандидат:

```text
4.5.0-rc.1
```

Після виправлень:

```text
4.5.0-rc.2
```

Після реальної серверної перевірки:

```text
master: 4.5.0
```

Після promotion:

```text
developer: 4.5.1-dev.1
```

---

## 19. Короткі обов'язкові правила

1. `developer` — лише розробка, тести та prerelease.
2. `master` — лише перевірені production-релізи.
3. `developer` і `master` мають різні версії.
4. Stable-реліз створюється лише з перевіреного RC.
5. Нові функції не додаються під час promotion.
6. Кожен RC перевіряється на реальному сервері.
7. Прямі push у `master` заборонені.
8. Hotfix обов'язково повертається в `developer`.
9. Development і RC GitHub Releases позначаються як Pre-release.
10. Stable GitHub Release позначається як Latest release.
11. Канал релізу зберігається у `VERSION.json`.
12. Не можна визначати канал лише через `.git/HEAD`.

---

## 20. Поточний стан

```text
master:    5.2.0       (stable, тег v5.2.0 = stamp b76a5ac,
           merge PR #102 = 477f166; metadata-only промоція
           2026-08-26 з прийнятого 5.2.0-rc.13)
developer: 5.3.0-dev.2 (development; 5.3.0-rc.1 залишається tagged
           candidate (v5.3.0-rc.1), pending acceptance, immutable —
           цикл 5.3.0 повернуто в development за явним рішенням
           власника, щоб внести P0 Configuration Foundation
           (feature-робота; §3.2 забороняє нові функції в RC).
           Наступний кандидат циклу (rc.2) включатиме й dev.1
           (P1.1 BRAVO_RESTORE_VERIFY + P2.1 status contract +
           FIX-пакет deferred-боргів), і новий P0 Configuration
           Foundation)
```

Дерево stable 5.2.0 = прийнятий `v5.2.0-rc.13` (stamp `0247ac3`,
sourceCommit `12e6370`) + non-runtime доповнення: acceptance-evidence
документ (PR #100) і governance-hardening PR #101 (repository identity
у гейті промоції master, регресії, branch protection `developer`,
синхронізація release-документації) — runtime functional diff проти
прийнятого rc.13 порожній.

Хронологія RC-циклу 5.2.0 (2026-08-24/25):

- `v5.2.0-rc.4`/`v5.2.0-rc.5` (лінія PR #83) — повний real-server
  acceptance PASS (`SERV_HRDL_1`, `WIN-44OBNQ3R3OB`).
- `v5.2.0-rc.6` — acceptance FAIL (фіксований поріг місця блокував
  backup); `v5.2.0-rc.7` (rc.5 + PR #84: розрахункова перевірка
  вільного місця з floor-override) — повний end-to-end acceptance PASS
  2026-08-25 (`WIN-42Q5558LQC9`: backup MODEL/BLOG/BRAVOEXCH,
  SFTP 7/7, Health OK).
- `v5.2.0-rc.8` (rc.7 + PR #86: регістронезалежна деривація відносних
  шляхів MODEL у Compare-FileSizes; закриває інцидент exit 43) —
  **acceptance реставрації PASS** 2026-08-25 22:03-22:24 на сервері
  інциденту (`LIMS`/ДНДІЛДВСЕ, `-ForceRestore`: bravocmd exit 0,
  Critical=0, Rollback=NONE, служби відновлено, Trace-pipeline OK).
- `v5.2.0-rc.9` (rc.8 + PR #88: живий підстатус консолі Maintenance +
  PR #89: logs pipeline v2 — усі `*.out` з кореня інсталяції,
  exchangAPI-архіви з оригінальними іменами на SFTP, структура
  `logs/trace`/`logs/exchangapi` з одноразовою автоміграцією `trace/`)
  — acceptance НЕ проводився: кандидата одразу замінено rc.10.
- `v5.2.0-rc.10` (rc.9 + PR #91: актуалізація release-документації +
  PR #92: семантичний гейт версії промоції в master і виключення
  `artifacts\` з генератора runtime-маніфесту) — acceptance НЕ
  проводився: кандидата одразу замінено rc.11.
- `v5.2.0-rc.11` (rc.10 + PR #94: компактні Maintenance-алерти —
  count + ≤5 прикладів замість повних діагностичних списків, повна
  діагностика лише в журналі — і глобальний payload guard notification-
  шару: safe limit 1800, одна подія → одне повідомлення на обох
  транспортах) — на acceptance 2026-08-26 виявлено дефект подвійної
  реставрації (нижче): кандидата замінено rc.12.
- `v5.2.0-rc.12` (rc.11 + PR #96: фікс подвійної реставрації після
  `-ForceRestore` — тижнева квота тепер покриває і «пропущений»
  минулий слот, `Test-BRAVORestoreWeeklyQuotaConsumed` з <= замість
  строгої рівності) — на acceptance зафіксовано UX-зауваження до
  прогресу реставрації: кандидата замінено rc.13.
- `v5.2.0-rc.13` (rc.12 + PR #98: підетапи у прогресі тривалих
  native-операцій — «<Фаза> — <Опис операції> — Виконується N сек.»;
  опис bravocmd-фази без прив'язки до продукту, з фактичним ім'ям
  проєкту моделі) — **фінальний кандидат циклу; acceptance PASS
  2026-08-26**: повний maintenance-цикл нової поверхні rc.9-rc.13 на
  двох реальних серверах (ДНДІЛДВСЕ Server 2022 / Львівська РДЛ,
  включно з хостом Server 2016 LegacyBestEffort) — перша бойова WinSCP
  MoveFile-міграція `trace/`→`logs/trace` 4/4, автостворення `logs/*`,
  скан реальних `*.out`-варіантів, компактні алерти, forced+normal
  реставрація в один вечір БЕЗ повтору; A2-encoding протокол
  (RELEASE_CHECKLIST §1.1) PASS в обох консольних контекстах
  (інтерактивно CP65001, SYSTEM CP866). Зведений evidence:
  `docs/BRAVO_520_RC13_ACCEPTANCE_EVIDENCE_20260826.md`.

Перенесено на 5.3.0 (додатково до P3.2a/M1/M3 нижче): три відкладені
Compare-FileSizes-фікси з локальної незапушеної гілки розробника
(settle-retry, AV-вікно 12×15с, надійна enumeration; збережено в
`backup/local-developer-rc2-line`) — механічний cherry-pick неможливий
(функцію двічі переписано в 5.2.0: main-model/сегменти,
регістронезалежні шляхи), а acceptance rc.8 на сервері інциденту
пройшов без settle-логіки; залишковий ризик — клас «антивірус тримає
файли MODEL одразу після bravocmd» на серверах з іншим AV. Там само
збережено `127e7e4` (діагностика очікування operation-lock) — кандидат
5.3.0. Решта локальних комітів тієї гілки верифіковано редундантні
(зміст уже в developer іншими комітами).

Stable `5.1.0` промотовано 2026-08-20 з прийнятого `5.1.0-rc.4`
(stamp `219c55b`, sourceCommit `d90c3c2`) після ПОВНОГО DEV-LIMS
acceptance того ж дня (evidence
`docs/BRAVO_DATA_RESTORE_RC4_DEVLIMS_ACCEPTANCE_20260820.md`, гілка
`evidence/219c55b-rc4-devlims-acceptance-pass`). Шлях циклу:
rc.1 (інвалідовано фічею DATA_RESTORE) → rc.2 (acceptance PASS, але
промоцію скасовано: виявлено відсутність порту severity-routing
PR #39) → rc.3 (порт routing; на acceptance виявлено, що DataRestore
шле повз routing) → rc.4 (фікс PR #62; повний acceptance PASS) →
stable 5.1.0.

Цикл `5.2.0-dev.1` відкрито одразу після промоції (розділ 11).
Записаний борг циклу: дедуплікація service-lifecycle / operation-lock /
WinSCP-session / ASCII-temp-root політик, декомпозиція
BRAVO.DataRestore Runtime.ps1, реалізація P3.2a (BRAVO_UPDATE.ps1).
Розведення імен push- та PR-checks у CI — ВИКОНАНО в dev.1 (під час
промоційного вікна 5.1.0 однойменний червоний push-run блокував
required checks гілки master, merge PR #61 виконано admin-обходом;
тепер required-контексти постачає лише pull_request-прогін, push-прогони
мають суфікс " (push)").

### Підготовка `5.2.0-rc.1` — рішення про scope (docs-only, без функціональних змін коду)

- **P3.2a (`BRAVO_UPDATE.ps1`) перенесено на `5.3.0`** (див.
  `ROADMAP.md` §P3.2a). Не входить у RC stabilization: нова поверхня
  атаки (download/staging/robocopy MIR/rollback/recovery), потребує
  власного acceptance, який не повинен блокувати вже готовий scope
  5.2.0. У коді 5.2.0 щодо P3.2a — нуль змін.
- **M3 (великий рефакторинг) не виконується у RC stabilization
  5.2.0.** Це стосується боргу циклу вище (dedup service-lifecycle/
  operation-lock/WinSCP-session, декомпозиція
  `BRAVO.DataRestore.Runtime.ps1`, перенесення Trace pipeline між
  модулями) і будь-якого іншого великого structural refactoring без
  конкретного production-дефекту — переноситься на наступний цикл
  (переважно `5.3.0`).
- **M1 (`WinSCP.uk` у `TOOLS_MANIFEST.json`) відкладено на `5.3.0`.**
  Bundled `WinSCP.exe` підтверджено версії `6.5.6.16502`
  (`FileVersionInfo`), що відповідає заявленому `WinSCP.uk`. Однак сам
  `WinSCP.uk` — не PE-файл із version resource, тому його версію/
  походження неможливо незалежно верифікувати з самого репозиторію.
  Генератор `ci/Update-BRAVOToolsManifest.ps1` і далі покриває лише
  `.exe/.dll/.com`; розширення allow-list на `.uk` і додавання
  `WinSCP.uk` у `TOOLS_MANIFEST.json` — окрема задача 5.3.0 після
  підтвердження походження файла.
- **Known issue (не блокер 5.2.0):** приватна
  `Get-BRAVOSevenZipArchiveInventory`
  (`modules/BRAVO.DataRestore/BRAVO.DataRestore.Runtime.ps1`) досі
  пише пароль у stdin через старий `Process.StandardInput.WriteLine`
  (BOM-даючий під UTF-8-консоллю), не мігрована на канонічний
  BOM-free `Write-BRAVOProcessInputText`. Функція й далі коректно
  читає СТАРІ (pre-5.2.0) архіви, але за певних умов консолі може НЕ
  прочитати НОВІ архіви (створені вже без BOM) під час free-space
  preflight реставрації. Мітигація зафіксована як борг циклу
  декомпозиції DataRestore (CHANGELOG, розділ dev.1) — не виправляється
  окремо в 5.2.0, щоб не змішувати вузько-скоуповий B2-фікс (легітимний
  compatibility-фікс) із частковою міграцією дублюючої реалізації
  (M3-подібний refactoring-ризик). *(Закрито в циклі 5.3.0: inventory
  став тонким адаптером над канонічною `Get-BRAVOSevenZipArchiveEntries`;
  гейт `Secrets/SevenZipPasswordUsesStdin` розширено на DataRestore.)*

### Функціональна зміна дефолту під час DEV-LIMS acceptance `5.2.0-rc.1`

- **`RepeatAlertAfterHours` (health-alert дедуп): дефолт `6` → `0`.**
  Виявлено під час реального DEV-LIMS acceptance (ДНДІЛДВСЕ,
  2026-08-23): при увімкненому `AutoArchiveMutationThreshold` оператор
  спостерігав лише перше сповіщення про `MUTATION_VIOLATION`, повторний
  ідентичний alert протягом наступних до 6 год. мовчав
  (`Test-AlertSuppressed`, `modules/BRAVO.Health/BRAVO.Health.Runtime.ps1`).
  Свідоме рішення: дедуп для alert-рівня (WARNING/ERROR/CRITICAL)
  вимикається за замовчуванням — кожен цикл, поки проблема триває,
  надсилає сповіщення заново, навіть якщо воно ідентичне попередньому.
  SUCCESS-звіт дедупу ніколи не підлягав (окрема гілка коду без
  fingerprint-перевірки) і цією зміною не зачіпається. Це функціональна
  зміна поведінки за замовчуванням (не docs-only), свідомо застосована
  до `5.2.0-rc.1` до завершення acceptance і публікації тега/artifact —
  вимагає перестемпування (`buildId`/`sourceCommit`/`RUNTIME_MANIFEST`)
  перед тегуванням. Деталі — `CHANGELOG.md` (`## 5.2.0-rc.1`, Upgrade
  notes).
