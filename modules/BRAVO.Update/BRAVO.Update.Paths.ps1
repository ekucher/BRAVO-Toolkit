# BRAVO.Update.Paths — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Шляхи за замовчуванням і adapter зовнішніх side effects. Усі інші функції
# engine приймають корені явними параметрами; production-значення
# обчислюються лише тут (CONTRACTS §1).

function Get-BRAVOUpdateDefaultPaths {
    <#
    .SYNOPSIS
        Повертає production-корені Installer v1. Нічого не створює на диску.
    .DESCRIPTION
        ProgramData береться через [Environment]::GetFolderPath, а не з
        $env:ProgramData: змінна середовища може бути підмінена або порожня
        в обмеженому контексті scheduled task.
    #>
    [CmdletBinding()]
    param()

    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    if ([string]::IsNullOrWhiteSpace($programData) -or [string]::IsNullOrWhiteSpace($programFiles)) {
        throw 'BRAVO.Update: не вдалося визначити ProgramData/ProgramFiles (fail closed).'
    }
    $bravoRoot = Join-Path $programData 'BRAVO'
    $lockRoot = Join-Path $bravoRoot 'Locks'
    return [pscustomobject]@{
        StateRoot         = (Join-Path $bravoRoot 'State\Update')
        LockRoot          = $lockRoot
        StagingRoot       = (Join-Path $bravoRoot 'Update\Staging')
        BackupRoot        = (Join-Path $bravoRoot 'Update\Backup')
        RuntimeRoot       = (Join-Path $programFiles 'BRAVO-Toolkit')
        OperationLockPath = (Join-Path $lockRoot 'BRAVO_OPERATION.lock')
        # Той самий production-шлях, що жорстко задають guard-викликачі
        # (BRAVO_ARCHIV.ps1 тощо); engine лише знімає й відновлює його
        # знімок у межах транзакції (ENGINE_DESIGN.md, розділ 7.2).
        VersionStatePath  = (Join-Path $bravoRoot 'State\BRAVO_VERSION_STATE.json')
    }
}

function Get-BRAVOUpdateFullPath {
    <#
    .SYNOPSIS
        Нормалізує шлях (GetFullPath: згортає '.'/'..', подвійні роздільники)
        і прибирає кінцеві роздільники (крім кореня диска).
    .DESCRIPTION
        Кидає виняток для порожнього або невалідного шляху: викликач, якому
        потрібен булів результат, використовує Test-BRAVOUpdatePathIsUnder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'BRAVO.Update: порожній шлях.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    $rootOfPath = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $rootOfPath.Length) {
        $full = $full.TrimEnd([char]'\', [char]'/')
    }
    return $full
}

