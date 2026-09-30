# Домен-фрагмент self-test: Governance (документація і політики репо):
# Documentation/* (SECURITY.md, THREAT_MODEL.md, RELEASE_CHECKLIST.md,
# RELEASE_POLICY.md, README.md, OPERATIONS.md -- обов'язкові розділи,
# відповідність реалізованим контролям), StaticAnalysis/* (PSScriptAnalyzer
# settings, ci.yml: блокуючі security-правила; усі .github\workflows:
# ASCII-only run-блоки, pinned action SHA), ReleasePolicy/* (CI-гейт гілка/версія/канал).
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 -- НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition, $script:failures.
# Зовнішніх source-text залежностей не має: всі документи й конфіги
# читаються локально в цьому фрагменті.

    # P2.4 аудиту: SECURITY.md — обов'язковий, легко забути оновити після
    # security-релевантних змін. Перевіряємо лише структуру (розділи є),
    # не зміст — зміст неможливо валідувати автоматично.
    $securityDocPath = Join-Path $root "SECURITY.md"
    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $securityDocPath -PathType Leaf) `
        -Name "Documentation/SecurityMdExists" `
        -Failure "SECURITY.md має існувати в корені репозиторію"
    if (Test-Path -LiteralPath $securityDocPath -PathType Leaf) {
        $securityDocText = [IO.File]::ReadAllText($securityDocPath, [Text.Encoding]::UTF8)
        Test-BRAVOCondition `
            -Condition (
                $securityDocText.Contains("Підтримувані версії") -and
                $securityDocText.Contains("Порядок повідомлення про вразливості") -and
                $securityDocText.Contains("Модель секретів") -and
                $securityDocText.Contains("Модель довіри до Tools") -and
                $securityDocText.Contains("Модель ACL") -and
                $securityDocText.Contains("Обмеження Credential Manager")
            ) `
            -Name "Documentation/SecurityMdCoversRequiredSections" `
            -Failure "SECURITY.md має покривати підтримувані версії, порядок повідомлення про вразливості, модель секретів/Tools/ACL і обмеження Credential Manager"

        # Аудит 2026-09-14 (P1): SECURITY.md посилався на приватний
        # репозиторій ekucher/ARCHIV_LIMS_MONOLITH і радив подавати
        # вразливість через Issue. Репозиторій публічний з 2026-08-26
        # (ROADMAP.md P0.2), тож та порада означала публічне розкриття
        # вразливості до випуску виправлення. Застаріла ідентичність
        # репозиторію в security-документі — не косметика: саме за нею
        # дослідник обирає канал.
        Test-BRAVOCondition `
            -Condition (-not $securityDocText.Contains('ARCHIV_LIMS_MONOLITH')) `
            -Name "Documentation/SecurityMdHasNoStaleRepositoryIdentity" `
            -Failure "SECURITY.md не повинен посилатися на застарілий репозиторій ARCHIV_LIMS_MONOLITH — канонічна ідентичність: ekucher/BRAVO-Toolkit"
        Test-BRAVOCondition `
            -Condition ($securityDocText.Contains('ekucher/BRAVO-Toolkit')) `
            -Name "Documentation/SecurityMdNamesCanonicalRepository" `
            -Failure "SECURITY.md має називати канонічний репозиторій ekucher/BRAVO-Toolkit"
        Test-BRAVOCondition `
            -Condition (
                $securityDocText.Contains('Private Vulnerability Reporting') -and
                $securityDocText.Contains('Не подавайте вразливість через Issue')
            ) `
            -Name "Documentation/SecurityMdRequiresPrivateDisclosureChannel" `
            -Failure "SECURITY.md має називати приватний канал (GitHub Private Vulnerability Reporting) основним і прямо забороняти подання вразливості через публічний Issue"
        # Формулювання-пастка: будь-яка порада "подавайте Issue" у
        # security-документі публічного репозиторію означає публічне
        # розкриття. Перевіряємо саме заклик до дії, а не будь-яку згадку
        # слова Issue (розділ вище свідомо пояснює, ЧОМУ Issue не можна).
        Test-BRAVOCondition `
            -Condition (-not [regex]::IsMatch(
                $securityDocText,
                '(?i)подавайте\s+(вразливість\s+)?Issue'
            )) `
            -Name "Documentation/SecurityMdNeverAdvisesPublicIssueDisclosure" `
            -Failure "SECURITY.md не повинен радити подавати вразливість через Issue — репозиторій публічний, це розкриття до випуску виправлення"
    }

    # Аудит P1 (PSScriptAnalyzer майже не блокує небезпечні патерни):
    # security-правила НЕ повинні виключатись глобально. Обґрунтовані
    # місця мають точковий SuppressMessageAttribute, а не -ExcludeRule у
    # workflow — інакше НОВИЙ небезпечний код теж мовчки пройде CI.
    $analyzerSettingsPath = Join-Path $root "PSScriptAnalyzerSettings.psd1"
    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $analyzerSettingsPath -PathType Leaf) `
        -Name "StaticAnalysis/AnalyzerSettingsExist" `
        -Failure "PSScriptAnalyzerSettings.psd1 має існувати в корені репозиторію"

    $requiredBlockingRules = @(
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingUsernameAndPasswordParams',
        'PSAvoidUsingInvokeExpression',
        'PSAvoidUsingComputerNameHardcoded'
    )
    if (Test-Path -LiteralPath $analyzerSettingsPath -PathType Leaf) {
        $analyzerSettings = Import-PowerShellDataFile -LiteralPath $analyzerSettingsPath
        $blockingRules = @($analyzerSettings.IncludeRules)
        $missingBlockingRules = @(
            $requiredBlockingRules | Where-Object { $blockingRules -notcontains $_ }
        )
        Test-BRAVOCondition `
            -Condition ($missingBlockingRules.Count -eq 0) `
            -Name "StaticAnalysis/SecurityRulesAreBlocking" `
            -Failure "PSScriptAnalyzerSettings.psd1 має блокувати security-правила; відсутні: $($missingBlockingRules -join ', ')"
    }

    # Той самий набір не повинен повернутись у workflow як -ExcludeRule.
    $ciWorkflowPath = Join-Path $root ".github\workflows\ci.yml"
    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $ciWorkflowPath -PathType Leaf) `
        -Name "StaticAnalysis/CiWorkflowExists" `
        -Failure ".github\workflows\ci.yml має існувати"
    if (Test-Path -LiteralPath $ciWorkflowPath -PathType Leaf) {
        $ciWorkflowText = [IO.File]::ReadAllText($ciWorkflowPath, [Text.Encoding]::UTF8)
        # Рядок з -ExcludeRule дозволений рівно один — інформаційний
        # прохід, який виключає САМЕ блокуючий набір (щоб не дублювати
        # його вивід), а не приховує security-правила.
        $globallyExcluded = @(
            $requiredBlockingRules | Where-Object {
                $ciWorkflowText -match "ExcludeRule[^\r\n]*$([regex]::Escape($_))"
            }
        )
        Test-BRAVOCondition `
            -Condition ($globallyExcluded.Count -eq 0) `
            -Name "StaticAnalysis/NoGlobalSecurityRuleExclusions" `
            -Failure "ci.yml не повинен виключати security-правила поіменно: $($globallyExcluded -join ', ')"

        Test-BRAVOCondition `
            -Condition (
                $ciWorkflowText.Contains('Invoke-BRAVOSecurityAnalysis.ps1') -and
                $ciWorkflowText.Contains('Test-BRAVOForbiddenPattern.ps1')
            ) `
            -Name "StaticAnalysis/CiUsesSettingsAndForbiddenPatterns" `
            -Failure "ci.yml має викликати ci\Invoke-BRAVOSecurityAnalysis.ps1 і ci\Test-BRAVOForbiddenPattern.ps1"
    }

    # T015: статичний конструктор `[T]::new(...)` існує лише з PowerShell
    # 5.0, а маніфести декларують PowerShellVersion = '3.0'. Реальний
    # дефект: Maintenance будував блок успішного сповіщення
    # (NotificationMode=all) через List[string]::new() — на 3.0/4.0 гілка
    # падала б лише в момент надсилання. Той самий AST-детектор і той
    # самий production-набір, що й CI-гейт ci\Test-BRAVOForbiddenPattern.ps1
    # (обидва — з ci\BRAVOAnalyzableFiles.ps1), тож self-test і CI не
    # можуть розійтись у визначенні.
    . (Join-Path $root 'ci\BRAVOAnalyzableFiles.ps1')

    # Детектор не повинен бути ні сліпим, ні шумним: згадка в коментарі,
    # у рядковому літералі та в here-string — НЕ виклик; реальний виклик
    # (включно з регістром 'New') — виклик.
    $staticNewProbePath = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_STATIC_NEW_PROBE_{0}.ps1" -f [guid]::NewGuid().ToString('N'))
    try {
        $staticNewProbeLines = @(
            '# коментар: [Uri]::new($base, $relative)',
            '$text = "[System.Text.StringBuilder]::new()"',
            '$here = @''',
            '[Collections.Generic.List[string]]::new()',
            '''@',
            '$list = New-Object ''System.Collections.Generic.List[string]''',
            '$real = [System.Collections.Generic.List[string]]::New()',
            '$other = [string]::Join(",", @("a"))'
        )
        [IO.File]::WriteAllText($staticNewProbePath, ($staticNewProbeLines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
        $staticNewProbeFindings = @(Find-BRAVOStaticNewInvocation -LiteralPath $staticNewProbePath)
        Test-BRAVOCondition `
            -Condition (
                $staticNewProbeFindings.Count -eq 1 -and
                $staticNewProbeFindings[0].Line -eq 7
            ) `
            -Name "StaticAnalysis/StaticNewDetectorMatchesOnlyRealInvocations" `
            -Failure "Find-BRAVOStaticNewInvocation мав знайти рівно один виклик (рядок 7) і пропустити коментар/рядок/here-string; знайдено: $(@($staticNewProbeFindings | ForEach-Object { '{0}:{1}' -f $_.Line, $_.Text }) -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $staticNewProbePath -Force -ErrorAction SilentlyContinue
    }

    $staticNewProductionFiles = @(Get-BRAVOProductionPowerShellFile -Root $root)
    $staticNewProductionFindings = @(
        foreach ($staticNewProductionFile in $staticNewProductionFiles) {
            Find-BRAVOStaticNewInvocation -LiteralPath $staticNewProductionFile.FullName
        }
    )
    $staticNewScopeNames = @($staticNewProductionFiles | ForEach-Object { $_.Name })
    Test-BRAVOCondition `
        -Condition (
            $staticNewProductionFiles.Count -gt 0 -and
            $staticNewScopeNames -contains 'BRAVO.Maintenance.Runtime.ps1' -and
            $staticNewScopeNames -notcontains 'BRAVO_SELF_TEST.ps1' -and
            $staticNewProductionFindings.Count -eq 0
        ) `
        -Name "StaticAnalysis/NoStaticNewConstructorInProductionCode" `
        -Failure "production PowerShell-код не повинен викликати [T]::new() (потрібен PowerShell 5.0+, маніфести декларують 3.0) — використовуйте New-Object; знайдено: $(@($staticNewProductionFindings | ForEach-Object { '{0}:{1}: {2}' -f $_.Path, $_.Line, $_.Text }) -join ' | ')"

    # --- Інваріанти, спільні для ВСІХ workflow (T022) ---------------------
    # Раніше ASCII-only і pin на SHA перевірялися лише для ci.yml, тож
    # порушення в інших workflow (release-artifact.yml мав кирилицю у
    # `run:`) лишалося непоміченим: той workflow запускається лише від
    # тега, і жоден PR-прогін його не виконує. Перелік файлів береться
    # динамічно, щоб новий workflow потрапляв під ті самі правила без
    # правки тесту. ci.yml-специфічні інваріанти (ExcludeRule,
    # -RequiredVersion PSScriptAnalyzer, виклики ci\*.ps1) лишаються вище
    # і нижче лише на ci.yml.
    #
    # GitHub Actions записує вміст `run:` у тимчасовий .ps1 БЕЗ BOM,
    # і Windows PowerShell 5.1 читає його в системній ANSI-кодовій
    # сторінці — не-ASCII там декодується в сміття, а окремі байти
    # стають control-символами або типографськими лапками, які парсер
    # сприймає як межу рядка. Реальне падіння CI сталося саме через це;
    # гірший варіант — скрипт парситься без помилки, але з іншою
    # структурою (зсунуті лапки ковтають `exit 1`). Логіку з кирилицею
    # тримаємо у файлах репозиторію (мають BOM), а виконувані рядки
    # workflow лишаються ASCII-only. Коментарі й `name:` не виконуються
    # PowerShell-ом, тому їх дозволено.
    $workflowGovFindNonAsciiLines = {
        param([string]$WorkflowText)
        $workflowLines = @($WorkflowText -split '\r?\n')
        for ($lineIndex = 0; $lineIndex -lt $workflowLines.Count; $lineIndex++) {
            $workflowLine = $workflowLines[$lineIndex]
            if ($workflowLine -match '[^\x00-\x7F]' -and
                $workflowLine -notmatch '^\s*#' -and
                $workflowLine -notmatch '^\s*-?\s*name:') {
                "{0}: {1}" -f ($lineIndex + 1), $workflowLine.Trim()
            }
        }
    }
    # Аудит P3: сторонні actions зафіксовані на повний commit SHA, а не
    # на рухомий тег. Тег можна переписати — pin на SHA цього не
    # дозволяє.
    $workflowGovFindUnpinnedActions = {
        param([string]$WorkflowText)
        [regex]::Matches($WorkflowText, 'uses:\s*(?<Ref>[^\r\n]+)') |
            ForEach-Object { $_.Groups['Ref'].Value.Trim() } |
            Where-Object { $_ -notmatch '@[0-9a-f]{40}\b' }
    }

    # Предикати мусять ловити порушення в будь-якому workflow, а не лише
    # в уже відомих: синтетичний новий workflow з кирилицею в `run:` і
    # action на рухомому тезі має бути знайдений, а коментар і `name:` з
    # кирилицею — ні.
    $workflowGovSyntheticText = (@(
        'name: Synthetic new workflow',
        'jobs:',
        '  demo:',
        '    runs-on: windows-latest',
        '    steps:',
        '      # коментар кирилицею дозволений',
        '      - uses: actions/checkout@v4',
        '      - name: Крок з кириличною назвою',
        '        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1',
        '      - shell: powershell',
        '        run: |',
        '          Write-Host "::error::тег не опублікований"',
        '          exit 1'
    ) -join "`r`n")
    $workflowGovSyntheticNonAscii = @(& $workflowGovFindNonAsciiLines $workflowGovSyntheticText)
    $workflowGovSyntheticUnpinned = @(& $workflowGovFindUnpinnedActions $workflowGovSyntheticText)
    Test-BRAVOCondition `
        -Condition (
            $workflowGovSyntheticNonAscii.Count -eq 1 -and
            $workflowGovSyntheticNonAscii[0] -like '12: Write-Host*' -and
            $workflowGovSyntheticUnpinned.Count -eq 1 -and
            $workflowGovSyntheticUnpinned[0] -eq 'actions/checkout@v4'
        ) `
        -Name "StaticAnalysis/WorkflowInvariantsCatchNewWorkflow" `
        -Failure ("предикати workflow-інваріантів мусять ловити синтетичний новий workflow: не-ASCII рядки " +
            "[$($workflowGovSyntheticNonAscii -join ' | ')] (очікується рівно рядок 12), не закріплені actions " +
            "[$($workflowGovSyntheticUnpinned -join ', ')] (очікується рівно actions/checkout@v4)")

    $workflowGovRoot = Join-Path $root ".github\workflows"
    $workflowGovFiles = @(
        if (Test-Path -LiteralPath $workflowGovRoot -PathType Container) {
            Get-ChildItem -LiteralPath $workflowGovRoot -File |
                Where-Object { $_.Extension -eq '.yml' -or $_.Extension -eq '.yaml' } |
                Sort-Object Name
        }
    )
    # Порожній перелік зробив би обидві перевірки нижче зеленими ні на
    # чому. На момент T022 у репозиторії 4 workflow: ci.yml,
    # config-parity.yml, config-v2-pilot-artifact.yml, release-artifact.yml.
    $workflowGovNames = @($workflowGovFiles | ForEach-Object { $_.Name })
    Test-BRAVOCondition `
        -Condition (
            $workflowGovFiles.Count -ge 4 -and
            $workflowGovNames -contains 'ci.yml' -and
            $workflowGovNames -contains 'release-artifact.yml'
        ) `
        -Name "StaticAnalysis/WorkflowEnumerationIsNotEmpty" `
        -Failure "перелік .github\workflows\*.yml|*.yaml має містити щонайменше 4 файли, включно з ci.yml і release-artifact.yml; знайдено: $($workflowGovNames -join ', ')"

    $workflowGovNonAsciiViolations = New-Object System.Collections.Generic.List[string]
    $workflowGovUnpinnedViolations = New-Object System.Collections.Generic.List[string]
    foreach ($workflowGovFile in $workflowGovFiles) {
        $workflowGovText = [IO.File]::ReadAllText($workflowGovFile.FullName, [Text.Encoding]::UTF8)
        foreach ($workflowGovLine in @(& $workflowGovFindNonAsciiLines $workflowGovText)) {
            [void]$workflowGovNonAsciiViolations.Add("$($workflowGovFile.Name):$workflowGovLine")
        }
        foreach ($workflowGovRef in @(& $workflowGovFindUnpinnedActions $workflowGovText)) {
            [void]$workflowGovUnpinnedViolations.Add("$($workflowGovFile.Name): $workflowGovRef")
        }
    }
    Test-BRAVOCondition `
        -Condition ($workflowGovFiles.Count -gt 0 -and $workflowGovNonAsciiViolations.Count -eq 0) `
        -Name "StaticAnalysis/CiRunBlocksAreAsciiOnly" `
        -Failure "workflow: виконуваний не-ASCII рядок поза коментарем/name (GitHub Actions пише run: без BOM, PowerShell 5.1 ламається): $($workflowGovNonAsciiViolations -join ' | ')"
    Test-BRAVOCondition `
        -Condition ($workflowGovFiles.Count -gt 0 -and $workflowGovUnpinnedViolations.Count -eq 0) `
        -Name "StaticAnalysis/ActionsPinnedToCommitSha" `
        -Failure "усі GitHub Actions в усіх workflow мають бути зафіксовані на повний commit SHA; не закріплені: $($workflowGovUnpinnedViolations -join ', ')"

    # Версія PSScriptAnalyzer зафіксована, інакше нове правило або зміна
    # поведінки ламає CI без жодної зміни коду. Аналізатор запускає лише
    # ci.yml, тому інваріант — ci.yml-специфічний.
    if (Test-Path -LiteralPath $ciWorkflowPath -PathType Leaf) {
        Test-BRAVOCondition `
            -Condition ($ciWorkflowText -match 'PSScriptAnalyzer\s+-RequiredVersion\s+\d+\.\d+') `
            -Name "StaticAnalysis/AnalyzerVersionPinned" `
            -Failure "версія PSScriptAnalyzer має бути зафіксована через -RequiredVersion"
    }

    # T030: [Net.ServicePointManager]::SecurityProtocol у production-коді
    # змінюється лише АДИТИВНО (поточне значення -bor прапор). Пряме
    # присвоєння (`= 3072`) мовчки вимикало протоколи, вже ввімкнені
    # хостом (напр. Tls13, Tls11) — так було в Maintenance/DataRestore
    # runtime і dry-run. Канонічна форма — Enable-BRAVOTls12
    # (BRAVO.Compatibility). Аналіз через AST, тож коментарі та рядкові
    # літерали не дають хибних збігів, а багаторядкові присвоєння
    # розпізнаються так само, як однорядкові. Self-test (корінь і
    # selftest\) виключено: він мусить відновлювати початкове значення.
    function Get-BRAVOSelfTestSecurityProtocolOverwrite {
        param(
            [Parameter(Mandatory = $true)][Management.Automation.Language.Ast]$Ast,
            [Parameter(Mandatory = $true)][string]$Label
        )
        $isSecurityProtocolMember = {
            param($node)
            while ($node -is [Management.Automation.Language.ParenExpressionAst]) {
                $node = $node.Pipeline
                if ($node -is [Management.Automation.Language.PipelineAst] -and $node.PipelineElements.Count -eq 1 -and
                    $node.PipelineElements[0] -is [Management.Automation.Language.CommandExpressionAst]) {
                    $node = $node.PipelineElements[0].Expression
                }
            }
            if (-not ($node -is [Management.Automation.Language.MemberExpressionAst]) -or -not $node.Static) { return $false }
            if (-not ($node.Expression -is [Management.Automation.Language.TypeExpressionAst])) { return $false }
            if (-not ($node.Member -is [Management.Automation.Language.StringConstantExpressionAst])) { return $false }
            $typeName = $node.Expression.TypeName.FullName -replace '^(?i)System\.', ''
            return ($typeName -eq 'Net.ServicePointManager' -and $node.Member.Value -eq 'SecurityProtocol')
        }
        $findings = @()
        $assignments = @($Ast.FindAll({
                    param($candidate)
                    $candidate -is [Management.Automation.Language.AssignmentStatementAst]
                }, $true))
        foreach ($assignment in $assignments) {
            if (-not (& $isSecurityProtocolMember $assignment.Left)) { continue }
            $right = $assignment.Right
            if ($right -is [Management.Automation.Language.PipelineAst] -and $right.PipelineElements.Count -eq 1) {
                $right = $right.PipelineElements[0]
            }
            if ($right -is [Management.Automation.Language.CommandExpressionAst]) {
                $right = $right.Expression
            }
            $isAdditive = (
                $assignment.Operator -eq [Management.Automation.Language.TokenKind]::Equals -and
                $right -is [Management.Automation.Language.BinaryExpressionAst] -and
                $right.Operator -eq [Management.Automation.Language.TokenKind]::Bor -and
                ((& $isSecurityProtocolMember $right.Left) -or (& $isSecurityProtocolMember $right.Right))
            )
            if (-not $isAdditive) {
                $findings += "${Label}:$($assignment.Extent.StartLineNumber)"
            }
        }
        return $findings
    }

    $securityProtocolGuardFixtures = @(
        @{ Expected = 1; Text = '[Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)' },
        @{ Expected = 1; Text = "[System.Net.ServicePointManager]::SecurityProtocol =`n    [Net.SecurityProtocolType]::Tls12" },
        @{ Expected = 1; Text = 'function f { [Net.ServicePointManager]::SecurityProtocol = 3072 -bor 768 }' },
        @{ Expected = 0; Text = "[Net.ServicePointManager]::SecurityProtocol =`n    [Net.ServicePointManager]::SecurityProtocol -bor [Enum]::ToObject([Net.SecurityProtocolType], 3072)" },
        @{ Expected = 0; Text = '[System.Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [System.Net.ServicePointManager]::SecurityProtocol' },
        @{ Expected = 0; Text = "# [Net.ServicePointManager]::SecurityProtocol = 3072`n`$x = '[Net.ServicePointManager]::SecurityProtocol = 3072'" }
    )
    $securityProtocolGuardMismatches = @()
    for ($securityProtocolFixtureIndex = 0; $securityProtocolFixtureIndex -lt $securityProtocolGuardFixtures.Count; $securityProtocolFixtureIndex++) {
        $securityProtocolFixture = $securityProtocolGuardFixtures[$securityProtocolFixtureIndex]
        $securityProtocolFixtureAst = [Management.Automation.Language.Parser]::ParseInput(
            $securityProtocolFixture.Text, [ref]$null, [ref]$null)
        $securityProtocolFixtureFindings = @(Get-BRAVOSelfTestSecurityProtocolOverwrite `
                -Ast $securityProtocolFixtureAst -Label "fixture$securityProtocolFixtureIndex")
        if (@($securityProtocolFixtureFindings).Count -ne $securityProtocolFixture.Expected) {
            $securityProtocolGuardMismatches += "fixture$securityProtocolFixtureIndex (очікувано $($securityProtocolFixture.Expected), знайдено $(@($securityProtocolFixtureFindings).Count))"
        }
    }
    Test-BRAVOCondition `
        -Condition ($securityProtocolGuardMismatches.Count -eq 0) `
        -Name "StaticAnalysis/SecurityProtocolGuardDetectsOverwrite" `
        -Failure "AST-guard SecurityProtocol мусить ловити пряме присвоєння (одно- й багаторядкове, [System.Net.]/[Net.]) і пропускати адитивне -bor, коментарі та рядки: $($securityProtocolGuardMismatches -join '; ')"

    $analyzableFilesHelperPath = Join-Path $root 'ci\BRAVOAnalyzableFiles.ps1'
    $securityProtocolOverwrites = @()
    $securityProtocolScannedCount = 0
    if (Test-Path -LiteralPath $analyzableFilesHelperPath -PathType Leaf) {
        . $analyzableFilesHelperPath
        $securityProtocolProductionFiles = @(
            Get-BRAVOAnalyzableFile -Root $root | Where-Object {
                ($_.FullName -replace '/', '\') -notlike '*\selftest\*' -and
                $_.Name -ne 'BRAVO_SELF_TEST.ps1'
            }
        )
        foreach ($securityProtocolProductionFile in $securityProtocolProductionFiles) {
            $securityProtocolProductionAst = [Management.Automation.Language.Parser]::ParseFile(
                $securityProtocolProductionFile.FullName, [ref]$null, [ref]$null)
            $securityProtocolOverwrites += @(Get-BRAVOSelfTestSecurityProtocolOverwrite `
                    -Ast $securityProtocolProductionAst `
                    -Label $securityProtocolProductionFile.FullName)
            $securityProtocolScannedCount++
        }
    }
    Test-BRAVOCondition `
        -Condition ($securityProtocolScannedCount -gt 0 -and $securityProtocolOverwrites.Count -eq 0) `
        -Name "StaticAnalysis/SecurityProtocolAssignmentsAreAdditive" `
        -Failure "production-код мусить вмикати протоколи адитивно ([Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor ... або Enable-BRAVOTls12); пряме присвоєння затирає вже ввімкнені протоколи (перевірено файлів: $securityProtocolScannedCount): $($securityProtocolOverwrites -join ', ')"

    # Аудит P5: threat model як окремий документ із чесним розділом
    # залишкового ризику для кожного сценарію.
    $threatModelPath = Join-Path $root "THREAT_MODEL.md"
    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $threatModelPath -PathType Leaf) `
        -Name "Documentation/ThreatModelExists" `
        -Failure "THREAT_MODEL.md має існувати в корені репозиторію"
    if (Test-Path -LiteralPath $threatModelPath -PathType Leaf) {
        $threatModelText = [IO.File]::ReadAllText($threatModelPath, [Text.Encoding]::UTF8)
        $requiredScenarios = @(
            "Компрометація локального адміністратора",
            "Підміна інструментів",
            "Підміна runtime",
            "Витік облікових даних",
            "Ransomware",
            "VSS",
            "Підміна SFTP/SMB призначення",
            "Rollback",
            "Паралельні запуски"
        )
        $missingScenarios = @(
            $requiredScenarios | Where-Object { -not $threatModelText.Contains($_) }
        )
        Test-BRAVOCondition `
            -Condition ($missingScenarios.Count -eq 0) `
            -Name "Documentation/ThreatModelCoversRequiredScenarios" `
            -Failure "THREAT_MODEL.md має покривати всі сценарії; відсутні: $($missingScenarios -join ', ')"

        # Модель без залишкового ризику — це реклама, а не аналіз.
        Test-BRAVOCondition `
            -Condition (
                ([regex]::Matches($threatModelText, 'Залишковий ризик').Count -ge 8)
            ) `
            -Name "Documentation/ThreatModelStatesResidualRisk" `
            -Failure "кожен сценарій THREAT_MODEL.md має мати явний розділ залишкового ризику"
    }

    # P2.6 аудиту: RELEASE_CHECKLIST.md.
    $releaseChecklistPath = Join-Path $root "RELEASE_CHECKLIST.md"
    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $releaseChecklistPath -PathType Leaf) `
        -Name "Documentation/ReleaseChecklistExists" `
        -Failure "RELEASE_CHECKLIST.md має існувати в корені репозиторію"
    if (Test-Path -LiteralPath $releaseChecklistPath -PathType Leaf) {
        $releaseChecklistText = [IO.File]::ReadAllText($releaseChecklistPath, [Text.Encoding]::UTF8)
        Test-BRAVOCondition `
            -Condition (
                $releaseChecklistText.Contains("VERSION.json") -and
                $releaseChecklistText.Contains("CHANGELOG.md") -and
                $releaseChecklistText.Contains("BRAVO_SELF_TEST.ps1") -and
                $releaseChecklistText.Contains("BOM") -and
                $releaseChecklistText.Contains("tag")
            ) `
            -Name "Documentation/ReleaseChecklistCoversRequiredSteps" `
            -Failure "RELEASE_CHECKLIST.md має покривати VERSION.json, CHANGELOG.md, self-test, BOM і git tag"
    }

    # RELEASE_POLICY.md: яка версія в якій гілці дозволена. Чек-лист
    # відповідає на питання "що зробити перед випуском", політика — на
    # питання "що взагалі дозволено випускати з цієї гілки".
    $releasePolicyPath = Join-Path $root "RELEASE_POLICY.md"
    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $releasePolicyPath -PathType Leaf) `
        -Name "Documentation/ReleasePolicyExists" `
        -Failure "RELEASE_POLICY.md має існувати в корені репозиторію"
    if (Test-Path -LiteralPath $releasePolicyPath -PathType Leaf) {
        $releasePolicyText = [IO.File]::ReadAllText($releasePolicyPath, [Text.Encoding]::UTF8)
        Test-BRAVOCondition `
            -Condition (
                $releasePolicyText.Contains('X.Y.Z-dev.N') -and
                $releasePolicyText.Contains('X.Y.Z-rc.N') -and
                $releasePolicyText.Contains('releaseChannel') -and
                $releasePolicyText.Contains('ci\Test-BRAVOReleasePolicy.ps1') -and
                $releasePolicyText.Contains('ModuleVersion')
            ) `
            -Name "Documentation/ReleasePolicyCoversVersionModel" `
            -Failure "RELEASE_POLICY.md має описувати prerelease-формати (dev/rc), releaseChannel, правило ModuleVersion і CI-gate ci\Test-BRAVOReleasePolicy.ps1"

        # Паритет-harness конфігурації: політика мусить називати його
        # обов'язковим кроком для змін конфігураційного пайплайна. Без
        # цього єдиний доказ збереження повного графа $global: лишається
        # інструментом, про який ніхто не знає (знахідка F4 аудиту
        # 2026-09-14, задача A4 у #154).
        Test-BRAVOCondition `
            -Condition (
                $releasePolicyText.Contains('ci\Test-BRAVOConfigFoundationParity.ps1') -and
                $releasePolicyText.Contains('BRAVO_CONFIG_LOADER.ps1')
            ) `
            -Name "Documentation/ReleasePolicyRequiresConfigParityHarness" `
            -Failure "RELEASE_POLICY.md має називати ci\Test-BRAVOConfigFoundationParity.ps1 обов'язковим кроком для PR, що змінюють конфігураційний пайплайн (BRAVO_CONFIG_LOADER.ps1 та ін.)"
    }

    # Дефолтна база harness-а мусить бути НЕЗМІННИМ комітом, а не іменем
    # гілки: гілку feature/config-foundation-derivation уже влито, і
    # прибирання стале гілок мовчки зламало б інструмент. Перевіряється
    # саме форма дефолту, бо це єдине, що governance може довести без git.
    $parityHarnessPath = Join-Path $root "ci\Test-BRAVOConfigFoundationParity.ps1"
    if (Test-Path -LiteralPath $parityHarnessPath -PathType Leaf) {
        $parityHarnessText = [IO.File]::ReadAllText($parityHarnessPath, [Text.Encoding]::UTF8)
        $parityBaseRefMatch = [regex]::Match($parityHarnessText, '\[string\]\$BaseRef\s*=\s*''([^'']*)''')
        Test-BRAVOCondition `
            -Condition ($parityBaseRefMatch.Success -and $parityBaseRefMatch.Groups[1].Value -match '^[0-9a-f]{40}$') `
            -Name "Governance/ConfigParityHarnessBaseRefIsImmutableCommit" `
            -Failure "дефолтний -BaseRef у ci\Test-BRAVOConfigFoundationParity.ps1 має бути повним SHA-1 коміта, а не іменем гілки (гілку може видалити прибирання стале гілок); отримано: '$(if ($parityBaseRefMatch.Success) { $parityBaseRefMatch.Groups[1].Value } else { '<не знайдено>' })'"
    }

    # Політика, яку ніхто не перевіряє механічно, тримається лише на
    # людській дисципліні — а саме вона вже двічі підвела на
    # fast-forward merge (AUD-016). Тому gate має бути і в репозиторії,
    # і в workflow.
    $releasePolicyGatePath = Join-Path $root 'ci\Test-BRAVOReleasePolicy.ps1'
    $ciWorkflowTextForPolicy = [IO.File]::ReadAllText(
        (Join-Path $root '.github\workflows\ci.yml'),
        [Text.Encoding]::UTF8
    )
    # Шукаємо саме КРОК `run:`, а не згадку шляху будь-де у файлі.
    # Підрядковий пошук був хибним: пояснювальний коментар біля
    # fetch-depth: 0 містить той самий шлях, тому видалення справжнього
    # кроку `run:` лишило б обидва guard-и зеленими — вони перевіряли б
    # наявність коментаря про перевірку замість самої перевірки.
    $releasePolicyRunStepPattern = '(?m)^\s*run:\s*\.\\ci\\Test-BRAVOReleasePolicy\.ps1\s*$'

    Test-BRAVOCondition `
        -Condition (
            (Test-Path -LiteralPath $releasePolicyGatePath -PathType Leaf) -and
            ($ciWorkflowTextForPolicy -match $releasePolicyRunStepPattern)
        ) `
        -Name "ReleasePolicy/CiGateEnforcesBranchVersionChannel" `
        -Failure "ci\Test-BRAVOReleasePolicy.ps1 має існувати і викликатися з .github\workflows\ci.yml — інакше відповідність гілки, версії та каналу тримається лише на пам'яті людини"

    # Перевірка провенансу в ci\Test-BRAVOReleasePolicy.ps1 читає VERSION.json
    # у коміті sourceCommit. При shallow-checkout той коміт недосяжний, і
    # перевірка ТИХО вимикається: гейт лишається в workflow, але перестає
    # щось охороняти. Саме цей клас — «обов'язок без механізму» — уже
    # коштував трьох діб неконсистентного провенансу на developer, тому
    # fetch-depth: 0 тримається тестом, а не домовленістю.
    #
    # Розбираємо блок задачі текстово: у Windows PowerShell 5.1 немає
    # вбудованого YAML-парсера, а тягнути модуль заради однієї перевірки
    # означало б зробити self-test залежним від галереї.
    $releasePolicyJobMatch = [regex]::Match(
        $ciWorkflowTextForPolicy,
        '(?ms)^  static-checks:\r?$(?<Body>.*?)(?=^  [A-Za-z0-9_-]+:\r?$|\z)')
    $releasePolicyJobBody = if ($releasePolicyJobMatch.Success) { $releasePolicyJobMatch.Groups['Body'].Value } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $releasePolicyJobMatch.Success -and
            ($releasePolicyJobBody -match $releasePolicyRunStepPattern) -and
            $releasePolicyJobBody -match '(?m)^\s*fetch-depth:\s*0\s*$'
        ) `
        -Name "Governance/ReleasePolicyJobFetchesFullHistory" `
        -Failure "задача static-checks у .github\workflows\ci.yml має і викликати ci\Test-BRAVOReleasePolicy.ps1, і задавати fetch-depth: 0 — без повної історії перевірка провенансу sourceCommit мовчки вимикається"

    # Функціональна перевірка самого gate-скрипта, а не лише факту його
    # існування. X.Y.Z завжди є підрядком X.Y.Z-dev.N/-rc.N — саме в
    # момент promotion у master, де ця перевірка найважливіша,
    # .Contains() дав би хибний PASS на забутому старому заголовку
    # ("## 4.5.0-dev.1" містить підрядок "4.5.0"). Ізольований мінімальний
    # комплект відтворює обидва випадки: справжнє оновлення і забутий крок.
    $releasePolicyProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_RELEASE_POLICY_PROBE_{0}" -f [guid]::NewGuid().ToString('N'))
    $releasePolicyProbeResults = @{}
    try {
        [void][IO.Directory]::CreateDirectory((Join-Path $releasePolicyProbeRoot 'modules\BRAVO.Fake'))
        # Маркер кореня репозиторію для власної перевірки скрипта; вміст
        # не читається, потрібен лише факт існування файлу.
        [IO.File]::WriteAllText((Join-Path $releasePolicyProbeRoot 'BRAVO_SELF_TEST.ps1'), '', (New-Object Text.UTF8Encoding($true)))
        Copy-Item -LiteralPath (Join-Path $root 'BRAVO_CONFIG_LOADER.ps1') -Destination (Join-Path $releasePolicyProbeRoot 'BRAVO_CONFIG_LOADER.ps1') -Force
        [IO.File]::WriteAllText(
            (Join-Path $releasePolicyProbeRoot 'modules\BRAVO.Fake\BRAVO.Fake.psd1'),
            "@{`r`n    ModuleVersion = '4.5.0'`r`n    GUID = '11111111-1111-1111-1111-111111111111'`r`n    Author = 'BRAVO self-test'`r`n}`r`n",
            (New-Object Text.UTF8Encoding($true))
        )

        function Set-BRAVOReleasePolicyProbeContent {
            param(
                [Parameter(Mandatory = $true)][string]$ProbeRoot,
                [Parameter(Mandatory = $true)][string]$ChangelogHeading,
                [Parameter(Mandatory = $true)][string]$ReadmeHeader,
                # RELEASE_POLICY 5.3: releaseDate звіряється з датою
                # заголовка CHANGELOG.md. Дефолт збігається з датою в
                # заголовках нижче, щоб наявні випадки перевіряли рівно
                # те, що перевіряли; розбіжність задається явно.
                [string]$ReleaseDate = '2026-08-05'
            )
            $utf8NoBom = New-Object Text.UTF8Encoding($false)
            # buildId/sourceCommit: RELEASE_POLICY 7.2 вимагає провенанс, і без
            # нього гейт відмовляє ще до перевірок нижче. Значення синтетичні
            # й самоузгоджені (buildId = перші 7 символів sourceCommit); у
            # probe-корені немає .git, тому звірка провенансу з історією тут
            # лише попереджає — саме те, що треба, щоб ці випадки перевіряли
            # CHANGELOG і заголовки, а не щось інше.
            [IO.File]::WriteAllText((Join-Path $ProbeRoot 'VERSION.json'), ('{{"packageVersion":"4.5.0","releaseChannel":"stable","releaseDate":"{0}","buildId":"0123456","sourceCommit":"0123456789abcdef0123456789abcdef01234567"}}' -f $ReleaseDate), $utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $ProbeRoot 'CHANGELOG.md'), "# Changelog`r`n`r`n$ChangelogHeading`r`n`r`nОпис.`r`n", $utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $ProbeRoot 'README.md'), "$ReadmeHeader`r`n", $utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $ProbeRoot 'BRAVO_SETUP.md'), "$ReadmeHeader`r`n", $utf8NoBom)
        }

        $releasePolicyGateScript = Join-Path $root 'ci\Test-BRAVOReleasePolicy.ps1'
        # Без пониження ErrorActionPreference stderr дочірнього процесу
        # ронить увесь прогін замість чистого [FAIL] (той самий патерн,
        # що й у RuntimeGuard/EntrypointsFailClosedWhenGuardUnloadable).
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # Справжній promotion: CHANGELOG і заголовки дійсно оновлені
            # на stable-версію.
            Set-BRAVOReleasePolicyProbeContent -ProbeRoot $releasePolicyProbeRoot -ChangelogHeading '## 4.5.0 — 2026-08-05' -ReadmeHeader '# BRAVO 4.5.0 — опис'
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $releasePolicyGateScript -Root $releasePolicyProbeRoot -Branch 'master' 2>&1
            $releasePolicyProbeResults['Genuine'] = $LASTEXITCODE

            # Забутий крок promotion: CHANGELOG і заголовки лишились зі
            # старої prerelease-версії.
            Set-BRAVOReleasePolicyProbeContent -ProbeRoot $releasePolicyProbeRoot -ChangelogHeading '## 4.5.0-dev.1 — 2026-08-05' -ReadmeHeader '# BRAVO 4.5.0-dev.1 — опис'
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $releasePolicyGateScript -Root $releasePolicyProbeRoot -Branch 'master' 2>&1
            $releasePolicyProbeResults['StaleFromDev'] = $LASTEXITCODE

            # Дрейф releaseDate: CHANGELOG і заголовки коректні, але
            # VERSION.json несе іншу дату. Рівно так поле й поїхало на
            # developer — лишалось датою штампу 5.3.0-rc.1 через три
            # подальші штампи, і не ловилось нічим.
            Set-BRAVOReleasePolicyProbeContent -ProbeRoot $releasePolicyProbeRoot -ChangelogHeading '## 4.5.0 — 2026-08-05' -ReadmeHeader '# BRAVO 4.5.0 — опис' -ReleaseDate '2026-08-04'
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $releasePolicyGateScript -Root $releasePolicyProbeRoot -Branch 'master' 2>&1
            $releasePolicyProbeResults['StaleReleaseDate'] = $LASTEXITCODE

            # Недатований заголовок stable-версії: звіряти немає з чим,
            # і на master це відмова, а не мовчазний пропуск.
            Set-BRAVOReleasePolicyProbeContent -ProbeRoot $releasePolicyProbeRoot -ChangelogHeading '## 4.5.0 (у розробці)' -ReadmeHeader '# BRAVO 4.5.0 — опис'
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $releasePolicyGateScript -Root $releasePolicyProbeRoot -Branch 'master' 2>&1
            $releasePolicyProbeResults['UndatedStableHeading'] = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorAction
        }
    } finally {
        Remove-Item -LiteralPath $releasePolicyProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Test-BRAVOCondition `
        -Condition ($releasePolicyProbeResults['Genuine'] -eq 0) `
        -Name "ReleasePolicy/AcceptsGenuineStableRelease" `
        -Failure "ci\Test-BRAVOReleasePolicy.ps1 має пропускати комплект, де CHANGELOG.md і заголовки дійсно оновлені на stable-версію (код виходу: $($releasePolicyProbeResults['Genuine']))"

    Test-BRAVOCondition `
        -Condition ($releasePolicyProbeResults['StaleFromDev'] -ne 0) `
        -Name "ReleasePolicy/RejectsStaleChangelogAndHeaderOnPromotion" `
        -Failure "ci\Test-BRAVOReleasePolicy.ps1 має блокувати promotion, якщо CHANGELOG.md і заголовки README.md/BRAVO_SETUP.md лишились зі старої prerelease-версії — X.Y.Z як підрядок X.Y.Z-dev.N не повинен рахуватись збігом; код виходу: $($releasePolicyProbeResults['StaleFromDev'])"

    Test-BRAVOCondition `
        -Condition ($releasePolicyProbeResults['StaleReleaseDate'] -ne 0) `
        -Name "ReleasePolicy/RejectsReleaseDateDriftFromChangelog" `
        -Failure "ci\Test-BRAVOReleasePolicy.ps1 має блокувати комплект, де releaseDate у VERSION.json не збігається з датою заголовка CHANGELOG.md — саме так поле лишалось датою штампу 5.3.0-rc.1 через три подальші штампи; код виходу: $($releasePolicyProbeResults['StaleReleaseDate'])"

    Test-BRAVOCondition `
        -Condition ($releasePolicyProbeResults['UndatedStableHeading'] -ne 0) `
        -Name "ReleasePolicy/RejectsUndatedStableChangelogHeading" `
        -Failure "ci\Test-BRAVOReleasePolicy.ps1 має блокувати promotion, якщо заголовок CHANGELOG.md для stable-версії не датований — звіряти releaseDate немає з чим; код виходу: $($releasePolicyProbeResults['UndatedStableHeading'])"

    # --- Провенанс: sourceCommit має нести ТУ САМУ packageVersion --------
    # Потрібен справжній git-репозиторій: перевірка читає VERSION.json у
    # коміті sourceCommit. Фікстура вище його не має, тому тут окремий
    # тимчасовий репозиторій із двох комітів.
    #
    # Відтворюємо рівно те, що сталося з 5.3.0-dev.3: коміт A несе одну
    # packageVersion, робоче дерево — іншу, а sourceCommit лишився вказувати
    # на A. buildId при цьому узгоджений із sourceCommit, тобто наявний
    # Version/StampConsistency такий стан пропускає.
    $provenanceProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_PROVENANCE_PROBE_{0}" -f [guid]::NewGuid().ToString('N'))
    $provenanceProbeExit = $null
    $provenanceProbeOutput = ''
    $provenanceProbeLimitation = ''
    # Ініціалізація ДО try: під Set-StrictMode звертання до невизначеної
    # змінної нижче замаскувало б справжню причину відмови git. Дефолти —
    # найсуворіші (git не спрацював).
    $gitInitOk = $false
    $probeBaseCommit = ''
    try {
        [void][IO.Directory]::CreateDirectory((Join-Path $provenanceProbeRoot 'modules\BRAVO.Fake'))
        $utf8NoBomProbe = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $provenanceProbeRoot 'BRAVO_SELF_TEST.ps1'), '', (New-Object Text.UTF8Encoding($true)))
        Copy-Item -LiteralPath (Join-Path $root 'BRAVO_CONFIG_LOADER.ps1') -Destination (Join-Path $provenanceProbeRoot 'BRAVO_CONFIG_LOADER.ps1') -Force
        [IO.File]::WriteAllText(
            (Join-Path $provenanceProbeRoot 'modules\BRAVO.Fake\BRAVO.Fake.psd1'),
            "@{`r`n    ModuleVersion = '4.5.0'`r`n    GUID = '22222222-2222-2222-2222-222222222222'`r`n    Author = 'BRAVO self-test'`r`n}`r`n",
            (New-Object Text.UTF8Encoding($true))
        )
        foreach ($documentName in @('README.md', 'BRAVO_SETUP.md')) {
            [IO.File]::WriteAllText((Join-Path $provenanceProbeRoot $documentName), "# BRAVO 4.5.0 — опис`r`n", $utf8NoBomProbe)
        }
        [IO.File]::WriteAllText(
            (Join-Path $provenanceProbeRoot 'CHANGELOG.md'),
            "# Changelog`r`n`r`n## 4.5.0 — 2026-08-05`r`n`r`nОпис.`r`n",
            $utf8NoBomProbe)

        # Коміт A: packageVersion 4.4.0 (СТАРА версія лінії).
        [IO.File]::WriteAllText(
            (Join-Path $provenanceProbeRoot 'VERSION.json'),
            '{"packageVersion":"4.4.0","releaseChannel":"stable","releaseDate":"2026-08-05"}',
            $utf8NoBomProbe)

        $previousErrorActionForGit = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # -c замість git config: ідентичність коммітера на раннері може
            # бути не задана, і тоді git відмовить створювати коміт.
            # Гілку фікстури задаємо ЯВНО. Без цього на машині з
            # init.defaultBranch=developer фікстура опинилась би на
            # developer, перехресна перевірка каналу з .git/HEAD дала б
            # 'development' проти 'stable' у VERSION.json, і скрипт вийшов
            # би ненульовим ЧЕРЕЗ КАНАЛ — тобто тест лишався б зеленим
            # навіть із повністю зламаною перевіркою провенансу.
            $null = & git -C $provenanceProbeRoot -c init.defaultBranch=master init --quiet 2>&1
            $gitInitOk = ($LASTEXITCODE -eq 0)
            if ($gitInitOk) {
                $null = & git -C $provenanceProbeRoot add -A 2>&1
                $null = & git -C $provenanceProbeRoot -c user.email='selftest@bravo.local' -c user.name='BRAVO self-test' commit -m 'probe base' --quiet 2>&1
                $gitInitOk = ($LASTEXITCODE -eq 0)
            }
            if ($gitInitOk) {
                $probeBaseCommit = (& git -C $provenanceProbeRoot rev-parse HEAD 2>&1 | Out-String).Trim()
                $gitInitOk = ($LASTEXITCODE -eq 0 -and $probeBaseCommit -match '^[0-9a-f]{40}$')
            }
        } finally {
            $ErrorActionPreference = $previousErrorActionForGit
        }

        if (-not $gitInitOk) {
            $provenanceProbeLimitation = 'git недоступний або не може створити коміт у тимчасовому репозиторії'
        } else {
            # Робоче дерево: packageVersion 4.5.0, а провенанс лишився від
            # коміта A (4.4.0). buildId узгоджений із sourceCommit навмисно.
            [IO.File]::WriteAllText(
                (Join-Path $provenanceProbeRoot 'VERSION.json'),
                ('{{"packageVersion":"4.5.0","releaseChannel":"stable","releaseDate":"2026-08-05","buildId":"{0}","sourceCommit":"{1}"}}' -f $probeBaseCommit.Substring(0, 7), $probeBaseCommit),
                $utf8NoBomProbe)

            $previousErrorActionForProbe = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $provenanceProbeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'ci\Test-BRAVOReleasePolicy.ps1') -Root $provenanceProbeRoot -Branch 'master' 2>&1 | Out-String
                $provenanceProbeExit = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousErrorActionForProbe
            }
        }
    } finally {
        Remove-Item -LiteralPath $provenanceProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Test-BRAVOCondition `
        -Condition (
            $null -ne $provenanceProbeExit -and
            $provenanceProbeExit -ne 0 -and
            $provenanceProbeOutput.Contains('RELEASE_POLICY 7.2')
        ) `
        -Name "ReleasePolicy/RejectsProvenanceFromDifferentVersion" `
        -EnvironmentLimitation $provenanceProbeLimitation `
        -Failure "ci\Test-BRAVOReleasePolicy.ps1 має блокувати комплект, де VERSION.json у коміті sourceCommit несе іншу packageVersion, і назвати саме цю причину (маркер 'RELEASE_POLICY 7.2'), а не вийти ненульовим через щось інше; код виходу: $provenanceProbeExit"

    # --- Володіння шляхом legacy BRAVO.config у self-test (#154, B4-2) ---
    # Кореневий BRAVO.config зникне з пакета на кроці B4-2. Доки кожне
    # місце будувало шлях самостійно, той крок означав переписати
    # фікстурну тканину ОДНОЧАСНО зі зміною runtime-контракту — саме тому
    # #154 і вважав його заблокованим.
    #
    # Тепер шлях знає рівно одна функція, і guard тримає це: у
    # BRAVO_SELF_TEST.ps1 допускається РІВНО одне входження (тіло
    # Get-BRAVOSelfTestLegacyConfigPath), у фрагментах — жодного.
    #
    # Сам цей файл виключено зі сканування: він містить шаблон як
    # рядковий літерал і інакше ловив би сам себе. Компроміс свідомий —
    # альтернатива (складніші межі сканування) коштувала б більше, ніж
    # дає.
    # Шаблон ловить співпадіння в ОДНОМУ РЯДКУ посилання на корінь
    # репозиторію ($root / $PSScriptRoot) з іменем BRAVO.config — у будь-
    # якому порядку. Це покриває позиційний Join-Path, іменовані
    # параметри (-Path/-ChildPath, у будь-якій послідовності) та
    # інтерполяцію, зокрема через вкладений вираз з екрануванням лапок:
    # саме остання форма пройшла повз першу редакцію guard-а, і перевірка
    # тоді звітувала PASS при живій прямій залежності.
    #
    # Межа чесна й названа: розрив виразу на кілька рядків шаблон не
    # ловить. Це defence-in-depth, а не останній рубіж — остаточну
    # відповідь дає сам крок B4-2, де зниклий файл валить будь-яке
    # уціліле пряме читання. Точніший варіант — розбір AST — свідомо не
    # вводиться тут: він коштує більше коду, ніж дає понад це.
    #
    # $scenarioRoot і подібні НЕ ловляться: \$root вимагає, щоб одразу
    # після $ ішло саме "root", а \b відсікає $rootSomething.
    # (?<!`) відсікає ЕКРАНОВАНИЙ долар: `$PSScriptRoot усередині
    # подвійних лапок — це літерал у тексті про код (наприклад у
    # -Failure іншого guard-а), а не звернення до змінної. Без цього
    # шаблон рахував два таких описи як живі залежності.
    #
    # ІМ'Я ФАЙЛУ звіряється РЕГІСТРОНЕЗАЛЕЖНО: цільова ФС регістру не
    # розрізняє, тож Join-Path $root 'bravo.config' читається успішно, а
    # статичні перевантаження [regex]::Matches/IsMatch за замовчуванням
    # регістрочутливі — без (?i:...) guard звітував би PASS при живій
    # прямій залежності.
    #
    # Ціна — обов'язкова МЕЖА імені файлу: без неї "BRAVO.config" збігся б
    # усередині "BRAVO.Configuration" (modules\BRAVO.Configuration\...),
    # якого тут багато. (?![A-Za-z0-9_]) вимагає, щоб після "config" не
    # йшов символ імені; у реальних посиланнях там лапка або роздільник.
    #
    # ІМ'Я ЗМІННОЇ, навпаки, лишається регістрочутливим, хоч змінні
    # PowerShell регістру не розрізняють. Це СВІДОМИЙ вибір, перевірений
    # на фактичному файлі: з (?i) на весь шаблон з'являється четвертий
    # збіг — $fixtureConfigPath = Join-Path $Root 'BRAVO.config' у
    # New-BRAVOProductionConfigFixtureResult, де $Root — ПАРАМЕТР функції
    # (тимчасовий fixture-корінь), а не корінь репозиторію. Тобто guard
    # падав би на коректному коді. Конвенція цього файлу: $root —
    # репозиторій, $Root — локальний параметр фікстури.
    $legacyConfigRootReference = '(?<!`)\$(root|PSScriptRoot)\b'
    $legacyConfigFileReference = '(?i:BRAVO\.config)(?![A-Za-z0-9_])'
    $legacyConfigPathPattern = ('({0}[^\r\n]{{0,80}}{1})|({1}[^\r\n]{{0,80}}{0})' -f $legacyConfigRootReference, $legacyConfigFileReference)
    $legacyConfigOwnerText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_SELF_TEST.ps1'), [Text.Encoding]::UTF8)
    $legacyConfigOwnerMatches = @([regex]::Matches($legacyConfigOwnerText, $legacyConfigPathPattern))
    $legacyConfigOwnerHits = $legacyConfigOwnerMatches.Count

    # Самої КІЛЬКОСТІ замало: якби одне з легальних посилань прибрали, а
    # натомість додали пряме читання деінде, лічильник лишився б 2 і guard
    # звітував би PASS при живому обході. Тому звіряються самі РЯДКИ, у
    # яких стався збіг.
    # Порівняння -ceq, а не -eq: рядкові оператори PowerShell за
    # замовчуванням регістронезалежні, тож зміна регістру в тілі
    # власника проїхала б повз звірку.
    $legacyConfigOwnerLines = @(
        $legacyConfigOwnerMatches | ForEach-Object {
            $matchIndex = $_.Index
            $lineStart = $legacyConfigOwnerText.LastIndexOf("`n", $matchIndex) + 1
            $lineEnd = $legacyConfigOwnerText.IndexOf("`n", $matchIndex)
            if ($lineEnd -lt 0) { $lineEnd = $legacyConfigOwnerText.Length }
            $legacyConfigOwnerText.Substring($lineStart, $lineEnd - $lineStart).Trim()
        } | Sort-Object -Unique
    )
    $legacyConfigExpectedLines = @(
        '$ConfigPath = Join-Path $root "BRAVO.config"'
    ) | Sort-Object -Unique
    $legacyConfigOwnerLinesText = [string]::Join(' | ', $legacyConfigOwnerLines)
    $legacyConfigExpectedLinesText = [string]::Join(' | ', $legacyConfigExpectedLines)

    $legacyConfigFragmentOffenders = New-Object System.Collections.ArrayList
    foreach ($fragmentFile in @(Get-ChildItem -LiteralPath (Join-Path $root 'selftest') -Filter '*.ps1' -File)) {
        if ($fragmentFile.Name -eq 'BRAVO_SELF_TEST.Governance.ps1') { continue }
        $fragmentText = [IO.File]::ReadAllText($fragmentFile.FullName, [Text.Encoding]::UTF8)
        if ([regex]::IsMatch($fragmentText, $legacyConfigPathPattern)) {
            [void]$legacyConfigFragmentOffenders.Add($fragmentFile.Name)
        }
    }

    # Рівно ТРИ легальні входження в кореневому файлі — три РІЗНІ
    # відповідальності, а не дублі:
    #   1) тіло Get-BRAVOSelfTestLegacyConfigPath — джерело legacy-тексту
    #      для фікстур (клас A). На B4-2 перейде на заморожений актив;
    #   2) тіло Get-BRAVOSelfTestShippedConfigPath — конфігурація, ЩО
    #      ВІДВАНТАЖУЄТЬСЯ, для тверджень про пакет (клас B). На B4-2
    #      перейде на канонічні дефолти, тобто В ІНШИЙ бік, ніж (1);
    #   3) дефолт -ConfigPath — ОПЕРАЦІЙНИЙ конфіг, з якого виводиться
    #      $configRoot і поруч з яким мусить лежати BRAVO_CONFIG_LOADER.ps1.
    #
    # Кожне злиття цих ролей уже було помилкою в цьому ж PR: (1)+(3) дало
    # б "Configuration loader not found" на старті, (1)+(2) — мовчазну
    # втрату покриття тверджень про пакет.
    #
    # B4-2 ВИКОНАНО (issue #216, Wave B): кореневий BRAVO.config прибрано
    # з git-tracking і з пакета. Get-BRAVOSelfTestLegacyConfigPath і
    # Get-BRAVOSelfTestShippedConfigPath тепер повертають шлях до
    # замороженого тестового активу (selftest\fixtures\
    # BravoConfigLegacyFrozen.config) — їхні тіла більше НЕ згадують
    # $root поруч з "BRAVO.config" (ім'я fixture-файлу навмисно не
    # містить літералу "BRAVO.config", тож і не збігається з цим
    # patterns). Лишається рівно ОДНЕ легітимне посилання — дефолт
    # -ConfigPath (операційний конфіг комплекту, якого це прибирання не
    # стосується: оператор і сьогодні може покласти явний BRAVO.config
    # поруч з entrypoint-ом через -ConfigPath).
    Test-BRAVOCondition `
        -Condition (
            $legacyConfigOwnerHits -eq 1 -and
            $legacyConfigOwnerLinesText -ceq $legacyConfigExpectedLinesText -and
            $legacyConfigFragmentOffenders.Count -eq 0
        ) `
        -Name "Governance/LegacyConfigPathHasSingleOwner" `
        -Failure "у BRAVO_SELF_TEST.ps1 дозволене рівно одне посилання на кореневий BRAVO.config (дефолт -ConfigPath; B4-2 прибрав файл з пакета, тож accessor-и фікстур більше не читають кореневий шлях), у фрагментах — жодного. Знайдено: $legacyConfigOwnerHits у корені, $($legacyConfigFragmentOffenders.Count) у фрагментах ($([string]::Join(', ', $legacyConfigFragmentOffenders.ToArray()))). Рядки збігів: [$legacyConfigOwnerLinesText]; очікувані: [$legacyConfigExpectedLinesText]"

    # --- Провенанс артефакту: sourceCommit описує САМЕ спаковане дерево ---
    # #199. Форма sourceCommit і рівність packageVersion нічого не кажуть
    # про вміст: перештампування однієї версії штатне, тому залишений
    # старий sourceCommit проходив би обидві перевірки. Інваріант
    # ci\New-BRAVOReleaseArtifact.ps1: між sourceCommit і комітом архіву
    # відрізняються РІВНО VERSION.json і RUNTIME_MANIFEST.json.
    #
    # Перевірка провенансу в скрипті стоїть ДО git archive, тому фікстурі
    # не потрібен справжній комплект: негативний випадок падає саме на
    # ній, а позитивний — гарантовано ПІСЛЯ неї, і це й перевіряється
    # (відсутність маркера), а не код виходу.
    #
    # Маркери PROVENANCE_* свідомо ASCII: stderr дочірнього процесу
    # кодується кодовою сторінкою консолі (CP437/CP866), і кириличний
    # Contains давав би хибний результат залежно від chcp.
    $artifactProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_ARTIFACT_PROV_{0}" -f [guid]::NewGuid().ToString('N'))
    $artifactProbeStale = ''
    $artifactProbeFresh = ''
    $artifactProbeLimitation = ''
    $artifactProbeReady = $false
    try {
        [void][IO.Directory]::CreateDirectory($artifactProbeRoot)
        $utf8NoBomArtifact = New-Object Text.UTF8Encoding($false)
        $writeProbeVersion = {
            param([string]$SourceCommit)
            [IO.File]::WriteAllText(
                (Join-Path $artifactProbeRoot 'VERSION.json'),
                ('{{"product":"BRAVO-Toolkit","packageVersion":"4.5.0","releaseChannel":"stable","releaseDate":"2026-08-05","buildId":"{0}","sourceCommit":"{1}"}}' -f $SourceCommit.Substring(0, 7), $SourceCommit),
                $utf8NoBomArtifact)
        }

        $previousErrorActionArtifact = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = & git -C $artifactProbeRoot -c init.defaultBranch=master init --quiet 2>&1
            if ($LASTEXITCODE -eq 0) {
                [IO.File]::WriteAllText((Join-Path $artifactProbeRoot 'code.txt'), "v1`r`n", $utf8NoBomArtifact)
                [IO.File]::WriteAllText((Join-Path $artifactProbeRoot 'RUNTIME_MANIFEST.json'), "{}`r`n", $utf8NoBomArtifact)
                & $writeProbeVersion '0000000000000000000000000000000000000000'
                $null = & git -C $artifactProbeRoot add -A 2>&1
                $null = & git -C $artifactProbeRoot -c user.email='selftest@bravo.local' -c user.name='BRAVO self-test' commit -m 'code' --quiet 2>&1
                $artifactProbeBase = (& git -C $artifactProbeRoot rev-parse HEAD 2>&1 | Out-String).Trim()
                $artifactProbeReady = ($LASTEXITCODE -eq 0 -and $artifactProbeBase -match '^[0-9a-f]{40}$')
            }

            if ($artifactProbeReady) {
                # ЧИСТИЙ штамп: відносно бази змінені лише два метаданих файли.
                & $writeProbeVersion $artifactProbeBase
                [IO.File]::WriteAllText((Join-Path $artifactProbeRoot 'RUNTIME_MANIFEST.json'), "{ }`r`n", $utf8NoBomArtifact)
                $null = & git -C $artifactProbeRoot add -A 2>&1
                $null = & git -C $artifactProbeRoot -c user.email='selftest@bravo.local' -c user.name='BRAVO self-test' commit -m 'stamp' --quiet 2>&1
                $artifactProbeFresh = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'ci\New-BRAVOReleaseArtifact.ps1') -RepositoryRoot $artifactProbeRoot -Ref 'HEAD' -OutputDir (Join-Path $artifactProbeRoot 'out') 2>&1 | Out-String

                # СТАЛЕ: штамп зачіпає ще й код, тобто провенанс його не описує.
                [IO.File]::WriteAllText((Join-Path $artifactProbeRoot 'code.txt'), "v2`r`n", $utf8NoBomArtifact)
                $null = & git -C $artifactProbeRoot add -A 2>&1
                $null = & git -C $artifactProbeRoot -c user.email='selftest@bravo.local' -c user.name='BRAVO self-test' commit -m 'stale stamp' --quiet 2>&1
                $artifactProbeStale = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'ci\New-BRAVOReleaseArtifact.ps1') -RepositoryRoot $artifactProbeRoot -Ref 'HEAD' -OutputDir (Join-Path $artifactProbeRoot 'out') 2>&1 | Out-String
            } else {
                $artifactProbeLimitation = 'git недоступний або не може створити коміт у тимчасовому репозиторії'
            }
        } finally {
            $ErrorActionPreference = $previousErrorActionArtifact
        }
    } finally {
        Remove-Item -LiteralPath $artifactProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Test-BRAVOCondition `
        -Condition ($artifactProbeStale.Contains('PROVENANCE_STALE')) `
        -Name "ReleaseArtifact/RejectsStaleProvenanceContent" `
        -EnvironmentLimitation $artifactProbeLimitation `
        -Failure "ci\New-BRAVOReleaseArtifact.ps1 має відмовляти, коли між sourceCommit і комітом архіву змінені не лише VERSION.json і RUNTIME_MANIFEST.json (маркер PROVENANCE_STALE); вивід: $artifactProbeStale"

    Test-BRAVOCondition `
        -Condition (-not $artifactProbeFresh.Contains('PROVENANCE_STALE')) `
        -Name "ReleaseArtifact/AcceptsCleanStampProvenance" `
        -EnvironmentLimitation $artifactProbeLimitation `
        -Failure "ci\New-BRAVOReleaseArtifact.ps1 НЕ має відхиляти чистий коміт-штамп (змінені лише VERSION.json і RUNTIME_MANIFEST.json); вивід: $artifactProbeFresh"

    # ROADMAP P0.2: гейт master-промоції має вимагати СЕМАНТИЧНЕ збільшення
    # stable-версії, а не лише нерівність рядків (стара реалізація
    # пропускала downgrade і prerelease). Реальна функція екстрагується з
    # канонічного ci-скрипта — жодної другої копії правила.
    $masterMergePolicyText = [IO.File]::ReadAllText(
        (Join-Path $root "ci\Test-BRAVOMasterMergePolicy.ps1"),
        [Text.Encoding]::UTF8
    )
    $stableVersionModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $masterMergePolicyText `
        -FunctionNames @('Test-BRAVOStableVersionPromotion', 'Test-BRAVOMasterMergeSource')
    $stableVersionScenarios = @(
        @{ Head = '5.2.0';      Master = '5.1.0';   ExpectFailures = 0; Label = 'GenuineIncrease' }
        @{ Head = '5.2.1';      Master = '5.2.0';   ExpectFailures = 0; Label = 'PatchIncrease' }
        @{ Head = '5.3.0';      Master = '5.2.9';   ExpectFailures = 0; Label = 'MinorRolloverIncrease' }
        @{ Head = '5.10.0';     Master = '5.9.0';   ExpectFailures = 0; Label = 'SemanticNotLexical' }
        @{ Head = '5.2.0';      Master = '';        ExpectFailures = 0; Label = 'NoMasterVersionYet' }
        @{ Head = '5.2.0-rc.9'; Master = '5.1.0';   ExpectFailures = 1; Label = 'PrereleaseRejected' }
        @{ Head = '5.1.0';      Master = '5.1.0';   ExpectFailures = 1; Label = 'SameVersionRejected' }
        @{ Head = '5.0.9';      Master = '5.1.0';   ExpectFailures = 1; Label = 'DowngradeRejected' }
        @{ Head = '5.2.0';      Master = 'garbage'; ExpectFailures = 1; Label = 'UnparsableMasterFailsClosed' }
    )
    foreach ($scenario in $stableVersionScenarios) {
        $scenarioFailures = @(& $stableVersionModule {
            param($HeadVersion, $MasterVersion)
            Test-BRAVOStableVersionPromotion -HeadPackageVersion $HeadVersion -MasterPackageVersion $MasterVersion
        } $scenario.Head $scenario.Master)
        Test-BRAVOCondition `
            -Condition (@($scenarioFailures).Count -eq [int]$scenario.ExpectFailures) `
            -Name "ReleasePolicy/StableVersionPromotion[$($scenario.Label)]" `
            -Failure "Test-BRAVOStableVersionPromotion('$($scenario.Head)' vs '$($scenario.Master)') має дати $($scenario.ExpectFailures) порушень; отримано $(@($scenarioFailures).Count): $($scenarioFailures -join ' | ')"
    }

    # ROADMAP P0.2 (repository identity): ім'я head-гілки не ідентифікує
    # репозиторій — fork з гілкою 'developer'/'hotfix/*' не повинен
    # проходити гейт промоції в master. Невизначений head-репозиторій —
    # теж FAIL (fail-closed), а не мовчазний skip. Та сама екстракція з
    # канонічного ci-скрипта — жодної другої копії правила.
    $mergeSourceScenarios = @(
        @{ HeadRef = 'developer';   HeadRepo = 'ekucher/BRAVO-Toolkit'; BaseRepo = 'ekucher/BRAVO-Toolkit'; ExpectFailures = 0; Label = 'SameRepoDeveloper' }
        @{ HeadRef = 'hotfix/x';    HeadRepo = 'ekucher/BRAVO-Toolkit'; BaseRepo = 'ekucher/BRAVO-Toolkit'; ExpectFailures = 0; Label = 'SameRepoHotfix' }
        @{ HeadRef = 'developer';   HeadRepo = 'EKUCHER/BRAVO-TOOLKIT'; BaseRepo = 'ekucher/BRAVO-Toolkit'; ExpectFailures = 0; Label = 'SameRepoCaseInsensitive' }
        @{ HeadRef = 'feature/x';   HeadRepo = 'ekucher/BRAVO-Toolkit'; BaseRepo = 'ekucher/BRAVO-Toolkit'; ExpectFailures = 1; Label = 'SameRepoFeatureRejected' }
        @{ HeadRef = 'developer';   HeadRepo = 'attacker/BRAVO-Toolkit'; BaseRepo = 'ekucher/BRAVO-Toolkit'; ExpectFailures = 1; Label = 'ForkDeveloperRejected' }
        @{ HeadRef = 'hotfix/x';    HeadRepo = 'attacker/BRAVO-Toolkit'; BaseRepo = 'ekucher/BRAVO-Toolkit'; ExpectFailures = 1; Label = 'ForkHotfixRejected' }
        @{ HeadRef = 'developer';   HeadRepo = '';                       BaseRepo = 'ekucher/BRAVO-Toolkit'; ExpectFailures = 1; Label = 'UnknownHeadRepoFailsClosed' }
        @{ HeadRef = 'feature/x';   HeadRepo = 'attacker/BRAVO-Toolkit'; BaseRepo = 'ekucher/BRAVO-Toolkit'; ExpectFailures = 2; Label = 'ForkFeatureBothViolations' }
    )
    foreach ($scenario in $mergeSourceScenarios) {
        $scenarioFailures = @(& $stableVersionModule {
            param($ScenarioHeadRef, $ScenarioHeadRepo, $ScenarioBaseRepo)
            Test-BRAVOMasterMergeSource -HeadRef $ScenarioHeadRef -HeadRepository $ScenarioHeadRepo -BaseRepository $ScenarioBaseRepo
        } $scenario.HeadRef $scenario.HeadRepo $scenario.BaseRepo)
        Test-BRAVOCondition `
            -Condition (@($scenarioFailures).Count -eq [int]$scenario.ExpectFailures) `
            -Name "ReleasePolicy/MasterMergeSource[$($scenario.Label)]" `
            -Failure "Test-BRAVOMasterMergeSource('$($scenario.HeadRef)' з '$($scenario.HeadRepo)' у '$($scenario.BaseRepo)') має дати $($scenario.ExpectFailures) порушень; отримано $(@($scenarioFailures).Count): $($scenarioFailures -join ' | ')"
    }

    # Пастка циклу 5.2.0-rc: збірник артефакту навмисно лишає
    # artifacts\release\staging (повну копію комплекту), і без виключення
    # каталогу генератор маніфесту вносив staging-дублікати -> exit 33 на
    # сервері. Виключення має лишатись у патерні назавжди.
    $runtimeManifestGeneratorText = [IO.File]::ReadAllText(
        (Join-Path $root "ci\Update-BRAVORuntimeManifest.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition ($runtimeManifestGeneratorText -match '\$excludedDirectoryPattern\s*=\s*''[^'']*\|artifacts\)') `
        -Name "ReleasePolicy/RuntimeManifestGeneratorExcludesArtifacts" `
        -Failure "ci\Update-BRAVORuntimeManifest.ps1 має виключати каталог artifacts\ з enumeration (staging збірки артефакту — повна копія комплекту, її потрапляння в маніфест ламає розгортання кодом 33)"

    # P2.7 аудиту: дрібні зауваження документації. Дерево каталогів мало
    # дублікат "BRAVO_*.ps1" двома окремими рядками; додано матрицю
    # діагностики за кодом завершення (розділ 12).
    $readmeTextForDocFixes = [IO.File]::ReadAllText(
        (Join-Path $root "README.md"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            ([regex]::Matches($readmeTextForDocFixes, [regex]::Escape('BRAVO_*.ps1')).Count -eq 0) -and
            $readmeTextForDocFixes.Contains("credentialInitializationError") -and
            $readmeTextForDocFixes.Contains('| `31` |') -and
            $readmeTextForDocFixes.Contains('| `90` |')
        ) `
        -Name "Documentation/ReadmeDirectoryTreeAndTroubleshootingMatrix" `
        -Failure "README.md не повинен містити дублікат-заглушку 'BRAVO_*.ps1' і має містити матрицю діагностики за кодом завершення"

    # Зовнішнє рев'ю 2026-08-05, P1: README описував модель довіри до Tools
    # як trust-on-first-use і радив "видаліть TOOLS_INTEGRITY.json, щоб
    # прийняти нову базову лінію". Код на той момент уже блокував запуск за
    # TOOLS_MANIFEST.json. Небезпека не теоретична: адміністратор, який
    # після security-алерту сумлінно виконає застарілу інструкцію, власноруч
    # легітимізує підмінений бінарник. Документація не повинна пропонувати
    # процедуру, яка вимикає діючий контроль безпеки.
    Test-BRAVOCondition `
        -Condition (
            $readmeTextForDocFixes.Contains("TOOLS_MANIFEST.json") -and
            $readmeTextForDocFixes.Contains("Enforce") -and
            $readmeTextForDocFixes.Contains("Update-BRAVOToolsManifest.ps1")
        ) `
        -Name "Documentation/ReadmeDescribesManifestToolTrust" `
        -Failure "README.md має описувати саме TOOLS_MANIFEST.json + режим Enforce як модель довіри до Tools, із посиланням на ci\Update-BRAVOToolsManifest.ps1"

    # Та сама вимога з іншого боку: README не має радити видалення жодного
    # з маніфестів як спосіб "полагодити" помилку цілісності.
    Test-BRAVOCondition `
        -Condition (
            -not [regex]::IsMatch(
                $readmeTextForDocFixes,
                '(?i)видал[а-яіїєґ]*\s+(файл\s+)?`?(TOOLS_INTEGRITY|TOOLS_MANIFEST|RUNTIME_MANIFEST)'
            )
        ) `
        -Name "Documentation/ReadmeNeverAdvisesDeletingManifest" `
        -Failure "README.md не повинен радити видаляти маніфест цілісності — це вимикає перевірку, а не усуває причину"

    # Зовнішнє рев'ю 2026-08-05, P1: SECURITY.md публікував порядок
    # повідомлення про вразливості із заглушками "[заповнити]" замість SLA.
    # Політика без строків не є політикою.
    $securityTextForContact = [IO.File]::ReadAllText(
        (Join-Path $root "SECURITY.md"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (-not $securityTextForContact.Contains("[заповнити]")) `
        -Name "Documentation/SecurityPolicyHasNoPlaceholders" `
        -Failure "SECURITY.md не повинен містити заглушок '[заповнити]' — контакт і строки реакції мають бути конкретними"

    # Зовнішнє рев'ю 2026-08-05: операторський runbook. README пояснює, як
    # налаштувати; OPERATIONS.md — що робити, коли вже зламалось. Найдорожча
    # помилка в історії цього репозиторію (застаріла порада видалити
    # TOOLS_INTEGRITY.json) належала саме до категорії "чого не робити", якої
    # в документації не існувало як окремого розділу.
    $operationsPath = Join-Path $root "OPERATIONS.md"
    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $operationsPath -PathType Leaf) `
        -Name "Documentation/OperationsRunbookExists" `
        -Failure "OPERATIONS.md має існувати в корені репозиторію"
    if (Test-Path -LiteralPath $operationsPath -PathType Leaf) {
        $operationsText = [IO.File]::ReadAllText($operationsPath, [Text.Encoding]::UTF8)

        # Кожен код контракту BRAVO.ExitCodes, який реально може побачити
        # оператор, повинен мати розділ у runbook. 0 і 10 — успішні, їх не
        # діагностують; решта означає, що щось потребує рішення людини.
        $runbookCodes = @('20', '30', '31', '32', '33', '34', '35', '40', '41', '50', '51', '60', '70', '90')
        $missingCodes = @(
            $runbookCodes | Where-Object { -not $operationsText.Contains("## ``$_`` —") }
        )
        Test-BRAVOCondition `
            -Condition ($missingCodes.Count -eq 0) `
            -Name "Documentation/OperationsRunbookCoversAllExitCodes" `
            -Failure "OPERATIONS.md має мати розділ для кожного коду завершення; відсутні: $($missingCodes -join ', ')"

        # Runbook без "чого не робити" — це переказ README іншими словами.
        # Саме цей розділ відрізняє його від матриці діагностики.
        Test-BRAVOCondition `
            -Condition (
                ([regex]::Matches($operationsText, '(?i)Чого (категорично )?не робити').Count -ge 8)
            ) `
            -Name "Documentation/OperationsRunbookStatesWhatNotToDo" `
            -Failure "OPERATIONS.md має містити розділ 'Чого не робити' для більшості сценаріїв — саме він відрізняє runbook від переліку симптомів"

        # Сценарії поза кодами завершення, які рев'ю вимагало окремо.
        $runbookScenarios = @(
            'ransomware',
            'Відновлення на чистий сервер',
            'Discovery',
            'fingerprint',
            'VSS',
            'SYSTEM'
        )
        $missingScenarios = @(
            $runbookScenarios | Where-Object { -not $operationsText.Contains($_) }
        )
        Test-BRAVOCondition `
            -Condition ($missingScenarios.Count -eq 0) `
            -Name "Documentation/OperationsRunbookCoversCriticalScenarios" `
            -Failure "OPERATIONS.md має покривати сценарії поза кодами завершення; відсутні: $($missingScenarios -join ', ')"

        # Та сама заборона, що й для README, але runbook читають саме в стані
        # інциденту — там порада видалити маніфест найнебезпечніша. Проста
        # заборона підрядка тут не працює: сам runbook мусить писати "не
        # видаляти TOOLS_MANIFEST.json". Тому перевіряємо кожне входження
        # окремо й вимагаємо, щоб перед ним стояло заперечення.
        $deleteManifestMentions = [regex]::Matches(
            $operationsText,
            '(?i)(?<negation>не\s+)?видал[а-яіїєґ]*[\s*`]+(файл[\s*`]+)?(TOOLS_INTEGRITY|TOOLS_MANIFEST|RUNTIME_MANIFEST)'
        )
        $affirmativeDeleteAdvice = @(
            $deleteManifestMentions | Where-Object { -not $_.Groups['negation'].Success }
        )
        Test-BRAVOCondition `
            -Condition ($affirmativeDeleteAdvice.Count -eq 0) `
            -Name "Documentation/OperationsRunbookNeverAdvisesDeletingManifest" `
            -Failure "OPERATIONS.md не повинен радити видаляти маніфест цілісності; знайдено без заперечення: $(($affirmativeDeleteAdvice | ForEach-Object { $_.Value }) -join '; ')"
    }

    # THREAT_MODEL.md — та сама категорія дефекту, що й README у PR #19:
    # документ описував залишкові ризики, які код уже закрив (коди 34 і 35,
    # SecureString). Модель загроз, що перебільшує ризик, шкодить не менше
    # за ту, що применшує: власник ухвалює інфраструктурні рішення саме за
    # її списком пріоритетів.
    $threatModelText = [IO.File]::ReadAllText(
        (Join-Path $root "THREAT_MODEL.md"),
        [Text.Encoding]::UTF8
    )
    $closedControls = @(
        @{ Marker = '`34`'; What = 'блокування послаблених перемикачів безпеки' },
        @{ Marker = '`35`'; What = 'блокування відкату версії' },
        @{ Marker = 'SecureString'; What = 'секрет як SecureString' }
    )
    $unmentionedControls = @(
        $closedControls | Where-Object { -not $threatModelText.Contains($_.Marker) }
    )
    Test-BRAVOCondition `
        -Condition ($unmentionedControls.Count -eq 0) `
        -Name "Documentation/ThreatModelReflectsImplementedControls" `
        -Failure "THREAT_MODEL.md має описувати вже реалізовані контролі; не згадані: $(($unmentionedControls | ForEach-Object { $_.What }) -join '; ')"

    # Конкретні застарілі твердження, які вже були в документі й описували
    # закритий ризик як відкритий.
    $staleThreatClaims = @(
        'Downgrade **не блокується**',
        'Секрет проходить через звичайний .NET `string`'
    )
    $foundStaleClaims = @(
        $staleThreatClaims | Where-Object { $threatModelText.Contains($_) }
    )
    Test-BRAVOCondition `
        -Condition ($foundStaleClaims.Count -eq 0) `
        -Name "Documentation/ThreatModelHasNoStaleResidualRisk" `
        -Failure "THREAT_MODEL.md містить твердження про залишковий ризик, який код уже закрив: $($foundStaleClaims -join '; ')"

# =====================================================================
# #149: перелік required checks у RELEASE_POLICY.md §13.3 мусить
# покривати ВСІ задачі ci.yml
# =====================================================================
# Корінь issue #149 — не забута галочка в налаштуваннях, а те, що
# перелік вівся вручну: ci.yml отримав задачу
# BRAVO_DATA_RESTORE_MATRIX_TEST.ps1, §13 про неї не дізнався, і
# провалений E2E-тест відновлення лишався технічно немерджблокуючим.
# Галочку вмикає людина, але дрейф переліку далі ловить self-test.
#
# Перевірка НАВМИСНО одностороння (ci.yml -> §13.3, не навпаки):
# «Secret scanning (gitleaks)» і «GitGuardian Security Checks» надає
# зовнішній провайдер, а не workflow цього репозиторію, тож вимога
# «кожен пункт §13.3 має бути задачею ci.yml» відхилила б їх хибно.
#
# Розбираються САМЕ пункти переліку (рядки "- `ім'я`"), а не весь текст
# секції: пояснювальна проза поряд згадує й суфікс " (push)", і на
# суцільному пошуку підрядка перевірка спрацьовувала б на власному
# поясненні.
& {
    $requiredChecksPolicyText = [IO.File]::ReadAllText(
        (Join-Path $root 'RELEASE_POLICY.md'), [Text.Encoding]::UTF8)
    $requiredChecksWorkflowText = [IO.File]::ReadAllText(
        (Join-Path $root '.github\workflows\ci.yml'), [Text.Encoding]::UTF8)

    # Імена задач у ci.yml записані тернарником за подією; required
    # check прив'язується до pull_request-варіанта, тому беремо саме
    # перший літерал виразу.
    $ciJobNameMatches = [regex]::Matches(
        $requiredChecksWorkflowText, "'pull_request'\s*&&\s*'([^']+)'")
    $ciPullRequestJobNames = @(
        $ciJobNameMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

    $requiredChecksSectionIndex = $requiredChecksPolicyText.IndexOf('### 13.3. Перелік required checks')
    $listedCheckNames = @()
    if ($requiredChecksSectionIndex -ge 0) {
        # Від заголовка §13.3 до наступного абзацу після переліку —
        # достатньо перших рядків секції, сам перелік іде одразу.
        $requiredChecksSection = $requiredChecksPolicyText.Substring($requiredChecksSectionIndex)
        $listedCheckNames = @(
            [regex]::Matches($requiredChecksSection, '(?m)^-\s+`([^`]+)`\s*$') |
                ForEach-Object { $_.Groups[1].Value })
    }

    $unlistedCiJobNames = @(
        $ciPullRequestJobNames | Where-Object { $listedCheckNames -notcontains $_ })

    Test-BRAVOCondition `
        -Condition (
            $requiredChecksSectionIndex -ge 0 -and
            $ciPullRequestJobNames.Count -gt 0 -and
            $listedCheckNames.Count -gt 0 -and
            $unlistedCiJobNames.Count -eq 0
        ) `
        -Name "Governance/RequiredChecksListCoversCiWorkflowJobs" `
        -Failure ("RELEASE_POLICY.md §13.3 мусить перелічувати кожну pull_request-задачу ci.yml " +
            "(інакше повторюється #149: задача є, required check — ні). Задач у ci.yml: " +
            "$($ciPullRequestJobNames.Count); пунктів у переліку: $($listedCheckNames.Count); " +
            "відсутні: $(if ($unlistedCiJobNames.Count -gt 0) { $unlistedCiJobNames -join ', ' } else { '<немає>' })")

    # Друга половина того самого кореня: імена в переліку мусять бути
    # pull_request-варіантами. Суфікс " (push)" означав би required
    # check, який на PR ніколи не з'явиться, тобто вічно заблокований
    # мердж — рівно той інцидент промоції 5.1.0, через який імена й
    # розділені за подією.
    $pushSuffixedCheckNames = @($listedCheckNames | Where-Object { $_ -like '* (push)' })
    Test-BRAVOCondition `
        -Condition ($pushSuffixedCheckNames.Count -eq 0) `
        -Name "Governance/RequiredChecksListUsesPullRequestNames" `
        -Failure ("RELEASE_POLICY.md §13.3 не має містити імен із суфіксом ' (push)' — такий required " +
            "check на PR не з'являється й заблокував би мердж назавжди; знайдено: $($pushSuffixedCheckNames -join ', ')")

# =====================================================================
# Config parity придатний до промоції в required status check
# =====================================================================
# Корінь проблеми той самий, що й #149, але з іншого боку: раніше
# .github\workflows\config-parity.yml мав workflow-level
# `pull_request.paths`. Фільтр `paths` діє на рівні WORKFLOW — для PR
# поза переліком workflow не запускається взагалі, тобто check run не
# створюється. Branch protection зіставляє required checks за ІМЕНЕМ і
# чекає на статус, якого ніхто не створить: PR, що змінює лише
# README.md, лишився б заблокованим назавжди.
#
# Інваріант тримається механічно, а не коментарем: повернення `paths:`
# у цей workflow валить self-test.
& {
    $configParityWorkflowPath = Join-Path $root '.github\workflows\config-parity.yml'
    $configParityWorkflowText = [IO.File]::ReadAllText($configParityWorkflowPath, [Text.Encoding]::UTF8)
    $configParityWorkflowLines = @($configParityWorkflowText -split "`r?`n")

    # --- Governance/ConfigParityWorkflowHasNoWorkflowLevelPathFilter ---
    # Розбирається САМЕ блок `on:` до першого рядка нульового відступу
    # після нього: слово "paths" трапляється і в поясненні, і в назві
    # кроку, і суцільний пошук підрядка спрацьовував би на власному
    # коментарі — рівно той клас хибного спрацювання, який уже
    # враховано в Governance/RequiredChecksListCoversCiWorkflowJobs.
    $onBlockStartIndex = -1
    for ($lineIndex = 0; $lineIndex -lt $configParityWorkflowLines.Count; $lineIndex++) {
        if ($configParityWorkflowLines[$lineIndex] -match '^on:\s*$') {
            $onBlockStartIndex = $lineIndex
            break
        }
    }

    $onBlockLines = @()
    if ($onBlockStartIndex -ge 0) {
        for ($lineIndex = $onBlockStartIndex + 1; $lineIndex -lt $configParityWorkflowLines.Count; $lineIndex++) {
            $currentLine = $configParityWorkflowLines[$lineIndex]
            if ($currentLine -match '^\S') { break }
            $onBlockLines += $currentLine
        }
    }

    $pathFilterLines = @(
        $onBlockLines | Where-Object { $_ -match '^\s+paths(-ignore)?\s*:' }
    )

    Test-BRAVOCondition `
        -Condition ($onBlockStartIndex -ge 0 -and $pathFilterLines.Count -eq 0) `
        -Name "Governance/ConfigParityWorkflowHasNoWorkflowLevelPathFilter" `
        -Failure ("config-parity.yml не повинен мати workflow-level paths/paths-ignore: фільтр не дає " +
            "workflow запуститись, тож required check ніколи не з'явиться й заблокує PR назавжди. " +
            "Блок on: знайдено: $($onBlockStartIndex -ge 0); знайдені фільтри: " +
            "$(if ($pathFilterLines.Count -gt 0) { ($pathFilterLines | ForEach-Object { $_.Trim() }) -join '; ' } else { '<немає>' })")

    # --- Governance/ConfigParityWorkflowRunsOnEveryPullRequest ---
    $hasUnconditionalPullRequestTrigger = @(
        $onBlockLines | Where-Object { $_ -match '^\s+pull_request\s*:\s*(\{\s*\})?\s*$' }
    ).Count -gt 0

    Test-BRAVOCondition `
        -Condition $hasUnconditionalPullRequestTrigger `
        -Name "Governance/ConfigParityWorkflowRunsOnEveryPullRequest" `
        -Failure "config-parity.yml мусить тригеритись на КОЖЕН pull_request без умов — інакше check run з'являється не для кожного PR"

    # --- Governance/ConfigParityCheckKeepsCanonicalName ---
    # Ім'я — це і є контракт required check: branch protection тримає
    # рядок, не посилання на задачу. Перейменування мовчки розірве
    # прив'язку, і мердж-гейт перестане існувати, лишившись у
    # налаштуваннях. Суфікс " (push)" для workflow_dispatch — та сама
    # схема, що в ci.yml (інцидент промоції 5.1.0).
    Test-BRAVOCondition `
        -Condition ($configParityWorkflowText.Contains("'Config parity (BRAVO_CONFIG_LOADER)'")) `
        -Name "Governance/ConfigParityCheckKeepsCanonicalName" `
        -Failure "config-parity.yml мусить зберігати канонічне pull_request-ім'я 'Config parity (BRAVO_CONFIG_LOADER)'"

    # --- Governance/ConfigParityWorkflowKeepsFullHistory ---
    # Без fetch-depth: 0 недосяжні і коміт-база паритету (42cf9ad), і
    # merge-base для рішення про релевантність. Перевірка мовчки
    # перетворилась би на no-op.
    Test-BRAVOCondition `
        -Condition ($configParityWorkflowText -match 'fetch-depth:\s*0') `
        -Name "Governance/ConfigParityWorkflowKeepsFullHistory" `
        -Failure "config-parity.yml мусить робити checkout із fetch-depth: 0 — інакше ні база паритету, ні merge-base недосяжні"

    # --- Governance/ConfigParityDecisionLogicIsNotInlineYaml ---
    # Перелік шляхів живе в коді саме для того, щоб його можна було
    # перевірити синтетичними наборами (ConfigParity/* нижче). Якщо
    # workflow перестане його викликати, ці регресії охоронятимуть
    # мертвий код.
    Test-BRAVOCondition `
        -Condition (
            $configParityWorkflowText.Contains('ci\Test-BRAVOConfigParityRelevantPath.ps1') -and
            $configParityWorkflowText.Contains('Test-BRAVOConfigParityRelevantPath -ChangedPath')
        ) `
        -Name "Governance/ConfigParityDecisionLogicIsNotInlineYaml" `
        -Failure "config-parity.yml мусить приймати рішення через ci\Test-BRAVOConfigParityRelevantPath.ps1, а не інлайн-переліком у YAML"
}

# =====================================================================
# ConfigParity/* — рішення "релевантно / не релевантно" на синтетичних
# наборах
# =====================================================================
# Це та частина, яку workflow-фільтр `paths` не дозволяв перевірити
# взагалі. Набори нижче — саме ті, що названі в постановці задачі, плюс
# випадки, на яких наївна реалізація ламається: префікс каталогу без
# роздільника, зворотні слеші, порожній набір.
& {
    . (Join-Path $root 'ci\Test-BRAVOConfigParityRelevantPath.ps1')

    $canonicalPattern = @(Get-BRAVOConfigParityRelevantPathPattern)

    # --- ConfigParity/CanonicalPatternCoversRequiredPaths ---
    # Постановка задачі називає мінімальний перелік поіменно; guard
    # ловить мовчазне звуження.
    $requiredPattern = @(
        'BRAVO_CONFIG_LOADER.ps1'
        'selftest/fixtures/BravoConfigLegacyFrozen.config'
        'BRAVO.local.config.example'
        'modules/BRAVO.Configuration/**'
        'modules/BRAVO.Configurator/**'
        'ci/Test-BRAVOConfigFoundationParity.ps1'
        '.github/workflows/config-parity.yml'
    )
    $missingPattern = @($requiredPattern | Where-Object { $canonicalPattern -notcontains $_ })
    Test-BRAVOCondition `
        -Condition ($missingPattern.Count -eq 0) `
        -Name "ConfigParity/CanonicalPatternCoversRequiredPaths" `
        -Failure "Канонічний перелік шляхів config-parity звузився; відсутні: $($missingPattern -join ', ')"

    # --- ConfigParity/DefaultPatternIsLoadedWhenCallerPassesNone ---
    # Регресія на реальний дефект першого CI-прогону #214.
    #
    # Визначення "переліку не передано" виводилось зі ЗНАЧЕННЯ
    # незв'язаного параметра (@($Pattern).Count), і прогін упав із
    # "The property 'Count' cannot be found on this object". Виняток був
    # щасливим випадком: тихий варіант тієї ж помилки лишив би
    # $effectivePattern порожнім, жоден шлях не збігся б із жодним,
    # КОЖЕН PR діставав би NOT APPLICABLE — і перевірка була б вічно
    # зеленою, не перевіряючи нічого. Тому доводиться не лише те, що
    # виклик без -Pattern не падає, а й те, що він реально підставив
    # КАНОНІЧНИЙ перелік і дійсно ним скористався.
    $defaultPatternDecision = Test-BRAVOConfigParityRelevantPath `
        -ChangedPath @('BRAVO_CONFIG_LOADER.ps1')
    Test-BRAVOCondition `
        -Condition (
            @($defaultPatternDecision.Pattern).Count -eq $canonicalPattern.Count -and
            $defaultPatternDecision.IsRelevant
        ) `
        -Name "ConfigParity/DefaultPatternIsLoadedWhenCallerPassesNone" `
        -Failure ("Виклик без -Pattern мусить підставити канонічний перелік і ним скористатися; " +
            "у переліку рішення: $(@($defaultPatternDecision.Pattern).Count), канонічних: " +
            "$($canonicalPattern.Count); IsRelevant: $($defaultPatternDecision.IsRelevant)")

    # --- ConfigParity/RelevantPathDecision ---
    $relevanceCases = @(
        @{ Name = 'README only';                 Changed = @('README.md');                                      Expected = $false }
        @{ Name = 'config loader';               Changed = @('BRAVO_CONFIG_LOADER.ps1');                        Expected = $true }
        @{ Name = 'Configuration module';        Changed = @('modules/BRAVO.Configuration/x.psm1');             Expected = $true }
        @{ Name = 'Configurator module';         Changed = @('modules/BRAVO.Configurator/y.psm1');              Expected = $true }
        @{ Name = 'the workflow itself';         Changed = @('.github/workflows/config-parity.yml');            Expected = $true }
        @{ Name = 'the harness itself';          Changed = @('ci/Test-BRAVOConfigFoundationParity.ps1');        Expected = $true }
        @{ Name = 'the decision logic itself';   Changed = @('ci/Test-BRAVOConfigParityRelevantPath.ps1');      Expected = $true }
        @{ Name = 'legacy primary config';       Changed = @('selftest/fixtures/BravoConfigLegacyFrozen.config'); Expected = $true }
        @{ Name = 'site config example';         Changed = @('BRAVO.local.config.example');                     Expected = $true }
        @{ Name = 'mixed, one relevant';         Changed = @('README.md', 'CHANGELOG.md', 'modules/BRAVO.Configuration/x.psm1', 'docs/a.md'); Expected = $true }
        @{ Name = 'mixed, none relevant';        Changed = @('README.md', 'CHANGELOG.md', 'docs/a.md');         Expected = $false }
        @{ Name = 'empty change set';            Changed = @();                                                 Expected = $false }
        # Наївна реалізація на StartsWith без роздільника сказала б
        # "релевантно" — це не сусідній каталог, а інший каталог.
        @{ Name = 'sibling directory prefix';    Changed = @('modules/BRAVO.ConfigurationBackup/x.psm1');       Expected = $false }
        # git друкує "/", але локальний виклик і копіпаста дають "".
        @{ Name = 'backslash separators';        Changed = @('modules\BRAVO.Configuration\x.psm1');            Expected = $true }
        # Регістр: цільова файлова система регістронезалежна.
        @{ Name = 'different case';              Changed = @('bravo_config_loader.ps1');                        Expected = $true }
        # Файл із такою ж назвою, але в іншому каталозі, релевантним не є.
        @{ Name = 'same name, other directory';  Changed = @('selftest/BRAVO_CONFIG_LOADER.ps1');               Expected = $false }
    )

    foreach ($relevanceCase in $relevanceCases) {
        $caseDecision = Test-BRAVOConfigParityRelevantPath -ChangedPath @($relevanceCase.Changed)
        Test-BRAVOCondition `
            -Condition ($caseDecision.IsRelevant -eq $relevanceCase.Expected) `
            -Name "ConfigParity/RelevantPathDecision ($($relevanceCase.Name))" `
            -Failure ("Рішення про релевантність невірне для набору [$(@($relevanceCase.Changed) -join ', ')]: " +
                "очікували IsRelevant=$($relevanceCase.Expected), отримали $($caseDecision.IsRelevant)")
    }

    # --- ConfigParity/RelevantPathDecisionReportsMatch ---
    # "Не релевантно" без переліку розглянутих шляхів неможливо
    # відрізнити від "перелік порожній через помилку", тому рішення несе
    # причину, а не лише [bool].
    $reportingDecision = Test-BRAVOConfigParityRelevantPath `
        -ChangedPath @('README.md', 'modules/BRAVO.Configuration/x.psm1')
    Test-BRAVOCondition `
        -Condition (
            @($reportingDecision.MatchedPath).Count -eq 1 -and
            @($reportingDecision.MatchedPath)[0] -eq 'modules/BRAVO.Configuration/x.psm1' -and
            @($reportingDecision.ConsideredPath).Count -eq 2
        ) `
        -Name "ConfigParity/RelevantPathDecisionReportsMatch" `
        -Failure "Рішення мусить повідомляти, ЯКИЙ саме шлях збігся і скільки шляхів розглянуто"

    # --- ConfigParity/RelevantPathDecisionSurvivesStrictModeCountAccess ---
    # Той самий клас дефекту, що #212: 0-елементний результат, який під
    # Set-StrictMode розгортається у $null, валить .Count із
    # PropertyNotFoundException. Тут це означало б падіння задачі CI
    # рівно на тих PR, які мали б завершитись N/A.
    $emptyDecisionSucceeded = $false
    try {
        $emptyDecision = Test-BRAVOConfigParityRelevantPath -ChangedPath @()
        $emptyDecisionSucceeded = (
            @($emptyDecision.MatchedPath).Count -eq 0 -and
            @($emptyDecision.ConsideredPath).Count -eq 0 -and
            @($emptyDecision.Pattern).Count -gt 0 -and
            -not $emptyDecision.IsRelevant
        )
    } catch {
        $emptyDecisionSucceeded = $false
    }
    Test-BRAVOCondition `
        -Condition $emptyDecisionSucceeded `
        -Name "ConfigParity/RelevantPathDecisionSurvivesStrictModeCountAccess" `
        -Failure "Порожній набір змінених файлів мусить давати валідний результат із доступним .Count, а не падати під Set-StrictMode"

    # --- ConfigParity/RelevantPathDecisionAcceptsExplicitPattern ---
    # Логіка зіставлення перевіряється окремо від канонічного переліку:
    # інакше зміна переліку мовчки переписувала б і очікування тестів.
    $syntheticDecision = Test-BRAVOConfigParityRelevantPath `
        -ChangedPath @('some/dir/file.txt') -Pattern @('some/dir/**')
    $syntheticNegative = Test-BRAVOConfigParityRelevantPath `
        -ChangedPath @('some/dirother/file.txt') -Pattern @('some/dir/**')
    Test-BRAVOCondition `
        -Condition ($syntheticDecision.IsRelevant -and -not $syntheticNegative.IsRelevant) `
        -Name "ConfigParity/RelevantPathDecisionAcceptsExplicitPattern" `
        -Failure "Зіставлення за явним -Pattern працює невірно: префікс каталогу мусить враховувати роздільник"
}

# =====================================================================
# ReleaseGate/* (Issue #216, §9 п.3/п.4): гейти LEGACY_CONFIG_REMOVED/
# AUTOEXEC винесені в ci\BRAVOConfigV2CutoverGates.ps1 — R2 знайшов, що
# попередня inline-версія в ci\New-BRAVOReleaseArtifact.ps1 перевіряла
# лише ТЕКСТОВУ присутність -DisallowLegacyPrimaryAutoDetect, тож явний
# `-DisallowLegacyPrimaryAutoDetect:$false` (чи `:0`) проходив би як
# коректний. Синтетичні фікстури тут — той самий підхід, що й
# ConfigParity/* вище: перевіряємо ЛОГІКУ функції на текстових
# сніпетах, а не через повну збірку release-артефакту (дорого й
# непотрібно для цього дефекту).
& {
    . (Join-Path $root 'ci\BRAVOConfigV2CutoverGates.ps1')

    function New-BRAVOReleaseGateFixtureRoot {
        param([string]$EntryPointText)
        $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_RELEASEGATE_{0}" -f [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($fixtureRoot)
        [IO.File]::WriteAllText(
            (Join-Path $fixtureRoot 'entry.ps1'), $EntryPointText, (New-Object Text.UTF8Encoding($false))
        )
        return $fixtureRoot
    }

    $releaseGateBareFlagRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $releaseGateBareFlagResult = Test-BRAVOConfigV2CutoverGates -Root $releaseGateBareFlagRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition ($releaseGateBareFlagResult.Passed) `
            -Name "ReleaseGate/CutoverGateAcceptsBareFlag" `
            -Failure "бекар (implicit `$true) -DisallowLegacyPrimaryAutoDetect мусить проходити гейт AUTOEXEC; отримано Failures=$($releaseGateBareFlagResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $releaseGateBareFlagRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $releaseGateTrueBindingRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect:$true'
    try {
        $releaseGateTrueBindingResult = Test-BRAVOConfigV2CutoverGates -Root $releaseGateTrueBindingRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition ($releaseGateTrueBindingResult.Passed) `
            -Name "ReleaseGate/CutoverGateAcceptsExplicitTrueBinding" `
            -Failure "явний -DisallowLegacyPrimaryAutoDetect:`$true мусить проходити гейт AUTOEXEC; отримано Failures=$($releaseGateTrueBindingResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $releaseGateTrueBindingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # R2: до фіксу цей кейс ХИБНО проходив гейт — текст прапорця присутній,
    # хоча ефективно auto-detect НЕ блокується.
    $releaseGateFalseBindingRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect:$false'
    try {
        $releaseGateFalseBindingResult = Test-BRAVOConfigV2CutoverGates -Root $releaseGateFalseBindingRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (-not $releaseGateFalseBindingResult.Passed) `
            -Name "ReleaseGate/CutoverGateRejectsExplicitFalseBinding" `
            -Failure "явний -DisallowLegacyPrimaryAutoDetect:`$false ЕФЕКТИВНО вимикає блокування auto-detect — гейт AUTOEXEC мусить це виявляти, а не пропускати через текстову присутність назви прапорця"
    } finally {
        Remove-Item -LiteralPath $releaseGateFalseBindingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $releaseGateZeroBindingRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect:0'
    try {
        $releaseGateZeroBindingResult = Test-BRAVOConfigV2CutoverGates -Root $releaseGateZeroBindingRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (-not $releaseGateZeroBindingResult.Passed) `
            -Name "ReleaseGate/CutoverGateRejectsExplicitZeroBinding" `
            -Failure "явний -DisallowLegacyPrimaryAutoDetect:0 ЕФЕКТИВНО вимикає блокування auto-detect — гейт AUTOEXEC мусить це виявляти"
    } finally {
        Remove-Item -LiteralPath $releaseGateZeroBindingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $releaseGateMissingFlagRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X'
    try {
        $releaseGateMissingFlagResult = Test-BRAVOConfigV2CutoverGates -Root $releaseGateMissingFlagRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (-not $releaseGateMissingFlagResult.Passed) `
            -Name "ReleaseGate/CutoverGateRejectsMissingFlag" `
            -Failure "виклик Import-BravoConfiguration без -DisallowLegacyPrimaryAutoDetect взагалі мусить провалювати гейт AUTOEXEC"
    } finally {
        Remove-Item -LiteralPath $releaseGateMissingFlagRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateDetectsLegacyConfigPresent ---
    $releaseGateLegacyRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        [IO.File]::WriteAllText((Join-Path $releaseGateLegacyRoot 'BRAVO.config'), '# poisoned', (New-Object Text.UTF8Encoding($false)))
        $releaseGateLegacyResult = Test-BRAVOConfigV2CutoverGates -Root $releaseGateLegacyRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $releaseGateLegacyResult.Passed -and
                @($releaseGateLegacyResult.Failures | Where-Object { $_.Contains('LEGACY_CONFIG_REMOVED') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CutoverGateDetectsLegacyConfigPresent" `
            -Failure "BRAVO.config, присутній у корені комплекту, мусить провалювати гейт LEGACY_CONFIG_REMOVED"
    } finally {
        Remove-Item -LiteralPath $releaseGateLegacyRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateDetectsDirectLegacyReaderCallInModule ---
    # Issue #216 Phase 11 п.11: production-код не сміє викликати
    # legacy-рідер напряму, минаючи Import-BravoConfiguration
    # -DisallowLegacyPrimaryAutoDetect (гейт 2 доводить лише, що
    # entrypoint-и самі не обходять guard; окремий модуль, що звертається
    # до рідера напряму, guard 2 не помітив би).
    $legacyReaderModuleFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $roguePsm1Dir = Join-Path $legacyReaderModuleFixtureRoot 'modules\BRAVO.Rogue'
        [void][IO.Directory]::CreateDirectory($roguePsm1Dir)
        [IO.File]::WriteAllText(
            (Join-Path $roguePsm1Dir 'BRAVO.Rogue.psm1'),
            'function Invoke-Rogue { Import-BravoLegacyPrimaryConfiguration -ConfigPath X }',
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderModuleFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderModuleFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $legacyReaderModuleFixtureResult.Passed -and
                @($legacyReaderModuleFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') -and $_.Contains('BRAVO.Rogue.psm1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CutoverGateDetectsDirectLegacyReaderCallInModule" `
            -Failure "модуль поза BRAVO_CONFIG_LOADER.ps1, що напряму викликає Import-BravoLegacyPrimaryConfiguration, мусить провалювати гейт LEGACY_READER_ISOLATION"
    } finally {
        Remove-Item -LiteralPath $legacyReaderModuleFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateDetectsDirectLegacyReaderCallInEntrypoint ---
    $legacyReaderEntrypointFixtureText = "Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect`nRead-BRAVOLegacyPrimaryRawOverrides -ConfigPath X"
    $legacyReaderEntrypointFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText $legacyReaderEntrypointFixtureText
    try {
        $legacyReaderEntrypointFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderEntrypointFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $legacyReaderEntrypointFixtureResult.Passed -and
                @($legacyReaderEntrypointFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') -and $_.Contains('entry.ps1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CutoverGateDetectsDirectLegacyReaderCallInEntrypoint" `
            -Failure "production entrypoint, що напряму викликає Read-BRAVOLegacyPrimaryRawOverrides в обхід Import-BravoConfiguration, мусить провалювати гейт LEGACY_READER_ISOLATION"
    } finally {
        Remove-Item -LiteralPath $legacyReaderEntrypointFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateAllowsCanonicalLegacyReaderSelfReference ---
    # BRAVO_CONFIG_LOADER.ps1 сам визначає й викликає ці дві функції —
    # гейт LEGACY_READER_ISOLATION мусить виключати саме цей файл зі
    # сканування, інакше він завжди провалювався б і на чистому дереві.
    $legacyReaderSelfReferenceFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        [IO.File]::WriteAllText(
            (Join-Path $legacyReaderSelfReferenceFixtureRoot 'BRAVO_CONFIG_LOADER.ps1'),
            "function Read-BRAVOLegacyPrimaryRawOverrides { }`nfunction Import-BravoLegacyPrimaryConfiguration { Read-BRAVOLegacyPrimaryRawOverrides }",
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderSelfReferenceFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderSelfReferenceFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                $legacyReaderSelfReferenceFixtureResult.Passed -and
                @($legacyReaderSelfReferenceFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') }).Count -eq 0
            ) `
            -Name "ReleaseGate/CutoverGateAllowsCanonicalLegacyReaderSelfReference" `
            -Failure "BRAVO_CONFIG_LOADER.ps1 — канонічне визначення legacy-рідера — не сміє саме собою провалювати гейт LEGACY_READER_ISOLATION"
    } finally {
        Remove-Item -LiteralPath $legacyReaderSelfReferenceFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateDetectsLegacyReaderCallCaseInsensitively ---
    # Codex-знахідка (gate-review): PowerShell розв'язує імена команд
    # регістронезалежно, тож інший регістр символів мусить так само
    # провалювати гейт, а не пройти через ordinal-порівняння.
    $legacyReaderCaseInsensitiveFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $rogueCaseDir = Join-Path $legacyReaderCaseInsensitiveFixtureRoot 'modules\BRAVO.RogueCase'
        [void][IO.Directory]::CreateDirectory($rogueCaseDir)
        [IO.File]::WriteAllText(
            (Join-Path $rogueCaseDir 'BRAVO.RogueCase.psm1'),
            'function Invoke-RogueCase { import-bravolegacyprimaryconfiguration -ConfigPath X }',
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderCaseInsensitiveFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderCaseInsensitiveFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $legacyReaderCaseInsensitiveFixtureResult.Passed -and
                @($legacyReaderCaseInsensitiveFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') -and $_.Contains('BRAVO.RogueCase.psm1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CutoverGateDetectsLegacyReaderCallCaseInsensitively" `
            -Failure "виклик легального PowerShell-імені іншим регістром символів (import-bravolegacyprimaryconfiguration) мусить так само провалювати гейт LEGACY_READER_ISOLATION, як і канонічний регістр"
    } finally {
        Remove-Item -LiteralPath $legacyReaderCaseInsensitiveFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateScansAllRootEntryScriptsNotOnlyAutoexecList ---
    # Codex-знахідка (gate-review): попередня версія сканувала лише 14
    # AUTOEXEC-цілей (Get-BRAVOProductionEntryPointRelativePath), пропускаючи
    # кореневі тонкі entrypoint-обгортки поза цим списком (напр.
    # BRAVO_ARCHIV.ps1/BRAVO_HEALTH.ps1/BRAVO_MAINTENANCE.ps1/
    # BRAVO_DATA_RESTORE.ps1/BRAVO_CONFIGURATOR.ps1). Тут фікстура НЕ передає
    # цільовий файл через -ProductionEntryPointRelativePath взагалі — гейт
    # мусить знайти його самостійно через власне сканування кореня.
    $legacyReaderRootEntryFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        [IO.File]::WriteAllText(
            (Join-Path $legacyReaderRootEntryFixtureRoot 'BRAVO_HEALTH.ps1'),
            "Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect`nRead-BRAVOLegacyPrimaryRawOverrides -ConfigPath X",
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderRootEntryFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderRootEntryFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $legacyReaderRootEntryFixtureResult.Passed -and
                @($legacyReaderRootEntryFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') -and $_.Contains('BRAVO_HEALTH.ps1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CutoverGateScansAllRootEntryScriptsNotOnlyAutoexecList" `
            -Failure "кореневий BRAVO_*.ps1-скрипт поза списком AUTOEXEC-цілей, що напряму викликає Read-BRAVOLegacyPrimaryRawOverrides, мусить провалювати гейт LEGACY_READER_ISOLATION, навіть коли його немає в -ProductionEntryPointRelativePath"
    } finally {
        Remove-Item -LiteralPath $legacyReaderRootEntryFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateIgnoresCommentOnlyLegacyReaderMention ---
    # Codex-знахідка (gate-review, R3): текстовий пошук бачив би цю появу
    # назви функції в коментарі як FAIL, хоча жодного виклику команди тут
    # немає — гейт мусить розбирати AST і зіставляти лише СПРАВЖНІ виклики
    # команд, а не будь-яку текстову появу імені.
    $legacyReaderCommentOnlyFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $commentOnlyDir = Join-Path $legacyReaderCommentOnlyFixtureRoot 'modules\BRAVO.Comment'
        [void][IO.Directory]::CreateDirectory($commentOnlyDir)
        [IO.File]::WriteAllText(
            (Join-Path $commentOnlyDir 'BRAVO.Comment.psm1'),
            "# делегує в Import-BravoLegacyPrimaryConfiguration/Read-BRAVOLegacyPrimaryRawOverrides для сумісності`nfunction Invoke-Noop { 'noop' }",
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderCommentOnlyFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderCommentOnlyFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                $legacyReaderCommentOnlyFixtureResult.Passed -and
                @($legacyReaderCommentOnlyFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') }).Count -eq 0
            ) `
            -Name "ReleaseGate/CutoverGateIgnoresCommentOnlyLegacyReaderMention" `
            -Failure "коментар, що лише ЗГАДУЄ назву legacy-рідера (без виклику команди), не сміє провалювати гейт LEGACY_READER_ISOLATION; отримано Failures=$($legacyReaderCommentOnlyFixtureResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $legacyReaderCommentOnlyFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateScansDeployDirectoryForLegacyReaderCalls ---
    # Codex-знахідка (gate-review): deploy\ раніше не сканувався ЗОВСІМ —
    # не-migration скрипт (напр. deploy\Install-BRAVOServer.ps1) міг би
    # напряму викликати legacy-рідер без жодного FAIL.
    $legacyReaderDeployFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        [void][IO.Directory]::CreateDirectory((Join-Path $legacyReaderDeployFixtureRoot 'deploy'))
        [IO.File]::WriteAllText(
            (Join-Path $legacyReaderDeployFixtureRoot 'deploy\Rogue-NotSanctioned.ps1'),
            'Read-BRAVOLegacyPrimaryRawOverrides -ConfigPath X',
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderDeployFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderDeployFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $legacyReaderDeployFixtureResult.Passed -and
                @($legacyReaderDeployFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') -and $_.Contains('Rogue-NotSanctioned.ps1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CutoverGateScansDeployDirectoryForLegacyReaderCalls" `
            -Failure "не-migration скрипт під deploy\, що напряму викликає Read-BRAVOLegacyPrimaryRawOverrides, мусить провалювати гейт LEGACY_READER_ISOLATION — deploy\ мусить скануватись так само, як modules\"
    } finally {
        Remove-Item -LiteralPath $legacyReaderDeployFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateExemptsSanctionedMigrationToolsFromLegacyReaderIsolation ---
    # ci\New-BRAVOReleaseArtifact.ps1 (коментар біля рядка 200) документує
    # канонічний перелік migration/deploy-інструментів, чия ЗАЯВЛЕНА мета —
    # читати РЕАЛЬНИЙ встановлений legacy-шар (Issue #216 Phase 6 санкціонує
    # це напряму для deploy\Get-BRAVOConfigSiteDelta.ps1). Гейт
    # LEGACY_READER_ISOLATION мусить узгоджено виключати той самий перелік.
    $legacyReaderSanctionedFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        [IO.File]::WriteAllText(
            (Join-Path $legacyReaderSanctionedFixtureRoot 'BRAVO_CONFIG_INTEGRATE.ps1'),
            'Read-BRAVOLegacyPrimaryRawOverrides -ConfigPath X',
            (New-Object Text.UTF8Encoding($false))
        )
        [void][IO.Directory]::CreateDirectory((Join-Path $legacyReaderSanctionedFixtureRoot 'deploy'))
        [IO.File]::WriteAllText(
            (Join-Path $legacyReaderSanctionedFixtureRoot 'deploy\Get-BRAVOConfigSiteDelta.ps1'),
            'Read-BRAVOLegacyPrimaryRawOverrides -ConfigPath X',
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderSanctionedFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderSanctionedFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                $legacyReaderSanctionedFixtureResult.Passed -and
                @($legacyReaderSanctionedFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') }).Count -eq 0
            ) `
            -Name "ReleaseGate/CutoverGateExemptsSanctionedMigrationToolsFromLegacyReaderIsolation" `
            -Failure "BRAVO_CONFIG_INTEGRATE.ps1 і deploy\Get-BRAVOConfigSiteDelta.ps1 — санкціоновані Issue #216 Phase 6 migration-інструменти — не сміють провалювати гейт LEGACY_READER_ISOLATION лише за виконання своєї заявленої мети; отримано Failures=$($legacyReaderSanctionedFixtureResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $legacyReaderSanctionedFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateDetectsSimpleVariableIndirectionLegacyReaderCall ---
    # Codex-знахідка (gate-review, R4): `$reader = 'Read-BRAVOLegacyPrimaryRawOverrides'; & $reader`
    # обходить пряме зіставлення CommandAst.GetCommandName() (повертає null
    # для команди-змінної). Гейт мусить ловити принаймні цю просту форму
    # непрямого виклику через локальне присвоєння рядкового літералу.
    $legacyReaderIndirectFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $indirectDir = Join-Path $legacyReaderIndirectFixtureRoot 'modules\BRAVO.Indirect'
        [void][IO.Directory]::CreateDirectory($indirectDir)
        [IO.File]::WriteAllText(
            (Join-Path $indirectDir 'BRAVO.Indirect.psm1'),
            "function Invoke-Sneaky { `$reader = 'Read-BRAVOLegacyPrimaryRawOverrides'; & `$reader -ConfigPath X }",
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderIndirectFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderIndirectFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $legacyReaderIndirectFixtureResult.Passed -and
                @($legacyReaderIndirectFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') -and $_.Contains('BRAVO.Indirect.psm1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CutoverGateDetectsSimpleVariableIndirectionLegacyReaderCall" `
            -Failure "виклик legacy-рідера через змінну, присвоєну рядковому літералу з іменем рідера (`$var = 'Read-BRAVOLegacyPrimaryRawOverrides'; & `$var), мусить провалювати гейт LEGACY_READER_ISOLATION"
    } finally {
        Remove-Item -LiteralPath $legacyReaderIndirectFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateIgnoresUnrelatedVariableIndirectionCalls ---
    # Контрольний негативний тест до попереднього: змінна, присвоєна
    # ЧОМУСЬ ІНШОМУ й потім викликана через `&`, не повинна породжувати
    # false positive.
    $legacyReaderBenignIndirectFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $benignIndirectDir = Join-Path $legacyReaderBenignIndirectFixtureRoot 'modules\BRAVO.BenignIndirect'
        [void][IO.Directory]::CreateDirectory($benignIndirectDir)
        [IO.File]::WriteAllText(
            (Join-Path $benignIndirectDir 'BRAVO.BenignIndirect.psm1'),
            "function Invoke-Benign { `$cmd = 'Get-ChildItem'; & `$cmd -Path X }",
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderBenignIndirectFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderBenignIndirectFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                $legacyReaderBenignIndirectFixtureResult.Passed -and
                @($legacyReaderBenignIndirectFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') }).Count -eq 0
            ) `
            -Name "ReleaseGate/CutoverGateIgnoresUnrelatedVariableIndirectionCalls" `
            -Failure "змінна, присвоєна імені команди, що НЕ є legacy-рідером, і викликана через `&`, не сміє провалювати гейт LEGACY_READER_ISOLATION; отримано Failures=$($legacyReaderBenignIndirectFixtureResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $legacyReaderBenignIndirectFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateIgnoresReassignedIndirectionVariable ---
    # Codex-знахідка (gate-review, R5): попередня версія тримала плаский
    # HashSet імен змінних на весь файл — reassignment тієї самої змінної
    # на щось безпечне ПІСЛЯ ризикового присвоєння хибно провалював би
    # гейт, хоча реально виконується лише безпечна команда.
    $legacyReaderReassignFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $reassignDir = Join-Path $legacyReaderReassignFixtureRoot 'modules\BRAVO.Reassign'
        [void][IO.Directory]::CreateDirectory($reassignDir)
        [IO.File]::WriteAllText(
            (Join-Path $reassignDir 'BRAVO.Reassign.psm1'),
            "function Invoke-Reassign { `$cmd = 'Read-BRAVOLegacyPrimaryRawOverrides'; `$cmd = 'Get-ChildItem'; & `$cmd -Path X }",
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderReassignFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderReassignFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                $legacyReaderReassignFixtureResult.Passed -and
                @($legacyReaderReassignFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') }).Count -eq 0
            ) `
            -Name "ReleaseGate/CutoverGateIgnoresReassignedIndirectionVariable" `
            -Failure "reassignment змінної на безпечне значення ПІСЛЯ ризикового присвоєння (`$cmd = 'Read-BRAVOLegacyPrimaryRawOverrides'; `$cmd = 'Get-ChildItem'; & `$cmd) не сміє провалювати гейт LEGACY_READER_ISOLATION — реально виконується лише Get-ChildItem; отримано Failures=$($legacyReaderReassignFixtureResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $legacyReaderReassignFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateIsolatesIndirectionVariableByScope ---
    # Контрольний тест до попереднього: та сама назва змінної, привласнена
    # безпечному значенню в ІНШІЙ функції того самого файлу, не повинна
    # хибно позначатись як ризикова через саму назву.
    $legacyReaderScopeFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $scopeDir = Join-Path $legacyReaderScopeFixtureRoot 'modules\BRAVO.CrossScope'
        [void][IO.Directory]::CreateDirectory($scopeDir)
        [IO.File]::WriteAllText(
            (Join-Path $scopeDir 'BRAVO.CrossScope.psm1'),
            "function Invoke-Benign { `$cmd = 'Get-ChildItem'; & `$cmd -Path X }`nfunction Invoke-BenignToo { & `$cmd -Path Y }",
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderScopeFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderScopeFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                $legacyReaderScopeFixtureResult.Passed -and
                @($legacyReaderScopeFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') }).Count -eq 0
            ) `
            -Name "ReleaseGate/CutoverGateIsolatesIndirectionVariableByScope" `
            -Failure "та сама назва змінної в іншій функції, без власного присвоєння в межах ТІЄЇ функції, не сміє провалювати гейт LEGACY_READER_ISOLATION; отримано Failures=$($legacyReaderScopeFixtureResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $legacyReaderScopeFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateNarrowsCanonicalLoaderExemptionToSanctionedCallSites ---
    # Codex-знахідка (gate-review, R5): попередня версія повністю
    # виключала BRAVO_CONFIG_LOADER.ps1 зі сканування, ховаючи МАЙБУТНІЙ
    # негвардований виклик десь-інде в тому самому файлі. Тепер файл
    # сканується, як усі інші, але звіряється проти точного переліку
    # санкціонованих пар (Read-... лише з Import-BravoLegacyPrimaryConfiguration,
    # Import-BravoLegacyPrimaryConfiguration лише з Import-BravoConfiguration).
    $legacyReaderLoaderSanctionedFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $sanctionedLoaderText = "function Read-BRAVOLegacyPrimaryRawOverrides { param(`$ConfigPath) }`n" +
            "function Import-BravoLegacyPrimaryConfiguration { param(`$ConfigPath); `$x = Read-BRAVOLegacyPrimaryRawOverrides -ConfigPath `$ConfigPath }`n" +
            "function Import-BravoConfiguration { param(`$ConfigRoot, [switch]`$DisallowLegacyPrimaryAutoDetect); if (-not `$DisallowLegacyPrimaryAutoDetect) { Import-BravoLegacyPrimaryConfiguration -ConfigPath X } }"
        [IO.File]::WriteAllText(
            (Join-Path $legacyReaderLoaderSanctionedFixtureRoot 'BRAVO_CONFIG_LOADER.ps1'),
            $sanctionedLoaderText,
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderLoaderSanctionedFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderLoaderSanctionedFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                $legacyReaderLoaderSanctionedFixtureResult.Passed -and
                @($legacyReaderLoaderSanctionedFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') }).Count -eq 0
            ) `
            -Name "ReleaseGate/CutoverGateNarrowsCanonicalLoaderExemptionToSanctionedCallSites" `
            -Failure "BRAVO_CONFIG_LOADER.ps1, що містить ЛИШЕ два санкціоновані внутрішні виклики (Import-BravoLegacyPrimaryConfiguration->Read-BRAVOLegacyPrimaryRawOverrides, Import-BravoConfiguration->Import-BravoLegacyPrimaryConfiguration), не сміє провалювати гейт LEGACY_READER_ISOLATION; отримано Failures=$($legacyReaderLoaderSanctionedFixtureResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $legacyReaderLoaderSanctionedFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateDetectsUnsanctionedCallSiteInsideCanonicalLoader ---
    # Контрольний тест до попереднього: ТРЕТІЙ, не санкціонований, виклик
    # Read-BRAVOLegacyPrimaryRawOverrides з будь-якої іншої функції в
    # тому самому BRAVO_CONFIG_LOADER.ps1 мусить і надалі провалювати
    # гейт — файл більше не отримує повний file-level allowlist.
    $legacyReaderLoaderUnsanctionedFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $unsanctionedLoaderText = "function Read-BRAVOLegacyPrimaryRawOverrides { param(`$ConfigPath) }`n" +
            "function Import-BravoLegacyPrimaryConfiguration { param(`$ConfigPath); `$x = Read-BRAVOLegacyPrimaryRawOverrides -ConfigPath `$ConfigPath }`n" +
            "function Import-BravoConfiguration { param(`$ConfigRoot, [switch]`$DisallowLegacyPrimaryAutoDetect); if (-not `$DisallowLegacyPrimaryAutoDetect) { Import-BravoLegacyPrimaryConfiguration -ConfigPath X } }`n" +
            "function Invoke-RogueShortcut { Read-BRAVOLegacyPrimaryRawOverrides -ConfigPath Y }"
        [IO.File]::WriteAllText(
            (Join-Path $legacyReaderLoaderUnsanctionedFixtureRoot 'BRAVO_CONFIG_LOADER.ps1'),
            $unsanctionedLoaderText,
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderLoaderUnsanctionedFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderLoaderUnsanctionedFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $legacyReaderLoaderUnsanctionedFixtureResult.Passed -and
                @($legacyReaderLoaderUnsanctionedFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') -and $_.Contains('BRAVO_CONFIG_LOADER.ps1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CutoverGateDetectsUnsanctionedCallSiteInsideCanonicalLoader" `
            -Failure "не санкціонований третій виклик Read-BRAVOLegacyPrimaryRawOverrides з довільної функції всередині самого BRAVO_CONFIG_LOADER.ps1 мусить провалювати гейт LEGACY_READER_ISOLATION"
    } finally {
        Remove-Item -LiteralPath $legacyReaderLoaderUnsanctionedFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateResolvesIndirectionThroughParentScope ---
    # Codex-знахідка (gate-review, R6): попередня версія вимагала точної
    # рівності ScriptBlockAst — присвоєння на рівні модуля/скрипта й
    # виклик через ту саму змінну ВСЕРЕДИНІ вкладеної функції реально
    # резолвиться лексично (PowerShell читає змінну з батьківського
    # scope), але точна рівність ScriptBlockAst це відкидала, пропускаючи
    # реальний обхід. Гейт мусить перевіряти весь ланцюжок охоплюючих
    # scope, а не лише точний.
    $legacyReaderParentScopeFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $parentScopeDir = Join-Path $legacyReaderParentScopeFixtureRoot 'modules\BRAVO.ParentScope'
        [void][IO.Directory]::CreateDirectory($parentScopeDir)
        [IO.File]::WriteAllText(
            (Join-Path $parentScopeDir 'BRAVO.ParentScope.psm1'),
            "`$reader = 'Read-BRAVOLegacyPrimaryRawOverrides'`nfunction Invoke-FromNested { & `$reader -ConfigPath X }",
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderParentScopeFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderParentScopeFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $legacyReaderParentScopeFixtureResult.Passed -and
                @($legacyReaderParentScopeFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') -and $_.Contains('BRAVO.ParentScope.psm1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CutoverGateResolvesIndirectionThroughParentScope" `
            -Failure "присвоєння змінної на рівні модуля/скрипта, використане через `& `$var` усередині ВКЛАДЕНОЇ функції, мусить провалювати гейт LEGACY_READER_ISOLATION — PowerShell реально резолвить це значення лексично з батьківського scope"
    } finally {
        Remove-Item -LiteralPath $legacyReaderParentScopeFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateInnerShadowOverridesOuterRiskyAssignment ---
    # Контрольний тест до попереднього: коли ВКЛАДЕНА функція сама
    # перевизначає ту саму змінну на безпечне значення ПЕРЕД викликом,
    # затінення (shadowing) означає, що реально виконується безпечна
    # команда — гейт не повинен провалюватись через зовнішнє ризикове
    # присвоєння, яке перекрите.
    $legacyReaderShadowFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $shadowDir = Join-Path $legacyReaderShadowFixtureRoot 'modules\BRAVO.Shadow'
        [void][IO.Directory]::CreateDirectory($shadowDir)
        [IO.File]::WriteAllText(
            (Join-Path $shadowDir 'BRAVO.Shadow.psm1'),
            "`$cmd = 'Read-BRAVOLegacyPrimaryRawOverrides'`nfunction Invoke-Shadowed { `$cmd = 'Get-ChildItem'; & `$cmd -Path X }",
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderShadowFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderShadowFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                $legacyReaderShadowFixtureResult.Passed -and
                @($legacyReaderShadowFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') }).Count -eq 0
            ) `
            -Name "ReleaseGate/CutoverGateInnerShadowOverridesOuterRiskyAssignment" `
            -Failure "власне присвоєння змінної ВСЕРЕДИНІ вкладеної функції (shadowing) на безпечне значення не сміє провалювати гейт LEGACY_READER_ISOLATION лише через зовнішнє ризикове присвоєння тієї самої назви; отримано Failures=$($legacyReaderShadowFixtureResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $legacyReaderShadowFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateDetectsSecondUnguardedCallFromSanctionedCaller ---
    # Codex-знахідка (gate-review, R7): перевірка санкціонованої пари за
    # ІМЕНЕМ охоплюючої функції не бачить, що конкретний виклик реально
    # guard'ований — другий, негвардований виклик Import-BravoLegacyPrimaryConfiguration
    # десь-інде всередині ТІЄЇ Ж Import-BravoConfiguration проходив би
    # непоміченим. Дешева інваріанта: рівно один виклик на санкціоновану
    # пару в усьому файлі — другий провалює гейт.
    $legacyReaderSecondCallFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $secondCallLoaderText = "function Read-BRAVOLegacyPrimaryRawOverrides { param(`$ConfigPath) }`n" +
            "function Import-BravoLegacyPrimaryConfiguration { param(`$ConfigPath); `$x = Read-BRAVOLegacyPrimaryRawOverrides -ConfigPath `$ConfigPath }`n" +
            "function Import-BravoConfiguration {`n" +
            "    param(`$ConfigRoot, [switch]`$DisallowLegacyPrimaryAutoDetect)`n" +
            "    if (-not `$DisallowLegacyPrimaryAutoDetect) { Import-BravoLegacyPrimaryConfiguration -ConfigPath X }`n" +
            "    Import-BravoLegacyPrimaryConfiguration -ConfigPath Y`n" +
            "}"
        [IO.File]::WriteAllText(
            (Join-Path $legacyReaderSecondCallFixtureRoot 'BRAVO_CONFIG_LOADER.ps1'),
            $secondCallLoaderText,
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderSecondCallFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderSecondCallFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $legacyReaderSecondCallFixtureResult.Passed -and
                @($legacyReaderSecondCallFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') -and $_.Contains('BRAVO_CONFIG_LOADER.ps1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CutoverGateDetectsSecondUnguardedCallFromSanctionedCaller" `
            -Failure "другий виклик Import-BravoLegacyPrimaryConfiguration з Import-BravoConfiguration (поза відомим guard'ом) мусить провалювати гейт LEGACY_READER_ISOLATION, навіть коли перший виклик санкціонований"
    } finally {
        Remove-Item -LiteralPath $legacyReaderSecondCallFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateTreatsCompoundAssignmentAsNonReplacing ---
    # Codex-знахідка (gate-review, R8) — РЕАЛЬНИЙ баг у самій реалізації
    # гейту (не крайовий випадок статичного аналізу): складене присвоєння
    # (`+=`) не ЗАМІНЮЄ значення змінної, а доповнює його, але попередня
    # версія записувала будь-який AssignmentStatementAst як повну заміну —
    # `$cmd += ''` після ризикового `$cmd = 'Read-...'` хибно "очищав"
    # запис, і подальший `& $cmd` (що реально й надалі викликає рідер)
    # проходив гейт непоміченим.
    $legacyReaderCompoundAssignFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $compoundAssignDir = Join-Path $legacyReaderCompoundAssignFixtureRoot 'modules\BRAVO.CompoundAssign'
        [void][IO.Directory]::CreateDirectory($compoundAssignDir)
        [IO.File]::WriteAllText(
            (Join-Path $compoundAssignDir 'BRAVO.CompoundAssign.psm1'),
            "function Invoke-Sneaky { `$cmd = 'Read-BRAVOLegacyPrimaryRawOverrides'; `$cmd += ''; & `$cmd -ConfigPath X }",
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderCompoundAssignFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderCompoundAssignFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $legacyReaderCompoundAssignFixtureResult.Passed -and
                @($legacyReaderCompoundAssignFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') -and $_.Contains('BRAVO.CompoundAssign.psm1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CutoverGateTreatsCompoundAssignmentAsNonReplacing" `
            -Failure "складене присвоєння (+=) ПІСЛЯ ризикового простого присвоєння (`$cmd = 'Read-...'; `$cmd += ''; & `$cmd) не сміє 'очищати' ризиковий запис — PowerShell реально й надалі викликає рідер, гейт мусить провалюватись"
    } finally {
        Remove-Item -LiteralPath $legacyReaderCompoundAssignFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateIgnoresScriptBlockLiteralAssignment ---
    # Codex-знахідка (gate-review, R9) — РЕАЛЬНИЙ false-positive баг у
    # самій реалізації гейту: рекурсивний FindAll шукав StringConstantExpressionAst
    # будь-де в правій частині присвоєння, включно з УСЕРЕДИНІ вкладеного
    # scriptblock-виразу. `$cmd = { 'Read-...' }` записувало ризиковий
    # літерал, хоча `& $cmd` реально виконує СКРИПТБЛОК (що просто
    # повертає текст, не викликає жодної команди) — легітимний код хибно
    # провалював гейт.
    $legacyReaderScriptBlockLiteralFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $sbLiteralDir = Join-Path $legacyReaderScriptBlockLiteralFixtureRoot 'modules\BRAVO.ScriptBlockLiteral'
        [void][IO.Directory]::CreateDirectory($sbLiteralDir)
        [IO.File]::WriteAllText(
            (Join-Path $sbLiteralDir 'BRAVO.ScriptBlockLiteral.psm1'),
            "function Invoke-Harmless { `$cmd = { 'Read-BRAVOLegacyPrimaryRawOverrides' }; & `$cmd -Path X }",
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderScriptBlockLiteralFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderScriptBlockLiteralFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                $legacyReaderScriptBlockLiteralFixtureResult.Passed -and
                @($legacyReaderScriptBlockLiteralFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') }).Count -eq 0
            ) `
            -Name "ReleaseGate/CutoverGateIgnoresScriptBlockLiteralAssignment" `
            -Failure "присвоєння змінної SCRIPTBLOCK-виразу, що лише МІСТИТЬ текст імені legacy-рідера як рядок усередині блоку (не виклик), не сміє провалювати гейт LEGACY_READER_ISOLATION; отримано Failures=$($legacyReaderScriptBlockLiteralFixtureResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $legacyReaderScriptBlockLiteralFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateNormalizesScopeQualifiedVariableName ---
    # Codex-знахідка (gate-review, R9): VariablePath.UserPath включає
    # scope-префікс (`script:`) як частину рядка — `$script:reader` і
    # `$reader` (яке PowerShell реально резолвить з батьківського scope
    # до того самого значення) порівнювались як РІЗНІ імена, тож ця
    # форма parent-scope indirection досі проходила гейт непоміченою.
    $legacyReaderScopeQualifiedFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $scopeQualifiedDir = Join-Path $legacyReaderScopeQualifiedFixtureRoot 'modules\BRAVO.ScopeQualified'
        [void][IO.Directory]::CreateDirectory($scopeQualifiedDir)
        [IO.File]::WriteAllText(
            (Join-Path $scopeQualifiedDir 'BRAVO.ScopeQualified.psm1'),
            "`$script:reader = 'Read-BRAVOLegacyPrimaryRawOverrides'`nfunction Invoke-FromNested { & `$reader -ConfigPath X }",
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderScopeQualifiedFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderScopeQualifiedFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $legacyReaderScopeQualifiedFixtureResult.Passed -and
                @($legacyReaderScopeQualifiedFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') -and $_.Contains('BRAVO.ScopeQualified.psm1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CutoverGateNormalizesScopeQualifiedVariableName" `
            -Failure "`$script:reader = 'Read-...' на рівні модуля, використане через незакваліфіковане `& `$reader` усередині вкладеної функції, мусить провалювати гейт LEGACY_READER_ISOLATION — scope-префікс не повинен заважати зіставленню"
    } finally {
        Remove-Item -LiteralPath $legacyReaderScopeQualifiedFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateRespectsExplicitScriptScopeQualifierAtCallSite ---
    # Codex-знахідка (gate-review, R10) — прямий регрес від R9: нормалізація
    # scope-префіксу знімала ЗМІСТ явного кваліфікатора В МІСЦІ ВИКЛИКУ.
    # `& $script:reader` ЦІЛЕСПРЯМОВАНО звертається лише до script-scope
    # (кореня файлу), навіть коли вкладена функція має власне
    # незакваліфіковане `$reader`, що затінює його локально — PowerShell
    # реально виконує рідер зі script-scope, а не локальне безпечне
    # значення.
    $legacyReaderExplicitScopeFixtureRoot = New-BRAVOReleaseGateFixtureRoot -EntryPointText 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'
    try {
        $explicitScopeDir = Join-Path $legacyReaderExplicitScopeFixtureRoot 'modules\BRAVO.QualifiedCall'
        [void][IO.Directory]::CreateDirectory($explicitScopeDir)
        [IO.File]::WriteAllText(
            (Join-Path $explicitScopeDir 'BRAVO.QualifiedCall.psm1'),
            "`$script:reader = 'Read-BRAVOLegacyPrimaryRawOverrides'`nfunction Invoke-Explicit { `$reader = 'Get-ChildItem'; & `$script:reader -ConfigPath X }",
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReaderExplicitScopeFixtureResult = Test-BRAVOConfigV2CutoverGates -Root $legacyReaderExplicitScopeFixtureRoot -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $legacyReaderExplicitScopeFixtureResult.Passed -and
                @($legacyReaderExplicitScopeFixtureResult.Failures | Where-Object { $_.Contains('LEGACY_READER_ISOLATION') -and $_.Contains('BRAVO.QualifiedCall.psm1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CutoverGateRespectsExplicitScriptScopeQualifierAtCallSite" `
            -Failure "явний `$script: кваліфікатор у МІСЦІ ВИКЛИКУ (`& `$script:reader) мусить цілеспрямовано резолвитись зі script-scope, навіть коли вкладена функція має власне незакваліфіковане `$reader — гейт не сміє пропускати цей виклик лише тому, що знайшов найближче (але семантично неправильне) локальне присвоєння"
    } finally {
        Remove-Item -LiteralPath $legacyReaderExplicitScopeFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGateSharedByReleaseArtifactAndPRWorkflow ---
    # Той самий клас перевірки, що ConfigParity/DecisionLogicIsNotInlineYaml
    # вище: обидва споживачі мусять dot-source'ити ОДНУ канонічну
    # реалізацію, а не тримати незалежні копії регексу/переліку.
    $releaseArtifactBuilderText = [IO.File]::ReadAllText((Join-Path $root 'ci\New-BRAVOReleaseArtifact.ps1'), [Text.Encoding]::UTF8)
    $prGateScriptText = [IO.File]::ReadAllText((Join-Path $root 'ci\Test-BRAVOConfigV2CutoverGatesOnPullRequest.ps1'), [Text.Encoding]::UTF8)
    Test-BRAVOCondition `
        -Condition (
            $releaseArtifactBuilderText.Contains('BRAVOConfigV2CutoverGates.ps1') -and
            $releaseArtifactBuilderText.Contains('Test-BRAVOConfigV2CutoverGates') -and
            $prGateScriptText.Contains('BRAVOConfigV2CutoverGates.ps1') -and
            $prGateScriptText.Contains('Test-BRAVOConfigV2CutoverGates')
        ) `
        -Name "ReleaseGate/CutoverGateSharedByReleaseArtifactAndPRWorkflow" `
        -Failure "ci\New-BRAVOReleaseArtifact.ps1 (release-шлях) і ci\Test-BRAVOConfigV2CutoverGatesOnPullRequest.ps1 (PR-шлях, issue #216 H-1) мусять dot-source'ити ОДНУ спільну ci\BRAVOConfigV2CutoverGates.ps1, а не тримати незалежні копії гейту"

    # --- ReleaseGate/PullRequestWorkflowInvokesCutoverGateUnconditionally ---
    $configParityWorkflowTextForGate = [IO.File]::ReadAllText((Join-Path $root '.github\workflows\config-parity.yml'), [Text.Encoding]::UTF8)
    Test-BRAVOCondition `
        -Condition ($configParityWorkflowTextForGate.Contains('Test-BRAVOConfigV2CutoverGatesOnPullRequest.ps1')) `
        -Name "ReleaseGate/PullRequestWorkflowInvokesCutoverGateUnconditionally" `
        -Failure "config-parity.yml (issue #216, H-1) мусить викликати ci\Test-BRAVOConfigV2CutoverGatesOnPullRequest.ps1 — інакше гейт LEGACY_CONFIG_REMOVED/AUTOEXEC і далі спрацьовує лише при tag/workflow_dispatch, ніколи на pull_request"
}

# =====================================================================
# ReleaseGate/CallerCompleteness* (issue #154, B7): AST-інваріант повноти
# переліку AUTOEXEC-цілей (Test-BRAVOConfigLoaderCallerCompleteness у
# ci\BRAVOConfigV2CutoverGates.ps1). Підстава — підтверджений дефект:
# BRAVO_OPERATIONS_HEARTBEAT.ps1 (PR #225) викликав Import-BravoConfiguration
# без -DisallowLegacyPrimaryAutoDetect і не був у фіксованому переліку, тож
# гейт LEGACY_CONFIG_AUTOEXEC його не бачив. Синтетичні фікстури —
# логіка інваріанта; два останні тести — фактичне дерево репозиторію
# (обидва провалюються на heartbeat до B7).
# =====================================================================
& {
    . (Join-Path $root 'ci\BRAVOConfigV2CutoverGates.ps1')

    function New-BRAVOCallerCompletenessFixtureRoot {
        # Hashtable «відносний шлях -> текст»; каталоги створюються за потреби.
        param([hashtable]$File)
        $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_CALLERCOMPLETENESS_{0}" -f [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($fixtureRoot)
        foreach ($relativePath in @($File.Keys)) {
            $filePath = Join-Path $fixtureRoot $relativePath
            [void][IO.Directory]::CreateDirectory((Split-Path -Path $filePath -Parent))
            [IO.File]::WriteAllText($filePath, [string]$File[$relativePath], (New-Object Text.UTF8Encoding($false)))
        }
        return $fixtureRoot
    }

    $callerCompletenessListedCall = 'Import-BravoConfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect'

    # --- ReleaseGate/CallerCompletenessDetectsUnlistedRootCaller ---
    $callerCompletenessRootFixture = New-BRAVOCallerCompletenessFixtureRoot -File @{
        'entry.ps1' = $callerCompletenessListedCall
        'BRAVO_NEW_OPERATOR_TOOL.ps1' = 'Import-BravoConfiguration -ConfigRoot X'
    }
    try {
        $callerCompletenessRootResult = Test-BRAVOConfigLoaderCallerCompleteness -Root $callerCompletenessRootFixture -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $callerCompletenessRootResult.Passed -and
                @($callerCompletenessRootResult.Failures | Where-Object { $_.Contains('CONFIG_LOADER_CALLER_COMPLETENESS') -and $_.Contains('BRAVO_NEW_OPERATOR_TOOL.ps1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CallerCompletenessDetectsUnlistedRootCaller" `
            -Failure "кореневий скрипт, що викликає Import-BravoConfiguration, але відсутній у переліку AUTOEXEC-цілей (клас дефекту heartbeat, PR #225), мусить провалювати CONFIG_LOADER_CALLER_COMPLETENESS; отримано Failures=$($callerCompletenessRootResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $callerCompletenessRootFixture -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CallerCompletenessDetectsUnlistedModuleCaller ---
    $callerCompletenessModuleFixture = New-BRAVOCallerCompletenessFixtureRoot -File @{
        'entry.ps1' = $callerCompletenessListedCall
        'modules\BRAVO.NewDomain\BRAVO.NewDomain.Runtime.ps1' = "function Invoke-X {`r`n    import-bravoconfiguration -ConfigRoot X -DisallowLegacyPrimaryAutoDetect`r`n}"
    }
    try {
        $callerCompletenessModuleResult = Test-BRAVOConfigLoaderCallerCompleteness -Root $callerCompletenessModuleFixture -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $callerCompletenessModuleResult.Passed -and
                @($callerCompletenessModuleResult.Failures | Where-Object { $_.Contains('modules\BRAVO.NewDomain\BRAVO.NewDomain.Runtime.ps1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CallerCompletenessDetectsUnlistedModuleCaller" `
            -Failure "новий *.Runtime.ps1 під modules\, що викликає Import-BravoConfiguration (у будь-якому регістрі, усередині функції), мусить провалювати CONFIG_LOADER_CALLER_COMPLETENESS, доки його не внесено в перелік — навіть із прапорцем (гейт AUTOEXEC перевіряє лише перелічені файли); отримано Failures=$($callerCompletenessModuleResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $callerCompletenessModuleFixture -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CallerCompletenessIgnoresNonCallMentions ---
    # Коментар, рядковий літерал, here-string і визначення функції з тим
    # самим ім'ям — не виклик (реальні форми в дереві:
    # BRAVO_CONFIG_INTEGRATE.ps1 — regex-рядок, BRAVO_CONFIG_LOADER.ps1 —
    # визначення, BRAVO.Configurator.Effective.psm1 — текст дочірнього процесу).
    $callerCompletenessNonCallFixture = New-BRAVOCallerCompletenessFixtureRoot -File @{
        'entry.ps1' = $callerCompletenessListedCall
        'BRAVO_COMMENT_ONLY.ps1' = "# Import-BravoConfiguration -ConfigRoot X`r`n`$pattern = 'Import-BravoConfiguration\s+-ConfigRoot'`r`n`$child = @`"`r`nImport-BravoConfiguration -ConfigRoot X`r`n`"@`r`n"
        'BRAVO_DEFINES_ONLY.ps1' = "function Import-BravoConfiguration { param(`$ConfigRoot) }"
    }
    try {
        $callerCompletenessNonCallResult = Test-BRAVOConfigLoaderCallerCompleteness -Root $callerCompletenessNonCallFixture -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition ($callerCompletenessNonCallResult.Passed -and @($callerCompletenessNonCallResult.CallerRelativePath).Count -eq 1) `
            -Name "ReleaseGate/CallerCompletenessIgnoresNonCallMentions" `
            -Failure "коментар/рядковий літерал/here-string/визначення функції Import-BravoConfiguration не є викликом і не сміють провалювати CONFIG_LOADER_CALLER_COMPLETENESS (AST, не текстовий пошук); отримано Callers=$(@($callerCompletenessNonCallResult.CallerRelativePath) -join ', ') Failures=$($callerCompletenessNonCallResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $callerCompletenessNonCallFixture -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CallerCompletenessAllowsSanctionedHarnessOnly ---
    $callerCompletenessHarnessFixture = New-BRAVOCallerCompletenessFixtureRoot -File @{
        'entry.ps1' = $callerCompletenessListedCall
        'BRAVO_SELF_TEST.ps1' = 'Import-BravoConfiguration -ConfigRoot X'
    }
    try {
        $callerCompletenessHarnessResult = Test-BRAVOConfigLoaderCallerCompleteness -Root $callerCompletenessHarnessFixture -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                $callerCompletenessHarnessResult.Passed -and
                @(Get-BRAVOConfigLoaderSanctionedNonProductionCallerRelativePath).Count -eq 1 -and
                @(Get-BRAVOConfigLoaderSanctionedNonProductionCallerRelativePath)[0] -eq 'BRAVO_SELF_TEST.ps1'
            ) `
            -Name "ReleaseGate/CallerCompletenessAllowsSanctionedHarnessOnly" `
            -Failure "єдиний санкціонований НЕ-production викликач — тестовий harness BRAVO_SELF_TEST.ps1; розширення винятку потребує окремого обґрунтування; отримано Passed=$($callerCompletenessHarnessResult.Passed), виняток=$(@(Get-BRAVOConfigLoaderSanctionedNonProductionCallerRelativePath) -join ', ')"
    } finally {
        Remove-Item -LiteralPath $callerCompletenessHarnessFixture -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CallerCompletenessDetectsFlaglessCallInListedEntrypoint ---
    # Файл у переліку з ПЕРШИМ викликом із прапорцем проходить текстовий
    # гейт LEGACY_CONFIG_AUTOEXEC, навіть якщо далі є другий виклик без
    # прапорця, з явним :$false або через splat без прапорця. Кожен
    # AST-виклик у production-entrypoint мусить прив'язувати прапорець.
    $callerCompletenessFlaglessFixture = New-BRAVOCallerCompletenessFixtureRoot -File @{
        'entry.ps1' = $callerCompletenessListedCall + "`r`nfunction Invoke-Second { Import-BravoConfiguration -ConfigRoot Y }"
        'entry2.ps1' = $callerCompletenessListedCall + "`r`nImport-BravoConfiguration -ConfigRoot Y -DisallowLegacyPrimaryAutoDetect:`$false"
        'entry3.ps1' = "`$loaderArgs = @{ ConfigRoot = 'Y' }`r`nImport-BravoConfiguration @loaderArgs"
    }
    $callerCompletenessFlaggedFixture = New-BRAVOCallerCompletenessFixtureRoot -File @{
        'entry.ps1' = $callerCompletenessListedCall + "`r`nfunction Invoke-Second { Import-BravoConfiguration -ConfigRoot Y -DisallowLegacyPrimaryAutoDetect:`$true }"
        'entry2.ps1' = "`$loaderArgs = @{ ConfigRoot = 'Y' }`r`nImport-BravoConfiguration @loaderArgs -DisallowLegacyPrimaryAutoDetect"
    }
    try {
        $callerCompletenessFlaglessResult = Test-BRAVOConfigLoaderCallerCompleteness -Root $callerCompletenessFlaglessFixture -ProductionEntryPointRelativePath @('entry.ps1', 'entry2.ps1', 'entry3.ps1')
        $callerCompletenessFlaggedResult = Test-BRAVOConfigLoaderCallerCompleteness -Root $callerCompletenessFlaggedFixture -ProductionEntryPointRelativePath @('entry.ps1', 'entry2.ps1')
        $callerCompletenessFlaglessText = [string]::Join(' | ', @($callerCompletenessFlaglessResult.Failures))
        Test-BRAVOCondition `
            -Condition (
                -not $callerCompletenessFlaglessResult.Passed -and
                $callerCompletenessFlaglessText.Contains('entry.ps1:2') -and
                $callerCompletenessFlaglessText.Contains('entry2.ps1:2') -and
                $callerCompletenessFlaglessText.Contains('entry3.ps1:2') -and
                -not $callerCompletenessFlaglessText.Contains('entry.ps1:1') -and
                $callerCompletenessFlaggedResult.Passed
            ) `
            -Name "ReleaseGate/CallerCompletenessDetectsFlaglessCallInListedEntrypoint" `
            -Failure "кожен виклик Import-BravoConfiguration у переліченому production-entrypoint мусить прив'язувати -DisallowLegacyPrimaryAutoDetect (другий виклик без прапорця, :`$false і splat без прапорця — FAIL; :`$true і splat із явним прапорцем — PASS); отримано Flagless.Failures=$callerCompletenessFlaglessText Flagged.Passed=$($callerCompletenessFlaggedResult.Passed) Flagged.Failures=$([string]::Join(' | ', @($callerCompletenessFlaggedResult.Failures)))"
    } finally {
        Remove-Item -LiteralPath $callerCompletenessFlaglessFixture -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $callerCompletenessFlaggedFixture -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CallerCompletenessFailsClosedOnParseError ---
    $callerCompletenessParseFixture = New-BRAVOCallerCompletenessFixtureRoot -File @{
        'entry.ps1' = $callerCompletenessListedCall
        'BRAVO_BROKEN.ps1' = "if (`$true) {`r`n    Import-BravoConfiguration -ConfigRoot X`r`n"
    }
    try {
        $callerCompletenessParseResult = Test-BRAVOConfigLoaderCallerCompleteness -Root $callerCompletenessParseFixture -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $callerCompletenessParseResult.Passed -and
                @($callerCompletenessParseResult.Failures | Where-Object { $_.Contains('BRAVO_BROKEN.ps1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CallerCompletenessFailsClosedOnParseError" `
            -Failure "файл, який AST-парсер не розібрав, не можна довести безпечним — CONFIG_LOADER_CALLER_COMPLETENESS мусить відмовити явно, а не пропустити його; отримано Failures=$($callerCompletenessParseResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $callerCompletenessParseFixture -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CutoverGatesEnforceCallerCompleteness ---
    # Спільна функція гейтів (release-artifact + PR-workflow) мусить
    # застосовувати інваріант, а не лише мати його поруч.
    $callerCompletenessCutoverFixture = New-BRAVOCallerCompletenessFixtureRoot -File @{
        'entry.ps1' = $callerCompletenessListedCall
        'BRAVO_NEW_OPERATOR_TOOL.ps1' = 'Import-BravoConfiguration -ConfigRoot X'
    }
    try {
        $callerCompletenessCutoverResult = Test-BRAVOConfigV2CutoverGates -Root $callerCompletenessCutoverFixture -ProductionEntryPointRelativePath @('entry.ps1')
        Test-BRAVOCondition `
            -Condition (
                -not $callerCompletenessCutoverResult.Passed -and
                @($callerCompletenessCutoverResult.Failures | Where-Object { $_.Contains('CONFIG_LOADER_CALLER_COMPLETENESS') -and $_.Contains('BRAVO_NEW_OPERATOR_TOOL.ps1') }).Count -eq 1
            ) `
            -Name "ReleaseGate/CutoverGatesEnforceCallerCompleteness" `
            -Failure "Test-BRAVOConfigV2CutoverGates (спільна для ci\New-BRAVOReleaseArtifact.ps1 і PR-workflow) мусить провалюватись на неперелічених викликачах Import-BravoConfiguration; отримано Failures=$($callerCompletenessCutoverResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $callerCompletenessCutoverFixture -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ReleaseGate/CallerCompletenessHoldsOnRepositoryTree ---
    # Фактичне дерево: кожен кореневий *.ps1 і кожен файл modules\, що
    # викликає Import-BravoConfiguration, перелічений. До B7 провалювався
    # на BRAVO_OPERATIONS_HEARTBEAT.ps1.
    $callerCompletenessRepositoryResult = Test-BRAVOConfigLoaderCallerCompleteness -Root $root
    Test-BRAVOCondition `
        -Condition (
            $callerCompletenessRepositoryResult.Passed -and
            @($callerCompletenessRepositoryResult.CallerRelativePath | Where-Object { $_ -eq 'BRAVO_OPERATIONS_HEARTBEAT.ps1' }).Count -eq 1
        ) `
        -Name "ReleaseGate/CallerCompletenessHoldsOnRepositoryTree" `
        -Failure "кожен фактичний викликач Import-BravoConfiguration серед кореневих *.ps1 і modules\ мусить бути в Get-BRAVOProductionEntryPointRelativePath (або в санкціонованому винятку); отримано Callers=$(@($callerCompletenessRepositoryResult.CallerRelativePath) -join ', ') Failures=$($callerCompletenessRepositoryResult.Failures -join ' | ')"

    # --- ReleaseGate/AutoExecGuardHoldsForEveryRepositoryTarget ---
    # Гейт LEGACY_CONFIG_AUTOEXEC на ФАКТИЧНОМУ вмісті кожної цілі переліку.
    # Копії цілей — у тимчасове дзеркало, а не -Root $root: на встановленому
    # сервері поруч із комплектом законно може лежати застарілий BRAVO.config
    # (Update-BRAVOServer.ps1 його не видаляє), і гейт LEGACY_CONFIG_REMOVED
    # хибно провалив би self-test там, де він не про це. До B7 провалювався
    # на BRAVO_OPERATIONS_HEARTBEAT.ps1 (виклик без прапорця).
    $autoExecMirrorRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_AUTOEXEC_MIRROR_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $autoExecMirrorFiles = @{}
        foreach ($autoExecTargetRelativePath in @(Get-BRAVOProductionEntryPointRelativePath)) {
            $autoExecTargetSourcePath = Join-Path $root $autoExecTargetRelativePath
            if (Test-Path -LiteralPath $autoExecTargetSourcePath -PathType Leaf) {
                $autoExecMirrorFiles[$autoExecTargetRelativePath] = [IO.File]::ReadAllText($autoExecTargetSourcePath, [Text.Encoding]::UTF8)
            }
        }
        [void][IO.Directory]::CreateDirectory($autoExecMirrorRoot)
        foreach ($autoExecMirrorRelativePath in @($autoExecMirrorFiles.Keys)) {
            $autoExecMirrorPath = Join-Path $autoExecMirrorRoot $autoExecMirrorRelativePath
            [void][IO.Directory]::CreateDirectory((Split-Path -Path $autoExecMirrorPath -Parent))
            [IO.File]::WriteAllText($autoExecMirrorPath, [string]$autoExecMirrorFiles[$autoExecMirrorRelativePath], (New-Object Text.UTF8Encoding($false)))
        }
        $autoExecMirrorResult = Test-BRAVOConfigV2CutoverGates -Root $autoExecMirrorRoot
        Test-BRAVOCondition `
            -Condition (
                $autoExecMirrorResult.Passed -and
                $autoExecMirrorFiles.Count -eq @(Get-BRAVOProductionEntryPointRelativePath).Count
            ) `
            -Name "ReleaseGate/AutoExecGuardHoldsForEveryRepositoryTarget" `
            -Failure "кожна ціль Get-BRAVOProductionEntryPointRelativePath мусить існувати в дереві й передавати ефективний -DisallowLegacyPrimaryAutoDetect; знайдено $($autoExecMirrorFiles.Count) з $(@(Get-BRAVOProductionEntryPointRelativePath).Count) цілей, Failures=$($autoExecMirrorResult.Failures -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $autoExecMirrorRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# Health — Config V2 контракт (issue #216, §9 п.9): Health був єдиним
# доменом без ЖОДНОГО прямого доказу дотримання Config V2 (лише
# опосередковано — через свою присутність у канонічному списку 14
# production entrypoint'ів гейту AUTOEXEC, ReleaseGate/* вище). Повний
# Invoke-BRAVOHealth тут НЕ запускається — той самий принцип, що вже
# документований на початку BRAVO_SELF_TEST.Archive.ps1 ("Main() ... не
# запускається тут повністю"): реальні health-перевірки дисків/сервісів
# нереалістично й небезпечно відтворювати в self-test. Натомість —
# структурна перевірка того самого класу, що вже існує для інших
# доменів у цьому файлі: Health.Runtime.ps1 отримує ефективну
# конфігурацію ВИКЛЮЧНО через канонічний Import-BravoConfiguration і
# ніде незалежно не парсить BRAVO.config сам (що відкрило б другий,
# непокритий Proof B шлях просочування legacy-значень).
& {
    $healthRuntimeTextForConfigV2 = [IO.File]::ReadAllText(
        (Join-Path $root 'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1'), [Text.Encoding]::UTF8)

    # --- ConfigParity/HealthRuntimeUsesCanonicalLoaderOnly ---
    Test-BRAVOCondition `
        -Condition (
            $healthRuntimeTextForConfigV2.Contains('Import-BravoConfiguration') -and
            $healthRuntimeTextForConfigV2.Contains('-DisallowLegacyPrimaryAutoDetect')
        ) `
        -Name "ConfigParity/HealthRuntimeUsesCanonicalLoaderOnly" `
        -Failure "BRAVO.Health.Runtime.ps1 мусить завантажувати конфігурацію через Import-BravoConfiguration -DisallowLegacyPrimaryAutoDetect (той самий гейт, що ReleaseGate/CutoverGateSharedByReleaseArtifactAndPRWorkflow вище перевіряє текстово через AUTOEXEC-регекс)"

    # --- ConfigParity/HealthRuntimeNoIndependentLegacyConfigParsing ---
    $healthIndependentConfigParsingPattern = [regex]::Matches(
        $healthRuntimeTextForConfigV2,
        '(?i)Get-Content[^\n]*BRAVO\.config|ConvertFrom-StringData[^\n]*BRAVO\.config'
    )
    Test-BRAVOCondition `
        -Condition ($healthIndependentConfigParsingPattern.Count -eq 0) `
        -Name "ConfigParity/HealthRuntimeNoIndependentLegacyConfigParsing" `
        -Failure "BRAVO.Health.Runtime.ps1 не повинен незалежно парсити BRAVO.config поза канонічним Import-BravoConfiguration — знайдено $($healthIndependentConfigParsingPattern.Count) підозрілих збігів; такий другий шлях не покривався би Proof B (ConfigLoader.ps1)"
}

# =====================================================================
# Володіння site-конфігурацією при розкатці (#154, B6)
# =====================================================================
# Site-файл — стан ОПЕРАТОРА, комплект — стан вендора. Ці перевірки
# статичні (реальні deploy-скрипти вимагають Windows-сервера, robocopy,
# служб і Планувальника), але вони ловлять саме той клас регресії, який
# коштує оператору втрати налаштувань: поява /MIR, зникнення /XF,
# автоматичне створення активного override з прикладу.
$deployUpdateText = [IO.File]::ReadAllText((Join-Path $root 'deploy\Update-BRAVOServer.ps1'), [Text.Encoding]::UTF8)
$deployInstallText = [IO.File]::ReadAllText((Join-Path $root 'deploy\Install-BRAVOServer.ps1'), [Text.Encoding]::UTF8)
$deployReadmeText = [IO.File]::ReadAllText((Join-Path $root 'deploy\README.md'), [Text.Encoding]::UTF8)

# --- Update/PreservesExistingLocalConfig ---
# Виключення з копіювання — єдине, що стоїть між оновленням і site-файлом.
Test-BRAVOCondition `
    -Condition (
        $deployUpdateText.Contains("'BRAVO.local.config'") -and
        $deployUpdateText.Contains('$excludeFiles') -and
        $deployUpdateText.Contains("'/XF'")
    ) `
    -Name "Update/PreservesExistingLocalConfig" `
    -Failure "deploy\Update-BRAVOServer.ps1 мусить виключати BRAVO.local.config з копіювання через /XF — інакше оновлення затирає site-налаштування сервера"

# --- Update/DoesNotDeleteLocalConfig ---
# /MIR і /PURGE роблять robocopy знищувальним: усе, чого немає в джерелі,
# зникає з призначення. Site-файлу в артефакті немає за визначенням, тому
# поява будь-якого з цих ключів = мовчазне видалення налаштувань.
# Порівнюється ВИКОНУВАНИЙ код, не коментарі: обидва скрипти навмисно
# пояснюють у коментарях, ЧОМУ /MIR і /PURGE тут заборонені, і наївний
# пошук по всьому тексту спрацював би саме на цих поясненнях.
$deployDestructiveSwitches = @('/MIR', '/PURGE')
$deployExecutableDeployLines = @(
    @($deployUpdateText -split "`r?`n") + @($deployInstallText -split "`r?`n") |
        Where-Object { -not ($_.TrimStart().StartsWith('#')) }
)
$deployDestructiveFound = @($deployDestructiveSwitches | Where-Object {
    $switchName = $_
    @($deployExecutableDeployLines | Where-Object { $_.Contains($switchName) }).Count -gt 0
})
Test-BRAVOCondition `
    -Condition ($deployDestructiveFound.Count -eq 0) `
    -Name "Update/DoesNotDeleteLocalConfig" `
    -Failure "скрипти розкатки не мають права використовувати знищувальні ключі robocopy; знайдено: $($deployDestructiveFound -join ', ')"

# --- Update/DoesNotReplaceLocalConfigWithExample ---
# Оновлення не має жодної причини торкатись прикладу як джерела для
# активного файлу: відсутній site-файл — легальний стан, а не дефект.
Test-BRAVOCondition `
    -Condition (-not ($deployUpdateText -match 'Copy-Item[^\r\n]*BRAVO\.local\.config\.example')) `
    -Name "Update/DoesNotReplaceLocalConfigWithExample" `
    -Failure "deploy\Update-BRAVOServer.ps1 не повинен створювати активний BRAVO.local.config із прикладу — мовчазний override є зміною конфігурації, якої оператор не просив"

# --- Install/DoesNotTreatExampleAsActiveConfig ---
# Інсталяція копіює приклад ЛИШЕ на явний -SeedLocalConfig і ніколи не
# перезаписує наявний файл.
Test-BRAVOCondition `
    -Condition (
        $deployInstallText.Contains('$SeedLocalConfig') -and
        $deployInstallText.Contains('BRAVO.local.config уже існує') -and
        ($deployInstallText -match '(?s)Test-Path -LiteralPath \$localConfig[^\r\n]*\r?\n[^}]*?\} elseif \(\$SeedLocalConfig\)')
    ) `
    -Name "Install/DoesNotTreatExampleAsActiveConfig" `
    -Failure "deploy\Install-BRAVOServer.ps1 мусить створювати BRAVO.local.config з прикладу ЛИШЕ за -SeedLocalConfig і не чіпати наявний файл"

# --- Update/NewRuntimeKeepsOperatorOwnedConfigAccordingToMigrationContract ---
# Автоматичного перенесення runtime-каталогу не існує — і саме тому
# site-файл не може зникнути під час "переїзду". Контракт мусить бути
# записаний в обох місцях: у самому скрипті й у документації розкатки.
Test-BRAVOCondition `
    -Condition (
        $deployUpdateText.Contains('не перейменовує каталог runtime') -and
        $deployReadmeText.Contains('перенесення runtime-каталогу — ручна операція')
    ) `
    -Name "Update/NewRuntimeKeepsOperatorOwnedConfigAccordingToMigrationContract" `
    -Failure "контракт «оновлення розгортає на місці, перенесення каталогу — ручна операція оператора» мусить бути зафіксований і в deploy\Update-BRAVOServer.ps1, і в deploy\README.md"

# --- Deploy/LocalConfigNeverShipsInArtifact ---
# Site-файл одного сервера не може приїхати на інший: він git-ignored, а
# артефакт збирається виключно git archive.
$deployGitignoreText = [IO.File]::ReadAllText((Join-Path $root '.gitignore'), [Text.Encoding]::UTF8)
$deployArtifactText = [IO.File]::ReadAllText((Join-Path $root 'ci\New-BRAVOReleaseArtifact.ps1'), [Text.Encoding]::UTF8)
Test-BRAVOCondition `
    -Condition (
        ($deployGitignoreText -match '(?m)^BRAVO\.local\.config\s*$') -and
        $deployArtifactText.Contains('archive --format=zip')
    ) `
    -Name "Deploy/LocalConfigNeverShipsInArtifact" `
    -Failure "BRAVO.local.config мусить лишатись git-ignored, а артефакт — збиратись через git archive, інакше site-файл одного сервера потрапить у комплект для інших"

# --- Deploy/OwnershipDocumentedForOperator ---
Test-BRAVOCondition `
    -Condition (
        $deployReadmeText.Contains('Володіння: що належить оператору') -and
        $deployReadmeText.Contains('оновлення ніколи не створює site-файл із прикладу')
    ) `
    -Name "Deploy/OwnershipDocumentedForOperator" `
    -Failure "deploy\README.md мусить описувати межу володіння site-конфігурацією — інакше контракт існує лише в коді"

}

# --- #152: гейт релізу в скриптах розкатки ---------------------------------
# Дефект, який закриває цей блок: prerelease-комплект розгортався в установі
# без жодного свідомого рішення оператора (Install лише попереджав, Update не
# перевіряв канал узагалі). Саме так сервер парку тривало
# працював у production на
# 5.2.0-rc.2 — версії, тега якої в репозиторії не існує.
#
# Блок виконується у власній області (& { ... }) за конвенцією #163.

& {
    $deployRoot = Join-Path $root 'deploy'
    $releaseGatePath = Join-Path $deployRoot 'BRAVO.Deploy.ReleaseGate.ps1'
    $installText = [IO.File]::ReadAllText((Join-Path $deployRoot 'Install-BRAVOServer.ps1'), [Text.Encoding]::UTF8)
    $updateText = [IO.File]::ReadAllText((Join-Path $deployRoot 'Update-BRAVOServer.ps1'), [Text.Encoding]::UTF8)

    # --- Структурні guard-и: одна реалізація політики, а не дві ------------

    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $releaseGatePath -PathType Leaf) `
        -Name "Deploy/ReleaseGatePolicyFileExists" `
        -Failure "deploy\BRAVO.Deploy.ReleaseGate.ps1 — канонічний власник політики гейта релізу; без нього обидва скрипти розкатки завели б власні копії"

    Test-BRAVOCondition `
        -Condition (
            $installText.Contains("Join-Path `$PSScriptRoot 'BRAVO.Deploy.ReleaseGate.ps1'") -and
            $updateText.Contains("Join-Path `$PSScriptRoot 'BRAVO.Deploy.ReleaseGate.ps1'")
        ) `
        -Name "Deploy/BothDeployScriptsUseSingleReleaseGate" `
        -Failure "обидва скрипти розкатки мусять брати політику гейта з BRAVO.Deploy.ReleaseGate.ps1 — інакше рішення 'що можна розгортати' існує у двох копіях, які розійдуться"

    # Копія рядка політики в самому скрипті розкатки означала б другу
    # реалізацію: назва каналу мусить жити рівно в одному файлі.
    Test-BRAVOCondition `
        -Condition (
            -not $installText.Contains("-ne 'stable'") -and
            -not $updateText.Contains("-ne 'stable'") -and
            -not $installText.Contains("-eq 'stable'") -and
            -not $updateText.Contains("-eq 'stable'")
        ) `
        -Name "Deploy/NoSecondChannelPolicyCopyInDeployScripts" `
        -Failure "скрипти розкатки не повинні самі порівнювати releaseChannel зі 'stable' — це робота BRAVO.Deploy.ReleaseGate.ps1"

    # Найпідступніша регресія: елевований перезапуск губить рішення оператора,
    # гейт спрацьовує вже під UAC, і причина виглядає як дефект комплекту.
    Test-BRAVOCondition `
        -Condition (
            $installText.Contains("if (`$AllowPrereleaseChannel) { [void]`$argumentParts.Add('-AllowPrereleaseChannel') }") -and
            $updateText.Contains("if (`$AllowPrereleaseChannel) { [void]`$argumentParts.Add('-AllowPrereleaseChannel') }")
        ) `
        -Name "Deploy/ElevationForwardsPrereleaseOverride" `
        -Failure "UAC-перезапуск мусить передавати -AllowPrereleaseChannel далі — інакше явне рішення оператора зникає при підйомі прав"

    # release-manifest.json — незалежне джерело провенансу. Доти розкатка
    # звіряла VERSION.json архіву сам із собою.
    Test-BRAVOCondition `
        -Condition (
            $installText.Contains("'release-manifest.json'") -and
            $updateText.Contains("'release-manifest.json'")
        ) `
        -Name "Deploy/BothDeployScriptsConsultReleaseManifest" `
        -Failure "обидва скрипти розкатки мусять звірятися з release-manifest.json — VERSION.json усередині архіву підтверджує лише сам себе"

    # --- Поведінкові перевірки самої політики ------------------------------
    # Файл — чисті функції без побічних ефектів, тому dot-source у ЦЮ область
    # безпечний і не лишає нічого після себе.
    . $releaseGatePath

    $stableVersion = [pscustomobject]@{
        packageVersion = '5.2.4'
        releaseChannel = 'stable'
        buildId        = '91db94c'
        sourceCommit   = '91db94c00000000000000000000000000000abcd'
    }
    $prereleaseVersion = [pscustomobject]@{
        packageVersion = '5.2.0-rc.2'
        releaseChannel = 'prerelease'
        buildId        = 'f7f6628'
        sourceCommit   = 'f7f66280000000000000000000000000000012ab'
    }

    $stableDecision = Get-BRAVODeployReleaseChannelDecision -VersionMetadata $stableVersion
    Test-BRAVOCondition `
        -Condition ($stableDecision.Allowed -and -not $stableDecision.OverrideUsed -and $stableDecision.Severity -eq 'Ok') `
        -Name "Deploy/ReleaseGateStableChannelIsAllowed" `
        -Failure "stable-канал мусить проходити гейт без override і без попередження"

    $refused = Get-BRAVODeployReleaseChannelDecision -VersionMetadata $prereleaseVersion
    Test-BRAVOCondition `
        -Condition (
            -not $refused.Allowed -and $refused.Severity -eq 'Error' -and
            $refused.Message.Contains('prerelease') -and
            $refused.Message.Contains('-AllowPrereleaseChannel')
        ) `
        -Name "Deploy/ReleaseGatePrereleaseIsRefusedByDefault" `
        -Failure "prerelease без явного рішення оператора мусить зупиняти розкатку, і повідомлення мусить називати канал і спосіб свідомо продовжити"

    $overridden = Get-BRAVODeployReleaseChannelDecision -VersionMetadata $prereleaseVersion -AllowPrereleaseChannel
    Test-BRAVOCondition `
        -Condition (
            $overridden.Allowed -and $overridden.OverrideUsed -and $overridden.Severity -eq 'Warning' -and
            $overridden.Message.Contains('журналі розкатки')
        ) `
        -Name "Deploy/ReleaseGatePrereleaseNeedsExplicitOverride" `
        -Failure "з -AllowPrereleaseChannel розкатка триває, але рішення мусить бути гучним і вимагати запису в журнал розкатки"

    # Відсутній канал — не доказ стабільності. Найтиповіше джерело: комплект,
    # зібраний не релізним конвеєром.
    $noChannel = Get-BRAVODeployReleaseChannelDecision -VersionMetadata ([pscustomobject]@{ packageVersion = '9.9.9' })
    Test-BRAVOCondition `
        -Condition (-not $noChannel.Allowed -and $noChannel.Message.Contains('(не вказано)')) `
        -Name "Deploy/ReleaseGateMissingChannelFailsClosed" `
        -Failure "VERSION.json без releaseChannel мусить зупиняти розкатку fail-closed, а не трактуватись як stable"

    # --- Провенанс ---------------------------------------------------------

    $goodManifest = [pscustomobject]@{
        schemaVersion  = 1
        packageVersion = '5.2.4'
        releaseChannel = 'stable'
        sourceCommit   = '91db94c00000000000000000000000000000abcd'
        buildId        = '91db94c'
        tag            = 'v5.2.4'
        artifact       = [pscustomobject]@{ name = 'BRAVO-Toolkit-5.2.4.zip'; sha256 = 'aa11bb22' }
    }

    $verdict = Get-BRAVODeployProvenanceVerdict -VersionMetadata $stableVersion `
        -ReleaseManifest $goodManifest -ArtifactSha256 'AA11BB22' -ExpectedTag 'v5.2.4'
    Test-BRAVOCondition `
        -Condition ($verdict.IsValid -and $verdict.Severity -eq 'Ok') `
        -Name "Deploy/ProvenanceAcceptsMatchingReleaseManifest" `
        -Failure "узгоджений release-manifest.json мусить підтверджувати провенанс; порівняння SHA-256 нечутливе до регістру"

    $shaMismatch = Get-BRAVODeployProvenanceVerdict -VersionMetadata $stableVersion `
        -ReleaseManifest $goodManifest -ArtifactSha256 'deadbeef' -ExpectedTag 'v5.2.4'
    Test-BRAVOCondition `
        -Condition (-not $shaMismatch.IsValid -and $shaMismatch.Message.Contains('sha256')) `
        -Name "Deploy/ProvenanceRejectsArtifactHashMismatch" `
        -Failure "архів, хеш якого не збігається з release-manifest.json, мусить відхилятись"

    $foreignManifest = [pscustomobject]@{
        packageVersion = '5.2.4'
        releaseChannel = 'stable'
        sourceCommit   = '0000000000000000000000000000000000000000'
        buildId        = '0000000'
        tag            = 'v5.2.4'
        artifact       = [pscustomobject]@{ sha256 = 'aa11bb22' }
    }
    $foreign = Get-BRAVODeployProvenanceVerdict -VersionMetadata $stableVersion `
        -ReleaseManifest $foreignManifest -ArtifactSha256 'aa11bb22' -ExpectedTag 'v5.2.4'
    Test-BRAVOCondition `
        -Condition (-not $foreign.IsValid -and $foreign.Message.Contains('sourceCommit')) `
        -Name "Deploy/ProvenanceRejectsForeignSourceCommit" `
        -Failure "розбіжність sourceCommit між VERSION.json і release-manifest.json мусить зупиняти розкатку"

    $tagMismatch = Get-BRAVODeployProvenanceVerdict -VersionMetadata $stableVersion `
        -ReleaseManifest $goodManifest -ArtifactSha256 'aa11bb22' -ExpectedTag 'v5.2.5'
    Test-BRAVOCondition `
        -Condition (-not $tagMismatch.IsValid -and $tagMismatch.Message.Contains('v5.2.5')) `
        -Name "Deploy/ProvenanceRejectsTagMismatch" `
        -Failure "артефакт іншого тега мусить відхилятись — інакше -Tag перестає щось означати"

    # Той самий інваріант, що накладає ci\New-BRAVOReleaseArtifact.ps1: його
    # порушення означає, що комплект зібраний не релізним конвеєром.
    $truncated = Get-BRAVODeployProvenanceVerdict -VersionMetadata ([pscustomobject]@{
        packageVersion = '5.2.4'; releaseChannel = 'stable'; buildId = '91db94c'; sourceCommit = '91db94c'
    })
    Test-BRAVOCondition `
        -Condition (-not $truncated.IsValid -and $truncated.Message.Contains('40-символьним')) `
        -Name "Deploy/ProvenanceRejectsTruncatedSourceCommit" `
        -Failure "sourceCommit, що не є повним git-hash, мусить відхилятись навіть без release-manifest.json"

    $wrongBuildId = Get-BRAVODeployProvenanceVerdict -VersionMetadata ([pscustomobject]@{
        packageVersion = '5.2.4'; releaseChannel = 'stable'; buildId = 'deadbee'
        sourceCommit = '91db94c00000000000000000000000000000abcd'
    })
    Test-BRAVOCondition `
        -Condition (-not $wrongBuildId.IsValid -and $wrongBuildId.Message.Contains('buildId')) `
        -Name "Deploy/ProvenanceRejectsBuildIdMismatch" `
        -Failure "buildId, що не є short(sourceCommit), мусить відхилятись"

    # Локальний zip без маніфесту — документований сценарій -ZipPath на сервері
    # без доступу до GitHub. Він мусить попереджати, а не блокувати.
    $noManifest = Get-BRAVODeployProvenanceVerdict -VersionMetadata $stableVersion
    Test-BRAVOCondition `
        -Condition (
            $noManifest.IsValid -and $noManifest.Severity -eq 'Warning' -and
            $noManifest.Message.Contains('release-manifest.json')
        ) `
        -Name "Deploy/ProvenanceWithoutManifestWarnsButDoesNotBlock" `
        -Failure "відсутній release-manifest.json мусить давати явне попередження, але не ламати документований сценарій -ZipPath"

    # Форма реального маніфесту не повинна розійтися з тим, що читає розкатка.
    $artifactBuilderText = [IO.File]::ReadAllText((Join-Path $root 'ci\New-BRAVOReleaseArtifact.ps1'), [Text.Encoding]::UTF8)
    $manifestFieldsUsedByDeploy = @('packageVersion', 'releaseChannel', 'sourceCommit', 'buildId', 'tag')
    $missingManifestFields = @(
        $manifestFieldsUsedByDeploy | Where-Object { -not $artifactBuilderText.Contains($_) }
    )
    Test-BRAVOCondition `
        -Condition (@($missingManifestFields).Count -eq 0) `
        -Name "Deploy/ReleaseManifestShapeMatchesArtifactBuilder" `
        -Failure ("release-manifest.json мусить містити поля, які читає розкатка; ci\New-BRAVOReleaseArtifact.ps1 не згадує: " +
            [string]::Join(', ', @($missingManifestFields)))
}

# --- #153: RC-матриця приймання по ОС --------------------------------------
# Дефект, який закриває цей блок: промоція RC -> stable не вимагала доказів
# з реальних хостів, а формальної матриці ОС у RELEASE_POLICY.md не було —
# лише епізодична згадка Server 2022/2016 у нотатці про acceptance 5.2.x.
# Підстава емпірична: обидва дефекти PR #148 відтворювались лише на реальних
# хостах і були невидимі для CI.
#
# Перевірки навмисно НЕ переписують класифікацію ОС: вона належить
# modules\BRAVO.Compatibility і SECURITY.md. Тут доводиться лише те, що
# матриця не винаходить паралельну класифікацію і не осиротіла.
#
# Блок виконується у власній області (& { ... }) за конвенцією #163.

& {
    $osMatrixPolicyText = [IO.File]::ReadAllText(
        (Join-Path $root 'RELEASE_POLICY.md'), [Text.Encoding]::UTF8)
    $osMatrixSecurityText = [IO.File]::ReadAllText(
        (Join-Path $root 'SECURITY.md'), [Text.Encoding]::UTF8)
    $osMatrixCompatibilityText = [IO.File]::ReadAllText(
        (Join-Path $root 'modules\BRAVO.Compatibility\BRAVO.Compatibility.psm1'), [Text.Encoding]::UTF8)

    $osMatrixHeading = '### 9.4. RC-матриця приймання по ОС'
    $osMatrixStart = $osMatrixPolicyText.IndexOf($osMatrixHeading)
    $osMatrixSection = ''
    if ($osMatrixStart -ge 0) {
        $osMatrixEnd = $osMatrixPolicyText.IndexOf('## 10. Promotion', $osMatrixStart)
        $osMatrixSection = if ($osMatrixEnd -gt $osMatrixStart) {
            $osMatrixPolicyText.Substring($osMatrixStart, $osMatrixEnd - $osMatrixStart)
        } else {
            $osMatrixPolicyText.Substring($osMatrixStart)
        }
    }

    Test-BRAVOCondition `
        -Condition ($osMatrixStart -ge 0 -and $osMatrixSection.Length -gt 0) `
        -Name "Governance/ReleasePolicyHasOsAcceptanceMatrix" `
        -Failure "RELEASE_POLICY.md мусить містити розділ «$osMatrixHeading» — інакше промоція stable не має контракту приймання на реальних хостах"

    # Матриця, на яку ніхто не посилається, — мертвий текст. Критерії
    # готовності RC (§9.3) мусять її вимагати.
    $osMatrixReadinessIndex = $osMatrixPolicyText.IndexOf("### 9.3. Критерії готовності")
    $osMatrixReadinessSection = if ($osMatrixReadinessIndex -ge 0 -and $osMatrixStart -gt $osMatrixReadinessIndex) {
        $osMatrixPolicyText.Substring($osMatrixReadinessIndex, $osMatrixStart - $osMatrixReadinessIndex)
    } else { '' }
    Test-BRAVOCondition `
        -Condition ($osMatrixReadinessSection.Contains('§9.4')) `
        -Name "Governance/OsAcceptanceMatrixIsWiredIntoRcReadiness" `
        -Failure "критерії готовності RC (RELEASE_POLICY.md §9.3) мусять вимагати докази по матриці §9.4 — інакше матриця лишається текстом, який нічого не блокує"

    # Обидві обов'язкові цілі мусять бути названі. Клієнтська Windows тут не
    # косметика: саме на ній немає diskshadow.exe, і саме там знайдено
    # перший дефект PR #148.
    $osMatrixRequiredTargets = @('Windows Server 2022', 'Windows 11')
    $osMatrixMissingTargets = @(
        $osMatrixRequiredTargets | Where-Object { -not $osMatrixSection.Contains($_) })
    Test-BRAVOCondition `
        -Condition (@($osMatrixMissingTargets).Count -eq 0) `
        -Name "Governance/OsAcceptanceMatrixNamesMandatoryTargets" `
        -Failure ("матриця §9.4 мусить називати обов'язкові цілі приймання; бракує: " +
            [string]::Join(', ', @($osMatrixMissingTargets)))

    # Класифікація ОС належить modules\BRAVO.Compatibility і SECURITY.md.
    # Матриця мусить користуватись ТИМИ САМИМИ рівнями, а не власними.
    $osMatrixTierNames = @('Supported', 'LegacyBestEffort')
    $osMatrixUnknownTiers = @(
        $osMatrixTierNames | Where-Object { -not $osMatrixCompatibilityText.Contains($_) })
    Test-BRAVOCondition `
        -Condition (
            @($osMatrixUnknownTiers).Count -eq 0 -and
            $osMatrixSection.Contains('BRAVO.Compatibility') -and
            $osMatrixSection.Contains('Supported') -and
            $osMatrixSection.Contains('LegacyBestEffort')
        ) `
        -Name "Governance/OsAcceptanceMatrixReusesCompatibilityTiers" `
        -Failure ("матриця §9.4 мусить посилатися на рівні modules\BRAVO.Compatibility, а не вводити " +
            "паралельну класифікацію; невідомі модулю рівні: " +
            [string]::Join(', ', @($osMatrixUnknownTiers)))

    # Реальна суперечність, яку варто ловити механічно: ціль приймання з
    # рівня Unsupported. Production-запуск на ній блокується кодом 30, тобто
    # «приймання» там неможливе за побудовою.
    $osMatrixUnsupportedRowIndex = $osMatrixSecurityText.IndexOf('**Unsupported**')
    $osMatrixUnsupportedRow = if ($osMatrixUnsupportedRowIndex -ge 0) {
        $osMatrixSecurityText.Substring($osMatrixUnsupportedRowIndex).Split([char]10)[0]
    } else { '' }
    $osMatrixUnsupportedNames = @(
        @('Windows 7', 'Windows Server 2008 R2') |
            Where-Object { $osMatrixUnsupportedRow.Contains($_) })
    $osMatrixForbiddenTargets = @(
        $osMatrixUnsupportedNames | Where-Object { $osMatrixSection.Contains($_) })
    Test-BRAVOCondition `
        -Condition (
            $osMatrixUnsupportedRowIndex -ge 0 -and
            @($osMatrixUnsupportedNames).Count -gt 0 -and
            @($osMatrixForbiddenTargets).Count -eq 0
        ) `
        -Name "Governance/OsAcceptanceMatrixExcludesUnsupportedSystems" `
        -Failure ("матриця §9.4 не може містити ціль приймання з рівня Unsupported (SECURITY.md): " +
            "production-запуск там блокується кодом 30. Знайдено: " +
            [string]::Join(', ', @($osMatrixForbiddenTargets)))

    # Недоступність self-test на жорсткому хості мусить бути описана саме як
    # класифікований стан, інакше оператор читає [FAIL] як дефект комплекту.
    Test-BRAVOCondition `
        -Condition (
            $osMatrixSection.Contains('Constrained Language Mode') -and
            $osMatrixSection.Contains('НЕДОСТУПНИЙ')
        ) `
        -Name "Governance/OsAcceptanceMatrixClassifiesUnavailableSelfTest" `
        -Failure "матриця §9.4 мусить окремо класифікувати недоступність self-test на жорстко налаштованому хості — інакше провал приймання й обмеження хоста виглядають однаково"
}

& {
    # Configuration v2 Pilot Preparation (незалежний аудит, 2026-09-16):
    # -ValidateOnly мусить лишатись цілком read-only — це передумова
    # безпечного pilot-переносу на реальному сервері (оператор запускає
    # -ValidateOnly ПЕРЕД будь-якою реальною зміною, і має право
    # покладатись на те, що сам прогін нічого не змінив). Статична
    # текстова перевірка, а не функціональний прогін: BRAVO_SETUP.ps1
    # вимагає адміністративних прав/scheduler/Credential Manager для
    # повного шляху, які self-test-середовище відтворити не зобов'язане;
    # ті самі self-test-файли вже покладаються на текстові guard-перевірки
    # для аналогічних інваріантів (див. Delta/SiteDeltaToolNeverOverwrites
    # у BRAVO_SELF_TEST.Configuration.ps1).
    $setupScriptText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_SETUP.ps1'), [Text.Encoding]::UTF8)

    # Регресія на реальний P1-дефект (той самий аудит): Save-
    # BRAVODiscoveryBaseline викликався БЕЗ перевірки -ValidateOnly, тобто
    # "BRAVO_SETUP.ps1 -ValidateOnly -ConfirmDiscoveryBaseline" persisted
    # discovery-baseline файл попри ValidateOnly. Єдиний знайдений виняток
    # із контракту "жодних записів під ValidateOnly" в усьому скрипті.
    Test-BRAVOCondition `
        -Condition (
            $setupScriptText -match '(?s)if\s*\(\s*\$ConfirmDiscoveryBaseline\s+-and\s+-not\s+\$ValidateOnly\s*\)\s*\{\s*\r?\n\s*Save-BRAVODiscoveryBaseline'
        ) `
        -Name "Governance/ValidateOnlyNeverPersistsDiscoveryBaseline" `
        -Failure "Save-BRAVODiscoveryBaseline у BRAVO_SETUP.ps1 мусить викликатись лише коли (-ConfirmDiscoveryBaseline -and -not -ValidateOnly) — інакше -ValidateOnly не є read-only"

    # Негативний контроль: переконуємось, що правило вище дійсно ловить
    # регресію, а не завжди повертає true через слабкий патерн — старий
    # (дефектний) вигляд рядка не повинен випадково теж матчитись.
    $setupScriptRegressionShape = $setupScriptText -replace `
        '(?s)if\s*\(\s*\$ConfirmDiscoveryBaseline\s+-and\s+-not\s+\$ValidateOnly\s*\)', `
        'if ($ConfirmDiscoveryBaseline)'
    Test-BRAVOCondition `
        -Condition (
            $setupScriptRegressionShape -notmatch '(?s)if\s*\(\s*\$ConfirmDiscoveryBaseline\s+-and\s+-not\s+\$ValidateOnly\s*\)\s*\{\s*\r?\n\s*Save-BRAVODiscoveryBaseline'
        ) `
        -Name "Governance/ValidateOnlyDiscoveryBaselineGuardPatternIsMeaningful" `
        -Failure "перевірка вище не відрізняє захищений виклик від незахищеного (patern занадто слабкий) — тест-негативний контроль провалився"

    # Регресія на ГЛИБШИЙ P1-дефект того самого класу (незалежний Codex
    # review PR #207, знайдений ПІСЛЯ фіксу вище): Import-
    # BRAVODiscoveryBaseline сам може мігрувати legacy-baseline файл у
    # canonical розташування (запис у $StateRoot) незалежно від
    # -ConfirmDiscoveryBaseline — на самому лише виклику під час читання.
    # Перевірка вище (Save-BRAVODiscoveryBaseline guard) цей шлях не
    # покриває: Codex явно вказав, що "the new regex test also misses
    # this path". -ReadOnly:$ValidateOnly у виклику нижче — фікс.
    Test-BRAVOCondition `
        -Condition (
            $setupScriptText -match '(?s)Import-BRAVODiscoveryBaseline\s*`\s*\r?\n\s*-StateRoot\s+\$global:stateRoot\s*`\s*\r?\n\s*-RuntimeRoot\s+\$PSScriptRoot\s*`\s*\r?\n\s*-ReadOnly:\$ValidateOnly'
        ) `
        -Name "Governance/ValidateOnlyNeverPersistsMigratedDiscoveryBaseline" `
        -Failure "виклик Import-BRAVODiscoveryBaseline у BRAVO_SETUP.ps1 мусить передавати -ReadOnly:`$ValidateOnly — інакше legacy->canonical міграція baseline записує стан машини навіть під -ValidateOnly"

    # Негативний контроль для перевірки вище.
    $setupScriptImportRegressionShape = $setupScriptText -replace `
        '-ReadOnly:\$ValidateOnly', `
        ''
    Test-BRAVOCondition `
        -Condition (
            $setupScriptImportRegressionShape -notmatch '(?s)Import-BRAVODiscoveryBaseline\s*`\s*\r?\n\s*-StateRoot\s+\$global:stateRoot\s*`\s*\r?\n\s*-RuntimeRoot\s+\$PSScriptRoot\s*`\s*\r?\n\s*-ReadOnly:\$ValidateOnly'
        ) `
        -Name "Governance/ValidateOnlyMigratedDiscoveryBaselineGuardPatternIsMeaningful" `
        -Failure "перевірка вище не відрізняє захищений виклик Import-BRAVODiscoveryBaseline від незахищеного (patern занадто слабкий) — тест-негативний контроль провалився"
}

# =====================================================================
# A5: канонічний guard binder-гейту @($List[object]) по всьому репозиторію
# =====================================================================
# `@($x)`, де $x тримає System.Collections.Generic.List[object],
# створений через New-Object, кидає ArgumentException "Argument types do
# not match" (PSToObjectArrayBinder) і в Windows PowerShell 5.1, і в
# PowerShell 7 — незалежно від вмісту списку, включно з порожнім.
# Тригер — PSObject-обгортка, яку дає вивід cmdlet-а New-Object; вона
# переживає присвоєння, аліас, return ,$list і передачу в параметр без
# типу або типу [object]. Параметр [object[]] чи [List[object]] обгортку
# знімає, .ToArray() і [object[]]-каст безпечні.
#
# Раніше цей клас тримався точковими виправленнями й коментарями
# ($probeGroupList, $generationResults, $emptyDirs, $model,
# $pendingByKey, Timings) і точковим guard-ом
# Archive/StepHistoryPayloadUsesToArrayNotArraySubexpression. PR #225
# знайшов ще три входження (stages в Archive і Health), яких точкові
# guard-и не бачили. Тут — одна перевірка по AST усіх PowerShell-файлів
# репозиторію (той самий перелік, що аналізує CI: Get-BRAVOAnalyzableFile).
#
# Ім'я змінної нормалізується через VariablePath.UserPath зі зрізанням
# префікса scope ($script:X і X — одна змінна), а не через DriveName:
# для $script:X DriveName порожній, і саме на цьому спроба загального
# guard-а в PR #225 дала 2192 хибні спрацювання. PSObject-обгортка
# переживає й зберігання списку у властивості чи елементі словника:
# @($group.Owners) і @($byKey[$k]) кидають так само. Властивість
# зіставляється за іменем лише в межах того самого файлу (між
# непов'язаними файлами збіг за іменем члена дає хибні спрацювання),
# елемент словника — за іменем змінної-словника з тим самим scope-правилом,
# що й для звичайної змінної.
#
# Після двох раундів review PR #259 детектор — не набір точкових
# патернів, а одна потокова модель: джерело -> scope -> присвоєння ->
# аліас -> властивість/елемент -> read-back -> прив'язка параметра ->
# пересилання -> аргумент виклику -> вихід функції, ітерована до нерухомої
# точки, і sink @(). Опис місць і правил — у коментарі функції нижче;
# рантайм-передумови моделі перевіряє GenericObjectListBinderPremisesHold.
& {
    function Find-BRAVOObjectListArraySubexpression {
        <#
            Повертає рядки "<Name>:<рядок>: <вираз> (<причина>; джерело
            <Name>:<рядок>)" для кожного @(<вираз>), де вираз тримає
            PSObject-обгорнутий List[object] з New-Object.
            -Source: об'єкти з властивостями Name і Text.

            Модель — одна потокова (dataflow) задача з нерухомою точкою:
            джерело -> правила переносу -> sink. Абстрактні місця:
              змінна       '<scope>|<ім'я>' у Sources свого файлу, де scope —
                           зсув визначення функції або '<script>'
                           ($global: — ще й спільна таблиця всіх файлів);
              параметр     те саме місце, що локальна змінна функції;
              ключ         рядковий ключ і властивість — одне місце: ім'я
                           в межах файлу (Members), $d['K'] і $d.K однакові;
              елемент      довільний індекс: '<scope>|[]<ім'я словника>',
                           для словника-властивості — Members '[]<член>';
              вихід        визначення функції: файл + зсув (FunctionOutputs) —
                           список серед емітованих об'єктів;
              значення     $( ... ) чи if/try/switch/цикл як права частина
                           присвоєння (NodeValues, ключ — сам вузол).
            Окремо від самого списку (вид L) модель знає вид W — масив з
            одним елементом-списком ($w = ,$list): @($w) безпечний, але
            емітований $w розгортається рівно в список.
            Значення виразу обчислює одна функція $getTaint: змінна (з
            динамічним scope, затіненням параметром і локальним
            присвоєнням), властивість і елемент (read-back), каст
            [object]/[psobject] (не знімає обгортку), виклик New-Object
            (тип — лише аргумент, прив'язаний до -TypeName, зокрема
            Microsoft.PowerShell.Utility\New-Object), виклик функції, чий
            вихід несе список, і значення $( ... )/оператора. Правила
            переносу (всі — "значення -> місце"): присвоєння (ліва частина з
            типом [object]/[psobject] розгортається, інший тип конвертує й
            обгортку знімає), ключ hashtable-літерала, значення параметра за
            замовчуванням, прив'язка аргументу виклику до параметра (іменна
            з префіксом і AliasAttribute, позиційна за рангом; аргумент —
            будь-який вираз, зокрема (New-Object ...) чи (Get-X)), і
            емісія: конвеєр, що реально потрапляє у вихід контейнера (тіла
            функції, $( ... ) чи присвоєного if/try/switch/циклу, а не в
            присвоєння, аргумент чи умову), передає далі виклик-команду без
            розгортання, а вираз — розгорнутим на один рівень (,$x, (,$x) і
            W-змінна дають список, голий $list — ні). Правила ітеруються,
            доки жодне місце не стає новим; тому ланцюги функцій,
            параметри-пересилання і read-back після зберігання сходяться
            без окремих проходів. [List[object]]::new() джерелом не є: без
            cmdlet-а обгортки немає, @() такий список не ламає.

            Прив'язка до параметрів іде і з конвеєра: попередній елемент
            (команда — цілим виходом, вираз — розгорнутим на один рівень) у
            параметр з ValueFromPipeline, і зі splatting @p: ключ, що за
            іменем, аліасом чи префіксом збігається з параметром, — місце
            ключа в Members (@{ K = ... }, $p['K'] = ..., $p.K = ...).
            Виклик резолвиться до визначень із власного файлу, а якщо там
            такої функції немає — до всіх однойменних (dot-source); вихід
            функції — місце самого визначення (файл + зсув). Статичні
            Set-Alias/New-Alias з рядковими -Name/-Value резолвляться до
            функції. $script:x і $global:x — різні місця; некваліфіковане
            читання бачить обидва. Ланцюгове $a = $b = <x> передає <x> далі
            (крім типізованої внутрішньої лівої частини); Write-Output
            -NoEnumerate <список> — емісія цілим, без -NoEnumerate — як
            емітований вираз; $w[...] з W-обгортки — сам список. Локальне
            присвоєння затіняє зовнішню змінну лише коли домінує над
            читанням (оператор блоку, що охоплює читання й завершився до
            нього); присвоєння в гілці чи циклі поруч — ні.

            Порядок виконання: читання $x у тому самому scope, доведено
            раніше за кожне присвоєння, що може забруднити його місце
            (жодне з них не в іншому блоці, не до читання, а над блоком до
            меж scope немає циклу, switch, trap чи скриптблок-виразу; $x не
            параметр), бачить значення до цих присвоєнь — домінуюче раніше
            присвоєння чи зовнішній scope. Що не доведено — позначається.
            Кардинальність: функція, чий end-блок до будь-якого можливого
            раннього виходу має два оператори, кожен з яких безумовно емітує
            рівно один об'єкт (рядок, число, hashtable-літерал, ,<x>; без
            перенаправлення), віддає масив: зібраний вихід ($v = Get-X,
            (Get-X)) — вид W, а не сам список; у конвеєр і в емісію далі
            (Get-X у тілі іншої функції) список іде окремим об'єктом, як і
            раніше. Гілки не рахуються: рання return в if лишає вихід
            позначеним.

            Чого модель свідомо НЕ моделює (оголошена межа guard-а):
              - порядок виконання поза доведеним випадком вище (читання
                після присвоєння в іншій гілці, у циклі, у вкладеній функції
                щодо зовнішньої змінної) — консервативно позначається;
                dot-source виклик (. Get-X), що присвоює змінні scope
                викликача, не моделюється;
              - splatting хештаблиці невідомого походження (ключі не зі
                статичних місць) і масиву (@args), $PSBoundParameters;
              - ValueFromPipelineByPropertyName і конвеєр через невідомі
                команди (Where-Object, ForEach-Object ...);
              - кількість виходів поза безумовними емісіями верхнього рівня
                (гілки, цикли, виклики інших команд) — вихід позначається як
                список (консервативно); значення, зібране з кількох виходів
                у параметр ((Get-X) як аргумент) чи в ланцюг $a = $b = Get-X,
                виду W не отримує;
              - список без New-Object, який обгортає інший cmdlet
                (Write-Output -NoEnumerate [List[object]]::new() тощо):
                джерелом є лише New-Object;
              - $using:, Set-Variable/Get-Variable, -OutVariable, члени
                класів, Invoke-Command, & $scriptblock, динамічні імена
                команд і аліаси з нерядковими аргументами.
        #>
        param([Parameter(Mandatory = $true)][object[]]$Source)

        # Продуктивність: guard розбирає весь репозиторій, тож помічники-
        # скриптблоки нижче викликаються через .InvokeReturnAsIs(...), а не
        # & $помічник: прив'язка через & у рази дорожча (у PS 5.1 guard
        # інакше займав хвилини). Змінні детектора помічники читають за
        # динамічним scope, як і з &.

        $listTypePattern = '^(System\.)?(Collections\.)?(Generic\.)?List\[(System\.)?Object\]$'
        # Тип, що не знімає PSObject-обгортку (параметр, ліва частина
        # присвоєння, каст): без типу, [object] або [psobject] у будь-якому
        # написанні простору імен, зокрема [System.Management.Automation.PSObject].
        $unsafeTypePattern = '^$|^(System\.)?Object$|^((System\.)?Management\.Automation\.|System\.)?PSObject$'
        # Параметри з автоматичного набору, що не беруть значення.
        $commonSwitchNames = @('verbose', 'debug', 'whatif', 'confirm')

        $getNormalizedName = {
            param([string]$UserPath)
            ($UserPath -replace '^(script|global|local|private|using):', '').ToLowerInvariant()
        }
        # 'script', 'global' або '' (некваліфіковане ім'я).
        $getScopeQualifier = {
            param($VariableNode)
            if ($VariableNode.VariablePath.UserPath -match '^(script|global):') { return $Matches[1].ToLowerInvariant() }
            return ''
        }
        $getScopeNode = {
            param($Node)
            $parentNode = $Node.Parent
            while ($null -ne $parentNode) {
                if ($parentNode -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $parentNode }
                $parentNode = $parentNode.Parent
            }
            return $null
        }
        $getScopeId = {
            param($Node)
            $scopeNode = $getScopeNode.InvokeReturnAsIs($Node)
            if ($null -eq $scopeNode) { return '<script>' }
            return [string]$scopeNode.Extent.StartOffset
        }
        $getFunctionParameters = {
            param($FunctionNode)
            $declaredParameters = @()
            if ($null -ne $FunctionNode.Body.ParamBlock) { $declaredParameters += @($FunctionNode.Body.ParamBlock.Parameters) }
            if ($null -ne $FunctionNode.Parameters) { $declaredParameters += @($FunctionNode.Parameters) }
            return ,$declaredParameters
        }
        $getParameterTypeName = {
            param($ParameterNode)
            foreach ($attribute in $ParameterNode.Attributes) {
                if ($attribute -is [System.Management.Automation.Language.TypeConstraintAst]) { return $attribute.TypeName.FullName }
            }
            return ''
        }
        # Ранги параметрів серед позиційних, у порядку $Parameters (0 —
        # перший позиційний аргумент), -1 — параметр не позиційний, -2 —
        # позицію статично не визначити (ParameterSetName, неконстантні
        # Position/PositionalBinding): тоді позиційний аргумент
        # зіставляється з параметром консервативно. PowerShell віддає
        # позиційні аргументи параметрам у порядку значень Position (це
        # порядок, а не абсолютний індекс); якщо Position не задано ніде —
        # у порядку оголошення без [switch].
        $getParameterRanks = {
            param($FunctionNode, $Parameters)
            $ranks = New-Object 'int[]' $Parameters.Count
            $unknownRanks = New-Object 'int[]' $Parameters.Count
            for ($index = 0; $index -lt $Parameters.Count; $index++) { $ranks[$index] = -1; $unknownRanks[$index] = -2 }
            $positionalBinding = $true
            if ($null -ne $FunctionNode.Body.ParamBlock) {
                foreach ($blockAttribute in $FunctionNode.Body.ParamBlock.Attributes) {
                    if ($blockAttribute.TypeName.Name -notmatch '^((System\.)?Management\.Automation\.)?CmdletBinding(Attribute)?$') { continue }
                    foreach ($namedArgument in $blockAttribute.NamedArguments) {
                        if ($namedArgument.ArgumentName -ne 'PositionalBinding') { continue }
                        if ($namedArgument.Argument -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return ,$unknownRanks }
                        $bindingValue = $namedArgument.Argument.VariablePath.UserPath
                        if ($bindingValue -eq 'false') { $positionalBinding = $false } elseif ($bindingValue -ne 'true') { return ,$unknownRanks }
                    }
                }
            }
            $explicitPositions = @{}
            for ($index = 0; $index -lt $Parameters.Count; $index++) {
                foreach ($attribute in $Parameters[$index].Attributes) {
                    if ($attribute -isnot [System.Management.Automation.Language.AttributeAst] -or
                        $attribute.TypeName.Name -notmatch '^((System\.)?Management\.Automation\.)?Parameter(Attribute)?$') { continue }
                    foreach ($namedArgument in $attribute.NamedArguments) {
                        if ($namedArgument.ArgumentName -eq 'ParameterSetName') { return ,$unknownRanks }
                        if ($namedArgument.ArgumentName -ne 'Position') { continue }
                        if ($namedArgument.Argument -isnot [System.Management.Automation.Language.ConstantExpressionAst]) { return ,$unknownRanks }
                        $explicitPositions[$index] = [int]$namedArgument.Argument.Value
                    }
                }
            }
            if ($explicitPositions.Count -gt 0) {
                # Сортування за (Position, порядок оголошення).
                $ordered = @($explicitPositions.Keys | Sort-Object { $explicitPositions[$_] }, { $_ })
                for ($rank = 0; $rank -lt $ordered.Count; $rank++) { $ranks[$ordered[$rank]] = $rank }
            } elseif ($positionalBinding) {
                $rank = 0
                for ($index = 0; $index -lt $Parameters.Count; $index++) {
                    if (($getParameterTypeName.InvokeReturnAsIs($Parameters[$index])) -match '^((System\.)?Management\.Automation\.)?Switch(Parameter)?$') { continue }
                    $ranks[$index] = $rank
                    $rank++
                }
            }
            return ,$ranks
        }
        $unwrapExpression = {
            param($Node)
            $current = $Node
            while ($true) {
                if ($current -is [System.Management.Automation.Language.PipelineAst] -and
                    $current.PipelineElements.Count -eq 1 -and
                    $current.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $current = $current.PipelineElements[0].Expression
                    continue
                }
                if ($current -is [System.Management.Automation.Language.CommandExpressionAst]) { $current = $current.Expression; continue }
                if ($current -is [System.Management.Automation.Language.ParenExpressionAst]) { $current = $current.Pipeline; continue }
                # Ланцюгове присвоєння $a = $b = <x>: значення — те саме <x>,
                # якщо внутрішня ліва частина не конвертує його типом
                # ([object[]]$b = <x> дає масив).
                if ($current -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                    $chainedLeft = $current.Left
                    while ($chainedLeft -is [System.Management.Automation.Language.AttributedExpressionAst]) {
                        if ($chainedLeft -is [System.Management.Automation.Language.ConvertExpressionAst] -and
                            $chainedLeft.Type.TypeName.FullName -notmatch $unsafeTypePattern) { return $current }
                        $chainedLeft = $chainedLeft.Child
                    }
                    $current = $current.Right
                    continue
                }
                return $current
            }
        }
        # Ім'я команди для порівняння з вбудованими cmdlet-ами: модульна
        # кваліфікація Microsoft.PowerShell.Utility\ знімається (той самий
        # cmdlet), будь-яка інша лишається. Для функцій репозиторію
        # кваліфікація знімається повністю.
        $getBuiltinName = {
            param($CommandNode)
            $commandName = $CommandNode.GetCommandName()
            if (-not $commandName) { return '' }
            return ($commandName.ToLowerInvariant() -replace '^microsoft\.powershell\.utility\\', '')
        }
        # Ключ функції для виклику: кваліфікація знімається, статичний
        # аліас (Set-Alias/New-Alias) резолвиться до функції.
        $getFunctionKey = {
            param($CommandNode)
            $commandName = $CommandNode.GetCommandName()
            if (-not $commandName) { return '' }
            $functionKey = $commandName.ToLowerInvariant() -replace '^.*\\', ''
            $aliasHops = 0
            while (-not $definitions.ContainsKey($functionKey) -and $commandAliases.ContainsKey($functionKey) -and $aliasHops -lt 8) {
                $functionKey = $commandAliases[$functionKey]
                $aliasHops++
            }
            return $functionKey
        }
        # Визначення, до яких резолвиться виклик: однойменні з того самого
        # файлу, а якщо там їх немає — усі однойменні (dot-source).
        $resolveDefinitions = {
            param($Unit, [string]$FunctionKey)
            $localKey = $Unit.Name + '|' + $FunctionKey
            if ($localDefinitions.ContainsKey($localKey)) { return ,$localDefinitions[$localKey] }
            if ($definitions.ContainsKey($FunctionKey)) { return ,$definitions[$FunctionKey] }
            return ,@()
        }
        # Статичний Set-Alias/New-Alias: рядкові -Name і -Value (іменні або
        # позиційні 0/1) -> @(ім'я, ціль), інакше $null.
        $getAliasDeclaration = {
            param($CommandNode)
            $elements = $CommandNode.CommandElements
            $aliasName = $null
            $aliasValue = $null
            $positionalValues = @()
            for ($elementIndex = 1; $elementIndex -lt $elements.Count; $elementIndex++) {
                $element = $elements[$elementIndex]
                if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                    $parameterName = $element.ParameterName.ToLowerInvariant()
                    $isSwitch = ($parameterName.Length -gt 0 -and ('passthru'.StartsWith($parameterName) -or 'force'.StartsWith($parameterName) -or
                            'whatif'.StartsWith($parameterName) -or 'confirm'.StartsWith($parameterName) -or 'verbose'.StartsWith($parameterName) -or 'debug'.StartsWith($parameterName)))
                    $value = $element.Argument
                    if ($null -eq $value -and -not $isSwitch -and $elementIndex + 1 -lt $elements.Count -and
                        $elements[$elementIndex + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                        $elementIndex++
                        $value = $elements[$elementIndex]
                    }
                    if ($parameterName.Length -gt 0 -and 'name'.StartsWith($parameterName)) { $aliasName = $value }
                    elseif ($parameterName.Length -gt 1 -and 'value'.StartsWith($parameterName)) { $aliasValue = $value }
                } else {
                    $positionalValues += $element
                }
            }
            $positionalIndex = 0
            if ($null -eq $aliasName -and $positionalIndex -lt $positionalValues.Count) { $aliasName = $positionalValues[$positionalIndex]; $positionalIndex++ }
            if ($null -eq $aliasValue -and $positionalIndex -lt $positionalValues.Count) { $aliasValue = $positionalValues[$positionalIndex] }
            if ($aliasName -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $aliasValue -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
            return ,@($aliasName.Value.ToLowerInvariant(), ($aliasValue.Value.ToLowerInvariant() -replace '^.*\\', ''))
        }
        # Значення, прив'язане до -TypeName у New-Object: іменний -TypeName
        # (будь-який однозначний префікс, -TypeName:<x>) має перевагу над
        # позиційним; інакше перший позиційний аргумент. Значення інших
        # параметрів (-ArgumentList, -Property, -ComObject) типом не є.
        $getNewObjectTypeName = {
            param($CommandNode)
            $elements = $CommandNode.CommandElements
            $firstPositional = $null
            for ($elementIndex = 1; $elementIndex -lt $elements.Count; $elementIndex++) {
                $element = $elements[$elementIndex]
                if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                    $parameterName = $element.ParameterName.ToLowerInvariant()
                    $isSwitch = ($parameterName.Length -gt 0 -and ('strict'.StartsWith($parameterName) -or 'verbose'.StartsWith($parameterName) -or 'debug'.StartsWith($parameterName)))
                    $value = $element.Argument
                    if ($null -eq $value -and -not $isSwitch -and $elementIndex + 1 -lt $elements.Count -and
                        $elements[$elementIndex + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                        $elementIndex++
                        $value = $elements[$elementIndex]
                    }
                    if ($parameterName.Length -gt 0 -and 'typename'.StartsWith($parameterName)) {
                        if ($value -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $value.Value }
                        return ''
                    }
                } elseif ($null -eq $firstPositional) {
                    $firstPositional = $element
                }
            }
            if ($firstPositional -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $firstPositional.Value }
            return ''
        }

        $units = New-Object System.Collections.Generic.List[object]
        $globalSources = @{}
        $functionOutputs = @{}
        $definitions = @{}
        $localDefinitions = @{}
        # Імена змінних, яким десь присвоєно ,<x> (кандидати виду W).
        $wrapperCandidates = @{}
        # Імена функцій, end-блок яких має >= 2 оператори верхнього рівня
        # виду $isDefiniteEmission без перевірки виходів і перенаправлень
        # (надмножина Multi; дешевий відсів правил виду W для $v = Get-X).
        $multiCandidates = @{}
        $commandAliases = @{}
        # Імена, що хоч десь стали джерелом: швидкий відсів читань змінних.
        $taintedNames = @{}

        # Порядок виконання (sound kill): читання $x у scope S бачить власне
        # місце S лише після присвоєння. Місце пропускається, коли доведено
        # все: $x не параметр S; кожне присвоєння, що пише це місце, — оператор
        # того самого блоку, що й оператор читання, і починається після його
        # кінця; між блоком і S немає циклу, switch, trap чи скриптблок-виразу
        # (там оператор читання може виконатися вдруге, вже після запису).
        # Будь-що недоведене — місце лишається (fail-closed). Записи через
        # параметр і $script:x з функції цій умові не відповідають за
        # побудовою.
        $isReadBeforeWriters = {
            param($Unit, $Node, [string]$ScopeKey, $ScopeNode)
            $cacheKey = [string]$Node.Extent.StartOffset + '|' + $ScopeKey
            if ($Unit.ReadOrder.ContainsKey($cacheKey)) { return $Unit.ReadOrder[$cacheKey] }
            $provenBefore = $false
            $writerStatements = $Unit.Writers[$ScopeKey]
            $variableName = ($ScopeKey.Substring($ScopeKey.IndexOf('|') + 1)) -replace '^(#|\[\])', ''
            $parameterNames = if ($null -eq $ScopeNode) { $Unit.ScriptParameters } else { $Unit.ParameterNames[[string]$ScopeNode.Extent.StartOffset] }
            if ($null -ne $writerStatements -and -not ($null -ne $parameterNames -and $parameterNames.ContainsKey($variableName))) {
                $readStatement = $Node
                while ($null -ne $readStatement.Parent -and
                    $readStatement.Parent -isnot [System.Management.Automation.Language.StatementBlockAst] -and
                    $readStatement.Parent -isnot [System.Management.Automation.Language.NamedBlockAst]) { $readStatement = $readStatement.Parent }
                $readBlock = $readStatement.Parent
                if ($null -ne $readBlock) {
                    $provenBefore = $true
                    $ancestor = $readBlock.Parent
                    while ($null -ne $ancestor -and -not [object]::ReferenceEquals($ancestor, $ScopeNode)) {
                        if ($ancestor -is [System.Management.Automation.Language.LoopStatementAst] -or
                            $ancestor -is [System.Management.Automation.Language.SwitchStatementAst] -or
                            $ancestor -is [System.Management.Automation.Language.TrapStatementAst] -or
                            $ancestor -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
                            $ancestor -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $provenBefore = $false; break }
                        $ancestor = $ancestor.Parent
                    }
                    if ($provenBefore) {
                        foreach ($writerStatement in $writerStatements) {
                            if (-not [object]::ReferenceEquals($writerStatement.Parent, $readBlock) -or
                                $writerStatement.Extent.StartOffset -lt $readStatement.Extent.EndOffset) { $provenBefore = $false; break }
                        }
                    }
                }
            }
            $Unit.ReadOrder[$cacheKey] = $provenBefore
            return $provenBefore
        }
        # Оператор, що на будь-якому шляху емітує рівно один об'єкт:
        # конвеєр-вираз без перенаправлення з рядка, числа, hashtable-
        # літерала чи ,<x> (один елемент, навіть $null).
        $isDefiniteEmission = {
            param($Node)
            if ($Node -isnot [System.Management.Automation.Language.PipelineAst] -or $Node.PipelineElements.Count -ne 1) { return $false }
            $element = $Node.PipelineElements[0]
            if ($element -isnot [System.Management.Automation.Language.CommandExpressionAst] -or $element.Redirections.Count -gt 0) { return $false }
            $emitted = $element.Expression
            return ($emitted -is [System.Management.Automation.Language.ConstantExpressionAst] -or
                $emitted -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
                $emitted -is [System.Management.Automation.Language.HashtableAst] -or
                ($emitted -is [System.Management.Automation.Language.ArrayLiteralAst] -and $emitted.Elements.Count -eq 1))
        }
        # Кардинальність виходу: функція, чий end-блок до будь-якого
        # можливого раннього виходу (return/exit/break/continue усередині
        # оператора) містить щонайменше два оператори $isDefiniteEmission,
        # на кожному шляху віддає >= 2 об'єкти — зібраний вихід є масивом.
        # Інші блоки й гілки лише додають об'єкти. Гілки не рахуються.
        $isMultiOutput = {
            param($FunctionNode)
            if ($FunctionNode.IsFilter -or $null -eq $FunctionNode.Body.EndBlock) { return $false }
            $emissionCount = 0
            foreach ($statement in $FunctionNode.Body.EndBlock.Statements) {
                $isReturn = $statement -is [System.Management.Automation.Language.ReturnStatementAst]
                $emittedNode = if ($isReturn) { $statement.Pipeline } else { $statement }
                if ($isDefiniteEmission.InvokeReturnAsIs($emittedNode)) {
                    $emissionCount++
                    if ($emissionCount -ge 2) { return $true }
                }
                if ($isReturn -or $null -ne $statement.Find({
                            $args[0] -is [System.Management.Automation.Language.ReturnStatementAst] -or
                            $args[0] -is [System.Management.Automation.Language.ExitStatementAst] -or
                            $args[0] -is [System.Management.Automation.Language.BreakStatementAst] -or
                            $args[0] -is [System.Management.Automation.Language.ContinueStatementAst]
                        }, $true)) { return $false }
            }
            return $false
        }
        # Змінна в місці читання: ланцюг охоплюючих функцій від найближчої
        # (T010: вкладені функції обгортки Invoke-BRAVO<X> читають її
        # змінні за динамічним scope), далі '<script>' файлу і спільна
        # таблиця $global:. Параметр функції — її локальна змінна: його
        # місце перевіряється першим, а незабруднений параметр затіняє
        # зовнішню змінну. Так само затіняє локальне присвоєння без
        # префікса scope, що завершилось до місця читання. Читання з
        # префіксом $script:/$global: функції пропускає й бачить лише своє
        # місце: $script:x — '<script>' файлу, $global:x — спільну таблицю.
        # Власне місце найближчого scope пропускається, якщо читання
        # доведено передує кожному присвоєнню, що може його забруднити
        # ($isReadBeforeWriters): тоді читається те, що було до них, —
        # домінуюче раніше присвоєння або зовнішній scope.
        $resolveVariable = {
            param($Unit, $Node, [string]$NormalizedName, [string]$Qualifier)
            $innermostScope = $true
            if ($Qualifier -eq '') {
                $parentNode = $Node.Parent
                while ($null -ne $parentNode) {
                    if ($parentNode -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                        $scopeKey = [string]$parentNode.Extent.StartOffset + '|' + $NormalizedName
                        if ($Unit.Sources.ContainsKey($scopeKey) -and
                            -not ($innermostScope -and ($isReadBeforeWriters.InvokeReturnAsIs($Unit, $Node, $scopeKey, $parentNode)))) { return $Unit.Sources[$scopeKey] }
                        $parameterNames = $Unit.ParameterNames[[string]$parentNode.Extent.StartOffset]
                        if ($null -ne $parameterNames -and $parameterNames.ContainsKey($NormalizedName)) { return $null }
                        if ($Unit.LocalAssignments.ContainsKey($scopeKey)) {
                            foreach ($shadowAssignment in $Unit.LocalAssignments[$scopeKey]) {
                                if ($shadowAssignment.End -le $Node.Extent.StartOffset -and
                                    $shadowAssignment.BlockStart -le $Node.Extent.StartOffset -and $Node.Extent.EndOffset -le $shadowAssignment.BlockEnd) { return $null }
                            }
                        }
                        $innermostScope = $false
                    }
                    $parentNode = $parentNode.Parent
                }
            }
            if ($Qualifier -ne 'global' -and $Unit.Sources.ContainsKey('<script>|' + $NormalizedName) -and
                -not ($Qualifier -eq '' -and $innermostScope -and ($isReadBeforeWriters.InvokeReturnAsIs($Unit, $Node, ('<script>|' + $NormalizedName), $null)))) { return $Unit.Sources['<script>|' + $NormalizedName] }
            if ($Qualifier -ne 'script' -and $globalSources.ContainsKey($NormalizedName)) { return $globalSources[$NormalizedName] }
            return $null
        }
        # Ключ вузла-значення ($( ... ) чи присвоєний оператор) у NodeValues.
        $getNodeKey = {
            param($Node)
            return ([string]$Node.Extent.StartOffset + '|' + [string]$Node.Extent.EndOffset + '|' + $Node.GetType().Name)
        }
        # Рядковий ключ індексу $x['K'] — те саме місце, що $x.K.
        $getConstantIndexKey = {
            param($IndexNode)
            if ($IndexNode.Index -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $IndexNode.Index.Value.ToLowerInvariant() }
            return $null
        }
        $isValueStatement = {
            param($Node)
            return ($Node -is [System.Management.Automation.Language.SubExpressionAst] -or
                $Node -is [System.Management.Automation.Language.IfStatementAst] -or
                $Node -is [System.Management.Automation.Language.TryStatementAst] -or
                $Node -is [System.Management.Automation.Language.SwitchStatementAst] -or
                $Node -is [System.Management.Automation.Language.LoopStatementAst])
        }
        # Джерело, яке несе значення виразу (вид L — сам список), або $null.
        $getTaint = {
            param($Unit, $Node)
            $valueNode = $unwrapExpression.InvokeReturnAsIs($Node)
            if ($valueNode -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $valueName = $getNormalizedName.InvokeReturnAsIs($valueNode.VariablePath.UserPath)
                if (-not $taintedNames.ContainsKey($valueName)) { return $null }
                return ($resolveVariable.InvokeReturnAsIs($Unit, $valueNode, $valueName, ($getScopeQualifier.InvokeReturnAsIs($valueNode))))
            }
            if ($valueNode -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) { return $null }
            if ($valueNode -is [System.Management.Automation.Language.MemberExpressionAst]) {
                if ($valueNode.Static -or $valueNode.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
                return $Unit.Members[$valueNode.Member.Value.ToLowerInvariant()]
            }
            if ($valueNode -is [System.Management.Automation.Language.IndexExpressionAst]) {
                $indexKey = $getConstantIndexKey.InvokeReturnAsIs($valueNode)
                if ($null -ne $indexKey -and $Unit.Members.ContainsKey($indexKey)) { return $Unit.Members[$indexKey] }
                $indexTarget = $valueNode.Target
                if ($indexTarget -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    # Елемент W-обгортки ($w = ,$list; $w[0]) — сам список.
                    $wrapperName = '#' + ($getNormalizedName.InvokeReturnAsIs($indexTarget.VariablePath.UserPath))
                    if ($taintedNames.ContainsKey($wrapperName)) {
                        $wrapperOrigin = $resolveVariable.InvokeReturnAsIs($Unit, $valueNode, $wrapperName, ($getScopeQualifier.InvokeReturnAsIs($indexTarget)))
                        if ($null -ne $wrapperOrigin) { return $wrapperOrigin }
                    }
                    $valueName = '[]' + ($getNormalizedName.InvokeReturnAsIs($indexTarget.VariablePath.UserPath))
                    if (-not $taintedNames.ContainsKey($valueName)) { return $null }
                    return ($resolveVariable.InvokeReturnAsIs($Unit, $valueNode, $valueName, ($getScopeQualifier.InvokeReturnAsIs($indexTarget))))
                }
                if ($indexTarget -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    $indexTarget -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    -not $indexTarget.Static -and $indexTarget.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    return $Unit.Members['[]' + $indexTarget.Member.Value.ToLowerInvariant()]
                }
                return $null
            }
            if ($valueNode -is [System.Management.Automation.Language.ConvertExpressionAst]) {
                if ($valueNode.Type.TypeName.FullName -notmatch $unsafeTypePattern) { return $null }
                return ($getTaint.InvokeReturnAsIs($Unit, $valueNode.Child))
            }
            if ($isValueStatement.InvokeReturnAsIs($valueNode)) { return $Unit.NodeValues[($getNodeKey.InvokeReturnAsIs($valueNode))] }
            if ($valueNode -is [System.Management.Automation.Language.PipelineAst]) {
                # Значення конвеєра — вихід останньої команди.
                $lastElement = $valueNode.PipelineElements[$valueNode.PipelineElements.Count - 1]
                if ($lastElement -is [System.Management.Automation.Language.CommandAst]) { return ($getCommandTaint.InvokeReturnAsIs($Unit, $lastElement, 'collected')) }
            }
            return $null
        }
        # Вихід команди: New-Object List[object] або виклик функції, вихід
        # визначення якої несе список. -Shape: 'stream' — список серед
        # емітованих об'єктів (конвеєр, емісія далі); 'collected' — зібране
        # значення є самим списком (визначення з Multi пропускаються: там
        # масив); 'wrapper' — зібране значення є масивом із цим списком
        # (лише визначення з Multi).
        $getCommandTaint = {
            param($Unit, $CommandNode, [string]$Shape = 'stream')
            $builtinName = $getBuiltinName.InvokeReturnAsIs($CommandNode)
            if ($Shape -eq 'wrapper' -and ($builtinName -eq 'new-object' -or $builtinName -eq 'write-output')) { return $null }
            if ($builtinName -eq 'new-object') {
                if (($getNewObjectTypeName.InvokeReturnAsIs($CommandNode)) -match $listTypePattern) { return ($Unit.Name + ':' + $CommandNode.Extent.StartLineNumber) }
                return $null
            }
            if ($builtinName -eq 'write-output') {
                # Write-Output -NoEnumerate <L> передає список цілим; без
                # -NoEnumerate значення розгортається, як емітований вираз.
                $noEnumerate = $false
                $valueNodes = @()
                $elements = $CommandNode.CommandElements
                for ($elementIndex = 1; $elementIndex -lt $elements.Count; $elementIndex++) {
                    $element = $elements[$elementIndex]
                    if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                        $parameterName = $element.ParameterName.ToLowerInvariant()
                        if ($parameterName.Length -gt 0 -and 'noenumerate'.StartsWith($parameterName)) { $noEnumerate = $true; continue }
                        if ($parameterName.Length -gt 2 -and 'inputobject'.StartsWith($parameterName)) {
                            if ($null -ne $element.Argument) { $valueNodes += $element.Argument }
                            elseif ($elementIndex + 1 -lt $elements.Count) { $elementIndex++; $valueNodes += $elements[$elementIndex] }
                        }
                        continue
                    }
                    $valueNodes += $element
                }
                foreach ($valueNode in $valueNodes) {
                    $valueOrigin = if ($noEnumerate) { $getTaint.InvokeReturnAsIs($Unit, $valueNode) } else { $getWrapped.InvokeReturnAsIs($Unit, $valueNode) }
                    if ($null -ne $valueOrigin) { return $valueOrigin }
                }
                return $null
            }
            foreach ($definition in ($resolveDefinitions.InvokeReturnAsIs($Unit, ($getFunctionKey.InvokeReturnAsIs($CommandNode))))) {
                if (-not $functionOutputs.ContainsKey($definition.OutputKey)) { continue }
                if ($Shape -ne 'stream') {
                    # Multi обчислюється ліниво: лише для визначень, чий
                    # вихід уже несе список.
                    if ($null -eq $definition.Multi) { $definition.Multi = $isMultiOutput.InvokeReturnAsIs($definition.Node) }
                    if (($Shape -eq 'collected') -eq $definition.Multi) { continue }
                }
                return $functionOutputs[$definition.OutputKey]
            }
            return $null
        }
        $canCarryCommand = {
            param($CommandNode)
            $builtinName = $getBuiltinName.InvokeReturnAsIs($CommandNode)
            return ($builtinName -eq 'new-object' -or $builtinName -eq 'write-output' -or $definitions.ContainsKey(($getFunctionKey.InvokeReturnAsIs($CommandNode))))
        }
        # Значення виразу після розгортання на один рівень (так його
        # емітує конвеєр-вираз): ,<L> і (,<L>) дають список, W-змінна
        # ($w = ,$list) — теж; голий список розгортається в елементи;
        # зібраний вихід функції з Multi — масив, елемент якого список.
        $getWrapped = {
            param($Unit, $Node)
            $valueNode = $unwrapExpression.InvokeReturnAsIs($Node)
            if ($valueNode -is [System.Management.Automation.Language.PipelineAst]) {
                $lastElement = $valueNode.PipelineElements[$valueNode.PipelineElements.Count - 1]
                if ($lastElement -is [System.Management.Automation.Language.CommandAst]) { return ($getCommandTaint.InvokeReturnAsIs($Unit, $lastElement, 'wrapper')) }
                return $null
            }
            if ($valueNode -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                if ($valueNode.Elements.Count -ne 1) { return $null }
                return ($getTaint.InvokeReturnAsIs($Unit, $valueNode.Elements[0]))
            }
            if ($valueNode -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $valueName = '#' + ($getNormalizedName.InvokeReturnAsIs($valueNode.VariablePath.UserPath))
                if (-not $taintedNames.ContainsKey($valueName)) { return $null }
                return ($resolveVariable.InvokeReturnAsIs($Unit, $valueNode, $valueName, ($getScopeQualifier.InvokeReturnAsIs($valueNode))))
            }
            return $null
        }
        # Статичний відсів: чи може вираз узагалі нести джерело.
        $canCarry = {
            param($Node, [string]$Mode)
            if ($Mode -eq 'key') { return $true }
            if ($Mode -eq 'stream') { return ($canCarryCommand.InvokeReturnAsIs($Node)) }
            if ($Mode -eq 'upstream') {
                if ($Node -is [System.Management.Automation.Language.CommandAst]) { return ($canCarryCommand.InvokeReturnAsIs($Node)) }
                if ($Node -is [System.Management.Automation.Language.CommandExpressionAst]) { return ($canCarry.InvokeReturnAsIs($Node.Expression, 'wrapped')) }
                return $false
            }
            $valueNode = $unwrapExpression.InvokeReturnAsIs($Node)
            if ($Mode -eq 'wrapped') {
                if ($valueNode -is [System.Management.Automation.Language.PipelineAst]) {
                    $lastElement = $valueNode.PipelineElements[$valueNode.PipelineElements.Count - 1]
                    return ($lastElement -is [System.Management.Automation.Language.CommandAst] -and ($canCarryCommand.InvokeReturnAsIs($lastElement)))
                }
                return (($valueNode -is [System.Management.Automation.Language.ArrayLiteralAst] -and $valueNode.Elements.Count -eq 1) -or
                    $valueNode -is [System.Management.Automation.Language.VariableExpressionAst])
            }
            if ($valueNode -is [System.Management.Automation.Language.ConvertExpressionAst]) {
                return ($valueNode.Type.TypeName.FullName -match $unsafeTypePattern -and ($canCarry.InvokeReturnAsIs($valueNode.Child, 'taint')))
            }
            if ($valueNode -is [System.Management.Automation.Language.PipelineAst]) {
                $lastElement = $valueNode.PipelineElements[$valueNode.PipelineElements.Count - 1]
                return ($lastElement -is [System.Management.Automation.Language.CommandAst] -and ($canCarryCommand.InvokeReturnAsIs($lastElement)))
            }
            return ($valueNode -is [System.Management.Automation.Language.VariableExpressionAst] -or
                $valueNode -is [System.Management.Automation.Language.MemberExpressionAst] -or
                $valueNode -is [System.Management.Automation.Language.IndexExpressionAst] -or
                ($isValueStatement.InvokeReturnAsIs($valueNode)))
        }
        # Ліва частина присвоєння як місця: змінна, елемент словника чи
        # властивість. Каст [object]/[psobject] розгортається, інший тип
        # ([object[]], [List[object]], [string] ...) конвертує значення й
        # обгортку знімає — місця немає. Рядковий індекс $x['K'] — місце
        # ключа 'k' (як $x.K) і водночас місце довільного елемента $x[...];
        # словник-властивість $o.P[...] — місце '[]p' у Members. -Wrapped:
        # місце виду W ($w = ,$list) — лише для змінної.
        $getAssignmentPlaces = {
            param($Unit, $Assignment, [bool]$Wrapped)
            $left = $Assignment.Left
            while ($left -is [System.Management.Automation.Language.AttributedExpressionAst]) {
                if ($left -is [System.Management.Automation.Language.ConvertExpressionAst] -and
                    $left.Type.TypeName.FullName -notmatch $unsafeTypePattern) { return ,@() }
                $left = $left.Child
            }
            $places = @()
            $targetPath = $null
            if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $targetPath = $left.VariablePath.UserPath
                $placeName = $getNormalizedName.InvokeReturnAsIs($targetPath)
                if ($Wrapped) { $placeName = '#' + $placeName }
            } elseif ($Wrapped) {
                return ,@()
            } elseif ($left -is [System.Management.Automation.Language.IndexExpressionAst]) {
                $indexKey = $getConstantIndexKey.InvokeReturnAsIs($left)
                if ($null -ne $indexKey) { $places += [pscustomobject]@{ Table = $Unit.Members; Key = $indexKey; Name = $null } }
                if ($left.Target -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $targetPath = $left.Target.VariablePath.UserPath
                    $placeName = '[]' + ($getNormalizedName.InvokeReturnAsIs($targetPath))
                } elseif ($left.Target -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    $left.Target -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    -not $left.Target.Static -and $left.Target.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $places += [pscustomobject]@{ Table = $Unit.Members; Key = ('[]' + $left.Target.Member.Value.ToLowerInvariant()); Name = $null }
                }
            } elseif ($left -is [System.Management.Automation.Language.MemberExpressionAst] -and
                -not $left.Static -and $left.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $places += [pscustomobject]@{ Table = $Unit.Members; Key = $left.Member.Value.ToLowerInvariant(); Name = $null }
            }
            if ($null -ne $targetPath) {
                if ($targetPath -match '^global:') {
                    $places += [pscustomobject]@{ Table = $globalSources; Key = $placeName; Name = $placeName }
                } else {
                    $placeScope = if ($targetPath -match '^script:') { '<script>' } else { $getScopeId.InvokeReturnAsIs($Assignment) }
                    $places += [pscustomobject]@{ Table = $Unit.Sources; Key = ($placeScope + '|' + $placeName); Name = $placeName }
                }
            }
            return ,$places
        }
        # Місце, у яке реально потрапляє вихід конвеєра: сам він — оператор
        # блоку чи return, а над ним лише оператори керування (if/цикл/try/
        # switch/trap) до найближчого контейнера виходу: тіла функції
        # (FunctionOutputs), $( ... ) чи if/try/switch/циклу, що сам є
        # правою частиною присвоєння (NodeValues). Присвоєння, аргумент,
        # умова, (...) чи скриптблок-вираз вихід не формують.
        $getEmissionPlace = {
            param($Unit, $Pipeline)
            $parentNode = $Pipeline.Parent
            if ($parentNode -isnot [System.Management.Automation.Language.StatementBlockAst] -and
                $parentNode -isnot [System.Management.Automation.Language.NamedBlockAst] -and
                $parentNode -isnot [System.Management.Automation.Language.ReturnStatementAst]) { return $null }
            while ($null -ne $parentNode) {
                if ($parentNode -is [System.Management.Automation.Language.ScriptBlockAst]) {
                    if ($parentNode.Parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                        return [pscustomobject]@{ Table = $functionOutputs; Key = ($Unit.Name + '|' + [string]$parentNode.Parent.Extent.StartOffset); Name = $null }
                    }
                    return $null
                }
                if ($parentNode -is [System.Management.Automation.Language.SubExpressionAst] -or
                    (($isValueStatement.InvokeReturnAsIs($parentNode)) -and $parentNode.Parent -is [System.Management.Automation.Language.AssignmentStatementAst])) {
                    return [pscustomobject]@{ Table = $Unit.NodeValues; Key = ($getNodeKey.InvokeReturnAsIs($parentNode)); Name = $null }
                }
                if ($parentNode -isnot [System.Management.Automation.Language.StatementBlockAst] -and
                    $parentNode -isnot [System.Management.Automation.Language.NamedBlockAst] -and
                    $parentNode -isnot [System.Management.Automation.Language.ReturnStatementAst] -and
                    $parentNode -isnot [System.Management.Automation.Language.IfStatementAst] -and
                    $parentNode -isnot [System.Management.Automation.Language.LoopStatementAst] -and
                    $parentNode -isnot [System.Management.Automation.Language.TryStatementAst] -and
                    $parentNode -isnot [System.Management.Automation.Language.CatchClauseAst] -and
                    $parentNode -isnot [System.Management.Automation.Language.SwitchStatementAst] -and
                    $parentNode -isnot [System.Management.Automation.Language.TrapStatementAst]) { return $null }
                $parentNode = $parentNode.Parent
            }
            return $null
        }
        # Параметри визначення, до яких прив'язується -<Name>: точний збіг
        # імені чи AliasAttribute має перевагу; інакше всі, для яких Name —
        # префікс імені чи аліасу (неоднозначний префікс PowerShell
        # відхиляє, тож консервативно — усі).
        $matchNamedParameter = {
            param($Definition, [string]$Name)
            if ($Definition.ByName.ContainsKey($Name)) { return ,@($Definition.ByName[$Name]) }
            $prefixMatches = @()
            foreach ($candidateName in $Definition.ByName.Keys) {
                if ($candidateName.StartsWith($Name)) { $prefixMatches += $Definition.ByName[$candidateName] }
            }
            return ,$prefixMatches
        }

        # Крок 1: розбір, вузли, визначення функцій з метаданими параметрів,
        # локальні присвоєння для затінення.
        foreach ($sourceItem in $Source) {
            $unitAst = [System.Management.Automation.Language.Parser]::ParseInput([string]$sourceItem.Text, [ref]$null, [ref]$null)
            # Предикат через $args[0], а не param(): прив'язка параметрів
            # скриптблоку на кожному вузлі AST утричі дорожча.
            $unitNodes = @($unitAst.FindAll({
                        $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -or
                        $args[0] -is [System.Management.Automation.Language.CommandAst] -or
                        $args[0] -is [System.Management.Automation.Language.CommandExpressionAst] -or
                        $args[0] -is [System.Management.Automation.Language.ArrayExpressionAst] -or
                        $args[0] -is [System.Management.Automation.Language.HashtableAst] -or
                        $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]
                    }, $true))
            $unit = [pscustomobject]@{
                Name             = [string]$sourceItem.Name
                Sources          = @{}
                Members          = @{}
                LocalAssignments = @{}
                ParameterNames   = @{}
                NodeValues       = @{}
                Writers          = @{}
                ReadOrder        = @{}
                ScriptParameters = @{}
                Assignments      = New-Object System.Collections.Generic.List[object]
                Hashtables       = New-Object System.Collections.Generic.List[object]
                Expressions      = New-Object System.Collections.Generic.List[object]
                ArrayExpressions = New-Object System.Collections.Generic.List[object]
                Commands         = New-Object System.Collections.Generic.List[object]
            }
            [void]$units.Add($unit)
            if ($null -ne $unitAst.ParamBlock) {
                foreach ($scriptParameter in $unitAst.ParamBlock.Parameters) { $unit.ScriptParameters[($getNormalizedName.InvokeReturnAsIs($scriptParameter.Name.VariablePath.UserPath))] = $true }
            }
            foreach ($node in $unitNodes) {
                if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    $scopeId = [string]$node.Extent.StartOffset
                    $parameterRecords = @()
                    $nameSet = @{}
                    $declaredParameters = $getFunctionParameters.InvokeReturnAsIs($node)
                    $parameterRanks = $getParameterRanks.InvokeReturnAsIs($node, $declaredParameters)
                    $parameterIndex = -1
                    foreach ($parameterNode in $declaredParameters) {
                        $parameterIndex++
                        $parameterName = $getNormalizedName.InvokeReturnAsIs($parameterNode.Name.VariablePath.UserPath)
                        $nameSet[$parameterName] = $true
                        $aliases = @()
                        foreach ($attribute in $parameterNode.Attributes) {
                            if ($attribute -isnot [System.Management.Automation.Language.AttributeAst] -or
                                $attribute.TypeName.Name -notmatch '^((System\.)?Management\.Automation\.)?Alias(Attribute)?$') { continue }
                            foreach ($aliasArgument in $attribute.PositionalArguments) {
                                if ($aliasArgument -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $aliases += $aliasArgument.Value.ToLowerInvariant() }
                            }
                        }
                        $fromPipeline = $false
                        foreach ($attribute in $parameterNode.Attributes) {
                            if ($attribute -isnot [System.Management.Automation.Language.AttributeAst] -or
                                $attribute.TypeName.Name -notmatch '^((System\.)?Management\.Automation\.)?Parameter(Attribute)?$') { continue }
                            foreach ($namedArgument in $attribute.NamedArguments) {
                                if ($namedArgument.ArgumentName -ne 'ValueFromPipeline') { continue }
                                if ($namedArgument.ExpressionOmitted -or ($namedArgument.Argument -is [System.Management.Automation.Language.VariableExpressionAst] -and
                                        $namedArgument.Argument.VariablePath.UserPath -eq 'true')) { $fromPipeline = $true }
                            }
                        }
                        $parameterTypeName = $getParameterTypeName.InvokeReturnAsIs($parameterNode)
                        $parameterRecords += [pscustomobject]@{
                            Node     = $parameterNode
                            Name     = $parameterName
                            Aliases  = $aliases
                            Unsafe   = ($parameterTypeName -match $unsafeTypePattern)
                            IsSwitch = ($parameterTypeName -match '^((System\.)?Management\.Automation\.)?Switch(Parameter)?$')
                            Rank     = $parameterRanks[$parameterIndex]
                            Pipeline = $fromPipeline
                        }
                    }
                    $unit.ParameterNames[$scopeId] = $nameSet
                    $functionKey = $node.Name.ToLowerInvariant()
                    if (-not $definitions.ContainsKey($functionKey)) { $definitions[$functionKey] = @() }
                    # Індекси для прив'язки: ім'я чи аліас -> параметр, ранг -> параметри.
                    $byName = @{}
                    $byRank = @{}
                    foreach ($parameterRecord in $parameterRecords) {
                        foreach ($bindingName in (@($parameterRecord.Name) + @($parameterRecord.Aliases))) { $byName[$bindingName] = $parameterRecord }
                        if (-not $byRank.ContainsKey($parameterRecord.Rank)) { $byRank[$parameterRecord.Rank] = @() }
                        $byRank[$parameterRecord.Rank] += $parameterRecord
                    }
                    $hasUnsafe = $false
                    foreach ($parameterRecord in $parameterRecords) { if ($parameterRecord.Unsafe) { $hasUnsafe = $true } }
                    $definitionRecord = [pscustomobject]@{ Unit = $unit; Node = $node; ScopeId = $scopeId; OutputKey = ($unit.Name + '|' + $scopeId); Parameters = $parameterRecords; ByName = $byName; ByRank = $byRank; HasUnsafe = $hasUnsafe; Multi = $null }
                    $definitions[$functionKey] += $definitionRecord
                    if (-not $node.IsFilter -and $null -ne $node.Body.EndBlock) {
                        $emissionCount = 0
                        foreach ($statement in $node.Body.EndBlock.Statements) {
                            if ($statement -is [System.Management.Automation.Language.ReturnStatementAst]) { $statement = $statement.Pipeline }
                            if ($statement -isnot [System.Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1 -or
                                $statement.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) { continue }
                            $emitted = $statement.PipelineElements[0].Expression
                            if ($emitted -is [System.Management.Automation.Language.ConstantExpressionAst] -or
                                $emitted -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
                                $emitted -is [System.Management.Automation.Language.HashtableAst] -or
                                $emitted -is [System.Management.Automation.Language.ArrayLiteralAst]) { $emissionCount++ }
                        }
                        if ($emissionCount -ge 2) { $multiCandidates[$functionKey] = $true }
                    }
                    $localKey = $unit.Name + '|' + $functionKey
                    if (-not $localDefinitions.ContainsKey($localKey)) { $localDefinitions[$localKey] = @() }
                    $localDefinitions[$localKey] += $definitionRecord
                } elseif ($node -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    [void]$unit.Expressions.Add($node)
                } elseif ($node -is [System.Management.Automation.Language.HashtableAst]) {
                    [void]$unit.Hashtables.Add($node)
                } elseif ($node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                    [void]$unit.ArrayExpressions.Add($node)
                } elseif ($node -is [System.Management.Automation.Language.CommandAst]) {
                    $commandName = $node.GetCommandName()
                    if (-not $commandName) { continue }
                    [void]$unit.Commands.Add($node)
                    if ($commandName -match '^(Microsoft\.PowerShell\.Utility\\)?(Set|New)-Alias$') {
                        $aliasDeclaration = $getAliasDeclaration.InvokeReturnAsIs($node)
                        if ($null -ne $aliasDeclaration) { $commandAliases[$aliasDeclaration[0]] = $aliasDeclaration[1] }
                    }
                } elseif ($node -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                    [void]$unit.Assignments.Add($node)
                    # Локальне присвоєння (без префікса $script:/$global:, з
                    # типом чи без) затіняє зовнішню змінну лише там, де воно
                    # домінує над читанням: оператор блоку, що охоплює місце
                    # читання, і завершився до нього. Присвоєння в гілці
                    # if/try чи в тілі циклу, що не охоплює читання, не
                    # затіняє (гілка може не виконатись).
                    $assignedNode = $node.Left
                    while ($assignedNode -is [System.Management.Automation.Language.AttributedExpressionAst]) { $assignedNode = $assignedNode.Child }
                    if ($assignedNode -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
                    $assignedName = ($assignedNode.VariablePath.UserPath -replace '^(script|global|local|private|using):', '').ToLowerInvariant()
                    if ($node.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and
                        ($unwrapExpression.InvokeReturnAsIs($node.Right)) -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                        $wrapperCandidates[$assignedName] = $true
                    }
                    if ($assignedNode.VariablePath.UserPath -notmatch '^(script|global):') {
                        $assignmentScopeNode = $node.Parent
                        while ($null -ne $assignmentScopeNode -and $assignmentScopeNode -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $assignmentScopeNode = $assignmentScopeNode.Parent }
                        if ($null -ne $assignmentScopeNode) {
                            $localKey = [string]$assignmentScopeNode.Extent.StartOffset + '|' + $assignedName
                            if ($node.Parent -is [System.Management.Automation.Language.StatementBlockAst] -or
                                $node.Parent -is [System.Management.Automation.Language.NamedBlockAst]) {
                                $shadowRecord = [pscustomobject]@{
                                    End        = $node.Extent.EndOffset
                                    BlockStart = $node.Parent.Extent.StartOffset
                                    BlockEnd   = $node.Parent.Extent.EndOffset
                                }
                                if ($unit.LocalAssignments.ContainsKey($localKey)) { $unit.LocalAssignments[$localKey] += $shadowRecord } else { $unit.LocalAssignments[$localKey] = @($shadowRecord) }
                            }
                        }
                    }
                }
            }
        }

        # Крок 2: правила переносу "значення -> місце". Правило, чиє
        # значення статично не може нести джерело, відкидається одразу.
        $rules = New-Object System.Collections.Generic.List[object]
        # -Mode: 'taint' — значення виразу; 'wrapped' — як емітоване
        # ($getWrapped); 'upstream' — те, що попередній елемент конвеєра
        # подає далі; 'stream' — вихід команди, емітований далі цілим
        # потоком ($getCommandTaint 'stream'); 'key' — ключ splat-
        # хештаблиці для параметра (Value — запис параметра).
        $addRule = {
            param($Unit, $Value, $Place, [string]$Mode = 'taint', [bool]$Checked = $false)
            if ($null -eq $Place -or $null -eq $Value -or (-not $Checked -and -not ($canCarry.InvokeReturnAsIs($Value, $Mode)))) { return }
            [void]$rules.Add([pscustomobject]@{ Unit = $Unit; Value = $Value; Mode = $Mode; Table = $Place.Table; Key = $Place.Key; Name = $Place.Name })
        }
        # Ключ splat-хештаблиці, що прив'язується до параметра: місце
        # ключа в Members, чиє ім'я збігається з іменем чи аліасом
        # параметра або є їх префіксом.
        $getSplatKeyTaint = {
            param($Unit, $ParameterRecord)
            $parameterNames = @($ParameterRecord.Name) + @($ParameterRecord.Aliases)
            foreach ($memberKey in @($Unit.Members.Keys)) {
                if ($memberKey.Length -eq 0 -or $memberKey.StartsWith('[]')) { continue }
                foreach ($parameterName in $parameterNames) {
                    if ($parameterName.StartsWith($memberKey)) { return $Unit.Members[$memberKey] }
                }
            }
            return $null
        }
        # $v = Get-X, де Get-X — кандидат Multi: місце виду W для $v.
        $wrapperAssignments = @{}
        if ($multiCandidates.Count -gt 0) {
            foreach ($unit in $units) {
                foreach ($node in $unit.Assignments) {
                    if ($node.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals) { continue }
                    if ($node.Right -isnot [System.Management.Automation.Language.PipelineAst]) { continue }
                    $lastElement = $node.Right.PipelineElements[$node.Right.PipelineElements.Count - 1]
                    if ($lastElement -isnot [System.Management.Automation.Language.CommandAst] -or -not $multiCandidates.ContainsKey(($getFunctionKey.InvokeReturnAsIs($lastElement)))) { continue }
                    $wrapperAssignments[$node] = $true
                    $assignedNode = $node.Left
                    while ($assignedNode -is [System.Management.Automation.Language.AttributedExpressionAst]) { $assignedNode = $assignedNode.Child }
                    if ($assignedNode -is [System.Management.Automation.Language.VariableExpressionAst]) { $wrapperCandidates[($getNormalizedName.InvokeReturnAsIs($assignedNode.VariablePath.UserPath))] = $true }
                }
            }
        }
        $sinks = New-Object System.Collections.Generic.List[object]
        foreach ($unit in $units) {
            foreach ($node in $unit.Assignments) {
                # Присвоєння: $x = ..., [object]$x = ..., $d[k] = ..., $o.P = ...
                if ($node.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals) { continue }
                # Кожне присвоєння змінній, що дає правило, — записувач її
                # місця для $isReadBeforeWriters (Writers).
                $assignedPlaces = $null
                $assignedMode = 'taint'
                if ($canCarry.InvokeReturnAsIs($node.Right, 'taint')) {
                    $assignedPlaces = $getAssignmentPlaces.InvokeReturnAsIs($unit, $node, $false)
                } elseif (($unwrapExpression.InvokeReturnAsIs($node.Right)) -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                    # $w = ,$list: місце виду W.
                    $assignedPlaces = $getAssignmentPlaces.InvokeReturnAsIs($unit, $node, $true)
                    $assignedMode = 'wrapped'
                }
                for ($placePass = 0; $placePass -lt 2; $placePass++) {
                    if ($placePass -eq 1) {
                        # $v = Get-X, де Get-X на кожному шляху емітує
                        # щонайменше два об'єкти: $v — масив, серед елементів
                        # якого список (вид W).
                        if ($wrapperAssignments.Count -eq 0 -or -not $wrapperAssignments.ContainsKey($node)) { break }
                        $assignedPlaces = $getAssignmentPlaces.InvokeReturnAsIs($unit, $node, $true)
                        $assignedMode = 'wrapped'
                    }
                    if ($null -eq $assignedPlaces) { continue }
                    foreach ($place in $assignedPlaces) {
                        $addRule.InvokeReturnAsIs($unit, $node.Right, $place, $assignedMode, ($assignedMode -eq 'taint' -or $placePass -eq 1))
                        if ($null -eq $place.Name -or [object]::ReferenceEquals($place.Table, $globalSources)) { continue }
                        if ($unit.Writers.ContainsKey($place.Key)) { $unit.Writers[$place.Key] += $node } else { $unit.Writers[$place.Key] = @($node) }
                    }
                }
            }
            foreach ($node in $unit.Hashtables) {
                # Ключ hashtable-літерала: @{ Owners = <значення> }.
                foreach ($pair in $node.KeyValuePairs) {
                    if ($pair.Item1 -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or -not ($canCarry.InvokeReturnAsIs($pair.Item2, 'taint'))) { continue }
                    $addRule.InvokeReturnAsIs($unit, $pair.Item2, ([pscustomobject]@{ Table = $unit.Members; Key = $pair.Item1.Value.ToLowerInvariant(); Name = $null }), 'taint', $true)
                }
            }
            foreach ($node in $unit.Expressions) {
                # Емісія виразу: увесь емітований конвеєр-вираз (return
                # ,$x, return (,$x), оператор ,$x, return $w) дає
                # контейнеру значення, розгорнуте на один рівень.
                if ($node.Parent -isnot [System.Management.Automation.Language.PipelineAst] -or $node.Parent.PipelineElements.Count -ne 1) { continue }
                # Відсів: лише ,<x> або змінна, яка десь отримує ,<x>.
                $emittedValue = $unwrapExpression.InvokeReturnAsIs($node.Expression)
                if ($emittedValue -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    if (-not $wrapperCandidates.ContainsKey(($getNormalizedName.InvokeReturnAsIs($emittedValue.VariablePath.UserPath)))) { continue }
                } elseif ($emittedValue -is [System.Management.Automation.Language.PipelineAst]) {
                    # return (Get-X): зібраний вихід розгортається; з Multi —
                    # список серед елементів.
                    $lastElement = $emittedValue.PipelineElements[$emittedValue.PipelineElements.Count - 1]
                    if ($lastElement -isnot [System.Management.Automation.Language.CommandAst] -or -not $multiCandidates.ContainsKey(($getFunctionKey.InvokeReturnAsIs($lastElement)))) { continue }
                } elseif ($emittedValue -isnot [System.Management.Automation.Language.ArrayLiteralAst] -or $emittedValue.Elements.Count -ne 1) { continue }
                $addRule.InvokeReturnAsIs($unit, $node.Parent, ($getEmissionPlace.InvokeReturnAsIs($unit, $node.Parent)), 'wrapped')
            }
            foreach ($node in $unit.ArrayExpressions) {
                # Sink: @(<вираз>) з одним оператором-виразом. @(Get-X)
                # (команда) безпечний: вихід команди не обгорнутий.
                $statements = $node.SubExpression.Statements
                if ($statements.Count -ne 1 -or $statements[0] -isnot [System.Management.Automation.Language.PipelineAst] -or
                    $statements[0].PipelineElements.Count -ne 1 -or
                    $statements[0].PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) { continue }
                [void]$sinks.Add([pscustomobject]@{ Unit = $unit; Node = $node; Value = $statements[0] })
            }
            foreach ($node in $unit.Commands) {
                # Відсів: команда, що не може ні нести список, ні
                # прив'язати аргумент до функції репозиторію, — пропуск.
                if (-not ($canCarryCommand.InvokeReturnAsIs($node))) { continue }
                # Емісія команди: виклик як останній елемент емітованого
                # конвеєра (Get-X, return Get-X, $x | Get-X, гілка
                # присвоєного if, $(Get-X)) передає її вихід далі без
                # розгортання; return (Get-X) — вираз, розгортає.
                $pipelineElements = $null
                $pipelineIndex = -1
                if ($node.Parent -is [System.Management.Automation.Language.PipelineAst]) {
                    $pipelineElements = $node.Parent.PipelineElements
                    for ($elementIndex = 0; $elementIndex -lt $pipelineElements.Count; $elementIndex++) {
                        if ([object]::ReferenceEquals($pipelineElements[$elementIndex], $node)) { $pipelineIndex = $elementIndex; break }
                    }
                    if ($pipelineIndex -eq $pipelineElements.Count - 1) {
                        $addRule.InvokeReturnAsIs($unit, $node, ($getEmissionPlace.InvokeReturnAsIs($unit, $node.Parent)), 'stream', $true)
                    }
                }
                # Прив'язка аргументів до параметрів визначень, до яких
                # резолвиться виклик: іменна з префіксом і аліасами,
                # позиційна за рангом, splat @p за ключами, конвеєрна
                # (ValueFromPipeline) з попереднього елемента. Аргумент —
                # будь-який вираз; місце — параметр визначення, якщо його
                # тип обгортку не знімає.
                $functionKey = $getFunctionKey.InvokeReturnAsIs($node)
                if (-not $definitions.ContainsKey($functionKey)) { continue }
                $elements = $node.CommandElements
                $carryCache = @{}
                foreach ($definition in ($resolveDefinitions.InvokeReturnAsIs($unit, $functionKey))) {
                    if (-not $definition.HasUnsafe) { continue }
                    if ($pipelineIndex -gt 0) {
                        foreach ($parameterRecord in $definition.Parameters) {
                            if (-not $parameterRecord.Pipeline -or -not $parameterRecord.Unsafe) { continue }
                            $addRule.InvokeReturnAsIs($unit, $pipelineElements[$pipelineIndex - 1], ([pscustomobject]@{ Table = $definition.Unit.Sources; Key = ($definition.ScopeId + '|' + $parameterRecord.Name); Name = $parameterRecord.Name }), 'upstream')
                        }
                    }
                    $positionalIndex = 0
                    for ($elementIndex = 1; $elementIndex -lt $elements.Count; $elementIndex++) {
                        $element = $elements[$elementIndex]
                        $argumentNode = $null
                        $boundParameters = @()
                        if ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and $element.Splatted) {
                            foreach ($parameterRecord in $definition.Parameters) {
                                if (-not $parameterRecord.Unsafe) { continue }
                                $addRule.InvokeReturnAsIs($unit, $parameterRecord, ([pscustomobject]@{ Table = $definition.Unit.Sources; Key = ($definition.ScopeId + '|' + $parameterRecord.Name); Name = $parameterRecord.Name }), 'key')
                            }
                            continue
                        }
                        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                            $parameterName = $element.ParameterName.ToLowerInvariant()
                            $boundParameters = $matchNamedParameter.InvokeReturnAsIs($definition, $parameterName)
                            $takesValue = ($boundParameters.Count -eq 0 -and $commonSwitchNames -notcontains $parameterName)
                            foreach ($boundParameter in $boundParameters) { if (-not $boundParameter.IsSwitch) { $takesValue = $true } }
                            if ($null -ne $element.Argument) {
                                $argumentNode = $element.Argument
                            } elseif ($takesValue -and $elementIndex + 1 -lt $elements.Count -and
                                $elements[$elementIndex + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                                $elementIndex++
                                $argumentNode = $elements[$elementIndex]
                            }
                        } else {
                            $argumentNode = $element
                            $argumentPosition = $positionalIndex
                            $positionalIndex++
                            $boundParameters = @()
                            if ($definition.ByRank.ContainsKey(-2)) { $boundParameters += $definition.ByRank[-2] }
                            if ($definition.ByRank.ContainsKey($argumentPosition)) { $boundParameters += $definition.ByRank[$argumentPosition] }
                        }
                        if ($null -eq $argumentNode) { continue }
                        if (-not $carryCache.ContainsKey($elementIndex)) { $carryCache[$elementIndex] = $canCarry.InvokeReturnAsIs($argumentNode, 'taint') }
                        if (-not $carryCache[$elementIndex]) { continue }
                        foreach ($boundParameter in $boundParameters) {
                            if (-not $boundParameter.Unsafe) { continue }
                            $addRule.InvokeReturnAsIs($unit, $argumentNode, ([pscustomobject]@{ Table = $definition.Unit.Sources; Key = ($definition.ScopeId + '|' + $boundParameter.Name); Name = $boundParameter.Name }), 'taint', $true)
                        }
                    }
                }
            }
        }
        # Значення параметра за замовчуванням ($Items = (New-Object ...))
        # для параметра, чий тип обгортку не знімає.
        foreach ($functionKey in @($definitions.Keys)) {
            foreach ($definition in $definitions[$functionKey]) {
                foreach ($parameterRecord in $definition.Parameters) {
                    if (-not $parameterRecord.Unsafe -or $null -eq $parameterRecord.Node.DefaultValue) { continue }
                    $addRule.InvokeReturnAsIs($definition.Unit, $parameterRecord.Node.DefaultValue, ([pscustomobject]@{ Table = $definition.Unit.Sources; Key = ($definition.ScopeId + '|' + $parameterRecord.Name); Name = $parameterRecord.Name }))
                }
            }
        }

        # Крок 3: нерухома точка. Правило, чиє місце вже джерело, більше не
        # потрібне; решта перевіряються знову, доки хоч одне місце нове.
        $pendingRules = $rules
        do {
            $changed = $false
            $remainingRules = New-Object System.Collections.Generic.List[object]
            foreach ($rule in $pendingRules) {
                if ($rule.Table.ContainsKey($rule.Key)) { continue }
                $origin = if ($rule.Mode -eq 'wrapped') {
                    $getWrapped.InvokeReturnAsIs($rule.Unit, $rule.Value)
                } elseif ($rule.Mode -eq 'key') {
                    $getSplatKeyTaint.InvokeReturnAsIs($rule.Unit, $rule.Value)
                } elseif ($rule.Mode -eq 'stream') {
                    $getCommandTaint.InvokeReturnAsIs($rule.Unit, $rule.Value, 'stream')
                } elseif ($rule.Mode -eq 'upstream') {
                    if ($rule.Value -is [System.Management.Automation.Language.CommandAst]) { $getCommandTaint.InvokeReturnAsIs($rule.Unit, $rule.Value, 'stream') } else { $getWrapped.InvokeReturnAsIs($rule.Unit, $rule.Value.Expression) }
                } else {
                    $getTaint.InvokeReturnAsIs($rule.Unit, $rule.Value)
                }
                if ($null -eq $origin) { [void]$remainingRules.Add($rule); continue }
                $rule.Table[$rule.Key] = $origin
                if ($null -ne $rule.Name) { $taintedNames[$rule.Name] = $true }
                $changed = $true
            }
            $pendingRules = $remainingRules
        } while ($changed)

        # Крок 4: sink-и.
        $findings = New-Object System.Collections.Generic.List[string]
        foreach ($sink in $sinks) {
            $origin = $getTaint.InvokeReturnAsIs($sink.Unit, $sink.Value)
            if ($null -eq $origin) { continue }
            $sinkValue = $unwrapExpression.InvokeReturnAsIs($sink.Value)
            $reason = if ($sinkValue -is [System.Management.Automation.Language.IndexExpressionAst]) {
                'елемент словника тримає New-Object List[object]'
            } elseif ($sinkValue -is [System.Management.Automation.Language.MemberExpressionAst]) {
                'властивості в цьому файлі присвоєно New-Object List[object]'
            } elseif ($sinkValue -is [System.Management.Automation.Language.PipelineAst]) {
                'виклик повертає New-Object List[object] через ,$list'
            } else {
                'змінна чи параметр тримає New-Object List[object]'
            }
            [void]$findings.Add($sink.Unit.Name + ':' + $sink.Node.Extent.StartLineNumber + ': ' + $sink.Node.Extent.Text + ' (' + $reason + '; джерело ' + $origin + ')')
        }
        return ,$findings.ToArray()
    }

    # --- Governance/GenericObjectListNeverWrappedInArraySubexpression ---
    $binderGateFiles = & {
        . (Join-Path $root 'ci\BRAVOAnalyzableFiles.ps1')
        @(Get-BRAVOAnalyzableFile -Root $root | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
    }
    $binderGateRootPrefix = $root.TrimEnd('\', '/')
    $binderGateSources = New-Object System.Collections.Generic.List[object]
    foreach ($binderGateFile in @($binderGateFiles)) {
        [void]$binderGateSources.Add([pscustomobject]@{
            Name = $binderGateFile.FullName.Substring($binderGateRootPrefix.Length).TrimStart('\', '/')
            Text = [IO.File]::ReadAllText($binderGateFile.FullName, [Text.Encoding]::UTF8)
        })
    }
    $binderGateFindings = Find-BRAVOObjectListArraySubexpression -Source $binderGateSources.ToArray()
    Test-BRAVOCondition `
        -Condition ($binderGateSources.Count -gt 0 -and $binderGateFindings.Count -eq 0) `
        -Name "Governance/GenericObjectListNeverWrappedInArraySubexpression" `
        -Failure ("@(<List[object] з New-Object>) кидає ArgumentException 'Argument types do not match' " +
            "у Windows PowerShell 5.1 і PowerShell 7 — використовуйте .ToArray() або параметр [object[]]. " +
            "Проскановано файлів: $($binderGateSources.Count); знахідки: " +
            $(if ($binderGateFindings.Count -gt 0) { $binderGateFindings -join '; ' } else { '<немає>' }))

    # --- Governance/GenericObjectListBinderGuardIsMeaningful ---
    # Негативний контроль: форми, які під PowerShell дійсно кидають
    # (локальна змінна, $script:, аліас, параметр без типу чи [object],
    # return ,$list, змінна обгортки T010, властивість, елемент словника),
    # мусять знаходитись, а безпечні форми (.ToArray(), параметр
    # [object[]], список [psobject], сирий виклик @(Get-X), @($d.Keys)) — ні.
    # Рядки 26-44 тримають виправлення за review PR #259: ланцюг return ,$v
    # (27), аліас у словник і властивість (28-29), позиційні аргументи за
    # порядком параметрів (30-35), [System.Management.Automation.PSObject]
    # (36), затінення локальним присвоєнням (38-39), $global: з іншого файлу
    # (40), значення параметра за замовчуванням (41-42) і однойменні функції
    # в різних файлах (43 проти fixture-typed). Рядки 45-82 — другий раунд
    # review, по парі "небезпечна форма / безпечний сусід" на кожен клас
    # потокової моделі: вбудований аргумент-вираз (45-50, ::new() — не
    # джерело), read-back з властивості й елемента (51-54), параметр-
    # пересилання (55-60), AliasAttribute з перевагою точного збігу (61-64),
    # вихід функції лише з реально емітованого ,$x чи виклику (65-73),
    # тип лише з -TypeName (74-76), ліва частина [object]/[psobject] проти
    # [object[]]/[List[object]] (77-80), Microsoft.PowerShell.Utility\New-Object
    # (81-82). Рядки 83-103 — незалежне review моделі: значення присвоєного
    # if/try/switch — те, що емітують гілки (83-87: голий список і
    # .ToArray() у гілці безпечні), $d['K'] і $d.K — одне місце, словник-
    # властивість $o.P[...] (88-93: .Count і .Keys безпечні), return (,$x)
    # зберігає список, а $p = (,$x) — ні (94-96), $( ... ) як значення й
    # аргумент (97-100), $w = ,$list; return $w (101-103: @($w) безпечний).
    # Рядки 104-127 — третій раунд review: hashtable-літерал і $map['key']
    # (104), splat @p з літерала і зі збереженого ключа (105-110: параметр
    # [object[]] безпечний), конвеєр у ValueFromPipeline (111-116: голий
    # $list | ... розгортається і безпечний), Set-Alias/New-Alias (117-122),
    # $script:x і $global:x — різні місця (123-124), вихід функції за
    # визначенням: локальне визначення Get-SharedOutput затіняє небезпечне з
    # fixture-output (125-126), а функція лише з fixture-output резолвиться
    # до нього (127). Рядки 128-137 — четвертий раунд: $a = $b = <список>
    # (128; [object[]]$b конвертує — 129), Write-Output -NoEnumerate
    # зберігає список, а без нього розгортає (130-133), $w[0] з W-обгортки
    # (134; $w.Count безпечний — 135), присвоєння в невиконаній гілці
    # вкладеної функції не затіняє список обгортки (136), а безумовне —
    # затіняє (137). Рядки 138-152 — кардинальність і порядок: функція з
    # двома безумовними емісіями (,$items; 'tail') віддає масив — @($r)
    # безпечний (139), але $r[0] — список (140); рання return у гілці
    # перед двома емісіями (141-142), конвеєр (143), повторна емісія $r
    # (144) і return (Get-X) (145) список зберігають, як і емісія з
    # перенаправленням > $null, що не рахується (146-147). Копія
    # $copy = $items до першого присвоєння списку в тому самому блоці
    # безпечна (148), але не в циклі (149), не після іншого присвоєння
    # списку (150), не коли $items до того несе зовнішній scope (151: там
    # список з'являється лише на другому кроці нерухомої точки) і не для
    # параметра (152).
    # Кожен знайдений рядок справді кидає під PowerShell, кожен
    # безпечний — ні (крім 14 і 18: вкладена функція там не викликається).
    $binderGateFixture = @'
$script:History = New-Object System.Collections.Generic.List[object]
function Get-LocalForm { $items = New-Object System.Collections.Generic.List[object]; return @($items) }
function Get-ScriptForm { return @($script:History) }
function Get-AliasForm { $items = New-Object 'System.Collections.Generic.List[System.Object]'; $copy = $items; return @($copy) }
function Get-UntypedParameterForm($Items) { return @($Items) }
function Invoke-UntypedParameterForm { $items = New-Object System.Collections.Generic.List[object]; Get-UntypedParameterForm -Items $items }
function Get-WrappedList { $items = New-Object System.Collections.Generic.List[object]; return ,$items }
function Get-ReturnedForm { $returned = Get-WrappedList; return @($returned) }
function Get-SafeToArray { $items = New-Object System.Collections.Generic.List[object]; return @($items.ToArray()) }
function Get-SafeTypedParameter([object[]]$Items) { return @($Items) }
function Invoke-SafeTypedParameter { $items = New-Object System.Collections.Generic.List[object]; Get-SafeTypedParameter -Items $items }
function Get-SafePsObjectList { $items = New-Object System.Collections.Generic.List[psobject]; return @($items) }
function Get-SafeCommand { return @(Get-LocalForm) }
function Invoke-RuntimeWrapper { $items = New-Object System.Collections.Generic.List[object]; function Get-NestedForm { return @($items) }; return $null }
function Invoke-RuntimeWrapper2 { $items = New-Object System.Collections.Generic.List[object]; function Get-NestedParam($Items) { return @($Items) }; Get-NestedParam -Items $items }
function Invoke-RuntimeWrapper3 { $items = New-Object System.Collections.Generic.List[object]; function Get-NestedSafe { return @($items.ToArray()) }; return $null }
function Invoke-RuntimeWrapper4 { $items = New-Object System.Collections.Generic.List[object]; function Get-NestedTyped([object[]]$Items) { return @($Items) }; Get-NestedTyped -Items $items }
function Invoke-RuntimeWrapper5 { $items = New-Object System.Collections.Generic.List[object]; function Get-NestedAlias { $copy = $items; return @($copy) }; return $null }
function Invoke-RuntimeWrapper6 { $items = New-Object System.Collections.Generic.List[object]; function Get-NestedObj([object]$Items) { return @($Items) }; Get-NestedObj -Items $items }
function Get-PropertyForm { $group = [pscustomobject]@{ Owners = (New-Object System.Collections.Generic.List[object]) }; return @($group.Owners) }
function Get-PropertyAssignedForm { $state = @{}; $state.Pending = New-Object System.Collections.Generic.List[object]; return @($state.Pending) }
function Get-DictionaryForm { $byKey = @{}; $byKey['a'] = New-Object System.Collections.Generic.List[object]; return @($byKey['a']) }
function Get-SafePropertyToArray { $group = [pscustomobject]@{ Owners = (New-Object System.Collections.Generic.List[object]) }; return @($group.Owners.ToArray()) }
function Get-SafeDictionaryKeys { $byKey = @{}; $byKey['a'] = New-Object System.Collections.Generic.List[object]; return @($byKey.Keys) }
function Get-SafePsObjectProperty { $group = [pscustomobject]@{ Rows = (New-Object System.Collections.Generic.List[psobject]) }; return @($group.Rows) }
function Get-WrappedTwice { $inner = Get-WrappedList; return ,$inner }
function Get-ChainedForm { $chained = Get-WrappedTwice; return @($chained) }
function Get-DictionaryAliasForm { $items = New-Object System.Collections.Generic.List[object]; $byKey = @{}; $byKey['a'] = $items; return @($byKey['a']) }
function Get-PropertyAliasForm { $items = New-Object System.Collections.Generic.List[object]; $holder = @{}; $holder.Queued = $items; return @($holder.Queued) }
function Show-SafeSecond([object[]]$First, $Second) { return @($Second) }
function Invoke-SafeSecond { $items = New-Object System.Collections.Generic.List[object]; Show-SafeSecond $items 'x' }
function Show-First($First, [object[]]$Second) { return @($First) }
function Invoke-First { $items = New-Object System.Collections.Generic.List[object]; Show-First $items 'x' }
function Show-SafeOrdered { param([Parameter(Position = 1)][object[]]$Head, [Parameter(Position = 0)]$Tail) return @($Tail) }
function Invoke-SafeOrdered { $items = New-Object System.Collections.Generic.List[object]; Show-SafeOrdered 'x' $items }
function Get-FullPsObjectParameter([System.Management.Automation.PSObject]$Items) { return @($Items) }
function Invoke-FullPsObjectParameter { $items = New-Object System.Collections.Generic.List[object]; Get-FullPsObjectParameter -Items $items }
function Get-SafeShadowedForm { $history = @(1, 2); return @($history) }
function Get-ReadBeforeShadowForm { $copy = @($history); $history = $null; return $copy }
function Get-GlobalForm { return @($global:BinderGateShared) }
function Get-DefaultForm($Items = (New-Object System.Collections.Generic.List[object])) { return @($Items) }
function Get-SafeTypedDefault([object[]]$Items = (New-Object System.Collections.Generic.List[object])) { return @($Items) }
function Show-SharedName($Items) { return @($Items) }
function Invoke-SharedName { $items = New-Object System.Collections.Generic.List[object]; Show-SharedName -Items $items }
function Show-InlineArgument($Items) { return @($Items) }
function Invoke-InlineArgument { Show-InlineArgument -Items (New-Object System.Collections.Generic.List[object]) }
function Show-InlineCallArgument($Items) { return @($Items) }
function Invoke-InlineCallArgument { Show-InlineCallArgument -Items (Get-WrappedList) }
function Show-SafeInlineArgument($Items) { return @($Items) }
function Invoke-SafeInlineArgument { Show-SafeInlineArgument -Items ([System.Collections.Generic.List[object]]::new()) }
function Get-PropertyReadBackForm { $holder = @{}; $holder.Parked = New-Object System.Collections.Generic.List[object]; $parked = $holder.Parked; return @($parked) }
function Get-IndexReadBackForm { $slots = @{}; $slots['a'] = New-Object System.Collections.Generic.List[object]; $slot = $slots['a']; return @($slot) }
function Get-SafePropertyReadBack { $holder = @{}; $holder.Parked = New-Object System.Collections.Generic.List[object]; $parkedCount = $holder.Parked.Count; return @($parkedCount) }
function Get-SafeIndexReadBack { $slots = @{}; $slots['a'] = New-Object System.Collections.Generic.List[object]; $slotItems = $slots['a'].ToArray(); return @($slotItems) }
function Show-ForwardedSink($Items) { return @($Items) }
function Invoke-ForwardingHop($Relay) { Show-ForwardedSink -Items $Relay }
function Invoke-ForwardingStart { $items = New-Object System.Collections.Generic.List[object]; Invoke-ForwardingHop -Relay $items }
function Show-SafeForwardedSink($Items) { return @($Items) }
function Invoke-SafeForwardingHop([object[]]$Relay) { Show-SafeForwardedSink -Items $Relay }
function Invoke-SafeForwardingStart { $items = New-Object System.Collections.Generic.List[object]; Invoke-SafeForwardingHop -Relay $items }
function Show-AliasedSink { param([Alias('Value')]$Items) return @($Items) }
function Invoke-AliasedSink { $items = New-Object System.Collections.Generic.List[object]; Show-AliasedSink -Value $items }
function Show-SafeAliasedSink { param([Alias('Value')][object[]]$Items, $Values) return @($Values) }
function Invoke-SafeAliasedSink { $items = New-Object System.Collections.Generic.List[object]; Show-SafeAliasedSink -Value $items }
function Get-CommaDiscarded { $items = New-Object System.Collections.Generic.List[object]; $ignored = ,$items; return 'safe' }
function Get-SafeCommaDiscardedForm { $result = Get-CommaDiscarded; return @($result) }
function Get-EmittedComma { $items = New-Object System.Collections.Generic.List[object]; ,$items }
function Get-EmittedCommaForm { $result = Get-EmittedComma; return @($result) }
function Get-PassThroughList { Get-WrappedList }
function Get-PassThroughForm { $result = Get-PassThroughList; return @($result) }
function Get-ParenReturnList { return (Get-WrappedList) }
function Get-SafeParenReturnForm { $result = Get-ParenReturnList; return @($result) }
function Get-ParenCallForm { return @((Get-WrappedList)) }
function Get-TypeNameForm { $items = New-Object -TypeName System.Collections.Generic.List[object]; return @($items) }
function Get-NamedAfterArgumentForm { $items = New-Object -ArgumentList 4 -TypeName System.Collections.Generic.List[object]; return @($items) }
function Get-SafeArgumentListForm { $builder = New-Object System.Text.StringBuilder -ArgumentList 'System.Collections.Generic.List[object]'; return @($builder) }
function Get-ObjectTypedTarget { [object]$items = New-Object System.Collections.Generic.List[object]; return @($items) }
function Get-PsObjectTypedTarget { [psobject]$items = New-Object System.Collections.Generic.List[object]; return @($items) }
function Get-SafeArrayTypedTarget { [object[]]$items = New-Object System.Collections.Generic.List[object]; return @($items) }
function Get-SafeListTypedTarget { [System.Collections.Generic.List[object]]$items = New-Object System.Collections.Generic.List[object]; return @($items) }
function Get-QualifiedNewObjectForm { $items = Microsoft.PowerShell.Utility\New-Object System.Collections.Generic.List[object]; return @($items) }
function Get-SafeQualifiedPsObjectList { $items = Microsoft.PowerShell.Utility\New-Object System.Collections.Generic.List[psobject]; return @($items) }
function Get-IfValueForm($Existing) { $items = if ($null -ne $Existing) { $Existing } else { New-Object System.Collections.Generic.List[object] }; return @($items) }
function Get-TryValueForm { $items = try { New-Object System.Collections.Generic.List[object] } catch { $null }; return @($items) }
function Get-SwitchValueForm { $items = switch ('a') { 'a' { New-Object System.Collections.Generic.List[object] } }; return @($items) }
function Get-SafeIfEnumeratedForm { $source = New-Object System.Collections.Generic.List[object]; $items = if ($true) { $source } else { $null }; return @($items) }
function Get-SafeIfToArrayForm { $items = if ($true) { (New-Object System.Collections.Generic.List[object]).ToArray() } else { @() }; return @($items) }
function Get-KeyLiteralIndexForm { $state = @{ Waiting = (New-Object System.Collections.Generic.List[object]) }; return @($state['Waiting']) }
function Get-IndexKeyMemberForm { $state = @{}; $state['Held'] = New-Object System.Collections.Generic.List[object]; return @($state.Held) }
function Get-MemberTargetIndexForm { $script:BinderGateState = @{ ByKey = @{} }; $script:BinderGateState.ByKey['k'] = New-Object System.Collections.Generic.List[object]; return @($script:BinderGateState.ByKey['k']) }
function Get-MemberTargetDynamicForm($Key = 'k') { $script:BinderGateQueue = @{ ByName = @{} }; $script:BinderGateQueue.ByName[$Key] = New-Object System.Collections.Generic.List[object]; return @($script:BinderGateQueue.ByName[$Key]) }
function Get-SafeIndexCountForm { $state = @{}; $state['Held'] = New-Object System.Collections.Generic.List[object]; return @($state.Count) }
function Get-SafeMemberTargetKeysForm { $script:BinderGateState = @{ ByKey = @{} }; $script:BinderGateState.ByKey['k'] = New-Object System.Collections.Generic.List[object]; return @($script:BinderGateState.ByKey.Keys) }
function Get-ParenCommaList { $items = New-Object System.Collections.Generic.List[object]; return (,$items) }
function Get-ParenCommaForm { $result = Get-ParenCommaList; return @($result) }
function Get-SafeParenCommaAssigned { $items = New-Object System.Collections.Generic.List[object]; $pair = (,$items); return @($pair) }
function Get-SubExpressionForm { $items = $(New-Object System.Collections.Generic.List[object]); return @($items) }
function Show-SubExpressionArgument($Items) { return @($Items) }
function Invoke-SubExpressionArgument { Show-SubExpressionArgument -Items $(New-Object System.Collections.Generic.List[object]) }
function Get-SafeSubExpressionForm { $source = New-Object System.Collections.Generic.List[object]; $items = $($source); return @($items) }
function Get-WrappedVariableList { $items = New-Object System.Collections.Generic.List[object]; $wrapper = ,$items; return $wrapper }
function Get-WrappedVariableForm { $result = Get-WrappedVariableList; return @($result) }
function Get-SafeWrappedVariable { $items = New-Object System.Collections.Generic.List[object]; $wrapper = ,$items; return @($wrapper) }
function Get-MapLiteralIndexForm { $map = @{ key = (New-Object System.Collections.Generic.List[object]) }; return @($map['key']) }
function Show-SplatSink($Payload) { return @($Payload) }
function Invoke-SplatLiteral { $splat = @{ Payload = New-Object System.Collections.Generic.List[object] }; Show-SplatSink @splat }
function Show-SplatStoredSink($Cargo) { return @($Cargo) }
function Invoke-SplatStored { $splat = @{}; $splat['Cargo'] = New-Object System.Collections.Generic.List[object]; Show-SplatStoredSink @splat }
function Show-SafeSplatSink([object[]]$Freight) { return @($Freight) }
function Invoke-SafeSplat { $splat = @{ Freight = New-Object System.Collections.Generic.List[object] }; Show-SafeSplatSink @splat }
function Show-PipelineSink { param([Parameter(ValueFromPipeline = $true)]$Items) process { return @($Items) } }
function Invoke-PipelineSink { New-Object System.Collections.Generic.List[object] | Show-PipelineSink }
function Show-PipelineCommaSink { param([Parameter(ValueFromPipeline)]$Items) process { return @($Items) } }
function Invoke-PipelineCommaSink { $items = New-Object System.Collections.Generic.List[object]; ,$items | Show-PipelineCommaSink }
function Show-SafePipelineSink { param([Parameter(ValueFromPipeline = $true)]$Items) process { return @($Items) } }
function Invoke-SafePipelineSink { $items = New-Object System.Collections.Generic.List[object]; $items | Show-SafePipelineSink }
function Show-AliasTargetSink($Items) { return @($Items) }
Set-Alias -Name Show-AliasedList -Value Show-AliasTargetSink
function Invoke-AliasedList { $items = New-Object System.Collections.Generic.List[object]; Show-AliasedList -Items $items }
function Show-SafeAliasTargetSink([object[]]$Items) { return @($Items) }
New-Alias Show-SafeAliasedList Show-SafeAliasTargetSink
function Invoke-SafeAliasedList { $items = New-Object System.Collections.Generic.List[object]; Show-SafeAliasedList -Items $items }
function Get-SafeGlobalDistinctForm { $script:BinderGateSplit = New-Object System.Collections.Generic.List[object]; $global:BinderGateSplit = @(); return @($global:BinderGateSplit) }
function Get-GlobalQualifiedForm { $global:BinderGateJoined = New-Object System.Collections.Generic.List[object]; return @($global:BinderGateJoined) }
function Get-SharedOutput { return 'safe' }
function Get-SafeSharedOutputForm { $result = Get-SharedOutput; return @($result) }
function Get-DotSourcedOutputForm { $result = Get-DotSourcedOutput; return @($result) }
function Get-ChainedAssignmentForm { $outer = $inner = New-Object System.Collections.Generic.List[object]; return @($outer) }
function Get-SafeChainedTypedForm { $outer = [object[]]$inner = New-Object System.Collections.Generic.List[object]; return @($outer) }
function Get-NoEnumerateList { $items = New-Object System.Collections.Generic.List[object]; Write-Output -NoEnumerate $items }
function Get-NoEnumerateForm { $result = Get-NoEnumerateList; return @($result) }
function Get-PlainWriteOutputList { $items = New-Object System.Collections.Generic.List[object]; Write-Output $items }
function Get-SafePlainWriteOutputForm { $result = Get-PlainWriteOutputList; return @($result) }
function Get-WrapperIndexForm { $items = New-Object System.Collections.Generic.List[object]; $wrapper = ,$items; return @($wrapper[0]) }
function Get-SafeWrapperCountForm { $items = New-Object System.Collections.Generic.List[object]; $wrapper = ,$items; return @($wrapper.Count) }
function Invoke-ConditionalShadowWrapper { $items = New-Object System.Collections.Generic.List[object]; function Get-ConditionalShadowForm { if ($false) { $items = @() }; return @($items) }; Get-ConditionalShadowForm }
function Invoke-StraightShadowWrapper { $items = New-Object System.Collections.Generic.List[object]; function Get-StraightShadowForm { $items = @(); return @($items) }; Get-StraightShadowForm }
function Get-MultiOutputList { $items = New-Object System.Collections.Generic.List[object]; ,$items; 'tail' }
function Get-SafeMultiOutputForm { $result = Get-MultiOutputList; return @($result) }
function Get-MultiOutputIndexForm { $result = Get-MultiOutputList; return @($result[0]) }
function Get-MultiOutputBranchList([bool]$Early = $true) { $items = New-Object System.Collections.Generic.List[object]; if ($Early) { return ,$items }; ,$items; 'tail' }
function Get-MultiOutputBranchForm { $result = Get-MultiOutputBranchList; return @($result) }
function Show-MultiOutputStreamSink { param([Parameter(ValueFromPipeline = $true)]$Entry) process { return @($Entry) } }; function Invoke-MultiOutputStream { Get-MultiOutputList | Show-MultiOutputStreamSink }
function Get-MultiOutputRewrapList { $result = Get-MultiOutputList; return $result }; function Show-MultiOutputRewrapSink { param([Parameter(ValueFromPipeline = $true)]$Entry) process { return @($Entry) } }; function Invoke-MultiOutputRewrap { Get-MultiOutputRewrapList | Show-MultiOutputRewrapSink }
function Get-MultiOutputParenList { return (Get-MultiOutputList) }; function Show-MultiOutputParenSink { param([Parameter(ValueFromPipeline = $true)]$Entry) process { return @($Entry) } }; function Invoke-MultiOutputParen { Get-MultiOutputParenList | Show-MultiOutputParenSink }
function Get-MultiOutputRedirectedList { $items = New-Object System.Collections.Generic.List[object]; ,$items; 'tail' > $null }
function Get-MultiOutputRedirectedForm { $result = Get-MultiOutputRedirectedList; return @($result) }
function Get-SafeFlowOrderForm { $items = @(); $copy = $items; $items = New-Object System.Collections.Generic.List[object]; return @($copy) }
function Get-FlowOrderLoopForm { $items = @(); foreach ($round in 1..2) { $copy = $items; $items = New-Object System.Collections.Generic.List[object] }; return @($copy) }
function Get-FlowOrderTwiceForm { $items = New-Object System.Collections.Generic.List[object]; $copy = $items; $items = New-Object System.Collections.Generic.List[object]; return @($copy) }
function Get-FlowOrderOuterForm { $items = Get-NoEnumerateList; function Get-FlowOrderInnerForm { $copy = $items; $items = New-Object System.Collections.Generic.List[object]; return @($copy) }; Get-FlowOrderInnerForm }
function Show-FlowOrderParamForm($Items) { $copy = $Items; $Items = New-Object System.Collections.Generic.List[object]; return @($copy) }; function Invoke-FlowOrderParam { $list = New-Object System.Collections.Generic.List[object]; Show-FlowOrderParamForm $list }
'@
    $binderGateFixtureFindings = Find-BRAVOObjectListArraySubexpression -Source @(
        [pscustomobject]@{ Name = 'fixture'; Text = $binderGateFixture },
        [pscustomobject]@{ Name = 'fixture-global'; Text = '$global:BinderGateShared = New-Object System.Collections.Generic.List[object]' },
        [pscustomobject]@{ Name = 'fixture-typed'; Text = 'function Show-SharedName([object[]]$Items) { return @($Items) }' },
        [pscustomobject]@{ Name = 'fixture-output'; Text = ('function Get-SharedOutput { $items = New-Object System.Collections.Generic.List[object]; return ,$items }' + "`n" +
                'function Get-DotSourcedOutput { $items = New-Object System.Collections.Generic.List[object]; return ,$items }') })
    # Знахідки поза основною фікстурою (fixture-global, fixture-typed,
    # fixture-output) — хибні спрацювання: ці файли безпечні самі по собі.
    $binderGateFixtureLines = @($binderGateFixtureFindings | ForEach-Object {
            $findingParts = $_ -split ':'
            if ($findingParts[0] -eq 'fixture') { [string][int]$findingParts[1] } else { $findingParts[0] + ':' + $findingParts[1] }
        } | Sort-Object { if ($_ -match '^\d+$') { [int]$_ } else { [int]::MaxValue } })
    Test-BRAVOCondition `
        -Condition (($binderGateFixtureLines -join ',') -eq '2,3,4,5,8,14,15,18,19,20,21,22,27,28,29,32,36,39,40,41,43,45,47,51,52,55,61,68,70,73,74,75,77,78,81,83,84,85,88,89,90,91,95,97,98,102,104,105,107,111,113,117,124,127,128,131,134,136,140,142,143,144,145,147,149,150,151,152') `
        -Name "Governance/GenericObjectListBinderGuardIsMeaningful" `
        -Failure ("detector binder-гейту має знаходити рівно рядки 2,3,4,5,8,14,15,18,19,20,21,22,27,28,29,32,36,39,40,41,43,45,47,51,52,55,61,68,70,73,74,75,77,78,81,83,84,85,88,89,90,91,95,97,98,102,104,105,107,111,113,117,124,127,128,131,134,136,140,142,143,144,145,147,149,150,151,152 синтетичної фікстури (14-19 — форми всередині обгортки Invoke-BRAVO<X> після T010; 20-22 — список у властивості й елементі словника; 27-43 — форми з review PR #259; 45-81 — класи потокової моделі з другого раунду review; 83-102 — значення операторів, ключі, (,`$x), `$( ) і W-змінна; 104-127 — третій раунд: splat, конвеєр, аліаси команд, `$script: проти `$global:, вихід за визначенням; 128-137 — четвертий раунд: ланцюгове присвоєння, Write-Output -NoEnumerate, `$w[0], затінення лише домінуючим присвоєнням; 138-152 — кардинальність виходу і порядок виконання) " +
            "(небезпечні форми) і не знаходити безпечні; фактично: " +
            $(if ($binderGateFixtureFindings.Count -gt 0) { $binderGateFixtureFindings -join '; ' } else { '<нічого>' }))

    # --- Governance/GenericObjectListBinderPremisesHold ---
    # Рантайм-передумови моделі на цьому хості (у Windows CI — PS 5.1): що
    # детектор вважає небезпечним — справді кидає ArgumentException, що
    # безпечним — ні. Код — рядки, тож сам guard їх як live-входження не
    # бачить; функції живуть лише в дочірньому scope проби. Кожна проба
    # самодостатня під Set-StrictMode -Version Latest, а будь-який інший
    # виняток — названий провал саме цієї проби, а не Fatal усього прогону.
    $binderGatePremises = @(
        @{ Throws = $true; Code = '$l = New-Object System.Collections.Generic.List[object]; @($l)' },
        @{ Throws = $true; Code = '$l = Microsoft.PowerShell.Utility\New-Object -ArgumentList 4 -TypeName System.Collections.Generic.List[object]; @($l)' },
        @{ Throws = $true; Code = '[psobject]$l = New-Object System.Collections.Generic.List[object]; @($l)' },
        @{ Throws = $true; Code = '$h = @{}; $h.P = New-Object System.Collections.Generic.List[object]; $l = $h.P; @($l)' },
        @{ Throws = $true; Code = 'function Get-L { $l = New-Object System.Collections.Generic.List[object]; ,$l }; function Get-P { Get-L }; $l = Get-P; @($l)' },
        @{ Throws = $true; Code = 'function Show-L { param([Alias(''Value'')]$Items) @($Items) }; function Send-L($Relay) { Show-L -Value $Relay }; Send-L -Relay (New-Object System.Collections.Generic.List[object])' },
        @{ Throws = $false; Code = '$l = [System.Collections.Generic.List[object]]::new(); @($l)' },
        @{ Throws = $false; Code = '[object[]]$l = New-Object System.Collections.Generic.List[object]; @($l)' },
        @{ Throws = $false; Code = '$l = New-Object System.Text.StringBuilder -ArgumentList ''System.Collections.Generic.List[object]''; @($l)' },
        @{ Throws = $false; Code = 'function Get-L { $l = New-Object System.Collections.Generic.List[object]; $x = ,$l; return ''safe'' }; $l = Get-L; @($l)' },
        @{ Throws = $false; Code = 'function Get-L { $l = New-Object System.Collections.Generic.List[object]; ,$l }; function Get-P { return (Get-L) }; $l = Get-P; @($l)' },
        @{ Throws = $false; Code = '$l = New-Object System.Collections.Generic.List[psobject]; @($l)' },
        @{ Throws = $true; Code = '$l = if ($true) { New-Object System.Collections.Generic.List[object] }; @($l)' },
        @{ Throws = $false; Code = '$s = New-Object System.Collections.Generic.List[object]; $l = if ($true) { $s }; @($l)' },
        @{ Throws = $true; Code = '$h = @{}; $h[''K''] = New-Object System.Collections.Generic.List[object]; @($h.K)' },
        @{ Throws = $true; Code = 'function Get-L { $l = New-Object System.Collections.Generic.List[object]; return (,$l) }; $l = Get-L; @($l)' },
        @{ Throws = $true; Code = 'function Get-L { $l = New-Object System.Collections.Generic.List[object]; $w = ,$l; return $w }; $l = Get-L; @($l)' },
        @{ Throws = $false; Code = '$s = New-Object System.Collections.Generic.List[object]; $l = (,$s); @($l)' },
        @{ Throws = $true; Code = 'function Show-L($Items) { @($Items) }; $p = @{ Items = New-Object System.Collections.Generic.List[object] }; Show-L @p' },
        @{ Throws = $true; Code = 'function Show-L { param([Parameter(ValueFromPipeline = $true)]$Items) process { @($Items) } }; New-Object System.Collections.Generic.List[object] | Show-L' },
        @{ Throws = $false; Code = 'function Show-L { param([Parameter(ValueFromPipeline = $true)]$Items) process { @($Items) } }; $s = New-Object System.Collections.Generic.List[object]; $s.Add(1); $s | Show-L' },
        @{ Throws = $true; Code = 'function Show-L($Items) { @($Items) }; Set-Alias -Name Show-A -Value Show-L; Show-A -Items (New-Object System.Collections.Generic.List[object])' },
        @{ Throws = $false; Code = '$script:BinderGatePremise = New-Object System.Collections.Generic.List[object]; $global:BinderGatePremise = @(); @($global:BinderGatePremise); Remove-Variable -Name BinderGatePremise -Scope Global' },
        @{ Throws = $true; Code = '$outer = $inner = New-Object System.Collections.Generic.List[object]; @($outer)' },
        @{ Throws = $false; Code = '$outer = [object[]]$inner = New-Object System.Collections.Generic.List[object]; @($outer)' },
        @{ Throws = $true; Code = 'function Get-L { $l = New-Object System.Collections.Generic.List[object]; Write-Output -NoEnumerate $l }; $l = Get-L; @($l)' },
        @{ Throws = $false; Code = 'function Get-L { $l = New-Object System.Collections.Generic.List[object]; Write-Output $l }; $l = Get-L; @($l)' },
        @{ Throws = $true; Code = '$s = New-Object System.Collections.Generic.List[object]; $w = ,$s; @($w[0])' },
        @{ Throws = $true; Code = 'function Get-O { $items = New-Object System.Collections.Generic.List[object]; function Get-I { if ($false) { $items = @() }; @($items) }; Get-I }; Get-O' },
        @{ Throws = $false; Code = 'function Get-O { $items = New-Object System.Collections.Generic.List[object]; function Get-I { $items = @(); @($items) }; Get-I }; Get-O' },
        @{ Throws = $false; Code = 'function Get-L { $l = New-Object System.Collections.Generic.List[object]; ,$l; ''tail'' }; $v = Get-L; @($v)' },
        @{ Throws = $true; Code = 'function Get-L { $l = New-Object System.Collections.Generic.List[object]; ,$l; ''tail'' }; $v = Get-L; @($v[0])' },
        @{ Throws = $true; Code = 'function Get-L { $l = New-Object System.Collections.Generic.List[object]; ,$l; ''tail'' }; function Show-L { param([Parameter(ValueFromPipeline = $true)]$Items) process { @($Items) } }; Get-L | Show-L' },
        @{ Throws = $true; Code = 'function Get-L { $l = New-Object System.Collections.Generic.List[object]; ,$l; ''tail'' > $null }; $v = Get-L; @($v)' },
        @{ Throws = $false; Code = '$items = @(); $copy = $items; $items = New-Object System.Collections.Generic.List[object]; @($copy)' },
        @{ Throws = $true; Code = '$items = @(); foreach ($r in 1..2) { $copy = $items; $items = New-Object System.Collections.Generic.List[object] }; @($copy)' },
        @{ Throws = $true; Code = '$outer = $inner = New-Object System.Collections.Generic.List[object]; @($inner)' })
    $binderGatePremiseMismatches = @(foreach ($binderGatePremise in $binderGatePremises) {
            $binderGatePremiseOutcome = 'не кидає'
            try { $null = & ([scriptblock]::Create('Set-StrictMode -Version Latest; ' + $binderGatePremise.Code)) } catch {
                # ArgumentException може прийти загорнутою: шукаємо по ланцюгу InnerException.
                $binderGatePremiseOutcome = $_.Exception.GetType().FullName
                $binderGatePremiseException = $_.Exception
                while ($null -ne $binderGatePremiseException) {
                    if ($binderGatePremiseException -is [System.ArgumentException]) { $binderGatePremiseOutcome = 'System.ArgumentException'; break }
                    $binderGatePremiseException = $binderGatePremiseException.InnerException
                }
            }
            if (($binderGatePremiseOutcome -eq 'System.ArgumentException') -ne $binderGatePremise.Throws) { $binderGatePremise.Code + ' => ' + $binderGatePremiseOutcome }
        })
    Test-BRAVOCondition `
        -Condition ($binderGatePremiseMismatches.Count -eq 0) `
        -Name "Governance/GenericObjectListBinderPremisesHold" `
        -Failure ("рантайм не збігається з моделлю детектора binder-гейту (джерела, перенос, безпечні форми): " + ($binderGatePremiseMismatches -join '; '))
}
