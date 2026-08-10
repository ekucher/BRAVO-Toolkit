# BRAVO 5.0.0-dev.19 — архівація, обслуговування та контроль резервних копій

Цей комплект автоматизує:

- архівацію `MODEL`, `BLOG` і `BRAVOEXCH`;
- локальну та SFTP-синхронізацію `BAZA`;
- копіювання архівів на SFTP і, за потреби, SMB/NAS;
- обслуговування служб BRAVO;
- перевірку локальних, SFTP і SMB-копій;
- сповіщення у Slack або Discord;
- створення й діагностику завдань Планувальника Windows.

Для звичайного встановлення не потрібно запускати всі скрипти окремо. Основна
точка входу — **`.\BRAVO_SETUP.ps1`**.

> **Важливо:** production-комплект для завдань від `SYSTEM` не можна запускати з
> `Desktop`, `Documents`, `Downloads` або іншого каталогу профілю користувача.
> Рекомендоване розташування RuntimeRoot — `C:\BRAVO`; його назва не
> пов'язана з `ArchiveRoot` або каталогом інсталяції LIMS.

## Швидкий вибір команди

| Що потрібно зробити | Команда |
|---|---|
| Перша інсталяція або повне оновлення | `.\BRAVO_SETUP.ps1` |
| Перевірити все без постійних змін | `.\BRAVO_SETUP.ps1 -ValidateOnly` |
| Симулювати production-операції | `.\BRAVO_DRY_RUN.ps1` |
| Перевірити реєстрацію завдань без UAC | `.\BRAVO_TASKS_DIAGNOSE.ps1 -InspectOnly` |
| Перевірити завдання та доступ від `SYSTEM` | `.\BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess` |
| Оновити лише параметри установи | `.\BRAVO_SETUP.ps1 -Action Credentials -CredentialComponent Institution` |
| Запустити архівацію вручну | `.\BRAVO_ARCHIV.ps1 -NoPause` |
| Запустити обслуговування вручну | `.\BRAVO_MAINTENANCE.ps1` |
| Запустити health-check вручну | `.\BRAVO_HEALTH.ps1` |
| Перевірити, що backup реально відновлюється | `.\BRAVO_RESTORE_TEST.ps1` |
| Виконати тести коду | `.\BRAVO_SELF_TEST.ps1` |

Усі команди в цій інструкції потрібно виконувати з каталогу `ARCHIV`. Для
інсталяції, зміни Credential Manager для `SYSTEM` і Планувальника відкрийте
`cmd.exe` або PowerShell **від імені адміністратора**.

**Якщо щось уже зламалось** — [OPERATIONS.md](OPERATIONS.md): операторський
runbook за кожним кодом завершення, із розділом «чого не робити» для кожного
сценарію. Модель безпеки — [SECURITY.md](SECURITY.md), аналіз загроз —
[THREAT_MODEL.md](THREAT_MODEL.md).

## 1. Системні вимоги

- 64-бітна Windows для повного сценарію обслуговування;
- локальні права адміністратора для встановлення завдань і керування службами;
- доступний VSS на локальних томах із `MODEL`, `BLOG` і `BRAVOEXCH`;
- доступ до SFTP через TCP 22, якщо SFTP-компоненти ввімкнені;
- доступ до Slack/Discord через HTTPS 443, якщо сповіщення ввімкнені;
- доступ до потрібного UNC-шляху, якщо SMB/NAS ввімкнений.

### Підтримувані версії Windows

| Рівень | Системи |
|---|---|
| **Supported** | Windows Server 2019+, Windows 10/11, Windows PowerShell 5.1 |
| **Legacy best-effort** | Windows Server 2012 R2, Windows Server 2016 (без гарантій) |
| **Unsupported** | Windows 7, Windows Server 2008 R2, PowerShell 3.0 |

Archive, Health і Maintenance визначають рівень при кожному запуску
(`Get-BRAVOOSSupportTier`, `modules\BRAVO.Compatibility`) і завжди пишуть у
журнал точну версію ОС, build, PowerShell і .NET — незалежно від рівня. На
`Legacy best-effort` запуск лише попереджає. На `Unsupported` production-запуск
**блокується** (код завершення `30`) — щоб продовжити свідомо, встановіть
змінну середовища `BRAVO_ALLOW_UNSUPPORTED_OS=1` перед запуском. Мінімальна
версія PowerShell для самого запуску скрипта — 3.0 (нижче кидає помилку
одразу, `Assert-BRAVOPowerShellCompatibility`); 3.0 сама по собі вже входить
до Unsupported і потребує того самого override.

У каталозі `ARCHIV\Tools` мають бути:

| Файл | Для чого потрібен |
|---|---|
| `7za.exe` | Створення та повна перевірка архівів |
| `WinSCP.com` | Production-передача і синхронізація SFTP |
| `WinSCPnet.dll` | Автентифікований read-only тест SFTP |
| `WinSCP.exe` | Працює в парі з `WinSCPnet.dll` під час тесту доступу |

Еталон цілісності інструментів — `Tools\TOOLS_MANIFEST.json`, у тому
самому каталозі, що й самі утиліти:
version-controlled файл із SHA-256 **усіх** виконуваних файлів `Tools\`
(включно з `7za.dll`, `7zxa.dll`, `DragExt64.dll`, які тягне за собою
7-Zip). Перед кожним запуском Archive/Health/Maintenance звіряють каталог
із маніфестом, і в режимі `Enforce` (типовий,
`$global:toolIntegritySettings.Mode` у `BRAVO.config`) **блокують роботу**
з кодом завершення `32`, якщо:

- хеш відомого файлу не збігається;
- файл із маніфесту відсутній;
- у `Tools\` з'явився сторонній `.exe`/`.dll`/`.com` (DLL side-loading:
  щоб виконати чужий код, підміняти `WinSCP.exe` не обов'язково —
  достатньо підкласти DLL із відповідним іменем);
- сам `TOOLS_MANIFEST.json` відсутній, порожній або пошкоджений.

Health при цьому не просто попереджає: він пропускає всю SFTP-гілку
(єдине місце, де він торкається `Tools\`) і завершується кодом `32`.
Локальні перевірки — служби, вільне місце, вік копій — виконуються далі.

> **Маніфест ніколи не створюється й не оновлюється автоматично.**
> Оновлення інструментів — свідома дія на робочій станції, не на сервері:
>
> ```powershell
> .\ci\Update-BRAVOToolsManifest.ps1          # лише показує розбіжності
> .\ci\Update-BRAVOToolsManifest.ps1 -Apply   # записує новий еталон
> git diff -- Tools                           # рев'ю manifest разом із бінарником
> ```
>
> Видаляти маніфест, щоб «полагодити» помилку цілісності, не можна: це
> не лікування, а вимкнення самої перевірки. У режимі `Enforce`
> відсутній маніфест — теж відмова.

Окремо існує додатковий шар виявлення дрейфу — `Tools\TOOLS_INTEGRITY.json`
(trust-on-first-use, створюється автоматично, розбіжність лише попереджає).
Це **не** контроль безпеки й не еталон: якщо хеш у ньому розійшовся,
рішення ухвалює `TOOLS_MANIFEST.json`.

## 2. Чотири корені: код окремо, дані окремо

**CODE IS NOT DATA.** Комплект, LIMS, операційні журнали й резервні копії —
чотири незалежні поняття. Жодне з них не виводиться з фізичного розташування
іншого, і всі чотири можуть бути на різних дисках.

| Корінь | Що це | Звідки береться |
|---|---|---|
| `RuntimeRoot` | сам комплект: скрипти, `modules\`, `Tools\`, `VERSION.json`, `RUNTIME_MANIFEST.json`, **логи самих скриптів** (`LOGS\`) | каталог запущеного скрипта (`$PSScriptRoot`) |
| `LIMSRoot` | інсталяція LIMS/BRAVO: `bravo.exe`, `Model`, `bravoexch` | `pathSettings.LIMSRoot`; `""` = AUTO зі служби BRAVO |
| `SystemLogRoot` | системні журнали BRAVO: `Trace`, `exchangAPI`, `BravoWeb` | `pathSettings.SystemLogRoot`; `""` = `<EffectiveLIMSRoot>\ARCHIV\LOGS` |
| `BackupRoot` | резервні копії `MODEL/BLOG/BRAVOEXCH/BAZA_APP/BAZA_WWW` | `pathSettings.BackupRoot`; `""` = `<EffectiveLIMSRoot>\ARCHIV` |

Окремо, поза `pathSettings`: машинний стан і operation lock — у
`%ProgramData%\BRAVO\State` і `%ProgramData%\BRAVO\Locks` (не залежать від
жодного кореня даних). Логи самих PowerShell-скриптів — завжди
`<RuntimeRoot>\LOGS` (helper-логи — `<RuntimeRoot>\LOGS\HELPERS`); вони не
налаштовуються через `pathSettings`.

Від `RuntimeRoot` залежать **лише** ресурси комплекту. Усі три корені даних
можуть бути `""` (all-AUTO — розкладання за замовчуванням від служби BRAVO):
`LIMSRoot=""` → корінь встановлення служби, `SystemLogRoot=""` →
`<EffectiveLIMSRoot>\ARCHIV\LOGS`, `BackupRoot=""` → `<EffectiveLIMSRoot>\ARCHIV`.
Некоректне або відносне непорожнє значення — помилка конфігурації з назвою
параметра, а не мовчазний здогад. Поняття `ArchiveRoot` прибрано.

Приклад розгортання на різних дисках:

```text
C:\BRAVO\                          RuntimeRoot — комплект
├── BRAVO_ARCHIV.ps1, BRAVO_MAINTENANCE.ps1, BRAVO_HEALTH.ps1
├── BRAVO_SETUP.ps1, BRAVO_DRY_RUN.ps1, BRAVO_SELF_TEST.ps1
├── BRAVO_CREDENTIALS_SETUP.ps1, BRAVO_TASKS_INSTALL.ps1,
│   BRAVO_TASKS_UNINSTALL.ps1, BRAVO_TASKS_DIAGNOSE.ps1
├── BRAVO_RUNTIME_GUARD.ps1, BRAVO_CONFIG_LOADER.ps1
├── BRAVO.config, VERSION.json, RUNTIME_MANIFEST.json
├── modules\                       спільні PowerShell-модулі (розділ 13)
├── Tools\                         runtime-залежності, не дані бекапу
│   ├── 7za.exe
│   ├── WinSCP.com
│   ├── WinSCP.exe
│   └── WinSCPnet.dll
└── LOGS\                          логи самих скриптів (Archive/Maintenance/Health)
    └── HELPERS\                    транскрипти допоміжних скриптів

