# Автоматичний Discovery джерел BRAVO: визначення BRAVO_ROOT/WEB_ROOT і
# джерел MODEL/BLOG/BRAVOEXCH/BAZA_APP/BAZA_WWW/BACKUP_ROOT за встановленими
# Windows-службами та активним bravo.ini, з повним ручним перевизначенням
# через BRAVO.config.
#
# BRAVO_ROOT — каталог встановлення служби BRAVO (де лежить bravo.exe); він же
# EffectiveLIMSRoot при AUTO-визначенні (Resolve-BRAVOEffectiveLimsRoot).
# Не плутати з RuntimeRoot (BRAVO.config) — каталогом самого комплекту
# скриптів (де лежать Tools\/modules\/TOOLS_MANIFEST.json, завжди поруч зі
# скриптом, ніколи не через Discovery), із SystemLogRoot (каталог системних
# журналів) і з BackupRoot (куди зберігаються самі архіви). Усі чотири —
# окремі поняття, які легко сплутати через спільне слово "ARCHIV"/"архів".
#
# Мінімальна підтримувана версія: Windows PowerShell 3.0.
#
# Явна залежність від BRAVO.Compatibility (Get-BRAVOWmiInstance): кожен
# PowerShell-модуль має власний session state, тому імпорт Compatibility
# кудись ІНШИМ модулем/скриптом (наприклад, BRAVO.Health.Runtime.ps1 перед
# Import-BravoConfiguration) не робить її функції видимими тут — це підтвердив
# живий прогін BRAVO_HEALTH.ps1: Get-BRAVOWmiInstance була "не розпізнана"
# всередині Find-BRAVOServiceByCandidates, хоча той самий виклик успішно
# знаходив реальну службу Br-a-vo.web поза цим модулем. Той самий патерн уже
# в BRAVO.Notifications/BRAVO.ArchiveRuntime/BRAVO.ArchiveHelpers.
$compatibilityManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.Compatibility\BRAVO.Compatibility.psd1'
Import-Module -Name $compatibilityManifest -ErrorAction Stop

function Get-BRAVOServiceExecutablePath {
    # Парсить Win32_Service.PathName ("C:\...\bravo.exe" -k runservice ->
    # C:\...\bravo.exe). Перенесено з BRAVO.config без зміни поведінки:
    # Find-BRAVOWebBAZASource (BRAVO.config) продовжує використовувати цю
    # саму функцію з модуля.
    [CmdletBinding()]
    param([string]$PathName)

    $expandedPath = [Environment]::ExpandEnvironmentVariables(
        [string]$PathName
    ).Trim()
    if ($expandedPath -match '^\s*"([^"]+)"') {
        return $matches[1]
    }
    if ($expandedPath -match '^\s*([^\s]+)') {
        return $matches[1]
    }
    return $null
}

function Find-BRAVOServiceByCandidates {
    # Generic-версія enumerate-частини Find-BRAVOWebBAZASource: знаходить
    # встановлені служби за списком кандидатів імен (Name/DisplayName,
    # case-insensitive), опційно доповнює список службами, які запускають
    # виконуваний файл із заданою назвою (ExecutableNameFallback),
    # незалежно від імені самої служби — той самий підхід, що вже
    # застосований для httpd.exe. Активні (Running) служби завжди йдуть
    # перед зупиненими.
    #
    # Стан служби (Running/Stopped/Disabled) НЕ впливає на identity — той
    # самий принцип, що вже документує Resolve-BRAVOEffectiveLimsRoot:
    # шлях встановлення не залежить від того, чи служба зараз запущена, чи
    # дозволено її автозапуск. Раніше тут відкидались служби зі
    # StartMode=Disabled ("встановлені (не Disabled)"), що фактично
    # плутало "Disabled" із "не встановлено": Disabled-служба лишається
    # зареєстрованою в SCM із тим самим PathName, лише не запускається
    # автоматично/вручну. Наслідок (audit safety-review): адміністративне
    # вимкнення служби BRAVO Web (напр. планове обслуговування) непомітно
    # вимикало BAZA_WWW backup — service-state гейтив backup без жодної
    # реальної файлової помилки, хоча каталог DocumentRoot на диску лишався
    # доступним. Фільтр знято; недоступність каталогу тепер виявляє
    # виключно downstream файлова перевірка (Test-PathWithLog), а не WMI
    # StartMode.
    #
    # -Services дозволяє self-test підставити синтетичні Win32_Service-
    # подібні об'єкти замість реального WMI-запиту — той самий injectable-
    # патерн, що вже використовує Get-BRAVOOSSupportTier/
    # Get-BRAVOPowerShellUpdateRecommendation (modules\BRAVO.Compatibility).
    [CmdletBinding()]
    param(
        [string[]]$ServiceCandidates,
        [string]$ExecutableNameFallback,
        [object[]]$Services
    )

    if ($null -eq $Services) {
        try {
            $Services = @(
                Get-BRAVOWmiInstance -ClassName Win32_Service |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace([string]$_.PathName)
                    }
            )
        } catch {
            return @()
        }
    } else {
        $Services = @(
            $Services | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.PathName)
            }
        )
    }

    $ordered = New-Object System.Collections.Generic.List[object]
    foreach ($runningOnly in @($true, $false)) {
        foreach ($candidateName in @($ServiceCandidates)) {
            foreach ($service in @(
                $Services | Where-Object {
                    ($_.Name -ieq $candidateName -or
                    $_.DisplayName -ieq $candidateName) -and
                    (
                        ($runningOnly -and $_.State -eq "Running") -or
                        (-not $runningOnly -and $_.State -ne "Running")
                    )
                }
            )) {
                if (-not $ordered.Contains($service)) {
                    $ordered.Add($service)
                }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExecutableNameFallback)) {
        foreach ($service in @(
            $Services |
                Where-Object {
                    $executable = Get-BRAVOServiceExecutablePath -PathName $_.PathName
                    -not [string]::IsNullOrWhiteSpace($executable) -and
                    [System.IO.Path]::GetFileName($executable) -ieq $ExecutableNameFallback
                } |
                Sort-Object @{
                    Expression = { if ($_.State -eq "Running") { 0 } else { 1 } }
                }
        )) {
            if (-not $ordered.Contains($service)) {
                $ordered.Add($service)
            }
        }
    }

    return @($ordered | ForEach-Object {
        $executablePath = Get-BRAVOServiceExecutablePath -PathName $_.PathName
        [pscustomobject]@{
            Name = [string]$_.Name
            DisplayName = [string]$_.DisplayName
            State = [string]$_.State
            StartMode = [string]$_.StartMode
            ExecutablePath = $executablePath
        }
    })
}

function ConvertFrom-BRAVOIniFile {
    # Мінімальний INI-парсер: секції [Name], рядки KEY=VALUE, коментарі ";"
    # (після trim рядка), порожні рядки ігноруються, ключі case-insensitive,
    # останнє неекрановане значення для дубльованого ключа виграє. Точно
    # покриває формат наданого bravo.ini (секції [system]/[archiv]/[model]/
    # /[net]/[Debug], закоментовані й задубльовані ключі).
    #
    # Звичайний Hashtable (не [ordered]) для узгодженості з
    # BRAVO.ExitCodes: тут немає позиційного індексатора, порядок секцій
    # не потрібен для читання значень за іменем.
    [CmdletBinding()]
    param(
        [string]$Path,
        [string[]]$Content
    )

    if ($null -eq $Content) {
        if ([string]::IsNullOrWhiteSpace($Path) -or
            -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $null
        }
        $Content = Get-Content -LiteralPath $Path -Encoding UTF8
    }

    $result = @{}
    $currentSectionName = ""
    $result[$currentSectionName] = @{}

    foreach ($rawLine in @($Content)) {
        $line = [string]$rawLine
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }
        if ($trimmed.StartsWith(";")) {
            continue
        }
        if ($trimmed.StartsWith("[") -and $trimmed.EndsWith("]")) {
            $currentSectionName = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
            if (-not $result.ContainsKey($currentSectionName)) {
                $result[$currentSectionName] = @{}
            }
            continue
        }
        $separatorIndex = $trimmed.IndexOf("=")
        if ($separatorIndex -lt 0) {
            continue
        }
        $key = $trimmed.Substring(0, $separatorIndex).Trim()
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }
        $value = $trimmed.Substring($separatorIndex + 1).Trim()
        $result[$currentSectionName][$key] = $value
    }

    return $result
}

