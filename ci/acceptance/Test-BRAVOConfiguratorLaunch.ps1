[CmdletBinding()]
param(
    [string]$RuntimeRoot,
    [int]$TimeoutSeconds = 12
)

# P2-A.7: детермінований, CI-небезпечний (не gate) launch-smoke для
# BRAVO_CONFIGURATOR.ps1 — те, що selftest\BRAVO_SELF_TEST.Configurator*.ps1
# НІКОЛИ не покриває (обидва фрагменти навмисно headless, ніколи не
# конструюють System.Windows.Forms.Form — саме цей розрив пропустив P1
# закритий над GetNewClosure()-дефект: усі 1572 self-test PASS, а реальний
# запуск падав одразу з "term ... is not recognized").
#
# Це НЕ замінює selftest — лише перевіряє, що процес реально стартує,
# завантажує модулі й доходить до блокуючого ShowDialog() без винятку.
# Жодного справжнього кліку/вводу не імітується (немає desktop GUI
# automation tooling у цьому середовищі) — "живий" процес після Timeout
# інтерпретується як "успішно дійшов до ShowDialog і чекає на оператора".
#
# CI-безпека: НЕ призначено як блокуючий gate у GitHub-hosted Windows
# runner-і — non-interactive/non-windowing сесія може поводитися
# непередбачувано для реального WinForms Form. Призначення — детермінований
# LOCAL acceptance-крок (реальна десктопна Windows-сесія розробника/
# оператора), що документує очікуваний результат. Скрипт сам НЕ намагається
# визначити, чи сесія windowing-здатна — виконавець відповідає за це.
#
# Ізоляція: -ProductionConfigDirectory вказує на порожню тимчасову
# директорію (%TEMP%) — реальний production BRAVO.local.config і
# Windows Credential Manager НЕ читаються/пишуться. $RuntimeRoot (модулі,
# BRAVO.config, RUNTIME_MANIFEST.json) лишається справжнім комплектом —
# саме його цілісність і перевіряється.
#
# Відома залежність поза межами цього smoke-тесту: якщо kit BRAVO.config
# має LIMSRoot=""/BackupRoot="" (AUTO) і хост не має встановленої служби
# BRAVO — Show-BRAVOConfiguratorMainForm впаде на РАННЬОМУ обчисленні
# DefaultConfig (Invoke-BRAVOConfiguratorEffectiveComputation) ще до
# побудови форми. Це ОЧІКУВАНА, environment-залежна поведінка (той самий
# AUTO-discovery клас, що selftest\BRAVO_SELF_TEST.Configurator.ps1
# документує для власної fixture) — НЕ closure-scope/module-defect. Скрипт
# відображає повний stdout/stderr, щоб виконавець міг відрізнити одне від
# іншого за текстом винятку.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $RuntimeRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$configuratorScriptPath = Join-Path $RuntimeRoot 'BRAVO_CONFIGURATOR.ps1'
if (-not (Test-Path -LiteralPath $configuratorScriptPath -PathType Leaf)) {
    Write-Host "[FAIL] BRAVO_CONFIGURATOR.ps1 не знайдено за RuntimeRoot='$RuntimeRoot'." -ForegroundColor Red
    exit 1
}

$isolatedConfigDirectory = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIGURATOR_LAUNCH_SMOKE_{0}" -f [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($isolatedConfigDirectory)
$stdoutPath = Join-Path $isolatedConfigDirectory 'stdout.log'
$stderrPath = Join-Path $isolatedConfigDirectory 'stderr.log'

$result = [pscustomobject]@{
    Passed               = $false
    Reason               = $null
    ExitedEarly          = $false
    ExitCode             = $null
    StdOut               = $null
    StdErr               = $null
    ChildrenDuringRun    = 0
    OrphansAfterCleanup  = 0
    FixtureCleanupOk     = $false
}
$process = $null
$script:capturedChildPids = @()

