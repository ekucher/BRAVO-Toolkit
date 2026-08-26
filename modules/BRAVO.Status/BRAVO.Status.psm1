# BRAVO.Status — machine-readable status contract v1 (ROADMAP P2.1).
#
# Канонічний власник схеми статусу останнього прогону операції для
# зовнішніх machine-споживачів (моніторинг читає JSON з диска замість
# парсингу консолі). Один файл на операцію:
#     %ProgramData%\BRAVO\State\STATUS\BRAVO_STATUS_<Operation>.json
#
# ІНВАРІАНТИ КОНТРАКТУ (ROADMAP «Telemetry/monitoring не повинні
# змінювати exit code або результат операції»):
# - Write-BRAVOOperationStatus сам може кинути виняток (диск/ACL) —
#   КОЖЕН call-site зобов'язаний обгорнути виклик try/catch і на
#   помилку лише логувати WARNING, ніколи не змінюючи exit code чи
#   результат операції (fail-soft; перевіряється self-test-контрактом).
# - Exit codes лишаються канонічним класифікатором збою: поле status
#   (OK|WARNINGS|ERROR) — лише зручна проєкція exitCode для споживача,
#   деривується ТУТ в одному місці (0→OK, 10→WARNINGS, решта→ERROR).
# - Жодних secret-bearing значень у details: call-site передає лише
#   агрегати (лічильники, ідентифікатори generation, булеві прапорці).
#
# Це фундамент P2.1; транспорт/outbox/Zabbix-інтеграція (P2.2/FEAT-003)
# свідомо НЕ входить — контракт лишається локальним файлом.

Set-StrictMode -Version 2.0

$script:OperationStatusSchemaVersion = 1

function Get-BRAVOOperationStatusPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Archive', 'Health', 'Maintenance', 'RestoreVerify')]
        [string]$Operation
    )

    return Join-Path (Join-Path $StateRoot 'STATUS') "BRAVO_STATUS_$Operation.json"
}

function Get-BRAVOOperationStatus {
    # Контракт результату той самий, що Read-BRAVOBazaState /
    # Get-BRAVORestoreVerifyState: {Exists; Corrupt; State; Reason}.
    # Невідома schemaVersion → Corrupt (fail-closed для споживача,
    # ніколи не мовчазна міграція).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not [IO.File]::Exists($Path)) {
        return [pscustomobject]@{ Exists = $false; Corrupt = $false; State = $null; Reason = $null }
    }
    try {
        $parsed = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($null -eq $parsed.PSObject.Properties['schemaVersion'] -or
            [int]$parsed.schemaVersion -ne $script:OperationStatusSchemaVersion) {
            return [pscustomobject]@{
                Exists = $true
                Corrupt = $true
                State = $null
                Reason = "непідтримувана schemaVersion status-файла (очікується $($script:OperationStatusSchemaVersion))"
            }
        }
        return [pscustomobject]@{ Exists = $true; Corrupt = $false; State = $parsed; Reason = $null }
    } catch {
        return [pscustomobject]@{ Exists = $true; Corrupt = $true; State = $null; Reason = $_.Exception.Message }
    }
}

function Write-BRAVOOperationStatus {
    # Atomic write: temp -> [IO.File]::Replace/Move (канонічний прийом
    # Save-BRAVOBazaState / Save-BRAVORestoreVerifyState) — crash посеред
    # запису не лишає частковий файл поверх валідного попереднього.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Archive', 'Health', 'Maintenance', 'RestoreVerify')]
        [string]$Operation,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [datetime]$FinishedAt = (Get-Date),
        # Операційно-специфічні агрегати (лічильники/ідентифікатори/булеві).
        # Call-site НЕ передає сюди секрети, повні шляхи з credentials чи
        # сирі повідомлення винятків — self-test перевіряє серіалізацію.
        [hashtable]$Details = @{},
        # Ім'я exit-коду з канонічного BRAVO.ExitCodes; параметр, а не
        # виклик звідси — модуль статусу не тягне залежність на ExitCodes
        # (call-site уже має Get-BRAVOExitCodeName у scope).
        [AllowNull()][AllowEmptyString()][string]$ExitCodeName
    )

    $status = if ($ExitCode -eq 0) { 'OK' } elseif ($ExitCode -eq 10) { 'WARNINGS' } else { 'ERROR' }

    $packageVersion = ''
    $packageVersionVariable = Get-Variable -Name 'ScriptVersion' -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $packageVersionVariable) {
        $packageVersion = [string]$packageVersionVariable.Value
    }

    $serializable = [ordered]@{
        schemaVersion = $script:OperationStatusSchemaVersion
        host = [string]$env:COMPUTERNAME
        packageVersion = $packageVersion
        operation = $Operation
        status = $status
        exitCode = $ExitCode
        exitCodeName = [string]$ExitCodeName
        startedAt = $StartedAt.ToString('o')
        finishedAt = $FinishedAt.ToString('o')
        durationSeconds = [math]::Round(($FinishedAt - $StartedAt).TotalSeconds, 1)
        details = $Details
    }

    $statusPath = Get-BRAVOOperationStatusPath -StateRoot $StateRoot -Operation $Operation
    $statusDirectory = Split-Path -Path $statusPath -Parent
    if (-not [IO.Directory]::Exists($statusDirectory)) {
        [void][IO.Directory]::CreateDirectory($statusDirectory)
    }
    $temporaryPath = Join-Path $statusDirectory ('.BRAVO_STATUS_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $backupPath = Join-Path $statusDirectory ('.BRAVO_STATUS_{0}.bak' -f [guid]::NewGuid().ToString('N'))
    $replaced = $false
    try {
        $json = $serializable | ConvertTo-Json -Depth 4 -Compress
        [IO.File]::WriteAllText($temporaryPath, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($statusPath)) {
            [IO.File]::Replace($temporaryPath, $statusPath, $backupPath)
            $replaced = $true
        } else {
            [IO.File]::Move($temporaryPath, $statusPath)
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
        if ($replaced -and [IO.File]::Exists($backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}
