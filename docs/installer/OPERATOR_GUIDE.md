# BRAVO Installer v1 — інструкція оператора

Статус: **Installer v1 не прийнятий для production.** Інструкція описує
поведінку коду гілки `feature/installer-v1` і призначена для тестових
серверів і VM. Для production чинними лишаються
`deploy/Install-BRAVOServer.ps1` і `deploy/Update-BRAVOServer.ps1`. Що саме
вже реалізовано, а що ні, — у [README.md](README.md), розділ «Стан
реалізації».

Усі команди — Windows PowerShell 5.1 (`powershell.exe`), не `pwsh`.

## 1. Два входи

| Вхід | Для чого | Права |
|---|---|---|
| `BRAVO_INSTALLER.ps1` | GUI для перегляду стану й перевірок | без elevation |
| `BRAVO_UPDATE.ps1` | CLI: стан, перевірки, план, виконання, відновлення, діагностика | read-only дії — без elevation; виконання — адміністратор (UAC) |

Обидва входи спершу запускають runtime guard (цілісність комплекту,
налаштування безпеки, захист від downgrade). `BRAVO_UPDATE.ps1` завжди
працює з integrity `Enforce` і читає version-state лише з `-NoWrite`.

## 2. GUI: `BRAVO_INSTALLER.ps1`

```powershell
powershell.exe -NoProfile -File .\BRAVO_INSTALLER.ps1 [-RuntimeRoot <шлях>] [-NoPause]
```

Поточний GUI — **read-only прототип**:

- показує стан встановлення й результат preflight; дані бере, запускаючи
  `BRAVO_UPDATE.ps1 -Action State|Preflight -AsJson` в окремому процесі;
- якщо знайдено кілька встановлень, дає обрати root;
- «Налаштування» відкриває `BRAVO_CONFIGURATOR.ps1` окремим процесом,
  «Журнали» відкривають каталог `<RuntimeRoot>\LOGS` у провіднику;
- кнопки встановлення, оновлення й repair **вимкнені**: mutation виконується
  лише через CLI.

Нормальне закриття вікна — код 0; збій GUI — 1; збій guard — 33/34/35.

## 3. CLI: `BRAVO_UPDATE.ps1`

### 3.1 Параметри

| Параметр | Значення |
|---|---|
| `-Action` | `State`, `Preflight`, `Plan`, `Install`, `Update`, `Repair`, `Recover`, `Diagnose`, `Initialize` (первинне створення захищених каталогів стану, потребує прав адміністратора); `Execute` — службова дія worker-а (див. 3.5) |
| `-RecoveryId` | Службовий GUID, яким неелевований CLI зв'язує elevated Recover із його `Operations\<RecoveryId>\result.json`; вручну не задається |
| `-Operation` | `Install`, `Update`, `Repair` — для `-Action Plan` (обов'язковий) і `Preflight` (необов'язковий) |
| `-RuntimeRoot` | Каталог встановлення; потрібен, якщо встановлень кілька або жодного |
| `-SourcePath` | Офлайн-джерело: шлях до `BRAVO-Toolkit-<версія>.zip` |
| `-Tag` | Онлайн-джерело: явний тег релізу (`v<версія>`); з `-SourcePath` — лише якщо тег не виводиться з імені архіву |
| `-AllowPrerelease` | Явний дозвіл prerelease (інакше prerelease відхиляється) |
| `-BackupDestination` | `Cloud`, `CloudAndSamba`, `SambaOnly`, `LocalOnly` — обов'язковий для `Install` |
| `-Scope` | `All` (типово), `Runtime`, `Scheduler` — для `Repair` |
| `-PlanPath` | Збережений план (JSON) для неінтерактивного виконання |
| `-ConfirmPlanId` | Короткий id плану (перші 8 hex `planId`) — підтвердження без діалогу |
| `-RequestPath` | Лише для `-Action Execute` |
| `-AsJson` | У stdout лише контрактний JSON; вмикає неінтерактивний режим |
| `-ResultPath` | Додатково записати результат (JSON) у файл |
| `-NonInteractive` | Без діалогів; виконання дозволено лише з `-PlanPath` і `-ConfirmPlanId` |
| `-NoPause` | Не чекати натискання клавіші в кінці |

### 3.2 Read-only дії

```powershell
# Стан встановлення (код завжди 0)
powershell.exe -NoProfile -File .\BRAVO_UPDATE.ps1 -Action State -NoPause

# Перевірки перед операцією (0 / 10 / код першого blocker-а)
powershell.exe -NoProfile -File .\BRAVO_UPDATE.ps1 -Action Preflight -Operation Update -NoPause

# Діагностичний звіт без секретів (код 0)
powershell.exe -NoProfile -File .\BRAVO_UPDATE.ps1 -Action Diagnose -AsJson -ResultPath D:\Support\bravo-diagnose.json
```

`Preflight` без `-Operation` перевіряє `Install`, якщо BRAVO не знайдено,
інакше `Update`. `Diagnose` додає до звіту результати трьох останніх
операцій.

### 3.3 План і підтвердження

