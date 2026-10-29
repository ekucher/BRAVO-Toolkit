# BRAVO.Update.Discovery — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# INS-020: read-only discovery встановлення. Усе, що тут відбувається, —
# ЧИТАННЯ: жодних записів на диск, жодних lock-ів, жодних змін задач,
# жодних дочірніх процесів. Єдине зовнішнє читання задач/credentials іде
# через adapter (див. CONTRACTS §1). Результат — InstallationState (§3).
#
# ЧОМУ ТАКА СУВОРІСТЬ: discovery викликається GUI/CLI до того, як оператор
# щось вирішив. Якби «подивитись» могло змінити сервер (взяти lock, створити
# тимчасову задачу, записати version state), помилка в самому огляді
# ставала б інцидентом. Тому TestCredentialPresence (може створювати
# тимчасову SYSTEM-задачу) вимкнений за замовчуванням.

# Безпечне читання властивості з PSObject або словника (StrictMode 2.0 кидає
# виняток на відсутню властивість, а adapter/журнал можуть повертати обидві
# форми).
function Get-BRAVOUpdateDiscoveryProperty {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $InputObject[$key]
            }
        }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

# Finding за CONTRACTS §2. Якщо W1-конструктор New-BRAVOUpdateFinding
# доступний і має очікувані параметри — використовуємо його (одна канонічна
# форма); інакше будуємо ту саму форму локально, щоб discovery не залежав
# від порядку інтеграції частин.
function New-BRAVOUpdateDiscoveryFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('Ok', 'Warning', 'Blocker', 'NotApplicable')][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Meaning,
        [string]$Action = '',
        [string]$Details = '',
        [AllowNull()]$ExitCodeHint = $null
    )

    $constructor = Get-Command -Name 'New-BRAVOUpdateFinding' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $constructor) {
        $known = @('Id', 'Severity', 'Title', 'Meaning', 'Action', 'Details')
        $supported = $true
        foreach ($parameterName in $known) {
            if (-not $constructor.Parameters.ContainsKey($parameterName)) { $supported = $false }
        }
        if ($supported) {
            $arguments = @{
                Id = $Id; Severity = $Severity; Title = $Title
                Meaning = $Meaning; Action = $Action; Details = $Details
            }
            if ($null -ne $ExitCodeHint -and $constructor.Parameters.ContainsKey('ExitCodeHint')) {
                $arguments['ExitCodeHint'] = [int]$ExitCodeHint
            }
            try { return (New-BRAVOUpdateFinding @arguments) } catch { $null = $_ }
        }
    }

    return [pscustomobject][ordered]@{
        id           = $Id
        severity     = $Severity
        title        = $Title
        meaning      = $Meaning
        action       = $Action
        details      = $Details
        exitCodeHint = $(if ($null -eq $ExitCodeHint) { $null } else { [int]$ExitCodeHint })
    }
}

# Читання JSON-файлу як ДАНИХ (ConvertFrom-Json), без виконання. Ніколи не
# кидає: пошкоджений файл — це результат, а не виняток.
function Read-BRAVOUpdateDiscoveryJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = [pscustomobject]@{ Present = $false; Valid = $false; Data = $null; Error = $null }
    $exists = $false
    try { $exists = [System.IO.File]::Exists($Path) } catch { $exists = $false }
    if (-not $exists) { return $result }
    $result.Present = $true

    try {
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($text)) {
            $result.Error = 'файл порожній'
            return $result
        }
        $parsed = $text | ConvertFrom-Json
        if ($null -eq $parsed -or $parsed -is [System.Array] -or $parsed -is [string] -or $parsed -is [ValueType]) {
            $result.Error = 'очікувався JSON-об''єкт'
            return $result
        }
        $result.Data = $parsed
        $result.Valid = $true
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

