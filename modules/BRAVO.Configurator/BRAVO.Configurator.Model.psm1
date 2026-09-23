# BRAVO.Configurator.Model — Default/Override/Effective/Dirty модель
# налаштувань. Без прихованого стану: кожна функція повертає новий
# знімок моделі, а не мутує існуючий об'єкт на місці.
#
# Модель НЕ обчислює dependency-семантику сама (SFTP/SMB master-child
# тощо) — Effective завжди приходить від
# BRAVO.Configurator.Effective::Invoke-BRAVOConfiguratorEffectiveComputation
# (canonical loader), див. docs/design/BRAVO_CONFIGURATOR_DESIGN.md §2, §5.
#
# P0.7/P0.8 reconciliation (5.2.2): для 4 master-gated шляхів нижче
# ($script:MasterGatedPathResolvers) Effective/DisabledReason читаються НЕ
# зі знімку $componentSettings (він завжди RAW — master ніколи не мутує
# дочірні прапорці за дизайном), а з canonical
# $global:storageEffective/$global:bazaSyncEffective, які Effective-модуль
# тепер також захоплює. Це той самий принцип "не вигадувати
# dependency-семантику в GUI" — resolvers нижче лише ЗНАХОДЯТЬ, ДЕ в
# canonical-виводі лежить правильне значення для кожного Path; саме
# master AND child обчислення повністю належить
# Get-BRAVOEffectiveStorageConfiguration/Get-BRAVOEffectiveSynchronizationConfiguration
# (modules/BRAVO.Discovery), не Configurator-у.

Set-StrictMode -Version 2.0

# Issue #216, сьоме коло ревю (P1, "Import configuration dependencies into
# the model scope"): раніше ConvertTo-BRAVOConfiguratorOverrideHashtable/
# Get-BRAVOConfiguratorSessionSchemaCatalog перевіряли `Get-Module -Name
# 'BRAVO.Configuration'/'...Schema'` і імпортували ЛИШЕ якщо модуля не
# знайдено в процесі — небезпечне припущення під Windows PowerShell 5.1
# module session-state семантикою: `Get-Module` показує, що інстанс
# модуля ЗАВАНТАЖЕНИЙ десь у процесі, але НЕ доводить, що його exported
# команди видимі у ПРИВАТНОМУ session state САМЕ модуля
# BRAVO.Configurator.Model (напр. якщо той самий модуль уже імпортовано
# лише в глобальну сесію викликача, а не dot-sourced/imported у сесію
# ЦЬОГО модуля). Тоді виклики на кшталт
# Get-BRAVOConfigurationSchemaAuthorizationClass/Get-BRAVODefaultConfiguration/
# Get-BRAVOConfigurationSchema/Test-BRAVOConfigurationOverrideAuthorization
# нижче падають CommandNotFoundException — і це особливо непомітно, бо
# guard-и мовчки "проходять" (Get-Module каже "вже завантажено"), а
# реальний виклик падає лише коли $LocalOverrides.Count -gt 0 (ранній
# return на порожньому наборі ховає залежність узагалі). Імпорт тепер
# БЕЗУМОВНИЙ у власний module scope цього файлу (без залежності від
# Get-Module як доказу видимості команд) — виконується ОДИН раз при
# imports .psm1, працює однаково незалежно від того, чи файл
# завантажується через Model.psd1 (RequiredModules) чи напряму (як це
# роблять і production BRAVO_CONFIGURATOR.ps1, і self-test).
$script:BRAVOConfiguratorModelDependencyRoot = Split-Path -Path $PSScriptRoot -Parent
Import-Module -Name (Join-Path $script:BRAVOConfiguratorModelDependencyRoot 'BRAVO.Configuration\BRAVO.Configuration.psd1') -ErrorAction Stop -Scope Local
Import-Module -Name (Join-Path $script:BRAVOConfiguratorModelDependencyRoot 'BRAVO.Configuration\BRAVO.Configuration.Schema.psd1') -ErrorAction Stop -Scope Local

