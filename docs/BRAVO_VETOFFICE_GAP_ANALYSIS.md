# VetOffice: інвентаризація та gap analysis (VETOFFICE-DISCOVERY-0, #486)

Статус: **чернетка gap list, очікує затвердження власником.** До
затвердження робота над #487 (VETOFFICE-COMPAT) не починається.

Документ фіксує чинну поведінку комплекту на знеособлених
characterization-фікстурах VetOffice. Runtime-код, служби, Scheduled Tasks і
Credential Manager на цьому етапі не змінювались. Перевірки на реальних
DEV-серверах не виконувались — це окремий крок (розділ «Що не перевірено»).

Усі імена, шляхи, хости й адреси в документі та фікстурах вигадані.
Реальні інсталяції далі називаються «Сайт A» (VetOffice на `D:`) і
«Сайт B» (VetOffice на `C:`).

## 1. Джерела

| Джерело | Стан |
| --- | --- |
| Issue #486 (опис) | прочитано; коментарів немає |
| Issue #487 | прочитано лише як контекст |
| ТЗ `BRAVO_VETOFFICE_FUNCTIONAL_RECOVERY_TZ.md` v1.1 (2026-10-17), на яке посилаються #486–#490 | **недоступне**: у репозиторії, `docs/` і доступних каталогах його немає. Вимоги нижче взято лише з тексту issue; зміст ТЗ — невідоме |
| Наявна підтримка VetOffice у коді | див. розділ 2 |

## 2. Що вже є в репозиторії

- `operationsReportingSettings.ProductType` з дозволеними значеннями
  `LIMS`/`VETOFFICE` (`modules/BRAVO.Configuration/BRAVO.Configuration.Schema.psm1:854`,
  `modules/BRAVO.Configurator/BRAVO.Configurator.Schema.psd1:273`). Значення
  споживає лише enrollment Operations (`modules/BRAVO.Operations/BRAVO.Operations.psm1:887`);
  профілю інсталяції `VETOFFICE` для Discovery/Maintenance/Archive/Health немає.
- Self-test `selftest/BRAVO_SELF_TEST.BackupScope.ps1:54` моделює VetOffice
  синтетичним presence (`BRAVOEXCH`/`BAZA_APP` = `Absent` з `Source = None`).
  Справжній Discovery на фікстурі дає для `BAZA_APP` інше джерело (розділ 4, G1).
- `Legacy/VetOfficeRemoved` (`BRAVO_SELF_TEST.ps1:29464-29471`) фіксує, що
  старі `ARCHIV_VETOFFICE.*` entrypoint-и не повертаються.