try {
    Write-Host "Launching: powershell.exe -NoProfile -File `"$configuratorScriptPath`" -ConfigPath `"$isolatedConfigDirectory`" -NoPause"
    $process = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$configuratorScriptPath`"",
            '-ConfigPath', "`"$isolatedConfigDirectory`"",
            '-NoPause'
        ) `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $exitedEarly = $false
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { $exitedEarly = $true; break }
        Start-Sleep -Milliseconds 250
    }

    $result.ExitedEarly = $exitedEarly
    if ($exitedEarly) {
        $result.ExitCode = $process.ExitCode
        $result.Passed = $false
        $result.Reason = "Процес завершився самостійно за $TimeoutSeconds сек (ExitCode=$($process.ExitCode)) — очікувався блокуючий ShowDialog()."
    } else {
        # Живий після Timeout -> дійшов до блокуючого ShowDialog() без винятку.
        # "Children during run" (напр. conhost.exe — нормальний baseline
        # console-host дочірній процес живого powershell.exe, підтверджений
        # ще в P1-стабілізації) — ОКРЕМЕ поняття від "orphans after
        # cleanup" нижче: наявність дочірніх процесів ПІД ЧАС життя батька
        # сама по собі НЕ є leak.
        $childProcessesDuringRun = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($process.Id)" -ErrorAction SilentlyContinue)
        $result.ChildrenDuringRun = $childProcessesDuringRun.Count
        $script:capturedChildPids = @($childProcessesDuringRun | ForEach-Object { [int]$_.ProcessId })
        $result.Passed = $true
        $result.Reason = "Процес живий після $TimeoutSeconds сек без винятку — успішно дійшов до блокуючого ShowDialog()."
    }
} finally {
    if ($null -ne $process -and -not $process.HasExited) {
        # Windows PowerShell 5.1 (.NET Framework): Process.Kill() НЕ має
        # entireProcessTree-перевантаження (те з'явилось лише в .NET
        # Core/5+) — вбиває ЛИШЕ сам parent, дочірні (напр. conhost.exe)
        # можуть лишитися сиротами. Тому: (1) kill parent за ЙОГО ВЛАСНИМ
        # PID (ніякого широкого kill за іменем); (2) детермінований grace
        # period; (3) targeted cleanup ЛИШЕ конкретних PID, зафіксованих
        # ДО kill (крок вище) — ніколи "Get-Process powershell | Stop-Process"
        # чи еквівалент, щоб не зачепити сторонні PowerShell/BRAVO процеси
        # на машині.
        try { $process.Kill() } catch { }
    }

    $graceDeadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $graceDeadline) {
        $stillAlive = @($script:capturedChildPids | Where-Object {
            $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue)
        })
        if ($stillAlive.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    }

    $remainingAfterGrace = @($script:capturedChildPids | Where-Object {
        $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue)
    })
    foreach ($childPid in $remainingAfterGrace) {
        try { Stop-Process -Id $childPid -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Milliseconds 300
    $result.OrphansAfterCleanup = @($script:capturedChildPids | Where-Object {
        $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue)
    }).Count

    $result.StdOut = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { $null }
    $result.StdErr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { $null }
    Remove-Item -LiteralPath $isolatedConfigDirectory -Recurse -Force -ErrorAction SilentlyContinue
    $result.FixtureCleanupOk = -not (Test-Path -LiteralPath $isolatedConfigDirectory)
}

# Orphan processes after cleanup — реальний process-cleanup contract
# violation, не косметичне попередження: FAIL, не warning.
if ($result.Passed -and $result.OrphansAfterCleanup -gt 0) {
    $result.Passed = $false
    $result.Reason = "$($result.OrphansAfterCleanup) дочірніх процес(ів) лишились ЖИВИМИ після grace period + targeted cleanup — process cleanup contract порушено."
}
if ($result.Passed -and -not $result.FixtureCleanupOk) {
    $result.Passed = $false
    $result.Reason = "Ізольована tmp-директорія fixture НЕ видалена після тесту ($isolatedConfigDirectory)."
}

if ($result.Passed) {
    Write-Host "[PASS] $($result.Reason)" -ForegroundColor Green
} else {
    Write-Host "[FAIL] $($result.Reason)" -ForegroundColor Red
}
Write-Host "Children during run: $($result.ChildrenDuringRun)"
Write-Host "Orphans after cleanup: $($result.OrphansAfterCleanup)"
Write-Host "Fixture cleanup: $(if ($result.FixtureCleanupOk) { 'PASS' } else { 'FAIL' })"
if (-not [string]::IsNullOrWhiteSpace($result.StdOut)) {
    Write-Host '--- stdout ---'
    Write-Host $result.StdOut
}
if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) {
    Write-Host '--- stderr ---'
    Write-Host $result.StdErr
}

exit $(if ($result.Passed) { 0 } else { 1 })
