[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$TestAccess,
    [switch]$SendTestNotification,
    [switch]$InspectOnly,
    [switch]$NoElevation
)

$helperLoggingPath = Join-Path $PSScriptRoot "modules\BRAVO.HelperLogging\BRAVO.HelperLogging.psd1"
Import-Module -Name $helperLoggingPath -ErrorAction Stop
$null = Start-BRAVOHelperLog -ScriptPath $PSCommandPath -ConfigPath $ConfigPath

$ErrorActionPreference = "Stop"
$scriptRoot = if ($PSCommandPath) {
    Split-Path -Path $PSCommandPath -Parent
} else {
    [Environment]::CurrentDirectory
}
$systemHelpersPath = Join-Path $scriptRoot 'modules\BRAVO.System\BRAVO.System.psd1'
if (-not (Test-Path -LiteralPath $systemHelpersPath -PathType Leaf)) {
    throw "Не знайдено PowerShell-модуль системних helpers: $systemHelpersPath"
}
Import-Module -Name $systemHelpersPath -ErrorAction Stop
# SID-based identity helpers (Test-BRAVOAccountIdentityEquivalent /
# ConvertTo-BRAVOAccountSidValue) — той самий механізм, що й у Installer:
# порівняння облікового запису завдання мовно-незалежно (локалізоване
# "СИСТЕМА" == SYSTEM == S-1-5-18).
$compatibilityHelpersPath = Join-Path $scriptRoot 'modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1'
if (-not (Test-Path -LiteralPath $compatibilityHelpersPath -PathType Leaf)) {
    throw "Не знайдено PowerShell-модуль сумісності: $compatibilityHelpersPath"
}
Import-Module -Name $compatibilityHelpersPath -ErrorAction Stop
# P0 Configuration Foundation (PR C): свідомий намір оператора фіксується
# ТУТ, на межі справжнього виклику скрипта, ДО підстановки auto-дефолту.
$configPathWasExplicit = $PSBoundParameters.ContainsKey('ConfigPath') -and
    -not [string]::IsNullOrWhiteSpace($ConfigPath)
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptRoot "BRAVO.config"
}





function Get-BRAVOTaskResultDescription {
    param([int64]$ResultCode)

    $unsigned = [Convert]::ToUInt32($ResultCode -band 0xffffffffL)
    switch ($unsigned) {
        0 { return "успішно" }
        0x00041300 { return "завдання готове до запуску" }
        0x00041301 { return "завдання зараз виконується" }
        0x00041302 { return "завдання вимкнено" }
        0x00041303 { return "завдання ще не запускалося" }
        0x00041306 { return "останній запуск завершено планувальником" }
        2147942402 { return "не знайдено файл у Action або config" }
        2147942405 { return "відмовлено в доступі" }
        2147942667 { return "некоректний робочий каталог" }
        2147943726 { return "помилка входу облікового запису" }
        2147750671 { return "для завдання не знайдено обліковий запис" }
        2147750687 { return "обмеження безпеки облікового запису" }
        default { return "невідомий код" }
    }
}

function Format-BRAVODiagnoseTaskNextRun {
    param(
        [ValidateSet("Backup", "Maintenance", "Health", "Recovery", "BAZASync", "RestoreVerify", "BackupCatchUp", "ServiceRecovery")]
        [string]$TaskType,
        $TaskSettings,
        $NextRunTime
    )

    $nextRunArguments = @{
        TaskType = $TaskType
        NextRunTime = $NextRunTime
    }
    if ($TaskType -eq "Recovery" -or $TaskType -eq "BackupCatchUp") {
        $nextRunArguments.StartupDelayMinutes = [int]$TaskSettings.StartupDelayMinutes
    }

    return Format-BRAVOSchedulerNextRun @nextRunArguments
}

function Set-BRAVOPrivateDirectoryAcl {
    param([string]$Path)

    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $none = [Security.AccessControl.PropagationFlags]::None
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }
    foreach ($sidText in @("S-1-5-18", "S-1-5-32-544")) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $none,
            $allow
        )))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Test-BRAVOMappedNetworkDrive {
    # Заплановане завдання від NT AUTHORITY\SYSTEM не бачить дискових
    # підключень користувача: буква Z: існує лише в його інтерактивному
    # сеансі. Такий шлях у конфігурації працює під час ручного запуску й
    # мовчки зникає вночі — тому це FAIL, а не інформація.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^([A-Za-z]):[\\/]') {
        return $false
    }
    try {
        $driveInfo = New-Object System.IO.DriveInfo($Matches[1] + ":\")
        return ($driveInfo.DriveType -eq [System.IO.DriveType]::Network)
    } catch {
        return $false
    }
}

