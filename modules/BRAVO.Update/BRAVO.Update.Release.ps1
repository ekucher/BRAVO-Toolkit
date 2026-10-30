# BRAVO.Update.Release — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Отримання та верифікація релізного артефакта (INS-030…034, INS-036).
# Усі функції повертають об'єкти й не виконують і не імпортують код payload:
# zip лише читається як дані (System.IO.Compression), розпакування — окрема
# частина Staging після успішної верифікації.
#
# РІШЕННЯ v1: лише явний тег. Режиму "latest" немає — оператор свідомо
# називає версію, яку розгортає; автоматичний вибір "найновішого" релізу
# означав би довіру до мутабельного вказівника на стороні сервера.
#
# Онлайн і офлайн-шляхи сходяться в один конвеєр Test-BRAVOReleaseArtifact:
# вердикт не залежить від того, звідки взято файли.

$script:BRAVOReleaseDefaultBaseUri = 'https://github.com/ekucher/BRAVO-Toolkit/releases/download'
$script:BRAVOReleaseManifestFileName = 'release-manifest.json'
# Той самий regex, що й у .github/workflows/release-artifact.yml
# (`$isPrerelease = $tag -match '-(dev|rc)\.'`): розбіжність дала б різні
# рішення "це prerelease?" у CI і на сервері.
$script:BRAVOReleasePrereleaseTagPattern = '-(dev|rc)\.'
$script:BRAVOReleaseTagPattern = '^v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$'
$script:BRAVOReleaseArtifactNamePattern = '^BRAVO-Toolkit-[0-9A-Za-z.\-]+\.zip$'
# Службове обмеження: VERSION.json — крихітний файл; більший вважаємо підміною.
$script:BRAVOReleaseMaxVersionJsonBytes = 65536

function Get-BRAVOReleaseCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [string]$RepositoryBaseUri = $script:BRAVOReleaseDefaultBaseUri
    )

    if ($Tag -cnotmatch $script:BRAVOReleaseTagPattern) {
        throw ('Некоректний тег релізу "{0}": очікується vX.Y.Z[-prerelease]. Режиму "latest" немає — вкажіть тег явно.' -f $Tag)
    }
    if ([string]::IsNullOrWhiteSpace($RepositoryBaseUri)) {
        throw 'RepositoryBaseUri порожній.'
    }
    # Лише https (і file:// для локальних дзеркал/тестів): http без TLS дозволив би
    # підміну артефакта в дорозі до перевірки хешу, що сам береться з того ж каналу.
    if ($RepositoryBaseUri -notmatch '^(https|file)://') {
        throw ('RepositoryBaseUri має починатися з https:// або file://: {0}' -f $RepositoryBaseUri)
    }

    $baseUri = $RepositoryBaseUri.TrimEnd('/')
    $packageVersion = $Tag.Substring(1)
    $artifactName = 'BRAVO-Toolkit-{0}.zip' -f $packageVersion
    $tagRoot = '{0}/{1}' -f $baseUri, $Tag

    return [pscustomobject]@{
        Tag            = $Tag
        PackageVersion = $packageVersion
        IsPrerelease   = [bool]($Tag -match $script:BRAVOReleasePrereleaseTagPattern)
        ArtifactName   = $artifactName
        ArtifactUri    = '{0}/{1}' -f $tagRoot, $artifactName
        ChecksumUri    = '{0}/{1}.sha256' -f $tagRoot, $artifactName
        ManifestUri    = '{0}/{1}' -f $tagRoot, $script:BRAVOReleaseManifestFileName
    }
}

function Invoke-BRAVOReleaseDefaultDownload {
    <#
        Типовий завантажувач. TLS 1.2 вмикається явно: Windows PowerShell 5.1
        на старих Windows Server за замовчуванням може не пропонувати його, а
        GitHub інших протоколів не приймає. застарілі клієнти завантаження заборонені політикою.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop | Out-Null
}

