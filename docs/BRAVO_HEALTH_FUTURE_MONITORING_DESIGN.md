# BRAVO Health Monitoring — концепція майбутньої реалізації

## Статус документа

**Тип:** технічна концепція / TODO  
**Призначення:** зафіксувати майбутній розвиток `BRAVO_HEALTH` як центрального lightweight watchdog стану сервера, сервісів, регламентних робіт і резервного копіювання.  
**Поточний runtime:** цим документом не змінюється.  
**Рекомендований майбутній реліз:** окремий функціональний release після стабілізації поточного циклу.

---

# 1. Мета

`BRAVO_HEALTH` повинен працювати не лише як періодична перевірка backup, а як центральний механізм спостережуваності за станом BRAVO-сервера.

Основні задачі:

- швидко виявляти зупинені або проблемні служби;
- бачити пропущені регламентні роботи;
- контролювати останню `COMPLETE` backup generation;
- контролювати локальний backup і remote copies;
- бачити стан SFTP/SMB/BAZA;
- виявляти stale backup;
- показувати загальний стан системи;
- не створювати notification spam;
- бути джерелом фактичного стану для майбутнього Recovery coordinator.

---

# 2. Рекомендована частота

## Fast Health

Рекомендований інтервал:

```text
кожні 30 хвилин
```

60 хвилин допустимо, але 30 хвилин дає кращу оперативність при малому навантаженні.

Fast Health не повинен запускати дорогі повні перевірки великих archive-файлів кожні 30 хвилин.

## Deep Health

Рекомендовано:

```text
кожні 4 години
+
після успішного Archive
```

Deep Health може виконувати дорожчі перевірки:

- SHA512;
- archive integrity;
- remote verification;
- детальну перевірку component state.

---

# 3. Розділення ролей

Не змішувати detection і remediation.

```text
HEALTH
=
detect + classify + report

RECOVERY
=
decide recovery action

ARCHIVE
=
create backup
```

`BRAVO_HEALTH` не повинен самостійно запускати full Archive лише через знайдену проблему.

Health формує факт стану.

Recovery у майбутньому приймає рішення:

```text
NeedNewLocalBackup
NeedRemoteRecovery
NeedBAZARecovery
NothingToRecover
```

---

# 4. Що повинен перевіряти Fast Health

## 4.1. System

Перевіряти:

- uptime;
- факт недавнього reboot;
- доступність required local disks;
- free space;
- доступність runtime/config/BackupRoot;
- критичні filesystem conditions.

Приклад:

```text
System
Windows: OK
Uptime: 3 дні 14 год.
Disk C: OK
Disk D: OK
BackupRoot: OK
```

---

# 5. Services

Перевіряти тільки configured/enabled компоненти.

Основні:

```text
BRAVO
exchangAPI
BRAVO Web / Apache — якщо enabled/installed
```

Стани:

```text
Running
Stopped
Missing optional
Missing required
Unknown
```

Optional service, якого немає і який вимкнений конфігурацією, не є warning.

Required service, який повинен працювати, але `Stopped`, — `CRITICAL`.

---

# 6. Scheduled Tasks

Health повинен контролювати не тільки `LastTaskResult`, а й фактичне виконання регламентних робіт.

Основні task classes:

```text
BRAVO_ARCHIV
BRAVO_MAINTENANCE
BRAVO_ARCHIV_HEALTH
BRAVO_RESTORE_RECOVERY
BAZA Sync
```

Для кожного:

- enabled/disabled;
- останній запуск;
- останній result;
- наступний запуск;
- чи пропущений expected schedule;
- чи є overdue execution.

---

# 7. Пропущені регламентні роботи

Це ключова нова можливість.

Не достатньо перевірити:

```text
LastTaskResult
```

Треба розрахувати:

```text
ExpectedRunTime
LastActualRun
LastSuccessfulRun
CurrentTime
GracePeriod
```

Приклад:

```text
Archive schedule: 23:00
Current time: 00:30
Expected run: 10.08.2026 23:00
Latest COMPLETE generation: 09.08.2026 23:07
```

Health повинен класифікувати:

```text
CRITICAL
Регламентне резервне копіювання пропущено
```

і показати:

```text
Очікувався запуск: 10.08.2026 23:00
Остання COMPLETE generation: 09.08.2026 23:07
Вік backup: 25 год. 23 хв.
```

---

# 8. Exit code не є єдиним джерелом істини

Не використовувати policy:

```powershell
if ($LastTaskResult -ne 0) {
    Problem = $true
}
```

Приклад:

```text
10 = SuccessWithWarnings
```

може означати:

```text
Range ID file missing
```

при повністю валідному backup.

Health повинен розрізняти:

```text
task execution result
backup result
remote delivery result
system warnings
```

---

# 9. Backup generation state

Health повинен орієнтуватися на:

```text
latest valid COMPLETE generation
```

а не просто:

```text
latest .mdz
latest timestamp
latest task run
```

Перевіряти:

- generationId;
- status;
- required components;
- local verification;
- age;
- manifest;
- remote state.

---

# 10. Local backup components

Для enabled components:

```text
MODEL
BLOG
BRAVOEXCH
```

Health показує:

```text
OK
WARNING
FAILED
MISSING
STALE
INCOMPLETE
```

Не вважати partial/incomplete generation valid backup.

---

# 11. Backup age

Потрібні configurable thresholds.

Наприклад:

```text
Healthy:
backup age <= expected schedule + normal grace

Warning:
backup трохи прострочений

Critical:
немає COMPLETE backup довше critical threshold
```

Не прив'язувати threshold жорстко до одного часу.

Параметри мають бути config-driven.

---

# 12. Remote backup state

Health повинен окремо показувати local і remote.

Приклад:

```text
Local:
COMPLETE
Verified

SFTP:
MODEL       OK
BLOG        OK
BRAVOEXCH   FAILED

SMB:
disabled
```

Не називати Local backup failed, якщо failed тільки remote delivery.

---

# 13. BAZA state

Для BAZA components:

```text
BAZA_APP
BAZA_WWW
```

перевіряти лише якщо enabled.

Можливі стани:

```text
Current
Stale
Failed
Disabled
Not configured
```

BAZA failure не повинна автоматично означати необхідність нового MODEL/BLOG/BRAVOEXCH backup.

---

# 14. Global Health State

Рекомендовані три верхньорівневі стани:

```text
HEALTHY
WARNING
CRITICAL
```

## HEALTHY

Приклад:

```text
BRAVO             Running
exchangAPI        Running
Archive           OK
Maintenance       OK
Local backup      COMPLETE
SFTP              Current
BAZA_APP          Current
Disk space        OK
```

## WARNING

Приклади:

```text
Range ID log missing
SFTP тимчасово недоступний, але Local COMPLETE
disk space наближається до threshold
Maintenance = SuccessWithWarnings
```

## CRITICAL

Приклади:

```text
BRAVO service stopped
required service missing
Archive пропущений
немає свіжої COMPLETE generation
local integrity failed
required archive component missing
backup age перевищив critical threshold
```

---

# 15. Notification policy

Fast Health може запускатися кожні 30 хвилин, але **не повинен надсилати повний Discord/Slack report кожні 30 хвилин**.

Потрібний persisted state.

Рекомендовані поля:

```text
PreviousHealthState
CurrentHealthState
ProblemFingerprint
FirstDetectedAt
LastDetectedAt
LastNotifiedAt
RecoveryNotifiedAt
```

---

# 16. State transition notifications

Рекомендована логіка:

```text
HEALTHY -> HEALTHY
нічого не надсилати

HEALTHY -> WARNING
відправити warning

WARNING -> WARNING
не дублювати

WARNING -> CRITICAL
відправити critical

CRITICAL -> CRITICAL
не дублювати

WARNING -> HEALTHY
відправити recovery

CRITICAL -> HEALTHY
відправити recovery
```

Це основний anti-spam contract.

---

# 17. Problem fingerprint

Не достатньо зберігати тільки:

```text
CurrentHealthState = WARNING
```

Треба розрізняти набір проблем.

Наприклад:

```text
WARNING:
RangeIdMissing

потім:

WARNING:
SFTPStale
```

це нова проблема, хоча global state залишився `WARNING`.

Тому потрібен fingerprint.

Наприклад:

```text
RangeIdMissing
Service:BRAVO:Stopped
Task:Archive:Missed
Backup:Local:Stale
SFTP:BLOG:Missing
```

Набір активних fingerprints порівнюється з попереднім запуском.

---

# 18. Notification reminder

Для довгих проблем допустимий reminder.

Рекомендовано configurable:

```text
Critical reminder: кожні 4–6 годин
Warning reminder: рідше або disabled
```

Не надсилати однаковий warning кожні 30 хвилин.

---

# 19. Daily System Summary

Повний system status краще відправляти окремо:

```text
1 раз на добу
```

Рекомендований час — configurable, наприклад ранок.

Приклад:

```text
✅ BRAVO — СТАН СИСТЕМИ

🏢 TEST-COMPANY [1234567890]
🖥 DEV-LIMS

Система
Windows Server 2022
Uptime: 3 дні 14 год.
Диски: OK

Служби
BRAVO: Running
exchangAPI: Running

Регламентні роботи
Archive: 10.08.2026 22:42 — успішно
Maintenance: 10.08.2026 23:55 — з попередженнями

Резервні копії
Generation: 20260810_224224
Вік: 3 год. 21 хв.
MODEL: OK
BLOG: OK
BRAVOEXCH: OK

Remote
SFTP archives: OK
BAZA_APP: OK
NAS: вимкнено

⚠️ Попередження
Range ID log відсутній

Загальний стан: WARNING
```

---

# 20. Fast Health vs Deep Health

## Fast Health — кожні 30 хвилин

Перевіряє:

```text
services
disk space
scheduler
missed jobs
last COMPLETE generation
backup age
manifest metadata
local component state
remote state metadata
pending recovery state
BAZA state metadata
```

Fast Health не повинен щоразу перечитувати весь великий archive-файл.

## Deep Health — кожні 4 години

Додатково:

```text
SHA512 verification
7-Zip integrity
remote checksum verification
детальна component verification
SFTP remote verification
```

## Post-backup Deep Health

Після Archive:

```text
Archive
  ->
Deep Health
```

для підтвердження щойно створеної generation.

---

# 21. Performance requirement

Fast Health повинен бути lightweight.

Ціль:

```text
не читати сотні MB/GB кожні 30 хвилин без необхідності
```

Використовувати:

- manifests;
- file metadata;
- persisted verification state;
- scheduler state;
- service state;
- timestamps.

Дорогі integrity checks — Deep Health.

---

# 22. Grace periods

Щоб уникнути false positive одразу після schedule time, потрібен grace period.

Наприклад:

```text
Archive scheduled: 23:00
Grace: 60 хв.
```

О 23:15 Archive ще може виконуватися — це не `Missed`.

Health повинен враховувати:

```text
scheduled time
expected duration
grace period
operation lock/current execution
```

---

# 23. Running operation awareness

Health повинен розуміти активну операцію.

Наприклад:

```text
Archive scheduled 23:00
Current time 23:20
Archive operation lock active
```

Результат:

```text
Archive: RUNNING
```

а не:

```text
Archive: MISSED
```

---

# 24. Maintenance classification

Maintenance має окремі стани:

```text
Success
SuccessWithWarnings
Failed
Missed
Running
```

`SuccessWithWarnings`:

```text
WARNING
```

але робота не вважається пропущеною.

---

# 25. Archive classification

Archive має розрізняти:

```text
COMPLETE
INCOMPLETE
FAILED
MISSED
RUNNING
STALE
```

`COMPLETE` визначається generation/manifest contract.

---

# 26. Recovery integration

Майбутній Recovery coordinator повинен отримувати факти від Health/state layer.

Приклад:

```text
Health:
No recent COMPLETE generation

Recovery decision:
NeedNewLocalBackup
```

або:

```text
Health:
Local COMPLETE
SFTP BLOG missing

Recovery decision:
NeedRemoteRecovery
```

Health не виконує recovery action сам.

---

# 27. Recommended scheduler model

Орієнтовно:

```text
BRAVO_HEALTH_FAST
every 30 minutes

BRAVO_HEALTH_DEEP
every 4 hours

BRAVO_HEALTH_DAILY_SUMMARY
once per day
```

Або один `BRAVO_HEALTH` із mode:

```text
-Fast
-Deep
-DailySummary
```

Точна архітектура має бути визначена під час реалізації.

Бажано уникнути дублювання логіки між трьома окремими скриптами.

---

# 28. Config candidates

Майбутні параметри можуть виглядати концептуально так:

```text
Health.FastIntervalMinutes = 30
Health.DeepIntervalHours = 4

Health.ArchiveGraceMinutes = 60
Health.MaintenanceGraceMinutes = 60

Health.WarningReminderHours = 0
Health.CriticalReminderHours = 4

Health.DailySummaryEnabled = true
Health.DailySummaryAt = 08:00
```

Назви лише концептуальні.

Не додавати в поточний `BRAVO.config` без окремого schema/compatibility рішення.

---

# 29. State persistence

Потрібний durable state file.

Він не повинен містити секрети.

Приклад conceptual state:

```json
{
  "lastRun": "2026-08-11T02:00:00+03:00",
  "globalState": "WARNING",
  "activeProblems": [
    "RangeIdMissing"
  ],
  "lastNotification": "2026-08-11T00:00:00+03:00",
  "lastCompleteGeneration": "20260810_224224"
}
```

State write має бути atomic:

```text
write temp
flush/close
replace final
```

щоб hard power loss не залишив пошкоджений state як єдине джерело істини.

---

# 30. Health state не є source of truth для backup

Persisted Health state — cache/observability state.

Source of truth для backup:

```text
generation manifest
archive verification
remote verification
```

Якщо Health state втрачено або пошкоджено, наступний Health повинен відновити фактичний стан із первинних даних.

---

# 31. Exit codes

Fast/Deep Health повинні використовувати canonical BRAVO ExitCodes.

Орієнтовна класифікація:

```text
0   Healthy
10  Warning
failure codes according to existing contract
```

Не створювати нові числові коди без окремої потреби.

Notification suppression не повинна змінювати actual Health exit code.

---

# 32. Logging

Кожний Health run повинен мати compact structured log.

Fast Health:

```text
[INFO] System OK
[SUCCESS] BRAVO Running
[SUCCESS] exchangAPI Running
[SUCCESS] Archive schedule current
[SUCCESS] Last COMPLETE generation ...
[WARNING] Range ID log missing
[SUCCESS] SFTP current
[RESULT] WARNING
```

Не створювати separator-only noise records.

---

# 33. Operator-facing summary

Fast Health console/manual summary повинен бути компактним.

Приклад:

```text
BRAVO HEALTH

Статус: WARNING

Система
OK

Служби
BRAVO       OK
exchangAPI  OK

Регламент
Archive      OK
Maintenance  WARNING

Backup
Generation   20260810_224224
Age          3 год. 21 хв.
Local        OK
SFTP         OK
BAZA_APP     OK

Проблеми
Range ID log відсутній
```

---

# 34. Не робити

У першій реалізації не потрібно:

- робити Health автоматичним Archive coordinator;
- запускати full backup прямо з Health;
- запускати Maintenance з Health;
- дублювати Recovery logic;
- виконувати SHA512 всіх великих archives кожні 30 хвилин;
- надсилати full report кожні 30 хвилин;
- трактувати будь-який `LastTaskResult != 0` як failure;
- трактувати `exit 10` як missed job;
- створювати warning для disabled optional component;
- залежати лише від persisted Health state.

---

# 35. Acceptance tests

## TEST 1 — Healthy repeated run

1. Усі служби працюють.
2. Backup current.
3. SFTP current.
4. Fast Health запускати двічі.

Очікується:

```text
HEALTHY -> HEALTHY
друге notification не надсилається
```

---

## TEST 2 — Service failure

1. Зупинити required BRAVO service.
2. Запустити Health.

Очікується:

```text
CRITICAL
notification sent
```

Наступний Fast Health при тому самому стані:

```text
CRITICAL
duplicate notification suppressed
```

Після service recovery:

```text
CRITICAL -> HEALTHY
recovery notification sent
```

---

## TEST 3 — Missing Range ID

Очікується:

```text
WARNING
```

Не:

```text
CRITICAL
```

Повторні Health runs не спамлять однаковий warning.

---

## TEST 4 — Missed Archive

