# BRAVO-Toolkit 5.2.3-rc.6 — зведений acceptance evidence (2026-09-13)

Статус: **PASS з однією відкритою позицією** — усі обов'язкові перевірки
§9.1, включно із запуском від `NT AUTHORITY\SYSTEM`, закриті на реальному
сервері; відкритими лишаються тільки негативні сценарії 4/5 (розділ 8). Документ
фіксує докази й не є авторизацією промоції: вердикт acceptance і рішення про
промоцію — окремі кроки (`RELEASE_POLICY.md` §9.3, §4).

## 1. Ідентичність кандидата

| Поле | Значення |
|---|---|
| Тег | `v5.2.3-rc.6` (анотований, на коміті-stamp) |
| Коміт-stamp (tag target) | `124140b` |
| sourceCommit / buildId (`VERSION.json`) | `b872ce68cd970594e18b4b9688b3e35a6799a9a5` / `b872ce6` |
| releaseChannel | `prerelease` |
| Артефакт | `BRAVO-Toolkit-5.2.3-rc.6.zip`, зібраний і провалідований workflow `Release artifact` (run 34728417679) |
| Розгорнуто на | `LIMS-TOP` (ВІННИЦЬКА ФВЛ [38511934]): спершу `C:\Temp\BRAVO_523_rc6\kit` (розділи 3-4), далі — бойовий runtime-корінь `C:\Program Files\BRAVO-Toolkit` (розділ 4.4) |
| Site-оверлей | `BRAVO.local.config`: `maintenanceSettings.Limits.ExcludedDrives = @('F:\','G:\')` |
| Базова stable (поведінковий baseline) | `5.2.2` (тег `v5.2.2` = `15ce820`) |

### 1.1. Зміст кандидата

| Коміт | Що |
|---|---|
| `5b80aff` | disk-space: health-only томи читають реальний `DriveInfo`; `TotalGB`; явний `Reason`; захист композитора; регресії S63/S64 |
| `3d901cd` | self-test: фікстура планувальника через `BRAVO.local.config` замість regex-мутації |
| `1855891` | self-test: асерт BAZASync по розкладу, незалежний від стану Планувальника машини |
| `460df95` | port: fixture-банери транскрипту + `Reason` для access-гілки (з `backup/local-5.2.3-rc.5`) |
| `b872ce6` | release: CRLF у `VERSION.json` і перехешування маніфесту |

## 2. Real-server acceptance по кандидатах

| Кандидат | Дата | Сервер | Обсяг | Результат |
|---|---|---|---|---|
| rc.1 | 2026-08-31 | — | замінено rc.2 до acceptance | n/a |
| rc.2 | 2026-09-02 | `LIMS-TOP` | непортативність self-test-фікстур (11 сценаріїв залежали від наявності `D:`/`E:`) | FAIL → rc.3 |
| rc.3 | 2026-09-13 | `LIMS-TOP` | повний прогін Archive+Maintenance | **FAIL** (розділ 2.1) |
| rc.4, rc.5 | — | — | номери зайняті паралельними деревами, кандидати не випускались | n/a |
| rc.6 | 2026-09-13 03:44–03:56 | `LIMS-TOP` | self-test, Archive, Health, Maintenance на артефакті | **PASS** (розділи 3-4) |

### 2.1. Чому rc.3 — FAIL

- **Production:** health-only гілка передавала `-Drives @()` безумовно, тому
  `Get-BRAVODiskSpaceCapacityObservation` шукав том у порожньому інжектованому
  масиві замість реального `System.IO.DriveInfo` → `CapacityState=Unknown` для
  кожного локального тому. Наслідки: порожні `[WARNING] C:\: ` у консолі й
  журналі, втрачене зведення вільного місця (`запас: немає даних`),
  `exit 10 SuccessWithWarnings` при нульових лічильниках етапів і фінальне
  сповіщення в ALERTS як «ПОТРІБНА ДІЯ» на успішному прогоні.
- **Self-test:** 1532 PASS / 1 FAIL —
  `Scheduler/BazaSyncTaskSkippedWhenSftpGloballyDisabled`. Асерт рахував
  згадки назви завдання; їх кількість залежить від того, чи завдання вже
  зареєстроване в Планувальнику машини (CI — одна, сервер — дві).

## 3. Обов'язкові перевірки (`RELEASE_POLICY.md` §9.1)