function Save-BRAVOReleaseArtifact {
    <#
        Завантажує три ассети релізу в DestinationRoot (його створює викликач
        через New-BRAVOUpdatePrivateDirectory). Відсутній release-manifest.json
        — Problem і Success=$false: старі deploy-скрипти лише попереджали, але в
        Installer v1 маніфест — єдине незалежне джерело провенансу, тож без
        нього stable-розкатка неможлива (суворіше за legacy свідомо).
        Downloader: scriptblock з двома позиційними аргументами (Uri, OutFile).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [scriptblock]$Downloader
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $result = [pscustomobject]@{
        Success      = $false
        ZipPath      = $null
        ChecksumPath = $null
        ManifestPath = $null
        Problems     = @()
    }

    foreach ($required in @('Tag', 'ArtifactName', 'ArtifactUri', 'ChecksumUri', 'ManifestUri')) {
        if ($null -eq $Candidate -or $null -eq $Candidate.PSObject.Properties[$required] -or
            [string]::IsNullOrWhiteSpace([string]$Candidate.$required)) {
            [void]$problems.Add(('Кандидат релізу не містить поля {0}.' -f $required))
        }
    }
    if ($problems.Count -eq 0) {
        # Ім'я артефакта стає іменем локального файлу: жодних розділювачів шляху.
        if ([string]$Candidate.ArtifactName -cnotmatch $script:BRAVOReleaseArtifactNamePattern) {
            [void]$problems.Add(('Недопустиме ім''я артефакта: {0}' -f $Candidate.ArtifactName))
        }
        if ([string]$Candidate.Tag -cnotmatch $script:BRAVOReleaseTagPattern) {
            [void]$problems.Add(('Недопустимий тег: {0}' -f $Candidate.Tag))
        }
    }
    if ($problems.Count -eq 0 -and -not [System.IO.Directory]::Exists($DestinationRoot)) {
        [void]$problems.Add(('Каталог призначення не існує: {0}' -f $DestinationRoot))
    }
    if ($problems.Count -gt 0) {
        $result.Problems = $problems.ToArray()
        return $result
    }

    $zipPath = Join-Path $DestinationRoot ([string]$Candidate.ArtifactName)
    $checksumPath = $zipPath + '.sha256'
    $manifestPath = Join-Path $DestinationRoot $script:BRAVOReleaseManifestFileName
    $assets = @(
        @{ Label = 'архів'; Uri = [string]$Candidate.ArtifactUri; Path = $zipPath },
        @{ Label = 'файл SHA-256'; Uri = [string]$Candidate.ChecksumUri; Path = $checksumPath },
        @{ Label = 'release-manifest.json'; Uri = [string]$Candidate.ManifestUri; Path = $manifestPath }
    )

    foreach ($asset in $assets) {
        try {
            if ($null -ne $Downloader) {
                & $Downloader $asset.Uri $asset.Path | Out-Null
            } else {
                Invoke-BRAVOReleaseDefaultDownload -Uri $asset.Uri -OutFile $asset.Path
            }
        } catch {
            [void]$problems.Add(('Не вдалося завантажити {0} ({1}): {2}' -f $asset.Label, $asset.Uri, $_.Exception.Message))
            continue
        }
        if (-not [System.IO.File]::Exists($asset.Path) -or (New-Object System.IO.FileInfo $asset.Path).Length -eq 0) {
            [void]$problems.Add(('Ассет {0} відсутній або порожній після завантаження: {1}' -f $asset.Label, $asset.Uri))
        }
    }

    $result.ZipPath = $zipPath
    $result.ChecksumPath = $checksumPath
    $result.ManifestPath = $manifestPath
    $result.Problems = $problems.ToArray()
    $result.Success = ($problems.Count -eq 0)
    return $result
}