```powershell
powershell.exe -NoProfile -File .\BRAVO_UPDATE.ps1 -Action Plan -Operation Update `
    -SourcePath D:\BRAVO-Release\BRAVO-Toolkit-5.3.0.zip -ResultPath D:\BRAVO-Release\plan.json -NoPause
```

План отримує, перевіряє й тимчасово розпаковує артефакт, виконує preflight
і показує: поточну й цільову версію, зміни файлів, вплив на конфігурацію й
задачі, що буде збережено, попередження й blocker-и, а також **короткий id
плану** (перші 8 hex `planId`). План дійсний 30 хвилин і прив'язаний до
передумов (fingerprint): якщо стан сервера змінився, план відхиляється як
застарілий — побудуйте новий.

### 3.4 Install / Update / Repair

Інтерактивно — CLI будує план, показує його й просить ввести короткий id:

```powershell
powershell.exe -NoProfile -File .\BRAVO_UPDATE.ps1 -Action Update -SourcePath D:\BRAVO-Release\BRAVO-Toolkit-5.3.0.zip
powershell.exe -NoProfile -File .\BRAVO_UPDATE.ps1 -Action Repair -SourcePath D:\BRAVO-Release\BRAVO-Toolkit-5.3.0.zip -Scope Runtime
powershell.exe -NoProfile -File .\BRAVO_UPDATE.ps1 -Action Install -SourcePath D:\BRAVO-Release\BRAVO-Toolkit-5.3.0.zip -BackupDestination LocalOnly
```

Неінтерактивно — лише зі збереженим планом і явним підтвердженням:

```powershell
powershell.exe -NoProfile -File .\BRAVO_UPDATE.ps1 -Action Update `
    -PlanPath D:\BRAVO-Release\plan.json -ConfirmPlanId 1a2b3c4d -NonInteractive -NoPause
```

Дія плану має збігатися з `-Action`. Неправильний id — операцію скасовано
без змін. `-NonInteractive` або `-AsJson` без `-PlanPath`/`-ConfirmPlanId`
— відмова з кодом 80.

Repair — це відновлення **тієї самої** версії: `packageVersion`,
`sourceCommit` і `buildId` артефакта мають збігатися з установленим
`VERSION.json`, інакше blocker (`Repair.VersionMismatch` /
`Repair.IdentityUnproven`). Repair ніколи не є прихованим upgrade чи
downgrade. Відкат на попередню закомічену версію у v1 не підтримується (це
downgrade).

### 3.5 Як виконується mutation

Після підтвердження CLI записує запит у
`C:\ProgramData\BRAVO\State\Update\Requests\<id>.json`. Якщо консоль уже
запущена від імені адміністратора, worker виконується в цьому ж процесі.
Інакше CLI запускає `BRAVO_UPDATE.ps1 -Action Execute -RequestPath <запит>`
через UAC і чекає на результат. Скасований UAC — код 36, змін немає.
Перед будь-якою зміною worker повторно перевіряє запит, корені, актуальність
плану й preflight.

### 3.6 Відновлення після перерваної операції

```powershell
powershell.exe -NoProfile -File .\BRAVO_UPDATE.ps1 -Action Recover
```

Потрібен, якщо стан — `InterruptedUpdate` або `RollbackRequired`, або якщо
результат радить `-Action Recover`. Без прав CLI сам перезапускається через
UAC. Recovery:

- немає відкритих журналів — `Success`, нічого не потрібно;
- зміни ще не починались — прибирає staging/backup операції, журнал
  `Abandoned`, результат `Failed` (80): сервер не змінено, побудуйте новий
  план;
- зміни почались — транзакційний відкат до попереднього стану
  (`RolledBack`, 81) або `Critical` (82);
- кілька відкритих журналів — `Failed/Blocked`, потрібен ручний аналіз;
  пошкоджений журнал — `Critical` без жодних змін. Журнали вручну не
  видаляйте.

Recovery можна запускати повторно: кроки ідемпотентні.

## 4. Результати й коди завершення

| Статус | Що означає | Що робити | Код |
|---|---|---|---|
| `Success` | Операцію виконано й перевірено | Нічого | 0 |
| `SuccessWithWarnings` | Виконано, але є попередження. **Не зелений успіх.** Для Update/Repair попередній стан задач відновлено, finding перелічує попередження | Прочитати findings, усунути причини | 10 |
| `Failed` | Операцію не виконано; зміни runtime не починались (`reasonCode`: `Blocked`, `Cancelled`, `PlanStale`, `VerificationFailed`, `Error`) | Усунути blocker, побудувати новий план | код першого blocker-а або 80 |
| `RolledBack` | Зміни почались, стався збій, попередній стан відновлено й перевірено | Розібрати причину за журналом і логами | 81 |
| `Critical` | Відкат не вдався або стан невідомий. Керовані задачі вимкнено, backup і журнал збережено | **Не вмикати задачі вручну**, не запускати нових операцій; передати журнал і backup адміністратору | 82 |

Задачі після операції (D6): Update/Repair повертають той enabled-стан, що
був до операції; clean install лишає задачі неактивними до явної активації;
після `Critical` задачі ніколи не вмикаються.

