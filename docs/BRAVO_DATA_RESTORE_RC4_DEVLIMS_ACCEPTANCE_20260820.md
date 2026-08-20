# BRAVO 5.1.0-rc.4 — DEV-LIMS Acceptance (2026-08-20) — PASS

Повний повторний acceptance-прогін кандидата 5.1.0-rc.4 на DEV-LIMS.
Причина повного повтору: функціональний runtime-фікс PR #62 (severity-routing
сповіщень DataRestore: GENERAL/ALERTS) інвалідував частковий rc.3-евіденс;
рішення оператора — фікс зараз → rc.4 → повний повтор (логи B15/B19 з
нічного rc.3-прогону не збережені).

## 1. Candidate identity (verified)

```
Deploy ref (stamp):  219c55b7aa83aa2cc091629591a73075cf4045a0 (developer)
VERSION.json:
  packageVersion:    5.1.0-rc.4
  releaseChannel:    prerelease
  releaseDate:       2026-08-20
  buildId:           d90c3c2
  sourceCommit:      d90c3c242a729e8fa8d3a232ec4b01a3796308cc
Артефакт:            BRAVO-Toolkit-5.1.0-rc.4.zip (11 768 609 байт)
SHA-256:             a825415c4275b8585c3b8896d655766545edfab2514902889229b80f096ca6b9
                     (звірено на DEV-LIMS: збіг)
Розгортання:         D:\BRAVO-Toolkit-5.1.0-rc.4
Runtime Guard:       exit 0 — цілісність підтверджена (75 файлів) — двічі
                     (після розгортання і після B16)
Ланцюжок комітів:    7a1000f (merge PR #62) -> 07b61a3 (open rc.4) ->
                     5343e11 (stamp) -> d90c3c2 (re-stamp CRLF) ->
                     219c55b (strip md BOM + re-stamp)
CI push 219c55b:     success (self-test, DataRestore matrix, PSSA,
                     Parser/BOM/JSON, gitleaks)
```

Середовище: DEV-LIMS (Windows Server 2022, PowerShell 5.1.20348.5386),
оператор `BSYSTEM\e.kucher`, елевейтед; LIMSRoot=E:\LIMS (service
discovery), BackupRoot=E:\LIMS\ARCHIV; служба BRAVO. Фонові задачі
Maintenance/Health вимкнені (Disabled), BRAVO_ARCHIV увімкнена (23:00).

## 2. Підсумок сценаріїв

| Сценарій | Результат | Evidence |
|---|---|---|
| Setup (Action Test) | PASS | 16/16 креди FOUND (user + SYSTEM, вкл. DiscordWebhookGeneral/Alerts); dry-run 45 PASS / 2 WARN (навмисні skip) / 0 FAIL; scheduler validate OK |
| Ручний Archive | PASS | 11:41, generation 20260820_114117 COMPLETE 3/3, SFTP 7/7, exit 0; звіт → GENERAL |
| Health standalone | PASS | exit 0 Healthy; сповіщення NotRequired — очікувано (SUCCESS шлеться лише з -NotifyOnSuccess) |
| B4 + B17 (SFTP OutOfPlace MODEL) | PASS | exit 0; staging preflight пройдено (не exit 90/ProbeDirectory); завантаження з SFTP + перевірки OK; TargetPath D:\TEST_RESTORE_B17; звіт → GENERAL |
| B15 (InPlace MODEL) | PASS | 12:56, exit 0; move-aside Model.prerestore_20260820_125605; 536 файлів 8.4 ГБ; post-restore Health 0; служба Running; звіт → GENERAL |
| B16 (InPlace All) | PASS | 13:03, exit 0; MODEL+BLOG+BRAVOEXCH ВІДНОВЛЕНО; prerestore-триплет _130325; попередні копії збережені; Health 0; Runtime Guard 0 |
| B16 fail-closed (бонус) | PASS | 13:00, exit 43 на free-space preflight (21.15 ГБ < 10.37+20 резерв через накопичені prerestore-копії); ЖОДНОЇ мутації; звіт → ALERTS |
| Guard підтвердження (бонус) | PASS | 13:09, порожнє/невірне підтвердження GenerationId → exit 30 InvalidConfiguration, «жодних змін не виконано» |
| B19 (rollback MODEL, failpoint AfterMoveAside:MODEL) | PASS | 13:05, exit 43; журнал: «Rollback виконано: E:\LIMS\Model повернуто до стану перед відновленням»; prerestore _130548 зник (rename назад); служба Running; звіт → ALERTS |
| B20 (cross-component rollback, failpoint AfterMoveAside:BRAVOEXCH) | PASS | 13:10, exit 43; MODEL і BLOG встигли відновитись, потім «ВІДКОЧЕНО» обидва + bravoexch («Rollback виконано» ×3 у журналі); prerestore _131032 зникли; часткового/змішаного стану немає; служба Running; звіт → ALERTS |
| B21 (SFTP-аборт, firewall block TCP/22) | PASS | 13:17, exit 50 SftpFailed на переліку manifest-ів (fail-closed валідація WinSCP XML); ЖОДНОЇ live-мутації (нових prerestore нема, служба не зупинялась); звіт → ALERTS |
| B22 (operation lock contention) | PASS | DataRestore стартував 13:37:52 паралельно з Archive (13:36-13:41, тримав BRAVO_OPERATION.lock); ЧЕКАВ до 13:41:23 («Operation lock захоплено»), паралельного доступу не було; після звільнення оператор підтвердив — реальне відновлення MODEL з generation 20260820_133611, exit 0, Health 0 |

