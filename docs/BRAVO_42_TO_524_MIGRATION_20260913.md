# Міграція BRAVO-Toolkit 4.2.x → 5.2.4 — операторська процедура

Дата: 2026-09-13. Джерело фактів — теги `v4.2.13` і `v5.2.4` у репозиторії.

Цей документ **не замінює** `BRAVO_524_FLEET_ROLLOUT_RUNBOOK_20260913.md`.
Той runbook описує оновлення 5.2.3 → 5.2.4 копіюванням поверх. Для 4.2 така
модель непридатна, і це не питання налаштування — див. розділ 1.

Після завершення міграції сервер стає звичайним сервером 5.2.4, і надалі до
нього застосовний саме fleet-runbook.

---

## 1. Чому не можна оновити поверх

Три незалежні жорсткі стопи, кожен перевірено по тегах.

**1.1. Немає runtime guard.** У `v4.2.13` відсутні `BRAVO_RUNTIME_GUARD.ps1`
і `RUNTIME_MANIFEST.json` — у комплекті 56 файлів проти 125 у 5.2.4.
Помічник `Update-BRAVOServer.ps1` вимагає guard у наявній інсталяції і
відмовиться працювати ще до preflight.

**1.2. Завантажувач 4.2 не дає ефективної конфігурації, якої чекає
preflight.** `BRAVO_CONFIG_LOADER.ps1` у 4.2 — 265 рядків проти 846 у 5.2.4;
`$global:effectiveLimsRoot` він не створює взагалі, а його
`Import-BravoConfiguration` не має параметра `-RuntimeRoot`.

**1.3. Збережений `BRAVO.config` від 4.2 зламає 5.2.4.** Завантажувач 5.2.4
викликає файл конфігурації беззастережно, без try/catch:

```powershell
& $legacyConfigScript -ConfigRoot $ConfigRoot -RuntimeRoot $RuntimeRoot
```

`param()` у `BRAVO.config` версії 4.2 оголошує лише `$ConfigRoot`. Прив'язка
параметра впаде ще до першого рядка конфігурації.

Саме тут модель fleet-runbook перевертається: те, що для 5.2.3 є перевагою
(«конфігурацію збережено недоторканою»), для 4.2 є блокером.

---

## 2. Модель переходу

    нова інсталяція 5.2.4 у ЧИСТИЙ каталог
        -> site-відмінності переносяться у BRAVO.local.config
        -> BRAVO.config з комплекту НЕ редагується
        -> стара інсталяція лишається на місці як відкат

Ключовий принцип 5.x (README §10, пункт 3): site-відмінності живуть у
`BRAVO.local.config` — data-only hashtable «dot-шлях -> значення», якої немає
в release-архіві і якої оновлення не торкається. Для сервера з 4.2 це
**одноразова міграція**, а не робота на кожне оновлення.

Формат fail-closed: невідомий або помилковий dot-шлях — це помилка
конфігурації при запуску. Це працює на вас: перенесений під старою назвою
ключ (`componentSettings.Synchronization.BAZASFTP`) не спрацює мовчки, а
зупинить запуск із кодом `30`.

---

## 3. Крок 0 — інвентаризація старого сервера (нічого не змінює)

Зафіксуйте письмово, зі старої інсталяції:

| Що | Де в 4.2 |
|---|---|
| `pathSettings.LIMSRoot`, `ArchiveRoot`, `BackupRoot` | `BRAVO.config` |
| фактичні джерела MODEL/BLOG/BRAVOEXCH | `sourcePaths` (у 4.2 виводились із `LIMSRoot`) |
| `componentSettings` — що увімкнено | `BRAVO.config` |
| `maintenanceSettings.Limits.MinimumFreeSpaceGB`, `ExcludedDrives` | `BRAVO.config` |
| розклад: часи Backup/Maintenance/Health | `schedulerSettings` |
| `Restore.RunMissedOnStartup` | `maintenanceSettings.Restore` |
| SFTP-хост, порт, fingerprint, кореневий шлях | `sftpSettings` |
| SMB/NAS UNC, якщо увімкнено | `smbSettings` |
| NotificationProvider / NotificationMode | `bravoSettings` |
| перелік записів Credential Manager | `cmdkey /list` (лише імена, не значення) |

