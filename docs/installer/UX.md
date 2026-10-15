# BRAVO Installer — UX baseline

## 1. Принципи

Цей документ фіксує погоджений UI/UX baseline BRAVO Installer.

1. Оператор не повинен знати, який `.ps1` запускати.
2. Installer автоматично визначає стан машини.
3. Clean install та existing installation мають різні primary actions.
4. Перед mutation завжди показується deployment plan.
5. Progress відображає реальні structured phases engine.
6. Failure screen чітко розрізняє failure до mutation, успішний rollback та rollback failure.
7. Advanced technical details доступні, але не перевантажують wizard.
8. Warning/blocked state не маскується зеленим загальним статусом.
9. GUI не приховує policy у presentation layer.
10. Основна мова цього design — українська.

## 2. Візуальний baseline

Windows-style wizard: світлий фон, синій акцент, зелений лише для підтвердженого success, жовтий для warning, червоний для blocking/error/critical, ліва навігація по кроках, одна очевидна primary action та expandable technical details.

Згенерований concept mockup є візуальним орієнтиром, але нормативним джерелом поведінки є цей документ.

## 3. Clean install wizard

### Крок 1. Вітання

```text
BRAVO Toolkit
Installer

BRAVO Toolkit не встановлено.

[ Встановити BRAVO ]

Діагностика
```

Installer не просить вручну вибрати Install/Update, якщо стан визначається автоматично.

### Крок 2. Перевірка системи

```text
Система                     ✓
Windows PowerShell 5.1      ✓
Права адміністратора        ✓
Вільне місце                ✓
Release metadata            ✓
Конфігурація                —
Попередня установка         Не знайдено
```

Blocking result вимикає `Далі` та показує actionable explanation.

### Крок 3. Версія

За замовчуванням — рекомендований stable release. Prerelease доступний лише через advanced/operator path з явним warning та confirmation.

### Крок 4. Налаштування

```text
Профіль сервера

● Сервер працює цілодобово
○ Сервер робочого часу
○ Розширене налаштування
```

Профілі не створюють паралельні defaults; вони відображають canonical configuration model. Advanced configuration використовує canonical Configurator.

### Крок 5. Credentials

Показуються тільки потрібні поля. Secret не відображається повторно після прийняття і не потрапляє в plan/log.

### Крок 6. План

Остання confirmation point до mutation.

```text
План встановлення

Версія
BRAVO Toolkit <version> stable

Каталог
C:\Program Files\BRAVO-Toolkit

Буде виконано
✓ Перевірка release artifact
✓ Встановлення runtime
✓ Локальна конфігурація
✓ Credentials
✓ Scheduled Tasks
✓ Runtime ACL
✓ Integrity validation
✓ Final validation

[ Встановити ]
```

### Крок 7. Виконання

```text
Перевірка release            ✓
Підготовка runtime           ✓
Backup                       ✓
Встановлення                 ...
Scheduled Tasks
Final validation
```

Cancel після mutation не завершує процес небезпечно; UI пояснює, що Installer повертає систему до безпечного стану.

### Крок 8. Перевірка

```text
Runtime integrity       ✓
Configuration           ✓
Credentials             ✓
Scheduled Tasks         ✓
Final validation        ✓
```

### Крок 9. Завершення

```text
BRAVO Toolkit успішно встановлено

Версія: <version>
Стан: готовий до роботи

[ Завершити ]

Налаштувати
Діагностика
Переглянути журнал
```

## 4. Existing installation / Maintenance Center

```text
BRAVO Toolkit

Встановлено
<version> <channel>

Стан системи
✓ Runtime
✓ Конфігурація
✓ Планувальник
✓ Цілісність

Доступне оновлення
<target version>

[ Оновити ]

Налаштувати
Діагностика
Відновити компоненти
Переглянути журнали
```

Якщо update відсутній, UI не створює фальшивої необхідності оновлення.

## 5. Update flow

Update повторно використовує:

```text
Preflight
-> Release
-> Plan
-> Progress
-> Validation
-> Result
```

Plan показує current/target version та channel.

## 6. Legacy configuration blocker

```text
Оновлення потребує міграції конфігурації

На сервері знайдено локальні параметри старого формату.
Автоматичне оновлення зупинено, щоб не втратити
налаштування цього сервера.

[ Переглянути відмінності ]
[ Запустити майстер міграції ]

Оновити зараз — недоступно
```

Не надавати `Ignore and continue`.

## 7. Repair

```text
Відновлення BRAVO

✓ VERSION.json
✗ Runtime integrity
✓ Configuration
⚠ Scheduled Tasks

Рекомендовано:
• відновити runtime поточної версії;
• узгодити Scheduled Tasks.

Site configuration буде збережено.

[ Відновити ]
```

Repair не маскується під Update.

## 8. Diagnostics

Read-only screen:

```text
BRAVO Diagnostics

Runtime               ✓
Integrity             ✓
Configuration         ✓
Credentials           ✓
Scheduled Tasks       ⚠
Discovery baseline    ✓
Release provenance    ✓

1 попередження

[ Зберегти діагностичний звіт ]
```

Diagnostics не змінює production state.

## 9. Failure states

### Failure до mutation

```text
Операцію не виконано
Runtime не змінювався.
Причина: <actionable reason>

[ Повторити ]
[ Переглянути журнал ]
```

### Failure + rollback success

```text
Оновлення не завершено

Попередню версію BRAVO успішно відновлено.
Система повернута до перевіреного стану.

[ Завершити ]
[ Переглянути журнал ]
```

Це failure, а не success.

### Rollback failure

```text
КРИТИЧНИЙ СТАН

Автоматичне відновлення не завершено.
Стан runtime не підтверджено.

Не запускайте подальше оновлення до ручної перевірки.

[ Відкрити журнал ]
[ Зберегти діагностику ]
```

## 10. Interrupted operation

```text
Попереднє оновлення BRAVO було перервано

Версія: <source> → <target>
Останній завершений етап: <phase>

Рекомендована дія:
● Відновити попередню перевірену версію

[ Відновити ]
```

Resume-from-middle не є вимогою v1.

## 11. Update Settings

```text
Оновлення

☑ Автоматично перевіряти оновлення

Канал
Stable

Режим
● Повідомити
○ Завантажити та підготувати
○ Встановлювати автоматично
```

Відповідність engine policy:

```text
Повідомити                  -> NotifyOnly
Завантажити та підготувати -> StageOnly
Встановлювати автоматично  -> Automatic
```

Default — `NotifyOnly`. Maintenance window показується лише для `Automatic`.

## 12. Prerelease UX

```text
Попередня версія

<version>
Канал: prerelease

Ця версія призначена для тестування.

[ ] Я розумію ризик

[ Встановити prerelease ]
```

Без explicit confirmation primary action недоступна.

## 13. Technical details

Result screen дозволяє відкрити operation ID, version/provenance, phase, warning/error details, log path та rollback status. Secrets не відображаються.

## 14. UX acceptance

UI прийнятний лише якщо clean install можна пройти без знання внутрішніх scripts; existing installation автоматично визначається; operator бачить mutation plan; warnings не маскуються; rollback result однозначний; critical state неможливо сплутати з success; GUI не парсить console decorations; небезпечні actions мають engine-side policy.
