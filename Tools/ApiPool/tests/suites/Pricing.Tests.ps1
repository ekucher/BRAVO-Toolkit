# Pricing suite. Dot-sourced by Invoke-ApiPoolTests.ps1.

$pricingSandbox = New-ApiPoolTestSandbox
try {
    function New-PricingUsage {
        param($In = 0, $Out = 0, $Cc = 0, $Cr = 0, $Breakdown = $null)
        $u = @{ input_tokens = $In; output_tokens = $Out; cache_creation_input_tokens = $Cc; cache_read_input_tokens = $Cr }
        if ($null -ne $Breakdown) { $u['cache_creation'] = $Breakdown }
        return $u
    }

    function New-PricingTier {
        param($Max = $null, $In = 1, $Out = 5, $C5 = 1.25, $C1 = 2, $Cr = 0.1)
        return @{ maxPromptTokens = $Max; input = $In; output = $Out; cacheWrite5m = $C5; cacheWrite1h = $C1; cacheRead = $Cr }
    }

    function Write-PricingRegistry {
        param([string]$Name, $Models)
        $p = Join-Path $pricingSandbox ($Name + '.json')
        $doc = @{ schemaVersion = 1; pricesAsOf = '2026-01-01'; pricingSource = 'test'; currency = 'USD'; unit = 'per_million_tokens'; models = $Models }
        [System.IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $doc -Depth 8))
        return $p
    }

    $registry = Import-ApiPoolModelRegistry -Path (Join-Path $script:ConfigRoot 'models.json')
    $opus = Get-ApiPoolModel -Registry $registry -Model 'claude-opus-5-5'
    $sonnet = Get-ApiPoolModel -Registry $registry -Model 'claude-sonnet-5-5'

    # ---------------- Registry ----------------
    Assert-ApiPoolEqual '2026-10-06' $registry.PricesAsOf 'Registry/PricesAsOf'
    Assert-ApiPoolTrue ($opus.Valid -and $opus.Enabled -and $sonnet.Valid -and $sonnet.Enabled) 'Registry/OpusSonnetUsable'
    Assert-ApiPoolEqual 2 $registry.Models['claude-haiku-5-5'].Tiers.Count 'Registry/HaikuHasTwoTiers'
    Assert-ApiPoolTrue ($registry.Models['claude-haiku-5-5'].Valid -and -not $registry.Models['claude-haiku-5-5'].Enabled) 'Registry/HaikuValidButDisabled'
    Assert-ApiPoolThrows { Get-ApiPoolModel -Registry $registry -Model 'claude-haiku-5-5' } 'Registry/DisabledModelRefused' -ExpectedCode 'PRICING_UNKNOWN'
    Assert-ApiPoolThrows { Get-ApiPoolModel -Registry $registry -Model 'claude-nonexistent' } 'Registry/UnknownModelRefused' -ExpectedCode 'PRICING_UNKNOWN'
    Assert-ApiPoolThrows { Get-ApiPoolModel -Registry $registry -Model 'CLAUDE-OPUS-5-5' } 'Registry/ModelIdIsCaseSensitive' -ExpectedCode 'PRICING_UNKNOWN'
    Assert-ApiPoolThrows { Get-ApiPoolModel -Registry $registry -Model '' } 'Registry/EmptyModelRefused' -ExpectedCode 'PRICING_UNKNOWN'
    Assert-ApiPoolThrows { Import-ApiPoolModelRegistry -Path (Join-Path $pricingSandbox 'absent.json') } 'Registry/MissingFile' -ExpectedCode 'CONFIG_INVALID'

    # Invalid price definitions: model flagged at import, refused on use, never priced as zero.
    $good = @{ enabled = $true; maxOutputTokens = 1000; tiers = @(, (New-PricingTier)) }
    $zero = @{ enabled = $true; maxOutputTokens = 1000; tiers = @(, (New-PricingTier -In 0)) }
    $neg = @{ enabled = $true; maxOutputTokens = 1000; tiers = @(, (New-PricingTier -Out -5)) }
    $str = @{ enabled = $true; maxOutputTokens = 1000; tiers = @(, (New-PricingTier -In '1.0')) }
    $missingTier = New-PricingTier
    $missingTier.Remove('cacheRead')
    $missing = @{ enabled = $true; maxOutputTokens = 1000; tiers = @(, $missingTier) }
    $order = @{ enabled = $true; maxOutputTokens = 1000; tiers = @(, (New-PricingTier -C5 3 -C1 2)) }
    $badMax = @{ enabled = $true; maxOutputTokens = 0; tiers = @(, (New-PricingTier)) }
    $badEnabled = @{ enabled = 'yes'; maxOutputTokens = 1000; tiers = @(, (New-PricingTier)) }
    $noTiers = @{ enabled = $true; maxOutputTokens = 1000; tiers = @() }
    $nullMidTier = @{ enabled = $true; maxOutputTokens = 1000; tiers = @((New-PricingTier -Max $null), (New-PricingTier -Max 5000)) }
    $descTier = @{ enabled = $true; maxOutputTokens = 1000; tiers = @((New-PricingTier -Max 5000), (New-PricingTier -Max 1000)) }
    $badPath = Write-PricingRegistry 'bad' @{ good = $good; zero = $zero; neg = $neg; str = $str; missing = $missing; order = $order; badMax = $badMax; badEnabled = $badEnabled; noTiers = $noTiers; nullMid = $nullMidTier; desc = $descTier }
    $bad = Import-ApiPoolModelRegistry -Path $badPath
    Assert-ApiPoolTrue $bad.Models['good'].Valid 'InvalidPrice/GoodModelStillValid'
    foreach ($id in @('zero', 'neg', 'str', 'missing', 'order', 'badMax', 'badEnabled', 'noTiers', 'nullMid', 'desc')) {
        Assert-ApiPoolTrue ((-not $bad.Models[$id].Valid) -and $bad.Models[$id].InvalidCode -ceq 'PRICING_INVALID') ('InvalidPrice/FlaggedAtImport/' + $id)
        Assert-ApiPoolThrows { Get-ApiPoolModel -Registry $bad -Model $id } ('InvalidPrice/RefusedOnUse/' + $id) -ExpectedCode 'PRICING_UNKNOWN'
        Assert-ApiPoolThrows { Get-ApiPoolReservationCost -Model $bad.Models[$id] -BodyBytes 10 -MessageCount 1 -MaxTokens 10 } ('InvalidPrice/ReservationRefused/' + $id) -ExpectedCode 'PRICING_UNKNOWN'
        Assert-ApiPoolThrows { Get-ApiPoolActualCost -Model $bad.Models[$id] -Usage (New-PricingUsage -In 1) } ('InvalidPrice/ActualCostRefused/' + $id) -ExpectedCode 'PRICING_UNKNOWN'
    }

    # ---------------- Actual cost: exact micro-USD ----------------
    Assert-ApiPoolEqual 14000 (Get-ApiPoolActualCost -Model $opus -Usage (New-PricingUsage -In 1000 -Out 500)) 'Actual/OpusExact'
    Assert-ApiPoolTrue ((Get-ApiPoolActualCost -Model $opus -Usage (New-PricingUsage -In 1000 -Out 500)) -is [long]) 'Actual/ReturnsLong'
    $breakdown = @{ ephemeral_5m_input_tokens = 1000; ephemeral_1h_input_tokens = 2000 }
    Assert-ApiPoolEqual 60500 (Get-ApiPoolActualCost -Model $sonnet -Usage (New-PricingUsage -In 10000 -Out 2000 -Cc 3000 -Cr 50000 -Breakdown $breakdown)) 'Actual/CacheBreakdown5mAnd1h'
    Assert-ApiPoolEqual 62000 (Get-ApiPoolActualCost -Model $sonnet -Usage (New-PricingUsage -In 10000 -Out 2000 -Cc 3000 -Cr 50000)) 'Actual/MissingBreakdownPricedAt1h'
    $mismatchLow = @{ ephemeral_5m_input_tokens = 1000; ephemeral_1h_input_tokens = 1000 }
    Assert-ApiPoolEqual 62000 (Get-ApiPoolActualCost -Model $sonnet -Usage (New-PricingUsage -In 10000 -Out 2000 -Cc 3000 -Cr 50000 -Breakdown $mismatchLow)) 'Actual/BreakdownBelowTotalConservative'
    $mismatchHigh = @{ ephemeral_5m_input_tokens = 1000; ephemeral_1h_input_tokens = 2000 }
    Assert-ApiPoolEqual 62000 (Get-ApiPoolActualCost -Model $sonnet -Usage (New-PricingUsage -In 10000 -Out 2000 -Cc 1000 -Cr 50000 -Breakdown $mismatchHigh)) 'Actual/BreakdownAboveTotalConservative'
    Assert-ApiPoolEqual 1 (Get-ApiPoolActualCost -Model $sonnet -Usage (New-PricingUsage -Cr 1)) 'Actual/RoundsUpFractionalMicroUsd'
    Assert-ApiPoolEqual 0 (Get-ApiPoolActualCost -Model $sonnet -Usage (New-PricingUsage)) 'Actual/ZeroUsageIsZero'
    $psUsage = [pscustomobject]@{ input_tokens = 1000; output_tokens = 500; cache_creation_input_tokens = 0; cache_read_input_tokens = 0; cache_creation = [pscustomobject]@{ ephemeral_5m_input_tokens = 0; ephemeral_1h_input_tokens = 0 } }
    Assert-ApiPoolEqual 14000 (Get-ApiPoolActualCost -Model $opus -Usage $psUsage) 'Actual/AcceptsPsObjectUsage'

    # Tiered model: tier chosen by total prompt (input + cache creation + cache read).
    $tiered = Import-ApiPoolModelRegistry -Path (Write-PricingRegistry 'tiered' @{ t = @{ enabled = $true; maxOutputTokens = 1000; tiers = @((New-PricingTier -Max 1000 -In 1 -Out 5 -C5 1.25 -C1 2 -Cr 0.1), (New-PricingTier -Max 5000 -In 2 -Out 10 -C5 2.5 -C1 4 -Cr 0.2)) } })
    $tm = Get-ApiPoolModel -Registry $tiered -Model 't'
    Assert-ApiPoolEqual 1500 (Get-ApiPoolActualCost -Model $tm -Usage (New-PricingUsage -In 1000 -Out 100)) 'Tier/FirstTierAtBoundary'
    Assert-ApiPoolEqual 3002 (Get-ApiPoolActualCost -Model $tm -Usage (New-PricingUsage -In 1001 -Out 100)) 'Tier/SecondTierJustAbove'
    Assert-ApiPoolEqual 3102 (Get-ApiPoolActualCost -Model $tm -Usage (New-PricingUsage -In 1 -Out 100 -Cc 500 -Cr 500 -Breakdown @{ ephemeral_5m_input_tokens = 0; ephemeral_1h_input_tokens = 500 })) 'Tier/CacheTokensCountTowardsTier'
    Assert-ApiPoolThrows { Get-ApiPoolActualCost -Model $tm -Usage (New-PricingUsage -In 5001) } 'Tier/AboveTopTierRefused' -ExpectedCode 'PRICING_UNKNOWN'

    # Usage validation.
    foreach ($field in @('input_tokens', 'output_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens')) {
        $u = New-PricingUsage -In 1 -Out 1
        $u.Remove($field)
        Assert-ApiPoolThrows { Get-ApiPoolActualCost -Model $opus -Usage $u } ('UsageInvalid/Missing/' + $field) -ExpectedCode 'USAGE_INVALID'
        $u2 = New-PricingUsage -In 1 -Out 1
        $u2[$field] = -1
        Assert-ApiPoolThrows { Get-ApiPoolActualCost -Model $opus -Usage $u2 } ('UsageInvalid/Negative/' + $field) -ExpectedCode 'USAGE_INVALID'
    }
    Assert-ApiPoolThrows { Get-ApiPoolActualCost -Model $opus -Usage (New-PricingUsage -In 1.5) } 'UsageInvalid/NonInteger' -ExpectedCode 'USAGE_INVALID'
    Assert-ApiPoolThrows { Get-ApiPoolActualCost -Model $opus -Usage (New-PricingUsage -In '5') } 'UsageInvalid/StringValue' -ExpectedCode 'USAGE_INVALID'
    Assert-ApiPoolThrows { Get-ApiPoolActualCost -Model $opus -Usage (New-PricingUsage -In $null) } 'UsageInvalid/NullValue' -ExpectedCode 'USAGE_INVALID'
    Assert-ApiPoolThrows { Get-ApiPoolActualCost -Model $opus -Usage $null } 'UsageInvalid/NullUsage' -ExpectedCode 'USAGE_INVALID'
    Assert-ApiPoolThrows { Get-ApiPoolActualCost -Model $opus -Usage (New-PricingUsage -Cc 5 -Breakdown @{ ephemeral_5m_input_tokens = 5 }) } 'UsageInvalid/IncompleteBreakdown' -ExpectedCode 'USAGE_INVALID'
    Assert-ApiPoolThrows { Get-ApiPoolActualCost -Model $opus -Usage (New-PricingUsage -Cc 5 -Breakdown @{ ephemeral_5m_input_tokens = -1; ephemeral_1h_input_tokens = 6 }) } 'UsageInvalid/NegativeBreakdown' -ExpectedCode 'USAGE_INVALID'

    # ---------------- Reservation ----------------
    Assert-ApiPoolEqual 10768 (Get-ApiPoolReservationCost -Model $opus -BodyBytes 1000 -MessageCount 2 -MaxTokens 100) 'Reservation/OpusExact'
    Assert-ApiPoolTrue ((Get-ApiPoolReservationCost -Model $opus -BodyBytes 1000 -MessageCount 2 -MaxTokens 100) -is [long]) 'Reservation/ReturnsLong'
    Assert-ApiPoolEqual 2010 (Get-ApiPoolReservationCost -Model $tm -BodyBytes 900 -MessageCount 1 -MaxTokens 10) 'Reservation/TierOneUsesMaxInputRate'
    Assert-ApiPoolEqual 4420 (Get-ApiPoolReservationCost -Model $tm -BodyBytes 1000 -MessageCount 1 -MaxTokens 10) 'Reservation/OverheadPushesToTierTwo'
    Assert-ApiPoolThrows { Get-ApiPoolReservationCost -Model $opus -BodyBytes 100 -MessageCount 1 -MaxTokens 0 } 'Reservation/MaxTokensZero' -ExpectedCode 'REQUEST_INVALID'
    Assert-ApiPoolThrows { Get-ApiPoolReservationCost -Model $opus -BodyBytes 100 -MessageCount 1 -MaxTokens -3 } 'Reservation/MaxTokensNegative' -ExpectedCode 'REQUEST_INVALID'
    Assert-ApiPoolThrows { Get-ApiPoolReservationCost -Model $opus -BodyBytes 100 -MessageCount 1 -MaxTokens 128001 } 'Reservation/MaxTokensAboveModelLimit' -ExpectedCode 'MAX_TOKENS_EXCEEDS_MODEL'
    Assert-ApiPoolThrows { Get-ApiPoolReservationCost -Model $opus -BodyBytes -1 -MessageCount 1 -MaxTokens 10 } 'Reservation/NegativeBytes' -ExpectedCode 'REQUEST_INVALID'
    Assert-ApiPoolThrows { Get-ApiPoolReservationCost -Model $opus -BodyBytes 100 -MessageCount -1 -MaxTokens 10 } 'Reservation/NegativeMessageCount' -ExpectedCode 'REQUEST_INVALID'
    Assert-ApiPoolThrows { Get-ApiPoolReservationCost -Model $tm -BodyBytes 6000 -MessageCount 1 -MaxTokens 10 } 'Reservation/AboveTopTierRefused' -ExpectedCode 'PRICING_UNKNOWN'

    # Reservation must bound the actual cost for any usage consistent with the byte bound.
    $bodyBytes = 50000
    $msgCount = 3
    $maxTokens = 2000
    foreach ($m in @($opus, $sonnet)) {
        $reserved = Get-ApiPoolReservationCost -Model $m -BodyBytes $bodyBytes -MessageCount $msgCount -MaxTokens $maxTokens
        $usages = @(
            (New-PricingUsage -In 50000 -Out 2000),
            (New-PricingUsage -In 0 -Out 2000 -Cc 50000),
            (New-PricingUsage -In 0 -Out 2000 -Cr 50000),
            (New-PricingUsage -In 20000 -Out 2000 -Cc 25000 -Cr 5000),
            (New-PricingUsage -In 10 -Out 2000 -Cc 49000 -Breakdown @{ ephemeral_5m_input_tokens = 40000; ephemeral_1h_input_tokens = 9000 }),
            (New-PricingUsage -In 0 -Out 0)
        )
        $index = 0
        foreach ($u in $usages) {
            $actual = Get-ApiPoolActualCost -Model $m -Usage $u
            Assert-ApiPoolTrue ($reserved -ge $actual) ('Reservation/BoundsActual/{0}/{1}' -f $m.Id, $index) ('reserved {0} < actual {1}' -f $reserved, $actual)
            $index++
        }
    }
    $reservedT = Get-ApiPoolReservationCost -Model $tm -BodyBytes 3000 -MessageCount 1 -MaxTokens 500
    Assert-ApiPoolTrue ($reservedT -ge (Get-ApiPoolActualCost -Model $tm -Usage (New-PricingUsage -In 3000 -Out 500))) 'Reservation/BoundsActual/TieredModel'
    $reservedLow = Get-ApiPoolReservationCost -Model $tm -BodyBytes 100 -MessageCount 1 -MaxTokens 500
    Assert-ApiPoolTrue ($reservedLow -ge (Get-ApiPoolActualCost -Model $tm -Usage (New-PricingUsage -In 100 -Out 500))) 'Reservation/BoundsActual/TieredLowTier'

    # ---------------- F5 ARCH-002: registry schemaVersion ----------------
    $shippedRegText = [System.IO.File]::ReadAllText((Join-Path $script:ConfigRoot 'models.json'))
    $svRegIdx = 0
    foreach ($svJson in @('2', '0', '"1"', '1.5', 'null')) {
        $svRegIdx++
        $svRegPath = Join-Path $pricingSandbox ('sv-registry-' + $svRegIdx + '.json')
        [System.IO.File]::WriteAllText($svRegPath, ($shippedRegText -replace '"schemaVersion":\s*1', ('"schemaVersion": ' + $svJson)))
        Assert-ApiPoolThrows { Import-ApiPoolModelRegistry -Path $svRegPath } ('Registry/SchemaVersionUnsupported/' + $svJson) -ExpectedCode 'CONFIG_INVALID'
    }
    $svRegMissing = Join-Path $pricingSandbox 'sv-registry-missing.json'
    [System.IO.File]::WriteAllText($svRegMissing, ($shippedRegText -replace '"schemaVersion":\s*1,', ''))
    Assert-ApiPoolThrows { Import-ApiPoolModelRegistry -Path $svRegMissing } 'Registry/SchemaVersionMissing' -ExpectedCode 'CONFIG_INVALID'
    Assert-ApiPoolEqual 1 $registry.SchemaVersion 'Registry/ShippedSchemaVersionIsOne'
}
finally {
    Remove-ApiPoolTestSandbox -Path $pricingSandbox
}
