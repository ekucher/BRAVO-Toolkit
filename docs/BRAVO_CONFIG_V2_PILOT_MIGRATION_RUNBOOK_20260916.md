# Pilot migration Configuration v2 — операторський runbook

**Задача:** #154, крок 1 «Remaining work» (pilot migration на одному сервері).
**Дата підготовки:** 2026-09-16.
**Статус:** процедура підготовлена; на жодному сервері ще не виконувалась.

## Мета

Довести на **одному** сервері, що перенесення site-значень із `BRAVO.config`
у `BRAVO.local.config` **не змінює ефективної конфігурації**. Це і є критерій
приймання, від якого залежать B5 (парк) і B4 частина 2 (фізичне прибирання
файлу з пакета).

## Межі

Runbook **не** прибирає `BRAVO.config` автоматично і не змінює його. Комплект
цього файлу не видаляє — крок виконує оператор свідомо, після звірки
(рішення зафіксоване в «Out of scope» #154).

Усі інструменти нижче, крім кроку 6, **нічого не записують** на сервері за
межами каталогу доказів, який ви вкажете самі.

## Передумови

1. Комплект версії, що містить `BRAVO.Configuration.Snapshot` (перевірка:
   файл `modules\BRAVO.Configuration\BRAVO.Configuration.Snapshot.psd1`
   існує).
2. Windows PowerShell 5.1 з правами на читання каталогу комплекту.
3. Каталог для доказів, наприклад `D:\BRAVO_MIGRATION_EVIDENCE`. Він має бути
   **поза** каталогом комплекту, інакше перевірка цілісності рантайму
   поскаржиться на сторонні файли.
4. Сервер **не** в момент виконання архівації: інструменти read-only, але
   знімок «до» і «після» має описувати той самий стан системи.

Далі `$Kit` — каталог комплекту, `$Ev` — каталог доказів.

```powershell
$Kit = 'C:\Program Files\BRAVO-Toolkit'
$Ev  = 'D:\BRAVO_MIGRATION_EVIDENCE'
New-Item -ItemType Directory -Path $Ev -Force | Out-Null
```

## Крок 0. Знімок BEFORE

```powershell
& "$Kit\BRAVO_CONFIG_TEST.ps1" -FullGraph |
    Set-Content -LiteralPath "$Ev\snapshot-A-before.json" -Encoding UTF8
```

**Чому `Set-Content -Encoding UTF8`, а не `>`.** У Windows PowerShell 5.1
оператор `>` пише файл у UTF-16LE. Інструмент порівняння читає знімки як
UTF-8, тож перенаправлення через `>` дало б не «відмінності», а помилку
розбору JSON — на кроці, де ви вже змінили конфігурацію.

Перевірте, що файл непорожній і починається з `{`. Якщо скрипт завершився
помилкою — **зупиніться**: мігрувати конфігурацію, яка не завантажується,
не можна.

Знімок містить `EffectiveGraph` — усі поля ефективної конфігурації, а не
лише корені. Саме тому тут `-FullGraph`, а не `-AsJson`.

## Крок 1. Дельта site-значень

```powershell
& "$Kit\deploy\Get-BRAVOConfigSiteDelta.ps1" -RuntimeRoot $Kit -OutputPath "$Ev\site-delta.config"
```

Інструмент відповідає на питання «що саме на ЦЬОМУ сервері перевизначено в
`BRAVO.config` відносно канонічних дефолтів». Наявний файл він не
перезаписує — за потреби вкажіть інший `-OutputPath`.

## Крок 2. Звірка дельти вручну

Це **не механічний** крок. Відкрийте `site-delta.config` і для кожного рядка
вирішіть, чи значення справді потрібне цій установі.

Наявність значення в `BRAVO.config` не доводить, що воно потрібне: частина
відмінностей — застаріла копія дефолтів попередньої версії комплекту, і
перенесення її в site-файл законсервувало б старий дефолт назавжди. Саме
цього епік і намагається позбутись.

Окремо перегляньте рядки з маркерами, які виписує інструмент:

| Маркер у файлі | Що робити |
| --- | --- |
| `[немає в BRAVO.config, діє дефолт]` | нічого; рядок інформаційний |
| `[уже є в BRAVO.local.config]` | нічого; повторний запис створив би дубль |
| `[УВАГА: форма вузла відрізняється...]` | перенести вручну; це зміна формату, а не site-значення |
| `[УВАГА: значення не серіалізується...]` | перенести вручну; розібратись у причині |
| `# НЕВІДОМИЙ канонічним дефолтам ключ` | звірити назву; ймовірна опечатка або ключ іншої версії |

## Крок 2а. Backup перед активацією

**Обов'язковий крок перед будь-яким записом `BRAVO.local.config`** (доповнення
незалежного аудиту Configuration v2 Pilot Preparation, 2026-09-16): до цього
місця runbook був лише read-only, і резервна копія існувала лише перед
деструктивним Кроком 6. Але Крок 3 нижче — це вже активація (перший
реальний запис у каталог комплекту), і якщо після нього щось піде не так
(помилка в шляху, невідповідність типу), відкат має спиратись на доведену
копію стану "до", а не на припущення, що файл можна просто видалити.

