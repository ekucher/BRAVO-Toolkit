# BRAVO.SchedulerDiagnostics — read-only діагностика зареєстрованих завдань Планувальника.
#
# Власник: перевірка «які завдання BRAVO передають -ConfigPath і на який файл» (#281 /
# #154, доказ B5). Модуль нічого не змінює: не реєструє, не редагує й не видаляє
# завдання, не читає і не виконує файли конфігурації; лише розбирає текст Action
# (Task.Xml) і перевіряє наявність/ім'я цільового файла.
#
# Залежності спрямовано від викликача: правило «що loader приймає як legacy primary»
# належить BRAVO_CONFIG_LOADER.ps1 (Test-BravoLegacyConfiguration) і передається сюди
# параметром -LegacyConfigurationValidator, а не дублюється.
#
# Чому окремий модуль, а не BRAVO.System: BRAVO.System уже ~2100 рядків із кількома
# незалежними відповідальностями; сюди додається цілісна діагностична відповідальність
# (розбір аргументів, прив'язка параметрів, класифікація цілі), яка не потрібна Installer-у.

function ConvertFrom-BRAVOWindowsCommandLine {
    # Розбір рядка аргументів за правилами CommandLineToArgvW (так powershell.exe
    # отримує Action.Arguments завдання). Лише розбір рядка — нічого не виконується.
    #  - роздільники: ЛИШЕ пробіл і табуляція (U+00A0, CR/LF — не роздільники);
    #  - 2N '\' + '"' -> N '\' і перемикання лапок; 2N+1 '\' + '"' -> N '\' і літерал '"';
    #  - усередині лапок `""` -> літерал '"' І вихід з режиму лапок. Це поведінка shell32
    #    CommandLineToArgvW, звірена нативним оракулом (P/Invoke) на Windows Server 2022;
    #    це НЕ варіант msvcrt після 2008 р., де `""` лишає в режимі лапок;
    #  - поза лапками `""` дає порожній аргумент.
    #  - `""` усередині лапок у реалізації CRT (msvcrt після 2008 р.) НЕ виходить з режиму лапок,
    #    тож межі токенів залежать від того, чий розбір застосує цільовий виконуваний файл.
    #    Ця неоднозначність не розв'язується статично: DoubledQuoteInQuote=$true, і
    #    Get-BRAVOPowerShellActionDefinition не сертифікує такий рядок (Unknown).
    # Повертає токени, ознаку збалансованості лапок і DoubledQuoteInQuote.
    param([AllowNull()][AllowEmptyString()][string]$CommandLine)

    $tokens = New-Object 'System.Collections.Generic.List[string]'
    $length = if ($null -eq $CommandLine) { 0 } else { $CommandLine.Length }
    $builder = New-Object System.Text.StringBuilder
    $inQuote = $false
    $hasToken = $false
    $doubledQuoteInQuote = $false
    $index = 0
    while ($index -lt $length) {
        $char = $CommandLine[$index]
        if ($char -eq [char]'\') {
            $end = $index
            while ($end -lt $length -and $CommandLine[$end] -eq [char]'\') { $end++ }
            $slashCount = $end - $index
            if ($end -lt $length -and $CommandLine[$end] -eq [char]'"') {
                [void]$builder.Append([char]'\', [int][math]::Floor($slashCount / 2))
                if (($slashCount % 2) -eq 1) {
                    [void]$builder.Append([char]'"')
                    $index = $end + 1
                } else {
                    $index = $end
                }
            } else {
                [void]$builder.Append([char]'\', $slashCount)
                $index = $end
            }
            $hasToken = $true
            continue
        }
        if ($char -eq [char]'"') {
            if ($inQuote -and ($index + 1) -lt $length -and $CommandLine[$index + 1] -eq [char]'"') {
                [void]$builder.Append([char]'"')
                $inQuote = $false
                $doubledQuoteInQuote = $true
                $hasToken = $true
                $index += 2
                continue
            }
            $inQuote = -not $inQuote
            $hasToken = $true
            $index++
            continue
        }
        if (($char -eq [char]' ' -or $char -eq [char]"`t") -and -not $inQuote) {
            if ($hasToken) {
                $tokens.Add($builder.ToString())
                [void]$builder.Clear()
                $hasToken = $false
            }
            $index++
            continue
        }
        [void]$builder.Append($char)
        $hasToken = $true
        $index++
    }
    if ($hasToken) { $tokens.Add($builder.ToString()) }

    return [pscustomobject]@{
        Tokens   = $tokens.ToArray()
        Balanced = (-not $inQuote)
        DoubledQuoteInQuote = $doubledQuoteInQuote
    }
}

function Test-BRAVODiagnosticProcessIsWow64 {
    # Діагностика запущена як 32-бітний процес на 64-бітній ОС (WOW64): тут %ProgramFiles% дорівнює
    # "Program Files (x86)", а 64-бітний Task Engine / цільовий процес отримає "Program Files".
    return [bool]([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
}

function Expand-BRAVOTaskActionVariable {
    # Розкриття %VAR% у тексті Action. Task Scheduler розкриває змінні у СВОЄМУ середовищі,
    # тому розкриваються лише машинно-стабільні (SystemRoot, windir, ProgramData, ProgramFiles,
    # SystemDrive); решта потрапляє в Unsupported. NamePattern — що вважати іменем змінної між
    # '%': за замовчуванням будь-що без символів \ і /; для командних рядків (де '%' може бути
    # псевдонімом ForEach-Object) викликач передає суворіший шаблон без пробілів.
    # ProgramFilesArchitectureUnknown (#496, B4): у WOW64-процесі діагностики %ProgramFiles% залежить від
    # архітектури процесу діагностики, а не завдання; архітектуру цілі не вгадуємо -> %ProgramFiles% = Unsupported.
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [string]$NamePattern = '[^%\\/]+',
        [bool]$ProgramFilesArchitectureUnknown = (Test-BRAVODiagnosticProcessIsWow64)
    )

    $stableVariables = @('SystemRoot', 'windir', 'ProgramData', 'ProgramFiles', 'SystemDrive')
    $unsupported = New-Object 'System.Collections.Generic.List[string]'
    $unsupportedPositions = New-Object 'System.Collections.Generic.List[int]'
    $result = [string]$Text
    foreach ($match in [regex]::Matches($result, "%($NamePattern)%")) {
        $variableName = $match.Groups[1].Value
        $value = $null
        if ($stableVariables -contains $variableName) {
            $value = [Environment]::GetEnvironmentVariable($variableName)
            if ($ProgramFilesArchitectureUnknown -and [string]::Equals($variableName, 'ProgramFiles', [StringComparison]::OrdinalIgnoreCase)) {
                $value = $null
            }
        }
        if ([string]::IsNullOrEmpty($value)) {
            $unsupported.Add($variableName)
            $unsupportedPositions.Add([int]$match.Index + 1)
        } else {
            $result = $result.Replace($match.Value, $value)
        }
    }
    # Unsupported/UnsupportedPositions: ім'я лишається лише для логіки викликача; У ЗВІТ воно не потрапляє
    # (вираз між '%' може містити секрет, напр. %password=...%) — виводиться лише позиція (1-based) у рядку.
    return [pscustomobject]@{ Text = $result; Unsupported = $unsupported.ToArray(); UnsupportedPositions = $unsupportedPositions.ToArray() }
}

function Test-BRAVOTaskLocalPathSafe {
    # SEC-001: єдина перевірка перед БУДЬ-ЯКИМ зверненням до файлової системи зі шляхом із Task.Xml
    # (Test-Path / Get-Item / ParseFile / читання валідатором). Шлях керується завданням, тож діагностика
    # (від імені оператора) не повинна ініціювати вихідний SMB/NTLM-запит і не повинна йти через reparse point.
    #
    # Файлова система відкривається ЛИШЕ для шляхів усередині TrustedRoot (каталог поточного runtime) і лише
    # якщо кожен компонент захищений від підміни (див. нижче); шляхи поза ним НІКОЛИ не відкриваються.
    # ЛЕКСИЧНО/за метаданими (без звернення до диска): шлях і root — лише `X:\...`/`X:/...` (UNC, `//`, `\\?\`,
    # `\\.\`, відносні — відхиляються); нормалізація GetFullPath; префікс за межею компонента, без урахування регістру
    # (`C:\BRAVO2` НЕ всередині `C:\BRAVO`); літера диска не мережева ([IO.DriveInfo].DriveType читає локальну таблицю
    # підключень, до сервера не звертається). Порожній/неприйнятний TrustedRoot = жодного доступу.
    #
    # ОДИН обхід згори вниз (корінь диска -> ціль). Кожен компонент i ПОВНІСТЮ перевіряється ДО будь-якого виклику
    # файлової системи, що проходить через нього (тобто до GetAttributes(i+1)):
    #  1) GetAttributes(i): перший неіснуючий компонент зупиняє обхід (нижче нічого немає); reparse point -> відмова;
    #  2) Get-Acl(i) (будь-яка помилка = недовірений, fail closed): власник довірений; жоден недовірений Allow-ACE
    #     не дає Delete/ChangePermissions/TakeOwnership; для каталогу — DeleteSubdirectoriesAndFiles; для компонентів
    #     на рівні TrustedRoot і нижче додатково WriteData/CreateFiles, AppendData/CreateDirectories, WriteAttributes,
    #     WriteExtendedAttributes. Відмова -> негайно, i+1 не чіпаємо.
    # Чому це стабільно: батько i уже перевірений (ніхто недовірений не видалить дочірній компонент), а в самого i
    # немає недовірених прав Delete/власника/DACL, тож i не можна замінити після перевірки, і розв'язання i+1
    # детерміноване. Модель загроз: непривілейований обліковий запис не може створити symlink на віддалену ціль без
    # SeCreateSymbolicLinkPrivilege, а junction не може вказувати на UNC; отже, щоб направити шлях назовні, треба
    # замінити існуючий компонент — а це за умов вище недоступно недовіреним суб'єктам. Вище root створення нових
    # сусідів (напр. Authenticated Users «create folders» на C:\) допустиме.
    # NULL DACL компонента = недовіреним дозволено все -> відмова (порожній DACL допустимий).
    # Довірені суб'єкти (за SID; неперекладний = недовірений): SYSTEM (S-1-5-18), BUILTIN\Administrators
    # (S-1-5-32-544), NT SERVICE\TrustedInstaller та поточний користувач процесу. Враховуються лише Allow-ACE, що
    # діють на сам об'єкт (InheritOnly пропускаються); Deny ігноруються (консервативно).
    # (Архітектурний борг: політику ACL runtime-каталогу ПИШУТЬ функції Set-* у BRAVO_TASKS_INSTALL.ps1; це лише
    # read-only верифікатор, локальний для сканера.)
    # Викликач після використання (ParseFile/Get-Item/валідатор) повторює перевірку — захист у глибину.
    # Safe=$false -> Reason без вмісту шляху (узагальнене пояснення), шлях не читається.
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$TrustedRoot
    )

    $reject = {
        param($Reason)
        [pscustomobject]@{ Safe = $false; Reason = $Reason }
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') {
        return (& $reject 'шлях не є локальним шляхом із літерою диска (мережевий/UNC/пристрій/відносний) — не перевірявся')
    }
    if ([string]::IsNullOrWhiteSpace($TrustedRoot) -or $TrustedRoot -notmatch '^[A-Za-z]:[\\/]') {
        return (& $reject 'каталог довіреного runtime не задано або він не є локальним шляхом — файлова система не відкривається')
    }
    $aclReason = 'ACL шляху не підтверджує захист від підміни компонентів недовіреними суб''єктами — не перевірявся'
    $reparseReason = 'компонент шляху є reparse point (junction/symlink) — ціль могла б бути віддаленою, не перевірявся'
    try {
        $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd([char]92, [char]47)
        $fullRoot = [IO.Path]::GetFullPath($TrustedRoot).TrimEnd([char]92, [char]47)
        if ($fullPath -notmatch '^[A-Za-z]:' -or $fullRoot -notmatch '^[A-Za-z]:') {
            return (& $reject 'шлях не є локальним шляхом із літерою диска (мережевий/UNC/пристрій/відносний) — не перевірявся')
        }
        $inside = [string]::Equals($fullPath, $fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)
        if (-not $inside) {
            return (& $reject 'шлях поза каталогом довіреного runtime — не відкривається (наявність і вміст не перевірялися)')
        }
        $driveType = (New-Object System.IO.DriveInfo ($fullRoot.Substring(0, 1))).DriveType
        if ($driveType -eq [System.IO.DriveType]::Network) {
            return (& $reject 'шлях на мережевому диску — не перевірявся')
        }

        $trusted = @(
            'S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464',
            [string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        )
        $genericAll = 0x10000000
        $coreMask = 0x10000 -bor 0x40000 -bor 0x80000 -bor $genericAll         # Delete, ChangePermissions, TakeOwnership
        $deleteChildMask = 0x40 -bor $genericAll                                # DeleteSubdirectoriesAndFiles
        $writeMask = 0x2 -bor 0x4 -bor 0x100 -bor 0x10 -bor $genericAll -bor 0x40000000  # data/append/attrs/ext attrs/GenericWrite
        $inheritOnly = [int][System.Security.AccessControl.PropagationFlags]::InheritOnly
        $sidType = [System.Security.Principal.SecurityIdentifier]

        $segments = @($fullPath.Substring(3) -split '[\\/]' | Where-Object { $_ -ne '' })
        $component = $fullPath.Substring(0, 3)
        $index = -1
        while ($true) {
            if ($index -ge 0) {
                if ($index -ge $segments.Count) { break }
                $component = Join-Path -Path $component -ChildPath $segments[$index]
            }
            $index++
            # (1) атрибути компонента i: його предки вже повністю перевірені.
            try {
                $attributes = [System.IO.File]::GetAttributes($component)
            } catch [System.IO.FileNotFoundException] {
                break
            } catch [System.IO.DirectoryNotFoundException] {
                break
            }
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return (& $reject $reparseReason) }
            # (2) ACL компонента i — ДО будь-якого звернення до i+1.
            $isDirectory = [bool]($attributes -band [System.IO.FileAttributes]::Directory)
            $belowRoot = ($component.Length -ge $fullRoot.Length)
            $acl = Get-Acl -LiteralPath $component -ErrorAction Stop
            # NULL DACL (необмежений доступ для всіх) не дає жодного правила в GetAccessRules, але НЕ є порожнім DACL
            # (порожній = доступу немає ні в кого, це допустимо). Розрізняємо за сирим дескриптором: DiscretionaryAcl = $null.
            $rawDescriptor = New-Object System.Security.AccessControl.RawSecurityDescriptor($acl.GetSecurityDescriptorBinaryForm(), 0)
            if ($null -eq $rawDescriptor.DiscretionaryAcl) { return (& $reject $aclReason) }
            $owner = $acl.GetOwner($sidType)
            if ($null -eq $owner -or $trusted -notcontains [string]$owner.Value) { return (& $reject $aclReason) }
            foreach ($rule in @($acl.GetAccessRules($true, $true, $sidType))) {
                if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
                if (([int]$rule.PropagationFlags -band $inheritOnly) -ne 0) { continue }
                if ($trusted -contains [string]$rule.IdentityReference.Value) { continue }
                $rights = [int]$rule.FileSystemRights
                if (($rights -band $coreMask) -ne 0) { return (& $reject $aclReason) }
                if ($isDirectory -and ($rights -band $deleteChildMask) -ne 0) { return (& $reject $aclReason) }
                if ($belowRoot -and ($rights -band $writeMask) -ne 0) { return (& $reject $aclReason) }
            }
        }
    } catch {
        return (& $reject 'не вдалося безпечно перевірити шлях (локальна перевірка не підтвердила його безпеку) — не перевірявся')
    }
    return [pscustomobject]@{ Safe = $true; Reason = $null }
}

function Resolve-BRAVOTaskActionPath {
    # Шлях з Action (скрипт або значення -ConfigPath) -> повний шлях. Task Scheduler
    # розкриває %VAR% у СВОЄМУ середовищі (Task Engine кешує його), а не в процесі
    # діагностики. Тому розкриваються лише машинно-стабільні змінні (SystemRoot, windir,
    # ProgramData, ProgramFiles, SystemDrive); будь-яка інша (%USERPROFILE%, %APPDATA%,
    # %TEMP%, %COMPUTERNAME% тощо) дає Path=$null з поясненням у Reason — класифікацію
    # для такого шляху не видаємо. Відносний шлях розв'язується від WorkingDirectory
    # завдання (теж лише зі стабільними змінними).
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$WorkingDirectory
    )

    $failure = {
        param($Reason)
        [pscustomobject]@{ Path = $null; Reason = $Reason }
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { return (& $failure 'порожній шлях') }

    $expand = {
        param($Text)
        Expand-BRAVOTaskActionVariable -Text $Text
    }
    $unsupportedReason = {
        param($Positions)
        'шлях залежить від змінної середовища (позиція ' + (@($Positions) -join ', ') + ' у рядку; вираз не виводиться), ' +
        'яку Task Engine бере зі свого (кешованого) середовища, а діагностика не може його відтворити; ' +
        'розкриваються лише %SystemRoot%, %windir%, %ProgramData%, %ProgramFiles%, %SystemDrive%' +
        $(if (Test-BRAVODiagnosticProcessIsWow64) {
                ' (%ProgramFiles% не розкривається, бо діагностику запущено як 32-бітний процес на 64-бітній ОС: архітектура цільового процесу невідома)'
            } else { '' })
    }

    try {
        # #496 F2: значення не обрізається — пробіл на краях у лапках PowerShell зберігає, обрізання дало б інший шлях.
        if ($Path -ne $Path.Trim()) { return (& $failure 'шлях має пробіли на початку чи в кінці значення — вони є частиною значення в PowerShell, тож діагностика не може довести, який шлях буде використано') }
        $expanded = & $expand $Path
        if (@($expanded.Unsupported).Count -gt 0) { return (& $failure (& $unsupportedReason $expanded.UnsupportedPositions)) }
        $text = $expanded.Text
        $remoteReason = 'шлях не є локальним шляхом із літерою диска (мережевий/UNC/пристрій) — не перевірявся'
        # SEC-001: лексична відмова ДО GetFullPath/звернення до диска: `\\host\share`, `//host`, `\\?\`, `\\.\`.
        if ($text -match '^[\\/]{2}') { return (& $failure $remoteReason) }
        if ([IO.Path]::IsPathRooted($text) -and
            $text -notmatch '^[A-Za-z]:(?![\\/])' -and
            $text -notmatch '^[\\/](?![\\/])') {
            $fullRooted = [IO.Path]::GetFullPath($text)
            if ($fullRooted -notmatch '^[A-Za-z]:[\\/]') { return (& $failure $remoteReason) }
            return [pscustomobject]@{ Path = $fullRooted; Reason = $null }
        }
        if ($text -match '^[A-Za-z]:' -or $text -match '^[\\/]') {
            return (& $failure 'шлях залежить від поточного диска/каталогу (X:foo або \foo)')
        }
        if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            return (& $failure 'відносний шлях без WorkingDirectory завдання')
        }
        $expandedWorkingDirectory = & $expand $WorkingDirectory.Trim().Trim('"')
        if (@($expandedWorkingDirectory.Unsupported).Count -gt 0) {
            return (& $failure (& $unsupportedReason $expandedWorkingDirectory.UnsupportedPositions))
        }
        if ($expandedWorkingDirectory.Text -match '^[\\/]{2}') { return (& $failure $remoteReason) }
        # #496 B5: лише повна форма `X:\...` (так само, як для цільового шляху). Кореневий `\BRAVO` і `X:foo`
        # IsPathRooted вважає абсолютними, але GetFullPath розв'язав би їх щодо диска/каталогу ПРОЦЕСУ діагностики,
        # а не завдання (lpCurrentDirectory у CreateProcess — повний шлях).
        if ($expandedWorkingDirectory.Text -notmatch '^[A-Za-z]:[\\/]') {
            return (& $failure 'WorkingDirectory завдання не є повним шляхом із літерою диска (X:\...) — розв''язати відносний шлях неможливо')
        }
        return [pscustomobject]@{
            Path = [IO.Path]::GetFullPath((Join-Path -Path $expandedWorkingDirectory.Text -ChildPath $text))
            Reason = $null
        }
    } catch {
        return (& $failure 'некоректний шлях (не розібрано)')
    }
}

function Get-BRAVOParameterValidationRule {
    # #496 B6: атрибут параметра param()-блоку -> правило, яке сканер уміє оцінити статично.
    #  $null  — атрибут не впливає на прийняття значення (Parameter, Alias, ArgumentCompleter, Obsolete, PSDefaultValue);
    #  Set    — ValidateSet із літеральних рядків для [string]-параметра без іменованих аргументів (IgnoreCase тощо);
    #  NotNull/NotNullOrEmpty — для [string]-параметра (рішення тривіальне для літерального значення);
    #  Opaque — усе інше (ValidateScript/Pattern/Range/Length/Count, Allow*, ArgumentTransformation, довільні атрибути,
    #           недетермінований ValidateSet): результат статично не визначити (fail closed).
    param($Attribute, $StaticType)

    # Ограничення типу ([string]) — теж елемент Attributes параметра, але не атрибут (TypeConstraintAst).
    if ($Attribute -isnot [System.Management.Automation.Language.AttributeAst]) { return $null }
    $name = ([string]$Attribute.TypeName.Name -split '\.')[-1]
    if ($name -match '(?i)Attribute$') { $name = $name.Substring(0, $name.Length - 9) }
    if ($name -match '(?i)^(Parameter|Alias|ArgumentCompleter|Obsolete|PSDefaultValue)$') { return $null }
    $opaque = [pscustomobject]@{ Kind = 'Opaque'; Name = $name; Values = @() }
    if ($name -ieq 'ValidateSet') {
        $values = New-Object 'System.Collections.Generic.List[string]'
        $decidable = ($StaticType -eq [string]) -and @($Attribute.NamedArguments).Count -eq 0 -and @($Attribute.PositionalArguments).Count -gt 0
        foreach ($argument in @($Attribute.PositionalArguments)) {
            if ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $values.Add([string]$argument.Value)
            } else {
                $decidable = $false
            }
        }
        if ($decidable) { return [pscustomobject]@{ Kind = 'Set'; Name = $name; Values = $values.ToArray() } }
        return $opaque
    }
    if (($name -ieq 'ValidateNotNull' -or $name -ieq 'ValidateNotNullOrEmpty') -and
        $StaticType -eq [string] -and @($Attribute.NamedArguments).Count -eq 0 -and @($Attribute.PositionalArguments).Count -eq 0) {
        return [pscustomobject]@{ Kind = $(if ($name -ieq 'ValidateNotNull') { 'NotNull' } else { 'NotNullOrEmpty' }); Name = $name; Values = @() }
    }
    return $opaque
}

function Test-BRAVOParameterValueValidation {
    # #496 B6: чи пройде літеральне значення перевірки атрибутів параметра. Accepted=$false і для відхилення
    # (значення поза ValidateSet), і для неоцінюваного атрибута; Reason не містить значення (воно може бути секретом).
    param(
        [AllowNull()][object[]]$Rule,
        [AllowNull()][AllowEmptyString()][string]$Value
    )

    foreach ($rule in @($Rule)) {
        if ($null -eq $rule) { continue }
        switch ([string]$rule.Kind) {
            'Set' {
                $member = @($rule.Values | Where-Object { [string]::Equals([string]$_, $Value, [StringComparison]::OrdinalIgnoreCase) })
                if ($member.Count -eq 0) {
                    return [pscustomobject]@{ Accepted = $false; Reason = 'значення не входить до ValidateSet параметра (значення не виводиться): PowerShell відмовить у прив''язці до запуску скрипта' }
                }
            }
            'ActionPreference' {
                $member = @($rule.Values | Where-Object { [string]::Equals([string]$_, $Value, [StringComparison]::OrdinalIgnoreCase) })
                if ($member.Count -eq 0) {
                    return [pscustomobject]@{ Accepted = $false; Reason = 'значення не доведено допустимою назвою ActionPreference для цього загального параметра Windows PowerShell 5.1 (значення не виводиться; числові форми й скорочення не моделюються): PowerShell може відмовити у прив''язці до запуску скрипта' }
                }
            }
            'NonNegativeInt32' {
                $parsedBuffer = 0
                if (-not [int]::TryParse([string]$Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedBuffer) -or $parsedBuffer -lt 0) {
                    return [pscustomobject]@{ Accepted = $false; Reason = 'значення не доведено невід''ємним Int32 (значення не виводиться): PowerShell відмовить у прив''язці до запуску скрипта' }
                }
            }
            'NotNull' { }
            'NotNullOrEmpty' {
                if ([string]::IsNullOrEmpty($Value)) {
                    return [pscustomobject]@{ Accepted = $false; Reason = 'порожнє значення відхиляється ValidateNotNullOrEmpty: PowerShell відмовить у прив''язці до запуску скрипта' }
                }
            }
            default {
                return [pscustomobject]@{ Accepted = $false; Reason = "параметр має атрибут перевірки/перетворення значення ($($rule.Name)), результат якого статично не визначити" }
            }
        }
    }
    return [pscustomobject]@{ Accepted = $true; Reason = $null }
}

function Get-BRAVOScriptDeclaredParameter {
    # Модель param()-блоку скрипта для відтворення прив'язки параметрів PowerShell:
    #  Entries         — кожне ім'я та alias -> параметр-власник (Owner);
    #  SwitchOwners    — власники типу [switch] (значення не споживають);
    #  PositionalOrder — власники у порядку позиційної прив'язки;
    #  PositionalAmbiguous — позицію статично не визначити (набори параметрів, змішані
    #                   явні/неявні Position, ValueFromRemainingArguments).
    #  MandatoryOwners — #496: параметри з Mandatory (літерал чи будь-яке значення, крім $false — fail closed);
    #  TypedOwners     — #496: власник -> 'Int32'|'Int64'|'Other' для типів, крім string/object/switch.
    # Known=$false, коли скрипт недоступний або не розбирається.
    param(
        [AllowNull()][AllowEmptyString()][string]$ScriptPath,
        [AllowNull()][AllowEmptyString()][string]$TrustedRuntimeRoot
    )

    $unknown = [pscustomobject]@{
        Known = $false; Entries = @(); SwitchOwners = @(); PositionalOrder = @(); PositionalAmbiguous = $true; Validation = @{}; MandatoryOwners = @(); TypedOwners = @{}; HasParameterSets = $false
    }
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return $unknown }
    try {
        # SEC-001: скрипт поза TrustedRuntimeRoot не відкривається й не розбирається.
        if (-not (Test-BRAVOTaskLocalPathSafe -Path $ScriptPath -TrustedRoot $TrustedRuntimeRoot).Safe) { return $unknown }
        if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { return $unknown }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
        if ($null -eq $ast -or @($errors).Count -gt 0) { return $unknown }
        # Повторна перевірка після використання (захист у глибину): шлях змінився -> результат відкидається.
        if (-not (Test-BRAVOTaskLocalPathSafe -Path $ScriptPath -TrustedRoot $TrustedRuntimeRoot).Safe) { return $unknown }

        $entries = New-Object 'System.Collections.Generic.List[object]'
        $switchOwners = New-Object 'System.Collections.Generic.List[string]'
        $positional = New-Object 'System.Collections.Generic.List[object]'
        $validation = @{}
        $mandatoryOwners = New-Object 'System.Collections.Generic.List[string]'
        $typedOwners = @{}
        $ambiguous = $false
        $hasParameterSets = $false
        $positionalBinding = $true
        $paramBlock = $ast.ParamBlock
        if ($null -ne $paramBlock) {
            $advanced = $false
            $supportsShouldProcess = $false
            foreach ($attribute in @($paramBlock.Attributes)) {
                if ($attribute.TypeName.Name -ne 'CmdletBinding') { continue }
                $advanced = $true
                foreach ($namedArgument in @($attribute.NamedArguments)) {
                    if ($namedArgument.ArgumentName -eq 'SupportsShouldProcess') {
                        # #496 F3: голий атрибут чи літерал $true — підтримується; літерал $false — ні;
                        # будь-яке інше значення не моделюється (fail closed: модель параметрів відкидається).
                        if ($namedArgument.ExpressionOmitted) { $supportsShouldProcess = $true }
                        elseif ($namedArgument.Argument.Extent.Text -match '^\$true$') { $supportsShouldProcess = $true }
                        elseif ($namedArgument.Argument.Extent.Text -match '^\$false$') { $supportsShouldProcess = $false }
                        else { return $unknown }
                    }
                    if ($namedArgument.ArgumentName -eq 'DefaultParameterSetName') { $ambiguous = $true; $hasParameterSets = $true }
                    if ($namedArgument.ArgumentName -eq 'PositionalBinding' -and
                        $namedArgument.Argument.Extent.Text -match '^\$false$') { $positionalBinding = $false }
                }
            }
            $declarationIndex = 0
            $explicitCount = 0
            foreach ($parameter in @($paramBlock.Parameters)) {
                $ownerName = [string]$parameter.Name.VariablePath.UserPath
                $entries.Add([pscustomobject]@{ Name = $ownerName; Owner = $ownerName })
                $isSwitch = ($parameter.StaticType -eq [System.Management.Automation.SwitchParameter])
                if ($isSwitch) { $switchOwners.Add($ownerName) }
                elseif ($parameter.StaticType -ne [string] -and $parameter.StaticType -ne [object]) {
                    $typedOwners[$ownerName] = $(if ($parameter.StaticType -eq [int]) { 'Int32' } elseif ($parameter.StaticType -eq [long]) { 'Int64' } else { 'Other' })
                }
                $explicitPosition = $null
                $parameterRules = New-Object 'System.Collections.Generic.List[object]'
                foreach ($attribute in @($parameter.Attributes)) {
                    $validationRule = Get-BRAVOParameterValidationRule -Attribute $attribute -StaticType $parameter.StaticType
                    if ($null -ne $validationRule) { $parameterRules.Add($validationRule) }
                    if ($attribute.TypeName.Name -eq 'Parameter') {
                        $advanced = $true
                        foreach ($namedArgument in @($attribute.NamedArguments)) {
                            if ($namedArgument.ArgumentName -eq 'Position') {
                                $positionText = $namedArgument.Argument.Extent.Text
                                $parsedPosition = 0
                                if ([int]::TryParse($positionText, [ref]$parsedPosition)) {
                                    $explicitPosition = $parsedPosition
                                } else {
                                    $ambiguous = $true
                                }
                            }
                            if ($namedArgument.ArgumentName -eq 'ParameterSetName') {
                                $ambiguous = $true
                                # #496: лише літерал __AllParameterSets не створює набору; будь-що інше — набори параметрів не моделюються (fail closed).
                                $setArgument = $namedArgument.Argument
                                if (-not ($setArgument -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                                        [string]::Equals([string]$setArgument.Value, '__AllParameterSets', [StringComparison]::OrdinalIgnoreCase))) {
                                    $hasParameterSets = $true
                                }
                            }
                            if ($namedArgument.ArgumentName -eq 'Mandatory' -and $namedArgument.Argument.Extent.Text -notmatch '^\$false$') {
                                $mandatoryOwners.Add($ownerName)
                            }
                            if ($namedArgument.ArgumentName -eq 'ValueFromRemainingArguments' -and
                                $namedArgument.Argument.Extent.Text -notmatch '^\$false$') { $ambiguous = $true }
                        }
                    }
                    if ($attribute.TypeName.Name -ne 'Alias') { continue }
                    foreach ($aliasArgument in @($attribute.PositionalArguments)) {
                        if ($aliasArgument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                            $entries.Add([pscustomobject]@{ Name = [string]$aliasArgument.Value; Owner = $ownerName })
                        }
                    }
                }
                if ($parameterRules.Count -gt 0) { $validation[$ownerName] = $parameterRules.ToArray() }
                if ($null -ne $explicitPosition) { $explicitCount++ }
                if (-not $isSwitch) {
                    $positional.Add([pscustomobject]@{ Owner = $ownerName; Explicit = $explicitPosition; Index = $declarationIndex })
                }
                $declarationIndex++
            }
            if ($advanced) {
                # Загальні параметри (advanced-скрипт) змодельовано точно: [switch]-типу —
                # Verbose/Debug (+WhatIf/Confirm за SupportsShouldProcess), без значення;
                # решта споживає одне значення. Alias-и PowerShell: vb, db, wi, cf, ea, wa, infa/ia, ev, wv, iv, ov, ob, pv.
                $commonParameters = @(
                    @('Verbose', $true, @('vb')), @('Debug', $true, @('db')),
                    @('ErrorAction', $false, @('ea')), @('WarningAction', $false, @('wa')),
                    @('InformationAction', $false, @('infa', 'ia')), @('ErrorVariable', $false, @('ev')),
                    @('WarningVariable', $false, @('wv')), @('InformationVariable', $false, @('iv')),
                    @('OutVariable', $false, @('ov')), @('OutBuffer', $false, @('ob')), @('PipelineVariable', $false, @('pv'))
                )
                if ($supportsShouldProcess) {
                    $commonParameters += , @('WhatIf', $true, @('wi'))
                    $commonParameters += , @('Confirm', $true, @('cf'))
                }
                foreach ($common in $commonParameters) {
                    $entries.Add([pscustomobject]@{ Name = [string]$common[0]; Owner = [string]$common[0] })
                    foreach ($commonAlias in @($common[2])) {
                        $entries.Add([pscustomobject]@{ Name = [string]$commonAlias; Owner = [string]$common[0] })
                    }
                    if ([bool]$common[1]) { $switchOwners.Add([string]$common[0]) }
                }
                # #496: значення модельованих загальних параметрів має бути доведено допустимим (перевірено пробами powershell.exe 5.1:
                # Stop/Continue/SilentlyContinue/Inquire/Ignore приймаються, Suspend/Break/Bogus/число 5 відхиляються; числа й скорочення не моделюємо).
                # Параметр, оголошений самим скриптом із тією ж назвою, не перекривається.
                $actionRule = [pscustomobject]@{ Kind = 'ActionPreference'; Name = 'ActionPreference'; Values = @('Stop', 'Continue', 'SilentlyContinue', 'Inquire', 'Ignore') }
                $bufferRule = [pscustomobject]@{ Kind = 'NonNegativeInt32'; Name = 'OutBuffer'; Values = @() }
                foreach ($actionOwner in @('ErrorAction', 'WarningAction', 'InformationAction')) {
                    if (-not $validation.ContainsKey($actionOwner)) { $validation[$actionOwner] = @($actionRule) }
                }
                if (-not $validation.ContainsKey('OutBuffer')) { $validation['OutBuffer'] = @($bufferRule) }
            }
            $explicitPositional = @($positional | Where-Object { $null -ne $_.Explicit })
            if ($positionalBinding -and $explicitPositional.Count -gt 0 -and $explicitPositional.Count -ne $positional.Count) {
                $ambiguous = $true
            }
        }
        $order = @()
        if ($positionalBinding) {
            $explicitSorted = @($positional | Where-Object { $null -ne $_.Explicit } | Sort-Object -Property Explicit)
            if ($explicitSorted.Count -gt 0) {
                $order = @($explicitSorted | ForEach-Object { $_.Owner })
            } else {
                $order = @($positional | ForEach-Object { $_.Owner })
            }
        } else {
            $order = @($positional | Where-Object { $null -ne $_.Explicit } | Sort-Object -Property Explicit | ForEach-Object { $_.Owner })
        }
        return [pscustomobject]@{
            Known = $true
            Entries = $entries.ToArray()
            SwitchOwners = $switchOwners.ToArray()
            PositionalOrder = @($order)
            PositionalAmbiguous = $ambiguous
            Validation = $validation
            MandatoryOwners = $mandatoryOwners.ToArray()
            TypedOwners = $typedOwners
            HasParameterSets = $hasParameterSets
        }
    } catch {
        return $unknown
    }
}