function Get-BRAVOIniValue {
    # Case-insensitive пошук значення в результаті ConvertFrom-BRAVOIniFile;
    # $null, якщо секції/ключа немає або значення порожнє.
    [CmdletBinding()]
    param(
        [object]$IniData,
        [string]$Section,
        [string]$Key
    )

    if ($null -eq $IniData -or -not ($IniData -is [System.Collections.IDictionary])) {
        return $null
    }
    $sectionData = $null
    foreach ($sectionName in $IniData.Keys) {
        if ($sectionName -ieq $Section) {
            $sectionData = $IniData[$sectionName]
            break
        }
    }
    if ($null -eq $sectionData -or -not ($sectionData -is [System.Collections.IDictionary])) {
        return $null
    }
    foreach ($keyName in $sectionData.Keys) {
        if ($keyName -ieq $Key) {
            $value = [string]$sectionData[$keyName]
            if ([string]::IsNullOrWhiteSpace($value)) {
                return $null
            }
            return $value
        }
    }
    return $null
}

function ConvertTo-BRAVOIniPathValue {
    # Нормалізація значення-шляху, прочитаного з INI: trim, зняття зовнішніх
    # лапок, розкриття змінних середовища. Повертає $null, якщо після
    # нормалізації нічого не лишилось — викликач відрізняє "ключа немає" від
    # "ключ є, але порожній" за вхідним значенням, а не за результатом.
    #
    # Окремо від ConvertFrom-BRAVOIniFile навмисно: парсер повертає значення
    # як є (це його контракт для всіх ключів), а лапки й %ENV% доречно
    # розкривати лише там, де значення справді є шляхом.
    [CmdletBinding()]
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $normalized = $Value.Trim()
    foreach ($quoteCharacter in @('"', "'")) {
        if ($normalized.Length -ge 2 -and
            $normalized.StartsWith($quoteCharacter) -and
            $normalized.EndsWith($quoteCharacter)) {
            $normalized = $normalized.Substring(1, $normalized.Length - 2).Trim()
            break
        }
    }
    $normalized = [Environment]::ExpandEnvironmentVariables($normalized)
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }
    return $normalized
}

function Test-BRAVOAbsolutePath {
    # Абсолютний = "X:\..." або UNC "\\server\share". [IO.Path]::IsPathRooted
    # самого по собі недостатньо: воно вважає rooted і "\log\bravo.out", і
    # "C:bravo.out" — обидва залежать від поточного каталогу процесу, тобто
    # для шляху з конфігурації служби це не адреса, а лотерея.
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    return ($Path -match '^([A-Za-z]:[\\/]|\\\\[^\\/]+[\\/])')
}

