# BRAVO.Update.Plan — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
# Побудова плану розгортання (INS-023, CONTRACTS §5): передумови й fingerprint,
# дельта файлів, footprint диска, сам DeploymentPlan, перевірка актуальності
# плану перед виконанням і текстове подання для CLI/GUI (екран 8).
#
# Усі функції тут read-only: план нічого не змінює на диску. Підтвердження
# оператора стосується саме цього плану; якщо після побудови змінилась будь-яка
# передумова (локальний конфіг, стан задач, артефакт, відкритий журнал) або
# сплив TTL, Test-BRAVODeploymentPlanCurrent вимагає новий preflight.

Set-StrictMode -Version 2.0

# --- Site-owned стан (ЄДИНИЙ набір для Plan/Backup/Deploy) -------------------
# Джерело: robocopy-виключення розгортання в deploy\Update-BRAVOServer.ps1,
# $excludeFiles / $excludeDirs (розділ "5. Розгортання комплекту", ~рядки
# 543-546). Це файли й каталоги, які налаштовані під конкретний сервер і яких
# артефакт не має права ні перезаписувати, ні видаляти. Backup і Deploy
# зобов'язані брати цей набір через Get-BRAVOUpdateSiteOwnedPaths, а не
# тримати власну копію: дві копії розійдуться, і тоді backup/delta/deploy
# по-різному трактуватимуть, що належить сайту.
$script:BRAVOUpdateSiteOwnedFiles = @('BRAVO.config', 'BRAVO.local.config', 'TOOLS_INTEGRITY.json',
                                      'WinSCP.ini', 'BRAVO_OPERATION.lock')
# 'local-backups', '.git', '.vscode' не належать артефакту: guard (BRAVO_RUNTIME_GUARD.ps1,
# рядок виключень) і генератор manifest (ci\Update-BRAVORuntimeManifest.ps1,
# $excludedDirectoryPattern) уже виключають їх з цілісності; deploy/backup/delta
# мають бачити той самий набір.
$script:BRAVOUpdateSiteOwnedDirs = @('LOGS', 'MODEL', 'BLOG', 'BRAVOEXCH', 'BAZA', 'BAZA_WWW', 'artifacts',
                                     'local-backups', '.git', '.vscode', '.claude')

# Резерв вільного місця на томі (CONTRACTS §5 / план): 512 MB.
$script:BRAVOUpdateFootprintReserveBytes = 512MB

function Get-BRAVOUpdateSiteOwnedPaths {
    # Єдиний accessor до набору site-owned (копії, щоб виклик не міг змінити константу).
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        Files = @($script:BRAVOUpdateSiteOwnedFiles)
        Dirs  = @($script:BRAVOUpdateSiteOwnedDirs)
    }
}

# --- Приватні допоміжні функції ----------------------------------------------

function Get-BRAVOUpdatePlanFileSha256 {
    # SHA-256 (UPPER) файлу або 'absent'. Нечитабельний файл -> 'unreadable',
    # а не виняток: fingerprint має змінитись, коли файл стає недоступним.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return 'absent' }
    try {
        return (Get-BRAVODeployFileSha256 -Path $Path)
    } catch {
        return 'unreadable'
    }
}

function Get-BRAVOUpdatePlanNow {
    # Час плану: явний -Now, інакше adapter.Now, інакше UtcNow. Завжди UTC.
    [CmdletBinding()]
    param([object]$Now = $null, [hashtable]$Adapter = $null)
    if ($null -ne $Now) { return ([datetime]$Now).ToUniversalTime() }
    if ($null -ne $Adapter -and $Adapter.ContainsKey('Now') -and $null -ne $Adapter['Now']) {
        $value = & $Adapter['Now']
        if ($null -ne $value) { return ([datetime]$value).ToUniversalTime() }
    }
    return [datetime]::UtcNow
}

function Get-BRAVOUpdatePlanManagedTaskList {
    # Керовані задачі через adapter: відсортований список {name, enabled}.
    # Повертає $null, якщо adapter відсутній або впав — "Unknown" не можна
    # плутати з "задач немає".
    [CmdletBinding()]
    param([hashtable]$Adapter = $null, [string]$RuntimeRoot = '')
    if ($null -eq $Adapter -or -not $Adapter.ContainsKey('GetManagedTasks') -or $null -eq $Adapter['GetManagedTasks']) {
        return $null
    }
    try {
        # Другий аргумент - цільовий RuntimeRoot: типовий adapter визначає область задач з ефективної конфігурації САМЕ цього
        # кореня, а не з кореня toolkit (перший - TaskPath, порожній = із конфігурації).
        $raw = @(& $Adapter['GetManagedTasks'] '' $RuntimeRoot)
    } catch {
        return $null
    }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($task in $raw) {
        if ($null -eq $task) { continue }
        $name = $null
        $enabled = $false
        foreach ($property in $task.PSObject.Properties) {
            if ($property.Name -ieq 'Name') { $name = [string]$property.Value }
            elseif ($property.Name -ieq 'Enabled') { $enabled = [bool]$property.Value }
        }
        if ([string]::IsNullOrEmpty($name)) { continue }
        [void]$items.Add([pscustomobject]@{ name = $name; enabled = $enabled })
    }
    return @($items.ToArray() | Sort-Object -Property name)
}