D:\LIMS-NEW\                       LIMSRoot — інсталяція LIMS ("" = AUTO зі служби)
├── bravo.exe
├── Model\
└── bravoexch\

D:\LIMS-NEW\ARCHIV\LOGS\           SystemLogRoot — системні журнали ("" = AUTO)
├── Trace\
├── exchangAPI\
└── BravoWeb\                      Apache\, Application\ (розділ 12)

E:\BRAVO_BACKUPS\                  BackupRoot — резервні копії
├── MANIFESTS\                      generation manifest-и (розділ 12)
│   └── BRAVO_BACKUP_<GenerationId>.json
├── MODEL\
├── BLOG\
├── BRAVOEXCH\
├── BAZA_APP\
└── BAZA_WWW\

C:\ProgramData\BRAVO\             машинний стан і lock (поза pathSettings)
├── Locks\BRAVO_OPERATION.lock
└── State\                         BRAVO_VERSION_STATE.json, *_TASK_EXECUTION_STATE.json, …
```

Конфігурація за замовчуванням — усі три корені `""` (all-AUTO): корені LIMS,
системних журналів і бекапів визначаються автоматично від встановленої служби
BRAVO, без machine-specific шляхів у комплекті:

```powershell
$global:pathSettings = @{
    LIMSRoot      = ""   # -> корінь встановлення служби BRAVO (батько bravo.exe)
    SystemLogRoot = ""   # -> <EffectiveLIMSRoot>\ARCHIV\LOGS
    BackupRoot    = ""   # -> <EffectiveLIMSRoot>\ARCHIV
}
```

Будь-який корінь можна перевизначити явним абсолютним шляхом — наприклад, щоб
винести бекапи на окремий диск (`E:\`, як у дереві вище):

```powershell
$global:pathSettings = @{
    LIMSRoot      = "D:\LIMS-NEW"   # або "" — AUTO зі встановленої служби BRAVO
    SystemLogRoot = ""              # "" -> <EffectiveLIMSRoot>\ARCHIV\LOGS
    BackupRoot    = "E:\BRAVO_BACKUPS"
}
```

Комплект і дані можуть лежати й в одному дереві — це питання зручності, а не
вимога: жодної фізичної залежності між коренями немає.

`RuntimeRoot` для production-завдань має бути захищений ACL (`SYSTEM` і
`Administrators` — FullControl, `Users` — ReadAndExecute) і не може лежати в
профілі користувача: заплановані завдання виконуються від
`NT AUTHORITY\SYSTEM`. Мережеве сховище задається UNC-шляхом
(`\\server\share\...`), а не буквою підключеного диска — SYSTEM не бачить
дискових підключень користувача, і такий шлях працює вручну, але мовчки
зникає вночі. `BRAVO_TASKS_DIAGNOSE.ps1` і `BRAVO_DRY_RUN.ps1` перевіряють
це окремо, разом із фактичним правом запису під SYSTEM (створити → записати →
прочитати назад → видалити probe-файл).

## 3. Що налаштувати у `BRAVO.config`

`BRAVO.config` є PowerShell-конфігурацією, тому зберігайте його кодування і
синтаксис. Паролі, логіни та webhook URL у файл не записуються.

Перед першим запуском перевірте такі секції:

| Секція | Що перевірити |
|---|---|
| `bravoSettings` | `NotificationProvider` (`slack` або `discord`) і `NotificationMode` |
| `pathSettings` | `LIMSRoot`/`SystemLogRoot`/`BackupRoot` — усі три `""`=AUTO (розділ 2); `ArchiveRoot` більше немає |
| `maintenanceSettings` | імена служб, каталог Br-a-vo.web, таймаути, `Retention.ArchiveDays` / `Retention.CompressedLogDays` (розділ 12) |
| `componentSettings` | які архіви, BAZA, SFTP і SMB потрібно виконувати |
| `backupConsistency` | обов'язковий режим `VSS` і контекст `ClientAccessible` для узгоджених архівів |
| SFTP | `sftpHostTemplate`, порт, fingerprint `sftpHostKey`, віддалені каталоги |
| `smbSettings` | реальний UNC-шлях і підкаталоги, якщо `ArchiveCopy = $true` |
| `backupMonitoring` | `CheckManagedServices`, допустимий вік копій, SHA512-перевірки і частота повторних alert |
| `schedulerSettings` | час запуску, імена завдань, таймаути і task account |

Початково ввімкнено:

- архівацію `MODEL`, `BLOG`, `BRAVOEXCH`;
- завантаження архівів на SFTP;
- синхронізацію `BAZA_APP` на SFTP (`BAZA_APP_SFTP`);
- синхронізацію `BAZA_WWW` на SFTP (`BAZA_WWW_SFTP`);
- щоденний backup о `23:00`;
- щоденне maintenance о `23:55`;
- health-check кожні 240 хвилин, починаючи з `00:15`.

Початково вимкнено:

- локальну копію `BAZA_APP` (`BAZA_APP_LOCAL`);
- локальну копію `BAZA_WWW` (`BAZA_WWW_LOCAL`);
- копіювання архівів на SMB/NAS.

Визначення BAZA обмежене рівно чотирма незалежними прапорцями в
`componentSettings.Synchronization` — інших значень немає:

| Прапорець | Джерело | Призначення |
|---|---|---|
| `BAZA_APP_SFTP` | `<BRAVO_ROOT>\BAZA` | SFTP-каталог `baza_app` |
| `BAZA_APP_LOCAL` | `<BRAVO_ROOT>\BAZA` | локальна копія під `BackupRoot\BAZA` |
| `BAZA_WWW_SFTP` | `{DocumentRoot}\BAZA` встановленого Apache/Br-a-vo.web | SFTP-каталог `baza_www` |
| `BAZA_WWW_LOCAL` | `{DocumentRoot}\BAZA` встановленого Apache/Br-a-vo.web | локальна копія під `BackupRoot\BAZA_WWW` |

Не вмикайте компонент, доки не задані його шлях, доступ і Credential Manager.
Віддалені SFTP-каталоги `model`, `blog`, `bravoexch`, `baza_app` і `baza_www`
потрібно попередньо створити або змінити їхні назви у `sftpDirectories`.

Archive upload, `BAZA_APP` і `BAZA_WWW` є трьома незалежними SFTP-операціями.
У консолі та result object вони відображаються окремо як `SFTP: резервні
копії`, `SFTP: BAZA_APP`, `SFTP: BAZA_WWW`; доступність перевіряється за
actual SFTP endpoint, без залежності від `google.com` або generic Internet.

Локальний backup generation стає `COMPLETE` після archive, `7z t` і SHA512
для всіх enabled компонентів. SFTP/SMB failure не змінює цей локальний статус
і не видаляє validated artifacts. Health оцінює останній `COMPLETE` manifest
як один recoverable generation, а не незалежні newest component files.

### 3.1. Автоматичне визначення джерел (Discovery)

Джерела архівації (`MODEL`, `BLOG`, `BRAVOEXCH`, `BAZA_APP`, `BAZA_WWW`, а також
`BRAVO_ROOT`/`WEB_ROOT`) за замовчуванням визначаються **автоматично**, без
редагування `BRAVO.config`:

1. Служба BRAVO з одночасним збігом `Name` і `DisplayName` визначає
   `BRAVO_ROOT`; без підтвердженої служби значення лишається невизначеним.
2. `bravo.ini` читається лише з canonical path: `%SystemRoot%\SysWOW64\bravo.ini`
   на x64 або `%SystemRoot%\System32\bravo.ini` на x86.
3. Із секції `[model]` canonical `bravo.ini` читаються `MODEL=`, `BLOG=`,
   `BEXCH=` — саме ці значення й стають джерелами архівації.
4. Служба Apache (одна зі `BravoWebCandidates`) аналогічно дає `WEB_ROOT`
   і, відповідно, `BAZA_WWW`.

Якщо canonical source відсутній, увімкнений компонент завершує валідацію
керованою помилкою. Silent fallback до `LIMSRoot\Model`, `LIMSRoot\BLOG`,
`LIMSRoot\bravoexch` або довільного Apache-каталогу заборонений.

Ручне перевизначення будь-якого поля лишається можливим через
`$global:discoverySettings` у `BRAVO.config` (`Sources.MODEL`,
`Sources.BLOG`, `Sources.BRAVOEXCH`, `BravoRoot`, `WebRoot`,
`BravoIniPath` тощо) — заданe вручну значення завжди має пріоритет над
автоматично знайденим і ніколи не перезаписується.

Щоб побачити, які джерела буде визначено на конкретному сервері, і чи
пройдуть вони перевірку (існування шляху, конфлікт джерело/призначення
тощо), запустіть:

```powershell
.\BRAVO_SETUP.ps1 -Action Test -ValidateOnly
```

Розділ виводу `=== DISCOVERY ДЖЕРЕЛ ===` показує знайдені служби,
шлях до `bravo.ini`, кожне обчислене джерело з поясненням (explicit override,
canonical `bravo.ini` або підтверджена служба) і результат
валідації.

#### Неоднозначність і дрейф джерел

Якщо на сервері знайдено кілька служб BRAVO (або кілька Apache-подібних
служб) із **різними** виконуваними файлами — це ознака stale/дублюючої
інсталяції. Discovery попереджає про це (`УВАГА: знайдено кілька служб-
кандидатів...`), а `Test-BRAVODiscoveryResult` під `-ValidateOnly`
блокує валідацію для будь-якого увімкненого компонента, що залежить від
неоднозначного `BRAVO_ROOT`/`WEB_ROOT` — доки адміністратор явно не
задасть потрібне значення через `discoverySettings.BravoRoot`/`WebRoot`
або не прибере зайву службу.

`BRAVO_SETUP.ps1 -ValidateOnly` також порівнює поточний discovery-
результат зі збереженим **baseline** (`LOGS\DISCOVERY_BASELINE.json`,
не в git) і повідомляє про дрейф (`Discovery drift: ...`), якщо джерело
змінилося відносно останнього підтвердженого запуску — наприклад,
службу перейменували або canonical source перестав збігатися з baseline.
Це лише інформаційне попередження, воно не блокує роботу.

Щоб зафіксувати поточний discovery-результат як новий baseline (після
ручної перевірки, що джерела визначені правильно):

```powershell
.\BRAVO_SETUP.ps1 -Action Test -ValidateOnly -ConfirmDiscoveryBaseline
```

### 3.2. Sanity-check обсягу backup

Технічно валідний архів (пройшов `7za test`, SHA-512 збігається) все одно
може бути підозріло малим через неправильне джерело, зламані permissions
чи неповний VSS exposure — сам файл при цьому виглядає коректним.
`backupMonitoring.SizeSanity` у `BRAVO.config` порівнює розмір щойно
створеного архіву з медіаною останніх `HistoryCount` валідних (hash-
підтверджених) архівів того самого компонента:

| Поле | Призначення |
|---|---|
| `Enabled` | вимкнути перевірку повністю |
| `HistoryCount` | скільки останніх валідних архівів брати для медіани (типово 5) |
| `MinimumBytes` | абсолютний мінімум незалежно від історії — захищає навіть перший backup компонента |
| `MaxSizeDropPercent` | падіння відносно медіани, що вважається аномалією (типово 50%) |

Перший backup компонента (історії ще немає) автоматично пропускає
перевірку — це не вважається аномалією. Виявлена аномалія **не блокує**
backup — лише пише `WARNING` у журнал (`Write-Log`) і піднімає статус
кроку `Архівація <компонент>` до `WARNING` у консольному звіті; це
потрапляє в лічильник попереджень і, відповідно, у Slack/Discord-
сповіщення після backup.

## 4. Параметри установи та секрети

Наступні значення зберігаються у Windows Credential Manager, тому їх не потрібно
знову вписувати у config після оновлення:

| Target Credential Manager | Значення |
|---|---|
| `BRAVO_INSTITUTION_NAME` | назва установи |
| `BRAVO_INSTITUTION_CODE` | код ЄДРПОУ/локальний код |
| `BRAVO_ARCHIVE_PREFIX` | префікс імен архівів |
| `BRAVO_7Z_PASSWORD` | пароль архівів |
| `BRAVO_SFTP_LOGIN` | логін SFTP |
| `BRAVO_SFTP_PASSWORD` | пароль SFTP |
| `BRAVO_SMB_LOGIN` | логін SMB/NAS |
| `BRAVO_SMB_PASSWORD` | пароль SMB/NAS |
| `BRAVO_SLACK_URL` | Slack webhook |
| `BRAVO_DISCORD_URL` | Discord webhook |

Значення `InstitutionName`, `InstitutionCode` і `ArchivePrefix` у
`BRAVO.config` — лише fallback для першого запуску. Після налаштування
використовуються записи Credential Manager.

`ArchivePrefix` може містити латинські літери, цифри, `.`, `_` і `-`. Після
зміни префікса старі архіви не видаляються, але новий health-check і retention
працюють уже з новим префіксом.

Credential Manager є прив'язаним до облікового запису. Тому стандартний режим
`-StoreFor Both` зберігає потрібні записи окремо:

1. для поточного адміністратора — ручні запуски;
2. для `NT AUTHORITY\SYSTEM` — автоматичні завдання.

Не використовуйте лише `CurrentUser`, якщо завдання запускаються від `SYSTEM`.

## 5. Перша інсталяція

### Крок 1. Розмістити файли

Скопіюйте комплект у `C:\BRAVO`, додайте інструменти у `Tools` і
перевірте наявність джерельних каталогів.

### Крок 2. Виконати локальні тести

```powershell
cd /d C:\BRAVO
.\BRAVO_SELF_TEST.ps1
```

Self-test перевіряє синтаксис усіх PowerShell-файлів, узгодженість версій,
захисні параметри backup, спільний operation lock і визначення завдань
Планувальника без production-архівації.

### Крок 3. Перевірити конфігурацію без змін

```powershell
.\BRAVO_SETUP.ps1 -ValidateOnly
```

Цей режим не створює постійні credentials або production-завдання і не
надсилає тестове повідомлення. Для читання Credential Manager від `SYSTEM`
може бути створене короткочасне службове завдання, яке видаляється автоматично.

### Крок 4. Запустити комплексне налаштування

```powershell
.\BRAVO_SETUP.ps1
```

Стандартний режим `Full`:

1. виконує preflight і dry-run без production-операцій;
2. запитує лише відсутні credentials та параметри установи;
3. перевіряє їх читання поточним користувачем і `SYSTEM`;
4. перевіряє і встановлює завдання Планувальника;
5. запускає dry-run та read-only тести SFTP/SMB від `SYSTEM`;
6. надсилає одне тестове повідомлення у налаштований Slack або Discord.

У цьому сценарії не створюються архіви, не синхронізуються дані, не видаляються
файли, не перезапускаються служби і не вимикається комп'ютер. Єдина зовнішня
операція запису — одне явно позначене тестове повідомлення.

Якщо зовнішня мережа тимчасово недоступна:

```powershell
.\BRAVO_SETUP.ps1 -SkipAccessTest
```

Якщо потрібно перевірити SFTP/SMB, але не надсилати повідомлення:

```powershell
.\BRAVO_SETUP.ps1 -SkipTestNotification
```

### Крок 5. Перевірити створені завдання

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -InspectOnly
.\BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess
```