function Resolve-BRAVOConfiguratorGatedEffective {
    <#
    .SYNOPSIS
        Для шляхів, чиє справжнє Effective-значення живе не в
        $componentSettings (RAW), а в canonical storageEffective/
        bazaSyncEffective — повертає [pscustomobject]@{ EffectiveValue; DisabledReason }.
        $null, якщо Path не є master-gated (виклик має впасти назад на
        звичайний dot-path lookup у $componentSettings).
    .DESCRIPTION
        DisabledReason приписується master-у ЛИШЕ коли він дійсно є
        причиною (canonical DisabledReason непорожній) — якщо
        BAZA_APP_SFTP/BAZA_WWW_SFTP ефективно вимкнені з іншої причини
        (власний raw-прапорець false, недоступне BAZA_WWW джерело), це НЕ
        приписується master-у (P0.8: "не хардкодити один generic текст
        для різних dependency chains").
    #>
    [CmdletBinding()]
    param(
        $EffectiveConfig,
        [Parameter(Mandatory = $true)][string]$Path
    )

    switch ($Path) {
        'componentSettings.SFTP.ArchiveUpload' {
            $storage = $EffectiveConfig.storageEffective.SFTP
            return [pscustomobject]@{
                EffectiveValue  = [bool]$storage.ArchiveUpload
                DisabledReason  = if ([string]::IsNullOrWhiteSpace([string]$storage.DisabledReason)) { $null } else { [string]$storage.DisabledReason }
            }
        }
        'componentSettings.SMB.ArchiveCopy' {
            $storage = $EffectiveConfig.storageEffective.SMB
            return [pscustomobject]@{
                EffectiveValue  = [bool]$storage.ArchiveCopy
                DisabledReason  = if ([string]::IsNullOrWhiteSpace([string]$storage.DisabledReason)) { $null } else { [string]$storage.DisabledReason }
            }
        }
        'componentSettings.Synchronization.BAZA_APP_SFTP' {
            $component = @($EffectiveConfig.bazaSyncEffective.Components | Where-Object { $_.Name -eq 'BAZA_APP' })
            if ($component.Count -ne 1) { return $null }
            $sftpMasterReason = [string]$EffectiveConfig.storageEffective.SFTP.DisabledReason
            # P2-фікс за результатами незалежного review: приписувати
            # DisabledReason master-у можна лише якщо ВЛАСНИЙ raw-прапорець
            # дитини true (тобто дитина була б Effective=true, якби не
            # master) — інакше, коли raw дитини вже false, Effective=false
            # спричинений власним вибором оператора, а не master-ом, і
            # DisabledReason, що вказує на SFTP.Enabled, був би хибним
            # поясненням.
            $rawSftpFlag = [bool]$EffectiveConfig.componentSettings.Synchronization.BAZA_APP_SFTP
            return [pscustomobject]@{
                EffectiveValue = [bool]$component[0].SftpEnabled
                DisabledReason = if ($rawSftpFlag -and (-not [bool]$component[0].SftpEnabled) -and -not [string]::IsNullOrWhiteSpace($sftpMasterReason)) { $sftpMasterReason } else { $null }
            }
        }
        'componentSettings.Synchronization.BAZA_WWW_SFTP' {
            $component = @($EffectiveConfig.bazaSyncEffective.Components | Where-Object { $_.Name -eq 'BAZA_WWW' })
            if ($component.Count -ne 1) { return $null }
            $sftpMasterReason = [string]$EffectiveConfig.storageEffective.SFTP.DisabledReason
            $rawSftpFlag = [bool]$EffectiveConfig.componentSettings.Synchronization.BAZA_WWW_SFTP
            return [pscustomobject]@{
                EffectiveValue = [bool]$component[0].SftpEnabled
                DisabledReason = if ($rawSftpFlag -and (-not [bool]$component[0].SftpEnabled) -and -not [string]::IsNullOrWhiteSpace($sftpMasterReason)) { $sftpMasterReason } else { $null }
            }
        }
        default { return $null }
    }
}

function Get-BRAVOConfiguratorValueAtPath {
    <#
    .SYNOPSIS
        Читає значення за dot-шляхом із вкладеної структури
        (hashtable/pscustomobject), сумісно і з BRAVO.config-хешами, і з
        JSON-десеріалізованими pscustomobject від Effective-модуля.
    #>
    [CmdletBinding()]
    param(
        $Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $segments = @($Path -split '\.')
    $currentNode = $Root
    foreach ($segment in $segments) {
        if ($null -eq $currentNode) { return $null }
        if ($currentNode -is [hashtable]) {
            if (-not $currentNode.Contains($segment)) { return $null }
            $currentNode = $currentNode[$segment]
        } elseif ($currentNode.PSObject.Properties.Name -contains $segment) {
            $currentNode = $currentNode.$segment
        } else {
            return $null
        }
    }
    return $currentNode
}

function Resolve-BRAVOConfiguratorSuppliedLeafOverride {
    <#
    .SYNOPSIS
        PR #224 review, N1: канонічна (ЄДИНА) проєкція "чи цей canonical
        leaf-шлях реально СУПРОВОДЖУЄТЬСЯ значенням у сирому
        LocalOverrides-шарі" — незалежно від того, у якій формі:
        плаский dot-шлях ('backupMonitoring.SFTP.BAZA.Mode' = 'Legacy')
        чи вкладений Node ('backupMonitoring.SFTP.BAZA' = @{ Mode = 'Legacy' }),
        включно з довільною глибиною вкладеності (та сама D3/F1-межа, що
        canonical loader-authorization уже застосовує).
    .DESCRIPTION
        Raw production BRAVO.local.config, записаний ДО Wave 2 (коли цей
        лист ще був редагованим через Configurator у плоскій формі), і
        BRAVO.local.config, записаний ДО F1 (нещодавно, у вкладеній
        формі) — обидва законні pre-remediation представлення ОДНОГО й
        того самого canonical leaf. Попередня Model-побудова перевіряла
        лише `$LocalOverrides.Contains($path)` (точний плоский ключ) —
        вкладена форма мовчки трактувалась як "override відсутній",
        хоча canonical loader (після F1) її авторизує й мерджить.

        Флат-форма МАЄ ПРІОРИТЕТ над вкладеною при обох присутніх
        одночасно (малоймовірний, але детермінований tie-break) —
        перевіряється першою (найдовший/точний префікс).

        НЕ виконує PowerShell (лише навігація вже розпарсених
        hashtable-значень). НЕ авторизує й НЕ валідує значення — це
        відповідальність canonical loader/authorization-реєстру; ця
        функція лише ЗНАХОДИТЬ supplied-значення й ЙОГО ПОХОДЖЕННЯ
        (TopLevelKey + NestedPath), достатнє для точного,
        нейдеструктивного видалення/оновлення пізніше
        (Remove-BRAVOConfiguratorNestedOverrideLeaf /
        Set-BRAVOConfiguratorNestedOverrideLeafValue).
    .OUTPUTS
        [pscustomobject]{ Found; Value; TopLevelKey; NestedPath }
        NestedPath — [string[]]; порожній масив = плоска форма (TopLevelKey
        сам дорівнює LeafPath); непорожній = сегменти всередині вкладеного
        контейнера TopLevelKey, що ведуть до листа.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$LocalOverrides,
        [Parameter(Mandatory = $true)][string]$LeafPath
    )

    $segments = @($LeafPath -split '\.')
    for ($prefixLength = $segments.Count; $prefixLength -ge 1; $prefixLength--) {
        $prefix = [string]::Join('.', $segments[0..($prefixLength - 1)])
        if (-not $LocalOverrides.Contains($prefix)) { continue }
        $candidateValue = $LocalOverrides[$prefix]

        if ($prefixLength -eq $segments.Count) {
            # Точний плоский dot-шлях — саме той canonical leaf, без
            # вкладеності.
            return [pscustomobject]@{
                Found       = $true
                Value       = $candidateValue
                TopLevelKey = $prefix
                NestedPath  = [string[]]@()
            }
        }

        if ($candidateValue -isnot [hashtable]) {
            # Значення на цьому префіксі існує, але не hashtable — не
            # може містити решту сегментів. Пробуємо коротший префікс.
            continue
        }

        $remainingSegments = @($segments[$prefixLength..($segments.Count - 1)])
        $node = $candidateValue
        $navigationOk = $true
        foreach ($segment in $remainingSegments) {
            if ($node -isnot [hashtable] -or -not $node.Contains($segment)) {
                $navigationOk = $false
                break
            }
            $node = $node[$segment]
        }
        if ($navigationOk) {
            return [pscustomobject]@{
                Found       = $true
                Value       = $node
                TopLevelKey = $prefix
                NestedPath  = [string[]]$remainingSegments
            }
        }
    }

    return [pscustomobject]@{
        Found       = $false
        Value       = $null
        TopLevelKey = $null
        NestedPath  = [string[]]@()
    }
}

function Convert-BRAVOConfiguratorNestedContainerToFlatKeys {
    <#
    .SYNOPSIS
        PR #224 review, N1: розгортає ОДИН вкладений (Node) top-level
        контейнер $Overrides[$TopLevelKey] у плоскі dot-шляхи
        ("$TopLevelKey.<segment>..."; довільна глибина) і видаляє сам
        TopLevelKey. Мутує $Overrides за посиланням.
    .DESCRIPTION
        Canonical Configurator-серіалізатор
        (ConvertTo-BRAVOConfiguratorPowerShellLiteral, викликається і
        production-записом, і isolated pre-Apply перевіркою) НАВМИСНО
        fail-closed відмовляється серіалізувати hashtable/IDictionary-
        значення (P2-фікс: "вкладена hashtable ніколи не мала тут
        з'являтись") — тобто Configurator ФІЗИЧНО не може записати
        canonical leaf у вкладеній формі, незалежно від того, як його
        прочитано. Тому щойно Merge-BRAVOConfiguratorCandidateOverrides
        торкається БУДЬ-ЯКОГО canonical-листа всередині легасі вкладеного
        контейнера (зняття override, чи навіть просто "лишити
        незміненим" для сусіднього листа з тим самим контейнером), УВЕСЬ
        контейнер мігрує у плоску форму — це НЕ "нормалізація всього
        local-config" (§4 задачі), бо торкається ЛИШЕ ЦЬОГО ОДНОГО
        контейнера, і НЕ "силует мовчазна міграція значення" — значення
        (включно з невідомими/новішими нащадками) зберігаються побайтово,
        міняється лише форма представлення (вкладена -> плоска), що є
        єдиним фізично можливим способом Configurator-у щось ЗАПИСАТИ.
        Оригінальний вкладений hashtable-об'єкт (може бути спільним
        посиланням з ProductionBaseline.Overrides викликача) лише
        ЧИТАЄТЬСЯ, ніколи не мутується на місці.

        PR #224 review, R3-2: явний плоский top-level ключ, що вже існує
        в $Overrides (canonical precedence "explicit flat leaf > nested
        representation" — той самий canonical leaf, supplied ОБОМА
        формами водночас), НЕ перезаписується значенням, знайденим під
        час розгортання вкладеного контейнера. Порівняння Path через
        Hashtable.Contains — та сама регістронезалежна семантика ключів
        PowerShell hashtable, що вже використовує решта Configurator-коду
        (BRAVO.local.config-ключі регістронезалежні).

        PR #224 review, R3-3: ПЕРЕД будь-якою мутацією $Overrides
        виконується preflight-обхід усього $root — якщо на БУДЬ-ЯКІЙ
        глибині трапляється порожній вкладений hashtable (без жодного
        leaf-нащадка), функція fail-closed кидає виняток і НЕ видаляє
        $TopLevelKey й НЕ записує жодного дочірнього ключа. Порожній
        вузол не має жодного leaf-значення, яке можна розгорнути у
        плоский dot-шлях — canonical серіалізатор
        (ConvertTo-BRAVOConfiguratorPowerShellLiteral) однаково не вміє
        записати hashtable-значення, тож мовчазне пропущення такого вузла
        незворотно втратило б його. Викликач (Merge-BRAVOConfiguratorCandidateOverrides
        -> Test-BRAVOConfiguratorCandidateOverrides -> Invoke-BRAVOConfiguratorApply)
        не продовжує до atomic replace після винятку тут, тож продакшн
        BRAVO.local.config лишається байт-в-байт незмінним.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Overrides,
        [Parameter(Mandatory = $true)][string]$TopLevelKey
    )

    if (-not $Overrides.Contains($TopLevelKey)) { return }
    $root = $Overrides[$TopLevelKey]
    if ($root -isnot [hashtable]) { return }

    $emptyDescendantPaths = New-Object System.Collections.Generic.List[string]
    $preflightPending = New-Object System.Collections.Generic.List[object]
    [void]$preflightPending.Add([pscustomobject]@{ Prefix = $TopLevelKey; Node = $root })
    while ($preflightPending.Count -gt 0) {
        $preflightCurrent = $preflightPending[$preflightPending.Count - 1]
        $preflightPending.RemoveAt($preflightPending.Count - 1)
        $preflightChildKeys = @($preflightCurrent.Node.Keys)
        if ($preflightChildKeys.Count -eq 0) {
            [void]$emptyDescendantPaths.Add($preflightCurrent.Prefix)
            continue
        }
        foreach ($preflightKey in $preflightChildKeys) {
            $preflightChildValue = $preflightCurrent.Node[$preflightKey]
            if ($preflightChildValue -is [hashtable]) {
                [void]$preflightPending.Add([pscustomobject]@{
                    Prefix = "$($preflightCurrent.Prefix).$preflightKey"
                    Node   = $preflightChildValue
                })
            }
        }
    }
    if ($emptyDescendantPaths.Count -gt 0) {
        throw ("BRAVO.Configurator: неможливо безпечно розгорнути вкладений контейнер '$TopLevelKey' у плоскі dot-шляхи — " +
            "порожній вкладений вузол без жодного leaf-нащадка виявлено на: $([string]::Join(', ', @($emptyDescendantPaths))). " +
            "Canonical серіалізатор не вміє записати hashtable-значення, тож цей вузол було б мовчки втрачено при флеттенізації; " +
            "операцію скасовано ДО будь-якої мутації — продакшн-файл лишається незмінним.")
    }

    $Overrides.Remove($TopLevelKey)

    $pending = New-Object System.Collections.Generic.List[object]
    [void]$pending.Add([pscustomobject]@{ Prefix = $TopLevelKey; Node = $root })
    while ($pending.Count -gt 0) {
        $current = $pending[$pending.Count - 1]
        $pending.RemoveAt($pending.Count - 1)
        foreach ($key in @($current.Node.Keys)) {
            $childPath = "$($current.Prefix).$key"
            $childValue = $current.Node[$key]
            if ($childValue -is [hashtable]) {
                [void]$pending.Add([pscustomobject]@{ Prefix = $childPath; Node = $childValue })
            } elseif (-not $Overrides.Contains($childPath)) {
                $Overrides[$childPath] = $childValue
            }
        }
    }
}

function Get-BRAVOConfiguratorModel {
    <#
    .SYNOPSIS
        Будує масив Setting-об'єктів (один на кожен schema-дескриптор) із
        canonical Default (реального BRAVO.config, через DefaultConfig) і
        поточних LocalOverrides — без Effective (обчислюється окремо,
        батчем, дорогою child-process операцією — Update-BRAVOConfiguratorEffective).
    .PARAMETER DefaultConfig
        Результат Invoke-BRAVOConfiguratorEffectiveComputation з ПОРОЖНІМ
        набором overrides (=canonical BRAVO.config без жодного site override) —
        баз для Default-колонки.
    .PARAMETER LocalOverrides
        Hashtable dot-шлях -> значення, як повертає
        Read-BRAVOLocalConfigurationOverrides.Overrides (canonical parser,
        не окремий).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$SchemaCatalog,
        [Parameter(Mandatory = $true)]$DefaultConfig,
        [Parameter(Mandatory = $true)][hashtable]$LocalOverrides
    )

    $model = New-Object System.Collections.Generic.List[object]
    foreach ($descriptor in $SchemaCatalog) {
        $path = [string]$descriptor.Path
        $defaultValue = Get-BRAVOConfiguratorValueAtPath -Root $DefaultConfig -Path $path
        # PR #224 review, N1: canonical leaf може бути supplied і плоским
        # dot-шляхом, і вкладеним Node-контейнером (легасі pre-F1
        # представлення) — Resolve-BRAVOConfiguratorSuppliedLeafOverride
        # трактує обидві форми ідентично, замість колишнього точного
        # $LocalOverrides.Contains($path), який бачив лише плоску форму.
        $suppliedLeaf = Resolve-BRAVOConfiguratorSuppliedLeafOverride -LocalOverrides $LocalOverrides -LeafPath $path
        $overridePresent = [bool]$suppliedLeaf.Found
        $overrideValue = if ($overridePresent) { $suppliedLeaf.Value } else { $null }

        $model.Add([pscustomobject]@{
            Path             = $path
            Metadata         = $descriptor
            DefaultValue     = $defaultValue
            OverridePresent  = $overridePresent
            OverrideValue    = $overrideValue
            EffectiveValue   = $null   # заповнюється Update-BRAVOConfiguratorEffective
            EffectiveSource  = $null   # 'Default' | 'Override' | 'Derived' | $null (не обчислено)
            DisabledReason   = $null   # canonical причина Raw != Effective (лише для master-gated шляхів; P0.8)
            ValidationState  = $null   # заповнюється Validation-модулем
            DependencyState  = $null   # заповнюється Validation-модулем
            Dirty            = $false
        })
    }

    # ПРИМІТКА: НЕ @($model) — прямий @()-каст System.Collections.Generic.List[object]
    # під Windows PowerShell 5.1 інколи кидає
    # "System.ArgumentException: Argument types do not match" із
    # PSToObjectArrayBinder (відомий CLR/PS 5.1 binder edge-case для
    # певних комбінацій типів елементів). .ToArray() — надійний шлях.
    return $model.ToArray()
}

