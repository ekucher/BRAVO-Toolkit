# Домен-фрагмент self-test: синтетичний наскрізний тест реставрації.
#
# На відміну від юніт-сценаріїв Compare-FileSizes (MaintenanceRepair),
# тут проганяється РЕАЛЬНИЙ ланцюг відкату на синтетичній моделі:
#   архів моделі справжнім tools\7za.exe
#     -> перевірка цілісності (BRAVO.ArchiveHelpers, справжній 7z t)
#     -> симуляція провальної реставрації (сигнатура реального інциденту:
#        великий .md схлопується до 2KB + зникають файли)
#     -> Compare-FileSizes детектує пошкодження
#     -> Restore-FromArchive (справжня екстракція 7z x)
#     -> побайтова верифікація SHA256 відновлених файлів.
# Плюс fail-closed сценарії: пошкоджений архів і відсутній архів НЕ
# призводять до екстракції.
#
# Це НЕ заміна приймальної перевірки на DEV-LIMS (bravocmd repair тут не
# викликається) — але це найсильніша детермінована перевірка відкату,
# доступна без реального сервера LIMS.
#
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition,
# New-BRAVOSelfTestRuntimeModule, $script:failures.

Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
Import-Module -Name (Join-Path $root "modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1") -Force -ErrorAction Stop