Інші коди:

| Код | Назва | Коли |
|---|---|---|
| 1 | — | Не вдалося завантажити модуль `BRAVO.Update` (або збій GUI) |
| 20 | `SkippedLockBusy` | Виконується інша операція оновлення, Archive чи Maintenance; дочекайтеся завершення, процеси не завершуйте |
| 30 | `InvalidConfiguration` | Blocker конфігурації |
| 31 | `CredentialsUnavailable` | Blocker credentials |
| 33 | `RuntimeIntegrityViolation` | Порушено цілісність комплекту (guard або blocker) |
| 34 | `SecuritySettingsWeakened` | Guard: послаблені налаштування безпеки |
| 35 | `VersionDowngradeBlocked` | Захист від downgrade або в середовищі задано `BRAVO_ALLOW_DOWNGRADE` |
| 36 | `PrivilegeRequired` | Немає прав адміністратора або UAC скасовано |
| 37 | `EnvironmentUnavailable` | Blocker середовища |
| 42 | `HashValidationFailed` | Артефакт не пройшов перевірку (хеш, маніфест, тег, підміна) |
| 80 | `DeploymentFailed` | Збій без конкретнішого коду, неправильне використання CLI |

`State` і `Diagnose` завжди повертають 0. `Preflight` і `Plan`: 0 — без
зауважень, 10 — є попередження, інакше код першого blocker-а (або 80).

## 5. Де що лежить

| Шлях | Вміст |
|---|---|
| `C:\ProgramData\BRAVO\State\Update\Journal\<operationId>.json` | Журнал операції (write-ahead) |
| `C:\ProgramData\BRAVO\State\Update\Operations\<operationId>\` | `request.json`, `progress.jsonl`, `result.json`, `logs\` (логи guard/setup/self-test після маскування секретів), знімки задач і version-state, `deploy-keys.json`, `control\` |
| `C:\ProgramData\BRAVO\State\Update\Requests\` | Запити на виконання |
| `C:\ProgramData\BRAVO\Update\Backup\<operationId>\` | Backup runtime (`runtime\`, `backup-manifest.json`); автоматично не видаляється |
| `C:\ProgramData\BRAVO\Update\Staging\` | Тимчасове розпакування артефакта |
| `C:\ProgramData\BRAVO\Locks\` | `BRAVO_UPDATE.lock` (+ `BRAVO_UPDATE.holder.json` для показу власника), `BRAVO_OPERATION.lock` |
| `<RuntimeRoot>\LOGS` | Логи продукту BRAVO |

Backup-и прибираються вручну (R5).

## 6. Офлайн-пакет

Покладіть у один каталог три файли того самого релізу:

- `BRAVO-Toolkit-<версія>.zip`;
- `BRAVO-Toolkit-<версія>.zip.sha256`;
- `release-manifest.json` (для Installer v1 обов'язковий).

Передайте `-SourcePath <шлях до zip>`. Тег виводиться з імені архіву
(`v<версія>`); інакше вкажіть `-Tag`. Файли копіюються в приватний
робочий каталог і перевіряються вже там, тим самим конвеєром, що й онлайн:
SHA-256, відповідність маніфесту й тегу, prerelease policy, захист від
downgrade, безпечне розпакування, перевірка staged runtime. Онлайн-джерело
(`-Tag` без `-SourcePath`) приймає лише `https://` (і `file://` для локальних
дзеркал). Режиму «latest» немає.

## 7. Credentials

Installer і engine секретів не бачать і не приймають. Введення —
інтерактивно в окремому видимому вікні:

```powershell
powershell.exe -NoProfile -File "C:\Program Files\BRAVO-Toolkit\BRAVO_SETUP.ps1" -Action Credentials
```

Після введення credentials на новому сервері виконайте Repair з
`-Scope Scheduler`, щоб зареєструвати задачі; активацію задач підтверджуйте
явно (D6). Engine лише перевіряє присутність credentials
(`Found`/`Missing`/`Unknown`).

## 8. Чого Installer ніколи не робить

- Не оновлює автоматично: немає scheduled, silent чи «latest»-оновлення
  (D1).
- Не приймає, не зберігає й не логує секрети; логи дочірніх процесів
  проходять маскування.
- Не завершує процеси примусово: зайнятий lock — це blocker «дочекайтеся
  завершення»; за таймаутом завершується лише власний дочірній процес
  engine.
- Не видаляє й не перезаписує site-конфігурацію та дані: `BRAVO.config`,
  `BRAVO.local.config`, `TOOLS_INTEGRITY.json`, `WinSCP.ini`,
  `BRAVO_OPERATION.lock` і каталоги `LOGS`, `MODEL`, `BLOG`, `BRAVOEXCH`,
  `BAZA`, `BAZA_WWW`, `artifacts` виключені з backup, deploy і відкату;
  збереження site-конфігурації перевіряється за SHA-256.
- Не встановлює `BRAVO_ALLOW_DOWNGRADE` і відмовляє, якщо вона є в
  середовищі.
- Не переносить і не перейменовує наявні каталоги встановлення.
- Не вмикає задачі після `Critical`.
