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
            # #291: перший (і для контрольованих виходів єдиний) виклик в
            # Archive — у fail-soft helper'і Write-BRAVOArchiveOperationStatus,
            # який пишуть хвіст Main і ранні виходи; exit code він отримує
            # параметром. Порядок «хвостовий виклик ПІСЛЯ обчислення exit
            # code» перевіряється окремо нижче (CallSiteAfterExitCode).
            Label = 'Archive'
            Path = 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1'
            RequiredAfter = '$writeArchiveEarlyExitStatus = {'
        }
        @{
            Label = 'Health'
            Path = 'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1'
            RequiredAfter = '$script:healthRuntimeExitCode = $healthExitCode'
        }
        @{
            # #478: перший Write-BRAVOOperationStatus у Maintenance — у
            # fail-soft helper'і Write-BRAVOMaintenanceEarlyExitStatus (ранні
            # виходи; exit code він отримує параметром). Порядок «виклик
            # disk-preflight / фінальний ПІСЛЯ обчислення exit code»
            # перевіряється нижче окремо (CallSiteAfterExitCode).
            Label = 'Maintenance'
            Path = 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'
            RequiredAfter = 'function Write-BRAVOMaintenanceEarlyExitStatus'
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

    # #291: Archive пише статус через helper — хвостовий виклик helper'а
    # (останній у файлі; ранні виходи стоять вище) мусить іти ПІСЛЯ
    # остаточного обчислення exit code і передавати саме його, а сам helper
    # — бути першим сирим викликом (контракт [Archive] вище) у try/catch.
    $archiveStatusText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1'), [Text.Encoding]::UTF8)
    $archiveStatusExitCodeIndex = $archiveStatusText.IndexOf('$script:processExitCode = Resolve-BRAVOExitCode -HasWarnings')
    # Останній ВИКЛИК (рядок, що починається з імені команди), а не згадка
    # в коментарі чи визначенні функції.
    $archiveStatusCallMatches = [regex]::Matches($archiveStatusText, '(?m)^[ \t]*Write-BRAVOArchiveOperationStatus[ \t]+`')
    $archiveStatusTailCallIndex = if ($archiveStatusCallMatches.Count -gt 0) {
        $archiveStatusLastCall = $archiveStatusCallMatches[$archiveStatusCallMatches.Count - 1]
        $archiveStatusLastCall.Index + $archiveStatusLastCall.Value.IndexOf('Write-BRAVOArchiveOperationStatus')
    } else { -1 }
    $archiveStatusHelperIndex = $archiveStatusText.IndexOf('function Write-BRAVOArchiveOperationStatus')
    $archiveStatusTailCallText = if ($archiveStatusTailCallIndex -ge 0) {
        $archiveStatusText.Substring($archiveStatusTailCallIndex, [Math]::Min(300, $archiveStatusText.Length - $archiveStatusTailCallIndex))
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $archiveStatusExitCodeIndex -ge 0 -and
            $archiveStatusHelperIndex -ge 0 -and
            $archiveStatusTailCallIndex -gt $archiveStatusExitCodeIndex -and
            $archiveStatusTailCallText -match '^Write-BRAVOArchiveOperationStatus\s+`?\s*-ExitCode\s+\$script:processExitCode(?!\w)'
        ) `
        -Name 'Status/CallSiteAfterExitCode[ArchiveTail]' `
        -Failure 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1: хвостовий виклик Write-BRAVOArchiveOperationStatus має стояти ПІСЛЯ остаточного обчислення exit code і передавати -ExitCode $script:processExitCode'

    # #291: BRAVO_STATUS_Archive.json — статус нічної копії. Кожен сирий
    # Write-BRAVOOperationStatus в Archive (helper і фатальний catch навколо
    # Main) мусить бути під guard'ом -SyncBAZA, інакше денна синхронізація
    # (зокрема її крах з exit 90) перезапише статус нічної копії.
    $archiveSyncBazaGuardText = '(Test-Path variable:SyncBAZA) -and $SyncBAZA'
    $archiveRawStatusIndexes = New-Object 'System.Collections.Generic.List[int]'
    $archiveRawStatusSearchFrom = 0
    while ($true) {
        $archiveRawStatusIndex = $archiveStatusText.IndexOf('Write-BRAVOOperationStatus `', $archiveRawStatusSearchFrom)
        if ($archiveRawStatusIndex -lt 0) { break }
        $archiveRawStatusIndexes.Add($archiveRawStatusIndex)
        $archiveRawStatusSearchFrom = $archiveRawStatusIndex + 1
    }
    $archiveUnguardedStatusCount = 0
    foreach ($archiveRawStatusIndex in $archiveRawStatusIndexes) {
        $archiveGuardIndex = $archiveStatusText.LastIndexOf($archiveSyncBazaGuardText, $archiveRawStatusIndex)
        if ($archiveGuardIndex -lt 0 -or ($archiveRawStatusIndex - $archiveGuardIndex) -gt 2200) {
            $archiveUnguardedStatusCount++
        }
    }
    Test-BRAVOCondition `
        -Condition ($archiveRawStatusIndexes.Count -ge 2 -and $archiveUnguardedStatusCount -eq 0) `
        -Name 'Status/ArchiveStatusWritesSkipSyncBaza' `
        -Failure "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1: кожен Write-BRAVOOperationStatus (helper і фатальний catch) має бути під guard'ом -SyncBAZA; викликів=$($archiveRawStatusIndexes.Count), без guard'а=$archiveUnguardedStatusCount"

    # --- #479/#478 (мінімальний v1-порт частин A+B PR #493; рішення власника
    # D-A: код 20 SkippedLockBusy -> status WARNINGS, схема лишається v1) ---
    $statusExitCodesModulePath = Join-Path $root 'modules\BRAVO.ExitCodes\BRAVO.ExitCodes.psd1'
    Import-Module -Name $statusExitCodesModulePath -ErrorAction Stop
    $statusMappingActual = (@(foreach ($statusMappingCode in 0, 10, 20, 30, 32, 40, 41, 90) {
        try {
            '{0}={1}' -f $statusMappingCode, (Get-BRAVOExitCodeStatus -Code $statusMappingCode)
        } catch {
            '{0}=THROW' -f $statusMappingCode
        }
    })) -join ';'
    Test-BRAVOCondition `
        -Condition ($statusMappingActual -ceq '0=OK;10=WARNINGS;20=WARNINGS;30=ERROR;32=ERROR;40=ERROR;41=ERROR;90=ERROR') `
        -Name 'Status/ExitCodeStatusMapping' `
        -Failure "Get-BRAVOExitCodeStatus (BRAVO.ExitCodes) — єдине джерело: 0=OK, 10/20=WARNINGS, решта=ERROR; фактично: $statusMappingActual"

    $statusLockBusyRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_STATUS_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void](New-Item -ItemType Directory -Path $statusLockBusyRoot -Force)
        Write-BRAVOOperationStatus -StateRoot $statusLockBusyRoot -Operation Health `
            -ExitCode 20 -ExitCodeName 'SkippedLockBusy' -StartedAt (Get-Date)
        $statusLockBusy = Get-BRAVOOperationStatus -Path (Get-BRAVOOperationStatusPath -StateRoot $statusLockBusyRoot -Operation Health)
        Test-BRAVOCondition `
            -Condition (
                -not [bool]$statusLockBusy.Corrupt -and
                [string]$statusLockBusy.State.status -ceq 'WARNINGS' -and
                [int]$statusLockBusy.State.exitCode -eq 20 -and
                [int]$statusLockBusy.State.schemaVersion -eq 1
            ) `
            -Name 'Status/ExitCode20IsWarningsSchemaV1' `
            -Failure 'Write-BRAVOOperationStatus -ExitCode 20 має писати status=WARNINGS (D-A) зі schemaVersion=1'

        # QA-001 (відомий P1 PR #493): запис статусу не залежить від того, чи
        # імпортовано BRAVO.ExitCodes у сесію викликача. Чистий powershell.exe
        # імпортує ЛИШЕ BRAVO.Status.
        $statusCleanScript = Join-Path $statusLockBusyRoot 'clean-session.ps1'
        $statusCleanLines = @(
            'param([string]$StatusModule, [string]$StateRoot)',
            '$ErrorActionPreference = ''Stop''',
            'Import-Module -Name $StatusModule -ErrorAction Stop',
            'if (Get-Command -Name Get-BRAVOExitCodeStatus -ErrorAction SilentlyContinue) { Write-Output ''PRELOADED''; exit 3 }',
            'foreach ($code in 0, 10, 20, 30, 90) {',
            '    Write-BRAVOOperationStatus -StateRoot $StateRoot -Operation Archive -ExitCode $code -StartedAt (Get-Date)',
            '    $parsed = Get-Content -LiteralPath (Get-BRAVOOperationStatusPath -StateRoot $StateRoot -Operation Archive) -Raw | ConvertFrom-Json',
            '    Write-Output (''{0}={1}/v{2}'' -f $code, $parsed.status, $parsed.schemaVersion)',
            '}'
        )
        [IO.File]::WriteAllLines($statusCleanScript, $statusCleanLines, (New-Object Text.UTF8Encoding($true)))
        # Без -ExecutionPolicy: дочірній процес успадковує політику прогону
        # self-test через PSExecutionPolicyPreference (той самий патерн, що
        # дочірні BRAVO_SELF_TEST.ps1 у моноліті); Bypass поза allowlist
        # заборонено ci\Test-BRAVOForbiddenPattern.ps1.
        $statusCleanOutput = @(& powershell.exe -NoProfile -File $statusCleanScript `
                -StatusModule (Join-Path $root 'modules\BRAVO.Status\BRAVO.Status.psd1') -StateRoot $statusLockBusyRoot 2>&1 |
            ForEach-Object { [string]$_ })
        $statusCleanExit = $LASTEXITCODE
        Test-BRAVOCondition `
            -Condition (
                $statusCleanExit -eq 0 -and
                ($statusCleanOutput -join ';') -ceq '0=OK/v1;10=WARNINGS/v1;20=WARNINGS/v1;30=ERROR/v1;90=ERROR/v1'
            ) `
            -Name 'Status/WriteWithoutPreimportedExitCodes' `
            -Failure "QA-001: запис статусу в чистому powershell.exe без попереднього імпорту BRAVO.ExitCodes не має падати; exit=$statusCleanExit; вивід: $($statusCleanOutput -join ' | ')"
    } finally {
        Remove-Item -LiteralPath $statusLockBusyRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- #478: ранні виходи Maintenance/Archive йдуть через helper, який
    # best-effort пише status (помилка запису -> лише WARNING у лог, exit code
    # не змінюється) і лише потім робить exit. ---
    function Get-BRAVOStatusTestExitLines {
        # Нормалізований текст кожного ExitStatementAst (без Complete-* викликів).
        param([Parameter(Mandatory = $true)][string]$Path)
        $statusParseErrors = $null
        $statusParseTokens = $null
        $statusParsedAst = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$statusParseTokens, [ref]$statusParseErrors)
        $statusExitNodes = $statusParsedAst.FindAll({ param($node) $node -is [Management.Automation.Language.ExitStatementAst] }, $true)
        return @($statusExitNodes | ForEach-Object { ([string]$_.Extent.Text -replace '\s+', ' ').Trim() })
    }
    function Get-BRAVOStatusTestFunctionText {
        param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string[]]$Name)
        $statusParseErrors = $null
        $statusParseTokens = $null
        $statusParsedAst = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$statusParseTokens, [ref]$statusParseErrors)
        $statusFunctionNodes = $statusParsedAst.FindAll({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Name -contains $node.Name }, $true)
        return (@($statusFunctionNodes | ForEach-Object { $_.Extent.Text }) -join "`r`n`r`n")
    }

    function Get-BRAVOStatusTestScriptBlockAssignmentText {
        param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$VariableName)
        $statusParseErrors = $null
        $statusParseTokens = $null
        $statusParsedAst = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$statusParseTokens, [ref]$statusParseErrors)
        $statusAssignmentNodes = $statusParsedAst.FindAll({ param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -ceq ('$' + $VariableName) }, $true)
        return (@($statusAssignmentNodes | ForEach-Object { $_.Extent.Text }) -join "`r`n")
    }

    $statusMaintenancePath = Join-Path $root 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'
    $statusMaintenanceExits = Get-BRAVOStatusTestExitLines -Path $statusMaintenancePath
    $statusMaintenanceText = [IO.File]::ReadAllText($statusMaintenancePath, [Text.Encoding]::UTF8)
    # Дозволені сирі exit: Recovery/lock-busy/RecoverServices/диск-preflight/
    # дочірній елевований процес/фінальний, а також єдиний exit у helper'і.
    $statusMaintenanceAllowedRawExits = @(
        'exit $ExitCode',
        'Exit $elevatedProcess.ExitCode',
        'exit (Invoke-BRAVOMaintenanceRecoverServicesProfile -ForceRestore:$ForceRestore -RunMissedRestoreOnly:$RunMissedRestoreOnly)',
        'exit $recoveryNoWorkExitCode',
        'exit $diskPreflightExitCode',
        'exit (Resolve-BRAVOExitCode -LockBusy)',
        'exit (Resolve-BRAVOExitCode -LockBusy)',
        'exit $recoveryVetoExitCode',
        'exit 20',
        'exit (Resolve-BRAVOExitCode -ToolIntegrityViolation)',
        'exit $script:maintenanceRuntimeExitCode'
    )
    $statusMaintenanceRawExitDiff = @(Compare-Object -ReferenceObject $statusMaintenanceAllowedRawExits -DifferenceObject $statusMaintenanceExits)
    $statusMaintenanceEarlyCalls = @([regex]::Matches($statusMaintenanceText, '(?m)^\s*Complete-BRAVOMaintenanceEarlyExit\s+-ExitCode\s+(\d+|\(Resolve-BRAVOExitCode\s+-\w+\))\s+-Reason\s+''(\w+)''') |
        ForEach-Object { '{0}:{1}' -f $_.Groups[1].Value, $_.Groups[2].Value })
    $statusMaintenanceExpectedEarly = @(
        '30:ConfigurationLoad', '30:MissingConfigParameter', '30:MissingConfigParameter', '30:InvalidConfigValues',
        '30:InvalidExcludedDrives', '30:RangeIdLogPathUndefined', '30:ArchivePasswordInConfig',
        '31:ArchivePasswordMissing', '31:NotificationWebhookMissing', '30:InvalidAutoShutdown',
        '30:InvalidArchiveAfterMaintenance', '90:AdministratorRequired', '90:PowerShellVersion',
        '90:Unsupported32BitOS', '90:UnsupportedWindowsVersion', '30:EffectiveRootsUndefined',
        '90:LogDirectoryCreateFailed', '(Resolve-BRAVOExitCode -InvalidConfiguration):UnsupportedOperatingSystem'
    )
    $statusMaintenanceWriterText = Get-BRAVOStatusTestFunctionText -Path $statusMaintenancePath -Name @('Write-BRAVOMaintenanceEarlyExitStatus')
    $statusMaintenanceHelperText = Get-BRAVOStatusTestFunctionText -Path $statusMaintenancePath -Name @('Complete-BRAVOMaintenanceEarlyExit')
    Test-BRAVOCondition `
        -Condition (
            $statusMaintenanceRawExitDiff.Count -eq 0 -and
            @(Compare-Object -ReferenceObject $statusMaintenanceExpectedEarly -DifferenceObject $statusMaintenanceEarlyCalls).Count -eq 0 -and
            $statusMaintenanceWriterText.Contains('Write-BRAVOOperationStatus') -and
            $statusMaintenanceWriterText.Contains('Get-BRAVOExitCodeName') -and
            $statusMaintenanceWriterText -match '(?s)try\s*\{.*Write-BRAVOOperationStatus.*\}\s*catch\s*\{.*Write-Warning' -and
            $statusMaintenanceHelperText -match '(?s)Write-BRAVOMaintenanceEarlyExitStatus.*exit \$ExitCode' -and
            $statusMaintenanceText -match '(?s)Write-BRAVOMaintenanceEarlyExitStatus -ExitCode \(Resolve-BRAVOExitCode -ToolIntegrityViolation\) -Reason ''ToolIntegrityViolation''\s+exit \(Resolve-BRAVOExitCode -ToolIntegrityViolation\)'
        ) `
        -Name 'Status/MaintenanceEarlyExitsWriteStatus' `
        -Failure "Maintenance: ранні виходи (#478) мають іти через Complete-BRAVOMaintenanceEarlyExit (status, потім exit); сирі exit лише з allowlist (Recovery/lock-busy/RecoverServices/disk-preflight/child/фінальний). Різниця сирих exit: $((@($statusMaintenanceRawExitDiff | ForEach-Object { '{0} {1}' -f $_.SideIndicator, $_.InputObject })) -join ' | '); ранні виклики: $($statusMaintenanceEarlyCalls -join ',')"

    # Запис disk-preflight (власні лічильники) лишається після обчислення exit code, у try/catch.
    $statusDiskExitIndex = $statusMaintenanceText.IndexOf('$script:maintenanceRuntimeExitCode = $diskPreflightExitCode')
    $statusDiskWriteIndex = if ($statusDiskExitIndex -ge 0) { $statusMaintenanceText.IndexOf('Write-BRAVOOperationStatus', $statusDiskExitIndex) } else { -1 }
    $statusDiskTryIndex = if ($statusDiskWriteIndex -ge 0) { $statusMaintenanceText.LastIndexOf('try {', $statusDiskWriteIndex) } else { -1 }
    Test-BRAVOCondition `
        -Condition ($statusDiskWriteIndex -gt $statusDiskExitIndex -and $statusDiskExitIndex -ge 0 -and $statusDiskTryIndex -gt $statusDiskExitIndex -and ($statusDiskWriteIndex - $statusDiskTryIndex) -lt 600) `
        -Name 'Status/CallSiteAfterExitCode[MaintenanceDiskPreflight]' `
        -Failure 'Maintenance: запис статусу disk-preflight має стояти ПІСЛЯ обчислення exit code і всередині try/catch'

    $statusArchivePath = Join-Path $root 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1'
    $statusArchiveExits = Get-BRAVOStatusTestExitLines -Path $statusArchivePath
    $statusArchiveText = [IO.File]::ReadAllText($statusArchivePath, [Text.Encoding]::UTF8)
    # Ранні виходи конфігурації: `& $writeArchiveEarlyExitStatus <код> '<причина>'`
    # і одразу за ним буквальний `Exit <той самий код>` (scriptblock, а не
    # function — див. коментар у runtime). Решта числових exit: forward Health
    # без компонента (90) і фінальний (0); нечислові — child/Test-Compatibility
    # (останні пишуть статус самі) та фінальний.
    $statusArchiveEarlyPairs = @([regex]::Matches($statusArchiveText, '(?m)^[ \t]*&\s+\$writeArchiveEarlyExitStatus\s+(\d+)\s+''(\w+)''\r?\n[ \t]*[Ee]xit\s+\1\b') |
        ForEach-Object { '{0}:{1}' -f $_.Groups[1].Value, $_.Groups[2].Value })
    $statusArchiveExpectedEarly = @(
        '30:ConfigurationLoad', '30:FreeSpaceConfiguration', '36:PrivilegeRequired',
        '30:InstitutionSettings', '30:InstitutionSettings'
    )
    $statusArchiveNumericExits = @($statusArchiveExits | Where-Object { $_ -match '^exit \d+$' } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
    $statusArchiveExpectedNumericExits = @('exit 0', 'exit 30', 'exit 30', 'exit 30', 'exit 30', 'exit 36', 'exit 90')
    $statusArchiveBlockText = Get-BRAVOStatusTestFunctionText -Path $statusArchivePath -Name @('Write-BRAVOArchiveOperationStatus')
    $statusArchiveBlockIndex = $statusArchiveText.IndexOf('$writeArchiveEarlyExitStatus = {')
    Test-BRAVOCondition `
        -Condition (
            @(Compare-Object -ReferenceObject $statusArchiveExpectedEarly -DifferenceObject $statusArchiveEarlyPairs).Count -eq 0 -and
            @(Compare-Object -ReferenceObject $statusArchiveExpectedNumericExits -DifferenceObject $statusArchiveNumericExits).Count -eq 0 -and
            $statusArchiveBlockIndex -ge 0 -and
            $statusArchiveBlockIndex -lt $statusArchiveText.IndexOf('& $writeArchiveEarlyExitStatus 30 ''ConfigurationLoad''') -and
            $statusArchiveText.Substring($statusArchiveBlockIndex, 3000) -match '(?s)try\s*\{.*Write-BRAVOOperationStatus.*\}\s*catch\s*\{.*Write-Log' -and
            $statusArchiveText.Substring($statusArchiveBlockIndex, 3000).Contains('(Test-Path variable:SyncBAZA) -and $SyncBAZA')
        ) `
        -Name 'Status/ArchiveEarlyExitsWriteStatus' `
        -Failure "Archive: ранні виходи конфігурації (#478) мають писати статус через `$writeArchiveEarlyExitStatus перед буквальним Exit; пари: $($statusArchiveEarlyPairs -join ','); числові exit: $($statusArchiveNumericExits -join ',')"

    # Поведінка helper'ів: у дочірньому powershell.exe з реальним текстом
    # функцій. (1) валідний stateRoot -> status ERROR, exit code збережено;
    # (2) недоступний stateRoot (файл замість каталогу) -> exit code збережено;
    # (3) stateRoot не визначено -> нічого не пишеться, exit code збережено.
    $statusEarlyBehaviorRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_STATUS_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void](New-Item -ItemType Directory -Path $statusEarlyBehaviorRoot -Force)
        $statusEarlyFileRoot = Join-Path $statusEarlyBehaviorRoot 'not-a-directory'
        [IO.File]::WriteAllText($statusEarlyFileRoot, 'x')
        $statusEarlyCases = @(
            @{
                Label = 'Maintenance'; Operation = 'Maintenance'; Code = 32
                Functions = Get-BRAVOStatusTestFunctionText -Path $statusMaintenancePath -Name @('Write-BRAVOMaintenanceEarlyExitStatus', 'Complete-BRAVOMaintenanceEarlyExit')
                Call = 'Complete-BRAVOMaintenanceEarlyExit -ExitCode 32 -Reason ''ToolIntegrityViolation'''
            }
            @{
                Label = 'Archive'; Operation = 'Archive'; Code = 30
                Functions = Get-BRAVOStatusTestScriptBlockAssignmentText -Path $statusArchivePath -VariableName 'writeArchiveEarlyExitStatus'
                Call = "& `$writeArchiveEarlyExitStatus 30 'ConfigurationLoad'`r`nExit 30"
            }
        )
        foreach ($statusEarlyCase in $statusEarlyCases) {
            $statusEarlyResults = @()
            foreach ($statusEarlyMode in 'valid', 'locked', 'nolockdir', 'unwritable', 'undefined') {
                $statusEarlyStateRoot = Join-Path $statusEarlyBehaviorRoot ("{0}-{1}" -f $statusEarlyCase.Label, $statusEarlyMode)
                $statusEarlyScriptPath = Join-Path $statusEarlyBehaviorRoot ("early-{0}-{1}.ps1" -f $statusEarlyCase.Label, $statusEarlyMode)
                # ARCH-001: спільний operation lock (файл; Open ReadWrite/FileShare.Read,
                # як в Enter-*OperationLock). 'locked' — його утримує цей (інший) процес.
                $statusEarlyLockDirectory = Join-Path $statusEarlyBehaviorRoot ("lock-{0}-{1}" -f $statusEarlyCase.Label, $statusEarlyMode)
                # 'nolockdir' — свіжа установка: каталогу lock немає, helper має створити його сам.
                if ($statusEarlyMode -eq 'nolockdir') {
                    $statusEarlyLockDirectory = Join-Path $statusEarlyLockDirectory 'Locks'
                } else {
                    [void](New-Item -ItemType Directory -Path $statusEarlyLockDirectory -Force)
                }
                $statusEarlyLockDirExistedBefore = [IO.Directory]::Exists($statusEarlyLockDirectory)
                $statusEarlyLockPath = Join-Path $statusEarlyLockDirectory 'BRAVO_OPERATION.lock'
                $statusEarlyStateLine = switch ($statusEarlyMode) {
                    'valid' { '$stateRoot = ''{0}''' -f $statusEarlyStateRoot }
                    'nolockdir' { '$stateRoot = ''{0}''' -f $statusEarlyStateRoot }
                    'locked' { '$stateRoot = ''{0}''' -f $statusEarlyStateRoot }
                    'unwritable' { '$stateRoot = ''{0}''' -f $statusEarlyFileRoot }
                    default { '' }
                }
                $statusEarlyLockLine = '$operationLockSettings = @{{ Path = ''{0}'' }}' -f $statusEarlyLockPath
                $statusEarlyHeldLock = $null
                $statusEarlyBytesBefore = $null
                if ($statusEarlyMode -eq 'locked') {
                    # Існуючий статус "працюючого" екземпляра + утримуваний ним lock.
                    Write-BRAVOOperationStatus -StateRoot $statusEarlyStateRoot -Operation $statusEarlyCase.Operation `
                        -ExitCode 0 -ExitCodeName 'Success' -StartedAt (Get-Date).AddMinutes(-1)
                    $statusEarlyBytesBefore = [IO.File]::ReadAllBytes((Get-BRAVOOperationStatusPath -StateRoot $statusEarlyStateRoot -Operation $statusEarlyCase.Operation))
                    $statusEarlyHeldLock = [System.IO.File]::Open($statusEarlyLockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
                }
                $statusEarlyScript = @(
                    'Set-StrictMode -Version 2.0',
                    ('Import-Module -Name ''{0}'' -ErrorAction Stop' -f (Join-Path $root 'modules\BRAVO.ExitCodes\BRAVO.ExitCodes.psd1')),
                    ('Import-Module -Name ''{0}'' -ErrorAction Stop' -f (Join-Path $root 'modules\BRAVO.Status\BRAVO.Status.psd1')),
                    $statusEarlyStateLine,
                    $statusEarlyLockLine,
                    $statusEarlyCase.Functions,
                    $statusEarlyCase.Call
                ) -join "`r`n"
                [IO.File]::WriteAllText($statusEarlyScriptPath, $statusEarlyScript, (New-Object Text.UTF8Encoding($true)))
                try {
                    [void](& powershell.exe -NoProfile -File $statusEarlyScriptPath 2>&1)
                    $statusEarlyExit = $LASTEXITCODE
                } finally {
                    if ($null -ne $statusEarlyHeldLock) { $statusEarlyHeldLock.Dispose() }
                }
                $statusEarlyUnchanged = $true
                if ($statusEarlyMode -eq 'locked') {
                    $statusEarlyBytesAfter = [IO.File]::ReadAllBytes((Get-BRAVOOperationStatusPath -StateRoot $statusEarlyStateRoot -Operation $statusEarlyCase.Operation))
                    $statusEarlyUnchanged = ([Convert]::ToBase64String($statusEarlyBytesBefore) -ceq [Convert]::ToBase64String($statusEarlyBytesAfter))
                }
                $statusEarlyFile = Get-BRAVOOperationStatusPath -StateRoot $statusEarlyStateRoot -Operation $statusEarlyCase.Operation
                $statusEarlyParsed = if ([IO.File]::Exists($statusEarlyFile)) { Get-BRAVOOperationStatus -Path $statusEarlyFile } else { $null }
                $statusEarlyResults += [pscustomobject]@{
                    Mode = $statusEarlyMode
                    Unchanged = $statusEarlyUnchanged
                    LockDirExistedBefore = $statusEarlyLockDirExistedBefore
                    LockDirExistsAfter = [IO.Directory]::Exists($statusEarlyLockDirectory)
                    Exit = $statusEarlyExit
                    Status = if ($null -ne $statusEarlyParsed -and -not $statusEarlyParsed.Corrupt) { [string]$statusEarlyParsed.State.status } else { '' }
                    Early = if ($null -ne $statusEarlyParsed -and -not $statusEarlyParsed.Corrupt) { ($null -ne $statusEarlyParsed.State.details.PSObject.Properties['earlyTermination']) } else { $false }
                    Schema = if ($null -ne $statusEarlyParsed -and -not $statusEarlyParsed.Corrupt) { [int]$statusEarlyParsed.State.schemaVersion } else { 0 }
                }
            }
            $statusEarlyValid = $statusEarlyResults | Where-Object { $_.Mode -eq 'valid' }
            $statusEarlyNoDir = $statusEarlyResults | Where-Object { $_.Mode -eq 'nolockdir' }
            Test-BRAVOCondition `
                -Condition (
                    @($statusEarlyResults | Where-Object { $_.Exit -ne $statusEarlyCase.Code }).Count -eq 0 -and
                    $statusEarlyValid.Status -ceq 'ERROR' -and $statusEarlyValid.Early -and $statusEarlyValid.Schema -eq 1 -and
                    # ARCH-001: lock утримує інший процес -> існуючий статус не змінено (байти до == після).
                    [bool]($statusEarlyResults | Where-Object { $_.Mode -eq 'locked' }).Unchanged -and
                    # Свіжа установка: каталогу lock не було заздалегідь -> helper створив його і записав статус.
                    -not [bool]$statusEarlyNoDir.LockDirExistedBefore -and [bool]$statusEarlyNoDir.LockDirExistsAfter -and
                    $statusEarlyNoDir.Status -ceq 'ERROR' -and $statusEarlyNoDir.Early -and $statusEarlyNoDir.Schema -eq 1
                ) `
                -Name "Status/EarlyExitHelperBehavior[$($statusEarlyCase.Label)]" `
                -Failure "$($statusEarlyCase.Label): helper раннього виходу має записати ERROR/schema 1 (valid) і зберегти exit code $($statusEarlyCase.Code) також при недоступному/невизначеному stateRoot; факт: $(($statusEarlyResults | ForEach-Object { '{0}:exit={1},status={2}' -f $_.Mode, $_.Exit, $_.Status }) -join '; ')"
        }
    } finally {
        Remove-Item -LiteralPath $statusEarlyBehaviorRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Maintenance FinalStatus: 0/10/>=30 без змін тексту; 20 -> попередження.
    $statusFinalFunctionText = Get-BRAVOStatusTestFunctionText -Path $statusMaintenancePath -Name @('Get-BRAVOMaintenanceFinalStatus')
    $statusFinalTexts = (@(0, 10, 20, 40) | ForEach-Object {
            $statusFinalCode = $_
            $statusFinalResult = & ([scriptblock]::Create($statusFinalFunctionText + "`r`nGet-BRAVOMaintenanceFinalStatus -ExitCode $statusFinalCode"))
            '{0}={1}' -f $statusFinalCode, $statusFinalResult.Text
        }) -join ';'
    Test-BRAVOCondition `
        -Condition ($statusFinalTexts -ceq '0=УСПІШНО;10=УСПІШНО З ПОПЕРЕДЖЕННЯМИ;20=ПОПЕРЕДЖЕННЯ;40=ПОМИЛКА') `
        -Name 'Status/MaintenanceFinalStatusLockBusyIsWarning' `
        -Failure "Get-BRAVOMaintenanceFinalStatus: 0/10/>=30 без змін, 20 (SkippedLockBusy) -> попередження, не ПОМИЛКА; факт: $statusFinalTexts"
