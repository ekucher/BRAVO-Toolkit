[CmdletBinding()]
param(
    [string]$ArtifactRoot = $PSScriptRoot,
    [switch]$Quiet
)

# Test-BRAVOConfigV2PilotArtifact.ps1 — canonical верифікатор pilot-
# артефакту. Викликається ОБОВ'ЯЗКОВО перед будь-якою pilot-операцією
# (Start-BRAVOConfigV2Pilot.ps1 -Preflight викликає цей скрипт сам).
#
# FAIL CLOSED: будь-яка розбіжність маніфесту/hash/відсутній файл ->
# exit 1. Жодна mutating-операція не має права продовжуватись після
# провалу цієї перевірки.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function private:Write-BRAVOPilotVerifyLine {
    param([string]$Text)
    if (-not $Quiet) { Write-Host $Text }
}

try {
    $resolvedRoot = (Resolve-Path -LiteralPath $ArtifactRoot -ErrorAction Stop).ProviderPath

    $manifestPath = Join-Path $resolvedRoot 'manifest\PILOT_MANIFEST.json'
    $hashesPath = Join-Path $resolvedRoot 'manifest\SHA256SUMS.json'

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "PILOT_ARTIFACT_INVALID: не знайдено $manifestPath."
    }
    if (-not (Test-Path -LiteralPath $hashesPath -PathType Leaf)) {
        throw "PILOT_ARTIFACT_INVALID: не знайдено $hashesPath."
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $hashes = Get-Content -LiteralPath $hashesPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if ([string]$manifest.artifactType -ne 'BRAVO.ConfigurationV2.Pilot') {
        throw "PILOT_ARTIFACT_INVALID: PILOT_MANIFEST.json.artifactType очікувалось 'BRAVO.ConfigurationV2.Pilot', отримано '$($manifest.artifactType)'."
    }
    if ([int]$manifest.artifactSchemaVersion -ne 1) {
        throw "PILOT_ARTIFACT_INVALID: непідтримувана artifactSchemaVersion '$($manifest.artifactSchemaVersion)' — очікувалась 1."
    }
    if ($manifest.sourceCommit -notmatch '^[0-9a-f]{40}$') {
        throw "PILOT_ARTIFACT_INVALID: sourceCommit ('$($manifest.sourceCommit)') не є повним 40-символьним git-hash — артефакт без провенансу."
    }

    Write-BRAVOPilotVerifyLine "artifactId:      $($manifest.artifactId)"
    Write-BRAVOPilotVerifyLine "packageVersion:  $($manifest.packageVersion)"
    Write-BRAVOPilotVerifyLine "sourceCommit:    $($manifest.sourceCommit)"
    Write-BRAVOPilotVerifyLine "buildId:         $($manifest.buildId)"

    # Секретна безпека маніфесту: жодних значень із sensitive-категорій.
    $manifestText = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
    foreach ($forbidden in @('password', 'passwd', 'token', 'secret', 'webhook', 'credential', 'authorization')) {
        if ($manifestText -match "(?i)`"$forbidden") {
            throw "PILOT_ARTIFACT_INVALID: PILOT_MANIFEST.json містить заборонений ключ, що відповідає категорії '$forbidden'."
        }
    }

    $missing = New-Object System.Collections.Generic.List[string]
    $mismatched = New-Object System.Collections.Generic.List[string]
    $checkedCount = 0

    foreach ($entry in $hashes.PSObject.Properties) {
        $relativePath = $entry.Name
        $expectedHash = [string]$entry.Value

        # Захист від path traversal у самому маніфесті: відносний шлях не
        # повинен виходити за межі $resolvedRoot.
        $candidatePath = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $relativePath))
        if (-not $candidatePath.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "PILOT_ARTIFACT_INVALID: запис SHA256SUMS.json '$relativePath' виходить за межі кореня артефакту (можливий path traversal)."
        }

        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            $missing.Add($relativePath)
            continue
        }

        $actualHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash
        if ($actualHash -ne $expectedHash.ToUpperInvariant()) {
            $mismatched.Add($relativePath)
            continue
        }
        $checkedCount++
    }

    # Кожен файл артефакту (крім самого manifest/*) мусить бути в SHA256SUMS.json —
    # інакше непорахований файл міг би підмінитись непомітно.
    $allFiles = @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File |
        Where-Object { $_.FullName -notlike (Join-Path $resolvedRoot 'manifest\*') } |
        ForEach-Object { $_.FullName.Substring($resolvedRoot.Length + 1).Replace('\', '/') })
    $hashedFiles = @($hashes.PSObject.Properties | ForEach-Object { $_.Name.Replace('\', '/') })
    $unhashed = @($allFiles | Where-Object { $hashedFiles -notcontains $_ })

    if ($missing.Count -gt 0) {
        throw "PILOT_ARTIFACT_INVALID: відсутні файли, перелічені в SHA256SUMS.json: $([string]::Join(', ', $missing))"
    }
    if ($mismatched.Count -gt 0) {
        throw "PILOT_ARTIFACT_INVALID: SHA-256 не збігається для: $([string]::Join(', ', $mismatched)) — артефакт пошкоджений або підмінений."
    }
    if ($unhashed.Count -gt 0) {
        throw "PILOT_ARTIFACT_INVALID: файли присутні, але НЕ перелічені в SHA256SUMS.json (непораховані): $([string]::Join(', ', $unhashed))"
    }

    # Обов'язкові файли артефакту.
    $requiredFiles = @(
        'Start-BRAVOConfigV2Pilot.ps1',
        'BRAVOConfigV2Pilot.Runtime.ps1',
        'Test-BRAVOConfigV2PilotArtifact.ps1',
        'README.txt',
        'docs\BRAVO_CONFIG_V2_PILOT_RUNBOOK.md'
    )
    $missingRequired = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $resolvedRoot $_) -PathType Leaf) })
    if ($missingRequired.Count -gt 0) {
        throw "PILOT_ARTIFACT_INVALID: відсутні обов'язкові файли артефакту: $([string]::Join(', ', $missingRequired))"
    }

    # PowerShell-сумісність: усі .ps1 у артефакті мусять парситись без
    # помилок (базова, дешева перевірка — не заміна PSScriptAnalyzer).
    $psFiles = @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Filter '*.ps1' -File)
    $parseFailures = New-Object System.Collections.Generic.List[string]
    foreach ($psFile in $psFiles) {
        $tokens = $null; $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($psFile.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
        if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
            $parseFailures.Add($psFile.Name)
        }
    }
    if ($parseFailures.Count -gt 0) {
        throw "PILOT_ARTIFACT_INVALID: PowerShell-файли не парсяться: $([string]::Join(', ', $parseFailures))"
    }

    Write-BRAVOPilotVerifyLine "Файлів перевірено (SHA-256): $checkedCount"
    Write-BRAVOPilotVerifyLine "PowerShell-файлів (parse OK): $($psFiles.Count)"
    Write-BRAVOPilotVerifyLine '[SUCCESS] Артефакт цілісний і провенанс перевірено.'
    exit 0
} catch {
    $ErrorActionPreference = 'Continue'
    Write-Error $_.Exception.Message
    exit 1
}
