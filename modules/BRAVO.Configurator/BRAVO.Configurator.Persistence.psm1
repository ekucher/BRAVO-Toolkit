# BRAVO.Configurator.Persistence — транзакційний, fail-closed запис
# BRAVO.local.config. Реалізує 15-крокову pipeline
# (docs/design/BRAVO_CONFIGURATOR_DESIGN.md §6). Жодного partial write:
# до atomic replace продакшн-файл гарантовано не змінюється.
#
# Reuse-first: парсинг/валідація candidate йде через canonical
# Read-BRAVOLocalConfigurationOverrides (dot-source BRAVO_CONFIG_LOADER.ps1),
# не через окремий незалежний парсер.

Set-StrictMode -Version 2.0

function Get-BRAVOConfiguratorProductionOverrideState {
    <#
    .SYNOPSIS
        Крок 1-2: читає поточний production BRAVO.local.config (canonical
        parser) і фіксує baseline-хеш (SHA256; $null = файл відсутній).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ProductionConfigDirectory
    )

    $loaderPath = Join-Path $RuntimeRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $loaderPath -PathType Leaf)) {
        throw "BRAVO.Configurator.Persistence: canonical loader не знайдено ('$loaderPath')."
    }
    . $loaderPath

    $overrideRead = Read-BRAVOLocalConfigurationOverrides -ConfigDirectory $ProductionConfigDirectory
    $baselineHash = if ($overrideRead.Present) {
        (Get-FileHash -LiteralPath $overrideRead.Path -Algorithm SHA256).Hash
    } else {
        $null
    }

    return [pscustomobject]@{
        Path       = [string]$overrideRead.Path
        Present    = [bool]$overrideRead.Present
        Overrides  = $overrideRead.Overrides
        BaselineHash = $baselineHash
    }
}

function Merge-BRAVOConfiguratorCandidateOverrides {
    <#
    .SYNOPSIS
        Крок 3: зливає existing production overrides із редагуваннями
        Model-і, зберігаючи будь-який невідомий/newer ключ, якого немає в
        schema-каталозі (§5.1 задачі: preservation невідомих ключів).
    .DESCRIPTION
        Для кожного schema Path: Model.OverridePresent=true -> перезаписує
        значення; Model.OverridePresent=false -> видаляє ключ. Будь-який
        ключ з ExistingOverrides, що НЕ відповідає жодному schema Path,
        лишається незмінним (Model про нього нічого не знає й не міг його
        видалити).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$ExistingOverrides,
        [Parameter(Mandatory = $true)][array]$Model,
        [Parameter(Mandatory = $true)][array]$SchemaCatalog
    )

    $schemaPaths = @($SchemaCatalog | ForEach-Object { [string]$_.Path })
    $merged = @{}
    foreach ($key in $ExistingOverrides.Keys) {
        $merged[$key] = $ExistingOverrides[$key]
    }

    foreach ($path in $schemaPaths) {
        $setting = @($Model | Where-Object { $_.Path -eq $path })
        if ($setting.Count -ne 1) { continue }
        if ($setting[0].OverridePresent) {
            $merged[$path] = $setting[0].OverrideValue
        } elseif ($merged.Contains($path)) {
            $merged.Remove($path)
        }
    }

    return $merged
}

