# BRAVO 5.3.0-dev.3 — архівація, обслуговування та контроль резервних копій

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
> Рекомендоване розташування RuntimeRoot — `C:\Program Files\BRAVO-Toolkit`; його назва не
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
| Змінити локальні (site-специфічні) налаштування через GUI | `.\BRAVO_CONFIGURATOR.ps1` |
| Запустити архівацію вручну | `.\BRAVO_ARCHIV.ps1 -NoPause` |
| Запустити обслуговування вручну | `.\BRAVO_MAINTENANCE.ps1` |
| Запустити health-check вручну | `.\BRAVO_HEALTH.ps1` |
| Перевірити, що backup реально відновлюється | `.\BRAVO_RESTORE_TEST.ps1` |
| Побачити, з чого можна відновитися | `.\BRAVO_DATA_RESTORE.ps1 -ListGenerations` |
| Відновити дані з резервної копії | `.\BRAVO_DATA_RESTORE.ps1 -Mode OutOfPlace -TargetPath "D:\RESTORE"` |
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
- доступний VSS на локальних томах із `MODEL`, `BLOG` і `BRAVOEXCH` (див.
  застереження щодо `diskshadow.exe` нижче, якщо ці компоненти на різних
  томах);
- доступ до SFTP через TCP 22, якщо SFTP-компоненти ввімкнені;
- доступ до Slack/Discord через HTTPS 443, якщо сповіщення ввімкнені;
- доступ до потрібного UNC-шляху, якщо SMB/NAS ввімкнений.

### Підтримувані версії Windows

| Рівень | Системи |
|---|---|
| **Supported** | Windows Server 2019+, Windows 10/11, Windows PowerShell 5.1 |
| **Legacy best-effort** | Windows Server 2012 R2, Windows Server 2016 (без гарантій) |
| **Unsupported** | Windows 7, Windows Server 2008 R2, PowerShell 3.0 |

> **Застереження (Windows 10/11, підтверджено 2026-09-01):** `diskshadow.exe`
> — компонент, гарантовано доступний на Windows Server, але на клієнтських
> Windows 10/11 його наявність **не гарантована** (підтверджено відсутнім у
> `%SystemRoot%\System32` на кількох реальних Windows 10 Pro-машинах, включно
> з build 19045/22H2). BRAVO вимагає `diskshadow.exe` лише коли джерела
> архіву (`MODEL`/`BLOG`/`BRAVOEXCH`) розташовані на **кількох різних
> томах** — тоді атомарний багатотомний VSS Snapshot Set неможливий без
> нього, і `BRAVO_DRY_RUN.ps1`/`BRAVO_SETUP.ps1` fail-closed зупиняються на
> `[FAIL] VSS` ще до кроку реєстрації планувальника (це навмисна поведінка
> — тихе створення кількох незалежних однотомних знімків і видача їх за
> єдиний узгоджений набір становило б реальний ризик цілісності backup).
> Якщо цільова машина — Windows 10/11 client без `diskshadow.exe`:
> перевірте `Test-Path "$env:SystemRoot\System32\diskshadow.exe"` заздалегідь,
> і за потреби розмістіть `MODEL`, `BLOG` і `BRAVOEXCH` на **одному томі**
> (тоді достатньо однотомного `Win32_ShadowCopy.Create`, `diskshadow.exe` не
> потрібен). Архітектурне рішення про підтримку багатотомних джерел без
> `diskshadow.exe` (наприклад, через VSS COM API) — окреме, ще не ухвалене.

Archive, Health, Maintenance і DataRestore визначають рівень при кожному запуску
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
| `WinSCPnet.dll` | Автентифікований тест доступу SFTP |
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
> Перед `-Apply` оновіть для кожного нового чи зміненого бінарника запис
> `provenance` у `Tools\TOOLS_MANIFEST.json` (версія, офіційний пакет, його
> SHA-256, шлях файлу в пакеті, дата завантаження). Без нього `-Apply`
> нічого не записує. Докладніше: `SECURITY.md`.
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
C:\Program Files\BRAVO-Toolkit\    RuntimeRoot — комплект
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

C:\LIMS\                           LIMSRoot — інсталяція LIMS ("" = AUTO зі служби)
├── bravo.exe
├── Model\
└── bravoexch\

C:\LIMS\ARCHIV\LOGS\               SystemLogRoot — системні журнали ("" = AUTO)
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
    LIMSRoot      = "C:\LIMS"   # або "" — AUTO зі встановленої служби BRAVO
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

## 3. Що налаштувати (built-in дефолти + `BRAVO.local.config`)