Перший виклик лише читає реєстрацію. Другий запускає end-to-end dry-run від
`SYSTEM` і перевіряє реальний доступ без архівації чи синхронізації.

## 6. Безпечний тестовий прогін

Лише перевірка конфігурації, файлів, каталогів, tools і плану операцій:

```powershell
.\BRAVO_DRY_RUN.ps1 -ConfigPath ".\BRAVO.config"
```

Додатково перевірити реальну автентифікацію та read-only доступ:

```powershell
.\BRAVO_DRY_RUN.ps1 -ConfigPath ".\BRAVO.config" -TestAccess
```

End-to-end тест із одним реальним Slack/Discord повідомленням:

```powershell
.\BRAVO_DRY_RUN.ps1 -ConfigPath ".\BRAVO.config" -TestAccess -SendTestNotification
```

`-TestAccess` виконує:

- SFTP: TCP-з'єднання, вхід через WinSCP і читання віддаленого каталогу;
- SMB: тимчасове підключення `PSDrive` і читання кореня, після чого drive
  видаляється;
- Slack/Discord: лише перевірку TCP-доступності HTTPS endpoint.

`-SendTestNotification` виконує HTTP POST і підтверджує, що webhook дійсно
приймає повідомлення. Для Discord mentions вимкнені. Невдале надсилання
повертає помилку, тому для першої інсталяції рекомендовано виконати саме цей
end-to-end тест.

