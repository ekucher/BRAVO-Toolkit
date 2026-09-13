# BRAVO-Toolkit 5.2.4-rc.1 — зведений acceptance evidence (2026-09-13)

Статус: **PASS** — цільова зміна кандидата доведена на реальному сервері
чотирма прогонами архівації, включно зі сценарієм, недосяжним у принципі
(поріг вище за повну ємність тому). Документ фіксує докази й не є
авторизацією промоції: вердикт acceptance і рішення про промоцію — окремі
кроки (`RELEASE_POLICY.md` §9.3, §4).

## 1. Ідентичність кандидата

| Поле | Значення |
|---|---|
| Тег | `v5.2.4-rc.1` (анотований, на коміті-stamp) |
| Коміт-stamp (tag target) | `340bd33` |
| sourceCommit / buildId (`VERSION.json`) | `a152d1f1da14502d4ca38320cba9920afad81943` / `a152d1f` |
| releaseChannel | `prerelease` |
| Артефакт | `BRAVO-Toolkit-5.2.4-rc.1.zip`, workflow `Release artifact` (run `34755687320`, job `103719544737`) |
| SHA-256 артефакту | `f53088f4231cb8db77b0ce5655be2c27a21fcdaba1ef6e60cb2bfefe5a4934fa` |
| Розгорнуто на | `LIMS-TOP` (ВІННИЦЬКА ФВЛ [38511934]), каталог `C:\Temp\BRAVO_524_rc1\kit` |
| Site-оверлей | `BRAVO.local.config`: `maintenanceSettings.Limits.ExcludedDrives = @('F:\','G:\')` |
| Базова stable (поведінковий baseline) | `5.2.3` (тег `v5.2.3`) |

### 1.1. Зміст кандидата

| Коміт | Що |
|---|---|
| `a152d1f` | disk-space: `RequirementPolicy` Archive → `ArchivePeakSafe`; нестиснутий розмір джерела як доведена верхня межа; bootstrap-компонент несе вимогу; history-оцінка обмежується тією ж межею |
| `340bd33` | stamp 5.2.4-rc.1 (provenance → `a152d1f`) |

Одна змістовна зміна runtime. `.psd1` усіх 18 модулів уже несуть базову
версію `5.2.4`, `RUNTIME_MANIFEST.json` перехешовано в коміті-stamp.

### 1.2. Прив'язка артефакту

Артефакт відтворено незалежно (`git archive --format=zip -9 v5.2.4-rc.1`)
і звірено з тим, що зібрав CI: SHA-256 збігся байт-у-байт із рядком
`SHA-256: f53088f4…4934fa` у лозі кроку «Збирання артефакту». Тобто на
сервер потрапив саме той комплект, який у CI пройшов обидва
інтегріті-маніфести, `BRAVO_RUNTIME_GUARD.ps1` і повний self-test.

Локально на сервері перед прогонами виконано: звірка SHA-256 з
`.zip.sha256`, розпакування, перевірка `packageVersion`/`sourceCommit`/
`buildId`, `BRAVO_RUNTIME_GUARD.ps1`, повний `BRAVO_SELF_TEST.ps1` — усе
без помилок.

`BRAVO_ALLOW_DOWNGRADE=1` був необхідний: на цій машині раніше
запускалась лінія `5.3.0-dev`, і guard коректно відпрацював
`VersionDowngradeBlocked` (exit 35) до його встановлення. Це очікувана
поведінка захисту, а не дефект кандидата.

## 2. Цільова зміна — доказ

Дзеркальний сценарій до зафіксованого в evidence 5.2.3 §4.5: підняти
поріг вище за вільне місце і переконатися, що прогін **проходить** з
WARNING замість `exit 40`.

Том `D:` — 931.51 GB ємності, ~715 GB вільних, фактична сукупна потреба
архівації `AggregatedRequiredGB = 0.0686` GB.

| # | Час | Поріг | `EstimatedSpaceMarginPercent` | Exit | Рішення класифікатора | Архіви |
|---|---|---|---|---|---|---|
| 1 | 16:40:09 | 20 GB | 25 | **0** | усе `Status=Success Blocks=False` | 3/3, SFTP 7/7 |
| 2 | 16:45:07 | **730 GB** | 25 | **10** | `BelowHealthFloorButRequirementSatisfied` на 3 destination, `Blocks=False` | 3/3, SFTP 7/7 |
| 3 | 16:49:54 | 20 GB | **2000** | **0** | усе `Success`; потреба 0.07 → 1.15 GB | 3/3, SFTP 7/7 |
| 4 | 17:01:49 | **1000 GB** | 25 | **0** | `BelowHealthFloorButRequirementSatisfied` на 3 destination, `Blocks=False` | 3/3, SFTP 7/7 |