Імітувати ситуацію, коли expected Archive window уже минув, але свіжої COMPLETE generation немає.

Очікується:

```text
CRITICAL
Archive missed
```

---

## TEST 5 — Archive running

Під час active Archive і після scheduled time:

```text
RUNNING
```

Не:

```text
MISSED
```

---

## TEST 6 — Maintenance SuccessWithWarnings

`LastTaskResult = 10`.

Очікується:

```text
Maintenance = WARNING / SuccessWithWarnings
```

Не:

```text
Missed
Failed
```

---

## TEST 7 — Local COMPLETE, SFTP failed

Очікується:

```text
Local = OK
SFTP = WARNING/CRITICAL according to policy
Global = WARNING or CRITICAL
```

Не називати local backup failed.

---

## TEST 8 — Backup stale

Штучно перевищити configured backup-age threshold.

Очікується:

```text
WARNING
```

після critical threshold:

```text
CRITICAL
```

---

## TEST 9 — New problem while same global state

Було:

```text
WARNING: RangeIdMissing
```

Стало:

```text
WARNING: RangeIdMissing + SFTPStale
```

Нова проблема повинна бути помічена навіть якщо global state не змінився.

---

## TEST 10 — Deep Health

Перевірити:

- SHA512;
- archive integrity;
- SFTP verification.

Fast Health між Deep runs не повинен повторювати ці expensive checks без причини.

---

## TEST 11 — Daily Summary

Повинен надсилатися один summary за configured schedule.

Не залежати від того, чи були state-change notifications протягом дня.

---

## TEST 12 — Health state corruption

Пошкодити/видалити persisted Health state.

Наступний Health:

- не падає;
- перебудовує фактичний state;
- не вважає backup valid лише через старий cache;
- створює новий valid state atomically.

---

# 36. Definition of Done

Майбутня реалізація вважається готовою, якщо:

- [ ] Fast Health працює кожні 30 хвилин;
- [ ] Fast Health є lightweight;
- [ ] Deep Health виконується окремо;
- [ ] services контролюються;
- [ ] missed Archive визначається;
- [ ] missed Maintenance визначається;
- [ ] running task не класифікується як missed;
- [ ] latest COMPLETE generation визначається коректно;
- [ ] backup age контролюється;
- [ ] local і remote state розділені;
- [ ] BAZA state контролюється окремо;
- [ ] `SuccessWithWarnings` не вважається failure/missed;
- [ ] global state = HEALTHY/WARNING/CRITICAL;
- [ ] state transitions persisted;
- [ ] duplicate notifications suppressed;
- [ ] recovery notifications працюють;
- [ ] problem fingerprint підтримується;
- [ ] optional reminders configurable;
- [ ] daily summary працює;
- [ ] Health не запускає Archive сам;
- [ ] Health інтегрується з майбутнім Recovery як detection/state layer;
- [ ] corrupted Health state recoverable;
- [ ] notification failure не змінює фактичний Health result.

---

# 37. Рекомендована архітектурна модель

```text
                    ┌─────────────────────┐
                    │   Scheduled Tasks   │
                    └──────────┬──────────┘
                               │
                               ▼
┌─────────────┐       ┌─────────────────────┐
│  Services   │──────▶│                     │
└─────────────┘       │   BRAVO HEALTH      │
                      │   State Evaluator   │
┌─────────────┐       │                     │
│  Manifests  │──────▶│ HEALTHY/WARN/CRIT   │
└─────────────┘       └──────────┬──────────┘
                                 │
┌─────────────┐                  ├──────────────▶ Notifications
│ SFTP / SMB  │──────────────────┤
└─────────────┘                  │
                                 ▼
                      Persisted Health State
                                 │
                                 ▼
                         Future Recovery
                                 │
                                 ▼
                 Archive / Remote / BAZA action
```

---

# 38. Короткий принцип

> `BRAVO_HEALTH` повинен часто й дешево визначати фактичний стан системи, сервісів, регламентних робіт та резервних копій.  
> Повідомлення надсилаються за зміною стану, а не на кожному запуску.  
> Дорогі integrity-перевірки виконуються Deep Health окремо.  
> Health виявляє проблему, Recovery вирішує що робити, Archive виконує резервне копіювання.
