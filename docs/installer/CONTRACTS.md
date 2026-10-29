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
  `-LockRoot`, `-StagingRoot`, `-BackupRoot`). Production-значення за
  замовчуванням обчислює лише `Get-BRAVOUpdateDefaultPaths`:
  - `StateRoot` = `%ProgramData%\BRAVO\State\Update`
  - `LockRoot` = `%ProgramData%\BRAVO\Locks`
  - `StagingRoot` = `%ProgramData%\BRAVO\Update\Staging`
  - `BackupRoot` = `%ProgramData%\BRAVO\Update\Backup`
  - `RuntimeRoot` (новий сервер) = `C:\Program Files\BRAVO-Toolkit` (чинний
    default `deploy\Install-BRAVOServer.ps1`; див. DECISIONS D4).
  Тести завжди передають sandbox-корені й ніколи не торкаються
  `C:\ProgramData\BRAVO`.
- Зовнішні side effects, які не є файловими операціями engine (запуск
  `BRAVO_SETUP.ps1`, guard, self-test, читання й увімкнення задач,
  перевірка credentials), виконуються через **adapter** — hashtable
  scriptblock-ів (`New-BRAVOUpdateDefaultAdapter`). Тести й failure injection
  підставляють stub-и. Ключі adapter-а:
  `InvokeGuard`, `InvokeSetupScheduler`, `InvokeSetupValidate`,
  `InvokeSelfTest`, `GetManagedTasks`, `SetTaskEnabled`,
  `TestCredentialPresence`, `GetEffectiveConfiguration`, `Now`.

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
| `schemaVersion`, `operationId`, `planId`, `action` | |
| `status` | `Success`, `SuccessWithWarnings`, `Failed`, `RolledBack`, `Critical` |
| `reasonCode` | Для `Failed`: `Blocked`, `Cancelled`, `PlanStale`, `VerificationFailed`, `Error` |
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
`DeploymentRolledBack`; `Critical` → 82 `DeploymentCritical`. Коди 80–82
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
| `lastCompletedPhase` | |
| `backup` | `{ path, manifestSha256, fileCount }` |
| `schedulerSnapshot` | `{ path }` — JSON зі станом enabled керованих задач до операції |
| `createdOwnership[]` | Ключі файлів/каталогів, створених цією операцією (для clean-install rollback) |
| `createdUtc`, `updatedUtc` | |

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
  операції (`Enter-BRAVOUpdateLifecycleLock` / `Exit-BRAVOUpdateLifecycleLock`).
- Перед mutation engine також бере канонічний `BRAVO_OPERATION.lock` у тому
  самому форматі JSON-holder (`operation = "Update"`), щоб Archive/Maintenance
  не стартували посеред deploy (вони завершаться з кодом 20). Активний
  holder → blocker «дочекайтеся завершення», ніколи не force-kill.

## 10. Worker protocol (GUI ↔ engine)

- GUI працює без elevation і ніколи не виконує mutation сам.
- Для mutation GUI зберігає план і запит у `<StateRoot>\Requests\<planId>.json`
  (без секретів) і запускає `BRAVO_UPDATE.ps1 -Action Execute -RequestPath
  <path>` через UAC (`Start-Process -Verb RunAs`). Шлях — єдиний аргумент;
  секретів в аргументах немає.
- Worker: перечитує запит, перевіряє схему, `planId` ще не використаний
  (реєстр `<StateRoot>\ConsumedPlans\`), план не прострочений, fingerprint
  поточний, повторно виконує preflight. Інакше — `Failed/PlanStale` без
  mutation.
- Worker пише `progress.jsonl` і `result.json` у
  `<StateRoot>\Operations\<operationId>\` (ACL: Administrators/SYSTEM — full,
  Users — read). GUI опитує їх таймером.
- Credentials вводяться лише через канонічний інтерактивний
  `BRAVO_CREDENTIALS_SETUP.ps1` у видимому консольному вікні; GUI і engine
  секретів не бачать.
