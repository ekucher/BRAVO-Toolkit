# BRAVO.Update.Paths — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Шляхи за замовчуванням і adapter зовнішніх side effects. Усі інші функції
# engine приймають корені явними параметрами; production-значення
# обчислюються лише тут (CONTRACTS §1).

function Get-BRAVOUpdateDefaultPaths {
    <#
    .SYNOPSIS
        Повертає production-корені Installer v1. Нічого не створює на диску.
    .DESCRIPTION
        ProgramData береться через [Environment]::GetFolderPath, а не з
        $env:ProgramData: змінна середовища може бути підмінена або порожня
        в обмеженому контексті scheduled task.
    #>
    [CmdletBinding()]
    param()

    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    if ([string]::IsNullOrWhiteSpace($programData) -or [string]::IsNullOrWhiteSpace($programFiles)) {
        throw 'BRAVO.Update: не вдалося визначити ProgramData/ProgramFiles (fail closed).'
    }
    $bravoRoot = Join-Path $programData 'BRAVO'
    $lockRoot = Join-Path $bravoRoot 'Locks'
    return [pscustomobject]@{
        StateRoot         = (Join-Path $bravoRoot 'State\Update')
        LockRoot          = $lockRoot
        StagingRoot       = (Join-Path $bravoRoot 'Update\Staging')
        BackupRoot        = (Join-Path $bravoRoot 'Update\Backup')
        RuntimeRoot       = (Join-Path $programFiles 'BRAVO-Toolkit')
        OperationLockPath = (Join-Path $lockRoot 'BRAVO_OPERATION.lock')
        # Той самий production-шлях, що жорстко задають guard-викликачі
        # (BRAVO_ARCHIV.ps1 тощо); engine лише знімає й відновлює його
        # знімок у межах транзакції (ENGINE_DESIGN.md, розділ 7.2).
        VersionStatePath  = (Join-Path $bravoRoot 'State\BRAVO_VERSION_STATE.json')
    }
}

function Get-BRAVOUpdateFullPath {
    <#
    .SYNOPSIS
        Нормалізує шлях (GetFullPath: згортає '.'/'..', подвійні роздільники)
        і прибирає кінцеві роздільники (крім кореня диска).
    .DESCRIPTION
        Кидає виняток для порожнього або невалідного шляху: викликач, якому
        потрібен булів результат, використовує Test-BRAVOUpdatePathIsUnder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'BRAVO.Update: порожній шлях.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    $rootOfPath = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $rootOfPath.Length) {
        $full = $full.TrimEnd([char]'\', [char]'/')
    }
    return $full
}

