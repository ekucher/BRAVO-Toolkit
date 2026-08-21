# BRAVO 5.2.0-dev.1 — комплексне налаштування і безпечний тестовий прогін

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
6. виконує безпечний read-only тест SFTP/SMB;
7. надсилає одне тестове повідомлення у налаштований Slack або Discord.

Архівація, копіювання, синхронізація, видалення, перезапуск служб,
shutdown та інші production-операції у цьому сценарії не виконуються.
Тестове повідомлення — єдина зовнішня операція запису.

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
розміщувати, наприклад, у `C:\BRAVO`; `LIMSRoot`, `ArchiveRoot` і `BackupRoot`
задаються окремими абсолютними шляхами в effective `BRAVO.config`.

Під час інсталяції Планувальника `BRAVO_TASKS_INSTALL.ps1` відмовляється
створювати SYSTEM-завдання з профілю користувача, захищає runtime ACL та
вмикає журнал `Microsoft-Windows-TaskScheduler/Operational`.

## Локальні параметри установи

Стандартний компонент `Required` тепер створює три додаткові записи:

- `BRAVO_INSTITUTION_NAME` — назва установи;
- `BRAVO_INSTITUTION_CODE` — код установи;
- `BRAVO_ARCHIVE_PREFIX` — префікс імен архівів.

`BRAVO_ARCHIV`, `BRAVO_MAINTENANCE`, `BRAVO_ARCHIV_HEALTH` і dry-run
завантажують ці значення після `BRAVO.config`. Тому під час оновлення можна
замінювати стандартний config без повторного ручного редагування назви
установи, коду та префікса.

Значення у `BRAVO.config` залишаються fallback для першого запуску. Фінальний
dry-run повідомляє про відсутні записи Credential Manager як про помилку.

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

### Trace-модель 5.2.0: що налаштувати

- `maintenanceSettings.Trace.BISSourcePath` у `BRAVO.config` — абсолютний шлях
  до `TraceBIS.out`, якщо на сервері використовується друге trace-джерело
  (порожньо = BIS вимкнено; SRV резолвиться автоматично з
  `bravo.ini [Debug] FILE`, у config не дублюється).
- `sftpDirectories.Trace` (типово `"trace"`) — каталог добових
  `Trace_YYYYMMDD.mdz` + `.sha512` на SFTP. **Каталог треба попередньо
  створити на SFTP-сервері**, як і решту каталогів із цього блоку.
- `maintenanceSettings.Retention.CompressedLogDeletionEnabled` — типово
  `$false`: стиснуті `.mdz` журналів (включно з добовими Trace-архівами)
  ніколи не видаляються автоматично; вмикайте свідомо разом із
  `CompressedLogDays`.

Окремих Scheduled Task для Trace немає і не потрібно: всю обробку виконує
наявний `BRAVO_MAINTENANCE` (ручний запуск робить рівно те саме).

## Спочатку лише перевірка

```powershell
.\BRAVO_SETUP.ps1 -ValidateOnly
```

Цей режим не створює і не змінює постійні записи Credential Manager та
завдання Планувальника. Для перевірки Credential Manager облікового запису
`SYSTEM` може короткочасно створюватися службове завдання, яке автоматично
видаляється скриптом `BRAVO_CREDENTIALS_SETUP.ps1`.

У режимі `-ValidateOnly` тестове повідомлення не надсилається.

Якщо зовнішня мережа під час інсталяції недоступна:

```powershell
.\BRAVO_SETUP.ps1 -SkipAccessTest
```

Щоб виконати read-only тести SFTP/SMB, але не надсилати тестове повідомлення:

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
.\BRAVO_TASKS_DIAGNOSE.ps1 -ConfigPath ".\BRAVO.config" -TestAccess
```

Лише перегляд реєстрації без UAC і без тимчасового SYSTEM-завдання:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -ConfigPath ".\BRAVO.config" -InspectOnly
```

З одним тестовим повідомленням від `SYSTEM`:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -ConfigPath ".\BRAVO.config" -TestAccess -SendTestNotification
```

Тільки комплексна перевірка без змін:

```powershell
.\BRAVO_SETUP.ps1 -Action Test -ValidateOnly
```

## Окремий dry-run

Без мережевої автентифікації:

```powershell
.\BRAVO_DRY_RUN.ps1 -ConfigPath ".\BRAVO.config"
```

З read-only перевіркою доступів:

```powershell
.\BRAVO_DRY_RUN.ps1 -ConfigPath ".\BRAVO.config" -TestAccess
```

З end-to-end надсиланням одного тестового повідомлення:

```powershell
.\BRAVO_DRY_RUN.ps1 -ConfigPath ".\BRAVO.config" -TestAccess -SendTestNotification
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

## Operator notification UX

Setup, Dry Run and Diagnose test notifications use the same operator summary
style as production runtime notifications:

- ✅ success -> `Дій не потрібно`;
- ⚠️ warning -> `Потрібна дія: ...`;
- 🚨 critical -> backup, integrity, credentials or maintenance safety is at risk.

The notification is not a technical log dump. It shows institution `🏢`,
compact host/IP, optional public IP only when available, version/build and a
log reference. Backup health uses `Остання резервна копія` for SUCCESS and
`Остання успішна резервна копія` for WARNING/ERROR.
