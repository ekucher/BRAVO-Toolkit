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

## Крок 3. Запис `BRAVO.local.config`

**Спершу збережіть поточний стан site-файла** — інакше відкат не поверне
сервер у допілотний стан: крок 6 відновлює лише `BRAVO.config`, а додані
локальні значення мають вищий пріоритет і мовчки затінювали б відновлений
primary-шар.

```powershell
# Спершу прибираємо ОБИДВА артефакти попереднього прогону. Без цього
# повторний пілот у тому самому $Ev успадкував би маркер .ABSENT від
# минулого разу: резервна копія створилась би, але відкат усе одно пішов
# би гілкою маркера й ВИДАЛИВ реальний site-файл замість відновлення.
Remove-Item -LiteralPath "$Ev\BRAVO.local.config.backup" -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$Ev\BRAVO.local.config.ABSENT" -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath "$Kit\BRAVO.local.config") {
    Copy-Item -LiteralPath "$Kit\BRAVO.local.config" -Destination "$Ev\BRAVO.local.config.backup" -ErrorAction Stop
} else {
    # Файла не було: позначаємо це, щоб відкат знав, що його треба ВИДАЛИТИ,
    # а не відновлювати.
    Set-Content -LiteralPath "$Ev\BRAVO.local.config.ABSENT" -Value '' -Encoding UTF8
}
```

Два артефакти **взаємовиключні за побудовою**: або резервна копія, або
маркер відсутності, ніколи обидва.

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
Remove-Item -LiteralPath "$Kit\BRAVO.config" -ErrorAction Stop
if (Test-Path -LiteralPath "$Kit\BRAVO.config") {
    throw 'BRAVO.config усе ще на місці — знімок C знімати НЕ МОЖНА.'
}
```

**`-ErrorAction Stop` і перевірка `Test-Path` тут обов'язкові.** Без них
відмова видалення (права, блокування файла, ФС) — **нетермінальна**: сесія
пішла б далі й зняла знімок C при живому `BRAVO.config`. Граф тоді
збігається з A, порівняння друкує `[SUCCESS]`, і міграція, яка насправді
нічого не прибрала, була б прийнята.

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

## Відкат

Відновлюються **обидва** шари. Повернути лише `BRAVO.config` недостатньо:
site-файл має вищий пріоритет, і залишені в ньому значення затінювали б
відновлений primary-шар — сервер виглядав би відкоченим, не будучи ним.

```powershell
# Захист від суперечливого стану каталогу доказів: рівно один артефакт.
$localBackup = Test-Path -LiteralPath "$Ev\BRAVO.local.config.backup"
$localAbsent = Test-Path -LiteralPath "$Ev\BRAVO.local.config.ABSENT"
if ($localBackup -eq $localAbsent) {
    throw "Стан site-файла в каталозі доказів неоднозначний (backup=$localBackup, absent=$localAbsent) — відкат зупинено."
}

Copy-Item -LiteralPath "$Ev\BRAVO.config.backup" -Destination "$Kit\BRAVO.config" -Force -ErrorAction Stop

if ($localAbsent) {
    # Файла до пілота не було -> прибираємо створений нами.
    Remove-Item -LiteralPath "$Kit\BRAVO.local.config" -ErrorAction Stop
} else {
    Copy-Item -LiteralPath "$Ev\BRAVO.local.config.backup" -Destination "$Kit\BRAVO.local.config" -Force -ErrorAction Stop
}
```

Далі — контрольний знімок **під ОКРЕМИМ іменем**:

```powershell
& "$Kit\BRAVO_CONFIG_TEST.ps1" -FullGraph |
    Set-Content -LiteralPath "$Ev\snapshot-R-rollback.json" -Encoding UTF8

& "$Kit\deploy\Compare-BRAVOConfigEffectiveSnapshot.ps1" `
    -BeforePath "$Ev\snapshot-A-before.json" `
    -AfterPath  "$Ev\snapshot-R-rollback.json" `
    -RuntimeRoot $Kit
```

**Не перезаписуйте `snapshot-A-before.json`.** Якщо зняти відкочений стан
поверх вихідного файла, наступне порівняння звірятиме файл сам із собою і
неминуче дасть `[SUCCESS]`, нічого не довівши. Вихідний знімок A — єдина
точка відліку, і він має пережити весь пілот.

Очікується `[SUCCESS]`: відкат повернув ефективну конфігурацію до стану A.

## Що вважати прийняттям пілота

- [ ] крок 5 (A ↔ B) — `[SUCCESS]`;
- [ ] крок 6 (A ↔ C) — `[SUCCESS]`;
- [ ] `BRAVO_SETUP.ps1 -ValidateOnly` після кроку 6 проходить;
- [ ] усі чотири JSON-знімки збережені як докази.

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
