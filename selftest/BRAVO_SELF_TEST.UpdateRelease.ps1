# Suite UpdateRelease: отримання й верифікація релізного артефакта BRAVO.Update
# (INS-030…034, INS-036). Мережі немає: онлайн-шлях тестується ін'єкцією
# завантажувача, який копіює локальні fixture-файли. Усі каталоги — у тимчасовому
# каталозі з унікальним GUID, до C:\ProgramData\BRAVO тести не торкаються.

Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking

$releaseTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('BRAVO_UPDATE_RELEASE_SELF_TEST_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $releaseTestRoot -Force)

try {
    & {
        $utf8 = New-Object System.Text.UTF8Encoding($false)

        function Write-RelFile {
            param([string]$Path, [string]$Text)
            $dir = [System.IO.Path]::GetDirectoryName($Path)
            if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            [System.IO.File]::WriteAllText($Path, $Text, $utf8)
        }

        function New-RelFixture {
            # Будує fake-реліз: staged-дерево з обчисленим RUNTIME_MANIFEST.json,
            # zip (записи через '/'), .sha256 і release-manifest.json.
            param(
                [string]$Base,
                [string]$Tag = 'v5.3.0',
                [string]$Channel = 'stable',
                [switch]$ExtraScript,
                [switch]$ManifestListsGhost,
                [switch]$SizeMismatch,
                [switch]$WrongSha,
                [string]$ShaFileName = '',
                [switch]$OmitManifest,
                [switch]$ManifestWrongArtifactSha,
                [switch]$ManifestWrongTag
            )
            $version = $Tag.Substring(1)
            $stage = Join-Path $Base 'stage'
            $out = Join-Path $Base 'out'
            [void](New-Item -ItemType Directory -Path $stage -Force)
            [void](New-Item -ItemType Directory -Path $out -Force)
            $commit = 'd77f3b4d021c3d3d53565a604a2497d1d962dcb4'
            $versionJson = (@{
                    product = 'BRAVO-Toolkit'; packageVersion = $version; configSchemaVersion = 1
                    stateSchemaVersion = 1; updaterVersion = '1.0.0'; releaseDate = '2026-09-13'
                    releaseChannel = $Channel; buildId = $commit.Substring(0, 7); sourceCommit = $commit
                } | ConvertTo-Json)
            Write-RelFile (Join-Path $stage 'VERSION.json') $versionJson
            Write-RelFile (Join-Path $stage 'BRAVO_RUNTIME_GUARD.ps1') '# guard stub'
            Write-RelFile (Join-Path $stage 'BRAVO_SETUP.ps1') '# setup stub'
            Write-RelFile (Join-Path $stage 'BRAVO_CONFIG_LOADER.ps1') '# loader stub'
            Write-RelFile (Join-Path $stage 'Tools\TOOLS_MANIFEST.json') '{}'
            Write-RelFile (Join-Path $stage 'modules\X\X.psm1') '# module stub'

            $integrity = [ordered]@{}
            foreach ($rel in @('BRAVO_RUNTIME_GUARD.ps1', 'BRAVO_SETUP.ps1', 'BRAVO_CONFIG_LOADER.ps1', 'modules\X\X.psm1', 'VERSION.json', 'Tools\TOOLS_MANIFEST.json')) {
                $integrity[$rel] = (Get-FileHash -LiteralPath (Join-Path $stage $rel) -Algorithm SHA256).Hash.ToUpperInvariant()
            }
            Write-RelFile (Join-Path $stage 'RUNTIME_MANIFEST.json') ((@{ schemaVersion = 1; description = 'fixture'; files = $integrity } | ConvertTo-Json -Depth 4))

            $fileEntries = New-Object System.Collections.Generic.List[object]
            foreach ($file in (Get-ChildItem -LiteralPath $stage -Recurse -File)) {
                $rel = $file.FullName.Substring($stage.Length + 1).Replace('\', '/')
                $size = [long]$file.Length
                if ($SizeMismatch -and $rel -eq 'VERSION.json') { $size = $size + 1 }
                [void]$fileEntries.Add([pscustomobject]@{ path = $rel; sizeBytes = $size; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
            }
            if ($ManifestListsGhost) {
                [void]$fileEntries.Add([pscustomobject]@{ path = 'ghost.txt'; sizeBytes = 1; sha256 = ('0' * 64) })
            }

            $zipName = 'BRAVO-Toolkit-{0}.zip' -f $version
            $zipPath = Join-Path $out $zipName
            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($file in (Get-ChildItem -LiteralPath $stage -Recurse -File)) {
                    $rel = $file.FullName.Substring($stage.Length + 1).Replace('\', '/')
                    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $rel)
                }
                if ($ExtraScript) {
                    $extra = Join-Path $Base 'extra.ps1'
                    Write-RelFile $extra '# extra'
                    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $extra, 'extra.ps1')
                }
            } finally { $zip.Dispose() }

            $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $shaPath = $zipPath + '.sha256'
            $shaHash = $(if ($WrongSha) { ('a' * 64) } else { $zipHash })
            $shaName = $(if ($ShaFileName) { $ShaFileName } else { $zipName })
            Write-RelFile $shaPath ("{0} *{1}`n" -f $shaHash, $shaName)

            $manifestPath = Join-Path $out 'release-manifest.json'
            if (-not $OmitManifest) {
                $manifestTag = $(if ($ManifestWrongTag) { 'v9.9.9' } else { $Tag })
                $manifestArtifactSha = $(if ($ManifestWrongArtifactSha) { ('b' * 64) } else { $zipHash })
                $manifest = [pscustomobject]@{
                    schemaVersion = 1; product = 'BRAVO-Toolkit'; packageVersion = $version; releaseChannel = $Channel
                    releaseDate = '2026-09-13'; sourceCommit = $commit; buildId = $commit.Substring(0, 7)
                    archiveRef = $Tag; archiveCommit = $commit; tag = $manifestTag; generatedUtc = '2026-09-13T00:00:00Z'
                    artifact = [pscustomobject]@{ name = $zipName; sizeBytes = (Get-Item -LiteralPath $zipPath).Length; sha256 = $manifestArtifactSha }
                    files = $fileEntries.ToArray()
                }
                Write-RelFile $manifestPath ($manifest | ConvertTo-Json -Depth 5)
            }
            return [pscustomobject]@{ Base = $Base; Stage = $stage; Out = $out; Zip = $zipPath; Sha = $shaPath; Manifest = $manifestPath; Tag = $Tag; Version = $version }
        }

        function Get-RelBlockerIds {
            param($Result)
            return @($Result.Findings | Where-Object { $_.severity -eq 'Blocker' } | ForEach-Object { $_.id })
        }

        function New-RelCaseDir {
            $script:relCase = $script:relCase + 1
            $dir = Join-Path $releaseTestRoot ('case{0}' -f $script:relCase)
            [void](New-Item -ItemType Directory -Path $dir -Force)
            return $dir
        }
        $script:relCase = 0

        # --- Get-BRAVOReleaseCandidate -----------------------------------------
        $candidate = Get-BRAVOReleaseCandidate -Tag 'v5.3.0'
        Test-BRAVOCondition -Condition ($candidate.PackageVersion -eq '5.3.0' -and -not $candidate.IsPrerelease -and $candidate.ArtifactName -eq 'BRAVO-Toolkit-5.3.0.zip') -Name 'UpdateRelease/Candidate-Stable' -Failure 'Кандидат stable-релізу сформовано некоректно.'
        Test-BRAVOCondition -Condition ($candidate.ArtifactUri -eq 'https://github.com/ekucher/BRAVO-Toolkit/releases/download/v5.3.0/BRAVO-Toolkit-5.3.0.zip' -and $candidate.ChecksumUri.EndsWith('.zip.sha256') -and $candidate.ManifestUri.EndsWith('/v5.3.0/release-manifest.json')) -Name 'UpdateRelease/Candidate-Uris' -Failure 'URI ассетів кандидата некоректні.'
        Test-BRAVOCondition -Condition ((Get-BRAVOReleaseCandidate -Tag 'v5.3.0-rc.1').IsPrerelease -and (Get-BRAVOReleaseCandidate -Tag 'v5.3.0-dev.3').IsPrerelease -and -not (Get-BRAVOReleaseCandidate -Tag 'v5.3.0-beta').IsPrerelease) -Name 'UpdateRelease/Candidate-PrereleaseRegex' -Failure 'IsPrerelease має відповідати -(dev|rc). з release workflow.'
        $badTags = @('latest', '5.3.0', 'v1.2', 'v1.2.3;x', 'v1.2.3/../x', '', 'v1.2.3-')
        $rejected = 0
        foreach ($badTag in $badTags) {
            $threw = $false
            try { [void](Get-BRAVOReleaseCandidate -Tag $badTag) } catch { $threw = $true }
            if ($threw) { $rejected++ }
        }
        Test-BRAVOCondition -Condition ($rejected -eq $badTags.Count) -Name 'UpdateRelease/Candidate-RejectsBadTag' -Failure ('Некоректні теги мають відхилятися ({0}/{1}).' -f $rejected, $badTags.Count)
        $httpRejected = $false
        try { [void](Get-BRAVOReleaseCandidate -Tag 'v1.0.0' -RepositoryBaseUri 'http://host-a/x') } catch { $httpRejected = $true }
        Test-BRAVOCondition -Condition $httpRejected -Name 'UpdateRelease/Candidate-RejectsHttp' -Failure 'http:// base URI має відхилятися.'
        Test-BRAVOCondition -Condition ((Get-BRAVOReleaseCandidate -Tag 'v1.0.0' -RepositoryBaseUri 'https://host-a.example/dl/').ArtifactUri -eq 'https://host-a.example/dl/v1.0.0/BRAVO-Toolkit-1.0.0.zip') -Name 'UpdateRelease/Candidate-CustomBase' -Failure 'Користувацька база з кінцевим / має нормалізуватись.'

        # --- Valid stable, offline ------------------------------------------------
        $case = New-RelCaseDir
        $fxStable = New-RelFixture -Base $case -Tag 'v5.3.0' -Channel 'stable'
        $stateDir = Join-Path $case 'state'
        [void](New-Item -ItemType Directory -Path $stateDir -Force)
        $statePath = Join-Path $stateDir 'BRAVO_VERSION_STATE.json'

        $validResult = Test-BRAVOReleaseArtifact -ZipPath $fxStable.Zip -ChecksumPath $fxStable.Sha -ManifestPath $fxStable.Manifest -ExpectedTag 'v5.3.0' -StatePath $statePath
        Test-BRAVOCondition -Condition ($validResult.IsValid -and $validResult.Severity -eq 'Ok' -and $validResult.PackageVersion -eq '5.3.0' -and $validResult.ReleaseChannel -eq 'stable') -Name 'UpdateRelease/Valid-Stable' -Failure ('Валідний stable-реліз має проходити: {0}' -f ((Get-RelBlockerIds $validResult) -join ','))
        Test-BRAVOCondition -Condition ($validResult.ArtifactSha256 -eq (Get-FileHash -LiteralPath $fxStable.Zip -Algorithm SHA256).Hash.ToLowerInvariant() -and $validResult.ManifestSha256 -eq (Get-FileHash -LiteralPath $fxStable.Manifest -Algorithm SHA256).Hash.ToLowerInvariant()) -Name 'UpdateRelease/Valid-Hashes' -Failure 'ArtifactSha256/ManifestSha256 мають бути обчисленими хешами.'
        Test-BRAVOCondition -Condition ($null -ne $validResult.VersionMetadata -and $validResult.VersionMetadata.packageVersion -eq '5.3.0') -Name 'UpdateRelease/Valid-VersionMetadata' -Failure 'VersionMetadata має бути прочитано з zip.'
        Test-BRAVOCondition -Condition (-not (Test-Path -LiteralPath (Join-Path $case 'out\VERSION.json'))) -Name 'UpdateRelease/NoExtraction' -Failure 'Верифікація не повинна розпаковувати архів.'

        # --- Wrong hash / sha file name / missing manifest -----------------------
        $fx = New-RelFixture -Base (New-RelCaseDir) -WrongSha
        $r = Test-BRAVOReleaseArtifact -ZipPath $fx.Zip -ChecksumPath $fx.Sha -ManifestPath $fx.Manifest -ExpectedTag 'v5.3.0'
        $hashBlocker = @($r.Findings | Where-Object { $_.severity -eq 'Blocker' -and $_.id -eq 'Release.ArtifactHash' })
        Test-BRAVOCondition -Condition (-not $r.IsValid -and $r.Severity -eq 'Error' -and $hashBlocker.Count -eq 1 -and $hashBlocker[0].exitCodeHint -eq 42) -Name 'UpdateRelease/WrongHash' -Failure 'Хибний SHA-256 має давати Blocker з exitCodeHint 42.'

        $fx = New-RelFixture -Base (New-RelCaseDir) -ShaFileName 'BRAVO-Toolkit-9.9.9.zip'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fx.Zip -ChecksumPath $fx.Sha -ManifestPath $fx.Manifest -ExpectedTag 'v5.3.0'
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.ChecksumName') -Name 'UpdateRelease/WrongShaFileName' -Failure 'Ім''я у .sha256 має дорівнювати імені архіва.'

        $fx = New-RelFixture -Base (New-RelCaseDir) -OmitManifest
        $r = Test-BRAVOReleaseArtifact -ZipPath $fx.Zip -ChecksumPath $fx.Sha -ManifestPath $fx.Manifest -ExpectedTag 'v5.3.0'
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.ManifestMissing') -Name 'UpdateRelease/MissingManifest' -Failure 'Відсутній release-manifest.json — Blocker (суворіше за legacy).'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fx.Zip -ChecksumPath $fx.Sha -ManifestPath '' -ExpectedTag 'v5.3.0'
        Test-BRAVOCondition -Condition (-not $r.IsValid) -Name 'UpdateRelease/EmptyManifestPath' -Failure 'Порожній ManifestPath має блокувати.'

        $fx = New-RelFixture -Base (New-RelCaseDir)
        Remove-Item -LiteralPath $fx.Sha -Force
        $r = Test-BRAVOReleaseArtifact -ZipPath $fx.Zip -ChecksumPath $fx.Sha -ManifestPath $fx.Manifest -ExpectedTag 'v5.3.0'
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.ChecksumMissing') -Name 'UpdateRelease/MissingChecksumFile' -Failure 'Відсутній .sha256 — Blocker.'

        $fx = New-RelFixture -Base (New-RelCaseDir)
        Write-RelFile $fx.Sha 'not a checksum'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fx.Zip -ChecksumPath $fx.Sha -ManifestPath $fx.Manifest -ExpectedTag 'v5.3.0'
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.ChecksumFormat') -Name 'UpdateRelease/CorruptChecksumFile' -Failure 'Некоректний формат .sha256 — Blocker.'

        $fx = New-RelFixture -Base (New-RelCaseDir)
        Write-RelFile $fx.Manifest '{ broken json'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fx.Zip -ChecksumPath $fx.Sha -ManifestPath $fx.Manifest -ExpectedTag 'v5.3.0'
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.ManifestParse') -Name 'UpdateRelease/CorruptManifest' -Failure 'Пошкоджений маніфест — Blocker.'

        $fx = New-RelFixture -Base (New-RelCaseDir) -ManifestWrongArtifactSha
        $r = Test-BRAVOReleaseArtifact -ZipPath $fx.Zip -ChecksumPath $fx.Sha -ManifestPath $fx.Manifest -ExpectedTag 'v5.3.0'
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.ManifestArtifactHash') -Name 'UpdateRelease/ManifestArtifactShaMismatch' -Failure 'artifact.sha256 маніфесту має збігатись з архівом.'

        # --- File list cross-check -------------------------------------------------
        $fx = New-RelFixture -Base (New-RelCaseDir) -ManifestListsGhost
        $r = Test-BRAVOReleaseArtifact -ZipPath $fx.Zip -ChecksumPath $fx.Sha -ManifestPath $fx.Manifest -ExpectedTag 'v5.3.0'
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.FileListMissing') -Name 'UpdateRelease/FileList-MissingInZip' -Failure 'Файл із маніфесту, якого немає в zip, — Blocker.'
        $fx = New-RelFixture -Base (New-RelCaseDir) -ExtraScript
        $r = Test-BRAVOReleaseArtifact -ZipPath $fx.Zip -ChecksumPath $fx.Sha -ManifestPath $fx.Manifest -ExpectedTag 'v5.3.0'
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.FileListExtra') -Name 'UpdateRelease/FileList-ExtraScript' -Failure 'Скрипт у zip поза маніфестом — Blocker.'
        $fx = New-RelFixture -Base (New-RelCaseDir) -SizeMismatch
        $r = Test-BRAVOReleaseArtifact -ZipPath $fx.Zip -ChecksumPath $fx.Sha -ManifestPath $fx.Manifest -ExpectedTag 'v5.3.0'
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.FileListSize') -Name 'UpdateRelease/FileList-SizeMismatch' -Failure 'Розбіжність розміру — Blocker.'

        # --- Prerelease / tag ------------------------------------------------------
        $fxRc = New-RelFixture -Base (New-RelCaseDir) -Tag 'v5.3.0-rc.1' -Channel 'development'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fxRc.Zip -ChecksumPath $fxRc.Sha -ManifestPath $fxRc.Manifest -ExpectedTag 'v5.3.0-rc.1'
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.Channel' -and (Get-RelBlockerIds $r) -contains 'Release.PrereleaseTag') -Name 'UpdateRelease/Prerelease-NoAuthorization' -Failure 'Prerelease без дозволу — Blocker.'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fxRc.Zip -ChecksumPath $fxRc.Sha -ManifestPath $fxRc.Manifest -ExpectedTag 'v5.3.0-rc.1' -AllowPrerelease
        Test-BRAVOCondition -Condition ($r.IsValid -and $r.Severity -eq 'Warning' -and @(Get-RelBlockerIds $r).Count -eq 0) -Name 'UpdateRelease/Prerelease-Authorized' -Failure 'Prerelease з дозволом — Warning без Blocker.'

        $r = Test-BRAVOReleaseArtifact -ZipPath $fxStable.Zip -ChecksumPath $fxStable.Sha -ManifestPath $fxStable.Manifest -ExpectedTag 'v5.4.0'
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.VersionTag') -Name 'UpdateRelease/WrongTag' -Failure 'Тег, що не відповідає VERSION.json, — Blocker.'
        $fx = New-RelFixture -Base (New-RelCaseDir) -ManifestWrongTag
        $r = Test-BRAVOReleaseArtifact -ZipPath $fx.Zip -ChecksumPath $fx.Sha -ManifestPath $fx.Manifest -ExpectedTag 'v5.3.0'
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.Provenance') -Name 'UpdateRelease/ManifestTagMismatch' -Failure 'tag у маніфесті має збігатись із запитаним.'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fxStable.Zip -ChecksumPath $fxStable.Sha -ManifestPath $fxStable.Manifest -ExpectedTag 'latest'
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.Tag') -Name 'UpdateRelease/InvalidExpectedTag' -Failure 'Некоректний ExpectedTag — Blocker.'

        # --- Downgrade vs sandbox state file --------------------------------------
        Write-RelFile $statePath '{"highestVersion":"5.9.0","highestVersionFull":"5.9.0","recordedAt":"2026-01-01T00:00:00Z"}'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fxStable.Zip -ChecksumPath $fxStable.Sha -ManifestPath $fxStable.Manifest -ExpectedTag 'v5.3.0' -StatePath $statePath
        $dg = @($r.Findings | Where-Object { $_.id -eq 'Release.Downgrade' })
        Test-BRAVOCondition -Condition (-not $r.IsValid -and $dg.Count -eq 1 -and $dg[0].exitCodeHint -eq 35) -Name 'UpdateRelease/Downgrade-Blocked35' -Failure 'Відкат версії — Blocker з exitCodeHint 35.'
        Write-RelFile $statePath '{"highestVersion":"5.3.0","highestVersionFull":"5.3.0"}'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fxStable.Zip -ChecksumPath $fxStable.Sha -ManifestPath $fxStable.Manifest -ExpectedTag 'v5.3.0' -StatePath $statePath
        Test-BRAVOCondition -Condition $r.IsValid -Name 'UpdateRelease/Downgrade-EqualAllowed' -Failure 'Та сама версія не є відкатом.'
        Write-RelFile $statePath '{"highestVersion":"5.2.6"}'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fxStable.Zip -ChecksumPath $fxStable.Sha -ManifestPath $fxStable.Manifest -ExpectedTag 'v5.3.0' -StatePath $statePath
        Test-BRAVOCondition -Condition $r.IsValid -Name 'UpdateRelease/Downgrade-NewerAllowedFallbackField' -Failure 'Новіша версія за highestVersion (fallback) проходить.'
        Write-RelFile $statePath '{"highestVersion":"9.0.0","highestVersionFull":"5.2.6"}'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fxStable.Zip -ChecksumPath $fxStable.Sha -ManifestPath $fxStable.Manifest -ExpectedTag 'v5.3.0' -StatePath $statePath
        Test-BRAVOCondition -Condition $r.IsValid -Name 'UpdateRelease/Downgrade-FullPreferred' -Failure 'highestVersionFull має пріоритет над highestVersion.'
        Write-RelFile $statePath '{ not json'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fxStable.Zip -ChecksumPath $fxStable.Sha -ManifestPath $fxStable.Manifest -ExpectedTag 'v5.3.0' -StatePath $statePath
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.DowngradeState') -Name 'UpdateRelease/Downgrade-CorruptStateFailClosed' -Failure 'Пошкоджений стан — fail closed.'
        Write-RelFile $statePath '{"highestVersion":"garbage"}'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fxStable.Zip -ChecksumPath $fxStable.Sha -ManifestPath $fxStable.Manifest -ExpectedTag 'v5.3.0' -StatePath $statePath
        Test-BRAVOCondition -Condition (-not $r.IsValid -and (Get-RelBlockerIds $r) -contains 'Release.DowngradeVersion') -Name 'UpdateRelease/Downgrade-UnparseableRecorded' -Failure 'Нерозпізнана записана версія — Blocker.'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fxStable.Zip -ChecksumPath $fxStable.Sha -ManifestPath $fxStable.Manifest -ExpectedTag 'v5.3.0' -StatePath (Join-Path $stateDir 'absent.json')
        Test-BRAVOCondition -Condition $r.IsValid -Name 'UpdateRelease/Downgrade-NoStateFile' -Failure 'Відсутній файл стану — перевірку пропущено.'

        # --- Online (injected downloader) vs offline: однакові вердикти ------------
        $onlineCase = New-RelCaseDir
        $onlineDest = Join-Path $onlineCase 'Папка з пробілом'
        [void](New-Item -ItemType Directory -Path $onlineDest -Force)
        $script:relFixtureForDownloader = $fxStable
        $downloader = {
            param($Uri, $OutFile)
            $leaf = $Uri.Substring($Uri.LastIndexOf('/') + 1)
            $src = Join-Path $script:relFixtureForDownloader.Out $leaf
            if (-not (Test-Path -LiteralPath $src)) { throw ('fixture not found: ' + $leaf) }
            Copy-Item -LiteralPath $src -Destination $OutFile -Force
        }
        $saved = Save-BRAVOReleaseArtifact -Candidate (Get-BRAVOReleaseCandidate -Tag 'v5.3.0') -DestinationRoot $onlineDest -Downloader $downloader
        Test-BRAVOCondition -Condition ($saved.Success -and $saved.Problems.Count -eq 0 -and (Test-Path -LiteralPath $saved.ZipPath) -and (Test-Path -LiteralPath $saved.ChecksumPath) -and (Test-Path -LiteralPath $saved.ManifestPath)) -Name 'UpdateRelease/Save-Success' -Failure 'Завантаження трьох ассетів має бути успішним.'
        $online = Test-BRAVOReleaseArtifact -ZipPath $saved.ZipPath -ChecksumPath $saved.ChecksumPath -ManifestPath $saved.ManifestPath -ExpectedTag 'v5.3.0'

        $offlineDest = Join-Path $onlineCase 'Офлайн копія'
        [void](New-Item -ItemType Directory -Path $offlineDest -Force)
        $offlineSource = Join-Path $onlineCase 'джерело з пробілом'
        [void](New-Item -ItemType Directory -Path $offlineSource -Force)
        Copy-Item -LiteralPath $fxStable.Zip -Destination $offlineSource
        Copy-Item -LiteralPath $fxStable.Sha -Destination $offlineSource
        Copy-Item -LiteralPath $fxStable.Manifest -Destination $offlineSource
        $offline = Get-BRAVOOfflineReleaseSource -ZipPath (Join-Path $offlineSource (Split-Path -Leaf $fxStable.Zip)) -DestinationRoot $offlineDest
        Test-BRAVOCondition -Condition ($offline.Success -and $offline.ZipPath.StartsWith($offlineDest) -and $offline.ChecksumPath.StartsWith($offlineDest) -and $offline.ManifestPath.StartsWith($offlineDest)) -Name 'UpdateRelease/Offline-CopiesIntoDestination' -Failure 'Офлайн-джерело має копіювати всі три файли в DestinationRoot (дефолти поруч із zip).'
        $offlineResult = Test-BRAVOReleaseArtifact -ZipPath $offline.ZipPath -ChecksumPath $offline.ChecksumPath -ManifestPath $offline.ManifestPath -ExpectedTag 'v5.3.0'
        Test-BRAVOCondition -Condition ($online.IsValid -eq $offlineResult.IsValid -and $online.Severity -eq $offlineResult.Severity -and $online.ArtifactSha256 -eq $offlineResult.ArtifactSha256 -and (($online.Findings | ForEach-Object { $_.id }) -join ',') -eq (($offlineResult.Findings | ForEach-Object { $_.id }) -join ',')) -Name 'UpdateRelease/OnlineOfflineIdentical' -Failure 'Онлайн і офлайн мають давати однаковий вердикт.'

        # TOCTOU: підміна вихідного файлу після копіювання не впливає на копію.
        $copyHashBefore = (Get-FileHash -LiteralPath $offline.ZipPath -Algorithm SHA256).Hash
        Write-RelFile (Join-Path $offlineSource (Split-Path -Leaf $fxStable.Zip)) 'swapped'
        Test-BRAVOCondition -Condition ($copyHashBefore -eq (Get-FileHash -LiteralPath $offline.ZipPath -Algorithm SHA256).Hash) -Name 'UpdateRelease/Offline-CopyIsIndependent' -Failure 'Копія не має залежати від вихідного файлу.'

        # Offline: відсутній маніфест / архів; явні шляхи
        $emptyDest = Join-Path (New-RelCaseDir) 'dest'
        [void](New-Item -ItemType Directory -Path $emptyDest -Force)
        $noManifestSource = Join-Path (New-RelCaseDir) 'src'
        [void](New-Item -ItemType Directory -Path $noManifestSource -Force)
        Copy-Item -LiteralPath $fxStable.Zip -Destination $noManifestSource
        Copy-Item -LiteralPath $fxStable.Sha -Destination $noManifestSource
        $off2 = Get-BRAVOOfflineReleaseSource -ZipPath (Join-Path $noManifestSource (Split-Path -Leaf $fxStable.Zip)) -DestinationRoot $emptyDest
        Test-BRAVOCondition -Condition (-not $off2.Success -and $off2.Problems.Count -ge 1) -Name 'UpdateRelease/Offline-MissingManifestProblem' -Failure 'Офлайн без маніфесту — Problem.'
        $off3 = Get-BRAVOOfflineReleaseSource -ZipPath (Join-Path $noManifestSource 'nope.zip') -DestinationRoot $emptyDest
        Test-BRAVOCondition -Condition (-not $off3.Success -and $off3.Problems.Count -ge 1) -Name 'UpdateRelease/Offline-MissingZipProblem' -Failure 'Офлайн без архіва — Problem.'

        # Save: маніфест відсутній на сервері / downloader кидає / порожній файл / поганий кандидат
        $fxNoManifest = New-RelFixture -Base (New-RelCaseDir) -OmitManifest
        $script:relFixtureForDownloader = $fxNoManifest
        $saveDest = Join-Path (New-RelCaseDir) 'dest'
        [void](New-Item -ItemType Directory -Path $saveDest -Force)
        $saved2 = Save-BRAVOReleaseArtifact -Candidate (Get-BRAVOReleaseCandidate -Tag 'v5.3.0') -DestinationRoot $saveDest -Downloader $downloader
        Test-BRAVOCondition -Condition (-not $saved2.Success -and ($saved2.Problems -join ' ') -match 'release-manifest') -Name 'UpdateRelease/Save-MissingManifestIsProblem' -Failure 'Відсутній маніфест на сервері — Problem, Success=false.'
        $saveDest2 = Join-Path (New-RelCaseDir) 'dest'
        [void](New-Item -ItemType Directory -Path $saveDest2 -Force)
        $emptyDownloader = { param($Uri, $OutFile) [System.IO.File]::WriteAllBytes($OutFile, [byte[]]@()) }
        $saved3 = Save-BRAVOReleaseArtifact -Candidate (Get-BRAVOReleaseCandidate -Tag 'v5.3.0') -DestinationRoot $saveDest2 -Downloader $emptyDownloader
        Test-BRAVOCondition -Condition (-not $saved3.Success -and $saved3.Problems.Count -eq 3) -Name 'UpdateRelease/Save-EmptyFilesRejected' -Failure 'Порожні завантаження — Problem на кожен ассет.'
        $badCandidate = [pscustomobject]@{ Tag = 'v1.0.0'; ArtifactName = '..\evil.zip'; ArtifactUri = 'https://host-a/x'; ChecksumUri = 'https://host-a/y'; ManifestUri = 'https://host-a/z' }
        $saved4 = Save-BRAVOReleaseArtifact -Candidate $badCandidate -DestinationRoot $saveDest2 -Downloader $downloader
        Test-BRAVOCondition -Condition (-not $saved4.Success) -Name 'UpdateRelease/Save-RejectsPathInArtifactName' -Failure 'Ім''я артефакта з розділювачем шляху має відхилятись.'
        $saved5 = Save-BRAVOReleaseArtifact -Candidate (Get-BRAVOReleaseCandidate -Tag 'v5.3.0') -DestinationRoot (Join-Path $releaseTestRoot 'absent-dir') -Downloader $downloader
        Test-BRAVOCondition -Condition (-not $saved5.Success) -Name 'UpdateRelease/Save-MissingDestination' -Failure 'Неіснуючий DestinationRoot — Problem.'

        # --- Corrupt zip -----------------------------------------------------------
        $fx = New-RelFixture -Base (New-RelCaseDir)
        Write-RelFile $fx.Zip 'this is not a zip'
        $r = Test-BRAVOReleaseArtifact -ZipPath $fx.Zip -ChecksumPath $fx.Sha -ManifestPath $fx.Manifest -ExpectedTag 'v5.3.0'
        Test-BRAVOCondition -Condition (-not $r.IsValid) -Name 'UpdateRelease/CorruptZip' -Failure 'Не-zip архів має блокуватись.'

        # --- Cyrillic / space paths ----------------------------------------------
        $fxCy = New-RelFixture -Base (Join-Path (New-RelCaseDir) 'Каталог з пробілом і кирилицею')
        $r = Test-BRAVOReleaseArtifact -ZipPath $fxCy.Zip -ChecksumPath $fxCy.Sha -ManifestPath $fxCy.Manifest -ExpectedTag 'v5.3.0'
        Test-BRAVOCondition -Condition $r.IsValid -Name 'UpdateRelease/CyrillicSpacePaths' -Failure 'Шляхи з пробілами й кирилицею мають працювати.'

        # --- Test-BRAVOStagedRuntime ----------------------------------------------
        $fxS = New-RelFixture -Base (New-RelCaseDir)
        $s = Test-BRAVOStagedRuntime -StagedRoot $fxS.Stage -ExpectedVersion '5.3.0'
        Test-BRAVOCondition -Condition ($s.IsValid -and @(Get-RelBlockerIds $s).Count -eq 0) -Name 'UpdateRelease/Staged-Valid' -Failure ('Валідний staged-комплект: {0}' -f ((Get-RelBlockerIds $s) -join ','))
        $s = Test-BRAVOStagedRuntime -StagedRoot $fxS.Stage -ExpectedVersion '5.4.0'
        Test-BRAVOCondition -Condition (-not $s.IsValid -and (Get-RelBlockerIds $s) -contains 'Staged.VersionMismatch') -Name 'UpdateRelease/Staged-VersionMismatch' -Failure 'Версія staged має збігатись.'
        $s = Test-BRAVOStagedRuntime -StagedRoot (Join-Path $fxS.Base 'absent') -ExpectedVersion '5.3.0'
        Test-BRAVOCondition -Condition (-not $s.IsValid) -Name 'UpdateRelease/Staged-MissingRoot' -Failure 'Відсутній staged-каталог — Blocker.'

        $fxS2 = New-RelFixture -Base (New-RelCaseDir)
        Write-RelFile (Join-Path $fxS2.Stage 'BRAVO_SETUP.ps1') '# tampered'
        $s = Test-BRAVOStagedRuntime -StagedRoot $fxS2.Stage -ExpectedVersion '5.3.0'
        $ib = @($s.Findings | Where-Object { $_.id -eq 'Staged.Integrity' -and $_.severity -eq 'Blocker' })
        Test-BRAVOCondition -Condition (-not $s.IsValid -and $ib.Count -eq 1 -and $ib[0].exitCodeHint -eq 33) -Name 'UpdateRelease/Staged-IntegrityMismatch' -Failure 'Підмінений файл — Blocker 33 (довіреним guard-ом).'

        $fxS3 = New-RelFixture -Base (New-RelCaseDir)
        Write-RelFile (Join-Path $fxS3.Stage 'Tools\planted.ps1') '# planted'
        $s = Test-BRAVOStagedRuntime -StagedRoot $fxS3.Stage -ExpectedVersion '5.3.0'
        Test-BRAVOCondition -Condition (-not $s.IsValid -and (Get-RelBlockerIds $s) -contains 'Staged.Integrity') -Name 'UpdateRelease/Staged-UnknownScript' -Failure 'Сторонній скрипт у staged — Blocker.'

        $fxS4 = New-RelFixture -Base (New-RelCaseDir)
        Write-RelFile (Join-Path $fxS4.Stage 'BRAVO.local.config') '# site'
        $s = Test-BRAVOStagedRuntime -StagedRoot $fxS4.Stage -ExpectedVersion '5.3.0'
        Test-BRAVOCondition -Condition (-not $s.IsValid -and (Get-RelBlockerIds $s) -contains 'Staged.SiteFile') -Name 'UpdateRelease/Staged-LocalConfigRejected' -Failure 'BRAVO.local.config у payload — Blocker.'
        $fxS5 = New-RelFixture -Base (New-RelCaseDir)
        Write-RelFile (Join-Path $fxS5.Stage 'sub\BRAVO.config') '# site'
        $s = Test-BRAVOStagedRuntime -StagedRoot $fxS5.Stage -ExpectedVersion '5.3.0'
        Test-BRAVOCondition -Condition (-not $s.IsValid -and (Get-RelBlockerIds $s) -contains 'Staged.SiteFile') -Name 'UpdateRelease/Staged-NestedBravoConfigRejected' -Failure 'BRAVO.config у payload (будь-де) — Blocker.'

        $fxS6 = New-RelFixture -Base (New-RelCaseDir)
        Remove-Item -LiteralPath (Join-Path $fxS6.Stage 'Tools\TOOLS_MANIFEST.json') -Force
        $s = Test-BRAVOStagedRuntime -StagedRoot $fxS6.Stage -ExpectedVersion '5.3.0'
        Test-BRAVOCondition -Condition (-not $s.IsValid -and (Get-RelBlockerIds $s) -contains 'Staged.RequiredFile') -Name 'UpdateRelease/Staged-MissingRequiredFile' -Failure 'Відсутній обов''язковий файл — Blocker.'

        $fxS7 = New-RelFixture -Base (Join-Path (New-RelCaseDir) 'Staged з пробілом і кирилицею')
        $s = Test-BRAVOStagedRuntime -StagedRoot $fxS7.Stage -ExpectedVersion '5.3.0'
        Test-BRAVOCondition -Condition $s.IsValid -Name 'UpdateRelease/Staged-CyrillicSpacePaths' -Failure 'Staged із кирилицею/пробілами має проходити.'
    }
} finally {
    $releaseTestFullRoot = [System.IO.Path]::GetFullPath($releaseTestRoot)
    $releaseTestTempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($releaseTestFullRoot.StartsWith($releaseTestTempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $releaseTestFullRoot) -like 'BRAVO_UPDATE_RELEASE_SELF_TEST_*' -and
        (Test-Path -LiteralPath $releaseTestFullRoot)) {
        Remove-Item -LiteralPath $releaseTestFullRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
