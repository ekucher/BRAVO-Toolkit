[CmdletBinding()]
param(
    [string]$RuntimeRoot,
    [string]$ConfigPath
)

# Real-server acceptance-крок для конкретної знахідки (2026-09-02, сервер
# "SERVER"): BRAVO_SETUP.ps1 fail-closed зупинявся на [FAIL] VSS, бо джерела
# архіву (MODEL/BLOG/BRAVOEXCH) лежали на РІЗНИХ томах (E:, C:), а
# diskshadow.exe — потрібний для атомарного багатотомного VSS Snapshot Set —
# на клієнтських Windows 10/11 штатно відсутній (підтверджено на 2 машинах).
#
# Узгоджене рішення: НЕ послаблювати fail-closed VSS-перевірку (rule 07),
# а звести MODEL/BLOG/BRAVOEXCH на ОДИН том — тоді BRAVO бере однотомний
# Win32_ShadowCopy.Create (New-BRAVOVSSSnapshotSet, modules/BRAVO.Archive/
# BRAVO.Archive.Runtime.ps1) і diskshadow.exe не потрібен узагалі.
#
# Це НЕ дублює VSS-логіку — вона й далі одна, канонічна, у
# BRAVO_DRY_RUN.ps1/BRAVO.Archive.Runtime.ps1. Скрипт лише запускає
# canonical BRAVO_DRY_RUN.ps1 як дочірній процес (той самий патерн, що і
# Invoke-ChildPowerShell у BRAVO_SETUP.ps1: окремий powershell.exe, бо
# Complete-BRAVOHelperLog завершується `exit`, який інакше вбив би й цей
# acceptance-скрипт), забирає його структурований результат (-ResultPath,
# без -AsJson — щоб оператор і далі бачив живий людський звіт у консолі) і
# звіряє категорію VSS/Джерело для одного конкретного питання: "чи справді
# всі джерела тепер на одному томі, і чи VSS-preflight через це PASS".
#
# Запускати на цільовому сервері ПІСЛЯ фізичного перенесення даних
# (наприклад, C:\bravoexch -> E:\LIMS\bravoexch) і виправлення відповідного
# шляху (BEXCH=) у bravo.ini — сам скрипт нічого не переносить і не пише.
#
# -SkipCredentials передається в BRAVO_DRY_RUN.ps1: це вузька перевірка VSS/
# discovery, Credential Manager тут не в темі (той самий підхід, що крок
# [1/5] "Локальний preflight" у BRAVO_SETUP.ps1).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $RuntimeRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

$dryRunScriptPath = Join-Path $RuntimeRoot 'BRAVO_DRY_RUN.ps1'
if (-not (Test-Path -LiteralPath $dryRunScriptPath -PathType Leaf)) {
    throw "BRAVO_DRY_RUN.ps1 не знайдено: $dryRunScriptPath"
}

$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
    throw "Windows PowerShell не знайдено: $powerShellPath"
}

$resultPath = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_VSS_ACCEPTANCE_{0}.json" -f [guid]::NewGuid().ToString('N'))

$childArguments = [Collections.Generic.List[string]]::new()
$childArguments.AddRange([string[]]@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dryRunScriptPath))
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $childArguments.AddRange([string[]]@('-ConfigPath', $ConfigPath))
}
$childArguments.AddRange([string[]]@('-SkipCredentials', '-ResultPath', $resultPath))

Write-Host ''
Write-Host '=== BRAVO VSS Single-Volume Acceptance ===' -ForegroundColor Cyan
Write-Host "RuntimeRoot: $RuntimeRoot"
Write-Host "DryRun:      $dryRunScriptPath"
Write-Host ''

try {
    & $powerShellPath @childArguments
    $dryRunExitCode = $LASTEXITCODE

    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw "BRAVO_DRY_RUN.ps1 не створив -ResultPath (exit code дочірнього процесу: $dryRunExitCode) — перевірте вивід вище"
    }

    $rawDryRunResults = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    $dryRunResults = @($rawDryRunResults)

    $sourceEntries = @($dryRunResults | Where-Object { $_.Category -eq 'Джерело' -and $_.Name -in @('MODEL', 'BLOG', 'BRAVOEXCH') })
    $vssEntries = @($dryRunResults | Where-Object { $_.Category -eq 'VSS' })

    Write-Host ''
    Write-Host '--- Томи джерел ---' -ForegroundColor Cyan
    $volumesSeen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($entry in $sourceEntries) {
        $volumeMatch = [regex]::Match([string]$entry.Detail, 'volume=([A-Za-z]:)')
        $volumeText = if ($volumeMatch.Success) { $volumeMatch.Groups[1].Value } else { '?' }
        if ($volumeMatch.Success) { [void]$volumesSeen.Add($volumeMatch.Groups[1].Value.ToUpperInvariant()) }
        Write-Host ("  {0,-10} -> {1}  ({2})" -f $entry.Name, $volumeText, $entry.Detail)
    }
    if ($sourceEntries.Count -eq 0) {
        Write-Host '  (жодного джерела MODEL/BLOG/BRAVOEXCH не знайдено в результаті — перевірте discovery/config)' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '--- VSS ---' -ForegroundColor Cyan
    foreach ($entry in $vssEntries) {
        $color = switch ($entry.Status) { 'PASS' { 'Green' }; 'FAIL' { 'Red' }; default { 'Yellow' } }
        Write-Host ("  [{0}] {1}: {2}" -f $entry.Status, $entry.Name, $entry.Detail) -ForegroundColor $color
    }
    if ($vssEntries.Count -eq 0) {
        Write-Host '  (жодного результату категорії VSS не знайдено — можливо, немає enabled archive-джерел)' -ForegroundColor Yellow
    }

    $vssFailCount = @($vssEntries | Where-Object { $_.Status -eq 'FAIL' }).Count
    $singleVolume = $volumesSeen.Count -le 1

    Write-Host ''
    Write-Host '=== ВЕРДИКТ ===' -ForegroundColor Cyan
    Write-Host ("  Унікальних томів серед джерел: {0} ({1})" -f $volumesSeen.Count, (($volumesSeen | Sort-Object) -join ', '))
    Write-Host ("  VSS FAIL: {0}" -f $vssFailCount)

    if ($vssFailCount -eq 0 -and $singleVolume) {
        Write-Host '  PASS: джерела на одному томі, VSS preflight пройшов без diskshadow.exe.' -ForegroundColor Green
        exit 0
    } elseif ($vssFailCount -eq 0) {
        Write-Host '  PASS (з увагою): VSS preflight пройшов, але джерела досі на кількох томах — ' -ForegroundColor Yellow -NoNewline
        Write-Host 'ймовірно diskshadow.exe тепер є в системі; консолідація на цьому сервері не обов''язкова.' -ForegroundColor Yellow
        exit 0
    } else {
        Write-Host '  FAIL: VSS preflight не пройшов. Якщо джерела досі на кількох томах — перенесення ще не завершено' -ForegroundColor Red
        Write-Host '  або bravo.ini досі вказує на старий шлях. Див. README.md §1 (застереження diskshadow.exe).' -ForegroundColor Red
        exit 1
    }
} finally {
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    }
}
