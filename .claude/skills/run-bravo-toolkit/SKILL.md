---
name: run-bravo-toolkit
description: Run, smoke-test, validate, or screenshot-check BRAVO-Toolkit locally — safe launch surface (dry-run simulation, full self-test, parse/forbidden checks) without touching production operations. Use for "run the toolkit", "start BRAVO", "smoke test", "dry run", "validate the bundle", "run self-test".
---

# Run BRAVO-Toolkit

BRAVO-Toolkit — операційний PowerShell 5.1 тулкіт (backup/maintenance/health
для production LIMS-серверів). Тут НЕМАЄ GUI і немає сервера; «запустити
застосунок» локально = **безпечна поверхня**: read-only симуляція
(`BRAVO_DRY_RUN.ps1`) та герметичний повний self-test. Реальні операційні
entrypoints (`BRAVO_ARCHIV.ps1`, `BRAVO_MAINTENANCE.ps1`, …) на робочій
машині НЕ запускати — вони чіпають служби, планувальник, SFTP і диски.

Усі шляхи нижче — відносно кореня репо (`E:\GitHub\BRAVO-Toolkit` або
відповідний worktree). Runtime — **Windows PowerShell 5.1** (не pwsh).

## Prerequisites

Нічого ставити не треба: Windows 11 + вбудований Windows PowerShell 5.1.
Перевірено на 5.1.26100.9168. `pwsh` (7+) не використовувати — комплект
таргетує 5.1-семантику.

## Run (agent path) — driver

```powershell
# швидкий smoke: parse + forbidden-patterns + dry-run (~1 хв), exit 0/1/2/3
.\.claude\skills\run-bravo-toolkit\smoke.ps1

# + повний BRAVO_SELF_TEST (~8 хв, ~1700 перевірок), exit 4 при FAIL
.\.claude\skills\run-bravo-toolkit\smoke.ps1 -Full
```

Драйвер друкує підсумок кожного кроку і кладе машиночитані результати в
`%TEMP%\bravo-smoke\` (`dryrun-result.json` — масив записів
`{Category, Name, Status, Detail}` зі статусами PASS/WARN/FAIL/PLAN;
`selftest.log` — повний лог self-test). Очікуваний здоровий результат на
дев-машині: dry-run `PASS≈57 WARN≈4 FAIL=0 PLAN≈21`, self-test `0 FAIL`.

Точкові виклики, з яких складено драйвер (кожен запускався і працює):

```powershell
# read-only симуляція з JSON-результатом (сама по собі)
.\BRAVO_DRY_RUN.ps1 -AsJson -ResultPath $env:TEMP\dryrun.json

# повний self-test (герметичний, фікстури в %TEMP% з GUID)
.\BRAVO_SELF_TEST.ps1 -NoPause

# CI-еквівалентні статичні чеки
.\ci\Test-BRAVOForbiddenPattern.ps1
.\ci\Invoke-BRAVOSecurityAnalysis.ps1     # потребує PSScriptAnalyzer 1.25.0
```

## Direct invocation (внутрішні функції без запуску entrypoint)

Більшість PR чіпають функції в `modules/BRAVO.<Domain>/`. Викликати їх без
повного запуску можна AST-екстракцією (так робить і self-test):

```powershell
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    "$PWD\BRAVO_RUNTIME_GUARD.ps1", [ref]$null, [ref]$null)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -eq 'ConvertTo-BRAVOComparableVersion' }, $true)
. ([scriptblock]::Create($fn.Extent.Text))
ConvertTo-BRAVOComparableVersion -Text '5.3.0-rc.1'
```

Модульні `.psm1` можна просто `Import-Module modules\BRAVO.<X>\BRAVO.<X>.psd1`,
але обережно: їхні Runtime-файли при звичайному виклику виконують реальні
операції — імпортуйте лише щоб дістати exported-обгортки, не викликайте
`Invoke-BRAVO*Entrypoint` з реальними параметрами.

## Run (human path)

Оператор на сервері запускає entrypoints напряму
(`.\BRAVO_DRY_RUN.ps1` перед першим прогоном, далі `BRAVO_ARCHIV.ps1` тощо
через Планувальник). На дев-машині це не відтворюється і не потрібно.

## Test

```powershell
.\BRAVO_SELF_TEST.ps1 -NoPause      # ~8 хв; підсумок [PASS]/[FAIL], exit 0/1
```

Після БУДЬ-ЯКОЇ зміни runtime-файлів перед self-test обовʼязково:

```powershell
.\ci\Update-BRAVORuntimeManifest.ps1 -Apply
```

інакше self-test упаде на RuntimeIntegrityViolation (манифест захищає
комплект від несанкціонованих змін — це фіча, не поломка).

## Gotchas (усе — реально спіймане)

- **UTF-8 BOM обовʼязковий для нових `.ps1`.** Файл без BOM із кирилицею
  PowerShell 5.1 читає в ANSI → mojibake і `Missing closing '}'` у
  парсера. Ліки: перезаписати `[IO.File]::WriteAllText($p, $text,
  (New-Object System.Text.UTF8Encoding($true)))`. CRLF також обовʼязковий
  (`.gitattributes`), інакше CI (не локальний прогін!) падає
  RuntimeIntegrityViolation.
- **`BRAVO_DRY_RUN.ps1` без прапорців — безпечний**, але `-TestAccess`
  НЕ read-only (створює відсутні SFTP-каталоги призначення), а
  `-SendTestNotification` реально шле у Slack/Discord. Не додавайте їх
  «для повноти».
- **Version-state:** dry-run викликає downgrade-guard із `-NoWrite` — стан
  машини не пишеться; але справжні entrypoints ПИШУТЬ
  `LOGS\BRAVO_VERSION_STATE.json` — ще одна причина не запускати їх локально.
- **Не запускати два повні self-test паралельно** в різних worktree —
  фікстури герметичні по `%TEMP%`+GUID, але окремі проби (Credential
  Manager, ACL) machine-global.
- **Логи**: кожен запуск будь-якого скрипта пише у `LOGS\HELPERS\` — тека
  ігнорується git-ом, чистити не обовʼязково.

## Troubleshooting

| Симптом | Причина → фікс |
|---|---|
| `Missing closing '}'` + кракозябри в помилці | .ps1 без BOM (див. Gotchas) → перезаписати з BOM |
| self-test: `RuntimeIntegrityViolation` | правили runtime-файл без regen манифеста → `.\ci\Update-BRAVORuntimeManifest.ps1 -Apply` |
| dry-run JSON: лічильники порожні | `-ResultPath` віддає МАСИВ записів, не обʼєкт із Summary — агрегуйте `Group-Object Status` |
| `Invoke-BRAVOSecurityAnalysis.ps1` падає одразу | нема PSScriptAnalyzer → `Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser` |
