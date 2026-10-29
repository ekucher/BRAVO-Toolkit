# Домен-фрагмент self-test: UpdateDiagnostics (INS-024, BRAVO.Update.Diagnostics:
# redaction, support-звіт, Save, хвіст журналу). Dot-sourced з кореневого
# BRAVO_SELF_TEST.ps1 -- НЕ запускається напряму. Успадковує з викликача:
# $root, Test-BRAVOCondition.

Import-Module (Join-Path $root 'modules\BRAVO.Update\BRAVO.Update.psm1') -Force -DisableNameChecking

# Shim-и лише на випадок, коли частини W1 (Contracts/Paths) ще не інтегровані:
# визначаються в області модуля тільки за відсутності справжніх функцій.
& (Get-Module BRAVO.Update) {
    if ($null -eq (Get-Command -Name 'Test-BRAVOUpdateNoSecretProperty' -ErrorAction SilentlyContinue)) {
        function script:Test-BRAVOUpdateNoSecretProperty {
            param($InputObject)
            $json = $InputObject | ConvertTo-Json -Depth 10
            $bad = @([regex]::Matches($json, '(?i)"[^"]*(password|secret|token|apikey|api_key|privatekey|passphrase|webhook)[^"]*"\s*:'))
            [pscustomobject]@{ IsValid = ($bad.Count -eq 0); Problems = @($bad | ForEach-Object { $_.Value }) }
        }
    }
    if ($null -eq (Get-Command -Name 'Format-BRAVOUpdateFindingMarker' -ErrorAction SilentlyContinue)) {
        function script:Format-BRAVOUpdateFindingMarker {
            param([string]$Severity)
            switch ($Severity) { 'Ok' { 'OK' } 'Warning' { '!' } 'Blocker' { 'X' } default { '-' } }
        }
    }
    if ($null -eq (Get-Command -Name 'Write-BRAVOUpdateFileAtomic' -ErrorAction SilentlyContinue)) {
        function script:Write-BRAVOUpdateFileAtomic {
            param([string]$Path, [string]$Text)
            $dir = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
        }
    }
}