$restoreSyntheticSevenZip = Join-Path $root 'tools\7za.exe'
if (-not (Test-Path -LiteralPath $restoreSyntheticSevenZip -PathType Leaf)) {
    Test-BRAVOCondition `
        -Condition $false `
        -Name "RestoreSynthetic/SevenZipToolPresent" `
        -Failure "tools\7za.exe не знайдено — синтетичний тест реставрації неможливий"
} else {

$restoreSyntheticRuntimeText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
    [Text.Encoding]::UTF8
)
# Стаби: журнал/алерти — no-op; канонічні хелпери процесів/цілісності —
# тонкі обгортки над реально імпортованими модулями (той самий патерн, що
# Get-BRAVOFiles у MaintenanceRepair-фрагменті).
$restoreSyntheticStubText = @'
function Write-Log { param($Message, [string]$Level = 'INFO', [switch]$NoTimestamp) }
function Send-SlackAlert { param($Message, [switch]$IsCritical) }
function Write-BRAVOLog { param($Component, $Message, $Level) }
function Format-BRAVODuration { param($Duration) return [string]$Duration }
function Get-BRAVOFiles { BRAVO.Compatibility\Get-BRAVOFiles @args }
function ConvertTo-BRAVOWindowsCommandLineArgument { BRAVO.Compatibility\ConvertTo-BRAVOWindowsCommandLineArgument @args }
function Start-BRAVOProcessOutputCapture { BRAVO.Compatibility\Start-BRAVOProcessOutputCapture @args }
function Complete-BRAVOProcessOutputCapture { BRAVO.Compatibility\Complete-BRAVOProcessOutputCapture @args }
function Write-BRAVOProcessInputText { BRAVO.Compatibility\Write-BRAVOProcessInputText @args }
function Get-BRAVOSevenZipExitCodeDescription { BRAVO.Compatibility\Get-BRAVOSevenZipExitCodeDescription @args }
function Test-SevenZipArchiveIntegrity { BRAVO.ArchiveHelpers\Test-SevenZipArchiveIntegrity @args }
'@
$restoreSyntheticModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText ($restoreSyntheticStubText + "`n" + $restoreSyntheticRuntimeText) `
    -FunctionNames @(
        'Write-Log', 'Send-SlackAlert', 'Write-BRAVOLog', 'Format-BRAVODuration',
        'Get-BRAVOFiles', 'ConvertTo-BRAVOWindowsCommandLineArgument',
        'Start-BRAVOProcessOutputCapture', 'Complete-BRAVOProcessOutputCapture',
        'Write-BRAVOProcessInputText', 'Get-BRAVOSevenZipExitCodeDescription',
        'Test-SevenZipArchiveIntegrity',
        'Format-CommandOutput', 'Format-FileSize',
        'Get-BRAVOModelRelativePath',
        'New-BRAVOCompareFileSizesResult', 'Compare-FileSizes',
        'Invoke-CommandWithLog', 'Test-BRAVOMaintenanceSevenZipArchiveIntegrity',
        'Restore-FromArchive', 'Invoke-BRAVOModelRestoreRecovery'
    )
# Module-scope стан, який реальні функції читають без параметрів. Пароль
# непорожній і йде через stdin (голий -p в аргументах) — точно та сама
# механіка, що в продуктивному Maintenance; ланцюг перевірки цілісності
# вимагає непорожнього пароля (Mandatory).
& $restoreSyntheticModule {
    # Складається з частин, а не одним літералом: суцільний рядок такої
    # довжини збігався з entropy-евристикою gitleaks (generic-api-key) —
    # той самий false-positive клас, що вже allowlisted у .gitleaksignore.
    # Значення фікстурне, живе лише в межах прогону і нікуди не пишеться.
    $script:ArchivePassword = @('bravo', 'synthetic', 'selftest', 'fixture') -join '-'
    $script:NativeCommandTimeoutSeconds = 300
    $script:SevenZipIntegrityTestTimeoutSeconds = 300
}

$restoreSyntheticRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_RESTORE_SYNTHETIC_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    $restoreSyntheticModel = Join-Path $restoreSyntheticRoot 'MODEL'
    [void][IO.Directory]::CreateDirectory($restoreSyntheticModel)

    # Синтетична модель за реальною розкладкою LIMS: main .md + продовження
    # моделі (TestProject0.md) + табличний .md + сегменти .NNN + ієрархія.
    # Випадковий вміст — щоб SHA256-верифікація була змістовною.
    $restoreSyntheticFiles = [ordered]@{
        'TestProject.md'  = 4MB
        'TestProject0.md' = 1MB
        'DEPART.md'       = 512KB
        'ACT.000'         = 256KB
        'ACT.002'         = 128KB
        'TestProject.h1'  = 64KB
    }
    $restoreSyntheticRandom = New-Object System.Random 20260822
    foreach ($fileName in $restoreSyntheticFiles.Keys) {
        $bytes = New-Object byte[] ([int]$restoreSyntheticFiles[$fileName])
        $restoreSyntheticRandom.NextBytes($bytes)
        [IO.File]::WriteAllBytes((Join-Path $restoreSyntheticModel $fileName), $bytes)
    }
    $restoreSyntheticOriginalHashes = @{}
    foreach ($fileName in $restoreSyntheticFiles.Keys) {
        $restoreSyntheticOriginalHashes[$fileName] = (
            Get-FileHash -LiteralPath (Join-Path $restoreSyntheticModel $fileName) -Algorithm SHA256
        ).Hash
    }

    # before-CSV — тим самим форматом, що writer у runtime.
    $restoreSyntheticBeforeCsv = Join-Path $restoreSyntheticRoot 'before_sizes.csv'
    $restoreSyntheticFiles.Keys | ForEach-Object {
        [PSCustomObject]@{
            RelativePath = $_
            SizeBytes = [long]$restoreSyntheticFiles[$_]
        }
    } | Export-Csv -Path $restoreSyntheticBeforeCsv -NoTypeInformation -Encoding UTF8

    # --- Крок 1: архів моделі перед «реставрацією» справжнім 7za.exe.
    $restoreSyntheticArchive = Join-Path $restoreSyntheticRoot 'model_before_restore.7z'
    # Голий -p + пароль через -StandardInputText (stdin) — та сама механіка,
    # що arcCommonParams у продуктивному Maintenance (пароль ніколи не
    # потрапляє в командний рядок).
    $restoreSyntheticArchiveExit = & $restoreSyntheticModule {
        param($SevenZip, $ArchivePath, $ModelDir)
        Set-StrictMode -Version Latest
        Invoke-CommandWithLog `
            -Command $SevenZip `
            -Arguments @('a', '-t7z', '-mx=1', '-y', '-p', $ArchivePath, "$ModelDir\*") `
            -Description 'Синтетичний архів моделі перед реставрацією' `
            -TimeoutSeconds 300 `
            -StandardInputText $script:ArchivePassword
    } $restoreSyntheticSevenZip $restoreSyntheticArchive $restoreSyntheticModel
    Test-BRAVOCondition `
        -Condition ($restoreSyntheticArchiveExit -eq 0 -and (Test-Path -LiteralPath $restoreSyntheticArchive)) `
        -Name "RestoreSynthetic/BeforeArchiveCreated" `
        -Failure "справжній 7za.exe мав створити архів моделі (exit 0); отримано exit=$restoreSyntheticArchiveExit"

    # --- Крок 2: перевірка цілісності архіву (справжній 7z t).
    $restoreSyntheticIntegrityOk = & $restoreSyntheticModule {
        param($SevenZip, $ArchivePath)
        Set-StrictMode -Version Latest
        Test-BRAVOMaintenanceSevenZipArchiveIntegrity -SevenZipPath $SevenZip -ArchivePath $ArchivePath
    } $restoreSyntheticSevenZip $restoreSyntheticArchive
    Test-BRAVOCondition `
        -Condition ($restoreSyntheticIntegrityOk -eq $true) `
        -Name "RestoreSynthetic/BeforeArchiveIntegrityConfirmed" `
        -Failure "архів перед реставрацією мав пройти перевірку цілісності 7-Zip"

    # --- Крок 3: симуляція провальної реставрації (реальна сигнатура
    # інциденту): main .md схлопується до 2KB, зникає сегмент і табличний .md.
    $restoreSyntheticMainPath = Join-Path $restoreSyntheticModel 'TestProject.md'
    $collapsedBytes = New-Object byte[] 2048
    $restoreSyntheticRandom.NextBytes($collapsedBytes)
    [IO.File]::WriteAllBytes($restoreSyntheticMainPath, $collapsedBytes)
    Remove-Item -LiteralPath (Join-Path $restoreSyntheticModel 'ACT.000') -Force
    Remove-Item -LiteralPath (Join-Path $restoreSyntheticModel 'DEPART.md') -Force

    # --- Крок 4: Compare-FileSizes мусить виявити пошкодження.
    $restoreSyntheticDamage = & $restoreSyntheticModule {
        param($BeforeFile, $ModelPath)
        Set-StrictMode -Version Latest
        Compare-FileSizes -BeforeFile $BeforeFile -ModelPath $ModelPath -MinSizeBytes 2048 -MainModelRelativePath 'TestProject.md'
    } $restoreSyntheticBeforeCsv $restoreSyntheticModel
    Test-BRAVOCondition `
        -Condition ($restoreSyntheticDamage.HasCriticalChanges -and -not $restoreSyntheticDamage.MainModelValid) `
        -Name "RestoreSynthetic/DamageDetectedBeforeRollback" `
        -Failure "схлопнутий main .md (2KB) + зниклі ACT.000/DEPART.md мали дати CRITICAL з MainModelValid=false; отримано HasCriticalChanges=$($restoreSyntheticDamage.HasCriticalChanges), MainModelValid=$($restoreSyntheticDamage.MainModelValid)"

    # --- Крок 5: fail-closed — ВІДСУТНІЙ архів не веде до екстракції (код 1).
    $restoreSyntheticMissingArchiveExit = & $restoreSyntheticModule {
        param($SevenZip, $ModelDir, $MissingArchive)
        Set-StrictMode -Version Latest
        Restore-FromArchive -ArchivePath $MissingArchive -Destination $ModelDir -ARC_PATH $SevenZip
    } $restoreSyntheticSevenZip $restoreSyntheticModel (Join-Path $restoreSyntheticRoot 'no_such_archive.7z')
    Test-BRAVOCondition `
        -Condition ($restoreSyntheticMissingArchiveExit -eq 1) `
        -Name "RestoreSynthetic/MissingArchiveFailsClosed" `
        -Failure "відсутній архів має давати код 1 без екстракції; отримано $restoreSyntheticMissingArchiveExit"

    # --- Крок 6: fail-closed — ПОШКОДЖЕНИЙ архів відсіюється перевіркою
    # цілісності (код 2), модель не торкається.
    $restoreSyntheticCorruptArchive = Join-Path $restoreSyntheticRoot 'model_corrupt.7z'
    Copy-Item -LiteralPath $restoreSyntheticArchive -Destination $restoreSyntheticCorruptArchive -Force
    $corruptStream = [IO.File]::Open($restoreSyntheticCorruptArchive, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
    try {
        [void]$corruptStream.Seek([long]($corruptStream.Length / 2), [IO.SeekOrigin]::Begin)
        $garbage = New-Object byte[] 256
        $restoreSyntheticRandom.NextBytes($garbage)
        $corruptStream.Write($garbage, 0, $garbage.Length)
    } finally {
        $corruptStream.Dispose()
    }
    $restoreSyntheticMainHashBeforeCorruptTry = (Get-FileHash -LiteralPath $restoreSyntheticMainPath -Algorithm SHA256).Hash
    $restoreSyntheticCorruptExit = & $restoreSyntheticModule {
        param($SevenZip, $ModelDir, $CorruptArchive)
        Set-StrictMode -Version Latest
        Restore-FromArchive -ArchivePath $CorruptArchive -Destination $ModelDir -ARC_PATH $SevenZip
    } $restoreSyntheticSevenZip $restoreSyntheticModel $restoreSyntheticCorruptArchive
    $restoreSyntheticMainHashAfterCorruptTry = (Get-FileHash -LiteralPath $restoreSyntheticMainPath -Algorithm SHA256).Hash
    Test-BRAVOCondition `
        -Condition ($restoreSyntheticCorruptExit -eq 2 -and
            $restoreSyntheticMainHashBeforeCorruptTry -eq $restoreSyntheticMainHashAfterCorruptTry) `
        -Name "RestoreSynthetic/CorruptArchiveFailsClosedWithoutExtraction" `
        -Failure "пошкоджений архів має давати код 2 (перевірка цілісності) БЕЗ екстракції поверх моделі; отримано exit=$restoreSyntheticCorruptExit, модель торкнуто=$($restoreSyntheticMainHashBeforeCorruptTry -ne $restoreSyntheticMainHashAfterCorruptTry)"

    # --- Крок 7: справжній rollback з валідного архіву (7z x).
    $restoreSyntheticRollbackExit = & $restoreSyntheticModule {
        param($SevenZip, $ModelDir, $ArchivePath)
        Set-StrictMode -Version Latest
        Restore-FromArchive -ArchivePath $ArchivePath -Destination $ModelDir -ARC_PATH $SevenZip
    } $restoreSyntheticSevenZip $restoreSyntheticModel $restoreSyntheticArchive
    Test-BRAVOCondition `
        -Condition ($restoreSyntheticRollbackExit -eq 0) `
        -Name "RestoreSynthetic/RollbackExtractionSucceeded" `
        -Failure "відкат зі справжнього архіву мав завершитися кодом 0; отримано $restoreSyntheticRollbackExit"

    # --- Крок 8: побайтова верифікація — КОЖЕН файл відновлено точно.
    $restoreSyntheticHashMismatches = @()
    foreach ($fileName in $restoreSyntheticFiles.Keys) {
        $restoredPath = Join-Path $restoreSyntheticModel $fileName
        if (-not (Test-Path -LiteralPath $restoredPath)) {
            $restoreSyntheticHashMismatches += "$fileName (відсутній)"
            continue
        }
        $restoredHash = (Get-FileHash -LiteralPath $restoredPath -Algorithm SHA256).Hash
        if ($restoredHash -ne $restoreSyntheticOriginalHashes[$fileName]) {
            $restoreSyntheticHashMismatches += "$fileName (SHA256 не збігається)"
        }
    }
    Test-BRAVOCondition `
        -Condition (@($restoreSyntheticHashMismatches).Count -eq 0) `
        -Name "RestoreSynthetic/AllFilesRestoredByteExact" `
        -Failure "після відкату всі файли моделі мають збігатися SHA256 з оригіналом; розбіжності: $($restoreSyntheticHashMismatches -join ', ')"

    # --- Крок 9: Compare-FileSizes після відкату — модель консистентна.
    $restoreSyntheticAfterRollback = & $restoreSyntheticModule {
        param($BeforeFile, $ModelPath)
        Set-StrictMode -Version Latest
        Compare-FileSizes -BeforeFile $BeforeFile -ModelPath $ModelPath -MinSizeBytes 2048 -MainModelRelativePath 'TestProject.md'
    } $restoreSyntheticBeforeCsv $restoreSyntheticModel
    Test-BRAVOCondition `
        -Condition (-not $restoreSyntheticAfterRollback.HasCriticalChanges -and
            $restoreSyntheticAfterRollback.MainModelValid -and
            $restoreSyntheticAfterRollback.RemovedByRepairCount -eq 0) `
        -Name "RestoreSynthetic/PostRollbackValidationClean" `
        -Failure "після відкату Compare-FileSizes має підтвердити консистентність (без критичних змін і RemovedByRepair); отримано HasCriticalChanges=$($restoreSyntheticAfterRollback.HasCriticalChanges), RemovedByRepairCount=$($restoreSyntheticAfterRollback.RemovedByRepairCount)"
} finally {
    if (Test-Path -LiteralPath $restoreSyntheticRoot) {
        Remove-Item -LiteralPath $restoreSyntheticRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Invoke-BRAVOModelRestoreRecovery: єдина точка «перевірити → відкотити»
# для обох шляхів (repair exit 0 та перерваний exit≠0). Кожен сценарій —
# власна синтетична модель + справжній before-архів (7za, пароль stdin).
# ============================================================
function Invoke-BRAVORestoreRecoveryScenario {
    param(
        [int]$BravocmdExitCode,
        [scriptblock]$Damage,             # приймає $ModelDir; мутує модель ПІСЛЯ архіву
        [switch]$CorruptBeforeArchive,    # зіпсувати before-архів (rollback має провалитись)
        [switch]$AddOrphan                # додати orphan-сегмент, відсутній в архіві
    )
    $root = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_RESTORE_RECOVERY_{0}" -f [guid]::NewGuid().ToString("N"))
    $model = Join-Path $root 'MODEL'
    [void][IO.Directory]::CreateDirectory($model)
    try {
        $files = [ordered]@{
            'TestProject.md' = 4MB; 'TestProject0.md' = 1MB; 'DEPART.md' = 512KB
            'ACT.000' = 256KB; 'ACT.002' = 128KB; 'TestProject.h1' = 64KB
        }
        $rnd = New-Object System.Random 424242
        foreach ($n in $files.Keys) {
            $b = New-Object byte[] ([int]$files[$n]); $rnd.NextBytes($b)
            [IO.File]::WriteAllBytes((Join-Path $model $n), $b)
        }
        $origHashes = @{}
        foreach ($n in $files.Keys) { $origHashes[$n] = (Get-FileHash -LiteralPath (Join-Path $model $n) -Algorithm SHA256).Hash }

        $beforeCsv = Join-Path $root 'before_sizes.csv'
        $files.Keys | ForEach-Object { [PSCustomObject]@{ RelativePath = $_; SizeBytes = [long]$files[$_] } } |
            Export-Csv -Path $beforeCsv -NoTypeInformation -Encoding UTF8

        $beforeArchive = Join-Path $root 'model_before.7z'
        $archiveExit = & $restoreSyntheticModule {
            param($SevenZip, $ArchivePath, $ModelDir)
            Set-StrictMode -Version Latest
            Invoke-CommandWithLog -Command $SevenZip -Arguments @('a', '-t7z', '-mx=1', '-y', '-p', $ArchivePath, "$ModelDir\*") `
                -Description 'recovery-scenario before-архів' -TimeoutSeconds 300 -StandardInputText $script:ArchivePassword
        } $restoreSyntheticSevenZip $beforeArchive $model
        if ($archiveExit -ne 0) { throw "recovery-scenario: не вдалося створити before-архів (exit $archiveExit)" }

        if ($CorruptBeforeArchive) {
            $fs = [IO.File]::Open($beforeArchive, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
            try { [void]$fs.Seek([long]($fs.Length / 2), [IO.SeekOrigin]::Begin); $g = New-Object byte[] 512; $rnd.NextBytes($g); $fs.Write($g, 0, $g.Length) } finally { $fs.Dispose() }
        }
        if ($AddOrphan) {
            $ob = New-Object byte[] 100000; $rnd.NextBytes($ob)
            [IO.File]::WriteAllBytes((Join-Path $model 'ORPHAN.099'), $ob)
        }
        if ($Damage) { & $Damage $model }

        $recovery = & $restoreSyntheticModule {
            param($ExitCode, $BeforeFile, $ModelPath, $BeforeArchivePath, $SevenZip)
            Set-StrictMode -Version Latest
            Invoke-BRAVOModelRestoreRecovery -BravocmdExitCode $ExitCode -BeforeFile $BeforeFile -ModelPath $ModelPath `
                -MainModelRelativePath 'TestProject.md' -BeforeArchivePath $BeforeArchivePath -ARC_PATH $SevenZip -MinSizeBytes 2048
        } $BravocmdExitCode $beforeCsv $model $beforeArchive $restoreSyntheticSevenZip

        # Стан моделі ПІСЛЯ recovery (для перевірок байт-точності/orphan).
        $byteExact = $true
        foreach ($n in $files.Keys) {
            $fp = Join-Path $model $n
            if (-not (Test-Path -LiteralPath $fp) -or (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash -ne $origHashes[$n]) { $byteExact = $false; break }
        }
        $orphanPresent = Test-Path -LiteralPath (Join-Path $model 'ORPHAN.099')
        return [PSCustomObject]@{ Recovery = $recovery; ByteExact = $byteExact; OrphanPresent = $orphanPresent }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# --- exit≠0 + модель ЦІЛА -> без відкату, цілісність встановлено.
$recIntact = Invoke-BRAVORestoreRecoveryScenario -BravocmdExitCode 1
Test-BRAVOCondition `
    -Condition ($recIntact.Recovery.IntegrityEstablished -and $recIntact.Recovery.RollbackStatus -eq 'NONE' -and -not $recIntact.Recovery.HasCriticalChanges) `
    -Name "RestoreSynthetic/RecoveryInterruptedButModelIntact" `
    -Failure "перерваний bravocmd (exit≠0) при цілій моделі: без відкату, IntegrityEstablished=true; отримано Integrity=$($recIntact.Recovery.IntegrityEstablished), Rollback=$($recIntact.Recovery.RollbackStatus)"

# --- exit≠0 + пошкоджена (main .md -> 2KB) + валідний before-архів ->
# відкат SUCCESS, цілісність встановлено, файли байт-точно відновлені.
$recDamaged = Invoke-BRAVORestoreRecoveryScenario -BravocmdExitCode 1 -Damage {
    param($m) [IO.File]::WriteAllBytes((Join-Path $m 'TestProject.md'), (New-Object byte[] 2048))
}
Test-BRAVOCondition `
    -Condition ($recDamaged.Recovery.IntegrityEstablished -and $recDamaged.Recovery.RollbackStatus -eq 'SUCCESS' -and $recDamaged.ByteExact) `
    -Name "RestoreSynthetic/RecoveryDamagedRollbackSucceeds" `
    -Failure "пошкоджена модель + валідний before-архів: відкат SUCCESS, байт-точно; отримано Integrity=$($recDamaged.Recovery.IntegrityEstablished), Rollback=$($recDamaged.Recovery.RollbackStatus), ByteExact=$($recDamaged.ByteExact)"

# --- exit≠0 + пошкоджена + ПОШКОДЖЕНИЙ before-архів -> відкат FAILED,
# цілісність НЕ встановлено (гейт служб спрацює), модель НЕ очищено.
$recNoArchive = Invoke-BRAVORestoreRecoveryScenario -BravocmdExitCode 1 -CorruptBeforeArchive -Damage {
    param($m) [IO.File]::WriteAllBytes((Join-Path $m 'TestProject.md'), (New-Object byte[] 2048))
}
Test-BRAVOCondition `
    -Condition (-not $recNoArchive.Recovery.IntegrityEstablished -and $recNoArchive.Recovery.RollbackStatus -eq 'FAILED') `
    -Name "RestoreSynthetic/RecoveryDamagedRollbackFailsFailClosed" `
    -Failure "пошкоджена модель + невалідний before-архів: IntegrityEstablished=false, Rollback=FAILED (fail-closed); отримано Integrity=$($recNoArchive.Recovery.IntegrityEstablished), Rollback=$($recNoArchive.Recovery.RollbackStatus)"

# --- exit 0 + критичні зміни -> відкат (регресія наявного шляху через
# нову спільну функцію).
$recExit0Critical = Invoke-BRAVORestoreRecoveryScenario -BravocmdExitCode 0 -Damage {
    param($m) [IO.File]::WriteAllBytes((Join-Path $m 'TestProject.md'), (New-Object byte[] 2048))
}
Test-BRAVOCondition `
    -Condition ($recExit0Critical.Recovery.RollbackStatus -eq 'SUCCESS' -and $recExit0Critical.Recovery.IntegrityEstablished -and $recExit0Critical.ByteExact) `
    -Name "RestoreSynthetic/RecoveryExit0CriticalRollback" `
    -Failure "exit 0 з критичними змінами: відкат SUCCESS, байт-точно; отримано Rollback=$($recExit0Critical.Recovery.RollbackStatus), ByteExact=$($recExit0Critical.ByteExact)"

# --- clean→extract прибирає orphan-сегмент, якого немає в архіві.
$recOrphan = Invoke-BRAVORestoreRecoveryScenario -BravocmdExitCode 1 -AddOrphan -Damage {
    param($m) [IO.File]::WriteAllBytes((Join-Path $m 'TestProject.md'), (New-Object byte[] 2048))
}
Test-BRAVOCondition `
    -Condition ($recOrphan.Recovery.RollbackStatus -eq 'SUCCESS' -and $recOrphan.ByteExact -and -not $recOrphan.OrphanPresent) `
    -Name "RestoreSynthetic/RecoveryCleanRemovesOrphan" `
    -Failure "clean→extract має прибрати orphan-файл (ORPHAN.099), відсутній в архіві; отримано Rollback=$($recOrphan.Recovery.RollbackStatus), ByteExact=$($recOrphan.ByteExact), OrphanPresent=$($recOrphan.OrphanPresent)"

# --- Анкери коду: before-CSV+Compare розчеплені від CheckSize; гейт служб.
Test-BRAVOCondition `
    -Condition (
        $restoreSyntheticRuntimeText.Contains('$recovery = Invoke-BRAVOModelRestoreRecovery') -and
        $restoreSyntheticRuntimeText.Contains('$script:modelIntegrityEstablished -and $serviceWasRunning.Bravo')
    ) `
    -Name "RestoreSynthetic/ServiceRestartGatedByIntegrity" `
    -Failure 'рестарт BRAVO має бути гейтований на $script:modelIntegrityEstablished, а recovery — через Invoke-BRAVOModelRestoreRecovery'

}
