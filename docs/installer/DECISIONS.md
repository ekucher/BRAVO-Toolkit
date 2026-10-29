# BRAVO Installer v1 — рішення (ADR)

Документ фіксує рішення, які Installer v1 (гілка `feature/installer-v1`)
реалізує за замовчуванням, і закриває перелік «Рішення для затвердження до
implementation freeze» з детального плану. Форми даних і назви функцій —
у [CONTRACTS.md](CONTRACTS.md); поточний стан реалізації — у
[README.md](README.md).

Кожен запис має статус **«Запропоновано — чекає затвердження власником»**,
доки власник явно не затвердить його. Розділ «Рішення» описує default, який
фактично закладено в код і контракти; розділ «Як змінити» — що саме треба
переробити, якщо власник обере інший варіант.

Жоден запис не є production acceptance і не дає дозволу на deployment,
merge, release чи pilot.

## D1. Scope Installer v1

**Статус:** Запропоновано — чекає затвердження власником.

**Контекст.** Детальний план (§3, §12 п. 1) пропонує обмежити першу версію
операціями, які оператор запускає вручну, щоб не змішувати transactional
engine з автоматичним rollout.

**Рішення.** Installer v1 охоплює:

- clean install на сервер без BRAVO Toolkit;
- ручне update до явно вибраного stable tag;
- same-version repair (відновлення поточної версії без upgrade);
- read-only diagnostics, preflight, журнали й support report.

Не входять у v1:

- автоматичне, silent або scheduled update (`NotifyOnly`, `StageOnly`,
  `Automatic`; backlog INS-110…120 виключено);
- uninstall і видалення backup/state/credentials;
- довільний downgrade, restore production даних, remote commands, fleet
  dashboard.

**Альтернативи.** Включити `NotifyOnly` уже у v1 — відхилено: потребує
окремого trigger-а й policy, а `Automatic` лишається hard-blocked до
повного P3.2 (див. [ARCHITECTURE.md](ARCHITECTURE.md) §13).

**Наслідки.** Engine не має scheduled entrypoint; Scheduled Tasks BRAVO не
запускають update. Uninstall виконується вручну за чинним runbook-ом.

**Як змінити.** Розширення scope — окреме рішення власника, новий контракт
trigger-а та архітектурний gate; для `Automatic` — після acceptance
повного P3.2.

## D2. Підтримувана матриця

**Статус:** Запропоновано — чекає затвердження власником.

**Контекст.** Чинний tier-код `Get-BRAVOOSSupportTier`
(`modules/BRAVO.Compatibility/BRAVO.Compatibility.psm1`) уже визначає
підтримку ОС і PowerShell для production-скриптів. Installer не повинен
мати другу, відмінну матрицю. Поріг .NET Framework у tier-коді відсутній.

**Рішення.**

| Компонент | Рівень |
|---|---|
| Windows Server 2019 / 2022, x64 | `Supported` |
| Windows 10 / 11, x64 | `Supported` |
| Windows Server 2016 (build < 17763) | `LegacyBestEffort` (як у tier-коді) |
| Windows PowerShell 5.1 Desktop | `Supported`; 4.x — `LegacyBestEffort`; нижче — `Unsupported` |
| .NET Framework | ≥ 4.7.2 (`Release` ≥ 528040) — нова preflight-перевірка `BRAVO.Update` |
| Server Core / headless, SYSTEM без desktop | лише CLI `BRAVO_UPDATE.ps1`, без GUI |

Фінальний tier — нижчий із tier-ів ОС і PowerShell. Блокує лише
`Unsupported` (свідомий override — `BRAVO_ALLOW_UNSUPPORTED_OS=1`, як у
чинних production-скриптах). Перевірка .NET Framework належить preflight
engine, а не tier-коду, тому не змінює поведінку наявних скриптів.

**Альтернативи.** Додати поріг .NET у `Get-BRAVOOSSupportTier` — відхилено
для v1: це змінило б поведінку Archive/Maintenance/Health без потреби.

**Наслідки.** На Server 2016 install/update можливі з warning; на
headless-серверах GUI не пропонується.

**Як змінити.** Зміна матриці ОС/PS — у tier-коді (одне джерело для всіх
скриптів); зміна порогу .NET — у preflight `BRAVO.Update` і цьому записі.

## D3. GUI stack

**Статус:** Запропоновано — чекає затвердження власником.

**Контекст.** [ARCHITECTURE.md](ARCHITECTURE.md) §15 і детальний план
називають основним кандидатом C#/.NET Framework/WPF, а запасним MVP —
WinForms-оболонку на базі наявного Configurator.

**Рішення.** Відхилення від основного кандидата: v1 використовує
**Windows PowerShell 5.1 + WinForms** (запасний MVP самого плану), тому що:

- у release artifact не потрібні compiler чи toolchain, а GUI проходить ту
  саму перевірку цілісності, що й інші `.ps1`;
