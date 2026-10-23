Set-StrictMode -Version Latest

# ApiPool.Pricing: model registry and cost math. Depends on ApiPool.Core, which
# the entrypoint/test runner imports into the global scope before this module.
#
# Money model: prices are USD per million tokens, which equals micro-USD per
# token, so tokens * price is an exact micro-USD amount. All math is [decimal];
# results are [long] micro-USD, always rounded UP (never under-count spend).
#
# Error policy: an unknown, disabled or invalid model is refused with
# PRICING_UNKNOWN (an invalid model is additionally flagged PRICING_INVALID at
# import time). Prices are never silently zero.

function Get-ApiPoolMember {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Test-ApiPoolMember {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Test-ApiPoolNumberValue {
    param($Value)

    return ($null -ne $Value) -and ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single])
}

function ConvertTo-ApiPoolTier {
    # Returns a tier object, or a string describing why the tier is invalid.
    param($Raw, [int]$Index)

    $fields = @('input', 'output', 'cacheWrite5m', 'cacheWrite1h', 'cacheRead')
    $values = @{}
    foreach ($f in $fields) {
        $v = Get-ApiPoolMember -Object $Raw -Name $f
        if (-not (Test-ApiPoolNumberValue -Value $v)) { return ("tier {0}: '{1}' is missing or not numeric" -f $Index, $f) }
        try { $d = [decimal]$v } catch { return ("tier {0}: '{1}' is out of range" -f $Index, $f) }
        if ($d -le 0) { return ("tier {0}: '{1}' must be > 0" -f $Index, $f) }
        $values[$f] = $d
    }
    if (-not ($values['cacheWrite1h'] -ge $values['cacheWrite5m'] -and $values['cacheWrite5m'] -ge $values['input'])) {
        return ("tier {0}: expected cacheWrite1h >= cacheWrite5m >= input" -f $Index)
    }
    $max = Get-ApiPoolMember -Object $Raw -Name 'maxPromptTokens'
    $maxTokens = $null
    if ($null -ne $max) {
        if (-not (Test-ApiPoolNumberValue -Value $max)) { return ("tier {0}: 'maxPromptTokens' must be a number or null" -f $Index) }
        try { $m = [decimal]$max } catch { return ("tier {0}: 'maxPromptTokens' is out of range" -f $Index) }
        if ($m -le 0 -or $m -ne [Math]::Floor($m)) { return ("tier {0}: 'maxPromptTokens' must be a positive integer" -f $Index) }
        $maxTokens = $m
    }
    return [pscustomobject]@{
        MaxPromptTokens = $maxTokens
        Input           = $values['input']
        Output          = $values['output']
        CacheWrite5m    = $values['cacheWrite5m']
        CacheWrite1h    = $values['cacheWrite1h']
        CacheRead       = $values['cacheRead']
    }
}

function ConvertTo-ApiPoolModelEntry {
    param([string]$Id, $Raw)

    $reason = $null
    $tiers = New-Object System.Collections.ArrayList
    $enabled = $false
    $maxOutput = 0

    $enabledRaw = Get-ApiPoolMember -Object $Raw -Name 'enabled'
    if ($enabledRaw -is [bool]) { $enabled = $enabledRaw } else { $reason = "'enabled' must be a boolean" }

    $maxRaw = Get-ApiPoolMember -Object $Raw -Name 'maxOutputTokens'
    if ($null -eq $reason) {
        if (-not (Test-ApiPoolNumberValue -Value $maxRaw) -or [decimal]$maxRaw -le 0 -or [decimal]$maxRaw -ne [Math]::Floor([decimal]$maxRaw)) {
            $reason = "'maxOutputTokens' must be a positive integer"
        }
        else { $maxOutput = [int64]$maxRaw }
    }

    if ($null -eq $reason) {
        $rawTiers = @(Get-ApiPoolMember -Object $Raw -Name 'tiers')
        if ($rawTiers.Count -eq 0 -or $null -eq $rawTiers[0]) { $reason = "'tiers' must be a non-empty array" }
        else {
            $index = 0
            $previousMax = [decimal]0
            foreach ($rt in $rawTiers) {
                $tier = ConvertTo-ApiPoolTier -Raw $rt -Index $index
                if ($tier -is [string]) { $reason = $tier; break }
                if ($null -eq $tier.MaxPromptTokens -and $index -ne ($rawTiers.Count - 1)) {
                    $reason = ("tier {0}: only the last tier may have maxPromptTokens = null" -f $index); break
                }
                if ($null -ne $tier.MaxPromptTokens) {
                    if ($tier.MaxPromptTokens -le $previousMax) { $reason = ("tier {0}: maxPromptTokens must be strictly ascending" -f $index); break }
                    $previousMax = $tier.MaxPromptTokens
                }
                [void]$tiers.Add($tier)
                $index++
            }
        }
    }

    $valid = ($null -eq $reason)
    return [pscustomobject]@{
        PSTypeName      = 'ApiPool.Model'
        Id              = $Id
        Enabled         = $enabled
        MaxOutputTokens = $maxOutput
        Tiers           = @($tiers)
        Valid           = $valid
        InvalidCode     = $(if ($valid) { $null } else { 'PRICING_INVALID' })
        InvalidReason   = $reason
    }
}

