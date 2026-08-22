# Домен-фрагмент self-test: false-positive rollback після bravocmd repair +
# Discord HTTP 429 retry (fix/repair-rollback-false-positive-and-discord-429).
#
# Compare-FileSizes: реальна ізольована AST-екстракція runtime-функції
# (не симуляція) з двома РІЗНИМИ generic назвами моделі (TestProject,
# AnotherProject42) — жодна з них не lims/VetOffice, щоб виключити
# випадковий hardcode. Send-BRAVOWebhookNotification: реальна екстракція з
# BRAVO.Compatibility.psm1 із застабованим Invoke-WebRequest (перша спроба
# такого стабу в цьому репозиторії — прецеденту немає).
#
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition,
# New-BRAVOSelfTestRuntimeModule, $script:failures.

$maintenanceRepairScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
    [Text.Encoding]::UTF8
)

Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop

# ============================================================
# MODEL-контракт: похідні MODEL_NAME/MAIN_MODEL_FILE, без hardcode.
# ============================================================
Test-BRAVOCondition `
    -Condition $maintenanceRepairScriptText.Contains(
        '$MODEL_NAME = Split-Path -Path $MODEL_PROJECT_PATH -Leaf'
    ) `
    -Name "Maintenance/ModelNameDerivedNotHardcoded" `
    -Failure "MODEL_NAME має бути похідним від MODEL_PROJECT_PATH (значення MODEL= з bravo.ini), а не hardcoded назвою проєкту"
Test-BRAVOCondition `
    -Condition $maintenanceRepairScriptText.Contains(
        '$MAIN_MODEL_FILE = "$MODEL_PROJECT_PATH.md"'
    ) `
    -Name "Maintenance/MainModelFileDerivedNotHardcoded" `
    -Failure "MAIN_MODEL_FILE має бути похідним (MODEL_PROJECT_PATH + '.md'), а не hardcoded шляхом на кшталт Model\lims.md/Model\VetOffice.md"
Test-BRAVOCondition `
    -Condition (
        -not ($maintenanceRepairScriptText -match '\$MODEL_NAME\s*=\s*"(?!.*MODEL_PROJECT_PATH)') -and
        -not ($maintenanceRepairScriptText -match '\$MAIN_MODEL_FILE\s*=\s*"(?!\$MODEL_PROJECT_PATH)')
    ) `
    -Name "Maintenance/NoHardcodedModelNameLiteral" `
    -Failure "MODEL_NAME/MAIN_MODEL_FILE не повинні мати альтернативного hardcoded присвоєння літералом"

# Split-Path/конкатенація — та сама семантика, що виробничий код, для двох
# РІЗНИХ generic назв (жодна не lims/VetOffice) — перевіряє відсутність
# cross-scenario bleed.
$modelContractScenarios = @(
    @{ Base = 'C:\Sandbox\Model\TestProject'; ExpectedName = 'TestProject'; ExpectedMain = 'C:\Sandbox\Model\TestProject.md' }
    @{ Base = 'E:\BRAVO\Model\AnotherProject42'; ExpectedName = 'AnotherProject42'; ExpectedMain = 'E:\BRAVO\Model\AnotherProject42.md' }
)
foreach ($scenario in $modelContractScenarios) {
    $derivedName = Split-Path -Path $scenario.Base -Leaf
    $derivedMain = "$($scenario.Base).md"
    Test-BRAVOCondition `
        -Condition ($derivedName -eq $scenario.ExpectedName -and $derivedMain -eq $scenario.ExpectedMain) `
        -Name "Maintenance/ModelContractDerivation[$($scenario.ExpectedName)]" `
        -Failure "MODEL_NAME/MAIN_MODEL_FILE для '$($scenario.Base)' мають бути '$($scenario.ExpectedName)'/'$($scenario.ExpectedMain)'; отримано '$derivedName'/'$derivedMain'"
}