Рядки `PLAN` у результаті показують, які production-операції були б виконані.
Dry-run їх не запускає.

### 6.1. Restore drill (перевірка відновлюваності)

Читабельний і навіть SHA-512/7za-перевірений архів доводить лише те, що
його байти не пошкоджені — не те, що з нього реально можна відновитися.
`BRAVO_RESTORE_TEST.ps1` обирає останній `COMPLETE` generation manifest і
бере `MODEL`/`BLOG`/`BRAVOEXCH` лише з одного `GenerationId`,
розпаковує його в ІЗОЛЬОВАНИЙ тимчасовий каталог (не production-шлях,
видаляється одразу після перевірки) і звіряє кількість розпакованих
файлів проти мінімального порогу:

```powershell
.\BRAVO_RESTORE_TEST.ps1 -ConfigPath ".\BRAVO.config"
```

Для контрольованого відновлення конкретної точки в часі задайте generation
явно. Не змішуйте independently newest MODEL/BLOG/BRAVOEXCH:

```powershell
.\BRAVO_RESTORE_TEST.ps1 -GenerationId "20260808_154300" -ConfigPath ".\BRAVO.config"
```

Лише один компонент, машинно-читаний JSON-результат і вища мінімальна
кількість файлів (типово `1`, підвищіть для реалістичного порогу під
конкретну інсталяцію):

```powershell
.\BRAVO_RESTORE_TEST.ps1 -Component MODEL -MinimumFileCount 50 -ResultPath ".\restore_drill_result.json" -AsJson
```

Це read-only діагностика: не видаляє, не переміщує й не змінює жоден
існуючий backup, не вимагає елевації. Кожен компонент отримує статус
`PASS`/`WARN`/`FAIL`; відсутній або некоректний `COMPLETE` generation,
невдала перевірка цілісності 7za, розпакування або мінімальна
кількість файлів) — коди завершення `0`/`10`/`41` відповідно до
контракту (розділ 12). Сповіщення в Slack/Discord надсилається
автоматично лише при `WARN`/`FAIL`, якщо не задано `-SkipNotification`.

Рекомендовано запускати щотижня або щомісяця окремим завданням
Планувальника — на відміну від `BRAVO_HEALTH.ps1`, це не входить до
типового набору завдань, встановлюваних `BRAVO_TASKS_INSTALL.ps1`
(потрібно додати вручну, якщо плануєте регулярний drill).

## 7. Окремі етапи налаштування

Комплексний setup можна обмежити одним етапом:

```powershell
.\BRAVO_SETUP.ps1 -Action Credentials
.\BRAVO_SETUP.ps1 -Action Scheduler
.\BRAVO_SETUP.ps1 -Action Test -ValidateOnly
```

Оновлення лише назви установи, коду і префікса:

```powershell
.\BRAVO_SETUP.ps1 -Action Credentials -CredentialComponent Institution
```

Розширене керування credentials:

```powershell
.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Ensure -Component Required -StoreFor Both
.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Test -Component Required -StoreFor Both
.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Set -Component Institution -StoreFor Both
```

Основні дії:

| Дія | Поведінка |
|---|---|
| `Ensure` | створює лише відсутні записи, наявні не змінює |
| `Set` | створює або перезаписує вибрані записи |
| `Add` | помилка, якщо запис уже існує |
| `Update` | помилка, якщо запису немає |
| `Test` | лише перевіряє читання |
| `Remove` | видаляє вибрані записи; використовуйте обережно |

`Component Required` автоматично вибирає credentials для фактично ввімкнених
компонентів. Доступні також `All`, `SFTP`, `SMB`, `Slack`, `Discord`, `Archive`
та `Institution`.

## 8. Планувальник завдань