function Import-ApiPoolModelRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not [System.IO.File]::Exists($Path)) {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message ("Model registry not found: {0}" -f $Path)
    }
    try { $doc = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path)) } catch {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message ("Model registry is not valid JSON: {0}" -f $Path)
    }
    $registrySchema = Get-ApiPoolMember -Object $doc -Name 'schemaVersion'
    if (-not (($registrySchema -is [int] -or $registrySchema -is [long]) -and [long]$registrySchema -eq 1)) {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message ("Model registry schemaVersion must be 1: {0}" -f $Path)
    }
    $modelsRaw = Get-ApiPoolMember -Object $doc -Name 'models'
    if ($null -eq $modelsRaw -or $modelsRaw -isnot [System.Management.Automation.PSCustomObject]) {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message "Model registry must contain a 'models' object."
    }
    if ((Get-ApiPoolMember -Object $doc -Name 'unit') -ne 'per_million_tokens' -or (Get-ApiPoolMember -Object $doc -Name 'currency') -ne 'USD') {
        Invoke-ApiPoolThrow -Code 'CONFIG_INVALID' -Message "Model registry must use currency 'USD' and unit 'per_million_tokens'."
    }

    $models = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    foreach ($p in $modelsRaw.PSObject.Properties) {
        $models[$p.Name] = ConvertTo-ApiPoolModelEntry -Id $p.Name -Raw $p.Value
    }
    return [pscustomobject]@{
        PSTypeName    = 'ApiPool.ModelRegistry'
        SchemaVersion = Get-ApiPoolMember -Object $doc -Name 'schemaVersion'
        PricesAsOf    = Get-ApiPoolMember -Object $doc -Name 'pricesAsOf'
        PricingSource = Get-ApiPoolMember -Object $doc -Name 'pricingSource'
        Models        = $models
    }
}

function Assert-ApiPoolModelUsable {
    param($Model)

    if ($null -eq $Model -or -not (Test-ApiPoolMember -Object $Model -Name 'Valid')) {
        Invoke-ApiPoolThrow -Code 'PRICING_UNKNOWN' -Message 'Model is not a registry model.'
    }
    if (-not $Model.Valid) {
        Invoke-ApiPoolThrow -Code 'PRICING_UNKNOWN' -Message ("Model '{0}' has invalid pricing ({1})." -f $Model.Id, $Model.InvalidReason)
    }
    if (-not $Model.Enabled) {
        Invoke-ApiPoolThrow -Code 'PRICING_UNKNOWN' -Message ("Model '{0}' is disabled." -f $Model.Id)
    }
}

function Get-ApiPoolModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Registry,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Model
    )

    if ([string]::IsNullOrEmpty($Model) -or -not $Registry.Models.ContainsKey($Model)) {
        Invoke-ApiPoolThrow -Code 'PRICING_UNKNOWN' -Message ("Model '{0}' is not in the pricing registry." -f $Model)
    }
    $entry = $Registry.Models[$Model]
    Assert-ApiPoolModelUsable -Model $entry
    return $entry
}

function Get-ApiPoolTierForPrompt {
    param($Model, [decimal]$PromptTokens)

    foreach ($tier in $Model.Tiers) {
        if ($null -eq $tier.MaxPromptTokens -or $PromptTokens -le $tier.MaxPromptTokens) { return $tier }
    }
    Invoke-ApiPoolThrow -Code 'PRICING_UNKNOWN' -Message ("Prompt of {0} tokens exceeds the highest priced tier of model '{1}'." -f $PromptTokens, $Model.Id)
}

function ConvertTo-ApiPoolMicroUsd {
    # Round UP to whole micro-USD. Input is already micro-USD (tokens * USD/MTok).
    param([decimal]$Value)

    return [long][Math]::Ceiling($Value)
}

