# BRAVO-Toolkit 5.3 — виконувана Windows acceptance-матриця (Wave E, issue #216)

Дата складання: 2026-09-25.
Автор: Agent E (issue-216-wave-e-acceptance), worktree
`E:\GitHub\BRAVO-Toolkit-216-e-acceptance`, база `origin/developer` @ `3e9e172`.

## Призначення й межі документа

CI цього репозиторію виконується на Ubuntu-раннерах і **не покриває**
Windows-специфічну поведінку: VSS/`diskshadow.exe`, Task Scheduler,
Credential Manager, service lifecycle, boot-послідовність. Цей документ —
виконувана матриця real-server acceptance для 5.3 (Config V2 cutover,
issue #216) і для нової фічі BSYSTEM Operations (PR #225,
`feat/operations-protocol-v2`, ще НЕ змерджено в `developer`).

**Явне попередження.** Жодна клітинка цієї матриці не декларується `PASS`
на основі CI, мок-даних чи здогадки. `PASS` означає, що перевірку
фактично виконано на реальному хості з реальним доказом (команда +
вивід). Усе інше — `NOT RUN` з точною командою, очікуваним результатом і
шляхом evidence для оператора, який має доступ до відповідного хоста.

## Джерело істини щодо support tiers

Задокументовано в `README.md` (розділ «Підтримувані версії Windows»,
рядки 60-94) і реалізовано канонічно в
`modules\BRAVO.Compatibility\BRAVO.Compatibility.psm1`
(`Get-BRAVOOSSupportTier`, підтверджено читанням коду, рядки 671-696):

| Tier | Системи | Джерело |
|---|---|---|
| **Supported** | Windows Server 2019+ (build ≥ 17763), Windows 10/11 (клієнтські, будь-який build), PowerShell 5.1 | README.md:64, BRAVO.Compatibility.psm1:676-681 |
| **Legacy best-effort** | Windows Server 2012 R2 (6.3), Windows Server 2016 і ранішні білди гілки 10.0 на Server (build < 17763) — без гарантій, лише попередження | README.md:65, BRAVO.Compatibility.psm1:674-679 |
| **Unsupported** | Windows 7, Windows Server 2008 R2, PowerShell 3.0 — production-запуск блокується (exit `30`), потребує `BRAVO_ALLOW_UNSUPPORTED_OS=1` для свідомого обходу | README.md:66, BRAVO.Compatibility.psm1:672-673, 702-710 |

Важливо: код визначає tier **не по конкретному номеру білда Windows
10/11**, а по тому, `ProductType` (сервер/клієнт). Будь-яка клієнтська
Windows 10/11 — завжди `Supported`, незалежно від білда. Це узгоджується
з відомим застереженням README про `diskshadow.exe` (окрема, незалежна
від tier проблема — стосується лише багатотомних джерел архіву).

Розбіжностей між README, ROADMAP.md і фактичним кодом `BRAVO.Compatibility`
**не знайдено** — документація узгоджена з реалізацією. Правок
документації в цій хвилі не було.

## Що реально доступно в цьому середовищі

Агент має доступ лише до **однієї** реальної Windows-машини — поточного
робочого хоста, на якому виконується ця сесія:

```
Caption      : Майкрософт Windows 11 Pro
Version      : 10.0.26200
BuildNumber  : 26200
ProductType  : 1 (Workstation)
PSVersion    : 5.1.26100.9444
```

Немає доступу до Windows Server 2012 R2, 2016, 2019, 2022 чи Windows 10
хостів. Немає доступу до продакшн `BRAVO.config`/LIMS-даних (MODEL/BLOG/
BRAVOEXCH) на цій машині — це чиста dev-робоча станція, не розгорнутий
BRAVO-хост. Це обмежує, які перевірки можна виконати реально, а не лише
теоретично.

---

## Acceptance-матриця

Позначення: **PASS** (виконано реально, доказ нижче) · **FAIL** (виконано
реально, провалилось) · **NOT RUN** (немає доступу до хоста/даних;
команда й очікуваний результат для оператора).