`.\BRAVO_TASKS_INSTALL.ps1` створює завдання у `\BRAVO\`:

| Завдання | Типовий розклад | Призначення |
|---|---|---|
| `BRAVO_ARCHIV` | щодня `23:00` | архівація та передача копій |
| `BRAVO_MAINTENANCE` | щодня `23:55` | обслуговування BRAVO |
| `BRAVO_ARCHIV_HEALTH` | кожні 240 хв. від `00:15` | контроль служб і локальних/SFTP/SMB копій |

Архівація, maintenance і health-check використовують спільний
`C:\ProgramData\BRAVO\Locks\BRAVO_OPERATION.lock`. Якщо інша операція вже працює, наступна не накладається
на неї. Backup і maintenance можуть очікувати звільнення lock до 360 хвилин;
health-check пропускає перевірку під час активного backup.

Lock — це реальний ексклюзивний файловий handle (`FileShare.None`), а не
маркер-файл, тому Windows сама звільняє його одразу, якщо процес завершився
аварійно; окремої "stale lock"-логіки не потрібно. Для діагностики файл
містить JSON: `pid`, `processStartTime`, `hostname`, `operation`
(`Archive`/`Maintenance`), `startedAt`, `packageVersion`, `config`,
`GenerationId` (для Archive) —
`processStartTime` і `hostname` дають змогу відрізнити той самий PID,
перевикористаний іншим процесом після перезавантаження сервера, від справді
активного запуску, коли з'ясовуєте, хто саме тримає lock на спільному сервері.

Hard termination може пропустити VSS `finally`. Тому Archive атомарно записує
точні BRAVO-owned Shadow IDs у
`C:\ProgramData\BRAVO\State\BRAVO_VSS_OWNERSHIP.json`. Наступний власник
machine-wide lock видаляє лише ці ID та `BRAVO_VSS_*` links; чужі VSS
snapshots не перелічуються для масового видалення. Якщо ownership state
пошкоджений або exact-ID cleanup не вдався, новий backup блокується, а state
лишається для повторної спроби й діагностики.

Якщо перед архівацією або maintenance встановлена керована служба не має стану
`Running`, Slack/Discord одразу отримує одне зведене попередження.
`BRAVO_ARCHIV` ніколи не зупиняє і не запускає служби — керування ними виконує
лише `BRAVO_MAINTENANCE`. MODEL, BLOG і BRAVOEXCH входять до одного VSS
Snapshot Set і мають один `GenerationId`: one backup generation = one
point-in-time. Якщо set створити не вдалося, виконується zero live archive
operations і запуск повертає
помилку. Погодинний health-check повторно контролює встановлені
служби, крім служб із типом запуску `Disabled`; однакові health-alert
пригнічуються на інтервал `RepeatAlertAfterHours`.

Встановити або оновити лише завдання:

```powershell
.\BRAVO_TASKS_INSTALL.ps1 -ConfigPath ".\BRAVO.config"
```

Перевірити визначення без встановлення:

```powershell
.\BRAVO_TASKS_INSTALL.ps1 -ConfigPath ".\BRAVO.config" -ValidateOnly
```

Видалити завдання:

```powershell
.\BRAVO_TASKS_UNINSTALL.ps1 -ConfigPath ".\BRAVO.config"
```

Перед реальним встановленням скрипт:

- відмовляється створювати `SYSTEM`-завдання з каталогу профілю користувача;
- перевіряє та захищає ACL runtime-каталогу;
- вмикає журнал `Microsoft-Windows-TaskScheduler/Operational`;
- перевіряє фактичну реєстрацію Action, Arguments і WorkingDirectory;
- у разі помилки повертає попередній стан завдань.

## 9. Ручний production-запуск

Архівація:

```powershell
.\BRAVO_ARCHIV.ps1 -NoPause
```

Maintenance:

```powershell
.\BRAVO_MAINTENANCE.ps1
```

Health-check:

```powershell
.\BRAVO_HEALTH.ps1
```

Ці команди виконують **фактичні операції**. Перед першим production-запуском
обов'язково виконайте `.\BRAVO_SETUP.ps1` або щонайменше dry-run.

`.\BRAVO_HEALTH.ps1` — read-only, лише перевіряє стан, нічого не архівує й не
видаляє. Ручний запуск без прав адміністратора (звичайна консоль/подвійний
клік) сам запитує підвищення прав (UAC) і перезапускається elevated — без
цього немає права запису в `LOGS`/`TEMP` комплекту, і локальна помилка прав
раніше помилково показувалась як "SFTP недоступний". Заплановане завдання
`BRAVO_ARCHIV_HEALTH` як і раніше виконується від `SYSTEM` без жодного UAC.
ACL каталогу комплекту при цьому НЕ послаблюється — рішення саме в
підвищенні прав запуску, а не в дозволі запису звичайним користувачам.
`BRAVO_ARCHIV.ps1`/`BRAVO_MAINTENANCE.ps1` мають власний, простіший
self-elevation (та сама SYSTEM/Administrator-перевірка), але без явного
розрізнення interactive/non-interactive і без окремої обробки скасованого
UAC — можливий подальший крок, якщо той самий сценарій виявиться проблемою
і для них.

Додатковий параметр архівації `-SyncBAZA` примусово запитує синхронізацію BAZA,
якщо її дозволяє конфігурація. Для maintenance доступні службові перемикачі
`-ForceRestore`, `-DisableSizeCheck`, `-EnableAllSlack`, `-DisableAllSlack`,
`-AutoShutdown on|off` і `-ArchiveAfterMaintenance on|off`; змінювати їх слід
лише з розумінням впливу на production.

## 10. Оновлення в установі

1. Зробіть копію поточного `BRAVO.config`.
2. Атомарно замініть весь комплект новою версією: виконувані `.ps1`,
   `VERSION.json`, документацію та весь каталог `modules`. Не змішуйте модулі й
   wrappers із різних версій.
3. Після копіювання вилучіть застарілі root-бібліотеки
   `BRAVO_COMPATIBILITY.ps1`, `BRAVO_CREDENTIALS.ps1`,
   `BRAVO_HELPER_LOGGING.ps1`, `BRAVO_NOTIFICATION.ps1`,
   `BRAVO_ARCHIVE_HELPERS.ps1`, `BRAVO_ARCHIV_RUNTIME.ps1` і
   `BRAVO_SYSTEM_HELPERS.ps1`.
4. Порівняйте та перенесіть локальні значення шляхів, компонентів, служб,
   SFTP/SMB і розкладу у новий `BRAVO.config`.
5. Не переносіть у config секрети, назву установи, код або префікс — вони вже
   зберігаються у Credential Manager.
6. Запустіть:

```powershell
.\BRAVO_SELF_TEST.ps1
.\BRAVO_SETUP.ps1 -ValidateOnly
.\BRAVO_SETUP.ps1
```

Повторний `.\BRAVO_SETUP.ps1` використовує режим `Ensure`: наявні credentials не
запитуються і не перезаписуються. Завдання оновлюються відповідно до поточного
`schedulerSettings`.

## 11. Якщо вручну працює, а за розкладом — ні

Найчастіша причина — різний контекст: вручну скрипт бачить credentials і доступ
поточного користувача, а завдання працює від `SYSTEM`.

Виконайте від адміністратора:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -ConfigPath ".\BRAVO.config" -InspectOnly
.\BRAVO_TASKS_DIAGNOSE.ps1 -ConfigPath ".\BRAVO.config" -TestAccess
```

Для перевірки webhook одним реальним повідомленням:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -ConfigPath ".\BRAVO.config" -TestAccess -SendTestNotification
```

Діагностика показує:

- чи існують і ввімкнені всі очікувані завдання;
- точні Action, Arguments, WorkingDirectory і task account;
- `LastTaskResult` з текстовим поясненням;
- історію Task Scheduler Operational;
- dry-run і доступи саме від `SYSTEM`.

Типові `LastTaskResult`:

| Код | Значення |
|---|---|
| `0x00000000` | успішно |
| `0x00041301` | завдання зараз виконується |
| `0x00041303` | завдання ще не запускалося |
| `0x80070002` | не знайдено скрипт або config |
| `0x80070005` | відмовлено в доступі |
| `0x8007010B` | некоректний робочий каталог |
| `0x8007052E` | помилка входу облікового запису |

Якщо 7-Zip повертає code `1` або іншу помилку, у тому самому журналі
`BRAVO_ARCHIV_*.log` після загального повідомлення записуються останні рядки
stdout/stderr. Зазвичай вони містять точний недоступний, заблокований або
пропущений файл.

Якщо tasks відсутні, запустіть `.\BRAVO_SETUP.ps1 -Action Scheduler`. Якщо
діагностика не читає credentials від `SYSTEM`, повторіть:

```powershell
.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Ensure -Component Required -StoreFor Both
```

На локалізованій Windows Task Scheduler може показувати `SYSTEM` як `СИСТЕМА`
або іншу перекладену назву. Інсталятор порівнює вбудовані облікові записи за
мовно-незалежним SID, тому це не є помилкою.

## 12. Логи та результати

**Два різні типи журналів (не плутати):**

*Логи самих скриптів* (виконання `BRAVO_ARCHIV`/`BRAVO_MAINTENANCE`/
`BRAVO_HEALTH`) — завжди у `<RuntimeRoot>\LOGS`, helper-логи — у
`<RuntimeRoot>\LOGS\HELPERS`. Не залежать від `LIMSRoot`/`SystemLogRoot`/
`BackupRoot` і не налаштовуються через `pathSettings`. Туди ж Maintenance
кладе власні артефакти запуску (`file_sizes_*.csv`, `restore_done_*.marker`).

*Системні журнали* BRAVO Trace, `exchangAPI`, Apache і BRAVO Web application
logs `BRAVO_MAINTENANCE` переносить під `SystemLogRoot` (за замовчуванням
`<EffectiveLIMSRoot>\ARCHIV\LOGS`):

```text
<SystemLogRoot>\
├── Trace\
│   ├── YYYY-MM-DD\TraceSRV_1.out, TraceSRV_2.out, …
│   └── Trace_YYYY-MM-DD.mdz            після Retention.ArchiveDays
├── exchangAPI\
│   ├── YYYY-MM-DD\exchangAPI_1.log, exchangAPI_2.log, …
│   └── exchangAPI_YYYY-MM-DD.mdz
└── BravoWeb\
    ├── Apache\
    │   ├── YYYY-MM-DD\access_1.log, error_1.log, ssl_error_1.log, …
    │   └── Apache_YYYY-MM-DD.mdz
    └── Application\
        ├── YYYY-MM-DD\
        │   ├── bravoexec_1.log, vet_1.log, …
        │   └── API\request_1.log        вкладена структура зберігається
        └── BravoWeb_YYYY-MM-DD.mdz
