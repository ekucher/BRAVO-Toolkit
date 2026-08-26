[CmdletBinding()]
param(
    [string]$Root,
    [string]$BaseRef,
    [string]$HeadRef,
    [string]$HeadRepository,
    [string]$BaseRepository
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

# Repository identity (ROADMAP P0.2): ім'я head-гілки НЕ ідентифікує
# репозиторій — PR з fork'а може мати гілку 'developer' чи 'hotfix/x' і
# пройти перевірку імені. Base-репозиторій береться з GITHUB_REPOSITORY;
# head-репозиторій дефолтних env-змінних не має, тому читаємо payload
# події з GITHUB_EVENT_PATH (pull_request.head.repo.full_name). Параметри
# -HeadRepository/-BaseRepository дозволяють локальний запуск і регресії.
if ([string]::IsNullOrWhiteSpace($BaseRepository)) {
    $BaseRepository = [Environment]::GetEnvironmentVariable('GITHUB_REPOSITORY')
}
if ([string]::IsNullOrWhiteSpace($HeadRepository)) {
    $eventPath = [Environment]::GetEnvironmentVariable('GITHUB_EVENT_PATH')
    if (-not [string]::IsNullOrWhiteSpace($eventPath) -and (Test-Path -LiteralPath $eventPath -PathType Leaf)) {
        try {
            $eventPayload = Get-Content -LiteralPath $eventPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($eventPayload.PSObject.Properties['pull_request'] -and
                $eventPayload.pull_request -and
                $eventPayload.pull_request.PSObject.Properties['head'] -and
                $eventPayload.pull_request.head -and
                $eventPayload.pull_request.head.PSObject.Properties['repo'] -and
                $eventPayload.pull_request.head.repo) {
                $HeadRepository = [string]$eventPayload.pull_request.head.repo.full_name
            }
        } catch {
            # Невалідний payload не маскуємо: HeadRepository лишиться
            # порожнім, і перевірка джерела нижче зафейлиться (fail-closed).
            Write-Host "Не вдалося розпарсити GITHUB_EVENT_PATH: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

Write-Host "Base: $BaseRef"
Write-Host "Head: $HeadRef"
Write-Host "Base repository: $BaseRepository"
Write-Host "Head repository: $HeadRepository"
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

# Перевірка джерела PR (RELEASE_POLICY §2.2/§12 + ROADMAP P0.2): дозволені
# лише developer (stable promotion) і hotfix/* (§12), і ЛИШЕ з того самого
# репозиторію, що й base. Невизначений head-репозиторій — FAIL, а не skip:
# гейт захищає промоційне вікно master і мусить падати закрито, коли не
# може довести легітимність джерела. Повертає перелік порушень (порожній = ОК).
function Test-BRAVOMasterMergeSource {
    param(
        [AllowNull()][AllowEmptyString()][string]$HeadRef,
        [AllowNull()][AllowEmptyString()][string]$HeadRepository,
        [AllowNull()][AllowEmptyString()][string]$BaseRepository
    )

    $sourceFailures = New-Object System.Collections.ArrayList

    $allowedHeadPattern = '^(developer|hotfix/.+)$'
    if ([string]::IsNullOrWhiteSpace($HeadRef) -or $HeadRef -notmatch $allowedHeadPattern) {
        [void]$sourceFailures.Add(
            "RELEASE_POLICY.md §2.2/§12: у master приймається код лише з 'developer' (stable promotion) або 'hotfix/*' (§12) — джерельна гілка '$HeadRef' не відповідає жодному з дозволених шляхів. Нову функціональність спершу розробіть і протестуйте в developer."
        )
    }

    if ([string]::IsNullOrWhiteSpace($HeadRepository) -or [string]::IsNullOrWhiteSpace($BaseRepository)) {
        [void]$sourceFailures.Add(
            "RELEASE_POLICY.md §2.2: не вдалося встановити repository identity джерела PR (head: '$HeadRepository'; base: '$BaseRepository') — гейт промоції в master падає закрито, коли легітимність джерела недовідна."
        )
    } elseif (-not [string]::Equals($HeadRepository, $BaseRepository, [StringComparison]::OrdinalIgnoreCase)) {
        [void]$sourceFailures.Add(
            "RELEASE_POLICY.md §2.2: PR у master походить з іншого репозиторію ('$HeadRepository', base: '$BaseRepository') — ім'я гілки fork'а не є довіреним джерелом промоції; production promotion дозволена лише з гілок цього репозиторію."
        )
    }

    return @($sourceFailures.ToArray())
}

foreach ($sourceFailure in @(Test-BRAVOMasterMergeSource `
        -HeadRef $HeadRef `
        -HeadRepository $HeadRepository `
        -BaseRepository $BaseRepository)) {
    Add-BRAVOMasterMergePolicyFailure $sourceFailure
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
