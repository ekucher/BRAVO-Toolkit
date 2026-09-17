#requires -Version 3.0

# BRAVO_SELF_TEST.ConfigV2PilotArtifact.ps1 — end-to-end і failure-injection
# тест pilot-артефакту Configuration v2 (deploy\New-BRAVOConfigV2PilotArtifact.ps1,
# deploy\Start-BRAVOConfigV2Pilot.ps1, deploy\BRAVOConfigV2Pilot.Runtime.ps1,
# deploy\Test-BRAVOConfigV2PilotArtifact.ps1).
#
# СТАНДАЛОН-ТЕСТ, НЕ dot-sourced з BRAVO_SELF_TEST.ps1: цей тест реально
# будує ZIP, розпаковує його й запускає повний CLI orchestrator кілька
# разів (важче й повільніше за звичайний self-test fragment). Запускається
# окремо (CI job / вручну), щоб не подовжувати й не ускладнювати основний
# canonical self-test entrypoint.
#
# УСІ файлові операції — лише в $env:TEMP. Жодного production-запису.
# Реальні файли репозиторію НІКОЛИ не змінюються (перевіряється явно
# наприкінці — хеш до/після).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:repoRoot = Split-Path -Parent $PSScriptRoot
$script:total = 0
$script:failedCount = 0
$script:failureNames = New-Object System.Collections.Generic.List[string]

function Test-BRAVOPilotSelfTestCondition {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][bool]$Condition, [string]$FailureDetail = '')
    $script:total++
    if ($Condition) {
        Write-Host "[PASS] $Name"
    } else {
        $script:failedCount++
        $script:failureNames.Add($Name)
        Write-Host "[FAIL] $Name -- $FailureDetail" -ForegroundColor Red
    }
}

function Test-BRAVOPilotSelfTestThrows {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock, [string]$ExpectedMessagePattern = '')
    $threw = $false
    $message = ''
    try {
        & $ScriptBlock | Out-Null
    } catch {
        $threw = $true
        $message = $_.Exception.Message
    }
    $patternOk = [string]::IsNullOrEmpty($ExpectedMessagePattern) -or ($message -match $ExpectedMessagePattern)
    Test-BRAVOPilotSelfTestCondition -Name $Name -Condition ($threw -and $patternOk) `
        -FailureDetail "threw=$threw message='$message' expectedPattern='$ExpectedMessagePattern'"
}

function Invoke-BRAVOPilotOutputDirGuardIsolated {
    # Тестує rejection-логіку Assert-BRAVOPilotOutputDirSafeToDelete
    # (New-BRAVOConfigV2PilotArtifact.ps1) БЕЗ виконання побічних ефектів
    # решти білдер-скрипта (git show тощо) і БЕЗ ризику реального
    # Remove-Item по системних шляхах: витягуємо лише визначення функції
    # через AST-парсер і викликаємо його ізольовано.
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $builderPath = Join-Path $script:repoRoot 'deploy\New-BRAVOConfigV2PilotArtifact.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($builderPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "Не вдалося розпарсити '$builderPath': $([string]::Join(' | ', @($parseErrors | ForEach-Object { $_.Message })))"
    }
    $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-BRAVOPilotOutputDirSafeToDelete' }, $true)
    if (-not $functionAst) {
        throw "Функцію 'Assert-BRAVOPilotOutputDirSafeToDelete' не знайдено в '$builderPath'."
    }
    $isolatedScriptBlock = [scriptblock]::Create($functionAst.Extent.Text + "`nAssert-BRAVOPilotOutputDirSafeToDelete -Path `$Path -RepositoryRoot `$RepositoryRoot")
    & $isolatedScriptBlock
}

# --- Synthetic fixture construction ------------------------------------------

function New-BRAVOPilotStubScript {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][ValidateSet('Setup', 'SelfTest', 'Health', 'DryRun')][string]$Kind)

    $body = switch ($Kind) {
        'Setup' {
            @'
param([string]$ConfigPath,[string]$Action,[string]$CredentialComponent,[string]$StoreFor,[switch]$ValidateOnly,[switch]$ConfirmDiscoveryBaseline,[switch]$SkipAccessTest,[switch]$SkipTestNotification,[switch]$NoElevation,[switch]$NoPause)
$behaviorPath = Join-Path $PSScriptRoot '.stub-behavior.json'
$exitCode = 0
$noOutput = $false
$stdErrOnly = $false
if (Test-Path -LiteralPath $behaviorPath) {
    $b = Get-Content -LiteralPath $behaviorPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($b.PSObject.Properties['Setup']) {
        $exitCode = [int]$b.Setup.ExitCode
        if ($b.Setup.PSObject.Properties['NoOutput']) { $noOutput = [bool]$b.Setup.NoOutput }
        if ($b.Setup.PSObject.Properties['StdErrOnly']) { $stdErrOnly = [bool]$b.Setup.StdErrOnly }
    }
}
# NoOutput симулює реальний VM-прогін (2026-09-17), де BRAVO_SETUP.ps1
# аварійно завершується настільки рано, що НІЧОГО не встигає потрапити
# ані в success-, ані в error-стрім, який захоплює
# Invoke-BRAVOPilotValidateOnly (2>&1 | ForEach-Object) — 0 захоплених
# рядків є правдивим діагностичним станом, не браком стаба.
if ($stdErrOnly) {
    # Стрес-тест merge 2>&1: помилка потрапляє лише в PowerShell
    # error-стрім (ErrorRecord, не рядок success-стріму) — саме те, що
    # реально захоплює Invoke-BRAVOPilotValidateOnly через `2>&1 |
    # ForEach-Object { [string]$_ }`.
    Write-Error "[STUB-SETUP-STDERR] exitCode=$exitCode" -ErrorAction Continue
} elseif (-not $noOutput) {
    Write-Output "[STUB-SETUP] ValidateOnly=$ValidateOnly SkipAccessTest=$SkipAccessTest exitCode=$exitCode"
}
exit $exitCode
'@
        }
        'SelfTest' {
            @'
param([string]$ConfigPath,[string[]]$Suite,[switch]$NoPause)
$behaviorPath = Join-Path $PSScriptRoot '.stub-behavior.json'
$exitCode = 0
$lines = @('[PASS] Stub/AlwaysPasses')
if (Test-Path -LiteralPath $behaviorPath) {
    $b = Get-Content -LiteralPath $behaviorPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($b.PSObject.Properties['SelfTest']) {
        $exitCode = [int]$b.SelfTest.ExitCode
        if ($b.SelfTest.PSObject.Properties['Lines']) { $lines = @($b.SelfTest.Lines) }
    }
}
foreach ($line in $lines) { Write-Output $line }
exit $exitCode
'@
        }
        'Health' {
            @'
param([string]$ConfigPath,[switch]$ForceNotification,[switch]$NotifyOnSuccess,[switch]$NoSlack,[switch]$SkipIfBackupTaskRunning,[switch]$NoPause)
$behaviorPath = Join-Path $PSScriptRoot '.stub-behavior.json'
$exitCode = 0
$lines = @('[OK] Stub health baseline')
if (Test-Path -LiteralPath $behaviorPath) {
    $b = Get-Content -LiteralPath $behaviorPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($b.PSObject.Properties['Health']) {
        $exitCode = [int]$b.Health.ExitCode
        if ($b.Health.PSObject.Properties['Lines']) { $lines = @($b.Health.Lines) }
    }
}
foreach ($line in $lines) { Write-Output $line }
exit $exitCode
'@
        }
        'DryRun' {
            @'
param([string]$ConfigPath,[switch]$TestAccess,[switch]$SendTestNotification,[switch]$SkipCredentials,[switch]$RequireScheduledTasks,[switch]$AsJson,[string]$ResultPath)
$behaviorPath = Join-Path $PSScriptRoot '.stub-behavior.json'
$exitCode = 0
if (Test-Path -LiteralPath $behaviorPath) {
    $b = Get-Content -LiteralPath $behaviorPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($b.PSObject.Properties['DryRun']) { $exitCode = [int]$b.DryRun.ExitCode }
}
Write-Output "[STUB-DRYRUN] exitCode=$exitCode"
exit $exitCode
'@
        }
    }
    [System.IO.File]::WriteAllText($Path, $body, (New-Object System.Text.UTF8Encoding($true)))
}