function Get-BRAVOOfflineReleaseSource {
    <#
        Офлайн-джерело: КОПІЮЄ zip, .sha256 і маніфест у DestinationRoot, щоб
        верифікація йшла по копії, яку оператор уже не може підмінити між
        перевіркою й використанням (TOCTOU). Файл хешів перейменовується під
        "<zip>.sha256": вміст перевіряється за іменем zip, а не за іменем
        вихідного файлу.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [string]$ChecksumPath,
        [string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $result = [pscustomobject]@{
        Success      = $false
        ZipPath      = $null
        ChecksumPath = $null
        ManifestPath = $null
        Problems     = @()
    }

    if (-not [System.IO.File]::Exists($ZipPath)) {
        [void]$problems.Add(('Архів не знайдено: {0}' -f $ZipPath))
    }
    if (-not [System.IO.Directory]::Exists($DestinationRoot)) {
        [void]$problems.Add(('Каталог призначення не існує: {0}' -f $DestinationRoot))
    }
    if ($problems.Count -gt 0) {
        $result.Problems = $problems.ToArray()
        return $result
    }

    $zipLeaf = [System.IO.Path]::GetFileName($ZipPath)
    $zipDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($ZipPath))
    if ([string]::IsNullOrWhiteSpace($ChecksumPath)) {
        $ChecksumPath = Join-Path $zipDirectory ($zipLeaf + '.sha256')
    }
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Join-Path $zipDirectory $script:BRAVOReleaseManifestFileName
    }

    $copies = @(
        @{ Label = 'архів'; Source = $ZipPath; Target = (Join-Path $DestinationRoot $zipLeaf) },
        @{ Label = 'файл SHA-256'; Source = $ChecksumPath; Target = (Join-Path $DestinationRoot ($zipLeaf + '.sha256')) },
        @{ Label = 'release-manifest.json'; Source = $ManifestPath; Target = (Join-Path $DestinationRoot $script:BRAVOReleaseManifestFileName) }
    )
    foreach ($copy in $copies) {
        if (-not [System.IO.File]::Exists($copy.Source)) {
            [void]$problems.Add(('Не знайдено {0}: {1}' -f $copy.Label, $copy.Source))
            continue
        }
        try {
            Copy-Item -LiteralPath $copy.Source -Destination $copy.Target -Force -ErrorAction Stop
        } catch {
            [void]$problems.Add(('Не вдалося скопіювати {0}: {1}' -f $copy.Label, $_.Exception.Message))
        }
    }

    $result.ZipPath = $copies[0].Target
    $result.ChecksumPath = $copies[1].Target
    $result.ManifestPath = $copies[2].Target
    $result.Problems = $problems.ToArray()
    $result.Success = ($problems.Count -eq 0)
    return $result
}

function Compare-BRAVOReleaseVersionText {
    <#
        Порівняння версій довіреним guard-ом ПОТОЧНОГО комплекту (не staged)
        через канонічний Import-BRAVOUpdateTrustedGuardFunctions (Paths).
        Повертає -1/0/1 або $null, якщо версію не розпізнано; відсутній guard
        -> виняток (викликач перетворює його на finding).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$LeftText,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RightText
    )

    Import-BRAVOUpdateTrustedGuardFunctions
    $left = ConvertTo-BRAVOComparableVersion -Text $LeftText
    $right = ConvertTo-BRAVOComparableVersion -Text $RightText
    if ($null -eq $left -or $null -eq $right) { return $null }
    return [int](Compare-BRAVOComparableVersion -Left $left -Right $right)
}

function Test-BRAVOReleaseTrustedIntegrity {
    <#
        Перевірка цілісності staged-дерева ДОВІРЕНОЮ копією guard-а (поточний
        комплект). Staged-копію guard-а не виконуємо: вона ще не перевірена.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StagedRoot,
        [Parameter(Mandatory = $true)][string]$IntegrityManifestPath
    )

    Import-BRAVOUpdateTrustedGuardFunctions
    return (Test-BRAVORuntimeManifestIntegrity -RuntimeRoot $StagedRoot -ManifestPath $IntegrityManifestPath -Mode Enforce)
}

function Read-BRAVOReleaseJsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'файл порожній' }
    return ($raw | ConvertFrom-Json)
}

