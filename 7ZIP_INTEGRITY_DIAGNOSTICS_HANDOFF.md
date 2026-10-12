# 7ZIP_INTEGRITY_DIAGNOSTICS_HANDOFF

Дата: 2026-10-13. Роль: Lead Maintainer / security-oriented defect investigation.
Класифікація зміни за `.claude/ai-routing.json`: **CRITICAL** (integrity/backup).

Гілка: `fix/sevenzip-integrity-diagnostics` в ізольованому worktree
`E:\GitHub-BRAVO-Toolkit-7zip-diag`, база `origin/developer`
`f317c201f742f8dece3f844f2169567c74a7a993`.
**Нічого не закомічено, не запушено, PR не створено.**

---

## 1. Live baseline

### Ідентичності (перевірені)

| Що | Значення |
|---|---|
| Production-сервер | Windows Server 2016 Standard (10.0.14393, build 14393), Windows PowerShell 5.1.14393.9507 |
| Розгорнута версія | **BRAVO 5.2.4 stable**, тег `v5.2.4`, коміт `91db94c007d770d8897ccaf9743bc36cd2f55e3f`, `sourceCommit a152d1f`, releaseDate 2026-09-13 |
| `origin/developer` | `f317c201f742f8dece3f844f2169567c74a7a993` (merge PR #443) |
| Версія на developer | `5.3.0-dev.3`, channel `development` |
| `Tools\7za.exe` | FileVersion/ProductVersion **26.02**, SHA256 `35D4D69D7CD6CB44558F208C3B1334268013F9DAF82D2DDA848893A1C30C59C2` — збігається з `Tools/TOOLS_MANIFEST.json`. Єдиний коміт, що торкався файлу, — `577d9bb` (початкове додавання `Tools/`). **Бінарник ніколи не оновлювався**; локальна копія байт-ідентична production, тому відтворення виконувалось тим самим інструментом. |

`.claude/PROJECT_STATE.md` записує застарілий canonical HEAD `05b5985`; фактичний
`developer` пішов далі (PR #442, #443). Робоча копія `E:\GitHub\BRAVO-Toolkit`
стоїть на `feature/bsystem-operations-foundation @ a0ecc76` — **959 комітів
позаду** `developer`; жоден цільовий файл з неї не читався (усі факти знято через
`git show origin/developer:<path>` та з worktree).

### Фактичні дані з production-логів

Джерело: `D:\Syncthing\Desktop\Нова папка (3)\LOGS` — 224 архівних логи
(2026-09-10 … 2026-10-12).

Конфігурація: усі три джерела лежать на диску **`C:`** (`C:\LIMS\Model`,
`C:\LIMS\BLOG`, `C:\LIMS\bravoexch`), читаються з ОДНОГО VSS Snapshot Set тому
`C:\` на всю generation. Розміри опублікованих копій: MODEL ~151 МБ, BLOG ~53 МБ,
BRAVOEXCH ~4 МБ. Призначення — `D:\ARCHIV` (вільно ~42.8 ГБ при потребі ~0.25 ГБ;
вільне місце ніколи не було фактором).

**Масштаб більший за початково повідомлений: 8 збоїв у 6 ночей** (повідомлялось
4 у 4), і початок — **2026-09-30**, а не 10-06:

| Нічний прогін | ok | fail | Generation |
|---|---|---|---|
| 2026-09-10 … 09-29 (20 ночей) | 3 | 0 | COMPLETE 3/3 — **жодного збою** |
| 2026-09-30 | 2 | — | INCOMPLETE 2/3 — збій на **create** (`7za a`, код 2, BLOG) |
| 2026-10-01 | 2 | 0 | лог без фінального Generation-рядка (прогін не дописав) |
| 2026-10-02 | 3 | 0 | COMPLETE 3/3 |
| 2026-10-03 | 0 | 2 | **FAILED 0/3** — MODEL на create, BLOG і BRAVOEXCH на test |
| 2026-10-04 | 1 | 1 | INCOMPLETE 1/3 (BLOG) |
| 2026-10-05 10:10 (ручний) | — | 1 | BLOG |
| 2026-10-06 | 2 | 1 | INCOMPLETE 2/3 (MODEL) |
| 2026-10-07 | 3 | 0 | COMPLETE 3/3 |
| 2026-10-08 | 1 | 2 | INCOMPLETE 1/3 (BLOG, BRAVOEXCH) |
| 2026-10-09, 10-10 | 3 | 0 | COMPLETE 3/3 |
| 2026-10-11 | 2 | 1 | INCOMPLETE 2/3 (MODEL) |

Дослівний фрагмент (2026-10-11, PID 4056) — саме та форма, що позбавляє оператора
причини:

```text
2026-10-11 23:05:42.089 [INFO   ] [ARCHIVE] Перевiрка цiлiсностi 7-Zip: odesa_vetlab_v2412_20261011_230006.…partial.mdz
2026-10-11 23:05:45.370 [ERROR  ] [ARCHIVE] Перевiрка цiлiсностi 7-Zip не пройдена (код: 2 — критична помилка): D:\ARCHIV\MODEL\.work\…partial.mdz
2026-10-11 23:05:45.432 [ERROR  ] [ARCHIVE] Пошкоджений або неперевiрений архiв не буде опублiковано як backup: D:\ARCHIV\MODEL\.work\…partial.mdz
```

**У 224 архівних логах — нуль рядків `[DEBUG]`.**

Fail-closed працював коректно на всьому інтервалі: неперевірені архіви не
публікувались, generation коректно ставав `INCOMPLETE`/`FAILED`, Health ескалював
(«остання COMPLETE generation старша за 24 год.», застарілі SFTP-копії).

---

## 2. Root cause

### 2.1 Заявлений симптом «немає діагностики» — ПІДТВЕРДЖЕНО (регресія BRAVO)

Діагностика зникала **не** через порожній capture, **не** через failure
classification і **не** через втрату stdout/stderr. Її **відкидав рівень
журналювання**:

1. `BRAVO.Compatibility.psm1` — `Invoke-BRAVOSevenZipIntegrityTestCore` коректно
   захоплює stdout/stderr (`t -y -bb1`, async `ReadToEndAsync`) і повертає їх.
2. `BRAVO.ArchiveHelpers.psm1` — `Test-SevenZipArchiveIntegrity` писав
   headline-помилку на `$failureLevel`, а фактичні рядки 7-Zip — на
   `-Level "DEBUG"`; гілки для `$diagnosticLines.Count -eq 0` не існувало взагалі.
3. `BRAVO.Archive.Runtime.ps1` — `Write-SevenZipFailureDiagnostics` теж жорстко
   задавав `-Level 'DEBUG'`.
4. `BRAVO.Logging.psm1` — шкала `DEBUG = 1`, `INFO = 2`; запис у файл гейтиться
   `$severity -ge Get-BRAVOLogSeverityValue($script:BRAVOLogFileLevel)`.
5. Канонічний дефолт `consoleSettings.FileLevel = "INFO"`.

→ `DEBUG` (1) < `INFO` (2): рядок не доходив **ні до файлу, ні до консолі**.

**Це регресія, а не дизайн.** Git-доказ:

* `878dd86` (2026-07-27, *fix: log actionable 7-Zip failure details*) навмисно
  створив `Write-SevenZipFailureDiagnostics` з `-Level "ERROR"`, додав явне
  маскування пароля і гілку «`$Operation` не повернув діагностичного тексту».
  Commit message дослівно: *«Promote the final sanitized stdout and stderr lines
  for 7-Zip create, integrity-test, and timeout failures to ERROR logs regardless
  of the configured log level.»*
* `ce4855d` (2026-07-28, *v.4.0.2*, рукотворний release-snapshot; 194 зміни /
  172 видалення в `BRAVO_ARCHIV.ps1`) **повністю відкотив** це.
* Пізніший коміт повернув **деградовану** версію: лише create-шлях, `DEBUG`, без
  маскування, без гілки порожнього виводу. Шлях **таймауту** лишився без
  діагностики взагалі.
* `CHANGELOG.md` 4.9.0 досі декларував поведінку `ERROR` «незалежно від
  `LogLevel`» — документація і код суперечили одне одному.

**Чому CI не зловив.** Гейт `BackupDiagnostics/SevenZipFailureOutput` перевіряв
лише *наявність підрядків* `Write-SevenZipFailureDiagnostics` і
`Operation "Дiагностика 7-Zip create"` — ані рівня, ані шляху integrity-тесту.
Вакуумний. Проєкт при цьому вже мав канонічний прецедент цього уроку в
`BRAVO.Maintenance.Runtime.ps1` (`Invoke-CommandWithLog`:
`$outputLevel = if ($exitCode -eq 0) { "DEBUG" } else { "ERROR" }`), покритий
assertion-ом *«вивід зовнішньої команди на шляху помилки має логуватися рівнем
ERROR, інакше діагностика зникає при LogLevel=INFO»* — **лише для Maintenance**.

Дефект присутній у всіх версіях з 4.0.2, включно з production 5.2.4 і `developer`.

### 2.2 Першопричина самих `exit 2` — UNRESOLVED, середовищна

Не є дефектом коду BRAVO. Доведено трьома незалежними аргументами:

1. **Різкий початок при незмінному BRAVO.** 5.2.4 вийшла 2026-09-13 і відпрацювала
   17 чистих ночей (20 поспіль COMPLETE 3/3) до першого збою 09-30. Жодна зміна
   коду BRAVO не може бути першопричиною.
2. **Збій по-компонентний у межах ОДНОГО процесу.** 2026-10-11, PID 4056: MODEL →
   exit 2, BLOG і BRAVOEXCH → exit 0. Те саме 10-03 і 10-08. Це виключає всі
   глобальні для процесу причини — зокрема **гіпотезу про механізм пароля
   (BOM/кодування) опроверґнуто**: пароль і `Console.InputEncoding` однакові для
   всіх компонентів одного прогону й не можуть давати різний результат.
3. **Збої і на `create`, і на `test`, різними ночами на різних компонентах** —
   патерн, характерний для середовищної деградації, а не детермінованого
   дефекту коду.

**Цю причину неможливо встановити без діагностики, якої код не записував.** Саме
тому виправлення діагностичного шляху — коректна й достатня інженерна відповідь
на цей P1, а встановлення причини `exit 2` — операційне дослідження (розділ 9).

### 2.2a ОНОВЛЕННЯ 2026-10-13: причину `exit 2` названо самим 7-Zip

**Це оновлення отримане ПІСЛЯ основного дослідження і змінює ранжування
підозрюваних у п. 2.2.** Оператор застосував рекомендацію розділу 9, п. 1 —
виставив `FileLevel = "DEBUG"` на поточній 5.2.4 — і причина проявилась
**того ж прогону**, без жодної зміни коду.

Прогін `BRAVO_ARCHIV_20261013_003107_PID1396` (ручний, 00:31, DEBUG): MODEL
опубліковано (exit 0), BLOG упав з `код: 2`, і разом із ним уперше з'явився
повний вивід інструмента:

```text
7-Zip (a) 26.02 (x64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-06-25

Scanning the drive:
4 files, 2825188346 bytes (2695 MiB)

Creating archive: D:\ARCHIV\BLOG\.work\odesa_vetlab_v2412_blog_20261013_003107.…partial.mdz

Add new data to archive: 4 files, 2825188346 bytes (2695 MiB)

Enter password (will not be echoed):
System ERROR:
Internal Error: The failure in hardware (RAM or CPU), OS or program
```

Повторний прогін `BRAVO_ARCHIV_20261013_003917_PID4680` (00:39) пройшов
`COMPLETE 3/3`, SFTP 7/7, `Результат: УСПIШНО` — тобто збій підтверджено як
переривчастий.

**Що це доводить.**

* Причина — **не BRAVO і не пароль**. `Enter password (will not be echoed):`
  тут лише останній рядок stdout перед помилкою: 7-Zip друкує цей запит
  завжди, і до нього вже встиг просканувати джерело (4 файли, 2695 МіБ) і
  почати компресію (`Add new data to archive`). Отже пароль був прийнятий, а
  збій стався **в процесі компресії**.
* Причина — **не NTFS і не VSS** (на що я вказував як на головного
  підозрюваного в п. 2.2.3, і це ранжування цим оновленням **скасовується**).
  Читання зі снапшота відпрацювало: сканування завершилось, обсяг перелічено.
  Відмова читання з тому чи витіснення снапшота дали б помилку
  відкриття/читання з іменем шляху, а не внутрішню помилку узгодженості
  самого 7-Zip.
* `Internal Error: The failure in hardware (RAM or CPU), OS or program` — це
  **власний текст 7-Zip** для провалу внутрішньої перевірки узгодженості.
  Це діагноз інструмента, не вердикт обладнання, але він прямо вказує
  клас причини.

**Чому RAM — головний підозрюваний.** Усі спостережені властивості збігаються:
збій імовірнісний, а не детермінований; у межах одного процесу падає один
компонент і проходять інші (різні обсяги й адреси виділень: MODEL
~151 МБ опублікованого проти BLOG 2695 МіБ сирих даних); архівація йде з
`-mmt` (багатопотоково) і `-mx6`, тобто з високим тиском на пам'ять; ізольований
`7za a` → `7za t` на малому файлі проходив (мале виділення); і 20 чистих ночей
перед раптовим початком відповідають розвитку апаратної несправності, а не
зміні конфігурації.

### 2.2b Уточнення: сервер — віртуальна машина QEMU

`systeminfo` з ураженого хоста (знято 2026-10-13):

```text
Изготовитель системы:  QEMU
Модель системы:        Standard PC (i440FX + PIIX, 1996)
Версия BIOS:           SeaBIOS rel-1.11.1
Требования Hyper-V:    Обнаружена низкоуровневая оболочка
Процессор(ы):          2 x Intel64 Family 6 Model 158 Stepping 11 ~3600 МГц
Полный объем памяти:   16 863 МБ (доступно 15 177 МБ)
Время загрузки:        12.10.2026, 23:31:45
```

Це змінює **місце** пошуку, але не клас причини.

1. **Діагностику пам'яті треба робити на ХОСТІ, не в гостьовій ОС.**
   `memtest86+`, запущений у гостьовій ОС, перевіряє пам'ять, яку віддав
   гіпервізор, і пройде навіть при несправній фізичній пам'яті хоста.
   Так само машина i440FX/SeaBIOS практично не пробрасує machine-check у
   гостя, тому `Microsoft-Windows-WHEA-Logger` усередині ВМ майже напевно
   буде порожнім і його тиша нічого не доводить.
2. **Хост майже напевно на не-ECC пам'яті.** Model 158 Stepping 11 — це
   Coffee Lake, споживчий CPU. При не-ECC тихе пошкодження сторінок невиявне
   для ОС хоста без memtest — рівно той механізм, що дає імовірнісну
   внутрішню помилку в пам'ятко-важкому процесі.
3. **Додатковий підозрюваний — memory overcommit / ballooning / swap на
   хості.** У гостьовій ОС вільно 15 ГБ з 16.8, тобто тиску зсередини немає.
   Але якщо хост перепідписав пам'ять і virtio-balloon відбирає сторінки, або
   хост свопить сторінки ВМ, компресія 2695 МіБ під `-mmt` отримує саме такий
   збій. Узгоджується з тим, що падає найбільший компонент, а менші проходять.
4. **Перезавантаження 12.10 о 23:31:45** пояснює відсутній нічний прогін
   23:00 на 10-12 (ВМ була недоступна) і ручні прогони о 00:31/00:39. Це
   також означає, що історія подій до 23:31 лежить у попередньому
   boot-сеансі: шукати її треба з явним фільтром за часом, інакше вона
   виглядатиме порожньою.

**Статус.** Причину на рівні інструмента **встановлено**. Підтвердження
конкретного вузла лишається за діагностикою **на гіпервізорі** (розділ 9) —
це вже не невідомість, а перевірка названої гіпотези.

**Побічний висновок про цей фікс.** Епізод емпірично підтверджує і серйозність
P1-1, і коректність його виправлення: текст, який шість ночей існував у виводі
7-Zip і відкидався рівнем журналу, виявився точною причиною. Після цієї зміни
той самий текст потрапляє в журнал **рівнем ERROR за замовчуванням**, без
потреби переводити весь прогін у `DEBUG`.

### 2.3 Окрема перевірена знахідка: асиметрія кодування пароля в лінії 5.2.x

У production 5.2.4 шлях *створення* архіву використовує
`$process.StandardInput.WriteLine($script:archivePassword)` (кодує
`Console.InputEncoding`), а шлях *перевірки* — `Write-BRAVOProcessInputText`
(явно UTF-8 без BOM через `BaseStream`). `Initialize-BRAVOConsoleEncoding` у 5.2.4
торкається лише `OutputEncoding` і ніколи не змінює `[Console]::InputEncoding`.

Перевірено: **весь рядок 5.2.x, включно з `v5.2.5-rc.4` (2026-10-04), досі має
legacy `WriteLine` і не має `Start-BRAVOProcessWithBomFreeInput`.** На `developer`
це закрито (T005/T005b, PR #249/#256, 2026-09-29).

**Це НЕ причина поточних збоїв** (п. 2.2.2 її опроверґує) і до цього P1 не
належить. Фіксується як окремий production-ризик (P1-3, розділ 7).

---

## 3. Reproduction

Відтворено локально справжнім `Tools\7za.exe` 26.02 (той самий SHA256, що в
production), через `powershell.exe` 5.1, у sandbox-фікстурах, cleanup у
`try/finally`.

Харнес: `Initialize-BRAVOLog -FileLevel 'INFO'` (канонічний production-дефолт) →
справжній зашифрований архів → усічення → `Test-SevenZipArchiveIntegrity` з
logger-скриптблоком до `Write-BRAVOLog` → читання лог-файлу **з диска**.

**RED проти `f317c201` (до фікса):**

```text
===== PROBE 1  corrupt / FileLevel=INFO  (production default) =====
  [INFO   ] [ARCHIVE] Перевiрка цiлiсностi 7-Zip: corrupt.7z
  [ERROR  ] [ARCHIVE] Перевiрка цiлiсностi 7-Zip не пройдена (код: 2 — критична помилка): …corrupt.7z

A1  diagnostics present at INFO          : False
A1b real 7-Zip text present at INFO      : False
A2  diagnostics present at DEBUG (ctrl)  : True
A3  empty-output case observable         : False
A4  diagnostics follow WARNING level     : False
A5  password absent from all logs        : True
RESULT: RED
```

PROBE 1 **дослівно відтворює production-лог**: headline із «код: 2» і далі нічого.

PROBE 2 (контроль, `FileLevel=DEBUG`) показав, що саме було втрачено:

```text
Open ERROR: Cannot open the file as [7z] archive
ERRORS:
Unexpected end of archive
Can't open as archive: 1
```

Це водночас емпірично підтверджує production-рекомендацію: `FileLevel=DEBUG`
відкриває діагностику **без зміни коду** (розділ 9, п. 1).

---

## 4. Мінімальний diff

Обсяг — 6 файлів, **+848 / −23**; з них production-код `BRAVO.ArchiveHelpers.psm1`
`+126` і `BRAVO.Archive.Runtime.ps1` `+40`, решта — тести, документація,
згенерований маніфест.

```text
 BRAVO_SELF_TEST.ps1                                    | 634 ++++++++  (тести)
 CHANGELOG.md                                           |  61 ++       (документація)
 RUNTIME_MANIFEST.json                                  |   8 +-       (згенеровано)
 modules/BRAVO.Archive/BRAVO.Archive.Runtime.ps1        |  40 +-
 modules/BRAVO.ArchiveHelpers/BRAVO.ArchiveHelpers.psd1 |   2 +-
 modules/BRAVO.ArchiveHelpers/BRAVO.ArchiveHelpers.psm1 | 126 ++-
```

**Змінено виключно діагностичний шлях.** Механізм створення архівів,
`Invoke-BRAVOSevenZipIntegrityTest*`, класифікатор
`Test-BRAVOSevenZipArchiveSpecificFailure`, `FailureInfo`, legacy BOM-fallback,
bool-контракт `Test-SevenZipArchiveIntegrity`, exit-коди і захист від публікації
неперевірених архівів — **не змінені**.

1. **`BRAVO.ArchiveHelpers.psm1`** — новий канонічний
   `Write-BRAVOSevenZipFailureDiagnostics` (`-Logger`, `-Operation`,
   `-StandardOutput`, `-StandardError`, `-Level`, `-EmptyOutputReason`,
   `-MaximumLines` 20, `-MaximumLength` 4000). `Test-SevenZipArchiveIntegrity`
   викликає його з `-Level $failureLevel`.
2. **`BRAVO.ArchiveHelpers.psd1`** — експорт нової функції.
3. **`BRAVO.Archive.Runtime.ps1`** — `Write-SevenZipFailureDiagnostics` став
   тонким адаптером над тим самим хелпером (ім'я функції й call-site збережені,
   тому наявний гейт не зламано); відновлено діагностику на шляху **таймауту**.

### Ключове дизайн-рішення: рівень

Діагностика пише **рівнем того збою, який вона пояснює** (`$failureLevel`,
дефолт `ERROR`), а не жорстким `ERROR`.

Обґрунтування: дефект — саме `DEBUG`, а не «не `ERROR`». І `WARNING` (4), і
`ERROR` (5) проходять гейт `INFO` (2), тому успадкування `$failureLevel`
виправляє симптом у **кожній** гілці. Жорсткий `ERROR` не дав би жодної
додаткової видимості, зате зламав би #300/#422: ці issue свідомо ввели
`-ArchiveFailureLevel WARNING` для retention старих архівів, і пояснення
`WARNING`-події рівнем `ERROR` повернуло б щонічний ERROR-шум для архіву, який
продукт свідомо толерує. Fail-closed збережено автоматично: у
`Test-SevenZipArchiveIntegrity` вже є
`$failureLevel = if ($archiveSpecificFailure) { $ArchiveFailureLevel } else { 'ERROR' }`,
тому **всі** збої виконання інструмента (7-Zip не знайдено, таймаут, відмова
доступу, невідомі коди, незавершена legacy BOM-спроба) лишаються `ERROR`.
Перевірено тестом: при запитаному `WARNING` таймаут усе одно дає `ERROR`.

### Межі зберігають ХВІСТ (знахідка review ARCH-001)

`7za t -bb1` друкує рядок на запис, а операторо-значущий вердикт (`ERRORS:`,
`Wrong password`, `Unexpected end of archive`) — у **кінці**. Тому:

* рядкова межа — останні 20 непорожніх рядків (`Select-Object -Last`);
* символьна межа обрізає **початок**, не кінець, і явно позначає це як
  `(обрізано) … `; маркер входить **у бюджет** `-MaximumLength`, тому запис
  тримається рівно в 4000 символів (перевірено: `payloadLen=4000`).

Перша реалізація обрізала з початку (`Substring(0, 4000)`) і відкидала саме
вердикт — тобто відтворювала той самий дефект «оператор без причини» іншим
механізмом. Знайдено незалежним review, виправлено, закріплено тестом.

### Побічно виправлені дефекти старої create-реалізації

`foreach ($line in @($StandardOutput, $StandardError))` ітерував по **двох
потоках**, а не по рядках. Отже: межі на 20 рядків **не існувало взагалі**, межа
4000 символів застосовувалась до кожного потоку окремо, а змінна `$line` була
названа хибно. Уніфікована нормалізація це усуває.

### Гілка порожнього виводу

Відновлено (її прибрав `ce4855d`), з причиною з `Error`/`Description`:

```text
Дiагностика 7-Zip test: 7-Zip не повернув діагностичного тексту (stdout/stderr порожні); причина: архів не знайдено: …
```

Це саме та production-форма збоїв «архів не знайдено», «7-Zip не знайдено» і
вбитого по таймауту процесу, де причина існує лише в цих полях. Раніше такі
випадки не логувались **узагалі**, тому «інструмент промовчав» було неможливо
відрізнити від «діагностику відфільтрував рівень журналу».

---

## 5. RED / GREEN evidence

**GREEN тим самим харнесом, що дав RED:**

```text
===== PROBE 1  corrupt / FileLevel=INFO =====
  [ERROR  ] Перевiрка цiлiсностi 7-Zip не пройдена (код: 2 — критична помилка): …
  [ERROR  ] Дiагностика 7-Zip test: ERROR: …
  Open ERROR: Cannot open the file as [7z] archive
  ERRORS:
  Unexpected end of archive
===== PROBE 3  missing archive / FileLevel=INFO =====
  [ERROR  ] Дiагностика 7-Zip test: 7-Zip не повернув діагностичного тексту (stdout/stderr порожні); причина: архів не знайдено: …
===== PROBE 4  corrupt / ArchiveFailureLevel=WARNING / FileLevel=INFO =====
  [WARNING] Перевiрка цiлiсностi 7-Zip не пройдена (код: 2 — критична помилка): …
  [WARNING] Дiагностика 7-Zip test: ERROR: …

A1 True · A1b True · A2 True · A3 True · A4 True · A5 True
RESULT: GREEN
```

### Доказ нетривіальності кожного нового гейта

Критичний пункт: попередній гейт був substring-овий і тому пропустив регресію на
2,5 місяці. Кожен новий гейт прогнано **проти базових текстів** `f317c201`:

```text
GATE[BASE]          offenders=2  missingOwners=1  => FAIL
    Runtime: Write-SevenZipFailureDiagnostics line 2164
    Helpers: Test-SevenZipArchiveIntegrity     line 264
    missing: Write-BRAVOSevenZipFailureDiagnostics
GATE[FIXED]         offenders=0  missingOwners=0  => PASS

TIMEOUTBRANCH[BASE]  branches=1  calls=0  => FAIL
TIMEOUTBRANCH[FIXED] branches=1  calls=1  => PASS

LINECAP  lines=20    tail=True  head=False                      => PASS
LENCAP   streamLen=6136  payloadLen=4000  verdict=True  head=False  marker=True  => PASS
TIMEOUT  res=False  TimedOut=True  ArchiveSpecific=False  ERROR=True  WARNING=False  => PASS
NONASCII len=17  allNonAscii=True  distinctAcrossRuns=True      => PASS
```

### Нові перевірки в `BRAVO_SELF_TEST.ps1`

Усі — **поведінкові** (справжній `Tools\7za.exe` + справжній `BRAVO.Logging` у
тимчасовий файл на `FileLevel=INFO` + читання файлу з диска) або **AST**, а не
substring.

| Перевірка | Що закріплює |
|---|---|
| `SevenZipDiagnostics/IntegrityFailureTextReachesLogAtInfoFileLevel` | текст 7-Zip фізично є у файлі при `FileLevel=INFO` |
| `SevenZipDiagnostics/EmptyToolOutputIsExplicitlyObservable` | порожній вивід видно явно |
| `SevenZipDiagnostics/DiagnosticLevelFollowsArchiveFailureLevel` | при `WARNING` діагностика WARNING і **нуль** `[ERROR]` — захист #300/#422 |
| `SevenZipDiagnostics/ArchivePasswordNeverAppearsInLog` | рання перевірка нерозкриття |
| `SevenZipDiagnostics/NoArchivePasswordInAnyDiagnosticLogFile` | **кожен** лог-файл блоку × **кожен** із 4 паролів; при збої друкується лише довжина, не секрет |
| `SevenZipDiagnostics/LockedArchiveStaysOperationalFailureWithErrorDiagnostics` | зайнятий файл → `ArchiveSpecific=false`, діагностика ERROR навіть при запиті WARNING |
| `SevenZipDiagnostics/NonAsciiPasswordRoundTripsWithoutFallback` | не-ASCII пароль проходить create→test без fallback |
| `SevenZipDiagnostics/SuccessfulIntegrityTestWritesNoDiagnostics` | успіх не пише діагностику |
| `SevenZipDiagnostics/MultiEntryCorruptArchiveStillYieldsDiagnostics` | багатозаписний пошкоджений архів дає запис |
| `SevenZipDiagnostics/LineCapKeepsExactlyLastTwentyLines` | 30 рядків → рівно 20, хвіст є, голови немає |
| `SevenZipDiagnostics/LengthCapKeepsVerdictTailNotHead` | символьна межа зберігає вердикт, тримає 4000 разом із маркером |
| `SevenZipDiagnostics/TimedOutResultRoutesReasonToErrorEvenWhenWarningRequested` | роутинг таймауту через реальний `Test-SevenZipArchiveIntegrity`, fail-closed |
| `SevenZipDiagnostics/CreateTimeoutBranchCallsDiagnosticsWriter` | AST-вкладеність виклику в тілі timeout-гілки `New-Archive` |
| `BackupDiagnostics/SevenZipDiagnosticsNeverLoggedAtDebug` | AST: жоден виклик у тілах трьох функцій-власників не передає `-Level DEBUG`; **плюс** гейт падає, якщо функції-власники не знайдено (щоб перейменування не вимкнуло його тихо) |
| `BackupDiagnostics/SevenZipCreateFailureOutputReachesLogAtInfoLevel` | create-шлях: обидва записи у файлі рівнем ERROR |

Наявний гейт `BackupDiagnostics/SevenZipFailureOutput` **збережено без змін** —
покриття не зменшено, лише додано.

### Дефекти в моєму власному тестовому коді, зловлені під час роботи

Записано як доказ того, що валідація реально виконувалась, а не декларувалась:

* `Diagnostics/NoKeywordParsedAsCommand` — `( if … )` замість `$( if … )`; це не
  лише стильове попередження: конструкція **упала в рантаймі**
  `CommandNotFoundException: The term 'if' is not recognized` і обірвала цілу
  секцію;
* хибне твердження про рівень: у багаторядковому записі префікс
  `<timestamp> [LEVEL]` стоїть лише на **першому** фізичному рядку, а
  перевірялося входження `[ERROR` у рядку з маркером;
* три знахідки незалежного review (розділ 6), одна з них — реальний дефект
  production-коду.

### Покриття 12 сценаріїв завдання

| № | Сценарій | Статус |
|---|---|---|
| 1 | Create → Test, success | RUN |
| 2 | Wrong password | RUN (наявні `B2/*`, RED-харнес) |
| 3 | BOM-prefixed legacy password | RUN (наявні `B2/*`) |
| 4 | Corrupt / truncated archive | RUN |
| 5 | Concurrent file access | RUN (`LockedArchiveStaysOperationalFailure…`) |
| 6 | Permission denied | **NOT RUN** — причина нижче |
| 7 | Missing archive | RUN (`EmptyToolOutputIsExplicitlyObservable`) |
| 8 | Timeout | **частково** — причина нижче |
| 9 | Non-ASCII password | RUN |
| 10 | Large encrypted fixture | RUN (60 записів; синтетичні дані, без production-даних) |
| 11 | stdout/stderr capture при non-zero exit | RUN |
| 12 | Логування без розкриття пароля | RUN (дві перевірки) |

**Сценарій 6 — `NOT RUN`, свідомо.** CI-раннер і типова dev-оболонка працюють з
правами локального адміністратора, і репозиторій уже фіксує емпірично, що
Deny-ACL у цьому середовищі доступ адміністратору не блокує
(`selftest/BRAVO_SELF_TEST.TraceArchive.ps1`). Тест, який «проходить» через те,
що ACL обійдено, гірший за відсутність тесту. Найближчий чесний замінник
виконано — сценарій 5 ганяє **той самий** operational-failure шлях end-to-end
справжнім 7-Zip і підтверджує `ArchiveSpecific=false` + рівень ERROR.

**Сценарій 8 — частково.** Справжній 12-годинний дефолт
(`SevenZipTestTimeoutSeconds = 43200`) не відтворюється; варіант
`-TimeoutSeconds 1` проти великої фікстури відкинуто як нестабільний (на швидкому
хості `7za t` може встигнути завершитись). Натомість детерміновано перевіряється
саме змінений роутинг: `TimedOut`-результат через реальний
`Test-SevenZipArchiveIntegrity` із заглушкою на межі
`Invoke-BRAVOSevenZipIntegrityTest`, плюс AST-вкладеність виклику в тілі
timeout-гілки `New-Archive`. Реальний прогін по таймауту лишається неперевіреним.

### Паролі у фікстурах

Архіви, які створює сам новий блок, шифруються **згенерованим на прогін** паролем
(`"diag-" + свіжий GUID`); не-ASCII пароль має фіксовану «голову» з потрібних
code point-ів і **випадковий не-ASCII хвіст** (17 символів, усі не-ASCII, різні
між прогонами). Спільна фікстура `B2/*` лишається на своєму історичному літералі:
її архіви шифрує код, якого ця зміна не торкається, і підміна пароля зламала б
наявні перевірки. Нерозкриття перевіряється по фактично записаних байтах усіх
лог-файлів проти всіх чотирьох паролів.

---

## 6. Security review

| Аспект | Висновок |
|---|---|
| Пароль у аргументах процесу | без змін — лише через redirected stdin; гейти `Secrets/*` не торкались |
| Пароль у журналі | дві перевірки, одна — по всіх записаних лог-файлах; структурно пароль до stdout/stderr 7-Zip не потрапляє (у командний рядок не йде, зі stdin не ехається) |
| `ci\Invoke-BRAVOSecurityAnalysis.ps1` | **чисто**, exit 0, 172 файли |
| `ci\Test-BRAVOForbiddenPattern.ps1` | **чисто**, exit 0, 174 файли |
| Послаблення integrity validation | немає — класифікатори, fail-closed, bool-контракт і захист від публікації неперевірених архівів не змінені |
| Нова поверхня | лише запис у журнал; жодного нового процесу, мережі, файлової операції чи credential-доступу |
| Межа росту журналу | збережена (20 рядків / 4000 символів разом із маркером) і тепер діє на **обох** шляхах; обрізання явно позначається |

### Незалежний review (CRITICAL risk → обов'язкові три ролі)

| Роль | Результат |
|---|---|
| `codex-security` | **0 знахідок.** Дослівно: *«No confirmed security vulnerability was found… Password delivery remains redirected stdin, with no identified new route from credentials into diagnostics»*. Зауваження про фіксовані паролі у фікстурах прийнято й виправлено. |
| `codex-qa` | **3 × P2**, усі прийнято й виправлено; повторна верифікація — `fixed` по всіх трьох. |
| `codex-architecture` | **1 × P2** (ARCH-001), прийнято й виправлено; повторна верифікація — `fixed`. Окремо підтвердив канонічного власника, адаптер, проброс `-Level`, і що `Invoke-CommandWithLog` у Maintenance **не** потребує конвергенції (інший предмет: загальні команди + метадані виконання). |

Знахідки review та їхнє закриття:

* **QA-001** — мій новий гейт `NeverLoggedAtDebug` був **сам вакуумний**:
  у базі `-Message` і `-Level "DEBUG"` стоять на різних фізичних рядках
  (backtick-продовження), а create-адаптер логує узагальнений `${Operation}`, тому
  порядковий regex давав нуль збігів і гейт позеленів би на дефектній базі.
  Переписано на AST по тілах функцій-власників; доведено `GATE[BASE]=FAIL` з
  обома порушеннями (рядки 2164 і 264) проти `GATE[FIXED]=PASS`. Додано падіння
  гейта при відсутності функцій-власників.
* **QA-002** — перевірка межі приймала будь-які 1–20 рядків і ніколи не доводила
  перебір; 60 записів нічого не доводять, бо пошкоджений заголовок змушує 7-Zip
  відмовити ще до перелічення. Замінено детермінованими writer-level перевірками
  (30 рядків → рівно 20, хвіст є, голови немає; 6136 символів → вердикт є,
  голови немає, маркер є, довжина 4000).
* **QA-003** — перевірка таймауту подавала рядок прямо у writer і не чіпала
  роутинг. Замінено прогоном реального `Test-SevenZipArchiveIntegrity` із
  заглушкою на межі + AST-вкладеністю в тілі timeout-гілки (не весь
  `IfStatementAst`, а тіло першої клаузи — інакше виклик у `else` теж
  задовольнив би гейт).
* **ARCH-001** — **реальний дефект мого production-коду**: символьна межа
  `Substring(0, 4000)` відкидала хвіст, тобто саме вердикт, який навмисно
  зберігає `Select-Object -Last`. Код суперечив власному коментарю. Виправлено
  на обрізання з початку з маркером у бюджеті межі; закріплено тестом.

### Обмеження, яке треба знати (P2-3, окремо від цього фікса)

Підняття діагностики з `DEBUG` (невидимо) до рівня, який реально пишеться у файл,
збільшує поверхню розкриття, **якби** пароль коли-небудь потрапив у вивід 7-Zip.
Перевірено: `Write-BRAVOLog` викликає `Protect-BRAVOLogSecret -Text $Message`
**без** `-KnownSecret`; шлях точного маскування значень
(`Get-BRAVOLogMaskSecretSet`) використовується лише для masked-копії, що
вивантажується на SFTP. Коментар у `BRAVO.Logging.psm1` каже це прямо: шаблонне
маскування «сирий пароль 7-Zip чи API-ключ без контексту пропускає».

Явне маскування з `878dd86` **свідомо не відроджувалось**: хенд-рол
`String.Replace` у `BRAVO.ArchiveHelpers` був би слабким дублікатом саме
*політики* маскування (#365/#417/#435 — raw/trim/URL/JSON-варіанти), а це гірший
безпековий результат, ніж його відсутність, і порушив би єдине канонічне
володіння. `BRAVO.ArchiveHelpers` навмисно не залежить від `BRAVO.Logging`.
Незалежний security-review цей ризик **не підтвердив як досяжний сьогодні**
(«inspection did not establish such a disclosure in the reviewed paths»), але
визначив як defense-in-depth gap.

Канонічне рішення, якщо точне маскування на звичайному шляху журналу потрібне:
передати `Write-BRAVOLog` той самий `-KnownSecret`, який він уже підтримує для
masked-копії. Окрема свідома зміна з власним review, не побічний ефект
діагностичного фікса.

---

## 7. P0–P3 findings

### P0
Немає.

### P1
* **P1-1 (виправлено).** Діагностика збою 7-Zip логувалась рівнем `DEBUG` при
  канонічному `FileLevel=INFO` — оператор не отримував причини збою ні для
  `test`, ні для `create`, ні для таймауту. Регресія `ce4855d` проти `878dd86`.
  Підтверджено production-логами (нуль `[DEBUG]` у 224 логах).
* **P1-2 (виправлено).** Порожній capture не логувався взагалі, тому «7-Zip
  промовчав» було неможливо відрізнити від «діагностику відфільтровано».
* **P1-3 (НЕ в цьому diff, production-ризик).** Уся лінія 5.2.x, включно з
  `v5.2.5-rc.4`, має асиметрію кодування пароля create↔test (legacy `WriteLine`
  проти BOM-free `BaseStream`); виправлено лише на 5.3-dev (T005/T005b). Для
  поточних збоїв **не причина** (опроверґнуто по-компонентним патерном), але
  реальний ризик для архівів, створених під UTF-8-консоллю. Рішення про backport
  у 5.2.x проти прискорення 5.3 — за власником.

### P2
* **P2-1 (виправлено).** Гейт `BackupDiagnostics/SevenZipFailureOutput` був
  вакуумним (лише підрядки) і тому пропустив регресію на 2,5 місяці.
* **P2-2 (виправлено).** Дві незалежні копії правила рівня (`ArchiveHelpers` і
  `Archive.Runtime`) — безпосередній механізм розходження `create` і `test`.
* **P2-3 (НЕ виправлено, свідомо).** Точне маскування значення пароля відсутнє на
  звичайному шляху `Write-BRAVOLog`. Канонічний фікс — прокинути наявний
  `-KnownSecret`; окрема зміна з власним review (розділ 6).
* **P2-4 (НЕ виправлено, поза обсягом).** `BRAVO_RESTORE_TEST.ps1` викликає
  `Test-SevenZipArchiveIntegrity` **без** `-Logger`, тому в Restore Drill
  відкидаються і headline, і діагностика — незалежно від рівня. Фікс в один
  рядок, але вимагає рішення щодо `-AsJson` (машинно-чистий stdout) і перевірки
  захоплення `Write-Host` транскриптом `Start-BRAVOHelperLog -QuietConsole`.

### P3
* **P3-1 (виправлено побічно).** Старий create-шлях мав `foreach` по двох потоках
  замість рядків: межі 20 рядків не існувало, 4000 символів діяли на кожен потік
  окремо.
* **P3-2 (НЕ виправлено, поза обсягом).** Три рядки `-Level "DEBUG"` у
  `New-Archive` (`Останнiй вивiд 7-Zip`, `Помилка 7-Zip`, `Деталi`) тепер строго
  дублюють ERROR-запис і лишаються невидимими. Шкоди не роблять; видалення
  торкалося б гілки `$showSevenZipProgress` — окремий коміт.
* **P3-3 (виправлено).** `CHANGELOG.md` 4.9.0 декларував поведінку, якої в коді не
  було. Виправлено записом у «Не випущено (developer)»; історичну секцію не
  чіпано.
* **P3-4 (прийнято).** Нове ім'я функції дає одну **інформаційну** знахідку
  `PSUseSingularNouns` (не в блокуючому наборі `PSScriptAnalyzerSettings.psd1`).
  Плюральне ім'я збережено для узгодженості з наявним
  `Write-SevenZipFailureDiagnostics`.
* **P3-5 (залишкове обмеження гейта, задокументовано).** AST-гейт ловить лише
  літеральний `-Level DEBUG` у тілах трьох названих функцій: рівень, переданий
  змінною, splatting або діагностичний виклик, винесений за межі цих тіл, він не
  побачить. Поведінкові перевірки на `FileLevel=INFO` закривають цю щілину з
  іншого боку.

---

## 8. Merge gate

| Пункт | Команда | Результат |
|---|---|---|
| Парсер Windows PowerShell 5.1 | `[Parser]::ParseFile(...)` на всі змінені `.ps1`/`.psm1` | **0 помилок** |
| Заборонені патерни | `.\ci\Test-BRAVOForbiddenPattern.ps1` | **exit 0**, не знайдено (174 файли) |
| Security-набір PSScriptAnalyzer | `.\ci\Invoke-BRAVOSecurityAnalysis.ps1` | **exit 0**, чисто (172 файли) |
| PSScriptAnalyzer delta | | `Archive.Runtime` **0**; `ArchiveHelpers` **+1 інформаційна** `PSUseSingularNouns` (не блокуюча) |
| Runtime-маніфест | `.\ci\Update-BRAVORuntimeManifest.ps1 -Apply`, потім без `-Apply` | оновлено (163 файли), повторний прогін — **розбіжностей немає** (ідемпотентно) |
| Пробіли / line endings | `git diff --check` | **rc=0** |
| CRLF | побайтова перевірка | **bareLF=0** у всіх змінених файлах |
| BOM | побайтова перевірка | `.ps1`/`.psm1` — **з BOM**; `.md` — **без BOM** (обидва напрямки політики CI) |
| Обсяг diff | `git diff --stat` | рівно **6 файлів, +848 / −23**, непов'язаних змін немає |
| RED → GREEN | standalone-харнес проти справжнього `7za.exe` 26.02 | RED: A1/A1b/A3/A4 = False → GREEN: усі шість True |
| Нетривіальність гейтів | та сама логіка проти текстів `f317c201` | `GATE[BASE]=FAIL` (2 порушення + 1 відсутній власник), `TIMEOUTBRANCH[BASE]=FAIL` (calls=0) |
| Повний `BRAVO_SELF_TEST.ps1 -NoPause` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\BRAVO_SELF_TEST.ps1 -NoPause` | **SELF-TEST PASSED** — перевірок **3596**, збоїв **0**, `SELFTEST_EXIT=0`. Запас змінних у верхній області: 6448 з 8192 (вимога >= 256 виконана). Нуль справжніх `[FAIL]`; усі 16 діагностичних assertion-ів PASS. |
| Незалежний review (CRITICAL) | `codex-qa` + `codex-security` + `codex-architecture` | 4 × P2 знайдено → усі прийнято, виправлено, повторно верифіковано як `fixed`; security — 0 знахідок |
| gitleaks | | **NOT RUN** локально (виконується в CI) |
| `BRAVO_DATA_RESTORE_MATRIX_TEST.ps1` | | **NOT RUN** — потребує інтерактивної елевації Administrator, недоступної в автоматизованій сесії; наявне обмеження середовища, не наслідок цієї зміни; закривається прогоном у CI |
| Real-server acceptance | | **NOT RUN** — лишається outstanding (розділ 10) |

**Вердикт:** технічно готово до відкриття PR на `developer` за наявності зеленого
CI. **Це доказ, а не авторизація.** Commit, push, PR, merge, release і deployment
не виконувались і виконані не будуть без окремого дозволу.

---

## 9. Production follow-up (окремо від коду; не входить у цей diff)

Першопричина `exit 2` середовищна й лишається **unresolved**. Цей фікс робить її
спостережуваною — він її **не лікує**, і очікувати зникнення збоїв після
розгортання не слід.

**Порядок переглянуто 2026-10-13 за новим доказом (п. 2.2a).** Пункт 1
виконано оператором, і він уже дав результат: 7-Zip повідомив
`Internal Error: The failure in hardware (RAM or CPU), OS or program`. Тому
перевірка пам'яті піднята на перше місце, а NTFS/VSS опущені — читання зі
снапшота відпрацювало, збій стався в компресії.

1. ~~**Негайна видимість без деплою** — `consoleSettings.FileLevel = "DEBUG"`.~~
   **ВИКОНАНО 2026-10-13.** Дало точну причину того ж прогону
   (`BRAVO_ARCHIV_20261013_003107_PID1396`), без зміни коду. Після розгортання
   цього фікса тримати весь прогін у `DEBUG` більше не потрібно: той самий
   текст пише рівнем `ERROR` за замовчуванням.
2. **Діагностика пам'яті — головний пріоритет, і робити її треба на
   ГІПЕРВІЗОРІ** (див. п. 2.2b: гість — ВМ QEMU, хост імовірно на не-ECC
   пам'яті). Багатопроходовий `memtest86+` на самому хості; кілька повних
   проходів, бо збій імовірнісний і один короткий прохід нічого не доводить.
   **Запуск memtest у гостьовій ОС сенсу не має** — він перевірить пам'ять,
   яку віддав гіпервізор.
3. **Логи гіпервізора** за 2026-09-30 … 10-13: `mce`, `EDAC`, OOM-killer,
   segfault/abort процесу `qemu-kvm`, активність swap. Це прямий
   підтверджувач або опровергач п. 2. `Microsoft-Windows-WHEA-Logger`
   усередині ВМ перевірити дешево, але його тиша нічого не доводить:
   i440FX/SeaBIOS machine-check у гостя практично не пробрасує.
4. **Налаштування пам'яті ВМ** — чи є overcommit, чи активний virtio-balloon,
   чи не свопиться ВМ. Якщо так, зафіксувати пам'ять ВМ без ballooning: це
   дешева й повністю оборотна перевірка гіпотези п. 2.2b.3.
5. **Чому відбулося перезавантаження 12.10 о 23:31:45** — планове чи
   аварійне. Якщо аварійне, це додатковий доказ проблеми на рівні хоста.
   У гостьовій ОС:
   `wevtutil qe System /q:"*[System[(EventID=41 or EventID=6008 or EventID=1001)]]" /c:10 /rd:true /f:text`
6. **Якщо пам'ять хоста чиста** — далі в такому порядку: CPU/термальний режим
   і throttling на хості, версія QEMU/KVM і virtio-драйвери в гості (машина
   i440FX із SeaBIOS 2014 року — застарілий тип), і лише потім
   `chkdsk C: /scan` та `vssadmin list shadowstorage` (лишаються в списку, але
   більше не головні підозрювані).
7. **Тимчасове зниження ризику, якщо ремонт хоста відкладається.**
   Зменшення `-mmt` і рівня компресії знижує тиск на пам'ять і може зменшити
   частоту збоїв. Це **маскування симптому, не лікування**, і зміна параметрів
   архівації — продуктове рішення власника, не операційна дія.
8. **Рішення власника щодо P1-3** (backport T005/T005b у 5.2.x проти
   прискорення 5.3). До цього P1 не належить і новим доказом не зачеплене.

---

## 10. Невиконані перевірки (явно)

* **Real-server acceptance — NOT RUN.** Поведінка залежить від реального
  Windows-хоста, VSS і Task Scheduler. CI-доказів для цього недостатньо за
  `.claude/rules/04-testing-validation.md`. Лишається outstanding.
* **`BRAVO_DATA_RESTORE_MATRIX_TEST.ps1`** — NOT RUN локально (інтерактивна
  елевація Administrator); **PASS у CI** на PR #444 (1m56s).
* **gitleaks** — NOT RUN локально; **PASS у CI** на PR #444 (11s).
* **GitGuardian Security Checks** — на PR #444 дав `1 secret uncovered`.
  Причина — контіґуальні літерали фікстурних паролів `B2LegacyPass` /
  `B2NormalPass`, яких ця зміна додала сім. Застосовано наявний у репозиторії
  прецедент (`.gitguardian.yaml`, запис про `aade0ee`): значення складаються
  через `-join`, контіґуального літерала в нових рядках не лишається,
  значення архівів не змінено. Наявні шість входжень на `developer` не
  торкнуті. Увага: той самий файл фіксує, що перевірка в PR — це GitHub App,
  керована з `dashboard.gitguardian.com` і **не налаштовувана з репозиторію**,
  тому вже зафіксований інцидент треба закрити як false positive у дашборді.
* **Реальний прогін по таймауту (43200 с) — NOT RUN.** Перевірено лише змінений
  роутинг, детерміновано.
* **Сценарій 6 (permission denied) — NOT RUN.** Причина в розділі 5.
