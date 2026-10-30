# BRAVO.Update.Preflight — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# INS-021 (deployment preflight) та INS-022 (config migration gate).
# Контракт: docs\installer\CONTRACTS.md §4 (PreflightResult) і §2 (Finding).
#
# Інваріанти частини:
#   * Preflight ЛИШЕ ЧИТАЄ: не пише файлів, не бере locks (лише канонічна
#     проба Test-BRAVOUpdateOperationLockActive: відкриття без запису й негайне
#     закриття), нікого не завершує.
#   * Жодного виводу в консоль: результат — об'єкти.
#   * Fail closed: те, що неможливо довести (журнал, lock, диск, шлях), —
#     Blocker, а не припущення «все гаразд». Виняток — операція Diagnose:
#     звіт будується завжди, тож Blocker там знижується до Warning.
#   * BRAVO.config — це СКРИПТ. Тут він ніколи не виконується, не
#     dot-source-иться і не читається: достатньо факту наявності файлу.
#     BRAVO.local.config читається лише невиконуючим AST-парсером
#     (ConvertFrom-BRAVOConfigurationDataFileText) із toolkit-копії модуля.
#
# Тестові seams (необов'язкові ключі adapter-а, поза контрактом §1):
#   GetPreflightEnvironment — scriptblock, що повертає об'єкт середовища
#   (OsTier, OsDescription, PowerShellVersion, PowerShellEdition,
#   DotNetRelease, Is64BitOS, IsAdministrator). Без нього береться реальне
#   середовище. GetManagedTasks — ключ контракту §1.

Set-StrictMode -Version 2.0

# Запас вільного місця понад RequiredBytes: розпакування/копіювання не має
# довести том до нуля (журнал, лог, тимчасові файли ОС).
$script:BRAVOPreflightReserveBytes = [decimal]536870912
# .NET Framework 4.8 (release 528040) — baseline канонічного toolkit.
$script:BRAVOPreflightMinDotNetRelease = 528040
# Файли, наявність яких означає «у каталозі вже є BRAVO». Перелік навмисно
# ширший за VERSION.json: частково знесений/пошкоджений runtime теж не можна
# «встановлювати поверх» як порожній каталог.
$script:BRAVOPreflightRuntimeMarker = @(
    'VERSION.json', 'RUNTIME_MANIFEST.json', 'BRAVO_SETUP.ps1',
    'BRAVO_RUNTIME_GUARD.ps1', 'BRAVO_CONFIG_LOADER.ps1',
    'BRAVO.config', 'BRAVO.local.config'
)
# Допустимий розмір BRAVO.local.config для читання: файл — це короткий
# hashtable; великий файл — ознака чужого вмісту, парсити його не варто.
$script:BRAVOPreflightMaxLocalConfigBytes = 1048576
# Операторські runbook-и міграції (джерело правила INS-022).
$script:BRAVOPreflightMigrationRunbook = 'docs\BRAVO_CONFIG_V2_PILOT_RUNBOOK.md (ручний fallback: docs\BRAVO_CONFIG_V2_PILOT_MIGRATION_RUNBOOK_20260916.md)'

