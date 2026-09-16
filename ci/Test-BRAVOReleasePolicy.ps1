[CmdletBinding()]
param(
    [string]$Root,
    [string]$Branch
)

# Перевірка RELEASE_POLICY.md: гілка <-> packageVersion <-> releaseChannel.
#
# RELEASE_POLICY.md, розділ 5.4: раніше releaseChannel зберігався
# однаковим на обох гілках, а реальне значення виводилось із .git/HEAD —
# саме тому, що ручна синхронізація двічі підвела при fast-forward. Тепер
# джерелом істини знову є VERSION.json (пакет на сервері може не мати
# .git взагалі), а замість людської дисципліни працює цей скрипт: якщо
# гілка, версія й канал не узгоджені — CI червоніє ще до merge.
#
# Запускається без параметрів і локально, і в GitHub Actions.

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path -LiteralPath (Join-Path $Root 'BRAVO_SELF_TEST.ps1') -PathType Leaf)) {
    Write-Host "Не схоже на корінь репозиторію BRAVO: $Root" -ForegroundColor Red
    exit 1
}

$failures = New-Object System.Collections.ArrayList

function Add-BRAVOReleasePolicyFailure {
    param([Parameter(Mandatory = $true)][string]$Message)
    [void]$failures.Add($Message)
    Write-Host "::error::$Message"
}

function Resolve-BRAVOReleasePolicyBranch {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    # У Pull Request значення має сенс брати з цільової гілки: promotion
    # developer -> master несе вже stable-версію, і перевіряти її треба
    # правилами master, а не гілки, з якої PR відкрито.
    foreach ($variableName in @('GITHUB_BASE_REF', 'GITHUB_REF_NAME')) {
        $value = [Environment]::GetEnvironmentVariable($variableName)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }

    $gitHeadPath = Join-Path $RepositoryRoot '.git\HEAD'
    if (Test-Path -LiteralPath $gitHeadPath -PathType Leaf) {
        $headContent = (Get-Content -LiteralPath $gitHeadPath -Raw -ErrorAction SilentlyContinue)
        if ($headContent -match '^ref:\s*refs/heads/(?<Branch>.+)$') {
            return $Matches.Branch.Trim()
        }
    }

    return $null
}