function Test-BRAVOScheduledTaskDefinition {
    # Перевірка ФАКТИЧНО зареєстрованого визначення, а не того, що мав би
    # створити інсталятор: завдання могли відредагувати вручну в оснастці,
    # і саме розбіжність між "як встановлювали" і "як зараз" пояснює нічні
    # відмови, яких не видно в жодному лозі.
    param(
        [string]$TaskType,
        $RegisteredTask,
        [hashtable]$TaskSettings,
        [string]$ExpectedConfigPath,
        # P0 Configuration Foundation (PR C, Секція 6): AUTO-встановлені
        # завдання НЕ повинні мати -ConfigPath у аргументах взагалі (див.
        # New-BRAVOTaskDefinition) — тому "правильний" стан для AUTO
        # означає ВІДСУТНІСТЬ токена, а не його наявність із будь-яким
        # значенням. $false тут — дефолт, що відповідає найпоширенішому
        # (AUTO) сценарію; викликач передає $true лише коли оператор
        # свідомо встановлював через -ConfigPath.
        [bool]$ConfigPathWasExplicit,
        [string]$ExpectedExecutable,
        [string[]]$RequiredArgumentTokens,
        [Parameter(Mandatory = $true)][string]$ExpectedAccount,
        [Parameter(Mandatory = $true)][int]$ExpectedLogonType,
        [Parameter(Mandatory = $true)][int]$ExpectedRunLevel,
        # #314: поточні відображувані імена керованих служб для звірки
        # фільтра події 7036 задачі ServiceRecovery; $null — не звіряти.
        [AllowNull()][string[]]$ServiceRecoveryStopEventDisplayNames = $null
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $definition = $RegisteredTask.Definition

    if (-not [bool]$RegisteredTask.Enabled) {
        $problems.Add("завдання вимкнено (Enabled=false)")
    }

    $principal = $definition.Principal
    $userId = [string]$principal.UserId
    # Порівняння за SID, а не за текстом: на локалізованій Windows Task
    # Scheduler повертає локалізовану назву ("СИСТЕМА"), яка мовно-незалежно
    # відповідає SYSTEM/S-1-5-18. Очікуваний акаунт береться з effective
    # schedulerSettings (той самий, який застосував Installer), а не хардкодиться.
    if (-not (Test-BRAVOAccountIdentityEquivalent `
            -ExpectedAccount $ExpectedAccount `
            -ActualAccount $userId)) {
        $expectedSid = ConvertTo-BRAVOAccountSidValue -AccountName $ExpectedAccount
        $actualSid = ConvertTo-BRAVOAccountSidValue -AccountName $userId
        $problems.Add(
            "Principal.UserId='$userId' (SID='$actualSid'), очікується " +
            "'$ExpectedAccount' (SID='$expectedSid')"
        )
    }
    if ([int]$principal.LogonType -ne $ExpectedLogonType) {
        $problems.Add("LogonType=$($principal.LogonType), очікується $ExpectedLogonType")
    }
    if ([int]$principal.RunLevel -ne $ExpectedRunLevel) {
        $problems.Add("RunLevel=$($principal.RunLevel), очікується $ExpectedRunLevel")
    }

    $executionTimeLimit = [string]$definition.Settings.ExecutionTimeLimit
    if ([string]::IsNullOrWhiteSpace($executionTimeLimit) -or $executionTimeLimit -eq "PT0S") {
        $problems.Add("ExecutionTimeLimit не задано")
    }

    $actions = @($definition.Actions)
    if ($actions.Count -eq 0) {
        $problems.Add("у завданні немає жодної дії")
    }
    foreach ($action in $actions) {
        $actionPath = [string]$action.Path
        if (-not (Test-Path -LiteralPath $actionPath -PathType Leaf)) {
            $problems.Add("Action executable не знайдено: $actionPath")
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedExecutable) -and
            -not [string]::Equals(
                [IO.Path]::GetFullPath($actionPath),
                [IO.Path]::GetFullPath($ExpectedExecutable),
                [StringComparison]::OrdinalIgnoreCase)) {
            $problems.Add("Action.Path='$actionPath', у конфігурації '$ExpectedExecutable'")
        }

        $arguments = [string]$action.Arguments
        foreach ($token in @($RequiredArgumentTokens)) {
            if ($arguments -notlike "*$token*") {
                $problems.Add("в аргументах немає '$token'")
            }
        }

        $scriptPath = if (-not [string]::IsNullOrWhiteSpace([string]$TaskSettings.ScriptPath)) {
            [IO.Path]::GetFullPath([string]$TaskSettings.ScriptPath)
        } else {
            $null
        }
        if (-not [string]::IsNullOrWhiteSpace($scriptPath)) {
            if ($arguments -notlike "*-File `"$scriptPath`"*") {
                $problems.Add("-File не вказує на $scriptPath")
            }
            $expectedWorkingDirectory = Split-Path -Path $scriptPath -Parent
            $workingDirectory = [string]$action.WorkingDirectory
            if ([string]::IsNullOrWhiteSpace($workingDirectory)) {
                $problems.Add("WorkingDirectory не задано (очікується $expectedWorkingDirectory)")
            } elseif (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
                $problems.Add("WorkingDirectory не знайдено: $workingDirectory")
            } elseif (-not [string]::Equals(
                    ([IO.Path]::GetFullPath($workingDirectory)).TrimEnd('\'),
                    $expectedWorkingDirectory.TrimEnd('\'),
                    [StringComparison]::OrdinalIgnoreCase)) {
                $problems.Add("WorkingDirectory='$workingDirectory', очікується '$expectedWorkingDirectory'")
            }
        }
        # P0 Configuration Foundation (PR C, Секція 6): AUTO/EXPLICIT
        # семантика симетрична New-BRAVOTaskDefinition — EXPLICIT вимагає
        # ТОЧНИЙ -ConfigPath, AUTO вимагає його ПОВНУ ВІДСУТНІСТЬ (не лише
        # "не перевіряємо"): застаріле завдання, встановлене до цього
        # фіксу (або відредаговане вручну), де AUTO-намір мав би НЕ мати
        # -ConfigPath, але фактично має — це реальна розбіжність "як
        # встановлювали" vs "як зараз", яку Diagnose існує саме для того,
        # щоб виявляти.
        if ($ConfigPathWasExplicit) {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedConfigPath) -and
                $arguments -notlike "*-ConfigPath `"$ExpectedConfigPath`"*") {
                $problems.Add("-ConfigPath не вказує на $ExpectedConfigPath (EXPLICIT-режим)")
            }
        } elseif ($arguments -like "*-ConfigPath *") {
            $problems.Add("AUTO-режим (оператор не передавав -ConfigPath при інсталяції) не повинен мати -ConfigPath у аргументах завдання, але він присутній")
        }
        if (Test-BRAVOMappedNetworkDrive -Path $actionPath) {
            $problems.Add("Action.Path на підключеному мережевому диску: $actionPath — використайте UNC \\server\share\...")
        }
    }

    # RestoreVerify — єдиний weekly-тип: перевіряємо, що фактичний тригер
    # справді щотижневий і день збігається з конфігурацією. Маска — той
    # самий канонічний ConvertTo-BRAVODaysOfWeekMask (BRAVO.System), яким
    # Installer створює тригер: Diagnose не може розійтися з ним у правилах.
    if ($TaskType -eq 'RestoreVerify') {
        $weeklyTriggers = @(@($definition.Triggers) | Where-Object { [int]$_.Type -eq 3 })
        if ($weeklyTriggers.Count -eq 0) {
            $problems.Add("немає жодного weekly-тригера (TASK_TRIGGER_WEEKLY)")
        } else {
            $expectedDaysMask = ConvertTo-BRAVODaysOfWeekMask -DayOfWeek ([string]$TaskSettings.WeeklyOn)
            $actualDaysMask = [int]$weeklyTriggers[0].DaysOfWeek
            if ($actualDaysMask -ne $expectedDaysMask) {
                $problems.Add("DaysOfWeek=$actualDaysMask, очікується $expectedDaysMask ($($TaskSettings.WeeklyOn))")
            }
        }
    }

    # ServiceRecovery (#314 FR-4): наявність і параметри всіх трьох тригерів
    # (подія Service Control Manager, старт ОС, кожні 15 хв) і фіксовані
    # MultipleInstances/StartWhenAvailable/ExecutionTimeLimit — тим самим
    # канонічним описом (BRAVO.System), за яким задачу будує Installer.
    # З -ServiceRecoveryStopEventDisplayNames — ще й фільтр події 7036
    # (штатна зупинка) проти поточних відображуваних імен служб.
    if ($TaskType -eq 'ServiceRecovery') {
        $serviceRecoveryCheckArguments = @{ Definition = $definition }
        if ($null -ne $ServiceRecoveryStopEventDisplayNames) {
            $serviceRecoveryCheckArguments['ExpectedStopEventDisplayNames'] = @($ServiceRecoveryStopEventDisplayNames)
        }
        foreach ($serviceRecoveryProblem in @(Test-BRAVOServiceRecoveryTaskDefinition @serviceRecoveryCheckArguments)) {
            $problems.Add([string]$serviceRecoveryProblem)
        }
    }

    return $problems.ToArray()
}

function Get-BRAVOUsersReadableDataDirectoryFinding {
    # F6: LOGS/TEMP/State не повинні читатися BUILTIN\Users (журнали;
    # BRAVO_WINSCP.lock відкривається продуктом з FileShare.None, тож
    # читання сторонньою особою блокує всі SFTP-операції). Повертає опис
    # знахідки або $null. Лише читання ACL; відсутній каталог — не знахідка.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [System.IO.Directory]::Exists($Path)) {
        return $null
    }
    $broadReaderSids = @{
        'S-1-5-32-545' = 'BUILTIN\Users'
        'S-1-5-11'     = 'Authenticated Users'
        'S-1-1-0'      = 'Everyone'
        'S-1-5-4'      = 'INTERACTIVE'
    }
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    } catch {
        return "не вдалося прочитати ACL: $($_.Exception.Message)"
    }
    $readRights = [int][Security.AccessControl.FileSystemRights]::ReadData
    foreach ($rule in @($acl.Access)) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
            continue
        }
        try {
            $ruleSid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        } catch {
            continue
        }
        # B7 / P3b: Domain Users (S-1-5-21-<домен>-513) теж широка група
        # (узгоджено з Protect-BRAVOMachineStateRoot / BRAVO_SETUP).
        $broadReaderName = $null
        if ($broadReaderSids.ContainsKey($ruleSid)) {
            $broadReaderName = $broadReaderSids[$ruleSid]
        } elseif ($ruleSid -match '^S-1-5-21-\d+-\d+-\d+-513$') {
            $broadReaderName = 'Domain Users'
        }
        if ($null -ne $broadReaderName -and
            (([int]$rule.FileSystemRights -band $readRights) -ne 0)) {
            return (
                "доступний для читання групі $broadReaderName " +
                "($($rule.FileSystemRights)); перевстановіть завдання " +
                "(BRAVO_TASKS_INSTALL.ps1), щоб застосувати захищений ACL"
            )
        }
    }
    return $null
}

