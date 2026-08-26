# BRAVO.RestoreVerify — state-API і health-оцінка планової перевірки
# відновлюваності (restore drill, ROADMAP P1.1).
#
# ВАЖЛИВЕ РОЗМЕЖУВАННЯ: цей модуль володіє BRAVO_RESTORE_VERIFY_STATE.json
# (вік останньої УСПІШНОЇ верифікації відновлюваності drill-ом
# BRAVO_RESTORE_TEST.ps1). Це ІНША машина станів, ніж
# BRAVO_RESTORE_STATE.json у BRAVO.Maintenance (тижнева планова
# реставрація моделі bravocmd; поля ScheduledOccurrence/Status/
# ForcedRestoreCoversSlot/LastSuccessfulRestoreAt) — не об'єднувати їх:
# успішна реставрація моделі не доводить відновлюваність backup-архівів,
# і навпаки.
#
# Два споживачі state: BRAVO_RESTORE_TEST.ps1 пише після кожного прогону,
# BRAVO_HEALTH (крок «Відновлюваність») читає і оцінює вік. Політика
# «LastVerifiedAt оновлюється ЛИШЕ повністю чистим прогоном (0 FAIL і
# 0 WARN)» реалізована тут в одному місці: WARN означає «частину
# компонентів не перевірено», і такий прогін не має скидати вік
# останньої ДОВЕДЕНОЇ верифікації.

Set-StrictMode -Version 2.0

$script:RestoreVerifyStateSchemaVersion = 1

function Get-BRAVORestoreVerifyStatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot
    )

    return Join-Path $StateRoot 'BRAVO_RESTORE_VERIFY_STATE.json'
}

function Get-BRAVORestoreVerifyState {
    # Контракт результату той самий, що в Read-BRAVOBazaComponentState:
    # {Exists; Corrupt; State; Reason}. Відсутній файл — легальний стан
    # (сервер щойно оновлено, перший scheduled-прогін ще не відбувся),
    # пошкоджений — окремий прапорець для fail-closed рішень споживача.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not [IO.File]::Exists($Path)) {
        return [pscustomobject]@{ Exists = $false; Corrupt = $false; State = $null; Reason = $null }
    }
    try {
        $parsed = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($null -eq $parsed.PSObject.Properties['SchemaVersion'] -or
            [int]$parsed.SchemaVersion -ne $script:RestoreVerifyStateSchemaVersion) {
            return [pscustomobject]@{
                Exists = $true
                Corrupt = $true
                State = $null
                Reason = "непідтримувана SchemaVersion state-файла (очікується $($script:RestoreVerifyStateSchemaVersion))"
            }
        }
        $state = [pscustomobject]@{
            SchemaVersion = [int]$parsed.SchemaVersion
            LastRunAt = [string]$parsed.LastRunAt
            LastStatus = [string]$parsed.LastStatus
            LastExitCode = [int]$parsed.LastExitCode
            GenerationId = [string]$parsed.GenerationId
            LastVerifiedAt = [string]$parsed.LastVerifiedAt
            UpdatedAt = [string]$parsed.UpdatedAt
        }
        return [pscustomobject]@{ Exists = $true; Corrupt = $false; State = $state; Reason = $null }
    } catch {
        return [pscustomobject]@{ Exists = $true; Corrupt = $true; State = $null; Reason = $_.Exception.Message }
    }
}