```

Marker `restore_done_yyyyMMdd.marker` (у `<RuntimeRoot>\LOGS`) створюється лише
після успішної реставрації, перевіреного after-архіву та SHA512. Записується
атомарно у UTF-8 і не створюється після примусового `-ForceRestore`. Тривкий
стан реставрації — `%ProgramData%\BRAVO\State\BRAVO_RESTORE_STATE.json`.

**Джерела.** Trace береться виключно з `bravo.ini`, секція `[Debug]`, ключ
`FILE`; у `BRAVO.config` цей параметр не дублюється. Сам `bravo.ini` має рівно
один очікуваний шлях, визначений архітектурою ОС —
`%SystemRoot%\SysWOW64\bravo.ini` на x64 і `%SystemRoot%\System32\bravo.ini`
на x86; інших місць не перевіряється, а відсутність файлу є помилкою
конфігурації з назвою перевіреного шляху. Відносне значення `FILE` (наприклад
`FILE=TraceSRV.out`) резолвиться від каталогу інсталяції BRAVO.

`exchangAPI` шукається у фактичному робочому каталозі служби
(`Win32_Service.PathName`, а для служб під NSSM — `AppDirectory`/`Application`
з `HKLM\SYSTEM\CurrentControlSet\Services\<ім'я>\Parameters`) за обома
шаблонами `exchangAPI_*.log` і `exchangAPI*.log` з дедуплікацією за повним
шляхом. Apache — тільки `*.log` безпосередньо в `apache\logs` (`httpd.pid`,
`*.lock` і тимчасові файли не чіпаються). `www\log` обходиться рекурсивно, і
відносна структура каталогів зберігається в призначенні.

**Нумерація.** Номер завжди `MAX(наявних) + 1` у межах конкретного
каталогу-дати (для BRAVO Web — конкретного відносного підкаталогу всередині
неї): пропущені номери не перевикористовуються, наявний файл ніколи не
перезаписується, а порожній журнал лишається в джерелі й номера не отримує.
Кожен компонент завершується агрегованим рядком
`знайдено / непорожніх / переміщено / порожніх / пропущено / помилок`.

**Retention** програмних журналів працює за двома незалежними політиками:

| Налаштування | Що визначає |
|---|---|
| `Retention.ArchiveDays` | вік каталогу `YYYY-MM-DD`, після якого він пакується в `.mdz` |
| `Retention.CompressedLogDays` | вік уже стиснутого `.mdz`, після якого архів видаляється |
| `Retention.LogDays` | вік службових журналів самого Maintenance у `<RuntimeRoot>\LOGS` |

Retention системних журналів (`ArchiveDays`/`CompressedLogDays`) працює лише
під `SystemLogRoot`; retention логів скриптів (`LogDays`) — лише під
`<RuntimeRoot>\LOGS`; retention backup — лише під `BackupRoot`. Це три
незалежні політики, які не заходять у чужі каталоги.

### Manifest-и backup generation (`MANIFESTS`)