function Set-BRAVOConfiguratorOverride {
    <#
    .SYNOPSIS
        Повертає НОВИЙ масив-модель із заміненим override для Path (Dirty=$true).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$Model,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $updated = @($Model | ForEach-Object {
        if ($_.Path -eq $Path) {
            $clone = $_.PSObject.Copy()
            $clone.OverridePresent = $true
            $clone.OverrideValue = $Value
            $clone.Dirty = $true
            $clone.EffectiveValue = $null
            $clone.EffectiveSource = $null
            $clone.DisabledReason = $null
            $clone
        } else {
            $_
        }
    })
    return $updated
}

function Clear-BRAVOConfiguratorOverride {
    <#
    .SYNOPSIS
        Повертає НОВИЙ масив-модель, де override для Path видалено —
        видаляє local override, НЕ записує default значення явно (§1.3
        задачі: "Використовувати default" видаляє override, а не
        матеріалізує його в BRAVO.local.config).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$Model,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $updated = @($Model | ForEach-Object {
        if ($_.Path -eq $Path) {
            $clone = $_.PSObject.Copy()
            $clone.OverridePresent = $false
            $clone.OverrideValue = $null
            $clone.Dirty = $true
            $clone.EffectiveValue = $null
            $clone.EffectiveSource = $null
            $clone.DisabledReason = $null
            $clone
        } else {
            $_
        }
    })
    return $updated
}

