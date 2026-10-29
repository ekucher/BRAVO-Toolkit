# BRAVO.Update — дизайн mutation-частини engine (Installer v1)

Статус: implementation design для хвилі 2 гілки `feature/installer-v1`.
Обов'язковий контракт — `docs/installer/CONTRACTS.md`; рішення, що чекають
затвердження, — `docs/installer/DECISIONS.md`. Розділ 1 — перевірені факти,
розділ 13 — відкриті рішення.

## 1. Перевірені факти

| # | Факт | Де |
|---|---|---|
| F1 | Повторна реєстрація задач завжди вмикає задачу (`Settings.Enabled = $true`, після `RegisterTaskDefinition` скрипт падає, якщо задача не `Enabled`). `BRAVO_SETUP -Action Scheduler` знову вмикає всі задачі, увімкнені в конфігурації. | `BRAVO_TASKS_INSTALL.ps1:636`, `:1443-1455` |
| F2 | `BRAVO_TASKS_INSTALL` у catch сам відкочує визначення задач; legacy-задачі видаляються `DeleteTask` без знімка. | `:1557-1589`, `:1486-1510` |
| F3 | `Set-BRAVOProtectedRuntimeAcl` (рекурсивно: Administrators FC, SYSTEM FC, Users RX, власник Administrators) викликається лише з `BRAVO_TASKS_INSTALL` без `-ValidateOnly`, тобто через `BRAVO_SETUP -Action Scheduler`. | `:67-153`, `:1258-1259` |
| F4 | `BRAVO_SETUP -Action Scheduler` також запускає Credential Test і `BRAVO_TASKS_DIAGNOSE` (тимчасова SYSTEM-задача). Без `-SkipAccessTest` додається `-TestAccess`, без `-SkipTestNotification` — `-SendTestNotification`. Exit лише 0/1 через `Complete-BRAVOHelperLog` (`exit`). | `BRAVO_SETUP.ps1:696-769`, `:784/806` |
| F5 | Прямий запуск guard викликає `Test-BRAVOVersionDowngrade -NoWrite`. Entrypoint-и ARCHIV, MAINTENANCE, HEALTH, CONFIGURATOR, DATA_RESTORE, RESTORE_TEST, BAZA_RECONCILE, OPERATIONS_HEARTBEAT викликають її без `-NoWrite`, ще до операційного lock; запис state неатомарний. | `BRAVO_RUNTIME_GUARD.ps1:884-919`, `:996-1000` |
| F6 | `Invoke-BRAVODeployExactRestore` будує owned-набір із дерева staged ∪ нового ∪ старого manifest; reparse-перевірок немає. | `deploy/BRAVO.Deploy.Rollback.ps1:147-254` |
| F7 | Legacy update виключає `BRAVO.config`, `BRAVO.local.config`, `TOOLS_INTEGRITY.json`, `WinSCP.ini`, `BRAVO_OPERATION.lock` і `LOGS`, `MODEL`, `BLOG`, `BRAVOEXCH`, `BAZA`, `BAZA_WWW`, `artifacts`. | `deploy/Update-BRAVOServer.ps1:544-546` |
| F8 | Коди 80/81/82 є в `BRAVO.ExitCodes`. | |
| F9 | `BRAVO.config` в артефакті відсутній. | |

## 2. Спільне ядро

### 2.1 Контекст операції

Стану `$script:` немає. `New-BRAVOUpdateOperationContext -Plan -Adapter -Paths
-OperationDirectory -Journal [-FaultInjection]` (частина Deploy) повертає
`{ OperationId, Plan, Adapter, Paths{RuntimeRoot, StateRoot, LockRoot,
StagingRoot, BackupRoot, OperationLockPath, VersionStatePath},
OperationDirectory, Journal, ProgressWriter, CancelRequested, MutationStarted,
Findings (List), Validation (List), Handles{LifecycleLock, OperationLock},
FaultInjection }`.

