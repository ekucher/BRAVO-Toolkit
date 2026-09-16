<#
    Test-SafePath.ps1
    Characterization/regression tests for .claude/hooks/lib/SafePath.ps1
    and its consumer save-task.ps1.

    Not part of BRAVO_SELF_TEST.ps1 — this is local Claude Code tooling,
    not BRAVO runtime. Run directly:

        powershell -NoProfile -File .claude\hooks\tests\Test-SafePath.ps1

    Exits 0 on all-pass, 1 on any failure (prints [FAIL] lines).
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $PSScriptRoot '..\lib\SafePath.ps1')

$script:failures = 0
$script:total = 0

function Assert-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    $script:total++
    if ($Expected -ceq $Actual) {
        Write-Host "[PASS] $Name"
    }
    else {
        $script:failures++
        Write-Host "[FAIL] $Name -- expected '$Expected', got '$Actual'" -ForegroundColor Red
    }
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    $script:total++
    if ($Condition) {
        Write-Host "[PASS] $Name"
    }
    else {
        $script:failures++
        Write-Host "[FAIL] $Name $Detail" -ForegroundColor Red
    }
}

# --- Unit tests: ConvertTo-SafeSessionId ---------------------------------

Assert-Equal 'normal session id passes through' 'abc123-DEF_456' (ConvertTo-SafeSessionId -SessionId 'abc123-DEF_456')
Assert-Equal 'null falls back' 'unknown-session' (ConvertTo-SafeSessionId -SessionId $null)
Assert-Equal 'empty falls back' 'unknown-session' (ConvertTo-SafeSessionId -SessionId '')
Assert-Equal 'whitespace-only falls back' 'unknown-session' (ConvertTo-SafeSessionId -SessionId '   ')
Assert-Equal 'single dot falls back (would resolve to the dir itself)' 'unknown-session' (ConvertTo-SafeSessionId -SessionId '.')
Assert-Equal 'double dot falls back (the actual vulnerability: parent-dir reference)' 'unknown-session' (ConvertTo-SafeSessionId -SessionId '..')
Assert-Equal 'many-dots-only falls back' 'unknown-session' (ConvertTo-SafeSessionId -SessionId '........')
Assert-Equal 'unix separators removed, remaining dots collapse to fallback' 'unknown-session' (ConvertTo-SafeSessionId -SessionId '../../..')
Assert-Equal 'windows separators removed, remaining dots collapse to fallback' 'unknown-session' (ConvertTo-SafeSessionId -SessionId '..\..\..')
Assert-Equal 'traversal payload with a suffix survives as one safe literal segment (not a fallback, not a traversal)' '....etcpasswd' (ConvertTo-SafeSessionId -SessionId '../../etc/passwd')
Assert-Equal 'absolute Windows path collapses to one safe literal segment' 'CWindowsSystem32' (ConvertTo-SafeSessionId -SessionId 'C:\Windows\System32')
Assert-Equal 'null byte and control chars stripped' 'abc' (ConvertTo-SafeSessionId -SessionId "a`0b`tc")
Assert-Equal 'custom fallback honored' 'custom-fallback' (ConvertTo-SafeSessionId -SessionId '..' -Fallback 'custom-fallback')

# --- Characterization test: end-to-end save-task.ps1, malicious session_id ---
#
# Proves the actual vulnerability class this fix closes: session_id = ".."
# consists ENTIRELY of allowlisted characters (dots), so a naive allowlist
# regex alone does not stop it — Join-Path $historyDir '..' resolves one
# level ABOVE .claude/task-history/, i.e. directly into .claude/. This runs
# the REAL hook script as a child process against an isolated fake project
# directory and proves no file lands outside .claude/task-history/.

function Invoke-SaveTaskHook {
    param(
        [string]$ProjectDir,
        [hashtable]$Payload
    )
    $json = $Payload | ConvertTo-Json -Compress
    $hookPath = Join-Path $root '.claude\hooks\save-task.ps1'
    $env:CLAUDE_PROJECT_DIR = $ProjectDir
    try {
        # Без -ExecutionPolicy Bypass навмисно: ci/Test-BRAVOForbiddenPattern.ps1
        # (сам відстежується RUNTIME_MANIFEST.json) блокує НОВІ Bypass-місця
        # поза installer/task definitions, а правка манігфест-трекнутого файлу
        # заради тестового allowlist-запису вимагала б окремого regen через
        # ci\Update-BRAVORuntimeManifest.ps1 — окрема, свідома операція поза
        # обсягом цього фіксу. save-task.ps1 — файл з локального checkout, не
        # internet-zone, тому RemoteSigned (типовий дефолт) виконує його й без
        # Bypass; сам продакшн-виклик хука в .claude/settings.json лишається
        # незмінним і має свій -ExecutionPolicy Bypass.
        $json | & powershell.exe -NoProfile -File $hookPath | Out-Null
    }
    finally {
        Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue
    }
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("bravo-hook-test-{0}" -f [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    $claudeDir = Join-Path $sandbox '.claude'
    $historyDir = Join-Path $claudeDir 'task-history'

    $maliciousSessionId = '..'

    # 1) UserPromptSubmit — stages the prompt under .pending/<sanitized>.txt
    Invoke-SaveTaskHook -ProjectDir $sandbox -Payload @{
        session_id      = $maliciousSessionId
        hook_event_name = 'UserPromptSubmit'
        prompt           = 'malicious session_id characterization test'
        cwd              = $sandbox
    }

    # 2) Stop — writes the final transcript file
    Invoke-SaveTaskHook -ProjectDir $sandbox -Payload @{
        session_id             = $maliciousSessionId
        hook_event_name        = 'Stop'
        last_assistant_message = 'response for malicious session_id test'
        cwd                    = $sandbox
        transcript_path        = ''
    }

    Assert-True 'history dir was created inside sandbox' (Test-Path $historyDir)

    # The pre-fix behavior would write "Claude_Task_*.txt" directly into
    # .claude/ (one level above task-history/) because Join-Path with ".."
    # resolves upward. That must NOT happen.
    $escapedFiles = @(Get-ChildItem -Path $claudeDir -Filter 'Claude_Task_*.txt' -File -ErrorAction SilentlyContinue)
    Assert-True 'no task file escaped one level up into .claude/ (the pre-fix vulnerability)' ($escapedFiles.Count -eq 0) `
        "(found: $($escapedFiles.Name -join ', '))"

    $writtenDirs = @(Get-ChildItem -Path $historyDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.pending' })
    Assert-True 'exactly one session directory was created (the sanitized fallback)' ($writtenDirs.Count -eq 1) `
        "(found: $($writtenDirs.Name -join ', '))"

    if ($writtenDirs.Count -ge 1) {
        # $shortSession truncates the fallback 'unknown-session' to 8 chars.
        $expectedShortFallback = 'unknown-session'.Substring(0, 8)
        Assert-True 'session directory name is the safe fallback, not the raw ".." payload' `
            ($writtenDirs[0].Name -eq $expectedShortFallback) `
            "(actual name: '$($writtenDirs[0].Name)', expected: '$expectedShortFallback')"

        $taskFiles = @(Get-ChildItem -Path $writtenDirs[0].FullName -Filter 'Claude_Task_*.txt' -File -ErrorAction SilentlyContinue)
        Assert-True 'task transcript file was written inside the sanitized session dir' ($taskFiles.Count -eq 1)
    }
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Total: $script:total, Failures: $script:failures"
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
