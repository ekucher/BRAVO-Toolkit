# Домен-фрагмент self-test: Status (P2.1 — machine-readable status
# contract v1): атомарний roundtrip запису/читання, деривація status з
# exitCode, fail-closed на пошкодженій/невідомій схемі, відсутність
# secret-bearing значень і fail-soft контракти всіх чотирьох call-site'ів
# (Archive/Health/Maintenance/RestoreVerify) — телеметрія не має права
# змінювати exit code чи результат операції.
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 -- НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition, $script:failures.

    Import-Module -Name (Join-Path $root 'modules\BRAVO.Status\BRAVO.Status.psd1') -Force

    # --- Roundtrip + деривація status + fail-closed читання ---
    $operationStatusTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_STATUS_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void](New-Item -ItemType Directory -Path $operationStatusTestRoot -Force)
        Write-BRAVOOperationStatus -StateRoot $operationStatusTestRoot -Operation Health `
            -ExitCode 0 -ExitCodeName 'Success' -StartedAt (Get-Date).AddMinutes(-2) `
            -Details @{ localVerified = $true; issueCount = 0 }
        $operationStatusPath = Get-BRAVOOperationStatusPath -StateRoot $operationStatusTestRoot -Operation Health
        $operationStatusOk = Get-BRAVOOperationStatus -Path $operationStatusPath
        $operationStatusBytes = [IO.File]::ReadAllBytes($operationStatusPath)
        Write-BRAVOOperationStatus -StateRoot $operationStatusTestRoot -Operation Health `
            -ExitCode 10 -ExitCodeName 'SuccessWithWarnings' -StartedAt (Get-Date)
        $operationStatusWarn = Get-BRAVOOperationStatus -Path $operationStatusPath
        Write-BRAVOOperationStatus -StateRoot $operationStatusTestRoot -Operation Health `
            -ExitCode 43 -ExitCodeName 'RestoreFailed' -StartedAt (Get-Date)
        $operationStatusError = Get-BRAVOOperationStatus -Path $operationStatusPath
        Test-BRAVOCondition `
            -Condition (
                [bool]$operationStatusOk.Exists -and -not [bool]$operationStatusOk.Corrupt -and
                [int]$operationStatusOk.State.schemaVersion -eq 1 -and
                [string]$operationStatusOk.State.operation -eq 'Health' -and
                [string]$operationStatusOk.State.status -eq 'OK' -and
                [string]$operationStatusOk.State.host -eq [string]$env:COMPUTERNAME -and
                [bool]$operationStatusOk.State.details.localVerified -and
                -not ($operationStatusBytes.Length -ge 3 -and $operationStatusBytes[0] -eq 0xEF) -and
                [string]$operationStatusWarn.State.status -eq 'WARNINGS' -and
                [string]$operationStatusError.State.status -eq 'ERROR' -and
                @(Get-ChildItem -LiteralPath (Split-Path $operationStatusPath -Parent) -Force -File |
                    Where-Object { $_.Name -like '.BRAVO_STATUS_*' }).Count -eq 0
            ) `
            -Name 'Status/AtomicWriteRoundTripAndExitCodeDerivation' `
            -Failure 'BRAVO.Status: schemaVersion=1, UTF-8 без BOM, без .tmp/.bak-залишків; status деривується з exitCode в одному місці (0=OK, 10=WARNINGS, інше=ERROR)'

        [IO.File]::WriteAllText($operationStatusPath, '{"schemaVersion":99}', (New-Object Text.UTF8Encoding($false)))
        $operationStatusUnknownSchema = Get-BRAVOOperationStatus -Path $operationStatusPath
        [IO.File]::WriteAllText($operationStatusPath, 'garbage{{{', (New-Object Text.UTF8Encoding($false)))
        $operationStatusGarbage = Get-BRAVOOperationStatus -Path $operationStatusPath
        $operationStatusMissing = Get-BRAVOOperationStatus -Path (Join-Path $operationStatusTestRoot 'absent.json')
        Test-BRAVOCondition `
            -Condition (
                [bool]$operationStatusUnknownSchema.Corrupt -and
                [bool]$operationStatusGarbage.Corrupt -and
                -not [bool]$operationStatusMissing.Exists
            ) `
            -Name 'Status/CorruptedOrUnknownSchemaFailsClosed' `
            -Failure 'Get-BRAVOOperationStatus: невідома schemaVersion або сміття -> Corrupt (без мовчазної міграції); відсутній файл -> Exists=false'

        # Контракт «жодних secret-bearing values»: серіалізований JSON
        # типового запису не містить полів-носіїв секретів.
        Write-BRAVOOperationStatus -StateRoot $operationStatusTestRoot -Operation Archive `
            -ExitCode 0 -ExitCodeName 'Success' -StartedAt (Get-Date) `
            -Details @{ generationId = 'GEN_1'; componentsSucceeded = 3; componentsTotal = 3; totalCreatedBytes = 123456 }
        $operationStatusSerialized = [IO.File]::ReadAllText(
            (Get-BRAVOOperationStatusPath -StateRoot $operationStatusTestRoot -Operation Archive), [Text.Encoding]::UTF8)
        Test-BRAVOCondition `
            -Condition ($operationStatusSerialized -notmatch '(?i)(password|secret|token|webhook|sftp://)') `
            -Name 'Status/NoSecretBearingFields' `
            -Failure 'status-файл не повинен містити secret-bearing значень (password/token/webhook/URI з credentials)'
    } finally {
        Remove-Item -LiteralPath $operationStatusTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- Fail-soft контракти call-site'ів: виклик обгорнутий try/catch і
    # стоїть ПІСЛЯ обчислення exit code (телеметрія не змінює результат) ---
    $statusCallSiteContracts = @(
        @{
            Label = 'Archive'
            Path = 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1'
            RequiredAfter = '$script:processExitCode = Resolve-BRAVOExitCode -HasWarnings'
        }
        @{
            Label = 'Health'
            Path = 'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1'
            RequiredAfter = '$script:healthRuntimeExitCode = $healthExitCode'
        }
        @{
            # Перший Write-BRAVOOperationStatus у Maintenance — ранній вихід
            # disk-preflight; його exit code резолвиться рядком нижче.
            Label = 'Maintenance'
            Path = 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'
            RequiredAfter = '$script:maintenanceRuntimeExitCode = $diskPreflightExitCode'
        }
        @{
            Label = 'RestoreVerify'
            Path = 'BRAVO_RESTORE_TEST.ps1'
            RequiredAfter = '$drillExitCodeForState = Resolve-BRAVOExitCode'
        }
    )
    foreach ($statusCallSite in $statusCallSiteContracts) {
        $statusCallSiteText = [IO.File]::ReadAllText((Join-Path $root $statusCallSite.Path), [Text.Encoding]::UTF8)
        $statusWriteIndex = $statusCallSiteText.IndexOf('Write-BRAVOOperationStatus')
        $exitCodeIndex = $statusCallSiteText.IndexOf([string]$statusCallSite.RequiredAfter)
        # try { ... Write-BRAVOOperationStatus ... } catch: перевіряємо, що
        # безпосередньо перед викликом у тому самому файлі є "try {" ближче,
        # ніж будь-який розрив (груба, але стабільна перевірка обгортки).
        $statusTryIndex = if ($statusWriteIndex -ge 0) {
            $statusCallSiteText.LastIndexOf('try {', $statusWriteIndex)
        } else { -1 }
        Test-BRAVOCondition `
            -Condition (
                $statusWriteIndex -ge 0 -and
                $exitCodeIndex -ge 0 -and
                $statusWriteIndex -gt $exitCodeIndex -and
                $statusTryIndex -ge 0 -and
                ($statusWriteIndex - $statusTryIndex) -lt 2500
            ) `
            -Name "Status/CallSiteIsFailSoft[$($statusCallSite.Label)]" `
            -Failure "$($statusCallSite.Path): Write-BRAVOOperationStatus має стояти ПІСЛЯ обчислення exit code і всередині try/catch (fail-soft; телеметрія не змінює результат операції)"
    }
