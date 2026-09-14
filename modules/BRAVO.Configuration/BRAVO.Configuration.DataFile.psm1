Set-StrictMode -Version 2.0

# BRAVO.Configuration.DataFile — НЕВИКОНУЮЧЕ вилучення літеральних даних
# з PowerShell-файлу конфігурації (#154, задача B1).
#
# НАВІЩО ОКРЕМА РЕАЛІЗАЦІЯ, КОЛИ CheckRestrictedLanguage ВЖЕ Є.
# Попередній контракт BRAVO.local.config був «перевірити обмеженою мовою,
# ПОТІМ виконати»: [scriptblock]::Create -> CheckRestrictedLanguage(@(), @(), $false)
# -> & $scriptBlock. Порожні allow-списки справді відхиляють cmdlet-и,
# виклики функцій і звернення до змінних/середовища ДО виконання, але:
#
#   - обмежена мова даних PowerShell лишається МОВОЮ: вона все ще
#     приймає деякі форми виразів (арифметика, діапазони), і
#     перевірений блок ПОТІМ ВИКЛИКАЄТЬСЯ, тобто такий вираз
#     ОБЧИСЛЮЄТЬСЯ, а не вилучається як літерал;
#   - fail-closed перелік дозволеного належить граматиці PowerShell, а
#     не нам: розширення обмеженої мови в майбутній версії платформи
#     автоматично розширило б і те, що приймає site-файл.
#
# Тут натомість: парсинг у AST -> обхід за ЯВНИМ переліком дозволених
# вузлів-літералів -> вилучення значень як ДАНИХ. Скомпільований
# scriptblock не створюється й не викликається взагалі; будь-який вузол
# поза переліком — відмова (fail closed).
#
# Прецедент невиконуючого читання конфігурації в цьому репозиторії вже
# є: Test-BRAVORuntimeSecuritySettings (BRAVO_RUNTIME_GUARD.ps1) читає
# перемикачі безпеки з BRAVO.config через [Parser]::ParseFile, ніколи не
# виконуючи файл. Ця функція узагальнює той самий підхід до повного
# data-only графа site-файлу.
#
# ЩО САМЕ ДОЗВОЛЕНО (усе інше — відмова):
#   - верхній рівень: рівно один hashtable-літерал @{ ... };
#   - ключі: рядкові константи (лапки або bareword), непорожні,
#     без повторів (регістронезалежно — як у самій hashtable PowerShell);
#   - значення: рядкові/числові константи, $true, $false, $null,
#     масиви @( ... ) і 1, 2, 3, вкладені hashtable-літерали,
#     знак +/- безпосередньо перед числовою константою;
#   - НЕ дозволено: param/begin/process/dynamicparam/using, виклики
#     команд і функцій, доступ до членів, індексація, приведення типів,
#     підвирази $( ), @( ) з інструкціями, будь-які інші звернення до
#     змінних (включно з $env:, $global:, $script:, $foo), рядки з
#     інтерполяцією, дужкові вирази, оператори.

# Глибина вкладеності. Плаский контракт 'dot.path' = значення потребує
# 1-2 рівнів; ліміт існує лише щоб патологічно вкладений файл давав
# зрозумілу відмову, а не переповнення стека.
$script:BRAVOConfigurationDataFileMaximumDepth = 16

function Get-BRAVOConfigurationDataFileNodeDescription {
    # Текст вузла для повідомлення про відмову: тип AST + рядок + сам
    # фрагмент. Без цього оператор бачив би «файл відхилено» без жодної
    # вказівки, що саме переписати на літерал.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Node)

    $extentText = [string]$Node.Extent.Text
    if ($extentText.Length -gt 120) { $extentText = $extentText.Substring(0, 117) + '...' }
    return "$($Node.GetType().Name) (рядок $($Node.Extent.StartLineNumber)): $extentText"
}