function Save-BRAVORestoreVerifyState {
    # Atomic write: temp -> [IO.File]::Replace/Move (канонічний прийом
    # Save-BRAVOBazaState / Save-BRAVOVSSOwnershipState) — crash посеред
    # запису не лишає частковий файл поверх валідного попереднього.
    #
    # LastVerifiedAt: оновлюється значенням RunAt ЛИШЕ коли
    # -VerificationSucceeded (0 FAIL і 0 WARN у прогоні drill); інакше
    # переноситься з попереднього стану — слабший результат не скидає вік
    # останньої доведеної верифікації (та сама філософія, що заборона
    # перезапису термінального стану слабшим).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][datetime]$RunAt,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'WARN', 'FAIL')][string]$Status,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [AllowNull()][AllowEmptyString()][string]$GenerationId,
        [Parameter(Mandatory = $true)][bool]$VerificationSucceeded
    )

    $previousVerifiedAt = $null
    $previous = Get-BRAVORestoreVerifyState -Path $Path
    if ($previous.Exists -and -not $previous.Corrupt -and
        -not [string]::IsNullOrWhiteSpace([string]$previous.State.LastVerifiedAt)) {
        $previousVerifiedAt = [string]$previous.State.LastVerifiedAt
    }
    $lastVerifiedAt = if ($VerificationSucceeded) { $RunAt.ToString('o') } else { $previousVerifiedAt }

    $stateDirectory = Split-Path -Path $Path -Parent
    if (-not [IO.Directory]::Exists($stateDirectory)) {
        [void][IO.Directory]::CreateDirectory($stateDirectory)
    }
    $serializable = [ordered]@{
        SchemaVersion = $script:RestoreVerifyStateSchemaVersion
        LastRunAt = $RunAt.ToString('o')
        LastStatus = $Status
        LastExitCode = $ExitCode
        GenerationId = [string]$GenerationId
        LastVerifiedAt = $lastVerifiedAt
        UpdatedAt = (Get-Date).ToString('o')
    }
    $temporaryPath = Join-Path $stateDirectory ('.BRAVO_RESTORE_VERIFY_STATE_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $backupPath = Join-Path $stateDirectory ('.BRAVO_RESTORE_VERIFY_STATE_{0}.bak' -f [guid]::NewGuid().ToString('N'))
    $replaced = $false
    try {
        $json = $serializable | ConvertTo-Json -Depth 3 -Compress
        [IO.File]::WriteAllText($temporaryPath, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporaryPath, $Path, $backupPath)
            $replaced = $true
        } else {
            [IO.File]::Move($temporaryPath, $Path)
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

function Get-BRAVORestoreVerifyHealthIssue {
    # Чиста функція оцінки для Health-кроку «Відновлюваність»: приймає вже
    # прочитаний StateResult (Get-BRAVORestoreVerifyState) — тестується без
    # файлової системи. Повертає {Issue; Warning; Detail}:
    #   Issue   — текст проблеми (крок стає ERROR) або $null;
    #   Warning — м'яке нагадування (лог, БЕЗ issue) або $null;
    #   Detail  — інформативний рядок про вік останньої верифікації.
    #
    # Відсутній state — Warning, НЕ Issue: кожен сервер після оновлення
    # комплекту чекає першого суботнього прогону; тримати його в ERROR
    # увесь цей час означало б привчити оператора ігнорувати крок.
    # Пошкоджений state або прострочений вік — Issue (fail-closed:
    # недоведена відновлюваність = проблема, яку треба побачити).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$StateResult,
        [Parameter(Mandatory = $true)][int]$MaxVerificationAgeHours,
        [datetime]$Now = (Get-Date)
    )

    $result = [pscustomobject]@{ Issue = $null; Warning = $null; Detail = $null }

    if (-not [bool]$StateResult.Exists) {
        $result.Warning = "стан перевірки відновлюваності ще не створено — дочекайтеся першого запуску задачі BRAVO_RESTORE_VERIFY або запустіть BRAVO_RESTORE_TEST.ps1 вручну; якщо задача не зареєстрована, перезапустіть BRAVO_TASKS_INSTALL.ps1"
        return $result
    }
    if ([bool]$StateResult.Corrupt) {
        $result.Issue = "state-файл перевірки відновлюваності пошкоджено ($([string]$StateResult.Reason)) — запустіть BRAVO_RESTORE_TEST.ps1 вручну, успішний прогін перезапише стан"
        return $result
    }

    $state = $StateResult.State
    if ([string]$state.LastStatus -eq 'FAIL') {
        $result.Issue = "останній restore drill завершився з FAIL (запуск $([string]$state.LastRunAt), GenerationId $([string]$state.GenerationId)) — резервні копії можуть бути невідновлюваними, перевірте журнал BRAVO_RESTORE_TEST"
        return $result
    }

    if ([string]::IsNullOrWhiteSpace([string]$state.LastVerifiedAt)) {
        $result.Issue = "жодного повністю успішного restore drill ще не зафіксовано (останній прогін: $([string]$state.LastStatus) $([string]$state.LastRunAt)) — відновлюваність резервних копій не доведена"
        return $result
    }

    $verifiedAt = $null
    try {
        $verifiedAt = [datetime]::Parse(
            [string]$state.LastVerifiedAt,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        $result.Issue = "не вдалося розпарсити LastVerifiedAt ('$([string]$state.LastVerifiedAt)') у state-файлі перевірки відновлюваності"
        return $result
    }

    $ageHours = ($Now - $verifiedAt).TotalHours
    $ageHoursRounded = [math]::Round($ageHours, 1)
    if ($ageHours -gt $MaxVerificationAgeHours) {
        $result.Issue = "остання успішна перевірка відновлюваності застаріла: $ageHoursRounded год тому (поріг $MaxVerificationAgeHours год; GenerationId $([string]$state.GenerationId)) — перевірте задачу BRAVO_RESTORE_VERIFY"
        return $result
    }

    $result.Detail = "остання успішна верифікація: $ageHoursRounded год тому (GenerationId $([string]$state.GenerationId))"
    return $result
}