```powershell
$stampUtc = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$backupDir = Join-Path $Ev "backup-$stampUtc"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

Copy-Item -LiteralPath "$Kit\BRAVO.config" -Destination "$backupDir\BRAVO.config" -ErrorAction Stop
if (Test-Path -LiteralPath "$Kit\BRAVO.local.config") {
    Copy-Item -LiteralPath "$Kit\BRAVO.local.config" -Destination "$backupDir\BRAVO.local.config" -ErrorAction Stop
} else {
    # Відсутність файлу — теж частина стану "до"; фіксуємо це явно, а не
    # мовчки пропускаємо, інакше відкат не знатиме, чи файл видаляти.
    Set-Content -LiteralPath "$backupDir\BRAVO.local.config.absent" -Value "BRAVO.local.config був відсутній на момент backup ($stampUtc UTC)." -Encoding UTF8
}

Get-ChildItem -LiteralPath $backupDir -File | ForEach-Object {
    [pscustomobject]@{
        File      = $_.Name
        SHA256    = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        SizeBytes = $_.Length
        TimestampUtc = $stampUtc
    }
} | ConvertTo-Json | Set-Content -LiteralPath "$backupDir\backup-manifest.json" -Encoding UTF8
```

**Очікуваний результат:** `$backupDir` містить `BRAVO.config` (побайтова
копія), або `BRAVO.local.config`, або `BRAVO.local.config.absent`, і
`backup-manifest.json` з SHA-256 кожного скопійованого файлу.

**Критерій відмови:** будь-яка помилка `Copy-Item` — **зупиніться**, не
переходьте до Кроку 3. Резервна копія поза `$Ev` не рахується (вона має
пережити повторний запуск інструментів на цьому ж каталозі доказів).

**Дія відкату:** див. розділ «Відкат» нижче — він тепер відновлює саме з
`$backupDir`, а не лише з Кроку 6.

## Крок 3. Запис `BRAVO.local.config`

Перенесіть відібрані рядки у `BRAVO.local.config` поруч із `BRAVO.config`.
Якщо файл уже існує — **додайте** рядки, не замінюйте файл.

Формат і правила описані в `BRAVO.local.config.example`. Коротко про те, що
найчастіше ламає файл:

- значення лише літеральні — виклики, приведення типів, `$env:`,
  арифметика відхиляються, і файл відхиляється **цілком**;
- повторний ключ (регістронезалежно) і порожній ключ — помилка;
- усі сегменти шляху, крім останнього, мусять існувати в канонічній
  конфігурації;
- опечатка саме в **останньому** сегменті приймається (forward-compat) і
  тихо нічого не перевизначає — тому крок 5 обов'язковий.

## Крок 4. Знімок AFTER-1 (`BRAVO.config` ще на місці)

```powershell
& "$Kit\BRAVO_CONFIG_TEST.ps1" -FullGraph |
    Set-Content -LiteralPath "$Ev\snapshot-B-local-added.json" -Encoding UTF8
```

## Крок 5. Порівняння A ↔ B

```powershell
& "$Kit\deploy\Compare-BRAVOConfigEffectiveSnapshot.ps1" `
    -BeforePath "$Ev\snapshot-A-before.json" `
    -AfterPath  "$Ev\snapshot-B-local-added.json" `
    -RuntimeRoot $Kit