**Секрети не виписуйте.** Вони лишаються в Credential Manager і потрібні
лише за іменами записів — див. розділ 5.

Окремо занотуйте фактичне вільне місце на робочому томі: у 5.2.4 поріг
`MinimumFreeSpaceGB` поводиться по-різному в Archive і Maintenance (розділ 8).

---

## 4. Крок 1 — таблиця відповідності конфігурації 4.2 → 5.2.4

Порівняння ключів двох `BRAVO.config`: 73 нових ключі, 17 зниклих, 17 змінених
значень за замовчуванням. Операторськи значущі — нижче.

### 4.1. Перейменовано (значення переносити під НОВОЮ назвою)

| 4.2 | 5.2.4 |
|---|---|
| `componentSettings.Synchronization.BAZALocal` | `componentSettings.Synchronization.BAZA_APP_LOCAL` |
| `componentSettings.Synchronization.BAZASFTP` | `componentSettings.Synchronization.BAZA_APP_SFTP` |
| `componentSettings.Synchronization.BAZAWWWSFTP` | `componentSettings.Synchronization.BAZA_WWW_SFTP` |
| `bazaPaths.*` | `bazaAppPaths.*` (похідний блок — через local.config НЕ перевизначається) |
| `credentialSettings.Targets.SlackWebhook` | `SlackWebhookGeneral` + `SlackWebhookAlerts` |
| `credentialSettings.Targets.DiscordWebhook` | `DiscordWebhookGeneral` + `DiscordWebhookAlerts` |
| `maintenanceSettings.Restore.RunMissedOnStartup = $true` | `maintenanceSettings.Restore.BootRestoreMode = "HoldServices"` |

`BootRestoreMode` приймає `"None"` або `"HoldServices"`; від нього похідно
вмикається завдання `BRAVO_RESTORE_RECOVERY`. `$false` у старому ключі
відповідає `"None"`.

### 4.2. Зникли (переносити нікуди)

`pathSettings.ArchiveRoot` (лишився лише `BackupRoot`),
`maintenanceSettings.RangeIdMonitoring.FilePath`,
`schedulerSettings.Recovery.RetryDurationHours`/`RetryEveryMinutes`,
`backupMonitoring.AlertStatePath`/`LogFileNameTemplate`/`RepeatAlertAfterHours`/
`NotifyOnSuccessAfterBackup`.

### 4.3. Нове, що варто свідомо переглянути

