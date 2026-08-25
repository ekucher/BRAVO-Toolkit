[CmdletBinding()]
param(
    [string]$Root,
    [string]$BaseRef,
    [string]$HeadRef
)

# Гейт RELEASE_POLICY.md §2.2/§12: master приймає код лише двома шляхами —
# stable-promotion з developer (пройшов CI/prerelease/real-server там) або
# документований hotfix/* (§12). Ніщо в GitHub раніше не перевіряло ЦЕ —
# PR #39 (нова фіча, feature/*-гілка, база master, без bump версії)
# змержився без жодного технічного бар'єру. Branch protection на master
# (required review/CI) — перший шар; цей скрипт — другий, специфічний до
# самої політики (джерело гілки + фактичне підняття версії), який
# спрацьовує саме в PR-контексті, де head/base відомі.

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path -LiteralPath (Join-Path $Root 'BRAVO_SELF_TEST.ps1') -PathType Leaf)) {
    Write-Host "Не схоже на корінь репозиторію BRAVO: $Root" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($BaseRef)) {
    $BaseRef = [Environment]::GetEnvironmentVariable('GITHUB_BASE_REF')
}
if ([string]::IsNullOrWhiteSpace($HeadRef)) {
    $HeadRef = [Environment]::GetEnvironmentVariable('GITHUB_HEAD_REF')
}

# GITHUB_BASE_REF заповнюється лише на pull_request-подіях. На push (той
# самий workflow реагує й на push) head/base для порівняння структурно
# немає — цей шар діє саме в PR, до merge; для push у master технічним
# бар'єром лишається branch protection (заборона прямого push).
if ([string]::IsNullOrWhiteSpace($BaseRef)) {
    Write-Host "Не PR-подія (GITHUB_BASE_REF порожній) — перевірку пропущено." -ForegroundColor Yellow
    exit 0
}
if ($BaseRef -notin @('master', 'main')) {
    Write-Host "Base-гілка '$BaseRef' — не master, перевірку пропущено." -ForegroundColor Yellow
    exit 0
}

Write-Host "Base: $BaseRef"
Write-Host "Head: $HeadRef"
Write-Host ""

$failures = New-Object System.Collections.ArrayList
function Add-BRAVOMasterMergePolicyFailure {
    param([Parameter(Mandatory = $true)][string]$Message)
    [void]$failures.Add($Message)
    Write-Host "::error::$Message"
}

# Семантична перевірка версії для промоції в master (RELEASE_POLICY §2.2,
# §3.3, §5.3): head мусить нести STABLE-версію X.Y.Z (без prerelease-
# суфікса) і бути семантично БІЛЬШОЮ за поточну master-версію. Проста
# нерівність рядків (попередня реалізація, ROADMAP P0.2) пропускала і
# downgrade, і prerelease — саме той клас помилок, від якого гейт має
# захищати промоційне вікно. Повертає перелік порушень (порожній = ОК).
function Test-BRAVOStableVersionPromotion {
    param(
        [Parameter(Mandatory = $true)][string]$HeadPackageVersion,
        [AllowNull()][AllowEmptyString()][string]$MasterPackageVersion
    )

    $versionFailures = New-Object System.Collections.ArrayList
    if ($HeadPackageVersion -notmatch '^\d+\.\d+\.\d+$') {
        [void]$versionFailures.Add(
            "RELEASE_POLICY.md §2.2/§5.3: у master дозволені лише stable-версії X.Y.Z — packageVersion '$HeadPackageVersion' містить prerelease-суфікс або має невалідний формат."
        )
        return @($versionFailures.ToArray())
    }
    $headBaseVersion = [version]$HeadPackageVersion

    if (-not [string]::IsNullOrWhiteSpace($MasterPackageVersion)) {
        # master теоретично може містити лише stable, але порівнюємо базову
        # частину захисно (історичні/аварійні стани не мають ламати парсер).
        $masterBaseText = ([string]$MasterPackageVersion -split '-', 2)[0]
        $masterBaseVersion = $null
        if (-not [version]::TryParse($masterBaseText, [ref]$masterBaseVersion)) {
            [void]$versionFailures.Add(
                "не вдалося розпарсити packageVersion поточного master ('$MasterPackageVersion') для семантичного порівняння — перевірте VERSION.json у master вручну."
            )
        } elseif ($headBaseVersion -le $masterBaseVersion) {
            [void]$versionFailures.Add(
                "RELEASE_POLICY.md §2.2/§4: packageVersion head ('$HeadPackageVersion') семантично НЕ БІЛЬШИЙ за поточний master ('$MasterPackageVersion') — downgrade або повтор версії в master заборонені."
            )
        }
    }
    return @($versionFailures.ToArray())
}

$allowedHeadPattern = '^(developer|hotfix/.+)$'
if ([string]::IsNullOrWhiteSpace($HeadRef) -or $HeadRef -notmatch $allowedHeadPattern) {
    Add-BRAVOMasterMergePolicyFailure "RELEASE_POLICY.md §2.2/§12: у master приймається код лише з 'developer' (stable promotion) або 'hotfix/*' (§12) — джерельна гілка '$HeadRef' не відповідає жодному з дозволених шляхів. Нову функціональність спершу розробіть і протестуйте в developer."
}

$versionPath = Join-Path $Root 'VERSION.json'
$headPackageVersion = $null
try {
    $headPackageVersion = [string](Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json).packageVersion
} catch {
    Add-BRAVOMasterMergePolicyFailure "не вдалося прочитати packageVersion із VERSION.json ($($_.Exception.Message))"
}

if ($headPackageVersion) {
    [void](& git -C $Root fetch origin master --depth=1 --quiet 2>$null)
    $masterVersionRaw = (& git -C $Root show origin/master:VERSION.json 2>$null) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($masterVersionRaw)) {
        Add-BRAVOMasterMergePolicyFailure "не вдалося прочитати VERSION.json з origin/master для звірки версії (git fetch/show)"
    } else {
        $masterPackageVersion = $null
        try {
            $masterPackageVersion = [string]($masterVersionRaw | ConvertFrom-Json).packageVersion
        } catch {
            Add-BRAVOMasterMergePolicyFailure "не вдалося розпарсити VERSION.json з origin/master: $($_.Exception.Message)"
        }
        foreach ($versionFailure in @(Test-BRAVOStableVersionPromotion `
                -HeadPackageVersion $headPackageVersion `
                -MasterPackageVersion $masterPackageVersion)) {
            Add-BRAVOMasterMergePolicyFailure $versionFailure
        }
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "MASTER MERGE POLICY: порушень — $($failures.Count)" -ForegroundColor Red
    exit 1
}
Write-Host "MASTER MERGE POLICY: гейт пройдено." -ForegroundColor Green
exit 0