function Get-BRAVOApacheDocumentRoot {
    # Мінімальний парсер httpd.conf: шукає перше неекрановане "DocumentRoot"
    # (Apache-директиви регістронезалежні). Значення може бути в лапках чи
    # без них, зі слешами в будь-який бік — Apache на Windows традиційно
    # пише шлях через "/" (підтверджено наданим httpd.conf: DocumentRoot
    # "c:/br-a-vo.web/www"). Не заходить усередину <VirtualHost>-блоків:
    # для інсталяції, поставленої разом з BRAVO, основний DocumentRoot
    # завжди в головній секції конфігу.
    [CmdletBinding()]
    param(
        [string]$Path,
        [string[]]$Content
    )

    if ($null -eq $Content) {
        if ([string]::IsNullOrWhiteSpace($Path) -or
            -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $null
        }
        $Content = Get-Content -LiteralPath $Path -Encoding UTF8
    }

    foreach ($rawLine in @($Content)) {
        $line = ([string]$rawLine).Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }
        $quotedMatch = [regex]::Match($line, '(?i)^DocumentRoot\s+"([^"]*)"\s*$')
        if ($quotedMatch.Success) {
            $rawValue = $quotedMatch.Groups[1].Value.Trim()
        } else {
            $unquotedMatch = [regex]::Match($line, '(?i)^DocumentRoot\s+(\S+)\s*$')
            $rawValue = if ($unquotedMatch.Success) {
                $unquotedMatch.Groups[1].Value.Trim()
            } else {
                $null
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($rawValue)) {
            return $rawValue.Replace('/', '\')
        }
    }
    return $null
}

function Get-BRAVOSystemDirectoryPath {
    # BRAVO — 32-бітний процес. На x64 Windows звернення служби до
    # System32 прозоро перенаправляється WOW64 у SysWOW64; на x86 правильним
    # системним каталогом лишається System32. Системні артефакти BRAVO
    # (bravo.ini і range_id_log.json) мають один authoritative каталог.
    # Injectable параметри тримають поведінку детермінованою у self-test.
    [CmdletBinding()]
    param(
        [string]$SystemRoot,
        [Nullable[bool]]$Is64BitOperatingSystem
    )

    $resolvedSystemRoot = if (-not [string]::IsNullOrWhiteSpace($SystemRoot)) {
        $SystemRoot
    } else {
        $env:SystemRoot
    }
    if ([string]::IsNullOrWhiteSpace($resolvedSystemRoot)) {
        return $null
    }
    $resolvedIs64Bit = if ($null -ne $Is64BitOperatingSystem) {
        [bool]$Is64BitOperatingSystem
    } else {
        [Environment]::Is64BitOperatingSystem
    }
    $systemSubDirectory = if ($resolvedIs64Bit) { 'SysWOW64' } else { 'System32' }
    return Join-Path $resolvedSystemRoot $systemSubDirectory
}

function Get-BRAVOSystemBravoIniPath {
    [CmdletBinding()]
    param(
        [string]$SystemRoot,
        [Nullable[bool]]$Is64BitOperatingSystem
    )

    $systemDirectory = Get-BRAVOSystemDirectoryPath `
        -SystemRoot $SystemRoot `
        -Is64BitOperatingSystem $Is64BitOperatingSystem
    if ([string]::IsNullOrWhiteSpace($systemDirectory)) {
        return $null
    }
    return Join-Path $systemDirectory 'bravo.ini'
}

function Get-BRAVOSystemRangeIdLogPath {
    [CmdletBinding()]
    param(
        [string]$SystemRoot,
        [Nullable[bool]]$Is64BitOperatingSystem
    )

    $systemDirectory = Get-BRAVOSystemDirectoryPath `
        -SystemRoot $SystemRoot `
        -Is64BitOperatingSystem $Is64BitOperatingSystem
    if ([string]::IsNullOrWhiteSpace($systemDirectory)) {
        return $null
    }
    return Join-Path $systemDirectory 'range_id_log.json'
}

function Resolve-BRAVOInstallationDiscovery {
    # Пріоритетний ланцюг (аудит/ТЗ CLAUDE_CODE_TZ_ARCHIV_LIMS_MONOLITH.md):
    # 1. CLI-параметри runtime-скриптів — не реалізовано в цій ітерації.
    # 2. Явний override у BRAVO.config (-DiscoverySettings) — виграє й
    #    ніколи не замінюється автоматично знайденим значенням.
    # 3. Canonical bravo.ini, визначений лише архітектурою ОС.
    # 4. Похідні значення (MODEL_SOURCE/BLOG_SOURCE/BRAVOEXCH_SOURCE/
    #    BAZA_APP/WEB_ROOT/BAZA_WWW) з даних bravo.ini й Apache-служби.
    # 5. Керована помилка — тут НЕ кидається; повертається DiscoveryResult
    #    із Reasons, що пояснюють кожне поле, а остаточне рішення "це
    #    помилка чи ні" ухвалює Test-BRAVODiscoveryResult (validation),
    #    щоб точки виклику самі вирішували критичність.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LimsRoot,
        [hashtable]$DiscoverySettings,
        [string]$BravoServiceName = "BRAVO",
        # Джерело істини для ідентифікації служби BRAVO — Service name
        # ТА Display name одночасно, а не будь-яке з них окремо: сторонній
        # сервіс із випадково схожим ім'ям не повинен пройти як BRAVO.
        [string]$BravoDisplayName = "BRAVO Service",
        [string[]]$WebServiceCandidates = @(),
        [string]$ExchangeApiServiceName,
        [object[]]$Services,
        [string]$SystemRoot,
        [Nullable[bool]]$Is64BitOperatingSystem
    )

    $reasons = @{}
    $overrides = @{}

    $normalizedDiscoverySettings = if ($null -ne $DiscoverySettings) {
        $DiscoverySettings
    } else {
        @{}
    }
    $sourceOverrides = if ($normalizedDiscoverySettings.Contains("Sources") -and
        $normalizedDiscoverySettings.Sources -is [System.Collections.IDictionary]) {
        $normalizedDiscoverySettings.Sources
    } else {
        @{}
    }

    # --- BRAVO_ROOT і bravo.ini ---
    $bravoIniPathOverride = if ($normalizedDiscoverySettings.Contains("BravoIniPath")) {
        [string]$normalizedDiscoverySettings.BravoIniPath
    } else {
        $null
    }
    $bravoRootOverride = if ($normalizedDiscoverySettings.Contains("BravoRoot")) {
        [string]$normalizedDiscoverySettings.BravoRoot
    } else {
        $null
    }

    # Пошук веде за обома іменами (ширша сітка — Name АБО DisplayName
    # дорівнює будь-якому кандидату), але службою BRAVO визнається лише
    # та, що пройшла СТРОГУ перевірку нижче: Name -eq BravoServiceName
    # І DisplayName -eq BravoDisplayName одночасно. Джерело істини.
    $bravoServiceSearchCandidates = @(
        $BravoServiceName, $BravoDisplayName
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    $bravoServicesFound = Find-BRAVOServiceByCandidates `
        -ServiceCandidates $bravoServiceSearchCandidates `
        -Services $Services
    $bravoServices = @($bravoServicesFound | Where-Object {
        $_.Name -ieq $BravoServiceName -and $_.DisplayName -ieq $BravoDisplayName
    })
    $bravoServiceMatch = $bravoServices | Select-Object -First 1
    # AUD-007 (аудит P1.1): кілька служб BRAVO з РІЗНИМИ виконуваними
    # файлами — ознака stale/дублюючої інсталяції. Обираємо перший
    # (running-first), як і раніше, але позначаємо неоднозначність, щоб
    # Test-BRAVODiscoveryResult міг її заблокувати для enabled-компонентів.
    $distinctBravoExecutables = @(
        $bravoServices |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) } |
            Select-Object -ExpandProperty ExecutablePath -Unique
    )
    $bravoRootAmbiguous = $distinctBravoExecutables.Count -gt 1
    $bravoRoot = $null
    $bravoRootReason = $null
    if (-not [string]::IsNullOrWhiteSpace($bravoRootOverride)) {
        $bravoRoot = $bravoRootOverride
        $overrides["BravoRoot"] = $true
        $bravoRootReason = "явний override discoverySettings.BravoRoot"
    } elseif ($null -ne $bravoServiceMatch -and
        -not [string]::IsNullOrWhiteSpace($bravoServiceMatch.ExecutablePath)) {
        $bravoRoot = Split-Path -Path $bravoServiceMatch.ExecutablePath -Parent
        $bravoRootReason = "служба '$($bravoServiceMatch.Name)' -> $($bravoServiceMatch.ExecutablePath)"
        if ($bravoRootAmbiguous) {
            $bravoRootReason += " [УВАГА: знайдено кілька служб BRAVO з різними виконуваними файлами, обрано першу]"
        }
        if ($bravoServiceMatch.StartMode -ieq 'Disabled') {
            # Лише діагностика для оператора (той самий патерн, що
            # Resolve-BRAVOEffectiveLimsRoot) — Disabled НЕ блокує
            # визначення BRAVO_ROOT/backup, але оператор має бачити стан.
            $bravoRootReason += " [УВАГА: служба має тип запуску Disabled]"
        }
    } else {
        $bravoRoot = $null
        $bravoRootReason = "каталог BRAVO не визначено: немає override або служби з підтвердженими Name/DisplayName"
    }
    $reasons["BravoRoot"] = $bravoRootReason

    # Джерело істини — рівно ОДИН шлях, визначений архітектурою ОС
    # (Get-BRAVOSystemBravoIniPath): SysWOW64 на x64, System32 на x86.
    # Каталог встановлення bravo.exe тут навмисно більше не перевіряється:
    # альтернативний шлях означає, що на машині можуть співіснувати два
    # bravo.ini, і Maintenance читатиме не той, який насправді використовує
    # служба, — мовчки й правдоподібно. Краще керована помилка з назвою
    # перевіреного шляху, ніж ротація за чужою конфігурацією.
    $systemBravoIniPath = Get-BRAVOSystemBravoIniPath -SystemRoot $SystemRoot -Is64BitOperatingSystem $Is64BitOperatingSystem
    $bravoIniPath = $null
    $bravoIniReason = $null
    if (-not [string]::IsNullOrWhiteSpace($bravoIniPathOverride)) {
        $bravoIniPath = $bravoIniPathOverride
        $overrides["BravoIniPath"] = $true
        $bravoIniReason = "явний override discoverySettings.BravoIniPath"
    } elseif ([string]::IsNullOrWhiteSpace($systemBravoIniPath)) {
        $bravoIniReason = "не вдалося визначити системний каталог Windows (%SystemRoot%), тому очікуваний шлях bravo.ini невідомий"
    } elseif (Test-Path -LiteralPath $systemBravoIniPath -PathType Leaf) {
        $bravoIniPath = $systemBravoIniPath
        $bravoIniReason = "системний каталог Windows за архітектурою ОС: $systemBravoIniPath"
    } else {
        $bravoIniReason = "bravo.ini відсутній за єдиним очікуваним для цієї архітектури ОС шляхом: $systemBravoIniPath"
    }
    $reasons["BravoIniPath"] = $bravoIniReason

    $iniData = if (-not [string]::IsNullOrWhiteSpace($bravoIniPath)) {
        ConvertFrom-BRAVOIniFile -Path $bravoIniPath
    } else {
        $null
    }

    # --- MODEL/BLOG/BRAVOEXCH з bravo.ini, з override ---
    function Resolve-BRAVOSourceField {
        param(
            [string]$FieldName,
            [string]$IniSection,
            [string]$IniKey,
            [scriptblock]$DeriveFromIniValue
        )

        if ($sourceOverrides.Contains($FieldName) -and
            -not [string]::IsNullOrWhiteSpace([string]$sourceOverrides[$FieldName])) {
            $overrides[$FieldName] = $true
            return [pscustomobject]@{
                Value = [string]$sourceOverrides[$FieldName]
                Reason = "явний override discoverySettings.Sources.$FieldName"
            }
        }
        $iniValue = Get-BRAVOIniValue -IniData $iniData -Section $IniSection -Key $IniKey
        if (-not [string]::IsNullOrWhiteSpace($iniValue)) {
            $derived = if ($null -ne $DeriveFromIniValue) {
                & $DeriveFromIniValue $iniValue
            } else {
                $iniValue
            }
            return [pscustomobject]@{
                Value = $derived
                Reason = "bravo.ini [$IniSection] $IniKey=$iniValue"
            }
        }
        $missingReason = if ($null -eq $iniData) {
            "canonical bravo.ini недоступний: $bravoIniReason"
        } else {
            "у canonical bravo.ini '$bravoIniPath' немає непорожнього ключа [$IniSection] $IniKey"
        }
        return [pscustomobject]@{ Value = $null; Reason = $missingReason }
    }

    $modelResolved = Resolve-BRAVOSourceField `
        -FieldName "MODEL" -IniSection "model" -IniKey "MODEL" `
        -DeriveFromIniValue { param($v) (Split-Path -Path $v -Parent) }
    $blogResolved = Resolve-BRAVOSourceField `
        -FieldName "BLOG" -IniSection "model" -IniKey "BLOG" `
        -DeriveFromIniValue { param($v) ($v.TrimEnd("\", "/")) }
    $bravoexchResolved = Resolve-BRAVOSourceField `
        -FieldName "BRAVOEXCH" -IniSection "model" -IniKey "BEXCH" `
        -DeriveFromIniValue { param($v) ($v.TrimEnd("\", "/")) }

    $modelProjectFile = Get-BRAVOIniValue -IniData $iniData -Section "model" -Key "MODEL"

    # --- TRACE_FILE: [Debug] FILE ---
    # Єдине джерело істини для журналу trace BRAVO. Ані BRAVO.config, ані
    # пошук "*.out" у LIMSRoot: ім'я файлу, розширення й каталог задає сам
    # BRAVO, і всі три можуть бути будь-якими. Тому тут свідомо НЕМАЄ ні
    # override з discoverySettings, ні legacy fallback — краще керована
    # помилка з поясненням, ніж мовчазна ротація не того файлу.
    #
    # Відносне значення (FILE=TraceSRV.out) резолвиться відносно каталогу
    # ІНСТАЛЯЦІЇ BRAVO — не поточного каталогу процесу, не ArchiveRoot і не
    # System32/SysWOW64, де лежить сам bravo.ini: файл створює bravo.exe,
    # тому відносний шлях у його конфігурації означає "поруч зі мною".
    $traceFileRawValue = Get-BRAVOIniValue -IniData $iniData -Section "Debug" -Key "FILE"
    $traceFileNormalized = ConvertTo-BRAVOIniPathValue -Value $traceFileRawValue
    $traceFile = $null
    $traceFileReason = $null
    $traceFileOutsideInstallation = $false
    if ($null -eq $iniData) {
        $traceFileReason = "bravo.ini недоступний: $bravoIniReason"
    } elseif ([string]::IsNullOrWhiteSpace($traceFileRawValue)) {
        $traceFileReason = "у '$bravoIniPath' немає непорожнього ключа FILE у секції [Debug]"
    } elseif ([string]::IsNullOrWhiteSpace($traceFileNormalized)) {
        $traceFileReason = "ключ FILE секції [Debug] у '$bravoIniPath' порожній після нормалізації (значення: '$traceFileRawValue')"
    } else {
        $traceFileResolved = $traceFileNormalized
        $traceFileResolvedFrom = "абсолютний шлях"
        if (-not (Test-BRAVOAbsolutePath -Path $traceFileNormalized)) {
            if ([string]::IsNullOrWhiteSpace($bravoRoot)) {
                $traceFileResolved = $null
                $traceFileReason = "ключ FILE секції [Debug] у '$bravoIniPath' задано відносним шляхом ('$traceFileRawValue'), але каталог інсталяції BRAVO невизначений: $bravoRootReason"
            } else {
                $traceFileResolved = Join-Path $bravoRoot $traceFileNormalized
                $traceFileResolvedFrom = "відносний шлях від каталогу інсталяції BRAVO ($bravoRoot)"
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($traceFileResolved)) {
            try {
                $traceFileResolved = [System.IO.Path]::GetFullPath($traceFileResolved)
            } catch {
                $traceFileResolved = $null
                $traceFileReason = "ключ FILE секції [Debug] у '$bravoIniPath' не є коректним шляхом: '$traceFileRawValue' ($($_.Exception.Message))"
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($traceFileResolved)) {
            $traceFile = $traceFileResolved
            $traceFileReason = "bravo.ini [Debug] FILE=$traceFileRawValue ($bravoIniPath); $traceFileResolvedFrom"
            # Trace належить каталогу інсталяції BRAVO. Розташування поза ним
            # не блокує ротацію (шлях може вести на окремий диск свідомо),
            # але це рівно та розбіжність між конфігурацією й очікуванням,
            # яку оператор має побачити в журналі, а не з'ясовувати потім.
            if (-not [string]::IsNullOrWhiteSpace($bravoRoot)) {
                $normalizedInstallationRoot = ([string]$bravoRoot).TrimEnd('\', '/')
                $traceFileDirectory = ([string](Split-Path -Path $traceFile -Parent)).TrimEnd('\', '/')
                if (-not [string]::Equals($traceFileDirectory, $normalizedInstallationRoot, [StringComparison]::OrdinalIgnoreCase) -and
                    -not $traceFileDirectory.StartsWith($normalizedInstallationRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    $traceFileOutsideInstallation = $true
                    $traceFileReason += "; УВАГА: поза каталогом інсталяції BRAVO ($bravoRoot)"
                }
            }
        }
    }

    # --- BAZA_APP ---
    # BAZA не має власного ключа в bravo.ini. Коли MODEL/BLOG вже взято з
    # bravo.ini (реальна інсталяція), BAZA_APP надійніше вивести як
    # сусідній каталог у тому самому корені LIMS-інсталяції, ніж через
    # BRAVO_ROOT: останній залежить від того, чи знайдено саму
    # Windows-службу BRAVO, а MODEL/BLOG з bravo.ini — ні. Реальний
    # випадок: службу BRAVO не встановлено (лише canonical bravo.ini на
    # диску). У такому разі BRAVO_ROOT лишається невизначеним, але шлях
    # MODEL/BLOG все одно дає контрольоване джерело для BAZA_APP.
    $iniInstallationRoot = if ($modelResolved.Reason -like "bravo.ini *") {
        Split-Path -Path $modelResolved.Value -Parent
    } elseif ($blogResolved.Reason -like "bravo.ini *") {
        Split-Path -Path $blogResolved.Value -Parent
    } else {
        $null
    }
    $bazaAppOverrideValue = if ($sourceOverrides.Contains("BAZA_APP") -and
        -not [string]::IsNullOrWhiteSpace([string]$sourceOverrides["BAZA_APP"])) {
        [string]$sourceOverrides["BAZA_APP"]
    } else {
        $null
    }
    $bazaAppResolved = if (-not [string]::IsNullOrWhiteSpace($bazaAppOverrideValue)) {
        $overrides["BAZA_APP"] = $true
        [pscustomobject]@{
            Value = $bazaAppOverrideValue
            Reason = "явний override discoverySettings.Sources.BAZA_APP"
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($iniInstallationRoot)) {
        [pscustomobject]@{
            Value = Join-Path $iniInstallationRoot "BAZA"
            Reason = "поруч із MODEL/BLOG з bravo.ini: $iniInstallationRoot"
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($bravoRoot)) {
        [pscustomobject]@{
            Value = Join-Path $bravoRoot "BAZA"
            Reason = "service discovery: каталог інсталяції BRAVO ($bravoRoot)"
        }
    } else {
        [pscustomobject]@{
            Value = $null
            Reason = "BAZA_APP не визначено: немає override, canonical bravo.ini або підтвердженої служби BRAVO"
        }
    }

    # --- BACKUP_ROOT: каталог збереження бекапів ---
    # Discovery не визначає production destination. Єдине джерело істини —
    # explicit pathSettings.BackupRoot; старий override збережено лише для
    # діагностики конфігів перехідного періоду.
    $backupRootResolved = [pscustomobject]@{
        Value = $(if ($sourceOverrides.Contains('BACKUP_ROOT') -and
            -not [string]::IsNullOrWhiteSpace([string]$sourceOverrides['BACKUP_ROOT'])) {
            $overrides['BACKUP_ROOT'] = $true
            [string]$sourceOverrides['BACKUP_ROOT']
        } else { $null })
        Reason = $(if ($sourceOverrides.Contains('BACKUP_ROOT') -and
            -not [string]::IsNullOrWhiteSpace([string]$sourceOverrides['BACKUP_ROOT'])) {
            'явний override discoverySettings.Sources.BACKUP_ROOT'
        } else {
            'не використовується: BackupRoot задається тільки pathSettings.BackupRoot'
        })
    }

    # --- WEB_ROOT / BAZA_WWW через Apache-службу ---
    $webRootOverride = if ($normalizedDiscoverySettings.Contains("WebRoot")) {
        [string]$normalizedDiscoverySettings.WebRoot
    } else {
        $null
    }
    $webServices = if (@($WebServiceCandidates).Count -gt 0) {
        Find-BRAVOServiceByCandidates `
            -ServiceCandidates $WebServiceCandidates `
            -ExecutableNameFallback "httpd.exe" `
            -Services $Services
    } else {
        @()
    }
    $webServiceMatch = $webServices | Select-Object -First 1
    $distinctWebExecutables = @(
        $webServices |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) } |
            Select-Object -ExpandProperty ExecutablePath -Unique
    )
    $webRootAmbiguous = $distinctWebExecutables.Count -gt 1
    $webRoot = $null
    $webRootReason = $null
    # ServerRoot Apache (<ServerRoot>\conf\httpd.conf, <ServerRoot>\bin\httpd.exe)
    # — окремо від WEB_ROOT: WEB_ROOT на рівень вище (батько ServerRoot),
    # ServerRoot потрібен лише для пошуку самого httpd.conf.
    $apacheServerRoot = $null
    if (-not [string]::IsNullOrWhiteSpace($webRootOverride)) {
        $webRoot = $webRootOverride
        $overrides["WebRoot"] = $true
        $webRootReason = "явний override discoverySettings.WebRoot"
    } elseif ($null -ne $webServiceMatch -and
        -not [string]::IsNullOrWhiteSpace($webServiceMatch.ExecutablePath) -and
        [System.IO.Path]::GetFileName($webServiceMatch.ExecutablePath) -ieq "httpd.exe") {
        # <WEB_ROOT>\apache\bin\httpd.exe -> bin -> apache (ServerRoot) -> WEB_ROOT.
        $binDir = Split-Path -Path $webServiceMatch.ExecutablePath -Parent
        $apacheServerRoot = Split-Path -Path $binDir -Parent
        $webRoot = Split-Path -Path $apacheServerRoot -Parent
        $webRootReason = "служба '$($webServiceMatch.Name)' -> $($webServiceMatch.ExecutablePath)"
        if ($webRootAmbiguous) {
            $webRootReason += " [УВАГА: знайдено кілька Apache-подібних служб з різними виконуваними файлами, обрано першу]"
        }
        if ($webServiceMatch.StartMode -ieq 'Disabled') {
            # Лише діагностика для оператора — Disabled НЕ блокує
            # визначення WEB_ROOT/BAZA_WWW backup, той самий патерн, що й
            # BravoRoot вище.
            $webRootReason += " [УВАГА: служба має тип запуску Disabled]"
        }
    } else {
        $webRootReason = "Apache-службу не знайдено; BAZA_WWW недоступний"
    }
    $reasons["WebRoot"] = $webRootReason

    # --- DocumentRoot з httpd.conf встановленої Apache-служби ---
    # Джерело істини для BAZA_WWW: не здогадка "<WEB_ROOT>\www", а реальний
    # DocumentRoot з конфігу тієї самої служби (bravo.ini для MODEL/BLOG —
    # той самий принцип, тут для BAZA_WWW). httpd.conf лежить поруч з
    # httpd.exe за стандартним для Apache Windows розкладом:
    # <ServerRoot>\conf\httpd.conf, де <ServerRoot> = батько bin.
    $httpdConfPath = $null
    $apacheDocumentRoot = $null
    $documentRootReason = $null
    if (-not [string]::IsNullOrWhiteSpace($apacheServerRoot)) {
        $httpdConfPath = Join-Path $apacheServerRoot "conf\httpd.conf"
        if (Test-Path -LiteralPath $httpdConfPath -PathType Leaf) {
            $apacheDocumentRoot = Get-BRAVOApacheDocumentRoot -Path $httpdConfPath
            if (-not [string]::IsNullOrWhiteSpace($apacheDocumentRoot)) {
                $documentRootReason = "httpd.conf: DocumentRoot=$apacheDocumentRoot ($httpdConfPath)"
            } else {
                $documentRootReason = "DocumentRoot не знайдено в httpd.conf: $httpdConfPath"
            }
        } else {
            $documentRootReason = "httpd.conf не знайдено за очікуваним шляхом: $httpdConfPath"
        }
    } elseif ([string]::IsNullOrWhiteSpace($webRootOverride)) {
        # Apache-службу взагалі не знайдено (не Disabled — просто немає
        # жодного кандидата з підтвердженим виконуваним файлом): без цієї
        # гілки Reasons.BAZA_WWW лишався "BAZA_WWW не визначено: " з
        # порожнім хвостом — оператор бачив причину лише в Reasons.WebRoot,
        # окремому полі. Дублюємо той самий текст сюди, а не окрему
        # формулу: причина одна ("службу не знайдено"), не дві різні.
        # (elseif, а не else: коли WEB_ROOT задано явним override,
        # $apacheServerRoot теж лишається null, але причина інша — немає
        # ServerRoot/conf\httpd.conf для читання, а не "службу не знайдено"
        # — той випадок нижче отримує власне явне формулювання.)
        $documentRootReason = $webRootReason
    } else {
        $documentRootReason = "WEB_ROOT заданий явним override, тому httpd.conf службою не шукається; для BAZA_WWW потрібен окремий discoverySettings.Sources.BAZA_WWW"
    }

    $bazaWwwOverride = if ($sourceOverrides.Contains('BAZA_WWW')) {
        [string]$sourceOverrides['BAZA_WWW']
    } else { $null }
    $bazaWwwResolved = if (-not [string]::IsNullOrWhiteSpace($bazaWwwOverride)) {
        $overrides['BAZA_WWW'] = $true
        [pscustomobject]@{ Value = $bazaWwwOverride; Reason = 'явний override discoverySettings.Sources.BAZA_WWW' }
    } elseif (-not [string]::IsNullOrWhiteSpace($apacheDocumentRoot)) {
        [pscustomobject]@{ Value = (Join-Path $apacheDocumentRoot 'BAZA'); Reason = $documentRootReason }
    } else {
        [pscustomobject]@{ Value = $null; Reason = "BAZA_WWW не визначено: $documentRootReason" }
    }
    # --- ExchangeAPI: лише ідентифікація служби, шлях завжди з bravo.ini ---
    $exchangeApiServices = if (-not [string]::IsNullOrWhiteSpace($ExchangeApiServiceName)) {
        Find-BRAVOServiceByCandidates `
            -ServiceCandidates @($ExchangeApiServiceName) `
            -Services $Services
    } else {
        @()
    }

    $allServices = @($bravoServices) + @($webServices) + @($exchangeApiServices)

    return [pscustomobject]@{
        BRAVO_ROOT = $bravoRoot
        WEB_ROOT = $webRoot
        # Явно, а не лише через Services: викликач (BRAVO.config) будував
        # би той самий фільтр за BravoWebCandidates вдруге, аби просто
        # залогувати, яка саме служба дала BAZA_WWW.
        WebServiceName = if ($null -ne $webServiceMatch) { [string]$webServiceMatch.Name } else { $null }
        WebServiceDisplayName = if ($null -ne $webServiceMatch) { [string]$webServiceMatch.DisplayName } else { $null }
        WebServiceExecutable = if ($null -ne $webServiceMatch) { [string]$webServiceMatch.ExecutablePath } else { $null }
        BravoIniPath = $bravoIniPath
        HttpdConfPath = $httpdConfPath
        MODEL_PROJECT_FILE = $modelProjectFile
        TRACE_FILE = $traceFile
        TRACE_FILE_OUTSIDE_INSTALLATION = $traceFileOutsideInstallation
        MODEL_SOURCE = $modelResolved.Value
        BLOG_SOURCE = $blogResolved.Value
        BRAVOEXCH_SOURCE = $bravoexchResolved.Value
        BAZA_APP = $bazaAppResolved.Value
        BAZA_WWW = $bazaWwwResolved.Value
        BACKUP_ROOT = $backupRootResolved.Value
        Services = $allServices
        Overrides = $overrides
        Ambiguous = @{
            BravoRoot = $bravoRootAmbiguous
            WebRoot = $webRootAmbiguous
        }
        Reasons = @{
            BravoRoot = $reasons["BravoRoot"]
            WebRoot = $reasons["WebRoot"]
            BravoIniPath = $reasons["BravoIniPath"]
            TRACE_FILE = $traceFileReason
            MODEL = $modelResolved.Reason
            BLOG = $blogResolved.Reason
            BRAVOEXCH = $bravoexchResolved.Reason
            BAZA_APP = $bazaAppResolved.Reason
            BAZA_WWW = $bazaWwwResolved.Reason
            BACKUP_ROOT = $backupRootResolved.Reason
        }
    }
}

function Test-BRAVODiscoveryResult {
    # Validation за ТЗ: існування enabled source, існування/створюваність
    # destination, destination != source, destination не вкладений у
    # source, наявність bravo.ini якщо він потрібен (тобто жоден
    # Sources.*-override не заданий), непорожність значень з bravo.ini.
    # Повертає масив рядків-помилок (порожній масив == валідно); виклик,
    # що це критично (код 30), лишається за BRAVO.config.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$DiscoveryResult,
        [hashtable]$EnabledComponents = @{},
        [hashtable]$DestinationPaths = @{}
    )

    $errors = New-Object System.Collections.Generic.List[string]

    # AUD-007 (аудит P1.1): неоднозначний BRAVO_ROOT/WEB_ROOT (кілька служб
    # із різними виконуваними файлами) не має мовчки давати "успішний"
    # backup не того джерела — блокуємо лише для реально увімкнених
    # компонентів, які від цього кореня залежать.
    if ($DiscoveryResult.PSObject.Properties['Ambiguous'] -and
        $DiscoveryResult.Ambiguous -is [System.Collections.IDictionary]) {
        $bravoRootDependents = @('MODEL', 'BLOG', 'BRAVOEXCH', 'BAZA_APP') |
            Where-Object { $EnabledComponents.Contains($_) -and [bool]$EnabledComponents[$_] }
        if ([bool]$DiscoveryResult.Ambiguous['BravoRoot'] -and @($bravoRootDependents).Count -gt 0) {
            $errors.Add("Знайдено кілька служб BRAVO з різними виконуваними файлами — BRAVO_ROOT неоднозначний (впливає на: $($bravoRootDependents -join ', ')). Задайте discoverySettings.BravoRoot вручну або приберіть зайву службу.")
        }
        if ([bool]$DiscoveryResult.Ambiguous['WebRoot'] -and
            $EnabledComponents.Contains('BAZA_WWW') -and [bool]$EnabledComponents['BAZA_WWW']) {
            $errors.Add("Знайдено кілька Apache-подібних служб з різними виконуваними файлами — WEB_ROOT неоднозначний (впливає на: BAZA_WWW). Задайте discoverySettings.WebRoot вручну або приберіть зайву службу.")
        }
    }

    $sourceFieldsByComponent = @{
        MODEL = "MODEL_SOURCE"
        BLOG = "BLOG_SOURCE"
        BRAVOEXCH = "BRAVOEXCH_SOURCE"
        BAZA_APP = "BAZA_APP"
        BAZA_WWW = "BAZA_WWW"
    }

    foreach ($componentName in $sourceFieldsByComponent.Keys) {
        if (-not $EnabledComponents.Contains($componentName) -or
            -not [bool]$EnabledComponents[$componentName]) {
            continue
        }
        $sourceFieldName = $sourceFieldsByComponent[$componentName]
        $sourceValue = $DiscoveryResult.$sourceFieldName
        if ([string]::IsNullOrWhiteSpace([string]$sourceValue)) {
            $errors.Add("Джерело '$componentName' увімкнено, але шлях не визначено (немає explicit override або canonical discovery value).")
            continue
        }
        $sourceForTest = ([string]$sourceValue).TrimEnd("*", "\")
        if (-not (Test-Path -LiteralPath $sourceForTest)) {
            $errors.Add("Джерело '$componentName' увімкнено, але шлях не існує: $sourceValue")
        }
    }

    foreach ($componentName in $DestinationPaths.Keys) {
        $destinationValue = [string]$DestinationPaths[$componentName]
        if ([string]::IsNullOrWhiteSpace($destinationValue)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $destinationValue -PathType Container)) {
            try {
                [void](New-Item -ItemType Directory -Path $destinationValue -Force -ErrorAction Stop)
            } catch {
                $errors.Add("Каталог призначення '$componentName' не існує і не вдалося створити: $destinationValue ($($_.Exception.Message))")
                continue
            }
        }
        if ($sourceFieldsByComponent.Contains($componentName)) {
            $sourceFieldName = $sourceFieldsByComponent[$componentName]
            $sourceValue = ([string]$DiscoveryResult.$sourceFieldName).TrimEnd("*", "\")
            if (-not [string]::IsNullOrWhiteSpace($sourceValue)) {
                $normalizedSource = $sourceValue.TrimEnd("\").ToLowerInvariant()
                $normalizedDestination = $destinationValue.TrimEnd("\").ToLowerInvariant()
                if ($normalizedSource -eq $normalizedDestination) {
                    $errors.Add("Каталог призначення '$componentName' збігається з джерелом: $destinationValue")
                } elseif ($normalizedDestination.StartsWith($normalizedSource + "\")) {
                    $errors.Add("Каталог призначення '$componentName' вкладений у джерело: $destinationValue всередині $sourceValue")
                }
            }
        }
    }

    # Звичайний масив, БЕЗ унарної коми і БЕЗ -NoEnumerate: обидва
    # трюки ламають один із двох стилів виклику (пряме присвоєння vs
    # виклик, обгорнутий у @(...) на боці клієнта). Контракт цієї функції
    # — виклик ЗАВЖДИ обгортається @(...) на боці клієнта (як і
    # BRAVO_SETUP.ps1 та BRAVO_SELF_TEST.ps1 уже роблять); це коректно
    # відновлює масив для 0, 1 і N елементів під Set-StrictMode -Version 2.0
    # на Windows PowerShell 5.1.
    return $errors.ToArray()
}

$script:BRAVODiscoveryBaselineFields = @(
    'BRAVO_ROOT', 'WEB_ROOT', 'MODEL_SOURCE', 'BLOG_SOURCE',
    'BRAVOEXCH_SOURCE', 'BAZA_APP', 'BAZA_WWW', 'BACKUP_ROOT'
)

function Save-BRAVODiscoveryBaseline {
    # AUD-007 (аудит P1.1/P1.2): зберігає останній підтверджений discovery-
    # результат на диск (JSON, без BOM — узгоджено з VERSION.json), щоб
    # Compare-BRAVODiscoveryBaseline міг виявити дрейф джерел між запусками.
    # Явне збереження (не автоматичне при кожному запуску) — за задумом:
    # baseline підтверджує адміністратор через BRAVO_SETUP.ps1
    # -ConfirmDiscoveryBaseline, після ручної перевірки виводу DISCOVERY.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$DiscoveryResult,
        [Parameter(Mandatory = $true)][string]$BaselinePath
    )

    $snapshot = [ordered]@{ SavedAt = (Get-Date).ToString("o") }
    foreach ($fieldName in $script:BRAVODiscoveryBaselineFields) {
        $snapshot[$fieldName] = [string]$DiscoveryResult.$fieldName
    }

    $parentDir = Split-Path -Path $BaselinePath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and
        -not (Test-Path -LiteralPath $parentDir -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parentDir -Force)
    }

    $json = [pscustomobject]$snapshot | ConvertTo-Json
    [IO.File]::WriteAllText($BaselinePath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Compare-BRAVODiscoveryBaseline {
    # Повертає масив рядків-попереджень про дрейф джерел відносно
    # останнього збереженого baseline (порожній масив == дрейфу немає або
    # baseline ще не існує — перший запуск не є дрейфом). -Baseline
    # дозволяє self-test підставити синтетичний baseline без файлу на
    # диску (той самий injectable-патерн, що й -Services).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$DiscoveryResult,
        [string]$BaselinePath,
        [object]$Baseline
    )

    if ($null -eq $Baseline) {
        if ([string]::IsNullOrWhiteSpace($BaselinePath) -or
            -not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)) {
            return @()
        }
        try {
            $rawBaseline = Get-Content -LiteralPath $BaselinePath -Raw -Encoding UTF8
            $Baseline = $rawBaseline | ConvertFrom-Json
        } catch {
            return @("Не вдалося прочитати збережений discovery baseline '$BaselinePath': $($_.Exception.Message)")
        }
    }

    $drift = New-Object System.Collections.Generic.List[string]
    foreach ($fieldName in $script:BRAVODiscoveryBaselineFields) {
        $baselineValue = if ($Baseline.PSObject.Properties[$fieldName]) {
            [string]$Baseline.$fieldName
        } else {
            $null
        }
        if ([string]::IsNullOrWhiteSpace($baselineValue)) {
            continue
        }
        $currentValue = [string]$DiscoveryResult.$fieldName
        if ([string]::IsNullOrWhiteSpace($currentValue)) {
            $drift.Add("Discovery drift: '$fieldName' раніше було '$baselineValue', зараз не визначено.")
        } elseif (-not [string]::Equals($baselineValue, $currentValue, [StringComparison]::OrdinalIgnoreCase)) {
            $drift.Add("Discovery drift: '$fieldName' змінився з '$baselineValue' на '$currentValue' відносно збереженого baseline.")
        }
    }

    return $drift.ToArray()
}

function Resolve-BRAVOEffectiveLimsRoot {
    # Канонічне визначення кореня production-інсталяції BRAVO (LIMSRoot).
    #
    # Порядок строгий (ТЗ RuntimeRoot/LIMSRoot §8-§15):
    #   1. ConfiguredPath заданий явно -> exact path, Source=ExplicitConfig.
    #      Discovery НІКОЛИ не перевизначає явний шлях.
    #   2. ConfiguredPath == "" -> AUTO через встановлену службу BRAVO,
    #      ідентифіковану ОДНОЧАСНО за Name і DisplayName. EffectiveLIMSRoot =
    #      каталог виконуваного файла служби (parent of bravo.exe).
    #   3. Служби немає / без виконуваного файла / кілька служб з різними
    #      виконуваними файлами -> Source=Error (fail-closed). Технічно
    #      валідний backup НЕ ТІЄЇ інсталяції гірший за кероване падіння.
    #
    # Стан служби (Running/Stopped/Paused/Disabled) НЕ впливає на identity:
    # шлях встановлення не залежить від того, чи служба зараз запущена.
    # Тому тут навмисно НЕ використовується Find-BRAVOServiceByCandidates
    # (він відкидає Disabled) — фільтр лише за Name/DisplayName.
    #
    # -Services дозволяє self-test підставити синтетичні Win32_Service-
    # подібні об'єкти замість WMI (той самий injectable-патерн, що й решта
    # discovery-функцій).
    [CmdletBinding()]
    param(
        [string]$ConfiguredPath,
        [string]$BravoServiceName = "BRAVO",
        [string]$BravoDisplayName = "BRAVO Service",
        [object[]]$Services
    )

    $buildResult = {
        param([string]$EffectivePath, [string]$Source, [object]$Service, [string]$Reason)
        [pscustomobject]@{
            ConfiguredPath = $ConfiguredPath
            EffectivePath = $EffectivePath
            Source = $Source
            ServiceName = if ($null -ne $Service) { [string]$Service.Name } else { $null }
            ServiceDisplayName = if ($null -ne $Service) { [string]$Service.DisplayName } else { $null }
            ServiceExecutable = if ($null -ne $Service) { [string]$Service.ExecutablePath } else { $null }
            Reason = $Reason
        }
    }

    $expanded = ([Environment]::ExpandEnvironmentVariables([string]$ConfiguredPath)).Trim()

    # 1/2 explicit override.
    if (-not [string]::IsNullOrWhiteSpace($expanded)) {
        if (-not (Test-BRAVOAbsolutePath -Path $expanded)) {
            return (& $buildResult $null 'Error' $null "pathSettings.LIMSRoot задано неабсолютним шляхом: '$ConfiguredPath'")
        }
        return (& $buildResult (([IO.Path]::GetFullPath($expanded)).TrimEnd('\', '/')) 'ExplicitConfig' $null 'явно задано в pathSettings.LIMSRoot')
    }

    # 3 AUTO через службу BRAVO.
    if ($null -eq $Services) {
        try {
            $Services = @(Get-BRAVOWmiInstance -ClassName Win32_Service)
        } catch {
            return (& $buildResult $null 'Error' $null "не вдалося перелічити служби Windows для AUTO-визначення LIMSRoot: $($_.Exception.Message)")
        }
    }

    $canonical = @(
        $Services | Where-Object {
            $_.Name -ieq $BravoServiceName -and $_.DisplayName -ieq $BravoDisplayName
        } | ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Name
                DisplayName = [string]$_.DisplayName
                State = [string]$_.State
                StartMode = [string]$_.StartMode
                ExecutablePath = Get-BRAVOServiceExecutablePath -PathName $_.PathName
            }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) }
    )

    if ($canonical.Count -eq 0) {
        return (& $buildResult $null 'Error' $null "службу BRAVO (Name='$BravoServiceName', DisplayName='$BravoDisplayName') не знайдено або вона без виконуваного файла; задайте pathSettings.LIMSRoot явно")
    }

    $distinctExecutables = @($canonical | Select-Object -ExpandProperty ExecutablePath -Unique)
    if ($distinctExecutables.Count -gt 1) {
        return (& $buildResult $null 'Error' $null "знайдено кілька служб BRAVO з різними виконуваними файлами ($($distinctExecutables -join ', ')); AUTO-визначення неоднозначне — задайте pathSettings.LIMSRoot явно")
    }

    $match = $canonical | Select-Object -First 1
    $effectivePath = (Split-Path -Path $match.ExecutablePath -Parent).TrimEnd('\', '/')
    $reason = "AUTO зі служби '$($match.Name)' -> $($match.ExecutablePath)"
    if ($match.StartMode -ieq 'Disabled') {
        $reason += " [УВАГА: служба має тип запуску Disabled]"
    }
    return (& $buildResult $effectivePath 'ServiceDiscovery' $match $reason)
}

function Resolve-BRAVOEffectiveSystemLogRoot {
    # SystemLogRoot — каталог системних журналів BRAVO (Trace/exchangAPI/
    # BravoWeb). "" -> <EffectiveLIMSRoot>\ARCHIV\LOGS (Source=AutoFromLIMSRoot);
    # явне значення використовується ТОЧНО, без дописування ARCHIV\LOGS.
    [CmdletBinding()]
    param(
        [string]$ConfiguredPath,
        [string]$EffectiveLimsRoot
    )

    $expanded = ([Environment]::ExpandEnvironmentVariables([string]$ConfiguredPath)).Trim()
    if (-not [string]::IsNullOrWhiteSpace($expanded)) {
        if (-not (Test-BRAVOAbsolutePath -Path $expanded)) {
            return [pscustomobject]@{
                ConfiguredPath = $ConfiguredPath; EffectivePath = $null
                Source = 'Error'; Reason = "pathSettings.SystemLogRoot задано неабсолютним шляхом: '$ConfiguredPath'"
            }
        }
        return [pscustomobject]@{
            ConfiguredPath = $ConfiguredPath
            EffectivePath = ([IO.Path]::GetFullPath($expanded)).TrimEnd('\', '/')
            Source = 'ExplicitConfig'
            Reason = 'явно задано в pathSettings.SystemLogRoot'
        }
    }

    if ([string]::IsNullOrWhiteSpace($EffectiveLimsRoot)) {
        return [pscustomobject]@{
            ConfiguredPath = $ConfiguredPath; EffectivePath = $null
            Source = 'Error'; Reason = 'SystemLogRoot="" вимагає визначеного EffectiveLIMSRoot, але його немає'
        }
    }
    return [pscustomobject]@{
        ConfiguredPath = $ConfiguredPath
        # [IO.Path]::Combine, а не Join-Path: якщо EffectiveLIMSRoot на диску,
        # якого зараз немає, Join-Path кинув би DriveNotFoundException під час
        # завантаження конфігурації. Доступність кореня перевіряє write-probe.
        EffectivePath = [System.IO.Path]::Combine($EffectiveLimsRoot, 'ARCHIV\LOGS')
        Source = 'AutoFromLIMSRoot'
        Reason = "AUTO від EffectiveLIMSRoot: $EffectiveLimsRoot\ARCHIV\LOGS"
    }
}

function Resolve-BRAVOEffectiveBackupRoot {
    # BackupRoot — корінь локальних резервних копій (MODEL/BLOG/BRAVOEXCH/
    # BAZA_APP/BAZA_WWW). "" -> <EffectiveLIMSRoot>\ARCHIV (co-located з
    # системними журналами; історичне розкладання). Явне значення — точно.
    [CmdletBinding()]
    param(
        [string]$ConfiguredPath,
        [string]$EffectiveLimsRoot
    )

    $expanded = ([Environment]::ExpandEnvironmentVariables([string]$ConfiguredPath)).Trim()
    if (-not [string]::IsNullOrWhiteSpace($expanded)) {
        if (-not (Test-BRAVOAbsolutePath -Path $expanded)) {
            return [pscustomobject]@{
                ConfiguredPath = $ConfiguredPath; EffectivePath = $null
                Source = 'Error'; Reason = "pathSettings.BackupRoot задано неабсолютним шляхом: '$ConfiguredPath'"
            }
        }
        return [pscustomobject]@{
            ConfiguredPath = $ConfiguredPath
            EffectivePath = ([IO.Path]::GetFullPath($expanded)).TrimEnd('\', '/')
            Source = 'ExplicitConfig'
            Reason = 'явно задано в pathSettings.BackupRoot'
        }
    }

    if ([string]::IsNullOrWhiteSpace($EffectiveLimsRoot)) {
        return [pscustomobject]@{
            ConfiguredPath = $ConfiguredPath; EffectivePath = $null
            Source = 'Error'; Reason = 'BackupRoot="" вимагає визначеного EffectiveLIMSRoot, але його немає'
        }
    }
    return [pscustomobject]@{
        ConfiguredPath = $ConfiguredPath
        # [IO.Path]::Combine — диск LIMSRoot може бути ще не змонтований на
        # момент завантаження; доступність перевіряє write-probe.
        EffectivePath = [System.IO.Path]::Combine($EffectiveLimsRoot, 'ARCHIV')
        Source = 'AutoFromLIMSRoot'
        Reason = "AUTO від EffectiveLIMSRoot: $EffectiveLimsRoot\ARCHIV"
    }
}

function ConvertTo-BRAVOSyncFlag {
    # Захисне приведення прапорця синхронізації до [bool]. Значення в
    # componentSettings — справжні $true/$false, але Installer історично
    # застосовував [Convert]::ToBoolean; зберігаємо ту саму толерантність в
    # одному місці, щоб усі споживачі трактували прапорці однаково.
    param($Value)
    if ($Value -is [bool]) { return $Value }
    if ($null -eq $Value) { return $false }
    try { return [System.Convert]::ToBoolean($Value) } catch { return $false }
}

function Get-BRAVOEffectiveSynchronizationConfiguration {
    # ЄДИНЕ канонічне джерело правди про синхронізацію BAZA. Централізує:
    #   - чи потрібне заплановане BAZASync-завдання (SFTP-операція за
    #     визначенням: BRAVO_ARCHIV.ps1 -SyncBAZA синхронізує лише SFTP);
    #   - які BAZA-джерела обов'язкові (LOCAL АБО SFTP увімкнено -> джерело
    #     обов'язкове й має існувати);
    #   - які SFTP-каталоги призначення обов'язкові для preflight.
    # Однакові вхідні дані -> однаковий результат у Config Loader, Task
    # Installer, Task Diagnose, Dry Run і production runtime. Жоден скрипт не
    # повторює вираз "BAZA_APP_SFTP -or BAZA_WWW_SFTP" самостійно (ТЗ:
    # "Не дублювати ... у 4-5 різних скриптах").
    [CmdletBinding()]
    param(
        [hashtable]$Synchronization,
        [string]$BazaAppSource,
        [string]$BazaWWWSource,
        $BazaWWWDetection,
        [hashtable]$SftpDirectories
    )

    if ($null -eq $Synchronization) { $Synchronization = @{} }

    $appLocal = ConvertTo-BRAVOSyncFlag $Synchronization['BAZA_APP_LOCAL']
    $appSftp = ConvertTo-BRAVOSyncFlag $Synchronization['BAZA_APP_SFTP']
    $wwwLocal = ConvertTo-BRAVOSyncFlag $Synchronization['BAZA_WWW_LOCAL']
    $wwwSftp = ConvertTo-BRAVOSyncFlag $Synchronization['BAZA_WWW_SFTP']

    $wwwReason = $null
    if ($null -ne $BazaWWWDetection -and
        $null -ne $BazaWWWDetection.PSObject.Properties['Reason']) {
        $wwwReason = [string]$BazaWWWDetection.Reason
    }

    $appComponent = [pscustomobject]@{
        Name = 'BAZA_APP'
        DisplayName = 'BAZA APP'
        LocalEnabled = $appLocal
        SftpEnabled = $appSftp
        AnyEnabled = ($appLocal -or $appSftp)
        Source = [string]$BazaAppSource
        SourceReason = $null
        SftpRemoteDirectory = if ($null -ne $SftpDirectories) { [string]$SftpDirectories['BAZA'] } else { $null }
    }
    $wwwComponent = [pscustomobject]@{
        Name = 'BAZA_WWW'
        DisplayName = 'BAZA WWW'
        LocalEnabled = $wwwLocal
        SftpEnabled = $wwwSftp
        AnyEnabled = ($wwwLocal -or $wwwSftp)
        Source = [string]$BazaWWWSource
        SourceReason = $wwwReason
        SftpRemoteDirectory = if ($null -ne $SftpDirectories) { [string]$SftpDirectories['BAZAWWW'] } else { $null }
    }

    $components = @($appComponent, $wwwComponent)
    return [pscustomobject]@{
        Components = $components
        ScheduledSftpSyncRequired = ($appSftp -or $wwwSftp)
        RequiredSftpDestinations = @(
            $components |
                Where-Object { $_.SftpEnabled -and -not [string]::IsNullOrWhiteSpace($_.SftpRemoteDirectory) } |
                ForEach-Object { $_.SftpRemoteDirectory }
        )
    }
}

Export-ModuleMember -Function @(
    'Get-BRAVOServiceExecutablePath',
    'Find-BRAVOServiceByCandidates',
    'ConvertFrom-BRAVOIniFile',
    'Get-BRAVOIniValue',
    'ConvertTo-BRAVOIniPathValue',
    'Test-BRAVOAbsolutePath',
    'Get-BRAVOApacheDocumentRoot',
    'Get-BRAVOSystemDirectoryPath',
    'Get-BRAVOSystemBravoIniPath',
    'Get-BRAVOSystemRangeIdLogPath',
    'Resolve-BRAVOInstallationDiscovery',
    'Resolve-BRAVOEffectiveLimsRoot',
    'Resolve-BRAVOEffectiveSystemLogRoot',
    'Resolve-BRAVOEffectiveBackupRoot',
    'Get-BRAVOEffectiveSynchronizationConfiguration',
    'Test-BRAVODiscoveryResult',
    'Save-BRAVODiscoveryBaseline',
    'Compare-BRAVODiscoveryBaseline'
)
