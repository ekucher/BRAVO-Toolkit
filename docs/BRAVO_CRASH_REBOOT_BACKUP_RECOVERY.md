# BRAVO — Crash/Reboot Backup Recovery

## Статус документа

**Тип:** технічна концепція / TODO для майбутньої реалізації  
**Призначення:** зафіксувати вимоги до автоматичного відновлення резервного копіювання після аварійного завершення, перезавантаження або втрати живлення.  
**Поточний runtime:** не змінюється цим документом.  
**Майбутня реалізація:** окремий функціональний реліз після стабілізації поточного observability/correctness циклу.

---

## 1. Проблема

BRAVO Archive виконує резервне копіювання декількох компонентів однієї backup generation:

- `MODEL`
- `BLOG`
- `BRAVOEXCH`
- за конфігурацією — локальні/віддалені BAZA-компоненти;
- SFTP;
- SMB/NAS;
- post-backup Health.

Для локальних archive-компонентів одна generation повинна представляти **одну point-in-time резервну копію**. Для цього всі enabled archive-компоненти мають використовувати **один VSS Snapshot Set**, створений для конкретної generation.

При аварійному вимкненні сервера, жорсткому reboot або зникненні живлення PowerShell/7-Zip/WinSCP можуть бути перервані без виконання `catch/finally`.

Можливі стани:

- частково записаний temporary `.mdz`;
- `.mdz` створений, але `.sha512` не завершений;
- частина archive-компонентів уже published, а інші ще не створені;
- локальна generation повністю створена, але SFTP/SMB передача перервана;
- BAZA sync не завершений;
- manifest залишився у незавершеному стані;
- Task Scheduler не встиг записати коректний final result.

Після наступного запуску Windows BRAVO повинен **сам визначити фактичний стан резервної копії та негайно відновити відсутню роботу**, без участі адміністратора.

---

## 2. Основна мета

Після reboot/boot сервер повинен автоматично:

1. визначити, чи попередній backup cycle завершився коректно;
2. не вважати interrupted/incomplete generation валідною;
3. не змішувати archive-компоненти з різних VSS Snapshot Set;
4. створити **нову generation**, якщо локальний backup не був завершений;
5. не створювати нові `.mdz`, якщо локальна generation вже валідна, а проблема лише у SFTP/SMB/BAZA;
6. повторити тільки необхідну remote delivery;
7. виконати Health;
8. повторювати recovery протягом обмеженого часу, якщо після boot ще не готові мережа/SFTP/диски/інші prerequisites;
9. залишатися idempotent: якщо все вже справно — нічого не переробляти.

---

## 3. Ключові інваріанти

### 3.1. One generation = one point-in-time

Одна generation не може містити archive-компоненти, створені з різних VSS Snapshot Set.

Заборонений сценарій:

```text
Generation A
MODEL       — створено до reboot зі Snapshot Set X
BLOG        — дозібрано після reboot зі Snapshot Set Y
BRAVOEXCH   — дозібрано після reboot зі Snapshot Set Y
```

Правильна поведінка:

```text
Generation A
MODEL       — можливо готовий
BLOG        — interrupted
BRAVOEXCH   — not started
STATUS      — INCOMPLETE / ABANDONED

Generation B
NEW VSS Snapshot Set
MODEL
BLOG
BRAVOEXCH
STATUS      — COMPLETE
```

### 3.2. Interrupted generation ніколи не стає COMPLETE автоматично

Сам факт наявності `.mdz` недостатній.

Для `COMPLETE` повинні бути виконані всі чинні generation invariants:

- усі required archive components присутні;
- archive integrity підтверджена;
- SHA512 підтверджена;
- manifest узгоджений;
- publish завершено;
- final generation transition виконаний штатно.

Після hard power loss незавершену generation не можна «дописувати» як COMPLETE без окремого доказового recovery-протоколу.

Для першої реалізації рекомендовано **fail-closed**:

> interrupted generation залишається incomplete/failed/abandoned; наступний backup створюється як нова generation.

### 3.3. Попередня COMPLETE generation не пошкоджується

Аварія нової generation не повинна:

- видаляти попередню COMPLETE generation;
- робити її невалідною;
- змінювати її manifest;
- змінювати її `.mdz/.sha512`.

Health повинен орієнтуватися на **останню валідну COMPLETE generation**, а не просто на найновіший файл за timestamp.

### 3.4. Remote failure не означає Local failure

Якщо локальна generation повністю валідна, але передача на SFTP/SMB перервалася, BRAVO не повинен повторно створювати MODEL/BLOG/BRAVOEXCH.

Повторюється тільки remote delivery.

---

## 4. Recovery coordinator

Для післяаварійного відновлення використовується окремий coordinator:

```text
BRAVO_RESTORE_RECOVERY
```

Він повинен залишатися **єдиним координатором missed/failed роботи після boot**.

Не рекомендується дублювати цю логіку через `StartWhenAvailable` для основного `BRAVO_ARCHIV`, оскільки це може створити одночасний запуск:

```text
missed BRAVO_ARCHIV
+
BRAVO_RESTORE_RECOVERY
```

Operation lock зменшить ризик, але orchestration повинна бути однозначною.

---

## 5. Boot flow

Рекомендований алгоритм:

```text
Windows boot
   |
   v
BRAVO_RESTORE_RECOVERY
   |
   v
Prerequisite checks
   |
   +-- runtime/config unavailable -> retry later
   +-- disks unavailable          -> retry later
   +-- operation lock busy        -> retry later
   |
   v
Inspect backup state
   |
   +-- Local COMPLETE missing/stale/incomplete?
   |       |
   |       +-- YES
   |            |
   |            v
   |         abandon previous interrupted generation
   |            |
   |            v
   |         NEW GenerationId
   |            |
   |            v
   |         NEW VSS Snapshot Set
   |            |
   |            v
   |         MODEL/BLOG/BRAVOEXCH
   |            |
   |            v
   |         SHA512 + integrity + publish
   |            |
   |            v
   |         remote delivery
   |
   +-- Local COMPLETE valid?
           |
           +-- SFTP incomplete -> retry SFTP only
           +-- SMB incomplete  -> retry SMB only
           +-- BAZA incomplete -> retry BAZA only
           +-- all OK          -> SKIPPED

                     |
                     v
                   Health
                     |
                     v
                    DONE
```

---

## 6. Класи стану, які треба розрізняти

Recovery не повинен використовувати лише `Task Scheduler LastTaskResult`.

### 6.1. NeedNewLocalBackup

Новий повний local backup потрібен, якщо виконується хоча б одна умова:

- немає достатньо свіжої COMPLETE generation;
- існує новіша generation зі статусом `STARTED`, `INCOMPLETE`, `FAILED`, `ABANDONED` або еквівалентним незавершеним станом;
- manifest не підтверджує COMPLETE;
- required archive component відсутній;
- `.sha512` відсутній або невалідний;
- 7-Zip integrity check не пройдено;
- локальний Health не підтверджує required archive components.

Результат:

```text
створити НОВУ generation
+
новий VSS Snapshot Set
+
повторно створити всі enabled archive components
```

### 6.2. NeedRemoteRecovery

Remote recovery потрібен, якщо:

- існує валідна локальна COMPLETE generation;
- але SFTP/SMB verification не завершена або не підтверджена.

Результат:

```text
НЕ створювати нові локальні .mdz
НЕ створювати нову generation
перевірити локальні .mdz + .sha512
повторити remote delivery
```

### 6.3. NeedBAZARecovery

Якщо archive generation локально/віддалено завершена, але BAZA sync не завершився:

```text
повторити тільки BAZA sync
```

Для існуючого окремого BAZA flow бажано перевикористати чинний механізм, а не дублювати його.

### 6.4. NothingToRecover

Якщо:

- latest required generation = COMPLETE;
- Local = Verified;
- SFTP = Verified;
- SMB = Verified або disabled;
- BAZA required components = current;
- Health = healthy;

Recovery завершується:

```text
SKIPPED
Причина: останній backup та remote-copy завершені
ExitCode: 0
```

---

## 7. Поведінка при конкретних аварійних сценаріях

### Scenario A — power loss під час MODEL

До аварії:

```text
MODEL       INTERRUPTED
BLOG        NOT STARTED
BRAVOEXCH   NOT STARTED
```

Після boot:

```text
old generation -> INCOMPLETE/ABANDONED
new generation -> full backup from NEW VSS Snapshot Set
```

### Scenario B — MODEL готовий, power loss під час BLOG

До аварії:

```text
MODEL       published
BLOG        INTERRUPTED
BRAVOEXCH   NOT STARTED
```

Після boot **заборонено** продовжувати стару generation з BLOG.

Потрібно:

```text
new GenerationId
new VSS Snapshot Set
MODEL again
BLOG
BRAVOEXCH
```

### Scenario C — всі local archives готові, power loss до generation COMPLETE

Навіть якщо `.mdz/.sha512` фізично присутні:

```text
generation != COMPLETE
```

Рекомендована fail-closed поведінка:

```text
old generation -> ABANDONED/INCOMPLETE
new generation -> full backup
```

Не завершувати стару generation лише за фактом наявності файлів.

### Scenario D — local COMPLETE, power loss під час SFTP

Наприклад:

```text
LOCAL:
MODEL       OK
BLOG        OK
BRAVOEXCH   OK
generation  COMPLETE

SFTP:
MODEL       OK
BLOG        partial/.filepart
BRAVOEXCH   not uploaded
```

Після boot:

```text
не архівувати MODEL/BLOG/BRAVOEXCH повторно
verify local generation
retry SFTP
Health
```

Якщо WinSCP resumesupport увімкнений — допустиме продовження/повтор transfer відповідно до чинної transfer policy.

### Scenario E — Archive/SFTP OK, BAZA sync interrupted

Після boot:

```text
retry BAZA only
```

Не створювати нову archive generation лише через BAZA sync failure.

### Scenario F — reboot після повністю успішного backup

Recovery:

```text
SKIPPED
```

Без створення зайвого backup.

### Scenario G — попередній process exit code = 10

`10 = SuccessWithWarnings` не є автоматичним сигналом для нового backup.

Наприклад:

```text
Range ID file missing -> WARNING -> exit 10
```

але backup може бути повністю валідний.

Рішення повинно базуватися на фактичному стані generation/local/remote/Health, а не на `exitCode != 0`.

---

## 8. Джерела істини для recovery decision

Порядок довіри:

1. generation/manifest state;
2. local archive component verification;
3. Health state;
4. SFTP/SMB/BAZA verification;
5. Task Scheduler result — тільки додатковий diagnostic signal.

Не використовувати:

```powershell
if ($LastTaskResult -ne 0) {
    RunFullBackup
}
```

як основну recovery policy.

---

## 9. Startup scheduling

Не запускати важкий backup «у першу мілісекунду» після boot.

Рекомендовано:

```text
Boot trigger
Initial delay: 1–2 хвилини
Retry interval: ~15 хвилин
Retry window: ~8 годин
```

Точні значення повинні бути config-driven.

Ще краще — readiness-driven запуск.

Prerequisites:

- runtime доступний;
- `BRAVO.config` доступний;
- `D:\LIMS` доступний;
- BackupRoot доступний;
- потрібні локальні диски ready;
- Credential Manager доступний;
- operation lock вільний.

Для local backup наявність Інтернету не є prerequisite.

Якщо local backup завершений, а SFTP ще недоступний:

```text
Recovery attempt 1:
Local COMPLETE
SFTP unavailable

Recovery attempt 2:
Local already valid -> do not rebuild
retry SFTP only
```

---

## 10. Interrupted generation lifecycle

Потрібно формально визначити статус незавершеної generation.

Рекомендований набір:

```text
STARTED
COMPLETE
FAILED
ABANDONED
```

Можливий варіант:

- `STARTED` — generation створена, робота триває;
- `COMPLETE` — усі required local invariants підтверджені;
- `FAILED` — runtime штатно завершив generation з помилкою;
- `ABANDONED` — на наступному boot/run знайдено стару `STARTED`, яка більше не може бути продовжена.

Hard power loss природно залишить `STARTED`.

При наступному recovery:

```text
STARTED from previous process/boot
    ->
ABANDONED
```

