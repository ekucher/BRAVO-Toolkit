[CmdletBinding()]
param(
    # Базова точка "ДО" — стан PR B (Configuration Foundation, до PR C).
    #
    # Тут НАВМИСНО стоїть незмінний SHA, а не ім'я гілки. Раніше дефолтом
    # було 'feature/config-foundation-derivation'; ця гілка вже влита в
    # developer, тож прибирання стале гілок (governance) видалило б
    # єдину точку відліку для доказу паритету конфігурації — і зламало б
    # цей інструмент мовчки, у момент, коли він найпотрібніший.
    #
    # 42cf9ad — тіп тієї самої гілки і предок developer, тож коміт
    # лишається досяжним після видалення гілки. Allowlist навмисних
    # відмінностей нижче прив'язаний саме до цього стану: підміна бази на
    # master/тег зробила б результат неінтерпретовним (master ще не має
    # Configuration Foundation). Інша база — лише явним -BaseRef.
    #
    # ПРО РЕКОМЕНДАЦІЮ "BaseRef = origin/master або тег" з #154 (A4): вона
    # НЕ застосовна, поки stable лишається 5.2.4 — перевірено 2026-09-14,
    # у origin/master немає навіть каталогу modules\BRAVO.Configuration\,
    # тож порівнювати не було б із чим. Перепривʼязка бази має сенс лише
    # після того, як Configuration Foundation потрапить у stable; доти
    # база лишається на 42cf9ad.
    #
    # НАСЛІДОК, про який треба знати: доки база зафіксована, а лінія
    # розробки йде вперед, allowlist нижче ЗРОСТАТИМЕ — кожен новий ключ
    # конфігурації й кожне штампування версії додають очікувану
    # відмінність. Це не гниття інструмента, а плата за незмінну точку
    # відліку; поіменне внесення таких ключів свідоме (обґрунтування — у
    # коментарях самого allowlist-а).
    [string]$BaseRef = '42cf9add7c9e9d40b7e6ae456518738c08e2cd4b',

    # Каталог комплекту "ПІСЛЯ" — за замовчуванням поточний working tree
    # (включно з незакомміченими змінами PR C) відносно розташування
    # цього скрипта.
    [string]$AfterRoot = (Split-Path -Path $PSScriptRoot -Parent)
)

<#
.SYNOPSIS
    P0 Configuration Foundation, Task #10: формальний characterization-тест
    паритету "config-present" сценарію ДО (PR B, merge-base) і ПІСЛЯ (PR C,
    включно з незакомміченим станом working tree) над ПОВНИМ effective
    graph (усі $global:*-змінні, які виставляє BRAVO_CONFIG_LOADER.ps1 +
    BRAVO.config), а не лише вибірковими полями.