## 3. Severity-routing (головна мета rc.4) — ПІДТВЕРДЖЕНО

Каналів рівно два; legacy-таргет не задіюється (route-специфічні креди
налаштовані):

- SUCCESS → **GENERAL**: Archive (двічі), DataRestore B17, B15 — підтверджено оператором.
- FAILED/CRITICAL → **ALERTS**: DataRestore exit 43 (B16 free-space,
  B19 rollback, B20 cross-rollback) і exit 50 (B21 SFTP) — підтверджено
  оператором. Саме цей клас повідомлень у rc.3 помилково падав у GENERAL.

## 4. Відхилення від плану прогону (не впливають на вердикт)

1. B22 планувався зі скасуванням на підтвердженні; оператор підтвердив —
   виконалось реальне відновлення (exit 0, Health 0). Ключове
   спостереження сценарію (очікування lock, відсутність паралельного
   виконання) зафіксовано журналом; фактичний перебіг сильніший за план.
   (Підпис оператора в чаті помилково вказував exit 30; авторитетний
   журнал: «Завершення з кодом 0 (Success)».)
2. Перший запуск B16 чесно зупинився fail-closed через брак місця
   (накопичені prerestore-копії з rc.2/rc.3 прогонів) — прибрано 4 старі
   Model.prerestore_*, повтор PASS. Записано як бонус-евіденс.
3. Setup-крок [5/5] (тест-сповіщення) не зафіксовано в чаті окремо;
   e2e-ланцюжок вебхуків доведено бойовими звітами Archive/DataRestore.
4. Health SUCCESS-сповіщення «SKIPPED/NotRequired» — очікувана поведінка
   (за замовчуванням success-звіт Health шлеться лише з -NotifyOnSuccess).

## 5. Прибирання після прогону

- Видалено до повтору B16: Model.prerestore_20260815_154407,
  _20260817_021714, _20260819_231307, _20260820_020736.
- Залишаються до ручного прибирання після підтвердження працездатності:
  D:\TEST_RESTORE_B17; сьогоднішні prerestore-копії (Model _125605,
  _130325, _133751; BLOG _130325; bravoexch _130325) і застарілі
  BLOG/bravoexch .prerestore_* з rc.2/rc.3 прогонів.

## 6. Вердикт

**PASS — рекомендація PROMOTE.** Усі обов'язкові сценарії runbook
(B4/B15/B16/B19/B20/B17/B21/B22 + Setup/Archive/Health + routing
GENERAL/ALERTS) пройдені на точному deploy ref `219c55b` з артефактом
sha256 `a825415c…`. Вердикт є acceptance-евіденсом, а не авторизацією
публікації: stable-промоція 5.1.0 виконується окремою metadata-only
операцією за явною командою оператора (PR #61).