після доказу, що попередній процес уже не виконується.

---

## 11. Cleanup interrupted artifacts

Не видаляти залишки одразу без діагностики.

Recovery повинен:

1. визначити interrupted generation;
2. зафіксувати її статус;
3. не використовувати її як backup;
4. створити нову valid generation;
5. лише потім застосувати окрему cleanup policy.

Можливі залишки:

- temporary `.mdz`;
- temporary `.sha512`;
- published archive одного компонента incomplete generation;
- manifest;
- staging directories;
- WinSCP `.filepart`.

Cleanup повинен мати retention/grace period та не видаляти evidence до того, як recovery state зафіксований.

---

## 12. Operation lock

Recovery повинен використовувати той самий canonical operation-lock contract.

Якщо після boot уже працює:

- Archive;
- Maintenance;
- інша recovery operation;

то Recovery:

```text
LOCK BUSY
-> не запускає другий backup
-> завершується/відкладається
-> повторюється наступним trigger
```

Не дозволяти паралельний full backup.

---

## 13. Notification / observability

Після recovery потрібне чітке повідомлення.

### Full backup recovered

```text
BRAVO RECOVERY — РЕЗЕРВНУ КОПІЮ ВІДНОВЛЕНО

Причина:
попередня generation не була завершена після аварійного переривання

Стара generation:
20260811_013900 — ABANDONED

Нова generation:
20260811_020500 — COMPLETE

Local:
MODEL       OK
BLOG        OK
BRAVOEXCH   OK

SFTP:
OK

Health:
Healthy
```

### Remote-only recovered

```text
BRAVO RECOVERY — ВІДДАЛЕНУ КОПІЮ ВІДНОВЛЕНО

Local generation:
20260811_013900 — COMPLETE

Повторно створювати local archives:
не потрібно

SFTP:
успішно завершено
```

### Nothing to recover

Залежно від NotificationMode, success/no-op notification може не надсилатися, але runtime log повинен містити:

```text
Recovery: SKIPPED
Причина: остання generation та required remote copies підтверджені
```

### Recovery still pending

Якщо remote недоступний:

```text
Local backup: COMPLETE
SFTP: PENDING/FAILED
Наступна спроба: scheduler retry
```

Не називати local backup failed, якщо failed лише remote delivery.

---

## 14. Exit-code semantics

Не вводити `backup must rerun` на основі будь-якого ненульового exit code.

Орієнтовно:

- `0` — recovery не потрібен або recovery завершений;
- existing BRAVO error codes — використовуються відповідно до фактичного failure class;
- `10 SuccessWithWarnings` не означає автоматичний full backup;
- lock-busy — штатно повертається відповідно до canonical contract.

Не змінювати числовий BRAVO ExitCodes contract без окремого рішення.

---

## 15. Manifest requirements

Manifest повинен дозволяти однозначно відповісти:

- generation ID;
- status;
- start time;
- completion time;
- required components;
- component state;
- local verification;
- SFTP verification;
- SMB verification;
- BAZA state (якщо включено до manifest contract);
- Health result;
- process/run identity, якщо потрібно для abandoned detection.

Бажано мати чіткі поля:

```json
{
  "generationId": "20260811_020500",
  "status": "STARTED|COMPLETE|FAILED|ABANDONED",
  "local": {
    "verified": false
  },
  "remote": {
    "sftpVerified": false,
    "smbVerified": false
  }
}
```

Це лише концептуальний приклад. Реальна schema повинна бути сумісна з чинним MANIFESTS contract.

---

## 16. Не робити в першій реалізації

Не реалізовувати:

- продовження interrupted local generation після reboot;
- дозбирання BLOG/BRAVOEXCH до старого MODEL з нового VSS Snapshot Set;
- автоматичне переведення `STARTED -> COMPLETE` лише через наявність файлів;
- видалення попередньої COMPLETE generation;
- blind retry full backup за будь-якого `LastTaskResult != 0`;
- одночасне використання `StartWhenAvailable` та Recovery як двох незалежних coordinators;
- broad redesign Archive/Health/Maintenance;
- зміну backup retention лише заради recovery.

---

## 17. Acceptance tests

