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

if (Enter-BRAVOSelfTestSection -Name 'MaintenanceRepair/Maintenance') { try {
$maintenanceRepairScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
    [Text.Encoding]::UTF8
)

Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
Import-Module -Name (Join-Path $root "modules\BRAVO.Notifications\BRAVO.Notifications.psd1") -Force -ErrorAction Stop

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
function Write-Log {
    param($Message, [string]$Level = 'INFO')
    if ($null -eq (Get-Variable -Name BRAVOCapturedLogMessages -Scope Script -ErrorAction SilentlyContinue)) {
        $script:BRAVOCapturedLogMessages = New-Object System.Collections.ArrayList
    }
    [void]$script:BRAVOCapturedLogMessages.Add([string]$Message)
}
function Send-SlackAlert {
    param($Message, [switch]$IsCritical)
    if ($null -eq (Get-Variable -Name BRAVOCapturedAlerts -Scope Script -ErrorAction SilentlyContinue)) {
        $script:BRAVOCapturedAlerts = New-Object System.Collections.ArrayList
    }
    [void]$script:BRAVOCapturedAlerts.Add([string]$Message)
}
function Get-BRAVOFiles { BRAVO.Compatibility\Get-BRAVOFiles @args }
function Format-BRAVOUkrainianCount { BRAVO.Notifications\Format-BRAVOUkrainianCount @args }
function Format-BRAVONotificationListSummary { BRAVO.Notifications\Format-BRAVONotificationListSummary @args }
'@
$compareFileSizesModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText ($compareFileSizesStubText + "`n" + $maintenanceRepairScriptText) `
    -FunctionNames @('Write-Log', 'Send-SlackAlert', 'Get-BRAVOFiles', 'Format-FileSize', 'Get-BRAVOModelRelativePath', 'Format-BRAVOUkrainianCount', 'Format-BRAVONotificationListSummary', 'New-BRAVOCompareFileSizesResult', 'Compare-FileSizes')

function Invoke-BRAVOCompareFileSizesScenario {
    param(
        [Parameter(Mandatory = $true)][hashtable]$BeforeFiles,
        [Parameter(Mandatory = $true)][hashtable]$AfterFiles,
        [string]$MainModelRelativePath,
        # Реальний інцидент (ЛАБОРАТОРІЯ-6, 2026-08-25): bravo.ini MODEL= містить
        # шлях з іншим регістром (мала літера диска), ніж нормалізований
        # FullName від Get-ChildItem. Перемикач передає Compare-FileSizes
        # той самий каталог, але з повністю зміненим регістром рядка шляху —
        # Windows-резолюція шляху ідентична, відрізняється лише рядок.
        [switch]$InvertModelPathCase,
        # Settle-retry: юніт-сценарії детерміністичні, retry їм не потрібен —
        # 1 спроба без затримки, інакше кожен critical-сценарій чекав би
        # production-бюджет 12×15с. Окремі settle-регресії нижче передають
        # власні значення.
        [int]$MaxSettleAttempts = 1,
        [int]$SettleDelaySeconds = 0,
        # Відкладене створення файлу під час прогону (симуляція AV-затримки
        # видимості): ScriptBlock запускається Start-Job-ом ДО виклику
        # Compare-FileSizes і створює файл у $ScenarioRoot із паузою.
        [scriptblock]$DelayedFileJob,
        # Поріг «малого» файлу; $null — не передавати (дефолт функції 1 МБ).
        $SmallFileThresholdBytes = $null
    )
    $scenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_COMPAREFILESIZES_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($scenarioRoot)
    $effectiveModelPath = if ($InvertModelPathCase) {
        # ToLowerInvariant дає той самий каталог, але інший РЯДОК шляху:
        # літера диска й компоненти на кшталт Users/AppData/Temp стають
        # малими, тоді як enumeration у Compare-FileSizes (тепер прямий
        # [IO.DirectoryInfo]::EnumerateFiles) повертає FullName з фактичним
        # регістром дочірніх компонентів — регістровий розсинхрон кореня
        # лишається точною сигнатурою інциденту, яку канонічно знімає
        # Get-BRAVOModelRelativePath (OrdinalIgnoreCase).
        $scenarioRoot.ToLowerInvariant()
    } else {
        $scenarioRoot
    }
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

        $delayedJob = $null
        if ($null -ne $DelayedFileJob) {
            $delayedJob = Start-Job -ScriptBlock $DelayedFileJob -ArgumentList $scenarioRoot
            # Холодний старт Start-Job (окремий powershell.exe) на
            # завантаженій машині може тривати довше за все retry-вікно —
            # реальний прогін показав старт job-а ПІСЛЯ завершення всіх
            # спроб. Тому job СПОЧАТКУ пише ready-маркер, а сценарій чекає
            # його ДО виклику Compare-FileSizes: гонка «cold start проти
            # retry-вікна» виключена, лишається лише детермінована
            # затримка появи файлу.
            $jobReadyMarker = Join-Path $scenarioRoot '__job_ready.marker'
            $jobReadyDeadline = (Get-Date).AddSeconds(60)
            while (-not (Test-Path -LiteralPath $jobReadyMarker) -and (Get-Date) -lt $jobReadyDeadline) {
                Start-Sleep -Milliseconds 200
            }
        }
        try {
            return & $compareFileSizesModule {
                param($BeforeFile, $ModelPath, $MainModelRelativePath, $MaxSettleAttempts, $SettleDelaySeconds, $SmallFileThresholdBytes)
                Set-StrictMode -Version Latest
                $compareExtraParameters = @{}
                if ($null -ne $SmallFileThresholdBytes) {
                    $compareExtraParameters['SmallFileThresholdBytes'] = [long]$SmallFileThresholdBytes
                }
                Compare-FileSizes -BeforeFile $BeforeFile -ModelPath $ModelPath -MinSizeBytes 2048 `
                    -MainModelRelativePath $MainModelRelativePath `
                    -MaxSettleAttempts $MaxSettleAttempts -SettleDelaySeconds $SettleDelaySeconds `
                    @compareExtraParameters
            } $beforeCsvPath $effectiveModelPath $MainModelRelativePath $MaxSettleAttempts $SettleDelaySeconds $SmallFileThresholdBytes
        } finally {
            if ($null -ne $delayedJob) {
                Wait-Job -Job $delayedJob -Timeout 30 | Out-Null
                Remove-Job -Job $delayedJob -Force -ErrorAction SilentlyContinue
            }
        }
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
# Основна модель тут 5 МБ — понад поріг «малого» файлу (1 МБ), тобто діє
# повне правило (<= MinSizeBytes / >= 50%); реальні основні моделі — ГБ.
$resultMainTiny = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 5242880; 'ACT.000' = 100000 } `
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

# --- Реальна сигнатура провальної реставрації (звіт оператора): .md був
# ~2GB, після repair став 2KB -> CRITICAL, MainModelValid=false. Ловиться
# обома правилами незалежно: current <= MinSizeBytes(2048) і редукція >=50%.
# 2GB перевіряє також [long]-семантику розмірів (понад [int32]::MaxValue).
$resultMainCollapsed2Gb = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 2147483648; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 2048; 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultMainCollapsed2Gb.HasCriticalChanges -and -not $resultMainCollapsed2Gb.MainModelValid) `
    -Name "Maintenance/CompareFileSizesMainModel2GbCollapsedTo2KbCritical" `
    -Failure "основна модель 2GB, що схлопнулась до 2KB після repair, має бути CRITICAL з MainModelValid=false — фактична сигнатура провальної реставрації; отримано HasCriticalChanges=$($resultMainCollapsed2Gb.HasCriticalChanges), MainModelValid=$($resultMainCollapsed2Gb.MainModelValid)"

# --- Та сама сигнатура для НЕ-main файлу > 1GB (звіт оператора: таке
# трапляється і з іншими великими файлами, не лише основною моделлю):
# 1.5GB -> 2KB -> CRITICAL незалежно від імені файлу.
$resultNonMainCollapsed1Gb = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'PROCRSRCH.md' = 1610612736 } `
    -AfterFiles  @{ 'TestProject.md' = 500000; 'PROCRSRCH.md' = 2048 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultNonMainCollapsed1Gb.HasCriticalChanges -and @($resultNonMainCollapsed1Gb.CriticalFiles).Count -eq 1) `
    -Name "Maintenance/CompareFileSizesNonMainOver1GbCollapsedTo2KbCritical" `
    -Failure "не-main файл >1GB, що схлопнувся до 2KB після repair, має бути CRITICAL незалежно від імені; отримано HasCriticalChanges=$($resultNonMainCollapsed1Gb.HasCriticalChanges), CriticalFiles=$(@($resultNonMainCollapsed1Gb.CriticalFiles).Count)"

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
# ============================================================
# Check-MdFileSizes: реальна runtime-функція на реальних файлах.
# Перевірка розмірів .md іде ПІСЛЯ реставрації (bravocmd repair штатно
# стискає .md), тож вона бачить розмір, який лишився після repair:
# (a) файл був понад ліміт, repair його стиснув -> жодного WARNING/alert;
# (b) файл лишився понад ліміт після repair -> WARNING і одне critical-сповіщення;
# (c) виключення з конфігурації далі діють. Блок — у дочірньому scope,
# щоб не додавати змінних у script-scope цього flat-файлу (#163).
# ============================================================
& {
    $mdSizeStubText = @'
function Write-Log {
    param($Message, [string]$Level = 'INFO')
    if ($null -eq (Get-Variable -Name BRAVOCapturedLogMessages -Scope Script -ErrorAction SilentlyContinue)) {
        $script:BRAVOCapturedLogMessages = New-Object System.Collections.ArrayList
    }
    [void]$script:BRAVOCapturedLogMessages.Add(('{0}|{1}' -f $Level, [string]$Message))
}
function Send-SlackAlert {
    param($Message, [switch]$IsCritical)
    if ($null -eq (Get-Variable -Name BRAVOCapturedAlerts -Scope Script -ErrorAction SilentlyContinue)) {
        $script:BRAVOCapturedAlerts = New-Object System.Collections.ArrayList
    }
    [void]$script:BRAVOCapturedAlerts.Add(('{0}|{1}' -f [bool]$IsCritical, [string]$Message))
}
function Format-BRAVOUkrainianCount { BRAVO.Notifications\Format-BRAVOUkrainianCount @args }
function Format-BRAVONotificationListSummary { BRAVO.Notifications\Format-BRAVONotificationListSummary @args }
'@
    $mdSizeModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($mdSizeStubText + "`n" + $maintenanceRepairScriptText) `
        -FunctionNames @('Write-Log', 'Send-SlackAlert', 'Format-FileSize', 'Get-BRAVOModelRelativePath', 'Format-BRAVOUkrainianCount', 'Format-BRAVONotificationListSummary', 'Check-MdFileSizes')
    $mdSizeRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_MDSIZE_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        $mdSizeScenario = {
            param([int64]$SizeBeforeRepair, [int64]$SizeAfterRepair, [string[]]$ExcludePatterns)
            if (Test-Path -LiteralPath $mdSizeRoot) { Remove-Item -LiteralPath $mdSizeRoot -Recurse -Force }
            [void][IO.Directory]::CreateDirectory((Join-Path $mdSizeRoot 'TestProject'))
            $mdSizeFile = Join-Path $mdSizeRoot 'TestProject\TestProject.md'
            # Модель до реставрації, потім «repair» переписує файл новим розміром.
            [IO.File]::WriteAllBytes($mdSizeFile, (New-Object byte[] $SizeBeforeRepair))
            [IO.File]::WriteAllBytes($mdSizeFile, (New-Object byte[] $SizeAfterRepair))
            [IO.File]::WriteAllBytes((Join-Path $mdSizeRoot 'TestProject\Small.md'), (New-Object byte[] 512))
            return (& $mdSizeModule {
                param($ModelPath, $Excludes)
                Set-StrictMode -Version Latest
                $script:BRAVOCapturedAlerts = New-Object System.Collections.ArrayList
                $script:BRAVOCapturedLogMessages = New-Object System.Collections.ArrayList
                Check-MdFileSizes -MODEL_PATH $ModelPath -MAX_MD_FILE_SIZE 4096 -ExcludePatterns $Excludes
                [pscustomobject]@{
                    Alerts = @($script:BRAVOCapturedAlerts)
                    Warnings = @($script:BRAVOCapturedLogMessages | Where-Object { ([string]$_).StartsWith('WARNING|') })
                }
            } $mdSizeRoot $ExcludePatterns)
        }

        $mdShrunk = & $mdSizeScenario 8192 2048 @()
        Test-BRAVOCondition `
            -Condition ($mdShrunk.Alerts.Count -eq 0 -and $mdShrunk.Warnings.Count -eq 0) `
            -Name "Maintenance/MdSizeCheckNoAlertWhenRepairShrankFile" `
            -Failure "файл .md, що був понад ліміт до repair і став меншим за ліміт після нього, не повинен давати WARNING чи сповіщення; alerts=$($mdShrunk.Alerts.Count), warnings=$($mdShrunk.Warnings.Count)"

        $mdStillLarge = & $mdSizeScenario 8192 6144 @()
        Test-BRAVOCondition `
            -Condition (
                $mdStillLarge.Alerts.Count -eq 1 -and
                ([string]$mdStillLarge.Alerts[0]).StartsWith('True|') -and
                ([string]$mdStillLarge.Alerts[0]).Contains('TestProject.md') -and
                -not ([string]$mdStillLarge.Alerts[0]).Contains('Small.md') -and
                $mdStillLarge.Warnings.Count -eq 1 -and
                ([string]$mdStillLarge.Warnings[0]).Contains('TestProject.md')
            ) `
            -Name "Maintenance/MdSizeCheckAlertsWhenFileStaysOversizedAfterRepair" `
            -Failure "файл .md, що лишився понад ліміт після repair, має дати рівно один WARNING і одне critical-сповіщення з його назвою; alerts=$($mdStillLarge.Alerts -join ' // '); warnings=$($mdStillLarge.Warnings -join ' // ')"

        $mdExcluded = & $mdSizeScenario 8192 6144 @('TestProject.md')
        Test-BRAVOCondition `
            -Condition ($mdExcluded.Alerts.Count -eq 0 -and $mdExcluded.Warnings.Count -eq 0) `
            -Name "Maintenance/MdSizeCheckHonoursExclusionsAfterRepair" `
            -Failure "файл .md із виключень конфігурації не повинен давати WARNING чи сповіщення навіть понад ліміт; alerts=$($mdExcluded.Alerts.Count), warnings=$($mdExcluded.Warnings.Count)"
    } finally {
        if (Test-Path -LiteralPath $mdSizeRoot) {
            Remove-Item -LiteralPath $mdSizeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
} catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'MaintenanceRepair/Maintenance' } }
if (Enter-BRAVOSelfTestSection -Name 'MaintenanceRepair/Maintenance.CompareFileSizesMixedMissingSegmentAndMd' -DependsOn 'MaintenanceRepair/Maintenance') { try {

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

# --- Зниклий .$$$ (тимчасовий робочий файл bravocmd, залишок перерваного
# repair) -> RemovedByRepair, НЕ критично: як і .NNN-сегменти, це транзитний
# артефакт, а не дані. Інакше orphan .$$$ давав би false-positive rollback.
$resultTempMissing = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'KZPpat.$$$' = 155273552 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition (-not $resultTempMissing.HasCriticalChanges -and $resultTempMissing.RemovedByRepairCount -eq 1) `
    -Name "Maintenance/CompareFileSizesTempDollarFileNotCritical" `
    -Failure "зниклий .`$`$`$ (temp bravocmd) має бути RemovedByRepair, не CRITICAL; отримано HasCriticalChanges=$($resultTempMissing.HasCriticalChanges), RemovedByRepairCount=$($resultTempMissing.RemovedByRepairCount)"

# --- Змішаний: зник .$$$ (temp, не критично) + зник .md (дані, критично)
# -> CRITICAL, а .$$$ лишається у RemovedByRepair.
$resultTempAndMd = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'DEPART.md' = 200000; 'KZPpat.$$$' = 148000000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultTempAndMd.HasCriticalChanges -and $resultTempAndMd.RemovedByRepairCount -eq 1) `
    -Name "Maintenance/CompareFileSizesTempDollarPlusMdMixed" `
    -Failure "змішаний: DEPART.md = CRITICAL, KZPpat.`$`$`$ = RemovedByRepair(1); отримано HasCriticalChanges=$($resultTempAndMd.HasCriticalChanges), RemovedByRepairCount=$($resultTempAndMd.RemovedByRepairCount)"

# --- Регресія реального інциденту (ЛАБОРАТОРІЯ-6, 2026-08-25, exit 43):
# bravo.ini MODEL= з малою літерою диска ("d:\LIMS\Model"), Get-ChildItem
# нормалізує FullName до "D:\...", ordinal Replace НЕ зрізав корінь, ключі
# lookup ставали абсолютними шляхами і ВСІ 546 файлів before-CSV оголошувались
# відсутніми (364 CRITICAL + 182 RemovedByRepair) навіть одразу після
# успішного rollback. Той самий каталог, змінено лише регістр рядка шляху ->
# нічого не зникло -> НЕ критично.
$resultRootCaseMismatch = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md' `
    -InvertModelPathCase
Test-BRAVOCondition `
    -Condition (-not $resultRootCaseMismatch.HasCriticalChanges -and $resultRootCaseMismatch.RemovedByRepairCount -eq 0) `
    -Name "Maintenance/CompareFileSizesRootCaseInsensitive" `
    -Failure "ModelPath з іншим регістром (той самий каталог) не повинен перетворювати всі файли на 'відсутні': HasCriticalChanges має бути false; отримано HasCriticalChanges=$($resultRootCaseMismatch.HasCriticalChanges), RemovedByRepairCount=$($resultRootCaseMismatch.RemovedByRepairCount), CriticalFiles=$(@($resultRootCaseMismatch.CriticalFiles).Count)"

# --- Той самий регістровий розсинхрон + штатно зниклий сегмент: класифікація
# RemovedByRepair/critical має працювати ідентично незалежно від регістру кореня.
$resultRootCaseMismatchSegment = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md' `
    -InvertModelPathCase
Test-BRAVOCondition `
    -Condition (-not $resultRootCaseMismatchSegment.HasCriticalChanges -and $resultRootCaseMismatchSegment.RemovedByRepairCount -eq 1) `
    -Name "Maintenance/CompareFileSizesRootCaseInsensitiveSegmentRemoved" `
    -Failure "при регістровому розсинхроні кореня зниклий сегмент .000 має класифікуватись RemovedByRepair(1), не CRITICAL; отримано HasCriticalChanges=$($resultRootCaseMismatchSegment.HasCriticalChanges), RemovedByRepairCount=$($resultRootCaseMismatchSegment.RemovedByRepairCount)"

# --- Юніт-контракт Get-BRAVOModelRelativePath: регістронезалежний зріз
# кореня, точний збіг -> '', шлях поза коренем -> без змін (fail-closed).
$relativePathScenarios = @(
    @{ FullName = 'D:\LIMS\Model\ACT.md';       Root = 'd:\lims\model';    Expected = 'ACT.md';        Label = 'CaseInsensitiveRoot' }
    @{ FullName = 'D:\LIMS\Model\sub\x.000';    Root = 'D:\LIMS\Model';    Expected = 'sub\x.000';     Label = 'Subdirectory' }
    @{ FullName = 'D:\LIMS\Model';              Root = 'd:\LIMS\MODEL\';   Expected = '';              Label = 'ExactRootMatch' }
    @{ FullName = 'E:\Other\file.md';           Root = 'D:\LIMS\Model';    Expected = 'E:\Other\file.md'; Label = 'OutsideRootUnchanged' }
    @{ FullName = 'D:\LIMS\ModelBackup\a.md';   Root = 'D:\LIMS\Model';    Expected = 'D:\LIMS\ModelBackup\a.md'; Label = 'PrefixNotComponentBoundary' }
)
foreach ($scenario in $relativePathScenarios) {
    $derived = & $compareFileSizesModule {
        param($FullName, $RootPath)
        Get-BRAVOModelRelativePath -FullName $FullName -RootPath $RootPath
    } $scenario.FullName $scenario.Root
    Test-BRAVOCondition `
        -Condition ($derived -ceq $scenario.Expected) `
        -Name "Maintenance/ModelRelativePath[$($scenario.Label)]" `
        -Failure "Get-BRAVOModelRelativePath('$($scenario.FullName)', '$($scenario.Root)') має повернути '$($scenario.Expected)'; отримано '$derived'"
}