function Get-BRAVOUpdatePlanOpenJournalId {
    # Ідентифікатори відкритих журналів через канонічний Get-BRAVOUpdateOpenJournal.
    # Пошкоджений/нечитабельний журнал рахується відкритим ('corrupt:<файл>'):
    # fail closed, бо він може приховувати перерване розгортання.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(Get-BRAVOUpdateOpenJournal -StateRoot $StateRoot)) {
        if ($null -eq $entry) { continue }
        if ([bool]$entry.IsCorrupt) {
            [void]$ids.Add('corrupt:' + [System.IO.Path]::GetFileNameWithoutExtension([string]$entry.Path))
        } elseif (-not [string]::IsNullOrEmpty([string]$entry.OperationId)) {
            [void]$ids.Add([string]$entry.OperationId)
        } else {
            [void]$ids.Add([System.IO.Path]::GetFileNameWithoutExtension([string]$entry.Path))
        }
    }
    return @($ids.ToArray() | Sort-Object)
}
function Get-BRAVOUpdateTreeBytes {
    # Сумарний розмір файлів дерева з урахуванням виключень (семантика robocopy
    # /XF /XD з Get-BRAVODeployTreeKeys). Зниклий під час обходу файл = 0.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs = @()
    )
    [long]$total = 0
    foreach ($key in @(Get-BRAVODeployTreeKeys -Root $Root -ExcludeFiles $ExcludeFiles -ExcludeDirs $ExcludeDirs)) {
        $full = Join-Path $Root ($key -replace '/', '\')
        try {
            $total += ([System.IO.FileInfo]$full).Length
        } catch {
            continue
        }
    }
    return $total
}

function Get-BRAVOUpdatePlanVersionText {
    # packageVersion із VERSION.json у корені; $null, якщо файлу/поля немає або
    # JSON пошкоджений.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)
    $path = Join-Path $Root 'VERSION.json'
    if (-not [System.IO.File]::Exists($path)) { return $null }
    try {
        $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $json) { return $null }
        $property = $json.PSObject.Properties['packageVersion']
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $null }
        return [string]$property.Value
    } catch {
        return $null
    }
}

function Get-BRAVOUpdateVersionOrdering {
    # Порівняння Current/Target через довірені функції guard.
    # Result: -1/0/1 (Current молодша/рівна/старша за Target) або $null +
    # Problem, якщо будь-яку з версій не розібрано або guard недоступний.
    [CmdletBinding()]
    param([string]$Current, [string]$Target)
    $problem = $null
    $result = $null
    $guardReady = $true
    try {
        Import-BRAVOUpdateTrustedGuardFunctions
    } catch {
        $guardReady = $false
        $problem = 'функції порівняння версій guard недоступні: ' + $_.Exception.Message
    }
    if ($guardReady) {
        $left = ConvertTo-BRAVOComparableVersion -Text $Current
        $right = ConvertTo-BRAVOComparableVersion -Text $Target
        if ($null -eq $left) { $problem = 'поточна версія не є коректною: ' + $Current }
        elseif ($null -eq $right) { $problem = 'цільова версія не є коректною: ' + $Target }
        else { $result = [int](Compare-BRAVOComparableVersion -Left $left -Right $right) }
    }
    return [pscustomobject]@{ Result = $result; Problem = $problem }
}

function Format-BRAVOUpdateByteSize {
    # Розмір для людей: MB з однією цифрою, інваріантна культура.
    [CmdletBinding()]
    param([object]$Bytes)
    if ($null -eq $Bytes) { return 'невідомо' }
    $mb = [double]$Bytes / 1MB
    return ($mb.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) + ' MB')
}

# --- Передумови й fingerprint ------------------------------------------------

function Get-BRAVODeploymentPreconditions {
    # Впорядкований набір вхідних даних fingerprint-а (CONTRACTS §5). Порядок і
    # імена полів фіксовані: fingerprint — це SHA-256 канонічного JSON цього
    # об'єкта, тож будь-яка нестабільність порядку дала б хибні розбіжності.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$ArtifactSha256 = '',
        [string]$ManifestSha256 = '',
        [hashtable]$Adapter = $null
    )
    $tasks = Get-BRAVOUpdatePlanManagedTaskList -Adapter $Adapter -RuntimeRoot $RuntimeRoot
    $taskInputs = 'Unknown'
    if ($null -ne $tasks) {
        $taskInputs = @(foreach ($task in @($tasks)) { $task.name + '=' + $(if ($task.enabled) { 'enabled' } else { 'disabled' }) })
    }
    return [pscustomobject][ordered]@{
        runtimeManifestSha256 = Get-BRAVOUpdatePlanFileSha256 -Path (Join-Path $RuntimeRoot 'RUNTIME_MANIFEST.json')
        versionJsonSha256     = Get-BRAVOUpdatePlanFileSha256 -Path (Join-Path $RuntimeRoot 'VERSION.json')
        localConfigSha256     = Get-BRAVOUpdatePlanFileSha256 -Path (Join-Path $RuntimeRoot 'BRAVO.local.config')
        configPresent         = [System.IO.File]::Exists((Join-Path $RuntimeRoot 'BRAVO.config'))
        artifactSha256        = $ArtifactSha256.ToUpperInvariant()
        manifestSha256        = $ManifestSha256.ToUpperInvariant()
        managedTasks          = $taskInputs
        openJournalIds        = @(Get-BRAVOUpdatePlanOpenJournalId -StateRoot $StateRoot)
    }
}

