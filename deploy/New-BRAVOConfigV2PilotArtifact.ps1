[CmdletBinding()]
param(
    [string]$Ref = 'HEAD',
    [string]$OutputDir,
    [string]$RepositoryRoot
)

# New-BRAVOConfigV2PilotArtifact.ps1 — canonical builder контрольованого
# pilot-артефакту Configuration v2 (#154, крок 2).
#
# Джерело вмісту — ВИКЛЮЧНО `git show <ref>:<path>` для явно переліченого,
# мінімального набору файлів (не весь репозиторій і не весь deploy\):
# детермінований build з того самого commit незалежно від стану робочого
# дерева (та сама причина, що й у ci\New-BRAVOReleaseArtifact.ps1).
#
# Артефакт НЕ бандлить Configuration v2 модулі/дельта-інструменти — вони
# викликаються з $InstallRoot самого pilot-сервера (canonical, без
# дублювання алгоритму). Детальне обґрунтування — коментар на початку
# BRAVOConfigV2Pilot.Runtime.ps1.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Split-Path -Parent $PSScriptRoot
} else {
    (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
}

function Get-BRAVOPilotArtifactVersionFromRef {
    param([string]$RepositoryRoot, [string]$GitRef)
    $raw = & git -C $RepositoryRoot show ("{0}:VERSION.json" -f $GitRef)
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        throw "Не вдалося прочитати VERSION.json з ref '$GitRef' (git show завершився з кодом $LASTEXITCODE)."
    }
    $text = ($raw -join "`n").TrimStart([char]0xFEFF)
    return $text | ConvertFrom-Json
}

$version = Get-BRAVOPilotArtifactVersionFromRef -RepositoryRoot $repositoryRoot -GitRef $Ref
$packageVersion = [string]$version.packageVersion
$configSchemaVersion = [string]$version.configSchemaVersion
$releaseChannel = [string]$version.releaseChannel

$archiveCommit = (& git -C $repositoryRoot rev-parse ("{0}^{{commit}}" -f $Ref)).Trim()
if ($LASTEXITCODE -ne 0 -or $archiveCommit -notmatch '^[0-9a-f]{40}$') {
    throw "Не вдалося розв'язати ref '$Ref' у commit."
}
$shortSha = $archiveCommit.Substring(0, 7)

# --- 1. Мінімальний, явно перелічений набір файлів ------------------------
#
# Мапа: шлях у репозиторії (git ref) -> шлях у артефакті. Навмисно НЕ
# 1:1 копія repository-структури — deploy\*.ps1 виносяться у корінь
# артефакту (це сам pilot-продукт), docs\ лишається docs\.
$fileMap = [ordered]@{
    'deploy/Start-BRAVOConfigV2Pilot.ps1'          = 'Start-BRAVOConfigV2Pilot.ps1'
    'deploy/BRAVOConfigV2Pilot.Runtime.ps1'         = 'BRAVOConfigV2Pilot.Runtime.ps1'
    'deploy/Test-BRAVOConfigV2PilotArtifact.ps1'    = 'Test-BRAVOConfigV2PilotArtifact.ps1'
    'docs/BRAVO_CONFIG_V2_PILOT_RUNBOOK.md'         = 'docs\BRAVO_CONFIG_V2_PILOT_RUNBOOK.md'
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repositoryRoot 'artifacts\config-v2-pilot'
}
if (Test-Path -LiteralPath $OutputDir) {
    Remove-Item -LiteralPath $OutputDir -Recurse -Force
}
[void](New-Item -ItemType Directory -Path $OutputDir -Force)

$artifactId = "BRAVO-ConfigV2-Pilot-$packageVersion-$shortSha"
$stagingDir = Join-Path $OutputDir $artifactId
[void](New-Item -ItemType Directory -Path $stagingDir -Force)

foreach ($sourcePath in $fileMap.Keys) {
    $targetRelative = $fileMap[$sourcePath]
    $targetPath = Join-Path $stagingDir $targetRelative
    $targetParent = Split-Path -Parent $targetPath
    if (-not (Test-Path -LiteralPath $targetParent)) {
        [void](New-Item -ItemType Directory -Path $targetParent -Force)
    }

    # git show повертає байти файлу таким, яким він закомічений
    # (нормалізація CRLF/BOM уже застосована git-атрибутами при checkout;
    # тут беремо саме blob, тому пишемо байти напряму, а не через
    # Out-File/Set-Content, щоб не внести повторну нормалізацію).
    $tempOut = [System.IO.Path]::GetTempFileName()
    try {
        & git -C $repositoryRoot show ("{0}:{1}" -f $Ref, $sourcePath) --  1> $tempOut
        if ($LASTEXITCODE -ne 0) {
            throw "Не вдалося прочитати '$sourcePath' з ref '$Ref' (git show завершився з кодом $LASTEXITCODE)."
        }
        Copy-Item -LiteralPath $tempOut -Destination $targetPath -Force
    } finally {
        Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
    }
}

# --- 2. README.txt (генерується, не копія з репозиторію) ------------------

