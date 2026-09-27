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
        'BRAVO_TASKS_UNINSTALL.ps1'
    )
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
    # під modules\ чи серед production entrypoint-ів, окрім самого
    # канонічного визначення, не сміє згадувати ці дві функції. Migration-only
    # інструментарій під deploy\ (deploy\Get-BRAVOConfigSiteDelta.ps1 і т.п.)
    # свідомо поза обсягом цього гейту — Issue #216 Phase 6 санкціонує йому
    # прямий доступ до legacy-шару, і BRAVO_SELF_TEST.Configuration.ps1 вже
    # окремо доводить, що той інструмент читає через канонічний
    # Read-BRAVOLegacyPrimaryRawOverrides, а не власну реалізацію.
    $legacyReaderFunctionNames = @(
        'Import-BravoLegacyPrimaryConfiguration',
        'Read-BRAVOLegacyPrimaryRawOverrides'
    )
    $legacyReaderAllowedRelativePaths = @(
        'BRAVO_CONFIG_LOADER.ps1'
    )
    $legacyReaderScanTargets = @('modules') + $ProductionEntryPointRelativePath
    $legacyReaderViolations = New-Object System.Collections.Generic.List[string]
    $legacyReaderScannedRelativePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $resolvedRootPathItem = Get-Item -LiteralPath $Root
    foreach ($scanTargetRelativePath in $legacyReaderScanTargets) {
        $scanTargetPath = Join-Path $Root $scanTargetRelativePath
        $scanTargetFiles = @()
        if (Test-Path -LiteralPath $scanTargetPath -PathType Container) {
            $scanTargetFiles = @(Get-ChildItem -LiteralPath $scanTargetPath -Recurse -File -Include '*.ps1', '*.psm1')
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
            foreach ($legacyReaderFunctionName in $legacyReaderFunctionNames) {
                if ($scanTargetFileText.Contains($legacyReaderFunctionName)) {
                    [void]$legacyReaderViolations.Add("$fileRelativePath ($legacyReaderFunctionName)")
                }
            }
        }
    }
    if ($legacyReaderViolations.Count -gt 0) {
        [void]$failures.Add(
            'Гейт LEGACY_READER_ISOLATION (issue #216, Phase 11 п.11): ' + $legacyReaderViolations.Count +
            ' звернення(ь) до legacy-рідера поза канонічним визначенням у modules\ чи production entrypoint-і — ' +
            'production-код не сміє викликати Import-BravoLegacyPrimaryConfiguration/Read-BRAVOLegacyPrimaryRawOverrides ' +
            'напряму, минаючи guard Import-BravoConfiguration -DisallowLegacyPrimaryAutoDetect: ' +
            ([string]::Join(', ', $legacyReaderViolations.ToArray()))
        )
    }

    return [pscustomobject]@{
        Passed   = ($failures.Count -eq 0)
        Failures = @($failures.ToArray())
    }
}