function Add-BRAVOPreflightFinding {
    # Додає Finding у колекцію. Для Diagnose Blocker знижується до Warning:
    # діагностичний звіт не має блокуватись нічим — оператору потрібна
    # повна картина саме тоді, коли середовище зламане.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$List,
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Meaning = '',
        [string]$Action = '',
        [string]$Details = '',
        [AllowNull()][object]$ExitCodeHint = $null
    )

    $effectiveSeverity = $Severity
    $effectiveHint = $ExitCodeHint
    $effectiveDetails = $Details
    if ($Operation -eq 'Diagnose' -and $Severity -eq 'Blocker') {
        $effectiveSeverity = 'Warning'
        $effectiveHint = $null
        $effectiveDetails = ("$Details (Diagnose: лише звіт, блокування не застосовується)").Trim()
    }
    [void]$List.Add((New-BRAVOUpdateFinding -Id $Id -Severity $effectiveSeverity -Title $Title `
            -Meaning $Meaning -Action $Action -Details $effectiveDetails -ExitCodeHint $effectiveHint))
}

function Get-BRAVOPreflightProperty {
    # Безпечне читання властивості (StrictMode 2.0 кидає на відсутній).
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-BRAVOPreflightFullPath {
    # Нормалізований повний шлях без кінцевого роздільника (крім кореня
    # диска) або $null, якщо шлях не розбирається.
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $null
    }
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
    return $full
}

function Test-BRAVOPreflightPathInside {
    # $true, якщо Child збігається з Parent або лежить усередині нього.
    # Порівняння з роздільником наприкінці: 'C:\Prog' не «всередині»
    # 'C:\Pro'. Регістр ігнорується (NTFS).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Child,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $childFull = Get-BRAVOPreflightFullPath -Path $Child
    $parentFull = Get-BRAVOPreflightFullPath -Path $Parent
    if ($null -eq $childFull -or $null -eq $parentFull) { return $false }
    if ([string]::Equals($childFull, $parentFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $parentPrefix = $parentFull.TrimEnd('\') + '\'
    return $childFull.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-BRAVOPreflightPathProblem {
    # Спільні перевірки шляху: абсолютний локальний, не UNC/device, без '..',
    # без reparse point (сам шлях і всі наявні предки), на fixed-диску.
    # Повертає масив українських проблем; порожній — шлях придатний.
    # Reparse point небезпечний тим, що staging/backup/deploy могли б
    # непомітно потрапити в інше місце (junction у системний каталог).
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Path)

    $problems = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Path)) {
        [void]$problems.Add('шлях порожній')
        return $problems.ToArray()
    }
    if ($Path -match '^[\\/]{2}') {
        [void]$problems.Add('мережевий (UNC) або device-шлях неприпустимий; потрібен локальний диск')
        return $problems.ToArray()
    }
    if ($Path -notmatch '^[A-Za-z]:[\\/]') {
        [void]$problems.Add('шлях має бути абсолютним з літерою локального диска')
        return $problems.ToArray()
    }
    foreach ($segment in ($Path -split '[\\/]')) {
        if ($segment -eq '..' -or $segment -eq '.') {
            [void]$problems.Add("шлях містить сегмент '$segment'; потрібен нормалізований шлях")
            return $problems.ToArray()
        }
    }
    $full = Get-BRAVOPreflightFullPath -Path $Path
    if ($null -eq $full) {
        [void]$problems.Add('шлях має недопустимі символи')
        return $problems.ToArray()
    }

    # Тип диска: лише Fixed (знімні та мережеві томи можуть зникнути
    # посеред операції).
    try {
        $drive = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($full))
        if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
            [void]$problems.Add("диск $($drive.Name) має тип $($drive.DriveType); потрібен локальний фіксований диск")
        }
    } catch {
        [void]$problems.Add('не вдалося визначити тип диска')
    }

    # Reparse point на самому шляху або будь-якому наявному предку.
    $cursor = $full
    $guard = 0
    while (-not [string]::IsNullOrEmpty($cursor) -and $guard -lt 64) {
        $guard++
        $exists = [System.IO.Directory]::Exists($cursor) -or [System.IO.File]::Exists($cursor)
        if ($exists) {
            try {
                $attributes = [System.IO.File]::GetAttributes($cursor)
                if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    [void]$problems.Add("'$cursor' є reparse point (junction/symlink); це неприпустимо")
                    break
                }
            } catch {
                [void]$problems.Add("не вдалося прочитати атрибути '$cursor'")
                break
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $problems.ToArray()
}

function Get-BRAVOPreflightSystemPathProblem {
    # Runtime root не може бути коренем диска, каталогом Windows чи самим
    # каталогом Program Files / ProgramData (там уживаються чужі продукти).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = Get-BRAVOPreflightFullPath -Path $Path
    if ($null -eq $full) { return @() }
    $problems = New-Object System.Collections.Generic.List[string]
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::Equals($full.TrimEnd('\'), $root.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        [void]$problems.Add('корінь диска не може бути каталогом BRAVO')
    }
    $windowsDir = [System.Environment]::GetEnvironmentVariable('SystemRoot')
    if (-not [string]::IsNullOrWhiteSpace($windowsDir) -and (Test-BRAVOPreflightPathInside -Child $full -Parent $windowsDir)) {
        [void]$problems.Add('каталог Windows і його вкладені каталоги заборонені')
    }
    foreach ($variableName in @('ProgramFiles', 'ProgramFiles(x86)', 'ProgramData')) {
        $bare = [System.Environment]::GetEnvironmentVariable($variableName)
        if ([string]::IsNullOrWhiteSpace($bare)) { continue }
        $bareFull = Get-BRAVOPreflightFullPath -Path $bare
        if ($null -ne $bareFull -and [string]::Equals($full, $bareFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$problems.Add("сам каталог $variableName не може бути каталогом BRAVO (потрібен підкаталог)")
        }
    }
    return $problems.ToArray()
}

function Get-BRAVOPreflightFreeBytes {
    # Вільне місце тому для шляху (шлях може ще не існувати — береться
    # корінь диска) через канонічний Get-BRAVOUpdateFreeSpace (Staging):
    # {Volume, AvailableFreeBytes, Error}. $null/Error означає «невідомо»
    # (fail closed у викликача: DiskSpace = Blocker); іншого джерела немає.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = Get-BRAVOPreflightFullPath -Path $Path
    if ($null -eq $full) { return $null }
    $value = Get-BRAVOUpdateFreeSpace -Path $full
    $bytes = Get-BRAVOPreflightProperty -InputObject $value -Name 'AvailableFreeBytes'
    if ($null -eq $bytes) { return $null }
    return [decimal]$bytes
}

function Get-BRAVOUpdatePreflightEnvironment {
    # Знімок середовища для preflight: ОС/PowerShell/.NET/розрядність/права.
    # Повністю замінюється adapter-ом (GetPreflightEnvironment) у тестах.
    [CmdletBinding()]
    param([string]$ToolkitRoot)

    $dotNetRelease = 0
    try {
        $dotNetRelease = [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' `
                -Name 'Release' -ErrorAction Stop).Release
    } catch {
        $dotNetRelease = 0
    }

    $tier = 'Unknown'
    $tierDescription = ''
    try {
        if ($null -eq (Get-Command -Name 'Get-BRAVOOSSupportTier' -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $ToolkitRoot 'modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1') -ErrorAction Stop
        }
        $tierInfo = Get-BRAVOOSSupportTier -DotNetRelease $dotNetRelease
        $tier = [string](Get-BRAVOPreflightProperty -InputObject $tierInfo -Name 'Tier' -Default 'Unknown')
        $tierDescription = ('{0} (версія {1})' -f
            (Get-BRAVOPreflightProperty -InputObject $tierInfo -Name 'OperatingSystem' -Default '?'),
            (Get-BRAVOPreflightProperty -InputObject $tierInfo -Name 'OperatingSystemVersion' -Default '?'))
    } catch {
        $tier = 'Unknown'
        $tierDescription = "не вдалося визначити рівень підтримки: $($_.Exception.Message)"
    }

    $isAdmin = $false
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $isAdmin = $false
    }

    $edition = ''
    $psEditionProperty = $PSVersionTable.PSObject.Properties['PSEdition']
    if ($null -ne $psEditionProperty) { $edition = [string]$psEditionProperty.Value }
    # PSEdition відсутній у PowerShell 4 і раніше — це Desktop за визначенням.
    if ([string]::IsNullOrEmpty($edition)) { $edition = 'Desktop' }

    return [pscustomobject]@{
        OsTier            = $tier
        OsDescription     = $tierDescription
        PowerShellVersion = [version]$PSVersionTable.PSVersion
        PowerShellEdition = $edition
        DotNetRelease     = [int]$dotNetRelease
        Is64BitOS         = [System.Environment]::Is64BitOperatingSystem
        IsAdministrator   = [bool]$isAdmin
    }
}

function Format-BRAVOPreflightLockHolder {
    # Опис власника lock-а для оператора — лише operation/pid/startedAt, без
    # решти полів holder-а (вони можуть містити зайве). Holder — результат
    # Test-BRAVOUpdateOperationLockActive (може бути $null).
    [CmdletBinding()]
    param([AllowNull()][object]$Holder)

    if ($null -eq $Holder) { return '' }
    $parts = foreach ($field in @('operation', 'pid', 'startedAt')) {
        $value = Get-BRAVOPreflightProperty -InputObject $Holder -Name $field
        "$field=$(if ($null -ne $value) { $value } else { '?' })"
    }
    return (@($parts) -join '; ')
}