function Get-BRAVOUpdatePreconditionsFingerprint {
    # SHA-256 (hex, UPPER) канонічного компактного JSON передумов.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Preconditions)
    $json = ConvertTo-Json -InputObject $Preconditions -Depth 10 -Compress
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($json))
    } finally {
        $sha.Dispose()
    }
    return ([BitConverter]::ToString($bytes) -replace '-', '').ToUpperInvariant()
}

# --- Дельта файлів -----------------------------------------------------------

function Get-BRAVODeploymentFileDelta {
    # Дельта між поточним runtime і staged за integrity-манифестами обох боків.
    # Removed = є в чинному манифесті, відсутнє в новому. Site-owned файли й
    # каталоги не рахуються ніколи (їх deploy не торкається). Відсутній
    # манифест staged — виняток (без нього план не можна обґрунтувати);
    # відсутній манифест runtime (Install/зіпсований runtime) = порожній
    # набір, усе Added, про що каже RuntimeManifestPresent.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$StagedRoot
    )
    $stagedHashes = Get-BRAVODeployManifestHashes -ManifestPath (Join-Path $StagedRoot 'RUNTIME_MANIFEST.json')
    $runtimeManifestPath = Join-Path $RuntimeRoot 'RUNTIME_MANIFEST.json'
    $runtimePresent = [System.IO.File]::Exists($runtimeManifestPath)
    $currentHashes = @{}
    if ($runtimePresent) {
        $currentHashes = Get-BRAVODeployManifestHashes -ManifestPath $runtimeManifestPath
    }
    $owned = Get-BRAVOUpdateSiteOwnedPaths
    $added = New-Object System.Collections.Generic.List[string]
    $changed = New-Object System.Collections.Generic.List[string]
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($key in $stagedHashes.Keys) {
        if (Test-BRAVODeployPathExcluded -RelativeKey $key -ExcludeFiles $owned.Files -ExcludeDirs $owned.Dirs) { continue }
        if (-not $currentHashes.ContainsKey($key)) {
            [void]$added.Add($key)
        } elseif ($currentHashes[$key] -ne $stagedHashes[$key]) {
            [void]$changed.Add($key)
        }
    }
    foreach ($key in $currentHashes.Keys) {
        if (Test-BRAVODeployPathExcluded -RelativeKey $key -ExcludeFiles $owned.Files -ExcludeDirs $owned.Dirs) { continue }
        if (-not $stagedHashes.ContainsKey($key)) { [void]$removed.Add($key) }
    }
    $addedSorted = @($added.ToArray() | Sort-Object)
    $changedSorted = @($changed.ToArray() | Sort-Object)
    $removedSorted = @($removed.ToArray() | Sort-Object)
    return [pscustomobject][ordered]@{
        FilesAdded             = $addedSorted.Count
        FilesChanged           = $changedSorted.Count
        FilesRemoved           = $removedSorted.Count
        Added                  = $addedSorted
        Changed                = $changedSorted
        Removed                = $removedSorted
        RuntimeManifestPresent = $runtimePresent
    }
}

# --- Footprint диска ---------------------------------------------------------

