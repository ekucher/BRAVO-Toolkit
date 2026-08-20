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
    [string]$ExpectedTag
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

$repositoryRoot = Split-Path -Parent $PSScriptRoot

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
