# Домен-фрагмент self-test: ManifestStorage (generation manifest сховище,
# BRAVO.ArchiveHelpers). Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 -- НЕ
# запускається напряму. Успадковує з викликача: $root, Test-BRAVOCondition,
# New-BRAVOSelfTestRuntimeModule, $script:failures.
#
# ПРИХОВАНА ЗАЛЕЖНІСТЬ (виявлена при розбитті, 2026-08-18): оригінальний блок
# у монолітному файлі повторно використовував $archiveScriptText,
# $healthScriptText і $archiveRuntimeTextForSizeSanity, вперше прочитані НАБАГАТО
# раніше (рядок ~2021) чи в попередньому SizeSanity-блоці, а не всередині
# самого ManifestStorage-блоку. Замість крихкої міжфайлової залежності —
# локальні read-only перечитування нижче (той самий вміст файлу, immutable
# протягом self-test-прогону; ідентичне значення, лише додаткова I/O-операція).
$archiveScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"),
    [Text.Encoding]::UTF8
)
$healthScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
    [Text.Encoding]::UTF8
)
$archiveRuntimeTextForSizeSanity = $archiveScriptText

# Silent-stub для Write-BRAVOLog (той самий підхід, що й Write-DataRestoreLog
# у BRAVO_SELF_TEST.DataRestore.ps1): retention/orphan-sweep нижче навмисно
# провокують реальні WARNING/ERROR-гілки Archive.Runtime.ps1 (mismatch
# generationId, access-denied enumerate) через справжні
# Remove-BRAVOExpiredBackupGenerations/Remove-BRAVOOrphanedTemporaryArchive-
# Artifacts — не текстову перевірку. Без цього stub-у виклик резолвиться
# у РЕАЛЬНИЙ Write-BRAVOLog (BRAVO.Logging імпортовано раніше self-test-
# прогоном) і друкує production ПОМИЛКА:/КРИТИЧНО:/УВАГА: у консоль
# self-test-у під час свідомо очікуваного negative-path сценарію. Append
# ПІСЛЯ runtime-тексту: New-BRAVOSelfTestRuntimeModule бере останнє
# визначення імені.
$manifestStorageLogStub = @'
function Write-BRAVOLog {
    param(
        [AllowEmptyString()][string]$Message,
        [string]$Level = 'INFO',
        [string]$Component = 'GENERAL',
        [switch]$Console,
        [switch]$NoConsole,
        [switch]$Environmental,
        [switch]$Secondary
    )
}
'@

    # dev.14: generation manifest-и (BRAVO_BACKUP_<GenerationId>.json) —
    # виділене сховище MANIFESTS\, окреме від LOGS/TEMP. Усі тести нижче
    # працюють ЛИШЕ із синтетичними каталогами під $env:TEMP — жодного
    # production BackupRoot/SFTP/SMB/ACL. BRAVO.ArchiveHelpers уже
    # імпортовано вище (SizeSanity), Write-BRAVOBackupGenerationManifest
    # тестується через ізольовану AST-екстракцію (Archive.Runtime.ps1
    # безумовно запускає Main при dot-source).
    $manifestWriterModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $archiveRuntimeTextForSizeSanity `
        -FunctionNames @('Write-BRAVOBackupGenerationManifest')

    function New-BRAVOManifestStorageTestGenerationState {
        param([string]$GenerationId)

        return [pscustomobject]@{
            GenerationId = $GenerationId
            StartedAt = (Get-Date)
            SnapshotSetId = $null
            Status = 'COMPLETE'
            SnapshotCreatedAt = $null
            Volumes = @()
            Components = @()
            TransferResults = $null
            HealthResult = $null
        }
    }

    $manifestStorageTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_MANIFEST_STORAGE_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($manifestStorageTestRoot)

        # --- 1. Get-BRAVOBackupManifestRoot: єдине джерело фізичного шляху ---
        Test-BRAVOCondition `
            -Condition (
                (Get-BRAVOBackupManifestRoot -BackupRoot $manifestStorageTestRoot) -eq `
                    (Join-Path $manifestStorageTestRoot 'MANIFESTS')
            ) `
            -Name "ManifestStorage/RootResolution" `
            -Failure "Get-BRAVOBackupManifestRoot має повертати BackupRoot\MANIFESTS і ніколи TEMP чи інший шлях"

        # --- 2. Writer: новий manifest завжди йде в MANIFESTS, каталог створюється сам ---
        $writerTestRoot = Join-Path $manifestStorageTestRoot 'writer'
        [void][IO.Directory]::CreateDirectory($writerTestRoot)
        $writerGenerationState = New-BRAVOManifestStorageTestGenerationState -GenerationId '20260809_120000'
        $writtenManifestPath = & $manifestWriterModule {
            param($State, $BackupRoot)
            Write-BRAVOBackupGenerationManifest -GenerationState $State -BackupRoot $BackupRoot
        } $writerGenerationState $writerTestRoot
        Test-BRAVOCondition `
            -Condition (
                $writtenManifestPath -eq (Join-Path (Join-Path $writerTestRoot 'MANIFESTS') 'BRAVO_BACKUP_20260809_120000.json') -and
                (Test-Path -LiteralPath $writtenManifestPath -PathType Leaf) -and
                -not (Test-Path -LiteralPath (Join-Path $writerTestRoot 'BRAVO_BACKUP_20260809_120000.json'))
            ) `
            -Name "ManifestStorage/WriterWritesToManifestsRoot" `
            -Failure "Write-BRAVOBackupGenerationManifest має писати новий manifest у BackupRoot\MANIFESTS (створюючи каталог за потреби), а не в корінь BackupRoot"

        $writerGenerationState.HealthResult = [pscustomobject]@{ Status = 'successful rewrite' }
        $rewrittenManifestPath = & $manifestWriterModule {
            param($State, $BackupRoot)
            Write-BRAVOBackupGenerationManifest -GenerationState $State -BackupRoot $BackupRoot
        } $writerGenerationState $writerTestRoot
        $rewrittenManifest = Get-Content -LiteralPath $rewrittenManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $orphanManifestBackups = @(
            Get-ChildItem -LiteralPath (Split-Path $rewrittenManifestPath -Parent) -File -Filter '.BRAVO_BACKUP_*.bak'
        )
        Test-BRAVOCondition `
            -Condition (
                $rewrittenManifest.healthResult.Status -eq 'successful rewrite' -and
                $orphanManifestBackups.Count -eq 0
            ) `
            -Name 'ManifestStorage/ExistingManifestRewriteSucceedsOnWindowsPowerShell51' `
            -Failure 'повторний atomic write існуючого manifest має працювати у Windows PowerShell 5.1 і не лишати backup-файл'

        $manifestBeforeFailedReplace = [IO.File]::ReadAllText($writtenManifestPath, [Text.Encoding]::UTF8)
        $writerGenerationState.HealthResult = [pscustomobject]@{ Status = 'synthetic update' }
        $manifestReplaceFailed = $false
        $manifestLock = $null
        try {
            $manifestLock = [IO.File]::Open(
                $writtenManifestPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::None
            )
            try {
                & $manifestWriterModule {
                    param($State, $BackupRoot)
                    Write-BRAVOBackupGenerationManifest -GenerationState $State -BackupRoot $BackupRoot
                } $writerGenerationState $writerTestRoot
            } catch {
                $manifestReplaceFailed = $true
            }
        } finally {
            if ($null -ne $manifestLock) {
                $manifestLock.Dispose()
            }
        }
        $manifestAfterFailedReplace = [IO.File]::ReadAllText($writtenManifestPath, [Text.Encoding]::UTF8)
        $orphanManifestTemps = @(
            Get-ChildItem -LiteralPath (Split-Path $writtenManifestPath -Parent) -File -Filter '.BRAVO_BACKUP_*.tmp'
        )
        Test-BRAVOCondition `
            -Condition (
                $manifestReplaceFailed -and
                $manifestAfterFailedReplace -ceq $manifestBeforeFailedReplace -and
                $orphanManifestTemps.Count -eq 0
            ) `
            -Name 'ManifestStorage/FailedRewritePreservesPreviousManifest' `
            -Failure 'невдалий atomic replace має лишати попередній COMPLETE manifest байт-у-байт незмінним і прибирати temporary JSON'

        # --- 3. Reader: той самий generationId в обох місцях -> MANIFESTS виграє ---
        $readerTestRoot = Join-Path $manifestStorageTestRoot 'reader-priority'
        $readerManifestsDir = Join-Path $readerTestRoot 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($readerManifestsDir)
        $legacyDuplicate = Join-Path $readerTestRoot 'BRAVO_BACKUP_20260101_010101.json'
        $newDuplicate = Join-Path $readerManifestsDir 'BRAVO_BACKUP_20260101_010101.json'
        [IO.File]::WriteAllText($legacyDuplicate, '{"generationId":"20260101_010101","source":"legacy"}')
        [IO.File]::WriteAllText($newDuplicate, '{"generationId":"20260101_010101","source":"manifests"}')
        $priorityResult = @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $readerTestRoot)
        Test-BRAVOCondition `
            -Condition (
                $priorityResult.Count -eq 1 -and
                $priorityResult[0].FullName -eq $newDuplicate
            ) `
            -Name "ManifestStorage/ReaderPrefersManifestsOnDuplicateGenerationId" `
            -Failure "коли той самий generationId є і в корені BackupRoot, і в MANIFESTS, reader має віддати рівно один запис — з MANIFESTS"
        $prioritySingle = @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $readerTestRoot -GenerationId '20260101_010101')
        Test-BRAVOCondition `
            -Condition ($prioritySingle.Count -eq 1 -and $prioritySingle[0].FullName -eq $newDuplicate) `
            -Name "ManifestStorage/ReaderByGenerationIdPrefersManifests" `
            -Failure "пошук за конкретним GenerationId також має віддавати перевагу версії з MANIFESTS"

        # --- 4. Reader: legacy-only файл (ще не мігрований) лишається видимим ---
        $readerLegacyOnlyRoot = Join-Path $manifestStorageTestRoot 'reader-legacy-only'
        [void][IO.Directory]::CreateDirectory($readerLegacyOnlyRoot)
        $legacyOnlyManifest = Join-Path $readerLegacyOnlyRoot 'BRAVO_BACKUP_20260202_020202.json'
        [IO.File]::WriteAllText($legacyOnlyManifest, '{"generationId":"20260202_020202"}')
        $legacyOnlyListAll = @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $readerLegacyOnlyRoot)
        $legacyOnlyById = @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $readerLegacyOnlyRoot -GenerationId '20260202_020202')
        Test-BRAVOCondition `
            -Condition (
                $legacyOnlyListAll.Count -eq 1 -and $legacyOnlyListAll[0].FullName -eq $legacyOnlyManifest -and
                $legacyOnlyById.Count -eq 1 -and $legacyOnlyById[0].FullName -eq $legacyOnlyManifest
            ) `
            -Name "ManifestStorage/ReaderFallsBackToLegacyRoot" `
            -Failure "на не мігрованій інсталяції (MANIFESTS відсутній або без цього файлу) reader має знаходити manifest у корені BackupRoot — і в list-all, і за GenerationId"

        # --- 5. Reader: без -Recurse — вкладені підкаталоги не потрапляють і не дублюються ---
        $readerNonRecursiveRoot = Join-Path $manifestStorageTestRoot 'reader-non-recursive'
        $deepDecoyDir = Join-Path $readerNonRecursiveRoot 'sub\deep'
        [void][IO.Directory]::CreateDirectory($deepDecoyDir)
        [IO.File]::WriteAllText((Join-Path $deepDecoyDir 'BRAVO_BACKUP_20260303_030303.json'), '{"generationId":"20260303_030303"}')
        $nonRecursiveResult = @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $readerNonRecursiveRoot)
        Test-BRAVOCondition `
            -Condition ($nonRecursiveResult.Count -eq 0) `
            -Name "ManifestStorage/ReaderIsNonRecursive" `
            -Failure "reader не повинен заглядати у вкладені підкаталоги BackupRoot (лише безпосередньо корінь і безпосередньо MANIFESTS)"

        # --- 6. Migration: переносить лише legacy-only файли ---
        $migrationBasicRoot = Join-Path $manifestStorageTestRoot 'migration-basic'
        [void][IO.Directory]::CreateDirectory($migrationBasicRoot)
        $migrationBasicFile = Join-Path $migrationBasicRoot 'BRAVO_BACKUP_20260404_040404.json'
        [IO.File]::WriteAllText($migrationBasicFile, '{"generationId":"20260404_040404"}')
        $migrationBasicResult = Initialize-BRAVOBackupManifestStorage -BackupRoot $migrationBasicRoot -Logger $null
        $migrationBasicDestination = Join-Path (Join-Path $migrationBasicRoot 'MANIFESTS') 'BRAVO_BACKUP_20260404_040404.json'
        Test-BRAVOCondition `
            -Condition (
                $migrationBasicResult.Migrated -contains 'BRAVO_BACKUP_20260404_040404.json' -and
                -not (Test-Path -LiteralPath $migrationBasicFile) -and
                (Test-Path -LiteralPath $migrationBasicDestination)
            ) `
            -Name "ManifestStorage/MigrationMovesLegacyOnlyFiles" `
            -Failure "Initialize-BRAVOBackupManifestStorage має переносити legacy manifest, для якого немає версії в MANIFESTS"

        # --- 7. Migration: другий запуск — no-op (ідемпотентність) ---
        $migrationSecondRun = Initialize-BRAVOBackupManifestStorage -BackupRoot $migrationBasicRoot -Logger $null
        Test-BRAVOCondition `
            -Condition (
                $migrationSecondRun.Migrated.Count -eq 0 -and
                $migrationSecondRun.Deduplicated.Count -eq 0 -and
                $migrationSecondRun.Conflicts.Count -eq 0 -and
                $migrationSecondRun.Errors.Count -eq 0 -and
                (Test-Path -LiteralPath $migrationBasicDestination)
            ) `
            -Name "ManifestStorage/MigrationSecondRunIsNoOp" `
            -Failure "повторний запуск міграції на вже мігрованій інсталяції не повинен нічого переносити, дублювати чи позначати як конфлікт"

        # --- 8. Migration: байтово ідентичний дублікат -> legacy прибирається ---
        $migrationDedupRoot = Join-Path $manifestStorageTestRoot 'migration-dedup'
        $migrationDedupManifests = Join-Path $migrationDedupRoot 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($migrationDedupManifests)
        $dedupContent = '{"generationId":"20260505_050505","identical":true}'
        $dedupLegacy = Join-Path $migrationDedupRoot 'BRAVO_BACKUP_20260505_050505.json'
        $dedupDestination = Join-Path $migrationDedupManifests 'BRAVO_BACKUP_20260505_050505.json'
        [IO.File]::WriteAllText($dedupLegacy, $dedupContent)
        [IO.File]::WriteAllText($dedupDestination, $dedupContent)
        $migrationDedupResult = Initialize-BRAVOBackupManifestStorage -BackupRoot $migrationDedupRoot -Logger $null
        Test-BRAVOCondition `
            -Condition (
                $migrationDedupResult.Deduplicated -contains 'BRAVO_BACKUP_20260505_050505.json' -and
                -not (Test-Path -LiteralPath $dedupLegacy) -and
                (Test-Path -LiteralPath $dedupDestination) -and
                ([IO.File]::ReadAllText($dedupDestination)) -eq $dedupContent
            ) `
            -Name "ManifestStorage/MigrationDedupesIdenticalCollision" `
            -Failure "коли legacy і MANIFESTS файли байтово ідентичні (SHA256), міграція має прибрати legacy-дублікат і лишити MANIFESTS без змін"

        # --- 9. Migration: різний вміст -> ЖОДЕН файл не чіпається, є конфлікт + WARNING ---
        $migrationConflictRoot = Join-Path $manifestStorageTestRoot 'migration-conflict'
        $migrationConflictManifests = Join-Path $migrationConflictRoot 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($migrationConflictManifests)
        $conflictLegacyContent = '{"generationId":"20260606_060606","source":"legacy"}'
        $conflictNewContent = '{"generationId":"20260606_060606","source":"manifests"}'
        $conflictLegacy = Join-Path $migrationConflictRoot 'BRAVO_BACKUP_20260606_060606.json'
        $conflictDestination = Join-Path $migrationConflictManifests 'BRAVO_BACKUP_20260606_060606.json'
        [IO.File]::WriteAllText($conflictLegacy, $conflictLegacyContent)
        [IO.File]::WriteAllText($conflictDestination, $conflictNewContent)
        $conflictLoggedMessages = New-Object System.Collections.ArrayList
        $conflictLogger = {
            param($Message, $Level)
            [void]$conflictLoggedMessages.Add(@{ Message = $Message; Level = $Level })
        }
        $migrationConflictResult = Initialize-BRAVOBackupManifestStorage -BackupRoot $migrationConflictRoot -Logger $conflictLogger
        $conflictWarningLogged = @($conflictLoggedMessages | Where-Object {
            $_.Level -eq 'WARNING' -and
            [string]$_.Message -match '20260606_060606' -and
            [string]$_.Message -match '[Кк]онфлікт'
        })
        Test-BRAVOCondition `
            -Condition (
                $migrationConflictResult.Conflicts -contains 'BRAVO_BACKUP_20260606_060606.json' -and
                (Test-Path -LiteralPath $conflictLegacy) -and
                (Test-Path -LiteralPath $conflictDestination) -and
                ([IO.File]::ReadAllText($conflictLegacy)) -eq $conflictLegacyContent -and
                ([IO.File]::ReadAllText($conflictDestination)) -eq $conflictNewContent -and
                $conflictWarningLogged.Count -eq 1
            ) `
            -Name "ManifestStorage/MigrationPreservesConflictingCollisionAndWarns" `
            -Failure "коли legacy і MANIFESTS файли того самого generationId відрізняються, міграція НЕ повинна видаляти чи перезаписувати жоден з них — лише WARNING з generationId конфлікту"

        # --- 10. Migration: без -Recurse — вкладений legacy файл не переноситься ---
        $migrationNonRecursiveRoot = Join-Path $manifestStorageTestRoot 'migration-non-recursive'
        $migrationDeepDecoyDir = Join-Path $migrationNonRecursiveRoot 'sub\deep'
        [void][IO.Directory]::CreateDirectory($migrationDeepDecoyDir)
        $deepLegacyFile = Join-Path $migrationDeepDecoyDir 'BRAVO_BACKUP_20260707_070707.json'
        [IO.File]::WriteAllText($deepLegacyFile, '{"generationId":"20260707_070707"}')
        $migrationNonRecursiveResult = Initialize-BRAVOBackupManifestStorage -BackupRoot $migrationNonRecursiveRoot -Logger $null
        Test-BRAVOCondition `
            -Condition (
                $migrationNonRecursiveResult.Migrated.Count -eq 0 -and
                (Test-Path -LiteralPath $deepLegacyFile) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $migrationNonRecursiveRoot 'MANIFESTS') 'BRAVO_BACKUP_20260707_070707.json'))
            ) `
            -Name "ManifestStorage/MigrationIsNonRecursive" `
            -Failure "міграція має шукати legacy manifest-и лише безпосередньо в корені BackupRoot, а не рекурсивно у вкладених підкаталогах"

        # --- 11. Migration: відсутній BackupRoot -> помилка у результаті, без throw ---
        $missingBackupRoot = Join-Path $manifestStorageTestRoot 'does-not-exist'
        $missingRootThrew = $false
        $missingRootResult = $null
        try {
            $missingRootResult = Initialize-BRAVOBackupManifestStorage -BackupRoot $missingBackupRoot -Logger $null
        } catch {
            $missingRootThrew = $true
        }
        Test-BRAVOCondition `
            -Condition (-not $missingRootThrew -and $null -ne $missingRootResult -and $missingRootResult.Errors.Count -gt 0) `
            -Name "ManifestStorage/MigrationHandlesMissingBackupRootGracefully" `
            -Failure "міграція має повертати структурований результат з Errors, а не кидати виняток, коли BackupRoot ще не існує"
    } finally {
        if (Test-Path -LiteralPath $manifestStorageTestRoot) {
            Remove-Item -LiteralPath $manifestStorageTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Retention: видалення generation прибирає ОБИДВІ фізичні копії
    # manifest-а (MANIFESTS і legacy-корінь), а не лише ту, яку
    # MANIFESTS-first reader обрав для рішення про видалення. Інакше
    # legacy-копія переживає видалення й "воскрешає" generation на
    # наступному запуску через legacy fallback читання (dev.14, round 2).
    # Викликає РЕАЛЬНУ Remove-BRAVOExpiredBackupGenerations (ізольована
    # AST-екстракція, як і решта Archive-тестів у цьому файлі) — не
    # симуляцію алгоритму, бо саме порядок фізичного видалення тут і є
    # предметом перевірки.
    $retentionCleanupModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($archiveRuntimeTextForSizeSanity + [Environment]::NewLine + $manifestStorageLogStub) `
        -FunctionNames @(
            'Remove-BRAVOExpiredBackupGenerations',
            'Resolve-BRAVORetentionGenerationManifest',
            'Get-BRAVORetentionUnresolvedComponentTypes',
            'Get-BRAVOGenerationManifestArtifactProblems',
            'Get-BRAVOUnreferencedBackupArchives',
            'Get-BRAVOGenerationManifestComponents',
            'Test-BRAVOGenerationManifestVerified',
            'Show-ArchiveCleanupSection',
            'Show-ScriptProgress',
            'Test-BRAVOBackupArtifactPathSafe',
            'Write-BRAVOLog'
        ) `
        -PreferLastDefinitionOnDuplicate
    $retentionCleanupTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_RETENTION_CLEANUP_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($retentionCleanupTestRoot)
        $retentionCleanupManifestsDir = Join-Path $retentionCleanupTestRoot 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($retentionCleanupManifestsDir)

        $retentionTargetLegacy = Join-Path $retentionCleanupTestRoot 'BRAVO_BACKUP_20260101_010101.json'
        $retentionTargetNew = Join-Path $retentionCleanupManifestsDir 'BRAVO_BACKUP_20260101_010101.json'
        # Різний вміст (note) — той самий "конфлікт", який міграція раніше
        # свідомо зберегла обома копіями; тепер generation все одно
        # видаляється цілком, бо retention уже прийняв рішення про видалення.
        [IO.File]::WriteAllText($retentionTargetLegacy, '{"generationId":"20260101_010101","status":"FAILED","startedAt":"2026-01-01T00:00:00","note":"legacy"}')
        [IO.File]::WriteAllText($retentionTargetNew, '{"generationId":"20260101_010101","status":"FAILED","startedAt":"2026-01-01T00:00:00","note":"manifests"}')

        $global:enableArchiveDeletion = $true
        $global:enableFailedArchiveDeletion = $true
        $global:failedArchiveRetentionDays = 1
        $global:minimumRetainedVerifiedBackups = 1
        $global:progressSettings = $null
        try {
            $retentionCleanupSectionShown = $false
            $retentionCleanupOk = & $retentionCleanupModule {
                param($BackupRoot, $CurrentGenerationId, $SectionShownRef)
                Remove-BRAVOExpiredBackupGenerations `
                    -BackupRoot $BackupRoot `
                    -CurrentGenerationId $CurrentGenerationId `
                    -RetentionDays 183 `
                    -CleanupSectionShown $SectionShownRef
            } $retentionCleanupTestRoot 'CURRENT_GENERATION_NOT_TARGET' ([ref]$retentionCleanupSectionShown)

            Test-BRAVOCondition `
                -Condition (
                    $retentionCleanupOk -eq $true -and
                    -not (Test-Path -LiteralPath $retentionTargetLegacy) -and
                    -not (Test-Path -LiteralPath $retentionTargetNew)
                ) `
                -Name "ManifestStorage/RetentionDeletesBothPhysicalManifestCopies" `
                -Failure "видалення generation має прибирати ОБИДВІ фізичні копії її manifest-а (MANIFESTS і legacy-корінь), а не лише ту, яку MANIFESTS-first reader повернув"

            $retentionCleanupAfterDelete = @(Get-BRAVOBackupGenerationManifestFiles `
                -BackupRoot $retentionCleanupTestRoot `
                -GenerationId '20260101_010101')
            Test-BRAVOCondition `
                -Condition ($retentionCleanupAfterDelete.Count -eq 0) `
                -Name "ManifestStorage/DeletedGenerationCannotReappearViaLegacyFallback" `
                -Failure "після видалення generation reader не повинен знаходити її manifest ні в MANIFESTS, ні через legacy fallback — інакше видалена generation 'воскресає' на наступному запуску"

            # --- dev.14 (round 3): filename/JSON generationId identity.
            # X — файл, ім'я якого каже generationId X, а JSON усередині
            # каже generationId Y (пошкодження/підміна). Y — РЕАЛЬНА,
            # окрема, ще не прострочена (сьогоднішня) generation. Без
            # перевірки identity X "видав би себе" за Y під час обробки й
            # ризикував би зачепити фізичні файли Y через
            # Get-BRAVOBackupGenerationManifestPhysicalFiles -GenerationId Y.
            $identityMismatchFile = Join-Path $retentionCleanupTestRoot 'BRAVO_BACKUP_20260101_010101.json'
            [IO.File]::WriteAllText($identityMismatchFile, '{"generationId":"20260202_020202","status":"FAILED","startedAt":"2026-01-01T00:00:00"}')
            $today = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
            $identityRealGenFile = Join-Path $retentionCleanupManifestsDir 'BRAVO_BACKUP_20260202_020202.json'
            [IO.File]::WriteAllText($identityRealGenFile, ('{{"generationId":"20260202_020202","status":"FAILED","startedAt":"{0}"}}' -f $today))

            $identitySectionShown = $false
            $identityOk = & $retentionCleanupModule {
                param($BackupRoot, $CurrentGenerationId, $SectionShownRef)
                Remove-BRAVOExpiredBackupGenerations `
                    -BackupRoot $BackupRoot `
                    -CurrentGenerationId $CurrentGenerationId `
                    -RetentionDays 183 `
                    -CleanupSectionShown $SectionShownRef
            } $retentionCleanupTestRoot 'CURRENT_GENERATION_NOT_TARGET_2' ([ref]$identitySectionShown)

            Test-BRAVOCondition `
                -Condition (
                    $identityOk -eq $true -and
                    (Test-Path -LiteralPath $identityMismatchFile)
                ) `
                -Name "ManifestStorage/ManifestFilenameAndJsonGenerationMustMatch" `
                -Failure "Remove-BRAVOExpiredBackupGenerations має перевіряти, що generationId з JSON збігається з generationId, закодованим у імені файлу"
            Test-BRAVOCondition `
                -Condition (Test-Path -LiteralPath $identityMismatchFile) `
                -Name "ManifestStorage/MismatchedGenerationIdIsExcludedFromRetention" `
                -Failure "файл із невідповідним generationId не повинен видалятися — mismatch виключає запис із retention (як parse error), а не використовується для рішення про видалення"
            Test-BRAVOCondition `
                -Condition (Test-Path -LiteralPath $identityRealGenFile) `
                -Name "ManifestStorage/MismatchedManifestCannotDeleteOtherGenerationMetadata" `
                -Failure "недовірений (mismatched) manifest НЕ повинен призводити до видалення physical manifest-а ІНШОЇ, реальної generation, на яку помилково вказує JSON"
        } finally {
            Remove-Item -Path Variable:\global:enableArchiveDeletion, `
                Variable:\global:enableFailedArchiveDeletion, `
                Variable:\global:failedArchiveRetentionDays, `
                Variable:\global:minimumRetainedVerifiedBackups, `
                Variable:\global:progressSettings `
                -ErrorAction SilentlyContinue
        }
    } finally {
        if (Test-Path -LiteralPath $retentionCleanupTestRoot) {
            Remove-Item -LiteralPath $retentionCleanupTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Retention Safety Invariants (roadmap Етап 4): пошкоджена НАЙНОВІША
    # generation (manifest каже COMPLETE, але байти archive змінені після
    # запису .sha512) не повинна витісняти справді валідну СТАРІШУ
    # generation із захищеного (protected) набору. VerifiedComplete
    # переперевіряє SHA512 на диску (не лише вірить полю status), тому
    # пошкоджена generation не захищається і видаляється лише за строком
    # зберігання (#335: не гілкою невдалих), а старша валідна
    # лишається захищеною — цей сценарій раніше не мав ЄДИНОГО end-to-end
    # тесту (окремо тестувались пошкодження хешу й окремо selection-алгоритм).
    $corruptNewestTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_CORRUPT_NEWEST_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($corruptNewestTestRoot)
        $corruptNewestManifestsDir = Join-Path $corruptNewestTestRoot 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($corruptNewestManifestsDir)

        function New-BRAVORetentionFixtureGeneration {
            param([string]$Root, [string]$GenerationId, [datetime]$StartedAt, [switch]$Corrupt)
            $archivePath = Join-Path $Root ("MODEL_{0}.mdz" -f $GenerationId)
            $hashPath = $archivePath + '.sha512'
            [IO.File]::WriteAllText($archivePath, ("payload-{0}" -f $GenerationId))
            $hash = (Get-BRAVOFileHash -Path $archivePath -Algorithm SHA512).Hash
            [IO.File]::WriteAllText($hashPath, ("{0} *{1}" -f $hash.ToLowerInvariant(), [IO.Path]::GetFileName($archivePath)))
            if ($Corrupt) {
                [IO.File]::AppendAllText($archivePath, 'corruption')
            }
            $manifestJson = (
                '{{"generationId":"{0}","status":"COMPLETE","startedAt":"{1}",' +
                '"components":{{"MODEL":{{"CreateSuccess":true,"IntegritySuccess":true,"HashSuccess":true,' +
                '"ArchivePath":"{2}","HashPath":"{3}"}}}}}}'
            ) -f $GenerationId, $StartedAt.ToString('yyyy-MM-ddTHH:mm:ss'),
                $archivePath.Replace('\', '\\'), $hashPath.Replace('\', '\\')
            [IO.File]::WriteAllText(
                (Join-Path $Root ("MANIFESTS\BRAVO_BACKUP_{0}.json" -f $GenerationId)),
                $manifestJson
            )
            return @{ ArchivePath = $archivePath; HashPath = $hashPath }
        }

        $olderValidGenerationId = '20250101_010000'
        $newestCorruptedGenerationId = '20250601_010000'
        $olderValidFiles = New-BRAVORetentionFixtureGeneration `
            -Root $corruptNewestTestRoot -GenerationId $olderValidGenerationId `
            -StartedAt (Get-Date).AddDays(-200)
        $newestCorruptedFiles = New-BRAVORetentionFixtureGeneration `
            -Root $corruptNewestTestRoot -GenerationId $newestCorruptedGenerationId `
            -StartedAt (Get-Date).AddDays(-190) -Corrupt

        $global:enableArchiveDeletion = $true
        $global:enableFailedArchiveDeletion = $true
        $global:failedArchiveRetentionDays = 30
        $global:minimumRetainedVerifiedBackups = 1
        $global:progressSettings = $null
        try {
            $corruptNewestSectionShown = $false
            $corruptNewestOk = & $retentionCleanupModule {
                param($BackupRoot, $CurrentGenerationId, $SectionShownRef)
                Remove-BRAVOExpiredBackupGenerations `
                    -BackupRoot $BackupRoot `
                    -CurrentGenerationId $CurrentGenerationId `
                    -RetentionDays 183 `
                    -CleanupSectionShown $SectionShownRef
            } $corruptNewestTestRoot 'CURRENT_GENERATION_NOT_TARGET_3' ([ref]$corruptNewestSectionShown)

            Test-BRAVOCondition `
                -Condition (
                    $corruptNewestOk -eq $true -and
                    -not (Test-Path -LiteralPath $newestCorruptedFiles.ArchivePath) -and
                    -not (Test-Path -LiteralPath $newestCorruptedFiles.HashPath) -and
                    (Test-Path -LiteralPath $olderValidFiles.ArchivePath) -and
                    (Test-Path -LiteralPath $olderValidFiles.HashPath)
                ) `
                -Name "BackupConsistency/CorruptNewestGenerationIsNotProtectedAndOlderVerifiedSurvives" `
                -Failure "пошкоджена НАЙНОВІША generation (SHA512 не збігається) не повинна рахуватися серед захищених і видаляється лише за строком зберігання, а СТАРІША справді валідна generation має лишатись захищеною, попри те, що вона хронологічно старіша"
        } finally {
            Remove-Item -Path Variable:\global:enableArchiveDeletion, `
                Variable:\global:enableFailedArchiveDeletion, `
                Variable:\global:failedArchiveRetentionDays, `
                Variable:\global:minimumRetainedVerifiedBackups, `
                Variable:\global:progressSettings `
                -ErrorAction SilentlyContinue
        }
    } finally {
        if (Test-Path -LiteralPath $corruptNewestTestRoot) {
            Remove-Item -LiteralPath $corruptNewestTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- #335 (safety): гілку видалення визначає ЗАПИСАНИЙ статус прогону,
    # а не сьогоднішня перевірка; пошкодження COMPLETE дає WARNING, а не
    # видалення (також для COMPLETE старших за N захищених); шляхи
    # manifest-а перебудовуються як у відновленні; manifest видаляється
    # після архівів; помилка на одній generation не зупиняє інші; архіви без
    # manifest-а лише рахуються; невідомий тип компонента не видаляється.
    # Реальна Remove-BRAVOExpiredBackupGenerations на тимчасовому дереві
    # MODEL + BLOG + MANIFESTS. Лог і виклики SHA512 фіксуються заглушками.
    $retentionCaptureStub = @'
function Write-BRAVOLog {
    param(
        [AllowEmptyString()][string]$Message,
        [string]$Level = 'INFO',
        [string]$Component = 'GENERAL',
        [switch]$Console,
        [switch]$NoConsole,
        [switch]$Environmental,
        [switch]$Secondary
    )
    [void]$global:BRAVORetentionTestLog.Add(('{0}|{1}' -f $Level, $Message))
}
function Get-BRAVOFileHash {
    param([string]$Path, [string]$Algorithm)
    $global:BRAVORetentionHashCalls = [int]$global:BRAVORetentionHashCalls + 1
    if ($null -eq $global:BRAVORetentionHashPaths) { $global:BRAVORetentionHashPaths = New-Object System.Collections.ArrayList }
    [void]$global:BRAVORetentionHashPaths.Add([string]$Path)
    # Збій читання саме під час SHA512 (файл заблоковано/диск недоступний).
    if ($null -ne $global:BRAVORetentionHashFailPath -and [string]$Path -eq [string]$global:BRAVORetentionHashFailPath) {
        throw (New-Object System.IO.IOException 'The process cannot access the file because it is being used by another process.')
    }
    $sha = [System.Security.Cryptography.SHA512]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try { $bytes = $sha.ComputeHash($stream) } finally { $stream.Dispose(); $sha.Dispose() }
    return [pscustomobject]@{ Hash = ([BitConverter]::ToString($bytes) -replace '-', '') }
}
'@
    $retentionSafetyModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($archiveRuntimeTextForSizeSanity + [Environment]::NewLine + $retentionCaptureStub) `
        -FunctionNames @(
            'Remove-BRAVOExpiredBackupGenerations',
            'Resolve-BRAVORetentionGenerationManifest',
            'Get-BRAVORetentionUnresolvedComponentTypes',
            'Get-BRAVOGenerationManifestArtifactProblems',
            'Get-BRAVOUnreferencedBackupArchives',
            'Get-BRAVOGenerationManifestComponents',
            'Test-BRAVOGenerationManifestVerified',
            'Show-ArchiveCleanupSection',
            'Show-ScriptProgress',
            'Test-BRAVOBackupArtifactPathSafe',
            'Write-BRAVOLog',
            'Get-BRAVOFileHash'
        ) `
        -PreferLastDefinitionOnDuplicate

    function New-BRAVORetentionComponentFixture {
        param(
            [string]$Root,
            [string]$GenerationId,
            [datetime]$StartedAt,
            [string]$Status = 'COMPLETE',
            [string[]]$Components = @('MODEL', 'BLOG'),
            # Змінює розмір архіву після запису ArchiveSize/.sha512.
            [string[]]$CorruptComponents = @(),
            # Змінює байти БЕЗ зміни розміру: видно лише по SHA512.
            [string[]]$BitRotComponents = @(),
            # Корінь, записаний у manifest (інший диск до перенесення).
            [string]$RecordedRoot
        )
        $recordRoot = if ([string]::IsNullOrWhiteSpace($RecordedRoot)) { $Root } else { $RecordedRoot }
        $componentsJson = @()
        foreach ($component in $Components) {
            $directory = Join-Path $Root $component
            [void][IO.Directory]::CreateDirectory($directory)
            $archiveName = "{0}_{1}.mdz" -f $component, $GenerationId
            $archivePath = Join-Path $directory $archiveName
            $payload = "payload-{0}-{1}" -f $component, $GenerationId
            [IO.File]::WriteAllText($archivePath, $payload)
            $size = (Get-Item -LiteralPath $archivePath).Length
            $hash = (Get-BRAVOFileHash -Path $archivePath -Algorithm SHA512).Hash
            [IO.File]::WriteAllText($archivePath + '.sha512', ("{0} *{1}" -f $hash.ToLowerInvariant(), $archiveName))
            if ($CorruptComponents -contains $component) {
                [IO.File]::AppendAllText($archivePath, 'corruption')
            }
            if ($BitRotComponents -contains $component) {
                [IO.File]::WriteAllText($archivePath, ('X' * $payload.Length))
            }
            $recordedArchivePath = Join-Path (Join-Path $recordRoot $component) $archiveName
            $componentsJson += (
                '"{0}":{{"CreateSuccess":true,"IntegritySuccess":true,"HashSuccess":true,' +
                '"ArchiveSize":{3},"ArchivePath":"{1}","HashPath":"{2}"}}'
            ) -f $component, $recordedArchivePath.Replace('\', '\\'), ($recordedArchivePath + '.sha512').Replace('\', '\\'), $size
        }
        $manifestsDirectory = Join-Path $Root 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($manifestsDirectory)
        $manifestPath = Join-Path $manifestsDirectory ("BRAVO_BACKUP_{0}.json" -f $GenerationId)
        [IO.File]::WriteAllText($manifestPath, (
            '{{"generationId":"{0}","status":"{1}","startedAt":"{2}","components":{{{3}}}}}' -f
            $GenerationId, $Status, $StartedAt.ToString('yyyy-MM-ddTHH:mm:ss'), ($componentsJson -join ',')
        ))
        return $manifestPath
    }

    function Invoke-BRAVORetentionFixtureCleanup {
        param([string]$Root, [string]$CurrentGenerationId, [object[]]$ArchiveDefinitions, [switch]$StrictMode)
        $global:BRAVORetentionTestLog = New-Object System.Collections.ArrayList
        $global:BRAVORetentionHashCalls = 0
        $global:BRAVORetentionHashPaths = New-Object System.Collections.ArrayList
        $sectionShown = $false
        return (& $retentionSafetyModule {
            param($BackupRoot, $CurrentId, $Definitions, $SectionShownRef, $UseStrictMode)
            # Production виконується під Set-StrictMode -Version 2.0
            # (BRAVO_CONFIG_LOADER.ps1); сценарії, що це моделюють, вмикають
            # його лише в області цього scriptblock. Під StrictMode retention
            # читає змінні конфігурації, які в production завжди задає
            # BRAVO.Configuration: тут вони задаються з тими ж значеннями за
            # замовчуванням, інакше невизначена змінна чи властивість $null
            # кидала б виняток і видалення падало б у catch.
            if ($UseStrictMode) {
                Set-StrictMode -Version 2.0
                $archiveFileFilter = '*.mdz'
                $progressSettings = @{ Enabled = $false; ShowOverallProgress = $false }
            }
            Remove-BRAVOExpiredBackupGenerations `
                -BackupRoot $BackupRoot `
                -CurrentGenerationId $CurrentId `
                -RetentionDays 183 `
                -CleanupSectionShown $SectionShownRef `
                -ArchiveDefinitions $Definitions
        } $Root $CurrentGenerationId $ArchiveDefinitions ([ref]$sectionShown) ([bool]$StrictMode))
    }

    # Підміняє значення startedAt у згенерованому manifest-і буквальним
    # JSON-фрагментом (null, "рядок") і виставляє давній LastWriteTime файлу.
    function Set-BRAVORetentionManifestStartedAt {
        param([string]$ManifestPath, [string]$JsonValue, [datetime]$LastWriteTime)
        $manifestText = [IO.File]::ReadAllText($ManifestPath)
        $patchedText = [regex]::Replace($manifestText, '"startedAt":"[^"]*"', ('"startedAt":' + $JsonValue))
        if ($patchedText -ceq $manifestText) { throw "startedAt не знайдено у fixture manifest: $ManifestPath" }
        [IO.File]::WriteAllText($ManifestPath, $patchedText)
        (Get-Item -LiteralPath $ManifestPath).LastWriteTime = $LastWriteTime
    }

    function Get-BRAVORetentionFixtureDefinitions {
        param([string]$Root)
        return @(
            @{ Type = 'MODEL'; Destination = (Join-Path $Root 'MODEL'); NameTemplate = '{0}_{1}.mdz' },
            @{ Type = 'BLOG'; Destination = (Join-Path $Root 'BLOG'); NameTemplate = '{0}_{1}.mdz' }
        )
    }

    function Test-BRAVORetentionLogged {
        param([string]$Level, [string]$Pattern)
        return (@($global:BRAVORetentionTestLog | Where-Object {
            $_.StartsWith($Level + '|') -and $_.Contains($Pattern)
        }).Count -gt 0)
    }

    $retentionStatusTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_RETENTION_STATUS_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    $global:enableFailedArchiveDeletion = $true
    $global:failedArchiveRetentionDays = 30
    $global:minimumRetainedVerifiedBackups = 2
    $global:progressSettings = $null
    $global:BRAVORetentionHashFailPath = $null
    $global:BRAVORetentionHashPaths = New-Object System.Collections.ArrayList
    try {
        # Сценарій 1: COMPLETE generation 41 дня з пошкодженим BLOG при
        # enableArchiveDeletion=$false. Раніше вона йшла у гілку невдалих
        # і видалялась разом із цілим MODEL, без жодного попередження.
        $global:enableArchiveDeletion = $false
        $statusRoot = Join-Path $retentionStatusTestRoot 'corrupt-component'
        $corruptComponentManifest = New-BRAVORetentionComponentFixture -Root $statusRoot `
            -GenerationId '20260821_230000' -StartedAt (Get-Date).AddDays(-41) -CorruptComponents @('BLOG')
        [void](New-BRAVORetentionComponentFixture -Root $statusRoot -GenerationId '20260930_230000' -StartedAt (Get-Date).AddDays(-1))
        [void](New-BRAVORetentionComponentFixture -Root $statusRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $corruptComponentOk = Invoke-BRAVORetentionFixtureCleanup -Root $statusRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $statusRoot)
        Test-BRAVOCondition `
            -Condition (
                $corruptComponentOk -eq $true -and
                (Test-Path -LiteralPath $corruptComponentManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $statusRoot 'MODEL') 'MODEL_20260821_230000.mdz')) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $statusRoot 'BLOG') 'BLOG_20260821_230000.mdz')) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Пошкоджена резервна копія 20260821_230000')
            ) `
            -Name "BackupConsistency/CompleteGenerationIsNeverDeletedAsFailedAndCorruptionWarns" `
            -Failure "COMPLETE generation, що сьогодні не проходить перевірку, не повинна видалятися гілкою failedArchiveRetentionDays (особливо при enableArchiveDeletion=false), а пошкодження має давати WARNING 'Пошкоджена резервна копія'"
        Test-BRAVOCondition `
            -Condition ($global:BRAVORetentionHashCalls -eq 0) `
            -Name "BackupConsistency/NoSha512WhenArchiveDeletionDisabled" `
            -Failure "при enableArchiveDeletion=false захист N нічого не вирішує, тому retention не повинен читати архіви для SHA512; викликів: $($global:BRAVORetentionHashCalls)"

        # COMPLETE + enableArchiveDeletion=$false: навіть дуже стара і ціла
        # generation не видаляється ніколи.
        $ancientManifest = New-BRAVORetentionComponentFixture -Root $statusRoot `
            -GenerationId '20250101_230000' -StartedAt (Get-Date).AddDays(-640)
        [void](Invoke-BRAVORetentionFixtureCleanup -Root $statusRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $statusRoot))
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath $ancientManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $statusRoot 'MODEL') 'MODEL_20250101_230000.mdz'))
            ) `
            -Name "BackupConsistency/CompleteGenerationNeverDeletedWhenArchiveDeletionDisabled" `
            -Failure "COMPLETE generation при enableArchiveDeletion=false не повинна видалятися ніколи, який би вік вона не мала"

        # Невдала (не COMPLETE) generation старша за 30 днів і далі
        # прибирається, навіть коли enableArchiveDeletion вимкнено.
        $failedStatusManifest = New-BRAVORetentionComponentFixture -Root $statusRoot `
            -GenerationId '20260801_230000' -StartedAt (Get-Date).AddDays(-61) -Status 'FAILED'
        $failedStatusOk = Invoke-BRAVORetentionFixtureCleanup -Root $statusRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $statusRoot)
        Test-BRAVOCondition `
            -Condition (
                $failedStatusOk -eq $true -and
                -not (Test-Path -LiteralPath $failedStatusManifest) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $statusRoot 'MODEL') 'MODEL_20260801_230000.mdz')) -and
                (Test-Path -LiteralPath $corruptComponentManifest)
            ) `
            -Name "BackupConsistency/FailedGenerationStillExpiresByFailedRetention" `
            -Failure "generation зі статусом не COMPLETE, старша за failedArchiveRetentionDays, має видалятися разом з архівами незалежно від enableArchiveDeletion"

        # Сценарій 2: COMPLETE, старша за N захищених, пошкоджена; при
        # enableArchiveDeletion=$true. Раніше цикл захисту зупинявся після N
        # цілих, і пошкодження старших не бачив ніхто. Дешева перевірка
        # дає WARNING для кожної; SHA512 читає лише найновіших (4 виклики:
        # 2 generation x 2 компоненти), а не всю історію.
        $global:enableArchiveDeletion = $true
        $oldRoot = Join-Path $retentionStatusTestRoot 'old-corrupt'
        [void](New-BRAVORetentionComponentFixture -Root $oldRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        [void](New-BRAVORetentionComponentFixture -Root $oldRoot -GenerationId '20260930_230000' -StartedAt (Get-Date).AddDays(-1))
        [void](New-BRAVORetentionComponentFixture -Root $oldRoot -GenerationId '20260929_230000' -StartedAt (Get-Date).AddDays(-2))
        $oldCorruptManifest = New-BRAVORetentionComponentFixture -Root $oldRoot `
            -GenerationId '20260821_230000' -StartedAt (Get-Date).AddDays(-41) -CorruptComponents @('BLOG')
        $oldExpiredManifest = New-BRAVORetentionComponentFixture -Root $oldRoot `
            -GenerationId '20250101_230000' -StartedAt (Get-Date).AddDays(-640)
        $oldCorruptOk = Invoke-BRAVORetentionFixtureCleanup -Root $oldRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $oldRoot)
        Test-BRAVOCondition `
            -Condition (
                $oldCorruptOk -eq $true -and
                (Test-Path -LiteralPath $oldCorruptManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $oldRoot 'MODEL') 'MODEL_20260821_230000.mdz')) -and
                -not (Test-Path -LiteralPath $oldExpiredManifest) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Пошкоджена резервна копія 20260821_230000') -and
                $global:BRAVORetentionHashCalls -eq 4
            ) `
            -Name "BackupConsistency/OldCorruptCompleteBeyondProtectedWarnsAndIsKept" `
            -Failure "COMPLETE generation старша за N захищених і ще не прострочена, але з пошкодженим архівом, має давати WARNING і лишатися; прострочена ціла видаляється; SHA512 лише для найновіших (очікувано 4 виклики, фактично $($global:BRAVORetentionHashCalls))"

        # Приховане пошкодження (той самий розмір) виявляє SHA512 під час
        # вибору захищених: така copy не захищається, WARNING називає SHA512.
        $bitRotRoot = Join-Path $retentionStatusTestRoot 'bit-rot'
        [void](New-BRAVORetentionComponentFixture -Root $bitRotRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $bitRotManifest = New-BRAVORetentionComponentFixture -Root $bitRotRoot `
            -GenerationId '20260930_230000' -StartedAt (Get-Date).AddDays(-1) -BitRotComponents @('MODEL')
        [void](New-BRAVORetentionComponentFixture -Root $bitRotRoot -GenerationId '20260929_230000' -StartedAt (Get-Date).AddDays(-2))
        [void](New-BRAVORetentionComponentFixture -Root $bitRotRoot -GenerationId '20250101_230000' -StartedAt (Get-Date).AddDays(-640))
        $bitRotOk = Invoke-BRAVORetentionFixtureCleanup -Root $bitRotRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $bitRotRoot)
        Test-BRAVOCondition `
            -Condition (
                $bitRotOk -eq $true -and
                (Test-Path -LiteralPath $bitRotManifest) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Пошкоджена резервна копія 20260930_230000') -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'SHA512') -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $bitRotRoot 'MODEL') 'MODEL_20260929_230000.mdz')) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $bitRotRoot 'MODEL') 'MODEL_20250101_230000.mdz'))
            ) `
            -Name "BackupConsistency/Sha512MismatchWarnsAndOlderVerifiedIsProtected" `
            -Failure "COMPLETE з однаковим розміром, але іншим вмістом, має давати WARNING про SHA512, не захищатися і не видалятися як невдала; старша ціла generation має стати захищеною"

        # Нічого не прострочено при enableArchiveDeletion=$true: хешування
        # не потрібне взагалі.
        $freshRoot = Join-Path $retentionStatusTestRoot 'nothing-expired'
        [void](New-BRAVORetentionComponentFixture -Root $freshRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        [void](New-BRAVORetentionComponentFixture -Root $freshRoot -GenerationId '20260930_230000' -StartedAt (Get-Date).AddDays(-1))
        [void](Invoke-BRAVORetentionFixtureCleanup -Root $freshRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $freshRoot))
        Test-BRAVOCondition `
            -Condition ($global:BRAVORetentionHashCalls -eq 0) `
            -Name "BackupConsistency/NoSha512WhenNothingIsExpired" `
            -Failure "без прострочених COMPLETE generation retention не повинен читати архіви для SHA512; викликів: $($global:BRAVORetentionHashCalls)"

        # Сценарій 3: сховище перенесено, manifest-и вказують на старий
        # корінь. Відновлення бачить архіви в канонічних каталогах — retention
        # має бачити їх так само: не видаляти manifest-и COMPLETE generation
        # при enableArchiveDeletion=$false і не лишати сиріт при $true.
        $relocatedRoot = Join-Path $retentionStatusTestRoot 'relocated'
        $relocatedOldRoot = Join-Path $retentionStatusTestRoot 'old-disk-that-no-longer-exists'
        $relocatedExpiredManifest = New-BRAVORetentionComponentFixture -Root $relocatedRoot `
            -GenerationId '20260301_230000' -StartedAt (Get-Date).AddDays(-200) -RecordedRoot $relocatedOldRoot
        $relocatedMidManifest = New-BRAVORetentionComponentFixture -Root $relocatedRoot `
            -GenerationId '20260815_230000' -StartedAt (Get-Date).AddDays(-47) -RecordedRoot $relocatedOldRoot
        [void](New-BRAVORetentionComponentFixture -Root $relocatedRoot -GenerationId '20260930_230000' `
            -StartedAt (Get-Date).AddDays(-1) -RecordedRoot $relocatedOldRoot)
        [void](New-BRAVORetentionComponentFixture -Root $relocatedRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $relocatedDefinitions = Get-BRAVORetentionFixtureDefinitions -Root $relocatedRoot
        $global:enableArchiveDeletion = $false
        $relocatedKeepOk = Invoke-BRAVORetentionFixtureCleanup -Root $relocatedRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions $relocatedDefinitions
        Test-BRAVOCondition `
            -Condition (
                $relocatedKeepOk -eq $true -and
                (Test-Path -LiteralPath $relocatedExpiredManifest) -and
                (Test-Path -LiteralPath $relocatedMidManifest)
            ) `
            -Name "BackupConsistency/RelocatedRepositoryKeepsCompleteManifests" `
            -Failure "після перенесення сховища manifest-и COMPLETE generation не повинні видалятися як невдалі лише тому, що записаний абсолютний шлях більше не існує"

        $global:enableArchiveDeletion = $true
        $relocatedDeleteOk = Invoke-BRAVORetentionFixtureCleanup -Root $relocatedRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions $relocatedDefinitions
        Test-BRAVOCondition `
            -Condition (
                $relocatedDeleteOk -eq $true -and
                -not (Test-Path -LiteralPath $relocatedExpiredManifest) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $relocatedRoot 'MODEL') 'MODEL_20260301_230000.mdz')) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $relocatedRoot 'BLOG') 'BLOG_20260301_230000.mdz.sha512')) -and
                (Test-Path -LiteralPath $relocatedMidManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $relocatedRoot 'MODEL') 'MODEL_20260930_230000.mdz'))
            ) `
            -Name "BackupConsistency/RelocatedRepositoryExpiryDeletesArchivesWithManifest" `
            -Failure "прострочена generation у перенесеному сховищі має видалятися разом з архівами з канонічних каталогів компонентів, а не лише manifest-ом (інакше архіви лишаються сиротами назавжди)"

        # Сценарій 4: заблокований файл посеред видалення однієї generation
        # (Remove-Item кидає на другому архіві). Архіви, що встигли видалитись,
        # зникли, manifest ЛИШАЄТЬСЯ, наступна generation обробляється,
        # прогін повертає $false; наступний прогін без блокування добиває.
        $global:enableArchiveDeletion = $false
        $lockRoot = Join-Path $retentionStatusTestRoot 'locked'
        $lockedManifest = New-BRAVORetentionComponentFixture -Root $lockRoot `
            -GenerationId '20260101_230000' -StartedAt (Get-Date).AddDays(-270) -Status 'FAILED'
        $lockLaterManifest = New-BRAVORetentionComponentFixture -Root $lockRoot `
            -GenerationId '20260201_230000' -StartedAt (Get-Date).AddDays(-240) -Status 'FAILED'
        [void](New-BRAVORetentionComponentFixture -Root $lockRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $lockedFile = Join-Path (Join-Path $lockRoot 'BLOG') 'BLOG_20260101_230000.mdz'
        $global:BRAVORetentionLockedPath = $lockedFile
        function global:Remove-Item {
            [CmdletBinding()]
            param([string]$LiteralPath, [string]$Path, [switch]$Force, [switch]$Recurse)
            $target = if ($LiteralPath) { $LiteralPath } else { $Path }
            if ($null -ne $global:BRAVORetentionLockedPath -and $target -eq $global:BRAVORetentionLockedPath) {
                throw 'The process cannot access the file because it is being used by another process.'
            }
            Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
        }
        $lockedRunOk = $null
        $lockedRunLogged = $false
        try {
            $lockedRunOk = Invoke-BRAVORetentionFixtureCleanup -Root $lockRoot `
                -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $lockRoot)
            $lockedRunLogged = Test-BRAVORetentionLogged -Level 'ERROR' -Pattern 'Не вдалося видалити backup generation 20260101_230000'
        } finally {
            $global:BRAVORetentionLockedPath = $null
            Microsoft.PowerShell.Management\Remove-Item -Path Function:\Remove-Item -ErrorAction SilentlyContinue
        }
        $lockedManifestSurvived = Test-Path -LiteralPath $lockedManifest
        $lockedFileSurvived = Test-Path -LiteralPath $lockedFile
        $lockedFirstArtifactGone = -not (Test-Path -LiteralPath (Join-Path (Join-Path $lockRoot 'MODEL') 'MODEL_20260101_230000.mdz'))
        Test-BRAVOCondition `
            -Condition (
                $lockedRunOk -eq $false -and
                $lockedRunLogged -and
                $lockedManifestSurvived -and
                $lockedFileSurvived -and
                -not (Test-Path -LiteralPath $lockLaterManifest) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $lockRoot 'MODEL') 'MODEL_20260201_230000.mdz'))
            ) `
            -Name "BackupConsistency/RetentionFailureOnOneGenerationDoesNotStopOthers" `
            -Failure "заблокований файл у однієї generation має давати ERROR, повернення `$false і НЕ зупиняти прибирання наступних прострочених generation (manifest-залишився=$lockedManifestSurvived, лог=$lockedRunLogged, результат=$lockedRunOk)"
        Test-BRAVOCondition `
            -Condition ($lockedManifestSurvived -and $lockedFileSurvived -and $lockedFirstArtifactGone) `
            -Name "BackupConsistency/ManifestIsDeletedOnlyAfterItsArtifacts" `
            -Failure "manifest generation, чиє видалення архівів не завершилось, має лишитися (інакше недовидалені архіви стають сиротами); manifest=$lockedManifestSurvived, заблокований файл=$lockedFileSurvived"
        $lockedRetryOk = Invoke-BRAVORetentionFixtureCleanup -Root $lockRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $lockRoot)
        Test-BRAVOCondition `
            -Condition (
                $lockedRetryOk -eq $true -and
                -not (Test-Path -LiteralPath $lockedManifest) -and
                -not (Test-Path -LiteralPath $lockedFile)
            ) `
            -Name "BackupConsistency/RetentionRetryFinishesGenerationAfterLockReleased" `
            -Failure "після зняття блокування наступний прогін має добити generation, чий manifest лишився (архіви і manifest видалено)"

        # Сценарій 5: архіви без manifest-а лише рахуються і ніколи не
        # видаляються (навіть при enableArchiveDeletion=$true і старі).
        # Обідні `_HHMM` копії у тих самих каталогах не рахуються сиротами.
        $global:enableArchiveDeletion = $true
        $orphanReportRoot = Join-Path $retentionStatusTestRoot 'orphan-report'
        [void](New-BRAVORetentionComponentFixture -Root $orphanReportRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $legacyArchive = Join-Path (Join-Path $orphanReportRoot 'MODEL') 'MODEL_legacy_20250101.mdz'
        [IO.File]::WriteAllText($legacyArchive, 'legacy payload')
        (Get-Item -LiteralPath $legacyArchive).LastWriteTime = (Get-Date).AddDays(-900)
        $lunchCopy = Join-Path (Join-Path $orphanReportRoot 'MODEL') 'MODEL_20260930_1300.mdz'
        [IO.File]::WriteAllText($lunchCopy, 'lunch payload')
        $orphanDefinitions = Get-BRAVORetentionFixtureDefinitions -Root $orphanReportRoot
        $orphanReportOk = Invoke-BRAVORetentionFixtureCleanup -Root $orphanReportRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions $orphanDefinitions
        $orphanAuditLogged = Test-BRAVORetentionLogged -Level 'INFO' -Pattern 'Архівів без generation manifest-а: 1 '
        Test-BRAVOCondition `
            -Condition (
                $orphanReportOk -eq $true -and
                $orphanAuditLogged -and
                (Test-Path -LiteralPath $legacyArchive) -and
                (Test-Path -LiteralPath $lunchCopy)
            ) `
            -Name "BackupConsistency/UnreferencedArchivesAreReportedNotDeleted" `
            -Failure "архів без generation manifest-а має потрапляти у звіт retention (рівно 1; обідня _HHMM копія не рахується) і ніколи не видалятися автоматично; звіт=$orphanAuditLogged"

        # Сценарій 6: manifest містить тип компонента, якого немає в
        # поточних ArchiveDefinitions. Generation лишається (як COMPLETE,
        # так і невдала), WARNING називає тип. Без цього перенесене сховище
        # втратило б manifest разом із невідомими архівами.
        $unknownRoot = Join-Path $retentionStatusTestRoot 'unknown-type'
        $unknownOldRoot = Join-Path $retentionStatusTestRoot 'unknown-old-disk'
        $unknownCompleteManifest = New-BRAVORetentionComponentFixture -Root $unknownRoot `
            -GenerationId '20250101_230000' -StartedAt (Get-Date).AddDays(-640) `
            -Components @('MODEL', 'BRAVOEXCH') -RecordedRoot $unknownOldRoot
        $unknownFailedManifest = New-BRAVORetentionComponentFixture -Root $unknownRoot `
            -GenerationId '20250201_230000' -StartedAt (Get-Date).AddDays(-600) -Status 'FAILED' `
            -Components @('MODEL', 'BRAVOEXCH') -RecordedRoot $unknownOldRoot
        [void](New-BRAVORetentionComponentFixture -Root $unknownRoot -GenerationId '20261001_230000' -StartedAt (Get-Date) -Components @('MODEL'))
        $unknownOk = Invoke-BRAVORetentionFixtureCleanup -Root $unknownRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions @(@{ Type = 'MODEL'; Destination = (Join-Path $unknownRoot 'MODEL'); NameTemplate = '{0}_{1}.mdz' })
        Test-BRAVOCondition `
            -Condition (
                $unknownOk -eq $true -and
                (Test-Path -LiteralPath $unknownCompleteManifest) -and
                (Test-Path -LiteralPath $unknownFailedManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $unknownRoot 'BRAVOEXCH') 'BRAVOEXCH_20250101_230000.mdz')) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $unknownRoot 'MODEL') 'MODEL_20250101_230000.mdz')) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'BRAVOEXCH')
            ) `
            -Name "BackupConsistency/UnknownComponentTypeKeepsGenerationAndWarns" `
            -Failure "generation з типом компонента, відсутнім в ArchiveDefinitions, не повинна ні видалятися, ні мовчки випадати з retention: manifest і архіви мають лишитися, а WARNING називати тип"

        # Сценарій 7 (рев'ю #344): перебудова шляхів fail-closed.
        # 7a: прострочений FAILED manifest у перенесеному сховищі посилається
        # на ім'я ІНШОЇ (поточної) generation. Перебудова дала б канонічний
        # шлях чужого архіву, і retention видалив би його в обхід поточної
        # та захищених. Identity gate за NameTemplate має це зупинити.
        $global:enableArchiveDeletion = $false
        $identityRoot = Join-Path $retentionStatusTestRoot 'identity'
        $identityOldRoot = Join-Path $retentionStatusTestRoot 'identity-old-disk'
        [void](New-BRAVORetentionComponentFixture -Root $identityRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $foreignNameManifest = New-BRAVORetentionComponentFixture -Root $identityRoot `
            -GenerationId '20250301_230000' -StartedAt (Get-Date).AddDays(-580) -Status 'FAILED' -RecordedRoot $identityOldRoot
        [IO.File]::WriteAllText($foreignNameManifest, (
            [IO.File]::ReadAllText($foreignNameManifest).Replace('MODEL_20250301_230000.mdz', 'MODEL_20261001_230000.mdz')
        ))
        $identityOk = Invoke-BRAVORetentionFixtureCleanup -Root $identityRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $identityRoot)
        Test-BRAVOCondition `
            -Condition (
                $identityOk -eq $true -and
                (Test-Path -LiteralPath $foreignNameManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $identityRoot 'MODEL') 'MODEL_20261001_230000.mdz')) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $identityRoot 'MODEL') 'MODEL_20261001_230000.mdz.sha512')) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'не належить generation 20250301_230000')
            ) `
            -Name "BackupConsistency/RelocatedForeignGenerationNameIsNotDeleted" `
            -Failure "manifest, що після перенесення сховища посилається на ім'я архіву іншої generation, не повинен призводити до видалення чужого архіву: generation лишається з WARNING"

        # 7b: файл ще лежить лише за старим записаним шляхом (поза новим
        # BackupRoot). Видалення manifest-а осиротило б його.
        $staleRoot = Join-Path $retentionStatusTestRoot 'stale-path'
        $staleOldRoot = Join-Path $retentionStatusTestRoot 'stale-old-disk'
        [void](New-BRAVORetentionComponentFixture -Root $staleRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $staleManifest = New-BRAVORetentionComponentFixture -Root $staleRoot `
            -GenerationId '20250401_230000' -StartedAt (Get-Date).AddDays(-550) -Status 'FAILED' -RecordedRoot $staleOldRoot
        $staleOldModelDirectory = Join-Path $staleOldRoot 'MODEL'
        [void][IO.Directory]::CreateDirectory($staleOldModelDirectory)
        $staleCanonicalArchive = Join-Path (Join-Path $staleRoot 'MODEL') 'MODEL_20250401_230000.mdz'
        $staleOldArchive = Join-Path $staleOldModelDirectory 'MODEL_20250401_230000.mdz'
        Microsoft.PowerShell.Management\Move-Item -LiteralPath $staleCanonicalArchive -Destination $staleOldArchive
        $staleOk = Invoke-BRAVORetentionFixtureCleanup -Root $staleRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $staleRoot)
        Test-BRAVOCondition `
            -Condition (
                $staleOk -eq $true -and
                (Test-Path -LiteralPath $staleManifest) -and
                (Test-Path -LiteralPath $staleOldArchive) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'поза BackupRoot')
            ) `
            -Name "BackupConsistency/RelocatedArtifactOnlyAtOldPathKeepsManifest" `
            -Failure "якщо файл generation лежить лише за старим записаним шляхом поза BackupRoot, manifest не повинен видалятися: generation лишається з WARNING"

        # 7c: канонічний каталог компонента недоступний (перенесення ще
        # триває). Відсутній там файл не доводить, що його вже видалено.
        $offlineRoot = Join-Path $retentionStatusTestRoot 'offline-destination'
        $offlineOldRoot = Join-Path $retentionStatusTestRoot 'offline-old-disk'
        [void](New-BRAVORetentionComponentFixture -Root $offlineRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $offlineManifest = New-BRAVORetentionComponentFixture -Root $offlineRoot `
            -GenerationId '20250501_230000' -StartedAt (Get-Date).AddDays(-520) -Status 'FAILED' -RecordedRoot $offlineOldRoot
        $offlineDefinitions = @(
            @{ Type = 'MODEL'; Destination = (Join-Path $offlineRoot 'MODEL'); NameTemplate = '{0}_{1}.mdz' },
            @{ Type = 'BLOG'; Destination = (Join-Path $offlineRoot 'BLOG-NOT-MOUNTED'); NameTemplate = '{0}_{1}.mdz' }
        )
        $offlineOk = Invoke-BRAVORetentionFixtureCleanup -Root $offlineRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions $offlineDefinitions
        Test-BRAVOCondition `
            -Condition (
                $offlineOk -eq $true -and
                (Test-Path -LiteralPath $offlineManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $offlineRoot 'MODEL') 'MODEL_20250501_230000.mdz')) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'каталог компонента недоступний')
            ) `
            -Name "BackupConsistency/RelocatedUnavailableDestinationKeepsGeneration" `
            -Failure "якщо канонічний каталог компонента недоступний, generation не повинна видалятися (ні архіви, ні manifest): лише WARNING"

        # 7d: метадані архіву не читаються (файл зник після Test-Path, ACL).
        # Це проблема однієї generation: WARNING для неї, решта обробляється.
        $metadataRoot = Join-Path $retentionStatusTestRoot 'metadata'
        [void](New-BRAVORetentionComponentFixture -Root $metadataRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $unreadableManifest = New-BRAVORetentionComponentFixture -Root $metadataRoot `
            -GenerationId '20260815_230000' -StartedAt (Get-Date).AddDays(-47)
        $metadataFailedManifest = New-BRAVORetentionComponentFixture -Root $metadataRoot `
            -GenerationId '20250601_230000' -StartedAt (Get-Date).AddDays(-480) -Status 'FAILED'
        $global:BRAVORetentionUnreadablePath = Join-Path (Join-Path $metadataRoot 'MODEL') 'MODEL_20260815_230000.mdz'
        function global:New-Object {
            param(
                [Parameter(Position = 0)][string]$TypeName,
                [Parameter(Position = 1)][object[]]$ArgumentList,
                [System.Collections.IDictionary]$Property,
                [switch]$Strict
            )
            if ($TypeName -eq 'System.IO.FileInfo' -and @($ArgumentList).Count -gt 0 -and
                [string]$ArgumentList[0] -eq $global:BRAVORetentionUnreadablePath) {
                throw 'Access to the path is denied.'
            }
            Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
        }
        $metadataOk = $null
        try {
            $metadataOk = Invoke-BRAVORetentionFixtureCleanup -Root $metadataRoot `
                -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $metadataRoot)
        } finally {
            $global:BRAVORetentionUnreadablePath = $null
            Microsoft.PowerShell.Management\Remove-Item -Path Function:\New-Object -ErrorAction SilentlyContinue
        }
        Test-BRAVOCondition `
            -Condition (
                $metadataOk -eq $true -and
                (Test-Path -LiteralPath $unreadableManifest) -and
                -not (Test-Path -LiteralPath $metadataFailedManifest) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'метадані архіву не прочитано')
            ) `
            -Name "BackupConsistency/UnreadableArchiveMetadataIsIsolatedPerGeneration" `
            -Failure "збій читання метаданих архіву однієї generation має давати WARNING лише для неї; прострочена невдала generation має видалятися в тому ж прогоні"

        # 7e (5.2.5-rc.7): транзієнтна помилка читання ПРОСТРОЧЕНОЇ цілої
        # COMPLETE при нестачі захищених. Перевірених копій менше за
        # minimumRetainedVerifiedBackups (лише поточна), тож неперевірена
        # прострочена COMPLETE може бути останньою цілою копією: retention її
        # не видаляє навіть при enableArchiveDeletion=$true і
        # enableFailedArchiveDeletion=$false (WARNING лишається).
        $savedEnableArchiveDeletion = $global:enableArchiveDeletion
        $savedEnableFailedArchiveDeletion = $global:enableFailedArchiveDeletion
        $global:enableArchiveDeletion = $true
        $global:enableFailedArchiveDeletion = $false
        $lastCopyRoot = Join-Path $retentionStatusTestRoot 'last-copy-ioerror'
        [void](New-BRAVORetentionComponentFixture -Root $lastCopyRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $lastCopyManifest = New-BRAVORetentionComponentFixture -Root $lastCopyRoot `
            -GenerationId '20260301_230000' -StartedAt (Get-Date).AddDays(-200)
        $global:BRAVORetentionUnreadablePath = Join-Path (Join-Path $lastCopyRoot 'MODEL') 'MODEL_20260301_230000.mdz'
        function global:New-Object {
            param(
                [Parameter(Position = 0)][string]$TypeName,
                [Parameter(Position = 1)][object[]]$ArgumentList,
                [System.Collections.IDictionary]$Property,
                [switch]$Strict
            )
            if ($TypeName -eq 'System.IO.FileInfo' -and @($ArgumentList).Count -gt 0 -and
                [string]$ArgumentList[0] -eq $global:BRAVORetentionUnreadablePath) {
                throw 'The process cannot access the file because it is being used by another process.'
            }
            Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
        }
        $lastCopyOk = $null
        try {
            $lastCopyOk = Invoke-BRAVORetentionFixtureCleanup -Root $lastCopyRoot `
                -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $lastCopyRoot)
        } finally {
            $global:BRAVORetentionUnreadablePath = $null
            Microsoft.PowerShell.Management\Remove-Item -Path Function:\New-Object -ErrorAction SilentlyContinue
            $global:enableArchiveDeletion = $savedEnableArchiveDeletion
            $global:enableFailedArchiveDeletion = $savedEnableFailedArchiveDeletion
        }
        Test-BRAVOCondition `
            -Condition (
                $lastCopyOk -eq $true -and
                (Test-Path -LiteralPath $lastCopyManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $lastCopyRoot 'MODEL') 'MODEL_20260301_230000.mdz')) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $lastCopyRoot 'BLOG') 'BLOG_20260301_230000.mdz')) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'метадані архіву не прочитано')
            ) `
            -Name "BackupConsistency/ExpiredUnverifiedCompleteKeptWhileProtectedBelowMinimum" `
            -Failure "прострочена COMPLETE generation, яку через транзієнтну помилку читання не вдалося перевірити, не повинна видалятися, поки перевірених копій менше за minimumRetainedVerifiedBackups (це може бути остання ціла копія)"

        # Сценарій 8 (L1/L2): час запуску невідомий або статус невідомий -
        # generation не видаляється, а LastWriteTime файлу видалення не
        # дозволяє. Усі виклики - під Set-StrictMode -Version 2.0, як у
        # production. 8a-8c: невідомий час (null, відсутній, нерозбірливий).
        $global:enableArchiveDeletion = $true
        $unknownTimeRoot = Join-Path $retentionStatusTestRoot 'unknown-time'
        [void](New-BRAVORetentionComponentFixture -Root $unknownTimeRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        [void](New-BRAVORetentionComponentFixture -Root $unknownTimeRoot -GenerationId '20260930_230000' -StartedAt (Get-Date).AddDays(-1))
        $nullTimeCompleteManifest = New-BRAVORetentionComponentFixture -Root $unknownTimeRoot `
            -GenerationId '20250101_230000' -StartedAt (Get-Date).AddDays(-640)
        Set-BRAVORetentionManifestStartedAt -ManifestPath $nullTimeCompleteManifest -JsonValue 'null' -LastWriteTime (Get-Date).AddDays(-640)
        $nullTimeFailedManifest = New-BRAVORetentionComponentFixture -Root $unknownTimeRoot `
            -GenerationId '20250102_230000' -StartedAt (Get-Date).AddDays(-639) -Status 'FAILED'
        Set-BRAVORetentionManifestStartedAt -ManifestPath $nullTimeFailedManifest -JsonValue 'null' -LastWriteTime (Get-Date).AddDays(-639)
        $badTimeCompleteManifest = New-BRAVORetentionComponentFixture -Root $unknownTimeRoot `
            -GenerationId '20250103_230000' -StartedAt (Get-Date).AddDays(-638)
        Set-BRAVORetentionManifestStartedAt -ManifestPath $badTimeCompleteManifest -JsonValue '"not-a-date"' -LastWriteTime (Get-Date).AddDays(-638)
        $badTimeFailedManifest = New-BRAVORetentionComponentFixture -Root $unknownTimeRoot `
            -GenerationId '20250104_230000' -StartedAt (Get-Date).AddDays(-637) -Status 'INCOMPLETE'
        Set-BRAVORetentionManifestStartedAt -ManifestPath $badTimeFailedManifest -JsonValue '"not-a-date"' -LastWriteTime (Get-Date).AddDays(-637)
        $unknownTimeOk = Invoke-BRAVORetentionFixtureCleanup -Root $unknownTimeRoot -StrictMode `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $unknownTimeRoot)
        Test-BRAVOCondition `
            -Condition (
                $unknownTimeOk -eq $true -and
                (Test-Path -LiteralPath $nullTimeCompleteManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $unknownTimeRoot 'MODEL') 'MODEL_20250101_230000.mdz')) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Резервна копія 20250101_230000: час запуску')
            ) `
            -Name "BackupConsistency/CompleteWithNullStartedAtIsNeverDeletedAndWarns" `
            -Failure "COMPLETE generation з startedAt=null має невідомий час: вона не повинна видалятися гілкою віку (навіть при давньому LastWriteTime), а WARNING має називати generation; manifest збережено=$(Test-Path -LiteralPath $nullTimeCompleteManifest)"
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath $nullTimeFailedManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $unknownTimeRoot 'MODEL') 'MODEL_20250102_230000.mdz')) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Резервна копія 20250102_230000: час запуску')
            ) `
            -Name "BackupConsistency/FailedWithNullStartedAtIsNeverDeletedAndWarns" `
            -Failure "FAILED generation з startedAt=null має невідомий час: гілка failedArchiveRetentionDays не повинна її видаляти ([datetime]`$null = 0001-01-01), WARNING має називати generation"
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath $badTimeCompleteManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $unknownTimeRoot 'MODEL') 'MODEL_20250103_230000.mdz')) -and
                (Test-Path -LiteralPath $badTimeFailedManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $unknownTimeRoot 'MODEL') 'MODEL_20250104_230000.mdz')) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Резервна копія 20250103_230000: час запуску') -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Резервна копія 20250104_230000: час запуску')
            ) `
            -Name "BackupConsistency/UnparseableStartedAtIsNotDeletedByFileTime" `
            -Failure "нерозбірливий startedAt не повинен підміняться LastWriteTime файлу manifest-а для рішення про видалення (ні COMPLETE, ні невдала generation); WARNING має називати generation"

        # 8d-8e: невідомий статус (RUNNING, порожній) не потрапляє в гілку
        # невдалих, навіть коли startedAt давно за failedArchiveRetentionDays.
        $unknownStatusRoot = Join-Path $retentionStatusTestRoot 'unknown-status'
        [void](New-BRAVORetentionComponentFixture -Root $unknownStatusRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $runningStatusManifest = New-BRAVORetentionComponentFixture -Root $unknownStatusRoot `
            -GenerationId '20250201_230000' -StartedAt (Get-Date).AddDays(-61) -Status 'RUNNING'
        $emptyStatusManifest = New-BRAVORetentionComponentFixture -Root $unknownStatusRoot `
            -GenerationId '20250202_230000' -StartedAt (Get-Date).AddDays(-61) -Status ''
        $unknownStatusOk = Invoke-BRAVORetentionFixtureCleanup -Root $unknownStatusRoot -StrictMode `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $unknownStatusRoot)
        Test-BRAVOCondition `
            -Condition (
                $unknownStatusOk -eq $true -and
                (Test-Path -LiteralPath $runningStatusManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $unknownStatusRoot 'MODEL') 'MODEL_20250201_230000.mdz')) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Резервна копія 20250201_230000: невідомий статус')
            ) `
            -Name "BackupConsistency/RunningStatusOlderThanFailedRetentionIsKeptAndWarns" `
            -Failure "generation зі статусом RUNNING (не FAILED/INCOMPLETE/COMPLETE) не повинна видалятися гілкою failedArchiveRetentionDays, а WARNING має називати generation"
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath $emptyStatusManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $unknownStatusRoot 'MODEL') 'MODEL_20250202_230000.mdz')) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Резервна копія 20250202_230000: невідомий статус')
            ) `
            -Name "BackupConsistency/EmptyStatusIsKeptAndWarns" `
            -Failure "generation з порожнім статусом не повинна видалятися гілкою failedArchiveRetentionDays, а WARNING має називати generation"

        # 8f: контроль - FAILED і INCOMPLETE (будь-який регістр), старші за
        # failedArchiveRetentionDays, видаляються як і раніше.
        $knownFailedRoot = Join-Path $retentionStatusTestRoot 'known-failed'
        [void](New-BRAVORetentionComponentFixture -Root $knownFailedRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $knownFailedManifest = New-BRAVORetentionComponentFixture -Root $knownFailedRoot `
            -GenerationId '20250301_230000' -StartedAt (Get-Date).AddDays(-61) -Status 'FAILED'
        $knownIncompleteManifest = New-BRAVORetentionComponentFixture -Root $knownFailedRoot `
            -GenerationId '20250302_230000' -StartedAt (Get-Date).AddDays(-61) -Status 'incomplete'
        $knownFailedOk = Invoke-BRAVORetentionFixtureCleanup -Root $knownFailedRoot -StrictMode `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $knownFailedRoot)
        Test-BRAVOCondition `
            -Condition (
                $knownFailedOk -eq $true -and
                -not (Test-Path -LiteralPath $knownFailedManifest) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $knownFailedRoot 'MODEL') 'MODEL_20250301_230000.mdz')) -and
                -not (Test-Path -LiteralPath $knownIncompleteManifest) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $knownFailedRoot 'MODEL') 'MODEL_20250302_230000.mdz'))
            ) `
            -Name "BackupConsistency/KnownFailedAndIncompleteStatusesStillExpire" `
            -Failure "generation зі статусом FAILED або INCOMPLETE (без урахування регістру) з відомим startedAt, старшим за failedArchiveRetentionDays, має видалятися як і раніше; ERROR у лозі retention: $(@($global:BRAVORetentionTestLog | Where-Object { $_.StartsWith('ERROR|') }) -join ' / ')"

        # 8g: COMPLETE з невідомим часом не займає місце серед N захищених
        # (сортується останньою, тож це насамперед перевірка, що вона не
        # видаляється і не витісняє цілу копію)
        # (minimumRetainedVerifiedBackups=2): прострочена, але захищена ціла
        # generation лишається, а сама копія з невідомим часом не видаляється.
        $protectedRoot = Join-Path $retentionStatusTestRoot 'null-time-protected'
        [void](New-BRAVORetentionComponentFixture -Root $protectedRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $protectedValidManifest = New-BRAVORetentionComponentFixture -Root $protectedRoot `
            -GenerationId '20250401_230000' -StartedAt (Get-Date).AddDays(-640)
        $protectedNullManifest = New-BRAVORetentionComponentFixture -Root $protectedRoot `
            -GenerationId '20250402_230000' -StartedAt (Get-Date).AddDays(-639)
        Set-BRAVORetentionManifestStartedAt -ManifestPath $protectedNullManifest -JsonValue 'null' -LastWriteTime (Get-Date).AddDays(-639)
        $protectedOk = Invoke-BRAVORetentionFixtureCleanup -Root $protectedRoot -StrictMode `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $protectedRoot)
        Test-BRAVOCondition `
            -Condition (
                $protectedOk -eq $true -and
                (Test-Path -LiteralPath $protectedValidManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $protectedRoot 'MODEL') 'MODEL_20250401_230000.mdz')) -and
                (Test-Path -LiteralPath $protectedNullManifest) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Резервна копія 20250402_230000: час запуску')
            ) `
            -Name "BackupConsistency/NullStartedAtCompleteDoesNotDisplaceProtectedGeneration" `
            -Failure "COMPLETE з невідомим часом не повинна брати участі у виборі N захищених: валідна прострочена generation, що входить у N найновіших, має лишитися, а копія з невідомим часом - не видалятися"

        # 8h: контроль - startedAt як НЕекранований рядок "/Date(ms)/"
        # (ConvertFrom-Json лишає його рядком, тож працює розбір у retention)
        # лишається відомим часом: прострочена незахищена COMPLETE generation
        # видаляється як і раніше.
        $epochRoot = Join-Path $retentionStatusTestRoot 'epoch-time'
        [void](New-BRAVORetentionComponentFixture -Root $epochRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        [void](New-BRAVORetentionComponentFixture -Root $epochRoot -GenerationId '20260930_230000' -StartedAt (Get-Date).AddDays(-1))
        $epochManifest = New-BRAVORetentionComponentFixture -Root $epochRoot `
            -GenerationId '20250501_230000' -StartedAt (Get-Date).AddDays(-640)
        $epochStart = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        $epochMilliseconds = [long]((Get-Date).AddDays(-640).ToUniversalTime() - $epochStart).TotalMilliseconds
        Set-BRAVORetentionManifestStartedAt -ManifestPath $epochManifest -JsonValue ('"/Date(' + $epochMilliseconds + ')/"') -LastWriteTime (Get-Date)
        $epochOk = Invoke-BRAVORetentionFixtureCleanup -Root $epochRoot -StrictMode `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $epochRoot)
        Test-BRAVOCondition `
            -Condition (
                $epochOk -eq $true -and
                -not (Test-Path -LiteralPath $epochManifest) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $epochRoot 'MODEL') 'MODEL_20250501_230000.mdz')) -and
                -not (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Резервна копія 20250501_230000: час запуску')
            ) `
            -Name "BackupConsistency/EpochStartedAtStillExpiresByAge" `
            -Failure "startedAt як рядок /Date(ms)/ має розбиратися як відомий час: прострочена незахищена COMPLETE generation видаляється; manifest збережено=$(Test-Path -LiteralPath $epochManifest); ERROR у лозі retention: $(@($global:BRAVORetentionTestLog | Where-Object { $_.StartsWith('ERROR|') }) -join ' / ')"

        # 8i: наскрізно - startedAt як [datetime], серіалізований ConvertTo-Json,
        # як це робить writer generation manifest-а (у Windows PowerShell 5.1 це
        # "\/Date(ms)\/", який ConvertFrom-Json повертає як [datetime] з
        # Kind=Utc - основний production-формат): час відомий, прострочена
        # незахищена COMPLETE generation видаляється як і раніше.
        $roundTripRoot = Join-Path $retentionStatusTestRoot 'round-trip-time'
        [void](New-BRAVORetentionComponentFixture -Root $roundTripRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        [void](New-BRAVORetentionComponentFixture -Root $roundTripRoot -GenerationId '20260930_230000' -StartedAt (Get-Date).AddDays(-1))
        $roundTripManifest = New-BRAVORetentionComponentFixture -Root $roundTripRoot `
            -GenerationId '20250601_230000' -StartedAt (Get-Date).AddDays(-640)
        $roundTripJson = ([ordered]@{ startedAt = [datetime]::Now.AddDays(-640) } | ConvertTo-Json -Compress)
        $roundTripValue = [regex]::Match($roundTripJson, '^\{"startedAt":(.+)\}$').Groups[1].Value
        if ([string]::IsNullOrEmpty($roundTripValue)) { throw "ConvertTo-Json дав неочікуваний формат: $roundTripJson" }
        Set-BRAVORetentionManifestStartedAt -ManifestPath $roundTripManifest -JsonValue $roundTripValue -LastWriteTime (Get-Date)
        $roundTripOk = Invoke-BRAVORetentionFixtureCleanup -Root $roundTripRoot -StrictMode `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $roundTripRoot)
        Test-BRAVOCondition `
            -Condition (
                $roundTripOk -eq $true -and
                -not (Test-Path -LiteralPath $roundTripManifest) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $roundTripRoot 'MODEL') 'MODEL_20250601_230000.mdz')) -and
                -not (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Резервна копія 20250601_230000: час запуску')
            ) `
            -Name "BackupConsistency/ConvertToJsonStartedAtRoundTripStillExpiresByAge" `
            -Failure "startedAt, серіалізований ConvertTo-Json, як у writer manifest-а ($roundTripValue), має лишатися відомим часом: прострочена незахищена COMPLETE generation видаляється; manifest збережено=$(Test-Path -LiteralPath $roundTripManifest); ERROR у лозі retention: $(@($global:BRAVORetentionTestLog | Where-Object { $_.StartsWith('ERROR|') }) -join ' / ')"
        # 8j: нульова дата (0001-01-01 - так ConvertTo-Json пише незаданий
        # [datetime]: "\/Date(-62135596800000)\/", або рядок з Z) - це
        # невідомий час, а не "найстаріша копія", у будь-якому часовому поясі.
        # Східніше UTC перехід у локальний час давав би 0001-01-01 + зсув,
        # що вже більше за MinValue.
        $zeroTimeRoot = Join-Path $retentionStatusTestRoot 'zero-time'
        [void](New-BRAVORetentionComponentFixture -Root $zeroTimeRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        [void](New-BRAVORetentionComponentFixture -Root $zeroTimeRoot -GenerationId '20260930_230000' -StartedAt (Get-Date).AddDays(-1))
        $zeroEpochManifest = New-BRAVORetentionComponentFixture -Root $zeroTimeRoot `
            -GenerationId '20250701_230000' -StartedAt (Get-Date).AddDays(-640)
        Set-BRAVORetentionManifestStartedAt -ManifestPath $zeroEpochManifest -JsonValue '"\/Date(-62135596800000)\/"' -LastWriteTime (Get-Date).AddDays(-640)
        $zeroIsoManifest = New-BRAVORetentionComponentFixture -Root $zeroTimeRoot `
            -GenerationId '20250702_230000' -StartedAt (Get-Date).AddDays(-640)
        Set-BRAVORetentionManifestStartedAt -ManifestPath $zeroIsoManifest -JsonValue '"0001-01-01T00:00:00Z"' -LastWriteTime (Get-Date).AddDays(-640)
        # Без поясу (Kind=Unspecified, не конвертується): ловить регресію і в UTC.
        $zeroLocalManifest = New-BRAVORetentionComponentFixture -Root $zeroTimeRoot `
            -GenerationId '20250703_230000' -StartedAt (Get-Date).AddDays(-640)
        Set-BRAVORetentionManifestStartedAt -ManifestPath $zeroLocalManifest -JsonValue '"0001-01-01T05:00:00"' -LastWriteTime (Get-Date).AddDays(-640)
        $zeroTimeOk = Invoke-BRAVORetentionFixtureCleanup -Root $zeroTimeRoot -StrictMode `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $zeroTimeRoot)
        Test-BRAVOCondition `
            -Condition (
                $zeroTimeOk -eq $true -and
                (Test-Path -LiteralPath $zeroEpochManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $zeroTimeRoot 'MODEL') 'MODEL_20250701_230000.mdz')) -and
                (Test-Path -LiteralPath $zeroIsoManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $zeroTimeRoot 'MODEL') 'MODEL_20250702_230000.mdz')) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Резервна копія 20250701_230000: час запуску') -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Резервна копія 20250702_230000: час запуску') -and
                (Test-Path -LiteralPath $zeroLocalManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $zeroTimeRoot 'MODEL') 'MODEL_20250703_230000.mdz')) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Резервна копія 20250703_230000: час запуску')
            ) `
            -Name "BackupConsistency/ZeroDateStartedAtIsUnknownInAnyTimeZone" `
            -Failure "startedAt з датою 0001-01-01 (незаданий [datetime] з ConvertTo-Json, рядок з Z чи без поясу) має бути невідомим часом: generation не видаляється, WARNING називає її; часовий пояс: $([TimeZoneInfo]::Local.Id); ERROR у лозі retention: $(@($global:BRAVORetentionTestLog | Where-Object { $_.StartsWith('ERROR|') }) -join ' / ')"
        # --- #498: спостережуваність retention і доказ ледачого SHA512.
        # Ті самі реальні функції та заглушки; додатково фіксуються конкретні
        # шляхи, які читав SHA512 ($global:BRAVORetentionHashPaths), щоб
        # довести, що перевіряються лише потрібні generation, а не весь репозиторій.
        function Get-BRAVORetentionGenerationPaths {
            param([string]$Root, [string[]]$GenerationIds, [string[]]$Components = @('MODEL', 'BLOG'))
            $paths = @()
            foreach ($generationId in $GenerationIds) {
                foreach ($component in $Components) {
                    $paths += (Join-Path (Join-Path $Root $component) ("{0}_{1}.mdz" -f $component, $generationId))
                }
            }
            return $paths
        }

        function Get-BRAVORetentionPathKey {
            param([string[]]$Paths)
            return ((@($Paths | ForEach-Object { ([string]$_).ToLowerInvariant() }) | Sort-Object) -join '|')
        }

        function Get-BRAVORetentionHashedPathKey {
            return (Get-BRAVORetentionPathKey -Paths @($global:BRAVORetentionHashPaths))
        }

        function Get-BRAVORetentionPathsLength {
            param([string[]]$Paths)
            [long]$total = 0
            foreach ($path in $Paths) { $total += (Get-Item -LiteralPath $path).Length }
            return $total
        }

        function Get-BRAVORetentionLogMessages {
            param([string]$Pattern, [string]$Level = 'INFO')
            return @($global:BRAVORetentionTestLog | Where-Object {
                $_.StartsWith($Level + '|') -and $_.Contains($Pattern)
            } | ForEach-Object { $_.Substring($Level.Length + 1) })
        }

        function Get-BRAVORetentionLogIndex {
            param([string]$Pattern, [string]$Level = 'INFO')
            for ($i = 0; $i -lt $global:BRAVORetentionTestLog.Count; $i++) {
                $entry = [string]$global:BRAVORetentionTestLog[$i]
                if ($entry.StartsWith($Level + '|') -and $entry.Contains($Pattern)) { return $i }
            }
            return -1
        }

        function Get-BRAVORetentionAuditLine {
            return (@(Get-BRAVORetentionLogMessages -Pattern 'Аудит retention:') | Select-Object -First 1)
        }

        # Повертає порожній рядок, якщо лог і підсумковий аудит містять усі
        # поля #498 у правильному порядку; інакше - опис розбіжностей.
        function Get-BRAVORetentionTelemetryProblems {
            param([string]$Root, [int]$ExpectedAttempts, [long]$ExpectedBytes)
            $problems = @()
            $startMarker = "Retention: старт аудиту generation у $Root (archiveRetentionDays=183; failedArchiveRetentionDays=30)"
            if ($global:BRAVORetentionTestLog.Count -lt 1 -or
                -not ([string]$global:BRAVORetentionTestLog[0]).Equals('INFO|' + $startMarker)) {
                $problems += "перший запис логу не є рядком старту (перший: $(@($global:BRAVORetentionTestLog)[0]))"
            }
            $inventoryIndex = Get-BRAVORetentionLogIndex -Pattern 'Retention: інвентаризація — generation='
            $firstFullCheckIndex = Get-BRAVORetentionLogIndex -Pattern 'Retention: повна перевірка SHA512 generation'
            if ($inventoryIndex -lt 1) { $problems += "немає рядка інвентаризації після старту (індекс $inventoryIndex)" }
            if ($ExpectedAttempts -gt 0 -and ($firstFullCheckIndex -lt 0 -or $inventoryIndex -ge $firstFullCheckIndex)) {
                $problems += "інвентаризація має передувати першій повній перевірці (інвентаризація=$inventoryIndex, перевірка=$firstFullCheckIndex)"
            }
            $inventoryLine = @(Get-BRAVORetentionLogMessages -Pattern 'Retention: інвентаризація —') | Select-Object -First 1
            if ($null -eq $inventoryLine -or $inventoryLine -notmatch 'минуло [0-9]+\.[0-9] с$') {
                $problems += "рядок інвентаризації без тривалості 'минуло X.X с': $inventoryLine"
            }
            $attemptLines = @(Get-BRAVORetentionLogMessages -Pattern 'Retention: повна перевірка SHA512 generation')
            if ($attemptLines.Count -ne $ExpectedAttempts) {
                $problems += "рядків 'повна перевірка' $($attemptLines.Count), очікувано $ExpectedAttempts"
            }
            foreach ($attemptLine in $attemptLines) {
                if ($attemptLine -notmatch '\(спроба [0-9]+; verified знайдено [0-9]+/2; логічний обсяг архівів [0-9]+\.[0-9] МБ\)$') {
                    $problems += "формат рядка повної перевірки: $attemptLine"
                }
            }
            $audit = Get-BRAVORetentionAuditLine
            if ([string]::IsNullOrEmpty($audit)) {
                $problems += 'немає підсумкового рядка Аудит retention'
                return ($problems -join '; ')
            }
            $orderedFields = @(
                'generation оцінено=', 'захищено (verified)=', 'видалено (COMPLETE, прострочено)=',
                'видалено (failed/incomplete, прострочено)=', 'помилок видалення=', 'архівів без manifest-а=',
                "перевірено SHA512 (generation)=$ExpectedAttempts;", 'логічний обсяг перевірених архівів=',
                "($ExpectedBytes байт)", 'тривалість SHA512=', 'тривалість retention='
            )
            $position = -1
            foreach ($field in $orderedFields) {
                $found = $audit.IndexOf($field, [StringComparison]::Ordinal)
                if ($found -le $position) { $problems += "поле '$field' відсутнє або не в порядку в аудиті"; break }
                $position = $found
            }
            if ($audit -notmatch 'логічний обсяг перевірених архівів=[0-9]+\.[0-9]{2} ГБ \(') { $problems += 'обсяг у ГБ не у форматі 0.00' }
            if ($audit -notmatch 'тривалість SHA512=[0-9]+\.[0-9] с;') { $problems += 'тривалість SHA512 не парситься' }
            if ($audit -notmatch 'тривалість retention=[0-9]+\.[0-9] с$') { $problems += 'тривалість retention не парситься' }
            return ($problems -join '; ')
        }

        # A: свіжі generation (усі молодші за 183 дні) - SHA512 не потрібен.
        $global:enableArchiveDeletion = $true
        foreach ($freshCount in @(105, 366)) {
            $freshSetRoot = Join-Path $retentionStatusTestRoot ("fresh-{0}" -f $freshCount)
            $freshNow = Get-Date
            $freshCurrentId = $null
            for ($freshIndex = 0; $freshIndex -lt $freshCount; $freshIndex++) {
                $freshStarted = $freshNow.AddHours(-11 * $freshIndex)
                $freshId = $freshStarted.ToString('yyyyMMdd_HHmmss')
                if ($freshIndex -eq 0) { $freshCurrentId = $freshId }
                [void](New-BRAVORetentionComponentFixture -Root $freshSetRoot -GenerationId $freshId -StartedAt $freshStarted)
            }
            $freshWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $freshOk = Invoke-BRAVORetentionFixtureCleanup -Root $freshSetRoot `
                -CurrentGenerationId $freshCurrentId -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $freshSetRoot)
            $freshWatch.Stop()
            $freshSeconds = $freshWatch.Elapsed.TotalSeconds.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
            $freshManifestCount = @(Get-ChildItem -LiteralPath (Join-Path $freshSetRoot 'MANIFESTS') -Filter '*.json' -File).Count
            $freshModelCount = @(Get-ChildItem -LiteralPath (Join-Path $freshSetRoot 'MODEL') -Filter '*.mdz' -File).Count
            $freshBlogCount = @(Get-ChildItem -LiteralPath (Join-Path $freshSetRoot 'BLOG') -Filter '*.mdz' -File).Count
            $freshInventory = @(Get-BRAVORetentionLogMessages -Pattern 'Retention: інвентаризація —') | Select-Object -First 1
            Test-BRAVOCondition `
                -Condition (
                    $freshOk -eq $true -and
                    $global:BRAVORetentionHashCalls -eq 0 -and
                    @($global:BRAVORetentionHashPaths).Count -eq 0 -and
                    $freshManifestCount -eq $freshCount -and
                    $freshModelCount -eq $freshCount -and
                    $freshBlogCount -eq $freshCount
                ) `
                -Name ("BackupConsistency/FreshRepository{0}GenerationsNeitherHashedNorDeleted" -f $freshCount) `
                -Failure "$freshCount свіжих COMPLETE generation (усі молодші за 183 дні) при enableArchiveDeletion=true: SHA512 не потрібен і нічого не видаляється (результат=$freshOk; викликів SHA512=$($global:BRAVORetentionHashCalls); шляхів=$(@($global:BRAVORetentionHashPaths).Count); manifest-ів=$freshManifestCount; MODEL=$freshModelCount; BLOG=$freshBlogCount; виміряно $freshSeconds с)"
            Test-BRAVOCondition `
                -Condition (
                    $null -ne $freshInventory -and
                    $freshInventory.Contains("generation=$freshCount (COMPLETE=$freshCount)") -and
                    $freshInventory.Contains('прострочено за віком (до захисту N): COMPLETE=0, failed/incomplete=0') -and
                    $freshInventory.Contains('видалення за віком: COMPLETE — увімкнено (enableArchiveDeletion), failed/incomplete — увімкнено (enableFailedArchiveDeletion)') -and
                    $freshInventory.Contains('фактично видалені — у підсумку «Аудит retention»') -and
                    $freshInventory.Contains('SHA512 не потрібен: немає COMPLETE, придатної до видалення за віком (archiveRetentionDays=183)')
                ) `
                -Name ("BackupConsistency/FreshRepository{0}InventoryExplainsNoSha512" -f $freshCount) `
                -Failure "рядок інвентаризації для $freshCount свіжих generation має містити generation=$freshCount, нуль прострочених, стан прапорців і причину «немає COMPLETE, придатної до видалення за віком»; фактично: $freshInventory (виміряно $freshSeconds с)"
        }

        # B: є прострочена COMPLETE, найновіші N=2 цілі - SHA512 читає лише їх.
        $global:enableArchiveDeletion = $true
        $lazyRoot = Join-Path $retentionStatusTestRoot 'lazy-sha512'
        $lazyNewest = '20261001_230000'
        $lazySecond = '20260930_230000'
        [void](New-BRAVORetentionComponentFixture -Root $lazyRoot -GenerationId $lazyNewest -StartedAt (Get-Date))
        [void](New-BRAVORetentionComponentFixture -Root $lazyRoot -GenerationId $lazySecond -StartedAt (Get-Date).AddDays(-1))
        [void](New-BRAVORetentionComponentFixture -Root $lazyRoot -GenerationId '20260801_230000' -StartedAt (Get-Date).AddDays(-50))
        [void](New-BRAVORetentionComponentFixture -Root $lazyRoot -GenerationId '20250601_230000' -StartedAt (Get-Date).AddDays(-380))
        $lazyExpiredManifest = New-BRAVORetentionComponentFixture -Root $lazyRoot `
            -GenerationId '20250101_230000' -StartedAt (Get-Date).AddDays(-640)
        $lazyExpected = Get-BRAVORetentionGenerationPaths -Root $lazyRoot -GenerationIds @($lazyNewest, $lazySecond)
        $lazyExpectedBytes = Get-BRAVORetentionPathsLength -Paths $lazyExpected
        $lazyOk = Invoke-BRAVORetentionFixtureCleanup -Root $lazyRoot `
            -CurrentGenerationId $lazyNewest -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $lazyRoot)
        $lazyHashedKey = Get-BRAVORetentionHashedPathKey
        Test-BRAVOCondition `
            -Condition (
                $lazyOk -eq $true -and
                $lazyHashedKey -ceq (Get-BRAVORetentionPathKey -Paths $lazyExpected) -and
                @($global:BRAVORetentionHashPaths).Count -eq 4 -and
                $global:BRAVORetentionHashCalls -eq 4
            ) `
            -Name "BackupConsistency/LazySha512ReadsOnlyNewestNGenerations" `
            -Failure "SHA512 має читати рівно 2 архіви x 2 найновіші generation (4 шляхи) і більше нічого; фактично викликів=$($global:BRAVORetentionHashCalls), шляхи: $(@($global:BRAVORetentionHashPaths) -join ' ; ')"
        Test-BRAVOCondition `
            -Condition (
                -not (Test-Path -LiteralPath $lazyExpiredManifest) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $lazyRoot 'MODEL') 'MODEL_20250101_230000.mdz')) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $lazyRoot 'MODEL') 'MODEL_20250601_230000.mdz')) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $lazyRoot 'MODEL') 'MODEL_20260801_230000.mdz')) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $lazyRoot 'MODEL') ("MODEL_{0}.mdz" -f $lazyNewest)))
            ) `
            -Name "BackupConsistency/LazySha512StillDeletesExpiredAndKeepsFresh" `
            -Failure "ледача перевірка не повинна змінити наслідок: прострочені незахищені COMPLETE видаляються, непрострочені та захищені лишаються"
        $lazyProblems = Get-BRAVORetentionTelemetryProblems -Root $lazyRoot -ExpectedAttempts 2 -ExpectedBytes $lazyExpectedBytes
        $lazyAudit = Get-BRAVORetentionAuditLine
        Test-BRAVOCondition `
            -Condition (
                $lazyProblems -eq '' -and
                $lazyAudit.Contains("захищено (verified)=2 [$lazyNewest, $lazySecond]") -and
                $lazyAudit.Contains('видалено (COMPLETE, прострочено)=2;') -and
                (Get-BRAVORetentionLogIndex -Pattern "повна перевірка SHA512 generation $lazyNewest (спроба 1; verified знайдено 0/2;") -ge 0 -and
                (Get-BRAVORetentionLogIndex -Pattern "generation $lazyNewest — SHA512 збігається, захищено 1/2; тривалість") -ge 0 -and
                (Get-BRAVORetentionLogIndex -Pattern "повна перевірка SHA512 generation $lazySecond (спроба 2; verified знайдено 1/2;") -ge 0 -and
                (Get-BRAVORetentionLogIndex -Pattern "generation $lazySecond — SHA512 збігається, захищено 2/2; тривалість") -ge 0 -and
                (Get-BRAVORetentionLogIndex -Pattern 'SHA512 потрібен: є прострочені COMPLETE; перевірка від найновіших, доки не знайдено 2 verified (придатних до перевірки: 5)') -ge 0
            ) `
            -Name "BackupConsistency/RetentionLogsStartInventoryAttemptsAndAuditCounters" `
            -Failure "лог retention має починатися рядком старту, далі інвентаризація, потім спроби SHA512, а підсумковий аудит - зберігати старі поля і дописати лічильники #498 (суму байтів=$lazyExpectedBytes); проблеми: $lazyProblems; лог: $(@($global:BRAVORetentionTestLog) -join ' / ')"

        # C: найновіша generation з прихованим пошкодженням (той самий розмір):
        # не рахується verified, пошук іде до старших цілих.
        $rotNewRoot = Join-Path $retentionStatusTestRoot 'bit-rot-newest'
        $rotNewG0 = '20261001_230000'
        $rotNewG1 = '20260930_230000'
        $rotNewG2 = '20260929_230000'
        $rotNewG3 = '20260928_230000'
        [void](New-BRAVORetentionComponentFixture -Root $rotNewRoot -GenerationId $rotNewG0 -StartedAt (Get-Date) -BitRotComponents @('MODEL'))
        [void](New-BRAVORetentionComponentFixture -Root $rotNewRoot -GenerationId $rotNewG1 -StartedAt (Get-Date).AddDays(-1))
        [void](New-BRAVORetentionComponentFixture -Root $rotNewRoot -GenerationId $rotNewG2 -StartedAt (Get-Date).AddDays(-2))
        [void](New-BRAVORetentionComponentFixture -Root $rotNewRoot -GenerationId $rotNewG3 -StartedAt (Get-Date).AddDays(-3))
        $rotNewExpiredManifest = New-BRAVORetentionComponentFixture -Root $rotNewRoot `
            -GenerationId '20250101_230000' -StartedAt (Get-Date).AddDays(-640)
        $rotNewExpected = @(Get-BRAVORetentionGenerationPaths -Root $rotNewRoot -GenerationIds @($rotNewG0) -Components @('MODEL')) +
            @(Get-BRAVORetentionGenerationPaths -Root $rotNewRoot -GenerationIds @($rotNewG1, $rotNewG2))
        $rotNewOk = Invoke-BRAVORetentionFixtureCleanup -Root $rotNewRoot `
            -CurrentGenerationId $rotNewG0 -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $rotNewRoot)
        $rotNewAudit = Get-BRAVORetentionAuditLine
        Test-BRAVOCondition `
            -Condition (
                $rotNewOk -eq $true -and
                (Get-BRAVORetentionHashedPathKey) -ceq (Get-BRAVORetentionPathKey -Paths $rotNewExpected) -and
                $global:BRAVORetentionHashCalls -eq 5 -and
                (Get-BRAVORetentionLogIndex -Pattern "повна перевірка SHA512 generation $rotNewG0 (спроба 1; verified знайдено 0/2;") -ge 0 -and
                (Get-BRAVORetentionLogIndex -Pattern "generation $rotNewG0 — перевірку SHA512 не пройдено; тривалість") -ge 0 -and
                (Get-BRAVORetentionLogIndex -Pattern "повна перевірка SHA512 generation $rotNewG1 (спроба 2; verified знайдено 0/2;") -ge 0 -and
                (Get-BRAVORetentionLogIndex -Pattern "повна перевірка SHA512 generation $rotNewG2 (спроба 3; verified знайдено 1/2;") -ge 0 -and
                (Get-BRAVORetentionLogIndex -Pattern 'спроба 4;') -lt 0 -and
                (Get-BRAVORetentionLogIndex -Pattern "Пошкоджена резервна копія ${rotNewG0}:" -Level 'WARNING') -ge 0
            ) `
            -Name "BackupConsistency/NewestBitRotIsNotVerifiedAndSearchContinuesToOlder" `
            -Failure "найновіша generation з тим самим розміром, але іншими байтами, не повинна рахуватися verified: очікувано 3 спроби і 5 шляхів SHA512 (MODEL найновішої + 2 старші цілі), фактично викликів=$($global:BRAVORetentionHashCalls); шляхи: $(@($global:BRAVORetentionHashPaths) -join ' ; ')"
        Test-BRAVOCondition `
            -Condition (
                $rotNewAudit.Contains("захищено (verified)=2 [$rotNewG1, $rotNewG2]") -and
                $rotNewAudit.Contains('пошкоджено (COMPLETE, не пройшли перевірку)=1;') -and
                -not (Test-Path -LiteralPath $rotNewExpiredManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $rotNewRoot 'MODEL') ("MODEL_{0}.mdz" -f $rotNewG0))) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $rotNewRoot 'MODEL') ("MODEL_{0}.mdz" -f $rotNewG3)))
            ) `
            -Name "BackupConsistency/NewestBitRotProtectsNextTwoHealthyAndKeepsCorrupt" `
            -Failure "захищеними мають стати дві наступні цілі generation ($rotNewG1, $rotNewG2), пошкоджена найновіша і непрострочена ціла лишаються, прострочена видаляється; аудит: $rotNewAudit"

        # D: цілих менше за N - пошук проходить усі придатні generation;
        # знайдена ціла, навіть прострочена, захищається і не видаляється.
        $fewRoot = Join-Path $retentionStatusTestRoot 'fewer-healthy'
        $fewG0 = '20261001_230000'
        $fewG1 = '20260930_230000'
        $fewSizeCorrupt = '20260926_230000'
        $fewExpiredHealthy = '20250301_230000'
        [void](New-BRAVORetentionComponentFixture -Root $fewRoot -GenerationId $fewG0 -StartedAt (Get-Date) -BitRotComponents @('MODEL'))
        [void](New-BRAVORetentionComponentFixture -Root $fewRoot -GenerationId $fewG1 -StartedAt (Get-Date).AddDays(-1) -BitRotComponents @('BLOG'))
        [void](New-BRAVORetentionComponentFixture -Root $fewRoot -GenerationId $fewSizeCorrupt `
            -StartedAt (Get-Date).AddDays(-5) -CorruptComponents @('BLOG'))
        $fewExpiredManifest = New-BRAVORetentionComponentFixture -Root $fewRoot `
            -GenerationId $fewExpiredHealthy -StartedAt (Get-Date).AddDays(-300)
        $fewExpected = Get-BRAVORetentionGenerationPaths -Root $fewRoot -GenerationIds @($fewG0, $fewG1, $fewExpiredHealthy)
        $fewExpectedBytes = Get-BRAVORetentionPathsLength -Paths $fewExpected
        # Hash-виклики: MODEL(1) + MODEL і BLOG(2, зупинка на BLOG) + 2 цілі
        # файли; перевірка зупиняється на першому невідповідному компоненті.
        $fewExpectedHashed = @(
            # @() обов'язкові: функція з одним шляхом повертає рядок, і без
            # них "+" склеїв би рядки замість масивів.
            @(Get-BRAVORetentionGenerationPaths -Root $fewRoot -GenerationIds @($fewG0) -Components @('MODEL')) +
            @(Get-BRAVORetentionGenerationPaths -Root $fewRoot -GenerationIds @($fewG1, $fewExpiredHealthy))
        )
        $fewOk = Invoke-BRAVORetentionFixtureCleanup -Root $fewRoot `
            -CurrentGenerationId $fewG0 -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $fewRoot)
        $fewAudit = Get-BRAVORetentionAuditLine
        $fewAttemptLines = @(Get-BRAVORetentionLogMessages -Pattern 'Retention: повна перевірка SHA512 generation')
        Test-BRAVOCondition `
            -Condition (
                $fewOk -eq $true -and
                $fewAttemptLines.Count -eq 3 -and
                (Get-BRAVORetentionHashedPathKey) -ceq (Get-BRAVORetentionPathKey -Paths $fewExpectedHashed) -and
                (Get-BRAVORetentionLogIndex -Pattern "повна перевірка SHA512 generation $fewExpiredHealthy (спроба 3; verified знайдено 0/2;") -ge 0 -and
                (Get-BRAVORetentionLogIndex -Pattern 'спроба 4;') -lt 0
            ) `
            -Name "BackupConsistency/FewerHealthyThanNWalksAllEligibleGenerations" `
            -Failure "коли цілих менше за N, пошук має пройти всі придатні (дешева перевірка ок) COMPLETE generation: очікувано 3 спроби, фактично $($fewAttemptLines.Count); generation з розміром, що не збігається ($fewSizeCorrupt), не читається SHA512; шляхи: $(@($global:BRAVORetentionHashPaths) -join ' ; ')"
        Test-BRAVOCondition `
            -Condition (
                $fewAudit.Contains("захищено (verified)=1 [$fewExpiredHealthy]") -and
                (Test-Path -LiteralPath $fewExpiredManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $fewRoot 'MODEL') ("MODEL_{0}.mdz" -f $fewExpiredHealthy))) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $fewRoot 'BLOG') ("BLOG_{0}.mdz" -f $fewExpiredHealthy))) -and
                $fewAudit.Contains('видалено (COMPLETE, прострочено)=0;') -and
                (Get-BRAVORetentionLogIndex -Pattern 'доки не знайдено 2 verified (придатних до перевірки: 3)') -ge 0 -and
                (Get-BRAVORetentionLogIndex -Pattern "Пошкоджена резервна копія ${fewSizeCorrupt}:" -Level 'WARNING') -ge 0
            ) `
            -Name "BackupConsistency/ExpiredHealthyIsProtectedWhenFewerThanNVerified" `
            -Failure "єдина знайдена ціла generation, навіть прострочена, має бути захищена і не видалятися; аудит: $fewAudit"
        $fewProblems = Get-BRAVORetentionTelemetryProblems -Root $fewRoot -ExpectedAttempts 3 -ExpectedBytes $fewExpectedBytes
        Test-BRAVOCondition `
            -Condition ($fewProblems -eq '') `
            -Name "BackupConsistency/RetentionAuditByteCounterEqualsSizeOfAttemptedGenerations" `
            -Failure "лічильник байтів аудиту має дорівнювати сумі розмірів архівів усіх generation, що мали спробу повної перевірки ($fewExpectedBytes байт, 3 спроби); проблеми: $fewProblems; аудит: $fewAudit"

        # E: enableArchiveDeletion=$false - ні SHA512, ні видалення COMPLETE.
        $global:enableArchiveDeletion = $false
        $offDeleteRoot = Join-Path $retentionStatusTestRoot 'deletion-disabled'
        [void](New-BRAVORetentionComponentFixture -Root $offDeleteRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        [void](New-BRAVORetentionComponentFixture -Root $offDeleteRoot -GenerationId '20260930_230000' -StartedAt (Get-Date).AddDays(-1))
        $offDeleteExpiredManifest = New-BRAVORetentionComponentFixture -Root $offDeleteRoot `
            -GenerationId '20250101_230000' -StartedAt (Get-Date).AddDays(-640)
        $offDeleteOk = Invoke-BRAVORetentionFixtureCleanup -Root $offDeleteRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $offDeleteRoot)
        $offDeleteInventory = @(Get-BRAVORetentionLogMessages -Pattern 'Retention: інвентаризація —') | Select-Object -First 1
        $offDeleteAudit = Get-BRAVORetentionAuditLine
        Test-BRAVOCondition `
            -Condition (
                $offDeleteOk -eq $true -and
                $global:BRAVORetentionHashCalls -eq 0 -and
                @($global:BRAVORetentionHashPaths).Count -eq 0 -and
                (Test-Path -LiteralPath $offDeleteExpiredManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $offDeleteRoot 'MODEL') 'MODEL_20250101_230000.mdz')) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $offDeleteRoot 'BLOG') 'BLOG_20250101_230000.mdz'))
            ) `
            -Name "BackupConsistency/DeletionDisabledNeitherHashesNorDeletesExpiredComplete" `
            -Failure "при enableArchiveDeletion=false прострочена ціла COMPLETE не видаляється і SHA512 не читається; викликів=$($global:BRAVORetentionHashCalls), шляхів=$(@($global:BRAVORetentionHashPaths).Count)"
        Test-BRAVOCondition `
            -Condition (
                $null -ne $offDeleteInventory -and
                $offDeleteInventory.Contains('прострочено за віком (до захисту N): COMPLETE=1, failed/incomplete=0') -and
                $offDeleteInventory.Contains('видалення за віком: COMPLETE — вимкнено (enableArchiveDeletion)') -and
                -not $offDeleteInventory.Contains('COMPLETE — увімкнено') -and
                $offDeleteInventory.Contains('SHA512 не потрібен: enableArchiveDeletion=false, COMPLETE за віком не видаляються') -and
                $offDeleteAudit.Contains('перевірено SHA512 (generation)=0;') -and
                $offDeleteAudit.Contains('(0 байт)')
            ) `
            -Name "BackupConsistency/DeletionDisabledInventoryNamesReason" `
            -Failure "інвентаризація при enableArchiveDeletion=false має називати причину 'enableArchiveDeletion=false' і рахувати 1 кандидата; інвентаризація: $offDeleteInventory; аудит: $offDeleteAudit"

        # F: пошкоджена COMPLETE віком між failedArchiveRetentionDays (30) і
        # archiveRetentionDays (183) - не видаляється навіть при обох
        # увімкнених прапорах видалення.
        $global:enableArchiveDeletion = $true
        $global:enableFailedArchiveDeletion = $true
        $midCorruptRoot = Join-Path $retentionStatusTestRoot 'corrupt-between-cutoffs'
        [void](New-BRAVORetentionComponentFixture -Root $midCorruptRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        [void](New-BRAVORetentionComponentFixture -Root $midCorruptRoot -GenerationId '20260930_230000' -StartedAt (Get-Date).AddDays(-1))
        $midCorruptManifest = New-BRAVORetentionComponentFixture -Root $midCorruptRoot `
            -GenerationId '20260601_230000' -StartedAt (Get-Date).AddDays(-100) -CorruptComponents @('BLOG')
        $midCorruptOk = Invoke-BRAVORetentionFixtureCleanup -Root $midCorruptRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $midCorruptRoot)
        Test-BRAVOCondition `
            -Condition (
                $midCorruptOk -eq $true -and
                (Test-Path -LiteralPath $midCorruptManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $midCorruptRoot 'MODEL') 'MODEL_20260601_230000.mdz')) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $midCorruptRoot 'BLOG') 'BLOG_20260601_230000.mdz')) -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Пошкоджена резервна копія 20260601_230000') -and
                $global:BRAVORetentionHashCalls -eq 0
            ) `
            -Name "BackupConsistency/CorruptCompleteBetweenCutoffsIsKeptWithBothDeletionFlags" `
            -Failure "пошкоджена COMPLETE віком 100 днів (між 30 і 183) при enableArchiveDeletion=true і enableFailedArchiveDeletion=true не має видалятися гілкою failed-retention: manifest і архіви лишаються, WARNING є; викликів SHA512=$($global:BRAVORetentionHashCalls)"

        # F (з активним SHA512): прострочена ціла COMPLETE вмикає пошук
        # verified. Між failedCutoff і validCutoff лежать дві пошкоджені
        # COMPLETE: прихована (40 днів, читається SHA512 і не проходить) і
        # розмірна (100 днів, відсіюється дешевою перевіркою). Обидві
        # лишаються, жодна не йде у failed-retention; пошук переходить до
        # цілої 150-денної, прострочена 200-денна видаляється за віком.
        $midHashRoot = Join-Path $retentionStatusTestRoot 'corrupt-between-cutoffs-sha512'
        [void](New-BRAVORetentionComponentFixture -Root $midHashRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $midHashRotManifest = New-BRAVORetentionComponentFixture -Root $midHashRoot `
            -GenerationId '20260820_230000' -StartedAt (Get-Date).AddDays(-40) -BitRotComponents @('BLOG')
        $midHashSizeManifest = New-BRAVORetentionComponentFixture -Root $midHashRoot `
            -GenerationId '20260620_230000' -StartedAt (Get-Date).AddDays(-100) -CorruptComponents @('BLOG')
        [void](New-BRAVORetentionComponentFixture -Root $midHashRoot -GenerationId '20260501_230000' -StartedAt (Get-Date).AddDays(-150))
        $midHashExpiredManifest = New-BRAVORetentionComponentFixture -Root $midHashRoot `
            -GenerationId '20260301_230000' -StartedAt (Get-Date).AddDays(-200)
        $midHashOk = Invoke-BRAVORetentionFixtureCleanup -Root $midHashRoot `
            -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $midHashRoot)
        $midHashAudit = Get-BRAVORetentionAuditLine
        $midHashExpectedKeys = Get-BRAVORetentionPathKey -Paths (Get-BRAVORetentionGenerationPaths -Root $midHashRoot `
            -GenerationIds @('20261001_230000', '20260820_230000', '20260501_230000'))
        Test-BRAVOCondition `
            -Condition (
                $midHashOk -eq $true -and
                (Test-Path -LiteralPath $midHashRotManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $midHashRoot 'BLOG') 'BLOG_20260820_230000.mdz')) -and
                (Test-Path -LiteralPath $midHashSizeManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $midHashRoot 'BLOG') 'BLOG_20260620_230000.mdz')) -and
                -not (Test-Path -LiteralPath $midHashExpiredManifest) -and
                (Get-BRAVORetentionHashedPathKey) -ceq $midHashExpectedKeys -and
                $midHashAudit.Contains('захищено (verified)=2 [20261001_230000, 20260501_230000]') -and
                $midHashAudit.Contains('пошкоджено (COMPLETE, не пройшли перевірку)=2;') -and
                $midHashAudit.Contains('видалено (COMPLETE, прострочено)=1;') -and
                $midHashAudit.Contains('видалено (failed/incomplete, прострочено)=0;') -and
                (Get-BRAVORetentionLogIndex -Pattern 'Retention: generation 20260820_230000 — перевірку SHA512 не пройдено') -ge 0 -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Пошкоджена резервна копія 20260820_230000') -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Пошкоджена резервна копія 20260620_230000')
            ) `
            -Name "BackupConsistency/CorruptCompleteBetweenCutoffsIsKeptWhileSha512SearchRuns" `
            -Failure "з активним SHA512 пошкоджені COMPLETE віком 40 і 100 днів мають лишитися (не failed-retention), пошук verified має пропустити 40-денну і захистити 20261001/20260501, прострочена 20260301 видаляється за віком; шляхи SHA512: $(@($global:BRAVORetentionHashPaths) -join ' ; '); аудит: $midHashAudit"

        # Збій читання ВСЕРЕДИНІ Get-BRAVOFileHash (заблокований/нечитабельний
        # архів під час SHA512): generation не зараховується до verified,
        # пошук іде далі, retention завершується штатно (без ERROR і без
        # неконтрольованого винятку), нічого не видаляється як невдале.
        $hashFailRoot = Join-Path $retentionStatusTestRoot 'hash-read-failure'
        [void](New-BRAVORetentionComponentFixture -Root $hashFailRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $hashFailManifest = New-BRAVORetentionComponentFixture -Root $hashFailRoot `
            -GenerationId '20260930_230000' -StartedAt (Get-Date).AddDays(-1)
        [void](New-BRAVORetentionComponentFixture -Root $hashFailRoot -GenerationId '20260929_230000' -StartedAt (Get-Date).AddDays(-2))
        $hashFailExpiredManifest = New-BRAVORetentionComponentFixture -Root $hashFailRoot `
            -GenerationId '20260301_230000' -StartedAt (Get-Date).AddDays(-200)
        $global:BRAVORetentionHashFailPath = Join-Path (Join-Path $hashFailRoot 'BLOG') 'BLOG_20260930_230000.mdz'
        $hashFailOk = $null
        $hashFailThrown = $null
        try {
            $hashFailOk = Invoke-BRAVORetentionFixtureCleanup -Root $hashFailRoot `
                -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $hashFailRoot)
        } catch {
            $hashFailThrown = $_.Exception.Message
        } finally {
            $global:BRAVORetentionHashFailPath = $null
        }
        $hashFailAudit = Get-BRAVORetentionAuditLine
        $hashFailExpectedKeys = Get-BRAVORetentionPathKey -Paths (Get-BRAVORetentionGenerationPaths -Root $hashFailRoot `
            -GenerationIds @('20261001_230000', '20260930_230000', '20260929_230000'))
        Test-BRAVOCondition `
            -Condition (
                $null -eq $hashFailThrown -and
                $hashFailOk -eq $true -and
                (Test-Path -LiteralPath $hashFailManifest) -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $hashFailRoot 'BLOG') 'BLOG_20260930_230000.mdz')) -and
                -not (Test-Path -LiteralPath $hashFailExpiredManifest) -and
                (Get-BRAVORetentionHashedPathKey) -ceq $hashFailExpectedKeys -and
                $hashFailAudit.Contains('захищено (verified)=2 [20261001_230000, 20260929_230000]') -and
                $hashFailAudit.Contains('видалено (failed/incomplete, прострочено)=0;') -and
                $hashFailAudit.Contains('помилок видалення=0;') -and
                (Get-BRAVORetentionLogIndex -Pattern 'Retention: generation 20260930_230000 — перевірку SHA512 не пройдено') -ge 0 -and
                (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Пошкоджена резервна копія 20260930_230000') -and
                @($global:BRAVORetentionTestLog | Where-Object { $_.StartsWith('ERROR|') }).Count -eq 0
            ) `
            -Name "BackupConsistency/HashReadFailureIsNotVerifiedAndSearchContinues" `
            -Failure "IOException усередині Get-BRAVOFileHash має робити generation неперевіреною (WARNING, лишається), пошук має перейти до 20260929, прострочена 20260301 видаляється, retention повертає `$true без ERROR і без винятку; виняток=$hashFailThrown; результат=$hashFailOk; шляхи: $(@($global:BRAVORetentionHashPaths) -join ' ; '); аудит: $hashFailAudit"

        # G: прострочена пошкоджена COMPLETE (розмір і приховане пошкодження)
        # за поточною політикою віку видаляється при enableArchiveDeletion=true
        # і лишається при false.
        foreach ($deleteFlag in @($true, $false)) {
            $global:enableArchiveDeletion = $deleteFlag
            $expCorruptRoot = Join-Path $retentionStatusTestRoot ("expired-corrupt-delete-{0}" -f $deleteFlag)
            [void](New-BRAVORetentionComponentFixture -Root $expCorruptRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
            [void](New-BRAVORetentionComponentFixture -Root $expCorruptRoot -GenerationId '20260930_230000' -StartedAt (Get-Date).AddDays(-1))
            [void](New-BRAVORetentionComponentFixture -Root $expCorruptRoot -GenerationId '20260929_230000' -StartedAt (Get-Date).AddDays(-2))
            $expSizeManifest = New-BRAVORetentionComponentFixture -Root $expCorruptRoot `
                -GenerationId '20250201_230000' -StartedAt (Get-Date).AddDays(-400) -CorruptComponents @('BLOG')
            $expRotManifest = New-BRAVORetentionComponentFixture -Root $expCorruptRoot `
                -GenerationId '20250202_230000' -StartedAt (Get-Date).AddDays(-399) -BitRotComponents @('MODEL')
            $expCorruptOk = Invoke-BRAVORetentionFixtureCleanup -Root $expCorruptRoot `
                -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $expCorruptRoot)
            $expCorruptAudit = Get-BRAVORetentionAuditLine
            $expSizeGone = -not (Test-Path -LiteralPath $expSizeManifest) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $expCorruptRoot 'MODEL') 'MODEL_20250201_230000.mdz')) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $expCorruptRoot 'BLOG') 'BLOG_20250201_230000.mdz'))
            $expRotGone = -not (Test-Path -LiteralPath $expRotManifest) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $expCorruptRoot 'MODEL') 'MODEL_20250202_230000.mdz'))
            if ($deleteFlag) {
                $expCorruptKeys = Get-BRAVORetentionPathKey -Paths (Get-BRAVORetentionGenerationPaths -Root $expCorruptRoot -GenerationIds @('20261001_230000', '20260930_230000'))
                Test-BRAVOCondition `
                    -Condition (
                        $expCorruptOk -eq $true -and
                        $expSizeGone -and
                        $expRotGone -and
                        (Test-BRAVORetentionLogged -Level 'WARNING' -Pattern 'Пошкоджена резервна копія 20250201_230000') -and
                        $expCorruptAudit.Contains('видалено (COMPLETE, прострочено)=2;') -and
                        $expCorruptAudit.Contains('видалено (failed/incomplete, прострочено)=0;') -and
                        (Get-BRAVORetentionHashedPathKey) -ceq $expCorruptKeys
                    ) `
                    -Name "BackupConsistency/ExpiredCorruptCompleteIsDeletedByArchiveRetentionDays" `
                    -Failure "прострочена (старша за 183 дні) незахищена пошкоджена COMPLETE при enableArchiveDeletion=true видаляється за віком (розмір: видалено=$expSizeGone, приховане пошкодження: видалено=$expRotGone) і рахується як 'видалено (COMPLETE, прострочено)=2'; SHA512 читає лише 2 найновіші; аудит: $expCorruptAudit"
            } else {
                Test-BRAVOCondition `
                    -Condition (
                        $expCorruptOk -eq $true -and
                        -not $expSizeGone -and
                        -not $expRotGone -and
                        (Test-Path -LiteralPath $expSizeManifest) -and
                        (Test-Path -LiteralPath $expRotManifest) -and
                        $global:BRAVORetentionHashCalls -eq 0 -and
                        $expCorruptAudit.Contains('видалено (COMPLETE, прострочено)=0;')
                    ) `
                    -Name "BackupConsistency/ExpiredCorruptCompleteIsKeptWhenArchiveDeletionDisabled" `
                    -Failure "при enableArchiveDeletion=false прострочена пошкоджена COMPLETE не видаляється ні гілкою віку, ні failed-retention; SHA512 не читається; викликів=$($global:BRAVORetentionHashCalls); аудит: $expCorruptAudit"
            }
        }
        $global:enableArchiveDeletion = $true

        # I: підсумковий аудит прогону з заблокованим файлом звітує помилку
        # видалення (повторення сценарію 4 із збереженням логу того прогону).
        $global:enableArchiveDeletion = $false
        $lockAuditRoot = Join-Path $retentionStatusTestRoot 'locked-audit'
        [void](New-BRAVORetentionComponentFixture -Root $lockAuditRoot -GenerationId '20260101_230000' `
            -StartedAt (Get-Date).AddDays(-270) -Status 'FAILED')
        [void](New-BRAVORetentionComponentFixture -Root $lockAuditRoot -GenerationId '20261001_230000' -StartedAt (Get-Date))
        $lockAuditFile = Join-Path (Join-Path $lockAuditRoot 'BLOG') 'BLOG_20260101_230000.mdz'
        $global:BRAVORetentionLockedPath = $lockAuditFile
        function global:Remove-Item {
            [CmdletBinding()]
            param([string]$LiteralPath, [string]$Path, [switch]$Force, [switch]$Recurse)
            $target = if ($LiteralPath) { $LiteralPath } else { $Path }
            if ($null -ne $global:BRAVORetentionLockedPath -and $target -eq $global:BRAVORetentionLockedPath) {
                throw 'The process cannot access the file because it is being used by another process.'
            }
            Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
        }
        $lockAuditOk = $null
        try {
            $lockAuditOk = Invoke-BRAVORetentionFixtureCleanup -Root $lockAuditRoot `
                -CurrentGenerationId '20261001_230000' -ArchiveDefinitions (Get-BRAVORetentionFixtureDefinitions -Root $lockAuditRoot)
        } finally {
            $global:BRAVORetentionLockedPath = $null
            Microsoft.PowerShell.Management\Remove-Item -Path Function:\Remove-Item -ErrorAction SilentlyContinue
        }
        $lockAuditLine = Get-BRAVORetentionAuditLine
        Test-BRAVOCondition `
            -Condition (
                $lockAuditOk -eq $false -and
                $null -ne $lockAuditLine -and
                $lockAuditLine.Contains('помилок видалення=1;') -and
                $lockAuditLine.Contains('перевірено SHA512 (generation)=0;')
            ) `
            -Name "BackupConsistency/LockedArtifactRunAuditReportsOneDeletionFailure" `
            -Failure "підсумковий аудит прогону із заблокованим архівом має містити 'помилок видалення=1', а прогін - повернути `$false (результат=$lockAuditOk); аудит: $lockAuditLine"
        $global:enableArchiveDeletion = $true
    } finally {
        Remove-Item -Path Variable:\global:enableArchiveDeletion, `
            Variable:\global:enableFailedArchiveDeletion, `
            Variable:\global:failedArchiveRetentionDays, `
            Variable:\global:minimumRetainedVerifiedBackups, `
            Variable:\global:progressSettings, `
            Variable:\global:BRAVORetentionTestLog, `
            Variable:\global:BRAVORetentionHashCalls, `
            Variable:\global:BRAVORetentionHashPaths, `
            Variable:\global:BRAVORetentionHashFailPath, `
            Variable:\global:BRAVORetentionLockedPath, `
            Variable:\global:BRAVORetentionUnreadablePath `
            -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $retentionStatusTestRoot) {
            Remove-Item -LiteralPath $retentionStatusTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Orphan temp-artifact sweep (roadmap Етап 4: OrphanTempRetention).
    # .work\*.partial* лишається назавжди, якщо процес вбито між створенням
    # тимчасового файлу й Remove-BRAVOTemporaryArchiveArtifacts (та прибирає
    # лише in-process). Reused module: реальні функції, реальне тимчасове
    # дерево каталогів — не текстова перевірка.
    $orphanSweepModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($archiveScriptText + [Environment]::NewLine + $manifestStorageLogStub) `
        -FunctionNames @('Remove-BRAVOOrphanedTemporaryArchiveArtifacts', 'Test-BRAVOBackupArtifactPathSafe', 'Write-BRAVOLog') `
        -PreferLastDefinitionOnDuplicate
    $orphanSweepTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_ORPHAN_SWEEP_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($orphanSweepTestRoot)
        $orphanSweepDestination = Join-Path $orphanSweepTestRoot 'MODEL'
        [void][IO.Directory]::CreateDirectory($orphanSweepDestination)
        $orphanSweepWorkDir = Join-Path $orphanSweepDestination '.work'
        [void][IO.Directory]::CreateDirectory($orphanSweepWorkDir)

        $orphanOldFile = Join-Path $orphanSweepWorkDir 'MODEL.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.partial.mdz'
        $orphanOldHash = $orphanOldFile + '.sha512'
        [IO.File]::WriteAllText($orphanOldFile, 'stale partial payload')
        [IO.File]::WriteAllText($orphanOldHash, 'stale partial hash sidecar')
        $staleTimestamp = (Get-Date).AddHours(-72)
        (Get-Item -LiteralPath $orphanOldFile).LastWriteTime = $staleTimestamp
        (Get-Item -LiteralPath $orphanOldHash).LastWriteTime = $staleTimestamp

        $orphanFreshFile = Join-Path $orphanSweepWorkDir 'MODEL.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.partial.mdz'
        [IO.File]::WriteAllText($orphanFreshFile, 'fresh partial payload')

        $orphanOutsideWorkFile = Join-Path $orphanSweepDestination 'MODEL_20250101_010000.mdz'
        [IO.File]::WriteAllText($orphanOutsideWorkFile, 'published archive, must never be touched')
        (Get-Item -LiteralPath $orphanOutsideWorkFile).LastWriteTime = $staleTimestamp

        $orphanSweepArchiveDefinitions = @(
            [pscustomobject]@{ Type = 'MODEL'; Enabled = $true; Destination = $orphanSweepDestination }
        )
        $orphanSweepRemovedCount = 0
        $orphanSweepOk = & $orphanSweepModule {
            param($Definitions, $Hours, $CountRef)
            Remove-BRAVOOrphanedTemporaryArchiveArtifacts `
                -ArchiveDefinitions $Definitions -RetentionHours $Hours -RemovedFileCount $CountRef
        } $orphanSweepArchiveDefinitions 48 ([ref]$orphanSweepRemovedCount)

        Test-BRAVOCondition `
            -Condition (
                $orphanSweepOk -eq $true -and
                $orphanSweepRemovedCount -eq 2 -and
                -not (Test-Path -LiteralPath $orphanOldFile) -and
                -not (Test-Path -LiteralPath $orphanOldHash)
            ) `
            -Name "BackupConsistency/OrphanTempSweepDeletesFilesOlderThanThreshold" `
            -Failure "осиротілі .work\*.partial* файли старші за RetentionHours мають видалятися (і .mdz, і .sha512 sidecar)"
        Test-BRAVOCondition `
            -Condition (Test-Path -LiteralPath $orphanFreshFile) `
            -Name "BackupConsistency/OrphanTempSweepPreservesFreshFiles" `
            -Failure "свіжий .work\*.partial* файл (новіший за RetentionHours) не повинен видалятися — процес може ще легітимно тривати"
        Test-BRAVOCondition `
            -Condition (Test-Path -LiteralPath $orphanOutsideWorkFile) `
            -Name "BackupConsistency/OrphanTempSweepNeverTouchesFilesOutsideWorkDirectory" `
            -Failure "opублiкований .mdz поза .work\ не повинен зачіпатися orphan-sweep'ом, навіть якщо він старий"

        # Регресія (P1, три окремі, точно класифіковані сценарії — БЕЗ
        # окремого Test-Path gate, підтверджено видаленим з реалізації):
        # Get-ChildItem сам класифікує причину невдачі через тип винятку.

        # 1) .work справді відсутній (ItemNotFoundException) — доброякісний
        # SKIP, а не помилка. Окремий Destination без .work\ узагалі.
        $orphanNoWorkDestination = Join-Path $orphanSweepTestRoot 'BLOG'
        [void][IO.Directory]::CreateDirectory($orphanNoWorkDestination)
        $orphanNoWorkDefinitions = @(
            [pscustomobject]@{ Type = 'BLOG'; Enabled = $true; Destination = $orphanNoWorkDestination }
        )
        $orphanNoWorkRemovedCount = -1
        $orphanNoWorkOk = & $orphanSweepModule {
            param($Definitions, $Hours, $CountRef)
            Remove-BRAVOOrphanedTemporaryArchiveArtifacts `
                -ArchiveDefinitions $Definitions -RetentionHours $Hours -RemovedFileCount $CountRef
        } $orphanNoWorkDefinitions 48 ([ref]$orphanNoWorkRemovedCount)
        Test-BRAVOCondition `
            -Condition ($orphanNoWorkOk -eq $true -and $orphanNoWorkRemovedCount -eq 0) `
            -Name "BackupConsistency/OrphanTempSweepMissingWorkDirectoryIsBenignSkip" `
            -Failure "коли .work справді не існує (ItemNotFoundException/DirectoryNotFoundException), sweep має повернути `$true — не трактувати відсутність каталогу як помилку"

        # 2) .work існує, але доступ заборонено (UnauthorizedAccessException,
        # той самий тип, що реально кидає Get-ChildItem для pure ACL
        # access-denied — на відміну від Test-Path, який просто повернув би
        # $false і НЕ дав би це відрізнити від "не існує"; підтверджено
        # видаленням Test-Path gate з реалізації цієї сесії). Локальний
        # override Get-ChildItem усередині виклику через & $module { ... }
        # реально підміняє команду, яку викликає дот-сорсена функція
        # (перевірено емпірично) — той самий принцип, що InModuleScope+Mock,
        # без нової залежності для репозиторію.
        $orphanAccessDeniedRemovedCount = 0
        $orphanAccessDeniedResult = & $orphanSweepModule {
            param($Definitions, $Hours, $CountRef)
            function Get-ChildItem {
                param(
                    [string]$LiteralPath,
                    [switch]$File,
                    [switch]$Force,
                    [string]$Filter,
                    [string]$ErrorAction
                )
                if ($LiteralPath -like '*\.work') {
                    throw [System.UnauthorizedAccessException]::new(
                        "simulated: access denied enumerating $LiteralPath"
                    )
                }
                Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
            }
            Remove-BRAVOOrphanedTemporaryArchiveArtifacts `
                -ArchiveDefinitions $Definitions -RetentionHours $Hours -RemovedFileCount $CountRef
        } $orphanSweepArchiveDefinitions 48 ([ref]$orphanAccessDeniedRemovedCount)
        Test-BRAVOCondition `
            -Condition ($orphanAccessDeniedResult -eq $false) `
            -Name "BackupConsistency/OrphanTempSweepAccessDeniedIsFailVisible" `
            -Failure "UnauthorizedAccessException на .work (pure ACL access-denied) має повертати `$false (fail-visible), а не мовчки трактуватися як 'каталогу немає'"

        # 3) .work існує, але провайдер/мережа падає з ІНШИМ типом винятку
        # (IOException — відключений диск, недоступний UNC) — так само
        # $failed=true/ERROR, доводить, що класифікація не звужена лише до
        # UnauthorizedAccessException.
        $orphanIoFailureRemovedCount = 0
        $orphanIoFailureResult = & $orphanSweepModule {
            param($Definitions, $Hours, $CountRef)
            function Get-ChildItem {
                param(
                    [string]$LiteralPath,
                    [switch]$File,
                    [switch]$Force,
                    [string]$Filter,
                    [string]$ErrorAction
                )
                if ($LiteralPath -like '*\.work') {
                    throw [System.IO.IOException]::new(
                        "simulated: provider I/O error enumerating $LiteralPath"
                    )
                }
                Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
            }
            Remove-BRAVOOrphanedTemporaryArchiveArtifacts `
                -ArchiveDefinitions $Definitions -RetentionHours $Hours -RemovedFileCount $CountRef
        } $orphanSweepArchiveDefinitions 48 ([ref]$orphanIoFailureRemovedCount)
        Test-BRAVOCondition `
            -Condition ($orphanIoFailureResult -eq $false) `
            -Name "BackupConsistency/OrphanTempSweepProviderIOFailureIsFailVisible" `
            -Failure "IOException на .work (відключений диск/недоступний UNC) має повертати `$false (fail-visible), а не мовчки трактуватися як 0 кандидатів"
    } finally {
        if (Test-Path -LiteralPath $orphanSweepTestRoot) {
            Remove-Item -LiteralPath $orphanSweepTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Структурно: Remove-BRAVOOrphanedTemporaryArchiveArtifacts більше
    # НЕ використовує Test-Path узагалі (AST-звуження до тіла функції, не
    # "рядок десь у файлі" — той самий idiom, що інші структурні тести).
    # Test-Path не fail-visible для pure ACL access-denied за конструкцією
    # (.NET Directory.Exists ковтає UnauthorizedAccessException), тому
    # єдиний надійний спосіб — не мати цього виклику взагалі.
    $orphanSweepAstErrors = $null
    $orphanSweepAstTokens = $null
    $orphanSweepAst = [Management.Automation.Language.Parser]::ParseInput(
        $archiveScriptText, [ref]$orphanSweepAstTokens, [ref]$orphanSweepAstErrors
    )
    $orphanSweepFunctionAst = $orphanSweepAst.Find(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $candidate.Name -eq 'Remove-BRAVOOrphanedTemporaryArchiveArtifacts'
        },
        $true
    )
    $orphanSweepTestPathCalls = @($orphanSweepFunctionAst.FindAll(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.CommandAst] -and
            $candidate.GetCommandName() -eq 'Test-Path'
        },
        $true
    ))
    Test-BRAVOCondition `
        -Condition (
            $null -ne $orphanSweepFunctionAst -and
            $orphanSweepTestPathCalls.Count -eq 0
        ) `
        -Name "BackupConsistency/OrphanTempSweepDoesNotUseTestPathGate" `
        -Failure "Remove-BRAVOOrphanedTemporaryArchiveArtifacts не повинна викликати Test-Path узагалі — він не fail-visible для pure ACL access-denied (.NET Directory.Exists ковтає UnauthorizedAccessException)"

    # --- Retention audit summary: один підсумковий рядок на прогін
    # (скільки generation оцінено/захищено/видалено і чому) доповнює вже
    # наявні per-deletion рядки. AST-звужений до тіла самої функції — той
    # самий idiom, що ManifestStorage/RetentionUsesCentralizedReader нижче.
    $auditParseErrors = $null
    $auditParseTokens = $null
    $archiveAstForAudit = [Management.Automation.Language.Parser]::ParseInput(
        $archiveScriptText, [ref]$auditParseTokens, [ref]$auditParseErrors
    )
    $removeExpiredFunctionAst = $archiveAstForAudit.Find(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $candidate.Name -eq 'Remove-BRAVOExpiredBackupGenerations'
        },
        $true
    )
    $removeExpiredFunctionText = if ($null -ne $removeExpiredFunctionAst) { $removeExpiredFunctionAst.Extent.Text } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $removeExpiredFunctionText.Contains('Аудит retention:') -and
            $removeExpiredFunctionText.Contains('$deletedVerifiedExpiredCount') -and
            $removeExpiredFunctionText.Contains('$deletedFailedIncompleteCount') -and
            $removeExpiredFunctionText.Contains('$protectedGenerationIds.Count')
        ) `
        -Name "ManifestStorage/RetentionEmitsAuditSummaryLog" `
        -Failure "Remove-BRAVOExpiredBackupGenerations має писати один підсумковий 'Аудит retention' рядок (оцінено/захищено/видалено з розбивкою verified vs failed/incomplete) перед return"

    # --- 12. Retention (Archive) читає manifest-и через централізований reader ---
    Test-BRAVOCondition `
        -Condition (
            $archiveRuntimeTextForSizeSanity.Contains('function Remove-BRAVOExpiredBackupGenerations') -and
            $archiveRuntimeTextForSizeSanity.Contains('Get-BRAVOBackupGenerationManifestFiles -BackupRoot $BackupRoot') -and
            -not $archiveRuntimeTextForSizeSanity.Contains("Get-BRAVOFiles -Path `$BackupRoot -Filter 'BRAVO_BACKUP_*.json'")
        ) `
        -Name "ManifestStorage/RetentionUsesCentralizedReader" `
        -Failure "Remove-BRAVOExpiredBackupGenerations має шукати manifest-и через Get-BRAVOBackupGenerationManifestFiles (MANIFESTS + legacy fallback), а не напряму Get-BRAVOFiles по корені BackupRoot"

    # --- 13. Health лишається read-only: читає через reader, ніколи не мігрує/не пише ---
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains('Get-BRAVOBackupGenerationManifestFiles -BackupRoot $backupRootPath') -and
            -not $healthScriptText.Contains('Initialize-BRAVOBackupManifestStorage')
        ) `
        -Name "ManifestStorage/HealthReaderNeverMigratesOrWrites" `
        -Failure "BRAVO.Health.Runtime.ps1 має лише читати generation manifest-и через Get-BRAVOBackupGenerationManifestFiles і ніколи не викликати Initialize-BRAVOBackupManifestStorage"

    # --- 14. Restore-selector (промоутнутий у ArchiveHelpers) читає через той самий централізований reader ---
    $restoreTestScriptTextForManifestStorage = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_RESTORE_TEST.ps1"),
        [Text.Encoding]::UTF8
    )
    $archiveHelpersTextForManifestStorage = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psm1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $archiveHelpersTextForManifestStorage.Contains('-GenerationId $RequestedGenerationId') -and
            -not $restoreTestScriptTextForManifestStorage.Contains("Get-BRAVOFiles -Path `$BackupRoot -Filter 'BRAVO_BACKUP_*.json'")
        ) `
        -Name "ManifestStorage/RestoreTestUsesCentralizedReader" `
        -Failure "Get-BRAVORestoreGenerationManifest (BRAVO.ArchiveHelpers) має читати через Get-BRAVOBackupGenerationManifestFiles, а BRAVO_RESTORE_TEST.ps1 — не читати manifest-и напряму Get-BRAVOFiles по корені BackupRoot"

    # --- 15. Ротація/очистка LOGS ніколи не чіпає MANIFESTS ---
    $maintenanceScriptTextForManifestStorage = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $removeOldLogFilesFunctionAst = @(
        [Management.Automation.Language.Parser]::ParseInput(
            $maintenanceScriptTextForManifestStorage, [ref]$null, [ref]$null
        ).FindAll(
            {
                param($candidate)
                $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $candidate.Name -eq 'Remove-OldLogFiles'
            },
            $true
        )
    ) | Select-Object -First 1
    Test-BRAVOCondition `
        -Condition (
            $null -ne $removeOldLogFilesFunctionAst -and
            -not $removeOldLogFilesFunctionAst.Extent.Text.Contains('MANIFESTS') -and
            -not $removeOldLogFilesFunctionAst.Extent.Text.Contains('BackupRoot')
        ) `
        -Name "ManifestStorage/LogCleanupNeverReferencesManifests" `
        -Failure "Remove-OldLogFiles (LOGS retention) не повинен знати про MANIFESTS чи BackupRoot — це незалежні lifecycle, керовані окремо LogDays/CompressedLogDays"

    # --- 16. Виклик міграції в Maintenance ніколи не є фатальним (лише WARNING) ---
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptTextForManifestStorage.Contains('Initialize-BRAVOBackupManifestStorage') -and
            $maintenanceScriptTextForManifestStorage.Contains('ІНІЦІАЛІЗАЦІЯ/МІГРАЦІЯ MANIFESTS') -and
            -not (
                $maintenanceScriptTextForManifestStorage -match
                '(?s)ІНІЦІАЛІЗАЦІЯ/МІГРАЦІЯ MANIFESTS.{0,2500}?\bexit\b'
            )
        ) `
        -Name "ManifestStorage/MaintenanceMigrationCallSiteIsNonFatal" `
        -Failure "виклик Initialize-BRAVOBackupManifestStorage у Maintenance не повинен мати exit поруч — невдала міграція не має блокувати Maintenance"
