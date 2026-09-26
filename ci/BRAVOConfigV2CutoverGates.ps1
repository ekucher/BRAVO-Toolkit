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

    return [pscustomobject]@{
        Passed   = ($failures.Count -eq 0)
        Failures = @($failures.ToArray())
    }
}
