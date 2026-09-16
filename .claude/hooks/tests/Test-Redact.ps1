<#
    Test-Redact.ps1
    Unit tests for .claude/hooks/lib/Redact.ps1 (secret redaction before
    forwarding hook text to Slack). No network calls — Send-SlackMessage
    is never invoked here.

    Run directly:
        powershell -NoProfile -File .claude\hooks\tests\Test-Redact.ps1

    Exits 0 on all-pass, 1 on any failure (prints [FAIL] lines).
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $PSScriptRoot '..\lib\Redact.ps1')

$script:failures = 0
$script:total = 0

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

# --- Get-BRAVOCanonicalRedactor -------------------------------------------

$canonical = Get-BRAVOCanonicalRedactor -ProjectDir $root
Assert-True 'canonical redactor resolves against the real BRAVO checkout' ($null -ne $canonical) `
    '(modules/BRAVO.Logging/BRAVO.Logging.psd1 should be found and Protect-BRAVOLogSecret should mask the probe)'

Assert-True 'canonical redactor returns $null for a non-existent project dir' `
    ($null -eq (Get-BRAVOCanonicalRedactor -ProjectDir (Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')))))

Assert-True 'canonical redactor returns $null for empty ProjectDir' `
    ($null -eq (Get-BRAVOCanonicalRedactor -ProjectDir ''))

# --- Protect-HookTextFailSafe (local fallback, no module dependency) -----

$s1 = Protect-HookTextFailSafe -Text 'sftp://svc-user:S3cr3tPass@baza.example.com/path'
Assert-True 'failsafe masks credentials embedded in a URL' `
    ($s1 -notmatch 'S3cr3tPass' -and $s1 -match 'sftp://svc-user:\*\*\*@baza\.example\.com/path') "(got: $s1)"

$s2 = Protect-HookTextFailSafe -Text 'password=hunter2 more text'
Assert-True 'failsafe masks password=... key-value pairs' `
    ($s2 -notmatch 'hunter2' -and $s2 -match 'password=\*\*\*') "(got: $s2)"

$s3 = Protect-HookTextFailSafe -Text 'token: placeholder-not-a-real-token'
Assert-True 'failsafe masks token: ... key-value pairs' `
    ($s3 -notmatch 'placeholder-not-a-real-token' -and $s3 -match 'token:\s*\*\*\*') "(got: $s3)"

$s4 = Protect-HookTextFailSafe -Text 'https://hooks.slack.com/services/T000/B000/xxxxxxxxxxxxxxxxxxxxxxxx'
Assert-True 'failsafe masks Slack webhook URL path' `
    ($s4 -notmatch 'xxxxxxxxxxxxxxxxxxxxxxxx' -and $s4 -match 'hooks\.slack\.com/services/\*\*\*') "(got: $s4)"

$s5 = Protect-HookTextFailSafe -Text 'https://discord.com/api/webhooks/123456/abcDEF-secret_token'
Assert-True 'failsafe masks Discord webhook URL path' `
    ($s5 -notmatch 'abcDEF-secret_token' -and $s5 -match 'discord\.com/api/webhooks/\*\*\*') "(got: $s5)"

$s6 = Protect-HookTextFailSafe -Text 'api_key=NOTAREALKEY000FAKEVALUE'
Assert-True 'failsafe masks api_key=... key-value pairs' `
    ($s6 -notmatch 'NOTAREALKEY000FAKEVALUE' -and $s6 -match 'api_key=\*\*\*') "(got: $s6)"

Assert-True 'failsafe leaves ordinary text untouched' `
    ((Protect-HookTextFailSafe -Text 'BRAVO_SELF_TEST.ps1 finished with 0 failures') -eq 'BRAVO_SELF_TEST.ps1 finished with 0 failures')

# [string]-typed params coerce a $null argument to '' before the function
# body runs, so $null and '' are indistinguishable inside — both must be
# handled without throwing.
Assert-True 'failsafe handles $null without throwing' ([string]::IsNullOrEmpty((Protect-HookTextFailSafe -Text $null)))
Assert-True 'failsafe handles empty string without throwing' ([string]::IsNullOrEmpty((Protect-HookTextFailSafe -Text '')))

# --- Protect-HookText (the entry point actually used by notify-slack.ps1) -

$viaCanonical = Protect-HookText -Text 'token=super-secret-value-123' -CanonicalRedactor $canonical
Assert-True 'Protect-HookText via canonical redactor masks a token' `
    ($viaCanonical -notmatch 'super-secret-value-123') "(got: $viaCanonical)"

$viaFallback = Protect-HookText -Text 'password=alsosecret' -CanonicalRedactor $null
Assert-True 'Protect-HookText falls back to failsafe when CanonicalRedactor is $null' `
    ($viaFallback -notmatch 'alsosecret' -and $viaFallback -match 'password=\*\*\*') "(got: $viaFallback)"

Assert-True 'Protect-HookText passes through $null text as empty (nothing to leak)' `
    ([string]::IsNullOrEmpty((Protect-HookText -Text $null -CanonicalRedactor $canonical)))

Assert-True 'Protect-HookText passes through empty text as empty' `
    ('' -eq (Protect-HookText -Text '' -CanonicalRedactor $canonical))

# A broken CanonicalRedactor (points at a command that throws) must not
# propagate the exception or fall through to raw text — it must fail over
# to the failsafe path and still redact.
function Test-BrokenRedactorCommand { param([string]$Text) throw 'simulated canonical redactor failure' }
$brokenCommand = Get-Command Test-BrokenRedactorCommand
# Protect-HookText calls Protect-BRAVOLogSecret by name (not via the passed
# CommandInfo directly) when $CanonicalRedactor is truthy, so to exercise
# the "canonical redactor throws" path we temporarily shadow
# Protect-BRAVOLogSecret with a throwing implementation.
function Protect-BRAVOLogSecret { param([string]$Text) throw 'simulated canonical redactor failure' }
$viaBrokenCanonical = Protect-HookText -Text 'secret=shouldstillbemasked' -CanonicalRedactor $brokenCommand
Assert-True 'Protect-HookText falls back to failsafe when the canonical redactor throws' `
    ($viaBrokenCanonical -notmatch 'shouldstillbemasked' -and $viaBrokenCanonical -match 'secret=\*\*\*') "(got: $viaBrokenCanonical)"

Write-Host ''
Write-Host "Total: $script:total, Failures: $script:failures"
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