```

**Очікується `[SUCCESS]` і код завершення 0.** На цьому кроці site-файл лише
**повторює** те, що вже казав `BRAVO.config`, тож ефективні значення
змінитись не мають.

Очікувано відрізняються лише поля, що описують **джерело** конфігурації
(`LocalConfigPresent`, `AppliedLocalOverrideKeys`, `LoadedAt` тощо) — вони
перелічені в самому інструменті поіменно й виводяться окремим списком.

Якщо ви бачите `[ERROR]` і перелік неочікуваних відмінностей — **зупиніться
і не переходьте до кроку 6**. Найімовірніші причини:

- опечатка в останньому сегменті dot-шляху (див. крок 3) — значення не
  застосувалось;
- перенесене значення відрізняється від того, що було в `BRAVO.config`;
- у site-файлі опинилось похідне поле замість первинного.

## Крок 6. Прибирання `BRAVO.config` (деструктивний крок)

Спочатку — резервна копія **поза** каталогом комплекту:

```powershell
Copy-Item -LiteralPath "$Kit\BRAVO.config" -Destination "$Ev\BRAVO.config.backup" -ErrorAction Stop
Remove-Item -LiteralPath "$Kit\BRAVO.config"
```

Одразу після цього — знімок і порівняння **з вихідним** станом A:

```powershell
& "$Kit\BRAVO_CONFIG_TEST.ps1" -FullGraph |
    Set-Content -LiteralPath "$Ev\snapshot-C-primary-removed.json" -Encoding UTF8
& "$Kit\deploy\Compare-BRAVOConfigEffectiveSnapshot.ps1" `
    -BeforePath "$Ev\snapshot-A-before.json" `
    -AfterPath  "$Ev\snapshot-C-primary-removed.json" `
    -RuntimeRoot $Kit
```

**Очікується `[SUCCESS]` і код завершення 0.** Саме це порівняння (A ↔ C), а
не A ↔ B, є доказом міграції: воно показує, що зникнення primary-шару не
змінило жодного ефективного значення.

## Крок 6а. `BRAVO_SELF_TEST.ps1`

```powershell
& "$Kit\BRAVO_SELF_TEST.ps1" 2>&1 | Tee-Object -FilePath "$Ev\self-test-after-migration.log"
```

**Очікується** код завершення 0 (`SELF-TEST FAILED` відсутній у виводі).
Це ширша перевірка, ніж Кроки 4-6: вона включно з `RuntimeIntegrityMode`,
Configuration-модулями, Discovery і рештою доменів комплекту, а не лише
конфігураційним графом.

**Критерій відмови:** будь-який `[FAIL]` у виводі — **зупиніться**, перейдіть
до розділу «Відкат». Не намагайтесь виправляти окремі `[FAIL]` на цьому
етапі pilot — приймання зупиняється до з'ясування причини.

**Доказ:** `self-test-after-migration.log` у `$Ev`.

## Крок 6б. Health-перевірка

```powershell
& "$Kit\BRAVO_HEALTH.ps1" 2>&1 | Tee-Object -FilePath "$Ev\health-after-migration.log"
```

**Очікується** відсутність нових деградацій відносно останнього відомого
health-стану сервера ДО міграції (порівняйте вручну — health відображає
стан середовища, а не самої конфігурації, тож автоматичного eталона тут
немає).

**Критерій відмови:** нова деградація, якої не було до Кроку 3 — зупиніться,
розберіться, чи це наслідок міграції, перш ніж продовжувати.

**Доказ:** `health-after-migration.log` у `$Ev`.

## Крок 6в. Archive smoke test

Довід ефективної конфігурації (Кроки 0-6) навмисно **не замінює** перевірку
поведінки продукту (див. «Відомі межі процедури» нижче). Мінімальний
поведінковий доказ:

```powershell
& "$Kit\BRAVO_DRY_RUN.ps1" 2>&1 | Tee-Object -FilePath "$Ev\dry-run-after-migration.log"
```

**Очікується** успішне завершення dry-run (read-only перевірка доступу до
джерел/призначень і креденшелів). Якщо процедура включає підтверджену
maintenance-вікно — спостерігайте **першу реальну архівацію** після pilot і
збережіть її лог окремо; це не автоматизується цим runbook.

**Критерій відмови:** dry-run повідомляє про недоступний шлях/креденшел,
якого не було до міграції — зупиніться.

**Доказ:** `dry-run-after-migration.log` (+ лог першої реальної архівації,
якщо вікно дозволяє в рамках цього ж pilot-візиту).

## Крок 6г. Формальне прийняття (Acceptance)

Пілот вважається прийнятим лише коли оператор явно підтверджує кожен пункт
розділу «Що вважати прийняттям пілота» нижче й зберігає підписаний/датований
чекліст разом з рештою доказів у `$Ev`. До підтвердження перехід до B5
(решта парку) не починається.

## Відкат

