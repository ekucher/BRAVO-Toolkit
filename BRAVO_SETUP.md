# BRAVO 5.3.0-dev.3 — комплексне налаштування і безпечний тестовий прогін

Кожен запуск setup і його допоміжних дочірніх скриптів створює окремий
transcript у `LOGS\HELPERS`. Ім'я містить назву скрипта, timestamp і PID, а
журнал завершується process exit code. Строк зберігання helper-логів — 31 день.

## Швидкий запуск

Запустіть від адміністратора:

```powershell
.\BRAVO_SETUP.ps1
```

Стандартний режим `Full` послідовно:

1. перевіряє конфігурацію, скрипти, інструменти та джерельні каталоги;
2. перевіряє Credential Manager і запитує тільки відсутні параметри установи та секрети;
3. повторно читає записи з обох сховищ;
4. валідує та встановлює завдання з `schedulerSettings`;
5. запускає dry-run від `NT AUTHORITY\SYSTEM`, тобто від task account;
6. виконує тест доступу SFTP/SMB (автентифікація і читання; відсутні
   каталоги призначення SFTP при цьому створюються);
7. надсилає одне тестове повідомлення у налаштований Slack або Discord.

Архівація, копіювання, синхронізація, видалення, перезапуск служб,
shutdown та інші production-операції у цьому сценарії не виконуються.

Проте сценарій **не є повністю read-only**. Зовнішні й локальні операції
запису, які він виконує:

- тестове повідомлення у Slack/Discord;
- create/write/read/delete проби у `RuntimeRoot\LOGS`, `SystemLogRoot`,
  `BackupRoot`, каталогах призначення та `.work` (тимчасові файли й
  каталоги прибираються після перевірки);
- створення відсутніх каталогів призначення на SFTP (з 5.2.0-rc.3;
  раніше їх відсутність зупиняла інсталяцію, хоча `BRAVO_ARCHIV` усе одно
  створює їх при першому запуску).

## Отримання комплекту (release artifact)

Комплект для розгортання — це release-артефакт з GitHub Release
відповідного тега, а не ручна копія довільного checkout:

- `BRAVO-Toolkit-X.Y.Z.zip` — детермінований вміст release-тега
  (генерується workflow `release-artifact` через `git archive`);
- `BRAVO-Toolkit-X.Y.Z.zip.sha256` — контрольна сума архіву;
- `release-manifest.json` — product, версія, `sourceCommit`/`buildId`
  і SHA-256 кожного файлу комплекту.

Перед розгортанням обов'язково звірте контрольну суму:

```powershell
(Get-FileHash .\BRAVO-Toolkit-X.Y.Z.zip -Algorithm SHA256).Hash.ToLower()
# порівняйте з вмістом BRAVO-Toolkit-X.Y.Z.zip.sha256
```

Артефакт прикріплюється до Release лише після того, як розпакований
комплект пройшов інтегріті-манифести, `BRAVO_RUNTIME_GUARD.ps1` і повний
`BRAVO_SELF_TEST.ps1` у CI. Той самий артефакт можна зібрати локально:
`.\ci\New-BRAVOReleaseArtifact.ps1 -Ref vX.Y.Z` (результат в
`artifacts\release`).

## Розташування runtime і безпека

