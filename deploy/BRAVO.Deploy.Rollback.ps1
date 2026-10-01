# Канонічна логіка точного відкату для deploy\Update-BRAVOServer.ps1 (#289).
#
# ПРОБЛЕМА, ЯКУ ВОНА ЗАКРИВАЄ. Розгортання копіює комплект ПОВЕРХ runtime без
# видалення, а відкат раніше копіював backup ПОВЕРХ runtime теж без видалення.
# Файли, які додав новий реліз, лишалися після "відкату", а відновлений старий
# RUNTIME_MANIFEST.json їх не знає: BRAVO_RUNTIME_GUARD бачив "сторонні скрипти
# в комплекті" і блокував Archive/Maintenance/Health/DataRestore кодом 33.
#
# ІНВАРІАНТ. Після відкату runtime == попередній реліз для ВСІХ файлів, якими
# володіє розгортання. Власність визначається тим самим контрактом, що й
# розгортання, а не окремим списком:
#   owned = файли staged-комплекту (те, що копіює розгортання)
#         ∪ ключі нового RUNTIME_MANIFEST.json (staged)
#         ∪ ключі старого RUNTIME_MANIFEST.json (backup)
#   мінус виключення розгортання (-ExcludeFiles / -ExcludeDirs: BRAVO.config,
#   BRAVO.local.config, LOGS, MODEL, ... — стан оператора й сервера).
# Для кожного owned-шляху: є в backup -> відновлюється байт-у-байт; немає в
# backup -> видаляється (його додав новий реліз). Усе поза owned (LOGS,
# site-файли, дані, довільні файли оператора) не читається й не змінюється.
#
# Файл без robocopy навмисно: набір файлів — чиста PowerShell-логіка, яку
# self-test виконує на будь-якій ОС.

Set-StrictMode -Version 2.0