| Перевірка | Результат | Джерело |
|---|---|---|
| Оновлення комплекту | OK (розгортання артефакту в чисту теку + оверлей) | rc.6 |
| `BRAVO_SETUP.ps1 -ValidateOnly` | OK | `BRAVO_TASKS_INSTALL_20260913_0346*` (7 прогонів, ExitCode 0) |
| `BRAVO_DRY_RUN.ps1` | OK, 0 помилок (режим READ-ONLY) | `BRAVO_DRY_RUN_20260913_034716`, `…034851` |
| Реальна архівація | **3 з 3**, VSS, один `GenerationId`, manifest COMPLETE | `BRAVO_ARCHIV_20260913_035104` |
| Перевірка архівів 7-Zip | OK | той самий журнал |
| SFTP | **7 з 7** файлів + manifest; BAZA APP синхронізовано | той самий журнал |
| SMB | n/a — компонент вимкнено в конфігурації | `BRAVO_ARCHIV_HEALTH_20260913_035538` |
| Health | «усі керовані служби працюють, копії актуальні» | `BRAVO_ARCHIV_HEALTH_20260913_035538` |
| Maintenance | **СТАТУС: УСПІШНО**, 0 попереджень, 0 помилок, 19 с | `BRAVO_MAINTENANCE_20260913_035612` |
| Секрети в журналах | 0 входжень password/пароль | grep по журналах прогону |
| Коди завершення | Archive «УСПIШНО», Maintenance `0 — Success` | консоль + журнали |
| Сумісність | Windows PowerShell 5.1.19041.7725, LIMS-TOP | заголовки журналів |
| Self-test на сервері | **1535 PASS / 0 FAIL**, exit 0 | `HELPERS/BRAVO_SELF_TEST_20260913_034434` |
| Запуск від `NT AUTHORITY\SYSTEM` | **PASS** — `BRAVO_ARCHIV_HEALTH` і `BRAVO_MAINTENANCE` запущені вручну з бойового кореня, `LastTaskResult = 0` в обох | розділ 4.4 |
| Доступи під SYSTEM (`-TestAccess`-еквівалент) | **PASS** — наскрізний dry-run `BRAVO_TASKS_DIAGNOSE` від `NT AUTHORITY\SYSTEM`: write-проби, обидва креденшели, Discord HTTP 204 | розділ 4.4 |
| Restore test з explicit `-GenerationId` | **PASS** — 3/3 компоненти з генерації `20260913_035104` | розділ 4.2 |

## 4. Нова поверхня 5.2.3 — operation-aware disk-space policy

Рішення класифікатора в прогоні Maintenance 03:56:13 — усі томи з реальною
ємністю, жодного `Unknown`:

```
C:\    HealthOnly              CapacityState=Known  AvailableGB=29.78   Status=Success
D:\    HealthOnly              CapacityState=Known  AvailableGB=715.51  Status=Success
G:\    HealthOnly              CapacityState=Known  AvailableGB=0.54    Status=Success  (придушено ExcludedDrives)
D:\LIMS MaintenanceWorkingVolume CapacityState=Known AvailableGB=715.51 Status=Success  RequirementGranularity=Unknown
```

Зведення вільного місця повернулось у журнал і сповіщення:

```
Диск C:: доступно 29.78 GB з 111.16 GB (потрібно мінімум: 20 GB)
Диск D:: доступно 715.51 GB з 931.51 GB (потрібно мінімум: 20 GB)
Диск G:: доступно 0.54 GB з 15 GB (потрібно мінімум: 20 GB)
```

| # | Сценарій | Очікувано | Факт |
|---|---|---|---|
| 1 | Місця вистачає всюди | архівація йде, `Status=Success` | **PASS** — Archive 3/3, Maintenance exit 0 |
| 2 | Мало місця на томі, що не бере участі в операції | не блокує | **PASS** — `G:` 0.54 GB не заблокував ані Archive, ані Maintenance |
| 3 | Мало місця на required томі призначення | блокує, `EstimatedRequirementNotMet` | не виконувався (покрито self-test A-серією) |
| 4 | Вільне нижче порогу, оцінка мала | блокує, `BelowFloorEstimateNotPeakSafe` | **не виконувався** |
| 5 | Required том у `ExcludedDrives` | блокує, `ExclusionIgnoredForRequiredVolume` | **не виконувався** |
| 6 | Maintenance: `ROOT_LIMS` як єдина write-required ціль | `RequirementGranularity=Unknown`, лише цей том | **PASS** — див. вивід вище |

### 4.1. Негативні перевірки