function Get-BRAVODeploymentFootprint {
    # Оцінка місця: staging = розмір staged, backup = чинний runtime без
    # site-owned, deploy = розмір staged. Якщо корені на одному томі, потреби
    # складаються (по томах), резерв додається один раз на том. Верхньорівневі
    # requiredFreeBytes/availableFreeBytes/volume — для тому з найменшим
    # запасом (найгірший), повний розклад — у volumes[]. Том, для якого
    # DriveInfo недоступний (UNC тощо), дає availableFreeBytes = $null:
    # невідомо не означає достатньо.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StagedRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$StagingRoot,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [long]$ReserveBytes = $script:BRAVOUpdateFootprintReserveBytes
    )
    $owned = Get-BRAVOUpdateSiteOwnedPaths
    # Розмір staged — канонічний helper Staging (без reparse points, виняток при помилці читання).
    [long]$stagingBytes = 0
    if ([System.IO.Directory]::Exists($StagedRoot)) { $stagingBytes = Get-BRAVOUpdateDirectorySize -Path $StagedRoot }
    [long]$backupBytes = Get-BRAVOUpdateTreeBytes -Root $RuntimeRoot -ExcludeFiles $owned.Files -ExcludeDirs $owned.Dirs
    [long]$deployBytes = $stagingBytes

    $demands = @(
        @{ Root = $StagingRoot; Bytes = $stagingBytes },
        @{ Root = $BackupRoot; Bytes = $backupBytes },
        @{ Root = $RuntimeRoot; Bytes = $deployBytes }
    )
    $byVolume = @{}
    foreach ($demand in $demands) {
        $volumeRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($demand.Root))
        $volumeKey = $volumeRoot.ToUpperInvariant()
        if (-not $byVolume.ContainsKey($volumeKey)) {
            $byVolume[$volumeKey] = [pscustomobject]@{ Volume = $volumeRoot; Required = [long]$ReserveBytes }
        }
        $byVolume[$volumeKey].Required += [long]$demand.Bytes
    }
    $volumes = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $byVolume.Values) {
        $free = Get-BRAVOUpdateFreeSpace -Path $entry.Volume
        $available = $free.AvailableFreeBytes
        [void]$volumes.Add([pscustomobject][ordered]@{
                volume             = $entry.Volume
                requiredFreeBytes  = [long]$entry.Required
                availableFreeBytes = $available
            })
    }
    # Найгірший том: невідомий доступний обсяг гірший за відомий.
    $worst = $null
    foreach ($volume in $volumes) {
        if ($null -eq $worst) { $worst = $volume; continue }
        $worstUnknown = ($null -eq $worst.availableFreeBytes)
        $currentUnknown = ($null -eq $volume.availableFreeBytes)
        if ($currentUnknown -and -not $worstUnknown) { $worst = $volume; continue }
        if ($worstUnknown -and -not $currentUnknown) { continue }
        if (-not $currentUnknown) {
            if (($volume.availableFreeBytes - $volume.requiredFreeBytes) -lt ($worst.availableFreeBytes - $worst.requiredFreeBytes)) { $worst = $volume }
        }
    }
    return [pscustomobject][ordered]@{
        stagingBytes       = $stagingBytes
        backupBytes        = $backupBytes
        deployBytes        = $deployBytes
        reserveBytes       = [long]$ReserveBytes
        requiredFreeBytes  = [long]$worst.requiredFreeBytes
        availableFreeBytes = $worst.availableFreeBytes
        volume             = [string]$worst.volume
        volumes            = @($volumes.ToArray())
    }
}

# --- План --------------------------------------------------------------------