- перевикористовуються патерни `BRAVO.Configurator`;
- GUI тестується під Windows PowerShell 5.1 тими самими засобами, що й
  продукт.

Ризики: масштабування DPI та блокування UI thread. Пом'якшення: mutation
виконує окремий процес engine (worker), а GUI лише опитує `progress.jsonl`
і `result.json` таймером (див. [CONTRACTS.md](CONTRACTS.md) §10).

**Альтернативи.** WPF/C# — лишається можливим пізніше за тим самим
контрактом engine; WebView/Electron/Node — відхилено без конкретної потреби;
MSI — не замінює transaction engine.

**Наслідки.** Один запуск `.exe` у v1 не забезпечується; GUI запускається
як PowerShell-скрипт.

**Як змінити.** Замінити frontend без зміни engine: новий GUI має
споживати ті самі request/progress/result контракти.

## D4. Runtime root і розташування стану

**Статус:** Запропоновано — чекає затвердження власником.

**Контекст.** Чинний `deploy/Install-BRAVOServer.ps1` встановлює в
`C:\Program Files\BRAVO-Toolkit`; на серверах можуть бути й інші root-и.

**Рішення.**

- Default runtime root для нового сервера — `C:\Program Files\BRAVO-Toolkit`
  (чинний default deploy).
- Наявні root-и ніколи не переносяться й не перейменовуються.
- Якщо знайдено кілька root-ів, стан `Ambiguous`; root обирає оператор.
- Стан engine — `%ProgramData%\BRAVO\State\Update`; staging і backup —
  `%ProgramData%\BRAVO\Update\Staging` і `%ProgramData%\BRAVO\Update\Backup`
  (поза runtime і data root-ами).

**Альтернативи.** Автоматична міграція в default root — відхилено: прихована
зміна шляхів ламає Scheduled Tasks і site-конфігурацію.

**Наслідки.** Production-шляхи обчислює лише `Get-BRAVOUpdateDefaultPaths`;
усі інші функції приймають явні корені.

**Як змінити.** Змінити `Get-BRAVOUpdateDefaultPaths` і [CONTRACTS.md](CONTRACTS.md) §1;
перенесення наявних установок — лише окремий operator-controlled сценарій.

## D5. Distribution і перевірка походження

**Статус:** Запропоновано — чекає затвердження власником.

**Контекст.** Online- і offline-джерела мають сходитися в один verification
pipeline (ARCHITECTURE §7). Authenticode-підпису поки немає.

**Рішення.**

- Джерело — release assets GitHub: zip, `.sha256` і release manifest JSON;
  або offline-копія тих самих трьох файлів.
- Обидва джерела проходять однаковий pipeline перевірки.
- Для stable release manifest **обов'язковий** (суворіше, ніж чинні legacy
  deploy-скрипти).
- Лише явно вказаний tag; режиму «latest» немає.
- Без Authenticode GUI чесно попереджає про можливий unknown publisher /
  SmartScreen.
- TLS + checksum з того самого каналу підтверджують цілісність і
  походження в межах каналу, але **не є незалежним криптографічним
  підписом**.

**Альтернативи.** Дозволити stable без manifest для сумісності — відхилено
для engine; legacy-скрипти поводяться як раніше.

**Наслідки.** Release без manifest не встановлюється через Installer.

**Як змінити.** Поява Authenticode — окреме рішення за roadmap і
доповнення pipeline перевіркою підпису.

## D6. Активація Scheduled Tasks

**Статус:** Запропоновано — чекає затвердження власником.

**Контекст.** Детальний план §12 п. 6 вимагає policy для
`SuccessWithWarnings` і мережевих проблем.

**Рішення.**

| Результат | Install | Update / Repair |
|---|---|---|
| `Success` | задачі за канонічною конфігурацією scheduler | задачі за канонічною конфігурацією scheduler |
| `SuccessWithWarnings` | задачі лишаються неактивними до підтвердження оператором | зберігається попередній enabled-стан |
| `Failed` / `RolledBack` | не активуються | відновлюється попередній стан зі snapshot журналу |
| `Critical` / невідомий runtime | ніколи не активуються | ніколи не активуються |

Warnings, що стосуються лише мережі (SFTP/SMB недоступні), активацію не
блокують: відсутність мережі не означає зіпсовану локальну інсталяцію.

**Альтернативи.** Завжди вимикати задачі при warnings — відхилено: зупиняє
архівацію через тимчасові мережеві проблеми.

**Наслідки.** Стан активації відображається в `taskActivation`
результату.

**Як змінити.** Policy зосереджено в engine (`activationPolicy` плану);
змінити там і в цьому записі.

## D7. Credentials

**Статус:** Запропоновано — чекає затвердження власником.

**Рішення.**

