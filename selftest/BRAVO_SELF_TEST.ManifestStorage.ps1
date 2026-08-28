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
        [switch]$Environmental
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
        $rewrittenManifest = Get-Content -LiteralPath $rewrittenManifestPath -Raw | ConvertFrom-Json
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
    # пошкоджена generation падає у failed/incomplete-гілку, а старша валідна
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
                -Name "BackupConsistency/CorruptNewestGenerationFallsToFailedBranchAndOlderVerifiedSurvives" `
                -Failure "пошкоджена НАЙНОВІША generation (SHA512 не збігається) має падати у failed/incomplete-гілку і видалятись за failedArchiveRetentionDays, а СТАРІША справді валідна generation має лишатись захищеною, попри те, що вона хронологічно старіша"
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