function Get-BRAVOConfigurationDataFileLiteralValue {
    <#
    .SYNOPSIS
        Вилучає значення одного вузла-літерала AST.
    .DESCRIPTION
        Повертає ОБГОРТКУ [pscustomobject]@{ Value = ... }, а не саме
        значення. Причина — PowerShell 5.1: результат функції проходить
        через output pipeline, який РОЗГОРТАЄ колекції. Прямий
        `return @()` перетворився б у $null, а `return @('x')` — у 'x',
        тобто порожній масив у site-файлі мовчки став би $null. Той самий
        клас дефекту вже ловився в Compare-BRAVOConfigurationGraph
        (порожні diff-рядки), тому тут він виключений конструктивно.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Node,
        [Parameter(Mandatory = $true)][string]$SourceName,
        [Parameter(Mandatory = $true)][int]$Depth
    )

    if ($Depth -gt $script:BRAVOConfigurationDataFileMaximumDepth) {
        throw "'$SourceName': перевищено дозволену глибину вкладеності даних ($script:BRAVOConfigurationDataFileMaximumDepth)."
    }

    # StringConstantExpressionAst успадковує ConstantExpressionAst, тому
    # перевіряється ПЕРШИМ: інакше рядок потрапляв би в числову гілку.
    if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return [pscustomobject]@{ Value = [string]$Node.Value }
    }

    # Рядок з інтерполяцією ("$env:X") — окремий тип вузла й НЕ константа.
    if ($Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        throw "'$SourceName': рядок з підстановкою заборонений, потрібен літерал в одинарних лапках — $(Get-BRAVOConfigurationDataFileNodeDescription -Node $Node)"
    }

    if ($Node -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        return [pscustomobject]@{ Value = $Node.Value }
    }

    if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        if ($Node.Splatted) {
            throw "'$SourceName': splatting заборонений — $(Get-BRAVOConfigurationDataFileNodeDescription -Node $Node)"
        }
        # UserPath, а не UnqualifiedPath: останньої властивості в
        # System.Management.Automation.VariablePath Windows PowerShell 5.1
        # публічно немає. UserPath ЗБЕРІГАЄ префікс області ($global:true
        # -> 'global:true'), тому точне порівняння нижче автоматично
        # відхиляє будь-яку кваліфіковану форму — розпізнаються лише три
        # внутрішні константи мови, і жодна з них не розв'язується зі
        # стану сесії.
        $userPath = [string]$Node.VariablePath.UserPath
        if ($userPath -ieq 'true') { return [pscustomobject]@{ Value = $true } }
        if ($userPath -ieq 'false') { return [pscustomobject]@{ Value = $false } }
        if ($userPath -ieq 'null') { return [pscustomobject]@{ Value = $null } }
        throw "'$SourceName': звернення до змінної заборонене (дозволені лише константи `$true, `$false, `$null) — $(Get-BRAVOConfigurationDataFileNodeDescription -Node $Node)"
    }

    if ($Node -is [System.Management.Automation.Language.UnaryExpressionAst]) {
        # Єдиний дозволений «вираз»: знак безпосередньо перед числовою
        # константою. Це форма запису ЧИСЛА, а не обчислення — вона не
        # може виразити жодної операції над іншими значеннями. Дозволена
        # явно, бо PowerShell залежно від контексту може розбирати -5 і
        # як константу, і як унарний вираз, а відмова від'ємного порогу
        # була б функціональною регресією, а не посиленням безпеки.
        $child = $Node.Child
        $isSignedNumber = (
            $child -is [System.Management.Automation.Language.ConstantExpressionAst] -and
            $child -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -and
            (
                $child.Value -is [int] -or $child.Value -is [long] -or $child.Value -is [double] -or
                $child.Value -is [decimal] -or $child.Value -is [single] -or $child.Value -is [short] -or
                $child.Value -is [byte]
            )
        )
        if ($isSignedNumber) {
            # Порівняння за ІМЕНЕМ значення enum, а не за членом
            # [TokenKind]::Minus: так перевірка не залежить від того, чи
            # платформа називає унарну форму Minus/Plus, чи окремо
            # UnaryMinus/UnaryPlus. Будь-яке інше ім'я (наприклад
            # MinusMinus) сюди не потрапляє й дає відмову нижче.
            $signTokenName = [string]$Node.TokenKind
            if ($signTokenName -eq 'Minus' -or $signTokenName -eq 'UnaryMinus') {
                return [pscustomobject]@{ Value = (0 - $child.Value) }
            }
            if ($signTokenName -eq 'Plus' -or $signTokenName -eq 'UnaryPlus') {
                return [pscustomobject]@{ Value = $child.Value }
            }
        }
        throw "'$SourceName': вираз заборонений, дозволені лише літеральні значення — $(Get-BRAVOConfigurationDataFileNodeDescription -Node $Node)"
    }

    if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        # Форма без дужок: 1, 2, 3
        $literalItems = New-Object System.Collections.Generic.List[object]
        foreach ($element in $Node.Elements) {
            $elementValue = Get-BRAVOConfigurationDataFileLiteralValue -Node $element -SourceName $SourceName -Depth ($Depth + 1)
            [void]$literalItems.Add($elementValue.Value)
        }
        return [pscustomobject]@{ Value = $literalItems.ToArray() }
    }

    if ($Node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        # Форма @( ... ). Порожній @() — це НУЛЬ інструкцій усередині, і
        # саме тому обгортка результату обов'язкова (див. .DESCRIPTION).
        $arrayItems = New-Object System.Collections.Generic.List[object]
        foreach ($statement in $Node.SubExpression.Statements) {
            if ($statement -isnot [System.Management.Automation.Language.PipelineAst]) {
                throw "'$SourceName': всередині @( ) дозволені лише літеральні значення — $(Get-BRAVOConfigurationDataFileNodeDescription -Node $statement)"
            }
            if (@($statement.PipelineElements).Count -ne 1) {
                throw "'$SourceName': конвеєр усередині @( ) заборонений — $(Get-BRAVOConfigurationDataFileNodeDescription -Node $statement)"
            }
            $pipelineElement = $statement.PipelineElements[0]
            if ($pipelineElement -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
                throw "'$SourceName': виклик команди всередині @( ) заборонений — $(Get-BRAVOConfigurationDataFileNodeDescription -Node $pipelineElement)"
            }
            $itemValue = Get-BRAVOConfigurationDataFileLiteralValue -Node $pipelineElement.Expression -SourceName $SourceName -Depth ($Depth + 1)
            if ($pipelineElement.Expression -is [System.Management.Automation.Language.ArrayLiteralAst] -or
                $pipelineElement.Expression -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                # @('a', 'b') — один елемент-ArrayLiteralAst із двома
                # значеннями: розкладаємо, інакше вийшов би масив з одного
                # вкладеного масиву. ArrayExpressionAst розкладається з тієї
                # ж причини: PowerShell при виконанні теж розгортав @( @(...) )
                # в плоский масив, і розбіжність тут дала б інший результат,
                # ніж давав попередній механізм.
                foreach ($item in @($itemValue.Value)) { [void]$arrayItems.Add($item) }
            } else {
                [void]$arrayItems.Add($itemValue.Value)
            }
        }
        return [pscustomobject]@{ Value = $arrayItems.ToArray() }
    }

    if ($Node -is [System.Management.Automation.Language.HashtableAst]) {
        return [pscustomobject]@{
            Value = (ConvertFrom-BRAVOConfigurationDataFileHashtableAst -HashtableAst $Node -SourceName $SourceName -Depth $Depth)
        }
    }

    throw "'$SourceName': непідтримувана синтаксична конструкція (дозволені лише літеральні дані) — $(Get-BRAVOConfigurationDataFileNodeDescription -Node $Node)"
}