function Read-BRAVOUpdateLocalConfigData {
    # Невиконуюче читання BRAVO.local.config (data-only AST-парсер із
    # toolkit-копії модуля Configuration). Повертає
    # { Present; IsValid; Problems[]; EffectiveSchemaVersion }.
    # Без глобальних змінних і без завантаження loader-а (він має побічні
    # ефекти) — лише чисті функції парсера та схеми.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ToolkitRoot
    )

    $localPath = Join-Path $RuntimeRoot 'BRAVO.local.config'
    $result = [pscustomobject]@{ Present = $false; IsValid = $true; Problems = @(); EffectiveSchemaVersion = $null }
    if (-not (Test-Path -LiteralPath $localPath)) { return $result }
    $result.Present = $true
    $problems = New-Object System.Collections.Generic.List[string]
    try {
        if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
            throw 'BRAVO.local.config має бути файлом'
        }
        $item = Get-Item -LiteralPath $localPath -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'BRAVO.local.config є reparse point; читання відхилено'
        }
        if ($item.Length -gt $script:BRAVOPreflightMaxLocalConfigBytes) {
            throw "BRAVO.local.config завеликий ($($item.Length) байт) для data-only hashtable"
        }
        foreach ($moduleName in @('BRAVO.Configuration', 'BRAVO.Configuration.DataFile', 'BRAVO.Configuration.Schema')) {
            $modulePath = Join-Path $ToolkitRoot "modules\BRAVO.Configuration\$moduleName.psd1"
            # Без -Force: повторне завантаження вже імпортованого модуля
            # не виконує його код вдруге.
            Import-Module -Name $modulePath -ErrorAction Stop
        }
        $text = [System.IO.File]::ReadAllText($localPath, (New-Object System.Text.UTF8Encoding($false)))
        $data = ConvertFrom-BRAVOConfigurationDataFileText -Text $text -SourceName $localPath
        $version = Resolve-BRAVOConfigurationSchemaVersion -DataFileContent $data -SourceName $localPath
        $result.EffectiveSchemaVersion = $version.EffectiveVersion
        $schema = Get-BRAVOConfigurationSchema -ReferenceConfiguration (Get-BRAVODefaultConfiguration)
        $verdict = Test-BRAVOConfigurationOverrideSchema -DotPathOverrides $version.Overrides -Schema $schema
        if (-not $verdict.IsValid) {
            foreach ($violation in $verdict.Violations) {
                [void]$problems.Add(([string](Get-BRAVOPreflightProperty -InputObject $violation -Name 'Path' -Default '?')) +
                    ': значення не відповідає схемі')
            }
        }
    } catch {
        [void]$problems.Add($_.Exception.Message)
    }
    $result.Problems = $problems.ToArray()
    $result.IsValid = ($problems.Count -eq 0)
    return $result
}

function Test-BRAVOConfigMigrationBlocker {
    <#
    .SYNOPSIS
        Migration gate (INS-022): чи блокує legacy-конфігурація Update/Repair.
    .DESCRIPTION
        Правило (fail closed): legacy BRAVO.config (або BRAVO.config.local)
        у runtime root І відсутній доказ завершеної operator-керованої
        міграції => Blocked.

        Що таке «міграція завершена» у Configuration v2 / 5.3 (джерела):
        * docs\design\BRAVO_CONFIGURATION_V2_COMPLETION.md (преамбула, Issue
          #216): у production 5.3 BRAVO.config не читається і не
          виконується; legacy-файл допустимий лише для підтримуваної
          міграції 5.2->5.3, міграційних тестів, доказів паритету й
          історичної документації; пакет 5.3 його не містить.
        * docs\BRAVO_CONFIG_V2_PILOT_MIGRATION_RUNBOOK_20260916.md (Крок 6)
          і docs\BRAVO_CONFIG_V2_PILOT_RUNBOOK.md: міграція завершується
          свідомим видаленням BRAVO.config оператором ПІСЛЯ паритету
          ефективних знімків (A<->C `[SUCCESS]`) та acceptance; докази
          (snapshot-*, backup-manifest.json, acceptance.json) лежать у
          каталозі доказів ПОЗА runtime root.
        * Той самий design-документ (розділ про native-v2): валідний вміст
          файлу сам по собі НЕ є доказом походження, а активний legacy-файл
          домінує над будь-яким «shortcut».

        Звідси єдиний перевірний у runtime root доказ завершеної міграції —
        ВІДСУТНІСТЬ legacy-файлу (Крок 6). Журнал міграції в repo лише
        спроєктовано (PLANNED), прочитати його неможливо, тому наявність
        legacy-файлу без такого доказу тут завжди блокує, а текст дії веде
        до runbook-а. Installer міграцію не виконує і файл не видаляє.

        Функція НІКОЛИ не виконує, не dot-source-ить і не читає BRAVO.config
        (це скрипт): лише Test-Path. Нічого не пише.
    .PARAMETER RuntimeRoot
        Каталог комплекту, де шукається legacy-файл.
    .OUTPUTS
        { Blocked; Reasons[]; Findings[] } (Findings — Finding із
        id Preflight.LegacyConfig, severity Blocker, exitCodeHint 30).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $findings = New-Object System.Collections.Generic.List[object]
    foreach ($legacyName in @('BRAVO.config', 'BRAVO.config.local')) {
        $legacyPath = Join-Path $RuntimeRoot $legacyName
        # Будь-який об'єкт з таким іменем (файл, каталог, reparse point)
        # вважається legacy-станом: безпечніше заблокувати, ніж вгадувати.
        if (-not (Test-Path -LiteralPath $legacyPath)) { continue }
        $reason = "У runtime root є legacy-файл '$legacyName'; доказу завершеної міграції (видалення після паритету, Крок 6 runbook-а) немає."
        [void]$reasons.Add($reason)
        [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Preflight.LegacyConfig' -Severity 'Blocker' `
                -Title "Знайдено legacy-конфігурацію '$legacyName'" `
                -Meaning 'Версія 5.3 не читає і не виконує BRAVO.config. Поки site-значення не перенесено в BRAVO.local.config, оновлення чи відновлення може змінити ефективну конфігурацію.' `
                -Action "Виконайте операторську міграцію Configuration v2 за $script:BRAVOPreflightMigrationRunbook, потім повторіть перевірку. Installer файл не змінює і не видаляє." `
                -Details "path=$legacyPath; source=BRAVO_CONFIGURATION_V2_COMPLETION (Issue #216)" `
                -ExitCodeHint 30))
    }

    return [pscustomobject]@{
        Blocked  = ($reasons.Count -gt 0)
        Reasons  = $reasons.ToArray()
        Findings = $findings.ToArray()
    }
}

function Get-BRAVOPreflightFingerprint {
    # Fingerprint: SHA-256 канонічного JSON від id+severity усіх Finding і
    # ключових входів. Час і details не входять — інакше відбиток
    # змінювався б між двома однаковими запусками.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Finding,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$KeyInput
    )

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $Finding) {
        [void]$items.Add([ordered]@{
                id       = [string](Get-BRAVOPreflightProperty -InputObject $entry -Name 'id')
                severity = [string](Get-BRAVOPreflightProperty -InputObject $entry -Name 'severity')
            })
    }
    $payload = [ordered]@{
        findings = $items.ToArray()
        inputs   = $KeyInput
    }
    return (Get-BRAVOUpdateSha256Text -Text (Get-BRAVOUpdateCanonicalJson -InputObject $payload))
}