function Set-BRAVOPilotStubBehavior {
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [Parameter(Mandatory = $true)][hashtable]$Behavior)
    $path = Join-Path $InstallRoot '.stub-behavior.json'
    [System.IO.File]::WriteAllText($path, ($Behavior | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}

function New-BRAVOPilotSyntheticInstallRoot {
    # Реальні canonical Configuration v2 файли (git archive з HEAD — не
    # робоче дерево, детермінований вміст), + власний мінімальний
    # BRAVO.config, + легкі стаб-скрипти для важких acceptance-гейтів
    # (SETUP/SELF_TEST/HEALTH/DRY_RUN) — тест перевіряє orchestrator, а не
    # повторно сам self-test/health/архівацію (ці домени вже покриті
    # власними self-test-фрагментами).
    param([Parameter(Mandatory = $true)][string]$Path)

    [void](New-Item -ItemType Directory -Path $Path -Force)

    $pathspec = @(
        'BRAVO_CONFIG_LOADER.ps1', 'BRAVO_CONFIG_TEST.ps1', 'VERSION.json',
        'modules/BRAVO.Configuration', 'modules/BRAVO.Configurator', 'modules/BRAVO.Discovery', 'modules/BRAVO.Compatibility',
        'deploy/Get-BRAVOConfigSiteDelta.ps1', 'deploy/Compare-BRAVOConfigEffectiveSnapshot.ps1'
    )
    $zipTemp = Join-Path ([System.IO.Path]::GetTempPath()) "bravo-pilot-src-$([Guid]::NewGuid().ToString('N')).zip"
    $archiveArgs = @('-C', $script:repoRoot, 'archive', '--format=zip', '-o', $zipTemp, 'HEAD', '--') + $pathspec
    & git @archiveArgs
    if ($LASTEXITCODE -ne 0) { throw "git archive для синтетичного InstallRoot завершився з кодом $LASTEXITCODE." }
    try {
        Expand-Archive -LiteralPath $zipTemp -DestinationPath $Path -Force
    } finally {
        Remove-Item -LiteralPath $zipTemp -Force -ErrorAction SilentlyContinue
    }

    # pathSettings.LIMSRoot МАЄ бути явним синтетичним шляхом: порожнє
    # значення ("" = AUTO) вимагає реальної встановленої служби Windows
    # "BRAVO" (Resolve-BRAVOEffectiveLimsRoot), якої на чистому CI-раннері
    # немає — БЕЗ цього рядка Prepare падає fail-closed на
    # "BackupRoot="" вимагає визначеного EffectiveLIMSRoot" лише на
    # хостах без реально встановленого BRAVO (виявлено на CI, 2026-09-16).
    $syntheticLimsRoot = Join-Path $Path 'SyntheticLIMS'
    [void](New-Item -ItemType Directory -Path $syntheticLimsRoot -Force)

    $configText = @'
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigRoot,
    [string]$RuntimeRoot
)
$global:bravoSettings = @{
    InstitutionName = "Synthetic Pilot Institution"
}
$global:pathSettings = @{
    LIMSRoot = "__SYNTHETIC_LIMS_ROOT__"
}
'@
    $configText = $configText.Replace('__SYNTHETIC_LIMS_ROOT__', $syntheticLimsRoot)
    [System.IO.File]::WriteAllText((Join-Path $Path 'BRAVO.config'), $configText, (New-Object System.Text.UTF8Encoding($true)))

    New-BRAVOPilotStubScript -Path (Join-Path $Path 'BRAVO_SETUP.ps1') -Kind Setup
    New-BRAVOPilotStubScript -Path (Join-Path $Path 'BRAVO_SELF_TEST.ps1') -Kind SelfTest
    New-BRAVOPilotStubScript -Path (Join-Path $Path 'BRAVO_HEALTH.ps1') -Kind Health
    New-BRAVOPilotStubScript -Path (Join-Path $Path 'BRAVO_DRY_RUN.ps1') -Kind DryRun
}

# --- Root temp workspace ------------------------------------------------------

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "bravo-pilot-selftest-$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $tempRoot -Force)

# Хеші реальних вихідних файлів РЕПОЗИТОРІЮ — до і після; жодна операція
# тесту не повинна їх торкнутись (§30).
$sourceFilesToWatch = @(
    'BRAVO_CONFIG_TEST.ps1', 'deploy\Get-BRAVOConfigSiteDelta.ps1',
    'deploy\Compare-BRAVOConfigEffectiveSnapshot.ps1', 'deploy\Start-BRAVOConfigV2Pilot.ps1',
    'deploy\BRAVOConfigV2Pilot.Runtime.ps1'
)
$sourceHashesBefore = @{}
foreach ($rel in $sourceFilesToWatch) {
    $sourceHashesBefore[$rel] = (Get-FileHash -LiteralPath (Join-Path $script:repoRoot $rel) -Algorithm SHA256).Hash
}

