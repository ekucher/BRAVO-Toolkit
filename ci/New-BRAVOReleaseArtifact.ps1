[CmdletBinding()]
param(
    # Git-ref, з якого збирається артефакт (тег релізу, гілка або commit).
    # Розгортати належить ТЕГ (= коміт-stamp), див. Update-BRAVOVersionStamp.ps1.
    [string]$Ref = 'HEAD',

    # Каталог результатів. Типово artifacts\release у корені репозиторію
    # (каталог ігнорується git, див. .gitignore).
    [string]$OutputDir,

    # Очікуване ім'я тега (наприклад v5.0.2). Якщо задано, збірка падає,
    # коли тег не дорівнює "v" + packageVersion з VERSION.json на $Ref —
    # це захист від публікації артефакту з невідповідною версією.
    [string]$ExpectedTag,

    # Корінь репозиторію. Типово — батьківський каталог ci\, тобто цей же
    # репозиторій. Параметр існує рівно з тієї ж причини, що й -Root у
    # ci\Test-BRAVOReleasePolicy.ps1: без нього перевірки провенансу
    # неможливо прогнати на ізольованій фікстурі, а тестувати їх
    # переписуванням тієї самої логіки в тесті — безглуздо.
    [string]$RepositoryRoot
)

# Збирання release-артефакту (P1.2, ROADMAP.md):
#
#     BRAVO-Toolkit-X.Y.Z.zip
#     BRAVO-Toolkit-X.Y.Z.zip.sha256
#     release-manifest.json
#
# Джерело вмісту — ВИКЛЮЧНО git archive із заданого ref: у zip потрапляє
# лише version-controlled стан (без untracked-файлів, LOGS, локальних
# конфігурацій), а .gitattributes гарантує ті самі CRLF, що й у checkout,
# тому SHA-256 файлів збігаються з RUNTIME_MANIFEST.json / TOOLS_MANIFEST.json.
#
# Скрипт сам перевіряє розпакований комплект (обидва integrity-манифести
# та BRAVO_RUNTIME_GUARD.ps1) і залишає staging-каталог для подальшого
# повного self-test (його запускає release-artifact workflow окремим кроком,
# щоб падіння self-test було видно як окремий крок CI).
#
# Повний self-test НЕ запускається тут навмисно: локальний виклик цього
# скрипта має бути швидким способом зібрати той самий артефакт вручну.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Split-Path -Parent $PSScriptRoot
} else {
    (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
}

function Get-BRAVOArtifactVersionFromRef {
    param([string]$RepositoryRoot, [string]$GitRef)

    # Без 2>$null: під $ErrorActionPreference='Stop' редірект stderr нативної
    # команди у PS 5.1 загортає її stderr у terminating NativeCommandError і
    # маскує нашу власну діагностику нижче.
    $raw = & git -C $RepositoryRoot show ("{0}:VERSION.json" -f $GitRef)
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        throw "Не вдалося прочитати VERSION.json з ref '$GitRef' (git show завершився з кодом $LASTEXITCODE)."
    }
    $text = ($raw -join "`n").TrimStart([char]0xFEFF)
    return $text | ConvertFrom-Json
}

# --- 1. Ідентичність версії з ref ---------------------------------------

$version = Get-BRAVOArtifactVersionFromRef -RepositoryRoot $repositoryRoot -GitRef $Ref
$packageVersion = [string]$version.packageVersion
$sourceCommit   = [string]$version.sourceCommit
$buildId        = [string]$version.buildId

if ([string]::IsNullOrWhiteSpace($packageVersion)) {
    throw "VERSION.json на ref '$Ref' не містить packageVersion."
}
if ($sourceCommit -notmatch '^[0-9a-f]{40}$') {
    throw "VERSION.json.sourceCommit ('$sourceCommit') не є повним 40-символьним git-hash — артефакт без провенансу не збирається."
}
if ($buildId -ne $sourceCommit.Substring(0, 7)) {
    throw "VERSION.json: buildId ('$buildId') не збігається з short(sourceCommit) ('$($sourceCommit.Substring(0,7))')."
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedTag) -and $ExpectedTag -ne ('v' + $packageVersion)) {
    throw "Тег '$ExpectedTag' не відповідає packageVersion '$packageVersion' (очікується 'v$packageVersion')."
}

$archiveCommit = (& git -C $repositoryRoot rev-parse ("{0}^{{commit}}" -f $Ref)).Trim()
if ($LASTEXITCODE -ne 0 -or $archiveCommit -notmatch '^[0-9a-f]{40}$') {
    throw "Не вдалося розв'язати ref '$Ref' у commit."
}