function ConvertFrom-BRAVOConfigurationDataFileHashtableAst {
    <#
    .SYNOPSIS
        Перетворює hashtable-літерал AST у hashtable ДАНИХ.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Language.HashtableAst]$HashtableAst,
        [Parameter(Mandatory = $true)][string]$SourceName,
        [Parameter(Mandatory = $true)][int]$Depth
    )

    # Регістронезалежна, як і будь-яка hashtable PowerShell: контракт
    # ключів site-файлу від цього переходу не змінюється.
    $result = @{}
    foreach ($pair in $HashtableAst.KeyValuePairs) {
        $keyNode = $pair.Item1
        $valueNode = $pair.Item2

        if ($keyNode -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            throw "'$SourceName': ключ мусить бути рядковою константою — $(Get-BRAVOConfigurationDataFileNodeDescription -Node $keyNode)"
        }
        $key = [string]$keyNode.Value
        if ([string]::IsNullOrWhiteSpace($key)) {
            throw "'$SourceName': порожній ключ неприпустимий (рядок $($keyNode.Extent.StartLineNumber))."
        }
        if ($result.Contains($key)) {
            # Раніше цю відмову давав сам PowerShell під час виконання
            # блока. Виконання більше немає — перевірка мусить бути тут,
            # інакше дублікат мовчки перезаписував би попереднє значення.
            throw "'$SourceName': повторний ключ '$key' (рядок $($keyNode.Extent.StartLineNumber))."
        }

        # Значення вузла-інструкції (StatementAst) у hashtable: @{ a = if (...) {} }
        # сюди не дійде — Item2 такої форми не є ExpressionAst і
        # відхиляється як непідтримувана конструкція.
        $valueExpression = $valueNode
        if ($valueNode -is [System.Management.Automation.Language.PipelineAst]) {
            if (@($valueNode.PipelineElements).Count -ne 1) {
                throw "'$SourceName': конвеєр у значенні ключа '$key' заборонений (рядок $($valueNode.Extent.StartLineNumber))."
            }
            $firstElement = $valueNode.PipelineElements[0]
            if ($firstElement -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
                throw "'$SourceName': виклик команди у значенні ключа '$key' заборонений — $(Get-BRAVOConfigurationDataFileNodeDescription -Node $firstElement)"
            }
            $valueExpression = $firstElement.Expression
        }

        $extracted = Get-BRAVOConfigurationDataFileLiteralValue -Node $valueExpression -SourceName $SourceName -Depth ($Depth + 1)
        $result[$key] = $extracted.Value
    }
    return $result
}

