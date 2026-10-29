# BRAVO.Installer.UI.Engine — запуск engine і допоміжних процесів з GUI.
# Правило: GUI ніколи не виконує довгу операцію у власному потоці й нічого не
# мутує. Read-only дії engine (State/Preflight) виконуються в ДОЧІРНЬОМУ
# процесі powershell.exe, результат — JSON-файл у приватному temp-каталозі.
# Побудова команд — чисті функції (тестуються без процесів); запуск — тонкий.
# Секретів у аргументах немає за конструкцією: жоден параметр їх не приймає.

# Корінь комплекту: <toolkit>\modules\BRAVO.Installer.UI\<ця частина>.
$script:BRAVOInstallerToolkitRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function ConvertTo-BRAVOInstallerQuotedArgument {
    # Один аргумент командного рядка Windows. Шлях з пробілами/кирилицею
    # береться в лапки; лапка всередині недопустима (fail closed — нема
    # надійного екранування для -File); кінцеві '\' подвоюються, інакше вони
    # екранують закривальну лапку.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Contains('"')) { throw "Аргумент містить лапку і не може бути безпечно переданий: $Value" }
    if ($Value -match '[\r\n]') { throw 'Аргумент містить символ нового рядка.' }
    $escaped = $Value
    if ($escaped -match '(\\+)$') { $escaped = $escaped + $Matches[1] }
    '"' + $escaped + '"'
}

function Get-BRAVOInstallerPowerShellPath {
    # Windows PowerShell 5.1 за фіксованим системним шляхом (не pwsh, не PATH).
    [CmdletBinding()]
    param([string]$SystemRoot = $env:SystemRoot)
    if ([string]::IsNullOrWhiteSpace($SystemRoot)) { $SystemRoot = 'C:\Windows' }
    Join-Path $SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

function New-BRAVOInstallerCommand {
    # Загальний конструктор «програма + аргументи»; ArgumentString — готовий
    # командний рядок для ProcessStartInfo.Arguments.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Argument
    )
    [pscustomobject]@{
        FilePath       = $FilePath
        Argument       = @($Argument)
        ArgumentString = (@($Argument) -join ' ')
    }
}

function New-BRAVOInstallerEngineCommand {
    <#
    .SYNOPSIS
        Команда read-only дії engine:
        powershell.exe -NoProfile -NonInteractive -File <toolkit>\BRAVO_UPDATE.ps1
            -Action State|Preflight -AsJson -ResultPath <file> [-RuntimeRoot <root>]
        Чиста функція: нічого не запускає й не читає з диска.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ToolkitRoot,
        [Parameter(Mandatory = $true)][ValidateSet('State', 'Preflight', 'Diagnose')][string]$Action,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [string]$RuntimeRoot,
        [string]$PowerShellPath = (Get-BRAVOInstallerPowerShellPath)
    )
    $script = Join-Path $ToolkitRoot 'BRAVO_UPDATE.ps1'
    $arguments = @(
        '-NoProfile', '-NonInteractive',
        '-File', (ConvertTo-BRAVOInstallerQuotedArgument -Value $script),
        '-Action', $Action,
        '-AsJson',
        '-ResultPath', (ConvertTo-BRAVOInstallerQuotedArgument -Value $ResultPath)
    )
    if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $arguments += @('-RuntimeRoot', (ConvertTo-BRAVOInstallerQuotedArgument -Value $RuntimeRoot))
    }
    New-BRAVOInstallerCommand -FilePath $PowerShellPath -Argument $arguments
}

function New-BRAVOInstallerConfiguratorCommand {
    # «Налаштування» запускають канонічний Configurator окремим процесом
    # (без вбудовування в v1 прототип).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ToolkitRoot,
        [string]$PowerShellPath = (Get-BRAVOInstallerPowerShellPath)
    )
    $script = Join-Path $ToolkitRoot 'BRAVO_CONFIGURATOR.ps1'
    New-BRAVOInstallerCommand -FilePath $PowerShellPath -Argument @(
        '-NoProfile', '-NonInteractive', '-File',
        (ConvertTo-BRAVOInstallerQuotedArgument -Value $script), '-NoPause')
}