# ============================================================
# Compare-FileSizes: RemovedByRepair vs CRITICAL класифікація.
# ============================================================
$compareFileSizesStubText = @'
function Write-Log { param($Message, [string]$Level = 'INFO') }
function Send-SlackAlert { param($Message, [switch]$IsCritical) }
function Get-BRAVOFiles { BRAVO.Compatibility\Get-BRAVOFiles @args }
'@
$compareFileSizesModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText ($compareFileSizesStubText + "`n" + $maintenanceRepairScriptText) `
    -FunctionNames @('Write-Log', 'Send-SlackAlert', 'Get-BRAVOFiles', 'Format-FileSize', 'New-BRAVOCompareFileSizesResult', 'Compare-FileSizes')

function Invoke-BRAVOCompareFileSizesScenario {
    param(
        [Parameter(Mandatory = $true)][hashtable]$BeforeFiles,
        [Parameter(Mandatory = $true)][hashtable]$AfterFiles,
        [string]$MainModelRelativePath
    )
    $scenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_COMPAREFILESIZES_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($scenarioRoot)
    try {
        foreach ($relativePath in $AfterFiles.Keys) {
            $fullPath = Join-Path $scenarioRoot $relativePath
            [void][IO.Directory]::CreateDirectory((Split-Path -Path $fullPath -Parent))
            $sizeBytes = [int64]$AfterFiles[$relativePath]
            [IO.File]::WriteAllBytes($fullPath, (New-Object byte[] $sizeBytes))
        }
        $beforeCsvPath = Join-Path $scenarioRoot '__before_sizes.csv'
        $beforeRows = @($BeforeFiles.Keys | ForEach-Object {
            [PSCustomObject]@{ RelativePath = $_; SizeBytes = [int64]$BeforeFiles[$_] }
        })
        $beforeRows | Export-Csv -Path $beforeCsvPath -NoTypeInformation -Encoding UTF8

        return & $compareFileSizesModule {
            param($BeforeFile, $ModelPath, $MainModelRelativePath)
            Set-StrictMode -Version Latest
            Compare-FileSizes -BeforeFile $BeforeFile -ModelPath $ModelPath -MinSizeBytes 2048 -MainModelRelativePath $MainModelRelativePath
        } $beforeCsvPath $scenarioRoot $MainModelRelativePath
    } finally {
        if (Test-Path -LiteralPath $scenarioRoot) {
            Remove-Item -LiteralPath $scenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- TestProject: 0 RemovedByRepair (нічого не зникло) -> НЕ критично.
$resultZeroRemoved = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition (-not $resultZeroRemoved.HasCriticalChanges -and $resultZeroRemoved.RemovedByRepairCount -eq 0) `
    -Name "Maintenance/CompareFileSizesZeroRemovedByRepair" `
    -Failure "без жодного зниклого файлу HasCriticalChanges має бути false, RemovedByRepairCount=0"

# --- TestProject: 1 сегментний файл прибрано repair -> RemovedByRepair=1,
# НЕ критично (це і є root cause фікса: bravocmd штатно перебудовує сегменти).
$resultOneRemoved = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition (-not $resultOneRemoved.HasCriticalChanges -and $resultOneRemoved.RemovedByRepairCount -eq 1) `
    -Name "Maintenance/CompareFileSizesOneRemovedByRepairNotCritical" `
    -Failure "сегментний файл, прибраний repair-ом, НЕ повинен бути CRITICAL; отримано HasCriticalChanges=$($resultOneRemoved.HasCriticalChanges), RemovedByRepairCount=$($resultOneRemoved.RemovedByRepairCount)"

# --- AnotherProject42: N=3 сегментних файли прибрано repair -> RemovedByRepair=3.
$resultManyRemoved = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'AnotherProject42.md' = 500000; 'ASSORT.000' = 100000; 'ASSORT.002' = 100000; 'classifier.003' = 100000 } `
    -AfterFiles  @{ 'AnotherProject42.md' = 500000 } `
    -MainModelRelativePath 'AnotherProject42.md'
Test-BRAVOCondition `
    -Condition (-not $resultManyRemoved.HasCriticalChanges -and $resultManyRemoved.RemovedByRepairCount -eq 3) `
    -Name "Maintenance/CompareFileSizesManyRemovedByRepairNotCritical" `
    -Failure "три сегментних файли, прибрані repair-ом, НЕ повинні бути CRITICAL; отримано HasCriticalChanges=$($resultManyRemoved.HasCriticalChanges), RemovedByRepairCount=$($resultManyRemoved.RemovedByRepairCount)"