`Get-BRAVOUpdateDefaultPaths` повертає також `VersionStatePath =
%ProgramData%\BRAVO\State\BRAVO_VERSION_STATE.json`. Тести завжди передають
sandbox-шлях.

### 2.2 Виконавець фаз (частина Deploy)

`Invoke-BRAVOUpdatePhase -Context -Phase -ProgressPhase -Action <scriptblock>
[-Durable]`: cancel-перевірка → fault `<Phase>.Before` → (durable) intent у
журнал → fault `.AfterIntent` → `Action` → fault `.AfterSideEffect` (crash між
side effect і completion) → completion у журнал → ProgressEvent `Completed` →
fault `.AfterComplete`.

### 2.3 FaultInjection

`hashtable`, ключ `'<Phase>.<Point>'`, значення `Throw` | `Crash` | `Cancel`;
`Deploy.AfterFileCount = N` кидає після N файлів. `Crash` кидає
`BRAVOUpdate.SimulatedCrash`, який orchestrator НЕ перехоплює для rollback
(журнал лишається `Open`, у `finally` лише handle-и); тест потім викликає
`Invoke-BRAVORecovery`. Обробка — приватна `Invoke-BRAVOUpdateFaultPoint`.
Worker і CLI ніколи не читають FaultInjection з request чи аргументів.
Збої зовнішніх side effect-ів — через stub-адаптер.

### 2.4 Cancel

Файл `<OperationDirectory>\control\cancel` (вміст не читається; каталог з ACE
`CreateFiles` для SID запускача). До `mutationStarted` → `Failed/Cancelled`,
журнал `Abandoned`, staging/backup операції видаляються. Після → поточна фаза
завершується, далі rollback, `RolledBack` + finding
`Operation.CancelledAfterMutation`. Після початку `Activate` cancel
ігнорується з finding.

### 2.5 API хвилі 1 (фактичні імена)

- Contracts/Journal: `New-BRAVOUpdateFinding`, `New-BRAVOUpdateDeploymentResult`,
  `ConvertTo-BRAVOUpdateExitCode`, `New-BRAVOUpdateJournal`,
  `Write-BRAVOUpdateJournal`, `Read-BRAVOUpdateJournal`,
  `Get-BRAVOUpdateOpenJournal`, `Add-BRAVOUpdateJournalPhaseIntent`,
  `Complete-BRAVOUpdateJournalPhase`, `Set-BRAVOUpdateJournalMutationStarted`,
  `Set-BRAVOUpdateJournalState`, `Add-BRAVOUpdateJournalCreatedOwnership`,
  `Write-BRAVOUpdateFileAtomic`, `Write-BRAVOUpdateProgressEvent -Path -Event`,
  `New-BRAVOUpdateProgressWriter`.
- Lock: `Enter-/Exit-BRAVOUpdateLifecycleLock -LockRoot -OperationId`;
  `Enter-/Exit-BRAVOUpdateOperationLock -OperationLockPath -OperationId
  -PackageVersion` → `{Success, Stream, Path, Holder, Error}`;
  `Test-BRAVOUpdateOperationLockActive`.
- Staging/Release: `New-BRAVOUpdatePrivateDirectory -Path` →
  `{Success, Path, Problems}`; `Expand-BRAVOUpdateArchiveSafe -ZipPath
  -DestinationRoot -ExpectedSha256`; `Save-BRAVOReleaseArtifact`,
  `Get-BRAVOOfflineReleaseSource`, `Test-BRAVOReleaseArtifact`,
  `Test-BRAVOStagedRuntime`; `Get-BRAVOUpdateDirectorySize`,
  `Get-BRAVOUpdateFreeSpace`, `Test-BRAVOUpdatePathHasReparsePoint`.
- Plan/Preflight: `Test-BRAVODeploymentPlanCurrent`, `Test-BRAVODeploymentPreflight`,
  `Get-BRAVOUpdateSiteOwnedPaths` → `{Files, Dirs}` — ЄДИНЕ джерело
  site-owned виключень для Backup/Deploy/Rollback (семантика robocopy `/XF`
  `/XD` на будь-якій глибині через `Test-BRAVODeployPathExcluded`).