| Перевірка | Факт |
|---|---|
| Порожніх WARNING без причини немає | **PASS** — 0 рядків `[WARNING]`/`[ERROR]` в обох прогонах |
| Maintenance не сканує всі Fixed-диски підряд | **PASS** — health-only sweep + одна write-required ціль |
| Сповіщення в правильному каналі | **PASS** — GENERAL (підтверджено оператором) |
| Немає `Cannot bind argument to parameter 'Path'` | **PASS** — 0 входжень |
| Fixture-банери в транскрипті самотесту | **PASS** — 8 банерів, жодного справжнього `[FAIL]` |

### 4.2. Restore drill (§9.1, обов'язковий)

`BRAVO_RESTORE_TEST.ps1 -GenerationId 20260913_035104 -Component All -AsJson`,
13.09.2026 04:13-04:14, `LIMS-TOP`, exit code **0**. Усі три компоненти —
з ОДНІЄЇ COMPLETE-генерації, не «найновіше по кожному окремо»:

| Компонент | Архів | Статус | Файлів | Каталогів | Трив., с |
|---|---|---|---|---|---|
| MODEL | `vinnytsya_fitolab_v2412_20260913_035104.mdz` | PASS | 385 | 20 | 5.3 |
| BLOG | `vinnytsya_fitolab_v2412_blog_20260913_035104.mdz` | PASS | 2 | 0 | 1.3 |
| BRAVOEXCH | `vinnytsya_fitolab_v2412_bravoexch_20260913_035104.mdz` | PASS | 10715 | 9 | 30.7 |

Генерація створена самим кандидатом rc.6 у прогоні Archive 03:51 — тобто
перевірено повний цикл «архів створено цією версією → відновлено цією ж
версією», а не лише читання старих архівів.

### 4.3. Спроба запуску від SYSTEM із тимчасової теки — не вдалась

Тимчасове завдання Планувальника (`\BRAVO_ACCEPTANCE\RC6_SYSTEM_RESTORE_DRILL`,
принципал `NT AUTHORITY\SYSTEM`, дія — той самий рядок аргументів, що успішно
відпрацював інтерактивно) завершилось із кодом **`0xFFFD0000`** (4294770688)
за менш ніж секунду: журнал Планувальника показує старт і завершення в ту
саму секунду 04:09:11 (PID 9968).

Процес помер **до рядка 20** скрипта — `LOGS\HELPERS` не створено взагалі,
тобто `Start-BRAVOHelperLog` не виконувався. Рядок аргументів виключено як
причину: інтерактивно він дав exit 0 (розділ 4.2). Причина специфічна для
SYSTEM-контексту при запуску з `C:\Temp` і не досліджувалась далі, бо цей
шлях не є production-сценарієм: бойові завдання виконуються з установленого
runtime-кореня з ACL, які виставляє `BRAVO_TASKS_INSTALL`.

**Це не дефект кандидата** (та сама дія з тими самими аргументами працює),
але й **не доказ** SYSTEM-виконання. Пункт §9.1 «запуск завдань від SYSTEM»
лишається відкритим — див. розділ 8.
### 4.4. Розгортання в бойовий runtime-корінь і запуск від SYSTEM

13.09.2026, `LIMS-TOP`. Кандидат розгорнуто в реальний runtime-корінь
`C:\Program Files\BRAVO-Toolkit` — саме той шлях, з якого працюють бойові
завдання Планувальника.

