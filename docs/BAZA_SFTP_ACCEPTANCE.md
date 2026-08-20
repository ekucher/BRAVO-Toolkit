# BAZA SFTP Acceptance — операторський runbook

**Мета:** підтвердити на реальному сервері з живим WinSCP/SFTP, що інкрементальний
append-only двигун (`BRAVO.BazaSync`) поводиться в 10 критичних сценаріях
так само, як у синтетичному self-test (`BRAVO_SELF_TEST.ps1` — PASS).
Прогін виконується **до** merge `developer → master`; за результатами
ухвалюється рішення про реліз.

Цей runbook — багаторазова процедура: він не прив'язаний до конкретного
SHA і не застаріває після кожного release stamp. Конкретний SHA
розгорнутого комплекту фіксується оператором на кожному прогоні окремо
(крок 0.1) і в протоколі (розділ 12), а не в тексті інструкції.
Запис про вже завершений прогін — розділ «Acceptance record» нижче.

**Компонент прогону:** `BAZA_APP` (для `BAZA_WWW` семантика ідентична —
окремий прогін не обов'язковий).

---

## 0. Передумови і правила безпеки

1. **Розгорнутий комплект відповідає поточному `VERSION.json`.** Джерело
   істини — файл `VERSION.json` самого розгорнутого комплекту, а не
   значення, зашиті в цей runbook. Перед прогоном оператор фіксує:
   - `packageVersion`;
   - `buildId`;
   - `sourceCommit`.
   `BRAVO_RUNTIME_GUARD.ps1` повинен пройти без помилок (підтверджує, що
   комплект не пошкоджено і відповідає `RUNTIME_MANIFEST.json`). Acceptance
   виконується на цьому конкретно зафіксованому bundle — занотуйте
   `buildId`/`sourceCommit` у протоколі (розділ 12), щоб прогін був
   відтворюваним і прив'язаним до перевіреного коду.
2. **Режим:** `backupMonitoring.SFTP.BAZA.Mode = "IncrementalAppendOnly"`
   (типовий). Перевіряється кроком 0.1 нижче.
3. **На час прогону вимкніть планові завдання** BRAVO у Task Scheduler
   (Backup / Health / BAZASync) — кожен цикл запускається вручну і не
   повинен перетинатися з плановим. Після прогону — увімкнути назад.
4. **НЕ використовуйте `BRAVO_ARCHIV.ps1 -SyncBAZA`** під час acceptance:
   це окремий **legacy**-шлях (повний WinSCP `synchronize`), який іде повз
   двигун, що тестується, не оновлює його state і «вилікує» навмисно
   створені drift-фікстури, зіпсувавши сценарії 5–9.
5. **Двигун ніколи не видаляє remote-дані.** Усі тестові файли, залиті на
   SFTP, наприкінці прибираються **вручну** через WinSCP (розділ 11).
6. Тестові файли кладемо в окремий підкаталог `TESTACC\` всередині
   каталогу-джерела BAZA_APP — вони стануть частиною реального дерева
   BAZA на час прогону; це очікувано.
7. Перед будь-яким редагуванням файлу стану — **резервна копія** (команди
   в сценаріях уже містять `Copy-Item`).

### 0.1. Зібрати фактичні шляхи

```powershell
.\BRAVO_DRY_RUN.ps1
```

Із секції `BAZA sync` звіту випишіть:

- **режим** (має бути `IncrementalAppendOnly`; якщо ні — acceptance не
  має сенсу, зупиніться);
- **шлях файлу стану** BAZA_APP — далі `<STATE>` (типово
  `%ProgramData%\BRAVO\State\BAZA\BAZA_APP.state.json`);
- дату останнього успішного циклу / останнього Full Audit (для
  сценарію 1 стан має бути **відсутній** — перший запуск двигуна).

Із `BRAVO.config` (або з логів) випишіть:

- каталог-джерело BAZA_APP — далі `<SRC>`;
- SFTP-каталог BAZA — далі `<REMOTE>` (його ж видно у лог-рядках аудиту).

Зручні змінні для сесії PowerShell (запускати з кореня комплекту, від
адміністратора):

```powershell
$state = '<STATE>'   # напр. C:\ProgramData\BRAVO\State\BAZA\BAZA_APP.state.json
$src   = '<SRC>'     # каталог-джерело BAZA_APP
```

### 0.2. Де дивитись результат кожного циклу

- **Лог** (`LOGS\`, файл поточного запуску Archive/Health):
  - успішний цикл: рядок виду
    `BAZA APP: cycle <CycleId> — передано N, вже підтверджено M, помилок 0` (SUCCESS);
  - будь-який не-COMPLETE: рядок виду
    `Каталог BAZA APP не вдалося синхронiзувати з SFTP (incremental): <STATUS>` (WARNING)
    — `<STATUS>` і є статусом циклу (INCOMPLETE / AUDIT_DRIFT /
    REMOTE_CONFLICT / RECONCILIATION_REQUIRED / …);
  - Full Audit: рядки `Аудит BAZA_APP …` з переліком pending-файлів і
    причин (`UploadNew` / `UploadUpdate`).
- **Health-повідомлення** (вбудований health Archive або
  `BRAVO_HEALTH.ps1`): точні CRITICAL/WARNING-тексти Fast Health зі
  шляхами й розмірами.
- **Стан**: `BRAVO_DRY_RUN.ps1` (останній цикл/аудит, читабельність) або
  прямий перегляд:

```powershell
(Get-Content $state -Raw -Encoding UTF8 | ConvertFrom-Json) |
    Select-Object LastCycleId, LastSuccessfulSyncUtc, LastFullAuditUtc, AuditReconciliationPending
```

### 0.3. Допоміжні прийоми (використовуються в сценаріях)

**Заблокувати збереження стану** (модель збою запису — `[IO.File]::Replace`
вимагає write-доступу до цілі):

```powershell
Set-ItemProperty -Path $state -Name IsReadOnly -Value $true   # увімкнути
Set-ItemProperty -Path $state -Name IsReadOnly -Value $false  # зняти
```

**Форсувати періодичний Full Audit** (CLI-перемикача немає — легітимний
важіль: відсутній/скинутий `LastFullAuditUtc` трактується двигуном як
«прострочено», див. OPERATIONS):

```powershell
Copy-Item $state "$state.acceptance-backup" -Force
$j = Get-Content $state -Raw -Encoding UTF8 | ConvertFrom-Json
$j.LastFullAuditUtc = $null
[IO.File]::WriteAllText($state, ($j | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
```

**Змоделювати перерваний trust-перехід** (crash між аудитом і фінальним
збереженням):

```powershell
Copy-Item $state "$state.acceptance-backup2" -Force
$j = Get-Content $state -Raw -Encoding UTF8 | ConvertFrom-Json
$j.AuditReconciliationPending = $true
[IO.File]::WriteAllText($state, ($j | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
```

---

## Сценарії

Запуск циклу всюди означає: `.\BRAVO_ARCHIV.ps1 -NoPause` (повний прогін
Archive; BAZA-фаза — його частина). Standalone Health: `.\BRAVO_HEALTH.ps1`.

### 1. Перший bootstrap на великому наявному BAZA

**Передумова:** `<STATE>` не існує (двигун ще жодного разу не запускався).

**Дії:** запустити цикл.

**Очікується:** один Full Audit (повне порівняння — це найдовша фаза
прогону, одноразова); вже наявні на SFTP файли сідяться `Verified` без
повторної передачі; передаються лише реально відсутні на SFTP.

**PASS:** SUCCESS-рядок з `передано N`, де N ≈ кількість файлів, яких
справді бракувало на SFTP (не розмір усього дерева!); `<STATE>` створено;
вибіркова перевірка у WinSCP: mtime кількох старих файлів на SFTP **не**
змінився (їх не перезаливали).

### 2. Повторний цикл без змін → 0 передач

**Дії:** одразу запустити цикл ще раз.

**PASS:** `передано 0, вже підтверджено M` (M ≈ увесь обсяг дерева);
BAZA-фаза триває значно менше за bootstrap (немає повного порівняння —
це і є перевірка «без CompareDirectories у звичайному циклі»).

### 3. +10 нових файлів → рівно 10 передач

**Дії:**

```powershell
New-Item -ItemType Directory -Path (Join-Path $src 'TESTACC') -Force | Out-Null
1..10 | ForEach-Object { [IO.File]::WriteAllBytes((Join-Path $src "TESTACC\acc_new_$_.bin"), (New-Object byte[] 4096)) }
```

Запустити цикл.

**PASS:** `передано 10`; усі 10 з'явились у `<REMOTE>/TESTACC/` на SFTP;
третій запуск поспіль знову дає `передано 0`.

### 4. Збій збереження стану після успішної передачі → без повторної передачі

**Дії:**

```powershell
[IO.File]::WriteAllBytes((Join-Path $src 'TESTACC\acc_crash.bin'), (New-Object byte[] 8192))
Set-ItemProperty -Path $state -Name IsReadOnly -Value $true
```

Запустити цикл → очікується WARNING `(incremental): INCOMPLETE` і текст
про неможливість зберегти стан (файл при цьому **залито** на SFTP —
перевірте у WinSCP, запам'ятайте його mtime).

```powershell
Set-ItemProperty -Path $state -Name IsReadOnly -Value $false
```

Запустити цикл ще раз.

**PASS:** другий цикл — SUCCESS з `передано 0` (файл визнано вже
наявним за збігом розміру, без блокера це дозволено); mtime
`acc_crash.bin` на SFTP **не змінився** (повторної передачі/перезапису
не було); у `<STATE>` файл тепер `Verified: true`.

### 5. Same-size drift + примусовий Full Audit → AUDIT_DRIFT

**Дії:**

1. Оберіть drift-файл: `TESTACC\acc_new_1.bin` (уже Verified).
2. У WinSCP змініть **лише mtime** відповідного remote-файлу
   (Properties → timestamp), або перезалийте вручну файл того самого
   розміру — розмір мусить збігтися, час — розійтись.
3. Форсуйте audit (прийом 0.3, `LastFullAuditUtc = $null`).
4. Запустіть цикл.

**Очікується:** audit рапортує `UploadUpdate` для файлу; статус циклу —
`AUDIT_DRIFT`; Health CRITICAL з шляхом, `[UploadUpdate]` і обома
розмірами.

**PASS:** WARNING `(incremental): AUDIT_DRIFT`; файл на SFTP **не
перезаписано** (mtime — той, що ви виставили в п.2); у `<STATE>` запис
файлу має `"BlockReason": "AuditDrift"`; `LastSuccessfulSyncUtc` **не**
просунувся (порівняйте з видрукуваним у 0.2 значенням до сценарію).

### 6. Наступний звичайний цикл (без audit) → досі AUDIT_DRIFT

**Дії:** запустити цикл, нічого не змінюючи.

**PASS:** знову `AUDIT_DRIFT` (блокер персистентний, а не «на один
цикл»); передач — нуль; `LastSuccessfulSyncUtc` не змінився.

### 7. Видалення локального заблокованого файлу → досі CRITICAL

**Дії:**

```powershell
Remove-Item (Join-Path $src 'TESTACC\acc_new_1.bin') -Force
```

Запустити цикл.

**PASS:** статус `AUDIT_DRIFT`, health-повідомлення містить точний шлях
і позначку про **відсутнє локальне джерело**; цикл не COMPLETE
(зникнення джерела — не розв'язка).

### 7R. Розв'язка drift (обов'язково перед сценаріями 8–9)

Блокер знімається лише позитивною розв'язкою. Найпростіший шлях тут:

1. У WinSCP **видаліть** remote `…/TESTACC/acc_new_1.bin`.
2. Поверніть локальний файл:

```powershell
[IO.File]::WriteAllBytes((Join-Path $src 'TESTACC\acc_new_1.bin'), (New-Object byte[] 4096))
```

3. Запустіть цикл.

**PASS:** SUCCESS, `передано 1` (файл залито заново після верифікації);
у `<STATE>` запис знову `Verified: true`, **без** `BlockReason`.

> Якщо цього не зробити, блокер (за дизайном) даватиме CRITICAL вічно —
> включно з випадком, коли і локальний, і remote файли вже прибрані.
> Аварійний last-resort: прибрати запис зі `<STATE>` вручну (з резервною
> копією) — але в acceptance має спрацювати саме штатна розв'язка вище.

### 8. Перерваний trust-перехід Full Audit

**8a. Write-ahead-барʼєр: audit не стартує без збереженого маркера.**

```powershell
# знову форсувати audit (прийом 0.3), потім:
Set-ItemProperty -Path $state -Name IsReadOnly -Value $true
```

Запустити цикл → очікується статус `ERROR` з текстом про **write-ahead
маркер** і те, що **Full Audit не запускався** (у лозі немає рядків
`Аудит BAZA_APP …` цього циклу).

```powershell
Set-ItemProperty -Path $state -Name IsReadOnly -Value $false
```

**8b. Crash після аудиту (модель наслідку).** Точний момент збою між
аудитом і фінальним збереженням вручну не зловити — моделюємо його
результат на диску (прийом 0.3, `AuditReconciliationPending = $true`),
після чого:

```powershell
.\BRAVO_HEALTH.ps1
```

**PASS (8b):** standalone Health — CRITICAL `RECONCILIATION_REQUIRED`
(«потрібна повторна Full Audit реконсиляція»), **нуль** передач, старі
Verified-записи не використано для «все гаразд».

### 9. Наступний Archive → примусова реконсиляція

**Дії:** запустити цикл (`AuditReconciliationPending` досі true на диску;
`-ForceFullAudit`/редагувань більше не потрібно).

**PASS:** у лозі є повний `Аудит BAZA_APP …` (реконсиляцію форсує сам
маркер); цикл завершується COMPLETE (SUCCESS-рядок); у `<STATE>`
`"AuditReconciliationPending": false`; наступний `BRAVO_HEALTH.ps1` — OK.

### 10. Конфлікти з уже наявним remote-файлом

**10a. Same-size (крешеве відновлення):**

```powershell
[IO.File]::WriteAllBytes((Join-Path $src 'TESTACC\acc_same.bin'), (New-Object byte[] 2048))
```

У WinSCP **до** запуску циклу залийте на `…/TESTACC/acc_same.bin`
будь-який файл рівно 2048 байт. Запустіть цикл.

**PASS:** `передано 0` для цього файлу (визнано наявним), mtime remote
не змінився, у `<STATE>` — `Verified: true`.

**10b. Different-size (заборона перезапису):**

```powershell
[IO.File]::WriteAllBytes((Join-Path $src 'TESTACC\acc_diff.bin'), (New-Object byte[] 2048))
```

У WinSCP залийте на `…/TESTACC/acc_diff.bin` файл **іншого** розміру
(напр. 100 байт). Запустіть цикл.

**PASS:** WARNING `(incremental): REMOTE_CONFLICT`; Health CRITICAL з
шляхом і **обома** розмірами (local 2048 / remote 100); remote-файл **не
перезаписано**. Розв'язка: видалити remote-файл у WinSCP → наступний
цикл заливає локальний і завершується COMPLETE.

---

## 11. Прибирання після прогону

1. Переконайтесь, що **жодних активних блокерів** не лишилось: останній
   цикл — COMPLETE, `BRAVO_HEALTH.ps1` — OK (розв'язки 7R/10b виконані).
2. Видаліть локально `<SRC>\TESTACC\` цілком.
3. У WinSCP видаліть `<REMOTE>/TESTACC/` цілком (двигун цього не зробить
   ніколи — no-delete за контрактом).
4. Запустіть цикл і `BRAVO_HEALTH.ps1` — обидва мають бути зеленими
   (записи видалених тестових файлів лишаться у `<STATE>` як verified —
   це нешкідливо і нічого не коштує).
5. Видаліть `"$state.acceptance-backup*"`.
6. Увімкніть назад планові завдання BRAVO у Task Scheduler.

> Опція «повний скид»: видалити `<STATE>` — наступний Archive виконає
> bootstrap Full Audit заново (штатний шлях, але на великому дереві це
> знову найдовша фаза).

---

## 12. Протокол

| # | Сценарій | Дата/час | Статус циклу (лог) | PASS/FAIL | Нотатки |
|---|---|---|---|---|---|
| 1 | Bootstrap | | | | |
| 2 | No-change → 0 | | | | |
| 3 | +10 → 10 | | | | |
| 4 | Crash після upload | | | | |
| 5 | Same-size drift + audit | | | | |
| 6 | Sticky на звичайному циклі | | | | |
| 7 | Missing local source | | | | |
| 7R | Розв'язка drift | | | | |
| 8a | Write-ahead барʼєр | | | | |
| 8b | RECONCILIATION_REQUIRED | | | | |
| 9 | Примусова реконсиляція | | | | |
| 10a | Same-size conflict | | | | |
| 10b | Different-size conflict | | | | |

**Критерій acceptance:** усі рядки PASS. Після цього — merge
`developer → master` і стабільний реліз за RELEASE_POLICY/RELEASE_CHECKLIST.

---

## 13. Acceptance record — завершений DEV-LIMS прогін (2026-08-13)

- **Результат:** BAZA real-SFTP acceptance — **PASS**.
- **Охоплені сценарії:** 1–10b (розділ «Сценарії» вище) + фінальний
  контрольний прогін Archive/Health.
- **Фінальний stamp BAZA/Archive/Health acceptance:** `c7d247c`.
- **Останній BAZA-фікс перед завершенням:** `c4e2a40` (fifth real-SFTP
  acceptance finding — resolve `winscp.exe` у standalone-fallback wiring
  `BRAVO.Health.Runtime`; той самий клас дефекту, що й acceptance
  blocker #3).

**Важливо:** це був ітеративний процес acceptance+fix, а не єдиний
наскрізний прогін на одному SHA — під час прогону було знайдено й
виправлено 5 дефектів, тому окремі сценарії 1–10b виконувались на різних
проміжних stamp'ах у міру виправлень. Твердження «усі сценарії 1–10b
виконано на одному SHA» було б неточним і сюди навмисно не входить.
Гарантія інша й точніша: починаючи зі stamp `c7d247c` і до release
candidate runtime-код BAZA/Archive/Health **не змінювався** — тобто
фінальний перевірений стан відповідає саме цьому stamp.