Не встановлюйте SYSTEM-завдання зі `Desktop`, `Documents`, `Downloads` або
іншого каталогу профілю користувача. Робочий комплект (`RuntimeRoot`) потрібно
розміщувати, наприклад, у `C:\Program Files\BRAVO-Toolkit`; `LIMSRoot`, `ArchiveRoot` і `BackupRoot`
задаються окремими абсолютними шляхами через override у `BRAVO.local.config`
(з 5.3, issue #216 — не в `BRAVO.config`, який більше не входить у комплект).

Під час інсталяції Планувальника `BRAVO_TASKS_INSTALL.ps1` відмовляється
створювати SYSTEM-завдання з профілю користувача, захищає runtime ACL та
вмикає журнал `Microsoft-Windows-TaskScheduler/Operational`.

## Локальні site-відмінності: `BRAVO.local.config` (5.2.1; з 5.3 — єдиний
override-шар, issue #216)

Нетипові інсталяції більше не потребують ручного редагування `BRAVO.config`
— **з 5.3 цей файл узагалі не входить у комплект** і не є частиною
нормального runtime-конфігураційного графа (issue #216). Канонічні built-in
дефолти постачаються кодом комплекту; будь-яке site-специфічне відхилення
від них задається файлом **`BRAVO.local.config`** (шаблон —
`BRAVO.local.config.example` у комплекті, каталог — той самий `ConfigRoot`,
де раніше лежав `BRAVO.config`): data-only hashtable «dot-шлях → значення»,
наприклад:

```powershell
@{
    'pathSettings.BackupRoot' = 'E:\ARCHIV'
    'maintenanceSettings.Restore.BootRestoreMode' = 'HoldServices'
    'backupMonitoring.SFTP.BAZA.AutoArchiveMutationThreshold' = 50
}
```

Правила:

- файл **переживає оновлення** (заміна комплекту нового `RuntimeRoot`
  локальний override-файл не чіпає; на 5.2-інсталяціях, що ще не
  мігрували, оновлення так само замінює `BRAVO.config`, залишаючи
  `BRAVO.local.config` недоторканим — розділ 10 `README.md`);
- первинні поля (`pathSettings`/`maintenanceSettings`/`componentSettings`/
  sftp-скаляри/`smbSettings`) застосовуються **до деривацій** — перевизначений
  `BackupRoot` коректно протягується в каталоги архівів і Планувальник;
- файл **ніколи не виконується**: комплект парсить його й вилучає лише
  літеральні значення (рядок, число, `$true`, `$false`, `$null`, масив
  `@( ... )`, вкладена hashtable). Будь-яка інша конструкція — виклик
  команди, доступ до члена, приведення типу, підстановка в рядку,
  звернення до змінної (`$env:`, `$global:`, `$foo`) чи будь-яке
  обчислення, включно з арифметикою — відхиляє файл цілком. Тобто
  `1 + 1` тепер не стає `2`, а є помилкою конфігурації;
- повторний ключ (регістронезалежно) і порожній ключ відхиляються;
- суворість dot-шляху **несиметрична**: усі сегменти, крім останнього,
  мусять існувати в канонічній конфігурації (невідомий батьківський вузол —
  помилка конфігурації при запуску, файл відхиляється цілком), односегментний
  шлях теж мусить існувати, а **сам останній сегмент (leaf) існувати не
  зобов'язаний** — це навмисна forward-compat для новішого Configurator.
  Практичний наслідок: опечатка саме в останньому сегменті
  (`maintenanceSettings.Limits.MinFreeSpaceGB` замість `MinimumFreeSpaceGB`)
  буде **прийнята**, але нічого не змінить. Прийом не змінився —
  змінилася видимість: завантаження виводить попередження з переліком
  таких ключів і записує їх у
  `BravoConfigurationMetadata.LocalConfigUnknownLeafOverrides`. Якщо у
  виводі запуску такий ключ є, а ви його не планували — це опечатка, і
  налаштування НЕ застосувалось;
- застосовані ключі видно в metadata завантаження (діагностика).

Те саме стосується й самого `BRAVO.config`, коли він явно підключений
`-ConfigPath` під час міграції 5.2→5.3 (5.3 без явного `-ConfigPath` цей
файл узагалі не читає, issue #216): top-level `$global:`, якого канонічний
pipeline не приймає, і невідомий вкладений ключ більше не зникають без
сліду — вони потрапляють у попередження й у
`BravoConfigurationMetadata.PrimaryConfigIgnoredGlobals` та
`.PrimaryConfigUnknownNestedKeys`. Прийом/відхилення і тут не змінено.

## Локальні параметри установи

Стандартний компонент `Required` тепер створює три додаткові записи:

- `BRAVO_INSTITUTION_NAME` — назва установи;
- `BRAVO_INSTITUTION_CODE` — код установи;
- `BRAVO_ARCHIVE_PREFIX` — префікс імен архівів.

`BRAVO_ARCHIV`, `BRAVO_MAINTENANCE`, `BRAVO_ARCHIV_HEALTH` і dry-run
завантажують ці значення після ефективної конфігурації (built-in дефолти +
`BRAVO.local.config`, або legacy `BRAVO.config` за явним `-ConfigPath` на
інсталяціях, що ще мігрують). Тому під час оновлення можна замінювати
комплект без повторного ручного редагування назви установи, коду та
префікса.

Значення в ефективній конфігурації (на 5.2-інсталяціях — у `BRAVO.config`)
залишаються fallback лише для першого запуску. Фінальний dry-run повідомляє
про відсутні записи Credential Manager як про помилку.

Окреме оновлення лише цих параметрів:

```powershell
.\BRAVO_SETUP.ps1 -Action Credentials -CredentialComponent Institution
```

Або без комплексного оркестратора:

```powershell
.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Set -Component Institution -StoreFor Both
```

`ArchivePrefix` обмежено латинськими літерами, цифрами, `.`, `_` і `-`, тому
він безпечний для назв файлів, wildcard і регулярних виразів retention.
Після зміни префікса старі архіви залишаються на диску, але health-check і
retention нового запуску шукають уже новий префікс.

Повторний `.\BRAVO_SETUP.ps1` працює в режимі `Ensure`: якщо записи вже наявні
для поточного користувача та `SYSTEM`, значення не запитуються і не
перезаписуються. Якщо компонент відсутній, запитується лише він.

### Trace-модель: що налаштувати

- Джерела trace налаштовувати НЕ потрібно: ротується кожен `*.out` з кореня
  інсталяції bravo.exe (Discovery), включно з варіантами на кшталт
  `TraceSRV2.out`/`traceBIS1.out`/`!TraceSRV.out`.
  `maintenanceSettings.Trace.BISSourcePath` потрібен лише якщо `TraceBIS.out`
  лежить ПОЗА коренем інсталяції (абсолютний шлях; порожньо/`'off'` — нічого
  додаткового).
- `sftpDirectories.TraceLogs` (типово `"logs/trace"`) і
  `sftpDirectories.ExchangeApiLogs` (типово `"logs/exchangapi"`) — каталоги
  добових `Trace_YYYYMMDD.mdz` / `exchangAPI_YYYYMMDD.mdz` + `.sha512` на
  SFTP. Відсутні remote-каталоги створюються автоматично (рекурсивно); у
  облікового запису SFTP мають бути права запису й квота. Наявні архіви зі
  старого `sftpDirectories.Trace` (`trace/`) Maintenance одноразово мігрує
  remote-move'ом у `logs/trace` — нічого не видаляється.
- Логи exchangAPI зберігають оригінальні імена (без `exchangAPI_N.log`),
  пакуються в добовий `exchangAPI_YYYYMMDD.mdz` і видаляються локально лише
  після повної SFTP-верифікації.
- `maintenanceSettings.Retention.CompressedLogDeletionEnabled` — типово
  `$false`: стиснуті `.mdz` журналів (включно з добовими Trace-архівами)
  ніколи не видаляються автоматично; вмикайте свідомо разом із
  `CompressedLogDays`.

Окремих Scheduled Task для Trace немає і не потрібно: всю обробку виконує
наявний `BRAVO_MAINTENANCE` (ручний запуск робить рівно те саме).

### Нові опційні ключі 5.2.0: сумісність старих `BRAVO.config`

Розгорнутий на сервері `BRAVO.config` може передувати цій версії
комплекту — це штатно. Нові опційні ключі отримують безпечні дефолти в
коді завантаження, редагувати старий config при оновленні не потрібно:

- `maintenanceSettings.Limits.EstimatedSpaceMarginPercent` — за
  відсутності діє `25` (запас розрахункової перевірки вільного місця,
  README розділ 3.3);
- `backupMonitoring.SFTP.BAZA.AutoArchiveMutationThreshold` — за
  відсутності діє `0` (авто-архівування мутацій вимкнено; поведінка
  reconcile не змінюється, `OPERATIONS.md`);
- `sftpDirectories.TraceLogs` / `sftpDirectories.ExchangeApiLogs` — за
  відсутності діють `"logs/trace"` / `"logs/exchangapi"` (нова структура
  журнальних архівів на SFTP; старий `Trace = "trace"` лишається джерелом
  одноразової автоміграції);
- `maintenanceSettings.Trace.BISSourcePath` — тепер опційний і на типових
  інсталяціях непотрібний (усі `*.out` кореня інсталяції скануються
  автоматично); значення `'off'` теж валідне.

## Спочатку лише перевірка

```powershell
.\BRAVO_SETUP.ps1 -ValidateOnly
```

Цей режим не створює і не змінює постійні записи Credential Manager та
завдання Планувальника. Для перевірки Credential Manager облікового запису
`SYSTEM` може короткочасно створюватися службове завдання, яке автоматично
видаляється скриптом `BRAVO_CREDENTIALS_SETUP.ps1`.

У режимі `-ValidateOnly` тестове повідомлення не надсилається.

Перевірка складу джерел враховує наявність компонентів: увімкнений, але не
встановлений на сервері компонент (`NotInstalled`) пропускається без помилки,
і каталог його призначення не вимагається. `-ValidateOnly` нічого не створює.
Discovery baseline (`%ProgramData%\BRAVO\State\DISCOVERY_BASELINE.json`)
створюється й доповнюється автоматично після першого COMPLETE backup
(`BRAVO_ARCHIV.ps1`), а generation manifest містить поле `componentScope`.
Деталі: `OPERATIONS.md`, розділ про `NotInstalled`.

Якщо зовнішня мережа під час інсталяції недоступна:

```powershell
.\BRAVO_SETUP.ps1 -SkipAccessTest
```

Щоб виконати тести доступу SFTP/SMB, але не надсилати тестове повідомлення:

```powershell
.\BRAVO_SETUP.ps1 -SkipTestNotification
```

## Окремі етапи

Лише credentials:

```powershell
.\BRAVO_SETUP.ps1 -Action Credentials
```

Лише Планувальник:

```powershell
.\BRAVO_SETUP.ps1 -Action Scheduler
```

Діагностика реєстрації, `LastTaskResult` і end-to-end доступу від `SYSTEM`:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess
```

Лише перегляд реєстрації без UAC і без тимчасового SYSTEM-завдання:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -InspectOnly
```

З одним тестовим повідомленням від `SYSTEM`:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess -SendTestNotification
```

Тільки комплексна перевірка без змін:

```powershell
.\BRAVO_SETUP.ps1 -Action Test -ValidateOnly
```

## Окремий dry-run

Без мережевої автентифікації:

```powershell
.\BRAVO_DRY_RUN.ps1
```

З перевіркою доступів (містить проби запису — див. вище):

```powershell
.\BRAVO_DRY_RUN.ps1 -TestAccess
```

З end-to-end надсиланням одного тестового повідомлення:

```powershell
.\BRAVO_DRY_RUN.ps1 -TestAccess -SendTestNotification
```

`-TestAccess` виконує:

- SFTP: TCP-з’єднання саме з configured endpoint, автентифікацію WinSCP і
  читання каталогу `.`; generic Internet/`google.com` не є prerequisite;
- SMB: тимчасове підключення `PSDrive` та читання кореня, після чого drive видаляється;
- Slack/Discord з `-TestAccess`: лише TCP-доступність HTTPS endpoint;
- Slack/Discord з `-SendTestNotification`: HTTP POST тестового повідомлення.

Для Discord payload містить `allowed_mentions.parse = []`, тому тестове
повідомлення не створює mentions. Невдале надсилання є критичною помилкою і
повертає код завершення `1`.

Код завершення `0` означає відсутність помилок, `1` — щонайменше одну
критичну проблему. Рядки `PLAN` описують операції, які production-скрипт
виконав би, але dry-run їх не запускає.

## Операторські сповіщення (UX)

Тестові сповіщення Setup, Dry Run і Diagnose мають той самий стиль
операторського підсумку, що й сповіщення production-runtime:

- ✅ success -> `Дій не потрібно`;
- ⚠️ warning -> `Потрібна дія: ...`;
- 🚨 critical -> під загрозою backup, цілісність, облікові дані або безпека
  обслуговування.

Сповіщення — не дамп технічного логу. Воно показує установу `🏢`, компактні
host/IP, публічну IP-адресу (опційно й лише коли вона доступна),
версію/збірку та посилання на лог. Для стану резервних копій
використовується `Остання резервна копія` для SUCCESS і
`Остання успішна резервна копія` для WARNING/ERROR.