Evidence root за замовчуванням для всіх `NOT RUN`-команд:
`C:\BRAVO-ACCEPTANCE\<platform>\<check>\` (створити перед запуском,
оператор обирає реальний шлях на своєму хості).

### Windows Server 2012 R2 (Legacy best-effort)

| Перевірка | Статус | Деталі |
|---|---|---|
| VSS single-volume | NOT RUN | Немає хоста. Команда: `.\BRAVO_DRY_RUN.ps1 -ConfigPath <path> -SkipCredentials -ResultPath C:\BRAVO-ACCEPTANCE\win2012r2\vss-single\result.json`. Очікування: `[WARN] LegacyBestEffort`-попередження про tier, але VSS-preflight `[OK]` для одного тому. |
| VSS multi-volume | NOT RUN | Команда: та сама, з MODEL/BLOG/BRAVOEXCH на різних томах. Очікування: `diskshadow.exe` штатно присутній на Server-редакціях — preflight має пройти `[OK]`, якщо джерела на різних томах. |
| `diskshadow.exe` наявність | NOT RUN | Команда: `Test-Path "$env:SystemRoot\System32\diskshadow.exe"`. Очікування: `True` (Server-редакції гарантовано мають цей компонент — README.md:69). |
| Task Scheduler реєстрація/виконання | NOT RUN | Команда: `.\BRAVO_TASKS_INSTALL.ps1 -ValidateOnly` потім `.\BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess`. Evidence: `C:\BRAVO-ACCEPTANCE\win2012r2\scheduler\`. |
| Heartbeat entrypoint (`BRAVO_OPERATIONS_HEARTBEAT.ps1`) | NOT RUN | Існує лише на гілці PR #225 (`feat/operations-protocol-v2`), не в `developer`. Команда після merge: `.\BRAVO_OPERATIONS_HEARTBEAT.ps1 -NoPause`. Очікування: heartbeat-подія без throw, навіть при `LegacyBestEffort` tier. |
| Credential Manager write/read | NOT RUN | Команда: PowerShell-сесія з `Import-Module .\modules\BRAVO.Credentials\BRAVO.Credentials.psd1; Set-BRAVOCredential ...; Get-BRAVOCredential ...`. Windows Server 2012 R2 має вбудований CredMan — очікується PASS, як на клієнтських системах. |
| Operations bootstrap credential | NOT RUN | Застосовно лише після merge PR #225. Команда: перевірити канонічний target Operations bootstrap-секрету (`8b3bb9a`). |
| Restore drill (реальний) | NOT RUN | Команда: `.\BRAVO_RESTORE_TEST.ps1 -Component All`. Потребує реальних MODEL/BLOG/BRAVOEXCH generations на хості. |
| Update/rollback 5.2→5.3 | NOT RUN | Auto-update ще не реалізовано (ROADMAP.md: «auto-update до появи atomic rollback і перевіреного release artifact»). Застосовний шлях — config-міграція, див. `docs/BRAVO_42_TO_524_MIGRATION_20260913.md`; для 5.3/Config V2 — `docs/BRAVO_CONFIG_V2_PILOT_MIGRATION_RUNBOOK_20260916.md`. Команда: виконати міграційний runbook на копії продакшн-конфігурації. |
| Operations API недоступний (fail-closed/degrade) | NOT RUN | Застосовно після merge PR #225. Контракт (`BRAVO.Operations.psm1:13-21`): усі публічні функції never-throw при мережевих/HTTP-збоях, події йдуть у durable outbox. Команда: заблокувати вихідний HTTPS до Operations API (firewall rule) і запустити `BRAVO_HEALTH.ps1`/`BRAVO_ARCHIV.ps1` — очікується, що основна операція завершується нормально (exit-код операції не змінюється через недоступність Operations), а подія лягає в `Outbox`. |

### Windows Server 2016 (Legacy best-effort, якщо build < 17763)

Ідентична структура до 2012 R2 — усе **NOT RUN**, немає хоста. Той самий
набір команд і очікувань. Нюанс: якщо конкретний білд Server 2016 ≥ 17763
(нетиповий кейс для 2016, але код перевіряє саме build, а не назву
редакції), tier фактично стане `Supported`, а не `LegacyBestEffort` —
оператор має зафіксувати фактичний `Get-BRAVOOSSupportTier`-вивід перед
інтерпретацією решти матриці для цього хоста.

| Перевірка | Статус | Деталі |
|---|---|---|
| VSS single-volume | NOT RUN | Те саме, evidence `C:\BRAVO-ACCEPTANCE\win2016\vss-single\`. |
| VSS multi-volume | NOT RUN | Те саме, evidence `C:\BRAVO-ACCEPTANCE\win2016\vss-multi\`. |
| `diskshadow.exe` наявність | NOT RUN | Очікування: `True` (Server-редакція). |
| Task Scheduler | NOT RUN | Evidence `C:\BRAVO-ACCEPTANCE\win2016\scheduler\`. |
| Heartbeat entrypoint | NOT RUN | Після merge PR #225. |
| Credential Manager | NOT RUN | Очікування PASS. |
| Operations bootstrap credential | NOT RUN | Після merge PR #225. |
| Restore drill | NOT RUN | Потребує реальних generations. |
| Update/rollback 5.2→5.3 | NOT RUN | Той самий runbook, що й 2012 R2. |
| Operations API недоступний | NOT RUN | Після merge PR #225, той самий сценарій. |

### Windows Server 2019 (Supported)

| Перевірка | Статус | Деталі |
|---|---|---|
| VSS single-volume | NOT RUN | Команда/очікування як вище. Evidence `C:\BRAVO-ACCEPTANCE\win2019\vss-single\`. Referencing acceptance-скрипт `ci/acceptance/Test-BRAVOVSSSingleVolumeAcceptance.ps1` — запускається на реальному сервері з фактичними MODEL/BLOG/BRAVOEXCH на одному томі. |
| VSS multi-volume | NOT RUN | `diskshadow.exe` штатний на Server 2019 — очікується `[OK]`. |
| `diskshadow.exe` наявність | NOT RUN | Очікування: `True`. |
| Task Scheduler | NOT RUN | Evidence `C:\BRAVO-ACCEPTANCE\win2019\scheduler\`. |
| Heartbeat entrypoint | NOT RUN | Після merge PR #225. |
| Credential Manager | NOT RUN | Очікування PASS. |
| Operations bootstrap credential | NOT RUN | Після merge PR #225. |
| Restore drill | NOT RUN | `.\BRAVO_RESTORE_TEST.ps1`, потребує реальних generations. |
| Update/rollback 5.2→5.3 | NOT RUN | Config V2 pilot migration runbook. |
| Operations API недоступний | NOT RUN | Після merge PR #225. |

### Windows Server 2022 (Supported)

Структурно ідентична до 2019 — усе **NOT RUN**, немає хоста.

| Перевірка | Статус | Деталі |
|---|---|---|
| VSS single-volume | NOT RUN | Evidence `C:\BRAVO-ACCEPTANCE\win2022\vss-single\`. |
| VSS multi-volume | NOT RUN | Evidence `C:\BRAVO-ACCEPTANCE\win2022\vss-multi\`. |
| `diskshadow.exe` наявність | NOT RUN | Очікування: `True`. |
| Task Scheduler | NOT RUN | Evidence `C:\BRAVO-ACCEPTANCE\win2022\scheduler\`. |
| Heartbeat entrypoint | NOT RUN | Після merge PR #225. |
| Credential Manager | NOT RUN | Очікування PASS. |
| Operations bootstrap credential | NOT RUN | Після merge PR #225. |
| Restore drill | NOT RUN | Потребує реальних generations. |
| Update/rollback 5.2→5.3 | NOT RUN | Той самий runbook. |
| Operations API недоступний | NOT RUN | Після merge PR #225. |

### Windows 10 (Supported, клієнт)

| Перевірка | Статус | Деталі |
|---|---|---|
| VSS single-volume | NOT RUN | Немає хоста Windows 10 (є лише Windows 11). Команда/очікування як для інших Supported-платформ. |
| VSS multi-volume | NOT RUN | **Відомий ґап** (README.md:68-84): `diskshadow.exe` не гарантований на клієнтських Windows 10/11 — підтверджено відсутнім на кількох build 19045/22H2 Pro-машинах. Якщо відсутній, `BRAVO_DRY_RUN.ps1`/`BRAVO_SETUP.ps1` fail-closed зупиняються на `[FAIL] VSS` для багатотомних джерел — це навмисна поведінка, не дефект. Очікуваний результат залежить від фактичної наявності `diskshadow.exe` на конкретній машині. |
| `diskshadow.exe` наявність | NOT RUN | Команда: `Test-Path "$env:SystemRoot\System32\diskshadow.exe"`. Очікування: **не гарантовано** — задокументований ґап, потребує перевірки на кожній конкретній машині. |
| Task Scheduler | NOT RUN | Evidence `C:\BRAVO-ACCEPTANCE\win10\scheduler\`. |
| Heartbeat entrypoint | NOT RUN | Після merge PR #225. |
| Credential Manager | NOT RUN | Очікування PASS (той самий CredMan API, що на Windows 11 — підтверджено реально нижче). |
| Operations bootstrap credential | NOT RUN | Після merge PR #225. |
| Restore drill | NOT RUN | Потребує реальних generations. |
| Update/rollback 5.2→5.3 | NOT RUN | Той самий runbook. |
| Operations API недоступний | NOT RUN | Після merge PR #225. |

### Windows 11 (Supported, клієнт) — реальна машина цієї сесії

| Перевірка | Статус | Деталі |
|---|---|---|
| VSS single-volume | NOT RUN | На цій машині немає розгорнутого BRAVO (немає `BRAVO.config` із реальними MODEL/BLOG/BRAVOEXCH) — запуск `BRAVO_DRY_RUN.ps1` без production-даних дав би оманливий результат, не справжній acceptance-доказ. Команда для оператора на реальному BRAVO-хості: `.\ci\acceptance\Test-BRAVOVSSSingleVolumeAcceptance.ps1`. Evidence: `%TEMP%\BRAVO_VSS_ACCEPTANCE_*.json` + консольний вивід. |
| VSS multi-volume | NOT RUN | Та сама причина відсутності реальних даних. Очікування на цій конкретній машині: `[FAIL] VSS` для багатотомних джерел, бо `diskshadow.exe` фактично відсутній (підтверджено нижче). |
| `diskshadow.exe` наявність | **PASS (FAIL-результат, підтверджує документований ґап)** | Виконано реально: `Test-Path "$env:SystemRoot\System32\diskshadow.exe"` → `False`. Хост: Windows 11 Pro, build 26200. Підтверджує застереження README.md:68-84 на ще одному build (26200, новіший за задокументовані 19045/22H2) — ґап не обмежений конкретним build. |
| Task Scheduler реєстрація/виконання | **PASS** | Виконано реально через COM `Schedule.Service` (той самий API, що використовує `BRAVO_TASKS_INSTALL.ps1`) в ізольованій папці `\BRAVO-ACCEPTANCE-TEST\`, окремій від будь-яких production task-шляхів BRAVO: створено вимкнену задачу `AcceptanceProbe_<guid>` з тригером +5 років (ніколи не спрацює), підтверджено `RegisterTaskDefinition` → `GetTask` → `DeleteTask` → `DeleteFolder`, увесь слід прибрано. |
| Heartbeat entrypoint | NOT RUN | `BRAVO_OPERATIONS_HEARTBEAT.ps1` існує лише на `feat/operations-protocol-v2` (PR #225), відсутній у `developer`/цьому worktree. Команда після merge: `.\BRAVO_OPERATIONS_HEARTBEAT.ps1 -NoPause`. |
| Credential Manager write/read | **PASS** | Виконано реально через канонічний `modules\BRAVO.Credentials\BRAVO.Credentials.psd1` (`Set-BRAVOCredential`/`Get-BRAVOCredential`/`Get-BRAVOCredentialSecret`/`Remove-BRAVOCredential`), тестовий target `BRAVO_ACCEPTANCE_TEST_<guid>` (поза будь-яким production-namespace BRAVO): write → read UserName збігся, read secret через `SecureString` збігся з очікуваним значенням, cleanup підтверджено (`Get-BRAVOCredential` після `Remove-BRAVOCredential` повернув порожньо). |
| Operations bootstrap credential | NOT RUN | Канонічний Operations bootstrap-credential існує лише на PR #225 (коміт `8b3bb9a`). Команда після merge: визначити точний target-формат у `BRAVO.Operations.psm1`/`BRAVO.Credentials.psm1` і повторити той самий write/read/delete-цикл на реальному target. |
| Restore drill (реальний) | NOT RUN | Немає реальних verified generations на цій машині (dev workstation, не розгорнутий BRAVO). Команда: `.\BRAVO_RESTORE_TEST.ps1 -Component All -ResultPath C:\BRAVO-ACCEPTANCE\win11\restore\result.json`. |
| Update/rollback 5.2→5.3 | NOT RUN | Потребує реальної розгорнутої 5.2.x інсталяції з production-даними для безпечного up/down-прогону; у dev-worktree немає встановленого попереднього релізу. Команда: `docs/BRAVO_CONFIG_V2_PILOT_MIGRATION_RUNBOOK_20260916.md` end-to-end на копії реальної конфігурації. |
| Operations API недоступний (fail-closed/degrade) | NOT RUN | Потребує merge PR #225 і реального BRAVO-хоста з активним enrollment до Operations API, щоб реалістично імітувати мережевий збій без ризику зіпсувати реальний enrollment-стан. Команда для оператора: заблокувати вихідний HTTPS до Operations API endpoint і запустити `BRAVO_HEALTH.ps1`; звірити з контрактом never-throw + outbox (`BRAVO.Operations.psm1:13-21`, `efd2307`, `d2d1136`). |

---

## Реально виконано на поточній машині — підсумок

Хост: Windows 11 Pro, build 26200 (ProductType=1/Workstation),
PowerShell 5.1.26100.9444, tier `Supported` (підтверджено
`Get-BRAVOOSSupportTier`).

1. **`diskshadow.exe` наявність** — `Test-Path` → `False`. Підтверджує
   задокументований ґап README.md:68-84 на новому build (26200), якого
   немає в оригінальному списку підтверджених build (19045/22H2).
2. **Task Scheduler** (COM `Schedule.Service`, ізольована тестова папка
   `\BRAVO-ACCEPTANCE-TEST\`) — реєстрація/читання/видалення задачі —
   **PASS**, слід прибрано повністю.
3. **Windows Credential Manager** (канонічний
   `modules\BRAVO.Credentials`, тестовий target поза production
   namespace) — write/read UserName/read Secret/cleanup — **PASS**.

Усе інше в матриці — **NOT RUN**, бо або (a) немає доступу до потрібної
Windows-версії (Server 2012 R2/2016/2019/2022, Windows 10), або (b) на
поточній машині немає реального розгорнутого BRAVO з production-даними
(VSS-preflight, restore drill, update/rollback), або (c) перевірка
залежить від коду PR #225, який ще не змерджено в `developer`
(heartbeat entrypoint, Operations bootstrap credential, Operations
API-degrade сценарій).

## Розбіжності документації

Не знайдено. README.md support tier таблиця, `diskshadow.exe`-
застереження й код `BRAVO.Compatibility.psm1` узгоджені між собою.
Правок README/ROADMAP у цій хвилі не робилось; комітів немає.

## Явне попередження (повторно)

Жодна клітинка цієї матриці не є доказом готовності до релізу поза
межами того, що справді виконано на реальному хості. `NOT RUN` — це не
"ймовірно ОК", це "не перевірено; ось точна команда для оператора з
доступом до цього хоста". CI (Ubuntu) і локальні PowerShell-перевірки на
єдиній доступній Windows 11-машині **не замінюють** full-matrix
real-server acceptance на Server 2012 R2/2016/2019/2022 і на реальному
Windows 10 хості, а також не замінюють end-to-end restore drill і
update/rollback прогони на реальних production-схожих даних.
