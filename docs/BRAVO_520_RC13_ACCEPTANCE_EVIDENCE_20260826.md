# BRAVO-Toolkit 5.2.0-rc.13 — зведений acceptance evidence (2026-08-26)

Статус: **PASS — кандидат готовий до metadata-only промоції stable 5.2.0.**
Промоція НЕ виконана цим документом; це виключно фіксація доказів
(RELEASE_POLICY розділи «Acceptance verdict semantics», «Stable promotion»).

## 1. Ідентичність кандидата

| Поле | Значення |
|---|---|
| Тег | `v5.2.0-rc.13` (анотований, на коміті-stamp) |
| Коміт-stamp (tag target) | `0247ac3` |
| sourceCommit / buildId (`VERSION.json`) | `12e6370afdf8ae24fe31758e887fdc9c13ec45ae` / `12e6370` |
| releaseDate | 2026-08-26 |
| Артефакт | `BRAVO-Toolkit-5.2.0-rc.13.zip`, SHA-256 `6eac9695ed6053e7156ff843d8b4aed8522b4627d65c95bace1bc3de5a42af22` |
| Базова stable (поведінковий baseline) | `5.1.0` (тег `v5.1.0`, stamp `219c55b`, sourceCommit `d90c3c2`) |

Хронологія кандидатів циклу (rc.4 → rc.13, PR #83–#98) — RELEASE_POLICY §20.

## 2. Real-server acceptance по кандидатах

| Кандидат | Дата | Сервер(и) | Обсяг | Результат |
|---|---|---|---|---|
| rc.4 / rc.5 | 2026-08-24 | `SERV_HRDL_1`, `WIN-44OBNQ3R3OB` | повний acceptance (backup, SFTP, Health) | PASS |
| rc.6 | 2026-08-25 | — | фіксований поріг місця блокував backup | FAIL → rc.7 |
| rc.7 | 2026-08-25 | `WIN-42Q5558LQC9` | повний end-to-end: backup MODEL/BLOG/BRAVOEXCH, SFTP 7/7, Health OK | PASS |
| rc.8 | 2026-08-25 22:03–22:24 | ДНДІЛДВСЕ (сервер інциденту exit 43) | `-ForceRestore`: bravocmd exit 0, Compare-FileSizes Critical=0, Rollback=NONE, служби відновлено, Trace-pipeline OK | PASS |
| rc.9 / rc.10 | — | — | замінені наступним кандидатом до acceptance | n/a |
| rc.11 | 2026-08-26 | ДНДІЛДВСЕ | виявлено подвійну реставрацію після `-ForceRestore` | FAIL → rc.12 |
| rc.12 | 2026-08-26 01:29 / 01:52 / 01:58 | ДНДІЛДВСЕ | forced-реставрація + два наступні звичайні запуски: квоту спожито, повтору НЕМАЄ (негативний тест квоти) | PASS (UX-зауваження → rc.13) |
| rc.13 | 2026-08-26 | ДНДІЛДВСЕ (Server 2022, Supported), Львівська РДЛ (включно з хостом Server 2016, LegacyBestEffort) | повний maintenance-цикл нової поверхні rc.9–rc.13 | PASS |

Підтверджена нова поверхня rc.9–rc.13 на реальних серверах (26.08):

- перша бойова одноразова SFTP-міграція `trace/` → `logs/trace`
  (WinSCP MoveFile): **4/4 без помилок**, повторний запуск idempotent;
- автостворення remote-каталогів `logs/trace` / `logs/exchangapi`;
- скан реальних `*.out`-варіантів кореня інсталяції та добові
  Trace/exchangAPI-архіви з SFTP-верифікацією;
- компактні алерти (count + ≤5 прикладів) і payload guard — жодного
  розірваного/обрізаного транспортом повідомлення;
- підетапи прогресу тривалих native-операцій
  («…— Виконується N сек.»), опис фази bravocmd з фактичним ім'ям
  проєкту моделі;
- forced + звичайна реставрація в один вечір БЕЗ повторного запуску
  (тижнева квота, фікс PR #96).

Аналіз журнального корпусу двох машин (244 логи + CSV у робочому
наборі, період 2026-08-14…2026-08-26): нових дефектів rc.13 не
виявлено; 18 `MUTATION_VIOLATION` BAZA (перезбережені PDF) розв'язані
оператором штатною ручною процедурою reconcile; критичних помилок
runtime немає.

## 3. A2 — encoding acceptance (RELEASE_CHECKLIST §1.1)

Підстава: 5.2.0 змінює запис пароля 7-Zip у stdin
(`Write-BRAVOProcessInputText`, UTF-8 БЕЗ BOM через BaseStream) і додає
legacy-fallback B2 для архівів, створених ≤5.1.0 під UTF-8-консоллю
(ефективний пароль `U+FEFF<password>`). Це впливає на читання ВЖЕ
існуючих production-архівів → A2 обов'язковий.

### 3.1. Методика (drill, контрольована машина HOUSE, Windows 11 Pro 26200)

Скрипт drill для кожного контексту виконував три варіанти повного
ланцюга «створення → канонічна інтегріті-перевірка rc.13
(`Invoke-BRAVOSevenZipIntegrityTest`) → канонічна екстракція rc.13
(`Invoke-BRAVOSevenZipExtraction`) → SHA-256-звірка відновленого вмісту
з джерелом (кириличні імена файлів і вміст включно)» на bundled
`Tools\7za.exe` комплекту:

- **A (v5.1.0 code path)** — архів створено ДОСЛІВНО шляхом коду
  v5.1.0 (`Process.StandardInput.WriteLine($password)`,
  `BRAVO.Archive.Runtime.ps1:2792` тега `v5.1.0`) у поточному
  консольному контексті;
- **B (v5.1.0 під UTF-8-консоллю, детерміновано)** — архів зашифровано
  паролем `U+FEFF<password>` (байт-у-байт результат WriteLine під
  CP65001) — rc.13 ЗОБОВ'ЯЗАНИЙ відкрити його через legacy-fallback;
- **C (rc.13, контроль)** — BOM-free архів rc.13 відкривається plain
  паролем БЕЗ fallback.

### 3.2. Інтерактивна операторська сесія — PASS

```text
Context: INTERACTIVE (HOUSE\evgen, UTF-8 console 65001)
Timestamp: 2026-08-26 02:52:29
User: HOUSE\evgen
Console.InputEncoding.CodePage:  65001
Console.OutputEncoding.CodePage: 65001
OutputEncoding: US-ASCII (20127)
PSVersion: 5.1.26100.9168; OS: Microsoft Windows NT 10.0.26200.0
[A-v510-WriteLine] create exit=0
[A-v510-WriteLine] integrity: Success=True LegacyBomPasswordFallbackUsed=False
[A-v510-WriteLine] extraction: Success=True Fallback=False ContentSHA256Match=True
[B-v510-BOM] create exit=0
[B-v510-BOM] integrity: Success=True LegacyBomPasswordFallbackUsed=True
[B-v510-BOM] extraction: Success=True Fallback=True ContentSHA256Match=True Files=2
[C-rc13-BomFree] create exit=0
[C-rc13-BomFree] integrity: Success=True LegacyBomPasswordFallbackUsed=False
[C-rc13-BomFree] extraction: Success=True Fallback=False ContentSHA256Match=True Files=2
A2 RESULT: PASS
```

### 3.3. Task account `NT AUTHORITY\SYSTEM` (Task Scheduler) — PASS

```text
Context: SYSTEM (Task Scheduler)
Timestamp: 2026-08-26 02:53:51
User: NT AUTHORITY\SYSTEM
Console.InputEncoding.CodePage:  866
Console.OutputEncoding.CodePage: 866
OutputEncoding: US-ASCII (20127)
PSVersion: 5.1.26100.9168; OS: Microsoft Windows NT 10.0.26200.0
[A-v510-WriteLine] create exit=0
[A-v510-WriteLine] integrity: Success=True LegacyBomPasswordFallbackUsed=False
[A-v510-WriteLine] extraction: Success=True Fallback=False ContentSHA256Match=True
[B-v510-BOM] create exit=0
[B-v510-BOM] integrity: Success=True LegacyBomPasswordFallbackUsed=True
[B-v510-BOM] extraction: Success=True Fallback=True ContentSHA256Match=True Files=2
[C-rc13-BomFree] create exit=0
[C-rc13-BomFree] integrity: Success=True LegacyBomPasswordFallbackUsed=False
[C-rc13-BomFree] extraction: Success=True Fallback=False ContentSHA256Match=True Files=2
A2 RESULT: PASS
```

Обидва контексти підтверджують ВИМОГУ §1.1 «не припускається, що обидва
середовища використовують той самий code page»: інтерактивно CP65001,
під SYSTEM — CP866 (той самий OEM-контекст, що й production Task
Scheduler на серверах). Варіант A додатково показав, що на цій
.NET-конфігурації WriteLine НЕ додає BOM навіть під CP65001 (архів
відкрито plain паролем без fallback) — тобто BOM-емісія
середовищезалежна, і саме тому варіант B фіксує legacy-випадок
детерміновано, байт-у-байт.

### 3.4. Відхилення від буквальної форми §1.1 і компенсатори

Буквальна форма вимагає OutOfPlace-restore реальної generation,
створеної stable 5.1.0, через `BRAVO_DATA_RESTORE.ps1` +
`BRAVO_RESTORE_TEST.ps1` на DEV-LIMS. Такої generation на
контрольованому сервері вже не існує (production-сервери працюють на
rc-лінії; їх generations створені rc-кандидатами). Компенсатори:

- drill відтворює encoding-критичний механізм ТОЧНИМ кодом v5.1.0 і
  байт-точним UTF-8-console варіантом (розділ 3.1) — саме та поведінка,
  якою відрізняються 5.1.0-архіви;
- повний end-to-end `BRAVO_DATA_RESTORE` (реальні generations через
  справжній `BRAVO_ARCHIV`, Component×Mode-матриця) — CI job
  `datarestore-matrix-test` зелений на кожному PR лінії rc;
- self-test домен B2 (legacy BOM-fallback: позитив і негатив
  wrong-password) зелений у повному `BRAVO_SELF_TEST.ps1` rc.13;
- реальні production-реставрації під SYSTEM/Task Scheduler (CP866)
  пройшли на двох серверах (розділ 2, rc.8/rc.12/rc.13) — включно з
  bravocmd, Compare-FileSizes і rollback-контуром.

Залишковий ризик оцінюється як закритий для промоції; якщо десь
збережеться фактичний архів, створений 5.1.0 під UTF-8-консоллю,
runtime відкриє його через fallback і запише Warning з рекомендацією
перестворити backup поточною версією (поведінка B2, перевірена в 3.2–3.3).

## 4. CI / детерміновані перевірки rc.13

- CI лінії PR #83–#98: повний `BRAVO_SELF_TEST.ps1`, runtime guard,
  інтегріті-маніфести, release policy, forbidden patterns,
  `datarestore-matrix-test` — зелені (merge PR #99 = `a3e6001`).
- Артефакт зібрано `ci/New-BRAVOReleaseArtifact.ps1 -Ref v5.2.0-rc.13
  -ExpectedTag v5.2.0-rc.13`; повний self-test зі staging-копії PASS;
  staging видалено до перерахунку маніфестів.

## 5. Відкриті позиції (не блокують промоцію)

- P2: тестове повідомлення dry-run завжди йде в перший resolved route
  (`alerts`) — legacy-поведінка, рішення (фікс у 5.3.0 чи rc.14) за
  власником.
- Перенесено на 5.3.0 (RELEASE_POLICY §20): settle/AV/enumeration
  Compare-FileSizes-фікси (`backup/local-developer-rc2-line`),
  `127e7e4` lock-wait diagnostics, P3.2a, M1 (WinSCP.uk), M3, BOM
  known-issue `Get-BRAVOSevenZipArchiveInventory`.

## 6. Висновок

Всі обов'язкові пункти acceptance циклу 5.2.0 закриті, включно з A2
(§1.1) в обох консольних контекстах із зафіксованими code page.
Кандидат `v5.2.0-rc.13` (stamp `0247ac3`) рекомендований до
**metadata-only** промоції stable `5.2.0`. Промоція вимагає окремої
явної авторизації власника.