Логи: `BRAVO_ARCHIV_20260913_164009_PID5812.log`,
`…_164507_PID7112.log`, `…_164954_PID476.log`, `…_170149_PID10112.log`.

### 2.1. Прогін 2 — ключовий

```
Поріг: 730 GB на кожному локальному Fixed-диску; виключення: F:, G:
Диск D:: доступно 715.35 GB з 931.51 GB (потрібно мінімум: 730 GB)
DisplayPath=D:\LIMS\ARCHIV\MODEL … RequiredGB=0.0549138216301799
    AggregatedRequiredGB=0.0685894777998328
    Status=Warning Blocks=False Reason=BelowHealthFloorButRequirementSatisfied
Generation 20260913_164507: COMPLETE (опубліковано 3 з 3)
Результат: УСПIШНО
```

Під 5.2.3 ця сама конфігурація давала `Status=Error Blocks=True
Reason=BelowFloorEstimateNotPeakSafe` і `exit 40`. Жодного входження
`BelowFloorEstimateNotPeakSafe` у логах кандидата немає.

`exit 10` — `SuccessWithWarnings` (`BRAVO.ExitCodes.psm1:24`), коректний
код для прогону з health-попередженнями.

### 2.2. Прогін 4 — поріг, недосяжний у принципі

Поріг 1000 GB перевищує **повну ємність** тому (931.51 GB), тобто не може
бути задоволений навіть на порожньому диску. Під 5.2.3 це був би вічний
жорсткий блок при кожному запуску. Кандидат виконав повну архівацію,
вивантаження на SFTP і post-backup health-check.

### 2.3. Прогін 3 — поведінка оцінки при завищеному запасі

Margin 25% → 2000% (множник 16.8). Вимога масштабувалась лінійно:
`0.05491382 × 16.8 = 0.9225522` проти `RequiredGB=0.922552230767906` у
лозі; BLOG `0.01178513 × 16.8 = 0.1979903` проти `0.197990250773728`.
Сукупна потреба зросла 0.07 → 1.15 GB, прогін не заблоковано.

Лінійність означає, що `min(історія × margin, джерело × 1.02)` щоразу
обирав історію: **стеля за розміром джерела на цьому сервері не
спрацювала** — джерела нестиснуті й значно більші за 21× стиснутого
архіву. Див. §5.

## 3. Обов'язкові перевірки (`RELEASE_POLICY.md` §9.1)

| Перевірка | Результат |
|---|---|
| Повна архівація з бойового кореня | 4 прогони, кожен `COMPLETE`, 3 з 3 компонентів |
| Цілісність архівів | 7-Zip код 0 на кожному компоненті кожного прогону |
| Узгодженість generation | один VSS Snapshot Set на прогін (напр. `{1FF5FDBF-0AFE-47D2-9846-C9E53C1D4098}`) |
| Вивантаження на SFTP | 7 з 7 файлів у кожному прогоні |
| BAZA APP sync | cycle завершено, помилок 0 |
| Post-backup health | `усi резервнi копiї актуальнi`, звіт у Discord |
| Health окремим прогоном | `BRAVO_ARCHIV_HEALTH_20260913_170621.log`: локальні 3/3 справні, SFTP 3/3 справні, служби BRAVO / exchangAPI / Br-a-vo.web працюють |
| Self-test з розпакованого артефакту | CI: **1539 перевірок, 0 помилок**; локально на сервері — без помилок |
| Runtime guard | exit 0 на розпакованому комплекті |

## 4. Регресійне покриття зміни

| Тест | Що перевіряє | CI |
|---|---|---|
| `Archive/A24` | інвертований: below-floor при достатній вимозі ДОЗВОЛЯЄ | PASS |
| `Archive/A25` | вимога, що не влазить, блокує й далі | PASS |
| `Archive/A26` | bootstrap несе вимогу з джерела | PASS |
| `Archive/EstimatedSpaceBootstrapUsesSourceUpperBound` | реальний обхід ФС: 40000 B → 40800 B | PASS |
| `…HistoryCappedBySmallerSource` | history 125000 B обмежується до 51000 B | PASS |
| `…EmptySourceDoesNotZeroRequirement` | порожнє джерело не обнуляє вимогу | PASS |

## 5. Що НЕ відтворено на реальному сервері

Фіксується явно, щоб межі доказу не були перебільшені.

