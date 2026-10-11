<#
    record-ai-cost.ps1
    Хук Stop для Claude Code — облік фактичного використання AI за сесію.

    Отримує на stdin JSON із полями session_id, transcript_path, cwd,
    hook_event_name. Читає транскрипт сесії (JSONL) і дописує один рядок у
    .claude/logs/ai-cost.jsonl: моделі, токени (input/output/cache), кількість
    делегувань агентам, кількість викликів Codex і заявлені причини fallback.

    Поля транскрипту, на які спирається розбір (перевірено емпірично на
    реальному транскрипті Claude Code):
        рядок type="assistant" -> message.model,
                                  message.usage.input_tokens,
                                  message.usage.output_tokens,
                                  message.usage.cache_creation_input_tokens,
                                  message.usage.cache_read_input_tokens,
        message.content[] з type="tool_use" -> name, input.subagent_type.

    Облік — вторинний ефект. Будь-яка помилка тут не повинна впливати на
    сесію: скрипт завжди завершується кодом 0 і за потреби пише діагностику
    в .claude/logs/ai-cost-errors.log.

    Викликати обов'язково з -NoProfile.
#>
$ErrorActionPreference = 'Stop'

$projectDir = $null
$logDir = $null

function Write-CostError {
    param([string]$Message)

    try {
        if ($null -eq $logDir) { return }
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $line = '{0} | {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath (Join-Path $logDir 'ai-cost-errors.log') -Value $line -Encoding UTF8
    }
    catch {
        # свідомо проглочено: облік не має права ламати сесію
    }
}

try {
    $raw = [Console]::In.ReadToEnd()
    $payload = $raw | ConvertFrom-Json

    $projectDir = $env:CLAUDE_PROJECT_DIR
    if ([string]::IsNullOrWhiteSpace($projectDir)) { $projectDir = [string]$payload.cwd }
    if ([string]::IsNullOrWhiteSpace($projectDir)) { $projectDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $logDir = Join-Path $projectDir '.claude\logs'

    $transcriptPath = [string]$payload.transcript_path
    if ([string]::IsNullOrWhiteSpace($transcriptPath) -or -not (Test-Path -LiteralPath $transcriptPath -PathType Leaf)) {
        Write-CostError ('transcript unavailable: ' + $transcriptPath)
        exit 0
    }

    $inputTokens = 0
    $outputTokens = 0
    $cacheCreationTokens = 0
    $cacheReadTokens = 0
    $assistantTurns = 0
    $models = New-Object 'System.Collections.Generic.HashSet[string]'
    $agentCalls = @{}
    $codexCalls = @{}
    $fallbackReasons = New-Object 'System.Collections.Generic.HashSet[string]'
    $firstTimestamp = $null
    $lastTimestamp = $null

    foreach ($line in [IO.File]::ReadLines($transcriptPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $entry = $null
        try { $entry = $line | ConvertFrom-Json }
        catch { continue }

        if ($null -ne $entry.timestamp) {
            if ($null -eq $firstTimestamp) { $firstTimestamp = [string]$entry.timestamp }
            $lastTimestamp = [string]$entry.timestamp
        }

        if ([string]$entry.type -cne 'assistant') { continue }
        if ($null -eq $entry.message) { continue }

        $assistantTurns++
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.message.model)) {
            $null = $models.Add([string]$entry.message.model)
        }

        $usage = $entry.message.usage
        if ($null -ne $usage) {
            if ($null -ne $usage.input_tokens) { $inputTokens += [int]$usage.input_tokens }
            if ($null -ne $usage.output_tokens) { $outputTokens += [int]$usage.output_tokens }
            if ($null -ne $usage.cache_creation_input_tokens) { $cacheCreationTokens += [int]$usage.cache_creation_input_tokens }
            if ($null -ne $usage.cache_read_input_tokens) { $cacheReadTokens += [int]$usage.cache_read_input_tokens }
        }

        foreach ($block in @($entry.message.content)) {
            if ($null -eq $block) { continue }
            if ([string]$block.type -cne 'tool_use') { continue }

            $toolName = [string]$block.name

            if ($toolName -ceq 'Task') {
                $agent = 'unspecified'
                if ($null -ne $block.input -and -not [string]::IsNullOrWhiteSpace([string]$block.input.subagent_type)) {
                    $agent = [string]$block.input.subagent_type
                }
                if ($agentCalls.ContainsKey($agent)) { $agentCalls[$agent]++ } else { $agentCalls[$agent] = 1 }

                $prompt = ''
                if ($null -ne $block.input -and $null -ne $block.input.prompt) { $prompt = [string]$block.input.prompt }
                if ($prompt -match 'claude-qa-fallback') {
                    $match = [regex]::Match($prompt, '(?im)^\s*fallback_reason\s*:\s*(?<reason>[a-z\-]+)')
                    if ($match.Success) { $null = $fallbackReasons.Add($match.Groups['reason'].Value) }
                    else { $null = $fallbackReasons.Add('unspecified') }
                }
            }
            elseif ($toolName -like 'mcp__codex-agent__*') {
                $role = 'unspecified'
                if ($null -ne $block.input -and -not [string]::IsNullOrWhiteSpace([string]$block.input.role)) {
                    $role = [string]$block.input.role
                }
                $key = ($toolName -replace '^mcp__codex-agent__', '') + ':' + $role
                if ($codexCalls.ContainsKey($key)) { $codexCalls[$key]++ } else { $codexCalls[$key] = 1 }
            }
        }
    }

    $durationMinutes = $null
    if (-not [string]::IsNullOrWhiteSpace($firstTimestamp) -and -not [string]::IsNullOrWhiteSpace($lastTimestamp)) {
        try {
            $span = ([datetime]$lastTimestamp) - ([datetime]$firstTimestamp)
            $durationMinutes = [math]::Round($span.TotalMinutes, 1)
        }
        catch {
            $durationMinutes = $null
        }
    }

    $record = [ordered]@{
        recordedAt          = (Get-Date).ToString('o')
        sessionId           = [string]$payload.session_id
        models              = @($models)
        assistantTurns      = $assistantTurns
        inputTokens         = $inputTokens
        outputTokens        = $outputTokens
        cacheCreationTokens = $cacheCreationTokens
        cacheReadTokens     = $cacheReadTokens
        agentCalls          = $agentCalls
        codexCalls          = $codexCalls
        fallbackReasons     = @($fallbackReasons)
        durationMinutes     = $durationMinutes
    }

    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $json = $record | ConvertTo-Json -Depth 5 -Compress
    Add-Content -LiteralPath (Join-Path $logDir 'ai-cost.jsonl') -Value $json -Encoding UTF8
}
catch {
    Write-CostError ('record failed: ' + $_.Exception.Message)
}

exit 0