function Get-BRAVOReleaseZipInfo {
    <#
        Читає zip БЕЗ розпакування: перелік записів і VERSION.json як дані.
        Нічого не пишеться на диск; жоден файл з архіву не виконується.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    $info = [pscustomobject]@{
        Entries     = @()
        VersionText = $null
        Problems    = @()
    }
    $problems = New-Object System.Collections.Generic.List[string]
    $entries = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        foreach ($entry in $archive.Entries) {
            $name = ([string]$entry.FullName).Replace('\', '/')
            if ($name.EndsWith('/')) { continue }
            $key = $name.ToLowerInvariant()
            if ($seen.ContainsKey($key)) {
                [void]$problems.Add(('Дублікат запису в архіві (без урахування регістру): {0}' -f $name))
                continue
            }
            $seen[$key] = $true
            # Defense in depth: повна валідація шляхів — у Staging, але такий архів
            # не мусить доходити навіть до порівняння списків.
            $segments = @($name.Split('/'))
            if ($name.StartsWith('/') -or $name -match '^[A-Za-z]:' -or
                ($segments -contains '..') -or ($segments -contains '.')) {
                [void]$problems.Add(('Небезпечний шлях запису в архіві: {0}' -f $name))
            }
            [void]$entries.Add([pscustomobject]@{ Name = $name; Length = [long]$entry.Length })

            if ($key -eq 'version.json') {
                if ($entry.Length -gt $script:BRAVOReleaseMaxVersionJsonBytes) {
                    [void]$problems.Add('VERSION.json в архіві завеликий для метаданих версії.')
                    continue
                }
                $stream = $entry.Open()
                try {
                    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                    try { $info.VersionText = $reader.ReadToEnd() } finally { $reader.Dispose() }
                } finally {
                    $stream.Dispose()
                }
            }
        }
    } catch {
        [void]$problems.Add(('Не вдалося прочитати архів як zip: {0}' -f $_.Exception.Message))
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }

    $info.Entries = $entries.ToArray()
    $info.Problems = $problems.ToArray()
    return $info
}

