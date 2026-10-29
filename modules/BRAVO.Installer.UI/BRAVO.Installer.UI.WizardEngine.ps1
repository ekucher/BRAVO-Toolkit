# BRAVO.Installer.UI.WizardEngine — команди engine для майстра (Plan, Execute
# через UAC, Recover, облікові дані), запис запиту, читання стану операції й
# запит скасування. Побудова команд — чисті функції; запуск — тонкий.
#
# Межі відповідальності (ENGINE_DESIGN §10, план §8):
#  * GUI НЕ виконує mutation і не викликає mutation-функцій BRAVO.Update: у
#    модуль engine ходить лише міст нижче з allowlist read-only функцій;
#  * секретів немає за конструкцією: жодна функція їх не приймає, запит
#    перевіряється канонічним Test-BRAVOUpdateNoSecretProperty;
#  * процес engine ніколи не завершується примусово: скасування = порожній
#    файл control\cancel, який engine перевіряє сам.

# Кеш PSModuleInfo BRAVO.Update за коренем комплекту (не стан операції:
# лише дескриптор завантаженого модуля, щоб не імпортувати його на кожен опит).
$script:BRAVOInstallerUpdateModules = @{}

function Get-BRAVOInstallerUpdateModule {
    # Завантажує BRAVO.Update з комплекту. Повертає $null, якщо модуль
    # недоступний (виклик має обробити це як «engine недоступний», fail closed).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ToolkitRoot)
    $key = $ToolkitRoot.TrimEnd('\').ToLowerInvariant()
    if ($script:BRAVOInstallerUpdateModules.ContainsKey($key)) { return $script:BRAVOInstallerUpdateModules[$key] }
    $manifest = Join-Path $ToolkitRoot 'modules\BRAVO.Update\BRAVO.Update.psd1'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $null }
    try {
        # Без -Force: якщо модуль уже завантажений з цього шляху, береться він.
        $loaded = Import-Module -Name $manifest -DisableNameChecking -PassThru -ErrorAction Stop
    } catch {
        return $null
    }
    $script:BRAVOInstallerUpdateModules[$key] = $loaded
    $loaded
}

function Invoke-BRAVOInstallerUpdateRead {
    <#
    .SYNOPSIS
        Єдиний міст GUI -> BRAVO.Update: викликає ЛИШЕ перелічені read-only
        функції у scope модуля (psd1 engine ще нічого не експортує). Будь-яка
        інша назва відхиляється ValidateSet, тому mutation-функції (Deploy,
        Rollback, Journal-мутатори, ...) з GUI недосяжні за конструкцією.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ToolkitRoot,
        [Parameter(Mandatory = $true)][ValidateSet(
            'Get-BRAVOUpdateDefaultPaths', 'Read-BRAVOUpdateProgressEvents', 'Read-BRAVOUpdateContractFile',
            'Test-BRAVOUpdateNoSecretProperty', 'Get-BRAVOUpdateLogTail', 'Format-BRAVODeploymentPlanText',
            'Format-BRAVODiagnosticReportText', 'New-BRAVODiagnosticReport', 'Save-BRAVODiagnosticReport',
            'Test-BRAVOUpdatePathIsUnder')][string]$Name,
        [hashtable]$Argument = @{}
    )
    $module = Get-BRAVOInstallerUpdateModule -ToolkitRoot $ToolkitRoot
    if ($null -eq $module) { throw 'Модуль engine BRAVO.Update недоступний у каталозі комплекту.' }
    & $module { param($functionName, $functionArgument) & $functionName @functionArgument } $Name $Argument
}

function Get-BRAVOInstallerStateRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ToolkitRoot)
    $paths = Invoke-BRAVOInstallerUpdateRead -ToolkitRoot $ToolkitRoot -Name 'Get-BRAVOUpdateDefaultPaths'
    [string]$paths.StateRoot
}

# --------------------------------------------------------------- Команди

