# BRAVO Installer v1 — контракти engine (INS-010…014)

Статус: implementation contract для Installer v1 (гілка `feature/installer-v1`).
Документ визначає форму даних між `BRAVO.Update`, `BRAVO_UPDATE.ps1`, GUI та
тестами. Рішення, що потребують затвердження власником, зібрані в
`docs/installer/DECISIONS.md`.

## 1. Загальні правила

- Усі контракти — `PSCustomObject` з полем `schemaVersion = 1`; серіалізація —
  JSON (UTF-8 без BOM), `ConvertTo-Json -Depth 10`.
- Кожен контракт має конструктор `New-BRAVOUpdate<Name>` і валідатор
  `Test-BRAVOUpdate<Name>`, що повертає `{ IsValid, Problems[] }` і нічого не
  кидає. Читання з диска — `Read-BRAVOUpdate<Name>` (fail closed: пошкоджений
  JSON → `IsValid = $false`, не виняток для викликача).
- Час — UTC ISO 8601 (`o`). Ідентифікатори операцій і планів — GUID у
  нижньому регістрі.
- **Секретів у контрактах немає.** Валідатор кожного контракту відхиляє
  властивість на будь-якій глибині, ім'я якої збігається з
  `(?i)password|secret|token|apikey|api_key|privatekey|passphrase|webhook`,
  крім явно дозволених полів присутності (`credentialPresence`, значення лише
  `Found|Missing|Unknown|NotRequired`). Функція
  `Test-BRAVOUpdateNoSecretProperty` — одна канонічна реалізація.
- Усі функції engine приймають явні корені (`-RuntimeRoot`, `-StateRoot`,
  `-LockRoot`, `-StagingRoot`, `-BackupRoot`, `-OperationLockPath`,
  `-VersionStatePath`). Production-значення за замовчуванням обчислює лише
  `Get-BRAVOUpdateDefaultPaths`. Функція нічого не створює на диску;
  `ProgramData` і `ProgramFiles` бере через `[Environment]::GetFolderPath`,
  а не зі змінних середовища; якщо шлях не визначено — виняток (fail closed).

  | Поле | Значення |
  |---|---|
  | `StateRoot` | `%ProgramData%\BRAVO\State\Update` |
  | `LockRoot` | `%ProgramData%\BRAVO\Locks` |
  | `StagingRoot` | `%ProgramData%\BRAVO\Update\Staging` |
  | `BackupRoot` | `%ProgramData%\BRAVO\Update\Backup` |
  | `RuntimeRoot` | `%ProgramFiles%\BRAVO-Toolkit` — default для нового сервера (чинний default `deploy\Install-BRAVOServer.ps1`; див. DECISIONS D4) |
  | `OperationLockPath` | `%ProgramData%\BRAVO\Locks\BRAVO_OPERATION.lock` — канонічний operation-lock (§9) |
  | `VersionStatePath` | `%ProgramData%\BRAVO\State\BRAVO_VERSION_STATE.json` — той самий шлях, що жорстко задають guard-викликачі; engine лише знімає й відновлює знімок цього файлу (DECISIONS D13) |

  Тести завжди передають sandbox-корені й ніколи не торкаються
  `C:\ProgramData\BRAVO`.