function Test-BRAVOConfiguratorCandidateOverrides {
    <#
    .SYNOPSIS
        Кроки 4-6: парсить candidate (canonical restricted-language
        перевірка), валідує проти schema (крок 5 — жоден раніше невідомий
        Path не додається без дескриптора, крім явно preserved unknown-key
        з продакшена — вони вже пройшли перевірку при попередньому Apply)
        і рахує dependency-findings через реальний canonical loader (крок 6).
    .DESCRIPTION
        Fail-closed: невалідний candidate (parse error, ERROR-рівня
        semantic finding, неканонічний shape) повертає IsValid=$false з
        причиною — виклик Apply не повинен продовжувати до atomic replace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][hashtable]$MergedOverrides,
        [Parameter(Mandatory = $true)][array]$SchemaCatalog
    )

    $reasons = New-Object System.Collections.Generic.List[string]

    # Крок 5: unknown-path guard — лише НОВІ ключі (яких не було в
    # production до цього Apply) мають бути в schema-каталозі; уже
    # застосований legacy/unknown ключ проходить прозоро (§5.1).
    # Дана функція навмисно НЕ відрізняє "новий unknown" від "старий
    # preserved unknown" на цьому рівні — canonical loader (крок 4)
    # усе одно fail-closed на дійсно непридатному шляху (невідомий
    # кореневий $global: або відсутня властивість), тому подвійна
    # перевірка тут була б дублюванням тієї самої canonical політики.

    $isolated = $null
    try {
        $isolated = New-BRAVOConfiguratorIsolatedConfigRoot -RuntimeRoot $RuntimeRoot -CandidateOverrides $MergedOverrides

        # Крок 4: parse + restricted-language (canonical loader сам кине
        # виняток, якщо candidate не data-only hashtable).
        $loaderPath = Join-Path $RuntimeRoot 'BRAVO_CONFIG_LOADER.ps1'
        . $loaderPath
        $parseResult = Read-BRAVOLocalConfigurationOverrides -ConfigDirectory $isolated.IsolatedRoot
        if (-not $parseResult.Present -and $MergedOverrides.Count -gt 0) {
            $reasons.Add('Кандидатний BRAVO.local.config не було записано в isolated root — внутрішня помилка Persistence.')
        }

        # Крок 6-7: dependency + canonical config validation через реальний
        # прогін canonical loader (Effective) + semantic Validation-модуль.
        # ВАЖЛИВО (P1-фікс за результатами незалежного review): Effective
        # МУСИТЬ обчислюватись з ПОВНОГО $MergedOverrides (включно з
        # preserved unknown/legacy ключами), а не з проєкції моделі назад
        # у candidate-hashtable (Update-BRAVOConfiguratorEffective без
        # -CandidateOverridesOverride бере лише schema-відомі Path -
        # ConvertTo-BRAVOConfiguratorOverrideHashtable мовчки відкидає
        # будь-який ключ поза schema). Без цього зламаний/застарілий
        # preserved-ключ міг пройти Apply, не будучи реально прогнаним
        # через canonical Import-BravoConfiguration, і впасти лише пізніше
        # в production entrypoint-і.
        $defaultConfig = Invoke-BRAVOConfiguratorEffectiveComputation -RuntimeRoot $RuntimeRoot -CandidateOverrides @{}
        $model = Get-BRAVOConfiguratorModel -SchemaCatalog $SchemaCatalog -DefaultConfig $defaultConfig -LocalOverrides $MergedOverrides
        $model = Update-BRAVOConfiguratorEffective -Model $model -RuntimeRoot $RuntimeRoot -CandidateOverridesOverride $MergedOverrides
        $validation = Invoke-BRAVOConfiguratorValidation -Model $model
        if ($validation.HasErrors) {
            foreach ($errorFinding in @($validation.Findings | Where-Object { $_.Severity -eq 'ERROR' })) {
                $reasons.Add("[$($errorFinding.Path)] $($errorFinding.Message)")
            }
        }
    } catch {
        $reasons.Add("Canonical loader відхилив candidate: $($_.Exception.Message)")
    } finally {
        if ($null -ne $isolated -and (Test-Path -LiteralPath $isolated.IsolatedRoot)) {
            Remove-Item -LiteralPath $isolated.IsolatedRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]@{
        IsValid = ($reasons.Count -eq 0)
        Reasons = $reasons.ToArray()
    }
}

function ConvertTo-BRAVOConfiguratorLocalConfigText {
    <#
    .SYNOPSIS
        Серіалізує merged overrides у текст BRAVO.local.config (той самий
        data-only hashtable-літерал формат, що canonical loader вимагає).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$MergedOverrides)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Згенеровано BRAVO Configurator. Data-only hashtable "dot-шлях -> значення".')
    $lines.Add('@{')
    foreach ($key in ($MergedOverrides.Keys | Sort-Object)) {
        $literalValue = ConvertTo-BRAVOConfiguratorPowerShellLiteral -Value $MergedOverrides[$key]
        $lines.Add("    '$key' = $literalValue")
    }
    $lines.Add('}')
    return [string]::Join([Environment]::NewLine, $lines)
}