function Get-ApiPoolReservationCost {
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory = $true)]
        $Model,

        [Parameter(Mandatory = $true)]
        [int64]$BodyBytes,

        [Parameter(Mandatory = $true)]
        [int]$MessageCount,

        [Parameter(Mandatory = $true)]
        [int]$MaxTokens
    )

    Assert-ApiPoolModelUsable -Model $Model
    if ($BodyBytes -lt 0 -or $MessageCount -lt 0) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'BodyBytes and MessageCount must not be negative.'
    }
    if ($MaxTokens -lt 1) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'MaxTokens must be at least 1.'
    }
    if ($MaxTokens -gt $Model.MaxOutputTokens) {
        Invoke-ApiPoolThrow -Code 'MAX_TOKENS_EXCEEDS_MODEL' -Message ("MaxTokens {0} exceeds the limit {1} of model '{2}'." -f $MaxTokens, $Model.MaxOutputTokens, $Model.Id)
    }

    # Token count never exceeds the UTF-8 byte count; framing overhead is added conservatively.
    [decimal]$inputUpper = [decimal]$BodyBytes + 64 + (16 * [decimal]$MessageCount)
    $tier = Get-ApiPoolTierForPrompt -Model $Model -PromptTokens $inputUpper
    $rate = [Math]::Max([Math]::Max($tier.Input, $tier.CacheWrite5m), $tier.CacheWrite1h)
    return (ConvertTo-ApiPoolMicroUsd -Value (($inputUpper * $rate) + ([decimal]$MaxTokens * $tier.Output)))
}

function Get-ApiPoolUsageCount {
    param($Usage, [string]$Name)

    if (-not (Test-ApiPoolMember -Object $Usage -Name $Name)) {
        Invoke-ApiPoolThrow -Code 'USAGE_INVALID' -Message ("Usage field '{0}' is missing." -f $Name)
    }
    $v = Get-ApiPoolMember -Object $Usage -Name $Name
    if (-not (Test-ApiPoolNumberValue -Value $v)) {
        Invoke-ApiPoolThrow -Code 'USAGE_INVALID' -Message ("Usage field '{0}' is not a number." -f $Name)
    }
    try { $d = [decimal]$v } catch {
        Invoke-ApiPoolThrow -Code 'USAGE_INVALID' -Message ("Usage field '{0}' is out of range." -f $Name)
    }
    if ($d -lt 0 -or $d -ne [Math]::Floor($d)) {
        Invoke-ApiPoolThrow -Code 'USAGE_INVALID' -Message ("Usage field '{0}' must be a non-negative integer." -f $Name)
    }
    return $d
}

function Get-ApiPoolActualCost {
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory = $true)]
        $Model,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Usage
    )

    Assert-ApiPoolModelUsable -Model $Model
    if ($null -eq $Usage) {
        Invoke-ApiPoolThrow -Code 'USAGE_INVALID' -Message 'Usage is missing.'
    }
    $in = Get-ApiPoolUsageCount -Usage $Usage -Name 'input_tokens'
    $out = Get-ApiPoolUsageCount -Usage $Usage -Name 'output_tokens'
    $cacheCreate = Get-ApiPoolUsageCount -Usage $Usage -Name 'cache_creation_input_tokens'
    $cacheRead = Get-ApiPoolUsageCount -Usage $Usage -Name 'cache_read_input_tokens'

    # Cache creation tokens priced at the 1h rate unless a consistent 5m/1h breakdown is given.
    $tokens5m = [decimal]0
    $tokens1h = $cacheCreate
    $breakdown = Get-ApiPoolMember -Object $Usage -Name 'cache_creation'
    if ($null -ne $breakdown) {
        $b5 = Get-ApiPoolUsageCount -Usage $breakdown -Name 'ephemeral_5m_input_tokens'
        $b1 = Get-ApiPoolUsageCount -Usage $breakdown -Name 'ephemeral_1h_input_tokens'
        if (($b5 + $b1) -eq $cacheCreate) {
            $tokens5m = $b5
            $tokens1h = $b1
        }
        else {
            # Inconsistent breakdown: price the larger figure entirely at the 1h rate.
            $tokens1h = [Math]::Max($cacheCreate, ($b5 + $b1))
        }
    }

    # The tier follows the RECONCILED cache-creation total (tokens5m + tokens1h), never the possibly smaller reported figure.
    $tier = Get-ApiPoolTierForPrompt -Model $Model -PromptTokens ($in + $tokens5m + $tokens1h + $cacheRead)
    $micro = ($in * $tier.Input) + ($out * $tier.Output) + ($tokens5m * $tier.CacheWrite5m) + ($tokens1h * $tier.CacheWrite1h) + ($cacheRead * $tier.CacheRead)
    return (ConvertTo-ApiPoolMicroUsd -Value $micro)
}

Export-ModuleMember -Function @(
    'Import-ApiPoolModelRegistry',
    'Get-ApiPoolModel',
    'Get-ApiPoolReservationCost',
    'Get-ApiPoolActualCost'
)
