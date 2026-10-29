# BRAVO.Update.Staging — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
# Безпечний staging пакета (INS-035): приватний каталог із захищеним DACL,
# перевірка ZIP до розпакування, власне розпакування entry-by-entry. Жодного
# виводу в консоль; Expand-Archive не використовується навмисно — він не
# перевіряє виходи за корінь (zip-slip), ADS і розмір.

function Test-BRAVOUpdatePathHasReparsePoint {
    # $true, якщо сам шлях або будь-який його предок (до -StopAt, виключно) є
    # reparse point (junction/symlink): через нього staging міг би вийти за
    # межі приватного каталогу. Неіснуючі елементи пропускаємо (піднімаємось
    # вище). Будь-яка інша помилка читання атрибутів -> $true (fail closed).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$StopAt
    )

    try {
        # Хвостовий '\' прибираємо лише не в корені диска: GetAttributes('C:')
        # без слеша означає поточний каталог диска, а не корінь.
        $current = [System.IO.Path]::GetFullPath($Path)
        if ($current.Length -gt [System.IO.Path]::GetPathRoot($current).Length) { $current = $current.TrimEnd('\') }
        $stop = $null
        if (-not [string]::IsNullOrWhiteSpace($StopAt)) {
            $stop = [System.IO.Path]::GetFullPath($StopAt)
            if ($stop.Length -gt [System.IO.Path]::GetPathRoot($stop).Length) { $stop = $stop.TrimEnd('\') }
        }
        while (-not [string]::IsNullOrEmpty($current)) {
            if ($null -ne $stop -and [string]::Equals($current, $stop, [System.StringComparison]::OrdinalIgnoreCase)) { break }
            $attributes = $null
            try {
                $attributes = [System.IO.File]::GetAttributes($current)
            } catch [System.IO.FileNotFoundException] {
                $attributes = $null
            } catch [System.IO.DirectoryNotFoundException] {
                $attributes = $null
            }
            if ($null -ne $attributes -and (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) { return $true }
            $parent = [System.IO.Path]::GetDirectoryName($current)
            if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) { break }
            $current = $parent
        }
        return $false
    } catch {
        return $true
    }
}

function Get-BRAVOUpdateDirectoryAclProblem {
    # Проблеми приватності каталогу (порожній масив = приватний): DACL
    # захищений; власник і КОЖЕН ACE (Allow чи Deny) належать лише довіреним
    # SID: BUILTIN\Administrators, NT AUTHORITY\SYSTEM, поточний користувач;
    # успадкованих правил немає. Помилка читання -> проблема (fail closed).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $problems = @()
    try {
        $trusted = @('S-1-5-32-544', 'S-1-5-18', [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $acl = Get-Acl -LiteralPath $Path
        if (-not $acl.AreAccessRulesProtected) { $problems += 'успадкування прав не вимкнено' }
        $ownerSid = [string]$acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($trusted -notcontains $ownerSid) { $problems += ('власник ' + $ownerSid + ' не з довіреного списку') }
        foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            $ruleSid = [string]$rule.IdentityReference.Value
            if ($rule.IsInherited) { $problems += ('успадковане правило ' + $ruleSid) }
            if ($trusted -notcontains $ruleSid) {
                $problems += ('ACE для недовіреного ' + $ruleSid + ' (' + [string]$rule.FileSystemRights + ')')
            }
        }
    } catch {
        $problems += ('ACL не прочитано: ' + $_.Exception.Message)
    }
    return @($problems)
}

function New-BRAVOUpdatePrivateDirectory {
    # Створює каталог із захищеним DACL (патерн
    # deploy\Install-BRAVOServer.ps1 New-BRAVOInstallPrivateDirectory, який
    # не змінюємо): успадкування вимкнено; FullControl лише для
    # BUILTIN\Administrators, NT AUTHORITY\SYSTEM і ПОТОЧНОГО користувача.
    # Поточний користувач у списку, щоб неелевовані тести й dry-run працювали;
    # у production worker запускається елевованим, тож поточний користувач =
    # адміністратор (або SYSTEM) і додатковий довірений принципал не з'являється.
    # Власника не міняємо (неелевований процес не може призначити
    # Administrators власником). Результат перечитується Get-Acl. Наявний
    # каталог допустимий лише порожній і не reparse point (тоді DACL
    # застосовується до нього); інакше — відмова. Повертає
    # { Success; Path; Problems[] }, не кидає виняток.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $problems = @()
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $exists = Test-Path -LiteralPath $fullPath
        if ($exists) {
            $item = Get-Item -LiteralPath $fullPath -Force
            if (-not $item.PSIsContainer) { throw 'шлях існує і не є каталогом.' }
            if (Test-BRAVOUpdatePathHasReparsePoint -Path $fullPath) { throw 'шлях є reparse point або має його серед предків.' }
            if (@(Get-ChildItem -LiteralPath $fullPath -Force).Count -gt 0) { throw 'каталог уже існує і не порожній.' }
        }

        $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $trustedSids = @($administratorsSid, $systemSid)
        if ($currentSid.Value -ne $administratorsSid.Value -and $currentSid.Value -ne $systemSid.Value) { $trustedSids += $currentSid }
        $allowedValues = @($trustedSids | ForEach-Object { $_.Value })

        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetAccessRuleProtection($true, $false)
        foreach ($trustedSid in $trustedSids) {
            $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $trustedSid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)))
        }
        if ($exists) {
            # Set-Acl тут не годиться: він записує всі секції дескриптора і
            # вимагає SeSecurityPrivilege (немає в неелевованому процесі).
            # Змінюємо лише DACL через DirectoryInfo.SetAccessControl.
            $directoryInfo = New-Object System.IO.DirectoryInfo($fullPath)
            $existingAcl = $directoryInfo.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
            $existingAcl.SetAccessRuleProtection($true, $false)
            foreach ($oldRule in @($existingAcl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
                [void]$existingAcl.RemoveAccessRuleSpecific($oldRule)
            }
            foreach ($newRule in @($security.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
                $existingAcl.AddAccessRule($newRule)
            }
            $directoryInfo.SetAccessControl($existingAcl)
        } else {
            # Windows PowerShell 5.1 (.NET Framework): Directory.CreateDirectory(path, DirectorySecurity);
            # PowerShell 7 (.NET): FileSystemAclExtensions.CreateDirectory.
            $createWithSecurity = [System.IO.Directory].GetMethod('CreateDirectory',
                [Type[]]@([string], [System.Security.AccessControl.DirectorySecurity]))
            if ($null -ne $createWithSecurity) {
                [void][System.IO.Directory]::CreateDirectory($fullPath, $security)
            } else {
                [void][System.IO.FileSystemAclExtensions]::CreateDirectory($security, $fullPath)
            }
        }

        $actual = Get-Acl -LiteralPath $fullPath
        if (-not $actual.AreAccessRulesProtected) { $problems += 'успадкування прав не вимкнено' }
        $ownerValue = [string]$actual.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($allowedValues -notcontains $ownerValue) { $problems += ('власник ' + $ownerValue + ' не з довіреного списку') }
        $rules = @($actual.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        foreach ($rule in $rules) {
            $ruleSid = [string]$rule.IdentityReference.Value
            if ($rule.IsInherited -or $allowedValues -notcontains $ruleSid -or
                $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
                ($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne [System.Security.AccessControl.FileSystemRights]::FullControl) {
                $problems += ('зайве правило ' + $ruleSid + ' ' + [string]$rule.AccessControlType + ' ' + [string]$rule.FileSystemRights)
            }
        }
        foreach ($allowedValue in $allowedValues) {
            if (@($rules | Where-Object { [string]$_.IdentityReference.Value -eq $allowedValue }).Count -eq 0) {
                $problems += ('немає правила для ' + $allowedValue)
            }
        }
        if (@(Get-ChildItem -LiteralPath $fullPath -Force).Count -gt 0) { $problems += 'каталог не порожній' }
        if ($problems.Count -gt 0) {
            # Створений нами каталог із хибним DACL не лишаємо.
            if (-not $exists) { Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction SilentlyContinue }
            return [pscustomobject]@{ Success = $false; Path = $fullPath; Problems = @($problems) }
        }
        return [pscustomobject]@{ Success = $true; Path = $fullPath; Problems = @() }
    } catch {
        $problems += ('Приватний каталог ' + $Path + ' не створено: ' + $_.Exception.Message)
        return [pscustomobject]@{ Success = $false; Path = $Path; Problems = @($problems) }
    }
}

function ConvertTo-BRAVOUpdateZipEntryPathProblem {
    # Перевіряє одне ім'я ZIP-entry; повертає масив проблем (порожній = ім'я
    # безпечне). Нормалізація: '\' -> '/'. Відхиляємо все, що Windows
    # трактує неоднозначно: кореневі/UNC/дискові шляхи, '..', ':' (ADS і
    # диск), недопустимі символи, сегменти з хвостовою крапкою/пробілом
    # (Windows їх мовчки обрізає -> аліас іншого імені), зарезервовані
    # імена пристроїв, вихід за корінь після нормалізації.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FullName,
        [Parameter(Mandatory = $true)][bool]$IsDirectory
    )

    $problems = @()
    $normalized = $FullName.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized.Trim('/'))) {
        if (-not $IsDirectory -or [string]::IsNullOrEmpty($normalized)) { return @('порожнє ім''я entry') }
        return @('кореневий шлях "' + $FullName + '"')
    }
    if ($normalized.StartsWith('/')) { $problems += 'кореневий або UNC шлях' }
    if ($normalized.Contains(':')) { $problems += 'містить ":" (диск або альтернативний потік)' }
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $reservedNames = @('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')
    $segments = @($normalized.Split('/'))
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $segment = [string]$segments[$index]
        if ($segment.Length -eq 0) {
            # Порожній сегмент дозволений лише як хвіст директорійного entry ('dir/').
            if ($index -eq ($segments.Count - 1) -and $IsDirectory) { continue }
            if ($index -eq 0) { continue } # уже відхилено як кореневий
            $problems += 'порожній сегмент шляху'
            continue
        }
        if ($segment -eq '..') { $problems += 'сегмент ".."'; continue }
        if ($segment -eq '.') { continue }
        if ($segment.IndexOfAny($invalidChars) -ge 0 -and -not $segment.Contains(':')) { $problems += ('недопустимі символи в "' + $segment + '"') }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) { $problems += ('сегмент "' + $segment + '" закінчується крапкою або пробілом') }
        $baseName = $segment.Split('.')[0].TrimEnd(' ').ToUpperInvariant()
        if ($reservedNames -contains $baseName) { $problems += ('зарезервоване ім''я пристрою "' + $segment + '"') }
    }
    if ($problems.Count -eq 0) {
        # Вихід за корінь після нормалізації: віртуальний корінь, файлову систему
        # GetFullPath не чіпає.
        try {
            $virtualRoot = 'Z:\bravo-staging-root\'
            $resolved = [System.IO.Path]::GetFullPath($virtualRoot + $normalized.Replace('/', '\'))
            if (-not $resolved.StartsWith($virtualRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $problems += 'шлях виходить за корінь' }
        } catch {
            $problems += ('шлях не нормалізується: ' + $_.Exception.Message)
        }
    }
    return @($problems)
}

function Test-BRAVOUpdateZipArchiveObject {
    # Перевіряє вже відкритий ZipArchive (щоб Expand перевіряв і розпаковував
    # ТОЙ САМИЙ handle: інакше між перевіркою і розпакуванням файл можна
    # підмінити — TOCTOU). Повертає { IsValid; Problems[]; Entries[]
    # {FullName; Length}; TotalUncompressedBytes }. Будь-яка помилка читання
    # архіва -> IsValid=$false (fail closed). Ліміти: розмір, кількість,
    # коефіцієнт стиснення (zip-bomb). Length у заголовку може брехати —
    # Expand-BRAVOUpdateArchiveSafe додатково обмежує фактично записане.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [long]$MaxTotalBytes = 2147483648,
        [int]$MaxEntries = 20000,
        [long]$RatioCheckMinBytes = 10485760,
        [int]$MaxCompressionRatio = 200
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $entries = New-Object System.Collections.Generic.List[object]
    $totalBytes = [long]0
    try {
        $zipEntries = New-Object System.Collections.Generic.List[object]
        foreach ($archiveEntry in $Archive.Entries) { $zipEntries.Add($archiveEntry) }
        if ($zipEntries.Count -gt $MaxEntries) {
            $problems.Add('забагато entry: ' + $zipEntries.Count + ' (ліміт ' + $MaxEntries + ')')
        } else {
            $seen = @{}
            foreach ($zipEntry in $zipEntries) {
                $name = [string]$zipEntry.FullName
                $isDirectory = ($name.EndsWith('/') -or $name.EndsWith('\'))
                $length = [long]$zipEntry.Length
                $entries.Add([pscustomobject]@{ FullName = $name; Length = $length })
                foreach ($pathProblem in @(ConvertTo-BRAVOUpdateZipEntryPathProblem -FullName $name -IsDirectory $isDirectory)) {
                    $problems.Add('entry "' + $name + '": ' + $pathProblem)
                }
                $key = $name.Replace('\', '/').TrimEnd('/').ToLowerInvariant()
                if ($seen.ContainsKey($key)) {
                    $problems.Add('дублікат імені (без урахування регістру): "' + $name + '"')
                } else {
                    $seen[$key] = $true
                }
                $totalBytes += $length
                if ($length -gt $RatioCheckMinBytes) {
                    $compressed = [long]$zipEntry.CompressedLength
                    if ($compressed -le 0 -or ($length / $compressed) -gt $MaxCompressionRatio) {
                        $problems.Add('підозрілий коефіцієнт стиснення (понад ' + $MaxCompressionRatio + ':1) для "' + $name + '"')
                    }
                }
            }
            if ($totalBytes -gt $MaxTotalBytes) {
                $problems.Add('сумарний розмір після розпакування ' + $totalBytes + ' байт перевищує ліміт ' + $MaxTotalBytes)
            }
        }
    } catch {
        $problems.Add('ZIP не вдалося прочитати: ' + $_.Exception.Message)
    }
    return [pscustomobject]@{
        IsValid                 = ($problems.Count -eq 0)
        Problems                = $problems.ToArray()
        Entries                 = $entries.ToArray()
        TotalUncompressedBytes  = $totalBytes
    }
}

function Test-BRAVOUpdateZipEntries {
    # Перевіряє ZIP за шляхом, нічого не розпаковуючи: файл відкривається
    # один раз із FileShare.Read (ніхто не може записати/видалити/підмінити
    # його, поки йде перевірка). Ліміти й правила імен — у
    # Test-BRAVOUpdateZipArchiveObject. Будь-яка помилка -> IsValid=$false.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [long]$MaxTotalBytes = 2147483648,
        [int]$MaxEntries = 20000,
        [long]$RatioCheckMinBytes = 10485760,
        [int]$MaxCompressionRatio = 200
    )

    $zipStream = $null
    $archive = $null
    try {
        Add-Type -AssemblyName System.IO.Compression
        $zipStream = New-Object System.IO.FileStream($ZipPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
        return (Test-BRAVOUpdateZipArchiveObject -Archive $archive -MaxTotalBytes $MaxTotalBytes -MaxEntries $MaxEntries -RatioCheckMinBytes $RatioCheckMinBytes -MaxCompressionRatio $MaxCompressionRatio)
    } catch {
        return [pscustomobject]@{
            IsValid                = $false
            Problems               = @('ZIP не вдалося прочитати: ' + $_.Exception.Message)
            Entries                = @()
            TotalUncompressedBytes = [long]0
        }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        if ($null -ne $zipStream) { $zipStream.Dispose() }
    }
}

function Remove-BRAVOUpdateCreatedStagingItem {
    # Відкат розпакування: видаляє лише файли й каталоги, створені цим
    # викликом (списки ведуться поштучно), каталоги — від найглибших.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Files,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Directories
    )
    foreach ($createdFile in $Files) {
        Remove-Item -LiteralPath $createdFile -Force -ErrorAction SilentlyContinue
    }
    foreach ($createdDirectory in @($Directories | Sort-Object -Property Length -Descending)) {
        Remove-Item -LiteralPath $createdDirectory -Force -ErrorAction SilentlyContinue
    }
}

function Expand-BRAVOUpdateArchiveSafe {
    # Безпечне розпакування ZIP у порожній приватний каталог. Порядок: SHA256
    # (якщо задано) -> перевірка entries -> перевірка призначення (існує,
    # не reparse point, порожній, DACL захищений = створений
    # New-BRAVOUpdatePrivateDirectory) -> entry-by-entry з перевіркою
    # повного шляху під коренем, без перезапису (CreateNew), без зміни ACL.
    # Фактично записані байти не можуть перевищити заявлений Length (захист
    # від брехливого заголовка). Будь-яка помилка -> видаляється лише те, що
    # створив цей виклик, Success=$false.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [string]$ExpectedSha256,
        [long]$MaxTotalBytes = 2147483648,
        [int]$MaxEntries = 20000
    )

    $createdFiles = New-Object System.Collections.Generic.List[string]
    $createdDirectories = New-Object System.Collections.Generic.List[string]
    $archive = $null
    $zipStream = $null
    $rootFull = $DestinationRoot
    $fileCount = 0
    try {
        # ZIP відкривається ОДИН раз із FileShare.Read (без write/delete): цей
        # handle живе крізь SHA256, перевірку entries і розпакування над тим
        # самим потоком — підміна файла між кроками неможлива (TOCTOU).
        Add-Type -AssemblyName System.IO.Compression
        $zipStream = New-Object System.IO.FileStream($ZipPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
            $hasher = [System.Security.Cryptography.SHA256]::Create()
            try {
                $actualHash = ([System.BitConverter]::ToString($hasher.ComputeHash($zipStream))).Replace('-', '')
            } finally {
                $hasher.Dispose()
            }
            $zipStream.Position = 0
            if (-not [string]::Equals($actualHash, $ExpectedSha256.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
                throw ('SHA256 архіва не збігається з очікуваним (' + $actualHash + ').')
            }
        }
        $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
        $validation = Test-BRAVOUpdateZipArchiveObject -Archive $archive -MaxTotalBytes $MaxTotalBytes -MaxEntries $MaxEntries
        if (-not $validation.IsValid) {
            return [pscustomobject]@{ Success = $false; Problems = @($validation.Problems); FileCount = 0; Root = $DestinationRoot }
        }

        $rootFull = [System.IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { throw 'каталог призначення не існує (створіть New-BRAVOUpdatePrivateDirectory).' }
        if (Test-BRAVOUpdatePathHasReparsePoint -Path $rootFull) { throw 'каталог призначення є reparse point або має його серед предків.' }
        if (@(Get-ChildItem -LiteralPath $rootFull -Force).Count -gt 0) { throw 'каталог призначення не порожній.' }
        # Захищений DACL сам по собі не доказ приватності (явний ACE для
        # Users/Everyone на порожньому каталозі проходить): кожен ACE і
        # власник мають бути лише з довіреного списку.
        $aclProblems = @(Get-BRAVOUpdateDirectoryAclProblem -Path $rootFull)
        if ($aclProblems.Count -gt 0) { throw ('каталог призначення не приватний: ' + ($aclProblems -join '; ')) }
        $rootPrefix = $rootFull + '\'

        foreach ($zipEntry in $archive.Entries) {
            $name = [string]$zipEntry.FullName
            $isDirectory = ($name.EndsWith('/') -or $name.EndsWith('\'))
            $relative = $name.Replace('/', '\').TrimEnd('\')
            $target = [System.IO.Path]::GetFullPath((Join-Path $rootFull $relative))
            if (-not $target.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw ('entry "' + $name + '" виходить за корінь розпакування.')
            }
            # Недостаючі каталоги-предки, створені цим викликом: збираємо знизу
            # вгору, реєструємо зверху вниз для відкату.
            $directoryToEnsure = $target
            if (-not $isDirectory) { $directoryToEnsure = Split-Path -Parent $target }
            $missing = New-Object System.Collections.Generic.List[string]
            $probe = $directoryToEnsure
            while ($probe.Length -gt $rootFull.Length -and -not (Test-Path -LiteralPath $probe)) {
                $missing.Insert(0, $probe)
                $probe = Split-Path -Parent $probe
            }
            foreach ($missingDirectory in $missing) {
                [void][System.IO.Directory]::CreateDirectory($missingDirectory)
                $createdDirectories.Add($missingDirectory)
            }
            # Інший користувач міг підмінити щойно створений підкаталог на
            # junction між кроками: перед записом перевіряємо ланцюг від
            # каталогу entry до кореня (корінь уже перевірено).
            if (Test-BRAVOUpdatePathHasReparsePoint -Path $directoryToEnsure -StopAt $rootFull) {
                throw ('entry "' + $name + '": каталог призначення став reparse point.')
            }
            if ($isDirectory) { continue }

            $entryStream = $zipEntry.Open()
            try {
                # CreateNew: наявний файл -> виняток, перезапису немає.
                $output = New-Object System.IO.FileStream($target, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $createdFiles.Add($target)
                try {
                    $buffer = New-Object byte[] 81920
                    $written = [long]0
                    while (($read = $entryStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $written += $read
                        if ($written -gt [long]$zipEntry.Length) { throw ('entry "' + $name + '" більший за заявлений розмір.') }
                        $output.Write($buffer, 0, $read)
                    }
                    if ($written -ne [long]$zipEntry.Length) { throw ('entry "' + $name + '" коротший за заявлений розмір.') }
                } finally {
                    $output.Dispose()
                }
            } finally {
                $entryStream.Dispose()
            }
            $fileCount++
        }
        return [pscustomobject]@{ Success = $true; Problems = @(); FileCount = $fileCount; Root = $rootFull }
    } catch {
        if ($null -ne $archive) { $archive.Dispose(); $archive = $null }
        if ($null -ne $zipStream) { $zipStream.Dispose(); $zipStream = $null }
        Remove-BRAVOUpdateCreatedStagingItem -Files $createdFiles.ToArray() -Directories $createdDirectories.ToArray()
        return [pscustomobject]@{ Success = $false; Problems = @('Розпакування скасовано: ' + $_.Exception.Message); FileCount = 0; Root = $rootFull }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        if ($null -ne $zipStream) { $zipStream.Dispose() }
    }
}

function Get-BRAVOUpdateDirectorySize {
    # Сума розмірів файлів каталогу в байтах без проходу по reparse point
    # (junction/symlink не рахуємо й не заходимо — інакше можна порахувати
    # чужий том або зациклитись). Помилка читання — виняток: заниження
    # розміру небезпечне для перевірки вільного місця.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $total = [long]0
    $pending = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $pending.Push((New-Object System.IO.DirectoryInfo([System.IO.Path]::GetFullPath($Path))))
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($child in $directory.GetFileSystemInfos()) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if (($child.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $pending.Push((New-Object System.IO.DirectoryInfo($child.FullName)))
            } else {
                $total += ([System.IO.FileInfo]$child).Length
            }
        }
    }
    return $total
}

function Get-BRAVOUpdateFreeSpace {
    # Вільне місце на томі шляху: DriveInfo кореня повного шляху. UNC-корінь
    # DriveInfo не підтримує -> AvailableFreeBytes=$null і Error (викликач
    # трактує як «невідомо» = blocker). Не кидає виняток.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $volume = $null
    try {
        $volume = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        if ([string]::IsNullOrWhiteSpace($volume) -or $volume.StartsWith('\\')) { throw 'том не визначено або це UNC-шлях.' }
        $driveInfo = New-Object System.IO.DriveInfo($volume)
        return [pscustomobject]@{ Volume = $volume; AvailableFreeBytes = [long]$driveInfo.AvailableFreeSpace; Error = $null }
    } catch {
        return [pscustomobject]@{ Volume = $volume; AvailableFreeBytes = $null; Error = $_.Exception.Message }
    }
}