function New-BRAVOInstallerPlanCommand {
    <#
    .SYNOPSIS
        BRAVO_UPDATE.ps1 -Action Plan -Operation Install|Update|Repair
        (-SourcePath <zip> | -Tag <vX.Y.Z>) [-AllowPrerelease]
        [-BackupDestination <режим>] [-RuntimeRoot <root>] -AsJson -ResultPath <file>
        Чиста функція. Plan нічого не змінює: engine будує план і staging
        лише для читання/перевірки джерела.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ToolkitRoot,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair')][string]$Operation,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [string]$SourcePath,
        [string]$Tag,
        [switch]$AllowPrerelease,
        [ValidateSet('', 'Cloud', 'CloudAndSamba', 'SambaOnly', 'LocalOnly')][string]$BackupDestination = '',
        [string]$RuntimeRoot,
        [string]$PowerShellPath = (Get-BRAVOInstallerPowerShellPath)
    )
    $hasSource = -not [string]::IsNullOrWhiteSpace($SourcePath)
    $hasTag = -not [string]::IsNullOrWhiteSpace($Tag)
    if ($hasSource -and $hasTag) { throw 'Вкажіть або локальний ZIP, або тег, але не обидва одразу.' }
    if ($hasTag -and $Tag.Trim() -notmatch '^v\d+\.\d+\.\d+(-[0-9A-Za-z][0-9A-Za-z.\-]*)?$') { throw "Недопустимий тег: $Tag" }
    $script = Join-Path $ToolkitRoot 'BRAVO_UPDATE.ps1'
    $arguments = @(
        '-NoProfile', '-NonInteractive',
        '-File', (ConvertTo-BRAVOInstallerQuotedArgument -Value $script),
        '-Action', 'Plan',
        '-Operation', $Operation
    )
    if ($hasSource) { $arguments += @('-SourcePath', (ConvertTo-BRAVOInstallerQuotedArgument -Value $SourcePath.Trim())) }
    if ($hasTag) { $arguments += @('-Tag', (ConvertTo-BRAVOInstallerQuotedArgument -Value $Tag.Trim())) }
    if ($AllowPrerelease) { $arguments += '-AllowPrerelease' }
    if (-not [string]::IsNullOrEmpty($BackupDestination)) { $arguments += @('-BackupDestination', $BackupDestination) }
    if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) { $arguments += @('-RuntimeRoot', (ConvertTo-BRAVOInstallerQuotedArgument -Value $RuntimeRoot)) }
    $arguments += @('-AsJson', '-ResultPath', (ConvertTo-BRAVOInstallerQuotedArgument -Value $ResultPath))
    New-BRAVOInstallerCommand -FilePath $PowerShellPath -Argument $arguments
}

function New-BRAVOInstallerExecuteCommand {
    <#
    .SYNOPSIS
        powershell.exe -NoProfile -File <toolkit>\BRAVO_UPDATE.ps1 -Action
        Execute -RequestPath <path> -NoPause; запускається через UAC
        (Verb = RunAs). Шлях запиту — єдиний дані-аргумент, секретів немає.
        Вікно НЕ приховується: оператор бачить консоль engine.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ToolkitRoot,
        [Parameter(Mandatory = $true)][string]$RequestPath,
        [string]$PowerShellPath = (Get-BRAVOInstallerPowerShellPath)
    )
    $script = Join-Path $ToolkitRoot 'BRAVO_UPDATE.ps1'
    $command = New-BRAVOInstallerCommand -FilePath $PowerShellPath -Argument @(
        '-NoProfile', '-File', (ConvertTo-BRAVOInstallerQuotedArgument -Value $script),
        '-Action', 'Execute', '-RequestPath', (ConvertTo-BRAVOInstallerQuotedArgument -Value $RequestPath), '-NoPause')
    $command | Add-Member -NotePropertyName Verb -NotePropertyValue 'RunAs' -PassThru
}

function New-BRAVOInstallerRecoverCommand {
    # Відновлення після переривання/відкат: engine сам читає журнал; GUI
    # лише запускає його через UAC у видимому вікні.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ToolkitRoot,
        [string]$RuntimeRoot,
        [string]$PowerShellPath = (Get-BRAVOInstallerPowerShellPath)
    )
    $script = Join-Path $ToolkitRoot 'BRAVO_UPDATE.ps1'
    $arguments = @('-NoProfile', '-File', (ConvertTo-BRAVOInstallerQuotedArgument -Value $script), '-Action', 'Recover')
    if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) { $arguments += @('-RuntimeRoot', (ConvertTo-BRAVOInstallerQuotedArgument -Value $RuntimeRoot)) }
    $arguments += '-NoPause'
    $command = New-BRAVOInstallerCommand -FilePath $PowerShellPath -Argument $arguments
    $command | Add-Member -NotePropertyName Verb -NotePropertyValue 'RunAs' -PassThru
}