function Test-BRAVOReleaseArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$ChecksumPath,
        [AllowEmptyString()][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ExpectedTag,
        [switch]$AllowPrerelease,
        [string]$StatePath
    )

    $findings = New-Object System.Collections.Generic.List[object]
    $result = [pscustomobject]@{
        IsValid         = $false
        Severity        = 'Error'
        ArtifactSha256  = $null
        ManifestSha256  = $null
        PackageVersion  = $null
        ReleaseChannel  = $null
        Findings        = @()
        VersionMetadata = $null
    }
    $blockerAction = 'Отримайте артефакт знову з довіреного джерела; розгортання не продовжується.'

    $addBlocker = {
        param($Id, $Title, $Meaning, $Details, $Hint)
        [void]$findings.Add((New-BRAVOUpdateFinding -Id $Id -Severity Blocker -Title $Title -Meaning $Meaning `
                    -Action $blockerAction -Details ([string]$Details) -ExitCodeHint $Hint))
    }
    $finish = {
        $hasBlocker = @($findings | Where-Object { $_.severity -eq 'Blocker' }).Count -gt 0
        $hasWarning = @($findings | Where-Object { $_.severity -eq 'Warning' }).Count -gt 0
        $result.Findings = $findings.ToArray()
        $result.IsValid = (-not $hasBlocker)
        $result.Severity = $(if ($hasBlocker) { 'Error' } elseif ($hasWarning) { 'Warning' } else { 'Ok' })
        return $result
    }

    if ($ExpectedTag -cnotmatch $script:BRAVOReleaseTagPattern) {
        & $addBlocker 'Release.Tag' 'Некоректний очікуваний тег' 'Тег релізу не відповідає vX.Y.Z[-prerelease].' $ExpectedTag $null
        return (& $finish)
    }
    $expectedVersion = $ExpectedTag.Substring(1)
    $isPrereleaseTag = [bool]($ExpectedTag -match $script:BRAVOReleasePrereleaseTagPattern)

    if (-not [System.IO.File]::Exists($ZipPath)) {
        & $addBlocker 'Release.ArtifactMissing' 'Архів релізу не знайдено' 'Без архіва перевіряти нічого.' $ZipPath 42
        return (& $finish)
    }
    $zipLeaf = [System.IO.Path]::GetFileName($ZipPath)

    # --- 1. SHA-256 архіву проти файлу хешів --------------------------------
    $computedHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $result.ArtifactSha256 = $computedHash

    $checksumOk = $false
    if (-not [System.IO.File]::Exists($ChecksumPath)) {
        & $addBlocker 'Release.ChecksumMissing' 'Файл SHA-256 відсутній' 'Без незалежного хешу цілісність архіва не підтверджується.' $ChecksumPath 42
    } else {
        $checksumLine = $null
        foreach ($line in [System.IO.File]::ReadAllLines($ChecksumPath, [System.Text.Encoding]::UTF8)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $checksumLine = $line.Trim(); break }
        }
        if ($null -eq $checksumLine -or $checksumLine -notmatch '^([0-9A-Fa-f]{64}) [ *](.+)$') {
            & $addBlocker 'Release.ChecksumFormat' 'Файл SHA-256 має неочікуваний формат' 'Очікується "<HASH> *<ім''я архіва>".' $ChecksumPath 42
        } else {
            $declaredHash = $Matches[1].ToLowerInvariant()
            $declaredName = $Matches[2]
            if ($declaredName -cne $zipLeaf) {
                & $addBlocker 'Release.ChecksumName' 'Файл SHA-256 належить іншому архіву' 'Ім''я у файлі хешів не збігається з іменем архіва.' ('{0} <> {1}' -f $declaredName, $zipLeaf) 42
            } elseif ($declaredHash -ne $computedHash) {
                & $addBlocker 'Release.ArtifactHash' 'SHA-256 архіва не збігається' 'Архів пошкоджено або підмінено.' ('очікувано {0}, обчислено {1}' -f $declaredHash, $computedHash) 42
            } else {
                $checksumOk = $true
            }
        }
    }
    if ($checksumOk) {
        [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Release.ArtifactHash' -Severity Ok -Title 'SHA-256 архіва збігається' -Details $computedHash))
    }

    # --- 2. release-manifest.json -------------------------------------------
    $manifest = $null
    $manifestFileMap = $null
    if ([string]::IsNullOrWhiteSpace($ManifestPath) -or -not [System.IO.File]::Exists($ManifestPath)) {
        & $addBlocker 'Release.ManifestMissing' 'release-manifest.json відсутній' 'У Installer v1 маніфест обов''язковий: це єдине незалежне джерело провенансу.' $ManifestPath 42
    } else {
        $result.ManifestSha256 = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        try {
            $manifest = Read-BRAVOReleaseJsonFile -Path $ManifestPath
        } catch {
            & $addBlocker 'Release.ManifestParse' 'release-manifest.json не розбирається' 'Маніфест пошкоджено.' $_.Exception.Message 42
        }
    }
    if ($null -ne $manifest) {
        $schema = Get-BRAVODeployMetadataValue -Source $manifest -Name 'schemaVersion'
        if ($null -eq $schema -or [string]$schema -ne '1') {
            & $addBlocker 'Release.ManifestSchema' 'Непідтримувана схема release-manifest.json' 'Підтримується лише schemaVersion 1.' ([string]$schema) 42
            $manifest = $null
        }
    }
    if ($null -ne $manifest) {
        $artifactNode = Get-BRAVODeployMetadataValue -Source $manifest -Name 'artifact'
        $manifestSha = Get-BRAVODeployMetadataValue -Source $artifactNode -Name 'sha256'
        $manifestName = Get-BRAVODeployMetadataValue -Source $artifactNode -Name 'name'
        if ($null -eq $manifestSha -or ([string]$manifestSha).Trim().ToLowerInvariant() -ne $computedHash) {
            & $addBlocker 'Release.ManifestArtifactHash' 'artifact.sha256 у маніфесті не збігається з архівом' 'Маніфест описує інший архів.' ('маніфест {0}, обчислено {1}' -f [string]$manifestSha, $computedHash) 42
        }
        if ($null -eq $manifestName -or [string]$manifestName -cne $zipLeaf) {
            & $addBlocker 'Release.ManifestArtifactName' 'artifact.name у маніфесті не збігається з іменем архіва' 'Маніфест описує інший архів.' ('маніфест {0}, архів {1}' -f [string]$manifestName, $zipLeaf) 42
        }
        $manifestFiles = Get-BRAVODeployMetadataValue -Source $manifest -Name 'files'
        if ($null -eq $manifestFiles -or @($manifestFiles).Count -eq 0) {
            & $addBlocker 'Release.ManifestFiles' 'Маніфест не містить переліку files[]' 'Без переліку неможливо звірити вміст архіва.' '' 42
        } else {
            $manifestFileMap = @{}
            foreach ($fileNode in @($manifestFiles)) {
                $filePath = Get-BRAVODeployMetadataValue -Source $fileNode -Name 'path'
                $fileSize = Get-BRAVODeployMetadataValue -Source $fileNode -Name 'sizeBytes'
                if ($null -eq $filePath -or [string]::IsNullOrWhiteSpace([string]$filePath)) { continue }
                $normalizedPath = ([string]$filePath).Replace('\', '/')
                $manifestFileMap[$normalizedPath.ToLowerInvariant()] = [pscustomobject]@{ Path = $normalizedPath; Size = $fileSize }
            }
        }
    }

    # --- 3. VERSION.json із zip без розпакування ----------------------------
    $zipInfo = Get-BRAVOReleaseZipInfo -ZipPath $ZipPath
    foreach ($zipProblem in $zipInfo.Problems) {
        & $addBlocker 'Release.ZipContent' 'Архів містить недопустимий вміст' 'Структуру архіва не можна вважати довіреною.' $zipProblem 42
    }
    $versionMetadata = $null
    if ([string]::IsNullOrWhiteSpace($zipInfo.VersionText)) {
        & $addBlocker 'Release.VersionMissing' 'VERSION.json відсутній в архіві' 'Без метаданих версії реліз не ідентифікується.' $ZipPath 42
    } else {
        try {
            $versionMetadata = $zipInfo.VersionText | ConvertFrom-Json
        } catch {
            & $addBlocker 'Release.VersionParse' 'VERSION.json в архіві не розбирається' 'Метадані версії пошкоджено.' $_.Exception.Message 42
        }
    }
    $packageVersion = ''
    if ($null -ne $versionMetadata) {
        $result.VersionMetadata = $versionMetadata
        $pv = Get-BRAVODeployMetadataValue -Source $versionMetadata -Name 'packageVersion'
        $packageVersion = $(if ($null -eq $pv) { '' } else { ([string]$pv).Trim() })
        $result.PackageVersion = $packageVersion
        $rc = Get-BRAVODeployMetadataValue -Source $versionMetadata -Name 'releaseChannel'
        $result.ReleaseChannel = $(if ($null -eq $rc) { $null } else { [string]$rc })

        if ($packageVersion -ne $expectedVersion) {
            & $addBlocker 'Release.VersionTag' 'Версія в архіві не відповідає запитаному тегу' 'Тег і вміст архіва належать різним релізам.' ('VERSION.json {0}, очікувано {1}' -f $packageVersion, $expectedVersion) 42
        }

        # --- 4. Провенанс: маніфест ОБОВ'ЯЗКОВИЙ (null = Blocker) -----------
        if ($null -ne $manifest) {
            $provenance = Get-BRAVODeployProvenanceVerdict -VersionMetadata $versionMetadata -ReleaseManifest $manifest `
                -ArtifactSha256 $computedHash -ExpectedTag $ExpectedTag
            if (-not $provenance.IsValid) {
                & $addBlocker 'Release.Provenance' 'Провенанс релізу не підтверджено' 'VERSION.json не узгоджується з незалежним release-manifest.json.' ([string]::Join('; ', @($provenance.Problems))) 42
            } else {
                [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Release.Provenance' -Severity Ok -Title 'Провенанс підтверджено release-manifest.json' -Details ([string]$provenance.Message)))
            }
        }

        # --- 5. Канал релізу -------------------------------------------------
        $channelDecision = Get-BRAVODeployReleaseChannelDecision -VersionMetadata $versionMetadata -AllowPrereleaseChannel:$AllowPrerelease
        if (-not $channelDecision.Allowed) {
            & $addBlocker 'Release.Channel' 'Канал релізу не дозволено' 'Не-stable реліз розгортається лише за явним рішенням оператора.' $channelDecision.Message 42
        } elseif ($channelDecision.Severity -eq 'Warning') {
            [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Release.Channel' -Severity Warning -Title 'Не-stable реліз за явним дозволом' `
                        -Meaning 'Prerelease розгортається за рішенням оператора.' -Action 'Зафіксуйте рішення в журналі.' -Details ([string]$channelDecision.Message)))
        }
        if ($isPrereleaseTag -and -not $AllowPrerelease) {
            & $addBlocker 'Release.PrereleaseTag' 'Тег є prerelease без явного дозволу' 'Prerelease-теги (-dev./-rc.) не розгортаються без явного дозволу.' $ExpectedTag 42
        }

        # --- 7. Захист від відкату ------------------------------------------
        # BRAVO_ALLOW_DOWNGRADE тут не читається й не встановлюється свідомо.
        if (-not [string]::IsNullOrWhiteSpace($StatePath) -and [System.IO.File]::Exists($StatePath)) {
            $recorded = ''
            $stateOk = $true
            try {
                $state = Read-BRAVOReleaseJsonFile -Path $StatePath
                $full = Get-BRAVODeployMetadataValue -Source $state -Name 'highestVersionFull'
                $basic = Get-BRAVODeployMetadataValue -Source $state -Name 'highestVersion'
                if (-not [string]::IsNullOrWhiteSpace([string]$full)) { $recorded = ([string]$full).Trim() }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$basic)) { $recorded = ([string]$basic).Trim() }
            } catch {
                $stateOk = $false
            }
            if (-not $stateOk -or [string]::IsNullOrWhiteSpace($recorded)) {
                # Пошкоджений стан не вважаємо відсутнім: fail closed.
                & $addBlocker 'Release.DowngradeState' 'Файл стану версій пошкоджено' 'Захист від відкату не може порівняти версії.' $StatePath 35
            } else {
                $cmp = $null
                $guardFailed = $false
                try {
                    $cmp = Compare-BRAVOReleaseVersionText -LeftText $packageVersion -RightText $recorded
                } catch {
                    $guardFailed = $true
                    & $addBlocker 'Release.DowngradeGuard' 'Не вдалося виконати порівняння версій' 'Довірений guard недоступний.' $_.Exception.Message 35
                }
                if ($guardFailed) {
                    # Blocker уже додано.
                } elseif ($null -eq $cmp) {
                    & $addBlocker 'Release.DowngradeVersion' 'Версію не розпізнано' 'Захист від відкату не може порівняти версії.' ('архів {0}, стан {1}' -f $packageVersion, $recorded) 35
                } elseif ($cmp -lt 0) {
                    & $addBlocker 'Release.Downgrade' 'Відкат версії' 'Архів старіший за найвищу версію, що вже запускалась на цьому сервері.' ('архів {0}, найвища {1}' -f $packageVersion, $recorded) 35
                }
            }
        }
    }

    # --- 6. Перехресна перевірка files[] маніфесту й записів zip ------------
    if ($null -ne $manifestFileMap) {
        $zipMap = @{}
        foreach ($entry in $zipInfo.Entries) { $zipMap[$entry.Name.ToLowerInvariant()] = $entry }
        foreach ($key in @($manifestFileMap.Keys)) {
            $item = $manifestFileMap[$key]
            if (-not $zipMap.ContainsKey($key)) {
                & $addBlocker 'Release.FileListMissing' 'Файл з маніфесту відсутній в архіві' 'Вміст архіва не відповідає release-manifest.json.' $item.Path 42
            } elseif ($null -ne $item.Size -and [long]$item.Size -ne $zipMap[$key].Length) {
                & $addBlocker 'Release.FileListSize' 'Розмір файлу в архіві не збігається з маніфестом' 'Вміст архіва не відповідає release-manifest.json.' ('{0}: маніфест {1}, архів {2}' -f $item.Path, $item.Size, $zipMap[$key].Length) 42
            }
        }
        foreach ($entry in $zipInfo.Entries) {
            $ext = [System.IO.Path]::GetExtension($entry.Name).ToLowerInvariant()
            if (@('.ps1', '.psm1', '.psd1') -contains $ext -and -not $manifestFileMap.ContainsKey($entry.Name.ToLowerInvariant())) {
                & $addBlocker 'Release.FileListExtra' 'Скрипт в архіві не описаний маніфестом' 'Сторонній скрипт у комплекті може бути виконаний від SYSTEM.' $entry.Name 42
            }
        }
    }

    return (& $finish)
}

