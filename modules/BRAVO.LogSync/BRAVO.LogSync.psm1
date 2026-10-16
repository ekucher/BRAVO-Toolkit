# #364: синхронізація дозволених runtime-журналів BRAVO на SFTP.
#
# Призначення: вивантажувати ЛИШЕ явно дозволені (allowlist, нерекурсивно)
# журнали з каталогу LOGS на SFTP, не втрачаючи локальні файли і не
# впливаючи на цілісність основної операції Maintenance при збої одного
# файлу. Замінює підхід закритого без merge PR #332 (issue #364):
# - пропуск за однаковим РОЗМІРОМ замінено на ledger (Size+LastWriteTimeUtc
#   разом) — перезапис тієї самої довжини з НОВИМ mtime більше не
#   пропускається мовчки;
# - жодного рекурсивного вивантаження всього LOGS — лише 4 явні шаблони
#   імені (без HELPERS/CSV);
# - без $global:/$script: — усі залежності явними параметрами, сумісно з
#   Windows PowerShell 5.1 (#requires -Version 3.0, як інші shared-модулі).
#
# Дизайн (owner-approved пакет рішень, 2026-10-16):
#   1. Allowlist: BRAVO_MAINTENANCE_*.log, BRAVO_ARCHIV_*.log,
#      BRAVO_DATA_RESTORE_*.log, script_log_*.txt. Нічого іншого.
#   2. Окремий тумблер (componentSettings.SFTP.RuntimeLogSyncEnabled),
#      дефолт $false для наявних установок.
#   3. Retention на віддаленому боці — НЕ реалізовано цим issue; відомий,
#      свідомо задокументований gap (issue #364, розділ "Рішення власника").
#   4. Сегмент хоста у віддаленому шляху — відповідальність ВИКЛИКАЧА
#      (Maintenance передає вже побудований $RemoteDirectory з
#      $env:COMPUTERNAME); цей модуль шляхів не нормалізує сам.
#   5. Exit code при збої вивантаження — відповідальність ВИКЛИКАЧА
#      (Write-Log -Level WARNING у Maintenance — наявний канонічний шлях
#      до SuccessWithWarnings(10), без нового коду виходу тут).
#
# Транспорт (SFTP-сесія, маскування, фактична передача файлу) НЕ належить
# цьому модулю — WinSCP-сесія й Connect-BRAVOOwnLogSftpSession/
# Send-BRAVOOwnLogFile/New-BRAVOMaskedLogCopy живуть у
# BRAVO.Maintenance.Runtime.ps1/BRAVO.Logging (не є importable-модулями чи
# мають виклик-специфічний стан). Invoke-BRAVOLogSyncRun приймає їх як
# ін'єктовані scriptblock-и — той самий ідіом ін'єкції, що $NowProvider у
# Test-BRAVORestoreExecutionStillAllowed (BRAVO.Maintenance.Runtime.ps1).

function Test-BRAVOLogSyncAllowlistMatch {
    # Чиста функція: ім'я файлу (без шляху) -> дозволено чи ні. Явний,
    # нерекурсивний allowlist (рішення власника #1) — НІЧОГО, крім цих 4
    # шаблонів, не йде на SFTP через цей шлях, зокрема НЕ HELPERS,
    # НЕ file_sizes_*.csv, НЕ маркери/lock-файли/self-test fixtures.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$FileName)

    if ([string]::IsNullOrWhiteSpace($FileName)) { return $false }
    $patterns = @(
        '^BRAVO_MAINTENANCE_.*\.log$',
        '^BRAVO_ARCHIV_.*\.log$',
        '^BRAVO_DATA_RESTORE_.*\.log$',
        '^script_log_.*\.txt$'
    )
    foreach ($pattern in $patterns) {
        if ($FileName -imatch $pattern) { return $true }
    }
    return $false
}