function New-BRAVOInstallerCredentialsCommand {
    <#
    .SYNOPSIS
        Видиме консольне вікно канонічного налаштування облікових даних:
        powershell.exe -NoProfile -File <runtime>\BRAVO_SETUP.ps1 -Action Credentials.
        GUI секретів не бачить: ввід відбувається лише в тому вікні.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [string]$PowerShellPath = (Get-BRAVOInstallerPowerShellPath)
    )
    $script = Join-Path $RuntimeRoot 'BRAVO_SETUP.ps1'
    New-BRAVOInstallerCommand -FilePath $PowerShellPath -Argument @(
        '-NoProfile', '-File', (ConvertTo-BRAVOInstallerQuotedArgument -Value $script), '-Action', 'Credentials')
}

function New-BRAVOInstallerOpenLogCommand {
    # Показати файл журналу в провіднику (read-only): explorer /select,"<path>".
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [string]$SystemRoot = $env:SystemRoot
    )
    if ([string]::IsNullOrWhiteSpace($SystemRoot)) { $SystemRoot = 'C:\Windows' }
    $quoted = ConvertTo-BRAVOInstallerQuotedArgument -Value $LogPath
    New-BRAVOInstallerCommand -FilePath (Join-Path $SystemRoot 'explorer.exe') -Argument @('/select,' + $quoted)
}

# ------------------------------------------------------------- Запуск

function Start-BRAVOInstallerElevatedCommand {
    <#
    .SYNOPSIS
        Запускає команду з Verb RunAs (єдиний UAC). Відмову користувача в UAC
        (код 1223) повертає як Declined без винятку: нічого не змінювалось.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Command)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = [string]$Command.FilePath
    $psi.Arguments = [string]$Command.ArgumentString
    $psi.UseShellExecute = $true
    $psi.Verb = 'runas'
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        return [pscustomobject]@{ Started = $true; Declined = $false; Process = $process; Error = '' }
    } catch [System.ComponentModel.Win32Exception] {
        $declined = ($_.Exception.NativeErrorCode -eq 1223)
        return [pscustomobject]@{ Started = $false; Declined = $declined; Process = $null; Error = $_.Exception.Message }
    } catch {
        return [pscustomobject]@{ Started = $false; Declined = $false; Process = $null; Error = $_.Exception.Message }
    }
}

function Start-BRAVOInstallerVisibleConsole {
    # Видиме консольне вікно без перенаправлення вводу/виводу (для
    # інтерактивного вводу облікових даних). Повертає Process для опитування.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Command)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = [string]$Command.FilePath
    $psi.Arguments = [string]$Command.ArgumentString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    [System.Diagnostics.Process]::Start($psi)
}

# ------------------------------------------------------------- Запит

function Write-BRAVOInstallerExecutionRequest {
    <#
    .SYNOPSIS
        Записує запит у <StateRoot>\Requests\<requestId>.json (UTF-8 без BOM,
        атомарно: тимчасовий файл + Move). Перед записом запит проходить
        канонічний Test-BRAVOUpdateNoSecretProperty; будь-яка проблема або
        недоступність перевірки = виняток (fail closed, файл не створюється).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Request,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ToolkitRoot
    )
    $requestId = [string](Get-BRAVOInstallerProperty -InputObject $Request -Name 'requestId' -Default '')
    if ($requestId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'Запит має некоректний requestId.' }
    $check = Invoke-BRAVOInstallerUpdateRead -ToolkitRoot $ToolkitRoot -Name 'Test-BRAVOUpdateNoSecretProperty' -Argument @{ InputObject = $Request }
    if (-not $check.IsValid) { throw ('Запит містить поля секретів і не записаний: ' + (@($check.Problems) -join '; ')) }
    $json = $Request | ConvertTo-Json -Depth 20
    $encoding = New-Object System.Text.UTF8Encoding($false)
    if ($encoding.GetByteCount($json) -gt 1048576) { throw 'Запит перевищує 1 МіБ і не записаний.' }
    $directory = Join-Path $StateRoot 'Requests'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    $path = Join-Path $directory ($requestId + '.json')
    if (Test-Path -LiteralPath $path) { throw "Файл запиту вже існує: $path" }
    $temporary = $path + '.tmp'
    [IO.File]::WriteAllText($temporary, $json, $encoding)
    [IO.File]::Move($temporary, $path)
    $path
}

# ------------------------------------------------- Стан операції і cancel