# --- AnotherProject42: існуючий (не основний) файл схлопнувся 50MB -> 2048b
# -> CRITICAL незалежно від назви файлу.
$resultCollapsed = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'AnotherProject42.md' = 500000; 'SAMPLE.000' = 52428800 } `
    -AfterFiles  @{ 'AnotherProject42.md' = 500000; 'SAMPLE.000' = 2048 } `
    -MainModelRelativePath 'AnotherProject42.md'
Test-BRAVOCondition `
    -Condition ($resultCollapsed.HasCriticalChanges -and @($resultCollapsed.CriticalFiles).Count -eq 1) `
    -Name "Maintenance/CompareFileSizesExistingFileCollapseCritical" `
    -Failure "файл, що схлопнувся з 50MB до 2048 байт, має лишатись CRITICAL незалежно від того, що це не основна модель"

# --- TestProject: основна модель ВІДСУТНЯ після repair -> CRITICAL.
$resultMainMissing = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultMainMissing.HasCriticalChanges -and -not $resultMainMissing.MainModelValid) `
    -Name "Maintenance/CompareFileSizesMainModelMissingCritical" `
    -Failure "відсутність основної моделі після repair має бути CRITICAL (MainModelValid=false), навіть якщо MainModelRelativePath переданий"

# --- TestProject: основна модель <= 2048 байт після repair -> CRITICAL.
$resultMainTiny = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 100; 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultMainTiny.HasCriticalChanges -and -not $resultMainTiny.MainModelValid) `
    -Name "Maintenance/CompareFileSizesMainModelTinyCritical" `
    -Failure "основна модель розміром <=2048 байт після repair має бути CRITICAL"

# --- AnotherProject42: каталог MODEL порожній після repair -> CRITICAL
# (defense-in-depth, окремо від per-file циклу).
$resultEmptyDirectory = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'AnotherProject42.md' = 500000; 'ASSORT.000' = 100000 } `
    -AfterFiles  @{} `
    -MainModelRelativePath 'AnotherProject42.md'
Test-BRAVOCondition `
    -Condition ($resultEmptyDirectory.HasCriticalChanges -and -not $resultEmptyDirectory.MainModelValid) `
    -Name "Maintenance/CompareFileSizesEmptyModelDirectoryCritical" `
    -Failure "порожній каталог MODEL після repair має бути CRITICAL незалежно від per-file порівняння"