Перед stable release потрібне реальне crash-consistency тестування на VM.

### TEST 1 — power loss during MODEL

1. Запустити Archive.
2. Під час створення MODEL виконати hard power off VM.
3. Boot.
4. Перевірити interrupted generation.
5. Recovery повинен створити NEW generation.
6. Health повинен бачити тільки COMPLETE generations.

### TEST 2 — power loss between MODEL and BLOG

1. Дочекатися MODEL OK.
2. Hard power off перед/під час BLOG.
3. Boot.
4. Старий MODEL не повинен використовуватися для дозбирання старої generation.
5. Повний backup створюється заново.

### TEST 3 — power loss during BLOG

Ті самі invariants, що TEST 2.

### TEST 4 — power loss after local archives but before COMPLETE

1. Усі `.mdz/.sha512` фізично готові.
2. Hard power off до final COMPLETE transition.
3. Boot.
4. Generation не повинна автоматично стати COMPLETE.
5. Нова generation створюється fail-closed.

### TEST 5 — power loss during SFTP

1. Local generation COMPLETE.
2. Hard power off під час SFTP.
3. Boot.
4. Recovery не створює local archives повторно.
5. Повторює тільки remote delivery.
6. Health після transfer = Healthy.

### TEST 6 — power loss during BAZA sync

1. Archive + archive SFTP завершені.
2. Перервати BAZA.
3. Boot.
4. Recovery виконує тільки BAZA sync.

### TEST 7 — reboot after successful run

1. Backup повністю успішний.
2. Reboot.
3. Recovery = SKIPPED.
4. Жодного нового `.mdz`.

### TEST 8 — exit 10 without backup failure

1. Створити harmless warning, наприклад missing Range ID file.
2. Backup при цьому повністю валідний.
3. Reboot.
4. Recovery не створює new generation лише через exit 10.

### TEST 9 — network unavailable after boot

1. Local recovery потрібен.
2. Boot без Інтернету.
3. Local full backup створюється.
4. SFTP залишається pending.
5. Наступний retry після появи мережі виконує SFTP only.

### TEST 10 — operation lock busy

1. На boot уже виконується інша BRAVO operation.
2. Recovery не запускає concurrent backup.
3. Наступна scheduler retry виконує recovery після звільнення lock.

---

## 18. Definition of Done

Функція вважається реалізованою лише якщо доведено:

- [ ] partial temporary `.mdz` не стає final valid archive;
- [ ] interrupted generation не стає latest COMPLETE;
- [ ] Health ігнорує interrupted generation як valid point-in-time backup;
- [ ] reboot після interrupted local backup створює NEW generation;
- [ ] new generation використовує NEW VSS Snapshot Set;
- [ ] стару generation не дозбирають з нового snapshot;
- [ ] valid local COMPLETE не перебудовується через remote-only failure;
- [ ] SFTP failure після local COMPLETE запускає SFTP retry only;
- [ ] BAZA failure запускає BAZA retry only;
- [ ] exit 10 без backup failure не запускає full backup;
- [ ] operation lock виключає паралельні backup operations;
- [ ] interrupted artifacts мають контрольований lifecycle/cleanup;
- [ ] recovery idempotent;
- [ ] реальні hard-power-off acceptance tests пройдені.

---

## 19. Рекомендований майбутній scope

Окремий функціональний release:

**Crash/Reboot Backup Recovery**

Основні компоненти:

1. state inspection;
2. interrupted generation detection;
3. `STARTED -> ABANDONED` reconciliation;
4. local full-backup recovery;
5. remote-only recovery;
6. BAZA-only recovery;
7. boot retry orchestration;
8. recovery logging/notification;
9. crash-consistency acceptance suite.

Не змішувати цю функцію з observability-only release.

---

## 20. Короткий принцип

> **Після аварії BRAVO не продовжує незавершену point-in-time generation.  
> Якщо local backup не завершений — створюється нова generation з новим VSS Snapshot Set.  
> Якщо local generation вже валідна, але не завершена лише remote delivery — повторюється тільки передача.  
> Рішення приймається за фактичним станом backup/manifest/Health, а не лише за Task Scheduler exit code.**