function ConvertTo-BRAVOConfiguratorOverrideHashtable {
    <#
    .SYNOPSIS
        Проєктує модель у candidate-overrides hashtable (dot-шлях -> значення)
        для передачі в Effective/Persistence — лише ті записи, де
        OverridePresent=$true.
    .DESCRIPTION
        PR #224 review, F2 (legacy denied override deadlockує Configurator
        при старті): виключає з проєкції будь-який override, чий
        канонічний Wave 2 Class — DENY_* (напр. legacy
        backupMonitoring.SFTP.BAZA.Mode='Legacy' з часів, коли цей лист
        іще був editable через Configurator). Це стосується ЛИШЕ ЦІЄЇ
        функції — ефективного preview-обчислення
        (Update-BRAVOConfiguratorEffective БЕЗ -CandidateOverridesOverride,
        тобто звичайний UI startup/recalculate шлях). Apply-гейт
        (Persistence::Test-BRAVOConfiguratorCandidateOverrides) цю функцію
        НІКОЛИ не викликає — він завжди передає повний $MergedOverrides
        напряму через -CandidateOverridesOverride, тож лишається так само
        fail-closed: доки denied override не прибрано (Clear), Apply і
        далі відхиляється canonical loader-ом.
        Виключення значення з ТОГО, ЩО РЕАЛЬНО НАДСИЛАЄТЬСЯ canonical
        loader-у для preview — не те саме, що авторизація цього значення;
        сам Model-запис (OverridePresent/OverrideValue) не мутується цим
        викликом, тож UI і далі бачить "legacy denied override існує" для
        відображення/можливості Clear.
        PR #224 review, R3-1: З ОДНИМ винятком — якщо ЦЕЙ КОНКРЕТНИЙ
        Path canonical реєстр позначив
        WeakeningOverride='ExistingSecurityEscapeHatch' (сьогодні лише
        requireAdministrator) І оператор явно підтвердив ПОТОЧНИМ
        процесом BRAVO_ALLOW_WEAKENED_SECURITY=1, override і далі
        передається loader-у, тому Effective-preview показує РІВНО те
        значення, яке реально стане ефективним (canonical loader
        прийняв би той самий override з тим самим env — Configurator
        preview більше не розходиться з реальною loader-поведінкою).
        Без цього env-підтвердження override лишається виключеним, як і
        для WeakeningOverride='None'-листів (напр.
        backupMonitoring.SFTP.BAZA.Mode/.MutationPolicy — вони НІКОЛИ не
        escapable, незалежно від env). Model лишається незмінною для UI
        в обох випадках.
        Читає канонічний реєстр напряму
        (Get-BRAVOConfigurationSchemaAuthorizationClass) і canonical
        рішення "чи escapable ЗАРАЗ"
        (Test-BRAVOConfigurationWeakeningEscapeHatchAllowed) — не другу
        копію 271-позиційної класифікації чи власне порівняння
        env-змінної: той самий реєстр і та сама функція, яку
        використовують BRAVO_CONFIG_LOADER.ps1 і
        Resolve-BRAVOConfiguratorFieldAuthorization; коректно незалежно
        від того, який варіант schema-каталогу (сирий чи вже пропущений
        через Resolve-BRAVOConfiguratorFieldAuthorization) конкретний
        викликач використав для побудови Model.

        PR #224 review (P1, "Let Configurator recover validator-rejected
        overrides"): раніше цикл нижче перевіряв ЛИШЕ DENY_*-клас напряму
        з реєстру — ALLOW_WITH_VALIDATOR-лист з невалідним supplied-
        значенням (напр. maintenanceSettings.Restore.BootRestoreMode =
        'Bogus', legacy-значення, яке ІСТОРИЧНО canonical loader сам
        нормалізував у попередження + безпечний fallback ДО Wave 2)
        проєктувався в preview НЕЗМІНЕНИМ і canonical loader відхиляв
        його під час КОЖНОГО startup/recalculate — Configurator взагалі
        не міг відкритись, щоб дати оператору виправити чи Clear-нути
        значення. Тепер ОДИН прохід через canonical
        Test-BRAVOConfigurationOverrideAuthorization (та сама функція, що
        й loader/Persistence-гейт використовують) над усім проєктованим
        candidate-шаром класифікує КОЖЕН OverridePresent-лист одразу —
        жодного окремого дублювання per-Class логіки для
        ValidatorRejected. Violations із Reason='ValidatorRejected'
        ЗАВЖДИ виключаються з preview-candidate (незалежно від
        WeakeningOverride — послаблення стосується лише DENY_*-власності
        листа, не невалідного значення валідованого листа). Violations із
        Class, що починається на 'DENY_', виключаються ЯКЩО НЕ escapable
        зараз — той самий F2/R3-1-контракт, що діяв і до цього рефакторингу,
        збережений через ІДЕНТИЧНУ Test-BRAVOConfigurationWeakeningEscapeHatchAllowed-
        перевірку. Модель (OverridePresent/OverrideValue) НІКОЛИ не
        мутується цим викликом — і DENY_*, і ValidatorRejected-значення
        лишаються видимими UI для відображення/Clear/виправлення.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$Model
    )

    # Залежності (BRAVO.Configuration/BRAVO.Configuration.Schema) імпортовані
    # безумовно у module scope цього файлу при завантаженні .psm1 (див.
    # коментар біля Set-StrictMode на початку файлу) — жодної Get-Module-
    # перевірки тут більше не потрібно.
    $authorizationClass = Get-BRAVOConfigurationSchemaAuthorizationClass

    $overrides = @{}
    foreach ($setting in $Model) {
        if (-not $setting.OverridePresent) { continue }
        $overrides[[string]$setting.Path] = $setting.OverrideValue
    }
    if ($overrides.Count -eq 0) { return $overrides }

    $canonicalSchema = Get-BRAVOConfigurationSchema -ReferenceConfiguration (Get-BRAVODefaultConfiguration)
    $authorizationResult = Test-BRAVOConfigurationOverrideAuthorization -DotPathOverrides $overrides -Schema $canonicalSchema

    foreach ($violation in @($authorizationResult.Violations)) {
        $violationPath = [string]$violation.Path
        $violationClass = [string]$violation.Class
        if ($violationClass.StartsWith('DENY_', [System.StringComparison]::Ordinal)) {
            $escapeHatchAllowed = Test-BRAVOConfigurationWeakeningEscapeHatchAllowed -Path $violationPath -AuthorizationClass $authorizationClass
            if ($escapeHatchAllowed) {
                # DENY_*, але зараз escapable (R3-1, лише requireAdministrator
                # сьогодні) -> preview МАЄ показати те саме значення, яке
                # реально стане ефективним у canonical loader з тим самим env.
                continue
            }
        }
        # DENY_* (не escapable зараз) АБО ValidatorRejected (невалідне
        # ALLOW_WITH_VALIDATOR-значення) АБО будь-яка інша канонічна
        # відмова — не передається canonical loader-у для preview-
        # обчислення. Model лишається незмінною для UI.
        [void]$overrides.Remove($violationPath)
    }

    return $overrides
}

