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
        і повертає { ExitCode, Output, TimedOut }.
    .DESCRIPTION
        Секрети в аргументи НЕ передаються (лише шляхи та імена компонентів).
        Завершується лише власний дочірній процес (за об'єктом Process, що
        створив цей виклик) і лише після таймауту.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ScriptArgument = @(),
        [int]$TimeoutSeconds = 600
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        return [pscustomobject]@{ ExitCode = -1; Output = "Скрипт не знайдено: $ScriptPath"; TimedOut = $false }
    }
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) { $powershellPath = 'powershell.exe' }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($fixed in @('-NoProfile', '-NonInteractive', '-File')) { $parts.Add($fixed) }
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

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { <# власний дочірній процес міг завершитись між WaitForExit і Kill — гонитва очікувана #> }
            return [pscustomobject]@{ ExitCode = -1; Output = "Таймаут $TimeoutSeconds с: $ScriptPath"; TimedOut = $true }
        }
        $process.WaitForExit()
        $text = [string]$stdoutTask.Result
        $errText = [string]$stderrTask.Result
        if (-not [string]::IsNullOrWhiteSpace($errText)) { $text = $text + [Environment]::NewLine + $errText }
        return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Output = $text; TimedOut = $false }
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
          GetManagedTasks        param([string]$TaskPath, [string]$RuntimeRoot)   (обидва необов'язкові)
                                 -> масив { Name, Path, Exists, State, Enabled, actionPath } (порожній, якщо задач немає);
                                 COM Schedule.Service, лише TaskPath і імена з ефективної конфігурації
          SetTaskEnabled         param([string]$TaskPath, [string]$Name, [bool]$Enabled, [string]$RuntimeRoot)
                                 -> { Success, Message }; TaskPath/ім'я поза ефективною конфігурацією -> виняток
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

    $adapter.InvokeGuard = {
        param([string]$RuntimeRoot)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        Invoke-BRAVOUpdateChildProcess -ScriptPath (Join-Path $RuntimeRoot 'BRAVO_RUNTIME_GUARD.ps1') `
            -ScriptArgument @('-RuntimeRoot', $RuntimeRoot, '-Mode', 'Enforce') -TimeoutSeconds 300
    }
    $adapter.InvokeSetupScheduler = {
        param([string]$RuntimeRoot)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        Invoke-BRAVOUpdateChildProcess -ScriptPath (Join-Path $RuntimeRoot 'BRAVO_SETUP.ps1') `
            -ScriptArgument @('-Action', 'Scheduler', '-NoPause') -TimeoutSeconds 900
    }
    $adapter.InvokeSetupValidate = {
        param([string]$RuntimeRoot)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        Invoke-BRAVOUpdateChildProcess -ScriptPath (Join-Path $RuntimeRoot 'BRAVO_SETUP.ps1') `
            -ScriptArgument @('-ValidateOnly', '-SkipAccessTest', '-SkipTestNotification', '-NoPause') -TimeoutSeconds 900
    }
    $adapter.InvokeSelfTest = {
        param([string]$RuntimeRoot)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        Invoke-BRAVOUpdateChildProcess -ScriptPath (Join-Path $RuntimeRoot 'BRAVO_SELF_TEST.ps1') `
            -ScriptArgument @('-NoPause') -TimeoutSeconds 3600
    }
    # Посилання на фінальний (замкнений) adapter: GetManagedTasks/SetTaskEnabled
    # викликають його GetEffectiveConfiguration, щоб область задач (TaskPath +
    # імена) визначав канонічний loader, а не hardcode (ENGINE_DESIGN.md, 5).
    $holder = @{ Adapter = $null }

    $adapter.GetManagedTasks = {
        param([string]$TaskPath, [string]$RuntimeRoot)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        $getConfiguration = $holder.Adapter['GetEffectiveConfiguration']
        $effective = & $getConfiguration $RuntimeRoot
        if (($null -eq $effective) -or (-not [bool]$effective.Success)) {
            throw 'BRAVO.Update: ефективну конфігурацію scheduler не прочитано (fail closed).'
        }
        $scope = Get-BRAVOUpdateManagedTaskScope -Configuration $effective.Configuration
        # Явний TaskPath поза ефективним — не наша область: виняток, а не порожній результат.
        if ((-not [string]::IsNullOrWhiteSpace($TaskPath)) -and
            (-not [string]::Equals((ConvertTo-BRAVOUpdateTaskPath -TaskPath $TaskPath), $scope.TaskPath, [StringComparison]::OrdinalIgnoreCase))) {
            throw "BRAVO.Update: TaskPath '$TaskPath' не є каталогом керованих задач."
        }
        $comPath = $scope.TaskPath
        if ($comPath -ne '\') { $comPath = $comPath.TrimEnd('\') }
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $folder = $null
        try { $folder = $service.GetFolder($comPath) } catch { $folder = $null }
        if ($null -eq $folder) { return @() }
        $stateNames = @{ 0 = 'Unknown'; 1 = 'Disabled'; 2 = 'Queued'; 3 = 'Ready'; 4 = 'Running' }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($name in $scope.Names) {
            $task = $null
            try { $task = $folder.GetTask($name) } catch { $task = $null }
            if ($null -eq $task) { continue }
            # Шлях скрипта з аргументів дії (-File "..."): Discovery виводить із нього кандидатів root.
            $actionPath = ''
            try {
                foreach ($action in $task.Definition.Actions) {
                    if ([int]$action.Type -ne 0) { continue }
                    $arguments = [string]$action.Arguments
                    if ($arguments -match '-File\s+"([^"]+)"') { $actionPath = $Matches[1] }
                    elseif ($arguments -match '-File\s+(\S+)') { $actionPath = $Matches[1] }
                    else { $actionPath = [string]$action.Path }
                    break
                }
            } catch { $actionPath = '' }
            $stateValue = [int]$task.State
            $stateText = 'Unknown'
            if ($stateNames.ContainsKey($stateValue)) { $stateText = [string]$stateNames[$stateValue] }
            $rows.Add([pscustomobject]@{
                Name       = [string]$name
                Path       = $scope.TaskPath
                Exists     = $true
                State      = $stateText
                Enabled    = [bool]$task.Enabled
                actionPath = $actionPath
            })
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($task)
        }
        return @($rows.ToArray())
    }
    $adapter.SetTaskEnabled = {
        param([string]$TaskPath, [string]$Name, [bool]$Enabled, [string]$RuntimeRoot)
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = $ToolkitRoot }
        $getConfiguration = $holder.Adapter['GetEffectiveConfiguration']
        $effective = & $getConfiguration $RuntimeRoot
        if (($null -eq $effective) -or (-not [bool]$effective.Success)) {
            throw 'BRAVO.Update: ефективну конфігурацію scheduler не прочитано (fail closed).'
        }
        $scope = Get-BRAVOUpdateManagedTaskScope -Configuration $effective.Configuration
        # Лише TaskPath з ефективної конфігурації і лише керовані імена, інакше виняток.
        if (-not [string]::Equals((ConvertTo-BRAVOUpdateTaskPath -TaskPath $TaskPath), $scope.TaskPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "BRAVO.Update: TaskPath '$TaskPath' не є каталогом керованих задач."
        }
        $managed = $false
        foreach ($known in $scope.Names) { if ([string]::Equals($known, $Name, [StringComparison]::OrdinalIgnoreCase)) { $managed = $true } }
        if (-not $managed) { throw "BRAVO.Update: задача '$Name' не є керованою." }
        $comPath = $scope.TaskPath
        if ($comPath -ne '\') { $comPath = $comPath.TrimEnd('\') }
        $task = $null
        try {
            $service = New-Object -ComObject 'Schedule.Service'
            $service.Connect()
            $task = $service.GetFolder($comPath).GetTask($Name)
            $task.Enabled = $Enabled
            # Перевірка наслідку: COM міг не застосувати зміну без винятку.
            $confirmed = ([bool]$service.GetFolder($comPath).GetTask($Name).Enabled -eq $Enabled)
            if (-not $confirmed) { return [pscustomobject]@{ Success = $false; Message = "Task Scheduler не підтвердив зміну стану '$Name'." } }
            [pscustomobject]@{ Success = $true; Message = '' }
        } catch {
            [pscustomobject]@{ Success = $false; Message = [string]$_.Exception.Message }
        } finally {
            if ($null -ne $task) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($task) }
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
    $holder.Adapter = $closed
    return $closed
}