| Ключ | За замовчуванням | Чому важливо |
|---|---|---|
| `pathSettings.LIMSRoot` | `""` = AUTO | у 4.2 було `Split-Path $ConfigRoot -Parent`, тобто комплект мав лежати всередині дерева LIMS. У 5.x код і дані розділені |
| `pathSettings.BackupRoot` | `""` = AUTO | те саме |
| `pathSettings.SystemLogRoot` | `""` = AUTO | новий корінь для системних журналів BRAVO |
| `maintenanceSettings.Limits.ExcludedDrives` | `@("F:\")` | у 4.2 було `@()`. У комплекті 5.2.4 це НЕ порожньо — перевірте, чи доречно на вашому сервері |
| `maintenanceSettings.Limits.EstimatedSpaceMarginPercent` | `25` | запас розрахункової оцінки Archive |
| `toolIntegritySettings.Mode` | `"Enforce"` | розбіжність `Tools\` з `TOOLS_MANIFEST.json` блокує запуск, код `32` |
| `operationLockSettings.Path` | `%ProgramData%\BRAVO\Locks\` | спільний lock Archive/Maintenance, код `20` |
| `schedulerSettings.BAZASync` | кожні 4 год | **нове заплановане завдання**, якого в 4.2 не було |
| `bravoSettings.NotificationRouting` | SUCCESS→general, решта→alerts | двоканальна маршрутизація |
| `backupMonitoring.SizeSanity` | увімкнено | контроль різкого падіння обсягу backup |
| `hostInformationSettings.PublicIPLookupEnabled` | `$false` | у 4.2 було `$true` |

### 4.4. Чого через `BRAVO.local.config` перевизначати НЕ можна

Похідні блоки `sourcePaths`, `archiveDirs`, `bazaAppPaths`, `bazaWWWPaths`,
`archiveDefinitions`, а також `toolIntegritySettings` і runtime-шляхи.

`discoverySettings` до цього переліку більше НЕ належить (#158, етап 4):
блок став звичайним raw-блоком фази 1, тому
`discoverySettings.BravoRoot`, `discoverySettings.WebRoot`,
`discoverySettings.BravoIniPath` і `discoverySettings.Sources.*` у
`BRAVO.local.config` застосовуються ДО discovery й реально визначають
джерела. Правити `BRAVO.config` вручну для цього більше не потрібно.

---

## 5. Крок 2 — що робити з Credential Manager

**Переживають перехід без жодних дій** (імена записів не змінились):
`BRAVO_SFTP_LOGIN`, `BRAVO_SFTP_PASSWORD`, `BRAVO_SMB_LOGIN`,
`BRAVO_SMB_PASSWORD`, `BRAVO_7Z_PASSWORD`, `BRAVO_INSTITUTION_NAME`,
`BRAVO_INSTITUTION_CODE`, `BRAVO_ARCHIVE_PREFIX`.

**Потрібно створити заново** — webhook-и сповіщень. У 5.2.1 provider-wide
записи виведено з контракту:

| 4.2 | 5.2.4 |
|---|---|
| `BRAVO_DISCORD_URL` | `BRAVO_DISCORD_GENERAL_URL` + `BRAVO_DISCORD_ALERTS_URL` |
| `BRAVO_SLACK_URL` | `BRAVO_SLACK_GENERAL_URL` + `BRAVO_SLACK_ALERTS_URL` |

Старі записи 5.2.4 **ігнорує і не видаляє автоматично**. Прибирайте їх
вручну лише після успішної першої доби.

Можна вказати той самий webhook для GENERAL і ALERTS, якщо окремого каналу
попереджень в установі немає — маршрутизація тоді просто зводиться в один
канал.

---

## 6. Крок 3 — розгортання

Стара інсталяція лишається на місці й не змінюється. Це і є ваш відкат.

1. Розпакуйте `BRAVO-Toolkit-5.2.4.zip` у **новий** каталог, за
   замовчуванням `C:\Program Files\BRAVO-Toolkit`. Звірте SHA-256:
   `DDBECEFF5ED5E1AAF77F416AB6CC5CB318E7B8E7AC0BBA98BFF1B19873E66A45`.
2. `BRAVO.config` з комплекту **не редагуйте**.
3. Скопіюйте `BRAVO.local.config.example` у `BRAVO.local.config` поруч із
   `BRAVO.config` і внесіть **лише** site-відмінності з кроку 0, під новими
   назвами з розділу 4.1. Приклад:

```powershell
@{
    'pathSettings.LIMSRoot' = 'D:\LIMS'
    'pathSettings.BackupRoot' = 'E:\ARCHIV'
    'maintenanceSettings.Limits.MinimumFreeSpaceGB' = 20
    'maintenanceSettings.Limits.ExcludedDrives' = @()
    'maintenanceSettings.Restore.BootRestoreMode' = 'None'
    'componentSettings.Synchronization.BAZA_APP_SFTP' = $true
    'bravoSettings.NotificationProvider' = 'discord'
    'bravoSettings.NotificationMode' = 'errors_only'
}
```

4. Секрети, назву установи, код і префікс у config **не переносьте** — вони
   в Credential Manager.

Якщо `LIMSRoot`/`BackupRoot` на сервері стандартні, лишіть `""` (AUTO) і
перевірте результат на кроці 4 — явне значення потрібне лише там, де AUTO
дає не те.

---

## 7. Крок 4 — валідація до будь-яких production-дій

Усе з піднятими правами, у каталозі нової інсталяції.

```powershell
.\BRAVO_SELF_TEST.ps1
.\BRAVO_SETUP.ps1 -ValidateOnly
.\BRAVO_SETUP.ps1 -Action Test -ValidateOnly
```

Третя команда — найважливіша для міграції саме з 4.2. Її розділ
`=== DISCOVERY ДЖЕРЕЛ ===` показує, як 5.2.4 визначає MODEL, BLOG,
BRAVOEXCH, BAZA_APP і BAZA_WWW.

**Звірте цей перелік із тим, що архівувалось у 4.2.** У 4.2 джерела
виводились із `LIMSRoot` (`<LIMSRoot>\Model\*`, `<LIMSRoot>\BLOG\*`), у 5.x
вони читаються з `[model]` у canonical `bravo.ini` і з підтверджених служб.
На більшості серверів результат збігається — але збіг треба **побачити**, а
не припустити. Розбіжність тут означає, що після міграції архівувався б
інший каталог.

Якщо discovery дає не те або повідомляє про кілька служб-кандидатів —
закріпіть значення явно через `discoverySettings.*` у `BRAVO.local.config`
(розділ 4.4). Явне значення завжди перемагає auto-discovery і ніколи ним
не замінюється.

Коли перелік джерел правильний, зафіксуйте базову лінію:

```powershell
.\BRAVO_SETUP.ps1 -Action Test -ValidateOnly -ConfirmDiscoveryBaseline
```

Крок обов'язковий, а не рекомендований: без зафіксованої базової лінії
подальші прогони не мають з чим порівнювати склад джерел, і зникле
джерело виглядає легітимно відсутнім.

Baseline зберігається в машинному стані —
`%ProgramData%\BRAVO\State\DISCOVERY_BASELINE.json` — тому переживає
перевстановлення комплекту в інший каталог. Якщо на сервері вже є baseline
у старому розташуванні (`<RuntimeRoot>\LOGS\DISCOVERY_BASELINE.json`),
перший же прогін перенесе його автоматично й повідомить про це рядком
`Discovery baseline перенесено у машинний стан: ...`; підтверджувати
базову лінію заново для цього не потрібно.

---

## 8. Крок 5 — поріг вільного місця

Перевірте фактичне вільне місце на робочому томі проти
`Limits.MinimumFreeSpaceGB`, який ви щойно перенесли.

У 5.2.4 Archive отримав розрахунок потреби і поріг для нього — індикатор
здоров'я. **Maintenance такого розрахунку не має**, тому для нього поріг
лишається жорстким гейтом, при спільному ключі конфігурації. Сервер із
завищеним порогом вдень успішно архівуватиме, а вночі валитиме
обслуговування з `BelowFallbackFloorNoEstimate` і кодом `60`.

Розгорнуто — розділи 1 і 5 fleet-runbook. Типове значення в комплекті — 20 GB.

---

## 9. Крок 6 — налаштування і планувальник

```powershell
.\BRAVO_SETUP.ps1
```

Режим `Full` запитує лише **відсутні** credentials (наявні не
перезаписуються), перевіряє їх читання від `SYSTEM`, встановлює завдання
Планувальника і надсилає одне тестове сповіщення. Саме тут ви внесете нові
webhook-записи з розділу 5.

Якщо зовнішня мережа недоступна — `-SkipAccessTest`; якщо не треба тестового
повідомлення — `-SkipTestNotification`.

Далі:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -InspectOnly
.\BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess
```