function ConvertTo-BRAVODeployRelativeKey {
    # Ключ манифесту = ДАНІ (staged/backup), а на його основі виконується
    # видалення й копіювання. Тому небезпечні форми відхиляються ГУЧНО (виняток,
    # а не мовчазний пропуск): кореневі (\x, /x), диск (C:\x), UNC (\\srv\share\x),
    # сегменти '..' і '.', порожній ключ.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Небезпечний шлях у manifest: порожній ключ' }
    if ($Path -match '^[\\/]' -or $Path -match '^[A-Za-z]:' -or $Path.Contains(':')) {
        throw ('Небезпечний шлях у manifest (кореневий, диск або UNC): ' + $Path)
    }
    $key = ($Path -replace '\\', '/')
    foreach ($segment in @($key -split '/')) {
        if ($segment -eq '..' -or $segment -eq '.' -or $segment.Length -eq 0) {
            throw ('Небезпечний шлях у manifest (сегмент ''' + $segment + '''): ' + $Path)
        }
    }
    return $key
}

function Resolve-BRAVODeployTargetPath {
    # Друга лінія захисту: повний шлях мусить лишатися під коренем
    # (Windows-семантика: без урахування регістру).
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $rootFull = [System.IO.Path]::GetFullPath($Root.TrimEnd('\', '/'))
    $full = [System.IO.Path]::GetFullPath($rootFull + $sep + ($Key -replace '/', $sep))
    if (-not $full.StartsWith($rootFull + $sep, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('Шлях виходить за межі ' + $rootFull + ': ' + $Key)
    }
    return $full
}

function Test-BRAVODeployPathExcluded {
    # Семантика robocopy /XF /XD: ім'я файлу збігається на будь-якій глибині,
    # ім'я каталогу — теж на будь-якій глибині.
    param(
        [Parameter(Mandatory = $true)][string]$RelativeKey,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs = @()
    )
    $segments = @($RelativeKey -split '/')
    $leaf = $segments[$segments.Count - 1]
    foreach ($name in @($ExcludeFiles)) {
        if ([string]::Equals($leaf, $name, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    for ($i = 0; $i -lt ($segments.Count - 1); $i++) {
        foreach ($name in @($ExcludeDirs)) {
            if ([string]::Equals($segments[$i], $name, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

function Get-BRAVODeployTreeKeys {
    # Обхід пропускає виключені каталоги ЦІЛКОМ (не заходить у LOGS/MODEL/BAZA...):
    # величезне або недоступне дерево даних не має ні гальмувати, ні валити відкат.
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs = @()
    )
    $keys = New-Object System.Collections.Generic.List[string]
    if (-not [System.IO.Directory]::Exists($Root)) { return @() }
    $prefix = $Root.TrimEnd('\', '/').Length + 1
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root.TrimEnd('\', '/'))
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($sub in [System.IO.Directory]::GetDirectories($dir)) {
            $name = [System.IO.Path]::GetFileName($sub)
            $skip = $false
            foreach ($ex in @($ExcludeDirs)) {
                if ([string]::Equals($name, $ex, [StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
            }
            if (-not $skip) { $stack.Push($sub) }
        }
        foreach ($full in [System.IO.Directory]::GetFiles($dir)) {
            $key = ($full.Substring($prefix) -replace '\\', '/')
            if (Test-BRAVODeployPathExcluded -RelativeKey $key -ExcludeFiles $ExcludeFiles -ExcludeDirs $ExcludeDirs) { continue }
            [void]$keys.Add($key)
        }
    }
    return @($keys.ToArray())
}

function Get-BRAVODeployManifestHashes {
    # Повертає hashtable key(з '/') -> SHA-256. Помилка читання = виняток:
    # без манифесту точний відкат неможливо верифікувати.
    param([Parameter(Mandatory = $true)][string]$ManifestPath)
    if (-not [System.IO.File]::Exists($ManifestPath)) {
        throw ('RUNTIME_MANIFEST.json не знайдено: ' + $ManifestPath)
    }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $filesProperty = $manifest.PSObject.Properties['files']
    if ($null -eq $filesProperty -or $null -eq $filesProperty.Value) {
        throw ('RUNTIME_MANIFEST.json без розділу files: ' + $ManifestPath)
    }
    $result = @{}
    foreach ($property in $filesProperty.Value.PSObject.Properties) {
        $result[(ConvertTo-BRAVODeployRelativeKey -Path $property.Name)] = ([string]$property.Value).ToUpperInvariant()
    }
    return $result
}

function Get-BRAVODeployFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToUpperInvariant()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function Get-BRAVODeployOwnedKeys {
    param(
        [Parameter(Mandatory = $true)][string]$StagedRoot,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs = @()
    )
    $owned = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in (Get-BRAVODeployTreeKeys -Root $StagedRoot -ExcludeFiles $ExcludeFiles -ExcludeDirs $ExcludeDirs)) {
        [void]$owned.Add($k)
    }
    foreach ($manifestPath in @((Join-Path $StagedRoot 'RUNTIME_MANIFEST.json'),
                                (Join-Path $BackupRoot 'RUNTIME_MANIFEST.json'))) {
        if (-not [System.IO.File]::Exists($manifestPath)) { continue }
        foreach ($k in @((Get-BRAVODeployManifestHashes -ManifestPath $manifestPath).Keys)) {
            if (Test-BRAVODeployPathExcluded -RelativeKey $k -ExcludeFiles $ExcludeFiles -ExcludeDirs $ExcludeDirs) { continue }
            [void]$owned.Add($k)
        }
    }
    return @($owned)
}

function Invoke-BRAVODeployExactRestore {
    # Точне відновлення owned-набору з backup. Повертає звіт; Errors не порожній
    # = відкат НЕ вдався (викликач мусить зупинитися гучно).
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$StagedRoot,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs = @()
    )
    $restored = New-Object System.Collections.Generic.List[string]
    $removed = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    $runtimeBase = $RuntimeRoot.TrimEnd('\', '/')
    $backupBase = $BackupRoot.TrimEnd('\', '/')

    $owned = @(Get-BRAVODeployOwnedKeys -StagedRoot $StagedRoot -BackupRoot $BackupRoot `
        -ExcludeFiles $ExcludeFiles -ExcludeDirs $ExcludeDirs)

    foreach ($key in $owned) {
        try {
            $runtimeFile = Resolve-BRAVODeployTargetPath -Root $runtimeBase -Key $key
            $backupFile = Resolve-BRAVODeployTargetPath -Root $backupBase -Key $key
            if ([System.IO.File]::Exists($backupFile)) {
                $needCopy = $true
                if ([System.IO.File]::Exists($runtimeFile)) {
                    $needCopy = ((Get-BRAVODeployFileSha256 -Path $runtimeFile) -ne (Get-BRAVODeployFileSha256 -Path $backupFile))
                }
                if ($needCopy) {
                    $dir = [System.IO.Path]::GetDirectoryName($runtimeFile)
                    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
                    [System.IO.File]::Copy($backupFile, $runtimeFile, $true)
                    [void]$restored.Add($key)
                }
            } elseif ([System.IO.File]::Exists($runtimeFile)) {
                [System.IO.File]::Delete($runtimeFile)
                [void]$removed.Add($key)
                # Каталог, спорожнілий видаленням, прибираємо; непорожній не чіпаємо.
                $dir = [System.IO.Path]::GetDirectoryName($runtimeFile)
                while ($dir.Length -gt $runtimeBase.Length -and [System.IO.Directory]::Exists($dir) -and
                       (@([System.IO.Directory]::GetFileSystemEntries($dir)).Count -eq 0)) {
                    [System.IO.Directory]::Delete($dir)
                    $dir = [System.IO.Path]::GetDirectoryName($dir)
                }
            }
        } catch {
            [void]$errors.Add($key + ': ' + $_.Exception.Message)
        }
    }

    return [pscustomobject]@{
        OwnedCount = $owned.Count
        Restored   = @($restored.ToArray())
        Removed    = @($removed.ToArray())
        Errors     = @($errors.ToArray())
    }
}

function Test-BRAVODeployRuntimeMatchesManifest {
    # Верифікація відкату: кожен ключ старого манифесту присутній з тим самим
    # SHA-256, і немає жодного .ps1/.psm1/.psd1 поза манифестом (той самий
    # критерій, що в BRAVO_RUNTIME_GUARD). Це перевірка ДЗЕРКАЛА, а не лише
    # коду виходу guard.
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [string[]]$ExcludeDirs = @()
    )
    $expected = Get-BRAVODeployManifestHashes -ManifestPath $ManifestPath
    $problems = New-Object System.Collections.Generic.List[string]
    $base = $RuntimeRoot.TrimEnd('\', '/')
    foreach ($key in @($expected.Keys)) {
        $full = Resolve-BRAVODeployTargetPath -Root $base -Key $key
        if (-not [System.IO.File]::Exists($full)) { [void]$problems.Add('відсутній: ' + $key); continue }
        if ((Get-BRAVODeployFileSha256 -Path $full) -ne $expected[$key]) { [void]$problems.Add('змінено: ' + $key) }
    }
    $lookup = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in @($expected.Keys)) { [void]$lookup.Add($key) }
    foreach ($key in (Get-BRAVODeployTreeKeys -Root $RuntimeRoot -ExcludeDirs $ExcludeDirs)) {
        $ext = [System.IO.Path]::GetExtension($key).ToLowerInvariant()
        if (@('.ps1', '.psm1', '.psd1') -notcontains $ext) { continue }
        if ($key -match '^(LOGS|\.git|\.vscode|\.claude|local-backups)/') { continue }
        if (-not $lookup.Contains($key)) { [void]$problems.Add('сторонній скрипт: ' + $key) }
    }
    return [pscustomobject]@{ IsMatch = ($problems.Count -eq 0); Problems = @($problems.ToArray()) }
}