- Гілок `origin/*` і PR з реалізацією VetOffice немає (перевірено
  `git branch -r`, пошук PR/issue за `vetoffice`: лише #486–#490).

## 3. Фікстури та harness

| Файл | Призначення |
| --- | --- |
| `selftest/fixtures/vetoffice/scenarios.json` | сценарії «D:» і «C:», розклад каталогів, синтетичні служби `BRAVO` і `Apache2.4` (`DependsOn: BRAVO`), відсутній `exchangAPI`, legacy-архіви |
| `selftest/fixtures/vetoffice/templates/bravo.ini.template` | знеособлений `bravo.ini` (`[model] MODEL`/`BLOG`, без `BEXCH`; `[Debug] FILE=TraceSRV.out`) |
| `selftest/fixtures/vetoffice/templates/httpd.conf.template` | `ServerRoot`/`DocumentRoot` для Discovery BAZA_WWW |
| `selftest/fixtures/vetoffice/trace/TraceSRV.sample.utf8.txt` | текст trace; harness кодує його в CP1251 під час матеріалізації |
| `ci/acceptance/Invoke-BRAVOVetOfficeFixtureCharacterization.ps1` | матеріалізує фікстуру під `-OutputRoot`, викликає Discovery з ін'єкцією служб і `-SystemRoot`, пише `characterization.json` |

Чому CP1251 і `.mdz` генеруються, а не лежать у репозиторії: за
`.gitattributes` (`* text=auto eol=crlf`) git нормалізував би файл CP1251 як
текст, а сканери репозиторію читають текст як UTF-8. Генерація з UTF-8
джерела дає детерміновані байти (SHA-256 записується в результат) без
зміни `.gitattributes`.

Розклад інсталяції у фікстурі — **припущення**, а не знання про реальні
сервери: `bravo.exe` у корені, `apache\bin\httpd.exe`, `www\BAZA`,
`www\PRINT`, `Model\VetOffice.md`, `BLOG`, legacy `ARCHIV\Trace\<дата>\TraceSRV_00000N.out`
і `ARCHIV\vet_control_*.mdz`. Реальний розклад має підтвердити власник (розділ 6).

Новий `.ps1` увійшов у `RUNTIME_MANIFEST.json`: маніфест охоплює всі
`.ps1/.psm1/.psd1` комплекту (`ci/Update-BRAVORuntimeManifest.ps1:40-73`).
Його перегенеровано штатним `ci/Update-BRAVORuntimeManifest.ps1 -Apply`
(дельта: один рядок `НОВИЙ ci\acceptance\Invoke-BRAVOVetOfficeFixtureCharacterization.ps1`).
`TOOLS_MANIFEST.json` не змінився.

## 4. Очікування, фактична поведінка, прогалини

Очікування взято з #486/#487. Позначки доказів:
**[F]** — виконано на фікстурі (harness або ізольований DRY_RUN);
**[C]** — встановлено читанням коду, без виконання.

### G1. BAZA_APP на VetOffice блокує резервне копіювання (P1)

- Очікування: на VetOffice немає BAZA_APP, і його відсутність штатна.
- Факт [F]: Discovery виводить `BAZA_APP = <корінь>\BAZA` з `bravo.ini`
  (`modules/BRAVO.Discovery/BRAVO.Discovery.psm1:905-941`), тобто джерело
  оголошене (`Source = BravoIni`). Каталогу немає, тому presence =
  `Absent/NotFound`, а `Resolve-BRAVOBackupComponentScope` дає
  `BAZA_APP = Missing` (Error). Так само в обох сценаріях (C: і D:).
  Ізольований DRY_RUN: `FAIL | Джерело | BAZA APP | каталог відсутній`.
- Розбіжність із self-test: `BackupScope` моделює той самий випадок як
  `Source = None` → `NotInstalled`, тому чинне покриття цієї поведінки не бачить.
- Обхід без зміни коду (не перевірено на реальному сервері): вимкнути
  синхронізацію BAZA_APP у `BRAVO.local.config`
  (`componentSettings.Synchronization.BAZA_APP_SFTP = $false`; приклад ключа —
  `BRAVO.local.config.example:266-267`).
- Власник: #487 (профіль інсталяції).

### G2. BRAVOEXCH без ключа `BEXCH` (P3)

- Факт [F]: presence = `Absent/None`, scope = `NotInstalled`; DRY_RUN:
  `PASS | Склад | Не встановлено на цьому сервері | BRAVOEXCH`.
- Прямий виклик `Test-BRAVODiscoveryResult` з усіма увімкненими компонентами
  повертає помилку «Джерело 'BRAVOEXCH' увімкнено, але шлях не визначено».
  [C] `BRAVO_SETUP.ps1:621-623` передає `-EnabledComponents
  $discoveryScope.EffectiveEnabledComponents`, з якого `NotInstalled`
  виключено (`BRAVO.Discovery.psm1:1895`), тому SETUP цієї помилки для
  BRAVOEXCH видавати не повинен. Виконанням не підтверджено (розділ 5).

### G3. Відсутня служба exchangAPI (P3)

- Очікування (#487): відсутність `exchangAPI` штатна, без WARNING.
- Факт [C]: Maintenance вимикає компонент (`SilentlySkipped`,
  `modules/BRAVO.Maintenance/BRAVO.Maintenance.Runtime.ps1:1187-1199`, `1411-1416`).
  Health читає службу з `-ErrorAction SilentlyContinue`
  (`modules/BRAVO.Health/BRAVO.Health.Runtime.ps1:4268-4274`).
- Факт [F]: Discovery службу не знаходить, помилки немає. DRY_RUN не дає
  WARNING/FAIL щодо exchangAPI, але все одно показує рядок
  `PLAN | Maintenance | exchangAPI логи | ... would archive ...`. Рядок
  описує ротацію компонента, якого на сервері немає. Це косметична прогалина.

### G4. Apache2.4 залежить від BRAVO: неявна зупинка (P1, потребує реальної перевірки)

- Очікування (#486/#487): ServiceCycle коректний для залежної `Apache2.4`.
- Факт [C]: залежності служб (`DependentServices`/`ServicesDependedOn`) у
  runtime не використовуються: `git grep -i` за цими назвами не дає жодного
  збігу в `.ps1`/`.psm1` комплекту (крім нового harness-а). Harness [F]
  показує те саме:
  результат Discovery не містить поля залежностей
  (`DiscoveryExposesServiceDependencies = false`).
- Чинний порядок зупинки: BRAVO Web → exchangAPI → BRAVO
  (`modules/BRAVO.Maintenance/BRAVO.Maintenance.ServiceCycle.ps1:280-395`).
  BRAVO зупиняється через `Stop-Service -Force`
  (`BRAVO.Maintenance.Runtime.ps1:1347`), а `-Force` зупиняє й залежні служби.
- Якщо `Apache2.4` визначено як BRAVO Web і вона керована, її зупиняють
  першою, тому неявна зупинка не настає. Ризик лишається, коли Apache не
  потрапила в керований набір або в ownership-маркер (`BravoWebEnabled = $false`,
  служба не ідентифікована, contract не підтвердив зупинку). Тоді
  `Stop-Service BRAVO -Force` зупинить Apache неявно, а цикл запуску її не
  підніме: служби немає в restart intent.
- Ідентифікація BRAVO Web у Maintenance спершу звіряє `httpd.exe` з
  `maintenanceSettings.General.BravoWebDirectory` (дефолт `C:\Br-a-vo.web`;
  `BRAVO.Maintenance.Runtime.ps1:1039-1066`), потім шукає за іменами
  кандидатів (`Apache2.4` є в дефолтному списку,
  `modules/BRAVO.Configuration/BRAVO.Configuration.psm1:154-161`). На VetOffice
  служба знаходиться лише за іменем.
- Не перевірено виконанням: потрібні справжні служби (розділ 6).

### G5. Веб-журнали VetOffice беруться не з Discovery (P2)

- Факт [F]: Discovery правильно визначає `WEB_ROOT = <корінь>` і BAZA_WWW
  з `httpd.conf` (`www\BAZA`, `Source = ApacheConfig`).
- Факт [C]: ротація журналів Apache/застосунку бере шляхи з
  `BravoWebDirectory` (`$BRAVO_WEB_DIR\apache\logs`, `$BRAVO_WEB_DIR\www\log`;
  `BRAVO.Maintenance.Runtime.ps1:9026-9031`, `9139-9140`), а не з `WEB_ROOT`.
  Без явного override на VetOffice ротація дивиться в `C:\Br-a-vo.web`.
  Чи збігається розклад `apache\logs`/`www\log` на VetOffice, невідомо.

### G6. Очищення `www\PRINT` (P2)

- Факт [C]: канонічного механізму очищення `www\PRINT` у модулях немає
  (пошук `PRINT` у `modules/` і кореневих entrypoint-ах не дає збігів). За #487
  це лишається в gap list, доки власник не визначить механізм.

### G7. TraceSRV у CP1251 і кодування конфігів (P3 / невідоме)

- Факт [F]: байти фікстурного TraceSRV у CP1251 не є валідним UTF-8
  (`DecodesAsStrictUtf8 = false`), round-trip CP1251 точний.
- Факт [C]: вміст trace комплект не розбирає. Файли переміщуються й
  архівуються як байти (`Get-BRAVOTraceArchiveBacklog`,
  `BRAVO.Maintenance.Runtime.ps1:4688-4750`), тому CP1251 на ротацію не впливає.
  Розбір вмісту з'явиться в #489 (детектор), і там кодування стане вимогою.
- Ризик [C]: `bravo.ini` і `httpd.conf` читаються як UTF-8
  (`BRAVO.Discovery.psm1:172`, `309`). Якщо реальний `bravo.ini` VetOffice
  записано в CP1251 із кирилицею в шляхах, шлях буде декодовано хибно.
  Кодування реального `bravo.ini` невідоме.

### G8. Legacy-архіви (P1 для #487)

- Факт [F]: для кореня інсталяції backlog добового trace-архіву містить
  лише `TraceSRV_20260301_101500.out` → `Trace_20260301.mdz`. Активний
  `TraceSRV.out` фільтр імен відкидає.
- Факт [C]: `ARCHIV\Trace\<дата>\TraceSRV_00000N.out` у backlog не
  потрапляють, бо перелік плоский, без рекурсії
  (`BRAVO.Maintenance.Runtime.ps1:4713`), а файли лежать у підкаталогах-датах.
  Порожній backlog для `ARCHIV\Trace` на фікстурі пояснюється саме цим, а не
  фільтром імен.
- Факт [C]: `Compress-OldData` пакує **будь-який** каталог `YYYY-MM-DD` у
  `<SystemLogRoot>\Trace`, старший за `ArchiveDays` (за `CreationTime`), у
  `Trace_YYYY-MM-DD.mdz` і видаляє каталог після успіху
  (`BRAVO.Maintenance.Runtime.ps1:7738-7800`, видалення — `7796`;
  `$TRACE_DIR = <SystemLogRoot>\Trace` — `9102`, виклик — `12490`). `Invoke-BRAVOLegacySweep`
  свідомо лишає непорожні legacy-каталоги-дати цьому шляху
  (`BRAVO.Maintenance.Runtime.ps1:11900-11916`). Якщо legacy `ARCHIV\Trace`
  збігається з `<SystemLogRoot>\Trace`, legacy-каталоги буде повторно
  заархівовано й видалено. Чи збігаються ці шляхи на сайтах і який там
  формат дат, невідомо.
- Факт [C]: retention стиснутих журналів фільтрує строго за префіксом
  компонента (`Remove-BRAVOExpiredCompressedLogs`,
  `BRAVO.Maintenance.Runtime.ps1:6705-6740`), тому `vet_control_*.mdz` цим
  шляхом не видаляється. Retention архівів MODEL шукає
  `${ArchivePrefix}_before_*`/`_after_*` (`BRAVO.Maintenance.Runtime.ps1:7956`).
  Інші шляхи retention для довільного `ArchivePrefix = vet_control` не
  перевірено.

### G9. range_id_log.json (P3 / невідоме)

- Факт [F]: DRY_RUN шукає `range_id_log.json` лише в системному каталозі
  (`WARN | Maintenance | Range ID`). Override немає
  (`Get-BRAVOSystemRangeIdLogPath`, `BRAVO.Discovery.psm1:462-476`). Чи існує
  цей файл на VetOffice, невідомо.

### G10. Диск C: проти D:

- Факт [F]: на фікстурах результати Discovery для «C:» і «D:» ідентичні з
  точністю до кореня. Discovery від літери диска не залежить.
- Від диска залежать [C], але не перевірено: дефолт `BravoWebDirectory = C:\Br-a-vo.web`
  (G5), набір томів VSS, виключення дисків для вільного місця.

## 5. Виконані перевірки

| Перевірка | Результат | Доказ |
| --- | --- | --- |
| Discovery на фікстурах (harness) | PASS (exit 0; 2 сценарії) | `characterization.json`, `characterization.console.txt` у каталозі доказів завдання |
| `BRAVO_DRY_RUN.ps1`, ізольовано | виконано; 67 рядків: PASS 39, PLAN 19, WARN 7, FAIL 2 (VSS — середовище; BAZA_APP — G1) | `dryrun-result.json`, `dryrun-stubbed.console.txt` |
| `BRAVO_SETUP.ps1 -ValidateOnly` | **NOT RUN** | причина нижче |
| Реальні DEV-сервери | **NOT VERIFIED — очікує власника** | окреме завдання |

Ізоляція DRY_RUN (перевірено читанням коду перед запуском):

- запуск із копії комплекту в каталозі доказів; маніфест копії збігся
  (`PASS | Цілісність | RUNTIME_MANIFEST.json відповідає комплекту`);
- `BRAVO.local.config` вказує `pathSettings.BackupRoot/SystemLogRoot` і
  `discoverySettings.*` на фікстуру;
- `ProgramData`, `TEMP` і `TMP` дочірнього процесу перенаправлено в каталог
  доказів. Write-probe-и DRY_RUN (`BRAVO_DRY_RUN.ps1:1397-1468`) пишуть у
  `%ProgramData%\BRAVO\Locks|State` (`modules/BRAVO.Configuration/BRAVO.Configuration.Derivation.psm1:240-247`),
  тому без перенаправлення вони торкнулися б справжнього каталогу;
- `-SkipCredentials`, без `-TestAccess` і `-SendTestNotification`. Мережа й
  Credential Manager не використовувались (`BRAVO_DRY_RUN.ps1:1904`, `2164`);
- перший запуск без stub-ів обірвався на `Get-Service`
  (`BRAVO_DRY_RUN.ps1:282`): обліковому запису dev-VM заборонено відкривати
  SCM. Повторний запуск виконано з read-only stub-ами `Get-Service`,
  `Get-CimInstance`/`Get-WmiObject` (лише клас `Win32_Service`), які
  повертають синтетичні служби фікстури. `Start-/Stop-/Restart-/Set-Service`
  і `Register-/Set-/Start-ScheduledTask` у тому процесі підмінено функціями,
  що кидають виняток;
- лишились реальні **читання**: стан Task Scheduler (каталог `\BRAVO` не
  існує), VSS-capability, `range_id_log.json`.

Чому `BRAVO_SETUP.ps1 -ValidateOnly` не запускався:

- за дефолтних параметрів він запускає дочірній
  `BRAVO_CREDENTIALS_SETUP.ps1 -Action Test -StoreFor Both`
  (`BRAVO_SETUP.ps1:696-715`). Для SYSTEM-сховища цей скрипт без прав
  адміністратора піднімає UAC (`Start-Process -Verb RunAs`,
  `BRAVO_CREDENTIALS_SETUP.ps1:1770-1813`), а з правами адміністратора
  реєструє тимчасову SYSTEM-задачу (`RegisterTaskDefinition`,
  `BRAVO_CREDENTIALS_SETUP.ps1:1498`);
- фінальний крок без `-SkipAccessTest` запускає DRY_RUN з `-TestAccess`
  (`BRAVO_SETUP.ps1:740-742`). У цьому режимі перевірка доступу створює
  віддалені SFTP-каталоги;
- read-only stub-и служб не успадковуються дочірніми процесами
  PowerShell, які SETUP запускає, тому ізолювати SETUP на цій VM так само,
  як DRY_RUN, не вдається.

Попутні спостереження поза VetOffice (окремі issue на рішення власника,
тут не виправлялись):

- O1. `BRAVO_SETUP.ps1 -ValidateOnly` не є повністю read-only: дочірній
  credentials-test може підняти UAC або зареєструвати тимчасову SYSTEM-задачу
  (див. вище).
- O2. У `BRAVO_DRY_RUN.ps1:282` виклик `Get-Service -ErrorAction SilentlyContinue`
  без `-Name` при забороненому доступі до SCM кидає завершальну помилку, і
  DRY_RUN обривається замість рядка FAIL/WARN. На production DRY_RUN
  запускається з правами адміністратора, тому вплив ймовірно низький.

## 6. Невідомі дані (без припущень)

1. Зміст ТЗ `BRAVO_VETOFFICE_FUNCTIONAL_RECOVERY_TZ.md` v1.1.
2. Реальний розклад інсталяцій Сайту A і Сайту B: де лежать `bravo.exe`,
   Apache (`httpd.exe`, `httpd.conf`), `DocumentRoot`, `www\PRINT`, веб-журнали.
   Особливо невідомі шляхи й особливості Сайту B (VetOffice на `C:`).
3. Вміст і кодування реального `bravo.ini` (ключі `MODEL`/`BLOG`/`BEXCH`,
   `[Debug] FILE`, кирилиця в шляхах).
4. Чи справді `Apache2.4` має `DependOnService = BRAVO` на обох сайтах
   (зараз це лише твердження з #486), її ім'я/DisplayName і тип запуску.
5. Розташування й формат дат legacy `ARCHIV\Trace\<дата>`, повний набір
   legacy-префіксів архівів (`vet_control_*` та інші), чинний `ArchivePrefix`.
6. Наявність `range_id_log.json`, клієнтів BIS і їхня роль на VetOffice.
7. Значення `SystemLogRoot`/`BackupRoot`/томів VSS на сайтах.

## 7. Залежності

- #487 (VETOFFICE-COMPAT): після затвердження цього gap list. G1, G3–G6 і G8 —
  його вхідні вимоги.
- #488 (TRACE-ROTATION-GRACE): G7, G8.
- #489 (FUNCTIONAL-FAILURE-DETECT): кодування TraceSRV (G7) стане вимогою
  детектора.
- #490 (RECOVER-FUNCTIONAL): поведінка залежної `Apache2.4` (G4).
- #316 (ClientGate для BIS): згадано в #487, у цьому кроці не аналізувалось.

## 8. Що потребує дій власника

- Затвердити або скоригувати gap list (G1–G10, O1–O2).
- Надати ТЗ v1.1 або підтвердити, що вимоги беруться з issue.
- Доручити окреме завдання на read-only перевірки (`-ValidateOnly`,
  DRY_RUN) на DEV-сервері Сайту A з правами, які дозволяють читати SCM, і
  перевірку залежності `Apache2.4` на справжніх службах. Журнали — без
  секретів і реальних ідентифікаторів у репозиторії.
- Заповнити невідомі дані розділу 6.
