# Агентський smoke-driver BRAVO-Toolkit: безпечна поверхня запуску
# (жодних production-операцій: без архівів, служб, планувальника, SFTP-запису).
#
#   .\.claude\skills\run-bravo-toolkit\smoke.ps1            # parse + forbidden + dry-run (~1 хв)
#   .\.claude\skills\run-bravo-toolkit\smoke.ps1 -Full      # + повний BRAVO_SELF_TEST (~8 хв)
#
# Exit 0 = усі кроки пройдено; інакше — номер першого провального кроку.
[CmdletBinding()]
param(
    [switch]$Full,
    # Тека для машиночитаних результатів (dry-run JSON, лог self-test).
    [string]$OutDir = (Join-Path $env:TEMP 'bravo-smoke')
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
Set-Location $root
if (-not (Test-Path $OutDir)) { [void](New-Item -ItemType Directory -Force $OutDir) }

Write-Host "== BRAVO smoke @ $root" -ForegroundColor Cyan

# --- Крок 1: PowerShell parse-check усього комплекту -------------------
Write-Host '== [1/4] Parse-check .ps1/.psm1' -ForegroundColor Cyan
$parseErrors = 0
Get-ChildItem -Recurse -Include '*.ps1', '*.psm1' -Path $root |
    Where-Object { $_.FullName -notmatch '\\(LOGS|TEMP|artifacts|\.claude)\\' } |
    ForEach-Object {
        $t = $null; $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$t, [ref]$e)
        if ($e.Count) {
            Write-Host "PARSE FAIL: $($_.FullName) ($($e[0].Message))" -ForegroundColor Red
            $parseErrors++
        }
    }
if ($parseErrors) { Write-Host "FAIL: parse errors=$parseErrors" -ForegroundColor Red; exit 1 }
Write-Host 'OK' -ForegroundColor Green

# --- Крок 2: заборонені патерни (той самий чек, що в CI) ---------------
Write-Host '== [2/4] Forbidden patterns' -ForegroundColor Cyan
& (Join-Path $root 'ci\Test-BRAVOForbiddenPattern.ps1')
if ($LASTEXITCODE -ne 0) { Write-Host 'FAIL: forbidden patterns' -ForegroundColor Red; exit 2 }

# --- Крок 3: DRY RUN — безпечна симуляція із JSON-результатом ----------
Write-Host '== [3/4] BRAVO_DRY_RUN (READ-ONLY simulation)' -ForegroundColor Cyan
$dryRunJson = Join-Path $OutDir 'dryrun-result.json'
& (Join-Path $root 'BRAVO_DRY_RUN.ps1') -AsJson -ResultPath $dryRunJson | Out-Null
$dryRunExit = $LASTEXITCODE
$dryRunRecords = @()
if (Test-Path $dryRunJson) {
    $dryRunRecords = Get-Content $dryRunJson -Raw | ConvertFrom-Json
}
$byStatus = $dryRunRecords | Group-Object Status
$counts = @{ PASS = 0; WARN = 0; FAIL = 0; PLAN = 0 }
foreach ($g in $byStatus) { $counts[$g.Name] = $g.Count }
Write-Host ("dry-run exit={0}; PASS={1} WARN={2} FAIL={3} PLAN={4} -> {5}" -f `
    $dryRunExit, $counts['PASS'], $counts['WARN'], $counts['FAIL'], $counts['PLAN'], $dryRunJson)
$dryRunRecords | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object {
    Write-Host ("  FAIL {0}/{1}: {2}" -f $_.Category, $_.Name, $_.Detail) -ForegroundColor Red
}
if ($dryRunExit -ne 0) { Write-Host 'FAIL: dry-run' -ForegroundColor Red; exit 3 }

# --- Крок 4 (опційно): повний self-test --------------------------------
if ($Full) {
    Write-Host '== [4/4] BRAVO_SELF_TEST (~8 хв)' -ForegroundColor Cyan
    $selfTestLog = Join-Path $OutDir 'selftest.log'
    & (Join-Path $root 'BRAVO_SELF_TEST.ps1') -NoPause *> $selfTestLog
    $selfTestExit = $LASTEXITCODE
    $stPass = (Select-String -Path $selfTestLog -Pattern '^\[PASS\]').Count
    $stFail = (Select-String -Path $selfTestLog -Pattern '^\[FAIL\]').Count
    Write-Host "self-test exit=$selfTestExit; PASS=$stPass FAIL=$stFail -> $selfTestLog"
    Select-String -Path $selfTestLog -Pattern '^\[FAIL\]' | Select-Object -First 10 |
        ForEach-Object { Write-Host "  $($_.Line)" -ForegroundColor Red }
    if ($selfTestExit -ne 0) { exit 4 }
} else {
    Write-Host '== [4/4] self-test пропущено (додайте -Full)' -ForegroundColor DarkGray
}

Write-Host '== SMOKE OK' -ForegroundColor Green
exit 0