# ============================================================
# Compact notification: операторський alert = count + ≤5 прикладів;
# повна діагностика (4 рядки/файл) лишається ТІЛЬКИ в журналі.
# Реальний інцидент: сотні critical-файлів → 4×N рядків у транспорт →
# серія Discord-повідомлень. Contract: one event -> one notification.
# ============================================================
function Get-BRAVOCompareCaptured {
    param([Parameter(Mandatory = $true)][ValidateSet('Alerts', 'Logs')][string]$Kind)
    return @(& $compareFileSizesModule {
        param($Which)
        if ($Which -eq 'Alerts') {
            if ($null -eq (Get-Variable -Name BRAVOCapturedAlerts -Scope Script -ErrorAction SilentlyContinue)) { @() } else { @($script:BRAVOCapturedAlerts) }
        } else {
            if ($null -eq (Get-Variable -Name BRAVOCapturedLogMessages -Scope Script -ErrorAction SilentlyContinue)) { @() } else { @($script:BRAVOCapturedLogMessages) }
        }
    } $Kind)
}
function Clear-BRAVOCompareCaptured {
    & $compareFileSizesModule {
        $script:BRAVOCapturedAlerts = New-Object System.Collections.ArrayList
        $script:BRAVOCapturedLogMessages = New-Object System.Collections.ArrayList
    }
}

# --- 341 critical: рівно ОДИН alert, компактний; повний список у лозі ---
$compactBefore = @{ 'TestProject.md' = 500000 }
for ($compactIndex = 1; $compactIndex -le 341; $compactIndex++) {
    $compactBefore[('F{0:000}.md' -f $compactIndex)] = 10000
}
Clear-BRAVOCompareCaptured
$compact341 = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles $compactBefore `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md'
$compact341Alerts = @(Get-BRAVOCompareCaptured -Kind Alerts)
$compact341Logs = @(Get-BRAVOCompareCaptured -Kind Logs)
$compact341DetailedLog = @($compact341Logs | Where-Object { $_ -like '*Розмір до реставрації*' } | Select-Object -First 1)
Test-BRAVOCondition `
    -Condition (
        $compact341.HasCriticalChanges -and
        @($compact341Alerts).Count -eq 1 -and
        $compact341Alerts[0].Contains('341 файл') -and
        $compact341Alerts[0].Contains('…і ще 336 файлів.') -and
        $compact341Alerts[0].Length -lt 1800 -and
        -not $compact341Alerts[0].Contains('Розмір до реставрації') -and
        (@($compact341Alerts[0] -split "`n" | Where-Object { $_ -like '• *' }).Count -eq 5) -and
        @($compact341DetailedLog).Count -eq 1 -and
        $compact341DetailedLog[0].Contains('F001.md') -and
        $compact341DetailedLog[0].Contains('F341.md') -and
        $compact341DetailedLog[0].Contains('Розмір до реставрації')
    ) `
    -Name "Maintenance/CompactAlert341FilesOneNotificationFullLog" `
    -Failure "341 critical: рівно 1 alert (<1800 симв., '341 файл', '…і ще 336 файлів.', 5 прикладів, БЕЗ 'Розмір до реставрації'); повний список (F001..F341 + деталі) лишається в лозі; факт: alerts=$(@($compact341Alerts).Count), len=$(if (@($compact341Alerts).Count) { $compact341Alerts[0].Length } else { 0 })"

# --- 3 critical (<=5): усі показані, БЕЗ '…і ще' ---
Clear-BRAVOCompareCaptured
[void](Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'A.md' = 9000; 'B.md' = 9000; 'C.md' = 9000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md')
$compact3Alerts = @(Get-BRAVOCompareCaptured -Kind Alerts)
Test-BRAVOCondition `
    -Condition (
        @($compact3Alerts).Count -eq 1 -and
        $compact3Alerts[0].Contains('3 файли') -and
        (@($compact3Alerts[0] -split "`n" | Where-Object { $_ -like '• *' }).Count -eq 3) -and
        -not $compact3Alerts[0].Contains('і ще')
    ) `
    -Name "Maintenance/CompactAlertThreeFilesShowsAllNoRemainder" `
    -Failure "3 critical: усі 3 приклади, без '…і ще'; факт: $(if (@($compact3Alerts).Count) { $compact3Alerts[0] } else { 'alert відсутній' })"

# --- 6 critical: 5 прикладів + '…і ще 1 файл.' ---
Clear-BRAVOCompareCaptured
[void](Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'A.md' = 9000; 'B.md' = 9000; 'C.md' = 9000; 'D.md' = 9000; 'E.md' = 9000; 'G.md' = 9000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md')
$compact6Alerts = @(Get-BRAVOCompareCaptured -Kind Alerts)
Test-BRAVOCondition `
    -Condition (
        @($compact6Alerts).Count -eq 1 -and
        (@($compact6Alerts[0] -split "`n" | Where-Object { $_ -like '• *' }).Count -eq 5) -and
        $compact6Alerts[0].Contains('…і ще 1 файл.')
    ) `
    -Name "Maintenance/CompactAlertSixFilesShowsFivePlusRemainder" `
    -Failure "6 critical: 5 прикладів + '…і ще 1 файл.'; факт: $(if (@($compact6Alerts).Count) { $compact6Alerts[0] } else { 'alert відсутній' })"

# --- missing vs редукція: різні короткі формати (structured, без parsing) ---
Clear-BRAVOCompareCaptured
[void](Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'GONE.md' = 2048000; 'DATABASE.md' = 5000000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000; 'DATABASE.md' = 1000000 } `
    -MainModelRelativePath 'TestProject.md')
$compactKindAlerts = @(Get-BRAVOCompareCaptured -Kind Alerts)
Test-BRAVOCondition `
    -Condition (
        @($compactKindAlerts).Count -eq 1 -and
        $compactKindAlerts[0] -match 'GONE\.md — файл відсутній \(було ' -and
        $compactKindAlerts[0] -match 'DATABASE\.md — .+ → .+ \(-80[,.]0%\)'
    ) `
    -Name "Maintenance/CompactAlertDistinguishesMissingVsReduction" `
    -Failure "missing -> 'файл відсутній (було ...)'; редукція 5000000->1000000 -> '<before> → <after> (-80,0%)'; факт: $(if (@($compactKindAlerts).Count) { $compactKindAlerts[0] } else { 'alert відсутній' })"