Відкат **не залежить** від того, на якому кроці зупинились — він завжди
відновлює зі `$backupDir` Кроку 2а, а не з проміжного стану.

```powershell
Copy-Item -LiteralPath "$backupDir\BRAVO.config" -Destination "$Kit\BRAVO.config" -Force

if (Test-Path -LiteralPath "$backupDir\BRAVO.local.config") {
    Copy-Item -LiteralPath "$backupDir\BRAVO.local.config" -Destination "$Kit\BRAVO.local.config" -Force
} elseif (Test-Path -LiteralPath "$backupDir\BRAVO.local.config.absent") {
    # До міграції файлу не було — відкат прибирає той, що міг з'явитись.
    Remove-Item -LiteralPath "$Kit\BRAVO.local.config" -ErrorAction SilentlyContinue
}
```

Після відновлення файлів пройдіть ту саму послідовність доказів, що й після
міграції, порівнюючи з `snapshot-A-before.json`:

```powershell
& "$Kit\BRAVO_SETUP.ps1" -ValidateOnly 2>&1 | Tee-Object -FilePath "$Ev\rollback-validate-only.log"
& "$Kit\BRAVO_CONFIG_TEST.ps1" -FullGraph |
    Set-Content -LiteralPath "$Ev\snapshot-D-after-rollback.json" -Encoding UTF8
& "$Kit\deploy\Compare-BRAVOConfigEffectiveSnapshot.ps1" `
    -BeforePath "$Ev\snapshot-A-before.json" `
    -AfterPath  "$Ev\snapshot-D-after-rollback.json" `
    -RuntimeRoot $Kit
& "$Kit\BRAVO_SELF_TEST.ps1" 2>&1 | Tee-Object -FilePath "$Ev\self-test-after-rollback.log"
& "$Kit\BRAVO_HEALTH.ps1" 2>&1 | Tee-Object -FilePath "$Ev\health-after-rollback.log"
```

**Очікується:** `-ValidateOnly` без помилок, порівняння A↔D `[SUCCESS]`,
`BRAVO_SELF_TEST.ps1` код 0, health без нових деградацій. Відкат не вважається
завершеним, доки всі чотири не підтверджені — сам факт `Copy-Item` без
помилки НЕ є доказом успішного відкату.

Rollback executable незалежно від того, чи Крок 3-6 взагалі виконувались
успішно: якщо Крок 3 (запис `BRAVO.local.config`) сам провалився/дав
неочікуваний результат, той самий блок команд вище повертає сервер у стан
Кроку 2а без додаткових умов.

## Що вважати прийняттям пілота

- [ ] крок 2а (backup) — `backup-manifest.json` збережено з SHA-256 обох
      файлів (або явним `.absent`-маркером для відсутнього
      `BRAVO.local.config`);
- [ ] крок 5 (A ↔ B) — `[SUCCESS]`;
- [ ] крок 6 (A ↔ C) — `[SUCCESS]`;
- [ ] крок 6а (`BRAVO_SELF_TEST.ps1`) — код завершення 0;
- [ ] крок 6б (Health) — без нових деградацій відносно стану до міграції;
- [ ] крок 6в (Archive smoke) — `BRAVO_DRY_RUN.ps1` успішний; за наявності
      вікна — перша реальна архівація після pilot спостережена й
      залогована;
- [ ] `BRAVO_SETUP.ps1 -ValidateOnly` після кроку 6 проходить;
- [ ] усі знімки (A, B, C) і логи Кроків 6а-6в збережені як докази в `$Ev`;
- [ ] чекліст цього розділу підписаний/датований оператором (крок 6г).

Лише після цього має сенс переходити до B5 (решта парку).

## Відомі межі процедури

1. **Доказ стосується ефективної конфігурації, а не поведінки продукту.**
   Він показує, що значення ті самі; він не замінює звичайного
   післяміграційного прогону `BRAVO_DRY_RUN.ps1` і спостереження за першою
   реальною архівацією.
2. **Перелік полів канонічний, але скінченний.** Знімок покриває поля з
   `Get-BRAVOEffectiveConfigurationVariableName`; значення, яке не
   публікується як `$global:`, у порівняння не потрапляє.
3. **Поля, що описують джерело, порівнюються не як значення.** Їхній перелік
   у `deploy\Compare-BRAVOConfigEffectiveSnapshot.ps1` поіменний і свідомий;
   якщо міграція змінить якесь поле поза цим переліком, інструмент
   доповість про це як про неочікувану відмінність — і це правильно.
