# Канонічна реалізація двох gate-перевірок Config V2 cutover (Issue #216):
# LEGACY_CONFIG_REMOVED (BRAVO.config відсутній у комплекті) і
# LEGACY_CONFIG_AUTOEXEC (кожен production/operator entrypoint блокує
# auto-detect BRAVO.config через -DisallowLegacyPrimaryAutoDetect).
#
# Призначений для dot-source, не для прямого запуску — так само, як
# BRAVO_CONFIG_LOADER.ps1 dot-source'иться entrypoint-ами. Два споживачі:
#   1. ci\New-BRAVOReleaseArtifact.ps1 — на staged-комплекті (після git
#      archive), лише при tag/workflow_dispatch.
#   2. .github\workflows\config-parity.yml (PR-рівня job, issue #216 H-1) —
#      напряму на checked-out repo tree, без повної збірки артефакту:
#      обидва гейти — чисто текстові перевірки, staging-каталог їм не
#      потрібен, потрібен лише корінь, де лежать перелічені нижче файли.
#
# R2 (issue #216, §9 п.3/п.4): попередня перевірка AUTOEXEC регексом
# `-notmatch '(?s)Import-BravoConfiguration.{0,400}?-DisallowLegacyPrimaryAutoDetect'`
# перевіряла лише ТЕКСТОВУ присутність назви прапорця — явний
# `-DisallowLegacyPrimaryAutoDetect:$false` (чи `:0`) проходив би так само,
# як бекар прапорця, хоча ефективно вимикає блокування auto-detect. Нижче —
# фікс: перевіряється, що явна прив'язка (якщо вона є) не встановлює
# протилежне значення.
#
# Issue #154 (B7): поруч — окремий гейт CONFIG_LOADER_CALLER_COMPLETENESS
# (Test-BRAVOConfigLoaderCallerCompleteness): AST-доказ, що фіксований
# перелік AUTOEXEC-цілей не пропускає жодного реального викликача
# Import-BravoConfiguration серед кореневих *.ps1 і modules\.