function Get-BRAVOConfiguratorSessionSchemaCatalog {
    <#
    .SYNOPSIS
        PR #224 review (P2, "Expose validator-rejected noncatalog overrides
        for recovery"; розширено — "Generalize noncatalog DENY recovery";
        розширено далі — "Keep escapable noncatalog overrides in the
        session model"): один augmented каталог дескрипторів для ПОТОЧНОЇ
        сесії — статичний каталог (типово
        Resolve-BRAVOConfiguratorFieldAuthorization-результат) плюс
        ДИНАМІЧНО синтезовані дескриптори для canonical листів, яких
        немає у статичному каталозі, але чиє ПОТОЧНЕ supplied-значення
        canonical авторизація трактує як одне з трьох:
          A. ALLOW_WITH_VALIDATOR + Reason='ValidatorRejected'
             -> recovery-only дескриптор (Section='ValidatorRejected');
          B. DENY_* + Reason='DeniedClass' + escape hatch НЕ дозволений
             зараз -> recovery-only дескриптор (Section='DeniedOverride');
          C. DENY_* + Reason='DeniedClass' + canonical escape hatch
             ЗАРАЗ дозволений (R3-1, сьогодні лише requireAdministrator)
             -> дескриптор session-preservation (Section='EscapableOverride') —
             це НЕ відхилене значення: canonical loader його зараз
             приймає, тож Model МУСИТЬ бачити той самий override, інакше
             preview/Effective розійшлися б із реальним canonical
             результатом.
    .DESCRIPTION
        Приклад 1 (ValidatorRejected): schedulerSettings.RestoreVerify.WeeklyOn='Funday' —
        canonical leaf, ALLOW_WITH_VALIDATOR, ІСТОРИЧНО loader сам
        нормалізував невідоме значення в попередження + safe fallback
        (Saturday) ДО Wave 2, але не має статичного Configurator-
        дескриптора — тож без цієї функції Model про нього нічого не
        знає, Merge-BRAVOConfiguratorCandidateOverrides лишає значення
        незмінним при КОЖНОМУ Apply, а canonical loader відхиляє КОЖЕН
        Apply — оператор не може прибрати легасі-значення через
        Configurator (recovery deadlock).

        Приклад 2 (DeniedClass, розширення цього кола): winSCPIniPath —
        canonical leaf, DENY_SECURITY_CONTROL, БЕЗ статичного
        Configurator-дескриптора (як і решта 41 DENY_*-листа, відсутнього
        у статичному каталозі). Той самий deadlock: якщо оператор (чи
        стара версія toolkit) залишив local override на такому листі,
        Configurator про нього нічого не знав і не міг Clear через UI.
        Детекція для ОБОХ прикладів похідна ЦІЛКОМ від ОДНОГО canonical
        виклику Test-BRAVOConfigurationOverrideAuthorization нижче — жодної
        другої/дублюючої класифікаційної таблиці DENY-шляхів тут немає;
        яка саме множина шляхів зараз DENY_*, повністю визначає
        $script:BRAVOConfigurationSchemaAuthorizationClass у Schema.psm1.

        Детекція ЦІЛКОМ похідна від canonical
        Test-BRAVOConfigurationOverrideAuthorization (включно з
        Resolve-BRAVOConfiguratorSuppliedLeafOverride для нейтральної
        плоскої/вкладеної форми supplied-значення) — жодного другого
        валідатора чи власної класифікаційної таблиці тут немає.

        ОДИН session-рівня результат ЦІЄЇ функції МАЄ передаватись
        консистентно в Get-BRAVOConfiguratorModel, dirty tracking, UI-
        рендер і Invoke-BRAVOConfiguratorApply (через $state.SchemaCatalog) —
        інакше Model бачила б recovery-рядок, а
        Merge-BRAVOConfiguratorCandidateOverrides (яка ітерує ЛИШЕ по
        $SchemaCatalog.Path) його не бачила б, і Clear мовчки ігнорувався
        б при Apply. Викликач ПОВИНЕН перевикликати цю функцію після
        кожного Reload/успішного Apply (зі свіжим LocalOverrides), щоб
        рядок, чий override зник з диска, природно перестав
        синтезуватись — жодного явного "видалення рядка" не потрібно.

        Синтезований дескриптор:
          - ReadOnly = $true (той самий UI-механізм, що вже дає "зняти
            наявний override можна, створити новий не можна" для
            backupMonitoring.SFTP.BAZA.Mode/.MutationPolicy — F2:
            checkbox.Enabled лишається $true, коли OverridePresent,
            valueControl.Enabled завжди $false для ReadOnly — редагувати
            значення через Configurator неможливо, лише Clear);
          - НЕ додається для Path, вже представленого статичним
            каталогом (нормальна UI-експозиція лишається під контролем
            каталогу, не цієї функції) — жоден canonical/DENY_*-шлях, уже
            маючий дескриптор (у т.ч. BAZA.Mode/.MutationPolicy, для яких
            ReadOnly-статус і так уже дає окремий, існуючий, статичний
            механізм через Resolve-BRAVOConfiguratorFieldAuthorization),
            тут не дублюється;
          - для DENY_*-класу з Reason='DeniedClass' синтезується РІВНО
            один рядок, чий Section визначається ЄДИНИМ canonical
            викликом Test-BRAVOConfigurationWeakeningEscapeHatchAllowed
            (той самий виклик, що ConvertTo-BRAVOConfiguratorOverrideHashtable
            вже використовує для R3-1/requireAdministrator — не
            дубльовано, не переоцінено тут окремою логікою): $false ->
            Section='DeniedOverride' (Case B, значення фактично
            відхилене); $true -> Section='EscapableOverride' (Case C,
            значення фактично ПРИЙНЯТЕ зараз через затверджений escape
            hatch) — В ОБОХ випадках рядок лишається ReadOnly/existing-
            only/Clear-only, різниться лише презентація й той факт, що
            Case C-значення продовжує брати участь у preview-candidate
            (див. ConvertTo-BRAVOConfiguratorOverrideHashtable);
          - НЕ додається для валідного supplied-значення (авторизація
            IsValid=$true — нормальний ALLOW_WITH_VALIDATOR override,
            нічого відновлювати, D3/невідомі ключі лишаються geть
            незачепленими цією функцією).
    .PARAMETER StaticCatalog
        Звичайний UI-каталог (типово результат
        Resolve-BRAVOConfiguratorFieldAuthorization) — статичні
        дескриптори НЕ мутуються, лише доповнюються.
    .PARAMETER LocalOverrides
        Поточний production override-шар (типово
        Read-BRAVOLocalConfigurationOverrides.Overrides /
        Get-BRAVOConfiguratorProductionOverrideState.Overrides).
    .OUTPUTS
        [object[]] — $StaticCatalog + 0..N синтезованих recovery-only
        дескрипторів.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][array]$StaticCatalog,
        [Parameter(Mandatory = $true)][hashtable]$LocalOverrides
    )

    # Залежності імпортовані безумовно у module scope цього файлу (див.
    # коментар біля Set-StrictMode на початку файлу) — жодної Get-Module-
    # перевірки тут більше не потрібно.

    $augmented = New-Object System.Collections.Generic.List[object]
    $staticPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($descriptor in $StaticCatalog) {
        [void]$augmented.Add($descriptor)
        [void]$staticPaths.Add([string]$descriptor.Path)
    }

    if ($LocalOverrides.Count -eq 0) { return $augmented.ToArray() }

    $authorizationClass = Get-BRAVOConfigurationSchemaAuthorizationClass
    $canonicalSchema = Get-BRAVOConfigurationSchema -ReferenceConfiguration (Get-BRAVODefaultConfiguration)

    $recoveryOrder = 90000
    foreach ($path in @($authorizationClass.Keys | Sort-Object)) {
        if ($staticPaths.Contains($path)) { continue }
        $entry = $authorizationClass[$path]
        $class = [string]$entry.Class
        $isValidatorClass = ($class -eq 'ALLOW_WITH_VALIDATOR')
        $isDenyClass = $class.StartsWith('DENY_')
        if (-not $isValidatorClass -and -not $isDenyClass) { continue }

        $supplied = Resolve-BRAVOConfiguratorSuppliedLeafOverride -LocalOverrides $LocalOverrides -LeafPath $path
        if (-not $supplied.Found) { continue }

        $authResult = Test-BRAVOConfigurationOverrideAuthorization -DotPathOverrides @{ $path = $supplied.Value } -Schema $canonicalSchema
        if ($authResult.IsValid) { continue }
        $violation = @($authResult.Violations | Where-Object { [string]$_.Path -eq $path })
        if ($violation.Count -eq 0) { continue }
        $reason = [string]$violation[0].Reason
        if ($isValidatorClass -and $reason -ne 'ValidatorRejected') { continue }
        if ($isDenyClass -and $reason -ne 'DeniedClass') { continue }

        $recoveryOrder++
        if ($reason -eq 'ValidatorRejected') {
            $section = 'ValidatorRejected'
            $label = "Відновлення (невалідне значення): $path"
            $description = "Наявний local override для '$path' не проходить canonical валідацію: $($violation[0].Message) Поле лише для перегляду/Clear через Configurator; нове значення тут ввести не можна. Виправте значення напряму у BRAVO.local.config, щоб знову зробити цей лист звичайним редагованим полем."
        } elseif (Test-BRAVOConfigurationWeakeningEscapeHatchAllowed -Path $path -AuthorizationClass $authorizationClass) {
            # Issue #216, сьоме коло ревю (P2, "Keep escapable noncatalog
            # overrides in the session model"): Case C — DeniedClass, АЛЕ
            # canonical escape hatch ЗАРАЗ активний для цього Path (R3-1,
            # сьогодні лише requireAdministrator + BRAVO_ALLOW_WEAKENED_SECURITY=1).
            # Це НЕ відхилене значення — canonical loader ПРИЙМАЄ його
            # прямо зараз (той самий, ЄДИНИЙ canonical виклик
            # Test-BRAVOConfigurationWeakeningEscapeHatchAllowed, що
            # ConvertTo-BRAVOConfiguratorOverrideHashtable вже використовує,
            # щоб включити цей самий override у preview-candidate). Раніше
            # цей випадок просто `continue`-ився (рядок НЕ синтезувався) —
            # Model про override взагалі не знала, тож ConvertTo-BRAVOConfiguratorOverrideHashtable
            # (яка будує candidate ЛИШЕ з OverridePresent-рядків Model)
            # ніколи не бачила цей override, а startup Effective preview
            # мовчки відкочувався до canonical default замість фактичного
            # значення, яке canonical loader реально застосує. Тепер рядок
            # синтезується під ОКРЕМИМ Section='EscapableOverride' — НЕ
            # 'DeniedOverride'/'ValidatorRejected', щоб не називати
            # прийняте значення відхиленим — і лишається ReadOnly/existing-
            # only/Clear-only, як і решта recovery-рядків: Configurator НЕ
            # дозволяє створити НОВИЙ послаблений override через це поле.
            $section = 'EscapableOverride'
            $label = "Активний override під дозволеним послабленням: $path"
            $description = "Наявний local override для '$path' активний лише завдяки затвердженому механізму послаблення безпеки (BRAVO_ALLOW_WEAKENED_SECURITY=1) — canonical loader ЗАРАЗ приймає це значення. Configurator відображає й зберігає наявний override для узгодженості з реальним ефективним значенням, але НЕ дозволяє створити новий послаблений override через це поле; нове значення тут ввести не можна. Clear прибирає override повністю."
        } else {
            # DeniedClass, НЕ escapable зараз: не розкриваємо саме значення
            # класу/причини заборони (security-sensitive деталь) — лише
            # факт, що поле заборонене і його можна прибрати через Clear.
            $section = 'DeniedOverride'
            $label = "Відновлення (заборонений override): $path"
            $description = "Наявний local override для '$path' встановлює заборонену політику й canonical loader його відхиляє. Поле лише для перегляду/Clear через Configurator; нове значення тут ввести не можна. Приберіть цей запис напряму з BRAVO.local.config, якщо override більше не потрібен."
        }
        [void]$augmented.Add(@{
            Path        = $path
            Group       = 'Recovery'
            Section     = $section
            Label       = $label
            Description = $description
            Type        = 'String'
            Phase       = 1
            Advanced    = $true
            ReadOnly    = $true
            Secret      = $false
            Order       = $recoveryOrder
        })
    }

    return $augmented.ToArray()
}