function Test-BRAVOUpdatePathIsUnder {
    <#
    .SYNOPSIS
        $true, якщо Path лежить строго всередині Root (без урахування регістру,
        після нормалізації).
    .DESCRIPTION
        Нормалізація ПЕРЕД порівнянням закриває обхід через '..'
        (C:\Root\..\Other не є підкаталогом C:\Root) і плутанину префіксів
        (C:\RootX не є підкаталогом C:\Root: порівнюємо з роздільником).
        Збіг із Root дає $false, якщо не вказано -AllowEqual. Будь-яка
        помилка нормалізації — $false (fail closed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Root,
        [switch]$AllowEqual
    )

    try {
        $fullPath = Get-BRAVOUpdateFullPath -Path $Path
        $fullRoot = Get-BRAVOUpdateFullPath -Path $Root
    } catch {
        return $false
    }
    if ([string]::Equals($fullPath, $fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return [bool]$AllowEqual
    }
    $prefix = $fullRoot
    if (-not $prefix.EndsWith('\')) { $prefix = $prefix + '\' }
    return $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

# ---------------------------------------------------------------------------
# Захищені корені engine (H1, внутрішнє рев'ю безпеки)
#
# Модель загрози: звичайний локальний користувач проти елевованого engine.
# UAC split token: SID елевованого процесу == особистий SID оператора, тому
# каталог, доступний особистому SID, доступний і НЕЕЛЕВОВАНОМУ шкідливому коду
# того ж облікового запису. Через це довіряємо лише BUILTIN\Administrators і
# NT AUTHORITY\SYSTEM; особистий SID довіряється ТІЛЬКИ процесу без прав
# адміністратора (тести/dry-run), де інших варіантів немає. ProgramData дозволяє
# будь-кому створювати каталоги, тож власника й ACL кожного кореня перевіряємо
# ДО читання журналів/запитів. Це єдина реалізація: New-BRAVOUpdatePrivateDirectory
# (Staging) і New-BRAVOInstallProtectedDirectory (Install) — тонкі обгортки.
#
# Чому не Protect-BRAVOMachineStateRoot (BRAVO.System): він перевіряє лише
# широкі Allow-ACE на ОДНОМУ каталозі State, не перевіряє власника, reparse
# point, не має наборів прав для Requests/Operations і застосовує Set-Acl
# (SeSecurityPrivilege). Сумісність збережено: контейнер State отримує рівно
# той самий DACL (Administrators/SYSTEM), тож SETUP не бачить розбіжності.
# ---------------------------------------------------------------------------

function Test-BRAVOUpdateTrustCurrentUser {
    <#
    .SYNOPSIS
        Рішення «чи довіряти особистому SID поточного користувача»: лише коли
        процес НЕ в ролі Administrators. AdminCheck — seam для тестів.
    .DESCRIPTION
        Помилка перевірки ролі = вважаємо адміністратором (не довіряємо; fail closed).
    #>
    [CmdletBinding()]
    param([scriptblock]$AdminCheck = $null)

    $isAdministrator = $true
    try {
        if ($null -ne $AdminCheck) { $isAdministrator = [bool](& $AdminCheck) } else { $isAdministrator = [bool](Test-BRAVOUpdateWorkerIsAdministrator) }
    } catch {
        $isAdministrator = $true
    }
    return (-not $isAdministrator)
}

function Get-BRAVOUpdateTrustedSid {
    # Довірені SID (текст): Administrators, SYSTEM і (лише без прав адміністратора)
    # поточний користувач.
    [CmdletBinding()]
    param([scriptblock]$AdminCheck = $null)

    $list = New-Object System.Collections.Generic.List[string]
    $list.Add('S-1-5-32-544')
    $list.Add('S-1-5-18')
    if (Test-BRAVOUpdateTrustCurrentUser -AdminCheck $AdminCheck) {
        $currentValue = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if (-not $list.Contains($currentValue)) { $list.Add($currentValue) }
    }
    return $list.ToArray()
}

function Test-BRAVOUpdateOwnerTrusted {
    # $true, якщо власник каталогу довірений. Помилка читання = $false.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [scriptblock]$AdminCheck = $null)

    try {
        $owner = [string](Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        return ((Get-BRAVOUpdateTrustedSid -AdminCheck $AdminCheck) -contains $owner)
    } catch {
        return $false
    }
}

function New-BRAVOUpdateProtectedDirectory {
    <#
    .SYNOPSIS
        ЄДИНА реалізація створення каталогу із захищеним DACL за набором правил
        { Sid, Rights, Inheritance }. Повертає { Success; Path; Problems[] }, не кидає.
    .DESCRIPTION
        Успадкування вимкнено; без прав адміністратора власника призначити
        неможливо (лишається поточний), з правами — Administrators. Наявний
        каталог допустимий лише порожній і не reparse point (DACL застосовується
        до нього). Set-Acl не використовується (SeSecurityPrivilege): змінюється
        лише секція Access. Результат перечитується: рівно очікуваний набір
        явних правил і довірений власник. Створений нами каталог із хибним DACL
        не лишаємо (лише порожній, нерекурсивно).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object[]]$Rule,
        [scriptblock]$AdminCheck = $null
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $fullPath = $Path
    $created = $false
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $exists = [System.IO.Directory]::Exists($fullPath)
        if ($exists) {
            if (Test-BRAVOUpdatePathHasReparsePoint -Path $fullPath) { throw 'шлях є reparse point або має його серед предків.' }
            if (@(Get-ChildItem -LiteralPath $fullPath -Force).Count -gt 0) { throw 'каталог уже існує і не порожній.' }
        } elseif (Test-Path -LiteralPath $fullPath) {
            throw 'шлях існує і не є каталогом.'
        }
        $trusted = @(Get-BRAVOUpdateTrustedSid -AdminCheck $AdminCheck)
        $expectedValues = @($Rule | ForEach-Object { $_.Sid.Value })
        if ($exists) {
            $applied = Set-BRAVOUpdateDirectoryAcl -Path $fullPath -Rule $Rule
            if (-not $applied.Success) { foreach ($item in $applied.Problems) { $problems.Add([string]$item) } }
        } else {
            $security = New-Object System.Security.AccessControl.DirectorySecurity
            $security.SetAccessRuleProtection($true, $false)
            if (-not (Test-BRAVOUpdateTrustCurrentUser -AdminCheck $AdminCheck)) {
                $security.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
            }
            foreach ($item in $Rule) {
                $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $item.Sid, $item.Rights, $item.Inheritance,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
            }
            # Windows PowerShell 5.1 (.NET Framework): Directory.CreateDirectory(path, DirectorySecurity);
            # PowerShell 7 (.NET): FileSystemAclExtensions.CreateDirectory.
            $createWithSecurity = [System.IO.Directory].GetMethod('CreateDirectory', [Type[]]@([string], [System.Security.AccessControl.DirectorySecurity]))
            if ($null -ne $createWithSecurity) {
                [void][System.IO.Directory]::CreateDirectory($fullPath, $security)
            } else {
                [void][System.IO.FileSystemAclExtensions]::CreateDirectory($security, $fullPath)
            }
            $created = $true
        }

        $actual = Get-Acl -LiteralPath $fullPath
        if (-not $actual.AreAccessRulesProtected) { $problems.Add('успадкування прав не вимкнено') }
        $ownerValue = [string]$actual.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($trusted -notcontains $ownerValue) { $problems.Add('власник ' + $ownerValue + ' не з довіреного списку') }
        $rules = @($actual.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        foreach ($actualRule in $rules) {
            $ruleSid = [string]$actualRule.IdentityReference.Value
            $match = $null
            foreach ($item in $Rule) { if ($ruleSid -eq $item.Sid.Value) { $match = $item } }
            if ($actualRule.IsInherited -or ($null -eq $match) -or
                $actualRule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
                (($actualRule.FileSystemRights -band $match.Rights) -ne $match.Rights)) {
                $problems.Add('зайве або неповне правило ' + $ruleSid + ' ' + [string]$actualRule.AccessControlType + ' ' + [string]$actualRule.FileSystemRights)
            }
        }
        foreach ($expectedValue in $expectedValues) {
            if (@($rules | Where-Object { [string]$_.IdentityReference.Value -eq $expectedValue }).Count -eq 0) { $problems.Add('немає правила для ' + $expectedValue) }
        }
        if (@(Get-ChildItem -LiteralPath $fullPath -Force).Count -gt 0) { $problems.Add('каталог не порожній') }
        if ($problems.Count -gt 0) {
            if ($created) { try { [System.IO.Directory]::Delete($fullPath, $false) } catch { $null = $_ } }
            return [pscustomobject]@{ Success = $false; Path = $fullPath; Problems = $problems.ToArray() }
        }
        return [pscustomobject]@{ Success = $true; Path = $fullPath; Problems = @() }
    } catch {
        $problems.Add('Захищений каталог ' + $Path + ' не створено: ' + $_.Exception.Message)
        return [pscustomobject]@{ Success = $false; Path = $Path; Problems = $problems.ToArray() }
    }
}

function Get-BRAVOUpdateProtectedRootProblem {
    <#
    .SYNOPSIS
        Проблеми безпеки наявного кореня engine (порожній масив = безпечний).
    .DESCRIPTION
        Kind: Private (лише довірені), ReadOnly (Users — лише читання/обхід),
        Requests (Users — лише створення файлів: drop box). Перевіряє: немає
        reparse point серед компонентів шляху; власник довірений; будь-який Allow-ACE
        недовіреного принципала не виходить за дозволену маску (запис/видалення/
        зміна прав заборонені). Суворий режим додатково вимагає вимкненого
        успадкування й відсутності успадкованих правил; -Lenient (для
        guarded-видалення) цього не вимагає, але запис недовірених заборонений так само.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('Private', 'ReadOnly', 'Requests')][string]$Kind = 'Private',
        [switch]$Lenient,
        [scriptblock]$AdminCheck = $null
    )

    $problems = New-Object System.Collections.Generic.List[string]
    try {
        if (Test-BRAVOUpdatePathHasReparsePoint -Path $Path) { $problems.Add('шлях є reparse point або має його серед предків: ' + $Path); return $problems.ToArray() }
        if (-not [System.IO.Directory]::Exists($Path)) { $problems.Add('каталог не існує або не є каталогом: ' + $Path); return $problems.ToArray() }
        $trusted = @(Get-BRAVOUpdateTrustedSid -AdminCheck $AdminCheck)
        $rights = [System.Security.AccessControl.FileSystemRights]
        $usersSid = 'S-1-5-32-545'
        $allowedMask = 0
        switch ($Kind) {
            'ReadOnly' { $allowedMask = [int]($rights::ReadAndExecute -bor $rights::Synchronize) }
            'Requests' { $allowedMask = [int]($rights::CreateFiles -bor $rights::ExecuteFile -bor $rights::ReadAttributes -bor $rights::Synchronize) }
            default { $allowedMask = 0 }
        }
        $acl = Get-Acl -LiteralPath $Path
        if ((-not $Lenient) -and (-not $acl.AreAccessRulesProtected)) { $problems.Add('успадкування прав не вимкнено: ' + $Path) }
        $ownerSid = [string]$acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($trusted -notcontains $ownerSid) { $problems.Add('власник ' + $ownerSid + ' не з довіреного списку: ' + $Path) }
        foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            $ruleSid = [string]$rule.IdentityReference.Value
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
            if ((-not $Lenient) -and $rule.IsInherited) { $problems.Add('успадковане правило ' + $ruleSid + ': ' + $Path) }
            if ($trusted -contains $ruleSid) { continue }
            $ruleMask = [int]$rule.FileSystemRights
            $maskAllowed = 0
            if ($ruleSid -eq $usersSid) { $maskAllowed = $allowedMask }
            if (($ruleMask -band (-bnot $maskAllowed)) -ne 0) {
                $problems.Add('ACE для недовіреного ' + $ruleSid + ' (' + [string]$rule.FileSystemRights + ') перевищує дозволене: ' + $Path)
            }
        }
    } catch {
        $problems.Add('ACL не прочитано: ' + $_.Exception.Message)
    }
    return $problems.ToArray()
}

function Get-BRAVOUpdateProtectedRootSpec {
    <#
    .SYNOPSIS
        Впорядкований (батьки першими) перелік коренів engine: { Path; Kind; Role }.
    .DESCRIPTION
        Контейнери — предки коренів ЛИШЕ всередині -ProgramDataRoot (ProgramData
        дозволяє будь-кому створювати каталоги: підкинутий BRAVO/State/Update
        керував би всім деревом). Корені поза ProgramData (тести) контейнерів не мають.
        Контейнер, що безпосередньо містить StateRoot (BRAVO\State), — Private:
        той самий DACL, який застосовує Protect-BRAVOMachineStateRoot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [string]$ProgramDataRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($ProgramDataRoot)) { $ProgramDataRoot = [Environment]::GetFolderPath('CommonApplicationData') }
    $stateRoot = Get-BRAVOUpdateFullPath -Path ([string]$Paths.StateRoot)
    $leaves = New-Object System.Collections.Generic.List[object]
    $leaves.Add([pscustomobject]@{ Path = $stateRoot; Kind = 'Private'; Role = 'StateRoot' })
    $leaves.Add([pscustomobject]@{ Path = (Join-Path $stateRoot 'Journal'); Kind = 'ReadOnly'; Role = 'Journal' })
    $leaves.Add([pscustomobject]@{ Path = (Join-Path $stateRoot 'Operations'); Kind = 'ReadOnly'; Role = 'Operations' })
    $leaves.Add([pscustomobject]@{ Path = (Join-Path $stateRoot 'ConsumedPlans'); Kind = 'Private'; Role = 'ConsumedPlans' })
    $leaves.Add([pscustomobject]@{ Path = (Join-Path $stateRoot 'Requests'); Kind = 'Requests'; Role = 'Requests' })
    $leaves.Add([pscustomobject]@{ Path = (Get-BRAVOUpdateFullPath -Path ([string]$Paths.LockRoot)); Kind = 'Private'; Role = 'LockRoot' })
    $leaves.Add([pscustomobject]@{ Path = (Get-BRAVOUpdateFullPath -Path ([string]$Paths.StagingRoot)); Kind = 'Private'; Role = 'StagingRoot' })
    $leaves.Add([pscustomobject]@{ Path = (Get-BRAVOUpdateFullPath -Path ([string]$Paths.BackupRoot)); Kind = 'Private'; Role = 'BackupRoot' })

    $containers = @{}
    $stateParent = [System.IO.Path]::GetDirectoryName($stateRoot)
    foreach ($leaf in $leaves) {
        $ancestor = [System.IO.Path]::GetDirectoryName($leaf.Path)
        while ((-not [string]::IsNullOrEmpty($ancestor)) -and (Test-BRAVOUpdatePathIsUnder -Path $ancestor -Root $ProgramDataRoot)) {
            $kind = 'ReadOnly'
            if ([string]::Equals($ancestor, $stateParent, [StringComparison]::OrdinalIgnoreCase)) { $kind = 'Private' }
            $containers[$ancestor.ToLowerInvariant()] = [pscustomobject]@{ Path = $ancestor; Kind = $kind; Role = 'Container' }
            $ancestor = [System.IO.Path]::GetDirectoryName($ancestor)
        }
    }
    $ordered = New-Object System.Collections.Generic.List[object]
    $sortedContainers = @($containers.Values | Sort-Object -Property @{ Expression = { $_.Path.Length } })
    $seen = @{}
    foreach ($container in $sortedContainers) { $ordered.Add($container); $seen[$container.Path.ToLowerInvariant()] = $true }
    foreach ($leaf in $leaves) {
        $key = $leaf.Path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $ordered.Add($leaf)
    }
    return $ordered.ToArray()
}

