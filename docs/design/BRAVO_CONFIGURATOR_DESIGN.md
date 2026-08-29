# BRAVO Configurator — Architecture Freeze (Agent 0)

Статус: **DRAFT — architecture freeze для перегляду перед стартом Agent 1-6.**
Гілка: `feat/bravo-configurator` (первинно базована на `origin/developer` @
`9d0ece8`; перебазована на `origin/developer` @ `0e63fdc` після інтеграції
`hotfix/5.2.2` — PR #111, "P0 reconciliation after 5.2.2" нижче, §2).
Не чіпає `master`/RC-гілки; не змінює production runtime.

## 1. Canonical source of truth (verified, не припущення)

- **`BRAVO.config`** (1288 рядків) — canonical defaults. Виконується як PowerShell
  script з `param(ConfigRoot, RuntimeRoot)`; містить ~50 `$global:*Settings`
  блоків, частина з яких — **похідні** (`effectiveLimsRoot`, `bazaSyncEffective`,
  `archiveDirs`, `sourcePaths`, `bazaAppPaths`, `bazaWWWPaths`, `archiveDefinitions`
  тощо), а не configurable input.
- **`BRAVO.local.config`** — data-only hashtable `'dot.path' = value`, завантажується
  `Read-BRAVOLocalConfigurationOverrides` (`BRAVO_CONFIG_LOADER.ps1:276`) через
  `[scriptblock]::CheckRestrictedLanguage([],[],$false)` — **виконуваний код
  відхиляється на рівні мови**, не лише конвенцією.
- **Канонічний перелік дозволених override-шляхів = сам
  `BRAVO.local.config.example`** (коментований, повний каталог) — це
  **єдине джерело істини** для Configurator schema inventory, не окрема
  ручна таблиця. Верифіковано скриптом (не вручну): **136 документованих
  override-ключів** (`CONFIGURABLE_TOTAL=136`, включно з кореневими
  скалярами без крапки в шляху — `logRetentionDays`, `sftpPort`,
  `LogLevel` тощо — які початковий grep без урахування single-segment
  ключів пропускав). `BRAVO.Configurator.Schema.psd1` містить рівно **138**
  дескрипторів, 1:1 з цим переліком (перевірено
  `Test-BRAVOConfiguratorSchemaCompleteness`, §4) — **136 базових + 2**,
  додані при P0 reconciliation after 5.2.2 (§2.1):
  `componentSettings.SFTP.Enabled`, `componentSettings.SMB.Enabled`.
- **Двофазне застосування overrides** (`BRAVO_CONFIG_LOADER.ps1:323`,
  `Invoke-BRAVOLocalConfigurationOverridePhase`) — критична семантика,
  яку Configurator **зобов'язаний** відтворювати, а не ігнорувати:
  - Фаза 1 (первинні поля: `bravoSettings`, `pathSettings`,
    `maintenanceSettings`, `componentSettings`, sftp/smb-скаляри) —
    застосовується ДО деривацій.
  - Фаза 2 (пізні блоки: `sftpDirectories`, `backupMonitoring`,
    `schedulerSettings`) — фінальні значення; похідні поля з інших
    полів **не переобчислюються** заново.
  - Проміжні вузли шляху не створюються — невідомий/помилковий шлях
    = помилка конфігурації в лоадері (typo-safety вбудований у сам
    контракт, Configurator має цю ж перевірку успадкувати, не дублювати).
- Заборонені для override (явно в шаблоні): похідні блоки (`sourcePaths`,
  `archiveDirs`, `bazaAppPaths`, `bazaWWWPaths`, `archiveDefinitions`),
  `discoverySettings`, `toolIntegritySettings`, runtime-шляхи
  (`ScriptPath`/`HelperPath`). Schema-inventory (Agent 1) повинен
  класифікувати ці шляхи як `ReadOnly=$true`/non-configurable, не як
  "забуті" — вони показуються в Effective view, але без editor control.

## 2. Canonical effective-resolver — стан на момент першого написання і після 5.2.2

**Історичний контекст (правильно на момент першого написання цього
документа, вже НЕ правильно після інтеграції `hotfix/5.2.2` — див. §2.1
нижче).** На `origin/developer` (до 5.2.2) **не існувало** централізованої
чистої функції на кшталт `Get-BRAVOEffectiveStorageConfiguration` для
SFTP/SMB master-child семантики. `Get-BRAVOEffectiveSynchronizationConfiguration`
(`BRAVO.Discovery.psm1:1340`) покривала лише BAZA sync-флаги, без жодного
глобального SFTP/SMB master-switch (той просто не існував як
конфігураційний контракт). Master/child логіка обчислювалась inline і
незалежно в кількох runtime-файлах: `BRAVO_DRY_RUN.ps1`,
`BRAVO_CREDENTIALS_SETUP.ps1`, `modules/BRAVO.Archive/BRAVO.Archive.Runtime.ps1`,
`modules/BRAVO.Health/BRAVO.Health.Runtime.ps1`.

Розділ 10 задачі прямо забороняє "вигадувати dependency semantics у GUI" і
вимагає canonical resolver. Централізація цієї логіки в новий
`Get-BRAVOEffective*` API була визнана окремим, ризикованим, cross-cutting
рефакторингом, який не варто змішувати з фіче-роботою Configurator
(`06-release-lifecycle.md`, "Do not combine broad refactoring with
unrelated features").

### 2.1. P0 reconciliation after 5.2.2 — resolver тепер існує

`hotfix/5.2.2` (інтегровано в `developer` через PR #111, комміт `0e63fdc`)
додав саме той canonical resolver, відсутність якого документована вище:

- `Get-BRAVOEffectiveStorageConfiguration` (`modules/BRAVO.Discovery/BRAVO.Discovery.psm1`) —
  згортає `componentSettings.SFTP.Enabled`/`SMB.Enabled` (нові global
  master-switches) з дочірніми прапорцями (`ArchiveUpload`/`ArchiveCopy`)
  ОДИН раз, включно з `DisabledReason`. Викликається з `BRAVO.config` в
  `$global:storageEffective` — **єдине джерело правди**, яке Archive,
  Health, Maintenance, Dry Run і Credentials Setup споживають напряму, не
  повторюючи "master AND child" самостійно.
- `Get-BRAVOEffectiveSynchronizationConfiguration` отримала параметр
  `-GlobalSftpEnabled` — `BAZA_APP_SFTP`/`BAZA_WWW_SFTP` тепер ТЕЖ гейтяться
  цим самим SFTP-master-ом.

**Технічний висновок (P0.7, не автоматичний рефакторинг "бо resolver тепер
є"):** повний Effective config (усі 138 шляхів, не лише SFTP/SMB) досі
вимагає прогону справжнього `Import-BravoConfiguration` — новий resolver
покриває лише вузьку підмножину (2 master-switches + 4 залежні поля), не
замінює потребу дочірньо-процесного механізму §2.2 нижче. **Мінімальний, а
не широкий рефакторинг:** дочірній процес тепер ДОДАТКОВО захоплює
`$global:storageEffective`/`$global:bazaSyncEffective` (раніше не
захоплювались), і Model-шар (`Resolve-BRAVOConfiguratorGatedEffective`,
`BRAVO.Configurator.Model.psm1`) читає EffectiveValue/DisabledReason для 4
master-gated шляхів (`SFTP.ArchiveUpload`, `SMB.ArchiveCopy`,
`Synchronization.BAZA_APP_SFTP`, `Synchronization.BAZA_WWW_SFTP`) з цих
canonical структур, а не з `$componentSettings` (завжди RAW). Жодна
master AND child арифметика не переізобретена в Configurator — лише "де в
canonical-виводі шукати правильне значення для цього Path".
`Import-BravoConfiguration` (child-процес) лишається канонічним
механізмом отримання ПОВНОГО effective config — рішення §2.2 нижче
залишається чинним.

### 2.2. Прийняте архітектурне рішення (уникає і дублювання, і небезпечного рефакторингу)

**Effective-value computation у Configurator = реальний прогін canonical
`BRAVO_CONFIG_LOADER.ps1` (`Import-BravoConfiguration`) в ізольованому
child-процесі проти кандидатної конфігурації**, а не переізобретення
resolver-ів у GUI. Той самий патерн (`Invoke-BRAVOAcceptanceChildProcess`),
що вже перевірений у `tools/acceptance/BRAVO_RC_ACCEPTANCE.ps1` для
non-destructive виконання реального RC runtime проти synthetic fixture.

Наслідок: `BRAVO.Configurator.Effective.psm1` **не містить бізнес-семантики
залежностей** — лише: (1) серіалізує candidate override-набір у тимчасовий
`BRAVO.local.config`, (2) запускає `BRAVO_CONFIG_LOADER.ps1` дочірнім
процесом проти synthetic `ConfigRoot`/`RuntimeRoot` (як і сам production
runtime), (3) серіалізує результуючі `$global:*Settings` назад у JSON,
(4) diff проти Default і проти попереднього Effective — виключно
презентаційна логіка. Це задовольняє "one canonical implementation policy"
без нового пререквізит-рефакторингу продакшн-модулів і без другого
незалежного config-engine.

Ціна рішення: кожен recompute Effective — реальний child-процес (~секунди,
не мілісекунди). Прийнятно для інтерактивного Preview/Apply, неприйнятно
для live-перерахунку "на кожен keystroke" — UI повинен дебаунсити
recompute (наприклад, на blur/commit поля, не on-change).

## 3. Модульні межі (freeze)

```text
BRAVO_CONFIGURATOR.ps1                    — тонкий entry point (bootstrap → GUI/CLI dispatch)

modules/BRAVO.Configurator/
  BRAVO.Configurator.psd1                 — module manifest, реекспорт публічного API
  BRAVO.Configurator.Schema.psd1          — data-only descriptor catalog (120+ leaf paths)
  BRAVO.Configurator.Schema.psm1          — schema completeness self-test helpers
  BRAVO.Configurator.Model.psm1           — Setting/Model: Default|Override|Effective|Dirty
  BRAVO.Configurator.Effective.psm1       — child-process canonical loader invocation (§2)
  BRAVO.Configurator.Validation.psm1      — semantic INFO/WARNING/ERROR, no I/O
  BRAVO.Configurator.Persistence.psm1     — baseline-hash, atomic apply, rollback
  BRAVO.Configurator.Presets.psd1         — preset definitions (data-only)
  BRAVO.Configurator.Presets.psm1         — preset application onto Model
  BRAVO.Configurator.Credentials.psm1     — Credential Manager status adapter (Agent 6)
  BRAVO.Configurator.UI.psm1              — WinForms shell, schema-driven controls
```

Залежність напрямку: `BRAVO_CONFIGURATOR.ps1 → UI → {Presets, Credentials} →
Model → {Schema, Effective, Validation} → Persistence`. UI ніколи не читає
`BRAVO.local.config` напряму — лише через Model. Жоден модуль Configurator
не є новим "Common/Utils" dumping-ground — кожен має один чіткий контракт
нижче.

## 4. Schema descriptor contract (Agent 1)

```powershell
@{
    Path        = 'componentSettings.SFTP.Enabled'   # exact BRAVO.local.config.example dot-path
    Group       = 'Storage'                            # навігаційна секція 1-10 (§6 задачі)
    Section     = 'SFTP'
    Label       = 'Увімкнути SFTP'                      # людська назва
    Description = '...'                                 # з коментаря BRAVO.config/example
    Type        = 'Boolean'                             # Boolean|String|Integer|Number|Enum|Time|Path|UNCPath|StringArray|NumberArray
    Phase       = 1                                      # 1 або 2 — з CONFIG_LOADER override-фаз
    Advanced    = $false
    ReadOnly    = $false                                 # true для похідних/discovery/toolIntegrity шляхів
    Secret      = $false
    AllowedValues = $null                                # для Enum
    Order       = 10
}
```

Джерело `Description`/`Label` — коментарі над відповідним ключем у
`BRAVO.local.config.example`/`BRAVO.config`; не вигадувати нові формулювання,
що суперечать існуючій документації.

## 5. Model API contract (Agent 2)

Одна `Setting` (immutable snapshot + explicit mutation function, без
прихованого стану):

```text
Get-BRAVOConfiguratorModel -SchemaCatalog -DefaultConfig -LocalOverrides
    -> Model[]  (Path, Metadata, DefaultValue, OverridePresent, OverrideValue,
                 EffectiveValue, Source, DisabledReason, ValidationState,
                 DependencyState, Dirty)
                 # DisabledReason (P0.8, 5.2.2): canonical причина Raw !=
                 # Effective для 4 master-gated шляхів
                 # (SFTP.ArchiveUpload/SMB.ArchiveCopy/BAZA_APP_SFTP/
                 # BAZA_WWW_SFTP) — читається напряму з
                 # storageEffective.SFTP/SMB.DisabledReason (§2.1), не
                 # генерується Configurator-ом; $null для решти шляхів.

Set-BRAVOConfiguratorOverride -Model -Path -Value   -> Model'  (Dirty=$true)
Clear-BRAVOConfiguratorOverride -Model -Path        -> Model'  (OverridePresent=$false)
Update-BRAVOConfiguratorEffective -Model            -> Model'  (перераховує §2 child-процесом; batched, не per-keystroke)
```

## 6. Persistence transaction (Agent 3)

15-крокова pipeline із задачі §5.2: Load → baseline hash → candidate (temp,
зі збереженням невідомих/newer ключів — §5.1) → parse
(CheckRestrictedLanguage, canonical loader) → schema validation →
dependency validation (canonical `Import-BravoConfiguration` через §2
child-process-механізм — подвійно слугує і Effective preview, і pre-apply
валідацією) → re-check baseline hash (race detection) → backup → atomic
replace (`Move-Item`/tmp+rename у тій самій директорії, не in-place write)
→ reload → verify → report. Baseline hash mismatch між Load і Apply =
**STOP**, без merge/overwrite.

### Кроки 8-9 (BRAVO_CONFIG_TEST / BRAVO_DRY_RUN) — НЕ blocking gate (verified finding)

Фактичний прогін показав, що обидва production-entrypoint-и непридатні як
сліпий exit-code gate для ізольованого candidate:
`BRAVO_CONFIG_TEST.ps1` жорстко фіксує `-ConfigRoot=$PSScriptRoot`, і
canonical security-guard `Test-BravoLegacyConfiguration`
(`BRAVO_CONFIG_LOADER.ps1:181`) навмисно відхиляє `-ConfigPath` поза цим
ConfigRoot (CODE!=DATA захист, не обходиться). `BRAVO_DRY_RUN.ps1` технічно
сумісний з ізольованим candidate, але його exit-code змішує config-
семантику з REAL_SERVER-залежними перевірками (Scheduled Tasks, служби) —
на dev-хості чи до `BRAVO_TASKS_INSTALL.ps1` він системно FAIL незалежно
від коректності candidate-конфігурації (той самий клас проблеми, що
вимагав окремого циклу category-aware allow-listing в
`tools/acceptance/BRAVO_RC_ACCEPTANCE.ps1` в іншій гілці — не
імпровізується тут без такого ж циклу верифікації). Кроки 6-7 (canonical
loader через Effective/Validation) уже покривають config-семантичну
валідацію без цього ризику; повний BRAVO_DRY_RUN -SkipCredentials лишається
можливим МАЙБУТНІМ інформаційним (не блокуючим) pre-apply звітом у UI.

### P0.3 (Iteration 2, незалежний review): "gap" між Configurator-валідацією і BRAVO_CONFIG_TEST закритий за конструкцією — доведено, не припущено

Independent review (Iteration 2, P0.1) підняв питання: якщо Кроки 8-9 не
блокують Apply, чи не бракує GUI Apply "еквівалентної canonical blocking
валідації", яку має `BRAVO_CONFIG_TEST.ps1`? Відповідь встановлена читанням
коду й emпіричним прогоном, не інтерпретацією:

`BRAVO_CONFIG_TEST.ps1` (весь файл — 89 рядків) не містить власної
валідаційної логіки. Він робить рівно один виклик:
`Import-BravoConfiguration -ConfigRoot $scriptRoot -ConfigPath $ConfigPath -PassThru`
і транслює будь-який виняток у ненульовий exit code; уся семантика
"валідно/невалідно" (restricted-language parse, unknown-key fail-closed
check `BRAVO_CONFIG_LOADER.ps1:758-767`, `Test-BravoLegacyConfiguration`
guard) належить самій `Import-BravoConfiguration`, не entrypoint-у навколо
неї.

`BRAVO.Configurator.Effective::Invoke-BRAVOConfiguratorEffectiveComputation`
викликає **ту саму** функцію з тим самим контрактом:
`Import-BravoConfiguration -ConfigRoot $isolatedRoot -RuntimeRoot $RuntimeRoot -PassThru`
(незалежний `-ConfigRoot`/`-RuntimeRoot` — параметр, спеціально
призначений саме для "конфіг в іншому каталозі, ніж modules\" — легітимне
використання, не обхід guard-а: `Test-BravoLegacyConfiguration` вимагає
лише щоб `ConfigPath` був під `ConfigRoot`, і обидва виклики це
задовольняють). Після P1-фіксу independent review (`Test-BRAVOConfiguratorCandidateOverrides`
тепер прогонить Effective із ПОВНИМ `$MergedOverrides`, а не
schema-відфільтрованою проєкцією) Configurator реально виконує ідентичний
canonical виклик на ідентичному candidate ДО Apply.

Емпірично підтверджено (не лише прочитано код): свідомо зламаний
candidate (`thisRootDoesNotExist.BrokenLegacyField`) прогнаний через (a)
реальний `BRAVO_CONFIG_TEST.ps1` в ізольованому fixture і (b) через
`Test-BRAVOConfiguratorCandidateOverrides` — обидва відхиляють з
ІДЕНТИЧНИМ повідомленням, що походить з ОДНОГО throw-сайту
(`BRAVO_CONFIG_LOADER.ps1:764`, "не вдалося застосувати ключ(і)"). Той
самий сценарій закріплено як self-test regression (scenario 20,
`selftest\BRAVO_SELF_TEST.Configurator.ps1`).

**Висновок:** Option A ("reusable validation API, спільна для
BRAVO_CONFIG_TEST і Configurator") вже виконана за конструкцією —
`Import-BravoConfiguration` і Є тим спільним canonical validation API;
`BRAVO_CONFIG_TEST.ps1` ніколи не мав окремої логіки, яку требa було б
"еквівалентно" відтворювати. Жодної зміни в production
`BRAVO_CONFIG_TEST.ps1`/`BRAVO_CONFIG_LOADER.ps1` не знадобилося й не
виконано. Єдине, чого Configurator НЕ відтворює (і навмисно) — це
REAL_SERVER-залежна частина `BRAVO_DRY_RUN.ps1` (Scheduled Tasks/служби),
яка вже задокументована вище як окрема, свідомо не-config перевірка.
Позначку "Configurator Apply = DEVELOPMENT ONLY" знято для
config-семантичної валідації; вона й далі відсутня для REAL_SERVER-класу
перевірок, які ніколи не були частиною Apply-контракту цього backend-а.

## 7. UI navigation map

Приймається без змін навігаційна структура з §6 задачі (10 груп: Загальні /
Шляхи та дані / Компоненти / Maintenance / Storage / Health / Scheduler /
Console-Logging / Credentials / Effective configuration) — узгоджується з
120-key inventory після Agent 1 verification.

## 8. Test plan (Agent 7)

Мінімум із §22 вихідного документа, плюс: **regression test для §2 Effective
child-process механізму** — canonical loader, викликаний Configurator-ом,
має повертати той самий результат, що і production
`BRAVO_ARCHIV.ps1`/`BRAVO_DRY_RUN.ps1` на ідентичному fixture
(характеризаційний тест, не дублюючий reimplementation).

## 9. Відкрите питання для власника перед стартом Agent 1-6

Обсяг цієї задачі (§18-22 вихідного документа: ~9 модулів, WinForms UI,
persistence, presets, credentials-адаптер, повний test suite, docs) —
багатоденний обсяг роботи. Architecture freeze (цей документ) завершено;
перед масовим кодуванням потрібне рішення власника про темп/розбивку
подальшої роботи на окремі review-порції (Agent 1+2+3 backend спочатку,
або паралельний запуск усіх — впливає на розмір і кількість наступних
PR-ів згідно §20 задачі).