> **Змінено в 5.3 (issue #216).** `BRAVO.config` більше НЕ входить у
> release-пакет і не є частиною нормального runtime-конфігураційного
> графа: production-скрипти й `BRAVO_CONFIGURATOR.ps1` не підхоплюють
> його автоматично, навіть якщо він фізично лежить поруч. Канонічні
> built-in дефолти в 5.3 — це код комплекту, а не файл; будь-яке
> відхилення від дефолту задається через **`BRAVO.local.config`**
> (data-only, `'dot.path' = значення`, шаблон — `BRAVO.local.config.example`),
> а секрети — через Windows Credential Manager. За контрактом 5.3 legacy
> `BRAVO.config` (5.2) читає лише migration-інструментарій (розділ 10) — нову
> production-інсталяцію 5.3 наводьте без нього. Виняток на час міграції:
> production-скрипт, запущений з явним `-ConfigPath` на legacy-файл (зокрема
> завдання Планувальника, встановлене з таким аргументом), досі виконує його
> як основний шар конфігурації.
> Канонічний опис джерел конфігурації й секретів —
> розділ 4, підрозділ «Джерела конфігурації та секретів у 5.3».

Рекомендований спосіб — `.\BRAVO_CONFIGURATOR.ps1`: інтерактивний GUI поверх
`BRAVO.local.config` — schema-driven форма з усіма 138 override-ключами,
presets, керуванням Credential Manager, попереднім переглядом ефективної
конфігурації і атомарним застосуванням (backup + перевірка хешу +
автоматичний rollback при помилці). Ручне редагування `BRAVO.local.config`
(текстовий data-only hashtable-файл, ніколи не виконується як код) так само
підтримується.

Перед першим запуском перевірте, чи потрібні override для таких секцій
(ключі задаються в `BRAVO.local.config` через dot-path, наприклад
`'pathSettings.BackupRoot' = 'E:\ARCHIV'`; повний канонічний перелік і
значення за замовчуванням — `BRAVO.local.config.example`):

| Секція | Що перевірити |
|---|---|
| `bravoSettings` | `NotificationProvider` (`slack` або `discord`), `NotificationMode` і `NotificationRouting` (severity → GENERAL/ALERTS) |
| `pathSettings` | `LIMSRoot`/`SystemLogRoot`/`BackupRoot` — усі три `""`=AUTO (розділ 2); `ArchiveRoot` більше немає |
| `maintenanceSettings` | імена служб, каталог Br-a-vo.web, таймаути, `Retention.ArchiveDays` / `Retention.CompressedLogDays` (розділ 12) |
| `maintenanceSettings.Limits` | `MinimumFreeSpaceGB`, `ExcludedDrives`, `MaximumMdFileSizeGB`, опційний `EstimatedSpaceMarginPercent` (розділ 3.3) |
| `componentSettings` | які архіви, BAZA, SFTP і SMB потрібно виконувати; `SFTP.Enabled`/`SMB.Enabled` — глобальні вимикачі destination (розділ 3.1) |
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
- health-check кожні 240 хвилин, починаючи з `00:30` (слот зсунуто повз ~16-хвилинне вікно BAZASync о `:00`; при зайнятій архівації прогін чекає її завершення до `Health.BusyWaitMinutes` хв, дефолт 60).

Початково вимкнено:

- локальну копію `BAZA_APP` (`BAZA_APP_LOCAL`);
- локальну копію `BAZA_WWW` (`BAZA_WWW_LOCAL`);
- копіювання архівів на SMB/NAS.

### 3.1. Глобальні вимикачі зовнішніх сховищ (5.2.2)

```text
componentSettings.SFTP.Enabled
├── ArchiveUpload
├── (Synchronization.)BAZA_APP_SFTP
└── (Synchronization.)BAZA_WWW_SFTP

componentSettings.SMB.Enabled
└── ArchiveCopy
```

`SFTP.Enabled = $false` / `SMB.Enabled = $false` — головні вимикачі
відповідного destination: вимикають ВСІ автоматичні мережеві операції
(архіви, BAZA-синхронізацію, Health-моніторинг, Dry Run проби) і знімають
вимогу креденшелів, **не змінюючи** дочірні прапорці (`ArchiveUpload`,
`ArchiveCopy`, `BAZA_*_SFTP`) — повернення `Enabled = $true` відновлює
попередню поведінку без повторного налаштування. Відсутній ключ (конфіг
5.2.1 і старіші) трактується як `$true`, тобто оновлення не змінює
поточну поведінку.

Ручні операторські дії лишаються доступними незалежно від вимикача:
`BRAVO_DATA_RESTORE.ps1 -Source SFTP`, `BRAVO_BAZA_RECONCILE.ps1`, явне
додавання SFTP/SMB-креденшелів через `BRAVO_CREDENTIALS_SETUP.ps1`.

**Local-only режим** (`SFTP.Enabled = $false` і `SMB.Enabled = $false`
одночасно) — валідна production-конфігурація: локальна архівація,
локальна BAZA, service/local-backup Health, notifications продовжують
працювати; scheduled завдання `BRAVO BAZA Synchronization` не
реєструється; SFTP/SMB-креденшели не вимагаються.

Приклади override у `BRAVO.local.config` — розділ "Глобальні вимикачі
зовнішніх сховищ" у `BRAVO.local.config.example`.

#### Профілі напрямків резервного копіювання

Профіль — назва для пари головних вимикачів; нових ключів конфігурації
немає. Відображення має одне джерело —
`Get-BRAVOConfiguratorBackupDestinationProfile`
(`modules\BRAVO.Configurator\BRAVO.Configurator.Presets.psm1`). Топологія
профілю відповідає пресету Configurator, але набір значень визначено явно:
дефолти нової інсталяції дорівнюють дефолтам конфігурації, крім вимикачів
напрямків.

| Профіль (`-BackupDestination`) | Пресет Configurator | `SFTP.Enabled` | `SMB.Enabled` | `SMB.ArchiveCopy` | BAZA |
|---|---|---|---|---|---|
| `Cloud` — Хмара (дефолт) | `LocalPlusSFTP` | `$true` | `$false` | — | не змінюється (дефолти) |
| `CloudAndSamba` — Хмара + Samba | `LocalPlusSFTPAndSMB` | `$true` | `$true` | `$true` | не змінюється (дефолти) |
| `SambaOnly` — Лише Samba | `LocalPlusSMB` | `$false` | `$true` | `$true` | `BAZA_*_LOCAL = $true` |
| `LocalOnly` — Лише локально | `LocalOnly` | `$false` | `$false` | — | `BAZA_*_LOCAL = $true` |

`SFTP.ArchiveUpload` жоден профіль не пише: для `Cloud` і `CloudAndSamba`
очікуване значення — дефолт конфігурації (`$true`); для `SambaOnly` і
`LocalOnly` вивантаження за вимкненого SFTP ефективно вимкнене.

Профіль застосовує `deploy\Install-BRAVOServer.ps1 -SeedLocalConfig
-BackupDestination <профіль>` і **лише** до нового `BRAVO.local.config`;
наявний файл ніколи не змінюється (без явного `-BackupDestination`
інсталятор повідомляє, що профіль не застосовано). Тому розгорнуті сервери поведінку не змінюють, а глобальний
дефолт `SMB.Enabled = $true` лишається як був: «Samba вимкнено» для нових
інсталяцій дає явне значення в новому файлі.

Явний `-BackupDestination` (будь-який профіль) інсталятор не ігнорує мовчки
(#434): він перевіряє ЕФЕКТИВНІ `SFTP.Enabled`, `SMB.Enabled`,
`SMB.ArchiveCopy`, а лише для `Cloud` і `CloudAndSamba` ще й `SFTP.ArchiveUpload`
(`Get-BRAVOEffectiveStorageConfiguration` поверх дефолтів і
`BRAVO.local.config`) проти значень профілю. Без `-SeedLocalConfig` і без
наявного файла інсталяція зупиняється до завантаження й будь-якого запису;
комплект без `BRAVO.Configurator`, нерозбірний наявний файл або наявний файл,
що суперечить профілю, зупиняють її до копіювання в каталог інсталяції з
назвою профілю й каналу, і файл не змінюється. Деталі — `deploy\README.md`.

Чому профілі з Samba пишуть `SMB.ArchiveCopy = $true`: дефолт
`ArchiveCopy` — `$false`, а `SMB.Enabled` сам по собі нічого не копіює.
Профілі з SFTP не пишуть BAZA-прапорців: діють дефолти конфігурації
(`BAZA_APP_SFTP = $true`, `BAZA_WWW_SFTP = $false`), а синхронізацію
BAZA WWW через SFTP вмикають свідомо для конкретного сервера.
`SambaOnly` і `LocalOnly` вмикають локальну BAZA (`BAZA_*_LOCAL = $true`),
бо BAZA-over-SMB не існує, а `BAZA_*_SFTP` при вимкненому SFTP не діють.
Пресет Configurator на вже налаштованому сервері, як і раніше, перемикає
головні вимикачі й BAZA-прапорці (зокрема `LocalPlusSFTP` вмикає
`BAZA_*_SFTP`) та не чіпає `ArchiveUpload`/`ArchiveCopy` — тому профілі
інсталятора й пресети UI свідомо різняться BAZA-прапорцями.

«Лише локально» охоплює дані й журнали: архіви, BAZA SFTP-синхронізацію,
вивантаження журналів Trace/exchangAPI і власних журналів. Сповіщення
Slack/Discord, Operations-звітність і запит публічної IP цей профіль не
вимикає (рішення власника). Self-test
`BackupDestinations/EveryOutboundChannelGatedByStorageEffective` перевіряє,
що кожне місце runtime-коду, яке відкриває WinSCP-сесію чи процес
WinSCP.com або підключає NAS як мережевий диск, досяжне лише під
`storageEffective.SFTP`/`SMB`; винятки — ручні інструменти оператора
(`BRAVO_BAZA_RECONCILE.ps1`, `BRAVO_DATA_RESTORE.ps1 -Source SFTP`).

Health показує свідомо вимкнений напрямок одним інформаційним рядком у
підсумку консолі й у звіті «ВСЕ СПРАВНО» (`Хмара (SFTP): вимкнено
конфігурацією`, `NAS/SMB: вимкнено конфігурацією`), без WARNING і без
рядків по компонентах.

> Обмеження: `SMB.Enabled` не керує UNC-шляхами в `pathSettings`
> (наприклад, `BackupRoot`, якщо він вказаний як `\\server\share`) —
> це окремий, не пов'язаний з `componentSettings.SMB` механізм.

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

Якщо canonical source відсутній, а компонент раніше був у резервній копії
або підтверджений у discovery baseline, валідація завершується керованою
помилкою. Компонент, який увімкнений за замовчуванням, але ніколи не був на
цьому сервері (немає ні baseline, ні архіву в останньому COMPLETE manifest),
має статус `NotInstalled`: він пропускається з INFO без помилки (див.
«Склад backup set за наявністю» нижче). `MODEL` обов'язковий. Silent fallback до `LIMSRoot\Model`, `LIMSRoot\BLOG`,
`LIMSRoot\bravoexch` або довільного Apache-каталогу заборонений.

Ручне перевизначення будь-якого поля лишається можливим через
`$global:discoverySettings` у `BRAVO.config` (`Sources.MODEL`,
`Sources.BLOG`, `Sources.BRAVOEXCH`, `BravoRoot`, `WebRoot`,
`BravoIniPath` тощо) — задане вручну значення завжди має пріоритет над
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
блокує валідацію для будь-якого увімкненого та встановленого (не `NotInstalled`) компонента, що залежить від
неоднозначного `BRAVO_ROOT`/`WEB_ROOT` — доки адміністратор явно не
задасть потрібне значення через `discoverySettings.BravoRoot`/`WebRoot`
або не прибере зайву службу.

`BRAVO_SETUP.ps1 -ValidateOnly` також порівнює поточний discovery-
результат зі збереженим **baseline** і повідомляє про дрейф
(`Discovery drift: ...`), якщо джерело змінилося відносно останнього
підтвердженого запуску — наприклад, службу перейменували або canonical
source перестав збігатися з baseline. Це лише інформаційне попередження,
воно не блокує роботу.

Baseline — це **машинний стан**, а не журнал, тому він лежить у
`%ProgramData%\BRAVO\State\DISCOVERY_BASELINE.json`, поруч з рештою
стану (operation lock, стан відновлення, quiescence-маркер), і **переживає
перевстановлення комплекту в інший каталог**. Раніше він зберігався в
`<RuntimeRoot>\LOGS`, і чиста інсталяція в новий каталог лишала його
позаду разом із захистом, який він дає: новий комплект бачив «перший
запуск», а будь-яке зникле джерело виглядало легітимно відсутнім.

Міграція автоматична й одноразова: якщо baseline знайдено лише в старому
розташуванні, `BRAVO_SETUP.ps1` переносить його вміст **дослівно** в
машинний стан і повідомляє про це. Файл у `LOGS` при цьому не видаляється
— це дані оператора; canonical розташування виграє завжди. Якщо файл у
машинному стані пошкоджений, це повідомляється окремо
(`Baseline discovery НЕПРИДАТНИЙ до читання`) і **не** видається за
перший запуск: інакше втрата захисту від тихого зникнення компонента
лишалась би невидимою.

Щоб зафіксувати поточний discovery-результат як новий baseline (після
ручної перевірки, що джерела визначені правильно):

```powershell
.\BRAVO_SETUP.ps1 -Action Test -ValidateOnly -ConfirmDiscoveryBaseline
```

#### Склад backup set за наявністю

Прапорець компонента в `componentSettings` означає «копіювати, якщо
компонент є на сервері». Складом керує `Resolve-BRAVOBackupComponentScope`
(модуль BRAVO.Discovery); його використовують `BRAVO_ARCHIV.ps1`, Health,
Dry Run і `BRAVO_SETUP.ps1 -ValidateOnly`, тому вони завжди погоджуються.

| Статус | Значення | Наслідок |
|---|---|---|
| `Planned` | увімкнений і присутній | архівується |
| `NotInstalled` | увімкнений, але на сервері його ніколи не було | пропускається без помилки (INFO), без BAZA-синхронізації й каталогів призначення |
| `DisabledByConfig` | вимкнений у конфігурації | не перевіряється |
| `Missing` | був у baseline або в останньому COMPLETE manifest, а тепер зник | помилка, як і раніше |
| `Unknown` | джерело оголошене, але недоступне або неоднозначне | помилка, ніколи не `NotInstalled` |

Після кожного COMPLETE generation `BRAVO_ARCHIV.ps1` автоматично створює
discovery baseline (якщо його ще немає) або доповнює порожні поля
компонентами, що реально потрапили в копію; наявні значення baseline не
змінюються, а непридатний baseline ніколи не перезаписується. Generation
manifest містить поле `componentScope` (аудит-доказ свідомого пропуску).
Порожній склад (жоден увімкнений компонент не встановлено) лишається
помилкою.

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

### 3.3. Перевірка вільного місця: поріг здоров'я і операційна вимога

Перевірку перед архівацією (`BRAVO_ARCHIV`) виконує спільний класифікатор
`modules/BRAVO.DiskSpace`. Він розрізняє дві незалежні речі:

- **поріг здоров'я тому** `maintenanceSettings.Limits.MinimumFreeSpaceGB`
  (типово 20 GB) — загальний захист від переповнення диска. Сам по собі він
  **не** визначає, чи можна виконати операцію;
- **операційну вимогу** — скільки місця реально потребує найближчий backup
  на кожному archive destination.

Вимогу рахує `BRAVO_ARCHIV` окремо для кожного увімкненого компонента
(MODEL/BLOG/BRAVOEXCH):

- є валідна історія — розмір останнього hash-підтвердженого валідного архіву
  (той самий канонічний reader історії, що й `SizeSanity` у розділі 3.2) плюс
  запас на зростання, але не більше за оцінку за розміром джерела нижче;
- історії немає (перший запуск, bootstrap) — оцінка за розміром джерела:
  сума `Length` усіх файлів джерела плюс 2% на накладні витрати 7-Zip, якщо
  ця сума більша за нуль;
- історії немає, а розмір джерела виміряти не вдалось **або він нульовий**
  (порожнє джерело чи лише файли нульової довжини) — вимога невідома, і для
  тому діє запасний гейт за порогом (`BelowFallbackFloorNoEstimate` у
  таблиці нижче). Тож перший backup порожнього джерела може бути
  заблокований, якщо залишок на томі менший за `MinimumFreeSpaceGB`.

Обидві оцінки — евристика, а не гарантована верхня межа. Оцінка за розміром
джерела рахує лише вміст файлів і не враховує окремо метадані контейнера
7-Zip (заголовки та імена кожного файлу): для джерела з дуже великою
кількістю дрібних файлів або довгими шляхами ці метадані можуть перевищити
2% від обсягу даних, і архів вийде більшим за оцінку. Тож на таких джерелах
не тримайте archive destination впритул до розрахункової потреби: тримайте
запас понад неї самостійно. `MinimumFreeSpaceGB` такого запасу не гарантує —
за `ArchivePeakSafe` і поточне вільне місце нижче порогу, і прогнозований
залишок після backup нижче порогу є лише попередженнями, тож прогін може
піти з мінімальним запасом понад заниженою оцінкою.

| Поле (`maintenanceSettings.Limits`) | Призначення |
|---|---|
| `EstimatedSpaceMarginPercent` | запас у % понад розмір останнього валідного архіву (типово 25); опційний — старі `BRAVO.config` без нього отримують дефолт у коді завантаження |

Компоненти на одному томі сумуються в одну вимогу. Архівація викликає
класифікатор з політикою `RequirementPolicy = 'ArchivePeakSafe'`, тож для
archive destination на локальному томі рішення таке:

| Стан тому призначення | Reason у лозі | Наслідок |
|---|---|---|
| вимога відома і більша за доступне місце (або вимога невідома, але вже відома її частина — сума відомих вимог інших компонентів тому — більша за доступне місце) | `EstimatedRequirementNotMet` | блокує, код `40` |
| вимога відома і вміщається, але вільного менше за `MinimumFreeSpaceGB` | `BelowHealthFloorButRequirementSatisfied` | `WARNING`, **не блокує** |
| вимога відома, вміщається, вільне вище порогу, але після backup залишок буде нижче порогу | `ProjectedBelowHealthFloor` | `WARNING`, не блокує |
| вимога хоча б одного компонента на томі невідома, і залишок після відомих вимог решти компонентів (`ResidualAvailableGB` = вільне місце мінус сума відомих вимог) менший за `MinimumFreeSpaceGB` | `BelowFallbackFloorNoEstimate` | блокує, код `40` |

Тобто відома вимога, яка вміщається в доступне місце, **не блокується лише
через те**, що вільного менше за `MinimumFreeSpaceGB`: поріг тут —
сигнал здоров'я, і прогін продовжується з кодом `10` (`SuccessWithWarnings`).
Поріг діє як гейт операції лише для destination без визначеної вимоги, і
тоді з порогом порівнюється не поточне вільне місце, а залишок після відомих
вимог (`ResidualAvailableGB` у рядку `DiskSpace ...`). Приклад: вільно 30 GB,
поріг 20 GB, на томі два компоненти — одному потрібно 15 GB, вимога другого
невідома. Залишок 30 − 15 = 15 GB менший за поріг, тож архівація блокується
з `BelowFallbackFloorNoEstimate`, хоча вільного місця більше за поріг.

**Archive destination на UNC-шляху** (`\\server\share\...`) таблиця вище не
описує. Архівація не передає класифікатору ємність мережевого ресурсу, тож
він фіксує її як невідому й повертає `CapacityUnknownRemote` (`WARNING`, не
блокує) ще до порівняння вимоги з місцем: навіть відома вимога з доступним
місцем на ресурсі не порівнюється, і ця перевірка **не захищає** мережевий
ресурс від переповнення — стежте за його вільним місцем окремо. Недоступний
UNC-шлях і далі блокує (перевірка доступу йде перед перевіркою місця).

Окремо від archive destination архівація робить health-only огляд **усіх**
локальних Fixed-дисків, зокрема й тих, що самі є archive destination. Цей
огляд оцінює лише поріг здоров'я: нестача дає `WARNING`
`BelowHealthFloorNoFreeSpaceRequirement` для health-only запису тому (виду
`D:\: BelowHealthFloorNoFreeSpaceRequirement`). Тому для destination нижче
порогу в журналі може бути два рядки: цей health-only і operational-рядок
`<шляхи destination>: <причина>`. Його причина залежить від вимоги:
`BelowHealthFloorButRequirementSatisfied`, якщо відома вимога вміщається
(не блокує), або блокуючі `EstimatedRequirementNotMet` чи
`BelowFallbackFloorNoEstimate`. Сама причина
`BelowHealthFloorNoFreeSpaceRequirement` означає результат health-only
огляду, а не те, що архівація на цей диск не пише.

Виняток — малий том, загальна ємність якого менша за `MinimumFreeSpaceGB`:
такий поріг недосяжний за побудовою, тож health-only оцінка замінює його на
10% ємності тому (фактичне значення — у `Flags` рядка `DiskSpace ...` як
`DegradedHealthFloorGB=...`). Попередження тоді з'являється лише нижче
цього зниженого порогу і має причину `BelowDegradedHealthFloorSmallVolume`.
Знижений поріг стосується лише health-only оцінки, не archive destination.

Health-only попередження `maintenanceSettings.Limits.ExcludedDrives` може
придушити. На operational-блокування `ExcludedDrives` не впливає.

`BRAVO_MAINTENANCE` використовує той самий класифікатор з політикою
`MaintenanceExactOnly`. Точної вимоги для нього немає, тому на томі
`LIMSRoot` поріг діє як гейт: нестача дає `BelowFallbackFloorNoEstimate` і
код `60`.

Операторська інтерпретація результатів — в `OPERATIONS.md`, розділ `40`,
підрозділ «Archive preflight: перевірка вільного місця».

## 4. Параметри установи та секрети

Секрети й параметри установи зберігаються у Windows Credential Manager, тому
їх не потрібно знову вписувати в конфігурацію після оновлення. Звідки саме
runtime бере кожне значення і що буває, коли його немає, — підрозділ
[«Джерела конфігурації та секретів у 5.3»](#джерела-конфігурації-та-секретів-у-53)
нижче; це єдиний канонічний опис, інші документи посилаються на нього.

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
| `BRAVO_SLACK_GENERAL_URL` | Slack webhook — лише штатні (SUCCESS) сповіщення |
| `BRAVO_SLACK_ALERTS_URL` | Slack webhook — попередження й помилки (WARNING/ERROR/CRITICAL) |
| `BRAVO_DISCORD_GENERAL_URL` | Discord webhook — лише штатні (SUCCESS) сповіщення |
| `BRAVO_DISCORD_ALERTS_URL` | Discord webhook — попередження й помилки (WARNING/ERROR/CRITICAL) |
| `BRAVO_OPERATIONS_BOOTSTRAP_SECRET` | bootstrap-секрет enrollment BSYSTEM Operations |
| `BRAVO_OPERATIONS_API_KEY` | API-ключ BSYSTEM Operations (записує сам runtime після enrollment) |

### Джерела конфігурації та секретів у 5.3

**Контракт runtime 5.3:**

```text
канонічні built-in дефолти (код комплекту)
  + BRAVO.local.config (лише дозволені не-секретні site-override)
  + Windows Credential Manager (секрети й параметри установи)
  + автоматичне визначення на машині (Discovery) для AUTO-шляхів
  + детермінована деривація
  = ефективна конфігурація
```

`BRAVO.config` у цьому контракті **не є джерелом конфігурації**: штатний
запуск 5.3 (без `-ConfigPath`) не виконує його, навіть якщо файл фізично
лежить поруч, — завантажувач лише попереджає про знайдений файл. Виняток —
явний `-ConfigPath` (підрозділ «Міграція — legacy `BRAVO.config`» нижче);
з PR #317 це стосується й ручного `BRAVO_OPERATIONS_HEARTBEAT.ps1`, який
раніше виконував сусідній файл і без `-ConfigPath`. Секретів він не постачає за жодних умов.

#### Runtime 5.3 — не-секретна конфігурація

1. Канонічні built-in дефолти — код комплекту (`modules\BRAVO.Configuration`).
2. `BRAVO.local.config` — лише ті dot-path, які реєстр авторизації дозволяє
   як site-override. Неавторизований або некоректний за типом ключ зупиняє
   завантаження ще до злиття — жоден override із файлу тоді не
   застосовується частково (єдиний виняток — свідоме послаблення через
   `BRAVO_ALLOW_WEAKENED_SECURITY=1` для ключів, які реєстр дозволяє так
   послабити).
3. Детермінована деривація (ефективні корені, шляхи, `storageEffective` тощо)
   з результату злиття. Для шляхів, лишених порожніми (AUTO, як built-in
   `pathSettings.LIMSRoot = ""`), вона бере автоматичне визначення на машині:
   `Resolve-BRAVOEffectiveLimsRoot` і `Resolve-BRAVOInstallationDiscovery`
   (`modules\BRAVO.Discovery`) читають служби Windows (`Win32_Service`),
   активний `bravo.ini` і стан файлової системи. Тому зміна служби чи
   `bravo.ini` може змінити ефективну конфігурацію без зміни жодного з
   перелічених файлів; явно заданий шлях Discovery не перевизначає.

#### Runtime 5.3 — секрети

Пароль архівів, SFTP- і SMB-логін/пароль, webhook-и Slack/Discord,
bootstrap-секрет BSYSTEM Operations мають **єдине** джерело — Windows
Credential Manager того облікового запису, від якого запущено процес:
адміністратора для ручних запусків, `SYSTEM` для завдань Планувальника
(тому `-StoreFor Both`). Змінні середовища, аргументи командного рядка,
`BRAVO.local.config` і `BRAVO.config` секретів не постачають.

API-ключ BSYSTEM Operations оператор не створює: його видає бекенд Operations
у відповіді на enrollment (або reissue), і runtime сам записує його
(`Set-BRAVOCredential`) у Credential Manager облікового запису процесу, а далі
читає лише звідти. Credential Manager для нього — постійне сховище, а не
першоджерело; `BRAVO_CREDENTIALS_SETUP.ps1` (компонент `Operations`)
провізіонує лише bootstrap-секрет, тож `-StoreFor Both` API-ключ не створює.

Конфігурація містить лише **ім'я запису** (reference metadata) —
`credentialSettings.Targets.<Ключ>`; перевизначити його в
`BRAVO.local.config` дозволено, але зазвичай не потрібно. Якщо ключ порожній,
runtime бере канонічне ім'я з таблиці вище (`BRAVO_7Z_PASSWORD`,
`BRAVO_SFTP_*`, `BRAVO_SMB_*`, `BRAVO_<SLACK|DISCORD>_<GENERAL|ALERTS>_URL`).
Для `OperationsApiKey`/`OperationsBootstrapSecret` такої підстановки в коді
немає: діє ім'я з built-in дефолту. Пошуку секрету під іншим ім'ям немає:
заданий target — єдиний кандидат, а webhook не підміняється ні legacy
provider-wide записом, ні записом іншого каналу (підрозділ «Маршрутизація
сповіщень» нижче). Порожній запис дорівнює відсутньому.

#### Runtime 5.3 — параметри установи

`InstitutionName`, `InstitutionCode`, `ArchivePrefix` — не секрети, тому
мають запасне джерело:

1. запис Credential Manager (`credentialSettings.Targets.InstitutionName`
   тощо; порожній ключ → `BRAVO_INSTITUTION_NAME`, `BRAVO_INSTITUTION_CODE`,
   `BRAVO_ARCHIVE_PREFIX`);
2. лише якщо запису немає або він порожній — `bravoSettings.<Параметр>` з
   ефективної конфігурації: override у `BRAVO.local.config`, інакше built-in
   placeholder (`УСТАНОВА`, `00000000`, `lab_v2412`).

Цей порядок застосовують `BRAVO_ARCHIV`, `BRAVO_HEALTH`, `BRAVO_MAINTENANCE`,
`BRAVO_DATA_RESTORE`, `BRAVO_OPERATIONS_HEARTBEAT` і `BRAVO_DRY_RUN`
(`Import-BRAVOInstitutionSettings`): у них запис Credential Manager завжди має
пріоритет — щойно він є, `bravoSettings.*` для цього параметра ігнорується.
Обране значення проходить
ту саму валідацію формату; некоректне значення або недоступний Credential
Manager зупиняють запуск. Placeholder формально валідний, тому production-
скрипти **не попереджають**, що працюють на ньому; джерело кожного параметра
(`CredentialManager` чи `ConfigurationFallback`, останнє — як `WARN`) показує
`.\BRAVO_DRY_RUN.ps1`.

Інші скрипти Credential Manager для цих параметрів не читають і беруть
`bravoSettings.*` (override або placeholder) навіть за наявного запису:
`BRAVO_NOTIFICATION_TEST` і `BRAVO_RESTORE_TEST` — у тексті своїх сповіщень,
`BRAVO_SETUP`, `BRAVO_BAZA_RECONCILE` і `BRAVO_TASKS_INSTALL` — у заголовку
консолі.

#### Відсутній секрет: що робить кожен компонент

Компонент, якому бракує секрету, не намагається працювати без нього. Код
завершення при цьому **не завжди `31`** — він залежить від скрипта:

| Скрипт | Відсутній запис | Поведінка | Код |
|---|---|---|---|
| `BRAVO_ARCHIV` | пароль архівів | архіви не створюються | `31` (або `30`, якщо одночасно є помилка конфігурації, — вона має вищий пріоритет) |
| `BRAVO_ARCHIV` | SFTP- або SMB-логін/пароль | відповідна передача пропускається як помилка конфігурації; локальна архівація продовжується | `30` |
| `BRAVO_ARCHIV` | webhook | сповіщення не надсилається, причина — у журналі; архівація не зупиняється | — |
| `BRAVO_ARCHIV` | параметри установи (некоректні або Credential Manager недоступний) | запуск зупиняється | `1` (поза контрактом `BRAVO.ExitCodes`) |
| `BRAVO_MAINTENANCE` | пароль архівів | запуск зупиняється до будь-яких дій | `31` |
| `BRAVO_MAINTENANCE` | webhook потрібного каналу (режим сповіщень не `none`) | запуск зупиняється | `31` |
| `BRAVO_MAINTENANCE` | SFTP-логін/пароль | SFTP-частина trace-архівації й вивантаження власного журналу пропускається з `WARNING` | — |
| `BRAVO_HEALTH` | webhook потрібного каналу (режим сповіщень не `none`) | перевірки не виконуються | `30` |
| `BRAVO_HEALTH` | SFTP- або SMB-логін/пароль | відповідна перевірка фіксується як проблема | `70` |
| `BRAVO_DATA_RESTORE` | пароль архівів; SFTP-логін/пароль для `-Source SFTP` | відновлення не починається | `31` |
| `BRAVO_RESTORE_TEST` | пароль архівів | drill не виконується | `90` |
| `BRAVO_BAZA_RECONCILE` | SFTP-логін/пароль | перегляд мутацій (`-ListOnly` або запуск без `-Accept`/`-AcceptAll`) облікових даних не читає й завершується `0`; не виконується лише прийняття мутацій (`-Accept`/`-AcceptAll`) | `31` (лише в режимі прийняття) |
| `BRAVO_NOTIFICATION_TEST` | webhook | тест не пройдено | `31` |
| BSYSTEM Operations (усі runtime) | API-ключ і bootstrap-секрет | `WARNING` у журналі; події буферизуються в локальному outbox (`%ProgramData%\BRAVO\State\Outbox`) до enrollment, але не більше 500: найстаріші витісняються в `Outbox\DeadLetter` (зберігаються 200 найновіших), звідки після enrollment автоматично не доставляються | — |

«—» означає, що відсутній секрет не має власного коду завершення: код
визначають інші результати прогону.

Некоректні параметри установи чи недоступний під час їх читання Credential
Manager у `BRAVO_MAINTENANCE`, `BRAVO_HEALTH`, `BRAVO_DATA_RESTORE` і
`BRAVO_OPERATIONS_HEARTBEAT` — помилка конфігурації (`30`); у `BRAVO_ARCHIV`
— `1` (див. таблицю). Коди — розділ 12 «Коди завершення production-скриптів».

#### Міграція — legacy `BRAVO.config`

За контрактом legacy `BRAVO.config` (5.2) читає лише ізольований migration-
інструментарій: `.\deploy\Get-BRAVOConfigSiteDelta.ps1` порівнює його з
канонічними дефолтами й друкує site-відмінності у форматі dot-path для
перенесення в `BRAVO.local.config` (процедура — розділ 10). Секрети з
`BRAVO.config` не мігрують: runtime їх звідти не читає, а пароль у
`archiveParams`/`Maintenance.Archiver.Parameters` вважається помилкою
конфігурації.
Параметри установи переносяться в Credential Manager
(`.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Ensure -Component Institution -StoreFor Both`),
а не в `BRAVO.local.config`.

Не використовуйте `BRAVO.config` як runtime-fallback. **Відома розбіжність
коду з контрактом:** production-скрипти досі приймають явний `-ConfigPath`
на legacy `BRAVO.config` і тоді виконують його як основний шар
(дефолти < `BRAVO.config` < `BRAVO.local.config`); завдання Планувальника,
встановлені з явним `-ConfigPath`, передають його щоразу. Це лише
сумісність на час міграції, а не підтримуване джерело конфігурації 5.3:
після перенесення відмінностей перевстановіть завдання без `-ConfigPath`
(`.\BRAVO_TASKS_INSTALL.ps1`). Ручний `BRAVO_OPERATIONS_HEARTBEAT.ps1`
до PR #317 не вимикав автопідхоплення legacy-файлу і без `-ConfigPath`
виконував `BRAVO.config` з каталогу runtime; тепер він поводиться так само,
як інші скрипти.

### Маршрутизація сповіщень (GENERAL/ALERTS)

`BRAVO.Notifications` централізовано маршрутизує сповіщення за severity у два
канали:

| Severity | Канал |
|---|---|
| `SUCCESS` | GENERAL |
| `WARNING` / `ERROR` / `CRITICAL` | ALERTS |

Маршрутизація за `NotificationMode` (`bravoSettings.NotificationMode`
у `BRAVO.config`):

| Mode | SUCCESS | WARNING/ERROR/CRITICAL |
|---|---|---|
| `none` | не надсилається | не надсилається |
| `errors_only` | не надсилається | ALERTS |
| `all` | GENERAL | ALERTS |

Таблицю severity → канал можна перевизначити через
`bravoSettings.NotificationRouting` у `BRAVO.config` (безпечний дефолт вище
застосовується автоматично, якщо ключ відсутній — стара конфігурація без
`NotificationRouting` лишається валідною).

Legacy provider-wide webhook-и (`BRAVO_DISCORD_URL`/`BRAVO_SLACK_URL`)
**більше не підтримуються**: кожен канал резолвиться виключно через власний
route-специфічний запис, без fallback на спільний webhook і без fallback між
каналами. Обов'язкова topology залежить від `NotificationMode`:
`errors_only` вимагає лише ALERTS-запис, `all` — обидва (GENERAL + ALERTS),
`none` — жодного. Стара інсталяція лише з legacy-записом отримає явну
міграційну діагностику в `BRAVO_DRY_RUN`/`BRAVO_SETUP`; налаштування:
`.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Ensure -Component Discord -StoreFor Both`
(аналогічно `-Component Slack`). Старі записи Credential Manager не
видаляються автоматично — після міграції вони просто ігноруються. Реальну
доставку в обидва канали перевіряє `.\BRAVO_NOTIFICATION_TEST.ps1`
(канонічний конвеєр, явно марковані тестові повідомлення).

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

Скопіюйте комплект у `C:\Program Files\BRAVO-Toolkit`, додайте інструменти у `Tools` і
перевірте наявність джерельних каталогів.

### Крок 2. Виконати локальні тести

```powershell
cd /d "C:\Program Files\BRAVO-Toolkit"
.\BRAVO_SELF_TEST.ps1
```

Self-test перевіряє синтаксис усіх PowerShell-файлів, узгодженість версій,
захисні параметри backup, спільний operation lock і визначення завдань
Планувальника без production-архівації.

#### Вибірковий прогін під час розробки (`-Suite`)

Повний прогін — режим за замовчуванням і **єдиний**, що є gate-ом мержу й
релізу. Для швидшого зворотного зв'язку під час роботи над одним доменом
можна виконати лише потрібні suite-фрагменти:

```powershell
.\BRAVO_SELF_TEST.ps1 -Suite DiskSpace,ArchiveDiskSpace
```

Невідоме ім'я зупиняє прогін і друкує перелік доступних — мовчки виконати
не те, що просили, гірше, ніж не виконати нічого.

**Що `-Suite` НЕ робить.** Він не пропускає inline-тіло кореневого
`BRAVO_SELF_TEST.ps1`: фрагменти не самодостатні й споживають фікстури,
які готує саме воно. Тому економія обмежена зверху — корінь це 961 з 2107
перевірок і 188.6 с із 477.5 с сумарного часу suite-ів.

**Вибірковий прогін не може вважатися доказом.** Він друкує
`SELF-TEST PARTIAL: <фрагменти>` замість `SELF-TEST PASSED`, а підсумок
прямо каже, що для мержу й релізу потрібен повний прогін без `-Suite`.
`RELEASE_CHECKLIST.md` вимагає саме дослівний `SELF-TEST PASSED`, тому
зарахувати вибірковий прогін як доказ релізу неможливо технічно, а не
лише за домовленістю.

#### Affected: мінімальний вибірковий прогін за зміною (`ci\Invoke-BRAVOAffectedSelfTest.ps1`)

Локальний інструмент розробника: за переліком змінених файлів визначає
**мінімальний клас за картою шляхів** і для V1/V2 запускає відповідний
`-Suite`. Це **не acceptance** і не required check CI: Full
(`.\BRAVO_SELF_TEST.ps1 -NoPause`) лишається єдиним gate-ом мержу й релізу, а
класифікація самого PR на рівні рев'ю обов'язкова й може підвищити клас.

```powershell
.\ci\Invoke-BRAVOAffectedSelfTest.ps1 -BaseRef origin/developer
```

Потрібні git і повний (не shallow) клон. Порівнюється merge-base бази й `HEAD`
з робочим деревом: staged, unstaged і untracked файли (без gitignored),
видалення окремо, перейменування — обидва шляхи.

| Клас | Що робить runner | Код завершення |
| --- | --- | --- |
| V1 (документи з таблиці споживачів, зокрема `CHANGELOG.md`) | вибірковий прогін споживачів і `Governance`; Full не звільняється | 0 — лише за збігу маркера |
| V2 (фрагмент каталогу плюс супутній `RUNTIME_MANIFEST.json`) | вибірковий прогін фрагмента й `Governance`; Full обов'язковий перед acceptance | 0 — лише за збігу маркера |
| V3 (будь-який невідомий шлях, зокрема змішаний набір відомих і невідомих) | **нічого не запускає**: друкує вимоги (Full, перевірки з `RELEASE_POLICY.md` §13.3, умовні gate-и, незалежне рев'ю, невідомі шляхи з причинами) | завжди 1 |

Код завершення — лише `0` або `1` (нової таблиці exit-кодів немає). `0` лише
коли водночас: клас V1/V2, дочірній процес завершився з кодом 0, надруковано
рівно один рядок `SELF-TEST PARTIAL: <очікуваний перелік>` і жодного іншого
рядка з маркером Self-Test. Маркером вважається будь-який рядок дочірнього
процесу, що після пробілів починається з `SELF-TEST` у будь-якому регістрі.
Усе інше — `1`. Останній рядок виводу завжди
`AFFECTED RESULT: <КОД>`, де код — `PARTIAL-OK`, `ESCALATED-V3`, `CHILD-FAILED`,
`MARKER-MISMATCH` або статус збирача без змін (`BASE-MISSING`, `BASE-INVALID`,
`BASE-EQUALS-HEAD`, `EMPTY-DIFF`, `GIT-MISSING`, `GIT-FAILED`,
`NOT-A-REPOSITORY`, `ROOT-MISMATCH`, `SHALLOW-REPOSITORY`, `NO-MERGE-BASE`).
Непередбачений виняток у CLI дає `AFFECTED ERROR` і `AFFECTED RESULT: RUNNER-FAILED`.
Доказом прогону є лише маркер на початку рядка: шлях чи інший текст може
містити `SELF-TEST PASSED` усередині рядка runner-а, і такий рядок нічого не
підтверджує.
Порожня база, збій git і порожній diff — це помилка, а не «нічого запускати».

Вивід runner-а завжди починається з `AFFECTED BASE`, `AFFECTED MERGE-BASE`,
`AFFECTED HEAD`, `AFFECTED DIRTY`, `AFFECTED CLASS` (з міткою «мінімальний
клас за картою шляхів») і `AFFECTED SUITES`. Рядки дочірнього процесу
друкуються з префіксом `child| `, а маркери Self-Test — лише розібраними
(`AFFECTED CHILD MARKER: PARTIAL <імена>`): жоден рядок runner-а не
починається з `SELF-TEST`, тому його вивід неможливо зарахувати як доказ
повного прогону. Дочірній процес — `powershell.exe` з каталогу Windows
PowerShell 5.1 (`-EncodedCommand`); його вивід з'являється після завершення
прогону. Дочірній процес пише stdout в UTF-8 без BOM, і runner так само його
читає, тож кирилиця в рядках `child| ` не залежить від кодової сторінки
консолі. stderr Windows PowerShell 5.1 пише в OEM-сторінці, тому runner
декодує його як OEM: літери, яких у цій сторінці немає, у повідомленнях про
помилки стають `?`.

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
5. запускає dry-run та тести доступу SFTP/SMB від `SYSTEM`;
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
.\BRAVO_DRY_RUN.ps1
```

Додатково перевірити реальну автентифікацію та доступ (містить проби
запису: локальні create/write/read/delete і створення відсутніх каталогів
призначення на SFTP):

```powershell
.\BRAVO_DRY_RUN.ps1 -TestAccess
```

End-to-end тест із одним реальним Slack/Discord повідомленням:

```powershell
.\BRAVO_DRY_RUN.ps1 -TestAccess -SendTestNotification
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
файлів проти мінімального порогу. З 5.3.0 drill виконується й
автоматично — щотижнева задача `BRAVO_RESTORE_VERIFY`
(`schedulerSettings.RestoreVerify`, типово Сб 04:00), а вік останньої
успішної верифікації контролює Health (крок «Відновлюваність»).
Ручний запуск:

```powershell
.\BRAVO_RESTORE_TEST.ps1
```

Для контрольованого відновлення конкретної точки в часі задайте generation
явно. Не змішуйте independently newest MODEL/BLOG/BRAVOEXCH:

```powershell
.\BRAVO_RESTORE_TEST.ps1 -GenerationId "20260808_154300"
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

### 6.2. Відновлення даних (`BRAVO_DATA_RESTORE.ps1`)

Drill (розділ 6.1) доводить відновлюваність, але нічого не відновлює.
Фактичне відновлення виконує `BRAVO_DATA_RESTORE.ps1`. Він працює лише з
`COMPLETE` generation і **до** будь-якої зміни на диску перевіряє
manifest, SHA512 sidecar, фактичний хеш архіву, `7za t` і вільне місце.

Спершу подивіться, з чого взагалі можна відновитися (read-only, без
елевації):

```powershell
.\BRAVO_DATA_RESTORE.ps1 -ListGenerations
```

**OutOfPlace** (типово) — розпакування у порожні підкаталоги вказаної
директорії; production і служби не змінюються:

```powershell
.\BRAVO_DATA_RESTORE.ps1 -GenerationId "20260808_154300" `
    -Mode OutOfPlace -TargetPath "D:\RESTORE_CHECK"
```

**InPlace** — відновлення у production-шляхи (їх визначає discovery за
`bravo.ini`, тому `-TargetPath` тут заборонений). Протокол безпеки:
знімок стану служб → зупинка → підтвердження (треба **набрати**
`GenerationId`) → поточні дані переміщуються вбік у
`<каталог>.prerestore_<timestamp>` → розпакування у щойно створений
порожній каталог → post-verify за кількістю файлів і обсягом →
повернення служб у попередній стан → `BRAVO_HEALTH`:

```powershell
.\BRAVO_DATA_RESTORE.ps1 -GenerationId "20260808_154300" `
    -Mode InPlace
```

Джерелом може бути не лише локальний `BackupRoot`, а й SFTP
(`-Source SFTP`): архіви завантажуються у staging і проходять ту саму
повну верифікацію. Окремий компонент — `-Component MODEL|BLOG|BRAVOEXCH`.

Інваріанти, на які можна покладатися:

- жоден файл ніколи не розпаковується поверх наявних даних — ціль завжди
  щойно створений порожній каталог;
- `.prerestore_*` **не видаляються автоматично** — видаляйте вручну після
  підтвердженої працездатності LIMS;
- при збої будь-якого компонента система **намагається відкотити весь
  прогін**: уже відновлені компоненти повертаються до попереднього стану у
  зворотному порядку, щоб MODEL/BLOG/BRAVOEXCH не лишились із різних
  generation. Відкат не є безумовно успішним — якщо каталог утримує інший
  процес, повернути його автоматично не вдасться;
- невдалий відкат одного компонента **не припиняє** відкат інших. Кожен
  такий компонент отримує статус `ПОМИЛКА ВІДКАТУ` з конкретною причиною,
  надсилається CRITICAL-сповіщення, його `.prerestore_*` зберігається, а
  прогін завершується `RestoreFailed (43)`. Стан таких каталогів не
  гарантований — потрібне ручне повернення за
  [OPERATIONS.md](OPERATIONS.md), розділ коду `43`;
- невдале відновлення дає код `43`; конкретніші причини — `41` (архів не
  пройшов перевірку) і `42` (SHA512). Дії за кожним кодом і сценарій
  перерваного відновлення — в [OPERATIONS.md](OPERATIONS.md).

Операція вимагає прав адміністратора (окрім `-ListGenerations`) і
захоплює той самий machine-wide operation lock, що архівація й
обслуговування, тому не може виконуватись паралельно з ними.

**Автоматична реставрація пропущеного слота** (`Restore.BootRestoreMode`,
`BRAVO.config`) визначає, як сервер поводиться, якщо планова реставрація
пропущена (сервер був вимкнений/перезавантажувався у вікні відновлення):
`"None"` (типово, 24/7-сервер) — пропущений слот підхоплює щонічне
Maintenance, окреме Recovery-завдання не реєструється (наявне вимикається
інсталятором); `"HoldServices"` (сервер робочого часу) — реєструється
одноразовий boot-trigger Recovery-завдання, що виконує пропущену
реставрацію одразу після старту, поки служби ще не запущені. Повний опис
обох режимів і взаємодії зі стартовим типом служб — `BRAVO.config`
(коментар над `Restore.BootRestoreMode`) і `OPERATIONS.md`, розділ
"Профілі реставрації: 24/7 vs сервер робочого часу".

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
| `BRAVO_ARCHIV_HEALTH` | кожні 240 хв. від `00:30` | контроль служб і локальних/SFTP/SMB копій |
| `BRAVO_RESTORE_VERIFY` | щотижня, субота `04:00` | restore drill (розділ 6.1) |
| `BRAVO_RESTORE_RECOVERY` | при старті сервера | підхоплення пропущеної реставрації моделі; лише профіль робочого часу (`Restore.BootRestoreMode = "HoldServices"`) |
| `BRAVO BAZA Synchronization` | кожні 4 год. від `00:00` | синхронізація `BAZA_APP`/`BAZA_WWW` із SFTP; лише коли ввімкнено BAZA SFTP |
| `BRAVO_ARCHIV_CATCHUP` | після старту Windows, затримка 7 хв. | пропущена нічна копія (сервер був вимкнений о `23:00`) |
| `BRAVO_SERVICE_RECOVERY` | падіння служби (подія SCM, +1 хв.), старт Windows (+10 хв.), кожні 15 хв. | автоматичне відновлення впалих служб BRAVO (`BRAVO_MAINTENANCE.ps1 -RecoverServices`); ставиться разом із Maintenance |

`BRAVO_ARCHIV_CATCHUP` запускає `BRAVO_ARCHIV.ps1 -CatchUpMissedBackup`.
Копія робиться, лише якщо після останнього слоту `Backup.DailyAt` немає
COMPLETE-копії і до наступного слоту більше 60 хв.; інакше прогін
завершується за кілька секунд з кодом `0`, без сповіщення. Рішення
приймається після отримання спільного lock, тож якщо в цей час іде
звичайна нічна копія, друга не робиться. Затримка фіксована: 7 хв.
На профілі робочого часу (`BootRestoreMode = "HoldServices"`) завдання
вимкнене: там пропущений backup уже виконує `BRAVO_RESTORE_RECOVERY`.

`BRAVO_SERVICE_RECOVERY` піднімає кожну керовану службу (BRAVO, exchangAPI,
BRAVO Web), тип запуску якої не `Disabled`; без впалих служб прогін
завершується за кілька секунд з кодом `0`, без журналу й сповіщення.
Health, побачивши впалу службу, запускає цю задачу, а не службу. Щоб
вивести службу з-під відновлення на час робіт, ставте `Disabled`
(OPERATIONS.md, розділ «Служби BRAVO: автоматичне відновлення»).

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
служби, крім служб із типом запуску `Disabled`; повторні однакові
health-alert можуть тимчасово пригнічуватися на інтервал
`RepeatAlertAfterHours` (типово `0` - дедуп вимкнено, alert надходить
щоцикл, поки проблема триває). Зелені success-звіти мають власне вікно
дедуплікації `SuccessDedupMinutes` (типово `1380` хв = 23 год —
максимум один зелений звіт на добу): плановий чи ручний health-прогін
не повторює звіт лише коли semantic-стан не змінився (той самий
fingerprint перевірок і генерацій копій) і аварій з часу попереднього
звіту не було; зміна стану, нова генерація копії або відновлення після
WARNING/ERROR/CRITICAL (recovery) надсилаються завжди, незалежно від
вікна. Факт непідтвердженого відновлення зберігається в окремому
операційному стані (`RecoveryPending`): він фіксується при виявленні
проблеми незалежно від долі alert-доставки і знімається лише після
фактично доставленого SUCCESS — якщо recovery-звіт не вдалося
доставити, наступні health-прогони повторюють його, доки оператор не
отримає підтвердження. Сам post-backup звіт після щоденної архівації не дедуплікується
і надходить завжди, `0` вимикає дедуп, `-ForceNotification` надсилає
примусово. Аварійні сповіщення від SUCCESS-дедупу не залежать.

Встановити або оновити лише завдання:

```powershell
.\BRAVO_TASKS_INSTALL.ps1
```

Перевірити визначення без встановлення:

```powershell
.\BRAVO_TASKS_INSTALL.ps1 -ValidateOnly
```

Видалити завдання:

```powershell
.\BRAVO_TASKS_UNINSTALL.ps1
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
якщо її дозволяє конфігурація. Він використовує той самий канонічний двигун, що й основний прогін
(`Invoke-BRAVOBazaCanonicalSync`: IncrementalAppendOnly, MutationPolicy, remote conflict);
legacy `synchronize -mirror` застосовується лише за явного `backupMonitoring.SFTP.BAZA.Mode = "Legacy"`. Для maintenance доступні службові перемикачі
`-ForceRestore`, `-DisableSizeCheck`, `-EnableAllSlack`, `-DisableAllSlack`,
`-AutoShutdown on|off` і `-ArchiveAfterMaintenance on|off`; змінювати їх слід
лише з розумінням впливу на production.

## 10. Оновлення в установі

Локальні site-відмінності (шляхи, компоненти, служби, SFTP/SMB, розклад)
живуть у `BRAVO.local.config` — файлі, якого НЕМАЄ в release-архіві
(`.gitignore`) і який оновлення взагалі не чіпає. Ручне перенесення значень
із старого `BRAVO.config` у новий («крок 4» попередніх версій цього
розділу) більше не потрібне: `BRAVO.local.config` — постійний override-шар,
що переживає заміну комплекту байт-у-байт.

1. Атомарно замініть весь комплект новою версією: виконувані `.ps1`,
   `VERSION.json`, документацію та весь каталог `modules`. Не змішуйте
   модулі й wrappers із різних версій. **З 5.3 (issue #216) `BRAVO.config`
   не входить у release-пакет** — заміняти/постачати цей файл більше не
   потрібно; канонічні дефолти йдуть у коді комплекту.
2. **НЕ торкайтесь** `BRAVO.local.config` — він лежить поруч (той самий
   каталог, що effective ConfigPath) і не є частиною release-архіву;
   заміна комплекту його не перезаписує.
3. Якщо в установі ще немає `BRAVO.local.config` (сайт не мігрував на цю
   схему), а старий (5.2) `BRAVO.config` мав ручні site-правки —
   перенесіть ЛИШЕ ці відмінності у НОВИЙ `BRAVO.local.config`
   (скопіюйте `BRAVO.local.config.example`, розкоментуйте потрібні
   `'dot.path' = значення`). Старий `BRAVO.config` при цьому не
   видаляйте — використайте його явним `-ConfigPath` лише як джерело
   для порівняння нижче; у звичайному (AUTO, без `-ConfigPath`)
   виконанні 5.3-скрипти його все одно ігнорують (з PR #317 — і
   `BRAVO_OPERATIONS_HEARTBEAT.ps1`). Це одноразова
   міграція за установу, не за кожне оновлення.

   Шукати ці відмінності вручну не потрібно —
   `.\deploy\Get-BRAVOConfigSiteDelta.ps1` порівнює `BRAVO.config` сервера
   з канонічними дефолтами й друкує **лише** відмінності вже у форматі
   dot-path. Інструмент нічого не змінює: вивід іде в консоль, запис — лише
   за явним `-OutputPath`. Звіряйте результат, а не копіюйте наосліп:
   частина відмінностей може бути застарілою копією дефолтів попередньої
   версії комплекту.

   **Опечатка в ОСТАННЬОМУ сегменті dot-шляху не зупиняє запуск** — такий
   ключ приймається (навмисна forward-compat), але нічого не змінює.
   Невидимим це не є: завантаження виводить попередження й записує такі
   ключі в `BravoConfigurationMetadata.LocalConfigUnknownLeafOverrides`.
   Повний контракт шляху — у шапці `BRAVO.local.config.example`.
4. Після копіювання вилучіть застарілі root-бібліотеки
   `BRAVO_COMPATIBILITY.ps1`, `BRAVO_CREDENTIALS.ps1`,
   `BRAVO_HELPER_LOGGING.ps1`, `BRAVO_NOTIFICATION.ps1`,
   `BRAVO_ARCHIVE_HELPERS.ps1`, `BRAVO_ARCHIV_RUNTIME.ps1` і
   `BRAVO_SYSTEM_HELPERS.ps1`.
5. Не переносіть у config (ні `BRAVO.config`, ні `BRAVO.local.config`)
   секрети, назву установи, код або префікс — вони вже зберігаються у
   Credential Manager.
6. Запустіть:

```powershell
.\BRAVO_SELF_TEST.ps1
.\BRAVO_SETUP.ps1 -ValidateOnly
.\BRAVO_SETUP.ps1
```

Повторний `.\BRAVO_SETUP.ps1` використовує режим `Ensure`: наявні credentials не
запитуються і не перезаписуються. Завдання оновлюються відповідно до поточного
`schedulerSettings`.

### Оновлення з 5.2.2 і раніше: перевірка `ExcludedDrives` і `MinimumFreeSpaceGB`

5.2.3 перевела перевірку вільного місця (`BRAVO_ARCHIV`/`BRAVO_MAINTENANCE`)
на operation-aware політику, 5.2.4 скоригувала її для архівації — детально в
`CHANGELOG.md` (розділи 5.2.3-dev.1 і 5.2.4-rc.1). Перед оновленням
production-сервера перевірте:

- Якщо `maintenanceSettings.Limits.ExcludedDrives` містить диск, доданий саме як обхід
  старого false-positive блокування (мало вільного місця на непов'язаному
  диску) — після 5.2.3 таке виключення більше не потрібне і його можна прибрати.
  Але якщо той самий диск реально є archive destination чи `LIMSRoot`
  (`ROOT_LIMS`) — виключення БІЛЬШЕ НЕ приховає недостатність місця саме там
  (`ExcludedDrives` тепер придушує лише health-попередження, не operational
  block).
- Сервери, де архівація проходила через below-floor relaxation
  (`Merge-BRAVOArchiveSpaceCheckResults` у 5.2.1/5.2.2 — доступно менше за
  `MinimumFreeSpaceGB`, але розрахункова оцінка достатня), проходять і далі:
  з 5.2.4 архівація використовує політику `ArchivePeakSafe`, і для archive
  destination `MinimumFreeSpaceGB` — поріг здоров'я тому, а не гейт операції.
  Якщо розрахункова вимога вміщається в доступне місце, прогін **не блокується**:
  у лозі з'являється рядок `DiskSpace ... Status=Warning Blocks=False
  Reason=BelowHealthFloorButRequirementSatisfied` і `WARNING` виду
  `<шляхи>: BelowHealthFloorButRequirementSatisfied`, крок `Перевірка вільного
  місця` лишається `OK`, а успішний прогін завершується кодом `10`
  (`SuccessWithWarnings`). Через нестачу місця блокують (код `40`,
  `LocalArchiveFailed`) лише невиконана вимога (`EstimatedRequirementNotMet`)
  і archive destination без визначеної вимоги, залишок якого після відомих
  вимог інших компонентів тому нижчий за поріг (`BelowFallbackFloorNoEstimate`).
  Причину `BelowFloorEstimateNotPeakSafe` видавала лише 5.2.3;
  production-виклики 5.2.4 і новіших її не породжують — побачивши її в лозі,
  перевірте, чи оновлення справді застосувалось.

## 11. Якщо вручну працює, а за розкладом — ні

Найчастіша причина — різний контекст: вручну скрипт бачить credentials і доступ
поточного користувача, а завдання працює від `SYSTEM`.

Виконайте від адміністратора:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -InspectOnly
.\BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess
```

Для перевірки webhook одним реальним повідомленням:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess -SendTestNotification
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
│   ├── TraceSRV_YYYYMMDD_HHMMSS.out    нова модель 5.2.0 (плоско, timestamp)
│   ├── TraceBIS_YYYYMMDD_HHMMSS.out    друге джерело (конфіг-override)
│   ├── Trace_YYYYMMDD.mdz (+ .sha512)  добовий накопичувальний архів
│   ├── YYYY-MM-DD\TraceSRV_1.out, …    legacy-структура (не чіпається)
│   └── Trace_YYYY-MM-DD.mdz            legacy-архіви каталогів-дат
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

**Trace-модель (добовий накопичувальний архів).** Trace-файли обробляються
**виключно** `BRAVO_MAINTENANCE` (ручний запуск і Task Scheduler — одна
pipeline; розмір файла ніколи не є тригером; без запуску Maintenance
BRAVO-Toolkit trace не чіпає взагалі). У тому самому запуску: ротація при
зупинених службах у `Trace\<basename>_<yyyyMMdd_HHmmss>.out` (колізія імені →
наступна вільна секунда, існуючий файл ніколи не перезаписується) → після
відновлення служб — накопичувальне оновлення **одного** `Trace_YYYYMMDD.mdz`
на календарну дату (дата — з імені ротованого файла; у 7-Zip передаються ЛИШЕ
нові файли; entries, що вже в архіві, — immutable і верифікуються за
Path+Size+CRC до/після) → `7z t` → SHA512 sidecar → SFTP у каталог
`sftpDirectories.TraceLogs` (типово `logs/trace`; передача у `<ім'я>.new` з
верифікацією розміру до заміни попередньої remote-версії) → видалення
ротованих `.out` лише після повного ланцюга archive+SFTP+verify. Локальний
`.mdz` після SFTP **не видаляється** — лише явно ввімкненою політикою
`Retention.CompressedLogDeletionEnabled` + `CompressedLogDays`. Збій SFTP не
втрачає нічого: архів і `.out` лишаються, наступний Maintenance догрузить без
дублікатів (backlog обробляє всі дати, oldest→newest). Наявні архіви зі
старого SFTP-каталогу `sftpDirectories.Trace` (типово `trace`) Maintenance
одноразово (idempotent) мігрує remote-move'ом у `logs/trace` з верифікацією,
нічого не видаляючи.

**Логи exchangAPI** обробляються тим самим движком: при зупиненій службі
файли переносяться в `LOGS\exchangAPI` (плоско) **з оригінальними іменами,
без перейменувань**; після відновлення служб — добовий
`exchangAPI_YYYYMMDD.mdz` (група за датою LastWriteTime файла) → `7z t` →
SHA512 → SFTP у `sftpDirectories.ExchangeApiLogs` (типово `logs/exchangapi`)
→ видалення джерельних `.log` лише після повної верифікації.

**Джерела.** Ротується **кожен `*.out` з кореня інсталяції bravo.exe**
(Discovery; фолбек — LIMSRoot, коли служба BRAVO не знайдена): реальні
інсталяції накопичують варіанти на кшталт `TraceSRV2.out`, `traceBIS1.out`,
`!TraceSRV.out` — усі вони підбираються за один прохід. Додатково: SRV-шлях
із `bravo.ini` (секція `[Debug]`, ключ `FILE`; у `BRAVO.config` не
дублюється) і явний `maintenanceSettings.Trace.BISSourcePath`, якщо ці файли
лежать поза коренем (порожньо або `'off'` = нічого додаткового — корінь і так
покривається скануванням). Сам `bravo.ini` має рівно
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
| `30` | Ефективна конфігурація (built-in дефолти + `BRAVO.local.config`) не пройшла валідацію або ОС у рівні `Unsupported`; також відсутні SFTP/SMB-облікові дані в `BRAVO_ARCHIV` і відсутній webhook у `BRAVO_HEALTH` (розділ 4, «Відсутній секрет: що робить кожен компонент») | Перший `[ERROR]` одразу після `=== ПЕРЕВІРКА СУМІСНОСТІ СИСТЕМИ ===`; `.\BRAVO_SETUP.ps1 -ValidateOnly` відтворює ту саму перевірку без production-дій. Облікові дані діагностуються в інших місцях: у `BRAVO_ARCHIV` — `[ERROR]` `Помилка конфiгурацiї SFTP: …` / `Помилка конфігурації NAS/SMB: …` у секції перевірки конфігурації SFTP чи NAS/SMB (далі `WARNING` про пропуск передачі); у `BRAVO_HEALTH` — `[ERROR]` `Некоректно налаштовано канал повідомлень або його webhook у Credential Manager` у `BRAVO_ARCHIV_HEALTH_*.log` |
| `31` | Відсутній або порожній запис Credential Manager: пароль архівів (`BRAVO_ARCHIV`, `BRAVO_MAINTENANCE`, `BRAVO_DATA_RESTORE`), webhook (`BRAVO_MAINTENANCE`, `BRAVO_NOTIFICATION_TEST`), SFTP (`BRAVO_DATA_RESTORE`; `BRAVO_BAZA_RECONCILE` лише з `-Accept`/`-AcceptAll`). Не кожен відсутній секрет дає `31` — повна таблиця в розділі 4 | Повідомлення «запис Credential Manager '<target>' не знайдено або він порожній» у консолі/журналі (у `BRAVO_ARCHIV` його несуть `archiveCredentialInitializationError`/`credentialInitializationError`); `.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Test -Component Required -StoreFor Both` |
| `32` | SHA-256 файлу в `Tools/` не збігається з еталонним `TOOLS_MANIFEST.json`, або маніфест відсутній/пошкоджений | Рядок `ЦIЛIСНIСТЬ IНСТРУМЕНТIВ ПОРУШЕНО` на старті логу. Якщо оновлення інструментів свідоме — оновіть маніфест на робочій станції (`ci\Update-BRAVOToolsManifest.ps1 -Apply`), перегляньте `git diff`, розгорніть новий комплект. Якщо ні — це можлива підміна: заплановане завдання виконується від `SYSTEM`, тому інструмент отримав би найвищі права |
| `33` | SHA-256 файлу комплекту не збігається з `RUNTIME_MANIFEST.json`, файл відсутній, або в комплекті з'явився сторонній `.ps1`/`.psm1` | Рядок `ЦІЛІСНІСТЬ КОМПЛЕКТУ ПОРУШЕНО` — це найперше, що виводиться, ще до завантаження модулів. Якщо оновлення коду свідоме: `ci\Update-BRAVORuntimeManifest.ps1 -Apply` на робочій станції, `git diff`, розгортання нового комплекту |
| `34` | `BRAVO.config` вимикає перевірку цілісності інструментів (`Mode = "Warn"`) або VSS-узгодженість (`backupConsistency.Mode ≠ "VSS"`) | Рядок `КОНФІГУРАЦІЯ ПОСЛАБЛЮЄ ЗАХИСТ` на старті. Конфігурація не входить до `RUNTIME_MANIFEST.json` (вона різна на кожному сервері), тому ці перемикачі перевіряються окремо — розбором AST, без виконання файлу. Якщо послаблення свідоме й тимчасове, встановіть `BRAVO_ALLOW_WEAKENED_SECURITY=1`: тоді воно лишає слід поза комплектом |
| `35` | `VERSION.json.packageVersion` нижчий за записаний у `C:\ProgramData\BRAVO\State\BRAVO_VERSION_STATE.json` | Рядок `ВІДКАТ ВЕРСІЇ` на старті. Старіший комплект проходить усі перевірки цілісності — разом із вразливостями, які відтоді закрили. Звірте `sourceCommit` розгорнутого й записаного. Якщо повернення на попередній реліз свідоме, встановіть `BRAVO_ALLOW_DOWNGRADE=1` |
| `36` | (лише `BRAVO_HEALTH.ps1`) ручний запуск без прав адміністратора: explicit `-NonInteractive` сесія без elevation, скасований UAC, або `UnauthorizedAccessException` при записі в `LOGS`/`TEMP` | Рядок `ПОМИЛКА СЕРЕДОВИЩА`/`КРИТИЧНА ПОМИЛКА: BRAVO HEALTH запущено без прав адміністратора` на старті. Запустіть від імені адміністратора вручну (з'явиться запит UAC автоматично) або переконайтесь, що заплановане завдання виконується від `SYSTEM`. SFTP/SMB/локальні перевірки при цьому коді НЕ виконувались — не плутати з `50`/`70` |
| `37` | (лише `BRAVO_HEALTH.ps1`) `LOGS`/`TEMP` недоступні з причини, що НЕ є `UnauthorizedAccessException` (диск повний, `PathTooLong`, пошкоджена файлова система) | Рядок `ПОМИЛКА СЕРЕДОВИЩА` / `Не вдалося використовувати runtime TEMP/LOGS: ...` на старті — конкретна причина в тексті. НЕ означає бракує прав адміністратора: перевірте вільне місце на диску й доступність самого шляху. SFTP/SMB/локальні перевірки НЕ виконувались |
| `40` | Провал створення архіву 7-Zip, провал archive preflight (зокрема перевірки вільного місця, розділ 3.3), або (Maintenance) провал відновлення з архіву | `[ERROR]` у секції `АРХІВАЦІЯ <компонент>`/`ВІДНОВЛЕННЯ`; останні рядки stdout/stderr 7-Zip записуються одразу після загального повідомлення. При провалі preflight — `Причина: Недостатньо вільного місця...`, архіви не створювались |
| `41` | `7z test` не підтвердив цілісність | `Перевiрка цiлiсностi 7-Zip не пройдена` у секції `АРХІВАЦІЯ`; final artifact не публікується |
| `42` | SHA512 generation/verification failed після успішного `7z t` | Компонент `HASH`; тимчасові артефакти поточної generation прибираються, попередній valid backup лишається незмінним |
| `50` | SFTP: з'єднання, автентифікація або передача файлу | Секція `ЗАВАНТАЖЕННЯ АРХІВІВ НА SFTP` / `СИНХРОНІЗАЦІЯ BAZA НА SFTP`; перевірте `sftpHostKey` fingerprint і мережевий доступ до TCP 22 |
| `51` | SMB/NAS: недоступний UNC-шлях або облікові дані | Секція `КОПІЮВАННЯ АРХІВІВ НА NAS/SMB`; перевірте доступність UNC-шляху від `SYSTEM` через `BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess` |
| `60` | Maintenance: служби, диск, файлове господарство — усе, що не потрапляє під `40`/`41` | Секція, де `Результат: ПОМИЛКА` вперше з'являється в `BRAVO_MAINTENANCE_*.log`; часто — недостатньо вільного місця на томі `LIMSRoot` (`BelowFallbackFloorNoEstimate`: точної вимоги в Maintenance немає, тому `Limits.MinimumFreeSpaceGB` там діє як гейт — розділ 3.3) або служба не в стані `Running` |
| `70` | Health-check: локальні/SFTP/SMB копії застаріли, або керована служба не працює | `BRAVO_ARCHIV_HEALTH_*.log`, рядки `[ERROR] Проблема ...`; дивіться `LocalVerified`/`SftpVerified`/`SmbVerified`, якщо результат читається програмно |
| `90` | Непередбачений виняток, якого runtime не встиг категоризувати | `Write-Error`/останній `[ERROR]` перед аварійним завершенням; часто вказує на прогалину в конфігурації, яку варто завести як окремий issue, а не лише перезапустити завдання |

Якщо Health (`70`) повідомляє, що остання COMPLETE generation застаріла, у секції «ЛОКАЛЬНІ БЕКАПИ» Slack-повідомлення з'являється рядок `:mag: Причина: …` (завдання `BRAVO_ARCHIV` не знайдене/вимкнене, остання спроба INCOMPLETE/FAILED з етапом, код останнього запуску, не запускалося, виконується зараз тощо); хмарні рядки «віддалена копія старша за N год.» для того самого застарілого архіву згортаються в один рядок.

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
| `BRAVO_CONFIGURATOR.ps1` | інтерактивний GUI-редактор `BRAVO.local.config` (schema-driven, presets, credentials, preview, atomic apply з rollback) — альтернатива ручному редагуванню файлу |
| `BRAVO_TASKS_DIAGNOSE.ps1` | діагностика Планувальника і запуск від `SYSTEM` |
| `BRAVO_RESTORE_TEST.ps1` | restore drill — розпакування останнього verified backup в ізольований каталог (розділ 6.1) |
| `BRAVO_DATA_RESTORE.ps1` | реальне відновлення даних із verified generation: out-of-place або in-place з move-aside і rollback (розділ 6.2) |
| `BRAVO_BAZA_RECONCILE.ps1` | розв'язання append-only mutation violation у BAZA_APP/BAZA_WWW — свідоме прийняття оператором (`OPERATIONS.md`, "Розв'язання мутацій"); опційний per-cycle поріг авто-архівування `backupMonitoring.SFTP.BAZA.AutoArchiveMutationThreshold` (типово `25`; `0` = вимкнено) описаний там само |

### Службові файли

| Файл | Призначення |
|---|---|
| `BRAVO.config` | legacy-конфігурація 5.2 (у 5.3 не входить у комплект; читається лише явним `-ConfigPath` під час міграції 5.2→5.3, розділ 10) |
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

Повний перелік вимог до релізу (версіонування, CI-ворота, required
checks, acceptance) — у `RELEASE_POLICY.md` у корені репозиторію.

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
  (за замовчуванням `2`) COMPLETE generation, що проходять повну перевірку
  (архів і hash-файл кожного компонента на місці, SHA512 збігається), навіть
  якщо вони старші за `archiveRetentionDays`. Захист рахується по generation
  цілком, а не окремо по компонентах — серія невдалих backup не повинна
  лишити сервер без жодної придатної копії;
- гілку видалення визначає записаний статус прогону: COMPLETE generation
  видаляється лише за `archiveRetentionDays` і лише при
  `enableArchiveDeletion = $true`; generation, що не завершилась COMPLETE, —
  за `failedArchiveRetentionDays` при `enableFailedArchiveDeletion`.
  COMPLETE generation, що не проходить перевірку, лише дає WARNING про
  пошкоджену копію і ніколи не видаляється як невдала. Повне читання архівів
  (SHA512) відбувається лише коли `enableArchiveDeletion = $true` і є
  прострочені COMPLETE generation; для WARNING про відсутні чи змінені за
  розміром файли використовується дешева перевірка без читання вмісту;
- шляхи до архівів retention шукає так само, як відновлення: за записаним
  шляхом, а якщо його немає — у канонічному каталозі компонента (сховище,
  перенесене на інший диск). Manifest видаляється лише після всіх знайдених
  архівів своєї generation; помилка на одній generation не зупиняє решту.
  Generation з типом компонента, якого немає в поточних налаштуваннях,
  не видаляється (WARNING). Архіви без generation manifest-а лише рахуються
  в рядку «Аудит retention» і автоматично не видаляються;
- помилки завантаження `BRAVO.config` і читання Credential Manager
  (SFTP/SMB/архів/webhook) маскуються `Protect-BRAVOLogSecret` одразу при
  захопленні винятку, а не лише при подальшому записі в лог — ці
  повідомлення друкуються у консоль ще до того, як спрацює єдина точка
  масковки в `Write-Log`;
- `hostInformationSettings.PublicIPLookupEnabled` увімкнено за замовчуванням
  (рішення власника 2026-08-30, замінює попередній P1.10-дефолт): Slack/
  Discord-сповіщення звертаються до `api.ipify.org`/`checkip.amazonaws.com`
  і показують публічну IP-адресу хоста. Це розкриває стороннім сервісам
  факт і час запуску backup — вимкніть `PublicIPLookupEnabled` свідомо
  (`$false`), якщо ця зовнішня залежність небажана.

## 15. Операторські сповіщення (UX)

Сповіщення Slack/Discord — короткі операторські підсумки. Детальні технічні
докази лишаються у лог-файлі, на який посилається сповіщення.

- ✅ SUCCESS: операцію/перевірку пройдено; повідомлення містить `Дій не потрібно`.
- ⚠️ WARNING: BRAVO може продовжувати роботу, але повідомлення називає
  конкретну дію (`Потрібна дія: ...`).
- 🚨 CRITICAL: під загрозою backup, цілісність, облікові дані або безпека
  обслуговування; причина й дія — на початку повідомлення.

Інформація про хост компактна: `🖥️ SERVER · 192.0.2.102`. Публічна IP-адреса
показується лише тоді, коли її пошук увімкнено й повернуто валідну адресу.
Рядки установи позначаються `🏢`.

Великі діагностичні колекції підсумовуються: сповіщення містить загальну
кількість, до 5 показових прикладів і рядок `…і ще N`; повна діагностика
лишається в локальному лозі BRAVO-Toolkit. Незалежний від транспорту
безпечний ліміт розміру повідомлення обрізає аномально великі повідомлення
(з явним суфіксом і збереженим шляхом до логу), а не розбиває одну подію на
серію повідомлень.

Термінологія стану резервних копій:

- SUCCESS: `Остання резервна копія`.
- WARNING/ERROR: `Остання успішна резервна копія`.