function Initialize-BRAVOUpdateProtectedRoots {
    <#
    .SYNOPSIS
        Створює (елевований engine) або перевіряє (-Validate) кожен корінь engine
        із власником/ACL за моделлю загрози H1. Не кидає.
    .DESCRIPTION
        Повертає { Success; Created[]; Reapplied[]; Missing[]; Problems[]; Findings[] }.
        Відсутній корінь: створюється (apply) або потрапляє в Missing (-Validate).
        Наявний: перевіряється Get-BRAVOUpdateProtectedRootProblem. За проблем у
        apply-режимі DACL перезастосовується ЛИШЕ коли власник довірений
        (Administrators/SYSTEM — каталог створений engine раніше); каталог з
        недовіреним власником може містити підкинутий вміст, тому НЕ змінюється:
        Blocker-finding вимагає ручного прибирання. Reparse point — завжди відмова.
        Викликається на початку Execute/Install/Update/Repair/Recover ДО читання
        будь-якого журналу чи запиту. GUI цю функцію з правами не викликає.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [switch]$Validate,
        [string]$ProgramDataRoot = '',
        # Обмеження переліку ролями (Get-BRAVOUpdateProtectedRootSpec.Role); без нього — усі корені й контейнери.
        [string[]]$Only = @(),
        [scriptblock]$AdminCheck = $null
    )

    $created = New-Object System.Collections.Generic.List[string]
    $reapplied = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    $problems = New-Object System.Collections.Generic.List[string]
    $includeCurrent = Test-BRAVOUpdateTrustCurrentUser -AdminCheck $AdminCheck
    $spec = @()
    try {
        $spec = @(Get-BRAVOUpdateProtectedRootSpec -Paths $Paths -ProgramDataRoot $ProgramDataRoot)
        if (@($Only).Count -gt 0) { $spec = @($spec | Where-Object { @($Only) -contains [string]$_.Role }) }
    } catch {
        $problems.Add('Корені engine не визначено: ' + $_.Exception.Message)
    }
    $ruleFor = {
        param([string]$Kind)
        $ruleKind = 'Private'
        if ($Kind -eq 'ReadOnly') { $ruleKind = 'Operation' } elseif ($Kind -eq 'Requests') { $ruleKind = 'Requests' }
        Get-BRAVOUpdateWorkerAclRule -Kind $ruleKind -IncludeCurrentUser:$includeCurrent
    }
    foreach ($entry in $spec) {
        $path = [string]$entry.Path
        try {
            if (Test-BRAVOUpdatePathHasReparsePoint -Path $path) { $problems.Add('шлях є reparse point або має його серед предків: ' + $path); continue }
            if (-not [System.IO.Directory]::Exists($path)) {
                if (Test-Path -LiteralPath $path) { $problems.Add('шлях існує і не є каталогом: ' + $path); continue }
                if ($Validate) { $missing.Add($path); continue }
                $made = New-BRAVOUpdateProtectedDirectory -Path $path -Rule @(& $ruleFor ([string]$entry.Kind)) -AdminCheck $AdminCheck
                if ($made.Success) { $created.Add($path) } else { foreach ($item in $made.Problems) { $problems.Add([string]$item) } }
                continue
            }
            $found = @(Get-BRAVOUpdateProtectedRootProblem -Path $path -Kind ([string]$entry.Kind) -AdminCheck $AdminCheck)
            if ($found.Count -eq 0) { continue }
            if ($Validate) { foreach ($item in $found) { $problems.Add([string]$item) }; continue }
            if (-not (Test-BRAVOUpdateOwnerTrusted -Path $path -AdminCheck $AdminCheck)) {
                foreach ($item in $found) { $problems.Add([string]$item) }
                $problems.Add('каталог не змінено: власник недовірений, потрібне ручне прибирання (могло бути підкинуто вміст): ' + $path)
                continue
            }
            $applied = Set-BRAVOUpdateDirectoryAcl -Path $path -Rule @(& $ruleFor ([string]$entry.Kind))
            $after = @(Get-BRAVOUpdateProtectedRootProblem -Path $path -Kind ([string]$entry.Kind) -AdminCheck $AdminCheck)
            if ($applied.Success -and $after.Count -eq 0) { $reapplied.Add($path) } else {
                foreach ($item in (@($applied.Problems) + $after)) { if (-not [string]::IsNullOrEmpty([string]$item)) { $problems.Add([string]$item) } }
            }
        } catch {
            $problems.Add('Корінь ' + $path + ' не оброблено: ' + $_.Exception.Message)
        }
    }
    $findings = New-Object System.Collections.Generic.List[object]
    if ($problems.Count -gt 0) {
        $findings.Add((New-BRAVOUpdateFinding -Id 'State.RootUnsafe' -Severity Blocker -Title 'Каталоги стану engine не пройшли перевірку власника/прав' `
                -Meaning 'Каталог могли створити або змінити непривілейовані користувачі; довіряти його вмісту не можна.' `
                -Action 'Адміністратор має вручну перевірити й прибрати зазначені каталоги, потім повторити; engine не перезаписує права каталогів із чужим власником.' `
                -Details ([string]::Join('; ', $problems.ToArray()))))
    }
    return [pscustomobject]@{
        Success   = ($problems.Count -eq 0)
        Created   = $created.ToArray()
        Reapplied = $reapplied.ToArray()
        Missing   = $missing.ToArray()
        Problems  = $problems.ToArray()
        Findings  = $findings.ToArray()
    }
}

function New-BRAVOUpdateChildWorkDirectory {
    <#
    .SYNOPSIS
        Захищений робочий каталог для дочірнього скрипта: <Root>\<guid>\work.
        Повертає { Success; Root; OperationDirectory; WorkDirectory; OperationId; Problems[] }.
    .DESCRIPTION
        Елевований engine передає StagingRoot (захищений); НЕЕЛЕВОВАНЕ читання
        передає каталог користувача — скрипт, який виконується елевованим, ніколи
        не лежить у %TEMP%. Корінь має пройти м'яку перевірку власника/ACL.
        Видаляється лише Remove-BRAVOUpdateChildWorkDirectory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root, [scriptblock]$AdminCheck = $null)

    $fail = {
        param([string[]]$Message)
        [pscustomobject]@{ Success = $false; Root = $Root; OperationDirectory = $null; WorkDirectory = $null; OperationId = $null; Problems = @($Message) }
    }
    try {
        if (-not [System.IO.Directory]::Exists($Root)) {
            $rootRules = @(Get-BRAVOUpdateWorkerAclRule -Kind Private -IncludeCurrentUser:(Test-BRAVOUpdateTrustCurrentUser -AdminCheck $AdminCheck))
            $rootMade = New-BRAVOUpdateProtectedDirectory -Path $Root -Rule $rootRules -AdminCheck $AdminCheck
            if (-not $rootMade.Success) { return (& $fail @($rootMade.Problems)) }
        }
        $rootProblems = @(Get-BRAVOUpdateProtectedRootProblem -Path $Root -Kind ReadOnly -Lenient -AdminCheck $AdminCheck)
        if ($rootProblems.Count -gt 0) { return (& $fail @($rootProblems)) }
        $id = [guid]::NewGuid().ToString()
        $operationDirectory = Join-Path $Root $id
        $workDirectory = Join-Path $operationDirectory 'work'
        $first = New-BRAVOUpdatePrivateDirectory -Path $operationDirectory
        if (-not $first.Success) { return (& $fail @($first.Problems)) }
        $second = New-BRAVOUpdatePrivateDirectory -Path $workDirectory
        if (-not $second.Success) {
            [void](Remove-BRAVOUpdateOperationDirectory -Path $operationDirectory -ExpectedParent $Root -OperationId $id -AllowedRoot @($Root))
            return (& $fail @($second.Problems))
        }
        return [pscustomobject]@{ Success = $true; Root = $Root; OperationDirectory = $operationDirectory; WorkDirectory = $workDirectory; OperationId = $id; Problems = @() }
    } catch {
        return (& $fail @($_.Exception.Message))
    }
}

function Remove-BRAVOUpdateChildWorkDirectory {
    # Видалення робочого каталогу через guarded-видалювач (без Remove-Item -Recurse).
    [CmdletBinding()]
    param([AllowNull()]$WorkInfo)

    if (($null -eq $WorkInfo) -or (-not [bool]$WorkInfo.Success)) { return }
    try {
        [void](Remove-BRAVOUpdateOperationDirectory -Path ([string]$WorkInfo.OperationDirectory) -ExpectedParent ([string]$WorkInfo.Root) -OperationId ([string]$WorkInfo.OperationId) -AllowedRoot @([string]$WorkInfo.Root))
    } catch {
        # Прибирання допоміжне: збій не має ховати результат дочірнього процесу.
        $null = $_
    }
}

function ConvertTo-BRAVOUpdateQuotedArgument {
    # Лапкування одного аргументу за правилами CommandLineToArgvW: шлях із
    # пробілами/кирилицею лишається одним аргументом; кінцеві '\' перед
    # закриваючою лапкою подвоюються. Значення з вбудованою '"' відхиляємо.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value.Contains('"')) {
        throw 'BRAVO.Update: аргумент дочірнього процесу не може містити лапку.'
    }
    return '"' + ([regex]::Replace($Value, '(\\*)$', '$1$1')) + '"'
}

function Invoke-BRAVOUpdateChildProcess {
    <#
    .SYNOPSIS
        Запускає powershell.exe -NoProfile -NonInteractive -File <Script> ...
        і повертає { ExitCode, Output, TimedOut, LogPath }.
    .DESCRIPTION
        Секрети в аргументи НЕ передаються (лише шляхи та імена компонентів).
        Завершується лише власний дочірній процес (за об'єктом Process, що
        створив цей виклик, тобто за його handle, а не за ім'ям чи віком) і
        лише після таймауту.
        -ExecutionPolicy RemoteSigned (не Bypass): політика машини не
        послаблюється до повного обходу (ENGINE_DESIGN §6).
        Вивід ЗАВЖДИ проходить Protect-BRAVOLogSecret перед поверненням і
        записом у -LogPath; якщо маскувальник недоступний, вивід не
        повертається (fail closed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ScriptArgument = @(),
        [int]$TimeoutSeconds = 600,
        [string]$WorkingDirectory = '',
        [string]$LogPath = ''
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        return [pscustomobject]@{ ExitCode = -1; Output = "Скрипт не знайдено: $ScriptPath"; TimedOut = $false; LogPath = $null }
    }
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) { $powershellPath = 'powershell.exe' }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($fixed in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned', '-File')) { $parts.Add($fixed) }
    $parts.Add((ConvertTo-BRAVOUpdateQuotedArgument -Value $ScriptPath))
    foreach ($argument in @($ScriptArgument)) {
        # Перемикачі й імена параметрів (-NoPause, -Action) не лапкуємо;
        # значення (шляхи, імена) — лапкуємо.
        if ($argument -match '^-[A-Za-z]+$') { $parts.Add($argument) } else { $parts.Add((ConvertTo-BRAVOUpdateQuotedArgument -Value $argument)) }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellPath
    $startInfo.Arguments = [string]::Join(' ', $parts.ToArray())
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $startInfo.WorkingDirectory = $WorkingDirectory }

    # Маскування секретів ДО повернення й запису в лог. BRAVO.Logging
    # імпортується один раз у BRAVO.Update.psm1; немає Protect-BRAVOLogSecret —
    # вивід не повертається (fail closed).
    $maskingAvailable = ($null -ne (Get-Command -Name 'Protect-BRAVOLogSecret' -ErrorAction SilentlyContinue))
    $mask = {
        param([string]$Raw)
        if (-not $maskingAvailable) { return '[вивід приховано: маскування секретів недоступне]' }
        return [string](Protect-BRAVOLogSecret -Text $Raw)
    }
    $writeLog = {
        param([string]$MaskedText)
        if ([string]::IsNullOrWhiteSpace($LogPath)) { return $null }
        try {
            $logDirectory = Split-Path -Parent $LogPath
            if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and -not [IO.Directory]::Exists($logDirectory)) {
                [void][IO.Directory]::CreateDirectory($logDirectory)
            }
            [IO.File]::WriteAllText($LogPath, $MaskedText, (New-Object System.Text.UTF8Encoding($false)))
            return $LogPath
        } catch {
            # Лог допоміжний: збій запису не має ховати код виходу дочірнього процесу.
            return $null
        }
    }

    # Запуск процесу лише через канонічний Start-BRAVOProcessWithBomFreeInput
    # (governance Secrets/StdinProcessStartOnlyViaBomFreeHelper). Stdin тут НЕ
    # перенаправляється (RedirectStandardInput за замовчуванням $false), дитина
    # працює з -NonInteractive. BRAVO.Compatibility підключається ліниво.
    if ($null -eq (Get-Command -Name 'Start-BRAVOProcessWithBomFreeInput' -ErrorAction SilentlyContinue)) {
        $compatibilityManifest = Join-Path $script:BRAVOUpdateToolkitRoot 'modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1'
        try {
            Import-Module -Name $compatibilityManifest -DisableNameChecking -ErrorAction Stop
        } catch {
            return [pscustomobject]@{ ExitCode = -1; Output = 'BRAVO.Compatibility недоступний: запуск дочірнього процесу відхилено (fail closed).'; TimedOut = $false; LogPath = $null }
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        Start-BRAVOProcessWithBomFreeInput -Process $process
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Лише власний об'єкт Process (handle, отриманий зі Start): PID міг
            # би бути перевикористаний, handle — ні.
            try { $process.Kill() } catch { <# власний дочірній процес міг завершитись між WaitForExit і Kill — гонитва очікувана #> }
            $timeoutText = & $mask "Таймаут $TimeoutSeconds с: $ScriptPath"
            $timeoutLog = & $writeLog $timeoutText
            return [pscustomobject]@{ ExitCode = -1; Output = $timeoutText; TimedOut = $true; LogPath = $timeoutLog }
        }
        $process.WaitForExit()
        $text = [string]$stdoutTask.Result
        $errText = [string]$stderrTask.Result
        if (-not [string]::IsNullOrWhiteSpace($errText)) { $text = $text + [Environment]::NewLine + $errText }
        $maskedText = & $mask $text
        $writtenLog = & $writeLog $maskedText
        return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Output = $maskedText; TimedOut = $false; LogPath = $writtenLog }
    } finally {
        $process.Dispose()
    }
}

function Import-BRAVOUpdateTrustedGuardFunctions {
    <#
    .SYNOPSIS
        Єдиний канонічний завантажувач довірених функцій BRAVO_RUNTIME_GUARD.ps1
        в область модуля BRAVO.Update (ConvertTo-/Compare-BRAVOComparableVersion,
        Test-BRAVORuntimeManifestIntegrity, Get-BRAVORuntimeFileHash).
    .DESCRIPTION
        Guard — виконуваний скрипт із param-блоком і головним блоком, тому
        dot-source засмічував би область викликача param-змінними
        ($RuntimeRoot/$Mode/...). Натомість через AST витягаємо лише тексти
        потрібних FunctionDefinitionAst і оголошуємо їх як script:-функції
        модуля: політика SemVer та перевірка manifest лишаються в одному місці
        (guard комплекту ІНСТАЛЯТОРА, а не цільового/staged дерева, яке ще не
        довірене). Ідемпотентно: якщо всі функції вже оголошені в цьому модулі,
        файл не читається (-Force примусово перечитує). Відсутній, нечитабельний
        або пошкоджений guard -> виняток; викликач перетворює його на Blocker/
        Warning finding. Часткове оголошення неможливе: спершу розбираємо й
        перевіряємо ВСІ визначення, лише потім оголошуємо.
    #>
    [CmdletBinding()]
    param(
        [string]$GuardPath = '',
        [switch]$Force
    )

    # Get-BRAVORuntimeFileHash — приватна залежність Test-BRAVORuntimeManifestIntegrity
    # (потрібна під час виклику, не оголошення).
    $required = @('Get-BRAVORuntimeFileHash', 'Test-BRAVORuntimeManifestIntegrity',
        'ConvertTo-BRAVOComparableVersion', 'Compare-BRAVOComparableVersion')

    if (-not $Force) {
        $allLoaded = $true
        foreach ($name in $required) {
            $existing = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
            # Глобальна функція з тим самим іменем не рахується: довіряємо лише
            # визначенню, яке модуль завантажив із guard комплекту.
            if ($null -eq $existing -or [string]$existing.ModuleName -ne 'BRAVO.Update') { $allLoaded = $false; break }
        }
        if ($allLoaded) { return }
    }

    if ([string]::IsNullOrWhiteSpace($GuardPath)) {
        $GuardPath = Join-Path $script:BRAVOUpdateToolkitRoot 'BRAVO_RUNTIME_GUARD.ps1'
    }
    if (-not [System.IO.File]::Exists($GuardPath)) {
        throw ('BRAVO.Update: довірений BRAVO_RUNTIME_GUARD.ps1 не знайдено: {0}' -f $GuardPath)
    }
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($GuardPath, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $parseErrors -and @($parseErrors).Count -gt 0) {
        throw ('BRAVO.Update: BRAVO_RUNTIME_GUARD.ps1 має синтаксичні помилки: {0}' -f @($parseErrors)[0].Message)
    }

    $definitions = @{}
    foreach ($name in $required) {
        $wanted = $name
        $node = $ast.Find({
                param($candidate)
                ($candidate -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($candidate.Name -eq $wanted)
            }, $true)
        if ($null -eq $node) {
            throw ('BRAVO.Update: BRAVO_RUNTIME_GUARD.ps1 не містить функції {0}.' -f $name)
        }
        # 'function Name' -> 'function script:Name': у dot-source-ному блоці
        # всередині функції це оголошує функцію в області модуля, а не в
        # локальній області завантажувача.
        $text = $node.Extent.Text
        $prefix = 'function ' + $name
        if (-not $text.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            throw ('BRAVO.Update: неочікуваний вигляд визначення {0} у BRAVO_RUNTIME_GUARD.ps1.' -f $name)
        }
        $definitions[$name] = [scriptblock]::Create('function script:' + $name + $text.Substring($prefix.Length))
    }
    foreach ($name in $required) {
        . $definitions[$name]
    }
}

function New-BRAVOUpdateDefaultAdapter {
    <#
    .SYNOPSIS
        Production adapter зовнішніх side effects (CONTRACTS §1). Тести та
        failure injection підставляють власні scriptblock-и під тими самими
        ключами.
    .DESCRIPTION
        Сигнатури scriptblock-ів (повертають PSCustomObject):
          InvokeGuard            param([string]$RuntimeRoot, [string]$LogPath)
                                 -> { ExitCode, Output, TimedOut, LogPath }
                                 (прямий запуск guard сам працює з -NoWrite, F5)
          InvokeSetupScheduler   param([string]$RuntimeRoot, [string]$LogPath)
                                 (BRAVO_SETUP.ps1 -Action Scheduler -SkipTestNotification -NoElevation -NoPause)
          InvokeSetupValidate    param([string]$RuntimeRoot, [string]$LogPath)
                                 (BRAVO_SETUP.ps1 -ValidateOnly -SkipAccessTest -SkipTestNotification -NoElevation -NoPause)
          InvokeSelfTest         param([string]$RuntimeRoot, [string]$LogPath)   (BRAVO_SELF_TEST.ps1 -NoPause)
                                 -> { ExitCode, Output, TimedOut, LogPath }
          Вивід дочірніх процесів маскується Protect-BRAVOLogSecret; -ExecutionPolicy RemoteSigned.
          GetManagedTasks        param([string]$TaskPath, [string]$RuntimeRoot)   (обидва необов'язкові)
                                 -> масив { Name, Path, Exists, State, Enabled, actionPath } (порожній, якщо задач немає);
                                 COM Schedule.Service, лише TaskPath і імена з ефективної конфігурації
          SetTaskEnabled         param([string]$TaskPath, [string]$Name, [bool]$Enabled, [string]$RuntimeRoot)
                                 -> { Success, Message }; TaskPath/ім'я поза ефективною конфігурацією -> виняток
          TestCredentialPresence param([string]$RuntimeRoot, [string]$Component)
                                 -> { Component, Presence (Found|Missing|Unknown), ExitCode }
                                 (BRAVO_CREDENTIALS_SETUP.ps1 -Action Test; код 0 = Found; секрет не читається й не передається)
          GetEffectiveConfiguration param([string]$RuntimeRoot)
                                 -> { Success, ExitCode, Configuration, Message }; Configuration — лише
                                 componentSettings/pathSettings/maintenanceSettings/schedulerSettings
                                 (БЕЗ credentialSettings), обчислені канонічним
                                 Import-BravoConfiguration у дочірньому процесі
                                 (глобальні змінні лоадера не потрапляють у процес engine).
          Now                    param() -> [datetime] UTC
        Якщо RuntimeRoot не передано, використовується ToolkitRoot (корінь
        інструментарію, з якого запущено engine).
    #>
    [CmdletBinding()]
    param(
        [string]$ToolkitRoot = $script:BRAVOUpdateToolkitRoot,
        # Корінь staging для робочих каталогів дочірніх скриптів елевованого engine (H1);
        # порожній = Get-BRAVOUpdateDefaultPaths.StagingRoot.
        [string]$StagingRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($StagingRoot)) { $StagingRoot = [string](Get-BRAVOUpdateDefaultPaths).StagingRoot }
    $adapter = @{}

    # Другий параметр $LogPath необов'язковий (Validation передає шлях логу в
    # <opDir>\logs; stub-адаптери з одним параметром його ігнорують).
    # Прямий запуск guard сам викликає Test-BRAVOVersionDowngrade -NoWrite (F5).
    $adapter.InvokeGuard = {
        param([string]$RuntimeRoot, [string]$LogPath)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        Invoke-BRAVOUpdateChildProcess -ScriptPath (Join-Path $RuntimeRoot 'BRAVO_RUNTIME_GUARD.ps1') `
            -ScriptArgument @('-RuntimeRoot', $RuntimeRoot, '-Mode', 'Enforce') -TimeoutSeconds 300 -LogPath $LogPath
    }
    $adapter.InvokeSetupScheduler = {
        param([string]$RuntimeRoot, [string]$LogPath)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        Invoke-BRAVOUpdateChildProcess -ScriptPath (Join-Path $RuntimeRoot 'BRAVO_SETUP.ps1') `
            -ScriptArgument @('-Action', 'Scheduler', '-SkipTestNotification', '-NoElevation', '-NoPause') -TimeoutSeconds 900 -LogPath $LogPath
    }
    $adapter.InvokeSetupValidate = {
        param([string]$RuntimeRoot, [string]$LogPath)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        Invoke-BRAVOUpdateChildProcess -ScriptPath (Join-Path $RuntimeRoot 'BRAVO_SETUP.ps1') `
            -ScriptArgument @('-ValidateOnly', '-SkipAccessTest', '-SkipTestNotification', '-NoElevation', '-NoPause') -TimeoutSeconds 900 -LogPath $LogPath
    }
    $adapter.InvokeSelfTest = {
        param([string]$RuntimeRoot, [string]$LogPath)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        Invoke-BRAVOUpdateChildProcess -ScriptPath (Join-Path $RuntimeRoot 'BRAVO_SELF_TEST.ps1') `
            -ScriptArgument @('-NoPause') -TimeoutSeconds 3600 -LogPath $LogPath
    }
    # Посилання на фінальний (замкнений) adapter: GetManagedTasks/SetTaskEnabled
    # викликають його GetEffectiveConfiguration, щоб область задач (TaskPath +
    # імена) визначав канонічний loader, а не hardcode (ENGINE_DESIGN.md, 5).
    $holder = @{ Adapter = $null }

    $adapter.GetManagedTasks = {
        param([string]$TaskPath, [string]$RuntimeRoot)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        $getConfiguration = $holder.Adapter['GetEffectiveConfiguration']
        $effective = & $getConfiguration $RuntimeRoot
        if (($null -eq $effective) -or (-not [bool]$effective.Success)) {
            throw 'BRAVO.Update: ефективну конфігурацію scheduler не прочитано (fail closed).'
        }
        $scope = Get-BRAVOUpdateManagedTaskScope -Configuration $effective.Configuration
        # Явний TaskPath поза ефективним — не наша область: виняток, а не порожній результат.
        if ((-not [string]::IsNullOrWhiteSpace($TaskPath)) -and
            (-not [string]::Equals((ConvertTo-BRAVOUpdateTaskPath -TaskPath $TaskPath), $scope.TaskPath, [StringComparison]::OrdinalIgnoreCase))) {
            throw "BRAVO.Update: TaskPath '$TaskPath' не є каталогом керованих задач."
        }
        $comPath = $scope.TaskPath
        if ($comPath -ne '\') { $comPath = $comPath.TrimEnd('\') }
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $folder = $null
        try { $folder = $service.GetFolder($comPath) } catch { $folder = $null }
        if ($null -eq $folder) { return @() }
        $stateNames = @{ 0 = 'Unknown'; 1 = 'Disabled'; 2 = 'Queued'; 3 = 'Ready'; 4 = 'Running' }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($name in $scope.Names) {
            $task = $null
            try { $task = $folder.GetTask($name) } catch { $task = $null }
            if ($null -eq $task) { continue }
            # Шлях скрипта з аргументів дії (-File "..."): Discovery виводить із нього кандидатів root.
            $actionPath = ''
            try {
                foreach ($action in $task.Definition.Actions) {
                    if ([int]$action.Type -ne 0) { continue }
                    $arguments = [string]$action.Arguments
                    if ($arguments -match '-File\s+"([^"]+)"') { $actionPath = $Matches[1] }
                    elseif ($arguments -match '-File\s+(\S+)') { $actionPath = $Matches[1] }
                    else { $actionPath = [string]$action.Path }
                    break
                }
            } catch { $actionPath = '' }
            $stateValue = [int]$task.State
            $stateText = 'Unknown'
            if ($stateNames.ContainsKey($stateValue)) { $stateText = [string]$stateNames[$stateValue] }
            $rows.Add([pscustomobject]@{
                Name       = [string]$name
                Path       = $scope.TaskPath
                Exists     = $true
                State      = $stateText
                Enabled    = [bool]$task.Enabled
                actionPath = $actionPath
            })
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($task)
        }
        return @($rows.ToArray())
    }
    $adapter.SetTaskEnabled = {
        param([string]$TaskPath, [string]$Name, [bool]$Enabled, [string]$RuntimeRoot)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        $getConfiguration = $holder.Adapter['GetEffectiveConfiguration']
        $effective = & $getConfiguration $RuntimeRoot
        if (($null -eq $effective) -or (-not [bool]$effective.Success)) {
            throw 'BRAVO.Update: ефективну конфігурацію scheduler не прочитано (fail closed).'
        }
        $scope = Get-BRAVOUpdateManagedTaskScope -Configuration $effective.Configuration
        # Лише TaskPath з ефективної конфігурації і лише керовані імена, інакше виняток.
        if (-not [string]::Equals((ConvertTo-BRAVOUpdateTaskPath -TaskPath $TaskPath), $scope.TaskPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "BRAVO.Update: TaskPath '$TaskPath' не є каталогом керованих задач."
        }
        $managed = $false
        foreach ($known in $scope.Names) { if ([string]::Equals($known, $Name, [StringComparison]::OrdinalIgnoreCase)) { $managed = $true } }
        if (-not $managed) { throw "BRAVO.Update: задача '$Name' не є керованою." }
        $comPath = $scope.TaskPath
        if ($comPath -ne '\') { $comPath = $comPath.TrimEnd('\') }
        $task = $null
        try {
            $service = New-Object -ComObject 'Schedule.Service'
            $service.Connect()
            $task = $service.GetFolder($comPath).GetTask($Name)
            $task.Enabled = $Enabled
            # Перевірка наслідку: COM міг не застосувати зміну без винятку.
            $confirmed = ([bool]$service.GetFolder($comPath).GetTask($Name).Enabled -eq $Enabled)
            if (-not $confirmed) { return [pscustomobject]@{ Success = $false; Message = "Task Scheduler не підтвердив зміну стану '$Name'." } }
            [pscustomobject]@{ Success = $true; Message = '' }
        } catch {
            [pscustomobject]@{ Success = $false; Message = [string]$_.Exception.Message }
        } finally {
            if ($null -ne $task) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($task) }
        }
    }
    $adapter.TestCredentialPresence = {
        param([string]$RuntimeRoot, [string]$Component)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        $run = Invoke-BRAVOUpdateChildProcess -ScriptPath (Join-Path $RuntimeRoot 'BRAVO_CREDENTIALS_SETUP.ps1') `
            -ScriptArgument @('-Action', 'Test', '-Component', $Component) -TimeoutSeconds 120
        $presence = 'Unknown'
        if (-not $run.TimedOut) {
            if ($run.ExitCode -eq 0) { $presence = 'Found' } elseif ($run.ExitCode -gt 0) { $presence = 'Missing' }
        }
        [pscustomobject]@{ Component = $Component; Presence = $presence; ExitCode = $run.ExitCode }
    }
    $adapter.GetEffectiveConfiguration = {
        param([string]$RuntimeRoot)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        # Дочірній скрипт пишеться у захищений робочий каталог UTF-8 З BOM, шляхи
        # передаються аргументами (не вбудовуються в текст: кирилиця/апостроф).
        # H1: елевований процес виконує скрипт ЛИШЕ з <StagingRoot>\<guid>\work
        # (захищений корінь engine), а не з %TEMP%, куди може писати неелевований
        # код того ж облікового запису. Неелевоване читання (Discovery у GUI) не
        # чіпає ProgramData і працює у власному каталозі користувача.
        $workRoot = $StagingRoot
        if (-not (Test-BRAVOUpdateWorkerIsAdministrator)) { $workRoot = Join-Path ([IO.Path]::GetTempPath()) 'BRAVO_UPDATE_WORK' }
        $work = New-BRAVOUpdateChildWorkDirectory -Root $workRoot
        if (-not $work.Success) {
            return [pscustomobject]@{ Success = $false; ExitCode = -1; Configuration = $null; Message = ('Робочий каталог не створено: ' + (@($work.Problems) -join '; ')) }
        }
        try {
            $childPath = Join-Path $work.WorkDirectory 'Get-Effective.ps1'
            $resultPath = Join-Path $work.WorkDirectory 'effective.json'
            $lines = @(
                'param([string]$RuntimeRoot, [string]$ResultPath)',
                'Set-StrictMode -Version 2.0',
                '$ErrorActionPreference = ''Stop''',
                '. (Join-Path $RuntimeRoot ''BRAVO_CONFIG_LOADER.ps1'')',
                '$null = Import-BravoConfiguration -ConfigRoot $RuntimeRoot -RuntimeRoot $RuntimeRoot -DisallowLegacyPrimaryAutoDetect -PassThru',
                '$snapshot = [ordered]@{}',
                'foreach ($name in @(''componentSettings'', ''pathSettings'', ''maintenanceSettings'', ''schedulerSettings'')) {',
                '    $variable = Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue',
                '    $snapshot[$name] = if ($null -ne $variable) { $variable.Value } else { $null }',
                '}',
                '$snapshot | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ResultPath -Encoding UTF8'
            )
            [IO.File]::WriteAllText($childPath, ([string]::Join([Environment]::NewLine, $lines)), (New-Object System.Text.UTF8Encoding($true)))
            $run = Invoke-BRAVOUpdateChildProcess -ScriptPath $childPath -ScriptArgument @($RuntimeRoot, $resultPath) -TimeoutSeconds 120
            if ($run.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
                return [pscustomobject]@{ Success = $false; ExitCode = $run.ExitCode; Configuration = $null; Message = $run.Output }
            }
            $configuration = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
            return [pscustomobject]@{ Success = $true; ExitCode = 0; Configuration = $configuration; Message = '' }
        } catch {
            return [pscustomobject]@{ Success = $false; ExitCode = -1; Configuration = $null; Message = [string]$_.Exception.Message }
        } finally {
            Remove-BRAVOUpdateChildWorkDirectory -WorkInfo $work
        }
    }
    $adapter.Now = {
        [datetime]::UtcNow
    }

    # Замикання фіксує $ToolkitRoot; scriptblock-и лишаються в області модуля
    # й бачать Invoke-BRAVOUpdateChildProcess.
    $closed = @{}
    foreach ($key in @($adapter.Keys)) { $closed[$key] = $adapter[$key].GetNewClosure() }
    $holder.Adapter = $closed
    return $closed
}