# Провенанс має описувати САМЕ те дерево, що пакується (#199).
#
# Форма sourceCommit і префікс buildId вище нічого не кажуть про ВМІСТ:
# перевірку проходив і провенанс, залишений від попереднього штампу тієї
# самої версії. Перештампування однієї версії — штатна практика
# (5.1.0-dev.1 штампували 25 разів), тому "та сама packageVersion" не є
# доказом актуальності.
#
# Справжній інваріант встановлено з історії репозиторію: процедура
# ci\Update-BRAVOVersionStamp.ps1 дає коміт-штамп, який відносно свого
# sourceCommit змінює РІВНО два файли метаданих. Перевірено на всіх
# коміт-штампах в історії — виняткiв немає.
#
# Тут це доречно, а в per-PR гейті ні: developer рухається, і між
# штампами різниця проти sourceCommit законно стає сотнями файлів
# (RELEASE_POLICY.md 5.3).
# Без 2>$null навмисно — та сама причина, що й у
# Get-BRAVOArtifactVersionFromRef вище: під $ErrorActionPreference='Stop'
# редірект stderr нативної команди у PS 5.1 загортає її в terminating
# NativeCommandError і маскує нашу власну діагностику нижче.
$sourceObjectType = (& git -C $repositoryRoot cat-file -t $sourceCommit | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceObjectType -ne 'commit') {
    $seen = if ([string]::IsNullOrWhiteSpace($sourceObjectType)) { "об'єкт не знайдено" } else { "тип: $sourceObjectType" }
    throw ("PROVENANCE_OBJECT: VERSION.json.sourceCommit ('$sourceCommit') не вказує на досяжний коміт ($seen). " +
        "Причини: неповна історія (для CI потрібен fetch-depth: 0), неіснуючий hash або ID не-комітного об'єкта.")
}

$provenanceMetadataFiles = @('VERSION.json', 'RUNTIME_MANIFEST.json')
$provenanceDiff = @(& git -C $repositoryRoot diff --name-only $sourceCommit $archiveCommit)
if ($LASTEXITCODE -ne 0) {
    throw "Не вдалося порівняти sourceCommit '$sourceCommit' з комітом архіву '$archiveCommit' (git diff завершився з кодом $LASTEXITCODE)."
}
# Обидва дозволені файли лежать у корені, тому роздільників у шляху не
# буває; -notcontains у PowerShell і так порівнює регістронезалежно.
$unexpectedProvenanceDiff = @(
    $provenanceDiff |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Where-Object { $provenanceMetadataFiles -notcontains $_.Trim() }
)
if ($unexpectedProvenanceDiff.Count -gt 0) {
    throw ("PROVENANCE_STALE: провенанс стале — між sourceCommit '$sourceCommit' і комітом архіву '$archiveCommit' " +
        "відрізняються не лише метадані, а й " + $unexpectedProvenanceDiff.Count + " файл(ів): " +
        ([string]::Join(', ', ($unexpectedProvenanceDiff | Select-Object -First 10))) +
        ". Проставте штамп заново (ci\Update-BRAVOVersionStamp.ps1 -Apply на чистій копії) і перегенеруйте RUNTIME_MANIFEST.json.")
}

# --- 2. Збирання zip через git archive ----------------------------------

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repositoryRoot 'artifacts\release'
}
if (Test-Path -LiteralPath $OutputDir) {
    Remove-Item -LiteralPath $OutputDir -Recurse -Force
}
[void](New-Item -ItemType Directory -Path $OutputDir -Force)

$zipName = "BRAVO-Toolkit-$packageVersion.zip"
$zipPath = Join-Path $OutputDir $zipName

& git -C $repositoryRoot archive --format=zip -9 -o $zipPath $Ref
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $zipPath)) {
    throw "git archive завершився з кодом $LASTEXITCODE — артефакт не створено."
}

# --- 3. Розпакування та перевірка цілісності комплекту ------------------

$stagingDir = Join-Path $OutputDir 'staging'
Expand-Archive -LiteralPath $zipPath -DestinationPath $stagingDir -Force

$stagedVersion = Get-Content -LiteralPath (Join-Path $stagingDir 'VERSION.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$stagedVersion.packageVersion -ne $packageVersion) {
    throw "packageVersion у розпакованому комплекті ('$($stagedVersion.packageVersion)') не збігається з '$packageVersion'."
}

Push-Location $stagingDir
try {
    & .\ci\Update-BRAVOToolsManifest.ps1
    if ($LASTEXITCODE -ne 0) { throw "TOOLS_MANIFEST.json не відповідає комплекту в артефакті (код $LASTEXITCODE)." }

    & .\ci\Update-BRAVORuntimeManifest.ps1
    if ($LASTEXITCODE -ne 0) { throw "RUNTIME_MANIFEST.json не відповідає комплекту в артефакті (код $LASTEXITCODE)." }

    & .\BRAVO_RUNTIME_GUARD.ps1
    if ($LASTEXITCODE -ne 0) { throw "BRAVO_RUNTIME_GUARD.ps1 відхилив комплект в артефакті (код $LASTEXITCODE)." }
} finally {
    Pop-Location
}