**Про старі завдання.** Каталог планувальника (`\BRAVO\`) і імена чотирьох
завдань у 4.2 і 5.2.4 однакові: `BRAVO_ARCHIV`, `BRAVO_MAINTENANCE`,
`BRAVO_ARCHIV_HEALTH`, `BRAVO_RESTORE_RECOVERY`. Реєстрація перезаписує їх і
перенацілює на новий каталог — окремо видаляти нічого не треба. Додається
п'яте, нове: `BRAVO BAZA Synchronization`.

Переконайтесь у `-InspectOnly`, що `ScriptPath` усіх завдань вказує на **нову**
інсталяцію. Якщо стара лишилась у планувальнику — це єдина ситуація, коли
потрібен `BRAVO_TASKS_UNINSTALL.ps1` зі **старої** інсталяції, і лише до
повторного `-Action Scheduler` з нової.

---

## 10. Крок 7 — перший контрольований прогін

```powershell
.\BRAVO_DRY_RUN.ps1
```

Потім один ручний повний прогін архівації поза нічним вікном і перевірка
результату в `<нова інсталяція>\LOGS`.

**Логи й стан переїхали.** У 4.2 журнали лежали в `<ArchiveRoot>\LOGS`, у
5.2.4 — у `LOGS` самого комплекту, а машинний стан — у
`%ProgramData%\BRAVO\State`. Старі логи лишаються на місці й не мігрують;
шукайте нові там, де новий комплект.

---

## 11. Перша доба

Не вважайте міграцію завершеною, доки не побачите обидві нічні операції і
першу синхронізацію BAZA.

- `BRAVO_ARCHIV_*.log` — `Результат: УСПIШНО`, generation `COMPLETE`;
- `BRAVO_MAINTENANCE_*.log` — `СТАТУС: УСПІШНО`, без
  `BelowFallbackFloorNoEstimate`;
- `BRAVO_ARCHIV_HEALTH_*.log` — без критичних;
- завдання `BRAVO BAZA Synchronization` — окрема увага: стан BAZA у 5.x
  живе в `%ProgramData%\BRAVO\State\BAZA` і на новому сервері порожній, тож
  перший прогін піде повним аудитом. Віддалений каталог SFTP при цьому той
  самий (`baza_app`), локальний каталог-призначення — новий
  (`<BackupRoot>\BAZA_APP` замість `<BackupRoot>\BAZA`). Режим —
  `IncrementalAppendOnly` з `MutationPolicy = "Fail"`, тобто будь-яка
  несподівана мутація зупинить синхронізацію, а не «полагодить» її тихо.

Коди завершення — таблиця в розділі 7 fleet-runbook і повна матриця в
README §12.

---

## 12. Відкат

Стара інсталяція 4.2 лишилась незмінною, тому відкат — це:

1. переконатись, що жодне завдання `\BRAVO\` не виконується;
2. зі **старої** інсталяції виконати `.\BRAVO_SETUP.ps1 -Action Scheduler`
   — завдання перереєструються на старі шляхи;
3. перевірити `-InspectOnly`.

`BRAVO.local.config` нової інсталяції при цьому нікуди не дінеться і
знадобиться при повторній спробі.

Webhook-записи GENERAL/ALERTS, створені на кроці 6, старій версії не
заважають — вона їх просто не читає.

**Не перейменовуйте каталоги інсталяцій** ні при міграції, ні при відкаті:
ACL-захист `BRAVO_TASKS_INSTALL` забороняє це навіть адміністратору.

---

## 13. Чого цей документ не покриває

Перелічено свідомо — це межі перевіреного.

1. **Процедуру не виконано на живому сервері.** Вона зібрана з фактичного
   вмісту тегів `v4.2.13` і `v5.2.4` (конфігурації, завантажувач, планувальник,
   credentials, README §5 і §10). Першою має бути одна пілотна установка, а
   не масовий перехід.
2. **Ретенція старих архівів 4.2 новим комплектом** не перевірялась. Імена
   архівів залежать від `ArchivePrefix`, який переживає перехід, але
   поведінку ретенції на успадкованому наборі файлів варто подивитись у
   перший же прогін Maintenance.
3. **Повноту backfill-ів завантажувача** для ключів, доданих між 4.2 і 5.2.4,
   не перевірено — і не потрібно: процедура свідомо бере `BRAVO.config` з
   комплекту 5.2.4, а не успадкований.
4. **Проміжні версії.** Процедура написана для переходу 4.2.x → 5.2.4
   напряму. Сервери на 4.4 чи 5.0–5.2.2 мають інший, менший набір
   відмінностей і окремої перевірки тут не отримали.

Ніколи не «лагодьте» помилку цілісності видаленням маніфеста —
`RUNTIME_MANIFEST.json`, `TOOLS_MANIFEST.json` чи `TOOLS_INTEGRITY.json`. Це
вимикає діючий контроль, а не усуває причину. Порядок дій при кодах `32`/`33`
— у матриці діагностики README §12.
