$ErrorActionPreference = 'Stop'

$logFile = $null

function Write-HookLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    if (-not $logFile) {
        return
    }

    try {
        $line = '{0} [{1}] {2}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `
            $Level, `
            $Message

        Add-Content `
            -Path $logFile `
            -Value $line `
            -Encoding UTF8
    }
    catch {
    }
}

# Спільна логіка маскування секретів — Get-BRAVOCanonicalRedactor,
# Protect-HookTextFailSafe, Protect-HookText. Винесена в lib/, бо та сама
# логіка потрібна тестам (.claude/hooks/tests/Test-Redact.ps1) без запуску
# всього хука (stdin, реальний HTTP-виклик до Slack).
#
# Dot-source у власному try/catch: хук не повинен впасти лише через те,
# що lib/Redact.ps1 відсутній чи пошкоджений — тоді визначаємо мінімальний
# fail-safe редактор інлайн (той самий підхід, що врятував session_id-
# санітизацію у save-task.ps1/precompact-checkpoint.ps1).
try {
    . (Join-Path $PSScriptRoot 'lib\Redact.ps1')
}
catch {
    function Get-BRAVOCanonicalRedactor { param([string]$ProjectDir) return $null }
    function Protect-HookTextFailSafe {
        param([AllowEmptyString()][AllowNull()][string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { return $Text }
        $sanitized = $Text
        $sanitized = $sanitized -replace '(?i)([a-z][a-z0-9+.-]*://[^:/\s@]+):[^@\s]+@', '$1:***@'
        $sanitized = $sanitized -replace '(?i)((?:password|passwd|secret|token|api[_-]?key)\s*[:=]\s*)(?:"[^"]*"|\S+)', '$1***'
        $sanitized = $sanitized -replace '(?i)(hooks\.slack\.com/services/)\S+', '$1***'
        $sanitized = $sanitized -replace '(?i)(discord(?:app)?\.com/api/webhooks/)\S+', '$1***'
        return $sanitized
    }
    function Protect-HookText {
        param([AllowEmptyString()][AllowNull()][string]$Text, $CanonicalRedactor)
        if ([string]::IsNullOrEmpty($Text)) { return $Text }
        try { return Protect-HookTextFailSafe -Text $Text } catch { return $null }
    }
}

function Get-GitBranch {
    param([string]$ProjectDir)

    try {
        $branch = & git -C $ProjectDir branch --show-current 2>$null

        if (-not [string]::IsNullOrWhiteSpace($branch)) {
            return $branch.Trim()
        }
    }
    catch {
    }

    return 'unknown'
}

function Send-SlackMessage {
    param(
        [string]$WebhookUrl,
        [string]$Text
    )

    $json = @{
        text = $Text
    } | ConvertTo-Json -Compress

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $body = $utf8.GetBytes($json)

    Invoke-RestMethod `
        -Uri $WebhookUrl `
        -Method Post `
        -ContentType 'application/json; charset=utf-8' `
        -Body $body `
        -TimeoutSec 10 `
        -ErrorAction Stop | Out-Null
}

try {

    # stdin від Claude Code читаємо явно як UTF-8
    $stdinStream = [Console]::OpenStandardInput()

    $reader = New-Object System.IO.StreamReader(
        $stdinStream,
        (New-Object System.Text.UTF8Encoding($false)),
        $true
    )

    $rawInput = $reader.ReadToEnd()
    $reader.Dispose()

    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        exit 0
    }

    try {
        $event = $rawInput | ConvertFrom-Json
    }
    catch {
        exit 0
    }

    $projectDir = $env:CLAUDE_PROJECT_DIR

    if ([string]::IsNullOrWhiteSpace($projectDir)) {
        $projectDir = [string]$event.cwd
    }

    if ([string]::IsNullOrWhiteSpace($projectDir)) {
        $projectDir = Split-Path `
            (Split-Path $PSScriptRoot -Parent) `
            -Parent
    }

    $logDir = Join-Path $projectDir '.claude\logs'

    if (-not (Test-Path $logDir)) {
        New-Item `
            -Path $logDir `
            -ItemType Directory `
            -Force | Out-Null
    }

    $logFile = Join-Path $logDir 'slack-notify.log'

    $webhookUrl = $env:BRAVO_SLACK_WEBHOOK_URL

    if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
        Write-HookLog 'BRAVO_SLACK_WEBHOOK_URL not configured' 'WARN'
        exit 0
    }

    $eventName = [string]$event.hook_event_name
    $projectName = Split-Path $projectDir -Leaf
    $branch = Get-GitBranch -ProjectDir $projectDir
    $canonicalRedactor = Get-BRAVOCanonicalRedactor -ProjectDir $projectDir

    $sessionId = [string]$event.session_id

    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        $sessionId = 'unknown'
    }

    if ($sessionId.Length -gt 8) {
        $sessionId = $sessionId.Substring(0, 8)
    }

    #
    # Claude просить permission
    #
    if (
        $eventName -eq 'Notification' -and
        [string]$event.notification_type -eq 'permission_prompt'
    ) {

        $message = [string]$event.message

        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = 'Claude Code очікує підтвердження операції.'
        }

        # Редагуємо ДО обрізання: обрізання спершу могло б лишити половину
        # секрету видимою, якщо він опинився саме на межі довжини.
        $message = Protect-HookText -Text $message -CanonicalRedactor $canonicalRedactor

        if ($null -eq $message) {
            Write-HookLog "permission_prompt SKIPPED: redaction unavailable, refusing to send unredacted body session=$sessionId" 'WARN'
            exit 0
        }

        if ($message.Length -gt 1800) {
            $message = $message.Substring(0, 1800) + '...'
        }

        $text = @"
🤖 *BRAVO Claude Code*

⚠️ *Потрібен дозвіл*

Project: $projectName
Branch: $branch
Session: $sessionId

$message
"@

        Send-SlackMessage `
            -WebhookUrl $webhookUrl `
            -Text $text

        Write-HookLog "permission_prompt sent session=$sessionId"

        exit 0
    }

    #
    # Claude сам визначив, що потрібен owner
    #
    if ($eventName -eq 'Stop') {

        $answer = [string]$event.last_assistant_message

        if ([string]::IsNullOrWhiteSpace($answer)) {
            exit 0
        }

        $marker = '[OWNER_ACTION_REQUIRED]'

        $index = $answer.IndexOf(
            $marker,
            [System.StringComparison]::OrdinalIgnoreCase
        )

        if ($index -lt 0) {
            exit 0
        }

        $details = $answer.Substring($index).Trim()

        $details = Protect-HookText -Text $details -CanonicalRedactor $canonicalRedactor

        if ($null -eq $details) {
            Write-HookLog "OWNER_ACTION_REQUIRED SKIPPED: redaction unavailable, refusing to send unredacted body session=$sessionId" 'WARN'
            exit 0
        }

        if ($details.Length -gt 2500) {
            $details = $details.Substring(0, 2500) + '...'
        }

        $text = @"
🤖 *BRAVO Claude Code*

🔴 *Потрібне рішення власника*

Project: $projectName
Branch: $branch
Session: $sessionId

$details
"@

        Send-SlackMessage `
            -WebhookUrl $webhookUrl `
            -Text $text

        Write-HookLog "OWNER_ACTION_REQUIRED sent session=$sessionId"

        exit 0
    }

    exit 0
}
catch {
    # Повідомлення .NET-винятку від Invoke-RestMethod інколи включає повний
    # URI запиту — тобто сам webhook URL. Fail-safe-маскування (не залежить
    # від стану $canonicalRedactor на момент падіння) застосовується завжди,
    # а не лише коли основний шлях уже дійшов до нього.
    $safeErrorMessage = try { Protect-HookTextFailSafe -Text $_.Exception.Message } catch { '(не вдалося безпечно залогувати повідомлення помилки)' }
    Write-HookLog "ERROR: $safeErrorMessage" 'ERROR'
    exit 0
}