# Нормалізація шляху для порівняння/дедуплікації. Некоректний шлях лишаємо
# як є (рішення про нього ухвалює викликач, а не виняток).
function ConvertTo-BRAVOUpdateDiscoveryPath {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $expanded = $Path.Trim().Trim('"')
    try { $expanded = [System.IO.Path]::GetFullPath($expanded) } catch { $null = $_ }
    if ($expanded.Length -gt 3) { $expanded = $expanded.TrimEnd('\', '/') }
    return $expanded
}

# Root «схожий на встановлений», якщо є VERSION.json або RUNTIME_MANIFEST.json.
function Test-BRAVOUpdateDiscoveryRootInstalled {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    try {
        return ([System.IO.File]::Exists((Join-Path $Root 'VERSION.json')) -or
            [System.IO.File]::Exists((Join-Path $Root 'RUNTIME_MANIFEST.json')))
    } catch {
        return $false
    }
}

# Виклик довіреного guard-а з комплекту ІНСТАЛЯТОРА (не з цільового root —
# цільовий може бути підмінений, саме його ми й перевіряємо).
#
# ЧОМУ dot-source БЕЗПЕЧНИЙ: BRAVO_RUNTIME_GUARD.ps1 виконує головний блок
# лише за `$MyInvocation.InvocationName -ne '.'`; при dot-source він тільки
# оголошує функції (так його підключає кожен entrypoint). Dot-source
# відбувається в локальній області цієї функції, тож нічого не просочується
# в область модуля. ПАСТКА: param-блок guard-а при dot-source перезаписує
# змінні $RuntimeRoot/$ManifestPath/$Mode/$ManifestContent у викликачі —
# тому вхідні значення тут мають інші імена.
function Invoke-BRAVOUpdateDiscoveryGuard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [switch]$CheckIntegrity,
        [string]$PackageVersionText,
        [string]$KnownStableVersionText
    )

    $outcome = [pscustomobject]@{
        Loaded              = $false
        Integrity           = $null
        PackageVersionValid = $null
        StableVersionValid  = $null
        StableIsNewer       = $false
        Message             = $null
    }

    $guardFile = Join-Path $script:BRAVOUpdateToolkitRoot 'BRAVO_RUNTIME_GUARD.ps1'
    $inputRoot = $TargetRoot
    $inputPackage = $PackageVersionText
    $inputStable = $KnownStableVersionText
    $inputIntegrity = [bool]$CheckIntegrity

    if (-not [System.IO.File]::Exists($guardFile)) {
        $outcome.Message = 'BRAVO_RUNTIME_GUARD.ps1 не знайдено в комплекті інсталятора'
        return $outcome
    }

    try {
        . $guardFile
    } catch {
        $outcome.Message = "не вдалося завантажити guard: $($_.Exception.Message)"
        return $outcome
    }
    foreach ($guardFunction in @('Test-BRAVORuntimeManifestIntegrity', 'ConvertTo-BRAVOComparableVersion', 'Compare-BRAVOComparableVersion')) {
        if ($null -eq (Get-Command -Name $guardFunction -CommandType Function -ErrorAction SilentlyContinue)) {
            $outcome.Message = "guard не оголосив $guardFunction"
            return $outcome
        }
    }
    $outcome.Loaded = $true

    if ($inputIntegrity) {
        try {
            $outcome.Integrity = Test-BRAVORuntimeManifestIntegrity `
                -RuntimeRoot $inputRoot `
                -ManifestPath (Join-Path $inputRoot 'RUNTIME_MANIFEST.json') `
                -Mode Enforce
        } catch {
            $outcome.Message = "перевірка цілісності не відпрацювала: $($_.Exception.Message)"
        }
    }

    $packageComparable = $null
    if (-not [string]::IsNullOrWhiteSpace($inputPackage)) {
        $packageComparable = ConvertTo-BRAVOComparableVersion -Text $inputPackage
        $outcome.PackageVersionValid = ($null -ne $packageComparable)
    }
    if (-not [string]::IsNullOrWhiteSpace($inputStable)) {
        $stableComparable = ConvertTo-BRAVOComparableVersion -Text $inputStable
        $outcome.StableVersionValid = ($null -ne $stableComparable)
        # «Новіший stable» лише коли обидві версії коректні й stable без
        # prerelease: UpdateAvailable не можна вивести з неперевіреного тексту.
        if ($null -ne $stableComparable -and $null -ne $packageComparable -and $null -eq $stableComparable.Prerelease) {
            $outcome.StableIsNewer = ((Compare-BRAVOComparableVersion -Left $stableComparable -Right $packageComparable) -gt 0)
        }
    }
    return $outcome
}

# Peek lifecycle/operation lock БЕЗ захоплення. Якщо W2-функція
# Test-BRAVOUpdateOperationLockActive доступна й приймає шлях — довіряємо
# їй (вона знає семантику holder-а); інакше мінімальний власний peek:
# файл, який не відкривається на читання через sharing violation, тримає
# інший процес. Короткочасний read-handle з FileShare.ReadWrite|Delete не
# блокує жодного власника, окрім мікросекундного вікна відкриття.
function Get-BRAVOUpdateDiscoveryLockPeek {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LockPath)

    $peek = [pscustomobject]@{ Held = $false; Description = $null; Evaluated = $true }
    $present = $false
    try { $present = [System.IO.File]::Exists($LockPath) } catch { $present = $false }
    if (-not $present) { return $peek }

    $w2 = Get-Command -Name 'Test-BRAVOUpdateOperationLockActive' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $w2) {
        $pathParameter = $null
        foreach ($candidate in @('LockPath', 'Path', 'OperationLockPath')) {
            if ($w2.Parameters.ContainsKey($candidate)) { $pathParameter = $candidate; break }
        }
        if ($null -ne $pathParameter) {
            try {
                $arguments = @{}
                $arguments[$pathParameter] = $LockPath
                $active = Test-BRAVOUpdateOperationLockActive @arguments
                $activeValue = $active
                if ($active -isnot [bool]) {
                    $activeValue = [bool](Get-BRAVOUpdateDiscoveryProperty -InputObject $active -Name 'Active' -Default (Get-BRAVOUpdateDiscoveryProperty -InputObject $active -Name 'Held' -Default $false))
                }
                $peek.Held = [bool]$activeValue
                if ($peek.Held) { $peek.Description = "lock активний: $LockPath" }
                return $peek
            } catch {
                # Падіння W2-перевірки не повинно ховати lock: переходимо на peek нижче.
                $null = $_
            }
        }
    }

    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $LockPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        # Відкрилось — ніхто не тримає ексклюзивно. Файл-holder може лишитись
        # від попередньої операції, це не «held».
    } catch [System.IO.IOException] {
        $peek.Held = $true
        $peek.Description = "файл lock утримується іншим процесом: $LockPath"
    } catch {
        # Немає прав на читання тощо — стан невідомий; не стверджуємо held.
        $peek.Evaluated = $false
        $peek.Description = "не вдалося перевірити lock: $LockPath"
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return $peek
}

# Відкрита операція з журналу. Пріоритет — W1 Get-BRAVOUpdateOpenJournal;
# fallback — мінімальне читання <StateRoot>\Journal\*.json (CONTRACTS §8).
# Пошкоджений журнал fail closed: вважаємо операцію відкритою з
# mutationStarted = $true (невідомо, чи runtime вже змінювали).
function Get-BRAVOUpdateDiscoveryInterruptedOperation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $none = [pscustomobject][ordered]@{
        present = $false; operationId = $null; action = $null
        lastCompletedPhase = $null; mutationStarted = $false; journalPath = $null
    }
    $report = [pscustomobject]@{ Operation = $none; Evaluated = $true; Message = $null; Corrupt = $false }

    $found = $null
    $foundPath = $null
    $w1 = Get-Command -Name 'Get-BRAVOUpdateOpenJournal' -CommandType Function -ErrorAction SilentlyContinue
    $usedW1 = $false
    if ($null -ne $w1) {
        try {
            $raw = @(Get-BRAVOUpdateOpenJournal -StateRoot $StateRoot)
            $usedW1 = $true
            $items = @($raw | Where-Object { $null -ne $_ })
            if ($items.Count -gt 0) {
                $pick = $items | Sort-Object -Property @{ Expression = { [bool](Get-BRAVOUpdateDiscoveryProperty -InputObject (Get-BRAVOUpdateDiscoveryProperty -InputObject $_ -Name 'journal' -Default $_) -Name 'mutationStarted' -Default $false) }; Descending = $true } | Select-Object -First 1
                $wrapped = Get-BRAVOUpdateDiscoveryProperty -InputObject $pick -Name 'journal' -Default $null
                $found = $(if ($null -ne $wrapped) { $wrapped } else { $pick })
                foreach ($pathName in @('journalPath', 'Path', 'path')) {
                    $candidatePath = Get-BRAVOUpdateDiscoveryProperty -InputObject $pick -Name $pathName -Default $null
                    if ($null -ne $candidatePath) { $foundPath = [string]$candidatePath; break }
                }
            }
        } catch {
            $usedW1 = $false
            $report.Message = "Get-BRAVOUpdateOpenJournal: $($_.Exception.Message)"
        }
    }

    if (-not $usedW1) {
        $journalDirectory = Join-Path $StateRoot 'Journal'
        $files = @()
        try {
            if ([System.IO.Directory]::Exists($journalDirectory)) {
                $files = @([System.IO.Directory]::GetFiles($journalDirectory, '*.json') | Sort-Object)
            }
        } catch {
            $report.Evaluated = $false
            $report.Message = "не вдалося прочитати каталог журналів: $($_.Exception.Message)"
            return $report
        }
        $candidates = New-Object System.Collections.ArrayList
        foreach ($file in $files) {
            $parsedJournal = Read-BRAVOUpdateDiscoveryJson -Path $file
            if (-not $parsedJournal.Valid) {
                $report.Corrupt = $true
                $fallbackId = [System.IO.Path]::GetFileNameWithoutExtension($file)
                $corrupt = [pscustomobject]@{ operationId = $fallbackId; action = $null; lastCompletedPhase = $null; mutationStarted = $true; state = 'Open' }
                [void]$candidates.Add([pscustomobject]@{ Journal = $corrupt; Path = $file })
                continue
            }
            $journalState = [string](Get-BRAVOUpdateDiscoveryProperty -InputObject $parsedJournal.Data -Name 'state' -Default '')
            if ($journalState -eq 'Open') {
                [void]$candidates.Add([pscustomobject]@{ Journal = $parsedJournal.Data; Path = $file })
            }
        }
        if ($candidates.Count -gt 0) {
            $best = @($candidates.ToArray() | Sort-Object -Property @{ Expression = { [bool](Get-BRAVOUpdateDiscoveryProperty -InputObject $_.Journal -Name 'mutationStarted' -Default $false) }; Descending = $true }) | Select-Object -First 1
            $found = $best.Journal
            $foundPath = $best.Path
        }
    }

    if ($null -ne $found) {
        $report.Operation = [pscustomobject][ordered]@{
            present            = $true
            operationId        = Get-BRAVOUpdateDiscoveryProperty -InputObject $found -Name 'operationId' -Default $null
            action             = Get-BRAVOUpdateDiscoveryProperty -InputObject $found -Name 'action' -Default $null
            lastCompletedPhase = Get-BRAVOUpdateDiscoveryProperty -InputObject $found -Name 'lastCompletedPhase' -Default $null
            mutationStarted    = [bool](Get-BRAVOUpdateDiscoveryProperty -InputObject $found -Name 'mutationStarted' -Default $false)
            journalPath        = $foundPath
        }
    }
    return $report
}

function Get-BRAVOInstallationState {
    <#
    .SYNOPSIS
        Read-only discovery встановлення BRAVO -> InstallationState (CONTRACTS §3).
    .DESCRIPTION
        Нічого не пише, не бере lock-ів, не змінює задач. Явний -RuntimeRoot
        завжди перемагає; без нього кандидати беруться з -CandidateRoots
        (+ шляхи дій зареєстрованих задач лише з -IncludeScheduler).
        Кілька встановлених кандидатів без явного root -> Ambiguous, без вгадування.
    #>
    [CmdletBinding()]
    param(
        [string]$RuntimeRoot,
        [string[]]$CandidateRoots,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$VersionStatePath,
        [Parameter(Mandatory = $true)][string]$OperationLockPath,
        [Parameter(Mandatory = $true)][string]$LockRoot,
        [System.Collections.IDictionary]$Adapter,
        [switch]$IncludeScheduler,
        [switch]$IncludeCredentials,
        [string]$KnownStableVersion
    )

    $findings = New-Object System.Collections.ArrayList
    $nowUtc = $null
    if ($null -ne $Adapter -and $null -ne (Get-BRAVOUpdateDiscoveryProperty -InputObject $Adapter -Name 'Now' -Default $null)) {
        try { $nowUtc = ([datetime](& $Adapter['Now'])).ToUniversalTime().ToString('o') } catch { $nowUtc = $null }
    }
    if ($null -eq $nowUtc) { $nowUtc = [datetime]::UtcNow.ToString('o') }

    # --- Adapter: якщо не передано, а читання задач/credentials потрібне, —
    # канонічний default (якщо вже інтегрований), інакше scheduler = Unknown.
    $effectiveAdapter = $Adapter
    if ($null -eq $effectiveAdapter -and ($IncludeScheduler -or $IncludeCredentials)) {
        $defaultAdapterCommand = Get-Command -Name 'New-BRAVOUpdateDefaultAdapter' -CommandType Function -ErrorAction SilentlyContinue
        if ($null -ne $defaultAdapterCommand) {
            try { $effectiveAdapter = New-BRAVOUpdateDefaultAdapter } catch { $effectiveAdapter = $null }
        }
    }

    # --- ОС (підтримуваний tier) ---
    $osUnsupported = $false
    try {
        if ($null -eq (Get-Command -Name 'Get-BRAVOOSSupportTier' -CommandType Function -ErrorAction SilentlyContinue)) {
            $compatibilityManifest = Join-Path $script:BRAVOUpdateToolkitRoot 'modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1'
            if ([System.IO.File]::Exists($compatibilityManifest)) {
                Import-Module -Name $compatibilityManifest -DisableNameChecking -ErrorAction Stop
            }
        }
        $tier = Get-BRAVOOSSupportTier
        $tierName = [string](Get-BRAVOUpdateDiscoveryProperty -InputObject $tier -Name 'Tier' -Default 'Unknown')
        $tierMessage = [string](Get-BRAVOUpdateDiscoveryProperty -InputObject $tier -Name 'Message' -Default '')
        if ($tierName -eq 'Unsupported') {
            $osUnsupported = $true
            [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.OsSupport' -Severity Blocker `
                -Title 'Операційна система не підтримується' `
                -Meaning 'Ця версія Windows або PowerShell поза підтримуваним рівнем; інсталятор не гарантує коректну роботу.' `
                -Action 'Використайте підтримувану ОС (див. документацію з сумісності) або зверніться до підтримки.' `
                -Details $tierMessage))
        } else {
            [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.OsSupport' -Severity Ok `
                -Title 'Операційна система підтримується' `
                -Meaning "Рівень підтримки: $tierName." -Details $tierMessage))
        }
    } catch {
        [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.OsSupport' -Severity Warning `
            -Title 'Не вдалося визначити рівень підтримки ОС' `
            -Meaning 'Рівень підтримки ОС не підтверджено; перевірку буде повторено у Preflight.' `
            -Action 'Повторіть перевірку; якщо помилка повторюється — перевірте комплект BRAVO.Compatibility.' `
            -Details $_.Exception.Message))
    }

    # --- Scheduler: читаємо один раз, шляхи дій також дають кандидатів ---
    $taskList = $null
    $schedulerStatus = 'Unknown'
    $schedulerTasks = @()
    $taskActionPaths = @()
    if ($IncludeScheduler) {
        $getTasks = Get-BRAVOUpdateDiscoveryProperty -InputObject $effectiveAdapter -Name 'GetManagedTasks' -Default $null
        if ($null -eq $getTasks) {
            [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Scheduler' -Severity Warning `
                -Title 'Стан задач планувальника не прочитано' `
                -Meaning 'Adapter без GetManagedTasks: стан задач невідомий.' `
                -Action 'Повторіть discovery із робочим adapter-ом.'))
        } else {
            try {
                $taskList = @(& $getTasks | Where-Object { $null -ne $_ })
            } catch {
                $taskList = $null
                [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Scheduler' -Severity Warning `
                    -Title 'Не вдалося прочитати задачі планувальника' `
                    -Meaning 'Стан задач BRAVO невідомий; discovery продовжено без нього.' `
                    -Action 'Перевірте доступ до Task Scheduler і повторіть.' -Details $_.Exception.Message))
            }
        }
        if ($null -ne $taskList) {
            $normalized = New-Object System.Collections.ArrayList
            $paths = New-Object System.Collections.ArrayList
            foreach ($task in $taskList) {
                $taskExists = Get-BRAVOUpdateDiscoveryProperty -InputObject $task -Name 'exists' -Default $true
                [void]$normalized.Add([pscustomobject][ordered]@{
                    name    = [string](Get-BRAVOUpdateDiscoveryProperty -InputObject $task -Name 'name' -Default '')
                    path    = [string](Get-BRAVOUpdateDiscoveryProperty -InputObject $task -Name 'path' -Default '')
                    exists  = [bool]$taskExists
                    state   = [string](Get-BRAVOUpdateDiscoveryProperty -InputObject $task -Name 'state' -Default 'Unknown')
                    enabled = [bool](Get-BRAVOUpdateDiscoveryProperty -InputObject $task -Name 'enabled' -Default $false)
                })
                # Шлях дії задачі — ЄДИНЕ джерело додаткових кандидатів root.
                foreach ($actionName in @('actionPath', 'actionPaths')) {
                    $actionValue = Get-BRAVOUpdateDiscoveryProperty -InputObject $task -Name $actionName -Default $null
                    foreach ($actionItem in @($actionValue)) {
                        if ($null -ne $actionItem -and -not [string]::IsNullOrWhiteSpace([string]$actionItem)) {
                            [void]$paths.Add([string]$actionItem)
                        }
                    }
                }
            }
            $schedulerTasks = @($normalized.ToArray())
            $taskActionPaths = @($paths.ToArray())
            $existingCount = @($schedulerTasks | Where-Object { $_.exists }).Count
            $healthyCount = @($schedulerTasks | Where-Object { $_.exists -and $_.enabled }).Count
            if ($schedulerTasks.Count -eq 0 -or $existingCount -eq 0) {
                $schedulerStatus = 'Missing'
            } elseif ($healthyCount -eq $schedulerTasks.Count) {
                $schedulerStatus = 'Ok'
            } else {
                $schedulerStatus = 'Partial'
            }
            switch ($schedulerStatus) {
                'Ok' {
                    [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Scheduler' -Severity Ok `
                        -Title 'Задачі планувальника на місці' -Meaning 'Усі керовані задачі існують і увімкнені.'))
                }
                'Partial' {
                    [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Scheduler' -Severity Warning `
                        -Title 'Задачі планувальника неповні' `
                        -Meaning 'Частина керованих задач відсутня або вимкнена; автоматичні операції можуть не виконуватись.' `
                        -Action 'Запустіть Відновлення, щоб привести задачі до очікуваного стану.'))
                }
                'Missing' {
                    [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Scheduler' -Severity Warning `
                        -Title 'Задач планувальника не знайдено' `
                        -Meaning 'Жодної керованої задачі BRAVO немає; автоматичні операції не виконуватимуться.' `
                        -Action 'Запустіть Відновлення або налаштуйте розклад.'))
                }
            }
        }
    }

    # --- Вибір root ---
    $explicitRoot = ConvertTo-BRAVOUpdateDiscoveryPath -Path $RuntimeRoot
    $allCandidates = New-Object System.Collections.ArrayList
    $selectedRoot = $null
    $ambiguous = $false

    if ($null -ne $explicitRoot) {
        $selectedRoot = $explicitRoot
        if (Test-BRAVOUpdateDiscoveryRootInstalled -Root $explicitRoot) {
            [void]$allCandidates.Add($explicitRoot)
        }
    } else {
        $rawCandidates = New-Object System.Collections.ArrayList
        if ($null -ne $CandidateRoots -and $CandidateRoots.Count -gt 0) {
            foreach ($item in $CandidateRoots) { [void]$rawCandidates.Add($item) }
        } else {
            # Production-default обчислює лише Get-BRAVOUpdateDefaultPaths.
            $defaultPathsCommand = Get-Command -Name 'Get-BRAVOUpdateDefaultPaths' -CommandType Function -ErrorAction SilentlyContinue
            if ($null -ne $defaultPathsCommand) {
                try {
                    $defaultRoot = Get-BRAVOUpdateDiscoveryProperty -InputObject (Get-BRAVOUpdateDefaultPaths) -Name 'RuntimeRoot' -Default $null
                    if ($null -ne $defaultRoot) { [void]$rawCandidates.Add([string]$defaultRoot) }
                } catch { $null = $_ }
            }
        }
        foreach ($actionPath in $taskActionPaths) {
            $normalizedAction = ConvertTo-BRAVOUpdateDiscoveryPath -Path $actionPath
            if ($null -eq $normalizedAction) { continue }
            # Дія вказує на файл скрипта -> root = його каталог.
            $actionDirectory = $normalizedAction
            if ([System.IO.Path]::HasExtension($normalizedAction)) {
                try { $actionDirectory = [System.IO.Path]::GetDirectoryName($normalizedAction) } catch { $actionDirectory = $null }
            }
            if (-not [string]::IsNullOrWhiteSpace($actionDirectory)) { [void]$rawCandidates.Add($actionDirectory) }
        }
        $seen = @{}
        foreach ($item in $rawCandidates) {
            $normalizedItem = ConvertTo-BRAVOUpdateDiscoveryPath -Path ([string]$item)
            if ($null -eq $normalizedItem) { continue }
            $key = $normalizedItem.ToUpperInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            if (Test-BRAVOUpdateDiscoveryRootInstalled -Root $normalizedItem) { [void]$allCandidates.Add($normalizedItem) }
        }
        if ($allCandidates.Count -eq 1) {
            $selectedRoot = $allCandidates[0]
        } elseif ($allCandidates.Count -gt 1) {
            $ambiguous = $true
            [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Ambiguous' -Severity Blocker `
                -Title 'Знайдено кілька встановлень BRAVO' `
                -Meaning 'Інсталятор не вгадує, яке з них цільове, щоб не змінити не те встановлення.' `
                -Action 'Вкажіть цільовий каталог явно (RuntimeRoot).' `
                -Details ($allCandidates.ToArray() -join '; ')))
        }
    }

    # --- Дані вибраного root ---
    $version = $null
    $versionProblem = $false
    $integrity = [pscustomobject][ordered]@{ status = 'Unknown'; checkedCount = 0; mismatchedCount = 0; missingCount = 0; unknownCount = 0; message = 'не перевірялось' }
    $localConfigPresent = $false
    $legacyConfigPresent = $false
    $localSchema = $null
    $migration = [pscustomobject][ordered]@{ blocked = $null; reasons = @('not evaluated') }
    $partialLayout = $false
    $rootInstalled = $false
    $stableNewer = $false

    if ($null -ne $selectedRoot) {
        $rootInstalled = Test-BRAVOUpdateDiscoveryRootInstalled -Root $selectedRoot
        $rootExists = $false
        try { $rootExists = [System.IO.Directory]::Exists($selectedRoot) } catch { $rootExists = $false }

        if ($rootInstalled) {
            $versionRead = Read-BRAVOUpdateDiscoveryJson -Path (Join-Path $selectedRoot 'VERSION.json')
            $packageText = $null
            if ($versionRead.Valid) {
                $packageText = [string](Get-BRAVOUpdateDiscoveryProperty -InputObject $versionRead.Data -Name 'packageVersion' -Default '')
                $version = [pscustomobject][ordered]@{
                    packageVersion = $(if ([string]::IsNullOrWhiteSpace($packageText)) { $null } else { $packageText })
                    releaseChannel = Get-BRAVOUpdateDiscoveryProperty -InputObject $versionRead.Data -Name 'releaseChannel' -Default $null
                    buildId        = Get-BRAVOUpdateDiscoveryProperty -InputObject $versionRead.Data -Name 'buildId' -Default $null
                    sourceCommit   = Get-BRAVOUpdateDiscoveryProperty -InputObject $versionRead.Data -Name 'sourceCommit' -Default $null
                    releaseDate    = Get-BRAVOUpdateDiscoveryProperty -InputObject $versionRead.Data -Name 'releaseDate' -Default $null
                }
                if ($null -eq $version.packageVersion) {
                    $versionProblem = $true
                    [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.VersionFile' -Severity Blocker `
                        -Title 'VERSION.json без packageVersion' `
                        -Meaning 'Версію встановленого комплекту визначити неможливо.' `
                        -Action 'Запустіть Відновлення.'))
                }
            } else {
                $versionProblem = $true
                $versionDetail = $(if ($versionRead.Present) { [string]$versionRead.Error } else { 'файл відсутній' })
                [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.VersionFile' -Severity Blocker `
                    -Title $(if ($versionRead.Present) { 'VERSION.json пошкоджений' } else { 'VERSION.json відсутній' }) `
                    -Meaning 'Версію встановленого комплекту визначити неможливо; встановлення потребує відновлення.' `
                    -Action 'Запустіть Відновлення.' -Details $versionDetail))
            }

            # Цілісність і порівняння версій — довіреним guard-ом інсталятора.
            $packageForGuard = ''
            if ($null -ne $version -and $null -ne $version.packageVersion) { $packageForGuard = [string]$version.packageVersion }
            $guardOutcome = Invoke-BRAVOUpdateDiscoveryGuard -TargetRoot $selectedRoot -CheckIntegrity `
                -PackageVersionText $packageForGuard -KnownStableVersionText $KnownStableVersion
            if (-not $guardOutcome.Loaded -or $null -eq $guardOutcome.Integrity) {
                $integrity.message = $(if ($null -ne $guardOutcome.Message) { [string]$guardOutcome.Message } else { 'перевірка недоступна' })
                [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Integrity' -Severity Warning `
                    -Title 'Цілісність комплекту не перевірено' `
                    -Meaning 'Довірений guard недоступний; цілісність буде перевірено у Preflight.' `
                    -Action 'Переконайтесь, що комплект інсталятора цілий.' -Details $integrity.message))
            } else {
                $guardResult = $guardOutcome.Integrity
                $mismatched = @($guardResult.MismatchedFiles)
                $missingFiles = @($guardResult.MissingFiles)
                $unknownFiles = @($guardResult.UnknownFiles)
                $integrity = [pscustomobject][ordered]@{
                    status          = $(if ($guardResult.IsValid) { 'Valid' } else { 'Invalid' })
                    checkedCount    = [int]$guardResult.CheckedCount
                    mismatchedCount = $mismatched.Count
                    missingCount    = $missingFiles.Count
                    unknownCount    = $unknownFiles.Count
                    message         = [string]$guardResult.Message
                }
                if ($guardResult.IsValid) {
                    [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Integrity' -Severity Ok `
                        -Title 'Цілісність комплекту підтверджена' `
                        -Meaning "Перевірено файлів: $($integrity.checkedCount)."))
                } else {
                    [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Integrity' -Severity Blocker `
                        -Title 'Цілісність комплекту порушена' `
                        -Meaning 'Файли встановленого комплекту не збігаються з RUNTIME_MANIFEST.json; працювати з ним небезпечно.' `
                        -Action 'Запустіть Відновлення з перевіреного релізного артефакту.' `
                        -Details $integrity.message -ExitCodeHint 33))
                }
            }
            if ($guardOutcome.PackageVersionValid -eq $false) {
                $versionProblem = $true
                [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.VersionFile' -Severity Blocker `
                    -Title 'packageVersion у VERSION.json некоректний' `
                    -Meaning 'Версія не відповідає формату X.Y.Z[-prerelease]; порівняти її неможливо.' `
                    -Action 'Запустіть Відновлення.'))
            }
            if ($guardOutcome.StableVersionValid -eq $false) {
                [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.KnownStable' -Severity Warning `
                    -Title 'Відому stable-версію не розпізнано' `
                    -Meaning 'Наявність оновлення не оцінювалась.' `
                    -Action 'Перевірте значення KnownStableVersion.'))
            }
            $stableNewer = [bool]$guardOutcome.StableIsNewer
        } elseif ($rootExists) {
            # Немає VERSION.json і manifest, але є файли BRAVO — неповне встановлення.
            try {
                $leftovers = @([System.IO.Directory]::GetFiles($selectedRoot, 'BRAVO_*.ps1'))
                if ($leftovers.Count -gt 0) { $partialLayout = $true }
            } catch { $null = $_ }
            if ($partialLayout) {
                [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.PartialInstall' -Severity Blocker `
                    -Title 'Знайдено залишки комплекту без VERSION.json і RUNTIME_MANIFEST.json' `
                    -Meaning 'Каталог містить файли BRAVO, але не є повним встановленням.' `
                    -Action 'Запустіть Відновлення або очистьте каталог вручну.' -Details $selectedRoot))
            }
        }

        # Конфігурація: лише наявність файлів. Схему local-конфігу не
        # перевіряємо тут: BRAVO_CONFIG_LOADER.ps1 має side effects (глобальні
        # змінні) і не підключається в процес discovery; це робить Preflight.
        try {
            $localConfigPresent = [System.IO.File]::Exists((Join-Path $selectedRoot 'BRAVO.local.config'))
            $legacyConfigPresent = [System.IO.File]::Exists((Join-Path $selectedRoot 'BRAVO.config'))
        } catch { $null = $_ }
        if ($localConfigPresent) { $localSchema = 'Unknown' }

        if ($rootInstalled -or $partialLayout) {
            $blockerCommand = Get-Command -Name 'Test-BRAVOConfigMigrationBlocker' -CommandType Function -ErrorAction SilentlyContinue
            if ($null -ne $blockerCommand) {
                try {
                    $blockerResult = Test-BRAVOConfigMigrationBlocker -RuntimeRoot $selectedRoot
                    $blockedFlag = Get-BRAVOUpdateDiscoveryProperty -InputObject $blockerResult -Name 'Blocked' -Default (Get-BRAVOUpdateDiscoveryProperty -InputObject $blockerResult -Name 'blocked' -Default $null)
                    $reasonList = Get-BRAVOUpdateDiscoveryProperty -InputObject $blockerResult -Name 'Reasons' -Default (Get-BRAVOUpdateDiscoveryProperty -InputObject $blockerResult -Name 'reasons' -Default @())
                    $migration = [pscustomobject][ordered]@{
                        blocked = $(if ($null -eq $blockedFlag) { $null } else { [bool]$blockedFlag })
                        reasons = @($reasonList | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
                    }
                    if ($migration.blocked -eq $true) {
                        [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.MigrationBlocker' -Severity Warning `
                            -Title 'Міграція конфігурації не завершена' `
                            -Meaning 'Старий BRAVO.config блокує оновлення, доки міграцію не завершено.' `
                            -Action 'Завершіть міграцію конфігурації за runbook.' `
                            -Details ($migration.reasons -join '; ') -ExitCodeHint 30))
                    }
                } catch {
                    $migration = [pscustomobject][ordered]@{ blocked = $null; reasons = @('не вдалося оцінити') }
                }
            }
        }
    } elseif (-not $ambiguous) {
        [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.NotInstalled' -Severity NotApplicable `
            -Title 'Встановлення BRAVO не знайдено' `
            -Meaning 'У жодному з кандидатів немає VERSION.json або RUNTIME_MANIFEST.json.' `
            -Action 'Виконайте Встановлення.'))
    }

    # --- version state (лише читання) ---
    $recordedVersion = $null
    $stateKind = 'Sandbox'
    try {
        $commonData = [Environment]::GetFolderPath('CommonApplicationData')
        $productionPrefix = (Join-Path $commonData 'BRAVO').TrimEnd('\') + '\'
        $fullStatePath = [System.IO.Path]::GetFullPath($VersionStatePath)
        if ($fullStatePath.StartsWith($productionPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { $stateKind = 'Production' }
    } catch { $stateKind = 'Sandbox' }
    $versionStateRead = Read-BRAVOUpdateDiscoveryJson -Path $VersionStatePath
    if ($versionStateRead.Valid) {
        $recorded = Get-BRAVOUpdateDiscoveryProperty -InputObject $versionStateRead.Data -Name 'highestVersionFull' -Default $null
        if ($null -ne $recorded -and -not [string]::IsNullOrWhiteSpace([string]$recorded)) { $recordedVersion = [string]$recorded }
    } elseif ($versionStateRead.Present) {
        [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.VersionState' -Severity Warning `
            -Title 'Файл стану версій пошкоджений' `
            -Meaning 'Захист від відкату не зможе спертися на записану версію.' `
            -Action 'Перевірте стан у Preflight; не видаляйте файл вручну.' -Details ([string]$versionStateRead.Error)))
    }
    $versionStateInfo = [pscustomobject][ordered]@{ recordedVersion = $recordedVersion; statePathKind = $stateKind }

    # --- credentials (за замовчуванням Unknown; adapter лише з прапорцем) ---
    $credentials = [pscustomobject][ordered]@{ status = 'Unknown'; items = @() }
    if ($IncludeCredentials) {
        $testPresence = Get-BRAVOUpdateDiscoveryProperty -InputObject $effectiveAdapter -Name 'TestCredentialPresence' -Default $null
        if ($null -eq $testPresence) {
            [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Credentials' -Severity Warning `
                -Title 'Наявність облікових даних не перевірено' `
                -Meaning 'Adapter без TestCredentialPresence.' -Action 'Повторіть із робочим adapter-ом.'))
        } else {
            try {
                $allowedPresence = @('Found', 'Missing', 'Unknown', 'NotRequired')
                $items = New-Object System.Collections.ArrayList
                foreach ($entry in @(& $testPresence | Where-Object { $null -ne $_ })) {
                    $presence = [string](Get-BRAVOUpdateDiscoveryProperty -InputObject $entry -Name 'credentialPresence' -Default 'Unknown')
                    if ($allowedPresence -notcontains $presence) { $presence = 'Unknown' }
                    # Копіюємо лише три відомі поля: жодних зайвих (потенційно секретних) властивостей.
                    [void]$items.Add([pscustomobject][ordered]@{
                        component          = [string](Get-BRAVOUpdateDiscoveryProperty -InputObject $entry -Name 'component' -Default '')
                        account            = [string](Get-BRAVOUpdateDiscoveryProperty -InputObject $entry -Name 'account' -Default 'CurrentUser')
                        credentialPresence = $presence
                    })
                }
                $credentials = [pscustomobject][ordered]@{ status = 'Checked'; items = @($items.ToArray()) }
                if (@($items.ToArray() | Where-Object { $_.credentialPresence -eq 'Missing' }).Count -gt 0) {
                    [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Credentials' -Severity Warning `
                        -Title 'Облікові дані частини компонентів відсутні' `
                        -Meaning 'Відповідні задачі не зможуть автентифікуватись.' `
                        -Action 'Налаштуйте облікові дані у Конфігураторі.'))
                }
            } catch {
                [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Credentials' -Severity Warning `
                    -Title 'Не вдалося перевірити облікові дані' `
                    -Meaning 'Наявність облікових даних невідома.' -Action 'Повторіть перевірку.' -Details $_.Exception.Message))
            }
        }
    }

    # --- перерваний журнал і lock ---
    $journalReport = Get-BRAVOUpdateDiscoveryInterruptedOperation -StateRoot $StateRoot
    $interrupted = $journalReport.Operation
    if (-not $journalReport.Evaluated) {
        [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Journal' -Severity Warning `
            -Title 'Журнал операцій не прочитано' `
            -Meaning 'Незавершену операцію виявити не вдалося.' -Action 'Перевірте доступ до каталогу стану.' `
            -Details ([string]$journalReport.Message)))
    }
    if ($interrupted.present) {
        $journalTitle = 'Знайдено перервану операцію'
        $journalMeaning = 'Операція не встигла змінити runtime; її треба закрити перед новою.'
        if ($interrupted.mutationStarted) {
            $journalTitle = 'Знайдено перервану операцію зі змінами runtime'
            $journalMeaning = 'Runtime міг бути змінений наполовину; потрібен відкат до відомого справного стану.'
        }
        [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Journal' -Severity Blocker `
            -Title $journalTitle -Meaning $journalMeaning `
            -Action 'Запустіть Відновлення (recovery); нових операцій не починайте.' `
            -Details ("operationId=$($interrupted.operationId); phase=$($interrupted.lastCompletedPhase)")))
    }

    $heldDescriptions = New-Object System.Collections.ArrayList
    $lockHeld = $false
    foreach ($lockPath in @((Join-Path $LockRoot 'BRAVO_UPDATE.lock'), $OperationLockPath)) {
        if ([string]::IsNullOrWhiteSpace($lockPath)) { continue }
        $peek = Get-BRAVOUpdateDiscoveryLockPeek -LockPath $lockPath
        if ($peek.Held) {
            $lockHeld = $true
            [void]$heldDescriptions.Add([string]$peek.Description)
        }
    }
    if ($lockHeld) {
        [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Lock' -Severity Warning `
            -Title 'Інша операція BRAVO зараз виконується' `
            -Meaning 'Утримується lock життєвого циклу або операції.' `
            -Action 'Дочекайтеся завершення; процеси не зупиняйте.' `
            -Details ($heldDescriptions.ToArray() -join '; ') -ExitCodeHint 20))
    }
    $lockDescription = $null
    if ($lockHeld) { $lockDescription = ($heldDescriptions.ToArray() -join '; ') }
    $lifecycleLock = [pscustomobject][ordered]@{ held = $lockHeld; holderDescription = $lockDescription }

    # --- конфігурація ---
    $configuration = [pscustomobject][ordered]@{
        localConfigPresent     = $localConfigPresent
        legacyConfigPresent    = $legacyConfigPresent
        localConfigSchemaValid = $localSchema
        migrationBlocker       = $migration
    }

    # --- стан за пріоритетом CONTRACTS §3 ---
    # Увага: -and/-or в PowerShell мають однаковий пріоритет, тому групи в дужках явні.
    $channel = ''
    if ($null -ne $version -and $null -ne $version.releaseChannel) { $channel = [string]$version.releaseChannel }
    $schedulerIncomplete = ($IncludeScheduler -and $rootInstalled -and (($schedulerStatus -eq 'Partial') -or ($schedulerStatus -eq 'Missing')))
    $degraded = ($schedulerIncomplete -or ($migration.blocked -eq $true) -or ($localSchema -eq $false))

    $state = 'Installed'
    if ($osUnsupported) {
        $state = 'Unsupported'
    } elseif ($interrupted.present -and $interrupted.mutationStarted) {
        $state = 'RollbackRequired'
    } elseif ($interrupted.present) {
        $state = 'InterruptedUpdate'
    } elseif ($ambiguous) {
        $state = 'Ambiguous'
    } elseif ((-not $rootInstalled) -and (-not $partialLayout)) {
        $state = 'NotInstalled'
    } elseif ($partialLayout -or $versionProblem -or ($integrity.status -eq 'Invalid')) {
        $state = 'RepairRequired'
    } elseif ($degraded) {
        $state = 'Degraded'
    } elseif (($channel -ne '') -and ($channel -ne 'stable')) {
        $state = 'PrereleaseInstalled'
    } elseif ($stableNewer) {
        $state = 'UpdateAvailable'
    }

    if ($state -eq 'UpdateAvailable') {
        [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.UpdateAvailable' -Severity Ok `
            -Title 'Доступне оновлення' -Meaning "Відома stable-версія $KnownStableVersion новіша за встановлену." `
            -Action 'Запустіть Оновлення.'))
    } elseif ($state -eq 'PrereleaseInstalled') {
        [void]$findings.Add((New-BRAVOUpdateDiscoveryFinding -Id 'Discovery.Prerelease' -Severity Warning `
            -Title 'Встановлена передрелізна збірка' -Meaning "Канал випуску: $channel; це не stable." `
            -Action 'Для production використовуйте stable-реліз.'))
    }

    # --- збірка результату (канонічний конструктор W1, якщо його форма збігається) ---
    $values = [ordered]@{
        State                = $state
        RuntimeRoot          = $selectedRoot
        CandidateRoots       = @($allCandidates.ToArray())
        Version              = $version
        Integrity            = $integrity
        VersionState         = $versionStateInfo
        Configuration        = $configuration
        Scheduler            = [pscustomobject][ordered]@{ status = $schedulerStatus; tasks = @($schedulerTasks) }
        Credentials          = $credentials
        InterruptedOperation = $interrupted
        LifecycleLock        = $lifecycleLock
        Findings             = @($findings.ToArray())
    }
    $stateConstructor = Get-Command -Name 'New-BRAVOUpdateInstallationState' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $stateConstructor) {
        $constructorFits = $true
        foreach ($parameterName in $values.Keys) {
            if (-not $stateConstructor.Parameters.ContainsKey($parameterName)) { $constructorFits = $false }
        }
        if ($constructorFits) {
            try {
                $constructorArguments = @{}
                foreach ($parameterName in $values.Keys) { $constructorArguments[$parameterName] = $values[$parameterName] }
                return (New-BRAVOUpdateInstallationState @constructorArguments)
            } catch { $null = $_ }
        }
    }

    return [pscustomobject][ordered]@{
        schemaVersion        = 1
        generatedUtc         = $nowUtc
        state                = $values.State
        runtimeRoot          = $values.RuntimeRoot
        candidateRoots       = $values.CandidateRoots
        version              = $values.Version
        integrity            = $values.Integrity
        versionState         = $values.VersionState
        configuration        = $values.Configuration
        scheduler            = $values.Scheduler
        credentials          = $values.Credentials
        interruptedOperation = $values.InterruptedOperation
        lifecycleLock        = $values.LifecycleLock
        findings             = $values.Findings
    }
}