### 2.6 Каталоги операції

| Каталог | Вміст |
|---|---|
| `<StagingRoot>\<opId>\` | payload і staged runtime |
| `<BackupRoot>\<opId>\` | `runtime\`, `backup-manifest.json` |
| `<StateRoot>\Operations\<opId>\` | `progress.jsonl`, `result.json`, `request.json`, `deploy-keys.json`, `scheduler-snapshot.json`, `version-state.snapshot`, `logs\`, `control\` |

Видалення — лише приватна `Remove-BRAVOUpdateOperationDirectory -Path
-ExpectedParent -OperationId` (leaf = opId, parent = очікуваний корінь,
reparse point видаляється як link без обходу цілі). Інших рекурсивних delete
немає.

## 3. Backup

`New-BRAVORuntimeBackup -RuntimeRoot -BackupRoot -OperationId [-FaultInjection]`
→ `{ Path, ManifestPath, ManifestSha256, FileCount, TotalBytes, Problems[] }`;
`Test-BRAVORuntimeBackup -BackupPath -ManifestPath -ExpectedManifestSha256
[-CompareRuntimeRoot]` → `{ IsValid, Problems[], FileCount }`.

1. `<BackupRoot>\<opId>\` через `New-BRAVOUpdatePrivateDirectory`; існує → відмова.
2. Reparse point у дереві runtime поза виключеннями → blocker `Backup.ReparsePoint`.
3. `Get-BRAVODeployTreeKeys` з виключеннями; потокове копіювання з SHA-256 на льоту.
4. Атомарно `backup-manifest.json`: `{schemaVersion, operationId,
   sourceRuntimeRoot, createdUtc, excludeFiles, excludeDirs, files{key:SHA256},
   fileCount, totalBytes}`.
5. Verify: повторний хеш backup проти manifest і проти live runtime;
   `runtime\RUNTIME_MANIFEST.json` присутній.
6. Журнал `backup{path, manifestSha256, fileCount}`. Фаза durable;
   компенсація — видалення каталогу операції (до mutation).

Тести: 0/1/N файлів; пробіли й кирилиця; виключені каталоги не в backup;
reparse → blocker; підміна в backup → `IsValid=$false`; повтор для того самого
opId → відмова.

## 4. Deploy і orchestrator

### 4.1 Файловий набір

`Get-BRAVODeploymentFileSet -StagedRoot -RuntimeRoot -OldManifestPath` (лише
читання) → `DeployKeys{key:sha}`, `Add[]`, `Change[]`, `Unchanged[]`,
`Remove[]` (ключі старого manifest без відповідника в staged — доведено
manifest-owned), `UnknownScripts[]` (`.ps1/.psm1/.psd1` поза обома manifest →
blocker `Deploy.UnknownScript` до mutation), `UnknownOther[]` (Warning,
лишаються), `NamespaceViolations[]` (staged-ключ у виключеному просторі →
blocker), `ReparsePoints[]` (blocker).

`Save-BRAVODeploymentKeySet -FileSet -OperationDirectory` → `{Path, Sha256}`.
`Invoke-BRAVORuntimeDeploy -Context -StagedRoot -FileSet` → `{Copied[],
Removed[], Errors[]}`: `Copy-BRAVOUpdateVerifiedFile -Source -Destination
-ExpectedSha256` (потік, хеш на льоту, розбіжність = виняток), далі видалення
`Remove[]`, порожні каталоги знизу вгору (корінь ніколи). Повторне hardening
ACL робить Scheduler-крок (F3).

### 4.2 Orchestrator

`Invoke-BRAVODeployment -Plan -Adapter [-RuntimeRoot -StateRoot -LockRoot
-StagingRoot -BackupRoot -OperationLockPath -VersionStatePath] [-SourcePath]
[-FaultInjection]` → DeploymentResult. Дії `Update` і `Repair`.

| Крок | Дія | Межа |
|---|---|---|
| U0 | `Test-BRAVODeploymentPlanCurrent` | → `Failed/PlanStale` |
| U1 | lifecycle lock | зайнято → `Failed/Blocked`, 20 |
| U2 | журнал `Open` | blocker «Recover» |
| U3 | `<StateRoot>\ConsumedPlans\<planId>` через `FileMode.CreateNew` | → `PlanStale` (replay) |
| U4 | каталог операції; журнал `Open`, `mutationStarted=false` | crash = `InterruptedUpdate` |
| U5 | Acquire → Verify → Stage проти `plan.source.*Sha256` | фази `Acquire`, `Stage` |
| U6 | staged-валідація (`Test-BRAVOStagedRuntime`, версія/commit == план, файловий набір без blocker-ів, `deploy-keys.json`) | |
| U7 | повторно `Test-BRAVODeploymentPlanCurrent` | |
| U8 | Backup | durable |
| U9 | `Enter-BRAVOUpdateOperationLock`; повторно `GetManagedTasks`: running → `Failed/Blocked` 20, журнал `Abandoned` | до межі навмисно |
| U10 | baseline: знімок version-state, scheduler, site-config, guard baseline | |
| U11 | `mutationStarted = $true` | **MUTATION BOUNDARY** |
| U12 | `QuiesceTasks`: вимкнути лише `enabled=true` зі знімка | durable |
| U13 | `Deploy` | durable |
| U14 | `ConfigureScheduler` | durable |
| U15 | `Validate` | |
| U16 | остання cancel-перевірка | |
| U17 | `Activate` | durable |
| U18 | журнал `Committed`; release operation lock; видалити staging; backup зберігається | `Commit` |
| U19 | `finally`: lifecycle lock | |

Збій до U11 → `Failed` (`Blocked|VerificationFailed|Cancelled|Error`), журнал
`Abandoned`, staging/backup операції видаляються. Після U11 →
`Invoke-BRAVORollback`. Збій в `Activate` після успішного `Validate` →
`SuccessWithWarnings`, `taskActivation.state = Unknown`, без rollback.

Тести: повний успіх у sandbox зі stub-адаптером; `Throw` у кожній фазі (до U11
— runtime незмінний за хешем, після — `RolledBack`); unknown script; tamper
staged; зайнятий lock; replay; cancel до/після межі; видалення файлу старого
manifest при збереженні невідомого не-скрипта.

## 5. Reconcile: конфігурація, scheduler, активація

- `Get-BRAVOSiteConfigurationBaseline -RuntimeRoot` → SHA-256 (або `absent`)
  `BRAVO.local.config`, `BRAVO.config`, `TOOLS_INTEGRITY.json`, `WinSCP.ini`;
  `Test-BRAVOSiteConfigurationPreserved -RuntimeRoot -Baseline` → validation
  entry `SiteConfigPreserved` (розбіжність = `Fail`).
- `Get-BRAVOSchedulerSnapshot -Adapter -RuntimeRoot` → `{schemaVersion,
  capturedUtc, taskPath, tasks[]{path, name, exists, enabled, state,
  isRunning}}` (імена й TaskPath з ефективної конфігурації через адаптер, не
  hardcode); `Save-BRAVOSchedulerSnapshot`.
- `Suspend-BRAVOManagedTasks -Snapshot -Adapter` → `{Disabled[], Failed[]}`
  (будь-який `Failed` = збій фази).
- `Invoke-BRAVOSchedulerReconcile -Context -Snapshot` → `{Verdict, ExitCode,
  CreatedTasks[], RequiescedTasks[], Problems[]}`: `InvokeSetupScheduler`
  (verdict через `Get-BRAVODeploySetupExitVerdict`), **одразу** після —
  вимкнути всі увімкнені керовані задачі (F1); `CreatedTasks` у журнал.
- `Restore-BRAVOManagedTaskState -Snapshot -Adapter` → `{Restored[], Failed[],
  IsComplete}` — вмикає лише ті, що мали `enabled=true`; ідемпотентна.
- `Disable-BRAVOAllManagedTasks -Adapter` — шлях `Critical` (best-effort).
- Адаптер `SetTaskEnabled` за замовчуванням — COM `Schedule.Service`
  (`GetFolder().GetTask().Enabled`), лише TaskPath з ефективної конфігурації і
  лише керовані імена, інакше виняток.
- `Set-BRAVOTaskActivation -Policy -Snapshot -Adapter -OutcomeStatus` →
  `taskActivation` (D6): Update/Repair + Success → відновити попередній стан;
  Update/Repair + SuccessWithWarnings → `Inactive` + finding, якщо план не має
  `activationPolicy = ActivateOnWarnings`; Install → `Inactive`; Critical →
  ніколи не вмикати.

## 6. Validation

Приватний `Invoke-BRAVOUpdateChildProcess -FilePath -Arguments -WorkingDirectory
-TimeoutSeconds -LogPath` → `{ExitCode, TimedOut, LogPath}`:
`System.Diagnostics.Process`, `powershell.exe -NoProfile -NonInteractive
-ExecutionPolicy RemoteSigned -File ...` (без Bypass), вивід у
`<opDir>\logs\` після `Protect-BRAVOLogSecret`; за таймаутом завершується лише
власний процес за PID об'єкта.

Адаптери за замовчуванням: `InvokeGuard` (direct run = `-NoWrite`, F5);
`InvokeSetupValidate` (`-ValidateOnly -SkipAccessTest -SkipTestNotification
-NoElevation -NoPause`); `InvokeSetupScheduler` (`-Action Scheduler
-SkipTestNotification -NoElevation -NoPause`); `InvokeSelfTest` лише якщо
заплановано. `BRAVO_SETUP` ніколи не виконується в процесі engine.

`Test-BRAVODeploymentValidation -Context -Mode Deploy|Rollback|Install|Repair
-ExpectedVersion -ExpectedManifestPath -SiteBaseline [-GuardBaselineExitCode]` →
`{Status Pass|Warn|Fail, Items[]}`: `VersionJson`, `RuntimeManifest`, `Guard`
(0; для Repair-rollback = baseline), `SetupValidate` (Install: FAIL → Warn,
бо credentials ще не введено), `SelfTest`, `SiteConfigPreserved`, для Install
`TestCredentialPresence` (Missing → Warn).

## 7. Rollback і version-state

### 7.1 Проблема

`highestVersion` пише будь-який entrypoint без `-NoWrite` (F5), і guard пише
стан до перевірки lock. Задача, ввімкнена canonical-реєстрацією (F1), або
ручний запуск оператора може зафіксувати target; відновлений старий runtime
тоді блокується кодом 35, а `BRAVO_ALLOW_DOWNGRADE=1` заборонено.

### 7.2 Рішення

1. Engine нічого не пише в state; validation викликає guard лише direct run;
   `BRAVO_UPDATE.ps1` викликає `Test-BRAVOVersionDowngrade -NoWrite`.
2. На U10 `Get-BRAVOVersionStateSnapshot -VersionStatePath -OperationDirectory`
   → `{present, sha256, recordedVersion, snapshotPath}` (точні байти або
   маркер `absent`).
3. `Restore-BRAVOVersionState -Snapshot -VersionStatePath -SourceVersion
   -TargetVersion` → `{Action NoChange|Restored|Refused, Message}`: sha ==
   знімок → `NoChange`; recorded == target або ≤ target і > знімка → атомарно
   повернути байти знімка (або видалити файл, якщо знімок `absent`); recorded >
   target → `Refused` → rollback завершується `Critical`; пошкоджений →
   повернути знімок.
4. `BRAVO_ALLOW_DOWNGRADE` ніде не встановлюється; engine відмовляє, якщо
   змінна присутня в середовищі процесу.

Ризик: залежність від формату state-файлу; ACL після `File.Replace` перевірити
на VM. Новий клас загрози не виникає: адміністратор і так може змінити цей
файл (`THREAT_MODEL.md`).

### 7.3 Rollback

`Invoke-BRAVORollback -Journal [-Context] -Adapter -StateRoot -LockRoot
-OperationLockPath -VersionStatePath [-FaultInjection]` → DeploymentResult
(`RolledBack` | `Critical`). Кожен крок durable і повторюваний:

1. Операційний lock (повторно, якщо немає).
2. `journal.action = Install` → розділ 9.3.
3. `Rollback.RestoreFiles`: `Invoke-BRAVODeployExactRestore ... -OwnedKeyList
   <deploy-keys>` (additive параметр у `deploy/BRAVO.Deploy.Rollback.ps1`;
   без нього поведінка legacy незмінна; SHA `deploy-keys.json` звіряється з
   журналом).
4. `Rollback.RestoreVersionState` (7.2).
5. Верифікація: `Test-BRAVODeployRuntimeMatchesManifest` проти
   `backup\runtime\RUNTIME_MANIFEST.json`; кожен ключ backup-manifest збігається
   за хешем; deploy-ключі, яких немає в backup, відсутні.
6. `Rollback.Scheduler` лише якщо `ConfigureScheduler` мав intent:
   `InvokeSetupScheduler` з відновленого runtime, вимкнути все знову;
   `CreatedTasks` лишаються вимкненими.
7. `Test-BRAVODeploymentValidation -Mode Rollback`.
8. `Rollback.RestoreTasks` — лише якщо 3–7 пройшли.
9. Журнал `RolledBack`, release lock.

Збій будь-якого кроку → `Disable-BRAVOAllManagedTasks`, журнал `Critical`,
результат 82; backup і знімки лишаються; `rollbackAttempts` у журналі, після
трьох — одразу `Critical`.

## 8. Recovery і Repair

`Invoke-BRAVORecovery -StateRoot -LockRoot -OperationLockPath -Adapter
[-VersionStatePath] [-FaultInjection]`: lifecycle lock (зайнято → 20) →
`Get-BRAVOUpdateOpenJournal`: 0 → `Success` «не потрібне»; >1 → `Failed/Blocked`
«ручний аналіз»; нечитаний → `Critical` без змін; `mutationStarted=false` →
прибрати staging/backup операції, журнал `Abandoned`, `Failed` 80;
`mutationStarted=true` → `Invoke-BRAVORollback`. Після recovery — лише новий
preflight і новий план. Crash після `Validate`/під час `Activate` теж
закінчується rollback (R1).

`Repair-BRAVOInstallation -Plan -Adapter [roots] [-Scope All|Runtime|Scheduler]
[-FaultInjection]` — ядро `Invoke-BRAVODeployment` з `action = Repair`:
staged `packageVersion`, `sourceCommit`, `buildId` == встановлений
`VERSION.json` (інакше `Repair.VersionMismatch`; нечитаний → `Repair.IdentityUnproven`);
integrity `Invalid` дозволена; unknown scripts лишаються blocker-ом; scope
`Scheduler` пропускає U5–U8 і U13, rollback лише відновлює enabled-стани;
rollback-валідація: runtime == backup, guard == baseline, повідомлення
«runtime лишився пошкодженим, як і до repair».

## 9. Clean install

### 9.1 Транзакція

`Install-BRAVOToolkit -Plan -Adapter -BackupDestination
Cloud|CloudAndSamba|SambaOnly|LocalOnly [roots] [-FaultInjection]`:

1. U0–U7 без backup.
2. Політика кореня: абсолютний локальний фіксований диск, не UNC, не корінь
   диска, не під `%SystemRoot%` і не в профілі (правило
   `BRAVO_TASKS_INSTALL.ps1:70-83`), без reparse у предках, не перетинається
   зі State/Staging/Backup; корінь не існує або порожній.
3. U9, U10, U11.
4. `CreateRuntimeRoot` (durable): `Directory.CreateDirectory(path,
   DirectorySecurity)` з тими самими трьома правилами, що
   `Set-BRAVOProtectedRuntimeAcl`; `createdOwnership` += `dir:<root>`;
   наперед існуючий порожній корінь → маркер `preexistingRoot`, не видаляється.
5. `Deploy` (durable): до копіювання — один запис `createdOwnership` з усіма
   deploy-ключами (з хешами) і каталогами.
6. `SeedLocalConfig` (durable): intent `file:BRAVO.local.config`;
   `Get-BRAVOConfiguratorBackupDestinationProfile` →
   `New-BRAVOConfiguratorSeedLocalConfig` у child-процесі зі staged-перевіреного
   runtime; `Created=$false` = збій; хеш у журнал.
7. Scheduler лише якщо `TestCredentialPresence(Required) == Found`; інакше
   finding `Install.SchedulerDeferred`.
8. `Validate -Mode Install` → `Commit`, `taskActivation = Inactive`.

### 9.2 Credentials

Engine секретів не бачить. Після commit CLI/GUI відкриває видиме консольне
вікно `powershell.exe -NoProfile -File <runtime>\BRAVO_SETUP.ps1 -Action
Credentials`; далі Repair `-Scope Scheduler`; далі явна активація (D6).

### 9.3 Відкат install

Вимкнути створені задачі → видалити файли з `createdOwnership` (найглибші
першими, лише якщо хеш == записаному; інакше лишити + finding) → видалити лише
порожні створені каталоги → корінь лише якщо створений операцією і порожній →
version-state за 7.2. «Наш» файл лишився → `Critical`; лишилися лише чужі →
`RolledBack` + Warning. Рекурсивного видалення немає.

## 10. Worker і `BRAVO_UPDATE.ps1`

### 10.1 Worker

`Invoke-BRAVOUpdateWorker -RequestPath [-Adapter] [-Paths]`:

1. `Test-IsAdministrator`, інакше 36 без записів.
2. Шлях лише `<StateRoot>\Requests\<guid>.json`, не reparse, ≤ 1 MiB; читається
   один раз, копія в `<opDir>\request.json`.
3. Request `{schemaVersion, requestId, planId, plan, confirmedPlanShortId,
   requestedUtc, options{prereleaseAuthorized, activationPolicy, runSelfTest,
   backupDestination, sourcePath}}`; `Test-BRAVOUpdateNoSecretProperty`,
   `Test-BRAVOUpdateDeploymentPlan`, `confirmedPlanShortId` == перші 8 hex `planId`.
4. Roots з request не беруться на віру: staging/backup == `Get-BRAVOUpdateDefaultPaths`;
   runtime == знайдений root (Update/Repair) або проходить політику кореня (Install).
5. Plan current + повторний preflight; інакше `PlanStale`/`Blocked` без mutation.
6. Dispatch → `Install-BRAVOToolkit` | `Invoke-BRAVODeployment` |
   `Repair-BRAVOInstallation`; `result.json` атомарно.

ACL: `Operations\<id>` — Administrators/SYSTEM FC, Users RX; `control\` —
`CreateFiles` для SID запускача; `Requests\` — Users створюють (request
недовірений, авторизація — UAC); `ConsumedPlans\` — Administrators/SYSTEM.

### 10.2 CLI

`BRAVO_UPDATE.ps1` (≤ ~250 рядків): `-Action
State|Preflight|Plan|Execute|Install|Update|Repair|Recover|Diagnose`,
`-RuntimeRoot`, `-SourcePath | -Tag`, `-AllowPrerelease`, `-BackupDestination`,
`-Scope`, `-PlanPath`, `-RequestPath`, `-ConfirmPlanId`, `-AsJson`,
`-ResultPath`, `-NonInteractive`, `-NoPause` (останній).

Guard-блок з `BRAVO_CONFIGURATOR.ps1:15-126`, але `Test-BRAVOVersionDowngrade
-NoWrite`; integrity завжди `Enforce`. Потік Install/Update/Repair: preflight →
plan → показ через `BRAVO.Console` → підтвердження (інтерактивно — короткий id;
неінтерактивно — лише `-PlanPath` + `-ConfirmPlanId`, інакше 80) → request →
у елевованому процесі worker in-process, інакше `Start-Process powershell.exe
-Verb RunAs -Wait ... -Action Execute -RequestPath <p> -NoPause` → код з
`result.json`. Відкат закомічених версій у v1 не підтримується (це downgrade).

Коди: State/Diagnose 0; Preflight/Plan 0, 10 або `exitCodeHint` першого
blocker-а; Execute/Recover — `ConvertTo-BRAVOUpdateExitCode`; без прав 36; lock 20;
неправильне використання 80. `-AsJson` — у stdout лише контрактний JSON.

## 11. Недоліки canonical коду та мінімальні рішення

- P1 F1: одразу після реєстрації engine вимикає задачі знову; вікно лишається.
  Рекомендація — окремий пакет scheduler-домену `-RegisterDisabled` (R6).
- P1 F5: знімок і відновлення version-state (7.2); CLI/engine лише `-NoWrite`.
- P1 F2: legacy-задачі видаляються без знімка → preflight blocker
  `Scheduler.LegacyTasksPresent`.
- P2 F4: завжди `-SkipAccessTest -SkipTestNotification -NoElevation -NoPause`;
  ніколи з Diagnose/Preflight.
- P2 немає canonical API вмикання задач → обмежений COM-адаптер.
- P2 `Complete-BRAVOHelperLog` викликає exit → лише child-процеси.
- P2 немає reparse-перевірок у `Resolve-BRAVODeployTargetPath` → сканування до mutation.
- `BRAVO_OPERATION.lock` береться на U9, до `mutationStarted`: інакше зайнятий
  lock давав би фіктивний `RolledBack`.

## 12. Пакети хвилі 2

| Пакет | Файли | Suite |
|---|---|---|
| E1 | `BRAVO.Update.Backup.ps1` | `UpdateBackup` |
| E2 | `BRAVO.Update.Deploy.ps1` | `UpdateDeploy` |
| E3 | `BRAVO.Update.Reconcile.ps1` | `UpdateReconcile` |
| E4 | `BRAVO.Update.Validation.ps1` | `UpdateValidation` |
| E5 | `BRAVO.Update.Rollback.ps1` + additive `-OwnedKeyList` у `deploy/BRAVO.Deploy.Rollback.ps1` | `UpdateRollback` |
| E6 | `BRAVO.Update.Recovery.ps1`, `BRAVO.Update.Repair.ps1` | `UpdateRecovery` |
| E7 | `BRAVO.Update.Install.ps1` | `UpdateInstall` |
| E8 | `BRAVO.Update.Worker.ps1`, `BRAVO_UPDATE.ps1` | `UpdateWorker` |

## 13. Відкриті рішення

| # | Рішення | Пропозиція |
|---|---|---|
| D6 | Активація для SuccessWithWarnings і Install | розділ 5 |
| R1 | Crash після `Validate`: rollback чи commit без активації | rollback |
| R2 | Чи дозволяти Repair при `Critical`-журналі з `-AcknowledgeCriticalOperationId` | дозволяти |
| R3 | Repair при нечитаному `VERSION.json` | blocker |
| R4 | Задачі, створені невдалою операцією: вимикати чи видаляти | вимикати |
| R5 | Retention backup-ів | ручне прибирання |
| R6 | `-RegisterDisabled` у scheduler-домені | окремий пакет |
| R7 | `Warn`-режим downgrade-перевірки для `Recover` | на security-рев'ю |
