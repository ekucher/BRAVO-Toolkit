# BRAVO.Update.Lock — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
# Lifecycle-lock і спільний operation-lock (CONTRACTS §9). Жодного виводу в
# консоль: усі функції повертають об'єкти і не кидають виняток на «зайнято».

function Get-BRAVOUpdateLockProcessStartTime {
    # Час старту поточного процесу в ISO 8601 ('o'): пара pid+processStartTime
    # відрізняє живого власника від повторно використаного PID. $null, якщо
    # прочитати не вдалося (holder тоді просто менш інформативний).
    [CmdletBinding()]
    param()
    try {
        return (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToString('o')
    } catch {
        return $null
    }
}

function Read-BRAVOUpdateLockHolderFile {
    # Власне читання JSON-holder-а (peek: FileAccess.Read + FileShare.ReadWrite
    # — відкриття вдається, навіть поки власник тримає файл на запис).
    # $null — файла немає, порожній, не JSON або недоступний: це «невідомо»,
    # а не помилка (вузьке вікно між відкриттям lock-а і записом holder-а).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $peekStream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            $peekReader = New-Object System.IO.StreamReader($peekStream, [System.Text.Encoding]::UTF8)
            $peekText = $peekReader.ReadToEnd()
        } finally {
            $peekStream.Dispose()
        }
        if ([string]::IsNullOrWhiteSpace($peekText)) { return $null }
        return ($peekText | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Write-BRAVOUpdateLockHolderToStream {
    # Записує JSON-holder у вже відкритий потік lock-а (SetLength(0) + Write +
    # Flush). Потік не закриває.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.IO.FileStream]$Stream,
        [Parameter(Mandatory = $true)][object]$Holder
    )
    $holderText = ($Holder | ConvertTo-Json -Compress)
    $holderBytes = [System.Text.Encoding]::UTF8.GetBytes($holderText)
    $Stream.SetLength(0)
    $Stream.Write($holderBytes, 0, $holderBytes.Length)
    $Stream.Flush()
}

function Enter-BRAVOUpdateLifecycleLock {
    # <LockRoot>\BRAVO_UPDATE.lock, FileShare.None: тримається всю операцію.
    # Зайнято -> Success=$false і читабельний Holder (не виняток).
    #
    # Чому sidecar: FileShare.None забороняє будь-яке чуже відкриття lock-файла,
    # навіть peek на читання. Тому holder пишемо і в сам lock (для порядку), і в
    # BRAVO_UPDATE.holder.json поруч — його конкурент читає, коли lock зайнятий.
    # Sidecar не є джерелом істини про «зайнято» (це лише факт, що lock-файл
    # не відкрився); застарілий sidecar без зайнятого lock-а ніхто не читає.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LockRoot,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    $lockPath = Join-Path $LockRoot 'BRAVO_UPDATE.lock'
    $holderPath = Join-Path $LockRoot 'BRAVO_UPDATE.holder.json'
    $stream = $null
    try {
        if (-not (Test-Path -LiteralPath $LockRoot -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $LockRoot -Force)
        }
        try {
            $stream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            return [pscustomobject]@{
                Success = $false
                Stream  = $null
                Path    = $lockPath
                Holder  = (Read-BRAVOUpdateLockHolderFile -Path $holderPath)
                Error   = ('Lifecycle-lock зайнятий: ' + $_.Exception.Message)
            }
        }
        $holder = [pscustomobject]@{
            pid              = $PID
            processStartTime = (Get-BRAVOUpdateLockProcessStartTime)
            operationId      = $OperationId
            startedAt        = (Get-Date).ToString('o')
        }
        Write-BRAVOUpdateLockHolderToStream -Stream $stream -Holder $holder
        # Sidecar — best-effort: збій запису не повинен провалити захоплення.
        try {
            [System.IO.File]::WriteAllText($holderPath, ($holder | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
        } catch {
            $null = $_
        }
        return [pscustomobject]@{
            Success = $true
            Stream  = $stream
            Path    = $lockPath
            Holder  = $holder
            Error   = $null
        }
    } catch {
        if ($null -ne $stream) { $stream.Dispose() }
        return [pscustomobject]@{
            Success = $false
            Stream  = $null
            Path    = $lockPath
            Holder  = $null
            Error   = $_.Exception.Message
        }
    }
}

function Exit-BRAVOUpdateLifecycleLock {
    # Звільняє lifecycle-lock: прибирає sidecar (поки lock ще тримається, щоб
    # не стерти holder наступного власника), закриває потік. Lock-файл не
    # видаляє: порожній файл безпечний, а видалення відкриває гонку.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Lock)

    if ($null -eq $Lock) { return }
    $streamProperty = $Lock.PSObject.Properties['Stream']
    $pathProperty = $Lock.PSObject.Properties['Path']
    if ($null -eq $streamProperty -or $null -eq $streamProperty.Value) { return }
    try {
        if ($null -ne $pathProperty -and -not [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) {
            $holderPath = Join-Path (Split-Path -Parent ([string]$pathProperty.Value)) 'BRAVO_UPDATE.holder.json'
            Remove-Item -LiteralPath $holderPath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        $null = $_
    } finally {
        $streamProperty.Value.Dispose()
    }
}

function Read-BRAVOUpdateOperationLockHolder {
    # Holder канонічного operation-lock: канонічний Read-BRAVOOperationLockHolder
    # (BRAVO.System), якщо модуль завантажено, інакше власне читання. Повертає
    # PSCustomObject або $null.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$OperationLockPath)

    if ($null -ne (Get-Command -Name 'Read-BRAVOOperationLockHolder' -ErrorAction SilentlyContinue)) {
        return (Read-BRAVOOperationLockHolder -Path $OperationLockPath)
    }
    return (Read-BRAVOUpdateLockHolderFile -Path $OperationLockPath)
}

function Enter-BRAVOUpdateOperationLock {
    # Канонічний BRAVO_OPERATION.lock тим самим механізмом і форматом, що
    # Archive/Maintenance/DataRestore: OpenOrCreate, ReadWrite, FileShare.Read
    # (дозволяє чужий read-only peek), JSON-holder з operation='Update'. Без
    # циклу очікування (NoWait): зайнято -> одразу Success=$false і Holder;
    # політика «дочекайтеся завершення» — на викликачі. generationId =
    # OperationId, щоб holder зіставлявся з журналом операції.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OperationLockPath,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$PackageVersion
    )

    $stream = $null
    try {
        $lockDirectory = Split-Path -Parent $OperationLockPath
        if (-not [string]::IsNullOrWhiteSpace($lockDirectory) -and -not (Test-Path -LiteralPath $lockDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $lockDirectory -Force)
        }
        try {
            $stream = [System.IO.File]::Open(
                $OperationLockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::Read
            )
        } catch [System.IO.IOException] {
            return [pscustomobject]@{
                Success = $false
                Stream  = $null
                Path    = $OperationLockPath
                Holder  = (Read-BRAVOUpdateOperationLockHolder -OperationLockPath $OperationLockPath)
                Error   = ('Операційний lock зайнятий: ' + $_.Exception.Message)
            }
        }
        $holder = [pscustomobject]@{
            pid              = $PID
            processStartTime = (Get-BRAVOUpdateLockProcessStartTime)
            hostname         = [Environment]::MachineName
            operation        = 'Update'
            startedAt        = (Get-Date).ToString('o')
            packageVersion   = $PackageVersion
            config           = $null
            generationId     = $OperationId
        }
        Write-BRAVOUpdateLockHolderToStream -Stream $stream -Holder $holder
        return [pscustomobject]@{
            Success = $true
            Stream  = $stream
            Path    = $OperationLockPath
            Holder  = $holder
            Error   = $null
        }
    } catch {
        if ($null -ne $stream) { $stream.Dispose() }
        return [pscustomobject]@{
            Success = $false
            Stream  = $null
            Path    = $OperationLockPath
            Holder  = $null
            Error   = $_.Exception.Message
        }
    }
}

function Exit-BRAVOUpdateOperationLock {
    # Звільняє operation-lock: закриває потік. Файл не видаляється (так само,
    # як у Archive/Maintenance).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Lock)

    if ($null -eq $Lock) { return }
    $streamProperty = $Lock.PSObject.Properties['Stream']
    if ($null -ne $streamProperty -and $null -ne $streamProperty.Value) {
        $streamProperty.Value.Dispose()
    }
}

function Test-BRAVOUpdateOperationLockActive {
    # Чи тримає хтось BRAVO_OPERATION.lock — без захоплення lock-а.
    #
    # Чому саме така проба: peek на читання (FileShare.ReadWrite) вдається
    # завжди, тож сам по собі не каже, чи lock живий (файл лишається на диску
    # після звільнення). Власник тримає файл із правом запису і FileShare.Read,
    # тому відкриття з FileAccess.Write + FileShare.ReadWrite вдається лише
    # якщо власника немає, і відразу закривається. Це НЕ захоплення lock-а
    # (holder не пишемо, нічого не змінюємо), але на долі мілісекунди чужий
    # Enter-* з FileShare.Read може отримати хибне «зайнято» — прийнятно, бо
    # Enter-* без очікування і так повторюється викликачем; Health-проба
    # поводиться так само. Будь-яка непередбачена помилка -> Active=$true
    # (fail closed: не вважаємо lock вільним).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$OperationLockPath)

    if (-not (Test-Path -LiteralPath $OperationLockPath -PathType Leaf)) {
        return [pscustomobject]@{ Active = $false; Holder = $null }
    }
    # ВАЖЛИВО: без типізованих catch із return всередині. У Windows PowerShell
    # 5.1 після кількох викликів (скомпільований scriptblock) такий варіант
    # хибно повертав Active=$false при зайнятому lock-і (fail open!). Один
    # універсальний catch + розбір типу + єдиний return поводиться однаково
    # в інтерпретованому й скомпільованому режимах.
    $active = $false
    $missing = $false
    try {
        $probe = [System.IO.File]::Open(
            $OperationLockPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite
        )
        $probe.Dispose()
    } catch {
        $failure = $_.Exception
        if ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
        if (($failure -is [System.IO.FileNotFoundException]) -or ($failure -is [System.IO.DirectoryNotFoundException])) {
            $missing = $true
        } else {
            $active = $true
        }
    }
    if ($missing) { return [pscustomobject]@{ Active = $false; Holder = $null } }
    $holder = $null
    if ($active) { $holder = Read-BRAVOUpdateOperationLockHolder -OperationLockPath $OperationLockPath }
    return [pscustomobject]@{ Active = $active; Holder = $holder }
}