function ConvertFrom-BRAVOConfigurationDataFileText {
    <#
    .SYNOPSIS
        Вилучає data-only hashtable з тексту PowerShell-конфігурації,
        НЕ виконуючи його (#154, B1).
    .DESCRIPTION
        Парсить текст у AST і обходить його за явним переліком дозволених
        вузлів-літералів. Скомпільований scriptblock не створюється, не
        викликається і не dot-source'иться; будь-яка конструкція поза
        переліком — відмова (fail closed).
    .PARAMETER Text
        Вміст файлу. Порожній текст — відмова: порожній файл не є
        валідним hashtable-літералом (штатний «немає перевизначень» —
        це ВІДСУТНІЙ файл, а не порожній).
    .PARAMETER SourceName
        Шлях/ім'я джерела для повідомлень про відмову.
    .OUTPUTS
        [hashtable]
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$SourceName
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $parseErrors -and @($parseErrors).Count -gt 0) {
        $firstError = @($parseErrors)[0]
        throw "'$SourceName': синтаксична помилка (рядок $($firstError.Extent.StartLineNumber)): $($firstError.Message)"
    }

    if ($null -ne $ast.ParamBlock) { throw "'$SourceName': блок param() заборонений — файл є ДАНИМИ, а не скриптом." }
    if ($null -ne $ast.BeginBlock) { throw "'$SourceName': блок begin заборонений — файл є ДАНИМИ, а не скриптом." }
    if ($null -ne $ast.ProcessBlock) { throw "'$SourceName': блок process заборонений — файл є ДАНИМИ, а не скриптом." }
    if ($null -ne $ast.DynamicParamBlock) { throw "'$SourceName': блок dynamicparam заборонений — файл є ДАНИМИ, а не скриптом." }

    # UsingStatements з'явився у ScriptBlockAst лише в PowerShell 5:
    # перевірка через PSObject, щоб Set-StrictMode не зривався на
    # відсутній властивості там, де її немає.
    $usingProperty = $ast.PSObject.Properties['UsingStatements']
    if ($null -ne $usingProperty -and $null -ne $usingProperty.Value -and @($usingProperty.Value).Count -gt 0) {
        throw "'$SourceName': інструкція using заборонена — файл є ДАНИМИ, а не скриптом."
    }

    if ($null -eq $ast.EndBlock) {
        throw "'$SourceName': очікується один hashtable-літерал @{ ... }, файл порожній."
    }
    $statements = @($ast.EndBlock.Statements)
    if ($statements.Count -eq 0) {
        throw "'$SourceName': очікується один hashtable-літерал @{ ... }, файл порожній."
    }
    if ($statements.Count -ne 1) {
        throw "'$SourceName': очікується РІВНО один hashtable-літерал @{ ... } (знайдено інструкцій: $($statements.Count))."
    }

    $statement = $statements[0]
    if ($statement -isnot [System.Management.Automation.Language.PipelineAst]) {
        throw "'$SourceName': очікується hashtable-літерал @{ ... } — $(Get-BRAVOConfigurationDataFileNodeDescription -Node $statement)"
    }
    if (@($statement.PipelineElements).Count -ne 1) {
        throw "'$SourceName': конвеєр на верхньому рівні заборонений."
    }
    $topElement = $statement.PipelineElements[0]
    if ($topElement -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
        throw "'$SourceName': виклик команди на верхньому рівні заборонений — $(Get-BRAVOConfigurationDataFileNodeDescription -Node $topElement)"
    }
    if ($topElement.Expression -isnot [System.Management.Automation.Language.HashtableAst]) {
        throw "'$SourceName': верхній рівень мусить бути hashtable-літералом @{ ... } — $(Get-BRAVOConfigurationDataFileNodeDescription -Node $topElement.Expression)"
    }

    return (ConvertFrom-BRAVOConfigurationDataFileHashtableAst `
        -HashtableAst $topElement.Expression -SourceName $SourceName -Depth 0)
}

Export-ModuleMember -Function @('ConvertFrom-BRAVOConfigurationDataFileText')
