# Suite UpdateStaging: lifecycle/operation lock і безпечний staging BRAVO.Update
# (INS-035). Фрагмент dot-source-иться з BRAVO_SELF_TEST.ps1 ($root заданий).

Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$updStagingTempPrefix = Join-Path ([System.IO.Path]::GetTempPath()) ('bravo-updstg-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $updStagingTempPrefix -Force)

# Будує ZIP із довільними іменами entry: @( @{ Name; Text } ... ).
function New-UpdStagingTestZip {
    param([string]$Path, [object[]]$Items)
    $zipStream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $zip = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($item in $Items) {
            $entry = $zip.CreateEntry([string]$item.Name)
            if (-not ([string]$item.Name).EndsWith('/')) {
                $writer = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding $false))
                $writer.Write([string]$item.Text)
                $writer.Dispose()
            }
        }
    } finally {
        $zip.Dispose()
        $zipStream.Dispose()
    }
}

try {
    # --- Lifecycle lock -----------------------------------------------------
    & {
        $lockRoot = Join-Path $updStagingTempPrefix 'lock root Кореневий'
        $first = Enter-BRAVOUpdateLifecycleLock -LockRoot $lockRoot -OperationId 'op-1'
        Test-BRAVOCondition -Condition ($first.Success -and $null -ne $first.Stream) -Name 'UpdateStaging/LifecycleLockAcquired' -Failure 'перше захоплення lifecycle-lock має вдатися'
        Test-BRAVOCondition -Condition ((Split-Path -Leaf $first.Path) -eq 'BRAVO_UPDATE.lock') -Name 'UpdateStaging/LifecycleLockFileName' -Failure 'ім''я lock-файла має бути BRAVO_UPDATE.lock'
        $second = Enter-BRAVOUpdateLifecycleLock -LockRoot $lockRoot -OperationId 'op-2'
        Test-BRAVOCondition -Condition (-not $second.Success -and $null -eq $second.Stream) -Name 'UpdateStaging/LifecycleLockBusy' -Failure 'друге захоплення має повернути Success=$false без винятку'
        Test-BRAVOCondition -Condition ($null -ne $second.Holder -and [string]$second.Holder.operationId -eq 'op-1' -and [int]$second.Holder.pid -eq $PID) -Name 'UpdateStaging/LifecycleLockHolderReadable' -Failure 'holder зайнятого lock-а має читатися (operationId, pid)'
        Test-BRAVOCondition -Condition ($null -ne $second.Holder.PSObject.Properties['processStartTime'] -and $null -ne $second.Holder.PSObject.Properties['startedAt']) -Name 'UpdateStaging/LifecycleLockHolderFields' -Failure 'holder має містити processStartTime і startedAt'
        Exit-BRAVOUpdateLifecycleLock -Lock $first
        $third = Enter-BRAVOUpdateLifecycleLock -LockRoot $lockRoot -OperationId 'op-3'
        Test-BRAVOCondition -Condition ($third.Success -and [string]$third.Holder.operationId -eq 'op-3') -Name 'UpdateStaging/LifecycleLockReacquire' -Failure 'після Exit повторне захоплення має вдатися'
        Exit-BRAVOUpdateLifecycleLock -Lock $third
        Exit-BRAVOUpdateLifecycleLock -Lock $null
        Test-BRAVOCondition -Condition (-not (Test-Path -LiteralPath (Join-Path $lockRoot 'BRAVO_UPDATE.holder.json'))) -Name 'UpdateStaging/LifecycleLockSidecarRemoved' -Failure 'Exit має прибрати sidecar holder'
    }

    # --- Operation lock -----------------------------------------------------
    & {
        $opPath = Join-Path $updStagingTempPrefix 'op lock Папка\BRAVO_OPERATION.lock'
        $idle = Test-BRAVOUpdateOperationLockActive -OperationLockPath $opPath
        Test-BRAVOCondition -Condition (-not $idle.Active -and $null -eq $idle.Holder) -Name 'UpdateStaging/OperationLockInactiveMissing' -Failure 'без файла lock неактивний'
        $first = Enter-BRAVOUpdateOperationLock -OperationLockPath $opPath -OperationId 'op-a' -PackageVersion '9.9.9'
        Test-BRAVOCondition -Condition ($first.Success) -Name 'UpdateStaging/OperationLockAcquired' -Failure 'захоплення operation-lock має вдатися'
        $active = Test-BRAVOUpdateOperationLockActive -OperationLockPath $opPath
        Test-BRAVOCondition -Condition ($active.Active -and $null -ne $active.Holder -and [string]$active.Holder.operation -eq 'Update') -Name 'UpdateStaging/OperationLockActiveHolder' -Failure 'активний lock має давати holder operation=Update'
        $second = Enter-BRAVOUpdateOperationLock -OperationLockPath $opPath -OperationId 'op-b' -PackageVersion '9.9.9'
        Test-BRAVOCondition -Condition (-not $second.Success -and $null -ne $second.Holder) -Name 'UpdateStaging/OperationLockBusy' -Failure 'зайнятий lock: Success=$false і читабельний holder'
        $json = & (Get-Module BRAVO.Update) { param($p) Read-BRAVOUpdateLockHolderFile -Path $p } $opPath
        Test-BRAVOCondition -Condition ([string]$json.operation -eq 'Update' -and [string]$json.generationId -eq 'op-a' -and [string]$json.packageVersion -eq '9.9.9' -and [string]$json.hostname -eq [Environment]::MachineName -and $null -eq $json.config) -Name 'UpdateStaging/OperationLockCanonicalFormat' -Failure 'JSON-holder має канонічний формат'
        Exit-BRAVOUpdateOperationLock -Lock $first
        $after = Test-BRAVOUpdateOperationLockActive -OperationLockPath $opPath
        Test-BRAVOCondition -Condition (-not $after.Active) -Name 'UpdateStaging/OperationLockReleasedInactive' -Failure 'після Exit lock неактивний'
        $third = Enter-BRAVOUpdateOperationLock -OperationLockPath $opPath -OperationId 'op-c' -PackageVersion '9.9.9'
        Test-BRAVOCondition -Condition ($third.Success) -Name 'UpdateStaging/OperationLockReacquire' -Failure 'після Exit повторне захоплення має вдатися'
        Exit-BRAVOUpdateOperationLock -Lock $third
    }

    # --- Private directory & reparse ---------------------------------------
    & {
        $dir = Join-Path $updStagingTempPrefix 'private Приватний'
        $created = New-BRAVOUpdatePrivateDirectory -Path $dir
        Test-BRAVOCondition -Condition ($created.Success -and (Test-Path -LiteralPath $dir -PathType Container)) -Name 'UpdateStaging/PrivateDirCreated' -Failure ('приватний каталог не створено: ' + ($created.Problems -join '; '))
        $acl = Get-Acl -LiteralPath $dir
        Test-BRAVOCondition -Condition ($acl.AreAccessRulesProtected) -Name 'UpdateStaging/PrivateDirNoInheritance' -Failure 'успадкування DACL має бути вимкнено'
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        Test-BRAVOCondition -Condition (@($rules | Where-Object { $_.IsInherited }).Count -eq 0) -Name 'UpdateStaging/PrivateDirNoInheritedRules' -Failure 'не має бути успадкованих правил'
        $sids = @($rules | ForEach-Object { [string]$_.IdentityReference.Value })
        $currentSidValue = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Test-BRAVOCondition -Condition (($sids -contains 'S-1-5-32-544') -and ($sids -contains 'S-1-5-18') -and ($sids -contains $currentSidValue) -and (@($sids | Where-Object { $_ -notin @('S-1-5-32-544', 'S-1-5-18', $currentSidValue) }).Count -eq 0)) -Name 'UpdateStaging/PrivateDirTrustedOnly' -Failure 'мають бути лише Administrators, SYSTEM і поточний користувач'
        # Наявний порожній каталог допустимий, непорожній — ні.
        $again = New-BRAVOUpdatePrivateDirectory -Path $dir
        Test-BRAVOCondition -Condition ($again.Success) -Name 'UpdateStaging/PrivateDirExistingEmptyOk' -Failure 'наявний порожній каталог має прийматися'
        [System.IO.File]::WriteAllText((Join-Path $dir 'x.txt'), 'x')
        $nonEmpty = New-BRAVOUpdatePrivateDirectory -Path $dir
        Test-BRAVOCondition -Condition (-not $nonEmpty.Success -and $nonEmpty.Problems.Count -gt 0) -Name 'UpdateStaging/PrivateDirNonEmptyRefused' -Failure 'непорожній каталог має відхилятися'
        Test-BRAVOCondition -Condition (-not (Test-BRAVOUpdatePathHasReparsePoint -Path $dir)) -Name 'UpdateStaging/ReparseNegative' -Failure 'звичайний каталог не reparse point'
        Test-BRAVOCondition -Condition (-not (Test-BRAVOUpdatePathHasReparsePoint -Path (Join-Path $dir 'missing\child'))) -Name 'UpdateStaging/ReparseMissingSkipped' -Failure 'неіснуючий шлях без reparse у предках -> $false'
        # Junction: створюємо через cmd mklink /J (без елевації), лише якщо вдалося.
        $target = Join-Path $updStagingTempPrefix 'junction target'
        $junction = Join-Path $updStagingTempPrefix 'junction link'
        [void](New-Item -ItemType Directory -Path $target -Force)
        $null = & cmd.exe /c mklink /J ('"' + $junction + '"') ('"' + $target + '"') 2>&1
        if (Test-Path -LiteralPath $junction) {
            Test-BRAVOCondition -Condition (Test-BRAVOUpdatePathHasReparsePoint -Path $junction) -Name 'UpdateStaging/ReparseJunctionDetected' -Failure 'junction має виявлятися'
            Test-BRAVOCondition -Condition (Test-BRAVOUpdatePathHasReparsePoint -Path (Join-Path $junction 'child')) -Name 'UpdateStaging/ReparseAncestorDetected' -Failure 'junction серед предків має виявлятися'
            Test-BRAVOCondition -Condition (-not (Test-BRAVOUpdatePathHasReparsePoint -Path $junction -StopAt $junction)) -Name 'UpdateStaging/ReparseStopAt' -Failure 'StopAt виключає межу'
            $viaJunction = New-BRAVOUpdatePrivateDirectory -Path $junction
            Test-BRAVOCondition -Condition (-not $viaJunction.Success) -Name 'UpdateStaging/PrivateDirReparseRefused' -Failure 'reparse point має відхилятися'
            [System.IO.Directory]::Delete($junction)
        } else {
            Test-BRAVOCondition -Condition $true -EnvironmentLimitation -Name 'UpdateStaging/ReparseJunction' -Failure 'junction створити не вдалося'
        }
    }

    # --- Перевірка ZIP ------------------------------------------------------
    & {
        $good = Join-Path $updStagingTempPrefix 'good пакет.zip'
        New-UpdStagingTestZip -Path $good -Items @(
            @{ Name = 'a.txt'; Text = 'one' },
            @{ Name = 'Підтека з пробілом/файл Один.txt'; Text = 'два' },
            @{ Name = 'dir/'; Text = '' },
            @{ Name = 'dir\sub\b.txt'; Text = 'three' })
        $valid = Test-BRAVOUpdateZipEntries -ZipPath $good
        Test-BRAVOCondition -Condition ($valid.IsValid -and $valid.Entries.Count -eq 4 -and $valid.TotalUncompressedBytes -gt 0) -Name 'UpdateStaging/ZipValid' -Failure ('валідний ZIP відхилено: ' + ($valid.Problems -join '; '))

        $cases = [ordered]@{
            'DotDot'      = '../x.txt'
            'DotDotMid'   = 'a/../../x.txt'
            'DriveRooted' = 'C:/x.txt'
            'Unc'         = '\\server\share\x.txt'
            'Rooted'      = '/etc/x.txt'
            'Ads'         = 'a:b'
            'AdsStream'   = 'file.txt:stream'
            'TrailingDot' = 'dir/name.'
            'Reserved'    = 'dir/NUL.txt'
            'InvalidChar' = 'dir/a*b.txt'
        }
        foreach ($caseName in $cases.Keys) {
            $badZip = Join-Path $updStagingTempPrefix ('bad-' + $caseName + '.zip')
            New-UpdStagingTestZip -Path $badZip -Items @(@{ Name = 'ok.txt'; Text = 'ok' }, @{ Name = [string]$cases[$caseName]; Text = 'evil' })
            $badResult = Test-BRAVOUpdateZipEntries -ZipPath $badZip
            Test-BRAVOCondition -Condition (-not $badResult.IsValid -and $badResult.Problems.Count -gt 0) -Name ('UpdateStaging/ZipRejects' + $caseName) -Failure ('ім''я "' + $cases[$caseName] + '" має відхилятися')
        }
        $dupZip = Join-Path $updStagingTempPrefix 'dup.zip'
        New-UpdStagingTestZip -Path $dupZip -Items @(@{ Name = 'A.txt'; Text = '1' }, @{ Name = 'a.txt'; Text = '2' })
        $dupResult = Test-BRAVOUpdateZipEntries -ZipPath $dupZip
        Test-BRAVOCondition -Condition (-not $dupResult.IsValid -and (@($dupResult.Problems) -join ' ') -match 'дублікат') -Name 'UpdateStaging/ZipRejectsCaseDuplicates' -Failure 'A.txt/a.txt мають відхилятися'
        $dupSlash = Join-Path $updStagingTempPrefix 'dup-slash.zip'
        New-UpdStagingTestZip -Path $dupSlash -Items @(@{ Name = 'd/x.txt'; Text = '1' }, @{ Name = 'D\x.txt'; Text = '2' })
        Test-BRAVOCondition -Condition (-not (Test-BRAVOUpdateZipEntries -ZipPath $dupSlash).IsValid) -Name 'UpdateStaging/ZipRejectsSlashNormalisedDuplicates' -Failure 'дублікати після нормалізації слешів мають відхилятися'

        $limits = Test-BRAVOUpdateZipEntries -ZipPath $good -MaxEntries 2
        Test-BRAVOCondition -Condition (-not $limits.IsValid) -Name 'UpdateStaging/ZipRejectsTooManyEntries' -Failure 'перевищення -MaxEntries має відхилятися'
        $limits = Test-BRAVOUpdateZipEntries -ZipPath $good -MaxTotalBytes 5
        Test-BRAVOCondition -Condition (-not $limits.IsValid) -Name 'UpdateStaging/ZipRejectsTooLarge' -Failure 'перевищення -MaxTotalBytes має відхилятися'

        $bomb = Join-Path $updStagingTempPrefix 'bomb.zip'
        $bombStream = New-Object System.IO.FileStream($bomb, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        $bombZip = New-Object System.IO.Compression.ZipArchive($bombStream, [System.IO.Compression.ZipArchiveMode]::Create)
        $bombEntry = $bombZip.CreateEntry('zeros.bin', [System.IO.Compression.CompressionLevel]::Optimal)
        $bombOut = $bombEntry.Open()
        $zeros = New-Object byte[] 1048576
        for ($i = 0; $i -lt 12; $i++) { $bombOut.Write($zeros, 0, $zeros.Length) }
        $bombOut.Dispose(); $bombZip.Dispose(); $bombStream.Dispose()
        $bombResult = Test-BRAVOUpdateZipEntries -ZipPath $bomb
        Test-BRAVOCondition -Condition (-not $bombResult.IsValid -and (@($bombResult.Problems) -join ' ') -match 'стиснення') -Name 'UpdateStaging/ZipRejectsCompressionBomb' -Failure '12 МБ нулів (>200:1) мають відхилятися'

        $notZip = Join-Path $updStagingTempPrefix 'not a zip.zip'
        [System.IO.File]::WriteAllText($notZip, 'це не архів')
        Test-BRAVOCondition -Condition (-not (Test-BRAVOUpdateZipEntries -ZipPath $notZip).IsValid) -Name 'UpdateStaging/ZipRejectsCorrupt' -Failure 'пошкоджений ZIP має відхилятися'
        Test-BRAVOCondition -Condition (-not (Test-BRAVOUpdateZipEntries -ZipPath (Join-Path $updStagingTempPrefix 'missing.zip')).IsValid) -Name 'UpdateStaging/ZipRejectsMissing' -Failure 'відсутній ZIP має відхилятися'
    }

    # --- Розпакування -------------------------------------------------------
    & {
        $good = Join-Path $updStagingTempPrefix 'expand пакет.zip'
        New-UpdStagingTestZip -Path $good -Items @(
            @{ Name = 'a.txt'; Text = 'one' },
            @{ Name = 'Підтека з пробілом/файл Один.txt'; Text = 'два' },
            @{ Name = 'empty dir/'; Text = '' },
            @{ Name = 'dir\sub\b.txt'; Text = 'three' })
        $sha = (Get-FileHash -LiteralPath $good -Algorithm SHA256).Hash

        $dest = Join-Path $updStagingTempPrefix 'dest Призначення'
        [void](New-BRAVOUpdatePrivateDirectory -Path $dest)
        $ok = Expand-BRAVOUpdateArchiveSafe -ZipPath $good -DestinationRoot $dest -ExpectedSha256 $sha
        Test-BRAVOCondition -Condition ($ok.Success -and $ok.FileCount -eq 3) -Name 'UpdateStaging/ExpandOk' -Failure ('розпакування не вдалося: ' + ($ok.Problems -join '; '))
        Test-BRAVOCondition -Condition ([System.IO.File]::ReadAllText((Join-Path $dest 'Підтека з пробілом\файл Один.txt')) -eq 'два' -and (Test-Path -LiteralPath (Join-Path $dest 'empty dir') -PathType Container) -and (Test-Path -LiteralPath (Join-Path $dest 'dir\sub\b.txt'))) -Name 'UpdateStaging/ExpandContent' -Failure 'вміст розпакованого не збігається'
        Test-BRAVOCondition -Condition ((Get-BRAVOUpdateDirectorySize -Path $dest) -eq ([long]([System.Text.Encoding]::UTF8.GetByteCount('one') + [System.Text.Encoding]::UTF8.GetByteCount('два') + [System.Text.Encoding]::UTF8.GetByteCount('three')))) -Name 'UpdateStaging/DirectorySize' -Failure 'розмір каталогу має дорівнювати сумі файлів'

        # Повторне розпакування в уже непорожній каталог відхиляється, наявне не чіпається.
        $again = Expand-BRAVOUpdateArchiveSafe -ZipPath $good -DestinationRoot $dest
        Test-BRAVOCondition -Condition (-not $again.Success -and (Test-Path -LiteralPath (Join-Path $dest 'a.txt'))) -Name 'UpdateStaging/ExpandNonEmptyRefused' -Failure 'непорожнє призначення має відхилятися, вміст лишається'

        # Неправильний SHA256.
        $dest2 = Join-Path $updStagingTempPrefix 'dest2'
        [void](New-BRAVOUpdatePrivateDirectory -Path $dest2)
        $badSha = Expand-BRAVOUpdateArchiveSafe -ZipPath $good -DestinationRoot $dest2 -ExpectedSha256 ('0' * 64)
        Test-BRAVOCondition -Condition (-not $badSha.Success -and @(Get-ChildItem -LiteralPath $dest2 -Force).Count -eq 0) -Name 'UpdateStaging/ExpandShaMismatchRefused' -Failure 'невірний SHA256 має відхилятися без жодного файла'

        # Шкідливий ZIP: нічого не розпаковується.
        $evil = Join-Path $updStagingTempPrefix 'evil.zip'
        New-UpdStagingTestZip -Path $evil -Items @(@{ Name = 'good.txt'; Text = 'g' }, @{ Name = '../escape.txt'; Text = 'e' })
        $evilResult = Expand-BRAVOUpdateArchiveSafe -ZipPath $evil -DestinationRoot $dest2
        Test-BRAVOCondition -Condition (-not $evilResult.Success -and @(Get-ChildItem -LiteralPath $dest2 -Force).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $updStagingTempPrefix 'escape.txt'))) -Name 'UpdateStaging/ExpandEvilRefused' -Failure 'шкідливий ZIP не має залишати файлів'

        # Призначення без захищеного DACL (звичайний каталог) відхиляється.
        $plain = Join-Path $updStagingTempPrefix 'plain dest'
        [void](New-Item -ItemType Directory -Path $plain -Force)
        $plainResult = Expand-BRAVOUpdateArchiveSafe -ZipPath $good -DestinationRoot $plain
        Test-BRAVOCondition -Condition (-not $plainResult.Success -and @(Get-ChildItem -LiteralPath $plain -Force).Count -eq 0) -Name 'UpdateStaging/ExpandNonPrivateRefused' -Failure 'неприватний каталог має відхилятися'

        # Регресія P1: захищений DACL із явним ACE для Users — не приватний.
        $leaky = Join-Path $updStagingTempPrefix 'leaky dest'
        [void](New-BRAVOUpdatePrivateDirectory -Path $leaky)
        $leakyInfo = New-Object System.IO.DirectoryInfo($leaky)
        $leakyAcl = $leakyInfo.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        $usersSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $leakyAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usersSid, [System.Security.AccessControl.FileSystemRights]::Modify, ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit), [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)))
        $leakyInfo.SetAccessControl($leakyAcl)
        $aclProblems = @(& (Get-Module BRAVO.Update) { param($p) Get-BRAVOUpdateDirectoryAclProblem -Path $p } $leaky)
        Test-BRAVOCondition -Condition ((Get-Acl -LiteralPath $leaky).AreAccessRulesProtected -and $aclProblems.Count -gt 0) -Name 'UpdateStaging/AclAllowlistDetectsUsersAce' -Failure 'ACE для Users у захищеному DACL має виявлятися'
        $leakyResult = Expand-BRAVOUpdateArchiveSafe -ZipPath $good -DestinationRoot $leaky
        Test-BRAVOCondition -Condition (-not $leakyResult.Success -and @(Get-ChildItem -LiteralPath $leaky -Force).Count -eq 0) -Name 'UpdateStaging/ExpandAclViolationRefused' -Failure 'каталог з ACE для Users має відхилятися без файлів'
        $cleanAcl = @(& (Get-Module BRAVO.Update) { param($p) Get-BRAVOUpdateDirectoryAclProblem -Path $p } $dest2)
        Test-BRAVOCondition -Condition ($cleanAcl.Count -eq 0) -Name 'UpdateStaging/AclAllowlistAcceptsPrivateDir' -Failure ('приватний каталог не має давати проблем: ' + ($cleanAcl -join '; '))

        # Регресія P1 (TOCTOU): ZIP відкривається з FileShare.Read — поки handle
        # тримається, запис/видалення/підміна файла неможливі; читач не заважає.
        $held = Join-Path $updStagingTempPrefix 'held.zip'
        New-UpdStagingTestZip -Path $held -Items @(@{ Name = 'h.txt'; Text = 'held' })
        $holdStream = New-Object System.IO.FileStream($held, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $replaced = $true
        try { [System.IO.File]::WriteAllText($held, 'replacement') } catch { $replaced = $false }
        $deleted = $true
        try { [System.IO.File]::Delete($held) } catch { $deleted = $false }
        Test-BRAVOCondition -Condition (-not $replaced -and -not $deleted -and (Test-Path -LiteralPath $held)) -Name 'UpdateStaging/ZipHandleBlocksReplaceDelete' -Failure 'файл під handle FileShare.Read не можна підмінити/видалити'
        $dest4 = Join-Path $updStagingTempPrefix 'dest4'
        [void](New-BRAVOUpdatePrivateDirectory -Path $dest4)
        $withReader = Expand-BRAVOUpdateArchiveSafe -ZipPath $held -DestinationRoot $dest4 -ExpectedSha256 ((Get-FileHash -LiteralPath $held -Algorithm SHA256).Hash)
        $holdStream.Dispose()
        Test-BRAVOCondition -Condition ($withReader.Success -and $withReader.FileCount -eq 1) -Name 'UpdateStaging/ExpandWorksWithConcurrentReader' -Failure 'розпакування має працювати, поки інший читач тримає файл'
        # Файл, відкритий на запис іншим handle, не розпаковується (незмінність не гарантована).
        $writeStream = New-Object System.IO.FileStream($held, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $dest5 = Join-Path $updStagingTempPrefix 'dest5'
        [void](New-BRAVOUpdatePrivateDirectory -Path $dest5)
        $withWriter = Expand-BRAVOUpdateArchiveSafe -ZipPath $held -DestinationRoot $dest5
        $writeStream.Dispose()
        Test-BRAVOCondition -Condition (-not $withWriter.Success -and @(Get-ChildItem -LiteralPath $dest5 -Force).Count -eq 0) -Name 'UpdateStaging/ExpandRefusesZipOpenForWrite' -Failure 'ZIP, відкритий на запис, має відхилятися'

        # Регресія P1: junction як корінь призначення відхиляється; підкаталог,
        # підмінений на junction, виявляється ланцюгом -StopAt (його викликає
        # Expand перед записом у кожен каталог).
        $jTarget = Join-Path $updStagingTempPrefix 'jt target'
        $jLink = Join-Path $updStagingTempPrefix 'jt link'
        [void](New-Item -ItemType Directory -Path $jTarget -Force)
        $null = & cmd.exe /c mklink /J ('"' + $jLink + '"') ('"' + $jTarget + '"') 2>&1
        if (Test-Path -LiteralPath $jLink) {
            $viaLink = Expand-BRAVOUpdateArchiveSafe -ZipPath $good -DestinationRoot $jLink
            Test-BRAVOCondition -Condition (-not $viaLink.Success -and @(Get-ChildItem -LiteralPath $jTarget -Force).Count -eq 0) -Name 'UpdateStaging/ExpandJunctionRootRefused' -Failure 'junction як призначення має відхилятися, ціль лишається порожньою'
            $swapRoot = Join-Path $updStagingTempPrefix 'swap root'
            [void](New-BRAVOUpdatePrivateDirectory -Path $swapRoot)
            $swapLink = Join-Path $swapRoot 'sub'
            $null = & cmd.exe /c mklink /J ('"' + $swapLink + '"') ('"' + $jTarget + '"') 2>&1
            Test-BRAVOCondition -Condition (Test-BRAVOUpdatePathHasReparsePoint -Path $swapLink -StopAt $swapRoot) -Name 'UpdateStaging/SwappedSubdirJunctionDetected' -Failure 'підкаталог-junction усередині кореня має виявлятися'
            [System.IO.Directory]::Delete($swapLink)
            [System.IO.Directory]::Delete($jLink)
        } else {
            Test-BRAVOCondition -Condition $true -EnvironmentLimitation -Name 'UpdateStaging/ExpandJunction' -Failure 'junction створити не вдалося'
        }

        # Відсутнє призначення.
        $missingDest = Expand-BRAVOUpdateArchiveSafe -ZipPath $good -DestinationRoot (Join-Path $updStagingTempPrefix 'no such dest')
        Test-BRAVOCondition -Condition (-not $missingDest.Success) -Name 'UpdateStaging/ExpandMissingDestRefused' -Failure 'відсутнє призначення має відхилятися'

        # Відкат: перший файл створено, другий конфліктує (файл і каталог з одним ім'ям) -> нічого не лишається.
        $conflict = Join-Path $updStagingTempPrefix 'conflict.zip'
        New-UpdStagingTestZip -Path $conflict -Items @(@{ Name = 'p/one.txt'; Text = '1' }, @{ Name = 'p/two'; Text = '2' }, @{ Name = 'p/two/inner.txt'; Text = '3' })
        $dest3 = Join-Path $updStagingTempPrefix 'dest3'
        [void](New-BRAVOUpdatePrivateDirectory -Path $dest3)
        $conflictResult = Expand-BRAVOUpdateArchiveSafe -ZipPath $conflict -DestinationRoot $dest3
        Test-BRAVOCondition -Condition (-not $conflictResult.Success -and @(Get-ChildItem -LiteralPath $dest3 -Force).Count -eq 0) -Name 'UpdateStaging/ExpandRollbackOnFailure' -Failure 'при збої розпакування створене має бути видалене'
    }

    # --- Вільне місце -------------------------------------------------------
    & {
        $space = Get-BRAVOUpdateFreeSpace -Path (Join-Path $updStagingTempPrefix 'not yet created')
        Test-BRAVOCondition -Condition ($null -eq $space.Error -and $space.AvailableFreeBytes -gt 0 -and -not [string]::IsNullOrEmpty($space.Volume)) -Name 'UpdateStaging/FreeSpace' -Failure 'вільне місце тому має визначатися'
        $unc = Get-BRAVOUpdateFreeSpace -Path '\\host-a\share\x'
        Test-BRAVOCondition -Condition ($null -eq $unc.AvailableFreeBytes -and $null -ne $unc.Error) -Name 'UpdateStaging/FreeSpaceUncUnknown' -Failure 'UNC -> невідомо з Error'
    }
    # --- H1: захищені корені engine, довіра до особистого SID, робочі каталоги, guarded-видалення ---
    & {
        $h1Module = Get-Module BRAVO.Update
        $h1Base = Join-Path $updStagingTempPrefix 'h1 Кореневі'
        [void](New-Item -ItemType Directory -Path $h1Base -Force)
        $h1UsersSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $h1AddUsersAce = {
            param([string]$Path, $Rights)
            $info = New-Object System.IO.DirectoryInfo($Path)
            $acl = $info.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($h1UsersSid, $Rights,
                    ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
                    [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)))
            $info.SetAccessControl($acl)
        }

        # Рішення «довіряти особистому SID»: false для ролі Administrators (елевований процес), true без неї; помилка = false.
        $trustAdmin = & $h1Module { Test-BRAVOUpdateTrustCurrentUser -AdminCheck { $true } }
        $trustUser = & $h1Module { Test-BRAVOUpdateTrustCurrentUser -AdminCheck { $false } }
        $trustError = & $h1Module { Test-BRAVOUpdateTrustCurrentUser -AdminCheck { throw 'role check failed' } }
        Test-BRAVOCondition -Condition (($trustAdmin -eq $false) -and ($trustUser -eq $true) -and ($trustError -eq $false)) -Name 'UpdateStaging/H1/TrustDecisionPure' -Failure "admin=$trustAdmin user=$trustUser error=$trustError"
        $sidsAdmin = @(& $h1Module { Get-BRAVOUpdateTrustedSid -AdminCheck { $true } })
        $sidsUser = @(& $h1Module { Get-BRAVOUpdateTrustedSid -AdminCheck { $false } })
        $currentSidText = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Test-BRAVOCondition -Condition (($sidsAdmin -notcontains $currentSidText -or @('S-1-5-18', 'S-1-5-32-544') -contains $currentSidText) -and ($sidsUser -contains $currentSidText)) -Name 'UpdateStaging/H1/TrustedSidsExcludePersonalWhenElevated' -Failure ('admin=' + ($sidsAdmin -join ',') + ' user=' + ($sidsUser -join ','))

        # Приватний каталог проходить суворе завершальне оцінювання; Users Write, успадкування й «елевований» власник — ні.
        $h1Private = Join-Path $h1Base 'приватний'
        $made = New-BRAVOUpdatePrivateDirectory -Path $h1Private
        $okProblems = @(& $h1Module { param($p) Get-BRAVOUpdateProtectedRootProblem -Path $p -Kind Private } $h1Private)
        Test-BRAVOCondition -Condition ($made.Success -and $okProblems.Count -eq 0) -Name 'UpdateStaging/H1/ValidatorAcceptsPrivateDirectory' -Failure ($okProblems -join '; ')
        $asElevated = @(& $h1Module { param($p) Get-BRAVOUpdateProtectedRootProblem -Path $p -Kind Private -AdminCheck { $true } } $h1Private)
        $personalIsAdminLike = (@('S-1-5-18', 'S-1-5-32-544') -contains $currentSidText)
        Test-BRAVOCondition -Condition ($personalIsAdminLike -or ($asElevated.Count -gt 0)) -Name 'UpdateStaging/H1/ValidatorRejectsPersonalSidWhenElevated' -Failure 'особистий SID (власник/ACE) не має довірятись елевованому процесу'
        & $h1AddUsersAce $h1Private ([System.Security.AccessControl.FileSystemRights]::Write)
        $usersWrite = @(& $h1Module { param($p) Get-BRAVOUpdateProtectedRootProblem -Path $p -Kind Private } $h1Private)
        Test-BRAVOCondition -Condition (@($usersWrite | Where-Object { $_ -like '*S-1-5-32-545*' }).Count -gt 0) -Name 'UpdateStaging/H1/ValidatorRejectsUsersWrite' -Failure ($usersWrite -join '; ')
        $inherited = Join-Path $h1Base 'успадкований'
        [void](New-Item -ItemType Directory -Path $inherited -Force)
        $inheritedProblems = @(& $h1Module { param($p) Get-BRAVOUpdateProtectedRootProblem -Path $p -Kind Private } $inherited)
        Test-BRAVOCondition -Condition (@($inheritedProblems | Where-Object { $_ -like '*успадкування*' }).Count -gt 0) -Name 'UpdateStaging/H1/ValidatorRejectsInheritedDacl' -Failure ($inheritedProblems -join '; ')

        # Reparse point серед компонентів шляху.
        $junctionTarget = Join-Path $h1Base 'ціль junction'
        $junction = Join-Path $h1Base 'junction'
        [void](New-Item -ItemType Directory -Path $junctionTarget -Force)
        $null = & cmd.exe /c ('mklink /J "' + $junction + '" "' + $junctionTarget + '"')
        if (Test-Path -LiteralPath $junction) {
            $viaJunction = @(& $h1Module { param($p) Get-BRAVOUpdateProtectedRootProblem -Path $p -Kind Private } (Join-Path $junction 'x'))
            $junctionDirect = @(& $h1Module { param($p) Get-BRAVOUpdateProtectedRootProblem -Path $p -Kind Private } $junction)
            Test-BRAVOCondition -Condition (($junctionDirect.Count -gt 0) -and ($junctionDirect[0] -like '*reparse*')) -Name 'UpdateStaging/H1/ValidatorRejectsReparseRoot' -Failure ($junctionDirect -join '; ')
            [void]$viaJunction
            try { [IO.Directory]::Delete($junction) } catch { $null = $_ }
        } else {
            Test-BRAVOCondition -Condition $true -EnvironmentLimitation -Name 'UpdateStaging/H1/ValidatorRejectsReparseRoot' -Failure 'junction не створено'
        }

        # Initialize: створення, -Validate (відсутні = Missing, не помилка), повторне застосування DACL для довіреного власника,
        # відмова без змін для «чужого» власника (симуляція: процес з роллю Administrators, власник — особистий SID).
        $h1Roots = [pscustomobject]@{ StateRoot = (Join-Path $h1Base 'state'); LockRoot = (Join-Path $h1Base 'lock'); StagingRoot = (Join-Path $h1Base 'stg'); BackupRoot = (Join-Path $h1Base 'bak') }
        $missingCheck = & $h1Module { param($p) Initialize-BRAVOUpdateProtectedRoots -Paths $p -Validate } $h1Roots
        Test-BRAVOCondition -Condition ($missingCheck.Success -and @($missingCheck.Missing).Count -ge 8 -and -not (Test-Path -LiteralPath $h1Roots.StateRoot)) -Name 'UpdateStaging/H1/ValidateOnlyCreatesNothing' -Failure ('Missing=' + @($missingCheck.Missing).Count)
        $applied = & $h1Module { param($p) Initialize-BRAVOUpdateProtectedRoots -Paths $p } $h1Roots
        $requestsPath = Join-Path $h1Roots.StateRoot 'Requests'
        $requestsProblems = @(& $h1Module { param($p) Get-BRAVOUpdateProtectedRootProblem -Path $p -Kind Requests } $requestsPath)
        Test-BRAVOCondition -Condition ($applied.Success -and (Test-Path -LiteralPath $requestsPath) -and $requestsProblems.Count -eq 0) -Name 'UpdateStaging/H1/InitializeCreatesRoots' -Failure (($applied.Problems -join '; ') + ' | ' + ($requestsProblems -join '; '))
        $again = & $h1Module { param($p) Initialize-BRAVOUpdateProtectedRoots -Paths $p } $h1Roots
        Test-BRAVOCondition -Condition ($again.Success -and @($again.Created).Count -eq 0 -and @($again.Reapplied).Count -eq 0) -Name 'UpdateStaging/H1/InitializeIdempotent' -Failure ($again.Problems -join '; ')
        & $h1AddUsersAce $requestsPath ([System.Security.AccessControl.FileSystemRights]::Modify)
        $requestsBad = @(& $h1Module { param($p) Get-BRAVOUpdateProtectedRootProblem -Path $p -Kind Requests } $requestsPath)
        Test-BRAVOCondition -Condition ($requestsBad.Count -gt 0) -Name 'UpdateStaging/H1/RequestsDropBoxRejectsUsersModify' -Failure 'Users Modify на Requests має відхилятись'
        $fixed = & $h1Module { param($p) Initialize-BRAVOUpdateProtectedRoots -Paths $p } $h1Roots
        Test-BRAVOCondition -Condition ($fixed.Success -and (@($fixed.Reapplied) -contains $requestsPath)) -Name 'UpdateStaging/H1/TrustedOwnerDaclReapplied' -Failure ($fixed.Problems -join '; ')
        if (-not $personalIsAdminLike) {
            & $h1AddUsersAce $requestsPath ([System.Security.AccessControl.FileSystemRights]::Modify)
            $foreign = & $h1Module { param($p) Initialize-BRAVOUpdateProtectedRoots -Paths $p -AdminCheck { $true } } $h1Roots
            $stillBad = @(& $h1Module { param($p) Get-BRAVOUpdateProtectedRootProblem -Path $p -Kind Requests } $requestsPath)
            Test-BRAVOCondition -Condition ((-not $foreign.Success) -and (@($foreign.Findings).Count -eq 1) -and ([string]$foreign.Findings[0].id -ceq 'State.RootUnsafe') -and $stillBad.Count -gt 0) -Name 'UpdateStaging/H1/ForeignOwnerBlockedNotReAcled' -Failure ('Success=' + $foreign.Success + ' still=' + $stillBad.Count)
        }
        $wrapper = & $h1Module { param($p) Initialize-BRAVOUpdateStateDirectories -StateRoot $p } (Join-Path $h1Base 'wrapper-state')
        Test-BRAVOCondition -Condition ($wrapper.Success -and (Test-Path -LiteralPath (Join-Path $h1Base 'wrapper-state\Operations')) -and -not (Test-Path -LiteralPath (Join-Path $h1Base 'wrapper-state\Staging'))) -Name 'UpdateStaging/H1/StateDirectoriesWrapperScoped' -Failure ($wrapper.Problems -join '; ')

        # Робочий каталог дочірніх скриптів — під заданим коренем, захищений, видаляється guarded-видалювачем.
        $workRoot = $h1Roots.StagingRoot
        $work = & $h1Module { param($p) New-BRAVOUpdateChildWorkDirectory -Root $p } $workRoot
        $workProblems = @()
        if ($work.Success) { $workProblems = @(Get-BRAVOUpdateDirectoryAclProblem -Path $work.WorkDirectory) }
        Test-BRAVOCondition -Condition ($work.Success -and (Test-BRAVOUpdatePathIsUnder -Path $work.WorkDirectory -Root $workRoot) -and $workProblems.Count -eq 0 -and ((Split-Path -Leaf $work.WorkDirectory) -ceq 'work')) -Name 'UpdateStaging/H1/ChildWorkDirectoryUnderRootProtected' -Failure (($work.Problems -join '; ') + ($workProblems -join '; '))
        [IO.File]::WriteAllText((Join-Path $work.WorkDirectory 'child.ps1'), 'x')
        & $h1Module { param($w) Remove-BRAVOUpdateChildWorkDirectory -WorkInfo $w } $work
        Test-BRAVOCondition -Condition (-not (Test-Path -LiteralPath $work.OperationDirectory)) -Name 'UpdateStaging/H1/ChildWorkDirectoryRemoved' -Failure 'робочий каталог має бути видалений'
        $badRoot = Join-Path $h1Base 'badroot'
        [void](New-BRAVOUpdatePrivateDirectory -Path $badRoot)
        & $h1AddUsersAce $badRoot ([System.Security.AccessControl.FileSystemRights]::Modify)
        $badWork = & $h1Module { param($p) New-BRAVOUpdateChildWorkDirectory -Root $p } $badRoot
        Test-BRAVOCondition -Condition (-not $badWork.Success) -Name 'UpdateStaging/H1/ChildWorkDirectoryRefusesWritableRoot' -Failure 'корінь із Users Modify має відхилятись'
        $engineSource = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.Paths.ps1')) + [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.Install.ps1'))
        Test-BRAVOCondition -Condition (($engineSource -notmatch 'BRAVO_UPDATE_EFFECTIVE_') -and ($engineSource -notmatch 'BRAVO_UPDATE_SEED_')) -Name 'UpdateStaging/H1/NoTempWorkDirectoriesForChildScripts' -Failure 'child-скрипти не мають лежати у %TEMP%'

        # Guarded-видалення: AllowedRoot, ACL кореня, junction усередині дерева.
        $removeRoot = Join-Path $h1Base 'remove-root'
        [void](New-BRAVOUpdatePrivateDirectory -Path $removeRoot)
        $removeId = [guid]::NewGuid().ToString()
        $removeDir = Join-Path $removeRoot $removeId
        [void](New-Item -ItemType Directory -Path (Join-Path $removeDir 'sub') -Force)
        $outside = Join-Path $h1Base 'outside'
        [void](New-Item -ItemType Directory -Path $outside -Force)
        [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'keep')
        $otherRoot = Join-Path $h1Base 'other-root'
        [void](New-Item -ItemType Directory -Path $otherRoot -Force)
        $threwForeign = $false
        try { [void](& $h1Module { param($a, $b, $c, $d) Remove-BRAVOUpdateOperationDirectory -Path $a -ExpectedParent $b -OperationId $c -AllowedRoot @($d) } $removeDir $removeRoot $removeId $otherRoot) } catch { $threwForeign = $true }
        Test-BRAVOCondition -Condition ($threwForeign -and (Test-Path -LiteralPath $removeDir)) -Name 'UpdateStaging/H1/RemoverRefusesRootOutsideAllowed' -Failure 'ExpectedParent поза AllowedRoot має відхилятись без змін'
        $null = & cmd.exe /c ('mklink /J "' + (Join-Path $removeDir 'sub\link') + '" "' + $outside + '"')
        $linkCreated = Test-Path -LiteralPath (Join-Path $removeDir 'sub\link')
        $removal = & $h1Module { param($a, $b, $c) Remove-BRAVOUpdateOperationDirectory -Path $a -ExpectedParent $b -OperationId $c -AllowedRoot @($b) } $removeDir $removeRoot $removeId
        Test-BRAVOCondition -Condition ((-not (Test-Path -LiteralPath $removeDir)) -and (Test-Path -LiteralPath (Join-Path $outside 'keep.txt')) -and ($removal.Removed -or -not $linkCreated)) -Name 'UpdateStaging/H1/RemoverStopsAtJunction' -Failure ('Removed=' + $removal.Removed + '; ' + (@($removal.Problems) -join '; '))
        $writableRoot = Join-Path $h1Base 'writable-root'
        [void](New-BRAVOUpdatePrivateDirectory -Path $writableRoot)
        & $h1AddUsersAce $writableRoot ([System.Security.AccessControl.FileSystemRights]::Modify)
        $writableId = [guid]::NewGuid().ToString()
        [void](New-Item -ItemType Directory -Path (Join-Path $writableRoot $writableId) -Force)
        $threwWritable = $false
        try { [void](& $h1Module { param($a, $b, $c) Remove-BRAVOUpdateOperationDirectory -Path $a -ExpectedParent $b -OperationId $c -AllowedRoot @($b) } (Join-Path $writableRoot $writableId) $writableRoot $writableId) } catch { $threwWritable = $true }
        Test-BRAVOCondition -Condition ($threwWritable -and (Test-Path -LiteralPath (Join-Path $writableRoot $writableId))) -Name 'UpdateStaging/H1/RemoverRefusesWritableRoot' -Failure 'корінь із Users Modify має відхилятись'
    }
} finally {
    if ($updStagingTempPrefix.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $updStagingTempPrefix) -like 'bravo-updstg-*' -and (Test-Path -LiteralPath $updStagingTempPrefix)) {
        Remove-Item -LiteralPath $updStagingTempPrefix -Recurse -Force -ErrorAction SilentlyContinue
    }
}