function Get-BRAVOLogSyncLocalSnapshot {
    # Нерекурсивний перелік $LogsDirectory, звужений до allowlist. Один
    # прохід .NET-переліку (той самий підхід, що Get-BRAVOBazaLocalSnapshot,
    # BRAVO.BazaSync) — не Get-ChildItem provider layer.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LogsDirectory)

    $entries = @{}
    if (-not [IO.Directory]::Exists($LogsDirectory)) {
        return [pscustomobject]@{ Success = $false; Error = "каталог не знайдено: $LogsDirectory"; Entries = $entries }
    }
    try {
        $directoryInfo = New-Object IO.DirectoryInfo($LogsDirectory)
        foreach ($file in $directoryInfo.EnumerateFiles('*', [IO.SearchOption]::TopDirectoryOnly)) {
            if (-not (Test-BRAVOLogSyncAllowlistMatch -FileName $file.Name)) { continue }
            if (([int]$file.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)) -ne 0) {
                continue
            }
            $entries[$file.Name] = [pscustomobject]@{
                FileName = $file.Name
                Size = [int64]$file.Length
                LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
                FullPath = $file.FullName
            }
        }
        return [pscustomobject]@{ Success = $true; Error = $null; Entries = $entries }
    } catch {
        return [pscustomobject]@{ Success = $false; Error = $_.Exception.Message; Entries = $entries }
    }
}

$script:BRAVOLogSyncLedgerSchemaVersion = 1

function Get-BRAVOLogSyncLedgerPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    return (Join-Path $StateRoot 'LOGSYNC\ledger.json')
}

function Read-BRAVOLogSyncLedger {
    # StrictMode-безпечна, керована відповідь — той самий принцип, що
    # Read-BRAVOBazaState: відсутній файл — легітимний перший запуск
    # (Exists=$false), пошкоджений — Corrupt=$true (викликач вирішує, чи
    # починати з порожнього ledger; тут — завжди так, бо повторне
    # вивантаження вже наявного на SFTP файлу нешкідливе, лише надлишкове).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $path = Get-BRAVOLogSyncLedgerPath -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Corrupt = $false; Files = @{} }
    }
    try {
        $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [pscustomobject]@{ Exists = $true; Corrupt = $true; Files = @{} }
        }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed.SchemaVersion -or [int]$parsed.SchemaVersion -ne $script:BRAVOLogSyncLedgerSchemaVersion) {
            return [pscustomobject]@{ Exists = $true; Corrupt = $true; Files = @{} }
        }
        $files = @{}
        if ($null -ne $parsed.Files) {
            foreach ($property in $parsed.Files.PSObject.Properties) {
                $files[$property.Name] = $property.Value
            }
        }
        return [pscustomobject]@{ Exists = $true; Corrupt = $false; Files = $files }
    } catch {
        return [pscustomobject]@{ Exists = $true; Corrupt = $true; Files = @{} }
    }
}