**Знахідка на production (не дефект кандидата).** До розгортання всі чотири
завдання гілки `\BRAVO\` (`BRAVO_ARCHIV`, `BRAVO_MAINTENANCE`,
`BRAVO_ARCHIV_HEALTH`, `BRAVO BAZA Synchronization`) вказували на
`C:\Temp\BRAVO_523_rc3\kit` — тобто нічна архівація о 23:00 виконалася б із
тимчасової теки без ACL і з кодом rc.3, у якому міститься дефект disk-space.
Так лишилось після acceptance-прогонів rc.3. Розгортання цю конфігурацію
виправило.

| Крок | Результат |
|---|---|
| Попередній вміст кореня | `5.2.3-rc.3` (prerelease, buildId `a008f78`) — збережено в `C:\BRAVO-Toolkit.old_5.2.3-rc.3` (311 файлів) |
| Порівняння `BRAVO.config` (встановлений vs комплект) | ідентичні (`Compare-Object` без виводу) |
| `robocopy … /MIR /XD LOGS /XF BRAVO.local.config BRAVO.config` | exit 1 (успіх), 125 файлів; legacy-бібліотеки в корені прибрано; `VERSION.json` → **5.2.3-rc.6 / b872ce6** |
| `BRAVO_RUNTIME_GUARD.ps1` | «Цілісність комплекту підтверджена (перевірено файлів: 87)», exit **0** |
| Повний self-test із бойового кореня | **1535 перевірок / 0 помилок**, exit **0** (включно з `DiskSpace/S63`, `S64`, серією `Maintenance/M*`) |
| `BRAVO_SETUP.ps1 -ValidateOnly` | ГОТОВО ДО ЗАПУСКУ: dry-run 1 — PASS 48 / WARN 2 / FAIL 0; dry-run 2 з write-пробами — PASS 63 / WARN 0 / FAIL 0; SFTP-endpoint автентифіковано |
| `BRAVO_SETUP.ps1` (повний) | ACL рекурсивно застосовано до `C:\Program Files\BRAVO-Toolkit`; 4 завдання **UPDATED**, 0 помилок |
| `BRAVO_TASKS_DIAGNOSE` наскрізний dry-run від `NT AUTHORITY\SYSTEM` | усі перевірки PASS: write-проби під `C:\WINDOWS\SystemTemp\`, креденшели для `LimsTop` і `SYSTEM` — FOUND, тестове повідомлення Discord — HTTP 204 |
| Аргументи завдань після переустановки | усі шляхи — `C:\Program Files\BRAVO-Toolkit\…`; **жодного входження `C:\Temp`** |
| Ручний запуск `\BRAVO\BRAVO_ARCHIV_HEALTH` (принципал SYSTEM) | `LastTaskResult = 0` |
| Ручний запуск `\BRAVO\BRAVO_MAINTENANCE` (принципал SYSTEM) | `LastTaskResult = 0` |

Це закриває пункти §9.1 «запуск завдань від SYSTEM» і «доступи під SYSTEM»:
на відміну від спроби з `C:\Temp` (розділ 4.3), тут перевірено і ACL бойового
кореня, і креденшели SYSTEM, і реальні шляхи. Завдання `BRAVO_RESTORE_VERIFY`
у цій гілці не існує (з'являється лише в 5.3.0), тому SYSTEM-виконання
підтверджено наявними завданнями Health і Maintenance.

## 5. Передпольотна інвентаризація парку

| Сервер | `MinimumFreeSpaceGB` | Фактично на required томі | `ExcludedDrives` | Рішення |
|---|---|---|---|---|
| `LIMS-TOP` | 20 | `D:\LIMS` — 715.51 GB | `F:\`, `G:\` | `G:` (15 GB загальних) внесено у виключення: том фізично менший за поріг, тож інакше давав би постійне попередження |
| решта парку | `<>` | `<>` | `<>` | `<перевірити до розкатки>` |

## 6. Мінімальний протокол (`RELEASE_POLICY.md` §9.2)

```text
Server:               LIMS-TOP (ВІННИЦЬКА ФВЛ [38511934])
OS:                   Windows (LIMS-TOP)
PowerShell:           5.1.19041.7725
Previous version:     5.2.3-rc.3 (прогін 13.09 01:26-01:32), stable у парку — 5.2.2
Tested version:       5.2.3-rc.6 (stamp 124140b, provenance b872ce6)
Install/update result: OK — артефакт розгорнуто в C:\Temp\BRAVO_523_rc6\kit + site-оверлей,
                      далі — у бойовий корінь C:\Program Files\BRAVO-Toolkit (GUARD 0, self-test 1535/0)
ValidateOnly result:  OK (7 прогонів BRAVO_TASKS_INSTALL, ExitCode 0)
Dry-run result:       OK, 0 помилок (READ-ONLY) + наскрізний dry-run BRAVO_TASKS_DIAGNOSE від SYSTEM — усі PASS
Archive result:       УСПIШНО — 3 з 3 архівів, VSS, SHA512
SFTP result:          7 з 7 файлів + manifest; BAZA APP: 0 нових, 5423 підтверджено
SMB result:           n/a — компонент вимкнено
Health result:        усі копії актуальні, служби працюють
Maintenance result:   УСПІШНО, exit 0, 0 попереджень, 0 помилок, 19 с
Restore test result:  PASS - MODEL/BLOG/BRAVOEXCH з генерації 20260913_035104
Self-test result:     1535 PASS / 0 FAIL, exit 0 (у т.ч. з C:\Program Files\BRAVO-Toolkit)
SYSTEM task run:      PASS - BRAVO_ARCHIV_HEALTH LastTaskResult=0, BRAVO_MAINTENANCE LastTaskResult=0
DiskSpace scenarios:  1 PASS, 2 PASS, 6 PASS; 3/4/5 не виконувались
Detected issues:      немає в кандидаті; на production знайдено й усунено конфігураційну
                      ваду — завдання \BRAVO\ вказували на C:\Temp\BRAVO_523_rc3\kit (розділ 4.4)
