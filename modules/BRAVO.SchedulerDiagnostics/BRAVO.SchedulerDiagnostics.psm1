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

    $stableVariables = @('SystemRoot', 'windir', 'ProgramData', 'ProgramFiles', 'SystemDrive')
    $expand = {
        param($Text)
        $unsupported = New-Object 'System.Collections.Generic.List[string]'
        $result = $Text
        foreach ($match in [regex]::Matches($Text, '%([^%\\/]+)%')) {
            $variableName = $match.Groups[1].Value
            $value = $null
            if ($stableVariables -contains $variableName) {
                $value = [Environment]::GetEnvironmentVariable($variableName)
            }
            if ([string]::IsNullOrEmpty($value)) {
                $unsupported.Add($variableName)
            } else {
                $result = $result.Replace($match.Value, $value)
            }
        }
        [pscustomobject]@{ Text = $result; Unsupported = $unsupported.ToArray() }
    }
    $unsupportedReason = {
        param($Names)
        'шлях залежить від змінної середовища ' + ((@($Names) | Select-Object -Unique | ForEach-Object { "%$_%" }) -join ', ') +
        ', яку Task Engine бере зі свого (кешованого) середовища, а діагностика не може його відтворити; ' +
        'розкриваються лише %SystemRoot%, %windir%, %ProgramData%, %ProgramFiles%, %SystemDrive%'
    }

    try {
        $expanded = & $expand $Path.Trim()
        if (@($expanded.Unsupported).Count -gt 0) { return (& $failure (& $unsupportedReason $expanded.Unsupported)) }
        $text = $expanded.Text
        if ([IO.Path]::IsPathRooted($text) -and
            $text -notmatch '^[A-Za-z]:(?![\\/])' -and
            $text -notmatch '^[\\/](?![\\/])') {
            return [pscustomobject]@{ Path = [IO.Path]::GetFullPath($text); Reason = $null }
        }
        if ($text -match '^[A-Za-z]:' -or $text -match '^[\\/]') {
            return (& $failure 'шлях залежить від поточного диска/каталогу (X:foo або \foo)')
        }
        if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            return (& $failure 'відносний шлях без WorkingDirectory завдання')
        }
        $expandedWorkingDirectory = & $expand $WorkingDirectory.Trim().Trim('"')
        if (@($expandedWorkingDirectory.Unsupported).Count -gt 0) {
            return (& $failure (& $unsupportedReason $expandedWorkingDirectory.Unsupported))
        }
        if (-not [IO.Path]::IsPathRooted($expandedWorkingDirectory.Text)) {
            return (& $failure 'WorkingDirectory завдання не є абсолютним шляхом')
        }
        return [pscustomobject]@{
            Path = [IO.Path]::GetFullPath((Join-Path -Path $expandedWorkingDirectory.Text -ChildPath $text))
            Reason = $null
        }
    } catch {
        return (& $failure "некоректний шлях: $($_.Exception.Message)")
    }
}