function Test-BRAVOUpdatePathIsUnder {
    <#
    .SYNOPSIS
        $true, якщо Path лежить строго всередині Root (без урахування регістру,
        після нормалізації).
    .DESCRIPTION
        Нормалізація ПЕРЕД порівнянням закриває обхід через '..'
        (C:\Root\..\Other не є підкаталогом C:\Root) і плутанину префіксів
        (C:\RootX не є підкаталогом C:\Root: порівнюємо з роздільником).
        Збіг із Root дає $false, якщо не вказано -AllowEqual. Будь-яка
        помилка нормалізації — $false (fail closed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Root,
        [switch]$AllowEqual
    )

    try {
        $fullPath = Get-BRAVOUpdateFullPath -Path $Path
        $fullRoot = Get-BRAVOUpdateFullPath -Path $Root
    } catch {
        return $false
    }
    if ([string]::Equals($fullPath, $fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return [bool]$AllowEqual
    }
    $prefix = $fullRoot
    if (-not $prefix.EndsWith('\')) { $prefix = $prefix + '\' }
    return $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-BRAVOUpdateQuotedArgument {
    # Лапкування одного аргументу за правилами CommandLineToArgvW: шлях із
    # пробілами/кирилицею лишається одним аргументом; кінцеві '\' перед
    # закриваючою лапкою подвоюються. Значення з вбудованою '"' відхиляємо.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value.Contains('"')) {
        throw 'BRAVO.Update: аргумент дочірнього процесу не може містити лапку.'
    }
    return '"' + ([regex]::Replace($Value, '(\\*)$', '$1$1')) + '"'
}

function Invoke-BRAVOUpdateChildProcess {
    <#
    .SYNOPSIS
        Запускає powershell.exe -NoProfile -NonInteractive -File <Script> ...
        і повертає { ExitCode, Output, TimedOut, LogPath }.
    .DESCRIPTION
        Секрети в аргументи НЕ передаються (лише шляхи та імена компонентів).
        Завершується лише власний дочірній процес (за об'єктом Process, що
        створив цей виклик, тобто за його handle, а не за ім'ям чи віком) і
        лише після таймауту.
        -ExecutionPolicy RemoteSigned (не Bypass): політика машини не
        послаблюється до повного обходу (ENGINE_DESIGN §6).
        Вивід ЗАВЖДИ проходить Protect-BRAVOLogSecret перед поверненням і
        записом у -LogPath; якщо маскувальник недоступний, вивід не
        повертається (fail closed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ScriptArgument = @(),
        [int]$TimeoutSeconds = 600,
        [string]$WorkingDirectory = '',
        [string]$LogPath = ''
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        return [pscustomobject]@{ ExitCode = -1; Output = "Скрипт не знайдено: $ScriptPath"; TimedOut = $false; LogPath = $null }
    }
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) { $powershellPath = 'powershell.exe' }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($fixed in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned', '-File')) { $parts.Add($fixed) }
    $parts.Add((ConvertTo-BRAVOUpdateQuotedArgument -Value $ScriptPath))
    foreach ($argument in @($ScriptArgument)) {
        # Перемикачі й імена параметрів (-NoPause, -Action) не лапкуємо;
        # значення (шляхи, імена) — лапкуємо.
        if ($argument -match '^-[A-Za-z]+$') { $parts.Add($argument) } else { $parts.Add((ConvertTo-BRAVOUpdateQuotedArgument -Value $argument)) }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellPath
    $startInfo.Arguments = [string]::Join(' ', $parts.ToArray())
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $startInfo.WorkingDirectory = $WorkingDirectory }

    # Маскування секретів ДО повернення й запису в лог. Модуль BRAVO.Logging
    # підключає Initialize-BRAVOUpdateDiagLogging (частина Diagnostics).
    $maskingAvailable = $true
    try {
        Initialize-BRAVOUpdateDiagLogging
    } catch {
        $maskingAvailable = $false
    }
    $mask = {
        param([string]$Raw)
        if (-not $maskingAvailable) { return '[вивід приховано: маскування секретів недоступне]' }
        return [string](Protect-BRAVOLogSecret -Text $Raw)
    }
    $writeLog = {
        param([string]$MaskedText)
        if ([string]::IsNullOrWhiteSpace($LogPath)) { return $null }
        try {
            $logDirectory = Split-Path -Parent $LogPath
            if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and -not [IO.Directory]::Exists($logDirectory)) {
                [void][IO.Directory]::CreateDirectory($logDirectory)
            }
            [IO.File]::WriteAllText($LogPath, $MaskedText, (New-Object System.Text.UTF8Encoding($false)))
            return $LogPath
        } catch {
            # Лог допоміжний: збій запису не має ховати код виходу дочірнього процесу.
            return $null
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Лише власний об'єкт Process (handle, отриманий зі Start): PID міг
            # би бути перевикористаний, handle — ні.
            try { $process.Kill() } catch { <# власний дочірній процес міг завершитись між WaitForExit і Kill — гонитва очікувана #> }
            $timeoutText = & $mask "Таймаут $TimeoutSeconds с: $ScriptPath"
            $timeoutLog = & $writeLog $timeoutText
            return [pscustomobject]@{ ExitCode = -1; Output = $timeoutText; TimedOut = $true; LogPath = $timeoutLog }
        }
        $process.WaitForExit()
        $text = [string]$stdoutTask.Result
        $errText = [string]$stderrTask.Result
        if (-not [string]::IsNullOrWhiteSpace($errText)) { $text = $text + [Environment]::NewLine + $errText }
        $maskedText = & $mask $text
        $writtenLog = & $writeLog $maskedText
        return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Output = $maskedText; TimedOut = $false; LogPath = $writtenLog }
    } finally {
        $process.Dispose()
    }
}

function New-BRAVOUpdateDefaultAdapter {
    <#
    .SYNOPSIS
        Production adapter зовнішніх side effects (CONTRACTS §1). Тести та
        failure injection підставляють власні scriptblock-и під тими самими
        ключами.
    .DESCRIPTION
        Сигнатури scriptblock-ів (повертають PSCustomObject):
          InvokeGuard            param([string]$RuntimeRoot)
                                 -> { ExitCode, Output, TimedOut }
          InvokeSetupScheduler   param([string]$RuntimeRoot)   (BRAVO_SETUP.ps1 -Action Scheduler -NoPause)
          InvokeSetupValidate    param([string]$RuntimeRoot)   (BRAVO_SETUP.ps1 -ValidateOnly -SkipAccessTest -SkipTestNotification -NoPause)
          InvokeSelfTest         param([string]$RuntimeRoot)   (BRAVO_SELF_TEST.ps1 -NoPause)
                                 -> { ExitCode, Output, TimedOut }
          GetManagedTasks        param([string]$TaskPath)
                                 -> масив { Name, Path, Exists, State, Enabled } (порожній, якщо задач немає)
          SetTaskEnabled         param([string]$TaskPath, [string]$Name, [bool]$Enabled)
                                 -> { Success, Message }
          TestCredentialPresence param([string]$RuntimeRoot, [string]$Component)
                                 -> { Component, Presence (Found|Missing|Unknown), ExitCode }
                                 (BRAVO_CREDENTIALS_SETUP.ps1 -Action Test; код 0 = Found; секрет не читається й не передається)
          GetEffectiveConfiguration param([string]$RuntimeRoot)
                                 -> { Success, ExitCode, Configuration, Message }; Configuration — лише
                                 componentSettings/pathSettings/maintenanceSettings/schedulerSettings
                                 (БЕЗ credentialSettings), обчислені канонічним
                                 Import-BravoConfiguration у дочірньому процесі
                                 (глобальні змінні лоадера не потрапляють у процес engine).
          Now                    param() -> [datetime] UTC
        Якщо RuntimeRoot не передано, використовується ToolkitRoot (корінь
        інструментарію, з якого запущено engine).
    #>
    [CmdletBinding()]
    param([string]$ToolkitRoot = $script:BRAVOUpdateToolkitRoot)

    $adapter = @{}

    # Другий параметр $LogPath необов'язковий (Validation передає шлях логу в
    # <opDir>\logs; stub-адаптери з одним параметром його ігнорують).
    # Прямий запуск guard сам викликає Test-BRAVOVersionDowngrade -NoWrite (F5).
    $adapter.InvokeGuard = {
        param([string]$RuntimeRoot, [string]$LogPath)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        Invoke-BRAVOUpdateChildProcess -ScriptPath (Join-Path $RuntimeRoot 'BRAVO_RUNTIME_GUARD.ps1') `
            -ScriptArgument @('-RuntimeRoot', $RuntimeRoot, '-Mode', 'Enforce') -TimeoutSeconds 300 -LogPath $LogPath
    }
    $adapter.InvokeSetupScheduler = {
        param([string]$RuntimeRoot, [string]$LogPath)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        Invoke-BRAVOUpdateChildProcess -ScriptPath (Join-Path $RuntimeRoot 'BRAVO_SETUP.ps1') `
            -ScriptArgument @('-Action', 'Scheduler', '-SkipTestNotification', '-NoElevation', '-NoPause') -TimeoutSeconds 900 -LogPath $LogPath
    }
    $adapter.InvokeSetupValidate = {
        param([string]$RuntimeRoot, [string]$LogPath)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        Invoke-BRAVOUpdateChildProcess -ScriptPath (Join-Path $RuntimeRoot 'BRAVO_SETUP.ps1') `
            -ScriptArgument @('-ValidateOnly', '-SkipAccessTest', '-SkipTestNotification', '-NoElevation', '-NoPause') -TimeoutSeconds 900 -LogPath $LogPath
    }
    $adapter.InvokeSelfTest = {
        param([string]$RuntimeRoot, [string]$LogPath)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        Invoke-BRAVOUpdateChildProcess -ScriptPath (Join-Path $RuntimeRoot 'BRAVO_SELF_TEST.ps1') `
            -ScriptArgument @('-NoPause') -TimeoutSeconds 3600 -LogPath $LogPath
    }
    $adapter.GetManagedTasks = {
        param([string]$TaskPath)
        $normalized = '\' + $TaskPath.Trim('\') + '\'
        $found = @()
        try {
            $found = @(Get-ScheduledTask -TaskPath $normalized -ErrorAction Stop)
        } catch {
            # Немає такого каталогу задач або немає доступу: порожній результат;
            # викликач відрізняє «немає» від «невідомо» своїми finding-ами.
            $found = @()
        }
        foreach ($task in $found) {
            [pscustomobject]@{
                Name    = [string]$task.TaskName
                Path    = [string]$task.TaskPath
                Exists  = $true
                State   = [string]$task.State
                Enabled = ([string]$task.State -ne 'Disabled')
            }
        }
    }
    $adapter.SetTaskEnabled = {
        param([string]$TaskPath, [string]$Name, [bool]$Enabled)
        $normalized = '\' + $TaskPath.Trim('\') + '\'
        try {
            if ($Enabled) {
                [void](Enable-ScheduledTask -TaskPath $normalized -TaskName $Name -ErrorAction Stop)
            } else {
                [void](Disable-ScheduledTask -TaskPath $normalized -TaskName $Name -ErrorAction Stop)
            }
            [pscustomobject]@{ Success = $true; Message = '' }
        } catch {
            [pscustomobject]@{ Success = $false; Message = [string]$_.Exception.Message }
        }
    }
    $adapter.TestCredentialPresence = {
        param([string]$RuntimeRoot, [string]$Component)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        $run = Invoke-BRAVOUpdateChildProcess -ScriptPath (Join-Path $RuntimeRoot 'BRAVO_CREDENTIALS_SETUP.ps1') `
            -ScriptArgument @('-Action', 'Test', '-Component', $Component) -TimeoutSeconds 120
        $presence = 'Unknown'
        if (-not $run.TimedOut) {
            if ($run.ExitCode -eq 0) { $presence = 'Found' } elseif ($run.ExitCode -gt 0) { $presence = 'Missing' }
        }
        [pscustomobject]@{ Component = $Component; Presence = $presence; ExitCode = $run.ExitCode }
    }
    $adapter.GetEffectiveConfiguration = {
        param([string]$RuntimeRoot)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        # Дочірній скрипт пишеться у тимчасовий каталог UTF-8 З BOM, шляхи
        # передаються аргументами (не вбудовуються в текст: кирилиця/апостроф).
        $workDir = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_UPDATE_EFFECTIVE_' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($workDir)
        try {
            $childPath = Join-Path $workDir 'Get-Effective.ps1'
            $resultPath = Join-Path $workDir 'effective.json'
            $lines = @(
                'param([string]$RuntimeRoot, [string]$ResultPath)',
                'Set-StrictMode -Version 2.0',
                '$ErrorActionPreference = ''Stop''',
                '. (Join-Path $RuntimeRoot ''BRAVO_CONFIG_LOADER.ps1'')',
                '$null = Import-BravoConfiguration -ConfigRoot $RuntimeRoot -RuntimeRoot $RuntimeRoot -DisallowLegacyPrimaryAutoDetect -PassThru',
                '$snapshot = [ordered]@{}',
                'foreach ($name in @(''componentSettings'', ''pathSettings'', ''maintenanceSettings'', ''schedulerSettings'')) {',
                '    $variable = Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue',
                '    $snapshot[$name] = if ($null -ne $variable) { $variable.Value } else { $null }',
                '}',
                '$snapshot | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ResultPath -Encoding UTF8'
            )
            [IO.File]::WriteAllText($childPath, ([string]::Join([Environment]::NewLine, $lines)), (New-Object System.Text.UTF8Encoding($true)))
            $run = Invoke-BRAVOUpdateChildProcess -ScriptPath $childPath -ScriptArgument @($RuntimeRoot, $resultPath) -TimeoutSeconds 120
            if ($run.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
                return [pscustomobject]@{ Success = $false; ExitCode = $run.ExitCode; Configuration = $null; Message = $run.Output }
            }
            $configuration = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
            return [pscustomobject]@{ Success = $true; ExitCode = 0; Configuration = $configuration; Message = '' }
        } catch {
            return [pscustomobject]@{ Success = $false; ExitCode = -1; Configuration = $null; Message = [string]$_.Exception.Message }
        } finally {
            if ((Test-BRAVOUpdatePathIsUnder -Path $workDir -Root ([IO.Path]::GetTempPath())) -and (Test-Path -LiteralPath $workDir)) {
                Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    $adapter.Now = {
        [datetime]::UtcNow
    }

    # Замикання фіксує $ToolkitRoot; scriptblock-и лишаються в області модуля
    # й бачать Invoke-BRAVOUpdateChildProcess.
    $closed = @{}
    foreach ($key in @($adapter.Keys)) { $closed[$key] = $adapter[$key].GetNewClosure() }
    return $closed
}