function Test-BRAVOConfiguratorValueEquality {
    <#
    .SYNOPSIS
        Порівнює два значення налаштування (скаляр або масив) для
        визначення EffectiveSource. Звичайний PowerShell '-eq' з масивом
        зліва виконує element-wise фільтрацію, а не порівняння цілого
        масиву — для StringArray/NumberArray-дескрипторів (напр.
        maintenanceSettings.Limits.ExcludedDrives) це завжди повертало
        помилковий 'Derived' навіть для дійсно рівних масивів (P2-фікс за
        результатами незалежного review).
    #>
    [CmdletBinding()]
    param($Left, $Right)

    if ($null -eq $Left -and $null -eq $Right) { return $true }
    if ($null -eq $Left -or $null -eq $Right) { return $false }

    $leftIsCollection = ($Left -is [array]) -or (($Left -is [System.Collections.IEnumerable]) -and ($Left -isnot [string]))
    $rightIsCollection = ($Right -is [array]) -or (($Right -is [System.Collections.IEnumerable]) -and ($Right -isnot [string]))

    if ($leftIsCollection -or $rightIsCollection) {
        $leftItems = @($Left)
        $rightItems = @($Right)
        if ($leftItems.Count -ne $rightItems.Count) { return $false }
        for ($index = 0; $index -lt $leftItems.Count; $index++) {
            if (-not (Test-BRAVOConfiguratorValueEquality -Left $leftItems[$index] -Right $rightItems[$index])) {
                return $false
            }
        }
        return $true
    }

    return $Left -eq $Right
}