function ConvertFrom-BRAVOWindowsCommandLine {
    # Розбір рядка аргументів за правилами CommandLineToArgvW (так powershell.exe
    # отримує Action.Arguments завдання). Лише розбір рядка — нічого не виконується.
    #  - роздільники: ЛИШЕ пробіл і табуляція (U+00A0, CR/LF — не роздільники);
    #  - 2N '' + '"' -> N '' і перемикання лапок; 2N+1 '' + '"' -> N '' і літерал '"';
    #  - усередині лапок `""` -> літерал '"' І вихід з режиму лапок. Це поведінка shell32
    #    CommandLineToArgvW, звірена нативним оракулом (P/Invoke, harness.ps1) на Windows
    #    Server 2022; це НЕ варіант msvcrt після 2008 р., де `""` лишає в режимі лапок;
    #  - поза лапками `""` дає порожній аргумент.
    # Повертає токени й ознаку збалансованості лапок.
    param([AllowNull()][AllowEmptyString()][string]$CommandLine)

    $tokens = New-Object 'System.Collections.Generic.List[string]'
    $length = if ($null -eq $CommandLine) { 0 } else { $CommandLine.Length }
    $builder = New-Object System.Text.StringBuilder
    $inQuote = $false
    $hasToken = $false
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
    }
}

function Resolve-BRAVOTaskActionPath {
    # Шлях з Action (скрипт або значення -ConfigPath) -> повний шлях. Task
    # Scheduler розкриває %VAR% в аргументах; відносний шлях PowerShell
    # розв'язує від WorkingDirectory завдання. Якщо однозначно розв'язати
    # неможливо — $null (викликач класифікує як Unknown).
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$WorkingDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
        if ($expanded.Contains('%') -or $expanded.Contains('$')) { return $null }
        if ([IO.Path]::IsPathRooted($expanded) -and
            $expanded -notmatch '^[A-Za-z]:(?![\\/])' -and
            $expanded -notmatch '^[\\/](?![\\/])') {
            return [IO.Path]::GetFullPath($expanded)
        }
        if ($expanded -match '^[A-Za-z]:' -or $expanded -match '^[\\/]') { return $null }
        if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { return $null }
        $expandedWorkingDirectory = [Environment]::ExpandEnvironmentVariables($WorkingDirectory.Trim().Trim('"'))
        if ($expandedWorkingDirectory.Contains('%') -or -not [IO.Path]::IsPathRooted($expandedWorkingDirectory)) { return $null }
        return [IO.Path]::GetFullPath((Join-Path -Path $expandedWorkingDirectory -ChildPath $expanded))
    } catch {
        return $null
    }
}

function Get-BRAVOScriptDeclaredParameter {
    # Імена параметрів (з alias-ами) скрипта з його param()-блоку — для
    # відтворення прив'язки скорочень (-Config, -ConfigP...) так, як це робить
    # PowerShell. Known=$false, коли скрипт недоступний або не розбирається.
    param([AllowNull()][AllowEmptyString()][string]$ScriptPath)

    $unknown = [pscustomobject]@{ Known = $false; Entries = @() }
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return $unknown }
    try {
        if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { return $unknown }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
        if ($null -eq $ast -or @($errors).Count -gt 0) { return $unknown }

        # Entries: кожне ім'я та alias -> параметр-власник (Owner). Alias-и одного
        # параметра не створюють неоднозначності, а точний збіг імені/alias виграє.
        $entries = New-Object 'System.Collections.Generic.List[object]'
        $addEntry = {
            param($Name, $Owner)
            $entries.Add([pscustomobject]@{ Name = [string]$Name; Owner = [string]$Owner })
        }
        $paramBlock = $ast.ParamBlock
        if ($null -ne $paramBlock) {
            $advanced = $false
            $supportsShouldProcess = $false
            foreach ($attribute in @($paramBlock.Attributes)) {
                if ($attribute.TypeName.Name -ne 'CmdletBinding') { continue }
                $advanced = $true
                foreach ($namedArgument in @($attribute.NamedArguments)) {
                    if ($namedArgument.ArgumentName -eq 'SupportsShouldProcess') { $supportsShouldProcess = $true }
                }
            }
            foreach ($parameter in @($paramBlock.Parameters)) {
                $ownerName = [string]$parameter.Name.VariablePath.UserPath
                & $addEntry $ownerName $ownerName
                foreach ($attribute in @($parameter.Attributes)) {
                    if ($attribute.TypeName.Name -eq 'Parameter') { $advanced = $true }
                    if ($attribute.TypeName.Name -ne 'Alias') { continue }
                    foreach ($aliasArgument in @($attribute.PositionalArguments)) {
                        if ($aliasArgument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                            & $addEntry ([string]$aliasArgument.Value) $ownerName
                        }
                    }
                }
            }
            if ($advanced) {
                foreach ($common in @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
                        'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')) {
                    & $addEntry $common $common
                }
                if ($supportsShouldProcess) {
                    & $addEntry 'WhatIf' 'WhatIf'
                    & $addEntry 'Confirm' 'Confirm'
                }
            }
        }
        return [pscustomobject]@{ Known = $true; Entries = $entries.ToArray() }
    } catch {
        return $unknown
    }
}

