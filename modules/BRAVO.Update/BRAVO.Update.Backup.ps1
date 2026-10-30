# BRAVO.Update.Backup — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Верифікована резервна копія runtime (INS-043, ENGINE_DESIGN §3):
#   <BackupRoot>\<opId>\runtime\...            копія керованих файлів;
#   <BackupRoot>\<opId>\backup-manifest.json   ключ(з '/') -> SHA-256 (UPPER).
# Site-owned виключення (BRAVO.config, LOGS, BAZA ...) беруться ЛИШЕ з
# Get-BRAVOUpdateSiteOwnedPaths: друга копія списку розійшлася б із Deploy і
# Rollback, і відкат торкнувся б (або пропустив) не ті файли. ACL копій не
# переносяться: повторне hardening робить Scheduler-крок (ENGINE_DESIGN F3).
# Жодного виводу в консоль; збої повертаються в Problems, а не винятком.

$script:BRAVOUpdateBackupManifestName = 'backup-manifest.json'

# --- Приватні допоміжні функції ----------------------------------------------

function Test-BRAVOUpdateBackupOperationId {
    # Ідентифікатор операції стає іменем каталогу: допускаємо лише безпечний
    # набір, щоб '..', роздільники й ':' не вивели бекап за межі BackupRoot.
    [CmdletBinding()]
    param([AllowNull()][string]$OperationId)
    if ([string]::IsNullOrEmpty($OperationId)) { return $false }
    return ($OperationId -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
}

function Test-BRAVOUpdateBackupKeySafe {
    # Ключ manifest-а має бути відносним, з '/' і без '..', '.', порожніх
    # сегментів, ':' та '\': змінений manifest не повинен виводити запис за
    # межі runtime\ (path traversal через підроблений ключ).
    [CmdletBinding()]
    param([AllowNull()][string]$Key)
    if ([string]::IsNullOrEmpty($Key)) { return $false }
    if ($Key.IndexOf('\') -ge 0 -or $Key.IndexOf(':') -ge 0 -or $Key.StartsWith('/')) { return $false }
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($segment in @($Key -split '/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') { return $false }
        if ($segment.IndexOfAny($invalid) -ge 0) { return $false }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) { return $false }
    }
    return $true
}

function ConvertTo-BRAVOUpdateBackupFilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Key
    )
    return [System.IO.Path]::Combine($Root.TrimEnd('\', '/'), ($Key -replace '/', '\'))
}

function Find-BRAVOUpdateBackupReparsePoint {
    # Обхід дерева поза виключеннями; повертає шляхи reparse point-ів (файлів і
    # каталогів) і НЕ заходить у них: junction усередині runtime інакше
    # потягнув би в копію чужі дані (або вийшов за межі дерева). Сам корінь
    # теж перевіряється. Помилка читання = знахідка (fail closed).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs = @()
    )

    $found = New-Object System.Collections.Generic.List[string]
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $rootParent = [System.IO.Path]::GetDirectoryName($rootFull)
    if (Test-BRAVOUpdatePathHasReparsePoint -Path $rootFull -StopAt $rootParent) {
        [void]$found.Add($rootFull)
        return @($found.ToArray())
    }
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($rootFull)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($sub in [System.IO.Directory]::GetDirectories($dir)) {
                $name = [System.IO.Path]::GetFileName($sub)
                $skip = $false
                foreach ($ex in @($ExcludeDirs)) {
                    if ([string]::Equals($name, $ex, [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
                }
                if ($skip) { continue }
                if (Test-BRAVOUpdatePathHasReparsePoint -Path $sub -StopAt $dir) { [void]$found.Add($sub); continue }
                $stack.Push($sub)
            }
            foreach ($file in [System.IO.Directory]::GetFiles($dir)) {
                $leaf = [System.IO.Path]::GetFileName($file)
                $skip = $false
                foreach ($ex in @($ExcludeFiles)) {
                    if ([string]::Equals($leaf, $ex, [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
                }
                if ($skip) { continue }
                if (Test-BRAVOUpdatePathHasReparsePoint -Path $file -StopAt $dir) { [void]$found.Add($file) }
            }
        } catch {
            [void]$found.Add($dir + ' (помилка читання: ' + $_.Exception.Message + ')')
        }
    }
    return @($found.ToArray())
}

function Copy-BRAVOUpdateBackupFile {
    # Потокове копіювання з SHA-256 на льоту (файл читається один раз; хеш
    # рахується з тих самих байтів, що пишуться). Призначення лише CreateNew:
    # існуючий файл у новому бекапі = аномалія, а не привід перезаписувати.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $directory = [System.IO.Path]::GetDirectoryName($Destination)
    if (-not [System.IO.Directory]::Exists($directory)) { [void][System.IO.Directory]::CreateDirectory($directory) }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $sourceStream = $null
    $output = $null
    $length = [long]0
    try {
        $sourceStream = New-Object System.IO.FileStream($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read, 81920)
        $output = New-Object System.IO.FileStream($Destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 81920)
        $buffer = New-Object byte[] 81920
        while (($read = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
            $output.Write($buffer, 0, $read)
            $length += $read
        }
        [void]$sha.TransformFinalBlock($buffer, 0, 0)
        $output.Flush($true)
    } finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
    }
    try {
        [System.IO.File]::SetLastWriteTimeUtc($Destination, [System.IO.File]::GetLastWriteTimeUtc($Source))
    } catch {
        # Час модифікації — зручність, не частина цілісності: хеш уже зафіксовано.
        $null = $_
    }
    $hash = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToUpperInvariant()
    $sha.Dispose()
    return [pscustomobject]@{ Sha256 = $hash; Length = $length }
}

function Get-BRAVOUpdateBackupFileHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-BRAVODeployFileSha256 -Path $Path)
}

# --- Публічні функції --------------------------------------------------------

function Get-BRAVOUpdateBackupManifest {
    <#
    .SYNOPSIS
        Читає й структурно валідує backup-manifest.json (для Rollback/Test).
    .DESCRIPTION
        Не кидає виняток. Повертає { IsValid; Problems[]; Manifest; Files;
        Sha256 }, де Files — hashtable ключ -> SHA-256 (UPPER), Sha256 — хеш
        самого файла manifest-а (UPPER). Ключі з '..', абсолютні й дублікати
        (без урахування регістру) роблять manifest невалідним.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $problems = New-Object System.Collections.Generic.List[string]
    $manifest = $null
    $files = @{}
    $fileSha = $null
    try {
        if (-not [System.IO.File]::Exists($Path)) {
            [void]$problems.Add('backup-manifest.json не знайдено: ' + $Path)
        } else {
            $fileSha = Get-BRAVOUpdateBackupFileHash -Path $Path
            $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
            if ([string]::IsNullOrWhiteSpace($text)) {
                [void]$problems.Add('backup-manifest.json порожній.')
            } else {
                $manifest = $text | ConvertFrom-Json
            }
        }
    } catch {
        $manifest = $null
        [void]$problems.Add('backup-manifest.json пошкоджений: ' + $_.Exception.Message)
    }

    if ($null -ne $manifest) {
        foreach ($name in @('schemaVersion', 'operationId', 'sourceRuntimeRoot', 'createdUtc', 'excludeFiles', 'excludeDirs', 'files', 'fileCount', 'totalBytes')) {
            if ($null -eq $manifest.PSObject.Properties[$name]) { [void]$problems.Add('manifest без поля ' + $name) }
        }
        if ($problems.Count -eq 0) {
            if ([int]$manifest.schemaVersion -ne 1) { [void]$problems.Add('непідтримувана schemaVersion manifest-а.') }
            if ($null -eq $manifest.files) {
                [void]$problems.Add('manifest без розділу files.')
            } else {
                foreach ($property in $manifest.files.PSObject.Properties) {
                    $key = [string]$property.Name
                    $value = [string]$property.Value
                    if (-not (Test-BRAVOUpdateBackupKeySafe -Key $key)) {
                        [void]$problems.Add('небезпечний ключ у manifest: ' + $key)
                        continue
                    }
                    if ($value -cnotmatch '^[0-9A-F]{64}$') {
                        [void]$problems.Add('некоректний SHA-256 для ' + $key)
                        continue
                    }
                    if ($files.ContainsKey($key)) {
                        [void]$problems.Add('дублікат ключа в manifest: ' + $key)
                        continue
                    }
                    $files[$key] = $value
                }
                if ($problems.Count -eq 0 -and [int]$manifest.fileCount -ne $files.Count) {
                    [void]$problems.Add('fileCount не збігається з кількістю ключів files.')
                }
            }
        }
    }

    return [pscustomobject]@{
        IsValid  = ($problems.Count -eq 0)
        Problems = @($problems.ToArray())
        Manifest = $manifest
        Files    = $files
        Sha256   = $fileSha
    }
}

function Test-BRAVORuntimeBackup {
    <#
    .SYNOPSIS
        Перевіряє резервну копію: manifest, байти копії, (опційно) живий runtime.
    .DESCRIPTION
        1) SHA-256 файла manifest-а == -ExpectedManifestSha256 (підміна manifest-а
           разом із файлами відсікається хешем із журналу);
        2) набір файлів у <BackupPath>\runtime точно дорівнює ключам manifest-а
           (зайвий файл = помилка), кожен файл має хеш із manifest-а, reparse
           point-ів немає; RUNTIME_MANIFEST.json присутній;
        3) з -CompareRuntimeRoot — живий runtime (за виключеннями з manifest-а)
           має ті самі ключі й хеші. Не кидає виняток.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ExpectedManifestSha256,
        [string]$CompareRuntimeRoot
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $fileCount = 0
    try {
        $loaded = Get-BRAVOUpdateBackupManifest -Path $ManifestPath
        foreach ($problem in @($loaded.Problems)) { [void]$problems.Add([string]$problem) }
        if ($null -ne $loaded.Sha256 -and -not [string]::Equals($loaded.Sha256, $ExpectedManifestSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$problems.Add('SHA-256 backup-manifest.json не збігається з очікуваним.')
        }

        if ($loaded.IsValid) {
            $manifest = $loaded.Manifest
            $expected = $loaded.Files
            $fileCount = $expected.Count
            $backupRuntime = [System.IO.Path]::Combine($BackupPath.TrimEnd('\', '/'), 'runtime')
            if (-not [System.IO.Directory]::Exists($backupRuntime)) {
                [void]$problems.Add('каталог runtime відсутній у резервній копії: ' + $backupRuntime)
            } else {
                $reparse = @(Find-BRAVOUpdateBackupReparsePoint -Root $backupRuntime)
                foreach ($item in $reparse) { [void]$problems.Add('reparse point у резервній копії: ' + $item) }
                if ($reparse.Count -eq 0) {
                    $actualKeys = @(Get-BRAVODeployTreeKeys -Root $backupRuntime)
                    $seen = @{}
                    foreach ($key in $actualKeys) {
                        $seen[$key] = $true
                        if (-not $expected.ContainsKey($key)) {
                            [void]$problems.Add('зайвий файл у резервній копії: ' + $key)
                            continue
                        }
                        $hash = $null
                        try {
                            $hash = Get-BRAVOUpdateBackupFileHash -Path (ConvertTo-BRAVOUpdateBackupFilePath -Root $backupRuntime -Key $key)
                        } catch {
                            [void]$problems.Add('не вдалося прочитати ' + $key + ': ' + $_.Exception.Message)
                            continue
                        }
                        if (-not [string]::Equals($hash, [string]$expected[$key], [System.StringComparison]::OrdinalIgnoreCase)) {
                            [void]$problems.Add('хеш не збігається з manifest: ' + $key)
                        }
                    }
                    foreach ($key in $expected.Keys) {
                        if (-not $seen.ContainsKey($key)) { [void]$problems.Add('відсутній файл у резервній копії: ' + $key) }
                    }
                }
            }
            if (-not $expected.ContainsKey('RUNTIME_MANIFEST.json')) {
                [void]$problems.Add('RUNTIME_MANIFEST.json відсутній у резервній копії.')
            }

            if (-not [string]::IsNullOrWhiteSpace($CompareRuntimeRoot)) {
                $excludeFiles = @($manifest.excludeFiles)
                $excludeDirs = @($manifest.excludeDirs)
                if (-not [System.IO.Directory]::Exists($CompareRuntimeRoot)) {
                    [void]$problems.Add('живий runtime не знайдено: ' + $CompareRuntimeRoot)
                } else {
                    $liveKeys = @(Get-BRAVODeployTreeKeys -Root $CompareRuntimeRoot -ExcludeFiles $excludeFiles -ExcludeDirs $excludeDirs)
                    $liveSeen = @{}
                    foreach ($key in $liveKeys) {
                        $liveSeen[$key] = $true
                        if (-not $expected.ContainsKey($key)) {
                            [void]$problems.Add('файл є в живому runtime, але не в резервній копії: ' + $key)
                            continue
                        }
                        try {
                            $hash = Get-BRAVOUpdateBackupFileHash -Path (ConvertTo-BRAVOUpdateBackupFilePath -Root $CompareRuntimeRoot -Key $key)
                            if (-not [string]::Equals($hash, [string]$expected[$key], [System.StringComparison]::OrdinalIgnoreCase)) {
                                [void]$problems.Add('живий runtime відрізняється від резервної копії: ' + $key)
                            }
                        } catch {
                            [void]$problems.Add('не вдалося прочитати живий ' + $key + ': ' + $_.Exception.Message)
                        }
                    }
                    foreach ($key in $expected.Keys) {
                        if (-not $liveSeen.ContainsKey($key)) { [void]$problems.Add('файл відсутній у живому runtime: ' + $key) }
                    }
                }
            }
        }
    } catch {
        [void]$problems.Add('перевірка резервної копії завершилась помилкою: ' + $_.Exception.Message)
    }

    return [pscustomobject]@{
        IsValid   = ($problems.Count -eq 0)
        Problems  = @($problems.ToArray())
        FileCount = $fileCount
    }
}

function New-BRAVORuntimeBackup {
    <#
    .SYNOPSIS
        Створює верифіковану резервну копію runtime у <BackupRoot>\<opId>\.
    .DESCRIPTION
        Не кидає виняток: збій = непорожній Problems (id у префіксі, напр.
        'Backup.ReparsePoint: ...') і ManifestPath = $null. Каталог операції
        після збою НЕ видаляється тут: компенсація (до mutation) —
        Remove-BRAVOUpdateOperationDirectory в orchestrator. Наявний каталог
        <BackupRoot>\<opId> = відмова без жодних змін.
        FaultInjection: 'Backup.AfterFileCount' = N кидає після N файлів
        (імітація збою посеред копіювання).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [hashtable]$FaultInjection
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $result = [ordered]@{ Path = $null; ManifestPath = $null; ManifestSha256 = $null; FileCount = 0; TotalBytes = [long]0; Problems = @() }
    $finish = {
        $result.Problems = @($problems.ToArray())
        if ($problems.Count -gt 0) { $result.ManifestPath = $null; $result.ManifestSha256 = $null }
        return [pscustomobject]$result
    }

    try {
        if (-not (Test-BRAVOUpdateBackupOperationId -OperationId $OperationId)) {
            [void]$problems.Add('Backup.OperationId: некоректний ідентифікатор операції.')
            return (& $finish)
        }
        if (-not [System.IO.Directory]::Exists($RuntimeRoot)) {
            [void]$problems.Add('Backup.RuntimeMissing: каталог runtime не знайдено: ' + $RuntimeRoot)
            return (& $finish)
        }
        $runtimeFull = [System.IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\', '/')
        $backupRootFull = [System.IO.Path]::GetFullPath($BackupRoot).TrimEnd('\', '/')
        # Бекап усередині runtime (або runtime усередині BackupRoot) зациклив би
        # копіювання / дозволив би Deploy зачепити власну резервну копію.
        if ((Test-BRAVOUpdatePathIsUnder -Path $backupRootFull -Root $runtimeFull -AllowEqual) -or
            (Test-BRAVOUpdatePathIsUnder -Path $runtimeFull -Root $backupRootFull -AllowEqual)) {
            [void]$problems.Add('Backup.Overlap: BackupRoot і RuntimeRoot не можуть містити один одного.')
            return (& $finish)
        }

        $operationPath = [System.IO.Path]::Combine($backupRootFull, $OperationId)
        if ([System.IO.Directory]::Exists($operationPath) -or [System.IO.File]::Exists($operationPath)) {
            [void]$problems.Add('Backup.AlreadyExists: резервна копія для цієї операції вже існує: ' + $operationPath)
            return (& $finish)
        }

        $siteOwned = Get-BRAVOUpdateSiteOwnedPaths
        $excludeFiles = @($siteOwned.Files)
        $excludeDirs = @($siteOwned.Dirs)

        # Reparse-перевірка ДО створення будь-чого на диску.
        $reparse = @(Find-BRAVOUpdateBackupReparsePoint -Root $runtimeFull -ExcludeFiles $excludeFiles -ExcludeDirs $excludeDirs)
        if ($reparse.Count -gt 0) {
            foreach ($item in $reparse) { [void]$problems.Add('Backup.ReparsePoint: ' + $item) }
            return (& $finish)
        }

        $directory = New-BRAVOUpdatePrivateDirectory -Path $operationPath
        if (-not $directory.Success) {
            foreach ($item in @($directory.Problems)) { [void]$problems.Add('Backup.PrivateDirectory: ' + [string]$item) }
            if ($problems.Count -eq 0) { [void]$problems.Add('Backup.PrivateDirectory: не вдалося створити каталог ' + $operationPath) }
            return (& $finish)
        }
        $result.Path = $operationPath
        $backupRuntime = [System.IO.Path]::Combine($operationPath, 'runtime')
        [void][System.IO.Directory]::CreateDirectory($backupRuntime)

        $keys = @(Get-BRAVODeployTreeKeys -Root $runtimeFull -ExcludeFiles $excludeFiles -ExcludeDirs $excludeDirs)
        $files = [ordered]@{}
        $total = [long]0
        $faultAfter = $null
        if ($null -ne $FaultInjection -and $FaultInjection.ContainsKey('Backup.AfterFileCount')) { $faultAfter = [int]$FaultInjection['Backup.AfterFileCount'] }
        $copied = 0
        foreach ($key in ($keys | Sort-Object)) {
            if ($null -ne $faultAfter -and $copied -ge $faultAfter) { throw ('Fault injection: Backup.AfterFileCount=' + $faultAfter) }
            $copy = Copy-BRAVOUpdateBackupFile -Source (ConvertTo-BRAVOUpdateBackupFilePath -Root $runtimeFull -Key $key) -Destination (ConvertTo-BRAVOUpdateBackupFilePath -Root $backupRuntime -Key $key)
            $files[$key] = $copy.Sha256
            $total += $copy.Length
            $copied++
        }
        $result.FileCount = $files.Count
        $result.TotalBytes = $total

        if (-not $files.Contains('RUNTIME_MANIFEST.json')) {
            [void]$problems.Add('Backup.RuntimeManifestMissing: RUNTIME_MANIFEST.json відсутній у runtime.')
            return (& $finish)
        }

        $manifest = [ordered]@{
            schemaVersion     = 1
            operationId       = $OperationId
            sourceRuntimeRoot = $runtimeFull
            createdUtc        = (Get-Date).ToUniversalTime().ToString('o')
            excludeFiles      = @($excludeFiles)
            excludeDirs       = @($excludeDirs)
            files             = $files
            fileCount         = $files.Count
            totalBytes        = $total
        }
        $manifestPath = [System.IO.Path]::Combine($operationPath, $script:BRAVOUpdateBackupManifestName)
        Write-BRAVOUpdateFileAtomic -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 10)
        $manifestSha = Get-BRAVOUpdateBackupFileHash -Path $manifestPath

        # Verify: хеш копії проти manifest-а І проти живого runtime (джерело
        # могло змінитися під час копіювання).
        $verify = Test-BRAVORuntimeBackup -BackupPath $operationPath -ManifestPath $manifestPath -ExpectedManifestSha256 $manifestSha -CompareRuntimeRoot $runtimeFull
        if (-not $verify.IsValid) {
            foreach ($item in @($verify.Problems)) { [void]$problems.Add('Backup.Verify: ' + [string]$item) }
            return (& $finish)
        }
        $result.ManifestPath = $manifestPath
        $result.ManifestSha256 = $manifestSha
    } catch {
        [void]$problems.Add('Backup.Error: ' + $_.Exception.Message)
    }
    return (& $finish)
}