# --- 3a. Гейт issue #216 (Wave B): жоден production/operator entrypoint у --
#     staged-комплекті не сміє автоматично виконувати довільний            --
#     BRAVO.config, підкладений поруч --------------------------------------
#
# ПОВНЕ прибирання BRAVO.config з комплекту (issue #154, крок B4-2)
# ВИКОНАНО в цій хвилі: кореневий файл більше не входить у пакет і не
# відстежується git (заморожений тестовий актив —
# selftest\fixtures\BravoConfigLegacyFrozen.config; deploy\
# Install-BRAVOServer.ps1 більше не вимагає файл; ci\
# Test-BRAVOConfigFoundationParity.ps1 і
# BRAVO_SELF_TEST.ConfigLoader.ps1/CommittedBravoConfigMatchesCanonicalDefaults
# читають той самий заморожений актив через
# Get-BRAVOSelfTestLegacyConfigPath).
#
# Перелік нижче розширено з 7 до 14: аудит (issue #216, крок 2) додав
# 7 раніше не охоплених production/operator-скриптів
# (BRAVO_BAZA_RECONCILE.ps1, BRAVO_DRY_RUN.ps1,
# BRAVO_NOTIFICATION_TEST.ps1, BRAVO_RESTORE_TEST.ps1,
# BRAVO_TASKS_DIAGNOSE.ps1, BRAVO_TASKS_INSTALL.ps1,
# BRAVO_TASKS_UNINSTALL.ps1) — усі вони штатні інструменти оператора
# (діагностика/драй-ран/встановлення й прибирання завдань планувальника/
# реконсиляція BAZA/тест сповіщень/тест відновлення), а не migration-
# tooling, тож так само не повинні автоматично виконувати підкладений
# файл. Свідомо залишено ПОЗА цим гейтом (migration/deploy tooling, де
# читання РЕАЛЬНОГО поточного BRAVO.config встановленого сервера — сама
# мета інструмента, а не випадковість): BRAVO_CONFIG_INTEGRATE.ps1,
# deploy\Get-BRAVOConfigSiteDelta.ps1,
# deploy\Compare-BRAVOConfigEffectiveSnapshot.ps1,
# deploy\Start-BRAVOConfigV2Pilot.ps1,
# deploy\New-BRAVOConfigV2PilotArtifact.ps1,
# deploy\BRAVOConfigV2Pilot.Runtime.ps1 і deploy\Update-BRAVOServer.ps1
# (його preflight-пробник явно читає ВЖЕ ВСТАНОВЛЕНИЙ на сервері
# BRAVO.config, щоб порівняти пороги перед оновленням, — це не
# "випадково підкладений файл", а фактичний стан продакшн-сервера, який
# інструмент зобов'язаний побачити).
#
# Гейт нижче: детерміністична текстова перевірка, що кожен
# production/operator entrypoint staged-комплекту передає
# -DisallowLegacyPrimaryAutoDetect у виклик Import-BravoConfiguration
# (BRAVO_CONFIG_LOADER.ps1) — так само, як RUNTIME_MANIFEST/TOOLS_MANIFEST
# гейти вище, provalidовано на РЕАЛЬНОМУ staged-вмісті, не на джерелі.

$productionEntryPointGuardTargets = @(
    'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1',
    'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1',
    'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1',
    'modules\BRAVO.DataRestore\BRAVO.DataRestore.Runtime.ps1',
    'BRAVO_SETUP.ps1',
    'BRAVO_CREDENTIALS_SETUP.ps1',
    'BRAVO_CONFIG_TEST.ps1',
    'BRAVO_BAZA_RECONCILE.ps1',
    'BRAVO_DRY_RUN.ps1',
    'BRAVO_NOTIFICATION_TEST.ps1',
    'BRAVO_RESTORE_TEST.ps1',
    'BRAVO_TASKS_DIAGNOSE.ps1',
    'BRAVO_TASKS_INSTALL.ps1',
    'BRAVO_TASKS_UNINSTALL.ps1'
)