$versionPath = Join-Path $Root 'VERSION.json'
$version = [IO.File]::ReadAllText($versionPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$packageVersion = [string]$version.packageVersion
$releaseChannel = [string]$version.releaseChannel

$branch = if (-not [string]::IsNullOrWhiteSpace($Branch)) { $Branch.Trim() } else { Resolve-BRAVOReleasePolicyBranch -RepositoryRoot $Root }

# Гілка невідома лише у detached HEAD або в розпакованому архіві без
# .git. Раніше тут був exit 0 — і разом із гілковими перевірками мовчки
# пропускались УСІ інші, зокрема звірка releaseDate з CHANGELOG.md, яку
# §5.3 прямо називає придатною для розпакованого комплекту. Тепер
# пропускаються рівно ті перевірки, які без гілки не мають змісту.
$branchKnown = -not [string]::IsNullOrWhiteSpace($branch)
if (-not $branchKnown) {
    Write-Host "Гілку визначити не вдалося (detached HEAD або копія без .git) — гілкові перевірки пропущено, решта виконується." -ForegroundColor Yellow
}

# Без відомої гілки трактуємо як не-stable: суворіші stable-правила
# спираються саме на гілку, і застосовувати їх наосліп не можна.
$isStableBranch = $branchKnown -and ($branch -in @('master', 'main'))

Write-Host "Гілка:          $(if ($branchKnown) { $branch } else { '(невідома)' })"
Write-Host "packageVersion: $packageVersion"
Write-Host "releaseChannel: $releaseChannel"
Write-Host ""

# Узгоджено з ConvertTo-BRAVOComparableVersion (BRAVO_RUNTIME_GUARD.ps1):
# без leading zero і в core, і в prerelease-лічильнику. Інакше PR CI
# схвалював би версію на кшталт 5.3.0-rc.01, яку Enforce-guard кожного
# entrypoint відкидає як malformed (review PR #135, третя хвиля) — і
# непрацездатний пакет ловився б лише на пізнішому tag-build.
$strictNumberPattern = '(0|[1-9][0-9]*)'
$stablePattern = "^$strictNumberPattern\.$strictNumberPattern\.$strictNumberPattern$"
$prereleasePattern = "^$strictNumberPattern\.$strictNumberPattern\.$strictNumberPattern-(dev|rc)\.$strictNumberPattern$"

if (-not $branchKnown) {
    Write-Host "Відповідність гілка <-> версія <-> канал не перевіряється: гілка невідома." -ForegroundColor Yellow
} elseif ($isStableBranch) {
    if ($packageVersion -notmatch $stablePattern) {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 2.2: на гілці '$branch' дозволені лише stable-версії X.Y.Z, а packageVersion = '$packageVersion'."
    }
    if ($releaseChannel -ne 'stable') {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 5.3: на гілці '$branch' releaseChannel має бути 'stable', а не '$releaseChannel'."
    }
} else {
    if ($packageVersion -notmatch $prereleasePattern) {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 2.1: поза master дозволені лише prerelease-версії X.Y.Z-dev.N або X.Y.Z-rc.N, а packageVersion = '$packageVersion'."
    }
    if ($releaseChannel -notin @('development', 'prerelease')) {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 5.3: поза master releaseChannel має бути 'development' або 'prerelease', а не '$releaseChannel'."
    }
    if ($packageVersion -match '-dev\.\d+$' -and $releaseChannel -ne 'development') {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 5.3: версія '$packageVersion' це dev-реліз, тому releaseChannel має бути 'development', а не '$releaseChannel'."
    }
    if ($packageVersion -match '-rc\.\d+$' -and $releaseChannel -ne 'prerelease') {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 5.3: версія '$packageVersion' це release candidate, тому releaseChannel має бути 'prerelease', а не '$releaseChannel'."
    }
}

# RELEASE_POLICY 3.4: ModuleVersion не приймає prerelease-суфікса
# ([System.Version]), тому маніфести модулів несуть базову частину.
$baseVersion = ($packageVersion -replace '-.*$', '')
$parsedBaseVersion = $null
if ($baseVersion -notmatch $stablePattern) {
    Add-BRAVOReleasePolicyFailure "packageVersion '$packageVersion' не має вигляду X.Y.Z[-suffix] — базову версію визначити неможливо."
} elseif (-not [version]::TryParse($baseVersion, [ref]$parsedBaseVersion)) {
    # Свідоме обмеження release contract BRAVO (RELEASE_POLICY.md):
    # X.Y.Z записується як ModuleVersion у кожному *.psd1, а
    # ModuleVersion на Windows PowerShell 5.1 — це [System.Version],
    # тобто кожен компонент <= Int32.MaxValue (2147483647). Синтаксично
    # коректний, але непредставимий core — invalid package version;
    # ловимо його тут як root cause, а не пізніше як N однакових
    # ModuleVersion-mismatch помилок чи відмову runtime guard.
    Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 3.4: базова версія '$baseVersion' (з packageVersion '$packageVersion') синтаксично X.Y.Z, але не представима типом System.Version (компонент понад 2147483647) — Windows PowerShell 5.1 не зможе використати її як ModuleVersion у *.psd1. Це непідтримувана packageVersion за release contract BRAVO."
} else {
    $manifests = @(Get-ChildItem -LiteralPath (Join-Path $Root 'modules') -Recurse -Filter '*.psd1' -File)
    if ($manifests.Count -eq 0) {
        Add-BRAVOReleasePolicyFailure "У modules\ не знайдено жодного .psd1 — перевірка ModuleVersion не має сенсу."
    }
    foreach ($manifest in $manifests) {
        $manifestVersion = [string](Test-ModuleManifest -Path $manifest.FullName -ErrorAction Stop).Version
        if ($manifestVersion -ne $baseVersion) {
            Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 3.4: $($manifest.Name) має ModuleVersion '$manifestVersion', очікується базова версія '$baseVersion' (з packageVersion '$packageVersion')."
        }
    }
}

# RELEASE_POLICY 14.3: версія має бути описана в CHANGELOG.md і в
# заголовках документації — інакше на сервері неможливо звірити, що саме
# розгорнуто.
#
# .Contains() тут навмисно НЕ використовується: X.Y.Z завжди є підрядком
# X.Y.Z-dev.N і X.Y.Z-rc.N. Саме в момент promotion у master — де ця
# перевірка найважливіша — .Contains('4.5.0') повернув би true навіть на
# забутому старому заголовку "## 4.5.0-dev.1" чи "# BRAVO 4.5.0-rc.2",
# бо обидва містять підрядок "4.5.0". Межу токена перевіряємо з обох
# боків: ані перед, ані після версії не повинно бути цифри, крапки чи
# дефіса — інакше збіг є частиною довшої версії (наприклад "4.5.0" не
# повинен зараховуватись усередині "24.5.0" чи "4.5.0-dev.1").
$versionAsExactToken = '(?<![\d.\-])' + [regex]::Escape($packageVersion) + '(?![\d.\-])'

$changelogText = [IO.File]::ReadAllText((Join-Path $Root 'CHANGELOG.md'), [Text.Encoding]::UTF8)
if ($changelogText -notmatch $versionAsExactToken) {
    Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 14.3: CHANGELOG.md не містить розділу саме для версії '$packageVersion' (входження як частини довшої prerelease-версії не рахується)."
}

# RELEASE_POLICY 5.3: releaseDate — це дата, яку пакет несе на сервер, а
# не коментар. BRAVO_CONFIG_LOADER.ps1 валідує її і віддає як
# $global:ScriptDate, а ci\New-BRAVOReleaseArtifact.ps1 переносить у
# release-manifest.json КОЖНОГО артефакту. Поле не записує жоден скрипт
# ci\ — воно ведеться вручну, і саме тому поїхало: у гілці developer
# воно залишалось 2026-08-26 (дата штампу 5.3.0-rc.1) наскрізь через
# штампи 5.3.0-dev.2, restamp dev.2 і 5.3.0-dev.3, поки stable-штампи
# оновлювали його коректно. Три тижні артефактів заявляли чужу дату, і
# помітити це не могло ніщо.
#
# Джерелом істини для звірки свідомо обрано заголовок CHANGELOG.md, а не
# дату коміту sourceCommit: заголовок не потребує ані .git, ані повного
# (не shallow) клону, тобто перевірка працює й на розпакованому архіві —
# там, де провенанс звірити вже нічим.
$releaseDate = [string]$version.releaseDate
$parsedReleaseDate = [datetime]::MinValue
if (-not [datetime]::TryParseExact(
        $releaseDate,
        'yyyy-MM-dd',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsedReleaseDate)) {
    Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 5.3: releaseDate '$releaseDate' не має вигляду YYYY-MM-DD."
} else {
    # Роздільник у заголовках — em dash, але приймаємо і en dash, і
    # звичайний дефіс: ловити треба розбіжність дати, а не набір тире.
    $escapedVersion = [regex]::Escape($packageVersion)
    $headingWithDate = [regex]::Match(
        $changelogText,
        '(?m)^##[ \t]+' + $escapedVersion + '[ \t]+[-\u2013\u2014][ \t]+(?<Date>\d{4}-\d{2}-\d{2})')
    $headingAny = [regex]::Match(
        $changelogText,
        '(?m)^##[ \t]+' + $escapedVersion + '(?![\d.\-])')

    if ($headingWithDate.Success) {
        $changelogDate = $headingWithDate.Groups['Date'].Value
        if ($changelogDate -ne $releaseDate) {
            Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 5.3: VERSION.json містить releaseDate '$releaseDate', а заголовок CHANGELOG.md для '$packageVersion' датований '$changelogDate' — одне з двох неправильне."
        }
    } elseif ($headingAny.Success) {
        # Документований вигляд заголовка лінії в роботі, напр.
        # "## 5.2.3-dev.1 (fix/..., у розробці)" — дати ще немає, і
        # вигадувати її, щоб задовольнити перевірку, гірше, ніж не
        # звіряти. На master так бути не може: кожен stable-заголовок
        # датований, тому там це відмова.
        if ($isStableBranch) {
            Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 5.3: заголовок CHANGELOG.md для stable-версії '$packageVersion' не датований — звірити releaseDate '$releaseDate' немає з чим."
        } else {
            Write-Host "CHANGELOG.md: заголовок '$packageVersion' без дати (лінія в роботі) — releaseDate '$releaseDate' не звіряється." -ForegroundColor Yellow
        }
    } else {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 14.3: у CHANGELOG.md немає заголовка '## $packageVersion' — звірити releaseDate '$releaseDate' немає з чим."
    }
}

foreach ($documentName in @('README.md', 'BRAVO_SETUP.md')) {
    $documentPath = Join-Path $Root $documentName
    $firstLine = ([IO.File]::ReadAllLines($documentPath, [Text.Encoding]::UTF8))[0]
    if ($firstLine -notmatch $versionAsExactToken) {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 14.3: заголовок $documentName ('$firstLine') не містить версії '$packageVersion' як самостійного значення (лише як частину довшої prerelease-версії не рахується)."
    }
}

# RELEASE_POLICY 5.4: .git більше не джерело каналу, але поки він поруч —
# він безкоштовна перехресна перевірка того самого твердження.
$loaderPath = Join-Path $Root 'BRAVO_CONFIG_LOADER.ps1'
. $loaderPath
$gitChannel = Resolve-BRAVOReleaseChannelFromGit -ConfigRoot $Root
if (-not [string]::IsNullOrWhiteSpace($gitChannel)) {
    $expectedForGitChannel = if ($gitChannel -eq 'stable') { @('stable') } else { @('development', 'prerelease') }
    if ($releaseChannel -notin $expectedForGitChannel) {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 5.4: .git/HEAD вказує на канал '$gitChannel', а VERSION.json містить '$releaseChannel' — одне з двох неправильне."
    }
}

# RELEASE_POLICY 7.2: провенанс має описувати ТОЙ САМИЙ реліз. Процедура
# штампування (ci\Update-BRAVOVersionStamp.ps1) складається з двох комітів:
# спершу коміт коду релізу з новою packageVersion, далі коміт-штамп, де
# sourceCommit вказує на нього. Тому в будь-якому завершеному стані
# VERSION.json у коміті sourceCommit несе ТУ САМУ packageVersion.
#
# Це прямо те, що обіцяє коментар self-test Version/StampConsistency
# («packageVersion нова, а build/sourceCommit від іншого коміту»), але
# сам він перевіряє лише, що buildId є префіксом sourceCommit — а це
# виконується й тоді, коли штамп узагалі не оновлювали.
#
# Емпірична підстава: 5.3.0-dev.3 отримав версію всередині merge-резолюції
# PR #143, кроки 2-3 процедури не виконувались, і три доби developer ніс
# packageVersion 5.3.0-dev.3 з провенансом 5.3.0-dev.2 (86270a1). Прогін по
# всіх станах VERSION.json в історії показав, що на КОЖНОМУ коміті-штампі
# правило виконується — тобто воно вже діє, просто ніким не перевірялось.
#
# Перевірка git-залежна, тому живе тут, а не в BRAVO_SELF_TEST.ps1: той
# набір мусить лишатись git-незалежним (RELEASE_POLICY 14.4). Потрібен
# повний (не shallow) клон — .github\workflows\ci.yml задає fetch-depth: 0
# для цієї задачі, а guard Governance/ReleasePolicyJobFetchesFullHistory
# тримає опцію на місці.
$sourceCommit = [string]$version.sourceCommit
if ([string]::IsNullOrWhiteSpace($sourceCommit)) {
    Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 7.2: VERSION.json не містить sourceCommit — провенанс пакета невідомий."
} else {
    # EAP=Continue лише навколо native-виклику: 2>$null під глобальним
    # Stop перетворив би будь-який stderr-рядок git на terminating
    # NativeCommandError і зірвав би скрипт замість чесної діагностики.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # --show-toplevel, а НЕ --git-dir: пошук репозиторію в git іде вгору
        # по батьківських каталогах, тому розпакований комплект, що лежить
        # десь усередині чужого робочого дерева, помилково вважався б
        # репозиторієм, і його sourceCommit звірявся б із ЧУЖОЮ історією.
        # Нас цікавить лише випадок, коли корінь репозиторію — це і є $Root.
        $repositoryTopLevel = (& git -C $Root rev-parse --show-toplevel 2>$null | Out-String).Trim()
        $hasGit = $false
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($repositoryTopLevel)) {
            # git віддає шлях із прямими слешами; порівнюємо нормалізовані
            # повні шляхи без кінцевого роздільника, регістронезалежно
            # (Windows).
            $normalizedTopLevel = [IO.Path]::GetFullPath($repositoryTopLevel.Replace('/', [IO.Path]::DirectorySeparatorChar)).TrimEnd([IO.Path]::DirectorySeparatorChar)
            $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
            $hasGit = $normalizedTopLevel.Equals($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)
        }
        # Тип об'єкта перевіряємо ОКРЕМО і ПЕРШИМ: git show приймає будь-який
        # tree-ish, тому 40-символьний ID дерева з підхожим VERSION.json у
        # корені пройшов би і перевірку форми, і buildId-префікс, і саме
        # читання файлу — провенанс, який не вказує на жоден коміт.
        $sourceObjectType = if ($hasGit) { (& git -C $Root cat-file -t $sourceCommit 2>$null | Out-String).Trim() } else { '' }
        $sourceIsCommit = ($hasGit -and $LASTEXITCODE -eq 0 -and $sourceObjectType -eq 'commit')
        $provenanceJson = if ($sourceIsCommit) { (& git -C $Root show ("{0}:VERSION.json" -f $sourceCommit) 2>$null) | Out-String } else { '' }
        $provenanceAvailable = ($sourceIsCommit -and $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($provenanceJson))
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if (-not $hasGit) {
        # Єдиний легальний пропуск: $Root не є коренем git-репозиторію
        # (розпакований комплект на сервері — зокрема й тоді, коли він
        # випадково лежить усередині чужого робочого дерева). Там звіряти
        # нема з чим, і звірка з чужою історією була б гіршою за пропуск.
        Write-Host "$Root не є коренем git-репозиторію — провенанс sourceCommit не звіряється (розпакований комплект)." -ForegroundColor Yellow
    } elseif (-not $provenanceAvailable) {
        # Репозиторій є, а коміт недосяжний — це відмова, а не попередження.
        # Інакше вигаданий 40-символьний hash із узгодженим buildId проходив
        # би всі перевірки провенансу, і fetch-depth: 0, доданий саме заради
        # авторитетності цієї звірки, не давав би нічого. Якщо історія
        # неповна — це теж треба бачити, а не пропускати.
        $sourceObjectTypeText = if ([string]::IsNullOrWhiteSpace($sourceObjectType)) { "об'єкт не знайдено" } else { "тип об'єкта: $sourceObjectType" }
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 7.2: sourceCommit '$sourceCommit' не вказує на досяжний коміт ($sourceObjectTypeText) — провенанс недоказовий. Причини: неповна історія (для CI потрібен fetch-depth: 0), неіснуючий hash або ID не-комітного об'єкта."
    } else {
        $provenanceVersion = [string]($provenanceJson | ConvertFrom-Json).packageVersion
        if ($provenanceVersion -ne $packageVersion) {
            Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 7.2: VERSION.json заявляє packageVersion '$packageVersion', але у коміті sourceCommit '$sourceCommit' записано '$provenanceVersion' — провенанс від іншого релізу. Проставте штамп заново (ci\Update-BRAVOVersionStamp.ps1 -Apply) і перегенеруйте RUNTIME_MANIFEST.json."
        }
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "RELEASE_POLICY: порушень — $($failures.Count)" -ForegroundColor Red
    exit 1
}

Write-Host "RELEASE_POLICY: гілка, версія і канал узгоджені." -ForegroundColor Green
exit 0