# --- Unicode/вкладені шляхи/пробіли не ламають compact-формат ---
Clear-BRAVOCompareCaptured
[void](Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; '#\tbl\antib41.csv' = 9000; 'Eqv\ЗВТ_13-80.pdf' = 9000; 'Folder With Spaces\Test.md' = 9000; 'Довідники\Аналіз №1.md' = 9000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md')
$compactUnicodeAlerts = @(Get-BRAVOCompareCaptured -Kind Alerts)
Test-BRAVOCondition `
    -Condition (
        @($compactUnicodeAlerts).Count -eq 1 -and
        $compactUnicodeAlerts[0].Contains('#\tbl\antib41.csv — файл відсутній') -and
        $compactUnicodeAlerts[0].Contains('Eqv\ЗВТ_13-80.pdf — файл відсутній') -and
        $compactUnicodeAlerts[0].Contains('Folder With Spaces\Test.md — файл відсутній') -and
        $compactUnicodeAlerts[0].Contains('Довідники\Аналіз №1.md — файл відсутній')
    ) `
    -Name "Maintenance/CompactAlertHandlesUnicodeAndNestedPaths" `
    -Failure "compact-формат має коректно нести #\, кирилицю, пробіли і вкладені шляхи; факт: $(if (@($compactUnicodeAlerts).Count) { $compactUnicodeAlerts[0] } else { 'alert відсутній' })"

# --- Викликач деривує hint від MAIN_MODEL_FILE тим самим канонічним правилом
# Get-BRAVOModelRelativePath, що й writer before-CSV та lookup у
# Compare-FileSizes, а не здогадом "$MODEL_NAME.md" і не ordinal Replace
# (регістрочутливий Replace — корінь інциденту ЛАБОРАТОРІЯ-6 2026-08-25).
Test-BRAVOCondition `
    -Condition (
        $maintenanceRepairScriptText.Contains(
            '$mainModelRelativeHint = Get-BRAVOModelRelativePath -FullName $MAIN_MODEL_FILE -RootPath $MODEL_PATH'
        ) -and
        $maintenanceRepairScriptText.Contains('-MainModelRelativePath $mainModelRelativeHint') -and
        -not $maintenanceRepairScriptText.Contains('-MainModelRelativePath "$MODEL_NAME.md"') -and
        -not $maintenanceRepairScriptText.Contains('.Replace($MODEL_PATH, "").TrimStart') -and
        -not $maintenanceRepairScriptText.Contains('.Replace($ModelPath, "").TrimStart')
    ) `
    -Name "Maintenance/MainModelHintDerivedFromMainModelFile" `
    -Failure "hint/writer/lookup мають деривувати відносний шлях канонічним Get-BRAVOModelRelativePath (регістронезалежно), без залишків ordinal Replace+TrimStart і без здогаду `"`$MODEL_NAME.md`""

# --- Settle-retry (порт 67f3ad3/f7f6628 з backup/local-developer-rc2-line):
# транзитно «невидимий» файл (симуляція AV-затримки видимості щойно
# записаних .md) з'являється на диску ПІД ЧАС retry-вікна — Compare-FileSizes
# має відновитись без critical. Файл створюється окремим процесом
# (Start-Job), бо enumeration тепер прямий .NET-виклик і не мокабельний.
$settleRecoveredResult = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md' `
    -MaxSettleAttempts 20 -SettleDelaySeconds 2 `
    -DelayedFileJob {
        param($ScenarioRoot)
        # Ready-маркер ПЕРШИМ (harness чекає його до старту compare) —
        # див. коментар у Invoke-BRAVOCompareFileSizesScenario. Файл
        # з'являється через 2 с після маркера — гарантовано всередині
        # retry-вікна 20×2с.
        [IO.File]::WriteAllText((Join-Path $ScenarioRoot '__job_ready.marker'), 'ready')
        Start-Sleep -Seconds 2
        [IO.File]::WriteAllBytes((Join-Path $ScenarioRoot 'TestProject.md'), (New-Object byte[] 500000))
    }
Test-BRAVOCondition `
    -Condition (-not $settleRecoveredResult.HasCriticalChanges -and $settleRecoveredResult.MainModelValid) `
    -Name "Maintenance/CompareFileSizesSettleRetryRecoversTransientlyMissingFile" `
    -Failure "файл, що став видимим у settle-вікні, не повинен лишати CRITICAL; отримано HasCriticalChanges=$($settleRecoveredResult.HasCriticalChanges), MainModelValid=$($settleRecoveredResult.MainModelValid)"

# --- Settle-retry НЕ послаблює fail-closed: справді відсутня основна модель
# лишається критичною після всіх спроб.
$settleStillCriticalResult = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md' `
    -MaxSettleAttempts 2 -SettleDelaySeconds 0
Test-BRAVOCondition `
    -Condition ($settleStillCriticalResult.HasCriticalChanges -and -not $settleStillCriticalResult.MainModelValid) `
    -Name "Maintenance/CompareFileSizesSettleRetryStillCriticalWhenGenuinelyMissing" `
    -Failure "справді відсутній файл після всіх settle-спроб мусить лишатися CRITICAL (fail-closed не послаблено); отримано HasCriticalChanges=$($settleStillCriticalResult.HasCriticalChanges)"

# ============================================================
# Поріг «малого» файлу (SmallFileThresholdBytes, типово 1 МБ).
# Реальний хибний rollback (exit 43): невеликий табличний файл після
# легітимного ущільнення repair-ом зменшився 4,5 КБ -> 2,0 КБ (-55,6%).
# Для файлів < порогу ДО реставрації критичними є лише зникнення та
# обнулення; файли від порогу — незмінне правило (>= 50% / <= 2048 байт).
# ============================================================
# --- Малий файл 4608 -> 2046 байт (-55,6%, і <= 2048) -> НЕ критично,
# але видимий в INFO-журналі; жодного alert.
Clear-BRAVOCompareCaptured
$smallShrinkResult = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 5242880; 'TABLE-A.md' = 4608 } `
    -AfterFiles  @{ 'TestProject.md' = 5242880; 'TABLE-A.md' = 2046 } `
    -MainModelRelativePath 'TestProject.md'
$smallShrinkAlerts = @(Get-BRAVOCompareCaptured -Kind Alerts)
$smallShrinkInfoLog = @(@(Get-BRAVOCompareCaptured -Kind Logs) | Where-Object { $_ -like '*малих файлів MODEL*' -and $_ -like '*TABLE-A.md*' })
Test-BRAVOCondition `
    -Condition (
        -not $smallShrinkResult.HasCriticalChanges -and
        $smallShrinkResult.MainModelValid -and
        @($smallShrinkResult.CriticalFiles).Count -eq 0 -and
        $smallShrinkResult.SmallFileReductionCount -eq 1 -and
        @($smallShrinkAlerts).Count -eq 0 -and
        @($smallShrinkInfoLog).Count -eq 1 -and
        ($smallShrinkInfoLog[0].Contains('-55,6%') -or $smallShrinkInfoLog[0].Contains('-55.6%'))
    ) `
    -Name "Maintenance/CompareFileSizesSmallFileShrinkNotCritical" `
    -Failure "малий файл 4608 -> 2046 байт має бути НЕ критичним (без alert/rollback), але видимим в INFO-журналі; отримано HasCriticalChanges=$($smallShrinkResult.HasCriticalChanges), SmallFileReductionCount=$($smallShrinkResult.SmallFileReductionCount), alerts=$(@($smallShrinkAlerts).Count), infoLog=$(@($smallShrinkInfoLog).Count)"

# --- Малий файл обнулено (0 байт, файл існує) -> CRITICAL.
$smallZeroResult = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 5242880; 'TABLE-A.md' = 4608 } `
    -AfterFiles  @{ 'TestProject.md' = 5242880; 'TABLE-A.md' = 0 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition (
        $smallZeroResult.HasCriticalChanges -and
        @($smallZeroResult.CriticalFiles).Count -eq 1 -and
        [string]$smallZeroResult.CriticalFiles[0].File -eq 'TABLE-A.md' -and
        $smallZeroResult.SmallFileReductionCount -eq 0
    ) `
    -Name "Maintenance/CompareFileSizesSmallFileZeroedCritical" `
    -Failure "малий файл, обнулений до 0 байт, має лишатися CRITICAL; отримано HasCriticalChanges=$($smallZeroResult.HasCriticalChanges), CriticalFiles=$(@($smallZeroResult.CriticalFiles).Count)"

# --- Малий (не транзитний) файл зник -> CRITICAL (логіка відсутніх файлів
# незмінна).
$smallMissingResult = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 5242880; 'TABLE-A.md' = 4608 } `
    -AfterFiles  @{ 'TestProject.md' = 5242880 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition (
        $smallMissingResult.HasCriticalChanges -and
        @($smallMissingResult.CriticalFiles).Count -eq 1 -and
        [bool]$smallMissingResult.CriticalFiles[0].Missing -and
        $smallMissingResult.RemovedByRepairCount -eq 0
    ) `
    -Name "Maintenance/CompareFileSizesSmallFileMissingCritical" `
    -Failure "зниклий малий файл (не сегмент .NNN) має лишатися CRITICAL; отримано HasCriticalChanges=$($smallMissingResult.HasCriticalChanges), CriticalFiles=$(@($smallMissingResult.CriticalFiles).Count), RemovedByRepairCount=$($smallMissingResult.RemovedByRepairCount)"

# --- Великий файл 4 МБ -> 1,5 МБ (-62,5%) -> CRITICAL (правило 50% діє).
$largeShrinkResult = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 5242880; 'FILE-A.md' = 4194304 } `
    -AfterFiles  @{ 'TestProject.md' = 5242880; 'FILE-A.md' = 1572864 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition (
        $largeShrinkResult.HasCriticalChanges -and
        @($largeShrinkResult.CriticalFiles).Count -eq 1 -and
        [string]$largeShrinkResult.CriticalFiles[0].File -eq 'FILE-A.md' -and
        $largeShrinkResult.SmallFileReductionCount -eq 0
    ) `
    -Name "Maintenance/CompareFileSizesLargeFileHalfShrinkCritical" `
    -Failure "великий файл 4 МБ -> 1,5 МБ (>= 50%) має лишатися CRITICAL; отримано HasCriticalChanges=$($largeShrinkResult.HasCriticalChanges), CriticalFiles=$(@($largeShrinkResult.CriticalFiles).Count)"

# --- Великий файл 4 МБ -> 3 МБ (-25%) -> НЕ критично.
$largeMildResult = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 5242880; 'FILE-A.md' = 4194304 } `
    -AfterFiles  @{ 'TestProject.md' = 5242880; 'FILE-A.md' = 3145728 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition (-not $largeMildResult.HasCriticalChanges -and $largeMildResult.SmallFileReductionCount -eq 0) `
    -Name "Maintenance/CompareFileSizesLargeFileMildShrinkNotCritical" `
    -Failure "великий файл 4 МБ -> 3 МБ (-25%) не має бути CRITICAL; отримано HasCriticalChanges=$($largeMildResult.HasCriticalChanges)"

# --- Поріг 0 = найсуворіший режим: правило 50% знову діє і для малих
# файлів (той самий 4608 -> 2046 стає CRITICAL).
$strictThresholdResult = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 5242880; 'TABLE-A.md' = 4608 } `
    -AfterFiles  @{ 'TestProject.md' = 5242880; 'TABLE-A.md' = 2046 } `
    -MainModelRelativePath 'TestProject.md' `
    -SmallFileThresholdBytes 0
Test-BRAVOCondition `
    -Condition ($strictThresholdResult.HasCriticalChanges -and @($strictThresholdResult.CriticalFiles).Count -eq 1) `
    -Name "Maintenance/CompareFileSizesZeroThresholdKeepsFullRule" `
    -Failure "SmallFileThresholdBytes=0 має застосовувати повне правило до всіх файлів; отримано HasCriticalChanges=$($strictThresholdResult.HasCriticalChanges)"

# --- Від'ємний поріг, переданий напряму, -> типові 1 МБ (fail-closed):
# малий файл 4608 -> 2046 не критичний, а великий 4 МБ -> 1,5 МБ —
# критичний (перевірку не вимкнено).
$negativeThresholdResult = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 5242880; 'TABLE-A.md' = 4608; 'FILE-A.md' = 4194304 } `
    -AfterFiles  @{ 'TestProject.md' = 5242880; 'TABLE-A.md' = 2046; 'FILE-A.md' = 1572864 } `
    -MainModelRelativePath 'TestProject.md' `
    -SmallFileThresholdBytes -5
Test-BRAVOCondition `
    -Condition (
        $negativeThresholdResult.HasCriticalChanges -and
        @($negativeThresholdResult.CriticalFiles).Count -eq 1 -and
        [string]$negativeThresholdResult.CriticalFiles[0].File -eq 'FILE-A.md' -and
        $negativeThresholdResult.SmallFileReductionCount -eq 1
    ) `
    -Name "Maintenance/CompareFileSizesNegativeThresholdFallsBackToDefault" `
    -Failure "від'ємний SmallFileThresholdBytes має давати типовий поріг 1 МБ; отримано HasCriticalChanges=$($negativeThresholdResult.HasCriticalChanges), CriticalFiles=$(@($negativeThresholdResult.CriticalFiles).Count), SmallFileReductionCount=$($negativeThresholdResult.SmallFileReductionCount)"

