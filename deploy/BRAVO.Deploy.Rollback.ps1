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
    param([Parameter(Mandatory = $true)][string]$Path)
    return (($Path -replace '\\', '/').TrimStart('/'))
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
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs = @()
    )
    $keys = New-Object System.Collections.Generic.List[string]
    if (-not [System.IO.Directory]::Exists($Root)) { return @() }
    $prefix = $Root.TrimEnd('\', '/').Length + 1
    foreach ($full in [System.IO.Directory]::GetFiles($Root, '*', [System.IO.SearchOption]::AllDirectories)) {
        $key = ConvertTo-BRAVODeployRelativeKey -Path $full.Substring($prefix)
        if (Test-BRAVODeployPathExcluded -RelativeKey $key -ExcludeFiles $ExcludeFiles -ExcludeDirs $ExcludeDirs) { continue }
        [void]$keys.Add($key)
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
        $native = $key -replace '/', [System.IO.Path]::DirectorySeparatorChar
        $runtimeFile = $runtimeBase + [System.IO.Path]::DirectorySeparatorChar + $native
        $backupFile = $backupBase + [System.IO.Path]::DirectorySeparatorChar + $native
        try {
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
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )
    $expected = Get-BRAVODeployManifestHashes -ManifestPath $ManifestPath
    $problems = New-Object System.Collections.Generic.List[string]
    $base = $RuntimeRoot.TrimEnd('\', '/')
    foreach ($key in @($expected.Keys)) {
        $full = $base + [System.IO.Path]::DirectorySeparatorChar + ($key -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not [System.IO.File]::Exists($full)) { [void]$problems.Add('відсутній: ' + $key); continue }
        if ((Get-BRAVODeployFileSha256 -Path $full) -ne $expected[$key]) { [void]$problems.Add('змінено: ' + $key) }
    }
    $lookup = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in @($expected.Keys)) { [void]$lookup.Add($key) }
    foreach ($key in (Get-BRAVODeployTreeKeys -Root $RuntimeRoot)) {
        $ext = [System.IO.Path]::GetExtension($key).ToLowerInvariant()
        if (@('.ps1', '.psm1', '.psd1') -notcontains $ext) { continue }
        if ($key -match '^(LOGS|\.git|\.vscode|\.claude|local-backups)/') { continue }
        if (-not $lookup.Contains($key)) { [void]$problems.Add('сторонній скрипт: ' + $key) }
    }
    return [pscustomobject]@{ IsMatch = ($problems.Count -eq 0); Problems = @($problems.ToArray()) }
}