function Update-BRAVOConfiguratorEffective {
    <#
    .SYNOPSIS
        Перераховує EffectiveValue/EffectiveSource для всієї моделі одним
        batched child-process викликом canonical loader-а (не per-keystroke —
        викликач відповідає за дебаунс).
    .PARAMETER CandidateOverridesOverride
        Опційно: повний candidate-hashtable (dot-шлях -> значення), який
        реально прогонятиметься через canonical loader, замість hashtable-а,
        виведеного з Model (ConvertTo-BRAVOConfiguratorOverrideHashtable
        бачить лише schema-відомі Path і мовчки відкидає будь-який
        preserved unknown/legacy ключ). Persistence-пайплайн передає сюди
        повний $MergedOverrides, щоб dependency/canonical-валідація перед
        Apply реально покривала те саме, що буде записано у продакшн —
        без цього параметра поведінка (проєкція з Model) лишається
        незмінною для звичайного UI-перерахунку Effective.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$Model,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [hashtable]$CandidateOverridesOverride
    )

    $candidateOverrides = if ($PSBoundParameters.ContainsKey('CandidateOverridesOverride')) {
        $CandidateOverridesOverride
    } else {
        ConvertTo-BRAVOConfiguratorOverrideHashtable -Model $Model
    }
    $effectiveConfig = Invoke-BRAVOConfiguratorEffectiveComputation -RuntimeRoot $RuntimeRoot -CandidateOverrides $candidateOverrides

    $updated = @($Model | ForEach-Object {
        $clone = $_.PSObject.Copy()
        $gated = Resolve-BRAVOConfiguratorGatedEffective -EffectiveConfig $effectiveConfig -Path $clone.Path
        if ($null -ne $gated) {
            $clone.EffectiveValue = $gated.EffectiveValue
            $clone.DisabledReason = $gated.DisabledReason
        } else {
            $clone.EffectiveValue = Get-BRAVOConfiguratorValueAtPath -Root $effectiveConfig -Path $clone.Path
            $clone.DisabledReason = $null
        }
        $clone.EffectiveSource = if ($clone.OverridePresent) {
            if (Test-BRAVOConfiguratorValueEquality -Left $clone.EffectiveValue -Right $clone.OverrideValue) { 'Override' } else { 'Derived' }
        } else {
            if (Test-BRAVOConfiguratorValueEquality -Left $clone.EffectiveValue -Right $clone.DefaultValue) { 'Default' } else { 'Derived' }
        }
        $clone
    })
    return $updated
}