# --- Fail-closed без MainModelRelativePath: будь-який зниклий файл лишається
# критичним (виклик, що не зміг визначити основну модель, не повинен
# випадково стати менш безпечним).
$resultNoMainModelKnown = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath $null
Test-BRAVOCondition `
    -Condition $resultNoMainModelKnown.HasCriticalChanges `
    -Name "Maintenance/CompareFileSizesFailClosedWithoutMainModelHint" `
    -Failure "без MainModelRelativePath (викликач не зміг визначити основну модель) будь-який зниклий файл має лишатись критичним — стара fail-closed поведінка"

# --- Hint передано, але його НЕМАЄ у before-CSV + зник сегментний файл ->
# строгий fallback: CRITICAL. Без fallback хибний hint мовчки перетворював
# би ВСІ зниклі файли на RemovedByRepair і знищена модель проходила б
# валідацію без rollback (F1).
$resultHintMismatchMissing = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'OtherName.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'OtherName.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultHintMismatchMissing.HasCriticalChanges -and $resultHintMismatchMissing.RemovedByRepairCount -eq 0) `
    -Name "Maintenance/CompareFileSizesHintNotInInventoryStrictFallback" `
    -Failure "hint, відсутній у before-інвентаризації, має вмикати строгий режим: зниклий файл = CRITICAL, а не RemovedByRepair; отримано HasCriticalChanges=$($resultHintMismatchMissing.HasCriticalChanges), RemovedByRepairCount=$($resultHintMismatchMissing.RemovedByRepairCount)"

# --- Hint відсутній у before-CSV, але ЖОДЕН файл не зник -> НЕ критично
# (строгий fallback сам по собі не породжує false-positive).
$resultHintMismatchNothingMissing = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'OtherName.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'OtherName.md' = 500000; 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition (-not $resultHintMismatchNothingMissing.HasCriticalChanges) `
    -Name "Maintenance/CompareFileSizesHintNotInInventoryNoFalsePositive" `
    -Failure "строгий fallback через хибний hint не повинен давати CRITICAL, коли жоден файл не зник і розміри не змінилися"

# --- Реальна сигнатура інциденту (звіт оператора): .md ІСНУЄ, але
# обнулений (0 байт) -> CRITICAL, MainModelValid=false (isCriticalReduction:
# current 0 <= 2048 при initial > 2048).
$resultMainZeroed = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 0; 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultMainZeroed.HasCriticalChanges -and -not $resultMainZeroed.MainModelValid) `
    -Name "Maintenance/CompareFileSizesMainModelZeroedCritical" `
    -Failure "обнулена основна модель (0 байт, файл існує) має бути CRITICAL з MainModelValid=false — фактична сигнатура реального пошкодження"

# --- MODEL= у підкаталозі: hint із відносним підшляхом збігається з
# RelativePath before-CSV -> зниклий сегмент лишається RemovedByRepair,
# НЕ критичний (нова деривація від MAIN_MODEL_FILE, а не "$MODEL_NAME.md").
$resultSubdirHint = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'sub\TestProject.md' = 500000; 'sub\ACT.000' = 100000 } `
    -AfterFiles  @{ 'sub\TestProject.md' = 500000 } `
    -MainModelRelativePath 'sub\TestProject.md'
Test-BRAVOCondition `
    -Condition (-not $resultSubdirHint.HasCriticalChanges -and $resultSubdirHint.RemovedByRepairCount -eq 1) `
    -Name "Maintenance/CompareFileSizesSubdirectoryHintMatches" `
    -Failure "hint з підкаталогом ('sub\TestProject.md') має збігатися з RelativePath before-CSV: зниклий сегмент = RemovedByRepair, не CRITICAL; отримано HasCriticalChanges=$($resultSubdirHint.HasCriticalChanges), RemovedByRepairCount=$($resultSubdirHint.RemovedByRepairCount)"

# --- Зниклий НЕ-main .md при коректному hint -> CRITICAL. За трасуванням
# реального bravocmd repair перебудовуються лише сегментні файли (.NNN);
# .md ніколи не видаляються. lims0.md/lims1.md — продовження основної
# моделі, табличні DEPART.md тощо — дані; їхнє зникнення = втрата даних.
$resultNonMainMdMissing = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'TestProject0.md' = 300000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultNonMainMdMissing.HasCriticalChanges -and $resultNonMainMdMissing.RemovedByRepairCount -eq 0) `
    -Name "Maintenance/CompareFileSizesNonMainMdMissingCritical" `
    -Failure "зниклий не-main .md (TestProject0.md — продовження моделі) має бути CRITICAL, не RemovedByRepair; отримано HasCriticalChanges=$($resultNonMainMdMissing.HasCriticalChanges), RemovedByRepairCount=$($resultNonMainMdMissing.RemovedByRepairCount)"