# BRAVO.config більше не входить у staged-комплект (B4-2). Явна перевірка
# відсутності — щоб регресія (файл випадково знову потрапив у git tree)
# провалила release-artifact build детерміністично, а не мовчки.
if (Test-Path -LiteralPath (Join-Path $stagingDir 'BRAVO.config') -PathType Leaf) {
    throw 'Гейт LEGACY_CONFIG_REMOVED (issue #216, B4-2): BRAVO.config неочікувано присутній у staged-комплекті — файл мав бути прибраний з git tracking.'
}
Write-Host 'Гейт LEGACY_CONFIG_REMOVED (issue #216, B4-2): BRAVO.config відсутній у staged-комплекті.'
$legacyConfigAutoExecGuardMissing = New-Object System.Collections.Generic.List[string]
foreach ($relativeGuardTarget in $productionEntryPointGuardTargets) {
    $guardTargetPath = Join-Path $stagingDir $relativeGuardTarget
    if (-not (Test-Path -LiteralPath $guardTargetPath -PathType Leaf)) {
        throw "Гейт LEGACY_CONFIG_AUTOEXEC (issue #216): production entrypoint '$relativeGuardTarget' відсутній у staged-комплекті."
    }
    $guardTargetText = Get-Content -LiteralPath $guardTargetPath -Raw -Encoding UTF8
    if ($guardTargetText -notmatch '(?s)Import-BravoConfiguration.{0,400}?-DisallowLegacyPrimaryAutoDetect') {
        [void]$legacyConfigAutoExecGuardMissing.Add($relativeGuardTarget)
    }
}
if ($legacyConfigAutoExecGuardMissing.Count -gt 0) {
    throw ('LEGACY_CONFIG_AUTOEXEC (issue #216): у staged-комплекті ' + $legacyConfigAutoExecGuardMissing.Count +
        ' production entrypoint(и) викликають Import-BravoConfiguration БЕЗ -DisallowLegacyPrimaryAutoDetect ' +
        '— довільний BRAVO.config, підкладений поруч без наміру оператора, знову виконувався б автоматично: ' +
        ([string]::Join(', ', $legacyConfigAutoExecGuardMissing.ToArray())))
}
Write-Host ("Гейт LEGACY_CONFIG_AUTOEXEC (issue #216): усі {0} production entrypoint(и) staged-комплекту блокують auto-detect BRAVO.config." -f $productionEntryPointGuardTargets.Count)

# --- 4. release-manifest.json + SHA-256 ---------------------------------

$fileEntries = New-Object System.Collections.Generic.List[object]
$stagingPrefix = (Resolve-Path -LiteralPath $stagingDir).Path
$stagedFiles = Get-ChildItem -LiteralPath $stagingDir -Recurse -File |
    Sort-Object -Property { $_.FullName.Substring($stagingPrefix.Length + 1).Replace('\', '/') }
foreach ($file in $stagedFiles) {
    $relativePath = $file.FullName.Substring($stagingPrefix.Length + 1).Replace('\', '/')
    [void]$fileEntries.Add([pscustomobject]@{
        path      = $relativePath
        sizeBytes = [long]$file.Length
        sha256    = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    })
}

$zipItem = Get-Item -LiteralPath $zipPath
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()

$releaseManifest = [pscustomobject]@{
    schemaVersion  = 1
    product        = [string]$version.product
    packageVersion = $packageVersion
    releaseChannel = [string]$version.releaseChannel
    releaseDate    = [string]$version.releaseDate
    sourceCommit   = $sourceCommit
    buildId        = $buildId
    archiveRef     = $Ref
    archiveCommit  = $archiveCommit
    tag            = $(if ([string]::IsNullOrWhiteSpace($ExpectedTag)) { $null } else { $ExpectedTag })
    generatedUtc   = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    artifact       = [pscustomobject]@{
        name      = $zipName
        sizeBytes = [long]$zipItem.Length
        sha256    = $zipHash
    }
    files          = $fileEntries.ToArray()
}

$manifestPath = Join-Path $OutputDir 'release-manifest.json'
$manifestJson = $releaseManifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, (New-Object System.Text.UTF8Encoding($false)))

$shaPath = "$zipPath.sha256"
[System.IO.File]::WriteAllText($shaPath, ("{0} *{1}`n" -f $zipHash, $zipName), (New-Object System.Text.UTF8Encoding($false)))

# --- 5. Підсумок ---------------------------------------------------------

Write-Host "Release-артефакт зібрано і перевірено:"
Write-Host ("  Версія:        {0} ({1})" -f $packageVersion, [string]$version.releaseChannel)
Write-Host ("  Ref/commit:    {0} / {1}" -f $Ref, $archiveCommit)
Write-Host ("  Провенанс:     sourceCommit={0}; buildId={1}" -f $sourceCommit, $buildId)
Write-Host ("  Zip:           {0} ({1:N0} байт)" -f $zipPath, $zipItem.Length)
Write-Host ("  SHA-256:       {0}" -f $zipHash)
Write-Host ("  Manifest:      {0} (файлів: {1})" -f $manifestPath, $fileEntries.Count)
Write-Host ("  Staging:       {0} (для повного self-test)" -f $stagingDir)
exit 0