.DESCRIPTION
    НЕ частина BRAVO_SELF_TEST.ps1 — той набір мусить лишатись git-
    незалежним (виконується і на розгорнутих у клієнта комплектах без
    .git). Цей скрипт — dev/CI-інструмент (той самий клас, що
    ci\Update-BRAVORuntimeManifest.ps1): запускається вручну під час
    рефакторингу конфігураційного пайплайна, не при кожному self-test.

    Методика:
      1. Ізольований git worktree за $BaseRef (не займає поточний working
         tree, не потребує commit/checkout).
      2. Два окремі ізольовані ConfigRoot-каталоги (BEFORE/AFTER), кожен —
         copy патченого BRAVO.config відповідної версії (LIMSRoot/
         BackupRoot підмінено на fixture-шляхи — без цього auto-discovery
         впаде на будь-якій машині без встановленого LIMS) + ІДЕНТИЧНИЙ
         BRAVO.local.config із широким набором overrides (schedulerSettings,
         notification, retention, SFTP/SMB, componentSettings/storage/
         bazaSync — усі домени, які Task #10 явно вимагав покрити).
      3. Дочірній процес Windows PowerShell для кожної версії: dot-source
         власного BRAVO_CONFIG_LOADER.ps1, Import-BravoConfiguration
         -PassThru, JSON-знімок повного набору $global:-змінних.
      4. Рекурсивний diff двох знімків із нормалізацією fixture-шляхів
         (сам корінь fixture різний за побудовою — це artifact методики
         тесту, не поведінки коду) і документованим allowlist для
         НАВМИСНИХ відмінностей (адитивні метадані Секцій 2-3, canonical-
         default фікс Секції 5 lunchArchiveCleanupPath).

    Будь-яка ІНША відмінність — регресія: скрипт завершується з exit 1 і
    повним переліком.
.EXAMPLE
    .\ci\Test-BRAVOConfigFoundationParity.ps1
    Порівнює базовий стан PR B (коміт 42cf9ad) з поточним working tree.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ===== Список $global:-імен, які захоплюємо =====
#
# Перелік БІЛЬШЕ НЕ ЖИВЕ ТУТ. Він переїхав у канонічного власника —
# modules\BRAVO.Configuration\BRAVO.Configuration.Snapshot.psm1 — бо
# з'явився другий споживач: доказ pilot migration на сервері, де цей
# git-залежний harness не запускається. Дві копії переліку означали б,
# що доказ міграції й доказ паритету мовчки дивляться на різні графи.
#
# Модуль береться з AFTER-дерева (поточний working tree). Для BEFORE-боку
# це коректно саме тому, що перелік ІМЕН — це питання "що взагалі
# вважається ефективною конфігурацією", спільне для обох боків; самі
# ЗНАЧЕННЯ кожен бік обчислює своїм власним лоадером.
Import-Module -Name (Join-Path $AfterRoot 'modules\BRAVO.Configuration\BRAVO.Configuration.Snapshot.psd1') -Force -ErrorAction Stop
$capturedNames = @(Get-BRAVOEffectiveConfigurationVariableName)
if ($capturedNames.Count -eq 0) {
    throw 'Get-BRAVOEffectiveConfigurationVariableName повернув порожній перелік — порівнювати не було б чого, і harness звітував би PASS ні про що.'
}

# ===== Широкий BRAVO.local.config, що покриває всі домени з Task #10 =====
$localConfigLiteral = @'
@{
    'bravoSettings.NotificationProvider' = 'discord'
    'bravoSettings.NotificationMode' = 'errors_only'
    'bravoSettings.NotificationRequestTimeoutSeconds' = 45
    'bravoSettings.NotificationRouting.SUCCESS' = 'general'
    'bravoSettings.NotificationRouting.WARNING' = 'alerts'
    'bravoSettings.NotificationRouting.ERROR' = 'alerts'
    'bravoSettings.NotificationRouting.CRITICAL' = 'alerts'
    'maintenanceSettings.Retention.ArchiveDays' = 45
    'maintenanceSettings.Retention.LogDays' = 21
    'maintenanceSettings.Retention.CompressedLogDays' = 120
    'maintenanceSettings.Retention.CompressedLogDeletionEnabled' = $true
    'maintenanceSettings.Retention.FailedArchiveDays' = 10
    'maintenanceSettings.Limits.ExcludedDrives' = @('X:\', 'Y:\')
    'componentSettings.SFTP.Enabled' = $true
    'componentSettings.SFTP.ArchiveUpload' = $true
    'componentSettings.SMB.Enabled' = $true
    'componentSettings.SMB.ArchiveCopy' = $true
    'componentSettings.Synchronization.BAZA_APP_LOCAL' = $true
    'componentSettings.Synchronization.BAZA_APP_SFTP' = $true
    'componentSettings.Synchronization.BAZA_WWW_LOCAL' = $true
    'componentSettings.Synchronization.BAZA_WWW_SFTP' = $true
    'componentSettings.Archive.BLOG' = $true
    'componentSettings.Archive.BRAVOEXCH' = $true
    'componentSettings.Archive.MODEL' = $true
    'backupMonitoring.SFTP.Enabled' = $true
    'backupMonitoring.SFTP.CheckArchiveUploads' = $true
    'backupMonitoring.SFTP.CheckBAZASynchronization' = $true
    'backupMonitoring.SFTP.RemoteBackupMaxAgeHours' = 30
    'backupMonitoring.SFTP.OperationTimeoutSeconds' = 90
    'backupMonitoring.SFTP.SynchronizationTimeoutSeconds' = 60
    'backupMonitoring.SFTP.VerifyRemoteArchiveHash' = $true
    'backupMonitoring.SFTP.RequireServerSideArchiveHash' = $true
    'backupMonitoring.SFTP.BAZAPendingAlertAfterHours' = 12
    'backupMonitoring.SFTP.BAZA.Mode' = 'Full'
    'backupMonitoring.SFTP.BAZA.SynchronizeBeforeHealth' = $true
    'backupMonitoring.SFTP.BAZA.FastHealthEnabled' = $true
    'backupMonitoring.SFTP.BAZA.FullAuditEnabled' = $true
    'backupMonitoring.SFTP.BAZA.FullAuditEveryDays' = 3
    'backupMonitoring.SFTP.BAZA.AutoArchiveMutationThreshold' = 5
    'backupMonitoring.SMB.Enabled' = $true
    'backupMonitoring.SMB.RemoteBackupMaxAgeHours' = 30
    'backupMonitoring.NotifyOnSuccessAfterBackup' = $true
    'sftpHostTemplate' = 'sftp-parity-test.example.local'
    'sftpPort' = 2222
    'sftpConnectionTimeoutSeconds' = 45
    'smbSettings.RootPath' = '\\PARITY-TEST-NAS\BRAVO_BACKUP'
    'smbSettings.CopyBufferSizeMB' = 8
    'smbSettings.Directories.BLOG' = 'PARITY_BLOG'
    'smbSettings.Directories.BRAVOEXCH' = 'PARITY_EXCH'
    'smbSettings.Directories.MODEL' = 'PARITY_MODEL'
    'sftpDirectories.Blog' = 'parity_blog'
    'sftpDirectories.BravoExch' = 'parity_exch'
    'sftpDirectories.MODEL' = 'parity_model'
    'sftpDirectories.Manifest' = 'parity_manifest'
    'sftpDirectories.TraceLogs' = 'parity_trace'
    'sftpDirectories.ExchangeApiLogs' = 'parity_exchapi'
    'schedulerSettings.Backup.Enabled' = $true
    'schedulerSettings.Backup.DailyAt' = '23:15'
    'schedulerSettings.Backup.ExecutionTimeLimitHours' = 6
    'schedulerSettings.Maintenance.Enabled' = $true
    'schedulerSettings.Maintenance.DailyAt' = '04:30'
    'schedulerSettings.Health.Enabled' = $true
    'schedulerSettings.Health.StartAt' = '06:00'
    'schedulerSettings.Health.RepeatEveryMinutes' = 30
    'schedulerSettings.Health.BusyWaitMinutes' = 5
    'schedulerSettings.Health.SkipIfBackupTaskRunning' = $true
    'schedulerSettings.BAZASync.StartAt' = '01:00'
    'schedulerSettings.BAZASync.RepeatEveryHours' = 2
    'schedulerSettings.OperationLockWaitMinutes' = 15
    'schedulerSettings.StartWhenAvailable' = $true
    'schedulerSettings.WakeToRun' = $true
}
'@

# ===== Дочірній-процес шаблон: dot-source власного лоадера версії,
# Import-BravoConfiguration -PassThru, JSON-знімок =====
#
# Сама МЕХАНІКА зчитування (Get-Variable -Scope Global + маркер
# '<<ABSENT>>') тут СВІДОМО дублює
# Get-BRAVOEffectiveConfigurationSnapshot, і конвергенція була б
# НЕКОРЕКТНОЮ: BEFORE-бік виконується в дереві $BaseRef, де цього модуля
# ще не існує. Імпортувати модуль з AFTER-дерева в BEFORE-захоплення
# означало б внести код "після" в знімок "до" — тобто знецінити сам
# characterization-тест. Спільним лишається тільки перелік ІМЕН, який
# параметризується ззовні (__CAPTURED_NAMES_LITERAL__).
$captureChildTemplate = @'
param(
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$ConfigRoot,
    [Parameter(Mandatory = $true)][string]$OutputJsonPath,
    [Parameter(Mandatory = $true)][string]$ErrorJsonPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $RuntimeRoot 'BRAVO_CONFIG_LOADER.ps1')
    $null = Import-BravoConfiguration -ConfigRoot $ConfigRoot -RuntimeRoot $RuntimeRoot -PassThru
    $names = @(__CAPTURED_NAMES_LITERAL__)
    $snapshot = [ordered]@{}
    foreach ($name in $names) {
        $variable = Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
        $snapshot[$name] = if ($null -ne $variable) { $variable.Value } else { '<<ABSENT>>' }
    }
    $snapshot | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $OutputJsonPath -Encoding UTF8
} catch {
    [pscustomobject]@{ Message = $_.Exception.Message; ScriptStackTrace = $_.ScriptStackTrace } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ErrorJsonPath -Encoding UTF8
    exit 1
}
'@

function New-PatchedFixtureConfigRoot {
    param([Parameter(Mandatory = $true)][string]$SourceKitRoot, [Parameter(Mandatory = $true)][string]$DestConfigRoot)

    $limsRoot = Join-Path $DestConfigRoot 'FIXTURE_LIMS'
    $backupRoot = Join-Path $DestConfigRoot 'FIXTURE_BACKUP'
    New-Item -ItemType Directory -Path $limsRoot -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $backupRoot -Force -ErrorAction Stop | Out-Null

    $kitConfigText = Get-Content -LiteralPath (Join-Path $SourceKitRoot 'BRAVO.config') -Raw
    $limsLine = '    LIMSRoot      = ""'
    $backupLine = '    BackupRoot    = ""'
    if (-not $kitConfigText.Contains($limsLine) -or -not $kitConfigText.Contains($backupLine)) {
        throw "New-PatchedFixtureConfigRoot: очікувані рядки LIMSRoot/BackupRoot не знайдено в $SourceKitRoot\BRAVO.config"
    }
    $patched = $kitConfigText.
        Replace($limsLine, "    LIMSRoot      = '$($limsRoot.Replace("'", "''"))'").
        Replace($backupLine, "    BackupRoot    = '$($backupRoot.Replace("'", "''"))'")
    [IO.File]::WriteAllText((Join-Path $DestConfigRoot 'BRAVO.config'), $patched, (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $DestConfigRoot 'BRAVO.local.config'), $localConfigLiteral, (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{ LimsRoot = $limsRoot; BackupRoot = $backupRoot }
}

function New-AbsentFixtureConfigRoot {
    # Wave 1C (Issue #216): AFTER-ABSENT-фікстура — той самий широкий
    # $localConfigLiteral (Секції 1-2 вище, спільний з present-фікстурою),
    # програмно розширений РІВНО двома path-ключами
    # (pathSettings.LIMSRoot/pathSettings.BackupRoot), БЕЗ жодного
    # BRAVO.config. Present-фікстура отримує ці два значення з ПАТЧЕНОГО
    # BRAVO.config (New-PatchedFixtureConfigRoot вище); у absent-режимі
    # немає primary-конфігу, який міг би їх задати, тож єдиний спосіб
    # зробити ефективні вхідні дані рівнозначними — local-override-шар
    # (Секція 9 owner-runbook). Значення НЕ дублюють increase — це
    # розширення того самого літералу, а не другий, незалежно підтримуваний
    # текст.
    param([Parameter(Mandatory = $true)][string]$DestConfigRoot)

    $limsRoot = Join-Path $DestConfigRoot 'FIXTURE_LIMS'
    $backupRoot = Join-Path $DestConfigRoot 'FIXTURE_BACKUP'
    New-Item -ItemType Directory -Path $limsRoot -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $backupRoot -Force -ErrorAction Stop | Out-Null

    $absentLocalConfigLiteral = $localConfigLiteral.TrimEnd().TrimEnd('}').TrimEnd() + (
        "`r`n" +
        "    'pathSettings.LIMSRoot' = '$($limsRoot.Replace("'", "''"))'`r`n" +
        "    'pathSettings.BackupRoot' = '$($backupRoot.Replace("'", "''"))'`r`n" +
        "}`r`n"
    )
    [IO.File]::WriteAllText((Join-Path $DestConfigRoot 'BRAVO.local.config'), $absentLocalConfigLiteral, (New-Object System.Text.UTF8Encoding($false)))

    # Fail-closed fixture-гарантія (owner-runbook, Секція 8): якщо
    # BRAVO.config тут ЯКИМОСЬ чином опиниться (напр. майбутня зміна
    # New-Item/копіювання помилково зачепить цей каталог), увесь
    # AFTER-ABSENT-сценарій перестає доводити те, що заявляє його назва —
    # мовчки продовжувати небезпечно, тому throw, а не попередження.
    $absentPrimaryConfigPath = Join-Path $DestConfigRoot 'BRAVO.config'
    if (Test-Path -LiteralPath $absentPrimaryConfigPath -PathType Leaf) {
        throw "New-AbsentFixtureConfigRoot: BRAVO.config неочікувано присутній у absent-фікстурі ($absentPrimaryConfigPath) — AFTER-ABSENT-сценарій вимагає СПРАВЖНЬОЇ відсутності primary-конфігу."
    }

    return [pscustomobject]@{ LimsRoot = $limsRoot; BackupRoot = $backupRoot }
}

function Invoke-ParityCapture {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot, [Parameter(Mandatory = $true)][string]$ConfigRoot, [Parameter(Mandatory = $true)][string]$WorkDir)

    $childScriptPath = Join-Path $WorkDir 'CaptureChild.ps1'
    $namesLiteral = ($capturedNames | ForEach-Object { "'$_'" }) -join ', '
    $childScriptContent = $captureChildTemplate.Replace('__CAPTURED_NAMES_LITERAL__', $namesLiteral)
    [IO.File]::WriteAllText($childScriptPath, $childScriptContent, (New-Object System.Text.UTF8Encoding($false)))

    $outputJsonPath = Join-Path $WorkDir 'result.json'
    $errorJsonPath = Join-Path $WorkDir 'error.json'
    $stdoutPath = Join-Path $WorkDir 'stdout.log'
    $stderrPath = Join-Path $WorkDir 'stderr.log'

    $processArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $childScriptPath,
        '-RuntimeRoot', $RuntimeRoot, '-ConfigRoot', $ConfigRoot,
        '-OutputJsonPath', $outputJsonPath, '-ErrorJsonPath', $errorJsonPath)
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $processArgs -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    if ($process.ExitCode -ne 0 -or (Test-Path -LiteralPath $errorJsonPath -PathType Leaf)) {
        $errorDetail = if (Test-Path -LiteralPath $errorJsonPath -PathType Leaf) { Get-Content -LiteralPath $errorJsonPath -Raw } else { '' }
        $stderrText = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
        throw "Invoke-ParityCapture: дочірній процес завершився з помилкою (ExitCode=$($process.ExitCode)). $errorDetail $stderrText"
    }
    if (-not (Test-Path -LiteralPath $outputJsonPath -PathType Leaf)) {
        throw 'Invoke-ParityCapture: дочірній процес завершився без помилки, але результат відсутній.'
    }
    return (Get-Content -LiteralPath $outputJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-ParityNormalizedString {
    # Fixture-методика використовує ДВА окремі корені на сторону (RuntimeRoot
    # — worktree/AfterRoot; ConfigRoot — тимчасовий BEFORE/AFTER fixture-
    # каталог) — captured-поля походять то з одного, то з іншого (ScriptPath/
    # ManifestPath/HelperPath з RuntimeRoot; archiveDefinitions/archiveDirs/
    # pathSettings з ConfigRoot). Обидва мають бути нормалізовані, інакше
    # чисто methodology-артефакт (різні GUID-based temp-каталоги для двох
    # прогонів) хибно позначається як регресія.
    param([string]$Value, [string[]]$RootPrefixes)
    $normalized = $Value
    foreach ($prefix in $RootPrefixes) {
        if (-not [string]::IsNullOrEmpty($prefix)) {
            $normalized = $normalized.Replace($prefix, '<<ROOT>>')
            # archiveDefinitions/archiveDirs проходять через ConvertTo-Json
            # -Compress ЗНОВУ в цій функції (array-гілка Compare-ParitySnapshot)
            # -> зворотні слеші подвоюються ("C:\\Users\\...") у JSON-тексті,
            # а $RootPrefixes — сирі .NET-шляхи з одинарними слешами. Без
            # цієї другої заміни fixture-шлях у JSON-полях лишається
            # ненормалізованим і хибно виглядає регресією (реально
            # відтворено: archiveDefinitions.Destination).
            $normalized = $normalized.Replace($prefix.Replace('\', '\\'), '<<ROOT>>')
        }
    }
    return $normalized
}

function Compare-ParitySnapshot {
    # Wave 1C (Issue #216): -LeftLabel/-RightLabel — опціональні, дефолт
    # зберігає ТОЧНО попередній вивід ("BEFORE=...|AFTER=...") для наявного
    # BEFORE/AFTER-виклику нижче. Третє порівняння (config-present vs
    # config-absent) передає 'PRESENT'/'ABSENT' явно — без generic
    # BEFORE/AFTER-міток, які тут були б оманливими (обидва боки — той
    # самий AFTER-комплект, різниця лише в наявності BRAVO.config).
    param(
        $Path, $Left, $Right, [System.Collections.Generic.List[string]]$Diffs,
        [string[]]$LeftRootPrefixes, [string[]]$RightRootPrefixes,
        [string]$LeftLabel = 'BEFORE', [string]$RightLabel = 'AFTER'
    )

    $leftIsObj = $null -ne $Left -and $Left -is [System.Management.Automation.PSCustomObject]
    $rightIsObj = $null -ne $Right -and $Right -is [System.Management.Automation.PSCustomObject]
    if ($leftIsObj -or $rightIsObj) {
        $leftProps = if ($leftIsObj) { @($Left.PSObject.Properties.Name) } else { @() }
        $rightProps = if ($rightIsObj) { @($Right.PSObject.Properties.Name) } else { @() }
        foreach ($p in @($leftProps + $rightProps | Sort-Object -Unique)) {
            $lv = if ($leftIsObj -and $leftProps -contains $p) { $Left.$p } else { $null }
            $rv = if ($rightIsObj -and $rightProps -contains $p) { $Right.$p } else { $null }
            Compare-ParitySnapshot "$Path.$p" $lv $rv $Diffs $LeftRootPrefixes $RightRootPrefixes -LeftLabel $LeftLabel -RightLabel $RightLabel
        }
        return
    }
    $leftIsArr = $Left -is [array]
    $rightIsArr = $Right -is [array]
    if ($leftIsArr -or $rightIsArr) {
        # -InputObject (не pipe): порожній @() через pipe розгортається в
        # НУЛЬ об'єктів вхідного потоку -> ConvertTo-Json нічого не отримує
        # і повертає $null замість "[]" (P2-фікс, реально відтворено).
        $lJson = ConvertTo-Json -InputObject @($Left) -Depth 10 -Compress
        $rJson = ConvertTo-Json -InputObject @($Right) -Depth 10 -Compress
        $lNorm = Get-ParityNormalizedString -Value $lJson -RootPrefixes $LeftRootPrefixes
        $rNorm = Get-ParityNormalizedString -Value $rJson -RootPrefixes $RightRootPrefixes
        if ($lNorm -ne $rNorm) { $Diffs.Add("$Path : $LeftLabel=$lJson | $RightLabel=$rJson") }
        return
    }
    $lStr = if ($null -eq $Left) { '<null>' } else { [string]$Left }
    $rStr = if ($null -eq $Right) { '<null>' } else { [string]$Right }
    $lNorm = Get-ParityNormalizedString -Value $lStr -RootPrefixes $LeftRootPrefixes
    $rNorm = Get-ParityNormalizedString -Value $rStr -RootPrefixes $RightRootPrefixes
    if ($lNorm -ne $rNorm) { $Diffs.Add("$Path : $LeftLabel=$lStr | $RightLabel=$rStr") }
}

# ===== Відомі, задокументовані НАВМИСНІ відмінності (allowlist по
# root-шляху властивості) — усе інше є регресією =====
$knownIntentionalDiffPrefixes = @(
    # Адитивні поля метаданих (Секції 2-3): PR B їх узагалі не мав
    # (властивість відсутня -> $null), PR C додав як НОВІ, не змінивши
    # жодне вже наявне поле.
    'BravoConfigurationMetadata.AppliedLocalOverrideKeys',
    # Адитивне діагностичне поле (#154, A2): прийняті, але нерезультативні
    # ключі BRAVO.local.config з невідомим кінцевим сегментом. Наявні поля
    # не змінює, на effective-конфігурацію не впливає.
    'BravoConfigurationMetadata.LocalConfigUnknownLeafOverrides',
    # Адитивні діагностичні поля (#154, A3/F1): top-level $global: з
    # BRAVO.config, які канонічний pipeline не приймає й не обчислює, та
    # вкладені ключі, невідомі канонічній конфігурації. Наявні поля не
    # змінюють, на effective-конфігурацію не впливають.
    'BravoConfigurationMetadata.PrimaryConfigIgnoredGlobals',
    'BravoConfigurationMetadata.PrimaryConfigUnknownNestedKeys',
    # Адитивне поле версії site-формату (#154, B3; коміт cefcf50).
    # АДИТИВНІСТЬ ДОВЕДЕНА, не припущена: у базі 42cf9ad рядок
    # 'LocalConfigEffectiveSchemaVersion' не зустрічається в
    # BRAVO_CONFIG_LOADER.ps1 ЖОДНОГО разу, тобто властивості не існувало
    # (звідси BEFORE=<null>). У AFTER вона дорівнює 1 — фікстурний
    # BRAVO.local.config не оголошує маркера, і резолвер трактує його як
    # версію 1 за задокументованою legacy-політикою. Ефективних значень
    # конфігурації поле не змінює.
    #
    # Сусіднє LocalConfigDeclaredSchemaVersion тут СВІДОМО не перелічене:
    # у цій фікстурі воно $null і в BEFORE, і в AFTER, тож відмінності не
    # дає. Вносити його наперед означало б заглушити майбутню справжню
    # зміну ще до того, як вона станеться.
    'BravoConfigurationMetadata.LocalConfigEffectiveSchemaVersion',
    # Адитивне діагностичне поле (#154, B4 частина 1; коміт 6a37efd):
    # dot-шляхи, де legacy BRAVO.config справді затіняє канонічний дефолт.
    # У базі 42cf9ad рядка 'PrimaryConfigOverridesCanonicalDefaults' у
    # завантажувачі немає взагалі.
    #
    # ЧОМУ ЗНАЧЕННЯ В AFTER НЕПОРОЖНЄ І ЧОМУ ЦЕ ПРАВИЛЬНО: воно дорівнює
    # рівно ['pathSettings.BackupRoot','pathSettings.LIMSRoot'] — тобто
    # саме тим двом шляхам, які New-PatchedFixtureConfigRoot вище підмінює
    # у фікстурному BRAVO.config (без підміни auto-discovery впав би на
    # машині без LIMS). Поле звітує про патч САМОЇ фікстури, а не про
    # властивість комплекту, і значення детерміноване доти, доки фікстура
    # патчить ті самі два рядки — а цього вимагає throw у самій функції.
    'BravoConfigurationMetadata.PrimaryConfigOverridesCanonicalDefaults',
    'BravoConfigurationMetadata.LocalConfigPath',
    'BravoConfigurationMetadata.LocalConfigPresent',
    'BravoConfigurationMetadata.Mode',
    'BravoConfigurationMetadata.PrimaryConfigPath',
    'BravoConfigurationMetadata.PrimaryConfigPresent',
    'BravoConfigurationMetadata.PrimaryConfigWasExplicit',
    # Час завантаження — очікувано різний між двома окремими прогонами.
    'BravoConfigurationMetadata.LoadedAt',
    # ІДЕНТИЧНІСТЬ ВЕРСІЇ — той самий клас, що LoadedAt вище: ці поля
    # відрізняються між БУДЬ-ЯКИМИ двома комітами, де версію штампували,
    # бо беруться з VERSION.json, а не з конфігураційного пайплайна. База
    # 42cf9ad — 5.3.0-dev.2/ff2fdc3; developer уже 5.3.0-dev.3/86270a1.
    # Їх пропустили при першому складанні allowlist-а, і через це harness
    # почав падати після ПЕРШОГО ж штампування версії — тобто гейт §14.4
    # став непрохідним ні для чого (#154, A4; підтверджено прогоном на
    # чистому developer 2026-09-14: ті самі 9 полів без жодного PR).
    # Порівнювати їх тут і не потрібно: узгодженість версії й provenance
    # перевіряють ci\Test-BRAVOReleasePolicy.ps1 і self-test
    # Version/ModuleManifests, а не паритет конфігурації.
    'BravoConfigurationMetadata.BuildId',
    'BravoConfigurationMetadata.PackageVersion',
    'ScriptVersion',
    'ScriptBuildId',
    # ДАТА РЕЛІЗУ — той самий клас, і в цьому списку її бракувало лише
    # тому, що releaseDate у developer був заморожений на 2026-08-26 ще
    # з штампу 5.3.0-rc.1: поле не відрізнялось від бази 42cf9ad, тож
    # відмінності не було видно. Щойно поле полагодили (звірка з
    # заголовком CHANGELOG.md у ci\Test-BRAVOReleasePolicy.ps1), воно
    # поводиться рівно як PackageVersion і BuildId вище — відрізняється
    # між будь-якими двома комітами, де штампували версію.
    'BravoConfigurationMetadata.ReleaseDate',
    'ScriptDate',
    # АДИТИВНІ КЛЮЧІ КОНФІГУРАЦІЇ, додані ПІСЛЯ бази 42cf9ad. У BEFORE їх
    # не існує взагалі (звідси <null>), у AFTER вони мають свої дефолти —
    # це ріст схеми на лінії розробки, а не зміна наявної поведінки.
    # Усі п'ять прийшли одним комітом 5c14a70 (2026-09-04, "log-lifecycle
    # P1/P2/P5/P6 — SFTP власних логів, legacy sweep, retention").
    #
    # Перелічені ПОІМЕННО навмисно. Загальне правило "BEFORE=null +
    # AFTER≠null = адитивність, пропускаємо" було б зручнішим, але воно
    # послабило б перевірку: поле, яке РАНІШЕ мало $null, а тепер має
    # значення, — це справжня зміна поведінки, і від адитивного ключа
    # автоматично не відрізняється. Тертя від поіменного переліку — це
    # і є чесний сигнал, що база старіє.
    'componentSettings.SFTP.ArchiveLogUploadEnabled',
    'componentSettings.SFTP.MaintenanceLogUploadEnabled',
    'maintenanceSettings.Retention.RawSourceGraceDays',
    'sftpDirectories.ArchivLog',
    'sftpDirectories.MaintenanceLog',
    # BSYSTEM Operations (5.3.0), коміт 021fdbf — нові credential-target
    # ключі bootstrap-секрету self-enrollment і виданого API-ключа.
    # У BEFORE (42cf9ad) секції credentialSettings.Targets / legacy
    # дзеркала backupMonitoring.NotificationCredentialTargets не існує
    # взагалі (звідси BEFORE=<null>) — це ріст схеми на лінії розробки,
    # не зміна наявної поведінки. Записи в Credential Manager створює
    # BRAVO_CREDENTIALS_SETUP.ps1 лише коли оператор явно вмикає
    # operationsReportingSettings.Enabled на цьому сервері.
    'credentialSettings.Targets.OperationsApiKey',
    'credentialSettings.Targets.OperationsBootstrapSecret',
    'backupMonitoring.NotificationCredentialTargets.OperationsApiKey',
    'backupMonitoring.NotificationCredentialTargets.OperationsBootstrapSecret',
    # Секція 5, задокументований canonical-default фікс (перевірено
    # окремим self-test ConfigLoader/CommittedBravoConfigMatchesCanonicalDefaults):
    # "E:\Archiv" (застарілий placeholder BRAVO.config) -> "" (canonical).
    # Тут НЕ перекрито через local.config override (свідомо, щоб цей
    # шлях лишався видимим у diff і підтверджував саме цю, а не іншу,
    # причину).
    'lunchArchiveCleanupPath'
)

# Wave 1C (Issue #216) — allowlist ДЛЯ ІНШОГО порівняння (AFTER-PRESENT
# vs AFTER-ABSENT, той самий комплект/коміт по обидва боки). НЕ той
# самий список, що $knownIntentionalDiffPrefixes вище (BEFORE — інший
# коміт/лінія розробки, тут — той самий коміт, різниця лише в
# наявності BRAVO.config): переносити BEFORE/AFTER-виправдання сюди
# приховало б реальну регресію. Лише поля метаданих/provenance, явно
# узгоджені з owner-runbook Секції 10 — жодного семантичного
# effective-конфігураційного поля тут НЕМАЄ.
$knownAbsentIntentionalDiffPrefixes = @(
    # 'legacy-config' vs 'synthetic-no-config' / composition-мітка —
    # ОБИДВА боки навмисно описують СПОСІБ композиції, не ефективні
    # значення.
    'BravoConfigurationMetadata.Format',
    'BravoConfigurationMetadata.Mode',
    'BravoConfigurationMetadata.PrimaryConfigPresent',
    # Діагностичні поля, чий ЗМІСТ залежить від того, чи існує
    # primary-конфіг узагалі (present-фікстура використовує реальний
    # committed BRAVO.config з його власними ignored-globals/unknown-
    # keys/override-шляхами; absent-фікстура не має primary-конфігу
    # взагалі, тому ці списки структурно порожні/інші) — не ефективна
    # конфігурація, а provenance САМОГО primary-файлу.
    'BravoConfigurationMetadata.PrimaryConfigIgnoredGlobals',
    'BravoConfigurationMetadata.PrimaryConfigUnknownNestedKeys',
    'BravoConfigurationMetadata.PrimaryConfigOverridesCanonicalDefaults',
    # Версія, оголошена САМИМ primary BRAVO.config — відсутня, коли
    # primary відсутній.
    'BravoConfigurationMetadata.LegacyScriptVersion',
    'BravoConfigurationMetadata.LegacyScriptVersionPresent',
    'BravoConfigurationMetadata.PackageVersionMatchesLegacyConfig',
    # Час завантаження — очікувано різний між двома окремими прогонами
    # (той самий клас, що в BEFORE/AFTER allowlist вище).
    'BravoConfigurationMetadata.LoadedAt'
    # LocalConfigOverrides/AppliedLocalOverrideKeys/PrimaryConfigPath/
    # ConfigPath/ConfigRoot/RuntimeRoot/LocalConfigPath СВІДОМО не
    # перелічені тут: перші два вирівнюються програмно (видаленням двох
    # fixture-only ключів з ABSENT-боку) нижче, а решта — шляхи, які вже
    # нормалізує Get-ParityNormalizedString через RootPrefixes.
)

$worktreePath = $null
$beforeConfigRoot = $null
$afterConfigRoot = $null
$beforeWorkDir = $null
$afterWorkDir = $null
$absentConfigRoot = $null
$absentWorkDir = $null
try {
    Write-Host "Base ref: $BaseRef" -ForegroundColor Cyan
    Write-Host "After root: $AfterRoot" -ForegroundColor Cyan

    # PowerShell 5.1: 2>&1 на нативному exe під $ErrorActionPreference='Stop'
    # обгортає КОЖЕН рядок stderr у термінуючий NativeCommandError, навіть
    # якщо exe завершився з ExitCode=0 (git worktree add сам по собі пише
    # прогрес-повідомлення в stderr) — тимчасово послаблюємо лише навколо
    # виклику, перевірка $LASTEXITCODE нижче лишається справжнім gate.
    $callEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # --verify ... ^{commit} замість голого rev-parse: голий rev-parse
    # повертає переданий SHA дослівно навіть тоді, коли самого об'єкта в
    # репозиторії немає (напр. shallow clone), і помилка спливала б аж на
    # 'git worktree add' у вигляді, з якого причина не читається.
    $baseCommit = & git -C $AfterRoot rev-parse --verify "$BaseRef^{commit}" 2>&1
    $ErrorActionPreference = $callEap
    if ($LASTEXITCODE -ne 0) {
        throw ("Не вдалося resolve base ref '$BaseRef': $baseCommit`n" +
            "Дефолтна база — незмінний коміт, досяжний з developer. Якщо клон " +
            "неповний (shallow) або гілка developer не вивантажена, виконайте " +
            "'git fetch origin developer' і повторіть. Іншу базу задавайте явно: " +
            "-BaseRef <ref>.")
    }
    Write-Host "Base commit: $baseCommit" -ForegroundColor Cyan

    $tempRoot = [IO.Path]::GetTempPath()
    $worktreePath = Join-Path $tempRoot ('BRAVO_PARITY_WORKTREE_' + [guid]::NewGuid().ToString('N'))
    $beforeConfigRoot = Join-Path $tempRoot ('BRAVO_PARITY_BEFORE_' + [guid]::NewGuid().ToString('N'))
    $afterConfigRoot = Join-Path $tempRoot ('BRAVO_PARITY_AFTER_' + [guid]::NewGuid().ToString('N'))
    $beforeWorkDir = Join-Path $tempRoot ('BRAVO_PARITY_BEFORE_CHILD_' + [guid]::NewGuid().ToString('N'))
    $afterWorkDir = Join-Path $tempRoot ('BRAVO_PARITY_AFTER_CHILD_' + [guid]::NewGuid().ToString('N'))
    $absentConfigRoot = Join-Path $tempRoot ('BRAVO_PARITY_ABSENT_' + [guid]::NewGuid().ToString('N'))
    $absentWorkDir = Join-Path $tempRoot ('BRAVO_PARITY_ABSENT_CHILD_' + [guid]::NewGuid().ToString('N'))
    foreach ($d in @($beforeConfigRoot, $afterConfigRoot, $beforeWorkDir, $afterWorkDir, $absentConfigRoot, $absentWorkDir)) {
        New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
    }

    $callEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $worktreeOutput = & git -C $AfterRoot worktree add --detach $worktreePath $baseCommit 2>&1
    $ErrorActionPreference = $callEap
    if ($LASTEXITCODE -ne 0) { throw "git worktree add провалився: $worktreeOutput" }

    $beforeFixture = New-PatchedFixtureConfigRoot -SourceKitRoot $worktreePath -DestConfigRoot $beforeConfigRoot
    $afterFixture = New-PatchedFixtureConfigRoot -SourceKitRoot $AfterRoot -DestConfigRoot $afterConfigRoot

    Write-Host "Захоплення BEFORE (base) знімку..." -ForegroundColor Cyan
    $beforeSnapshot = Invoke-ParityCapture -RuntimeRoot $worktreePath -ConfigRoot $beforeConfigRoot -WorkDir $beforeWorkDir
    Write-Host "Захоплення AFTER (поточний) знімку..." -ForegroundColor Cyan
    $afterSnapshot = Invoke-ParityCapture -RuntimeRoot $AfterRoot -ConfigRoot $afterConfigRoot -WorkDir $afterWorkDir

    $diffs = New-Object System.Collections.Generic.List[string]
    foreach ($name in $capturedNames) {
        Compare-ParitySnapshot $name $beforeSnapshot.$name $afterSnapshot.$name $diffs `
            @($beforeConfigRoot, $worktreePath) @($afterConfigRoot, $AfterRoot)
    }

    $unexpectedDiffs = @($diffs | Where-Object {
        $line = $_
        -not (@($knownIntentionalDiffPrefixes | Where-Object { $line.StartsWith($_) })).Count
    })

    Write-Host ""
    Write-Host "Усього відмінностей (сирих, до фільтра root-шляхів і allowlist): $($diffs.Count)" -ForegroundColor Cyan
    Write-Host "Неочікуваних (потенційна регресія): $($unexpectedDiffs.Count)" -ForegroundColor $(if ($unexpectedDiffs.Count -gt 0) { 'Red' } else { 'Green' })

    if ($unexpectedDiffs.Count -gt 0) {
        Write-Host ""
        Write-Host "РЕГРЕСІЯ: наступні поля effective graph відрізняються між BEFORE (PR B, $baseCommit) і AFTER без задокументованого обґрунтування:" -ForegroundColor Red
        $unexpectedDiffs | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        exit 1
    }

    Write-Host ""
    Write-Host "PASS: config-present parity PASS — BEFORE (PR B, $baseCommit) і AFTER паритетні: усі відмінності або path-артефакти fixture-методики, або задокументовані навмисні зміни (адитивні метадані Секцій 2-3, canonical-default фікс Секції 5)." -ForegroundColor Green

    # ============================================================
    # Wave 1C (Issue #216) — ТРЕТІЙ сценарій: AFTER-ABSENT. Доводить
    # EffectiveConfig(config-absent) == EffectiveConfig(config-present) на
    # ТОМУ САМОМУ комплекті (AfterRoot/поточний working tree), з тими
    # самими site-вхідними даними — єдина відмінність фікстур: наявність
    # BRAVO.config.
    # ============================================================
    $absentFixture = New-AbsentFixtureConfigRoot -DestConfigRoot $absentConfigRoot

    Write-Host ""
    Write-Host "Захоплення AFTER-ABSENT (без BRAVO.config) знімку..." -ForegroundColor Cyan
    $absentSnapshot = Invoke-ParityCapture -RuntimeRoot $AfterRoot -ConfigRoot $absentConfigRoot -WorkDir $absentWorkDir

    # Section 10 owner-runbook: LocalConfigOverrides/AppliedLocalOverrideKeys
    # НЕ блокет-ігноруються. ABSENT-бік застосовує РІВНО на два local-
    # override-ключі більше, ніж PRESENT (pathSettings.LIMSRoot,
    # pathSettings.BackupRoot — у PRESENT ці два значення приходять з
    # ПАТЧЕНОГО primary BRAVO.config, не з local override). Знімаємо
    # рівно ці два ключі з ABSENT-списків ПЕРЕД порівнянням; усе інше в
    # цих двох полях мусить збігатися з PRESENT точно.
    $fixtureOnlyLocalOverrideKeys = @('pathSettings.LIMSRoot', 'pathSettings.BackupRoot')
    foreach ($localOverrideFieldName in @('LocalConfigOverrides', 'AppliedLocalOverrideKeys')) {
        $absentFieldValue = @($absentSnapshot.BravoConfigurationMetadata.$localOverrideFieldName)
        $absentFieldValueTrimmed = @($absentFieldValue | Where-Object { $fixtureOnlyLocalOverrideKeys -notcontains $_ })
        $absentSnapshot.BravoConfigurationMetadata.$localOverrideFieldName = $absentFieldValueTrimmed
    }

    $absentDiffs = New-Object System.Collections.Generic.List[string]
    foreach ($name in $capturedNames) {
        Compare-ParitySnapshot $name $afterSnapshot.$name $absentSnapshot.$name $absentDiffs `
            @($afterConfigRoot, $AfterRoot) @($absentConfigRoot, $AfterRoot) -LeftLabel 'PRESENT' -RightLabel 'ABSENT'
    }

    $unexpectedAbsentDiffs = @($absentDiffs | Where-Object {
        $line = $_
        -not (@($knownAbsentIntentionalDiffPrefixes | Where-Object { $line.StartsWith($_) })).Count
    })

    Write-Host ""
    Write-Host "Усього відмінностей PRESENT vs ABSENT (сирих, до фільтра root-шляхів і allowlist): $($absentDiffs.Count)" -ForegroundColor Cyan
    Write-Host "Неочікуваних (потенційна регресія): $($unexpectedAbsentDiffs.Count)" -ForegroundColor $(if ($unexpectedAbsentDiffs.Count -gt 0) { 'Red' } else { 'Green' })

    if ($unexpectedAbsentDiffs.Count -gt 0) {
        Write-Host ""
        Write-Host "РЕГРЕСІЯ: наступні поля effective graph відрізняються між AFTER-PRESENT і AFTER-ABSENT без задокументованого обґрунтування:" -ForegroundColor Red
        $unexpectedAbsentDiffs | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        exit 1
    }

    Write-Host ""
    Write-Host "PASS: config-absent parity PASS — AFTER-PRESENT і AFTER-ABSENT паритетні на еквівалентних вхідних даних: усі відмінності або path-артефакти fixture-методики, або задокументовані provenance/метадані-винятки (owner-runbook Секція 10)." -ForegroundColor Green
    exit 0
} finally {
    if ($worktreePath -and (Test-Path -LiteralPath $worktreePath)) {
        $callEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & git -C $AfterRoot worktree remove --force $worktreePath 2>&1 | Out-Null
        $ErrorActionPreference = $callEap
    }
    foreach ($d in @($beforeConfigRoot, $afterConfigRoot, $beforeWorkDir, $afterWorkDir, $absentConfigRoot, $absentWorkDir)) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
