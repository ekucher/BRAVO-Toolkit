# BRAVO.Configurator.Validation — семантична перевірка моделі (INFO/WARNING/
# ERROR), без жодного I/O. Отримує вже обчислену Effective-модель
# (Update-BRAVOConfiguratorEffective) — не викликає child-process сама.
#
# ERROR = блокує Apply. WARNING/INFO — інформаційні, не блокують.

Set-StrictMode -Version 2.0

function New-BRAVOConfiguratorValidationFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('INFO', 'WARNING', 'ERROR')][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )
    return [pscustomobject]@{ Severity = $Severity; Path = $Path; Message = $Message }
}

function Test-BRAVOConfiguratorSMBArchiveConsistency {
    <#
    .SYNOPSIS
        SMB.ArchiveCopy=true (effective) з порожнім/невалідним RootPath —
        ERROR (§11 задачі: приклад допустимого blocking error).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][array]$Model)

    $findings = New-Object System.Collections.Generic.List[object]
    $archiveCopySetting = @($Model | Where-Object { $_.Path -eq 'componentSettings.SMB.ArchiveCopy' })
    $rootPathSetting = @($Model | Where-Object { $_.Path -eq 'smbSettings.RootPath' })

    if ($archiveCopySetting.Count -eq 1 -and $rootPathSetting.Count -eq 1) {
        $archiveCopyEffective = [bool]$archiveCopySetting[0].EffectiveValue
        $rootPathEffective = [string]$rootPathSetting[0].EffectiveValue
        if ($archiveCopyEffective -and [string]::IsNullOrWhiteSpace($rootPathEffective)) {
            $findings.Add((New-BRAVOConfiguratorValidationFinding -Severity 'ERROR' -Path 'smbSettings.RootPath' `
                -Message 'SMB.ArchiveCopy увімкнено (effective), але smbSettings.RootPath порожній/невалідний.'))
        }
    }
    # .ToArray() — не @($findings): прямий @()-каст List[object] під PS 5.1
    # інколи кидає ArgumentException у PSToObjectArrayBinder (див. Model.psm1).
    return $findings.ToArray()
}

function Test-BRAVOConfiguratorRawChildMasterMismatch {
    <#
    .SYNOPSIS
        Info-рівня пояснення для raw child != effective через master-switch
        (§11 задачі: приклад допустимого INFO/WARNING, не error).
    .DESCRIPTION
        P0.8 reconciliation (5.2.2): повідомлення БІЛЬШЕ НЕ хардкодить
        один загальний текст "master-switch (SFTP/SMB Enabled)" для всіх 4
        пар — Model.psm1 (Resolve-BRAVOConfiguratorGatedEffective) заповнює
        DisabledReason канонічним текстом напряму з
        $global:storageEffective.SFTP/SMB.DisabledReason (те саме
        повідомлення, яке бачить production runtime). Ця функція лише
        передає його — не вигадує причину. Якщо DisabledReason порожній
        (Raw!=Effective з іншої причини, не master — напр. власний
        BAZA_WWW_SFTP raw=false або недоступне BAZA_WWW джерело),
        повідомлення чесно НЕ приписує розбіжність master-у.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][array]$Model)

    $findings = New-Object System.Collections.Generic.List[object]
    $childPaths = @(
        'componentSettings.SFTP.ArchiveUpload',
        'componentSettings.SMB.ArchiveCopy',
        'componentSettings.Synchronization.BAZA_APP_SFTP',
        'componentSettings.Synchronization.BAZA_WWW_SFTP'
    )
    foreach ($childPath in $childPaths) {
        $setting = @($Model | Where-Object { $_.Path -eq $childPath })
        if ($setting.Count -ne 1) { continue }
        $rawValue = if ($setting[0].OverridePresent) { $setting[0].OverrideValue } else { $setting[0].DefaultValue }
        if ([bool]$rawValue -ne [bool]$setting[0].EffectiveValue) {
            $disabledReason = [string]$setting[0].DisabledReason
            $message = if (-not [string]::IsNullOrWhiteSpace($disabledReason)) {
                "Raw=$rawValue, Effective=$($setting[0].EffectiveValue) — $disabledReason"
            } else {
                "Raw=$rawValue, Effective=$($setting[0].EffectiveValue) — розбіжність зумовлена іншою залежністю (не global SFTP/SMB master-switch)."
            }
            $findings.Add((New-BRAVOConfiguratorValidationFinding -Severity 'INFO' -Path $childPath -Message $message))
        }
    }
    # .ToArray() — не @($findings): прямий @()-каст List[object] під PS 5.1
    # інколи кидає ArgumentException у PSToObjectArrayBinder (див. Model.psm1).
    return $findings.ToArray()
}

function Invoke-BRAVOConfiguratorValidation {
    <#
    .SYNOPSIS
        Прогонить усі semantic-перевірки над Effective-моделлю і повертає
        плаский список findings, відсортований найважчими першими.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][array]$Model)

    $allFindings = New-Object System.Collections.Generic.List[object]
    foreach ($finding in (Test-BRAVOConfiguratorSMBArchiveConsistency -Model $Model)) { $allFindings.Add($finding) }
    foreach ($finding in (Test-BRAVOConfiguratorRawChildMasterMismatch -Model $Model)) { $allFindings.Add($finding) }

    $severityRank = @{ 'ERROR' = 0; 'WARNING' = 1; 'INFO' = 2 }
    $sorted = @($allFindings | Sort-Object { $severityRank[[string]$_.Severity] })

    return [pscustomobject]@{
        Findings   = $sorted
        HasErrors  = (@($sorted | Where-Object { $_.Severity -eq 'ERROR' }).Count -gt 0)
        ErrorCount = @($sorted | Where-Object { $_.Severity -eq 'ERROR' }).Count
        WarningCount = @($sorted | Where-Object { $_.Severity -eq 'WARNING' }).Count
        InfoCount  = @($sorted | Where-Object { $_.Severity -eq 'INFO' }).Count
    }
}

Export-ModuleMember -Function @(
    'New-BRAVOConfiguratorValidationFinding',
    'Test-BRAVOConfiguratorSMBArchiveConsistency',
    'Test-BRAVOConfiguratorRawChildMasterMismatch',
    'Invoke-BRAVOConfiguratorValidation'
)