function Get-BRAVOProductionEntryPointRelativePath {
    <#
        Канонічний перелік production/operator entrypoint-ів (Issue #216),
        які МУСЯТЬ викликати Import-BravoConfiguration
        -DisallowLegacyPrimaryAutoDetect. Єдине попереднє джерело —
        ci\New-BRAVOReleaseArtifact.ps1 ($productionEntryPointGuardTargets);
        інші файли, що згадують підмножину цих імен (ConfigIntent/
        ManualLaunchers selftest-и), перевіряють НАВМИСНО іншу, вужчу
        поведінку (порядок захвату наміру, forwarding конкретних splat-ів)
        і не є дублікатами цього переліку.
    #>
    return @(
        'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1',
        'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1',
        'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1',
        'modules\BRAVO.DataRestore\BRAVO.DataRestore.Runtime.ps1',
        'BRAVO_SETUP.ps1',
        'BRAVO_CREDENTIALS_SETUP.ps1',
        'BRAVO_CONFIG_TEST.ps1',
        'BRAVO_BAZA_RECONCILE.ps1',
        'BRAVO_DRY_RUN.ps1',
        'BRAVO_NOTIFICATION_TEST.ps1',
        'BRAVO_RESTORE_TEST.ps1',
        'BRAVO_TASKS_DIAGNOSE.ps1',
        'BRAVO_TASKS_INSTALL.ps1',
        'BRAVO_TASKS_UNINSTALL.ps1',
        # Issue #154 (B7): операторський heartbeat (PR #225) з'явився ПІСЛЯ
        # формування цього переліку й до B7 викликав Import-BravoConfiguration
        # без прапорця — auto-derived BRAVO.config поруч виконувався як
        # primary-шар. Щоб наступний новий entrypoint не випав так само,
        # перелік тепер звіряється з фактичними викликачами AST-інваріантом
        # повноти (Test-BRAVOConfigLoaderCallerCompleteness нижче).
        'BRAVO_OPERATIONS_HEARTBEAT.ps1'
    )
}

function Get-BRAVOConfigLoaderSanctionedNonProductionCallerRelativePath {
    <#
        Issue #154 (B7): ЄДИНИЙ файл у межах сканування інваріанта повноти
        (кореневі *.ps1 і modules\), якому дозволено викликати
        Import-BravoConfiguration поза переліком
        Get-BRAVOProductionEntryPointRelativePath. BRAVO_SELF_TEST.ps1 — не
        production-entrypoint, а тестовий harness: він НАВМИСНО викликає
        loader і з прапорцем, і без нього (контрольні прогони Proof B /
        PostUpdateStaleConfig доводять, що без прапорця файл справді
        читається). Migration/deploy-інструменти (deploy\*,
        BRAVO_CONFIG_INTEGRATE.ps1) сюди не потрапляють: deploy\ поза
        обсягом сканування, а BRAVO_CONFIG_INTEGRATE.ps1 містить ім'я
        функції лише в рядкових літералах (AST-виклику немає).
    #>
    return @(
        'BRAVO_SELF_TEST.ps1'
    )
}

function Get-BRAVOConfigLoaderCallerRelativePath {
    <#
        Issue #154 (B7): AST-перелік файлів, що РЕАЛЬНО викликають
        Import-BravoConfiguration (CommandAst.GetCommandName(), без
        урахування регістру) — серед усіх кореневих *.ps1 і всіх
        *.ps1/*.psm1 під modules\. Коментар, рядковий літерал чи
        here-string з тим самим текстом викликом не є (на відміну від
        текстового пошуку). Непрямий виклик (`& $name`, аліас, обчислене
        ім'я) статичний AST не бачить — той самий свідомий межовий
        випадок, що й у гейті LEGACY_READER_ISOLATION (#239).

        Кожен AST-виклик додатково класифікується: FlaglessCall — виклик,
        який НЕ прив'язує -DisallowLegacyPrimaryAutoDetect (відсутній або
        явно :$false/:0), або splat-виклик, прапорець якого статично не
        довести (fail closed). Формат елемента — '<відносний шлях>:<рядок>'.

        Повертає [pscustomobject]@{ CallerRelativePath; FlaglessCall; ParseFailures }:
        відносні шляхи нормалізовано до '\'-роздільника (форма переліку
        Get-BRAVOProductionEntryPointRelativePath незалежно від ОС
        прогону). Файл, який парсер не розібрав, НЕ пропускається мовчки —
        він потрапляє в ParseFailures (fail closed у викликача).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )

    $resolvedRoot = (Get-Item -LiteralPath $Root).FullName
    $candidateFiles = New-Object System.Collections.Generic.List[object]
    foreach ($rootScript in @(Get-ChildItem -LiteralPath $resolvedRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.ps1' })) {
        [void]$candidateFiles.Add($rootScript)
    }
    $modulesPath = Join-Path $resolvedRoot 'modules'
    if (Test-Path -LiteralPath $modulesPath -PathType Container) {
        # `-Include` разом із `-LiteralPath` на Windows PowerShell 5.1
        # ненадійний — розширення фільтруються вручну (той самий прийом,
        # що в гейті LEGACY_READER_ISOLATION).
        foreach ($moduleScript in @(Get-ChildItem -LiteralPath $modulesPath -Recurse -File |
                Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' })) {
            [void]$candidateFiles.Add($moduleScript)
        }
    }

    $callers = New-Object System.Collections.Generic.List[string]
    $flaglessCalls = New-Object System.Collections.Generic.List[string]
    $parseFailures = New-Object System.Collections.Generic.List[string]
    foreach ($candidateFile in $candidateFiles) {
        $relativePath = $candidateFile.FullName.Substring($resolvedRoot.Length).TrimStart('\', '/').Replace('/', '\')
        $candidateText = [IO.File]::ReadAllText($candidateFile.FullName, [Text.Encoding]::UTF8)
        $candidateParseErrors = $null
        $candidateAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $candidateText, [ref]$null, [ref]$candidateParseErrors
        )
        if ($candidateParseErrors -and $candidateParseErrors.Count -gt 0) {
            [void]$parseFailures.Add("$relativePath ($($candidateParseErrors[0].Message))")
            continue
        }
        $loaderCalls = @($candidateAst.FindAll({
                    param($astNode)
                    ($astNode -is [System.Management.Automation.Language.CommandAst]) -and
                    [string]::Equals([string]$astNode.GetCommandName(), 'Import-BravoConfiguration', [StringComparison]::OrdinalIgnoreCase)
                }, $true))
        if ($loaderCalls.Count -gt 0) {
            [void]$callers.Add($relativePath)
        }
        foreach ($loaderCall in $loaderCalls) {
            $flagBound = $false
            foreach ($callElement in @($loaderCall.CommandElements)) {
                if ($callElement -is [System.Management.Automation.Language.CommandParameterAst] -and
                    [string]::Equals($callElement.ParameterName, 'DisallowLegacyPrimaryAutoDetect', [StringComparison]::OrdinalIgnoreCase)) {
                    $flagArgumentText = if ($null -ne $callElement.Argument) { [string]$callElement.Argument.Extent.Text } else { '' }
                    $flagBound = -not ($flagArgumentText -match '^\$?(false|0)$')
                }
            }
            # Splat без явного прапорця статично не довести — fail closed;
            # явний прапорець поруч зі splat однозначний (дубль параметра
            # у splat — помилка прив'язки, а не тихе :$false).
            if (-not $flagBound) {
                [void]$flaglessCalls.Add($relativePath + ':' + $loaderCall.Extent.StartLineNumber)
            }
        }
    }

    return [pscustomobject]@{
        CallerRelativePath = @($callers.ToArray())
        FlaglessCall       = @($flaglessCalls.ToArray())
        ParseFailures      = @($parseFailures.ToArray())
    }
}

function Test-BRAVOConfigLoaderCallerCompleteness {
    <#
        Issue #154 (B7): інваріант повноти для переліку AUTOEXEC-цілей.
        Гейт LEGACY_CONFIG_AUTOEXEC перевіряє лише ФІКСОВАНИЙ перелік —
        новий entrypoint, що викликає Import-BravoConfiguration без
        -DisallowLegacyPrimaryAutoDetect і якого забули внести в перелік,
        гейт не бачить узагалі (саме так BRAVO_OPERATIONS_HEARTBEAT.ps1
        пройшов повз гейт після PR #225). Тут: кожен фактичний AST-викликач
        (Get-BRAVOConfigLoaderCallerRelativePath) мусить бути або в переліку
        AUTOEXEC-цілей, або в явному санкціонованому винятку
        (Get-BRAVOConfigLoaderSanctionedNonProductionCallerRelativePath).

        Окрема функція, а не розширення гейтів AUTOEXEC чи
        LEGACY_READER_ISOLATION: ті гейти лишаються без змін (#239 — не
        додавати до них евристик). Повертає [pscustomobject]@{ Passed;
        Failures; CallerRelativePath } — НЕ кидає виняток.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ProductionEntryPointRelativePath = (Get-BRAVOProductionEntryPointRelativePath),
        [string[]]$SanctionedNonProductionCallerRelativePath = (Get-BRAVOConfigLoaderSanctionedNonProductionCallerRelativePath)
    )

    $failures = New-Object System.Collections.Generic.List[string]
    $knownCallers = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($knownRelativePath in @($ProductionEntryPointRelativePath) + @($SanctionedNonProductionCallerRelativePath)) {
        if (-not [string]::IsNullOrWhiteSpace($knownRelativePath)) {
            [void]$knownCallers.Add($knownRelativePath.Replace('/', '\'))
        }
    }

    $callerScan = Get-BRAVOConfigLoaderCallerRelativePath -Root $Root
    if ($callerScan.ParseFailures.Count -gt 0) {
        [void]$failures.Add(
            'Гейт CONFIG_LOADER_CALLER_COMPLETENESS (issue #154, B7): не вдалося розібрати AST ' + $callerScan.ParseFailures.Count +
            ' файл(ів) — довести, що вони не викликають Import-BravoConfiguration поза переліком, неможливо: ' +
            ([string]::Join(', ', $callerScan.ParseFailures))
        )
    }
    $unlistedCallers = @($callerScan.CallerRelativePath | Where-Object { -not $knownCallers.Contains($_) })
    if ($unlistedCallers.Count -gt 0) {
        [void]$failures.Add(
            'Гейт CONFIG_LOADER_CALLER_COMPLETENESS (issue #154, B7): ' + $unlistedCallers.Count +
            ' файл(и) викликають Import-BravoConfiguration, але відсутні в переліку Get-BRAVOProductionEntryPointRelativePath ' +
            '(ci\BRAVOConfigV2CutoverGates.ps1) — гейт LEGACY_CONFIG_AUTOEXEC їх не перевіряє, і auto-derived BRAVO.config поруч ' +
            'міг би виконуватись без наміру оператора. Внесіть кожен у перелік (і передайте -DisallowLegacyPrimaryAutoDetect) ' +
            'або, для НЕ-production тестового harness-у, у Get-BRAVOConfigLoaderSanctionedNonProductionCallerRelativePath з обґрунтуванням: ' +
            ([string]::Join(', ', $unlistedCallers))
        )
    }

    # Файл у переліку ще не означає, що КОЖЕН його виклик передає прапорець:
    # гейт LEGACY_CONFIG_AUTOEXEC бачить лише перший текстовий збіг. Тут
    # кожен AST-виклик у production-entrypoint (санкціонований тестовий
    # harness навмисно викликає loader і без прапорця) мусить прив'язувати
    # -DisallowLegacyPrimaryAutoDetect.
    $sanctionedCallers = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($sanctionedRelativePath in @($SanctionedNonProductionCallerRelativePath)) {
        if (-not [string]::IsNullOrWhiteSpace($sanctionedRelativePath)) {
            [void]$sanctionedCallers.Add($sanctionedRelativePath.Replace('/', '\'))
        }
    }
    $productionFlaglessCalls = @($callerScan.FlaglessCall | Where-Object {
            -not $sanctionedCallers.Contains($_.Substring(0, $_.LastIndexOf(':')))
        })
    if ($productionFlaglessCalls.Count -gt 0) {
        [void]$failures.Add(
            'Гейт CONFIG_LOADER_CALLER_COMPLETENESS (issue #154, B7): ' + $productionFlaglessCalls.Count +
            ' виклик(и) Import-BravoConfiguration у production-коді не прив''язують -DisallowLegacyPrimaryAutoDetect ' +
            '(відсутній, явно :$false/:0 або splat, який статично не довести) — auto-derived BRAVO.config поруч виконався б: ' +
            ([string]::Join(', ', $productionFlaglessCalls))
        )
    }

    return [pscustomobject]@{
        Passed             = ($failures.Count -eq 0)
        Failures           = @($failures.ToArray())
        CallerRelativePath = @($callerScan.CallerRelativePath)
    }
}

function Test-BRAVOConfigV2CutoverGates {
    <#
        -Root: staging-каталог (release-build) або checked-out repo tree
        (PR-check) — обидва гейти читають лише відносні шляхи нижче.

        Повертає [pscustomobject]@{ Passed; Failures } — НЕ кидає виняток:
        викликач вирішує (release-build — throw на першу невдачу,
        зберігаючи попередній текст повідомлень; PR-job — надрукувати
        ВСІ невдачі одразу й вийти з ненульовим кодом).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ProductionEntryPointRelativePath = (Get-BRAVOProductionEntryPointRelativePath)
    )

    $failures = New-Object System.Collections.Generic.List[string]

    # --- Гейт 1: LEGACY_CONFIG_REMOVED ---
    if (Test-Path -LiteralPath (Join-Path $Root 'BRAVO.config') -PathType Leaf) {
        [void]$failures.Add(
            'Гейт LEGACY_CONFIG_REMOVED (issue #216, B4-2): BRAVO.config неочікувано присутній у комплекті — файл мав бути прибраний з git tracking.'
        )
    }

    # --- Гейт 2: LEGACY_CONFIG_AUTOEXEC ---
    $autoExecMissing = New-Object System.Collections.Generic.List[string]
    foreach ($relativeGuardTarget in $ProductionEntryPointRelativePath) {
        $guardTargetPath = Join-Path $Root $relativeGuardTarget
        if (-not (Test-Path -LiteralPath $guardTargetPath -PathType Leaf)) {
            [void]$failures.Add(
                "Гейт LEGACY_CONFIG_AUTOEXEC (issue #216): production entrypoint '$relativeGuardTarget' відсутній у комплекті."
            )
            continue
        }
        $guardTargetText = Get-Content -LiteralPath $guardTargetPath -Raw -Encoding UTF8
        # R2: спершу знаходимо саму появу прапорця біля Import-BravoConfiguration
        # (та сама межа пошуку — 400 символів), потім окремо перевіряємо, чи
        # прапорець явно прив'язаний до негативного значення ($false/0) —
        # текстова присутність назви прапорця сама по собі більше не
        # достатня для PASS.
        $flagMatch = [regex]::Match(
            $guardTargetText,
            '(?s)Import-BravoConfiguration.{0,400}?-DisallowLegacyPrimaryAutoDetect(\s*:\s*(?<binding>\$?\w+))?'
        )
        $explicitlyDisabled = $flagMatch.Success -and
            $flagMatch.Groups['binding'].Success -and
            $flagMatch.Groups['binding'].Value -match '^\$?(false|0)$'
        if (-not $flagMatch.Success -or $explicitlyDisabled) {
            [void]$autoExecMissing.Add($relativeGuardTarget)
        }
    }
    if ($autoExecMissing.Count -gt 0) {
        [void]$failures.Add(
            'LEGACY_CONFIG_AUTOEXEC (issue #216): у комплекті ' + $autoExecMissing.Count +
            ' production entrypoint(и) викликають Import-BravoConfiguration БЕЗ ефективного -DisallowLegacyPrimaryAutoDetect ' +
            '(прапорець відсутній або явно прив''язаний до $false/0) — довільний BRAVO.config, підкладений поруч без наміру оператора, знову виконувався б автоматично: ' +
            ([string]::Join(', ', $autoExecMissing.ToArray()))
        )
    }

    # --- Гейт 3: LEGACY_READER_ISOLATION (issue #216, Phase 11 п.11) ---
    # Import-BravoConfiguration (BRAVO_CONFIG_LOADER.ps1) сама викликає
    # legacy-рідер лише під -DisallowLegacyPrimaryAutoDetect-guard'ом (гейт 2
    # вище доводить, що guard увімкнено скрізь). Але той guard нічого не
    # каже про файл, який обходить публічну Import-BravoConfiguration і
    # звертається до рідера НАПРЯМУ — тому потрібен окремий гейт: жоден файл
    # під modules\ чи серед кореневих BRAVO_*.ps1-скриптів, окрім самого
    # канонічного визначення, не сміє згадувати ці дві функції. Migration-only
    # інструментарій під deploy\ (deploy\Get-BRAVOConfigSiteDelta.ps1 і т.п.)
    # свідомо поза обсягом цього гейту — Issue #216 Phase 6 санкціонує йому
    # прямий доступ до legacy-шару, і BRAVO_SELF_TEST.Configuration.ps1 вже
    # окремо доводить, що той інструмент читає через канонічний
    # Read-BRAVOLegacyPrimaryRawOverrides, а не власну реалізацію.
    #
    # R3 (issue #216, gate-review): текстовий `.IndexOf` бачить кожну
    # ТЕКСТОВУ появу імені функції — включно з коментарями/help-текстом/
    # рядковими літералами у fixture-даних self-test-ів (сам блоковий
    # allowlist для BRAVO_SELF_TEST.ps1 у попередній версії був прямим
    # доказом цього false-positive класу) — і водночас пропустив би
    # реальний виклик через `& $variable`/aliasing. Замість текстового
    # пошуку розбираємо файл через PowerShell AST і зіставляємо лише
    # СПРАВЖНІ виклики команд (CommandAst.GetCommandName()) — коментар чи
    # рядковий літерал з тим самим текстом більше не породжує FAIL, а
    # окремий file-level allowlist для test-харнесу більше не потрібен.
    $legacyReaderFunctionNames = @(
        'Import-BravoLegacyPrimaryConfiguration',
        'Read-BRAVOLegacyPrimaryRawOverrides'
    )
    # R3 (issue #216, gate-review): ci\New-BRAVOReleaseArtifact.ps1 (коментар
    # біля рядка 200) уже документує канонічний перелік migration/deploy-
    # інструментів, чия ЗАЯВЛЕНА мета — читати РЕАЛЬНИЙ встановлений
    # BRAVO.config/legacy-шар (Issue #216 Phase 6 санкціонує це для
    # deploy\Get-BRAVOConfigSiteDelta.ps1 зокрема). Гейт LEGACY_READER_ISOLATION
    # мусить узгоджено виключати той самий перелік — інакше той самий
    # інструмент, що вже офіційно поза гейтом AUTOEXEC, міг би несподівано
    # провалити ЦЕЙ гейт, щойно виконає свою санкціоновану роботу.
    # R5 (issue #216, gate-review): BRAVO_CONFIG_LOADER.ps1 УМИСНО прибрано
    # з цього повного file-level allowlist — на відміну від migration-
    # інструментів нижче (чия ЗАЯВЛЕНА мета — весь файл читати legacy-шар
    # без guard'у), цей файл — канонічний ВЛАСНИК guard'у: повне
    # виключення ховало б МАЙБУТНІЙ негвардований виклик десь-інде в
    # тому самому файлі. Замість цього файл сканується як усі інші, але
    # звіряється проти точного переліку санкціонованих пар (викликана
    # функція -> функція-викликач) нижче — $legacyReaderSanctionedCallSitePairs.
    $legacyReaderAllowedRelativePaths = @(
        'BRAVO_CONFIG_INTEGRATE.ps1',
        'deploy\Get-BRAVOConfigSiteDelta.ps1',
        'deploy\Compare-BRAVOConfigEffectiveSnapshot.ps1',
        'deploy\Start-BRAVOConfigV2Pilot.ps1',
        'deploy\New-BRAVOConfigV2PilotArtifact.ps1',
        'deploy\BRAVOConfigV2Pilot.Runtime.ps1',
        'deploy\Update-BRAVOServer.ps1'
    )
    # R5: точні два реальні внутрішні виклики в BRAVO_CONFIG_LOADER.ps1 —
    # Import-BravoLegacyPrimaryConfiguration викликає
    # Read-BRAVOLegacyPrimaryRawOverrides (винесення в окрему функцію), і
    # Import-BravoConfiguration викликає Import-BravoLegacyPrimaryConfiguration
    # під $legacyConfigFileExists-guard'ом (гейт 2 вище доводить, що
    # -DisallowLegacyPrimaryAutoDetect увімкнено скрізь). Будь-який ІНШИЙ
    # виклик цих двох функцій — навіть у самому BRAVO_CONFIG_LOADER.ps1 —
    # не санкціонований і мусить провалювати гейт.
    $legacyReaderSanctionedCallSitePairs = @{
        'Read-BRAVOLegacyPrimaryRawOverrides'    = 'Import-BravoLegacyPrimaryConfiguration'
        'Import-BravoLegacyPrimaryConfiguration' = 'Import-BravoConfiguration'
    }

    # R9 (issue #216, gate-review): VariablePath.UserPath включає scope-
    # префікс (`script:`, `global:`, `local:`, `private:`) як частину
    # рядка — `$script:reader` і `$reader`, попри те що PowerShell
    # резолвить друге з батьківського scope до того самого значення,
    # порівнювались як РІЗНІ імена. Знімаємо відомий scope-префікс перед
    # порівнянням.
    function Get-BRAVOAstNormalizedVariableName {
        param([string]$UserPath)
        foreach ($scopePrefix in @('script:', 'global:', 'local:', 'private:', 'using:')) {
            if ($UserPath.StartsWith($scopePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                return $UserPath.Substring($scopePrefix.Length)
            }
        }
        return $UserPath
    }

    function Get-BRAVOAstEnclosingFunctionName {
        param($AstNode)
        $current = $AstNode.Parent
        while ($current) {
            if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                return $current.Name
            }
            $current = $current.Parent
        }
        return $null
    }

    function Get-BRAVOAstEnclosingScriptBlock {
        param($AstNode)
        $current = $AstNode.Parent
        while ($current -and -not ($current -is [System.Management.Automation.Language.ScriptBlockAst])) {
            $current = $current.Parent
        }
        return $current
    }

    # R6 (issue #216, gate-review): PowerShell лексично резолвить змінну
    # НЕ лише в тому самому ScriptBlockAst, а й у ВСІХ охоплюючих (parent)
    # scope — `$reader = '...'` на рівні модуля/скрипта й подальший
    # `& $reader` всередині вкладеної функції реально виконує рідер, хоча
    # це РІЗНІ ScriptBlockAst-об'єкти. Повертаємо весь ланцюжок
    # охоплюючих ScriptBlockAst від найглибшого (сам вузол) до
    # найзовнішнього (корінь файлу), щоб зіставлення могло перевірити
    # кожен рівень.
    function Get-BRAVOAstEnclosingScriptBlockChain {
        param($AstNode)
        $chain = New-Object System.Collections.Generic.List[object]
        $current = Get-BRAVOAstEnclosingScriptBlock -AstNode $AstNode
        while ($current) {
            [void]$chain.Add($current)
            $current = Get-BRAVOAstEnclosingScriptBlock -AstNode $current
        }
        return $chain
    }
    # R2 (issue #216, gate-review): попередня версія обмежувалась modules\ і
    # лише 14 AUTOEXEC-цілями (Get-BRAVOProductionEntryPointRelativePath), що
    # пропускало кореневі тонкі entrypoint-обгортки поза цим списком (напр.
    # BRAVO_ARCHIV.ps1, BRAVO_HEALTH.ps1, BRAVO_MAINTENANCE.ps1,
    # BRAVO_DATA_RESTORE.ps1, BRAVO_CONFIGURATOR.ps1) — усі кореневі
    # BRAVO_*.ps1-скрипти є production/operator-поверхнею репозиторію
    # (архітектурна політика 05-architecture.md), тому скануються всі, не
    # лише підмножина з AUTOEXEC-переліку.
    # R3 (issue #216, gate-review): deploy\ раніше не сканувався ЗОВСІМ —
    # додано, щоб deploy\Install-BRAVOServer.ps1 та інші не-migration
    # скрипти цього каталогу теж підлягали ізоляції.
    $legacyReaderRootEntryScripts = @(Get-ChildItem -LiteralPath $Root -File -Filter 'BRAVO_*.ps1' -ErrorAction SilentlyContinue) |
        ForEach-Object { $_.Name }
    $legacyReaderScanTargets = @('modules', 'deploy') + $ProductionEntryPointRelativePath + $legacyReaderRootEntryScripts
    $legacyReaderViolations = New-Object System.Collections.Generic.List[string]
    $legacyReaderScannedRelativePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $resolvedRootPathItem = Get-Item -LiteralPath $Root
    foreach ($scanTargetRelativePath in $legacyReaderScanTargets) {
        $scanTargetPath = Join-Path $Root $scanTargetRelativePath
        $scanTargetFiles = @()
        if (Test-Path -LiteralPath $scanTargetPath -PathType Container) {
            # R3: `-Include` разом із `-LiteralPath` на Windows PowerShell 5.1
            # ненадійний (відомий gotcha — фільтр мовчки ігнорується), тому
            # розширення відфільтровано вручну після перерахування файлів.
            $scanTargetFiles = @(Get-ChildItem -LiteralPath $scanTargetPath -Recurse -File |
                Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' })
        } elseif (Test-Path -LiteralPath $scanTargetPath -PathType Leaf) {
            $scanTargetFiles = @(Get-Item -LiteralPath $scanTargetPath)
        }
        foreach ($scanTargetFile in $scanTargetFiles) {
            $fileRelativePath = $scanTargetFile.FullName.Substring($resolvedRootPathItem.FullName.Length).TrimStart('\', '/')
            if (-not $legacyReaderScannedRelativePaths.Add($fileRelativePath)) {
                continue
            }
            if ($legacyReaderAllowedRelativePaths -contains $fileRelativePath) {
                continue
            }
            $scanTargetFileText = Get-Content -LiteralPath $scanTargetFile.FullName -Raw -Encoding UTF8
            $legacyReaderParseErrors = $null
            $legacyReaderFileAst = [System.Management.Automation.Language.Parser]::ParseInput(
                $scanTargetFileText, [ref]$null, [ref]$legacyReaderParseErrors
            )
            if ($legacyReaderParseErrors -and $legacyReaderParseErrors.Count -gt 0) {
                # Fail closed: незрозумілий для парсера файл не можна довести
                # безпечним — гейт відмовляє явно, а не мовчки пропускає скан.
                [void]$legacyReaderViolations.Add(
                    "$fileRelativePath (не вдалося розібрати AST для перевірки LEGACY_READER_ISOLATION: $($legacyReaderParseErrors[0].Message))"
                )
                continue
            }
            $legacyReaderIsCanonicalLoaderFile = [string]::Equals(
                $fileRelativePath, 'BRAVO_CONFIG_LOADER.ps1', [StringComparison]::OrdinalIgnoreCase
            )

            # R4 (issue #216, gate-review): найпростіша форма непрямого
            # виклику — `$var = 'Read-BRAVOLegacyPrimaryRawOverrides'; & $var`
            # — CommandAst.GetCommandName() повертає null для команди-змінної,
            # тож нижче окремо збираємо ПРОСТІ прямі присвоєння змінної
            # рядковому літералу з іменем рідера в межах цього ж файлу.
            # R5 (issue #216, gate-review): попередня версія тримала лише
            # плаский HashSet імен змінних на весь файл — reassignment тієї
            # самої змінної на щось безпечне ПІСЛЯ підозрілого присвоєння, чи
            # той самий текстовий варіант імені змінної в ІНШІЙ функції,
            # хибно позначались як FAIL. Тепер для кожного присвоєння
            # запам'ятовуємо охоплюючий ScriptBlockAst і текстовий offset, а
            # для кожного виклику через змінну шукаємо НАЙБЛИЖЧЕ ПОПЕРЕДНЄ
            # (за offset) присвоєння ТІЄЇ Ж змінної в межах ТОГО САМОГО
            # ScriptBlockAst (тобто тієї самої функції чи того самого
            # верхньорівневого скрипта) — це не повна dataflow-аналіза
            # (обчислені/конкатеновані імена, значення з параметра чи іншого
            # файлу — поза межами статичного гейту; таке обфускування
            # статичний CI-лінт принципово не може довести безпечно чи
            # небезпечно без повного виконання), лише порядко- й
            # scope-обізнаний найдешевший практичний випадок.
            $legacyReaderAssignmentRecords = New-Object System.Collections.Generic.List[object]
            $legacyReaderAssignmentAsts = $legacyReaderFileAst.FindAll(
                { param($astNode) $astNode -is [System.Management.Automation.Language.AssignmentStatementAst] },
                $true
            )
            foreach ($legacyReaderAssignmentAst in $legacyReaderAssignmentAsts) {
                $assignmentTarget = $legacyReaderAssignmentAst.Left
                $assignmentValueAst = $legacyReaderAssignmentAst.Right
                if ($assignmentTarget -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
                    continue
                }
                # R8 (issue #216, gate-review): складене присвоєння (`+=` і
                # подібні) НЕ замінює значення змінної — воно доповнює
                # попереднє. Записувати його як "нове" значення (в т.ч. як
                # "безпечне" reassignment) хибно перекрило б реально
                # ризикове попереднє присвоєння. Лише простий `=` трактується
                # як повна заміна; складене присвоєння пропускається зі
                # списку записів, тож попередній простий запис лишається
                # найближчим авторитетним значенням.
                if ($legacyReaderAssignmentAst.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals) {
                    continue
                }
                # R5: записуємо значення КОЖНОГО простого присвоєння рядковому
                # літералу (не лише "ризикових") — інакше reassignment на щось
                # безпечне ПІСЛЯ підозрілого присвоєння не мав би запису, і
                # "найближче попереднє" знову знайшло б застаріле ризикове
                # значення замість актуального.
                # R9 (issue #216, gate-review): попередня версія шукала БУДЬ-
                # ЯКИЙ StringConstantExpressionAst у правій частині рекурсивно
                # через FindAll — це заходило й у ВКЛАДЕНІ scriptblock-и:
                # `$cmd = { 'Read-...' }` записувало ризиковий літерал, хоча
                # `& $cmd` реально виконує СКРИПТБЛОК (що лише повертає текст,
                # не викликає команду). "Проста" форма присвоєння тепер
                # визначена якомога вужче: права частина — це PipelineAst з
                # РІВНО ОДНИМ CommandExpressionAst, чий вираз — САМЕ
                # StringConstantExpressionAst (без розпаковування вкладених
                # scriptblock/підвиразів) — не рекурсивний пошук.
                $assignmentValueLiteralAst = $null
                if ($assignmentValueAst -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $assignmentValueLiteralAst = $assignmentValueAst.Expression -as [System.Management.Automation.Language.StringConstantExpressionAst]
                } elseif ($assignmentValueAst -is [System.Management.Automation.Language.PipelineAst] -and
                    $assignmentValueAst.PipelineElements.Count -eq 1 -and
                    $assignmentValueAst.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $assignmentValueLiteralAst = $assignmentValueAst.PipelineElements[0].Expression -as [System.Management.Automation.Language.StringConstantExpressionAst]
                }
                if (-not $assignmentValueLiteralAst) {
                    continue
                }
                $matchedReaderFunctionName = $null
                foreach ($legacyReaderFunctionName in $legacyReaderFunctionNames) {
                    if ([string]::Equals($assignmentValueLiteralAst.Value, $legacyReaderFunctionName, [StringComparison]::OrdinalIgnoreCase)) {
                        $matchedReaderFunctionName = $legacyReaderFunctionName
                        break
                    }
                }
                [void]$legacyReaderAssignmentRecords.Add([pscustomobject]@{
                    VariableName       = (Get-BRAVOAstNormalizedVariableName -UserPath $assignmentTarget.VariablePath.UserPath)
                    ScriptBlock        = (Get-BRAVOAstEnclosingScriptBlock -AstNode $legacyReaderAssignmentAst)
                    StartOffset        = $legacyReaderAssignmentAst.Extent.StartOffset
                    ReaderFunctionName = $matchedReaderFunctionName
                })
            }

            # R7 (issue #216, gate-review): "той самий callee викликаний із
            # санкціонованого викликача" перевіряє лише ІМ'Я охоплюючої
            # функції, не ідентичність/control-flow конкретного guard'ованого
            # виклику — додатковий, ще не написаний виклик усередині ТІЄЇ Ж
            # санкціонованої функції (напр. поза $legacyConfigFileExists-
            # guard'ом) пройшов би так само непоміченим. Повна перевірка
            # control-flow guard'у статичним AST-гейтом невиправдано складна
            # (довелося б відтворити семантику довільного if/else); натомість
            # — дешева, детерміністична інваріанта: у кожної санкціонованої
            # пари має бути РІВНО ОДИН виклик з відповідного викликача в
            # усьому файлі. Другий (і будь-який подальший) виклик того самого
            # callee з того самого санкціонованого викликача провалює гейт.
            $legacyReaderSanctionedCallSiteHits = New-Object System.Collections.Generic.List[object]

            $legacyReaderCommandAsts = $legacyReaderFileAst.FindAll(
                { param($astNode) $astNode -is [System.Management.Automation.Language.CommandAst] },
                $true
            )
            foreach ($legacyReaderCommandAst in $legacyReaderCommandAsts) {
                $enclosingFunctionName = Get-BRAVOAstEnclosingFunctionName -AstNode $legacyReaderCommandAst
                $invokedCommandName = $legacyReaderCommandAst.GetCommandName()
                if (-not [string]::IsNullOrEmpty($invokedCommandName)) {
                    foreach ($legacyReaderFunctionName in $legacyReaderFunctionNames) {
                        if (-not [string]::Equals($invokedCommandName, $legacyReaderFunctionName, [StringComparison]::OrdinalIgnoreCase)) {
                            continue
                        }
                        if ($legacyReaderIsCanonicalLoaderFile -and
                            $legacyReaderSanctionedCallSitePairs.ContainsKey($legacyReaderFunctionName) -and
                            [string]::Equals($legacyReaderSanctionedCallSitePairs[$legacyReaderFunctionName], $enclosingFunctionName, [StringComparison]::OrdinalIgnoreCase)) {
                            [void]$legacyReaderSanctionedCallSiteHits.Add($legacyReaderFunctionName)
                            continue
                        }
                        [void]$legacyReaderViolations.Add("$fileRelativePath ($legacyReaderFunctionName)")
                    }
                    continue
                }
                $firstCommandElement = $legacyReaderCommandAst.CommandElements | Select-Object -First 1
                if ($firstCommandElement -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
                    continue
                }
                # R6: перевіряємо КОЖЕН рівень охоплюючого scope (від
                # найглибшого до кореня файлу) — лексичний scoping
                # PowerShell резолвить змінну назовні, якщо в поточній
                # функції немає власного присвоєння; перший рівень із
                # найближчим ПОПЕРЕДНІМ присвоєнням (за offset ТОГО САМОГО
                # рівня) вважається джерелом значення — це відтворює
                # звичайне затінення (shadowing), а не повну dataflow.
                # R10 (issue #216, gate-review): R9 знімала scope-префікс з
                # ІМЕНІ змінної для порівняння, але це стирало ЗМІСТ
                # префікса в місці ВИКЛИКУ — явний `& $script:reader`
                # цілеспрямовано звертається ЛИШЕ до script-scope (кореня
                # файлу), навіть якщо вкладена функція має власне
                # незакваліфіковане `$reader` ближче. Тому обхід по scope-
                # ланцюжку тепер звужується залежно від кваліфікатора В
                # МІСЦІ ВИКЛИКУ: незакваліфіковане ім'я — повний ланцюжок
                # (як і раніше); `script:` — лише корінь файлу (найзовнішній
                # рівень ланцюжка); будь-який інший кваліфікатор
                # (`global:`/`local:`/`private:`/drive-qualified) — поза
                # межами цієї статичної евристики, не зіставляється.
                $callScopeChain = @(Get-BRAVOAstEnclosingScriptBlockChain -AstNode $legacyReaderCommandAst)
                $callVariablePath = $firstCommandElement.VariablePath
                if ($callVariablePath.IsScript) {
                    $callScopeLevelsToSearch = @($callScopeChain | Select-Object -Last 1)
                } elseif ($callVariablePath.IsUnqualified) {
                    $callScopeLevelsToSearch = $callScopeChain
                } else {
                    $callScopeLevelsToSearch = @()
                }
                $callOffset = $legacyReaderCommandAst.Extent.StartOffset
                $nearestPrecedingAssignment = $null
                foreach ($callScopeLevel in $callScopeLevelsToSearch) {
                    $nearestPrecedingAssignment = $legacyReaderAssignmentRecords |
                        Where-Object {
                            [string]::Equals($_.VariableName, (Get-BRAVOAstNormalizedVariableName -UserPath $callVariablePath.UserPath), [StringComparison]::OrdinalIgnoreCase) -and
                            [object]::ReferenceEquals($_.ScriptBlock, $callScopeLevel) -and
                            $_.StartOffset -lt $callOffset
                        } |
                        Sort-Object -Property StartOffset -Descending |
                        Select-Object -First 1
                    if ($nearestPrecedingAssignment) {
                        break
                    }
                }
                if (-not $nearestPrecedingAssignment -or -not $nearestPrecedingAssignment.ReaderFunctionName) {
                    continue
                }
                if ($legacyReaderIsCanonicalLoaderFile -and
                    $legacyReaderSanctionedCallSitePairs.ContainsKey($nearestPrecedingAssignment.ReaderFunctionName) -and
                    [string]::Equals($legacyReaderSanctionedCallSitePairs[$nearestPrecedingAssignment.ReaderFunctionName], $enclosingFunctionName, [StringComparison]::OrdinalIgnoreCase)) {
                    [void]$legacyReaderSanctionedCallSiteHits.Add($nearestPrecedingAssignment.ReaderFunctionName)
                    continue
                }
                [void]$legacyReaderViolations.Add("$fileRelativePath (виклик через змінну `$$($firstCommandElement.VariablePath.UserPath), присвоєну імені legacy-рідера)")
            }

            if ($legacyReaderIsCanonicalLoaderFile) {
                $legacyReaderSanctionedCallSiteHits |
                    Group-Object |
                    Where-Object { $_.Count -gt 1 } |
                    ForEach-Object {
                        [void]$legacyReaderViolations.Add(
                            "$fileRelativePath ($($_.Name): знайдено $($_.Count) виклик(ів) із санкціонованого викликача — очікується рівно 1; додатковий виклик поза відомим guard'ом підозрілий)"
                        )
                    }
            }
        }
    }
    if ($legacyReaderViolations.Count -gt 0) {
        [void]$failures.Add(
            'Гейт LEGACY_READER_ISOLATION (issue #216, Phase 11 п.11): ' + $legacyReaderViolations.Count +
            ' звернення(ь) до legacy-рідера поза канонічним визначенням у modules\ чи кореневому BRAVO_*.ps1 — ' +
            'production-код не сміє викликати Import-BravoLegacyPrimaryConfiguration/Read-BRAVOLegacyPrimaryRawOverrides ' +
            'напряму, минаючи guard Import-BravoConfiguration -DisallowLegacyPrimaryAutoDetect: ' +
            ([string]::Join(', ', $legacyReaderViolations.ToArray()))
        )
    }

    # --- Гейт 4: CONFIG_LOADER_CALLER_COMPLETENESS (issue #154, B7) ---
    # Окрема AST-перевірка повноти переліку AUTOEXEC-цілей (гейти 2 і 3
    # вище не змінюються). Той самий -ProductionEntryPointRelativePath, що
    # й гейт 2, — перелік, який перевіряє гейт 2, і перелік, повноту якого
    # доводить гейт 4, завжди один і той самий.
    $callerCompleteness = Test-BRAVOConfigLoaderCallerCompleteness `
        -Root $Root `
        -ProductionEntryPointRelativePath $ProductionEntryPointRelativePath
    foreach ($callerCompletenessFailure in $callerCompleteness.Failures) {
        [void]$failures.Add($callerCompletenessFailure)
    }

    return [pscustomobject]@{
        Passed   = ($failures.Count -eq 0)
        Failures = @($failures.ToArray())
    }
}
