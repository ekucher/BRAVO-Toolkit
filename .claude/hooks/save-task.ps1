$ErrorActionPreference = 'Stop'

# ConvertTo-SafeSessionId — канонічна санітизація session_id, спільна з
# precompact-checkpoint.ps1. Винесена в lib/, щоб не дублювати той самий
# allowlist-регекс і ту саму перевірку на крапково-лише значення в обох
# хуках (.claude/hooks/tests/Test-SafePath.ps1 покриває обидва).
#
# Dot-source навмисно у власному try/catch: хук не повинен впасти лише
# через те, що lib/SafePath.ps1 відсутній чи пошкоджений — тоді просто
# визначаємо ту саму логіку інлайн як fallback.
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

try {
    #
    # Claude Code передає hook JSON через stdin у UTF-8.
    # Windows PowerShell 5.1 за замовчуванням може читати stdin як OEM CP866,
    # тому читаємо raw stdin явно як UTF-8.
    #
    $stdin = [Console]::OpenStandardInput()
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $reader = New-Object System.IO.StreamReader(
        $stdin,
        $utf8NoBom,
        $true
    )

    $rawInput = $reader.ReadToEnd()
    $reader.Dispose()

    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        exit 0
    }

    $event = $rawInput | ConvertFrom-Json

    $projectDir = $env:CLAUDE_PROJECT_DIR

    if ([string]::IsNullOrWhiteSpace($projectDir)) {
        $projectDir = [string]$event.cwd
    }

    if ([string]::IsNullOrWhiteSpace($projectDir)) {
        exit 0
    }

    $historyDir = Join-Path $projectDir '.claude\task-history'
    $pendingDir = Join-Path $historyDir '.pending'

    if (-not (Test-Path $historyDir)) {
        New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
    }

    if (-not (Test-Path $pendingDir)) {
        New-Item -ItemType Directory -Path $pendingDir -Force | Out-Null
    }

    # session_id стає ім'ям файлу/підпапки нижче, тому пропускаємо його
    # через ConvertTo-SafeSessionId (lib/SafePath.ps1) ПЕРЕД будь-яким
    # використанням у шляху.
    $sessionId = ConvertTo-SafeSessionId -SessionId ([string]$event.session_id)

    $pendingFile = Join-Path $pendingDir "$sessionId.txt"

    #
    # USER TASK
    #
    if ($event.hook_event_name -eq 'UserPromptSubmit') {

        $prompt = [string]$event.prompt

        $utf8Bom = New-Object System.Text.UTF8Encoding($true)

        [System.IO.File]::WriteAllText(
            $pendingFile,
            $prompt,
            $utf8Bom
        )

        exit 0
    }

    #
    # CLAUDE RESULT
    #
    if ($event.hook_event_name -eq 'Stop') {

        $answer = [string]$event.last_assistant_message

        if ([string]::IsNullOrWhiteSpace($answer)) {
            exit 0
        }

        $prompt = ''

        if (Test-Path $pendingFile) {
            $prompt = [System.IO.File]::ReadAllText(
                $pendingFile,
                [System.Text.Encoding]::UTF8
            )
        }

        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'

        # Truncation could re-introduce a dot-only fragment (наприклад,
        # sessionId = "..........abc" -> перші 8 символів = "........"),
        # тому та сама перевірка повторюється після обрізання.
        $shortSession = $sessionId

        if ($shortSession.Length -gt 8) {
            $shortSession = $shortSession.Substring(0, 8)
        }

        if ($shortSession -match '^\.+$') {
            $shortSession = 'unknown-session'.Substring(0, 8)
        }

        $fileName = "Claude_Task_${timestamp}_${shortSession}.txt"
        $sessionDir = Join-Path $historyDir $shortSession
        if (-not (Test-Path $sessionDir)) {
            New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        }

        $outputFile = Join-Path $sessionDir $fileName

        $content = @"
================================================================================
CLAUDE CODE TASK
================================================================================

Date:       $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Session:    $sessionId
Project:    $projectDir
Transcript: $($event.transcript_path)

================================================================================
USER TASK
================================================================================

$prompt

================================================================================
CLAUDE RESULT
================================================================================

$answer

================================================================================
END
================================================================================
"@

        #
        # UTF-8 BOM спеціально залишаємо:
        # Notepad / Windows PowerShell 5.1 коректніше визначають кирилицю.
        #
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)

        [System.IO.File]::WriteAllText(
            $outputFile,
            $content,
            $utf8Bom
        )

        #
        # Копія повного Claude transcript
        #
        $transcriptPath = [string]$event.transcript_path

        if (-not [string]::IsNullOrWhiteSpace($transcriptPath)) {
            try {
                if (Test-Path $transcriptPath) {

                    $transcriptCopy = Join-Path `
                        $sessionDir `
                        "Claude_Transcript_${shortSession}.jsonl"

                    Copy-Item `
                        -LiteralPath $transcriptPath `
                        -Destination $transcriptCopy `
                        -Force
                }
            }
            catch {
                # Transcript backup не повинен ламати Claude Code.
            }
        }

        if (Test-Path $pendingFile) {
            Remove-Item `
                -LiteralPath $pendingFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        exit 0
    }

    exit 0
}
catch {
    #
    # Hook ніколи не повинен блокувати Claude Code.
    #
    exit 0
}