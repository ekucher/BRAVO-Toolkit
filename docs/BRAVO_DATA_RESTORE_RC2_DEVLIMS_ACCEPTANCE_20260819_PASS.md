# BRAVO 5.1.0-rc.2 — DEV-LIMS acceptance, 2026-08-19 — ПІДСУМОК: PASS

Повний реальний acceptance-прогін за runbook
`docs/BRAVO_DATA_RESTORE_RC2_ACCEPTANCE_RUNBOOK_20260818.md`.
Знімає NO-GO від 15.08.2026 (`33c5aca`, B20 BLOCKED).

## Ідентичність кандидата (exact identity)

| Поле | Значення |
|---|---|
| Кандидат | 5.1.0-rc.2 (prerelease) |
| Stamp-коміт (розгорнутий) | `10e9973983ff3e42cde4cee01d064047c4485b9a` |
| VERSION.sourceCommit / buildId | `1f03a6fb2c21c65435a74b6bf257925a4258e77c` / `1f03a6f` |
| Артефакт | `BRAVO-Toolkit-5.1.0-rc.2.zip`, SHA-256 `9394421cd539609627c25a8a42a1a9f348a6263c999b8e4860937432cc74d13e` (зібрано `ci\New-BRAVOReleaseArtifact.ps1` з `10e9973`; хеш звірено оператором перед розгортанням) |
| CI на stamp-коміті | run 32292576143 SUCCESS (self-test, DataRestore matrix, gitleaks, parser/BOM/JSON, PSScriptAnalyzer) |
| Сервер | DEV-LIMS, Windows Server 2022 Standard (10.0.20348), PowerShell 5.1.20348.5386 — рівень підтримки Supported |
| Runtime | `D:\BRAVO-Toolkit-5.1.0-rc.2`; LIMSRoot `E:\LIMS` (ServiceDiscovery); BackupRoot `E:\LIMS\ARCHIV` |
| Оператор | `BSYSTEM\e.kucher`; заплановані завдання від `NT AUTHORITY\SYSTEM` |
| `build` у кожному runtime-лозі прогону | `1f03a6f` (збіг підтверджено) |

## Базова готовність (PHASE-клас)

- `BRAVO_SETUP.ps1 -Action Full` (22:52): ACL runtime (SYSTEM/Administrators),
  Credential Manager 14/14 FOUND (e.kucher + SYSTEM), 5 завдань
  встановлено/оновлено, **end-to-end dry-run від NT AUTHORITY\SYSTEM** —
  усі PASS, включно з SFTP read-only і реальним Discord-тестом (HTTP 204).
- `BRAVO_DRY_RUN.ps1 -TestAccess` (22:47): **60 PASS / 0 WARN / 0 FAIL**,
  «ГОТОВО ДО ЗАПУСКУ». Цілісність RUNTIME/TOOLS manifest, anti-rollback,
  VSS capability, SFTP endpoint+read-only, `/baza_app` — PASS.
- Плановий нічний `BRAVO_ARCHIV` від SYSTEM (23:00): generation
  `20260819_230002` **COMPLETE 3/3** (MODEL 413.03 МБ, BLOG 53.88 МБ,
  BRAVOEXCH 29.63 КБ), SHA512 sidecar-и, SFTP **7/7**, retention-аудит
  42/2/0/0, вбудований Health — усі копії актуальні (локальні + SFTP по
  віддалених `.sha512`), Discord Sent, «Результат: УСПІШНО».
- Free-space діагностика (фікс `274b514`): перелік усіх 3 Fixed-дисків
  з обсягами перед перевіркою — у кожному Archive-лозі прогону.

## Сценарії runbook