function Get-BRAVOInstallerOperationDirectory {
    # <StateRoot>\Operations\<operationId>; operationId має бути GUID
    # (захист від обходу шляху через значення з плану).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot, [AllowNull()][string]$OperationId)
    if ($OperationId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $null }
    Join-Path (Join-Path $StateRoot 'Operations') $OperationId.ToLowerInvariant()
}

function Read-BRAVOInstallerExecutionState {
    <#
    .SYNOPSIS
        Читає (лише читання) progress.jsonl, result.json і журнал операції.
        Результат валідується Read-BRAVOUpdateContractFile: файл є, але
        невалідний = ResultPresent $true, ResultValid $false (fail closed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$ToolkitRoot
    )
    $directory = Get-BRAVOInstallerOperationDirectory -StateRoot $StateRoot -OperationId $OperationId
    $empty = [pscustomobject]@{ Events = @(); Result = $null; ResultPresent = $false; ResultValid = $false; ResultProblems = @(); Journal = $null; MutationStarted = $false; Directory = $directory }
    if ($null -eq $directory) { return $empty }
    $events = @(Read-BRAVOInstallerProgress -Path (Join-Path $directory 'progress.jsonl') -ToolkitRoot $ToolkitRoot)
    $result = $null
    $present = $false
    $valid = $false
    $problems = @()
    $resultPath = Join-Path $directory 'result.json'
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        $present = $true
        try {
            $read = Invoke-BRAVOInstallerUpdateRead -ToolkitRoot $ToolkitRoot -Name 'Read-BRAVOUpdateContractFile' -Argument @{ Path = $resultPath; Kind = 'DeploymentResult' }
            $valid = [bool]$read.IsValid
            $problems = @($read.Problems)
            if ($valid) { $result = $read.Contract }
        } catch {
            $problems = @($_.Exception.Message)
        }
    }
    $journal = $null
    $journalPath = Join-Path (Join-Path $StateRoot 'Journal') ($OperationId.ToLowerInvariant() + '.json')
    if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        try {
            $readJournal = Invoke-BRAVOInstallerUpdateRead -ToolkitRoot $ToolkitRoot -Name 'Read-BRAVOUpdateContractFile' -Argument @{ Path = $journalPath; Kind = 'UpdateJournal' }
            if ($readJournal.IsValid) { $journal = $readJournal.Contract }
        } catch { $journal = $null }
    }
    $started = Test-BRAVOInstallerMutationStarted -ProgressEvent $events -Journal $journal
    if ($present -and $valid) { $started = ($started -or [bool](Get-BRAVOInstallerProperty -InputObject $result -Name 'mutationStarted' -Default $false)) }
    [pscustomobject]@{ Events = @($events); Result = $result; ResultPresent = $present; ResultValid = $valid; ResultProblems = @($problems); Journal = $journal; MutationStarted = $started; Directory = $directory }
}

function New-BRAVOInstallerCancelRequest {
    <#
    .SYNOPSIS
        Створює порожній файл <opDir>\control\cancel. Каталог control\ створює
        engine (з ACL для запускача); якщо його ще немає — просимо повторити,
        самі каталог не створюємо (інакше підмінили б ACL engine). Процес
        engine не чіпаємо.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$OperationDirectory)
    if ([string]::IsNullOrWhiteSpace($OperationDirectory)) {
        return [pscustomobject]@{ Success = $false; Path = ''; Message = 'Каталог операції ще не визначено.' }
    }
    $control = Join-Path $OperationDirectory 'control'
    if (-not (Test-Path -LiteralPath $control -PathType Container)) {
        return [pscustomobject]@{ Success = $false; Path = ''; Message = 'Engine ще не створив каталог керування операцією. Спробуйте за кілька секунд.' }
    }
    $path = Join-Path $control 'cancel'
    try {
        $stream = New-Object System.IO.FileStream($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $stream.Dispose()
    } catch {
        return [pscustomobject]@{ Success = $false; Path = $path; Message = ('Не вдалося створити запит на зупинку: ' + $_.Exception.Message) }
    }
    [pscustomobject]@{ Success = $true; Path = $path; Message = 'Запит на зупинку надіслано.' }
}

function Get-BRAVOInstallerLogFile {
    # Перелік *.log (без рекурсії, лише читання). Відсутній каталог = порожньо.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LogsPath)
    if (-not (Test-Path -LiteralPath $LogsPath -PathType Container)) { return @() }
    @(Get-ChildItem -LiteralPath $LogsPath -Filter '*.log' -File -ErrorAction SilentlyContinue)
}