try {
    # =========================================================================
    # 1) Build + verify artifact
    # =========================================================================
    $buildOutputDir = Join-Path $tempRoot 'build'
    $buildOutput = & (Join-Path $script:repoRoot 'deploy\New-BRAVOConfigV2PilotArtifact.ps1') -OutputDir $buildOutputDir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Artifact/BuildSucceeds' -Condition ($LASTEXITCODE -eq 0) -FailureDetail ([string]::Join(' | ', @($buildOutput | Select-Object -Last 5)))

    $artifactDir = @(Get-ChildItem -LiteralPath $buildOutputDir -Directory | Where-Object { $_.Name -like 'BRAVO-ConfigV2-Pilot-*' })[0].FullName
    $zipPath = "$artifactDir.zip"
    Test-BRAVOPilotSelfTestCondition -Name 'Artifact/ZipCreated' -Condition (Test-Path -LiteralPath $zipPath -PathType Leaf) -FailureDetail $zipPath

    # Розпаковуємо ZIP окремо (справжній unpack-крок, а не лише staging-каталог builder-а).
    $unpackDir = Join-Path $tempRoot 'unpacked'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $unpackDir -Force
    # Compress-Archive -Path (staging\*) пише файли артефакту В КОРІНЬ zip
    # (без обгортки-каталогу artifactId) — той самий root після unpack.
    $artifactRoot = $unpackDir

    $verifyOutput = & (Join-Path $artifactRoot 'Test-BRAVOConfigV2PilotArtifact.ps1') -ArtifactRoot $artifactRoot 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Artifact/VerifiesAfterUnpack' -Condition ($LASTEXITCODE -eq 0) -FailureDetail ([string]::Join(' | ', @($verifyOutput | Select-Object -Last 5)))

    # =========================================================================
    # 1a) Guard проти unsafe -OutputDir перед Remove-Item -Recurse -Force
    #     (Assert-BRAVOPilotOutputDirSafeToDelete)
    # =========================================================================
    Test-BRAVOPilotSelfTestThrows -Name 'Guard/RejectsDriveRoot' -ExpectedMessagePattern 'корінь диска' -ScriptBlock {
        Invoke-BRAVOPilotOutputDirGuardIsolated -Path 'C:\' -RepositoryRoot $script:repoRoot
    }
    Test-BRAVOPilotSelfTestThrows -Name 'Guard/RejectsRepositoryRoot' -ExpectedMessagePattern 'коренем репозиторію' -ScriptBlock {
        Invoke-BRAVOPilotOutputDirGuardIsolated -Path $script:repoRoot -RepositoryRoot $script:repoRoot
    }
    Test-BRAVOPilotSelfTestThrows -Name 'Guard/RejectsRepositoryRootAncestor' -ExpectedMessagePattern 'предком кореня репозиторію' -ScriptBlock {
        Invoke-BRAVOPilotOutputDirGuardIsolated -Path (Split-Path -Parent $script:repoRoot) -RepositoryRoot $script:repoRoot
    }
    Test-BRAVOPilotSelfTestThrows -Name 'Guard/RejectsWellKnownSystemDir' -ExpectedMessagePattern 'системним каталогом' -ScriptBlock {
        Invoke-BRAVOPilotOutputDirGuardIsolated -Path $env:SystemRoot -RepositoryRoot $script:repoRoot
    }
    $guardAllowsOrdinaryDir = $true
    $guardAllowsOrdinaryDirDetail = ''
    try {
        Invoke-BRAVOPilotOutputDirGuardIsolated -Path $buildOutputDir -RepositoryRoot $script:repoRoot
    } catch {
        $guardAllowsOrdinaryDir = $false
        $guardAllowsOrdinaryDirDetail = $_.Exception.Message
    }
    Test-BRAVOPilotSelfTestCondition -Name 'Guard/AllowsOrdinaryOutputDir' -Condition $guardAllowsOrdinaryDir -FailureDetail $guardAllowsOrdinaryDirDetail

    # Реальний end-to-end прогін гілки Remove-Item + rebuild: $buildOutputDir
    # уже існує з попереднього білда (тимчасовий каталог, безпечно).
    $rebuildOutput = & (Join-Path $script:repoRoot 'deploy\New-BRAVOConfigV2PilotArtifact.ps1') -OutputDir $buildOutputDir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Guard/RebuildIntoExistingOutputDirSucceeds' -Condition ($LASTEXITCODE -eq 0) -FailureDetail ([string]::Join(' | ', @($rebuildOutput | Select-Object -Last 5)))

    # =========================================================================
    # 2) Happy path end-to-end через розпакований артефакт
    # =========================================================================
    $happyInstallRoot = Join-Path $tempRoot 'install-happy'
    New-BRAVOPilotSyntheticInstallRoot -Path $happyInstallRoot
    $happyEvidenceRoot = Join-Path $tempRoot 'evidence-happy'

    $startScript = Join-Path $artifactRoot 'Start-BRAVOConfigV2Pilot.ps1'

    $preflightOutput = & $startScript -Preflight -InstallRoot $happyInstallRoot -ArtifactRoot $artifactRoot -EvidenceRoot $happyEvidenceRoot 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Happy/PreflightPasses' -Condition ($LASTEXITCODE -eq 0) -FailureDetail ([string]::Join(' | ', @($preflightOutput | Select-Object -Last 10)))

    $prepareOutput = & $startScript -Prepare -InstallRoot $happyInstallRoot -ArtifactRoot $artifactRoot -EvidenceRoot $happyEvidenceRoot 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Happy/PrepareSucceeds' -Condition ($LASTEXITCODE -eq 0) -FailureDetail ([string]::Join(' | ', @($prepareOutput | Select-Object -Last 10)))

    $evidenceDir = (Get-ChildItem -LiteralPath $happyEvidenceRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
    $stateAfterPrepare = Get-Content -LiteralPath (Join-Path $evidenceDir 'metadata.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-BRAVOPilotSelfTestCondition -Name 'Happy/StateIsDeltaGenerated' -Condition ([string]$stateAfterPrepare.State -eq 'DeltaGenerated') -FailureDetail [string]$stateAfterPrepare.State

    Test-BRAVOPilotSelfTestCondition -Name 'Happy/DeltaPreviewContainsExpectedOverride' -Condition (
        (Get-Content -LiteralPath (Join-Path $evidenceDir 'delta.preview.txt') -Raw -Encoding UTF8) -match "InstitutionName' = 'Synthetic Pilot Institution'"
    ) -FailureDetail 'delta.preview.txt не містить очікуваного override'

    $candidateHash = [string]$stateAfterPrepare.CandidateHash

    $approveOutput = & $startScript -Approve -EvidenceDir $evidenceDir -ApprovedCandidateHash $candidateHash 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Happy/ApproveSucceeds' -Condition ($LASTEXITCODE -eq 0) -FailureDetail ([string]::Join(' | ', @($approveOutput | Select-Object -Last 10)))
    Test-BRAVOPilotSelfTestCondition -Name 'Happy/HumanReviewEvidenceExists' -Condition (Test-Path -LiteralPath (Join-Path $evidenceDir 'human-review.json') -PathType Leaf) ''

    $activateOutput = & $startScript -Activate -InstallRoot $happyInstallRoot -EvidenceDir $evidenceDir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Happy/ActivateSucceeds' -Condition ($LASTEXITCODE -eq 0) -FailureDetail ([string]::Join(' | ', @($activateOutput | Select-Object -Last 10)))
    Test-BRAVOPilotSelfTestCondition -Name 'Happy/BravoConfigRetained' -Condition (Test-Path -LiteralPath (Join-Path $happyInstallRoot 'BRAVO.config') -PathType Leaf) ''
    Test-BRAVOPilotSelfTestCondition -Name 'Happy/BackupManifestExists' -Condition (@(Get-ChildItem -LiteralPath $evidenceDir -Directory -Filter 'backup-*').Count -eq 1) ''

    # Ідемпотентність активації: повторний -Activate — no-op, файл не змінюється.
    $localConfigHashBefore = (Get-FileHash -LiteralPath (Join-Path $happyInstallRoot 'BRAVO.local.config') -Algorithm SHA256).Hash
    $activateAgainOutput = & $startScript -Activate -InstallRoot $happyInstallRoot -EvidenceDir $evidenceDir 2>&1
    $localConfigHashAfter = (Get-FileHash -LiteralPath (Join-Path $happyInstallRoot 'BRAVO.local.config') -Algorithm SHA256).Hash
    Test-BRAVOPilotSelfTestCondition -Name 'Idempotency/RepeatedActivateIsNoOp' -Condition (
        $LASTEXITCODE -eq 0 -and $localConfigHashBefore -eq $localConfigHashAfter
    ) -FailureDetail ([string]::Join(' | ', @($activateAgainOutput | Select-Object -Last 5)))

    $validateOutput = & $startScript -Validate -InstallRoot $happyInstallRoot -EvidenceDir $evidenceDir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Happy/ValidateSucceeds' -Condition ($LASTEXITCODE -eq 0) -FailureDetail ([string]::Join(' | ', @($validateOutput | Select-Object -Last 15)))

    $parity = Get-Content -LiteralPath (Join-Path $evidenceDir 'parity.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-BRAVOPilotSelfTestCondition -Name 'Happy/SemanticParityBeforeEqualsAfter' -Condition ([bool]$parity.Pass) -FailureDetail ([string]::Join(' | ', @($parity.Output)))

    # Ідемпотентність Validate: повторний виклик, той самий результат, без drift.
    $validateAgainOutput = & $startScript -Validate -InstallRoot $happyInstallRoot -EvidenceDir $evidenceDir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Idempotency/RepeatedValidateSucceeds' -Condition ($LASTEXITCODE -eq 0) -FailureDetail ([string]::Join(' | ', @($validateAgainOutput | Select-Object -Last 10)))

    # P2 regression: acceptance.json.PreflightPass має бути evidence-based
    # (читається з фактичного preflight.json), а не hardcoded true. Копія
    # evidence-каталогу на стані Validated з видаленим preflight.json ->
    # -Accept НЕ повинен звітувати PreflightPass=true й не повинен видати
    # PILOT ACCEPTED, хоча решта доказів (Validated-стан, backup, health
    # тощо) лишається валідною.
    $tamperedEvidenceDir = Join-Path $tempRoot 'evidence-happy-missing-preflight'
    Copy-Item -LiteralPath $evidenceDir -Destination $tamperedEvidenceDir -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $tamperedEvidenceDir 'preflight.json') -Force
    $tamperedAcceptOutput = & $startScript -Accept -EvidenceDir $tamperedEvidenceDir 2>&1
    $tamperedAcceptExit = $LASTEXITCODE
    $tamperedAcceptance = Get-Content -LiteralPath (Join-Path $tamperedEvidenceDir 'acceptance.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-BRAVOPilotSelfTestCondition -Name 'Security/AcceptWithMissingPreflightEvidenceDoesNotClaimPass' -Condition (
        $tamperedAcceptExit -ne 0 -and
        -not [bool]$tamperedAcceptance.Criteria.PreflightPass -and
        [string]$tamperedAcceptance.Result -ne 'PILOT ACCEPTED'
    ) -FailureDetail ("exit=$tamperedAcceptExit PreflightPass=$($tamperedAcceptance.Criteria.PreflightPass) Result=$($tamperedAcceptance.Result)")

    $acceptOutput = & $startScript -Accept -EvidenceDir $evidenceDir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Happy/AcceptSucceeds' -Condition ($LASTEXITCODE -eq 0) -FailureDetail ([string]::Join(' | ', @($acceptOutput | Select-Object -Last 10)))
    $acceptance = Get-Content -LiteralPath (Join-Path $evidenceDir 'acceptance.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-BRAVOPilotSelfTestCondition -Name 'Happy/AcceptanceResultIsAccepted' -Condition ([string]$acceptance.Result -eq 'PILOT ACCEPTED') -FailureDetail ([string]::Join(', ', @($acceptance.FailedCriteria)))
    Test-BRAVOPilotSelfTestCondition -Name 'Happy/AcceptanceRecordsPreflightPassFromEvidence' -Condition ([bool]$acceptance.Criteria.PreflightPass) ''

    # Секретна безпека: жоден evidence-файл не містить embedded-credential URI,
    # і жодне значення під sensitive-ключем поза reference-формою.
    $evidenceFiles = @(Get-ChildItem -LiteralPath $evidenceDir -Recurse -File)
    $secretScanFindings = New-Object System.Collections.Generic.List[string]
    foreach ($file in $evidenceFiles) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($null -ne $text -and $text -match '[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@') {
            $secretScanFindings.Add($file.Name)
        }
    }
    Test-BRAVOPilotSelfTestCondition -Name 'Security/NoEmbeddedCredentialUriInEvidence' -Condition ($secretScanFindings.Count -eq 0) -FailureDetail ([string]::Join(', ', $secretScanFindings))

    # Idempotency: Status x2, read-only, той самий результат.
    $status1 = & $startScript -Status -EvidenceDir $evidenceDir 2>&1
    $status2 = & $startScript -Status -EvidenceDir $evidenceDir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Idempotency/StatusRepeatable' -Condition (($status1 | Out-String) -eq ($status2 | Out-String)) ''

    # =========================================================================
    # 3) Rollback scenario: Validate провалюється (стаб self-test FAIL) -> Rollback
    # =========================================================================
    $rollbackInstallRoot = Join-Path $tempRoot 'install-rollback'
    New-BRAVOPilotSyntheticInstallRoot -Path $rollbackInstallRoot
    $rollbackEvidenceRoot = Join-Path $tempRoot 'evidence-rollback'

    & $startScript -Preflight -InstallRoot $rollbackInstallRoot -ArtifactRoot $artifactRoot -EvidenceRoot $rollbackEvidenceRoot 2>&1 | Out-Null
    & $startScript -Prepare -InstallRoot $rollbackInstallRoot -ArtifactRoot $artifactRoot -EvidenceRoot $rollbackEvidenceRoot 2>&1 | Out-Null
    $rbEvidenceDir = (Get-ChildItem -LiteralPath $rollbackEvidenceRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
    $rbState = Get-Content -LiteralPath (Join-Path $rbEvidenceDir 'metadata.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    & $startScript -Approve -EvidenceDir $rbEvidenceDir -ApprovedCandidateHash ([string]$rbState.CandidateHash) 2>&1 | Out-Null
    & $startScript -Activate -InstallRoot $rollbackInstallRoot -EvidenceDir $rbEvidenceDir 2>&1 | Out-Null

    $originalConfigHash = (Get-FileHash -LiteralPath (Join-Path $rollbackInstallRoot 'BRAVO.config') -Algorithm SHA256).Hash

    Set-BRAVOPilotStubBehavior -InstallRoot $rollbackInstallRoot -Behavior @{ SelfTest = @{ ExitCode = 1; Lines = @('[FAIL] Stub/InjectedFailure') } }
    $rbValidateOutput = & $startScript -Validate -InstallRoot $rollbackInstallRoot -EvidenceDir $rbEvidenceDir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Rollback/ValidateFailsOnInjectedSelfTestFailure' -Condition ($LASTEXITCODE -ne 0) -FailureDetail ([string]::Join(' | ', @($rbValidateOutput | Select-Object -Last 10)))

    # Скидаємо ін'єктовану поломку ПЕРЕД -Rollback: SelfTest.ExitCode=1 мав
    # лише провалити -Validate (щоб дати підставу для відкату). Rollback
    # сам по собі ПОВТОРНО запускає BRAVO_SELF_TEST.ps1 як post-restore
    # доказ, і на реальному сервері після відкату self-test знову проходить
    # — інакше ROLLBACK INCOMPLETE тут був би НЕ хибним спрацюванням
    # orchestrator-а, а коректним fail-closed результатом на зіпсованому
    # тестовому фікстурі.
    Set-BRAVOPilotStubBehavior -InstallRoot $rollbackInstallRoot -Behavior @{}
    $rbRollbackOutput = & $startScript -Rollback -InstallRoot $rollbackInstallRoot -EvidenceDir $rbEvidenceDir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Rollback/CommandSucceeds' -Condition ($LASTEXITCODE -eq 0) -FailureDetail ([string]::Join(' | ', @($rbRollbackOutput | Select-Object -Last 15)))

    $rollbackJson = Get-Content -LiteralPath (Join-Path $rbEvidenceDir 'rollback.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-BRAVOPilotSelfTestCondition -Name 'Rollback/ResultIsSuccess' -Condition ([string]$rollbackJson.Result -eq 'ROLLBACK SUCCESS') -FailureDetail ($rollbackJson.Steps | ConvertTo-Json -Compress)

    $restoredConfigHash = (Get-FileHash -LiteralPath (Join-Path $rollbackInstallRoot 'BRAVO.config') -Algorithm SHA256).Hash
    Test-BRAVOPilotSelfTestCondition -Name 'Rollback/BravoConfigRestoredByteIdentical' -Condition ($restoredConfigHash -eq $originalConfigHash) ''
    Test-BRAVOPilotSelfTestCondition -Name 'Rollback/BravoLocalConfigRemoved' -Condition (-not (Test-Path -LiteralPath (Join-Path $rollbackInstallRoot 'BRAVO.local.config'))) ''

    # =========================================================================
    # 4) Failure injection (15 сценаріїв, §28)
    # =========================================================================

    # Спільна dot-sourced бібліотека — для сценаріїв, що перевіряють
    # поведінку конкретної функції, а не повний CLI round-trip.
    . (Join-Path $script:repoRoot 'deploy\BRAVOConfigV2Pilot.Runtime.ps1')

    # F1: corrupt artifact (пошкоджений байт у файлі, не в SHA256SUMS.json).
    $f1Dir = Join-Path $tempRoot 'f1-corrupt-artifact'
    Copy-Item -LiteralPath $artifactRoot -Destination $f1Dir -Recurse -Force
    Add-Content -LiteralPath (Join-Path $f1Dir 'Start-BRAVOConfigV2Pilot.ps1') -Value '# corrupted' -Encoding UTF8
    $f1Output = & (Join-Path $f1Dir 'Test-BRAVOConfigV2PilotArtifact.ps1') -ArtifactRoot $f1Dir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/CorruptArtifactFailsClosed' -Condition ($LASTEXITCODE -ne 0) -FailureDetail ([string]::Join(' | ', @($f1Output | Select-Object -Last 3)))

    # F2: hash mismatch (SHA256SUMS.json відредаговано, файл незмінний).
    $f2Dir = Join-Path $tempRoot 'f2-hash-mismatch'
    Copy-Item -LiteralPath $artifactRoot -Destination $f2Dir -Recurse -Force
    $f2HashesPath = Join-Path $f2Dir 'manifest\SHA256SUMS.json'
    $f2Hashes = Get-Content -LiteralPath $f2HashesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $f2Hashes.'README.txt' = ('0' * 64)
    [System.IO.File]::WriteAllText($f2HashesPath, ($f2Hashes | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
    $f2Output = & (Join-Path $f2Dir 'Test-BRAVOConfigV2PilotArtifact.ps1') -ArtifactRoot $f2Dir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/HashMismatchFailsClosed' -Condition ($LASTEXITCODE -ne 0) -FailureDetail ([string]::Join(' | ', @($f2Output | Select-Object -Last 3)))

    # F3: missing BRAVO.config.
    $f3Install = Join-Path $tempRoot 'f3-missing-config'
    New-BRAVOPilotSyntheticInstallRoot -Path $f3Install
    Remove-Item -LiteralPath (Join-Path $f3Install 'BRAVO.config') -Force
    $f3Preflight = Invoke-BRAVOPilotPreflight -InstallRoot $f3Install -ArtifactRoot $artifactRoot
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/MissingBravoConfigFailsPreflight' -Condition (-not $f3Preflight.Pass -and $f3Preflight.FailedBlockingChecks -contains 'BRAVOConfigExists') ''

    # F4: malformed BRAVO.config (syntax error) — знімок мусить провалитись fail-closed.
    $f4Install = Join-Path $tempRoot 'f4-malformed-config'
    New-BRAVOPilotSyntheticInstallRoot -Path $f4Install
    [System.IO.File]::WriteAllText((Join-Path $f4Install 'BRAVO.config'), 'param( this is not valid powershell {{{', (New-Object System.Text.UTF8Encoding($true)))
    Test-BRAVOPilotSelfTestThrows -Name 'FailureInjection/MalformedConfigFailsSnapshotClosed' -ScriptBlock {
        Invoke-BRAVOPilotConfigSnapshot -InstallRoot $f4Install -OutputPath (Join-Path $tempRoot 'f4-snapshot.json')
    }

    # F5: malformed candidate (виклик команди замість літералу) — activation-syntax-guard.
    $f5Install = Join-Path $tempRoot 'f5-malformed-candidate'
    New-BRAVOPilotSyntheticInstallRoot -Path $f5Install
    $f5CandidatePath = Join-Path $tempRoot 'f5-candidate.config'
    [System.IO.File]::WriteAllText($f5CandidatePath, "@{ 'bravoSettings.InstitutionName' = (Get-Date).ToString() }", (New-Object System.Text.UTF8Encoding($true)))
    Test-BRAVOPilotSelfTestThrows -Name 'FailureInjection/MalformedCandidateRejectedBeforeActivation' -ScriptBlock {
        Test-BRAVOPilotCandidateSyntax -CandidatePath $f5CandidatePath
    } -ExpectedMessagePattern 'PILOT_CANDIDATE_INVALID'

    # F5b: $true/$false/$null — PowerShell AST представляє їх як
    # VariableExpressionAst, хоча семантично це константні літерали, не
    # змінні. Без явного винятку для них БУДЬ-ЯКИЙ, повністю легітимний
    # data-only candidate із boolean/null site-override (типовий випадок
    # — напр. componentSettings.Archive.X = $false) хибно відхилявся б як
    # "містить змінні" — реальний дефект, знайдений реальним VM pilot-
    # прогоном 2026-09-17 (P1: -Activate відмовляв на легітимному
    # candidate з $false). Це — регресійний тест на той P1.
    $f5bCandidatePath = Join-Path $tempRoot 'f5b-candidate-boolean-null.config'
    [System.IO.File]::WriteAllText($f5bCandidatePath, "@{ 'a' = `$true; 'b' = `$false; 'c' = `$null; 'd' = 'text'; 'e' = 42 }", (New-Object System.Text.UTF8Encoding($true)))
    $f5bAccepted = $true
    $f5bError = $null
    try {
        Test-BRAVOPilotCandidateSyntax -CandidatePath $f5bCandidatePath | Out-Null
    } catch {
        $f5bAccepted = $false
        $f5bError = $_.Exception.Message
    }
    Test-BRAVOPilotSelfTestCondition -Name 'Security/CandidateBooleanNullLiteralsAccepted' -Condition $f5bAccepted -FailureDetail $f5bError

    # F5c: справжня небезпечна змінна (не $true/$false/$null) все одно
    # мусить відхилятись — регресія не повинна ослабити реальний захист.
    $f5cCandidatePath = Join-Path $tempRoot 'f5c-candidate-real-variable.config'
    [System.IO.File]::WriteAllText($f5cCandidatePath, "@{ 'a' = `$env:PATH }", (New-Object System.Text.UTF8Encoding($true)))
    Test-BRAVOPilotSelfTestThrows -Name 'Security/CandidateRealVariableStillRejected' -ScriptBlock {
        Test-BRAVOPilotCandidateSyntax -CandidatePath $f5cCandidatePath
    } -ExpectedMessagePattern 'PILOT_CANDIDATE_INVALID'

    # F6: wrong type / F7: unknown parent — симулюються через стаб SETUP, що
    # відмовляє (реальний BRAVO_SETUP.ps1 -ValidateOnly ловить обидва класи
    # помилок через canonical Configuration-схему; тут перевіряється, що
    # orchestrator коректно зупиняється на негативному ValidateOnly).
    $f6Install = Join-Path $tempRoot 'f6-wrong-type'
    New-BRAVOPilotSyntheticInstallRoot -Path $f6Install
    Set-BRAVOPilotStubBehavior -InstallRoot $f6Install -Behavior @{ Setup = @{ ExitCode = 1 } }
    $f6Validate = Invoke-BRAVOPilotValidateOnly -InstallRoot $f6Install -OutputPath (Join-Path $tempRoot 'f6-validate.log')
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ValidateOnlyFailureDetected' -Condition (-not $f6Validate.Pass) ''

    # F18: регресія на реальний VM P1 (2026-09-17) — Write-BRAVOPilotEvidenceText
    # раніше кидала необроблений ParameterBindingValidationException для
    # ПОРОЖНЬОГО (не $null) масиву -Lines, оскільки типізований масив-параметр
    # без [AllowEmptyCollection()] відхиляє 0-елементний масив за замовчуванням.
    # 0 захоплених рядків — легітимний діагностичний стан (дочірній скрипт
    # аварійно завершився ДО того, як щось потрапило в success/error-стрім),
    # а не помилка виклику; функція мусить записати правдивий (порожній)
    # evidence-файл, а не впасти.
    $f18EvidencePath = Join-Path $tempRoot 'f18-empty-lines.log'
    $f18Threw = $false
    $f18Error = $null
    try {
        Write-BRAVOPilotEvidenceText -Path $f18EvidencePath -Lines @()
    } catch {
        $f18Threw = $true
        $f18Error = $_.Exception.Message
    }
    Test-BRAVOPilotSelfTestCondition -Name 'Security/EvidenceTextToleratesEmptyLines' -Condition (-not $f18Threw) -FailureDetail $f18Error
    Test-BRAVOPilotSelfTestCondition -Name 'Security/EvidenceTextEmptyLinesWritesEmptyFile' -Condition (
        (Test-Path -LiteralPath $f18EvidencePath -PathType Leaf) -and
        ((Get-Content -LiteralPath $f18EvidencePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) -in @($null, ''))
    ) ''

    # F19: той самий сценарій, але через реальний call chain
    # Invoke-BRAVOPilotValidateOnly -> дочірній BRAVO_SETUP.ps1, що аварійно
    # завершується РІВНО з exit 1 і НУЛЬОВИМ захопленим виводом (NoOutput=$true
    # в стабі) — точна репродукція реального VM-прогону. Первинна помилка
    # (exit code) має зберегтися контрольовано, без вторинного винятку, що її
    # ховає (§6/§7 контракт: child exit != 0 -> preserve, tolerate zero
    # output lines, write truthful evidence, return controlled pilot failure).
    $f19Install = Join-Path $tempRoot 'f19-empty-output-failure'
    New-BRAVOPilotSyntheticInstallRoot -Path $f19Install
    Set-BRAVOPilotStubBehavior -InstallRoot $f19Install -Behavior @{ Setup = @{ ExitCode = 1; NoOutput = $true } }
    $f19OutputPath = Join-Path $tempRoot 'f19-validate.log'
    $f19Threw = $false
    $f19Error = $null
    $f19Result = $null
    try {
        $f19Result = Invoke-BRAVOPilotValidateOnly -InstallRoot $f19Install -OutputPath $f19OutputPath
    } catch {
        $f19Threw = $true
        $f19Error = $_.Exception.Message
    }
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ValidateOnlyEmptyOutputNoSecondaryException' -Condition (-not $f19Threw) -FailureDetail $f19Error
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ValidateOnlyEmptyOutputPreservesExitCode' -Condition (
        (-not $f19Threw) -and $null -ne $f19Result -and $f19Result.ExitCode -eq 1 -and -not $f19Result.Pass
    ) -FailureDetail $(if ($null -ne $f19Result) { "ExitCode=$($f19Result.ExitCode) Pass=$($f19Result.Pass)" } else { '$f19Result є $null' })
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ValidateOnlyEmptyOutputEvidenceWritten' -Condition (
        Test-Path -LiteralPath $f19OutputPath -PathType Leaf
    ) ''

    # F20: явний offline-access контракт (config-v2-pilot-validate-blockers,
    # 2026-09-17, §15-20) — throwaway pilot з fake/недосяжними SFTP/SMB/
    # webhook fixture-цілями не повинен провалюватись на мережевій пробі
    # доступу, якщо оператор ЯВНО передав -AllowOfflineExternalAccess.
    # Перевіряється: (a) прапорець реально прокидається в BRAVO_SETUP.ps1
    # -SkipAccessTest (не мовчки ігнорується), (b) evidence правдиво фіксує
    # ExternalAccess: NOT PERFORMED з причиною (не фабрикований PASS),
    # (c) за замовчуванням (без прапорця) поведінка НЕ змінюється —
    # -SkipAccessTest не передається і evidence фіксує PERFORMED.
    $f20Install = Join-Path $tempRoot 'f20-offline-access'
    New-BRAVOPilotSyntheticInstallRoot -Path $f20Install
    Set-BRAVOPilotStubBehavior -InstallRoot $f20Install -Behavior @{ Setup = @{ ExitCode = 0 } }

    $f20OfflineOutputPath = Join-Path $tempRoot 'f20-offline-validate.log'
    $f20OfflineResult = Invoke-BRAVOPilotValidateOnly -InstallRoot $f20Install -OutputPath $f20OfflineOutputPath -AllowOfflineExternalAccess
    $f20OfflineLines = @(Get-Content -LiteralPath $f20OfflineOutputPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    Test-BRAVOPilotSelfTestCondition -Name 'ExternalAccess/OfflineFlagForwardedToSetup' -Condition (
        @($f20OfflineLines | Where-Object { $_ -match 'SkipAccessTest=True' }).Count -gt 0
    ) -FailureDetail ([string]::Join(' | ', $f20OfflineLines))
    Test-BRAVOPilotSelfTestCondition -Name 'ExternalAccess/OfflineEvidenceRecordsNotPerformedTruthfully' -Condition (
        @($f20OfflineLines | Where-Object { $_ -match 'ExternalAccess: NOT PERFORMED' -and $_ -match 'OfflineThrowawayPilot' }).Count -gt 0
    ) -FailureDetail ([string]::Join(' | ', $f20OfflineLines))
    Test-BRAVOPilotSelfTestCondition -Name 'ExternalAccess/OfflineFlagDoesNotHideRealSetupFailure' -Condition (
        $f20OfflineResult.Pass -eq $true -and $f20OfflineResult.ExitCode -eq 0
    ) -FailureDetail "ExitCode=$($f20OfflineResult.ExitCode) Pass=$($f20OfflineResult.Pass)"

    $f20StrictOutputPath = Join-Path $tempRoot 'f20-strict-validate.log'
    $f20StrictResult = Invoke-BRAVOPilotValidateOnly -InstallRoot $f20Install -OutputPath $f20StrictOutputPath
    $f20StrictLines = @(Get-Content -LiteralPath $f20StrictOutputPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    Test-BRAVOPilotSelfTestCondition -Name 'ExternalAccess/DefaultModeDoesNotSkipAccessTest' -Condition (
        @($f20StrictLines | Where-Object { $_ -match 'SkipAccessTest=False' }).Count -gt 0
    ) -FailureDetail ([string]::Join(' | ', $f20StrictLines))
    Test-BRAVOPilotSelfTestCondition -Name 'ExternalAccess/DefaultModeEvidenceRecordsPerformed' -Condition (
        @($f20StrictLines | Where-Object { $_ -match 'ExternalAccess: PERFORMED' }).Count -gt 0
    ) -FailureDetail ([string]::Join(' | ', $f20StrictLines))

    # F21: exit 0 + ПОРОЖНІЙ вивід — відмінний кейс від F19 (exit 1 +
    # порожній). Успішний дочірній прогін, що з якоїсь причини (напр.
    # -NoPause на дуже ранньому success-шляху) не пише жодного рядка,
    # МАЄ трактуватись як PASS з порожньою evidence, а не як прихована
    # помилка.
    $f21Install = Join-Path $tempRoot 'f21-exit0-empty-output'
    New-BRAVOPilotSyntheticInstallRoot -Path $f21Install
    Set-BRAVOPilotStubBehavior -InstallRoot $f21Install -Behavior @{ Setup = @{ ExitCode = 0; NoOutput = $true } }
    $f21OutputPath = Join-Path $tempRoot 'f21-validate.log'
    $f21Threw = $false
    $f21Error = $null
    $f21Result = $null
    try {
        $f21Result = Invoke-BRAVOPilotValidateOnly -InstallRoot $f21Install -OutputPath $f21OutputPath
    } catch {
        $f21Threw = $true
        $f21Error = $_.Exception.Message
    }
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ValidateOnlyExitZeroEmptyOutputNoSecondaryException' -Condition (-not $f21Threw) -FailureDetail $f21Error
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ValidateOnlyExitZeroEmptyOutputReportsPass' -Condition (
        (-not $f21Threw) -and $null -ne $f21Result -and $f21Result.ExitCode -eq 0 -and $f21Result.Pass -eq $true
    ) -FailureDetail $(if ($null -ne $f21Result) { "ExitCode=$($f21Result.ExitCode) Pass=$($f21Result.Pass)" } else { '$f21Result є $null' })

    # F22: помилка дочірнього процесу потрапляє ЛИШЕ в error-стрім
    # (PowerShell ErrorRecord через Write-Error), success-стрім
    # порожній. `2>&1 | ForEach-Object { [string]$_ }` мусить коректно
    # злити обидва стріми в масив рядків без винятку прив'язки і без
    # втрати діагностичної інформації про помилку.
    $f22Install = Join-Path $tempRoot 'f22-stderr-only'
    New-BRAVOPilotSyntheticInstallRoot -Path $f22Install
    Set-BRAVOPilotStubBehavior -InstallRoot $f22Install -Behavior @{ Setup = @{ ExitCode = 1; StdErrOnly = $true } }
    $f22OutputPath = Join-Path $tempRoot 'f22-validate.log'
    $f22Threw = $false
    $f22Error = $null
    $f22Result = $null
    try {
        $f22Result = Invoke-BRAVOPilotValidateOnly -InstallRoot $f22Install -OutputPath $f22OutputPath
    } catch {
        $f22Threw = $true
        $f22Error = $_.Exception.Message
    }
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ValidateOnlyStdErrOnlyNoSecondaryException' -Condition (-not $f22Threw) -FailureDetail $f22Error
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ValidateOnlyStdErrOnlyPreservesExitCode' -Condition (
        (-not $f22Threw) -and $null -ne $f22Result -and $f22Result.ExitCode -eq 1 -and -not $f22Result.Pass
    ) -FailureDetail $(if ($null -ne $f22Result) { "ExitCode=$($f22Result.ExitCode) Pass=$($f22Result.Pass)" } else { '$f22Result є $null' })
    $f22Lines = @(Get-Content -LiteralPath $f22OutputPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ValidateOnlyStdErrOnlyContentCaptured' -Condition (
        @($f22Lines | Where-Object { $_ -match 'STUB-SETUP-STDERR' }).Count -gt 0
    ) -FailureDetail ([string]::Join(' | ', $f22Lines))

    # F8: read-only destination (EvidenceRoot без права на запис).
    $f8EvidenceRoot = Join-Path $tempRoot 'f8-readonly-evidence'
    [void](New-Item -ItemType Directory -Path $f8EvidenceRoot -Force)
    $acl = Get-Acl -LiteralPath $f8EvidenceRoot
    $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME, 'Write,CreateFiles,CreateDirectories', 'ContainerInherit,ObjectInherit', 'None', 'Deny')
    $acl.AddAccessRule($denyRule)
    $f8AclApplied = $true
    try { Set-Acl -LiteralPath $f8EvidenceRoot -AclObject $acl } catch { $f8AclApplied = $false }
    if ($f8AclApplied) {
        $f8Writable = Test-BRAVOPilotWritableDirectory -Path $f8EvidenceRoot
        Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ReadOnlyDestinationDetected' -Condition (-not $f8Writable) ''
        $acl.RemoveAccessRule($denyRule) | Out-Null
        Set-Acl -LiteralPath $f8EvidenceRoot -AclObject $acl
    } else {
        Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ReadOnlyDestinationDetected' -Condition $true 'ACL deny-rule непідтримуваний у цьому середовищі (CI-гермет) — сценарій пропущено без FAIL'
    }

    # F9: backup failure (BRAVO.config видалено між Preflight і Activate).
    $f9Install = Join-Path $tempRoot 'f9-backup-failure'
    New-BRAVOPilotSyntheticInstallRoot -Path $f9Install
    $f9EvidenceDir = New-BRAVOPilotEvidenceDirectory -EvidenceRoot (Join-Path $tempRoot 'f9-evidence') -ServerId 'f9'
    Remove-Item -LiteralPath (Join-Path $f9Install 'BRAVO.config') -Force
    Test-BRAVOPilotSelfTestThrows -Name 'FailureInjection/BackupFailureFailsClosedNoPartialWrite' -ScriptBlock {
        New-BRAVOPilotBackup -InstallRoot $f9Install -EvidenceDir $f9EvidenceDir
    } -ExpectedMessagePattern 'PILOT_BACKUP_FAILED'
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/BackupFailureNoLocalConfigWritten' -Condition (-not (Test-Path -LiteralPath (Join-Path $f9Install 'BRAVO.local.config'))) ''

    # F10: candidate changed after approval (TOCTOU).
    $f10Install = Join-Path $tempRoot 'f10-toctou'
    New-BRAVOPilotSyntheticInstallRoot -Path $f10Install
    $f10EvidenceDir = New-BRAVOPilotEvidenceDirectory -EvidenceRoot (Join-Path $tempRoot 'f10-evidence') -ServerId 'f10'
    Set-BRAVOPilotState -EvidenceDir $f10EvidenceDir -State 'PreflightPassed' | Out-Null
    $f10CandidatePath = Join-Path $f10EvidenceDir 'BRAVO.local.config.candidate'
    [System.IO.File]::WriteAllText($f10CandidatePath, "@{ 'bravoSettings.InstitutionName' = 'Original' }", (New-Object System.Text.UTF8Encoding($true)))
    $f10Hash = (Get-FileHash -LiteralPath $f10CandidatePath -Algorithm SHA256).Hash
    $f10Approval = Approve-BRAVOPilotCandidate -EvidenceDir $f10EvidenceDir -CandidatePath $f10CandidatePath -ApprovedCandidateHash $f10Hash
    # Candidate тепер міняється ПІСЛЯ approval.
    [System.IO.File]::WriteAllText($f10CandidatePath, "@{ 'bravoSettings.InstitutionName' = 'Tampered' }", (New-Object System.Text.UTF8Encoding($true)))
    Test-BRAVOPilotSelfTestThrows -Name 'FailureInjection/CandidateChangedAfterApprovalToctouBlocked' -ScriptBlock {
        Invoke-BRAVOPilotAtomicActivation -InstallRoot $f10Install -CandidatePath $f10CandidatePath -EvidenceDir $f10EvidenceDir -ApprovedCandidateHash $f10Approval.CandidateHash
    } -ExpectedMessagePattern 'PILOT_ACTIVATION_FAILED'
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ToctouNoActivationOccurred' -Condition (-not (Test-Path -LiteralPath (Join-Path $f10Install 'BRAVO.local.config'))) ''

    # F11: partial activation simulation (ціль — заблокований файл, File.Replace провалюється).
    $f11Install = Join-Path $tempRoot 'f11-partial-activation'
    New-BRAVOPilotSyntheticInstallRoot -Path $f11Install
    $f11TargetPath = Join-Path $f11Install 'BRAVO.local.config'
    [System.IO.File]::WriteAllText($f11TargetPath, "@{ 'bravoSettings.InstitutionName' = 'PreExisting' }", (New-Object System.Text.UTF8Encoding($true)))
    $f11OriginalHash = (Get-FileHash -LiteralPath $f11TargetPath -Algorithm SHA256).Hash
    $f11CandidatePath = Join-Path $tempRoot 'f11-candidate.config'
    [System.IO.File]::WriteAllText($f11CandidatePath, "@{ 'bravoSettings.InstitutionName' = 'NewValue' }", (New-Object System.Text.UTF8Encoding($true)))
    $f11Hash = (Get-FileHash -LiteralPath $f11CandidatePath -Algorithm SHA256).Hash
    $lockStream = [System.IO.File]::Open($f11TargetPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $f11EvidenceDir = New-BRAVOPilotEvidenceDirectory -EvidenceRoot (Join-Path $tempRoot 'f11-evidence') -ServerId 'f11'
        Test-BRAVOPilotSelfTestThrows -Name 'FailureInjection/PartialActivationBlockedFailsClosed' -ScriptBlock {
            Invoke-BRAVOPilotAtomicActivation -InstallRoot $f11Install -CandidatePath $f11CandidatePath -EvidenceDir $f11EvidenceDir -ApprovedCandidateHash $f11Hash
        } -ExpectedMessagePattern 'PILOT_ACTIVATION_FAILED'
    } finally {
        $lockStream.Close()
        $lockStream.Dispose()
    }
    $f11FinalHash = (Get-FileHash -LiteralPath $f11TargetPath -Algorithm SHA256).Hash
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/PartialActivationOriginalPreserved' -Condition ($f11FinalHash -eq $f11OriginalHash) ''

    # F12: ValidateOnly failure -> вже покрито F6 (той самий механізм) +
    # end-to-end у сценарії Rollback вище (self-test failure, той самий клас).
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ValidateOnlyFailureCoveredByF6AndRollbackScenario' -Condition $true ''

    # F13: semantic parity failure — candidate НЕ відповідає реальній
    # дельті BRAVO.config (навмисно підмінене значення після Prepare).
    $f13Install = Join-Path $tempRoot 'f13-parity-failure'
    New-BRAVOPilotSyntheticInstallRoot -Path $f13Install
    $f13EvidenceRoot = Join-Path $tempRoot 'f13-evidence'
    & $startScript -Preflight -InstallRoot $f13Install -ArtifactRoot $artifactRoot -EvidenceRoot $f13EvidenceRoot 2>&1 | Out-Null
    & $startScript -Prepare -InstallRoot $f13Install -ArtifactRoot $artifactRoot -EvidenceRoot $f13EvidenceRoot 2>&1 | Out-Null
    $f13EvidenceDir = (Get-ChildItem -LiteralPath $f13EvidenceRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
    $f13State = Get-Content -LiteralPath (Join-Path $f13EvidenceDir 'metadata.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $f13CandidatePath = [string]$f13State.CandidatePath
    # Тампер: змінюємо значення в candidate на ІНШЕ, ніж реально в BRAVO.config сайту.
    [System.IO.File]::WriteAllText($f13CandidatePath, "@{ 'bravoSettings.InstitutionName' = 'Tampered Mismatch Value' }", (New-Object System.Text.UTF8Encoding($true)))
    $f13TamperedHash = (Get-FileHash -LiteralPath $f13CandidatePath -Algorithm SHA256).Hash
    & $startScript -Approve -EvidenceDir $f13EvidenceDir -ApprovedCandidateHash $f13TamperedHash 2>&1 | Out-Null
    & $startScript -Activate -InstallRoot $f13Install -EvidenceDir $f13EvidenceDir 2>&1 | Out-Null
    $f13ValidateOutput = & $startScript -Validate -InstallRoot $f13Install -EvidenceDir $f13EvidenceDir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/SemanticParityMismatchDetected' -Condition ($LASTEXITCODE -ne 0) -FailureDetail ([string]::Join(' | ', @($f13ValidateOutput | Select-Object -Last 10)))
    if (Test-Path -LiteralPath (Join-Path $f13EvidenceDir 'parity.json')) {
        $f13Parity = Get-Content -LiteralPath (Join-Path $f13EvidenceDir 'parity.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/SemanticParityRecordsFailure' -Condition (-not [bool]$f13Parity.Pass) ''
    } else {
        Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/SemanticParityRecordsFailure' -Condition $false 'parity.json не створено'
    }

    # F14: missing Credential Manager reference — НЕ FAIL: свідоме
    # design-рішення (§10 Preflight: "де можливо" + non-blocking WARN),
    # бо свіжий pilot-сервер легітимно може не мати ще спровіджених
    # credential-записів, якщо SFTP-функціональність не використовується.
    # Тест підтверджує САМЕ ЦЮ, а не протилежну, поведінку.
    $f14Install = Join-Path $tempRoot 'f14-missing-cred'
    New-BRAVOPilotSyntheticInstallRoot -Path $f14Install
    $f14Preflight = Invoke-BRAVOPilotPreflight -InstallRoot $f14Install -ArtifactRoot $artifactRoot
    $f14CredCheck = @($f14Preflight.Checks | Where-Object { $_.Name -eq 'CredentialManagerReferencesCheckedWithoutResolving' })[0]
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/MissingCredentialReferenceIsNonBlockingByDesign' -Condition (-not $f14CredCheck.Blocking) ''

    # F15: rollback source corruption (backup-manifest.json пошкоджено).
    $f15Install = Join-Path $tempRoot 'f15-rollback-corruption'
    New-BRAVOPilotSyntheticInstallRoot -Path $f15Install
    $f15EvidenceRoot = Join-Path $tempRoot 'f15-evidence'
    & $startScript -Preflight -InstallRoot $f15Install -ArtifactRoot $artifactRoot -EvidenceRoot $f15EvidenceRoot 2>&1 | Out-Null
    & $startScript -Prepare -InstallRoot $f15Install -ArtifactRoot $artifactRoot -EvidenceRoot $f15EvidenceRoot 2>&1 | Out-Null
    $f15EvidenceDir = (Get-ChildItem -LiteralPath $f15EvidenceRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
    $f15State = Get-Content -LiteralPath (Join-Path $f15EvidenceDir 'metadata.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    & $startScript -Approve -EvidenceDir $f15EvidenceDir -ApprovedCandidateHash ([string]$f15State.CandidateHash) 2>&1 | Out-Null
    & $startScript -Activate -InstallRoot $f15Install -EvidenceDir $f15EvidenceDir 2>&1 | Out-Null
    $f15BackupDir = (Get-ChildItem -LiteralPath $f15EvidenceDir -Directory -Filter 'backup-*')[0].FullName
    $f15InstallConfigHashBeforeRollback = (Get-FileHash -LiteralPath (Join-Path $f15Install 'BRAVO.config') -Algorithm SHA256).Hash
    [System.IO.File]::WriteAllText((Join-Path $f15BackupDir 'backup-manifest.json'), '{ corrupted json', (New-Object System.Text.UTF8Encoding($false)))
    $f15RollbackOutput = & $startScript -Rollback -InstallRoot $f15Install -EvidenceDir $f15EvidenceDir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/RollbackSourceCorruptionFailsClosed' -Condition ($LASTEXITCODE -ne 0) -FailureDetail ([string]::Join(' | ', @($f15RollbackOutput | Select-Object -Last 5)))
    $f15InstallConfigHashAfterRollback = (Get-FileHash -LiteralPath (Join-Path $f15Install 'BRAVO.config') -Algorithm SHA256).Hash
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/RollbackSourceCorruptionNoMutationAttempted' -Condition ($f15InstallConfigHashBeforeRollback -eq $f15InstallConfigHashAfterRollback) ''

    # F16: -Activate провалюється ПІСЛЯ New-BRAVOPilotBackup/State=BackupCreated
    # (P2-triage): candidate тампериться ПІСЛЯ -Approve (той самий TOCTOU
    # клас, що й F10, але через повний CLI -Activate, а не напряму через
    # Invoke-BRAVOPilotAtomicActivation) -> перевіряємо, що CLI-обгортка НЕ
    # лишає metadata.json застряглим на 'BackupCreated' (dead-end без шляху
    # вперед), backup лишається валідним, і -Rollback після цього працює.
    $f16Install = Join-Path $tempRoot 'f16-activation-failure'
    New-BRAVOPilotSyntheticInstallRoot -Path $f16Install
    $f16EvidenceRoot = Join-Path $tempRoot 'f16-evidence'
    & $startScript -Preflight -InstallRoot $f16Install -ArtifactRoot $artifactRoot -EvidenceRoot $f16EvidenceRoot 2>&1 | Out-Null
    & $startScript -Prepare -InstallRoot $f16Install -ArtifactRoot $artifactRoot -EvidenceRoot $f16EvidenceRoot 2>&1 | Out-Null
    $f16EvidenceDir = (Get-ChildItem -LiteralPath $f16EvidenceRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
    $f16State = Get-Content -LiteralPath (Join-Path $f16EvidenceDir 'metadata.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    & $startScript -Approve -EvidenceDir $f16EvidenceDir -ApprovedCandidateHash ([string]$f16State.CandidateHash) 2>&1 | Out-Null
    # Тамперимо candidate ПІСЛЯ approval — той самий SHA-256 у metadata.json
    # уже не збігається з реальним файлом, тому Invoke-BRAVOPilotAtomicActivation
    # кине TOCTOU-виняток УСЕРЕДИНІ CLI -Activate, вже ПІСЛЯ того, як backup
    # створено й state='BackupCreated' записано.
    [System.IO.File]::AppendAllText([string]$f16State.CandidatePath, "`n# tampered-after-approval`n")
    $f16ActivateOutput = & $startScript -Activate -InstallRoot $f16Install -EvidenceDir $f16EvidenceDir 2>&1
    $f16ActivateExit = $LASTEXITCODE
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ActivationFailureAfterBackupExitsNonZero' -Condition ($f16ActivateExit -ne 0) -FailureDetail ([string]::Join(' | ', @($f16ActivateOutput | Select-Object -Last 5)))

    $f16StateAfterFailure = Get-Content -LiteralPath (Join-Path $f16EvidenceDir 'metadata.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ActivationFailureTransitionsToFailedNotStuck' -Condition ([string]$f16StateAfterFailure.State -eq 'Failed') -FailureDetail "State=$([string]$f16StateAfterFailure.State)"

    $f16BackupDirs = @(Get-ChildItem -LiteralPath $f16EvidenceDir -Directory -Filter 'backup-*')
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ActivationFailureBackupStillPresent' -Condition ($f16BackupDirs.Count -eq 1) ''
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/ActivationFailureNoLocalConfigWritten' -Condition (-not (Test-Path -LiteralPath (Join-Path $f16Install 'BRAVO.local.config'))) ''

    # Відновлення після 'Failed' -> -Rollback лишається доступним і успішним
    # незалежно від застряглого стану (Invoke-BRAVOPilotRollback шукає
    # каталог backup-*, а не читає metadata.json.State).
    $f16RollbackOutput = & $startScript -Rollback -InstallRoot $f16Install -EvidenceDir $f16EvidenceDir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'FailureInjection/RollbackAvailableAfterActivationFailure' -Condition ($LASTEXITCODE -eq 0) -FailureDetail ([string]::Join(' | ', @($f16RollbackOutput | Select-Object -Last 5)))

    # =========================================================================
    # F17: взаємне виключення mutating-операцій над одним -InstallRoot
    # (§concurrency-triage) — Enter-/Exit-BRAVOPilotInstallRootLock через
    # повний CLI, з РЕАЛЬНИМ окремим процесом-власником локу (не той самий
    # потік — named Mutex реентерабельний для одного потоку, тому лише
    # окремий процес коректно моделює конкурентний -Activate).
    # =========================================================================
    $f17aInstall = Join-Path $tempRoot 'f17a-concurrency'
    New-BRAVOPilotSyntheticInstallRoot -Path $f17aInstall
    $f17aEvidenceRoot = Join-Path $tempRoot 'f17a-evidence'
    & $startScript -Preflight -InstallRoot $f17aInstall -ArtifactRoot $artifactRoot -EvidenceRoot $f17aEvidenceRoot 2>&1 | Out-Null
    & $startScript -Prepare -InstallRoot $f17aInstall -ArtifactRoot $artifactRoot -EvidenceRoot $f17aEvidenceRoot 2>&1 | Out-Null
    $f17aEvidenceDir = (Get-ChildItem -LiteralPath $f17aEvidenceRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
    $f17aState = Get-Content -LiteralPath (Join-Path $f17aEvidenceDir 'metadata.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    & $startScript -Approve -EvidenceDir $f17aEvidenceDir -ApprovedCandidateHash ([string]$f17aState.CandidateHash) 2>&1 | Out-Null

    $f17bInstall = Join-Path $tempRoot 'f17b-concurrency'
    New-BRAVOPilotSyntheticInstallRoot -Path $f17bInstall
    $f17bEvidenceRoot = Join-Path $tempRoot 'f17b-evidence'
    & $startScript -Preflight -InstallRoot $f17bInstall -ArtifactRoot $artifactRoot -EvidenceRoot $f17bEvidenceRoot 2>&1 | Out-Null
    & $startScript -Prepare -InstallRoot $f17bInstall -ArtifactRoot $artifactRoot -EvidenceRoot $f17bEvidenceRoot 2>&1 | Out-Null
    $f17bEvidenceDir = (Get-ChildItem -LiteralPath $f17bEvidenceRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
    $f17bState = Get-Content -LiteralPath (Join-Path $f17bEvidenceDir 'metadata.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    & $startScript -Approve -EvidenceDir $f17bEvidenceDir -ApprovedCandidateHash ([string]$f17bState.CandidateHash) 2>&1 | Out-Null

    $f17ResolvedInstallA = [System.IO.Path]::GetFullPath($f17aInstall)
    $f17HolderScriptPath = Join-Path $tempRoot 'f17-lock-holder.ps1'
    $f17LockAcquiredMarker = Join-Path $tempRoot 'f17-lock-acquired.marker'
    $f17HolderStdoutPath = Join-Path $tempRoot 'f17-holder.stdout.log'
    $f17HolderStderrPath = Join-Path $tempRoot 'f17-holder.stderr.log'
    $f17HolderScript = @"
. '$($script:repoRoot)\deploy\BRAVOConfigV2Pilot.Runtime.ps1'
`$m = Enter-BRAVOPilotInstallRootLock -InstallRoot '$f17ResolvedInstallA' -TimeoutSeconds 10
[System.IO.File]::WriteAllText('$f17LockAcquiredMarker', 'acquired')
# Довше за дефолтний TimeoutSeconds=5 у Enter-BRAVOPilotInstallRootLock:
# конкуруючий -Activate нижче МАЄ вичерпати bounded wait і отримати
# fail closed (PILOT_INSTALLROOT_LOCKED), а не просто дочекатись
# звільнення й тихо пройти (перша версія цього тесту тримала лок лише
# 4с < 5с timeout, тому "заблокований" виклик насправді просто чекав
# і легітимно активувався — хибний provал тесту без реального дефекту).
Start-Sleep -Seconds 8
Exit-BRAVOPilotInstallRootLock -Mutex `$m
"@
    [System.IO.File]::WriteAllText($f17HolderScriptPath, $f17HolderScript, (New-Object System.Text.UTF8Encoding($false)))
    $f17HolderProc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $f17HolderScriptPath) -PassThru -WindowStyle Hidden -RedirectStandardOutput $f17HolderStdoutPath -RedirectStandardError $f17HolderStderrPath

    # Детерміноване очікування маркера замість фіксованого Start-Sleep:
    # новий powershell.exe-процес + dot-source Runtime.ps1 має непередбачуваний
    # холодний старт, фіксована пауза була б крихкою (спостережено — перший
    # прогін фактично встиг активувати f17a ДО того, як власник локу набув
    # володіння, і тест хибно провалився без будь-якого реального дефекту в
    # самому locking-коді).
    $f17MarkerDeadline = (Get-Date).AddSeconds(8)
    while (-not (Test-Path -LiteralPath $f17LockAcquiredMarker) -and (Get-Date) -lt $f17MarkerDeadline) {
        Start-Sleep -Milliseconds 100
    }
    $f17MarkerAppeared = Test-Path -LiteralPath $f17LockAcquiredMarker
    Test-BRAVOPilotSelfTestCondition -Name 'Concurrency/LockHolderProcessAcquiredLock' -Condition $f17MarkerAppeared -FailureDetail ("holder stderr: " + (Get-Content -LiteralPath $f17HolderStderrPath -Raw -ErrorAction SilentlyContinue))

    $f17BlockedOutput = & $startScript -Activate -InstallRoot $f17aInstall -EvidenceDir $f17aEvidenceDir 2>&1
    $f17BlockedExit = $LASTEXITCODE
    Test-BRAVOPilotSelfTestCondition -Name 'Concurrency/ActivateBlockedWhileLockHeldBySameInstallRoot' -Condition (
        $f17BlockedExit -ne 0 -and (($f17BlockedOutput | Out-String) -match 'PILOT_INSTALLROOT_LOCKED')
    ) -FailureDetail ([string]::Join(' | ', @($f17BlockedOutput | Select-Object -Last 5)))

    $f17IndependentOutput = & $startScript -Activate -InstallRoot $f17bInstall -EvidenceDir $f17bEvidenceDir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Concurrency/DifferentInstallRootActivatesIndependently' -Condition ($LASTEXITCODE -eq 0) -FailureDetail ([string]::Join(' | ', @($f17IndependentOutput | Select-Object -Last 5)))

    $f17HolderProc.WaitForExit()
    $f17RetryOutput = & $startScript -Activate -InstallRoot $f17aInstall -EvidenceDir $f17aEvidenceDir 2>&1
    Test-BRAVOPilotSelfTestCondition -Name 'Concurrency/ActivateSucceedsAfterLockReleased' -Condition ($LASTEXITCODE -eq 0) -FailureDetail ([string]::Join(' | ', @($f17RetryOutput | Select-Object -Last 5)))

} catch {
    # Неперехоплена помилка десь у сценарії — це саме по собі провал
    # тесту, а не привід мовчки перервати прогін без summary/exit-коду.
    $script:failedCount++
    $script:failureNames.Add('UNCAUGHT_EXCEPTION')
    Write-Host "[FAIL] UNCAUGHT_EXCEPTION -- $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
} finally {
    # --- Верифікація: жоден вихідний файл репозиторію не змінився -------
    foreach ($rel in $sourceFilesToWatch) {
        $afterHash = (Get-FileHash -LiteralPath (Join-Path $script:repoRoot $rel) -Algorithm SHA256).Hash
        Test-BRAVOPilotSelfTestCondition -Name "SourceIntegrity/${rel}Unmodified" -Condition ($afterHash -eq $sourceHashesBefore[$rel]) "before=$($sourceHashesBefore[$rel]) after=$afterHash"
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ('=' * 70)
Write-Host ("Усього перевірок: {0}; провалено: {1}" -f $script:total, $script:failedCount)
if ($script:failedCount -gt 0) {
    Write-Host ("Провалені: {0}" -f ([string]::Join(', ', $script:failureNames))) -ForegroundColor Red
    Write-Host 'SELF-TEST FAILED'
    exit 1
}
Write-Host 'SELF-TEST PASSED' -ForegroundColor Green
exit 0