$updDiagTemp = Join-Path ([IO.Path]::GetTempPath()) ('bravo-upddiag-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $updDiagTemp -Force)
$updDiagLockStream = $null
try {
    # ===== Redaction =====
    & {
        $fakeFp = 'SHA256:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ'
        $machine = [Environment]::MachineName
        $user = [Environment]::UserName
        $text = @(
            'password=Hunter2xyz',
            'token: abc123def456',
            'ip 192.0.2.15 loopback 127.0.0.1',
            'share \\host-a\backups\day1 end',
            'mail admin@example.com done',
            "key ssh-ed25519 255 $fakeFp ok",
            'site Example Lab / EXL-01',
            "machine $machine user $user"
        ) -join "`n"
        $out = & (Get-Module BRAVO.Update) { param($t) Protect-BRAVOUpdateReportText -Text $t -SiteIdentifiers @('Example Lab', 'EXL-01', 'host-a') } $text

        Test-BRAVOCondition -Condition ($out -notmatch 'Hunter2xyz') -Name 'UpdateDiagnostics/Redact-Password' -Failure 'password=... не замасковано'
        Test-BRAVOCondition -Condition ($out -notmatch 'abc123def456') -Name 'UpdateDiagnostics/Redact-Token' -Failure 'token не замасковано'
        Test-BRAVOCondition -Condition (($out -notmatch '192\.0\.2\.15') -and ($out -match '127\.0\.0\.1')) -Name 'UpdateDiagnostics/Redact-IPv4' -Failure 'IPv4 має бути замасковано, а 127.0.0.1 лишитися'
        Test-BRAVOCondition -Condition (($out -match '\\\\<redacted:host>\\backups') -and ($out -notmatch 'host-a')) -Name 'UpdateDiagnostics/Redact-UncHost' -Failure 'UNC host не замасковано, share має лишитися'
        Test-BRAVOCondition -Condition ($out -notmatch 'admin@example\.com') -Name 'UpdateDiagnostics/Redact-Email' -Failure 'e-mail не замасковано'
        Test-BRAVOCondition -Condition (($out -notmatch 'abcdefghijklmnopqrstuvwxyz') -and ($out -match '<redacted:fingerprint>')) -Name 'UpdateDiagnostics/Redact-Fingerprint' -Failure 'SFTP fingerprint не замасковано'
        Test-BRAVOCondition -Condition (($out -notmatch 'Example Lab') -and ($out -notmatch 'EXL-01')) -Name 'UpdateDiagnostics/Redact-SiteIdentifiers' -Failure 'ідентифікатори майданчика не замасковано'
        Test-BRAVOCondition -Condition (($out -notmatch [regex]::Escape($machine)) -and ($out -notmatch [regex]::Escape($user))) -Name 'UpdateDiagnostics/Redact-MachineAndUser' -Failure 'ім''я машини/користувача не замасковано'

        $safe = 'Версія 5.3.0 / 5.2.6-rc1, дата 2026-10-29T12:30:45Z, OS 10.0.20348, код 80'
        $safeOut = & (Get-Module BRAVO.Update) { param($t) Protect-BRAVOUpdateReportText -Text $t } $safe
        Test-BRAVOCondition -Condition ($safeOut -eq $safe) -Name 'UpdateDiagnostics/NoFalseRedaction' -Failure "версії/дати змінено: $safeOut"

        $emptyOut = & (Get-Module BRAVO.Update) { Protect-BRAVOUpdateReportText -Text '' }
        Test-BRAVOCondition -Condition ([string]::IsNullOrEmpty($emptyOut)) -Name 'UpdateDiagnostics/Redact-Empty' -Failure 'порожній текст має лишитися порожнім'

        $cyr = 'Установа «Тест-Лабораторія» шлях C:\Дані з пробілом'
        $cyrOut = & (Get-Module BRAVO.Update) { param($t) Protect-BRAVOUpdateReportText -Text $t -SiteIdentifiers @('Тест-Лабораторія') } $cyr
        Test-BRAVOCondition -Condition (($cyrOut -notmatch 'Тест-Лабораторія') -and ($cyrOut -match 'Дані з пробілом')) -Name 'UpdateDiagnostics/Redact-Cyrillic' -Failure "кирилиця: $cyrOut"
    }

    # ===== Report =====
    & {
        $state = [pscustomobject]@{
            schemaVersion = 1; state = 'Degraded'; runtimeRoot = 'C:\Sandbox Root\BRAVO'
            candidateRoots = @('C:\Sandbox Root\BRAVO')
            version = [pscustomobject]@{ packageVersion = '5.3.0'; releaseChannel = 'stable'; buildId = 'b1'; releaseDate = '2026-10-29' }
            integrity = [pscustomobject]@{ status = 'Valid'; checkedCount = 10; mismatchedCount = 0; missingCount = 0; unknownCount = 0; message = 'ok' }
            scheduler = [pscustomobject]@{ status = 'Partial'; tasks = @([pscustomobject]@{ name = 'BRAVO-Backup'; exists = $true; state = 'Ready'; enabled = $true }) }
            credentials = [pscustomobject]@{ status = 'Unknown'; items = @() }
            findings = @([pscustomobject]@{ id = 'State.X'; severity = 'Warning'; title = 'Хост host-a недоступний'; meaning = 'm'; action = 'a'; details = 'password=Hunter2xyz 192.0.2.7'; exitCodeHint = $null })
        }
        $preflight = [pscustomobject]@{ canProceed = $false; blockerCount = 1; warningCount = 0
            findings = @([pscustomobject]@{ id = 'Preflight.Disk'; severity = 'Blocker'; title = 'Мало місця'; meaning = 'm'; action = 'Звільніть місце'; details = ''; exitCodeHint = 20 }) }
        $results = @([pscustomobject]@{ finishedUtc = '2026-10-29T10:00:00Z'; action = 'Update'; status = 'Failed'; exitCode = 80; lastPhase = 'Deploy'; sourceVersion = '5.2.6'; targetVersion = '5.3.0' })
        $tail = @('2026-10-29 INFO start', 'ERROR token=abc123def456 mail ops@example.com host-a', 'Кирилиця в журналі')

        $report = & (Get-Module BRAVO.Update) {
            param($s, $p, $r, $t)
            New-BRAVODiagnosticReport -InstallationState $s -Preflight $p -RecentResults $r -LogTail $t -SiteIdentifiers @('host-a')
        } $state $preflight $results $tail
        $flat = ($report | ConvertTo-Json -Depth 10)
        $reportText = & (Get-Module BRAVO.Update) { param($r) Format-BRAVODiagnosticReportText -Report $r } $report

        Test-BRAVOCondition -Condition (($report.schemaVersion -eq 1) -and ($report.sections.Count -ge 5) -and ($null -ne $report.generatedUtc)) -Name 'UpdateDiagnostics/Report-Shape' -Failure 'форма звіту некоректна'
        Test-BRAVOCondition -Condition (($flat -notmatch 'Hunter2xyz') -and ($flat -notmatch 'abc123def456') -and ($flat -notmatch 'host-a') -and ($flat -notmatch '192\.0\.2\.7') -and ($flat -notmatch 'ops@example\.com')) -Name 'UpdateDiagnostics/Report-NoSecretsInData' -Failure 'у даних звіту лишився секрет/ідентифікатор'
        Test-BRAVOCondition -Condition (($reportText -notmatch 'Hunter2xyz') -and ($reportText -notmatch 'abc123def456') -and ($reportText -notmatch 'host-a')) -Name 'UpdateDiagnostics/Report-NoSecretsInText' -Failure 'у тексті звіту лишився секрет'
        Test-BRAVOCondition -Condition (($report.redactionsApplied.credential -ge 2) -and ($report.redactionsApplied.email -ge 1) -and ($report.redactionsApplied.site -ge 1)) -Name 'UpdateDiagnostics/Report-RedactionCounts' -Failure 'лічильники замін не накопичено'
        Test-BRAVOCondition -Condition ($null -ne $report.containsSecretsCheck -and $report.containsSecretsCheck.IsValid) -Name 'UpdateDiagnostics/Report-SecretPropertyCheck' -Failure 'containsSecretsCheck відсутній або невалідний'
        Test-BRAVOCondition -Condition (($reportText -match 'Діагностичний звіт') -and ($reportText -match 'Блокер') -and ($reportText -match 'Кирилиця в журналі') -and ($reportText -match '5\.3\.0')) -Name 'UpdateDiagnostics/Report-TextUkrainian' -Failure 'текстовий звіт без українських заголовків/маркерів/версії'

        # Мінімальний/частковий state не ламає звіт (StrictMode).
        $minimal = & (Get-Module BRAVO.Update) {
            New-BRAVODiagnosticReport -InstallationState ([pscustomobject]@{ state = 'NotInstalled' }) -Preflight ([pscustomobject]@{})
        }
        Test-BRAVOCondition -Condition ($minimal.sections.Count -ge 5) -Name 'UpdateDiagnostics/Report-PartialState' -Failure 'звіт для порожнього state не побудовано'

        # ===== Save =====
        $saveDir = Join-Path $updDiagTemp 'Звіти з пробілом'
        $savePath = Join-Path $saveDir 'report.txt'
        $null = & (Get-Module BRAVO.Update) { param($r, $p) Save-BRAVODiagnosticReport -Report $r -Path $p } $report $savePath
        $bytes = [IO.File]::ReadAllBytes($savePath)
        $noBom = -not (($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF))
        $roundTrip = [IO.File]::ReadAllText($savePath, (New-Object Text.UTF8Encoding $false))
        Test-BRAVOCondition -Condition ($noBom -and ($roundTrip -match 'Кирилиця в журналі')) -Name 'UpdateDiagnostics/Save-Utf8NoBom' -Failure 'файл має бути UTF-8 без BOM з кирилицею'

        $overwriteRefused = $false
        try { & (Get-Module BRAVO.Update) { param($r, $p) Save-BRAVODiagnosticReport -Report $r -Path $p } $report $savePath } catch { $overwriteRefused = $true }
        Test-BRAVOCondition -Condition $overwriteRefused -Name 'UpdateDiagnostics/Save-RefusesOverwrite' -Failure 'перезапис без -Force не відхилено'
        $forced = $true
        try { $null = & (Get-Module BRAVO.Update) { param($r, $p) Save-BRAVODiagnosticReport -Report $r -Path $p -Force } $report $savePath } catch { $forced = $false }
        Test-BRAVOCondition -Condition $forced -Name 'UpdateDiagnostics/Save-ForceOverwrites' -Failure '-Force має дозволяти перезапис'

        $runtimeRoot = Join-Path $updDiagTemp 'runtime root'
        [void](New-Item -ItemType Directory -Path $runtimeRoot -Force)
        $runtimeRefused = $false
        try { & (Get-Module BRAVO.Update) { param($r, $p, $rr) Save-BRAVODiagnosticReport -Report $r -Path $p -RuntimeRoot $rr } $report (Join-Path $runtimeRoot 'LOGS\r.txt') $runtimeRoot } catch { $runtimeRefused = $true }
        Test-BRAVOCondition -Condition ($runtimeRefused -and -not (Test-Path -LiteralPath (Join-Path $runtimeRoot 'LOGS'))) -Name 'UpdateDiagnostics/Save-RefusesRuntimeRoot' -Failure 'збереження під runtime root не відхилено або щось створено'

        $dirRefused = $false
        try { & (Get-Module BRAVO.Update) { param($r, $p) Save-BRAVODiagnosticReport -Report $r -Path $p } $report $saveDir } catch { $dirRefused = $true }
        Test-BRAVOCondition -Condition $dirRefused -Name 'UpdateDiagnostics/Save-RefusesDirectory' -Failure 'шлях-каталог не відхилено'
    }

    # ===== Log tail =====
    & {
        $logRoot = Join-Path $updDiagTemp 'LOGS з пробілом'
        [void](New-Item -ItemType Directory -Path $logRoot -Force)
        $older = Join-Path $logRoot 'old.log'
        $newer = Join-Path $logRoot 'new.log'
        [IO.File]::WriteAllText($older, "old1`r`nold2`r`n", (New-Object Text.UTF8Encoding $false))
        (Get-Item -LiteralPath $older).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2)
        [IO.File]::WriteAllText((Join-Path $logRoot 'ignored.txt'), 'not a log', (New-Object Text.UTF8Encoding $false))

        # Відкритий для запису файл (FileShare.ReadWrite) -- імітація живого журналу.
        $script:updDiagLockStream = New-Object IO.FileStream($newer, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $payload = (New-Object Text.UTF8Encoding $false).GetBytes("рядок 1`r`nрядок 2`r`nрядок 3`r`n")
        $script:updDiagLockStream.Write($payload, 0, $payload.Length)
        $script:updDiagLockStream.Flush()

        $lines = @(& (Get-Module BRAVO.Update) { param($d) Get-BRAVOUpdateLogTail -LogRoot $d -MaxLines 4 -MaxFiles 2 } $logRoot)
        Test-BRAVOCondition -Condition (($lines.Count -eq 4) -and ($lines[3] -eq 'рядок 3') -and ($lines[0] -eq 'old2')) -Name 'UpdateDiagnostics/LogTail-LockedFileAndCyrillic' -Failure "хвіст відкритого журналу: $($lines -join '|')"

        $one = @(& (Get-Module BRAVO.Update) { param($d) Get-BRAVOUpdateLogTail -LogRoot $d -MaxLines 10 -MaxFiles 1 } $logRoot)
        Test-BRAVOCondition -Condition (($one.Count -eq 3) -and ($one -notcontains 'old1')) -Name 'UpdateDiagnostics/LogTail-MaxFiles' -Failure "MaxFiles=1: $($one -join '|')"

        $missing = @(& (Get-Module BRAVO.Update) { param($d) Get-BRAVOUpdateLogTail -LogRoot (Join-Path $d 'нема') } $updDiagTemp)
        Test-BRAVOCondition -Condition ($missing.Count -eq 0) -Name 'UpdateDiagnostics/LogTail-MissingRoot' -Failure 'відсутній каталог має дати порожній результат'

        # Великий файл: читається лише обмежений хвіст, неповний перший рядок відкидається.
        $big = Join-Path $logRoot 'big.log'
        $sb = New-Object Text.StringBuilder
        for ($i = 1; $i -le 5000; $i++) { [void]$sb.AppendLine("line $i padding padding padding") }
        [IO.File]::WriteAllText($big, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
        $bigLines = @(& (Get-Module BRAVO.Update) { param($d) Get-BRAVOUpdateLogTail -LogRoot $d -MaxLines 3 -MaxFiles 1 -MaxBytesPerFile 2048 } $logRoot)
        Test-BRAVOCondition -Condition (($bigLines.Count -eq 3) -and ($bigLines[2] -eq 'line 5000 padding padding padding')) -Name 'UpdateDiagnostics/LogTail-BoundedBigFile' -Failure "великий файл: $($bigLines -join '|')"

        $script:updDiagLockStream.Dispose()
        $script:updDiagLockStream = $null
    }
}
finally {
    if ($null -ne $script:updDiagLockStream) { $script:updDiagLockStream.Dispose() }
    if ($updDiagTemp.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $updDiagTemp).StartsWith('bravo-upddiag-') -and
        (Test-Path -LiteralPath $updDiagTemp)) {
        Remove-Item -LiteralPath $updDiagTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