- Installer (GUI та engine) ніколи не обробляє секрети.
- Введення — лише через канонічний інтерактивний
  `BRAVO_CREDENTIALS_SETUP.ps1` у видимому консольному вікні.
- Update зберігає наявні секрети; відкат credentials не обіцяється.
- Ротація паролів — поза scope v1.
- Engine не створює credentials, тому після невдалого clean install
  видаляти нічого з credentials не потрібно.

**Альтернативи.** Secure IPC для передачі секретів із GUI — відкладено:
потребує окремого security design (authenticated endpoint, ACL, replay
rejection).

**Наслідки.** Контракти містять лише `credentialPresence`
(`Found|Missing|Unknown|NotRequired`).

**Як змінити.** Окремий security design і review до будь-якої передачі
секретів через Installer.

## D8. Тестові хости та pilot

**Статус:** Запропоновано — чекає затвердження власником.

**Рішення.** VM-матрицю для acceptance і список pilot-серверів визначає
власник. Дозвіл на production rollout надає лише власник.

**Наслідки.** Код і документація цієї гілки не містять реальних імен
хостів; VM acceptance і pilot (INS-130…142, INS-150…155) не виконано.

**Як змінити.** Власник фіксує матрицю й список в окремому рішенні.

## D9. Коди завершення 80/81/82

**Статус:** Запропоновано — чекає затвердження власником.

**Рішення.** У канонічну таблицю `modules/BRAVO.ExitCodes` додано:

| Код | Назва | Severity |
|---|---|---|
| `80` | `DeploymentFailed` | `ERROR` |
| `81` | `DeploymentRolledBack` | `ERROR` |
| `82` | `DeploymentCritical` | `CRITICAL` |

Legacy deploy-скрипти (`deploy/Install-BRAVOServer.ps1`,
`deploy/Update-BRAVOServer.ps1`) зберігають свої коди `1`/`2` до виведення
з експлуатації.

**Альтернативи.** Перевикористати `60`/`90` — відхилено: моніторинг не
розрізнив би збій deploy від збою Maintenance чи внутрішньої помилки.

**Як змінити.** Зміна кодів — contract change у `BRAVO.ExitCodes`, README і
[CONTRACTS.md](CONTRACTS.md) §7.

## D10. Код результату `BRAVO_SETUP.ps1`

**Статус:** Запропоновано — чекає затвердження власником.

**Контекст.** Попередня редакція [ARCHITECTURE.md](ARCHITECTURE.md) §14
стверджувала, що setup повертає `10` як success with warning. Фактично
`BRAVO_SETUP.ps1` завершується лише кодом `0` (успіх) або `1` (помилка).
`Get-BRAVODeploySetupExitVerdict` у `deploy/BRAVO.Deploy.Rollback.ps1`
досі відображає `10` → `PASS_WITH_WARNING` — це залишок сумісності, який
setup не продукує.

**Рішення.** Engine трактує код setup `0` як `Pass`, будь-який ненульовий —
як `Fail`. Код `10` у результаті engine означає лише
`SuccessWithWarnings` самого engine (див. [CONTRACTS.md](CONTRACTS.md) §7).

**Наслідки.** Legacy-вердикт у deploy-скрипті не змінюється цією гілкою.

**Як змінити.** Якщо setup почне повертати `10`, це окремий contract change
setup і engine.

## D11. Lifecycle lock і `BRAVO_OPERATION.lock`

**Статус:** Запропоновано — чекає затвердження власником.

**Рішення.** Engine тримає `BRAVO_UPDATE.lock` протягом усієї операції, а
перед mutation додатково бере канонічний `BRAVO_OPERATION.lock`. Поки lock
утримується, Scheduled Tasks Archive/Maintenance завершуються з кодом `20`.
Активний holder → blocker «дочекайтеся завершення»; примусового завершення
процесів немає.

**Як змінити.** Формат lock-ів — [CONTRACTS.md](CONTRACTS.md) §9.

## D12. Cloud-профіль і `BAZA_WWW` без каналу

**Статус:** Запропоновано — чекає затвердження власником.

**Контекст.** За правилом власника (коментар у
`modules/BRAVO.Configurator/BRAVO.Configurator.Presets.psm1`) профілі з
SFTP не пишуть BAZA-прапорців; `BAZA_WWW_SFTP` за замовчуванням `$false`.
Тому профіль може лишити компонент WWW без жодного каналу синхронізації.

**Рішення.** Installer показує цю ситуацію оператору як warning і не змінює
конфігурацію самостійно. Остаточну поведінку підтверджує власник.

**Як змінити.** Зміна defaults профілю — у `BRAVO.Configurator` за рішенням
власника, не в Installer.

## D13. Version state під час transactional rollback

**Статус:** Запропоновано — чекає затвердження власником.

**Рішення.** Див. `docs/installer/ENGINE_DESIGN.md`.