`BRAVO_BACKUP_<GenerationId>.json` — manifest конкретної generation backup
(статус, компоненти, шляхи архівів і хешів) — з dev.14 лежить у
`<BackupRoot>\MANIFESTS\`, окремо від `LOGS\`/`TEMP\`. Це навмисно третє,
незалежне сховище: lifecycle manifest-а прив'язаний до generation
(видаляється разом з нею при retention backup, розділ вище), а не до
`LogDays`/`CompressedLogDays` — жодна з політик retention журналів на
`MANIFESTS` не діє й не повинна діяти.

Каталог `MANIFESTS\` створюється автоматично при першому записі нового
manifest-а. Старі `BRAVO_BACKUP_*.json`, що лишились безпосередньо в
корені `BackupRoot` з версій до dev.14, переносяться туди ідемпотентно
першим же запуском `BRAVO_MAINTENANCE.ps1` після оновлення — без ручних
дій і без production-простою; докладніше й що робити при конфлікті
перенесення — [OPERATIONS.md](OPERATIONS.md#manifest-и-backup-generation-перенесено-в-manifests-dev14).
`BRAVO_HEALTH.ps1` читає manifest-и (з `MANIFESTS\` і, для сумісності,
з кореня `BackupRoot`), але ніколи їх не переносить і не створює.

Каталог-дата видаляється **лише** після успішного створення архіву та
успішної перевірки `7z t`. Вік `.mdz` рахується за датою в його імені, а не
за часом файлу, і видаляються лише архіви очікуваного формату свого
компонента. Очищення службових журналів Maintenance лишається нерекурсивним
і працює тільки з верхнім рівнем `<RuntimeRoot>\LOGS` за whitelist імен, тому
до `SystemLogRoot` (`Trace\`, `exchangAPI\`, `BravoWeb\`) воно не дістає.

**Міграція.** Старі каталоги `<SystemLogRoot>\..\Trace`,
`..\exchangAPI` і `..\Br-a-vo.web` (тобто попередній
`<ArchiveRoot>\{Trace,exchangAPI,Br-a-vo.web}`) переносяться під
`SystemLogRoot` автоматично при першому ж запуску Maintenance. Міграція
ідемпотентна: повторний запуск не створює дублікатів, джерело видаляється
лише після підтвердженого переміщення, а часткова невдача лишає невдалі файли
й legacy-каталог для наступного запуску.

Допоміжні скрипти `BRAVO_SETUP`, `BRAVO_DRY_RUN`,
`BRAVO_CREDENTIALS_SETUP`, `BRAVO_TASKS_INSTALL`,
`BRAVO_TASKS_UNINSTALL`, `BRAVO_TASKS_DIAGNOSE` і `BRAVO_SELF_TEST` створюють
окремий transcript для кожного процесу:

```text
<RuntimeRoot>\LOGS\HELPERS\<SCRIPT>_yyyyMMdd_HHmmss_fff_PID<n>.log
```

У журналі є контекст запуску, консольний результат і фінальний process exit
code. Це дозволяє окремо бачити батьківський setup, дочірні етапи та перевірки
від `SYSTEM`. Helper-логи зберігаються 31 день. Якщо основний каталог
недоступний для запису, скрипт попереджає про це і використовує резервний
`%TEMP%\BRAVO\LOGS\HELPERS`.

Значення паролів, які вводяться через захищений prompt, у лог не виводяться.
Не передавайте секрети як довільні аргументи командного рядка.

Додатково переглядайте:

- Event Viewer → Applications and Services Logs → Microsoft → Windows →
  TaskScheduler → Operational;
- властивості завдань у `Task Scheduler Library\BRAVO`;
- `Last Run Result` і час наступного запуску.

Для dry-run код завершення `0` означає відсутність критичних проблем, `1` —
щонайменше одну критичну проблему. PowerShell-скрипти повертають код PowerShell
скрипта, тому результат можна використовувати в автоматичних перевірках.

### Коди завершення production-скриптів

`BRAVO_ARCHIV.ps1`, `BRAVO_MAINTENANCE.ps1` і `BRAVO_HEALTH.ps1` повертають
один зі стабільних кодів контракту `modules\BRAVO.ExitCodes`, а не просто
`0`/`1`. Це дозволяє зовнішньому моніторингу (Task Scheduler history, Zabbix)
розрізняти причину відмови, а не лише факт її наявності:

| Код | Значення |
|---|---|
| `0` | успішно |
| `10` | успішно, але в лозі були попередження |
| `20` | пропущено — спільний lock зайнятий іншою операцією |
| `30` | некоректна конфігурація |
| `31` | недоступні credentials |
| `32` | порушено цілісність інструментів (`TOOLS_MANIFEST.json`) — запуск заблоковано |
| `33` | порушено цілісність PowerShell-комплекту (`RUNTIME_MANIFEST.json`) — запуск заблоковано до завантаження модулів |
| `34` | `BRAVO.config` послаблює захист (вимкнено перевірку інструментів або VSS-узгодженість) — запуск заблоковано |
| `35` | розгорнуто старішу версію, ніж уже запускали на цьому сервері — запуск заблоковано |
| `36` | (лише `BRAVO_HEALTH.ps1`) недостатньо прав ОС для запуску — ручний запуск без адміністративних прав в explicit non-interactive режимі, скасований UAC, або `UnauthorizedAccessException` при записі в `LOGS`/`TEMP`; реальні health-checks НЕ виконувались |
| `37` | (лише `BRAVO_HEALTH.ps1`) `LOGS`/`TEMP` недоступні з причини, що НЕ є браком прав (диск повний, `PathTooLong`, файлова система) — реальні health-checks НЕ виконувались |
| `40` | помилка локальної архівації або відновлення з архіву |
| `41` | не підтверджено цілісність (`7z t`) |
| `42` | не вдалося створити або фактично звірити SHA512 |
| `50` | помилка SFTP |
| `51` | помилка SMB |
| `60` | інша критична помилка обслуговування (Maintenance) |
| `70` | health-check критичний |
| `90` | непередбачена внутрішня помилка |

При одночасних відмовах перемагає найвищий пріоритет: lock > конфігурація >
credentials > локальна архівація > 7-Zip integrity > SHA512 > SFTP > SMB > maintenance >
health > лише попередження. Код `90` має найвищий пріоритет за все — він
означає, що runtime не встиг сам категоризувати відмову.

Сам код `70` (health-check критичний) — лише один агрегований показник;
щоб зовнішній моніторинг бачив, який саме напрямок деградував, а не тільки
факт наявності проблеми, програмний Health API (`Invoke-BRAVOHealthCheck`)
повертає окремі `LocalVerified`/`SftpVerified`/`SmbVerified` у result object
— відмова одного напрямку (наприклад SFTP недоступний) не впливає на
значення інших, бо кожен перевіряється незалежним викликом.

### Матриця діагностики за кодом завершення

Куди дивитись у журналі `LOGS\BRAVO_ARCHIV_*.log` /
`BRAVO_MAINTENANCE_*.log` / `BRAVO_ARCHIV_HEALTH_*.log` для кожного коду:

| Код | Найімовірніша причина | Де дивитись |
|---|---|---|
| `20` | Інший екземпляр Archive/Maintenance ще виконується | `C:\ProgramData\BRAVO\Locks\BRAVO_OPERATION.lock` (JSON: `pid`, `hostname`, `operation`, `startedAt`, `GenerationId`); збільшіть `OperationLockWaitMinutes`, якщо це штатне перекриття довгих завдань |
| `30` | Некоректний/відсутній розділ `BRAVO.config` (`maintenanceSettings`, `pathSettings` тощо) | Перший `[ERROR]` одразу після `=== ПЕРЕВІРКА СУМІСНОСТІ СИСТЕМИ ===`; `.\BRAVO_SETUP.ps1 -ValidateOnly` відтворює ту саму перевірку без production-дій |
| `31` | Відсутній або порожній запис Credential Manager для потрібного компонента | Рядок `credentialInitializationError`/`archiveCredentialInitializationError` у консольному виводі; `.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Test -Component Required -StoreFor Both` |
| `32` | SHA-256 файлу в `Tools/` не збігається з еталонним `TOOLS_MANIFEST.json`, або маніфест відсутній/пошкоджений | Рядок `ЦIЛIСНIСТЬ IНСТРУМЕНТIВ ПОРУШЕНО` на старті логу. Якщо оновлення інструментів свідоме — оновіть маніфест на робочій станції (`ci\Update-BRAVOToolsManifest.ps1 -Apply`), перегляньте `git diff`, розгорніть новий комплект. Якщо ні — це можлива підміна: заплановане завдання виконується від `SYSTEM`, тому інструмент отримав би найвищі права |
| `33` | SHA-256 файлу комплекту не збігається з `RUNTIME_MANIFEST.json`, файл відсутній, або в комплекті з'явився сторонній `.ps1`/`.psm1` | Рядок `ЦІЛІСНІСТЬ КОМПЛЕКТУ ПОРУШЕНО` — це найперше, що виводиться, ще до завантаження модулів. Якщо оновлення коду свідоме: `ci\Update-BRAVORuntimeManifest.ps1 -Apply` на робочій станції, `git diff`, розгортання нового комплекту |
| `34` | `BRAVO.config` вимикає перевірку цілісності інструментів (`Mode = "Warn"`) або VSS-узгодженість (`backupConsistency.Mode ≠ "VSS"`) | Рядок `КОНФІГУРАЦІЯ ПОСЛАБЛЮЄ ЗАХИСТ` на старті. Конфігурація не входить до `RUNTIME_MANIFEST.json` (вона різна на кожному сервері), тому ці перемикачі перевіряються окремо — розбором AST, без виконання файлу. Якщо послаблення свідоме й тимчасове, встановіть `BRAVO_ALLOW_WEAKENED_SECURITY=1`: тоді воно лишає слід поза комплектом |
| `35` | `VERSION.json.packageVersion` нижчий за записаний у `C:\ProgramData\BRAVO\State\BRAVO_VERSION_STATE.json` | Рядок `ВІДКАТ ВЕРСІЇ` на старті. Старіший комплект проходить усі перевірки цілісності — разом із вразливостями, які відтоді закрили. Звірте `sourceCommit` розгорнутого й записаного. Якщо повернення на попередній реліз свідоме, встановіть `BRAVO_ALLOW_DOWNGRADE=1` |
| `36` | (лише `BRAVO_HEALTH.ps1`) ручний запуск без прав адміністратора: explicit `-NonInteractive` сесія без elevation, скасований UAC, або `UnauthorizedAccessException` при записі в `LOGS`/`TEMP` | Рядок `ПОМИЛКА СЕРЕДОВИЩА`/`КРИТИЧНА ПОМИЛКА: BRAVO HEALTH запущено без прав адміністратора` на старті. Запустіть від імені адміністратора вручну (з'явиться запит UAC автоматично) або переконайтесь, що заплановане завдання виконується від `SYSTEM`. SFTP/SMB/локальні перевірки при цьому коді НЕ виконувались — не плутати з `50`/`70` |
| `37` | (лише `BRAVO_HEALTH.ps1`) `LOGS`/`TEMP` недоступні з причини, що НЕ є `UnauthorizedAccessException` (диск повний, `PathTooLong`, пошкоджена файлова система) | Рядок `ПОМИЛКА СЕРЕДОВИЩА` / `Не вдалося використовувати runtime TEMP/LOGS: ...` на старті — конкретна причина в тексті. НЕ означає бракує прав адміністратора: перевірте вільне місце на диску й доступність самого шляху. SFTP/SMB/локальні перевірки НЕ виконувались |
| `40` | Провал створення архіву 7-Zip, або (Maintenance) провал відновлення з архіву | `[ERROR]` у секції `АРХІВАЦІЯ <компонент>`/`ВІДНОВЛЕННЯ`; останні рядки stdout/stderr 7-Zip записуються одразу після загального повідомлення |
| `41` | `7z test` не підтвердив цілісність | `Перевiрка цiлiсностi 7-Zip не пройдена` у секції `АРХІВАЦІЯ`; final artifact не публікується |
| `42` | SHA512 generation/verification failed після успішного `7z t` | Компонент `HASH`; тимчасові артефакти поточної generation прибираються, попередній valid backup лишається незмінним |
| `50` | SFTP: з'єднання, автентифікація або передача файлу | Секція `ЗАВАНТАЖЕННЯ АРХІВІВ НА SFTP` / `СИНХРОНІЗАЦІЯ BAZA НА SFTP`; перевірте `sftpHostKey` fingerprint і мережевий доступ до TCP 22 |
| `51` | SMB/NAS: недоступний UNC-шлях або облікові дані | Секція `КОПІЮВАННЯ АРХІВІВ НА NAS/SMB`; перевірте доступність UNC-шляху від `SYSTEM` через `BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess` |
| `60` | Maintenance: служби, диск, файлове господарство — усе, що не потрапляє під `40`/`41` | Секція, де `Результат: ПОМИЛКА` вперше з'являється в `BRAVO_MAINTENANCE_*.log`; часто — недостатньо вільного місця (`Limits.MinimumFreeSpaceGB`) або служба не в стані `Running` |
| `70` | Health-check: локальні/SFTP/SMB копії застаріли, або керована служба не працює | `BRAVO_ARCHIV_HEALTH_*.log`, рядки `[ERROR] Проблема ...`; дивіться `LocalVerified`/`SftpVerified`/`SmbVerified`, якщо результат читається програмно |
| `90` | Непередбачений виняток, якого runtime не встиг категоризувати | `Write-Error`/останній `[ERROR]` перед аварійним завершенням; часто вказує на прогалину в конфігурації, яку варто завести як окремий issue, а не лише перезапустити завдання |

Для `LastTaskResult` самого Task Scheduler (окремо від кодів вище —
це код запуску процесу, а не BRAVO) дивіться таблицю на початку цього
розділу.

## 13. Призначення файлів

### Основні точки входу

| Файл | Призначення |
|---|---|
| `BRAVO_SETUP.ps1` | комплексна інсталяція, credentials, tasks і тест |
| `BRAVO_DRY_RUN.ps1` | симуляція без production-операцій |
| `BRAVO_ARCHIV.ps1` | production-архівація |
| `BRAVO_MAINTENANCE.ps1` | production-обслуговування |
| `BRAVO_HEALTH.ps1` | контроль резервних копій і служб |
| `BRAVO_TASKS_DIAGNOSE.ps1` | діагностика Планувальника і запуск від `SYSTEM` |
| `BRAVO_RESTORE_TEST.ps1` | restore drill — розпакування останнього verified backup в ізольований каталог (розділ 6.1) |

### Службові файли

| Файл | Призначення |
|---|---|
| `BRAVO.config` | головна конфігурація BRAVO |
| `BRAVO_CREDENTIALS_SETUP.ps1` | керування записами Credential Manager |
| `modules\BRAVO.Credentials` | модуль читання/запису credentials |
| `modules\BRAVO.HelperLogging` | модуль transcript-журналювання допоміжних скриптів |
| `BRAVO_TASKS_INSTALL.ps1` | встановлення завдань |
| `BRAVO_TASKS_UNINSTALL.ps1` | видалення завдань |
| `modules\BRAVO.Compatibility` | модуль сумісності зі старими Windows/PowerShell |
| `modules\BRAVO.Archive` | runtime-модуль архівації; `BRAVO_ARCHIV.ps1` є тонким wrapper |
| `modules\BRAVO.Health` | runtime-модуль health-check; `BRAVO_HEALTH.ps1` є тонким wrapper |
| `modules\BRAVO.Maintenance` | runtime-модуль maintenance; `BRAVO_MAINTENANCE.ps1` є тонким wrapper |
| `BRAVO_SELF_TEST.ps1` | автоматичні регресійні тести |

Детальні параметри комплексного setup наведені у
[BRAVO_SETUP.md](BRAVO_SETUP.md), історія версій — у
[CHANGELOG.md](CHANGELOG.md), модель безпеки й порядок повідомлення про
вразливості — у [SECURITY.md](SECURITY.md), а чек-лист перед випуском
нової версії — у [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

### Гілки та release channel

`VERSION.json.releaseChannel` — це лише **нейтральний fallback**
(`"stable"`), однаковий на обох гілках у git. Реальний release channel
визначається динамічно під час завантаження конфігурації
(`Resolve-BRAVOReleaseChannelFromGit`, `BRAVO_CONFIG_LOADER.ps1`): якщо
поруч є каталог `.git`, значення читається напряму з `.git/HEAD`
(без виклику `git.exe`, який може бути відсутній на production-сервері):

| Гілка | Ефективний `releaseChannel` | Призначення |
|---|---|---|
| `developer` | `development` | Поточна розробка; може містити ще не повністю перевірені зміни |
| `master`/`main` | `stable` | Стабільний стан для production-розгортання |
| інша гілка / detached HEAD | статичне значення з `VERSION.json` (`stable`) | fallback, коли гілку не вдалося однозначно визначити |
| без `.git` (розгорнутий production-сервер) | статичне значення з `VERSION.json` (`stable`) | дистрибутив копіюється файлами, не клонується |

Раніше `releaseChannel` зберігався як буквальне значення, що вручну
різнилося між гілками — кожен merge `developer` → `master` вимагав
окремого follow-up commit, а fast-forward-мержі могли мовчки протягнути
значення в неправильний бік і в той, і в інший бік (AUD-016). Тепер
джерело не потребує ручного редагування цього поля взагалі:
`BRAVO_SELF_TEST.ps1` перевіряє, що на `developer` ефективний channel —
`development` (з `ReleaseChannelSource=git-branch`), а на `master`/`main`
— ніколи не `development`.

## 14. Правила безпеки

- не записуйте паролі, webhook URL або логіни у `.config`, `.ps1` чи
  логи;
- не розміщуйте SYSTEM runtime у каталозі, доступному звичайним користувачам
  на запис;
- не вимикайте `RequireProtectedRuntime`, окрім контрольованої міграції;
- не додавайте `-delete` до SFTP-синхронізації BAZA: хмара є накопичувальною;
- після зміни SFTP fingerprint перевірте його через незалежний довірений канал;
- пароль 7-Zip передається утиліті лише через redirected standard input і не
  повинен повертатися до аргументів процесу; це контролює self-test;
- перед production-змінами завжди виконуйте self-test, `-ValidateOnly` і
  dry-run;
- `enableArchiveDeletion` ніколи не видаляє останні `minimumRetainedVerifiedBackups`
  (за замовчуванням `1`) перевірених (SHA512 збігається) комплектів кожного
  компонента, навіть якщо вони старші за `archiveRetentionDays` — серія
  невдалих backup не повинна лишити компонент без жодної придатної копії;
- помилки завантаження `BRAVO.config` і читання Credential Manager
  (SFTP/SMB/архів/webhook) маскуються `Protect-BRAVOLogSecret` одразу при
  захопленні винятку, а не лише при подальшому записі в лог — ці
  повідомлення друкуються у консоль ще до того, як спрацює єдина точка
  масковки в `Write-Log`;
- `hostInformationSettings.PublicIPLookupEnabled` вимкнено за замовчуванням:
  без цього Slack/Discord-сповіщення звертаються до `api.ipify.org`/
  `checkip.amazonaws.com`, зайвої зовнішньої залежності, яка розкриває
  стороннім сервісам факт і час запуску backup. Увімкніть свідомо, якщо
  публічна IP-адреса потрібна в сповіщеннях.

## 15. Operator notification UX

Slack/Discord notifications are short operator summaries. The detailed
technical evidence stays in the referenced log file.

- ✅ SUCCESS: operation/check passed; the message says `Дій не потрібно`.
- ⚠️ WARNING: BRAVO can continue, but the message gives a concrete
  `Потрібна дія: ...`.
- 🚨 CRITICAL: backup, integrity, credentials or maintenance safety is at
  risk, with the reason and action at the top.

Host information is compact: `🖥️ SERVER · 10.10.150.102`. Public IP is shown
only when lookup is enabled and a valid address is returned. Institution lines
use `🏢`.

Backup health terminology:

- SUCCESS: `Остання резервна копія`.
- WARNING/ERROR: `Остання успішна резервна копія`.
