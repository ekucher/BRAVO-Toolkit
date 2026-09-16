# Домен-фрагмент self-test: Governance (документація і політики репо):
# Documentation/* (SECURITY.md, THREAT_MODEL.md, RELEASE_CHECKLIST.md,
# RELEASE_POLICY.md, README.md, OPERATIONS.md -- обов'язкові розділи,
# відповідність реалізованим контролям), StaticAnalysis/* (PSScriptAnalyzer
# settings, ci.yml: блокуючі security-правила, ASCII-only run-блоки,
# pinned action SHA), ReleasePolicy/* (CI-гейт гілка/версія/канал).
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

        # GitHub Actions записує вміст `run:` у тимчасовий .ps1 БЕЗ BOM,
        # і Windows PowerShell 5.1 читає його в системній ANSI-кодовій
        # сторінці — кирилиця там декодується в сміття, а окремі байти
        # стають control-символами, що ламають парсер ще до виконання
        # кроку. Реальне падіння CI сталося саме через це. Логіку з
        # кирилицею тримаємо у файлах репозиторію (мають BOM), а `run:`
        # лишається ASCII-only.
        $ciRunBlockLines = @(
            $ciWorkflowText -split '\r?\n' |
                Where-Object { $_ -match '[Ѐ-ӿ]' } |
                Where-Object { $_ -notmatch '^\s*#' } |
                Where-Object { $_ -notmatch '^\s*-?\s*name:' }
        )
        Test-BRAVOCondition `
            -Condition ($ciRunBlockLines.Count -eq 0) `
            -Name "StaticAnalysis/CiRunBlocksAreAsciiOnly" `
            -Failure "ci.yml: виконуваний рядок з кирилицею поза коментарем/name (GitHub Actions пише run: без BOM, PowerShell 5.1 ламається): $($ciRunBlockLines -join ' | ')"
    }

    # Аудит P3: сторонні actions зафіксовані на повний commit SHA, а не
    # на рухомий тег. Тег можна переписати — pin на SHA цього не
    # дозволяє. Версія PSScriptAnalyzer теж зафіксована, інакше нове
    # правило або зміна поведінки ламає CI без жодної зміни коду.
    if (Test-Path -LiteralPath $ciWorkflowPath -PathType Leaf) {
        $unpinnedActions = @(
            [regex]::Matches($ciWorkflowText, 'uses:\s*(?<Ref>[^\r\n]+)') |
                ForEach-Object { $_.Groups['Ref'].Value.Trim() } |
                Where-Object { $_ -notmatch '@[0-9a-f]{40}\b' }
        )
        Test-BRAVOCondition `
            -Condition ($unpinnedActions.Count -eq 0) `
            -Name "StaticAnalysis/ActionsPinnedToCommitSha" `
            -Failure "усі GitHub Actions мають бути зафіксовані на повний commit SHA; не закріплені: $($unpinnedActions -join ', ')"

        Test-BRAVOCondition `
            -Condition ($ciWorkflowText -match 'PSScriptAnalyzer\s+-RequiredVersion\s+\d+\.\d+') `
            -Name "StaticAnalysis/AnalyzerVersionPinned" `
            -Failure "версія PSScriptAnalyzer має бути зафіксована через -RequiredVersion"
    }

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
    Test-BRAVOCondition `
        -Condition (
            (Test-Path -LiteralPath $releasePolicyGatePath -PathType Leaf) -and
            $ciWorkflowTextForPolicy.Contains('ci\Test-BRAVOReleasePolicy.ps1')
        ) `
        -Name "ReleasePolicy/CiGateEnforcesBranchVersionChannel" `
        -Failure "ci\Test-BRAVOReleasePolicy.ps1 має існувати і викликатися з .github\workflows\ci.yml — інакше відповідність гілки, версії та каналу тримається лише на пам'яті людини"

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
                [Parameter(Mandatory = $true)][string]$ReadmeHeader
            )
            $utf8NoBom = New-Object Text.UTF8Encoding($false)
            [IO.File]::WriteAllText((Join-Path $ProbeRoot 'VERSION.json'), '{"packageVersion":"4.5.0","releaseChannel":"stable"}', $utf8NoBom)
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
# перевіряв канал узагалі). Саме так LIMS-TOP тривало працював у production на
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