function Invoke-BRAVOConfiguratorApply {
    <#
    .SYNOPSIS
        Повний 15-крокова transactional apply: Load -> baseline hash ->
        candidate -> parse -> schema/dependency validation -> re-check
        baseline (race) -> backup -> atomic replace -> reload -> verify.
    .DESCRIPTION
        Fail-closed на кожному кроці: будь-яка помилка ДО atomic replace
        залишає production BRAVO.local.config незмінним. Race detection
        (крок 10) зупиняє Apply без merge/overwrite, якщо файл змінився
        паралельно між Load і Apply.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ProductionConfigDirectory,
        [Parameter(Mandatory = $true)][array]$Model,
        [Parameter(Mandatory = $true)][array]$SchemaCatalog,
        [Parameter(Mandatory = $true)]$ProductionBaseline   # результат Get-BRAVOConfiguratorProductionOverrideState, зафіксований при Load
    )

    # Крок 3: злиття (Model edits + збереження невідомих ключів).
    $mergedOverrides = Merge-BRAVOConfiguratorCandidateOverrides `
        -ExistingOverrides $ProductionBaseline.Overrides -Model $Model -SchemaCatalog $SchemaCatalog

    # Крок 4-7: parse + schema + dependency + canonical validation.
    $validationResult = Test-BRAVOConfiguratorCandidateOverrides `
        -RuntimeRoot $RuntimeRoot -MergedOverrides $mergedOverrides -SchemaCatalog $SchemaCatalog
    if (-not $validationResult.IsValid) {
        return [pscustomobject]@{
            Applied = $false
            Stage   = 'Validation'
            Reasons = $validationResult.Reasons
        }
    }

    # Кроки 8-9 (BRAVO_CONFIG_TEST / BRAVO_DRY_RUN -SkipCredentials) НЕ є
    # блокуючим gate у цій backend-реалізації — свідоме архітектурне
    # рішення, підтверджене фактичним прогоном, не припущенням:
    #   - BRAVO_CONFIG_TEST.ps1 жорстко фіксує -ConfigRoot=$PSScriptRoot
    #     (реальний RuntimeRoot); canonical security-guard
    #     Test-BravoLegacyConfiguration (BRAVO_CONFIG_LOADER.ps1:181)
    #     навмисно відхиляє -ConfigPath поза цим ConfigRoot ("Файл
    #     конфігурації повинен знаходитися в каталозі конфігурації") —
    #     це захист CODE!=DATA, не обходити. Ізольований candidate поза
    #     RuntimeRoot органічно несумісний із цим entrypoint-ом.
    #   - BRAVO_DRY_RUN.ps1 сумісний технічно (сам виводить ConfigRoot із
    #     ConfigPath), але його exit-code змішує config-семантику з
    #     REAL_SERVER-залежними перевірками (Scheduled Tasks/служби) —
    #     на dev-хості чи щойно розгорнутому сервері (до
    #     BRAVO_TASKS_INSTALL.ps1) він системно FAIL незалежно від
    #     коректності candidate-конфігурації. Класифікація "яка FAIL-
    #     категорія дійсно відносна до config, а яка — середовище" —
    #     нетривіальна робота (той самий клас, що вимагав окремого циклу
    #     category-aware allow-listing в tools/acceptance/), навмисно НЕ
    #     імпровізується тут. Реальні кроки 6-7 (canonical loader через
    #     Effective/Validation вище) уже покривають config-семантичну
    #     валідацію без цього ризику.
    # Майбутня UI-ітерація може показувати BRAVO_DRY_RUN як
    # ІНФОРМАЦІЙНИЙ (не блокуючий) pre-apply звіт.
    #
    # P0.3 (Iteration 2, незалежний review): це НЕ залишає Apply без
    # canonical blocking-валідації, еквівалентної BRAVO_CONFIG_TEST.ps1.
    # BRAVO_CONFIG_TEST.ps1 не має власної валідаційної логіки — це тонка
    # обгортка навколо Import-BravoConfiguration -PassThru. Кроки 6-7 вище
    # (через Test-BRAVOConfiguratorCandidateOverrides -> Update-
    # BRAVOConfiguratorEffective -CandidateOverridesOverride $MergedOverrides)
    # викликають ту саму функцію з тим самим fail-closed контрактом на
    # ПОВНОМУ candidate — емпірично підтверджено (docs/design/
    # BRAVO_CONFIGURATOR_DESIGN.md, розділ "P0.3"). Ніякого refactor
    # production BRAVO_CONFIG_TEST/LOADER не знадобилося.

    # Крок 10: race detection — перечитати baseline ПРЯМО перед записом.
    $currentState = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $RuntimeRoot -ProductionConfigDirectory $ProductionConfigDirectory
    if ($currentState.BaselineHash -ne $ProductionBaseline.BaselineHash) {
        return [pscustomobject]@{
            Applied = $false
            Stage   = 'RaceDetection'
            Reasons = @('BRAVO.local.config змінився паралельно між Load і Apply (baseline hash mismatch). STOP — без merge/overwrite. Перезавантажте Configurator і повторіть редагування.')
        }
    }

    $productionConfigPath = Join-Path $ProductionConfigDirectory 'BRAVO.local.config'
    $candidateText = ConvertTo-BRAVOConfiguratorLocalConfigText -MergedOverrides $mergedOverrides

    # Крок 11: backup існуючого файлу (якщо був).
    $backupPath = $null
    if ($ProductionBaseline.Present) {
        $backupPath = "$productionConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $productionConfigPath -Destination $backupPath -Force
    }

    # Крок 12: atomic replace — write у temp У ТІЙ САМІЙ директорії (той
    # самий том => Move-Item є атомарним rename, не copy+delete), потім
    # Move-Item поверх продакшн-файлу.
    $tempWritePath = "$productionConfigPath.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($tempWritePath, $candidateText, (New-Object System.Text.UTF8Encoding($false)))

        # Друга (вужча) race-перевірка безпосередньо перед Move-Item (P2-фікс
        # за результатами незалежного review): backup/серіалізація між
        # кроком 10 і сюди займають вимірюваний час, протягом якого файл
        # усе ще міг змінитися паралельно. Це НЕ замінює крок 10 (та
        # перевірка потрібна раніше, щоб не витрачати час на backup для
        # вже застарілого candidate) — це додаткове звуження вікна прямо
        # перед незворотним record.
        $immediateState = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $RuntimeRoot -ProductionConfigDirectory $ProductionConfigDirectory
        if ($immediateState.BaselineHash -ne $ProductionBaseline.BaselineHash) {
            Remove-Item -LiteralPath $tempWritePath -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{
                Applied = $false
                Stage   = 'RaceDetection'
                Reasons = @('BRAVO.local.config змінився паралельно безпосередньо перед atomic replace (baseline hash mismatch). STOP — без merge/overwrite. Перезавантажте Configurator і повторіть редагування.')
            }
        }

        Move-Item -LiteralPath $tempWritePath -Destination $productionConfigPath -Force
    } catch {
        Remove-Item -LiteralPath $tempWritePath -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            Applied = $false
            Stage   = 'AtomicReplace'
            Reasons = @("Не вдалося атомарно записати BRAVO.local.config: $($_.Exception.Message). Production файл НЕ змінено.")
        }
    }

    # Крок 13-14: reload + verify — production конфігурація мусить
    # завантажуватись без винятку одразу після запису. Якщо ні —
    # АВТОМАТИЧНИЙ ROLLBACK (P1-фікс за результатами незалежного review):
    # раніше ця гілка повертала Applied=$true з текстовим "УВАГА", хоча
    # production-файл уже замінено файлом, який сам щойно провалив
    # власну верифікацію — це перетворювало fail-closed зупинку на
    # попередження (заборонено §07 BRAVO Runtime Safety Invariants).
    # Тепер: спроба відновити production з backup (або видалити, якщо
    # файлу до Apply не існувало), і в будь-якому разі Applied=$false —
    # операція вважається неуспішною, оператор повинен повторити Apply.
    try {
        $loaderPath = Join-Path $RuntimeRoot 'BRAVO_CONFIG_LOADER.ps1'
        . $loaderPath
        $reloadResult = Read-BRAVOLocalConfigurationOverrides -ConfigDirectory $ProductionConfigDirectory
        if (-not $reloadResult.Present) {
            throw 'Щойно записаний BRAVO.local.config не читається повторно.'
        }
    } catch {
        $verificationError = $_.Exception.Message
        $rollbackReasons = New-Object System.Collections.Generic.List[string]
        $rollbackReasons.Add("Щойно записаний BRAVO.local.config не пройшов повторне читання: $verificationError")
        try {
            if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                Copy-Item -LiteralPath $backupPath -Destination $productionConfigPath -Force
                $rollbackReasons.Add("Rollback виконано: production BRAVO.local.config відновлено з backup ($backupPath).")
            } else {
                Remove-Item -LiteralPath $productionConfigPath -Force -ErrorAction Stop
                $rollbackReasons.Add('Rollback виконано: production BRAVO.local.config видалено (до Apply файл не існував).')
            }
        } catch {
            $rollbackReasons.Add("КРИТИЧНО: автоматичний rollback НЕ вдався ($($_.Exception.Message)). Production файл лишається у невалідованому стані ($productionConfigPath). Відновіть вручну з backup: $backupPath")
        }
        return [pscustomobject]@{
            Applied      = $false
            Stage        = 'PostApplyVerification'
            Reasons      = $rollbackReasons.ToArray()
            BackupPath   = $backupPath
        }
    }

    # Крок 15: результат.
    return [pscustomobject]@{
        Applied     = $true
        Stage       = 'Complete'
        Reasons     = @()
        BackupPath  = $backupPath
        NewHash     = (Get-FileHash -LiteralPath $productionConfigPath -Algorithm SHA256).Hash
        AppliedPaths = @($mergedOverrides.Keys | Sort-Object)
    }
}

Export-ModuleMember -Function @(
    'Get-BRAVOConfiguratorProductionOverrideState',
    'Merge-BRAVOConfiguratorCandidateOverrides',
    'Test-BRAVOConfiguratorCandidateOverrides',
    'ConvertTo-BRAVOConfiguratorLocalConfigText',
    'Invoke-BRAVOConfiguratorApply'
)
