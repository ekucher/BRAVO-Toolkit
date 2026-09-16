<#
    precompact-checkpoint.ps1
    Хук PreCompact для Claude Code.

    Отримує на stdin JSON із полями session_id, transcript_path, cwd,
    hook_event_name, trigger ("auto" або "manual") і custom_instructions.
    Пише контрольну точку в .claude/task-history/<session_id>/ і мовчки
    завершується. Кожен виклик і кожна помилка потрапляють у
    .claude/logs/precompact.log.

    Викликати обов'язково з -NoProfile: якщо профіль PowerShell щось друкує
    при старті, це ламає розбір JSON, який хук повертає Claude Code.
#>
$ErrorActionPreference = 'Stop'

# ConvertTo-SafeSessionId — канонічна санітизація session_id, спільна з
# save-task.ps1. Dot-source у власному try/catch: хук не повинен впасти
# лише через те, що lib/SafePath.ps1 відсутній чи пошкоджений.
try {
    . (Join-Path $PSScriptRoot 'lib\SafePath.ps1')
}
catch {
    function ConvertTo-SafeSessionId {
        param([AllowEmptyString()][AllowNull()][string]$SessionId, [string]$Fallback = 'unknown-session')
        $value = if ($null -eq $SessionId) { '' } else { $SessionId }
        $value = $value -replace '[^A-Za-z0-9._-]', ''
        if ([string]::IsNullOrWhiteSpace($value) -or $value -match '^\.+$') { return $Fallback }
        return $value
    }
}

$logFile = $null

function Write-HookLog {
    param([string]$Message, [string]$Level = 'INFO')
    if (-not $logFile) { return }
    try {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -Path $logFile -Value $line -Encoding UTF8
    }
    catch { }
}

# Що б не сталося — хук не має валити сесію.
try {
        # stdin читаємо явно як UTF-8: Windows PowerShell 5.1 інакше візьме OEM CP866.
    $stdinStream = [Console]::OpenStandardInput()
    $reader = New-Object System.IO.StreamReader($stdinStream, (New-Object System.Text.UTF8Encoding($false)), $true)
    $stdin = $reader.ReadToEnd()
    $reader.Dispose()
    $data  = if ([string]::IsNullOrWhiteSpace($stdin)) { $null } else { $stdin | ConvertFrom-Json }

    $projectDir = $env:CLAUDE_PROJECT_DIR
    if ([string]::IsNullOrWhiteSpace($projectDir)) {
        $projectDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    }

    # Лог піднімаємо якнайраніше, щоб він застав і подальші помилки.
    $logDir = Join-Path $projectDir '.claude\logs'
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    $logFile = Join-Path $logDir 'precompact.log'

    $trigger = if ($data -and $data.trigger) { [string]$data.trigger } else { 'unknown' }

    # Ідентифікатор сесії — це ім'я підпапки, тому пропускаємо його через
    # ConvertTo-SafeSessionId (lib/SafePath.ps1) перед будь-яким
    # використанням у шляху.
    $rawSessionId = if ($data -and $data.session_id) { [string]$data.session_id } else { '' }
    $sessionId = ConvertTo-SafeSessionId -SessionId $rawSessionId

    Write-HookLog "Виклик: trigger=$trigger session=$sessionId"

    $sessionDir = Join-Path (Join-Path $projectDir '.claude\task-history') $sessionId
    if (-not (Test-Path $sessionDir)) {
        New-Item -Path $sessionDir -ItemType Directory -Force | Out-Null
        Write-HookLog "Створено папку сесії: $sessionDir"
    }

    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outFile = Join-Path $sessionDir "compact-$stamp-$trigger.md"

    # Скільки компакцій уже було в цій сесії — корисно бачити в заголовку.
    $seq = @(Get-ChildItem -Path $sessionDir -Filter 'compact-*.md' -File -ErrorAction SilentlyContinue).Count + 1

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Контрольна точка $seq перед компакцією")
    $lines.Add('')
    $lines.Add("- Час: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("- Тригер: $trigger")
    $lines.Add("- Сесія: $sessionId")
    if ($data) {
        $lines.Add("- Робоча папка: $($data.cwd)")
        if ($data.custom_instructions) {
            $lines.Add("- Інструкції до компакції: $($data.custom_instructions)")
        }
    }
    $lines.Add('')

    # Останні запити користувача з транскрипту (jsonl), якщо він доступний.
    if ($data -and $data.transcript_path -and (Test-Path $data.transcript_path)) {
        $prompts = New-Object System.Collections.Generic.List[string]

        foreach ($line in (Get-Content -Path $data.transcript_path -Encoding UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $entry = $line | ConvertFrom-Json } catch { continue }

            if ($entry.type -eq 'user' -and $entry.message -and
                $entry.message.content -is [string] -and
                -not [string]::IsNullOrWhiteSpace($entry.message.content)) {
                $prompts.Add($entry.message.content)
            }
        }

        if ($prompts.Count -gt 0) {
            $take = [Math]::Min(10, $prompts.Count)
            $lines.Add('## Останні запити користувача')
            $lines.Add('')
            foreach ($p in $prompts[($prompts.Count - $take)..($prompts.Count - 1)]) {
                $short = $p -replace '\s+', ' '
                if ($short.Length -gt 300) { $short = $short.Substring(0, 300) + '…' }
                $lines.Add("- $short")
            }
            $lines.Add('')
        }
        else {
            Write-HookLog 'У транскрипті не знайдено текстових запитів користувача.' 'WARN'
        }
    }
    elseif ($data -and $data.transcript_path) {
        Write-HookLog "Транскрипт недоступний: $($data.transcript_path)" 'WARN'
    }

    $lines.Add('## Нотатки')
    $lines.Add('')
    $lines.Add('_Заповніть вручну те, що важливо зберегти після стиснення._')

    Set-Content -Path $outFile -Value ($lines -join "`r`n") -Encoding UTF8
    Write-HookLog "Записано: $outFile"
}
catch {
    # Збій хука не повинен блокувати компакцію — лише лишаємо слід у лозі.
    Write-HookLog "ПОМИЛКА: $($_.Exception.Message)" 'ERROR'
    Write-HookLog "  у $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" 'ERROR'
}

# Порожній stdout Claude Code вважає помилкою хука, тому віддаємо мінімальний JSON.
'{"continue":true,"suppressOutput":true}'