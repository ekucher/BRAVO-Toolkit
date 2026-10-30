# Інвентар machine-wide ресурсів self-test (OPT-11)

Статус: **аналіз, P3, потребує окремого рішення власника**. Код не змінено,
required CI не змінюється. Внутрішньопроцесна паралелізація заборонена
(`docs/engineering/testing-validation.md`); тут оцінюється лише запуск
окремих процесів або окремих CI-job-ів.

База аналізу: `1c45476c`. Метод: `grep` по `BRAVO_SELF_TEST.ps1` і
`selftest/*.ps1` з ручною перевіркою контексту. Номери рядків відповідають
цій базі. Інвентар не вичерпний для шляхів, збудованих динамічно; такі місця
позначено «не перевірено».

## 1. Підсумок

Переважна більшість self-test ізольована: фікстури лежать у каталогах з
`NewGuid()`, а служби, Планувальник, реєстр і Credential Manager замінено
заглушками. Реальних machine-wide точок мало:

| Ресурс | Де | Спільний між процесами? | Висновок |
| --- | --- | --- | --- |
| Credential Manager, фіксований target `BRAVO_PILOT_SELFTEST_F23_EXISTS` (`cmdkey /delete`, `/generic`, `/delete`) | `selftest/BRAVO_SELF_TEST.ConfigV2PilotArtifact.ps1:679-693` | так, фіксоване ім'я | лише один процес за раз; скрипт уже окремий CI job (`.github/workflows/config-v2-pilot-artifact.yml:51`) |
| Named mutex `Global\BRAVOConfigV2Pilot-<sha256(InstallRoot)>` | `deploy/BRAVOConfigV2Pilot.Runtime.ps1:1252`; використання `ConfigV2PilotArtifact.ps1:907-925` | `Global\`, але ім'я залежить від шляху в GUID-каталозі | колізій між процесами немає |
| Named mutex `Global\BRAVOOperationsEnrollmentClaim-<sha256(StatePath)>` | `modules/BRAVO.Operations/BRAVO.Operations.psm1:388`; тест `selftest/BRAVO_SELF_TEST.Operations.ps1:843-880` | `Global\`, ім'я від шляху в `$opsSelfTestRoot` | колізій немає, якщо `$opsSelfTestRoot` унікальний (унікальність не перевірено окремо) |
| Журнал helper-а `<корінь репозиторію>\LOGS\HELPERS\<скрипт>_yyyyMMdd_HHmmss_fff_PID<PID>.log` | `BRAVO_SELF_TEST.ps1:164`, `modules/BRAVO.HelperLogging/BRAVO.HelperLogging.psm1:58` | каталог спільний у чекауті, імена файлів — ні | ім'я містить `$PID`, тож паралельні процеси не конфліктують за файл |
| Ротація журналів helper-а за `RetentionDays` | `modules/BRAVO.HelperLogging/BRAVO.HelperLogging.psm1:61-66` | так, видаляє старі `*.log` у спільному каталозі | при старті будь-якого процесу видаляються лише файли старші за поріг; журнали поточних процесів не зачіпаються; вплив на вердикт не очікується |
| Фіксовані імена в `%TEMP%`: `BRAVO_VSS_selftest_1/2` (`BRAVO_SELF_TEST.ps1:11989-11990`), `fallbacktimeout_MODEL.7z`, `fallbackaccess_MODEL.7z`, `nullresult_MODEL.7z`, `normal_MODEL.7z`, `legacy_BAZA.7z`, `normal_BAZA.7z` (`BRAVO_SELF_TEST.ps1:25124-25277`) | `BRAVO_SELF_TEST.ps1` | так, спільний `%TEMP%` | схоже на імена в аргументах заглушок, а не на створювані файли; **не перевірено**, чи створюється файл. Якщо створюється, потрібна унікалізація перед паралельним запуском |
| Читання `HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription` | `BRAVO_SELF_TEST.ps1:565` | лише читання | безпечно |
| Читання списку дисків (`DriveInfo`, `Get-PSDrive`) | `BRAVO_SELF_TEST.ps1:21393-21394`, `:30949`; `selftest/BRAVO_SELF_TEST.DiskSpace.ps1:503`; `selftest/BRAVO_SELF_TEST.Paths.ps1:190` | лише читання | безпечно |
| `Start-Job` на час тесту | `selftest/BRAVO_SELF_TEST.Operations.ps1:859`, `selftest/BRAVO_SELF_TEST.MaintenanceRepair.ps1:143` | у межах одного suite | процесній ізоляції не заважає |

## 2. Категорії без знайдених реальних machine-wide ефектів

- **ProgramData.** Згадки — рядки-шляхи, перевірки тексту/AST або
  sandbox-шлях `$discoveryTestRoot\ProgramData\BRAVO\State`
  (`BRAVO_SELF_TEST.ps1:22829`). Реальний `C:\ProgramData\BRAVO\...` тести не
  пишуть (`BRAVO_SELF_TEST.ps1:23038` — лише рядок-проба). VersionState
  ізольовано сесією `BRAVO_SELFTEST_*` у `RUNNER_TEMP` або `%TEMP%` з GUID
  (`BRAVO_SELF_TEST.ps1:419-423`); змінні `BRAVO_SELFTEST_*` процесні, між
  процесами не перетинаються.
- **Служби та завдання SYSTEM.** `Start-Service`/`Stop-Service` — локальні
  заглушки (`BRAVO_SELF_TEST.ps1:17277-17282`,
  `selftest/BRAVO_SELF_TEST.DataRestore.ps1:74-82`); `Start-ScheduledTask` —
  заглушка (`selftest/BRAVO_SELF_TEST.ServiceRecovery.ps1:2514`). Імена
  завдань SYSTEM перевіряються статично (AST/текст); реальних
  `Register-ScheduledTask` чи `schtasks /create` не знайдено.
- **Журнали подій.** `Get-WinEvent` — заглушка
  (`selftest/BRAVO_SELF_TEST.ServiceRecovery.ps1:1260`); `New-EventLog`,
  `Write-EventLog`, `wevtutil` не використовуються.
- **ACL.** `Set-Acl` застосовується до каталогів у тимчасових GUID-коренях:
  `BRAVO_SELF_TEST.ps1:16043-16125`,
  `selftest/BRAVO_SELF_TEST.Configurator.ps1:614-650`,
  `selftest/BRAVO_SELF_TEST.ConfigV2PilotArtifact.ps1:733-738`;
  `selftest/BRAVO_SELF_TEST.MaintenanceRepair.ps1:1473` — заглушка. `icacls` і
  `takeown` не використовуються.
- **Порти.** `TcpListener`/`HttpListener` і фіксованих портів у тестах не
  знайдено (згадка `Test-NetConnection` — лише в перевірці
  `ProgressPreference`, `BRAVO_SELF_TEST.ps1:10827-10839`).
- **Каталоги у `%TEMP%` з GUID (безпечні):**
  `BRAVOSelfTest_ArchiveOwnLog_*` (`Archive.ps1:139`),
  `BRAVOSelfTest_ArchiveSecretMask365_*` (`Archive.ps1:320`),
  `BRAVOSelfTest_MaintenanceOwnLog_*` (`MaintenanceOwnLog.ps1:112`),
  `BRAVOSelfTest_SecretMask365_*` (`MaintenanceOwnLog.ps1:477`),
  `BRAVO_SelfTest_SchemaIsolated_*` (`Configuration.ps1:2453`),
  `bravo-pilot-selftest-*` (`ConfigV2PilotArtifact.ps1:230`). Вибіркова
  перевірка інших `Join-Path ([IO.Path]::GetTempPath()) (...)` у
  `BRAVO_SELF_TEST.ps1` (наприклад `:5339`, `:8545`, `:12794`) показала GUID у
  назві; повний перелік із приблизно 320 згадок `%TEMP%` **не вичитано**.
- **Поточний каталог процесу.** `[Environment]::CurrentDirectory`
  змінюється й відновлюється в
  `selftest/BRAVO_SELF_TEST.ConfigLoader.ps1:94-133`; це властивість
  процесу, між процесами не ділиться.

## 3. Висновок щодо розбиття на процеси

Обмеження, яке зменшує користь: кожен вибірковий процес виконує inline-тіло
кореня (за `README.md` — 961 із 2107 перевірок на момент написання, цифра
застаріла), тож N паралельних процесів N разів платять за корінь, а виграш
дають лише частки suite. Накладні витрати кореня треба виміряти до рішення.

**Кандидати на окремі worker-процеси або CI-job-и** (machine-wide конфліктів
не знайдено): `Archive`, `ArchiveDiskSpace`, `BackupDestinations`,
`BackupScope`, `BazaSync`, `ClientGate`, `ConfigIntent`, `ConfigLoader`,
`Configuration`, `Configurator`, `ConfiguratorUI`, `ConsoleUX`, `DataRestore`,
`DiskSpace`, `Governance`, `LogRotation`, `LogSync`, `MaintenanceDiskSpace`,
`MaintenanceOwnLog`, `ManifestStorage`, `Operations`, `Paths`,
`RestoreSynthetic`, `RestoreVerify`, `ServiceQuiescence`, `Status`,
`TraceArchive`.

**Серійна група до додаткової перевірки:**

- `ServiceRecovery`, `MaintenanceRepair` — найбільше підмін глобальних функцій
  і `Start-Job`; ризик не між процесами, а в правильності ізоляції. Окремий
  процес безпечний, якщо кожен процес має власний `%TEMP%`.
- Будь-який suite з фіксованими іменами файлів у `%TEMP%` (рядок про
  `*_MODEL.7z`, `BRAVO_VSS_selftest_*`): після підтвердження, що файли
  створюються, потрібна унікалізація або окремий `TEMP` на процес.

**Лише одна копія на машині одночасно:** `ConfigV2PilotArtifact` —
фіксований target Credential Manager F23. Скрипт уже окремий і запускається
окремим CI job; для self-hosted runner-ів з кількома job-ами на одній машині
його треба серіалізувати (concurrency group).

**Вимоги до будь-якої реалізації (поза обсягом OPT-11):**

1. Окремий `%TEMP%`/`RUNNER_TEMP` і чекаут (або окремий `LOGS\HELPERS`) на
   процес.
2. Full лишається єдиним release gate; сумарне покриття паралельних job-ів
   має дорівнювати Full (контроль: кількість перевірок і набір `-Name`).
3. Required CI не змінюється без окремого рішення власника.
4. Спершу виміряти накладні витрати кореня на процес.
