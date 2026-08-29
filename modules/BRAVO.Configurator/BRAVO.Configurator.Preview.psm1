# BRAVO.Configurator.Preview — семантичний diff перед Apply: Raw-зміни,
# Effective-зміни, зміни credential-вимог, попередження й blocking errors.
# Жодного I/O, жодної canonical-логіки — лише порівняння двох уже
# обчислених Model[] (та опційно двох Get-BRAVOConfiguratorCredentialState
# знімків), передбачених викликачем.
#
# Secret-safety: жоден дескриптор Configurator-схеми сьогодні не має
# Secret=$true (креденшели — окремий домен, ніколи не входять у Model), але
# Preview все одно явно фільтрує Metadata.Secret=$true про всяк випадок
# (майбутньостійкість, не покладатись лише на поточний стан схеми).

Set-StrictMode -Version 2.0

function Get-BRAVOConfiguratorPreview {
    <#
    .SYNOPSIS
        Будує повний preview-звіт: Raw diff, Effective diff, credential
        diff (якщо надано обидва CredentialState знімки), Validation
        findings (Warnings/BlockingErrors) над ModelAfter.
    .PARAMETER ModelBefore
        Модель ДО редагування (напр. щойно завантажена або preset-before).
    .PARAMETER ModelAfter
        Модель ПІСЛЯ редагування/preset — та, що піде в Apply.
    .PARAMETER RequirementStateBefore / RequirementStateAfter
        Опційно: результати Get-BRAVOConfiguratorCredentialState до і
        після (SFTP/SMB Required). Якщо не надано — CredentialChanges
        порожній (Preview все одно лишається коректним без цього блоку).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$ModelBefore,
        [Parameter(Mandatory = $true)][array]$ModelAfter,
        $RequirementStateBefore,
        $RequirementStateAfter
    )

    $rawChanges = New-Object System.Collections.Generic.List[object]
    $effectiveChanges = New-Object System.Collections.Generic.List[object]

    foreach ($afterSetting in $ModelAfter) {
        if ([bool]$afterSetting.Metadata.Secret) { continue }
        $beforeSetting = @($ModelBefore | Where-Object { $_.Path -eq $afterSetting.Path })
        if ($beforeSetting.Count -ne 1) { continue }
        $before = $beforeSetting[0]

        $rawBeforePresent = [bool]$before.OverridePresent
        $rawAfterPresent = [bool]$afterSetting.OverridePresent
        $rawBeforeValue = if ($rawBeforePresent) { $before.OverrideValue } else { $null }
        $rawAfterValue = if ($rawAfterPresent) { $afterSetting.OverrideValue } else { $null }

        $rawChanged = ($rawBeforePresent -ne $rawAfterPresent) -or
            (-not (Test-BRAVOConfiguratorValueEquality -Left $rawBeforeValue -Right $rawAfterValue))
        if ($rawChanged) {
            $rawChanges.Add([pscustomobject]@{
                Path            = $afterSetting.Path
                Label           = $afterSetting.Metadata.Label
                BeforePresent   = $rawBeforePresent
                AfterPresent    = $rawAfterPresent
                BeforeValue     = $rawBeforeValue
                AfterValue      = $rawAfterValue
                ChangeKind      = if (-not $rawBeforePresent -and $rawAfterPresent) { 'Added' }
                                   elseif ($rawBeforePresent -and -not $rawAfterPresent) { 'Removed (default)' }
                                   else { 'Changed' }
            })
        }

        $effectiveChanged = -not (Test-BRAVOConfiguratorValueEquality -Left $before.EffectiveValue -Right $afterSetting.EffectiveValue)
        if ($effectiveChanged) {
            $effectiveChanges.Add([pscustomobject]@{
                Path            = $afterSetting.Path
                Label           = $afterSetting.Metadata.Label
                BeforeEffective = $before.EffectiveValue
                AfterEffective  = $afterSetting.EffectiveValue
                DisabledReason  = $afterSetting.DisabledReason
            })
        }
    }

    $credentialChanges = New-Object System.Collections.Generic.List[object]
    if ($null -ne $RequirementStateBefore -and $null -ne $RequirementStateAfter) {
        foreach ($component in @('SFTP', 'SMB')) {
            $beforeState = $RequirementStateBefore.$component
            $afterState = $RequirementStateAfter.$component
            if ($beforeState.Required -ne $afterState.Required) {
                $credentialChanges.Add([pscustomobject]@{
                    Component      = $component
                    BeforeRequired = [bool]$beforeState.Required
                    AfterRequired  = [bool]$afterState.Required
                })
            }
        }
    }

    $validation = Invoke-BRAVOConfiguratorValidation -Model $ModelAfter
    $warnings = @($validation.Findings | Where-Object { $_.Severity -in @('WARNING', 'INFO') })
    $blockingErrors = @($validation.Findings | Where-Object { $_.Severity -eq 'ERROR' })

    return [pscustomobject]@{
        RawChanges        = $rawChanges.ToArray()
        EffectiveChanges   = $effectiveChanges.ToArray()
        CredentialChanges  = $credentialChanges.ToArray()
        Warnings           = $warnings
        BlockingErrors     = $blockingErrors
        HasBlockingErrors  = ($blockingErrors.Count -gt 0)
        HasChanges         = ($rawChanges.Count -gt 0 -or $effectiveChanges.Count -gt 0)
    }
}

Export-ModuleMember -Function @(
    'Get-BRAVOConfiguratorPreview'
)