function Test-BRAVOParameterSpellingBindsConfigPath {
    # Чи прив'яжеться написання параметра (без дефіса) до -ConfigPath: точний
    # збіг має перевагу; інакше однозначний префікс (як у PowerShell). Двозначний
    # префікс, що охоплює ConfigPath, = помилка прив'язки в PowerShell, тож
    # файл НЕ виконується, але ми повідомляємо про це (Ambiguous).
    # Без відомого param()-блоку скрипта працює лише евристика за іменем:
    # префікс ConfigPath довжиною від 4 символів (Evidence='NameOnly').
    param(
        [AllowNull()][AllowEmptyString()][string]$Spelling,
        [Parameter(Mandatory = $true)]$DeclaredParameter
    )

    $result = [pscustomobject]@{ Binds = $false; Ambiguous = $false; Evidence = 'ScriptParam' }
    if ([string]::IsNullOrEmpty($Spelling)) { return $result }
    $canonical = 'ConfigPath'

    if (-not [bool]$DeclaredParameter.Known) {
        $result.Evidence = 'NameOnly'
        $result.Binds = ($Spelling.Length -ge 4 -and
            $canonical.StartsWith($Spelling, [StringComparison]::OrdinalIgnoreCase))
        return $result
    }

    $entries = @($DeclaredParameter.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
    $exact = @($entries | Where-Object { [string]::Equals($_.Name, $Spelling, [StringComparison]::OrdinalIgnoreCase) })
    if ($exact.Count -gt 0) {
        $result.Binds = [bool](@($exact | Where-Object { [string]::Equals($_.Owner, $canonical, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
        return $result
    }
    # Префікс прив'язується, лише якщо ВСІ кандидати належать одному параметру.
    $prefixOwners = @($entries | Where-Object { $_.Name.StartsWith($Spelling, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { $_.Owner.ToLowerInvariant() } | Select-Object -Unique)
    if ($prefixOwners.Count -eq 1) {
        $result.Binds = [string]::Equals($prefixOwners[0], $canonical, [StringComparison]::OrdinalIgnoreCase)
    } elseif ($prefixOwners.Count -gt 1) {
        $result.Ambiguous = [bool]($prefixOwners -contains $canonical.ToLowerInvariant())
    }
    return $result
}

function Test-BRAVOScriptPathIsBravoEntrypoint {
    # Ціль виклику — BRAVO_*.ps1 (за ім'ям файла в шляху). Єдине правило для -File і -Command.
    param([AllowNull()][AllowEmptyString()][string]$ScriptPath)

    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return $false }
    return [bool]($ScriptPath -match '(?i)(^|[\\/])BRAVO_[A-Za-z0-9_]*\.ps1$')
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
        if ('encodedcommand'.StartsWith($name, [StringComparison]::Ordinal)) { return [pscustomobject]@{ Mode = 'EncodedCommand'; Index = $i } }
    }
    return [pscustomobject]@{ Mode = $null; Index = -1 }
}

function Get-BRAVOTaskActionConfigPathReference {
    # Розбирає Action.Arguments powershell.exe і повертає ВСІ входження -ConfigPath
    # (будь-яке прийнятне написання/скорочення; -File та -Command/-EncodedCommand;
    # лапки/без). Кожен елемент: Form, ScriptPath, Spelling, RawValue, Problem
    # (Problem != $null -> значення не вдалося визначити). Лише розбір тексту
    # (Parser::ParseInput нічого не виконує). Порожній результат = -ConfigPath
    # немає або форма аргументів не розпізнана (див. Get-BRAVOTaskConfigPathFinding).
    param(
        [AllowNull()][AllowEmptyString()][string]$Arguments,
        [AllowNull()][AllowEmptyString()][string]$WorkingDirectory
    )

    $references = New-Object 'System.Collections.Generic.List[object]'
    $newReference = {
        param($Form, $ScriptPath, $Spelling, $RawValue, $Problem)
        [pscustomobject]@{
            Form = $Form
            ScriptPath = $ScriptPath
            Spelling = $Spelling
            RawValue = $RawValue
            Problem = $Problem
        }
    }

    $split = ConvertFrom-BRAVOWindowsCommandLine -CommandLine $Arguments
    $tokens = @($split.Tokens)
    if (-not [bool]$split.Balanced) {
        $references.Add((& $newReference 'Unparsed' $null $null $null 'незбалансовані лапки в аргументах завдання'))
        return $references.ToArray()
    }

    $invocation = Get-BRAVOPowerShellInvocationMode -Tokens $tokens
    $mode = $invocation.Mode
    $modeIndex = [int]$invocation.Index
    if ($null -eq $mode) { return $references.ToArray() }

    if ($mode -eq 'File') {
        if ($modeIndex + 1 -ge $tokens.Count) {
            $references.Add((& $newReference 'File' $null $null $null '-File без значення'))
            return $references.ToArray()
        }
        $scriptPath = $tokens[$modeIndex + 1]
        $declared = Get-BRAVOScriptDeclaredParameter -ScriptPath (Resolve-BRAVOTaskActionPath -Path $scriptPath -WorkingDirectory $WorkingDirectory)
        for ($i = $modeIndex + 2; $i -lt $tokens.Count; $i++) {
            if (-not ($tokens[$i] -match '^-([A-Za-z][A-Za-z0-9_]*)(:(.*))?$')) { continue }
            $spelling = $Matches[1]
            $hasInline = $tokens[$i].Contains(':')
            $inlineValue = if ($hasInline) { [string]$Matches[3] } else { $null }
            $binding = Test-BRAVOParameterSpellingBindsConfigPath -Spelling $spelling -DeclaredParameter $declared
            if ($binding.Ambiguous) {
                $references.Add((& $newReference 'File' $scriptPath $spelling $null "скорочення -$spelling неоднозначне (збігається з ConfigPath та іншим параметром) — PowerShell відмовить у прив'язці"))
                continue
            }
            if (-not $binding.Binds) { continue }
            if ($hasInline -and -not [string]::IsNullOrEmpty($inlineValue)) {
                $references.Add((& $newReference 'File' $scriptPath $spelling $inlineValue $null))
            } elseif ($i + 1 -lt $tokens.Count -and $tokens[$i + 1] -notmatch '^-[A-Za-z]') {
                $references.Add((& $newReference 'File' $scriptPath $spelling $tokens[$i + 1] $null))
                $i++
            } else {
                $references.Add((& $newReference 'File' $scriptPath $spelling $null '-ConfigPath без значення'))
            }
        }
        return $references.ToArray()
    }

    # -Command / -EncodedCommand: текст команди розбираємо парсером PowerShell.
    $commandText = $null
    if ($mode -eq 'Command') {
        $commandText = ($tokens | Select-Object -Skip ($modeIndex + 1)) -join ' '
    } else {
        try {
            if ($modeIndex + 1 -ge $tokens.Count) { throw 'немає значення' }
            $commandText = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($tokens[$modeIndex + 1]))
        } catch {
            $references.Add((& $newReference 'EncodedCommand' $null $null $null "-EncodedCommand не вдалося декодувати: $($_.Exception.Message)"))
            return $references.ToArray()
        }
    }
    $parseTokens = $null
    $parseErrors = $null
    $commandAst = [System.Management.Automation.Language.Parser]::ParseInput([string]$commandText, [ref]$parseTokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        $references.Add((& $newReference $mode $null $null $null "текст -$mode не розібрано: $(@($parseErrors)[0].Message)"))
        return $references.ToArray()
    }
    $commands = @($commandAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst]
            }, $true))
    foreach ($command in $commands) {
        $elements = @($command.CommandElements)
        if ($elements.Count -eq 0) { continue }
        $first = $elements[0]
        if ($first -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
        $scriptPath = [string]$first.Value
        # Лише виклики BRAVO_*.ps1: -ConfigPath інших скриптів у тому ж -Command
        # не належить BRAVO.
        if (-not (Test-BRAVOScriptPathIsBravoEntrypoint -ScriptPath $scriptPath)) { continue }
        # Виклик усередині блоку { ... } або тіла функції може не виконатися (або виконатися інакше):
        # BRAVO-посилання там — Unknown.
        $insideScriptBlock = $false
        for ($ancestor = $command.Parent; $null -ne $ancestor; $ancestor = $ancestor.Parent) {
            if ($ancestor -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
                $ancestor -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $insideScriptBlock = $true; break }
        }
        $declared = Get-BRAVOScriptDeclaredParameter -ScriptPath (Resolve-BRAVOTaskActionPath -Path $scriptPath -WorkingDirectory $WorkingDirectory)
        for ($i = 1; $i -lt $elements.Count; $i++) {
            $element = $elements[$i]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $spelling = [string]$element.ParameterName
            $binding = Test-BRAVOParameterSpellingBindsConfigPath -Spelling $spelling -DeclaredParameter $declared
            if ($binding.Ambiguous) {
                $references.Add((& $newReference $mode $scriptPath $spelling $null "скорочення -$spelling неоднозначне (збігається з ConfigPath та іншим параметром) — PowerShell відмовить у прив'язці"))
                continue
            }
            if (-not $binding.Binds) { continue }
            if ($insideScriptBlock) {
                $references.Add((& $newReference $mode $scriptPath $spelling $null 'виклик BRAVO-скрипта з -ConfigPath усередині блоку { } — чи виконається він, статично не визначити'))
                continue
            }
            $valueExpression = $null
            if ($null -ne $element.Argument) {
                $valueExpression = $element.Argument
            } elseif ($i + 1 -lt $elements.Count -and
                $elements[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                $valueExpression = $elements[$i + 1]
                $i++
            }
            if ($null -eq $valueExpression) {
                $references.Add((& $newReference $mode $scriptPath $spelling $null '-ConfigPath без значення'))
            } elseif ($valueExpression -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $references.Add((& $newReference $mode $scriptPath $spelling ([string]$valueExpression.Value) $null))
            } elseif ($valueExpression -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
                @($valueExpression.NestedExpressions).Count -eq 0) {
                $references.Add((& $newReference $mode $scriptPath $spelling ([string]$valueExpression.Value) $null))
            } else {
                $references.Add((& $newReference $mode $scriptPath $spelling $null 'значення -ConfigPath обчислюється виразом/змінною — статично не визначити'))
            }
        }
    }
    return $references.ToArray()
}

function Get-BRAVOConfigPathTargetClassification {
    # Класифікація цілі явного -ConfigPath (read-only; файл лише перевіряється
    # на наявність і, якщо це .config, його ім'я/розширення — файл НЕ читається
    # і НЕ виконується):
    #   Missing       — файл не існує;
    #   Local         — BRAVO.local.config (той самий ім'я, що в
    #                   Read-BRAVOLocalConfigurationOverrides);
    #   LegacyPrimary — файл, який loader прийме як legacy primary:
    #                   Test-BravoLegacyConfiguration (BRAVO_CONFIG_LOADER.ps1)
    #                   — каноничне правило loader-а, а не власна евристика;
    #   Unknown       — шлях не розв'язується/не придатний або loader такий
    #                   файл не прийме (напр. інше розширення).
    param(
        [AllowNull()][AllowEmptyString()][string]$RawPath,
        [AllowNull()][AllowEmptyString()][string]$WorkingDirectory
    )

    $classify = {
        param($Class, $ResolvedPath, $Reason)
        [pscustomobject]@{ Class = $Class; ResolvedPath = $ResolvedPath; Reason = $Reason }
    }
    if ([string]::IsNullOrWhiteSpace($RawPath)) {
        return (& $classify 'Unknown' $null 'порожнє значення -ConfigPath')
    }
    $resolved = Resolve-BRAVOTaskActionPath -Path $RawPath -WorkingDirectory $WorkingDirectory
    if ($null -eq $resolved) {
        return (& $classify 'Unknown' $null 'шлях не розв''язується однозначно (змінна середовища, відносний шлях без WorkingDirectory або некоректний шлях)')
    }
    try {
        if (Test-Path -LiteralPath $resolved -PathType Container) {
            return (& $classify 'Unknown' $resolved 'шлях вказує на каталог, а не на файл')
        }
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            return (& $classify 'Missing' $resolved 'файл не існує')
        }
    } catch {
        return (& $classify 'Unknown' $resolved "не вдалося перевірити файл: $($_.Exception.Message)")
    }
    if ([string]::Equals([IO.Path]::GetFileName($resolved), 'BRAVO.local.config', [StringComparison]::OrdinalIgnoreCase)) {
        return (& $classify 'Local' $resolved 'BRAVO.local.config')
    }
    try {
        Test-BravoLegacyConfiguration -ConfigPath $resolved -ConfigRoot (Split-Path -Path $resolved -Parent)
    } catch {
        return (& $classify 'Unknown' $resolved "loader не приймає цей файл як legacy primary: $($_.Exception.Message)")
    }
    return (& $classify 'LegacyPrimary' $resolved 'BRAVO.config (legacy primary)')
}

function Get-BRAVOTaskConfigPathFinding {
    # Знахідки -ConfigPath для ОДНОГО завдання. Враховуються лише Exec-дії, що
    # посилаються на BRAVO_*.ps1. Status: NoConfigPath | LegacyPrimary | Local |
    # Missing | Unknown. Завжди повертає масив (0 для не-BRAVO завдання).
    param(
        [AllowNull()][AllowEmptyString()][string]$TaskPath,
        [AllowNull()][AllowEmptyString()][string]$TaskName,
        [AllowNull()][object[]]$Actions
    )

    $findings = New-Object 'System.Collections.Generic.List[object]'
    $actionIndex = 0
    foreach ($action in @($Actions)) {
        $actionIndex++
        if ($null -eq $action) { continue }
        $command = [string]$action.Command
        $arguments = [string]$action.Arguments
        $workingDirectory = [string]$action.WorkingDirectory
        $bravoScriptPattern = '(?i)BRAVO_[A-Za-z0-9_]*\.ps1'
        $rawRelevant = (("$command $arguments") -match $bravoScriptPattern)
        # -File: релевантна дія лише тоді, коли САМ скрипт-ціль (токен після -File) —
        # BRAVO_*.ps1; згадка BRAVO_*.ps1 в іншому аргументі (напр. -Label) не рахується.
        $fileSplit = ConvertFrom-BRAVOWindowsCommandLine -CommandLine $arguments
        if ([bool]$fileSplit.Balanced) {
            $fileInvocation = Get-BRAVOPowerShellInvocationMode -Tokens @($fileSplit.Tokens)
            if ($fileInvocation.Mode -eq 'File' -and ([int]$fileInvocation.Index + 1) -lt @($fileSplit.Tokens).Count) {
                if (-not (Test-BRAVOScriptPathIsBravoEntrypoint -ScriptPath ([string]@($fileSplit.Tokens)[[int]$fileInvocation.Index + 1]))) { continue }
                $rawRelevant = $true
            }
        }
        # -EncodedCommand ховає ім'я скрипта в base64: такі дії розбираємо теж і
        # вважаємо BRAVO-завданням лише якщо декодований текст посилається на BRAVO_*.ps1.
        if (-not $rawRelevant -and $arguments -notmatch '(?i)(^|\s)[-/]e[a-z]*(\s|$)') { continue }

        $newFinding = {
            param($Status, $Reference, $Classification, $Detail)
            [pscustomobject]@{
                TaskPath = $TaskPath
                TaskName = $TaskName
                ActionIndex = $actionIndex
                Status = $Status
                Form = if ($null -ne $Reference) { [string]$Reference.Form } else { $null }
                Spelling = if ($null -ne $Reference) { [string]$Reference.Spelling } else { $null }
                ConfigPathRaw = if ($null -ne $Reference) { [string]$Reference.RawValue } else { $null }
                ResolvedPath = if ($null -ne $Classification) { [string]$Classification.ResolvedPath } else { $null }
                Detail = $Detail
            }
        }

        $references = @(Get-BRAVOTaskActionConfigPathReference -Arguments $arguments -WorkingDirectory $workingDirectory)
        if (-not $rawRelevant -and
            @($references | Where-Object { $null -ne $_.ScriptPath -and ([string]$_.ScriptPath) -match $bravoScriptPattern }).Count -eq 0) {
            continue
        }
        if ($references.Count -eq 0) {
            # Fallback лише коли форму виклику не розпізнано (немає -File/-Command/-EncodedCommand);
            # розібране -File/-Command без -ConfigPath — це NoConfigPath.
            $formRecognized = ($arguments -match '(?i)(^|\s)[-/](f|fi|fil|file|c|co|com|comm|comma|comman|command|e[a-z]*)(\s|$)')
            if (-not $formRecognized -and $arguments -match '(?i)config\s*path|[-/]conf') {
                $findings.Add((& $newFinding 'Unknown' $null $null 'аргументи згадують config, але форму виклику (-File/-Command) не розпізнано'))
            } else {
                $findings.Add((& $newFinding 'NoConfigPath' $null $null '-ConfigPath відсутній (AUTO)'))
            }
            continue
        }
        foreach ($reference in $references) {
            if ($null -ne $reference.Problem) {
                $findings.Add((& $newFinding 'Unknown' $reference $null ([string]$reference.Problem)))
                continue
            }
            $classification = Get-BRAVOConfigPathTargetClassification -RawPath $reference.RawValue -WorkingDirectory $workingDirectory
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
    foreach ($node in @($document.SelectNodes("//*[local-name()='Actions']/*[local-name()='Exec']"))) {
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
    # Read-only обхід дерева Планувальника (ITaskFolder) від переданої папки:
    # для кожного завдання читається лише Task.Xml; жодне завдання/файл не
    # змінюється. Завдання, чий XML недоступний, лише рахуються (Unreadable).
    param([Parameter(Mandatory = $true)]$TaskFolder)

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
                foreach ($finding in @(Get-BRAVOTaskConfigPathFinding -TaskPath ([string]$task.Path) -TaskName ([string]$task.Name) -Actions $taskActions)) {
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
    # Рядок звіту у форматі Diagnose ([INFO]/[PASS]/[WARN]). Level -> колір
    # виводить викликач. LegacyPrimary/Missing/Unknown — [WARN] і НЕ змінюють
    # код виходу: це доказ для B5 (#154/#281), а не відмова реєстрації.
    param([Parameter(Mandatory = $true)]$Finding)

    $subject = "$($Finding.TaskPath)"
    switch ([string]$Finding.Status) {
        'NoConfigPath' {
            return [pscustomobject]@{ Level = 'PASS'; Text = "[PASS] ${subject}: -ConfigPath відсутній (AUTO) — legacy BRAVO.config не виконується." }
        }
        'LegacyPrimary' {
            return [pscustomobject]@{ Level = 'WARN'; Text = (
                    "[WARN] ${subject}: LegacyPrimary — завдання передає -ConfigPath на legacy BRAVO.config " +
                    "'$($Finding.ResolvedPath)' (форма $($Finding.Form), написання -$($Finding.Spelling)); loader ВИКОНУЄ цей файл як основний шар. " +
                    "Дія оператора: занесіть завдання до доказів міграції B5 (#154/#281) і не змінюйте його до рішення власника щодо #281; " +
                    "для міграції перенесіть site-відмінності у BRAVO.local.config (deploy\Get-BRAVOConfigSiteDelta.ps1) і перевстановіть завдання без -ConfigPath (BRAVO_TASKS_INSTALL.ps1).") }
        }
        'Local' {
            return [pscustomobject]@{ Level = 'INFO'; Text = (
                    "[INFO] ${subject}: Local — -ConfigPath вказує на BRAVO.local.config '$($Finding.ResolvedPath)' " +
                    "(не legacy primary; сам -ConfigPath у завданні не потрібен для AUTO-режиму).") }
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

function Get-BRAVOTaskFolder {
    param($Service, [string]$TaskPath)
    $comPath = if ($TaskPath -eq "\") { "\" } else { $TaskPath.TrimEnd("\") }
    try {
        return $Service.GetFolder($comPath)
    } catch {
        return $null
    }
}

try {
    # P0 Configuration Foundation: BRAVO.config став опційним основним
    # override-шаром — попередня жорстка "файл мусить існувати" перевірка
    # (і Resolve-Path, який теж вимагав існування) дублювала те саме
    # рішення, яке Import-BravoConfiguration тепер приймає коректно сама.
    # GetFullPath (а не Resolve-Path) нормалізує шлях без вимоги існування.
    $resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $configRoot = Split-Path -Path $resolvedConfigPath -Parent
    $configurationLoaderPath = Join-Path $scriptRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    # Issue #216 (Wave B): production operator entrypoint — не виконує
    # BRAVO.config автоматично лише тому, що він опинився поруч на диску;
    # див. коментар біля $DisallowLegacyPrimaryAutoDetect у
    # BRAVO_CONFIG_LOADER.ps1.
    Import-BravoConfiguration `
        -ConfigRoot $configRoot `
        -ConfigPath $resolvedConfigPath `
        -RuntimeRoot $scriptRoot `
        -DisallowLegacyPrimaryAutoDetect `
        -ConfigPathWasExplicit:$configPathWasExplicit

    if (-not $InspectOnly -and
        (ConvertTo-BRAVOAccountSidValue -AccountName ([string]$schedulerSettings.RunAsUser)) -eq 'S-1-5-18') {
        # Перевіряється розташування КОМПЛЕКТУ, а не каталогу конфігурації:
        # саме комплект виконується від SYSTEM, і саме він має лежати в
        # захищеному каталозі. Конфігурація може лежати де завгодно.
        $profileRoot = [IO.Path]::GetFullPath(
            [Environment]::GetFolderPath("UserProfile")
        ).TrimEnd("\") + "\"
        if (($scriptRoot.TrimEnd("\") + "\").StartsWith(
                $profileRoot,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw (
                "SYSTEM dry-run не запускається з профілю користувача: $scriptRoot. " +
                "Заплановані завдання виконуються від NT AUTHORITY\SYSTEM, а каталог " +
                "профілю не є для нього захищеним розташуванням. Перенесіть комплект " +
                "у локальний захищений каталог — наприклад C:\Program Files\BRAVO-Toolkit, C:\ProgramData\BRAVO " +
                "або D:\BRAVO_RUNTIME (ACL: SYSTEM/Administrators — FullControl, " +
                "Users — ReadAndExecute). Корені даних (LIMSRoot/SystemLogRoot/BackupRoot) " +
                "переносити не потрібно: вони задаються в BRAVO.config незалежно."
            )
        }
    }

    if (-not $InspectOnly -and -not (Test-IsAdministrator)) {
        if ($NoElevation) {
            throw "для SYSTEM dry-run потрібні права адміністратора"
        }
        $arguments = @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            (ConvertTo-BRAVOProcessArgument $PSCommandPath)
        )
        # P0 Configuration Foundation (PR C, Секція 6): зберігаємо той
        # самий AUTO/EXPLICIT намір при власному UAC relaunch Diagnose-а.
        if ($configPathWasExplicit) {
            $arguments += "-ConfigPath"
            $arguments += (ConvertTo-BRAVOProcessArgument $resolvedConfigPath)
        }
        if ($TestAccess) { $arguments += "-TestAccess" }
        if ($SendTestNotification) { $arguments += "-SendTestNotification" }
        $process = Start-Process `
            -FilePath (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -ArgumentList $arguments `
            -Verb RunAs `
            -Wait `
            -PassThru `
            -WindowStyle Normal
        Complete-BRAVOHelperLog -ExitCode $process.ExitCode
    }

    if ($null -eq $schedulerSettings) {
        throw "у config відсутній schedulerSettings"
    }
    # Dry Run — runtime-ресурс комплекту, тому береться з RuntimeRoot ($scriptRoot),
    # а не з каталогу конфігурації (config може бути переданий через -ConfigPath
    # з іншого місця).
    $dryRunPath = Join-Path $scriptRoot "BRAVO_DRY_RUN.ps1"
    if (-not (Test-Path -LiteralPath $dryRunPath -PathType Leaf)) {
        throw "dry-run не знайдено: $dryRunPath"
    }

    $taskService = New-Object -ComObject "Schedule.Service"
    $taskService.Connect()
    $taskFolder = Get-BRAVOTaskFolder `
        -Service $taskService `
        -TaskPath ([string]$schedulerSettings.TaskPath)

    Write-Host ""
    Write-Host "=== КОРЕНІ ШЛЯХІВ ===" -ForegroundColor Cyan
    $pathRootsFailed = $false
    $diagnosticRoots = [ordered]@{
        'RuntimeRoot'      = $scriptRoot
        'RuntimeLogRoot'   = [string]$global:runtimeLogRoot
        'ConfigPath'       = $resolvedConfigPath
        'EffectiveLIMSRoot' = [string]$global:effectiveLimsRoot
        'SystemLogRoot'    = [string]$global:systemLogRoot
        'BackupRoot'       = [string]$global:backupRootPath
        'StateRoot'        = [string]$global:stateRoot
    }
    foreach ($rootEntry in $diagnosticRoots.GetEnumerator()) {
        if (Test-BRAVOMappedNetworkDrive -Path ([string]$rootEntry.Value)) {
            Write-Host (
                "[FAIL] $($rootEntry.Key): $($rootEntry.Value) — підключений мережевий диск. " +
                "SYSTEM не бачить дискових підключень користувача; використайте UNC \\server\share\..."
            ) -ForegroundColor Red
            $pathRootsFailed = $true
        } else {
            Write-Host "[INFO] $($rootEntry.Key): $($rootEntry.Value)" -ForegroundColor Gray
        }
    }

    # F6: лише попередження (WARN) — код виходу діагностики не змінюється.
    foreach ($dataDirectoryEntry in @(
            @{ Name = 'RuntimeLogRoot'; Path = [string]$global:runtimeLogRoot },
            @{ Name = 'TEMP'; Path = (Join-Path $(if (-not [string]::IsNullOrWhiteSpace([string]$global:runtimeRoot)) { [string]$global:runtimeRoot } else { $scriptRoot }) 'TEMP') },
            @{ Name = 'StateRoot'; Path = [string]$global:stateRoot }
        )) {
        $usersReadableFinding = Get-BRAVOUsersReadableDataDirectoryFinding -Path $dataDirectoryEntry.Path
        if ($null -ne $usersReadableFinding) {
            Write-Host "[WARN] $($dataDirectoryEntry.Name): $($dataDirectoryEntry.Path) — $usersReadableFinding" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "=== ДІАГНОСТИКА ПОСТІЙНИХ ЗАВДАНЬ ===" -ForegroundColor Cyan
    $registrationFailed = $pathRootsFailed
    # BAZASync входить у перелік нарівні з рештою: раніше він був єдиним
    # production-завданням поза діагностикою, тобто єдиним, чия неправильна
    # реєстрація виявлялася б лише з відсутності даних у хмарі.
    $taskArgumentExpectations = @{
        Backup        = @('-NoPause')
        Maintenance   = @('-NoPause')
        Health        = @('-NoPause', '-NotifyOnSuccess')
        Recovery      = @('-NoPause', '-RunMissedRestoreOnly')
        BAZASync      = @('-NoPause', '-SyncBAZA')
        RestoreVerify = @('-NoPause', '-NotifyOnSuccess')
        BackupCatchUp = @('-NoPause', '-CatchUpMissedBackup')
        ServiceRecovery = @('-NoPause', '-RecoverServices')
    }
    foreach ($taskType in @("Backup", "Maintenance", "Health", "Recovery", "BAZASync", "RestoreVerify", "BackupCatchUp", "ServiceRecovery")) {
        $settings = $schedulerSettings[$taskType]
        if ($null -eq $settings -or -not [bool]$settings.Enabled) {
            Write-Host "[SKIP] ${taskType}: вимкнено в конфігурації" -ForegroundColor Gray
            continue
        }
        $registeredTask = $null
        if ($null -ne $taskFolder) {
            try {
                $registeredTask = $taskFolder.GetTask([string]$settings.TaskName)
            } catch {
                $registeredTask = $null
            }
        }
        if ($null -eq $registeredTask) {
            Write-Host "[FAIL] ${taskType}: завдання не зареєстровано" -ForegroundColor Red
            $registrationFailed = $true
            continue
        }

        $lastResult = [Convert]::ToUInt32(
            ([int64]$registeredTask.LastTaskResult) -band 0xffffffffL
        )
        $description = Get-BRAVOTaskResultDescription -ResultCode $lastResult
        $lastResultIsBenign = $lastResult -in @(0, 0x00041300, 0x00041301, 0x00041303)
        $color = if ($lastResultIsBenign) { "Green" } else { "Yellow" }
        # Recovery — boot-тригер: NextRunTime повертає sentinel 30.12.1899.
        # LastRunTime для завдання, що ще не запускалося, — так само sentinel.
        $nextRunRaw = try { $registeredTask.NextRunTime } catch { $null }
        $nextRunText = Format-BRAVODiagnoseTaskNextRun `
            -TaskType $taskType `
            -TaskSettings $settings `
            -NextRunTime $nextRunRaw
        $lastRunRaw = try { $registeredTask.LastRunTime } catch { $null }
        $lastRunText = if ($lastRunRaw -is [datetime] -and $lastRunRaw.Year -gt 1900) {
            $lastRunRaw.ToString('dd.MM.yyyy HH:mm')
        } else {
            'ще не запускалося'
        }
        Write-Host (
            "[INFO] $($registeredTask.Path): enabled=$($registeredTask.Enabled); " +
            "state=$($registeredTask.State); last=0x$($lastResult.ToString('X8')) ($description); " +
            "lastRun=$lastRunText; nextRun=$nextRunText"
        ) -ForegroundColor $color

        $requiredTokens = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy Bypass')
        if ($taskArgumentExpectations.ContainsKey($taskType)) {
            $requiredTokens += $taskArgumentExpectations[$taskType]
        }
        if ($taskType -eq 'Health' -and [bool]$settings.SkipIfBackupTaskRunning) {
            $requiredTokens += '-SkipIfBackupTaskRunning'
        }
        # Expected principal — той самий канонічний розрахунок, що застосовує
        # Installer. Diagnose перевіряє фактичне визначення проти НЬОГО, а не
        # проти жорстко прописаних SYSTEM/5/1.
        $expectedPrincipal = Get-BRAVOExpectedSchedulerPrincipal -SchedulerSettings $schedulerSettings
        # #314: фільтр події 7036 задачі ServiceRecovery звіряється з
        # відображуваними іменами служб, прочитаними так само, як інсталятор.
        $serviceRecoveryStopEventDisplayNames = $null
        if ($taskType -eq 'ServiceRecovery') {
            $discoveryVariableForTask = Get-Variable -Name bravoDiscoveryResult -Scope Global -ErrorAction SilentlyContinue
            $serviceRecoveryStopEventFilter = Get-BRAVOServiceRecoveryStopEventFilter -ServiceNames @(Get-BRAVOServiceRecoveryManagedServiceNames `
                -ServicesSettings $maintenanceSettings.Services `
                -DiscoveryResult $(if ($null -ne $discoveryVariableForTask) { $discoveryVariableForTask.Value }))
            foreach ($serviceRecoveryStopEventWarning in @($serviceRecoveryStopEventFilter.Warnings)) {
                Write-Host "[WARN] ${taskType}: $serviceRecoveryStopEventWarning (штатну зупинку підхопить 15-хвилинний тик)" -ForegroundColor Yellow
            }
            $serviceRecoveryStopEventDisplayNames = @($serviceRecoveryStopEventFilter.DisplayNames)
        }
        $definitionProblems = @(Test-BRAVOScheduledTaskDefinition `
            -ServiceRecoveryStopEventDisplayNames $serviceRecoveryStopEventDisplayNames `
            -TaskType $taskType `
            -RegisteredTask $registeredTask `
            -TaskSettings $settings `
            -ExpectedConfigPath $resolvedConfigPath `
            -ConfigPathWasExplicit $configPathWasExplicit `
            -ExpectedExecutable ([string]$schedulerSettings.PowerShellExecutable) `
            -RequiredArgumentTokens $requiredTokens `
            -ExpectedAccount $expectedPrincipal.UserId `
            -ExpectedLogonType $expectedPrincipal.LogonType `
            -ExpectedRunLevel $expectedPrincipal.RunLevel)
        if ($definitionProblems.Count -eq 0) {
            Write-Host (
                "[PASS] ${taskType}: визначення завдання відповідає конфігурації " +
                "(акаунт '$($expectedPrincipal.UserId)' / LogonType=$($expectedPrincipal.LogonType) / RunLevel=$($expectedPrincipal.RunLevel))"
            ) -ForegroundColor Green
            # Definition validation і execution history — РІЗНІ поняття. Якщо
            # поточне визначення правильне, але останній РЕЗУЛЬТАТ ненульовий,
            # це історія попереднього запуску (можливо, до цього оновлення
            # definition), а не помилка поточної конфігурації.
            if (-not $lastResultIsBenign) {
                Write-Host (
                    "[INFO] ${taskType}: last=0x$($lastResult.ToString('X8')) ($description) — " +
                    "результат ОСТАННЬОГО виконання, а не перевірка поточного визначення " +
                    "(яке щойно пройшло). Якщо definition змінювали, дочекайтеся наступного запуску."
                ) -ForegroundColor DarkGray
            }
        } else {
            foreach ($problem in $definitionProblems) {
                Write-Host "[FAIL] ${taskType}: $problem" -ForegroundColor Red
            }
            $registrationFailed = $true
        }
    }
    Write-Host (
        "[INFO] MultipleInstances=$($schedulerSettings.MultipleInstances): за політикою IgnoreNew " +
        "новий тригер ПРОПУСКАЄТЬСЯ, якщо попередній екземпляр ще виконується."
    ) -ForegroundColor Gray

    # #281 / #154 (B5): read-only доказ — які завдання BRAVO на цьому хості досі
    # передають -ConfigPath на legacy BRAVO.config. Нічого не змінює (ні завдань,
    # ні файлів), не потребує UAC (працює і з -InspectOnly) і НЕ впливає на код
    # виходу: рішення щодо підтримки -ConfigPath на legacy-файл за власником.
    Write-Host ""
    Write-Host "=== LEGACY -ConfigPath У ЗАВДАННЯХ BRAVO (#281 / #154 B5, лише читання) ===" -ForegroundColor Cyan
    try {
        $legacyConfigPathScanRoot = $taskService.GetFolder("\")
        $legacyConfigPathReport = Get-BRAVOLegacyConfigPathTaskReport -TaskFolder $legacyConfigPathScanRoot
        $legacyConfigPathFindings = @($legacyConfigPathReport.Findings)
        foreach ($legacyConfigPathFinding in $legacyConfigPathFindings) {
            $legacyConfigPathLine = Format-BRAVOConfigPathFindingLine -Finding $legacyConfigPathFinding
            $legacyConfigPathColor = switch ([string]$legacyConfigPathLine.Level) {
                'PASS' { 'Green' }
                'WARN' { 'Yellow' }
                default { 'Gray' }
            }
            Write-Host $legacyConfigPathLine.Text -ForegroundColor $legacyConfigPathColor
        }
        foreach ($legacyConfigPathProblem in @($legacyConfigPathReport.Problems)) {
            Write-Host "[WARN] LegacyConfigPath: $legacyConfigPathProblem (потрібні права адміністратора для читання цього завдання?)" -ForegroundColor Yellow
        }
        $legacyConfigPathTaskCount = @($legacyConfigPathFindings | ForEach-Object { $_.TaskPath } | Select-Object -Unique).Count
        Write-Host (
            "[INFO] LegacyConfigPath: переглянуто завдань Планувальника: $($legacyConfigPathReport.TasksScanned); " +
            "завдань BRAVO: $legacyConfigPathTaskCount; " +
            "LegacyPrimary=$(@($legacyConfigPathFindings | Where-Object { $_.Status -eq 'LegacyPrimary' }).Count); " +
            "Local=$(@($legacyConfigPathFindings | Where-Object { $_.Status -eq 'Local' }).Count); " +
            "Missing=$(@($legacyConfigPathFindings | Where-Object { $_.Status -eq 'Missing' }).Count); " +
            "Unknown=$(@($legacyConfigPathFindings | Where-Object { $_.Status -eq 'Unknown' }).Count); " +
            "без -ConfigPath=$(@($legacyConfigPathFindings | Where-Object { $_.Status -eq 'NoConfigPath' }).Count); " +
            "не прочитано=$(@($legacyConfigPathReport.Problems).Count)"
        ) -ForegroundColor Gray
        if ($legacyConfigPathTaskCount -eq 0) {
            Write-Host "[INFO] LegacyConfigPath: завдань із Exec-дією BRAVO_*.ps1 на цьому хості не знайдено." -ForegroundColor Gray
        }
    } catch {
        Write-Host "[WARN] LegacyConfigPath: перевірку не виконано: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if ($InspectOnly) {
        if ($registrationFailed) {
            Complete-BRAVOHelperLog -ExitCode 1
        }
        Write-Host "Реєстрацію постійних завдань перевірено." -ForegroundColor Green
        Complete-BRAVOHelperLog -ExitCode 0
    }

    Write-Host ""
    Write-Host "=== END-TO-END DRY-RUN ВІД NT AUTHORITY\SYSTEM ===" -ForegroundColor Cyan
    $diagnosticRoot = Join-Path (
        [Environment]::GetFolderPath("CommonApplicationData")
    ) "BRAVO\TaskDiagnostics"
    if (-not (Test-Path -LiteralPath $diagnosticRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $diagnosticRoot -Force | Out-Null
    }
    $workingDirectory = Join-Path $diagnosticRoot ([guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
    Set-BRAVOPrivateDirectoryAcl -Path $workingDirectory
    $resultPath = Join-Path $workingDirectory "dry-run.json"
    $temporaryTaskName = "BRAVO_SYSTEM_DRY_RUN_" + ([guid]::NewGuid().ToString("N"))
    $rootTaskFolder = $taskService.GetFolder("\")

    try {
        $definition = $taskService.NewTask(0)
        $definition.RegistrationInfo.Description = "Temporary BRAVO SYSTEM dry-run"
        $definition.Principal.UserId = "SYSTEM"
        $definition.Principal.LogonType = 5
        $definition.Principal.RunLevel = 1
        $definition.Settings.Enabled = $true
        $definition.Settings.ExecutionTimeLimit = "PT10M"
        $definition.Settings.DisallowStartIfOnBatteries = $false
        $definition.Settings.StopIfGoingOnBatteries = $false
        $action = $definition.Actions.Create(0)
        $action.Path = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $argumentParts = @(
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            (ConvertTo-BRAVOProcessArgument $dryRunPath)
        )
        # P0 Configuration Foundation (PR C, Секція 6): тимчасове SYSTEM
        # dry-run завдання має відтворювати ТОЙ САМИЙ AUTO/EXPLICIT намір,
        # що й реальні встановлені завдання — інакше діагностика
        # перевіряла б інший сценарій, ніж той, що реально встановлено.
        if ($configPathWasExplicit) {
            $argumentParts += "-ConfigPath"
            $argumentParts += (ConvertTo-BRAVOProcessArgument $resolvedConfigPath)
        }
        $argumentParts += "-RequireScheduledTasks"
        $argumentParts += "-ResultPath"
        $argumentParts += (ConvertTo-BRAVOProcessArgument $resultPath)
        if ($TestAccess) { $argumentParts += "-TestAccess" }
        if ($SendTestNotification) { $argumentParts += "-SendTestNotification" }
        $action.Arguments = $argumentParts -join " "
        # WorkingDirectory тимчасового SYSTEM dry-run — RuntimeRoot (де лежить
        # BRAVO_DRY_RUN.ps1 і modules), а не каталог конфігурації.
        $action.WorkingDirectory = $scriptRoot

        $temporaryTask = $rootTaskFolder.RegisterTaskDefinition(
            $temporaryTaskName,
            $definition,
            6,
            "SYSTEM",
            $null,
            5,
            $null
        )
        [void]$temporaryTask.Run($null)

        $deadline = (Get-Date).AddMinutes(10)
        while ((Get-Date) -lt $deadline -and
            -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            Start-Sleep -Milliseconds 500
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            $temporaryTask = $rootTaskFolder.GetTask($temporaryTaskName)
            $lastResult = [Convert]::ToUInt32(
                ([int64]$temporaryTask.LastTaskResult) -band 0xffffffffL
            )
            throw (
                "SYSTEM dry-run не створив результат; state=$($temporaryTask.State); " +
                "last=0x$($lastResult.ToString('X8')) " +
                "($(Get-BRAVOTaskResultDescription $lastResult))"
            )
        }

        # ConvertFrom-Json у Windows PowerShell 5.1 віддає JSON-масив ОДНИМ
        # об'єктом, не розгортаючи його в конвеєр. Через це @(... | ConvertFrom-Json)
        # давало масив з єдиного елемента-масиву: цикл нижче виконувався один
        # раз, а $result.Status ставав System.Object[] і друкувався як
        # "[PASS PASS FAIL ...] Конфігурація Скрипти ...: шлях шлях шлях" —
        # увесь результат SYSTEM dry-run в одному нечитабельному рядку.
        # Присвоєння у змінну перед @() зберігає розгортання.
        $parsedResults = [IO.File]::ReadAllText($resultPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
        $results = @($parsedResults)
        foreach ($result in $results) {
            $color = switch ([string]$result.Status) {
                "PASS" { "Green" }
                "FAIL" { "Red" }
                "WARN" { "Yellow" }
                default { "Gray" }
            }
            Write-Host (
                "[$($result.Status)] $($result.Category) / $($result.Name): $($result.Detail)"
            ) -ForegroundColor $color
        }
        $dryRunFailed = @($results | Where-Object { $_.Status -eq "FAIL" }).Count -gt 0
    } finally {
        try {
            $temporaryTask = $rootTaskFolder.GetTask($temporaryTaskName)
            if ([int]$temporaryTask.State -eq 4) {
                $temporaryTask.Stop(0)
            }
            $rootTaskFolder.DeleteTask($temporaryTaskName, 0)
        } catch {
            # Тимчасове завдання створюється лише для перевірки доступу від
            # SYSTEM. Якщо його не вдалося прибрати, воно лишається в
            # Планувальнику й наступний запуск діагностики впаде на
            # створенні завдання з тим самим іменем — тому попереджаємо
            # явно, з іменем, яке треба видалити вручну.
            Write-Warning (
                "Не вдалося видалити тимчасове завдання '$temporaryTaskName': " +
                "$($_.Exception.Message). Видаліть його вручну в Планувальнику завдань."
            )
        }
        if (Test-Path -LiteralPath $workingDirectory -PathType Container) {
            Remove-Item -LiteralPath $workingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($registrationFailed -or $dryRunFailed) {
        Complete-BRAVOHelperLog -ExitCode 1
    }
    Write-Host "Завдання і доступ від SYSTEM перевірено успішно." -ForegroundColor Green
    Complete-BRAVOHelperLog -ExitCode 0
} catch {
    Write-Host "ПОМИЛКА ДІАГНОСТИКИ: $($_.Exception.Message)" -ForegroundColor Red
    Complete-BRAVOHelperLog -ExitCode 1
}
