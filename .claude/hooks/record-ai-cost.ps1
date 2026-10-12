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

    Додатково скрипт працює детектором перейменування інструмента делегування:
    якщо в транскрипті є tool_use, вхід якого містить subagent_type, але name не
    входить до відомого списку імен делегування, це означає, що PreToolUse-гейт
    маршрутизації більше не бачить делегувань і enforcement тихо мертвий. Такий
    випадок пишеться як ALERT у .claude/logs/ai-routing.log і як поле
    unknownDelegationTools у записі ai-cost.jsonl.

    Облік — вторинний ефект. Будь-яка помилка тут не повинна впливати на
    сесію: скрипт завжди завершується кодом 0 і за потреби пише діагностику
    в .claude/logs/ai-cost-errors.log.

    Викликати обов'язково з -NoProfile.
#>
$ErrorActionPreference = 'Stop'

$projectDir = $null
$logDir = $null

# Відомі імена інструмента делегування. 'Agent' — ім'я в Claude Code 2.1.x,
# 'Task' — історичне ім'я. Список мусить лишатися синхронним із
# $script:DelegationTools у validate-agent-routing.ps1 та з matcher-ом
# PreToolUse у .claude/settings.json.
$script:KnownDelegationTools = @('Agent', 'Task')

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

function Write-RoutingAlert {
    param([string]$Message)

    try {
        if ($null -eq $logDir) { return }
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $line = '{0} | ALERT | {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath (Join-Path $logDir 'ai-routing.log') -Value $line -Encoding UTF8
    }
    catch {
        # свідомо проглочено: детектор не має права ламати сесію
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
    $unknownDelegationTools = @{}
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

            # 'Agent' — ім'я інструмента делегування в Claude Code 2.1.x;
            # 'Task' лишається для сумісності з версіями, де він називався так.
            # Доки тут був лише 'Task', облік делегувань у живій сесії завжди
            # виходив порожнім (live-прогін 2026-10-12).
            if ($script:KnownDelegationTools -ccontains $toolName) {
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
            elseif ($null -ne $block.input -and -not [string]::IsNullOrWhiteSpace([string]$block.input.subagent_type)) {
                # Делегування під невідомим іменем інструмента: PreToolUse-гейт
                # маршрутизації його не бачить, тобто enforcement мертвий.
                # Саме цей клас дефекту був P1 у PR #441.
                if ([string]::IsNullOrWhiteSpace($toolName)) { $toolName = 'unnamed' }
                if ($unknownDelegationTools.ContainsKey($toolName)) {
                    $unknownDelegationTools[$toolName]++
                } else {
                    $unknownDelegationTools[$toolName] = 1
                }
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
        unknownDelegationTools = $unknownDelegationTools
        fallbackReasons     = @($fallbackReasons)
        durationMinutes     = $durationMinutes
    }

    foreach ($unknownTool in @($unknownDelegationTools.Keys | Sort-Object)) {
        Write-RoutingAlert ("tool='" + $unknownTool + "' | calls=" + $unknownDelegationTools[$unknownTool] +
            " | delegation tool is not in the known list (" + ($script:KnownDelegationTools -join ', ') +
            "): the PreToolUse routing gate does not see delegations and enforcement is silently inactive." +
            " Update `$script:DelegationTools in validate-agent-routing.ps1, the PreToolUse matcher in" +
            " .claude/settings.json, enforcement.gatedTools in .claude/ai-routing.json and" +
            " `$script:KnownDelegationTools in record-ai-cost.ps1.")
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