- Зовнішні side effects, які не є файловими операціями engine (запуск
  `BRAVO_SETUP.ps1`, guard, self-test, читання й увімкнення задач,
  перевірка credentials), виконуються через **adapter** — hashtable
  scriptblock-ів (`New-BRAVOUpdateDefaultAdapter [-ToolkitRoot]`). Тести й
  failure injection підставляють stub-и під тими самими ключами. Кожен
  scriptblock повертає `PSCustomObject`; якщо `RuntimeRoot` не передано,
  production adapter бере `ToolkitRoot` (корінь, з якого запущено engine).

  | Ключ | Сигнатура | Результат і поведінка production adapter-а |
  |---|---|---|
  | `InvokeGuard` | `param([string]$RuntimeRoot, [string]$LogPath)` | `{ ExitCode, Output, TimedOut, LogPath }`; `BRAVO_RUNTIME_GUARD.ps1 -RuntimeRoot <root> -Mode Enforce` (прямий запуск guard сам працює з `-NoWrite`), таймаут 300 с |
  | `InvokeSetupScheduler` | `param([string]$RuntimeRoot, [string]$LogPath)` | `{ ExitCode, Output, TimedOut, LogPath }`; `BRAVO_SETUP.ps1 -Action Scheduler -SkipTestNotification -NoElevation -NoPause`, 900 с |
  | `InvokeSetupValidate` | `param([string]$RuntimeRoot, [string]$LogPath)` | `{ ExitCode, Output, TimedOut, LogPath }`; `BRAVO_SETUP.ps1 -ValidateOnly -SkipAccessTest -SkipTestNotification -NoElevation -NoPause`, 900 с |
  | `InvokeSelfTest` | `param([string]$RuntimeRoot, [string]$LogPath)` | `{ ExitCode, Output, TimedOut, LogPath }`; `BRAVO_SELF_TEST.ps1 -NoPause`, 3600 с |
  | `GetManagedTasks` | `param([string]$TaskPath, [string]$RuntimeRoot)`, обидва необов'язкові | масив рядків `{ Name, Path, Exists, State, Enabled, actionPath }` (порожній, якщо задач немає); COM `Schedule.Service`; лише TaskPath і імена з ефективної конфігурації (через `GetEffectiveConfiguration`); явний TaskPath поза нею — виняток. `actionPath` — шлях скрипта з `-File` дії задачі; Discovery виводить із нього кандидатів root |
  | `SetTaskEnabled` | `param([string]$TaskPath, [string]$Name, [bool]$Enabled, [string]$RuntimeRoot)` | `{ Success, Message }`; зміну перечитує й підтверджує; TaskPath чи ім'я поза ефективною конфігурацією — виняток |
  | `TestCredentialPresence` | `param([string]$RuntimeRoot, [string]$Component)` | `{ Component, Presence, ExitCode }`, `Presence` = `Found\|Missing\|Unknown`; `BRAVO_CREDENTIALS_SETUP.ps1 -Action Test -Component <c>`: код 0 → `Found`, більше 0 → `Missing`, таймаут або від'ємний код → `Unknown`; секрет не читається й не передається |
  | `GetEffectiveConfiguration` | `param([string]$RuntimeRoot)` | `{ Success, ExitCode, Configuration, Message }`; `Configuration` містить лише `componentSettings`, `pathSettings`, `maintenanceSettings`, `schedulerSettings` (без `credentialSettings`), обчислені канонічним `Import-BravoConfiguration` у дочірньому процесі |
  | `Now` | `param()` | `[datetime]` UTC |

  Дочірні процеси запускає приватний `Invoke-BRAVOUpdateChildProcess
  -ScriptPath -ScriptArgument [-TimeoutSeconds] [-WorkingDirectory]
  [-LogPath]`: `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy
  RemoteSigned -File ...` (без Bypass), секретів в аргументах немає. Вивід
  завжди проходить `Protect-BRAVOLogSecret`; якщо маскувальник недоступний,
  вивід не повертається. За таймаутом завершується лише власний дочірній
  процес — за handle об'єкта `Process`, а не за ім'ям чи PID.

## 2. Finding (спільний елемент)

Використовується в State, Preflight, Plan і Result.