function Test-BRAVOConfiguratorModelDirty {
    <#
    .SYNOPSIS
        P2-A.3: справжній diff-based Dirty — порівнює поточний
        OverridePresent/OverrideValue КОЖНОГО schema-запису з
        $BaselineOverrides (той самий hashtable, що
        Get-BRAVOConfiguratorProductionOverrideState.Overrides повертає
        при Load/Reload/успішному Apply), а НЕ подієвий Model[].Dirty
        прапорець.
    .DESCRIPTION
        Model[].Dirty (виставляється Set/Clear-BRAVOConfiguratorOverride)
        лише фіксує "цей рядок торкались у цій сесії" і лишається $true
        назавжди навіть після edit -> revert до оригінального значення —
        P3-знахідка P1-стабілізації ("phantom Dirty"). Ця функція натомість
        обчислює справжній diff:
          - OverridePresent відрізняється від baseline OverridePresent, АБО
          - обидва present, але OverrideValue відрізняється (глибоке
            порівняння через Test-BRAVOConfiguratorValueEquality — та сама
            функція, що EffectiveSource уже використовує для масивів).
        "false override" (OverridePresent=true, OverrideValue=$false)
        НІКОЛИ не еквівалентний "відсутньому override" — порівняння йде
        по OverridePresent, не лише по значенню.
        Обчислені/непersisted поля моделі (EffectiveValue, EffectiveSource,
        ValidationState, DependencyState, DisabledReason) свідомо НЕ
        враховуються — вони не є частиною BRAVO.local.config.

        PR #224 review (P2, "Resolve nested baselines in dirty checks"):
        baseline presence/value РАНІШЕ читались напряму через
        $BaselineOverrides.Contains($setting.Path) — розуміє лише плаский
        dot-шлях. Якщо той самий baseline supplied у вкладеній Node-формі
        ('backupMonitoring.SFTP.BAZA' = @{ Mode = 'Legacy' }),
        $setting.OverridePresent (обчислений моделлю через канонічний
        Resolve-BRAVOConfiguratorSuppliedLeafOverride) коректно $true, але
        пряма перевірка Contains($setting.Path) хибно повертала $false —
        неторкана вкладена baseline завжди звітувала як dirty. Тепер
        baseline проєктується через ТОЙ САМИЙ канонічний resolver, що й
        сама модель — єдине джерело істини для "плаский vs вкладений
        supplied leaf", без дублювання вкладеної навігації тут.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$Model,
        [Parameter(Mandatory = $true)][hashtable]$BaselineOverrides
    )

    foreach ($setting in $Model) {
        $baseline = Resolve-BRAVOConfiguratorSuppliedLeafOverride -LocalOverrides $BaselineOverrides -LeafPath $setting.Path
        $baselinePresent = [bool]$baseline.Found
        if ([bool]$setting.OverridePresent -ne $baselinePresent) { return $true }
        if ($baselinePresent -and -not (Test-BRAVOConfiguratorValueEquality -Left $setting.OverrideValue -Right $baseline.Value)) {
            return $true
        }
    }
    return $false
}

function Reset-BRAVOConfiguratorSetting {
    <#
    .SYNOPSIS
        P2-A.6: скидає ОДИН schema-запис до Default — еквівалентно
        Clear-BRAVOConfiguratorOverride (видаляє local override, НЕ
        матеріалізує Default явно в BRAVO.local.config — той самий §1.3
        контракт, що "Використовувати default"). Іменований окремо для
        явного Reset-контракту (§ P2-A.6 задачі), логіка канонічно та сама.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$Model,
        [Parameter(Mandatory = $true)][string]$Path
    )

    return Clear-BRAVOConfiguratorOverride -Model $Model -Path $Path
}

function Reset-BRAVOConfiguratorSection {
    <#
    .SYNOPSIS
        P2-A.6: скидає ВСІ schema-записи вказаної Group/Section до
        Default. Інші section/group і будь-який preserved unknown/newer
        ключ (Model про нього нічого не знає) лишаються незмінними —
        unknown-ключі persist через Merge-BRAVOConfiguratorCandidateOverrides
        (Persistence), не через Model.
    .PARAMETER Group
        Metadata.Group значення (той самий групувальний ключ, що UI
        категорійне дерево вже використовує).
    .PARAMETER Section
        Metadata.Section значення в межах Group.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$Model,
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Section
    )

    $updated = $Model
    $pathsInSection = @($Model | Where-Object {
        [string]$_.Metadata.Group -eq $Group -and [string]$_.Metadata.Section -eq $Section -and [bool]$_.OverridePresent
    } | ForEach-Object { [string]$_.Path })

    foreach ($path in $pathsInSection) {
        $updated = Clear-BRAVOConfiguratorOverride -Model $updated -Path $path
    }
    return $updated
}

function Get-BRAVOConfiguratorSessionOutcome {
    <#
    .SYNOPSIS
        P2-A.4 (correction): визначає фінальний session outcome
        ('Applied'/'Cancelled'/'NoChanges') виключно проти ПОТОЧНОГО
        ProductionBaseline (не проти першого baseline сесії при Launch).
    .DESCRIPTION
        ProductionBaseline — canonical знімок production-стану, який уже
        оновлюється при Load/Reload і після успішного Apply (той самий
        знімок, що вже використовується для race detection у Persistence
        і для status-bar/close-confirmation Dirty). Використання
        первинного baseline сесії (замість поточного) давало хибний
        Cancelled після Reload без незбережених змін (сценарій A) і
        приховувало реальні незбережені зміни, зроблені ПІСЛЯ успішного
        Apply (сценарій B), бо AnyApplySucceeded мав абсолютний
        пріоритет над фактичним поточним diff.

        Precedence: незбережений diff на момент закриття переважає над
        фактом, що Apply колись у сесії відбувся успішно — Applied не
        повинен приховувати подальші незбережені зміни, які оператор
        закрив без застосування.
    .PARAMETER Model
        Поточна модель на момент закриття форми.
    .PARAMETER ProductionBaseline
        Поточний (не первинний) ProductionBaseline.Overrides знімок —
        оновлюється Reload/успішним Apply.
    .PARAMETER AnyApplySucceeded
        Чи відбувся хоча б один успішний Apply протягом сесії.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$Model,
        [Parameter(Mandatory = $true)][hashtable]$ProductionBaseline,
        [Parameter(Mandatory = $true)][bool]$AnyApplySucceeded
    )

    $currentDirty = Test-BRAVOConfiguratorModelDirty -Model $Model -BaselineOverrides $ProductionBaseline
    if ($currentDirty) {
        return 'Cancelled'
    } elseif ($AnyApplySucceeded) {
        return 'Applied'
    } else {
        return 'NoChanges'
    }
}

Export-ModuleMember -Function @(
    'Get-BRAVOConfiguratorValueAtPath',
    'Resolve-BRAVOConfiguratorSuppliedLeafOverride',
    'Convert-BRAVOConfiguratorNestedContainerToFlatKeys',
    'Get-BRAVOConfiguratorModel',
    'Set-BRAVOConfiguratorOverride',
    'Clear-BRAVOConfiguratorOverride',
    'ConvertTo-BRAVOConfiguratorOverrideHashtable',
    'Get-BRAVOConfiguratorSessionSchemaCatalog',
    'Test-BRAVOConfiguratorValueEquality',
    'Update-BRAVOConfiguratorEffective',
    'Test-BRAVOConfiguratorModelDirty',
    'Reset-BRAVOConfiguratorSetting',
    'Reset-BRAVOConfiguratorSection',
    'Get-BRAVOConfiguratorSessionOutcome'
)