# --- Зниклий файл ієрархії (.h1) при коректному hint -> CRITICAL.
$resultHierMissing = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'TestProject.h1' = 50000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultHierMissing.HasCriticalChanges -and $resultHierMissing.RemovedByRepairCount -eq 0) `
    -Name "Maintenance/CompareFileSizesHierarchyFileMissingCritical" `
    -Failure "зниклий файл ієрархії (.h1) має бути CRITICAL, не RemovedByRepair"

# --- Змішаний кейс: зник сегмент .000 (штатно) І зник DEPART.md (втрата
# даних) -> CRITICAL, при цьому сегмент коректно лишається у RemovedByRepair.
$resultMixedMissing = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'AnotherProject42.md' = 500000; 'DEPART.md' = 200000; 'ASSORT.000' = 100000 } `
    -AfterFiles  @{ 'AnotherProject42.md' = 500000 } `
    -MainModelRelativePath 'AnotherProject42.md'
Test-BRAVOCondition `
    -Condition ($resultMixedMissing.HasCriticalChanges -and $resultMixedMissing.RemovedByRepairCount -eq 1) `
    -Name "Maintenance/CompareFileSizesMixedMissingSegmentAndMd" `
    -Failure "змішаний кейс: DEPART.md = CRITICAL, ASSORT.000 = RemovedByRepair(1); отримано HasCriticalChanges=$($resultMixedMissing.HasCriticalChanges), RemovedByRepairCount=$($resultMixedMissing.RemovedByRepairCount)"

# --- Викликач деривує hint від MAIN_MODEL_FILE тим самим правилом, що й
# writer before-CSV (Replace+TrimStart), а не здогадом "$MODEL_NAME.md".
Test-BRAVOCondition `
    -Condition (
        $maintenanceRepairScriptText.Contains(
            '$mainModelRelativeHint = $MAIN_MODEL_FILE.Replace($MODEL_PATH, "").TrimStart(''\'')'
        ) -and
        $maintenanceRepairScriptText.Contains('-MainModelRelativePath $mainModelRelativeHint') -and
        -not $maintenanceRepairScriptText.Contains('-MainModelRelativePath "$MODEL_NAME.md"')
    ) `
    -Name "Maintenance/MainModelHintDerivedFromMainModelFile" `
    -Failure "hint для Compare-FileSizes має деривуватися від MAIN_MODEL_FILE правилом Replace+TrimStart (як writer before-CSV), а не передаватися здогадом `"`$MODEL_NAME.md`""