function Test-BRAVODeploymentPreflight {
    <#
    .SYNOPSIS
        Preflight розгортання (INS-021): повертає PreflightResult (§4).
    .DESCRIPTION
        Лише читає. Не бере locks і нічого не завершує. Кожна перевірка —
        Finding 'Preflight.<X>'. Для Diagnose Blocker знижується до Warning.
    .PARAMETER Operation
        Install | Update | Repair | Diagnose.
    .PARAMETER OperationLockPath
        Шлях канонічного BRAVO_OPERATION.lock (Archive/Maintenance).
    .PARAMETER RequiredBytes
        Оцінка потрібного місця; до неї додається резерв 512 MB на кожен том.
    .PARAMETER RequireElevation
        Для mutation без прав адміністратора — Blocker (36), інакше Warning.
    .PARAMETER InstallationState
        Результат Get-BRAVOInstallationState (необов'язково); з нього береться
        лише integrity.
    .PARAMETER Adapter
        Hashtable scriptblock-ів (§1): GetManagedTasks; тестові seams описано
        у заголовку файлу.
    .PARAMETER ToolkitRoot
        Корінь toolkit (довірені модулі схеми/сумісності); типово — корінь
        модуля.
    .PARAMETER AllowOpenJournal
        Для recovery: відкритий журнал не блокує (його і треба відновити).
    .PARAMETER IgnoreOwnLocks
        Викликач сам тримає lifecycle/operation lock (повторний preflight у
        worker-і після захоплення): їх не вважати зайнятими.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair', 'Diagnose')][string]$Operation,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$LockRoot,
        [Parameter(Mandatory = $true)][string]$OperationLockPath,
        [Parameter(Mandatory = $true)][string]$StagingRoot,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [long]$RequiredBytes = 0,
        [switch]$RequireElevation,
        [AllowNull()][object]$InstallationState = $null,
        [AllowNull()][hashtable]$Adapter = $null,
        [string]$ToolkitRoot = $script:BRAVOUpdateToolkitRoot,
        [switch]$AllowOpenJournal,
        [switch]$IgnoreOwnLocks,
        # Область Repair (All|Runtime|Scheduler); для інших операцій не використовується.
        [string]$Scope = 'All'
    )

    $list = New-Object System.Collections.Generic.List[object]
    $isMutation = ($Operation -ne 'Diagnose')
    $adapterTable = $Adapter
    if ($null -eq $adapterTable) { $adapterTable = @{} }
    # Цілісність цілі потрібна вже для вибору джерела області задач (Repair пошкодженого runtime).
    $earlyIntegrity = Get-BRAVOPreflightProperty -InputObject $InstallationState -Name 'integrity'
    $earlyIntegrityStatus = [string](Get-BRAVOPreflightProperty -InputObject $earlyIntegrity -Name 'status' -Default '')

    # ---- Середовище: ОС, PowerShell, .NET, розрядність, elevation -------
    $environment = $null
    if ($adapterTable.ContainsKey('GetPreflightEnvironment') -and $adapterTable['GetPreflightEnvironment'] -is [scriptblock]) {
        $environment = & $adapterTable['GetPreflightEnvironment']
    } else {
        $environment = Get-BRAVOUpdatePreflightEnvironment -ToolkitRoot $ToolkitRoot
    }

    $tier = [string](Get-BRAVOPreflightProperty -InputObject $environment -Name 'OsTier' -Default 'Unknown')
    $osDescription = [string](Get-BRAVOPreflightProperty -InputObject $environment -Name 'OsDescription' -Default '')
    switch ($tier) {
        'Supported' {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.OperatingSystem' -Severity 'Ok' `
                -Title 'Операційна система підтримується' -Meaning 'ОС входить до підтримуваного baseline BRAVO.' -Details $osDescription
        }
        'LegacyBestEffort' {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.OperatingSystem' -Severity 'Warning' `
                -Title 'ОС підтримується без гарантій (legacy best-effort)' `
                -Meaning 'Операцію можна виконати, але підтримка цієї ОС не гарантується.' `
                -Action 'Заплануйте перехід на Windows Server 2019+ або Windows 10/11.' -Details $osDescription
        }
        default {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.OperatingSystem' -Severity 'Blocker' `
                -Title 'ОС не підтримується або її рівень не визначено' `
                -Meaning 'BRAVO не підтримує цю ОС/версію PowerShell; mutation заблоковано.' `
                -Action 'Використайте підтримувану ОС (Windows Server 2019+/Windows 10/11, PowerShell 5.1).' `
                -Details "tier=$tier; $osDescription" -ExitCodeHint 37
        }
    }

    $psVersion = Get-BRAVOPreflightProperty -InputObject $environment -Name 'PowerShellVersion'
    $psEdition = [string](Get-BRAVOPreflightProperty -InputObject $environment -Name 'PowerShellEdition' -Default '')
    $psOk = $false
    if ($null -ne $psVersion -and $psEdition -eq 'Desktop') {
        $psParsed = [version]$psVersion
        $psOk = ($psParsed.Major -eq 5 -and $psParsed.Minor -ge 1)
    }
    if ($psOk) {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.PowerShell' -Severity 'Ok' `
            -Title 'Windows PowerShell 5.1 (Desktop)' -Meaning 'Версія та редакція PowerShell відповідають вимогам.' `
            -Details "version=$psVersion; edition=$psEdition"
    } else {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.PowerShell' -Severity 'Blocker' `
            -Title 'Потрібен Windows PowerShell 5.1 (Desktop)' `
            -Meaning 'Toolkit працює лише в Windows PowerShell 5.1; інша версія чи редакція не підтримується.' `
            -Action 'Запустіть Installer у Windows PowerShell 5.1 (powershell.exe), не в pwsh.' `
            -Details "version=$psVersion; edition=$psEdition" -ExitCodeHint 37
    }

    $dotNetRelease = [int](Get-BRAVOPreflightProperty -InputObject $environment -Name 'DotNetRelease' -Default 0)
    if ($dotNetRelease -ge $script:BRAVOPreflightMinDotNetRelease) {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.DotNet' -Severity 'Ok' `
            -Title '.NET Framework 4.8 або новіший' -Meaning 'Версія .NET Framework достатня.' -Details "release=$dotNetRelease"
    } else {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.DotNet' -Severity 'Blocker' `
            -Title 'Потрібен .NET Framework 4.8' `
            -Meaning 'Встановлено застарілий .NET Framework або його не вдалося визначити.' `
            -Action 'Встановіть .NET Framework 4.8 і повторіть перевірку.' `
            -Details "release=$dotNetRelease; потрібно не менше $script:BRAVOPreflightMinDotNetRelease" -ExitCodeHint 37
    }

    if ([bool](Get-BRAVOPreflightProperty -InputObject $environment -Name 'Is64BitOS' -Default $false)) {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.Architecture' -Severity 'Ok' `
            -Title '64-розрядна ОС' -Meaning 'Розрядність ОС підтримується.'
    } else {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.Architecture' -Severity 'Blocker' `
            -Title 'Потрібна 64-розрядна ОС' -Meaning 'BRAVO підтримується лише на 64-розрядній Windows.' `
            -Action 'Використайте 64-розрядну Windows.' -ExitCodeHint 37
    }

    $isAdmin = [bool](Get-BRAVOPreflightProperty -InputObject $environment -Name 'IsAdministrator' -Default $false)
    if (-not $isMutation) {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.Elevation' -Severity 'NotApplicable' `
            -Title 'Права адміністратора для діагностики не потрібні' -Meaning 'Діагностика лише читає стан.'
    } elseif ($isAdmin) {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.Elevation' -Severity 'Ok' `
            -Title 'Запущено з правами адміністратора' -Meaning 'Додаткове підтвердження UAC не потрібне.'
    } elseif ($RequireElevation) {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.Elevation' -Severity 'Blocker' `
            -Title 'Потрібні права адміністратора' `
            -Meaning 'Операція змінює каталог програми й розклад, а поточний процес не підвищений.' `
            -Action 'Запустіть Installer від імені адміністратора.' -ExitCodeHint 36
    } else {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.Elevation' -Severity 'Warning' `
            -Title 'Буде запитано UAC' `
            -Meaning 'Попередня перевірка виконана без підвищення; перед змінами Windows покаже запит UAC.' `
            -Action 'Підтвердьте запит UAC, коли він з''явиться.'
    }

    # ---- Шляхи ------------------------------------------------------------
    $runtimeProblems = New-Object System.Collections.Generic.List[string]
    foreach ($problem in (Get-BRAVOPreflightPathProblem -Path $RuntimeRoot)) { [void]$runtimeProblems.Add($problem) }
    if ($runtimeProblems.Count -eq 0) {
        foreach ($problem in (Get-BRAVOPreflightSystemPathProblem -Path $RuntimeRoot)) { [void]$runtimeProblems.Add($problem) }
    }
    if ($runtimeProblems.Count -eq 0) {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.RuntimeRootPath' -Severity 'Ok' `
            -Title 'Каталог BRAVO придатний' -Meaning 'Шлях локальний, абсолютний, без reparse point і поза системними каталогами.' `
            -Details "runtimeRoot=$RuntimeRoot"
    } else {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.RuntimeRootPath' -Severity 'Blocker' `
            -Title 'Каталог BRAVO непридатний' -Meaning 'Розгортання в такий каталог небезпечне.' `
            -Action 'Вкажіть локальний абсолютний каталог на фіксованому диску поза каталогами Windows.' `
            -Details ("runtimeRoot=$RuntimeRoot; " + ($runtimeProblems.ToArray() -join '; ')) -ExitCodeHint 37
    }

    $workProblems = New-Object System.Collections.Generic.List[string]
    $workRoots = [ordered]@{ staging = $StagingRoot; backup = $BackupRoot; state = $StateRoot; lock = $LockRoot }
    foreach ($roleName in $workRoots.Keys) {
        $rolePath = [string]$workRoots[$roleName]
        foreach ($problem in (Get-BRAVOPreflightPathProblem -Path $rolePath)) {
            [void]$workProblems.Add("${roleName}: $problem")
        }
        if ($runtimeProblems.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($rolePath)) {
            if ((Test-BRAVOPreflightPathInside -Child $rolePath -Parent $RuntimeRoot) -or
                (Test-BRAVOPreflightPathInside -Child $RuntimeRoot -Parent $rolePath)) {
                [void]$workProblems.Add("${roleName}: каталог збігається з runtime root або вкладений у нього (чи містить його)")
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($StagingRoot) -and -not [string]::IsNullOrWhiteSpace($BackupRoot) -and
        ((Test-BRAVOPreflightPathInside -Child $StagingRoot -Parent $BackupRoot) -or
        (Test-BRAVOPreflightPathInside -Child $BackupRoot -Parent $StagingRoot))) {
        [void]$workProblems.Add('staging і backup не можуть збігатися чи бути вкладеними один в одного')
    }
    if ($workProblems.Count -eq 0) {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.WorkRootsPath' -Severity 'Ok' `
            -Title 'Робочі каталоги придатні' `
            -Meaning 'Staging, backup, state і lock лежать поза каталогом BRAVO, на локальних дисках.'
    } else {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.WorkRootsPath' -Severity 'Blocker' `
            -Title 'Робочі каталоги непридатні' `
            -Meaning 'Staging/backup/state/lock мають бути локальними й поза каталогом програми, інакше розгортання може знищити власні резервні копії.' `
            -Action 'Вкажіть окремі каталоги поза runtime root (типово під %ProgramData%\BRAVO).' `
            -Details ($workProblems.ToArray() -join '; ') -ExitCodeHint 37
    }

    # ---- Диск -------------------------------------------------------------
    $volumeChecks = New-Object System.Collections.Generic.List[string]
    $diskShort = $false
    $seenVolumes = @{}
    $neededBytes = [decimal]$RequiredBytes + $script:BRAVOPreflightReserveBytes
    $diskTargets = New-Object System.Collections.Generic.List[object]
    [void]$diskTargets.Add(@('staging', $StagingRoot))
    [void]$diskTargets.Add(@('backup', $BackupRoot))
    [void]$diskTargets.Add(@('runtime', $RuntimeRoot))
    foreach ($diskRole in $diskTargets.ToArray()) {
        $fullDiskPath = Get-BRAVOPreflightFullPath -Path ([string]$diskRole[1])
        if ($null -eq $fullDiskPath) {
            $diskShort = $true
            [void]$volumeChecks.Add("$($diskRole[0]): шлях не розбирається")
            continue
        }
        $volumeKey = [System.IO.Path]::GetPathRoot($fullDiskPath).ToUpperInvariant()
        if ($seenVolumes.ContainsKey($volumeKey)) { continue }
        $seenVolumes[$volumeKey] = $true
        $free = Get-BRAVOPreflightFreeBytes -Path $fullDiskPath
        if ($null -eq $free) {
            $diskShort = $true
            [void]$volumeChecks.Add("$volumeKey ($($diskRole[0])): вільне місце не визначено")
        } elseif ($free -lt $neededBytes) {
            $diskShort = $true
            [void]$volumeChecks.Add("$volumeKey ($($diskRole[0])): вільно $free байт, потрібно $neededBytes")
        } else {
            [void]$volumeChecks.Add("$volumeKey ($($diskRole[0])): вільно $free байт, потрібно $neededBytes")
        }
    }
    if ($diskShort) {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.DiskSpace' -Severity 'Blocker' `
            -Title 'Недостатньо вільного місця' `
            -Meaning 'На одному з томів (staging, backup або runtime) немає потрібного місця разом із резервом 512 MB або місце не визначено.' `
            -Action 'Звільніть місце або вкажіть інший каталог на диску з достатнім обсягом.' `
            -Details ($volumeChecks.ToArray() -join '; ') -ExitCodeHint 37
    } else {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.DiskSpace' -Severity 'Ok' `
            -Title 'Вільного місця достатньо' -Meaning 'Усі томи мають потрібний обсяг із резервом 512 MB.' `
            -Details ($volumeChecks.ToArray() -join '; ')
    }

    # ---- Locks (лише peek) -----------------------------------------------
    $lifecycleLockPath = Join-Path $LockRoot 'BRAVO_UPDATE.lock'
    if ($IgnoreOwnLocks) {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.LifecycleLock' -Severity 'NotApplicable' `
            -Title 'Lifecycle lock тримає поточний процес' -Meaning 'Повторний preflight виконується під власним lock.'
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.OperationLock' -Severity 'NotApplicable' `
            -Title 'Operation lock тримає поточний процес' -Meaning 'Повторний preflight виконується під власним lock.'
    } else {
        # Канонічна проба Lock-частини (fail closed: будь-яка непередбачена
        # помилка відкриття дає Active = $true, тобто Blocker).
        $lifecycleProbe = Test-BRAVOUpdateOperationLockActive -OperationLockPath $lifecycleLockPath
        if ($lifecycleProbe.Active) {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.LifecycleLock' -Severity 'Blocker' `
                -Title 'Інша операція Installer уже виконується' `
                -Meaning 'Одночасно може працювати лише одна операція встановлення/оновлення.' `
                -Action 'Дочекайтеся завершення поточної операції й повторіть перевірку. Процес не завершуйте примусово.' `
                -Details "lock=$lifecycleLockPath; $(Format-BRAVOPreflightLockHolder -Holder $lifecycleProbe.Holder)" -ExitCodeHint 20
        } else {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.LifecycleLock' -Severity 'Ok' `
                -Title 'Lock оновлення вільний' -Meaning 'Інша операція Installer не виконується.'
        }

        $operationProbe = Test-BRAVOUpdateOperationLockActive -OperationLockPath $OperationLockPath
        if ($operationProbe.Active) {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.OperationLock' -Severity 'Blocker' `
                -Title 'Виконується операція BRAVO (архівація або обслуговування)' `
                -Meaning 'Зміна файлів посеред архівації чи обслуговування може пошкодити їхній результат.' `
                -Action 'Дочекайтеся завершення операції й повторіть перевірку. Процес не завершуйте примусово.' `
                -Details "lock=$OperationLockPath; $(Format-BRAVOPreflightLockHolder -Holder $operationProbe.Holder)" -ExitCodeHint 20
        } else {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.OperationLock' -Severity 'Ok' `
                -Title 'Архівація та обслуговування не виконуються' -Meaning 'Lock операцій BRAVO вільний.'
        }
    }

    # ---- Керовані задачі через adapter -----------------------------------
    if ($adapterTable.ContainsKey('GetManagedTasks') -and $adapterTable['GetManagedTasks'] -is [scriptblock]) {
        try {
            # Цільовий RuntimeRoot - другим аргументом (перший - TaskPath, порожній = із конфігурації цього кореня).
            # Install: область задач - з ДОВІРЕНОЇ конфігурації комплекту (ціль ще не існує, її loader не можна виконувати).
            $managedTasks = @(& $adapterTable['GetManagedTasks'] '' (Resolve-BRAVOUpdateTaskRuntimeRoot -Action $Operation -RuntimeRoot $RuntimeRoot -ToolkitRoot $ToolkitRoot -IntegrityStatus $earlyIntegrityStatus))
            $runningNames = New-Object System.Collections.Generic.List[string]
            foreach ($task in $managedTasks) {
                $taskState = [string](Get-BRAVOPreflightProperty -InputObject $task -Name 'state' -Default '')
                if ($taskState -eq 'Running') {
                    [void]$runningNames.Add([string](Get-BRAVOPreflightProperty -InputObject $task -Name 'name' -Default '?'))
                }
            }
            if ($runningNames.Count -gt 0) {
                Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.RunningTasks' -Severity 'Blocker' `
                    -Title 'Виконуються задачі BRAVO' `
                    -Meaning 'Задачі розкладу працюють просто зараз; зміна файлів у цей час небезпечна.' `
                    -Action 'Дочекайтеся завершення задач (або зупиніть їх штатно в Планувальнику) і повторіть перевірку.' `
                    -Details ('running=' + ($runningNames.ToArray() -join ', ')) -ExitCodeHint 20
            } else {
                Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.RunningTasks' -Severity 'Ok' `
                    -Title 'Задачі BRAVO не виконуються' -Meaning 'Жодна керована задача не в стані Running.' `
                    -Details "tasks=$($managedTasks.Count)"
            }
        } catch {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.RunningTasks' -Severity 'Blocker' `
                -Title 'Не вдалося перевірити задачі BRAVO' `
                -Meaning 'Стан задач розкладу не доведено, тому безпечно продовжувати не можна.' `
                -Action 'Повторіть перевірку від імені адміністратора.' -Details $_.Exception.Message -ExitCodeHint 37
        }
    } else {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.RunningTasks' -Severity 'Warning' `
            -Title 'Стан задач BRAVO не перевірявся' `
            -Meaning 'Adapter не надав перелік задач; lock операцій усе одно перевірено окремо.' `
            -Action 'Перевірку задач буде повторено перед змінами.'
    }

    # ---- Власник і права коренів engine (H1; лише перевірка, нічого не створюється) ----
    # Наявний корінь із чужим власником/правами Users на запис/успадкуванням або reparse point —
    # Blocker для mutation (Warning для Diagnose: Add-BRAVOPreflightFinding знижує). Відсутні
    # корені не помилка: їх створює елевований engine; GUI їх не створює. Неелевований
    # процес довіряє особистому SID (див. Get-BRAVOUpdateTrustedSid), елевований engine
    # перевіряє суворіше й підтвердить або заблокує остаточно.
    try {
        $rootArguments = @{ Validate = $true; Paths = ([pscustomobject]@{ StateRoot = $StateRoot; LockRoot = $LockRoot; StagingRoot = $StagingRoot; BackupRoot = $BackupRoot }) }
        # Seam тестів (adapter): імітація читача ACL, який кидає UnauthorizedAccessException.
        if ($adapterTable.ContainsKey('ReadRootAcl') -and ($adapterTable['ReadRootAcl'] -is [scriptblock])) { $rootArguments['AclReader'] = $adapterTable['ReadRootAcl'] }
        if ($adapterTable.ContainsKey('RootAdminCheck') -and ($adapterTable['RootAdminCheck'] -is [scriptblock])) { $rootArguments['AdminCheck'] = $adapterTable['RootAdminCheck'] }
        $rootCheck = Initialize-BRAVOUpdateProtectedRoots @rootArguments
        if ($rootCheck.Success -and @($rootCheck.Deferred).Count -gt 0) {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.StateRootsDeferred' -Severity 'Warning' `
                -Title 'Перевірку власника/прав каталогів стану буде виконано elevated worker-ом' `
                -Meaning 'Неелевований процес не може прочитати права каталогів, закритих для Administrators/SYSTEM; це не ознака небезпеки.' `
                -Action 'Продовжуйте: elevated worker перевірить каталоги перед виконанням і заблокує операцію, якщо вони небезпечні.' `
                -Details ('відкладено: ' + @($rootCheck.Deferred).Count)
        } elseif ($rootCheck.Success) {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.StateRoots' -Severity 'Ok' `
                -Title 'Каталоги стану engine мають довіреного власника й права' -Meaning 'Перевірено власника, успадкування, права Users і reparse points наявних каталогів.' `
                -Details ('відсутні (створить engine): ' + @($rootCheck.Missing).Count)
        } else {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.StateRoots' -Severity 'Blocker' `
                -Title 'Каталоги стану engine не пройшли перевірку власника/прав' `
                -Meaning 'Каталог могли створити або змінити непривілейовані користувачі; довіряти журналам і запитам у ньому не можна.' `
                -Action 'Адміністратор має вручну перевірити й прибрати зазначені каталоги; engine не перезаписує права каталогів із чужим власником.' `
                -Details ([string]::Join('; ', @($rootCheck.Problems)))
        }
    } catch {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.StateRoots' -Severity 'Blocker' `
            -Title 'Каталоги стану engine не вдалося перевірити' -Meaning 'Не доведено, що каталоги стану безпечні.' `
            -Action 'Повторіть перевірку; якщо помилка зберігається, зверніться до адміністратора.' -Details $_.Exception.Message
    }

    # ---- Відкритий журнал -------------------------------------------------
    if ($AllowOpenJournal) {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.OpenJournal' -Severity 'NotApplicable' `
            -Title 'Відкритий журнал не блокує відновлення' -Meaning 'Режим recovery саме обробляє незавершену операцію.'
    } else {
        try {
            # Канонічний Get-BRAVOUpdateOpenJournal: Open АБО пошкоджені журнали
            # (пошкоджений = Blocker, fail closed).
            $openJournals = @(Get-BRAVOUpdateOpenJournal -StateRoot $StateRoot | Where-Object { $null -ne $_ })
            if ($openJournals.Count -gt 0) {
                $journalIds = New-Object System.Collections.Generic.List[string]
                foreach ($journal in $openJournals) {
                    $journalId = [string](Get-BRAVOPreflightProperty -InputObject $journal -Name 'OperationId' -Default '')
                    if ([string]::IsNullOrEmpty($journalId)) { $journalId = '?' }
                    if ([bool](Get-BRAVOPreflightProperty -InputObject $journal -Name 'IsCorrupt' -Default $false)) { $journalId = 'corrupt:' + $journalId }
                    [void]$journalIds.Add($journalId)
                }
                Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.OpenJournal' -Severity 'Blocker' `
                    -Title 'Є незавершена операція оновлення' `
                    -Meaning 'Попередня операція перервалась; нову не можна починати, доки стан не відновлено.' `
                    -Action 'Виконайте відновлення (Recovery) незавершеної операції й повторіть перевірку.' `
                    -Details ('journals=' + ($journalIds.ToArray() -join ', '))
            } else {
                Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.OpenJournal' -Severity 'Ok' `
                    -Title 'Незавершених операцій немає' -Meaning 'Відкритих журналів не знайдено.'
            }
        } catch {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.OpenJournal' -Severity 'Blocker' `
                -Title 'Журнал операцій пошкоджений або недоступний' `
                -Meaning 'Не доведено, що незавершеної операції немає.' `
                -Action 'Перегляньте каталог журналу й виконайте відновлення; журнали вручну не видаляйте.' `
                -Details $_.Exception.Message
        }
    }
    # ---- Ціль розгортання (Install/Update/Repair) ------------------------
    $targetMarkers = New-Object System.Collections.Generic.List[string]
    $targetExists = [System.IO.Directory]::Exists($RuntimeRoot)
    $targetIsFile = [System.IO.File]::Exists($RuntimeRoot)
    $targetNonEmpty = $false
    if ($targetExists) {
        foreach ($markerName in $script:BRAVOPreflightRuntimeMarker) {
            if (Test-Path -LiteralPath (Join-Path $RuntimeRoot $markerName)) { [void]$targetMarkers.Add($markerName) }
        }
        $targetNonEmpty = ($null -ne (Get-ChildItem -LiteralPath $RuntimeRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1))
    }
    $hasVersionFile = $targetMarkers.Contains('VERSION.json')
    switch ($Operation) {
        'Install' {
            if ($targetIsFile) {
                Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.InstallTarget' -Severity 'Blocker' `
                    -Title 'Цільовий шлях є файлом' -Meaning 'Встановлення неможливе у файл.' `
                    -Action 'Вкажіть інший каталог.' -Details "path=$RuntimeRoot" -ExitCodeHint 37
            } elseif ($hasVersionFile) {
                Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.InstallTarget' -Severity 'Blocker' `
                    -Title 'BRAVO уже встановлено в цьому каталозі' `
                    -Meaning 'Чисте встановлення поверх наявної інсталяції може знищити site-конфігурацію.' `
                    -Action 'Використайте «Оновити» або «Відновити» замість встановлення.' `
                    -Details "path=$RuntimeRoot" -ExitCodeHint 37
            } elseif ($targetMarkers.Count -gt 0) {
                Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.InstallTarget' -Severity 'Blocker' `
                    -Title 'У каталозі є файли BRAVO без VERSION.json' `
                    -Meaning 'Це часткова або пошкоджена інсталяція; встановлення поверх неї небезпечне.' `
                    -Action 'Використайте «Відновити» або вкажіть порожній каталог.' `
                    -Details ('markers=' + ($targetMarkers.ToArray() -join ', ')) -ExitCodeHint 37
            } elseif ($targetNonEmpty) {
                Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.InstallTarget' -Severity 'Blocker' `
                    -Title 'Цільовий каталог не порожній' `
                    -Meaning 'Installer не бере під контроль довільний непорожній каталог, щоб не пошкодити чужі файли.' `
                    -Action 'Вкажіть порожній або неіснуючий каталог.' -Details "path=$RuntimeRoot" -ExitCodeHint 37
            } else {
                Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.InstallTarget' -Severity 'Ok' `
                    -Title 'Цільовий каталог порожній або відсутній' -Meaning 'Чисте встановлення можливе.'
            }
        }
        'Diagnose' {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.InstallTarget' -Severity 'NotApplicable' `
                -Title 'Наявність інсталяції для діагностики не обов''язкова' -Meaning 'Діагностика описує стан, який є.'
        }
        default {
            if ($targetExists -and $targetMarkers.Count -gt 0) {
                Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.InstallTarget' -Severity 'Ok' `
                    -Title 'Знайдено наявну інсталяцію BRAVO' -Meaning 'Є що оновлювати чи відновлювати.' `
                    -Details ('markers=' + ($targetMarkers.ToArray() -join ', '))
            } else {
                Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.InstallTarget' -Severity 'Blocker' `
                    -Title 'У каталозі немає інсталяції BRAVO' `
                    -Meaning 'Оновлювати й відновлювати нічого: файлів BRAVO не знайдено.' `
                    -Action 'Виберіть «Встановити» або вкажіть правильний каталог.' -Details "path=$RuntimeRoot" -ExitCodeHint 37
            }
        }
    }

    # ---- Цілісність поточного runtime (з InstallationState) --------------
    $integrity = Get-BRAVOPreflightProperty -InputObject $InstallationState -Name 'integrity'
    $integrityStatus = [string](Get-BRAVOPreflightProperty -InputObject $integrity -Name 'status' -Default '')
    if ($Operation -eq 'Install' -or $Operation -eq 'Diagnose' -or [string]::IsNullOrEmpty($integrityStatus)) {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.RuntimeIntegrity' -Severity 'NotApplicable' `
            -Title 'Цілісність поточної інсталяції не оцінювалась' `
            -Meaning 'Для цієї операції стан цілісності не потрібен або не передано.'
    } elseif ($integrityStatus -eq 'Valid') {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.RuntimeIntegrity' -Severity 'Ok' `
            -Title 'Поточна інсталяція цілісна' -Meaning 'Файли збігаються з еталонним маніфестом.'
    } elseif ($Operation -eq 'Repair') {
        # Repair -Scope Scheduler не має резервної копії файлів: відкат звіряв би незмінені пошкоджені файли з еталоном (Critical).
        if (($Scope -ceq 'Scheduler') -and ($integrityStatus -eq 'Invalid')) {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.RepairScope' -Severity 'Blocker' `
                -Title 'Для порушеної цілісності Repair -Scope Scheduler недоступний' `
                -Meaning 'Відновлення лише планувальника не виправляє файли, а його відкат не пройде перевірку цілісності.' `
                -Action 'Виконайте повний Repair (Scope All).' -Details "integrity=$integrityStatus; scope=$Scope" -ExitCodeHint 33
        }
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.RuntimeIntegrity' -Severity 'NotApplicable' `
            -Title 'Порушена цілісність — очікувано для відновлення' -Meaning 'Саме це відновлення й виправляє.' `
            -Details "integrity=$integrityStatus"
    } elseif ($integrityStatus -eq 'Invalid') {
        # Update з доведено порушеного runtime не відкотити чисто (відновлений бекап знову не пройде еталонний маніфест -> Critical),
        # тому Update блокується: спершу Repair. Статус Unknown (цілісність не підтверджена) лишається Warning.
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.RuntimeIntegrity' -Severity 'Blocker' `
            -Title 'Цілісність поточного runtime порушена — спершу виконайте Відновлення (Repair)' `
            -Meaning 'Оновлення поверх пошкодженого runtime неможливо безпечно відкотити: відновлена копія знову не відповідатиме еталону.' `
            -Action 'Виконайте «Відновити» (Repair), а потім повторіть оновлення.' -Details "integrity=$integrityStatus" -ExitCodeHint 33
    } else {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.RuntimeIntegrity' -Severity 'Warning' `
            -Title 'Цілісність поточної інсталяції порушена або не підтверджена' `
            -Meaning 'Оновлення замінить керовані файли, але стан до оновлення не еталонний.' `
            -Action 'За потреби спершу виконайте «Відновити».' -Details "integrity=$integrityStatus"
    }

    # ---- Міграція конфігурації та схема локальної конфігурації -----------
    if ($Operation -eq 'Install') {
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.ConfigMigration' -Severity 'NotApplicable' `
            -Title 'Міграція конфігурації для нового встановлення не потрібна' -Meaning 'Legacy-конфігурації в порожньому каталозі немає.'
        Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.LocalConfigSchema' -Severity 'NotApplicable' `
            -Title 'Локальної конфігурації ще немає' -Meaning 'BRAVO.local.config буде створено під час налаштування.'
    } else {
        $migration = Test-BRAVOConfigMigrationBlocker -RuntimeRoot $RuntimeRoot
        if ($migration.Blocked) {
            foreach ($migrationFinding in $migration.Findings) {
                Add-BRAVOPreflightFinding -List $list -Operation $Operation `
                    -Id ([string](Get-BRAVOPreflightProperty -InputObject $migrationFinding -Name 'id')) `
                    -Severity ([string](Get-BRAVOPreflightProperty -InputObject $migrationFinding -Name 'severity')) `
                    -Title ([string](Get-BRAVOPreflightProperty -InputObject $migrationFinding -Name 'title')) `
                    -Meaning ([string](Get-BRAVOPreflightProperty -InputObject $migrationFinding -Name 'meaning')) `
                    -Action ([string](Get-BRAVOPreflightProperty -InputObject $migrationFinding -Name 'action')) `
                    -Details ([string](Get-BRAVOPreflightProperty -InputObject $migrationFinding -Name 'details')) `
                    -ExitCodeHint (Get-BRAVOPreflightProperty -InputObject $migrationFinding -Name 'exitCodeHint')
            }
        } else {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.ConfigMigration' -Severity 'Ok' `
                -Title 'Legacy-конфігурації (BRAVO.config) немає' -Meaning 'Міграцію Configuration v2 не потрібно виконувати або вона завершена.'
        }

        $localConfig = Read-BRAVOUpdateLocalConfigData -RuntimeRoot $RuntimeRoot -ToolkitRoot $ToolkitRoot
        if (-not $localConfig.Present) {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.LocalConfigSchema' -Severity 'Ok' `
                -Title 'BRAVO.local.config відсутній' -Meaning 'Діють канонічні значення за замовчуванням.'
        } elseif ($localConfig.IsValid) {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.LocalConfigSchema' -Severity 'Ok' `
                -Title 'BRAVO.local.config відповідає схемі' -Meaning 'Site-значення коректні й буде збережено без змін.' `
                -Details "schemaVersion=$($localConfig.EffectiveSchemaVersion)"
        } else {
            Add-BRAVOPreflightFinding -List $list -Operation $Operation -Id 'Preflight.LocalConfigSchema' -Severity 'Blocker' `
                -Title 'BRAVO.local.config не відповідає схемі' `
                -Meaning 'Файл не data-only hashtable або містить значення невідповідних типів; Installer його не змінює.' `
                -Action 'Виправте BRAVO.local.config за BRAVO.local.config.example (Configurator) і повторіть перевірку.' `
                -Details ($localConfig.Problems -join '; ') -ExitCodeHint 30
        }
    }

    $findingArray = $list.ToArray()
    $fingerprint = Get-BRAVOPreflightFingerprint -Finding $findingArray -KeyInput ([ordered]@{
            operation        = $Operation
            runtimeRoot      = $RuntimeRoot
            stateRoot        = $StateRoot
            lockRoot         = $LockRoot
            operationLock    = $OperationLockPath
            stagingRoot      = $StagingRoot
            backupRoot       = $BackupRoot
            requiredBytes    = $RequiredBytes
            requireElevation = [bool]$RequireElevation
            allowOpenJournal = [bool]$AllowOpenJournal
            ignoreOwnLocks   = [bool]$IgnoreOwnLocks
        })

    return New-BRAVOUpdatePreflightResult -Operation $Operation -RuntimeRoot $RuntimeRoot `
        -Findings $findingArray -Fingerprint $fingerprint
}
