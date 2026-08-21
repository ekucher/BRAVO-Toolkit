# Домен-фрагмент self-test: TraceArchive — накопичувальний добовий
# Trace_YYYYMMDD.mdz (модель 5.2.0): backlog за датою З ІМЕНІ, план
# New/Duplicate/Conflict, транзакційне оновлення (.work + 7z t +
# re-inventory immutability + SHA512 + атомарна публікація). Сценарії
# ганяються на СПРАВЖНЬОМУ Tools\7za.exe (шифровані архіви): семантику `7za a` в шифрований архів
# стаби підтвердити не можуть, а помилка в ній коштує trace-історії.
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition,
# New-BRAVOSelfTestRuntimeModule, $script:failures.
$traceArchiveScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
    [Text.Encoding]::UTF8
)

    Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $root "modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1") -Force -ErrorAction Stop

    # Стаби ПЕРЕД реальним текстом: FindAll бере ПЕРШЕ визначення, тому
    # логери/алерти Runtime підмінюються тихими заглушками (задокументована
    # пастка: стаб після реального тексту не спрацював би). Форвард-стаби
    # module-qualified: попередні домени self-test авто-імпортують власні
    # заглушки цих імен у глобальну сесію (New-Module-пастка), і без
    # кваліфікації ізольований модуль підхопив би чужий фейк замість
    # канонічної реалізації Compatibility/ArchiveHelpers.
    $traceArchiveStubText = @'