# --- Resolve-BRAVORestoreSmallFileThresholdBytes: читання конфігурації
# Restore.IntegritySmallFileThresholdBytes. Некоректне значення ніколи не
# вимикає перевірку: типові 1048576 + InvalidValue для WARNING.
$thresholdResolverModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText $maintenanceRepairScriptText `
    -FunctionNames @('Resolve-BRAVORestoreSmallFileThresholdBytes')
$thresholdResolverCases = @(
    @{ Label = 'Missing';        Value = $null;        Expected = 1048576;   ExpectInvalid = $false }
    @{ Label = 'ValidInt';       Value = 524288;       Expected = 524288;    ExpectInvalid = $false }
    @{ Label = 'ValidString';    Value = ' 2097152 ';  Expected = 2097152;   ExpectInvalid = $false }
    @{ Label = 'Zero';           Value = 0;            Expected = 0;         ExpectInvalid = $false }
    @{ Label = 'Maximum';        Value = 104857600;    Expected = 104857600; ExpectInvalid = $false }
    @{ Label = 'Negative';       Value = -1;           Expected = 1048576;   ExpectInvalid = $true }
    @{ Label = 'AboveMaximum';   Value = 104857601;    Expected = 1048576;   ExpectInvalid = $true }
    @{ Label = 'Fraction';       Value = 1.5;          Expected = 1048576;   ExpectInvalid = $true }
    @{ Label = 'NotANumber';     Value = 'abc';        Expected = 1048576;   ExpectInvalid = $true }
    @{ Label = 'EmptyString';    Value = '';           Expected = 1048576;   ExpectInvalid = $true }
    @{ Label = 'Boolean';        Value = $true;        Expected = 1048576;   ExpectInvalid = $true }
)
foreach ($thresholdCase in $thresholdResolverCases) {
    $thresholdResolved = & $thresholdResolverModule {
        param($Value)
        Set-StrictMode -Version Latest
        Resolve-BRAVORestoreSmallFileThresholdBytes -Value $Value
    } $thresholdCase.Value
    $thresholdIsInvalid = $null -ne $thresholdResolved.InvalidValue
    Test-BRAVOCondition `
        -Condition (
            [long]$thresholdResolved.ThresholdBytes -eq [long]$thresholdCase.Expected -and
            $thresholdIsInvalid -eq [bool]$thresholdCase.ExpectInvalid
        ) `
        -Name "Maintenance/RestoreSmallFileThresholdConfig[$($thresholdCase.Label)]" `
        -Failure "Resolve-BRAVORestoreSmallFileThresholdBytes('$($thresholdCase.Value)') має дати $($thresholdCase.Expected) (InvalidValue очікувано: $($thresholdCase.ExpectInvalid)); отримано $($thresholdResolved.ThresholdBytes), InvalidValue='$($thresholdResolved.InvalidValue)'"
}

# --- Ключ конфігурації протягнуто до реальної перевірки: runtime читає
# Restore.IntegritySmallFileThresholdBytes через резолвер і передає
# результат у Invoke-BRAVOModelRestoreRecovery, а той — в обидва
# виклики Compare-FileSizes (до і після відкату).
Test-BRAVOCondition `
    -Condition (
        $maintenanceRepairScriptText.Contains('$RestoreSmallFileThreshold = Resolve-BRAVORestoreSmallFileThresholdBytes -Value $restoreSmallFileThresholdRawValue') -and
        $maintenanceRepairScriptText.Contains('-SmallFileThresholdBytes $RestoreSmallFileThreshold.ThresholdBytes') -and
        ([regex]::Matches($maintenanceRepairScriptText, '-SmallFileThresholdBytes \$SmallFileThresholdBytes')).Count -eq 2
    ) `
    -Name "Maintenance/RestoreSmallFileThresholdWiredToCompare" `
    -Failure "поріг Restore.IntegritySmallFileThresholdBytes має доходити від конфігурації до обох викликів Compare-FileSizes у Invoke-BRAVOModelRestoreRecovery"

# ============================================================
# Discord HTTP 429: обмежений retry з пріоритетом на Retry-After.
#
# УВАГА (пастка, реально спіймана 2026-08-26): New-Module у
# New-BRAVOSelfTestRuntimeModule авто-імпортує dynamic module у СЕСІЮ,
# тому фейкові Invoke-WebRequest і Start-Sleep звідси стають видимими
# ГЛОБАЛЬНО після цієї секції — зокрема Start-Sleep перетворюється на
# no-op лічильник. Будь-які нові сценарії, що покладаються на РЕАЛЬНИЙ
# Start-Sleep/мережу (напр. settle-retry Compare-FileSizes вище),
# додавайте ПЕРЕД цією секцією.
# ============================================================
$compatibilityScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psm1"),
    [Text.Encoding]::UTF8
)
$webhookStubText = @'
function New-BRAVOFake429Exception {
    param([string]$RetryAfter, [int]$StatusCode = 429)
    $fakeHeaders = @{ 'Retry-After' = $RetryAfter }
    $fakeResponse = [PSCustomObject]@{ StatusCode = $StatusCode; Headers = $fakeHeaders }
    $exception = New-Object System.Exception("HTTP $StatusCode (fake)")
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
        throw (New-BRAVOFake429Exception -RetryAfter $script:BRAVOFakeWebRequestRetryAfter -StatusCode $script:BRAVOFakeWebRequestStatusCode)
    }
    return [PSCustomObject]@{ StatusCode = 200; Content = '' }
}
function Start-Sleep {
    param([long]$Milliseconds = 0, [long]$Seconds = 0)
    $script:BRAVOFakeSleepTotalMs += $Milliseconds + ($Seconds * 1000)
}
'@
$webhookModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText ($webhookStubText + "`n" + $compatibilityScriptText) `
    -FunctionNames @('New-BRAVOFake429Exception', 'Invoke-WebRequest', 'Start-Sleep', 'Enable-BRAVOTls12', 'Send-BRAVOWebhookNotification')

function Invoke-BRAVOWebhook429Scenario {
    # -StatusCode: HTTP-статус, яким фейковий Invoke-WebRequest падає перші
    # -FailCount викликів (за замовчуванням 429; T031 — також 5xx/4xx).
    param(
        [int]$FailCount,
        [string]$RetryAfter,
        [int]$StatusCode = 429
    )
    return & $webhookModule {
        param($FailCount, $RetryAfter, $StatusCode)
        Set-StrictMode -Version Latest
        $script:BRAVOFakeWebRequestCallCount = 0
        $script:BRAVOFakeWebRequest429Count = $FailCount
        $script:BRAVOFakeWebRequestRetryAfter = $RetryAfter
        $script:BRAVOFakeWebRequestStatusCode = $StatusCode
        $script:BRAVOFakeSleepTotalMs = [long]0
        $threw = $false
        $errorMessage = $null
        try {
            Send-BRAVOWebhookNotification -Provider "discord" -WebhookUrl "https://discord.example.invalid/webhook" -Message "test"
        } catch {
            $threw = $true
            $errorMessage = $_.Exception.Message
        }
        [PSCustomObject]@{
            Threw = $threw
            ErrorMessage = $errorMessage
            CallCount = $script:BRAVOFakeWebRequestCallCount
            SleepTotalMs = $script:BRAVOFakeSleepTotalMs
        }
    } $FailCount $RetryAfter $StatusCode
}

# --- 429 один раз, потім успіх -> рівно 2 спроби, БЕЗ помилки.
$webhookRetrySuccess = Invoke-BRAVOWebhook429Scenario -FailCount 1 -RetryAfter '0'
Test-BRAVOCondition `
    -Condition (-not $webhookRetrySuccess.Threw -and $webhookRetrySuccess.CallCount -eq 2) `
    -Name "Notifications/Discord429RetryThenSuccess" `
    -Failure "429 з Retry-After на першій спробі має призвести до рівно 2 викликів Invoke-WebRequest без помилки; отримано Threw=$($webhookRetrySuccess.Threw) '$($webhookRetrySuccess.ErrorMessage)', CallCount=$($webhookRetrySuccess.CallCount)"

# --- 429 постійно -> обмежена невдача (макс. 4 спроби, без нескінченного
# retry), помилка прокидається виклику і ЯВНО називає rate limit та
# кількість спроб (діагностика для оператора, а не генерична помилка).
$webhookRetryExhaustedResult = Invoke-BRAVOWebhook429Scenario -FailCount 99 -RetryAfter '0'
Test-BRAVOCondition `
    -Condition ($webhookRetryExhaustedResult.Threw -and $webhookRetryExhaustedResult.CallCount -eq 4) `
    -Name "Notifications/Discord429RetryBoundedNoInfiniteLoop" `
    -Failure "постійний 429 має призвести до РІВНО 4 спроб сумарно (без нескінченного retry) і помилка має прокидатись виклику; отримано Threw=$($webhookRetryExhaustedResult.Threw), CallCount=$($webhookRetryExhaustedResult.CallCount)"
Test-BRAVOCondition `
    -Condition ($webhookRetryExhaustedResult.ErrorMessage -match '429' -and $webhookRetryExhaustedResult.ErrorMessage -match '4\s*спроб') `
    -Name "Notifications/Discord429ExhaustionErrorNamesRateLimitAndAttempts" `
    -Failure "помилка після вичерпання ретраїв має містити '429' і кількість спроб; отримано: '$($webhookRetryExhaustedResult.ErrorMessage)'"

# --- Великий серверний Retry-After (Cloudflare-фронт Discord повертає і
# 1800с) має обмежуватись капом 30с: сумарний сон = 30.25с, а не 30 хвилин
# синхронного сну під час зупинених служб BRAVO. Кап заодно виключає
# OverflowException у [int]-конвертації мілісекунд.
$webhookLargeRetryAfter = Invoke-BRAVOWebhook429Scenario -FailCount 1 -RetryAfter '1800'
Test-BRAVOCondition `
    -Condition (-not $webhookLargeRetryAfter.Threw -and $webhookLargeRetryAfter.SleepTotalMs -eq 30250) `
    -Name "Notifications/DiscordLargeRetryAfterCappedAt30s" `
    -Failure "Retry-After=1800 має капатись до 30с (сон 30250мс з буфером 0.25с); отримано Threw=$($webhookLargeRetryAfter.Threw), SleepTotalMs=$($webhookLargeRetryAfter.SleepTotalMs)"