| # | Сценарій | Час | Результат / докази |
|---|---|---|---|
| B4 | OutOfPlace, Local, MODEL | 23:08 | exit **0**; generation `20260819_230002`; без WARNING про пропущені manifest-и; 536 файлів / 8.4 ГБ → `D:\TEST_RESTORE_DATA\MODEL`; lock захоплено/звільнено |
| B15 | InPlace single (BLOG) | 23:11 | exit **0**; служба BRAVO stop→start; move-aside `BLOG.prerestore_20260819_231157`; post-restore Health exit 0 |
| B16 | InPlace All | 23:13 | exit **0**; move-aside `Model/BLOG/bravoexch.prerestore_20260819_231307`; prerestore з B15 збережений (перевірено переліком); вбудований Health повний PASS |
| B19 | Rollback single (failpoint `AfterMoveAside:MODEL`) | 23:15 | exit **43**; «Rollback виконано: Model повернуто»; служба знову Running; `Model.prerestore_20260819_231544` відсутній після відкату (перевірено) |
| **B20** | **Cross-component rollback (failpoint `AfterMoveAside:BRAVOEXCH`, `-Component All`)** | 23:18 | exit **43**; MODEL ✔ і BLOG ✔ відновлені, BRAVOEXCH збій після move-aside; каскадний відкат у зворотному порядку — підсумок: `BLOG: ВІДКОЧЕНО`, `MODEL: ВІДКОЧЕНО`, `BRAVOEXCH: ПОМИЛКА`; всі три `*.prerestore_20260819_231806` забрані назад (перевірено — перелік порожній); служба Running. **Колишню причину NO-GO знято.** |
| B17 | SFTP-source restore success (фікс PR #42) | 23:20 | exit **0**; вибір generation з віддалених manifest-ів; архів+sidecar завантажені у staging; free-space preflight пройдено (НЕ exit 90/ProbeDirectory); 8.4 ГБ розпаковано; staging після успіху прибраний автоматично (підтверджено) |
| B21 | Чистий аборт при збої SFTP-download (кероване мережеве переривання: firewall-блок TCP/22 під час download архіву) | 23:28 | exit **50 (SftpFailed)**; причина `Network error: Software caused connection abort` на `/model/...mdz`; WinSCP код 1 → розбір per-operation XML; `MODEL: НЕ ВИКОНУВАВСЯ — очікує` (нуль мутацій, до move-aside не дійшло); **«Staging збережено для діагностики/повтору»** — задокументована навмисна поведінка підтверджена |
| B22 | Real concurrent-operation lock contention | 23:47 | Archive тримав lock 23:47:12→23:52:38 (5:25, нова COMPLETE `20260819_234712`, SFTP 7/7); DataRestore стартував 23:47:48, «Operation lock захоплено» лише о **23:52:48** — 5:00 чесного очікування, нуль паралелізму; далі обрано вже нову generation `20260819_234712`, exit **0** |

Додатково в межах прогону: другий успішний SFTP-restore (повтор B17-класу,
23:26, exit 0) і два повні ручні Archive-цикли (23:33 `20260819_233353`,
23:47 `20260819_234712`) — обидва COMPLETE 3/3, SFTP 7/7, Health PASS.

## Спостереження (не блокери)

1. P3, косметика: у консольному плані відновлення підписи дат наявних
   prerestore-копій зсунуті відносно імен (схоже, LastWriteTime сусіднього
   запису). На поведінку не впливає.
2. SFTP-акаунт Storage Box не має права rename (`Permission denied`) —
   для захисту історії це плюс; для тестів типу B21 використовувати
   мережеве переривання, а не перейменування на сервері.
3. Повторний `BRAVO_TASKS_INSTALL` (у складі Setup -Action Full)
   повторно вмикає всі заплановані завдання — при acceptance-вікні
   вимикати їх треба ПІСЛЯ останнього Setup-запуску.

## Вердикт

**PASS.** Усі сценарії runbook (B4, B15, B16, B19, B20, B17, B21, B22)
пройдені на точному кандидаті `10e9973` без жодного відхилення від
очікуваної поведінки. NO-GO від 15.08.2026 знято. Кандидат готовий до
metadata-only stable promotion `5.1.0-rc.2 → 5.1.0`.

Первинні логи: `D:\BRAVO-Toolkit-5.1.0-rc.2\LOGS\` на DEV-LIMS
(BRAVO_DATA_RESTORE_20260819_23*.log, BRAVO_ARCHIV_20260819_23*.log,
LOGS\HELPERS\* за 2026-08-19); повні транскрипти — у сесії підготовки
цього документа.
