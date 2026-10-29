# Suite UpdateBackup: верифікована резервна копія runtime BRAVO.Update (INS-043).
# Фрагмент dot-source-иться з BRAVO_SELF_TEST.ps1 ($root заданий).

Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking

$updBackupTempPrefix = Join-Path ([System.IO.Path]::GetTempPath()) ('bravo-updbak-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $updBackupTempPrefix -Force)

# Пише текстовий файл (UTF-8 без BOM), створюючи каталоги.
function New-UpdBackupTestFile {
    param([string]$Path, [string]$Text)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

# Хеш усього дерева (ключ=вміст) для доказу "runtime не змінено".
function Get-UpdBackupTreeDigest {
    param([string]$Root)
    $lines = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Sort-Object FullName)) {
        $lines += ($file.FullName.Substring($Root.Length) + '=' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)
    }
    return ($lines -join "`n")
}

# Нове sandbox-середовище: runtime з типовим набором файлів.
function New-UpdBackupTestEnvironment {
    param([string]$Name, [switch]$Empty, [switch]$OnlyManifest)
    $base = Join-Path $updBackupTempPrefix $Name
    $runtime = Join-Path $base 'Program Files Каталог\BRAVO'
    [void](New-Item -ItemType Directory -Path $runtime -Force)
    if (-not $Empty) {
        New-UpdBackupTestFile -Path (Join-Path $runtime 'RUNTIME_MANIFEST.json') -Text '{"files":{}}'
        if (-not $OnlyManifest) {
            New-UpdBackupTestFile -Path (Join-Path $runtime 'VERSION.json') -Text '{"packageVersion":"1.0.0"}'
            New-UpdBackupTestFile -Path (Join-Path $runtime 'BRAVO_TEST.ps1') -Text 'Write-Output 1'
            New-UpdBackupTestFile -Path (Join-Path $runtime 'модулі з пробілом\файл один.txt') -Text 'Кирилиця й пробіли'
            New-UpdBackupTestFile -Path (Join-Path $runtime 'deploy\nested\deep.txt') -Text 'deep'
            # Site-owned: не мають потрапити в backup.
            New-UpdBackupTestFile -Path (Join-Path $runtime 'BRAVO.local.config') -Text 'site'
            New-UpdBackupTestFile -Path (Join-Path $runtime 'LOGS\a.log') -Text 'log'
            New-UpdBackupTestFile -Path (Join-Path $runtime 'BAZA\data.bin') -Text 'data'
            New-UpdBackupTestFile -Path (Join-Path $runtime 'deploy\LOGS\inner.log') -Text 'inner'
        }
    }
    return [pscustomobject]@{ Base = $base; Runtime = $runtime; BackupRoot = (Join-Path $base 'Backup Копії') }
}