function Write-BRAVOLogSyncLedger {
    # Atomic write: temp -> Move/Replace (той самий прийом, що
    # Save-BRAVOBazaState) — переривання посеред запису не сміє лишити
    # пошкоджений ledger поверх валідного попереднього.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][hashtable]$Files
    )

    $path = Get-BRAVOLogSyncLedgerPath -StateRoot $StateRoot
    $directory = Split-Path -Path $path -Parent
    if (-not [IO.Directory]::Exists($directory)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    $serializable = [ordered]@{
        SchemaVersion = $script:BRAVOLogSyncLedgerSchemaVersion
        Files = $Files
    }
    $temporaryPath = Join-Path $directory ('.ledger_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $backupPath = Join-Path $directory ('.ledger_{0}.bak' -f [guid]::NewGuid().ToString('N'))
    $replaced = $false
    try {
        $json = $serializable | ConvertTo-Json -Depth 6 -Compress
        [IO.File]::WriteAllText($temporaryPath, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($path)) {
            [IO.File]::Replace($temporaryPath, $path, $backupPath)
            $replaced = $true
        } else {
            [IO.File]::Move($temporaryPath, $path)
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
        if ($replaced -and [IO.File]::Exists($backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-BRAVOLogSyncPlan {
    # Чиста функція: знімок + ledger -> план. Жодного I/O.
    #
    # На відміну від Get-BRAVOBazaSyncPlan (BRAVO.BazaSync, незмінні
    # BAZA-архіви — зміна Verified-файлу це "mutation violation", потребує
    # ручного рішення), журнали ЗАВЖДИ мутують (дозапис/ротація) — це
    # нормальна поведінка, не аномалія. Тому рішення просте: немає в
    # ledger, АБО Size/LastWriteTimeUtc відрізняється від ledger -> у
    # ToUpload. Саме це закриває дефект закритого PR #332 (пропуск за
    # однаковим розміром): перезапис тієї самої довжини з новим mtime тут
    # дає mtimeChanged=true -> ToUpload, а не TrustedSkip.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][object]$Ledger
    )

    $toUpload = New-Object System.Collections.Generic.List[object]
    $upToDate = New-Object System.Collections.Generic.List[object]
    foreach ($fileName in ($Snapshot.Entries.Keys | Sort-Object)) {
        $localEntry = $Snapshot.Entries[$fileName]
        $ledgerEntry = $Ledger.Files[$fileName]
        if ($null -eq $ledgerEntry) {
            $toUpload.Add($localEntry)
            continue
        }
        $sizeChanged = ([int64]$ledgerEntry.Size -ne $localEntry.Size)
        $mtimeChanged = ([string]$ledgerEntry.LastWriteTimeUtc -cne [string]$localEntry.LastWriteTimeUtc)
        if ($sizeChanged -or $mtimeChanged) {
            $toUpload.Add($localEntry)
        } else {
            $upToDate.Add($localEntry)
        }
    }
    return [pscustomobject]@{
        ToUpload = $toUpload.ToArray()
        UpToDate = $upToDate.ToArray()
    }
}

function Invoke-BRAVOLogSyncRun {
    # Оркестрація: знімок -> план -> бюджетований цикл вивантаження, з
    # ізоляцією збою ОДНОГО файлу (не впливає на решту) і зупинкою при
    # розриві сесії чи вичерпанні бюджету (час/обсяг/кількість) — решта
    # лишається у ToUpload для наступного прогону (ledger для них не
    # оновлюється). Транспорт (маскування, фактична передача,
    # перевірка здоров'я сесії) — ін'єктовані scriptblock-и від
    # викликача; цей модуль їх не визначає (BRAVO.Maintenance.Runtime.ps1
    # не є importable-модулем, BRAVO.Logging — маскування, окрема залежність
    # лишається явною на боці викликача, не тут).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LogsDirectory,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$RemoteDirectory,
        # param($LocalPath) -> маскована копія (шлях до тимчасового файлу);
        # викликач відповідає за прибирання — Invoke-BRAVOLogSyncRun сам
        # прибирає кожну копію через $RemoveMaskedCopy одразу після спроби.
        [Parameter(Mandatory = $true)][scriptblock]$MaskFile,
        [Parameter(Mandatory = $true)][scriptblock]$RemoveMaskedCopy,
        # param($LocalPath, $RemoteDirectory, $RemoteFileName) ->
        # [pscustomobject]@{ Success = [bool]; Error = [string] }
        [Parameter(Mandatory = $true)][scriptblock]$UploadFile,
        # Перевірка «сесія ще жива» МІЖ файлами — розрив на середині
        # прогону зупиняє цикл одразу, а не retry-штормом на кожному
        # наступному файлі (ledger лишається точним для часткового прогону).
        [scriptblock]$IsSessionHealthy = { $true },
        [int]$MaxFiles = 20,
        [long]$MaxTotalBytes = 104857600,
        [int]$MaxDurationSeconds = 300,
        [scriptblock]$NowProvider = { Get-Date }
    )

    $result = [pscustomobject]@{
        Success = $true
        Error = $null
        Attempted = 0
        Uploaded = 0
        Failed = 0
        BudgetExhausted = $false
        SessionBroke = $false
        Errors = New-Object System.Collections.Generic.List[string]
        # Review (P1): файл, що сам перевищує MaxTotalBytes, раніше ламав
        # УВЕСЬ цикл (break), а оскільки план сортується за іменем, цей
        # самий файл назавжди лишався б першим і назавжди блокував би всі
        # алфавітно пізніші файли від вивантаження в БУДЬ-якому майбутньому
        # прогоні -- постійна голодовка, не просто обмеження одного прогону.
        # Такий файл пропускається (не рахується як Failed, не ставить
        # BudgetExhausted), а цикл іде далі.
        OversizedSkipped = New-Object System.Collections.Generic.List[string]
    }

    $snapshot = Get-BRAVOLogSyncLocalSnapshot -LogsDirectory $LogsDirectory
    if (-not $snapshot.Success) {
        $result.Success = $false
        $result.Error = $snapshot.Error
        return $result
    }
    $ledger = Read-BRAVOLogSyncLedger -StateRoot $StateRoot
    # Пошкоджений ledger -> починаємо з порожнього: повторне вивантаження
    # вже наявного на SFTP файлу нешкідливе (лише надлишкове мережеве
    # вивантаження), а НЕ починати через пошкоджений файл стану — гірше
    # (журнали взагалі ніколи не синхронізувались би).
    $ledgerFiles = @{}
    foreach ($key in $ledger.Files.Keys) { $ledgerFiles[$key] = $ledger.Files[$key] }

    $plan = Get-BRAVOLogSyncPlan -Snapshot $snapshot -Ledger ([pscustomobject]@{ Files = $ledgerFiles })

    $startedAt = & $NowProvider
    $totalBytesThisRun = [int64]0
    foreach ($entry in $plan.ToUpload) {
        $elapsedSeconds = ((& $NowProvider) - $startedAt).TotalSeconds
        if ($elapsedSeconds -ge $MaxDurationSeconds) {
            $result.BudgetExhausted = $true
            break
        }
        if ($result.Attempted -ge $MaxFiles) {
            $result.BudgetExhausted = $true
            break
        }
        if ($entry.Size -gt $MaxTotalBytes) {
            # Цей файл сам більший за весь бюджет -- ніколи не влізе,
            # скільки прогонів не чекай. Пропускаємо саме його, не весь
            # прогін (інакше він назавжди блокував би алфавітно пізніші
            # файли -- саме той дефект, який цей фікс усуває).
            [void]$result.OversizedSkipped.Add($entry.FileName)
            continue
        }
        if (($totalBytesThisRun + $entry.Size) -gt $MaxTotalBytes) {
            $result.BudgetExhausted = $true
            break
        }
        if (-not (& $IsSessionHealthy)) {
            $result.SessionBroke = $true
            break
        }

        $result.Attempted++
        $maskedPath = $null
        try {
            $maskedPath = & $MaskFile $entry.FullPath
            $uploadOutcome = & $UploadFile $maskedPath $RemoteDirectory $entry.FileName
            if ($null -ne $uploadOutcome -and [bool]$uploadOutcome.Success) {
                $ledgerFiles[$entry.FileName] = [pscustomobject]@{
                    Size = $entry.Size
                    LastWriteTimeUtc = $entry.LastWriteTimeUtc
                    UploadedUtc = ((& $NowProvider).ToUniversalTime().ToString('o'))
                }
                $totalBytesThisRun += $entry.Size
                $result.Uploaded++
                # Інкрементальний запис: збій ПІСЛЯ цього файлу (крах,
                # розрив сесії) не сміє втратити вже підтверджений прогрес
                # — наступний прогін не повторить те, що вже дійшло.
                Write-BRAVOLogSyncLedger -StateRoot $StateRoot -Files $ledgerFiles
            } else {
                $result.Failed++
                $errorText = if ($null -ne $uploadOutcome -and -not [string]::IsNullOrWhiteSpace([string]$uploadOutcome.Error)) {
                    [string]$uploadOutcome.Error
                } else {
                    'невідома помилка вивантаження'
                }
                [void]$result.Errors.Add("$($entry.FileName): $errorText")
            }
        } catch {
            # Збій ОДНОГО файлу (маскування чи передача) не сміє перервати
            # решту allowlist — ізоляція по файлу.
            $result.Failed++
            [void]$result.Errors.Add("$($entry.FileName): $($_.Exception.Message)")
        } finally {
            if (-not [string]::IsNullOrWhiteSpace([string]$maskedPath)) {
                try { & $RemoveMaskedCopy $maskedPath } catch {
                    # Прибирання тимчасової копії — найкращий намір; збій
                    # тут не сміє замаскувати результат самого вивантаження.
                }
            }
        }
    }

    return $result
}