$readmeLines = @(
    "BRAVO-Toolkit Configuration v2 — Controlled Real Pilot Artifact"
    "=================================================================="
    ""
    "artifactId:      $artifactId"
    "packageVersion:  $packageVersion"
    "sourceCommit:    $archiveCommit"
    "configSchemaVersion: $configSchemaVersion"
    ""
    "1. ПЕРЕД БУДЬ-ЯКОЮ ОПЕРАЦІЄЮ виконайте:"
    "   .\Test-BRAVOConfigV2PilotArtifact.ps1"
    "   Будь-яка розбіжність hash/manifest -> НЕ використовуйте артефакт."
    ""
    "2. Повний покроковий runbook: docs\BRAVO_CONFIG_V2_PILOT_RUNBOOK.md"
    ""
    "3. Мінімальна послідовність команд:"
    "   .\Start-BRAVOConfigV2Pilot.ps1 -Preflight -InstallRoot 'C:\Program Files\BRAVO-Toolkit'"
    "   .\Start-BRAVOConfigV2Pilot.ps1 -Prepare   -InstallRoot 'C:\Program Files\BRAVO-Toolkit'"
    "   (перегляньте delta.preview.txt у виведеному EvidenceDir)"
    "   .\Start-BRAVOConfigV2Pilot.ps1 -Approve  -EvidenceDir <dir> -ApprovedCandidateHash <hash>"
    "   .\Start-BRAVOConfigV2Pilot.ps1 -Activate -InstallRoot 'C:\Program Files\BRAVO-Toolkit' -EvidenceDir <dir>"
    "   .\Start-BRAVOConfigV2Pilot.ps1 -Validate -InstallRoot 'C:\Program Files\BRAVO-Toolkit' -EvidenceDir <dir>"
    "   .\Start-BRAVOConfigV2Pilot.ps1 -Accept   -EvidenceDir <dir>"
    "   (за потреби) .\Start-BRAVOConfigV2Pilot.ps1 -Rollback -InstallRoot ... -EvidenceDir <dir>"
    ""
    "4. Цей артефакт НЕ видаляє BRAVO.config і НЕ мігрує весь парк —"
    "   лише один сервер, явно вказаний через -InstallRoot."
    ""
    "5. Windows PowerShell 5.1. Потрібні права адміністратора на сервері."
)
[System.IO.File]::WriteAllText((Join-Path $stagingDir 'README.txt'), ([string]::Join("`r`n", $readmeLines)), (New-Object System.Text.UTF8Encoding($false)))

# --- 3. Маніфест + SHA-256 --------------------------------------------------

$manifestDir = Join-Path $stagingDir 'manifest'
[void](New-Item -ItemType Directory -Path $manifestDir -Force)

$pilotManifest = [ordered]@{
    artifactType         = 'BRAVO.ConfigurationV2.Pilot'
    artifactSchemaVersion = 1
    createdAtUtc         = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    packageVersion       = $packageVersion
    releaseChannel       = $releaseChannel
    configSchemaVersion  = [int]$configSchemaVersion
    sourceBranch         = 'developer'
    sourceCommit         = $archiveCommit
    buildId              = $shortSha
    artifactId           = $artifactId
    minimumPowerShellVersion = '5.1'
    purpose              = 'Configuration v2 controlled real-server pilot'
}
$pilotManifestPath = Join-Path $manifestDir 'PILOT_MANIFEST.json'
[System.IO.File]::WriteAllText($pilotManifestPath, ($pilotManifest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

$hashEntries = [ordered]@{}
$stagingPrefix = (Resolve-Path -LiteralPath $stagingDir).Path
$stagedFiles = Get-ChildItem -LiteralPath $stagingDir -Recurse -File |
    Where-Object { $_.FullName -notlike (Join-Path $stagingDir 'manifest\*') } |
    Sort-Object -Property { $_.FullName.Substring($stagingPrefix.Length + 1).Replace('\', '/') }
foreach ($file in $stagedFiles) {
    $relativePath = $file.FullName.Substring($stagingPrefix.Length + 1).Replace('\', '/')
    $hashEntries[$relativePath] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}
$hashesPath = Join-Path $manifestDir 'SHA256SUMS.json'
[System.IO.File]::WriteAllText($hashesPath, ($hashEntries | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))

# --- 4. Самоперевірка перед видачею ----------------------------------------

$verifierPath = Join-Path $stagingDir 'Test-BRAVOConfigV2PilotArtifact.ps1'
& $verifierPath -ArtifactRoot $stagingDir
if ($LASTEXITCODE -ne 0) {
    throw "Щойно зібраний артефакт не пройшов власну верифікацію (код $LASTEXITCODE) — build відхилено."
}

# --- 5. ZIP -----------------------------------------------------------------

$zipPath = Join-Path $OutputDir "$artifactId.zip"
Compress-Archive -Path (Join-Path $stagingDir '*') -DestinationPath $zipPath -Force
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$zipPath.sha256", ("{0} *{1}`n" -f $zipHash, (Split-Path -Leaf $zipPath)), (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Pilot-артефакт зібрано і перевірено:"
Write-Host ("  artifactId:   {0}" -f $artifactId)
Write-Host ("  sourceCommit: {0}" -f $archiveCommit)
Write-Host ("  Staging:      {0}" -f $stagingDir)
Write-Host ("  Zip:          {0}" -f $zipPath)
Write-Host ("  Zip SHA-256:  {0}" -f $zipHash)
Write-Host ("  Файлів у SHA256SUMS.json: {0}" -f $hashEntries.Count)
exit 0