function Resolve-BRAVOParameterSpelling {
    # Написання параметра (без дефіса) -> параметр-власник за правилами PowerShell:
    # точний збіг імені/alias виграє; префікс прив'язується, лише якщо ВСІ кандидати
    # належать одному параметру; кілька власників = Ambiguous (PowerShell відмовить).
    # Без відомого param()-блоку працює лише евристика за іменем: префікс ConfigPath
    # довжиною від 4 символів (Evidence='NameOnly'), решта — Owner=$null.
    param(
        [AllowNull()][AllowEmptyString()][string]$Spelling,
        [Parameter(Mandatory = $true)]$DeclaredParameter
    )

    $result = [pscustomobject]@{ Owner = $null; Ambiguous = $false; AmbiguousOwners = @(); Evidence = 'ScriptParam' }
    if ([string]::IsNullOrEmpty($Spelling)) { return $result }
    $canonical = 'ConfigPath'

    if (-not [bool]$DeclaredParameter.Known) {
        $result.Evidence = 'NameOnly'
        if ($Spelling.Length -ge 4 -and $canonical.StartsWith($Spelling, [StringComparison]::OrdinalIgnoreCase)) {
            $result.Owner = $canonical
        }
        return $result
    }

    $entries = @($DeclaredParameter.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
    $exact = @($entries | Where-Object { [string]::Equals($_.Name, $Spelling, [StringComparison]::OrdinalIgnoreCase) })
    if ($exact.Count -gt 0) {
        $result.Owner = [string]$exact[0].Owner
        return $result
    }
    $prefixOwners = @($entries | Where-Object { $_.Name.StartsWith($Spelling, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { [string]$_.Owner } | Select-Object -Unique)
    if ($prefixOwners.Count -eq 1) {
        $result.Owner = $prefixOwners[0]
    } elseif ($prefixOwners.Count -gt 1) {
        $result.Ambiguous = $true
        $result.AmbiguousOwners = $prefixOwners
    }
    return $result
}

function Test-BRAVOScriptPathIsBravoEntrypoint {
    # Ціль виклику — BRAVO_*.ps1 (за ім'ям файла в шляху). Єдине правило для -File і -Command.
    param([AllowNull()][AllowEmptyString()][string]$ScriptPath)

    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return $false }
    return [bool]($ScriptPath -match '(?i)(^|[\\/])BRAVO_[A-Za-z0-9_]*\.ps1$')
}

function Test-BRAVOStockWindowsPowerShellPath {
    # #496 B1: Exec.Command — рівно штатний Windows PowerShell 5.1: %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
    # або %SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe (після розкриття стабільних змінних, без урахування
    # регістру, щодо справжнього SystemRoot). Голе `powershell`/`powershell.exe` (пошук у PATH), довільний каталог
    # (напр. C:\Tools\powershell.exe), нерозкриті змінні, `..` — не штатні. Інсталятор реєструє завдання з повним
    # шляхом System32 (BRAVO.Configuration.Derivation: PowerShellExecutable = Join-Path $env:SystemRoot ...).
    param([AllowNull()][AllowEmptyString()][string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    $expanded = Expand-BRAVOTaskActionVariable -Text $Command.Trim().Trim('"').Trim()
    if (@($expanded.Unsupported).Count -gt 0) { return $false }
    $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot')
    if ([string]::IsNullOrWhiteSpace($systemRoot)) { return $false }
    $candidate = ([string]$expanded.Text).Replace('/', '\')
    foreach ($architectureDirectory in @('System32', 'SysWOW64')) {
        $stock = $systemRoot.TrimEnd([char]92, [char]47) + '\' + $architectureDirectory + '\WindowsPowerShell\v1.0\powershell.exe'
        if ([string]::Equals($candidate, $stock, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-BRAVOActionExecutableKind {
    # Exec.Command -> PowerShell | PowerShellUnverified | Cmd | Other (за ім'ям файла, без урахування регістру,
    # у лапках чи без, зі шляхом (%SystemRoot%\...) чи без). Аргументи розбираються як
    # синтаксис PowerShell лише для PowerShell; cmd.exe — обгортка, яку статично не розбираємо.
    # PowerShell — лише штатний Windows PowerShell 5.1 (Test-BRAVOStockWindowsPowerShellPath); powershell(.exe) з
    # іншого каталогу чи з PATH — PowerShellUnverified (який бінарник і як він розбере аргументи — невідомо).
    param([AllowNull()][AllowEmptyString()][string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return 'Other' }
    $text = $Command.Trim().Trim('"').Trim()
    $leaf = ($text -split '[\\/]')[-1].Trim().Trim('"').ToLowerInvariant()
    if ($leaf -eq 'powershell.exe' -or $leaf -eq 'powershell') {
        if (Test-BRAVOStockWindowsPowerShellPath -Command $text) { return 'PowerShell' }
        return 'PowerShellUnverified'
    }
    if ($leaf -eq 'pwsh.exe' -or $leaf -eq 'pwsh') { return 'Pwsh' }
    if ($leaf -eq 'cmd.exe' -or $leaf -eq 'cmd') { return 'Cmd' }
    return 'Other'
}

function Get-BRAVOPowerShellInvocationMode {
    # Перший -File/-Command/-EncodedCommand (будь-яке скорочення) серед токенів
    # аргументів powershell.exe. Mode=$null, коли форму не розпізнано.
    param([AllowNull()][string[]]$Tokens)

    $tokenList = @($Tokens)
    for ($i = 0; $i -lt $tokenList.Count; $i++) {
        if (-not ($tokenList[$i] -match '^[-/]([A-Za-z]+)$')) { continue }
        $name = $Matches[1].ToLowerInvariant()
        if ('file'.StartsWith($name, [StringComparison]::Ordinal)) { return [pscustomobject]@{ Mode = 'File'; Index = $i } }
        if ('command'.StartsWith($name, [StringComparison]::Ordinal)) { return [pscustomobject]@{ Mode = 'Command'; Index = $i } }
        # -ec — окремий alias powershell.exe (не префікс слова EncodedCommand), поруч із префіксами -e, -en, -enc, ...
        if ('encodedcommand'.StartsWith($name, [StringComparison]::Ordinal) -or $name -eq 'ec') { return [pscustomobject]@{ Mode = 'EncodedCommand'; Index = $i } }
    }
    return [pscustomobject]@{ Mode = $null; Index = -1 }
}

function Get-BRAVOPowerShellActionDefinition {
    # Розбір Action.Arguments powershell.exe: режим, ціль -File або текст команди
    # (для -EncodedCommand — ДЕКОДОВАНИЙ), помилки розбору. Нічого не виконується.
    param([AllowNull()][AllowEmptyString()][string]$Arguments)

    # Task Scheduler розкриває %VAR% в Arguments ДО запуску процесу, тож межі токенів
    # визначає розкритий рядок (шлях зі стабільної змінної з пробілом без лапок розривається).
    # Нестабільна змінна (%USERPROFILE% тощо) — межі токенів невідомі: Problem (Unknown).
    # Рішення (fail closed): Task Scheduler розкриває %ім'я% в Arguments незалежно від того, чи powershell.exe потім
    # сприйме текст як код -Command (на кшталт ExpandEnvironmentStrings: визначені імена підставляються, невизначені лишаються
    # дослівно). Тому будь-яка пара '%...%' з непорожнім іменем без '%' (пробіли, у тому числі на краях, та '=' не виключаємо)
    # вважається посиланням; не з підтримуваних стабільних -> Problem (Unknown), у т.ч. пара '%' як псевдонім ForEach-Object
    # усередині -Command. Одинокий '%' без пари посиланням не є.
    $expansion = Expand-BRAVOTaskActionVariable -Text $Arguments -NamePattern '[^%]+'
    $split = ConvertFrom-BRAVOWindowsCommandLine -CommandLine $expansion.Text
    $tokens = @($split.Tokens)
    $definition = [pscustomobject]@{
        Balanced = [bool]$split.Balanced
        Tokens = $tokens
        Mode = $null
        ModeIndex = -1
        FileTarget = $null
        CommandText = $null
        Problem = $null
    }
    if (@($expansion.Unsupported).Count -gt 0) {
        $definition.Problem = 'аргументи залежать від змінної середовища (позиція ' + (@($expansion.UnsupportedPositions) -join ', ') +
            ' у рядку; вираз не виводиться), яку Task Engine бере зі свого (кешованого) середовища: межі токенів статично не визначити'
        return $definition
    }
    if (-not $definition.Balanced) {
        $definition.Problem = 'незбалансовані лапки в аргументах завдання'
        return $definition
    }
    if ([bool]$split.DoubledQuoteInQuote) {
        $definition.Problem = 'подвоєні лапки всередині лапок в аргументах: межі токенів залежать від реалізації розбору argv (CommandLineToArgvW чи CRT), статично не визначити'
        return $definition
    }
    $invocation = Get-BRAVOPowerShellInvocationMode -Tokens $tokens
    $definition.Mode = $invocation.Mode
    $definition.ModeIndex = [int]$invocation.Index
    if ($null -eq $definition.Mode) { return $definition }

    $valueIndex = $definition.ModeIndex + 1
    if ($definition.Mode -eq 'File') {
        if ($valueIndex -lt $tokens.Count) { $definition.FileTarget = [string]$tokens[$valueIndex] }
        else { $definition.Problem = '-File без значення' }
    } elseif ($definition.Mode -eq 'Command') {
        $definition.CommandText = ($tokens | Select-Object -Skip $valueIndex) -join ' '
    } else {
        try {
            if ($valueIndex -ge $tokens.Count) { throw 'немає значення' }
            $definition.CommandText = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String([string]$tokens[$valueIndex]))
        } catch {
            $definition.Problem = "-EncodedCommand не вдалося декодувати (не base64/UTF-16LE)"
        }
    }
    return $definition
}

function Get-BRAVOEvaluatedArgumentText {
    # Значення елемента команди (AST) як статичний текст; $null + Reason, якщо воно
    # обчислюється виразом/змінною.
    param($Expression)

    if ($Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return [pscustomobject]@{ Text = [string]$Expression.Value; Reason = $null }
    }
    if ($Expression -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
        @($Expression.NestedExpressions).Count -eq 0) {
        return [pscustomobject]@{ Text = [string]$Expression.Value; Reason = $null }
    }
    return [pscustomobject]@{ Text = $null; Reason = 'значення обчислюється виразом/змінною — статично не визначити' }
}

function Get-BRAVOConfigPathReferenceFromItem {
    # Прив'язка аргументів виклику BRAVO-скрипта до -ConfigPath за моделлю PowerShell:
    # іменований параметр (точний/скорочений/alias), значення через пробіл чи ':', а
    # потім ПОЗИЦІЙНІ значення за param()-блоком скрипта. Де прив'язку статично не
    # визначити (скрипт недоступний, набори параметрів, динамічне значення) — Unknown
    # (Problem), а не мовчазне «немає -ConfigPath».
    #
    # Modelled — allowlist для NoConfigPath: $true лише коли КОЖЕН токен прив'язано
    # моделлю (відомий param()-блок; кожен параметр розпізнано однозначно; параметри не
    # [switch]-типу мають значення; жодного невідомого/непрозорого токена; кожне позиційне
    # значення має слот). Інакше Modelled=$false з Reason.
    # Items: Kind='Param' (Spelling, HasInline, Text, Reason), Kind='Value' (Text, Reason)
    # або Kind='Opaque' (Reason: токен, який не змодельовано).
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Item,
        [Parameter(Mandatory = $true)]$Declared,
        [Parameter(Mandatory = $true)][string]$Form,
        [AllowNull()][string]$ScriptPath
    )

    $references = New-Object 'System.Collections.Generic.List[object]'
    $state = @{ Modelled = $true; Reason = $null }
    $fail = {
        param($Reason)
        if ($state.Modelled) { $state.Modelled = $false; $state.Reason = $Reason }
    }
    $newReference = {
        param($Spelling, $RawValue, $Problem)
        [pscustomobject]@{ Form = $Form; ScriptPath = $ScriptPath; Spelling = $Spelling; RawValue = $RawValue; Problem = $Problem }
    }
    $canonical = 'ConfigPath'
    $items = @($Item)
    $consumed = New-Object 'System.Collections.Generic.HashSet[int]'
    $boundOwners = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    if (-not [bool]$Declared.Known) { & $fail 'param() скрипта недоступний — аргументи статично не змоделювати' }
    # #496: набори параметрів (ParameterSetName/DefaultParameterSetName) не моделюються: сумісність параметрів різних наборів статично не доводиться.
    if ([bool]$Declared.Known -and [bool]$Declared.HasParameterSets) { & $fail 'скрипт оголошує набори параметрів (ParameterSetName/DefaultParameterSetName): сумісність параметрів і вибір набору не моделюються' }

    # #496 B6: параметр із атрибутами перевірки значення (ValidateSet тощо). Значення, яке PowerShell відхилить, або
    # атрибут, результат якого статично не визначити, -> Modelled=$false (Unknown): інакше скрипт міг би не запуститися
    # взагалі, а дія отримала б визначений клас. Значення в причину не потрапляє (воно може бути секретом).
    $checkValidation = {
        param($Owner, $Value, $HasValue)
        if (-not [bool]$Declared.Known) { return }
        # #496: тип, відмінний від string/object/switch: значення має довести конвертацію ([int]/[long] — інваріантно), інакше Unknown.
        if ($HasValue -and $Declared.TypedOwners.ContainsKey($Owner)) {
            $parsed32 = 0
            $parsed64 = [long]0
            $typeKind = [string]$Declared.TypedOwners[$Owner]
            $converts = (($typeKind -eq 'Int32' -and [int]::TryParse([string]$Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed32)) -or
                ($typeKind -eq 'Int64' -and [long]::TryParse([string]$Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed64)))
            if (-not $converts) { & $fail "значення параметра -$Owner не доведено сумісним із його типом (значення не виводиться): PowerShell може відмовити у прив'язці до запуску скрипта" }
        }
        $rules = @()
        if ($null -ne $Declared.Validation -and $Declared.Validation.ContainsKey($Owner)) { $rules = @($Declared.Validation[$Owner]) }
        if ($rules.Count -eq 0) { return }
        if (-not $HasValue) {
            & $fail "параметр -$Owner має атрибути перевірки значення, а передано лише прапорець — результат статично не визначити"
            return
        }
        $verdict = Test-BRAVOParameterValueValidation -Rule $rules -Value $Value
        if (-not [bool]$verdict.Accepted) { & $fail "параметр -${Owner}: $($verdict.Reason)" }
    }

    for ($i = 0; $i -lt $items.Count; $i++) {
        $current = $items[$i]
        if ($current.Kind -eq 'Opaque') { & $fail ([string]$current.Reason); continue }
        if ($current.Kind -ne 'Param') { continue }
        $resolution = Resolve-BRAVOParameterSpelling -Spelling $current.Spelling -DeclaredParameter $Declared
        if ($resolution.Ambiguous) {
            if (@($resolution.AmbiguousOwners | Where-Object { [string]::Equals($_, $canonical, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
                $references.Add((& $newReference $current.Spelling $null "скорочення -$($current.Spelling) неоднозначне (збігається з ConfigPath та іншим параметром) — PowerShell відмовить у прив'язці"))
            }
            & $fail "скорочення -$($current.Spelling) неоднозначне"
            # Прив'язка однаково не відбудеться: значення належало б цьому параметру, а не позиції.
            if (($i + 1) -lt $items.Count -and $items[$i + 1].Kind -eq 'Value') { [void]$consumed.Add($i + 1) }
            continue
        }
        $owner = $resolution.Owner
        $hasNextValue = (($i + 1) -lt $items.Count -and $items[$i + 1].Kind -eq 'Value')
        if ($null -eq $owner) {
            # Параметр, якого ми не знаємо: чи споживає він наступне значення — невідомо.
            & $fail "параметр (елемент №$($i + 1)) не розпізнано за param() скрипта"
            if ($hasNextValue) {
                $nextText = [string]$items[$i + 1].Text
                if (-not [bool]$Declared.Known -and ($null -eq $items[$i + 1].Text -or $nextText -match '(?i)\.config$')) {
                    $references.Add((& $newReference $current.Spelling $null "параметр (елемент №$($i + 1)) невідомий (param() скрипта недоступний); наступне значення могло б бути -ConfigPath"))
                }
                [void]$consumed.Add($i + 1)
            }
            continue
        }
        # Повторна прив'язка того самого параметра (точно, через alias чи скорочення) — помилка PowerShell до запуску скрипта.
        if (-not $boundOwners.Add($owner)) { & $fail "параметр задано двічі (-$($current.Spelling) вказує на вже прив'язаний $owner)" }
        $isConfig = [string]::Equals($owner, $canonical, [StringComparison]::OrdinalIgnoreCase)
        $isSwitch = (@($Declared.SwitchOwners) -contains $owner)
        $valueItem = $null
        # Наявність inline-значення — структурна (є аргумент після ':'), а не його «істинність»:
        # явне порожнє значення (-ConfigRoot:'') — теж значення і не віддає наступний токен.
        if ([bool]$current.HasInline) {
            $valueItem = $current
        } elseif (-not $isSwitch -and $hasNextValue) {
            $valueItem = $items[$i + 1]
            [void]$consumed.Add($i + 1)
        }
        # #496 B7: Windows PowerShell 5.1 не передає явний Boolean у script switch через -File (`-NoPause:$false`):
        # прив'язка завершується помилкою до запуску скрипта.
        if ($Form -eq 'File' -and $isSwitch -and [bool]$current.HasInline) {
            & $fail "switch-параметр -$($current.Spelling) із inline-значенням у режимі -File: powershell.exe 5.1 не передає явний Boolean у switch скрипта через -File, прив'язка завершиться помилкою"
        }
        if ($isSwitch) {
            & $checkValidation $owner $null $false
        } elseif ($null -ne $valueItem -and $null -eq $valueItem.Reason) {
            & $checkValidation $owner ([string]$valueItem.Text) $true
        }
        if (-not $isConfig) {
            if (-not $isSwitch -and $null -eq $valueItem) { & $fail "параметр -$($current.Spelling) без значення" }
            if ($null -ne $valueItem -and $null -ne $valueItem.Reason) { & $fail "значення параметра -$($current.Spelling) динамічне" }
            continue
        }
        if ($null -eq $valueItem) {
            $references.Add((& $newReference $current.Spelling $null '-ConfigPath без значення'))
        } elseif ($null -ne $valueItem.Reason) {
            $references.Add((& $newReference $current.Spelling $null ([string]$valueItem.Reason)))
        } else {
            $references.Add((& $newReference $current.Spelling ([string]$valueItem.Text) $null))
        }
    }

    # Позиційні значення: ті, що не спожито як значення іменованих параметрів.
    $leftover = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i].Kind -eq 'Value' -and -not $consumed.Contains($i)) { $leftover.Add($items[$i]) }
    }
    if ($leftover.Count -gt 0) {
        if (-not [bool]$Declared.Known) {
            if (-not $boundOwners.Contains($canonical)) {
                $references.Add((& $newReference '<positional>' $null 'позиційний аргумент, а param() скрипта недоступний — невідомо, чи це -ConfigPath'))
            }
        } elseif ([bool]$Declared.PositionalAmbiguous) {
            & $fail 'позиційний аргумент, а позиції параметрів скрипта статично не визначити'
            if (-not $boundOwners.Contains($canonical)) {
                $references.Add((& $newReference '<positional>' $null 'позиційний аргумент, а позиції параметрів скрипта статично не визначити (набори параметрів, змішані Position, ValueFromRemainingArguments)'))
            }
        } else {
            $order = @(@($Declared.PositionalOrder) | Where-Object { -not $boundOwners.Contains([string]$_) })
            if ($leftover.Count -gt $order.Count) { & $fail 'зайвий позиційний аргумент без слота в param() скрипта' }
            for ($k = 0; $k -lt $leftover.Count -and $k -lt $order.Count; $k++) {
                if ($null -eq $leftover[$k].Reason) { & $checkValidation ([string]$order[$k]) ([string]$leftover[$k].Text) $true }
            }
            if (-not $boundOwners.Contains($canonical)) {
                for ($k = 0; $k -lt $leftover.Count -and $k -lt $order.Count; $k++) {
                    if (-not [string]::Equals([string]$order[$k], $canonical, [StringComparison]::OrdinalIgnoreCase)) { continue }
                    if ($null -ne $leftover[$k].Reason) {
                        $references.Add((& $newReference '<positional>' $null ([string]$leftover[$k].Reason)))
                    } else {
                        $references.Add((& $newReference '<positional>' ([string]$leftover[$k].Text) $null))
                    }
                }
            }
            foreach ($leftoverItem in $leftover) {
                if ($null -ne $leftoverItem.Reason) { & $fail 'позиційне значення динамічне' }
            }
        }
    }
    # #496: Mandatory-параметр без прив'язки (ні іменований, ні позиційний) -> PowerShell відмовить до запуску скрипта.
    if ([bool]$Declared.Known) {
        $positionallyBound = @()
        if ($leftover.Count -gt 0 -and -not [bool]$Declared.PositionalAmbiguous) {
            $positionallyBound = @(@($Declared.PositionalOrder) | Where-Object { -not $boundOwners.Contains([string]$_) } | Select-Object -First $leftover.Count)
        }
        foreach ($mandatoryOwner in @($Declared.MandatoryOwners)) {
            if (-not $boundOwners.Contains([string]$mandatoryOwner) -and @($positionallyBound) -notcontains [string]$mandatoryOwner) {
                & $fail "обов'язковий параметр -$mandatoryOwner (Mandatory) не прив'язано: PowerShell відмовить у прив'язці до запуску скрипта"
            }
        }
    }
    return [pscustomobject]@{ References = $references.ToArray(); Modelled = [bool]$state.Modelled; Reason = $state.Reason }
}

function Test-BRAVOPowerShellLeadingOptionsModelled {
    # Єдина модель опцій Windows PowerShell 5.1 ДО -File/-Command/-EncodedCommand. Опція має бути
    # впізнана однозначно за мінімальним префіксом 5.1 (напр. -nop, -nol, -noe, -noni; коротші
    # -no/-non відхиляються), інакше форму статично не змоделювати (Modelled=$false).
    # NoProfile=$true лише коли токен класифіковано саме як прапорець NoProfile, а НЕ як значення
    # опції (напр. `-ExecutionPolicy -nop` споживає -nop як значення, профіль завантажиться).
    # -PSConsoleFile/-ConfigurationName не моделюються (завантажують snap-ін/кінцеву точку).
    param(
        [AllowNull()][string[]]$Tokens,
        [int]$ModeIndex
    )

    $tokenList = @($Tokens)
    # Ім'я -> мінімальна довжина префікса (5.1).
    $flags = @{ nologo = 3; noexit = 3; noprofile = 3; noninteractive = 4; mta = 3; sta = 3 }
    # -Version навмисно НЕ моделюється (значення, прийнятні цільовим powershell.exe, не верифіковано) -> Modelled=$false.
    $withValue = @{ executionpolicy = 2; windowstyle = 2; inputformat = 2; outputformat = 2 }
    # Значення, які powershell.exe 5.1 приймає (перевірено пробами: Bogus/скорочення -InputFormat/-OutputFormat/-WindowStyle
    # відхиляються з кодом -196608, повні імена будь-якого регістру приймаються). Інше значення — Modelled=$false (Unknown):
    # інакше скрипт міг би не запуститися взагалі, а дія отримала б визначену класифікацію.
    $allowedValues = @{
        executionpolicy = @('restricted', 'allsigned', 'remotesigned', 'unrestricted', 'bypass', 'undefined', 'default')
        windowstyle = @('normal', 'minimized', 'maximized', 'hidden')
        inputformat = @('text', 'xml')
        outputformat = @('text', 'xml')
    }
    $noProfile = $false
    for ($i = 0; $i -lt $ModeIndex; $i++) {
        if (-not ($tokenList[$i] -match '^[-/]([A-Za-z]+)$')) { return [pscustomobject]@{ Modelled = $false; NoProfile = $false } }
        $name = $Matches[1].ToLowerInvariant()
        $flagMatches = @($flags.Keys | Where-Object { $name.Length -ge $flags[$_] -and ([string]$_).StartsWith($name, [StringComparison]::Ordinal) })
        $valueMatches = @($withValue.Keys | Where-Object { $name.Length -ge $withValue[$_] -and ([string]$_).StartsWith($name, [StringComparison]::Ordinal) })
        if ($flagMatches.Count + $valueMatches.Count -ne 1) { return [pscustomobject]@{ Modelled = $false; NoProfile = $false } }
        if ($valueMatches.Count -eq 1) {
            $i++
            if ($i -ge $ModeIndex) { return [pscustomobject]@{ Modelled = $false; NoProfile = $false } }
            if (@($allowedValues[[string]$valueMatches[0]]) -notcontains ([string]$tokenList[$i]).ToLowerInvariant()) {
                return [pscustomobject]@{ Modelled = $false; NoProfile = $false }
            }
        } elseif ($flagMatches[0] -eq 'noprofile') {
            $noProfile = $true
        }
    }
    return [pscustomobject]@{ Modelled = $true; NoProfile = $noProfile }
}
function Get-BRAVOTaskActionConfigPathReference {
    # Усі входження -ConfigPath (іменовані й позиційні) у визначенні дії PowerShell +
    # ознака Modelled: дію ПОВНІСТЮ змодельовано (allowlist для NoConfigPath):
    #  (а) -File <BRAVO_*.ps1> — кожен токен прив'язано param()-моделлю;
    #  (б) -Command/-EncodedCommand — рівно один конвеєр з однією командою CommandAst,
    #      ціль якої — літерал BRAVO_*.ps1 (голе слово або & 'літерал'), без перенаправлень,
    #      блоків, змінних, підвиразів, splatting; аргументи змодельовано як у (а).
    # Усе інше, що згадує BRAVO_*.ps1 — Modelled=$false з Reason (Unknown, не PASS).
    # Лише розбір тексту (Parser::ParseInput нічого не виконує).
    param(
        [Parameter(Mandatory = $true)]$Definition,
        [AllowNull()][AllowEmptyString()][string]$WorkingDirectory,
        [AllowNull()][AllowEmptyString()][string]$TrustedRuntimeRoot
    )

    $references = New-Object 'System.Collections.Generic.List[object]'
    $problemReference = {
        param($Form, $ScriptPath, $Problem)
        [pscustomobject]@{ Form = $Form; ScriptPath = $ScriptPath; Spelling = $null; RawValue = $null; Problem = $Problem }
    }
    $noProfile = $false
    $targetScript = $null
    $result = {
        param($Modelled, $Reason)
        [pscustomobject]@{ References = $references.ToArray(); Modelled = [bool]$Modelled; Reason = $Reason; NoProfile = [bool]$noProfile; TargetScript = $targetScript }
    }
    if ($null -ne $Definition.Problem) {
        $references.Add((& $problemReference $(if ($null -ne $Definition.Mode) { [string]$Definition.Mode } else { 'Unparsed' }) $null $Definition.Problem))
        return (& $result $false $Definition.Problem)
    }
    if ($null -eq $Definition.Mode) {
        return (& $result $false 'форму виклику (-File/-Command/-EncodedCommand) не розпізнано')
    }
    $mode = [string]$Definition.Mode
    $tokens = @($Definition.Tokens)
    $options = Test-BRAVOPowerShellLeadingOptionsModelled -Tokens $tokens -ModeIndex ([int]$Definition.ModeIndex)
    $noProfile = [bool]$options.NoProfile
    if (-not [bool]$options.Modelled) {
        return (& $result $false 'невідома опція powershell.exe перед -File/-Command/-EncodedCommand')
    }

    if ($mode -eq 'File') {
        $scriptPath = [string]$Definition.FileTarget
        $targetScript = $scriptPath
        if (-not (Test-BRAVOScriptPathIsBravoEntrypoint -ScriptPath $scriptPath)) {
            return (& $result $false '-File вказує не на BRAVO_*.ps1, а дія згадує BRAVO_*.ps1 в аргументах/каталозі')
        }
        $declared = Get-BRAVOScriptDeclaredParameter -ScriptPath (Resolve-BRAVOTaskActionPath -Path $scriptPath -WorkingDirectory $WorkingDirectory).Path -TrustedRuntimeRoot $TrustedRuntimeRoot
        $items = New-Object 'System.Collections.Generic.List[object]'
        for ($i = $Definition.ModeIndex + 2; $i -lt $tokens.Count; $i++) {
            if ($tokens[$i] -match '^-([A-Za-z][A-Za-z0-9_]*)(:(.*))?$') {
                $hasInline = $tokens[$i].Contains(':')
                if ($hasInline -and [string]$Matches[3] -eq '') {
                    # '-Param:' без значення в тому ж токені: чи візьме PowerShell наступний токен — не змоделювати.
                    $items.Add([pscustomobject]@{ Kind = 'Opaque'; Text = $null; Reason = "токен №$($i + 1) має порожнє inline-значення" })
                    continue
                }
                $items.Add([pscustomobject]@{
                        Kind = 'Param'; Spelling = $Matches[1]; HasInline = $hasInline
                        Text = $(if ($hasInline) { [string]$Matches[3] } else { $null }); Reason = $null
                    })
            } elseif ($tokens[$i].StartsWith('-', [StringComparison]::Ordinal)) {
                $items.Add([pscustomobject]@{ Kind = 'Opaque'; Text = $null; Reason = "токен №$($i + 1) не змодельовано" })
            } else {
                $items.Add([pscustomobject]@{ Kind = 'Value'; Text = [string]$tokens[$i]; Reason = $null })
            }
        }
        $bound = Get-BRAVOConfigPathReferenceFromItem -Item $items.ToArray() -Declared $declared -Form 'File' -ScriptPath $scriptPath
        foreach ($reference in @($bound.References)) { $references.Add($reference) }
        return (& $result $bound.Modelled $bound.Reason)
    }

    # -Command / -EncodedCommand: -EncodedCommand допускає лише одне значення без хвоста.
    if ($mode -eq 'EncodedCommand' -and $tokens.Count -gt ([int]$Definition.ModeIndex + 2)) {
        $references.Add((& $problemReference $mode $null 'після -EncodedCommand є додаткові токени'))
        return (& $result $false 'після -EncodedCommand є додаткові токени')
    }
    # Base64 приховує percent-вирази від Task Scheduler; у декодованому
    # PowerShell-тексті вони літеральні. Не застосовуємо до них повторне
    # розкриття змінних Task Scheduler, зокрема в цілі скрипта й ConfigPath.
    if ($mode -eq 'EncodedCommand' -and [string]$Definition.CommandText -match '%[^%]+%') {
        $problem = 'декодований EncodedCommand містить літеральний percent-вираз; повторне розкриття змінних Task Scheduler неприпустиме'
        $references.Add((& $problemReference $mode $null $problem))
        return (& $result $false $problem)
    }

    $parseTokens = $null
    $parseErrors = $null
    $commandAst = [System.Management.Automation.Language.Parser]::ParseInput([string]$Definition.CommandText, [ref]$parseTokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        $problem = "текст -$mode не розібрано (помилка розбору у позиції $(@($parseErrors)[0].Extent.StartColumnNumber); вміст не виводиться)"
        $references.Add((& $problemReference $mode $null $problem))
        return (& $result $false $problem)
    }

    # Структурний allowlist: рівно один конвеєр з однією командою.
    $structureReason = $null
    $soleCommand = $null
    $endBlock = $commandAst.EndBlock
    if ($null -ne $commandAst.ParamBlock -or $null -ne $commandAst.BeginBlock -or $null -ne $commandAst.ProcessBlock -or
        $null -ne $commandAst.DynamicParamBlock -or $null -eq $endBlock) {
        $structureReason = 'текст команди містить блоки param/begin/process'
    } elseif (($null -ne $endBlock.Traps -and @($endBlock.Traps).Count -gt 0)) {
        $structureReason = 'текст команди містить trap'
    } elseif ($null -ne $commandAst.ScriptRequirements -or ($null -ne $commandAst.UsingStatements -and @($commandAst.UsingStatements).Count -gt 0)) {
        $structureReason = 'текст команди містить #requires/using'
    } elseif (@($endBlock.Statements).Count -ne 1) {
        $structureReason = 'текст команди містить не один оператор (кілька операторів/порожньо)'
    } elseif (@($endBlock.Statements)[0] -isnot [System.Management.Automation.Language.PipelineAst]) {
        $structureReason = 'оператор команди не є простим конвеєром'
    } elseif (@(@($endBlock.Statements)[0].PipelineElements).Count -ne 1) {
        $structureReason = 'конвеєр містить кілька команд'
    } elseif (@(@($endBlock.Statements)[0].PipelineElements)[0] -isnot [System.Management.Automation.Language.CommandAst]) {
        $structureReason = 'елемент конвеєра не є командою'
    } else {
        $candidate = @(@($endBlock.Statements)[0].PipelineElements)[0]
        if (@($candidate.Redirections).Count -gt 0) {
            $structureReason = 'команда має перенаправлення'
        } elseif ($candidate.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot) {
            $structureReason = 'dot-source виклик'
        } elseif (@($candidate.CommandElements).Count -eq 0 -or
            @($candidate.CommandElements)[0] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $structureReason = 'ціль команди не є літералом (змінна/вираз)'
        } elseif (-not (Test-BRAVOScriptPathIsBravoEntrypoint -ScriptPath ([string]@($candidate.CommandElements)[0].Value))) {
            $structureReason = 'ціль команди не BRAVO_*.ps1 (вкладений запуск/лаунчер/інша команда), а текст згадує BRAVO_*.ps1'
        } elseif (([string]@($candidate.CommandElements)[0].Value) -notmatch '[\\/]') {
            # PowerShell не шукає голе ім'я команди в поточному каталозі (лише в PATH/командах сесії):
            # без явного шляху (.\ чи абсолютного) невідомо, що саме буде запущено.
            $structureReason = 'ціль команди — голе ім''я BRAVO_*.ps1 без шляху: PowerShell не шукає його в WorkingDirectory (лише .\ чи абсолютний шлях), тож що саме запуститься — статично не визначити'
        } else {
            $soleCommand = $candidate
            $targetScript = [string]@($candidate.CommandElements)[0].Value
        }
    }

    $dynamicInvokers = @('iex', 'invoke-expression', 'invoke-command', 'icm', 'start-process', 'saps', 'start')
    $mentionsBravo = ([string]$Definition.CommandText -match '(?i)BRAVO_[A-Za-z0-9_]*\.ps1')
    $dynamicInvocation = $false
    $soleBound = $null
    $commands = @($commandAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst]
            }, $true))
    foreach ($command in $commands) {
        $elements = @($command.CommandElements)
        if ($elements.Count -eq 0) { continue }
        $first = $elements[0]
        if ($first -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            # & $variable / & (expr) / & "$x" — ціль виклику статично не визначити.
            $dynamicInvocation = $true
            continue
        }
        $scriptPath = [string]$first.Value
        $simpleName = ($scriptPath -split '[\\/]')[-1].ToLowerInvariant()
        if ($dynamicInvokers -contains $simpleName) { $dynamicInvocation = $true; continue }
        # Лише виклики BRAVO_*.ps1: -ConfigPath інших скриптів у тому ж -Command не належить BRAVO.
        if (-not (Test-BRAVOScriptPathIsBravoEntrypoint -ScriptPath $scriptPath)) { continue }
        # Виклик усередині блоку { ... } або тіла функції може не виконатися (або виконатися інакше):
        # BRAVO-посилання там — Unknown.
        $insideScriptBlock = $false
        for ($ancestor = $command.Parent; $null -ne $ancestor; $ancestor = $ancestor.Parent) {
            if ($ancestor -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
                $ancestor -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $insideScriptBlock = $true; break }
        }
        $declared = Get-BRAVOScriptDeclaredParameter -ScriptPath (Resolve-BRAVOTaskActionPath -Path $scriptPath -WorkingDirectory $WorkingDirectory).Path -TrustedRuntimeRoot $TrustedRuntimeRoot
        $items = New-Object 'System.Collections.Generic.List[object]'
        $splatted = $false
        for ($i = 1; $i -lt $elements.Count; $i++) {
            $element = $elements[$i]
            if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                $inlineText = $null
                $inlineReason = $null
                if ($null -ne $element.Argument) {
                    $evaluated = Get-BRAVOEvaluatedArgumentText -Expression $element.Argument
                    $inlineText = $evaluated.Text
                    $inlineReason = $evaluated.Reason
                }
                $items.Add([pscustomobject]@{
                        Kind = 'Param'; Spelling = [string]$element.ParameterName; HasInline = ($null -ne $element.Argument)
                        Text = $inlineText; Reason = $inlineReason
                    })
                continue
            }
            if ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and $element.Splatted) {
                $splatted = $true
                $items.Add([pscustomobject]@{ Kind = 'Opaque'; Text = $null; Reason = 'splatting (@змінна)' })
                continue
            }
            $evaluated = Get-BRAVOEvaluatedArgumentText -Expression $element
            $items.Add([pscustomobject]@{ Kind = 'Value'; Text = $evaluated.Text; Reason = $evaluated.Reason })
        }
        $bound = Get-BRAVOConfigPathReferenceFromItem -Item $items.ToArray() -Declared $declared -Form $mode -ScriptPath $scriptPath
        if ($command -eq $soleCommand) { $soleBound = $bound }
        $found = @($bound.References)
        if ($splatted) {
            $found += (& $problemReference $mode $scriptPath 'виклик BRAVO-скрипта зі splatting (@змінна) — параметри статично не визначити')
        }
        if ($insideScriptBlock -and $found.Count -gt 0) {
            $references.Add((& $problemReference $mode $scriptPath 'виклик BRAVO-скрипта з -ConfigPath усередині блоку { } або функції — чи виконається він, статично не визначити'))
            continue
        }
        foreach ($reference in $found) { $references.Add($reference) }
    }
    if ($mentionsBravo -and $dynamicInvocation) {
        $references.Add((& $problemReference $mode $null 'текст згадує BRAVO_*.ps1, але ціль виклику динамічна (& $змінна, Invoke-Expression, Start-Process тощо) — статично не визначити'))
    }
    if ($null -ne $structureReason) { return (& $result $false $structureReason) }
    if ($null -eq $soleBound) { return (& $result $false 'виклик BRAVO_*.ps1 не змодельовано') }
    return (& $result $soleBound.Modelled $soleBound.Reason)
}

function Get-BRAVOConfigPathTargetClassification {
    # Класифікація цілі явного -ConfigPath (read-only; файл лише перевіряється на
    # наявність, а ім'я перевіряється на BRAVO.local.config — файл НЕ читається і НЕ
    # виконується):
    #   Missing       — файл не існує;
    #   Local         — BRAVO.local.config. Це НЕ безпечний стан: loader трактує будь-який
    #                   явний -ConfigPath як legacy primary і ВИКОНУЄ файл як скрипт; вивід
    #                   data-only hashtable потрапляє у відповідь читача primary-шару, і
    #                   завантаження конфігурації завершується помилкою прив'язки;
    #   LegacyPrimary — файл, який loader приймає як legacy primary: перевіряється
    #                   переданим валідатором (Test-BravoLegacyConfiguration loader-а);
    #   Unknown       — шлях не розв'язується/не придатний або loader такий файл не прийме.
    param(
        [AllowNull()][AllowEmptyString()][string]$RawPath,
        [AllowNull()][AllowEmptyString()][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][scriptblock]$LegacyConfigurationValidator,
        [AllowNull()][AllowEmptyString()][string]$TrustedRuntimeRoot
    )

    $classify = {
        param($Class, $ResolvedPath, $Reason)
        [pscustomobject]@{ Class = $Class; ResolvedPath = $ResolvedPath; Reason = $Reason }
    }
    if ([string]::IsNullOrWhiteSpace($RawPath)) {
        return (& $classify 'Unknown' $null 'порожнє значення -ConfigPath')
    }
    $resolution = Resolve-BRAVOTaskActionPath -Path $RawPath -WorkingDirectory $WorkingDirectory
    if ($null -eq $resolution.Path) {
        return (& $classify 'Unknown' $null ([string]$resolution.Reason))
    }
    $resolved = [string]$resolution.Path
    # Ціль поза TrustedRuntimeRoot (або будь-яка небезпечна) НЕ відкривається: явний -ConfigPath лишається
    # знахідкою Unknown (WARN, не PASS) — клас не присвоюється, бо без читання файлу його не визначити
    # (LegacyPrimary вимагає перевірки валідатором loader-а, Missing — перевірки наявності).
    $pathSafety = Test-BRAVOTaskLocalPathSafe -Path $resolved -TrustedRoot $TrustedRuntimeRoot
    if (-not $pathSafety.Safe) {
        return (& $classify 'Unknown' $null ([string]$pathSafety.Reason))
    }
    try {
        # Get-Item -ErrorAction Stop: помилка доступу/вводу-виводу кидає виняток (Unknown), а не
        # мовчки дає $false, як Test-Path (інакше файл без права доступу хибно вважався б Missing).
        $item = $null
        try {
            $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
        } catch [System.Management.Automation.DriveNotFoundException] {
            return (& $classify 'Unknown' $resolved "диск/ресурс недоступний, наявність файлу невідома: $($_.Exception.Message)")
        } catch [System.Management.Automation.ItemNotFoundException] {
            if ($resolved.StartsWith('\\', [StringComparison]::Ordinal)) {
                return (& $classify 'Unknown' $resolved 'мережевий (UNC) шлях недосяжний чи відсутній — наявність файлу не підтверджено')
            }
            return (& $classify 'Missing' $resolved 'файл не існує')
        }
        if ($item.PSIsContainer) {
            return (& $classify 'Unknown' $resolved 'шлях вказує на каталог, а не на файл')
        }
        # Повторна перевірка після використання (захист у глибину).
        if (-not (Test-BRAVOTaskLocalPathSafe -Path $resolved -TrustedRoot $TrustedRuntimeRoot).Safe) {
            return (& $classify 'Unknown' $null 'шлях змінився під час перевірки (небезпечний компонент) — результат відкинуто')
        }
    } catch {
        return (& $classify 'Unknown' $resolved "не вдалося перевірити файл: $($_.Exception.Message)")
    }
    if ([string]::Equals([IO.Path]::GetFileName($resolved), 'BRAVO.local.config', [StringComparison]::OrdinalIgnoreCase)) {
        return (& $classify 'Local' $resolved 'BRAVO.local.config')
    }
    try {
        & $LegacyConfigurationValidator $resolved (Split-Path -Path $resolved -Parent)
    } catch {
        return (& $classify 'Unknown' $resolved "loader не приймає цей файл як legacy primary (текст помилки loader-а не виводиться)")
    }
    if (-not (Test-BRAVOTaskLocalPathSafe -Path $resolved -TrustedRoot $TrustedRuntimeRoot).Safe) {
        return (& $classify 'Unknown' $null 'шлях змінився під час перевірки (небезпечний компонент) — результат відкинуто')
    }
    return (& $classify 'LegacyPrimary' $resolved 'BRAVO.config (legacy primary)')
}

function Test-BRAVOArgumentsHaveEncodedCommandToken {
    # #496 B2: у аргументах є токен -EncodedCommand (будь-який префікс powershell.exe 5.1: -e, -ec, -en, -enc, ...).
    # Для обгорток (cmd.exe, %ComSpec%) вміст такого токена не декодується: BRAVO_*.ps1 може ховатися в payload.
    param([AllowNull()][AllowEmptyString()][string]$Arguments)

    foreach ($match in [regex]::Matches([string]$Arguments, '(?<![A-Za-z0-9_])[-/]([A-Za-z]+)(?![A-Za-z0-9_])')) {
        $tokenName = $match.Groups[1].Value.ToLowerInvariant()
        if ('encodedcommand'.StartsWith($tokenName, [StringComparison]::Ordinal) -or $tokenName -eq 'ec') { return $true }
    }
    return $false
}

function Get-BRAVOEntrypointRuntimeDelegation {
    # #496 B3: тонкі кореневі entrypoint-и, які самі НЕ викликають Import-BravoConfiguration, а делегують це доменному
    # runtime-файлу (Invoke-BRAVO<Domain>Entrypoint -> modules\BRAVO.<Domain>\BRAVO.<Domain>.Runtime.ps1). Канонічне
    # правило «production-код викликає loader з -DisallowLegacyPrimaryAutoDetect» і його перелік належать
    # ci\BRAVOConfigV2CutoverGates.ps1 (Get-BRAVOProductionEntryPointRelativePath); модуль не може його імпортувати
    # (сканує все дерево; ci\ не гарантовано поруч), тому тут лише відображення entrypoint -> runtime-файл. Дрейф
    # із канонічним переліком ловить TaskConfigPath/EntrypointDelegationMatchesCutoverGateList у self-test.
    return @{
        'BRAVO_ARCHIV.ps1'       = @{ Command = 'Invoke-BRAVOArchiveEntrypoint'; Runtime = 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1' }
        'BRAVO_MAINTENANCE.ps1'  = @{ Command = 'Invoke-BRAVOMaintenanceEntrypoint'; Runtime = 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1' }
        'BRAVO_HEALTH.ps1'       = @{ Command = 'Invoke-BRAVOHealthEntrypoint'; Runtime = 'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1' }
        'BRAVO_DATA_RESTORE.ps1' = @{ Command = 'Invoke-BRAVODataRestoreEntrypoint'; Runtime = 'modules\BRAVO.DataRestore\BRAVO.DataRestore.Runtime.ps1' }
    }
}

function Test-BRAVOCanonicalRuntimeFile {
    # #496 (рішення власника): позитивний вердикт NoConfigPath дозволений лише для НЕЗМІНЕНОГО канонічного entrypoint-а:
    # SHA-256 кожного файла, на який спирається доказ (цільовий скрипт і, для тонкого entrypoint-а, його доменний
    # runtime-файл), має дорівнювати запису RUNTIME_MANIFEST.json каталогу поточного runtime (TrustedRuntimeRoot).
    # Ключі маніфесту — відносні шляхи з '\'; шлях порівнюється без урахування регістру, хеш — точно. Лише читання,
    # без мережі; відсутній/нечитабельний/пошкоджений маніфест, файл поза маніфестом, розбіжність хешу чи будь-яка
    # помилка вводу-виводу = не канонічний (fail closed). Значення (шляхи, хеші) у причині не виводяться.
    # Маніфест і хеш читаються тут напряму (SHA-256 через .NET, як Get-BRAVORuntimeFileHash у BRAVO_RUNTIME_GUARD.ps1),
    # а не через guard: guard — кореневий pre-trust скрипт, який dot-source-ять entrypoint-и, тож модуль (нижчий шар)
    # не може його підключати; Test-BRAVORuntimeManifestIntegrity перевіряє весь комплект, а тут потрібен вердикт
    # про окремі файли. Єдина канонічна політика цілісності лишається в guard; це її read-only відображення.
    param(
        [AllowNull()][AllowEmptyString()][string]$TrustedRuntimeRoot,
        [string[]]$RelativePath
    )

    $verdict = {
        param($Canonical, $Reason)
        [pscustomobject]@{ Canonical = [bool]$Canonical; Reason = $Reason }
    }
    $unverified = 'не вдалося безпечно прочитати RUNTIME_MANIFEST.json або обчислити хеш файла'
    if ([string]::IsNullOrWhiteSpace($TrustedRuntimeRoot) -or @($RelativePath).Count -eq 0) {
        return (& $verdict $false 'довірений каталог runtime або перелік файлів для перевірки цілісності не передано')
    }
    $sha256 = $null
    try {
        $manifestPath = Join-Path -Path $TrustedRuntimeRoot -ChildPath 'RUNTIME_MANIFEST.json'
        if (-not (Test-BRAVOTaskLocalPathSafe -Path $manifestPath -TrustedRoot $TrustedRuntimeRoot).Safe) { return (& $verdict $false $unverified) }
        if (-not [IO.File]::Exists($manifestPath)) { return (& $verdict $false 'RUNTIME_MANIFEST.json відсутній у каталозі поточного runtime') }
        $parsed = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['files'] -or $null -eq $parsed.files) {
            return (& $verdict $false 'RUNTIME_MANIFEST.json не містить розділу files')
        }
        $expected = @{}
        foreach ($property in $parsed.files.PSObject.Properties) {
            $key = ([string]$property.Name).Replace('/', '\')
            if ($expected.ContainsKey($key)) { return (& $verdict $false 'RUNTIME_MANIFEST.json містить дубльований запис') }
            $expected[$key] = ([string]$property.Value).Trim()
        }
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        foreach ($relative in @($RelativePath)) {
            if (-not $expected.ContainsKey($relative)) {
                return (& $verdict $false 'файл, на який спирається доказ, не перелічений у RUNTIME_MANIFEST.json')
            }
            $fullPath = Join-Path -Path $TrustedRuntimeRoot -ChildPath $relative
            if (-not (Test-BRAVOTaskLocalPathSafe -Path $fullPath -TrustedRoot $TrustedRuntimeRoot).Safe) { return (& $verdict $false $unverified) }
            $stream = [IO.File]::Open($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $actual = ([BitConverter]::ToString($sha256.ComputeHash($stream)) -replace '-', '')
            } finally {
                $stream.Dispose()
            }
            if (-not [string]::Equals($expected[$relative], $actual, [StringComparison]::OrdinalIgnoreCase)) {
                return (& $verdict $false 'вміст файла, на який спирається доказ, не збігається з RUNTIME_MANIFEST.json (файл змінено або не з цього комплекту)')
            }
        }
    } catch {
        return (& $verdict $false $unverified)
    } finally {
        if ($null -ne $sha256) { $sha256.Dispose() }
    }
    return (& $verdict $true $null)
}

function Get-BRAVOScriptLoaderCallEvidence {
    # #496 B3: AST-докази з тексту скрипта (лише розбір, файл не виконується; SEC-001: лише всередині
    # TrustedRuntimeRoot, до і після розбору). Кожен виклик Import-BravoConfiguration класифікується за ТИМ САМИМ
    # правилом, що й канонічний гейт (ci\BRAVOConfigV2CutoverGates.ps1): -DisallowLegacyPrimaryAutoDetect має бути
    # прив'язаний явно й не як :$false / :0; splat без явного прапорця = не доведено. Це захист у глибину:
    # вирішальна умова — збіг хешу з RUNTIME_MANIFEST.json (Test-BRAVOCanonicalRuntimeFile), AST не аналізує досяжність.
    param(
        [AllowNull()][AllowEmptyString()][string]$ScriptPath,
        [AllowNull()][AllowEmptyString()][string]$TrustedRuntimeRoot
    )

    $unreadable = [pscustomobject]@{ Read = $false; LoaderCallCount = 0; UnguardedCallCount = 0; CommandName = @() }
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return $unreadable }
    try {
        if (-not (Test-BRAVOTaskLocalPathSafe -Path $ScriptPath -TrustedRoot $TrustedRuntimeRoot).Safe) { return $unreadable }
        if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { return $unreadable }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
        if ($null -eq $ast -or @($errors).Count -gt 0) { return $unreadable }
        if (-not (Test-BRAVOTaskLocalPathSafe -Path $ScriptPath -TrustedRoot $TrustedRuntimeRoot).Safe) { return $unreadable }

        $loaderCalls = 0
        $unguardedCalls = 0
        $names = New-Object 'System.Collections.Generic.List[string]'
        $commands = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true))
        foreach ($command in $commands) {
            $commandName = [string]$command.GetCommandName()
            if ([string]::IsNullOrEmpty($commandName)) { continue }
            $names.Add($commandName)
            if (-not [string]::Equals($commandName, 'Import-BravoConfiguration', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $loaderCalls++
            $flagBound = $false
            foreach ($element in @($command.CommandElements)) {
                if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
                    [string]::Equals($element.ParameterName, 'DisallowLegacyPrimaryAutoDetect', [StringComparison]::OrdinalIgnoreCase)) {
                    $argumentText = if ($null -ne $element.Argument) { [string]$element.Argument.Extent.Text } else { '' }
                    # Лише ствердне доведення: голий switch або літерал $true (дужки навколо допустимі). Усе інше
                    # (:$false, :($false), :$змінна, :(вираз), :0, :1) — не доведено.
                    $flagBound = $false
                    if ($null -eq $element.Argument) {
                        $flagBound = $true
                    } else {
                        $proofText = $argumentText.Trim()
                        while ($proofText -match '^\((.*)\)$') { $proofText = $Matches[1].Trim() }
                        $flagBound = [string]::Equals($proofText, '$true', [StringComparison]::OrdinalIgnoreCase)
                    }
                }
            }
            if (-not $flagBound) { $unguardedCalls++ }
        }
        return [pscustomobject]@{ Read = $true; LoaderCallCount = $loaderCalls; UnguardedCallCount = $unguardedCalls; CommandName = $names.ToArray() }
    } catch {
        return $unreadable
    }
}

function Test-BRAVOScriptDisallowsLegacyAutoDetect {
    # #496 (рішення власника): NoConfigPath (PASS «legacy BRAVO.config не виконується») лише для НЕЗМІНЕНОГО канонічного
    # entrypoint-а. Умови (усі):
    #  (1) цільовий скрипт (файл у TrustedRuntimeRoot; викликач перевіряє, що його каталог = TrustedRuntimeRoot) має
    #      SHA-256 із RUNTIME_MANIFEST.json цього каталогу — будь-який інший скрипт (змінений, невідомий, поза
    #      маніфестом) не сертифікується, що закриває клас обходів AST-аналізу;
    #  (2) захист у глибину (AST): скрипт сам викликає Import-BravoConfiguration і КОЖЕН виклик прив'язує
    #      -DisallowLegacyPrimaryAutoDetect; або це відомий тонкий entrypoint (Get-BRAVOEntrypointRuntimeDelegation),
    #      що викликає Invoke-BRAVO<Domain>Entrypoint, а його доменний runtime-файл (теж із збігом хешу) викликає
    #      loader так само.
    # Межа: статичний AST не доводить, що виклик досяжний у runtime і що модуль, який імпортує entrypoint, — той самий файл.
    param(
        [AllowNull()][AllowEmptyString()][string]$ScriptPath,
        [AllowNull()][AllowEmptyString()][string]$TrustedRuntimeRoot
    )

    $verdict = {
        param($Proven, $Reason)
        [pscustomobject]@{ Proven = [bool]$Proven; Reason = $Reason }
    }
    $entryName = [IO.Path]::GetFileName($ScriptPath)
    $integrity = Test-BRAVOCanonicalRuntimeFile -TrustedRuntimeRoot $TrustedRuntimeRoot -RelativePath @($entryName)
    if (-not [bool]$integrity.Canonical) {
        return (& $verdict $false ('цільовий скрипт не підтверджено як незмінений канонічний entrypoint комплекту: ' + [string]$integrity.Reason + ' — виклик loader-а з -DisallowLegacyPrimaryAutoDetect не підтверджено'))
    }
    $own = Get-BRAVOScriptLoaderCallEvidence -ScriptPath $ScriptPath -TrustedRuntimeRoot $TrustedRuntimeRoot
    if (-not [bool]$own.Read) {
        return (& $verdict $false 'цільовий скрипт не вдалося безпечно прочитати й розібрати — виклик loader-а з -DisallowLegacyPrimaryAutoDetect не підтверджено')
    }
    if ([int]$own.LoaderCallCount -gt 0) {
        if ([int]$own.UnguardedCallCount -gt 0) {
            return (& $verdict $false 'цільовий скрипт містить виклик Import-BravoConfiguration без -DisallowLegacyPrimaryAutoDetect (відсутній, або значення не є голим switch чи літералом $true: :$false, :($false), :$змінна, :(вираз)) — auto-derived legacy BRAVO.config міг би виконуватися')
        }
        return (& $verdict $true $null)
    }
    $delegation = Get-BRAVOEntrypointRuntimeDelegation
    if (-not $delegation.ContainsKey($entryName)) {
        return (& $verdict $false 'цільовий скрипт не містить виклику Import-BravoConfiguration і не є відомим тонким entrypoint-ом, що делегує завантаження конфігурації доменному runtime — cutover не підтверджено')
    }
    $entry = $delegation[$entryName]
    $callsDomain = @($own.CommandName | Where-Object { [string]::Equals([string]$_, [string]$entry.Command, [StringComparison]::OrdinalIgnoreCase) })
    if ($callsDomain.Count -eq 0) {
        return (& $verdict $false "цільовий скрипт не викликає $($entry.Command) — делегування доменному runtime не підтверджено")
    }
    $runtimeIntegrity = Test-BRAVOCanonicalRuntimeFile -TrustedRuntimeRoot $TrustedRuntimeRoot -RelativePath @([string]$entry.Runtime)
    if (-not [bool]$runtimeIntegrity.Canonical) {
        return (& $verdict $false ('доменний runtime-файл entrypoint-а не підтверджено як незмінений канонічний: ' + [string]$runtimeIntegrity.Reason + ' — cutover не підтверджено'))
    }
    $runtimePath = Join-Path -Path (Split-Path -Path $ScriptPath -Parent) -ChildPath ([string]$entry.Runtime)
    $runtimeEvidence = Get-BRAVOScriptLoaderCallEvidence -ScriptPath $runtimePath -TrustedRuntimeRoot $TrustedRuntimeRoot
    if (-not [bool]$runtimeEvidence.Read) {
        return (& $verdict $false 'доменний runtime-файл entrypoint-а відсутній або його не вдалося безпечно прочитати й розібрати — cutover не підтверджено')
    }
    if ([int]$runtimeEvidence.LoaderCallCount -eq 0 -or [int]$runtimeEvidence.UnguardedCallCount -gt 0) {
        return (& $verdict $false 'доменний runtime-файл entrypoint-а не викликає Import-BravoConfiguration з -DisallowLegacyPrimaryAutoDetect у кожному виклику — cutover не підтверджено')
    }
    return (& $verdict $true $null)
}

function Get-BRAVOTaskConfigPathFinding {
    # Знахідки -ConfigPath для ОДНОГО завдання. Status: NoConfigPath | LegacyPrimary |
    # Local | Missing | Unknown. Завжди повертає масив (0 для не-BRAVO завдання).
    #
    # NoConfigPath (PASS) — ALLOWLIST: лише коли дію розпізнано як повністю змодельовану
    # форму (див. Get-BRAVOTaskActionConfigPathReference: -File <BRAVO_*.ps1> або один
    # CommandAst з літеральною ціллю BRAVO_*.ps1, усі токени прив'язано param()-моделлю).
    # LegacyPrimary/Local/Missing потребують позитивно розв'язаного значення -ConfigPath.
    # Будь-яка інша дія PowerShell/cmd.exe, що згадує BRAVO_*.ps1 в аргументах, декодованому
    # тексті чи WorkingDirectory — Unknown з причиною. Інші виконувані файли — не BRAVO-дії.
    param(
        [AllowNull()][AllowEmptyString()][string]$TaskPath,
        [AllowNull()][AllowEmptyString()][string]$TaskName,
        [AllowNull()][object[]]$Actions,
        [Parameter(Mandatory = $true)][scriptblock]$LegacyConfigurationValidator,
        [AllowNull()][AllowEmptyString()][string]$TrustedRuntimeRoot
    )

    $findings = New-Object 'System.Collections.Generic.List[object]'
    $bravoPattern = '(?i)BRAVO_[A-Za-z0-9_]*\.ps1'
    $actionIndex = 0
    foreach ($action in @($Actions)) {
        $actionIndex++
        if ($null -eq $action) { continue }
        $command = [string]$action.Command
        $arguments = [string]$action.Arguments
        $workingDirectory = [string]$action.WorkingDirectory

        $newFinding = {
            param($Status, $Reference, $Classification, $Detail)
            [pscustomobject]@{
                TaskPath = $TaskPath
                TaskName = $TaskName
                ActionIndex = $actionIndex
                ActionCount = @($Actions).Count
                Status = $Status
                Form = if ($null -ne $Reference) { [string]$Reference.Form } else { $null }
                Spelling = if ($null -ne $Reference) { [string]$Reference.Spelling } else { $null }
                ConfigPathRaw = if ($null -ne $Reference -and $null -ne $Classification -and $Classification.Class -ne 'Unknown') { [string]$Reference.RawValue } else { $null }
                ResolvedPath = if ($null -ne $Classification) { [string]$Classification.ResolvedPath } else { $null }
                Detail = $Detail
            }
        }

        $kind = Get-BRAVOActionExecutableKind -Command $command
        # #496 B2: -EncodedCommand (будь-який префікс) в обгортці: payload не декодується, BRAVO_*.ps1 у ньому не виключено.
        $encodedWrapper = Test-BRAVOArgumentsHaveEncodedCommandToken -Arguments $arguments
        # #496 (P2-1): предикат «аргументи містять %VAR%, яку статично не розкрити» обчислюється ОДИН раз на дію й
        # однаково застосовується до обгорток cmd.exe, Other-дій із %VAR%-командою та powershell.exe (значення не виводиться).
        $unsupportedEnv = (@((Expand-BRAVOTaskActionVariable -Text $arguments -NamePattern '[^%]+').Unsupported).Count -gt 0)
        if ($kind -eq 'Other') {
            # Exec.Command із %VAR% (напр. %ComSpec%) Task Scheduler розкриває у своєму середовищі:
            # що саме запуститься — невідомо. Якщо дія згадує BRAVO_*.ps1 — Unknown, а не мовчазний пропуск.
            if ($command -match '%[^%]+%' -and ($arguments -match $bravoPattern -or $workingDirectory -match $bravoPattern)) {
                $findings.Add((& $newFinding 'Unknown' $null $null 'Exec.Command залежить від змінної середовища (розкривається Task Scheduler у власному середовищі), а аргументи/WorkingDirectory згадують BRAVO_*.ps1 — що саме запуститься, статично не визначити'))
            } elseif ($command -match '%[^%]+%' -and $encodedWrapper) {
                $findings.Add((& $newFinding 'Unknown' $null $null 'Exec.Command залежить від змінної середовища (розкривається Task Scheduler у власному середовищі), а аргументи містять -EncodedCommand (або його скорочення): декодований вміст не розібрано, згадка BRAVO_*.ps1 у ньому не виключена — що саме запуститься, статично не визначити'))
            } elseif ($command -match '%[^%]+%' -and $unsupportedEnv) {
                $findings.Add((& $newFinding 'Unknown' $null $null 'Exec.Command залежить від змінної середовища, а аргументи містять змінну середовища, яку статично не розкрити (значення не виводиться): після розкриття Task Scheduler може запуститися виклик BRAVO_*.ps1 — що саме запуститься, статично не визначити'))
            }
            continue
        }
        if ($kind -eq 'Cmd') {
            if ($arguments -match $bravoPattern -or $workingDirectory -match $bravoPattern) {
                $findings.Add((& $newFinding 'Unknown' $null $null 'обгортка cmd.exe, що згадує BRAVO_*.ps1 — аргументи статично не розібрано'))
            } elseif ($encodedWrapper) {
                $findings.Add((& $newFinding 'Unknown' $null $null 'обгортка cmd.exe з -EncodedCommand (або його скороченням) в аргументах: декодований вміст не розібрано, згадка BRAVO_*.ps1 у ньому не виключена — аргументи статично не розібрано'))
            } elseif ($unsupportedEnv) {
                $findings.Add((& $newFinding 'Unknown' $null $null 'обгортка cmd.exe: аргументи містять змінну середовища, яку статично не розкрити (значення не виводиться): після розкриття у ній може опинитися виклик BRAVO_*.ps1 — аргументи статично не розібрано'))
            }
            continue
        }

        $definition = Get-BRAVOPowerShellActionDefinition -Arguments $arguments
        $mention = ($arguments -match $bravoPattern -or $workingDirectory -match $bravoPattern -or
            ($null -ne $definition.CommandText -and [string]$definition.CommandText -match $bravoPattern))
        if (-not $mention) {
            # #496: нерозкрита змінна середовища + -EncodedCommand (будь-який префікс): payload не декодовано, BRAVO_*.ps1 у ньому не виключено.
            if ($encodedWrapper -and $unsupportedEnv) {
                $findings.Add((& $newFinding 'Unknown' $null $null 'аргументи powershell.exe містять -EncodedCommand (або його скорочення) і змінну середовища, яку статично не розкрити: payload не декодовано, згадка BRAVO_*.ps1 у ньому не виключена — що саме запуститься, статично не визначити'))
            } elseif ($unsupportedEnv) {
                # #496: Task Scheduler розкриває %VAR% до запуску powershell.exe: у -Command/-File може опинитися виклик BRAVO_*.ps1 (значення змінної не виводиться).
                $findings.Add((& $newFinding 'Unknown' $null $null 'аргументи powershell.exe містять змінну середовища, яку статично не розкрити (значення не виводиться): після розкриття Task Scheduler у -Command/-File може опинитися виклик BRAVO_*.ps1 — що саме запуститься, статично не визначити'))
            }
            continue
        }
        if ($kind -eq 'PowerShellUnverified') {
            $findings.Add((& $newFinding 'Unknown' $null $null 'powershell.exe запущено не зі штатного розташування Windows PowerShell 5.1 (%SystemRoot%\System32 або %SystemRoot%\SysWOW64, WindowsPowerShell\v1.0) — голе ім''я (пошук у PATH) чи інший каталог: який бінарник запуститься й як він розбере аргументи, статично не визначити'))
            continue
        }
        if ($kind -eq 'Pwsh') {
            $findings.Add((& $newFinding 'Unknown' $null $null 'pwsh.exe не моделюється (інші правила розбору аргументів і опцій, ніж у Windows PowerShell 5.1) — аргументи статично не розібрано'))
            continue
        }

        $analysis = Get-BRAVOTaskActionConfigPathReference -Definition $definition -WorkingDirectory $workingDirectory -TrustedRuntimeRoot $TrustedRuntimeRoot
        $references = @($analysis.References)
        if ($references.Count -eq 0) {
            if ([bool]$analysis.Modelled) {
                if (-not [bool]$analysis.NoProfile) {
                    $findings.Add((& $newFinding 'Unknown' $null $null 'powershell.exe запущено без -NoProfile: профіль облікового запису завдання може задати ConfigPath через $PSDefaultParameterValues, тож відсутність -ConfigPath (AUTO) не підтверджується'))
                } else {
                    # «legacy BRAVO.config не виконується» гарантує лише runtime із cutover (entrypoint викликає
                    # Import-BravoConfiguration -DisallowLegacyPrimaryAutoDetect; перевіряється ci/BRAVOConfigV2CutoverGates.ps1
                    # для ПОТОЧНОГО комплекту). Ціль в іншій (старішій) інсталяції цієї гарантії не має -> Unknown.
                    $scriptResolution = Resolve-BRAVOTaskActionPath -Path ([string]$analysis.TargetScript) -WorkingDirectory $workingDirectory
                    $trustReason = $null
                    if ([string]::IsNullOrWhiteSpace($TrustedRuntimeRoot)) {
                        $trustReason = 'довірений каталог поточного runtime не передано — cutover цільового скрипта не перевірено'
                    } elseif ($null -eq $scriptResolution.Path) {
                        $trustReason = "шлях цільового скрипта не розв'язано ($($scriptResolution.Reason)) — cutover не перевірено"
                    } else {
                        try {
                            $trustedFull = [IO.Path]::GetFullPath($TrustedRuntimeRoot).TrimEnd([char]92, [char]47)
                            $scriptParent = ([IO.Path]::GetDirectoryName([string]$scriptResolution.Path)).TrimEnd([char]92, [char]47)
                            if (-not [string]::Equals($trustedFull, $scriptParent, [StringComparison]::OrdinalIgnoreCase)) {
                                $trustReason = "ціль '$($scriptResolution.Path)' лежить в іншій інсталяції, ніж поточний runtime '$trustedFull' — cutover (без автозавантаження legacy BRAVO.config) цього runtime не перевірено"
                            } else {
                                # #496: той самий каталог — ще не доказ: застарілий/довільний BRAVO_*.ps1 міг лишитися поруч.
                                # Позитивний вердикт — лише для незміненого канонічного entrypoint-а (хеш = RUNTIME_MANIFEST.json) з доведеним викликом loader-а.
                                $cutover = Test-BRAVOScriptDisallowsLegacyAutoDetect -ScriptPath ([string]$scriptResolution.Path) -TrustedRuntimeRoot $TrustedRuntimeRoot
                                if (-not [bool]$cutover.Proven) { $trustReason = [string]$cutover.Reason }
                            }
                        } catch {
                            $trustReason = "не вдалося порівняти каталог цілі з поточним runtime (шлях не нормалізовано)"
                        }
                    }
                    if ($null -ne $trustReason) {
                        $findings.Add((& $newFinding 'Unknown' $null $null ('-ConfigPath відсутній, але ' + $trustReason)))
                    } else {
                        $findings.Add((& $newFinding 'NoConfigPath' $null $null '-ConfigPath відсутній (AUTO); дію повністю змодельовано'))
                    }
                }
            } else {
                $findings.Add((& $newFinding 'Unknown' $null $null ([string]$analysis.Reason)))
            }
            continue
        }
        foreach ($reference in $references) {
            if ($null -ne $reference.Problem) {
                $findings.Add((& $newFinding 'Unknown' $reference $null ([string]$reference.Problem)))
                continue
            }
            if (-not [bool]$analysis.Modelled) {
                # Позитивні класи (LegacyPrimary/Local/Missing) — лише для повністю змодельованої дії:
                # інакше невідомо, чи цей -ConfigPath взагалі буде прив'язано/виконано.
                $findings.Add((& $newFinding 'Unknown' $reference $null ("знайдено -ConfigPath, але дію не змодельовано повністю ($($analysis.Reason)) — клас не присвоюється; значення не виводиться")))
                continue
            }
            $classification = Get-BRAVOConfigPathTargetClassification -RawPath $reference.RawValue -WorkingDirectory $workingDirectory `
                -LegacyConfigurationValidator $LegacyConfigurationValidator -TrustedRuntimeRoot $TrustedRuntimeRoot
            $findings.Add((& $newFinding ([string]$classification.Class) $reference $classification ([string]$classification.Reason)))
        }
    }
    return $findings.ToArray()
}

function ConvertFrom-BRAVOTaskXmlExecAction {
    # Exec-дії із XML завдання (Task.Xml). Лише читання тексту; DTD заборонено.
    param([AllowNull()][AllowEmptyString()][string]$TaskXml)

    $actions = New-Object 'System.Collections.Generic.List[object]'
    if ([string]::IsNullOrWhiteSpace($TaskXml)) { return $actions.ToArray() }
    $readerSettings = New-Object System.Xml.XmlReaderSettings
    $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $readerSettings.XmlResolver = $null
    $stringReader = New-Object System.IO.StringReader($TaskXml)
    $document = New-Object System.Xml.XmlDocument
    try {
        $reader = [System.Xml.XmlReader]::Create($stringReader, $readerSettings)
        try { $document.Load($reader) } finally { $reader.Dispose() }
    } finally {
        $stringReader.Dispose()
    }
    foreach ($node in @($document.SelectNodes("//*[local-name()='Actions']/*"))) {
        # #496: позиція дії рахується серед УСІХ дій Actions; не-Exec дія займає слот ($null), який сканер пропускає.
        if ($node.LocalName -ne 'Exec') { $actions.Add($null); continue }
        $read = {
            param($ChildName)
            $child = $node.SelectSingleNode("*[local-name()='$ChildName']")
            if ($null -eq $child) { '' } else { [string]$child.InnerText }
        }
        $actions.Add([pscustomobject]@{
                Command = (& $read 'Command')
                Arguments = (& $read 'Arguments')
                WorkingDirectory = (& $read 'WorkingDirectory')
            })
    }
    return $actions.ToArray()
}

function Get-BRAVOLegacyConfigPathTaskReport {
    # Read-only обхід дерева Планувальника (ITaskFolder) від переданої папки: для кожного
    # завдання читається лише Task.Xml; жодне завдання/файл не змінюється. Завдання, чий
    # XML недоступний, потрапляють у Problems.
    # TrustedRuntimeRoot — каталог ПОТОЧНОГО комплекту: лише скрипти з нього можуть дістати
    # NoConfigPath (cutover перевірено CI-gate-ом); цілі деінде або порожній параметр -> Unknown.
    param(
        [Parameter(Mandatory = $true)]$TaskFolder,
        [Parameter(Mandatory = $true)][scriptblock]$LegacyConfigurationValidator,
        [AllowNull()][AllowEmptyString()][string]$TrustedRuntimeRoot
    )

    $findings = New-Object 'System.Collections.Generic.List[object]'
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $scanned = 0
    $pending = New-Object 'System.Collections.Generic.Queue[object]'
    $pending.Enqueue($TaskFolder)
    while ($pending.Count -gt 0) {
        $folder = $pending.Dequeue()
        $tasks = @()
        try {
            $tasks = @($folder.GetTasks(1))
        } catch {
            $problems.Add("папка '$($folder.Path)': не вдалося перелічити завдання: $($_.Exception.Message)")
        }
        foreach ($task in $tasks) {
            $scanned++
            try {
                $taskActions = @(ConvertFrom-BRAVOTaskXmlExecAction -TaskXml ([string]$task.Xml))
                foreach ($finding in @(Get-BRAVOTaskConfigPathFinding -TaskPath ([string]$task.Path) -TaskName ([string]$task.Name) `
                            -Actions $taskActions -LegacyConfigurationValidator $LegacyConfigurationValidator `
                            -TrustedRuntimeRoot $TrustedRuntimeRoot)) {
                    $findings.Add($finding)
                }
            } catch {
                $problems.Add("завдання '$($task.Path)': не вдалося прочитати визначення: $($_.Exception.Message)")
            }
        }
        try {
            foreach ($subFolder in @($folder.GetFolders(0))) { $pending.Enqueue($subFolder) }
        } catch {
            $problems.Add("папка '$($folder.Path)': не вдалося перелічити підпапки: $($_.Exception.Message)")
        }
    }
    return [pscustomobject]@{
        Findings = $findings.ToArray()
        TasksScanned = $scanned
        Problems = $problems.ToArray()
    }
}

function Format-BRAVOConfigPathFindingLine {
    # Рядок звіту у форматі Diagnose ([INFO]/[PASS]/[WARN]). Level -> колір виводить
    # викликач. LegacyPrimary/Local/Missing/Unknown — [WARN] і НЕ змінюють код виходу:
    # це доказ для B5 (#154/#281), а не відмова реєстрації.
    param([Parameter(Mandatory = $true)]$Finding)

    # Завдання з кількома діями: без номера дії знахідки різних дій були б нерозрізнювані.
    # Для однодієвого завдання формат лишається без змін.
    $subject = "$($Finding.TaskPath)"
    if ($Finding.PSObject.Properties['ActionCount'] -and [int]$Finding.ActionCount -gt 1) {
        $subject += " [action $([int]$Finding.ActionIndex)]"
    }
    switch ([string]$Finding.Status) {
        'NoConfigPath' {
            return [pscustomobject]@{ Level = 'PASS'; Text = "[PASS] ${subject}: -ConfigPath відсутній (AUTO) — legacy BRAVO.config не виконується." }
        }
        'LegacyPrimary' {
            return [pscustomobject]@{ Level = 'WARN'; Text = (
                    "[WARN] ${subject}: LegacyPrimary — завдання передає -ConfigPath на legacy BRAVO.config " +
                    "'$($Finding.ResolvedPath)' (форма $($Finding.Form), $(if ($Finding.Spelling -eq '<positional>') { 'позиційний аргумент' } else { "написання -$($Finding.Spelling)" })); loader ВИКОНУЄ цей файл як основний шар. " +
                    "Дія оператора: занесіть завдання до доказів міграції B5 (#154/#281) і не змінюйте його до рішення власника щодо #281; " +
                    "для міграції перенесіть site-відмінності у BRAVO.local.config (deploy\Get-BRAVOConfigSiteDelta.ps1) і перевстановіть завдання без -ConfigPath (BRAVO_TASKS_INSTALL.ps1).") }
        }
        'Local' {
            return [pscustomobject]@{ Level = 'WARN'; Text = (
                    "[WARN] ${subject}: Local — -ConfigPath вказує на BRAVO.local.config '$($Finding.ResolvedPath)'. " +
                    "Це НЕ допустима конфігурація завдання: loader трактує будь-який явний -ConfigPath як legacy primary і ВИКОНУЄ файл як скрипт, " +
                    "тож data-only BRAVO.local.config ламає завантаження конфігурації (запуск завдання завершиться помилкою). " +
                    "Дія оператора: занесіть завдання до доказів B5 (#154/#281) і, за рішенням власника, перевстановіть його без -ConfigPath (BRAVO_TASKS_INSTALL.ps1); " +
                    "BRAVO.local.config поруч із комплектом підхоплюється автоматично.") }
        }
        'Missing' {
            return [pscustomobject]@{ Level = 'WARN'; Text = (
                    "[WARN] ${subject}: Missing — -ConfigPath '$($Finding.ConfigPathRaw)' вказує на файл, якого немає " +
                    "('$($Finding.ResolvedPath)'); явний -ConfigPath вимагає існуючого файлу, тож запуск завдання завершиться помилкою конфігурації. " +
                    "Дія оператора: відновіть файл або перевстановіть завдання без -ConfigPath (BRAVO_TASKS_INSTALL.ps1).") }
        }
        default {
            return [pscustomobject]@{ Level = 'WARN'; Text = (
                    "[WARN] ${subject}: Unknown — ціль -ConfigPath не класифіковано: $($Finding.Detail). " +
                    "Дія оператора: перегляньте Action завдання вручну в Планувальнику й занесіть результат до доказів B5 (#154/#281).") }
        }
    }
}
