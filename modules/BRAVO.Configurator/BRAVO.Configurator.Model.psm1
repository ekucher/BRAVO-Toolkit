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
        $overridePresent = $LocalOverrides.Contains($path)
        $overrideValue = if ($overridePresent) { $LocalOverrides[$path] } else { $null }

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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$Model
    )

    $overrides = @{}
    foreach ($setting in $Model) {
        if ($setting.OverridePresent) {
            $overrides[$setting.Path] = $setting.OverrideValue
        }
    }
    return $overrides
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

Export-ModuleMember -Function @(
    'Get-BRAVOConfiguratorValueAtPath',
    'Get-BRAVOConfiguratorModel',
    'Set-BRAVOConfiguratorOverride',
    'Clear-BRAVOConfiguratorOverride',
    'ConvertTo-BRAVOConfiguratorOverrideHashtable',
    'Test-BRAVOConfiguratorValueEquality',
    'Update-BRAVOConfiguratorEffective'
)