function Get-BRAVOScriptDeclaredParameter {
    # Модель param()-блоку скрипта для відтворення прив'язки параметрів PowerShell:
    #  Entries         — кожне ім'я та alias -> параметр-власник (Owner);
    #  SwitchOwners    — власники типу [switch] (значення не споживають);
    #  PositionalOrder — власники у порядку позиційної прив'язки;
    #  PositionalAmbiguous — позицію статично не визначити (набори параметрів, змішані
    #                   явні/неявні Position, ValueFromRemainingArguments).
    # Known=$false, коли скрипт недоступний або не розбирається.
    param([AllowNull()][AllowEmptyString()][string]$ScriptPath)

    $unknown = [pscustomobject]@{
        Known = $false; Entries = @(); SwitchOwners = @(); PositionalOrder = @(); PositionalAmbiguous = $true
    }
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return $unknown }
    try {
        if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { return $unknown }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
        if ($null -eq $ast -or @($errors).Count -gt 0) { return $unknown }

        $entries = New-Object 'System.Collections.Generic.List[object]'
        $switchOwners = New-Object 'System.Collections.Generic.List[string]'
        $positional = New-Object 'System.Collections.Generic.List[object]'
        $ambiguous = $false
        $positionalBinding = $true
        $paramBlock = $ast.ParamBlock
        if ($null -ne $paramBlock) {
            $advanced = $false
            $supportsShouldProcess = $false
            foreach ($attribute in @($paramBlock.Attributes)) {
                if ($attribute.TypeName.Name -ne 'CmdletBinding') { continue }
                $advanced = $true
                foreach ($namedArgument in @($attribute.NamedArguments)) {
                    if ($namedArgument.ArgumentName -eq 'SupportsShouldProcess') { $supportsShouldProcess = $true }
                    if ($namedArgument.ArgumentName -eq 'DefaultParameterSetName') { $ambiguous = $true }
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
                $explicitPosition = $null
                foreach ($attribute in @($parameter.Attributes)) {
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
                            if ($namedArgument.ArgumentName -eq 'ParameterSetName') { $ambiguous = $true }
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

function Get-BRAVOActionExecutableKind {
    # Exec.Command -> PowerShell | Cmd | Other (за ім'ям файла, без урахування регістру,
    # у лапках чи без, зі шляхом (%SystemRoot%\...) чи без). Аргументи розбираються як
    # синтаксис PowerShell лише для PowerShell; cmd.exe — обгортка, яку статично не розбираємо.
    param([AllowNull()][AllowEmptyString()][string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return 'Other' }
    $text = $Command.Trim().Trim('"').Trim()
    $leaf = ($text -split '[\\/]')[-1].Trim().Trim('"').ToLowerInvariant()
    if ($leaf -eq 'powershell.exe' -or $leaf -eq 'powershell') { return 'PowerShell' }
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
        if ('encodedcommand'.StartsWith($name, [StringComparison]::Ordinal)) { return [pscustomobject]@{ Mode = 'EncodedCommand'; Index = $i } }
    }
    return [pscustomobject]@{ Mode = $null; Index = -1 }
}

function Get-BRAVOPowerShellActionDefinition {
    # Розбір Action.Arguments powershell.exe: режим, ціль -File або текст команди
    # (для -EncodedCommand — ДЕКОДОВАНИЙ), помилки розбору. Нічого не виконується.
    param([AllowNull()][AllowEmptyString()][string]$Arguments)

    $split = ConvertFrom-BRAVOWindowsCommandLine -CommandLine $Arguments
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
    if (-not $definition.Balanced) {
        $definition.Problem = 'незбалансовані лапки в аргументах завдання'
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
            $definition.Problem = "-EncodedCommand не вдалося декодувати: $($_.Exception.Message)"
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
            & $fail "параметр -$($current.Spelling) не розпізнано за param() скрипта"
            if ($hasNextValue) {
                $nextText = [string]$items[$i + 1].Text
                if (-not [bool]$Declared.Known -and ($null -eq $items[$i + 1].Text -or $nextText -match '(?i)\.config$')) {
                    $references.Add((& $newReference $current.Spelling $null "параметр -$($current.Spelling) невідомий (param() скрипта недоступний); наступне значення могло б бути -ConfigPath"))
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
    $withValue = @{ executionpolicy = 2; windowstyle = 2; version = 2; inputformat = 2; outputformat = 2 }
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
        [AllowNull()][AllowEmptyString()][string]$WorkingDirectory
    )

    $references = New-Object 'System.Collections.Generic.List[object]'
    $problemReference = {
        param($Form, $ScriptPath, $Problem)
        [pscustomobject]@{ Form = $Form; ScriptPath = $ScriptPath; Spelling = $null; RawValue = $null; Problem = $Problem }
    }
    $noProfile = $false
    $result = {
        param($Modelled, $Reason)
        [pscustomobject]@{ References = $references.ToArray(); Modelled = [bool]$Modelled; Reason = $Reason; NoProfile = [bool]$noProfile }
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
        if (-not (Test-BRAVOScriptPathIsBravoEntrypoint -ScriptPath $scriptPath)) {
            return (& $result $false '-File вказує не на BRAVO_*.ps1, а дія згадує BRAVO_*.ps1 в аргументах/каталозі')
        }
        $declared = Get-BRAVOScriptDeclaredParameter -ScriptPath (Resolve-BRAVOTaskActionPath -Path $scriptPath -WorkingDirectory $WorkingDirectory).Path
        $items = New-Object 'System.Collections.Generic.List[object]'
        for ($i = $Definition.ModeIndex + 2; $i -lt $tokens.Count; $i++) {
            if ($tokens[$i] -match '^-([A-Za-z][A-Za-z0-9_]*)(:(.*))?$') {
                $hasInline = $tokens[$i].Contains(':')
                if ($hasInline -and [string]$Matches[3] -eq '') {
                    # '-Param:' без значення в тому ж токені: чи візьме PowerShell наступний токен — не змоделювати.
                    $items.Add([pscustomobject]@{ Kind = 'Opaque'; Text = $null; Reason = "токен '$($tokens[$i])' має порожнє inline-значення" })
                    continue
                }
                $items.Add([pscustomobject]@{
                        Kind = 'Param'; Spelling = $Matches[1]; HasInline = $hasInline
                        Text = $(if ($hasInline) { [string]$Matches[3] } else { $null }); Reason = $null
                    })
            } elseif ($tokens[$i].StartsWith('-', [StringComparison]::Ordinal)) {
                $items.Add([pscustomobject]@{ Kind = 'Opaque'; Text = $null; Reason = "токен '$($tokens[$i])' не змодельовано" })
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
    $parseTokens = $null
    $parseErrors = $null
    $commandAst = [System.Management.Automation.Language.Parser]::ParseInput([string]$Definition.CommandText, [ref]$parseTokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        $problem = "текст -$mode не розібрано: $(@($parseErrors)[0].Message)"
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
        $declared = Get-BRAVOScriptDeclaredParameter -ScriptPath (Resolve-BRAVOTaskActionPath -Path $scriptPath -WorkingDirectory $WorkingDirectory).Path
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
        [Parameter(Mandatory = $true)][scriptblock]$LegacyConfigurationValidator
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
    } catch {
        return (& $classify 'Unknown' $resolved "не вдалося перевірити файл: $($_.Exception.Message)")
    }
    if ([string]::Equals([IO.Path]::GetFileName($resolved), 'BRAVO.local.config', [StringComparison]::OrdinalIgnoreCase)) {
        return (& $classify 'Local' $resolved 'BRAVO.local.config')
    }
    try {
        & $LegacyConfigurationValidator $resolved (Split-Path -Path $resolved -Parent)
    } catch {
        return (& $classify 'Unknown' $resolved "loader не приймає цей файл як legacy primary: $($_.Exception.Message)")
    }
    return (& $classify 'LegacyPrimary' $resolved 'BRAVO.config (legacy primary)')
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
        [Parameter(Mandatory = $true)][scriptblock]$LegacyConfigurationValidator
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
                ConfigPathRaw = if ($null -ne $Reference) { [string]$Reference.RawValue } else { $null }
                ResolvedPath = if ($null -ne $Classification) { [string]$Classification.ResolvedPath } else { $null }
                Detail = $Detail
            }
        }

        $kind = Get-BRAVOActionExecutableKind -Command $command
        if ($kind -eq 'Other') { continue }
        if ($kind -eq 'Cmd') {
            if ($arguments -match $bravoPattern -or $workingDirectory -match $bravoPattern) {
                $findings.Add((& $newFinding 'Unknown' $null $null 'обгортка cmd.exe, що згадує BRAVO_*.ps1 — аргументи статично не розібрано'))
            }
            continue
        }

        $definition = Get-BRAVOPowerShellActionDefinition -Arguments $arguments
        $mention = ($arguments -match $bravoPattern -or $workingDirectory -match $bravoPattern -or
            ($null -ne $definition.CommandText -and [string]$definition.CommandText -match $bravoPattern))
        if (-not $mention) { continue }
        if ($kind -eq 'Pwsh') {
            $findings.Add((& $newFinding 'Unknown' $null $null 'pwsh.exe не моделюється (інші правила розбору аргументів і опцій, ніж у Windows PowerShell 5.1) — аргументи статично не розібрано'))
            continue
        }

        $analysis = Get-BRAVOTaskActionConfigPathReference -Definition $definition -WorkingDirectory $workingDirectory
        $references = @($analysis.References)
        if ($references.Count -eq 0) {
            if ([bool]$analysis.Modelled) {
                if (-not [bool]$analysis.NoProfile) {
                    $findings.Add((& $newFinding 'Unknown' $null $null 'powershell.exe запущено без -NoProfile: профіль облікового запису завдання може задати ConfigPath через $PSDefaultParameterValues, тож відсутність -ConfigPath (AUTO) не підтверджується'))
                } else {
                    $findings.Add((& $newFinding 'NoConfigPath' $null $null '-ConfigPath відсутній (AUTO); дію повністю змодельовано'))
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
                $findings.Add((& $newFinding 'Unknown' $reference $null ("знайдено -ConfigPath '$($reference.RawValue)', але дію не змодельовано повністю ($($analysis.Reason)) — клас не присвоюється")))
                continue
            }
            $classification = Get-BRAVOConfigPathTargetClassification -RawPath $reference.RawValue -WorkingDirectory $workingDirectory `
                -LegacyConfigurationValidator $LegacyConfigurationValidator
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
    # Read-only обхід дерева Планувальника (ITaskFolder) від переданої папки: для кожного
    # завдання читається лише Task.Xml; жодне завдання/файл не змінюється. Завдання, чий
    # XML недоступний, потрапляють у Problems.
    param(
        [Parameter(Mandatory = $true)]$TaskFolder,
        [Parameter(Mandatory = $true)][scriptblock]$LegacyConfigurationValidator
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
                            -Actions $taskActions -LegacyConfigurationValidator $LegacyConfigurationValidator)) {
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