function Test-BRAVOStagedRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StagedRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $findings = New-Object System.Collections.Generic.List[object]
    $addBlocker = {
        param($Id, $Title, $Meaning, $Details, $Hint)
        [void]$findings.Add((New-BRAVOUpdateFinding -Id $Id -Severity Blocker -Title $Title -Meaning $Meaning `
                    -Action 'Не продовжуйте розгортання; отримайте й розпакуйте релізний артефакт знову.' -Details ([string]$Details) -ExitCodeHint $Hint))
    }
    $finish = {
        $blockers = @($findings | Where-Object { $_.severity -eq 'Blocker' })
        return [pscustomobject]@{ IsValid = ($blockers.Count -eq 0); Findings = $findings.ToArray() }
    }

    if (-not [System.IO.Directory]::Exists($StagedRoot)) {
        & $addBlocker 'Staged.Root' 'Staged-каталог не існує' 'Нічого перевіряти.' $StagedRoot 42
        return (& $finish)
    }

    $required = @('BRAVO_RUNTIME_GUARD.ps1', 'RUNTIME_MANIFEST.json', 'BRAVO_SETUP.ps1', 'BRAVO_CONFIG_LOADER.ps1', 'VERSION.json', 'Tools\TOOLS_MANIFEST.json')
    foreach ($relative in $required) {
        if (-not [System.IO.File]::Exists((Join-Path $StagedRoot $relative))) {
            & $addBlocker 'Staged.RequiredFile' 'Обов''язковий файл комплекту відсутній' 'Комплект неповний.' $relative 42
        }
    }

    # Файли сайту не постачаються ніколи: інакше оновлення перезаписало б
    # локальну конфігурацію сервера або внесло чужу.
    $rootPrefixLength = $StagedRoot.TrimEnd('\', '/').Length + 1
    foreach ($path in [System.IO.Directory]::GetFiles($StagedRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
        $leaf = [System.IO.Path]::GetFileName($path)
        if ($leaf -ieq 'BRAVO.config' -or $leaf -ieq 'BRAVO.local.config') {
            $relativeSite = $path.Substring($rootPrefixLength)
            & $addBlocker 'Staged.SiteFile' 'Payload містить файл конфігурації сайту' 'Файли сайту (BRAVO.config / BRAVO.local.config) не постачаються в релізі.' $relativeSite 42
        }
    }

    $versionPath = Join-Path $StagedRoot 'VERSION.json'
    if ([System.IO.File]::Exists($versionPath)) {
        $stagedVersion = ''
        try {
            $meta = Read-BRAVOReleaseJsonFile -Path $versionPath
            $pv = Get-BRAVODeployMetadataValue -Source $meta -Name 'packageVersion'
            if ($null -ne $pv) { $stagedVersion = ([string]$pv).Trim() }
        } catch {
            & $addBlocker 'Staged.VersionParse' 'VERSION.json staged-комплекту не розбирається' 'Метадані версії пошкоджено.' $_.Exception.Message 42
        }
        if ($stagedVersion -ne $ExpectedVersion) {
            & $addBlocker 'Staged.VersionMismatch' 'Версія staged-комплекту не збігається з очікуваною' 'Розпаковано не той реліз.' ('staged {0}, очікувано {1}' -f $stagedVersion, $ExpectedVersion) 42
        }
    }

    $integrityManifest = Join-Path $StagedRoot 'RUNTIME_MANIFEST.json'
    if ([System.IO.File]::Exists($integrityManifest)) {
        try {
            $integrity = Test-BRAVOReleaseTrustedIntegrity -StagedRoot $StagedRoot -IntegrityManifestPath $integrityManifest
            if (-not $integrity.IsValid) {
                & $addBlocker 'Staged.Integrity' 'Цілісність staged-комплекту порушено' 'Файли комплекту не збігаються з RUNTIME_MANIFEST.json.' ([string]$integrity.Message) 33
            } else {
                [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Staged.Integrity' -Severity Ok -Title 'Цілісність staged-комплекту підтверджено' -Details ('перевірено файлів: {0}' -f $integrity.CheckedCount)))
            }
        } catch {
            & $addBlocker 'Staged.IntegrityGuard' 'Не вдалося виконати перевірку цілісності' 'Довірений guard недоступний.' $_.Exception.Message 33
        }
    }

    return (& $finish)
}