function Write-Log { param($Message, [string]$Level = 'INFO') }
function Send-SlackAlert { param($Message, [switch]$IsCritical) }
function Test-SevenZipArchiveIntegrity { BRAVO.ArchiveHelpers\Test-SevenZipArchiveIntegrity @args }
function Get-BRAVOSevenZipArchiveEntries { BRAVO.Compatibility\Get-BRAVOSevenZipArchiveEntries @args }
function Get-BRAVOSevenZipFileCrc { BRAVO.Compatibility\Get-BRAVOSevenZipFileCrc @args }
function Get-BRAVOSevenZipExitCodeDescription { BRAVO.Compatibility\Get-BRAVOSevenZipExitCodeDescription @args }
function Get-BRAVOFileHash { BRAVO.Compatibility\Get-BRAVOFileHash @args }
function Get-BRAVOFiles { BRAVO.Compatibility\Get-BRAVOFiles @args }
function ConvertTo-BRAVOWindowsCommandLineArgument { BRAVO.Compatibility\ConvertTo-BRAVOWindowsCommandLineArgument @args }
function Start-BRAVOProcessOutputCapture { BRAVO.Compatibility\Start-BRAVOProcessOutputCapture @args }
function Write-BRAVOProcessInputText { BRAVO.Compatibility\Write-BRAVOProcessInputText @args }
function Complete-BRAVOProcessOutputCapture { BRAVO.Compatibility\Complete-BRAVOProcessOutputCapture @args }
'@
    $traceArchiveModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($traceArchiveStubText + "`n" + $traceArchiveScriptText) `
        -FunctionNames @(
            "Write-Log",
            "Send-SlackAlert",
            "Test-SevenZipArchiveIntegrity",
            "Get-BRAVOSevenZipArchiveEntries",
            "Get-BRAVOSevenZipFileCrc",
            "Get-BRAVOSevenZipExitCodeDescription",
            "Get-BRAVOFileHash",
            "Get-BRAVOFiles",
            "ConvertTo-BRAVOWindowsCommandLineArgument",
            "Start-BRAVOProcessOutputCapture",
            "Write-BRAVOProcessInputText",
            "Complete-BRAVOProcessOutputCapture",
            "Write-BRAVOLogRotationMessage",
            "Format-CommandOutput",
            "Invoke-CommandWithLog",
            "Get-BRAVOTraceArchiveBacklog",
            "Get-BRAVOTraceArchiveUpdatePlan",
            "New-BRAVOTraceWorkArchivePath",
            "Remove-BRAVOTraceWorkArtifacts",
            "Clear-BRAVOTraceOrphanWorkArtifacts",
            "Write-BRAVOTraceArchiveSidecar",
            "Test-BRAVOTraceArchiveSidecarCurrent",
            "Update-BRAVOTraceDailyArchive"
        )

    $traceArchive7za = Join-Path $root "Tools\7za.exe"
    $traceArchivePassword = 'trace-selftest-pass'
    # БЕЗ -mhe: другий запит пароля при add в mhe-архів нечитабельний з
    # redirected stdin (див. коментар в Update-BRAVOTraceDailyArchive).
    $traceArchiveAddParams = @('a', '-y', '-p')
    $traceArchiveTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_TRACE_ARCHIVE_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        $taTrace = Join-Path $traceArchiveTestRoot "Trace"
        [void](New-Item -ItemType Directory -Path $taTrace -Force)

        function New-BRAVOTraceArchiveFixture {
            param([string]$Name, [string]$Content)
            $path = Join-Path $taTrace $Name
            [IO.File]::WriteAllText($path, $Content, (New-Object Text.UTF8Encoding($false)))
            return (Get-Item -LiteralPath $path)
        }

        # ===== Backlog: групування за датою З ІМЕНІ, oldest->newest,
        # legacy/сміття невидимі =====
        [void](New-BRAVOTraceArchiveFixture -Name 'TraceSRV_20260820_110000.out' -Content 'srv-20 a')
        [void](New-BRAVOTraceArchiveFixture -Name 'TraceBIS_20260820_110001.out' -Content 'bis-20 a')
        [void](New-BRAVOTraceArchiveFixture -Name 'TraceSRV_20260821_090000.out' -Content 'srv-21 a')
        [void](New-BRAVOTraceArchiveFixture -Name 'TraceSRV_1.out' -Content 'legacy sequence')
        [void](New-BRAVOTraceArchiveFixture -Name 'TraceSRV_99999999_123456.out' -Content 'impossible date')
        [void](New-BRAVOTraceArchiveFixture -Name 'Trace_2026-08-20.mdz' -Content 'legacy mdz stub')
        [void](New-Item -ItemType Directory -Path (Join-Path $taTrace '2026-08-20') -Force)
        # Дата береться з імені, не з CreationTime: навмисно «чужий» час.
        (Get-Item -LiteralPath (Join-Path $taTrace 'TraceSRV_20260820_110000.out')).CreationTime = Get-Date -Date '2026-01-01 00:00:00'

        $taBacklog = & $traceArchiveModule { param($d) Get-BRAVOTraceArchiveBacklog -TraceDirectory $d } $taTrace
        Test-BRAVOCondition -Condition (
            @($taBacklog).Count -eq 2 -and
            [string]@($taBacklog)[0].DateKey -eq '20260820' -and
            [string]@($taBacklog)[1].DateKey -eq '20260821' -and
            @(@($taBacklog)[0].Files).Count -eq 2 -and
            [string]@($taBacklog)[0].ArchiveName -eq 'Trace_20260820.mdz' -and
            @(@($taBacklog) | ForEach-Object { @($_.Files) } | Where-Object { $_.Name -match '_1\.out$|99999999' }).Count -eq 0
        ) -Name 'TraceArchive/BacklogGroupsByNameDateOldestFirst' -Failure "backlog має дати 20260820(2 файли)+20260821 за іменами (не CreationTime), oldest-first; legacy _1.out і неможлива дата — невидимі; факт: $(@($taBacklog).Count) груп"

        # ===== Перший MDZ за дату: CREATED + 7zt + sidecar-формат =====
        $taGroup20 = @($taBacklog)[0]
        $taPlan1 = & $traceArchiveModule { param($g, $z, $p) Get-BRAVOTraceArchiveUpdatePlan -BacklogGroup $g -SevenZipPath $z -ArchivePassword $p } $taGroup20 $traceArchive7za $traceArchivePassword
        $taUpdate1 = & $traceArchiveModule { param($g, $pl, $z, $ap, $p) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 } $taGroup20 $taPlan1 $traceArchive7za $traceArchiveAddParams $traceArchivePassword
        $taSidecarText1 = if (Test-Path -LiteralPath $taGroup20.SidecarPath) { [IO.File]::ReadAllText($taGroup20.SidecarPath, [Text.Encoding]::UTF8) } else { '' }
        $taExpectedHash1 = if (Test-Path -LiteralPath $taGroup20.ArchivePath) { ([string](BRAVO.Compatibility\Get-BRAVOFileHash -Path $taGroup20.ArchivePath -Algorithm SHA512).Hash).ToLowerInvariant() } else { 'no-archive' }
        Test-BRAVOCondition -Condition (
            [string]$taUpdate1.Status -eq 'CREATED' -and
            [int]$taUpdate1.AddedCount -eq 2 -and
            (Test-Path -LiteralPath $taGroup20.ArchivePath) -and
            $taSidecarText1 -ceq "$taExpectedHash1 *Trace_20260820.mdz" -and
            (BRAVO.ArchiveHelpers\Test-SevenZipArchiveIntegrity -SevenZipPath $traceArchive7za -ArchivePath $taGroup20.ArchivePath -Password $traceArchivePassword -TimeoutSeconds 600)
        ) -Name 'TraceArchive/FirstDailyArchiveCreatedWithSidecar' -Failure "перший запуск дати має дати CREATED(2), 7zt OK і sidecar '{hash} *Trace_20260820.mdz'; факт: $($taUpdate1.Status)/$($taUpdate1.Error)"

        # ===== Друге поповнення: UPDATED, старі entries immutable =====
        $taInventoryBefore = BRAVO.Compatibility\Get-BRAVOSevenZipArchiveEntries -SevenZipPath $traceArchive7za -ArchivePath $taGroup20.ArchivePath -Password $traceArchivePassword
        [void](New-BRAVOTraceArchiveFixture -Name 'TraceSRV_20260820_180000.out' -Content 'srv-20 evening, more content')
        $taBacklog2 = & $traceArchiveModule { param($d) Get-BRAVOTraceArchiveBacklog -TraceDirectory $d } $taTrace
        $taGroup20b = @($taBacklog2 | Where-Object { $_.DateKey -eq '20260820' })[0]
        $taPlan2 = & $traceArchiveModule { param($g, $z, $p) Get-BRAVOTraceArchiveUpdatePlan -BacklogGroup $g -SevenZipPath $z -ArchivePassword $p } $taGroup20b $traceArchive7za $traceArchivePassword
        $taDiagLog = New-Object System.Collections.Generic.List[string]
        $taDiagLogger = { param($Message, $Level) [void]$taDiagLog.Add("[$Level] $Message") }.GetNewClosure()
        $taUpdate2 = & $traceArchiveModule { param($g, $pl, $z, $ap, $p, $lg) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 -Logger $lg } $taGroup20b $taPlan2 $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taDiagLogger
        $taInventoryAfter = BRAVO.Compatibility\Get-BRAVOSevenZipArchiveEntries -SevenZipPath $traceArchive7za -ArchivePath $taGroup20.ArchivePath -Password $traceArchivePassword
        $taOldPreserved = $true
        foreach ($oldEntry in @($taInventoryBefore.Entries)) {
            $afterMatch = @($taInventoryAfter.Entries | Where-Object { $_.Path -eq $oldEntry.Path -and [int64]$_.Size -eq [int64]$oldEntry.Size -and [string]$_.Crc -eq [string]$oldEntry.Crc })
            if (@($afterMatch).Count -ne 1) { $taOldPreserved = $false }
        }
        Test-BRAVOCondition -Condition (
            [string]$taUpdate2.Status -eq 'UPDATED' -and
            [int]$taUpdate2.AddedCount -eq 1 -and
            @($taPlan2.NewFiles).Count -eq 1 -and
            @($taPlan2.DuplicateFiles).Count -eq 2 -and
            $taOldPreserved -and
            @($taInventoryAfter.Entries).Count -eq 3
        ) -Name 'TraceArchive/SecondRunAppendsOnlyNewEntriesOldImmutable' -Failure "друге поповнення: UPDATED(+1), 2 дублікати skip, старі entries Path+Size+CRC незмінні, разом 3; факт: $($taUpdate2.Status) added=$($taUpdate2.AddedCount) entries=$(@($taInventoryAfter.Entries).Count) err=$($taUpdate2.Error) diag=$($taDiagLog -join ' // ')"

        # ===== Дублікат, що вже в архіві (слід «MDZ OK / SFTP FAIL»):
        # не додається повторно, архів байт-у-байт стабільний =====
        $taArchiveSizeBefore = (Get-Item -LiteralPath $taGroup20.ArchivePath).Length
        $taPlan3 = & $traceArchiveModule { param($g, $z, $p) Get-BRAVOTraceArchiveUpdatePlan -BacklogGroup $g -SevenZipPath $z -ArchivePassword $p } $taGroup20b $traceArchive7za $traceArchivePassword
        $taUpdate3 = & $traceArchiveModule { param($g, $pl, $z, $ap, $p) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 } $taGroup20b $taPlan3 $traceArchive7za $traceArchiveAddParams $traceArchivePassword
        Test-BRAVOCondition -Condition (
            [string]$taUpdate3.Status -eq 'UP_TO_DATE' -and
            @($taPlan3.NewFiles).Count -eq 0 -and
            @($taPlan3.DuplicateFiles).Count -eq 3 -and
            -not $taPlan3.HasConflicts -and
            (Get-Item -LiteralPath $taGroup20.ArchivePath).Length -eq $taArchiveSizeBefore
        ) -Name 'TraceArchive/DuplicateLocalFilesAreNotReAdded' -Failure "усі 3 локальні файли вже в архіві: план 0 нових/3 дублікати, UP_TO_DATE, розмір архіву незмінний; факт: $($taUpdate3.Status) new=$(@($taPlan3.NewFiles).Count) err=$($taUpdate3.Error) planErr=$($taPlan3.Error)"

        # ===== Restart-safe: зіпсований sidecar регенерується в UP_TO_DATE =====
        [IO.File]::WriteAllText($taGroup20.SidecarPath, 'garbage-sidecar', (New-Object Text.UTF8Encoding($false)))
        $taUpdate3b = & $traceArchiveModule { param($g, $pl, $z, $ap, $p) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 } $taGroup20b $taPlan3 $traceArchive7za $traceArchiveAddParams $traceArchivePassword
        $taSidecarText3b = [IO.File]::ReadAllText($taGroup20.SidecarPath, [Text.Encoding]::UTF8)
        $taExpectedHash3b = ([string](BRAVO.Compatibility\Get-BRAVOFileHash -Path $taGroup20.ArchivePath -Algorithm SHA512).Hash).ToLowerInvariant()
        Test-BRAVOCondition -Condition (
            [string]$taUpdate3b.Status -eq 'UP_TO_DATE' -and
            $taSidecarText3b -ceq "$taExpectedHash3b *Trace_20260820.mdz"
        ) -Name 'TraceArchive/UpToDateRegeneratesStaleSidecar' -Failure "UP_TO_DATE-гілка має регенерувати невідповідний sidecar (restart-safe після збою між публікацією архіву і sidecar)"

        # ===== Конфлікт: те саме ім'я, інший контент -> FAILED, архів і
        # локальний файл недоторкані =====
        $taConflictPath = Join-Path $taTrace 'TraceSRV_20260820_110000.out'
        [IO.File]::WriteAllText($taConflictPath, 'srv-20 TAMPERED content xxxx', (New-Object Text.UTF8Encoding($false)))
        $taHashBeforeConflict = ([string](BRAVO.Compatibility\Get-BRAVOFileHash -Path $taGroup20.ArchivePath -Algorithm SHA512).Hash)
        $taPlan4 = & $traceArchiveModule { param($g, $z, $p) Get-BRAVOTraceArchiveUpdatePlan -BacklogGroup $g -SevenZipPath $z -ArchivePassword $p } $taGroup20b $traceArchive7za $traceArchivePassword
        $taUpdate4 = & $traceArchiveModule { param($g, $pl, $z, $ap, $p) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 } $taGroup20b $taPlan4 $traceArchive7za $traceArchiveAddParams $traceArchivePassword
        Test-BRAVOCondition -Condition (
            $taPlan4.HasConflicts -and
            [string]$taUpdate4.Status -eq 'FAILED' -and
            ([string](BRAVO.Compatibility\Get-BRAVOFileHash -Path $taGroup20.ArchivePath -Algorithm SHA512).Hash) -ceq $taHashBeforeConflict -and
            (Test-Path -LiteralPath $taConflictPath)
        ) -Name 'TraceArchive/NameCollisionWithDifferentContentFailsClosed' -Failure "однакове ім'я з іншим контентом: план Conflict, Update=FAILED, archived entry і локальний файл недоторкані"
        [IO.File]::WriteAllText($taConflictPath, 'srv-20 a', (New-Object Text.UTF8Encoding($false)))

        # ===== Збій 7za a: старий архів живий, work прибрано =====
        [void](New-BRAVOTraceArchiveFixture -Name 'TraceSRV_20260820_235500.out' -Content 'late srv entry')
        $taBacklog5 = & $traceArchiveModule { param($d) Get-BRAVOTraceArchiveBacklog -TraceDirectory $d } $taTrace
        $taGroup20c = @($taBacklog5 | Where-Object { $_.DateKey -eq '20260820' })[0]
        $taPlan5 = & $traceArchiveModule { param($g, $z, $p) Get-BRAVOTraceArchiveUpdatePlan -BacklogGroup $g -SevenZipPath $z -ArchivePassword $p } $taGroup20c $traceArchive7za $traceArchivePassword
        $taUpdate5 = & $traceArchiveModule { param($g, $pl, $z, $ap, $p) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 } $taGroup20c $taPlan5 $traceArchive7za @('a', '-y', '-invalid-switch!!', '-p') $traceArchivePassword
        $taWorkDir = Join-Path $taTrace '.work'
        $taWorkLeftovers = if (Test-Path -LiteralPath $taWorkDir) { @(Get-ChildItem -LiteralPath $taWorkDir -File) } else { @() }
        Test-BRAVOCondition -Condition (
            [string]$taUpdate5.Status -eq 'FAILED' -and
            ([string](BRAVO.Compatibility\Get-BRAVOFileHash -Path $taGroup20.ArchivePath -Algorithm SHA512).Hash) -ceq $taHashBeforeConflict -and
            @($taWorkLeftovers).Count -eq 0 -and
            (Test-Path -LiteralPath (Join-Path $taTrace 'TraceSRV_20260820_235500.out'))
        ) -Name 'TraceArchive/SevenZipAddFailureKeepsPreviousArchive' -Failure "збій 7za a: FAILED, попередній архів байт-у-байт живий, .work прибрано, джерело лишилось; факт: $($taUpdate5.Status) leftovers=$(@($taWorkLeftovers).Count)"

        # ===== Tampered-верифікація: якщо «старий» entry нібито мав інший
        # CRC — публікація скасовується (immutability-гейт) =====
        $taTamperedPlan = [pscustomobject]@{
            ArchiveExists = $taPlan5.ArchiveExists
            ExistingEntries = @($taPlan5.ExistingEntries | ForEach-Object {
                [pscustomobject]@{ Path = $_.Path; Size = $_.Size; Crc = 'DEADBEEF'; IsDirectory = $_.IsDirectory }
            })
            NewFiles = $taPlan5.NewFiles
            DuplicateFiles = $taPlan5.DuplicateFiles
            ConflictFiles = @()
            HasConflicts = $false
            InventoryFailed = $false
            Error = $null
        }
        $taUpdate6 = & $traceArchiveModule { param($g, $pl, $z, $ap, $p) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 } $taGroup20c $taTamperedPlan $traceArchive7za $traceArchiveAddParams $traceArchivePassword
        Test-BRAVOCondition -Condition (
            [string]$taUpdate6.Status -eq 'FAILED' -and
            $taUpdate6.Error -like '*змінився*' -and
            ([string](BRAVO.Compatibility\Get-BRAVOFileHash -Path $taGroup20.ArchivePath -Algorithm SHA512).Hash) -ceq $taHashBeforeConflict
        ) -Name 'TraceArchive/PostUpdateImmutabilityCheckBlocksPublish' -Failure "розбіжність Size/CRC старого entry на контрольному inventory має скасувати публікацію (FAILED, архів попередньої версії живий)"

        # ===== Успішне поповнення після збою: без дублікатів =====
        $taPlan7 = & $traceArchiveModule { param($g, $z, $p) Get-BRAVOTraceArchiveUpdatePlan -BacklogGroup $g -SevenZipPath $z -ArchivePassword $p } $taGroup20c $traceArchive7za $traceArchivePassword
        $taUpdate7 = & $traceArchiveModule { param($g, $pl, $z, $ap, $p) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 } $taGroup20c $taPlan7 $traceArchive7za $traceArchiveAddParams $traceArchivePassword
        $taInventoryFinal = BRAVO.Compatibility\Get-BRAVOSevenZipArchiveEntries -SevenZipPath $traceArchive7za -ArchivePath $taGroup20.ArchivePath -Password $traceArchivePassword
        Test-BRAVOCondition -Condition (
            [string]$taUpdate7.Status -eq 'UPDATED' -and
            [int]$taUpdate7.AddedCount -eq 1 -and
            @($taInventoryFinal.Entries).Count -eq 4 -and
            @($taInventoryFinal.Entries | Group-Object Path | Where-Object { $_.Count -gt 1 }).Count -eq 0
        ) -Name 'TraceArchive/RetryAfterFailureAddsWithoutDuplicates' -Failure "повторний прогін після збою: додано рівно новий файл, жодного дубльованого entry (4 унікальні)"

        # ===== Orphan sweep: старий .partial прибирається, свіжий — ні =====
        [void](New-Item -ItemType Directory -Path $taWorkDir -Force)
        $taOrphanOld = Join-Path $taWorkDir 'Trace_20260819.deadbeef.partial.mdz'
        $taOrphanFresh = Join-Path $taWorkDir 'Trace_20260821.cafebabe.partial.mdz'
        [IO.File]::WriteAllText($taOrphanOld, 'old orphan')
        [IO.File]::WriteAllText($taOrphanFresh, 'fresh orphan')
        (Get-Item -LiteralPath $taOrphanOld).LastWriteTime = (Get-Date).AddHours(-72)
        $taSweptCount = & $traceArchiveModule { param($d) Clear-BRAVOTraceOrphanWorkArtifacts -TraceDirectory $d -RetentionHours 48 } $taTrace
        Test-BRAVOCondition -Condition (
            [int]$taSweptCount -eq 1 -and
            -not (Test-Path -LiteralPath $taOrphanOld) -and
            (Test-Path -LiteralPath $taOrphanFresh)
        ) -Name 'TraceArchive/OrphanWorkSweepRespectsRetention' -Failure "sweep має прибрати лише .partial старший за поріг (72h > 48h), свіжий лишити"
        Remove-Item -LiteralPath $taOrphanFresh -Force -ErrorAction SilentlyContinue
    } finally {
        if (-not [string]::IsNullOrWhiteSpace([string]$traceArchiveTestRoot) -and (Test-Path -LiteralPath $traceArchiveTestRoot)) {
            Remove-Item -LiteralPath $traceArchiveTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