# --- Дробовий Retry-After "1.5" парситься через InvariantCulture (крапка
# як десятковий роздільник) незалежно від локалі хоста: сон 1.75с, а не
# фолбек 1с+0.25 через невдалий culture-залежний парсинг.
$webhookFractionalRetryAfter = Invoke-BRAVOWebhook429Scenario -FailCount 1 -RetryAfter '1.5'
Test-BRAVOCondition `
    -Condition (-not $webhookFractionalRetryAfter.Threw -and $webhookFractionalRetryAfter.SleepTotalMs -eq 1750) `
    -Name "Notifications/DiscordFractionalRetryAfterInvariantCulture" `
    -Failure "Retry-After='1.5' має давати сон 1750мс (InvariantCulture-парсинг), а не фолбек 1250мс; отримано SleepTotalMs=$($webhookFractionalRetryAfter.SleepTotalMs)"
Test-BRAVOCondition `
    -Condition $compatibilityScriptText.Contains('[Globalization.CultureInfo]::InvariantCulture') `
    -Name "Notifications/DiscordRetryAfterParseUsesInvariantCulture" `
    -Failure "парсинг Retry-After має використовувати InvariantCulture-перевантаження TryParse (culture-залежне на uk-UA не парсить '1.5')"
} catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'MaintenanceRepair/Maintenance.CompareFileSizesMixedMissingSegmentAndMd' } }
if (Enter-BRAVOSelfTestSection -Name 'MaintenanceRepair/Notifications' -DependsOn 'MaintenanceRepair/Maintenance.CompareFileSizesMixedMissingSegmentAndMd') { try {

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

# ============================================================
# T031: transient HTTP 5xx (500/502/503/504) ретраїться за тією самою
# обмеженою політикою, що й 429 (макс. 4 спроби, фолбек 1с/2с/4с,
# Retry-After з капом 30с для 503). 501/505 і 4xx (крім 429) — НЕ
# transient: прокидаються одразу, 1 спроба, без сну. Мережа і сон
# фейкові (stub Invoke-WebRequest/Start-Sleep вище) — детерміновано.
# ============================================================
$webhookSuccessFirstTry = Invoke-BRAVOWebhook429Scenario -FailCount 0 -RetryAfter ''
Test-BRAVOCondition `
    -Condition (-not $webhookSuccessFirstTry.Threw -and $webhookSuccessFirstTry.CallCount -eq 1 -and $webhookSuccessFirstTry.SleepTotalMs -eq 0) `
    -Name "Notifications/WebhookSuccessFirstTryNoRetry" `
    -Failure "успіх з першої спроби має давати рівно 1 виклик без сну; отримано Threw=$($webhookSuccessFirstTry.Threw) '$($webhookSuccessFirstTry.ErrorMessage)', CallCount=$($webhookSuccessFirstTry.CallCount), SleepTotalMs=$($webhookSuccessFirstTry.SleepTotalMs)"

foreach ($transientStatusCode in @(500, 502, 503, 504)) {
    $webhookTransientRecovered = Invoke-BRAVOWebhook429Scenario -FailCount 1 -RetryAfter '' -StatusCode $transientStatusCode
    Test-BRAVOCondition `
        -Condition (-not $webhookTransientRecovered.Threw -and $webhookTransientRecovered.CallCount -eq 2 -and $webhookTransientRecovered.SleepTotalMs -eq 1250) `
        -Name "Notifications/Webhook$($transientStatusCode)RetryThenSuccess" `
        -Failure "HTTP $transientStatusCode на першій спробі має ретраїтись (2 виклики, фолбек-сон 1250мс) і завершитись успіхом; отримано Threw=$($webhookTransientRecovered.Threw) '$($webhookTransientRecovered.ErrorMessage)', CallCount=$($webhookTransientRecovered.CallCount), SleepTotalMs=$($webhookTransientRecovered.SleepTotalMs)"

    $webhookTransientExhausted = Invoke-BRAVOWebhook429Scenario -FailCount 99 -RetryAfter '' -StatusCode $transientStatusCode
    Test-BRAVOCondition `
        -Condition ($webhookTransientExhausted.Threw -and $webhookTransientExhausted.CallCount -eq 4 -and
            $webhookTransientExhausted.SleepTotalMs -eq 7750 -and
            $webhookTransientExhausted.ErrorMessage -match "HTTP $transientStatusCode" -and
            $webhookTransientExhausted.ErrorMessage -match '4\s*спроб') `
        -Name "Notifications/Webhook$($transientStatusCode)RetryBoundedAndNamesStatus" `
        -Failure "постійний HTTP $transientStatusCode має дати РІВНО 4 спроби (сон 1.25+2.25+4.25=7750мс) і помилку зі статусом та кількістю спроб; отримано Threw=$($webhookTransientExhausted.Threw), CallCount=$($webhookTransientExhausted.CallCount), SleepTotalMs=$($webhookTransientExhausted.SleepTotalMs), '$($webhookTransientExhausted.ErrorMessage)'"
}

# --- Retry-After на 503 враховується (1.5с -> сон 1750мс), на 500 —
# ігнорується на користь фолбеку 1с (сон 1250мс): заголовок визначений
# лише для 429/503.
$webhook503RetryAfter = Invoke-BRAVOWebhook429Scenario -FailCount 1 -RetryAfter '1.5' -StatusCode 503
Test-BRAVOCondition `
    -Condition (-not $webhook503RetryAfter.Threw -and $webhook503RetryAfter.SleepTotalMs -eq 1750) `
    -Name "Notifications/Webhook503HonoursRetryAfter" `
    -Failure "503 з Retry-After='1.5' має давати сон 1750мс; отримано Threw=$($webhook503RetryAfter.Threw), SleepTotalMs=$($webhook503RetryAfter.SleepTotalMs)"
$webhook503LargeRetryAfter = Invoke-BRAVOWebhook429Scenario -FailCount 1 -RetryAfter '1800' -StatusCode 503
Test-BRAVOCondition `
    -Condition (-not $webhook503LargeRetryAfter.Threw -and $webhook503LargeRetryAfter.SleepTotalMs -eq 30250) `
    -Name "Notifications/Webhook503RetryAfterCappedAt30s" `
    -Failure "503 з Retry-After=1800 має капатись до 30с (сон 30250мс); отримано SleepTotalMs=$($webhook503LargeRetryAfter.SleepTotalMs)"
$webhook500RetryAfter = Invoke-BRAVOWebhook429Scenario -FailCount 1 -RetryAfter '1.5' -StatusCode 500
Test-BRAVOCondition `
    -Condition (-not $webhook500RetryAfter.Threw -and $webhook500RetryAfter.SleepTotalMs -eq 1250) `
    -Name "Notifications/Webhook500UsesBackoffNotRetryAfter" `
    -Failure "500 має використовувати фолбек 1с (сон 1250мс), а не Retry-After; отримано SleepTotalMs=$($webhook500RetryAfter.SleepTotalMs)"

foreach ($nonTransientStatusCode in @(400, 404, 501, 505)) {
    $webhookNonTransient = Invoke-BRAVOWebhook429Scenario -FailCount 99 -RetryAfter '0' -StatusCode $nonTransientStatusCode
    Test-BRAVOCondition `
        -Condition ($webhookNonTransient.Threw -and $webhookNonTransient.CallCount -eq 1 -and $webhookNonTransient.SleepTotalMs -eq 0) `
        -Name "Notifications/Webhook$($nonTransientStatusCode)NotRetried" `
        -Failure "HTTP $nonTransientStatusCode не є transient і має прокидатись одразу (1 виклик, без сну); отримано Threw=$($webhookNonTransient.Threw), CallCount=$($webhookNonTransient.CallCount), SleepTotalMs=$($webhookNonTransient.SleepTotalMs)"
}

# ============================================================
# Регресія порядку виконання (P0, знайдено /code-review коміту 5803859):
# Get-BRAVOEmptyLogDateDirectories/Remove-BRAVOEmptyLogDateDirectories
# МУСЯТЬ бути фізично визначені у файлі РАНІШЕ за топ-рівневий виклик
# Invoke-BRAVOLegacySweep (який їх опосередковано викликає). Це
# .ps1-скрипт, а не модуль із попереднім парсингом усіх function-
# тверджень — виконується строго послідовно; виклик функції, чиє
# `function`-твердження ще фізично нижче за файлом, кидає
# CommandNotFoundException у проді щоразу, коли $BravoMaintenanceEnabled.
# New-BRAVOSelfTestRuntimeModule НЕ ловить цей клас дефекту: він
# екстрагує потрібні функції по AST за іменами й dot-sources їх у
# ПОРЯДКУ СПИСКУ -FunctionNames (довільному, не фізичному) — саме тому
# нижче перевіряється РЕАЛЬНИЙ AST усього файлу через Extent.StartOffset,
# а не поведінка ізольованого рантайм-модуля.
# ============================================================
$orderingAst = [System.Management.Automation.Language.Parser]::ParseInput($maintenanceRepairScriptText, [ref]$null, [ref]$null)
$orderingGetFn = @($orderingAst.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-BRAVOEmptyLogDateDirectories' },
    $true
)) | Select-Object -First 1
$orderingRemoveFn = @($orderingAst.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-BRAVOEmptyLogDateDirectories' },
    $true
)) | Select-Object -First 1
# Топ-рівневі виклики Invoke-BRAVOLegacySweep — CommandAst-и з цим
# іменем команди, які НЕ вкладені у жоден FunctionDefinitionAst (тобто
# виконуються одразу під час запуску скрипта, а не всередині означення
# іншої функції). Виняток — Invoke-BRAVOMaintenance: це обгортка всього
# тіла runtime (T010), її оператори виконуються так само послідовно, як
# раніше оператори рівня скрипта, тож вона — "верхній рівень" тіла, а не
# "інша функція".
$orderingTopLevelInvokeCalls = New-Object System.Collections.Generic.List[object]
foreach ($orderingCandidate in @($orderingAst.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-BRAVOLegacySweep' },
    $true
))) {
    $orderingInsideFunctionDef = $false
    $orderingAncestor = $orderingCandidate.Parent
    while ($null -ne $orderingAncestor) {
        if ($orderingAncestor -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $orderingAncestor.Name -ne 'Invoke-BRAVOMaintenance') {
            $orderingInsideFunctionDef = $true
            break
        }
        $orderingAncestor = $orderingAncestor.Parent
    }
    if (-not $orderingInsideFunctionDef) {
        [void]$orderingTopLevelInvokeCalls.Add($orderingCandidate)
    }
}
$orderingMisorderedCalls = @($orderingTopLevelInvokeCalls | Where-Object {
    $_.Extent.StartOffset -lt $orderingGetFn.Extent.StartOffset -or
    $_.Extent.StartOffset -lt $orderingRemoveFn.Extent.StartOffset
})
Test-BRAVOCondition `
    -Condition (
        $null -ne $orderingGetFn -and $null -ne $orderingRemoveFn -and
        $orderingTopLevelInvokeCalls.Count -ge 1 -and
        $orderingMisorderedCalls.Count -eq 0
    ) `
    -Name 'Maintenance/LegacySweepDependencyFunctionsDefinedBeforeTopLevelInvocation' `
    -Failure "Get-BRAVOEmptyLogDateDirectories/Remove-BRAVOEmptyLogDateDirectories мають бути фізично визначені ДО топ-рівневого виклику Invoke-BRAVOLegacySweep; факт: GetFnFound=$($null -ne $orderingGetFn) RemoveFnFound=$($null -ne $orderingRemoveFn) topLevelCalls=$($orderingTopLevelInvokeCalls.Count) misordered=$($orderingMisorderedCalls.Count)"

# ============================================================
# Invoke-BRAVOLegacySweep: одноразове маркер-гейтоване очищення
# legacy-артефактів ери ARCHIV_LIMS-предка (регресія 2026-09, сервер парку).
# ============================================================
# Get-BRAVODirectories з опційним test-only гаком
# $script:legacySweepVanishAfterDiscoveryPath (R4-2, PR #136 review, 4-е
# коло) — той самий прийом, що $script:taP2VanishAfterDiscoveryPath у
# BRAVO_SELF_TEST.TraceArchive.ps1: синхронно й детерміновано видаляє
# вказаний candidate ПІСЛЯ реального сканування каталогу, але ДО
# per-candidate EnumerateFileSystemInfos() — відтворює РЕАЛЬНИЙ
# DirectoryNotFoundException для ОДНОГО candidate без потоків/сну.
$legacySweepStubText = @'
function Write-Log { param($Message, [string]$Level = 'INFO') }
function Get-BRAVOFiles { BRAVO.Compatibility\Get-BRAVOFiles @args }
function Get-BRAVODirectories {
    param([string]$Path, [string]$Filter = "*", [switch]$Recurse)
    $realResult = @(BRAVO.Compatibility\Get-BRAVODirectories -Path $Path -Filter $Filter -Recurse:$Recurse)
    if ($script:legacySweepVanishAfterDiscoveryPath -and (Test-Path -LiteralPath $script:legacySweepVanishAfterDiscoveryPath)) {
        Remove-Item -LiteralPath $script:legacySweepVanishAfterDiscoveryPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $realResult
}
'@
$legacySweepModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText ($legacySweepStubText + "`n" + $maintenanceRepairScriptText) `
    -FunctionNames @(
        'Write-Log',
        'Get-BRAVOFiles',
        'Get-BRAVODirectories',
        'Get-BRAVOCanonicalBackupRootIdentity',
        'Get-BRAVOEmptyLogDateDirectories',
        'Remove-BRAVOEmptyLogDateDirectories',
        'Get-BRAVOLegacySweepStatePath',
        'Write-BRAVOLegacySweepState',
        'Read-BRAVOLegacySweepState',
        'Invoke-BRAVOLegacySweep'
    )

$legacySweepRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_LEGACY_SWEEP_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    $legacySweepLogDir = Join-Path $legacySweepRoot 'LOGS'
    $legacySweepTraceDir = Join-Path $legacySweepRoot 'LOGS\Trace'
    [void](New-Item -ItemType Directory -Path $legacySweepLogDir -Force)
    [void](New-Item -ItemType Directory -Path $legacySweepTraceDir -Force)
    $legacySweepStatePath = Join-Path $legacySweepRoot 'State\BRAVO_LEGACY_SWEEP_STATE.json'
    $legacySweepBackupRootA = Join-Path $legacySweepRoot 'BackupRootA'

    # --- (a) Немає стану + legacy-артефакти присутні -> виметено, маркер записано.
    [IO.File]::WriteAllText((Join-Path $legacySweepLogDir 'script_log_20260830_2355.txt'), 'legacy', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $legacySweepLogDir 'ARCHIV_LIMS_20260902_1510.log'), 'legacy', (New-Object Text.UTF8Encoding($false)))
    $legacySweepEmptyDir = Join-Path $legacySweepTraceDir '2026-08-23'
    [void](New-Item -ItemType Directory -Path $legacySweepEmptyDir -Force)
    $legacySweepNonEmptyDir = Join-Path $legacySweepTraceDir '2026-08-19'
    [void](New-Item -ItemType Directory -Path $legacySweepNonEmptyDir -Force)
    [IO.File]::WriteAllText((Join-Path $legacySweepNonEmptyDir 'traceBIS_000001.out'), 'stray', (New-Object Text.UTF8Encoding($false)))

    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $legacySweepLogDir $legacySweepTraceDir $legacySweepStatePath $legacySweepBackupRootA

    Test-BRAVOCondition -Condition (
        -not (Test-Path -LiteralPath (Join-Path $legacySweepLogDir 'script_log_20260830_2355.txt')) -and
        -not (Test-Path -LiteralPath (Join-Path $legacySweepLogDir 'ARCHIV_LIMS_20260902_1510.log')) -and
        -not (Test-Path -LiteralPath $legacySweepEmptyDir) -and
        (Test-Path -LiteralPath $legacySweepNonEmptyDir) -and
        (Test-Path -LiteralPath (Join-Path $legacySweepNonEmptyDir 'traceBIS_000001.out')) -and
        (Test-Path -LiteralPath $legacySweepStatePath)
    ) -Name 'Maintenance/LegacySweepFirstRunSweepsKnownArtifactsOnly' `
        -Failure "перший прогін має видалити script_log_*.txt/ARCHIV_LIMS_*.log і ПОРОЖНІЙ каталог-дату, залишити НЕПОРОЖНІЙ каталог-дату і записати маркер стану"

    # --- (b) Маркер присутній -> sweep пропущено, навіть якщо legacy-артефакти знову з'явились.
    [IO.File]::WriteAllText((Join-Path $legacySweepLogDir 'script_log_20260901_0000.txt'), 'reappeared', (New-Object Text.UTF8Encoding($false)))
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $legacySweepLogDir $legacySweepTraceDir $legacySweepStatePath $legacySweepBackupRootA
    Test-BRAVOCondition -Condition (
        Test-Path -LiteralPath (Join-Path $legacySweepLogDir 'script_log_20260901_0000.txt')
    ) -Name 'Maintenance/LegacySweepSkippedWhenMarkerPresent' `
        -Failure "з наявним маркером sweep має бути пропущений навіть якщо legacy-артефакт знову з'явився"

    # --- (c) Пошкоджений/нечитабельний стан -> трактується як "вже виметено" (пропуск), без деструкції.
    [IO.File]::WriteAllText($legacySweepStatePath, 'not-valid-json{{{', (New-Object Text.UTF8Encoding($false)))
    $legacySweepCorruptRead = & $legacySweepModule { param($p) Read-BRAVOLegacySweepState -Path $p } $legacySweepStatePath
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $legacySweepLogDir $legacySweepTraceDir $legacySweepStatePath $legacySweepBackupRootA
    Test-BRAVOCondition -Condition (
        $null -eq $legacySweepCorruptRead -and
        (Test-Path -LiteralPath (Join-Path $legacySweepLogDir 'script_log_20260901_0000.txt'))
    ) -Name 'Maintenance/LegacySweepCorruptStateTreatedAsAlreadySwept' `
        -Failure "пошкоджений стан-файл має трактуватись як 'вже виметено' (fail-closed skip), Read має повернути `$null, жодної деструктивної дії"

    # --- (d) Валідний JSON, але нечислова schemaVersion — регресія
    # code-review 5c14a70: [int]-каст поза try кидав помилковий record і
    # повертав зіпсований стан як валідний. Має бути $null (пошкоджений),
    # тихо, без error-record.
    [IO.File]::WriteAllText($legacySweepStatePath, '{"schemaVersion": "abc", "sweptAt": "2026-09-04T00:00:00Z"}', (New-Object Text.UTF8Encoding($false)))
    $legacySweepBadSchemaOutput = @(
        & $legacySweepModule { param($p) Read-BRAVOLegacySweepState -Path $p } $legacySweepStatePath 2>&1
    )
    $legacySweepBadSchemaErrors = @(
        $legacySweepBadSchemaOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
    )
    $legacySweepBadSchemaValues = @(
        $legacySweepBadSchemaOutput | Where-Object {
            $_ -isnot [System.Management.Automation.ErrorRecord] -and $null -ne $_
        }
    )
    Test-BRAVOCondition -Condition (
        $legacySweepBadSchemaValues.Count -eq 0 -and
        $legacySweepBadSchemaErrors.Count -eq 0
    ) -Name 'Maintenance/LegacySweepNonNumericSchemaVersionIsCorruptState' `
        -Failure "валідний JSON із нечисловою schemaVersion має трактуватись як пошкоджений стан (`$null) без error-record; факт: values=$($legacySweepBadSchemaValues.Count), errors=$($legacySweepBadSchemaErrors.Count)"
} finally {
    if (Test-Path -LiteralPath $legacySweepRoot) {
        Remove-Item -LiteralPath $legacySweepRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ===== R4-2 (PR #136 review, 4-е коло): провал enumeration для ОДНОГО
# candidate не зупиняє обробку інших і не веде до видалення
# непідтвердженого каталогу; структурований результат розрізняє
# DiscoveredCandidates/ConfirmedEmpty/Deleted/EnumerationWarnings/
# DeletionWarnings. Invoke-BRAVOLegacySweep тепер повертає результат
# КАНОНІЧНОЇ Remove-BRAVOEmptyLogDateDirectories замість власного
# паралельного enumeration-циклу. =====
$legacySweepP2Root = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_LEGACY_SWEEP_P2_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    $p2LogDir = Join-Path $legacySweepP2Root 'LOGS'
    $p2TraceDir = Join-Path $legacySweepP2Root 'LOGS\Trace'
    [void](New-Item -ItemType Directory -Path $p2LogDir -Force)
    [void](New-Item -ItemType Directory -Path $p2TraceDir -Force)
    $p2StatePath = Join-Path $legacySweepP2Root 'State\BRAVO_LEGACY_SWEEP_STATE.json'
    $p2BackupRoot = Join-Path $legacySweepP2Root 'BackupRoot'
    $p2VanishingDir = Join-Path $p2TraceDir '2026-09-01'
    $p2ValidEmptyDir = Join-Path $p2TraceDir '2026-09-02'
    [void](New-Item -ItemType Directory -Path $p2VanishingDir -Force)
    [void](New-Item -ItemType Directory -Path $p2ValidEmptyDir -Force)

    $p2Result = & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root, $VanishPath)
        $script:legacySweepVanishAfterDiscoveryPath = $VanishPath
        try { Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' }
        finally { $script:legacySweepVanishAfterDiscoveryPath = $null }
    } $p2LogDir $p2TraceDir $p2StatePath $p2BackupRoot $p2VanishingDir

    Test-BRAVOCondition -Condition (
        $null -ne $p2Result -and
        $p2Result.DiscoveredCandidates -eq 2 -and
        $p2Result.ConfirmedEmpty -eq 1 -and
        $p2Result.Deleted -eq 1 -and
        $p2Result.EnumerationWarnings -eq 1 -and
        $p2Result.DeletionWarnings -eq 0 -and
        (-not (Test-Path -LiteralPath $p2ValidEmptyDir)) -and
        (Test-Path -LiteralPath $p2StatePath)
    ) -Name 'Maintenance/LegacySweepEnumerationFailureIsolatedPerCandidate' `
        -Failure ("провал enumeration для ОДНОГО candidate не повинен зупиняти обробку іншого; факт: " + `
            "discovered=$($p2Result.DiscoveredCandidates), confirmedEmpty=$($p2Result.ConfirmedEmpty), " + `
            "deleted=$($p2Result.Deleted), enumWarn=$($p2Result.EnumerationWarnings), delWarn=$($p2Result.DeletionWarnings)")
} finally {
    if (Test-Path -LiteralPath $legacySweepP2Root) {
        Remove-Item -LiteralPath $legacySweepP2Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ===== R4-4 (PR #136 review, 4-е коло): legacy-sweep маркер прив'язаний
# до BackupRoot — зміна кореня тригерить повторний sweep; той самий
# корінь в іншому лексичному форматі — ні; corrupt/unknown стан і провал
# атомарного запису лишаються fail-safe незалежно від кореня. =====
$legacySweepRootScopeRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_LEGACY_SWEEP_ROOTSCOPE_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    $rsLogDir = Join-Path $legacySweepRootScopeRoot 'LOGS'
    $rsTraceDir = Join-Path $legacySweepRootScopeRoot 'LOGS\Trace'
    [void](New-Item -ItemType Directory -Path $rsLogDir -Force)
    [void](New-Item -ItemType Directory -Path $rsTraceDir -Force)
    $rsStatePath = Join-Path $legacySweepRootScopeRoot 'State\BRAVO_LEGACY_SWEEP_STATE.json'
    $rsBackupRootA = Join-Path $legacySweepRootScopeRoot 'BackupRootA'
    $rsBackupRootB = Join-Path $legacySweepRootScopeRoot 'BackupRootB'

    # --- (i) Перший sweep для root A.
    [IO.File]::WriteAllText((Join-Path $rsLogDir 'script_log_20260901_0100.txt'), 'legacy', (New-Object Text.UTF8Encoding($false)))
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $rsLogDir $rsTraceDir $rsStatePath $rsBackupRootA
    Test-BRAVOCondition -Condition (
        -not (Test-Path -LiteralPath (Join-Path $rsLogDir 'script_log_20260901_0100.txt')) -and
        (Test-Path -LiteralPath $rsStatePath)
    ) -Name 'Maintenance/LegacySweepRootScopeFirstSweepForRootA' `
        -Failure "перший sweep для root A має видалити legacy-артефакт і записати маркер"

    # --- (ii) Повторний прогін для root A -> пропущено.
    [IO.File]::WriteAllText((Join-Path $rsLogDir 'script_log_20260901_0200.txt'), 'reappeared', (New-Object Text.UTF8Encoding($false)))
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $rsLogDir $rsTraceDir $rsStatePath $rsBackupRootA
    Test-BRAVOCondition -Condition (
        Test-Path -LiteralPath (Join-Path $rsLogDir 'script_log_20260901_0200.txt')
    ) -Name 'Maintenance/LegacySweepRootScopeRepeatForSameRootSkipped' `
        -Failure "повторний прогін для того самого root A має бути пропущений"

    # --- (iii) Той самий root A, лише в іншому лексичному форматі
    # (інший регістр + кінцевий '\') -> НЕ тригерить повторний sweep.
    $rsBackupRootAAltFormat = $rsBackupRootA.ToUpperInvariant() + '\'
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $rsLogDir $rsTraceDir $rsStatePath $rsBackupRootAAltFormat
    Test-BRAVOCondition -Condition (
        Test-Path -LiteralPath (Join-Path $rsLogDir 'script_log_20260901_0200.txt')
    ) -Name 'Maintenance/LegacySweepRootScopePathFormatChangeWithoutCanonicalChangeNotResweep' `
        -Failure "зміна лексичного формату (регістр/кінцевий '\') того самого root A не повинна тригерити повторний sweep"

    # --- (iv) Зміна на root B -> повторний sweep для нового кореня.
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $rsLogDir $rsTraceDir $rsStatePath $rsBackupRootB
    Test-BRAVOCondition -Condition (
        -not (Test-Path -LiteralPath (Join-Path $rsLogDir 'script_log_20260901_0200.txt'))
    ) -Name 'Maintenance/LegacySweepRootScopeChangeToRootBTriggersResweep' `
        -Failure "зміна BackupRoot на root B має тригерити повторний sweep для нового кореня"

    # --- (v) corrupt/unknown стан fail-safe пропускає sweep незалежно
    # від переданого BackupRoot (той самий принцип, що (c)/(d) вище).
    [IO.File]::WriteAllText($rsStatePath, 'not-valid-json{{{', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $rsLogDir 'script_log_20260901_0300.txt'), 'reappeared-corrupt', (New-Object Text.UTF8Encoding($false)))
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $rsLogDir $rsTraceDir $rsStatePath $rsBackupRootB
    Test-BRAVOCondition -Condition (
        Test-Path -LiteralPath (Join-Path $rsLogDir 'script_log_20260901_0300.txt')
    ) -Name 'Maintenance/LegacySweepRootScopeCorruptStateFailsSafeRegardlessOfRoot' `
        -Failure "пошкоджений стан-файл має fail-closed пропустити sweep незалежно від переданого BackupRoot"

    # --- (vi) Провал атомарного запису НЕ знищує попередній валідний
    # маркер. Спершу відновлюємо валідний маркер для root B, тоді
    # блокуємо ЦІЛЬОВИЙ файл маркера (відкритий FileStream без
    # FileShare.Write/Delete) так, щоб [IO.File]::Replace у
    # Write-BRAVOLegacySweepState кинув виняток під час спроби sweep для
    # НОВОГО root C — попередній валідний маркер (для root B) має
    # лишитись читабельним і байт-у-байт незмінним.
    Remove-Item -LiteralPath $rsStatePath -Force -ErrorAction SilentlyContinue
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $rsLogDir $rsTraceDir $rsStatePath $rsBackupRootB
    $rsPriorValidStateBytes = [IO.File]::ReadAllBytes($rsStatePath)

    [IO.File]::WriteAllText((Join-Path $rsLogDir 'script_log_20260901_0400.txt'), 'triggers-resweep-for-root-c', (New-Object Text.UTF8Encoding($false)))
    $rsBackupRootC = Join-Path $legacySweepRootScopeRoot 'BackupRootC'
    $rsLockStream = New-Object IO.FileStream($rsStatePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        & $legacySweepModule {
            param($LogDir, $TraceDir, $StatePath, $Root)
            Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
        } $rsLogDir $rsTraceDir $rsStatePath $rsBackupRootC
    } finally {
        $rsLockStream.Close()
    }
    $rsPostFailureStateBytes = [IO.File]::ReadAllBytes($rsStatePath)
    # Примітка: сам legacy-файл-тригер ОЧІКУВАНО видаляється до спроби
    # запису маркера (та сама поведінка, що й наявний P2 partial-failure
    # шлях: успішно видалені об'єкти при повторному прогоні просто не
    # будуть знайдені знову) — атомарність тут гарантується ЛИШЕ для
    # самого стан-файлу маркера, не для вже виконаної sweep-роботи.
    Test-BRAVOCondition -Condition (
        (Test-Path -LiteralPath $rsStatePath) -and
        ([System.Convert]::ToBase64String($rsPriorValidStateBytes) -eq [System.Convert]::ToBase64String($rsPostFailureStateBytes))
    ) -Name 'Maintenance/LegacySweepRootScopeAtomicWriteFailurePreservesPriorValidState' `
        -Failure "провал атомарного запису маркера (заблокований цільовий файл) не повинен знищувати/змінювати попередній валідний стан-файл"
} finally {
    if (Test-Path -LiteralPath $legacySweepRootScopeRoot) {
        Remove-Item -LiteralPath $legacySweepRootScopeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
    # B7 / F6 + F8 (security review): статичні (AST) перевірки. Поведінка DACL
    # перевіряється ізольованою probe на scratch-каталозі (не тут: SetOwner
    # вимагає elevated-токена, який self-test не гарантований мати).
    $b7ParseFunction = {
        param([string]$Text, [string]$Name)
        $b7Ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        return $b7Ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true)
    }
    $b7InstallText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_TASKS_INSTALL.ps1'), [Text.Encoding]::UTF8)
    $b7DiagnoseText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_TASKS_DIAGNOSE.ps1'), [Text.Encoding]::UTF8)
    $b7DataAcl = & $b7ParseFunction $b7InstallText 'Set-BRAVOProtectedDataDirectoryAcl'
    $b7RuntimeAcl = & $b7ParseFunction $b7InstallText 'Set-BRAVOProtectedRuntimeAcl'
    $b7DataAclText = if ($null -ne $b7DataAcl) { $b7DataAcl.Extent.Text } else { '' }
    $b7RuntimeAclText = if ($null -ne $b7RuntimeAcl) { $b7RuntimeAcl.Extent.Text } else { '' }
    # Статична перевірка лишається лише як доповнення до поведінкових нижче:
    # функція існує, не користується Get-Acl і не видає ReadAndExecute.
    # (B7: текст CreateDirectory($Path) змінено на $fullPath — пін оновлено.)
    Test-BRAVOCondition -Condition (
        $null -ne $b7DataAcl -and
        $b7DataAclText.Contains('SetAccessRuleProtection($true, $false)') -and
        $b7DataAclText.Contains('[System.IO.Directory]::CreateDirectory($fullPath)') -and
        -not $b7DataAclText.Contains('Get-Acl')
    ) -Name 'Scheduler/DataDirectoryAclIsProtectedWithoutUsersAce' `
        -Failure 'Set-BRAVOProtectedDataDirectoryAcl має створювати каталог, вимикати успадкування й не містити Get-Acl (поведінку див. DataDirectoryAclExactSidSetBehavioural)'
    & {
        # B7 / P1+P2 (повторний security-review): поведінкові перевірки замість
        # текстових. Функції витягуються через AST у ЧИСТИЙ scope, Set-Acl
        # підміняється записувачем (SetOwner/реальний Set-Acl вимагають
        # elevated-токена, self-test його не гарантує), а Test-BRAVOPathIsReparsePoint
        # і Get-BRAVOPathOwnerSid — реальні (junction створюється через mklink /J).
        $b7InstallFunctionText = (@(
                'Test-BRAVOPathIsReparsePoint', 'Get-BRAVOPathOwnerSid', 'Set-BRAVOProtectedDataDirectoryAcl'
            ) | ForEach-Object {
                $b7FunctionAst = & $b7ParseFunction $b7InstallText $_
                if ($null -ne $b7FunctionAst) { $b7FunctionAst.Extent.Text } else { '' }
            }) -join "`n`n"
        $b7Probe = {
            param(
                [string]$FunctionText, [string]$Path, [string[]]$ModifySid, [string]$Boundary,
                [string]$OwnerSid, [string[]]$StubReparsePaths
            )
            $recordedCalls = New-Object System.Collections.ArrayList
            $recordedWarnings = New-Object System.Collections.ArrayList
            . ([scriptblock]::Create($FunctionText))
            function Set-Acl {
                param($LiteralPath, $AclObject, $ErrorAction)
                [void]$recordedCalls.Add([pscustomobject]@{ Path = [string]$LiteralPath; Acl = $AclObject })
            }
            function Write-Warning { param($Message) [void]$recordedWarnings.Add([string]$Message) }
            function Write-Host { param($Object, $ForegroundColor) }
            if (-not [string]::IsNullOrWhiteSpace($OwnerSid)) {
                function Get-BRAVOPathOwnerSid { param([string]$Path) return $OwnerSid }
            }
            if (@($StubReparsePaths | Where-Object { $_ }).Count -gt 0) {
                function Test-BRAVOPathIsReparsePoint {
                    param([string]$Path)
                    return (@($StubReparsePaths) -contains $Path.TrimEnd('\'))
                }
            }
            $errorMessage = $null
            try {
                $null = Set-BRAVOProtectedDataDirectoryAcl -Path $Path -ModifySid $ModifySid -BoundaryRoot $Boundary
            } catch {
                $errorMessage = $_.Exception.Message
            }
            return [pscustomobject]@{
                Calls = @($recordedCalls)
                Warnings = @($recordedWarnings)
                Error = $errorMessage
            }
        }
        $b7Scratch = Join-Path ([IO.Path]::GetTempPath()) ('bravo-b7-' + [guid]::NewGuid().ToString('N'))
        $b7ScratchJunctions = New-Object System.Collections.ArrayList
        try {
            [void][IO.Directory]::CreateDirectory($b7Scratch)
            $b7ModifySid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
            $b7NewJunction = {
                param([string]$LinkPath, [string]$TargetPath)
                & cmd.exe /c mklink /J "$LinkPath" "$TargetPath" 2>&1 | Out-Null
                $created = [IO.Directory]::Exists($LinkPath) -and
                    (([int][IO.File]::GetAttributes($LinkPath) -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)
                if ($created) { [void]$b7ScratchJunctions.Add($LinkPath) }
                return $created
            }

            # 1) Точний набір SID/прав/успадкування для кореня, файлу й підкаталогу.
            $b7Data = Join-Path $b7Scratch 'data'
            [void][IO.Directory]::CreateDirectory((Join-Path $b7Data 'sub'))
            [IO.File]::WriteAllText((Join-Path $b7Data 'f.txt'), 'x')
            [IO.File]::WriteAllText((Join-Path $b7Data 'sub\g.txt'), 'x')
            $b7Result = & $b7Probe $b7InstallFunctionText $b7Data @($b7ModifySid) $b7Scratch 'S-1-5-32-544' @()
            $b7ExpectedPaths = @($b7Data, (Join-Path $b7Data 'f.txt'), (Join-Path $b7Data 'sub'), (Join-Path $b7Data 'sub\g.txt'))
            $b7Problems = New-Object System.Collections.ArrayList
            if ($null -ne $b7Result.Error) { [void]$b7Problems.Add("помилка: $($b7Result.Error)") }
            $b7RecordedPaths = @($b7Result.Calls | ForEach-Object { $_.Path })
            if ((@($b7RecordedPaths | Sort-Object) -join '|') -ne (@($b7ExpectedPaths | Sort-Object) -join '|')) {
                [void]$b7Problems.Add("набір шляхів Set-Acl: $($b7RecordedPaths -join ', ')")
            }
            $b7Sid = [Security.Principal.SecurityIdentifier]
            $b7RootOwnAceCount = 0
            $b7RootInheritOnlyCount = 0
            foreach ($b7Call in @($b7Result.Calls)) {
                $b7IsDirectory = [IO.Directory]::Exists($b7Call.Path)
                $b7Acl = $b7Call.Acl
                if (-not $b7Acl.AreAccessRulesProtected) { [void]$b7Problems.Add("$($b7Call.Path): успадкування не вимкнено") }
                if ([string]$b7Acl.GetOwner($b7Sid).Value -ne 'S-1-5-32-544') { [void]$b7Problems.Add("$($b7Call.Path): власник не Administrators") }
                $b7Rules = @($b7Acl.GetAccessRules($true, $false, $b7Sid))
                $b7SidSet = (@($b7Rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique) -join '|')
                $b7ExpectedSidSet = (@('S-1-5-32-544', 'S-1-5-18', $b7ModifySid) | Sort-Object) -join '|'
                if ($b7SidSet -ne $b7ExpectedSidSet) { [void]$b7Problems.Add("$($b7Call.Path): набір SID '$b7SidSet'") }
                $b7ExpectedInheritance = if ($b7IsDirectory) {
                    [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
                } else { [Security.AccessControl.InheritanceFlags]::None }
                $b7IsRoot = ($b7Call.Path -eq $b7Data)
                foreach ($b7Rule in $b7Rules) {
                    $b7RuleSid = $b7Rule.IdentityReference.Value
                    if ($b7IsRoot -and $b7RuleSid -eq $b7ModifySid) {
                        # P2: корінь - ReadAndExecute|Write без DELETE (no inherit) + окремий inherit-only Modify.
                        $b7RootDeleteMask = [int][Security.AccessControl.FileSystemRights]::Delete -bor [int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
                        $b7IsInheritOnly = ($b7Rule.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::InheritOnly)
                        if ($b7IsInheritOnly) {
                            if ($b7Rule.InheritanceFlags -ne $b7ExpectedInheritance -or
                                ([int]$b7Rule.FileSystemRights -band (-bnot [int][Security.AccessControl.FileSystemRights]::Synchronize)) -ne ([int][Security.AccessControl.FileSystemRights]::Modify -band (-bnot [int][Security.AccessControl.FileSystemRights]::Synchronize))) {
                                [void]$b7Problems.Add("корінь: inherit-only ACE для ModifySid має бути Modify з CI|OI: $($b7Rule.FileSystemRights)/$($b7Rule.InheritanceFlags)")
                            }
                            $b7RootInheritOnlyCount++
                        } else {
                            if ($b7Rule.InheritanceFlags -ne [Security.AccessControl.InheritanceFlags]::None -or
                                ([int]$b7Rule.FileSystemRights -band $b7RootDeleteMask) -ne 0 -or
                                ([int]$b7Rule.FileSystemRights -band [int][Security.AccessControl.FileSystemRights]::Write) -ne [int][Security.AccessControl.FileSystemRights]::Write) {
                                [void]$b7Problems.Add("корінь: власний ACE для ModifySid має бути Write без Delete/DeleteSubdirectoriesAndFiles, без успадкування: $($b7Rule.FileSystemRights)/$($b7Rule.InheritanceFlags)")
                            }
                            $b7RootOwnAceCount++
                        }
                        continue
                    }
                    $b7ExpectedRights = if ($b7RuleSid -eq $b7ModifySid) { [Security.AccessControl.FileSystemRights]::Modify } else { [Security.AccessControl.FileSystemRights]::FullControl }
                    if ($b7Rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { [void]$b7Problems.Add("$($b7Call.Path): не Allow для $b7RuleSid") }
                    if (([int]$b7Rule.FileSystemRights -band (-bnot [int][Security.AccessControl.FileSystemRights]::Synchronize)) -ne ([int]$b7ExpectedRights -band (-bnot [int][Security.AccessControl.FileSystemRights]::Synchronize))) { [void]$b7Problems.Add("$($b7Call.Path): права $b7RuleSid = $($b7Rule.FileSystemRights)") }
                    if ($b7Rule.InheritanceFlags -ne $b7ExpectedInheritance) { [void]$b7Problems.Add("$($b7Call.Path): InheritanceFlags $b7RuleSid = $($b7Rule.InheritanceFlags)") }
                    if ($b7Rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) { [void]$b7Problems.Add("$($b7Call.Path): PropagationFlags $b7RuleSid") }
                }
                foreach ($b7BroadSid in @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0', 'S-1-5-4')) {
                    if ($b7SidSet.Contains($b7BroadSid)) { [void]$b7Problems.Add("$($b7Call.Path): широкий принципал $b7BroadSid") }
                }
            }
            if ($b7RootOwnAceCount -ne 1 -or $b7RootInheritOnlyCount -ne 1) {
                [void]$b7Problems.Add("корінь: очікується рівно один власний і один inherit-only ACE для ModifySid ($b7RootOwnAceCount/$b7RootInheritOnlyCount)")
            }
            Test-BRAVOCondition -Condition ($b7Problems.Count -eq 0 -and $b7Result.Calls.Count -eq 4) `
                -Name 'Scheduler/DataDirectoryAclExactSidSetBehavioural' `
                -Failure ("Set-BRAVOProtectedDataDirectoryAcl: DACL має бути protected, SID == {Administrators, SYSTEM, ModifySid} (FullControl/FullControl/Modify), без Users/Authenticated Users/Everyone/INTERACTIVE, правильні прапори успадкування для каталогів і файлів: " + ($b7Problems -join '; '))

            # 2) Власник не SYSTEM/Administrators -> throw до будь-якого Set-Acl.
            $b7OwnerData = Join-Path $b7Scratch 'owner-data'
            $b7OwnerResult = & $b7Probe $b7InstallFunctionText $b7OwnerData @() $b7Scratch 'S-1-5-21-9-9-9-1001' @()
            Test-BRAVOCondition -Condition (
                $b7OwnerResult.Calls.Count -eq 0 -and $null -ne $b7OwnerResult.Error -and
                $b7OwnerResult.Error.Contains('власник') -and $b7OwnerResult.Error.Contains($b7OwnerData)
            ) -Name 'Scheduler/DataDirectoryAclRefusesUntrustedOwner' `
                -Failure 'каталог даних із власником не SYSTEM/Administrators має призвести до throw (з назвою шляху) ДО будь-якого Set-Acl'

            # 2a) P1: власник НЕ підмінений. Каталог створює сама функція (власник =
            # поточна elevated-особа: built-in Administrator RID 500 під власним SID
            # або Administrators у split-token) - має пройти, а ACL мають точний набір SID.
            $b7FreshData = Join-Path $b7Scratch 'fresh-real-owner\data'
            $b7FreshResult = & $b7Probe $b7InstallFunctionText $b7FreshData @($b7ModifySid) (Join-Path $b7Scratch 'fresh-real-owner') '' @()
            $b7FreshProblems = New-Object System.Collections.ArrayList
            if ($null -ne $b7FreshResult.Error) { [void]$b7FreshProblems.Add("помилка: $($b7FreshResult.Error)") }
            if ($b7FreshResult.Calls.Count -ne 1) { [void]$b7FreshProblems.Add("кількість Set-Acl: $($b7FreshResult.Calls.Count)") }
            foreach ($b7FreshCall in @($b7FreshResult.Calls)) {
                $b7FreshSidSet = (@($b7FreshCall.Acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique) -join '|')
                if ($b7FreshSidSet -ne ((@('S-1-5-32-544', 'S-1-5-18', $b7ModifySid) | Sort-Object) -join '|')) { [void]$b7FreshProblems.Add("набір SID '$b7FreshSidSet'") }
            }
            . ([scriptblock]::Create((& $b7ParseFunction $b7InstallText 'Get-BRAVOPathOwnerSid').Extent.Text))
            $b7FreshOwner = Get-BRAVOPathOwnerSid -Path $b7FreshData
            $b7FreshCurrent = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            Test-BRAVOCondition -Condition (
                $b7FreshProblems.Count -eq 0 -and
                (@('S-1-5-32-544', 'S-1-5-18', $b7FreshCurrent) -contains $b7FreshOwner)
            ) -Name 'Scheduler/DataDirectoryAclAcceptsSelfCreatedDirRealOwner' `
                -Failure ("функція має приймати каталог, який сама створила (реальний власник $b7FreshOwner, поточна особа $b7FreshCurrent; без підміни Get-BRAVOPathOwnerSid): " + ($b7FreshProblems -join '; '))

            # 2b) ModifySid (RunAsUser) не є довіреним власником ПРЕДКА (P2):
            # предок 'anc' із власником = ModifySid -> throw, листок data - допустимий.
            $b7AncestorData = Join-Path $b7Scratch 'anc\data'
            $b7AncestorResult = & $b7Probe $b7InstallFunctionText $b7AncestorData @($b7ModifySid) $b7Scratch $b7ModifySid @()
            Test-BRAVOCondition -Condition (
                $b7AncestorResult.Calls.Count -eq 0 -and $null -ne $b7AncestorResult.Error -and
                $b7AncestorResult.Error.Contains('власник') -and $b7AncestorResult.Error.Contains((Join-Path $b7Scratch 'anc')) -and
                -not $b7AncestorResult.Error.Contains($b7AncestorData)
            ) -Name 'Scheduler/DataDirectoryAclRefusesUntrustedAncestorOwner' `
                -Failure ("предок із власником ModifySid має призвести до throw (ModifySid довірений лише як власник самого каталогу даних): " + [string]$b7AncestorResult.Error)

            # 3) Junction як корінь/предок каталогу даних -> throw, ціль не чіпається.
            $b7JunctionTarget = Join-Path $b7Scratch 'victim'
            [void][IO.Directory]::CreateDirectory($b7JunctionTarget)
            [IO.File]::WriteAllText((Join-Path $b7JunctionTarget 'secret.txt'), 'x')
            $b7JunctionRoot = Join-Path $b7Scratch 'junction-root'
            $b7JunctionCreated = & $b7NewJunction $b7JunctionRoot $b7JunctionTarget
            $b7RootStubs = if ($b7JunctionCreated) { @() } else { @($b7JunctionRoot) }
            if (-not $b7JunctionCreated) {
                # mklink /J недоступний у середовищі: перевіряємо власну логіку
                # функції з підміненим предикатом reparse point.
                [void][IO.Directory]::CreateDirectory($b7JunctionRoot)
            }
            $b7RootResult = & $b7Probe $b7InstallFunctionText $b7JunctionRoot @() $b7Scratch 'S-1-5-32-544' $b7RootStubs
            $b7ChildOfJunctionResult = & $b7Probe $b7InstallFunctionText (Join-Path $b7JunctionRoot 'State') @() $b7Scratch 'S-1-5-32-544' $b7RootStubs
            Test-BRAVOCondition -Condition (
                $b7RootResult.Calls.Count -eq 0 -and $null -ne $b7RootResult.Error -and $b7RootResult.Error.Contains('reparse point') -and
                $b7ChildOfJunctionResult.Calls.Count -eq 0 -and $null -ne $b7ChildOfJunctionResult.Error -and $b7ChildOfJunctionResult.Error.Contains('reparse point') -and
                -not [IO.Directory]::Exists((Join-Path $b7JunctionTarget 'State')) -and
                -not $b7RootResult.Error.Contains('Небезпечний власник')
            ) -Name 'Scheduler/DataDirectoryAclRefusesJunctionRoot' `
                -Failure ("junction як каталог даних (або його предок) має призвести до throw ДО Set-Acl і без створення каталогів у цілі (junction справжній: $b7JunctionCreated): " + [string]$b7RootResult.Error)

            # 4) Junction-дитина пропускається з WARNING; її ціль не обходиться.
            $b7ChildData = Join-Path $b7Scratch 'child-data'
            [void][IO.Directory]::CreateDirectory($b7ChildData)
            [IO.File]::WriteAllText((Join-Path $b7ChildData 'real.txt'), 'x')
            $b7ChildLink = Join-Path $b7ChildData 'link'
            $b7ChildCreated = & $b7NewJunction $b7ChildLink $b7JunctionTarget
            $b7ChildStubs = @()
            if (-not $b7ChildCreated) {
                [void][IO.Directory]::CreateDirectory($b7ChildLink)
                $b7ChildStubs = @($b7ChildLink)
            }
            $b7ChildResult = & $b7Probe $b7InstallFunctionText $b7ChildData @() $b7Scratch 'S-1-5-32-544' $b7ChildStubs
            $b7ChildPaths = @($b7ChildResult.Calls | ForEach-Object { $_.Path })
            Test-BRAVOCondition -Condition (
                $null -eq $b7ChildResult.Error -and
                ($b7ChildPaths -contains $b7ChildData) -and ($b7ChildPaths -contains (Join-Path $b7ChildData 'real.txt')) -and
                -not ($b7ChildPaths -contains $b7ChildLink) -and
                -not (@($b7ChildPaths | Where-Object { $_.StartsWith($b7JunctionTarget, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) -and
                (@($b7ChildResult.Warnings | Where-Object { $_.Contains($b7ChildLink) }).Count -eq 1)
            ) -Name 'Scheduler/DataDirectoryAclSkipsJunctionChild' `
                -Failure ("дочірній reparse point не повинен отримувати Set-Acl, ціль не обходиться, WARNING називає посилання (junction справжній: $b7ChildCreated): " + (($b7ChildPaths + $b7ChildResult.Warnings + [string]$b7ChildResult.Error) -join ' | '))

            # 5) Предикат reparse point на справжньому junction/звичайному/відсутньому шляху.
            if ($b7JunctionCreated) {
                . ([scriptblock]::Create((& $b7ParseFunction $b7InstallText 'Test-BRAVOPathIsReparsePoint').Extent.Text))
                Test-BRAVOCondition -Condition (
                    (Test-BRAVOPathIsReparsePoint -Path $b7JunctionRoot) -and
                    -not (Test-BRAVOPathIsReparsePoint -Path $b7Data) -and
                    -not (Test-BRAVOPathIsReparsePoint -Path (Join-Path $b7Scratch 'missing'))
                ) -Name 'Scheduler/ReparsePointPredicateDetectsJunction' `
                    -Failure 'Test-BRAVOPathIsReparsePoint: junction -> true; звичайний і відсутній шлях -> false'
            }

            # 6) DIAGNOSE: Get-BRAVOUsersReadableDataDirectoryFinding на реальних ACL.
            . ([scriptblock]::Create((& $b7ParseFunction $b7DiagnoseText 'Get-BRAVOUsersReadableDataDirectoryFinding').Extent.Text))
            $b7CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $b7MakeDirectory = {
                param([string]$Name, [string[]]$ExtraReaderSids)
                $directory = Join-Path $b7Scratch $Name
                [void][IO.Directory]::CreateDirectory($directory)
                $security = New-Object Security.AccessControl.DirectorySecurity
                $security.SetAccessRuleProtection($true, $false)
                foreach ($sidText in @('S-1-5-32-544', 'S-1-5-18', $b7CurrentSid.Value) + @($ExtraReaderSids)) {
                    $rights = if (@($ExtraReaderSids) -contains $sidText) { 'ReadAndExecute' } else { 'FullControl' }
                    $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                        (New-Object Security.Principal.SecurityIdentifier($sidText)), $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
                }
                Set-Acl -LiteralPath $directory -AclObject $security
                return $directory
            }
            $b7CleanDirectory = & $b7MakeDirectory 'diag-clean' @()
            $b7CleanFinding = Get-BRAVOUsersReadableDataDirectoryFinding -Path $b7CleanDirectory
            Test-BRAVOCondition -Condition ($null -eq $b7CleanFinding) `
                -Name 'Scheduler/DiagnoseNoFindingForProtectedDirectory' `
                -Failure ("каталог лише з SYSTEM/Administrators/поточним користувачем не повинен давати знахідку: $b7CleanFinding")
            $b7BroadProblems = New-Object System.Collections.ArrayList
            foreach ($b7BroadSid in @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0', 'S-1-5-4', 'S-1-5-21-1111111111-2222222222-3333333333-513')) {
                $b7BroadDirectory = & $b7MakeDirectory ('diag-' + $b7BroadSid.Replace('S-1-', '')) @($b7BroadSid)
                if ($null -eq (Get-BRAVOUsersReadableDataDirectoryFinding -Path $b7BroadDirectory)) {
                    [void]$b7BroadProblems.Add($b7BroadSid)
                }
            }
            Test-BRAVOCondition -Condition ($b7BroadProblems.Count -eq 0) `
                -Name 'Scheduler/DiagnoseFlagsBroadReaderAce' `
                -Failure ("явний ACE для Users/Authenticated Users/Everyone/INTERACTIVE/Domain Users має давати знахідку; пропущено: " + ($b7BroadProblems -join ', '))
        } finally {
            foreach ($b7Junction in @($b7ScratchJunctions)) {
                if ([IO.Directory]::Exists($b7Junction)) { & cmd.exe /c rmdir "$b7Junction" 2>&1 | Out-Null }
            }
            if ([IO.Directory]::Exists($b7Scratch)) {
                Remove-Item -LiteralPath $b7Scratch -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Test-BRAVOCondition -Condition (
        $b7InstallText -match '(?s)Set-BRAVOProtectedRuntimeAcl -RuntimeRoot \$runtimeRoot.*?runtimeLogRoot.*?Join-Path \$runtimeRoot ''TEMP''.*?\$global:stateRoot.*?Set-BRAVOProtectedDataDirectoryAcl -Path \$protectedDataDirectory' -and
        $b7InstallText.IndexOf('Не вдалося визначити SID облікового запису завдань', [StringComparison]::Ordinal) -gt 0 -and
        $b7InstallText.IndexOf('Не вдалося визначити SID облікового запису завдань', [StringComparison]::Ordinal) -lt $b7InstallText.IndexOf('Set-BRAVOProtectedRuntimeAcl -RuntimeRoot $runtimeRoot', [StringComparison]::Ordinal)
    ) -Name 'Scheduler/InstallerAppliesProtectedAclToLogsTempState' `
        -Failure 'інсталятор має застосувати Set-BRAVOProtectedDataDirectoryAcl до LOGS, TEMP і State ПІСЛЯ Set-BRAVOProtectedRuntimeAcl'
    Test-BRAVOCondition -Condition (
        $null -ne $b7RuntimeAcl -and
        $b7RuntimeAclText.Contains('[Security.AccessControl.FileSystemRights]::ReadAndExecute')
    ) -Name 'Scheduler/RuntimeRootAclKeepsUsersReadAndExecute' `
        -Failure 'ACL runtime-кореня (Set-BRAVOProtectedRuntimeAcl) не змінюється: Users ReadAndExecute лишається для читання скриптів операторами'
    $b7DiagnoseFinding = & $b7ParseFunction $b7DiagnoseText 'Get-BRAVOUsersReadableDataDirectoryFinding'
    $b7DiagnoseFindingText = if ($null -ne $b7DiagnoseFinding) { $b7DiagnoseFinding.Extent.Text } else { '' }
    Test-BRAVOCondition -Condition (
        $null -ne $b7DiagnoseFinding -and
        $b7DiagnoseFindingText.Contains("'S-1-5-32-545'") -and
        $b7DiagnoseFindingText.Contains('ReadData') -and
        $b7DiagnoseText -match '(?s)runtimeLogRoot.*?Join-Path \$\(if \(-not \[string\]::IsNullOrWhiteSpace\(\[string\]\$global:runtimeRoot\)\) \{ \[string\]\$global:runtimeRoot \} else \{ \$scriptRoot \}\) ''TEMP''.*?\$global:stateRoot.*?Get-BRAVOUsersReadableDataDirectoryFinding -Path' -and
        $b7DiagnoseText.Contains('[WARN] $($dataDirectoryEntry.Name)')
    ) -Name 'Scheduler/DiagnoseReportsUsersReadableLogsTempState' `
        -Failure 'BRAVO_TASKS_DIAGNOSE.ps1 має попереджати (WARN, без зміни коду виходу), коли LOGS/TEMP/State читаються BUILTIN\Users'
    $b7Retention = & $b7ParseFunction $maintenanceRepairScriptText 'Remove-OldRestoreArchives'
    $b7RetentionText = if ($null -ne $b7Retention) { $b7Retention.Extent.Text } else { '' }
    $b7GuardIndex = $b7RetentionText.IndexOf('if ($KeepCount -lt 1) {', [StringComparison]::Ordinal)
    $b7FirstDeleteIndex = $b7RetentionText.IndexOf('$groupsToDelete.Count -eq 0', [StringComparison]::Ordinal)
    Test-BRAVOCondition -Condition (
        $b7GuardIndex -gt 0 -and $b7FirstDeleteIndex -gt $b7GuardIndex -and
        $b7RetentionText.Substring($b7GuardIndex, 400).Contains('-Level "ERROR"') -and
        $b7RetentionText.Substring($b7GuardIndex, 400).Contains('return')
    ) -Name 'Maintenance/RestoreRetentionSkipsWhenKeepCountBelowOne' `
        -Failure 'Remove-OldRestoreArchives має за KeepCount < 1 записати ERROR і вийти до будь-якого видалення (інакше видаляються всі придатні сесії)'
} catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'MaintenanceRepair/Notifications' } }