function New-BRAVOInstallerLogsCommand {
    # «Журнали» лише відкривають каталог у провіднику (read-only).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LogsPath,
        [string]$SystemRoot = $env:SystemRoot
    )
    if ([string]::IsNullOrWhiteSpace($SystemRoot)) { $SystemRoot = 'C:\Windows' }
    New-BRAVOInstallerCommand -FilePath (Join-Path $SystemRoot 'explorer.exe') `
        -Argument @((ConvertTo-BRAVOInstallerQuotedArgument -Value $LogsPath))
}

function Get-BRAVOInstallerLogsPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ToolkitRoot, [string]$RuntimeRoot)
    $base = if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot } else { $ToolkitRoot }
    Join-Path $base 'LOGS'
}

function Test-BRAVOInstallerEngineAvailable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ToolkitRoot)
    Test-Path -LiteralPath (Join-Path $ToolkitRoot 'BRAVO_UPDATE.ps1') -PathType Leaf
}

function Invoke-BRAVOInstallerCommand {
    # Тонкий запуск: без оболонки, без вікна, без очікування. Повертає Process
    # (для власного процесу GUI; ми його ніколи не завершуємо примусово).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Command)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = [string]$Command.FilePath
    $psi.Arguments = [string]$Command.ArgumentString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [System.Diagnostics.Process]::Start($psi)
}

function New-BRAVOInstallerPrivateDirectory {
    # Приватний каталог результату під temp поточного користувача.
    [CmdletBinding()]
    param([string]$TempRoot = [IO.Path]::GetTempPath())
    $path = Join-Path $TempRoot ('BRAVO_INSTALLER_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $path -Force)
    $path
}

function Remove-BRAVOInstallerPrivateDirectory {
    # Видаляє лише каталог, створений цим модулем (перевірка префікса).
    [CmdletBinding()]
    param([AllowNull()][string]$Path, [string]$TempRoot = [IO.Path]::GetTempPath())
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $prefix = Join-Path $TempRoot 'BRAVO_INSTALLER_'
    if (-not $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Start-BRAVOInstallerEngineJob {
    <#
    .SYNOPSIS
        Запускає read-only дію engine прихованим дочірнім процесом із
        перенаправленим виводом і повертає handle для опитування таймером.
        Не блокує UI-потік. stdout/stderr читаються асинхронно (без deadlock
        при великому виводі).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ToolkitRoot,
        [Parameter(Mandatory = $true)][ValidateSet('State', 'Preflight', 'Diagnose', 'Plan')][string]$Action,
        [string]$RuntimeRoot,
        [string]$ProgressPath,
        [hashtable]$PlanOption = @{}
    )
    if (-not (Test-BRAVOInstallerEngineAvailable -ToolkitRoot $ToolkitRoot)) {
        throw 'Engine недоступний: BRAVO_UPDATE.ps1 не знайдено в каталозі комплекту.'
    }
    $privateDir = New-BRAVOInstallerPrivateDirectory
    try {
        $resultPath = Join-Path $privateDir 'result.json'
        if ($Action -eq 'Plan') {
            # Plan: параметри джерела й операції передає майстер (PlanOption).
            $command = New-BRAVOInstallerPlanCommand -ToolkitRoot $ToolkitRoot -ResultPath $resultPath -RuntimeRoot $RuntimeRoot @PlanOption
        } else {
            $command = New-BRAVOInstallerEngineCommand -ToolkitRoot $ToolkitRoot -Action $Action `
                -ResultPath $resultPath -RuntimeRoot $RuntimeRoot
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $command.FilePath
        $psi.Arguments = $command.ArgumentString
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        $process = [System.Diagnostics.Process]::Start($psi)
        # stdin не перенаправляємо (governance: лише через BomFree-helper); engine
        # запускається з -NonInteractive, тож на запиті зависнути не може.
        [pscustomobject]@{
            Action       = $Action
            Process      = $process
            StdOutTask   = $process.StandardOutput.ReadToEndAsync()
            StdErrTask   = $process.StandardError.ReadToEndAsync()
            ResultPath   = $resultPath
            ProgressPath = $ProgressPath
            PrivateDir   = $privateDir
            StartedUtc   = [DateTime]::UtcNow
            Command      = $command
        }
    } catch {
        Remove-BRAVOInstallerPrivateDirectory -Path $privateDir
        throw
    }
}