function New-BRAVODeploymentPlan {
    # Будує DeploymentPlan (CONTRACTS §5). План будується навіть із blockers
    # (оператор має побачити причини), але requiresConfirmation завжди $true, а
    # виконання плану з blocker-ами заборонено споживачем (finding-и в плані).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair')][string]$Action,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$StagingRoot,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$Source,
        [Parameter(Mandatory = $true)][string]$StagedRoot,
        [Parameter(Mandatory = $true)]$Preflight,
        $InstallationState = $null,
        [hashtable]$Adapter = $null,
        [ValidateRange(1, 1440)][int]$TtlMinutes = 30,
        [object]$Now = $null,
        # Вибір self-test є частиною ПІДТВЕРДЖЕНОГО плану, а не вільною опцією запиту:
        # Default = Include для Install/Update, Skip для Repair.
        [ValidateSet('Default', 'Include', 'Skip')][string]$SelfTest = 'Default'
    )
    $findings = New-Object System.Collections.Generic.List[object]
    $nowUtc = Get-BRAVOUpdatePlanNow -Now $Now -Adapter $Adapter

    # --- Джерело (нормалізація з перевіркою полів: StrictMode) ---
    $sourceValues = [ordered]@{
        kind = ''; tag = ''; artifactName = ''; artifactSha256 = ''; manifestSha256 = ''
        packageVersion = ''; releaseChannel = ''; prereleaseAuthorized = $false
    }
    foreach ($name in @($sourceValues.Keys)) {
        $property = $Source.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) { $sourceValues[$name] = $property.Value }
    }
    $sourceValues['artifactSha256'] = ([string]$sourceValues['artifactSha256']).ToUpperInvariant()
    $sourceValues['manifestSha256'] = ([string]$sourceValues['manifestSha256']).ToUpperInvariant()
    $sourceValues['prereleaseAuthorized'] = [bool]$sourceValues['prereleaseAuthorized']
    $targetVersion = [string]$sourceValues['packageVersion']

    # --- Поточна версія й стан ---
    $currentVersion = $null
    $installState = $null
    if ($null -ne $InstallationState) {
        $stateProperty = $InstallationState.PSObject.Properties['state']
        if ($null -ne $stateProperty) { $installState = [string]$stateProperty.Value }
        $versionProperty = $InstallationState.PSObject.Properties['version']
        if ($null -ne $versionProperty -and $null -ne $versionProperty.Value) {
            $packageProperty = $versionProperty.Value.PSObject.Properties['packageVersion']
            if ($null -ne $packageProperty -and -not [string]::IsNullOrWhiteSpace([string]$packageProperty.Value)) {
                $currentVersion = [string]$packageProperty.Value
            }
        }
    }
    if ($null -eq $currentVersion) { $currentVersion = Get-BRAVOUpdatePlanVersionText -Root $RuntimeRoot }

    # --- Правила дії/версії ---
    $hasTarget = (-not [string]::IsNullOrWhiteSpace($targetVersion))
    if (-not $hasTarget) {
        [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.TargetVersionMissing' -Severity 'Blocker' `
                -Title 'У джерелі не вказано версію пакета' `
                -Meaning 'Без цільової версії неможливо порівняти її з встановленою.' `
                -Action 'Повторіть отримання релізу, щоб отримати коректний маніфест.'))
    }
    switch ($Action) {
        'Install' {
            $alreadyInstalled = $false
            if ($null -ne $installState) { $alreadyInstalled = ($installState -ne 'NotInstalled') }
            elseif ($null -ne $currentVersion) { $alreadyInstalled = $true }
            if ($alreadyInstalled) {
                [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.InstallOnExisting' -Severity 'Blocker' `
                        -Title 'Сервер уже має встановлений BRAVO Toolkit' `
                        -Meaning 'Чиста інсталяція можлива лише там, де Toolkit ще не встановлено.' `
                        -Action 'Виберіть «Оновити» або «Відновити» замість «Встановити».' `
                        -Details ('стан=' + [string]$installState + '; версія=' + [string]$currentVersion)))
            }
        }
        default {
            if ($null -eq $currentVersion) {
                [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.CurrentVersionUnknown' -Severity 'Blocker' `
                        -Title 'Не вдалося визначити встановлену версію' `
                        -Meaning 'Без поточної версії неможливо перевірити напрям зміни (оновлення чи відкат).' `
                        -Action 'Перевірте VERSION.json у каталозі встановлення або виконайте відновлення з повного пакета.'))
            } elseif ($hasTarget) {
                $ordering = Get-BRAVOUpdateVersionOrdering -Current $currentVersion -Target $targetVersion
                if ($null -eq $ordering.Result) {
                    [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.VersionCompareFailed' -Severity 'Blocker' `
                            -Title 'Не вдалося порівняти версії' `
                            -Meaning 'Напрям зміни версії не доведено, тому розгортання заблоковано.' `
                            -Action 'Перевірте формат версій (X.Y.Z[-prerelease]).' `
                            -Details $ordering.Problem))
                } elseif ($Action -eq 'Repair') {
                    if ($ordering.Result -ne 0) {
                        [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.RepairVersionMismatch' -Severity 'Blocker' `
                                -Title 'відновлення не виконує оновлення версії' `
                                -Meaning 'Відновлення перевстановлює ту саму версію, що вже встановлена.' `
                                -Action 'Для зміни версії скористайтеся «Оновити»; для відновлення вкажіть пакет тієї самої версії.' `
                                -Details ('встановлена=' + $currentVersion + '; пакет=' + $targetVersion)))
                    }
                } else {
                    # Update: потрібна строго новіша цільова версія.
                    if ($ordering.Result -eq 0) {
                        [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.UpdateSameVersion' -Severity 'Blocker' `
                                -Title 'Встановлена версія збігається з пакетом' `
                                -Meaning 'Оновлювати нічого: версії однакові.' `
                                -Action 'Якщо потрібно перевстановити файли тієї самої версії, виберіть «Відновити».' `
                                -Details ('версія=' + $currentVersion)))
                    } elseif ($ordering.Result -gt 0) {
                        [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.UpdateDowngrade' -Severity 'Blocker' `
                                -Title 'Пакет старіший за встановлену версію' `
                                -Meaning 'Відкат версії через оновлення заборонено: це знижує захист від регресій.' `
                                -Action 'Використайте пакет новішої версії.' `
                                -Details ('встановлена=' + $currentVersion + '; пакет=' + $targetVersion) `
                                -ExitCodeHint 35))
                    }
                }
            }
        }
    }

    # --- Prerelease без дозволу ---
    if ($hasTarget -and ([string]$sourceValues['releaseChannel']) -ne 'stable' -and -not $sourceValues['prereleaseAuthorized']) {
        [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.PrereleaseNotAuthorized' -Severity 'Blocker' `
                -Title 'Пакет не зі стабільного каналу, а дозволу немає' `
                -Meaning 'Попередні (prerelease) збірки встановлюються лише з явного дозволу оператора.' `
                -Action 'Використайте stable-реліз або явно дозвольте prerelease.' `
                -Details ('канал=' + [string]$sourceValues['releaseChannel'])))
    }

    # --- Збіг версії staged із джерелом ---
    $stagedVersion = Get-BRAVOUpdatePlanVersionText -Root $StagedRoot
    if ($hasTarget -and $null -ne $stagedVersion -and $stagedVersion -ne $targetVersion) {
        [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.StagedVersionMismatch' -Severity 'Blocker' `
                -Title 'Версія staged-пакета не збігається з джерелом' `
                -Meaning 'Розпакований пакет не відповідає манифесту релізу.' `
                -Action 'Очистіть staging і отримайте пакет повторно.' `
                -Details ('джерело=' + $targetVersion + '; staged=' + $stagedVersion)))
    }

    # --- Дельта файлів ---
    $delta = $null
    try {
        $delta = Get-BRAVODeploymentFileDelta -RuntimeRoot $RuntimeRoot -StagedRoot $StagedRoot
    } catch {
        [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.DeltaFailed' -Severity 'Blocker' `
                -Title 'Не вдалося порахувати зміни файлів' `
                -Meaning 'Без integrity-манифесту staged-пакета склад змін не доведено.' `
                -Action 'Очистіть staging і отримайте пакет повторно.' `
                -Details $_.Exception.Message))
    }
    if ($null -ne $delta -and -not $delta.RuntimeManifestPresent -and $Action -ne 'Install') {
        [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.RuntimeManifestMissing' -Severity 'Warning' `
                -Title 'У чинному встановленні немає RUNTIME_MANIFEST.json' `
                -Meaning 'Кількість змінених і видалених файлів неточна: усі файли пакета вважаються доданими.' `
                -Action 'Після розгортання перевірте цілісність.'))
    }

    # --- Footprint ---
    $footprint = $null
    try {
        $footprint = Get-BRAVODeploymentFootprint -StagedRoot $StagedRoot -RuntimeRoot $RuntimeRoot -StagingRoot $StagingRoot -BackupRoot $BackupRoot
    } catch {
        [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.FootprintFailed' -Severity 'Blocker' `
                -Title 'Не вдалося оцінити потрібне місце на диску' `
                -Meaning 'Без оцінки розміру не можна гарантувати, що розгортання завершиться.' `
                -Action 'Перевірте доступність каталогів staging, backup і встановлення.' `
                -Details $_.Exception.Message))
    }
    if ($null -ne $footprint) {
        if ($null -eq $footprint.availableFreeBytes) {
            [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.DiskSpaceUnknown' -Severity 'Warning' `
                    -Title 'Не вдалося визначити вільне місце на томі' `
                    -Meaning 'Достатність місця не перевірена.' `
                    -Details ('том=' + $footprint.volume)))
        } elseif ($footprint.availableFreeBytes -lt $footprint.requiredFreeBytes) {
            [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.DiskSpace' -Severity 'Blocker' `
                    -Title 'Недостатньо вільного місця на диску' `
                    -Meaning 'Staging, резервна копія й нові файли не поміщаються разом із резервом.' `
                    -Action 'Звільніть місце або вкажіть інший том для резервних копій.' `
                    -Details ('том=' + $footprint.volume + '; потрібно=' + (Format-BRAVOUpdateByteSize $footprint.requiredFreeBytes) + '; доступно=' + (Format-BRAVOUpdateByteSize $footprint.availableFreeBytes))))
        }
    }

    # --- Preflight: копіюємо Blocker/Warning ---
    $preflightFindings = $null
    if ($null -ne $Preflight) {
        $preflightProperty = $Preflight.PSObject.Properties['findings']
        if ($null -ne $preflightProperty) { $preflightFindings = @($preflightProperty.Value) }
    }
    if ($null -eq $preflightFindings) {
        [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.PreflightMissing' -Severity 'Blocker' `
                -Title 'Немає результату preflight' `
                -Meaning 'План не можна затвердити без перевірки передумов.' `
                -Action 'Виконайте preflight і побудуйте план знову.'))
    } else {
        foreach ($item in $preflightFindings) {
            if ($null -eq $item) { continue }
            $severityProperty = $item.PSObject.Properties['severity']
            if ($null -eq $severityProperty) { continue }
            if ([string]$severityProperty.Value -eq 'Blocker' -or [string]$severityProperty.Value -eq 'Warning') {
                [void]$findings.Add($item)
            }
        }
        $canProceedProperty = $Preflight.PSObject.Properties['canProceed']
        if ($null -ne $canProceedProperty -and -not [bool]$canProceedProperty.Value) {
            $hasBlocker = $false
            foreach ($item in $findings) { if ($item.severity -eq 'Blocker') { $hasBlocker = $true } }
            if (-not $hasBlocker) {
                [void]$findings.Add((New-BRAVOUpdateFinding -Id 'Plan.PreflightNotProceed' -Severity 'Blocker' `
                        -Title 'Preflight не дозволяє продовжити' `
                        -Meaning 'Результат preflight має canProceed = false без деталізації.' `
                        -Action 'Повторіть preflight.'))
            }
        }
    }

    # --- Керовані задачі (стан ДО операції) ---
    $taskList = Get-BRAVOUpdatePlanManagedTaskList -Adapter $Adapter -RuntimeRoot $RuntimeRoot
    $planTasks = @()
    if ($null -ne $taskList) {
        $planTasks = @(foreach ($task in @($taskList)) { [pscustomobject][ordered]@{ name = $task.name; enabledBefore = $task.enabled } })
    }

    # --- Передумови й fingerprint ---
    $preconditions = Get-BRAVODeploymentPreconditions -RuntimeRoot $RuntimeRoot -StateRoot $StateRoot `
        -ArtifactSha256 ([string]$sourceValues['artifactSha256']) -ManifestSha256 ([string]$sourceValues['manifestSha256']) -Adapter $Adapter
    $fingerprint = Get-BRAVOUpdatePreconditionsFingerprint -Preconditions $preconditions

    # --- Тести ---
    $planned = @(
        [pscustomobject][ordered]@{ id = 'RuntimeGuard'; title = 'Перевірка runtime guard' },
        [pscustomobject][ordered]@{ id = 'SetupValidate'; title = 'Перевірка конфігурації (BRAVO_SETUP validate)' },
        [pscustomobject][ordered]@{ id = 'SchedulerReconcile'; title = 'Звірка планувальника задач' }
    )
    $skipped = @()
    $includeSelfTest = ($Action -ne 'Repair')
    if ($SelfTest -eq 'Include') { $includeSelfTest = $true }
    if ($SelfTest -eq 'Skip') { $includeSelfTest = $false }
    if ($includeSelfTest) {
        $planned += [pscustomobject][ordered]@{ id = 'SelfTest'; title = 'Self-test' }
    } else {
        $selfTestReason = 'вимкнено оператором'
        if ($SelfTest -eq 'Default') { $selfTestReason = 'Відновлення не змінює версію; повний self-test не запускається, цілісність перевіряють guard і валідація.' }
        $skipped = @([pscustomobject][ordered]@{ id = 'SelfTest'; title = 'Self-test'; reason = $selfTestReason })
    }

    $preserved = @(
        'Локальна конфігурація сервера (BRAVO.config, BRAVO.local.config) не змінюється',
        'Журнали LOGS не змінюються',
        'Дані та каталоги сервера (MODEL, BLOG, BRAVOEXCH, BAZA, BAZA_WWW, artifacts) не змінюються',
        'Стан інсталятора й журнали операцій (State) зберігаються',
        'Облікові дані (Credential Manager, облікові записи задач) не змінюються',
        'Попередні резервні копії зберігаються'
    )

    $localConfigPresent = [System.IO.File]::Exists((Join-Path $RuntimeRoot 'BRAVO.local.config'))
    $legacyConfigPresent = [System.IO.File]::Exists((Join-Path $RuntimeRoot 'BRAVO.config'))
    $filesAdded = 0; $filesChanged = 0; $filesRemoved = 0
    if ($null -ne $delta) { $filesAdded = $delta.FilesAdded; $filesChanged = $delta.FilesChanged; $filesRemoved = $delta.FilesRemoved }

    $planChanges = [pscustomobject][ordered]@{
        filesAdded    = $filesAdded
        filesChanged  = $filesChanged
        filesRemoved  = $filesRemoved
        configuration = [pscustomobject][ordered]@{
            localConfigPreserved  = $localConfigPresent
            legacyConfigPreserved = $legacyConfigPresent
            delta                 = @()
            note                  = 'BRAVO.local.config зберігається побайтово'
        }
        scheduler     = [pscustomobject][ordered]@{
            tasks            = $planTasks
            activationPolicy = 'ActivateOnSuccessOnly'
        }
    }
    $planTests = [pscustomobject][ordered]@{ planned = $planned; skipped = $skipped }

    # Канонічний конструктор (форма й planId/operationId/TTL — в одному місці).
    $plan = New-BRAVOUpdateDeploymentPlan -Action $Action -RuntimeRoot $RuntimeRoot -StagingRoot $StagingRoot -BackupRoot $BackupRoot `
        -Source ([pscustomobject]$sourceValues) -CurrentVersion $currentVersion -TargetVersion $targetVersion `
        -Footprint $footprint -Changes $planChanges -Preserved $preserved -Tests $planTests `
        -Findings @($findings.ToArray()) -PreconditionsFingerprint $fingerprint `
        -CreatedUtc $nowUtc.ToString('o') -TtlMinutes $TtlMinutes

    # Невалідний план не повертаємо мовчки: контрактний валідатор додає Blocker.
    $validation = Test-BRAVOUpdateDeploymentPlan -InputObject $plan
    if (-not $validation.IsValid) {
        $details = (@($validation.Problems) -join '; ')
        $plan.findings = @($plan.findings) + @(New-BRAVOUpdateFinding -Id 'Plan.ContractInvalid' -Severity 'Blocker' `
                -Title 'План не відповідає контракту' -Meaning 'Внутрішня помилка побудови плану.' `
                -Action 'Повідомте розробників.' -Details $details)
    }    return $plan
}

function Test-BRAVODeploymentPlanCurrent {
    # План актуальний, лише якщо не минув TTL, fingerprint передумов збігається,
    # а корінь той самий. Будь-який збій читання/форми плану = не актуальний
    # (fail closed), виняток викликачу не віддається.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [hashtable]$Adapter = $null,
        [object]$Now = $null
    )
    $problems = New-Object System.Collections.Generic.List[string]
    $expired = $false
    $fingerprintMatches = $false
    try {
        $names = @($Plan.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($required in @('expiresUtc', 'preconditionsFingerprint', 'source', 'runtimeRoot')) {
            if ($names -notcontains $required) { throw ('у плані немає поля ' + $required) }
        }
        $nowUtc = Get-BRAVOUpdatePlanNow -Now $Now -Adapter $Adapter
        $expires = [datetime]::Parse([string]$Plan.expiresUtc, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if ($nowUtc -gt $expires) {
            $expired = $true
            [void]$problems.Add('Термін дії плану минув: потрібен новий preflight і нове підтвердження.')
        }
        $planRoot = [System.IO.Path]::GetFullPath(([string]$Plan.runtimeRoot).TrimEnd('\', '/'))
        $askedRoot = [System.IO.Path]::GetFullPath($RuntimeRoot.TrimEnd('\', '/'))
        if (-not [string]::Equals($planRoot, $askedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            [void]$problems.Add('Каталог встановлення відрізняється від указаного в плані.')
        }
        $artifact = ''
        $manifest = ''
        $artifactProperty = $Plan.source.PSObject.Properties['artifactSha256']
        $manifestProperty = $Plan.source.PSObject.Properties['manifestSha256']
        if ($null -ne $artifactProperty -and $null -ne $artifactProperty.Value) { $artifact = [string]$artifactProperty.Value }
        if ($null -ne $manifestProperty -and $null -ne $manifestProperty.Value) { $manifest = [string]$manifestProperty.Value }
        $preconditions = Get-BRAVODeploymentPreconditions -RuntimeRoot $RuntimeRoot -StateRoot $StateRoot `
            -ArtifactSha256 $artifact -ManifestSha256 $manifest -Adapter $Adapter
        $current = Get-BRAVOUpdatePreconditionsFingerprint -Preconditions $preconditions
        $fingerprintMatches = ($current -eq ([string]$Plan.preconditionsFingerprint).ToUpperInvariant())
        if (-not $fingerprintMatches) {
            [void]$problems.Add('Передумови змінилися після побудови плану (конфігурація, задачі, версія, артефакт або журнал): потрібен новий preflight.')
        }
    } catch {
        [void]$problems.Add('Не вдалося перевірити актуальність плану: ' + $_.Exception.Message)
    }
    return [pscustomobject][ordered]@{
        IsCurrent          = ($problems.Count -eq 0 -and $fingerprintMatches -and -not $expired)
        Expired            = $expired
        FingerprintMatches = $fingerprintMatches
        Problems           = @($problems.ToArray())
    }
}

function Format-BRAVODeploymentPlanText {
    # Український підсумок плану для CLI та екрана 8 GUI. Лише рядки, жодного
    # виводу в консоль. Статус завжди текстом разом із символом (не лише колір).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)
    $mark = @{
        Ok            = [string][char]0x2713
        Warning       = '!'
        Blocker       = [string][char]0x00D7
        NotApplicable = [string][char]0x2014
    }
    $actionText = @{ Install = 'Встановлення'; Update = 'Оновлення'; Repair = 'Відновлення' }
    $lines = New-Object System.Collections.Generic.List[string]
    $actionName = [string]$Plan.action
    if ($actionText.ContainsKey($actionName)) { $actionName = $actionText[$actionName] }
    [void]$lines.Add('План: ' + $actionName)
    $current = [string]$Plan.currentVersion
    if ([string]::IsNullOrEmpty($current)) { $current = 'не встановлено' }
    [void]$lines.Add('Версія: ' + $current + ' -> ' + [string]$Plan.targetVersion)
    [void]$lines.Add('Каталог встановлення: ' + [string]$Plan.runtimeRoot)
    [void]$lines.Add('Резервна копія: ' + [string]$Plan.backupRoot)
    [void]$lines.Add('Джерело: ' + [string]$Plan.source.kind + ', ' + [string]$Plan.source.artifactName + ' (' + [string]$Plan.source.releaseChannel + ')')
    [void]$lines.Add('Файли: додається ' + $Plan.changes.filesAdded + ', змінюється ' + $Plan.changes.filesChanged + ', видаляється ' + $Plan.changes.filesRemoved)
    [void]$lines.Add('Конфігурація: ' + [string]$Plan.changes.configuration.note)
    [void]$lines.Add('Планувальник: політика активації ' + [string]$Plan.changes.scheduler.activationPolicy + ', задач: ' + @($Plan.changes.scheduler.tasks).Count)
    if ($null -ne $Plan.footprint) {
        [void]$lines.Add('Диск: потрібно ' + (Format-BRAVOUpdateByteSize $Plan.footprint.requiredFreeBytes) + ', доступно ' + (Format-BRAVOUpdateByteSize $Plan.footprint.availableFreeBytes) + ' (том ' + [string]$Plan.footprint.volume + ')')
    }
    [void]$lines.Add('Буде збережено без змін:')
    foreach ($item in @($Plan.preserved)) { [void]$lines.Add('  ' + $mark['Ok'] + ' ' + [string]$item) }
    [void]$lines.Add('Перевірки після розгортання:')
    foreach ($item in @($Plan.tests.planned)) { [void]$lines.Add('  ' + $mark['Ok'] + ' ' + [string]$item.title) }
    foreach ($item in @($Plan.tests.skipped)) { [void]$lines.Add('  ' + $mark['NotApplicable'] + ' ' + [string]$item.title + ' пропущено: ' + [string]$item.reason) }
    $findingList = @($Plan.findings)
    if ($findingList.Count -gt 0) {
        [void]$lines.Add('Зауваження:')
        foreach ($finding in $findingList) {
            $symbol = '?'
            if ($mark.ContainsKey([string]$finding.severity)) { $symbol = $mark[[string]$finding.severity] }
            $line = '  ' + $symbol + ' ' + [string]$finding.title
            if (-not [string]::IsNullOrEmpty([string]$finding.action)) { $line += ' — ' + [string]$finding.action }
            [void]$lines.Add($line)
        }
    }
    [void]$lines.Add('План чинний до: ' + [string]$Plan.expiresUtc + ' (UTC); потрібне підтвердження оператора.')
    return @($lines.ToArray())
}
