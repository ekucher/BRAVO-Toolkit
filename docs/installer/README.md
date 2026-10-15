# BRAVO Installer

## Статус

Цей каталог містить design-документацію майбутнього підсистемного напряму **BRAVO Installer & Update Lifecycle**.

Документація описує цільову архітектуру та план реалізації. Вона **не означає, що описані API, модулі, GUI, Scheduled Tasks або режими автоматичного оновлення вже реалізовані**.

Поточні `deploy/Install-BRAVOServer.ps1` і `deploy/Update-BRAVOServer.ps1` залишаються чинними operator-facing deployment helpers до появи та acceptance канонічного lifecycle engine.

## Мета

Перетворити встановлення, оновлення, відновлення та діагностику BRAVO Toolkit з набору окремих операторських сценаріїв на один безпечний lifecycle:

```text
              BRAVO.Update
             /     |      \
            /      |       \
 Installer GUI   CLI entry   Scheduled trigger
                 |
          BRAVO_UPDATE.ps1

BRAVO.Update є canonical lifecycle/deployment domain.
GUI, CLI entrypoint і майбутній Scheduled trigger не створюють
паралельних implementation deployment policy.
```

GUI не є власником deployment policy. Він відображає стан, збирає вибір оператора, показує план, запускає канонічний engine та відображає structured progress/result.

## Документи

- [ARCHITECTURE.md](ARCHITECTURE.md) — архітектура, trust boundary, deployment transaction, rollback/recovery, configuration, credentials та scheduled update.
- [UX.md](UX.md) — затверджений UX baseline Installer/Maintenance Center і поведінка всіх основних екранів.
- [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) — поетапний implementation train, залежності, gates, acceptance та Definition of Done.

## Основні інваріанти

1. Windows PowerShell 5.1 залишається підтримуваним runtime для BRAVO product/tests.
2. `BRAVO_RUNTIME_GUARD.ps1` зберігає pre-trust boundary.
3. GUI не дублює release, configuration, scheduler, integrity або rollback policy.
4. Site configuration та production data не повинні втрачатися під час install/update/repair.
5. Legacy `BRAVO.config` не видаляється і не мігрує автоматично без доведеної operator-controlled migration.
6. Після початку mutation failure має завершитися або доведено успішним rollback, або явним `CRITICAL/Manual intervention required`.
7. Scheduled update використовує той самий engine, що й ручне оновлення.
8. Production `Automatic` update не входить у P3.2a та залишається hard-blocked до завершення й acceptance повного P3.2: versioned release directories, deployment pointer, staging/validation, atomic activation, automatic rollback та update journal.
9. Prerelease deployment залишається fail-closed без explicit authorization.
10. Merged code не дорівнює real-host acceptance.

## Поточні залежності

Реалізація read-only foundation може починатися незалежно від production rollout. Реальне розгортання Installer/automatic update має враховувати окремі operational acceptance gates, зокрема fleet inventory, Config v2 migration та real-host acceptance.

Актуальний стан таких gates завжди перевіряється live перед deployment; цей документ не є snapshot їхнього статусу.