function Resolve-BRAVOInstallerPayload {
    # Engine може загорнути дані; приймаємо документований «голий» об'єкт і
    # кілька очевидних обгорток, інакше повертаємо як є.
    [CmdletBinding()]
    param([AllowNull()][object]$Data, [Parameter(Mandatory = $true)][ValidateSet('State', 'Preflight', 'Diagnose', 'Plan')][string]$Kind)
    $marker = switch ($Kind) { 'State' { 'state' } 'Diagnose' { 'sections' } 'Plan' { 'planId' } default { 'findings' } }
    if ($null -eq $Data) { return $null }
    if ($null -ne $Data.PSObject.Properties[$marker]) { return $Data }
    foreach ($wrapper in @('result', 'data', 'installationState', 'preflight', 'plan', 'report')) {
        $inner = Get-BRAVOInstallerProperty -InputObject $Data -Name $wrapper
        if ($null -ne $inner -and $null -ne $inner.PSObject.Properties[$marker]) { return $inner }
    }
    $Data
}

function Get-BRAVOInstallerEngineJobStatus {
    <#
    .SYNOPSIS
        Неблокуюче опитування handle. Completed=$false, поки процес працює.
        Після завершення: ExitCode, StdOut/StdErr, Data (розібраний JSON) або Error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Handle,
        [int]$TimeoutSeconds = 120
    )
    $elapsed = ([DateTime]::UtcNow - $Handle.StartedUtc).TotalSeconds
    if (-not $Handle.Process.HasExited) {
        # Процес не завершуємо примусово: лише повідомляємо про перевищення часу.
        return [pscustomobject]@{ Completed = $false; TimedOut = ($elapsed -gt $TimeoutSeconds); ElapsedSeconds = $elapsed
            ExitCode = $null; StdOut = ''; StdErr = ''; Data = $null; Error = '' }
    }
    $Handle.Process.WaitForExit()
    $stdout = ''
    $stderr = ''
    try { $stdout = [string]$Handle.StdOutTask.Result } catch { $stdout = '' }
    try { $stderr = [string]$Handle.StdErrTask.Result } catch { $stderr = '' }
    $data = $null
    $errorText = ''
    if (Test-Path -LiteralPath $Handle.ResultPath -PathType Leaf) {
        try {
            $raw = [IO.File]::ReadAllText($Handle.ResultPath, [Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($raw)) { $errorText = 'Engine повернув порожній результат.' }
            else { $data = Resolve-BRAVOInstallerPayload -Data ($raw | ConvertFrom-Json) -Kind $Handle.Action }
        } catch {
            $errorText = "Не вдалося розібрати результат engine: $($_.Exception.Message)"
        }
    } else {
        $errorText = "Engine завершився з кодом $($Handle.Process.ExitCode) без файлу результату."
    }
    [pscustomobject]@{ Completed = $true; TimedOut = $false; ElapsedSeconds = $elapsed
        ExitCode = $Handle.Process.ExitCode; StdOut = $stdout; StdErr = $stderr; Data = $data; Error = $errorText }
}

function Read-BRAVOInstallerProgress {
    <#
    .SYNOPSIS
        Читає progress.jsonl (лише читання) ЛИШЕ канонічним
        Read-BRAVOUpdateProgressEvents з BRAVO.Update через read-only міст
        Invoke-BRAVOInstallerUpdateRead (WizardEngine). Власного запасного
        читача JSONL немає: недоступний модуль engine = виняток (fail closed).
        Нечитабельні/«рвані» рядки пропускає сам канонічний читач.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Path, [string]$ToolkitRoot = $script:BRAVOInstallerToolkitRoot)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(Invoke-BRAVOInstallerUpdateRead -ToolkitRoot $ToolkitRoot -Name 'Read-BRAVOUpdateProgressEvents' -Argument @{ Path = $Path })
}