| Поле | Тип | Зміст |
|---|---|---|
| `id` | string | Стабільний машинний код, напр. `Preflight.DiskSpace` |
| `severity` | enum | `Ok`, `Warning`, `Blocker`, `NotApplicable` |
| `title` | string | Коротко українською: що виявлено |
| `meaning` | string | Що це означає для оператора |
| `action` | string | Що зробити (для `Blocker` обов'язкове) |
| `details` | string | Технічні подробиці (без секретів) |
| `exitCodeHint` | int/null | Канонічний код `BRAVO.ExitCodes` для цієї причини |

Відображення в UI/CLI: `Ok` → `✓`, `Warning` → `!`, `Blocker` → `×`,
`NotApplicable` → `—`, завжди разом із текстом (не лише колір).

## 3. InstallationState (INS-010)

`New-BRAVOUpdateInstallationState`; продукує `Get-BRAVOInstallationState`.

| Поле | Зміст |
|---|---|
| `schemaVersion`, `generatedUtc` | |
| `state` | `NotInstalled`, `Installed`, `UpdateAvailable`, `PrereleaseInstalled`, `Degraded`, `RepairRequired`, `InterruptedUpdate`, `RollbackRequired`, `Unsupported`, `Ambiguous` |
| `runtimeRoot` | Обраний root або `$null` |
| `candidateRoots[]` | Усі знайдені roots (`Ambiguous`, якщо >1 і root не вказано) |
| `version` | `{ packageVersion, releaseChannel, buildId, sourceCommit, releaseDate }` з `VERSION.json` або `$null` |
| `integrity` | `{ status: Valid|Invalid|Unknown, checkedCount, mismatchedCount, missingCount, unknownCount, message }` (з `Test-BRAVORuntimeManifestIntegrity`) |
| `versionState` | `{ recordedVersion, statePathKind: Production|Sandbox }` |
| `configuration` | `{ localConfigPresent, legacyConfigPresent, localConfigSchemaValid, migrationBlocker: { blocked, reasons[] } }` |
| `scheduler` | `{ status: Ok|Partial|Missing|Unknown, tasks[]: { name, path, exists, state, enabled } }` |
| `credentials` | `{ status: Unknown|Checked, items[]: { component, account: TaskAccount|CurrentUser, credentialPresence } }` — read-only discovery повертає `Unknown` |
| `interruptedOperation` | `{ present, operationId, action, lastCompletedPhase, mutationStarted, journalPath }` |
| `lifecycleLock` | `{ held, holderDescription }` |
| `findings[]` | Finding |

Правила стану (у порядку пріоритету): відкритий журнал із `mutationStarted`
→ `RollbackRequired`; відкритий журнал без mutation → `InterruptedUpdate`;
кілька roots без явного вибору → `Ambiguous`; немає `VERSION.json` і
runtime-файлів → `NotInstalled`; integrity `Invalid` → `RepairRequired`;
неповні задачі/конфігурація → `Degraded`; канал не `stable` →
`PrereleaseInstalled`; відомий новіший stable (лише якщо target доведено) →
`UpdateAvailable`; інакше `Installed`. `Unsupported` — ОС/PS поза
підтримуваним tier.

## 4. PreflightResult (INS-021)

`{ schemaVersion, generatedUtc, operation: Install|Update|Repair|Diagnose,
runtimeRoot, findings[], canProceed, blockerCount, warningCount,
fingerprint }`. `canProceed = (blockerCount -eq 0)`.

## 5. DeploymentPlan (INS-011)

| Поле | Зміст |
|---|---|
| `schemaVersion`, `planId`, `operationId` | GUID |
| `action` | `Install`, `Update`, `Repair` |
| `createdUtc`, `expiresUtc` | default TTL 30 хв |
| `runtimeRoot`, `stagingRoot`, `backupRoot` | |
| `source` | `{ kind: Online|Offline, tag, artifactName, artifactSha256, manifestSha256, packageVersion, releaseChannel, prereleaseAuthorized }` |
| `currentVersion`, `targetVersion` | |
| `footprint` | `{ stagingBytes, backupBytes, deployBytes, reserveBytes, requiredFreeBytes, availableFreeBytes, volume }` |
| `changes` | `{ filesAdded, filesChanged, filesRemoved, configuration: { localConfigPreserved, legacyConfigPreserved, delta[] }, scheduler: { tasks[], activationPolicy } }` |
| `preserved[]` | Що гарантовано не змінюється (site config, LOGS, state, credentials, backups) |
| `tests` | `{ planned[], skipped[] }` |
| `findings[]` | Warnings/blockers на момент побудови |
| `preconditionsFingerprint` | SHA-256 (hex, upper) канонічного JSON передумов |
| `requiresConfirmation` | завжди `$true` |

Передумови fingerprint-а: SHA-256 `RUNTIME_MANIFEST.json`, `VERSION.json`,
`BRAVO.local.config` (або `absent`), наявність `BRAVO.config`, SHA-256
артефакта й release manifest, перелік керованих задач зі станом enabled,
відсутність відкритого журналу. `Test-BRAVODeploymentPlanCurrent` перераховує
fingerprint і перевіряє expiry; розбіжність → новий preflight і нове
підтвердження.

## 6. ProgressEvent (INS-013)

`{ schemaVersion, operationId, sequence, timestampUtc, phase, status,
percent, messageKey, messageArgs[], message }`

- `phase`: `Preflight`, `Acquire`, `Verify`, `Stage`, `Backup`, `Deploy`,
  `Configure`, `Validate`, `Activate`, `Commit`, `Rollback`, `Recovery`.
- `status`: `Started`, `Progress`, `Heartbeat`, `Completed`, `Failed`,
  `Skipped`.
- `percent`: `$null` (невідомо → indeterminate) або 0–100.
- `sequence` монотонно зростає від 1 у межах операції.
- Потік — JSONL-файл `progress.jsonl` у каталозі операції; один рядок —
  одна подія; запис з flush після кожної події. GUI лише читає.

## 7. DeploymentResult (INS-012)

| Поле | Зміст |
|---|---|
| `schemaVersion`, `operationId` | `operationId` — GUID у нижньому регістрі |
| `planId` | GUID або `$null` (результат recovery і відмови до появи плану) |
| `action` | `Install`, `Update`, `Repair`, `Rollback` (результат `Invoke-BRAVORollback`), `Recovery` (результат `Invoke-BRAVORecovery` і `BRAVO_UPDATE.ps1 -Action Recover`) |
| `status` | `Success`, `SuccessWithWarnings`, `Failed`, `RolledBack`, `Critical` |
| `reasonCode` | Для `Failed` обов'язковий: `Blocked`, `Cancelled`, `PlanStale`, `VerificationFailed`, `Error`; для інших статусів — `$null` або одне з цих значень |
| `exitCode`, `exitCodeName` | Лише через `BRAVO.ExitCodes` |
| `sourceVersion`, `targetVersion`, `installedVersion` | |
| `lastPhase`, `mutationStarted` | |
| `validation[]` | `{ name, status: Pass|Warn|Fail|Skipped, message }` |
| `rollback` | `{ attempted, status: NotNeeded|Succeeded|Failed, message }` |
| `taskActivation` | `{ state: Active|Inactive|Unchanged|Unknown, tasks[] }` |
| `findings[]` | |
| `logPath`, `reportPath`, `journalPath` | |
| `startedUtc`, `finishedUtc` | |

Відображення на коди (`ConvertTo-BRAVOUpdateExitCode`): `Success` → 0;
`SuccessWithWarnings` → 10; `Failed` → `exitCodeHint` першого blocker-а
(20/30/31/33/35/36/37/42) або 80 `DeploymentFailed`; `RolledBack` → 81
`DeploymentRolledBack`; `Critical` → 82 `DeploymentCritical`; невідомий
статус → 80 (fail closed). Конструктор `New-BRAVOUpdateDeploymentResult`
обчислює `exitCode` і `exitCodeName` сам; валідатор відхиляє результат, у
якому `exitCode` не відповідає цьому відображенню. Коди 80–82
додаються в канонічну таблицю `BRAVO.ExitCodes` (severity: 80/81 ERROR,
82 CRITICAL); інших нових кодів немає.

`SuccessWithWarnings` ніколи не відображається як загальний зелений успіх.

## 8. UpdateJournal (INS-014)

Файл `<StateRoot>\Journal\<operationId>.json`.

| Поле | Зміст |
|---|---|
| `schemaVersion`, `operationId`, `planId`, `action` | |
| `state` | `Open`, `Committed`, `RolledBack`, `Critical`, `Abandoned` |
| `runtimeRoot`, `stagingRoot`, `backupRoot`, `artifactSha256` | |
| `sourceVersion`, `targetVersion` | |
| `mutationStarted` | bool |
| `phases[]` | `{ phase, intentUtc, completedUtc, outcome }` |
| `lastCompletedPhase` | Остання фаза з `outcome` не `Failed` |
| `backup` | `$null` або `{ path, manifestSha256, fileCount }` (`Set-BRAVOUpdateJournalBackup`); `path` — каталог `<BackupRoot>\<operationId>` з `runtime\` і `backup-manifest.json` |
| `schedulerSnapshot` | `$null` або `{ path }` (`Set-BRAVOUpdateJournalSchedulerSnapshot`) — JSON `<StateRoot>\Operations\<operationId>\scheduler-snapshot.json` зі станом enabled керованих задач до операції |
| `createdOwnership[]` | Записи про елементи, створені цією операцією (для відкату clean install), синтаксис нижче |
| `createdUtc`, `updatedUtc` | |

Поля вище створює `New-BRAVOUpdateJournal`, і їх вимагає валідатор
`Test-BRAVOUpdateJournal`. Наступні поля **адитивні**: їх додає
`Set-BRAVOUpdateJournalField` (дозволено лише ці імена; поле, якого ще
немає, додається як NoteProperty і одразу персиститься), а `createdTasks` —
також `Add-BRAVOUpdateJournalCreatedTask`. Валідатор їх не вимагає й не
відхиляє; відсутнє поле читається як значення за замовчуванням.

| Поле | Зміст |
|---|---|
| `rollbackAttempts` | int, за замовчуванням 0. `Invoke-BRAVORollback` збільшує його **до** будь-якої дії відкату; при значенні 3 і більше відкат одразу завершується `Critical` |
| `versionState` | `{ present, sha256, recordedVersion, snapshotPath }` — знімок `BRAVO_VERSION_STATE.json` до mutation (`Get-BRAVOVersionStateSnapshot`): точні байти у `<StateRoot>\Operations\<operationId>\version-state.snapshot` або маркер «файлу не було» (`present = $false`, `sha256 = $null`). Якщо поля немає, відкат читає знімок напряму з цього файлу |
| `deployKeys` | `{ sha256 }` — SHA-256 (hex, upper) файлу `<StateRoot>\Operations\<operationId>\deploy-keys.json`; відкат звіряє його перед будь-яким видаленням, розбіжність або відсутність — збій кроку |
| `baseline` | `{ siteConfig, guardExitCode }`: `siteConfig` — результат `Get-BRAVOSiteConfigurationBaseline` (`{ schemaVersion, capturedUtc, runtimeRoot, files[]{ name, sha256 \| 'absent' } }` для `BRAVO.local.config`, `BRAVO.config`, `TOOLS_INTEGRITY.json`, `WinSCP.ini`); `guardExitCode` — код guard до операції (для Repair-відкату guard має повернутися до нього) |
| `createdTasks[]` | `{ path, name }` — задачі, створені операцією; дублікати (без урахування регістру) ігноруються; після невдалої операції лишаються вимкненими (R4) |

Синтаксис записів `createdOwnership[]` (розбирає `Invoke-BRAVOInstallRollback`;
невідомий запис — проблема, відкат не вважається повним):

| Запис | Значення |
|---|---|
| `dir:<шлях\|ключ>` | Каталог, створений операцією; видаляється лише порожнім |
| `file:<ключ>\|<SHA256>` | Файл із записаним хешем; видаляється лише якщо поточний SHA-256 збігається |
| `file:<ключ>` | Файл без хеша; не видаляється (finding `Rollback.OwnedFileUnverified`) |
| `marker:preexistingRoot` | Корінь існував до операції (порожнім); корінь не видаляється. Також приймається застаріла форма `preexistingRoot` |
| `deploykeys:<SHA256>` | Усі deploy-ключі з хешами одним записом: SHA-256 файлу `deploy-keys.json` операції; хеш звіряється, далі кожен ключ трактується як `file:<ключ>\|<SHA256>` |

Правила:

- Атомарний запис: тимчасовий файл у тому ж каталозі з `WriteThrough`, потім
  `File.Replace` (або `File.Move` для нового файлу). Часткового файлу на місці
  журналу ніколи немає.
- Intent записується **до** кожного критичного side effect, `completedUtc` —
  після. Recovery трактує фазу з intent без completion як можливо виконану.
- `mutationStarted = $true` записується до першої зміни runtime.
- Відкритий журнал (`state = Open`) блокує нові операції, крім recovery.
- Recovery v1: повернення до known-good; resume-from-middle не підтримується.

## 9. Lifecycle lock

- `<LockRoot>\BRAVO_UPDATE.lock`, `FileShare.None`, тримається протягом усієї
  операції (`Enter-BRAVOUpdateLifecycleLock -LockRoot -OperationId` /
  `Exit-BRAVOUpdateLifecycleLock -Lock`). Обидві функції повертають
  `{ Success, Stream, Path, Holder, Error }` і не кидають виняток на
  «зайнято». Lock-файл після звільнення не видаляється (видалення відкрило б
  гонку).
- Holder `{ pid, processStartTime, operationId, startedAt }` пишеться в сам
  lock і в sidecar `<LockRoot>\BRAVO_UPDATE.holder.json`. Sidecar потрібен,
  бо `FileShare.None` забороняє конкуренту навіть читати lock-файл; він
  **лише для показу** («хто тримає»): факт «зайнято» визначає тільки
  невдале відкриття lock-файла, застарілий sidecar без зайнятого lock-а
  ніхто не читає. Запис sidecar — best-effort; при звільненні sidecar
  видаляється ще до закриття lock-а.
- Перед mutation engine також бере канонічний `BRAVO_OPERATION.lock`
  (`Enter-BRAVOUpdateOperationLock -OperationLockPath -OperationId
  -PackageVersion`): `FileShare.Read`, той самий JSON-holder, що в
  Archive/Maintenance (`pid`, `processStartTime`, `hostname`,
  `operation = "Update"`, `startedAt`, `packageVersion`, `config = $null`,
  `generationId = operationId`), без циклу очікування. Поки він утримується,
  Archive/Maintenance завершуються з кодом 20. Активний holder → blocker
  «дочекайтеся завершення», ніколи не force-kill.
  `Test-BRAVOUpdateOperationLockActive` перевіряє зайнятість без захоплення
  (непередбачена помилка → `Active = $true`).

## 10. Worker protocol (GUI/CLI ↔ engine)

Реалізація — `modules/BRAVO.Update/BRAVO.Update.Worker.ps1`
(`Invoke-BRAVOUpdateWorker`, `Invoke-BRAVOUpdateCliAction`).

### 10.1 Модель довіри

- Неелевований процес (GUI або CLI без прав) ніколи не виконує mutation
  сам: він лише **пише запит** у `<StateRoot>\Requests\<requestId>.json`
  (без секретів) і запускає `BRAVO_UPDATE.ps1 -Action Execute -RequestPath
  <path> -NoPause` через UAC (`Start-Process powershell.exe -Verb RunAs
  -Wait`). В аргументах лише шляхи; секретів немає.
- Авторизація mutation — це UAC, а не файл запиту: запит **недовірений**.
  Worker не бере на віру жодного кореня з запиту (див. 10.3).
- Процес, що вже має права адміністратора, викликає worker in-process,
  без перезапуску.
- FaultInjection worker і CLI не приймають ні з запиту, ні з аргументів.

### 10.2 Запит

`New-BRAVOUpdateRequest -Plan -ConfirmedPlanShortId [-Option]` будує, а
`Write-BRAVOUpdateRequestFile -Request -StateRoot` записує (`FileMode.CreateNew`,
наявний файл не перезаписується; каталог `Requests` має вже існувати):

```text
{ schemaVersion: 1, requestId: <guid>, planId: <guid>, plan: <DeploymentPlan>,
  confirmedPlanShortId: <перші 8 hex planId>, requestedUtc,
  options: { prereleaseAuthorized: bool, activationPolicy: string,
             runSelfTest: bool,
             backupDestination: '' | Cloud | CloudAndSamba | SambaOnly | LocalOnly,
             sourcePath: string,
             scope: All | Runtime | Scheduler } }
```

- `confirmedPlanShortId` — те, що оператор ввів текстом; якщо воно не
  дорівнює першим 8 hex `planId`, запит не будується (підтвердження не
  підміняється обчисленим значенням).
- `Test-BRAVOUpdateRequest` (не кидає): обов'язкові поля, `schemaVersion = 1`,
  GUID-и в нижньому регістрі, `Test-BRAVOUpdateNoSecretProperty`,
  `Test-BRAVOUpdateDeploymentPlan`, `planId` запиту == `planId` плану, типи
  й допустимі значення `options`.
- `options.backupDestination` обов'язковий для `Install`; `options.scope`
  використовується лише для `Repair`; `options.sourcePath` передається
  операції, лише якщо вона приймає `-SourcePath`.

### 10.3 Перевірки worker-а (усі — до mutation)

1. Процес елевований (інакше `Failed/Blocked`, hint 36, нічого не пишеться);
   `BRAVO_ALLOW_DOWNGRADE` у середовищі → `Failed/Blocked`, hint 35.
2. Запит: лише файл безпосередньо в `<StateRoot>\Requests` з ім'ям
   `<guid>.json`, без reparse point у шляху, не більше 1 MiB (перевіряється
   за `FileInfo` і за фактично прочитаними байтами), коректний UTF-8 і JSON.
   Файл читається **один раз**; далі все працює з копією в пам'яті (TOCTOU).
3. Схема запиту (10.2).
4. Корені: `plan.stagingRoot` і `plan.backupRoot` мають дорівнювати
   `Get-BRAVOUpdateDefaultPaths`; `plan.runtimeRoot` не збігається і не
   перетинається з `StateRoot`/`LockRoot`/`StagingRoot`/`BackupRoot`; для
   `Update`/`Repair` він має бути серед знайдених `Get-BRAVOInstallationState`
   root-ів. Інакше `Failed/Blocked` (`Worker.ForeignRoot`).
5. Replay: існує `<StateRoot>\ConsumedPlans\<planId>` або непорожній
   `<StateRoot>\Operations\<operationId>` → `Failed/PlanStale`
   (`Worker.PlanReplay`), без записів. Worker маркер `ConsumedPlans` лише
   перевіряє; створює його оркестратор операції через `FileMode.CreateNew`
   (крок U3, ENGINE_DESIGN §4.2).
6. Каталог операції `<StateRoot>\Operations\<operationId>\` з
   `control\`; копія запиту — `request.json`.
7. `Test-BRAVODeploymentPlanCurrent` (fingerprint і expiry) →
   інакше `Failed/PlanStale`; blocker-и плану → `Failed/Blocked`.
8. Повторний `Test-BRAVODeploymentPreflight` → blocker-и → `Failed/Blocked`.
9. Dispatch за іменем: `Install` → `Install-BRAVOToolkit`, `Update` →
   `Invoke-BRAVODeployment`, `Repair` → `Repair-BRAVOInstallation`.
   Виняток або відсутній/невалідний результат → `Failed/Error`
   (`Worker.DispatchFailed` / `Worker.ResultInvalid`) з порадою виконати
   `-Action Recover`.

Результат пишеться атомарно в `<StateRoot>\Operations\<operationId>\result.json`
для всіх відмов, починаючи з кроку 6; відмови до кроку 6 існують лише в
пам'яті (і в `-ResultPath`/stdout CLI).

### 10.4 Каталоги протоколу та ACL

`Initialize-BRAVOUpdateStateDirectories -StateRoot` створює відсутні каталоги
(наявні не змінює); DACL захищений, успадкування вимкнено, застосований
DACL перечитується й перевіряється:

| Каталог | ACL |
|---|---|
| `<StateRoot>\Requests` | Administrators, SYSTEM — FullControl; Users — лише створення файлів (`CreateFiles`, `ExecuteFile`, `ReadAttributes`, `Synchronize`, без успадкування): drop box |
| `<StateRoot>\Operations` і кожен `Operations\<operationId>` | Administrators, SYSTEM — FullControl; Users — ReadAndExecute |
| `Operations\<operationId>\control` | як `Operations` + SID запускача (за замовчуванням — користувач поточного процесу) — `CreateFiles`, `ReadAttributes`, `Synchronize` лише на сам каталог: можна створити cancel-файл, не можна читати чи змінювати чужі |
| `<StateRoot>\ConsumedPlans` | лише Administrators і SYSTEM |

Неелевований процес (тести) додатково отримує FullControl для поточного
користувача; в елевованому worker-і такого запису немає. Каталоги протоколу
створює лише процес з правами (CLI викликає ініціалізацію тільки під
адміністратором).

Вміст каталогу операції: `request.json`, `result.json`, `progress.jsonl`
(GUI опитує їх таймером), `logs\` (логи дочірніх процесів після маскування,
наприклад `validate-guard.log`), `deploy-keys.json`,
`scheduler-snapshot.json`, `version-state.snapshot`, `control\`.

Cancel — файл `<StateRoot>\Operations\<operationId>\control\cancel`
(вміст не читається), семантика — ENGINE_DESIGN §2.4.

### 10.5 Credentials

Credentials вводяться лише інтерактивно в окремому видимому консольному
вікні: `powershell.exe -NoProfile -File <runtime>\BRAVO_SETUP.ps1 -Action
Credentials` (він викликає канонічний `BRAVO_CREDENTIALS_SETUP.ps1`). GUI і
engine секретів не бачать; engine лише перевіряє присутність через
`TestCredentialPresence`.