- **Стеля за розміром джерела (`HistoryCappedBySource`).** Не спрацювала
  в жодному прогоні: джерела на цьому сервері значно більші за
  history-оцінку навіть із 20-кратним запасом (§2.3). Покрито
  юніт-тестами `…HistoryCappedBySmallerSource` і
  `…EstimatedSpaceBootstrapUsesSourceUpperBound`, обидва — через реальний
  `Get-ChildItem`/`Measure-Object`, не через інжектований override.
- **Bootstrap-компонент без історії.** Усі три компоненти на `LIMS-TOP`
  мають валідну історію. Покрито `Archive/A26` і
  `…EstimatedSpaceBootstrapUsesSourceUpperBound`.
- **`ExclusionIgnoredForRequiredVolume`.** Перевірено в циклі 5.2.3
  (evidence 5.2.3 §4.5, сценарій 5); 5.2.4 цієї гілки не торкається
  (`Resolve-BRAVODiskSpaceGroupDecision`, крок 14 — flag-only, ніколи не
  скидає `Blocks=true`).

## 6. Знахідки, зафіксовані як борг (неблокуючі)

Обидві знайдено під час цього acceptance. Жодна не впливає на коректність
рішення, цілісність даних, безпеку чи exit-коди, тому кандидат не
змінювався (`RELEASE_POLICY.md`, P0/P1 проти P2). Специфікація —
`docs/BRAVO_530_DISK_SPACE_HEALTH_SIGNAL_TASK.md` §3 і §4.

**§3. Зведений рядок рішення приписує шляхам чужу причину.**
`Group-BRAVODiskSpaceMessagesByCapacityKey` групує лише за `CapacityKey`
і бере `Reason` від першої entity. У прогоні 4 трьом destination із
`BelowHealthFloorButRequirementSatisfied` приписано
`BelowHealthFloorNoFreeSpaceRequirement`. Структурований лог рішення дає
правдиву причину на кожну entity — уражений лише операторський рядок.
Дефект успадкований з 5.2.3 (`236e559`, присутній в `origin/master` без
змін); 5.2.4 його не вносила, а лише вперше проявила, створивши на одному
томі змішані причини.

**§4. Maintenance трактує поріг інакше за Archive.**
`Get-BRAVOMaintenanceDiskSpaceEntities` задає
`RequirementGranularity = 'Unknown'`, тож гілка `RequirementPolicy`
недосяжна і поріг там лишився жорстким гейтом. Обидві операції читають
той самий ключ `maintenanceSettings.Limits.MinimumFreeSpaceGB`.

| Поріг | `BRAVO_ARCHIV` | `BRAVO_MAINTENANCE` |
|---|---|---|
| 1000 GB | exit 0, архіви 3/3 (17:01) | `BelowFallbackFloorNoEstimate`, exit 60, 2 сек (17:07) |
| 800 GB | не прогонялось | `BelowFallbackFloorNoEstimate`, exit 60, 2 сек (17:41) |

Це **не регресія 5.2.4**: Maintenance поводиться рівно так, як у 5.2.3.
Але після 5.2.4 з'явилась асиметрія, якої раніше не було, і вона
операційно небезпечна — підняття порогу заради архівації тихо ламає
обслуговування. Прогони з порогом 20 GB проходять обидві операції.

## 7. CI / детерміновані перевірки

Коміт `340bd33`, workflow runs `34755682470` (CI) і `34755687320`
(Release artifact):

| Перевірка | Результат |
|---|---|
| `BRAVO_SELF_TEST.ps1` | success (1539/0) |
| `BRAVO_DATA_RESTORE_MATRIX_TEST.ps1` | success |
| `PSScriptAnalyzer` | success |
| `Secret scanning (gitleaks)` | success |
| `GitGuardian Security Checks` | success |
| `Build + validate + attach` | success |
| `Parser / BOM / JSON` | **failure — очікувано** |

Останній падає на кроці Release policy: база PR — `master`, яка вимагає
stable-версії, а кандидат є prerelease. Позеленіє після stable-штампа, як
було в циклі 5.2.3.

## 8. Висновок

Цільова зміна кандидата доведена на реальному сервері в чотирьох
конфігураціях, включно з недосяжним порогом. Захист не послаблено:
`EstimatedRequirementNotMet` лишається жорстким блокуванням, що
підтверджує `Archive/A25`. Блокувальних знахідок немає; дві знайдені
P2-позиції винесені в лінію 5.3.0 без зміни кандидата.

Вердикт: **PROMOTE**.

Це вердикт валідації, а не авторизація публікації, тегування чи зміни
`master` (`RELEASE_POLICY.md` §9.3).