# ============================================================
# Discord HTTP 429: обмежений retry з пріоритетом на Retry-After.
# ============================================================
$compatibilityScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psm1"),
    [Text.Encoding]::UTF8
)
$webhookStubText = @'
function New-BRAVOFake429Exception {
    param([string]$RetryAfter)
    $fakeHeaders = @{ 'Retry-After' = $RetryAfter }
    $fakeResponse = [PSCustomObject]@{ StatusCode = 429; Headers = $fakeHeaders }
    $exception = New-Object System.Exception('429 Too Many Requests (fake)')
    Add-Member -InputObject $exception -MemberType NoteProperty -Name Response -Value $fakeResponse -Force
    return $exception
}
function Invoke-WebRequest {
    [CmdletBinding()]
    param(
        [string]$Uri,
        [string]$Method,
        [string]$ContentType,
        $Body,
        [int]$TimeoutSec,
        [switch]$UseBasicParsing
    )
    $script:BRAVOFakeWebRequestCallCount++
    if ($script:BRAVOFakeWebRequestCallCount -le $script:BRAVOFakeWebRequest429Count) {
        throw (New-BRAVOFake429Exception -RetryAfter $script:BRAVOFakeWebRequestRetryAfter)
    }
    return [PSCustomObject]@{ StatusCode = 200; Content = '' }
}
'@
$webhookModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText ($webhookStubText + "`n" + $compatibilityScriptText) `
    -FunctionNames @('New-BRAVOFake429Exception', 'Invoke-WebRequest', 'Enable-BRAVOTls12', 'Send-BRAVOWebhookNotification')

# --- 429 один раз, потім успіх -> рівно 2 спроби, успіх.
$webhookRetrySuccessThrew = $false
$webhookRetrySuccessError = $null
$webhookRetrySuccessCallCount = & $webhookModule {
    param($FailCount, $RetryAfter)
    Set-StrictMode -Version Latest
    $script:BRAVOFakeWebRequestCallCount = 0
    $script:BRAVOFakeWebRequest429Count = $FailCount
    $script:BRAVOFakeWebRequestRetryAfter = $RetryAfter
    try {
        Send-BRAVOWebhookNotification -Provider "discord" -WebhookUrl "https://discord.example.invalid/webhook" -Message "test"
    } catch {
        $script:BRAVOFakeWebhookRetryThrew = $true
        $script:BRAVOFakeWebhookRetryError = $_.Exception.Message
    }
    $script:BRAVOFakeWebRequestCallCount
} 1 '0'
Test-BRAVOCondition `
    -Condition ($webhookRetrySuccessCallCount -eq 2) `
    -Name "Notifications/Discord429RetryThenSuccess" `
    -Failure "429 з Retry-After на першій спробі має призвести до рівно 2 викликів Invoke-WebRequest (1 невдала + 1 успішна); отримано: $webhookRetrySuccessCallCount"

# --- 429 постійно -> обмежена невдача (макс. 4 спроби, без нескінченного
# retry), помилка прокидається виклику.
$webhookRetryExhaustedResult = & $webhookModule {
    param($FailCount, $RetryAfter)
    Set-StrictMode -Version Latest
    $script:BRAVOFakeWebRequestCallCount = 0
    $script:BRAVOFakeWebRequest429Count = $FailCount
    $script:BRAVOFakeWebRequestRetryAfter = $RetryAfter
    $threw = $false
    try {
        Send-BRAVOWebhookNotification -Provider "discord" -WebhookUrl "https://discord.example.invalid/webhook" -Message "test"
    } catch {
        $threw = $true
    }
    [PSCustomObject]@{ Threw = $threw; CallCount = $script:BRAVOFakeWebRequestCallCount }
} 99 '0'
Test-BRAVOCondition `
    -Condition ($webhookRetryExhaustedResult.Threw -and $webhookRetryExhaustedResult.CallCount -eq 4) `
    -Name "Notifications/Discord429RetryBoundedNoInfiniteLoop" `
    -Failure "постійний 429 має призвести до РІВНО 4 спроб сумарно (без нескінченного retry) і помилка має прокидатись виклику; отримано Threw=$($webhookRetryExhaustedResult.Threw), CallCount=$($webhookRetryExhaustedResult.CallCount)"

# --- Non-429 помилка НЕ ретраїться (rethrow одразу, без затримки).
$webhookNon429Result = & $webhookModule {
    Set-StrictMode -Version Latest
    function Invoke-WebRequest {
        [CmdletBinding()]
        param($Uri, $Method, $ContentType, $Body, $TimeoutSec, [switch]$UseBasicParsing)
        throw (New-Object System.Net.WebException('DNS resolution failed (fake, not 429)'))
    }
    $threw = $false
    try {
        Send-BRAVOWebhookNotification -Provider "discord" -WebhookUrl "https://discord.example.invalid/webhook" -Message "test"
    } catch {
        $threw = $true
    }
    $threw
}
Test-BRAVOCondition `
    -Condition $webhookNon429Result `
    -Name "Notifications/DiscordNon429NotRetried" `
    -Failure "помилка, що НЕ є 429, має прокидатись одразу без retry-циклу"
