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
