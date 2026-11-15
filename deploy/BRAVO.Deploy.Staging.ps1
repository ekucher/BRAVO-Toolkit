# Приватний staging-каталог для deploy\Update-BRAVOServer.ps1 (#545, AUD-AG14-001).
#
# ПРОБЛЕМА, ЯКУ ВІН ЗАКРИВАЄ. Раніше оновлювач розпаковував комплект у
# C:\Temp\BRAVO_UPDATE, створений звичайним New-Item. Каталог C:\Temp може
# створити будь-який локальний користувач і стати його власником, а отже
# підмінити архів між Get-FileHash і Expand-Archive чи staged-файли перед
# robocopy в %ProgramFiles%. Далі цей код виконується від SYSTEM (TOCTOU).
#
# КОНТРАКТ.
#   * Каталог щоразу новий, з випадковою назвою, в $env:SystemRoot\Temp. Не в
#     %TEMP%: там процес того самого користувача без елевації має
#     FILE_DELETE_CHILD на батьківський каталог і міг би перейменувати
#     захищений каталог та підкласти свій.
#   * Каталог створюється ОДРАЗУ з явним захищеним DACL (CreateDirectory з
#     DirectorySecurity, не «New-Item, потім Set-Acl»): успадкування вимкнено,
#     FullControl лише BUILTIN\Administrators (S-1-5-32-544) і NT AUTHORITY\SYSTEM
#     (S-1-5-18), власник — Administrators. Результат перечитується Get-Acl;
#     наявний каталог, будь-яке зайве правило чи інший власник — відмова.
#   * Архів копіюється в цей каталог ДО звірки SHA-256 і розпаковується з тієї
#     самої копії: перевірене й розпаковане — ті самі байти.
#   * Перед першою зміною runtime staged-дерево ще раз звіряється з
#     RUNTIME_MANIFEST.json комплекту (Test-BRAVODeployRuntimeMatchesManifest у
#     BRAVO.Deploy.Rollback.ps1).
#
# Той самий патерн, що New-BRAVOInstallPrivateDirectory у
# Install-BRAVOServer.ps1 (#434). Інсталятор свою копію поки не переносить сюди:
# її поведінку закріплено self-test-ами BackupDestinations.

Set-StrictMode -Version 2.0

function Get-BRAVODeployPrivateDirectoryBase {
    $systemRoot = $env:SystemRoot
    $privateBase = $(if ([string]::IsNullOrWhiteSpace($systemRoot)) { '' } else { Join-Path $systemRoot 'Temp' })
    if ([string]::IsNullOrEmpty($privateBase) -or -not (Test-Path -LiteralPath $privateBase -PathType Container)) {
        throw ('Немає каталогу для приватного staging: ' +
            $(if ([string]::IsNullOrEmpty($privateBase)) { '$env:SystemRoot не задано' } else { $privateBase }) +
            '. Нічого не змінено. Перевірте $env:SystemRoot\Temp на сервері й повторіть запуск.')
    }
    return $privateBase
}

function New-BRAVODeployPrivateDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (Test-Path -LiteralPath $Path) { throw 'каталог уже існує.' }
        $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $allowedSids = @($administratorsSid.Value, $systemSid.Value)
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetOwner($administratorsSid)
        $security.SetAccessRuleProtection($true, $false)
        foreach ($allowedSid in @($administratorsSid, $systemSid)) {
            $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $allowedSid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)))
        }
        # .NET Framework (Windows PowerShell 5.1): Directory.CreateDirectory(path, DirectorySecurity);
        # .NET (PowerShell 7): той самий виклик — FileSystemAclExtensions.CreateDirectory.
        $createWithSecurity = [System.IO.Directory].GetMethod('CreateDirectory',
            [Type[]]@([string], [System.Security.AccessControl.DirectorySecurity]))
        if ($null -ne $createWithSecurity) {
            [void][System.IO.Directory]::CreateDirectory($Path, $security)
        } else {
            [void][System.IO.FileSystemAclExtensions]::CreateDirectory($security, $Path)
        }
        $actual = Get-Acl -LiteralPath $Path
        $problems = @()
        if (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $problems += 'каталог є reparse point'
        }
        if (-not $actual.AreAccessRulesProtected) { $problems += 'успадкування прав не вимкнено' }
        $ownerSid = [string]$actual.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($ownerSid -ne $administratorsSid.Value) { $problems += ('власник ' + $ownerSid + ', а не BUILTIN\Administrators') }
        $rules = @($actual.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        foreach ($rule in $rules) {
            $ruleSid = [string]$rule.IdentityReference.Value
            if ($rule.IsInherited -or $allowedSids -notcontains $ruleSid -or
                $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
                ($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne [System.Security.AccessControl.FileSystemRights]::FullControl) {
                $problems += ('зайве правило ' + $ruleSid + ' ' + [string]$rule.AccessControlType + ' ' + [string]$rule.FileSystemRights)
            }
        }
        foreach ($allowedSidValue in $allowedSids) {
            if (@($rules | Where-Object { [string]$_.IdentityReference.Value -eq $allowedSidValue }).Count -eq 0) {
                $problems += ('немає правила для ' + $allowedSidValue)
            }
        }
        if (@(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) { $problems += 'каталог не порожній' }
        if ($problems.Count -gt 0) { throw ('DACL не той: ' + ($problems -join '; ') + '.') }
    } catch {
        throw ('Приватний staging-каталог ' + $Path + ' не вдалося створити із захищеними правами ' +
            '(без успадкування; лише BUILTIN\Administrators і NT AUTHORITY\SYSTEM): ' + $_.Exception.Message +
            ' Нічого не змінено. Запустіть скрипт у елевованій консолі адміністратора й повторіть запуск.')
    }
}