Decision:             PASS; відкритими лишаються тільки негативні сценарії 4/5 (розділ 8)
```

## 7. CI / детерміновані перевірки

Прогін `34728418758` на коміті-stamp `124140b`:

- `BRAVO_SELF_TEST.ps1` ✅, `BRAVO_DATA_RESTORE_MATRIX_TEST.ps1` ✅,
  `PSScriptAnalyzer` ✅, `Secret scanning (gitleaks)` ✅,
  `GitGuardian Security Checks` ✅;
- `Parser / BOM / JSON` ❌ — крок «Release policy» рахується проти базової
  гілки `master` і вимагає stable-версії; на prerelease-кандидаті падає за
  визначенням. Стане зеленим після stable-штампа. Побічно: наступні кроки
  того job'а (master merge policy, integrity manifests, markdown BOM)
  пропускаються, тож свіжість `RUNTIME_MANIFEST.json` у PR не перевіряється
  автоматично — її підтвердив штатний `ci\Update-BRAVORuntimeManifest.ps1
  -Apply` на stamp-кроці (розбіжність лише у `VERSION.json`, яку сам stamp і
  створив).

Окремий прогін `34728417679` за тегом — `Build + validate + attach` ✅:
артефакт зібрано `git archive` з тега, розпаковано і з розпакованого
комплекту прогнано обидва integrity-маніфести, `BRAVO_RUNTIME_GUARD` і повний
self-test.

## 8. Відкриті позиції

Закриті після випуску попередньої редакції цього документа:

- ~~запуск від `NT AUTHORITY\SYSTEM`~~ — **PASS**, розділ 4.4;
- ~~доступи під SYSTEM (`-TestAccess`-еквівалент)~~ — **PASS**, розділ 4.4;
- ~~restore test з explicit `-GenerationId`~~ — **PASS**, розділ 4.2.

Лишається відкритим — рішення власника, чи вимагати до промоції:

1. **Негативні сценарії 4 і 5** (below-floor блокування та
   `ExclusionIgnoredForRequiredVolume`) — не відтворювались на сервері.
   Покриті self-test-серіями A24/A25 і M7.

Косметичний борг циклу (не блокує):

- у підсумку Maintenance лічильник `Попереджень: 0` не враховує попередження
  з передетапної перевірки місця (виявлено на rc.3, коли exit був 10);
- том, менший за поріг, дає постійне health-попередження — обходиться
  `ExcludedDrives`, кандидат на policy-рішення в 5.3.0;
- попередження «VERSION.json і BRAVO.config містять різні версії пакета»
  вказує на `BRAVO.config`, хоча читає залишковий `$global:ScriptVersion` від
  попереднього запуску в тій самій сесії (відтворено 13.09 04:06, зникає в
  чистій консолі) — діагностика називає не те джерело;
- вивід in-process фікстур самотесту (`ПОМИЛКА:` червоним) не покритий
  банерами `43b6f04`, які працюють лише для дочірніх процесів.

## 9. Висновок

Кандидат `v5.2.3-rc.6` (stamp `124140b`, provenance `b872ce6`) закрив усі три
дефекти, знайдені acceptance rc.3, що підтверджено на тому самому сервері:
реальна ємність усіх томів і повернуте зведення вільного місця, self-test
1535/0 на машині із зареєстрованим завданням BAZASync, `exit 0` і сповіщення
в GENERAL замість ALERTS.

Обов'язкові перевірки §9.1 закриті повністю: до restore drill з явним
`-GenerationId` додано запуск завдань від `NT AUTHORITY\SYSTEM` з бойового
кореня `C:\Program Files\BRAVO-Toolkit` (`LastTaskResult = 0` для Health і
Maintenance) та наскрізний SYSTEM-dry-run доступів. Побічно усунено
конфігураційну ваду production: завдання Планувальника більше не вказують на
тимчасову теку з кодом rc.3.

Блокуючих дефектів і security-регресій не виявлено. Рекомендація:
**metadata-only промоція в stable `5.2.3`** — після рішення власника щодо
єдиної відкритої позиції розділу 8 (негативні сценарії 4/5, покриті
self-test-серіями A24/A25 і M7). Промоція вимагає окремої явної
авторизації.