try {
    # --- 1 файл (лише RUNTIME_MANIFEST.json) --------------------------------
    & {
        $env1 = New-UpdBackupTestEnvironment -Name 'one' -OnlyManifest
        $opId = [guid]::NewGuid().ToString()
        $backup = New-BRAVORuntimeBackup -RuntimeRoot $env1.Runtime -BackupRoot $env1.BackupRoot -OperationId $opId
        Test-BRAVOCondition -Condition ($backup.Problems.Count -eq 0 -and $backup.FileCount -eq 1 -and $backup.TotalBytes -gt 0) -Name 'UpdateBackup/OneFile' -Failure ('1 файл: Problems=' + ($backup.Problems -join '; '))
        Test-BRAVOCondition -Condition ($backup.ManifestSha256 -cmatch '^[0-9A-F]{64}$' -and (Test-Path -LiteralPath $backup.ManifestPath)) -Name 'UpdateBackup/OneFileManifest' -Failure 'manifest має існувати, SHA-256 UPPER'
    }

    # --- 0 файлів -------------------------------------------------------------
    & {
        $env0 = New-UpdBackupTestEnvironment -Name 'zero' -Empty
        $backup = New-BRAVORuntimeBackup -RuntimeRoot $env0.Runtime -BackupRoot $env0.BackupRoot -OperationId 'op-zero'
        Test-BRAVOCondition -Condition ($backup.Problems.Count -gt 0 -and $null -eq $backup.ManifestPath -and $backup.FileCount -eq 0) -Name 'UpdateBackup/ZeroFilesRejected' -Failure 'порожній runtime без RUNTIME_MANIFEST.json має дати помилку'
        $missing = New-BRAVORuntimeBackup -RuntimeRoot (Join-Path $env0.Base 'немає такого') -BackupRoot $env0.BackupRoot -OperationId 'op-missing'
        Test-BRAVOCondition -Condition ($missing.Problems.Count -gt 0 -and ($missing.Problems -join ' ') -match 'Backup\.RuntimeMissing') -Name 'UpdateBackup/RuntimeMissing' -Failure 'відсутній runtime -> Backup.RuntimeMissing'
    }

    # --- N файлів, виключення, кирилиця, пробіли, незмінність runtime ---------
    & {
        $envN = New-UpdBackupTestEnvironment -Name 'many'
        $before = Get-UpdBackupTreeDigest -Root $envN.Runtime
        $opId = [guid]::NewGuid().ToString()
        $backup = New-BRAVORuntimeBackup -RuntimeRoot $envN.Runtime -BackupRoot $envN.BackupRoot -OperationId $opId
        Test-BRAVOCondition -Condition ($backup.Problems.Count -eq 0) -Name 'UpdateBackup/ManyFilesOk' -Failure ('Problems=' + ($backup.Problems -join '; '))
        Test-BRAVOCondition -Condition ($backup.FileCount -eq 5) -Name 'UpdateBackup/ManyFilesCount' -Failure ('очікувано 5 файлів, є ' + $backup.FileCount)
        Test-BRAVOCondition -Condition ((Get-UpdBackupTreeDigest -Root $envN.Runtime) -ceq $before) -Name 'UpdateBackup/RuntimeUnchanged' -Failure 'runtime не має змінюватися'
        Test-BRAVOCondition -Condition ($backup.Path -eq (Join-Path ([System.IO.Path]::GetFullPath($envN.BackupRoot)) $opId)) -Name 'UpdateBackup/PathLayout' -Failure 'Path має бути <BackupRoot>\<opId>'

        $copyRoot = Join-Path $backup.Path 'runtime'
        Test-BRAVOCondition -Condition (Test-Path -LiteralPath (Join-Path $copyRoot 'модулі з пробілом\файл один.txt')) -Name 'UpdateBackup/CyrillicSpacesCopied' -Failure 'файл із кирилицею й пробілами має бути в копії'
        Test-BRAVOCondition -Condition (-not (Test-Path -LiteralPath (Join-Path $copyRoot 'LOGS')) -and -not (Test-Path -LiteralPath (Join-Path $copyRoot 'BAZA')) -and -not (Test-Path -LiteralPath (Join-Path $copyRoot 'deploy\LOGS')) -and -not (Test-Path -LiteralPath (Join-Path $copyRoot 'BRAVO.local.config'))) -Name 'UpdateBackup/ExcludedNotCopied' -Failure 'site-owned каталоги й файли не мають бути в копії (на будь-якій глибині)'

        $loaded = Get-BRAVOUpdateBackupManifest -Path $backup.ManifestPath
        Test-BRAVOCondition -Condition ($loaded.IsValid -and $loaded.Sha256 -ceq $backup.ManifestSha256 -and $loaded.Files.Count -eq 5) -Name 'UpdateBackup/ManifestReadable' -Failure ('manifest має читатися: ' + ($loaded.Problems -join '; '))
        Test-BRAVOCondition -Condition ($loaded.Files.ContainsKey('модулі з пробілом/файл один.txt') -and $loaded.Files.ContainsKey('deploy/nested/deep.txt') -and -not $loaded.Files.ContainsKey('LOGS/a.log')) -Name 'UpdateBackup/ManifestKeys' -Failure 'ключі з ''/'' і без виключених'
        $siteOwned = Get-BRAVOUpdateSiteOwnedPaths
        Test-BRAVOCondition -Condition ((@($loaded.Manifest.excludeFiles) -join '|') -ceq (@($siteOwned.Files) -join '|') -and (@($loaded.Manifest.excludeDirs) -join '|') -ceq (@($siteOwned.Dirs) -join '|')) -Name 'UpdateBackup/ExclusionsFromSiteOwned' -Failure 'excludeFiles/excludeDirs мають збігатися з Get-BRAVOUpdateSiteOwnedPaths'

        $valid = Test-BRAVORuntimeBackup -BackupPath $backup.Path -ManifestPath $backup.ManifestPath -ExpectedManifestSha256 $backup.ManifestSha256 -CompareRuntimeRoot $envN.Runtime
        Test-BRAVOCondition -Condition ($valid.IsValid -and $valid.FileCount -eq 5 -and $valid.Problems.Count -eq 0) -Name 'UpdateBackup/TestValid' -Failure ('Problems=' + ($valid.Problems -join '; '))

        # Живий runtime змінився -> порівняння виявляє.
        New-UpdBackupTestFile -Path (Join-Path $envN.Runtime 'VERSION.json') -Text '{"packageVersion":"2.0.0"}'
        $live = Test-BRAVORuntimeBackup -BackupPath $backup.Path -ManifestPath $backup.ManifestPath -ExpectedManifestSha256 $backup.ManifestSha256 -CompareRuntimeRoot $envN.Runtime
        Test-BRAVOCondition -Condition (-not $live.IsValid) -Name 'UpdateBackup/LiveDiffDetected' -Failure 'зміна живого runtime має давати IsValid=$false з -CompareRuntimeRoot'
        $liveNoCompare = Test-BRAVORuntimeBackup -BackupPath $backup.Path -ManifestPath $backup.ManifestPath -ExpectedManifestSha256 $backup.ManifestSha256
        Test-BRAVOCondition -Condition ($liveNoCompare.IsValid) -Name 'UpdateBackup/LiveIgnoredWithoutCompare' -Failure 'без -CompareRuntimeRoot живий runtime не перевіряється'

        # Новий файл у живому runtime -> теж розбіжність.
        New-UpdBackupTestFile -Path (Join-Path $envN.Runtime 'new_file.txt') -Text 'x'
        $liveExtra = Test-BRAVORuntimeBackup -BackupPath $backup.Path -ManifestPath $backup.ManifestPath -ExpectedManifestSha256 $backup.ManifestSha256 -CompareRuntimeRoot $envN.Runtime
        Test-BRAVOCondition -Condition (-not $liveExtra.IsValid -and ($liveExtra.Problems -join ' ') -match 'new_file\.txt') -Name 'UpdateBackup/LiveExtraFileDetected' -Failure 'зайвий живий файл має бути у Problems'
    }

    # --- Підміна в backup / manifest -----------------------------------------
    & {
        $envT = New-UpdBackupTestEnvironment -Name 'tamper'
        $backup = New-BRAVORuntimeBackup -RuntimeRoot $envT.Runtime -BackupRoot $envT.BackupRoot -OperationId 'op-tamper'
        $copyRoot = Join-Path $backup.Path 'runtime'
        $target = Join-Path $copyRoot 'BRAVO_TEST.ps1'
        $original = [System.IO.File]::ReadAllText($target)

        [System.IO.File]::WriteAllText($target, 'Write-Output 2')
        $tampered = Test-BRAVORuntimeBackup -BackupPath $backup.Path -ManifestPath $backup.ManifestPath -ExpectedManifestSha256 $backup.ManifestSha256
        Test-BRAVOCondition -Condition (-not $tampered.IsValid -and ($tampered.Problems -join ' ') -match 'BRAVO_TEST\.ps1') -Name 'UpdateBackup/TamperedFileDetected' -Failure 'підміна файла в backup -> IsValid=$false'
        [System.IO.File]::WriteAllText($target, $original)

        New-UpdBackupTestFile -Path (Join-Path $copyRoot 'planted.ps1') -Text 'evil'
        $extra = Test-BRAVORuntimeBackup -BackupPath $backup.Path -ManifestPath $backup.ManifestPath -ExpectedManifestSha256 $backup.ManifestSha256
        Test-BRAVOCondition -Condition (-not $extra.IsValid -and ($extra.Problems -join ' ') -match 'planted\.ps1') -Name 'UpdateBackup/ExtraFileDetected' -Failure 'зайвий файл у backup -> IsValid=$false'
        Remove-Item -LiteralPath (Join-Path $copyRoot 'planted.ps1') -Force

        Remove-Item -LiteralPath (Join-Path $copyRoot 'VERSION.json') -Force
        $missing = Test-BRAVORuntimeBackup -BackupPath $backup.Path -ManifestPath $backup.ManifestPath -ExpectedManifestSha256 $backup.ManifestSha256
        Test-BRAVOCondition -Condition (-not $missing.IsValid -and ($missing.Problems -join ' ') -match 'VERSION\.json') -Name 'UpdateBackup/MissingFileDetected' -Failure 'відсутній файл у backup -> IsValid=$false'
        New-UpdBackupTestFile -Path (Join-Path $copyRoot 'VERSION.json') -Text '{"packageVersion":"1.0.0"}'

        $wrongSha = Test-BRAVORuntimeBackup -BackupPath $backup.Path -ManifestPath $backup.ManifestPath -ExpectedManifestSha256 ('A' * 64)
        Test-BRAVOCondition -Condition (-not $wrongSha.IsValid) -Name 'UpdateBackup/WrongManifestShaDetected' -Failure 'невірний очікуваний SHA-256 manifest-а -> IsValid=$false'

        # Підміна manifest-а разом із хешем файла: очікуваний SHA із журналу відсікає.
        $manifestText = [System.IO.File]::ReadAllText($backup.ManifestPath)
        [System.IO.File]::WriteAllText($backup.ManifestPath, $manifestText.Replace('"fileCount":', '"fileCount" :'))
        $manifestTampered = Test-BRAVORuntimeBackup -BackupPath $backup.Path -ManifestPath $backup.ManifestPath -ExpectedManifestSha256 $backup.ManifestSha256
        Test-BRAVOCondition -Condition (-not $manifestTampered.IsValid) -Name 'UpdateBackup/ManifestTamperDetected' -Failure 'змінений manifest має відхилятися за очікуваним SHA-256'

        # Пошкоджений/порожній/відсутній manifest.
        [System.IO.File]::WriteAllText($backup.ManifestPath, '{ not json')
        $corrupt = Get-BRAVOUpdateBackupManifest -Path $backup.ManifestPath
        Test-BRAVOCondition -Condition (-not $corrupt.IsValid -and $corrupt.Problems.Count -gt 0 -and $null -eq $corrupt.Manifest) -Name 'UpdateBackup/CorruptManifest' -Failure 'пошкоджений manifest -> IsValid=$false без винятку'
        [System.IO.File]::WriteAllText($backup.ManifestPath, '')
        $empty = Get-BRAVOUpdateBackupManifest -Path $backup.ManifestPath
        Test-BRAVOCondition -Condition (-not $empty.IsValid) -Name 'UpdateBackup/EmptyManifest' -Failure 'порожній manifest -> IsValid=$false'
        $absent = Get-BRAVOUpdateBackupManifest -Path (Join-Path $envT.Base 'нема.json')
        Test-BRAVOCondition -Condition (-not $absent.IsValid) -Name 'UpdateBackup/AbsentManifest' -Failure 'відсутній manifest -> IsValid=$false'
        $gone = Test-BRAVORuntimeBackup -BackupPath $backup.Path -ManifestPath (Join-Path $envT.Base 'нема.json') -ExpectedManifestSha256 ('A' * 64)
        Test-BRAVOCondition -Condition (-not $gone.IsValid) -Name 'UpdateBackup/TestAbsentManifest' -Failure 'Test без manifest -> IsValid=$false'
    }

    # --- Небезпечні ключі manifest-а -----------------------------------------
    & {
        $envK = New-UpdBackupTestEnvironment -Name 'keys' -OnlyManifest
        $sha = ('A' * 64)
        foreach ($badKey in @('../outside.txt', 'a/../../b.txt', 'C:/Windows/x.txt', '/abs.txt', 'a\b.txt', 'a//b.txt')) {
            $manifestPath = Join-Path $envK.Base 'bad-manifest.json'
            $json = @{ schemaVersion = 1; operationId = 'x'; sourceRuntimeRoot = 'r'; createdUtc = 'u'; excludeFiles = @(); excludeDirs = @(); files = @{ $badKey = $sha }; fileCount = 1; totalBytes = 1 } | ConvertTo-Json -Depth 5
            [System.IO.File]::WriteAllText($manifestPath, $json)
            $bad = Get-BRAVOUpdateBackupManifest -Path $manifestPath
            Test-BRAVOCondition -Condition (-not $bad.IsValid) -Name ('UpdateBackup/UnsafeKeyRejected/' + ($badKey -replace '[^A-Za-z0-9]', '_')) -Failure ('небезпечний ключ ' + $badKey + ' має відхилятися')
        }
    }

    # --- Повтор для того самого opId -----------------------------------------
    & {
        $envR = New-UpdBackupTestEnvironment -Name 'repeat'
        $first = New-BRAVORuntimeBackup -RuntimeRoot $envR.Runtime -BackupRoot $envR.BackupRoot -OperationId 'op-repeat'
        $copied = Join-Path $first.Path 'runtime\VERSION.json'
        $hashBefore = (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash
        $second = New-BRAVORuntimeBackup -RuntimeRoot $envR.Runtime -BackupRoot $envR.BackupRoot -OperationId 'op-repeat'
        Test-BRAVOCondition -Condition ($first.Problems.Count -eq 0 -and $second.Problems.Count -gt 0 -and ($second.Problems -join ' ') -match 'Backup\.AlreadyExists' -and $null -eq $second.ManifestPath) -Name 'UpdateBackup/RepeatRefused' -Failure 'повтор для того самого opId має бути відмовою'
        Test-BRAVOCondition -Condition ((Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash -ceq $hashBefore -and (Test-Path -LiteralPath $first.ManifestPath)) -Name 'UpdateBackup/RepeatKeepsExisting' -Failure 'відмова не має зачіпати наявну копію'
    }

    # --- Reparse point -------------------------------------------------------
    & {
        $envJ = New-UpdBackupTestEnvironment -Name 'reparse'
        $outside = Join-Path $envJ.Base 'зовнішній каталог'
        New-UpdBackupTestFile -Path (Join-Path $outside 'secret.txt') -Text 'outside'
        $junction = Join-Path $envJ.Runtime 'deploy\link'
        $junctionCreated = $false
        try {
            [void](New-Item -ItemType Junction -Path $junction -Target $outside -ErrorAction Stop)
            $junctionCreated = $true
        } catch {
            $junctionCreated = $false
        }
        if ($junctionCreated) {
            try {
                $backup = New-BRAVORuntimeBackup -RuntimeRoot $envJ.Runtime -BackupRoot $envJ.BackupRoot -OperationId 'op-reparse'
                Test-BRAVOCondition -Condition ($backup.Problems.Count -gt 0 -and ($backup.Problems -join ' ') -match 'Backup\.ReparsePoint' -and $null -eq $backup.ManifestPath) -Name 'UpdateBackup/ReparseIsBlocker' -Failure 'junction у runtime -> Backup.ReparsePoint'
                Test-BRAVOCondition -Condition (-not (Test-Path -LiteralPath (Join-Path $envJ.BackupRoot 'op-reparse'))) -Name 'UpdateBackup/ReparseNothingCreated' -Failure 'до reparse-перевірки каталог бекапу не створюється'
            } finally {
                [System.IO.Directory]::Delete($junction)
            }
            # Reparse у виключеному каталозі не є blocker-ом (site-owned не копіюється).
            $excludedLink = Join-Path $envJ.Runtime 'LOGS\ext'
            try {
                [void](New-Item -ItemType Junction -Path $excludedLink -Target $outside -ErrorAction Stop)
                $okBackup = New-BRAVORuntimeBackup -RuntimeRoot $envJ.Runtime -BackupRoot $envJ.BackupRoot -OperationId 'op-reparse-excluded'
                Test-BRAVOCondition -Condition ($okBackup.Problems.Count -eq 0) -Name 'UpdateBackup/ReparseInExcludedIgnored' -Failure ('junction у LOGS не має блокувати: ' + ($okBackup.Problems -join '; '))
            } finally {
                if (Test-Path -LiteralPath $excludedLink) { [System.IO.Directory]::Delete($excludedLink) }
            }
        } else {
            Test-BRAVOCondition -Condition $true -Name 'UpdateBackup/ReparseSkippedNoJunction' -Failure 'junction створити неможливо' -EnvironmentLimitation
        }
    }

    # --- Некоректні входи, перекриття, fault injection -----------------------
    & {
        $envB = New-UpdBackupTestEnvironment -Name 'inputs'
        foreach ($badId in @('..\evil', '../evil', 'a b', '.hidden', 'C:\x')) {
            $r = New-BRAVORuntimeBackup -RuntimeRoot $envB.Runtime -BackupRoot $envB.BackupRoot -OperationId $badId -ErrorAction SilentlyContinue
            Test-BRAVOCondition -Condition ($r.Problems.Count -gt 0 -and ($r.Problems -join ' ') -match 'Backup\.OperationId') -Name ('UpdateBackup/BadOperationId/' + ($badId -replace '[^A-Za-z0-9]', '_')) -Failure ('opId "' + $badId + '" має відхилятися')
        }
        $inside = New-BRAVORuntimeBackup -RuntimeRoot $envB.Runtime -BackupRoot (Join-Path $envB.Runtime 'backups') -OperationId 'op-inside'
        Test-BRAVOCondition -Condition ($inside.Problems.Count -gt 0 -and ($inside.Problems -join ' ') -match 'Backup\.Overlap') -Name 'UpdateBackup/BackupInsideRuntimeRefused' -Failure 'BackupRoot усередині runtime -> Backup.Overlap'
        Test-BRAVOCondition -Condition (-not (Test-Path -LiteralPath (Join-Path $envB.Runtime 'backups'))) -Name 'UpdateBackup/OverlapNothingCreated' -Failure 'при Overlap нічого не створюється'

        $fault = New-BRAVORuntimeBackup -RuntimeRoot $envB.Runtime -BackupRoot $envB.BackupRoot -OperationId 'op-fault' -FaultInjection @{ 'Backup.AfterFileCount' = 2 }
        Test-BRAVOCondition -Condition ($fault.Problems.Count -gt 0 -and $null -eq $fault.ManifestPath -and $null -eq $fault.ManifestSha256) -Name 'UpdateBackup/FaultInjectionFails' -Failure 'збій посеред копіювання -> Problems без manifest'

        $noManifest = New-UpdBackupTestEnvironment -Name 'nomanifest'
        Remove-Item -LiteralPath (Join-Path $noManifest.Runtime 'RUNTIME_MANIFEST.json') -Force
        $nm = New-BRAVORuntimeBackup -RuntimeRoot $noManifest.Runtime -BackupRoot $noManifest.BackupRoot -OperationId 'op-nm'
        Test-BRAVOCondition -Condition ($nm.Problems.Count -gt 0 -and ($nm.Problems -join ' ') -match 'RuntimeManifestMissing' -and $null -eq $nm.ManifestPath) -Name 'UpdateBackup/RuntimeManifestRequired' -Failure 'без RUNTIME_MANIFEST.json backup не валідний'
    }
} finally {
    if ($updBackupTempPrefix.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $updBackupTempPrefix) -like 'bravo-updbak-*' -and (Test-Path -LiteralPath $updBackupTempPrefix)) {
        Remove-Item -LiteralPath $updBackupTempPrefix -Recurse -Force -ErrorAction SilentlyContinue
    }
}
